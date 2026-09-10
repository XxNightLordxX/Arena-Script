-- Crimson Arena: the arena ped, the doors, and opening the panel.

-- ======================================================================
-- CACHED SERVER STATE
--
-- One snapshot, replaced wholesale on every `state` push. A global rather
-- than an upvalue so there is one copy of the server's truth for the whole
-- client realm to read: nothing outside this file reads it today, and
-- keeping it reachable is what stops the next thing that needs it building
-- a second cache that can disagree with this one.
-- ======================================================================
ArenaState = {}

local snapshot

function ArenaState.Get()
    return snapshot
end

function ArenaState.Set(newState)
    snapshot = type(newState) == 'table' and newState or nil
end

function ArenaState.MatchId()
    local player = snapshot and snapshot.player
    return player and player.matchId or nil
end

function ArenaState.IsInMatch()
    return ArenaState.MatchId() ~= nil
end

function ArenaState.Schedule()
    return snapshot and snapshot.schedule or {}
end

function ArenaState.DoorsShut()
    return ArenaState.Schedule().open == false
end

local TARGET_NAME = 'crimson_arena_lobby'

local pedLabel = nil
local MODEL_LOAD_TIMEOUT_MS = 10000

local lobbyPed
local lobbyBlip

local function warn(message)
    print(('[crimson_arena] %s'):format(message))
end

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

local function targeting()
    if GetResourceState('ox_target') ~= 'started' then return nil end
    return exports.ox_target
end

local function spawnLobbyPed()
    local ped = Config.Lobby.ped

    local target = targeting()
    if not target then
        warn('ox_target is not started, so the lobby NPC would have nobody able to talk to it. ' ..
             'No NPC spawned -- start ox_target, or set ' ..
             "Config.Lobby.interaction = 'marker' if the marker is what you want.")
        return false
    end

    local hash = loadModel(ped.model)
    if not hash then
        warn(("Lobby ped model '%s' would not load -- no NPC spawned."):format(tostring(ped.model)))
        return false
    end

    local coords = ped.coords
    lobbyPed = CreatePed(4, hash, coords.x, coords.y, coords.z - 1.0, coords.w, false, true)
    SetModelAsNoLongerNeeded(hash)

    SetEntityAsMissionEntity(lobbyPed, true, true)
    if ped.freeze then FreezeEntityPosition(lobbyPed, true) end
    if ped.invincible then SetEntityInvincible(lobbyPed, true) end
    if ped.blockEvents then SetBlockingOfNonTemporaryEvents(lobbyPed, true) end
    if ped.scenario then TaskStartScenarioInPlace(lobbyPed, ped.scenario, 0, true) end

    target:addLocalEntity(lobbyPed, {
        {
            name = TARGET_NAME,
            label = ped.targetLabel,
            icon = ped.targetIcon,
            distance = ped.targetDistance,
            onSelect = openPanel,
        },
    })
    pedLabel = ped.targetLabel

    return true
end

local function relabelLobbyPed()
    if not lobbyPed or not DoesEntityExist(lobbyPed) then return end

    local ped = Config.Lobby.ped
    local wanted = ped.targetLabel
    if ArenaState.DoorsShut() then
        local opensAt = ArenaState.Schedule().opensAt
        wanted = type(opensAt) == 'string'
            and locale('match.hours_shut_label', opensAt)
            or locale('match.hours_shut_now_label')
    end

    if wanted == pedLabel then return end

    local target = targeting()
    if not target then return end

    local ok = pcall(function()
        target:removeLocalEntity(lobbyPed, TARGET_NAME)
        target:addLocalEntity(lobbyPed, {
            {
                name = TARGET_NAME,
                label = wanted,
                icon = ped.targetIcon,
                distance = ped.targetDistance,
                onSelect = openPanel,
            },
        })
    end)

    if ok then pedLabel = wanted end
end

local function removeLobbyPed()
    if not lobbyPed then return end

    if DoesEntityExist(lobbyPed) then
        local target = targeting()
        if target then target:removeLocalEntity(lobbyPed, TARGET_NAME) end
        SetEntityAsMissionEntity(lobbyPed, true, true)
        DeleteEntity(lobbyPed)
    end
    lobbyPed = nil
end

local function createBlip(mode)
    local blip = Config.Lobby.blip
    if not blip.enabled then return end

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

local function doorHelpText(marker)
    if not ArenaState.DoorsShut() then return marker.helpText end

    local opensAt = ArenaState.Schedule().opensAt
    if type(opensAt) ~= 'string' then return locale('match.hours_shut_now_help') end
    return locale('match.hours_shut_help', opensAt)
end

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
                    AddTextComponentSubstringPlayerName(doorHelpText(marker))
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

RegisterNetEvent('crimson_arena:client:state', function(newState)
    ArenaState.Set(newState)

    if type(ArenaMatch) == 'table' and type(ArenaMatch.SetKeepOut) == 'function' then
        ArenaMatch.SetKeepOut(type(newState) == 'table' and newState.keepOut or nil)
    end

    relabelLobbyPed()
end)

CreateThread(function()
    Arena.ReportConfigProblems()

    local mode = resolveInteraction()

    local pedUp = false
    if mode == 'ped' or mode == 'both' then
        local ok, result = pcall(spawnLobbyPed)
        if ok then
            pedUp = result == true
        else
            warn(('the lobby NPC could not be spawned: %s. No NPC is standing there -- fix the '
                .. 'error above, or set Config.Lobby.interaction to \'marker\' or \'both\'.')
                :format(tostring(result)))
        end
    end

    if mode == 'marker' or mode == 'both' then startMarkerThread() end
    createBlip(mode)

    local where = pedUp and Config.Lobby.ped.coords or Config.Lobby.marker.coords
    local fixture = pedUp and 'NPC' or (mode == 'ped' and 'NOTHING -- see the warning above' or 'ground marker')
    warn(('lobby: %s at %.2f, %.2f, %.2f (interaction = %s).'):format(
        fixture, where.x, where.y, where.z, tostring(mode)))

    -- NO STATE REQUEST FROM HERE, deliberately. The server reads one as
    -- "a panel just opened" and adds the asker to the set every broadcast is
    -- serialised for; asked on behalf of every client at start, that set
    -- became "everybody connected", for the whole session, for a panel nobody
    -- had touched -- so a ready toggle in a two-player lobby cost the other
    -- ninety-eight players a snapshot each. ArenaUI.Open fetches its own
    -- snapshot before it draws anything, and the cache above is refilled by
    -- every push after that, so nothing here needs one up front.
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    removeLobbyPed()
    removeBlip()
end)
