--[[
    crimson_arena/tests/spectatorempty_spec.lua

    A CAMERA WATCHING AN ARENA THAT HAS NO SCENERY, EVERY FRAME.

    client/spectate.lua asks ArenaMatch.EnsureSpectatorScenery on every
    frame the camera runs, so that a watcher who never entered the arena
    still sees its floor and its wall. Its "already standing" guard asked
    `#arenaProps > 0` -- and an arena that has no scenery at all, the
    Trailer Park as shipped (real ground, cover switched off), never has
    any. So every frame of every watch of it ran the whole build: the
    teardown, two sweeps, a fresh builtArena, the floor-repair clock reset,
    and a plan that came back empty. Nothing was ever wrong with the answer.
    It was simply worked out again sixty times a second.

    The build now marks the arena it planned as empty, and the guard takes
    that mark as "standing" -- BUT ONLY WHILE THIS CAMERA'S OWN WATCH IS
    STILL UP. spectatorBuilt is lowered by every teardown there is, so the
    trap the guard's own comment records -- it once answered "standing" for
    an arena a teardown had just taken down -- cannot come back through the
    new clause.

    Held three ways:

      THE COST. An empty arena is planned once per watch, not once a frame,
      at either size and in either order of sizes, and for any arena with
      nothing to build -- the sky arena with its floor and cover switched
      off, or one an operator adds -- not only the one that ships empty.
      This is the half that failed before the change.

      THE REST OF THE WATCH, pinned as it was: the sky arena built once and
      kept; the second watch after a stop; a switch between arenas; a camera
      that stopped mid-answer; a teardown on the way out of a round; a sky
      floor that could not be built, and an arena that planned pieces and
      built none -- neither of which may ever be taken for an empty one.

      THE EQUIVALENCE. The guard and the build branch as they were are kept
      below and spliced back in to make a reference client. Both are driven
      through the same seeded runs -- watch either arena at either size for
      a few frames, drop, toggle the camera, move the ped, enter a round,
      exit -- and after every operation what is standing, whether the watch
      is up, and every answer the camera was given must be the same, and so
      must every native either client called, the clock aside. Each run
      also holds the new client's plans of the empty arena under what its
      own watches could ask for, so a saving lost for one kind of watch
      cannot hide in the total.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('spectatorempty_spec')

local PATH = '../Crimson-Arena/client/match.lua'

-- The skydome's spawn area centre, and the trailer park's: a watcher is
-- parked where the fighters are, which is where CreateObject can build.
local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }
local PARK = { x = 2344.4, y = 2565.1, z = 46.7 }
local FAR = { x = -282.0, y = -2030.0, z = 30.1 }

local function readFile(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

-- ======================================================================
-- THE REFERENCE: THE GUARD AND THE EMPTY BRANCH AS THEY WERE
-- ======================================================================

local GUARD_FROM = '    if builtArena and builtArena.key == arenaKey'
local EMPTY_FROM = '    if #wanted == 0 then\n'
local BLOCK_END = '        return true\n    end\n'

local REFERENCE_GUARD = '    if builtArena and builtArena.key == arenaKey and #arenaProps > 0 then\n' .. BLOCK_END
local REFERENCE_EMPTY = EMPTY_FROM .. BLOCK_END

--- Replaces the block that starts at `from` and ends at the first
--- `BLOCK_END` after it. Both anchors must be where they are expected.
local function splice(text, from, replacement, what)
    local at = text:find(from, 1, true)
    t.isNotNil(at, what .. ': the anchor the reference is spliced at is gone')
    t.isNil(text:find(from, at + 1, true), what .. ': the anchor appears twice')
    local to = text:find(BLOCK_END, at, true)
    t.isNotNil(to, what .. ': the end of the block is gone')
    -- A block and its own comment, not a stretch of the file.
    t.isTrue(to - at < 1500, what .. ': the spliced block runs on past the guard')
    t.isNil(text:sub(at, to):find('\nfunction ', 1, true), what .. ': the spliced block crosses a function')
    return text:sub(1, at - 1) .. replacement .. text:sub(to + #BLOCK_END)
end

local function referenceSource()
    local text = readFile(PATH)
    text = splice(text, GUARD_FROM, REFERENCE_GUARD, 'the guard')
    text = splice(text, EMPTY_FROM, REFERENCE_EMPTY, 'the empty branch')
    return text
end

-- ======================================================================
-- THE FIXTURE
-- ======================================================================

--- An upvalue of one of the file's functions, by name. How a spec reads
--- whether THIS CAMERA'S WATCH IS UP, which is a local and nothing else.
local function upvalue(fn, name)
    for index = 1, 255 do
        local key, value = debug.getupvalue(fn, index)
        if key == nil then break end
        if key == name then return value end
    end
    error('no upvalue called ' .. name)
end

--- NATIVES THAT ONLY ANSWER A QUESTION, left out of the record the two
--- clients are compared on. They change nothing in the game, and asking
--- them less often is exactly what an optimisation is allowed to do; every
--- native that DOES change something -- an object made, moved, frozen or
--- deleted, a model asked for or let go, a control held -- is recorded,
--- with its arguments, in order, per thread.
local READS_ONLY = {
    GetGameTimer = true, HasModelLoaded = true, IsModelInCdimage = true, IsModelValid = true,
    GetModelDimensions = true, DoesEntityExist = true, GetEntityModel = true, GetGamePool = true,
    GetEntityCoords = true, GetEntityHeading = true, PlayerPedId = true, PlayerId = true,
    IsEntityDead = true, GetEntityHealth = true, GetPedArmour = true, GetSelectedPedWeapon = true,
    HasPedGotWeapon = true, GetAmmoInPedWeapon = true, IsPauseMenuActive = true,
    HasCollisionLoadedAroundEntity = true, GetGroundZFor_3dCoord = true, GetPlayerServerId = true,
    GetPlayerFromServerId = true, NetworkIsPlayerActive = true, GetPlayerPed = true,
    DoesBlipExist = true, GetPedSourceOfDeath = true, IsEntityAPed = true, IsPedAPlayer = true,
    NetworkGetPlayerIndexFromPed = true,
}

--- A client/match.lua in the modelled world, with a camera module the
--- test switches, a frame clock, and every plan and every native counted.
--- @param opts table? -- { source = text, start = point, models = table, cover = { arenaKey }, record = false,
---                        mutate = fn(Config), before the file loads }
local function newClient(opts)
    opts = opts or {}
    local world = World.new({ start = opts.start or SKY, models = opts.models })
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = {
        world = world, runner = runner, clock = 10000,
        log = {}, plans = {}, answers = {}, printed = {}, toServer = {},
        spectateActive = true,
    }

    local labels, nextLabel = {}, 0
    local function label(co)
        if not labels[co] then
            nextLabel = nextLabel + 1
            labels[co] = 'thread' .. nextLabel
        end
        return labels[co]
    end

    local natives = {
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
        GetPedSourceOfDeath = function() return 0 end,
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
        SetPlayerTeam = function() end,
        NetworkSetFriendlyFireOption = function() end,
        SetCanAttackFriendly = function() end,
    }
    for name, fn in pairs(world.natives) do natives[name] = fn end
    -- A FRAME CLOCK that moves a frame's worth on every step. Model loads in
    -- this world answer at once, so no build ever waits on it.
    natives.GetGameTimer = function() return c.clock end
    natives.joaat, natives.vector3, natives.vec3 = nil, nil, nil

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            c.toServer[#c.toServer + 1] = { name = name, payload = payload }
            c.log[#c.log + 1] = { name = 'event:' .. tostring(name), args = {}, co = label(coroutine.running()) }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        print = function(line) c.printed[#c.printed + 1] = tostring(line) end,
        lib = { notify = function() end },
        joaat = world.natives.joaat,
        vector3 = world.natives.vector3,
        vec3 = world.natives.vec3,
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
        -- THE CAMERA, as far as client/match.lua reaches into it -- and its
        -- Stop does what client/spectate.lua's does: the camera comes down
        -- and, if it was up, the scenery it asked for is dropped in the same
        -- call, before anything else can run.
        ArenaSpectate = {
            IsActive = function() return c.spectateActive == true end,
            Stop = function()
                local was = c.spectateActive
                c.spectateActive = false
                if was then c.env.ArenaMatch.DropSpectatorScenery() end
            end,
            Start = function() c.spectateActive = true end,
        },
    }
    -- WHAT IS STANDING, KEPT AS IT CHANGES. world.live() walks every object
    -- ever made, and a run that builds the sky arena a hundred times makes
    -- thousands; asking it after every operation of every run is what made
    -- this file take minutes. Nothing in this file deletes an object behind
    -- the resource's back, so create and delete are the whole story.
    c.alive, c.aliveCount = {}, 0
    for name, fn in pairs(natives) do
        local logged = opts.record ~= false and not READS_ONLY[name]
        overrides[name] = function(...)
            if logged then
                c.log[#c.log + 1] = { name = name, args = { ... }, co = label(coroutine.running()) }
            end
            if name == 'CreateObject' then
                local handle = fn(...)
                if handle ~= 0 then
                    c.alive[handle] = true
                    c.aliveCount = c.aliveCount + 1
                end
                return handle
            elseif name == 'DeleteObject' then
                local handle = ...
                if c.alive[handle] then
                    c.alive[handle] = nil
                    c.aliveCount = c.aliveCount - 1
                end
            end
            return fn(...)
        end
    end

    local env = Sandbox.newArenaEnv(overrides)
    for _, key in ipairs(opts.cover or {}) do
        env.Config.Arenas[key].cover.enabled = true
    end
    if opts.mutate then opts.mutate(env.Config) end
    local chunk = assert(load(opts.source or readFile(PATH), '@' .. PATH, 't', env))
    chunk()
    c.env = env

    -- EVERY PLAN, BY ARENA. Arena.ArenaProps is looked up on the global at
    -- the moment the build calls it, so wrapping it here sees every one.
    local realPlan = env.Arena.ArenaProps
    env.Arena.ArenaProps = function(arenaKey, ...)
        c.plans[arenaKey] = (c.plans[arenaKey] or 0) + 1
        return realPlan(arenaKey, ...)
    end

    function c.watchUp()
        return upvalue(env.ArenaMatch.DropSpectatorScenery, 'spectatorBuilt') == true
    end

    --- Runs one call inside a coroutine, which is where the camera runs it.
    local function inThread(fn)
        local result
        local thread = coroutine.create(function() result = fn() end)
        for _ = 1, 400 do
            if coroutine.status(thread) == 'dead' then break end
            local ok, err = coroutine.resume(thread)
            if not ok then error(err) end
        end
        assert(coroutine.status(thread) == 'dead', 'the call never finished')
        return result
    end
    c.inThread = inThread

    --- One camera frame watching `arenaKey`: the camera's question, then
    --- every other thread once. Returns the answer the camera was given.
    function c.watch(arenaKey, factor)
        c.clock = c.clock + 16
        local answer = inThread(function() return env.ArenaMatch.EnsureSpectatorScenery(arenaKey, factor) end)
        c.answers[#c.answers + 1] = answer
        runner.step()
        return answer
    end

    function c.drop() inThread(function() return env.ArenaMatch.DropSpectatorScenery() end) end
    function c.stopCamera() inThread(function() return env.ArenaSpectate.Stop() end) end
    function c.startCamera() env.ArenaSpectate.Start() end

    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('no handler for ' .. name) end
        local args = table.pack(...)
        inThread(function() return handler(table.unpack(args, 1, args.n)) end)
    end

    function c.enter(arenaKey)
        local arena = env.Config.Arenas[arenaKey]
        local spawn = env.Arena.PickSpawn(arenaKey, nil, 1)
        c.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1', arenaKey = arenaKey, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, sizeFactor = 1.0, radar = false,
            loadout = { weapons = {} },
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius, warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        })
    end

    function c.moveTo(point) world.pedPos = { x = point.x, y = point.y, z = point.z } end

    --- Whether exactly the same objects stand in both worlds, made in the
    --- same order (so under the same handles), of the same models, at the
    --- same places. Compared as values: it is asked after every operation.
    function c.sameStanding(other)
        if c.aliveCount ~= other.aliveCount then return false end
        for handle in pairs(c.alive) do
            if not other.alive[handle] then return false end
            local mine, theirs = world.objects[handle], other.world.objects[handle]
            if mine.model ~= theirs.model or mine.x ~= theirs.x or mine.y ~= theirs.y or mine.z ~= theirs.z
                or mine.heading ~= theirs.heading or mine.frozen ~= theirs.frozen
                or mine.collision ~= theirs.collision
            then
                return false
            end
        end
        return true
    end

    --- Every object standing, in the order it was made.
    function c.standing()
        local handles = {}
        for handle in pairs(c.alive) do handles[#handles + 1] = handle end
        table.sort(handles)
        local out = {}
        for _, handle in ipairs(handles) do
            local object = world.objects[handle]
            out[#out + 1] = ('%s@%.3f,%.3f,%.3f'):format(object.model, object.x, object.y, object.z)
        end
        return table.concat(out, ';')
    end

    return c
end

-- ======================================================================
-- THE COST
-- ======================================================================

t.test('THE WASTE: an arena with no scenery is planned once per watch, not once a frame', function()
    local c = newClient({ start = PARK })
    for _ = 1, 100 do c.watch('trailerpark', 1.0) end
    t.equals(c.plans.trailerpark or 0, 1,
        ('the empty arena was planned %d times in 100 frames'):format(c.plans.trailerpark or 0))
end)

t.test('and at either size, since size is not what the guard checks', function()
    -- BOTH ORDERS, and each size alone. A watch that STARTS grown is the one
    -- a guard tied to the default size would miss: the build records the
    -- size it was made at, so a run that starts at 1.0 never shows it.
    for _, sizes in ipairs({ { 1.0, 1.3 }, { 1.3, 1.0 }, { 1.3 }, { 1.0 } }) do
        local c = newClient({ start = PARK })
        for frame = 1, 40 do c.watch('trailerpark', sizes[(frame - 1) % #sizes + 1]) end
        t.equals(c.plans.trailerpark or 0, 1,
            ('sizes %s: an arena with nothing to size was planned %d times in 40 frames')
                :format(table.concat(sizes, ' then '), c.plans.trailerpark or 0))
    end
end)

--- The same arena with nothing to build, made two other ways: the sky
--- arena with its floor and its cover switched off, and an arena an
--- operator added under a key of their own.
local OTHER_EMPTY = {
    {
        key = 'skydome', start = SKY,
        mutate = function(config)
            config.Arenas.skydome.platform.enabled = false
            config.Arenas.skydome.cover.enabled = false
        end,
    },
    {
        key = 'yard', start = PARK,
        mutate = function(config)
            local yard = {}
            for field, value in pairs(config.Arenas.trailerpark) do yard[field] = value end
            yard.label = 'The Yard'
            config.Arenas.yard = yard
        end,
    },
}

t.test('AND FOR ANY ARENA WITH NOTHING TO BUILD, not only the one that ships that way', function()
    -- The Trailer Park is the only arena in the shipped config with nothing
    -- to build, so every other test here watches it. The fix is about an
    -- empty PLAN, whatever arena it is for: an operator who switches the
    -- sky arena's floor and cover off, or adds a ground arena of their own,
    -- must not be handed back the re-plan on every frame.
    for _, case in ipairs(OTHER_EMPTY) do
        local c = newClient({ start = case.start, mutate = case.mutate })
        for frame = 1, 40 do
            t.isTrue(c.watch(case.key, frame % 3 == 1 and 1.3 or 1.0), case.key .. ': frame ' .. frame .. ' was refused')
        end
        t.equals(c.plans[case.key] or 0, 1,
            ('%s: an arena with nothing to build was planned %d times in 40 frames'):format(case.key, c.plans[case.key] or 0))
        t.equals(c.standing(), '', case.key .. ': something was built')
        t.isTrue(c.watchUp(), case.key .. ': the watch is not up')
        c.drop()
        for _ = 1, 10 do c.watch(case.key, 1.0) end
        t.equals(c.plans[case.key] or 0, 2, case.key .. ': the watch after a stop was not planned exactly once more')
    end
end)

t.test('and a second watch after a stop is planned once more, and only once', function()
    local c = newClient({ start = PARK })
    for _ = 1, 10 do c.watch('trailerpark', 1.0) end
    c.drop()
    for _ = 1, 10 do c.watch('trailerpark', 1.0) end
    t.equals(c.plans.trailerpark or 0, 2, 'the second watch was planned other than once')
end)

-- ======================================================================
-- THE WATCH, AS IT WAS
-- ======================================================================

t.test('watching the empty arena answers yes on every frame, builds nothing, and holds the watch up', function()
    local c = newClient({ start = PARK })
    for frame = 1, 30 do
        t.isTrue(c.watch('trailerpark', 1.0), 'frame ' .. frame .. ' was told there is no arena')
        t.equals(c.standing(), '', 'frame ' .. frame .. ' built scenery an arena on the map does not have')
        t.isTrue(c.watchUp(), 'frame ' .. frame .. ' did not hold the watch up')
    end
    t.equals(#c.world.order, 0, 'an object was ever created')
    -- The start-up checks print about the outline and the marker on this
    -- fixture, which has neither; what must not appear is the scenery.
    for _, line in ipairs(c.printed) do
        t.notContains(line, 'scenery', 'watching an empty arena said something about its scenery')
    end
end)

t.test('a stop lowers the watch, and the next watch raises it again', function()
    local c = newClient({ start = PARK })
    c.watch('trailerpark', 1.0)
    c.drop()
    t.isFalse(c.watchUp(), 'the stop left the watch up')
    t.isTrue(c.watch('trailerpark', 1.0), 'the second watch was told there is no arena')
    t.isTrue(c.watchUp(), 'the second watch did not raise it')
end)

t.test('the sky arena is built once and kept, frame after frame', function()
    local c = newClient({ start = SKY })
    t.isTrue(c.watch('skydome', 1.0), 'the first frame built nothing')
    local standing = c.standing()
    t.isTrue(standing ~= '', 'the sky arena put nothing up')
    local created = #c.world.order
    for _ = 1, 30 do
        t.isTrue(c.watch('skydome', 1.0))
        t.equals(c.standing(), standing, 'the sky arena changed under the camera')
    end
    t.equals(#c.world.order, created, 'the sky arena was rebuilt while it stood')
    t.equals(c.plans.skydome, 1, 'the sky arena was planned more than once')
end)

t.test('from the empty arena to the sky one and back: built, then taken down', function()
    local c = newClient({ start = SKY })
    for _ = 1, 5 do c.watch('trailerpark', 1.0) end
    t.equals(c.standing(), '', 'the empty arena put something up')
    t.isTrue(c.watch('skydome', 1.0), 'switching to the sky arena built nothing')
    t.isTrue(c.standing() ~= '', 'the sky arena is not standing')
    t.isTrue(c.watch('trailerpark', 1.0), 'switching back was refused')
    t.equals(c.standing(), '', 'the sky arena was left standing for a watch of the trailer park')
    t.isTrue(c.watchUp(), 'the watch of the trailer park is not up')
    t.isTrue(c.watch('skydome', 1.0), 'and forward again built nothing')
    t.isTrue(c.standing() ~= '', 'the second switch to the sky arena built nothing')
end)

t.test('a camera that stopped before the answer is told no, and asked again when it is back', function()
    -- In the game this is a Stop landing while a build waits on a model:
    -- the camera is gone by the time the answer is checked. Here the camera
    -- is simply off when asked, which reaches the same check.
    local c = newClient({ start = PARK })
    c.spectateActive = false
    t.isFalse(c.watch('trailerpark', 1.0), 'a stopped camera was told the arena is up')
    t.isFalse(c.watchUp(), 'a stopped camera left the watch up')
    local before = c.plans.trailerpark or 0
    c.spectateActive = true
    t.isTrue(c.watch('trailerpark', 1.0), 'the camera, back, was told there is no arena')
    t.isTrue((c.plans.trailerpark or 0) > before, 'the camera, back, was not planned for again')
    t.isTrue(c.watchUp(), 'the camera, back, has no watch up')
end)

t.test('a camera stopped while a watch is up takes the watch down with it, whatever it was watching', function()
    -- THE INVARIANT THE NEW CLAUSE LEANS ON: the watch is never up while the
    -- camera is stopped. Stop drops it in the same call.
    for _, arena in ipairs({ 'trailerpark', 'skydome' }) do
        local c = newClient({ start = arena == 'skydome' and SKY or PARK })
        t.isTrue(c.watch(arena, 1.0), arena .. ': the watch was refused')
        t.isTrue(c.watchUp(), arena .. ': the watch did not go up')
        c.stopCamera()
        t.isFalse(c.watchUp(), arena .. ': the stop left the watch up')
        t.equals(c.standing(), '', arena .. ': the stop left scenery standing')
        c.startCamera()
        t.isTrue(c.watch(arena, 1.0), arena .. ': the watch after a restart was refused')
        t.isTrue(c.watchUp(), arena .. ': the watch after a restart did not go up')
    end
end)

t.test('every way out of a round lowers the watch, so the next one is planned again', function()
    for _, way in ipairs({ 'exit', 'enter-another', 'resource-stop' }) do
        local c = newClient({ start = PARK })
        c.watch('trailerpark', 1.0)
        t.isTrue(c.watchUp(), way .. ': the watch never went up')
        if way == 'exit' then
            c.enter('trailerpark')
            c.fire('crimson_arena:client:exitArena', {})
        elseif way == 'enter-another' then
            c.enter('trailerpark')
        else
            c.fire('onResourceStop', 'crimson_arena')
        end
        t.isFalse(c.watchUp(), way .. ': the teardown left the watch up')
        local before = c.plans.trailerpark or 0
        c.spectateActive = true
        t.isTrue(c.watch('trailerpark', 1.0), way .. ': the next watch was told there is no arena')
        t.equals((c.plans.trailerpark or 0) - before, 1, way .. ': the next watch was not planned exactly once')
    end
end)

t.test('a fighter standing in the empty arena, then watching it, is told it is up and loses nothing', function()
    local c = newClient({ start = PARK })
    c.enter('trailerpark')
    for _ = 1, 10 do
        t.isTrue(c.watch('trailerpark', 1.0), 'the fighter was told their own arena is not up')
    end
    t.equals(c.standing(), '', 'the fighter\'s arena grew scenery')
end)

t.test('a sky floor that could not be built is asked for again every frame, and is never "up"', function()
    -- Too far away to build: CreateObject refuses outside the streamed
    -- world, so the floor comes out empty and the build says no. That is a
    -- failure, not an empty arena, and must be retried.
    local c = newClient({ start = FAR })
    for frame = 1, 10 do
        t.isFalse(c.watch('skydome', 1.0), 'frame ' .. frame .. ': a floorless sky arena was reported as up')
        t.isFalse(c.watchUp(), 'frame ' .. frame .. ': a failed build left the watch up')
    end
    t.equals(c.plans.skydome, 10, 'a failed sky build stopped being retried')
    -- And once the camera is somewhere it can build, it does.
    c.moveTo(SKY)
    t.isTrue(c.watch('skydome', 1.0), 'the sky arena was not built once it could be')
    t.isTrue(c.standing() ~= '', 'nothing is standing')
end)

t.test('an arena that PLANNED pieces and built none is not taken for an empty one', function()
    -- Cover switched on, and none of its models on this build: the plan has
    -- pieces, none can be made, and the build says yes with nothing up.
    -- Only a plan with NOTHING in it is an empty arena; this one keeps being
    -- asked for, as it always was.
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do
        if not name:find('container', 1, true) and not name:find('conc_blocks', 1, true)
            and not name:find('barrier', 1, true) then
            models[name] = size
        end
    end
    local c = newClient({ start = PARK, models = models, cover = { 'trailerpark' } })
    for _ = 1, 8 do
        t.isTrue(c.watch('trailerpark', 1.0))
        t.equals(c.standing(), '', 'a cover piece this build does not have was built')
    end
    t.equals(c.plans.trailerpark, 8, 'a plan with pieces that built none stopped being retried')
end)

t.test('THE MARK is on a build that planned nothing, and on no other kind of build', function()
    -- Read straight off the build's own record, because the gate hides a
    -- mark in the wrong place from everything the camera can see -- which
    -- is exactly why it must not be there: the gate is the second lock, not
    -- the only one.
    local function mark(c)
        local record = upvalue(c.env.ArenaMatch.EnsureSpectatorScenery, 'builtArena')
        return record and record.empty
    end

    local empty = newClient({ start = PARK })
    empty.watch('trailerpark', 1.0)
    t.equals(mark(empty), true, 'an arena that planned nothing is not marked')

    local floorless = newClient({ start = FAR })
    floorless.watch('skydome', 1.0)
    t.isNil(mark(floorless), 'a sky floor that could not be built was marked empty')

    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do
        if not name:find('container', 1, true) and not name:find('conc_blocks', 1, true)
            and not name:find('barrier', 1, true) then
            models[name] = size
        end
    end
    local unbuilt = newClient({ start = PARK, models = models, cover = { 'trailerpark' } })
    unbuilt.watch('trailerpark', 1.0)
    t.isNil(mark(unbuilt), 'a plan whose pieces all failed was marked empty')

    local sky = newClient({ start = SKY })
    sky.watch('skydome', 1.0)
    t.isNil(mark(sky), 'a sky arena that stands was marked empty')

    for _, case in ipairs(OTHER_EMPTY) do
        local other = newClient({ start = case.start, mutate = case.mutate })
        other.watch(case.key, 1.3)
        t.equals(mark(other), true, case.key .. ', planning nothing, is not marked')
    end

    -- AND A FRESH BUILD FORGETS IT: the mark belongs to one build's record.
    empty.moveTo(SKY)
    empty.watch('skydome', 1.0)
    t.isNil(mark(empty), 'the empty mark outlived the build that set it')
end)

t.test('the same arena with its cover buildable is built once and kept', function()
    local c = newClient({ start = PARK, cover = { 'trailerpark' } })
    t.isTrue(c.watch('trailerpark', 1.0))
    local standing = c.standing()
    t.isTrue(standing ~= '', 'the cover block did nothing')
    for _ = 1, 10 do c.watch('trailerpark', 1.0) end
    t.equals(c.standing(), standing, 'the cover block changed under the camera')
    t.equals(c.plans.trailerpark, 1, 'the cover block was re-planned while it stood')
end)

t.test('garbage arena keys are refused before any plan', function()
    local c = newClient({ start = PARK })
    for _, key in ipairs({ false, '', 42 }) do
        t.isFalse(c.inThread(function() return c.env.ArenaMatch.EnsureSpectatorScenery(key, 1.0) end),
            tostring(key) .. ' was accepted')
    end
    local planned = 0
    for _, n in pairs(c.plans) do planned = planned + n end
    t.equals(planned, 0, 'a garbage key was planned')
    t.isFalse(c.watchUp(), 'a garbage key raised the watch')
end)

t.test('a key no arena has is answered as it always was: nothing to build, so yes', function()
    local c = newClient({ start = PARK })
    for _ = 1, 3 do
        t.isTrue(c.watch('nowhere', 1.0), 'an unknown arena was answered differently')
    end
    t.equals(c.standing(), '')
end)

-- ======================================================================
-- THE EQUIVALENCE
-- ======================================================================

local function rng(seed)
    local state = seed
    return function(n)
        -- Park-Miller: exact in a double, the same on every machine.
        state = (state * 48271) % 2147483647
        return (state % n) + 1
    end
end

local function render(call)
    local parts = {}
    for index = 1, select('#', table.unpack(call.args)) do
        local value = call.args[index]
        if type(value) == 'number' then
            parts[#parts + 1] = ('%.6g'):format(value)
        elseif type(value) == 'table' then
            parts[#parts + 1] = ('{%s,%s,%s}'):format(tostring(value.x), tostring(value.y), tostring(value.z))
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    return ('%s %s(%s)'):format(call.co, call.name, table.concat(parts, ','))
end

--- Every native a client called since `from` that changes anything. See
--- READS_ONLY for what is left out and why.
local function trace(c, from)
    local out = {}
    for index = from, #c.log do out[#out + 1] = c.log[index] end
    return out
end

local function sameValue(a, b)
    if type(a) == 'table' and type(b) == 'table' then
        return a.x == b.x and a.y == b.y and a.z == b.z
    end
    return a == b
end

--- Two calls are the same call: same thread, same native, same arguments.
--- Compared as values, and only rendered as text when they differ -- the
--- runs make millions of calls between them.
local function sameCall(a, b)
    if a.name ~= b.name or a.co ~= b.co or #a.args ~= #b.args then return false end
    for index = 1, math.max(#a.args, #b.args) do
        if not sameValue(a.args[index], b.args[index]) then return false end
    end
    return true
end

t.test('THE REFERENCE is the guard and the empty branch as they were', function()
    local reference = referenceSource()
    t.contains(reference, REFERENCE_GUARD, 'the old guard is not in the reference')
    t.isNil(reference:find('.empty', 1, true), 'the reference still marks an empty arena')
    local c = newClient({ source = reference, start = PARK })
    for _ = 1, 10 do c.watch('trailerpark', 1.0) end
    t.equals(c.plans.trailerpark, 10, 'the reference does not plan every frame the way the old guard did')
end)

t.test('DIFFERENTIAL: 200 seeded runs of 150 operations -- the new guard changes nothing anybody can see', function()
    local reference = referenceSource()
    local ARENAS = { 'trailerpark', 'skydome' }
    -- WEIGHTED TOWARDS WHERE A WATCHER REALLY STANDS. A camera parked far
    -- from the sky arena, or switched off while still asked, rebuilds that
    -- arena on every frame -- old and new alike, by design -- and those
    -- frames cost a full build each. They are kept, at a rate that lets
    -- three hundred runs finish.
    local PLACES = { SKY, SKY, SKY, SKY, SKY, SKY, PARK, PARK, PARK, PARK, PARK, FAR }
    local seen = {}
    local function saw(what) seen[what] = (seen[what] or 0) + 1 end
    local compared, savedPlans = 0, 0

    for seed = 1, 200 do
        local roll = rng(seed * 15485863)
        local start = PLACES[roll(#PLACES)]
        -- EVERY NATIVE IS COMPARED IN THE FIRST SIXTY RUNS; the rest compare
        -- what the camera and the player can see, which is what the claim is
        -- about, at half the cost.
        local record = seed <= 60
        local old = newClient({ source = reference, start = start, record = record })
        local new = newClient({ start = start, record = record })
        local marks = { 1, 1 }
        local inRound = false
        local lastArena = nil
        -- THE MOST PLANS OF THE EMPTY ARENA THE NEW GUARD MAY MAKE IN THIS
        -- RUN: one per watch with the camera up, whatever size it asks for;
        -- one a frame with it stopped, where every answer is worked out
        -- afresh by design; and one per round entered there. Held per run,
        -- so a guard that lost the saving at one size, or for one kind of
        -- watch, cannot hide behind the total over all of them.
        local allowance = 0

        local reseeds = 0
        local function both(fn)
            reseeds = reseeds + 1
            for _, c in ipairs({ old, new }) do
                math.randomseed(seed, reseeds)
                fn(c)
            end
        end

        for op = 1, 150 do
            local label = ('seed %d, op %d'):format(seed, op)
            local what = roll(10)
            if what <= 5 then
                -- A WATCHER MOSTLY KEEPS WATCHING WHAT THEY WERE WATCHING,
                -- and a switch costs a full build of the sky arena.
                local arena = (lastArena and roll(10) <= 6) and lastArena or ARENAS[roll(2)]
                lastArena = arena
                local factor = roll(2) == 1 and 1.0 or 1.3
                local frames = roll(5)
                -- client/spectate.lua parks the watcher by the fighters
                -- before it builds, so a watch of the sky arena usually
                -- starts there. Not always: the rest are the failed builds.
                if arena == 'skydome' and roll(10) ~= 1 then
                    both(function(c) c.moveTo(SKY) end)
                end
                -- AND IT ASKS ONLY WHILE IT IS RUNNING. A watch starts the
                -- camera (the way out of a round stops it); the rest ask
                -- with it stopped -- the moment a stop lands in the middle
                -- of an answer -- which costs a full build a frame.
                if not old.spectateActive and roll(8) ~= 1 then
                    both(function(c) c.startCamera() end)
                end
                if arena == 'trailerpark' then
                    allowance = allowance + (new.spectateActive and 1 or frames)
                    saw(('watch trailerpark at %.1f'):format(factor))
                end
                for frame = 1, frames do
                    local a = old.watch(arena, factor)
                    local b = new.watch(arena, factor)
                    t.equals(b, a, ('%s, frame %d: the camera was given a different answer'):format(label, frame))
                end
                saw('watch ' .. arena)
            elseif what == 6 then
                both(function(c) c.drop() end)
                saw('drop')
            elseif what == 7 then
                -- THE CAMERA STARTED OR STOPPED THE WAY spectate.lua DOES IT:
                -- a stop drops the watch in the same call.
                if roll(8) ~= 1 then
                    both(function(c) c.startCamera() end)
                    saw('camera on')
                else
                    both(function(c) c.stopCamera() end)
                    saw('camera off')
                end
            elseif what == 8 then
                local place = PLACES[roll(#PLACES)]
                both(function(c) c.moveTo(place) end)
                saw('move')
            elseif what == 9 then
                local arena = ARENAS[roll(2)]
                both(function(c) c.enter(arena) end)
                if arena == 'trailerpark' then allowance = allowance + 1 end
                inRound = true
                saw('enter ' .. arena)
            else
                both(function(c) c.fire('crimson_arena:client:exitArena', {}) end)
                saw(inRound and 'exit' or 'exit with no round')
                inRound = false
            end

            if not new.sameStanding(old) then
                t.equals(new.standing(), old.standing(), label .. ': different scenery is standing')
            end
            t.equals(new.watchUp(), old.watchUp(), label .. ': the watch is up on one and not the other')
            t.equals(#new.toServer, #old.toServer, label .. ': the server was told different things')
            t.equals(#new.printed, #old.printed, label .. ': the console was told different things')

            local a, b = trace(old, marks[1]), trace(new, marks[2])
            marks[1], marks[2] = #old.log + 1, #new.log + 1
            t.equals(#b, #a, label .. ': the two made a different number of native calls')
            for index = 1, math.min(#a, #b) do
                if not sameCall(a[index], b[index]) then
                    t.equals(render(b[index]), render(a[index]), ('%s: native call %d differs'):format(label, index))
                end
            end
            compared = compared + 1
        end
        savedPlans = savedPlans + (old.plans.trailerpark or 0) - (new.plans.trailerpark or 0)
        t.isTrue((new.plans.trailerpark or 0) <= allowance,
            ('seed %d: the empty arena was planned %d times, and no more than %d watches and rounds asked for it')
                :format(seed, new.plans.trailerpark or 0, allowance))
        t.equals(new.plans.skydome or 0, old.plans.skydome or 0,
            ('seed %d: the sky arena was planned a different number of times'):format(seed))
    end

    t.equals(compared, 200 * 150, 'not every operation was compared')
    -- WHAT THE RUNS REACHED. A camera left off is the rare one on purpose
    -- (see the watch above), so it is held to less.
    local AT_LEAST = {
        ['watch trailerpark'] = 3000, ['watch skydome'] = 3000, drop = 1000, move = 1000,
        ['camera on'] = 1000, ['camera off'] = 200, ['enter trailerpark'] = 500,
        ['enter skydome'] = 500, exit = 500, ['exit with no round'] = 500,
        ['watch trailerpark at 1.0'] = 1500, ['watch trailerpark at 1.3'] = 1500,
    }
    for what, least in pairs(AT_LEAST) do
        t.isTrue((seen[what] or 0) >= least, ('the runs did "%s" only %d times'):format(what, seen[what] or 0))
    end
    -- AND IT SAVED SOMETHING, or these are two copies of one guard.
    t.isTrue(savedPlans > 10000, 'the new guard saved almost no plans: ' .. savedPlans)
end)

os.exit(t.summary())
