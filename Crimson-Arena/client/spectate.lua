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

--- Where the watched match is, and how long the camera has been waiting for
--- somebody in it to stream in.
---
--- THE ENGINE MOVES NOBODY ON ITS OWN. Spectating hides the viewer's body
--- and normally leaves it where it was standing -- usually the lobby, and
--- the arena can be the far side of the map or a kilometre straight up.
--- Nothing about a routing bucket streams a player in: the engine streams
--- what is near the FOCUS, and until this existed the only line that set one
--- sat inside
--- `if ped then`. So the camera needed a fighter to be streamed in order to
--- ask for a fighter to be streamed, found none on its very first frame,
--- and stopped with "nobody left to watch" while the round was going on in
--- front of it.
local focusPoint = nil

--- The arena the watched match is being fought in, as the snapshot named it.
--- Set by refreshTargets and read by the camera thread, which is the only
--- place that knows the world around a fighter has actually loaded.
local watchedArena = nil
local waitingSince = nil

--- How long to hold the focus on an empty arena before believing it. Long
--- enough for the slowest legitimate stream-in, short enough that a match
--- that really has emptied does not leave somebody staring at nothing.
local STREAM_GRACE_MS = 12000

--- Where the viewer's body was before it was moved to the arena, or nil if
--- it was never moved. See parkAtArena.
local parkedFrom = nil

--- How far from the arena the viewer's body has to be before it is worth
--- moving. An eliminated fighter is already standing in the round -- inside a
--- boundary of 110m, 180m at the largest the arena grows to -- so nothing at
--- 300m is somebody this applies to, and their body is left exactly where the
--- match put it.
local PARK_DISTANCE_M = 300.0

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

--- Whether any fighter on the list is simply NOT LOADED, as opposed to
--- loaded and out of the round.
---
--- The two look identical to currentTargetPed -- both answer nil -- and
--- they call for opposite handling. Nothing streamed means wait: the arena
--- is somewhere the viewer's body is not, and the engine has not been asked
--- for it yet. Streamed and dead means the round really is over for these
--- people, and holding the camera on them would leave the viewer staring
--- at corpses for the length of the grace window.
--- @return boolean
local function anyUnstreamed()
    for _, serverId in ipairs(targets) do
        local player = GetPlayerFromServerId(serverId)
        if player == -1 or not NetworkIsPlayerActive(player) then return true end

        local ped = GetPlayerPed(player)
        if ped == 0 or not DoesEntityExist(ped) then return true end
    end
    return false
end

--- Puts the viewer's BODY at the arena, once, and remembers where it was.
---
--- THE FOCUS NATIVE IS NOT ENOUGH, and believing it was is why watching a
--- match you are not in showed an empty field.
---
--- SetFocusPosAndVel moves where the engine loads the MAP. It does not move
--- where the SERVER thinks you are, and with OneSync on it is the server that
--- decides which players you are sent at all -- culled around your body, not
--- around your camera. So a viewer standing at the lobby is never sent the
--- fighters however long the camera waits: the grace window below expires,
--- the watch ends, and the panel says there is nobody to watch about a round
--- with people alive in it.
---
--- An eliminated fighter never had this problem, which is exactly why it took
--- a live report to find: their body is already in the arena, so the fighters
--- are already theirs to see. The two paths differ in nothing else.
---
--- The body is invisible, frozen and collisionless by now, so moving it is
--- unobservable -- and Stop puts it back.
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
                    -- NOT NECESSARILY EMPTY -- POSSIBLY NOT LOADED YET.
                    --
                    -- Every fighter resolves through GetPlayerPed, and a
                    -- player the engine has not streamed to this client has
                    -- no ped at all. Nothing moves the viewer on its own, so
                    -- a match across the map -- or the one a kilometre up --
                    -- has nothing streamed around it until something asks
                    -- for it. Believing the first empty frame is what made a
                    -- full arena report "nobody left to watch".
                    --
                    -- So point the streamer at the arena and hold it there.
                    -- A round that really has emptied still ends the watch,
                    -- one grace window later.
                    local loading = #targets > 0 and anyUnstreamed()
                    if focusPoint and loading then
                        SetFocusPosAndVel(focusPoint.x, focusPoint.y, focusPoint.z, 0.0, 0.0, 0.0)
                        -- AND THE BODY, WHICH IS THE HALF THAT MATTERS. The
                        -- line above loads the map; this is what makes the
                        -- server send the fighters at all.
                        parkAtArena()
                    end

                    waitingSince = waitingSince or GetGameTimer()
                    if focusPoint and loading and (GetGameTimer() - waitingSince) < STREAM_GRACE_MS then
                        Wait(250)
                    else
                        ArenaUI.Notify(locale('notify.spectate_no_targets'), 'warning')
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
                    TriggerServerEvent('crimson_arena:server:stopSpectating')
                    ArenaSpectate.Stop()
                    return
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

                -- AND NOW THE PLACE THEY ARE STANDING IN, because there is a
                -- resolved fighter here: the engine has streamed the world
                -- around them, which is the one condition CreateObject needs
                -- and the one refreshTargets could not guarantee.
                --
                -- Idempotent, so a call per frame costs a comparison, and it
                -- refuses to touch scenery an eliminated fighter is already
                -- standing on.
                if watchedArena and ArenaMatch and ArenaMatch.EnsureSpectatorScenery then
                    ArenaMatch.EnsureSpectatorScenery(watchedArena.key, watchedArena.factor)
                end
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
        if match.id == matchId then
            -- WHERE TO POINT THE STREAMER. Taken from the snapshot the
            -- panel already receives rather than from a new field on the
            -- wire, and resolved through the same shared arena table both
            -- realms read, so it cannot disagree with where the fight
            -- actually is.
            focusPoint = Arena.SpectateFocus and Arena.SpectateFocus(match.arenaKey) or nil

            -- WHICH ARENA TO BUILD, remembered rather than built here.
            --
            -- The props are local objects: a fighter's client makes its own
            -- copy on `enterArena`, and a spectator never receives that
            -- event. Being in the match's routing bucket carries the PLAYERS
            -- across and nothing else, so the sky arena was fighters
            -- standing on empty air with no floor and no wall.
            --
            -- NOT BUILT FROM HERE THOUGH. This runs on every state push,
            -- including the first one -- when the watcher's body is still
            -- wherever they were standing, which may be the far side of the
            -- map. CreateObject only produces anything where the world is
            -- streamed, so building now is the "floor a kilometre from the
            -- player" failure this resource has already had once. The camera
            -- thread builds it, at the point where it has a fighter to
            -- follow and the world around them is loaded.
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

    -- The snapshot is the only place the living-player list exists, so ask
    -- for one immediately rather than waiting for the next broadcast.
    TriggerServerEvent('crimson_arena:server:requestState')

    ArenaUI.Notify(locale('notify.spectate_started'), 'info')
    announceControls()
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

    -- PUT BACK WHERE THEY WERE STANDING, and unconditionally: a body is
    -- only ever parked when it was 300m or more from the arena, which is a
    -- player who was never in the round -- so there is no match exit coming
    -- along afterwards to move them home.
    if parkedFrom then
        SetEntityCoordsNoOffset(ped, parkedFrom.x, parkedFrom.y, parkedFrom.z, false, false, false)
        parkedFrom = nil
    end

    -- ONLY WHAT WATCHING PUT UP. A spectator who is also an eliminated
    -- fighter is still standing on the arena's floor, and this refuses to
    -- take that one down -- client/match.lua owns it until they leave.
    if ArenaMatch and ArenaMatch.DropSpectatorScenery then
        ArenaMatch.DropSpectatorScenery()
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
