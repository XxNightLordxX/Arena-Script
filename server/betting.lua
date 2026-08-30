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

--- Money OUT. False means nothing moved, so the caller must record nothing --
--- otherwise escrow claims a stake the player still has in their pocket.
--- @return boolean
local function debit(src, amount, reason)
    local player = ArenaGetPlayer(src)
    if not player then return false end
    return player.Functions.RemoveMoney(Config.Betting.account, amount, reason) == true
end

--- Money IN. False means the player could not be paid, almost always because
--- they have left the server. What to do about that differs between a refund
--- (still held, still owed, try again later) and a payout (the pot has
--- already been divided, so it is logged instead), which is why this returns
--- the failure rather than handling it.
--- @return boolean
local function credit(src, amount, reason)
    local player = ArenaGetPlayer(src)
    if not player then return false end
    return player.Functions.AddMoney(Config.Betting.account, amount, reason) == true
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

--- Hands one unresolved side-bet back, once. Shared by the no-result
--- settlement and by Clear so both take identical care about paying twice.
--- @return boolean paid
local function returnSideBet(bet, matchId)
    if bet.settled then return false end

    if not credit(bet.src, bet.amount, transaction('sidebet_refund', matchId)) then
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
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaBetting.TakeStake(src, matchId, amount)
    if not ArenaBetting.IsEnabled() then return true, nil end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    local fee, reason = Arena.ResolveEntryFee(amount)
    if not fee then return false, reason or 'error.bet_invalid' end
    if fee <= 0 then return true, nil end

    local held = stakesOf(matchId)[id]
    if held and not held.settled then
        -- A second take for one seat would remove the fee twice while only
        -- one of the two could ever be refunded.
        ArenaLog('DOUBLE STAKE REFUSED: %s already holds %d on match %s. Nothing was taken.',
            tostring(held.citizenid or id), held.amount, tostring(matchId))
        return false, 'error.bet_already_staked'
    end

    local ceiling = Arena.ToInt(Config.Betting.maxPot) or 0
    if ceiling > 0 and (ArenaBetting.GetPot(matchId) + fee) > ceiling then
        return false, 'error.pot_limit_reached'
    end

    if not debit(id, fee, transaction('stake', matchId)) then
        return false, 'error.not_enough_money'
    end

    escrow[matchId] = escrow[matchId] or {}
    escrow[matchId][id] = {
        amount = fee,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
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

    if not credit(id, stake.amount, transaction('refund', matchId)) then
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
--- even share, because with `hostSetsForEveryone = false` they did not all
--- pay the same.
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

--- Pays the pot out. The match decides who won; this decides nothing but
--- where the money goes and whether it has gone already.
---
--- The pot comes from ESCROW, never from `context.pot`: the caller's idea of
--- the pot is a report, escrow is the fact, and paying out against a report
--- is how a pot ends up bigger than the money behind it.
--- @param matchId string
--- @param context table -- Arena.ComputePayouts' context: { players = { { id, team, kills, stake, placement } }, winners = { id }, teams = boolean }
--- @return table[] payouts -- { { id, amount, reason } } as computed
function ArenaBetting.Settle(matchId, context)
    if not Arena.IsKey(matchId) then return {} end

    local pot = ArenaBetting.GetPot(matchId)
    if pot <= 0 then return {} end

    context = type(context) == 'table' and context or {}
    local payouts, houseCut = Arena.ComputePayouts({
        pot = pot,
        players = context.players,
        winners = context.winners,
        teams = context.teams,
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

    local lines, undelivered = {}, 0
    for _, payout in ipairs(payouts) do
        local amount = math.max(0, Arena.ToInt(payout.amount) or 0)
        local winner = serverId(payout.id)
        if amount > 0 then
            if winner and credit(winner, amount, transaction('payout', matchId)) then
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
function ArenaBetting.HasSpectatorBet(matchId, src)
    local id = serverId(src)
    if not id then return false end
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == id then return true end
    end
    return false
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
function ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount)
    if not ArenaBetting.IsEnabled() then return false, 'error.betting_disabled' end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    local stake, reason = Arena.ResolveSpectatorBet(amount)
    if not stake then return false, reason or 'error.bet_invalid' end

    local match = lobbyMatch(matchId)
    if not match then return false, 'error.match_not_found' end

    if type(match.players) == 'table' and match.players[id] then
        -- A fighter backing an outcome they are in is not a side-bet.
        return false, 'error.bet_not_spectator'
    end
    if not betsAreOpen(match) then return false, 'error.bets_closed' end

    local wanted = canonicalPick(pick)
    if not wanted or not pickExists(match, wanted) then return false, 'error.bet_invalid_pick' end

    local spectator = Config.Betting.spectatorBets or {}
    if spectator.oneBetPerMatch ~= false and ArenaBetting.HasSpectatorBet(matchId, id) then
        return false, 'error.bet_already_placed'
    end

    if not debit(id, stake, transaction('sidebet', matchId)) then
        return false, 'error.not_enough_money'
    end

    sideBets[matchId] = sideBets[matchId] or {}
    sideBets[matchId][#sideBets[matchId] + 1] = {
        src = id,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
        pick = wanted,
        amount = stake,
        placedAt = os.time(),
        settled = false,
    }

    trace('took side-bet of %d from %s on "%s" in match %s',
        stake, tostring(id), wanted, tostring(matchId))
    ArenaNotifyKey(id, 'notify.spectator_bet_placed', 'info', money(stake))
    return true, nil
end

--- Settles every side-bet on a match. Winners are paid
--- `Arena.ComputeSpectatorPayout` (their stake included in it); losers are
--- kept by the house.
---
--- A nil `winningPick` means the match produced no result at all. There is
--- nothing to judge a bet against then, so the house has no claim on it and
--- every bet is returned rather than swallowed.
--- @param matchId string
--- @param winningPick any -- team key, winning fighter's server id, or nil
--- @return integer paid -- winning bets settled
--- @return integer total -- money paid out
function ArenaBetting.SettleSpectatorBets(matchId, winningPick)
    local bets = sideBets[matchId]
    if type(bets) ~= 'table' then return 0, 0 end

    local wanted = canonicalPick(winningPick)
    local paid, total, kept, lines = 0, 0, 0, {}

    for _, bet in ipairs(bets) do
        if not bet.settled then
            if not wanted then
                returnSideBet(bet, matchId)
            elseif bet.pick == wanted then
                local amount = Arena.ComputeSpectatorPayout(bet.amount)
                -- Marked before the payment for the same reason the pot is:
                -- a settlement that runs twice must not pay twice.
                bet.settled = true
                bet.settledAs = 'won'
                paid = paid + 1
                total = total + amount
                if amount > 0 and credit(bet.src, amount, transaction('sidebet_payout', matchId)) then
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
            else
                bet.settled = true
                bet.settledAs = 'lost'
                kept = kept + bet.amount
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

    return paid, total
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
--- @param matchId string
--- @return boolean ok -- false when something is still owed; nothing is dropped then
function ArenaBetting.Clear(matchId)
    local held = ArenaBetting.GetPot(matchId)
    if held > 0 then
        ArenaLog('CLEAR REFUSED: match %s still holds %d in escrow. Settle or refund it first -- nothing was dropped.',
            tostring(matchId), held)
        incidentWebhook('Match cleared while holding escrow',
            'A match was cleared while its pot was still held. The escrow was kept.', {
                { name = 'Match', value = tostring(matchId) },
                { name = 'Held', value = money(held) },
            })
        return false
    end

    local owed = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled then
            ArenaLog('CLEAR: match %s had an unresolved side-bet of %d from %s -- returning it.',
                tostring(matchId), bet.amount, tostring(bet.name or bet.src))
            if not returnSideBet(bet, matchId) then owed = owed + bet.amount end
        end
    end
    if owed > 0 then
        ArenaLog('CLEAR REFUSED: match %s still owes %d in side-bets that could not be returned. Nothing was dropped.',
            tostring(matchId), owed)
        return false
    end

    escrow[matchId] = nil
    sideBets[matchId] = nil
    return true
end
