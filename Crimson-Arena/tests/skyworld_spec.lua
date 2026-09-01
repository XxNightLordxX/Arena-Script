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
    local c = { world = world, serverEvents = {}, notifications = {}, notified = {}, printed = {} }

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

        -- WHAT THE OPERATOR SEES IN F8. Several of this file's guarantees are
        -- a console line and nothing else -- a floor that did not build, a
        -- model that fell back, a floor that reaches outside its own arena --
        -- and a line nobody can read is the same as no line at all.
        print = function(line) c.printed[#c.printed + 1] = tostring(line) end,

        lib = { notify = function(payload) c.notified[#c.notified + 1] = payload end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end

    -- A CLOCK, NOT A COUNTER. The world's own GetGameTimer just increments,
    -- which is enough to stop a load loop spinning forever but useless to
    -- anything that measures a DURATION -- and the boundary's warning grace
    -- is a duration. Wired to the thread runner instead, so Wait(500)
    -- advances the clock by 500ms exactly as it does in the game, and five
    -- seconds of grace really is ten ticks of a 500ms loop.
    overrides.GetGameTimer = function() return runner.elapsed end

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
    c.runner = runner

    --- Promotes the round to live, which is what starts the boundary and
    --- blip loops -- they deliberately do nothing during the countdown.
    function c.goLive()
        c.fire('crimson_arena:client:matchLive')
    end

    --- Runs the loops `times` times. The thread runner resumes each captured
    --- thread once per step, and the boundary loop is one Wait per pass.
    function c.tick(times)
        for _ = 1, (times or 1) do runner.step() end
    end

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

    --- Everything this client has printed, as one string.
    function c.console() return table.concat(c.printed, '\n') end

    return c
end

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }

--- How far above the surface a fighter is held while the countdown runs.
---
--- NOT ZERO, and that is the fix for spawning inside the platform. A ped
--- placed at exactly the floor height has its origin inside the prop it is
--- meant to be standing on, and drops straight through. It is held clear and
--- released onto the floor when the freeze ends.
--- @param client table
--- @return number
local function standOffset(client)
    return tonumber(client.env.Config.Match.spawnHeightOffset) or 1.0
end

--- Is this fighter standing on the arena surface -- held exactly the hold
--- above it, never inside it and never anywhere else?
---
--- EXACTLY, not within a tolerance. The first version of this allowed
--- anything from the surface up to the hold, which quietly accepted a
--- placement that had lost the lift as well as one that had it -- and since
--- the bound was read from the same setting the code reads, raising
--- spawnHeightOffset raised the assertion with it and the test could not
--- fail on height at all. The offset is arithmetic, so it is asserted as
--- arithmetic; `the hold is a sane height` below is what stops the setting
--- and the assertion sliding together.
--- @param client table
--- @param surface number
--- @return boolean
local function standingOn(client, surface)
    local z = client.pos().z
    return math.abs(z - (surface + standOffset(client))) < 0.01
end

--- Is there a piece of the FLOOR under this point?
---
--- BY LAYER, NOT BY MODEL NAME, and that distinction is forced: the shipped
--- arena's floor chain and its cover chain both end at the same shipping
--- container, so a name tells you nothing about which one a piece is. The
--- floor is the lowest layer -- everything else stands on it.
--- @param client table
--- @param x number
--- @param y number
--- @return boolean
local function onFloor(client, x, y)
    local lowest
    for _, object in ipairs(client.world.live()) do
        lowest = math.min(lowest or object.z, object.z)
    end
    if not lowest then return false end

    for _, object in ipairs(client.world.live()) do
        if math.abs(object.z - lowest) < 0.001 then
            local size = client.world.models[object.model]
            if size
                and math.abs(x - object.x) <= size.x * 0.5 + 1e-6
                and math.abs(y - object.y) <= size.y * 0.5 + 1e-6 then
                return true
            end
        end
    end
    return false
end


-- ======================================================================
-- THE FLOOR IS REALLY THERE
-- ======================================================================

t.test('DEFECT: a floor that sticks out of the arena says so in F8', function()
    -- ValidateConfig asks this at start-up and can only answer it for
    -- platform.tileSize -- the size the client falls back to when it cannot
    -- measure the model. The real prop is usually bigger, so the client is
    -- the only place both numbers exist at once. Solid ground outside the
    -- sphere is the failure that reads worst from a player's seat: you walk
    -- to the edge of a platform you are still standing on and start bleeding.
    local c = newClient()
    c.env.Config.Arenas.skydome.boundary.radius = 20.0
    c.enter('skydome')

    t.contains(c.console(), 'THE FLOOR REACHES OUTSIDE THE ARENA',
        'a floor well outside a 20m boundary was built without a word')
end)

t.test('and stays quiet when the floor is inside it, which is the shipped case', function()
    -- A warning that fires on a working arena is noise, and noise in a
    -- start-up report is how a real one gets scrolled past.
    local c = newClient()
    c.enter('skydome')
    t.notContains(c.console(), 'THE FLOOR REACHES OUTSIDE THE ARENA',
        'the shipped skydome was reported as sticking out of its own boundary')
end)

t.test('DEFECT: the ped is frozen BEFORE the world is waited for, not after', function()
    -- FROZEN IS WHAT STOPS THE FALL. A placement freezes the ped, waits for
    -- collision, and then leaves it in whatever state the caller asked for --
    -- and on entry that final state is frozen too. So the END STATE IS
    -- IDENTICAL whether the first freeze happened or not, which is why
    -- turning it into `false` survived every spec in the suite: for the
    -- frames the world takes to stream in there is nothing under the player,
    -- gravity applies, and they arrive below the map.
    --
    -- Only the ORDER tells the two apart, so the order is what is asserted.
    local c = newClient()
    c.enter('skydome')

    t.isTrue(#c.world.freezes > 0, 'the placement never froze the player at all')
    t.isTrue(c.world.freezes[1] == true,
        'the first thing done to the player was to UNfreeze them, so they fall while the world streams in')
end)

t.test('and a respawn is frozen first too', function()
    -- The respawn path is the one this originally got wrong: entry happened
    -- to freeze in its caller as well, and this one did not.
    --
    -- It is LEFT frozen on purpose, and that is not this test's business:
    -- the release is ArenaDispatch.ReleaseDeadState's, so that the single
    -- instant the player becomes a target again is one line rather than the
    -- start of a five-second wait. What matters here is that the freeze
    -- comes BEFORE the move, not after it.
    local c = newClient()
    c.enter('skydome')
    local before = #c.world.freezes

    c.fire('crimson_arena:client:respawn', {
        matchId = 'match-1',
        spawn = { x = SKY.x, y = SKY.y, z = SKY.z, w = 0.0 },
        scatterRadius = 0.0,
    })

    local during = {}
    for index = before + 1, #c.world.freezes do during[#during + 1] = c.world.freezes[index] end
    t.isTrue(#during > 0, 'a respawn never touched the freeze at all')
    t.isTrue(during[1] == true, 'a respawn moved the player before freezing them')
end)

t.test('the hold is a sane height, so nothing can slide with it', function()
    -- standingOn reads this setting, so a test that only used standingOn
    -- would agree with any value at all. This is the one assertion in the
    -- file written against a number rather than against the config, and it
    -- is here so the rest can be written against the config safely.
    --
    -- Above zero: a ped placed level with a prop has its origin inside it
    -- and falls through, which is the defect the hold exists for. Under
    -- five: it is a drop the player takes when the countdown ends, and it
    -- is also a flare visible across the arena saying where a spawn is.
    local offset = tonumber(Sandbox.newArenaEnv().Config.Match.spawnHeightOffset) or 1.0
    t.isTrue(offset > 0.0, ('spawnHeightOffset is %0.2f -- a ped placed level with the floor falls through it'):format(offset))
    t.isTrue(offset <= 5.0, ('spawnHeightOffset is %0.2f -- that is a fall, and it broadcasts the spawn'):format(offset))
end)

t.test('DEFECT: entering the skydome builds a floor and stands the player on it', function()
    -- THE WHOLE FEATURE, in one assertion. Nothing below matters if this
    -- fails, and this is what "the skydome does not work at all" was.
    local c = newClient()
    c.enter('skydome')

    t.isTrue(#c.world.live() > 0, 'the arena built nothing at all')

    local surface, piece = c.world.surfaceUnder(c.pos().x, c.pos().y)
    t.isNotNil(surface, 'the player is standing over open air -- there is no piece under them')
    t.isNotNil(piece)

    -- Above it and within the hold, never inside it. Placing a ped at
    -- exactly the floor height puts its origin in the prop and it falls
    -- through, which is what this used to do.
    t.isTrue(standingOn(c, surface),
        ('the player is at %0.2f, and the floor under them is at %0.2f (hold %0.2f)')
            :format(c.pos().z, surface, standOffset(c)))
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

-- ----------------------------------------------------------------------
-- THE WALL, AND WHICH WAY ROUND ITS PIECES ARE
--
-- A ring of containers is a WALL when every piece stands across the radius
-- and a set of SPOKES with twelve-metre gaps when they stand along it, and
-- which heading does which depends on how the model was built -- long side
-- along its own X, or along its own Y. Config cannot know that. The client
-- measures the prop for its height anyway, so it works the heading out from
-- the same measurement.
-- ----------------------------------------------------------------------

--- The wall pieces of a built skydome: everything standing on the floor,
--- outside the circle fighters are placed in.
---
--- BY HEIGHT AND NOT BY MODEL NAME. The shipping container is in both
--- chains -- it is the floor's last-resort fallback as well as what the wall
--- is built from -- so filtering the floor out by name throws the whole wall
--- away with it. The floor hangs BELOW the walkable surface, by its own
--- height, and cover stands on top of it; that is a difference no model name
--- can be wrong about.
local function wallPieces(c)
    local area = c.Arena.GetSpawnArea('skydome')
    local surface = c.Arena.GetPlatform('skydome').z

    local out = {}
    for _, object in ipairs(c.world.live()) do
        if object.z >= surface - 0.5 then
            local dx, dy = object.x - area.x, object.y - area.y
            if math.sqrt(dx * dx + dy * dy) > area.radius then
                out[#out + 1] = { object = object, dx = dx, dy = dy }
            end
        end
    end
    return out
end

--- How much of a piece's LONG side points along the radius rather than
--- across it. 0 is side-on -- a wall. 1 is end-on -- a spoke.
local function alongRadius(c, entry)
    local size = c.world.models[entry.object.model]
    local heading = math.rad(entry.object.heading or 0.0)

    -- Local +X points along (cos h, -sin h), local +Y along (sin h, cos h).
    local ax, ay
    if size.x >= size.y then
        ax, ay = math.cos(heading), -math.sin(heading)
    else
        ax, ay = math.sin(heading), math.cos(heading)
    end

    local length = math.sqrt(entry.dx * entry.dx + entry.dy * entry.dy)
    return math.abs((ax * entry.dx + ay * entry.dy) / length)
end

t.test('DEFECT: every wall piece stands ACROSS the radius, so the ring is a wall', function()
    local c = newClient()
    c.enter('skydome')

    local wall = wallPieces(c)
    t.isTrue(#wall >= 40, ('only %d pieces were built outside the spawn circle'):format(#wall))

    for _, entry in ipairs(wall) do
        t.isTrue(alongRadius(c, entry) < 0.02,
            ('a wall piece at %.1f,%.1f is turned %.1f, which points %.2f along the radius')
                :format(entry.object.x, entry.object.y, entry.object.heading, alongRadius(c, entry)))
    end
end)

t.test('and it still does on a build whose container is modelled the other way round', function()
    -- THE REASON THE HEADING IS MEASURED AND NOT WRITTEN DOWN. Same config,
    -- same headings on the page, a prop whose long side runs along its own Y
    -- instead of its X -- and the ring has to come out the same way round.
    -- Take the measurement out and this is the test that fails: every piece
    -- turns ninety degrees and the wall becomes twenty-two spokes with a
    -- twelve-metre gap between each one.
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    models.prop_container_01a = { x = 2.5, y = 12.2, top = 2.6 }
    models.prop_container_01b = { x = 2.5, y = 12.2, top = 2.6 }

    local c = newClient({ models = models })
    c.enter('skydome')

    local wall = wallPieces(c)
    t.isTrue(#wall >= 40, ('only %d pieces were built outside the spawn circle'):format(#wall))

    for _, entry in ipairs(wall) do
        t.isTrue(alongRadius(c, entry) < 0.02,
            ('with the container modelled along Y, a piece at %.1f,%.1f points %.2f along the radius')
                :format(entry.object.x, entry.object.y, alongRadius(c, entry)))
    end
end)

t.test('and the wall is two courses high everywhere, with nothing over the top', function()
    -- Two courses because one is a 2.6m step somebody vaults; nothing above
    -- them because this is a wall and not a box -- the sky is the point of
    -- the arena.
    local c = newClient()
    c.enter('skydome')

    local columns = {}
    for _, entry in ipairs(wallPieces(c)) do
        local key = ('%.1f,%.1f'):format(entry.object.x, entry.object.y)
        columns[key] = columns[key] or {}
        table.insert(columns[key], entry.object.z)
    end

    local segments = 0
    local surface = c.Arena.GetPlatform('skydome').z
    local highest = surface
    for key, heights in pairs(columns) do
        segments = segments + 1
        t.isTrue(#heights >= 2, ('wall segment %s is a single course, which is a step'):format(key))
        for _, z in ipairs(heights) do
            if z > highest then highest = z end
        end
    end

    t.isTrue(segments >= 20, ('the wall is only %d segments round'):format(segments))

    -- Two containers, and no third one over anybody's head.
    t.isTrue(highest <= surface + 6.0,
        ('something is standing %.1fm above the floor -- the sky arena has a lid on it')
            :format(highest - surface))
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

t.test('DEFECT: the floor prop is MEASURED, and a coordinate\'s type is not \'table\'', function()
    -- THE ONE THAT MADE THE ARENA LOOK BROKEN IN GAME, reported as "the
    -- props are broken it looks scuffed out i can still walk on them they
    -- just look super glitchy".
    --
    -- GetModelDimensions answers with two VECTORS, and in this runtime a
    -- vector is its own type -- `type(v)` is 'vector3', never 'table' and
    -- never 'userdata'. modelFootprint guarded on exactly those two names,
    -- so it said no to every answer the game ever gave it and returned
    -- zeros. Nothing was measured; both numbers it exists to supply fell
    -- back to a guess; and the floor was tiled on config's 10m placeholder
    -- out of a FORTY-metre block. Eighty-one pieces where the design lays
    -- nine, each overlapping its neighbours by thirty metres on both axes,
    -- every top face at the same height. Solid underfoot and impossible to
    -- look at.
    --
    -- It could not be caught here until the fixture stopped handing
    -- production plain tables, which is why sandbox.lua now marks its
    -- stand-in vectors with the type the runtime reports.
    local c = newClient()
    c.enter('skydome')

    local floor = 0
    for _, object in ipairs(c.world.live()) do
        if object.model == 'stt_prop_stunt_bblock_huge_01' then floor = floor + 1 end
    end
    t.isTrue(floor > 0, 'no floor was built at all')

    -- What the arena's own arithmetic says the floor should be, given the
    -- real measurement. Asked of Arena rather than written down, so the
    -- expectation follows the config instead of going stale beside it.
    local platform = c.env.Arena.GetPlatform('skydome')
    local planned = #c.env.Arena.PlatformTiles(platform, SKY.x, SKY.y,
        { x = 40.0, y = 40.0, top = 10.0 })
    t.equals(floor, planned,
        ('the floor came out as %d pieces where the measured plan is %d'):format(floor, planned))

    -- And nowhere near what the unmeasured fallback produces. Stated as its
    -- own assertion because the equality above passes trivially if somebody
    -- makes both sides wrong the same way.
    local guessed = #c.env.Arena.PlatformTiles(platform, SKY.x, SKY.y, nil)
    t.isTrue(guessed > floor * 4,
        ('the tileSize fallback lays %d pieces and the measurement %d -- too close for this test to mean anything')
            :format(guessed, floor))
end)

t.test('and it says the footprint it measured out loud, so F8 settles it', function()
    -- The line is gated on the measurement having happened at all, so its
    -- ABSENCE was the in-game symptom of the defect above -- and its
    -- presence is how an operator confirms the fix in ten seconds without
    -- reading any of this.
    local c = newClient()
    c.enter('skydome')

    local console = c.console()
    t.isTrue(console:find('measures', 1, true) ~= nil,
        'the arena never reported the footprint it measured')
    t.isTrue(console:find('40.00 x 40.00m', 1, true) ~= nil,
        ('the reported footprint is not the prop\'s real size:\n%s'):format(console))
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
    t.isTrue(standingOn(c, surface), 'the player is not standing on the fallback floor')
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
-- THE EDGE IS LETHAL, AND THAT IS THE BOUNDARY DOING IT
--
-- There is no falling code in this resource. Stepping off a platform a
-- kilometre up is fatal because the boundary is a SPHERE and you leave it
-- from underneath within a second. That is one loop, written the way FiveM
-- code is written -- `#(GetEntityCoords(ped) - center) > radius` -- and
-- until the world model grew real vector arithmetic it could not be run at
-- all. It is the mechanism the whole arena rests on.
-- ======================================================================

t.test('standing on the floor is inside the boundary, and nothing bleeds', function()
    local c = newClient()
    c.enter('skydome')
    c.goLive()
    c.tick(20)

    t.equals(#c.world.damage, 0,
        ('a fighter standing on the floor took %d tick(s) of boundary damage'):format(#c.world.damage))
    t.equals(#c.notified, 0, 'a fighter standing on the floor was warned about the boundary')
end)

t.test('DEFECT: and every point of the floor is inside it, not just the middle', function()
    -- The relationship that makes the arena playable rather than a bleed
    -- trap: a fighter who walks to the spawn ring must not start dying for
    -- it. Checked by MOVING the player, so the real loop answers.
    local c = newClient()
    c.enter('skydome')
    c.goLive()

    local area = c.Arena.GetSpawnArea('skydome')
    local bleeding = nil
    for step = 0, 15 do
        local angle = (step / 16) * math.pi * 2
        c.world.pedPos = {
            x = area.x + area.radius * math.cos(angle),
            y = area.y + area.radius * math.sin(angle),
            z = area.z,
        }
        c.world.damage = {}
        c.notified = {}
        c.tick(20)
        if #c.world.damage > 0 and not bleeding then
            bleeding = ('%0.1f, %0.1f'):format(c.world.pedPos.x - area.x, c.world.pedPos.y - area.y)
        end
    end
    t.isNil(bleeding, bleeding and ('the edge of the spawn ring is out of bounds at %s'):format(bleeding) or '')
end)

t.test('DEFECT: falling off the edge leaves the boundary and kills', function()
    -- THE WHOLE POINT OF PUTTING IT IN A SPHERE. Not "you fall for a long
    -- time" -- you leave the sphere from underneath and bleed, with no
    -- falling code anywhere in this resource.
    local c = newClient()
    c.enter('skydome')
    c.goLive()

    local boundary = c.env.Config.Arenas.skydome.boundary
    -- Just past the bottom of the sphere: what falling off the edge looks
    -- like about a second later.
    c.world.pedPos = { x = boundary.center.x, y = boundary.center.y, z = boundary.center.z - boundary.radius - 5.0 }

    c.tick(2)
    t.isTrue(#c.notified > 0, 'nothing warned the player they had left the arena')
    t.equals(#c.world.damage, 0, 'the warning grace was not honoured -- damage landed immediately')

    -- Past the grace period.
    c.tick(30)
    t.isTrue(#c.world.damage > 0, 'a player a hundred metres under the arena is not being bled')
end)

t.test('and walking back inside stops it, so the grace is not one-way', function()
    local c = newClient()
    c.enter('skydome')
    c.goLive()

    local area = c.Arena.GetSpawnArea('skydome')
    local boundary = c.env.Config.Arenas.skydome.boundary
    c.world.pedPos = { x = boundary.center.x, y = boundary.center.y, z = boundary.center.z - boundary.radius - 5.0 }
    c.tick(3)

    c.world.pedPos = { x = area.x, y = area.y, z = area.z }
    c.world.damage = {}
    c.tick(40)
    t.equals(#c.world.damage, 0, 'a player who came back inside is still being bled')
end)

t.test('and the boundary does not run before the round is live', function()
    -- The countdown is spent standing in the arena frozen. Bleeding somebody
    -- who cannot move yet is the failure this ordering exists to stop.
    local c = newClient()
    c.enter('skydome')

    local boundary = c.env.Config.Arenas.skydome.boundary
    c.world.pedPos = { x = boundary.center.x, y = boundary.center.y, z = boundary.center.z - boundary.radius - 50.0 }
    c.tick(40)

    t.equals(#c.world.damage, 0, 'the boundary bled a fighter during the frozen countdown')
end)

-- ======================================================================
-- DYING IN THE SKY, OVER AND OVER
-- ======================================================================

t.test('DEFECT: ten respawns in a row all land on the floor', function()
    -- One respawn proves the path works once. A match has lives, and the
    -- failure that matters is the one that only shows on the fourth death --
    -- a cursor that walks, a floor reference that goes stale, a surface that
    -- drifts.
    local c = newClient()
    c.enter('skydome')
    c.goLive()

    local surfaceZ = c.Arena.GetPlatform('skydome').z
    local area = c.Arena.GetSpawnArea('skydome')
    for life = 1, 10 do
        local angle = (life / 10) * math.pi * 2
        local point = {
            x = area.x + 20.0 * math.cos(angle),
            y = area.y + 20.0 * math.sin(angle),
            z = area.z, w = 0.0,
        }
        c.fire('crimson_arena:client:respawn', {
            spawn = point, scatterRadius = 0.0, loadout = { weapons = {} },
        })

        t.isTrue(onFloor(c, c.pos().x, c.pos().y),
            ('respawn %d put the player over open air'):format(life))
        -- ON THE SURFACE CONFIG NAMES, which is the invariant every other
        -- number in the arena is written against -- held clear of it, as
        -- every placement is.
        t.isTrue(standingOn(c, surfaceZ),
            ('respawn %d left the player at %0.2f, and the arena surface is %0.2f')
                :format(life, c.pos().z, surfaceZ))
    end
end)

t.test('and no respawn is ever placed below the arena floor, whatever it is sent', function()
    -- THE TYPO AN OPERATOR MAKES ONCE AND CANNOT DIAGNOSE. A spawn Z below
    -- the platform is not a near miss in the sky -- it is a fighter placed
    -- underneath the arena, falling, killed by the boundary a second later
    -- with nothing to say why.
    local c = newClient()
    c.enter('skydome')
    local floor = c.Arena.SpawnFloor('skydome')
    t.isNotNil(floor)

    for _, sent in ipairs({ floor - 200.0, floor - 5.0, 0.0, -50.0 }) do
        c.fire('crimson_arena:client:respawn', {
            spawn = { x = SKY.x, y = SKY.y, z = sent, w = 0.0 },
            scatterRadius = 0.0, loadout = { weapons = {} },
        })
        t.isTrue(c.pos().z >= floor - 0.001,
            ('a respawn sent to z=%0.1f left the player at %0.1f, below the floor at %0.1f')
                :format(sent, c.pos().z, floor))
    end
end)

t.test('DEFECT: and an operator who forgets exactSpawnZ is still not dropped to the terrain', function()
    -- BELT AND BRACES, and worth having. `exactSpawnZ` is what stops the
    -- downward ground search; the floor Z is what rejects an answer from
    -- below the arena. They are two separate guards and this checks the
    -- second one alone, because the first is one word in config and the
    -- consequence of losing it is every fighter teleported a kilometre down.
    local c = newClient()
    c.env.Config.Arenas.skydome.exactSpawnZ = nil
    c.enter('skydome')

    t.isTrue(c.pos().z > 1000.0,
        ('without exactSpawnZ the player ended at z=%0.1f -- the ground probe won'):format(c.pos().z))
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
-- THE ARENA AT EVERY SIZE IT CAN BE
--
-- The floor is built from a factor the server works out from the roster.
-- Testing one factor tests one arena; these walk the whole range, because a
-- floor that is right at six players and wrong at twenty is a floor that
-- fails on the night it matters.
-- ======================================================================

t.test('at every roster size the floor is built, and the player is on it', function()
    for _, players in ipairs({ 2, 6, 10, 16, 20, 28, 40, 100 }) do
        local c = newClient()
        local factor = c.Arena.SizeFactor('skydome', players)
        c.enter('skydome', nil, factor)

        t.isTrue(#c.world.live() > 0, ('%d players built nothing'):format(players))
        t.isTrue(onFloor(c, c.pos().x, c.pos().y),
            ('%d players: the fighter is over open air'):format(players))
        t.isTrue(standingOn(c, c.Arena.GetPlatform('skydome', factor).z),
            ('%d players: the fighter is not on the arena surface'):format(players))
    end
end)

t.test('DEFECT: and the whole spawn ring has floor under it at every size', function()
    -- The failure that only shows at scale: a floor that grows more slowly
    -- than the ring of spawns it has to hold. Every point the planner can
    -- return, at every factor, checked against what the client really built.
    for _, players in ipairs({ 6, 20, 40 }) do
        local c = newClient()
        local factor = c.Arena.SizeFactor('skydome', players)
        c.enter('skydome', nil, factor)

        local area = c.Arena.GetSpawnArea('skydome', factor)
        local holes = 0
        for ring = 0, math.floor(area.radius) do
            for step = 0, 23 do
                local angle = (step / 24) * math.pi * 2
                if not onFloor(c, area.x + ring * math.cos(angle), area.y + ring * math.sin(angle)) then
                    holes = holes + 1
                end
            end
        end
        t.equals(holes, 0, ('%d players: %d points in the spawn area have no floor under them')
            :format(players, holes))
    end
end)

t.test('and the boundary still contains the fighters at the largest size', function()
    -- Every radius scales by the same factor, so this should hold by
    -- construction -- which is exactly the kind of claim worth checking
    -- rather than asserting, because "by construction" is how the surface
    -- height was wrong for a week.
    local c = newClient()
    local factor = c.Arena.SizeFactor('skydome', 100)
    c.enter('skydome', nil, factor)
    c.goLive()

    local area = c.Arena.GetSpawnArea('skydome', factor)
    local bleeding = nil
    for step = 0, 15 do
        local angle = (step / 16) * math.pi * 2
        c.world.pedPos = {
            x = area.x + area.radius * math.cos(angle),
            y = area.y + area.radius * math.sin(angle),
            z = area.z,
        }
        c.world.damage = {}
        c.tick(20)
        if #c.world.damage > 0 and not bleeding then bleeding = step end
    end
    t.isNil(bleeding, 'the grown arena puts its own spawn ring out of bounds')
end)

t.test('DEFECT: the container fallback holds up at the largest size too', function()
    -- The worst case this arena has: no DLC blocks, the biggest roster, and
    -- a floor tiled out of shipping containers -- hundreds of pieces, and a
    -- piece ceiling that has to grow with the disc or the rim comes off.
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    for _, name in ipairs({ 'stt_prop_stunt_bblock_huge_01', 'bkr_prop_biker_bblock_huge_01',
                            'imp_prop_impexp_bblock_huge_01', 'ar_prop_ar_bblock_huge_01' }) do
        models[name] = nil
    end

    local c = newClient({ models = models })
    local factor = c.Arena.SizeFactor('skydome', 40)
    c.enter('skydome', nil, factor)

    local platform = c.Arena.GetPlatform('skydome', factor)
    local floor = #c.world.liveOf('prop_container_01a')
    t.isTrue(floor > 0, 'the chain never reached the container at scale')
    t.isTrue(floor <= platform.maxTiles,
        ('%d floor pieces against a ceiling of %d'):format(floor, platform.maxTiles))

    local area = c.Arena.GetSpawnArea('skydome', factor)
    local holes = 0
    for ring = 0, math.floor(area.radius) do
        for step = 0, 23 do
            local angle = (step / 24) * math.pi * 2
            if not onFloor(c, area.x + ring * math.cos(angle), area.y + ring * math.sin(angle)) then
                holes = holes + 1
            end
        end
    end
    t.equals(holes, 0, ('the grown container floor has %d holes in it'):format(holes))
end)

-- ======================================================================
-- NOTHING IS LEFT BEHIND, ON ANY EXIT
-- ======================================================================

t.test('DEFECT: stopping the resource mid-round takes the arena down with it', function()
    -- A restart is the most common thing an operator does, and it is the one
    -- exit path that does not go through the server. Props left by it stand
    -- at a thousand metres until the client reconnects.
    local c = newClient()
    c.enter('skydome')
    t.isTrue(#c.world.live() > 0)

    c.fire('onResourceStop', 'crimson_arena')

    t.equals(#c.world.live(), 0,
        ('%d pieces survived the resource stopping'):format(#c.world.live()))
end)

t.test('and stopping a DIFFERENT resource leaves the arena alone', function()
    -- The handler is fired for every resource that stops. Reacting to
    -- somebody else's restart would tear the floor out from under a live
    -- round.
    local c = newClient()
    c.enter('skydome')
    local before = #c.world.live()

    c.fire('onResourceStop', 'some_other_resource')

    t.equals(#c.world.live(), before,
        "another resource stopping took down this arena's floor")
end)

t.test('and a round that ends during the countdown cleans up too', function()
    -- Before matchLive, which is a different code path to a round that ends
    -- after it: no boundary thread, no blip thread, and the player still
    -- frozen where entry left them.
    local c = newClient()
    c.enter('skydome')
    t.isTrue(#c.world.live() > 0)

    c.fire('crimson_arena:client:exitArena', {})

    t.equals(#c.world.live(), 0, 'a round cancelled during the countdown left its floor standing')
    local home = c.env.Config.Lobby.returnCoords
    t.isTrue(math.abs(c.pos().z - home.z) < 1.0, 'the player was not taken home')
    t.isTrue(not c.world.frozen, 'the player was left frozen')
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
        t.isTrue(standingOn(c, surface or 0),
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
    t.isTrue(standingOn(c, surface), 'the respawn did not land on the floor')
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
-- THE CLIENT HALF OF "DOES EDITING THE CONFIG WORK"
--
-- configeffect_spec asks that question of everything observable from the
-- server -- the snapshot the panel is drawn from, and the payload a client
-- is sent. It cannot ask it of the settings whose only effect is geometry a
-- client BUILDS, because that needs a modelled game. Those live here.
--
-- Same shape: change one value, run the same scenario, require the result to
-- move. Not what it should become -- that would be a second copy of the
-- implementation agreeing with itself. Just that something noticed.
-- ======================================================================

--- Enters the sky arena on a config with one thing changed, and reports what
--- the world looks like afterwards.
--- @param mutate fun(config: table)?
--- @return table observation
local function afterEntering(mutate)
    local c = newClient()
    if mutate then mutate(c.env.Config) end
    c.enter('skydome')

    local lowest, models, places = nil, {}, {}
    for _, object in ipairs(c.world.live()) do
        lowest = math.min(lowest or object.z, object.z)
        models[object.model] = (models[object.model] or 0) + 1
        -- POSITIONS TOO, not just a count. Moving a piece changes neither
        -- the number of objects nor the set of models, so an observation
        -- built from those alone reports "dead setting" for every edit that
        -- only moves something -- which is most of what an operator does to
        -- a cover layout.
        places[#places + 1] = ('%0.2f/%0.2f/%0.2f'):format(object.x, object.y, object.z)
    end
    table.sort(places)

    return {
        pieces = #c.world.live(),
        models = models,
        places = table.concat(places, ' '),
        floorZ = lowest,
        standingAt = ('%0.3f'):format(c.pos().z),
        client = c,
    }
end

--- @param observation table
--- @return string
local function shape(observation)
    local names = {}
    for model, count in pairs(observation.models) do
        names[#names + 1] = ('%s=%d'):format(model, count)
    end
    table.sort(names)
    return ('pieces=%d floor=%s standing=%s models=[%s] at=[%s]')
        :format(observation.pieces, tostring(observation.floorZ), observation.standingAt,
                table.concat(names, ','), observation.places)
end

t.test('the arena settings a CLIENT builds from all reach it', function()
    local baseline = shape(afterEntering())

    local cases = {
        {
            'Config.Arenas.skydome.platform.z',
            function(config) config.Arenas.skydome.platform.z = 900.0 end,
        },
        {
            'Config.Arenas.skydome.platform.radius',
            function(config) config.Arenas.skydome.platform.radius = 20.0 end,
        },
        {
            'Config.Arenas.skydome.platform.models',
            function(config)
                config.Arenas.skydome.platform.models = { 'prop_container_01a' }
            end,
        },
        {
            'Config.Arenas.skydome.platform.maxTiles',
            function(config)
                config.Arenas.skydome.platform.models = { 'prop_container_01a' }
                config.Arenas.skydome.platform.maxTiles = 12
            end,
        },
        {
            'Config.Arenas.skydome.cover.enabled',
            function(config) config.Arenas.skydome.cover.enabled = false end,
        },
        {
            'deleting a cover piece',
            function(config) table.remove(config.Arenas.skydome.cover.pieces) end,
        },
        {
            'moving a cover piece',
            function(config) config.Arenas.skydome.cover.pieces[1].x = 40.0 end,
        },
    }

    for _, case in ipairs(cases) do
        t.isTrue(shape(afterEntering(case[2])) ~= baseline,
            ('%s changes nothing the client builds -- it is a dead setting'):format(case[1]))
    end
end)

t.test('and the FLOOR really lands where platform.z says, at any value', function()
    -- Not just "it moved". This is the one client-side setting with an exact
    -- promise attached, and the promise is about the FLOOR: whatever prop
    -- turns up, its top ends at this height.
    --
    -- It is deliberately NOT a promise about where the fighter stands. The
    -- spawn Z decides that, floored at the surface -- so a spawn point above
    -- the floor is honoured rather than dragged down to it, which is what an
    -- operator asking for a raised platform spawn would expect. The floor is
    -- the minimum, not the answer.
    for _, height in ipairs({ 300.0, 900.0, 1201.0, 1800.0 }) do
        local c = newClient()
        c.env.Config.Arenas.skydome.platform.z = height
        c.enter('skydome')

        local platform = c.Arena.GetPlatform('skydome')
        local lowest
        for _, object in ipairs(c.world.live()) do
            lowest = math.min(lowest or object.z, object.z)
        end
        t.isNotNil(lowest, ('platform.z = %0.1f built no floor at all'):format(height))

        -- The top of the lowest layer is the walkable surface.
        local surface
        for _, object in ipairs(c.world.live()) do
            if math.abs(object.z - lowest) < 0.001 then
                surface = object.z + c.world.models[object.model].top
                break
            end
        end
        t.isTrue(math.abs(surface - platform.z) < 0.001,
            ('platform.z = %0.1f put the walkable surface at %0.2f'):format(height, surface or 0))
    end
end)

t.test('and returnCoords is where a player really ends up', function()
    -- The lobby half. Read off the world rather than the payload, because
    -- this is the one the player experiences.
    local c = newClient()
    c.env.Config.Lobby.returnCoords = { x = 111.0, y = 222.0, z = 333.0, w = 90.0 }
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})

    t.isTrue(math.abs(c.pos().x - 111.0) < 0.01 and math.abs(c.pos().z - 333.0) < 0.01,
        ('the player was sent to %0.1f, %0.1f, %0.1f instead of the configured lobby')
            :format(c.pos().x, c.pos().y, c.pos().z))
end)

-- ======================================================================
-- EVENT ORDERS NOBODY DESIGNED FOR
--
-- Every test above fires events in the order a healthy round produces them.
-- Production does not always oblige: a player disconnects during a
-- countdown, a match is cancelled while somebody is still loading models, a
-- resource is restarted mid-round, two entries race because the server
-- retried. Those orderings are where a state machine leaks -- and this one
-- holds a floor made of objects that outlive the script if nobody deletes
-- them.
--
-- So the order is generated instead of chosen. Seeded, so a failure names a
-- seed that reproduces it exactly.
-- ======================================================================

--- Every event the client takes, as things a fuzz run can throw at it.
--- @param c table
--- @return table<string, fun()>
local function eventMenu(c)
    local area = c.Arena.GetSpawnArea('skydome')
    local spawn = { x = area.x, y = area.y, z = area.z, w = 0.0 }

    return {
        enter = function() c.enter('skydome') end,
        enterGrown = function() c.enter('skydome', nil, c.Arena.SizeFactor('skydome', 20)) end,
        enterGround = function() c.enter('trailerpark') end,
        live = function() c.fire('crimson_arena:client:matchLive') end,
        respawn = function()
            c.fire('crimson_arena:client:respawn', {
                spawn = spawn, scatterRadius = 0.0, loadout = { weapons = {} },
            })
        end,
        hud = function()
            c.fire('crimson_arena:client:matchHud', {
                visible = true,
                scoreboard = { { id = 1, name = 'You', alive = true, team = 'crimson' } },
            })
        end,
        exit = function() c.fire('crimson_arena:client:exitArena', {}) end,
        stop = function() c.fire('onResourceStop', 'crimson_arena') end,
        otherStop = function() c.fire('onResourceStop', 'some_other_resource') end,
    }
end

t.test('FUZZ: no ordering of events ever leaves scenery behind', function()
    -- THE LEAK THAT NOBODY SEES. Props are client-side local objects a
    -- kilometre up, in an instance no one can reach to look at. A player
    -- whose round ended badly is home, holding their own gear, with nothing
    -- on screen -- and a hundred pieces still standing. Only the object
    -- count knows.
    --
    -- The invariant is not "zero at the end" -- a run may legitimately end
    -- mid-round. It is that the count never exceeds ONE arena's worth, and
    -- that it IS zero once the round is over by any route.
    local clean = newClient()
    clean.enter('skydome')
    local oneArena = #clean.world.live()
    t.isTrue(oneArena > 0, 'a clean entry built nothing, so this proves nothing')

    local grown = newClient()
    grown.enter('skydome', nil, grown.Arena.SizeFactor('skydome', 20))
    local biggest = math.max(oneArena, #grown.world.live())

    local names = { 'enter', 'enterGrown', 'enterGround', 'live', 'respawn',
                    'hud', 'exit', 'stop', 'otherStop' }

    local failures = {}
    for seed = 1, 120 do
        math.randomseed(seed + 777)

        local c = newClient()
        local menu = eventMenu(c)
        local order = {}

        for _ = 1, 8 do
            local pick = names[math.random(#names)]
            order[#order + 1] = pick
            menu[pick]()

            local standing = #c.world.live()
            if standing > biggest and #failures == 0 then
                failures[#failures + 1] = ('seed %d after [%s]: %d pieces, more than one arena (%d)')
                    :format(seed, table.concat(order, ' '), standing, biggest)
            end
        end

        -- However it went, ending the round has to leave nothing.
        menu.exit()
        if #c.world.live() ~= 0 and #failures == 0 then
            failures[#failures + 1] = ('seed %d after [%s] then exit: %d pieces left standing')
                :format(seed, table.concat(order, ' '), #c.world.live())
        end
    end

    t.equals(#failures, 0, failures[1] or '')
end)

t.test('FUZZ: and never leaves the player frozen somewhere they cannot get out of', function()
    -- The other way a bad ordering ruins a session, and the one the player
    -- actually feels: frozen, in an arena that no longer exists, with no
    -- round to end and nothing to press. leaveArena is the single path that
    -- releases them, so every route out has to reach it.
    local names = { 'enter', 'enterGrown', 'enterGround', 'live', 'respawn',
                    'hud', 'exit', 'stop', 'otherStop' }

    local stuck = nil
    for seed = 1, 120 do
        math.randomseed(seed + 555)

        local c = newClient()
        local menu = eventMenu(c)
        local order = {}

        for _ = 1, 8 do
            local pick = names[math.random(#names)]
            order[#order + 1] = pick
            menu[pick]()
        end

        -- The round ends, by the route the server really uses.
        menu.exit()

        if c.world.frozen and not stuck then
            stuck = ('seed %d after [%s] then exit: the player is still frozen')
                :format(seed, table.concat(order, ' '))
        end

        local home = c.env.Config.Lobby.returnCoords
        if math.abs(c.pos().z - home.z) > 1.0 and not stuck then
            stuck = ('seed %d after [%s] then exit: the player is at z=%0.1f, not the lobby')
                :format(seed, table.concat(order, ' '), c.pos().z)
        end
    end

    t.isNil(stuck, stuck or '')
end)

t.test('FUZZ: and a player in the sky is never left standing below the floor', function()
    -- The fatal direction. Above the surface is a fall onto something;
    -- below it is a fall out of the world, and the boundary finishes it a
    -- second later with nothing to say why.
    local names = { 'enter', 'enterGrown', 'live', 'respawn', 'hud', 'otherStop' }

    local sunk = nil
    for seed = 1, 150 do
        math.randomseed(seed + 999)

        local c = newClient()
        local menu = eventMenu(c)
        local floor = c.Arena.SpawnFloor('skydome')
        local order = {}

        for _ = 1, 8 do
            local pick = names[math.random(#names)]
            order[#order + 1] = pick
            menu[pick]()

            -- Only while there is an arena standing: once it is gone the
            -- player belongs at the lobby, which is far below.
            if #c.world.live() > 0 and c.pos().z < floor - 0.001 and not sunk then
                sunk = ('seed %d after [%s]: standing at %0.2f, under a floor at %0.2f')
                    :format(seed, table.concat(order, ' '), c.pos().z, floor)
            end
        end
    end

    t.isNil(sunk, sunk or '')
end)

-- ======================================================================
-- AN ARENA THE OPERATOR ADDED, BUILT FOR REAL
--
-- newarena_spec proves a pasted-in block is READ correctly -- it appears in
-- the list, it plans spawns, its slips are named. This is the other half:
-- that the client actually BUILDS one it has never seen, at coordinates and
-- a height nothing in the shipped config uses.
-- ======================================================================

--- A sky arena an operator wrote, nothing like the shipped one: different
--- coordinates, a different height, a different prop, a different size.
local function pastedSkyArena()
    return {
        label = 'The Gantry',
        enabled = true,
        exactSpawnZ = true,
        platform = {
            enabled = true,
            models = { 'prop_container_01a' },
            tileSize = 10.0,
            radius = 40.0,
            z = 640.0,
            maxTiles = 500,
        },
        cover = {
            enabled = true,
            pieces = {
                { models = { 'prop_mp_barrier_02b' }, x = 12.0, y = 0.0, z = 0.0, heading = 90.0 },
                { models = { 'prop_mp_barrier_02b' }, x = -12.0, y = 0.0, z = 0.0, heading = 270.0 },
            },
        },
        spawnArea = {
            enabled = true,
            center = { x = -2200.0, y = 4400.0, z = 640.0 },
            radius = 25.0,
            minSeparation = 9.0,
            teamRadius = 12.0,
        },
        spawns = { { x = -2200.0, y = 4400.0, z = 640.0, w = 0.0 } },
        boundary = {
            enabled = true,
            center = { x = -2200.0, y = 4400.0, z = 640.0 },
            radius = 60.0,
            warningSeconds = 5, damagePerTick = 20, tickMs = 500,
        },
    }
end

t.test('a sky arena the operator added builds, and holds the fighter up', function()
    local c = newClient()
    c.env.Config.Arenas.gantry = pastedSkyArena()
    c.enter('gantry')

    t.isTrue(#c.world.live() > 0, 'an arena added by an operator built nothing')
    t.isTrue(onFloor(c, c.pos().x, c.pos().y),
        'the fighter is over open air in an arena the operator added')
    t.isTrue(standingOn(c, 640.0),
        ('the fighter is at %0.2f, and the operator asked for 640'):format(c.pos().z))
end)

t.test('and its whole spawn ring has floor under it', function()
    local c = newClient()
    c.env.Config.Arenas.gantry = pastedSkyArena()
    c.enter('gantry')

    local area = c.Arena.GetSpawnArea('gantry')
    local holes = 0
    for ring = 0, math.floor(area.radius) do
        for step = 0, 23 do
            local angle = (step / 24) * math.pi * 2
            if not onFloor(c, area.x + ring * math.cos(angle), area.y + ring * math.sin(angle)) then
                holes = holes + 1
            end
        end
    end
    t.equals(holes, 0, ('%d points in the new arena have no floor under them'):format(holes))
end)

t.test('and it comes down again when the round ends, like any other', function()
    local c = newClient()
    c.env.Config.Arenas.gantry = pastedSkyArena()
    c.enter('gantry')
    t.isTrue(#c.world.live() > 0)

    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, 'an operator-added arena left its floor at 640m')
end)

t.test('two operator arenas at once do not build into each other', function()
    -- Somebody will add three. Each client builds only the one it is in.
    local first = newClient()
    first.env.Config.Arenas.gantry = pastedSkyArena()
    first.enter('gantry')

    local second = newClient()
    second.env.Config.Arenas.gantry = pastedSkyArena()
    second.enter('skydome')

    -- The second client is in the SHIPPED arena; nothing it built should sit
    -- at the operator arena's height.
    for _, object in ipairs(second.world.live()) do
        t.isTrue(math.abs(object.z - 640.0) > 1.0,
            'a client in the shipped arena built pieces at the operator arena height')
    end
    t.isTrue(#first.world.live() > 0 and #second.world.live() > 0)
end)

t.test('DEFECT: an operator arena that forgets exactSpawnZ is still not dropped to the map', function()
    -- The second guard, on an arena nobody has ever run. The floor Z is what
    -- rejects a ground answer from below the platform, and it has to work
    -- for an arena defined entirely by the operator.
    local c = newClient()
    local arena = pastedSkyArena()
    arena.exactSpawnZ = nil
    c.env.Config.Arenas.gantry = arena
    c.enter('gantry')

    t.isTrue(c.pos().z > 500.0,
        ('without exactSpawnZ the fighter ended at z=%0.1f -- the ground probe won'):format(c.pos().z))
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
