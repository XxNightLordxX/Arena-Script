--[[
    crimson_arena/tests/fencegoesup_spec.lua

    THE FENCE THAT NEVER WENT UP.

    A fighter who walks out of a live round is taken off the roster before
    the broadcast, and a round that ends is torn down before its own -- so
    the leaver was never sent another word of state. His client kept the last
    thing it was told: no fence for his own arena, because he was in it. He
    could walk straight back into a round still being fought there. The
    mirror of the fence that never came down, closed the same way: one push,
    to him alone, at the exit.

    Real server files, shipped keepOutBarrier / isolation / concurrency.
]]
-- Verifier harness for finding 1: does a fighter who leaves a live round, or
-- whose round ends while another round is live at the same arena, ever get a
-- state push carrying the fence? Built on the REAL server files exactly as
-- tests/handback_spec.lua's newServer() does.
local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local PLACES = {
    trailerpark = { x = 2344.4, y = 2565.1, z = 46.7 },
    skydome = { x = 1500.0, y = 3000.0, z = 1201.0 },
}

local function newServer(mutate)
    local players = {}
    for src = 1, 6 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 50000, bank = 50000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, sent, bucketOf, at, logs = {}, {}, {}, {}, {}
    local clock = 0
    local env = Sandbox.newArenaEnv({
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            logs[#logs + 1] = table.concat(parts, ' ')
        end,
        TriggerClientEvent = function(event, src, payload)
            sent[src] = sent[src] or {}
            sent[src][#sent[src] + 1] = { event = event, payload = payload }
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
            local point = at[tonumber(ped) or -1] or PLACES.trailerpark
            return { x = point.x, y = point.y, z = point.z }
        end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
            Record = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end, ReclaimAll = function() return 0 end,
            Clear = function() return true end, OnLoan = function() return 0 end,
        },
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return bucketOf[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) bucketOf[src] = bucket end,
        SetRoutingBucketEntityLockdownMode = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    -- maxConcurrentMatches and keepOutBarrier are left EXACTLY as shipped.
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { lobby = env.ArenaLobby, match = env.ArenaMatch, env = env, sent = sent, logs = logs, at = at }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        env.source = src
        handler(data)
    end
    function server.step(times) for _ = 1, (times or 1) do threads.step() end end
    function server.count(src) return #(sent[src] or {}) end
    function server.eventsSince(src, index)
        local names = {}
        for i = index + 1, #(sent[src] or {}) do names[#names + 1] = sent[src][i].event:gsub('crimson_arena:client:', '') end
        return table.concat(names, ', ')
    end
    function server.fenceOn(src)
        local list = sent[src] or {}
        for i = #list, 1, -1 do
            if list[i].event == 'crimson_arena:client:state' then
                local zones = list[i].payload.keepOut or {}
                local labels = {}
                for _, zone in ipairs(zones) do labels[#labels + 1] = tostring(zone.label) end
                table.sort(labels)
                return table.concat(labels, ' + ')
            end
        end
        return nil
    end
    function server.run(arenaKey, ids)
        server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })
        local match
        for _, entry in ipairs(server.lobby.All()) do
            if entry.hostSource == ids[1] then match = entry end
        end
        for i = 2, #ids do server.fire('joinMatch', ids[i], { matchId = match.id }) end
        for _, src in ipairs(ids) do at[src] = PLACES[arenaKey] end
        server.fire('startMatch', ids[1])
        server.step(6)
        return match.id
    end
    return server
end


print('fencegoesup_spec')

t.test('DEFECT: a fighter who leaves a live round was never sent the fence for it', function()
    local server = newServer()
    local id = server.run('trailerpark', { 1, 2, 3 })
    t.equals(server.lobby.Get(id).state, 'live', 'round did not go live')
    t.equals(server.fenceOn(1), '', 'fighter had a fence while placed in his own round, so this proves nothing')

    server.fire('leaveMatch', 1, {})
    server.step(3)

    t.equals(server.lobby.Get(id).state, 'live', 'the round did not continue, so this proves nothing')
    t.isFalse(server.env.ArenaDispatch.IsPlayerInArena(1), 'leaver still dispatched')
    t.equals(server.fenceOn(1), 'Trailer Park',
        'the leaver holds no fence for the round he just walked out of')
end)

t.test('DEFECT: two rounds on one arena -- when one ends, its fighters were never fenced out of the other', function()
    local server = newServer()
    local m1 = server.run('trailerpark', { 1, 2 })
    local m2 = server.run('trailerpark', { 3, 4 })
    t.equals(server.lobby.Get(m2).state, 'live', 'second round refused the arena, so this case is unreachable here')

    server.match.End(m1, 'match.ended', { 2 })
    server.step(3)

    t.isNil(server.lobby.Get(m1), 'ended round still exists')
    t.equals(server.lobby.Get(m2).state, 'live', 'the other round is no longer live')
    t.equals(server.fenceOn(1), 'Trailer Park', 'fighter 1 walked out unfenced from an arena still being fought on')
    t.equals(server.fenceOn(2), 'Trailer Park', 'fighter 2 walked out unfenced from an arena still being fought on')
end)

t.test('and the same when the first round is abandoned', function()
    local server = newServer()
    local m1 = server.run('trailerpark', { 1, 2 })
    local m2 = server.run('trailerpark', { 3, 4 })
    server.fire('leaveMatch', 1, {})
    server.fire('leaveMatch', 2, {})
    server.step(3)

    t.isNil(server.lobby.Get(m1), 'abandoned round still exists')
    t.equals(server.lobby.Get(m2).state, 'live')
    t.equals(server.fenceOn(1), 'Trailer Park')
    t.equals(server.fenceOn(2), 'Trailer Park')
end)

t.test('CONTROL: the fence still comes down when the other round ends (fenceHeld)', function()
    local server = newServer()
    server.run('skydome', { 1, 2 })
    local theirs = server.run('trailerpark', { 3, 4 })
    server.fire('leaveMatch', 1, {})
    server.step(3)
    t.equals(server.fenceOn(1), 'Trailer Park', 'the other arena was not fenced, so this proves nothing')
    server.match.End(theirs, 'match.ended', { 4 })
    server.step(3)
    t.equals(server.fenceOn(1), '', 'a fence outlived the round that put it up')
end)

t.test('CONTROL: a fighter still in his own round is not fenced out of it', function()
    local server = newServer()
    local id = server.run('trailerpark', { 1, 2, 3 })
    server.fire('leaveMatch', 3, {})
    server.step(3)
    t.equals(server.lobby.Get(id).state, 'live')
    t.equals(server.fenceOn(1), '', 'a fighter still in the round was fenced out of his own arena')
end)

os.exit(t.summary())
