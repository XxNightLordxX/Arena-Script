--[[
    crimson_arena/client/main.lua

    The lobby end of the resource: the NPC (or marker) players walk up to,
    the map blip, the optional command, and the cached copy of the server's
    state snapshot that the other client files read.

    NOTHING HERE DECIDES ANYTHING. Every button this file can reach ends in
    a server event; the snapshot it caches is whatever the server last sent.
    The client's job is to draw the door, not to decide who may walk through
    it.
]]

-- ======================================================================
-- CACHED SERVER STATE
--
-- One snapshot, replaced wholesale on every `state` push. Exposed rather
-- than left as an upvalue because client/match.lua and client/spectate.lua
-- both need to know whether this player is in a match, and neither should
-- keep its own idea of that.
-- ======================================================================
ArenaState = {}

local snapshot

--- The whole last-known snapshot, or nil before the first push.
--- @return table|nil
function ArenaState.Get()
    return snapshot
end

--- Replaces the cache. Only the `state` handler below should call this.
--- @param newState table|nil
function ArenaState.Set(newState)
    snapshot = type(newState) == 'table' and newState or nil
end

--- The match this player belongs to, lobby or live, or nil.
--- @return string|nil
function ArenaState.MatchId()
    local player = snapshot and snapshot.player
    return player and player.matchId or nil
end

--- @return boolean
function ArenaState.IsInMatch()
    return ArenaState.MatchId() ~= nil
end

-- ======================================================================
-- LOBBY FIXTURES
-- ======================================================================

local TARGET_NAME = 'crimson_arena_lobby'
local MODEL_LOAD_TIMEOUT_MS = 10000

local lobbyPed
local lobbyBlip

--- @param message string
local function warn(message)
    print(('[crimson_arena] %s'):format(message))
end

--- 'ped' | 'marker' | 'both', with anything else treated as 'ped'.
--- Called exactly once at start so an operator typo produces one line in
--- the console rather than one per frame.
--- @return string
local function resolveInteraction()
    local mode = Config.Lobby.interaction
    if mode == 'ped' or mode == 'marker' or mode == 'both' then return mode end

    warn(("Config.Lobby.interaction is '%s', which is not 'ped', 'marker' or 'both' -- falling back to 'ped'.")
        :format(tostring(mode)))
    return 'ped'
end

local function openPanel()
    ArenaUI.Open()
end

--- Loads a model with a bounded wait. Returns nil rather than hanging when
--- the model is missing or bad -- a lobby with no NPC is recoverable, a
--- client stuck in a load loop is not.
--- @param model string
--- @return integer|nil hash
local function loadModel(model)
    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then return nil end

    RequestModel(hash)
    local deadline = GetGameTimer() + MODEL_LOAD_TIMEOUT_MS
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(50)
    end

    if not HasModelLoaded(hash) then return nil end
    return hash
end

local function spawnLobbyPed()
    local ped = Config.Lobby.ped
    local hash = loadModel(ped.model)
    if not hash then
        warn(("Lobby ped model '%s' would not load -- no NPC spawned."):format(tostring(ped.model)))
        return
    end

    local coords = ped.coords
    -- config.lua documents `coords.z` as the GROUND z; CreatePed puts the
    -- ped's root there, which leaves it hovering, so drop it a unit.
    lobbyPed = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, coords.w, false, true)
    SetModelAsNoLongerNeeded(hash)

    -- Mission entity so the engine's population culling cannot delete the
    -- NPC out from under the target registration.
    SetEntityAsMissionEntity(lobbyPed, true, true)
    if ped.freeze then FreezeEntityPosition(lobbyPed, true) end
    if ped.invincible then SetEntityInvincible(lobbyPed, true) end
    if ped.blockEvents then SetBlockingOfNonTemporaryEvents(lobbyPed, true) end
    if ped.scenario then TaskStartScenarioInPlace(lobbyPed, ped.scenario, 0, true) end

    exports.ox_target:addLocalEntity(lobbyPed, {
        {
            name = TARGET_NAME,
            label = ped.targetLabel,
            icon = ped.targetIcon,
            distance = ped.targetDistance,
            onSelect = openPanel,
        },
    })
end

--- An orphaned mission ped survives a resource restart, so every restart
--- would otherwise leave one more identical NPC standing in the lobby.
local function removeLobbyPed()
    if not lobbyPed then return end

    if DoesEntityExist(lobbyPed) then
        exports.ox_target:removeLocalEntity(lobbyPed, TARGET_NAME)
        SetEntityAsMissionEntity(lobbyPed, true, true)
        DeleteEntity(lobbyPed)
    end
    lobbyPed = nil
end

--- @param mode string
local function createBlip(mode)
    local blip = Config.Lobby.blip
    if not blip.enabled then return end

    -- Point the blip at whichever fixture the player is actually looking for.
    local coords = mode == 'marker' and Config.Lobby.marker.coords or Config.Lobby.ped.coords

    lobbyBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(lobbyBlip, blip.sprite)
    SetBlipColour(lobbyBlip, blip.color)
    SetBlipScale(lobbyBlip, blip.scale + 0.0)
    SetBlipAsShortRange(lobbyBlip, blip.shortRange == true)
    SetBlipDisplay(lobbyBlip, 4)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(blip.label)
    EndTextCommandSetBlipName(lobbyBlip)
end

local function removeBlip()
    if lobbyBlip and DoesBlipExist(lobbyBlip) then
        RemoveBlip(lobbyBlip)
    end
    lobbyBlip = nil
end

--- The marker path. Draws only inside `drawDistance` and only listens for
--- the key inside `interactDistance`; outside the draw radius it sleeps a
--- full second, because a lobby marker is something a player is near for a
--- few seconds an hour and a per-frame loop the rest of the time is pure
--- waste on every client on the server.
local function startMarkerThread()
    local marker = Config.Lobby.marker
    local center = vector3(marker.coords.x, marker.coords.y, marker.coords.z)

    CreateThread(function()
        while true do
            local sleep = 1000
            local distance = #(GetEntityCoords(PlayerPedId()) - center)

            if distance < marker.drawDistance then
                sleep = 0
                DrawMarker(
                    marker.type,
                    center.x, center.y, center.z,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    marker.size.x, marker.size.y, marker.size.z,
                    marker.color.r, marker.color.g, marker.color.b, marker.color.a,
                    marker.bobUpAndDown == true, false, 2, marker.rotate == true,
                    nil, nil, false
                )

                if distance < marker.interactDistance then
                    BeginTextCommandDisplayHelp('STRING')
                    AddTextComponentSubstringPlayerName(marker.helpText)
                    EndTextCommandDisplayHelp(0, false, true, -1)

                    if IsControlJustReleased(0, marker.key) then
                        openPanel()
                    end
                end
            end

            Wait(sleep)
        end
    end)
end

-- ======================================================================
-- WIRING
-- ======================================================================

RegisterNetEvent('crimson_arena:client:state', function(newState)
    ArenaState.Set(newState)
    ArenaUI.SetState(ArenaState.Get())
end)

CreateThread(function()
    local mode = resolveInteraction()

    if mode == 'ped' or mode == 'both' then spawnLobbyPed() end
    if mode == 'marker' or mode == 'both' then startMarkerThread() end
    createBlip(mode)

    if Config.UI.command then
        RegisterCommand(Config.UI.command, openPanel, false)
        TriggerEvent('chat:addSuggestion', '/' .. Config.UI.command, locale('cmd.open_panel'))
    end

    -- A resource restart leaves clients with a stale (or absent) snapshot,
    -- so ask for a fresh one rather than waiting for the next broadcast.
    TriggerServerEvent('crimson_arena:server:requestState')
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    removeLobbyPed()
    removeBlip()
end)
