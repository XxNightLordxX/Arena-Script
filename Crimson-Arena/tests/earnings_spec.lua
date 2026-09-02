--[[
    crimson_arena/tests/earnings_spec.lua

    WHAT A PLAYER IS TOLD THEY EARNED, AND WHAT THE BOARD REMEMBERS.

    Two readers, one number, and until this file they could not agree on a
    default server -- because the number they both read was empty.

    `ArenaBetting.Settle` hands back the list of who it paid, and both the
    results board on the player's screen and the all-time leaderboard are
    derived from that list. With `betPayout.includeEntryPot` on -- which is
    how this ships -- Settle does not pay anybody: it folds the entry stakes
    into the bet pool and returns `{}`, and the money is paid a line further
    down by `SettleSpectatorBets`. So on the shipped configuration:

      THE WINNER WAS TOLD THEY EARNED NOTHING while the pot arrived in their
      pocket, and

      THE LEADERBOARD RECORDED ZERO for every player, for ever.

    Neither is visible from a balance -- the money really does move -- which
    is why nothing caught it. The rules this file holds:

      EARNINGS ARE WHAT WAS PAID, whichever of the two settlements paid it.

      THE BOARD AND THE LEADERBOARD ARE THE SAME NUMBER, by construction and
      not by two readers happening to agree.

      A REFUND IS NOT EARNINGS, including the uncontested-pool refund. Money
      handed back is money you already had.

    The real `server/stats.lua` is loaded rather than stubbed, because the
    defect lived in the handoff between it and the settlement, and a stub is
    exactly the thing that cannot have a handoff.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('earnings_spec')

--- A two-fighter server with the real stats module in it.
--- @param mutate function? -- last word on Config
local function newServer(mutate)
    local players = {}
    for src = 1, 3 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent = {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
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
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 1
    env.Config.Betting.enabled = true
    if mutate then mutate(env.Config) end

    -- `stats` is in this list and stubbed nowhere: the defect was in the
    -- handoff between it and the settlement.
    for _, file in ipairs({ 'util', 'stats', 'betting', 'lobby', 'match', 'main' }) do
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

    --- The results board this player was actually sent.
    function server.resultsFor(src)
        local found
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:results' and message.target == src then
                found = message.payload
            end
        end
        return found
    end

    --- The all-time board, as a { [name] = earnings } map.
    function server.leaderboard()
        local out = {}
        env.ArenaStats.GetLeaderboard(function(rows)
            for _, row in ipairs(rows or {}) do out[row.name] = row.earnings end
        end)
        return out
    end

    --- Opens a `fee` match between 1 and 2, runs it, and 2 loses.
    function server.playMatch(fee)
        server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = fee, account = 'cash' })
        local matchId = server.lobby.All()[1].id
        server.fire('joinMatch', 2, { matchId = matchId, account = 'cash' })
        return matchId
    end

    function server.finish(matchId, loser)
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.match.Start(matchId)
        threads.step()
        server.match.OnDeath(loser, loser == 1 and 2 or 1)
        for _ = 1, 8 do threads.step() end
    end

    return server
end

-- ======================================================================
-- EARNINGS ARE WHAT WAS PAID
-- ======================================================================

t.test('DEFECT: the winner of a shipped-config match is told what they won', function()
    -- includeEntryPot ships ON, which is the whole point: this is the
    -- default path, and it was the broken one.
    local server = newServer()
    t.isTrue(server.config.Betting.betPayout.includeEntryPot,
        'the shipped default changed -- this test is aimed at the wrong path')

    server.finish(server.playMatch(5000), 2)

    local results = server.resultsFor(1)
    t.isNotNil(results, 'the winner was sent no results board at all')
    t.equals(results.earnings, 10000, 'the board told the winner they earned this')
end)

t.test('DEFECT: and the all-time board records it too', function()
    local server = newServer()
    server.finish(server.playMatch(5000), 2)
    t.equals(server.leaderboard()['Fighter 1'], 10000, 'the leaderboard recorded the winner at this')
end)

t.test('and the loser earned nothing, in both places', function()
    local server = newServer()
    server.finish(server.playMatch(5000), 2)
    t.equals(server.resultsFor(2).earnings, 0, 'the loser was told they earned something')
    t.equals(server.leaderboard()['Fighter 2'], 0, 'the leaderboard credited the loser')
end)

t.test('the pot settling on its own reports the SAME number', function()
    -- The other path, and the one that was already right. Both have to
    -- answer identically or the leaderboard means different things on two
    -- servers running the same arena.
    local shipped = newServer()
    shipped.finish(shipped.playMatch(5000), 2)

    local separate = newServer(function(config) config.Betting.betPayout.includeEntryPot = false end)
    separate.finish(separate.playMatch(5000), 2)

    t.equals(separate.resultsFor(1).earnings, shipped.resultsFor(1).earnings,
        'the two settlement paths report different earnings for the same match')
    t.equals(separate.leaderboard()['Fighter 1'], shipped.leaderboard()['Fighter 1'],
        'the two settlement paths record different earnings for the same match')
end)

t.test('the board on screen and the board on record never disagree', function()
    -- Written as an equality between the two readers rather than against a
    -- number, because the failure was not a wrong figure -- it was two
    -- readers of one empty list.
    for _, fee in ipairs({ 0, 1000, 5000, 25000 }) do
        local server = newServer()
        server.finish(server.playMatch(fee), 2)
        t.equals(server.leaderboard()['Fighter 1'], server.resultsFor(1).earnings,
            ('at a fee of %d the screen and the record disagree'):format(fee))
    end
end)

t.test('a free match earns nobody anything, and says so', function()
    local server = newServer()
    server.finish(server.playMatch(0), 2)
    t.equals(server.resultsFor(1).earnings, 0, 'a free match paid the winner something')
    t.equals(server.leaderboard()['Fighter 1'], 0, 'a free match recorded earnings')
end)

-- ======================================================================
-- A REFUND IS NOT EARNINGS
-- ======================================================================

t.test('a returned side-bet is not counted as money the player made', function()
    -- The uncontested-pool refund is the newest way to get money back
    -- without having won anything, and the oldest rule in this area is that
    -- getting your own stake back is not earnings.
    local server = newServer()
    local matchId = server.playMatch(0)
    t.isTrue(server.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'cash'),
        'the self-bet was refused')

    server.finish(matchId, 2)

    t.equals(server.cash(1), 100000, 'the uncontested bet was not handed back')
    t.equals(server.resultsFor(1).earnings, 0, 'a refund was reported as earnings')
    t.equals(server.leaderboard()['Fighter 1'], 0, 'a refund was recorded as earnings')
end)

t.test('but a side-bet actually won IS', function()
    -- The other side of the same rule. A fighter who backs themselves against
    -- a real backer and wins has earned that money in this match.
    local server = newServer()
    local matchId = server.playMatch(0)
    -- 3 never joins: a fighter backing another fighter is refused, so the
    -- other side of this pool has to come from somebody watching.
    t.isTrue(server.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'cash'), 'fighter backs themselves')
    t.isTrue(server.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'), 'a spectator backs the other')

    server.finish(matchId, 2)

    t.equals(server.cash(1), 105000, 'the winner did not take the pool')
    t.equals(server.resultsFor(1).earnings, 10000, 'the won pool was not reported as earnings')
    t.equals(server.leaderboard()['Fighter 1'], 10000, 'the won pool was not recorded as earnings')
end)

os.exit(t.summary())
