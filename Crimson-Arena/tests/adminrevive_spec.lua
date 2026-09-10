--[[
    crimson_arena/tests/adminrevive_spec.lua

    THE ADMIN REVIVE THAT CANCELLED A RESPAWN.

    A death in a live round with lives left schedules a respawn, and the
    thread that sends it bails the moment it sees the row alive. The tablet
    marks that fighter Down for the five-second wait and offers Revive on
    them -- and Revive flipped the row alive. No respawn was ever sent. The
    fighter lay held on the floor, invincible at full health, counted as
    standing by every winner path, and once the real fighters had knocked
    each other out the held body was the last one standing: crowned and paid.

    Real server files, three fighters and an admin, shipped numbers.
]]
local t = dofile('testkit.lua')
print('adminrevive_spec')
local Sandbox = dofile('fixtures/sandbox.lua')

local PLACE = { x = 2344.4, y = 2565.1, z = 46.7 }

local function newServer()
    local players = {}
    for src = 1, 4 do
        players[src] = { citizenid = ('CID%03d'):format(src), name = ('Fighter %d'):format(src),
            money = { cash = 50000, bank = 50000 }, job = { name = 'unemployed', grade = { level = 0 } } }
    end
    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, sent, bucketOf = {}, {}, {}
    local clock = 0
    local logs = {}
    local ammoStub = setmetatable({
        IsEnabled = function() return false end, Issue = function() return {} end,
        Reclaim = function() return 0 end, Refresh = function() return true end,
        ReclaimAll = function() return 0 end, Clear = function() return true end,
        OnLoan = function() return 0 end, LoadOwedKit = function() end,
    }, { __index = function() return function() return nil end end })
    local env = Sandbox.newArenaEnv({
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        print = function(...) logs[#logs + 1] = table.concat({ ... }, ' ') end,
        TriggerClientEvent = function(event, src, payload)
            sent[src] = sent[src] or {}
            sent[src][#sent[src] + 1] = { event = event, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) netEvents['@' .. name] = fn end, RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function() return { x = PLACE.x, y = PLACE.y, z = PLACE.z } end,
        GetEntityHealth = function() return 200 end,   -- the hold sets health to max: the dead sweep sees a healthy ped
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function(src) return src == 4 end,   -- 4 is the admin, in no match
        PerformHttpRequest = function() end,
        ArenaStats = setmetatable({ GetLeaderboard = function(cb) cb({}) end },
            { __index = function() return function() end end }),
        ArenaAmmo = ammoStub,
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return bucketOf[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) bucketOf[src] = bucket end,
        SetRoutingBucketEntityLockdownMode = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
    })
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.maxConcurrentMatches = 0
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end
    local server = { lobby = env.ArenaLobby, match = env.ArenaMatch, sent = sent, logs = logs, env = env }
    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        env.source = src
        return handler(data)
    end
    function server.step(n) for _ = 1, (n or 1) do threads.step() end end
    function server.run(arenaKey, ids)
        server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })
        local match
        for _, entry in ipairs(server.lobby.All()) do if entry.hostSource == ids[1] then match = entry end end
        for i = 2, #ids do server.fire('joinMatch', ids[i], { matchId = match.id }) end
        server.fire('startMatch', ids[1])
        server.step(6)
        return match.id
    end
    function server.eventsTo(src, name)
        local out = {}
        for _, e in ipairs(sent[src] or {}) do if e.event == name then out[#out + 1] = e end end
        return out
    end
    return server
end


local RESPAWN = 'crimson_arena:client:respawn'

t.test('CONTROL: a plain death in a live round respawns on its own', function()
    local s = newServer()
    local id = s.run('trailerpark', { 1, 2, 3 })
    s.fire('reportDeath', 2, { killerServerId = 1 })
    s.step(10)
    t.equals(#s.eventsTo(2, RESPAWN), 1, 'no respawn without any Revive, so this fixture proves nothing')
end)

t.test('DEFECT: a Revive pressed inside the respawn wait cancelled the respawn', function()
    local s = newServer()
    local id = s.run('trailerpark', { 1, 2, 3 })
    s.fire('reportDeath', 2, { killerServerId = 1 })
    t.isFalse(s.lobby.Get(id).players[2].alive, 'fighter 2 is not down, so this proves nothing')

    local ok, err = pcall(s.fire, 'adminRevive', 4, { target = 2 })
    t.isTrue(ok, 'adminRevive raised: ' .. tostring(err))

    s.step(10)
    t.equals(#s.eventsTo(2, RESPAWN), 1,
        'the Revive click marked the fighter alive and the round never stood them up')
    t.isTrue(s.lobby.Get(id).players[2].alive, 'the fighter never came back at all')
end)

t.test('and the medical revive still happens for them', function()
    -- The half of the button that is never wrong: picking somebody up off
    -- the floor. The fix must not have taken that away.
    local s = newServer()
    local id = s.run('trailerpark', { 1, 2, 3 })
    s.fire('reportDeath', 2, { killerServerId = 1 })
    local before = #s.eventsTo(2, 'crimson_arena:client:holdVitals')
    assert(pcall(s.fire, 'adminRevive', 4, { target = 2 }))
    t.isTrue(#s.eventsTo(2, 'crimson_arena:client:holdVitals') > before,
        'the medical revive no longer reaches the fighter')
end)

t.test('DEFECT: a held body could win a round it had never been stood up in', function()
    local s = newServer()
    local id = s.run('trailerpark', { 1, 2, 3 })
    s.fire('reportDeath', 2, { killerServerId = 1 })
    assert(pcall(s.fire, 'adminRevive', 4, { target = 2 }))
    s.step(10)
    for _ = 1, 3 do s.fire('reportDeath', 3, { killerServerId = 1 }); s.step(10) end
    for _ = 1, 3 do s.fire('reportDeath', 1, {}); s.step(10) end

    local m = s.lobby.Get(id)
    t.isTrue(m == nil or m.state == 'ended', 'the round did not end')
    local results = s.eventsTo(2, 'crimson_arena:client:results')
    t.isTrue(#results > 0 and results[1].payload.won == true,
        'fighter 2 is the last one standing and should have won')
    t.isTrue(#s.eventsTo(2, RESPAWN) >= 1,
        'fighter 2 won without ever being stood up -- a held body was crowned')
end)

os.exit(t.summary())
