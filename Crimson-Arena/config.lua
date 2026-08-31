--[[
    crimson_arena/config.lua

    Crimson Roleplay -- Arena.

    THE ONLY FILE AN OPERATOR NEEDS TO EDIT. Everything the arena does is
    driven from this table: which weapons and how much ammo players may
    pick from, whether betting is on, which teams exist and whether they
    are allowed to be lopsided, how many people may join, and where the
    lobby ped stands.

    HOW TO READ THIS FILE
      Config.Lobby ........ the ped (or marker) players walk up to in order
                            to open the arena menu, and where they are put
                            back afterwards.
      Config.Arenas ....... the fighting grounds themselves: spawn points,
                            per-team spawn points, the boundary.
      Config.Modes ........ free-for-all / team deathmatch / gun game etc.
      Config.Teams ........ the team list, whether players pick their own,
                            and whether uneven teams are allowed.
      Config.Loadouts ..... THE WEAPON AND AMMO LIST players choose from.
      Config.Betting ...... the pot: entry fees, payout split, spectator
                            side-bets. One `enabled` flag turns all of it off.
      Config.Match ........ round rules: player counts, lives, timers,
                            win condition.
      Config.UI ........... the red/black theme, and what the panel is called.
      Config.Permissions .. who may create a match, who may force-stop one.
      Config.Database ..... optional persistence for the leaderboard.

    TWO THINGS THAT TRIP PEOPLE UP
      1. `maxPlayers = 0` means UNLIMITED, not "nobody". The same is true of
         `maxTeamSize`, `maxPot` and `maxConcurrentMatches`. Zero is the
         "no ceiling" value everywhere in this file, and it is always
         spelled out in the comment next to it.
      2. Nothing a player's game client claims is trusted. The weapon and
         ammo the client asks for are re-checked against the lists below by
         the server before a single round is handed out, so shortening a
         weapon list here genuinely removes that weapon from the arena --
         it does not merely hide a button.
]]

Config = {}

-- ======================================================================
-- GENERAL
-- ======================================================================

--- Printed in the console and used as the notification title.
Config.ResourceLabel = 'Crimson Arena'

--- Extra console logging for anyone debugging a match that went wrong.
--- Chatty by design: turn it off once the arena is behaving.
Config.Debug = true

--- ox_lib notification title for every message this resource sends.
Config.NotifyTitle = 'CRIMSON ARENA'

-- ======================================================================
-- LOBBY -- the entry point players walk up to.
-- ======================================================================
Config.Lobby = {
    -- HOW PLAYERS OPEN THE ARENA PANEL.
    --   'ped'    -- an NPC stands at `ped.coords`; players use ox_target on
    --              them. This is the default. ox_target is the only target
    --              script wired up -- with it stopped or absent the marker
    --              below goes up in the NPC's place, on the same spot.
    --   'marker' -- a glowing marker on the ground; players stand in it and
    --              press the key in `marker.key`. No NPC is spawned.
    --   'both'   -- spawn the NPC AND draw the marker. Either one opens the
    --              same panel.
    -- Anything else is treated as 'ped' and a warning is printed at start.
    interaction = 'ped',

    ped = {
        model = 'g_m_m_armboss_01',
        -- x, y, z, heading. z should be the GROUND z -- the resource drops
        -- the ped by one unit itself so it does not float.
        -- OUTSIDE the airfield hangar at Sandy Shores, facing the tarmac the
        -- fights happen on. Deliberately not inside a building: an interior
        -- puts the NPC behind a door players have to find, and interiors are
        -- their own can of worms once a match teleports people out of one.
        coords = vector4(1737.20, 3308.40, 41.22, 195.0),
        -- An idle animation so the NPC is not a statue. Set to nil for none.
        scenario = 'WORLD_HUMAN_GUARD_STAND',
        freeze = true,
        invincible = true,
        blockEvents = true,     -- the NPC will not flee, panic or react to gunfire
        -- What the target script shows when a player looks at the NPC.
        targetLabel = 'Enter the Arena',
        targetIcon = 'fas fa-skull',
        targetDistance = 2.5,
    },

    marker = {
        type = 27,
        coords = vector3(1737.20, 3308.40, 40.22),
        size = vector3(1.6, 1.6, 0.6),
        -- Crimson, to match the panel.
        color = { r = 200, g = 16, b = 32, a = 140 },
        bobUpAndDown = false,
        rotate = true,
        drawDistance = 25.0,
        interactDistance = 1.4,
        key = 38,               -- E
        helpText = 'Press ~INPUT_CONTEXT~ to enter the ~r~Arena',
    },

    blip = {
        enabled = true,
        sprite = 313,
        color = 1,              -- red
        scale = 0.8,
        shortRange = true,
        label = 'Crimson Arena',
    },

    -- Where a player is put back when they leave, die out, or the match
    -- ends. Also where they are returned to if the resource restarts while
    -- they are mid-match, so make sure it is somewhere safe to stand.
    returnCoords = vector4(1740.10, 3305.60, 41.22, 195.0),
}

-- ======================================================================
-- ARENAS -- the grounds people actually fight on.
--
-- ADD AS MANY AS YOU LIKE. This is an ordinary list: paste another block in,
-- give it a key nothing else uses, and it appears in the panel at the next
-- restart. Nothing else needs editing -- no code, no second list, no
-- registration step. Delete a block and it is gone; set `enabled = false` and
-- it is hidden without losing the coordinates you spent time collecting.
--
-- THE TWO SHIPPED ARENAS ARE OPEN GROUND ON PURPOSE, and their coordinates
-- are a starting point rather than gospel. Stand where you want a spawn
-- point, take the coordinates with whatever command your server has for it,
-- and paste them in. The heading is the last number -- the direction the
-- player faces when they land.
--
-- COPY THIS TO ADD ONE:
--
--     ['pier'] = {
--         label = 'Del Perro Pier',
--         description = 'Whatever players see under the name in the panel.',
--         enabled = true,
--         spawns = {
--             vector4(x, y, z, heading),
--             vector4(x, y, z, heading),
--         },
--         teamSpawns = {                      -- optional; omit for FFA-only
--             crimson = { vector4(x, y, z, heading) },
--             ash     = { vector4(x, y, z, heading) },
--         },
--         boundary = {
--             enabled = true,
--             center = vector3(x, y, z),
--             radius = 110.0,                 -- metres
--             warningSeconds = 5,
--             damagePerTick = 8,
--             tickMs = 1000,
--         },
--         weatherOverride = nil,              -- e.g. 'THUNDER'
--         timeOverride = nil,                 -- e.g. { hour = 22, minute = 0 }
--     },
--
-- An arena with no spawn points is named in the server console at startup
-- rather than failing quietly when somebody tries to fight in it.
--
-- SPAWNS: you do not need one spawn point per player. They are handed out
-- round-robin and each player is scattered within
-- `Config.Match.spawnScatterRadius` of the point they draw, so twenty players
-- can share four spawn points without stacking inside each other. Two is
-- enough to start; more simply spreads people out.
--
-- TEAM SPAWNS: a team with no list here falls back to the shared `spawns`,
-- so enabling a third team does not force you to edit every arena. Give the
-- sides opposite ends of the ground if you want the match to open cleanly.
-- ======================================================================
Config.Arenas = {
    ['airfield'] = {
        label = 'Sandy Shores Airfield',
        description = 'Open tarmac. Nowhere to hide, long sightlines, rifles win.',
        enabled = true,

        -- Used in free-for-all, and as the fallback for any team with no
        -- entry in `teamSpawns` below. Spread wide across the apron so
        -- nobody lands on top of anybody.
        spawns = {
            vector4(1692.40, 3231.80, 41.09, 30.0),
            vector4(1751.60, 3230.10, 41.09, 330.0),
            vector4(1690.90, 3300.20, 41.15, 150.0),
            vector4(1753.80, 3298.70, 41.15, 210.0),
            vector4(1722.30, 3266.50, 41.12, 90.0),
            vector4(1722.90, 3324.10, 41.16, 180.0),
        },

        -- Team modes. Keys must match `Config.Teams.list`. A team missing
        -- here falls back to `spawns` above.
        teamSpawns = {
            crimson = {
                vector4(1692.40, 3231.80, 41.09, 30.0),
                vector4(1699.10, 3238.60, 41.09, 30.0),
                vector4(1686.20, 3239.40, 41.09, 30.0),
            },
            ash = {
                vector4(1753.80, 3298.70, 41.15, 210.0),
                vector4(1746.90, 3292.10, 41.15, 210.0),
                vector4(1760.20, 3291.40, 41.15, 210.0),
            },
        },

        -- Wide, because the ground is. A boundary tight enough for a
        -- warehouse would have people bleeding out crossing the apron.
        boundary = {
            enabled = true,
            center = vector3(1722.00, 3270.00, 41.12),
            radius = 130.0,
            warningSeconds = 5,
            damagePerTick = 8,
            tickMs = 1000,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },

    ['beach'] = {
        label = 'Vespucci Sands',
        description = 'Flat open sand at the waterline. No cover at all -- pure aim.',
        enabled = true,

        spawns = {
            vector4(-1222.60, -1531.40, 4.35, 35.0),
            vector4(-1288.10, -1483.20, 2.30, 215.0),
            vector4(-1246.90, -1489.70, 3.10, 125.0),
            vector4(-1263.80, -1524.90, 3.20, 305.0),
            vector4(-1210.40, -1494.30, 3.90, 180.0),
            vector4(-1299.20, -1528.60, 2.10, 0.0),
        },

        teamSpawns = {
            crimson = {
                vector4(-1222.60, -1531.40, 4.35, 35.0),
                vector4(-1215.30, -1524.10, 4.30, 35.0),
            },
            ash = {
                vector4(-1288.10, -1483.20, 2.30, 215.0),
                vector4(-1295.40, -1490.60, 2.25, 215.0),
            },
        },

        boundary = {
            enabled = true,
            center = vector3(-1255.00, -1507.00, 3.20),
            radius = 110.0,
            warningSeconds = 5,
            damagePerTick = 8,
            tickMs = 1000,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },
}

-- ======================================================================
-- MODES
--
-- `teams = false` is a free-for-all: everyone against everyone, and the
-- team picker is not shown at all. `teams = true` shows the team picker.
-- ======================================================================
Config.Modes = {
    ['ffa'] = {
        label = 'Free For All',
        description = 'Every player for themselves. Last one breathing takes the pot.',
        enabled = true,
        teams = false,
        icon = 'fas fa-skull-crossbones',
    },

    ['tdm'] = {
        label = 'Team Deathmatch',
        description = 'Pick a side. Wipe the other one out.',
        enabled = true,
        teams = true,
        icon = 'fas fa-users',
    },

    ['gungame'] = {
        label = 'Gun Game',
        description = 'Every kill moves you up the weapon ladder. First to the end wins.',
        enabled = true,         -- the ladder below is what it plays
        teams = false,
        icon = 'fas fa-arrow-up-9-1',
        -- Weapon keys from Config.Loadouts.weapons, in order. When this mode
        -- is on, the player's own weapon choice is ignored -- the ladder
        -- replaces it.
        gunGameLadder = { 'pistol', 'smg', 'shotgun', 'rifle', 'sniper', 'knife' },
    },
}

--- Which mode a newly created match starts on before the host changes it.
Config.DefaultMode = 'ffa'

-- ======================================================================
-- TEAMS
--
-- UNEVEN TEAMS ARE ALLOWED BY DEFAULT -- `allowUnequal = true` below. Nine
-- players against one is a legal match. Set it to false only if you want
-- the server to refuse a start while the sides differ by more than
-- `maxTeamSizeDifference`.
-- ======================================================================
Config.Teams = {
    -- Players pick their own side from the panel. With this off, everyone
    -- is auto-assigned and the team picker is hidden.
    allowChoose = true,

    -- THE UNEVEN-TEAMS SWITCH. true = any split is fine (5v1, 8v2, 11v0
    -- as long as `requireBothTeamsOccupied` allows it).
    allowUnequal = true,

    -- Only consulted when `allowUnequal = false`. The largest difference in
    -- head count the server will start a match with.
    maxTeamSizeDifference = 1,

    -- Even with uneven teams allowed, a team match with everyone on one
    -- side is not a match. Set false only if you genuinely want that.
    requireBothTeamsOccupied = true,

    -- 0 = unlimited players per team.
    maxTeamSize = 0,

    -- Someone who joins a team match without picking a side is dropped onto
    -- the smallest team when the match starts. With this off they are asked
    -- to pick and the start is refused until they do.
    autoAssignIfUnchosen = true,

    -- Can teammates hurt each other?
    friendlyFire = false,

    -- Team blips on the map during a match.
    showTeamBlips = true,
    showEnemyBlips = false,

    list = {
        ['crimson'] = {
            label = 'Crimson',
            -- Panel accent for this team, and the tint used on its blips.
            color = '#c81020',
            blipColor = 1,      -- red
            enabled = true,
            order = 1,
        },
        ['ash'] = {
            label = 'Ash',
            color = '#4a4a52',
            blipColor = 40,     -- grey
            enabled = true,
            order = 2,
        },
        -- A third and fourth side ship disabled. Turn one on and every team
        -- mode immediately offers it -- no code change needed. Give it
        -- spawn points in each arena's `teamSpawns` or it falls back to the
        -- shared `spawns` list.
        ['bone'] = {
            label = 'Bone',
            color = '#d8d2c4',
            blipColor = 0,
            enabled = false,
            order = 3,
        },
        ['ember'] = {
            label = 'Ember',
            color = '#ff6a1a',
            blipColor = 47,
            enabled = false,
            order = 4,
        },
    },
}

-- ======================================================================
-- LOADOUTS -- THE WEAPONS AND AMMO PLAYERS CHOOSE FROM.
--
-- This is the list the weapon picker is built from. Delete an entry, or
-- set `enabled = false`, and that weapon is gone from the arena for
-- everyone -- the server refuses it even if a modified client asks for it
-- by name.
--
-- AMMO: each weapon carries its own `ammo` block. `options` is what the
-- player may pick from in the panel; `max` is the hard ceiling the server
-- clamps to no matter what arrives on the wire, and an off-list request is
-- refused back to `default` rather than rounded.
--
-- A weapon with `ammo.options = nil` has no picker: the panel offers no ammo
-- choice for it, so an honest client sends nothing but `ammo.default` and
-- that is what the player is handed. It is FREE-FORM on the wire, though --
-- with no list to check a request against, the only limit left is `max`, so
-- a modified client asking for a number in between is given it. Set
-- `max = default`, the way the melee entries below do, for a weapon whose
-- count is meant to be fixed.
-- ======================================================================
Config.Loadouts = {
    -- Players choose their own weapons. With this off, everyone is given
    -- `Config.Loadouts.fixed` instead and the picker is hidden.
    -- WHO PICKS, and this is a rule about the match rather than a menu
    -- option -- it decides whether an arena round is a test of skill or a
    -- test of who picked the better gun.
    --
    --   'host'   -- the host picks ONCE and every player in that match
    --               fights with it. Everyone carries the same weapons, so
    --               the only variable left is the players. This is the
    --               default. The picker is read-only for everyone else, and
    --               the server refuses their request as well as the panel
    --               hiding it. Somebody who joins after the host has picked
    --               inherits it rather than starting on the default.
    --
    --   'player' -- everybody picks their own from the lists below.
    --
    -- Anything else is treated as 'host' and a warning is printed at start.
    chooser = 'host',

    allowChoose = true,

    -- How many SHOOTABLE weapons one player may take. Raise it for
    -- loadout-style play, drop it to 1 for a duel server.
    weaponSlots = 2,

    -- How many MELEE weapons, counted separately from the above.
    --
    -- Separate on purpose: with one shared count a player who fancies a knife
    -- has to give up a rifle for it, so nobody ever does and the whole melee
    -- list is decoration. Two firearms and one blade is a loadout; "any three
    -- things" is not.
    --
    -- 0 removes melee from the arena entirely while leaving the weapons in the
    -- list below, ready to switch back on.
    meleeSlots = 1,

    -- Handed to everyone on top of what they picked. Use it for a knife,
    -- a parachute, or nothing at all.
    alwaysGive = {
        { weapon = 'WEAPON_KNIFE', ammo = 1 },
    },

    -- Used only when `allowChoose = false`. Keys from the weapon list below,
    -- and keys only: with choosing switched off there is no request to
    -- resolve, so every weapon here is handed out at its OWN `ammo.default`.
    -- Change the amount in the weapon's entry, not here -- an `ammo` written
    -- next to one of these lines is a number nothing reads.
    fixed = {
        { key = 'rifle' },
        { key = 'pistol' },
    },

    -- Purely for grouping the picker into tabs. A weapon whose `category`
    -- is not listed here still shows, under 'Other'.
    categories = {
        { key = 'sidearm', label = 'Sidearms', order = 1 },
        { key = 'automatic', label = 'Automatics', order = 2 },
        { key = 'heavy', label = 'Heavy', order = 3 },
        { key = 'precision', label = 'Precision', order = 4 },
        { key = 'melee', label = 'Melee', order = 5 },
    },

    -- THE WEAPON LIST.
    --
    -- ADD AND REMOVE FREELY. Paste a block in and it appears in the picker at
    -- the next restart; delete one and it is gone from the arena for everybody,
    -- including anyone whose panel was still showing it -- the server checks
    -- every request against this list before it hands out a single round, so a
    -- weapon that is not here cannot be obtained by asking for it.
    --
    -- `enabled = false` does exactly the same as deleting, while keeping the
    -- entry to switch back on later. There is no difference the player can see.
    --
    -- COPY THIS TO ADD ONE:
    --
    --     {
    --         key = 'microsmg',                 -- unique; the panel and wire use it
    --         weapon = 'WEAPON_MICROSMG',       -- the real GTA name; this is what is given
    --         label = 'Micro SMG',              -- what the player reads
    --         category = 'automatic',           -- a key from `categories` above
    --         enabled = true,
    --         ammo = { default = 120, options = { 60, 120, 250 }, max = 400 },
    --         components = {},
    --         tint = 0,
    --     },
    --
    -- Two keys the same, or an ammo option above that weapon's own max, are
    -- named in the server console at startup rather than failing quietly in
    -- front of a player.
    --
    --   key      -- what the panel and the wire use. Must be unique.
    --   weapon   -- the real GTA weapon name. This is what is actually given.
    --   ammo     -- default/options/max, see the note above this table.
    --   enabled  -- false hides it everywhere without deleting the entry.
    weapons = {
        {
            key = 'pistol',
            weapon = 'WEAPON_PISTOL',
            label = 'Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            components = {},
            tint = 0,
        },
        {
            key = 'combatpistol',
            weapon = 'WEAPON_COMBATPISTOL',
            label = 'Combat Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            components = {},
            tint = 0,
        },
        {
            key = 'revolver',
            weapon = 'WEAPON_REVOLVER',
            label = 'Heavy Revolver',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 24, options = { 12, 24, 48 }, max = 96 },
            components = {},
            tint = 0,
        },
        {
            key = 'smg',
            weapon = 'WEAPON_SMG',
            label = 'SMG',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            components = {},
            tint = 0,
        },
        {
            key = 'rifle',
            weapon = 'WEAPON_ASSAULTRIFLE',
            label = 'Assault Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            components = {},
            tint = 0,
        },
        {
            key = 'carbine',
            weapon = 'WEAPON_CARBINERIFLE',
            label = 'Carbine Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            components = {},
            tint = 0,
        },
        {
            key = 'shotgun',
            weapon = 'WEAPON_PUMPSHOTGUN',
            label = 'Pump Shotgun',
            category = 'heavy',
            enabled = true,
            ammo = { default = 32, options = { 16, 32, 64 }, max = 120 },
            components = {},
            tint = 0,
        },
        {
            key = 'sniper',
            weapon = 'WEAPON_SNIPERRIFLE',
            label = 'Sniper Rifle',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 60 },
            components = {},
            tint = 0,
        },
        {
            key = 'marksman',
            weapon = 'WEAPON_MARKSMANRIFLE',
            label = 'Marksman Rifle',
            category = 'precision',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 120 },
            components = {},
            tint = 0,
        },
        {
            key = 'knife',
            weapon = 'WEAPON_KNIFE',
            label = 'Knife',
            category = 'melee',
            enabled = true,
            -- No `options` -- melee has nothing to pick, so the panel offers
            -- no ammo choice for it. `max` matches `default` so there is no
            -- room above it for a modified client to ask into either.
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'bat',
            weapon = 'WEAPON_BAT',
            label = 'Baseball Bat',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        -- Ships disabled. Turn it on if your arena wants explosives.
        {
            key = 'grenadelauncher',
            weapon = 'WEAPON_GRENADELAUNCHER',
            label = 'Grenade Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 10, options = { 5, 10, 20 }, max = 30 },
            components = {},
            tint = 0,
        },

        -- ==============================================================
        -- MELEE. No ammo choice is offered for any of these -- there is
        -- nothing to choose -- so the panel shows the weapon and nothing
        -- else. Add as many as you like; the pattern is the same as any
        -- other weapon, just with `ammo.options = nil`.
        -- ==============================================================
        {
            key = 'machete',
            weapon = 'WEAPON_MACHETE',
            label = 'Machete',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'knuckles',
            weapon = 'WEAPON_KNUCKLE',
            label = 'Brass Knuckles',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'hatchet',
            weapon = 'WEAPON_HATCHET',
            label = 'Hatchet',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'crowbar',
            weapon = 'WEAPON_CROWBAR',
            label = 'Crowbar',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'golfclub',
            weapon = 'WEAPON_GOLFCLUB',
            label = 'Golf Club',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'switchblade',
            weapon = 'WEAPON_SWITCHBLADE',
            label = 'Switchblade',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'nightstick',
            weapon = 'WEAPON_NIGHTSTICK',
            label = 'Nightstick',
            category = 'melee',
            enabled = false,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },
        {
            key = 'battleaxe',
            weapon = 'WEAPON_BATTLEAXE',
            label = 'Battle Axe',
            category = 'melee',
            enabled = false,
            ammo = { default = 1, options = nil, max = 1 },
            components = {},
            tint = 0,
        },

        -- ==============================================================
        -- MK II WEAPONS -- the ones that can carry an AMMO TYPE.
        --
        -- See the AMMO TYPES note above this table. These four are the
        -- weapons GTA actually ships special magazines for; adding an
        -- `ammoTypes` list to a non-MK II weapon does nothing useful,
        -- because there is no component for it to attach.
        -- ==============================================================
        {
            key = 'pistolmk2',
            weapon = 'WEAPON_PISTOL_MK2',
            label = 'Pistol MK II',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            components = {},
            tint = 0,
            defaultAmmoType = 'standard',
            ammoTypes = {
                { key = 'standard',   label = 'Standard',     component = nil },
                { key = 'fmj',        label = 'FMJ',          component = 'COMPONENT_PISTOL_MK2_CLIP_FMJ' },
                { key = 'hollow',     label = 'Hollow Point', component = 'COMPONENT_PISTOL_MK2_CLIP_HOLLOWPOINT' },
                { key = 'incendiary', label = 'Incendiary',   component = 'COMPONENT_PISTOL_MK2_CLIP_INCENDIARY' },
                { key = 'tracer',     label = 'Tracer',       component = 'COMPONENT_PISTOL_MK2_CLIP_TRACER' },
            },
        },
        {
            key = 'smgmk2',
            weapon = 'WEAPON_SMG_MK2',
            label = 'SMG MK II',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            components = {},
            tint = 0,
            defaultAmmoType = 'standard',
            ammoTypes = {
                { key = 'standard',   label = 'Standard',     component = nil },
                { key = 'fmj',        label = 'FMJ',          component = 'COMPONENT_SMG_MK2_CLIP_FMJ' },
                { key = 'hollow',     label = 'Hollow Point', component = 'COMPONENT_SMG_MK2_CLIP_HOLLOWPOINT' },
                { key = 'incendiary', label = 'Incendiary',   component = 'COMPONENT_SMG_MK2_CLIP_INCENDIARY' },
                { key = 'tracer',     label = 'Tracer',       component = 'COMPONENT_SMG_MK2_CLIP_TRACER' },
            },
        },
        {
            key = 'riflemk2',
            weapon = 'WEAPON_ASSAULTRIFLE_MK2',
            label = 'Assault Rifle MK II',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            components = {},
            tint = 0,
            defaultAmmoType = 'standard',
            ammoTypes = {
                { key = 'standard',   label = 'Standard',        component = nil },
                { key = 'fmj',        label = 'FMJ',             component = 'COMPONENT_ASSAULTRIFLE_MK2_CLIP_FMJ' },
                { key = 'ap',         label = 'Armour Piercing', component = 'COMPONENT_ASSAULTRIFLE_MK2_CLIP_ARMORPIERCING' },
                { key = 'incendiary', label = 'Incendiary',      component = 'COMPONENT_ASSAULTRIFLE_MK2_CLIP_INCENDIARY' },
                { key = 'tracer',     label = 'Tracer',          component = 'COMPONENT_ASSAULTRIFLE_MK2_CLIP_TRACER' },
            },
        },
        {
            key = 'snipermk2',
            weapon = 'WEAPON_HEAVYSNIPER_MK2',
            label = 'Heavy Sniper MK II',
            category = 'precision',
            enabled = false,      -- explosive rounds are a big change; opt in
            ammo = { default = 20, options = { 10, 20, 40 }, max = 60 },
            components = {},
            tint = 0,
            defaultAmmoType = 'standard',
            ammoTypes = {
                { key = 'standard',   label = 'Standard',        component = nil },
                { key = 'fmj',        label = 'FMJ',             component = 'COMPONENT_HEAVYSNIPER_MK2_CLIP_FMJ' },
                { key = 'ap',         label = 'Armour Piercing', component = 'COMPONENT_HEAVYSNIPER_MK2_CLIP_ARMORPIERCING' },
                { key = 'incendiary', label = 'Incendiary',      component = 'COMPONENT_HEAVYSNIPER_MK2_CLIP_INCENDIARY' },
                -- Ships off inside a weapon that ships off. Explosive sniper
                -- rounds in a small arena are a different game.
                { key = 'explosive',  label = 'Explosive',       component = 'COMPONENT_HEAVYSNIPER_MK2_CLIP_EXPLOSIVE', enabled = false },
            },
        },
    },

    -- ==================================================================
    -- THE DOOR -- what a player may bring in, and what leaves with them.
    --
    -- NOBODY BRINGS THEIR OWN KIT INTO THE ARENA. On the way in a player's
    -- whole inventory is put into a private stash and they are given only
    -- what the arena issued. On the way out everything they are carrying is
    -- destroyed -- issued, looted off a body, picked up off the floor -- and
    -- their own inventory is handed straight back.
    --
    -- That makes a round even: two players in an arena have exactly what the
    -- loadout screen gave them and nothing else, and no amount of dying,
    -- looting or hoarding changes what anybody walks out with.
    --
    -- WHERE YOUR STUFF ACTUALLY GOES, because this is the part worth being
    -- sure about: an ox_inventory STASH, one per character, which ox_inventory
    -- persists itself. Not a Lua table in this resource's memory -- a server
    -- that crashed mid-round would take that with it, and losing a player's
    -- inventory is not a bug you get to apologise for.
    --
    -- AND IF ANYTHING GOES WRONG PUTTING IT AWAY, the arena does NOT strip
    -- them. They walk in carrying their own gear, which is a worse match and
    -- a fixable one. It never risks the alternative.
    -- ==================================================================
    inventory = {
        -- Take the player's own inventory at the door and give it back after.
        -- Off means players fight with whatever they walked up carrying, on
        -- top of what the arena issued.
        stripOnEntry = true,

        -- Stash names are this plus the character's citizen id, so one player
        -- can never open another's. Change it only if it collides with
        -- something you already use.
        stashPrefix = 'crimson_arena_',

        -- Refuse to let players drop anything while they are in a match.
        --
        -- Cheaper and far more reliable than hunting down bags off the floor
        -- afterwards: a dropped item becomes its own inventory in the world,
        -- and finding every one of them again is guesswork. Not dropping in
        -- the first place is not.
        blockDropsInArena = true,
    },

    -- ==================================================================
    -- AMMO TYPES -- your ammo script's ITEMS.
    --
    -- SHIPS OFF. Turn it on once you have put your own item names in the list
    -- below, because handing out an item name that does not exist on your
    -- server is a silent nothing, and a player who chose armour-piercing and
    -- got no ammo will report it as the arena being broken.
    --
    -- HOW IT WORKS: the player picks a type in the panel alongside the amount,
    -- and the server gives them that many of the matching item when the round
    -- starts.
    --
    -- GETTING IT BACK IS NOT THIS BLOCK'S JOB, and there is no switch for it
    -- here. The door above already guarantees it: a player's own inventory is
    -- stashed on the way in and everything they are carrying is destroyed on
    -- the way out, so arena ammunition cannot leave the arena any more than
    -- anything else can. There is nothing to reclaim separately, and no way to
    -- turn the reclaim off without turning the door off -- which is
    -- `Config.Loadouts.inventory.stripOnEntry`, and is the honest place for
    -- that decision to live.
    -- ==================================================================
    ammoItems = {
        enabled = false,


        -- How many rounds one item is worth. With ox_inventory's usual
        -- per-round ammo items this is 1 and a player picking 60 rounds is
        -- given 60 items. If one item on your server is a box of 30, put 30
        -- here and they get 2.
        roundsPerItem = 1,

        -- Give the weapon even when its ammo item could not be handed over.
        -- On means a player with a full inventory fights with an empty gun
        -- rather than being refused the round; off means the match refuses to
        -- start them. On is friendlier and is the default.
        allowWeaponWithoutAmmoItem = true,
    },

    -- Which type a player gets when they express no preference.
    defaultAmmoType = 'standard',

    -- How many DIFFERENT ammo types one player may carry across their whole
    -- loadout. 0 is no limit, which means a different round for every weapon.
    --
    -- A player over the limit is not refused the weapon -- losing a gun
    -- because of an ammunition preference is a surprising way to be told
    -- about a limit -- they simply get that weapon's default round instead.
    ammoTypeSlots = 0,

    -- THE TYPES, offered for every weapon that takes ammunition. Melee never
    -- gets them -- a bat has nothing to load.
    --
    -- Override for one weapon by giving that weapon its own `ammoTypes` list
    -- (do this when your item names differ per weapon, e.g. a pistol round and
    -- a rifle round are separate items). Switch them off for one weapon with
    -- `ammoTypes = false`.
    --
    --   key       -- what the panel and the wire use. Must be unique in a list.
    --   label     -- what the player reads.
    --   item      -- YOUR item name. This is the one you must edit.
    --   component -- optional, and only meaningful on MK II weapons: GTA's own
    --                special magazines are weapon components rather than items,
    --                so a type can carry both and get both effects.
    --   enabled   -- false hides it without deleting it.
    defaultAmmoTypes = {
        { key = 'standard',   label = 'Standard',        item = 'ammo-rifle' },
        { key = 'fmj',        label = 'FMJ',             item = 'ammo-rifle-fmj' },
        { key = 'ap',         label = 'Armour Piercing', item = 'ammo-rifle-ap' },
        { key = 'incendiary', label = 'Incendiary',      item = 'ammo-rifle-incendiary' },
        { key = 'hollow',     label = 'Hollow Point',    item = 'ammo-rifle-hollowpoint', enabled = false },
        { key = 'tracer',     label = 'Tracer',          item = 'ammo-rifle-tracer',      enabled = false },
    },

    -- Body armour, picked the same way ammo is.
    -- BODY ARMOUR. Everyone starts every round on a full plate, and cannot
    -- choose otherwise -- `allowChoose = false` hides the picker entirely, so
    -- nobody can hand themselves a disadvantage by accident or hand an
    -- opponent one on purpose.
    --
    -- Turn `allowChoose` back on and the options below become a picker again,
    -- for a server that wants armour to be part of the loadout decision.
    armor = {
        allowChoose = false,
        options = { 0, 50, 100 },
        default = 100,
        max = 100,
    },

    -- Health every player starts a round on. 200 is a stock GTA full bar, and
    -- everyone gets one -- whatever state they walked up to the arena in, a
    -- round starts even. Their real health is captured on the way in and
    -- handed back on the way out.
    health = 200,
}

-- ======================================================================
-- BETTING
--
-- ONE SWITCH TURNS ALL OF IT OFF: `Config.Betting.enabled = false` hides
-- every bet control in the panel and makes the server reject any bet that
-- arrives anyway. Nothing else needs changing.
--
-- HOW THE MONEY MOVES: a player's entry fee leaves their account the moment
-- they lock in, and is held by the match. It is paid out to the winner(s)
-- when the match ends, or refunded in full if the match fails to start, is
-- closed by the server, or ends with nobody eligible to be paid.
--
-- The two exceptions are both settings, both default to refunding, and both
-- are spelled out where they live below: `refundOnCancel` (a host closing
-- their own lobby) and `refundOnDisconnectBeforeStart` (leaving one). Turn
-- either off and that stake stops coming back.
-- ======================================================================
Config.Betting = {
    enabled = true,

    -- 'cash' or 'bank'.
    account = 'cash',
    currencySymbol = '$',

    -- THE ENTRY FEE each player stakes to take part.
    entryFee = {
        -- With this off, matches are free to enter and the pot is only ever
        -- filled by spectator side-bets (if those are on).
        enabled = true,
        min = 0,
        max = 50000,
        default = 1000,
        -- Quick-pick buttons in the panel. Any value between min and max is
        -- still accepted if the player types it.
        presets = { 500, 1000, 5000, 25000 },
    },

    -- Taken off the top of the pot before it is paid out. 0 = no cut.
    houseCutPercent = 0,

    -- HOW THE POT IS SPLIT.
    --   'winner_takes_all' -- one player (or the winning team, split evenly)
    --   'top_three'        -- split by `topThreeSplit` below, FFA only
    --   'per_kill'         -- divided by share of total kills
    payout = 'winner_takes_all',
    topThreeSplit = { 60, 30, 10 },

    -- Below this head count the match still runs, but the pot is refunded
    -- rather than paid out -- stops two friends farming each other.
    minPlayersToPayOut = 2,

    -- 0 = no ceiling on the total pot.
    maxPot = 0,

    -- A HOST CLOSING THEIR OWN LOBBY. With this on -- the default -- every
    -- stake goes straight back. With it off they are FORFEITED, and the
    -- money goes nowhere at all: it is kept the way the house cut and a
    -- losing side-bet are kept, because this resource has no house account
    -- to credit and handing the pot to somebody would only move the abuse to
    -- whoever received it. That is the point of the setting -- it deters a
    -- host who fills a lobby, takes everyone's stake and closes it. Every
    -- forfeit is logged and webhooked whatever `logPayouts` says, because an
    -- operator running a house account by hand is the only person who can
    -- put that money anywhere.
    --
    -- ONLY a host cancelling forfeits. An idle-timeout close, an admin
    -- force-stop, the last player walking out and a resource restart all
    -- still refund in full: punishing a host who calls their own match off
    -- is not the same as punishing a lobby the server itself closed.
    refundOnCancel = true,

    -- LEAVING A LOBBY THAT HAS NOT STARTED. On, the stake comes back. Off,
    -- it stays in the pot and is won by whoever takes the match.
    --
    -- Like its mid-match sibling below, this does NOT distinguish a
    -- deliberate quit from a crash, and deliberately so: a rule that charged
    -- only genuine disconnects would take money from players whose game
    -- crashed and hand it back to the ones who left on purpose, which is
    -- worse than either answer applied evenly.
    refundOnDisconnectBeforeStart = true,

    -- Someone who disconnects mid-match forfeits their stake to the pot.
    -- With this on they get it back instead.
    refundOnDisconnectDuringMatch = false,

    -- SPECTATOR SIDE-BETS: people who are not fighting can back a team (in
    -- team modes) or a specific player (in free-for-all).
    spectatorBets = {
        enabled = true,
        min = 100,
        max = 25000,
        -- Bets close this many seconds after the match starts. 0 closes
        -- them the moment the round begins.
        closeAfterStartSeconds = 30,
        -- Winning side-bets pay stake x this. Losing ones are lost.
        oddsMultiplier = 2.0,
        -- One bet per spectator per match.
        oneBetPerMatch = true,
    },
}

-- ======================================================================
-- MATCH RULES
-- ======================================================================
Config.Match = {
    -- Fewest players a match will start with.
    minPlayers = 2,

    -- 0 = UNLIMITED. Any number of players may join one match.
    maxPlayers = 0,

    -- 0 = unlimited matches running side by side.
    maxConcurrentMatches = 0,

    -- Only the player who created the match may start it. With this off,
    -- anyone in the lobby can.
    onlyHostCanStart = true,

    -- Start on its own once everybody has readied up and `minPlayers` is
    -- met, without waiting for the host to press start.
    autoStartWhenAllReady = true,

    -- The countdown shown in the lobby once a start is triggered. Players
    -- may still back out during it.
    lobbyCountdownSeconds = 10,

    -- The frozen countdown after everyone is teleported in, before weapons
    -- go live.
    startCountdownSeconds = 5,

    -- 0 = no time limit. When the clock runs out the win condition is
    -- decided on kills.
    roundTimeSeconds = 600,

    -- LIVES PER PLAYER. 1 = eliminated on the first death. Above that, a
    -- player who dies is put back at a fresh spawn point with a full
    -- loadout, and is only out once their last life is spent.
    --
    -- Three changes how a round feels more than any other number here: a
    -- single unlucky opening exchange no longer ends somebody's match, and
    -- the round lasts long enough for position and ammunition to matter.
    -- Watch roundTimeSeconds alongside it -- three lives each across a full
    -- lobby is a much longer fight than one.
    -- Set a plain number here instead -- `lives = 3` -- to fix it for every
    -- match and take the choice away.
    lives = {
        allowChoose = true,
        min = 1,
        max = 10,
        default = 3,
    },

    -- How long a player lies there before being put back in. Long enough to
    -- feel like a death, short enough not to be a punishment on its own.
    respawnDelaySeconds = 5,

    -- HOW A MATCH IS WON.
    --   'last_standing' -- everyone else eliminated
    --   'most_kills'    -- highest kill count when the clock runs out
    --   'score_limit'   -- first to `scoreLimit` kills
    winCondition = 'last_standing',
    scoreLimit = 25,

    -- Metres a player may be scattered from the spawn point they drew, so
    -- more players than spawn points never stack inside each other.
    spawnScatterRadius = 2.5,

    -- HOW FAR ABOVE THE SPAWN POINT A PLAYER IS PUT DOWN, in metres.
    --
    -- The player is held motionless this far above the spawn point while the
    -- world streams in, and is then put down on whatever surface the game
    -- reports underneath -- so they never fall, and never stand where there
    -- is nothing yet.
    --
    -- KEEP IT SMALL. Being frozen is what stops the fall through an unloaded
    -- world; height has nothing to do with it. A big number would hang every
    -- player in the air where the whole arena can see them, which broadcasts
    -- exactly where the spawn points are.
    --
    -- Finding the real ground is a separate job and is handled by searching
    -- down from well overhead -- a maths query nobody is ever at, and the
    -- part that actually fixes a spawn Z written below the surface. That
    -- height is not configurable because it is not a gameplay decision.
    spawnHeightOffset = 1.0,

    -- Eliminated players watch the rest of the match instead of being sent
    -- straight back to the lobby.
    spectateOnElimination = true,

    -- Give players back the weapons and armour they walked in with when
    -- they leave. Strongly recommended on.
    restoreLoadoutOnExit = true,

    -- Wipe a player's carried weapons on entry so only arena weapons are
    -- in play. Turning this off lets people bring their own guns in.
    stripWeaponsOnEntry = true,

    -- A match sitting in the lobby with nobody readying up is closed after
    -- this long, and any stakes refunded. 0 = never.
    idleLobbyTimeoutSeconds = 900,

    -- Refuse to let a player join while they are dead, cuffed or in a
    -- vehicle. Server-checked.
    blockWhileDead = true,
    blockWhileInVehicle = true,
}

-- ======================================================================
-- UI -- the red/black panel.
-- ======================================================================
Config.UI = {
    title = 'CRIMSON',
    subtitle = 'ROLEPLAY ARENA',

    -- HOW THE LOGO IS USED. Two shapes of logo exist and they want opposite
    -- treatment, so this picks which one you have:
    --
    --   'mark'   -- a small square badge sitting to the LEFT of the title
    --               above. Right for a simple icon: a skull, a monogram, a
    --               shield. It is drawn small, so anything with words in it
    --               is unreadable.
    --
    --   'banner' -- the logo spans the top of the panel and `title` and
    --               `subtitle` are NOT drawn. Right for a finished lockup
    --               that already contains your server name, because in
    --               'mark' mode that name is printed twice: once as text,
    --               once as pixels too small to read.
    --
    -- A full-scene artwork -- skyline, vehicles, effects -- will still be
    -- small at panel size whichever you choose. It reads far better cropped
    -- down to the part that identifies you: the badge alone for 'mark', the
    -- wordmark strip for 'banner'.
    --
    -- Anything else is treated as 'mark' and a warning is printed at start.
    logoStyle = 'mark',

    -- Drop your own logo in html/images/logo.png and it appears in the
    -- panel header. If you change the FILENAME you must also add the new
    -- file to fxmanifest.lua's `files` block, or it silently will not load.
    logo = 'images/logo.png',

    theme = {
        accent = '#c81020',         -- the crimson everything is keyed off
        accentBright = '#ff2038',
        accentDim = '#7a0a14',
        background = '#0a0a0c',
        surface = '#121216',
        surfaceRaised = '#1a1a20',
        border = '#2a2a32',
        text = '#f2f2f4',
        textMuted = '#8e8e98',
        danger = '#ff3b3b',
        success = '#37d67a',
    },

    -- Command that opens the panel from anywhere, for testing or for
    -- servers that would rather not use a ped at all. Set to nil to
    -- register no command.
    command = nil,

    -- Sound the panel plays on open/close/ready. false = silent panel.
    sounds = true,

    -- Show the live scoreboard overlay during a match.
    showMatchHud = true,
}

-- ======================================================================
-- PERMISSIONS
--
-- Empty job/group lists mean "everyone" -- that is the default, because an
-- arena is usually open to the whole server.
-- ======================================================================
Config.Permissions = {
    -- Jobs allowed to CREATE a match. Empty = anyone may.
    createJobs = {},
    -- ACE/ox_lib admin groups allowed to force-stop or wipe a match.
    adminGroups = { 'admin', 'god' },
    -- Anyone may join a match someone else created.
    joinJobs = {},
}

-- ======================================================================
-- DATABASE -- the leaderboard only. OFF, so this resource is drag and drop.
--
-- SHIPPED OFF ON PURPOSE. With it off there is no SQL to import, no table to
-- create, no database user to grant anything to, and nothing to go wrong on
-- first start. Drop the folder in, ensure it, play. That is the whole install.
--
-- WHAT YOU LOSE, and it is only this one thing: the leaderboard resets when
-- the server restarts. Wins, kills and earnings are still counted and still
-- shown during a session -- they simply are not written down anywhere, so a
-- restart starts the table fresh.
--
-- WHAT YOU DO NOT LOSE: matches, teams, weapon and ammo choice, the whole
-- betting system including escrow, payouts and refunds, the panel, dispatch
-- suppression. None of it touches the database. Every money guarantee this
-- resource makes holds exactly the same with this off.
--
-- TURNING IT ON LATER is one word here and a restart. The table creates
-- itself on first start; sql/install.sql is there only for servers whose
-- database user is not allowed to create tables at runtime.
--
-- OFF MEANS OFF, INCLUDING THE DEPENDENCY. oxmysql is not named in
-- fxmanifest.lua and the MySQL library is not included there either, so with
-- this switched off the resource starts on a server that has no database
-- resource at all. Switch it on without oxmysql running and the console says
-- so once, the leaderboard falls back to this server run, and nothing else
-- changes.
-- ======================================================================
Config.Database = {
    enabled = false,
    -- Flush queued stat writes this often, in ms. Also flushed on stop.
    flushIntervalMs = 60000,
    leaderboardSize = 25,
}

-- ======================================================================
-- WEBHOOK -- optional Discord log of every finished match.
-- ======================================================================
Config.Webhook = {
    enabled = false,
    url = '',
    username = 'Crimson Arena',
    color = 13115424,   -- crimson
    -- Log match results, and separately, every payout.
    logResults = true,
    logPayouts = true,
}

-- ======================================================================
-- DISPATCH SUPPRESSION
--
-- An arena is a place where people shoot each other on purpose. Left alone,
-- every round calls the police for shots fired and every death calls EMS for
-- a person down, and your emergency services spend the evening driving to a
-- fight nobody wants them at.
--
-- THIS BLOCK IS BUILT FOR A CUSTOM DISPATCH SCRIPT, not for GTA's own
-- five-star wanted system. Almost every serious RP server has the vanilla
-- system switched off entirely and runs its own alerts, so that is the case
-- treated as normal here: `Config.Dispatch.custom` below is the real
-- integration, and the vanilla block further down ships DISABLED for servers
-- that still use it.
--
-- THE ONE THING NO RESOURCE CAN DO. Your dispatch script decides to send an
-- alert inside its own event handlers. Nothing in FiveM can reach into
-- another resource and cancel that -- not this script, not any script that
-- claims otherwise. So the job here is to hand your dispatch script the
-- facts it needs to decline, in whichever of the three forms suits how it is
-- written. All three are live at once; use whichever is least work.
--
-- WHICH IS WHY THE STRONGEST SETTING IN THIS BLOCK IS `isolation` BELOW, and
-- why it is first. It does not ask anybody to decline anything: it puts the
-- match in its own network instance, where every OTHER player's client --
-- and therefore every dispatch and ambulance script running on one -- has
-- nothing to see in the first place. Read that block before any of the rest.
-- ======================================================================
Config.Dispatch = {
    -- THE ONE SWITCH AT THIS LEVEL. It only ever applies to players who are
    -- IN a match -- it does not follow anyone back out. What it governs is
    -- `clearDeadStateImmediately` at the bottom of this block: the arena
    -- standing its own casualties straight back up, so a medical script's
    -- polling loop never catches one. That is something this resource does
    -- to its own players in its own file, which is why one switch can
    -- honestly turn it off.
    suppressAmbulanceDown = true,

    -- THERE IS NO `suppressPoliceShotsFired` KEY HERE, and saying why is
    -- worth more than the key was. It sat on this line reading like the
    -- headline police setting, and the only code that ever looked at it was
    -- inside `vanillaPolice` below -- which ships OFF -- so on a shipped
    -- config it did nothing in either position. It was the first thing to
    -- reach for when the police still turned up at a round, and the one
    -- thing that could not have been the cause.
    --
    -- There is no single police switch because the police are not a single
    -- thing here. GTA's own NPC cops are `vanillaPolice` below, behind that
    -- block's own `enabled`. A custom dispatch script is `custom` below, and
    -- each of its four forms is already governed by whether you filled that
    -- form's own list in -- an empty list does nothing whatever a switch
    -- says, which is the same reason `custom` has no master switch either.
    -- `cancelEvents` explains in its own comment why it is deliberately not
    -- tied to a police-or-medical switch at all: an event name does not say
    -- which of the two it is.

    -- ==================================================================
    -- ROUTING BUCKET ISOLATION -- the layer that needs nothing from anybody
    --
    -- A routing bucket is a separate network instance. Entities and events
    -- inside one do not replicate to players outside it. Put a match in its
    -- own bucket and no other player's client can see arena gunfire, arena
    -- bodies or arena entities AT ALL -- so a dispatch or ambulance script
    -- running on one of those clients has nothing to detect and nothing to
    -- report, with no cooperation from it and no line pasted into it.
    --
    -- It is worth having even on a server with no dispatch script: it stops
    -- passers-by wandering into a live round, and stops arena gunfire being
    -- heard across the map.
    --
    -- THE HONEST LIMIT, and it is the same one everything else in this block
    -- is here for: a bucket cannot hide an arena player's gunfire from THEIR
    -- OWN client. A dispatch script polling IsPedShooting on the shooter's
    -- machine still sees the shooter shooting. Nothing inside another
    -- resource can stop that loop. The state bag, the events and the exports
    -- further down are what is left for that case, and they still matter.
    -- ==================================================================
    isolation = {
        -- Off means every match is fought in the ordinary world, in front of
        -- everybody, exactly as it was before this setting existed.
        enabled = true,

        -- ONE BUCKET PER MATCH, so two matches running at once cannot see
        -- each other either. With this off every match shares `firstBucket`:
        -- still hidden from the rest of the server, but two simultaneous
        -- arenas would be standing in one room hearing each other.
        perMatch = true,

        -- The number allocated from, counting upwards. Bucket numbers are
        -- server-wide and shared with every other resource on the box, so
        -- this is deliberately high and unlikely to collide -- change it if
        -- something you run already lives in this range. Bucket 0 is the
        -- default world and is never allocated.
        firstBucket = 4210,

        -- Ambient NPCs and traffic inside an arena bucket. Off, so a round
        -- is fought in an empty world: an NPC that does not exist cannot
        -- witness a firefight, panic in front of one, or be run over into
        -- somebody's incident report.
        populationEnabled = false,

        -- HOW STRICT THE BUCKET IS ABOUT ENTITIES CLIENTS CREATE.
        --   'relaxed'  -- clients may create entities. THE DEFAULT.
        --   'inactive' -- entities are not culled, and clients may create
        --                 them; the loosest of the three.
        --   'strict'   -- clients may not create entities at all.
        --
        -- 'strict' isolates hardest and is NOT the default on purpose:
        -- weapons and props handed out during a match are created BY the
        -- receiving client, and a strict bucket refuses them -- the player
        -- arrives in the arena empty-handed with nothing on screen saying
        -- why. Only set this to 'strict' if you have tested that loadouts
        -- still arrive on your build.
        lockdownMode = 'relaxed',
    },

    -- ==================================================================
    -- YOUR DISPATCH SCRIPT
    --
    -- Three ways to hand it the same fact so it can decline the alert
    -- itself, and then a fourth that tries to decline on its behalf and
    -- works only sometimes -- read FORM 4's own comment before using it.
    -- Pick one; the others cost nothing.
    -- ==================================================================
    custom = {
        -- ---- FORM 1: this resource tells you -----------------------------
        -- Server events fired when a player is put into an arena and when
        -- they leave it, so your script can keep its own ignore list without
        -- polling anything.
        --
        --     AddEventHandler('crimson_arena:dispatch:enter', function(src, matchId)
        --         MyDispatch.Ignore[src] = true
        --     end)
        --     AddEventHandler('crimson_arena:dispatch:exit', function(src, matchId)
        --         MyDispatch.Ignore[src] = nil
        --     end)
        --
        -- Both are SERVER events -- they are not sent to any client, because
        -- "who is allowed to be ignored" is not a decision a client gets to
        -- take part in. Set either to nil to fire nothing.
        enterEvent = 'crimson_arena:dispatch:enter',
        exitEvent = 'crimson_arena:dispatch:exit',

        -- Your dispatch script restarting mid-round would otherwise lose its
        -- ignore list and start alerting on a fight already in progress.
        -- Name it here and this resource re-fires `enterEvent` for everyone
        -- currently in an arena as soon as it comes back up.
        -- Add every resource that keeps its own copy of that list.
        resyncResources = {},

        -- ---- FORM 2: you read a flag -------------------------------------
        -- A replicated state bag, readable from either realm with no call
        -- and no event:
        --
        --     if Player(src).state.crimsonArena then return end        -- server
        --     if LocalPlayer.state.crimsonArena then return end        -- client
        --
        -- The value is a table -- { active = true, matchId = '...' } -- so it
        -- is truthy in a match and nil otherwise. Rename the key if it
        -- collides with something you already use.
        --
        -- IT IS WRITTEN BY THE SERVER, NEVER THE CLIENT, and that is a
        -- security decision rather than a tidy one: a replicated bag set from
        -- a client can be set by ANY client, so a player who has never been
        -- near the arena could pin the flag on themselves and have your
        -- dispatch script politely ignore them robbing a bank.
        stateBagKey = 'crimsonArena',

        -- ---- FORM 3: this resource calls you -----------------------------
        -- If your script already has its own "ignore this player" or
        -- "disable" export, name it and it will be called with `true` when a
        -- player enters and `false` when they leave.
        --
        --     disableExports = {
        --         { resource = 'my_dispatch', export = 'SetIgnoredPlayer' },
        --     },
        --
        -- Nothing ships enabled, because calling an export that means
        -- something different on your build is worse than not calling it. An
        -- entry naming a resource that is not running, or an export that does
        -- not exist, is skipped with one console warning -- it will not error
        -- and it will not stop a match starting.
        -- NO `enabled` SWITCH HERE, deliberately. There used to be one and
        -- nothing read it -- every path in this block is driven by whether
        -- its own list has anything in it, which is the honest signal: an
        -- empty list does nothing whether a switch says on or off. A key
        -- that looks like a master switch and controls nothing is worse
        -- than no key, because it is the first thing an operator toggles
        -- when something does not work.
        disableExports = {},

        -- ---- FORM 4: this resource cancels the alert event ----------------
        -- BEST EFFORT. THE WEAKEST THING IN THIS ENTIRE BLOCK. Read the whole
        -- comment before you count on it, because a suppression you believe
        -- is working and is not is worse than one you know you still have to
        -- wire up.
        --
        -- Name the events your dispatch or ambulance script raises in order to
        -- send an alert. This resource registers a handler on each one and
        -- calls CancelEvent() on it -- but only when it can establish that the
        -- alert is about a player who is in a match right now.
        --
        --     cancelEvents = {
        --         -- An event a CLIENT triggers. `source` is the player who
        --         -- triggered it, and that is all this needs.
        --         'dispatch:server:shotsFired',
        --
        --         -- An event another RESOURCE triggers on the server. There
        --         -- is no player behind it, so say which argument carries the
        --         -- server id of the player the alert is ABOUT. Count from 1.
        --         { event = 'dispatch:server:personDown', playerArg = 1 },
        --     },
        --
        -- WHY IT IS ONLY BEST EFFORT, and there is no way to make it more.
        -- CancelEvent() raises a flag. It stops nothing by itself. The alert
        -- still goes out unless the code that raised the event checks
        -- WasEventCanceled() afterwards and decides to drop it -- AND MANY
        -- SCRIPTS NEVER CHECK. Worse, a script that does check inside its own
        -- handler only sees the flag if this resource registered first, which
        -- comes down to the order resources start in your server.cfg and is
        -- not something any resource can guarantee about another.
        --
        -- So: treat a cancelled alert as a bonus, never as the thing keeping
        -- your dispatch quiet. If this is the only form on this list you have
        -- filled in, assume the alerts are still being sent. `stateBagKey`
        -- above is one line pasted into the sending script and it always
        -- works; this exists for the case where you cannot edit that script
        -- at all.
        --
        -- WHAT IT WILL NOT DO IS GUESS. An event that arrives with no usable
        -- `source` and no `playerArg` is left alone, and its name is printed
        -- once so you know to add one. Cancelling a shots-fired call about
        -- somebody on the other side of the map is a far worse outcome than
        -- failing to cancel one about a fighter, so anything doubtful is
        -- passed straight through.
        --
        -- Not tied to the two suppress switches at the top of this block: an
        -- event name does not say whether it is a police alert or a medical
        -- one. Empty this list to switch it off.
        cancelEvents = {
            -- ---- sc-dispatch / sc-ambulance, READ OFF THEIR OWN SOURCE ----
            -- These four are the events those two resources ACTUALLY raise on
            -- this box. The two names that used to sit here --
            -- 'sc-dispatch:server:AddNotification' and
            -- 'sc-dispatch:AddNotification' -- exist in neither resource and
            -- never fired once, so this whole layer was listening to silence.
            -- AddNotification is an EXPORT, not an event:
            -- `exports['sc-dispatch']:AddNotification(data)`. Nothing can
            -- register a handler on an export call, which is why `retract`
            -- below exists, and why these are the events one step UPSTREAM of
            -- it -- the ones a client actually triggers.

            -- Gunfire. sc-dispatch's client polls IsPedShooting on the
            -- SHOOTER's own machine and sends this, so FXServer stamps
            -- `source` with the fighter and the arena can pin it exactly.
            'sc-dispatch:server:ShotsFired',

            -- "10-52 Person Down". Raised by sc-ambulance when a downed
            -- player asks for EMS, and again `source` is that player.
            'hospital:server:EMSDownAlert',

            -- The default QBCore ambulance alert. sc-ambulance only raises
            -- this while its own Config.MDTIntegration.DisableDefaultAlerts
            -- is off, so on this box it is usually quiet -- listed because it
            -- costs nothing and turning that key back on must not silently
            -- reopen the hole.
            'hospital:server:ambulanceAlert',

            -- sc-dispatch's second EMS entry point.
            'mydispatch:requestEMS',
        },

        -- ---- FORM 5: this resource WITHDRAWS the alert -------------------
        -- WHAT TO USE WHEN FORM 4 CANNOT WORK, AND FOR sc-dispatch IT CANNOT.
        --
        -- CancelEvent() raises a flag and stops nothing: by Cfx's own
        -- documentation it does not prevent another resource's handler from
        -- running, and sc-dispatch never calls WasEventCanceled(). So every
        -- name in the list above WILL still create its call. Form 4 is kept
        -- because it is free, and because its console lines are how you tell
        -- a hook that never fires from one that fires and declines -- but on
        -- this server it is diagnostics, not suppression.
        --
        -- This form is the one that actually removes the call. Most dispatch
        -- scripts, sc-dispatch included, expose a "clear this call" export
        -- and build the call's id out of facts this resource can see. Name
        -- the export and the id shape and an arena alert is withdrawn the
        -- moment it is created: the map blip goes, the MDT row is marked
        -- inactive, and the call stops being dispatchable.
        --
        -- THE HONEST LIMIT, and it is why this is not called a fix. The alert
        -- is created before it is withdrawn. An officer on duty in that
        -- moment still hears the notification sound and may see the entry
        -- blink in and out. What this stops is the call PERSISTING -- units
        -- driving to an arena, a blip sitting on the map for the length of
        -- AutoClearTime, a round's worth of 10-71s stacking up in the MDT.
        -- Stopping the sound too takes one line inside the sending resource,
        -- which is what `stateBagKey` above is for.
        --
        -- Set `resource` to nil to switch the whole form off.
        retract = {
            -- The resource holding the "clear a call" export, and the export
            -- itself. Skipped with one console line if it is not running.
            resource = 'sc-dispatch',
            export = 'ClearNotification',

            -- How long to wait before withdrawing, in milliseconds.
            --
            -- NOT ZERO, AND THIS IS THE ONE NUMBER WORTH UNDERSTANDING. Both
            -- handlers -- sc-dispatch's and this one -- hang off the same
            -- event, and nothing decides which runs first. Withdrawing a call
            -- that has not been created yet clears nothing at all, so this
            -- waits long enough for the other handler to have finished its
            -- database insert. Raise it if calls still linger; every
            -- millisecond here is time the alert is live on an officer's
            -- screen, so do not raise it further than you have to.
            delayMs = 250,

            -- Seconds either side of the current clock to also withdraw.
            --
            -- sc-dispatch files a call under '<kind>_<serverId>_<os.time()>'.
            -- This resource rebuilds that string from the same two facts,
            -- which agrees unless the two handlers straddle a one-second
            -- boundary. Clearing one second either way closes that gap, and
            -- it cannot reach anybody else's call: the server id in the
            -- middle is the arena player's own.
            clockSlack = 1,

            -- The id shape each event's call is filed under, keyed by the
            -- event that leads to it. The first '%d' is the player's server
            -- id and the second is the unix timestamp -- the order both
            -- sc-dispatch and sc-ambulance build them in.
            --
            -- An event with no entry here is cancelled (Form 4) and not
            -- withdrawn, which is the safe direction: an id shape that is
            -- close but wrong clears nothing rather than clearing the wrong
            -- call.
            idTemplates = {
                ['sc-dispatch:server:ShotsFired'] = 'shots_%d_%d',
                ['hospital:server:EMSDownAlert'] = 'emsdown_%d_%d',
            },
        },
    },

    -- There are exports too, for a script that would rather ask than listen:
    --     exports.crimson_arena:IsPlayerInArena(src)     -- server
    --     exports.crimson_arena:GetPlayerMatchId(src)    -- server
    --     exports.crimson_arena:GetArenaPlayers()        -- server
    --     exports.crimson_arena:IsInArena()              -- client
    -- Those exist whether or not anything here is switched on. They report;
    -- they do not enforce.

    -- ==================================================================
    -- GTA'S OWN FIVE-STAR WANTED SYSTEM
    --
    -- OFF, deliberately. If you run a custom dispatch script you have almost
    -- certainly disabled the vanilla wanted system server-wide already, and
    -- touching these natives on top of that ranges from pointless to
    -- actively harmful -- plenty of custom systems drive their own logic off
    -- the native wanted level, and pinning it to zero mid-match would fight
    -- them for it.
    --
    -- Turn this on ONLY if NPC police still respond to gunfire on your
    -- server. Everything it changes is restored on the way out, wanted stars
    -- included: walking into an arena is not an amnesty.
    -- ==================================================================
    -- ---- TELLING YOUR AMBULANCE SCRIPT THEY ARE ALIVE ----------------
    -- SEPARATE FROM EVERYTHING ELSE IN THIS BLOCK, and the one setting
    -- most likely to be the reason a player "is still dead" after a match.
    --
    -- The arena stands its own players back up itself, and for the
    -- character model that is the whole job. It is not the whole job for
    -- your server: an ambulance or medical script keeps its OWN record of
    -- who is dead -- player metadata, a table, a state bag -- and nothing
    -- about standing a body up tells it anything. So a player who died in
    -- a match walks back to the lobby on their feet while that script
    -- still has them down, and they stay stuck until somebody revives
    -- them properly.
    --
    -- Name whatever your script uses to revive somebody and it is called
    -- for that player EVERY TIME THE ARENA STANDS THEM BACK UP: on each
    -- mid-match respawn, and again on the way out.
    --
    -- Both, because a death inside the arena is a death as far as your
    -- medical script is concerned. From that moment it has them down, and
    -- the arena putting them back on their feet does not reach it -- so a
    -- player who is only revived at the end fights the rest of the round as
    -- a casualty, with whatever that script does to a dead player still
    -- being done to them.
    --
    -- NOTHING IS GUESSED AND NOTHING SHIPS ON. There is no default here
    -- for the same reason the catalogue below only detects: an event name
    -- that is close but not right looks wired up and does nothing.
    revive = {
        -- NOTHING HERE HAS TO BE SET FOR PLAYERS TO GET BACK UP.
        --
        -- The arena revives its own players itself, in code, with no command
        -- and no permission -- it knocked them down, so standing them back up
        -- is not a privileged act and it does not ask anybody. That happens
        -- whatever this block says, including with `enabled = false`.
        --
        -- What is left below is for telling ANOTHER script -- a medical or
        -- ambulance resource -- that the player is no longer a casualty. That
        -- part is optional, and it is the only part these settings control.
        enabled = true,

        -- COMMANDS run from the SERVER CONSOLE. `%s` is where the player's
        -- server id goes; a line with no `%s` gets the id appended, so
        -- 'revive' and 'revive %s' both work.
        --
        -- EMPTY ON PURPOSE. An admin revive command checks whether its caller
        -- is allowed, and a resource is not an admin -- so on most servers
        -- this is refused, which prints an "Access denied" line for every
        -- single death while the built-in revive quietly does the real work.
        -- Since nothing needs the command any more, the noise is not worth
        -- shipping on. Add your medical script's own command here if you want
        -- it run as well:
        --     commands = { 'revive %s' },
        commands = {},

        -- THE SAME COMMANDS, RUN ON THE PLAYER'S OWN CLIENT.
        --
        -- Use these when the server console line above appears but nothing
        -- happens. A command registered CLIENT-side does not exist as far as
        -- the server console is concerned: `commands` finds nothing, does
        -- nothing, and reports nothing wrong -- the quietest failure there
        -- is, and the reason both forms exist.
        --
        -- Same `%s` rule. Many client-side revives revive whoever ran them
        -- and take no id at all, so 'revive' on its own is the common case
        -- here -- and unlike the server list, a template with no placeholder
        -- is sent AS IS rather than having the id appended.
        --     clientCommands = { 'revive' },
        clientCommands = {},

        -- GIVE THIS RESOURCE PERMISSION TO RUN THOSE COMMANDS. On by
        -- default, and the reason the revive appeared to do nothing.
        --
        -- A command run from a resource is run BY that resource, and an admin
        -- command checks whether its caller is allowed. This resource is not
        -- an admin, so `revive` was refused -- silently, because a refused
        -- command is not an error, it is a command that did nothing. The
        -- console could honestly report running it while the player stayed on
        -- the floor.
        --
        -- What is granted is exactly the commands named above and nothing
        -- else: `command.revive` lets this resource revive, and lets it do
        -- nothing more. NOT admin. Adding the arena to an admin group would
        -- also work and would mean every command on your server was reachable
        -- from inside it -- so any flaw anywhere in this resource became a
        -- way to run anything on the box. That trade is not worth making for
        -- one command.
        --
        -- Runtime only: nothing is written to a .cfg and nothing survives a
        -- restart. It is granted again at every start, from this config, so
        -- deleting a command above deletes its permission with it.
        --
        -- Set true only if you added a `commands` line above AND that command
        -- is gated on its own ACE. Off by default: most servers refuse a
        -- resource's attempt to grant itself anything -- correctly -- and the
        -- refusal is itself another console line per death.
        --
        -- If you do want it granted, the honest way is one line in server.cfg,
        -- which needs no permission from anybody because you are the console:
        --     add_ace resource.Crimson-Arena command.revive allow
        grantSelfPermission = false,

        -- PUT THIS RESOURCE IN THE ADMIN GROUP AS WELL.
        --
        -- The narrow grant above covers a revive command gated on its own
        -- ACE. It does nothing for one gated any other way -- and this
        -- server's still answered "access denied" with it on, which is what
        -- this is for.
        --
        -- It does two things: `command allow`, which is every command rather
        -- than the named few, and membership of the groups below, because a
        -- script that tests GROUP membership never looks at the ace list.
        -- Either could be what your revive checks, so both are applied.
        --
        -- BE CLEAR ABOUT THE TRADE, WHICH IS WHY THIS IS OFF.
        --
        -- With this on, any flaw anywhere in this resource is a way to run any
        -- command on your server. The arena no longer needs that for anything
        -- -- it revives players itself -- so paying that price buys nothing.
        --
        -- It is also usually refused anyway: a server that lets a resource
        -- write its own permissions is a server with no permissions. If you
        -- genuinely want the arena in the admin group, put it in server.cfg
        -- yourself, where the console is doing the granting:
        --     add_principal resource.Crimson-Arena group.admin
        grantSelfAdmin = false,

        -- The groups to join. `group.admin` is the usual one; add your own if
        -- your permissions are named differently.
        adminGroups = { 'group.admin' },

        -- HOW LONG AFTER A MID-MATCH RESPAWN TO REVIVE, in milliseconds.
        --
        -- The revive has to come AFTER the client has stood the player up,
        -- not before. Told first, your medical script is being told somebody
        -- is alive while their body is still a corpse -- and whatever it does
        -- then is undone by the resurrect, the collision wait and the
        -- teleport that follow. That is what put players back into a round
        -- still dead.
        --
        -- Raise it if a respawned player is still down. 0 reverts to
        -- reviving immediately, which is almost certainly not what you want.
        afterRespawnDelayMs = 2000,

        -- ONE MORE SWEEP AFTER THE MATCH, in milliseconds. 0 turns it off.
        --
        -- The per-player revive runs as each player is sent home -- before
        -- their body is stood up, before the teleport, before they leave the
        -- arena instance. A medical script told "alive" at that moment is
        -- being told it about somebody who is still a corpse somewhere else,
        -- and anything it does can be undone by the teardown behind it.
        --
        -- So the whole roster is revived once more, this long after the match
        -- has finished and everybody is home. Reviving somebody already alive
        -- costs nothing, which is what makes a blanket sweep the safe answer
        -- rather than a clever one.
        sweepAfterMatchMs = 5000,

        -- Server events. Each is triggered with the player's server id.
        --     serverEvents = { 'my_ambulance:server:revivePlayer' },
        serverEvents = {},

        -- Client events. Each is sent to that player only, with no
        -- arguments -- the client already knows who it is.
        --     clientEvents = { 'my_ambulance:client:revive' },
        clientEvents = {},

        -- Exports, called as exports.<resource>:<export>(src).
        --     exports = {
        --         { resource = 'my_ambulance', export = 'RevivePlayer' },
        --     },
        -- A resource that is not started, or an export that errors, is
        -- reported once in the console and skipped. It will not stop a
        -- match ending.
        exports = {},
    },

    vanillaPolice = {
        enabled = false,

        -- Stop NPC police reacting to this player at all.
        ignorePlayer = true,
        -- Stop the game dispatching units for them.
        stopDispatch = true,
        -- Stash the stars they walked in with, clear them on the way in, and
        -- hand back exactly what was captured on the way out -- including
        -- zero, if that is what they arrived with.
        --
        -- The wanted CEILING is deliberately not touched. Pinning it would
        -- hold stars at zero for the whole match, but there is no native to
        -- read the ceiling back, so the arena could only "restore" it to the
        -- stock 5 -- silently undoing a server that had deliberately set its
        -- own. A setting this resource cannot read back is one it does not
        -- set. Stars gained inside a round are cleared on exit either way.
        stashWantedLevel = true,
    },

    -- ==================================================================
    -- THE "PERSON DOWN" ALERT, STOPPED AT SOURCE
    --
    -- This one needs nothing from anybody. Most medical scripts spot a
    -- casualty by watching whether a player is dead, on a loop that runs
    -- somewhere between twice a second and once a second. With this on, an
    -- arena death is reported to the server and the body is put back on its
    -- feet in the same instant -- frozen, invisible and untouchable until
    -- the server says whether they respawn or are out -- so that loop never
    -- sees a dead player to report.
    --
    -- It also makes respawning feel sharper, which is why it is on even for
    -- servers with no medical script at all.
    --
    -- THE HONEST LIMIT: a script that hooks the death EVENT rather than
    -- polling the death STATE still fires, because the player really did
    -- die. For those, use `custom` above. This is not a substitute for it.
    -- ==================================================================
    clearDeadStateImmediately = true,
}
