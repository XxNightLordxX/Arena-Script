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

-- How often the fighter blips are reconciled against the scoreboard. The
-- server pushes one board a second; the extra pass in between exists for
-- peds that streamed in since the last one, which is worth half a second
-- and no more.
local BLIP_REFRESH_MS = 500

-- The tint for a fighter with no team to take one from: a free-for-all
-- fighter, or one whose side an operator switched off mid-round. 1 is GTA's
-- red, the colour the rest of this resource is keyed to.
local BLIP_FALLBACK_COLOR = 1

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

-- The last scoreboard the server pushed, and the blips drawn from it keyed
-- by server id. Every handle in `playerBlips` is one this file created, and
-- this file is the only thing that can take it away again.
local roster = {}
local playerBlips = {}

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
    -- THE STRONG PATH, taken whenever we hold a capture to put back. Wiping
    -- everything and restoring what they walked in with is the only version
    -- of this that is airtight: removing only what we tracked leaves behind
    -- anything picked up inside the arena, and a player who leaves carrying a
    -- weapon the arena produced is exactly what this must never allow.
    --
    -- Guarded on `carried`, and that guard is the whole safety of it: with no
    -- capture to restore from, a full wipe would take the player's own
    -- weapons and give nothing back. In that case -- a capture that failed,
    -- or an exit path that somehow runs before entry completed -- fall back
    -- to removing only what we know we issued, which can never cost them
    -- anything of their own.
    if carried then
        RemoveAllPedWeapons(ped, true)
    else
        for _, hash in ipairs(givenWeapons) do
            RemoveWeaponFromPed(ped, hash)
        end
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

    -- WHO OWNS THE WEAPON. With ox_inventory running, a weapon is an item and
    -- ox_inventory reconciles the ped against the inventory continuously:
    -- anything handed to the ped here that has no item behind it is taken
    -- back off the player within moments, and SetPedAmmo goes the same way.
    -- server/ammo.lua adds the item instead, magazine and all, and this side
    -- keeps its hands off -- two writers for one weapon is how you get a
    -- player standing in a live round unarmed.
    local inventoryOwnsWeapons = GetResourceState('ox_inventory') == 'started'

    if Config.Match.stripWeaponsOnEntry == true and not inventoryOwnsWeapons then
        -- Skipped under ox_inventory as well: the door already emptied the
        -- player's inventory, and wiping the ped afterwards would delete the
        -- arena weapon the server had just issued as an item.
        RemoveAllPedWeapons(ped, true)
        givenWeapons = {}
    end

    if not inventoryOwnsWeapons then
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
    end

    -- Health and armour are the ped's either way -- no inventory resource
    -- has an opinion about them, and starting every round full is a rule
    -- rather than a loadout choice.
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
-- Every loop this file starts -- the two here and the blip loop below --
-- is gated on `matchLive` AND the entry token, so they end when the round
-- ends and cannot survive into the next one.
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

                -- Reported first, cleared second. The server's record of the
                -- kill must not depend on how fast this runs, and this must
                -- run before any medical script's polling loop comes round
                -- and finds a casualty to send an ambulance to.
                ArenaDispatch.ClearDeadState(ped)
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

            -- A reported death has not been answered yet, so this ped is
            -- either a corpse or one parked inside ClearDeadState's hold --
            -- neither is a fighter who could walk back inside the sphere,
            -- and both are frozen where they fell. Bleeding one kills it a
            -- second time, and the live thread reports and clears a death
            -- once: that second one stays, which is the casualty
            -- clearDeadStateImmediately exists to stop a medical script
            -- ever finding.
            if not deathReported and #(GetEntityCoords(ped) - center) > radius then
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
-- FIGHTER BLIPS
--
-- `Config.Teams.showTeamBlips` and `Config.Teams.showEnemyBlips`, drawn on
-- the living fighters of the match this player is in.
--
-- THE ROSTER IS THE SCOREBOARD the server already pushes for the HUD. There
-- is no second list of who is in the match and nothing extra is asked of
-- the server, so a blip can never disagree with the board about who is
-- alive.
--
-- A BLIP OUTLIVES THE RESOURCE THAT MADE IT -- one left behind is on the
-- map until the player reconnects. So every handle created here is removed
-- on the single exit path in leaveArena, which is also the resource-stop
-- path, rather than by the loop that drew it: a loop from the previous
-- match could wake one last time and take the current match's blips with
-- it.
-- ======================================================================

--- Whether this match could put a blip on the map at all.
---
--- FREE-FOR-ALL HAS NO TEAMMATES, so showTeamBlips has nobody it could ever
--- draw there and showEnemyBlips alone decides. Said here as well as in
--- blipColorFor below so a free-for-all with only team blips on starts no
--- loop at all, rather than one that wakes twice a second to work out it has
--- nothing to do.
--- @param modeKey any
--- @return boolean
local function blipsEnabled(modeKey)
    if Config.Teams.showEnemyBlips == true then return true end
    return Config.Teams.showTeamBlips == true and Arena.ModeUsesTeams(modeKey)
end

--- The colour one scoreboard row should be blipped in, or nil for a row
--- that must not be drawn at all.
---
--- FREE-FOR-ALL IS DECIDED HERE, not left to fall out of a missing team
--- key: no teams means nobody to be a teammate of, so every row takes the
--- enemy branch and showEnemyBlips alone decides. A team mode a player
--- somehow reached without a side of their own lands there too, for the
--- same reason.
--- @param row table -- one entry from the matchHud scoreboard
--- @return integer|nil color
local function blipColorFor(row)
    if not currentMatch or type(row) ~= 'table' then return nil end

    -- `alive` is the server's word for it and the only trustworthy one:
    -- Config.Dispatch.clearDeadStateImmediately stands an arena casualty
    -- straight back up, so IsEntityDead is false for a player who is out.
    if row.alive ~= true then return nil end

    local teamMode = Arena.ModeUsesTeams(currentMatch.modeKey)
    local ownTeam = teamMode and currentMatch.teamKey or nil
    local teammate = teamMode and Arena.IsKey(ownTeam) and row.team == ownTeam

    if teammate then
        if Config.Teams.showTeamBlips ~= true then return nil end
    elseif Config.Teams.showEnemyBlips ~= true then
        return nil
    end

    -- Only a team mode has a tint to hand out. `blipColor` is legitimately 0
    -- for one of the shipped teams, so this leans on ToInt returning nil --
    -- not on the value being falsy -- to spot a team with none set.
    local team = teamMode and Arena.GetTeamByKey(row.team) or nil
    return (team and Arena.ToInt(team.blipColor)) or BLIP_FALLBACK_COLOR
end

--- The local ped for a server id, or nil when that player has left the
--- server or is not streamed in near enough to hang a blip on.
--- @param serverId integer
--- @return integer|nil ped
local function pedForServerId(serverId)
    local player = GetPlayerFromServerId(serverId)
    -- -1 is "nobody here by that id", and GetPlayerPed(-1) is our OWN ped --
    -- taking it would blip this player as every fighter who happens to be
    -- out of scope.
    if player == -1 or not NetworkIsPlayerActive(player) then return nil end

    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped
end

--- @param ped integer
--- @param color integer
--- @param name any -- the scoreboard's name for this fighter, if it had one
--- @return integer blip
local function createBlipOn(ped, color, name)
    local blip = AddBlipForEntity(ped)

    -- A plain dot. The tint is what says whose side this is, and a sprite
    -- with a shape of its own would compete with it for the same answer.
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, color)
    SetBlipDisplay(blip, 4)
    -- Never short range: knowing where somebody is stops being worth
    -- anything at the point you can already see them.
    SetBlipAsShortRange(blip, false)

    if Arena.IsKey(name) then
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(name)
        EndTextCommandSetBlipName(blip)
    end

    return blip
end

--- @param serverId integer
local function removePlayerBlip(serverId)
    local blip = playerBlips[serverId]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    playerBlips[serverId] = nil
end

--- Every blip this file drew, gone. Idempotent, and synchronous so it can
--- run on the resource-stop path.
local function removeAllPlayerBlips()
    for serverId in pairs(playerBlips) do
        removePlayerBlip(serverId)
    end
end

--- Brings what is drawn in line with the last scoreboard: one pass to take
--- away what should no longer be there -- a fighter who died, left, or was
--- never ours to see -- and one to draw what should.
local function refreshBlips()
    local selfId = GetPlayerServerId(PlayerId())
    local wanted = {}

    for _, row in ipairs(roster) do
        local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
        -- Our own dot is already on the map, drawn by the game.
        if serverId and serverId ~= selfId then
            local color = blipColorFor(row)
            if color then wanted[serverId] = { color = color, name = row.name } end
        end
    end

    for serverId in pairs(playerBlips) do
        if not wanted[serverId] then removePlayerBlip(serverId) end
    end

    for serverId, want in pairs(wanted) do
        -- The engine takes an entity blip away with the entity, so a handle
        -- still sitting in the table can already be dead. Forget it, and let
        -- the pass below draw a fresh one when the player streams back in.
        if playerBlips[serverId] and not DoesBlipExist(playerBlips[serverId]) then
            playerBlips[serverId] = nil
        end

        if not playerBlips[serverId] then
            local ped = pedForServerId(serverId)
            if ped then
                playerBlips[serverId] = createBlipOn(ped, want.color, want.name)
            end
        end
    end
end

--- Started with the other match-only loops, on the same token, and left to
--- die with them. Removal is leaveArena's job, not this loop's -- see the
--- section note above.
local function startBlipThread()
    if not currentMatch or not blipsEnabled(currentMatch.modeKey) then return end

    local token = matchToken

    CreateThread(function()
        while matchLive and matchToken == token do
            refreshBlips()
            Wait(BLIP_REFRESH_MS)
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

    -- Before anything below can yield or throw. A blip nobody removes stays
    -- on the map until the player reconnects, and this is the one path every
    -- way out of the arena goes through -- the round ending, walking out
    -- mid-round, and the resource stopping.
    removeAllPlayerBlips()
    roster = {}

    if ArenaSpectate then ArenaSpectate.Stop() end

    -- Police, wanted level and the arena flag all go back to what they were
    -- before this player walked in. Safe to call when nothing was ever
    -- suppressed, which is why it sits on the single shared exit path.
    ArenaDispatch.Exit()

    ClearOverrideWeather()
    NetworkClearClockTimeOverride()

    local ped = PlayerPedId()
    local coords = returnCoords or Config.Lobby.returnCoords

    if IsEntityDead(ped) then
        NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, coords.w or 0.0, true, false)
        ped = PlayerPedId()
    end

    -- Unconditional: an eliminated player is still inside ClearDeadState's
    -- hold at this point, and nobody may be teleported back to the lobby
    -- invisible, invincible or without collision. Idempotent for everyone
    -- else.
    ArenaDispatch.ReleaseDeadState(ped)

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
    currentMatch = {
        id = data.matchId,
        boundary = data.boundary,
        -- Between them these two decide who counts as a teammate for the
        -- blips. Both are re-read through Arena.* at the point of use rather
        -- than trusted as they arrive.
        modeKey = data.modeKey,
        teamKey = data.teamKey,
    }

    -- Last round's board must not seed this round's blips.
    roster = {}

    local token = matchToken
    local ped = PlayerPedId()

    -- Before anything can make a noise. The countdown is still inside the
    -- arena, and a shot fired during it is still a shot fired.
    ArenaDispatch.Enter(data.matchId)

    FreezeEntityPosition(ped, true)
    placeAt(ped, scatter(data.spawn, tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius))

    -- placeAt waits for the ground to stream in, so this handler YIELDS for
    -- up to five seconds and an exitArena can be delivered inside that
    -- window. By the time placeAt returns, leaveArena has already taken this
    -- player home and given them their own weapons back: arming them with
    -- the arena loadout now would strip exactly what was just restored, in
    -- the open world, with nothing left that would ever take it away again.
    if matchToken ~= token or not currentMatch then return end

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
    startBlipThread()
end)

RegisterNetEvent('crimson_arena:client:respawn', function(data)
    if not currentMatch or type(data) ~= 'table' or type(data.spawn) ~= 'table' then return end

    local token = matchToken
    local x, y, z, heading = scatter(data.spawn, Config.Match.spawnScatterRadius)
    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

    local ped = PlayerPedId()
    -- Undoes the frozen, invisible hold ClearDeadState put them in. placeAt
    -- below sets the position, so this only restores the ped's properties.
    ArenaDispatch.ReleaseDeadState(ped)
    ClearPedBloodDamage(ped)
    placeAt(ped, x, y, z, heading)

    -- The same yield the entry handler guards: a round that ended while this
    -- player was being put back on their feet has already restored their own
    -- gear and moved them to the lobby.
    if matchToken ~= token or not currentMatch then return end

    applyLoadout(ped, data.loadout)

    -- Only now: a death that has already been reported must not be
    -- reported again, but the next one must be.
    deathReported = false
end)

RegisterNetEvent('crimson_arena:client:eliminated', function(data)
    if type(data) ~= 'table' then return end

    -- The hold ClearDeadState put them in STAYS, camera or no camera, and
    -- leaveArena is the only thing that releases it. Releasing it here stood
    -- an eliminated player back up, armed, in a live round the moment the
    -- camera stopped -- and the camera stops on its own, whenever the last
    -- fighter it could follow goes out of scope.
    --
    -- Spectating needs nothing released: it hides and freezes a ped that is
    -- already hidden and frozen, and leaving invincibility where it found it
    -- is what keeps the parked body from being killed a second time.
    if data.spectate and ArenaSpectate then
        ArenaSpectate.Start(data.matchId)
    end
end)

RegisterNetEvent('crimson_arena:client:exitArena', function(data)
    leaveArena(type(data) == 'table' and data.returnCoords or nil)
end)

RegisterNetEvent('crimson_arena:client:matchHud', function(data)
    -- Taken BEFORE the HUD switch is read. The scoreboard is the roster the
    -- blip loop draws from, and an operator who turned the overlay off did
    -- not thereby turn the blips off.
    roster = (type(data) == 'table' and type(data.scoreboard) == 'table') and data.scoreboard or {}

    if not Config.UI.showMatchHud then return end

    ArenaUI.UpdateHud({ visible = currentMatch ~= nil, hud = data })
end)

-- A restart while a round is running must not cost anyone their gear, and
-- must not leave them standing in an arena no resource is managing.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    leaveArena(nil)
end)
