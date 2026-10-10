--[[
    crimson_arena/tests/idleloops_spec.lua

    THE SERVER LOOPS THAT START ON DEMAND AND STOP WHEN IDLE, driven through
    the real files with a captured-thread runner:

      server/dispatch.lua   down-state hold: started by ArenaDispatch.Set,
                            ends on the first wake with nobody active.
      server/match.lua      main sweep: 1 s while a round counts down or is
                            live, sleeps to the next minute otherwise, and
                            Begin/Start wake it.
      server/lobby.lua      idle-lobby sweep: started by ArenaLobby.Create,
                            ends when no lobby/countdown is left.

    IDLELOOPS_SERVER_DIR (env var) swaps the directory dispatch/lobby/match
    are read from, so the same spec can be pointed at older copies.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local SERVER = os.getenv('IDLELOOPS_SERVER_DIR') or '../Crimson-Arena/server/'
if SERVER:sub(-1) ~= '/' then SERVER = SERVER .. '/' end
local function serverFile(name)
    if name == 'dispatch' or name == 'lobby' or name == 'match' then return SERVER .. name .. '.lua' end
    return '../Crimson-Arena/server/' .. name .. '.lua'
end

--- Captures every thread with where its function was defined and every Wait
--- it asked for, so a test can pick out one loop and read its cadence.
local function newRunner()
    local threads = {}
    local r = { created = 0 }
    function r.CreateThread(fn)
        r.created = r.created + 1
        local info = debug.getinfo(fn, 'S')
        threads[#threads + 1] = { co = coroutine.create(fn), src = info.source, line = info.linedefined, waits = {} }
    end
    function r.Wait(ms)
        local co = coroutine.running()
        for _, th in ipairs(threads) do
            if th.co == co then th.waits[#th.waits + 1] = ms end
        end
        coroutine.yield()
    end
    r.SetTimeout = function(_, fn) r.CreateThread(fn) end
    function r.step()
        for i = 1, #threads do
            local th = threads[i]
            if coroutine.status(th.co) ~= 'dead' then
                local ok, err = coroutine.resume(th.co)
                if not ok then error(err) end
            end
        end
    end
    --- Threads whose function is defined in `file` between lines `from`..`to`.
    function r.find(file, from, to)
        local out = {}
        for _, th in ipairs(threads) do
            if th.src:find(file, 1, true) and th.line >= (from or 0) and th.line <= (to or math.huge) then out[#out + 1] = th end
        end
        return out
    end
    function r.alive(list)
        local out = {}
        for _, th in ipairs(list) do
            if coroutine.status(th.co) ~= 'dead' then out[#out + 1] = th end
        end
        return out
    end
    return r
end

local function lineOf(path, needle)
    local n = 0
    for line in io.lines(path) do
        n = n + 1
        if line:find(needle, 1, true) then return n end
    end
    error('marker not found in ' .. path .. ': ' .. needle)
end

local function lastWait(th) return th.waits[#th.waits] end

-- ======================================================================
-- (1) server/dispatch.lua -- the down-state hold
-- ======================================================================

local HOLD_FROM = lineOf(serverFile('dispatch'), 'function ArenaDispatch.HoldDownState')
local HOLD_TO = lineOf(serverFile('dispatch'), 'CATCHING THE MOMENT ITSELF')

local function newDispatch(interval)
    local runner = newRunner()
    local meta = {}
    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = function() end,
        Player = function() return { state = { set = function() end } } end,
        TriggerEvent = function() end, AddEventHandler = function() end,
        RegisterNetEvent = function() end, RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return 0 end,
        GetResourceState = function() return 'missing' end,
        exports = setmetatable({}, { __call = function() end,
            __index = function() return setmetatable({}, { __index = function() return function() end end }) end }),
        ArenaLog = function() end, ArenaDebug = function() end,
        GetPlayerName = function() return 'x' end,
        ArenaGetPlayer = function(src)
            if not meta[src] then return nil end
            return { Functions = {
                SetMetaData = function(k, v) meta[src][k] = v end,
                GetMetaData = function(k) return meta[src][k] end,
            } }
        end,
    })
    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    env.Config.Dispatch.downState.holdIntervalMs = interval
    env.Config.Dispatch.downState.watchStateBag = nil
    Sandbox.loadInto(serverFile('dispatch'), env)
    local d = { D = env.ArenaDispatch, runner = runner, meta = meta }
    function d.holds() return runner.alive(runner.find('dispatch.lua', HOLD_FROM, HOLD_TO)) end
    return d
end

t.test('dispatch: no hold thread before the first Set', function()
    local d = newDispatch(250)
    for _ = 1, 5 do d.runner.step() end
    t.equals(#d.holds(), 0, 'a down-state hold is running with nobody in a match')
end)

t.test('dispatch: repeated Set starts exactly one hold, and it holds', function()
    local d = newDispatch(250)
    d.meta[7] = { inlaststand = false, isdead = false }
    d.meta[8] = { inlaststand = false, isdead = false }
    d.D.Set(7, 'm1')
    t.equals(#d.holds(), 1, 'Set did not start a hold')
    d.D.Set(8, 'm1')
    d.D.Set(7, 'm1')
    t.equals(#d.holds(), 1, 'a further Set started a second hold')
    d.runner.step() -- reaches its Wait
    d.meta[7].inlaststand = true
    d.runner.step()
    t.isFalse(d.meta[7].inlaststand, 'the hold did not hold the flag down')
    t.equals(lastWait(d.holds()[1]), 250)
end)

t.test('dispatch: the hold exits after the last Clear and the next Set restarts it', function()
    local d = newDispatch(250)
    d.meta[7] = { inlaststand = false }
    d.meta[8] = { inlaststand = false }
    d.D.Set(7, 'm1'); d.D.Set(8, 'm1')
    d.runner.step()
    d.D.Clear(7)
    d.runner.step()
    t.equals(#d.holds(), 1, 'the hold ended while somebody was still in')
    d.D.Clear(8)
    d.runner.step()
    t.equals(#d.holds(), 0, 'the hold outlived the last player')
    for _ = 1, 3 do d.runner.step() end
    t.equals(#d.holds(), 0)
    d.D.Set(7, 'm2')
    t.equals(#d.holds(), 1, 'the next Set did not restart the hold')
    d.runner.step()
    d.meta[7].inlaststand = true
    d.runner.step()
    t.isFalse(d.meta[7].inlaststand, 'the restarted hold did not sweep')
end)

t.test('dispatch: holdIntervalMs = 0 starts no thread at all', function()
    local d = newDispatch(0)
    local before = d.runner.created
    d.meta[7] = { inlaststand = true }
    d.D.Set(7, 'm1')
    t.equals(d.runner.created, before, 'an off hold still created a thread')
    t.equals(#d.holds(), 0)
end)

-- ======================================================================
-- (2)/(3) server/match.lua sweep and server/lobby.lua idle sweep
-- ======================================================================

local SWEEP_FROM = lineOf(serverFile('match'), 'local hoursWereOpen = nil')
-- Crimson: the watcher-position check below the sweep is its own thread.
local SWEEP_TO = lineOf(serverFile('match'), 'local SPECTATOR_CHECK_MS') - 1
local IDLE_FROM = lineOf(serverFile('lobby'), 'local SWEEP_INTERVAL_MS = 30000')

local function newServer()
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host', money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
        [3] = { citizenid = 'CCC33333', name = 'Other', money = { cash = 50000, bank = 0 } },
        [4] = { citizenid = 'DDD44444', name = 'Fourth', money = { cash = 50000, bank = 0 } },
        -- Crimson: a watcher must be a loaded character (ArenaLobby.EntryBlocked).
        [9] = { citizenid = 'III99999', name = 'Watcher', money = { cash = 0, bank = 0 } },
    })
    local runner = newRunner()
    local netEvents = {}
    local flags, buckets = {}, {}
    local env = Sandbox.newArenaEnv({
        exports = qbx.exports, lib = Sandbox.newOxLib(),
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        print = function() end,
        TriggerClientEvent = function() end, TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end, RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped) return { x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0, y = 2565.1, z = 46.7 } end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = { GetLeaderboard = function(cb) cb({}) end, EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end },
        ArenaAmmo = { IsEnabled = function() return false end, Refresh = function() return true end, Issue = function() return {} end,
            Reclaim = function() return 0 end, ReclaimAll = function() return 0 end, Clear = function() return true end, OnLoan = function() return 0 end },
        ArenaDispatch = {
            Set = function(src, matchId) flags[src] = matchId end,
            Clear = function(src) flags[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return flags[src] ~= nil end,
            GetPlayerMatchId = function(src) return flags[src] end,
            ClearDownState = function() return 0 end,
            EnterBucket = function(src, matchId) buckets[src] = matchId end,
            ExitBucket = function(src) buckets[src] = nil end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })
    env.Config.Match.lobbyCountdownSeconds = 3
    env.Config.Match.startCountdownSeconds = 2
    env.Config.Match.minPlayers = 2
    env.Config.Match.idleLobbyTimeoutSeconds = 900
    env.Config.Match.autoStartWhenAllReady = false
    env.Config.Betting.enabled = false
    env.Config.Betting.entryFee.enabled = false
    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto(serverFile(file), env)
    end
    local s = { env = env, runner = runner, lobby = env.ArenaLobby, match = env.ArenaMatch, buckets = buckets }
    function s.fire(event, src, data) env.source = src; netEvents['crimson_arena:server:' .. event](data) end
    function s.create(src) s.fire('createMatch', src, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 }); return s.lobby.GetByPlayer(src) end
    function s.sweeps() return runner.alive(runner.find('match.lua', SWEEP_FROM, SWEEP_TO)) end
    function s.idleSweeps() return runner.alive(runner.find('lobby.lua', IDLE_FROM)) end
    --- The one live sweep loop; fails the test if there is not exactly one.
    function s.sweep()
        local list = s.sweeps()
        t.equals(#list, 1, 'expected exactly one match sweep loop, found ' .. #list)
        return list[1]
    end
    return s
end

t.test('match sweep: idles past 1 s with no round in play', function()
    local s = newServer()
    s.runner.step() -- first Wait (1 s)
    t.equals(lastWait(s.sweep()), 1000)
    s.runner.step() -- first pass: nothing in play
    t.isTrue(lastWait(s.sweep()) > 1000, 'empty server still sweeps every second')
    t.isTrue(lastWait(s.sweep()) <= 60000)
    s.create(1)
    s.runner.step()
    t.isTrue(lastWait(s.sweep()) > 1000, 'a waiting lobby alone keeps the 1 s sweep')
end)

t.test('match sweep: Begin brings back the 1 s cadence with a single loop', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    local m = s.create(1)
    s.fire('joinMatch', 2, { matchId = m.id })
    s.fire('joinMatch', 3, { matchId = m.id })
    local ok, why = s.match.Begin(m.id)
    t.isTrue(ok, tostring(why))
    s.runner.step()
    t.equals(lastWait(s.sweep()), 1000, 'countdown is not on the 1 s cadence')
    for _ = 1, 12 do s.runner.step() end
    t.equals(m.state, 'live', 'never went live')
    t.equals(lastWait(s.sweep()), 1000, 'live round is not on the 1 s cadence')
end)

t.test('match sweep: Start from a lobby wakes it too', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    local m = s.create(1)
    s.fire('joinMatch', 2, { matchId = m.id })
    s.runner.step()
    t.isTrue(lastWait(s.sweep()) > 1000)
    local ok, why = s.match.Start(m.id)
    t.isTrue(ok, tostring(why))
    s.runner.step()
    t.equals(lastWait(s.sweep()), 1000, 'Start did not wake the sweep')
end)

t.test('match sweep: a bucketed spectator is handed back before it sleeps', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    local m = s.create(1)
    s.fire('joinMatch', 2, { matchId = m.id })
    s.fire('joinMatch', 3, { matchId = m.id })
    t.isTrue(s.match.Begin(m.id))
    for _ = 1, 12 do s.runner.step() end
    t.equals(m.state, 'live')
    s.lobby.AddSpectator(9, m.id)
    s.runner.step()
    t.equals(s.buckets[9], m.id, 'spectator was never bucketed by the sweep')
    t.isNotNil(s.buckets[1], 'fighter was never bucketed')
    s.match.Abort(m.id, 'match.aborted')
    local slept = false
    for _ = 1, 6 do
        s.runner.step()
        if lastWait(s.sweep()) > 1000 then slept = true break end
    end
    t.isTrue(slept, 'the sweep never went back to sleep')
    t.isNil(s.buckets[9], 'spectator still bucketed when the sweep went to sleep')
    t.isNil(s.buckets[1], 'fighter still bucketed when the sweep went to sleep')
end)

t.test('match sweep: a round that just stops being in play is unbucketed by the sweep itself', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    local m = s.create(1)
    s.fire('joinMatch', 2, { matchId = m.id })
    t.isTrue(s.match.Begin(m.id))
    for _ = 1, 12 do s.runner.step() end
    t.equals(m.state, 'live')
    s.lobby.AddSpectator(9, m.id)
    s.runner.step()
    t.equals(s.buckets[9], m.id, 'spectator was never bucketed by the sweep')
    -- no End/Abort cleanup: only the sweep's own pass can hand the bucket back
    m.state = 'ended'
    local slept = false
    for _ = 1, 4 do
        s.runner.step()
        if lastWait(s.sweep()) > 1000 then slept = true break end
    end
    t.isTrue(slept, 'the sweep never went back to sleep')
    t.isNil(s.buckets[9], 'spectator still bucketed when the sweep went to sleep')
end)

t.test('match sweep: an opening-hours close while idle still closes waiting lobbies', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    local m = s.create(1)
    s.runner.step()
    t.isTrue(lastWait(s.sweep()) > 1000, 'precondition: sweep idling')
    -- the schedule (not an admin override) says shut from here on
    s.env.ArenaHoursOpen = function() return false end
    s.runner.step()
    t.isNil(s.lobby.Get(m.id), 'idle sweep missed the hours edge')
end)

t.test('lobby idle sweep: none at load; Create starts exactly one for two lobbies', function()
    local s = newServer()
    s.runner.step(); s.runner.step()
    t.equals(#s.idleSweeps(), 0, 'idle-lobby sweep running with no lobby')
    s.create(1)
    t.equals(#s.idleSweeps(), 1, 'Create did not start the idle sweep')
    s.create(2)
    t.equals(#s.idleSweeps(), 1, 'a second lobby started a second sweep')
    s.runner.step()
    t.equals(lastWait(s.idleSweeps()[1]), 30000)
end)

t.test('lobby idle sweep: exits with nothing left, restarts on the next Create', function()
    local s = newServer()
    local m = s.create(1)
    m.createdAt = os.time() - 1000; m.idleSince = m.createdAt
    s.runner.step(); s.runner.step()
    t.isNil(s.lobby.Get(m.id), 'idle lobby was not swept')
    t.equals(#s.idleSweeps(), 0, 'sweep outlived the last lobby')
    s.create(1)
    t.equals(#s.idleSweeps(), 1, 'next Create did not restart the sweep')
end)

t.test('lobby idle sweep: a countdown keeps it alive, held back it is still swept', function()
    local s = newServer()
    local m = s.create(1)
    s.fire('joinMatch', 2, { matchId = m.id })
    t.isTrue(s.match.Begin(m.id))
    s.runner.step(); s.runner.step()
    t.equals(m.state, 'countdown')
    t.equals(#s.idleSweeps(), 1, 'idle sweep exited during countdown')
    t.isTrue(s.lobby.HoldCountdown(1))
    m.createdAt = os.time() - 1000; m.idleSince = m.createdAt
    s.runner.step()
    t.isNil(s.lobby.Get(m.id), 'held lobby never swept')
end)

os.exit(t.summary())
