--[[
    crimson_arena/tests/sweeponce_spec.lua

    ONE WALK OF THE OBJECT POOL PER BUILD, WHERE ONE IS ENOUGH.

    Every build opens with a teardown, and the teardown sweeps the object
    pool for strays of the arena this client last built, at the size it last
    built it. The build then used to sweep the pool AGAIN, for the arena it
    is about to lay -- in the same frame, with nothing yielding in between.
    On a repeat round at the same arena and the same size those are the same
    question asked twice: Arena.PropSweep is a pure function of the arena,
    the size and the config, so the second walk searched a pool the first
    had just cleaned. It could only ever find what the first had failed to
    delete, and it would fail to delete that again.

    So the build's own sweep is skipped when, and only when, the teardown
    just swept the same arena AT THE SAME SIZE. Everything else still sweeps
    exactly as before:

      - a FRESH client, which has no record of building anything, so its
        teardown sweeps nothing -- the case the build's sweep exists for;
      - a DIFFERENT arena, whose teardown swept somewhere else;
      - a DIFFERENT SIZE. This is the half that is easy to lose: grow the
        arena and the build's reach is wider than the teardown's, and the
        ring between them is covered by nobody else. propsweep_spec pins
        that ring with a stray in it; this file counts the walks.

    The cost pins below fail on the version that walked twice. The
    differential at the foot runs the real client beside one built from the
    same file with the old unconditional sweep put back, through a few
    hundred seeded rounds, exits, camera builds and strays, and requires
    them to agree on every object, every console line and where the player
    ends up. The only difference allowed is fewer walks.

    THAT REFERENCE IS CUT FROM THE SAME FILE, so a change anywhere else in it
    lands on both sides and the differential cannot see it. What the skip
    leans on outside the line it guards -- the teardown sweeping at all, at
    the size it built, and only after its own pieces are down -- is pinned
    by tests of its own below, each against the real file alone.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('sweeponce_spec')

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }
local OURS = 'stt_prop_stunt_bblock_huge_01'
local FOREIGN = 'prop_bench_01a'
local MATCH_FILE = '../Crimson-Arena/client/match.lua'

local function read(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

--- THE OLD OPENING OF THE BUILD, rebuilt from the real file.
---
--- The only thing this change touches is whether the build's own sweep
--- runs, so the reference is the production file with that one call made
--- unconditional again -- everything else about it is the file as shipped.
--- Exactly one of two shapes must be found, or this raises: the guarded
--- call (the change is in), or the unguarded call straight after the
--- opening teardown (it is not). Anything else means the opening has been
--- rewritten, and a reference silently equal to the real thing would let
--- this differential pass while comparing a file with itself.
local SOURCE = read(MATCH_FILE)
local GUARDED = 'if not sweptAlready then sweepStrayArenaProps(arenaKey, factor) end'
local REFERENCE_SOURCE, SHAPE
do
    local start, finish = SOURCE:find(GUARDED, 1, true)
    if start then
        assert(SOURCE:find(GUARDED, finish + 1, true) == nil, 'the guarded sweep appears twice')
        REFERENCE_SOURCE = SOURCE:sub(1, start - 1) .. 'sweepStrayArenaProps(arenaKey, factor)'
            .. SOURCE:sub(finish + 1)
        SHAPE = 'guarded'
    elseif SOURCE:find('clearArenaScenery%(true%)\n\n    sweepStrayArenaProps%(arenaKey, factor%)\n') then
        REFERENCE_SOURCE = SOURCE
        SHAPE = 'unguarded'
    else
        -- Failed by the first test and the differential below, not raised
        -- here: every other test in this file still has something to say.
        SHAPE = 'unknown'
    end
end

--- @param opts table|nil -- { reference, models, arena, factor }
local function newClient(opts)
    opts = opts or {}
    local world = World.new({ streamRange = 100000.0, models = opts.models })
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { world = world, printed = {}, toServer = {}, walks = 0, calls = {}, sticky = {}, watching = true }

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            c.toServer[#c.toServer + 1] = { name = name, payload = payload }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        NetworkResurrectLocalPlayer = function() end,
        ClearPedBloodDamage = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        SetPedArmour = function() end,
        SetEntityHealth = function() end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end,
        RemoveWeaponFromPed = function() end,
        DisableControlAction = function() end,
        DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 900 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 5 end,
        GetPlayerServerId = function() return 7 end,
        PlayerId = function() return 0 end,
        GetPlayerFromServerId = function(serverId) return serverId end,
        NetworkIsPlayerActive = function() return true end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        AddBlipForEntity = function(ped) return 6000 + (ped or 0) end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        EndTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        SetBlipDisplay = function() end,
        DoesBlipExist = function() return true end,
        RemoveBlip = function() end,
        SetEntityDrawOutline = function() end,
        SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function() end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,
        SetLocalPlayerVisibleLocally = function() end,
        TaskStartScenarioInPlace = function() end,
        SetBlockingOfNonTemporaryEvents = function() end,
        SetPedCanRagdoll = function() end,
        print = function(line) c.printed[#c.printed + 1] = tostring(line) end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
        ArenaSpectate = {
            IsActive = function() return c.watching == true end,
            Stop = function() c.watching = false end,
            Start = function() c.watching = true end,
        },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end
    overrides.GetGameTimer = function() return runner.elapsed end

    local function tally(name) c.calls[name] = (c.calls[name] or 0) + 1 end

    -- EVERY WALK OF THE POOL, COUNTED. The sweep is the only thing in this
    -- resource that lists the pool, so a walk is a sweep that got as far as
    -- looking.
    overrides.GetGamePool = function(kind)
        if kind == 'CObject' then c.walks = c.walks + 1 end
        return world.natives.GetGamePool(kind)
    end
    overrides.GetEntityModel = function(handle)
        tally('GetEntityModel')
        return world.natives.GetEntityModel(handle)
    end
    overrides.DoesEntityExist = function(handle)
        tally('DoesEntityExist')
        return world.natives.DoesEntityExist(handle)
    end
    -- A PIECE SOMEBODY ELSE OWNS survives a delete. Both builds try it and
    -- both fail, which is the argument for skipping the second attempt.
    overrides.DeleteObject = function(handle)
        tally('DeleteObject')
        if c.sticky[handle] then
            c.calls['DeleteObject:sticky'] = (c.calls['DeleteObject:sticky'] or 0) + 1
            return
        end
        return world.natives.DeleteObject(handle)
    end

    local env = Sandbox.newArenaEnv(overrides)
    local chunk = assert(load(opts.reference and REFERENCE_SOURCE or SOURCE, '@' .. MATCH_FILE, 't', env))
    chunk()
    c.env = env

    local function run(thread)
        for _ = 1, 400 do
            if coroutine.status(thread) == 'dead' then break end
            local ok, err = coroutine.resume(thread)
            if not ok then error(err) end
        end
        assert(coroutine.status(thread) == 'dead', 'a handler never finished')
    end

    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('no handler for ' .. name) end
        local args = table.pack(...)
        run(coroutine.create(function() handler(table.unpack(args, 1, args.n)) end))
    end

    function c.enter(key, sizeFactor)
        local arena = env.Config.Arenas[key]
        local spawn = env.Arena.PickSpawn(key, nil, 1)
        c.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1', arenaKey = key, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false, loadout = { weapons = {} },
            sizeFactor = sizeFactor,
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius * math.max(1.0, sizeFactor or 1.0),
                warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        })
    end

    function c.exit() c.fire('crimson_arena:client:exitArena', {}) end

    --- The spectator camera asking for scenery, from inside a thread the
    --- way client/spectate.lua's loop does. The camera is switched on first
    --- -- an exit stops it -- unless `off` says the watcher has gone.
    function c.watch(key, factor, off)
        c.watching = not off
        local result
        run(coroutine.create(function() result = env.ArenaMatch.EnsureSpectatorScenery(key, factor) end))
        return result
    end

    function c.unwatch()
        run(coroutine.create(function() env.ArenaMatch.DropSpectatorScenery() end))
    end

    --- A prop nothing in this client is tracking.
    function c.plant(model, x, y, z, sticky)
        local handle = world.natives.CreateObject(model, x, y, z, false, false, false)
        assert(handle ~= 0, 'the fixture refused to plant the stray prop')
        if sticky then c.sticky[handle] = true end
        return handle
    end

    --- Pool walks made by one call.
    function c.walksDuring(fn)
        local before = c.walks
        fn()
        return c.walks - before
    end

    function c.alive(handle)
        local object = world.objects[handle]
        return object ~= nil and not object.deleted
    end

    function c.sweptLines()
        local out = {}
        for _, sent in ipairs(c.toServer) do
            if sent.name == 'crimson_arena:server:clientDebug' and type(sent.payload) == 'table'
                and type(sent.payload.line) == 'string' and sent.payload.line:find('swept', 1, true) then
                out[#out + 1] = sent.payload.line
            end
        end
        return out
    end

    return c
end

--- The world as one string: every standing object, in creation order.
local function snapshot(c)
    local out = {}
    for _, object in ipairs(c.world.live()) do
        out[#out + 1] = ('%d %s %.3f %.3f %.3f %.1f %s'):format(object.handle, object.model,
            object.x, object.y, object.z, object.heading or 0.0, tostring(object.collision))
    end
    return table.concat(out, '\n')
end

--- Everything the client has said, in both sinks, as one string.
local function said(c)
    local out = {}
    for _, line in ipairs(c.printed) do out[#out + 1] = 'F8 ' .. line end
    for _, sent in ipairs(c.toServer) do
        local payload = sent.payload
        local text = sent.name
        if type(payload) == 'table' then
            if type(payload.lines) == 'table' then text = text .. ' ' .. table.concat(payload.lines, ' | ') end
            if payload.line ~= nil then text = text .. ' ' .. tostring(payload.line) end
        end
        out[#out + 1] = 'SV ' .. text
    end
    return table.concat(out, '\n')
end

t.test('the reference really is the old opening, and the file really has one of the two shapes', function()
    t.isTrue(SHAPE == 'guarded' or SHAPE == 'unguarded',
        'the build no longer opens in either shape the reference knows -- rebuild the reference')
    if SHAPE == 'guarded' then
        t.isTrue(REFERENCE_SOURCE ~= SOURCE, 'the reference was not rebuilt')
        t.isTrue(REFERENCE_SOURCE:find('clearArenaScenery(true)\n\n    sweepStrayArenaProps(arenaKey, factor)\n', 1, true)
            ~= nil, 'the reference does not sweep straight after its opening teardown')
    end
end)

-- ======================================================================
-- THE COST THIS CHANGE IS FOR
-- ======================================================================

t.test('THE COST: a repeat round at the same arena and size walks the pool once, not twice', function()
    local c = newClient()
    for i = 1, 400 do c.plant(FOREIGN, SKY.x + (i % 40), SKY.y + (i % 23), SKY.z + 30.0) end
    c.enter('skydome', 1.0)
    c.exit()

    local models = c.calls['GetEntityModel'] or 0
    local walks = c.walksDuring(function() c.enter('skydome', 1.0) end)
    t.equals(walks, 1, ('the second round at the same arena and size walked the pool %d time(s)'):format(walks))
    -- One model read per pooled object, for the one walk.
    t.equals((c.calls['GetEntityModel'] or 0) - models, 400,
        'the repeat entry read the pool\'s models more than once')
end)

t.test('and the same with no size sent at all, which is the same size twice', function()
    local c = newClient()
    c.enter('skydome')
    c.exit()
    t.equals(c.walksDuring(function() c.enter('skydome') end), 1)
end)

t.test('and a round re-entered without an exit in between', function()
    local c = newClient()
    c.enter('skydome', 1.5)
    t.equals(c.walksDuring(function() c.enter('skydome', 1.5) end), 1)
end)

t.test('and a camera rebuilding the arena its client just left', function()
    local c = newClient()
    c.enter('skydome', 1.0)
    c.exit()
    t.equals(c.walksDuring(function() t.isTrue(c.watch('skydome', 1.0)) end), 1)
end)

t.test('and a camera whose build fails walks the pool twice a frame, not three times', function()
    -- NO FLOOR MODEL AT ALL, so every camera build fails and its caller's
    -- failure path tears down again -- and the per-frame loop asks again the
    -- next frame. Three walks a frame became two.
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    local c = newClient({ models = models })
    for _, name in ipairs(c.env.Arena.GetPlatform('skydome').models) do models[name] = nil end

    t.isTrue(c.watch('skydome', 1.0) == false, 'the camera build did not fail, so this tests nothing')
    for _ = 1, 3 do
        t.equals(c.walksDuring(function() c.watch('skydome', 1.0) end), 2)
    end
end)

-- ======================================================================
-- WHERE THE BUILD MUST STILL SWEEP FOR ITSELF
-- ======================================================================

t.test('a fresh client sweeps before its first build, and the stray goes', function()
    -- The case the build's sweep exists for: no record of ever having
    -- built here, so the teardown has nothing to sweep FROM.
    local c = newClient()
    local stray = c.plant(OURS, SKY.x, SKY.y, SKY.z - 10.0)
    t.equals(c.walksDuring(function() c.enter('skydome', 1.0) end), 1)
    t.isTrue(not c.alive(stray), 'a fresh client built straight through a stray')
end)

t.test('a grown arena sweeps its own wider reach, and the ring between is cleared', function()
    local c = newClient()
    local small, big = c.env.Arena.PropSweep('skydome', 1.0), c.env.Arena.PropSweep('skydome', 2.0)
    c.enter('skydome', 1.0)
    c.exit()
    local stray = c.plant('prop_container_01a', SKY.x, SKY.y + (small.radius + big.radius) * 0.5, SKY.z + 5.0)
    t.equals(c.walksDuring(function() c.enter('skydome', 2.0) end), 2,
        'growing the arena did not walk the pool for the wider reach')
    t.isTrue(not c.alive(stray), 'the ring the arena grew into kept its stray')
end)

t.test('a shrunk arena still sweeps too, and the old wider reach is cleared by the teardown', function()
    local c = newClient()
    local small, big = c.env.Arena.PropSweep('skydome', 1.0), c.env.Arena.PropSweep('skydome', 2.0)
    c.enter('skydome', 2.0)
    c.exit()
    local stray = c.plant('prop_container_01b', SKY.x - (small.radius + big.radius) * 0.5, SKY.y, SKY.z)
    t.equals(c.walksDuring(function() c.enter('skydome', 1.0) end), 2)
    t.isTrue(not c.alive(stray), 'a stray in the reach the arena had last round survived it shrinking')
end)

t.test('the smallest step in size is still a different size', function()
    local c = newClient()
    c.enter('skydome', 1.0)
    c.exit()
    t.equals(c.walksDuring(function() c.enter('skydome', 1.0 + 1e-9) end), 2,
        'a size a hair different was treated as the same one')
end)

t.test('no size and size one are not assumed to be the same size', function()
    -- The server sends a number; an entry built without one sends nil. They
    -- lay the same arena, but the skip compares what it was given rather
    -- than guessing, so the cautious answer is a second walk.
    local c = newClient()
    c.enter('skydome')
    c.exit()
    t.equals(c.walksDuring(function() t.isTrue(c.watch('skydome', 1.0)) end), 2)
end)

t.test('a different arena gets its own sweep', function()
    -- The teardown swept the trailer park -- which has no sweep at all --
    -- so nothing has looked at the sky arena this frame.
    local c = newClient()
    c.enter('trailerpark')
    c.exit()
    local stray = c.plant(OURS, SKY.x + 10.0, SKY.y, SKY.z)
    t.equals(c.walksDuring(function() c.enter('skydome') end), 1)
    t.isTrue(not c.alive(stray), 'the sky arena was built without being swept, because the last one was elsewhere')

    -- And the other way round: the teardown sweeps the sky, and the trailer
    -- park has nothing to sweep.
    t.equals(c.walksDuring(function() c.enter('trailerpark') end), 1)
end)

t.test('the skip leans on the teardown having swept: a stray planted after the exit is gone after the next round', function()
    local c = newClient()
    c.enter('skydome', 1.25)
    c.exit()
    local strays = {
        c.plant(OURS, SKY.x, SKY.y, SKY.z - 10.0),
        c.plant('prop_container_01a', SKY.x + 60.0, SKY.y - 40.0, SKY.z),
        c.plant('prop_barrier_work05', SKY.x - 30.0, SKY.y + 20.0, SKY.z + 1.0),
    }
    local clean = newClient()
    clean.enter('skydome', 1.25)
    c.enter('skydome', 1.25)
    for _, stray in ipairs(strays) do t.isTrue(not c.alive(stray), 'a stray survived a same-size round') end
    t.equals(#c.world.live(), #clean.world.live(), 'the round is not exactly one arena')
    local lines = c.sweptLines()
    t.equals(lines[#lines], 'arena scenery: swept 3 stray piece(s) still standing at \'skydome\' from an earlier round.')
end)

t.test('and a stray planted while the arena still stands is gone after a same-size re-entry', function()
    local c = newClient()
    c.enter('skydome', 1.0)
    local stray = c.plant(OURS, SKY.x + 40.0, SKY.y + 40.0, SKY.z - 10.0)
    c.enter('skydome', 1.0)
    t.isTrue(not c.alive(stray), 'the stray standing beside the last arena survived the rebuild')
end)

t.test('the teardown sweeps AFTER it takes its own pieces down: an ordinary round reports no strays', function()
    -- THE ORDER INSIDE THE TEARDOWN THE SKIP LEANS ON. clearArenaScenery
    -- takes down the pieces it remembers and only then sweeps for what it
    -- does not. Swept first, the arena's own standing pieces are all strays
    -- to the sweep: every ordinary exit deletes the whole arena through it
    -- and tells the operator "swept 87 stray piece(s) ... from an earlier
    -- round" -- a false alarm on every round, with the world left exactly
    -- as it should be, so nothing that only counts objects notices. Nothing
    -- is planted here, so any swept line at all is that alarm.
    local function noAlarm(label, steps)
        local c = newClient()
        steps(c)
        t.isTrue(said(c):find('swept', 1, true) == nil,
            label .. ': a round with no strays reported some -- the teardown swept its own pieces')
        return c
    end
    local c = noAlarm('enter then exit', function(c) c.enter('skydome', 1.0); c.exit() end)
    t.equals(#c.world.live(), 0, 'the exit left pieces standing')
    noAlarm('enter, exit, the same size again', function(c)
        c.enter('skydome', 1.0); c.exit(); c.enter('skydome', 1.0); c.exit()
    end)
    local clean = newClient()
    clean.enter('skydome', 1.0)
    c = noAlarm('a same-size re-entry with no exit between', function(c)
        c.enter('skydome', 1.0); c.enter('skydome', 1.0)
    end)
    t.equals(#c.world.live(), #clean.world.live(), 'the re-entry is not exactly one arena')
    noAlarm('a grown re-entry with no exit between', function(c) c.enter('skydome', 1.0); c.enter('skydome', 2.0) end)
    noAlarm('a camera after an exit, then dropped', function(c)
        c.enter('skydome', 1.25); c.exit()
        t.isTrue(c.watch('skydome', 1.25), 'the camera build failed')
        c.unwatch()
    end)
end)

t.test('a piece that will not delete is tried by the teardown and left, as it always was', function()
    local c = newClient()
    c.enter('skydome', 1.0)
    c.exit()
    local stray = c.plant(OURS, SKY.x, SKY.y, SKY.z - 10.0, true)
    local before = c.calls['DeleteObject:sticky'] or 0
    local lines = #c.sweptLines()
    c.enter('skydome', 1.0)
    t.isTrue(c.alive(stray), 'the fixture let a sticky piece be deleted')
    t.isTrue((c.calls['DeleteObject:sticky'] or 0) - before >= 1, 'nothing even tried to delete it')
    t.equals(#c.sweptLines(), lines, 'a piece that did not go was reported as swept')
end)

t.test('a build that dies after creating a piece it never recorded leaves one arena, not one and a bit', function()
    -- THE ORPHAN THE SWEEP EXISTS FOR, made on purpose: the build raises
    -- between CreateObject and writing the handle down, so the piece stands
    -- and no list knows it. The failed entry's teardown sweeps it -- and the
    -- next same-size round, whose own sweep is now skipped, must still come
    -- out as exactly one clean arena.
    local c = newClient()
    local realHeading = c.env.SetEntityHeading
    local calls = 0
    c.env.SetEntityHeading = function(handle, heading)
        if c.world.objects[handle] then
            calls = calls + 1
            if calls == 5 then error('a native raised after CreateObject') end
        end
        return realHeading(handle, heading)
    end
    c.enter('skydome', 1.0)
    c.env.SetEntityHeading = realHeading
    t.isTrue(calls >= 5, 'the build never reached the failing call')
    t.equals(#c.world.live(), 0, 'the failed build left pieces standing')

    c.enter('skydome', 1.0)
    local clean = newClient()
    clean.enter('skydome', 1.0)
    t.equals(snapshot(c):gsub('^%d+ ', ''):gsub('\n%d+ ', '\n'),
        snapshot(clean):gsub('^%d+ ', ''):gsub('\n%d+ ', '\n'),
        'the round after a failed build is not exactly one clean arena')
end)

-- ======================================================================
-- THE DIFFERENTIAL: THE REAL CLIENT AGAINST THE OLD OPENING
-- ======================================================================

local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return (state // 65536) % n + 1
    end
end

--- One seeded run of rounds, exits, camera builds and strays, played on
--- the real client and on the reference side by side.
local function playSequence(seed, steps, stats)
    assert(REFERENCE_SOURCE ~= nil, 'there is no reference to compare against: see the first test')
    local real, ref = newClient(), newClient({ reference = true })
    local rand = generator(seed)
    local factors = { false, 1.0, 1.0, 1.25, 1.5, 2.0 }
    local sweepModels = {}
    for name in pairs(real.env.Arena.PropSweep('skydome', 2.0).models) do sweepModels[#sweepModels + 1] = name end
    table.sort(sweepModels)
    local reaches = {}
    for _, f in ipairs({ 1.0, 1.25, 1.5, 2.0 }) do reaches[#reaches + 1] = real.env.Arena.PropSweep('skydome', f).radius end

    local walksReal, walksRef = 0, 0
    for step = 1, steps do
        local op = rand(12)
        local key = rand(5) == 1 and 'trailerpark' or 'skydome'
        local factor = factors[rand(#factors)] or nil
        local label = ('seed %d step %d'):format(seed, step)
        local action
        if op <= 4 then
            action = function(c) c.enter(key, factor) end
            label = label .. (' enter %s %s'):format(key, tostring(factor))
            stats.enters = stats.enters + 1
        elseif op <= 6 then
            action = function(c) c.exit() end
            label = label .. ' exit'
        elseif op <= 9 then
            -- A stray: our model or not, in one of the rings between the
            -- sizes' reaches, inside the height or above it.
            local model = rand(4) == 1 and FOREIGN or sweepModels[rand(#sweepModels)]
            local ring = rand(#reaches + 1)
            local inner = ring == 1 and 0.0 or reaches[ring - 1]
            local outer = reaches[ring] or (reaches[#reaches] + 60.0)
            local r = inner + (outer - inner) * (rand(99) / 100.0)
            local angle = rand(360) * math.pi / 180.0
            local z = SKY.z + (rand(4) == 1 and 75.0 or (rand(81) - 41))
            local sticky = rand(6) == 1
            local x, y = SKY.x + r * math.cos(angle), SKY.y + r * math.sin(angle)
            action = function(c) c.plant(model, x, y, z, sticky) end
            label = label .. (' plant %s r=%.1f z=%.1f%s'):format(model, r, z, sticky and ' sticky' or '')
            stats.strays = stats.strays + 1
        elseif op == 10 then
            local watching = rand(4) ~= 1
            action = function(c) c.watch(key, factor or 1.0, not watching) end
            label = label .. (' watch %s %s%s'):format(key, tostring(factor or 1.0), watching and '' or ' (camera off)')
            stats.watches = stats.watches + 1
        elseif op == 11 then
            action = function(c) c.unwatch() end
            label = label .. ' unwatch'
        else
            action = function(c) c.fire('onResourceStop', 'crimson_arena') end
            label = label .. ' resource stop'
        end

        local a = real.walksDuring(function() action(real) end)
        local b = ref.walksDuring(function() action(ref) end)
        walksReal, walksRef = walksReal + a, walksRef + b

        t.equals(snapshot(real), snapshot(ref), label .. ': the world differs')
        t.equals(said(real), said(ref), label .. ': the consoles differ')
        local p, q = real.world.pedPos, ref.world.pedPos
        t.equals(('%.3f %.3f %.3f'):format(p.x, p.y, p.z), ('%.3f %.3f %.3f'):format(q.x, q.y, q.z),
            label .. ': the player ended up somewhere else')
        t.isTrue(a <= b, label .. ': the real client walked the pool MORE than the old one')
        stats.steps = stats.steps + 1
    end
    stats.walksReal = stats.walksReal + walksReal
    stats.walksRef = stats.walksRef + walksRef
end

local STATS = { steps = 0, enters = 0, strays = 0, watches = 0, walksReal = 0, walksRef = 0 }

t.test('over four hundred and fifty seeded steps the real client does exactly what the old opening did', function()
    for seed = 1, 30 do playSequence(7000 + seed * 31, 16, STATS) end
    t.equals(STATS.steps, 480)
    t.isTrue(STATS.enters > 100 and STATS.strays > 80 and STATS.watches > 20,
        ('the sequences did too little: %d entries, %d strays, %d camera builds')
            :format(STATS.enters, STATS.strays, STATS.watches))
end)

t.test('and across the same steps it walked the pool fewer times in all', function()
    t.isTrue(STATS.steps > 0, 'the differential above never ran')
    t.isTrue(STATS.walksReal < STATS.walksRef,
        ('the real client walked the pool %d time(s) against the old opening\'s %d')
            :format(STATS.walksReal, STATS.walksRef))
end)

os.exit(t.summary())
