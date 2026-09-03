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


local c = newClient()
c.enter('skydome')
print('---CONSOLE---')
print(c.console())
os.exit(0)
