--[[
    crimson_arena/tests/lobbyworld_spec.lua

    THE LOBBY, AS THE PLAYER ACTUALLY FINDS IT.

    client/main.lua puts the whole front door of this resource into the
    world: the NPC, the ground marker that replaces it when ox_target is
    not there, the map blip that has to point at whichever of those two is
    really up, and the /arena command. panel_spec covers the START-UP
    THREAD -- that the ped goes where config says, that a raise does not
    take the blip down with it, that the failure is loud. This file covers
    everything that thread LEAVES BEHIND.

    A mutation sample of client/main.lua found forty survivors, the worst
    of any file in the resource, and they cluster in three places
    panel_spec cannot reach by design:

      THE MARKER RENDER LOOP, which panel_spec records rather than runs --
      its own comment says so, because running a `while true` inline never
      returns. So the distance test, the draw call and the help prompt had
      never executed. Inverting the subtraction that measures how far away
      the player is left every test green.

      THE MODE RESOLUTION, which decides whether a player gets an NPC, a
      marker, both, or a marker they were not expecting because ox_target
      is down. Turning its three-way check into one that can never be true
      left every test green too.

      THE NATIVE FLAGS on the NPC -- mission entity, freeze, invincible,
      block events -- each of which is one boolean between a working lobby
      and an NPC that wanders off, dies, or is culled mid-conversation.

    This file runs the marker loop on the sandbox's coroutine thread
    runner, one render pass at a time, with the player's position under the
    test's control.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- A vector3 that supports `#(a - b)`.
---
--- The sandbox's own stub is a plain { x, y, z }, which is enough for
--- config.lua but not for the one line in the marker loop that measures
--- how far the player is from it. LENGTH LIVES ON THE DIFFERENCE, not on
--- the point: that is the only shape production asks for.
local function vec3(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, {
        __sub = function(a, b)
            local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            return setmetatable({}, { __len = function() return distance end })
        end,
    })
end

--- One fresh load of the REAL client/main.lua with the world modelled.
---
--- THE THREADS RUN. panel_spec captures the marker thread and asserts it
--- was started; here it is a coroutine the test steps, so the loop inside
--- it is production code being executed rather than production code being
--- counted.
--- @param opts table? -- { targetState, interaction, at, pedRaises, modelLoads, mutate }
--- @return table fixture
local function newLobby(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()

    local f = {
        console = {},
        markers = {},        -- every DrawMarker, in order
        helpPrompts = {},    -- every help text shown
        pedFlags = {},       -- the native flags set on the NPC
        targeted = {},       -- ox_target registrations and removals
        blips = {},          -- every blip created, with its properties
        commands = {},       -- every RegisterCommand
        opened = 0,          -- how many times the panel was opened
        deleted = {},        -- entities deleted on teardown
        keyPressed = false,
    }
    -- Where the player is standing. A test moves this between steps.
    f.playerAt = opts.at or { x = 1000.0, y = 1000.0, z = 0.0 }

    local handlers = {}
    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        print = function(line) f.console[#f.console + 1] = tostring(line) end,

        vector3 = vec3,
        PlayerPedId = function() return 1 end,
        GetEntityCoords = function() return vec3(f.playerAt.x, f.playerAt.y, f.playerAt.z) end,

        GetResourceState = function(resource)
            if resource == 'ox_target' then return opts.targetState or 'started' end
            return 'started'
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function(name, fn, restricted)
            f.commands[#f.commands + 1] = { name = name, fn = fn, restricted = restricted }
        end,
        ArenaUI = { Open = function() f.opened = f.opened + 1 end },

        joaat = function() return 1 end,
        IsModelInCdimage = function() return true end,
        IsModelValid = function() return true end,
        RequestModel = function() end,
        HasModelLoaded = function() return opts.modelLoads ~= false end,
        -- A REAL CLOCK, driven by the same Wait the code under test
        -- calls. loadModel gives itself a ten-second deadline and spins on
        -- Wait(50) until it passes; against a frozen clock that loop never
        -- ends, and the start-up thread parks in it forever.
        GetGameTimer = function() return runner.elapsed end,

        CreatePed = function(kind, model, x, y, z, heading, networked, scriptHost)
            if opts.pedRaises then error('the game would not make that ped') end
            f.createdPed = {
                kind = kind, model = model, at = { x = x, y = y, z = z, w = heading },
                networked = networked, scriptHost = scriptHost,
            }
            return 7
        end,
        SetModelAsNoLongerNeeded = function() end,
        DoesEntityExist = function() return true end,
        DeleteEntity = function(entity) f.deleted[#f.deleted + 1] = entity end,
        -- RECORDED WITH THEIR ARGUMENTS. Each of these is one boolean
        -- between a working lobby NPC and one that walks away.
        SetEntityAsMissionEntity = function(entity, a, b)
            f.pedFlags.mission = { entity = entity, a = a, b = b }
            f.pedFlags.missionCalls = (f.pedFlags.missionCalls or 0) + 1
        end,
        FreezeEntityPosition = function(_e, on) f.pedFlags.frozen = on end,
        SetEntityInvincible = function(_e, on) f.pedFlags.invincible = on end,
        SetBlockingOfNonTemporaryEvents = function(_e, on) f.pedFlags.blockEvents = on end,
        TaskStartScenarioInPlace = function(_e, name) f.pedFlags.scenario = name end,
        exports = {
            ox_target = {
                addLocalEntity = function(_self, entity, options)
                    f.targeted[#f.targeted + 1] = { action = 'add', entity = entity, options = options }
                end,
                removeLocalEntity = function(_self, entity, name)
                    f.targeted[#f.targeted + 1] = { action = 'remove', entity = entity, name = name }
                end,
            },
        },

        AddBlipForCoord = function(x, y, z)
            f.blips[#f.blips + 1] = { at = { x = x, y = y, z = z } }
            return 3
        end,
        SetBlipSprite = function(_b, v) f.blips[#f.blips].sprite = v end,
        SetBlipColour = function(_b, v) f.blips[#f.blips].color = v end,
        SetBlipScale = function(_b, v) f.blips[#f.blips].scale = v end,
        SetBlipAsShortRange = function(_b, v) f.blips[#f.blips].shortRange = v end,
        SetBlipDisplay = function(_b, v) f.blips[#f.blips].display = v end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function(text) f.lastText = text end,
        EndTextCommandSetBlipName = function() f.blips[#f.blips].label = f.lastText end,
        DoesBlipExist = function() return true end,
        RemoveBlip = function() f.blipRemoved = true end,

        DrawMarker = function(kind, x, y, z, ...)
            f.markers[#f.markers + 1] = { kind = kind, at = { x = x, y = y, z = z }, rest = { ... } }
        end,
        BeginTextCommandDisplayHelp = function() end,
        EndTextCommandDisplayHelp = function()
            f.helpPrompts[#f.helpPrompts + 1] = f.lastText
        end,
        IsControlJustReleased = function() return f.keyPressed end,
    })

    Sandbox.loadInto('../config.lua', env)
    if opts.interaction ~= nil then env.Config.Lobby.interaction = opts.interaction end
    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../client/main.lua', env)

    f.env = env
    f.runner = runner
    --- One render pass of every live thread.
    f.step = runner.step
    f.fire = function(name, ...)
        local handler = handlers[name]
        if not handler then return false end
        handler(...)
        return true
    end
    f.log = function() return table.concat(f.console, '\n') end

    -- The start-up thread, which is what puts everything above in place.
    -- One pass is enough unless the model never loads, where the thread
    -- has to spin out its ten-second deadline at fifty milliseconds a
    -- pass before it gives up and falls back. The player starts far from
    -- the lobby, so the marker thread draws nothing while that happens.
    local passes = opts.modelLoads == false
        and math.ceil(10000 / 50) + 2
        or 1
    for _ = 1, passes do runner.step() end
    return f
end

--- Puts the player `distance` metres from the marker, on the x axis.
local function standAt(f, distance)
    local m = f.env.Config.Lobby.marker.coords
    f.playerAt = { x = m.x + distance, y = m.y, z = m.z }
end

-- ========================================================================
-- THE MARKER RENDER LOOP
--
-- Never executed before this file: panel_spec records the thread and says
-- in its own comment that running it inline would never return.
-- ========================================================================

t.test('the marker is drawn when the player is inside the draw distance', function()
    local f = newLobby({ targetState = 'missing' })
    standAt(f, f.env.Config.Lobby.marker.drawDistance - 1.0)

    f.step()

    t.equals(#f.markers, 1, 'the marker was not drawn to a player standing next to it')
    local m = f.env.Config.Lobby.marker.coords
    t.equals(f.markers[1].at.x, m.x, 'the marker was drawn somewhere other than where config puts it')
    t.equals(f.markers[1].at.y, m.y)
    t.equals(f.markers[1].kind, f.env.Config.Lobby.marker.type)
end)

t.test('and NOT drawn to a player standing outside it', function()
    -- The other half, and the one that matters for every client on the
    -- server: outside the radius this loop sleeps a full second, and a
    -- marker drawn regardless is a per-frame draw call on ninety-nine
    -- players who are nowhere near the lobby.
    local f = newLobby({ targetState = 'missing' })
    standAt(f, f.env.Config.Lobby.marker.drawDistance + 1.0)

    f.step()

    t.equals(#f.markers, 0, 'the marker is drawn to players who are nowhere near it')
end)

t.test('DISTANCE IS A DISTANCE -- walking away stops the draw', function()
    -- THE ASSERTION THAT CATCHES A SIGN ERROR. A single test at one spot
    -- passes just as happily against a loop that measures the sum of the
    -- two positions rather than the gap between them; only moving proves
    -- the number tracks the player.
    local f = newLobby({ targetState = 'missing' })

    standAt(f, 1.0)
    f.step()
    t.equals(#f.markers, 1, 'standing on the marker did not draw it')

    standAt(f, f.env.Config.Lobby.marker.drawDistance * 10)
    f.step()
    t.equals(#f.markers, 1, 'walking far away kept drawing the marker')

    standAt(f, 1.0)
    f.step()
    t.equals(#f.markers, 2, 'walking back did not start drawing it again')
end)

t.test('the help prompt appears only inside the INTERACT distance', function()
    -- Two radii, not one. The marker is visible from a distance; the
    -- "press E" prompt is not, or every player crossing the block is told
    -- to press a key that does nothing.
    local f = newLobby({ targetState = 'missing' })
    local marker = f.env.Config.Lobby.marker

    standAt(f, (marker.interactDistance + marker.drawDistance) / 2)
    f.step()
    t.equals(#f.markers, 1, 'the marker was not drawn at mid range')
    t.equals(#f.helpPrompts, 0, 'the press-key prompt was shown from outside interaction range')

    standAt(f, marker.interactDistance - 0.5)
    f.step()
    t.equals(#f.helpPrompts, 1, 'the prompt never appeared even standing on the marker')
    t.equals(f.helpPrompts[1], marker.helpText, 'the prompt is not the text config names')
end)

t.test('pressing the key inside range opens the panel', function()
    local f = newLobby({ targetState = 'missing' })
    standAt(f, f.env.Config.Lobby.marker.interactDistance - 0.5)

    f.keyPressed = true
    f.step()

    t.equals(f.opened, 1, 'pressing the key on the marker did not open the panel')
end)

t.test('and pressing it from outside range does NOT', function()
    -- The key is read inside the interact branch. Read outside it, a
    -- player anywhere on the map gets the arena panel every time they
    -- press that key.
    local f = newLobby({ targetState = 'missing' })
    standAt(f, f.env.Config.Lobby.marker.drawDistance * 10)

    f.keyPressed = true
    f.step()
    f.step()

    t.equals(f.opened, 0, 'the panel opened for a player nowhere near the lobby')
end)

t.test('the loop keeps running -- it is not a one-shot', function()
    local f = newLobby({ targetState = 'missing' })
    standAt(f, 1.0)

    f.step(); f.step(); f.step()

    t.equals(#f.markers, 3, 'the marker thread stopped after its first pass')
    t.equals(f.runner.aliveCount(), 1, 'the marker thread died instead of looping')
end)

-- ========================================================================
-- WHICH FIXTURE THE PLAYER GETS
-- ========================================================================

t.test("interaction = 'ped' puts up an NPC and no marker", function()
    local f = newLobby({ interaction = 'ped' })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.targeted, 1, 'no NPC was registered with ox_target')
    t.equals(#f.markers, 0, 'a ground marker went up as well as the NPC')
end)

t.test("interaction = 'marker' puts up a marker and no NPC", function()
    local f = newLobby({ interaction = 'marker' })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.targeted, 0, 'an NPC went up in marker-only mode')
    t.equals(#f.markers, 1, 'no marker went up in marker-only mode')
end)

t.test("interaction = 'both' puts up both", function()
    local f = newLobby({ interaction = 'both' })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.targeted, 1, 'no NPC in both mode')
    t.equals(#f.markers, 1, 'no marker in both mode')
end)

t.test('a typo in interaction falls back to ped AND says so once', function()
    -- Resolved once at start rather than per frame, so an operator's typo
    -- is one console line and not one per render pass.
    local f = newLobby({ interaction = 'npc' })

    t.contains(f.log(), 'is not', 'nothing was said about an unusable interaction setting')
    t.contains(f.log(), 'npc', 'the warning does not quote what the operator actually wrote')
    t.equals(#f.targeted, 1, 'the fallback did not put up the NPC it says it falls back to')
end)

t.test('and a valid setting produces NO such warning', function()
    -- The control. Without it the assertion above passes against a
    -- resource that warns on every start whatever the setting is.
    for _, mode in ipairs({ 'ped', 'marker', 'both' }) do
        local f = newLobby({ interaction = mode })
        t.notContains(f.log(), 'which is not',
            ('a valid interaction setting (%s) was reported as a typo'):format(mode))
    end
end)

t.test("ox_target missing turns 'ped' into the marker, loudly", function()
    -- The most common real deployment: ox_target stopped, and an NPC
    -- nobody can talk to is worse than no NPC because it looks like the
    -- resource is working.
    local f = newLobby({ interaction = 'ped', targetState = 'missing' })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.targeted, 0, 'an NPC was registered with a targeting resource that is not running')
    t.equals(#f.markers, 1, 'no marker replaced the NPC that could not go up')
    t.contains(f.log(), 'ox_target is not started')
    t.contains(f.log(), 'fell back', 'the start-up line does not say the lobby fell back')
end)

t.test('and an NPC that RAISES falls back to the marker too', function()
    local f = newLobby({ interaction = 'ped', pedRaises = true })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.markers, 1, 'a raise in the spawn left the player with no way into the arena')
    t.contains(f.log(), 'could not be spawned')
end)

-- ========================================================================
-- THE BLIP POINTS AT WHATEVER IS REALLY THERE
-- ========================================================================

--- Moves the marker well away from the ped.
---
--- THE SHIPPED CONFIG PUTS BOTH AT THE SAME COORDINATE, which is right for
--- a server -- the marker stands in for the NPC in the same doorway -- and
--- useless for a test: an assertion that the blip points at the ped passes
--- just as happily against one that always points at the marker. Every
--- blip test below moves them apart first, so the two answers differ.
local function separate(config)
    local ped = config.Lobby.ped.coords
    config.Lobby.marker.coords = { x = ped.x + 500.0, y = ped.y + 500.0, z = ped.z }
end

t.test('the blip follows the NPC when the NPC is what went up', function()
    local f = newLobby({ interaction = 'ped', mutate = separate })
    local wanted = f.env.Config.Lobby.ped.coords

    t.equals(#f.blips, 1)
    t.equals(f.blips[1].at.x, wanted.x, 'the blip points at the marker rather than the NPC that went up')
    t.equals(f.blips[1].at.y, wanted.y)
end)

t.test('and the MARKER when the NPC could not', function()
    -- Both live in config and an operator may move one and not the other,
    -- so a blip that always points at the ped sends players to an empty
    -- spot on exactly the servers where the fallback fired.
    local f = newLobby({ interaction = 'ped', targetState = 'missing', mutate = separate })
    local wanted = f.env.Config.Lobby.marker.coords

    t.equals(#f.blips, 1)
    t.equals(f.blips[1].at.x, wanted.x, 'the blip points at an NPC that never went up')
    t.equals(f.blips[1].at.y, wanted.y)
end)

t.test('and the MARKER in marker-only mode, where no NPC was ever asked for', function()
    local f = newLobby({ interaction = 'marker', mutate = separate })
    local wanted = f.env.Config.Lobby.marker.coords

    t.equals(f.blips[1].at.x, wanted.x, 'a marker-only lobby blipped a ped that does not exist')
end)

t.test('the blip carries the properties config gives it', function()
    local f = newLobby({ interaction = 'ped' })
    local blip = f.env.Config.Lobby.blip

    t.equals(f.blips[1].sprite, blip.sprite)
    t.equals(f.blips[1].color, blip.color)
    t.equals(f.blips[1].label, blip.label)
    -- shortRange is normalised to a real boolean: the native rejects a
    -- string, and config is hand-edited.
    t.equals(f.blips[1].shortRange, blip.shortRange == true)
    t.equals(type(f.blips[1].shortRange), 'boolean')
end)

t.test('and a blip switched off in config is not created at all', function()
    local f = newLobby({ mutate = function(config) config.Lobby.blip.enabled = false end })
    t.equals(#f.blips, 0, 'a blip was drawn for an operator who turned blips off')
end)

-- ========================================================================
-- THE FLAGS ON THE NPC
--
-- Each of these is one boolean between a working lobby and an NPC that
-- wanders off, dies, or is culled in the middle of a conversation.
-- ========================================================================

t.test('the NPC is LOCAL, not networked -- one per client, not one per player', function()
    -- Every client runs this file and every client spawns its own lobby
    -- NPC. Created networked, each of those is replicated to everybody
    -- else, and a busy server ends up with a crowd of identical NPCs
    -- standing in each other -- one per player online, all of them real
    -- to everybody.
    local f = newLobby({ interaction = 'ped' })

    t.isNotNil(f.createdPed, 'no NPC was created')
    t.equals(f.createdPed.networked, false, 'the lobby NPC is networked, so every client spawns one for everybody')
    t.equals(f.createdPed.scriptHost, true)
end)

t.test('the NPC is a mission entity, so population culling cannot delete it', function()
    local f = newLobby({ interaction = 'ped' })

    t.isNotNil(f.pedFlags.mission, 'the NPC was never made a mission entity')
    t.equals(f.pedFlags.mission.a, true)
    t.equals(f.pedFlags.mission.b, true)
end)

t.test('and it is frozen, invincible and deaf to gunfire when config says so', function()
    -- blockEvents is the one people find out about the hard way: without
    -- it the lobby NPC reacts to the first shot fired near it, flees, and
    -- takes the ox_target registration with it to wherever it stops.
    local f = newLobby({
        interaction = 'ped',
        mutate = function(config)
            config.Lobby.ped.freeze = true
            config.Lobby.ped.invincible = true
            config.Lobby.ped.blockEvents = true
        end,
    })

    t.equals(f.pedFlags.frozen, true, 'the lobby NPC was left free to walk away')
    t.equals(f.pedFlags.invincible, true, 'the lobby NPC can be killed')
    t.equals(f.pedFlags.blockEvents, true, 'the lobby NPC will flee the first shot fired near it')
end)

t.test('and none of them are set when config says not to', function()
    local f = newLobby({
        interaction = 'ped',
        mutate = function(config)
            config.Lobby.ped.freeze = false
            config.Lobby.ped.invincible = false
            config.Lobby.ped.blockEvents = false
            config.Lobby.ped.scenario = nil
        end,
    })

    t.isNil(f.pedFlags.frozen, 'the NPC was frozen against the operator\'s setting')
    t.isNil(f.pedFlags.invincible, 'the NPC was made invincible against the operator\'s setting')
    t.isNil(f.pedFlags.blockEvents)
    t.isNil(f.pedFlags.scenario, 'a scenario was started for an operator who asked for none')
end)

t.test('the scenario config names is the one started', function()
    local f = newLobby({
        interaction = 'ped',
        mutate = function(config) config.Lobby.ped.scenario = 'WORLD_HUMAN_SMOKING' end,
    })
    t.equals(f.pedFlags.scenario, 'WORLD_HUMAN_SMOKING')
end)

t.test('the target option carries the label, icon and distance from config', function()
    local f = newLobby({ interaction = 'ped' })
    local ped = f.env.Config.Lobby.ped

    local option = f.targeted[1].options[1]
    t.equals(option.label, ped.targetLabel)
    t.equals(option.icon, ped.targetIcon)
    t.equals(option.distance, ped.targetDistance)
    t.equals(type(option.onSelect), 'function', 'the NPC has no action attached to it')

    option.onSelect()
    t.equals(f.opened, 1, 'selecting the NPC option does not open the panel')
end)

-- ========================================================================
-- THE COMMAND
-- ========================================================================

t.test('SHIPPED DEFAULT -- no command is registered at all', function()
    -- Config.UI.command is nil out of the box: the ped is the way in, and
    -- a command that opens the arena panel from anywhere is opt-in.
    -- Asserted so that turning one on by accident is a red test rather
    -- than a shipped default nobody chose.
    local f = newLobby()

    t.isNil(f.env.Config.UI.command, 'the shipped config now names a panel command')
    t.equals(#f.commands, 0, 'a command was registered for an operator who asked for none')
end)

t.test('and the one an operator names is registered UNRESTRICTED', function()
    -- The restricted flag is the difference between a command everybody
    -- can use and one that silently needs an ACE nobody has granted --
    -- which reads as "the command does nothing" for every player who
    -- tries it.
    local f = newLobby({ mutate = function(config) config.UI.command = 'arena' end })

    t.equals(#f.commands, 1, 'the command an operator asked for was not registered')
    t.equals(f.commands[1].name, 'arena')
    t.equals(f.commands[1].restricted, false, 'the panel command was registered as restricted')

    f.commands[1].fn()
    t.equals(f.opened, 1, 'the command does not open the panel')
end)

-- ========================================================================
-- TEARDOWN
-- ========================================================================

t.test('stopping the resource takes the NPC and the blip with it', function()
    -- An orphaned mission ped survives a restart, so without this every
    -- restart leaves one more identical NPC standing in the lobby.
    local f = newLobby({ interaction = 'ped' })

    t.isTrue(f.fire('onResourceStop', 'crimson_arena'))

    t.equals(#f.deleted, 1, 'the lobby NPC was left standing after the resource stopped')
    t.equals(f.deleted[1], 7)
    t.isTrue(f.blipRemoved, 'the map blip outlived the resource that drew it')
    t.equals(f.targeted[#f.targeted].action, 'remove', 'the NPC was deleted without being de-registered')
end)

t.test('but SOME OTHER resource stopping leaves the lobby alone', function()
    local f = newLobby({ interaction = 'ped' })

    t.isTrue(f.fire('onResourceStop', 'some_other_script'))

    t.equals(#f.deleted, 0, 'an unrelated resource stopping deleted this resource\'s NPC')
    t.isNil(f.blipRemoved, 'an unrelated resource stopping removed this resource\'s blip')
end)


-- ========================================================================
-- THE MARKER HONOURS THE REST OF ITS CONFIG
-- ========================================================================

t.test('the marker is drawn at the size, colour and style config gives it', function()
    -- Every one of these is a hand-edited config value reaching a native
    -- positionally. A pair swapped here is a marker of the wrong shape in
    -- the wrong colour, and nothing else in the resource would notice.
    local f = newLobby({ targetState = 'missing' })
    local marker = f.env.Config.Lobby.marker
    standAt(f, 1.0)

    f.step()

    -- rest = everything after type and the three centre coordinates:
    -- three rotation, three direction, three scale, four colour, then the
    -- flags. Indices are one-based into that remainder.
    local rest = f.markers[1].rest
    t.equals(rest[7], marker.size.x, 'the marker is not the size config asks for')
    t.equals(rest[8], marker.size.y)
    t.equals(rest[9], marker.size.z)
    t.equals(rest[10], marker.color.r, 'the marker is not the colour config asks for')
    t.equals(rest[11], marker.color.g)
    t.equals(rest[12], marker.color.b)
    t.equals(rest[13], marker.color.a)
    -- Normalised to real booleans: the native rejects a string, and both
    -- of these are hand-edited.
    t.equals(rest[14], marker.bobUpAndDown == true, 'bobUpAndDown did not reach the native')
    t.equals(type(rest[14]), 'boolean')
    t.equals(rest[17], marker.rotate == true, 'rotate did not reach the native')
    t.equals(type(rest[17]), 'boolean')
end)

t.test('and an operator turning bob and rotate ON gets them', function()
    -- The control for the pair above: with both shipped off, an assertion
    -- that they arrive as false passes against a native call that hardcodes
    -- false.
    local f = newLobby({
        targetState = 'missing',
        mutate = function(config)
            config.Lobby.marker.bobUpAndDown = true
            config.Lobby.marker.rotate = true
        end,
    })
    standAt(f, 1.0)

    f.step()

    local rest = f.markers[1].rest
    t.equals(rest[14], true, 'bobUpAndDown is hardcoded rather than read from config')
    t.equals(rest[17], true, 'rotate is hardcoded rather than read from config')
end)

-- ========================================================================
-- THE KEEP-OUT FENCE THE SERVER HANDS DOWN
--
-- A state push carries the boundary of any arena being fought in that this
-- player is NOT in, and client/main.lua relays it to client/match.lua.
-- Handed on here rather than read out of the cache by the fence itself, so
-- a match ending stops the fence in the same instant the state says so.
--
-- The relay is one line, and it is exactly the shape of defect this
-- resource keeps producing: a value that is correct where it is computed
-- and gone by the time the other end reads it.
-- ========================================================================

--- A lobby whose ArenaMatch is a spy, so the relay can be watched.
--- @param matchStub table? -- what ArenaMatch should be; nil for a real one
local function newLobbyWithMatch(matchStub)
    local seen = { calls = 0 }
    local f = newLobby({
        mutate = function() end,
    })
    f.env.ArenaMatch = matchStub or {
        SetKeepOut = function(value)
            seen.calls = seen.calls + 1
            seen.last = value
        end,
    }
    f.seen = seen
    return f
end

t.test('a state push hands the keep-out boundary down to the match layer', function()
    local f = newLobbyWithMatch()

    t.isTrue(f.fire('crimson_arena:client:state', { keepOut = { arena = 'airfield' } }),
        'nothing listens for the server state push')

    t.equals(f.seen.calls, 1, 'the keep-out fence was never told anything')
    t.isNotNil(f.seen.last, 'the boundary was dropped between the state and the fence')
    t.equals(f.seen.last.arena, 'airfield', 'the fence was handed the wrong value')
end)

t.test('and a push with NO keep-out clears the fence rather than leaving it up', function()
    -- THE HALF THAT TRAPS PLAYERS. A fence that is only ever raised and
    -- never lowered leaves the player walled out of a part of the map
    -- after the match that justified it has ended.
    local f = newLobbyWithMatch()

    f.fire('crimson_arena:client:state', { keepOut = { arena = 'airfield' } })
    f.fire('crimson_arena:client:state', {})

    t.equals(f.seen.calls, 2, 'a state push with no keep-out was not relayed at all')
    t.isNil(f.seen.last, 'the fence was left up after the match that raised it ended')
end)

t.test('and rubbish where the state belongs clears it too, rather than raising', function()
    local f = newLobbyWithMatch()

    f.fire('crimson_arena:client:state', { keepOut = { arena = 'airfield' } })
    for _, bad in ipairs({ 'state', 42, true }) do
        f.fire('crimson_arena:client:state', bad)
        t.isNil(f.seen.last, ('%s as a state left the fence up'):format(tostring(bad)))
    end
end)

t.test('the relay survives client/match.lua not being loaded yet', function()
    -- Load order between two client files is not guaranteed, and a state
    -- push can land before the match layer exists. Raising here would take
    -- the whole state handler down -- the panel cache with it -- for every
    -- push afterwards.
    for _, stub in ipairs({ { name = 'nothing there' }, { SetKeepOut = 'not a function' } }) do
        local f = newLobby()
        f.env.ArenaMatch = stub.SetKeepOut and stub or nil

        t.isTrue(f.fire('crimson_arena:client:state', { keepOut = { arena = 'airfield' } }),
            'the state handler raised rather than skipping an absent match layer')
    end
end)

-- ========================================================================
-- THE FALLBACK IS ANNOUNCED ONLY WHEN IT HAPPENED
-- ========================================================================

t.test('a marker-only lobby is NOT reported as having fallen back', function()
    -- An operator who chose the marker deliberately must not be told
    -- something went wrong -- that line sends them looking for a warning
    -- above it that is not there.
    local f = newLobby({ interaction = 'marker' })

    t.notContains(f.log(), 'fell back',
        'a deliberate marker lobby was reported as a failure')
end)

t.test('but a ped lobby that could not put one up IS', function()
    local f = newLobby({ interaction = 'ped', targetState = 'missing' })
    t.contains(f.log(), 'fell back', 'a lobby that fell back said nothing about it')
end)

-- ========================================================================
-- WHAT HAPPENS WHEN THE MODEL WILL NOT LOAD
-- ========================================================================

t.test('a lobby ped model that never loads falls back to the marker', function()
    -- A bad model name in config is a typo, and the resource has to stay
    -- reachable through it rather than leaving no way into the arena.
    local f = newLobby({
        interaction = 'ped',
        mutate = function(config) config.Lobby.ped.model = 'not_a_real_ped' end,
        modelLoads = false,
    })
    standAt(f, 1.0)
    f.step()

    t.equals(#f.targeted, 0, 'an NPC was registered for a model that never loaded')
    t.equals(#f.markers, 1, 'a model that would not load left no way into the arena')
    t.contains(f.log(), 'would not load')
end)

-- ========================================================================
-- TEARDOWN, IN THE SHAPES IT REALLY HAPPENS IN
-- ========================================================================

t.test('the NPC is re-flagged as a mission entity before it is deleted', function()
    -- DeleteEntity refuses an entity the script does not own, and
    -- ownership can have moved since the spawn. Without the second flag
    -- the delete silently does nothing and the restart leaves another NPC
    -- standing.
    local f = newLobby({ interaction = 'ped' })
    t.equals(f.pedFlags.missionCalls, 1, 'the spawn did not flag the NPC')

    f.fire('onResourceStop', 'crimson_arena')

    t.equals(f.pedFlags.missionCalls, 2, 'the NPC was deleted without being re-flagged first')
    -- The same two flags as the spawn. Called with false the entity is
    -- RELEASED back to the engine instead of claimed, and the delete on
    -- the next line is the one that silently does nothing.
    t.equals(f.pedFlags.mission.a, true, 'the NPC was released rather than claimed before deleting it')
    t.equals(f.pedFlags.mission.b, true)
    t.equals(#f.deleted, 1)
end)

t.test('a lobby with no blip removes no blip', function()
    -- RemoveBlip on a nil handle is a native call with rubbish in it. The
    -- guard is two conditions and both are load-bearing.
    local f = newLobby({
        interaction = 'ped',
        mutate = function(config) config.Lobby.blip.enabled = false end,
    })

    f.fire('onResourceStop', 'crimson_arena')

    t.isNil(f.blipRemoved, 'a blip that was never created was removed anyway')
    t.equals(#f.deleted, 1, 'the NPC was left standing because there was no blip to remove')
end)

t.test('and a marker-only lobby stops cleanly with no NPC to delete', function()
    local f = newLobby({ interaction = 'marker' })

    t.isTrue(f.fire('onResourceStop', 'crimson_arena'))

    t.equals(#f.deleted, 0, 'an NPC that was never spawned was deleted')
    t.isTrue(f.blipRemoved, 'the blip outlived a marker-only lobby')
end)

os.exit(t.summary())
