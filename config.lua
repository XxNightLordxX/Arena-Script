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
--- Leave off on a live server -- it is chatty.
Config.Debug = false

--- ox_lib notification title for every message this resource sends.
Config.NotifyTitle = 'CRIMSON ARENA'

-- ======================================================================
-- LOBBY -- the entry point players walk up to.
-- ======================================================================
Config.Lobby = {
    -- HOW PLAYERS OPEN THE ARENA PANEL.
    --   'ped'    -- an NPC stands at `ped.coords`; players use their target
    --              script (ox_target/qb-target) on them. This is the default.
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
        coords = vector4(-268.16, -2023.42, 30.14, 267.5),
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
        coords = vector3(-268.16, -2023.42, 29.14),
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
    returnCoords = vector4(-265.41, -2019.88, 30.14, 90.0),
}

-- ======================================================================
-- ARENAS -- the grounds people actually fight on.
--
-- Add as many as you like. `enabled = false` hides one without deleting it.
--
-- SPAWNS: you do not need one spawn point per player. Spawn points are
-- handed out round-robin and each player is scattered within
-- `Config.Match.spawnScatterRadius` of the point they draw, so twenty
-- players can share four spawn points without stacking inside each other.
-- ======================================================================
Config.Arenas = {
    ['warehouse'] = {
        label = 'Crimson Warehouse',
        description = 'Tight indoor lanes. Shotguns and SMGs eat here.',
        enabled = true,

        -- Used in free-for-all modes, and as the fallback for any team
        -- that has no entry in `teamSpawns` below.
        spawns = {
            vector4(1088.51, -3099.44, -38.99, 180.0),
            vector4(1077.28, -3091.12, -38.99, 270.0),
            vector4(1097.63, -3091.55, -38.99, 90.0),
            vector4(1088.02, -3082.10, -38.99, 0.0),
        },

        -- Used in team modes. Keys must match `Config.Teams.list` keys.
        -- A team missing here falls back to `spawns` above.
        teamSpawns = {
            crimson = {
                vector4(1077.28, -3091.12, -38.99, 270.0),
                vector4(1078.94, -3095.60, -38.99, 270.0),
            },
            ash = {
                vector4(1097.63, -3091.55, -38.99, 90.0),
                vector4(1096.10, -3086.90, -38.99, 90.0),
            },
        },

        -- Players who wander outside this sphere are warned, then damaged
        -- until they come back. Set `enabled = false` for an open arena.
        boundary = {
            enabled = true,
            center = vector3(1088.51, -3091.44, -38.99),
            radius = 60.0,
            warningSeconds = 5,
            damagePerTick = 8,
            tickMs = 1000,
        },

        -- Optional atmosphere while the match runs. nil = leave the world
        -- exactly as it is.
        weatherOverride = nil,
        timeOverride = nil,     -- e.g. { hour = 22, minute = 0 }
    },

    ['yard'] = {
        label = 'The Yard',
        description = 'Open ground with hard cover. Rifles rule.',
        enabled = true,

        spawns = {
            vector4(-1605.30, -1108.10, 2.20, 140.0),
            vector4(-1571.44, -1080.63, 2.20, 320.0),
            vector4(-1588.90, -1120.55, 2.20, 40.0),
            vector4(-1560.12, -1099.80, 2.20, 220.0),
        },

        teamSpawns = {
            crimson = {
                vector4(-1605.30, -1108.10, 2.20, 140.0),
                vector4(-1601.88, -1112.44, 2.20, 140.0),
            },
            ash = {
                vector4(-1571.44, -1080.63, 2.20, 320.0),
                vector4(-1567.02, -1076.35, 2.20, 320.0),
            },
        },

        boundary = {
            enabled = true,
            center = vector3(-1585.00, -1094.00, 2.20),
            radius = 90.0,
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
        enabled = false,        -- off by default; needs `gunGameLadder` below
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
-- clamps to no matter what arrives on the wire. A weapon with
-- `ammo.options = nil` is handed out at `ammo.default` with no picker.
-- ======================================================================
Config.Loadouts = {
    -- Players choose their own weapons. With this off, everyone is given
    -- `Config.Loadouts.fixed` instead and the picker is hidden.
    allowChoose = true,

    -- How many weapons one player may take into a match. Raise it for
    -- loadout-style play, drop it to 1 for a duel server.
    weaponSlots = 2,

    -- Handed to everyone on top of what they picked. Use it for a knife,
    -- a parachute, or nothing at all.
    alwaysGive = {
        { weapon = 'WEAPON_KNIFE', ammo = 1 },
    },

    -- Used only when `allowChoose = false`.
    fixed = {
        { key = 'rifle', ammo = 250 },
        { key = 'pistol', ammo = 100 },
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
            -- No `options` -- melee has nothing to pick, so the panel shows
            -- no ammo row for it and the server hands out `default`.
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
    },

    -- Body armour, picked the same way ammo is.
    armor = {
        allowChoose = true,
        options = { 0, 50, 100 },
        default = 100,
        max = 100,
    },

    -- Health every player starts a round on. 200 is a stock GTA full bar.
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
-- when the match ends, or refunded in full if the match is cancelled, fails
-- to start, or ends with nobody eligible to be paid.
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
        -- The host sets one fee for the whole match and everyone pays it.
        -- With this off, each player stakes whatever they like and the
        -- payout is weighted by stake.
        hostSetsForEveryone = true,
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

    refundOnCancel = true,
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

    -- Lives per player. 1 = eliminated on first death. Higher values
    -- respawn the player at a fresh spawn point.
    lives = 1,
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
    command = 'arena',

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
-- DATABASE -- the leaderboard only.
--
-- Turning this off costs you nothing but the all-time leaderboard: matches,
-- betting and payouts all work exactly the same in memory. oxmysql stays a
-- hard dependency in fxmanifest.lua either way -- FiveM checks that before
-- this file is ever read, so no setting here can route around it.
-- ======================================================================
Config.Database = {
    enabled = true,
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
-- ======================================================================
Config.Dispatch = {
    -- The two switches you actually came here for. Both only ever apply to
    -- players who are IN a match -- nothing here follows anyone back out.
    suppressPoliceShotsFired = true,
    suppressAmbulanceDown = true,

    -- ==================================================================
    -- YOUR DISPATCH SCRIPT
    --
    -- Three ways to read the same fact. Pick one; the others cost nothing.
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
        disableExports = {},
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
    vanillaPolice = {
        enabled = false,

        -- Stop NPC police reacting to this player at all.
        ignorePlayer = true,
        -- Stop the game dispatching units for them.
        stopDispatch = true,
        -- Stash the stars they walked in with, pin them at zero for the
        -- match, and hand them back on the way out. Without the pin, stars
        -- come straight back the first time somebody shoots near an NPC.
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

    -- Keep the player out of the game's own injured/recovery handling for
    -- the length of the match.
    disableHealthRecharge = true,
}
