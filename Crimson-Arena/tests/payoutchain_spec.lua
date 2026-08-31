--[[
    crimson_arena/tests/payoutchain_spec.lua

    The seam between three files that were each individually correct.

    THE BUG THIS EXISTS FOR. When a player quits mid-round, the roster handed
    to the payout maths is the SURVIVING one -- and that is deliberate, because
    every refund branch pays `player.stake` back off that list, so listing a
    quitter would hand back the stake that leaving was supposed to forfeit.

    But `Config.Betting.minPlayersToPayOut` is asking a different question:
    was this a real fight, or two friends farming each other? That question is
    about how many people FOUGHT, not how many are still standing. Judged on
    survivors, a 1v1 where one player quits arrives with one name on the list,
    falls under the minimum, and refunds everybody -- handing the quitter back
    the stake they forfeited and paying the winner nothing for a fight they won.

    server/match.lua records `contestants` for exactly this. shared/arena.lua
    reads it. Both landed, both correct, and the exploit stayed live anyway,
    because server/betting.lua's Settle rebuilds the context FIELD BY FIELD and
    quietly dropped the one field they had just agreed on.

    Every existing spec passed. matchflow_spec asserts at the Settle boundary,
    so it sees the field going in. rulesdefects_spec calls ComputePayouts
    directly, so it sees the field being read. Neither crosses the line where
    it was lost. THAT is why this file drives the whole chain instead of
    either end of it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param wallets table<number, integer>
--- @param mutate fun(config: table)?
--- @return table server
local function newServer(wallets, mutate, opts)
    local roster = {}
    for id, cash in pairs(wallets) do
        roster[id] = {
            citizenid = ('CID%05d'):format(id),
            name = 'Player' .. id,
            money = { cash = cash, bank = 0 },
        }
    end

    local qbx = Sandbox.newQbxCore(roster, opts)
    local console = {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        print = function(line) console[#console + 1] = line end,
    })
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)

    return {
        env = env,
        betting = env.ArenaBetting,
        config = env.Config,
        cash = function(id) return qbx.players[id].money.cash end,
        --- Money created or destroyed across every account. Always zero: the
        --- pot only ever moves money between players.
        ledgerTotal = function()
            local total = 0
            for _, entry in ipairs(qbx.ledger) do total = total + entry.delta end
            return total
        end,
        log = function() return table.concat(console, '\n') end,
    }
end

--- A 1v1 where both players staked, then one walked out mid-round. The
--- survivor won. This is the exact shape the bug needed.
--- @param server table
--- @return table context -- as server/match.lua builds it at End
local function quitterContext(server)
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    return {
        -- The SURVIVING roster. Player 2 quit and is deliberately absent:
        -- their stake stays in the pot, which is what forfeiting means.
        players = { { id = 1, team = nil, kills = 1, stake = 1000, placement = 1 } },
        winners = { 1 },
        teams = false,
        -- How many the round was fought with.
        contestants = 2,
    }
end

-- ========================================================================
-- The chain
-- ========================================================================

t.test('the numbers below are the shipped ones', function()
    local config = newServer({}).config
    t.equals(config.Betting.minPlayersToPayOut, 2)
    t.equals(config.Betting.houseCutPercent, 0)
    t.equals(config.Betting.payout, 'winner_takes_all')
end)

t.test('a 1v1 quitter does not turn the winner\'s pot back into a refund', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    local payouts = server.betting.Settle('m1', quitterContext(server))

    t.equals(#payouts, 1, 'the winner should be paid, and only the winner')
    t.equals(payouts[1].id, 1)
    t.equals(payouts[1].reason, 'winner',
        'reason "refund_too_few" here is the bug: the round was fought by two people')
    t.equals(payouts[1].amount, 2000, 'the winner takes both stakes')
end)

t.test('the quitter does not get their forfeited stake back', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.Settle('m1', quitterContext(server))

    -- 5000 - 1000 staked, and nothing returned.
    t.equals(server.cash(2), 4000, 'leaving mid-round forfeits the stake')
    -- 5000 - 1000 staked + 2000 won.
    t.equals(server.cash(1), 6000)
end)

t.test('money is conserved across the settlement', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.Settle('m1', quitterContext(server))
    t.equals(server.ledgerTotal(), 0, 'the pot moved money between players, it did not create any')
end)

t.test('Settle forwards contestants rather than rebuilding the context without it', function()
    -- The direct statement of the defect. With the field dropped, the
    -- surviving roster of one falls under minPlayersToPayOut and every payout
    -- comes back as a refund.
    local server = newServer({ [1] = 5000, [2] = 5000 })
    local payouts = server.betting.Settle('m1', quitterContext(server))

    for _, payout in ipairs(payouts) do
        t.isTrue(payout.reason:sub(1, 6) ~= 'refund',
            ('payout for %s came back as "%s" -- contestants never reached the maths')
                :format(tostring(payout.id), tostring(payout.reason)))
    end
end)

-- ========================================================================
-- The cases the fix must NOT change
-- ========================================================================

t.test('a genuinely tiny match still refunds', function()
    -- One person, who fought alone. contestants agrees with the roster, so
    -- the minimum still bites -- the fix must not become a way to pay out a
    -- match nobody contested.
    local server = newServer({ [1] = 5000 })
    server.betting.TakeStake(1, 'm2', 1000)

    local payouts = server.betting.Settle('m2', {
        players = { { id = 1, kills = 0, stake = 1000, placement = 1 } },
        winners = { 1 },
        teams = false,
        contestants = 1,
    })

    t.equals(#payouts, 1)
    t.equals(payouts[1].reason, 'refund_too_few')
    t.equals(server.cash(1), 5000, 'the stake came back')
end)

t.test('a context with no contestants at all still works off the roster', function()
    -- Every caller sets it today, but a caller that forgets must degrade to
    -- the old behaviour rather than erroring or paying out wrongly.
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm3', 1000)
    server.betting.TakeStake(2, 'm3', 1000)

    local payouts = server.betting.Settle('m3', {
        players = {
            { id = 1, kills = 1, stake = 1000, placement = 1 },
            { id = 2, kills = 0, stake = 1000, placement = 2 },
        },
        winners = { 1 },
        teams = false,
    })

    t.equals(#payouts, 1)
    t.equals(payouts[1].reason, 'winner')
    t.equals(payouts[1].amount, 2000)
end)

t.test('an eliminated player who stayed is still owed a refund when the round does not qualify', function()
    -- Eliminated is not the same as gone. They fought to the end, so they stay
    -- on the roster and a refunding round owes them their stake back.
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm4', 1000)
    server.betting.TakeStake(2, 'm4', 1000)

    local payouts = server.betting.Settle('m4', {
        players = {
            { id = 1, kills = 0, stake = 1000, placement = 1 },
            { id = 2, kills = 0, stake = 1000, placement = 2 },
        },
        winners = {},
        teams = false,
        contestants = 2,
    })

    t.equals(#payouts, 2, 'both are owed')
    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
    t.equals(server.ledgerTotal(), 0)
end)

-- ========================================================================
-- A FRAMEWORK THAT SAYS NOTHING WHEN IT SUCCEEDS
--
-- The live defect these cover, and the reason the whole file above did not
-- catch it: every money movement was believed only if the framework returned
-- exactly `true`. Some builds return nil on success. On one of those, the
-- money left the player's pocket and the stake was recorded as never taken --
-- so the pot stayed empty, and a match everybody had paid for paid nobody
-- anything.
--
-- Nothing about the arithmetic was wrong. The fixture returned `true`, like
-- the documentation, and unlike the server. Seventy-three betting tests
-- passed against an API more generous than the real one.
--
-- The balance is the authority now, not the return value. These tests run the
-- same chain against a framework that reports success by staying quiet.
-- ========================================================================

t.test('a stake is recorded when the framework reports success by saying nothing', function()
    local server = newServer({ [1] = 5000, [2] = 5000 }, nil, { quiet = true })

    t.isTrue(server.betting.TakeStake(1, 'm1', 1000), 'the stake was refused after the money moved')
    t.equals(server.cash(1), 4000, 'the player was charged')
    t.equals(server.betting.GetPot('m1'), 1000,
        'the money left the player and the pot never saw it')
end)

t.test('and the pot pays out, which is the symptom that was actually reported', function()
    local server = newServer({ [1] = 5000, [2] = 5000 }, nil, { quiet = true })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    t.equals(server.betting.GetPot('m1'), 2000)
    t.equals(server.cash(1), 4000)
    t.equals(server.cash(2), 4000)

    server.betting.Settle('m1', {
        players = { { id = 1, stake = 1000, kills = 1 }, { id = 2, stake = 1000, kills = 0 } },
        winners = { 1 },
        teams = false,
        contestants = 2,
    })

    t.equals(server.cash(1), 6000, 'the winner was not paid')
    t.equals(server.cash(2), 4000, 'the loser got money back')
    t.equals(server.ledgerTotal(), 0, 'money was created or destroyed')
end)

t.test('an explicit refusal is still a refusal on a quiet framework', function()
    -- The one answer that means the same thing in every build. A fixture that
    -- blurred this too would be modelling nothing real -- and the fix must
    -- not turn "you cannot afford it" into a free stake.
    local server = newServer({ [1] = 100 }, nil, { quiet = true })

    t.isFalse(server.betting.TakeStake(1, 'm1', 1000), 'a player staked money they do not have')
    t.equals(server.cash(1), 100, 'and were charged for it')
    t.equals(server.betting.GetPot('m1'), 0)
end)

t.test('a refund reaches the player on a quiet framework too', function()
    local server = newServer({ [1] = 5000, [2] = 5000 }, nil, { quiet = true })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    server.betting.RefundAll('m1', 'cancelled')

    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
    t.equals(server.betting.GetPot('m1'), 0, 'the pot still claims to hold money')
    t.equals(server.ledgerTotal(), 0)
end)

-- ========================================================================
-- THE CONSOLE SAYS WHY A POT DID NOT PAY
--
-- A refunded pot and a broken one look identical to the players: money comes
-- back, nobody wins anything. Until now the difference was reported only to
-- a webhook, which ships off -- so an operator watching a match refund had
-- no way to tell "this match did not qualify" from "the arena is broken",
-- and reported the second when it was the first.
-- ========================================================================

t.test('a pot refunded for too few players says so, with the numbers behind it', function()
    local server = newServer({ [1] = 5000 }, function(config)
        config.Betting.minPlayersToPayOut = 2
    end)
    server.betting.TakeStake(1, 'm1', 1000)

    server.betting.Settle('m1', {
        players = { { id = 1, stake = 1000, kills = 0 } },
        winners = { 1 },
        teams = false,
        contestants = 1,
    })

    local console = server.log()
    t.contains(console, 'refunded its pot')
    t.contains(console, 'refund_too_few', 'the reason is not named')
    t.contains(console, 'minPlayersToPayOut', 'the setting that decided it is not named')
    t.equals(server.cash(1), 5000, 'the stake did not come back')
end)

t.test('a pot refunded for having no winner names that reason instead', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    server.betting.Settle('m1', {
        players = { { id = 1, stake = 1000 }, { id = 2, stake = 1000 } },
        winners = {},
        teams = false,
        contestants = 2,
    })

    t.contains(server.log(), 'refund_no_winner')
end)

t.test('a pot that DID pay says so too, so a quiet console means nothing ran', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    server.betting.Settle('m1', {
        players = { { id = 1, stake = 1000, kills = 1 }, { id = 2, stake = 1000, kills = 0 } },
        winners = { 1 },
        teams = false,
        contestants = 2,
    })

    local console = server.log()
    t.contains(console, 'paid out')
    t.notContains(console, 'refunded its pot')
    t.equals(server.cash(1), 6000)
end)

t.test('an empty pot says so rather than returning in silence', function()
    -- The path that made this hardest to diagnose. Settle returns
    -- immediately on an empty pot, before any of the other reporting, so a
    -- match that paid nobody produced no console output at all -- while
    -- side-bets, a separate pool, paid normally. That combination reads as
    -- "the pot is broken" and is not.
    local server = newServer({ [1] = 5000, [2] = 5000 })

    server.betting.Settle('m1', {
        players = { { id = 1, stake = 0 }, { id = 2, stake = 0 } },
        winners = { 1 },
        teams = false,
        contestants = 2,
    })

    local console = server.log()
    t.contains(console, 'NOTHING IN THE POT')
    t.contains(console, 'entry fee', 'the likely cause is not named')
    t.contains(console, 'Side-bets', 'the thing that DID pay is not distinguished')
    t.equals(server.cash(1), 5000, 'money moved from an empty pot')
end)

print('payoutchain_spec')
os.exit(t.summary())
