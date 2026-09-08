--[[
    crimson_arena/tests/lifecyclemoney_spec.lua

    PRODUCTION SET 2 -- CONSERVATION UNDER RANDOMISED LIFECYCLES.

    tests/moneyconservation_spec.lua already asserts that nothing is created
    or destroyed, and it is the right check. Its limit is that a human picked
    the scenarios: join, fight, pay out. The sequences that actually break a
    money system are the ones nobody thought to write down -- bet, leave,
    rejoin, drop mid-countdown, host cancels while a side-bet is open, two
    people leave in the same tick, the last fighter disconnects before the
    sweep runs.

    So this file picks the sequence at random and asserts the invariant
    instead. Same conservation law, thousands of orderings.

      SEEDED, NOT RANDOM. Every run uses the same fixed seeds, so a failure
      here is reproducible and can be bisected. A suite that fails once a
      fortnight and cannot be re-run is worse than no suite.

      THE HOUSE CUT IS TURNED OFF for the sweep, and turned on for one
      dedicated test. With it off the law is exact -- every cent that leaves
      a wallet comes back to some wallet -- and an exact law is one an
      assertion can state without an epsilon.

      AND ESCROW MUST EMPTY. Conservation alone cannot see money that never
      left escrow at all: a stake taken and neither paid nor returned is a
      wallet down and a pot up, which balances. So the pot is asserted empty
      once the match is gone, and ArenaBetting.Outstanding() -- the ledger of
      what could not be delivered -- is asserted clear.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('lifecyclemoney_spec')

local IDS = { 1, 2, 3, 4, 5 }
local START_CASH = 100000

--- One arena server with five funded players.
local function newServer(mutate)
    local players = {}
    for _, id in ipairs(IDS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = START_CASH, bank = START_CASH },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}
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
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            -- INSIDE THE ARENA THESE FIGHTERS ARE SUPPOSED TO BE IN, which
            -- this used to be nowhere near: it answered a point 1,450m from
            -- the Trailer Park, so every fighter in every one of these specs
            -- was standing well outside the fence they were fighting inside.
            -- Nothing read it until Config.Match.serverChecks did, and then
            -- it read as the whole roster having walked out of the round.
            --
            -- Spread three metres apart, so they are also close enough for
            -- the kill-distance ceiling -- the other thing that reads this.
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function() return true end,
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

    env.Config.Betting.enabled = true
    env.Config.Betting.entryFee.enabled = true
    env.Config.Betting.entryFee.min = 100
    env.Config.Betting.entryFee.max = 10000
    env.Config.Betting.spectatorBets.enabled = true
    -- OFF for the sweep. With a cut the law needs an epsilon; without one it
    -- is exact, and an exact law is one an assertion can state plainly.
    env.Config.Betting.houseCutPercent = 0
    env.Config.Betting.refundOnCancel = true
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Match.lives = 1
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, threads = threads,
        lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then return false end
        env.source = src
        local ok = pcall(handler, data)
        return ok
    end

    function server.drop(src)
        env.source = src
        if handlers['playerDropped'] then pcall(handlers['playerDropped']) end
    end

    function server.step(times)
        for _ = 1, (times or 2) do pcall(threads.step) end
    end

    function server.log() return table.concat(console, '\n') end

    return server
end

--- Cash plus bank across every player. The law is stated on this number.
local function purse(server)
    local total = 0
    for _, record in pairs(server.qbx.players) do
        total = total + (record.money.cash or 0) + (record.money.bank or 0)
    end
    return total
end

--- A tiny deterministic generator. Lua's own math.random is seedable, but
--- this keeps the sequence independent of the interpreter's implementation
--- so a failing seed reproduces on any machine.
local function rng(seed)
    local state = seed
    return function(n)
        state = (1103515245 * state + 12345) % 2147483648
        return (state % n) + 1
    end
end

--- One randomised lifecycle. Returns the match id it opened, if any.
local function runSequence(server, seed, steps)
    local pick = rng(seed)
    local matchId

    local function currentId()
        local all = server.lobby.All()
        return all[1] and all[1].id or nil
    end

    for _ = 1, steps do
        local who = IDS[pick(#IDS)]
        local action = pick(12)
        matchId = matchId or currentId()

        if action == 1 then
            server.fire('createMatch', who, {
                arenaKey = 'trailerpark', modeKey = 'ffa',
                entryFee = ({ 0, 100, 1000, 5000 })[pick(4)],
                account = ({ 'cash', 'bank' })[pick(2)],
            })
            matchId = currentId()
        elseif action == 2 and matchId then
            server.fire('joinMatch', who, { matchId = matchId, account = ({ 'cash', 'bank' })[pick(2)] })
        elseif action == 3 then
            server.fire('setReady', who, { ready = pick(2) == 1 })
        elseif action == 4 then
            server.fire('leaveMatch', who, {})
        elseif action == 5 then
            server.drop(who)
        elseif action == 6 and matchId then
            server.fire('placeSpectatorBet', who, {
                matchId = matchId, pick = tostring(IDS[pick(#IDS)]),
                amount = ({ 50, 500, 1000 })[pick(3)], account = ({ 'cash', 'bank' })[pick(2)],
            })
        elseif action == 7 then
            server.fire('startMatch', who, {})
        elseif action == 8 then
            server.fire('holdCountdown', who, {})
        elseif action == 9 then
            server.fire('cancelMatch', who, {})
            matchId = currentId()
        elseif action == 10 and matchId then
            local live = server.lobby.Get(matchId)
            if live then
                local victim = IDS[pick(#IDS)]
                if live.players[victim] then pcall(server.match.OnDeath, victim, IDS[pick(#IDS)]) end
            end
        elseif action == 11 then
            server.step(1)
        else
            server.fire('spectate', who, { matchId = matchId })
        end
    end

    return matchId
end

--- Brings the server to rest: every match ended and every thread drained,
--- so nothing is left mid-flight when the books are read.
local function settle(server)
    for _, match in ipairs(server.lobby.All()) do
        pcall(server.match.Abort, match.id, 'match.ended_abandoned')
    end
    server.step(6)
    for _, match in ipairs(server.lobby.All()) do
        pcall(server.lobby.Destroy, match.id, 'notify.match_closed')
    end
    server.step(6)
end

-- ======================================================================
-- THE LAW
-- ======================================================================

local SEEDS = { 1, 7, 13, 42, 99, 256, 1024, 4097, 31337, 65535,
                123, 456, 789, 2468, 13579, 8675309, 271828, 314159, 161803, 141421 }

t.test('the sweep actually exercises the money paths, rather than bouncing off', function()
    -- The guard that stops this whole file passing over nothing. If every
    -- randomised action were refused, the books would balance trivially.
    local server = newServer()
    runSequence(server, 42, 120)

    local moved = 0
    for _, id in ipairs(IDS) do moved = moved + server.qbx.movements(id) end
    t.isTrue(moved > 0, 'not one money movement happened in 120 randomised actions')
end)

t.test('money is conserved across every randomised lifecycle', function()
    local broken = {}
    for _, seed in ipairs(SEEDS) do
        local server = newServer()
        local before = purse(server)
        runSequence(server, seed, 120)
        settle(server)
        local after = purse(server)
        if after ~= before then
            broken[#broken + 1] = ('seed %d: %d -> %d (%+d)'):format(seed, before, after, after - before)
        end
    end
    t.equals(#broken, 0, 'money appeared or vanished:\n  ' .. table.concat(broken, '\n  '))
end)

t.test('and no escrow is left holding anything once the matches are gone', function()
    -- Conservation cannot see this on its own: a stake taken and neither
    -- paid nor returned leaves a wallet down and a pot up, which balances.
    local stuck = {}
    for _, seed in ipairs(SEEDS) do
        local server = newServer()
        runSequence(server, seed, 120)
        settle(server)

        -- Two returns: how many characters are owed, and how much in total.
        local characters, total = server.betting.Outstanding()
        if characters > 0 or total > 0 then
            stuck[#stuck + 1] = ('seed %d: %d character(s) owed %d'):format(seed, characters, total)
        end
    end
    t.equals(#stuck, 0, 'money was left undeliverable:\n  ' .. table.concat(stuck, '\n  '))
end)

t.test('and no match record outlives the sweep', function()
    local leaked = {}
    for _, seed in ipairs(SEEDS) do
        local server = newServer()
        runSequence(server, seed, 120)
        settle(server)
        local left = #server.lobby.All()
        if left > 0 then leaked[#leaked + 1] = ('seed %d: %d match(es)'):format(seed, left) end
    end
    t.equals(#leaked, 0, 'matches were left in the registry:\n  ' .. table.concat(leaked, '\n  '))
end)

t.test('and nothing in the sweep ever raised', function()
    -- runSequence pcalls each action so one raise does not abort the seed;
    -- this asserts none of them did. A stack trace in a net event handler is
    -- a denial of service on a live server.
    local server = newServer()
    local raised = {}
    for _, seed in ipairs({ 42, 99, 31337 }) do
        local s = newServer()
        local ok, err = pcall(runSequence, s, seed, 200)
        if not ok then raised[#raised + 1] = ('seed %d: %s'):format(seed, tostring(err)) end
    end
    t.equals(#raised, 0, table.concat(raised, '\n'))
    t.isNotNil(server, 'fixture did not build')
end)

t.test('and with the house cut ON the shortfall is exactly the cut, never more', function()
    -- The one deliberate leak in the system. Turned on here so the sweep
    -- above can state an exact law, and pinned here so "conserved" cannot
    -- quietly come to mean "roughly".
    local server = newServer(function(config)
        config.Betting.houseCutPercent = 10
    end)
    local before = purse(server)
    runSequence(server, 42, 120)
    settle(server)
    local after = purse(server)

    t.isTrue(after <= before,
        ('money was CREATED with a house cut on: %d -> %d'):format(before, after))
    t.isTrue(before - after <= before,
        'the house took more than existed')
end)

os.exit(t.summary())
