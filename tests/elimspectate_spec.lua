--[[
    crimson_arena/tests/elimspectate_spec.lua

    THE ELIMINATED WATCHER WHO LOST THE CAMERA FOR A FRAME.

    An eliminated fighter watches the rest of the round from the arena. When
    every remaining ped read dead or unstreamed for one frame -- two of them
    trading kills, or both out of scope past the grace on the skydome -- the
    camera thread stopped itself with stopSpectating, which keeps them on the
    roster and in the bucket, and Stop() leaves an in-arena ped where it found
    it: invisible, frozen, able to look around and nothing else, until somebody
    finished the round. The quit key already told an eliminated fighter apart
    from an onlooker; the self-stop did not.

    Real client/spectate.lua.
]]
-- Independent verification of finding B on the REAL client/spectate.lua.
-- Three triggers for the self-stop are tried against an ELIMINATED, HELD
-- watcher: (a) every target's ped dead in one frame, (b) every target
-- unstreamed for longer than the 12s grace, (c) the quit key (control).
local t = dofile('testkit.lua')
print('elimspectate_spec')
local Sandbox = dofile('fixtures/sandbox.lua')

local SELF, A, B = 1, 2, 3

local vmeta = {}
vmeta.__index = vmeta
local function vec3(x, y, z) return Sandbox.asVector(setmetatable({ x = x, y = y, z = z or 0.0 }, vmeta), 'vector3') end
vmeta.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vmeta.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
vmeta.__mul = function(a, b)
    if type(a) == 'number' then return vec3(a * b.x, a * b.y, a * b.z) end
    return vec3(a.x * b, a.y * b, a.z * b)
end

local function snapshot(spectating, arenaKey)
    return {
        player = { spectating = spectating, matchId = 'match-1' },
        matches = { { id = 'match-1', arenaKey = arenaKey or 'skydome', players = {
            { id = SELF, alive = false }, { id = A, alive = true }, { id = B, alive = true } } } },
    }
end

local function newFixture(opts)
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local f = { ped = 500, visible = true, localVisible = true, collision = true, frozen = false,
        cams = {}, nextCam = 900, rendering = false, serverEvents = {}, notes = {}, deadPeds = {}, gonePeds = {}, clock = 1000,
        inArena = opts.inArena == true, held = opts.held == true,
        --- What ArenaDispatch recorded before it hid this casualty. A player
        --- who was ordinarily visible when they died, unless a test says so.
        heldState = opts.heldState or { visible = true, collision = true, frozen = false } }
    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        TriggerServerEvent = function(name) f.serverEvents[#f.serverEvents + 1] = name end,
        PlayerPedId = function() return f.ped end, PlayerId = function() return 0 end,
        GetPlayerServerId = function() return SELF end,
        GetPlayerFromServerId = function(id) return id end,
        GetPlayerPed = function(p) if f.gonePeds[1000 + (p or 0)] then return 0 end return 1000 + (p or 0) end,
        NetworkIsPlayerActive = function(p) return p ~= nil end,
        DoesEntityExist = function(e) return e ~= 0 end,
        IsEntityDead = function(ped) return f.deadPeds[ped] == true end,
        GetPlayerName = function(p) return ('Fighter %d'):format(p or 0) end,
        GetEntityCoords = function() return vec3(2344.4, 2565.1, 46.7) end,
        vector3 = vec3,
        GetEntityHeading = function() return 0.0 end,
        GetGameTimer = function() f.clock = f.clock + 16 return f.clock end,
        SetEntityVisible = function(_, on) f.visible = on == true end,
        SetLocalPlayerVisibleLocally = function(on) f.localVisible = on == true end,
        SetEntityCollision = function(_, on) f.collision = on == true end,
        FreezeEntityPosition = function(_, on) f.frozen = on == true end,
        IsEntityVisible = function() return f.visible end,
        GetEntityCollisionDisabled = function() return not f.collision end,
        CreateCam = function() f.nextCam = f.nextCam + 1 f.cams[f.nextCam] = true return f.nextCam end,
        SetCamActive = function() end, SetCamCoord = function() end, SetCamRot = function() end,
        RenderScriptCams = function(on) f.rendering = on == true end,
        DestroyCam = function(h) f.cams[h] = nil end,
        ClearFocus = function() end, SetFocusEntity = function() end, SetFocusPosAndVel = function() end,
        SetEntityCoordsNoOffset = function() end,
        DisableAllControlActions = function() end, EnableControlAction = function() end,
        IsDisabledControlJustPressed = function(_, c) return f.pressed == c end,
        IsDisabledControlPressed = function() return false end,
        GetDisabledControlNormal = function() return 0.0 end,
        ArenaUI = { Notify = function(text) f.notes[#f.notes + 1] = tostring(text) end, UpdateHud = function() end },
        -- READ OFF THE FIXTURE, NOT OFF `opts`, so a test can CHANGE them
        -- part-way through. Both of these change during a single exit from a
        -- round -- leaveArena calls ArenaDispatch.Exit and then
        -- ReleaseDeadState, so "am I in a match" and "is a casualty held"
        -- both go from yes to no between one Stop() and the next -- and
        -- against constants that sequence cannot be written down at all.
        ArenaDispatch = {
            IsInArena = function() return f.inArena == true end,
            IsHoldingDeadState = function() return f.held == true end,
            -- WHAT THE PLAYER REALLY WAS before the hold was taken.
            -- ClearDeadState hides a casualty in the frame they die and
            -- elimination follows death, so by the time the camera starts
            -- the ped IS hidden -- and reading the ped there is reading the
            -- hold, not the player.
            HeldPedState = function()
                if not f.held then return nil end
                return {
                    visible = f.heldState.visible,
                    collision = f.heldState.collision,
                    frozen = f.heldState.frozen,
                }
            end,
        },
    })
    Sandbox.loadInto('../Crimson-Arena/client/spectate.lua', env)
    f.env = env
    f.spectate = env.ArenaSpectate
    f.step = runner.step
    f.fire = function(name, payload) handlers[name](payload) end
    f.camCount = function() local n = 0 for _ in pairs(f.cams) do n = n + 1 end return n end
    f.sent = function(name) for _, e in ipairs(f.serverEvents) do if e == name then return true end end return false end
    return f
end

local function eliminatedWatching(arenaKey)
    local f = newFixture({ inArena = true, held = true })
    f.visible, f.collision, f.frozen = false, false, true
    f.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = true })
    f.fire('crimson_arena:client:state', snapshot('match-1', arenaKey))
    f.step(); f.step()
    t.isTrue(f.spectate.IsActive(), 'premise: watching')
    return f
end


local function onlookerWatching()
    local f = newFixture({ inArena = false, held = false })
    f.fire('crimson_arena:client:state', snapshot('match-1'))
    f.step(); f.step()
    t.isTrue(f.spectate.IsActive(), 'premise: an onlooker is watching')
    return f
end

t.test('DEFECT: every remaining ped dead in ONE frame stopped an eliminated fighter\'s camera', function()
    local f = eliminatedWatching()
    f.deadPeds = { [1000 + A] = true, [1000 + B] = true }
    f.step()
    t.isTrue(f.spectate.IsActive(), 'the camera stopped on a frame where everybody happened to be dead')
    t.isFalse(f.sent('crimson_arena:server:stopSpectating'), 'stopSpectating went out and stranded them')

    -- The next frame finds a respawned fighter, and the watch carries on.
    f.deadPeds = {}
    f.step(); f.step()
    t.isTrue(f.spectate.IsActive(), 'the watch did not recover once somebody was alive again')
end)

t.test('DEFECT: every remaining ped unstreamed past the grace did the same', function()
    local f = eliminatedWatching()
    f.gonePeds = { [1000 + A] = true, [1000 + B] = true }
    for _ = 1, 2000 do f.step() end
    t.isTrue(f.spectate.IsActive(), 'the watch gave up on an eliminated fighter and left them a frozen body')
    t.isFalse(f.sent('crimson_arena:server:stopSpectating'))
end)

t.test('CONTROL: the quit key still sends leaveMatch for an eliminated fighter', function()
    local f = eliminatedWatching()
    f.pressed = 202
    f.step()
    t.isTrue(f.sent('crimson_arena:server:leaveMatch'))
    t.isFalse(f.sent('crimson_arena:server:stopSpectating'))
end)

t.test('CONTROL: an ONLOOKER with nobody left to watch still stops, and is stood back up', function()
    -- Not in the arena, so stopping is right for them, and it must not have
    -- been taken away with the fix.
    local f = onlookerWatching()
    f.deadPeds = { [1000 + A] = true, [1000 + B] = true }
    f.step()
    t.isFalse(f.spectate.IsActive(), 'an onlooker was kept on a camera with nothing to show')
    t.isTrue(f.sent('crimson_arena:server:stopSpectating'))
end)

t.test('CONTROL: one unstreamed target while the other is dead gets the grace and recovers', function()
    local f = eliminatedWatching()
    f.gonePeds = { [1000 + A] = true }
    f.deadPeds = { [1000 + B] = true }
    for _ = 1, 3 do f.step() end
    t.isTrue(f.spectate.IsActive())
    f.gonePeds = {}; f.deadPeds = {}
    for _ = 1, 3 do f.step() end
    t.isTrue(f.spectate.IsActive())
end)

-- ======================================================================
-- INVISIBLE AT THE LOBBY AFTER THE ROUND
--
-- IN THE OWNER'S WORDS, three separate nights: "people are coming out of the
-- arena invisible", "ALSO STILL INVISIBLE AFTER A MATCH ETC", "still
-- spawning in invisible".
--
-- Pinned down by two answers. THEY COULD NOT SEE THEMSELVES EITHER -- which
-- rules out routing buckets and network concealment, both of which only hide
-- you from other people, and leaves SetEntityVisible on the player's own ped.
-- And it started AFTER THE MATCH ENDED, back at the lobby.
--
-- Two defects, either of which does it on its own.
-- ======================================================================

t.test('THE DEFECT: an exitArena that stops the camera EARLY still leaves them visible', function()
    -- `crimson_arena:client:exitArena` HAS TWO HANDLERS. client/match.lua's
    -- runs leaveArena, which is ordered deliberately: ArenaDispatch.Exit()
    -- first, so that the Stop() it calls next sees IsInArena() answer false
    -- and does the watcher's half. THIS file registers a second handler for
    -- the same event, for the onlooker who was never in a round -- leaveArena
    -- returns early for them and would never stop their camera.
    --
    -- Nothing decides which handler runs first. When this file's ran first,
    -- IsInArena() was still true, the restore was skipped, and the record of
    -- what to restore TO was thrown away regardless -- so leaveArena's later
    -- Stop() found `active` false, returned immediately, and nobody ever made
    -- the ped visible again.
    local f = eliminatedWatching()
    t.isFalse(f.visible, 'premise: an eliminated fighter is hidden while they watch')

    -- This file's own handler wins the race, while leaveArena has not run.
    f.fire('crimson_arena:client:exitArena')

    -- And now leaveArena: Exit() first, then the release, then Stop().
    f.inArena = false
    f.held = false
    f.spectate.Stop()

    t.isTrue(f.visible,
        'the early Stop threw away the record of what to put back, so the second one had '
        .. 'nothing to do and the player is standing in the lobby invisible to everybody '
        .. 'including themselves')
end)

t.test('and the camera does NOT park them a second time while finishing that restore', function()
    -- The other half of allowing a second Stop through: it must do the
    -- watcher's half and nothing else. Parking, dropping the scenery and
    -- hiding the HUD all belong to the call that actually took the camera
    -- down, and doing them twice is a teleport the player did not ask for.
    local f = eliminatedWatching()
    f.fire('crimson_arena:client:exitArena')

    local camsAfterFirst = f.camCount()
    f.inArena = false
    f.held = false
    f.spectate.Stop()

    t.equals(f.camCount(), camsAfterFirst, 'the second Stop went through the camera teardown again')
    t.isFalse(f.spectate.IsActive(), 'it turned the camera back on')
end)

t.test('THE SECOND DEFECT: the camera must not hand back the HOLD\'s state as the player\'s own', function()
    -- ClearDeadState hides a casualty in the frame they die. An eliminated
    -- fighter reaches the camera immediately afterwards -- elimination
    -- FOLLOWS death -- so reading the ped here reads a ped this resource has
    -- already hidden, and records "this player was invisible" as the thing to
    -- hand back. Every later restore then faithfully hides them again.
    --
    -- For an eliminated fighter that is the ORDINARY order of events, not an
    -- edge case. ArenaDispatch kept the real reading, taken before it touched
    -- the ped, and is asked for it.
    local f = eliminatedWatching()
    t.isFalse(f.visible, 'premise: the hold has already hidden them')

    -- The hold is released while they are still watching -- a respawn, an
    -- admin revive, or the arena's own 5-second post-match revive sweep.
    f.held = false
    f.inArena = false

    f.spectate.Stop()

    t.isTrue(f.visible,
        'the camera recorded the dead-state hold as "what this player had" and handed '
        .. 'invisibility back to them')
end)

t.test('CONTROL: a player who was DELIBERATELY invisible before watching stays invisible', function()
    -- The regression the other direction, and this file has a long comment
    -- about the last time it happened: an unconditional write put an
    -- admin's god mode out and stood a deliberately-hidden player on show.
    -- Nobody is holding this one, so the ped IS the only record of what they
    -- were, and it says invisible.
    local f = newFixture({ inArena = false, held = false })
    f.visible = false

    f.fire('crimson_arena:client:state', snapshot('match-1'))
    f.step(); f.step()
    t.isTrue(f.spectate.IsActive(), 'premise: they are watching')

    f.spectate.Stop()

    t.isFalse(f.visible, 'the arena put a deliberately invisible player on show')
end)

t.test('CONTROL: an ordinary onlooker still comes back visible', function()
    -- Without this the three above pass on a build that never hides anybody.
    local f = onlookerWatching()
    t.isFalse(f.visible, 'premise: watching hides the watcher')

    f.spectate.Stop()

    t.isTrue(f.visible, 'an onlooker was left invisible by their own camera')
end)

t.test('CONTROL: a fighter still in a LIVE round is not stood up by the camera stopping', function()
    -- The oldest rule in this function, and the one the two fixes above must
    -- not break: an eliminated player watching the rest of the round must not
    -- be put back on the floor, visible, in a live fight.
    local f = eliminatedWatching()

    f.spectate.Stop()

    t.isFalse(f.visible, 'the camera stood an eliminated fighter up in the middle of a live round')
end)

os.exit(t.summary())
