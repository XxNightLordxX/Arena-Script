--[[
    crimson_arena/client/match.lua

    Everything that happens between "you have been teleported in" and "you
    are standing back at the lobby ped".

    THE ONE THING THIS FILE MUST NEVER GET WRONG is giving a player back the
    weapons and armour they walked in with. The capture happens before any
    other work on entry and the restore runs on every exit path there is --
    normal end, elimination, disconnect-driven exit, and resource stop.

    Everything else here is enforcement of decisions the server already
    made: it applies the vitals the server resolved, it reports a death as a
    HINT and lets the server decide whether it scored, and its match-only
    threads all die the moment the match does. It never hands the ped a
    weapon -- ox_inventory owns those, and server/ammo.lua issues them as
    items.
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

-- What the player owned before we touched them.
local carried

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
    carried = {
        weapons = weapons,
        selected = selected,
        armor = GetPedArmour(ped),
        health = GetEntityHealth(ped),
    }
end

--- Clears the ped so nothing the arena produced leaves with anybody.
--- @param ped integer
local function stripIssuedWeapons(ped)
    -- GUARDED ON BOTH THE CAPTURE AND THE RESTORE SETTING, because the wipe
    -- and the restore are one decision and were once being made separately.
    --
    -- With Config.Match.restoreLoadoutOnExit off, restoreOwnLoadout below
    -- deliberately gives nothing back -- and this still wiped the ped. The
    -- player walked out having lost every weapon they arrived with, and the
    -- setting that caused it says "give players back the weapons and armour
    -- they walked in with", not "confiscate them". The resource's headline
    -- promise is that a match cannot cost anyone anything.
    --
    -- ox_inventory re-equips the ped from the inventory afterwards, so the
    -- wipe costs a player nothing they still own an item for -- and the door
    -- has already handed their own kit back by the time this runs.
    if carried and Config.Match.restoreLoadoutOnExit == true then
        RemoveAllPedWeapons(ped, true)
    end
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

--- Applies the loadout the server resolved. Nothing is re-derived here, and
--- nothing about the weapons is touched: what this puts on the player is the
--- health and armour every life starts on.
--- What the arena decided this fighter's health and armour should be, and
--- until when it is worth putting them back.
---
--- The arena is not the only thing that writes to them during a round: the
--- revive handoff invites the operator's medical script to stand the player
--- up, and standing somebody up is exactly when such a script sets health
--- and clears armour. This is the arena's own answer, held so it can be the
--- last one rather than the first.
local arenaVitals = { health = nil, armour = nil, until_ = 0 }

--- How long to keep re-asserting them after a revive. Long enough to
--- outlast a medical script's own revive, short enough that armour lost to
--- being shot is never handed back.
local VITALS_REASSERT_MS = 1500

--- @param ped integer
--- @param loadout table
local function applyLoadout(ped, loadout)
    if type(loadout) ~= 'table' then return end

    -- THIS SIDE DOES NOT TOUCH WEAPONS. ox_inventory owns them: a weapon is
    -- an item, and ox_inventory reconciles the ped against the inventory
    -- continuously, so anything handed to the ped here that has no item
    -- behind it is taken back off the player within moments and SetPedAmmo
    -- goes the same way. server/ammo.lua adds the item instead, magazine and
    -- all -- two writers for one weapon is how you get a player standing in
    -- a live round unarmed.
    --
    -- Health and armour are the ped's either way -- no inventory resource
    -- has an opinion about them, and starting every round full is a rule
    -- rather than a loadout choice.
    -- A FLOOR, NOT A READ. The loadout carries both numbers so this side has
    -- one thing to look at, but what it applies is never less than the rule
    -- -- so a loadout that arrived without them, or a stale one built before
    -- the rule existed, still starts this player on full health and a full
    -- plate rather than on whatever happened to be in the table.
    local fullHealth, fullArmour = Arena.StartingVitals()
    local wantedHealth = math.max(Arena.ToInt(loadout.health) or 0, fullHealth)
    local wantedArmour = math.max(Arena.ToInt(loadout.armor) or 0, fullArmour)

    SetEntityHealth(ped, wantedHealth)
    SetPedArmour(ped, wantedArmour)

    -- KEPT, because something else gets the last word a moment later.
    --
    -- The revive handoff runs AFTER this on every life: the arena tells the
    -- operator's medical script to take this player off its casualty list,
    -- and a medical script's revive sets its OWN health and -- almost
    -- always -- zeroes armour. It lands after the loadout, so the fighter
    -- comes back on that script's numbers rather than the arena's: not
    -- fully healed, and with no armour at all, on every life after the
    -- first. Re-asserted below rather than raced with.
    arenaVitals.health = wantedHealth
    arenaVitals.armour = wantedArmour
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
--- @param leaveFrozen boolean -- the freeze state to leave the ped in
--- @param stillWanted fun(): boolean|nil -- re-asked after the yield below
--- @return boolean placed -- false when the caller stopped wanting this
--- @param exactZ boolean|nil -- true where `z` is the surface, not a hint
--- @param floorZ number|nil -- the lowest Z this arena may place anybody at
local function placeAt(ped, x, y, z, heading, leaveFrozen, stillWanted, exactZ, floorZ)
    -- FROZEN IS WHAT STOPS THE FALL. HEIGHT IS ONLY FOR THE PROBE.
    --
    -- Two separate things, and conflating them cost a round: this used to
    -- drop the ped on the exact spawn Z and only then wait for collision, so
    -- for the frames the world took to stream in there was nothing under
    -- them, gravity applied, and they arrived below the map. Entry got away
    -- with it because its caller happened to freeze first; the respawn path
    -- did not.
    --
    -- The fix for THAT is the freeze, not altitude. A frozen ped does not
    -- fall through anything, so the player is held above the spawn point
    -- rather than lifted into the sky -- somebody watching a fighter arrive
    -- fifty metres up has been told where the spawns are.
    --
    -- SO `lift` DOES TWO JOBS, and they want different amounts of it:
    --
    --   on real ground it is only where the PROBE is asked from, a maths
    --   query nobody can see, and the player is put on the answer;
    --
    --   on a floor this resource built there is no probe, so it is where the
    --   player is really left -- above the surface, because a ped placed
    --   level with a prop has its origin inside the prop and drops through
    --   it, which is what was reported. They fall the difference when the
    --   freeze is dropped: on entry that is the end of the countdown, and on
    --   a respawn it is immediately.
    --
    -- Config.Match.spawnHeightOffset is therefore worth turning DOWN once a
    -- sky arena is known to be solid underfoot: it costs nothing on ground
    -- arenas and it is a visible drop on a built one.
    local lift = tonumber(Config.Match.spawnHeightOffset) or 1.0

    FreezeEntityPosition(ped, true)
    SetEntityCoordsNoOffset(ped, x, y, z + lift, false, false, false)
    SetEntityHeading(ped, heading)

    RequestCollisionAtCoord(x, y, z + lift)
    local deadline = GetGameTimer() + 5000
    while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do
        RequestCollisionAtCoord(x, y, z + lift)
        Wait(0)
    end

    -- ASKED AGAIN AFTER THE YIELD, and this is a real bug rather than
    -- caution. That loop can wait five seconds, and a round can end inside
    -- it: the player is sent home, given their own gear back, and put in the
    -- lobby -- and then this function, still parked mid-placement, wakes up
    -- and teleports them BACK to the arena spawn they no longer belong at.
    -- Nothing downstream undid it, because by then the exit had already run.
    --
    -- The freeze is dropped on the way out. The caller's own guard cannot do
    -- it: it does not run until this returns, and by then the damage is a
    -- teleport that has already happened.
    if stillWanted and not stillWanted() then
        FreezeEntityPosition(ped, false)
        return false
    end

    -- AN ARENA THAT KNOWS ITS OWN FLOOR IS NOT SEARCHED FOR ONE.
    --
    -- GetGroundZFor_3dCoord searches DOWNWARD for TERRAIN. It does not know
    -- about props, and it does not stop at the first thing it passes -- so in
    -- an arena a kilometre up, standing on a floor this resource spawned
    -- itself, it happily finds the real map far below, reports success, and
    -- the line beneath teleports the fighter out of the sky and onto the
    -- ground. Both halves behave exactly as documented; the result is an
    -- arena nobody can hold a round in.
    --
    -- So an arena with `exactSpawnZ` is placed at the Z it was given and
    -- nothing is asked. The freeze above still runs -- that is what stops the
    -- fall while the floor streams in -- and it is dropped below as usual.
    if exactZ then
        -- ABOVE THE SURFACE, NOT LEVEL WITH IT.
        --
        -- This used to place the ped at exactly the floor height, which puts
        -- its origin inside the prop it is meant to be standing on -- so the
        -- player spawns in the geometry and drops straight through it. A ped
        -- is not a point that rests on a plane; it needs room to be stood up
        -- in, and the collision of a prop created moments earlier needs a
        -- beat to exist at all.
        --
        -- Dropped from `lift` when the freeze is released, which is what the
        -- countdown is for. Config.Match.spawnHeightOffset tunes it.
        SetEntityCoordsNoOffset(ped, x, y, math.max(z, floorZ or z) + lift, false, false, false)
        FreezeEntityPosition(ped, leaveFrozen == true)
        return true
    end

    -- PROBED FROM HIGH ABOVE -- the query, not the player.
    --
    -- GetGroundZFor_3dCoord searches DOWNWARD from the point it is given. Ask
    -- it from just above a spawn Z that is itself below the surface and the
    -- search starts underground, finds nothing above it, and reports failure
    -- -- leaving the player exactly where they were put, which is under the
    -- map. That is why raising the player did not fix this and asking from
    -- higher up does: the altitude was only ever needed by the search.
    --
    -- These heights are fixed rather than configurable because they are not
    -- a gameplay decision -- nobody is ever at them. They are where the
    -- question is asked from, and asking from further up costs nothing.
    -- Several are tried in the same frame: what makes them robust is
    -- starting from DIFFERENT heights, not from different frames.
    local placed = false
    for _, probe in ipairs({ lift, 50.0, 200.0 }) do
        local found, groundZ = GetGroundZFor_3dCoord(x, y, z + probe, false)
        -- `> -190.0` rejects the answer the game gives when it knows nothing:
        -- the bottom of the world. `floorZ` rejects the other wrong answer --
        -- real terrain that is genuinely there and is nowhere near this
        -- arena, which is what an arena in the sky gets asked about.
        local belowTheArena = floorZ ~= nil and groundZ and groundZ < floorZ
        if found and groundZ and groundZ > -190.0 and not belowTheArena then
            SetEntityCoordsNoOffset(ped, x, y, groundZ + 0.15, false, false, false)
            placed = true
            break
        end
    end

    if not placed then
        -- NOTHING ANSWERED, so this is the one case where height is worth
        -- more than concealment.
        --
        -- The probe failing means the ground here is not known -- which is
        -- exactly the situation that drops a player through the map. A short
        -- fall onto terrain that has since streamed in is survivable and
        -- being under the map is not, so this deliberately uses more
        -- head-room than the ordinary hold above: it is not where players
        -- are put, it is where players are put when the alternative is
        -- falling out of the world.
        SetEntityCoordsNoOffset(ped, x, y,
            math.max(z + math.max(lift, 10.0), floorZ or -math.huge), false, false, false)
    end

    -- Restored explicitly rather than assumed: entry wants the ped held still
    -- for the countdown, a respawn wants it moving immediately, and guessing
    -- wrong either strands a fighter or lets them run before the round.
    FreezeEntityPosition(ped, leaveFrozen == true)
    return true
end

-- ======================================================================
-- IN-ARENA THREADS
--
-- Every loop this file starts is gated on the entry token, so none of them
-- can survive into the next match. What they are gated on BESIDES the token
-- differs, and the difference is the point:
--
--   * the death watch runs from the moment the player is put in the arena,
--     because they are standing in it -- armed, and shootable -- for the
--     whole of the start countdown;
--   * the boundary and the blips wait for `matchLive`, which is deliberate.
--     A sphere that bit during the countdown would bleed fighters who are
--     frozen and cannot walk back inside it, and there is no scoreboard to
--     draw a blip from until the round produces one.
-- ======================================================================

--- A death BEFORE the weapons go live. Nobody is out, nothing is scored,
--- and the player has to be on their feet when the round starts.
---
--- DELIBERATELY NOT REPORTED. ArenaMatch.OnDeath refuses anything from a
--- match that is not 'live' yet, so the report would be dropped on the
--- floor having already set `deathReported` -- and the respawn that clears
--- that flag again would never be sent. The player would then sit out the
--- entire round inside ClearDeadState's hold, invisible and frozen, for a
--- death that never counted. This side settles it alone instead.
---
--- Nor is it gated on Config.Dispatch the way ClearDeadState is: those keys
--- choose who handles a death the round is going to score, and this is not
--- one of those. Left dead here, nothing else would ever pick this player
--- up -- the server has no record that they went down.
--- @param ped integer
local function reviveForCountdown(ped)
    local x, y, z = table.unpack(GetEntityCoords(ped))

    NetworkResurrectLocalPlayer(x, y, z, GetEntityHeading(ped), true, false)

    -- The resurrect can hand back a different handle, so nothing below may
    -- use the one that was passed in.
    local revived = PlayerPedId()
    ClearPedBloodDamage(revived)

    -- Back to exactly what the server sent them in on: full health and a
    -- full plate. Their weapons are items and never left them.
    applyLoadout(revived, currentMatch and currentMatch.loadout)

    -- Held still again, for the reason entry froze them in the first place:
    -- the countdown is still running and dying is not a way to start moving
    -- early. Nothing can strand them here -- both matchLive and leaveArena
    -- unfreeze unconditionally.
    FreezeEntityPosition(revived, true)
end

--- Per-frame from entry until the player is out of the arena: catch their
--- death, and shut the doors they could otherwise use to walk out sideways
--- -- the pause menu's map (teleport/respawn exploits and quitting to the
--- lobby both live behind it) and the multiplayer overlay.
---
--- STARTED AT ENTRY RATHER THAN AT `matchLive`, and that is the whole
--- reason it is a separate function from the two loops below. Players are
--- placed in the arena at the top of the start countdown, and a shot fired
--- during it kills exactly like any other. Watching only from `matchLive`
--- left that kill invisible on every side at once: never reported, so the
--- server never scored it; never cleared, so the operator's medical script
--- found a real corpse and paged an ambulance into a routing bucket it
--- cannot reach; and never resurrected, so the victim entered the round
--- lying on the floor. The blocked controls come earlier for the same
--- reason -- the pause menu was an open exit for the length of the
--- countdown.
--- One arena death, handled exactly once however it was spotted.
---
--- Pulled out of the watch loop below so the game-event hook can call the
--- same code. `deathReported` is what makes calling it twice in one frame
--- harmless, and it is set BEFORE anything else so a second caller inside
--- the same frame finds the door already shut.
--- @param ped integer
local function handleDeath(ped)
    if deathReported or not IsEntityDead(ped) then return end

    if not matchLive then
        -- Still counting down, so there is no round for this to have
        -- happened in. `deathReported` stays down on purpose: the death that
        -- counts is the next one.
        reviveForCountdown(ped)
        return
    end

    deathReported = true

    -- A hint, not a verdict. The server checks the claim against its own
    -- record of who was alive and on which team.
    local killerServerId
    local source = GetPedSourceOfDeath(ped)
    if source ~= 0 and source ~= ped and IsEntityAPed(source) and IsPedAPlayer(source) then
        local index = NetworkGetPlayerIndexFromPed(source)
        if index and index ~= -1 then
            killerServerId = GetPlayerServerId(index)
        end
    end

    TriggerServerEvent('crimson_arena:server:reportDeath', { killerServerId = killerServerId })

    -- Reported first, cleared second. The server's record of the kill must
    -- not depend on how fast this runs, and this must run before any medical
    -- script comes round and finds a casualty to send an ambulance to.
    ArenaDispatch.ClearDeadState(ped)
end

-- ----------------------------------------------------------------------
-- THE SAME FRAME THE DEATH HAPPENS IN, and it is the difference between the
-- ambulance being called and not.
--
-- The watch loop below finds a body on its NEXT pass, which is the next
-- frame at the earliest. A medical script does not wait that long: Qbox's
-- and this server's both hang off `gameEventTriggered` /
-- CEventNetworkEntityDamage, which is raised in the frame the ped dies, and
-- their handler's first question is `IsEntityDead(PlayerPedId())`. Ours ran
-- a frame later, so the answer was always yes -- the player went into the
-- medical script's bleed-out state, which is what puts the "press G for EMS"
-- prompt on screen and is where every 10-52 out of this arena came from.
--
-- Resurrecting from inside the same event dispatch is what makes that
-- question answer NO, and a medical script that answers no does nothing at
-- all: no laststand, no dead metadata, no prompt, no alert to suppress
-- afterwards. It is the only layer in this resource that stops a medical
-- alert at the source rather than chasing it.
--
-- IT DEPENDS ON HANDLER ORDER, and that is worth saying plainly rather than
-- discovering later: handlers on a shared event run in the order their
-- resources registered them, so this wins only when crimson_arena starts
-- BEFORE the medical script in server.cfg. It costs nothing when it loses --
-- the watch loop below still catches the death one frame later, exactly as
-- it did before -- so there is no case where having this is worse.
--
-- Guarded on `currentMatch` and not on a token: this is registered once, at
-- load, and lives for the resource. A death outside a match is not ours.
-- ----------------------------------------------------------------------
AddEventHandler('gameEventTriggered', function(event, data)
    if event ~= 'CEventNetworkEntityDamage' then return end
    if not currentMatch or deathReported then return end

    local victim, victimDied = data[1], data[4]
    if victimDied ~= 1 and victimDied ~= true then return end
    if not victim or not DoesEntityExist(victim) then return end
    if victim ~= PlayerPedId() then return end

    handleDeath(victim)
end)

--- Insist on the arena's health and armour for a moment.
---
--- THE HANDOFF IS THE SIGNAL. Everything the server does at this moment is
--- a request to ANOTHER script to do something to this player's body, and a
--- medical revive does not only clear a death record -- it sets health, and
--- most of them set armour to zero doing it. Rather than guess at which
--- script or how long it takes, the arena puts its own numbers back for a
--- moment afterwards.
local function holdVitals()
    if not currentMatch then return end
    arenaVitals.until_ = GetGameTimer() + VITALS_REASSERT_MS
end

RegisterNetEvent('crimson_arena:client:holdVitals', holdVitals)

local function startArenaThread()
    local token = matchToken

    CreateThread(function()
        while currentMatch and matchToken == token do
            DisableControlAction(0, 199, true)      -- P, pause menu
            DisableControlAction(0, 200, true)      -- ESC, pause menu
            DisableControlAction(0, 322, true)      -- ESC, frontend
            DisableControlAction(0, 20, true)       -- Z, multiplayer info
            if IsPauseMenuActive() then
                SetFrontendActive(false)
            end

            -- NO SHOOTING FROM BEYOND THE GRAVE, and it has to be here
            -- rather than in the hold itself.
            --
            -- ClearDeadState makes the dead player invincible, invisible,
            -- frozen and collisionless, and its own comment says that is to
            -- stop "a player who could shoot during that gap". Not one of
            -- those four natives stops a trigger being pulled: a frozen ped
            -- aims and fires exactly as well as a standing one, and the
            -- rounds are real. That is the split second between dying and
            -- being put back that a player can still kill somebody in.
            --
            -- Firing is a per-frame refusal in this engine -- there is no
            -- flag to set once -- so it belongs on the only per-frame loop
            -- the arena already runs, and it is keyed on the same flag the
            -- respawn clears.
            if deathReported then
                DisablePlayerFiring(PlayerId(), true)
                DisableControlAction(0, 24, true)       -- attack
                DisableControlAction(0, 25, true)       -- aim
                DisableControlAction(0, 257, true)      -- attack, alternate
                DisableControlAction(0, 263, true)      -- melee attack
            end

            -- The arena's numbers, put back over whatever the revive
            -- handoff left behind. Bounded by a deadline rather than run
            -- for the whole round: armour a fighter loses to being SHOT is
            -- theirs to lose, and a loop that restored it continuously
            -- would make everybody bulletproof.
            if not deathReported
                and arenaVitals.until_ > 0
                and GetGameTimer() < arenaVitals.until_
            then
                local ped = PlayerPedId()
                if arenaVitals.health then SetEntityHealth(ped, arenaVitals.health) end
                if arenaVitals.armour then SetPedArmour(ped, arenaVitals.armour) end
            end

            -- The backstop. The hook above catches the ordinary case a frame
            -- earlier; this catches a death no CEventNetworkEntityDamage was
            -- raised for at all -- drowning, a fall, the boundary bleed --
            -- and every case where the hook lost the ordering race.
            handleDeath(PlayerPedId())

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
            -- second time, and the arena thread reports and clears a death
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
-- THE FENCE ROUND A LIVE ARENA
--
-- Isolation already stops an outsider seeing a fight, shooting into it, or
-- being shot out of it -- a live match is in its own routing bucket and that
-- is the strongest answer there is. This is the PHYSICAL half of the same
-- idea: without it somebody who is not in the round can walk into the middle
-- of it, invisible to everybody there, and on a server that has turned
-- isolation off they are standing in a live firefight.
--
-- ONE THREAD FOR THE WHOLE RESOURCE, started once and parked when there is
-- nothing to keep anybody out of. A thread per zone would be a thread per
-- live match on every client on the server.
-- ======================================================================

--- This file's own namespace, which it did not have until the fence needed
--- one. Everything else here is local or an event handler; this is the single
--- thing client/main.lua has to be able to call.
-- Assigned, never read-then-assigned: boot_spec loads every file in manifest
-- order and treats a READ of an undefined global as the error it usually is,
-- so `ArenaMatch or {}` fails the boot for a name this file itself owns.
ArenaMatch = {}

--- The zones the server says this player must stay out of. Replaced whole on
--- every state push rather than merged: a match that has ended must stop
--- fencing immediately, and the absence of a zone is the only way the server
--- says so.
local keepOut = {}

--- Whether a warning has already been given for the zone being stood in, so
--- crossing the line says something once rather than four times a second.
local warnedZone = nil

--- @param zones table[]|nil
function ArenaMatch.SetKeepOut(zones)
    keepOut = type(zones) == 'table' and zones or {}
    if #keepOut == 0 then warnedZone = nil end
end

--- The zone a point is inside, or nil.
--- @return table|nil zone
--- @return number|nil distance -- from the zone centre
local function zoneAt(x, y)
    for _, zone in ipairs(keepOut) do
        local zx, zy = tonumber(zone.x), tonumber(zone.y)
        local radius = tonumber(zone.radius)
        if zx and zy and radius then
            local dx, dy = x - zx, y - zy
            local distance = math.sqrt(dx * dx + dy * dy)
            if distance < radius then return zone, distance end
        end
    end
    return nil, nil
end

CreateThread(function()
    while true do
        local barrier = (Config.Match or {}).keepOutBarrier
        local on = type(barrier) == 'table' and barrier.enabled == true

        -- Parked, not spinning. With no live match anywhere -- which is most
        -- of the time on most servers -- this costs one wake a second.
        if not on or #keepOut == 0 then
            warnedZone = nil
            Wait(1000)
        else
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local zone, distance = zoneAt(coords.x, coords.y)

            if zone then
                local radius = tonumber(zone.radius) or 0
                local push = math.max(1.0, tonumber(barrier.pushBackMetres) or 6.0)

                -- Pushed straight back out along the line from the centre, so
                -- they leave the way they came in rather than being spun
                -- round to somewhere they were not heading.
                --
                -- Dead centre has no direction to push along, so one is
                -- chosen: any edge is better than standing in the middle of
                -- a round.
                local dx, dy = coords.x - zone.x, coords.y - zone.y
                local length = math.max(0.01, distance or 0.01)
                if (distance or 0) < 0.5 then dx, dy, length = 1.0, 0.0, 1.0 end

                local target = radius + push
                local nx = zone.x + (dx / length) * target
                local ny = zone.y + (dy / length) * target

                -- Asked from well above, for the same reason the spawn probe
                -- is: the query starts where it is told and searches DOWN, so
                -- asking from the player's own height finds nothing when the
                -- ground outside is higher than the ground inside.
                local found, groundZ = GetGroundZFor_3dCoord(nx, ny, coords.z + 200.0, false)
                local nz = (found and groundZ and groundZ > -190.0) and (groundZ + 0.15) or coords.z

                SetEntityCoordsNoOffset(ped, nx, ny, nz, false, false, false)

                if barrier.notify ~= false and warnedZone ~= zone.label then
                    warnedZone = zone.label
                    notify('match.keep_out', 'error', zone.label or '')
                end
            else
                warnedZone = nil
            end

            Wait(math.max(50, Arena.ToInt(barrier.tickMs) or 250))
        end
    end
end)

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
--- Whether the OTHER SIDE is drawn permanently, which is the one thing
--- that switches the radar off entirely.
---
--- THIS USED TO ASK THE WRONG QUESTION, and it cost the radar its whole
--- reason for existing. It read:
---
---     if Config.Teams.showEnemyBlips == true then return true end
---     return Config.Teams.showTeamBlips == true and Arena.ModeUsesTeams(modeKey)
---
--- -- which is "is anything drawn permanently", and in the shipped config
--- (team blips on, enemy blips off) it answered TRUE for every team match.
--- The loop below reads it as "draw everything, always", so a team deathmatch
--- put every enemy on the map for the whole round and the sweep never ran
--- once. The setting looked switched on in the panel and did nothing.
---
--- Teammates are not what this decides. They are drawn on every branch of
--- that loop, sweep or no sweep, because your own side is not something the
--- radar reveals -- so `showTeamBlips` has no business here at all.
--- @return boolean
local function permanentEnemyBlips()
    return Config.Teams.showEnemyBlips == true
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
local function blipColorFor(row, includeEnemies)
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
    elseif not includeEnemies and Config.Teams.showEnemyBlips ~= true then
        -- ENEMIES ARE THE RADAR'S TO DRAW, not this pass's. `includeEnemies`
        -- is the sweep saying so for the moment it is lit; the operator's own
        -- showEnemyBlips still overrides it into being permanent.
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
--- Peds currently wearing a team outline, so one can be taken off again.
local outlined = {}

--- Draws a coloured edge round the player's own TEAMMATES.
---
--- The colour is the team's own `color`, the same value the panel is tinted
--- with and the same team the map blip belongs to, so "the outline matches
--- the dot" is true by construction rather than by an operator keeping two
--- fields in step.
---
--- TEAMMATES ONLY, and never the other side. An outline on an enemy would
--- be a wallhack with a colour scheme: it draws THROUGH geometry, which is
--- the whole point of it for finding a friend and exactly the problem with
--- it for finding a target.
local function refreshOutlines()
    local wanted = {}

    if currentMatch and Config.Teams.showTeamOutline == true
        and Arena.ModeUsesTeams(currentMatch.modeKey)
        and Arena.IsKey(currentMatch.teamKey)
    then
        local selfId = GetPlayerServerId(PlayerId())
        local team = Arena.GetTeamByKey(currentMatch.teamKey)
        local r, g, b = Arena.HexToRgb(team and team.color)

        -- No usable colour is a reason not to draw, not a reason to guess:
        -- a white outline round half the lobby says nothing about sides.
        if r then
            for _, row in ipairs(roster) do
                local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
                if serverId and serverId ~= selfId and row.alive == true
                    and row.team == currentMatch.teamKey
                then
                    local ped = pedForServerId(serverId)
                    if ped then
                        wanted[ped] = true
                        if not outlined[ped] then
                            SetEntityDrawOutline(ped, true)
                            outlined[ped] = true
                        end
                    end
                end
            end

            -- Set every pass rather than once: it is global state on the
            -- outline shader, and anything else on the server that draws an
            -- outline sets it too.
            SetEntityDrawOutlineColor(r, g, b, 255)

            -- AND THE SHADER THAT ACTUALLY DRAWS IT THROUGH A WALL.
            --
            -- The note above this function says the outline draws through
            -- geometry and that this is the whole point of it -- knowing
            -- where your side is, not where the corner is. Nothing switched
            -- that on. SetEntityDrawOutline alone uses the DEFAULT shader,
            -- which is occluded by everything in front of it and faint even
            -- in the open, so a teammate behind any cover at all showed
            -- nothing and a teammate in the open showed almost nothing.
            --
            -- Shader 1 is the see-through variant. Global, like the colour,
            -- and set on the same schedule for the same reason.
            SetEntityDrawOutlineShader(1)
        end
    end

    for ped in pairs(outlined) do
        if not wanted[ped] then
            if DoesEntityExist(ped) then SetEntityDrawOutline(ped, false) end
            outlined[ped] = nil
        end
    end
end

--- Takes every outline off. Part of the same teardown the blips use, and for
--- the same reason: an outline outlives the match that drew it.
local function removeAllOutlines()
    for ped in pairs(outlined) do
        if DoesEntityExist(ped) then SetEntityDrawOutline(ped, false) end
    end
    outlined = {}
end

--- @param includeEnemies boolean|nil -- true only while a radar sweep is lit
local function refreshBlips(includeEnemies)
    local selfId = GetPlayerServerId(PlayerId())
    local wanted = {}

    for _, row in ipairs(roster) do
        local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
        -- Our own dot is already on the map, drawn by the game.
        if serverId and serverId ~= selfId then
            local color = blipColorFor(row, includeEnemies)
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

-- ----------------------------------------------------------------------
-- THE RADAR
--
-- A permanent dot on every fighter turns a round into a map to be read
-- rather than a place to be searched, so the blips above ship off and this
-- is what replaces them: a SWEEP. Every interval the positions appear for
-- under a second and then go dark again, so what a player gets is where
-- everybody WAS a moment ago -- long enough to plan with, stale enough to
-- be wrong about.
--
-- THE HOST'S SETTING, NOT EACH PLAYER'S.
--
-- This used to be a per-player toggle kept only on this side, on the
-- reasoning that a display setting nobody else can see does not belong on
-- the wire. That reasoning was wrong about what the setting is: a radar is
-- not a display preference, it is how much of the other side a round lets
-- you see, and letting every fighter decide that for themselves made a
-- match only as dark as its least patient player.
--
-- So it comes in with `enterArena`, the host having set it on the match,
-- and this side holds no preference of its own to disagree with it.
-- ----------------------------------------------------------------------

--- @return table
local function radarConfig()
    local block = (Config.Match or {}).radar
    return type(block) == 'table' and block or {}
end

--- What the match said when we entered it. nil between rounds, which is
--- the same as off: there is no sweep to run outside a match.
local radarForMatch = nil

--- @return boolean
local function radarOn()
    -- The operator's switch still wins. A server that has turned the radar
    -- off entirely does not run one because a host's stale panel said so.
    if radarConfig().allowChoose == false then return radarConfig().defaultOn == true end
    return radarForMatch == true
end

--- Set from `enterArena` -- never from the panel, which no longer has a
--- control that reaches this side. Takes effect on the next sweep rather
--- than immediately: the sweep interval is the whole point of the setting,
--- and a switch that lit one instantly would be a way around it.
--- @param on boolean
function ArenaMatch.SetRadar(on)
    radarForMatch = on == true
    if not radarForMatch then removeAllPlayerBlips() end
end

--- Started with the other match-only loops, on the same token, and left to
--- die with them. Removal is leaveArena's job, not this loop's -- see the
--- section note above.
local function startBlipThread()
    if not currentMatch then return end

    local token = matchToken
    local permanent = permanentEnemyBlips()

    CreateThread(function()
        while matchLive and matchToken == token do
            -- TEAMMATES ARE ALWAYS DRAWN, sweep or no sweep. Your own side
            -- is not something the radar reveals -- you know where your team
            -- is because they are your team.
            refreshOutlines()

            if permanent then
                -- The old behaviour, for a server that asked for it.
                refreshBlips(true)
                Wait(BLIP_REFRESH_MS)
            elseif radarOn() then
                -- LIT, then DARK. The removal is not optional and not
                -- deferred to the next pass: a sweep that failed to clear
                -- itself would be a permanent blip with extra steps.
                -- LIT: teammates and enemies together, briefly.
                refreshBlips(true)
                Wait(math.max(100, Arena.ToInt(radarConfig().visibleMs) or 800))

                -- DARK: the enemies go, the teammates come straight back --
                -- outlines with them, because the lit phase above is a single
                -- wait and this is the far side of it. Without this the
                -- longest gap between reconciling your own side is the lit
                -- phase plus a slice rather than a slice.
                removeAllPlayerBlips()
                refreshBlips(false)
                refreshOutlines()

                local interval = math.max(1000, Arena.ToInt(radarConfig().intervalMs) or 30000)
                local visible = math.max(100, Arena.ToInt(radarConfig().visibleMs) or 800)
                local dark = math.max(500, interval - visible)

                -- THE DARK PHASE IS SLICED, NOT ONE LONG WAIT, and that is
                -- about the TEAMMATES rather than the radar.
                --
                -- refreshOutlines runs at the top of this loop, so whatever
                -- this branch waits IS the rate at which your own side is
                -- reconciled. Waiting the whole interval in one go dropped
                -- that from twice a second to once every thirty on the
                -- shipped radar settings -- so a teammate who was eliminated
                -- kept a coloured edge drawn through walls for half a minute
                -- after the scoreboard said they were out, one who respawned
                -- onto a new ped had no outline at all until the loop came
                -- round, and anybody still streaming in when the round went
                -- live went unhazed for the opening thirty seconds of it.
                --
                -- The sweep's own timing is untouched: the dark phase still
                -- lasts exactly as long, it is just no longer blind for the
                -- whole of it. Teammate blips are refreshed with the
                -- outlines, because they are the same reconciliation -- a
                -- respawn onto a new ped invalidates both.
                local slept = 0
                while slept < dark and matchLive and matchToken == token do
                    local step = math.min(BLIP_REFRESH_MS, dark - slept)
                    Wait(step)
                    slept = slept + step

                    -- Not on the last slice: the top of the loop is about to
                    -- do both, and doing them twice in one frame is work
                    -- nobody sees.
                    if slept < dark then
                        refreshOutlines()
                        refreshBlips(false)
                    end
                end
            else
                -- Radar off. Teammates still on the map -- that is not what
                -- the radar is for -- and checked often enough that switching
                -- it on is felt within a sweep rather than within a round.
                refreshBlips(false)
                Wait(1000)
            end
        end

        -- The loop owns whatever it lit. leaveArena clears everything on the
        -- way out, but a match that ends between two sweeps must not leave
        -- the last one burning until it does.
        removeAllPlayerBlips()
        removeAllOutlines()
    end)
end

-- ----------------------------------------------------------------------
-- THE ARENA'S OWN SCENERY
--
-- An arena in the sky has nothing under it, and an arena on flat ground has
-- nothing to hide behind. Both are the same problem: props this resource
-- puts there for the length of a round and takes away again.
--
-- LOCAL TO EACH FIGHTER, and deliberately. Every player in the match builds
-- their own copy at the same coordinates, so the floor is solid for all of
-- them and invisible to everybody else on the server -- no network objects,
-- nothing for another resource to trip over, and nothing left behind if this
-- client crashes.
-- ----------------------------------------------------------------------

--- How far a piece of cover is held off the floor it stands on.
---
--- Small enough that nothing looks like it is hovering, big enough that the
--- underside of a barrier and the top of the platform are not the same
--- plane. Coincident coplanar faces are what flicker, and on a floor made of
--- tiled props there are a lot of them to flicker against.
local COVER_LIFT = 0.05

--- How far away the arena's own scenery keeps drawing at full detail.
---
--- CLIENT-CREATED PROPS DO NOT GET THIS FOR FREE. A prop the map ships with
--- is placed by the streamer, which knows the distance to draw it from; one
--- created by a script starts on the engine's own short default, and past it
--- the piece drops to a low-detail stand-in or stops drawing at all. On a
--- floor tiled out of them that reads as the arena flickering and changing
--- shape as you walk across it -- while remaining perfectly solid underfoot,
--- because collision never depended on the draw distance.
---
--- 0xFFFF is the ceiling the native accepts, which is the right answer here:
--- there is nothing else within a kilometre to spend the budget on.
local PROP_LOD_DISTANCE = 0xFFFF

--- Handles of everything this client built for the current round.
local arenaProps = {}

--- The TOP of the floor this client built, measured rather than configured.
--- nil for an arena that stands on real ground.
local arenaSurfaceZ = nil

--- Which arena this client last built scenery for, and at what size.
---
--- KEPT SEPARATELY FROM currentMatch on purpose. The scenery outlives the
--- match record on more than one path -- a build that finishes into a round
--- that has already ended, a second exit for a match already left, a resource
--- stopping after the last round -- and the pieces still have to come down on
--- all of them. A teardown that can only find the arena through currentMatch
--- cannot run on the exact paths that leave props standing.
local builtArena = nil

--- One prop's real footprint and height, straight from the game.
---
--- ASKED RATHER THAN CONFIGURED, and it removes the two numbers nobody can
--- get right from outside the game: how far apart to lay the floor tiles,
--- and how high its walkable surface ends up. A tile spacing typed into
--- config leaves gaps to fall through when it is too big and a flickering
--- overlap where it is too small, and an operator looking at the result
--- cannot tell which.
--- PER AXIS, and that is the whole point of measuring rather than guessing.
--- A shipping container is twelve metres by two and a half; collapsing that
--- to one number and tiling on it either leaves ten-metre holes to fall
--- through or stacks the pieces four deep.
--- THE BOTTOM MATTERS AS MUCH AS THE TOP, and leaving it out is why cover
--- looked wrong. GetModelDimensions answers in MODEL space: the origin is
--- (0,0,0) and the box sits wherever the artist put it. Some props are built
--- with the origin on the floor of the model (bottom = 0), others with it in
--- the middle (bottom = -half the height).
---
--- Place both kinds at the same Z and the second sinks halfway into the
--- floor. Asking for the bottom and resting the prop ON the surface works
--- for either, without knowing or caring which convention a given model
--- follows.
--- @param hash integer
--- @return number sizeX, number sizeY, number top, number bottom
local function modelFootprint(hash)
    local minimum, maximum = GetModelDimensions(hash)
    -- Arena.IsPoint rather than a type check written out here, and that is
    -- the fix rather than a tidy-up: this native answers with two VECTORS,
    -- and a vector is its own type in this runtime. Asking whether one is a
    -- 'table' says no to every answer the game has ever given this function,
    -- so nothing was ever measured -- and the two numbers it exists to
    -- supply both fell back to a guess. The floor was tiled on config's 10m
    -- placeholder out of a forty-metre block: eighty-one pieces overlapping
    -- by thirty metres on both axes, every top face at the same height,
    -- solid to stand on and impossible to look at.
    if not Arena.IsPoint(minimum) or not Arena.IsPoint(maximum) then
        return 0.0, 0.0, 0.0, 0.0
    end

    return (maximum.x or 0.0) - (minimum.x or 0.0),
           (maximum.y or 0.0) - (minimum.y or 0.0),
           (maximum.z or 0.0),
           (minimum.z or 0.0)
end

--- Loads the first model in a chain this build actually has.
---
--- THE CHAIN IS THE POINT. A model name being real is not the same as it
--- being on THIS server -- a build without a DLC, or an operator who has
--- stripped assets, has fewer objects than the game's own list does. And the
--- first floor model this resource shipped was one that had been remembered
--- rather than looked up and did not exist anywhere at all.
---
--- IsModelInCdimage is what separates "this build has never heard of it"
--- from "it is taking a while", so an unknown name costs nothing and the
--- next one in the chain is tried immediately.
--- @param models string[]|string
--- @return integer|nil hash
--- @return string|nil name -- which one of them it turned out to be
local function loadPropModel(models)
    if type(models) == 'string' then models = { models } end

    for _, model in ipairs(models or {}) do
        local hash = joaat(model)
        if IsModelInCdimage(hash) and IsModelValid(hash) then
            RequestModel(hash)
            -- Bounded, because a model that will never arrive must not hold
            -- the entry handler open for the whole round.
            local deadline = GetGameTimer() + 10000
            while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
            if HasModelLoaded(hash) then return hash, model end
        end
    end

    return nil, nil
end

--- Takes down everything this client built. Idempotent, and synchronous so
--- it can run on the resource-stop path.
local function removeArenaProps()
    for _, object in ipairs(arenaProps) do
        if DoesEntityExist(object) then
            SetEntityAsMissionEntity(object, true, true)
            DeleteObject(object)
        end
    end
    arenaProps = {}
end

--- Deletes an arena's own scenery standing near it, whether or not this
--- client is the one that remembers building it.
---
--- See Arena.PropSweep for why a handle list is not enough on its own, and
--- for why this is safe only at an arena that carries its own floor.
--- @param arenaKey any
--- @param factor number|nil
--- @return integer removed
local function sweepStrayArenaProps(arenaKey, factor)
    local sweep = Arena.PropSweep(arenaKey, factor)
    if not sweep then return 0 end

    local wanted = {}
    for name in pairs(sweep.models) do wanted[joaat(name)] = true end

    local removed = 0
    for _, object in ipairs(GetGamePool('CObject') or {}) do
        if DoesEntityExist(object) and wanted[GetEntityModel(object)] then
            local at = GetEntityCoords(object)
            local dx = (at.x or 0.0) - sweep.x
            local dy = (at.y or 0.0) - sweep.y
            local dz = (at.z or 0.0) - sweep.z
            if (dx * dx + dy * dy) <= sweep.radius * sweep.radius
                and math.abs(dz) <= sweep.height
            then
                SetEntityAsMissionEntity(object, true, true)
                DeleteObject(object)
                -- Counted on the world rather than on the call: DeleteObject
                -- reports nothing, and a piece this refused to delete is
                -- exactly the one worth knowing about.
                if not DoesEntityExist(object) then removed = removed + 1 end
            end
        end
    end

    if removed > 0 then
        print(('[crimson_arena] arena scenery: swept %d stray piece(s) still standing at \'%s\' from an earlier round.')
            :format(removed, tostring(arenaKey)))
    end
    return removed
end

--- Takes down this client's arena scenery: the pieces it remembers building,
--- and then anything of that arena's own still standing that it does not.
---
--- builtArena IS DELIBERATELY NOT CLEARED. It is not "the arena of the round
--- in progress" -- it is "the last place this client put scenery", and that
--- stays true after the round ends. Clearing it here would make the FIRST
--- teardown the only one able to sweep, and the piece worth sweeping is
--- precisely the one that appears after it: created by a build that was still
--- unwinding when the exit ran. The next build overwrites it, so it never
--- names the wrong arena.
local function clearArenaScenery()
    removeArenaProps()
    if builtArena then sweepStrayArenaProps(builtArena.key, builtArena.factor) end
    arenaSurfaceZ = nil
end

--- Builds an arena's floor and cover, and answers whether the FLOOR is
--- really there.
---
--- The answer matters: an arena whose floor did not build is a very long
--- fall, and the caller would rather refuse to place anybody than drop them
--- into one. Cover failing is a worse round, not a broken one.
--- @param arenaKey any
--- @param factor number|nil -- how much bigger this arena is for this match
--- @return boolean floorReady
--- @param arenaKey any
--- @param factor number|nil
--- @param boundary table|nil -- as sent, so the reach check below is real
local function buildArenaProps(arenaKey, factor, boundary)
    clearArenaScenery()

    -- SWEPT BEFORE A SINGLE PIECE IS LAID, and this is the half that answers
    -- a round starting on top of the last one's floor. clearArenaScenery can
    -- only take down what THIS client still remembers building; a piece
    -- orphaned by a restart, or by a build that died between creating it and
    -- recording it, is remembered by nothing at all. Building over one of
    -- those stacks two copies of every prop in the same place.
    sweepStrayArenaProps(arenaKey, factor)
    builtArena = { key = arenaKey, factor = factor }

    -- THE SAME FACTOR THE SERVER PLANNED THE SPAWNS WITH. It arrives on the
    -- entry payload rather than being worked out here, because this side
    -- cannot see the roster -- and two ends deriving the same number
    -- separately is how they come to disagree about where the floor ends.
    local platform = Arena.GetPlatform(arenaKey, factor)

    -- THE FLOOR IS MEASURED BEFORE IT IS LAID.
    --
    -- The model is loaded once up front purely to ask the game how big it
    -- is, and the tiling and the walkable height both come from the answer.
    -- config's `tileSize` is only the fallback for a model that will not
    -- load -- and a model that will not load has no floor to space out.
    local measured = nil
    if platform then
        local hash, name = loadPropModel(platform.models)
        if hash then
            local sizeX, sizeY, top = modelFootprint(hash)
            if sizeX > 0.0 and sizeY > 0.0 then
                measured = { x = sizeX, y = sizeY, top = top }
            end
            -- THE SURFACE IS THE NUMBER IN CONFIG, because the pieces are
            -- lowered by their own height to meet it. It used to be derived
            -- the other way -- config Z plus whatever that prop's height
            -- turned out to be -- which put the walkable floor metres above
            -- the spawn Z and the cover metres below it, buried inside the
            -- platform.
            arenaSurfaceZ = platform.z
            if name ~= platform.models[1] then
                print(('[crimson_arena] arena scenery: the floor fell back to \'%s\' -- this build does not have \'%s\'.')
                    :format(tostring(name), tostring(platform.models[1])))
            end
        end
    end

    local wanted = Arena.ArenaProps(arenaKey, measured, factor)
    if #wanted == 0 then
        -- Nothing to build is not a failure: every arena on the ground is
        -- this case, and the ground is already there.
        return true
    end

    local needsFloor = platform ~= nil
    -- COUNTED SEPARATELY, and that is not tidiness. `built` alone answers
    -- "did anything appear", and a sky arena whose FLOOR model is missing
    -- but whose barriers are present answers yes to that -- so the guard
    -- below passed and everybody was placed into open air, past the one
    -- check written to stop it.
    local built, builtFloor, failed = 0, 0, {}

    -- COUNTED SO THE CONSOLE CAN ANSWER "IS THE WALL IN THIS COPY".
    --
    -- The perimeter of a sky arena is cover like any other piece, so nothing
    -- in the build distinguishes it -- and an operator standing on an
    -- unwalled platform has no way to tell a copy of the resource that
    -- predates the wall from a build whose container model would not load.
    -- Those are opposite problems with opposite fixes, and the two numbers
    -- below separate them in one line: how many cover pieces this copy asked
    -- for, and how far out the furthest one stands.
    local builtCover, coverReach = 0, 0.0

    for _, piece in ipairs(wanted) do
        local hash = loadPropModel(piece.models or piece.model)
        if hash then
            local placeZ = piece.z

            -- COVER IS RESTED ON THE FLOOR, NOT DROPPED AT ITS HEIGHT.
            --
            -- Its Z arrives as "the arena surface plus whatever offset the
            -- operator wrote", which is only correct for a prop whose origin
            -- happens to sit on its own base. For one with the origin in the
            -- middle it buries half the piece in the floor.
            --
            -- Measuring the bottom and lifting by it rests the piece on the
            -- surface whichever convention the model follows. The extra
            -- fraction keeps its underside off the floor's top face -- two
            -- coplanar surfaces at exactly the same height is what makes a
            -- platform flicker.
            local heading = piece.heading or 0.0

            if piece.kind ~= 'floor' then
                local sizeX, sizeY, _, bottom = modelFootprint(hash)
                placeZ = placeZ - bottom + COVER_LIFT

                -- TURNED BY MEASUREMENT, NOT BY THE NUMBER IN CONFIG.
                --
                -- A piece marked `align = 'tangent'` is meant to stand ACROSS
                -- the radius -- side-on to the middle -- which is what turns
                -- a ring of containers into a wall rather than a set of
                -- spokes with twelve-metre gaps between them. Which heading
                -- does that depends on which way round the MODEL is, and that
                -- is not knowable from config: some props are built with
                -- their long side along their own X, others along their Y.
                --
                -- The measurement is already in hand for the Z above, so the
                -- long axis costs nothing to ask for. The heading in config
                -- stays as the fallback for a model this build could not
                -- measure.
                if piece.align == 'tangent' and sizeX > 0.0 and sizeY > 0.0 then
                    heading = Arena.TangentHeading(piece.offsetX, piece.offsetY, sizeX >= sizeY)
                end
            end

            local object = CreateObject(hash, piece.x, piece.y, placeZ, false, false, false)
            if object and object ~= 0 then
                if piece.kind == 'floor' then
                    builtFloor = builtFloor + 1
                else
                    builtCover = builtCover + 1
                    -- The offsets are already relative to the arena's middle,
                    -- which is what makes this a radius rather than a
                    -- world coordinate nobody can read at a glance.
                    local ox, oy = piece.offsetX or 0.0, piece.offsetY or 0.0
                    local out = math.sqrt(ox * ox + oy * oy)
                    if out > coverReach then coverReach = out end
                end
                SetEntityHeading(object, heading)
                -- Frozen and collidable: it is scenery to stand on and hide
                -- behind, not something to shove off the edge.
                FreezeEntityPosition(object, true)
                SetEntityCollision(object, true, true)
                SetEntityInvincible(object, true)
                SetEntityLodDist(object, PROP_LOD_DISTANCE)
                SetEntityAsMissionEntity(object, true, true)
                arenaProps[#arenaProps + 1] = object
                built = built + 1
            end
            SetModelAsNoLongerNeeded(hash)
        else
            -- The whole chain came up empty, so name all of it: "the floor
            -- is missing" is not actionable, and "none of these three exist
            -- on this build" is.
            failed[table.concat(piece.models or { piece.model }, ' / ')] = true
        end
    end

    for model in pairs(failed) do
        print(('[crimson_arena] arena scenery: the model \'%s\' would not load, so those pieces are missing. Check it exists on this build.')
            :format(tostring(model)))
    end

    -- PRINTED WHENEVER ANYTHING WAS ASKED FOR, not only when the floor could
    -- be measured. It used to be gated on `measured`, so the one arena most
    -- likely to be misbuilt -- the one whose floor prop this build does not
    -- have -- was also the one that printed nothing about what it did build.
    if #wanted > 0 then
        print(('[crimson_arena] arena scenery: %d of %d piece(s) built -- %d floor, %d cover, furthest cover %.2fm out.')
            :format(built, #wanted, builtFloor, builtCover, coverReach))
        if measured then
            print(('[crimson_arena] arena scenery: the floor prop measures %.2f x %.2fm and its surface is at %.2f.')
                :format(measured.x, measured.y, arenaSurfaceZ or 0.0))
        end
    end

    -- DOES THE FLOOR STICK OUT OF THE ARENA, measured against the prop this
    -- build actually supplied.
    --
    -- Arena.ValidateConfig asks the same question at start-up and can only
    -- answer it for `platform.tileSize`, which is the size the client falls
    -- back to when it cannot measure the model. The real prop is often much
    -- bigger -- the shipped chain leads with a stunt block four times that --
    -- and a floor tiled out of it reaches proportionally further. This is the
    -- only place both numbers exist at once: the measurement, and the
    -- boundary the server sent.
    --
    -- Solid ground outside the sphere is the failure that reads worst from a
    -- player's seat: you walk to the edge of a platform you are still
    -- standing on and start bleeding, with nothing to tell you why.
    if builtFloor > 0 and measured and type(boundary) == 'table' and boundary.enabled == true then
        local radius = tonumber(boundary.radius) or 0.0
        local centre = boundary.center or {}
        local cx, cy = tonumber(centre.x) or 0.0, tonumber(centre.y) or 0.0
        local halfX, halfY = (measured.x or 0.0) * 0.5, (measured.y or 0.0) * 0.5

        local reach = 0.0
        for _, piece in ipairs(wanted) do
            if piece.kind == 'floor' then
                local far = math.sqrt((math.abs(piece.x - cx) + halfX) ^ 2
                    + (math.abs(piece.y - cy) + halfY) ^ 2)
                if far > reach then reach = far end
            end
        end

        if radius > 0.0 and reach > radius then
            print(('[crimson_arena] arena scenery: THE FLOOR REACHES OUTSIDE THE ARENA -- it extends %.2fm from the middle and the boundary is %.2fm. The outer ring is solid ground you bleed on. Raise Config.Arenas["%s"].boundary.radius above %.2fm, or lower platform.radius.')
                :format(reach, radius, tostring(arenaKey), reach))
        end
    end

    if needsFloor and builtFloor == 0 then
        arenaSurfaceZ = nil
        print('[crimson_arena] arena scenery: NO FLOOR was built for an arena that supplies its own. Nobody is being placed into it -- there is nothing under it.')
        return false
    end

    return true
end

-- ======================================================================
-- ENTRY / EXIT
-- ======================================================================

--- Puts the world back the way we found it. Synchronous on purpose: it is
--- also the resource-stop path, and a stop handler that yields is a stop
--- handler that does not finish.
--- @param returnCoords table|nil
local function leaveArena(returnCoords)
    -- THE SCENERY COMES DOWN FIRST, AND UNGUARDED.
    --
    -- Everything below is per match, so the guard is right for it. The props
    -- are not: they are the one thing that can still be standing when
    -- currentMatch is already nil -- a second exit for a round already left,
    -- a resource stopping after it ended, a build that finished into a match
    -- that had gone. Behind the guard, every one of those leaves a floor at a
    -- thousand metres for the rest of the session, and puts the next round's
    -- floor inside it.
    clearArenaScenery()

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
    removeAllOutlines()
    roster = {}

    if ArenaSpectate then ArenaSpectate.Stop() end

    -- The operator's own mute exports go back off. Safe to call when
    -- nothing was ever muted, which is why it sits on the single shared
    -- exit path.
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
        -- Kept because the arena's own scenery and its exact-Z rule are read
        -- from config by key, on this side, rather than serialised into every
        -- entry payload.
        arenaKey = data.arenaKey,
        -- How much bigger this arena is for this match. Kept because the
        -- respawn path reads the arena's geometry again and has to read the
        -- same arena the floor was built for.
        sizeFactor = data.sizeFactor,
        -- Kept rather than used and dropped: a death during the start
        -- countdown is answered on this side alone, and standing that
        -- player back up means handing them the same loadout again.
        loadout = data.loadout,
    }

    -- BEFORE the blip thread starts, so the first sweep already knows which
    -- way it goes. Applied even when false: this is also what clears the
    -- setting left behind by the last match we were in.
    ArenaMatch.SetRadar(data.radar == true)

    -- Last round's board must not seed this round's blips.
    roster = {}

    local token = matchToken
    local ped = PlayerPedId()

    -- Before anything can make a noise. The countdown is still inside the
    -- arena, and a shot fired during it is still a shot fired.
    ArenaDispatch.Enter(data.matchId)

    -- Captured into locals first. scatter() returns FOUR values, and a call
    -- in the middle of an argument list is truncated to one -- so passing it
    -- inline alongside the freeze flag would hand placeAt an x and nothing
    -- else.
    local sx, sy, sz, sheading = scatter(data.spawn, tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius)

    -- THE PLAYER IS MOVED FIRST, FROZEN, AND THE FLOOR IS BUILT AROUND THEM.
    --
    -- THIS IS WHY THE ARENA IN THE SKY DID NOTHING AT ALL. CreateObject
    -- builds into the streamed world, and the world is streamed around the
    -- player. Asking for a floor a kilometre above somebody standing in the
    -- city is asking for scenery in a part of the map the engine is not
    -- holding, and what comes back is nothing -- so the floor check below
    -- failed, the handler returned, and the round simply never started for
    -- them. Nothing in the console said so, because refusing to place
    -- somebody over a kilometre of air is the CORRECT response to a floor
    -- that is not there; the floor not being there was the bug.
    --
    -- Safe in the order it now runs because the FREEZE is what stops the
    -- fall, not the floor: a frozen ped hangs in the air over nothing. That
    -- is the same guarantee placeAt has always relied on, used a few hundred
    -- milliseconds earlier.
    -- ONLY FOR AN ARENA THAT BUILDS SOMETHING. An arena that is just a
    -- place on the map has nothing to stream in around the player, so it
    -- keeps the order it always had and pays none of the delay below.
    if Arena.GetPlatform(data.arenaKey) or #Arena.GetCover(data.arenaKey) > 0 then
        -- HELD AT THE FLOOR, NOT AT THE SPAWN Z THAT WAS SENT.
        --
        -- The point of the hold is to put the player where the scenery is
        -- about to be built, so the engine is holding that part of the map.
        -- The floor is built at the arena's own surface -- so that is the
        -- height to be at, and a spawn Z that disagrees with it must not
        -- decide where the world gets streamed.
        --
        -- It can disagree. The sky arena writes its height into config five
        -- times -- the platform, the spawn area, the spawn list, the team
        -- lists and the boundary -- and an operator moving the arena has to
        -- change all of them. Miss one and the player is held a few hundred
        -- metres from the floor being built, every CreateObject is refused
        -- for being outside the streamed world, and the arena reports that
        -- it has no floor. Correct, and impossible to diagnose from the
        -- symptom. Placement below still uses the sent Z, floored at the
        -- surface -- this only decides where to stand while building.
        local holdZ = Arena.SpawnFloor(data.arenaKey) or sz
        FreezeEntityPosition(ped, true)
        SetEntityCoordsNoOffset(ped, sx, sy, holdZ + (tonumber(Config.Match.spawnHeightOffset) or 1.0),
            false, false, false)
        SetEntityHeading(ped, sheading)
        RequestCollisionAtCoord(sx, sy, holdZ)
        -- Long enough for the streamer to have followed the player to the
        -- new position, short enough that nobody notices. Bounded rather
        -- than a wait on collision: an arena in the sky has none to wait for.
        Wait(150)
    end

    -- Returns false only when a floor that was supposed to be built is not
    -- there. Placing somebody into that is a very long fall, so they are
    -- taken back out instead -- and the server is told, or it keeps a fighter
    -- in a match it can never put anywhere.
    if not buildArenaProps(data.arenaKey, data.sizeFactor, data.boundary) then
        clearArenaScenery()

        local home = Config.Lobby.returnCoords
        SetEntityCoordsNoOffset(ped, home.x, home.y, home.z, false, false, false)
        SetEntityHeading(ped, home.w or 0.0)
        FreezeEntityPosition(ped, false)
        TriggerServerEvent('crimson_arena:server:leaveMatch')
        return
    end

    -- ASKED AGAIN, BECAUSE THE BUILD YIELDS. Loading a model waits, and the
    -- hold above waits, so a round can end while this handler is parked
    -- inside buildArenaProps -- and leaveArena, running in that window, does
    -- its removeArenaProps BEFORE this build has finished putting pieces
    -- back. The exit is then over and the pieces it was meant to take down
    -- do not exist yet; they are created a moment later, into an arena
    -- nobody is in, and stand at a thousand metres for the rest of the
    -- session because leaveArena will not run again for a match that has
    -- already gone.
    --
    -- The same yield the placement below guards against, one step earlier:
    -- moving the build ahead of the placement is what made this window wide
    -- enough to matter.
    if matchToken ~= token or not currentMatch then
        clearArenaScenery()
        return
    end

    -- The floor this client actually BUILT beats the one config described.
    -- A surface measured from the model is right whatever prop an operator
    -- swapped in; a number typed beside it is right until they swap one.
    --
    -- The guard is handed IN, exactly as the respawn path does it. placeAt
    -- waits up to five seconds for the world, and a round that ends inside
    -- that wait has already sent this player home and given them their gear
    -- back -- a placement decided before the wait and applied after it drags
    -- them back to an arena spawn they no longer belong at, and nothing
    -- downstream undoes it.
    placeAt(ped, sx, sy, sz, sheading, true, function()
        return matchToken == token and currentMatch ~= nil
    end, Arena.UsesExactSpawnZ(data.arenaKey), arenaSurfaceZ or Arena.SpawnFloor(data.arenaKey))

    -- placeAt waits for the ground to stream in, so this handler YIELDS for
    -- up to five seconds and an exitArena can be delivered inside that
    -- window. By the time placeAt returns, leaveArena has already taken this
    -- player home and given them their own weapons back: arming them with
    -- the arena loadout now would strip exactly what was just restored, in
    -- the open world, with nothing left that would ever take it away again.
    if matchToken ~= token or not currentMatch then return end

    applyLoadout(ped, data.loadout)

    -- Watching starts HERE, not at matchLive: the countdown below is spent
    -- standing in the arena within range of everybody else's opening shot.
    -- Started after placeAt rather than before it because a countdown
    -- revive replaces the ped handle, and `ped` above is still in use.
    startArenaThread()

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

--- The round is on. The two loops opened here are the ones that have
--- nothing to do until it is -- the boundary would otherwise bleed fighters
--- frozen in place by the countdown, and the blips have no scoreboard to
--- draw from yet. The death watch is already running; entry started it.
RegisterNetEvent('crimson_arena:client:matchLive', function()
    if not currentMatch or matchLive then return end

    matchLive = true
    FreezeEntityPosition(PlayerPedId(), false)
    startBoundaryThread(currentMatch.boundary)
    startBlipThread()
end)

RegisterNetEvent('crimson_arena:client:respawn', function(data)
    if not currentMatch or type(data) ~= 'table' or type(data.spawn) ~= 'table' then return end

    local token = matchToken
    -- THE SERVER'S NUMBER, not config's. It was sending one and this side
    -- was reading config instead, so the whole field was decorative: a
    -- respawn onto a planned point is sent with no scatter precisely so it
    -- is not nudged off it, and that instruction was being dropped on
    -- arrival. The fallback keeps an older server working.
    local x, y, z, heading = scatter(data.spawn,
        tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius)
    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

    local ped = PlayerPedId()

    -- THE WATCH IS RE-ARMED BEFORE THE PED IS KILLABLE, and the order of the
    -- three steps below is the only reason this reads the way it does.
    --
    -- `deathReported` is what the watch checks before it will look at a body,
    -- and ReleaseDeadState is what hands this ped back to the world. The flag
    -- therefore has to go down BEFORE the release. It used to go down last,
    -- after a placeAt that YIELDS for as long as the ground takes to stream:
    -- for those frames the player stood in a live round mortal, visible and
    -- unwatched, and a kill landed in them was reported to nobody, cleared
    -- for nobody, and left the operator's medical script a real corpse to
    -- page an ambulance to -- in a bucket no ambulance can reach.
    --
    -- Down only AFTER the resurrect, though: with the body still dead the
    -- watch would find the death it has already reported and report it a
    -- second time. Nothing between the resurrect above and this line yields,
    -- so the watch cannot get a look in between the two.
    deathReported = false

    ClearPedBloodDamage(ped)

    -- Placed while STILL inside ClearDeadState's hold, and left frozen, so
    -- that the release below is the single instant this player becomes a
    -- target again rather than the start of a five-second wait. Nothing is
    -- made invincible here that was not already -- the hold is simply not
    -- dropped early any more.
    -- The guard is handed IN rather than checked after. placeAt can wait five
    -- seconds for the world, and a round that ends inside that wait sends
    -- this player home -- so a placement decided before the wait and applied
    -- after it would teleport somebody who has already left back to the
    -- arena spawn. Asked again on the far side of the yield, it simply does
    -- not place them.
    local placed = placeAt(ped, x, y, z, heading, true, function()
        return matchToken == token and currentMatch ~= nil
    end, Arena.UsesExactSpawnZ(currentMatch and currentMatch.arenaKey),
        arenaSurfaceZ or Arena.SpawnFloor(currentMatch and currentMatch.arenaKey))

    -- Unconditional, and ahead of the guard below: placeAt re-freezes this
    -- ped, and a round that ended during its yield already spent its one
    -- release in leaveArena. Without this the player is left FROZEN AT THE
    -- ARENA SPAWN -- not invisible, and not in the lobby: leaveArena has
    -- already made them visible and mortal on its way past. Frozen alone is
    -- enough to strand them, which is what this line is for.
    ArenaDispatch.ReleaseDeadState(ped)

    -- The same yield the entry handler guards: a round that ended while this
    -- player was being put back on their feet has already restored their own
    -- gear and moved them to the lobby.
    if not placed or matchToken ~= token or not currentMatch then return end

    applyLoadout(ped, data.loadout)

    -- EVERY LIFE, NOT ONLY THE ONES A MEDICAL SCRIPT IS TOLD ABOUT. The
    -- server opens this window again when it runs the medical handoff, which
    -- is the case that needs it most -- but the handoff is two seconds away
    -- and optional, and a fighter is standing in a live round NOW. Opening it
    -- here as well means the numbers this respawn just applied are held from
    -- the instant they are applied, whatever else reaches for them.
    holdVitals()
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

    -- SPECTATORS COUNT AS WATCHING, and leaving them out hid the whole HUD.
    --
    -- client/ui.lua registers this event too and simply passes the payload
    -- through; this file loads AFTER it, so this call is the one that lands.
    -- Reading `visible` off currentMatch alone therefore overrode ui.lua's
    -- and told the panel to hide the overlay for anybody not in the fight --
    -- which is exactly who a spectator is. No clock, no alive count, no
    -- scoreboard, for the one person with nothing to do but read them.
    --
    -- Guarded on the type: client/spectate.lua loads after this file, so
    -- ArenaSpectate does not exist while this line is being READ. It does by
    -- the time the event fires.
    local watching = type(ArenaSpectate) == 'table'
        and type(ArenaSpectate.IsActive) == 'function'
        and ArenaSpectate.IsActive() == true

    ArenaUI.UpdateHud({ visible = currentMatch ~= nil or watching, hud = data })
end)

-- A restart while a round is running must not cost anyone their gear, and
-- must not leave them standing in an arena no resource is managing.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    leaveArena(nil)
end)

-- ======================================================================
-- WHICH PROPS THIS BUILD ACTUALLY HAS
--
-- An arena that carries its own floor names prop models, and a name being
-- real is not the same as it being on THIS server: a build without a DLC, or
-- one whose assets have been stripped, has fewer objects than the game's own
-- list does. That is why every prop names a CHAIN rather than one model.
--
-- The chains make it survivable. This makes it KNOWABLE -- before somebody
-- finds out mid-round, on their own, with no way to tell a missing prop from
-- a broken script.
--
-- Client-side because that is the only realm that can ask: IsModelInCdimage
-- reads the game's object index, and the server does not have one.
--
-- SILENT WHEN EVERYTHING IS FINE, unless Config.Debug is on. The one line
-- worth interrupting somebody for is the one that says a chain has run out.
-- ======================================================================

CreateThread(function()
    -- After the world is up; asking the object index before then answers
    -- for a game that has not finished loading.
    Wait(2000)

    -- A DIAGNOSTIC MAY NOT BE THE THING THAT BREAKS THE RESOURCE. This is
    -- the only place in the client that touches the object index, and a
    -- build without that native -- or a test harness that has not stubbed it
    -- -- would otherwise take this whole thread down. The lobby NPC was lost
    -- to exactly this shape once already: a raise inside a startup thread,
    -- and everything after it silently never ran.
    if type(IsModelInCdimage) ~= 'function' or type(joaat) ~= 'function' then return end

    local checked, missing = {}, {}

    --- @param entry table -- anything with `model` / `models`
    --- @param where string
    local function inspect(entry, where)
        local chain = Arena.ModelChain(entry)
        if #chain == 0 then return end

        local have = {}
        for _, model in ipairs(chain) do
            if IsModelInCdimage(joaat(model)) then have[#have + 1] = model end
        end

        checked[#checked + 1] = ('%s: %d of %d (%s)')
            :format(where, #have, #chain, have[1] or 'NONE')
        if #have == 0 then
            missing[#missing + 1] = ('%s -- none of: %s'):format(where, table.concat(chain, ', '))
        end
    end

    for _, entry in ipairs(Arena.GetEnabledArenas()) do
        local arena = Arena.GetArenaByKey(entry.key)
        if type(arena) == 'table' then
            if type(arena.platform) == 'table' and arena.platform.enabled ~= false then
                inspect(arena.platform, entry.key .. ' floor')
            end
            if type(arena.cover) == 'table' and arena.cover.enabled ~= false then
                local seen = {}
                for index, piece in ipairs(arena.cover.pieces or {}) do
                    -- One line per DISTINCT chain rather than per piece:
                    -- twenty barriers off the same chain is one fact.
                    local signature = table.concat(Arena.ModelChain(piece), '|')
                    if signature ~= '' and not seen[signature] then
                        seen[signature] = true
                        inspect(piece, ('%s cover #%d'):format(entry.key, index))
                    end
                end
            end
        end
    end

    if #missing > 0 then
        print('[crimson_arena] PROPS MISSING ON THIS BUILD -- an arena below cannot be built and will refuse to start:')
        for _, line in ipairs(missing) do print('    ' .. line) end
        print('[crimson_arena] Add those models to a stream/ folder in this resource, or name props your build does have. See stream/README.md.')
    elseif Config.Debug and #checked > 0 then
        print('[crimson_arena] arena props, checked against this build:')
        for _, line in ipairs(checked) do print('    ' .. line) end
    end
end)
