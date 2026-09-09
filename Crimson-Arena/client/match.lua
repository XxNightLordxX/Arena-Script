-- Crimson Arena: what a fighter sees and does during a round.

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

local BLIP_REFRESH_MS = 500

local BLIP_FALLBACK_COLOR = 1

local currentMatch
local matchLive = false
local deathReported = false

local matchToken = 0

local carried

local roster = {}
local playerBlips = {}

local outlined = {}

local OUTLINE_SHADER = 0

--- THE TECHNIQUE GROUP THE ENGINE DRAWS THE OUTLINE MASK WITH, AND THE
--- REASON A PED NEVER LIT UP NO MATTER WHAT ELSE WAS FIXED.
---
--- The outline is not a flag the renderer reads off an entity. FiveM keeps a
--- list, and at the end of the scene it RE-DRAWS every entity on it into a
--- mask render target -- forcing one technique group while it does so:
---
---   GamePrimitives_Outlines.cpp:38   DEFAULT_SHADER_TECHNIQUE_GROUP = "unlit"
---   GamePrimitives_Outlines.cpp:439  *currentShader = _getTechniqueDrawName(group)
---
--- And a ped shader has no technique in that group. Rockstar's own header
--- gates unlit techniques to four shader families, and peds are not one:
---
---   common.fxh  UNLIT_TECHNIQUES_FOR_SHADER = (__GTA_MEGASHADER_FXH__
---                 || __GTA_TERRAIN_CB_COMMON_FXH__
---                 || VEHICLE_PAINT_SHADER || VEHICLE_GLASS_SHADER)
---
--- (__GTA_PED_COMMON_FXH__ is a fifth, separate family -- common.fxh names it
--- in the same file, in the shadow-technique list, and not in this one.)
---
--- So the forced group resolves to no technique, the mask draw emits no
--- geometry, the mask stays at its cleared zero, and the Gauss pass blurs
--- zero and composites zero. That is why props outline and peds never do.
---
--- AND WHY NOTHING EVER SAID SO. SET_ENTITY_DRAW_OUTLINE is void: its entire
--- body is a push_back onto that list. There is no type check, no return
--- value and no failure signal, so refreshOutlines below can call it on a
--- real streamed ped, print "drawing 1 teammate(s)", and be telling the exact
--- truth about a frame in which nothing was drawn. Every earlier fix -- the
--- flag re-asserted every pass, the colour held every frame, the start-order
--- race -- was aimed at a layer that was already working.
---
--- SET_ENTITY_DRAW_OUTLINE_RENDER_TECHNIQUE (a CFX native, ~May 2025) is the
--- one lever that reaches this. Peds do implement the DEFAULT group, so that
--- is what we ask for.
---
--- ONE GLOBAL FOR THE WHOLE CLIENT, exactly like the colour and the shader --
--- so it is set only while we are drawing and put back in removeAllOutlines,
--- or every other resource's outlines on this machine inherit it.
local OUTLINE_TECHNIQUE = 'default'

--- Asks for that group, if this artifact is new enough to have the native.
--- UNGUARDED IT WOULD BE FATAL rather than merely useless: one of the two
--- call sites is inside the per-frame thread that also carries the death
--- backstop, and a nil call there kills the thread and the backstop with it.
local function holdOutlineTechnique()
    if SetEntityDrawOutlineRenderTechnique then
        SetEntityDrawOutlineRenderTechnique(OUTLINE_TECHNIQUE)
    end
end

local outlineTint = nil

--- THE MARKER ABOVE A TEAMMATE'S HEAD, AND WHY IT IS NOT THE OUTLINE AGAIN.
---
--- The outline above is the nicer of the two and it is the one that CANNOT
--- BE RELIED ON: it needs a CFX native from around May 2025, it owns three
--- client-wide settings any other resource can take from it mid-frame, and
--- when it fails it fails silently, drawing a mask that emits no geometry
--- while this file truthfully logs that it drew a teammate.
---
--- So this is a second, independent answer to the same question, and every
--- choice in it is made for reliability rather than for looks:
---
---   NOTHING IS ATTACHED TO ANYTHING. There is no flag on a ped, no handle
---   to keep, no client-wide setting held. Each frame the ally's SERVER ID
---   is turned back into a ped and a rectangle is drawn. A ped recreated by
---   a respawn or by re-streaming is a different handle and this does not
---   care -- the next frame looks it up again. Nothing can be "lost", so
---   nothing has to be re-attached.
---
---   NOTHING TO CLEAN UP. Drawing stops and the marker is gone in the same
---   frame. It CANNOT follow anybody into the city, because there is no
---   state anywhere for it to follow them with.
---
---   NOTHING ANY OTHER RESOURCE CAN TAKE. DrawRect is a call, not a
---   setting, so the race the outline loses to a per-frame target script
---   does not exist here.
---
--- THROUGH WALLS, WHICH IS THE WHOLE POINT and also the reason it is
--- teammates only. A draw origin makes these ordinary 2D interface draws
--- positioned at a world point: there is no depth test, so cover does not
--- hide it. On an enemy that would be a wallhack, and nothing here will
--- ever take an enemy -- see refreshTeamMarks.
---
--- These four are base game natives from 2015, present on every build there
--- is. The check is not defensive padding against a build that lacks them:
--- one of the two call sites is the per-frame thread that also carries the
--- death backstop, and an unguarded nil call there does not lose a marker,
--- it kills the thread and every fighter after it dies unreported.
local MARKER_NATIVES = SetDrawOrigin ~= nil
    and ClearDrawOrigin ~= nil
    and DrawRect ~= nil
    and IsEntityOnScreen ~= nil

--- SKEL_Head, so the marker sits over the head rather than over the feet
--- plus a guess -- which matters exactly when it matters most, on somebody
--- crouched behind cover or lying down.
local MARKER_HEAD_BONE = 31086

--- Where the marker's point sits above the head, in metres.
local MARKER_LIFT = 0.42

--- The same lift measured from the FEET, for the fallback below.
local MARKER_ROOT_LIFT = 1.32

--- The chevron, as { how far ABOVE the point, half its width }. Rows are
--- screen fractions, so the marker keeps one size at any range -- a
--- teammate across the arena is as easy to pick out as one beside you,
--- which is the thing being asked for.
--- Widest at the top, a point at the bottom, so it reads as an arrow aimed
--- at the head under it. The rows overlap by design -- each is taller than
--- the gap to the next -- because three separated bars are three bars.
local MARKER_ROWS = {
    { 0.0000, 0.0020 },
    { 0.0050, 0.0045 },
    { 0.0100, 0.0070 },
}

local MARKER_ROW_HEIGHT = 0.0065

--- A dark plate behind each row, this much wider and taller than it. A
--- bright team colour on a bright sky is not a marker. The two are
--- different numbers because DrawRect measures width against the screen's
--- width and height against its height, so one value would be a plate
--- nearly twice as thick on one axis as the other.
local MARKER_EDGE_X = 0.0016
local MARKER_EDGE_Y = 0.0028

--- The head of a ped, already lifted, as three numbers.
---
--- Resolved once rather than tested per ped per frame. GET_PED_BONE_COORDS
--- is as old as the rest, so the second branch is a floor and not a plan.
local markerHeadCoords
if GetPedBoneCoords ~= nil then
    markerHeadCoords = function(ped)
        local head = GetPedBoneCoords(ped, MARKER_HEAD_BONE, 0.0, 0.0, 0.0)
        return head.x, head.y, head.z + MARKER_LIFT
    end
else
    markerHeadCoords = function(ped)
        local at = GetEntityCoords(ped)
        return at.x, at.y, at.z + MARKER_ROOT_LIFT
    end
end

--- The living teammates to mark, as SERVER IDS -- never peds, never blip
--- handles. A server id is the one thing about a teammate that survives
--- their ped being destroyed and remade.
local teamMarks = {}

local teamMarkTint = nil

--- DECLARED HERE, DEFINED FURTHER DOWN, beside the roster scan it reads --
--- which is several hundred lines BELOW the per-frame thread that calls it.
---
--- DO NOT delete this line and make the definition a `local function`. A
--- local declared after its caller is not the name that caller compiled
--- against: the call site would read a global that nothing ever assigns,
--- and calling nil raises INSIDE the per-frame thread that also carries the
--- death backstop. Every fighter on that client would then die unreported.
--- Measured, not supposed: it raises on the first frame of the first round.
---
--- Keeping it a local rather than letting the definition make a global is
--- the smaller half of the same decision -- a global here is one more name
--- every other file in this resource can read and overwrite, for a function
--- with exactly one caller.
local drawTeamMarks

local function notify(key, notifyType, ...)
    lib.notify({
        title = Config.NotifyTitle,
        description = locale(key, ...),
        type = notifyType,
    })
end

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

local friendlyFireHeld = false

local priorTeam = nil

local heldPed = nil

local heldTeam = nil

local releaseFriendlyFire

local function holdFriendlyFire(ped)
    if not currentMatch
        or not Arena.ModeUsesTeams(currentMatch.modeKey)
        or Config.Teams.friendlyFire == true
    then
        releaseFriendlyFire(ped)
        return
    end

    local index = Arena.TeamIndex(currentMatch.teamKey)
    if not index then
        releaseFriendlyFire(ped)
        return
    end

    if not friendlyFireHeld then priorTeam = GetPlayerTeam(PlayerId()) end

    SetPlayerTeam(PlayerId(), index)
    NetworkSetFriendlyFireOption(false)
    SetCanAttackFriendly(ped, false, false)
    friendlyFireHeld = true
    heldPed = ped
    heldTeam = index
end

releaseFriendlyFire = function(ped)
    if not friendlyFireHeld then return end
    friendlyFireHeld = false
    heldTeam = nil
    heldPed = nil

    SetPlayerTeam(PlayerId(), priorTeam or -1)
    priorTeam = nil
    NetworkSetFriendlyFireOption(true)
    SetCanAttackFriendly(ped, true, true)
end

local function restoreOwnLoadout(ped)
    if not carried then return end

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

local arenaVitals = { health = nil, armour = nil, until_ = 0 }

local VITALS_REASSERT_MS = 1500

local function applyLoadout(ped, loadout)
    if type(loadout) ~= 'table' then return end

    local fullHealth, fullArmour = Arena.StartingVitals()
    local wantedHealth = math.max(Arena.ToInt(loadout.health) or 0, fullHealth)
    local wantedArmour = math.max(Arena.ToInt(loadout.armor) or 0, fullArmour)

    SetEntityHealth(ped, wantedHealth)
    SetPedArmour(ped, wantedArmour)

    arenaVitals.health = wantedHealth
    arenaVitals.armour = wantedArmour
end

local SPAWN_HEADROOM = 1.5

local SPAWN_PROBE_UP = 12.0

local SPAWN_ESCAPE_RINGS = { 4.0, 8.0, 12.0 }

local SPAWN_ESCAPE_PER_RING = 4

local GROUND_PROBE_LOW = 3.0

--- Whether something solid is sitting on top of this spot.
---
--- IN A PLAYER'S WORDS: "in the trailer park i keep spawning in trailers".
---
--- GetGroundZFor_3dCoord -- which is what places everybody on a real-ground
--- arena -- searches downward for TERRAIN and knows nothing about props. The
--- trailer park is a real map location with trailers standing on it, so the
--- probe cheerfully answered with the dirt UNDERNEATH one and the fighter was
--- put down inside it. Both natives behaved exactly as documented.
---
--- A SHAPE TEST IS THE ONE THAT KNOWS ABOUT PROPS. Fired straight down from
--- overhead, it stops at the first solid thing -- a trailer roof, a container,
--- a wall -- so a hit well above the ground means this spot has something over
--- it, and a spot with something over it is a spot somebody would arrive
--- inside of.
---
--- FAILS OPEN. A shape test that answers nothing, or a build with no shape
--- tests at all, leaves the point usable: the worst case then is what shipped
--- before this existed, and refusing every spawn point in an arena would be
--- very much worse than occasionally using a poor one.
--- @param x number
--- @param y number
--- @param groundZ number -- where the terrain under this point is
--- @return boolean blocked
local function roofedOver(x, y, groundZ)
    if type(StartExpensiveSynchronousShapeTestLosProbe) ~= 'function'
        or type(GetShapeTestResult) ~= 'function'
    then
        return false
    end

    -- FLAGS: the map, vehicles and objects. Peds are deliberately left out --
    -- somebody standing on the spot is not a reason nobody may spawn there,
    -- and the scatter exists to spread people out anyway.
    --
    -- THE NUMBERS, SPELLED OUT, because the first version of this said
    -- exactly the sentence above and then wrote `1 + 2 + 8` -- which is the
    -- map, vehicles and RAGDOLLS. It requested the one family the comment
    -- disclaimed and omitted the one it claimed. The trailers that started
    -- all this are baked map geometry, so flag 1 covered them and the report
    -- really was fixed; what the wrong value quietly cost was every prop
    -- this resource or any other SPAWNS -- a shipping container laid out as
    -- cover reads as open sky to a probe that never asked about objects.
    --
    -- 1 IntersectWorld, 2 IntersectVehicles, 16 IntersectObjects.
    -- Not 4 (peds) and not 8 (ragdolls): on the respawn path this runs
    -- while the player is still a corpse, and their own body is not a roof.
    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        x, y, groundZ + SPAWN_PROBE_UP,
        x, y, groundZ + SPAWN_HEADROOM,
        1 + 2 + 16, 0, 4)

    local _, hit, endCoords = GetShapeTestResult(handle)
    if hit ~= 1 and hit ~= true then return false end

    -- READ WITHOUT INDEXING SOMETHING THAT CANNOT BE INDEXED. The first
    -- version of this was `type(endCoords) == 'table' and tonumber(...) or
    -- tonumber(endCoords and endCoords.z)` -- and the second half of that
    -- indexes whatever it was handed. A number or a `true` back from a build
    -- whose native answers differently throws out of here, out of the
    -- placement, and out of the entry handler, which has already set the
    -- dispatch flag and the friendly-fire hold: a player left standing in
    -- the city, flagged as being in an arena they are not in.
    --
    -- The 'table' test was also the wrong question. In the CitizenFX runtime
    -- a vector3 answers 'vector3' to `type`, never 'table' -- the same trap
    -- four guards in this resource fell into before -- so on a real server
    -- that branch never fired and every read came through the unguarded one.
    local shape = type(endCoords)
    local hitZ
    if shape == 'vector3' or shape == 'vector4' or shape == 'table' or shape == 'userdata' then
        hitZ = tonumber(endCoords.z)
    end

    if hitZ == nil then return false end

    return hitZ > groundZ + SPAWN_HEADROOM
end

local function escapeRoute(x, y)
    local points = { { x = x, y = y } }
    for ring, distance in ipairs(SPAWN_ESCAPE_RINGS) do
        -- TURNED HALF A STEP EACH RING, so the rings do not line up into
        -- four spokes -- which would test the same four bearings three
        -- times and miss everything between them.
        local twist = (ring - 1) * math.pi / SPAWN_ESCAPE_PER_RING
        for step = 1, SPAWN_ESCAPE_PER_RING do
            local angle = twist + (step - 1) * math.pi * 2.0 / SPAWN_ESCAPE_PER_RING
            points[#points + 1] = {
                x = x + math.cos(angle) * distance,
                y = y + math.sin(angle) * distance,
            }
        end
    end
    return points
end

local function scatter(spawn, radius)
    local baseX, baseY = spawn.x, spawn.y
    local z, heading = spawn.z, spawn.w or 0.0

    if not (radius and radius > 0.0) then return baseX, baseY, z, heading end

    local angle = math.random() * math.pi * 2.0
    local distance = math.sqrt(math.random()) * radius
    return baseX + math.cos(angle) * distance,
        baseY + math.sin(angle) * distance,
        z, heading
end

local function placeAt(ped, x, y, z, heading, leaveFrozen, stillWanted, exactZ, floorZ)
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

    if stillWanted and not stillWanted() then
        FreezeEntityPosition(ped, false)
        return false
    end

    if exactZ then
        SetEntityCoordsNoOffset(ped, x, y, math.max(z, floorZ or z) + lift, false, false, false)
        FreezeEntityPosition(ped, leaveFrozen == true)
        return true
    end

    local function groundUnder(px, py)
        for _, probe in ipairs({ GROUND_PROBE_LOW, 50.0, 200.0 }) do
            local found, groundZ = GetGroundZFor_3dCoord(px, py, z + probe, false)
            local belowTheArena = floorZ ~= nil and groundZ and groundZ < floorZ
            if found and groundZ and groundZ > -190.0 and not belowTheArena then
                return groundZ
            end
        end
        return nil
    end

    -- AND NOT INSIDE ANYTHING. IN A PLAYER'S WORDS: "in the trailer park i
    -- keep spawning in trailers".
    --
    -- GetGroundZFor_3dCoord above searches downward for TERRAIN and knows
    -- nothing about what is standing on it, so on a real map location with
    -- trailers on it the probe answers with the dirt UNDERNEATH one and the
    -- fighter is put down inside it. Both natives behave exactly as
    -- documented.
    --
    -- HERE, AND NOT WHERE THE POINT WAS DRAWN, for two reasons that each
    -- killed the first attempt on their own: the collision wait above has
    -- just run, so the geometry the shape test needs actually exists; and
    -- this is a placement rather than a draw, so there is somewhere else to
    -- go. A planned spawn arrives with no scatter radius at all -- the plan
    -- already spread the roster and kept it clear of the arena's own cover
    -- -- so nudging one at random was never available; moving a BLOCKED one
    -- the shortest distance that clears it is.
    --
    -- THE SPACING THE PLAN BOUGHT IS SPENT ONLY WHERE IT HAS TO BE. The
    -- first point tried is the one the plan chose, so a clear spawn costs
    -- one shape test and moves nobody. The rings are walked nearest first,
    -- so a blocked one gives up as little separation as will get it out.
    local placed = false
    local fallbackX, fallbackY, fallbackZ
    for _, point in ipairs(escapeRoute(x, y)) do
        local groundZ = groundUnder(point.x, point.y)
        if groundZ then
            if fallbackZ == nil then
                fallbackX, fallbackY, fallbackZ = point.x, point.y, groundZ
            end
            if not roofedOver(point.x, point.y, groundZ) then
                SetEntityCoordsNoOffset(ped, point.x, point.y, groundZ + 0.15,
                    false, false, false)
                placed = true
                break
            end
        end
    end

    if not placed and fallbackZ then
        SetEntityCoordsNoOffset(ped, fallbackX, fallbackY, fallbackZ + 0.15,
            false, false, false)
        placed = true
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

    local revived = PlayerPedId()

    holdFriendlyFire(revived)
    ClearPedBloodDamage(revived)

    applyLoadout(revived, currentMatch and currentMatch.loadout)

    FreezeEntityPosition(revived, true)
end

--- WHY A DEATH NAMED NOBODY. Sent alongside the claim as a NUMBER, never as
--- text: this is a report from the one client whose report is being doubted,
--- and the server writes it into the operator's log. A number it maps itself
--- cannot put a sentence of somebody else's choosing in that log.
---
--- ONLY EVER A LOG LINE. None of these four gives anybody a kill, and DO NOT
--- let one start to: the whole reason this exists is that the answer is
--- honestly unknown, and a client that can choose the reason would simply
--- choose the one that pays.
local WHY_NOTHING = 1
local WHY_SELF = 2
local WHY_NOT_A_PLAYER = 3
local WHY_NOT_NETWORKED = 4

local WHY_TEXT = {
    [WHY_NOTHING] = 'nothing that hit you was an entity this game could name, which is what a fall, '
        .. 'a drowning, the arena boundary or a fire looks like',
    [WHY_SELF] = 'the only thing that hit you was you -- your own explosive, or the boundary bleed',
    [WHY_NOT_A_PLAYER] = 'what hit you was not a player: an NPC, a prop, or a vehicle with nobody driving it',
    [WHY_NOT_NETWORKED] = 'a player hit you but their character was not on your game\'s network list '
        .. 'by the time you went down -- they were too far away, or they left',
}

--- THE ONE FATAL BLOW THIS CLIENT SAW, kept alive for the frame or two
--- between the damage and the corpse.
---
--- THE DEFECT, IN THE OWNER'S OWN F8: "i was shot and it said nobody was seen
--- as the killer". handleDeath's first line refuses a ped that is not
--- IsEntityDead YET -- and the damage hook below runs in the frame the ped
--- dies, which is the frame before the engine finalises the death state.
--- That finalisation is the same one that leaves GET_PED_SOURCE_OF_DEATH at
--- 0, so on the kills where the two coincide the hook handed in a perfectly
--- good attacker, that first line dropped the whole call unread, and the
--- watch loop picked the body up a frame later with nothing left to ask but
--- the source of death -- the reading that had already failed. The attacker
--- has to OUTLIVE the frame it arrived in, which is all this is.
---
--- STAMPED, AND THE STAMP IS THE ENTIRE SAFETY OF IT. A remembered attacker
--- becomes a KILL CREDIT, and crediting the wrong player is worse than
--- crediting nobody -- so it is read only while it is fresh enough to belong
--- to the death being reported. Two seconds is already far longer than the
--- gap it covers and shorter than any respawn this arena ships. DO NOT widen
--- it, and DO NOT let it survive a respawn.
local FATAL_MEMORY_MS = 2000
local lastFatalEntity
local lastFatalAt = 0

--- The server id of the PLAYER behind one entity, or nil and the reason why.
---
--- A VEHICLE IS AN ANSWER AND NOT A DEAD END. Run down, or killed by a car
--- somebody else detonated, the engine names the VEHICLE -- and this refused
--- it for not being a ped, so the death named nobody and the driver was paid
--- nothing. Following a vehicle to whoever is driving it is not a guess about
--- who happened to be nearby; it is the chain the game's own kill feed walks.
--- DO NOT narrow this back to "a ped or nothing".
---
--- IT IS THE DRIVER'S SEAT AND NEVER A PASSENGER'S, on purpose. A car that
--- kills somebody was driven into them by the person steering it; a gunner in
--- the back is firing a weapon of their own, which the engine reports as that
--- ped and not as the vehicle. Widening this to "anybody aboard" would start
--- crediting kills to whoever happened to be sitting in the car, and a wrong
--- credit is worse than no credit.
--- @param entity integer|nil
--- @param victim integer
--- @return integer|nil serverId
--- @return integer why
local function playerBehind(entity, victim)
    if not entity or entity == 0 then return nil, WHY_NOTHING end
    if entity == victim then return nil, WHY_SELF end
    if not DoesEntityExist(entity) then return nil, WHY_NOTHING end

    local ped = entity
    if not IsEntityAPed(ped) then
        -- ASKED FOR RATHER THAN ASSUMED, on the one path in this file that
        -- MUST NOT raise. handleDeath is the whole of how a death is
        -- reported: throw here and the fighter lies on the floor with no
        -- report sent, no respawn scheduled, and the fence sweep counting
        -- down to throwing them out of a round they paid for. These two are
        -- the only natives this function adds, so they are the only two that
        -- could be missing from a build.
        if type(IsEntityAVehicle) ~= 'function' or type(GetPedInVehicleSeat) ~= 'function' then
            return nil, WHY_NOT_A_PLAYER
        end
        if not IsEntityAVehicle(ped) then return nil, WHY_NOT_A_PLAYER end

        ped = GetPedInVehicleSeat(ped, -1)
        if not ped or ped == 0 then return nil, WHY_NOT_A_PLAYER end
        if ped == victim then return nil, WHY_SELF end
        if not DoesEntityExist(ped) then return nil, WHY_NOT_A_PLAYER end
    end

    if not IsPedAPlayer(ped) then return nil, WHY_NOT_A_PLAYER end

    local index = NetworkGetPlayerIndexFromPed(ped)
    if not index or index == -1 then return nil, WHY_NOT_NETWORKED end

    -- A SERVER ID OF NOUGHT IS NOT A KILLER, AND IT IS NOT "NOBODY" EITHER.
    -- GET_PLAYER_SERVER_ID answers 0 for a player index the client CANNOT
    -- resolve, and 0 went out on the wire as the claim. resolveKiller refuses
    -- it, which is right -- but the server's "named nobody" branch tests for
    -- nil, so a 0 fell between the two: no kill paid, and not counted as a
    -- death that named nobody either. It is the streamed-out case, so it is
    -- reported as exactly that, and a 0 must not reach the wire again.
    local id = GetPlayerServerId(index)
    if not id or id <= 0 then return nil, WHY_NOT_NETWORKED end

    return id, WHY_NOTHING
end

local function handleDeath(ped, attacker)
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
    --
    -- THE DAMAGE EVENT'S ATTACKER FIRST, AND THIS IS THE WHOLE OF "HEADSHOTS
    -- GIVE NO POINTS".
    --
    -- GET_PED_SOURCE_OF_DEATH is not populated in the frame the ped dies: the
    -- engine fills it in when the death state is finalised, which is after
    -- the damage event has been dispatched. Whether that matters depends
    -- entirely on WHICH of this file's two spotters gets there first --
    --
    --   the watch loop finds the body on its next pass, a frame or more
    --   later, by which time the source is set and the kill is credited;
    --
    --   the CEventNetworkEntityDamage hook above runs in the frame the ped
    --   dies -- deliberately, because that is what stops a medical script
    --   filing an ambulance out of the arena -- and there the source is 0.
    --
    -- So a kill that took several shots, or that ended in a bleed-out, was
    -- credited, and one that killed outright was not: killerServerId went out
    -- nil, the server had no claim to check, and nothing was logged at either
    -- end because a nil claim is not a rejected claim. From a seat that is
    -- "headshots do not give points", and the better the shot the more
    -- reliably it happened.
    --
    -- The damage event carries the attacker in its own payload, so the hook
    -- hands it in. Everything below still applies to it: it has to be a ped,
    -- a player, and not the victim.
    --
    -- THE SECOND DEFECT, AND IT IS THE ONE THE OWNER IS LOOKING AT. The two
    -- readings were tried in a FIXED ORDER and the first non-empty one was
    -- committed to: `source = attacker`, and the source of death was
    -- consulted ONLY when the attacker was missing entirely. So an attacker
    -- that existed but could not be turned into a player -- an explosion the
    -- engine blames on the vehicle that carried it, a bullet whose shooter
    -- streamed out between the shot and the corpse -- ended the search, and
    -- GET_PED_SOURCE_OF_DEATH, which frequently names the shooter in exactly
    -- those cases, was never asked. One reading being empty is not a reason
    -- to stop reading. THEY ARE ASKED IN TURN NOW, and the first that
    -- actually resolves to a player wins.
    --
    -- ORDER IS STILL DELIBERATE, because they can disagree and the least
    -- second-hand answer must win: the blow that was actually struck, then
    -- the one this client remembers striking it, then the engine's own
    -- summary once the death finished settling.
    local remembered
    if lastFatalEntity and (GetGameTimer() - lastFatalAt) <= FATAL_MEMORY_MS then
        remembered = lastFatalEntity
    end
    lastFatalEntity = nil

    local ofDeath = GetPedSourceOfDeath(ped)

    local killerServerId, why = playerBehind(attacker, ped)
    if not killerServerId then
        local id, second = playerBehind(remembered, ped)
        killerServerId, why = id, math.max(why, second)
    end
    if not killerServerId then
        local id, third = playerBehind(ofDeath, ped)
        killerServerId, why = id, math.max(why, third)
    end

    -- DO NOT put this back behind Config.Debug. THE REPORT this whole change
    -- exists for is a player quoting this line -- "it said nobody was seen as
    -- the killer in my f8" -- and what it said was two raw entity handles,
    -- which is nothing anybody can act on. It prints once per death, to the
    -- dead player alone, and it names the CAUSE: the one fact that separates
    -- "the arena killed me" from "somebody shot me and got nothing for it".
    if not killerServerId then
        local cause = type(GetPedCauseOfDeath) == 'function' and GetPedCauseOfDeath(ped) or nil
        print(('[crimson_arena] your death could not be pinned on anybody, so nobody was credited '
            .. 'for it -- %s. Cause of death hash %s, attacker %s, source of death %s. If somebody '
            .. 'shot you, tell the server owner and quote this line.')
            :format(WHY_TEXT[why] or 'reason unknown',
                tostring(cause), tostring(attacker), tostring(ofDeath)))
    end

    local report = { killerServerId = killerServerId }
    if not killerServerId then report.why = why end

    TriggerServerEvent('crimson_arena:server:reportDeath', report)

    -- Reported first, cleared second. The server's record of the kill must
    -- not depend on how fast this runs, and this must run before any medical
    -- script comes round and finds a casualty to send an ambulance to.
    ArenaDispatch.ClearDeadState(ped)
end

AddEventHandler('gameEventTriggered', function(event, data)
    if event ~= 'CEventNetworkEntityDamage' then return end
    if not currentMatch or deathReported then return end

    local victim, attacker, victimDied = data[1], data[2], data[4]
    if victimDied ~= 1 and victimDied ~= true then return end
    if not victim or not DoesEntityExist(victim) then return end
    if victim ~= PlayerPedId() then return end

    -- REMEMBERED BEFORE IT IS HANDED OVER, and that order is the fix.
    -- handleDeath refuses a ped the engine has not finished killing, and on
    -- the shots where that is still true in this frame the call below did
    -- nothing at all -- taking the one good attacker in this whole file with
    -- it. Stored first, the watch loop's later pass finds it waiting. See
    -- FATAL_MEMORY_MS for why it is stamped and must not outlive the death.
    lastFatalEntity = attacker
    lastFatalAt = GetGameTimer()

    handleDeath(victim, attacker)
end)

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

            if deathReported or not matchLive then
                DisablePlayerFiring(PlayerId(), true)
                DisableControlAction(0, 24, true)       -- attack
                DisableControlAction(0, 25, true)       -- aim
                DisableControlAction(0, 257, true)      -- attack, alternate
                DisableControlAction(0, 263, true)      -- melee attack
            end

            if not deathReported
                and arenaVitals.until_ > 0
                and GetGameTimer() < arenaVitals.until_
            then
                local ped = PlayerPedId()
                if arenaVitals.health then SetEntityHealth(ped, arenaVitals.health) end
                if arenaVitals.armour then SetPedArmour(ped, arenaVitals.armour) end
            end

            local current = PlayerPedId()
            if friendlyFireHeld
                and (current ~= heldPed or GetPlayerTeam(PlayerId()) ~= heldTeam)
            then
                holdFriendlyFire(current)
            end

            handleDeath(current)

            -- HOLD THE TEAM OUTLINE AGAINST THE OTHER RESOURCES ON THE BOX.
            --
            -- The outline colour and shader are ONE setting for the whole
            -- game, not a property of the ped. refreshOutlines sets them, but
            -- it runs twice a second at best, and any resource that sets them
            -- every frame -- a target script highlighting what you look at, a
            -- job script marking a delivery -- owns them for the other four
            -- hundred milliseconds, and the teammate outline goes that
            -- resource's colour. On a server running several such scripts
            -- that is indistinguishable from the outline not working at all.
            --
            -- NOT A GUARANTEE. The setting is sampled once a frame at render,
            -- so two per-frame writers are resolved by which ticks last --
            -- resource start order, not anything in this file. Before this we
            -- lost to such a resource always; now we lose only to one that
            -- starts after us. If that ever turns out to be happening, start
            -- crimson_arena last.
            --
            -- AND THAT IS THE OPPOSITE OF WHAT THE DEATH HANDLING ASKS FOR.
            -- shared/compat/dispatch.lua tells an operator whose ambulance
            -- job is being paged for fighters to start this resource FIRST,
            -- which is the order that loses this race every frame -- so an
            -- operator can follow one instruction and break the other, and
            -- nothing in any log will disagree, because as far as this file
            -- is concerned it drew the outline. WarnLateStartOnce now says
            -- so where it gives that advice, and points at the state-flag
            -- snippet that makes the death fix independent of order.
            --
            -- Done HERE rather than in a thread of its own: this loop is
            -- already per-frame for the death backstop above, so holding the
            -- outline costs two native calls and no new thread -- and a new
            -- thread measurably changed what blipscope_spec measures about
            -- the blip loop's own sleeping.
            local tint = outlineTint
            if tint and next(outlined) ~= nil then
                SetEntityDrawOutlineColor(tint.r, tint.g, tint.b, 255)
                SetEntityDrawOutlineShader(OUTLINE_SHADER)
                holdOutlineTechnique()
            end

            -- AND THE MARKER, WHICH IS THE HALF THAT HAS TO WORK.
            --
            -- Per frame because a rectangle drawn at a world point is not a
            -- state anybody keeps: it exists for the frame it is drawn in
            -- and no longer. That is the property being bought -- there is
            -- nothing to lose when a ped is remade, and nothing to leave
            -- behind when the round ends.
            --
            -- IN THIS THREAD RATHER THAN A NEW ONE, for the reason the
            -- paragraph above gives about the outline hold, and one more:
            -- this thread's condition is `currentMatch`, so the marker stops
            -- in the same frame the match does. A thread of its own would be
            -- a second lifetime to keep in step with this one, and the round
            -- must not be able to end with one of them still running.
            --
            -- drawTeamMarks is written to be incapable of raising: this loop
            -- also carries the death backstop, and a fighter whose client
            -- threw here is a fighter whose death is never reported.
            drawTeamMarks()

            Wait(0)
        end
    end)
end

local function startBoundaryThread(boundary)
    if type(boundary) ~= 'table' or boundary.enabled ~= true then return end

    -- A CENTRE THAT CANNOT BE READ MUST NOT TAKE THE BLIPS WITH IT.
    --
    -- This indexed boundary.center directly. The server builds that field
    -- with toPoint, which deliberately answers nil for a centre missing an
    -- x, y or z -- and a plain table of numbers is a shape toPoint's own
    -- header says an operator may write, so one missing `z` is exactly what
    -- it is written to reject. Nothing downstream handled the rejection, so
    -- this line threw.
    --
    -- WHERE THE THROW LANDED IS THE REAL COST. Its one caller runs
    -- `matchLive = true`, unfreezes the ped, calls this, and THEN calls
    -- startBlipThread. Raising here started the round with no boundary --
    -- nobody warned, nobody bled, fighters free to walk out and stay out --
    -- and no teammate or enemy blips for anyone, for every player, every
    -- round on that arena. The only symptom was one red line in F8.
    local cx = tonumber(boundary.center and boundary.center.x)
    local cy = tonumber(boundary.center and boundary.center.y)
    local cz = tonumber(boundary.center and boundary.center.z)
    if not cx or not cy or not cz then
        print('[crimson_arena] THIS ARENA HAS NO USABLE BOUNDARY CENTRE, so nobody will be warned or '
            .. 'bled for leaving it. Check Config.Arenas[...].boundary.center -- it needs x, y and z. '
            .. 'Everything else about the round is unaffected.')
        return
    end

    local token = matchToken
    local center = vector3(cx, cy, cz)
    local radius = (tonumber(boundary.radius) or 0.0) + 0.0
    local graceMs = (boundary.warningSeconds or 0) * 1000
    local damage = boundary.damagePerTick or 0
    local tickMs = boundary.tickMs or 1000
    local leftAt

    CreateThread(function()
        while matchLive and matchToken == token do
            local ped = PlayerPedId()

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

ArenaMatch = {}

local keepOut = {}

local warnedZone = nil

function ArenaMatch.SetKeepOut(zones)
    keepOut = type(zones) == 'table' and zones or {}
    if #keepOut == 0 then warnedZone = nil end
end

--- The zone a point is inside, or nil.
---
--- A SPHERE, NOT A COLUMN, and the difference was a kilometre wide.
---
--- server/lobby.lua says of this fence: "The BOUNDARY is the fence,
--- deliberately -- the same circle the fighters themselves are bled for
--- leaving. One arena has one edge." The fighters' edge is genuinely
--- spherical -- startBoundaryThread does `#(GetEntityCoords(ped) - center) >
--- radius` on a vector3 -- and this took x and y only. The server has always
--- sent the height; nothing read it.
---
--- So while a skydome round was live -- centre (1500, 3000, 1201), radius
--- 110 -- ANYONE STANDING IN THE GRAND SENORA DESERT A KILOMETRE BELOW IT
--- was inside the fence: teleported 116 m sideways four times a second and
--- told "A match is being fought at The Skydome. You have been moved outside
--- it." Nothing they could see explained it and nothing they could do
--- stopped it. Over the trailer park the same column pulled anyone flying
--- across out of the air and put them on the ground at the rim.
---
--- The 2D fallback is kept for a zone with no height rather than refusing
--- one: an older server, or an arena whose boundary centre was written
--- without a z, should still fence its own ground.
--- @return table|nil zone
--- @return number|nil distance -- HORIZONTAL, which is what the push uses
local function zoneAt(x, y, z)
    for _, zone in ipairs(keepOut) do
        local zx, zy = tonumber(zone.x), tonumber(zone.y)
        local radius = tonumber(zone.radius)
        if zx and zy and radius then
            local dx, dy = x - zx, y - zy
            local flat = math.sqrt(dx * dx + dy * dy)

            local zz = tonumber(zone.z)
            local reach = flat
            if zz and z then
                local dz = z - zz
                reach = math.sqrt(dx * dx + dy * dy + dz * dz)
            end

            if reach < radius then return zone, flat end
        end
    end
    return nil, nil
end

CreateThread(function()
    while true do
        local barrier = (Config.Match or {}).keepOutBarrier
        local on = type(barrier) == 'table' and barrier.enabled == true

        if not on or #keepOut == 0 then
            warnedZone = nil
            Wait(1000)
        else
            local ped = PlayerPedId()
            local coords = GetEntityCoords(ped)
            local zone, distance = zoneAt(coords.x, coords.y, coords.z)

            if zone then
                local radius = tonumber(zone.radius) or 0
                local push = math.max(1.0, tonumber(barrier.pushBackMetres) or 6.0)

                local dx, dy = coords.x - zone.x, coords.y - zone.y
                local length = math.max(0.01, distance or 0.01)
                if (distance or 0) < 0.5 then dx, dy, length = 1.0, 0.0, 1.0 end

                local target = radius + push
                local nx = zone.x + (dx / length) * target
                local ny = zone.y + (dy / length) * target

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

    if row.alive ~= true then return nil end

    local teamMode = Arena.ModeUsesTeams(currentMatch.modeKey)
    local ownTeam = teamMode and currentMatch.teamKey or nil
    local teammate = teamMode and Arena.IsKey(ownTeam) and row.team == ownTeam

    if teammate then
        if Config.Teams.showTeamBlips ~= true then return nil end
    elseif not includeEnemies and Config.Teams.showEnemyBlips ~= true then
        return nil
    end

    local team = teamMode and Arena.GetTeamByKey(row.team) or nil
    return (team and Arena.ToInt(team.blipColor)) or BLIP_FALLBACK_COLOR
end

local function pedForServerId(serverId)
    local player = GetPlayerFromServerId(serverId)
    if player == -1 or not NetworkIsPlayerActive(player) then return nil end

    local ped = GetPlayerPed(player)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    return ped
end

local function createBlipOn(ped, color, name)
    local blip = AddBlipForEntity(ped)

    SetBlipSprite(blip, 1)
    SetBlipColour(blip, color)
    SetBlipDisplay(blip, 4)
    SetBlipAsShortRange(blip, false)

    if Arena.IsKey(name) then
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(name)
        EndTextCommandSetBlipName(blip)
    end

    return blip
end

local function removePlayerBlip(serverId)
    local blip = playerBlips[serverId]
    if blip and DoesBlipExist(blip) then RemoveBlip(blip) end
    playerBlips[serverId] = nil
end

local function removeAllPlayerBlips()
    for serverId in pairs(playerBlips) do
        removePlayerBlip(serverId)
    end
end

local lastOutlineReason = nil

local function outlineReason(reason)
    if reason == lastOutlineReason then return end
    lastOutlineReason = reason
    if Config.Debug then
        print(('[crimson_arena] [debug] team outline: %s'):format(reason))

        TriggerServerEvent('crimson_arena:server:outlineReason', reason)
    end
end

local function refreshOutlines()
    local wanted = {}

    if not currentMatch then
        outlineReason('not in a match')
    elseif Config.Teams.showTeamOutline ~= true then
        outlineReason('Config.Teams.showTeamOutline is not true')
    elseif not Arena.ModeUsesTeams(currentMatch.modeKey) then
        outlineReason(('mode "%s" has no teams, so there is nobody to outline')
            :format(tostring(currentMatch.modeKey)))
    elseif not Arena.IsKey(currentMatch.teamKey) then
        outlineReason('this client was not told which team it is on')
    end

    if currentMatch and Config.Teams.showTeamOutline == true
        and Arena.ModeUsesTeams(currentMatch.modeKey)
        and Arena.IsKey(currentMatch.teamKey)
    then
        local selfId = GetPlayerServerId(PlayerId())
        local team = Arena.GetTeamByKey(currentMatch.teamKey)
        local r, g, b = Arena.HexToRgb(team and team.color)

        if not r then
            outlineReason(('team "%s" has no readable colour (%s), so nothing is drawn')
                :format(tostring(currentMatch.teamKey), tostring(team and team.color)))
        end

        if r then
            local mates, alive, streamed = 0, 0, 0
            for _, row in ipairs(roster) do
                local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
                if serverId and serverId ~= selfId and row.team == currentMatch.teamKey then
                    mates = mates + 1
                    if row.alive == true then
                        alive = alive + 1
                        local ped = pedForServerId(serverId)
                        if ped then
                            streamed = streamed + 1
                            wanted[ped] = true

                            SetEntityDrawOutline(ped, true)
                            outlined[ped] = true
                        end
                    end
                end
            end

            if streamed > 0 then
                outlineReason(('drawing %d teammate(s) in %s'):format(streamed, tostring(currentMatch.teamKey)))
            else
                outlineReason(('nothing to draw -- roster %d, on your side %d, of those alive %d, of those streamed 0')
                    :format(#roster, mates, alive))
            end

            outlineTint = { r = r, g = g, b = b }
            if streamed > 0 then
                SetEntityDrawOutlineColor(r, g, b, 255)
                SetEntityDrawOutlineShader(OUTLINE_SHADER)
                holdOutlineTechnique()
            end
        end
    end

    if next(wanted) == nil then outlineTint = nil end

    for ped in pairs(outlined) do
        if not wanted[ped] then
            if DoesEntityExist(ped) then SetEntityDrawOutline(ped, false) end
            outlined[ped] = nil
        end
    end
end

-- ----------------------------------------------------------------------
-- THE MARKER OVER A TEAMMATE'S HEAD
--
-- Two functions: this one decides WHO, once per roster; drawTeamMarks below
-- draws them, every frame.
--
-- ITS OWN SCAN OF THE ROSTER, NOT A SHARE OF refreshOutlines'. Six lines of
-- gating are repeated here on purpose. The outline and the marker were
-- asked for as two answers that must not be able to fail together, and a
-- marker computed inside refreshOutlines would be switched off by
-- showTeamOutline, skipped by an early return added to it later, and
-- carried down by anything that ever raises in it. It is the shared
-- dependency that would make one fault take both, so there is not one.
--
-- WHAT IT WILL NOT DO, and neither of these is negotiable:
--
--   IT NEVER TAKES AN ENEMY. The marker draws through walls. On the other
--   side that is a wallhack with a palette, and the only person who would
--   ever notice is the one it is helping.
--
--   IT NEVER RUNS IN A MODE WITHOUT TEAMS. Free-for-all and gun game have
--   no teammates to mark, so there is nobody this applies to.
-- ----------------------------------------------------------------------

local function refreshTeamMarks()
    local marks = {}
    local tint = nil

    if currentMatch
        and Config.Teams.showTeamMarker == true
        and Arena.ModeUsesTeams(currentMatch.modeKey)
        and Arena.IsKey(currentMatch.teamKey)
    then
        local team = Arena.GetTeamByKey(currentMatch.teamKey)
        local r, g, b = Arena.HexToRgb(team and team.color)

        if r then
            -- THE SAME HEX THE OUTLINE AND THE PANEL READ, through the same
            -- helper. `color` is a hex string and `blipColor` is a numbered
            -- GTA map colour; they are two systems and this must not reach
            -- for the wrong one, or the marker is one colour and the dot on
            -- the map is another.
            tint = { r = r, g = g, b = b }

            local selfId = GetPlayerServerId(PlayerId())
            for _, row in ipairs(roster) do
                local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
                if serverId
                    and serverId ~= selfId
                    and row.alive == true
                    and row.team == currentMatch.teamKey
                then
                    marks[#marks + 1] = serverId
                end
            end
        end
    end

    teamMarkTint = tint
    teamMarks = marks
end

--- Everything the marker leaves behind when a round ends, which is nothing
--- -- there is no handle and no engine flag, so emptying the list IS the
--- teardown. Called anyway on every exit path the blips and outlines use,
--- because a list this thread reads must not outlive the match that filled
--- it even by one frame.
local function clearTeamMarks()
    teamMarks = {}
    teamMarkTint = nil
end

-- ASSIGNED, NOT DECLARED. This fills in the local declared at the top of
-- the file. DO NOT put `local` in front of it: that declares a second,
-- different variable, leaves the first one nil, and the per-frame thread
-- raises on the first frame of the first round -- see that declaration.
--
-- Nor `function drawTeamMarks()` in the first column, which would read as
-- one of this file's public entry points -- to a reader, and to the
-- checklist that counts them against REFERENCE.md -- and it is not one.
drawTeamMarks = function()
    local tint = teamMarkTint
    if not tint or not MARKER_NATIVES then return end

    for index = 1, #teamMarks do
        local ped = pedForServerId(teamMarks[index])

        -- ON SCREEN, NOT IN SIGHT, and the difference is the feature.
        -- IS_ENTITY_ON_SCREEN asks whether the ped is inside the camera's
        -- view, and answers yes through a wall -- which is what is wanted.
        -- What it keeps out is a teammate BEHIND the camera: a draw origin
        -- given a point behind you projects to a mirrored place on screen,
        -- and the marker would appear over open ground with nobody there.
        --
        -- DO NOT replace this with a line-of-sight or shape test to "stop
        -- it showing through walls". Showing through walls is the whole
        -- reason it exists, and a marker you can only see when you can
        -- already see the player tells you nothing you did not know.
        if ped and IsEntityOnScreen(ped) then
            local x, y, z = markerHeadCoords(ped)

            SetDrawOrigin(x, y, z, 0)

            -- The dark plate first, then the colour over it. Two passes
            -- rather than one so the plate can never land on top of the row
            -- it is behind.
            for _, row in ipairs(MARKER_ROWS) do
                DrawRect(0.0, -row[1],
                    (row[2] + MARKER_EDGE_X) * 2.0, MARKER_ROW_HEIGHT + MARKER_EDGE_Y,
                    0, 0, 0, 190)
            end
            for _, row in ipairs(MARKER_ROWS) do
                DrawRect(0.0, -row[1], row[2] * 2.0, MARKER_ROW_HEIGHT,
                    tint.r, tint.g, tint.b, 255)
            end

            -- A DRAW ORIGIN MUST NOT outlive the draws it was opened for.
            -- Left open, the next resource to draw an interface element
            -- this frame draws it at a teammate's head instead of on the
            -- screen -- somebody else's speedometer or notification,
            -- floating in the arena, and nothing pointing back to here.
            ClearDrawOrigin()
        end
    end
end

local function removeAllOutlines()
    for ped in pairs(outlined) do
        if DoesEntityExist(ped) then SetEntityDrawOutline(ped, false) end
    end
    outlined = {}

    if ResetEntityDrawOutlineRenderTechnique then
        ResetEntityDrawOutlineRenderTechnique()
    end

    -- WHAT IS NOT HANDED BACK, SAID PLAINLY, because this used to claim it
    -- was. The line above read "Same rule the colour and the shader follow",
    -- and neither of them followed it.
    --
    -- THE SHADER does not need to: SetEntityDrawOutlineShader takes an index
    -- into the three renderers the engine registers, and this file asks for
    -- 0 -- the first of them. Setting a global to the value it already holds
    -- costs nobody anything.
    --
    -- THE COLOUR IS A REAL GAP, and it is left open deliberately rather than
    -- papered over. SET_ENTITY_DRAW_OUTLINE_COLOR is one setting for the
    -- whole client -- neither call site takes an entity -- so from the end of
    -- the first team round until the game restarts, any other script that
    -- outlines something without setting its own colour draws in the last
    -- team's tint. The cost is cosmetic and lands on other resources.
    --
    -- There is no reset native for it and no getter to capture the previous
    -- value with, so putting it back means writing a constant for the
    -- engine's default -- and that default is not something this file can
    -- read. Twenty lines up is what guessing at engine internals cost here
    -- last time: "That was invented, not read", two rounds of "the haze
    -- still is not working". A wrong constant broadcast into a client-wide
    -- global is a worse bug than the one it would be fixing, so this stays a
    -- documented gap until somebody can read the real default out of the
    -- engine.
end

local function refreshBlips(includeEnemies)
    local selfId = GetPlayerServerId(PlayerId())
    local wanted = {}

    for _, row in ipairs(roster) do
        local serverId = type(row) == 'table' and Arena.ToInt(row.id) or nil
        if serverId and serverId ~= selfId then
            local color = blipColorFor(row, includeEnemies)
            if color then wanted[serverId] = { color = color, name = row.name } end
        end
    end

    for serverId in pairs(playerBlips) do
        if not wanted[serverId] then removePlayerBlip(serverId) end
    end

    for serverId, want in pairs(wanted) do
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

local function radarConfig()
    local block = (Config.Match or {}).radar
    return type(block) == 'table' and block or {}
end

local radarForMatch = nil

local function radarOn()
    if radarConfig().allowChoose == false then return radarConfig().defaultOn == true end
    return radarForMatch == true
end

function ArenaMatch.SetRadar(on)
    radarForMatch = on == true
    if not radarForMatch then removeAllPlayerBlips() end
end

local function startBlipThread()
    if not currentMatch then return end

    local token = matchToken
    local permanent = permanentEnemyBlips()

    CreateThread(function()
        while matchLive and matchToken == token do
            -- BEFORE refreshOutlines, on purpose. This loop is the marker's
            -- SECOND way of learning who is alive -- the matchHud handler is
            -- the first, and it does not run in here at all -- and a pass
            -- that raised inside refreshOutlines must still have refreshed
            -- the marker before it did. One line of ordering, and it is the
            -- difference between the outline failing and both failing.
            refreshTeamMarks()
            refreshOutlines()

            if permanent then
                refreshBlips(true)
                Wait(BLIP_REFRESH_MS)
            elseif radarOn() then
                refreshBlips(true)
                Wait(math.max(100, Arena.ToInt(radarConfig().visibleMs) or 800))

                removeAllPlayerBlips()
                refreshBlips(false)
                refreshTeamMarks()
                refreshOutlines()

                local interval = math.max(1000, Arena.ToInt(radarConfig().intervalMs) or 30000)
                local visible = math.max(100, Arena.ToInt(radarConfig().visibleMs) or 800)
                local dark = math.max(500, interval - visible)

                local slept = 0
                while slept < dark and matchLive and matchToken == token do
                    local step = math.min(BLIP_REFRESH_MS, dark - slept)
                    Wait(step)
                    slept = slept + step

                    if slept < dark then
                        refreshTeamMarks()
                        refreshOutlines()
                        refreshBlips(false)
                    end
                end
            else
                refreshBlips(false)
                Wait(1000)
            end
        end

        -- The loop owns whatever it lit. leaveArena clears everything on the
        -- way out, but a match that ends between two sweeps must not leave
        -- the last one burning until it does.
        removeAllPlayerBlips()
        removeAllOutlines()
        clearTeamMarks()
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

local FLOOR_PIECES_WORTH_WARNING_ABOUT = 40

local arenaProps = {}

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

local spectatorBuilt = false

local function modelFootprint(hash)
    local minimum, maximum = GetModelDimensions(hash)
    if not Arena.IsPoint(minimum) or not Arena.IsPoint(maximum) then
        return 0.0, 0.0, 0.0, 0.0
    end

    return (maximum.x or 0.0) - (minimum.x or 0.0),
           (maximum.y or 0.0) - (minimum.y or 0.0),
           (maximum.z or 0.0),
           (minimum.z or 0.0)
end

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

local function removeArenaProps()
    for _, object in ipairs(arenaProps) do
        if DoesEntityExist(object) then
            SetEntityAsMissionEntity(object, true, true)
            DeleteObject(object)
        end
    end
    arenaProps = {}
end

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
    spectatorBuilt = false
    if builtArena then sweepStrayArenaProps(builtArena.key, builtArena.factor) end
    arenaSurfaceZ = nil
end

local function buildArenaProps(arenaKey, factor, boundary)
    clearArenaScenery()

    sweepStrayArenaProps(arenaKey, factor)
    builtArena = { key = arenaKey, factor = factor }
    spectatorBuilt = false

    -- THE SAME FACTOR THE SERVER PLANNED THE SPAWNS WITH. It arrives on the
    -- entry payload rather than being worked out here, because this side
    -- cannot see the roster -- and two ends deriving the same number
    -- separately is how they come to disagree about where the floor ends.
    local platform = Arena.GetPlatform(arenaKey, factor)

    local measured = nil
    if platform then
        local hash, name = loadPropModel(platform.models)
        if hash then
            local sizeX, sizeY, top = modelFootprint(hash)
            if sizeX > 0.0 and sizeY > 0.0 then
                measured = { x = sizeX, y = sizeY, top = top }
            end
            arenaSurfaceZ = platform.z
            if name ~= platform.models[1] then
                print(('[crimson_arena] arena scenery: the floor fell back to \'%s\' -- this build does not have \'%s\'.')
                    :format(tostring(name), tostring(platform.models[1])))
            end
        end
    end

    local wanted = Arena.ArenaProps(arenaKey, measured, factor)
    if #wanted == 0 then
        return true
    end

    local needsFloor = platform ~= nil
    local built, builtFloor, failed = 0, 0, {}

    local builtCover, coverReach = 0, 0.0

    -- NO YIELD IN THIS LOOP, AND THAT IS A DECISION MADE TWICE.
    --
    -- The build does up to four hundred CreateObjects, and doing them in one
    -- frame is a visible freeze. So it was changed to hand the frame back
    -- every thirty-two pieces -- and a player who had entered the skydome
    -- without trouble for weeks began crashing on every single entry.
    --
    -- The first explanation was that the yield let the streamer act on the
    -- per-piece SetModelAsNoLongerNeeded between batches, so the models are
    -- now held for the whole build and released at the end (see `held`
    -- below). That is a real improvement and it was not enough: the crashes
    -- carried on.
    --
    -- So the yield is gone. A freeze is a bad frame; a crash is somebody
    -- unable to play. The freeze was inferred from a hitch warning and never
    -- confirmed as anybody's actual complaint, while the crash was reported
    -- by name, twice, and started when this changed. On that evidence the
    -- one-frame build wins, and it stays until there is a way to spread the
    -- work that has been shown not to do this.
    --
    -- IF YOU COME BACK TO THIS: the freeze is real and worth solving. What
    -- is not established is that yielding mid-build is safe on a client
    -- streaming an arena a kilometre up.
    --
    -- AND DO NOT REACH FOR `maxTiles`. It looks like the safe lever and it is
    -- not: the shipped skydome needs all 291 of its container tiles to reach
    -- the wall. Trimming to 250 opens a hole in the floor at 43m, and 200
    -- opens one at 39m -- both well INSIDE a wall at 44.5m, which is a
    -- fighter dropping a kilometre through ground they were standing on.
    -- The rim `maxTiles` trims is not the unreachable overshoot; the
    -- overshoot is what is left after the disc is covered.
    --
    -- The count itself is the thing worth attacking, and the way to attack it
    -- is the PROP, not the cap -- see the fallback warning further down.

    local held = {}
    for _, piece in ipairs(wanted) do
        local hash = loadPropModel(piece.models or piece.model)
        if hash then
            local placeZ = piece.z

            local heading = piece.heading or 0.0

            if piece.kind ~= 'floor' then
                local sizeX, sizeY, _, bottom = modelFootprint(hash)
                placeZ = placeZ - bottom + COVER_LIFT

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
                    local ox, oy = piece.offsetX or 0.0, piece.offsetY or 0.0
                    local out = math.sqrt(ox * ox + oy * oy)
                    if out > coverReach then coverReach = out end
                end
                SetEntityHeading(object, heading)
                FreezeEntityPosition(object, true)
                SetEntityCollision(object, true, true)
                SetEntityInvincible(object, true)
                SetEntityLodDist(object, PROP_LOD_DISTANCE)
                SetEntityAsMissionEntity(object, true, true)
                arenaProps[#arenaProps + 1] = object
                built = built + 1
            end
            held[hash] = true
        else
            failed[table.concat(piece.models or { piece.model }, ' / ')] = true
        end
    end

    for hash in pairs(held) do SetModelAsNoLongerNeeded(hash) end

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

        -- WHICH PROP THIS CLIENT GOT DECIDES HOW HEAVY THE ARENA IS, AND THE
        -- TWO ANSWERS ARE NOT CLOSE.
        --
        -- Every floor names a CHAIN of models ending in one the base game
        -- always has, so a build missing a DLC still gets a floor. That makes
        -- it survivable, and it hides how differently it survives: the
        -- shipped skydome is NINE pieces tiled out of the stunt block at the
        -- head of its chain, and TWO HUNDRED AND NINETY-ONE tiled out of the
        -- shipping container at the end of it. Same arena, same round, one
        -- client, thirty-two times the objects -- every one of them pinned as
        -- a mission entity so the engine may not reclaim it under pressure.
        --
        -- That is a per-client difference decided by which assets that
        -- player's build has, which is exactly the shape of "one of the three
        -- of us crashes going in and the other two are fine". It was already
        -- printed -- as a piece count, on one line, with nothing to compare
        -- it against and no reason to look twice.
        --
        -- So it is named. The threshold is deliberately not clever: any floor
        -- that took more than a few dozen pieces came off the small end of a
        -- chain, whatever the arena.
        if builtFloor > FLOOR_PIECES_WORTH_WARNING_ABOUT then
            print(('[crimson_arena] arena scenery: THIS CLIENT BUILT THE FLOOR OUT OF %d PIECES.')
                :format(builtFloor))
            print('[crimson_arena]   That is the small-prop end of the model chain -- the large prop at the')
            print('[crimson_arena]   head of it is missing from this build, and the same arena is a handful')
            print('[crimson_arena]   of pieces on a client that has it. Every piece is a pinned object, so')
            print('[crimson_arena]   this client is carrying far more of them than anybody else in the round.')
            print('[crimson_arena]   If a player crashes entering this arena and others do not, this is the')
            print('[crimson_arena]   first thing to check. Stream the large prop, or give the arena a floor')
            print('[crimson_arena]   model every one of your players actually has -- see STREAMING.md.')
            print('[crimson_arena]   Do NOT answer it by lowering platform.maxTiles: the floor needs every')
            print('[crimson_arena]   one of these pieces to reach its wall, and trimming them puts a hole')
            print('[crimson_arena]   in the ground inside it.')
        end
    end

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

        if coverReach > 0.0 and reach > coverReach + 0.5 then
            print(('[crimson_arena] arena scenery: THE WALL DOES NOT ENCLOSE THE FLOOR -- the furthest cover stands %.2fm out and the floor reaches %.2fm, so there is %.2fm of walkable ground OUTSIDE the wall and fighters can walk round it and fall. Either move the cover ring out to %.2fm in Config.Arenas["%s"].cover, or give platform.models a smaller prop so the floor stops short of the wall.')
                :format(coverReach, reach, reach - coverReach, reach, tostring(arenaKey)))
        end
    end

    if needsFloor and builtFloor == 0 then
        arenaSurfaceZ = nil
        print('[crimson_arena] arena scenery: NO FLOOR was built for an arena that supplies its own. Nobody is being placed into it -- there is nothing under it.')
        return false
    end

    return true
end

--- Puts the world back the way we found it. Synchronous on purpose: it is
--- also the resource-stop path, and a stop handler that yields is a stop
--- handler that does not finish.
--- @param returnCoords table|nil
local function leaveArena(returnCoords)
    clearArenaScenery()

    releaseFriendlyFire(PlayerPedId())

    if not currentMatch then return end

    currentMatch = nil
    matchLive = false
    deathReported = false
    matchToken = matchToken + 1

    removeAllPlayerBlips()
    removeAllOutlines()
    clearTeamMarks()
    roster = {}

    if ArenaSpectate then ArenaSpectate.Stop() end

    ArenaDispatch.Exit()

    ClearOverrideWeather()
    NetworkClearClockTimeOverride()

    local ped = PlayerPedId()
    local coords = returnCoords or Config.Lobby.returnCoords

    if IsEntityDead(ped) then
        NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, coords.w or 0.0, true, false)
        ped = PlayerPedId()
    end

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

function ArenaMatch.EnsureSpectatorScenery(arenaKey, factor)
    if not Arena.IsKey(arenaKey) then return false end

    local wantedFactor = tonumber(factor) or 1.0

    -- WHAT IS STANDING, NOT WHAT WAS LAST BUILT.
    --
    -- This used to be `builtArena and builtArena.key == arenaKey`, and
    -- builtArena is DELIBERATELY never cleared -- clearArenaScenery's own
    -- header says so, because the sweep needs it to outlive the round. So
    -- after any teardown of this arena on this client the props are gone and
    -- builtArena still names it: the guard answered "already standing" for
    -- an empty world, and reported it as `standing = true`.
    --
    -- Watch a skydome round, stop watching, watch another: no floor and no
    -- container wall, fighters hanging in empty air, and it never recovered
    -- for the rest of the session. `arenaProps` is the real record -- it is
    -- emptied by removeArenaProps and refilled by a build.
    --
    -- THE SIZE IS NOT CHECKED HERE, AND THAT IS DELIBERATE. It was tempting:
    -- wantedFactor is computed and never compared, so a watcher whose client
    -- last built this arena at a different size keeps the old one. But the
    -- case this guard exists for is an ELIMINATED FIGHTER watching the rest
    -- of their own round -- they are standing on that floor, and a rebuild
    -- takes it away and puts it back under them. On the sky arena that is a
    -- kilometre. A slightly wrong arena size is worth living with; dropping
    -- somebody through the floor is not.
    if builtArena and builtArena.key == arenaKey and #arenaProps > 0 then
        return true
    end

    local arena = Arena.GetArenaByKey(arenaKey)
    local boundary = type(arena) == 'table' and arena.boundary or nil
    if not buildArenaProps(arenaKey, wantedFactor, boundary) then
        clearArenaScenery()
        return false
    end

    if ArenaSpectate and ArenaSpectate.IsActive and not ArenaSpectate.IsActive() then
        clearArenaScenery()
        return false
    end

    spectatorBuilt = true
    return true
end

function ArenaMatch.DropSpectatorScenery()
    if not spectatorBuilt then return end
    spectatorBuilt = false
    clearArenaScenery()
end

RegisterNetEvent('crimson_arena:client:enterArena', function(data)
    if type(data) ~= 'table' or type(data.spawn) ~= 'table' then return end

    captureOwnLoadout()

    matchToken = matchToken + 1
    matchLive = false
    deathReported = false
    currentMatch = {
        id = data.matchId,
        boundary = data.boundary,
        modeKey = data.modeKey,
        teamKey = data.teamKey,
        arenaKey = data.arenaKey,
        sizeFactor = data.sizeFactor,
        loadout = data.loadout,
    }

    ArenaMatch.SetRadar(data.radar == true)

    -- Last round's board must not seed this round's blips.
    roster = {}

    local token = matchToken
    local ped = PlayerPedId()

    -- HANDS AWAY, BEFORE ANYTHING ELSE HAPPENS TO THEM.
    --
    -- IN A PLAYER'S WORDS: "what if someone has a weapon in hand before a
    -- match start and the match starts". They walk in still holding it. The
    -- door moves their ITEMS into a stash on the server, and ox_inventory
    -- reconciles the ped from the inventory a moment later -- but "a moment
    -- later" is inside the start countdown, and what a player sees is
    -- themselves standing in the arena with their own gun out, before the
    -- arena has issued them anything.
    --
    -- HOLSTERED, NOT CONFISCATED, and the difference is the whole of why this
    -- is one line rather than RemoveAllPedWeapons. ox_inventory owns the
    -- weapons in this resource -- the item IS the weapon -- so wiping the ped
    -- would destroy things a player still owns an item for on a server that
    -- runs with the door OFF, which is the exact bug the comment on the exit
    -- path a few hundred lines above exists to remember. Putting their hands
    -- away costs them nothing and takes nothing.
    SetCurrentPedWeapon(ped, UNARMED, true)

    ArenaDispatch.Enter(data.matchId)

    holdFriendlyFire(ped)

    local sx, sy, sz, sheading = scatter(data.spawn,
        tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius)

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
        Wait(150)
    end

    if not buildArenaProps(data.arenaKey, data.sizeFactor, data.boundary) then
        leaveArena(Config.Lobby.returnCoords)
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

    placeAt(ped, sx, sy, sz, sheading, true, function()
        return matchToken == token and currentMatch ~= nil
    end, Arena.UsesExactSpawnZ(data.arenaKey), arenaSurfaceZ or Arena.SpawnFloor(data.arenaKey))

    if matchToken ~= token or not currentMatch then return end

    applyLoadout(ped, data.loadout)

    startArenaThread()

    if data.weatherOverride then SetWeatherTypeNowPersist(data.weatherOverride) end
    if type(data.timeOverride) == 'table' then
        NetworkOverrideClockTime(data.timeOverride.hour or 12, data.timeOverride.minute or 0, 0)
    end

    local freezeSeconds = math.floor(tonumber(data.freezeSeconds) or 0)
    if freezeSeconds <= 0 then
        FreezeEntityPosition(ped, false)
    else
        CreateThread(function()
            local remaining = freezeSeconds
            while remaining > 0 do
                if matchToken ~= token or not currentMatch then return end
                ArenaUI.Countdown(remaining, locale('match.countdown_label'))
                Wait(1000)
                remaining = remaining - 1
            end

            if matchToken == token and currentMatch then
                FreezeEntityPosition(PlayerPedId(), false)
            end
        end)
    end
end)

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
    local x, y, z, heading = scatter(data.spawn,
        tonumber(data.scatterRadius) or Config.Match.spawnScatterRadius)
    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

    local ped = PlayerPedId()

    deathReported = false

    holdFriendlyFire(ped)

    ClearPedBloodDamage(ped)

    local placed = placeAt(ped, x, y, z, heading, true, function()
        return matchToken == token and currentMatch ~= nil
    end, Arena.UsesExactSpawnZ(currentMatch and currentMatch.arenaKey),
        arenaSurfaceZ or Arena.SpawnFloor(currentMatch and currentMatch.arenaKey))

    ArenaDispatch.ReleaseDeadState(ped)

    if not placed or matchToken ~= token or not currentMatch then return end

    applyLoadout(ped, data.loadout)

    holdVitals()
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
    roster = (type(data) == 'table' and type(data.scoreboard) == 'table') and data.scoreboard or {}

    -- THE MOMENT THE ANSWER CHANGES, rather than up to a second after it.
    -- This board is the server saying who is alive and on which side, and
    -- it is the only message that ever says so -- a teammate who has just
    -- respawned is marked again on the frame it arrives.
    --
    -- ABOVE THE showMatchHud RETURN ON PURPOSE. Below it, an operator who
    -- switched the scoreboard panel off would also be switching off the
    -- marker over their teammate's head -- two settings that have nothing
    -- to do with each other, tied together by a line's position, and
    -- nothing about the file would look wrong.
    refreshTeamMarks()

    if not Config.UI.showMatchHud then return end

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

CreateThread(function()
    Wait(2000)

    if type(IsModelInCdimage) ~= 'function' or type(joaat) ~= 'function' then return end

    local checked, missing = {}, {}

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
        print('[crimson_arena] Add those models to a stream/ folder in this resource, or name props your build does have. See STREAMING.md.')
    elseif Config.Debug and #checked > 0 then
        print('[crimson_arena] arena props, checked against this build:')
        for _, line in ipairs(checked) do print('    ' .. line) end
    end
end)

-- ----------------------------------------------------------------------
-- WHAT THIS CLIENT CAN AND CANNOT DRAW, SAID WHERE THE OPERATOR IS SITTING
--
-- THE WARNING BELOW WAS ALREADY WRITTEN AND IT WAS ALREADY INVISIBLE. Six
-- print() calls in a client script reach F8 on the machine that ran them
-- and nowhere else. The operator watches a SERVER console, and what he had
-- there was refreshOutlines' own line saying it had drawn N teammates --
-- true about a frame in which nothing was drawn. So the console that could
-- have ended this said nothing, and the console he reads said success.
--
-- It now goes out on crimson_arena:server:outlineReason, which is the route
-- this file already uses to tell the server why the outline is not drawing,
-- and which server/main.lua prints through ArenaDebug with the reporting
-- client's id in front of it.
--
-- ONE SEND PER CLIENT PER SESSION. Not per frame, not per round: this asks
-- a question about the build, and the answer CANNOT change while the client
-- is running. A line an operator sees once is a line they read.
--
-- ONE LINE PER PLAYER IS THE POINT, not noise. The native is resolved by
-- the client, so two players on the same server can answer differently, and
-- which of them reported it is the first thing worth knowing.
-- ----------------------------------------------------------------------

CreateThread(function()
    Wait(2000)

    local teamMode = false
    for _, mode in ipairs(Arena.GetEnabledModes()) do
        if mode.teams then teamMode = true break end
    end
    if not teamMode then return end

    local canOutline = SetEntityDrawOutlineRenderTechnique ~= nil

    if canOutline and MARKER_NATIVES then
        if Config.Debug then
            print('[crimson_arena] team outline: this build has SET_ENTITY_DRAW_OUTLINE_RENDER_TECHNIQUE, so teammates will be outlined.')
        end
        return
    end

    local reported

    if not canOutline then
        print('[crimson_arena] TEAM OUTLINE CANNOT WORK ON THIS BUILD. Your FiveM artifact does not have')
        print('[crimson_arena]   SET_ENTITY_DRAW_OUTLINE_RENDER_TECHNIQUE (a CFX native from around May 2025).')
        print('[crimson_arena] Without it the outline is drawn in the "unlit" technique group, which ped shaders')
        print('[crimson_arena] do not implement -- so the mask comes out empty and teammates show no colour at all.')
        print('[crimson_arena] Everything else about teams works: sides, spawns, friendly fire, scoring, payouts.')
        print('[crimson_arena] The fix is to update the server artifact. Nothing in config.lua can turn this on.')
        print('[crimson_arena] The marker above each teammate\'s head does NOT need that native and is drawing.')
        print('[crimson_arena]   Config.Teams.showTeamMarker is what switches that one, and it ships on.')

        reported = 'THIS CLIENT CANNOT DRAW THE TEAM OUTLINE -- no SET_ENTITY_DRAW_OUTLINE_RENDER_TECHNIQUE on this build. The overhead teammate marker does not need it and is drawing.'
    end

    if not MARKER_NATIVES then
        print('[crimson_arena] THE TEAMMATE MARKER CANNOT DRAW ON THIS BUILD: one of SET_DRAW_ORIGIN,')
        print('[crimson_arena]   CLEAR_DRAW_ORIGIN, DRAW_RECT or IS_ENTITY_ON_SCREEN is missing. These are')
        print('[crimson_arena]   base game natives, so this is not an old artifact -- something is wrong with')
        print('[crimson_arena]   this client. Teams themselves are unaffected.')

        reported = canOutline
            and 'THIS CLIENT CANNOT DRAW THE OVERHEAD TEAMMATE MARKER -- one of SET_DRAW_ORIGIN, CLEAR_DRAW_ORIGIN, DRAW_RECT, IS_ENTITY_ON_SCREEN is missing. The team outline is unaffected.'
            or 'THIS CLIENT CAN DRAW NEITHER THE TEAM OUTLINE NOR THE OVERHEAD MARKER -- it is missing SET_ENTITY_DRAW_OUTLINE_RENDER_TECHNIQUE and one of the four draw natives. Teammates have the map only.'
    end

    -- STRAIGHT OUT, NOT THROUGH outlineReason. That helper is a per-reason
    -- latch shared with the running match, and this must not be swallowed
    -- as a repeat of whatever the round last reported, nor swallow the
    -- round's next reason itself.
    if reported then
        TriggerServerEvent('crimson_arena:server:outlineReason', reported)
    end
end)
