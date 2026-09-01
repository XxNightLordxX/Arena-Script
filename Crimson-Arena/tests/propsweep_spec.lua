--[[
    crimson_arena/tests/propsweep_spec.lua

    SCENERY NOBODY IS TRACKING.

    The client takes its arena down by remembering every handle it created.
    That is right until the memory and the world disagree, and there are
    several ordinary ways for them to: a build that dies between CreateObject
    and the table the handle goes into, a resource restarted with a round
    live, a build still unwinding when the exit already ran. Each leaves a
    piece standing that no list knows about -- and because the pieces are
    marked as mission entities, the engine will not collect them either.

    From a player's seat that is not "a stray prop". The next round lays its
    floor in the same coordinates, so every tile is now two tiles in one
    place, and a floor made of doubled props flickers and changes as you walk
    across it while staying perfectly solid underfoot. That is exactly how it
    was reported: "it looks scuffed out i can still walk on them they just
    look super glitchy".

    So the teardown no longer trusts its own list alone. It sweeps the arena
    for anything of that arena's own, by model, within reach of it.

    THE SWEEP IS DELIBERATELY NOT AVAILABLE TO EVERY ARENA, and the first
    test here is the reason: it deletes by model, and at an arena on the real
    map the same shipping container is very likely part of the map somebody
    chose the spot for. Only an arena that carries its own floor -- which
    hangs over open air, where nothing within reach is ours by accident --
    gets one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('propsweep_spec')

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }

-- ======================================================================
-- THE RULE: WHAT COUNTS AS THIS ARENA'S OWN, AND HOW FAR OUT
-- ======================================================================

local env = Sandbox.newArenaEnv()
local Arena = env.Arena

t.test('an arena on the real map gets no sweep at all', function()
    -- THE SAFETY ARGUMENT, and it is the whole reason this is not general.
    -- Trailer Park is a real place with real props in it, and its cover
    -- chain names the same shipping container the sky arena uses. A sweep
    -- there would delete the map.
    t.equals(Arena.PropSweep('trailerpark'), nil,
        'a ground arena was handed a sweep that deletes props by model')
end)

t.test('and neither does an arena key that does not exist', function()
    t.equals(Arena.PropSweep('no-such-arena'), nil)
    t.equals(Arena.PropSweep(nil), nil)
end)

t.test('the sky arena is swept around its own centre', function()
    local sweep = Arena.PropSweep('skydome')
    t.isTrue(sweep ~= nil, 'the arena that builds its own floor got no sweep')
    t.equals(sweep.x, SKY.x)
    t.equals(sweep.y, SKY.y)
    t.equals(sweep.z, SKY.z)
end)

t.test('and it reaches further than the floor it is looking for', function()
    -- A tile is kept whenever ANY part of it reaches the platform radius, so
    -- the last ring hangs half a tile past it and the corners half a
    -- diagonal past that. A sweep drawn at the platform radius walks past
    -- exactly the pieces on the rim.
    local platform = Arena.GetPlatform('skydome')
    local sweep = Arena.PropSweep('skydome')
    t.isTrue(sweep.radius > platform.radius,
        ('the sweep reaches %.1fm and the floor is laid to %.1fm')
            :format(sweep.radius, platform.radius))
    -- Big enough for the shipped floor prop, which is forty metres square:
    -- half a diagonal is 28.3m.
    t.isTrue(sweep.radius - platform.radius >= 28.3,
        'the margin is thinner than half a tile diagonal, so rim pieces survive')
end)

t.test('it names every model in every chain, not just the one this build loaded', function()
    -- THE PIECE LEFT BEHIND MAY NOT BE THE ONE THIS CLIENT WOULD CREATE. A
    -- client on a build without the stunt DLC falls further down the chain
    -- and leaves a container standing; a client that has the DLC then sweeps
    -- looking only for stunt blocks and walks straight past it.
    local sweep = Arena.PropSweep('skydome')
    local platform = Arena.GetPlatform('skydome')

    for _, name in ipairs(platform.models) do
        t.isTrue(sweep.models[name] == true,
            ('the floor chain names %s and the sweep does not look for it'):format(name))
    end
    t.isTrue(#platform.models > 1, 'the floor chain has no fallbacks, so this proves nothing')

    local coverModels = 0
    for _, piece in ipairs(Arena.GetCover('skydome')) do
        for _, name in ipairs(piece.models) do
            coverModels = coverModels + 1
            t.isTrue(sweep.models[name] == true,
                ('a cover chain names %s and the sweep does not look for it'):format(name))
        end
    end
    t.isTrue(coverModels > 0, 'the arena has no cover, so this proves nothing')
end)

t.test('and it grows with the match, like everything else about the arena', function()
    -- The floor grows, so the reach that finds the floor has to grow with
    -- it. A sweep sized for six players misses the rim of an arena built for
    -- twenty.
    local small = Arena.PropSweep('skydome', 1.0)
    local big = Arena.PropSweep('skydome', 2.0)
    t.isTrue(big.radius > small.radius,
        ('a grown arena is swept to %.1fm and an ungrown one to %.1fm')
            :format(big.radius, small.radius))
end)

-- ======================================================================
-- THE CLIENT, RUN
-- ======================================================================

--- A client/match.lua in a modelled game, cut down to what these tests
--- touch. Kept local rather than shared with skyworld_spec: that file's
--- harness is tuned to its own questions, and a fixture two specs pull in
--- opposite directions stops answering either.
--- @return table
local function newClient()
    local world = World.new()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { world = world, printed = {} }

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
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
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end
    overrides.GetGameTimer = function() return runner.elapsed end

    local clientEnv = Sandbox.newArenaEnv(overrides)
    Sandbox.loadInto('../client/match.lua', clientEnv)
    c.env = clientEnv

    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('no handler for ' .. name) end
        local args = table.pack(...)
        local thread = coroutine.create(function() handler(table.unpack(args, 1, args.n)) end)
        for _ = 1, 200 do
            if coroutine.status(thread) == 'dead' then break end
            assert(coroutine.resume(thread))
        end
        assert(coroutine.status(thread) == 'dead', name .. ' never finished')
    end

    function c.enter(arenaKey)
        local arena = clientEnv.Config.Arenas[arenaKey]
        local spawn = clientEnv.Arena.PickSpawn(arenaKey, nil, 1)
        c.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1', arenaKey = arenaKey, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false, loadout = { weapons = {} },
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius,
                warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        })
    end

    --- Stands a prop in the world that client/match.lua is not tracking --
    --- the orphan every path in this file's header produces.
    ---
    --- The ped is moved there first because the world refuses to create
    --- anything outside the streamed bubble, exactly as the engine does.
    function c.plant(model, x, y, z)
        world.pedPos.x, world.pedPos.y, world.pedPos.z = x, y, z
        local handle = clientEnv.CreateObject(model, x, y, z, false, false, false)
        t.isTrue(handle ~= 0, 'the fixture refused to plant the stray prop')
        return handle
    end

    return c
end

t.test('every piece the arena builds is given a draw distance', function()
    -- A SCRIPT-CREATED PROP DOES NOT GET ONE FOR FREE. The map's own props
    -- are placed by the streamer, which knows how far to draw them; one
    -- created by a script starts on the engine's short default and past it
    -- drops to a low-detail stand-in or stops drawing. On a floor tiled out
    -- of them that reads as the arena flickering and changing shape as you
    -- walk it -- while staying solid, because collision never depended on
    -- the draw distance.
    local c = newClient()
    c.enter('skydome')

    local pieces = c.world.live()
    t.isTrue(#pieces > 0, 'the arena built nothing at all')
    for _, object in ipairs(pieces) do
        t.isTrue((object.lodDist or 0) > 0,
            ('%s at %.0f,%.0f was created with no draw distance'):format(object.model, object.x, object.y))
    end
end)

t.test('a stray piece left where the floor goes is swept before the next one is laid', function()
    -- THE REPORTED BUG. Two copies of the same prop in the same place is a
    -- floor that flickers and changes as you cross it, and is still solid --
    -- so nothing about it reads as "a prop was left behind".
    local c = newClient()
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, 'the ordinary teardown already failed')

    local stray = c.plant('stt_prop_stunt_bblock_huge_01', SKY.x, SKY.y, SKY.z - 10.0)
    t.equals(#c.world.live(), 1, 'the stray was not planted')

    c.enter('skydome')

    for _, object in ipairs(c.world.live()) do
        t.isTrue(object.handle ~= stray,
            'the next round built its floor straight through a prop already standing there')
    end
end)

t.test('a client with no memory at all still sweeps before it builds', function()
    -- THE CASE THE TEARDOWN CANNOT REACH, and the only reason the build
    -- sweeps separately from the exit.
    --
    -- After a restart the client is new: it has no handle list and no record
    -- of ever having built here, so there is nothing for a teardown to sweep
    -- FROM. Meanwhile the pieces the last session left are still standing,
    -- because they were marked as mission entities and the engine does not
    -- collect those. The next round is the first moment anything knows this
    -- arena is in use again, so it is the moment to look.
    local c = newClient()
    local stray = c.plant('stt_prop_stunt_bblock_huge_01', SKY.x, SKY.y, SKY.z - 10.0)
    t.equals(#c.world.live(), 1, 'the stray was not planted')

    c.enter('skydome')

    for _, object in ipairs(c.world.live()) do
        t.isTrue(object.handle ~= stray,
            'a fresh client built its floor straight through what the last session left')
    end
end)

t.test('and the round that follows is exactly one arena, not two', function()
    local c = newClient()
    c.enter('skydome')
    local clean = #c.world.live()
    c.fire('crimson_arena:client:exitArena', {})

    c.plant('stt_prop_stunt_bblock_huge_01', SKY.x + 12.0, SKY.y - 8.0, SKY.z - 10.0)
    c.enter('skydome')

    t.equals(#c.world.live(), clean,
        ('the arena came out as %d pieces where a clean one is %d'):format(#c.world.live(), clean))
end)

t.test('a stray of a model this arena never builds is left alone', function()
    -- The sweep deletes by model on purpose. A prop that is not one of ours
    -- is somebody else's, even a kilometre up.
    local c = newClient()
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})

    -- The premise, asserted rather than assumed. Every model this arena
    -- names is fair game for the sweep, and the shipped chains reach further
    -- than they look -- prop_barrier_work05 is in one of them, which is what
    -- this test was written with before it caught itself.
    local sweep = c.env.Arena.PropSweep('skydome')
    t.isTrue(sweep.models['prop_bench_01a'] == nil,
        'the arena does name this model, so the test proves nothing')

    local other = c.plant('prop_bench_01a', SKY.x, SKY.y, SKY.z)
    c.enter('skydome')

    local found = false
    for _, object in ipairs(c.world.live()) do
        if object.handle == other then found = true end
    end
    t.isTrue(found, "the sweep deleted a prop that is not part of this arena")
end)

t.test('and one of our own models standing well away from the arena is left alone', function()
    -- The radius is the other half of the safety argument. A container the
    -- map put down elsewhere is not ours because it shares a model name.
    local c = newClient()
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})

    local sweep = c.env.Arena.PropSweep('skydome')
    local far = c.plant('prop_container_01a', SKY.x + sweep.radius + 50.0, SKY.y, SKY.z)
    c.enter('skydome')

    local found = false
    for _, object in ipairs(c.world.live()) do
        if object.handle == far then found = true end
    end
    t.isTrue(found, 'the sweep reached outside the arena and deleted somebody else\'s prop')
end)

t.test('the resource stopping sweeps the arena even with no match left to read', function()
    -- THE TEARDOWN RUNS BEFORE THE GUARD, and this is what that buys. Every
    -- other thing leaveArena undoes belongs to a match, so skipping it when
    -- there is no match is right. The props do not: they are the one thing
    -- that can still be standing after currentMatch is gone -- a build that
    -- was still unwinding when the exit ran, a second exit for a round
    -- already left, a restart after the round ended. Behind the guard, every
    -- one of those leaves a floor at a thousand metres.
    local c = newClient()
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})

    -- Standing scenery, and no match on this client to find it through.
    local stray = c.plant('stt_prop_stunt_bblock_huge_01', SKY.x, SKY.y, SKY.z - 10.0)
    t.equals(#c.world.live(), 1)

    c.fire('onResourceStop', 'crimson_arena')

    local found = false
    for _, object in ipairs(c.world.live()) do
        if object.handle == stray then found = true end
    end
    t.isTrue(not found,
        'a piece left standing survived the resource stopping because there was no match to read')
end)

t.test('and the sweep says so in the console rather than tidying up silently', function()
    -- An operator whose arena keeps needing a sweep has a leak worth
    -- knowing about, and a fix that hides its own symptom is how it stays
    -- unfound.
    local c = newClient()
    c.enter('skydome')
    c.fire('crimson_arena:client:exitArena', {})
    c.plant('stt_prop_stunt_bblock_huge_01', SKY.x, SKY.y, SKY.z - 10.0)
    c.enter('skydome')

    t.isTrue(table.concat(c.printed, '\n'):find('stray', 1, true) ~= nil,
        'a stray piece was swept and nothing was printed about it')
end)
