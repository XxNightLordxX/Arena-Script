--[[
    CRIMSON ARENA -- config.lua

    ONE OF THE TWO FILES YOU EDIT, and nothing in either needs code to go
    with it. Paste an arena in and it appears in the panel. Delete a weapon
    and it leaves the game. There is no second list to register anything with.

    THE WEAPON CATALOGUE IS NEXT DOOR, in config.weapons.lua: a thousand
    lines of weapon blocks that everybody editing a timer or a payout used to
    scroll past. It is loaded straight after this file and writes into the
    same `Config` table.

    THE FILE IS ORDERED BY HOW OFTEN YOU TOUCH IT: the settings first, then
    the arena list, then the optional integrations most servers never open.
    The map below is the fast way in.

    ------------------------------------------------------------------------------
     line   setting       what it is
    ------------------------------------------------------------------------------
       81   Lobby         The NPC players walk up to
      151   Schedule      Opening hours: when the door is actually open
      187   Match         Lives, timers, player counts, win condition
      484   Teams         The sides, and whether they may be uneven
      600   Modes         Free-for-all, team deathmatch and gun game
      904   DefaultMode   Which of them a new lobby opens on
      923   Betting       Entry fees, self-bets, side-bets, how the pot is split
      1100  UI            Panel colours, logo and title
      1150  Permissions   Who may open a match, who may force-stop one
      1231  Arenas        THE GROUNDS. One block per arena; paste one in, it appears
     1665   Loadouts      Slots, ammo items and supplies (weapons: config.weapons.lua)
     1997   Database      Optional: all-time leaderboard. Off, no SQL to import
     2007   Webhook       Optional: a Discord line per finished match
     2039   Dispatch      Optional: keeping police and EMS out of the arena
    ------------------------------------------------------------------------------

    (Those line numbers were kept honest by a test, which is not in this
    release -- so if you add or remove lines above a setting, the number
    beside it goes stale and nothing will tell you.)

    FOUR THINGS THAT TRIP PEOPLE UP

      1. ZERO MEANS UNLIMITED, not "none". `maxPlayers = 0`, `maxTeamSize`,
         `maxPot`, `maxConcurrentMatches` -- zero is the no-ceiling value
         everywhere in this file, and it is spelled out next to each one.

      2. AN EMPTY LIST DOES NOT MEAN THE SAME THING TWICE. Empty job and
         group lists in Config.Permissions mean EVERYONE; an empty list in
         Config.Dispatch means NOTHING IS CALLED. Each one says which.

      3. NOTHING A PLAYER'S CLIENT CLAIMS IS TRUSTED. The weapon and ammo a
         client asks for are re-checked against the lists here by the server
         before a round is handed out, so shortening a list genuinely removes
         that weapon -- it does not merely hide a button.

      4. THE ARENAS AND THE LOBBY ARE SEPARATE SETTINGS. Config.Lobby is
         where players come to join. Config.Arenas is where they fight.
         Moving one does not move the other.
]]

Config = {}

-- ======================================================================
-- GENERAL
-- ======================================================================

--- Printed in the console and used as the notification title.
Config.ResourceLabel = 'Crimson Arena'

--- Extra console logging, for working out why a round went the way it did.
---
--- SHIPS ON, DELIBERATELY. Nothing here reaches a player, and the console is
--- how a strange round gets explained rather than guessed at.
Config.Debug = true

--- ox_lib notification title for every message this resource sends.
Config.NotifyTitle = 'CRIMSON ARENA'

-- ======================================================================
-- LOBBY -- the entry point players walk up to.
-- ======================================================================
Config.Lobby = {
    -- HOW PLAYERS OPEN THE ARENA PANEL. Write one of:
    --   'ped'    -- an NPC they walk up to (needs ox_target)
    --   'marker' -- a glowing spot they stand in and press `marker.key`
    --   'both'   -- the NPC and the marker, either one opens the panel
    --
    -- On 'ped' with ox_target missing there is NO fallback marker: no NPC is
    -- spawned and the console says so. Use 'both' if you want the safety net.
    interaction = 'ped',

    ped = {
        model = 'g_m_m_armboss_01',
        -- x, y, z, heading. Use the GROUND z -- the resource drops the ped
        -- by one unit itself so it does not float. Keep it outdoors.
        --
        -- This is only where players come to JOIN. The fighting happens
        -- wherever Config.Arenas puts it.
        coords = vector4(-282.0125, -2030.4575, 30.1457, 276.6953),
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
        -- The same spot as the NPC, so 'both' does not send players to two
        -- different places.
        coords = vector3(-282.0125, -2030.4575, 30.1457),
        size = vector3(1.6, 1.6, 0.6),
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
    -- ends -- and where they land if the resource restarts mid-match. It
    -- must be somewhere safe to stand.
    returnCoords = vector4(-282.0125, -2030.4575, 30.1457, 276.6953),
}

-- ======================================================================
-- OPENING HOURS -- when the door in Config.Lobby is actually open
--
-- Ships on, with four windows. Outside them nobody may open a match and
-- nobody may join one.
--
-- THESE ARE REAL HOURS ON THE SERVER'S OWN CLOCK -- not the city clock, and
-- not the player's. A GTA day is 48 real minutes, so city hours would open
-- the arena in four-minute bursts around the clock and no round could
-- finish inside one. Everybody sees the same schedule wherever they are.
-- ======================================================================
Config.Schedule = {
    -- Off, the arena never shuts and nothing below is read.
    --
    -- You do not have to edit this file to make an exception: /arenaadmin
    -- holds the doors open past the schedule, or shuts them inside it, until
    -- the server restarts.
    enabled = true,

    -- WHOLE HOURS, 24-hour clock. Open at `from`, shut at `to`: 5 to 7 is
    -- open at 06:59 and shut at 07:00. Windows that touch are shown as one.
    -- A window may cross midnight -- { from = 22, to = 2 } is fine, and
    -- `to = 0` and `to = 24` both mean midnight.
    --
    -- A window with hours out of range, or with `from` equal to `to`, is
    -- DROPPED and named in the console rather than corrected. Write
    -- { from = 0, to = 24 } for all day.
    windows = {
        { from = 0,  to = 4 },   -- midnight to 4am
        { from = 5,  to = 7 },   -- 5am to 7am
        { from = 12, to = 14 },  -- noon to 2pm
        { from = 18, to = 20 },  -- 6pm to 8pm
    },

    -- HOURS TO ADD TO THE SERVER'S CLOCK, when the machine is not in your
    -- players' timezone. Most hosts run on UTC: if your players are five
    -- hours behind it, put -5 here.
    --
    -- 0 means the server's clock is already right. It knows nothing about
    -- daylight saving -- when the clocks change, change this too.
    -- `/arenahours` prints what the server currently thinks the time is.
    offsetHours = 0,
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

    -- HOW LONG A ROUND RUNS, in real seconds. 0 = no time limit.
    --
    -- TWO SHAPES. Write a plain number -- `roundTimeSeconds = 600` -- to fix
    -- it for every match. Write the block below and the HOST picks it when
    -- they create the match, opening on `default`.
    --
    -- THE FIRST OF THESE THAT IS SET WINS: what the host chose for this
    -- match, then the mode's own `roundTimeSeconds` (gun game has one), then
    -- `default` below. So gun game runs its designed 480 seconds unless a
    -- host says otherwise, and a host who says otherwise gets what they
    -- asked for.
    --
    -- `allowChoose = false` takes the control off the create screen.
    roundTimeSeconds = {
        allowChoose = true,
        min = 60,
        max = 3600,
        default = 600,
    },

    -- LIVES PER PLAYER. 1 = out on the first death. Above that, a player
    -- who dies comes back at a fresh spawn with a full loadout, and is only
    -- out once the last one is spent.
    --
    -- Three lives makes a much longer round than one, so set
    -- roundTimeSeconds with it in mind.
    --
    -- ONLY 'last_standing' SPENDS LIVES. The other two win conditions end on
    -- a count, so nobody is ever eliminated under them and this number is not
    -- read -- the panel takes the box away and says why. See `winCondition`.
    --
    -- Write a plain number -- `lives = 3` -- to fix it for every match.
    lives = {
        allowChoose = true,
        min = 1,
        max = 10,
        default = 3,
    },

    -- How long a player lies there before being put back in. Long enough to
    -- feel like a death, short enough not to be a punishment on its own.
    respawnDelaySeconds = 5,

    -- HOW A MATCH IS WON. Three, and only these three:
    --   'last_standing' -- everyone else eliminated
    --   'most_kills'    -- highest kill count when the clock runs out
    --   'score_limit'   -- first to `scoreLimit` kills
    --
    -- TWO SHAPES. Write a plain string -- `winCondition = 'last_standing'` --
    -- to fix it for every match. Write the block below and the host picks it
    -- from a dropdown, opening on `default`. There is no list to write: each
    -- name has code behind it, so a fourth one invented here would be a round
    -- that never ends, and a `default` this file does not know is named in
    -- the console at start-up.
    --
    -- 'most_kills' NEEDS A CLOCK -- nothing about the roster can end it -- so
    -- a host who picks it on a mode with no time limit is refused.
    --
    -- GUN GAME IGNORES THIS ENTIRELY: it is won by topping the ladder or by
    -- its own clock. See Config.Modes.gungame.
    winCondition = {
        allowChoose = true,
        default = 'last_standing',
    },

    -- FIRST TO THIS MANY KILLS, under 'score_limit' and ignored otherwise.
    --
    -- TWO SHAPES, as above: a plain number fixes it, the block puts a box on
    -- the create screen when the host picks that win condition.
    --
    -- NOBODY IS ELIMINATED UNDER A SCORE LIMIT -- players respawn until
    -- somebody reaches the number, so `lives` is not read.
    scoreLimit = {
        allowChoose = true,
        min = 1,
        max = 200,
        default = 25,
    },

    -- Metres a player may be scattered from the spawn point they drew, so
    -- more players than spawn points never stack inside each other.
    spawnScatterRadius = 2.5,

    -- HOW FAR ABOVE THE SPAWN POINT A PLAYER IS HELD, in metres, while the
    -- world streams in around them.
    --
    -- KEEP IT SMALL -- a metre is a step off a kerb. It is enough to keep a
    -- ped out of the prop it is standing on, which is the whole job. Being
    -- frozen is what stops a fall through an unloaded world, not height, and
    -- a big number hangs every player in the air where the entire arena can
    -- see exactly where the spawn points are.
    spawnHeightOffset = 1.0,

    -- THE RADAR. A match setting, not a personal one: the host decides once
    -- when they create the match and everybody fights under it.
    --
    -- IT SWEEPS RATHER THAN TRACKS. Every `intervalMs` the fighters' dots
    -- appear for `visibleMs` and go dark again, so what a player gets is
    -- where everyone WAS a moment ago.
    --
    -- Config.Teams.showEnemyBlips overrides this: turn that on for permanent
    -- enemy dots and the radar never runs.
    radar = {
        -- Off, the host is not offered the choice and every match uses
        -- `defaultOn`.
        allowChoose = true,

        -- Where the host's toggle starts.
        defaultOn = false,

        -- The whole cycle, and how much of it is lit: a sweep every 30
        -- seconds, visible for most of a second, so 29.2s of it is dark.
        intervalMs = 30000,
        visibleMs = 800,
    },

    -- NOBODY SHOOTS ACROSS THE LINE, IN EITHER DIRECTION. Somebody outside a
    -- round cannot hurt anyone in it, and a fighter cannot hurt anyone
    -- outside. Refused on the SERVER, from the damage packet, so it holds
    -- whatever an edited client believes.
    --
    -- A live match already runs in its own instance, which covers the
    -- ordinary case. This covers the three it does not: a SPECTATOR, who is
    -- deliberately put in the match's instance so they can watch; a server
    -- with instancing switched off; and two rounds sharing one arena, who
    -- are as separate from each other as a fighter and a passer-by.
    --
    -- Hurting YOURSELF is never refused -- a fall or your own grenade is not
    -- crossfire.
    --
    -- IT ALSO CARRIES THE ONLY SERVER-SIDE REFUSAL OF FRIENDLY FIRE, so
    -- SWITCHING IT OFF REALLY DOES LET TEAMMATES SHOOT EACH OTHER. This is
    -- the one place a shot can be refused at all; the only other things
    -- standing between a bullet and a teammate are the client, which an
    -- edited one ignores, and the scoreboard, which merely declines to
    -- credit the kill. Leave it on and use Config.Teams.friendlyFire to
    -- decide whether teammates may fight.
    crossfireGuard = {
        enabled = true,
    },

    -- HOW FAR APART TWO PLAYERS MAY BE FOR ONE TO HAVE KILLED THE OTHER, in
    -- metres. `0` switches the check off.
    --
    -- WHY IT EXISTS. The server cannot watch a kill happen -- the dying
    -- player's own game reports it and names the killer. Without this, two
    -- accomplices could hand each other every kill in the round from opposite
    -- ends of the map without firing a shot, and take the pot with it. This
    -- does not make the report honest; it forces them to BE THERE, which
    -- costs them the round they are trying to win.
    --
    -- A FLOOR, NOT A CEILING. The arena's own boundary raises it whenever
    -- that is bigger, so a fair shot across a large arena is never refused.
    -- This number is what an arena with no boundary falls back to.
    --
    -- A refused claim costs the killer the credit and nothing else -- the
    -- death still counts, and the console says so with both distances.
    maxKillDistance = 150.0,

    -- PUSHING NON-FIGHTERS BACK OUT of an arena that is being fought in.
    -- The fence is the arena's own `boundary` -- the same circle a fighter is
    -- bled for leaving.
    keepOutBarrier = {
        enabled = true,

        -- How far outside the line they are put. Far enough not to be pushed
        -- again next tick, close enough to read as a wall and not a teleport.
        pushBackMetres = 6.0,

        -- How often the fence is checked. A quarter second catches a sprint.
        tickMs = 250,

        -- Tell them why they were moved, once per crossing.
        notify = true,
    },

    -- ==================================================================
    -- WHAT THE SERVER CHECKS FOR ITSELF
    --
    -- Two facts about a round come from the player's own game and nowhere
    -- else: where they are standing, and whether they just died. Everything
    -- else on this page is decided on the server, and those two were not --
    -- which is a hole big enough to win a round through.
    --
    --   PARKED OUTSIDE. The fence in each arena's `boundary` block is drawn
    --   and enforced by the player's own game, so a client that simply does
    --   not run it cannot be pushed back. Measured: a fighter sat 140 km
    --   from the arena while the others killed each other, and took the
    --   round and the pot.
    --
    --   NEVER DYING. A death is reported by the dying player's own game, and
    --   that report is the only thing that spends a life -- so a client that
    --   never sends one cannot be eliminated. Measured: a fighter killed
    --   nobody, was shot repeatedly, and won on last-man-standing.
    --
    -- SO THE SERVER LOOKS FOR ITSELF, once a second, and acts only on
    -- something it has seen several times running. That patience is the
    -- whole design: a player whose game is still loading the world, or who
    -- has just been teleported, reads for a moment exactly like a cheat, and
    -- throwing an honest player out of a paid round is worse than the thing
    -- this is here to stop.
    --
    -- IT FAILS OPEN, ALWAYS. A body the server cannot see -- mid-stream, not
    -- yet created -- counts as nothing at all rather than as a strike.
    -- ==================================================================
    serverChecks = {
        -- Off, both checks below stop entirely and the round is exactly as
        -- trusting as it was before they existed.
        enabled = true,

        -- HOW FAR PAST THE ARENA'S OWN FENCE counts as outside, in metres.
        --
        -- SMALL ON PURPOSE, BECAUSE THE TOLERANCE COMES FROM `outsideTicks`
        -- AND NOT FROM HERE. This shipped at 60 and that was a hiding place:
        -- the distance is measured in three dimensions from the middle of the
        -- arena, so anywhere 59m outside the sphere was permanently legal --
        -- including a point directly under the skydome's floor, through a
        -- kilometre of air nobody could reach. From there the kill ceiling
        -- still covered the whole arena, so a fighter could park out of the
        -- fight, stay credited, and be handed the round when everybody else
        -- had killed each other. Which is the exploit this block exists for.
        --
        -- Ten metres is enough for the honest case and no more: a fighter who
        -- steps over the line is being bled by the boundary already and either
        -- comes back -- which clears the count -- or dies of it.
        outsideMetres = 10.0,

        -- HOW MANY ONE-SECOND CHECKS IN A ROW they must be out there before
        -- the server removes them from the round. Their stake is forfeit,
        -- the same as a disconnect, because that is what walking out of a
        -- live round costs.
        --
        -- One sighting is not enough and never will be. Set it low and a
        -- fighter whose game hitched at the wrong moment loses their round.
        outsideTicks = 8,

        -- HOW MANY ONE-SECOND CHECKS IN A ROW a fighter's body must read as
        -- dead, with no death reported, before the server books the death
        -- itself. Nobody is credited with the kill -- the server did not see
        -- one -- so this costs a life and nothing else, which is exactly the
        -- half a silent client was skipping.
        --
        -- 0 switches this half off and leaves the fence.
        deadTicks = 4,
    },

    -- Eliminated players watch the rest of the match instead of being sent
    -- straight back to the lobby.
    spectateOnElimination = true,

    -- Give players back the weapons and armour they walked in with when
    -- they leave. Strongly recommended on.
    restoreLoadoutOnExit = true,

    -- A match sitting in the lobby with nobody readying up is closed after
    -- this long, and any stakes refunded. 0 = never.
    idleLobbyTimeoutSeconds = 900,

    -- Refuse to let a player join while they are dead, cuffed or in a
    -- vehicle. Server-checked.
    blockWhileDead = true,
    blockWhileInVehicle = true,
}

-- ======================================================================
-- TEAMS
--
-- UNEVEN TEAMS ARE ALLOWED BY DEFAULT. Nine against one is a legal match.
-- Set `allowUnequal = false` to have the server refuse to start while the
-- sides differ by more than `maxTeamSizeDifference`.
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

    -- Someone who never picked a side is put on the SMALLEST team when the
    -- match starts -- at random only when the sides are already level, so a
    -- lobby where nobody picked still comes out even.
    --
    -- Off, they are asked to pick and the start waits for them.
    autoAssignIfUnchosen = true,

    -- CAN TEAMMATES HURT EACH OTHER? Off means the SHOT is refused, not
    -- merely that the kill is not counted. This is the one switch to move --
    -- three separate places read it.
    --
    -- WHAT "REFUSED" COVERS, since the engine decides the shape of this:
    --
    --   Bullets and melee are refused on the server.
    --
    --   Nothing stops the TRIGGER. Aiming at your own side still fires,
    --   still spends the round, and still plays the flinch on your own
    --   screen. Judge it by your teammate's health bar, not by the feel.
    --
    --   A SPREAD THAT CATCHES A TEAMMATE on its way to an enemy goes
    --   through, teammate included: one shotgun blast is one packet naming
    --   everybody it touched, and it is allowed or refused whole. The kill
    --   is still not counted.
    --
    --   EXPLOSIONS ARE NOT REFUSED, AND EXPLOSIVES DO SHIP ENABLED. Every
    --   weapon in config.weapons.lua is switched on, the whole `heavy`
    --   category included -- launchers, the minigun, the railgun, the
    --   flamethrower. So on a team mode, teammates CAN blow each other up
    --   whatever this setting says. Switch the heavy entries off in
    --   config.weapons.lua if that is not the round you want.
    friendlyFire = false,

    -- YOUR OWN SIDE ON THE MAP, all round. Knowing where your team is is the
    -- difference between a team mode and four people in the same field.
    showTeamBlips = true,

    -- THE OTHER SIDE, NEVER -- a permanent dot on every enemy turns a round
    -- into a map to be read rather than a place to be searched.
    -- Config.Match.radar is how an enemy position is learned instead. Turn
    -- this on for permanent enemy dots, and the radar stops running.
    showEnemyBlips = false,

    -- A COLOURED EDGE ROUND YOUR TEAMMATES, in that team's own colour.
    --
    -- Teammates only, and it cannot be turned on for enemies: an outline
    -- draws THROUGH walls, which is the point of it for finding a friend and
    -- exactly the problem with it for finding a target.
    showTeamOutline = true,

    -- PICK COLOURS TO BE TOLD APART AT A GLANCE, not to be tasteful.
    --
    -- `color` is a hex string: the panel accent and the outline on your own
    -- side. `blipColor` is one of GTA's numbered map colours. They are two
    -- different systems, so choose them to MATCH -- otherwise the edge round
    -- your teammate is one colour and their dot on the map is another.
    list = {
        ['crimson'] = {
            label = 'Crimson',
            color = '#ff2233',
            blipColor = 1,      -- red
            enabled = true,
            order = 1,
        },
        ['ash'] = {
            label = 'Ash',
            color = '#2aa6ff',
            blipColor = 3,      -- blue
            enabled = true,
            order = 2,
        },
        -- A third and fourth side ship disabled. Turn one on and every team
        -- mode offers it at once. Give it spawn points in each arena's
        -- `teamSpawns` or it falls back to the shared `spawns` list.
        ['bone'] = {
            label = 'Bone',
            color = '#ffd34d',
            blipColor = 5,      -- yellow
            enabled = false,
            order = 3,
        },
        ['ember'] = {
            label = 'Ember',
            color = '#ff8c1a',
            blipColor = 17,     -- orange
            enabled = false,
            order = 4,
        },
    },
}

-- ======================================================================
-- MODES
--
-- `teams = false` is a free-for-all: everyone against everyone, and the
-- team picker is not shown at all. `teams = true` shows the team picker.
-- ======================================================================
Config.Modes = {
    -- WHAT A KILL PAYS IN AMMUNITION, in free-for-all and team deathmatch.
    --
    -- ROUNDS PER KILL, PER WEAPON YOU ARE CARRYING. Land a kill and every
    -- firearm in your loadout is handed this many rounds of its own calibre.
    -- Melee is paid nothing -- a blade names no ammunition. Only kills the
    -- server verified pay at all. `0` switches it off.
    --
    -- The arena pays this rather than letting people loot the body, which is
    -- refused (`Config.Loadouts.inventory.blockDropsInArena`).
    --
    -- A NOTE ON FARMING. Two players who agree to trade deaths can pump
    -- ammunition between them, and what stops it is the win condition:
    -- 'last_standing' spends a life each time, so it runs out; the other two
    -- never eliminate anybody, so the kill limit or the clock is the only
    -- bound.
    --
    -- ON THE SHIPPED SETTINGS THE ROUNDS GO NOWHERE -- `stripOnEntry` empties
    -- the arena kit at the door and `blockDropsInArena` stops anything moving
    -- out mid-match, so it dies with the round. Turn either of those off and
    -- this becomes a real item farm: lower it, or set it to 0.
    ['ffa'] = {
        label = 'Free For All',
        description = 'Every player for themselves. Last one breathing takes the pot.',
        enabled = true,
        teams = false,
        icon = 'fas fa-skull-crossbones',
        killAmmo = 100,
    },

    ['tdm'] = {
        label = 'Team Deathmatch',
        description = 'Pick a side. Wipe the other one out.',
        enabled = true,
        teams = true,
        icon = 'fas fa-users',
        killAmmo = 100,
    },

    -- ==================================================================
    -- GUN GAME
    --
    -- A TIMER, NOT LIVES. Nobody is eliminated: you respawn for as long as
    -- the clock runs, and the clock is the round. That is why this mode
    -- carries its own `roundTimeSeconds` below.
    --
    -- CLIMB BY KILLING, FALL BY DYING. Every kill moves you one tier up;
    -- every death moves you one down and takes that tier's weapon with it.
    --
    -- THE LADDER IS DRAWN, NOT FIXED. The tiers are ordered pools -- melee,
    -- then sidearms, then up -- and one weapon is drawn from each pool at the
    -- start of the round. The shape of the climb is the same every time; the
    -- guns on it are not.
    -- ==================================================================
    ['gungame'] = {
        label = 'Gun Game',
        description = 'Climb the tiers. Every kill is a better weapon, every death costs you one.',
        enabled = true,
        -- A ladder is climbed by one player, so it is won by one player.
        teams = false,
        icon = 'fas fa-arrow-up-9-1',

        -- HOW LONG A ROUND OF THIS MODE RUNS, in real seconds. Overrides
        -- Config.Match.roundTimeSeconds for gun game and nothing else, and a
        -- host who sets their own still beats it.
        --
        -- Eight minutes is long enough to get near the top of a seven-tier
        -- ladder and short enough to play several. `0` removes the clock and
        -- the round then runs until somebody finishes the ladder, which in an
        -- even lobby can take a while.
        roundTimeSeconds = 480,

        -- THE TIERS, WEAKEST FIRST, each one a POOL of weapon keys from
        -- config.weapons.lua. One weapon is drawn from each pool at the start
        -- of every round: everybody climbs the same ladder, and it is a
        -- different ladder next round.
        --
        -- ORDER IS POWER. These are climbed bottom to top, so put only
        -- weapons that belong at that step in a pool. Reorder the tiers and
        -- you reorder the climb; add one and the ladder gets longer.
        --
        -- A KEY THAT IS NOT AN ENABLED WEAPON IS SKIPPED, and a tier whose
        -- whole pool is off is dropped -- one typo shortens the ladder rather
        -- than breaking the mode. Under two tiers is not a gun game, and the
        -- console says so at start-up.
        --
        -- SEVEN TIERS IS TUNED TO THE RULE ABOVE. Because a death costs a
        -- tier, a player's tier is their kills less their deaths -- so
        -- topping a seven-tier ladder means being six kills up on the field,
        -- which is a real run rather than a formality. A much longer ladder
        -- is one nobody finishes and the clock decides every round; a much
        -- shorter one is finished in the first two minutes.
        -- THE LADDER, BY WEAPON CLASS.
        --
        -- Each entry is one CLASS of weapon -- melee, sidearms, and up -- in
        -- climbing order, with its own ordered pool of weapons (weakest
        -- first) and how many RUNGS of the ladder that class fills by
        -- default. The pool is split evenly across those rungs, so a class
        -- of eighteen sidearms across nine rungs draws two apiece and the
        -- climb still goes weakest-to-strongest inside the class.
        --
        -- THE HOST PICKS THE COUNTS. The match-creation menu shows one row
        -- per class, and `tiers` here is what it opens on. A class set to 0
        -- is left out of the ladder entirely -- a server that wants pistols
        -- and rifles and nothing else is a legal ladder.
        --
        -- WHY CLASSES RATHER THAN A FLAT LIST OF POOLS. It was a flat list,
        -- and a flat list cannot be composed: "give me four shotgun rungs" is
        -- not a thing you can ask of it without knowing which of the thirty
        -- entries happened to be shotguns. It is also how the ladder got five
        -- melee rungs deep without anybody noticing that a sixth of every
        -- round was being fought with clubs.
        --
        -- A class can never have more rungs than it has weapons: one weapon
        -- per rung is the floor, and asking for more is refused rather than
        -- padded, because two rungs drawing from the same single weapon is a
        -- promotion that hands you the gun you are already holding.
        --
        -- `enabled = false` on a WEAPON in config.weapons.lua removes it from
        -- these pools wherever it appears, and a class left with nothing
        -- playable is skipped.
        gunGameClasses = {
            {
                key = 'melee',
                label = 'Melee',
                -- ONE RUNG BY DEFAULT, AND THAT IS THE POINT OF THE MODE.
                -- Everybody opens the round on a blade or a bat -- which is
                -- what makes the first kill of a gun game the hardest one --
                -- and the climb is out of melee from the very next tier.
                tiers = 1,
                weapons = {
                    'bat', 'hammer', 'nightstick', 'stonehatchet', 'bottle', 'hatchet',
                    'poolcue', 'candycane', 'crowbar', 'knife', 'switchblade', 'flashlight',
                    'dagger', 'knuckles', 'wrench', 'golfclub', 'machete', 'battleaxe',
                },
            },
            {
                key = 'sidearm',
                label = 'Sidearms',
                -- THE LONGEST STRETCH, because this is the part of the climb
                -- everybody sees every round: a player who never gets past
                -- tier 6 should still have felt the gun get better three
                -- times on the way.
                tiers = 9,
                weapons = {
                    'snspistol', 'vintagepistol', 'pistol', 'ceramicpistol',
                    'combatpistol', 'gadgetpistol', 'snspistolmk2', 'pistolxm3',
                    'appistol', 'doubleaction', 'heavypistol', 'tecpistol',
                    'pistolmk2', 'navyrevolver', 'pistol50', 'marksmanpistol',
                    'revolver', 'revolvermk2',
                },
            },
            {
                key = 'smg',
                label = 'Machine Pistols & SMGs',
                tiers = 4,
                weapons = {
                    'machinepistol', 'minismg', 'microsmg', 'smg',
                    'assaultsmg', 'smgmk2', 'combatpdw', 'gusenberg',
                },
            },
            {
                key = 'shotgun',
                label = 'Shotguns',
                -- Close-range rungs in the MIDDLE of the ladder, which is
                -- what stops the climb being one long straight line of "more
                -- range than the last one".
                tiers = 4,
                weapons = {
                    'dbshotgun', 'sawnoffshotgun', 'pumpshotgunmk2', 'shotgun',
                    'bullpupshotgun', 'combatshotgun', 'assaultshotgun',
                    'heavyshotgun', 'autoshotgun',
                },
            },
            {
                key = 'rifle',
                label = 'Carbines & Rifles',
                tiers = 7,
                weapons = {
                    'compactrifle', 'advancedrifle', 'carbine', 'rifle',
                    'carbineriflemk2', 'riflemk2', 'bullpuprifle', 'specialcarbine',
                    'bullpupriflemk2', 'specialcarbinemk2', 'tacticalrifle',
                    'militaryrifle', 'heavyrifle', 'battlerifle',
                },
            },
            {
                key = 'heavy',
                label = 'Heavy',
                tiers = 2,
                weapons = { 'musket', 'mg', 'combatmg', 'combatmgmk2' },
            },
            {
                key = 'precision',
                label = 'Precision',
                -- AT THE TOP, where a player who has already earned
                -- twenty-seven kills is the one holding it.
                tiers = 3,
                weapons = {
                    'marksman', 'marksmanriflemk2', 'sniper',
                    'precisionrifle', 'heavysniper', 'snipermk2',
                },
            },
        },

        -- WHAT A KILL IS WORTH BESIDES THE TIER, by supply key from
        -- Config.Loadouts.supplies.items -- so an operator who renamed the
        -- bandage item once does not have to rename it again here.
        --
        -- Bandages every time, armour a quarter of the time. The bandages
        -- are the reason a good player can keep a run going without leaving
        -- the fight, and the armour is the reason they still have to think
        -- about it: 25 means one kill in four, on average, and not one in
        -- four exactly -- it is a roll per kill.
        --
        -- `chance` is a percentage. Leave it out and the supply is given on
        -- every kill; set it to 0 and it is never given at all. An entry
        -- naming a supply this server has switched off is skipped.
        --
        -- THESE ARE ONLY PAID ON A KILL THAT COUNTED FOR THE LADDER, which
        -- is what stops an accomplice being farmed for bandages after
        -- `maxTiersPerVictim` below has stopped paying tiers.
        -- HOW MANY ROUNDS A TIER WEAPON IS HANDED.
        --
        -- A LADDER RE-ARMS YOU, AND THAT IS THE POINT OF THE MODE. Without a
        -- number here each tier arrived on the weapon's own `ammo.default`
        -- from config.weapons.lua -- 60 for a sidearm, 150 for a rifle -- and
        -- because a promotion sweeps the previous tier's rounds away along
        -- with its gun, that one number was the whole supply for the tier.
        -- Sixty rounds is a magazine and a half to fight a whole rung with,
        -- and running dry should be a mistake you made rather than the shape
        -- of the mode.
        --
        -- CLAMPED PER WEAPON, NOT HANDED OUT FLAT. Each weapon's own
        -- `ammo.max` still holds -- a number bigger than a weapon allows
        -- becomes that weapon's ceiling rather than being refused -- and
        -- melee is given none at all, because a blade is not an ammo weapon
        -- and ox_inventory reads a present ammo key as saying it is.
        --
        -- DELETE THIS LINE, or set it to 0, and every tier falls back to its
        -- weapon's own default exactly as it did before.
        tierAmmo = 200,

        killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 1, chance = 25 },
        },

        -- WHAT EVERYBODY WALKS IN WITH, every round, whatever they picked --
        -- by supply key from Config.Loadouts.supplies.items, so an operator
        -- who renamed the bandage item once does not have to rename it here
        -- as well.
        --
        -- THE LOADOUT SCREEN IS SHUT IN THIS MODE and this is the other half
        -- of that. The ladder decides the weapon, so there is no weapon to
        -- pick; leaving the SUPPLIES pickable would mean a mode where the
        -- guns are equal and the plates are not, which is the one asymmetry
        -- a ladder cannot absorb -- everybody meets on tier 1 with a blade,
        -- and the player who bought twenty-five plates wins that meeting
        -- every time. So the kit is the operator's, one kit, everybody.
        --
        -- CLAMPED TO EACH SUPPLY'S OWN `max`, exactly as a player's request
        -- is, and a key naming a supply this server has switched off is
        -- skipped. With Config.Loadouts.supplies.enabled off, nobody carries
        -- any of it and this list is ignored -- that switch outranks a mode.
        --
        -- AN EMPTY LIST MEANS NOTHING CARRIED; DELETING THE FIELD ENTIRELY
        -- means "no opinion", and the players fall back to what the rest of
        -- the resource would have given them. The two are different on
        -- purpose, the same way `chance` above is.
        startingKit = {
            { key = 'armour', count = 1 },
            { key = 'bandage', count = 5 },
        },

        -- HOW MANY TIERS ONE KILLER MAY TAKE OFF ANY SINGLE PLAYER, per
        -- round. Kills past this still count everywhere else -- scoreboard,
        -- leaderboard, payout -- they just stop moving the killer up.
        --
        -- THIS IS THE ANTI-COLLUSION RULE. The server cannot see a kill
        -- happen; it is told who died and who they say killed them. With no
        -- lives to spend and the ladder ending the round outright, two
        -- players trading kills can top it in under a minute and take the pot.
        --
        -- IT IS OFF HERE, ON PURPOSE, SO A 1v1 CAN BE PLAYED. The cap means
        -- "spread your kills across the field", and a field of one has
        -- nowhere to spread. Off is off: on an open server with money on the
        -- round, put it back.
        --
        -- PUT IT BACK by writing a number. `2` is generous to honest play --
        -- killing the same opponent twice in a round is ordinary -- and a
        -- seven-tier ladder then needs four different victims to top.
        --
        -- Anything that is not a number falls back to the built-in default
        -- and is named in the console. Only a real `0` switches it off, so a
        -- typo cannot disable this quietly.
        maxTiersPerVictim = 0,

        -- Tell the room when somebody reaches the top tier, so the last
        -- stretch is a race everybody can see rather than a surprise ending.
        announceFinalTier = true,
    },
}

--- Which mode a newly created match starts on before the host changes it.
Config.DefaultMode = 'ffa'

-- ======================================================================
-- BETTING
--
-- ONE SWITCH TURNS ALL OF IT OFF: `Config.Betting.enabled = false` hides
-- every bet control and makes the server refuse any bet that arrives anyway.
--
-- HOW THE MONEY MOVES: an entry fee leaves the player's account the moment
-- they lock in and is held by the match. It is paid to the winners at the
-- end, or refunded in full if the match never starts, is closed by the
-- server, or ends with nobody eligible to be paid.
--
-- THREE SETTINGS BELOW DECIDE WHETHER A STAKE COMES BACK, and they do not
-- all ship the same way. `refundOnCancel` and `refundOnDisconnectBeforeStart`
-- both refund. `refundOnDisconnectDuringMatch` does NOT: a fighter who
-- crashes out of a live round forfeits, and that is the commonest case of
-- the three.
-- ======================================================================
Config.Betting = {
    enabled = true,

    -- 'cash' or 'bank'.
    account = 'cash',

    -- WHERE A STAKE IS TAKEN FROM, in the order tried. Each account is tried
    -- for the WHOLE amount -- a stake is never split across two, so nobody
    -- ends up half-charged for a bet that was refused.
    --
    -- Money always goes back where it came from.
    accounts = { 'cash', 'bank' },

    -- HOW A WINNING BET IS PAID -- fighters backing themselves, and
    -- spectators backing anybody. Write one of:
    --
    --   'pool' -- every bet goes into one pool and the winners split it in
    --             proportion to what they staked. Winners are paid with the
    --             losers' money and the server creates nothing, so a big pool
    --             with one winner pays enormously and a small one split four
    --             ways pays little.
    --
    --   'odds' -- the stake is multiplied by `spectatorBets.oddsMultiplier`
    --             and paid BY THE SERVER. Predictable, and it costs the
    --             server money on every win.
    --
    -- BOTH SHIP AS 'pool'. 'odds' on a bet placed by somebody who can decide
    -- the result is a money printer: a fighter backs themselves to win a
    -- round they were going to win anyway and the server pays for it.
    --
    -- THIS IS NOT `Config.Betting.payout`, which is further down and answers
    -- a different question: how the POT is split between the winners.
    betPayout = {
        fighters = 'pool',
        spectators = 'pool',

        -- ONE POOL FOR FIGHTERS AND SPECTATORS, or one each. Shared makes a
        -- small arena's pool worth betting into; separate keeps the two
        -- crowds' money apart, which is fairer when fighters know things
        -- spectators do not. Only 'pool' bets ever enter it.
        sharedPool = true,

        -- THE ENTRY FEES JOIN THE POOL TOO. On, a fighter's entry fee IS a
        -- bet on their own side, there is one prize, and a fighter who wins
        -- always profits because the pool holds every loser's fee.
        --
        -- Off, the entry pot is paid separately by Config.Betting.payout and
        -- the bets settle on their own -- two prizes for two different things.
        includeEntryPot = true,
    },

    fighterBets = {
        enabled = true,

        -- The band one fighter may stake. Nothing to do with the entry fee.
        --
        -- KEEP `max` LEVEL WITH `spectatorBets.max`. A fighter who leaves a
        -- live round has their stake trimmed to the watcher ceiling and the
        -- difference handed back, so anything above that line is a stake they
        -- can take off the table by walking out. Level, there is nothing to
        -- trim and nothing to gain by leaving.
        min = 100,
        max = 25000,

        -- A fighter may only back THEMSELVES, or their own side. Off, they
        -- may back anybody, which is a way to throw a round for money.
        ownSideOnly = true,

        -- One bet each. Off, a fighter may keep adding to their position
        -- while the lobby is open.
        oneBetPerMatch = true,

        -- WHEN THE BOOK SHUTS FOR A FIGHTER: the moment the round goes live,
        -- and there is no setting for it. `spectatorBets.closeAfterStartSeconds`
        -- below keeps the book open a little way into a live round, and that
        -- grace is for WATCHERS only -- a fighter betting on themselves
        -- thirty seconds in would be betting on a round they can already see
        -- the shape of, at a fighter's ceiling, having banked the first kills.
    },
    currencySymbol = '$',

    -- THE ENTRY FEE each player stakes to take part.
    entryFee = {
        -- With this off, matches are free to enter and the pot is only ever
        -- filled by spectator side-bets (if those are on).
        enabled = true,
        min = 0,
        max = 50000,
        -- WHAT THE BOX STARTS ON -- what a host who never touches it opens
        -- the round at. A host who wants a free round types 0.
        default = 500,
        -- Quick-pick buttons in the panel. Any value between min and max is
        -- still accepted if the player types it.
        presets = { 500, 1000, 5000, 25000 },
    },

    -- Taken off the top of the pot before it is paid out. 0 = no cut.
    --
    -- ONLY WHEN THE POT SETTLES ON ITS OWN. `betPayout.includeEntryPot` ships
    -- ON, which hands the entry fees to the bet pool -- and a pool is the
    -- bettors' money, so nothing is raked off it. Set a cut with that switch
    -- on and none is taken; the console says so at start-up.
    houseCutPercent = 0,

    -- HOW THE POT IS SPLIT.
    --   'winner_takes_all' -- one player (or the winning team, split evenly)
    --   'per_kill'         -- divided by share of total kills
    payout = 'winner_takes_all',

    -- Below this head count the match still runs, but the pot is refunded
    -- rather than paid out -- stops two friends farming each other.
    --
    -- ONLY WHEN THE POT SETTLES ON ITS OWN, exactly like `houseCutPercent`
    -- above it. `betPayout.includeEntryPot` ships ON, which turns the entry
    -- fees into bets in the pool, and the pool has no head count to check --
    -- so on the shipped settings A TWO-PLAYER MATCH PAYS OUT IN FULL and
    -- this number is never read. The console says so at start-up. Turn
    -- includeEntryPot off for the guard to bite.
    minPlayersToPayOut = 2,

    -- 0 = no ceiling on the total pot.
    maxPot = 0,

    -- A HOST CLOSING THEIR OWN LOBBY. On, every stake goes straight back.
    -- Off, they are FORFEITED and the money goes nowhere -- there is no house
    -- account, and handing the pot to somebody would only move the abuse to
    -- them. That is the point: it deters a host who fills a lobby, takes
    -- everyone's stake and closes it. Every forfeit is logged and webhooked
    -- whatever `logPayouts` says.
    --
    -- ONLY a host cancelling forfeits. An idle close, an admin force-stop,
    -- the last player leaving and a resource restart all refund in full.
    refundOnCancel = true,

    -- LEAVING A LOBBY THAT HAS NOT STARTED. On, the stake comes back. Off,
    -- it stays in the pot for whoever wins.
    --
    -- Neither this nor the one below can tell a deliberate quit from a crash,
    -- and does not try: a rule that charged only real disconnects would take
    -- money from players whose game crashed and spare the ones who left on
    -- purpose.
    refundOnDisconnectBeforeStart = true,

    -- Someone who disconnects mid-match forfeits their stake to the pot.
    -- With this on they get it back instead.
    refundOnDisconnectDuringMatch = false,

    -- HOW OFTEN TO RETRY A REFUND THAT COULD NOT BE DELIVERED.
    --
    -- A refund needs the player to be ON the server, and the commonest reason
    -- a stake is being handed back is the commonest reason it cannot be: they
    -- crashed. So the debt is recorded against the CHARACTER and paid the
    -- next time this sweep sees them, which survives a reconnect.
    --
    -- Zero or below switches the sweep off, and an undeliverable refund is
    -- then logged and webhooked for an operator to settle by hand.
    refundRetrySeconds = 30,

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
-- UI -- the red/black panel.
-- ======================================================================
Config.UI = {
    title = 'CRIMSON',
    subtitle = 'ROLEPLAY ARENA',

    -- WHICH SHAPE OF LOGO YOU HAVE. Write one of:
    --
    --   'mark'   -- a small square badge left of the title. Right for a
    --               simple icon; it is drawn small, so anything with words in
    --               it is unreadable.
    --
    --   'banner' -- the logo spans the top and `title` and `subtitle` are NOT
    --               drawn. Right for a finished lockup that already has your
    --               server name in it.
    --
    -- A full-scene artwork will be small at panel size either way -- crop it
    -- down to the part that identifies you.
    logoStyle = 'mark',

    -- Drop your own logo in html/images/logo.png and it appears in the panel
    -- header. Change the FILENAME and you must add the new file to
    -- fxmanifest.lua's `files` block, or it silently will not load.
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
    -- ACE/ox_lib admin groups. This is the whole admin surface, not just the
    -- stop button: /arenaadmin (the tablet -- force-stop, wipe, the unpaid
    -- ledger, opening a player's stash by hand, and holding the arena's doors
    -- open past Config.Schedule) and /arenahours are both gated on it.
    adminGroups = { 'admin', 'god' },
    -- Anyone may join a match someone else created.
    joinJobs = {},
}

-- ======================================================================
-- ARENAS -- the grounds people actually fight on.
--
-- ADD AS MANY AS YOU LIKE. Paste another block in, give it a key nothing else
-- uses, and it appears in the panel at the next restart. No code, no second
-- list, no registration step. Delete a block and it is gone; set
-- `enabled = false` to hide it without losing the coordinates.
--
-- THE TWO SHIPPED ARENAS ARE DIFFERENT ANIMALS -- one a real place on the map
-- with its own cover, one built out of props a kilometre up with nothing
-- under it. Their coordinates are a starting point, not gospel: stand where
-- you want a spawn point, take the coordinates, paste them in. The heading is
-- the last number -- the way the player faces when they land.
--
-- COPY THIS TO ADD ONE:
--
--     ['pier'] = {
--         label = 'Del Perro Pier',
--         description = 'Whatever players see under the name in the panel.',
--         enabled = true,
--         -- ONE POINT AND A RADIUS, instead of a list of exact spawns.
--         --
--         -- Set this and the arena works the rest out: every player lands
--         -- somewhere random inside the circle, nobody closer to anybody
--         -- else than `minSeparation`, and in a team mode each team lands
--         -- together on its own side of it. `spawns` below is then unused.
--         --
--         -- Delete it, or set enabled = false, and the exact `spawns` list
--         -- is used exactly as before.
--         spawnArea = {
--             enabled = true,
--             center = vector3(x, y, z),      -- the middle of the circle
--             radius = 100.0,                 -- how far out players may land
--             minSeparation = 12.0,           -- never closer than this to another player
--             teamRadius = 25.0,              -- how tightly one team lands together
--         },
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
--             damagePerTick = 20,             -- per tick, through armour too
--             tickMs = 500,                   -- 40/second: dead in ~7.5s
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
    ['trailerpark'] = {
        label = 'Trailer Park',
        description = 'Close ground between the vans. Corners everywhere, nothing to see across.',
        enabled = true,

        -- ON REAL GROUND, unlike the skydome: there is a map under this one,
        -- so there is no `platform` block and no `exactSpawnZ` -- the game is
        -- asked where the ground is and players are put on it.

        -- COVER PROPS ARE OFF HERE, because the trailer park already has
        -- trailers, fences and vehicles to fight around. These offsets know
        -- nothing about what is already standing there, so switching them on
        -- can put a container through a caravan.
        --
        -- The layout is left ready for the one case it is worth having: turn
        -- `enabled` on, fly out, and nudge whatever landed somewhere silly.
        -- Offsets are from the spawn-area centre below, so `z = 0` is ground
        -- level in the middle of the arena. Nobody is ever placed
        -- ONTO these, so a piece sitting slightly proud is untidy rather
        -- than a fall.
        cover = {
            enabled = false,
            pieces = {
                -- AN OUTER RING with gaps to run through, turned side-on so
                -- the long face is what you take cover behind.
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = 26.0, y = 0.0, z = 0.0, heading = 90.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = 18.4, y = 18.4, z = 0.0, heading = 135.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = 0.0, y = 26.0, z = 0.0, heading = 180.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = -18.4, y = 18.4, z = 0.0, heading = 225.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = -26.0, y = 0.0, z = 0.0, heading = 270.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = -18.4, y = -18.4, z = 0.0, heading = 315.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = 0.0, y = -26.0, z = 0.0, heading = 0.0 },
                { models = { 'prop_container_01a', 'prop_container_01b', 'prop_conc_blocks01a' }, x = 18.4, y = -18.4, z = 0.0, heading = 45.0 },

                -- FOUR POCKETS, each open from one side only.
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 10.5, y = 10.5, z = 0.0, heading = 135.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = -10.5, y = 10.5, z = 0.0, heading = 225.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = -10.5, y = -10.5, z = 0.0, heading = 315.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 10.5, y = -10.5, z = 0.0, heading = 45.0 },

                -- THE MIDDLE: a pinwheel, so the centre can be crossed but
                -- is never open ground.
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 5.5, y = 0.0, z = 0.0, heading = 45.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 0.0, y = 5.5, z = 0.0, heading = 135.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = -5.5, y = 0.0, z = 0.0, heading = 225.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 0.0, y = -5.5, z = 0.0, heading = 315.0 },
            },
        },

        spawnArea = {
            enabled = true,
            -- The operator's own coordinates, and the middle of everything
            -- else in this block.
            center = vector3(2344.4294, 2565.0552, 46.6677),
            radius = 38.0,
            minSeparation = 10.0,
            teamRadius = 18.0,
        },

        -- Used only if spawnArea is switched off. Each heading points back
        -- towards the middle of the park. Note that a GTA heading of 90 is
        -- WEST, not east -- the commonest way to get these backwards.
        spawns = {
            vector4(2374.4294, 2565.0552, 46.6677, 90.0),
            vector4(2314.4294, 2565.0552, 46.6677, 270.0),
            vector4(2344.4294, 2595.0552, 46.6677, 180.0),
            vector4(2344.4294, 2535.0552, 46.6677, 0.0),
        },

        -- One list per side. A team with no list here falls back to `spawns`.
        teamSpawns = {
            crimson = {
                vector4(2374.4294, 2565.0552, 46.6677, 90.0),
                vector4(2374.4294, 2553.0552, 46.6677, 68.2),
            },
            ash = {
                vector4(2314.4294, 2565.0552, 46.6677, 270.0),
                vector4(2314.4294, 2577.0552, 46.6677, 248.2),
            },
        },

        boundary = {
            enabled = true,
            center = vector3(2344.4294, 2565.0552, 46.6677),
            -- BIG ENOUGH FOR THE WHOLE PARK. A hundred metres covers it end
            -- to end with room to back off, and stops short of the highway.
            -- Grows with the roster: 135m at the twenty-player ceiling.
            radius = 100.0,
            warningSeconds = 5,
            damagePerTick = 20,
            tickMs = 500,
        },

        -- ROOM FOR TWENTY, on ground that already exists.
        --
        -- Only the spawn ring and the boundary grow here -- there is no
        -- floor to build and the cover is off -- so this just spreads people
        -- further apart and gives them more of the park. The ceiling is lower
        -- than the skydome's, which has no fence or highway to run into.
        scale = {
            enabled = true,
            baseline = 6,
            perPlayer = 1.4,
            maxGrowth = 1.35,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },

    ['skydome'] = {
        label = 'The Skydome',
        description = 'A walled platform in the clouds, with nothing under it and nothing over it.',
        -- THE PROP MODELS BELOW ARE THE ONE THING HERE YOU CANNOT CHECK FROM
        -- OUTSIDE THE GAME. If a model is missing from your build the floor
        -- does not appear -- so the client REFUSES to put anybody into an
        -- arena whose floor did not build and says so in the console. Nobody
        -- falls; the match simply will not start.
        --
        -- Fly up to the coordinates below once and look. You are checking
        -- that the floor is solid and that `spawnArea.center.z` is standing
        -- height on it.
        enabled = true,

        -- THE FLOOR.
        platform = {
            enabled = true,

            -- TRIED IN ORDER: the first model this build actually has is
            -- used, and the console says which if it was not the first.
            --
            -- The first four are the same big flat slab from four different
            -- DLCs. The fifth is a base-game shipping container, which every
            -- build has -- it tiles into a floor perfectly well, it just
            -- takes a few hundred pieces, which is what `maxTiles` is for.
            models = {
                'stt_prop_stunt_bblock_huge_01',
                'bkr_prop_biker_bblock_huge_01',
                'imp_prop_impexp_bblock_huge_01',
                'ar_prop_ar_bblock_huge_01',
                'prop_container_01a',
            },

            -- A FALLBACK ONLY. The client measures the model's real
            -- footprint and lays the floor out on that; this is used only if
            -- the model will not load at all.
            tileSize = 10.0,

            -- How far the floor reaches. Keep it inside the boundary, so the
            -- edge of the world is the edge of the floor rather than open air
            -- you can stand in while bleeding.
            --
            -- IT HAS TO CARRY THE WALL, which is why it is 48 and not 45: the
            -- wall stands at 44.5 and a container is 2.44m across, so the
            -- extra margin puts whole tiles under every corner of it at every
            -- size the arena grows to.
            radius = 48.0,

            -- THE SURFACE PEOPLE STAND ON -- not where the pieces are
            -- created. The client measures the prop and lowers it by its own
            -- height so the TOP lands exactly here, whichever model this
            -- build turned out to have.
            --
            -- This has to agree with `spawnArea` and `cover` below; all three
            -- are 1201.
            z = 1201.0,

            -- A CEILING ON THE PIECE COUNT. It only bites on the container
            -- fallback -- a big slab tiles this arena in nine pieces. The
            -- middle is kept and the rim is dropped, so a capped floor loses
            -- edge nobody spawns on rather than opening a hole. 0 = no ceiling.
            maxTiles = 400,
        },

        -- SOMETHING TO GET BEHIND, AND SOMETHING TO STOP AT. Without cover a
        -- flat disc is a staring contest; without a wall it is a
        -- thousand-metre drop.
        --
        -- Positions are OFFSETS from the spawn-area centre, so `z = 0` is
        -- standing on the floor. Add, delete and move these freely.
        --
        -- `z` IS THE ONE OFFSET THAT DOES NOT SCALE with the arena, because a
        -- container is 2.6m tall whatever size the floor is. That is what
        -- makes a stack a stack: a piece at `z = 2.6` stands on the roof of
        -- the one at `z = 0` at every roster size.
        --
        -- `align = 'tangent'` TURNS A PIECE SIDE-ON TO THE MIDDLE and
        -- overrides the heading beside it -- the client measures the model to
        -- work out which heading really does that. The written heading is the
        -- fallback for a model it cannot measure.
        cover = {
            enabled = true,
            pieces = {
                -- THE WALL. Twenty-two containers around the rim, every one
                -- doubled: 5.2m of steel, not climbable and not something
                -- anybody walks off by accident. Nothing goes over the top --
                -- the sky stays open.
                --
                -- THE COUNT AND THE RADIUS GO TOGETHER. A container is 12.19m
                -- long, so twenty-two of them make a ring whose edges are a
                -- little longer than one piece: fewer and the inside corners
                -- drive through each other, more and gaps open up. Change one
                -- of these two numbers and you have to change the other.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 44.5, y = 0.0, z = 0.0, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 44.5, y = 0.0, z = 2.6, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = 12.5, z = 0.0, heading = 106.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = 12.5, z = 2.6, heading = 106.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = 24.1, z = 0.0, heading = 122.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = 24.1, z = 2.6, heading = 122.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = 33.6, z = 0.0, heading = 139.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = 33.6, z = 2.6, heading = 139.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = 40.5, z = 0.0, heading = 155.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = 40.5, z = 2.6, heading = 155.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = 44.0, z = 0.0, heading = 171.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = 44.0, z = 2.6, heading = 171.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = 44.0, z = 0.0, heading = 188.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = 44.0, z = 2.6, heading = 188.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = 40.5, z = 0.0, heading = 204.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = 40.5, z = 2.6, heading = 204.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = 33.6, z = 0.0, heading = 220.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = 33.6, z = 2.6, heading = 220.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = 24.1, z = 0.0, heading = 237.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = 24.1, z = 2.6, heading = 237.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = 12.5, z = 0.0, heading = 253.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = 12.5, z = 2.6, heading = 253.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -44.5, y = 0.0, z = 0.0, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -44.5, y = 0.0, z = 2.6, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = -12.5, z = 0.0, heading = 286.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = -12.5, z = 2.6, heading = 286.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = -24.1, z = 0.0, heading = 302.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = -24.1, z = 2.6, heading = 302.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = -33.6, z = 0.0, heading = 319.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = -33.6, z = 2.6, heading = 319.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = -40.5, z = 0.0, heading = 335.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = -40.5, z = 2.6, heading = 335.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = -44.0, z = 0.0, heading = 351.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = -44.0, z = 2.6, heading = 351.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = -44.0, z = 0.0, heading = 8.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = -44.0, z = 2.6, heading = 8.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = -40.5, z = 0.0, heading = 24.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = -40.5, z = 2.6, heading = 24.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = -33.6, z = 0.0, heading = 40.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = -33.6, z = 2.6, heading = 40.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = -24.1, z = 0.0, heading = 57.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = -24.1, z = 2.6, heading = 57.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = -12.5, z = 0.0, heading = 73.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = -12.5, z = 2.6, heading = 73.7, align = 'tangent' },

                -- THE OUTER RING: containers side-on to the middle with gaps
                -- between them to run through, rather than a second wall.
                --
                -- ALL EIGHT SIDE-ON NOW. Four of these were end-on to the
                -- middle and nobody noticed, because eight pieces twenty metres
                -- apart read as a ring whichever way each one is turned. They
                -- are marked to be turned by measurement instead of by hand.
                --
                -- Four of the eight are doubled, which costs the placement
                -- nothing -- a stacked piece stands in the same footprint as
                -- the one under it -- and makes the ring something to be behind
                -- rather than something to shoot over.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 28.0, y = 0.0, z = 0.0, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 28.0, y = 0.0, z = 2.6, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 19.8, y = 19.8, z = 0.0, heading = 135.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = 28.0, z = 0.0, heading = 180.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = 28.0, z = 2.6, heading = 180.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -19.8, y = 19.8, z = 0.0, heading = 225.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -28.0, y = 0.0, z = 0.0, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -28.0, y = 0.0, z = 2.6, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -19.8, y = -19.8, z = 0.0, heading = 315.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = -28.0, z = 0.0, heading = 0.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = -28.0, z = 2.6, heading = 0.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 19.8, y = -19.8, z = 0.0, heading = 45.0, align = 'tangent' },

                -- THE MID BAND: eight more, sat in the outer ring's GAPS
                -- rather than lined up behind it -- lined up, every gap is a
                -- firing lane down the whole diameter. Skewed 20 degrees off
                -- side-on so the arena does not read as concentric circles.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 20.8, y = 12.0, z = 0.0, heading = 220.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.2, y = 23.2, z = 0.0, heading = 175.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -12.0, y = 20.8, z = 0.0, heading = 130.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -23.2, y = 6.2, z = 0.0, heading = 85.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -20.8, y = -12.0, z = 0.0, heading = 40.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.2, y = -23.2, z = 0.0, heading = 355.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 12.0, y = -20.8, z = 0.0, heading = 310.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 23.2, y = -6.2, z = 0.0, heading = 265.0 },

                -- FOUR CORNERS, each a long wall and a short return. A pocket
                -- you can hold, open from one side only. Both pieces are turned
                -- off square so the four pockets do not all face the same way.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 11.3, y = 11.3, z = 0.0, heading = 245.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 6.7, y = 15.9, z = 0.0, heading = 285.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -11.3, y = 11.3, z = 0.0, heading = 155.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = -15.9, y = 6.7, z = 0.0, heading = 195.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -11.3, y = -11.3, z = 0.0, heading = 65.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = -6.7, y = -15.9, z = 0.0, heading = 105.0 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 11.3, y = -11.3, z = 0.0, heading = 335.0 },
                { models = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }, x = 15.9, y = -6.7, z = 0.0, heading = 15.0 },

                -- THE MIDDLE: four containers in a pinwheel, turned 30
                -- degrees off side-on and two of them doubled. The centre can
                -- be crossed but is never open ground and never a straight run.
                --
                -- BE CAREFUL ADDING PIECES HERE. Every FOOTPRINT is kept 7m
                -- clear of every spawn, so a new piece in the middle is room
                -- taken away from placing fighters -- while a piece STACKED on
                -- one already there costs nothing. That is why this arena can
                -- be walled in and doubled up and still place eight fighters
                -- ten metres apart.
                --
                -- A DENSER LAYOUT WAS TRIED AND TAKEN BACK OUT: it looked fine
                -- and then put six fighters 6.23m apart against a stated 10.
                -- Adding footprints is cheap to write and expensive to check.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 8.3, y = 3.4, z = 0.0, heading = 277.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 8.3, y = 3.4, z = 2.6, heading = 277.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -3.4, y = 8.3, z = 0.0, heading = 187.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -8.3, y = -3.4, z = 0.0, heading = 97.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -8.3, y = -3.4, z = 2.6, heading = 97.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 3.4, y = -8.3, z = 0.0, heading = 7.7 },
            },
        },

        -- THE ARENA GROWS WITH THE MATCH. The radii below are written for a
        -- small round; twenty fighters in the same circle would open the game
        -- already in each other's sights.
        --
        -- ONE NUMBER SCALES ALL OF IT -- spawn area, floor, boundary and
        -- where the cover sits -- so the relationships between them, which
        -- are what stop people spawning off the floor or out of bounds, stay
        -- intact.
        --
        -- The floor is tiled, so a bigger arena is more pieces and `maxTiles`
        -- above grows with it.
        scale = {
            enabled = true,

            -- The roster the radii below are written for. At or under this,
            -- nothing changes and the arena is exactly as configured.
            baseline = 6,

            -- Metres of spawn radius added per fighter above the baseline.
            -- At 1.6: six players fight in the 35m circle below, twenty fight
            -- in a 57m one, and the floor and boundary grow with it.
            perPlayer = 1.6,

            -- However many turn up, it never grows past this multiple of
            -- the configured size. A ceiling, not a target.
            maxGrowth = 2.0,
        },

        -- THE SPAWN Z IS EXACT HERE. Without this the client asks the game
        -- where the ground is, gets the real terrain a kilometre below, and
        -- every fighter drops out of the sky when the round starts.
        exactSpawnZ = true,

        spawnArea = {
            enabled = true,
            -- A floor for the client to raise fighters to. It measures the
            -- real surface off the prop and uses that when it is higher, so
            -- this only has to be at or below standing height.
            center = vector3(1500.00, 3000.00, 1201.00),
            radius = 35.0,
            minSeparation = 10.0,
            teamRadius = 16.0,
        },

        -- The fallback list, used only if spawnArea is switched off.
        --
        -- TWO THINGS TO GET RIGHT IF YOU MOVE THESE. A GTA heading is degrees
        -- clockwise from north, so 90 is WEST -- reading it as east puts a
        -- fighter's back to the arena. And each point must stand in a GAP in
        -- the cover ring, not against it: these four are 10.28m from the
        -- nearest piece, which clears the 7m requirement and the 2.5m scatter.
        spawns = {
            vector4(1531.56, 3009.65, 1201.00, 107.0),
            vector4(1490.35, 3031.56, 1201.00, 197.0),
            vector4(1468.44, 2990.35, 1201.00, 287.0),
            vector4(1509.65, 2968.44, 1201.00, 17.0),
        },

        -- Each side gets two adjacent gaps, and the sides are opposite each
        -- other across the arena.
        teamSpawns = {
            crimson = {
                vector4(1515.49, 3029.14, 1201.00, 152.0),
                vector4(1490.35, 3031.56, 1201.00, 197.0),
            },
            ash = {
                vector4(1484.51, 2970.86, 1201.00, 332.0),
                vector4(1509.65, 2968.44, 1201.00, 17.0),
            },
        },

        -- A SPHERE, which is what makes the drop lethal without a line of
        -- falling code: step off the floor and you are outside the boundary
        -- from underneath within a second.
        --
        -- IT HAS TO CONTAIN THE WHOLE FLOOR, or players bleed while still
        -- standing on solid platform. The floor is TILED, so it reaches
        -- further than `platform.radius` -- a tile is kept whenever any part
        -- of it falls inside. The console complains at start-up if a boundary
        -- is smaller than the floor drawn inside it.
        boundary = {
            enabled = true,
            center = vector3(1500.00, 3000.00, 1201.00),
            radius = 110.0,
            warningSeconds = 5,
            damagePerTick = 20,
            tickMs = 500,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },
}

-- ======================================================================
-- LOADOUTS -- THE RULES THE WEAPON PICKER IS BUILT UNDER.
--
-- THE WEAPONS THEMSELVES ARE IN config.weapons.lua. Delete an entry there,
-- or set `enabled = false` on one, and that weapon is gone from the arena
-- for everyone -- the server refuses it even if a modified client asks for it
-- by name. What is in THIS block is how many a player may take, what
-- ammunition they arrive with, and the spare kit they carry in.
--
-- AMMO: each weapon carries its own `ammo` block. `options` is what the
-- player may pick from in the panel; `max` is the hard ceiling the server
-- clamps to whatever arrives on the wire.
--
-- A WEAPON WITH NO `ammo.options` HAS NO PICKER, and its count is then only
-- bounded by `max` -- with no list to check against, a modified client asking
-- for a number below the ceiling is given it. Set `max = default`, the way
-- every melee entry does, for a weapon whose count is meant to be fixed.
-- ======================================================================
Config.Loadouts = {
    -- WHO PICKS THE WEAPONS. This decides whether a round is a test of skill
    -- or a test of who picked the better gun. Write one of:
    --
    --   'host'   -- the host picks once and everybody fights with it, so the
    --               only variable left is the players. The picker is
    --               read-only for everyone else and the server refuses their
    --               request as well. A late joiner inherits the choice.
    --
    --   'player' -- everybody picks their own.
    chooser = 'host',

    -- HOW MANY WEAPONS one player carries -- guns and blades TOGETHER, in
    -- one count. Four rifles, four bats, three and a knife: the mix is the
    -- player's, and only the total is enforced.
    --
    -- Raise it for loadout-style play. Drop it to 1 for a duel server.
    -- 0 MEANS NO LIMIT, the same as every other count in this file.
    slots = 4,

    -- SWITCH A WHOLE KIND OFF. The weapons stay in config.weapons.lua ready
    -- to switch back on, and the picker drops the section rather than showing
    -- it empty.
    --
    --   allowFirearms = false  a melee-only arena -- bats and knives
    --   allowMelee = false     a firearms-only arena
    --
    -- Both false means nobody carries anything, and the console says so at
    -- start rather than running a round of unarmed players.
    --
    -- THESE ARE ABOUT WHAT A PLAYER MAY PICK. A mode that issues its own kit
    -- is not picking, so a gun game still opens on a blade.
    --
    -- MIND WHAT COUNTS AS MELEE: any weapon whose `ammo.max` is 1 or absent
    -- is treated as melee whatever category it is filed under -- a weapon
    -- that holds one round is a club as far as this is concerned. With
    -- allowMelee off, a single-shot weapon you added silently disappears.
    allowFirearms = true,
    allowMelee = true,

    -- Purely for grouping the picker into tabs. A weapon whose `category`
    -- is not listed here still shows, under 'Other'.
    categories = {
        { key = 'sidearm', label = 'Sidearms', order = 1 },
        { key = 'automatic', label = 'Automatics', order = 2 },
        { key = 'shotgun', label = 'Shotguns', order = 3 },
        { key = 'precision', label = 'Precision', order = 4 },
        { key = 'heavy', label = 'Heavy', order = 5 },
        { key = 'melee', label = 'Melee', order = 6 },
    },

    -- THE WEAPON LIST IS IN ITS OWN FILE: config.weapons.lua, loaded straight
    -- after this one. How to add, remove or disable a weapon is documented at
    -- the top of it.


    -- ==================================================================
    -- THE DOOR -- what a player may bring in, and what leaves with them.
    --
    -- NOBODY BRINGS THEIR OWN KIT INTO THE ARENA. On the way in a player's
    -- whole inventory goes into a private stash and they carry only what the
    -- arena issued. On the way out everything on them is destroyed -- issued,
    -- looted, picked up off the floor -- and their own is handed back. So no
    -- amount of dying, looting or hoarding changes what anybody walks out
    -- with.
    --
    -- WHERE IT ACTUALLY GOES: an ox_inventory STASH, one per character, which
    -- ox_inventory persists itself. Not a table in this resource's memory,
    -- which a crash would take with it.
    --
    -- IF ANYTHING GOES WRONG PUTTING IT AWAY the arena does NOT strip them --
    -- they fight carrying their own gear, which is a worse match and a
    -- fixable one.
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

        -- WHAT STAYS IN A PLAYER'S POCKETS ON THE WAY IN, instead of going
        -- into the stash. Empty, and it should stay that way.
        --
        -- DO NOT PUT ANYTHING VALUABLE HERE. An item named here is carried
        -- through the whole round, and ox_inventory empties a dead player's
        -- pockets onto the floor. They will die, it will drop, and the arena
        -- refuses to let anybody pick things up mid-round -- including its
        -- owner -- so it stays there and the round ends around it.
        --
        -- A phone, a radio, a key, cash: leave them OFF this list. Off it
        -- they go into the stash and come back at the exit, which is the only
        -- place in a round anything is actually safe. Cash is protected at
        -- the other end by `neverDestroy` below, which is a different
        -- question with a different answer.
        --
        -- ARENA ITEMS ARE IGNORED HERE. Name a weapon, an ammunition item or
        -- a supply and it is stashed and returned like anything else, with a
        -- line in the console saying so -- otherwise fighters would walk out
        -- with the kit they were issued, every round, for ever.
        neverStash = {},

        -- WHAT THE EXIT'S CLEAR MUST NOT DESTROY.
        --
        -- The exit wipes whatever a player is carrying, because at that
        -- moment it all belongs to the arena -- their own is in the stash.
        -- The one hole in that is the PAYOUT: the pot is settled before
        -- anybody is sent home, so a cash win would be credited and then
        -- destroyed a few lines later.
        --
        -- Add any other item your server treats as currency. Names are
        -- ox_inventory item names.
        neverDestroy = { 'money', 'black_money' },

        -- REFUSE TO LET PLAYERS MOVE ANYTHING IN OR OUT OF THEIR POCKETS
        -- during a match -- a round is fought with what the round issued.
        --
        -- OUT, because a dropped item becomes its own container in the world
        -- and finding them all again afterwards is guesswork.
        --
        -- AND IN, WHICH MATTERS MOST IN A ROUND WITH RESPAWNS: ox_inventory
        -- drops a dead player's inventory on the floor, so without this a
        -- fighter could loot the whole arena kit off every body. The same
        -- rule covers a stash, a vehicle boot and another player's inventory.
        --
        -- Nothing the ARENA hands over is affected -- every issue, top-up,
        -- kill reward and stash return is a server-side write.
        blockDropsInArena = true,

        -- How often, in seconds, the server checks for belongings it still
        -- owes somebody and hands them over.
        --
        -- Giving an inventory back can fail for ordinary reasons -- full
        -- pockets, over the weight limit, disconnected mid-round -- and when
        -- it does, the things stay safely in the stash. This empties it on
        -- its own once the reason goes away, and survives a reconnect and a
        -- restart.
        --
        -- 0 switches it off, and anything that would not go back then waits
        -- for an operator to open the stash by hand.
        returnRetrySeconds = 30,
    },

    -- ==================================================================
    -- AMMO ITEMS -- real ox_inventory items, one per round.
    --
    -- Every weapon in config.weapons.lua already names the ammo item it
    -- fires, read out of that weapon's own `ammoname` in ox_inventory. A
    -- player never chooses a TYPE: they pick an AMOUNT, and the server hands
    -- them that many of the round their weapon takes. Asking for a different
    -- round is ignored rather than refused -- a pistol asking for .50 BMG
    -- gets 9mm.
    --
    -- GETTING IT BACK IS NOT THIS BLOCK'S JOB. The door above already covers
    -- it: everything a player carries is destroyed at the exit, so arena
    -- ammunition cannot leave the arena.
    -- ==================================================================
    ammoItems = {
        -- THE AMOUNT A PLAYER PICKS IS A TOTAL: one magazine loaded in the
        -- gun and the remainder as items they can see and reload from.
        --
        -- WHERE THE SPLIT FALLS is the weapon's own `magazine`, or failing
        -- that the smallest number in its `ammo.options`. A pistol offering
        -- 30/60/120 picked at 60 arrives with 30 loaded and 30 spare; picked
        -- at 30 it arrives with 30 loaded and nothing spare.
        --
        -- OFF does not remove the ammunition -- rounds then travel in the
        -- weapon's own metadata, the way ox_inventory carries them when there
        -- is no separate item. It removes the ITEMS.
        enabled = true,


        -- How many rounds one item is worth. With ox_inventory's usual
        -- per-round ammo items this is 1 and a player picking 60 rounds is
        -- given 60 items. If one item on your server is a box of 30, put 30
        -- here and they get 2.
        roundsPerItem = 1,

        -- What a weapon starts loaded with when it names no `magazine` AND
        -- has no `ammo.options` -- so only a weapon added without either.
        -- Never more than the player picked: it is a ceiling, not a handout.
        defaultMagazine = 30,

        -- Give the weapon even when its spare rounds could not be handed
        -- over -- a full inventory, or an item name this server lacks.
        --
        -- ON:  they fight with the magazine and no reloads rather than being
        --      refused the weapon. The failure is in the console either way.
        -- OFF: that one WEAPON is taken back. They keep their place in the
        --      round and everything else they picked.
        --
        -- A weapon picked at or under one magazine has no spare rounds to
        -- issue, so neither branch is reached -- that gun is already carrying
        -- every round the player asked for.
        allowWeaponWithoutAmmoItem = true,
    },

    -- LETTING A PLAYER TYPE THEIR OWN AMOUNT. On, the ammo row gets a box
    -- next to the presets and a player may ask for any number up to that
    -- weapon's `max`, which the server still enforces -- this widens what
    -- may be ASKED for and moves no limit.
    --
    -- Off, an off-list request falls back to that weapon's default rather
    -- than being rounded up.
    --
    -- Per weapon too: give one its own `allowCustomAmmo = false` to pin it to
    -- its presets while the rest stay free.
    allowCustomAmmo = true,

    -- Which type a player gets when they express no preference.
    defaultAmmoType = 'standard',

    -- How many DIFFERENT ammo types one player may carry across their whole
    -- loadout. 0 is no limit. Somebody over it is not refused the weapon --
    -- they get that weapon's default round instead.
    ammoTypeSlots = 0,

    -- THE FALLBACK AMMO TYPE, used only by a weapon added without an
    -- `ammoTypes` list of its own. Every weapon that ships names its own
    -- item, so nothing in the shipped catalogue reaches this.
    --
    -- The keys of an entry are:
    --   key       -- what the panel and the wire use; unique within a list.
    --   label     -- what the player reads.
    --   item      -- YOUR ox_inventory item name. This is the one to edit.
    --   component -- optional, and only meaningful on MK II weapons, whose
    --                special magazines are components rather than items.
    --   enabled   -- false hides it without deleting it.
    --
    -- IT MUST NAME AN ITEM THIS SERVER REALLY HAS. Offering a round the
    -- inventory cannot produce is the quietest kind of broken.
    defaultAmmoTypes = {
        { key = 'standard', label = '5.56x45', item = 'ammo-rifle' },
    },

    -- ==================================================================
    -- EXTRA SUPPLIES -- what a player carries IN, on top of the kit.
    --
    -- NOT THE STARTING ARMOUR. Every player starts every life on full health
    -- and a full plate, always, and nothing here reaches that.
    --
    -- This is the SPARE: a second plate for when the first is gone, a bandage
    -- to patch up behind cover. Real ox_inventory items, issued at the start
    -- of the round and taken back at the exit, so nobody walks out of a match
    -- holding free plates.
    -- ==================================================================
    supplies = {
        -- Off, the whole section is hidden and nobody carries any. Players
        -- still start on full health and a full plate: that is a rule, and
        -- this switch does not reach it.
        enabled = true,

        -- Whether the PLAYER picks the amounts. Off, everybody carries the
        -- `default` on each entry below -- which is how an operator sets one
        -- kit for the whole server.
        allowChoose = true,

        -- A ceiling across ALL supplies together, not per entry. `0` means
        -- no ceiling, so the per-item numbers below are the only limit --
        -- which is what ships, so adding a third supply is bounded by its own
        -- `max` rather than being squeezed by a total nobody remembered.
        --
        -- Set it, and it binds three things at once: what a player picks,
        -- what a mode's `startingKit` hands out, and what ONE KILL pays
        -- through `killReward` (per payment, not per round).
        --
        -- The real ceiling is then ox_inventory's own weight limit, which
        -- refuses what will not fit and says so in the console.
        totalItems = 0,

        -- THE ITEM NAMES MUST EXIST IN YOUR ox_inventory DATA. `armour` and
        -- `bandage` are the QB/ox defaults. A name that does not exist is
        -- refused by ox_inventory and named once in the console; it does not
        -- fail the round.
        items = {
            {
                key = 'armour',
                label = 'Body Armour',
                item = 'armour',
                -- The most one player may carry in.
                max = 25,
                -- What somebody who picks nothing carries.
                default = 1,
                -- WHAT THE PICKER OFFERS, AND ALL IT OFFERS -- buttons, with
                -- no box to type a number into. `default` MUST be one of
                -- them, or the row opens with nothing lit and that amount is
                -- unreachable the moment the player touches it. The console
                -- says so at start-up.
                options = { 0, 1, 5, 10, 25 },
            },
            {
                key = 'bandage',
                label = 'Bandage',
                item = 'bandage',
                max = 30,
                default = 2,
                -- 2 is in the list because it is the default, per the rule
                -- above.
                options = { 0, 2, 5, 10, 20, 30 },
            },
        },
    },

    -- FULL HEALTH AND A FULL PLATE ON EVERY LIFE ARE A RULE, NOT A SETTING.
    -- Both numbers live in shared/arena.lua, where the panel and the server
    -- read the same one. A player's real health and armour are captured on
    -- the way in and handed back on the way out.
}

-- ======================================================================
-- DATABASE -- the all-time leaderboard, and nothing else.
--
-- SHIPPED OFF, so the install is drag and drop: no SQL to import, no table
-- to create, no database user to grant anything to.
--
-- WHAT YOU LOSE IS ONE THING: the leaderboard resets when the server
-- restarts. Wins, kills and earnings are still counted and shown during a
-- session; they are simply not written down. Matches, teams, weapons,
-- betting, escrow, payouts and refunds never touch the database.
--
-- TURNING IT ON is one word here and a restart. The table creates itself;
-- sql/install.sql is only for a database user not allowed to do that.
--
-- OFF MEANS OFF, INCLUDING THE DEPENDENCY -- oxmysql is not required, so the
-- resource starts on a server with no database at all. Switch this on
-- without oxmysql running and the console says so once and falls back to
-- counting this server run.
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
-- THIS BLOCK IS BUILT FOR A CUSTOM DISPATCH SCRIPT and nothing else. The
-- arena touches no game native on the way into a match or out of one.
--
-- THE ONE THING NO RESOURCE CAN DO: your dispatch script decides to send an
-- alert inside its own event handlers, and nothing in FiveM can reach into
-- another resource and cancel that. So the job here is to hand it the facts
-- it needs to decline, in whichever of three forms suits how it is written.
-- All three are live at once; use whichever is least work.
--
-- THE STRONGEST SETTING HERE IS `isolation`, which is why it is first. It
-- asks nobody to decline anything -- it puts the match in its own network
-- instance where other players' clients have nothing to see. Read that block
-- before the rest.
-- ======================================================================
Config.Dispatch = {
    -- THERE IS NO MASTER SWITCH AT THE TOP OF THIS BLOCK. Every switch sits
    -- with the thing it controls, and each form of `custom` is governed by
    -- whether you filled that form's own list in -- an empty list does
    -- nothing whatever any switch says.

    -- ==================================================================
    -- ROUTING BUCKET ISOLATION -- the layer that needs nothing from anybody
    --
    -- A routing bucket is a separate network instance: what happens inside
    -- one does not reach players outside it. So no OTHER player's client sees
    -- arena gunfire, arena bodies or arena entities, and a dispatch script
    -- running on a bystander's machine has nothing to report.
    --
    -- WHAT IT CANNOT DO, stated plainly: a bucket cannot hide a client from
    -- ITSELF. A dispatch script that polls the shooter's own machine, or an
    -- ambulance script whose death handler runs on the victim's own machine,
    -- is inside the bucket -- it is the fighter's own client -- and the alert
    -- it sends travels by ordinary event RPC, which buckets do not filter.
    -- The state bag, the events and the exports further down are what is left
    -- for that case.
    --
    -- It is worth having regardless: it keeps passers-by out of a live round,
    -- keeps arena gunfire from being heard across the map, keeps NPCs out,
    -- and is what lets two matches share one arena.
    -- ==================================================================
    isolation = {
        -- Off means every match is fought in the ordinary world, in front of
        -- everybody.
        enabled = true,

        -- ONE BUCKET PER MATCH, so two rounds running at once cannot see
        -- each other. Off, every match shares `firstBucket` -- still hidden
        -- from the rest of the server, but two arenas in one room.
        perMatch = true,

        -- The number allocated from, counting upwards. Bucket numbers are
        -- server-wide and shared with every other resource on the box, so
        -- change this if something you run already lives in this range.
        -- Bucket 0 is the ordinary world and is never allocated.
        firstBucket = 4210,

        -- Ambient NPCs and traffic inside an arena bucket. Off, so a round is
        -- fought in an empty world -- an NPC that does not exist cannot
        -- witness a firefight or be run over into somebody's report.
        populationEnabled = false,

        -- HOW STRICT THE BUCKET IS ABOUT ENTITIES CLIENTS CREATE.
        --   'relaxed'  -- clients may create entities. THE DEFAULT.
        --   'inactive' -- entities are not culled, and clients may create
        --                 them; the loosest of the three.
        --   'strict'   -- clients may not create entities at all.
        --
        -- 'strict' isolates hardest and is NOT the default on purpose:
        -- weapons and props handed out mid-match are created BY the receiving
        -- client, and a strict bucket refuses them -- the player arrives
        -- empty-handed with nothing on screen saying why. Only use 'strict'
        -- if you have tested that loadouts still arrive on your build.
        lockdownMode = 'relaxed',
    },

    -- ==================================================================
    -- THE DOWN FLAG -- the one layer here that acts at the moment it matters
    --
    -- The QB-family medical scripts keep "this player is down" as PLAYER
    -- METADATA on the framework object, which is qbx_core's data, so this
    -- resource can write it. A dispatch script polling that metadata raises
    -- its own down and dead alerts the moment it goes up -- no keypress and
    -- nothing anybody has to agree to -- so the arena puts it back down
    -- before the next poll. That is a write against a wall clock, not a race
    -- against another handler, so resource start order does not matter.
    --
    -- IT IS DONE AT THE DEATH, NOT AT THE REVIVE, because the revive is
    -- seven seconds later -- fourteen windows of a 500ms poll.
    --
    -- WHAT IT CANNOT DO: a medical script that sends its own alert from the
    -- VICTIM'S CLIENT, back to back with the flag it reads, leaves no gap for
    -- a server-side write to land in.
    -- ==================================================================
    downState = {
        -- The keys your medical script keeps the down state in. Empty the
        -- list to switch the whole thing off. A name nothing reads is
        -- harmless; a name that is WRONG for a script that does read it is
        -- not, so add one only if you have checked it.
        keys = { 'inlaststand', 'isdead' },

        -- How often the flags are put back down for everyone in a match, in
        -- ms. `0` clears once at the death and never again.
        --
        -- CLEARING ONCE IS NOT KEEPING CLEAR: medical scripts re-assert the
        -- flag on a respawn, on their own poll, on a restart. Keep this at
        -- about half the polling interval you are up against.
        holdIntervalMs = 250,
    },

    -- ==================================================================
    -- YOUR DISPATCH SCRIPT
    --
    -- FIVE FORMS. Three hand your script the same fact so it can decline the
    -- alert itself; a fourth tries to decline on its behalf; a fifth
    -- withdraws a call that was already filed.
    --
    -- FORMS 4 AND 5 ARE A PAIR -- 5 is reached only from inside 4. Of the
    -- first three, pick one; the others cost nothing.
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
        -- Both are SERVER events, never sent to a client -- who is allowed to
        -- be ignored is not a decision a client takes part in. Set either to
        -- nil to fire nothing.
        enterEvent = 'crimson_arena:dispatch:enter',
        exitEvent = 'crimson_arena:dispatch:exit',

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
        -- WRITTEN BY THE SERVER, NEVER THE CLIENT. A replicated bag set from
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
        -- Nothing ships here, because calling an export that means something
        -- different on your build is worse than not calling it. An entry
        -- naming a resource that is not running, or an export that does not
        -- exist, is skipped with one console warning -- it will not error and
        -- it will not stop a match starting.
        --
        -- The empty list IS the off switch; there is no separate `enabled`.
        disableExports = {},

        -- ---- FORM 4: THE LIST OF ALERTS THIS SERVER RAISES -----------------
        --
        -- IT IS NOT A SUPPRESSION LAYER. Listing an event here does not
        -- cancel it, and the startup report says as much. It earns its place
        -- for two other jobs:
        --
        --   IT IS THE ONLY WAY IN TO FORM 5. `retract` is reached from inside
        --   these handlers and nowhere else, so an event missing from this
        --   list is never withdrawn and never even logged.
        --
        --   IT IS THE ONLY THING THAT REPORTS. Each name prints once, the
        --   first time it fires, so you can tell an alert nobody is watching
        --   from one that is watched and declines.
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
        -- WHY IT IS ONLY BEST EFFORT. CancelEvent() raises a flag and stops
        -- nothing by itself: the alert still goes out unless the script that
        -- raised the event checks WasEventCanceled() afterwards, and many
        -- never do. A script that does check only sees the flag if this
        -- resource registered its handler first, which is decided by resource
        -- start order and is not something any resource can guarantee.
        --
        -- So treat a cancelled alert as a bonus, never as the thing keeping
        -- your dispatch quiet. `stateBagKey` above is one line pasted into
        -- the sending script and it always works.
        --
        -- IT WILL NOT GUESS. An event that arrives with no usable `source`
        -- and no `playerArg` is left alone and its name printed once, because
        -- cancelling a call about somebody on the other side of the map is
        -- far worse than failing to cancel one about a fighter.
        --
        -- Empty the list to switch it off.
        cancelEvents = {
            -- THESE SIX ARE THE EVENTS sc-dispatch AND sc-ambulance REALLY
            -- RAISE, read out of those two resources rather than guessed. If
            -- you run something else, replace the list.

            -- Gunfire, sent from the shooter's own machine.
            'sc-dispatch:server:ShotsFired',

            -- "10-52 Person Down", when a downed player asks for EMS.
            'hospital:server:EMSDownAlert',

            -- The default QBCore ambulance alert. Usually quiet on this box,
            -- and listed so that turning it back on cannot silently reopen
            -- the hole. It gets NO id template below and cannot have one --
            -- it broadcasts straight to on-duty medics and files no call, so
            -- there is nothing to withdraw.
            'hospital:server:ambulanceAlert',

            -- The second EMS entry point.
            'mydispatch:requestEMS',

            -- THE TWO THAT MATTER MOST, because nobody has to ask for them:
            -- sc-dispatch's own client polls the down metadata and raises
            -- these by itself the moment it goes up. A fighter who never
            -- presses a key still files a call.
            'sc-dispatch:server:PlayerDown',
            'sc-dispatch:server:PlayerDead',
        },

        -- ---- FORM 5: this resource WITHDRAWS the alert -------------------
        -- WHAT TO USE WHEN FORM 4 CANNOT WORK -- and against sc-dispatch, it
        -- cannot: it never checks the cancelled flag, so every name in the
        -- list above still creates its call.
        --
        -- Most dispatch scripts expose a "clear this call" export and build
        -- the call's id out of facts this resource can see. Name the export
        -- and the id shape, and an arena alert is withdrawn the moment it is
        -- created: the blip goes, the MDT row is marked inactive, and the
        -- call stops being dispatchable.
        --
        -- THE HONEST LIMIT: the alert is CREATED before it is withdrawn, so
        -- an officer on duty at that moment still hears the sound. What this
        -- stops is the call PERSISTING -- units driving out, a blip sitting
        -- on the map, a round's worth of calls stacking up in the MDT.
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
            -- handlers hang off the same event and nothing decides which runs
            -- first, so withdrawing a call before it exists clears nothing.
            -- This waits for the other handler to finish writing it. Raise it
            -- if calls still linger -- but every millisecond here is time the
            -- alert is live on an officer's screen.
            delayMs = 250,

            -- Seconds either side of the current clock to also withdraw. The
            -- id has a timestamp in it, so the two handlers can straddle a
            -- one-second boundary; this closes that gap. It cannot reach
            -- anybody else's call -- the server id in the middle is the arena
            -- player's own.
            clockSlack = 1,

            -- The id shape each event's call is filed under. The first '%d'
            -- is the player's server id, the second the unix timestamp.
            --
            -- An event with no entry here is cancelled (Form 4) but not
            -- withdrawn, which is the safe direction.
            --
            -- EVERY SHAPE BELOW WAS READ OUT OF THE SCRIPT THAT BUILDS IT.
            -- Do not add one you have not checked: a shape that is close but
            -- wrong clears nothing.
            idTemplates = {
                ['sc-dispatch:server:ShotsFired'] = 'shots_%d_%d',      -- :2544
                ['sc-dispatch:server:PlayerDown'] = 'playerdown_%d_%d', -- :2618
                ['sc-dispatch:server:PlayerDead'] = 'playerdead_%d_%d', -- :2645
                ['mydispatch:requestEMS'] = 'emshelp_%d_%d',            -- :2576

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
    -- TELLING YOUR AMBULANCE SCRIPT THEY ARE ALIVE -- two timings, and
    -- nothing else.
    --
    -- The arena stands its own players up, which is the whole job for the
    -- character model and none of it for your medical script -- that keeps
    -- its own record of who is dead, and nothing about standing a body up
    -- tells it anything. So a fighter would walk back to the lobby while
    -- that script still has them down.
    --
    -- YOU DO NOT NAME THAT SCRIPT HERE. The catalogue in
    -- shared/compat/dispatch.lua already knows which revive event each one
    -- listens for and fires it for whichever this box is running. A player
    -- who is still "dead" after a match means their script is missing from
    -- that catalogue, which is where to fix it.
    --
    -- It happens on every mid-match respawn as well as at the exit -- a
    -- player revived only at the end fights the rest of the round as a
    -- casualty.
    revive = {
        -- HOW LONG AFTER A RESPAWN THE MEDICAL SCRIPT IS TOLD, in ms.
        --
        -- The client needs a moment to be placed and standing before there is
        -- a living player for a revive to be about. Two seconds covers the
        -- teleport and the collision wait.
        --
        -- IT IS NOT WHAT KEEPS THE DISPATCH QUIET -- `downState` above does
        -- that, at the death itself. This only tells another script.
        afterRespawnDelayMs = 2000,

        -- A SECOND, BLANKET PASS over everybody who played, this many ms
        -- after the match ends. `0` switches it off.
        --
        -- Every exit path tells the medical script already; this covers the
        -- exit nobody has written yet. Runs once, when everybody is home.
        sweepAfterMatchMs = 5000,
    },

    -- ==================================================================
    -- THE "PERSON DOWN" ALERT, STOPPED AT SOURCE -- needs nothing from
    -- anybody.
    --
    -- Most medical scripts spot a casualty by watching whether a player is
    -- dead, once or twice a second. With this on, an arena death is reported
    -- and the body put back on its feet in the same instant -- frozen,
    -- invisible and untouchable until the server says whether they respawn or
    -- are out -- so that loop never sees a dead player. It also makes
    -- respawning feel sharper.
    --
    -- THE HONEST LIMIT: a script that hooks the death EVENT rather than
    -- polling the death STATE still fires, because the player really did die.
    -- Use `custom` above for those.
    -- ==================================================================
    clearDeadStateImmediately = true,
}
