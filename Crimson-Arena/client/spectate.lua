-- Crimson Arena: watching a round you are not in.

ArenaSpectate = {}

local active = false
local camera = nil

local cameraToken = 0

local matchId = nil
local targets = {}
local index = 1

--- Only unfrozen on Stop if this file was the one that froze the ped --
--- client/match.lua freezes players for its own countdown and must not have
--- that undone underneath it.
local frozeLocalPed = false

local focusPoint = nil

local watchedArena = nil
local waitingSince = nil

local STREAM_GRACE_MS = 12000

local parkedFrom = nil

local PARK_DISTANCE_M = 300.0

local ORBIT_DISTANCE_MIN = 1.5
local ORBIT_DISTANCE_MAX = 12.0

local distance = 4.5
local camHeading = 0.0
local camPitch = -12.0

function ArenaSpectate.IsActive()
    return active
end

local function currentTargetId()
    return targets[index]
end

local function currentTargetPed()
    local serverId = currentTargetId()
    if not serverId then return nil end

    local player = GetPlayerFromServerId(serverId)
    if player == -1 or not NetworkIsPlayerActive(player) then return nil end

    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) or IsEntityDead(ped) then return nil end

    return ped
end

local function anyUnstreamed()
    for _, serverId in ipairs(targets) do
        local player = GetPlayerFromServerId(serverId)
        if player == -1 or not NetworkIsPlayerActive(player) then return true end

        local ped = GetPlayerPed(player)
        if ped == 0 or not DoesEntityExist(ped) then return true end
    end
    return false
end

local function parkAtArena()
    if not focusPoint or parkedFrom then return end

    local ped = PlayerPedId()
    local here = GetEntityCoords(ped)
    if not Arena.IsPoint(here) then return end

    local dx = (here.x or 0.0) - focusPoint.x
    local dy = (here.y or 0.0) - focusPoint.y
    local dz = (here.z or 0.0) - focusPoint.z
    if (dx * dx + dy * dy + dz * dz) < (PARK_DISTANCE_M * PARK_DISTANCE_M) then return end

    parkedFrom = { x = here.x, y = here.y, z = here.z }
    SetEntityCoordsNoOffset(ped, focusPoint.x, focusPoint.y, focusPoint.z, false, false, false)
end

local function announceTarget()
    local serverId = currentTargetId()
    if not serverId then return end
    local player = GetPlayerFromServerId(serverId)
    if player == -1 then return end
    ArenaUI.Notify(locale('notify.spectating_player', GetPlayerName(player)), 'info')
end

--- Said once per watch, not once per target: the controls do not change
--- between fighters, and repeating them on every cycle is noise.
---
--- IT NAMES THE QUIT KEY BECAUSE NOTHING ELSE CAN. Every control is disabled
--- while the camera runs, so a spectator cannot open the panel to find the
--- Stop Watching button, and there is no other prompt anywhere in the game
--- telling them which key gets them out.
local function announceControls()
    ArenaUI.Notify(locale('notify.spectate_controls'), 'info')
end

local function cycle(step)
    local count = #targets
    if count == 0 then return false end

    for _ = 1, count do
        index = ((index - 1 + step) % count) + 1
        if currentTargetPed() then return true end
    end

    return false
end

local function runCameraThread()
    cameraToken = cameraToken + 1
    local token = cameraToken

    CreateThread(function()
        while active and cameraToken == token do
            Wait(0)

            local ped = currentTargetPed()
            if not ped then
                if not cycle(1) then
                    local loading = #targets > 0 and anyUnstreamed()
                    if focusPoint and loading then
                        SetFocusPosAndVel(focusPoint.x, focusPoint.y, focusPoint.z, 0.0, 0.0, 0.0)
                        parkAtArena()
                    end

                    waitingSince = waitingSince or GetGameTimer()
                    if focusPoint and loading and (GetGameTimer() - waitingSince) < STREAM_GRACE_MS then
                        Wait(250)
                    else
                        ArenaUI.Notify(locale('notify.spectate_no_targets'), 'warning')
                        TriggerServerEvent('crimson_arena:server:stopSpectating')
                        ArenaSpectate.Stop()
                        return
                    end
                else
                    waitingSince = nil
                    announceTarget()
                    ped = currentTargetPed()
                end
            else
                waitingSince = nil
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
                elseif IsDisabledControlJustPressed(0, 202) then
                    -- THE WAY OUT, AND IT IS THE ONLY ONE THE PLAYER HAS.
                    --
                    -- DisableAllControlActions above takes everything, and
                    -- what is handed back is look, zoom and cycle. There was
                    -- no quit among them. The panel does carry a Stop
                    -- Watching button -- but the panel opens from the lobby
                    -- ped or the ground marker, and a spectator's body is
                    -- frozen, invisible and possibly parked 300m away, so it
                    -- cannot be reached. Somebody who pressed Watch was in
                    -- for the rest of the round.
                    --
                    -- THE SERVER IS TOLD FIRST. Stop() is client-side only:
                    -- it drops the camera and stands nothing up. The server
                    -- keeps its own spectator list, and that list is what
                    -- holds the routing bucket -- so stopping locally
                    -- without saying so leaves a player who is not watching
                    -- anything still instanced into a match they cannot see.
                    --
                    -- WHICH EXIT THIS IS DEPENDS ON WHO IS PRESSING IT, and
                    -- treating the two the same is what stranded people.
                    --
                    -- An ELIMINATED FIGHTER is still in the arena: Stop()
                    -- deliberately leaves their ped invisible, frozen and
                    -- collisionless (see its own IsInArena guard), the arena
                    -- thread keeps the pause menu disabled, and the panel
                    -- opens only from the lobby ped -- which is a kilometre
                    -- away and unreachable. So they got their camera taken
                    -- away and were left with a body that could look around
                    -- and do nothing else until somebody else finished the
                    -- round. Stopping watching is not what they want anyway;
                    -- they want out, and leaving is the path that hands
                    -- their gear back and puts them on their feet.
                    --
                    -- An ONLOOKER is not in the arena, so Stop() stands them
                    -- up where they were and stopSpectating is exactly right.
                    if ArenaDispatch.IsInArena() then
                        TriggerServerEvent('crimson_arena:server:leaveMatch')
                    else
                        TriggerServerEvent('crimson_arena:server:stopSpectating')
                    end
                    ArenaSpectate.Stop()
                    return
                end

                local pitchRad = math.rad(camPitch)
                local headingRad = math.rad(camHeading)
                local flat = math.cos(pitchRad)

                local forward = vector3(-math.sin(headingRad) * flat, math.cos(headingRad) * flat, math.sin(pitchRad))
                local focus = GetEntityCoords(ped) + vector3(0.0, 0.0, 0.5)

                SetCamCoord(camera, focus - forward * distance)
                SetCamRot(camera, camPitch, 0.0, camHeading, 2)

                SetFocusEntity(ped)

                if watchedArena and ArenaMatch and ArenaMatch.EnsureSpectatorScenery then
                    ArenaMatch.EnsureSpectatorScenery(watchedArena.key, watchedArena.factor)
                end
            end
        end
    end)
end

local function refreshTargets(state)
    if not active or type(state) ~= 'table' then return end

    local matches = state.matches
    if type(matches) ~= 'table' then return end

    local watching = currentTargetId()
    local selfId = GetPlayerServerId(PlayerId())
    local rebuilt = {}

    for _, match in ipairs(matches) do
        if match.id == matchId then
            -- WHERE TO POINT THE STREAMER. Taken from the snapshot the
            -- panel already receives rather than from a new field on the
            -- wire, and resolved through the same shared arena table both
            -- realms read, so it cannot disagree with where the fight
            -- actually is.
            focusPoint = Arena.SpectateFocus and Arena.SpectateFocus(match.arenaKey) or nil

            watchedArena = { key = match.arenaKey, factor = match.sizeFactor }

            if type(match.players) == 'table' then
                for _, player in ipairs(match.players) do
                    if player.alive and player.id ~= selfId then
                        rebuilt[#rebuilt + 1] = player.id
                    end
                end
            end
        end
    end

    targets = rebuilt

    index = 1
    for position, serverId in ipairs(targets) do
        if serverId == watching then
            index = position
            break
        end
    end
end

function ArenaSpectate.Start(matchIdentifier)
    if not Arena.IsKey(matchIdentifier) then return end

    if active then
        if matchIdentifier == matchId then return end
        ArenaSpectate.Stop()
    end

    local ped = PlayerPedId()

    matchId = matchIdentifier
    targets = {}
    index = 1
    active = true
    focusPoint = nil
    waitingSince = nil

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

    TriggerServerEvent('crimson_arena:server:requestState')

    ArenaUI.Notify(locale('notify.spectate_started'), 'info')
    announceControls()
end

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

    SetLocalPlayerVisibleLocally(true)

    if not ArenaDispatch.IsInArena() then
        SetEntityVisible(ped, true, false)
        SetEntityCollision(ped, true, true)
        if frozeLocalPed then
            FreezeEntityPosition(ped, false)
            frozeLocalPed = false
        end
    end

    if parkedFrom then
        SetEntityCoordsNoOffset(ped, parkedFrom.x, parkedFrom.y, parkedFrom.z, false, false, false)
        parkedFrom = nil
    end

    if ArenaMatch and ArenaMatch.DropSpectatorScenery then
        ArenaMatch.DropSpectatorScenery()
    end

    if Config.UI.showMatchHud and not ArenaDispatch.IsInArena() then
        ArenaUI.UpdateHud({ visible = false })
    end

    matchId = nil
    targets = {}
    index = 1
    focusPoint = nil
    waitingSince = nil
    watchedArena = nil
end

function ArenaSpectate.Next()
    if not active then return end
    if cycle(1) then announceTarget() end
end

function ArenaSpectate.Previous()
    if not active then return end
    if cycle(-1) then announceTarget() end
end

RegisterNetEvent('crimson_arena:client:eliminated', function(data)
    if type(data) ~= 'table' then return end
    if not Config.Match.spectateOnElimination then return end
    if not data.spectate then return end
    ArenaSpectate.Start(data.matchId)
end)

RegisterNetEvent('crimson_arena:client:state', function(state)
    if type(state) ~= 'table' or type(state.player) ~= 'table' then return end

    local spectating = state.player.spectating
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

RegisterNetEvent('crimson_arena:client:exitArena', function()
    ArenaSpectate.Stop()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ArenaSpectate.Stop()
end)
