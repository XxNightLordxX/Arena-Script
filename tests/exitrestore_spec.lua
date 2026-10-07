-- Crimson Arena: what the round changed about the player, put back on the way out.

--[[
    tests/exitrestore_spec.lua

    THE OWNER'S ASK: "after a match ends, every player must be back to
    normal -- nothing the arena changed may be left behind." The audit of
    every exit found four things client/match.lua's leaveArena did not put
    back, each exercised here against the REAL client/match.lua:

      FIRE.       A fighter set alight in the last seconds of a round was
                  sent home still burning, and the fire ate the health the
                  exit had just put back.

      A DEAD READING.  A player downed between joining and placement walks
                  in dead; the capture read that health, and the exit wrote
                  it back -- killing them again at the lobby.

      THE RADIO.  Their own channel was never given back: a team round left
                  them on no channel at all, and the door's stash of their
                  radio item dropped it in every other mode too.

      THE COUNTDOWN.  An abort or a /leave during the start freeze left a big
                  frozen "N STARTING" on screen back at the lobby.

    Harness borrowed from itemlessweapon_spec, without ox (nothing here is
    about the inventory), with the two radio resources faked the way the
    arena calls them: `exports[res]:fn(...)`, so every export takes `self`.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('exitrestore_spec')

local UNARMED = 'WEAPON_UNARMED'

--- @param opts table|nil { pmaVoice = 'started'|'missing', mmRadio = 'started'|'missing',
---     channel = number -- what pma-voice says they are on when the fixture loads }
local function newClient(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local world = {
        clock = 100000,
        health = 200,
        dead = false,
        healthSet = nil,
        log = {},           -- the natives that matter here, in the order they ran
        countdowns = {},    -- every value ArenaUI.Countdown was handed
        radio = {           -- the radio as the two resources see it
            channel = opts.channel or 0,
            pmaSets = {},   -- every pma-voice setRadioChannel
            forced = {},    -- every mm_radio ForceJoinRadio
            left = 0,       -- mm_radio LeaveRadio calls
        },
        stops = {},
    }
    local state = { pmaVoice = opts.pmaVoice or 'started', mmRadio = opts.mmRadio or 'missing' }

    local localPlayer = { state = {} }
    setmetatable(localPlayer.state, {
        __index = function(_, key) if key == 'radioChannel' then return world.radio.channel end end,
    })

    local exportsTable = setmetatable({
        ['pma-voice'] = {
            setVoiceProperty = function() end,
            setRadioChannel = function(_self, channel)
                world.radio.pmaSets[#world.radio.pmaSets + 1] = channel
                world.radio.channel = channel
            end,
        },
        -- `world.radio.waits`: both end the way mm_radio's do, in
        -- Radio:update's lib.callback.await -- which CitizenFX turns into a
        -- wait of the CALLER's own (the export's async retval is awaited in
        -- the calling coroutine). The channel changes first, as it does there.
        mm_radio = {
            ForceJoinRadio = function(_self, channel)
                world.radio.forced[#world.radio.forced + 1] = channel
                world.radio.channel = channel
                if world.radio.waits then coroutine.yield() end
                return true
            end,
            LeaveRadio = function(_self)
                world.radio.left = world.radio.left + 1
                world.radio.channel = 0
                if world.radio.waits then coroutine.yield() end
            end,
        },
    }, { __call = function() end })

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn)
            if name == 'onResourceStop' then world.stops[#world.stops + 1] = fn else handlers[name] = fn end
        end,
        RegisterCommand = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        exports = exportsTable,
        LocalPlayer = localPlayer,
        GetConvar = function(_name, default) return default end,
        print = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name)
            if name == 'pma-voice' then return state.pmaVoice end
            if name == 'mm_radio' then return state.mmRadio end
            return 'missing'
        end,
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { x = 2344.0, y = 2565.0, z = 46.7 } end,
        SetEntityCoordsNoOffset = function() end,
        GetGroundZFor_3dCoord = function() return true, 46.0 end,
        IsEntityDead = function() return world.dead end,
        GetEntityHealth = function() return world.health end,
        GetEntityMaxHealth = function() return 200 end,
        SetEntityHealth = function(_p, value)
            world.healthSet = value
            world.health = value
            world.log[#world.log + 1] = 'health'
        end,
        StopEntityFire = function(ped) world.log[#world.log + 1] = 'fire-out:' .. tostring(ped) end,
        GetPedArmour = function() return 0 end,
        SetPedArmour = function() end,

        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        GetSelectedPedWeapon = function() return UNARMED end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        RemoveWeaponFromPed = function() end,
        RemoveAllPedWeapons = function() end,

        ClearPedBloodDamage = function() end,
        NetworkResurrectLocalPlayer = function() world.dead = false; world.log[#world.log + 1] = 'resurrect' end,
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
        ArenaUI = {
            UpdateHud = function() end,
            Notify = function() end,
            Countdown = function(seconds) world.countdowns[#world.countdowns + 1] = seconds end,
        },
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
    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/client/dispatch.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/spawnprotection.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    local c = { env = env, world = world, state = state, runner = runner }

    function c.fire(event, payload)
        local handler = handlers['crimson_arena:client:' .. event]
        if not handler then error('no client handler for ' .. event, 2) end
        handler(payload)
    end

    --- Into a round. `extra` is merged over a plain free-for-all payload.
    function c.enter(extra, noLive)
        local payload = {
            matchId = 'm1', arenaKey = 'trailerpark', modeKey = 'ffa',
            spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
            scatterRadius = 0.0, sizeFactor = 1.0, radar = false, loadout = {},
            boundary = { enabled = true, center = { x = 2344.4, y = 2565.0, z = 46.7 }, radius = 100.0 },
            freezeSeconds = 0,
        }
        for key, value in pairs(extra or {}) do payload[key] = value end
        c.fire('enterArena', payload)
        if not noLive then c.fire('matchLive', {}) end
    end

    --- A team round on `team` channel, from a player who was on `prior`.
    function c.enterTeam(team, prior)
        c.enter({ modeKey = 'tdm', teamKey = 'crimson', radioChannel = team, priorRadioChannel = prior })
    end

    function c.exit() c.fire('exitArena', {}) end

    function c.stopResource()
        for _, fn in ipairs(world.stops) do fn('crimson_arena') end
    end

    --- The resource stopping AS IT REALLY RUNS: each handler in a coroutine
    --- of its own, as CitizenFX runs every event handler, and never resumed
    --- -- a stopped resource's scheduler does not come back for anything
    --- that waited.
    function c.stopResourceForReal()
        for _, fn in ipairs(world.stops) do
            local co = coroutine.create(function() fn('crimson_arena') end)
            local ok, err = coroutine.resume(co)
            if not ok then error(err, 2) end
        end
    end

    function c.poll(times, everyMs)
        for _ = 1, (times or 1) do
            world.clock = world.clock + (everyMs or 250)
            runner.step()
        end
    end

    --- Where the log says something happened, or nil.
    function c.at(entry)
        for i, seen in ipairs(world.log) do if seen == entry then return i end end
        return nil
    end

    return c
end

-- ======================================================================
-- FIRE
-- ======================================================================

t.test('DEFECT: a fighter leaving a round is put out before their health goes back', function()
    local c = newClient()
    c.enter()
    c.world.log = {}
    c.exit()

    local out, health = c.at('fire-out:11'), c.at('health')
    t.isNotNil(out, 'a fighter set alight in the round was sent home still burning')
    t.isNotNil(health, 'the exit put no health back, so the order proves nothing')
    t.isTrue(out < health, 'the fire was put out after the health went back, so it had already eaten some')
end)

t.test('and on the resource-stop path too, which is a way out like any other', function()
    local c = newClient()
    c.enter()
    c.world.log = {}
    c.stopResource()
    t.isNotNil(c.at('fire-out:11'), 'a restart mid-round left a burning fighter burning')
end)

t.test('and somebody who never fought is not touched', function()
    -- An exit for a client that never saw the round start -- an onlooker,
    -- or a second exit -- has nothing of the arena's on them to put out.
    local c = newClient()
    c.exit()
    t.isNil(c.at('fire-out:11'), 'a player the arena never put in a round was touched on the way out')
end)

-- ======================================================================
-- A DEAD READING IS NOT WRITTEN BACK
-- ======================================================================

t.test('DEFECT: a player who walked in dead does not die again at the lobby', function()
    local c = newClient()
    c.world.dead, c.world.health = true, 0
    c.enter()
    -- The start countdown stood them up for the round.
    c.world.dead, c.world.health = false, 200
    c.exit()

    t.isTrue((c.world.healthSet or 0) > 100,
        ('the exit wrote %s back onto a living player -- dead on arrival at the lobby')
            :format(tostring(c.world.healthSet)))
    t.equals(c.world.healthSet, 200, 'they leave at the full health the arena\'s revive gave them')
end)

t.test('and the 100 a player ped dies at is a dead reading too', function()
    local c = newClient()
    c.world.health = 100
    c.enter()
    c.world.health = 180
    c.exit()
    t.equals(c.world.healthSet, 200, 'a dead-threshold health was written back')
end)

t.test('but a living player gets back exactly what they walked in with', function()
    -- The control: the floor is only for a dead reading. Somebody who walked
    -- in hurt leaves hurt -- the arena does not heal people for free.
    local c = newClient()
    c.world.health = 150
    c.enter()
    c.world.health = 120
    c.exit()
    t.equals(c.world.healthSet, 150, 'a living player\'s own health was not handed back as it was')
end)

-- ======================================================================
-- THE RADIO CHANNEL THEY WERE ON
-- ======================================================================

local function last(list) return list[#list] end

t.test('DEFECT: a team round puts them back on their own channel, not on none (pma-voice)', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, 3)
    t.equals(c.world.radio.channel, 401, 'they were never put on the team channel, so this proves nothing')
    c.exit()
    t.equals(c.world.radio.channel, 3, 'a player on channel 3 before the round came out on channel '
        .. tostring(c.world.radio.channel))
end)

t.test('and through mm_radio when it runs, so the radio shows it', function()
    local c = newClient({ mmRadio = 'started', channel = 3 })
    c.enterTeam(401, 3)
    c.exit()
    t.equals(last(c.world.radio.forced), 3, 'the channel was not handed back through mm_radio')
    t.equals(c.world.radio.left, 0, 'mm_radio was told to leave the radio instead')
    t.equals(c.world.radio.channel, 3)
end)

t.test('somebody who was on no channel is taken off the team one, as before', function()
    local c = newClient({ mmRadio = 'started' })
    c.enterTeam(401, 0)
    c.exit()
    t.equals(c.world.radio.left, 1, 'the team channel was not left')
    t.equals(c.world.radio.channel, 0, 'a player who had no channel was left on one')
end)

t.test('THE ASK: eliminated in a team round takes them off the team channel (pma-voice)', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, 3)
    c.fire('eliminated', { matchId = 'm1', spectate = false })
    c.poll(1)
    t.equals(c.world.radio.channel, 0, 'an eliminated fighter is still on the team channel')
    c.poll(8, 500)
    t.equals(c.world.radio.channel, 0, 'the lock loop put the eliminated fighter back on the team channel')
    c.exit()
    t.equals(c.world.radio.channel, 3, 'their own channel did not come back when the round ended')
end)

t.test('and through mm_radio, so the radio shows them off it', function()
    local c = newClient({ mmRadio = 'started', channel = 3 })
    c.enterTeam(401, 3)
    c.fire('eliminated', { matchId = 'm1', spectate = false })
    c.poll(1)
    t.equals(c.world.radio.left, 1, 'mm_radio was not told to leave the team channel')
    c.exit()
    t.equals(last(c.world.radio.forced), 3, 'their own channel was not handed back through mm_radio')
end)

t.test('and outside a team round elimination leaves the radio alone', function()
    local c = newClient({ channel = 3 })
    c.enter()
    c.fire('eliminated', { matchId = 'm1', spectate = false })
    c.poll(1)
    t.equals(c.world.radio.channel, 3, 'a free-for-all elimination touched their own channel')
end)

t.test('DEFECT: outside a team round, a channel the door\'s stash dropped is handed back', function()
    -- The door stashed their radio item; mm_radio left the channel when it
    -- went. In a free-for-all nothing else would ever give it back.
    local c = newClient({ mmRadio = 'started', channel = 3 })
    c.enter({ priorRadioChannel = 3 })
    c.world.radio.channel = 0          -- mm_radio's doRadioCheck, on the stash
    c.exit()
    t.equals(c.world.radio.channel, 3, 'the channel the stash dropped was never handed back')
end)

t.test('but somebody still on a channel outside a team round is left on it', function()
    -- Nothing dropped them, so there is nothing of the arena's to undo; one
    -- they tuned to themselves is theirs.
    local c = newClient({ channel = 3 })
    c.enter({ priorRadioChannel = 3 })
    c.world.radio.channel = 7
    c.exit()
    t.equals(c.world.radio.channel, 7, 'the arena re-tuned a radio it never touched')
    t.equals(#c.world.radio.pmaSets, 0, 'the arena wrote a channel it had no reason to')
end)

t.test('a server that does not send the channel falls back to pma-voice\'s own reading', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, nil)
    c.exit()
    t.equals(c.world.radio.channel, 3, 'with no channel in the payload, the one pma-voice still showed was lost')
end)

t.test('an arena team channel is never "handed back"', function()
    -- 400..499 is the arena's own range, locked to one side of one match.
    local c = newClient({ mmRadio = 'started', channel = 405 })
    c.enterTeam(401, 405)
    c.exit()
    t.equals(c.world.radio.channel, 0, 'the exit put a player on one of the arena\'s own team channels')
end)

t.test('a second enter in the same round does not take the team channel for theirs', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, nil)
    c.enterTeam(401, nil)               -- the state bag now reads the team channel
    c.exit()
    t.equals(c.world.radio.channel, 3, 'the second reading replaced the player\'s own channel')
end)

t.test('and the resource stopping mid-round hands it back too', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, 3)
    c.stopResource()
    t.equals(c.world.radio.channel, 3, 'a restart mid-round left them on no channel')
end)

-- A RESTART MID-ROUND ON AN mm_radio SERVER. mm_radio's ForceJoinRadio and
-- LeaveRadio wait on a server callback, and that wait becomes leaveArena's
-- own -- on the resource-stop path, the end of it. The radio was handled at
-- the TOP of leaveArena, so nothing after it ran: no health back, no
-- teleport, no weapons. In a team round that was already so; handing the
-- channel back in every mode spread it to every round.
for _, case in ipairs({
    { 'a free-for-all whose stash dropped their channel', function(c)
        c.enter({ priorRadioChannel = 3 })
        c.world.radio.channel = 0          -- mm_radio's doRadioCheck, on the stash
    end, 3 },
    { 'a team round, handing their own channel back', function(c) c.enterTeam(401, 3) end, 3 },
    { 'a team round, leaving the team channel for none', function(c) c.enterTeam(401, 0) end, 0 },
}) do
    t.test('DEFECT: a restart mid-round still sends them home whole -- ' .. case[1], function()
        local c = newClient({ mmRadio = 'started', channel = 3 })
        c.world.health = 150
        case[2](c)
        t.isTrue(c.world.healthSet ~= 150, 'the round never changed their health, so this proves nothing')

        c.world.radio.waits = true
        c.stopResourceForReal()

        t.equals(c.world.healthSet, 150,
            'mm_radio\'s wait swallowed the rest of the exit: their own health was never handed back')
        t.isNotNil(c.at('fire-out:11'), 'nor was the rest of the exit run')
        t.equals(c.world.radio.channel, case[3], 'and the radio was not put where it belongs')
    end)
end

t.test('and a later round starts from a clean slate', function()
    local c = newClient({ channel = 3 })
    c.enterTeam(401, 3)
    c.exit()
    c.world.radio.channel = 0           -- they switched their radio off afterwards
    c.enterTeam(402, 0)
    c.exit()
    t.equals(c.world.radio.channel, 0, 'the first round\'s channel was handed back again a round later')
end)

-- ======================================================================
-- THE START COUNTDOWN
-- ======================================================================

t.test('DEFECT: leaving during the start freeze takes the countdown down with it', function()
    local c = newClient()
    c.enter({ freezeSeconds = 5 }, true)
    c.poll(1)
    t.equals(c.world.countdowns[1], 5, 'the freeze never drew a countdown, so this proves nothing')

    c.exit()
    c.poll(3, 1000)

    t.equals(last(c.world.countdowns), 0,
        'a frozen "' .. tostring(last(c.world.countdowns)) .. ' STARTING" was left on screen after the exit')
end)

t.test('and an exit for somebody who never fought sends no countdown at all', function()
    -- An onlooker's exit must not hide a countdown that is not the arena's
    -- round's to hide.
    local c = newClient()
    c.exit()
    t.equals(#c.world.countdowns, 0, 'a player who was never in a round had a countdown sent to them')
end)

os.exit(t.summary())
