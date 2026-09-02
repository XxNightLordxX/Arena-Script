--[[
    CRIMSON ARENA -- config.lua

    THE ONLY FILE YOU EDIT, and nothing in it needs code to go with it.
    Paste an arena in and it appears in the panel. Delete a weapon and it
    leaves the game. There is no second list to register anything with.

    THE FILE IS ORDERED BY HOW OFTEN YOU TOUCH IT: the settings first, then
    the two long lists -- arenas and weapons -- then the optional
    integrations most servers never open. The map below is the fast way in.

    ------------------------------------------------------------------------------
     line   setting       what it is
    ------------------------------------------------------------------------------
       73   Lobby         The NPC players walk up to
      144   Match         Lives, timers, player counts, win condition
      356   Teams         The sides, and whether they may be uneven
      458   Modes         Free-for-all, team deathmatch, gun game
      492   DefaultMode   Which of them a new lobby opens on
      511   Betting       Entry fees, self-bets, side-bets, how the pot is split
      706   UI            Panel colours, logo and title
      769   Permissions   Who may open a match, who may force-stop one
      848   Arenas        THE GROUNDS. One block per arena; paste one in, it appears
     1548   Loadouts      THE WEAPON AND AMMO LIST players choose from
     3095   Database      Optional: all-time leaderboard. Off, no SQL to import
     3105   Webhook       Optional: a Discord line per finished match
     3143   Dispatch      Optional: keeping police and EMS out of the arena
    ------------------------------------------------------------------------------

    (Those line numbers are checked by tests/configmap_spec.lua, so a map
    that has gone stale fails the suite instead of sending you to the wrong
    part of the file.)

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
        -- IN THE CITY, at the operator's own coordinates. Deliberately not
        -- inside a building: an interior puts the NPC behind a door players
        -- have to find, and interiors are their own can of worms once a match
        -- teleports people out of one.
        --
        -- The NPC and the ARENAS are separate settings. This is only where
        -- players come to join; the fights still happen wherever each entry
        -- in Config.Arenas puts them.
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
        -- The same spot as the NPC above: this is what goes up in its place
        -- when ox_target is not running, so the two must not drift apart.
        coords = vector3(-282.0125, -2030.4575, 30.1457),
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
    returnCoords = vector4(-282.0125, -2030.4575, 30.1457, 276.6953),
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
    -- RAISED FROM 1.0, because a metre was not clearing it.
    --
    -- Three metres is still not a skydive -- nobody watching learns where
    -- anybody spawned from it, which is the reason this is not simply set to
    -- fifty -- but it is enough head-room that a ped placed a moment before
    -- the ground finishes streaming falls onto terrain instead of through it.
    --
    -- This is the height a player is HELD at. It is not the height the ground
    -- is searched from: that is fixed, much higher, and explained where the
    -- probe happens in client/match.lua.
    --
    -- ON A GROUND ARENA NOBODY EVER SEES IT: the probe answers, and the
    -- player is put on the answer. On an arena that builds its own floor
    -- there is no probe to answer, so this is where they are really left and
    -- they fall it when the freeze drops -- at the end of the countdown on
    -- entry, and at once on a respawn. Worth turning down to a metre once a
    -- sky arena is confirmed solid underfoot; leave it here until then,
    -- because the failure it guards against is falling out of the world and
    -- the cost of it is a short drop.
    spawnHeightOffset = 3.0,

    -- THE RADAR, which replaced permanent blips.
    --
    -- Off for every player until they switch it on themselves in the panel,
    -- and even then it is not a live feed: it SWEEPS. Every `intervalMs` the
    -- fighters' positions appear for `visibleMs` and then go dark again, so
    -- what a player gets is where everybody WAS a moment ago, not where they
    -- are now. Long enough to plan, stale enough to be wrong about.
    --
    -- The two Config.Teams blip switches above override this: a server that
    -- wants permanent dots turns those on and the radar never runs.
    radar = {
        -- Whether the toggle appears in the panel at all. Off, nobody has a
        -- radar and the control is not drawn -- rather than drawn and dead.
        allowChoose = true,

        -- Whether a player who has never touched it starts with it on.
        defaultOn = false,

        -- How long between sweeps, and how long a sweep is visible for.
        -- 30 seconds dark, most of a second lit.
        intervalMs = 30000,
        visibleMs = 800,
    },

    -- KEEPING EVERYONE ELSE OUT OF A LIVE ARENA.
    --
    -- A live match is already fought in its own routing bucket, so an
    -- outsider cannot see the fighters, cannot shoot them and cannot be shot
    -- -- that half is settled and this adds nothing to it.
    --
    -- What this adds is the physical half: somebody who is not in the round
    -- is pushed back out of the arena's boundary circle and held there for as
    -- long as it is being fought in. Without it they can stand in the middle
    -- of a firefight nobody can see them in -- and on a server that has
    -- turned isolation off, in one they can be shot in.
    --
    -- The fence is the arena's own `boundary`, deliberately: the same circle
    -- the fighters are bled for leaving. One field, one edge.
    -- NOBODY SHOOTS ACROSS THE LINE, IN EITHER DIRECTION.
    --
    -- A player outside a round cannot hurt anyone in it, and a fighter
    -- cannot hurt anyone outside. Refused on the SERVER, from the damage
    -- packet itself, so it holds whatever the client believes.
    --
    -- The routing bucket already covers the ordinary case -- somebody
    -- outside the match is in another instance and cannot see or hit anyone
    -- in it. This is for the three cases it does not cover: a SPECTATOR,
    -- who is deliberately put in the match's own instance so they can watch
    -- and whose body is handed back the moment the camera stops; a server
    -- where isolation is not in force (buckets need OneSync, and an
    -- operator can switch them off); and the general principle that "nobody
    -- can shoot across this line" should not be a side effect of a
    -- networking setting.
    --
    -- Two people in DIFFERENT matches are as separate as a fighter and a
    -- passer-by, which is what makes one arena safe to run two rounds in.
    -- A player hurting THEMSELVES is never refused: a fall or your own
    -- grenade is not crossfire.
    --
    -- Off is the old behaviour: the bucket alone.
    crossfireGuard = {
        enabled = true,
    },

    keepOutBarrier = {
        enabled = true,

        -- How far OUTSIDE the boundary somebody is put when they cross it.
        -- Far enough that they are not immediately pushed again by the next
        -- tick, close enough that it reads as a wall and not a teleport.
        pushBackMetres = 6.0,

        -- How often the fence is checked, in milliseconds. A quarter second
        -- catches a sprint; every frame would be a loop running on every
        -- player on the server for the length of every round.
        tickMs = 250,

        -- Tell them why they were moved, once per crossing rather than once
        -- per tick.
        notify = true,
    },

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
    -- BOTH OFF. A permanent dot on every fighter turns a round into a map to
    -- be read rather than a place to be searched -- nobody flanks anybody
    -- when everybody's position is drawn continuously.
    --
    -- Config.Match.radar below is the replacement, and it is opt-in per
    -- player: a sweep that shows where everyone was for a moment and then
    -- goes dark again. Turn these back on for a server that wants the old
    -- permanent behaviour; they override the radar entirely.
    -- YOUR OWN SIDE, ALWAYS. Knowing where your team is is not intelligence
    -- -- it is the difference between a team mode and four people in the
    -- same field -- so teammates stay on the map for the whole round.
    showTeamBlips = true,

    -- THE OTHER SIDE, NEVER. A permanent dot on every enemy turns a round
    -- into a map to be read rather than a place to be searched. The radar
    -- below is how an enemy position is learned: opt-in, and a sweep that
    -- goes dark again. Turn this on for a server that wants the old
    -- permanent behaviour, and the radar stops running.
    showEnemyBlips = false,

    -- A COLOURED EDGE ROUND YOUR TEAMMATES, in that team's own colour --
    -- the same value the panel is tinted with and the same team the map
    -- blip belongs to, so the outline and the dot match by construction
    -- rather than by keeping two settings in step.
    --
    -- Teammates only, and it cannot be turned on for enemies: an outline
    -- draws THROUGH walls, which is the point of it for finding a friend
    -- and exactly the problem with it for finding a target.
    showTeamOutline = true,

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
        -- OFF. Switched off at the operator's request, not because anything
        -- about it is broken: the ladder below is intact and tested, and
        -- setting this back to true is the whole of turning the mode on.
        enabled = false,
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

    -- WHERE A STAKE IS TAKEN FROM, in the order tried.
    --
    -- One account was 'cash' and nothing else, so a player with the price in
    -- the bank and an empty pocket was told they could not afford it. Each is
    -- tried in turn for the WHOLE amount; a stake is never split across two.
    --
    -- Splitting has a failure mode nothing else here does: half the money
    -- leaves, the second half is refused, and the player is out of pocket for
    -- a stake that was never taken. Refunding a split is also two movements
    -- that can each fail on their own. One account or none is the honest
    -- trade, and it keeps a refund a single reversible movement.
    --
    -- Money always goes back where it came from. Refunding bank money as
    -- cash is a way to launder through the arena, and refunding cash into the
    -- bank is a surprise for somebody carrying it on purpose.
    accounts = { 'cash', 'bank' },

    -- FIGHTERS BACKING THEMSELVES.
    --
    -- Separate from the entry fee, which is one fixed price everybody pays.
    -- This is a real bet at whatever size the player chooses, on themselves
    -- in a free-for-all or on their own team in a team mode.
    --
    -- HOW A WINNING BET IS PAID, and it is the same question for both kinds.
    --
    --   'pool' -- PARIMUTUEL. Every bet on the match goes into a pool and the
    --             winners split it in PROPORTION TO WHAT THEY STAKED. A
    --             winner is paid with the losers' money, the sum handed out
    --             equals the pool exactly, and the server creates nothing. So
    --             what you win depends on how much you put in AND on how many
    --             people bet -- a big pool with one winner pays enormously, a
    --             small pool split four ways pays little.
    --
    --   'odds'  -- FIXED PRICE. The stake is multiplied by
    --             spectatorBets.oddsMultiplier below and paid by the server.
    --             Predictable, and it costs the server money on every win.
    --
    -- BOTH DEFAULT TO 'pool', because 'odds' on a bet placed by somebody who
    -- can influence the result is a money printer: a fighter backs themselves
    -- to win a round they were going to win anyway and the server pays for
    -- it. With 'pool' that same bet can only ever take money other bettors
    -- put up.
    -- NAMED betPayout, NOT `payout`. `Config.Betting.payout` already exists
    -- further down and is a different question entirely -- how the POT is
    -- split between the winners of the round. Calling this one `payout` too
    -- meant the second assignment silently replaced the first, so this whole
    -- block did nothing and every bet quietly fell back to the default. It
    -- was luacheck that noticed, not a test.
    betPayout = {
        fighters = 'pool',
        spectators = 'pool',

        -- ONE POOL FOR BOTH, or one each.
        --
        -- Shared, a spectator's stake can be won by a fighter and the other
        -- way round, which makes a small arena's pool worth betting into.
        -- Separate keeps the two crowds' money apart, which is fairer when
        -- fighters can see things spectators cannot.
        --
        -- Only ever pools bets that are actually on 'pool' -- an 'odds' bet
        -- is server-funded and never enters, or it would be paying itself
        -- out of other people's stakes as well.
        sharedPool = true,

        -- THE ENTRY FEES JOIN THE POOL TOO.
        --
        -- On, a fighter's entry fee IS their bet: it is added to the pool as
        -- a stake on their own side, so paying to enter puts you in rather
        -- than funding other people's bets for nothing. The pot is no longer
        -- paid out separately -- there is one pot and one set of winners.
        --
        -- What that guarantees: a fighter who wins always profits, because
        -- the pool holds every loser's fee as well as their own. Off, the
        -- entry pot is paid to the match winners by Config.Betting.payout
        -- below and the bets settle on their own, which is two prizes for
        -- two different things.
        includeEntryPot = true,
    },

    fighterBets = {
        enabled = true,

        -- The band one fighter may stake. Nothing to do with the entry fee.
        min = 100,
        max = 50000,

        -- A fighter may only back THEMSELVES, or their own team in a team
        -- mode. Off, they may back any side -- which on most servers is a
        -- way to throw a round for money, so it ships on.
        ownSideOnly = true,

        -- One bet each. Off, a fighter may keep adding to their position
        -- while the lobby is open.
        oneBetPerMatch = true,
    },
    currencySymbol = '$',

    -- THE ENTRY FEE each player stakes to take part.
    entryFee = {
        -- With this off, matches are free to enter and the pot is only ever
        -- filled by spectator side-bets (if those are on).
        enabled = true,
        min = 0,
        max = 50000,
        -- FREE UNLESS THE HOST ASKS FOR A FEE. Creating a match should not
        -- quietly put a price on it: a host who never touches the field
        -- opens a free round, and anybody who wants money on the outcome
        -- backs themselves with a fighter bet instead, which is voluntary,
        -- their own size, and paid out of the pool rather than by the server.
        default = 0,
        -- Quick-pick buttons in the panel. Any value between min and max is
        -- still accepted if the player types it.
        presets = { 500, 1000, 5000, 25000 },
    },

    -- Taken off the top of the pot before it is paid out. 0 = no cut.
    --
    -- ONLY WHEN THE POT SETTLES ON ITS OWN. `betPayout.includeEntryPot`
    -- below ships ON, which hands the entry fees to the bet pool instead --
    -- and a pool is the bettors' money, so nothing is raked off it. Set a
    -- cut with that switch on and none is taken; Arena.ValidateConfig says
    -- so on startup rather than leaving you to work it out from the
    -- payouts. Turn includeEntryPot off to rake the pot the old way.
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
    ['airfield'] = {
        label = 'Sandy Shores Airfield',
        description = 'Open tarmac. Nowhere to hide, long sightlines, rifles win.',
        -- OFF, at the operator's request: this server fights in the sky
        -- instead. Nothing here is deleted -- the coordinates, spawns, teams
        -- and boundary are all intact, so switching it back on is this one
        -- word.
        enabled = false,

        -- ONE POINT AND A RADIUS. Every player lands somewhere random
        -- inside this circle, no two closer than minSeparation, and in a
        -- team mode each team lands together on its own side of it.
        --
        -- Centred on this arena's own boundary and pulled inside it, so a
        -- spawn cannot put somebody out of bounds and bleeding before the
        -- round has started. Set enabled = false to use the exact `spawns`
        -- list below instead.
        spawnArea = {
            enabled = true,
            center = vector3(1722.00, 3270.00, 41.12),
            radius = 97.5,
            minSeparation = 12.0,
            teamRadius = 26.0,
        },

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
            -- LETHAL, AND QUICKLY. 20 twice a second is 40 a second, so a
            -- player who ignores the warning is dead in about seven and a
            -- half seconds from a full bar and a full plate.
            --
            -- It used to be 8 once a second, which is 35 seconds through
            -- health and armour -- long enough to walk out of the arena,
            -- take a look around and stroll back with most of a bar left.
            -- That is not a boundary, it is a suggestion.
            --
            -- Twice a second rather than once, too: the damage arrives as
            -- steady pressure a player can feel and react to, instead of
            -- four big unexplained hits.
            damagePerTick = 20,
            tickMs = 500,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },

    ['beach'] = {
        label = 'Vespucci Sands',
        description = 'Flat open sand at the waterline. No cover at all -- pure aim.',
        -- OFF, for the same reason as the airfield above. Intact, not
        -- deleted.
        enabled = false,

        -- ONE POINT AND A RADIUS. Every player lands somewhere random
        -- inside this circle, no two closer than minSeparation, and in a
        -- team mode each team lands together on its own side of it.
        --
        -- Centred on this arena's own boundary and pulled inside it, so a
        -- spawn cannot put somebody out of bounds and bleeding before the
        -- round has started. Set enabled = false to use the exact `spawns`
        -- list below instead.
        spawnArea = {
            enabled = true,
            center = vector3(-1255.00, -1507.00, 3.20),
            radius = 82.5,
            minSeparation = 12.0,
            teamRadius = 22.0,
        },

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
            -- LETHAL, AND QUICKLY. 20 twice a second is 40 a second, so a
            -- player who ignores the warning is dead in about seven and a
            -- half seconds from a full bar and a full plate.
            --
            -- It used to be 8 once a second, which is 35 seconds through
            -- health and armour -- long enough to walk out of the arena,
            -- take a look around and stroll back with most of a bar left.
            -- That is not a boundary, it is a suggestion.
            --
            -- Twice a second rather than once, too: the damage arrives as
            -- steady pressure a player can feel and react to, instead of
            -- four big unexplained hits.
            damagePerTick = 20,
            tickMs = 500,
        },

        weatherOverride = nil,
        timeOverride = nil,
    },

    -- ==================================================================
    -- AN ARENA IN THE SKY, for a map whose ground is all spoken for.
    --
    -- Nothing is up here, so this arena brings its own floor: one prop
    -- tiled into a disc, spawned when a fighter walks in and deleted when
    -- they walk out. It costs nothing while nobody is fighting.
    --
    -- ONE SKY ARENA SERVES EVERY MATCH AT ONCE, and that is worth being
    -- clear about because it looks like it should not. Every match is
    -- fought in its own routing bucket, so two matches at these exact
    -- coordinates cannot see, shoot or collide with each other -- they are
    -- in different instances of the world. There is no need for a second
    -- location, and no need to move anything when a match ends.
    --
    -- The floor is CLIENT-SIDE and local to each fighter: they each build
    -- their own copy at the same coordinates, so it is solid for all of
    -- them and invisible to everybody else on the server.
    -- ==================================================================
    ['trailerpark'] = {
        label = 'Trailer Park',
        description = 'Close ground between the vans. Corners everywhere, nothing to see across.',
        enabled = true,

        -- ON REAL GROUND, unlike the skydome. There is already a map under
        -- this one, so there is no `platform` block and no `exactSpawnZ`:
        -- the client asks the game where the ground is and puts people on
        -- it, which is what every arena did before the sky one existed.

        -- OFF, BECAUSE THIS ONE IS A REAL PLACE. The trailer park is on the
        -- map and already has trailers, fences and vehicles to fight around
        -- -- that is the reason to hold a match here. Dropping shipping
        -- containers on top of it at fixed offsets does not add cover, it
        -- puts a container through somebody's caravan: these coordinates are
        -- relative to the middle of the arena and know nothing about what is
        -- already standing there.
        --
        -- The skydome needs this because it is built over open air and has
        -- nothing of its own. This does not.
        --
        -- IT IS LEFT HERE, LAID OUT AND READY, for the one case it is worth
        -- having: turn `enabled` on, fly out, and nudge the pieces that
        -- landed somewhere silly. Offsets are from the spawn-area centre
        -- below, so `z = 0` is ground level in the middle of the arena and a
        -- piece on a slope is moved with its own `z`. Nobody is ever placed
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

        -- Used only if spawnArea is switched off. The heading is the one the
        -- operator stood at, pointed back towards the middle from each side.
        spawns = {
            vector4(2374.4294, 2565.0552, 46.6677, 270.0),
            vector4(2314.4294, 2565.0552, 46.6677, 90.0),
            vector4(2344.4294, 2595.0552, 46.6677, 180.0),
            vector4(2344.4294, 2535.0552, 46.6677, 0.0),
        },

        teamSpawns = {
            crimson = {
                vector4(2374.4294, 2565.0552, 46.6677, 270.0),
                vector4(2374.4294, 2553.0552, 46.6677, 270.0),
            },
            ash = {
                vector4(2314.4294, 2565.0552, 46.6677, 90.0),
                vector4(2314.4294, 2577.0552, 46.6677, 90.0),
            },
        },

        boundary = {
            enabled = true,
            center = vector3(2344.4294, 2565.0552, 46.6677),
            -- BIG ENOUGH FOR THE WHOLE PARK, which is the point of holding a
            -- match in a real place. Sixty metres reached the spawn ring and
            -- very little else: the vans on the far rows, the track in and
            -- the fence line were all outside it, so chasing somebody around
            -- the place you came here to fight in started the bleed. A
            -- hundred covers the lot end to end with room to back off, and
            -- still stops well short of the highway.
            --
            -- Grows with the roster like everything else below: at the
            -- twenty-player ceiling this is 135m.
            radius = 100.0,
            warningSeconds = 5,
            damagePerTick = 20,
            tickMs = 500,
        },

        -- ROOM FOR TWENTY, on ground that already exists.
        --
        -- Only the spawn ring and the boundary move here -- there is no floor
        -- to grow and the cover is switched off -- so this is purely "spread
        -- people further apart and give them more of the park to use". The
        -- ceiling is deliberately lower than the skydome's: that one builds
        -- its own world and can be any size, and this one has a fence around
        -- it and a highway past it.
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
        -- ON, and the only arena this server runs.
        --
        -- THE PROP MODELS BELOW ARE THE ONE THING HERE THAT CANNOT BE CHECKED
        -- FROM OUTSIDE THE GAME. If a model is not on your build the floor
        -- does not appear -- so the client REFUSES to place anybody into an
        -- arena whose floor did not build, and says so in the console, rather
        -- than dropping the round into a kilometre of air. Nobody falls; the
        -- match simply will not start, which is the failure you want.
        --
        -- Fly up to the coordinates below once and look at it. What you are
        -- checking is that the floor is solid and that `spawnArea.center.z`
        -- is standing height on it.
        enabled = true,

        -- THE FLOOR.
        platform = {
            enabled = true,

            -- A Cunning Stunts building block: a big solid slab with a flat
            -- top, which is what people build sky platforms out of.
            --
            -- CHECKED AGAINST THE GAME'S OWN OBJECT LIST, not remembered.
            -- The first model written here was invented and does not exist,
            -- which would have meant no floor at all -- tests/skyarena_spec
            -- now pins every model named in this file against a dump of all
            -- 21,631 real ones.
            -- TRIED IN ORDER; the first one this build actually has is used,
            -- and the console says which if it was not the first. A name
            -- being real is not the same as it being on YOUR server: a build
            -- without the Cunning Stunts DLC has none of the first two, and
            -- the shipping container is base game and always there.
            --
            -- FIVE DEEP, and the first four are the same shape from four
            -- different DLCs -- Cunning Stunts, Bikers, Import/Export and
            -- Arena War. A server missing all four has been stripped hard.
            -- The fifth is a base-game shipping container, which every build
            -- has and which tiles into a floor perfectly well; it just takes
            -- a few hundred pieces to do it, which is what `maxTiles` is for.
            models = {
                'stt_prop_stunt_bblock_huge_01',
                'bkr_prop_biker_bblock_huge_01',
                'imp_prop_impexp_bblock_huge_01',
                'ar_prop_ar_bblock_huge_01',
                'prop_container_01a',
            },

            -- A FALLBACK, not the answer. The client asks the game for the
            -- model's real footprint with GetModelDimensions and lays the
            -- floor out on that, so this is only used if the model will not
            -- load -- and a model that will not load has no floor to space.
            --
            -- It matters because nobody can get it right by hand: too big
            -- leaves seams to fall through, too small stacks the pieces into
            -- a flickering mess, and from the ground you cannot tell which.
            tileSize = 10.0,

            -- How far the floor reaches. Inside the boundary below, so the
            -- edge of the world is the edge of the floor rather than a
            -- stretch of open air you can stand in while bleeding.
            --
            -- IT HAS TO CARRY THE WALL, and that is why it is 48 and not 45.
            -- The wall stands at 44.5, a container is 2.44m across, and a
            -- tile is only kept when part of it falls inside this radius --
            -- so at 45 the outermost pieces had a corner hanging over a
            -- notch in the rim. Three metres of margin puts whole tiles
            -- under every corner of every piece at every size the arena
            -- grows to, which tests/propfit_spec.lua checks rather than
            -- takes on trust.
            radius = 48.0,

            -- THE SURFACE PEOPLE STAND ON. Not where the pieces are
            -- created -- the client measures the prop and lowers it by its
            -- own height so that its TOP lands exactly here, whichever model
            -- out of the chain above this build turned out to have.
            --
            -- So this is the one number that has to agree with `spawnArea`
            -- and `cover` below, and they are all 1201. It used to be the
            -- other way round: the pieces were created at this Z and the
            -- surface came out at "1201 plus however tall that prop is",
            -- which left the cover buried inside the floor and the spawn
            -- height wrong by the height of a prop nobody had measured.
            z = 1201.0,

            -- A CEILING ON THE PIECE COUNT, and it only ever bites on the
            -- container fallback: a big block tiles this arena in nine
            -- pieces, a container needs a few hundred. The middle is kept
            -- and the outer rim is dropped, so what a capped floor loses is
            -- edge nobody spawns on rather than a hole under somebody.
            -- 0 means no ceiling.
            maxTiles = 400,
        },

        -- SOMETHING TO GET BEHIND, AND SOMETHING TO STOP AT.
        --
        -- Without cover a flat disc is a staring contest: everybody sees
        -- everybody from the first second and the round is decided by who
        -- aimed first. Without a WALL the same disc is a thousand-metre drop
        -- with nothing at all between a fighter and the edge of it.
        --
        -- Positions are OFFSETS from the spawn-area centre below, so `z = 0`
        -- is standing on the floor and a piece can be nudged a metre without
        -- working out a world coordinate. Add, delete and move these freely
        -- -- it is a list, and nothing else reads it.
        --
        -- `z` IS THE ONE OFFSET THAT DOES NOT SCALE WITH THE ARENA, because
        -- it is measured in prop rather than in arena: a container is 2.6m
        -- tall whatever size the floor is. That is what makes a stack a
        -- stack -- a second piece at `z = 2.6` stands on the roof of the one
        -- at `z = 0` at every roster size, rather than drifting into the air
        -- as the arena grows.
        --
        -- `align = 'tangent'` TURNS A PIECE SIDE-ON TO THE MIDDLE, and it
        -- overrides the heading written beside it. The client measures the
        -- model and works out which heading actually does that, because which
        -- way round a prop is built -- long side along its own X or its own Y
        -- -- is not something config can know. The heading is still written
        -- down as the fallback for a model this build cannot measure. See
        -- Arena.TangentHeading in shared/arena.lua.
        --
        -- The models here are the second thing to check in game, after the
        -- floor. Any solid prop works; these are ordinary base-game ones.
        cover = {
            enabled = true,
            pieces = {
                -- THE WALL. Twenty-two containers end to end around the rim,
                -- every one of them doubled: 5.2m of steel, which is not
                -- climbable and not something anybody walks off by accident.
                -- NOTHING GOES OVER THE TOP -- the sky stays open, and this is
                -- a wall rather than a box.
                --
                -- WHY TWENTY-TWO, AND WHY 44.5m. A container is 12.19m long, so
                -- the ring has to be a twenty-two sided polygon whose edge is a
                -- little longer than one: shorter and the inside corners drive
                -- through each other, longer and gaps open up. At this radius
                -- adjacent pieces come within 0.19m of touching on the inside
                -- face. Nothing gets between them, and no two pieces share a
                -- millimetre of volume.
                --
                -- IT COSTS THE SPAWN PLACEMENT NOTHING, which is what lets it
                -- be this big. Cover is excluded from placement at 7m and the
                -- spawn circle reaches 35m, so a wall at 44.5 is 9.5m clear of
                -- the furthest point anybody can be put -- at every size the
                -- arena grows to, because both numbers scale together.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 44.5, y = 0.0, z = 0.0, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 44.5, y = 0.0, z = 2.6, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = 12.5, z = 0.0, heading = 253.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = 12.5, z = 2.6, heading = 253.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = 24.1, z = 0.0, heading = 237.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = 24.1, z = 2.6, heading = 237.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = 33.6, z = 0.0, heading = 220.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = 33.6, z = 2.6, heading = 220.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = 40.5, z = 0.0, heading = 204.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = 40.5, z = 2.6, heading = 204.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = 44.0, z = 0.0, heading = 188.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = 44.0, z = 2.6, heading = 188.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = 44.0, z = 0.0, heading = 171.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = 44.0, z = 2.6, heading = 171.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = 40.5, z = 0.0, heading = 155.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = 40.5, z = 2.6, heading = 155.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = 33.6, z = 0.0, heading = 139.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = 33.6, z = 2.6, heading = 139.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = 24.1, z = 0.0, heading = 122.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = 24.1, z = 2.6, heading = 122.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = 12.5, z = 0.0, heading = 106.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = 12.5, z = 2.6, heading = 106.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -44.5, y = 0.0, z = 0.0, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -44.5, y = 0.0, z = 2.6, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = -12.5, z = 0.0, heading = 73.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -42.7, y = -12.5, z = 2.6, heading = 73.7, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = -24.1, z = 0.0, heading = 57.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -37.4, y = -24.1, z = 2.6, heading = 57.2, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = -33.6, z = 0.0, heading = 40.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -29.1, y = -33.6, z = 2.6, heading = 40.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = -40.5, z = 0.0, heading = 24.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -18.5, y = -40.5, z = 2.6, heading = 24.6, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = -44.0, z = 0.0, heading = 8.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -6.3, y = -44.0, z = 2.6, heading = 8.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = -44.0, z = 0.0, heading = 351.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 6.3, y = -44.0, z = 2.6, heading = 351.9, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = -40.5, z = 0.0, heading = 335.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 18.5, y = -40.5, z = 2.6, heading = 335.4, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = -33.6, z = 0.0, heading = 319.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 29.1, y = -33.6, z = 2.6, heading = 319.1, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = -24.1, z = 0.0, heading = 302.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 37.4, y = -24.1, z = 2.6, heading = 302.8, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = -12.5, z = 0.0, heading = 286.3, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 42.7, y = -12.5, z = 2.6, heading = 286.3, align = 'tangent' },

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
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 28.0, y = 0.0, z = 0.0, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 28.0, y = 0.0, z = 2.6, heading = 270.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 19.8, y = 19.8, z = 0.0, heading = 225.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = 28.0, z = 0.0, heading = 180.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = 28.0, z = 2.6, heading = 180.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -19.8, y = 19.8, z = 0.0, heading = 135.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -28.0, y = 0.0, z = 0.0, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -28.0, y = 0.0, z = 2.6, heading = 90.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -19.8, y = -19.8, z = 0.0, heading = 45.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = -28.0, z = 0.0, heading = 360.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 0.0, y = -28.0, z = 2.6, heading = 360.0, align = 'tangent' },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 19.8, y = -19.8, z = 0.0, heading = 315.0, align = 'tangent' },

                -- THE MID BAND: eight more between the corner pockets and the
                -- outer ring, sat in the outer ring's GAPS rather than lined up
                -- behind it. Staggered, a gap in the outer ring does not also
                -- look through the middle and out the far side; lined up, every
                -- gap is a firing lane down the whole diameter.
                --
                -- SKEWED 20 DEGREES off side-on, so the arena does not read as a
                -- set of concentric circles, and a fighter behind one of these
                -- is covered from a different direction than one behind the ring
                -- outside it.
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

                -- THE MIDDLE: four containers in a pinwheel where four short
                -- barriers used to stand -- spread from 6.5m out to 9m, turned
                -- 30 degrees off side-on, and two of them doubled. The centre
                -- can still be crossed, but it is never open ground and never a
                -- straight run.
                --
                -- WHAT ADDING TO THIS COSTS, and it is why there are four and
                -- not eight. Every FOOTPRINT here is excluded from spawn
                -- placement at 7m and that exclusion is never relaxed, so a
                -- piece in the middle is room taken away from the placement --
                -- while a piece STACKED on one already there costs nothing at
                -- all. That is the whole reason this arena can be walled in and
                -- doubled up and still place eight fighters ten metres apart:
                -- 78 pieces stand in 50 footprints, and only 28 of those are
                -- inside the circle anybody is placed in -- the same 28 the
                -- arena had before any of this.
                --
                -- A DENSER LAYOUT WAS TRIED AND MEASURED AND TAKEN BACK OUT.
                -- Twelve more, in two bands, passed everything a seeded sampler
                -- and the grown arena could see -- and then failed
                -- skyarena_spec, which uses real randomness with growth off and
                -- found what the sampler had not: six fighters landing 6.23m
                -- apart against a stated 10. Adding footprints here is cheap to
                -- write and expensive to verify. Run the suite.
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 8.3, y = 3.4, z = 0.0, heading = 277.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 8.3, y = 3.4, z = 2.6, heading = 277.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -3.4, y = 8.3, z = 0.0, heading = 187.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -8.3, y = -3.4, z = 0.0, heading = 97.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = -8.3, y = -3.4, z = 2.6, heading = 97.7 },
                { models = { 'prop_container_01a', 'prop_container_01b' }, x = 3.4, y = -8.3, z = 0.0, heading = 7.7 },
            },
        },

        -- THE ARENA GROWS WITH THE MATCH.
        --
        -- The radii below describe an arena sized for a small round. Twenty
        -- fighters in the same circle is a different game: `minSeparation`
        -- stops being satisfiable, the placement quietly settles for less,
        -- and everybody opens the round already in somebody's sights.
        --
        -- So one number scales all of it -- the spawn area, the floor, the
        -- boundary and where the cover sits -- which keeps the relationships
        -- between them intact. Those relationships are what stop people
        -- spawning off the floor or out of bounds, so they are not something
        -- to let a growth setting quietly break.
        --
        -- WORTH KNOWING: the floor is TILED, so a bigger arena is more
        -- pieces. `maxTiles` above grows with it (by the square, because a
        -- disc does), and the ceiling only ever bites on the container
        -- fallback.
        scale = {
            enabled = true,

            -- The roster the radii below are written for. At or under this,
            -- nothing changes and the arena is exactly as configured.
            baseline = 6,

            -- Metres of spawn radius added per fighter above the baseline.
            -- Written in metres rather than as a multiplier because metres
            -- are what you can picture; it is converted against this
            -- arena's own size, so the same number means the same thing on
            -- a small arena and a large one.
            --
            -- At 1.6: six players fight in the 35m circle below, twenty
            -- fight in a 57m one, and the floor and boundary grow with it.
            perPlayer = 1.6,

            -- However many turn up, it never grows past this multiple of
            -- the configured size. A ceiling, not a target.
            maxGrowth = 2.0,
        },

        -- THE SPAWN Z IS EXACT HERE. Without this the client asks the game
        -- where the ground is, the game answers with the real terrain a
        -- kilometre below, and every fighter is teleported out of the sky
        -- the moment the round starts.
        exactSpawnZ = true,

        spawnArea = {
            enabled = true,
            -- A floor for the client to raise fighters to. It measures the
            -- real surface from the prop and uses that when it is higher, so
            -- this only has to be at or below standing height -- it cannot
            -- put anybody underneath the platform.
            center = vector3(1500.00, 3000.00, 1201.00),
            radius = 35.0,
            minSeparation = 10.0,
            teamRadius = 16.0,
        },

        -- The fallback list, used only if spawnArea is switched off. Same
        -- surface height.
        spawns = {
            vector4(1470.00, 3000.00, 1201.00, 90.0),
            vector4(1530.00, 3000.00, 1201.00, 270.0),
            vector4(1500.00, 3030.00, 1201.00, 180.0),
            vector4(1500.00, 2970.00, 1201.00, 0.0),
        },

        teamSpawns = {
            crimson = {
                vector4(1470.00, 3000.00, 1201.00, 90.0),
                vector4(1470.00, 3012.00, 1201.00, 90.0),
            },
            ash = {
                vector4(1530.00, 3000.00, 1201.00, 270.0),
                vector4(1530.00, 2988.00, 1201.00, 270.0),
            },
        },

        -- A SPHERE, which is what makes the drop lethal without a single
        -- line of falling code: step off the floor and you leave the
        -- boundary from underneath within a second, and it bleeds you the
        -- same way walking out of any other arena does.
        --
        -- IT HAS TO CONTAIN THE WHOLE FLOOR, and this was 60 while the floor
        -- reached 77. The last seventeen metres of solid platform were
        -- outside the arena: you walked to the edge, still on the floor, and
        -- started bleeding for it. Nothing about that reads as a boundary --
        -- it reads as the arena being broken.
        --
        -- The floor is TILED, so it reaches further than `platform.radius`:
        -- a tile is kept whenever any part of it falls inside that radius,
        -- so the last ring sticks out by up to half a tile, and on the
        -- corners by half a diagonal. 110 covers the shipped prop with room
        -- to spare, and Arena.ValidateConfig now complains if a boundary is
        -- ever smaller than the floor it is drawn around.
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
    --
    -- TWO, at the operator's request: a blade and a blunt, or a knife kept
    -- back for the end of a round. It is still counted apart from the
    -- firearms above, so this buys a second melee weapon and never a third
    -- gun.
    meleeSlots = 2,

    -- Handed to everyone on top of what they picked. Use it for a knife,
    -- a parachute, or nothing at all.
    -- EMPTY, so a player carries what they picked and nothing else.
    --
    -- The knife used to be here, handed to everybody on top of their loadout.
    -- That made the melee allowance a lie: a player who deliberately took no
    -- blade still had one, and a player who picked a different blade carried
    -- two. It is still in the weapon list, so anyone who wants a knife can
    -- take one -- it just is not decided for them.
    --
    -- Put something back by key, which inherits the real entry from the list
    -- below -- label, category, and the ammunition that weapon takes:
    --
    --     alwaysGive = { { key = 'knife' } },
    --
    -- A bare `weapon = 'WEAPON_X'` also works, for handing out something
    -- deliberately not in the list at all, like a parachute.
    alwaysGive = {},

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
        { key = 'shotgun', label = 'Shotguns', order = 3 },
        { key = 'precision', label = 'Precision', order = 4 },
        { key = 'heavy', label = 'Heavy', order = 5 },
        { key = 'melee', label = 'Melee', order = 6 },
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
        -- GENERATED FROM THIS SERVER'S OWN ox_inventory weapons.lua.
        --
        -- Every entry below is a weapon that really exists in this server's
        -- inventory, and every `item` in an `ammoTypes` line is the ammo item
        -- that weapon's own `ammoname` field names. Neither was guessed: a
        -- weapon the inventory does not define cannot be handed out, and an
        -- ammo item it does not define cannot be given, so both are read from
        -- the source rather than from a list of what GTA usually calls things.
        --
        -- `ammoTypes` is per weapon here rather than one shared list, because
        -- on this server the round differs by weapon -- a 9mm and a 12 gauge
        -- are separate items. That is exactly the per-weapon override the
        -- note further down describes.
        --
        -- ENABLED = FALSE ON EXPLOSIVES, LAUNCHERS AND NOVELTIES. They are
        -- present so they can be switched on deliberately, rather than absent

        -- ---- SIDEARM ---------------------------------------------------
        {
            key = 'acidspray',
            weapon = 'WEAPON_ACIDSPRAY',
            label = '200ML Acid Spray',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '1Ml acid ammo', item = 'ammo-acidspray' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pepperspray',
            weapon = 'WEAPON_PEPPERSPRAY',
            label = '200ML Pepper Spray',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '1Ml pepper ammo', item = 'ammo-pepperspray' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pinkpepperspray',
            weapon = 'WEAPON_PINKPEPPERSPRAY',
            label = '200ML Pepper Spray',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '1Ml pepper ammo', item = 'ammo-pepperspray' } },
            components = {},
            tint = 0,
        },
        {
            key = 'spraypaint',
            weapon = 'WEAPON_SPRAYPAINT',
            label = '200ML Spray Paint',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '1Ml Spray Paint', item = 'ammo-spraypaint' } },
            components = {},
            tint = 0,
        },
        {
            key = 'appistol',
            weapon = 'WEAPON_APPISTOL',
            label = 'AP Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'ceramicpistol',
            weapon = 'WEAPON_CERAMICPISTOL',
            label = 'Ceramic Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
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
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'doubleaction',
            weapon = 'WEAPON_DOUBLEACTION',
            label = 'Double Action Revolver',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.38 LC', item = 'ammo-38' } },
            components = {},
            tint = 0,
        },
        {
            key = 'flaregun',
            weapon = 'WEAPON_FLAREGUN',
            label = 'Flare Gun',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = 'Flare round', item = 'ammo-flare' } },
            components = {},
            tint = 0,
        },
        {
            key = 'heavypistol',
            weapon = 'WEAPON_HEAVYPISTOL',
            label = 'Heavy Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
            components = {},
            tint = 0,
        },
        {
            key = 'machinepistol',
            weapon = 'WEAPON_MACHINEPISTOL',
            label = 'Machine Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'marksmanpistol',
            weapon = 'WEAPON_MARKSMANPISTOL',
            label = 'Marksman Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.22 Long Rifle', item = 'ammo-22' } },
            components = {},
            tint = 0,
        },
        {
            key = 'nailgun',
            weapon = 'WEAPON_NAILGUN',
            label = 'Nail Gun',
            category = 'sidearm',
            enabled = false,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = 'Nail Ammo', item = 'ammo-nail' } },
            components = {},
            tint = 0,
        },
        {
            key = 'navyrevolver',
            weapon = 'WEAPON_NAVYREVOLVER',
            label = 'Navy Revolver',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
            components = {},
            tint = 0,
        },
        {
            key = 'gadgetpistol',
            weapon = 'WEAPON_GADGETPISTOL',
            label = 'Perico Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pistol',
            weapon = 'WEAPON_PISTOL',
            label = 'Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pistol50',
            weapon = 'WEAPON_PISTOL50',
            label = 'Pistol .50',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.50 AE', item = 'ammo-50' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pistolmk2',
            weapon = 'WEAPON_PISTOL_MK2',
            label = 'Pistol MK2',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'revolver',
            weapon = 'WEAPON_REVOLVER',
            label = 'Revolver',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
            components = {},
            tint = 0,
        },
        {
            key = 'revolvermk2',
            weapon = 'WEAPON_REVOLVER_MK2',
            label = 'Revolver MK2',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
            components = {},
            tint = 0,
        },
        {
            key = 'snspistol',
            weapon = 'WEAPON_SNSPISTOL',
            label = 'SNS Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
            components = {},
            tint = 0,
        },
        {
            key = 'snspistolmk2',
            weapon = 'WEAPON_SNSPISTOL_MK2',
            label = 'SNS Pistol MK2',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
            components = {},
            tint = 0,
        },
        {
            key = 'tecpistol',
            weapon = 'WEAPON_TECPISTOL',
            label = 'Tactical SMG',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'vintagepistol',
            weapon = 'WEAPON_VINTAGEPISTOL',
            label = 'Vintage Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pistolxm3',
            weapon = 'WEAPON_PISTOLXM3',
            label = 'WM 29 Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },

        -- ---- AUTOMATIC -------------------------------------------------
        {
            key = 'advancedrifle',
            weapon = 'WEAPON_ADVANCEDRIFLE',
            label = 'Advanced Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
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
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'riflemk2',
            weapon = 'WEAPON_ASSAULTRIFLE_MK2',
            label = 'Assault Rifle MK2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'assaultsmg',
            weapon = 'WEAPON_ASSAULTSMG',
            label = 'Assault SMG',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'battlerifle',
            weapon = 'WEAPON_BATTLERIFLE',
            label = 'Battle Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'bullpuprifle',
            weapon = 'WEAPON_BULLPUPRIFLE',
            label = 'Bullpup Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'bullpupriflemk2',
            weapon = 'WEAPON_BULLPUPRIFLE_MK2',
            label = 'Bullpup Rifle MK2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
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
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'carbineriflemk2',
            weapon = 'WEAPON_CARBINERIFLE_MK2',
            label = 'Carbine Rifle MK2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'combatmg',
            weapon = 'WEAPON_COMBATMG',
            label = 'Combat MG',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'combatmgmk2',
            weapon = 'WEAPON_COMBATMG_MK2',
            label = 'Combat MG MK2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'combatpdw',
            weapon = 'WEAPON_COMBATPDW',
            label = 'Combat PDW',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'compactrifle',
            weapon = 'WEAPON_COMPACTRIFLE',
            label = 'Compact Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'gusenberg',
            weapon = 'WEAPON_GUSENBERG',
            label = 'Gusenberg',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
            components = {},
            tint = 0,
        },
        {
            key = 'heavyrifle',
            weapon = 'WEAPON_HEAVYRIFLE',
            label = 'Heavy Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'mg',
            weapon = 'WEAPON_MG',
            label = 'Machine Gun',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'microsmg',
            weapon = 'WEAPON_MICROSMG',
            label = 'Micro SMG',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
            components = {},
            tint = 0,
        },
        {
            key = 'militaryrifle',
            weapon = 'WEAPON_MILITARYRIFLE',
            label = 'Military Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'minismg',
            weapon = 'WEAPON_MINISMG',
            label = 'Mini SMG',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
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
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'smgmk2',
            weapon = 'WEAPON_SMG_MK2',
            label = 'SMG Mk2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
            components = {},
            tint = 0,
        },
        {
            key = 'specialcarbine',
            weapon = 'WEAPON_SPECIALCARBINE',
            label = 'Special Carbine',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'specialcarbinemk2',
            weapon = 'WEAPON_SPECIALCARBINE_MK2',
            label = 'Special Carbine MK2',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },
        {
            key = 'tacticalrifle',
            weapon = 'WEAPON_TACTICALRIFLE',
            label = 'Tactical Rifle',
            category = 'automatic',
            enabled = true,
            ammo = { default = 150, options = { 60, 150, 300 }, max = 500 },
            ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
            components = {},
            tint = 0,
        },

        -- ---- SHOTGUN ---------------------------------------------------
        {
            key = 'assaultshotgun',
            weapon = 'WEAPON_ASSAULTSHOTGUN',
            label = 'Assault Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'bullpupshotgun',
            weapon = 'WEAPON_BULLPUPSHOTGUN',
            label = 'Bullpup Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'combatshotgun',
            weapon = 'WEAPON_COMBATSHOTGUN',
            label = 'Combat Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'dbshotgun',
            weapon = 'WEAPON_DBSHOTGUN',
            label = 'Double Barrel Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'heavyshotgun',
            weapon = 'WEAPON_HEAVYSHOTGUN',
            label = 'Heavy Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'shotgun',
            weapon = 'WEAPON_PUMPSHOTGUN',
            label = 'Pump Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'pumpshotgunmk2',
            weapon = 'WEAPON_PUMPSHOTGUN_MK2',
            label = 'Pump Shotgun MK2',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'sawnoffshotgun',
            weapon = 'WEAPON_SAWNOFFSHOTGUN',
            label = 'Sawn Off Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'autoshotgun',
            weapon = 'WEAPON_AUTOSHOTGUN',
            label = 'Sweeper Shotgun',
            category = 'shotgun',
            enabled = true,
            ammo = { default = 40, options = { 20, 40, 80 }, max = 150 },
            ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
            components = {},
            tint = 0,
        },

        -- ---- PRECISION -------------------------------------------------
        {
            key = 'heavysniper',
            weapon = 'WEAPON_HEAVYSNIPER',
            label = 'Heavy Sniper',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '.50 BMG', item = 'ammo-heavysniper' } },
            components = {},
            tint = 0,
        },
        {
            key = 'snipermk2',
            weapon = 'WEAPON_HEAVYSNIPER_MK2',
            label = 'Heavy Sniper MK2',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '.50 BMG', item = 'ammo-heavysniper' } },
            components = {},
            tint = 0,
        },
        {
            key = 'marksman',
            weapon = 'WEAPON_MARKSMANRIFLE',
            label = 'Marksman Rifle',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
            components = {},
            tint = 0,
        },
        {
            key = 'marksmanriflemk2',
            weapon = 'WEAPON_MARKSMANRIFLE_MK2',
            label = 'Marksman Rifle MK2',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
            components = {},
            tint = 0,
        },
        {
            key = 'musket',
            weapon = 'WEAPON_MUSKET',
            label = 'Musket',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '.50 Ball', item = 'ammo-musket' } },
            components = {},
            tint = 0,
        },
        {
            key = 'precisionrifle',
            weapon = 'WEAPON_PRECISIONRIFLE',
            label = 'Precision Rifle',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
            components = {},
            tint = 0,
        },
        {
            key = 'sniper',
            weapon = 'WEAPON_SNIPERRIFLE',
            label = 'Sniper Rifle',
            category = 'precision',
            enabled = true,
            ammo = { default = 20, options = { 10, 20, 40 }, max = 80 },
            ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
            components = {},
            tint = 0,
        },

        -- ---- HEAVY -----------------------------------------------------
        {
            key = 'emplauncher',
            weapon = 'WEAPON_EMPLAUNCHER',
            label = 'Compact EMP Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'EMP round', item = 'ammo-emp' } },
            components = {},
            tint = 0,
        },
        {
            key = 'compactlauncher',
            weapon = 'WEAPON_COMPACTLAUNCHER',
            label = 'Compact Grenade Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = '40mm Explosive', item = 'ammo-grenade' } },
            components = {},
            tint = 0,
        },
        {
            key = 'firework',
            weapon = 'WEAPON_FIREWORK',
            label = 'Firework Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Firework', item = 'ammo-firework' } },
            components = {},
            tint = 0,
        },
        {
            key = 'fireworksingle',
            weapon = 'WEAPON_FIREWORKSINGLE',
            label = 'Firework Spray',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Firework', item = 'ammo-firework' } },
            components = {},
            tint = 0,
        },
        {
            key = 'flamethrower',
            weapon = 'WEAPON_FLAMETHROWER',
            label = 'Flamethrower',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Fuel', item = 'ammo-flamethrower' } },
            components = {},
            tint = 0,
        },
        {
            key = 'grenadelauncher',
            weapon = 'WEAPON_GRENADELAUNCHER',
            label = 'Grenade Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = '40mm Explosive', item = 'ammo-grenade' } },
            components = {},
            tint = 0,
        },
        {
            key = 'hominglauncher',
            weapon = 'WEAPON_HOMINGLAUNCHER',
            label = 'Homing Launcher',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Rocket', item = 'ammo-rocket' } },
            components = {},
            tint = 0,
        },
        {
            key = 'minigun',
            weapon = 'WEAPON_MINIGUN',
            label = 'Minigun',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
            components = {},
            tint = 0,
        },
        {
            key = 'rpg',
            weapon = 'WEAPON_RPG',
            label = 'RPG',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Rocket', item = 'ammo-rocket' } },
            components = {},
            tint = 0,
        },
        {
            key = 'railgun',
            weapon = 'WEAPON_RAILGUN',
            label = 'Railgun',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Railgun charge', item = 'ammo-railgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'railgunxm3',
            weapon = 'WEAPON_RAILGUNXM3',
            label = 'Railgun XM3',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Railgun charge', item = 'ammo-railgun' } },
            components = {},
            tint = 0,
        },
        {
            key = 'raycarbine',
            weapon = 'WEAPON_RAYCARBINE',
            label = 'Unholy Hellbringer',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Laser charge', item = 'ammo-laser' } },
            components = {},
            tint = 0,
        },
        {
            key = 'rayminigun',
            weapon = 'WEAPON_RAYMINIGUN',
            label = 'Widowmaker',
            category = 'heavy',
            enabled = false,
            ammo = { default = 8, options = { 4, 8, 16 }, max = 30 },
            ammoTypes = { { key = 'standard', label = 'Laser charge', item = 'ammo-laser' } },
            components = {},
            tint = 0,
        },

        -- ---- MELEE -----------------------------------------------------
        {
            key = 'bat',
            weapon = 'WEAPON_BAT',
            label = 'Bat',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'bottle',
            weapon = 'WEAPON_BOTTLE',
            label = 'Bottle',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
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
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'dagger',
            weapon = 'WEAPON_DAGGER',
            label = 'Dagger',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
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
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'hammer',
            weapon = 'WEAPON_HAMMER',
            label = 'Hammer',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
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
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'knife',
            weapon = 'WEAPON_KNIFE',
            label = 'Knife',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'knuckles',
            weapon = 'WEAPON_KNUCKLE',
            label = 'Knuckle Dusters',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'machete',
            weapon = 'WEAPON_MACHETE',
            label = 'Machete',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'nightstick',
            weapon = 'WEAPON_NIGHTSTICK',
            label = 'Nightstick',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'poolcue',
            weapon = 'WEAPON_POOLCUE',
            label = 'Pool Cue',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
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
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'wrench',
            weapon = 'WEAPON_WRENCH',
            label = 'Wrench',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'battleaxe',
            weapon = 'WEAPON_BATTLEAXE',
            label = 'Battle Axe',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'stonehatchet',
            weapon = 'WEAPON_STONE_HATCHET',
            label = 'Stone Hatchet',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'candycane',
            weapon = 'WEAPON_CANDYCANE',
            label = 'Candy Cane',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
        },
        {
            key = 'flashlight',
            weapon = 'WEAPON_FLASHLIGHT',
            label = 'Flashlight',
            category = 'melee',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
            ammoTypes = false,
            components = {},
            tint = 0,
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

        -- How often, in seconds, the server checks for belongings it still
        -- owes somebody and hands them over.
        --
        -- WHAT IT IS FOR. Giving a player their inventory back can fail for
        -- ordinary reasons -- their pockets are full, they are over the
        -- weight limit, they disconnected mid-round -- and when it does,
        -- their things stay safely in the stash rather than being destroyed.
        -- This is what empties that stash afterwards, on its own, the moment
        -- the reason goes away. It survives a reconnect and a server restart,
        -- because the stash is named from the character and not from a server
        -- id, and it never gives anything to somebody who is in a round.
        --
        -- 0 switches it off, and the cost of that is exactly what it was
        -- before this existed: anything that would not go back sits in the
        -- stash until an operator opens it by hand.
        returnRetrySeconds = 30,
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
        -- ON, because this server has real per-round ammo items and the
        -- weapon list above names the right one for every single weapon,
        -- read out of that weapon's own `ammoname` in ox_inventory.
        --
        -- WHAT A PLAYER GETS. They pick a weapon, they pick an amount from
        -- that weapon's own list, and they are handed exactly that many
        -- rounds of exactly the round that weapon takes -- one magazine
        -- loaded in the gun and the remainder as real inventory items they
        -- can see and reload from.
        --
        -- THE AMOUNT IS A TOTAL, AND IT USED TO BE ISSUED TWICE. The magazine
        -- was filled with the whole pick and the same amount was handed over
        -- again as items: sixty rounds chosen, sixty in the gun, sixty in the
        -- pocket, a hundred and twenty carried. Every weapon, every round.
        -- Two loops each doing their own job correctly, neither aware the
        -- other had already issued the lot.
        --
        -- WHERE THE SPLIT FALLS is the weapon's own `magazine` if it has one,
        -- otherwise the SMALLEST amount that weapon's own `ammo.options`
        -- offers -- which is the operator's own idea of a small quantity of
        -- this round, already written next to the weapon. Every firearm in
        -- the list below has one, so nothing needs adding. A pistol offering
        -- 30/60/120 and picked at 60 arrives with 30 loaded and 30 in the
        -- pocket; picked at 30 it arrives with 30 loaded and nothing spare,
        -- because thirty rounds is thirty rounds.
        --
        -- AND NOTHING ELSE. The round is not something they choose: it comes
        -- from the weapon. Asking for a different one does not fail, it is
        -- simply ignored and the weapon's own round is issued -- a pistol
        -- asking for .50 BMG gets 9mm. There is a spec for exactly that,
        -- because "refuses the request" and "ignores the request" look the
        -- same from the panel and are very different at the door.
        --
        -- Turning this OFF does not remove the ammunition: rounds then travel
        -- in the weapon's own metadata instead, which is how ox_inventory
        -- carries them when there is no separate item. It removes the items.
        enabled = true,


        -- How many rounds one item is worth. With ox_inventory's usual
        -- per-round ammo items this is 1 and a player picking 60 rounds is
        -- given 60 items. If one item on your server is a box of 30, put 30
        -- here and they get 2.
        roundsPerItem = 1,

        -- What a weapon starts loaded with when it names no `magazine` of its
        -- own AND its `ammo.options` list is empty. Every firearm shipped
        -- below has an options list, so this is only reached by a weapon an
        -- operator adds without one, or by an `alwaysGive` entry that names
        -- no catalogue weapon.
        --
        -- Never more than the player picked: it is a ceiling on the magazine,
        -- not an amount handed out.
        defaultMagazine = 30,

        -- Give the weapon even when its ammo item could not be handed over --
        -- a full inventory, or an item name this server does not have.
        --
        -- ON  (default): they fight with the magazine and no reloads rather
        --     than being refused the weapon. Friendlier, and the failure is
        --     in the console for the operator either way.
        -- OFF: that WEAPON is taken back off them. They keep their place in
        --     the round and everything else they picked -- what goes is the
        --     one gun they cannot reload.
        --
        -- NOTE WHAT THE SPLIT ABOVE DID TO THIS. A weapon picked at or under
        -- one magazine has no spare rounds to issue, so there is no item to
        -- refuse and neither branch is reached -- which is right: that gun is
        -- carrying every round the player asked for.
        --
        -- The old wording here said `off` made the match refuse to start the
        -- player. It never did: nothing read this setting at all, and both
        -- values behaved as `on`. Ejecting somebody mid-placement would mean
        -- unwinding a dispatch flag, a routing bucket and a stash already set
        -- for them, so taking the gun is what it does instead -- which is
        -- what the setting is FOR, without inventing a new way to strand a
        -- player.
        allowWeaponWithoutAmmoItem = true,
    },

    -- LETTING A PLAYER TYPE THEIR OWN AMOUNT.
    --
    -- On, the ammo row gets a box next to the presets and a player may ask
    -- for any number up to that weapon's `max`. The preset buttons stay --
    -- they are what most people will click -- and become suggestions rather
    -- than the only legal values.
    --
    -- WHAT THIS DOES NOT CHANGE: the ceiling. `max` is still enforced by the
    -- server on every request, so this widens what a player may ASK for and
    -- moves the limit not at all. With it OFF an off-list request falls back
    -- to that weapon's default rather than being rounded up to the nearest
    -- preset, which is what stops a modified client walking a value past a
    -- preset by asking for one just above it.
    --
    -- Per weapon too: give any weapon in the list its own
    -- `allowCustomAmmo = false` to pin that one to its presets while the
    -- rest stay free.
    allowCustomAmmo = true,

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
    -- THE FALLBACK, and on this server almost nothing reaches it.
    --
    -- Every weapon in the list above carries its own `ammoTypes` naming the
    -- exact item its ox_inventory entry declares, so this is only consulted
    -- for a weapon added later without one.
    --
    -- The variant rounds that used to sit here -- ammo-rifle-fmj, -ap,
    -- -incendiary, -hollowpoint, -tracer -- were removed rather than left
    -- looking configured: NONE of them exists in this server's inventory.
    -- Offering a player a round the inventory cannot produce is the quietest
    -- kind of broken, and this file's own rule is that a name which merely
    -- sounds right is worse than no name.
    --
    -- 5.56x45 is the fallback because it is the round the most weapons here
    -- take. Add variants back the moment the items exist to back them.
    defaultAmmoTypes = {
        { key = 'standard', label = '5.56x45', item = 'ammo-rifle' },
    },

    -- Body armour, picked the same way ammo is.
    -- BODY ARMOUR. Everyone starts every round on a full plate, and cannot
    -- choose otherwise -- `allowChoose = false` hides the picker entirely, so
    -- nobody can hand themselves a disadvantage by accident or hand an
    -- opponent one on purpose.
    --
    -- Turn `allowChoose` back on and the options below become a picker again,
    -- for a server that wants armour to be part of the loadout decision.
    -- ==================================================================
    -- EXTRA SUPPLIES -- what a player carries IN, on top of the kit
    --
    -- NOT THE STARTING ARMOUR. There used to be an `armor` block here with
    -- its own allowChoose / options / default / max, four keys deciding
    -- something that should never have been decidable: a round where one
    -- fighter opens on a full plate and another on none, because of a picker
    -- or because a default was lowered once and forgotten, is not a fair
    -- round. Every player now starts every life on full health and a full
    -- plate, always, and no setting here reaches that -- see
    -- Arena.StartingVitals in shared/arena.lua.
    --
    -- What this block is for is the SPARE. A second plate to put on when the
    -- first one is gone, a bandage to patch up behind cover. They are real
    -- ox_inventory items, handed over at the start of the round and taken
    -- back on the way out with everything else the arena issued -- a player
    -- cannot walk out of a match holding free plates.
    --
    -- Shaped like the weapon catalogue on purpose, down to the key / label /
    -- item triple and the `enabled` switch: an operator who has already
    -- edited that list should not have to learn a second grammar for this
    -- one.
    -- ==================================================================
    supplies = {
        -- Off, the whole section is hidden and nobody carries any. Players
        -- still start on full health and a full plate: that is a rule, and
        -- this switch does not reach it.
        enabled = true,

        -- Whether the PLAYER picks the amounts. Off, everybody carries the
        -- `default` on each entry below -- which is how an operator sets one
        -- kit for the whole server. Also forced off by
        -- Config.Loadouts.allowChoose, like every other picker here.
        allowChoose = true,

        -- A ceiling across ALL supplies together, not per entry. `0` means
        -- no ceiling. Without it a server with six supplies lets one player
        -- carry every entry's own maximum at once, which is a different
        -- match to the one the per-item numbers describe.
        totalItems = 8,

        -- THE ITEM NAMES ARE THE ONLY PART THAT MATTERS TO ox_inventory, and
        -- they must exist in YOUR ox_inventory data. `armour` and `bandage`
        -- are the QB/ox defaults and are what ships. A name that does not
        -- exist is refused by ox_inventory, and the arena says so once in
        -- the console naming the item -- it does not fail the round.
        items = {
            {
                key = 'armour',
                label = 'Body Armour',
                item = 'armour',
                -- The most one player may carry in.
                max = 4,
                -- What somebody who picks nothing carries. Kept at 1 rather
                -- than 0 so the feature is visible on a fresh install
                -- without anybody having to find this block first.
                default = 1,
                -- What the picker offers as one-tap amounts. A player may
                -- still type any number up to `max`.
                options = { 0, 1, 2, 4 },
            },
            {
                key = 'bandage',
                label = 'Bandage',
                item = 'bandage',
                max = 6,
                default = 2,
                options = { 0, 2, 4, 6 },
            },
        },
    },

    -- THERE IS NO `health` KEY HERE ANY MORE, and saying why is worth more
    -- than the key was. It read `health = 200` -- a stock GTA full bar --
    -- and the only thing it could usefully be set to was 200: lower it and
    -- the arena starts handicapping everybody for no stated reason, raise it
    -- and nothing happens, because nothing here raises a ped's ceiling.
    --
    -- Full health and a full plate on every life are a rule of the arena
    -- now, in shared/arena.lua where both realms read the same number. Their
    -- real health and armour are still captured on the way in and handed
    -- back on the way out.
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
    -- THE DOWN FLAG, AND WHY IT IS THE ONLY LAYER HERE THAT ACTS AT THE
    -- MOMENT IT MATTERS
    --
    -- The QB-family scripts -- sc-ambulance and qbx_ambulancejob among them
    -- -- keep "this player is down" as PLAYER METADATA on the framework
    -- object rather than in a table of their own. That is qbx_core's data,
    -- so this resource can write it.
    --
    -- WHY IT IS WORTH WRITING. sc-dispatch's client polls that metadata
    -- every 500ms (client/main.lua:2801-2846) and raises its own PlayerDown
    -- and PlayerDead alerts the moment it goes up -- no keypress, no
    -- request, nothing anybody has to agree to. Put the flag back down
    -- before the next poll and there is nothing for it to see. That is not a
    -- race against another handler; it is a write against a wall clock, and
    -- it does not care what order anything started in.
    --
    -- THE BUG THIS REPLACES, stated plainly because the old comment claimed
    -- the opposite. These keys used to live under `revive` and were written
    -- only by the revive -- which, on the path a fighter takes most, runs
    -- `Config.Match.respawnDelaySeconds` (5s) plus `afterRespawnDelayMs`
    -- (2000ms) AFTER the death. Seven seconds, against a 500ms poll:
    -- fourteen windows. Those two alerts were not "never raised". They were
    -- certain, on every death of every round.
    --
    -- WHAT IT STILL CANNOT DO, and this is not a limit that more code fixes:
    -- sc-ambulance sends its own EMSDownAlert from the VICTIM'S CLIENT,
    -- back-to-back with the flag it reads, so no server-side write can land
    -- between the two. This closes PlayerDown and PlayerDead. It does not
    -- close EMSDownAlert.
    -- ==================================================================
    downState = {
        -- The keys your medical script keeps the down state in. Empty this
        -- list to switch the whole thing off. A name no script reads is
        -- harmless -- it writes a field nobody looks at -- but a name that is
        -- WRONG for a script that does read it is not, which is why these two
        -- are the only ones shipped and both were read off sc-ambulance.
        keys = { 'inlaststand', 'isdead' },

        -- How often the flags are put back down for everyone in a match,
        -- in ms. `0` clears at the moment of death and never re-asserts.
        --
        -- CLEARING ONCE IS NOT KEEPING CLEAR. A medical script sets its flag
        -- from the victim's own client and several of them re-assert it --
        -- on a respawn, on a poll of their own, on a restart. Half the
        -- pollster's own interval means the arena always writes again inside
        -- the window it is being read in.
        holdIntervalMs = 250,
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
            --
            -- NO TEMPLATE BELOW, AND THERE CANNOT BE ONE. This is not a
            -- dispatch call: sc-ambulance/server/main.lua:258-268 broadcasts
            -- straight to on-duty ambulance players and never touches
            -- AddNotification, so there is no id and nothing to withdraw.
            -- Do not give it one -- it would be a name for a record that
            -- does not exist.
            'hospital:server:ambulanceAlert',

            -- sc-dispatch's second EMS entry point.
            'mydispatch:requestEMS',

            -- ---- THE TWO THAT WERE MISSING, and they are the commonest ---
            --
            -- sc-dispatch does not only react to a player ASKING for help.
            -- Its own client polls the QB metadata every 500ms
            -- (client/main.lua:2801-2846) and raises these two by itself the
            -- moment `inlaststand` or `isdead` goes up -- no keypress, no
            -- request. So a fighter who never touches G still files a call.
            --
            -- Leaving them out did more than miss a cancel: retraction is
            -- only reachable from inside a cancelEvents handler, so these
            -- two were not cancelled, not withdrawn, and not even LOGGED --
            -- they simply stood on the dispatch board for the full
            -- AutoClearTime with nothing anywhere reporting them.
            'sc-dispatch:server:PlayerDown',
            'sc-dispatch:server:PlayerDead',
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

                -- ---- THE THREE THAT HAD NO SHAPE ------------------------
                -- Read out of sc-dispatch/server/main.lua, where each id is
                -- built as '<kind>_' .. src .. '_' .. os.time():
                --   :2618 playerdown_   :2645 playerdead_   :2576 emshelp_
                --
                -- Without a shape here retractFor returns early and the call
                -- is never withdrawn, so these stood on the board for the
                -- full AutoClearTime. mydispatch:requestEMS was already in
                -- the cancel list above and still had no template, which is
                -- the quietest version of this: listed, matched, and then
                -- silently unable to do the one thing listing it was for.
                ['sc-dispatch:server:PlayerDown'] = 'playerdown_%d_%d',
                ['sc-dispatch:server:PlayerDead'] = 'playerdead_%d_%d',
                ['mydispatch:requestEMS'] = 'emshelp_%d_%d',
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

        -- THERE ARE NO COMMAND FORMS HERE ANY MORE, and saying why is worth
        -- more than the keys were.
        --
        -- `commands` ran a line on the server console with ExecuteCommand,
        -- and `clientCommands` relayed one to the player's own client to run
        -- there. Both shipped empty. Both existed because an ambulance
        -- script's revive is very often an admin command -- and an admin
        -- command run by a resource is refused, which is how this block came
        -- to carry instructions for granting this resource an ace.
        --
        -- All of it is gone rather than switched off: the resource asks for
        -- no permissions, runs no commands, and no longer has a channel for
        -- running one. What is left below are EVENTS and EXPORTS, which are
        -- things a script publishes on purpose for other scripts to call.

        -- HOW LONG AFTER A RESPAWN THE MEDICAL SCRIPT IS TOLD, in ms.
        --
        -- The client needs a moment to be placed and standing before there
        -- is a living player for anybody's revive to be about. Two seconds
        -- covers the teleport and the collision wait.
        --
        -- IT IS NOT WHAT KEEPS THE DISPATCH QUIET ANY MORE, and that is the
        -- correction worth reading. The down flags used to be cleared by
        -- this same handoff, seven seconds after a death, against a poll
        -- running twice a second -- so raising or lowering this number moved
        -- a guarantee that was never being kept. Config.Dispatch.downState
        -- clears them at the death itself now and holds them down; this is
        -- only about telling another script.
        afterRespawnDelayMs = 2000,

        -- A SECOND, BLANKET PASS over everybody who played, this many ms
        -- after the match ends. `0` switches it off.
        --
        -- The belt to the exit path's braces: every exit tells the medical
        -- script already, and this is what covers the exit nobody has
        -- written yet. Run once, when everybody is home.
        sweepAfterMatchMs = 5000,

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
