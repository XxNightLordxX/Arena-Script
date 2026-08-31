--[[
    crimson_arena/tests/bettingdefects_spec.lua

    Five reviewed defects in server/betting.lua, each pinned by the sequence
    that reached it. The REAL server/util.lua and server/betting.lua are
    loaded unmodified into a sandbox over the real config.lua and
    shared/arena.lua -- nothing here re-implements a rule.

    THE LEDGER, NOT THE BALANCE, exactly as server_spec.lua counts it: every
    claim about money checks how many times it MOVED as well as where it
    ended up. Three of the five defects below are a payment that goes to the
    wrong person or does not go at all, and a balance alone cannot tell a
    refund that ran twice from one that never ran.

    server/lobby.lua is NOT loaded. betting.lua only reads the match registry,
    defensively, at run time, and `fakeLobby` supplies the one record shape it
    reads -- which is also what lets a test move a player between "spectator"
    and "fighter" the way a join would, without the rest of a lobby.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('bettingdefects_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- @param wallets table<integer, integer> -- [serverId] = starting cash
--- @return table<integer, table>
local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
        }
    end
    return players
end

--- One arena server: real config, real rules, real util.lua, real
--- betting.lua, and a fake qbx_core recording every money movement. Fresh
--- per test -- escrow is module state, so two tests sharing an env would
--- share a pot.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)? -- applied before anything is staked
--- @return table server
local function newServer(wallets, mutate)
    local qbx = Sandbox.newQbxCore(roster(wallets))
    local oxlib = Sandbox.newOxLib()
    local console, toasts = {}, {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = oxlib,
        TriggerClientEvent = function(event, target, payload)
            toasts[#toasts + 1] = { event = event, target = target, payload = payload }
        end,
        -- Captured, not silenced: a refusal that is not loud is half the bug
        -- in three of these findings.
        print = function(line) console[#console + 1] = line end,
    })
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)

    local server = { env = env, qbx = qbx, betting = env.ArenaBetting, config = env.Config }

    --- @return integer
    function server.cash(id)
        return qbx.players[id].money.cash
    end

    --- @return integer
    function server.movements(id)
        return qbx.movements(id)
    end

    --- Money created or destroyed across every account.
    --- @return integer
    function server.ledgerTotal()
        local total = 0
        for _, entry in ipairs(qbx.ledger) do total = total + entry.delta end
        return total
    end

    --- @return integer
    function server.movementCount()
        return #qbx.ledger
    end

    --- @return string
    function server.log()
        return table.concat(console, '\n')
    end

    --- The player behind a server id changes: their connection went, the id
    --- was freed, and FXServer handed it to the next player to connect. The
    --- wallet and the citizenid are somebody else's from here on -- which is
    --- the whole of what a reused id is.
    --- @param id integer
    --- @param cash integer
    function server.reassignId(id, cash)
        qbx.players[id] = {
            citizenid = ('NEW%03d'):format(id),
            name = ('Newcomer %d'):format(id),
            money = { cash = cash, bank = 0 },
        }
    end

    --- The player behind a server id leaves and nobody replaces them: every
    --- lookup for that id comes back nil, which is what a payment to them
    --- fails on.
    --- @param id integer
    function server.disconnect(id)
        qbx.players[id] = nil
    end

    return server
end

--- The one record betting.lua reads out of the lobby. `players` is a live
--- table so a test can seat or unseat somebody the way a join or a leave
--- would, which is exactly the ordering these findings turn on.
--- @param records table<string, table>
--- @return table
local function fakeLobby(records)
    return { Get = function(matchId) return records[matchId] end }
end

--- Two fighters staked into one team match, with the lobby record wired up
--- so side-bets have something to bet on. The record is returned alongside
--- the server so a test can move somebody into or out of `players`.
--- @param spectators table<integer, integer>? -- [serverId] = starting cash
--- @param mutate fun(config: table)?
--- @return table server
--- @return table record -- the m1 match record the server reads
--- Pins the FIXED-ODDS payout, which several tests below were written
--- against and which is no longer the default.
---
--- Both kinds of bet now settle out of a POOL by default -- winners split
--- the stakes in proportion to what they put in, and the server funds
--- nothing. That changes two numbers these tests assert: what a winner
--- receives, and what happens to a loser when nobody backed the winning
--- side (a pool with no winner is the bettors' own money and goes back,
--- where the house keeps a losing bet against fixed odds).
---
--- The rule under test in each case is the odds one, so it is stated here
--- rather than inherited.
--- @param config table
local function oddsPayout(config)
    config.Betting.betPayout = { fighters = 'odds', spectators = 'odds', sharedPool = true }
end

local function teamMatch(spectators, mutate)
    local wallets = { [1] = 5000, [2] = 5000 }
    for id, cash in pairs(spectators or {}) do wallets[id] = cash end

    local server = newServer(wallets, mutate)
    local record = {
        id = 'm1',
        state = 'lobby',
        modeKey = 'tdm',
        players = {
            [1] = { src = 1, team = 'crimson' },
            [2] = { src = 2, team = 'ash' },
        },
    }
    server.env.ArenaLobby = fakeLobby({ ['m1'] = record })

    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)
    return server, record
end

-- ======================================================================
-- F5 -- AN UNJUDGED SIDE-BET MUST SURVIVE A POT THAT COULD NOT BE REFUNDED
--
-- The two pools are independent, and every caller drops the match record
-- whatever Clear returns. A side-bet still sitting in the table at that
-- moment is money nobody can reach again: there is no id left to call Clear
-- with, and unlike a stranded stake nothing has printed its name.
-- ======================================================================

t.test('Clear returns an unjudged side-bet even while the pot is still held', function()
    local server, record = teamMatch({ [3] = 3000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))
    t.equals(server.cash(3), 2000, 'the bet left the spectator')

    -- Fighter 1's qbx object goes away while the lobby is still open -- a
    -- crash, or a /logout to character select -- so their refund fails and
    -- their stake is deliberately left held and still owed.
    record.players[1] = nil
    server.disconnect(1)

    local settled = server.betting.RefundAll('m1', 'notify.match_empty')
    t.isFalse(settled, 'the pot cannot be fully refunded, which is the case this test is about')
    t.equals(server.betting.GetPot('m1'), 1000)
    t.contains(server.log(), 'REFUND FAILED')

    local dropped = server.betting.Clear('m1')

    -- Still refused, and still loud: the stake is real money that has to
    -- stay reachable.
    t.isFalse(dropped, 'a match still holding a stake may not be dropped')
    t.contains(server.log(), 'CLEAR REFUSED')
    t.equals(server.betting.GetPot('m1'), 1000, 'the held stake was not quietly written off')

    -- THE ASSERTION THIS TEST EXISTS FOR. The spectator's money is not the
    -- pot's, and the pot's trouble is not a reason to keep it.
    t.contains(server.log(), 'unresolved side-bet')
    t.equals(server.cash(3), 3000, 'the side-bet came back')
    t.equals(server.movements(3), 2, 'out once, back once')
end)

t.test('a second Clear does not hand the same side-bet back twice', function()
    local server, record = teamMatch({ [3] = 3000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))

    record.players[1] = nil
    server.disconnect(1)
    server.betting.RefundAll('m1', 'notify.match_empty')
    t.isFalse(server.betting.Clear('m1'))

    local before = server.movementCount()
    t.isFalse(server.betting.Clear('m1'), 'the stake is still held, so the refusal stands')

    -- A returned bet is marked, not deleted, exactly like a settled stake --
    -- so the retry that a still-held pot invites pays nobody a second time.
    t.equals(server.movementCount(), before, 'the second Clear moved money')
    t.equals(server.cash(3), 3000)
    t.equals(server.movements(3), 2)
end)

-- ======================================================================
-- F6 / F17 -- A SIDE-BET MUST NOT SURVIVE ITS HOLDER BECOMING A FIGHTER
--
-- PlaceSpectatorBet refuses a fighter, so the way round it is to bet first
-- and join afterwards. The rule is enforced in two places now: the door a
-- join takes its stake through, and the settlement where the money moves.
-- ======================================================================

t.test('a spectator holding a side-bet cannot take a seat in that match', function()
    local server = teamMatch({ [3] = 30000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 25000))

    local ok, reason = server.betting.TakeStake(3, 'm1', 1000)

    t.isFalse(ok, 'a fighter may not hold money on the fight at house odds')
    t.equals(reason, 'error.bet_not_spectator')
    t.equals(server.movements(3), 1, 'the refused stake must not reach the account')
    t.equals(server.betting.GetPot('m1'), 2000, 'and must not reach the pot')
    t.equals(server.betting.GetStake('m1', 3), 0)
end)

t.test('the refusal is about this match, not about betting at all', function()
    -- The rule is "not on the fight you are in". Backing one match must not
    -- lock somebody out of every other one on the server.
    local server = teamMatch({ [3] = 30000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))

    local ok, reason = server.betting.TakeStake(3, 'm2', 1000)

    t.isTrue(ok)
    t.isNil(reason)
    t.equals(server.betting.GetStake('m2', 3), 1000)
    t.equals(server.movements(3), 2, 'the side-bet out, the other match\'s stake out')
end)

t.test('a bet whose holder ends the match as a fighter is void and goes back unpaid', function()
    -- The door above is the entry fee's. A match with no entry fee never
    -- calls TakeStake at all -- `entryFee.enabled = false` with side-bets
    -- left on is a documented setup -- so the rule has to hold again where
    -- the money actually moves.
    -- WITH FIGHTER BETS OFF, which is the rule this test is about. With them
    -- on, backing the side you then fight for is a legitimate fighter bet and
    -- is settled rather than voided -- a different rule, tested separately.
    local server, record = teamMatch({ [3] = 30000, [4] = 30000 }, function(config)
        oddsPayout(config)
        config.Betting.fighterBets = { enabled = false }
    end)
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 25000))
    t.isTrue(server.betting.PlaceSpectatorBet(4, 'm1', 'crimson', 25000))

    -- 3 joins the side they backed, without a stake in the way.
    record.players[3] = { src = 3, team = 'crimson' }

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    -- The house pays the spectator who only watched, and nobody else.
    t.equals(paid, 1, 'the fighter was paid as a winner')
    t.equals(total, 50000)
    t.equals(server.cash(4), 55000, 'a real spectator still collects at the configured odds')
    t.equals(server.movements(4), 2, 'the bet out, the winnings in')

    -- THE ASSERTION THIS TEST EXISTS FOR. Paid at 2.0 this would have been
    -- 50000 of house money on a result its holder fought for.
    t.contains(server.log(), 'SIDE-BET VOID')
    t.equals(server.cash(3), 30000, 'the fighter got their own stake back and nothing else')
    t.equals(server.movements(3), 2, 'out once, back once')
    t.equals(server.ledgerTotal(), 23000,
        'the house is out 25000 on the one real bet, and the two 1000 fees are still escrowed')
end)

t.test('a fighter\'s side-bet is void whichever way it would have gone', function()
    -- Voided in both directions on purpose: the bet never counted, so the
    -- house has no more claim on a losing one than a winning one. Keeping
    -- the loser would also make it worth placing a bet on the side you are
    -- about to fight against.
    local server, record = teamMatch({ [3] = 30000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'ash', 25000))
    record.players[3] = { src = 3, team = 'crimson' }

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(paid, 0)
    t.equals(total, 0)
    t.equals(server.cash(3), 30000)
    t.equals(server.movements(3), 2, 'out once, back once -- not kept by the house')
end)

t.test('an ordinary losing side-bet is still kept by the house, against fixed odds', function()
    -- The guard above must not have turned every loser into a refund.
    local server = teamMatch({ [4] = 3000 }, oddsPayout)
    t.isTrue(server.betting.PlaceSpectatorBet(4, 'm1', 'ash', 1000))

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(paid, 0)
    t.equals(total, 0)
    t.equals(server.cash(4), 2000)
    t.equals(server.movements(4), 1, 'money out, and nothing back')
end)

-- ======================================================================
-- F7 -- A REFUND IS OWED TO A PERSON, NOT TO A SERVER ID
--
-- A stake outlives its owner exactly when they have gone, and that is when
-- FXServer hands their id to the next connection.
-- ======================================================================

t.test('a refund is not paid to whoever now holds the departed player\'s id', function()
    local server = newServer({ [5] = 5000, [6] = 5000 })
    server.betting.TakeStake(5, 'm1', 1000)
    server.betting.TakeStake(6, 'm1', 1000)

    -- 5 drops mid-round; the shipped mid-match rule forfeits their stake to
    -- the pot, so it sits unsettled. Minutes later somebody else connects
    -- and is handed server id 5. The round then ends with no winner and the
    -- whole pot is refunded.
    server.reassignId(5, 250)

    local settled, refunded = server.betting.RefundAll('m1', 'refund_no_winner')

    t.isFalse(settled, 'a stake with nobody to hand it to is still owed')
    t.equals(refunded, 1, 'only the player who is really here was refunded')

    -- THE ASSERTION THIS TEST EXISTS FOR. Paying the current holder of the
    -- id would credit a stranger 1000 they never staked, mark the stake
    -- settled, and print nothing.
    t.equals(server.cash(5), 250, 'the new holder of that id was not paid somebody else\'s stake')
    t.equals(server.movements(5), 1, 'the original stake going out, and nothing since')
    t.contains(server.log(), 'REFUND FAILED')

    -- Still held, still owed, still reachable -- and the match may not be
    -- dropped while it is.
    t.equals(server.betting.GetPot('m1'), 1000)
    t.isFalse(server.betting.Clear('m1'))

    -- The half that must keep working: the player who is who they were is
    -- refunded exactly once.
    t.equals(server.cash(6), 5000)
    t.equals(server.movements(6), 2)
end)

t.test('a side-bet is returned to its owner, not to the id they used to hold', function()
    local server = teamMatch({ [3] = 3000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))
    server.reassignId(3, 400)

    -- No result to judge it against, so the bet goes back -- to the person
    -- who placed it, or to nobody.
    server.betting.SettleSpectatorBets('m1', nil)

    t.equals(server.cash(3), 400, 'the new holder of that id was not handed a bet they never placed')
    t.equals(server.movements(3), 1, 'the bet going out, and nothing since')
    t.contains(server.log(), 'SIDE-BET REFUND FAILED')

    -- Unsettled, so Clear goes on refusing to drop the match and the bet
    -- stays reachable.
    t.isFalse(server.betting.Clear('m1'))
end)

t.test('a winning side-bet is not paid to whoever inherited the id', function()
    local server = teamMatch({ [3] = 3000 }, oddsPayout)
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))
    server.reassignId(3, 400)

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    -- The bet won, so it is settled and reported as such -- the pot side of
    -- this file cannot roll a payout back -- but the money does not reach
    -- the wrong account, and the console says who is owed.
    t.equals(paid, 1)
    t.equals(total, 2000)
    t.equals(server.cash(3), 400)
    t.equals(server.movements(3), 1)
    t.contains(server.log(), 'SIDE-BET PAYOUT UNDELIVERED')
end)

-- ======================================================================
-- F8 -- A FORFEITED STAKE IS NOT A SEAT
--
-- With `refundOnDisconnectBeforeStart = false`, leaving a lobby leaves the
-- fee in that match's pot. The record outlives the player's row, and the
-- double-take guard used to read it as "already staked, refused" forever.
-- ======================================================================

t.test('a player who forfeited their stake to a pot may sit back down on it', function()
    local server, record = teamMatch(nil, function(config)
        config.Betting.refundOnDisconnectBeforeStart = false
    end)

    -- 2 walks out of the lobby: nothing moves, and the fee stays in the pot.
    t.equals(server.betting.KeepInPot('m1', 2), 1000)
    record.players[2] = nil

    local before = server.movementCount()
    local ok, reason = server.betting.TakeStake(2, 'm1', 1000)

    t.isTrue(ok, 'the lobby has an open seat and their money is already in its pot')
    t.isNil(reason)

    -- Nothing moved, because nothing had to: this is the first stake, never
    -- handed back, not a second one.
    t.equals(server.movementCount(), before, 'the rejoin charged them again')
    t.equals(server.movements(2), 1, 'one fee out, at the door, once')
    t.equals(server.cash(2), 4000)
    t.equals(server.betting.GetPot('m1'), 2000, 'the pot is the two fees that were paid')
    t.equals(server.betting.GetStake('m1', 2), 1000, 'and the seat is backed by the stake it always was')
    t.notContains(server.log(), 'DOUBLE STAKE REFUSED')

    -- One stake in the books means one refund out of them.
    t.isTrue(server.betting.RefundAll('m1', 'notify.match_cancelled'))
    t.equals(server.cash(2), 5000)
    t.equals(server.movements(2), 2)
    t.equals(server.ledgerTotal(), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('a seat that is still occupied cannot be staked a second time', function()
    -- The guard the change above narrows, still doing its job: 1 never left,
    -- so their stake is a seat and a second take would remove the fee twice.
    local server = teamMatch()

    local ok, reason = server.betting.TakeStake(1, 'm1', 1000)

    t.isFalse(ok)
    t.equals(reason, 'error.bet_already_staked')
    t.equals(server.movements(1), 1, 'the second take must not reach the account')
    t.equals(server.betting.GetPot('m1'), 2000)
    t.contains(server.log(), 'DOUBLE STAKE REFUSED')
end)

t.test('a stake is not a seat somebody else can inherit with the id', function()
    -- The other half of the same rule: 2 forfeited and then dropped, and the
    -- id went to a newcomer. Their money is not a seat for whoever is on
    -- that id now, and the newcomer is not charged for it either.
    local server, record = teamMatch(nil, function(config)
        config.Betting.refundOnDisconnectBeforeStart = false
    end)
    server.betting.KeepInPot('m1', 2)
    record.players[2] = nil
    server.reassignId(2, 5000)

    local ok, reason = server.betting.TakeStake(2, 'm1', 1000)

    t.isFalse(ok, 'that stake belongs to somebody else')
    t.equals(reason, 'error.bet_already_staked')
    t.equals(server.cash(2), 5000, 'and the newcomer was not charged for it either')
    t.equals(server.betting.GetPot('m1'), 2000)
    t.contains(server.log(), 'DOUBLE STAKE REFUSED')
end)
-- ======================================================================
-- THE POOL, which is how both kinds of bet are paid by default
--
-- Nothing is created. Every stake on a match goes into one pool and the
-- winners split it in proportion to what they put in, so what you take home
-- depends on your own stake AND on how many others backed the other side.
-- The server funds none of it -- which is the whole reason a fighter is
-- allowed to back themselves at all. Against fixed odds, somebody who can
-- influence the result winning a bet is a money printer.
-- ======================================================================

t.test('the winners split the whole pool and the server adds nothing', function()
    local server = teamMatch({ [3] = 10000, [4] = 10000, [5] = 10000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))
    t.isTrue(server.betting.PlaceSpectatorBet(4, 'm1', 'ash', 2000))
    t.isTrue(server.betting.PlaceSpectatorBet(5, 'm1', 'ash', 1000))

    local paid, total = server.betting.SettleSpectatorBets('m1', 'ash')

    t.equals(paid, 2, 'both winners should be settled')
    t.equals(total, 4000,
        'the pool was 1000 + 2000 + 1000 and every penny of it must be handed out, and no more')

    -- 4 staked twice what 5 did, so takes twice the share.
    t.equals(server.cash(4), 8000 + 2667, 'the larger stake did not take the larger share')
    t.equals(server.cash(5), 9000 + 1333)
end)

t.test('a fighter backing themselves is paid out of the same pool', function()
    local server, record = teamMatch({ [3] = 10000 })
    record.players[1] = { src = 1, team = 'crimson' }

    t.isTrue(server.betting.PlaceSpectatorBet(1, 'm1', 'crimson', 1000),
        'a fighter was refused a bet on their own side')
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'ash', 3000))

    local _, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(total, 4000, 'the fighter was paid anything other than the whole pool')
    t.equals(server.cash(3), 7000, 'the losing spectator was refunded, or paid twice')
end)

t.test('and may NOT back the other side, which is being paid to lose', function()
    local server, record = teamMatch({})
    record.players[1] = { src = 1, team = 'crimson' }

    local ok, reason = server.betting.PlaceSpectatorBet(1, 'm1', 'ash', 1000)
    t.isFalse(ok, 'a fighter was allowed to back the team they are fighting against')
    t.equals(reason, 'error.bet_not_own_side')
end)

t.test('and cannot get round it by betting first and joining afterwards', function()
    -- The placement check alone is defeated by doing the two things in the
    -- other order, so it is checked again at settlement against who actually
    -- fought -- the only moment both facts are known.
    local server, record = teamMatch({ [3] = 10000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'ash', 5000))

    -- Now they join the OTHER side.
    record.players[3] = { src = 3, team = 'crimson' }

    server.betting.SettleSpectatorBets('m1', 'ash')

    t.equals(server.cash(3), 10000, 'a bet against your own side paid out -- bet, then join, then collect')
    t.equals(server.movements(3), 2, 'out once and back once: void, not judged')
end)

t.test('a pool nobody won goes back, rather than being kept by the arena', function()
    -- Against fixed odds a loser has lost to the server, which was the
    -- counterparty. A pool has no counterparty: it is the bettors' own money,
    -- and if the winning side drew no backers there is nobody to pay it to.
    -- Keeping it would be the arena quietly taking every stake on the match.
    local server = teamMatch({ [3] = 5000, [4] = 5000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'ash', 1000))
    t.isTrue(server.betting.PlaceSpectatorBet(4, 'm1', 'ash', 1000))

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(paid, 0)
    t.equals(total, 0)
    t.equals(server.cash(3), 5000, 'a stake on a pool nobody won was kept by the house')
    t.equals(server.cash(4), 5000)
end)

t.test('somebody who places no bet is paid nothing, and loses nothing', function()
    -- Betting is voluntary. Not taking part must cost nothing and earn
    -- nothing -- it must not be a silent entry into the pool either way.
    local server, record = teamMatch({ [3] = 5000 })
    record.players[1] = { src = 1, team = 'crimson' }
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))

    -- Measured ACROSS the settlement rather than against a starting figure:
    -- the fixture's match has already taken an entry stake from the fighters,
    -- and this test is about the pool, not about the fee.
    local before, moves = server.cash(1), server.movements(1)
    server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(server.cash(1), before,
        'a fighter who never placed a bet was paid out of the pool anyway')
    t.equals(server.movements(1), moves,
        'settling the pool moved money for somebody who was not in it')
end)
-- ======================================================================
-- ENTRY FEES AS BETS -- the shipped arrangement
--
-- includeEntryPot means there is no separate pot at all: each fighter's
-- entry fee becomes a pool bet on their own side and is settled with
-- everything else. One pot, one set of winners, and paying to enter puts
-- you IN the pool rather than funding other people's bets for nothing.
--
-- Settled in the order server/match.lua really uses -- Settle first, then
-- SettleSpectatorBets -- because Settle is what converts the fees and the
-- second call is what pays them. Either alone is half a settlement.
-- ======================================================================

t.test('the entry fee becomes a bet, and the winner takes the losers fees', function()
    local server, record = teamMatch({})
    record.players[1] = { src = 1, team = 'crimson' }
    record.players[2] = { src = 2, team = 'ash' }

    -- teamMatch already took 1000 from each fighter -- that IS the entry
    -- fee this arrangement turns into a bet.
    t.equals(server.cash(1), 4000)
    t.equals(server.cash(2), 4000)

    local context = {
        teams = true,
        winners = { 1 },
        contestants = 2,
        players = {
            { id = 1, team = 'crimson', stake = 1000, kills = 1 },
            { id = 2, team = 'ash', stake = 1000, kills = 0 },
        },
    }

    t.equals(#server.betting.Settle('m1', context), 0,
        'Settle paid a pot of its own -- the fees were meant to become bets')
    t.equals(server.betting.GetPot('m1'), 0,
        'the pot still holds the fees, so something can pay them twice')

    server.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(server.cash(1), 6000, 'the winner did not take both fees')
    t.equals(server.cash(2), 4000, 'the loser was given their fee back')
end)

t.test('a fighter who also bets is in the pool once for each, not once in total', function()
    local server, record = teamMatch({})
    record.players[1] = { src = 1, team = 'crimson' }
    record.players[2] = { src = 2, team = 'ash' }

    t.isTrue(server.betting.PlaceSpectatorBet(1, 'm1', 'crimson', 500))

    server.betting.Settle('m1', {
        teams = true, winners = { 1 }, contestants = 2,
        players = {
            { id = 1, team = 'crimson', stake = 1000, kills = 1 },
            { id = 2, team = 'ash', stake = 1000, kills = 0 },
        },
    })
    server.betting.SettleSpectatorBets('m1', 'crimson')

    -- Pool is 1000 + 1000 + 500 = 2500, and player 1 holds both winning
    -- stakes, so the whole thing comes back to them.
    t.equals(server.cash(1), 5000 - 1000 - 500 + 2500)
    t.equals(server.cash(2), 4000)
end)

t.test('and the winner ALWAYS profits, because the pool holds the losers fees', function()
    -- The guarantee this arrangement exists for. With bets alone a winner
    -- can break even -- if everybody backed the same side there is nothing
    -- to win. With the fees in, every loser has put money up.
    local server, record = teamMatch({})
    record.players[1] = { src = 1, team = 'crimson' }
    record.players[2] = { src = 2, team = 'ash' }

    local before = server.cash(1)
    server.betting.Settle('m1', {
        teams = true, winners = { 1 }, contestants = 2,
        players = {
            { id = 1, team = 'crimson', stake = 1000, kills = 1 },
            { id = 2, team = 'ash', stake = 1000, kills = 0 },
        },
    })
    server.betting.SettleSpectatorBets('m1', 'crimson')

    t.isTrue(server.cash(1) > before,
        'the winner came out of a two-fee pool with no more than they went in with')
end)

t.test('money is conserved: the pool pays out exactly what went into it', function()
    local server, record = teamMatch({ [3] = 5000 })
    record.players[1] = { src = 1, team = 'crimson' }
    record.players[2] = { src = 2, team = 'ash' }

    server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 750)

    server.betting.Settle('m1', {
        teams = true, winners = { 1 }, contestants = 2,
        players = {
            { id = 1, team = 'crimson', stake = 1000, kills = 1 },
            { id = 2, team = 'ash', stake = 1000, kills = 0 },
        },
    })
    server.betting.SettleSpectatorBets('m1', 'crimson')

    local total = server.cash(1) + server.cash(2) + server.cash(3)
    t.equals(total, 5000 + 5000 + 5000,
        'the settlement created or destroyed money -- it is only ever allowed to move it')
end)

os.exit(t.summary())
