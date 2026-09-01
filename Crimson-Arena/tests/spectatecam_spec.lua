--[[
    crimson_arena/tests/spectatecam_spec.lua

    THE SPECTATOR CAMERA, AS ARITHMETIC RATHER THAN AS A CALL COUNT.

    client/spectate.lua runs an orbit camera around whichever fighter the
    viewer is following. spectate_spec covers what the feature DOES -- who
    can start it, that an eliminated fighter is not handed their feet back,
    that the camera always goes even when the ped stays down. It stubs
    SetCamCoord and SetCamRot to empty functions and answers every input
    native with zero, which is right for the questions it asks: the camera
    thread runs, and nothing it computes is looked at.

    So none of the maths had a test. A mutation sample found thirty-two
    survivors in this file and they cluster in the numbers:

      WHERE THE CAMERA SITS. `focus - forward * distance` puts it behind
      the fighter, down the line it is looking. Change that minus to a
      plus and the camera sits the same distance away on the far side,
      pointed away from the fight -- the viewer watches an empty arena
      with the fighter behind them, and every existing assertion stays
      green because a camera was still created, activated and rendered.

      HOW FAR AWAY. The zoom keys, and the two clamps that stop a viewer
      pushing the camera inside the fighter's head or out into the next
      postcode.

      WHICH WAY IS UP. The pitch clamp at seventy degrees, which is what
      stops the orbit passing over the top and flipping the view.

      WHO IS FRAMED. The cycle arithmetic that wraps at both ends and
      steps over anybody who has left, is not streamed in, or is a corpse.

    This file drives the real camera thread with real mouse and key input
    and reads the coordinates it produces.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local SELF, A, B, C = 1, 2, 3, 4

--- A vector3 with the arithmetic the camera maths actually performs:
--- `coords + offset`, `forward * distance`, `focus - back`.
---
--- The sandbox's stub is a plain { x, y, z }, which is enough for config
--- and not for a single line of this file.
local function vec3(x, y, z)
    local mt
    local function make(a, b, c) return setmetatable({ x = a, y = b, z = c }, mt) end
    mt = {
        __add = function(a, b) return make(a.x + b.x, a.y + b.y, a.z + b.z) end,
        __sub = function(a, b) return make(a.x - b.x, a.y - b.y, a.z - b.z) end,
        __mul = function(a, b)
            if type(b) == 'number' then return make(a.x * b, a.y * b, a.z * b) end
            return make(a.x * b.x, a.y * b.y, a.z * b.z)
        end,
    }
    return make(x, y, z)
end

--- True when two numbers agree to within a whisker. The camera maths runs
--- through sin and cos, so exact equality is the wrong question.
local function near(actual, expected, tolerance)
    return math.abs(actual - expected) <= (tolerance or 0.0001)
end

--- One fresh load of the REAL client/spectate.lua with the camera's output
--- recorded and its input under the test's control.
--- @param opts table? -- { inArena, pedAt }
--- @return table fixture
local function newCam(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 500,
        inArena = opts.inArena == true,
        pedAt = opts.pedAt or vec3(0.0, 0.0, 0.0),
        heading = 0.0,           -- what GetEntityHeading answers on Start
        cams = {},
        nextCam = 900,
        rendering = nil,
        destroyed = {},
        camCoords = nil,         -- the LAST SetCamCoord, as a point
        camRot = nil,            -- the LAST SetCamRot
        focusEntity = nil,
        notes = {},
        serverEvents = {},
        -- Input the test drives. `look` is the mouse; `held` are the zoom
        -- keys; `pressed` are the cycle keys.
        look = { [1] = 0.0, [2] = 0.0 },
        held = {},
        pressed = {},
        deadPeds = {},
        goneServerIds = {},
    }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        TriggerServerEvent = function(name) f.serverEvents[#f.serverEvents + 1] = name end,

        vector3 = vec3,
        PlayerPedId = function() return f.ped end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return SELF end,
        GetPlayerFromServerId = function(serverId)
            if f.goneServerIds[serverId] then return -1 end
            return serverId
        end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        NetworkIsPlayerActive = function(player) return player ~= nil and player ~= -1 end,
        DoesEntityExist = function() return true end,
        IsEntityDead = function(ped) return f.deadPeds[ped] == true end,
        GetPlayerName = function(player) return ('Fighter %d'):format(player or 0) end,
        -- The FIGHTER's position, which is what the camera orbits.
        GetEntityCoords = function() return vec3(f.pedAt.x, f.pedAt.y, f.pedAt.z) end,
        GetEntityHeading = function() return f.heading end,

        -- ARGUMENTS KEPT, NOT JUST THE CALL. Each of these natives takes
        -- a second flag past the on/off, and a stub that drops it cannot
        -- tell a correct call from one that changes the wrong thing.
        SetEntityVisible = function(_ped, on, alsoNetwork)
            f.visible = { on = on, alsoNetwork = alsoNetwork }
        end,
        SetLocalPlayerVisibleLocally = function(on) f.localVisible = on end,
        SetEntityCollision = function(_ped, on, keepPhysics)
            f.collision = { on = on, keepPhysics = keepPhysics }
        end,
        FreezeEntityPosition = function(_ped, on) f.frozen = on end,

        CreateCam = function(name, active)
            f.nextCam = f.nextCam + 1
            f.cams[f.nextCam] = { name = name, active = active }
            return f.nextCam
        end,
        SetCamActive = function(handle, on) f.camActive = { handle = handle, on = on } end,
        SetCamCoord = function(_handle, point) f.camCoords = point end,
        SetCamRot = function(_handle, pitch, roll, heading, order)
            f.camRot = { pitch = pitch, roll = roll, heading = heading, order = order }
        end,
        PointCamAtCoord = function() end,
        RenderScriptCams = function(render, ease, easeTime)
            f.rendering = render
            f.render = { render = render, ease = ease, easeTime = easeTime }
        end,
        DestroyCam = function(handle, flag)
            f.cams[handle] = nil
            f.destroyed[#f.destroyed + 1] = { handle = handle, flag = flag }
        end,
        ClearFocus = function() f.focusEntity = nil end,
        SetFocusEntity = function(entity) f.focusEntity = entity end,

        DisableAllControlActions = function() end,
        EnableControlAction = function(_group, control, enable)
            f.enabled = f.enabled or {}
            f.enabled[control] = enable
        end,
        IsDisabledControlJustPressed = function(_group, control) return f.pressed[control] == true end,
        IsDisabledControlPressed = function(_group, control) return f.held[control] == true end,
        GetDisabledControlNormal = function(_group, control) return f.look[control] or 0.0 end,
        HideHudAndRadarThisFrame = function() end,
        SetTextFont = function() end, SetTextScale = function() end,
        SetTextColour = function() end, SetTextCentre = function() end,
        SetTextOutline = function() end, SetTextEntry = function() end,
        AddTextComponentString = function() end, DrawText = function() end,
        BeginTextCommandDisplayHelp = function() end,
        EndTextCommandDisplayHelp = function() end,

        ArenaUI = { Notify = function(text) f.notes[#f.notes + 1] = tostring(text) end },
        ArenaDispatch = { IsInArena = function() return f.inArena end },
    })

    Sandbox.loadInto('../client/spectate.lua', env)

    f.env = env
    f.spectate = env.ArenaSpectate

    --- One rendered frame of the camera thread.
    ---
    --- THE THREAD OPENS WITH Wait(0), so its first resume only carries it
    --- to that yield and computes nothing. That priming resume is absorbed
    --- here rather than left for every test to remember, so one step is
    --- one frame everywhere below -- and a test that forgot it would read
    --- as "the camera was never positioned" rather than as an off-by-one.
    local primed = false
    f.step = function()
        if not primed then
            primed = true
            runner.step()
        end
        runner.step()
    end
    f.fire = function(name, payload)
        local handler = handlers[name]
        if not handler then return false end
        handler(payload)
        return true
    end

    --- Hands the file a state push shaped the way the server sends one.
    ---
    --- `player.spectating` is not decoration: the state handler reads it to
    --- decide whether this player is watching anything at all, and a push
    --- without it is a push that says "stop spectating". A payload carrying
    --- only `matches` therefore tears the camera down instead of filling
    --- the target list.
    --- @param alive integer[] -- server ids still fighting
    f.roster = function(matchId, alive)
        local players = {}
        for _, id in ipairs(alive) do players[#players + 1] = { id = id, alive = true } end
        f.fire('crimson_arena:client:state', {
            player = { spectating = matchId, matchId = matchId },
            matches = { { id = matchId, players = players } },
        })
    end

    return f
end

--- Starts a watch on `match-1` with two living fighters and one camera
--- frame rendered, so every test below begins from a settled camera.
local function watching(opts)
    local f = newCam(opts)
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B })
    f.step()
    return f
end

-- ========================================================================
-- WHERE THE CAMERA SITS
-- ========================================================================

t.test('the camera sits BEHIND the fighter, down the line it looks along', function()
    -- THE ASSERTION THIS FILE EXISTS FOR. With heading and pitch at zero
    -- the look direction is +y, so the camera belongs at -y: behind the
    -- fighter, looking forward at them. Put it at +y instead and it is
    -- the same distance away, still created, still active, still
    -- rendering -- and pointed at empty arena with the fight behind it.
    local f = newCam({ pedAt = vec3(10.0, 20.0, 30.0) })
    f.heading = 0.0
    f.spectate.Start('match-1')
    f.roster('match-1', { A })
    f.step()

    t.isNotNil(f.camCoords, 'the camera was never positioned')
    t.isTrue(near(f.camCoords.x, 10.0), 'the camera drifted off the fighter\'s axis')

    -- The camera also starts pitched twelve degrees down, so its reach
    -- ALONG THE GROUND is the orbit distance foreshortened by that angle
    -- rather than the whole 4.5 -- the rest of it is the height it gains.
    local flat = math.cos(math.rad(-12.0)) * 4.5
    t.isTrue(near(f.camCoords.y, 20.0 - flat, 0.001),
        ('the camera is not behind the fighter -- it is at y=%.3f, the fighter is at y=20'):format(f.camCoords.y))
    t.isTrue(f.camCoords.y < 20.0, 'the camera is on the far side of the fighter, looking away from them')
end)

t.test('and it frames the fighter\'s HEAD, not their feet', function()
    -- The focus is half a metre above the entity's root. Subtract that
    -- offset instead of adding it and the camera stares at the floor
    -- between their boots.
    local f = newCam({ pedAt = vec3(0.0, 0.0, 30.0) })
    f.heading = 0.0
    f.spectate.Start('match-1')
    f.roster('match-1', { A })

    -- Pitch starts at -12 degrees, so the camera is BELOW the focus by
    -- sin(12) * distance and level with it in the flat plane.
    f.step()

    local expected = 30.0 + 0.5 - math.sin(math.rad(-12.0)) * 4.5
    t.isTrue(near(f.camCoords.z, expected, 0.001),
        ('the camera is at z=%.3f; framing the head puts it at %.3f'):format(f.camCoords.z, expected))
end)

t.test('the camera keeps its distance as it orbits', function()
    -- The invariant that ties position and rotation together: whatever
    -- the viewer does with the mouse, the camera stays exactly `distance`
    -- from what it is looking at.
    local f = watching({ pedAt = vec3(0.0, 0.0, 0.0) })

    for _, look in ipairs({ 0.25, -0.4, 0.9 }) do
        f.look[1] = look
        f.look[2] = look / 2
        f.step()

        local focus = vec3(0.0, 0.0, 0.5)
        local dx, dy, dz = f.camCoords.x - focus.x, f.camCoords.y - focus.y, f.camCoords.z - focus.z
        t.isTrue(near(math.sqrt(dx * dx + dy * dy + dz * dz), 4.5, 0.001),
            'the camera left its orbit -- position and rotation no longer agree')
    end
end)

t.test('and it reports the same angles it is positioned at', function()
    local f = watching()
    f.look[1] = 0.3
    f.step()

    t.isNotNil(f.camRot, 'the camera was never rotated')
    -- Roll is pinned at zero: a spectator camera that rolls is a bug
    -- report about the horizon tilting.
    t.equals(f.camRot.roll, 0.0, 'the spectator camera rolls')
    t.equals(f.camRot.order, 2)
end)

-- ========================================================================
-- HOW FAR AWAY
-- ========================================================================

t.test('the zoom keys move the camera the way the player expects', function()
    -- 241 is scroll up, and scroll up means closer. Reversed, every
    -- viewer's first instinct pushes the camera away from the fight.
    local f = watching({ pedAt = vec3(0.0, 0.0, 0.0) })
    local function reach()
        local dy = f.camCoords.y - 0.0
        local dz = f.camCoords.z - 0.5
        return math.sqrt(dy * dy + dz * dz)
    end

    f.step()
    local before = reach()

    f.held[241] = true
    f.step()
    t.isTrue(reach() < before, 'scrolling up pushed the camera AWAY from the fighter')

    f.held[241] = false
    f.held[242] = true
    f.step(); f.step()
    t.isTrue(reach() > before, 'scrolling down pulled the camera towards the fighter')
end)

t.test('and cannot be pushed inside the fighter', function()
    -- Without the floor the viewer scrolls straight through the fighter
    -- and out the other side, and the camera ends up inside the head it
    -- is meant to be framing.
    local f = watching({ pedAt = vec3(0.0, 0.0, 0.0) })
    f.held[241] = true
    for _ = 1, 200 do f.step() end

    local dy = f.camCoords.y - 0.0
    local dz = f.camCoords.z - 0.5
    local reach = math.sqrt(dy * dy + dz * dz)
    t.isTrue(reach >= 1.5 - 0.001, ('the camera came within %.3f of the fighter'):format(reach))
    t.isTrue(near(reach, 1.5, 0.001), 'the camera stopped somewhere other than the documented minimum')
end)

t.test('and cannot be pushed out of the arena', function()
    local f = watching({ pedAt = vec3(0.0, 0.0, 0.0) })
    f.held[242] = true
    for _ = 1, 200 do f.step() end

    local dy = f.camCoords.y - 0.0
    local dz = f.camCoords.z - 0.5
    local reach = math.sqrt(dy * dy + dz * dz)
    t.isTrue(near(reach, 12.0, 0.001), ('the camera pulled back to %.3f, past the documented maximum'):format(reach))
end)

-- ========================================================================
-- WHICH WAY IS UP
-- ========================================================================

t.test('the pitch stops before the camera passes over the top', function()
    -- Past ninety degrees the orbit crosses the pole and the view flips
    -- upside down. Seventy is where it stops.
    local f = watching()

    f.look[2] = -1.0            -- held, looking up
    for _ = 1, 100 do f.step() end
    t.isTrue(f.camRot.pitch <= 70.0 + 0.001,
        ('the camera pitched to %.1f degrees and went over the top'):format(f.camRot.pitch))
    t.isTrue(near(f.camRot.pitch, 70.0, 0.001), 'the upward clamp is not at seventy degrees')

    f.look[2] = 1.0             -- and back down
    for _ = 1, 100 do f.step() end
    t.isTrue(near(f.camRot.pitch, -70.0, 0.001), 'the downward clamp is not at seventy degrees')
end)

t.test('and the mouse moves the view by a consistent amount', function()
    -- Not a restatement of the constant: two steps must move twice as far
    -- as one, which is what makes the sensitivity a rate rather than a
    -- one-off nudge.
    local f = watching()
    f.step()
    local start = f.camRot.heading

    f.look[1] = 0.1
    f.step()
    local afterOne = f.camRot.heading
    f.step()
    local afterTwo = f.camRot.heading

    local firstStep = afterOne - start
    local secondStep = afterTwo - afterOne
    t.isTrue(math.abs(firstStep) > 0.0, 'moving the mouse did not turn the camera')
    t.isTrue(near(firstStep, secondStep, 0.0001), 'the camera does not turn at a steady rate')
end)

-- ========================================================================
-- WHO IS FRAMED
-- ========================================================================

t.test('Next walks forward through the fighters and wraps round the end', function()
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B, C })
    f.step()

    local seen = {}
    for _ = 1, 4 do
        seen[#seen + 1] = f.focusEntity
        f.spectate.Next()
        f.step()
    end

    t.equals(seen[1], 1000 + A, 'the camera did not start on the first fighter')
    t.equals(seen[2], 1000 + B, 'Next did not move to the second fighter')
    t.equals(seen[3], 1000 + C)
    t.equals(seen[4], 1000 + A, 'Next did not wrap back round to the first fighter')
end)

t.test('and Previous walks backward and wraps round the FRONT', function()
    -- The other end of the same arithmetic, and the one an off-by-one
    -- lands on: stepping back from the first fighter must reach the last,
    -- not index zero.
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B, C })
    f.step()

    f.spectate.Previous()
    f.step()
    t.equals(f.focusEntity, 1000 + C, 'stepping back from the first fighter did not wrap to the last')

    f.spectate.Previous()
    f.step()
    t.equals(f.focusEntity, 1000 + B)
end)

t.test('cycling steps OVER a fighter who has left the world', function()
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B, C })
    f.step()

    f.goneServerIds[B] = true
    f.spectate.Next()
    f.step()

    t.equals(f.focusEntity, 1000 + C, 'the camera parked on a fighter who is no longer there')
end)

t.test('and over a corpse the scoreboard still lists as alive', function()
    -- A camera parked on a dead body is the thing cycling exists to
    -- avoid, and the roster is a broadcast behind the world.
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B, C })
    f.step()

    f.deadPeds[1000 + B] = true
    f.spectate.Next()
    f.step()

    t.equals(f.focusEntity, 1000 + C, 'the camera parked on a corpse')
end)

t.test('a lobby of nothing but corpses ends the search instead of spinning', function()
    -- Bounded by the list length on purpose: an unbounded search here is
    -- a client hang, not a missing frame.
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B })
    f.step()

    f.deadPeds[1000 + A] = true
    f.deadPeds[1000 + B] = true

    f.spectate.Next()
    t.isTrue(true, 'the cycle did not return')
end)

t.test('the viewer is never offered themselves to watch', function()
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { SELF, A })
    f.step()

    t.equals(f.focusEntity, 1000 + A, 'the spectator camera was pointed at the spectator')
end)

t.test('and only fighters from the match being WATCHED are offered', function()
    local f = newCam()
    f.spectate.Start('match-1')
    f.fire('crimson_arena:client:state', {
        player = { spectating = 'match-1', matchId = 'match-1' },
        matches = {
            { id = 'match-2', players = { { id = C, alive = true } } },
            { id = 'match-1', players = { { id = A, alive = true } } },
        },
    })
    f.step()

    t.equals(f.focusEntity, 1000 + A, 'the camera followed somebody from a different match')
end)

t.test('the camera HOLDS on its fighter as the list shrinks around them', function()
    -- THE ONE THE VIEWER NOTICES. The order shifts every time somebody
    -- dies; re-indexing blind makes the view jump to a different fighter
    -- for no reason they can see, in the middle of a fight they were
    -- watching.
    local f = newCam()
    f.spectate.Start('match-1')
    f.roster('match-1', { A, B, C })
    f.step()

    f.spectate.Next()           -- now on B
    f.step()
    t.equals(f.focusEntity, 1000 + B)

    f.roster('match-1', { B, C })   -- A is eliminated and leaves the list
    f.step()

    t.equals(f.focusEntity, 1000 + B, 'the view jumped to another fighter when somebody else died')
end)

-- ========================================================================
-- THE CAMERA'S LIFE
-- ========================================================================

t.test('starting a watch hands the view to the script camera', function()
    local f = newCam()
    f.spectate.Start('match-1')

    t.equals(f.rendering, true, 'the script camera was created but never rendered')
    t.isNotNil(f.camActive, 'the camera was never activated')
    t.equals(f.camActive.on, true)
end)

t.test('and stopping hands it back and destroys the camera', function()
    local f = watching()
    local handle = f.camActive.handle

    f.spectate.Stop()

    t.equals(f.rendering, false, 'the player was left looking through a camera that is gone')
    t.equals(#f.destroyed, 1, 'the camera was abandoned rather than destroyed')
    t.equals(f.destroyed[1].handle, handle)
    t.isNil(f.focusEntity, 'streaming stayed focused on a fighter after the watch ended')
end)

t.test('starting the SAME match again changes nothing', function()
    -- Idempotent on purpose: the server re-announces, and tearing the
    -- camera down and building it again would blink the view for no
    -- reason.
    local f = watching()
    local handle = f.camActive.handle

    f.spectate.Start('match-1')

    t.equals(f.camActive.handle, handle, 'the camera was rebuilt for a match already being watched')
    t.equals(#f.destroyed, 0, 're-announcing the same match tore the camera down')
end)

t.test('but switching to a DIFFERENT match rebuilds it', function()
    -- Without the teardown the old target list stays in place and the
    -- viewer watches the wrong fight.
    local f = watching()
    local handle = f.camActive.handle

    f.spectate.Start('match-2')

    t.equals(#f.destroyed, 1, 'switching matches left the old camera running')
    t.isTrue(f.camActive.handle ~= handle, 'switching matches reused the old camera')
    t.equals(f.rendering, true, 'switching matches left the view off the script camera')
end)

t.test('the camera thread stops itself when the watch ends', function()
    local f = watching()
    f.spectate.Stop()
    f.step()

    local before = f.camCoords
    f.pedAt = vec3(999.0, 999.0, 999.0)
    f.step()

    t.equals(f.camCoords, before, 'the camera thread kept running after the watch ended')
end)


-- ========================================================================
-- THE ARGUMENTS PAST THE FIRST
--
-- Every native below takes a flag after the on/off that decides HOW it
-- does what it was asked. They are the arguments a stub silently drops
-- and nobody ever reads again.
-- ========================================================================

t.test('the view is CUT to the script camera, not eased into it', function()
    -- An eased hand-over swoops the view across the map from wherever the
    -- player was standing to the fight. For a spectator taking over
    -- mid-round that is a second or two of watching scenery.
    local f = newCam()
    f.spectate.Start('match-1')

    t.isNotNil(f.render, 'the view was never handed to the script camera')
    t.equals(f.render.render, true)
    t.equals(f.render.ease, false, 'the hand-over to the spectator camera is eased')
    t.equals(f.render.easeTime, 0, 'the hand-over to the spectator camera takes time')
end)

t.test('and cut back the same way when the watch ends', function()
    local f = watching()
    f.spectate.Stop()

    t.equals(f.render.render, false, 'the player was left looking through a camera that is gone')
    t.equals(f.render.ease, false, 'the hand-back from the spectator camera is eased')
    t.equals(f.render.easeTime, 0)
end)

t.test('the camera is created ALREADY active', function()
    local f = newCam()
    f.spectate.Start('match-1')

    local handle = f.camActive.handle
    t.isNotNil(f.cams[handle], 'no camera exists')
    t.equals(f.cams[handle].name, 'DEFAULT_SCRIPTED_CAMERA')
    t.equals(f.cams[handle].active, true, 'the camera was created inactive')
end)

t.test('and destroyed with the flag that actually frees it', function()
    local f = watching()
    f.spectate.Stop()

    t.equals(#f.destroyed, 1)
    t.equals(f.destroyed[1].flag, true, 'the camera was released rather than destroyed')
end)

t.test('looking up and down is enabled, not merely mentioned', function()
    -- Every control is disabled and exactly two are handed back. Passing
    -- false to the second one leaves a spectator who can turn but not
    -- look up.
    local f = watching()
    f.step()

    t.equals(f.enabled[1], true, 'the spectator cannot look left or right')
    t.equals(f.enabled[2], true, 'the spectator cannot look up or down')
end)

t.test('the spectator is hidden and passes through the world', function()
    -- Both flags on both natives: the second argument to each decides
    -- whether the change reaches the network and whether physics is kept,
    -- and an invisible body that still blocks a doorway is a spectator
    -- standing in the middle of a fight nobody can walk through.
    local f = newCam()
    f.spectate.Start('match-1')

    t.equals(f.visible.on, false, 'the spectator body is still visible')
    t.equals(f.visible.alsoNetwork, false)
    t.equals(f.collision.on, false, 'the spectator body still collides with the fighters')
    t.equals(f.collision.keepPhysics, false)
    t.equals(f.localVisible, false, 'the spectator can still see their own parked body')
    t.equals(f.frozen, true, 'the spectator body was left free to be pushed around')
end)

t.test('and gets all of it back on the way out, when they are not in the arena', function()
    local f = watching({ inArena = false })
    f.spectate.Stop()

    t.equals(f.visible.on, true, 'the player was left invisible')
    t.equals(f.visible.alsoNetwork, false)
    t.equals(f.collision.on, true, 'the player was left walking through walls')
    t.equals(f.collision.keepPhysics, true)
    t.equals(f.localVisible, true, 'the player cannot see themselves')
    t.equals(f.frozen, false, 'the player was left frozen where they stood')
end)

t.test('but an ELIMINATED fighter is left exactly as they were found', function()
    -- Somebody watching a match AND inside one is an eliminated fighter,
    -- and the only thing keeping them out of a live round is the hold on
    -- their ped. Standing them up hands a dead player their feet, their
    -- collision and the loadout they died holding, mid-round.
    local f = watching({ inArena = true })
    f.spectate.Stop()

    t.equals(f.visible.on, false, 'an eliminated fighter was made visible again mid-round')
    t.equals(f.collision.on, false, 'an eliminated fighter was given their collision back mid-round')
    t.equals(f.frozen, true, 'an eliminated fighter was unfrozen mid-round')
    -- They still get to see themselves: this file is the only thing that
    -- hid the ped from its OWN player, so nothing else would put it back.
    t.equals(f.localVisible, true, 'an eliminated fighter cannot see their own body')
end)

-- ========================================================================
-- RUNNING OUT OF PEOPLE TO WATCH
-- ========================================================================

t.test('a lobby where everybody is dead ENDS the watch rather than spinning', function()
    -- The camera thread cycles when its target dies. With nobody left the
    -- cycle has to report failure so the thread can stop -- report
    -- success and it loops forever on a target that resolves to nothing,
    -- which is a client hang rather than a missing frame.
    local f = watching()
    f.deadPeds[1000 + A] = true
    f.deadPeds[1000 + B] = true

    f.step()

    t.isFalse(f.spectate.IsActive(), 'the watch stayed open with nobody left to watch')
    t.equals(f.render.render, false, 'the view was left on a camera following nobody')
end)

t.test('a roster that empties ends the watch too', function()
    -- The other way to run out of people: not corpses the client can see,
    -- but a scoreboard that no longer lists anybody alive. The cycle is
    -- handed an empty list and has to report failure from the length
    -- check rather than walking a list of nothing.
    local f = watching()

    f.roster('match-1', {})
    f.step()

    t.isFalse(f.spectate.IsActive(), 'the watch stayed open on an empty arena')
    t.equals(f.render.render, false, 'the view was left on a camera following an empty list')
end)

t.test('and says so rather than just going black', function()
    local f = watching()
    f.deadPeds[1000 + A] = true
    f.deadPeds[1000 + B] = true

    f.step()

    t.isTrue(#f.notes > 0, 'the watch ended with nothing said about why')
end)

-- ========================================================================
-- STATE PUSHES THAT ARE NOT WHAT THEY LOOK LIKE
-- ========================================================================

t.test('a state push with no player block is ignored, not indexed into', function()
    -- The push is a network payload and the handler reads two levels into
    -- it. Reaching the second level without checking the first is a raise
    -- on the client for every push that arrives mid-teardown.
    local f = watching()

    t.isTrue(f.fire('crimson_arena:client:state', { matches = {} }),
        'the state handler raised on a push carrying no player block')
end)

t.test('and one that is not a table at all is too', function()
    local f = watching()
    for _, bad in ipairs({ 'state', 42, true }) do
        t.isTrue(f.fire('crimson_arena:client:state', bad),
            ('the state handler raised on %s'):format(tostring(bad)))
    end
end)

t.test('a push saying the player is NOT spectating ends the watch', function()
    -- The server's state is the authority on who is watching. A push that
    -- no longer lists this player as a spectator has to close the camera,
    -- or somebody taken off the list keeps an orbit camera on a fight
    -- they are no longer entitled to see.
    local f = watching()
    t.isTrue(f.spectate.IsActive())

    f.fire('crimson_arena:client:state', { player = {}, matches = {} })

    t.isFalse(f.spectate.IsActive(), 'the camera stayed up on a player the server no longer lists as watching')
    t.equals(f.render.render, false, 'the view was left on the spectator camera')
end)

t.test('and one that names the match only by a bare `true` still works', function()
    -- `spectating` carries the match id when the server knows it and a
    -- bare true when it only knows the fact; the fallback reads the match
    -- the player is attached to so the second form is not a silent stop.
    local f = newCam()

    f.fire('crimson_arena:client:state', {
        player = { spectating = true, matchId = 'match-1' },
        matches = { { id = 'match-1', players = { { id = A, alive = true } } } },
    })
    f.step()

    t.isTrue(f.spectate.IsActive(), 'a state push carrying `spectating = true` started nothing')
    t.equals(f.focusEntity, 1000 + A, 'the watch started but followed nobody')
end)

os.exit(t.summary())
