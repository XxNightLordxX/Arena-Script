--[[
    crimson_arena/client/spectate.lua

    Free-cam spectating for players who have been eliminated and for
    onlookers who never joined.

    THE SHAPE OF IT: a scripted camera orbits whichever living fighter is
    currently selected. Left/right cycles fighters. The local ped is hidden,
    frozen and left out of the way -- it is still standing wherever the
    match put it, and a visible body drifting through the arena would be
    both a distraction and a target.

    WHO DECIDES: the server does. `Start`/`Stop` are also driven off the
    state snapshot's `player.spectating`, so a server that ends a match or
    kicks someone out of spectator mode does not need this file to agree --
    the next snapshot turns the camera off on its own.

    EVERY exit path goes through Stop(). Stop() is idempotent: leaving a
    player invisible with a dead camera is the one failure mode that
    genuinely ruins a session, so it is written to be safe to call at any
    time, including when nothing is running. The camera always goes; the ped
    is put back only when this file is the reason it is down -- an eliminated
    fighter is held by client/dispatch.lua, and client/match.lua releases
    that on the way out of the arena. See Stop().
]]

ArenaSpectate = {}

local active = false
local camera = nil

--- Match being watched, and the server ids of the fighters still alive in
--- it, in a stable order so cycling is predictable.
local matchId = nil
local targets = {}
local index = 1

--- Only unfrozen on Stop if this file was the one that froze the ped --
--- client/match.lua freezes players for its own countdown and must not have
--- that undone underneath it.
local frozeLocalPed = false

local ORBIT_DISTANCE_MIN = 1.5
local ORBIT_DISTANCE_MAX = 12.0

local distance = 4.5
local camHeading = 0.0
local camPitch = -12.0

--- @return boolean
function ArenaSpectate.IsActive()
    return active
end

--- Server id of the fighter currently framed, or nil.
local function currentTargetId()
    return targets[index]
end

--- Resolves the current target to a local ped handle. Returns nil when the
--- player has left, is not streamed in yet, or is a corpse -- all three are
--- handled the same way: move on to somebody worth watching.
local function currentTargetPed()
    local serverId = currentTargetId()
    if not serverId then return nil end

    local player = GetPlayerFromServerId(serverId)
    if player == -1 or not NetworkIsPlayerActive(player) then return nil end

    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) or IsEntityDead(ped) then return nil end

    return ped
end

--- Announces who is on screen. Cheap orientation for the viewer, and the
--- only feedback that a cycle key did anything when two fighters are stood
--- in the same room.
local function announceTarget()
    local serverId = currentTargetId()
    if not serverId then return end
    local player = GetPlayerFromServerId(serverId)
    if player == -1 then return end
    ArenaUI.Notify(locale('notify.spectating_player', GetPlayerName(player)), 'info')
end

--- Moves `index` by `step` and stops on the first target that resolves to a
--- living ped. Bounded by the list length so a lobby full of corpses ends
--- the search instead of spinning.
--- @param step integer
--- @return boolean found
local function cycle(step)
    local count = #targets
    if count == 0 then return false end

    for _ = 1, count do
        index = ((index - 1 + step) % count) + 1
        if currentTargetPed() then return true end
    end

    return false
end

--- The camera thread. It owns nothing but the camera: it reads the target
--- list, and exits the moment `active` goes false, so Stop() needs no
--- handshake with it.
local function runCameraThread()
    CreateThread(function()
        while active do
            Wait(0)

            local ped = currentTargetPed()
            if not ped then
                -- Target died or vanished mid-frame. Cycling here is what
                -- keeps the camera off a corpse without a separate watchdog.
                if not cycle(1) then
                    ArenaUI.Notify(locale('notify.spectate_no_targets'), 'warning')
                    ArenaSpectate.Stop()
                    return
                end
                announceTarget()
                ped = currentTargetPed()
            end

            if ped then
                -- A spectator must not be able to walk their invisible body
                -- around the arena, so everything is off except looking,
                -- cycling and zooming -- read through the Disabled* natives
                -- for exactly that reason.
                DisableAllControlActions(0)
                EnableControlAction(0, 1, true)     -- LookLeftRight
                EnableControlAction(0, 2, true)     -- LookUpDown

                camHeading = camHeading - GetDisabledControlNormal(0, 1) * 8.0
                camPitch = camPitch - GetDisabledControlNormal(0, 2) * 8.0
                if camPitch > 70.0 then camPitch = 70.0 end
                if camPitch < -70.0 then camPitch = -70.0 end

                if IsDisabledControlPressed(0, 241) then distance = distance - 0.2 end
                if IsDisabledControlPressed(0, 242) then distance = distance + 0.2 end
                if distance < ORBIT_DISTANCE_MIN then distance = ORBIT_DISTANCE_MIN end
                if distance > ORBIT_DISTANCE_MAX then distance = ORBIT_DISTANCE_MAX end

                if IsDisabledControlJustPressed(0, 174) then
                    ArenaSpectate.Previous()
                elseif IsDisabledControlJustPressed(0, 175) then
                    ArenaSpectate.Next()
                end

                local pitchRad = math.rad(camPitch)
                local headingRad = math.rad(camHeading)
                local flat = math.cos(pitchRad)

                -- Unit vector the camera looks along; the camera sits that
                -- far back down it, so rotation and position always agree.
                local forward = vector3(-math.sin(headingRad) * flat, math.cos(headingRad) * flat, math.sin(pitchRad))
                local focus = GetEntityCoords(ped) + vector3(0.0, 0.0, 0.5)

                SetCamCoord(camera, focus - forward * distance)
                SetCamRot(camera, camPitch, 0.0, camHeading, 2)

                -- Keeps the world streamed around the fighter rather than
                -- around our own parked body, which may be far away.
                SetFocusEntity(ped)
            end
        end
    end)
end

--- Rebuilds the target list from a state snapshot. Called on every `state`
--- event so eliminations reach the cycle order without a second round trip.
--- @param state table
local function refreshTargets(state)
    if not active or type(state) ~= 'table' then return end

    local matches = state.matches
    if type(matches) ~= 'table' then return end

    local watching = currentTargetId()
    local selfId = GetPlayerServerId(PlayerId())
    local rebuilt = {}

    for _, match in ipairs(matches) do
        if match.id == matchId and type(match.players) == 'table' then
            for _, player in ipairs(match.players) do
                if player.alive and player.id ~= selfId then
                    rebuilt[#rebuilt + 1] = player.id
                end
            end
        end
    end

    targets = rebuilt

    -- Hold the camera on whoever it was already following; the list order
    -- shifts every time somebody dies and re-indexing blind would make the
    -- view jump for no reason the viewer can see.
    index = 1
    for position, serverId in ipairs(targets) do
        if serverId == watching then
            index = position
            break
        end
    end
end

--- @param matchIdentifier string the match to watch
function ArenaSpectate.Start(matchIdentifier)
    if not Arena.IsKey(matchIdentifier) then return end

    if active then
        -- Switching matches without tearing the camera down would leave the
        -- old target list in place.
        if matchIdentifier == matchId then return end
        ArenaSpectate.Stop()
    end

    local ped = PlayerPedId()

    matchId = matchIdentifier
    targets = {}
    index = 1
    active = true

    SetEntityVisible(ped, false, false)
    SetEntityCollision(ped, false, false)
    SetLocalPlayerVisibleLocally(false)
    FreezeEntityPosition(ped, true)
    frozeLocalPed = true

    camHeading = GetEntityHeading(ped)
    camPitch = -12.0
    distance = 4.5

    camera = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamActive(camera, true)
    RenderScriptCams(true, false, 0, true, true)

    runCameraThread()

    -- The snapshot is the only place the living-player list exists, so ask
    -- for one immediately rather than waiting for the next broadcast.
    TriggerServerEvent('crimson_arena:server:requestState')

    ArenaUI.Notify(locale('notify.spectate_started'), 'info')
end

--- Safe at any time, including when not spectating.
---
--- THE CAMERA ALWAYS GOES; THE PED DOES NOT ALWAYS GET UP. Somebody who is
--- watching a match AND is inside one is an eliminated fighter -- the server
--- registers nobody else as both -- and the only thing keeping them out of a
--- live round is the hold client/dispatch.lua has on their ped. This
--- function is reached without the round being over at all: the server can
--- simply take them off the spectator list, and the camera thread below
--- stops itself the moment it runs out of fighters it can follow. Standing
--- that ped up on either of those would hand a dead player back their feet,
--- their collision and the arena loadout they died holding, mid-round.
---
--- So the hold is left exactly as it was found. client/match.lua releases it
--- on the way out of the arena, which is the one place that knows the player
--- is really finished with the round.
function ArenaSpectate.Stop()
    if not active then return end
    active = false

    RenderScriptCams(false, false, 0, true, true)
    if camera then
        DestroyCam(camera, true)
        camera = nil
    end
    ClearFocus()

    local ped = PlayerPedId()

    -- Unconditional, held or not: this file is the only thing that hides the
    -- ped from its OWN player, so nothing else would ever put it back and
    -- they would spend the rest of the session unable to see themselves.
    SetLocalPlayerVisibleLocally(true)

    if not ArenaDispatch.IsInArena() then
        SetEntityVisible(ped, true, false)
        SetEntityCollision(ped, true, true)
        if frozeLocalPed then
            FreezeEntityPosition(ped, false)
            frozeLocalPed = false
        end
    end

    matchId = nil
    targets = {}
    index = 1
end

function ArenaSpectate.Next()
    if not active then return end
    if cycle(1) then announceTarget() end
end

function ArenaSpectate.Previous()
    if not active then return end
    if cycle(-1) then announceTarget() end
end

-- ======================================================================
-- SERVER-DRIVEN ENTRY AND EXIT
-- ======================================================================

--- Elimination is the common case, and it arrives before the next state
--- broadcast does. `spectate` is the server's decision for this match;
--- `spectateOnElimination` is the operator's for the whole resource, and
--- both have to agree before a dead player is put behind a camera.
RegisterNetEvent('crimson_arena:client:eliminated', function(data)
    if type(data) ~= 'table' then return end
    if not Config.Match.spectateOnElimination then return end
    if not data.spectate then return end
    ArenaSpectate.Start(data.matchId)
end)

--- The snapshot is authoritative: it both starts spectating for an onlooker
--- who asked through the panel and stops it when the server says the player
--- is no longer a spectator.
RegisterNetEvent('crimson_arena:client:state', function(state)
    if type(state) ~= 'table' or type(state.player) ~= 'table' then return end

    local spectating = state.player.spectating
    -- `spectating` carries the match id when the server knows it and a bare
    -- true when it only knows the fact; fall back to the match the player
    -- is attached to so the second form still works.
    local target = Arena.IsKey(spectating) and spectating
        or (spectating and Arena.IsKey(state.player.matchId) and state.player.matchId)
        or nil

    if target then
        ArenaSpectate.Start(target)
        refreshTargets(state)
    else
        ArenaSpectate.Stop()
    end
end)

--- The match is over and the player is being put back at the lobby; there
--- is nothing left to watch.
RegisterNetEvent('crimson_arena:client:exitArena', function()
    ArenaSpectate.Stop()
end)

-- A camera and an invisible ped both outlive the script that made them.
-- Restarting the resource while spectating would otherwise leave the player
-- staring at an arena from inside a body nobody can see.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ArenaSpectate.Stop()
end)
