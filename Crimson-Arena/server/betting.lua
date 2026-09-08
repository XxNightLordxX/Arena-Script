-- Crimson Arena: the book. Stakes, odds, and who gets paid.

ArenaBetting = {}

local escrow = {}

--- Money this resource took and could not give back, keyed by CITIZEN ID.
---
--- WHY IT CANNOT BE KEYED BY MATCH, which is what it was before and is the
--- whole defect. Escrow is `escrow[matchId]`, reachable only through
--- stakesOf(matchId), and nothing anywhere iterates it. A refund that fails
--- leaves the stake unsettled with a comment promising "a later RefundAll
--- tries again" -- but there is no later: ArenaLobby.Leave sees the lobby is
--- empty and calls Destroy in the same call chain, Destroy calls RefundAll
--- (which fails the same way) and then Clear (which correctly REFUSES,
--- because the pot is still held) -- and then drops `matches[match.id]`
--- anyway. From that instant no id exists to call Clear, RefundAll or GetPot
--- with, and the escrow row sits in memory until the server stops.
---
--- Destroy's own comment states the invariant it does not enforce: "escrow
--- against a match nobody can look up is money nobody can get out again."
---
--- And the failure is not exotic. credit() needs a LOADED character, so the
--- commonest reason a refund cannot be delivered is the commonest reason one
--- is owed: they crashed. A single-host lobby whose host crashes destroys
--- the match immediately, and takes the entry fee with it.
---
--- Keyed by citizen id, the debt survives the reconnect, the teardown and
--- the recycled server id -- exactly as server/ammo.lua's `owed` does for
--- belongings, for exactly the same reason.
local unpaid = {}

local sideBets = {}

local function trace(fmt, ...)
    if Config.Debug then ArenaLog(fmt, ...) end
end

local function money(amount)
    return ('%s%d'):format(Config.Betting.currencySymbol or '$', math.max(0, Arena.ToInt(amount) or 0))
end

local function serverId(value)
    local id = Arena.ToInt(value)
    if not id or id <= 0 then return nil end
    return id
end

local function citizenIdOf(src)
    local player = ArenaGetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

local function balanceOf(player, account)
    local wallet = player and player.PlayerData and player.PlayerData.money
    if type(wallet) ~= 'table' then return nil end
    return Arena.ToInt(wallet[account or Config.Betting.account])
end

local function debitAccounts()
    local list = Config.Betting.accounts
    local out = {}
    if type(list) == 'table' then
        for _, name in ipairs(list) do
            if Arena.IsKey(name) then out[#out + 1] = name end
        end
    end
    if #out == 0 then out[1] = Config.Betting.account or 'cash' end
    return out
end

function ArenaBetting.Accounts()
    return debitAccounts()
end

--- What one player holds in each of them, for the panel's own display. Read
--- through the same balanceOf every debit uses, so the figure on screen and
--- the figure the debit checks cannot disagree.
--- @param src any
--- @return table<string, integer>
function ArenaBetting.Wallet(src)
    local player = ArenaGetPlayer(serverId(src))
    local out = {}
    for _, account in ipairs(debitAccounts()) do
        out[account] = balanceOf(player, account) or 0
    end
    return out
end

local function moved(before, after, amount, outward)
    if not before or not after then return nil end
    local delta = outward and (before - after) or (after - before)
    return delta >= amount
end

--- The accounts to try for one debit, honouring a player's own choice.
---
--- A CHOSEN ACCOUNT IS THE ONLY ONE TRIED. Falling back to the other would
--- take money out of a pocket the player deliberately did not pick -- they
--- chose `bank` because they wanted the cash left alone, and quietly spending
--- it instead is the same class of mistake as clamping a number somebody
--- typed. Refused with a reason they can act on is the honest answer.
---
--- THREE ANSWERS, NOT TWO, and collapsing the last two was a hole in exactly
--- the promise above.
---
---   NO NAME GIVEN -- "no preference". Every server that has not switched
---   the choice on, and every panel that has not been touched. Falls back to
---   the operator's list, and must, or an old panel cannot pay at all.
---
---   A NAME THAT IS NOT ONE OF THIS PLAYER'S ACCOUNTS -- junk. A stale
---   panel, a typo in a payload, a crafted request. Nothing was really
---   chosen, so this is "no preference" too: refusing a player who can
---   plainly pay, because something sent a word nobody recognises, helps
---   nobody.
---
---   A REAL ACCOUNT OF THEIRS THAT THIS SERVER DOES NOT DEBIT -- a choice
---   that cannot be honoured. This is a player who picked cash on a server
---   that has since stopped taking it, and falling back spends the pocket
---   they deliberately left alone. That is the one outcome this whole
---   function exists to prevent, so nothing moves and they are told.
---
--- The player's own wallet is what separates the last two, because it is the
--- only thing that knows which account names are real for them.
--- @param player table|nil
--- @param preferred any
--- @return string[]|nil -- nil where a real choice cannot be honoured
local function accountsFor(player, preferred)
    local allowed = debitAccounts()
    if not Arena.IsKey(preferred) then return allowed end

    for _, name in ipairs(allowed) do
        if name == preferred then return { name } end
    end

    local wallet = player and player.PlayerData and player.PlayerData.money
    if type(wallet) ~= 'table' or wallet[preferred] == nil then return allowed end

    return nil
end

local function debit(src, amount, reason, preferred)
    local player = ArenaGetPlayer(src)
    if not player then return false, nil end

    local accounts = accountsFor(player, preferred)
    if not accounts then
        ArenaLog('betting: refused a payment from \'%s\' -- that account exists for this player but is not one Config.Betting.accounts lets this server debit. Nothing was taken from the other one.',
            tostring(preferred))
        return false, nil
    end

    for _, account in ipairs(accounts) do
        local before = balanceOf(player, account)

        if before == nil or before >= amount then
            local answer = player.Functions.RemoveMoney(account, amount, reason)

            if answer ~= false then
                local confirmed = moved(before, balanceOf(ArenaGetPlayer(src), account), amount, true)

                -- nil is an unreadable balance, so the return value is all
                -- there is. Only an explicit false counts against it --
                -- checked above -- because a framework that reports success
                -- by staying quiet must not be read as refusing.
                if confirmed == nil or confirmed then return true, account end
            end
        end
    end

    return false, nil
end

local function credit(src, amount, reason, citizenid, account)
    local player = ArenaGetPlayer(src)
    if not player then return false end
    if citizenid and (player.PlayerData and player.PlayerData.citizenid) ~= citizenid then return false end

    -- BACK WHERE IT CAME FROM when we know, and to the configured account
    -- when we do not. Refunding bank money as cash is a way to launder
    -- through the arena, and refunding cash into the bank is a surprise for
    -- somebody who was carrying it on purpose.
    local target = Arena.IsKey(account) and account
        or (debitAccounts()[1] or Config.Betting.account)

    local before = balanceOf(player, target)
    local answer = player.Functions.AddMoney(target, amount, reason)
    if answer == false then return false end

    local confirmed = moved(before, balanceOf(ArenaGetPlayer(src), target), amount, false)
    if confirmed ~= nil then return confirmed end

    return true
end

--- Records money this resource owes a character and could not deliver.
---
--- THE POINT IS THE KEY. A debt filed against a match id dies with the
--- match, and the match is torn down in the same call chain that failed to
--- pay. Filed against the citizen id it survives the teardown, the
--- reconnect, and the recycled server id -- and the sweep at the bottom of
--- this file pays it the next time that character is seen.
---
--- Accumulated rather than overwritten: a player can be owed an entry fee
--- and a side-bet off the same collapse, and the second must not erase the
--- first.
--- @param citizenid any
--- @param name any -- for the log only
--- @param amount integer
--- @param account string|nil -- the account it was taken FROM
--- @param reason string|nil
--- @return boolean recorded -- false when there is no citizen id to file under
local function owe(citizenid, name, amount, account, reason)
    local id = Arena.IsKey(citizenid) and citizenid or nil
    local value = math.max(0, Arena.ToInt(amount) or 0)
    if not id or value <= 0 then return false end

    local row = unpaid[id]
    if not row then
        row = { citizenid = id, name = name, total = 0, parts = {} }
        unpaid[id] = row
    end

    row.name = name or row.name
    row.total = row.total + value
    row.parts[#row.parts + 1] = { amount = value, account = account, reason = reason }
    return true
end

local function transaction(kind, matchId)
    return ('crimson_arena:%s:%s'):format(kind, tostring(matchId))
end

local function payoutWebhook(title, description, fields)
    if Config.Webhook.logPayouts ~= true then return end
    ArenaWebhook(title, description, fields)
end

--- Discord log of money this file could not deliver. Deliberately NOT gated
--- on `logPayouts`: an operator who turned payout logging off still needs to
--- hear about a player who is owed. ArenaWebhook itself no-ops when webhooks
--- are switched off entirely.
local function incidentWebhook(title, description, fields)
    ArenaWebhook(title, description, fields)
end

local function stakesOf(matchId)
    return escrow[matchId] or {}
end

local function canonicalPick(value)
    if type(value) == 'number' then
        local id = Arena.ToInt(value)
        return id and tostring(id) or nil
    end
    if Arena.IsKey(value) then return value end
    return nil
end

local function lobbyMatch(matchId)
    if type(ArenaLobby) ~= 'table' or type(ArenaLobby.Get) ~= 'function' then return nil end
    local match = ArenaLobby.Get(matchId)
    if type(match) ~= 'table' then return nil end
    return match
end

local function fightersOf(matchId)
    local match = lobbyMatch(matchId)
    if not match or type(match.players) ~= 'table' then return nil end
    return match.players
end

local function holdsSideBet(matchId, src)
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == src and not bet.settled then return true end
    end
    return false
end

local function betsAreOpen(match, isFighter)
    local state = match.state
    if state == 'lobby' or state == 'countdown' then return true end
    if state ~= 'live' then return false end

    if isFighter then return false end

    local spectator = Config.Betting.spectatorBets or {}
    local grace = math.max(0, Arena.ToInt(spectator.closeAfterStartSeconds) or 0)
    local startedAt = Arena.ToInt(match.startsAt)
    local now = os.time()
    if not startedAt or startedAt > now then return false end
    return (now - startedAt) < grace
end

function ArenaBetting.BetsAreOpen(match)
    return type(match) == 'table' and betsAreOpen(match) or false
end

function ArenaBetting.SecondsUntilBetsClose(match)
    if type(match) ~= 'table' or match.state ~= 'live' then return nil end

    local spectator = Config.Betting.spectatorBets or {}
    local grace = math.max(0, Arena.ToInt(spectator.closeAfterStartSeconds) or 0)
    local startedAt = Arena.ToInt(match.startsAt)
    if grace <= 0 or not startedAt then return nil end

    local left = (startedAt + grace) - os.time()
    if left <= 0 then return nil end
    return left
end

local function pickExists(match, pick)
    local players = type(match.players) == 'table' and match.players or {}

    -- ELIMINATED IS NOT ON THE ROSTER, for this question.
    --
    -- An eliminated fighter deliberately KEEPS their row -- the results board
    -- ranks off it -- so "is in match.players" and "can still win" are two
    -- different questions and this only ever asked the first. The book stays
    -- open for spectatorBets.closeAfterStartSeconds (30 on the shipped
    -- config) AFTER the round goes live, so inside that window a spectator
    -- could be sold a bet, by the panel's own chip, on somebody who was
    -- already out. It is not voided at settlement either -- the holder never
    -- fought -- so it falls through to lost and their whole stake, up to
    -- 25,000, goes to whoever backed the winner.
    if Arena.ModeUsesTeams(match.modeKey) then
        if not Arena.GetTeamByKey(pick) then return false end
        for _, player in pairs(players) do
            if player.team == pick and not Arena.IsEliminated(player) then return true end
        end
        return false
    end

    for id, player in pairs(players) do
        if canonicalPick(id) == pick and not Arena.IsEliminated(player) then return true end
    end
    return false
end

local function isRefundReason(reason)
    return type(reason) == 'string' and reason:sub(1, 6) == 'refund'
end

--- Whether a payout line is a stake coming back rather than money won.
---
--- Exported because server/match.lua has to tell them apart and could not:
--- Settle hands its computed list back even when the whole thing is a
--- refund -- deliberately, as the report of what was decided -- and End
--- summed every line into a player's `earnings`. So a match that did not
--- qualify to pay out told everybody they had WON their own entry fee back.
--- @param reason any
--- @return boolean
function ArenaBetting.IsRefundReason(reason)
    return isRefundReason(reason)
end

local function returnSideBet(bet, matchId)
    if bet.settled then return false end

    if not credit(bet.src, bet.amount, transaction('sidebet_refund', matchId),
        bet.citizenid, bet.account) then
        if owe(bet.citizenid, bet.name or bet.src, bet.amount, bet.account, 'sidebet_refund') then
            bet.settled = true
            bet.settledAs = 'owed'
            ArenaLog('SIDE-BET REFUND DEFERRED: %d owed to %s (citizenid %s) on match %s -- recorded against ' ..
                'their character and paid when they are next seen.',
                bet.amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
        else
            ArenaLog('SIDE-BET REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the bet stays held, ' ..
                'and there is no citizen id to file it against.',
                bet.amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
        end
        incidentWebhook('Side-bet not returned',
            'A spectator side-bet could not be handed back and is still owed.', {
                { name = 'Match', value = tostring(matchId) },
                { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                { name = 'Amount', value = money(bet.amount) },
            })
        return false
    end

    bet.settled = true
    bet.settledAs = 'refund'
    trace('returned side-bet of %d to %s on match %s', bet.amount, tostring(bet.src), tostring(matchId))
    ArenaNotifyKey(bet.src, 'notify.spectator_bet_refunded', 'info', money(bet.amount))
    return true
end

function ArenaBetting.IsEnabled()
    return Config.Betting.enabled == true
end

function ArenaBetting.StakeOf(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return 0, nil end

    local stake = stakesOf(matchId)[id]
    if type(stake) ~= 'table' or stake.settled then return 0, nil end
    return math.max(0, Arena.ToInt(stake.amount) or 0), stake.account
end

function ArenaBetting.GetPot(matchId)
    local total = 0
    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then total = total + stake.amount end
    end
    return total
end

function ArenaBetting.GetStake(matchId, src)
    local id = serverId(src)
    if not id then return 0 end
    local stake = stakesOf(matchId)[id]
    if not stake or stake.settled then return 0 end
    return stake.amount
end

--- Takes a player's entry fee and holds it against `matchId`.
---
--- Betting switched off, or entry fees switched off, is SUCCESS with nothing
--- taken: a free match must not become unjoinable because there is no pot.
--- Every other refusal happens BEFORE any money moves, so a false return
--- always means the player's account is untouched.
--- @param src integer
--- @param matchId string
--- @param amount any -- as requested; re-resolved through Arena.ResolveEntryFee
--- @param account any -- which account the player chose to pay from, if any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaBetting.TakeStake(src, matchId, amount, account)
    if not ArenaBetting.IsEnabled() then return true, nil end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    if holdsSideBet(matchId, id) then return false, 'error.bet_not_spectator' end

    local fee, reason = Arena.ResolveEntryFee(amount)
    if not fee then return false, reason or 'error.bet_invalid' end
    if fee <= 0 then return true, nil end

    local held = stakesOf(matchId)[id]
    if held and not held.settled then
        local fighters = fightersOf(matchId)
        local vacated = fighters ~= nil and fighters[id] == nil
        local theirs = held.citizenid ~= nil and held.citizenid == citizenIdOf(id)

        if not vacated or not theirs then
            ArenaLog('DOUBLE STAKE REFUSED: %s already holds %d on match %s. Nothing was taken.',
                tostring(held.citizenid or id), held.amount, tostring(matchId))
            return false, 'error.bet_already_staked'
        end

        trace('%s took a seat on match %s back on the %d already forfeited to its pot -- nothing taken',
            tostring(held.citizenid or id), tostring(matchId), held.amount)
        return true, nil
    end

    local ceiling = Arena.ToInt(Config.Betting.maxPot) or 0
    if ceiling > 0 and (ArenaBetting.GetPot(matchId) + fee) > ceiling then
        return false, 'error.pot_limit_reached'
    end

    local took, paidFrom = debit(id, fee, transaction('stake', matchId), account)
    if not took then
        return false, 'error.not_enough_money'
    end

    escrow[matchId] = escrow[matchId] or {}
    escrow[matchId][id] = {
        amount = fee,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
        account = paidFrom,
        takenAt = os.time(),
        settled = false,
    }

    trace('took stake of %d from %s for match %s (pot now %d)',
        fee, tostring(id), tostring(matchId), ArenaBetting.GetPot(matchId))
    ArenaNotifyKey(id, 'notify.stake_taken', 'info', money(fee))
    return true, nil
end

function ArenaBetting.RefundOne(matchId, src, reasonKey)
    local id = serverId(src)
    if not id then return false end

    local stake = stakesOf(matchId)[id]
    if not stake then
        ArenaLog('REFUND IGNORED: no stake is held for %s on match %s.', tostring(id), tostring(matchId))
        return false
    end
    if stake.settled then
        ArenaLog('DOUBLE REFUND REFUSED: %d for %s on match %s was already returned as "%s". Nothing was paid.',
            stake.amount, tostring(stake.citizenid or id), tostring(matchId), tostring(stake.settledAs))
        return false
    end

    if not credit(id, stake.amount, transaction('refund', matchId),
        stake.citizenid, stake.account) then
        -- Left unsettled deliberately: this is money still held and still
        -- owed, so a later RefundAll tries again and Clear goes on refusing
        -- to drop the match until it lands. Writing it off here would be the
        -- one thing this file must never do.
        -- MOVED OFF THE MATCH RATHER THAN LEFT ON IT. The stake is marked
        -- settled so Clear can drop this match's escrow, and the money is
        -- filed against the CHARACTER, where the sweep can still find it
        -- after Destroy has dropped the id. Left on the match it was
        -- destroyed a few milliseconds later; the log line that used to sit
        -- here promised a retry that had nowhere to run.
        if owe(stake.citizenid, stake.name or id, stake.amount, stake.account, reasonKey) then
            stake.settled = true
            stake.settledAs = 'owed'
            ArenaLog('REFUND DEFERRED: %d owed to %s (citizenid %s) could not be delivered on match %s -- ' ..
                'they are not on the server. It is recorded against their character and will be paid when they are next seen.',
                stake.amount, tostring(stake.name or id), tostring(stake.citizenid), tostring(matchId))
        else
            ArenaLog('REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the stake stays held, ' ..
                'and there is no citizen id to file it against.',
                stake.amount, tostring(stake.name or id), tostring(stake.citizenid), tostring(matchId))
        end
        incidentWebhook('Stake not refunded', 'An entry fee could not be returned and is still held in escrow.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Player', value = ('%s (%s)'):format(tostring(stake.name or id), tostring(stake.citizenid)) },
            { name = 'Amount', value = money(stake.amount) },
        })
        return false
    end

    stake.settled = true
    stake.settledAs = 'refund'
    stake.reason = reasonKey

    trace('refunded %d to %s on match %s (%s)',
        stake.amount, tostring(id), tostring(matchId), tostring(reasonKey))
    ArenaNotifyKey(id, 'notify.stake_refunded', 'info', money(stake.amount))
    return true
end

function ArenaBetting.RefundAll(matchId, reasonKey)
    local refunded, total, owed = 0, 0, 0

    for id, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            local amount = stake.amount
            if ArenaBetting.RefundOne(matchId, id, reasonKey) then
                refunded = refunded + 1
                total = total + amount
            else
                owed = owed + amount
            end
        end
    end

    if owed > 0 then
        ArenaLog('REFUND INCOMPLETE: match %s still owes %d across its players.', tostring(matchId), owed)
    elseif refunded > 0 then
        trace('refunded %d stake(s) worth %d on match %s (%s)',
            refunded, total, tostring(matchId), tostring(reasonKey))
    end

    return owed == 0, refunded, total
end

function ArenaBetting.KeepInPot(matchId, src)
    local id = serverId(src)
    if not id then return 0 end

    local stake = stakesOf(matchId)[id]
    if not stake or stake.settled then return 0 end

    trace('kept %d of %s in the pot on match %s', stake.amount, tostring(id), tostring(matchId))
    ArenaNotifyKey(id, 'notify.stake_forfeited', 'error', money(stake.amount))
    return stake.amount
end

function ArenaBetting.ForfeitAll(matchId, reasonKey)
    local forfeited, total = 0, 0

    for id, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            stake.settled = true
            stake.settledAs = 'forfeit'
            stake.reason = reasonKey
            forfeited = forfeited + 1
            total = total + stake.amount
            ArenaNotifyKey(id, 'notify.stake_forfeited', 'error', money(stake.amount))
        end
    end

    if total > 0 then
        ArenaLog('FORFEIT: match %s kept %d across %d stake(s) (%s). Nobody was paid it.',
            tostring(matchId), total, forfeited, tostring(reasonKey))
        incidentWebhook('Pot forfeited', 'A cancelled lobby kept its stakes instead of returning them.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Kept', value = money(total) },
            { name = 'Stakes', value = tostring(forfeited) },
            { name = 'Reason', value = tostring(reasonKey) },
        })
    end

    return forfeited, total
end

local function entryPotJoinsPool()
    local block = Config.Betting.betPayout
    return type(block) == 'table' and block.includeEntryPot == true
end

local function addEntryStakesAsBets(matchId, context)
    local sides = {}
    for _, row in ipairs((type(context) == 'table' and context.players) or {}) do
        local id = Arena.ToInt(row.id)
        if id then
            sides[id] = Arena.IsKey(row.team) and row.team or tostring(id)
        end
    end

    local added = 0
    for src, stake in pairs(stakesOf(matchId)) do
        local amount = Arena.ToInt(stake.amount) or 0
        if not stake.settled and amount > 0 then
            sideBets[matchId] = sideBets[matchId] or {}
            sideBets[matchId][#sideBets[matchId] + 1] = {
                src = src,
                citizenid = stake.citizenid,
                name = stake.name,
                pick = sides[src] or tostring(src),
                amount = amount,
                account = stake.account,
                kind = 'fighter',
                mode = 'pool',
                fromEntryFee = true,
                placedAt = stake.takenAt,
                settled = false,
            }

            stake.settled = true
            added = added + 1
        end
    end

    return added
end

function ArenaBetting.Settle(matchId, context)
    if not Arena.IsKey(matchId) then return {} end

    if entryPotJoinsPool() then
        local added = addEntryStakesAsBets(matchId, context)
        if added > 0 then
            trace('entry fees joined the bet pool on match %s (%d stake(s))', tostring(matchId), added)
        end
        return {}
    end

    local pot = ArenaBetting.GetPot(matchId)
    if pot <= 0 then
        ArenaLog('betting: match %s had NOTHING IN THE POT to pay out. Either the match was created with no entry fee, or every stake had already been refunded or forfeited before it ended. Side-bets are a separate pool and are unaffected.',
            tostring(matchId))
        return {}
    end

    context = type(context) == 'table' and context or {}
    local payouts, houseCut = Arena.ComputePayouts({
        pot = pot,
        players = context.players,
        winners = context.winners,
        teams = context.teams,
        contestants = context.contestants,
    })

    local refundingEveryone = #payouts > 0
    for _, payout in ipairs(payouts) do
        if not isRefundReason(payout.reason) then
            refundingEveryone = false
            break
        end
    end
    if refundingEveryone then
        ArenaLog('betting: match %s refunded its pot of %s instead of paying out -- %s. Fought by %d, %d winner(s), Config.Betting.minPlayersToPayOut = %d.',
            tostring(matchId), money(pot), tostring(payouts[1].reason),
            math.max(#(context.players or {}), Arena.ToInt(context.contestants) or 0),
            #(context.winners or {}),
            Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0)

        ArenaBetting.RefundAll(matchId, payouts[1].reason)
        payoutWebhook('Pot refunded', 'The match did not qualify to pay out.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Pot', value = money(pot) },
            { name = 'Reason', value = tostring(payouts[1].reason) },
        })
        return payouts
    end

    local distributed = 0
    for _, payout in ipairs(payouts) do
        distributed = distributed + math.max(0, Arena.ToInt(payout.amount) or 0)
    end

    -- Arena.ComputePayouts cannot overspend the pot it was handed, so this
    -- only trips when the caller's player list disagrees with escrow. The
    -- honest answer to that is everyone's own stake back, not a guess.
    if (distributed + houseCut) > pot then
        ArenaLog('SETTLE REFUSED: match %s computed %d + %d house against a held pot of %d. Refunding instead.',
            tostring(matchId), distributed, houseCut, pot)
        ArenaBetting.RefundAll(matchId, 'refund_settle_mismatch')
        return {}
    end

    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            stake.settled = true
            stake.settledAs = 'payout'
        end
    end

    ArenaLog('betting: match %s paid out %s of a %s pot to %d player(s) (%s), house kept %s.',
        tostring(matchId), money(distributed), money(pot), #payouts,
        tostring(Config.Betting.payout or 'winner_takes_all'), money(houseCut))

    local paidFrom, citizenOf, nameOf = {}, {}, {}
    for id, stake in pairs(stakesOf(matchId)) do
        paidFrom[id] = stake.account
        citizenOf[id] = stake.citizenid
        nameOf[id] = stake.name
    end

    local lines, undelivered = {}, 0
    for _, payout in ipairs(payouts) do
        local amount = math.max(0, Arena.ToInt(payout.amount) or 0)
        local winner = serverId(payout.id)
        if amount > 0 then
            if winner and credit(winner, amount, transaction('payout', matchId),
                nil, paidFrom[winner] or paidFrom[payout.id]) then
                lines[#lines + 1] = ('%s: %s (%s)'):format(ArenaPlayerName(winner), money(amount), tostring(payout.reason))
                trace('paid %d to %s on match %s (%s)',
                    amount, tostring(winner), tostring(matchId), tostring(payout.reason))
                ArenaNotifyKey(winner, 'notify.pot_won', 'success', money(amount))
            else
                undelivered = undelivered + amount

                local citizenid = citizenOf[payout.id] or citizenIdOf(payout.id)
                if owe(citizenid, payout.name or nameOf[payout.id] or payout.id, amount,
                    paidFrom[payout.id], 'pot_payout') then
                    ArenaLog('PAYOUT UNDELIVERED: %d owed to %s (citizenid %s) on match %s -- they are not on the server. It is on the unpaid ledger and will be paid when they come back; /arenaadmin can list it.',
                        amount, tostring(payout.id), tostring(citizenid), tostring(matchId))
                else
                    ArenaLog('PAYOUT LOST: %d owed to %s on match %s -- they are not on the server and there is no citizen id to file it against. Settle by hand.',
                        amount, tostring(payout.id), tostring(matchId))
                end
                incidentWebhook('Payout not delivered', 'A settled payout could not be paid to its winner.', {
                    { name = 'Match', value = tostring(matchId) },
                    { name = 'Player', value = tostring(payout.id) },
                    { name = 'Amount', value = money(amount) },
                })
            end
        end
    end

    payoutWebhook('Pot paid out', ('%d payout(s) from a pot of %s.'):format(#payouts, money(pot)), {
        { name = 'Match', value = tostring(matchId) },
        { name = 'Pot', value = money(pot) },
        { name = 'House cut', value = money(houseCut) },
        { name = 'Undelivered', value = money(undelivered) },
        { name = 'Payouts', value = #lines > 0 and table.concat(lines, '\n') or 'none' },
    })

    return payouts
end

function ArenaBetting.GetSideBetPool(matchId)
    local total = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.settled ~= true and bet.mode ~= 'odds' then
            total = total + (Arena.ToInt(bet.amount) or 0)
        end
    end
    return total
end

function ArenaBetting.GetPrizePool(matchId)
    local pot = ArenaBetting.GetPot(matchId)
    if not entryPotJoinsPool() then return pot end
    return pot + ArenaBetting.GetSideBetPool(matchId)
end

--- One player's own side-bet on a match, or nil.
---
--- THE PANEL COULD NOT SEE ITS OWN BET. Side-bets are kept in this file and
--- nothing carried them into the snapshot, so a player who placed one
--- watched their money leave and the screen say nothing: no stake, no side,
--- no way to tell a bet that was taken from one that was refused. The pot on
--- that screen is the ENTRY pot and deliberately does not move for a
--- side-bet -- two pools, and conflating them is its own confusion -- which
--- left nothing at all to change.
--- @param matchId string
--- @param src any
--- @return table|nil -- { amount, pick, kind, account }
function ArenaBetting.GetSideBet(matchId, src)
    local id = serverId(src)
    if not id then return nil end

    for _, bet in ipairs(sideBets[matchId] or {}) do
        -- The one they CHOSE. An entry fee folded into the pool at settle
        -- time is not a bet they placed and must not be shown as one.
        -- AND NOT ONE THAT HAS ALREADY BEEN SETTLED. returnSideBet does not
        -- delete a row, it marks it -- `bet.settled = true` -- so a bet that
        -- has been handed back was still reported here as money on the
        -- result. ArenaLobby.UpdateMatch used to return every side-bet when
        -- the host changed the mode, and the panel then went on printing "You
        -- have $500 on crimson." over a stake that was back in the player's
        -- wallet, backing a side the match no longer has. That refund is gone
        -- -- the mode change is refused instead -- but a bet still comes back
        -- through half a dozen other doors, and this is the check that keeps
        -- the panel honest about every one of them.
        if bet.src == id and not bet.settled and bet.fromEntryFee ~= true then
            return {
                amount = bet.amount,
                pick = bet.pick,
                kind = bet.kind,
                account = bet.account,
            }
        end
    end
    return nil
end

function ArenaBetting.HoldsSideBet(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false end
    return holdsSideBet(matchId, id)
end

--- Every match this player currently has an unsettled side-bet on.
---
--- THE PANEL CANNOT WORK THIS OUT FOR ITSELF. `player.bet` in the snapshot
--- reports one bet -- the one on the match they are IN or WATCHING -- and a
--- side-bet is placed from the Bets tab on a match they are doing neither
--- with. So the Join button on a match the player had money on stayed lit,
--- and clicking it came back "Fighters do not bet on themselves.", which is
--- not what they did and not why they were refused.
---
--- An array rather than one id: one bet per match is a rule, one bet per
--- PLAYER is not, and a player watching the board can have money on several
--- lobbies at once.
--- @param src any
--- @return string[] matchIds
function ArenaBetting.MatchesBackedBy(src)
    local id = serverId(src)
    local out = {}
    if not id then return out end

    for matchId, bets in pairs(sideBets) do
        for _, bet in ipairs(bets) do
            if bet.src == id and not bet.settled and bet.fromEntryFee ~= true then
                out[#out + 1] = matchId
                break
            end
        end
    end
    return out
end

function ArenaBetting.HasSpectatorBet(matchId, src)
    local id = serverId(src)
    if not id then return false end
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == id and not bet.settled then return true end
    end
    return false
end

local function payoutMode(kind)
    local block = Config.Betting.betPayout
    local wanted = type(block) == 'table'
        and block[kind == 'fighter' and 'fighters' or 'spectators']
        or nil
    return wanted == 'odds' and 'odds' or 'pool'
end

local function fighterBetsOn()
    local block = Config.Betting.fighterBets
    return type(block) == 'table' and block.enabled == true
end

local function spectatorCeiling()
    local rules = Config.Betting.spectatorBets
    if type(rules) ~= 'table' or rules.enabled ~= true then return nil end

    local minimum = math.max(0, Arena.ToInt(rules.min) or 0)
    return math.max(minimum, Arena.ToInt(rules.max) or minimum)
end

local function ownSideOf(match, src)
    local row = type(match.players) == 'table' and match.players[src] or nil
    if not row then return nil end
    if Arena.ModeUsesTeams(match.modeKey) and Arena.IsKey(row.team) then return row.team end
    return tostring(src)
end

local function voided(bet, fighters)
    -- NOT ON THE FINAL ROSTER, WHICH IS TWO DIFFERENT PEOPLE.
    --
    -- A spectator who never joined, judged on the pick they chose -- which is
    -- what this line was written for -- and a FIGHTER who placed a bet at the
    -- fighter band and then came off the roster, who was judged on the same
    -- terms and should not have been. That second one was a live exploit:
    -- fighterBets.max ships at twice spectatorBets.max, so a fighter could
    -- take a 50,000 position, walk out of the lobby for nothing, and settle
    -- it against a field nobody else could put more than 25,000 into.
    --
    -- THE ANSWER IS NOT HERE, and deliberately so. Voiding it would hand the
    -- stake back, which is the exact refund ArenaBetting.MarkWalkedOut exists
    -- to withhold -- a wager you can cancel once it is going badly is not a
    -- wager. And trimming it here is too late: the pools above have already
    -- been totalled and every winner's share is a proportion of them, so
    -- shrinking a stake at settlement would move other people's money.
    --
    -- So the band is enforced at the moment the fact changes instead.
    -- MarkWalkedOut trims the stake to what a non-fighter may hold, returns
    -- the difference, and re-files the bet as a spectator's. By the time this
    -- runs there is nothing left to correct, and this line is once again
    -- about the only person it was ever about.
    local row = fighters[bet.src]
    if not row then return false end

    if bet.fromEntryFee == true then return false end

    if not fighterBetsOn() then return true end
    if (Config.Betting.fighterBets or {}).ownSideOnly == false then return false end

    local team = type(row) == 'table' and row.team or nil
    local own = Arena.IsKey(team) and team or tostring(bet.src)
    return bet.pick ~= own
end

local function poolKeyFor(kind)
    local block = Config.Betting.betPayout
    if type(block) == 'table' and block.sharedPool == false then return kind end
    return 'all'
end

function ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)
    if not ArenaBetting.IsEnabled() then return false, 'error.betting_disabled' end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    local match = lobbyMatch(matchId)
    if not match then return false, 'error.match_not_found' end

    local isFighter = type(match.players) == 'table' and match.players[id] ~= nil
    if isFighter and not fighterBetsOn() then
        return false, 'error.bet_not_spectator'
    end

    -- THE AMOUNT IS CHECKED AGAINST THE RIGHT BAND, which means it cannot be
    -- checked until we know which kind of bet this is.
    --
    -- It used to be resolved at the top of this function, before `isFighter`
    -- existed, and always against Config.Betting.spectatorBets. Every other
    -- rule below already picks the right block -- ownSideOnly and
    -- oneBetPerMatch both do -- and the amount was the one that did not. On
    -- the shipped config that refused every fighter stake over 25,000 while
    -- the panel, which is sent fighterBets.max, was offering 50,000; and
    -- with spectatorBets switched off it refused fighter bets entirely,
    -- with a message about side-bets being off.
    --
    -- WRITTEN AS AN IF RATHER THAN `isFighter and X or Y`, deliberately.
    -- That idiom collapses to Y whenever X is nil -- which here is exactly
    -- the refused-bet case -- so a fighter over their band would have
    -- silently fallen through to the spectator check. It is the single
    -- commonest defect in this codebase and it is not worth being clever
    -- about.
    local stake, reason
    if isFighter then
        stake, reason = Arena.ResolveFighterBet(amount)
    else
        stake, reason = Arena.ResolveSpectatorBet(amount)
    end
    if not stake then return false, reason or 'error.bet_invalid' end

    if not betsAreOpen(match, isFighter) then return false, 'error.bets_closed' end

    local wanted = canonicalPick(pick)
    if not wanted or not pickExists(match, wanted) then return false, 'error.bet_invalid_pick' end

    -- A FIGHTER MAY ONLY BACK THEIR OWN SIDE, when the operator says so.
    -- Backing the other side is a way to be paid for losing on purpose, and
    -- an arena is exactly where that is worth doing.
    if isFighter and (Config.Betting.fighterBets or {}).ownSideOnly ~= false then
        local own = ownSideOf(match, id)
        if own and wanted ~= own then return false, 'error.bet_not_own_side' end
    end

    local rules = isFighter and (Config.Betting.fighterBets or {})
        or (Config.Betting.spectatorBets or {})
    if rules.oneBetPerMatch ~= false and ArenaBetting.HasSpectatorBet(matchId, id) then
        return false, 'error.bet_already_placed'
    end

    local took, paidFrom = debit(id, stake, transaction('sidebet', matchId), account)
    if not took then
        return false, 'error.not_enough_money'
    end

    local kind = isFighter and 'fighter' or 'spectator'

    sideBets[matchId] = sideBets[matchId] or {}
    sideBets[matchId][#sideBets[matchId] + 1] = {
        src = id,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
        pick = wanted,
        amount = stake,
        account = paidFrom,
        kind = kind,
        mode = payoutMode(kind),
        placedAt = os.time(),
        settled = false,
    }

    trace('took side-bet of %d from %s on "%s" in match %s',
        stake, tostring(id), wanted, tostring(matchId))
    ArenaNotifyKey(id, 'notify.spectator_bet_placed', 'info', money(stake))

    -- THE ONE MONEY MOVEMENT THAT NEVER REFRESHED THE PANEL. Everything else
    -- that takes or returns money runs through a lobby path that broadcasts
    -- afterwards; a side-bet is placed from the Bets tab and settled here,
    -- and nothing told anyone. So the bettor was left reading their balance
    -- from before the bet and a pot that did not include it, until some
    -- unrelated change to the lobby happened to refresh them.
    --
    -- Guarded the way lobbyMatch above guards: this file loads before
    -- server/lobby.lua, so the global is checked rather than assumed.
    if type(ArenaLobby) == 'table' and type(ArenaLobby.Broadcast) == 'function' then
        ArenaLobby.Broadcast()
    end

    return true, nil
end

--- How many unsettled side-bets are riding on this match.
---
--- THE BOOK, AS A NUMBER, so a caller that must not change the shape of a
--- match under the people who backed it can ask whether anybody has.
---
--- IT REPLACED A REFUND, and the refund was the defect. ArenaLobby.UpdateMatch
--- used to hand the WHOLE BOOK back whenever the host changed the mode --
--- correct on its own, because a bet naming a side the match no longer has
--- cannot be judged -- but the host is a fighter with money on the outcome
--- and flipping the mode cost them nothing and could be done again a second
--- later. That is a "cancel everyone's bets" button, theirs alone, pressable
--- the moment the book turns against them. Nothing had to be exploited; it
--- was simply what the setting did.
---
--- So the mode is refused instead, and this is the question that refuses it.
--- An honest host -- an open lobby nobody has backed -- gets the same free
--- hand they always had, because the answer is zero.
---
--- Entry-fee rows are not bets anybody placed and are not counted. Settle
--- writes them at the moment the round is decided, so one cannot exist while
--- a lobby is still editable anyway.
--- @param matchId string
--- @return integer
function ArenaBetting.CountSideBets(matchId)
    local count = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled and bet.fromEntryFee ~= true then count = count + 1 end
    end
    return count
end

--- Marks every unsettled bet this player is holding on this match as one
--- placed by somebody who then walked out of it.
---
--- WHAT IT IS FOR, AND IT IS A HOLE THE REFUND BELOW OPENS RATHER THAN ONE
--- IT FOUND. A fighter backing themselves picks their own server id, so
--- their bet and a spectator's bet on them name the SAME pick. Returning
--- everything on that pick when they leave hands the fighter their own wager
--- back -- and a wager you can cancel once it is going badly is not a wager,
--- it is free money with an exit. `fighterBets` ships ON, so that is the
--- default configuration.
---
--- The spectator's case is the exact opposite, and is the reason the refund
--- exists: their pick died through somebody else's act, with nothing they
--- could have done about it. This is the one line that tells the two apart.
---
--- MARKED RATHER THAN SETTLED. The bet is still live and still judged at
--- settlement the way it always was -- the holder is no longer a fighter, so
--- `voided` passes it through, and a pick that did not win loses. All this
--- withholds is the refund.
---
--- It also closes the second departure: two players on one side who both
--- backed it, both leaving, would otherwise see the first one's bet returned
--- when the second emptied the side.
---
--- AND IT IS WHERE THE FIGHTER BAND LAPSES, which is the other half of the
--- same fact and was missing for as long as fighter bets have existed.
---
--- A fighter's stake is held to Config.Betting.fighterBets, which ships at
--- TWICE the spectator ceiling. That is not a bonus, it is the price of being
--- in the fight: the money is riding on a round the holder has to stand up
--- in. Take the holder off the roster and every reason for the larger number
--- goes with them -- but the stake did not move, and nothing re-read the
--- band, so a fighter could put down 50,000, walk out of the lobby for
--- nothing (the shipped entry fee is zero), and settle a fighter-sized
--- position against a field capped at 25,000. On the shipped config that paid
--- the leaver the honest spectator's whole stake.
---
--- TRIMMED, NOT VOIDED. Handing the bet back is the refund the whole function
--- exists to withhold. What is returned is only the part the fighter band
--- alone ever justified; what is left is a position any onlooker could have
--- taken, judged on the pick the holder chose, and it still loses if that
--- pick loses. Exactly the bet PlaceSpectatorBet would have written for them
--- one second after they left.
---
--- AND RE-FILED AS A SPECTATOR'S, because standing is what changed. With
--- betPayout.sharedPool off the two kinds settle in separate pools, and a
--- lone walked-out fighter left in the fighters' pool is the only bet in it
--- -- uncontested -- so SettleSpectatorBets hands the whole thing back and
--- undoes the trim. `mode` is deliberately NOT touched: that is who funds the
--- payout, which was agreed when the stake was taken, and changing it after
--- the fact would move a pool bet onto the operator's own money.
---
--- THE MONEY MOVES FIRST AND THE RECORD FOLLOWS. `bet.amount` is only cut
--- once the difference has actually been credited, or failing that filed
--- against the character on the unpaid ledger. A trim recorded over money
--- that went nowhere is money this resource has quietly destroyed.
--- @param matchId string
--- @param src any
--- @return integer marked
--- @return integer returned -- money handed back because the band lapsed
function ArenaBetting.MarkWalkedOut(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return 0, 0 end

    local ceiling = spectatorCeiling()
    local marked, returned = 0, 0

    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == id and not bet.settled and bet.fromEntryFee ~= true then
            bet.walkedOut = true
            marked = marked + 1

            if bet.kind == 'fighter' then
                if ceiling == nil then
                    local whole = Arena.ToInt(bet.amount) or 0
                    if returnSideBet(bet, matchId) then
                        returned = returned + whole
                        ArenaLog('SIDE-BET BAND LAPSED: %s left match %s and this server allows non-fighters no side-bet at all -- the whole %d went back.',
                            tostring(bet.name or id), tostring(matchId), whole)
                    end
                else
                    local held = Arena.ToInt(bet.amount) or 0
                    local excess = held - ceiling
                    if excess > 0 then
                        local paid = credit(id, excess, transaction('sidebet_trim', matchId),
                            bet.citizenid, bet.account)
                        if paid then
                            ArenaNotifyKey(id, 'notify.bet_trimmed', 'info', money(excess))
                        else
                            paid = owe(bet.citizenid, bet.name or id, excess, bet.account, 'sidebet_trim')
                            if paid then
                                ArenaLog('SIDE-BET TRIM DEFERRED: %d owed to %s (citizenid %s) on match %s -- recorded against their character and paid when they are next seen.',
                                    excess, tostring(bet.name or id), tostring(bet.citizenid), tostring(matchId))
                            end
                        end

                        if paid then
                            bet.amount = ceiling
                            returned = returned + excess
                            ArenaLog('SIDE-BET TRIMMED: %s left match %s holding a fighter stake of %d; the fighter band went with them, so %d was returned and %d stands as a spectator bet.',
                                tostring(bet.name or id), tostring(matchId), held, excess, ceiling)
                        else
                            ArenaLog('SIDE-BET TRIM FAILED: %d could not be returned to %s (citizenid %s) on match %s -- the bet stands at its full %d and is still held to the fighter band.',
                                excess, tostring(bet.name or id), tostring(bet.citizenid), tostring(matchId), held)
                            incidentWebhook('Side-bet band could not be trimmed',
                                'A fighter left a match holding a stake above the spectator ceiling and the difference could not be returned.', {
                                    { name = 'Match', value = tostring(matchId) },
                                    { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or id), tostring(bet.citizenid)) },
                                    { name = 'Held', value = money(held) },
                                    { name = 'Over the ceiling by', value = money(excess) },
                                })
                        end
                    end

                    bet.kind = 'spectator'
                end
            end
        end
    end

    return marked, returned
end

--- Returns every outstanding side-bet on one pick, because that pick can no
--- longer win.
---
--- THE SAME UNFAIRNESS AS A MODE CHANGE, ARRIVING BY A DIFFERENT DOOR.
--- Changing the mode of a lobby leaves every bet on it naming something that
--- cannot win, and such a bet must not simply lose: there is nothing on
--- screen saying so and no way for the bettor to have seen it coming. That
--- one is answered by refusing the change now -- see CountSideBets -- because
--- a host who could void the book on demand was worse than the loss. This
--- door cannot be refused the same way.
---
--- A FIGHTER WALKING OUT does exactly the same thing to the people who
--- backed them, and nothing was returning those. The bet was not voided and
--- not refunded -- it fell through every branch of SettleSpectatorBets to
--- the last `else` and was marked `lost`, and on the shipped config
--- (sharedPool, includeEntryPot) the pool is contested by the remaining
--- fighters' own entry fees, so the uncontested-pool refund could not catch
--- it either. The spectator's whole stake -- up to `spectatorBets.max` --
--- was handed to whoever backed the winner, and the only thing they were
--- told was "your pick went down", which is not what happened.
---
--- It is also the shape of a scam that runs itself: open a lobby with a
--- friend, talk the room into backing them, have them walk before the start,
--- win, collect. Nothing in the resource had to be exploited for that to
--- work; it was simply how a departed pick settled.
---
--- Entry-fee rows are skipped. They are written by Settle at the moment the
--- round is decided and cannot exist while somebody is still leaving -- but
--- one is a stake escrowed in the pot rather than a bet anybody placed, and
--- handing it back here would take money out of a pot the survivors are
--- fighting for.
--- @param matchId string
--- @param pick any -- a team key, or a fighter's server id as a string
--- @return integer returned
--- @return integer owed -- money that could not be handed back
function ArenaBetting.ReturnBetsOn(matchId, pick)
    local returned, owed = 0, 0
    if not Arena.IsKey(matchId) or pick == nil then return 0, 0 end

    local wanted = canonicalPick(pick)
    if not wanted then return 0, 0 end

    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled and bet.fromEntryFee ~= true and bet.walkedOut ~= true
            and bet.pick == wanted then
            if returnSideBet(bet, matchId) then
                returned = returned + 1
            else
                owed = owed + (Arena.ToInt(bet.amount) or 0)
            end
        end
    end

    return returned, owed
end

function ArenaBetting.SettleSpectatorBets(matchId, winningPick)
    local bets = sideBets[matchId]
    if type(bets) ~= 'table' then return 0, 0, {} end

    local fighters = fightersOf(matchId) or {}
    local wanted = canonicalPick(winningPick)
    local paid, total, kept, lines = 0, 0, 0, {}
    local earnings = {}

    -- THE POOLS, built before anything is paid.
    --
    -- A pool bet is paid with other bettors' money and nothing else, so the
    -- pool has to be known in full before the first payment leaves -- and the
    -- winners' stakes with it, because a share is a proportion of the whole.
    -- Working it out as we go would pay the first winner out of a pool that
    -- had not finished being counted.
    --
    -- 'odds' bets are deliberately absent from both. They are funded by the
    -- server, so letting one into the pool would pay it out of other people's
    -- stakes as well as the operator's pocket.
    local pools, winners, backed = {}, {}, {}
    for _, bet in ipairs(bets) do
        if not bet.settled and bet.mode ~= 'odds' and not voided(bet, fighters) then
            local key = poolKeyFor(bet.kind or 'spectator')
            local stake = Arena.ToInt(bet.amount) or 0
            pools[key] = (pools[key] or 0) + stake

            if wanted and bet.pick == wanted then
                winners[key] = winners[key] or {}
                winners[key][#winners[key] + 1] = bet
                backed[key] = (backed[key] or 0) + stake
            end
        end
    end

    local uncontested = {}
    for key, pool in pairs(pools) do
        if (backed[key] or 0) >= pool then uncontested[key] = true end
    end

    for key, pool in pairs(pools) do
        local list = winners[key]
        if list and #list > 0 then
            local stakes = {}
            for index, bet in ipairs(list) do stakes[index] = bet.amount end
            local shares = Arena.SplitByStake(pool, stakes)
            for index, bet in ipairs(list) do bet.poolShare = shares[index] or 0 end
        end
    end

    for _, bet in ipairs(bets) do
        if not bet.settled then
            if voided(bet, fighters) then
                ArenaLog('SIDE-BET VOID: %s backed "%s" on match %s and then fought in it -- returning %d unjudged.',
                    tostring(bet.name or bet.src), tostring(bet.pick), tostring(matchId), bet.amount)
                returnSideBet(bet, matchId)
            elseif not wanted then
                returnSideBet(bet, matchId)
            elseif bet.mode ~= 'odds' and uncontested[poolKeyFor(bet.kind or 'spectator')] then
                ArenaLog('SIDE-BET UNCONTESTED: nobody bet against %s on match %s -- returning %d.',
                    tostring(bet.name or bet.src), tostring(matchId), bet.amount)
                returnSideBet(bet, matchId)
            elseif bet.pick == wanted then
                local amount = (bet.mode == 'odds')
                    and Arena.ComputeSpectatorPayout(bet.amount)
                    or (Arena.ToInt(bet.poolShare) or 0)
                -- Marked before the payment for the same reason the pot is:
                -- a settlement that runs twice must not pay twice.
                bet.settled = true
                bet.settledAs = 'won'
                paid = paid + 1
                total = total + amount
                earnings[bet.src] = (earnings[bet.src] or 0) + amount
                if amount > 0 and credit(bet.src, amount, transaction('sidebet_payout', matchId),
                    bet.citizenid, bet.account) then
                    lines[#lines + 1] = ('%s: %s on "%s"'):format(tostring(bet.name or bet.src), money(amount), bet.pick)
                    ArenaNotifyKey(bet.src,
                        bet.fromEntryFee == true and 'notify.pot_won' or 'notify.spectator_bet_won',
                        'success', money(amount))
                elseif amount > 0 then
                    owe(bet.citizenid, bet.name or bet.src, amount, bet.account, 'sidebet_payout')

                    ArenaLog('SIDE-BET PAYOUT UNDELIVERED: %d owed to %s (citizenid %s) on match %s. It is on the unpaid ledger and will be paid when they come back.',
                        amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
                    incidentWebhook('Side-bet payout not delivered',
                        'A winning spectator side-bet could not be paid.', {
                            { name = 'Match', value = tostring(matchId) },
                            { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                            { name = 'Amount', value = money(amount) },
                        })
                end
            elseif bet.mode ~= 'odds' and not (winners[poolKeyFor(bet.kind or 'spectator')] or {})[1] then
                returnSideBet(bet, matchId)
            else
                bet.settled = true
                bet.settledAs = 'lost'
                if bet.mode == 'odds' then kept = kept + bet.amount end
                ArenaNotifyKey(bet.src,
                    bet.fromEntryFee == true and 'notify.stake_forfeited' or 'notify.spectator_bet_lost',
                    'error', money(bet.amount))
            end
        end
    end

    if paid > 0 or kept > 0 then
        trace('settled side-bets on match %s: %d winner(s) paid %d, %d kept',
            tostring(matchId), paid, total, kept)
        payoutWebhook('Side-bets settled', ('Winning pick: %s'):format(tostring(wanted)), {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Paid out', value = money(total) },
            { name = 'Kept', value = money(kept) },
            { name = 'Winners', value = #lines > 0 and table.concat(lines, '\n') or 'none' },
        })
    end

    return paid, total, earnings
end

function ArenaBetting.PayOutstanding(src)
    local id = serverId(src)
    if not id then return 0 end

    local player = ArenaGetPlayer(id)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil
    if not Arena.IsKey(citizenid) then return 0 end

    local row = unpaid[citizenid]
    if not row then return 0 end

    local paid, left = 0, {}
    for _, part in ipairs(row.parts) do
        if credit(id, part.amount, transaction(part.reason or 'refund_owed', 'owed'),
            citizenid, part.account) then
            paid = paid + part.amount
        else
            left[#left + 1] = part
        end
    end

    if paid > 0 then
        ArenaLog('betting: paid %s of money owed to %s (citizenid %s) that could not be delivered earlier.',
            money(paid), tostring(row.name or id), tostring(citizenid))
        ArenaNotifyKey(id, 'notify.stake_refunded', 'info', money(paid))
    end

    if #left > 0 then
        row.parts = left
        row.total = 0
        for _, part in ipairs(left) do row.total = row.total + part.amount end
    else
        unpaid[citizenid] = nil
    end

    return paid
end

function ArenaBetting.SweepUnpaid()
    if next(unpaid) == nil then return 0, 0 end

    local people, total = 0, 0
    for _, id in ipairs(GetPlayers()) do
        local src = Arena.ToInt(id)
        if src then
            local paid = ArenaBetting.PayOutstanding(src)
            if paid > 0 then
                people = people + 1
                total = total + paid
            end
        end
    end
    return people, total
end

function ArenaBetting.Outstanding()
    local characters, total = 0, 0
    for _, row in pairs(unpaid) do
        characters = characters + 1
        total = total + (row.total or 0)
    end
    return characters, total
end

CreateThread(function()
    local seconds = Arena.ToInt(Config.Betting.refundRetrySeconds)
    if seconds == nil then seconds = 30 end

    if seconds <= 0 then return end

    while true do
        Wait(seconds * 1000)
        ArenaBetting.SweepUnpaid()
    end
end)

function ArenaBetting.Clear(matchId)
    local owed = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled then
            ArenaLog('CLEAR: match %s had an unresolved side-bet of %d from %s -- returning it.',
                tostring(matchId), bet.amount, tostring(bet.name or bet.src))
            if not returnSideBet(bet, matchId) then owed = owed + bet.amount end
        end
    end

    local held = ArenaBetting.GetPot(matchId)
    if held > 0 then
        ArenaLog('CLEAR REFUSED: match %s still holds %d in escrow. Settle or refund it first -- nothing was dropped.',
            tostring(matchId), held)
        incidentWebhook('Match cleared while holding escrow',
            'A match was cleared while its pot was still held. The escrow was kept.', {
                { name = 'Match', value = tostring(matchId) },
                { name = 'Held', value = money(held) },
            })
    end
    if owed > 0 then
        ArenaLog('CLEAR REFUSED: match %s still owes %d in side-bets that could not be returned. Nothing was dropped.',
            tostring(matchId), owed)
    end
    if held > 0 or owed > 0 then return false end

    escrow[matchId] = nil
    sideBets[matchId] = nil
    return true
end
