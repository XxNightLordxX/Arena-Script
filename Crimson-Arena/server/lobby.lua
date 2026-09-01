--[[
    crimson_arena/server/lobby.lua

    The match registry, and the one place the panel's picture of the world
    is built.

    EVERY match that exists lives in the `matches` table below, from the
    moment its host creates it to the moment it is destroyed. Nothing else
    in this resource keeps a second list -- server/match.lua reads and
    mutates the very same records, which is why the record shape here is
    fixed and documented rather than convenient.

    WHAT THIS FILE DECIDES: who may sit in a lobby, on which side, with
    which guns, and who has said they are ready. WHAT IT DOES NOT DECIDE:
    whether a lobby may START (Arena.CanStartMatch and server/match.lua),
    and where money is (server/betting.lua). Stakes are taken and returned
    exclusively through ArenaBetting -- this file never touches an account.

    UNEVEN TEAMS ARE LEGAL. Nothing here refuses a join, a team switch or a
    ready toggle because the sides are lopsided. Arena.TeamsAreStartable is
    the only thing that ever looks at balance, and it looks once, at start
    time. The single team-shaped refusal below is Config.Teams.maxTeamSize,
    which is a cap, not a balance rule.

    THE SNAPSHOT is built in BuildState and nowhere else. Broadcast sends it
    to the people who can see it -- panel open, in a match, or watching one
    -- and to nobody else. A ready toggle in a two-player lobby must not
    cost the other ninety-eight players on the server a serialisation.
]]

ArenaLobby = {}

-- ======================================================================
-- REGISTRY
-- ======================================================================

--- Every match, keyed by its ArenaNewId() string.
local matches = {}

--- The two ways a source can be attached to a match, kept as reverse
--- indexes so "which match is this player in" is a lookup rather than a
--- scan of every lobby on every event.
local playerIndex = {}          -- [src] = matchId, for people PLAYING
local spectatorIndex = {}       -- [src] = matchId, for people WATCHING

--- Sources with the arena panel open. main.lua marks them, including on
--- playerDropped -- but a dropped source that was never unmarked would be
--- pushed to forever, so Broadcast prunes as it goes.
local panelOpen = {}

-- ======================================================================
-- LEADERBOARD CACHE
--
-- The panel wants the leaderboard inside the same snapshot as everything
-- else, but ArenaStats.GetLeaderboard answers through a callback and may
-- be waiting on a database. So the snapshot always carries the last rows
-- we were handed and a refresh runs behind it: a panel that opens on an
-- empty board fills in a moment later, and no state build ever blocks on
-- IO.
-- ======================================================================

local leaderboard = {}
local leaderboardAt = 0
local LEADERBOARD_TTL_SECONDS = 30

local function refreshLeaderboard()
    local now = os.time()
    if now - leaderboardAt < LEADERBOARD_TTL_SECONDS then return end
    leaderboardAt = now

    local synchronous = true
    ArenaStats.GetLeaderboard(function(rows)
        leaderboard = rows
        -- With no database the callback lands before this function has even
        -- returned, and the caller is about to build a snapshot from the
        -- fresh rows anyway. Only a late answer has an audience to push to.
        if not synchronous then ArenaLobby.Broadcast() end
    end)
    synchronous = false
end

-- ======================================================================
-- LOOKUPS
-- ======================================================================

--- @param matchId any -- straight off the wire; may be anything
--- @return table|nil match
function ArenaLobby.Get(matchId)
    if not Arena.IsKey(matchId) then return nil end
    return matches[matchId]
end

--- @param src any
--- @return table|nil match
function ArenaLobby.GetByPlayer(src)
    local target = tonumber(src)
    if not target then return nil end
    local matchId = playerIndex[target]
    if not matchId then return nil end
    return matches[matchId]
end

--- Oldest first, id breaking the tie, so two reads of an unchanged registry
--- can never render the match list in a different order.
--- @return table[] matches
function ArenaLobby.All()
    local out = {}
    for _, match in pairs(matches) do out[#out + 1] = match end
    table.sort(out, function(a, b)
        if a.createdAt ~= b.createdAt then return a.createdAt < b.createdAt end
        return a.id < b.id
    end)
    return out
end

--- @param match table
--- @return integer
function ArenaLobby.PlayerCount(match)
    if type(match) ~= 'table' then return 0 end
    return Arena.Count(match.players)
end

--- The roster as an ARRAY, in join order -- the shape every Arena.* rule
--- takes, and the order a spawn index is drawn from.
--- @param match table
--- @return table[] players
function ArenaLobby.PlayerArray(match)
    local out = {}
    if type(match) ~= 'table' then return out end
    for _, src in ipairs(match.order or {}) do
        local player = match.players[src]
        if player then out[#out + 1] = player end
    end
    return out
end

-- ======================================================================
-- INTERNAL HELPERS
-- ======================================================================

--- @param match table
--- @param src number
local function removeFromOrder(match, src)
    for index, entry in ipairs(match.order) do
        if entry == src then
            table.remove(match.order, index)
            return
        end
    end
end

--- The match a player is in AND their row in it, in one lookup. The two can
--- only fall out of step if something removed a row without clearing the
--- index; reporting that as "not in a match" beats indexing a nil.
--- @param src number
--- @return table|nil match
--- @return table|nil player
--- The loadout a player joining `match` should start with.
---
--- In host mode that is whatever the host is currently holding, so a late
--- joiner is armed the same as everybody else rather than being the one
--- player carrying the default. A fresh resolve otherwise.
---
--- Always a NEW table. Handing back the host's own would tie two players'
--- loadouts together for the rest of the match, and gun game rewrites a
--- player's loadout in place as they climb.
--- @param match table
--- @return table loadout
local function hostLoadoutFor(match)
    if Arena.LoadoutChooser() ~= 'host' then return (Arena.ResolveLoadout(nil)) end

    local host = match.players and match.players[match.hostSource]
    if not host or type(host.loadout) ~= 'table' then return (Arena.ResolveLoadout(nil)) end

    -- Re-resolved from the host's own loadout rather than deep-copied: it
    -- goes back through the same validation every other loadout passes, so a
    -- weapon disabled since the host picked it cannot reach a joiner.
    return (Arena.ResolveLoadout(host.loadout))
end

local function findPlayer(src)
    local match = ArenaLobby.GetByPlayer(src)
    local player = match and match.players[src] or nil
    if not player then return nil, nil end
    return match, player
end

--- @param match table
--- @return integer
local function readyCount(match)
    local total = 0
    for _, player in pairs(match.players) do
        if player.ready == true then total = total + 1 end
    end
    return total
end

--- Out of the round but still on the roster.
---
--- An eliminated fighter keeps their row -- the results board ranks off it
--- -- so "has a row in match.players" and "is still in the fight" are two
--- different questions. Somebody lying down waiting out respawnDelaySeconds
--- is not standing either, but they still have lives and are still in it.
--- @param match table
--- @param src number
--- @return boolean
local function isEliminated(match, src)
    local player = match.players[src]
    if not player then return false end
    return player.alive ~= true and (Arena.ToInt(player.lives) or 0) <= 0
end

--- Whether ArenaMatch.Start has already put this match's fighters in the
--- arena.
---
--- `state` cannot answer that, which is the whole reason this exists:
--- ArenaMatch.Begin uses 'countdown' for the lobby countdown, where nobody
--- has been moved anywhere, and ArenaMatch.Start uses the SAME name for the
--- frozen start countdown, after teleporting the room in -- only goLive
--- promotes it to 'live'. The dispatch flag is a record of what has actually
--- been DONE to a player rather than of what the match calls itself, and
--- server/match.lua raises it on the same choke point that teleports them.
--- @param match table
--- @return boolean
local function playersArePlaced(match)
    for src in pairs(match.players) do
        if ArenaDispatch.IsPlayerInArena(src) then return true end
    end
    return false
end

--- The "not right now" gates from Config.Match. They read qbx's own
--- metadata rather than the ped, because that is what the rest of the
--- server agrees a dead or cuffed player is.
---
--- Cuffed rides along with the dead check: config.lua describes both under
--- one switch and ships no separate flag for it.
--- @param src number
--- @param data table -- PlayerData
--- @return string|nil reasonKey
local function entryBlocked(src, data)
    local metadata = type(data.metadata) == 'table' and data.metadata or {}

    if Config.Match.blockWhileDead == true then
        if metadata.isdead == true or metadata.inlaststand == true then
            return 'error.cannot_join_dead'
        end
        if metadata.ishandcuffed == true then
            return 'error.cannot_join_cuffed'
        end
    end

    if Config.Match.blockWhileInVehicle == true then
        if GetVehiclePedIsIn(GetPlayerPed(src), false) ~= 0 then
            return 'error.cannot_join_in_vehicle'
        end
    end

    return nil
end

--- Which side a player lands on, and the ONLY reason a side can be refused:
--- its size cap. Lopsidedness is deliberately not consulted -- an eighth
--- player joining a 7v0 lobby is a legal lobby, and whether that lobby may
--- start is Arena.TeamsAreStartable's call, made once at start time.
---
--- A nil team with no reason means "has not picked yet", which is a legal
--- lobby state; callers must branch on the REASON, not on the team.
--- @param match table
--- @param teamKey any -- straight off the wire
--- @param ignoreSrc number? -- a player already on a side who is switching off it
--- @return string|nil team
--- @return string|nil reasonKey
local function resolveTeam(match, teamKey, ignoreSrc)
    if not Arena.ModeUsesTeams(match.modeKey) then return nil, nil end

    local roster = ArenaLobby.PlayerArray(match)

    -- With choosing switched off nobody sends a key and the smallest side
    -- takes them the moment they join.
    if Config.Teams.allowChoose == false then
        return Arena.SuggestTeam(roster), nil
    end

    local team = Arena.GetTeamByKey(teamKey)
    if not team then
        -- Sending nothing is the panel's "I have not picked". Sending a key
        -- that is not a live team is either a stale panel or a forged
        -- payload, and both deserve to be told no.
        if Arena.IsKey(teamKey) then return nil, 'error.team_unavailable' end
        return nil, nil
    end

    local cap = Arena.ToInt(Config.Teams.maxTeamSize) or 0
    if cap > 0 then
        local taken = Arena.CountTeams(roster)[team.key] or 0
        -- Someone switching within their own team must not be counted twice
        -- against the cap they are already inside.
        local current = ignoreSrc and match.players[ignoreSrc]
        if current and current.team == team.key then taken = taken - 1 end
        if taken >= cap then return nil, 'error.team_over_capacity' end
    end

    return team.key, nil
end

-- ======================================================================
-- SNAPSHOT
--
-- One shape, built here and nowhere else. The client caches whatever
-- arrives and re-renders from it, so anything the panel needs has to be in
-- here -- and anything that is not needed is a cost paid on every push.
-- ======================================================================

--- The config third of the snapshot never changes under a running resource:
--- Config is read at load and an operator editing it restarts. So it is
--- built once and handed out by reference from then on.
local configBlock

--- The panel's view of one weapon's ammo types: key and label only.
--- @param weapon table
--- @return table[]
local function ammoTypesFor(weapon)
    local out = {}
    for _, entry in ipairs(Arena.GetAmmoTypes(weapon)) do
        out[#out + 1] = { key = entry.key, label = entry.label }
    end
    return out
end

--- Which of them is preselected. Resolved through the real function rather
--- than read from config, so the panel opens on the type the server would
--- actually hand out if the player changed nothing.
--- @param weapon table
--- @return string|nil
local function defaultAmmoTypeFor(weapon)
    local resolved = Arena.ResolveAmmoType(weapon, nil)
    return resolved and resolved.key or nil
end

--- @return table
local function snapshotConfig()
    if configBlock then return configBlock end

    local weapons = {}
    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        local ammo = type(weapon.ammo) == 'table' and weapon.ammo or {}
        weapons[#weapons + 1] = {
            key = weapon.key,
            label = weapon.label or weapon.key,
            category = weapon.category,
            -- Which allowance this one is counted against. Resolved here
            -- rather than inferred from the category in JavaScript, so the
            -- panel and the server can never disagree about what a bat is.
            melee = Arena.IsMeleeWeapon(weapon),
            -- Resolved here for the same reason `melee` is: the panel shows
            -- the typing box by asking this, and the server honours what
            -- comes back by asking the same function -- so a box the server
            -- would refuse cannot be drawn.
            allowCustomAmmo = Arena.AllowsCustomAmmo(weapon),
            ammo = {
                default = Arena.ToInt(ammo.default) or 0,
                options = Arena.GetAmmoOptions(weapon),
                max = Arena.ToInt(ammo.max) or 0,
            },
            -- The ammo TYPES this weapon offers, already resolved through the
            -- same function the server will check the answer against, so the
            -- picker cannot show a round the server would refuse. Empty for
            -- melee and for any weapon an operator switched types off for --
            -- the panel shows no type control at all in that case.
            --
            -- Item names are deliberately NOT sent: which inventory item
            -- backs a round is the operator's business and nothing a client
            -- needs, and it is the sort of detail worth not broadcasting.
            ammoTypes = ammoTypesFor(weapon),
            defaultAmmoType = defaultAmmoTypeFor(weapon),
        }
    end

    local fee = Config.Betting.entryFee or {}
    local spectator = Config.Betting.spectatorBets or {}
    local fighter = Config.Betting.fighterBets or {}

    configBlock = {
        ui = Config.UI,
        arenas = Arena.GetEnabledArenas(),
        modes = Arena.GetEnabledModes(),

        teams = {
            allowChoose = Config.Teams.allowChoose ~= false,
            allowUnequal = Config.Teams.allowUnequal ~= false,
            -- THE ALLOWANCE, not just the switch. Arena.TeamsAreStartable
            -- refuses a start only when the sides differ by MORE than this,
            -- and the panel had no way to know the number -- so it warned on
            -- any difference at all and told a 3v2 lobby the server would
            -- not start it. The server starts it: 1 is within 1.
            maxTeamSizeDifference = math.max(0, Arena.ToInt(Config.Teams.maxTeamSizeDifference) or 1),
            list = Arena.GetEnabledTeams(),
        },

        loadouts = {
            allowChoose = Config.Loadouts.allowChoose ~= false,
            -- The global switch, for a weapon the panel is drawing before it
            -- has a per-weapon answer.
            allowCustomAmmo = Config.Loadouts.allowCustomAmmo == true,
            -- Sent for the same reason ammoTypeSlots below is: the SERVER
            -- enforces it, refusing a non-host's request outright, so a
            -- panel that does not know would offer every player a picker
            -- and then reject what they chose with no explanation on screen.
            chooser = Arena.LoadoutChooser(),
            weaponSlots = math.max(0, Arena.ToInt(Config.Loadouts.weaponSlots) or 1),
            meleeSlots = math.max(0, Arena.ToInt(Config.Loadouts.meleeSlots) or 1),
            -- Sent because the SERVER enforces it. Arena.ResolveLoadout caps
            -- distinct ammo types and quietly substitutes a weapon's default
            -- past the cap, so a panel that does not know the number offers a
            -- different round per weapon and then watches the server change
            -- its mind. The fourth field in this resource to be enforced at
            -- one end and never sent to the other; the pattern is always a
            -- table rebuilt by hand rather than passed through.
            ammoTypeSlots = math.max(0, Arena.ToInt(Config.Loadouts.ammoTypeSlots) or 0),
            categories = Config.Loadouts.categories or {},
            armor = Config.Loadouts.armor,
            weapons = weapons,
        },

        betting = {
            enabled = ArenaBetting.IsEnabled(),
            currencySymbol = Config.Betting.currencySymbol,
            account = Config.Betting.account,
            payout = Config.Betting.payout,
            entryFee = {
                enabled = fee.enabled == true,
                min = math.max(0, Arena.ToInt(fee.min) or 0),
                max = math.max(0, Arena.ToInt(fee.max) or 0),
                default = math.max(0, Arena.ToInt(fee.default) or 0),
                presets = fee.presets or {},
            },
            spectatorBets = {
                enabled = spectator.enabled == true,
                min = math.max(0, Arena.ToInt(spectator.min) or 0),
                max = math.max(0, Arena.ToInt(spectator.max) or 0),
                oddsMultiplier = tonumber(spectator.oddsMultiplier) or 2.0,
            },
            -- A FIGHTER BACKING THEMSELVES. Its own band, because staking
            -- money on a round you are in is a different act to backing one
            -- you are watching, and the operator sets the two separately.
            --
            -- THIS WAS NOT SENT AT ALL, and the panel had no way to know the
            -- feature existed. server/betting.lua takes these bets, settles
            -- them out of the pool and has done since fighterBets shipped --
            -- but the panel refused every one of them before it reached the
            -- wire, with "You are fighting in this match. You cannot bet on
            -- yourself." So the setting was on, correct, tested, and dead.
            -- HOW A WINNING BET IS PAID, which the panel has to know before it
            -- can tell anybody what they stand to win.
            --
            -- 'pool' is a share of everything staked, in proportion to what
            -- each backer put in -- so the figure is not knowable in advance
            -- and the panel must not pretend it is. 'odds' is the fixed
            -- multiplier below, funded by the server.
            --
            -- NOT SENT BEFORE THIS, so the panel quoted the multiplier
            -- whatever the mode: on a pool server every spectator was told
            -- they would be paid exactly twice their stake, by a rule that
            -- was not running.
            -- The accounts a player may pay from, in the operator's own order.
            -- Sent so the panel can offer the choice at all: the names are
            -- the server's, and a panel guessing 'cash'/'bank' would offer
            -- one this framework does not have.
            accounts = ArenaBetting.Accounts(),
            betPayout = (function()
                local block = Config.Betting.betPayout
                if type(block) ~= 'table' then return { fighters = 'pool', spectators = 'pool' } end
                return {
                    fighters = block.fighters == 'odds' and 'odds' or 'pool',
                    spectators = block.spectators == 'odds' and 'odds' or 'pool',
                    sharedPool = block.sharedPool ~= false,
                }
            end)(),
            fighterBets = {
                enabled = fighter.enabled == true,
                min = math.max(0, Arena.ToInt(fighter.min) or 0),
                max = math.max(0, Arena.ToInt(fighter.max) or 0),
                -- Whether they are held to their own side. The panel needs
                -- it to say WHY a chip is refused, rather than letting the
                -- server refuse it after the click.
                ownSideOnly = fighter.ownSideOnly ~= false,
            },
        },

        match = {
            minPlayers = math.max(1, Arena.ToInt(Config.Match.minPlayers) or 1),
            maxPlayers = math.max(0, Arena.ToInt(Config.Match.maxPlayers) or 0),
            -- The default a host starts on, plus the range they may move
            -- within. Sent because the SERVER enforces the range: a panel
            -- that did not know it would offer a number the server refuses.
            lives = Arena.ResolveLives(nil),
            livesChoice = (function()
                local lives = Config.Match.lives
                if type(lives) ~= 'table' or lives.allowChoose ~= true then return nil end
                local minimum = math.max(1, Arena.ToInt(lives.min) or 1)
                return {
                    min = minimum,
                    max = math.max(minimum, Arena.ToInt(lives.max) or minimum),
                }
            end)(),
            -- The radar control: whether to draw it at all, and where it
            -- starts for a host who has not touched it. What a particular
            -- match settled on is not here -- it rides on that match, as
            -- `radar` beside `lives`, because it is a rule of that round and
            -- not a property of the server.
            radar = (function()
                local block = Config.Match.radar
                if type(block) ~= 'table' or block.allowChoose == false then return nil end
                return {
                    defaultOn = block.defaultOn == true,
                    intervalSeconds = math.max(1, math.floor((Arena.ToInt(block.intervalMs) or 30000) / 1000)),
                }
            end)(),
            -- WHAT HAPPENS TO THE GUNS THEY WALKED IN WITH. The panel has a
            -- line about this and reads it off here, deliberately saying
            -- NOTHING when the field is absent rather than guessing -- so
            -- never sending it meant the line could not appear on any
            -- server, and the question every player asks before their first
            -- round went unanswered by a panel that had the answer written
            -- into it.
            restoreLoadoutOnExit = Config.Match.restoreLoadoutOnExit == true,
            roundTimeSeconds = math.max(0, Arena.ToInt(Config.Match.roundTimeSeconds) or 0),
            winCondition = Config.Match.winCondition,
            onlyHostCanStart = Config.Match.onlyHostCanStart ~= false,
            -- WHETHER READYING UP IS WHAT STARTS THE ROUND. It ships ON, and
            -- the panel told every player the opposite in as many words --
            -- "Ready Up only tells the others you are set, it does not start
            -- the round" -- because it had no way to know. That is the one
            -- sentence a player reads immediately before pressing the button
            -- it is wrong about.
            autoStartWhenAllReady = Config.Match.autoStartWhenAllReady == true,
            -- WHICH MODE A NEW MATCH STARTS ON. Config.DefaultMode is used
            -- server-side as the fallback when a create arrives without one --
            -- and the panel always sends one, because it preselects from its
            -- own list. So the fallback never fired, the operator's setting
            -- never took effect, and every match opened on whichever mode
            -- happened to come first.
            defaultMode = Arena.IsKey(Config.DefaultMode) and Config.DefaultMode or nil,
            lobbyCountdownSeconds = math.max(0, Arena.ToInt(Config.Match.lobbyCountdownSeconds) or 0),
        },
    }
    return configBlock
end

--- What somebody who is in no match is shown in the loadout tab, and what
--- they would be handed if they joined and never touched it. Read-only: it
--- is only ever serialised out, never stored on a player.
local previewLoadout

--- @return table
local function loadoutPreview()
    if not previewLoadout then previewLoadout = (Arena.ResolveLoadout(nil)) end
    return previewLoadout
end

--- The one part of the snapshot that differs per recipient.
---
--- `false` rather than nil for the empty cases: a nil field does not survive
--- the trip as a key at all, and the panel would have to tell "not in a
--- match" from "the server forgot to say".
--- @param src number
--- @return table
local function snapshotPlayer(src)
    local match = ArenaLobby.GetByPlayer(src)
    local player = match and match.players[src] or nil

    local money = 0
    local qbx = ArenaGetPlayer(src)
    local data = qbx and qbx.PlayerData
    if data and type(data.money) == 'table' then
        money = Arena.ToInt(data.money[Config.Betting.account]) or 0
    end

    return {
        serverId = src,
        name = ArenaPlayerName(src),
        money = money,
        -- WHAT THEY HOLD IN EACH ACCOUNT, not just in the one the operator
        -- listed first. The panel cannot offer a choice between cash and bank
        -- without being able to say what is in them, and `money` above is a
        -- single figure from a single account.
        wallet = ArenaBetting.Wallet(src),
        matchId = match and match.id or false,
        team = (player and Arena.IsKey(player.team)) and player.team or false,
        ready = player ~= nil and player.ready == true,
        loadout = player and player.loadout or loadoutPreview(),
        spectating = spectatorIndex[src] or false,
        -- THEIR OWN SIDE-BET, so the panel can show one was taken.
        -- Side-bets live in server/betting.lua and nothing carried them
        -- here, so a player who placed one saw no stake, no side, and no
        -- change to anything -- the entry pot deliberately does not move
        -- for a side-bet, which left the screen with nothing at all to
        -- redraw. False rather than nil so the field is always on the
        -- wire and the panel can tell "no bet" from "not sent".
        bet = (match and ArenaBetting.GetSideBet(match.id, src)) or false,
        isHost = match ~= nil and match.hostSource == src,
    }
end

--- Every match, as the browser and the lobby screen render them.
--- @return table[]
local function snapshotMatches()
    local out = {}

    for _, match in ipairs(ArenaLobby.All()) do
        local arena = Arena.GetArenaByKey(match.arenaKey)
        local mode = Arena.GetModeByKey(match.modeKey)
        local roster = ArenaLobby.PlayerArray(match)

        local players = {}
        for _, player in ipairs(roster) do
            players[#players + 1] = {
                id = player.src,
                name = player.name,
                team = player.team,
                ready = player.ready == true,
                kills = player.kills,
                deaths = player.deaths,
                alive = player.alive == true,
                isHost = player.src == match.hostSource,
            }
        end

        out[#out + 1] = {
            id = match.id,
            label = match.label,
            arenaKey = match.arenaKey,
            -- An arena or mode switched off while a match was already using
            -- it stops resolving; the key is still better than a blank card.
            arenaLabel = arena and arena.label or match.arenaKey,
            modeKey = match.modeKey,
            modeLabel = mode and mode.label or match.modeKey,
            teams = Arena.ModeUsesTeams(match.modeKey),
            hostId = match.hostSource,
            hostName = match.hostName,
            state = match.state,
            entryFee = match.entryFee,
            -- SENT, because the host chose it and nothing else can tell them
            -- what they chose. Stored on the match and never put on the wire,
            -- it was a setting that appeared to do nothing: the lobby card
            -- looked identical whatever was picked, so the only way to find
            -- out was to die three times and count.
            lives = match.lives,
            -- On the wire for the same reason `lives` is: the panel draws
            -- the host's own control from it, and every other player needs
            -- to know whether the round they are joining has a radar in it.
            radar = match.radar == true,
            -- WHAT A WINNER IS ACTUALLY PLAYING FOR. GetPot is the entry
            -- pot alone; with betPayout.includeEntryPot on -- the shipped
            -- default -- the side-bets settle in the same pool, so a
            -- screen showing only the entry half sat still while a player
            -- watched their own stake go into the part it could not see.
            pot = ArenaBetting.GetPrizePool(match.id),
            -- The two halves as well, so the panel can say which is which
            -- rather than only quoting a total.
            entryPot = ArenaBetting.GetPot(match.id),
            betPool = ArenaBetting.GetSideBetPool(match.id),
            playerCount = #roster,
            teamCounts = Arena.CountTeams(roster),
            startsAt = match.startsAt,
            players = players,
        }
    end

    return out
end

--- Everyone with a reason to hold the snapshot, deduplicated.
--- @return table<number, boolean>
local function recipients()
    local targets = {}

    for src in pairs(panelOpen) do
        -- Self-healing: a panel-open entry left behind by a disconnect would
        -- otherwise be pushed to for the life of the resource.
        if Arena.IsKey(GetPlayerName(src)) then
            targets[src] = true
        else
            panelOpen[src] = nil
        end
    end

    for _, match in pairs(matches) do
        for src in pairs(match.players) do targets[src] = true end
        for src in pairs(match.spectators) do targets[src] = true end
    end

    return targets
end

--- One player's snapshot, for the changes nobody else can see.
--- @param src number
local function pushState(src)
    TriggerClientEvent('crimson_arena:client:state', src, ArenaLobby.BuildState(src))
end

--- @param src number
--- @return table snapshot
--- The arenas a player must be kept OUT of, because a round is being fought
--- in them and they are not in it.
---
--- WHY THIS EXISTS AT ALL, given isolation. A live match is fought in its own
--- routing bucket, so an outsider already cannot see the fighters, cannot
--- shoot them, and cannot be shot -- that half is settled at the strongest
--- level there is and this adds nothing to it.
---
--- What it adds is the PHYSICAL half. Without it an outsider can stand in the
--- middle of an arena, invisible to everybody fighting there, wandering
--- through a round nobody can see them in -- and if an operator ever turns
--- isolation off, they are standing in a live firefight.
---
--- Per player, and only ever the matches they are NOT in: a fighter must not
--- be pushed out of their own round.
--- @param src any
--- @return table[] zones -- { { x, y, z, radius, label } }
local function snapshotKeepOut(src)
    local barrier = (Config.Match or {}).keepOutBarrier
    if type(barrier) ~= 'table' or barrier.enabled ~= true then return {} end

    local id = tonumber(src)

    -- WHICH ARENAS THIS PLAYER BELONGS ON, worked out before a single zone
    -- is drawn -- and worked out per ARENA, which is the fix.
    --
    -- THE FENCE IS DRAWN ROUND AN ARENA AND THE EXEMPTION USED TO BE PER
    -- MATCH, so the two disagreed the moment a second round started on the
    -- same ground. Two matches live at the trailer park: for each fighter of
    -- the first, the second match is live and they are not in it, so they
    -- were handed a keep-out circle centred on the arena they were standing
    -- and fighting in -- and the client's barrier loop teleports anyone
    -- inside a zone to its radius plus the push, four times a second. At the
    -- trailer park that is 106m from the middle of the round. At the skydome
    -- it is 116m, which is off the edge of the platform and a kilometre of
    -- air. Both groups, at once, each shoved out of the other's fence.
    --
    -- Being IN the match is not the test either: a player queued in a lobby
    -- at that arena has not been teleported anywhere and must still be kept
    -- out of a round already being fought there. The test is whether the
    -- arena has actually taken them, which is what the dispatch flag records
    -- -- the same predicate playersArePlaced above leans on, and for the
    -- same reason: `state` cannot answer it.
    local mine = {}
    if ArenaDispatch.IsPlayerInArena(id) then
        for _, match in pairs(matches) do
            if type(match.players) == 'table' and match.players[id]
                and Arena.IsKey(match.arenaKey)
            then
                mine[match.arenaKey] = true
            end
        end
    end

    local zones, drawn = {}, {}

    for _, match in pairs(matches) do
        -- Lobby matches are not fought in yet, so there is nothing to keep
        -- anybody out of and no reason to fence off a field early.
        --
        -- ONE ARENA, ONE FENCE. Two live matches on one ground used to send
        -- two identical circles, which the client then tested a player
        -- against twice a tick for no different answer.
        if match.state == 'live' and not mine[match.arenaKey] and not drawn[match.arenaKey] then
            local arena = Arena.GetArenaByKey(match.arenaKey)
            local boundary = type(arena) == 'table' and arena.boundary or nil

            -- The BOUNDARY is the fence, deliberately -- the same circle the
            -- fighters themselves are bled for leaving. One arena has one
            -- edge, and two different ones would be a question with two
            -- answers on the same field.
            if type(boundary) == 'table' and boundary.enabled ~= false and boundary.center then
                local radius = tonumber(boundary.radius) or 0
                if radius > 0 then
                    zones[#zones + 1] = {
                        x = tonumber(boundary.center.x),
                        y = tonumber(boundary.center.y),
                        z = tonumber(boundary.center.z),
                        radius = radius,
                        label = arena.label or match.arenaKey,
                    }
                    drawn[match.arenaKey] = true
                end
            end
        end
    end

    return zones
end

function ArenaLobby.BuildState(src)
    refreshLeaderboard()
    return {
        config = snapshotConfig(),
        player = snapshotPlayer(src),
        matches = snapshotMatches(),
        leaderboard = leaderboard,
        keepOut = snapshotKeepOut(src),
    }
end

--- Pushes the snapshot to everyone who can see it and nobody who cannot.
---
--- The three shared thirds are built ONCE per broadcast and handed to every
--- recipient by reference; only the `player` block is rebuilt per head.
--- With forty people in a lobby the alternative is forty identical match
--- lists assembled on every ready toggle.
function ArenaLobby.Broadcast()
    refreshLeaderboard()

    local config = snapshotConfig()
    local matchList = snapshotMatches()
    local rows = leaderboard

    for src in pairs(recipients()) do
        TriggerClientEvent('crimson_arena:client:state', src, {
            config = config,
            player = snapshotPlayer(src),
            matches = matchList,
            leaderboard = rows,
            -- PER HEAD, like `player`, and it has to be here at all.
            --
            -- This payload is assembled by hand rather than through
            -- BuildState, and it was missing this one field -- so the
            -- keep-out barrier was DEAD IN PRODUCTION despite shipping
            -- enabled. client/main.lua reads a state with no keepOut as
            -- "take the fence down", and Broadcast fires on virtually every
            -- change there is: a join, a ready, a bet, a match starting, a
            -- match ending. The fence went up only on a per-player push --
            -- a panel opening, a loadout change -- and the very next
            -- broadcast pulled it back down, usually within the second.
            --
            -- It cannot be hoisted out of the loop with the other three:
            -- which arenas a player may stand in depends on which matches
            -- that player is in.
            keepOut = snapshotKeepOut(src),
        })
    end
end

-- ======================================================================
-- PANEL PRESENCE
-- ======================================================================

--- @param src any
--- @return boolean
function ArenaLobby.MarkPanelOpen(src)
    local target = tonumber(src)
    if not target then return false end
    panelOpen[target] = true
    return true
end

--- @param src any
--- @return boolean
function ArenaLobby.MarkPanelClosed(src)
    local target = tonumber(src)
    if not target then return false end
    panelOpen[target] = nil
    return true
end

-- ======================================================================
-- LIFECYCLE
-- ======================================================================

--- Opens a lobby and puts its host in it.
--- @param src any
--- @param arenaKey any
--- @param modeKey any
--- @param entryFee any
--- @return string|nil matchId
--- @return string|nil reasonKey
function ArenaLobby.Create(src, arenaKey, modeKey, entryFee, lives, radar, account)
    local host = tonumber(src)
    if not host then return nil, 'error.invalid_request' end
    if not ArenaCanCreate(host) then return nil, 'error.no_permission' end
    if playerIndex[host] then return nil, 'error.already_in_match' end

    local arena = Arena.GetArenaByKey(arenaKey)
    if not arena then return nil, 'error.arena_unavailable' end

    -- An unset mode is a panel that has not been touched, not a tampered
    -- payload -- the operator's default is what it would have shown anyway.
    local wantedMode = Arena.IsKey(modeKey) and modeKey or Config.DefaultMode
    local mode = Arena.GetModeByKey(wantedMode)
    if not mode then return nil, 'error.mode_unavailable' end

    local ceiling = Arena.ToInt(Config.Match.maxConcurrentMatches) or 0
    if ceiling > 0 and Arena.Count(matches) >= ceiling then
        return nil, 'error.too_many_matches'
    end

    -- With betting off the fee is not clamped, it does not exist: every
    -- match is free and no stake is ever taken.
    local fee = 0
    if ArenaBetting.IsEnabled() then
        local amount, reason = Arena.ResolveEntryFee(entryFee)
        if not amount then return nil, reason end
        fee = amount
    end

    -- REFUSED, NOT CLAMPED. A host who asked for a number this server does
    -- not allow is told so, rather than being dropped into a match with a
    -- different rule to the one they set.
    local resolvedLives, livesReason = Arena.ResolveLives(lives)
    if not resolvedLives then return nil, livesReason end

    -- Never refuses (see Arena.ResolveRadar), so there is nothing to check
    -- here -- a host on a server that does not offer the choice simply gets
    -- the operator's default written onto their match.
    local resolvedRadar = Arena.ResolveRadar(radar)

    local id = ArenaNewId()
    local hostName = ArenaPlayerName(host)

    matches[id] = {
        id = id,
        label = locale('match.label', hostName, mode.label or wantedMode),
        arenaKey = arenaKey,
        modeKey = wantedMode,
        hostSource = host,
        hostName = hostName,
        state = 'lobby',
        entryFee = fee,
        -- The host's choice, resolved once here and read from the match for
        -- the rest of its life. Re-reading Config.Match.lives when a player
        -- joins would give a late joiner a different number to everybody
        -- else the moment an operator edited the config mid-session.
        lives = resolvedLives,
        -- THE HOST'S, NOT EACH PLAYER'S. Stored beside `lives` because it is
        -- the same kind of thing: a rule of this match, chosen once, that
        -- everybody in it fights under.
        radar = resolvedRadar,
        createdAt = os.time(),
        -- 0, not nil, until server/match.lua schedules them: a nil field
        -- would simply be absent from the snapshot the panel receives.
        startsAt = 0,
        endsAt = 0,
        players = {},
        order = {},
        spectators = {},
    }

    -- The host joins through the same door as everybody else so their stake
    -- is taken once, by the one piece of code that takes stakes. A refused
    -- stake leaves nothing behind -- including the match.
    local ok, reason = ArenaLobby.Join(host, id, nil, account)
    if not ok then
        matches[id] = nil
        return nil, reason
    end

    ArenaLog('%s created match %s (%s / %s, fee %d)', hostName, id, arenaKey, wantedMode, fee)
    return id, nil
end

--- @param src any
--- @param matchId any
--- @param teamKey any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.Join(src, matchId, teamKey, account)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    -- Asked before the match is even looked up, the way Create asks
    -- ArenaCanCreate first: whether this player may fight here at all does
    -- not depend on which lobby they picked. An empty Config.Permissions
    -- .joinJobs is everybody, which is the shipped default.
    --
    -- The host comes through this same door, so a joinJobs list that excludes
    -- them refuses their Create as well -- which is right. A match its own
    -- host may not enter is not a match.
    if not ArenaCanJoin(target) then return false, 'error.no_permission' end

    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end
    if playerIndex[target] then return false, 'error.already_in_match' end

    -- Arena.HasRoom owns the maxPlayers = 0 rule. Reading the key here
    -- instead is how "unlimited" quietly becomes "nobody".
    if not Arena.HasRoom(ArenaLobby.PlayerCount(match)) then return false, 'error.match_full' end

    local qbx = ArenaGetPlayer(target)
    local data = qbx and qbx.PlayerData
    if not data or not Arena.IsKey(data.citizenid) then return false, 'error.player_not_loaded' end

    local blocked = entryBlocked(target, data)
    if blocked then return false, blocked end

    local team, teamReason = resolveTeam(match, teamKey, nil)
    if teamReason then return false, teamReason end

    -- MONEY FIRST. The player does not exist in this match until the stake
    -- is in escrow, so a refused stake has no row, no order entry and no
    -- index to unwind -- there is nothing to leave behind.
    local stake = 0
    if ArenaBetting.IsEnabled() and match.entryFee > 0 then
        -- The account the player chose to pay the entry fee from, carried
        -- straight through. Betting owns which names are real and what an
        -- unknown one means; this only has to not drop it.
        local taken, reason = ArenaBetting.TakeStake(target, match.id, match.entryFee, account)
        if not taken then return false, reason or 'error.stake_failed' end
        -- Escrow is the authority on what was actually taken, not the fee we
        -- asked it for.
        stake = ArenaBetting.GetStake(match.id, target)
    end

    -- Watching and playing are mutually exclusive.
    ArenaLobby.RemoveSpectator(target)

    match.players[target] = {
        src = target,
        citizenid = data.citizenid,
        name = ArenaPlayerName(target),
        team = team,
        ready = false,
        -- Resolved rather than nil so somebody who never opens the loadout
        -- tab still walks in carrying the operator's alwaysGive list. In
        -- host mode the host's pick is inherited instead, so somebody who
        -- joins after it was made is armed the same as everyone else rather
        -- than being the one player holding the default.
        loadout = hostLoadoutFor(match),
        kills = 0,
        deaths = 0,
        alive = true,
        -- FROM THE MATCH, not from config. The host chose this when they
        -- opened the lobby, and somebody who joins later has to be playing
        -- the same match as everybody already in it.
        lives = math.max(1, Arena.ToInt(match.lives) or 1),
        stake = stake,
        joinedAt = os.time(),
        placement = 0,
    }
    match.order[#match.order + 1] = target
    playerIndex[target] = match.id

    ArenaDebug('%s joined match %s (team %s, stake %d)', target, match.id, tostring(team), stake)
    ArenaLobby.Broadcast()
    return true, nil
end

--- Takes a player out of whatever they are attached to: a match if they are
--- in one, otherwise the match they were watching. main.lua routes
--- playerDropped through here for exactly that reason.
--- @param src any
--- @param reasonKey string?
--- @return boolean ok
function ArenaLobby.Leave(src, reasonKey)
    local target = tonumber(src)
    if not target then return false end

    local match, player = findPlayer(target)
    if not match then
        -- A stale index, if one ever happened, must not outlive the leave
        -- that found it.
        playerIndex[target] = nil
        return ArenaLobby.RemoveSpectator(target)
    end

    -- WHAT LEAVING COSTS. One switch per state, and the state is the only
    -- thing that picks between them: refundOnDisconnectBeforeStart while the
    -- match is still a lobby or a countdown, refundOnDisconnectDuringMatch
    -- once the round is running. Both ship as "hand it back", and neither
    -- separates walking out from dropping -- a rule that charged only real
    -- disconnects would take money from the players who crashed and give it
    -- back to the ones who quit on purpose.
    --
    -- NOT REFUNDING IS NOT MOVING: the stake stays escrowed against this
    -- match, still counted by ArenaBetting.GetPot, which is what "forfeited
    -- to the pot" means -- whoever is still in the match is playing for it.
    local started = match.state == 'live' or match.state == 'ended'
    local refund
    if started then
        refund = Config.Betting.refundOnDisconnectDuringMatch == true
    else
        refund = Config.Betting.refundOnDisconnectBeforeStart ~= false
    end

    if player.stake > 0 then
        if refund then
            ArenaBetting.RefundOne(match.id, target, reasonKey or 'bet.refund_left')
        elseif not started then
            -- Only the lobby forfeit says anything. The mid-round one has
            -- been silent since it shipped and is not this change's to alter;
            -- this one is new, so the player it takes money from hears why.
            ArenaBetting.KeepInPot(match.id, target)
        end
    end

    match.players[target] = nil
    playerIndex[target] = nil
    removeFromOrder(match, target)

    -- An eliminated fighter sits in match.players AND in match.spectators --
    -- AddSpectator admits them so the camera they were handed survives the
    -- next broadcast -- so walking out has to detach both. server/match.lua's
    -- sweep puts anyone the registry still calls a spectator into that
    -- match's routing bucket, and a leftover entry would keep pulling this
    -- player back into an instance of a round they have left.
    if spectatorIndex[target] == match.id then
        spectatorIndex[target] = nil
        match.spectators[target] = nil
    end

    -- Join order is the fairest claim on the room: whoever has been waiting
    -- longest takes it over.
    if match.hostSource == target then
        local heir = match.order[1]
        if heir then
            match.hostSource = heir
            match.hostName = match.players[heir].name
            ArenaNotifyKey(heir, 'notify.you_are_host', 'info')
        end
    end

    if Arena.Count(match.players) == 0 then
        ArenaLobby.Destroy(match.id, reasonKey or 'notify.match_empty')
        return true
    end

    ArenaLobby.Broadcast()
    return true
end

--- Refunds whatever is still escrowed, tells everyone, and removes the
--- match from the registry.
--- @param matchId any
--- @param reasonKey string?
--- @return boolean ok
function ArenaLobby.Destroy(matchId, reasonKey)
    local match = ArenaLobby.Get(matchId)
    if not match then return false end

    local notice = Arena.IsKey(reasonKey) and reasonKey or 'notify.match_closed'

    -- Anything still held goes back before the id stops existing -- escrow
    -- against a match nobody can look up is money nobody can get out again.
    -- After ArenaMatch.End has settled and cleared there is nothing left to
    -- return and both calls are no-ops, which is what makes that order safe.
    ArenaBetting.RefundAll(match.id, notice)
    ArenaBetting.Clear(match.id)
    -- AND THE INVENTORY RECORDS, which nothing called at all. ArenaAmmo.Clear
    -- has always existed and always refused while anybody's kit is still
    -- stashed -- exactly like the betting Clear above refuses over escrow --
    -- and no path in this resource ever reached it. So every match this
    -- server ran left its issued-weapon and issued-ammunition tables behind
    -- for good. It sits beside the betting Clear because it is the same step:
    -- the point where a finished match stops being owed anything.
    ArenaAmmo.Clear(match.id)

    for src in pairs(match.players) do
        -- BELT AND BRACES, and it belongs here rather than at the call
        -- sites because this is the ONE teardown every path funnels through
        -- and the step that makes the match unreachable: after this loop
        -- there is no record left of who was in it, so a caller that gets
        -- here without having sent its players home has stranded them for
        -- good -- left standing in the arena holding the issued loadout, with
        -- their own weapons, armour and health unrecoverable and a flag
        -- suppressing their police and medical alerts for the rest of the
        -- session. End, Abort and RemovePlayer all go through
        -- server/match.lua's exit choke point first, which clears the flag,
        -- so on every path that exists today this does nothing.
        --
        -- THE FLAG IS THE TEST, not match.state: the flag records who was
        -- actually teleported in, while 'countdown' names both the lobby
        -- countdown and the frozen one Start leaves behind after moving
        -- everybody.
        if ArenaDispatch.IsPlayerInArena(src) then
            -- FIRST, and unconditionally: this is the last moment anybody
            -- looks at this player, and it is the one that owes them their own
            -- inventory back. A teardown that cleared the flag and the bucket
            -- but skipped this would leave them holding the arena kit with
            -- their real belongings still sitting in a stash -- exactly the
            -- promise the door makes, broken on the one path nothing else
            -- covers. Reclaiming somebody who was never stashed is a no-op.
            ArenaAmmo.Reclaim(src, 'match closed')

            ArenaDispatch.Clear(src)
            ArenaDispatch.ExitBucket(src)
            -- No returnCoords: the client falls back to its own copy of
            -- Config.Lobby.returnCoords, which is the value every other exit
            -- path sends it anyway.
            TriggerClientEvent('crimson_arena:client:exitArena', src, {})
        end

        playerIndex[src] = nil
        ArenaNotifyKey(src, notice, 'warning')
    end
    for src in pairs(match.spectators) do
        spectatorIndex[src] = nil

        -- AND BACK OUT OF THE INSTANCE, which this loop used to skip
        -- entirely -- it forgot the index and left the routing bucket set.
        --
        -- Watching puts a player in the match's own instance so they can see
        -- it. Destroying the match without taking them back out leaves them
        -- in a room with nobody in it: invisible to the server and the
        -- server invisible to them, for the rest of their session. The
        -- per-tick sweep in server/match.lua rescues anyone stranded in a
        -- COUNTDOWN or LIVE match's bucket, but a spectator of a match still
        -- in its lobby was never in that sweep's books -- and clicking Watch
        -- on a lobby from the Matches tab, then having the host cancel it,
        -- is an entirely ordinary thing to do.
        --
        -- ONLY FOR SOMEBODY WHO WAS ONLY WATCHING, the same guard
        -- ArenaLobby.RemoveSpectator uses: an eliminated fighter watching
        -- their own round is handled by the loop above, which owes them
        -- their inventory as well as their instance.
        if not match.players[src] then
            local pulled = type(ArenaDispatch) == 'table'
                and type(ArenaDispatch.ExitBucket) == 'function'
                and ArenaDispatch.ExitBucket(src)

            -- TOLD ONLY IF THEY WERE STILL IN ONE. ExitBucket answers
            -- whether it actually moved anybody, and that is the difference
            -- between the two ways a match reaches this teardown.
            --
            -- ArenaMatch.End has already sent every spectator home, with the
            -- results board and the coordinates to walk back to; a second
            -- exit behind it lands on somebody already at the NPC and, being
            -- the later message, is the one that wins. Destroying a match
            -- that never started has sent them nothing at all, and they are
            -- the ones this is for.
            if pulled then
                TriggerClientEvent('crimson_arena:client:exitArena', src, {})
            end
        end
    end

    matches[match.id] = nil
    ArenaLog('match %s closed (%s)', match.id, notice)

    ArenaLobby.Broadcast()
    return true
end

--- The host closing their own lobby.
---
--- A cancel is its own exit rather than a Destroy with a different notice
--- because it is the ONE way of closing a lobby an operator can make cost
--- something. Everything else that closes one -- the idle sweep, an admin
--- force-stop, the last player walking out, a resource restart -- refunds in
--- full and none of them come through here, which is exactly why they are
--- unaffected by `refundOnCancel`: an operator punishing a host who calls
--- their own match off has not asked to punish a lobby the server itself
--- closed.
---
--- WHICH MATCH is never taken from the caller: it is the one they are
--- standing in, and they have to be its host.
--- @param src any
--- @return boolean ok
--- @return string|nil reasonKey
--- Puts a counting-down lobby back to being a lobby.
---
--- WHAT THE PANEL'S BUTTON ALWAYS SAID IT DID. "Stop The Countdown" posted
--- `cancelMatch`, and its own tooltip read "Everybody stays in the lobby and
--- nobody loses their place" -- while Cancel below destroys the match,
--- evicts the room, and on a server with refundOnCancel off burns every
--- stake in it. A host reading that button had no way to know.
---
--- Nothing has to be undone. ArenaMatch.Begin's countdown thread re-reads
--- the match every second and returns the moment its state is not
--- 'countdown', so putting the state back IS the stop.
---
--- Refused once the room has been teleported in, for the same reason Cancel
--- is: `state` alone cannot tell the lobby countdown from the frozen start
--- countdown -- both are called 'countdown' -- so it asks what has actually
--- been DONE to the players.
--- @param src any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.HoldCountdown(src)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match = ArenaLobby.GetByPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.hostSource ~= target and not ArenaIsAdmin(target) then return false, 'error.host_only' end
    -- THE PLACEMENT CHECK FIRST, because it is the stronger answer and the
    -- two overlap. A live round is also "not counting down", and telling a
    -- host their match cannot be found when it is being fought in front of
    -- them is the less useful of the two true things.
    if playersArePlaced(match) then return false, 'error.match_in_progress' end
    if match.state ~= 'countdown' then return false, 'error.match_not_found' end

    match.state = 'lobby'
    -- Back to "no start time", or the panel keeps counting down to a moment
    -- that is no longer coming.
    match.startsAt = 0

    for src2 in pairs(match.players) do
        ArenaNotifyKey(src2, 'notify.start_cancelled', 'warning')
    end

    ArenaLobby.Broadcast()
    return true, nil
end

function ArenaLobby.Cancel(src)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match = ArenaLobby.GetByPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.hostSource ~= target then return false, 'error.host_only' end

    -- Cancelling is a lobby control. Once the round is running the way out is
    -- leaving it, or an admin stop -- both of which already exist, and
    -- neither of which should be reachable by every host through a button
    -- labelled "cancel".
    if match.state ~= 'lobby' and match.state ~= 'countdown' then
        return false, 'error.match_in_progress'
    end

    -- ...and the state alone cannot carry that intent, because 'countdown'
    -- names two phases and only the first of them is a lobby. Once
    -- ArenaMatch.Start has teleported the room in, a cancel used to run
    -- Destroy over players standing in an arena whose record then stopped
    -- existing: nobody was sent home, nobody's own weapons came back, and
    -- every one of them kept a dispatch flag they had no way to clear. So ask
    -- what has been done to them rather than what the match calls itself.
    if playersArePlaced(match) then return false, 'error.match_in_progress' end

    -- THE STAKES. With refundOnCancel on -- the default -- nothing happens
    -- here and Destroy hands every one of them straight back. With it off
    -- they are forfeited BEFORE Destroy runs, which is what makes that order
    -- load-bearing: forfeiting marks each stake settled, so Destroy's
    -- RefundAll finds nothing left to return and its Clear can drop the match
    -- without the escrow check having to be weakened for this path.
    if Config.Betting.refundOnCancel == false then
        ArenaBetting.ForfeitAll(match.id, 'notify.match_cancelled')
    end

    ArenaLobby.Destroy(match.id, 'notify.match_cancelled')
    return true, nil
end

-- ======================================================================
-- EDITING A LOBBY THAT IS ALREADY OPEN
-- ======================================================================

--- Changes the settings of a match the host has already opened.
---
--- WHY THIS EXISTS. Picking the wrong arena used to mean closing the lobby
--- and opening another -- which refunds and re-takes every stake, drops
--- everybody who had joined, and costs the host their own place in the queue
--- for a mistake that takes one click to make.
---
--- WHAT IT WILL NOT CHANGE, and both refusals are about money and fairness
--- rather than difficulty:
---
---   The ENTRY FEE. Every player in the lobby has already paid the fee that
---   was advertised when they joined. Changing it afterwards either charges
---   them for something they did not agree to or hands the late joiners a
---   different deal to the early ones, and no amount of refunding and
---   re-taking makes that honest. A host who wants a different fee opens a
---   different lobby.
---
---   Anything at all once the round has STARTED. A match being fought is not
---   a form.
--- @param src any
--- @param data any -- { arenaKey?, modeKey?, lives?, radar? }
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.UpdateMatch(src, data)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end
    if type(data) ~= 'table' then return false, 'error.invalid_request' end

    local match = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.hostSource ~= target then return false, 'error.not_host' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    -- Everything is validated BEFORE anything is written, so a request that
    -- is half legal does not leave the match half changed.
    local arenaKey, modeKey, lives = match.arenaKey, match.modeKey, match.lives
    local radar = match.radar == true

    if data.arenaKey ~= nil then
        local arena = Arena.GetArenaByKey(data.arenaKey)
        if not arena then return false, 'error.arena_unavailable' end
        arenaKey = data.arenaKey
    end

    if data.modeKey ~= nil then
        local mode = Arena.GetModeByKey(data.modeKey)
        if not mode then return false, 'error.mode_unavailable' end
        modeKey = data.modeKey
    end

    if data.lives ~= nil then
        local resolved, reason = Arena.ResolveLives(data.lives)
        if not resolved then return false, reason end
        lives = resolved
    end

    if data.radar ~= nil then
        radar = Arena.ResolveRadar(data.radar)
    end

    -- A mode change can strand players on a team the new mode does not have,
    -- or leave them teamless in one that needs sides. Cleared rather than
    -- guessed at: the panel puts the team picker back in front of them, and
    -- CanStartMatch already refuses to start a team match with nobody sorted.
    local teamsChanged = modeKey ~= match.modeKey

    -- EVERY OUTSTANDING SIDE-BET GOES BACK when the mode changes.
    --
    -- A side-bet names a side: a team key in a team mode, a fighter's server
    -- id in a free-for-all. Change the mode and every bet already placed is
    -- picking something that cannot win any more -- a team key in a match
    -- with no teams -- so at settlement it simply loses. Not voided, not
    -- refunded: lost, with nothing on screen saying so and no way for the
    -- bettor to have seen it coming.
    --
    -- They backed a match that no longer exists in the shape they backed it
    -- in. They get their money and can back the one that replaced it.
    if teamsChanged then
        local returned, owed = ArenaBetting.ReturnSideBets(match.id)
        if returned > 0 then
            ArenaLog('betting: match %s changed mode, so %d side-bet(s) were returned unjudged.',
                tostring(match.id), returned)
        end
        if owed > 0 then
            ArenaLog('betting: match %s changed mode and %d of side-bets could not be returned -- they are still held.',
                tostring(match.id), owed)
        end
    end

    match.arenaKey = arenaKey
    match.modeKey = modeKey
    match.lives = lives
    match.radar = radar
    match.label = locale('match.label', match.hostName,
        (Arena.GetModeByKey(modeKey) or {}).label or modeKey)

    for _, player in pairs(match.players) do
        -- Applied to everybody, not only to those who join next. A lobby
        -- where the host changed the rules and half the room is still on the
        -- old ones is worse than not allowing the change at all.
        player.lives = lives
        if teamsChanged then player.team = nil end
    end

    ArenaLobby.Broadcast()
    return true, nil
end

-- ======================================================================
-- LOBBY CHOICES
-- ======================================================================

--- @param src any
--- @param teamKey any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.SetTeam(src, teamKey)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end
    if not Arena.ModeUsesTeams(match.modeKey) then return false, 'error.mode_has_no_teams' end
    if Config.Teams.allowChoose == false then return false, 'error.team_choice_disabled' end

    -- Switching has to name a side. Clearing one is not something the panel
    -- offers, and treating a missing key as "unpick me" would let a player
    -- dodge a full team by emptying their own.
    if not Arena.IsKey(teamKey) then return false, 'error.team_unavailable' end

    local team, reason = resolveTeam(match, teamKey, target)
    if reason then return false, reason end

    player.team = team
    ArenaLobby.Broadcast()
    return true, nil
end

--- @param src any
--- @param request any -- { weapons = { { key, ammo } }, armor }, straight off the wire
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.SetLoadout(src, request)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    -- ONE LOADOUT FOR THE WHOLE MATCH, when the operator asked for that.
    -- The panel greys the picker out for everyone but the host, but the
    -- panel is a suggestion and this is the rule: a crafted request from
    -- anyone else is refused here, not merely undrawn there.
    local hostPicks = Arena.LoadoutChooser() == 'host'
    if hostPicks and match.hostSource ~= target then
        return false, 'error.host_picks_loadout'
    end

    -- What is STORED is what Arena.ResolveLoadout allowed, never the
    -- request: the panel's copy is a preview, this one is handed out.
    local loadout, rejected = Arena.ResolveLoadout(type(request) == 'table' and request or nil)
    player.loadout = loadout

    -- A panel left open across a config change asks for weapons that are no
    -- longer there. Saying so costs a toast; staying quiet costs the player
    -- a gun they thought they had picked.
    if #rejected > 0 then
        ArenaNotifyKey(target, 'notify.loadout_rejected', 'warning', table.concat(rejected, ', '))
    end

    if hostPicks then
        -- Everyone gets the host's pick, including anyone who joined before
        -- it was made. Copied per player rather than shared by reference:
        -- gun game rewrites a player's loadout as they climb the ladder, and
        -- one shared table would climb it for the whole match at once.
        for _, other in pairs(match.players) do
            if other.src ~= target then
                other.loadout = (Arena.ResolveLoadout(request))
                pushState(other.src)
            end
        end
    end

    -- Nobody else's snapshot changed: a loadout is not in the match list.
    -- (In host mode the loop above has already told the ones that did.)
    pushState(target)
    return true, nil
end

--- @param src any
--- @param ready any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.SetReady(src, ready)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    -- With auto-assignment off an unpicked side blocks the start. This is
    -- the last moment the player is still looking at the team picker, so it
    -- is the kindest place to say so.
    if ready == true
        and Arena.ModeUsesTeams(match.modeKey)
        and not Arena.IsKey(player.team)
        and Config.Teams.autoAssignIfUnchosen == false then
        return false, 'error.pick_a_team'
    end

    player.ready = ready == true
    ArenaLobby.Broadcast()

    if player.ready and Config.Match.autoStartWhenAllReady == true then
        local roster = ArenaLobby.PlayerArray(match)
        local allReady = #roster > 0
        for _, entry in ipairs(roster) do
            if entry.ready ~= true then
                allReady = false
                break
            end
        end

        if allReady then
            local startable = Arena.CanStartMatch({
                arenaKey = match.arenaKey,
                modeKey = match.modeKey,
                players = roster,
            })
            if startable then
                -- ArenaMatch is defined by a file that loads AFTER this one.
                -- This line runs inside an event handler, long after every
                -- server file has finished loading, so the global is there --
                -- fxmanifest.lua's server_scripts note spells out why.
                --
                -- No requester: an auto-start is the server's, not a
                -- player's, so Config.Match.onlyHostCanStart has nothing to
                -- weigh it against.
                ArenaMatch.Begin(match.id, nil)
            end
        end
    end

    return true, nil
end

-- ======================================================================
-- SPECTATORS
-- ======================================================================

--- @param src any
--- @param matchId any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaLobby.AddSpectator(src, matchId)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end

    -- WHAT THIS REFUSES IS A FIGHTER, not merely a row in match.players. An
    -- eliminated player keeps their row -- the results board ranks off it --
    -- and they are exactly who the spectator camera exists for, so reading
    -- "already in a match" off playerIndex alone refused the one case
    -- server/match.lua calls this for. Watching any OTHER match is still
    -- refused whether they are out or not: being knocked out of your own
    -- round is not a pass into somebody else's.
    local attachedTo = playerIndex[target]
    if attachedTo and (attachedTo ~= match.id or not isEliminated(match, target)) then
        return false, 'error.already_in_match'
    end

    ArenaLobby.RemoveSpectator(target)      -- one match at a time
    match.spectators[target] = true
    spectatorIndex[target] = match.id

    -- INTO THE MATCH'S INSTANCE, which is what makes there be anything to
    -- watch.
    --
    -- Matches are fought in their own routing bucket -- that is the layer
    -- that keeps arena gunfire off the rest of the server -- and a spectator
    -- who is not put in it flies to the arena and finds an empty field. The
    -- camera worked, the server had them registered, the panel said
    -- "Watching": there was simply nobody there to see. That is what "the
    -- watch button does not work" looked like.
    --
    -- Idempotent for the case this is called from most: an eliminated player
    -- watching their own round is already in this bucket, and EnterBucket
    -- returns early rather than re-recording the arena as the bucket to
    -- restore them to.
    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.EnterBucket) == 'function' then
        ArenaDispatch.EnterBucket(target, match.id)
    end

    ArenaLobby.Broadcast()
    return true, nil
end

--- @param src any
--- @return boolean ok -- false when they were not watching anything
function ArenaLobby.RemoveSpectator(src)
    local target = tonumber(src)
    if not target then return false end

    local matchId = spectatorIndex[target]
    if not matchId then return false end

    spectatorIndex[target] = nil
    local match = matches[matchId]
    if match then match.spectators[target] = nil end

    -- AND BACK OUT, but only for somebody who was ONLY watching.
    --
    -- An eliminated player who stops watching is still in the round -- their
    -- row is what the results board ranks off -- and pulling them out of the
    -- instance here would drop them into the live world mid-match, on top of
    -- whoever happens to be standing there. Their exit runs on the match's
    -- own path, which is where it belongs.
    if not playerIndex[target]
        and type(ArenaDispatch) == 'table'
        and type(ArenaDispatch.ExitBucket) == 'function'
    then
        ArenaDispatch.ExitBucket(target)
    end

    ArenaLobby.Broadcast()
    return true
end

-- ======================================================================
-- IDLE LOBBY SWEEP
--
-- ONE thread for the whole registry, not one per match. A per-match thread
-- would spend its entire life asleep, would have to be cancelled from every
-- one of the four paths that end a match to stop it outliving its own
-- lobby, and would multiply by however many lobbies are open. This loop
-- costs the same whether there is one match or fifty.
-- ======================================================================

local SWEEP_INTERVAL_MS = 30000

local idleTimeout = math.max(0, Arena.ToInt(Config.Match.idleLobbyTimeoutSeconds) or 0)

-- 0 means never, and a thread that can never do anything is not worth
-- waking thirty seconds at a time for the life of the server.
if idleTimeout > 0 then
    CreateThread(function()
        while true do
            Wait(SWEEP_INTERVAL_MS)

            local now = os.time()
            local expired = {}

            for id, match in pairs(matches) do
                -- One ready player is the difference between a lobby that
                -- was abandoned and one that is waiting for its last joiner.
                if match.state == 'lobby'
                    and readyCount(match) == 0
                    and (now - match.createdAt) >= idleTimeout then
                    expired[#expired + 1] = id
                end
            end

            -- Collected first: Destroy edits the table being walked.
            for _, id in ipairs(expired) do
                ArenaLobby.Destroy(id, 'notify.lobby_timed_out')
            end
        end
    end)
end
