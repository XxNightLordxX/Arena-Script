-- Crimson Arena: the health and armour handed back at the exit stay handed back.

--[[
    tests/exitvitals_spec.lua

    THE OWNER'S ASK: "after a match ends, every player must be back to
    normal." The exit puts back the health and armour a fighter walked in
    with -- and then, five seconds later, End's revive sweep sends the
    medical script's revive to everybody it sent home, and most medical
    scripts set health and put ARMOUR TO ZERO doing it (matchflow_spec).
    holdVitals, sent straight after it, did nothing outside a round, so a
    fighter who walked out in their own vest lost it standing at the lobby.

    Now the exit's numbers are defended for a short window after it, the way
    the in-round hold defends the arena's: only the player's own numbers,
    only inside the window, never on a dead ped, and never into the next
    round. Exercised against the REAL client/match.lua.

    Harness borrowed from exitrestore_spec, with armour modelled and the
    radio resources left out (nothing here is about them).
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('exitvitals_spec')

local UNARMED = 'WEAPON_UNARMED'

local function newClient()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local world = { clock = 100000, health = 200, armour = 0, dead = false }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        exports = setmetatable({}, { __index = function() return {} end }),
        LocalPlayer = { state = {} },
        GetConvar = function(_name, default) return default end,
        print = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { x = 2344.0, y = 2565.0, z = 46.7 } end,
        SetEntityCoordsNoOffset = function() end,
        GetGroundZFor_3dCoord = function() return true, 46.0 end,
        IsEntityDead = function() return world.dead end,
        GetEntityHealth = function() return world.health end,
        GetEntityMaxHealth = function() return 200 end,
        SetEntityHealth = function(_p, value) world.health = value end,
        StopEntityFire = function() end,
        GetPedArmour = function() return world.armour end,
        SetPedArmour = function(_p, value) world.armour = value end,

        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        GetSelectedPedWeapon = function() return UNARMED end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        RemoveWeaponFromPed = function() end,
        RemoveAllPedWeapons = function() end,

        ClearPedBloodDamage = function() end,
        NetworkResurrectLocalPlayer = function() world.dead = false end,
        FreezeEntityPosition = function() end,
        SetEntityVisible = function() end,
        SetEntityCollision = function() end,
        SetEntityInvincible = function() end,
        SetPlayerInvincible = function() end,
        GetPlayerInvincible = function() return false end,
        IsPedShooting = function() return false end,
        IsPedPerformingMeleeAction = function() return false end,
        IsPedInMeleeCombat = function() return false end,
        IsControlJustPressed = function() return false end,
        IsDisabledControlJustPressed = function() return false end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGameTimer = function() return world.clock end,
        joaat = function(name) return name end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end, Notify = function() end, Countdown = function() end },
        IsEntityVisible = function() return true end,
        GetEntityCollisionDisabled = function() return false end,
        IsEntityPositionFrozen = function() return false end,
        ArenaSpectate = { IsActive = function() return false end, Stop = function() end },
        GetEntityHeading = function() return 0.0 end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        RemoveBlip = function() end,
        DoesEntityExist = function(h) return h == 11 end,
        GetGamePool = function() return {} end,
        SetEntityDrawOutline = function() end,
        ResetEntityDrawOutlineRenderTechnique = function() end,
        DisableControlAction = function() end,
        DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end,
        GetPlayerServerId = function() return 1 end,
        GetWeaponDamageType = function() return 3 end,
    })

    env.Arena.GetPlatform = function() return nil end
    env.Arena.GetCover = function() return {} end
    Sandbox.loadInto('../Crimson-Arena/client/dispatch.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/spawnprotection.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    local c = { env = env, world = world, runner = runner }

    function c.fire(event, payload)
        local handler = handlers['crimson_arena:client:' .. event]
        if not handler then error('no client handler for ' .. event, 2) end
        handler(payload)
    end

    function c.enter()
        c.fire('enterArena', {
            matchId = 'm1', arenaKey = 'trailerpark', modeKey = 'ffa',
            spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
            scatterRadius = 0.0, sizeFactor = 1.0, radar = false, loadout = {},
            boundary = { enabled = true, center = { x = 2344.4, y = 2565.0, z = 46.7 }, radius = 100.0 },
            freezeSeconds = 0,
        })
        c.fire('matchLive', {})
    end

    function c.exit() c.fire('exitArena', {}) end

    --- What a medical script's revive does to a ped that is up: health to
    --- full, armour to nothing. Then the arena's holdVitals, which
    --- ArenaDispatch.Revive sends straight after it.
    function c.medicalRevive()
        world.health, world.armour = 200, 0
        c.fire('holdVitals')
    end

    --- Frames, each `ms` apart on the game clock.
    function c.frames(count, ms)
        for _ = 1, (count or 1) do
            world.clock = world.clock + (ms or 100)
            runner.step()
        end
    end

    return c
end

--- In with their own 160 health and 45 armour, out again, the exit's own
--- threads settled.
local function foughtAndLeft()
    local c = newClient()
    c.world.health, c.world.armour = 160, 45
    c.enter()
    c.frames(2)
    c.world.health, c.world.armour = 130, 10        -- the round's wear
    c.exit()
    t.equals(c.world.health, 160, 'premise: the exit did not hand their health back')
    t.equals(c.world.armour, 45, 'premise: the exit did not hand their armour back')
    return c
end

t.test('DEFECT: the sweep\'s medical revive after the exit does not take their own armour away', function()
    local c = foughtAndLeft()
    c.frames(5, 1000)                               -- standing at the lobby, five seconds on

    c.medicalRevive()
    c.frames(2)

    t.equals(c.world.armour, 45, 'the vest they walked in with was stripped at the lobby by the arena\'s revive')
    t.equals(c.world.health, 160, 'their own health was rewritten by the arena\'s revive')
end)

t.test('DEFECT: and a revive that writes a frame late is answered too', function()
    -- A handler that yields lands after holdVitals; the hold re-asserts on
    -- every frame of its window, so a late write is put right on the next.
    local c = foughtAndLeft()
    c.fire('holdVitals')
    c.frames(1)
    c.world.health, c.world.armour = 200, 0         -- the handler, a frame late
    c.frames(1)
    t.equals(c.world.armour, 45)
    t.equals(c.world.health, 160)
end)

t.test('DEFECT: the exit\'s OWN revive, landing just after the restore, does not undo it', function()
    -- sendExitArena sends the revive before the exit, so its holdVitals
    -- reaches a client still in the round; a handler that yields writes
    -- after leaveArena has put the player's numbers back.
    local c = newClient()
    c.world.health, c.world.armour = 160, 45
    c.enter()
    c.frames(2)
    c.fire('holdVitals')                            -- the exit revive's, still in the round
    c.exit()
    c.world.health, c.world.armour = 200, 0         -- the yielding handler, after the restore
    c.frames(2)
    t.equals(c.world.armour, 45, 'the exit revive stripped the armour the exit had just handed back')
    t.equals(c.world.health, 160)
end)

t.test('the defence is a short one: armour lost after it is not handed back', function()
    -- Bounded like the in-round hold, or a player at the lobby would be
    -- bulletproof for as long as it ran.
    local c = foughtAndLeft()
    c.medicalRevive()
    c.frames(20, 250)                               -- five seconds: well past VITALS_REASSERT_MS
    c.world.armour = 20                             -- shot, in the city
    c.frames(3)
    t.equals(c.world.armour, 20, 'armour lost after the window was handed straight back')
end)

t.test('and the window closes: a revive long after the exit re-asserts nothing', function()
    local c = foughtAndLeft()
    c.frames(15, 1000)                              -- fifteen seconds at the lobby
    c.medicalRevive()
    c.frames(3)
    t.equals(c.world.armour, 0, 'a revive long after the round re-asserted the round\'s exit numbers')
end)

t.test('a dead ped is never written', function()
    local c = foughtAndLeft()
    c.fire('holdVitals')
    c.world.dead, c.world.health = true, 0
    c.frames(3)
    t.equals(c.world.health, 0, 'the hold wrote health onto a dead ped')
end)

t.test('and the next round\'s entry ends it: the arena\'s numbers stand there', function()
    local c = foughtAndLeft()
    c.fire('holdVitals')
    c.enter()                                       -- straight into another round
    local health, armour = c.world.health, c.world.armour
    c.frames(3)
    t.equals(c.world.armour, armour, 'the last round\'s exit armour was written in the new round')
    t.equals(c.world.health, health, 'the last round\'s exit health was written in the new round')
    t.isTrue(c.world.armour ~= 45, 'premise: the new round put its own armour on')
end)

t.test('somebody who never fought is not touched by a revive outside a round', function()
    local c = newClient()
    c.world.health, c.world.armour = 170, 30
    c.exit()                                        -- an onlooker's exit: nothing captured
    c.medicalRevive()
    c.frames(3)
    t.equals(c.world.armour, 0, 'a player the arena never captured was handed numbers')
end)

os.exit(t.summary())
