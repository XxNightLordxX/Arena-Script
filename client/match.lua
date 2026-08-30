--[[
    crimson_arena/client/match.lua

    Everything that happens between "you have been teleported in" and "you
    are standing back at the lobby ped".

    THE ONE THING THIS FILE MUST NEVER GET WRONG is giving a player back the
    weapons and armour they walked in with. The capture happens before any
    other work on entry and the restore runs on every exit path there is --
    normal end, elimination, disconnect-driven exit, and resource stop.

    Everything else here is enforcement of decisions the server already
    made: it hands out the exact ammo the server resolved, it reports a
    death as a HINT and lets the server decide whether it scored, and its
    match-only threads all die the moment the match does.
]]

local UNARMED = joaat('WEAPON_UNARMED')

-- The match we are physically inside, nil when standing in the world.
local currentMatch
local matchLive = false
local deathReported = false

-- Bumped on every entry so a thread left over from the previous match
-- cannot unfreeze, damage or teleport a player who has since moved on.
local matchToken = 0

-- What the player owned before we touched them, and what we handed them.
local carried
local givenWeapons = {}

--- @param key string
--- @param notifyType string
--- @param ... any -- locale() substitutions
local function notify(key, notifyType, ...)
    lib.notify({
        title = Config.NotifyTitle,
        description = locale(key, ...),
        type = notifyType,
    })
end

-- ======================================================================
-- THE PLAYER'S OWN GEAR
-- ======================================================================

--- Snapshots what the player is carrying. Called first thing on entry,
--- before a single weapon is stripped.
---
--- On an ox_inventory server the ped only ever physically holds the weapon
--- the player has equipped -- the rest sit in the inventory where they are
--- never ours to lose -- so that is the one that matters. The arena
--- catalogue is scanned on top of it so a server not running an inventory
--- resource still gets its guns back.
local function captureOwnLoadout()
    local ped = PlayerPedId()
    local weapons, seen = {}, {}

    local function remember(hash)
        if hash == UNARMED or seen[hash] or not HasPedGotWeapon(ped, hash, false) then return end
        seen[hash] = true
        weapons[#weapons + 1] = { hash = hash, ammo = GetAmmoInPedWeapon(ped, hash) }
    end

    local selected = GetSelectedPedWeapon(ped)
    remember(selected)
    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        remember(joaat(weapon.weapon))
    end
    for _, entry in ipairs(Config.Loadouts.alwaysGive or {}) do
        if entry.weapon then remember(joaat(entry.weapon)) end
    end

    carried = {
        weapons = weapons,
        selected = selected,
        armor = GetPedArmour(ped),
        health = GetEntityHealth(ped),
    }
end

--- Takes back exactly the weapons the arena issued and nothing else -- a
--- blanket wipe here would delete an inventory-managed weapon the player
--- re-equipped mid-match.
--- @param ped integer
local function stripIssuedWeapons(ped)
    for _, hash in ipairs(givenWeapons) do
        RemoveWeaponFromPed(ped, hash)
    end
    givenWeapons = {}
end

--- @param ped integer
local function restoreOwnLoadout(ped)
    if not carried then return end

    -- Health comes back whatever the restore setting says: nobody leaves
    -- the arena as a corpse.
    SetEntityHealth(ped, carried.health)

    if Config.Match.restoreLoadoutOnExit == true then
        for _, weapon in ipairs(carried.weapons) do
            GiveWeaponToPed(ped, weapon.hash, weapon.ammo, false, false)
            SetPedAmmo(ped, weapon.hash, weapon.ammo)
        end
        if carried.selected ~= UNARMED then
            SetCurrentPedWeapon(ped, carried.selected, true)
        end
        SetPedArmour(ped, carried.armor)
    end

    carried = nil
end

--- Hands out the loadout the server resolved. Nothing is re-derived here:
--- the ammo on the wire already went through Arena.ResolveAmmo server-side
--- and is the authoritative number.
--- @param ped integer
--- @param loadout table
local function applyLoadout(ped, loadout)
    if type(loadout) ~= 'table' then return end

    if Config.Match.stripWeaponsOnEntry == true then
        RemoveAllPedWeapons(ped, true)
        givenWeapons = {}
    end

    for _, entry in ipairs(loadout.weapons or {}) do
        local hash = joaat(entry.weapon)
        GiveWeaponToPed(ped, hash, entry.ammo, false, false)
        SetPedAmmo(ped, hash, entry.ammo)

        for _, component in ipairs(entry.components or {}) do
            GiveWeaponComponentToPed(ped, hash, joaat(component))
        end
        if (entry.tint or 0) > 0 then
            SetPedWeaponTintIndex(ped, hash, entry.tint)
        end

        givenWeapons[#givenWeapons + 1] = hash
    end

    SetEntityHealth(ped, loadout.health or Config.Loadouts.health)
    SetPedArmour(ped, loadout.armor or 0)
end

-- ======================================================================
-- PLACEMENT
-- ======================================================================

--- Scatters a spawn point over a disc so more players than spawn points
--- never materialise inside one another. sqrt keeps the distribution even
--- across the disc instead of bunching everyone at the centre.
--- @param spawn table -- vector4-shaped
--- @param radius number
--- @return number, number, number, number
local function scatter(spawn, radius)
    local x, y, z, heading = spawn.x, spawn.y, spawn.z, spawn.w or 0.0
    if radius and radius > 0.0 then
        local angle = math.random() * math.pi * 2.0
        local distance = math.sqrt(math.random()) * radius
        x = x + math.cos(angle) * distance
        y = y + math.sin(angle) * distance
    end
    return x, y, z, heading
end

--- Teleports and waits for the ground to exist. Without the collision wait
--- a player dropped into an unstreamed arena falls through the map.
--- @param ped integer
--- @param x number
--- @param y number
--- @param z number
--- @param heading number
local function placeAt(ped, x, y, z, heading)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, heading)

    RequestCollisionAtCoord(x, y, z)
    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z)
        Wait(0)
    end
end

-- ======================================================================
-- MATCH-ONLY THREADS
--
-- Both loops are gated on `matchLive` AND the entry token, so they end
-- when the round ends and cannot survive into the next one.
-- ======================================================================

--- Per-frame while live: report the death once, and shut the doors a
--- player could otherwise use to walk out of the arena sideways -- the
--- pause menu's map (teleport/respawn exploits and quitting to the lobby
--- both live behind it) and the multiplayer overlay.
local function startLiveThread()
    local token = matchToken

    CreateThread(function()
        while matchLive and matchToken == token do
            DisableControlAction(0, 199, true)      -- P, pause menu
            DisableControlAction(0, 200, true)      -- ESC, pause menu
            DisableControlAction(0, 322, true)      -- ESC, frontend
            DisableControlAction(0, 20, true)       -- Z, multiplayer info
            if IsPauseMenuActive() then
                SetFrontendActive(false)
            end

            local ped = PlayerPedId()
            if not deathReported and IsEntityDead(ped) then
                deathReported = true

                -- A hint, not a verdict. The server checks the claim against
                -- its own record of who was alive and on which team.
                local killerServerId
                local source = GetPedSourceOfDeath(ped)
                if source ~= 0 and source ~= ped and IsEntityAPed(source) and IsPedAPlayer(source) then
                    local index = NetworkGetPlayerIndexFromPed(source)
                    if index and index ~= -1 then
                        killerServerId = GetPlayerServerId(index)
                    end
                end

                TriggerServerEvent('crimson_arena:server:reportDeath', { killerServerId = killerServerId })
            end

            Wait(0)
        end
    end)
end

--- Warn once on leaving the sphere, then bleed the player until they come
--- back. The grace period is what makes it a boundary and not a wall.
--- @param boundary table
local function startBoundaryThread(boundary)
    if type(boundary) ~= 'table' or boundary.enabled ~= true then return end

    local token = matchToken
    local center = vector3(boundary.center.x, boundary.center.y, boundary.center.z)
    local radius = boundary.radius + 0.0
    local graceMs = (boundary.warningSeconds or 0) * 1000
    local damage = boundary.damagePerTick or 0
    local tickMs = boundary.tickMs or 1000
    local leftAt

    CreateThread(function()
        while matchLive and matchToken == token do
            local ped = PlayerPedId()

            if #(GetEntityCoords(ped) - center) > radius then
                if not leftAt then
                    leftAt = GetGameTimer()
                    notify('match.boundary_warning', 'error', boundary.warningSeconds or 0)
                elseif GetGameTimer() - leftAt >= graceMs then
                    ApplyDamageToPed(ped, damage, false)
                end
            elseif leftAt then
                leftAt = nil
            end

            Wait(tickMs)
        end
    end)
end

-- ======================================================================
-- ENTRY / EXIT
-- ======================================================================

--- Puts the world back the way we found it. Synchronous on purpose: it is
--- also the resource-stop path, and a stop handler that yields is a stop
--- handler that does not finish.
--- @param returnCoords table|nil
local function leaveArena(returnCoords)
    if not currentMatch then return end

    currentMatch = nil
    matchLive = false
    deathReported = false
    matchToken = matchToken + 1

    if ArenaSpectate then ArenaSpectate.Stop() end

    ClearOverrideWeather()
    NetworkClearClockTimeOverride()

    local ped = PlayerPedId()
    local coords = returnCoords or Config.Lobby.returnCoords

    if IsEntityDead(ped) then
        NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, coords.w or 0.0, true, false)
        ped = PlayerPedId()
    end

    stripIssuedWeapons(ped)
    restoreOwnLoadout(ped)

    SetEntityCoordsNoOffset(ped, coords.x, coords.y, coords.z, false, false, false)
    SetEntityHeading(ped, coords.w or 0.0)
    FreezeEntityPosition(ped, false)
    ClearPedBloodDamage(ped)

    if Config.UI.showMatchHud then
        ArenaUI.UpdateHud({ visible = false })
    end
end

RegisterNetEvent('crimson_arena:client:enterArena', function(data)
    if type(data) ~= 'table' or type(data.spawn) ~= 'table' then return end

    -- FIRST, always. Everything below this line can destroy gear.
    captureOwnLoadout()

    matchToken = matchToken + 1
    matchLive = false
    deathReported = false
    currentMatch = { id = data.matchId, boundary = data.boundary }

    local token = matchToken
    local ped = PlayerPedId()

    FreezeEntityPosition(ped, true)
    placeAt(ped, scatter(data.spawn, tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius))
    applyLoadout(ped, data.loadout)

    if data.weatherOverride then SetWeatherTypeNowPersist(data.weatherOverride) end
    if type(data.timeOverride) == 'table' then
        NetworkOverrideClockTime(data.timeOverride.hour or 12, data.timeOverride.minute or 0, 0)
    end

    local freezeSeconds = tonumber(data.freezeSeconds) or 0
    if freezeSeconds <= 0 then
        FreezeEntityPosition(ped, false)
    else
        CreateThread(function()
            Wait(math.floor(freezeSeconds * 1000))
            if matchToken == token and currentMatch then
                FreezeEntityPosition(PlayerPedId(), false)
            end
        end)
    end
end)

--- The round is on: this is the only thing that opens the match-only
--- threads, so the boundary never bites during the start countdown.
RegisterNetEvent('crimson_arena:client:matchLive', function()
    if not currentMatch or matchLive then return end

    matchLive = true
    FreezeEntityPosition(PlayerPedId(), false)
    startLiveThread()
    startBoundaryThread(currentMatch.boundary)
end)

RegisterNetEvent('crimson_arena:client:respawn', function(data)
    if not currentMatch or type(data) ~= 'table' or type(data.spawn) ~= 'table' then return end

    local x, y, z, heading = scatter(data.spawn, Config.Match.spawnScatterRadius)
    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

    local ped = PlayerPedId()
    ClearPedBloodDamage(ped)
    placeAt(ped, x, y, z, heading)
    applyLoadout(ped, data.loadout)

    -- Only now: a death that has already been reported must not be
    -- reported again, but the next one must be.
    deathReported = false
end)

RegisterNetEvent('crimson_arena:client:eliminated', function(data)
    if type(data) ~= 'table' then return end

    if data.spectate and ArenaSpectate then
        ArenaSpectate.Start(data.matchId)
    end
end)

RegisterNetEvent('crimson_arena:client:exitArena', function(data)
    leaveArena(type(data) == 'table' and data.returnCoords or nil)
end)

RegisterNetEvent('crimson_arena:client:matchHud', function(data)
    if not Config.UI.showMatchHud then return end

    ArenaUI.UpdateHud({ visible = currentMatch ~= nil, hud = data })
end)

-- A restart while a round is running must not cost anyone their gear, and
-- must not leave them standing in an arena no resource is managing.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    leaveArena(nil)
end)
