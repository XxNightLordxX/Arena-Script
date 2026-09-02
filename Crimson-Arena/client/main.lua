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

--- ox_target's export table, or nil when it is not running.
---
--- ASKED FOR RATHER THAN ASSUMED. `exports.ox_target` on a server where
--- ox_target is missing or stopped does not return nil -- it raises, and a
--- raise inside the startup thread below takes the marker, the blip and the
--- fallback command down with the ped, leaving the arena unreachable with
--- nothing in the console pointing at the cause.
--- @return table? targeting
local function targeting()
    if GetResourceState('ox_target') ~= 'started' then return nil end
    return exports.ox_target
end

--- @return boolean spawned -- false means the caller should fall back
local function spawnLobbyPed()
    local ped = Config.Lobby.ped

    -- Checked BEFORE the model loads: an NPC nobody can interact with is
    -- worse than no NPC, because it looks like the resource is working.
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

    target:addLocalEntity(lobbyPed, {
        {
            name = TARGET_NAME,
            label = ped.targetLabel,
            icon = ped.targetIcon,
            distance = ped.targetDistance,
            onSelect = openPanel,
        },
    })

    return true
end

--- An orphaned mission ped survives a resource restart, so every restart
--- would otherwise leave one more identical NPC standing in the lobby.
local function removeLobbyPed()
    if not lobbyPed then return end

    if DoesEntityExist(lobbyPed) then
        -- Same guard as the registration: ox_target can be stopped between
        -- the ped going up and this resource coming down, and an orphaned
        -- NPC left standing is a worse outcome than a skipped de-register.
        local target = targeting()
        if target then target:removeLocalEntity(lobbyPed, TARGET_NAME) end
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

-- Caching only. client/ui.lua registers its own handler for this same
-- event and is the one that pushes the snapshot into the panel; this file
-- owns the cache that match.lua and spectate.lua read. Relaying from here
-- as well would send the panel two copies of every update.
RegisterNetEvent('crimson_arena:client:state', function(newState)
    ArenaState.Set(newState)

    -- The fence round any arena being fought in that this player is not in.
    -- Handed on here rather than read out of the cache by the fence itself,
    -- so a match ending stops it in the same instant the state says so.
    if type(ArenaMatch) == 'table' and type(ArenaMatch.SetKeepOut) == 'function' then
        ArenaMatch.SetKeepOut(type(newState) == 'table' and newState.keepOut or nil)
    end
end)

CreateThread(function()
    local mode = resolveInteraction()

    -- WHICH FIXTURE GOES UP IS THE OPERATOR'S DECISION AND NOBODY ELSE'S.
    -- An NPC that cannot be put up leaves the lobby without one, and says so
    -- in the console; it does not quietly become a ground marker instead.
    -- A resource that silently plays a different setting than the one in the
    -- file is a resource whose config cannot be trusted, and 'both' is
    -- already there for an operator who wants the marker as a safety net.
    --
    -- WRAPPED, because a raise in here used to take everything after it down.
    --
    -- This file already says so about `targeting()`: "a raise inside the
    -- startup thread below takes the marker, the blip and the fallback
    -- command down with the ped, leaving the arena unreachable with nothing
    -- in the console pointing at the cause". That was true of exactly one
    -- call in spawnLobbyPed and the guard was put around that one. Everything
    -- else in there can raise too -- CreatePed on a model the game will not
    -- give, a scenario name it does not know, and above all
    -- ox_target:addLocalEntity, whose shape is another resource's to change.
    --
    -- The symptom is unmistakable and was unexplainable: NO NPC AND NO BLIP,
    -- on a resource that reports itself started. The blip is drawn two lines
    -- below this one.
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

    -- WHERE THE ARENA ACTUALLY WENT, said out loud on every start.
    --
    -- config.lua is where an operator puts these coordinates, and a
    -- coordinate that appears not to take is the most confusing failure this
    -- resource has: the resource works, the panel works, and the arena is somewhere
    -- they did not put it. From outside, "my edit was ignored", "I am looking
    -- at the old spot" and "the folder the server runs is not the one I
    -- edited" all look identical -- nothing was in the console to tell them
    -- apart.
    --
    -- Not gated on Config.Debug: this is one line at start-up, and it is
    -- worth more to the person who needs it than it costs everybody else.
    local where = pedUp and Config.Lobby.ped.coords or Config.Lobby.marker.coords
    local fixture = pedUp and 'NPC' or (mode == 'ped' and 'NOTHING -- see the warning above' or 'ground marker')
    warn(('lobby: %s at %.2f, %.2f, %.2f (interaction = %s).'):format(
        fixture, where.x, where.y, where.z, tostring(mode)))

    if Config.UI.command then
        RegisterCommand(Config.UI.command, openPanel, false)
        TriggerEvent('chat:addSuggestion', '/' .. Config.UI.command, locale('cmd.open_panel'))
    end

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
