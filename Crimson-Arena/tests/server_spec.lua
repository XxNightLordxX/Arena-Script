--[[
    crimson_arena/tests/server_spec.lua

    The money, end to end, through the REAL server/util.lua and
    server/betting.lua -- loaded unmodified into a sandbox over the real
    config.lua and shared/arena.lua. betting_spec.lua proves the arithmetic;
    this file proves the plumbing around it: that the sums it computes are
    the sums that actually leave and enter a player's account, exactly once
    each.

    THE LEDGER, NOT THE BALANCE. Every assertion about a refund or a payout
    checks how many times money MOVED as well as where it ended up. A refund
    that ran twice and a refund that never ran leave the same balance behind
    -- the first pays the player twice out of a pot that only holds one
    stake, the second strands their money in escrow forever, and a balance
    check calls both of them fine.

    STUBS ARE MINIMAL AND LOUD. The only native either file reaches on these
    paths is TriggerClientEvent, and it is captured rather than swallowed
    because what a player is told about their own money is part of the
    invariant. Nothing else is stubbed: a file that grows a call to a native
    this env does not carry fails as a nil call naming that native, which is
    the failure worth having.

    server/lobby.lua is NOT loaded -- it is a later file in the load order
    and betting.lua only reads it, defensively, at run time. `fakeLobby`
    below supplies the one record shape it reads.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('server_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- Wallets for a set of server ids, in the shape Sandbox.newQbxCore wants.
--- Names matter: server/betting.lua captures one against every stake while
--- the player is still connected, precisely so a disconnect later still has
--- somebody to name.
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
--- betting.lua, and a fake qbx_core whose every money movement is recorded.
--- Fresh per test on purpose -- escrow is module state, so two tests
--- sharing an env would share a pot.
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
        -- Captured, not silenced: half of what this file asserts is that a
        -- refusal is LOUD, and the console is where that lands.
        print = function(line) console[#console + 1] = line end,
    })
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)

    local server = { env = env, qbx = qbx, lib = oxlib, betting = env.ArenaBetting, config = env.Config }

    --- @return integer
    function server.cash(id)
        return qbx.players[id].money.cash
    end

    --- Money created or destroyed across every account. Zero for anything the
    --- entry-fee pot does: it only ever moves money between players.
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

    --- Descriptions of what one player was told, in order.
    --- @param id integer
    --- @return string[]
    function server.told(id)
        local said = {}
        for _, toast in ipairs(toasts) do
            if toast.target == id then said[#said + 1] = toast.payload.description end
        end
        return said
    end

    return server
end

--- The one thing server/betting.lua reads out of the lobby: a record to
--- judge a side-bet against. Only the fields it actually touches are here
--- -- state, modeKey and the players map -- so a betting.lua that starts
--- reading a fourth one fails as a nil index rather than passing on a
--- fixture that agreed with it in advance.
--- @param records table<string, table>
--- @return table
local function fakeLobby(records)
    return { Get = function(matchId) return records[matchId] end }
end

--- Two fighters staked into one team match, with the lobby record wired up
--- so spectator bets have something to bet on.
--- @param spectators table<integer, integer>? -- [serverId] = starting cash
--- @param mutate fun(config: table)? -- applied before anything is staked
--- @return table server
local function teamMatch(spectators, mutate)
    local wallets = { [1] = 5000, [2] = 5000 }
    for id, cash in pairs(spectators or {}) do wallets[id] = cash end

    local server = newServer(wallets, mutate)
    server.env.ArenaLobby = fakeLobby({
        ['m1'] = {
            id = 'm1',
            state = 'lobby',
            modeKey = 'tdm',
            players = {
                [1] = { src = 1, team = 'crimson' },
                [2] = { src = 2, team = 'ash' },
            },
        },
    })

    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)
    return server
end

--- The settlement context ArenaMatch.End builds for that team match, with
--- crimson taking it.
--- @return table
local function teamContext()
    return {
        teams = true,
        winners = { 1 },
        players = {
            { id = 1, team = 'crimson', kills = 1, stake = 1000 },
            { id = 2, team = 'ash', kills = 0, stake = 1000 },
        },
    }
end

--- Four fighters staked into one free-for-all -- the shape every payout mode
--- below is settled against, so the only thing that differs between those
--- tests is the mode itself.
--- @param mutate fun(config: table)? -- applied before anything is staked
--- @param stakes integer[]? -- per fighter, in order; 1000 each by default
--- @return table server
local function ffaMatch(mutate, stakes)
    local server = newServer({ [1] = 5000, [2] = 5000, [3] = 5000, [4] = 5000 }, mutate)
    for id = 1, 4 do
        server.betting.TakeStake(id, 'm1', (stakes or {})[id] or 1000)
    end
    return server
end

--- The settlement context for that free-for-all. `winners` is in placement
--- order, best first: top_three reads it as the podium, every other mode as
--- the set of people who won.
--- @param winners integer[]
--- @param stakes integer[]?
--- @return table
local function ffaContext(winners, stakes)
    -- Lopsided kills on purpose. An even spread would make a per_kill split
    -- and an even split agree, and telling those two apart is the point.
    local kills = { 3, 1, 0, 0 }
    local players = {}
    for id = 1, 4 do
        players[id] = { id = id, kills = kills[id], stake = (stakes or {})[id] or 1000 }
    end
    return { teams = false, winners = winners, players = players }
end

-- ======================================================================
-- WHAT THESE TESTS ASSUME
-- ======================================================================

t.test('the shipped betting config is the one the numbers below assume', function()
    -- Every expected amount in this file is worked out by hand from these
    -- five settings. Change one in config.lua and the arithmetic here is
    -- wrong rather than the code -- so the mismatch is named here, once,
    -- instead of showing up as eight unrelated failures.
    local betting = newServer({}).config.Betting
    t.isTrue(betting.enabled)
    t.equals(betting.account, 'cash')
    t.equals(betting.houseCutPercent, 0)
    t.equals(betting.maxPot, 0, '0 means no ceiling')
    t.equals(betting.payout, 'winner_takes_all')
    t.equals(betting.minPlayersToPayOut, 2)
    t.equals(betting.entryFee.max, 50000)
    t.equals(betting.spectatorBets.oddsMultiplier, 2.0)
end)

-- ======================================================================
-- TAKING A STAKE
-- ======================================================================

t.test('TakeStake removes exactly the fee, once, and holds it against the match', function()
    local server = newServer({ [1] = 5000 })

    local ok, reason = server.betting.TakeStake(1, 'm1', 1000)
    t.isTrue(ok)
    t.isNil(reason)

    t.equals(server.cash(1), 4000)
    t.equals(server.qbx.net(1, 'cash'), -1000, 'the fee, and nothing but the fee')
    t.equals(server.qbx.movements(1), 1, 'one movement -- a fee taken twice nets the same as a fee and a refund')

    t.equals(server.betting.GetPot('m1'), 1000)
    t.equals(server.betting.GetStake('m1', 1), 1000)

    -- Recorded against the match, not just subtracted: an operator reading
    -- a qbx_core transaction log has to be able to find the match it went to.
    t.contains(server.qbx.ledger[1].reason, 'm1')
    t.contains(server.qbx.ledger[1].reason, 'stake')
end)

t.test('a stake the player cannot cover is refused and nothing is recorded', function()
    local server = newServer({ [1] = 500 })

    local ok, reason = server.betting.TakeStake(1, 'm1', 1000)
    t.isFalse(ok)
    t.equals(reason, 'error.not_enough_money')

    t.equals(server.cash(1), 500, 'a refused stake must not touch the account')
    t.equals(server.qbx.movements(1), 0)
    t.equals(server.betting.GetPot('m1'), 0)
    t.equals(server.betting.GetStake('m1', 1), 0)
    t.equals(#server.told(1), 0, 'nothing was taken, so there is nothing to tell them about')

    -- Nothing is held, so the match id is clean and can be dropped. A
    -- refusal that half-recorded the stake would fail here, not above.
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('a fee outside the configured band never reaches the account', function()
    local server = newServer({ [1] = 500000 })

    local ok, reason = server.betting.TakeStake(1, 'm1', 60000)
    t.isFalse(ok)
    t.equals(reason, 'error.bet_out_of_range')
    t.equals(server.qbx.movements(1), 0)
    t.equals(server.betting.GetPot('m1'), 0)
end)

t.test('one seat cannot be staked twice', function()
    local server = newServer({ [1] = 5000 })

    t.isTrue(server.betting.TakeStake(1, 'm1', 1000))
    local ok, reason = server.betting.TakeStake(1, 'm1', 1000)

    t.isFalse(ok)
    t.equals(reason, 'error.bet_already_staked')
    t.equals(server.qbx.movements(1), 1, 'the second take must not reach the account')
    t.equals(server.betting.GetPot('m1'), 1000, 'a pot of 2000 backed by one refundable stake')
    t.contains(server.log(), 'DOUBLE STAKE REFUSED')
end)

t.test('with betting switched off nothing is taken and the join still succeeds', function()
    -- A free match must not become unjoinable because there is no pot.
    local server = newServer({ [1] = 5000 }, function(config) config.Betting.enabled = false end)

    local ok, reason = server.betting.TakeStake(1, 'm1', 1000)
    t.isTrue(ok)
    t.isNil(reason)
    t.equals(server.qbx.movements(1), 0)
    t.equals(server.betting.GetPot('m1'), 0)
end)

t.test('the player is told about their own money, through the arena toast and nowhere else', function()
    local server = newServer({ [1] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.RefundOne('m1', 1, 'notify.match_cancelled')

    local said = server.told(1)
    t.equals(#said, 2, 'one line for the stake, one for the refund')
    t.contains(said[1], '$1000')
    t.contains(said[2], '$1000')

    -- Through server/util.lua's notify, which is the only path that carries
    -- the arena's own title -- a bare lib.notify from the server realm would
    -- reach nobody at all.
    t.equals(#server.lib.notifications, 0)
end)

-- ======================================================================
-- REFUNDS
-- ======================================================================

t.test('RefundAll returns every stake, each to the player who paid it', function()
    -- Deliberately unequal: an even split of the pot balances the books
    -- while quietly moving money between players, and equal stakes hide it.
    local server = newServer({ [1] = 5000, [2] = 5000, [3] = 9000 })
    server.betting.TakeStake(1, 'm1', 500)
    server.betting.TakeStake(2, 'm1', 1000)
    server.betting.TakeStake(3, 'm1', 5000)
    t.equals(server.betting.GetPot('m1'), 6500)

    local ok, refunded, total = server.betting.RefundAll('m1', 'notify.match_cancelled')
    t.isTrue(ok, 'nothing may still be owed')
    t.equals(refunded, 3)
    t.equals(total, 6500)

    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
    t.equals(server.cash(3), 9000)
    t.equals(server.ledgerTotal(), 0, 'the refund created nothing and destroyed nothing')
    t.equals(server.betting.GetPot('m1'), 0)
end)

t.test('a second RefundAll pays nothing -- counted in movements, not balances', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 500)
    server.betting.TakeStake(2, 'm1', 1000)
    server.betting.RefundAll('m1', 'notify.match_cancelled')

    local before = server.movementCount()
    local ok, refunded, total = server.betting.RefundAll('m1', 'notify.match_cancelled')

    t.isTrue(ok, 'nothing is owed, so the second sweep is a success that pays nobody')
    t.equals(refunded, 0)
    t.equals(total, 0)

    -- THE ASSERTION THIS TEST EXISTS FOR. The balances are already right
    -- after one refund and would still look right after two, because the
    -- second one would come out of a pot that no longer exists.
    t.equals(server.movementCount(), before, 'the second sweep moved money')
    t.equals(server.qbx.movements(1), 2, 'one out, one back')
    t.equals(server.qbx.movements(2), 2)
    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
end)

t.test('RefundOne refuses a stake it has already returned, and says so out loud', function()
    local server = newServer({ [1] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)

    t.isTrue(server.betting.RefundOne('m1', 1, 'notify.match_cancelled'))
    t.isFalse(server.betting.RefundOne('m1', 1, 'notify.match_cancelled'))

    t.equals(server.qbx.movements(1), 2)
    t.equals(server.cash(1), 5000)
    t.contains(server.log(), 'DOUBLE REFUND REFUSED')

    -- A stake nobody ever took is a different mistake and gets its own line.
    t.isFalse(server.betting.RefundOne('m1', 2, 'notify.match_cancelled'))
    t.contains(server.log(), 'REFUND IGNORED')
end)

-- ======================================================================
-- SETTLEMENT
-- ======================================================================

t.test('Settle pays the whole pot out and creates nothing', function()
    local server = newServer({ [1] = 5000, [2] = 5000, [3] = 5000, [4] = 5000 })
    for id = 1, 4 do server.betting.TakeStake(id, 'm1', 1000) end
    t.equals(server.betting.GetPot('m1'), 4000)

    local payouts = server.betting.Settle('m1', {
        teams = false,
        winners = { 1 },
        players = {
            { id = 1, kills = 3, stake = 1000 },
            { id = 2, kills = 0, stake = 1000 },
            { id = 3, kills = 0, stake = 1000 },
            { id = 4, kills = 0, stake = 1000 },
        },
    })

    t.equals(#payouts, 1)
    t.equals(payouts[1].id, 1)
    t.equals(payouts[1].amount, 4000)
    t.equals(payouts[1].reason, 'winner')

    t.equals(server.cash(1), 8000, 'their own stake back plus the other three')
    t.equals(server.qbx.movements(1), 2, 'one stake out, one pot in')
    for id = 2, 4 do
        t.equals(server.cash(id), 4000)
        t.equals(server.qbx.movements(id), 1)
    end
    t.equals(server.ledgerTotal(), 0, 'the pot paid out is exactly the pot taken in')

    -- Spent in full, so the match holds nothing and may be dropped.
    t.equals(server.betting.GetPot('m1'), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('Settle pays the net pot when the house takes a cut, and not a dollar more', function()
    local server = newServer({ [1] = 5000, [2] = 5000, [3] = 5000 },
        function(config) config.Betting.houseCutPercent = 10 end)
    for id = 1, 3 do server.betting.TakeStake(id, 'm1', 1000) end

    local payouts = server.betting.Settle('m1', {
        teams = false,
        winners = { 1 },
        players = {
            { id = 1, kills = 2, stake = 1000 },
            { id = 2, kills = 0, stake = 1000 },
            { id = 3, kills = 0, stake = 1000 },
        },
    })

    t.equals(#payouts, 1)
    t.equals(payouts[1].amount, 2700, '3000 less the 10% house cut')
    t.equals(server.cash(1), 6700)
    t.equals(server.ledgerTotal(), -300, 'the house keeps the cut and nothing else leaves the world')
    t.equals(server.betting.GetPot('m1'), 0)
end)

t.test('top_three pays each place its configured share, remainder and all', function()
    -- The odd stake is what stops 60/30/10 dividing the pot cleanly. Two
    -- dollars are left over after the three percentages are taken, and they
    -- have to land on somebody: a split that "balances" by dropping them
    -- shrinks the pot by a couple of dollars every single match.
    local stakes = { 1000, 1000, 1000, 999 }
    local server = ffaMatch(function(config) config.Betting.payout = 'top_three' end, stakes)
    t.equals(server.betting.GetPot('m1'), 3999)

    local payouts = server.betting.Settle('m1', ffaContext({ 1, 2, 3 }, stakes))

    t.equals(#payouts, 3)
    t.equals(payouts[1].amount, 2401, '60% of 3999, plus the 2 no other share could carry')
    t.equals(payouts[2].amount, 1199)
    t.equals(payouts[3].amount, 399)
    t.equals(payouts[1].reason, 'placement')

    t.equals(server.cash(1), 6401)
    t.equals(server.cash(2), 5199)
    t.equals(server.cash(3), 4399)
    t.equals(server.cash(4), 4001, 'fourth place staked and takes nothing home')
    t.equals(server.qbx.movements(4), 1, 'off the podium is one movement, not two')
    t.equals(server.ledgerTotal(), 0, 'the pot paid out is exactly the pot taken in')
    t.equals(server.betting.GetPot('m1'), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('top_three in a team match pays the winning side, not a podium', function()
    -- topThreeSplit is free-for-all only. Ranking two sides onto a podium
    -- would pay the LOSING team's runner-up out of the winners' pot, so the
    -- mode falls back rather than doing it -- and the fallback is what an
    -- operator who set top_three on a team server actually gets.
    local server = teamMatch(nil, function(config) config.Betting.payout = 'top_three' end)
    t.equals(server.betting.GetPot('m1'), 2000)

    local payouts = server.betting.Settle('m1', teamContext())

    t.equals(#payouts, 1)
    t.equals(payouts[1].id, 1)
    t.equals(payouts[1].amount, 2000)
    t.equals(payouts[1].reason, 'winner', 'not a placement -- nothing was placed')
    t.equals(server.cash(1), 6000)
    t.equals(server.cash(2), 4000)
    t.equals(server.ledgerTotal(), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('per_kill splits the pot by share of the kills and skips whoever scored none', function()
    local server = ffaMatch(function(config) config.Betting.payout = 'per_kill' end)
    t.equals(server.betting.GetPot('m1'), 4000)

    -- 4 kills between them, 3 to one player and 1 to another: three quarters
    -- and one quarter of 4000.
    local payouts = server.betting.Settle('m1', ffaContext({ 1 }))

    t.equals(#payouts, 2, 'two players scored; the other two are not on the sheet at all')
    t.equals(payouts[1].id, 1)
    t.equals(payouts[1].amount, 3000)
    t.equals(payouts[1].reason, 'per_kill')
    t.equals(payouts[2].id, 2)
    t.equals(payouts[2].amount, 1000)

    t.equals(server.cash(1), 7000)
    t.equals(server.cash(2), 5000, 'a player who scored is paid whether or not they won')
    t.equals(server.cash(3), 4000)
    t.equals(server.cash(4), 4000)
    t.equals(server.qbx.movements(3), 1, 'staked, and never paid')
    t.equals(server.ledgerTotal(), 0)
    t.equals(server.betting.GetPot('m1'), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('a payout mode nobody implemented pays the winner rather than stranding the pot', function()
    -- A typo in config.lua is an operator's mistake to make; four people's
    -- stakes sitting in escrow with nobody left to hand them to is not the
    -- punishment for it.
    local server = ffaMatch(function(config) config.Betting.payout = 'winner_take_all' end)

    local payouts = server.betting.Settle('m1', ffaContext({ 1 }))

    t.equals(#payouts, 1)
    t.equals(payouts[1].amount, 4000)
    t.equals(payouts[1].reason, 'winner')
    t.equals(server.cash(1), 8000)
    t.equals(server.ledgerTotal(), 0)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('every payout mode spends the net pot exactly and leaves escrow empty', function()
    -- What each test above claims in its own arithmetic, claimed once as a
    -- property across every mode an operator can set: the money that leaves
    -- escrow is the pot less the house cut. Never a dollar more -- that is
    -- money invented out of a pot that never held it -- and never a dollar
    -- less, which is a stake stranded in a match record about to be dropped.
    for _, mode in ipairs({ 'winner_takes_all', 'top_three', 'per_kill', 'a mode nobody wrote' }) do
        local server = ffaMatch(function(config)
            config.Betting.payout = mode
            config.Betting.houseCutPercent = 10
        end)

        local payouts = server.betting.Settle('m1', ffaContext({ 1, 2, 3 }))

        local paid = 0
        for _, payout in ipairs(payouts) do paid = paid + payout.amount end

        t.isTrue(#payouts > 0, mode .. ': settled a full pot and decided nobody')
        t.equals(paid, 3600, mode .. ': 4000 less the 10% cut')
        t.equals(server.ledgerTotal(), -400, mode .. ': the house kept the cut and nothing else left')
        t.equals(server.betting.GetPot('m1'), 0, mode .. ': escrow still holds something')
        t.isTrue(server.betting.Clear('m1'), mode .. ': a spent pot must be droppable')
    end
end)

t.test('a second Settle pays nothing', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    local context = {
        teams = false,
        winners = { 1 },
        players = {
            { id = 1, kills = 1, stake = 1000 },
            { id = 2, kills = 0, stake = 1000 },
        },
    }
    server.betting.Settle('m1', context)
    local before = server.movementCount()

    t.equals(#server.betting.Settle('m1', context), 0, 'a spent pot has nothing left to decide')
    t.equals(server.movementCount(), before, 'the second settlement moved money')
    t.equals(server.cash(1), 6000)
end)

-- ======================================================================
-- CLEARING
-- ======================================================================

t.test('Clear refuses while the pot is still held, and drops nothing', function()
    local server = newServer({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    t.isFalse(server.betting.Clear('m1'))
    t.contains(server.log(), 'CLEAR REFUSED')

    -- The refusal is only worth anything if the money is still reachable
    -- afterwards, which is what makes a later refund possible.
    t.equals(server.betting.GetPot('m1'), 2000)
    t.equals(server.betting.GetStake('m1', 1), 1000)

    t.isTrue(server.betting.RefundAll('m1', 'notify.match_cancelled'))
    t.isTrue(server.betting.Clear('m1'))
    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
end)

-- ======================================================================
-- THE POT CEILING
-- ======================================================================

t.test('maxPot caps the pot, and the stake that would breach it is refused whole', function()
    local server = newServer({ [1] = 5000, [2] = 5000, [3] = 5000 },
        function(config) config.Betting.maxPot = 1500 end)

    t.isTrue(server.betting.TakeStake(1, 'm1', 1000))

    local ok, reason = server.betting.TakeStake(2, 'm1', 1000)
    t.isFalse(ok, 'that stake would put the pot at 2000')
    t.equals(reason, 'error.pot_limit_reached')
    t.equals(server.qbx.movements(2), 0, 'refused whole -- not taken and trimmed to fit')
    t.equals(server.betting.GetPot('m1'), 1000)

    -- The ceiling is a ceiling, not a wall short of it: a stake that lands
    -- exactly on it is allowed.
    t.isTrue(server.betting.TakeStake(2, 'm1', 500))
    t.equals(server.betting.GetPot('m1'), 1500)

    t.isFalse(server.betting.TakeStake(3, 'm1', 1))
    t.equals(server.qbx.movements(3), 0)
    t.equals(server.betting.GetPot('m1'), 1500)

    -- A capped pot is still a pot: it refunds like any other.
    t.isTrue(server.betting.RefundAll('m1', 'notify.match_cancelled'))
    t.equals(server.ledgerTotal(), 0)
end)

-- ======================================================================
-- SPECTATOR SIDE-BETS
-- ======================================================================

t.test('a spectator side-bet never reaches the fighters pot', function()
    local server = teamMatch({ [3] = 3000 })
    t.equals(server.betting.GetPot('m1'), 2000)

    local ok, reason = server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000)
    t.isTrue(ok)
    t.isNil(reason)
    t.isTrue(server.betting.HasSpectatorBet('m1', 3))
    t.equals(server.cash(3), 2000, 'the bet left the spectator')

    -- THE POINT: a bystander cannot change what the winner takes home.
    t.equals(server.betting.GetPot('m1'), 2000)

    local payouts = server.betting.Settle('m1', teamContext())
    t.equals(#payouts, 1)
    t.equals(payouts[1].amount, 2000, 'the two entry fees, not the side-bet as well')
    t.equals(server.cash(1), 6000)

    -- The side-bet is house action, settled on its own terms at the
    -- configured odds and out of nobody's stake.
    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')
    t.equals(paid, 1)
    t.equals(total, 2000)
    t.equals(server.cash(3), 4000)
    t.equals(server.qbx.net(3, 'cash'), 1000)
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('a losing side-bet is kept by the house, not added to the pot', function()
    local server = teamMatch({ [4] = 3000 })
    t.isTrue(server.betting.PlaceSpectatorBet(4, 'm1', 'ash', 1000))
    t.equals(server.betting.GetPot('m1'), 2000)

    local payouts = server.betting.Settle('m1', teamContext())
    t.equals(payouts[1].amount, 2000, 'a lost side-bet is not the winner\'s to take')

    local paid, total = server.betting.SettleSpectatorBets('m1', 'crimson')
    t.equals(paid, 0)
    t.equals(total, 0)
    t.equals(server.cash(4), 2000)
    t.equals(server.qbx.movements(4), 1, 'money out, and nothing back')
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('Clear hands back a side-bet nothing ever judged', function()
    -- The match is gone, so there is nothing left to settle the bet
    -- against. The house has no claim on a bet it never resolved.
    local server = teamMatch({ [3] = 3000 })
    t.isTrue(server.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 1000))
    t.isTrue(server.betting.RefundAll('m1', 'notify.match_cancelled'))

    t.isTrue(server.betting.Clear('m1'))
    t.contains(server.log(), 'unresolved side-bet')
    t.equals(server.cash(3), 3000)
    t.equals(server.qbx.movements(3), 2, 'out once, back once')
    t.equals(server.ledgerTotal(), 0)
end)

os.exit(t.summary())
