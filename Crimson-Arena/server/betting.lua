--[[
    crimson_arena/server/betting.lua

    The only file in this resource that moves money.

    ESCROW, NOT BOOKKEEPING. A stake leaves the player's account the moment
    they lock in and is held here against a match id. From then on the money
    exists in exactly one place -- this file's tables -- until RefundOne,
    RefundAll or Settle hands it back out. Nothing anywhere reads a balance to
    work out what is owed, because a balance is a running total, and a running
    total cannot tell a refund that happened twice from one that never
    happened at all.

    THE INVARIANT: no sequence of join / leave / disconnect / match-abort /
    resource-stop may create or destroy a single dollar. What holds it up:
      - a stake is recorded only AFTER the removal actually succeeded;
      - a settled stake is marked rather than deleted, so a second payout of
        it is refused and printed instead of silently doubled, and only
        `Clear` -- once nothing is owed -- drops the record;
      - a stake the operator's config forfeits is marked settled and kept
        rather than quietly dropped from the books: it is the one movement
        here that ends with nobody credited, so it is logged and sent to the
        webhook every time. ForfeitAll says where that money goes and why;
      - money that cannot be handed back stays on the books and stays loud;
      - `Clear` refuses to drop a match that still holds anything. A leaked
        table entry is a bug someone can find later; a swallowed pot is one
        nobody can.

    TWO SEPARATE POOLS. The entry-fee pot is what the fighters are playing
    for; `maxPot` caps it and only it. Spectator side-bets are house action
    paid at `oddsMultiplier` and live in their own table, because a side-bet
    that reached the pot would let a bystander change what the winner takes
    home.

    All of the maths -- what a fee may be, what the house takes, how a pot
    splits, what a winning side-bet returns -- belongs to shared/arena.lua.
    This file decides only WHERE money goes and WHETHER it has already gone.
]]

ArenaBetting = {}

-- ======================================================================
-- STATE
-- ======================================================================

--- Held entry fees.
--- [matchId] = { [src] = { amount, citizenid, name, takenAt, settled, settledAs, reason } }
local escrow = {}

--- Spectator side-bets, an array per match rather than a map by player:
--- `oneBetPerMatch = false` is a supported setting, so one person may
--- legitimately hold several at once.
--- [matchId] = { { src, citizenid, name, pick, amount, placedAt, settled, settledAs } }
local sideBets = {}

-- ======================================================================
-- MOVEMENT PRIMITIVES
-- ======================================================================

--- Routine movements are traced only when the operator asked for noise.
--- Everything that prints unconditionally below is a failure, and a failed
--- movement is never routine.
local function trace(fmt, ...)
    if Config.Debug then ArenaLog(fmt, ...) end
end

--- Player-facing money, in the operator's currency.
--- @param amount any
--- @return string
local function money(amount)
    return ('%s%d'):format(Config.Betting.currencySymbol or '$', math.max(0, Arena.ToInt(amount) or 0))
end

--- Server ids arrive from event handlers, from match contexts and from the
--- wire. Normalising every one of them means escrow is never keyed by 5 in
--- one place and "5" in another.
--- @param value any
--- @return integer|nil
local function serverId(value)
    local id = Arena.ToInt(value)
    if not id or id <= 0 then return nil end
    return id
end

--- The stable identity behind a server id, captured while the player is
--- still connected: an id means nothing once they have gone, and them being
--- gone is exactly when somebody has to work out who is owed what.
--- @param src integer
--- @return string|nil
local function citizenIdOf(src)
    local player = ArenaGetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

--- What one player currently holds in the account bets are settled in, or
--- nil when it cannot be read.
--- @param player table|nil
--- @return integer|nil
local function balanceOf(player, account)
    -- Named `wallet` rather than `money`: this file already has a `money`
    -- upvalue for formatting figures, and one shadowing the other is a
    -- misread waiting to happen in a file where every variable is currency.
    local wallet = player and player.PlayerData and player.PlayerData.money
    if type(wallet) ~= 'table' then return nil end
    return Arena.ToInt(wallet[account or Config.Betting.account])
end

--- The accounts money may be TAKEN from, in the order they are tried.
---
--- One name was 'cash' and nothing else, so a player with the price in the
--- bank and nothing in their pocket was told they could not afford it.
--- Falling back to a list keeps the old single-account behaviour for a
--- server that never sets one.
--- @return string[]
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

--- The accounts a player may be asked to choose between, in the operator's
--- own order. Exported because the panel has to draw the choice and the
--- server is the only thing that knows which names are real.
--- @return string[]
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

--- Did `amount` actually move, in the direction expected?
---
--- WHY THIS DOES NOT JUST READ THE RETURN VALUE. It used to, and required it
--- to be exactly `true` -- and a framework function that returns nil on
--- success, as some builds of these do, then read as failure. The
--- consequences were not symmetrical and not obvious: money was taken from
--- the player and the stake was recorded as never taken, so the pot stayed
--- empty and a match nobody appeared to have paid for paid nobody out. Every
--- test passed throughout, because the fixture returned `true` like the
--- documentation says and unlike the server.
---
--- So the balance is the authority. `>=` rather than `==` because another
--- resource may move the same account in the same instant, and the question
--- here is only whether OUR movement happened.
--- @param before integer|nil
--- @param after integer|nil
--- @param amount integer
--- @param outward boolean
--- @return boolean|nil moved -- nil when the balance could not be read
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

--- Money OUT. False means nothing moved, so the caller must record nothing --
--- otherwise escrow claims a stake the player still has in their pocket.
--- @param preferred string|nil -- the account the player picked, if they did
--- @return boolean took
--- @return string|nil account -- which one it came out of, for the refund
local function debit(src, amount, reason, preferred)
    local player = ArenaGetPlayer(src)
    if not player then return false, nil end

    -- WHOLE AMOUNT FROM ONE ACCOUNT, never split across two.
    --
    -- A split debit has a failure mode nothing else here does: half the
    -- money leaves, the second half is refused, and the player is out of
    -- pocket for a stake that was never taken. Refunding a split is also two
    -- movements that can each fail independently. One account or none is the
    -- honest trade -- and it keeps a refund a single, reversible movement to
    -- the place the money came from.
    local accounts = accountsFor(player, preferred)
    if not accounts then
        -- Named rather than silent: from the player's side this is a
        -- payment that did nothing, and the only person who can fix it is
        -- the operator whose account list no longer has what the panel
        -- offered.
        ArenaLog('betting: refused a payment from \'%s\' -- that account exists for this player but is not one Config.Betting.accounts lets this server debit. Nothing was taken from the other one.',
            tostring(preferred))
        return false, nil
    end

    for _, account in ipairs(accounts) do
        local before = balanceOf(player, account)

        -- Skipped rather than attempted when it plainly cannot cover it, so
        -- an unaffordable first account does not produce a framework refusal
        -- that looks like an error in the log.
        if before == nil or before >= amount then
            local answer = player.Functions.RemoveMoney(account, amount, reason)

            -- An explicit refusal is believed immediately: it is the one
            -- answer that means something unambiguous, and re-reading a
            -- balance to second-guess it would only find the money still
            -- there and agree.
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

--- Money IN. False means the player could not be paid, almost always because
--- they have left the server. What to do about that differs between a refund
--- (still held, still owed, try again later) and a payout (the pot has
--- already been divided, so it is logged instead), which is why this returns
--- the failure rather than handling it.
---
--- `citizenid` is the identity captured against that money when it was
--- taken, and it is checked here because a server id is a slot rather than a
--- person: FXServer hands a departed player's id to the next connection, and
--- a stake outlives its owner exactly when they have gone. An id that now
--- answers to somebody else is therefore "not on the server", not "here
--- under a new name" -- so the caller takes the branch it already has for
--- money it could not deliver, which says out loud who is still owed, rather
--- than paying a stranger quietly. Money recorded without an identity passes
--- nil and is paid on the id alone.
--- @return boolean
--- @param account string|nil -- where it came from; a refund goes back there
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

--- The transaction note qbx_core stores next to the movement. Operator
--- facing, in one shape, so a server log can be grepped for one match id.
local function transaction(kind, matchId)
    return ('crimson_arena:%s:%s'):format(kind, tostring(matchId))
end

--- Discord log of an ordinary, successful movement.
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

-- ======================================================================
-- LOOKUPS
-- ======================================================================

--- Read-only view of what a match holds. Never write through it -- the empty
--- fallback is a throwaway.
--- @return table<integer, table>
local function stakesOf(matchId)
    return escrow[matchId] or {}
end

--- A pick reaches this file as a team key or a fighter's server id from the
--- panel, and comes back from the match as whatever that match decided a
--- winner is -- possibly a number where the wire carried a string. Comparing
--- canonical forms is what stops "3" ~= 3 quietly voiding every side-bet in
--- a free-for-all.
--- @param value any
--- @return string|nil
local function canonicalPick(value)
    if type(value) == 'number' then
        local id = Arena.ToInt(value)
        return id and tostring(id) or nil
    end
    if Arena.IsKey(value) then return value end
    return nil
end

--- The lobby owns the match registry; this file only ever reads it, and only
--- at run time, long after both files have loaded. It reads it at all because
--- a side-bet on a match that does not exist, on a fighter who is not in it,
--- or after the window shut is money taken for nothing -- and the player who
--- would notice is the one it was taken from.
--- @return table|nil
local function lobbyMatch(matchId)
    if type(ArenaLobby) ~= 'table' or type(ArenaLobby.Get) ~= 'function' then return nil end
    local match = ArenaLobby.Get(matchId)
    if type(match) ~= 'table' then return nil end
    return match
end

--- The players a match currently has seated, or nil when the registry
--- cannot answer at all. The two callers below want opposite things from
--- "cannot answer" -- one treats it as seated, the other as not a fighter --
--- so that choice stays theirs rather than being flattened into an empty
--- table here.
--- @return table<integer, table>|nil
local function fightersOf(matchId)
    local match = lobbyMatch(matchId)
    if not match or type(match.players) ~= 'table' then return nil end
    return match.players
end

--- Whether this player has money riding on the outcome of this match as a
--- spectator. A settled bet does not count: it has already been paid, lost
--- or handed back, so it is no longer money on the result.
--- @return boolean
local function holdsSideBet(matchId, src)
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == src and not bet.settled then return true end
    end
    return false
end

--- Whether side-bets on this match are still open: all through the lobby and
--- the countdown, then `closeAfterStartSeconds` into the live round
--- (0 = closed the moment it begins).
---
--- `startsAt` is stamped by server/match.lua in epoch seconds (os.time), the
--- same clock read here -- NOT GetGameTimer, which server/util.lua's rate
--- limiter uses for its own monotonic purposes and which would silently
--- compare against the wrong scale. A live match whose start this clock cannot read -- missing, or
--- somehow still in the future -- closes the window rather than leaving it
--- open, because a window that cannot be timed cannot be closed, and an
--- uncloseable window is free money for anyone watching the scoreboard.
--- @return boolean
local function betsAreOpen(match)
    local state = match.state
    if state == 'lobby' or state == 'countdown' then return true end
    if state ~= 'live' then return false end

    local spectator = Config.Betting.spectatorBets or {}
    local grace = math.max(0, Arena.ToInt(spectator.closeAfterStartSeconds) or 0)
    local startedAt = Arena.ToInt(match.startsAt)
    local now = os.time()
    if not startedAt or startedAt > now then return false end
    return (now - startedAt) < grace
end

--- A pick has to be something that can actually win: an enabled team that
--- somebody is standing on, or a fighter really in the match. Backing an
--- empty team is not a bet, it is a donation.
--- @return boolean
local function pickExists(match, pick)
    local players = type(match.players) == 'table' and match.players or {}

    if Arena.ModeUsesTeams(match.modeKey) then
        if not Arena.GetTeamByKey(pick) then return false end
        for _, player in pairs(players) do
            if player.team == pick then return true end
        end
        return false
    end

    for id in pairs(players) do
        if canonicalPick(id) == pick then return true end
    end
    return false
end

--- @return boolean
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

--- Hands one unresolved side-bet back, once. Shared by the no-result
--- settlement and by Clear so both take identical care about paying twice.
--- @return boolean paid
local function returnSideBet(bet, matchId)
    if bet.settled then return false end

    -- `bet.account` -- the account the stake actually LEFT. Dropped here, the
    -- refund fell to whichever account the operator lists first, so a bet
    -- paid from the bank came back as cash. That is not a rounding error: it
    -- is a laundering route through the arena, and credit() says so in as
    -- many words directly above the branch that was never being reached.
    if not credit(bet.src, bet.amount, transaction('sidebet_refund', matchId),
        bet.citizenid, bet.account) then
        ArenaLog('SIDE-BET REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the bet stays held.',
            bet.amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
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

-- ======================================================================
-- ENTRY FEES
-- ======================================================================

--- @return boolean
function ArenaBetting.IsEnabled()
    return Config.Betting.enabled == true
end

--- What a match is holding right now. Refunded and settled stakes are gone
--- from it, which is what gives `Clear`'s check something real to test.
--- @param matchId string
--- @return integer pot
function ArenaBetting.GetPot(matchId)
    local total = 0
    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then total = total + stake.amount end
    end
    return total
end

--- One player's share of the held pot -- 0 once it has been refunded or paid
--- out, because at that point this match holds nothing of theirs.
--- @param matchId string
--- @param src integer
--- @return integer stake
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

    -- A SEAT AND A SIDE-BET ON THE SAME MATCH ARE EXCLUSIVE, and this is the
    -- half of that rule ordering used to walk round: PlaceSpectatorBet
    -- refuses a fighter, so the way in was to back the match first and take
    -- a seat afterwards. It is the door that closes rather than the bet that
    -- is handed back, because a bet its holder can cancel at a moment of
    -- their choosing -- by joining and walking straight out again -- is a bet
    -- with no downside. SettleSpectatorBets voids what gets past here.
    if holdsSideBet(matchId, id) then return false, 'error.bet_not_spectator' end

    local fee, reason = Arena.ResolveEntryFee(amount)
    if not fee then return false, reason or 'error.bet_invalid' end
    if fee <= 0 then return true, nil end

    local held = stakesOf(matchId)[id]
    if held and not held.settled then
        -- An unsettled stake is not by itself a seat. Somebody who left a
        -- lobby under `refundOnDisconnectBeforeStart = false` forfeited their
        -- fee INTO this match's pot, and that record outlives their row --
        -- refusing on the record alone locked them out of a match with open
        -- seats for as long as it existed, printing another refusal at the
        -- operator on every retry. Their money is still in this pot, so
        -- sitting back down is not a second stake; it is the first one, never
        -- handed back, and nothing moves.
        --
        -- Both halves have to hold. The registry has to actually say the seat
        -- is empty -- no answer means seated, because a second take for one
        -- seat would remove the fee twice while only one of the two could
        -- ever be refunded -- and the stake has to be THIS player's, since an
        -- id belongs to whoever holds it now and seating a new connection on
        -- a departed player's money is the same bug pointed the other way.
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
        -- Which account ACTUALLY paid, so a refund goes back where the money
        -- came from rather than to whichever one this server happens to list
        -- first -- and never to whichever one was merely asked for. With a
        -- preference set the two are the same; without one they are not, and
        -- a refund to the requested account would be inventing money in a
        -- place the player never spent it from.
        account = paidFrom,
        takenAt = os.time(),
        settled = false,
    }

    trace('took stake of %d from %s for match %s (pot now %d)',
        fee, tostring(id), tostring(matchId), ArenaBetting.GetPot(matchId))
    ArenaNotifyKey(id, 'notify.stake_taken', 'info', money(fee))
    return true, nil
end

--- Returns exactly what was taken, exactly once.
--- @param matchId string
--- @param src integer
--- @param reasonKey string? -- audit reason recorded against the stake; the
---        player is told the amount, the caller owns the message about why
--- @return boolean ok
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

    -- `stake.account`, for the reason returnSideBet gives above. The escrow
    -- record has carried this field since accounts became a list, with a
    -- comment saying a refund goes back where the money came from -- and
    -- nothing read it. A fee paid from the bank was returned as cash.
    if not credit(id, stake.amount, transaction('refund', matchId),
        stake.citizenid, stake.account) then
        -- Left unsettled deliberately: this is money still held and still
        -- owed, so a later RefundAll tries again and Clear goes on refusing
        -- to drop the match until it lands. Writing it off here would be the
        -- one thing this file must never do.
        ArenaLog('REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the stake stays held.',
            stake.amount, tostring(stake.name or id), tostring(stake.citizenid), tostring(matchId))
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

--- Everybody still in escrow gets their own stake back -- their own, not an
--- even share of the pot. Escrow is the record of what each player actually
--- paid, and only the amount recorded against a stake can be handed back to
--- the player it was taken from; an even share balances the books while
--- quietly moving money between them.
--- @param matchId string
--- @param reasonKey string?
--- @return boolean ok -- true only when nothing is still owed
--- @return integer refunded -- stakes returned
--- @return integer total -- money returned
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

--- Keeps one player's stake in the pot rather than handing it back.
---
--- NOTHING MOVES, and that is the entire operation: the money is already
--- escrowed against this match, so leaving it exactly where it is IS the
--- forfeit. It stays inside ArenaBetting.GetPot, the players who stayed are
--- fighting for it, and Settle pays it out with the rest. Every path that
--- ends the match without a result still refunds it, so a stake forfeited to
--- a pot is never money nobody can reach.
---
--- The player is told, because a stake that is not coming back is not
--- something to work out from a balance -- and somebody who walked out of a
--- lobby is still on the server to hear it.
--- @param matchId string
--- @param src integer
--- @return integer kept -- 0 when this match holds nothing of theirs
function ArenaBetting.KeepInPot(matchId, src)
    local id = serverId(src)
    if not id then return 0 end

    local stake = stakesOf(matchId)[id]
    if not stake or stake.settled then return 0 end

    trace('kept %d of %s in the pot on match %s', stake.amount, tostring(id), tostring(matchId))
    ArenaNotifyKey(id, 'notify.stake_forfeited', 'error', money(stake.amount))
    return stake.amount
end

--- Keeps every held stake and pays nobody. The pot is forfeited.
---
--- WHERE THE MONEY GOES, exactly: nowhere. A forfeited pot is kept the way
--- the house cut of a settled pot and a losing side-bet are kept -- this file
--- has no house account to credit, so the money leaves the economy at the
--- point it leaves escrow. That is what `Config.Betting.refundOnCancel =
--- false` is FOR: it is a deterrent against a host filling a lobby,
--- collecting everybody's stake and closing it, and a deterrent that handed
--- the pot to someone would only move the abuse to whoever received it.
--- Every forfeit is logged and sent to the webhook whatever `logPayouts`
--- says, because an operator who runs a house account by hand is the only
--- person who can put this money anywhere.
---
--- Marked rather than deleted, like every other settlement here: a second
--- forfeit of the same stake keeps nothing twice, a later refund of it is
--- refused out loud, and `Clear` may drop a match that now genuinely holds
--- nothing -- which is what keeps its refusal to drop one that does worth
--- something.
--- @param matchId string
--- @param reasonKey string? -- audit reason recorded against each stake
--- @return integer forfeited -- stakes kept
--- @return integer total -- money kept
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

--- Whether entry fees are settled as bets rather than as a pot of their own.
--- @return boolean
local function entryPotJoinsPool()
    local block = Config.Betting.betPayout
    return type(block) == 'table' and block.includeEntryPot == true
end

--- Turns every unsettled entry stake into a pool bet on that player's own
--- side, and marks the stake settled so nothing can pay it twice.
---
--- RECORDED HERE, NOT WHEN THE FEE WAS TAKEN, and the difference matters: a
--- player's side is not final until the round is. A bet written at join time
--- would carry the team they picked then, and a player who switched sides --
--- or a mode the host changed under them -- would be judged against a side
--- they did not fight for.
---
--- The pick is their team in a team mode and their own id otherwise, which is
--- exactly what ownSideOnly means everywhere else in this file, so an entry
--- stake can never be voided as a bet against its own holder.
--- @param matchId string
--- @param context table
--- @return integer added
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
                -- Marked so the console and any later reader can tell a fee
                -- that became a bet from a bet somebody chose to place.
                fromEntryFee = true,
                placedAt = stake.takenAt,
                settled = false,
            }

            -- The pool owns it from here. GetPot reads this, so the pot is
            -- now empty and cannot be paid out a second time by any path.
            stake.settled = true
            added = added + 1
        end
    end

    return added
end

--- Pays the pot out. The match decides who won; this decides nothing but
--- where the money goes and whether it has gone already.
---
--- The pot comes from ESCROW, never from `context.pot`: the caller's idea of
--- the pot is a report, escrow is the fact, and paying out against a report
--- is how a pot ends up bigger than the money behind it.
--- @param matchId string
--- @param context table -- Arena.ComputePayouts' context: { players = { { id, team, kills, stake, placement } }, winners = { id }, teams = boolean, contestants = integer }
--- @return table[] payouts -- { { id, amount, reason } } as computed
function ArenaBetting.Settle(matchId, context)
    if not Arena.IsKey(matchId) then return {} end

    -- THE ENTRY FEES AS BETS, when the operator has said so.
    --
    -- Each fighter's stake becomes a bet on their own side at the moment the
    -- round is decided, and the whole thing is settled by the pool below --
    -- one pot, one set of winners. Paying to enter puts you IN the pool
    -- rather than funding other people's bets for nothing, and a fighter who
    -- wins always profits, because the pool holds every loser's fee as well
    -- as their own.
    --
    -- Recorded here rather than when the fee is taken: a player's side is not
    -- final until the round is, and a bet on a team somebody later left would
    -- be judged against a side they did not fight for.
    if entryPotJoinsPool() then
        local added = addEntryStakesAsBets(matchId, context)
        if added > 0 then
            trace('entry fees joined the bet pool on match %s (%d stake(s))', tostring(matchId), added)
        end
        return {}
    end

    local pot = ArenaBetting.GetPot(matchId)
    if pot <= 0 then
        -- THE LAST SILENT PATH, and the one that looks most like a broken
        -- arena from a player's seat: side-bets are a separate pool and pay
        -- out normally, so a match where only they pay reads as "the pot is
        -- broken" when the truth is there was no pot to pay.
        --
        -- Said out loud with the reason it can happen, because from outside
        -- this function an empty pot and a failed payout are the same
        -- event: nobody got anything.
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
        -- FORWARDED, and it has to be. This table is rebuilt field by field
        -- rather than passed through, so a field the caller sets and the
        -- maths reads is silently dropped unless it is named here. That is
        -- exactly what happened to `contestants`: server/match.lua recorded
        -- it and shared/arena.lua read it, both correctly, and the value
        -- never crossed this line -- so the bug they were each fixing stayed
        -- live between them.
        --
        -- What it costs when missing: `players` is the SURVIVING roster, so
        -- a 1v1 where one player quits mid-round arrives here with one name
        -- on it. Below Config.Betting.minPlayersToPayOut, the maths refunds
        -- everybody -- handing the quitter back the stake that leaving was
        -- meant to forfeit, and paying the winner nothing for a fight they
        -- won. `contestants` is how many the round was FOUGHT with, which is
        -- the number that question was always asking about.
        contestants = context.contestants,
    })

    -- Every payout being a refund means the match did not qualify to pay out
    -- -- too few players, no winner, nobody killed anybody. Escrow, not the
    -- caller's player list, is the record of who staked what, so the money
    -- moves through RefundAll and the computed list is handed back purely as
    -- the report of what was decided.
    local refundingEveryone = #payouts > 0
    for _, payout in ipairs(payouts) do
        if not isRefundReason(payout.reason) then
            refundingEveryone = false
            break
        end
    end
    if refundingEveryone then
        -- SAID OUT LOUD, not only to a webhook that ships off. A refunded
        -- pot and a pot that failed to pay look identical to the players --
        -- money comes back, nobody wins anything -- and an operator watching
        -- that happen has no way to tell "the match did not qualify" from
        -- "the arena is broken". This line is the difference, and it names
        -- the three numbers the decision was actually made on.
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

    -- The pot is spent the moment it is decided: every held stake is marked
    -- before a single payment goes out, so a Settle that somehow runs twice
    -- pays nothing the second time even if a payment failed the first.
    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            stake.settled = true
            stake.settledAs = 'payout'
        end
    end

    -- The other half of the pair above. A pot that DID pay is worth one
    -- line too: it is how an operator confirms the money went where they
    -- expected without reading a webhook, and it is what turns "betting is
    -- broken" into a question with an answer already in the console.
    ArenaLog('betting: match %s paid out %s of a %s pot to %d player(s) (%s), house kept %s.',
        tostring(matchId), money(distributed), money(pot), #payouts,
        tostring(Config.Betting.payout or 'winner_takes_all'), money(houseCut))

    -- WHERE EACH WINNER'S OWN STAKE CAME FROM. A pot payout is that stake
    -- plus a share of everybody else's, and the stake is the part we can
    -- place exactly -- so the whole payment rides back to the account the
    -- winner actually paid from. Dropping it paid a bank-funded entry out
    -- as cash, which is the same surprise (and the same laundering route)
    -- returnSideBet spells out. Unknown here only for a winner escrow never
    -- held, and credit() falls back to the configured account for those.
    local paidFrom = {}
    for id, stake in pairs(stakesOf(matchId)) do paidFrom[id] = stake.account end

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
                -- The pot has already been divided among everyone else, so
                -- this cannot be rolled back into escrow without changing
                -- what they were paid. It is logged for a human instead.
                undelivered = undelivered + amount
                ArenaLog('PAYOUT UNDELIVERED: %d owed to %s on match %s -- they are not on the server. Settle by hand.',
                    amount, tostring(payout.id), tostring(matchId))
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

-- ======================================================================
-- SPECTATOR SIDE-BETS
--
-- A pool of their own. They are never added to the pot and never subtracted
-- from it: a winning side-bet is paid by the house at `oddsMultiplier`, a
-- losing one is kept by it, and the fighters' pot is untouched either way.
-- ======================================================================

--- @param matchId string
--- @param src integer
--- @return boolean
--- Everything staked in side-bets that will be settled as a pool.
---
--- THE NUMBER ON SCREEN HAS TO BE THE NUMBER THAT GETS PAID. GetPot above
--- is the ENTRY pot and nothing else, and with betPayout.includeEntryPot on
--- -- the shipped default -- the entry stakes and the side-bets are settled
--- as ONE pool by one set of rules. So a panel showing GetPot alone shows a
--- figure nobody ever wins: a player placing a bet watched the pot sit
--- still, because their money had gone into the half of it the screen could
--- not see.
---
--- Only pool-mode bets. An 'odds' bet is funded by the server and never
--- enters the pool, so counting it would promise the winner money that is
--- not there.
--- @param matchId string
--- @return integer
function ArenaBetting.GetSideBetPool(matchId)
    local total = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.settled ~= true and bet.mode ~= 'odds' then
            total = total + (Arena.ToInt(bet.amount) or 0)
        end
    end
    return total
end

--- Everything a winner of this match stands to be paid from, as one figure.
---
--- With the entry pot joining the pool that is both halves; without it the
--- two are separate prizes decided by different rules, and adding them
--- would tell a player the entry pot is bigger than it is.
--- @param matchId string
--- @return integer
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
        if bet.src == id and bet.fromEntryFee ~= true then
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

function ArenaBetting.HasSpectatorBet(matchId, src)
    local id = serverId(src)
    if not id then return false end
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == id then return true end
    end
    return false
end

--- The payout mode for one kind of bet: 'pool' or 'odds'.
--- @param kind string -- 'fighter' or 'spectator'
--- @return string
local function payoutMode(kind)
    local block = Config.Betting.betPayout
    local wanted = type(block) == 'table'
        and block[kind == 'fighter' and 'fighters' or 'spectators']
        or nil
    return wanted == 'odds' and 'odds' or 'pool'
end

--- Whether fighter bets are on at all.
local function fighterBetsOn()
    local block = Config.Betting.fighterBets
    return type(block) == 'table' and block.enabled == true
end

--- The side a fighter is allowed to back: their team, or themselves.
--- @return string|nil
local function ownSideOf(match, src)
    local row = type(match.players) == 'table' and match.players[src] or nil
    if not row then return nil end
    if Arena.ModeUsesTeams(match.modeKey) and Arena.IsKey(row.team) then return row.team end
    return tostring(src)
end

--- Whether a bet must be handed back unjudged.
---
--- THE BET-THEN-JOIN HOLE. The rule that a fighter may only back their own
--- side is checked when the bet is placed, and that check alone is defeated
--- by doing the two things in the other order: bet on the side you are about
--- to fight against, then join. So it is checked AGAIN here, against who
--- actually fought, which is the only moment both facts are known.
---
--- With fighter bets switched off entirely, any bet a fighter CHOSE to place
--- is void -- the original rule, unchanged.
--- @param bet table
--- @param fighters table<number, table|boolean>
--- @return boolean
local function voided(bet, fighters)
    local row = fighters[bet.src]
    if not row then return false end

    -- AN ENTRY FEE IS NOT A BET ANYBODY CHOSE TO PLACE.
    --
    -- With betPayout.includeEntryPot on, every fighter's entry fee is turned
    -- into a pool bet on their own side so the pot and the side-bets are
    -- settled by one set of rules. That is bookkeeping, not a wager: the
    -- player paid a fixed price to enter, and `fighterBets` is the switch for
    -- whether they may ALSO back themselves with money of their own.
    --
    -- Without this line the two settings cancelled each other out. An
    -- operator who wanted an entry pot but no self-betting got neither: every
    -- entry stake was a bet held by a fighter, so every one was voided and
    -- handed straight back, and the pot was never won by anybody. Nothing
    -- said so -- the round ended, the winner was announced, and the money
    -- quietly went home. `fromEntryFee` exists on the record precisely to
    -- tell the two apart, and this is the check that reads it.
    --
    -- The own-side rule below has nothing to say about one either:
    -- addEntryStakesAsBets writes the pick from the side they actually
    -- fought on, so it can never be a bet against its own holder.
    if bet.fromEntryFee == true then return false end

    -- They fought. Whether that is allowed at all:
    if not fighterBetsOn() then return true end
    if (Config.Betting.fighterBets or {}).ownSideOnly == false then return false end

    -- And whether they backed their own side. `row` is the player record the
    -- registry returned, so their team is read from what they actually
    -- fought as rather than from anything carried on the bet.
    local team = type(row) == 'table' and row.team or nil
    local own = Arena.IsKey(team) and team or tostring(bet.src)
    return bet.pick ~= own
end

--- Which pool a bet belongs to, so a shared pool and two separate ones are
--- the same code path with a different key.
local function poolKeyFor(kind)
    local block = Config.Betting.betPayout
    if type(block) == 'table' and block.sharedPool == false then return kind end
    return 'all'
end

--- Takes a spectator's side-bet on a team or a fighter.
---
--- Everything is checked before the money moves: that the match exists, that
--- the better is not one of the fighters in it, that the window is still
--- open, and that the pick is something that can actually win.
--- @param src integer
--- @param matchId string
--- @param pick any -- team key in a team mode, a fighter's server id in a free-for-all
--- @param amount any -- as requested; re-resolved through Arena.ResolveSpectatorBet
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)
    if not ArenaBetting.IsEnabled() then return false, 'error.betting_disabled' end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    local stake, reason = Arena.ResolveSpectatorBet(amount)
    if not stake then return false, reason or 'error.bet_invalid' end

    local match = lobbyMatch(matchId)
    if not match then return false, 'error.match_not_found' end

    -- A FIGHTER IS A DIFFERENT KIND OF BET, not a refused one.
    --
    -- It used to be refused outright. With fighterBets on they may back
    -- themselves -- or their own team in a team mode -- and the bet is
    -- settled out of the pool rather than by the server, so winning a round
    -- they were always going to win takes other bettors' money instead of
    -- printing it.
    local isFighter = type(match.players) == 'table' and match.players[id] ~= nil
    if isFighter and not fighterBetsOn() then
        return false, 'error.bet_not_spectator'
    end
    if not betsAreOpen(match) then return false, 'error.bets_closed' end

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
        -- Recorded so a refund goes back to the account it came out of
        -- rather than to whichever one this server happens to list first --
        -- and the account it came OUT of, never the one that was asked for.
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

--- Hands every unsettled side-bet on a match back, unjudged.
---
--- FOR A MATCH THAT HAS CHANGED OUT FROM UNDER THEM. A side-bet names a
--- side: a team key in a team mode, a fighter's server id in a free-for-all.
--- Change the mode of an open lobby and every outstanding bet on it is
--- picking something that can no longer win -- a team key in a match with no
--- teams -- so at settlement it simply loses. Not voided, not refunded: lost,
--- with no way for the bettor to have seen it coming and nothing on screen
--- saying it happened.
---
--- Returning them is the honest answer. They backed a match that no longer
--- exists in the shape they backed it in, and they can bet again on the one
--- that replaced it.
--- No reason key: returnSideBet tells the bettor in its own words, and a
--- parameter this passed along and that function ignored would read as
--- wired up.
--- @param matchId string
--- @return integer returned
--- @return integer owed -- money that could not be handed back
function ArenaBetting.ReturnSideBets(matchId)
    local returned, owed = 0, 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled then
            if returnSideBet(bet, matchId) then
                returned = returned + 1
            else
                owed = owed + (Arena.ToInt(bet.amount) or 0)
            end
        end
    end
    return returned, owed
end

--- Settles every side-bet on a match. Winners are paid
--- `Arena.ComputeSpectatorPayout` (their stake included in it); losers are
--- kept by the house.
---
--- A nil `winningPick` means the match produced no result at all. There is
--- nothing to judge a bet against then, so the house has no claim on it and
--- every bet is returned rather than swallowed.
---
--- A BET HELD BY A FIGHTER IS RE-JUDGED, not automatically void. With
--- fighterBets on, backing your own side is a bet like any other and is
--- settled out of the pool; backing the OTHER side is being paid to lose on
--- purpose, and goes back unjudged. With fighterBets off, any bet held by a
--- fighter is void -- the original rule, unchanged.
---
--- Checked here as well as at placement because the placement check alone is
--- defeated by doing the two things in the other order: bet on the side you
--- are about to fight against, then join. This is the check that cannot be
--- ordered around, because it runs where the money moves and reads the
--- roster as it finally stood. See `voided` for the rule itself.
--- WHAT IT PAID, PER PLAYER, is the third return and it is not a
--- convenience. With betPayout.includeEntryPot on -- which is how this ships
--- -- ArenaBetting.Settle hands the entry stakes to this function and returns
--- an EMPTY payout list, so every downstream reader of that list saw a match
--- where nobody was paid anything. The winner's own results board said they
--- earned nothing while the money landed in their account, and the all-time
--- leaderboard recorded zero earnings for everybody, for ever, on the default
--- configuration. This is the number those two have to read instead.
---
--- WON BETS ONLY. A refund is a player's own stake handed back -- including
--- the uncontested-pool refund above -- and has never counted as earnings.
--- @param matchId string
--- @param winningPick any -- team key, winning fighter's server id, or nil
--- @return integer paid -- winning bets settled
--- @return integer total -- money paid out
--- @return table<integer, integer> earnings -- { [src] = won }, refunds excluded
function ArenaBetting.SettleSpectatorBets(matchId, winningPick)
    local bets = sideBets[matchId]
    if type(bets) ~= 'table' then return 0, 0, {} end

    -- No answer from the registry means no fighter can be identified, so
    -- every bet is judged on the rule it was placed under. The callers that
    -- matter -- End and Abort -- both settle before the record is dropped.
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

    -- A POOL NOBODY BET AGAINST IS NOT A WIN, and paying it as one is how
    -- the arena ends up looking like it stole from the only person who
    -- played along. Bet on yourself in an empty pool and the pool IS your
    -- stake: the share works out to exactly what you put in, so you are
    -- told you won and your balance does not move -- or worse, moves into
    -- the other account. There was no counterparty, so there is nothing to
    -- judge: every stake goes back and is described as what it is.
    --
    -- Only when the winners hold the WHOLE pool. One backer against one
    -- loser is a real bet and settles normally.
    local uncontested = {}
    for key, pool in pairs(pools) do
        if (backed[key] or 0) >= pool then uncontested[key] = true end
    end

    -- Each pool split among ITS winners, in proportion to what they staked.
    -- Done here rather than per bet so the shares provably sum to the pool.
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
                -- No result to judge against, so the house has no claim and
                -- every stake goes back -- pool bets included, because a pool
                -- with no winner is just everybody's money.
                returnSideBet(bet, matchId)
            elseif bet.mode ~= 'odds' and uncontested[poolKeyFor(bet.kind or 'spectator')] then
                -- Winner and loser alike: with the whole pool on one side
                -- there is no money to move between them.
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
                -- Recorded on the WIN, not on the delivery: a payout that
                -- could not be handed over is still money this player won,
                -- and the undelivered branch below is what chases it.
                earnings[bet.src] = (earnings[bet.src] or 0) + amount
                -- `bet.account` AGAIN, for the same reason returnSideBet
                -- carries it. A winning side-bet is the bettor's own stake
                -- plus a share of the pool, and dropping the account paid it
                -- into whichever account the operator happens to list first:
                -- back a bank-funded bet on yourself with nobody else in the
                -- pool and you win exactly your stake -- into your pocket,
                -- with your bank permanently down by it. That reads as the
                -- arena taking the money, and from the bank's side it is.
                if amount > 0 and credit(bet.src, amount, transaction('sidebet_payout', matchId),
                    bet.citizenid, bet.account) then
                    lines[#lines + 1] = ('%s: %s on "%s"'):format(tostring(bet.name or bet.src), money(amount), bet.pick)
                    ArenaNotifyKey(bet.src, 'notify.spectator_bet_won', 'success', money(amount))
                elseif amount > 0 then
                    ArenaLog('SIDE-BET PAYOUT UNDELIVERED: %d owed to %s (citizenid %s) on match %s.',
                        amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
                    incidentWebhook('Side-bet payout not delivered',
                        'A winning spectator side-bet could not be paid.', {
                            { name = 'Match', value = tostring(matchId) },
                            { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                            { name = 'Amount', value = money(amount) },
                        })
                end
            elseif bet.mode ~= 'odds' and not (winners[poolKeyFor(bet.kind or 'spectator')] or {})[1] then
                -- A POOL NOBODY WON IS NOT THE HOUSE'S.
                --
                -- With fixed odds a loser's stake is simply lost -- the
                -- server was the counterparty and it kept the bet. A pool has
                -- no counterparty: it is the bettors' own money, and if the
                -- winning side drew no backers there is nobody it can be paid
                -- to. Keeping it would be the arena quietly taking every
                -- stake on the match.
                returnSideBet(bet, matchId)
            else
                bet.settled = true
                bet.settledAs = 'lost'
                -- KEPT MEANS THE HOUSE KEPT IT, and only fixed odds ever
                -- does: the server was the counterparty and the stake stays
                -- with it. A losing POOL stake was just paid to the winners
                -- a few lines up, so counting it here reported the same
                -- money twice -- "paid out 10,000, kept 5,000" out of a
                -- 10,000 pool -- and an operator reading that line has been
                -- told the arena is skimming when it is not.
                if bet.mode == 'odds' then kept = kept + bet.amount end
                ArenaNotifyKey(bet.src, 'notify.spectator_bet_lost', 'error', money(bet.amount))
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

-- ======================================================================
-- TEARDOWN
-- ======================================================================

--- Drops a match's money state.
---
--- REFUSES while the entry-fee escrow still holds anything, and says so on
--- the console. That refusal is the last line of defence: it turns "the pot
--- vanished with the match record" into a message an operator can read and a
--- state a later refund can still reach.
---
--- Unresolved side-bets are the other case: they are the house's action
--- rather than the pot, and once the match is gone there is nothing left to
--- judge them against, so they are handed back here instead of kept.
---
--- THE ORDER IS LOAD-BEARING, and the returns run before the escrow check
--- for that reason. The two pools are independent -- an entry fee that could
--- not be handed back is not a reason to keep somebody's unjudged bet -- and
--- the refusal below does not stop the match record being dropped:
--- ArenaLobby.Destroy drops it whatever this returns. A side-bet still
--- sitting here at that moment is one nobody can reach again, with no id
--- left to call Clear with and, unlike a stranded stake, not one line
--- printed with its name on it.
--- @param matchId string
--- @return boolean ok -- false when something is still owed; nothing is dropped then
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
