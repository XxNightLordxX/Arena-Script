--[[
    crimson_arena/tests/selfbet_spec.lua

    BETTING ON YOURSELF WITH NOBODY ON THE OTHER SIDE.

    Reported from a live server, in one sentence: "self betting on yourself
    and no one else bets just takes your money." Two separate defects made
    that true, and both of them are invisible from a balance alone -- which
    is why this file asserts on BOTH pockets after every round.

      THE PAYOUT FORGOT WHICH POCKET PAID. returnSideBet has always handed a
      refund back to the account the stake left; the winning payout did not,
      so it fell to whichever account the operator lists first. Back yourself
      from the bank and win, and the money arrived as cash: bank permanently
      down by the stake, cash up by it, and a player watching their bank
      balance has watched the arena take five thousand off them.

      AN UNCONTESTED POOL WAS PAID AS A WIN. A pool bet is other people's
      money; with nobody backing another side the pool IS your own stake, so
      the share works out to exactly what you put in. The player was told
      they had won, and their balance did not move. Returned and described as
      a return is the honest answer, and it is now the one the code gives.

    The rule this file holds, in both directions and from either pocket:

      A LONE BETTER ON THEMSELVES ENDS THE ROUND WHOLE, in the account they
      paid from, whether they win the fight or lose it.

    Everything runs a real match to a real ending -- the bug only appears at
    settlement, and a spec that stops at placement cannot see it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('selfbet_spec')

--- A two-fighter server with one life each, so a single death decides it.
--- @param wallets table<integer, table> -- [src] = { cash = n, bank = n }
--- @param mutate function? -- last word on Config, before the files load
local function newServer(wallets, mutate)
    local players = {}
    for src, money in pairs(wallets) do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = money.cash or 0, bank = money.bank or 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console = {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    -- One life apiece: the sweep decides the round on the first death, which
    -- is the only reason this spec can reach settlement in a handful of steps.
    env.Config.Match.lives = 1
    env.Config.Betting.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, match = env.ArenaMatch, lobby = env.ArenaLobby }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    --- Opens a free lobby with 1 and 2 in it and returns the match id.
    function server.openMatch()
        server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id, account = 'cash' })
        return match.id
    end

    --- Runs the round to its end, with `loser` dying to the other fighter.
    function server.settle(matchId, loser)
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.match.Start(matchId)
        threads.step()
        server.match.OnDeath(loser, loser == 1 and 2 or 1)
        -- The sweep runs once per step; a handful covers the end, the exit
        -- and the delayed revive without depending on how many it takes.
        for _ = 1, 8 do threads.step() end
    end

    return server
end

-- ======================================================================
-- THE REPORT, IN BOTH DIRECTIONS AND FROM BOTH POCKETS
-- ======================================================================

--- Backs themselves for `stake` out of `account`, fights, and reports what
--- each pocket looks like afterwards against what it looked like before.
--- @return table before, table after
local function loneSelfBet(account, stake, outcome)
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
    })
    local matchId = server.openMatch()

    local before = { cash = server.cash(1), bank = server.bank(1) }
    local ok, reason = server.betting.PlaceSpectatorBet(1, matchId, 1, stake, account)
    if not ok then error('the self-bet was refused: ' .. tostring(reason), 2) end

    server.settle(matchId, outcome == 'win' and 2 or 1)
    return before, { cash = server.cash(1), bank = server.bank(1) }, server
end

for _, account in ipairs({ 'cash', 'bank' }) do
    for _, outcome in ipairs({ 'win', 'lose' }) do
        t.test(('a lone %s-funded self-bet leaves both pockets whole on a %s'):format(account, outcome), function()
            local before, after = loneSelfBet(account, 5000, outcome)
            t.equals(after.cash, before.cash, 'cash after a lone self-bet')
            t.equals(after.bank, before.bank, 'bank after a lone self-bet')
        end)
    end
end

t.test('the money never crosses accounts on the way back', function()
    -- The defect that started this: bank out, cash in. Balances that merely
    -- SUM correctly would pass the checks above if they were written on the
    -- total, so the two pockets are asserted apart and this says why.
    local before, after = loneSelfBet('bank', 5000, 'win')
    t.equals(before.bank - after.bank, 0, 'bank drained by a winning self-bet')
    t.equals(after.cash - before.cash, 0, 'cash invented by a winning self-bet')
end)

t.test('an uncontested pool is returned, not paid out as a win', function()
    local _, _, server = loneSelfBet('cash', 5000, 'win')
    t.contains(server.log(), 'SIDE-BET UNCONTESTED',
        'the console says the pool was uncontested')
    t.notContains(server.log(), 'settled side-bets',
        'nothing was settled out of a pool with one side in it')
end)

-- ======================================================================
-- AND A CONTESTED POOL STILL PAYS
-- ======================================================================
--
-- The fix above is a refund, and a refund is exactly what a broken payout
-- looks like from a balance. These are the tests that stop "return
-- everything" from passing this file.

t.test('a real bet against a self-bet still settles out of the pool', function()
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
        [3] = { cash = 100000, bank = 100000 },
    })
    local matchId = server.openMatch()

    -- 1 backs themselves; 3 is a spectator backing 2. Two sides, one pool.
    t.isTrue(server.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'cash'), 'fighter backs themselves')
    t.isTrue(server.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'), 'spectator backs the other fighter')

    server.settle(matchId, 2)

    t.equals(server.cash(1), 105000, 'the winning fighter takes the whole pool')
    t.equals(server.cash(3), 95000, 'the losing spectator paid for it')
end)

t.test('a contested pool pays the winner into the account they bet from', function()
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
        [3] = { cash = 100000, bank = 100000 },
    })
    local matchId = server.openMatch()

    t.isTrue(server.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'bank'), 'fighter backs themselves from the bank')
    t.isTrue(server.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'), 'spectator backs the other fighter')

    server.settle(matchId, 2)

    t.equals(server.bank(1), 105000, 'the payout landed in the bank the stake left')
    t.equals(server.cash(1), 100000, 'and did not appear as cash')
end)

t.test('a losing self-bet against a real backer is genuinely lost', function()
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
        [3] = { cash = 100000, bank = 100000 },
    })
    local matchId = server.openMatch()

    t.isTrue(server.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'cash'), 'fighter backs themselves')
    t.isTrue(server.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'), 'spectator backs the other fighter')

    server.settle(matchId, 1)

    t.equals(server.cash(1), 95000, 'the self-bet lost its stake')
    t.equals(server.cash(3), 105000, 'and the backer of the winner took it')
end)

-- ======================================================================
-- THE POT PAYS INTO THE POCKET THAT PAID, TOO
-- ======================================================================

--- Opens a `fee` lobby with 1 paying from `account` and 2 from cash, runs it
--- to an end with `loser` dying, and hands the server back.
--- @param mutate function? -- Config, before the files load
local function potRound(fee, account, loser, mutate)
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
    }, mutate)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = fee, account = account })
    local matchId = server.lobby.All()[1].id
    server.fire('joinMatch', 2, { matchId = matchId, account = 'cash' })
    server.settle(matchId, loser)
    return server
end

--- The shipped default folds entry fees into the side-bet pool, so the pot's
--- OWN payout only runs with that switched off. Both routes have to place the
--- money in the right pocket, and only one of them is the default.
local function separatePot(config) config.Betting.betPayout.includeEntryPot = false end

t.test('a bank-funded entry fee is won back into the bank', function()
    local server = newServer({
        [1] = { cash = 100000, bank = 100000 },
        [2] = { cash = 100000, bank = 100000 },
    })
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 5000, account = 'bank' })
    local matchId = server.lobby.All()[1].id
    server.fire('joinMatch', 2, { matchId = matchId, account = 'cash' })

    t.equals(server.bank(1), 95000, 'the host paid from the bank')
    t.equals(server.cash(2), 95000, 'and the joiner from their pocket')

    server.settle(matchId, 2)

    t.isTrue(server.bank(1) > 95000, 'the winner was paid back into the bank')
    t.equals(server.cash(1), 100000, 'and the pot did not turn into cash')
end)

t.test('the pot pays a bank-funded winner into their bank', function()
    local server = potRound(5000, 'bank', 2, separatePot)
    t.contains(server.log(), 'paid out', 'the pot settled on its own rather than through the pool')
    t.equals(server.bank(1), 105000, 'the pot landed in the bank the entry fee left')
    t.equals(server.cash(1), 100000, 'and did not appear as cash')
end)

t.test('the pot still pays a cash-funded winner into their cash', function()
    local server = potRound(5000, 'cash', 2, separatePot)
    t.equals(server.cash(1), 105000, 'the pot landed in the cash the entry fee left')
    t.equals(server.bank(1), 100000, 'and did not appear in the bank')
end)

-- ======================================================================
-- WHAT THE OPERATOR IS TOLD
-- ======================================================================

t.test('a pool that paid out is not also reported as kept', function()
    -- Two 5,000 entry fees folded into the pool, all 10,000 paid to the
    -- winner. The loser's stake went to the winner, not to the house, so a
    -- line claiming the arena kept 5,000 of it is describing a skim that
    -- did not happen.
    local server = potRound(5000, 'cash', 2)
    t.contains(server.log(), 'paid 10000, 0 kept', 'the house kept nothing out of a pool')
end)

os.exit(t.summary())
