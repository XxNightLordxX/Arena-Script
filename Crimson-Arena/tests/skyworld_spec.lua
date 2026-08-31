--[[
    crimson_arena/tests/skyworld_spec.lua

    THE REAL client/match.lua, RUN.

    Every other spec about the arena in the sky asserts arithmetic:
    shared/arena.lua works out where the pieces go, and it does that without
    calling a single native, so it can be checked anywhere. This file checks
    the other half -- the half that is nothing but natives, and that
    therefore shipped three times broken while every arithmetic test stayed
    green.

    It loads the production client file into fixtures/world.lua, a model of
    the game with objects, a streaming bubble, prop dimensions and real
    terrain underneath, fires the entry event the server really sends, and
    then asks the question that matters: IS THERE A FLOOR UNDER THIS PLAYER.

    The three defects this would have caught on the day, each pinned below by
    a test named DEFECT:

      1. The floor was built a kilometre from the player, so the engine built
         nothing and the round silently never started.
      2. The surface was derived from the prop instead of set by config, so
         cover was buried inside the floor.
      3. Tiles were spaced on the prop's longest side and kept by their
         centres, so the floor had gaps -- and on a prop wider than the
         inset, exactly one tile.

    What this file does NOT claim is that the model is GTA. See the header of
    fixtures/world.lua: its streaming rule is deliberately stricter than the
    engine, so that passing here does not depend on the engine being
    generous.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('skyworld_spec')

-- ======================================================================
-- ONE CLIENT, IN ONE WORLD
-- ======================================================================

--- A client/match.lua running inside a modelled game.
--- @param opts table? -- passed to World.new, plus { cover = boolean }
--- @return table client
local function newClient(opts)
    opts = opts or {}
    local world = World.new(opts)
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { world = world, serverEvents = {}, notifications = {} }

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,

        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            c.serverEvents[#c.serverEvents + 1] = { name = name, payload = payload }
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
        SetEntityDrawOutlineColor = function() end,

        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,

        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end

    -- A HOOK INTO THE MIDDLE OF THE BUILD. Loading a model is where the
    -- entry handler yields, so it is the only seam a round ending mid-build
    -- can be simulated from.
    --
    -- `interruptAfter` counts model loads rather than firing on the first,
    -- because the first is the measurement load -- before a single piece
    -- exists, which is not the window that leaks.
    local realRequest = overrides.RequestModel
    local loads = 0
    overrides.RequestModel = function(...)
        loads = loads + 1
        if c.duringBuild and loads >= (c.interruptAfter or 1) then
            local interrupt = c.duringBuild
            c.duringBuild = nil
            interrupt()
        end
        return realRequest(...)
    end

    local env = Sandbox.newArenaEnv(overrides)
    if opts.cover then
        for _, key in ipairs(opts.cover) do
            local arena = env.Config.Arenas[key]
            if arena and type(arena.cover) == 'table' then arena.cover.enabled = true end
        end
    end
    Sandbox.loadInto('../client/match.lua', env)

    c.env = env
    c.Arena = env.Arena
    c.step = runner.step

    --- Fires a handler the way FiveM does -- inside a coroutine, resumed
    --- until it finishes -- so the yields inside the entry path park rather
    --- than error.
    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('client/match.lua registered no handler for ' .. name) end
        local args = table.pack(...)
        local thread = coroutine.create(function() handler(table.unpack(args, 1, args.n)) end)
        for _ = 1, 200 do
            if coroutine.status(thread) == 'dead' then break end
            local ok, err = assert(coroutine.resume(thread))
            if not ok then error(err) end
        end
        assert(coroutine.status(thread) == 'dead',
            ('the %s handler never finished -- it is stuck in a loop'):format(name))
    end

    --- The payload server/match.lua really sends, built from the real
    --- config through the real Arena so it cannot drift from production.
    --- @param arenaKey string
    --- @param spawn table?
    function c.enter(arenaKey, spawn, factor)
        local arena = env.Config.Arenas[arenaKey]
        spawn = spawn or env.Arena.PickSpawn(arenaKey, nil, 1)
        c.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1',
            arenaKey = arenaKey,
            modeKey = 'ffa',
            teamKey = nil,
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            -- The server sends no extra scatter where it has planned the
            -- spawns itself; a fixed point is what a spec wants anyway,
            -- because a random offset makes "is there a floor here" a
            -- different question every run.
            scatterRadius = 0.0,
            -- How much bigger the arena is for this match. The server works
            -- it out from the roster and sends it; this side cannot see a
            -- roster.
            sizeFactor = factor,
            radar = false,
            loadout = { weapons = {} },
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius * math.max(1.0, factor or 1.0),
                warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        })
    end

    function c.pos() return world.pedPos end

    return c
end

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }

-- ======================================================================
-- THE FLOOR IS REALLY THERE
-- ======================================================================

t.test('DEFECT: entering the skydome builds a floor and stands the player on it', function()
    -- THE WHOLE FEATURE, in one assertion. Nothing below matters if this
    -- fails, and this is what "the skydome does not work at all" was.
    local c = newClient()
    c.enter('skydome')

    t.isTrue(#c.world.live() > 0, 'the arena built nothing at all')

    local surface, piece = c.world.surfaceUnder(c.pos().x, c.pos().y)
    t.isNotNil(surface, 'the player is standing over open air -- there is no piece under them')
    t.isNotNil(piece)

    -- Standing ON it, not inside it and not hovering above it.
    t.isTrue(math.abs(c.pos().z - surface) < 0.5,
        ('the player is at %0.2f and the floor under them is at %0.2f'):format(c.pos().z, surface))
end)

t.test('DEFECT: and the ground probe does not drag them out of the sky', function()
    -- GetGroundZFor_3dCoord searches DOWNWARD for terrain and this world has
    -- real terrain at 30. An arena that forgets it is exact gets every
    -- fighter teleported a kilometre down, and both halves report success.
    local c = newClient()
    c.enter('skydome')
    t.isTrue(c.pos().z > 1000.0,
        ('the player ended the entry at z=%0.1f -- that is the map, not the arena'):format(c.pos().z))
end)

t.test('DEFECT: the cover stands ON the floor, not buried inside it', function()
    -- The surface used to be "config Z plus however tall the prop is", while
    -- cover was positioned from the spawn centre in config. With a ten-metre
    -- block that put every barrier ten metres under the floor: invisible,
    -- unusable, and impossible to see from the ground.
    local c = newClient()
    c.enter('skydome')

    local floorModels = {}
    for _, model in ipairs(c.Arena.GetPlatform('skydome').models) do floorModels[model] = true end

    local cover, buried, unsupported = 0, 0, 0
    for _, object in ipairs(c.world.live()) do
        if not floorModels[object.model] then
            cover = cover + 1
            -- The FLOOR under this piece, not whatever is standing on it --
            -- a barrier is its own tallest thing, and asking without the
            -- filter makes every piece look buried under itself.
            local surface = c.world.surfaceUnder(object.x, object.y, floorModels)
            if not surface then
                unsupported = unsupported + 1
            elseif object.z < surface - 0.75 then
                buried = buried + 1
            end
        end
    end

    t.isTrue(cover > 0, 'no cover was built at all')
    t.equals(buried, 0, ('%d of %d cover pieces are underneath the floor'):format(buried, cover))
    t.equals(unsupported, 0,
        ('%d of %d cover pieces are standing over open air'):format(unsupported, cover))
end)

t.test('DEFECT: every spawn the arena can hand out has a piece under it', function()
    -- Not just the one this test drew. A floor with a hole in it is a hole
    -- somebody eventually spawns over, and the fall is a kilometre.
    local c = newClient()
    c.enter('skydome')

    local area = c.Arena.GetSpawnArea('skydome')
    local holes = {}
    for ring = 0, math.floor(area.radius) do
        for step = 0, 23 do
            local angle = (step / 24) * math.pi * 2
            local x = area.x + ring * math.cos(angle)
            local y = area.y + ring * math.sin(angle)
            if not c.world.surfaceUnder(x, y) then
                holes[#holes + 1] = ('%0.1f,%0.1f'):format(x - area.x, y - area.y)
            end
        end
    end
    t.equals(#holes, 0, ('%d points inside the spawn area have no floor under them, e.g. %s')
        :format(#holes, holes[1] or ''))
end)

t.test('and the floor is one flat layer, at exactly the height config names', function()
    -- The surface is a promise config makes: `platform.z` is where people
    -- stand, and every other number in the arena -- spawn Z, cover Z, the
    -- boundary centre -- is written against it. A floor laid at "whatever
    -- that prop's height works out to" keeps none of them.
    --
    -- The floor layer is the LOWEST one: cover stands on top of it, and the
    -- two can be the same model, so height is what separates them rather
    -- than the name.
    local c = newClient()
    c.enter('skydome')

    local platform = c.Arena.GetPlatform('skydome')
    local floorModels = {}
    for _, model in ipairs(platform.models) do floorModels[model] = true end

    local lowest = nil
    for _, object in ipairs(c.world.live()) do
        if floorModels[object.model] then
            lowest = math.min(lowest or object.z, object.z)
        end
    end
    t.isNotNil(lowest, 'no floor was built')

    local tiles, tops = 0, {}
    for _, object in ipairs(c.world.live()) do
        if floorModels[object.model] and math.abs(object.z - lowest) < 0.001 then
            tiles = tiles + 1
            local size = c.world.models[object.model]
            tops[('%0.3f'):format(object.z + size.top)] = true
        end
    end

    t.isTrue(tiles > 1, ('the floor is %d piece(s)'):format(tiles))

    local distinct = 0
    for _ in pairs(tops) do distinct = distinct + 1 end
    t.equals(distinct, 1, 'the floor is a staircase -- its pieces have different tops')
    t.isTrue(tops[('%0.3f'):format(platform.z)] == true,
        ('the floor surface is not at the configured %0.2f'):format(platform.z))
end)

-- ======================================================================
-- THE ORDER: THE FLOOR IS BUILT WHERE THE PLAYER IS
-- ======================================================================

t.test('DEFECT: the floor is built around the player, not across the map', function()
    -- THE BUG THAT MADE THE ARENA DO NOTHING AT ALL.
    --
    -- CreateObject builds into the streamed world, and the streamed world is
    -- the bubble around the player. Building the floor while the player is
    -- still standing in the city asks the engine for scenery in a part of
    -- the map it is not holding.
    --
    -- The player starts in the city here, exactly as they do in production:
    -- if the client does not move them to the arena first, every CreateObject
    -- is refused and nothing is built.
    local c = newClient({ start = { x = -282.0, y = -2030.0, z = 30.1 } })
    t.isTrue(math.abs(c.pos().x - SKY.x) > 1000.0, 'the player did not start away from the arena')

    c.enter('skydome')

    t.equals(#c.world.refused, 0,
        ('%d pieces were refused for being outside the streamed world'):format(#c.world.refused))
    t.isTrue(#c.world.live() > 0, 'nothing was built')
end)

t.test('and a floor that cannot be built takes the player back out', function()
    -- The one case where refusing to place somebody is the kind outcome:
    -- there is a kilometre of air under them. What must NOT happen is the
    -- old behaviour -- the handler returns, the client says nothing, and the
    -- server keeps a fighter in a match it has already started.
    --
    -- A build with none of the floor models is how that is provoked, which
    -- is also the real-world case: an operator who has stripped their game
    -- assets.
    local c = newClient({ models = {
        prop_mp_barrier_02b = { x = 3.0, y = 0.4, top = 1.1 },
    } })
    c.enter('skydome')

    t.equals(#c.world.liveOf('stt_prop_stunt_bblock_huge_01'), 0)

    local home = c.env.Config.Lobby.returnCoords
    t.isTrue(math.abs(c.pos().z - home.z) < 1.0,
        ('the player was left at z=%0.1f rather than back at the lobby'):format(c.pos().z))
    t.isTrue(not c.world.frozen, 'the player was left frozen')

    local told = false
    for _, event in ipairs(c.serverEvents) do
        if event.name == 'crimson_arena:server:leaveMatch' then told = true end
    end
    t.isTrue(told, 'the server was never told this client could not be placed')
end)

-- ======================================================================
-- THE FALLBACK CHAIN, EXERCISED RATHER THAN ASSUMED
-- ======================================================================

t.test('a build without the stunt blocks falls back and still has no holes', function()
    -- The fallback is the name nobody looks at, right up to the day the
    -- primary is missing and it is all that stands between a round and a
    -- kilometre of air. So it is run, not read.
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    models.stt_prop_stunt_bblock_huge_01 = nil
    models.bkr_prop_biker_bblock_huge_01 = nil
    models.imp_prop_impexp_bblock_huge_01 = nil
    models.ar_prop_ar_bblock_huge_01 = nil

    local c = newClient({ models = models })
    c.enter('skydome')

    -- It came down to the base-game container, which is long and thin -- the
    -- shape that used to be tiled on its longest side and left gaps.
    t.isTrue(#c.world.liveOf('prop_container_01a') > 0, 'the chain did not reach the container')

    local area = c.Arena.GetSpawnArea('skydome')
    local holes = 0
    for ring = 0, math.floor(area.radius) do
        for step = 0, 23 do
            local angle = (step / 24) * math.pi * 2
            if not c.world.surfaceUnder(area.x + ring * math.cos(angle),
                                        area.y + ring * math.sin(angle)) then
                holes = holes + 1
            end
        end
    end
    t.equals(holes, 0, ('the container floor has %d holes in it'):format(holes))

    local surface = c.world.surfaceUnder(c.pos().x, c.pos().y)
    t.isNotNil(surface)
    t.isTrue(math.abs(c.pos().z - surface) < 0.5, 'the player is not standing on the fallback floor')
end)

t.test('and the piece count stays under the ceiling config sets', function()
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    for _, name in ipairs({ 'stt_prop_stunt_bblock_huge_01', 'bkr_prop_biker_bblock_huge_01',
                            'imp_prop_impexp_bblock_huge_01', 'ar_prop_ar_bblock_huge_01' }) do
        models[name] = nil
    end

    local c = newClient({ models = models })
    c.enter('skydome')

    local cap = c.Arena.GetPlatform('skydome').maxTiles
    t.isTrue(cap > 0, 'the shipped arena sets no ceiling on the container fallback')
    local floor = #c.world.liveOf('prop_container_01a')
    t.isTrue(floor <= cap, ('%d floor pieces against a ceiling of %d'):format(floor, cap))
end)

-- ======================================================================
-- TIDYING UP
-- ======================================================================

t.test('leaving takes every piece down again', function()
    -- A prop nobody deletes stands at a thousand metres for the rest of the
    -- session, in an instance nobody can reach to look at it.
    local c = newClient()
    c.enter('skydome')
    t.isTrue(#c.world.live() > 0)

    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, ('%d pieces were left standing'):format(#c.world.live()))
end)

t.test('and entering a second match does not stack a second floor on the first', function()
    local c = newClient()
    c.enter('skydome')
    local first = #c.world.live()

    c.fire('crimson_arena:client:exitArena', {})
    c.enter('skydome')

    t.equals(#c.world.live(), first,
        'the second round built on top of the first rather than replacing it')
end)

t.test('DEFECT: a round that ends mid-build leaves nothing standing at a thousand metres', function()
    -- THE WINDOW THE BUILD ORDER OPENED. Building the floor before placing
    -- the fighter is what makes the sky arena work at all -- but the build
    -- YIELDS, on every model it loads, and a round can end inside that.
    --
    -- leaveArena runs in the window and takes the props down. Its
    -- removeArenaProps finds the ones built SO FAR; the rest are created a
    -- moment later, into an arena nobody is in. And leaveArena will not run
    -- again -- it returns immediately for a match that has already gone --
    -- so those pieces stand at a thousand metres for the rest of the
    -- session, in an instance no one can reach to look at them.
    --
    -- Invisible from every angle: the player is home, their gear is back,
    -- and nothing is on screen. Only the object count knows.
    -- STREAMING IS TAKEN OUT OF THE PICTURE FOR THIS ONE, deliberately. The
    -- world model refuses a CreateObject beyond its stream range, and the
    -- exit teleports the player home -- so with the ordinary range every
    -- piece after the interrupt would fail to build and the arena would look
    -- clean whether the guard is there or not. That is the model hiding the
    -- defect, not the code avoiding it: the real engine is more permissive
    -- than this model, which is exactly where the pieces would be created.
    local c = newClient({ streamRange = 100000.0 })

    -- Part-way through, not on the first load: the first is the measurement
    -- pass and no piece exists yet, so an exit there leaks nothing.
    c.interruptAfter = 3
    c.duringBuild = function()
        c.fire('crimson_arena:client:exitArena', {})
    end

    c.enter('skydome')

    t.equals(#c.world.live(), 0,
        ('%d pieces were left standing after a round that ended mid-build')
            :format(#c.world.live()))
end)

t.test('and the fighter is not placed into an arena the round has left', function()
    -- The other half of the same window, and the reason the guard is asked
    -- again rather than only cleaned up after: a player already sent home,
    -- with their own gear back, must not be teleported to an arena spawn.
    local c = newClient({ streamRange = 100000.0 })
    c.interruptAfter = 3
    c.duringBuild = function()
        c.fire('crimson_arena:client:exitArena', {})
    end

    c.enter('skydome')

    local home = c.env.Config.Lobby.returnCoords
    t.isTrue(math.abs(c.pos().z - home.z) < 1.0,
        ('the player ended at z=%0.1f rather than back at the lobby'):format(c.pos().z))
end)

-- ======================================================================
-- TWO MATCHES AT ONCE
-- ======================================================================

t.test('two clients in two matches each build their own, and neither touches the other', function()
    -- The routing bucket is what makes one set of coordinates serve every
    -- match at once, and it is server-side -- concurrent_spec proves that
    -- half. THIS half is that the scenery is per client: local objects, one
    -- set each, and one client leaving takes down only its own.
    local a = newClient()
    local b = newClient()
    a.enter('skydome')
    b.enter('skydome')

    t.isTrue(#a.world.live() > 0, 'the first client built nothing')
    t.equals(#b.world.live(), #a.world.live(), 'the second client built a different arena')

    a.fire('crimson_arena:client:exitArena', {})
    t.equals(#a.world.live(), 0)
    t.isTrue(#b.world.live() > 0,
        "one client leaving took down the other client's arena")
end)

-- ======================================================================
-- TWENTY FIGHTERS
-- ======================================================================

t.test('a twenty-player match builds a bigger floor, and every spawn is on it', function()
    -- THE REQUIREMENT, run rather than calculated. skyarena_spec proves the
    -- spawns are far enough apart; this proves there is a floor under all
    -- twenty of them once the client has actually built one.
    local roster = {}
    for id = 1, 20 do roster[#roster + 1] = { src = id } end

    local sizing = newClient()
    local factor = sizing.Arena.SizeFactor('skydome', 20)
    t.isTrue(factor > 1.2, ('twenty players grew the arena by only %0.2f'):format(factor))

    local plan = sizing.Arena.PlanSpawns('skydome', roster, nil, factor)
    t.isNotNil(plan)

    -- One client, entering at each of the twenty planned points in turn.
    -- The floor it builds is the same floor every one of them gets, so this
    -- is the same question asked twenty times.
    for src, point in pairs(plan) do
        local c = newClient()
        c.enter('skydome', { x = point.x, y = point.y, z = point.z, w = point.w or 0.0 }, factor)

        local surface = c.world.surfaceUnder(c.pos().x, c.pos().y)
        t.isNotNil(surface, ('fighter %d is standing over open air'):format(src))
        t.isTrue(math.abs(c.pos().z - (surface or 0)) < 0.5,
            ('fighter %d is not standing on the floor'):format(src))
    end
end)

t.test('and the grown floor really is bigger than the ungrown one', function()
    -- The growth has to reach the props. A factor that stopped at the spawn
    -- planner would put the twentieth fighter off the edge of a floor built
    -- for six -- which is the failure this whole feature exists to stop, and
    -- it looks identical to it working right up until somebody falls.
    local small = newClient()
    small.enter('skydome', nil, 1.0)
    local large = newClient()
    large.enter('skydome', nil, large.Arena.SizeFactor('skydome', 20))

    t.isTrue(#large.world.live() > #small.world.live(),
        ('the arena for twenty built %d pieces against %d for six')
            :format(#large.world.live(), #small.world.live()))

    -- And it reaches further out. Measured rather than assumed: the tiles
    -- deliberately overhang the configured radius (coverage beats tidiness,
    -- see PlatformTiles), so how far a floor actually reaches is a question
    -- for the floor, not for the number it was built from.
    local area = small.Arena.GetSpawnArea('skydome', 1.0)
    local function reach(client)
        local furthest = 0.0
        for step = 1, 400 do
            if client.world.surfaceUnder(area.x + step * 0.5, area.y) then
                furthest = step * 0.5
            end
        end
        return furthest
    end

    local near, far = reach(small), reach(large)
    t.isTrue(far > near + 5.0,
        ('the arena for twenty reaches %0.1fm against %0.1fm for six'):format(far, near))
end)

-- ======================================================================
-- THE RESPAWN LANDS WHERE IT WAS SENT
-- ======================================================================

t.test('DEFECT: the client respawns on the point the server chose, not near it', function()
    -- The server picks a respawn to be as far from the nearest live opponent
    -- as the area allows and clear of the cover, then sends `scatterRadius`
    -- to say so. This side was reading Config.Match.spawnScatterRadius
    -- instead, so the field was decorative and every carefully chosen point
    -- was nudged a couple of metres off -- which on an arena with barriers is
    -- how somebody comes back inside one.
    local c = newClient()
    c.enter('skydome')

    local point = { x = SKY.x + 10.0, y = SKY.y - 6.0, z = SKY.z, w = 0.0 }
    c.fire('crimson_arena:client:respawn', {
        spawn = point, scatterRadius = 0.0, loadout = { weapons = {} },
    })

    t.isTrue(math.abs(c.pos().x - point.x) < 0.01 and math.abs(c.pos().y - point.y) < 0.01,
        ('sent to %0.2f,%0.2f and landed at %0.2f,%0.2f')
            :format(point.x, point.y, c.pos().x, c.pos().y))

    -- And still on the floor, which is the other half of a respawn in the sky.
    local surface = c.world.surfaceUnder(c.pos().x, c.pos().y)
    t.isNotNil(surface, 'the respawn put the player over open air')
    t.isTrue(math.abs(c.pos().z - surface) < 0.5, 'the respawn did not land on the floor')
end)

t.test('and it still scatters when the server asks for one', function()
    -- The condition has to work both ways: a round-robin point list needs
    -- the scatter or twenty players land in four piles.
    local c = newClient()
    c.enter('skydome')

    local point = { x = SKY.x, y = SKY.y, z = SKY.z, w = 0.0 }
    local moved = false
    for _ = 1, 8 do
        c.fire('crimson_arena:client:respawn', {
            spawn = point, scatterRadius = 20.0, loadout = { weapons = {} },
        })
        if math.abs(c.pos().x - point.x) > 0.5 or math.abs(c.pos().y - point.y) > 0.5 then
            moved = true
        end
    end
    t.isTrue(moved, 'a scatter radius the server asked for was ignored')
end)

-- ======================================================================
-- THE ARENA ON THE GROUND
-- ======================================================================

t.test('the trailer park builds nothing and stands the player on the map', function()
    -- It is a real place. There is already a floor, and an arena that
    -- spawned one would be putting a platform through the ground.
    local c = newClient()
    c.enter('trailerpark')

    t.equals(#c.world.live(), 0, 'an arena on the map built scenery it does not need')
    -- The ground probe, which is the right answer here and the wrong one in
    -- the sky: the world's terrain is at 30.
    t.isTrue(math.abs(c.pos().z - 30.0) < 1.0,
        ('the player ended up at z=%0.1f rather than on the ground'):format(c.pos().z))
end)

t.test('and its cover block still works if an operator switches it on', function()
    -- Shipped off because fixed offsets know nothing about the caravans
    -- already standing there -- but it is a real, laid-out block, not a
    -- comment, so it has to build when asked.
    local c = newClient({ cover = { 'trailerpark' } })
    c.enter('trailerpark')

    t.isTrue(#c.world.live() > 0, 'the cover block did nothing when switched on')
    t.equals(#c.world.refused, 0, 'cover was built before the player got there')

    -- Still on the ground: cover does not make this a platform arena.
    t.isTrue(math.abs(c.pos().z - 30.0) < 1.0, 'switching cover on moved the spawn height')

    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, 'ground cover was left standing after the match')
end)

os.exit(t.summary())
