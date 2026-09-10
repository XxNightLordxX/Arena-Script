-- Crimson Arena: lobbies. Joining, leaving, teams, and readiness.

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

local matches = {}

local playerIndex = {}          -- [src] = matchId, for people PLAYING
local spectatorIndex = {}       -- [src] = matchId, for people WATCHING

local panelOpen = {}

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
        if not synchronous then ArenaLobby.Broadcast() end
    end)
    synchronous = false
end

function ArenaLobby.Get(matchId)
    if not Arena.IsKey(matchId) then return nil end
    return matches[matchId]
end

function ArenaLobby.GetByPlayer(src)
    local target = tonumber(src)
    if not target then return nil end
    local matchId = playerIndex[target]
    if not matchId then return nil end
    return matches[matchId]
end

function ArenaLobby.All()
    local out = {}
    for _, match in pairs(matches) do out[#out + 1] = match end
    table.sort(out, function(a, b)
        if a.createdAt ~= b.createdAt then return a.createdAt < b.createdAt end
        return a.id < b.id
    end)
    return out
end

function ArenaLobby.PlayerCount(match)
    if type(match) ~= 'table' then return 0 end
    return Arena.Count(match.players)
end

function ArenaLobby.PlayerArray(match)
    local out = {}
    if type(match) ~= 'table' then return out end
    for _, src in ipairs(match.order or {}) do
        local player = match.players[src]
        if player then out[#out + 1] = player end
    end
    return out
end

local function removeFromOrder(match, src)
    for index, entry in ipairs(match.order) do
        if entry == src then
            table.remove(match.order, index)
            return
        end
    end
end

local function hostLoadoutFor(match)
    if Arena.LoadoutChooser() ~= 'host' then return (Arena.ResolveLoadout(nil)) end

    local host = match.players and match.players[match.hostSource]
    if not host or type(host.loadout) ~= 'table' then return (Arena.ResolveLoadout(nil)) end

    return (Arena.ResolveLoadout(host.loadout))
end

--- Whether two resolved loadouts are the same kit.
---
--- BY VALUE, BECAUSE IDENTITY ANSWERS "DIFFERENT" EVERY TIME.
--- Arena.ResolveLoadout builds a fresh table on every call, so `old ~= new`
--- is true even when the player re-sent the pick they already hold -- which
--- is the only way a guard in ArenaLobby.SetLoadout could have been written
--- with `==`, and it would have guarded nothing. DO NOT reduce this to an
--- equality test.
---
--- Everything a resolved loadout holds is a string, a number, or an array of
--- those (Arena.ResolveWeaponEntry and Arena.ResolveSupplies build them), so
--- there are no cycles to walk and no metatables to respect.
--- @param a table|nil
--- @param b table|nil
--- @return boolean same
local function sameLoadout(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end

    for key, value in pairs(a) do
        if type(value) == 'table' then
            if not sameLoadout(value, b[key]) then return false end
        elseif value ~= b[key] then
            return false
        end
    end

    -- THE SECOND WALK IS NOT REDUNDANT AND MUST NOT BE DELETED: the first
    -- only proves every key of `a` is matched in `b`, and a `b` carrying an
    -- extra weapon passes that.
    for key in pairs(b) do
        if a[key] == nil then return false end
    end

    return true
end

local function findPlayer(src)
    local match = ArenaLobby.GetByPlayer(src)
    local player = match and match.players[src] or nil
    if not player then return nil, nil end
    return match, player
end

local function readyCount(match)
    local total = 0
    for _, player in pairs(match.players) do
        if player.ready == true then total = total + 1 end
    end
    return total
end

local function isEliminated(match, src)
    return Arena.IsEliminated(match.players[src])
end

local function playersArePlaced(match)
    for src in pairs(match.players) do
        if ArenaDispatch.IsPlayerInArena(src) then return true end
    end
    return false
end

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

    if Config.Teams.allowChoose == false then
        return Arena.SuggestTeam(roster), nil
    end

    local team = Arena.GetTeamByKey(teamKey)
    if not team then
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

local configBlock

local function ammoTypesFor(weapon)
    local out = {}
    for _, entry in ipairs(Arena.GetAmmoTypes(weapon)) do
        out[#out + 1] = { key = entry.key, label = entry.label }
    end
    return out
end

local function defaultAmmoTypeFor(weapon)
    local resolved = Arena.ResolveAmmoType(weapon, nil)
    return resolved and resolved.key or nil
end

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

    local supplyConfig = (Config.Loadouts or {}).supplies or {}
    local supplies = {
        enabled = supplyConfig.enabled == true,
        allowChoose = supplyConfig.allowChoose ~= false,
        totalItems = Arena.SupplyTotalCap(),
        items = {},
    }
    for _, entry in ipairs(Arena.GetEnabledSupplies()) do
        local maximum = Arena.SupplyMax(entry)
        supplies.items[#supplies.items + 1] = {
            key = entry.key,
            label = entry.label or entry.key,
            max = maximum,
            default = Arena.ClampInt(entry.default, 0, maximum) or 0,
            options = type(entry.options) == 'table' and entry.options or {},
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
            maxTeamSizeDifference = math.max(0, Arena.ToInt(Config.Teams.maxTeamSizeDifference) or 1),
            maxTeamSize = math.max(0, Arena.ToInt(Config.Teams.maxTeamSize) or 0),
            autoAssignIfUnchosen = Config.Teams.autoAssignIfUnchosen ~= false,
            requireBothTeamsOccupied = Config.Teams.requireBothTeamsOccupied ~= false,
            list = Arena.GetEnabledTeams(),
        },

        loadouts = {
            allowCustomAmmo = Config.Loadouts.allowCustomAmmo == true,
            chooser = Arena.LoadoutChooser(),
            -- ONE POOL, MIRRORED THE WAY THE RESOLVER READS IT -- including
            -- that zero means NO LIMIT, and that junk and negative fall back
            -- rather than clamping to zero. Two readers of one number with
            -- hand-copied defaults is how a panel comes to disagree with the
            -- server about what a player may carry, and the panel is the half
            -- the player believes.
            slots = Arena.SlotsPerPlayer(),
            allowFirearms = Config.Loadouts.allowFirearms ~= false,
            allowMelee = Config.Loadouts.allowMelee ~= false,
            ammoTypeSlots = math.max(0, Arena.ToInt(Config.Loadouts.ammoTypeSlots) or 0),
            categories = Config.Loadouts.categories or {},

            supplies = supplies,
            weapons = weapons,
        },

        betting = {
            enabled = ArenaBetting.IsEnabled(),
            currencySymbol = Config.Betting.currencySymbol,
            account = Config.Betting.account,
            payout = Config.Betting.payout,
            refundOnCancel = Config.Betting.refundOnCancel ~= false,
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
                oneBetPerMatch = spectator.oneBetPerMatch ~= false,
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
                    includeEntryPot = block.includeEntryPot == true,
                }
            end)(),
            fighterBets = {
                enabled = fighter.enabled == true,
                min = math.max(0, Arena.ToInt(fighter.min) or 0),
                max = math.max(0, Arena.ToInt(fighter.max) or 0),
                ownSideOnly = fighter.ownSideOnly ~= false,
                oneBetPerMatch = fighter.oneBetPerMatch ~= false,
            },
        },

        match = {
            minPlayers = math.max(1, Arena.ToInt(Config.Match.minPlayers) or 1),
            maxPlayers = math.max(0, Arena.ToInt(Config.Match.maxPlayers) or 0),
            maxConcurrentMatches = math.max(0, Arena.ToInt(Config.Match.maxConcurrentMatches) or 0),
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
            roundTimeSeconds = Arena.RoundTimeDefault(),
            roundTimeChoice = Arena.RoundTimeChoice(),
            winCondition = Arena.WinConditionDefault(),
            winConditionChoice = Arena.WinConditionChoice(),
            scoreLimit = Arena.ScoreLimitDefault(),
            scoreLimitChoice = Arena.ScoreLimitChoice(),
            onlyHostCanStart = Config.Match.onlyHostCanStart ~= false,
            autoStartWhenAllReady = Config.Match.autoStartWhenAllReady == true,
            defaultMode = Arena.IsKey(Config.DefaultMode) and Config.DefaultMode or nil,
            lobbyCountdownSeconds = math.max(0, Arena.ToInt(Config.Match.lobbyCountdownSeconds) or 0),
        },
    }
    return configBlock
end

local previewLoadout

local function loadoutPreview()
    if not previewLoadout then previewLoadout = (Arena.ResolveLoadout(nil)) end
    return previewLoadout
end

--- How many edits this server has refused each player, by src.
---
--- Not persisted and not keyed by citizen id on purpose: it exists to make
--- one browser re-read one lobby, and a reconnect gets a fresh form anyway.
local editRefusals = {}

function ArenaLobby.NoteEditRefused(src)
    local target = tonumber(src)
    if not target then return end
    editRefusals[target] = (editRefusals[target] or 0) + 1
end

function ArenaLobby.ForgetEditRefusals(src)
    local target = tonumber(src)
    if target then editRefusals[target] = nil end
end

local function snapshotPlayer(src)
    local match = ArenaLobby.GetByPlayer(src)
    local player = match and match.players[src] or nil

    local betOn = (match and match.id) or spectatorIndex[src] or nil

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
        bet = (betOn and ArenaBetting.GetSideBet(betOn, src)) or false,
        backing = ArenaBetting.MatchesBackedBy(src),
        isHost = match ~= nil and match.hostSource == src,
        -- HOW MANY OF THEIR EDITS THIS SERVER HAS TURNED DOWN.
        --
        -- The create/edit form is the second control in this panel that
        -- holds a DRAFT -- values that exist only in the browser until the
        -- server agrees -- and server/main.lua's note beside the loadout
        -- picker says why that matters: every other control renders straight
        -- off the snapshot, so a refusal leaves it showing what the server
        -- already holds. This one does not. It seeds once per lobby and then
        -- keeps whatever was typed, so a refused "Apply changes" left the
        -- form saying `most_kills` over a lobby still fought as
        -- `last_standing`, with the card next to it disagreeing and nothing
        -- saying which was real.
        --
        -- A COUNT RATHER THAN A FLAG, because the panel needs to notice a
        -- SECOND refusal as well as a first, and a boolean that is already
        -- true says nothing when it is set again.
        editRefused = editRefusals[src] or 0,
    }
end

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
                alive = not isEliminated(match, player.src),
                isHost = player.src == match.hostSource,
            }
        end

        out[#out + 1] = {
            id = match.id,
            label = match.label,
            arenaKey = match.arenaKey,
            betsOpen = ArenaBetting.BetsAreOpen(match),
            fighterBetsOpen = ArenaBetting.FighterBetsAreOpen(match),
            sizeFactor = match.sizeFactor,
            arenaLabel = arena and arena.label or match.arenaKey,
            modeKey = match.modeKey,
            modeLabel = mode and mode.label or match.modeKey,
            teams = Arena.ModeUsesTeams(match.modeKey),
            hostId = match.hostSource,
            hostName = match.hostName,
            state = match.state,
            entryFee = match.entryFee,
            lives = match.lives,
            radar = match.radar == true,
            roundTimeSeconds = Arena.RoundSecondsFor(match.modeKey, match.roundTimeSeconds),
            winCondition = Arena.WinConditionFor(match.winCondition),
            livesSpent = Arena.WinConditionSpendsLives(match.winCondition),
            scoreLimit = Arena.ScoreLimitFor(match.scoreLimit),
            tierPlan = match.tierPlan,
            pot = ArenaBetting.GetPrizePool(match.id),
            entryPot = ArenaBetting.GetPot(match.id),
            betPool = ArenaBetting.GetSideBetPool(match.id),
            bets = ArenaBetting.CountSideBets(match.id),
            playerCount = #roster,
            teamCounts = Arena.CountTeams(roster),
            startsAt = match.startsAt,
            players = players,
        }
    end

    return out
end

--- Who is currently standing behind a keep-out fence this server put up.
---
--- THE FENCE IS THE ONE PIECE OF STATE THAT OUTLIVES ITS RECIPIENT SET, and
--- that is what makes this table necessary rather than tidy. A client is told
--- about the fence inside a state push, and it holds that list until the next
--- push replaces it -- so the list has to be taken down by a push as much as
--- it was put up by one, and a player it was put up for must not stop being
--- a recipient before that second push.
---
--- IN THE OWNER'S WORDS: "after the match is over ... if i jump it immediatly
--- sends me to the ground ... as its still registering that". He was: the set
--- below is players with the panel open plus players in a match, and a man
--- who has just walked out of a round with the panel shut is in neither. So
--- the last list he was ever sent -- a circle round an arena somebody else
--- was fighting in -- stayed live on his client for the rest of the session,
--- and the barrier loop in client/match.lua went on teleporting him to its
--- rim and dropping him on the ground every time he walked inside it, for a
--- match that had ended an hour earlier. Measured end to end: after his round
--- finished, not one further state push reached him, ever.
---
--- So anybody the last push actually fenced stays a recipient until a push
--- tells them the fence is down, and then stops being one. That is at most
--- one extra snapshot per fenced player per change, and only for players who
--- really are fenced.
local fenceHeld = {}

--- Records what the fence the caller is about to send says, so the entry can
--- be dropped the moment it goes empty.
---
--- Called from snapshotKeepOut rather than from the send sites because there
--- are three of those -- Broadcast, pushState and server/main.lua's answer to
--- requestState -- and every one of them gets its list from that one
--- function. A fourth added later cannot forget.
--- @param id integer
--- @param zones table[]
local function rememberFence(id, zones)
    -- A nil key is a raise in Lua, not a no-op, and snapshotKeepOut is
    -- reached with whatever src its caller was given.
    if not id then return end
    fenceHeld[id] = (#zones > 0) or nil
end

local function recipients()
    local targets = {}

    for src in pairs(panelOpen) do
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

    -- Pruned the same way panelOpen is, and for the same reason: a player who
    -- has gone must not be a permanent entry in a table nothing else clears.
    for src in pairs(fenceHeld) do
        if Arena.IsKey(GetPlayerName(src)) then
            targets[src] = true
        else
            fenceHeld[src] = nil
        end
    end

    return targets
end

local function pushState(src)
    TriggerClientEvent('crimson_arena:client:state', src, ArenaLobby.BuildState(src))
end

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
    local id = tonumber(src)

    local barrier = (Config.Match or {}).keepOutBarrier
    if type(barrier) ~= 'table' or barrier.enabled ~= true then
        -- An operator who switches the barrier off mid-session has to be able
        -- to take down the fences already standing on people's clients, so
        -- this leaves through the same bookkeeping as every other answer.
        rememberFence(id, {})
        return {}
    end

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

    local watching = spectatorIndex[id]
    if watching then
        local match = matches[watching]
        if match and Arena.IsKey(match.arenaKey) then
            mine[match.arenaKey] = true
        end
    end

    local zones, drawn = {}, {}

    for _, match in pairs(matches) do
        if match.state == 'live' and not mine[match.arenaKey] and not drawn[match.arenaKey] then
            local arena = Arena.GetArenaByKey(match.arenaKey)
            local boundary = Arena.BoundaryOf(arena)

            -- The BOUNDARY is the fence, deliberately -- the same circle the
            -- fighters themselves are bled for leaving. One arena has one
            -- edge, and two different ones would be a question with two
            -- answers on the same field.
            if boundary and boundary.center then
                local factor = math.max(1.0, tonumber(match.sizeFactor) or 1.0)
                local radius = (tonumber(boundary.radius) or 0) * factor
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

    rememberFence(id, zones)
    return zones
end

function ArenaLobby.PushState(src)
    local target = tonumber(src)
    if not target then return end
    pushState(target)
end

function ArenaLobby.BuildState(src)
    refreshLeaderboard()
    return {
        config = snapshotConfig(),
        player = snapshotPlayer(src),
        matches = snapshotMatches(),
        leaderboard = leaderboard,
        keepOut = snapshotKeepOut(src),
        schedule = ArenaHoursSnapshot(),
    }
end

function ArenaLobby.Broadcast()
    refreshLeaderboard()

    local config = snapshotConfig()
    local matchList = snapshotMatches()
    local rows = leaderboard
    local schedule = ArenaHoursSnapshot()

    for src in pairs(recipients()) do
        TriggerClientEvent('crimson_arena:client:state', src, {
            config = config,
            player = snapshotPlayer(src),
            matches = matchList,
            leaderboard = rows,
            keepOut = snapshotKeepOut(src),
            schedule = schedule,
        })
    end
end

function ArenaLobby.MarkPanelOpen(src)
    local target = tonumber(src)
    if not target then return false end
    panelOpen[target] = true
    return true
end

function ArenaLobby.MarkPanelClosed(src)
    local target = tonumber(src)
    if not target then return false end
    panelOpen[target] = nil
    return true
end

function ArenaLobby.Create(src, arenaKey, modeKey, entryFee, lives, radar, account, roundTime,
    winCondition, tierPlan, scoreLimit)
    local host = tonumber(src)
    if not host then return nil, 'error.invalid_request' end
    if not ArenaCanCreate(host) then return nil, 'error.no_permission' end
    if playerIndex[host] then return nil, 'error.already_in_match' end

    local arena = Arena.GetArenaByKey(arenaKey)
    if not arena then return nil, 'error.arena_unavailable' end

    local wantedMode = Arena.IsKey(modeKey) and modeKey or Config.DefaultMode
    local mode = Arena.GetModeByKey(wantedMode)
    if not mode then return nil, 'error.mode_unavailable' end

    local ceiling = Arena.ToInt(Config.Match.maxConcurrentMatches) or 0
    if ceiling > 0 and Arena.Count(matches) >= ceiling then
        return nil, 'error.too_many_matches'
    end

    local fee = 0
    if ArenaBetting.IsEnabled() then
        local amount, reason = Arena.ResolveEntryFee(entryFee)
        if not amount then return nil, reason end
        fee = amount
    end

    local resolvedLives, livesReason = Arena.ResolveLives(lives)
    if not resolvedLives then return nil, livesReason end

    local resolvedRadar = Arena.ResolveRadar(radar)

    local resolvedRound, roundReason = Arena.ResolveRoundTime(roundTime)
    if not resolvedRound then return nil, roundReason end

    local resolvedWin, winReason = Arena.ResolveWinCondition(winCondition)
    if not resolvedWin then return nil, winReason end

    if not Arena.PlaysLadder(wantedMode)
        and Arena.WinConditionNeedsClock(resolvedWin)
        and Arena.RoundSecondsFor(wantedMode, resolvedRound) <= 0
    then
        return nil, 'error.win_condition_needs_clock'
    end

    local resolvedTiers, tierReason = Arena.ResolveTierPlan(wantedMode, tierPlan)
    if tierReason then return nil, tierReason end

    local resolvedLimit, limitReason = Arena.ResolveScoreLimit(scoreLimit)
    if not resolvedLimit then return nil, limitReason end

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
        lives = resolvedLives,
        radar = resolvedRadar,
        roundTimeSeconds = resolvedRound,
        winCondition = resolvedWin,
        -- THE SHAPE OF THIS MATCH'S LADDER, or nil for the mode's own. Read
        -- by `ladderOf` when the round draws its weapons, and stored for the
        -- same reason `lives` is: an operator switching a weapon class off
        -- mid-session must not reshape a lobby that is already open.
        tierPlan = resolvedTiers,
        scoreLimit = resolvedLimit,
        createdAt = os.time(),
        startsAt = 0,
        endsAt = 0,
        players = {},
        order = {},
        spectators = {},
    }

    local ok, reason = ArenaLobby.Join(host, id, nil, account)
    if not ok then
        matches[id] = nil
        return nil, reason
    end

    ArenaLog('%s created match %s (%s / %s, fee %d)', hostName, id, arenaKey, wantedMode, fee)
    return id, nil
end

function ArenaLobby.Join(src, matchId, teamKey, account)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    if not ArenaCanJoin(target) then return false, 'error.no_permission' end

    if not ArenaHoursOpen() then return false, 'error.arena_shut' end

    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end
    if playerIndex[target] then return false, 'error.already_in_match' end

    if not Arena.HasRoom(ArenaLobby.PlayerCount(match)) then return false, 'error.match_full' end

    local qbx = ArenaGetPlayer(target)
    local data = qbx and qbx.PlayerData
    if not data or not Arena.IsKey(data.citizenid) then return false, 'error.player_not_loaded' end

    local blocked = entryBlocked(target, data)
    if blocked then return false, blocked end

    local team, teamReason = resolveTeam(match, teamKey, nil)
    if teamReason then return false, teamReason end

    -- WATCHING AND BACKING ARE ONE CHOICE, AND THE FEE HAS NOTHING TO DO
    -- WITH IT.
    --
    -- ArenaBetting.TakeStake carries this same refusal, and says why: a bet
    -- its holder can cancel at a moment of their choosing -- by joining and
    -- walking straight out again -- is a bet with no risk in it. But Join
    -- only reaches TakeStake when the match has an entry fee, and the
    -- shipped default fee is ZERO. So on the commonest configuration there
    -- is a documented guard that nothing ever runs, and backing a match then
    -- taking a seat in it was free.
    --
    -- REFUSED IN THE WORDS OF THE THING THEY DID. This used to answer
    -- 'error.bet_not_spectator' -- "Fighters do not bet on themselves." --
    -- which describes the OTHER half of the rule, the one betting.lua
    -- enforces when a fighter tries to bet. Read after clicking Join it
    -- names an action the player did not take and a reason that is not
    -- theirs.
    if ArenaBetting.IsEnabled() and ArenaBetting.HoldsSideBet(match.id, target) then
        return false, 'error.bet_then_join'
    end

    local stake = 0
    if ArenaBetting.IsEnabled() and match.entryFee > 0 then
        local taken, reason = ArenaBetting.TakeStake(target, match.id, match.entryFee, account)
        if not taken then return false, reason or 'error.stake_failed' end
        stake = ArenaBetting.GetStake(match.id, target)
    end

    ArenaLobby.RemoveSpectator(target)

    match.players[target] = {
        src = target,
        citizenid = data.citizenid,
        name = ArenaPlayerName(target),
        team = team,
        ready = false,
        loadout = hostLoadoutFor(match),
        kills = 0,
        deaths = 0,
        alive = true,
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

--- Whether this player may take themselves out of the match they are in.
---
--- YOU DO NOT TAKE YOUR OWN MONEY OFF THE TABLE BY STANDING UP.
---
--- The mirror of the 'error.bet_then_join' rule ArenaLobby.Join enforces a
--- hundred lines up, for the reason that one states: a bet its holder can
--- cancel at a moment of their choosing is a bet with no risk in it. Joining
--- a match you have backed was already refused; LEAVING one you have backed
--- was not, and it is the same trade run backwards.
---
--- WHAT IT COST. fighterBets.max ships at twice spectatorBets.max, so a
--- fighter took a 50,000 position on their own side, walked out for nothing
--- -- the shipped entry fee is zero -- and settled it against a field nobody
--- watching could put more than 25,000 into. Their side won without them and
--- they collected the honest spectator's whole stake.
---
--- HoldsSideBet, not a check for a FIGHTER bet specifically, and the two are
--- the same set: Join refuses a seat to anybody already holding a bet on this
--- match, so a bet held by somebody on the roster can only have been placed
--- from inside it. Asking the narrower question would be a second copy of
--- Join's rule, worded differently, for no gain.
---
--- TWO NARROWINGS, BOTH LOAD-BEARING, NEITHER OF THEM TIMIDITY:
---
---   A DISCONNECT CANNOT BE REFUSED. The player is already gone; holding
---   their row would leave a ghost on the roster, a routing bucket set, a
---   dispatch flag suppressing their police and medical alerts for the rest
---   of the session, and a stake nobody can reach. So a drop always goes
---   through, and the money side of it is closed where it still can be:
---   ArenaBetting.MarkWalkedOut trims the stake down to what a non-fighter
---   may hold and hands the difference back. That leaves ONE thing a
---   determined player can still buy by pulling their own connection --
---   getting the over-band part of a losing bet returned -- and it is worth
---   exactly `fighterBets.max` minus `spectatorBets.max`. An operator who
---   wants it to be worth nothing sets those two equal.
---
---   A FIGHT IS NOT A ROOM ANYBODY MAY BE LOCKED IN. There is no
---   cancel-a-bet path anywhere in this resource, so this refusal has no
---   release valve; applied to a live round it would mean a player standing
---   in an arena being shot at, clicking Leave, and being told no. That is a
---   worse defect than the one being fixed.
---
--- SO IT COVERS THE LOBBY AND THE COUNTDOWN, and the countdown is not
--- padding: without it the whole rule is worth fifteen seconds of patience.
--- Bet, wait for the host to press Start, and leave during the ten-second
--- lobby countdown or the five-second frozen one -- the stake comes back
--- before start either way and the trim hands over the difference. A
--- countdown is also the one window where being held is no hardship: it ends
--- in the round they backed, by itself, in seconds.
---
--- WHAT THE HELD PLAYER CAN DO, because a refusal that names no action is
--- worse than none: sit the round out, or have the lobby closed. Every way a
--- lobby ends -- the host's own Close Lobby, the idle sweep at
--- idleLobbyTimeoutSeconds, an admin stop -- runs ArenaLobby.Destroy, whose
--- Clear hands back every unsettled side-bet whatever refundOnCancel says.
--- Nobody is held for longer than the lobby lives.
--- @param src any
--- @param dropped boolean? -- their connection went away; never refused
--- @return boolean may
--- @return string|nil reasonKey
--- @param ejected boolean? -- the SERVER took them out; never refused either
function ArenaLobby.MayLeave(src, dropped, ejected)
    local target = tonumber(src)
    if not target or dropped == true or ejected == true then return true end

    local match = findPlayer(target)
    if not match then return true end
    if match.state ~= 'lobby' and match.state ~= 'countdown' then return true end

    if ArenaBetting.IsEnabled() and ArenaBetting.HoldsSideBet(match.id, target) then
        return false, 'error.bet_then_leave'
    end

    -- AND THE SECOND REFUSAL, WHICH IS NOT ABOUT MONEY AT ALL: ONE PLAYER
    -- MUST NOT BE ABLE TO CALL OFF EVERY ROUND ON THE SERVER.
    --
    -- ArenaMatch.Begin's countdown thread re-runs Arena.CanStartMatch once a
    -- second and puts the match back to 'lobby' the moment it fails, so
    -- anybody the roster still needs cancels the start by standing up: the
    -- second body under Config.Match.minPlayers, or -- with
    -- Config.Teams.requireBothTeamsOccupied on, which is what ships -- the
    -- sole occupant of one side of a 3v1. The entry fee comes back in full on
    -- this path (refundOnDisconnectBeforeStart ships true), so they rejoin a
    -- second later and do it again, free, for as long as they like. The bet
    -- rule above refuses exactly that trade, but only to somebody holding a
    -- side-bet, and a griefer holds none.
    --
    -- `placed ~= true` LEAVES THE FROZEN WINDOW ALONE, ON PURPOSE, and that
    -- is the whole care in this line. 'countdown' is two states wearing one
    -- name -- the forfeit rule in ArenaLobby.Leave below sets both out -- and
    -- the second of them, after ArenaMatch.Start has teleported the roster
    -- in, is a round being fought. Walking out of THAT is the settled rule
    -- tests/countdownexit_spec.lua covers, money and all, and it is not
    -- touched here. A live round is not touched either: the state test above
    -- has already returned true for it before this line is reached.
    --
    -- WHAT THE HELD PLAYER CAN DO, because a refusal that names no action is
    -- worse than none: the countdown is ten seconds and ends by itself, the
    -- host's Cancel Start puts the whole room back in the lobby, and a
    -- disconnect is never refused.
    if match.state == 'countdown' and match.placed ~= true then
        return false, 'error.match_in_progress'
    end

    return true
end

function ArenaLobby.Leave(src, reasonKey, dropped, ejected)
    local target = tonumber(src)
    if not target then return false end

    local match, player = findPlayer(target)
    if not match then
        -- A stale index, if one ever happened, must not outlive the leave
        -- that found it.
        playerIndex[target] = nil
        return ArenaLobby.RemoveSpectator(target)
    end

    local may, refusal = ArenaLobby.MayLeave(target, dropped, ejected)
    if not may then return false, refusal end

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
    -- A ROUND BEING FOUGHT, which is a narrower thing than `started` below.
    -- Both the leaderboard rule and the announcement further down turn on
    -- it, and they must agree: a fighter told somebody walked out is being
    -- told about a round the walker was recorded as losing.
    --
    -- AND `countdown` IS TWO DIFFERENT STATES WEARING ONE NAME. A lobby
    -- counting down has nobody on the ground; a match in its FREEZE, after
    -- ArenaMatch.Start has teleported the whole roster in, is a round being
    -- fought that has not been promoted to `live` yet. Reading the name
    -- alone made those the same thing, and the five seconds between them
    -- were a free look at the arena: closing the game inside that window
    -- returned the stake in full, recorded no loss, and told the fighters
    -- standing there watching somebody vanish nothing at all -- while the
    -- same act one second later forfeited everything.
    --
    -- READ OFF THE MATCH, not off the dispatch. Asking
    -- ArenaDispatch.IsPlayerInArena looks like the right question and always
    -- answers no here: ArenaMatch.RemovePlayer sends the leaver home -- which
    -- clears that very flag -- several lines before it calls this function.
    -- `match.placed` is set by ArenaMatch.Start when the roster is teleported
    -- in, and nothing clears it.
    local placed = match.state == 'countdown' and match.placed == true

    local liveRound = match.state == 'live' or placed

    -- STILL IN THE FIGHT WHEN THEY WENT, which is not the same as "the round
    -- was live". An eliminated fighter KEEPS their row on purpose -- the
    -- results board ranks off it, and with spectateOnElimination off
    -- server/match.lua has already sent them home -- so they can reach this
    -- function minutes after they stopped being a contestant.
    --
    -- Both rules below turn on it, and each was wrong without it:
    --
    --   THE RECORD. Sparing a crash is for somebody whose game died while
    --   they were still fighting. A player who was already knocked out has
    --   lost the round either way, so sparing them there let anyone erase
    --   their loss by closing the game after being eliminated -- exactly the
    --   hole the quit rule exists to shut, reopened from the other side.
    --
    --   THE ANNOUNCEMENT. "walked out of the fight" about somebody who was
    --   knocked out four minutes ago is just wrong.
    --
    -- RemovePlayer sets alive = false before it gets here, so `alive` alone
    -- cannot answer this; lives is what separates a fighter on the floor
    -- waiting to respawn from one who is out for good.
    local wasFighting = liveRound and not Arena.IsEliminated(player)

    local started = match.state == 'live' or match.state == 'ended' or placed
    local refund
    if started then
        refund = Config.Betting.refundOnDisconnectDuringMatch == true
    else
        refund = Config.Betting.refundOnDisconnectBeforeStart ~= false
    end

    if player.stake > 0 then
        if refund then
            ArenaBetting.RefundOne(match.id, target, reasonKey or 'bet.refund_left')
        else
            ArenaBetting.KeepInPot(match.id, target)
        end
    end

    local leftTeam = Arena.IsKey(player.team) and player.team or nil

    local leftName = player.name

    -- A ROUND WALKED OUT OF IS A ROUND LOST.
    --
    -- The leaderboard only ever saw players who were still on the roster
    -- when the round ENDED -- ArenaStats.RecordMatch walks match.players,
    -- and the line below is what takes this one out of it. So quitting a
    -- round you were losing cost you nothing on the board: no loss, and the
    -- kills and deaths you had already taken vanished with you.
    --
    -- That is the one penalty that was missing. The stake is already
    -- forfeited to the pot on this exact path (refundOnDisconnectDuringMatch
    -- ships false), and config.lua's reasoning for not separating a quit
    -- from a crash applies here word for word: a rule that recorded only
    -- deliberate quits would take a loss from the players whose game crashed
    -- and clear it for the ones who left on purpose. Applied evenly.
    --
    -- 'live' AND NOT `started`, which is the money predicate one branch up
    -- and covers 'ended' as well. ArenaMatch.End sets 'ended' before it
    -- calls RecordMatch, so a disconnect arriving in that window would be
    -- recorded here AND there. A round that has not gone live yet records
    -- nothing at all, which is the same answer its stake gets: handed back,
    -- nothing happened.
    --
    -- AND NOT A DROP. The money above deliberately does NOT separate a quit
    -- from a crash, and says why: charging only genuine disconnects would
    -- take the stake from the player whose game died and hand it back to the
    -- one who quit on purpose. The leaderboard is the opposite call, and it
    -- is made deliberately rather than by oversight -- a loss follows you
    -- for the life of the server, so somebody whose game crashed should not
    -- wear one. The stake still goes; only the record is spared.
    --
    -- The two rules therefore disagree ON PURPOSE, and that is the thing to
    -- keep in mind before "tidying" either of them into the other.
    --
    -- HERE rather than in ArenaMatch.RemovePlayer because this is the only
    -- place both exits meet: server/main.lua routes playerDropped straight
    -- through this function, and it never touches RemovePlayer at all.
    -- AND AN EJECTION IS NOT A CRASH, WHICH IS WHY `ejected` IS HERE AT ALL.
    --
    -- The rule above spares a dropped fighter's record because a crash is not
    -- something they chose. Config.Match.serverChecks removing somebody for
    -- standing outside the arena for eight seconds running is the opposite:
    -- it is the one exit that is entirely their doing, and it is aimed at a
    -- player parked out of the fight waiting to be the last one left.
    --
    -- It has to travel as `dropped` everywhere else -- that is what gets it
    -- past MayLeave's refusal and onto the forfeit rule, both of which are
    -- right for it -- so without this flag the fence would have been the one
    -- way to walk out of a round you are losing with no defeat on the board.
    if liveRound and not (dropped and wasFighting and not ejected)
        and type(ArenaStats) == 'table' and type(ArenaStats.Record) == 'function'
    then
        ArenaStats.Record({
            citizenid = player.citizenid,
            name = player.name,
            won = false,
            kills = player.kills,
            deaths = player.deaths,
            earnings = 0,
        })
    end

    -- THEIR KILLS STAY WITH THEIR SIDE.
    --
    -- The row is deleted on purpose -- a leaver must not be crowned, and
    -- every winner-selection path walks `match.players`. But a TEAM's score
    -- is the sum of its members' kills, so deleting the row took the kills
    -- out of the team total as well: a fighter who scored six for their side
    -- and then rage-quit HANDED THE ROUND to the other one, and the pot with
    -- it. That is a button anybody can press.
    --
    -- Banked per side rather than kept on the row, because the row is what
    -- must not survive. Only in a team mode: in a free-for-all a departed
    -- player's kills belong to nobody, and there is no side for them to be
    -- credited to.
    if liveRound and Arena.ModeUsesTeams(match.modeKey) and Arena.IsKey(player.team) then
        match.departedKills = match.departedKills or {}
        match.departedKills[player.team] = (match.departedKills[player.team] or 0)
            + math.max(0, Arena.ToInt(player.kills) or 0)
    end

    match.players[target] = nil
    playerIndex[target] = nil
    removeFromOrder(match, target)

    -- AND TELL THE PEOPLE STILL FIGHTING.
    --
    -- The roster on their scoreboard just got shorter and nothing said why.
    -- en.json has carried "A fighter dropped out." since before this, on a
    -- key that is only ever passed around as a REASON IDENTIFIER -- stored
    -- against the refund, written to the log, rendered for nobody. These are
    -- separate keys on purpose: the reason keys keep their exact meaning and
    -- their exact argument count, and Destroy still renders one of them on
    -- the paths where a match closes under people.
    --
    -- MID-ROUND ONLY. In a lobby the roster is visibly churning anyway and
    -- a toast per person coming and going is noise; in a live round a
    -- fighter vanishing changes what is left to beat.
    --
    -- Sent AFTER the row is removed, so the leaver is not told about
    -- themselves, and to the fighters rather than the spectators: it is the
    -- people whose round just changed shape who need it.
    if wasFighting and Arena.IsKey(leftName) then
        local key = 'notify.fighter_left'
        if ejected then
            key = 'notify.fighter_ejected'
        elseif dropped then
            key = 'notify.fighter_dropped'
        end
        for remaining in pairs(match.players) do
            ArenaNotifyKey(remaining, key, 'warning', leftName)
        end
    end

    -- ANYBODY WHO BACKED THEM GETS THEIR MONEY BACK.
    --
    -- A side-bet names a side: a team key in a team mode, this player's
    -- server id in a free-for-all. Walking out makes that pick unwinnable,
    -- and an unwinnable pick does not go back on its own -- it falls through
    -- every branch of SettleSpectatorBets to the last one and is marked
    -- LOST, paying the spectator's whole stake to whoever backed the winner.
    -- The uncontested-pool refund cannot catch it either: on the shipped
    -- config the survivors' own entry fees are in that pool, so it is
    -- contested by definition.
    --
    -- UpdateMatch has done this for a mode change since the day it was
    -- written, for the identical reason, and says so at length. This is the
    -- same event arriving by the other door.
    --
    -- A TEAM PICK ONLY DIES WITH THE LAST PLAYER ON IT. One of four leaving
    -- a 2v2 leaves crimson perfectly able to win, and returning the bets on
    -- it would be handing money back on a wager that is still live.
    -- THEIR OWN BETS ARE THEIRS TO LOSE, and this has to run BEFORE the
    -- return below or it cannot. A fighter backing themselves picks their own
    -- server id, so their bet names the same pick a spectator's bet on them
    -- does; without this line, walking out cancels a wager that was going
    -- badly and hands the money back. fighterBets ships on.
    --
    -- AND ONLY BEFORE THE ROUND IS FOUGHT. This is the whole of it, and
    -- returning a live round's bets was a FREE OPTION with somebody else's
    -- money in it.
    --
    -- The rule reads fairly: your pick vanished through no fault of yours,
    -- so you get your stake back. Split the two roles and it stops being
    -- fair. A colluder backs an accomplice for the ceiling. The accomplice
    -- holds no bet, so MayLeave -- which refuses a fighter who HOLDS one --
    -- never looks at them. If the accomplice is winning they play on and the
    -- pair take a share; if the accomplice is losing they press Leave and
    -- the whole stake comes back, unjudged, at any moment of the round,
    -- INCLUDING after they have already been eliminated and long after the
    -- book has shut. Never a loss, on a free-entry lobby costing nothing,
    -- and holdable on every open match at once.
    --
    -- So a departure from a round being fought settles the bets on that pick
    -- the way it settles the leaver's own stake: kept. Which is the rule the
    -- entry fee has always had, for the reason written above it -- and it
    -- deliberately does not separate a quit from a crash, because charging
    -- only the genuine disconnects takes money from the player whose game
    -- died and hands it to the one who quit on purpose.
    --
    -- Before the round is live, nothing has been fought and the return is
    -- exactly right: the pick left a queue, not a fight.
    --
    -- AND IN A LOBBY TOO, WHICH LOOKS HARSH AND IS NOT. It was put behind
    -- `started` for a while on the reasoning that nothing can be going badly
    -- in a round nobody has fought -- but the wager is on the FIELD, and the
    -- field is what changes while a lobby fills. A fighter who backs
    -- themselves for the fighterBets ceiling -- twice the spectator one --
    -- and then watches somebody far better walk in has a wager going badly
    -- before a shot is fired, and closing the game would be the way out of
    -- it. Standing up is already refused for the same reason (see MayLeave),
    -- so sparing the drop would leave one door open and the other shut.
    ArenaBetting.MarkWalkedOut(match.id, target)

    if leftTeam then
        -- THROUGH PlayerArray, LIKE THE OTHER TWO CALLERS, and not because it
        -- reads better. Arena.CountTeams walks its argument with `ipairs`,
        -- and `match.players` is keyed by SERVER ID -- so on a live server,
        -- where the lowest id in a lobby is rarely 1, ipairs stops at the
        -- first index and counts nothing. Every side would then read as
        -- empty, and this guard -- the one whose whole job is to keep a live
        -- team's bets alive -- would hold open for any single departure.
        --
        -- It passed its own test because the fixture numbered its players
        -- 1..5, which is the one roster shape where ipairs over a src-keyed
        -- map is right. Same trap as the slot-keyed inventory read in
        -- server/ammo.lua, sprung the same way, one file over.
        local remaining = Arena.CountTeams(ArenaLobby.PlayerArray(match))
        if (remaining[leftTeam] or 0) == 0 and not started then
            local returned, owed = ArenaBetting.ReturnBetsOn(match.id, leftTeam)
            if returned > 0 then
                ArenaLog('betting: the last player on "%s" left match %s, so %d side-bet(s) on that side were returned unjudged.',
                    tostring(leftTeam), tostring(match.id), returned)
            end
            if owed > 0 then
                ArenaLog('betting: %d of side-bets on "%s" could not be returned on match %s -- they are still held.',
                    owed, tostring(leftTeam), tostring(match.id))
            end
        end
    elseif not started then
        local returned, owed = ArenaBetting.ReturnBetsOn(match.id, tostring(target))
        if returned > 0 then
            ArenaLog('betting: %s left match %s, so %d side-bet(s) backing them were returned unjudged.',
                tostring(target), tostring(match.id), returned)
        end
        if owed > 0 then
            ArenaLog('betting: %d of side-bets backing %s could not be returned on match %s -- they are still held.',
                owed, tostring(target), tostring(match.id))
        end
    end

    if spectatorIndex[target] == match.id then
        spectatorIndex[target] = nil
        match.spectators[target] = nil
    end

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

function ArenaLobby.Destroy(matchId, reasonKey)
    local match = ArenaLobby.Get(matchId)
    if not match then return false end

    local notice = Arena.IsKey(reasonKey) and reasonKey or 'notify.match_closed'

    ArenaBetting.RefundAll(match.id, notice)
    ArenaBetting.Clear(match.id)

    for src in pairs(match.players) do
        if ArenaDispatch.IsPlayerInArena(src) then
            ArenaAmmo.Reclaim(src, 'match closed')

            ArenaDispatch.Clear(src)
            ArenaDispatch.ExitBucket(src)
            TriggerClientEvent('crimson_arena:client:exitArena', src, {})
        end

        playerIndex[src] = nil

        if match.state ~= 'ended' then
            ArenaNotifyKey(src, notice, 'warning')
        end
    end
    for src in pairs(match.spectators) do
        spectatorIndex[src] = nil

        if not match.players[src] then
            -- THE EXIT GOES WHATEVER THE BUCKET SAYS, AND THE BUCKET DOES
            -- NOT GET A VOTE ON IT.
            --
            -- This was an EXISTENCE check -- `type(ExitBucket) == 'function'`
            -- -- whose VALUE was then used as the send condition, and
            -- ExitBucket answers false for anybody it was never given. With
            -- Config.Dispatch.isolation.enabled off, GetBucket returns nil and
            -- EnterBucket recorded nothing, so that is EVERY spectator on such
            -- a server: not one of them was ever told the match had gone.
            -- Camera locked on a match that no longer exists, ped invisible
            -- and frozen, for the rest of the session.
            --
            -- The Broadcast at the foot of this function CANNOT stand in for
            -- it: it carries no exit, and `matches[match.id]` is cleared
            -- before it runs, so recipients() no longer counts a spectator
            -- with no panel open.
            --
            -- SAFE FOR A WATCHER WHO WAS NEVER MOVED ANYWHERE: client/
            -- match.lua's leaveArena returns at `not currentMatch` before it
            -- teleports or strips anything, and client/spectate.lua's handler
            -- -- the one that matters here -- only stops the camera.
            --
            -- ArenaMatch.End and ArenaMatch.Abort both send theirs
            -- unconditionally through sendExitArena; Destroy was the odd one
            -- out. DO NOT gate this on ExitBucket again.
            --
            -- `state ~= 'ended'` IS NOT THAT GATE COMING BACK. It is the
            -- SAME question the notify six lines up asks, for the same
            -- reason: End and Abort are the only two callers that set
            -- 'ended', they both set it BEFORE their own spectator loop, and
            -- they have therefore already sent this exit -- with the results
            -- board and the return point on it, which this bare one has not
            -- got. Every other way in here (Cancel, the idle sweep,
            -- CloseWaitingLobbies, the last player leaving) arrives at
            -- 'lobby', 'countdown' or 'live', where nobody has sent anything.
            -- Asking the bucket was what made this dedupe work, and it only
            -- worked while isolation was on.
            if type(ArenaDispatch) == 'table' and type(ArenaDispatch.ExitBucket) == 'function' then
                ArenaDispatch.ExitBucket(src)
            end

            if match.state ~= 'ended' then
                TriggerClientEvent('crimson_arena:client:exitArena', src, {})
            end
        end
    end

    -- AFTER THE EXITS, WHICH IS THE WHOLE POINT OF WHERE THIS LINE SITS.
    --
    -- ArenaAmmo.Clear drops this match's rows from `issuedWeapons`,
    -- `issuedAmmo` and `issuedSupplies`, and those rows ARE the record of
    -- what the arena handed out -- the only thing the exit can take the kit
    -- back BY. This ran FIRST, above the loop, so on every path where the
    -- record survives being cleared there was nothing left for
    -- ArenaAmmo.Reclaim to remove and the fighters walked out still holding
    -- the arena's weapons and their ammunition.
    --
    -- It read clean only by accident: Clear REFUSES while anybody's kit is
    -- still stashed against the match, which on a working door is everybody.
    -- Turn the door off, or let a stash fail, and the refusal never fires --
    -- so the free kit landed on exactly the servers with no stash to protect
    -- them. `heldBefore` was dropped before that refusal either way, taking
    -- with it the floor that stops the exit reclaiming a player's OWN rounds.
    --
    -- server/match.lua does this in the right order and says so at length.
    -- DO NOT move this back above the loop.
    ArenaAmmo.Clear(match.id)

    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.ReleaseBucket) == 'function' then
        ArenaDispatch.ReleaseBucket(match.id)
    end

    matches[match.id] = nil
    ArenaLog('match %s closed (%s)', match.id, notice)

    ArenaLobby.Broadcast()
    return true
end

function ArenaLobby.HoldCountdown(src)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match = ArenaLobby.GetByPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.hostSource ~= target and not ArenaIsAdmin(target) then return false, 'error.host_only' end
    if playersArePlaced(match) then return false, 'error.match_in_progress' end
    if match.state ~= 'countdown' then return false, 'error.match_not_found' end

    match.state = 'lobby'
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

    if match.state ~= 'lobby' and match.state ~= 'countdown' then
        return false, 'error.match_in_progress'
    end

    if playersArePlaced(match) then return false, 'error.match_in_progress' end

    if Config.Betting.refundOnCancel == false then
        ArenaBetting.ForfeitAll(match.id, 'notify.match_cancelled')
    end

    ArenaLobby.Destroy(match.id, 'notify.match_cancelled')
    return true, nil
end

function ArenaLobby.UpdateMatch(src, data)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end
    if type(data) ~= 'table' then return false, 'error.invalid_request' end

    local match = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.hostSource ~= target then return false, 'error.not_host' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    local arenaKey, modeKey, lives = match.arenaKey, match.modeKey, match.lives
    local radar = match.radar == true
    local roundTime = Arena.ToInt(match.roundTimeSeconds) or 0
    local winCondition = Arena.IsKey(match.winCondition) and match.winCondition or ''
    local tierPlan = match.tierPlan
    local scoreLimit = Arena.ToInt(match.scoreLimit) or 0

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

    if data.roundTimeSeconds ~= nil then
        local resolved, reason = Arena.ResolveRoundTime(data.roundTimeSeconds)
        if not resolved then return false, reason end
        roundTime = resolved
    end

    if data.winCondition ~= nil then
        local resolved, reason = Arena.ResolveWinCondition(data.winCondition)
        if not resolved then return false, reason end
        winCondition = resolved
    end

    if data.scoreLimit ~= nil then
        local resolved, reason = Arena.ResolveScoreLimit(data.scoreLimit)
        if not resolved then return false, reason end
        scoreLimit = resolved
    end

    if data.tierPlan ~= nil then
        local resolved, reason = Arena.ResolveTierPlan(modeKey, data.tierPlan)
        if reason then return false, reason end
        tierPlan = resolved
    end

    if data.radar ~= nil then
        radar = Arena.ResolveRadar(data.radar)
    end

    if not Arena.PlaysLadder(modeKey)
        and Arena.WinConditionNeedsClock(winCondition)
        and Arena.RoundSecondsFor(modeKey, roundTime) <= 0
    then
        return false, 'error.win_condition_needs_clock'
    end

    local teamsChanged = modeKey ~= match.modeKey

    -- THE MODE LOCKS THE MOMENT MONEY IS DOWN ON IT.
    --
    -- A side-bet names a side: a team key in a team mode, a fighter's server
    -- id in a free-for-all. Change the mode and every bet already placed is
    -- picking something that cannot win any more -- a team key in a match
    -- with no teams -- so at settlement it simply loses. Not voided, not
    -- refunded: lost, with nothing on screen saying so and no way for the
    -- bettor to have seen it coming.
    --
    -- THIS USED TO HAND THE WHOLE BOOK BACK instead, and that was the wrong
    -- half of the answer. Returning the bets is fair to the bettors and it is
    -- exactly what makes the button worth pressing: the host is a FIGHTER
    -- with money on the outcome, changing the mode costs nothing, and it can
    -- be done again a second later. So the host held a "cancel everyone's
    -- bets" lever -- their own losing wager included -- pullable the instant
    -- the book turned against them, as often as they liked. Nothing had to be
    -- exploited for that; it was simply what the setting did.
    --
    -- Refused instead, BEFORE anything is written, the way every other
    -- refusal in this function is: a request that is half legal must not
    -- leave the match half changed.
    --
    -- THE HONEST HOST IS UNTOUCHED. They opened a lobby, nobody has backed
    -- it, and this asks about the book rather than about the lobby -- so a
    -- match with players in it and no bets on it is as editable as it ever
    -- was, and the arena, the lives and the radar stay editable even when
    -- there IS a book, because none of those makes a pick unwinnable.
    --
    -- Their way out when somebody HAS backed it is the one they already have:
    -- close the lobby. ArenaLobby.Destroy's Clear returns every unsettled
    -- side-bet whatever refundOnCancel says, so nobody is left holding a bet
    -- on a match that stopped existing -- it just costs the host the room
    -- rather than costing them nothing.
    if teamsChanged and ArenaBetting.IsEnabled() and ArenaBetting.CountSideBets(match.id) > 0 then
        return false, 'error.mode_locked_by_bets'
    end

    -- WHAT WINNING MEANS, as opposed to what the fight is like. Kept apart
    -- from `ruleChanged` below because the two books lock different halves of
    -- this form and the reasons do not travel.
    local decidesTheWinner = roundTime ~= (Arena.ToInt(match.roundTimeSeconds) or 0)
        or winCondition ~= (Arena.IsKey(match.winCondition) and match.winCondition or '')
        or scoreLimit ~= (Arena.ToInt(match.scoreLimit) or 0)

    -- THE TIER PLAN IS COMPARED BY VALUE, NOT BY IDENTITY. It is a flat map
    -- of class key to tier count, and the panel posts a fresh table on every
    -- Apply -- so `tierPlan ~= match.tierPlan` was true whenever a ladder
    -- mode was being edited at all, changed or not, and a gun-game lobby
    -- with any stake on it refused an Apply that altered nothing.
    local function sameTierPlan(a, b)
        if a == b then return true end
        if type(a) ~= 'table' or type(b) ~= 'table' then
            return (a == nil or next(a) == nil) and (b == nil or next(b) == nil)
        end
        for key, count in pairs(a) do if b[key] ~= count then return false end end
        for key, count in pairs(b) do if a[key] ~= count then return false end end
        return true
    end

    -- THE MODE IS A RULE, and it was the one rule this did not name. Every
    -- other field on the form was locked once money was down, and the mode
    -- -- the thing the money was put down ON -- could be swapped freely
    -- right up to the start, wiping every player's chosen team as it went.
    -- The side-bet guard above does lock it, but only against the side-bet
    -- book; entry fees are not side-bets, so a full pot with no side-bets on
    -- it left the mode open. It belongs here with the rest.
    local ruleChanged = arenaKey ~= match.arenaKey
        or modeKey ~= match.modeKey
        or lives ~= match.lives
        or radar ~= (match.radar == true)
        or not sameTierPlan(tierPlan, match.tierPlan)
        or decidesTheWinner

    -- THE ENTRY POT LOCKS THE WHOLE FORM, and it is the entry pot on purpose:
    -- en.json renders this key as "People have already paid to be in this
    -- round. The rules are set now." That sentence is about OTHER PEOPLE,
    -- and this asks exactly that. It used to ask GetPot > 0, and the host's
    -- own stake is taken the instant the lobby is created -- so on the
    -- shipped fee every lobby was locked against the only person in it from
    -- the moment it existed, with the panel still offering Apply and the
    -- server answering that other people had paid. The honest host, alone,
    -- edits freely again; the moment a second person has paid, the rules
    -- are set. This is the entry-fee book and NOT a mis-typed CountSideBets.
    -- DO NOT merge it into the guard below, and DO NOT put GetPot back.
    if ruleChanged and ArenaBetting.IsEnabled() and ArenaBetting.OthersStaked(match.id, target) then
        return false, 'error.rules_locked_by_stakes'
    end

    -- AND THE SIDE-BET BOOK LOCKS THE HALF THAT RE-JUDGES IT.
    --
    -- THE DEFECT: there was one guard here, on the entry pot alone, and with
    -- entryFee = 0 -- which every free lobby is, and which
    -- Config.Betting.entryFee invites -- that pot reads zero however large
    -- the side-bet book is. Measured: a host rewrote the win condition, the
    -- round clock and the score limit over a 50,000 book, every edit
    -- accepted, while a 1,000 entry pot with nothing bet on it refused the
    -- identical edit.
    --
    -- THE ARENA, THE LIVES AND THE RADAR ARE DELIBERATELY NOT IN HERE. The
    -- mode lock above states the line and tests/payaccount_spec.lua pins it:
    -- a side-bet names a SIDE, and moving the venue, the number of lives or
    -- the radar leaves every pick exactly where it was, so locking them
    -- would take the feature away from the honest host to fix an abuse of
    -- three other fields. What these three do is different in kind -- they
    -- decide WHO WINS, which is the only thing a side-bet is a wager on --
    -- so changing them re-judges every bet already down under rules the
    -- bettor never saw. That is the mode lock's own harm arriving by another
    -- door, and it is why the two guards ask two different books.
    --
    -- `tierPlan` IS STILL MISSING FROM decidesTheWinner, and the reason has
    -- changed. It used to be that the comparison was by table identity and
    -- would have locked every gun-game edit; that is fixed above, the plan
    -- is now compared by value. What remains is a judgement, not a bug: a
    -- ladder change does re-judge a gun-game side-bet, and whether that
    -- should lock behind the side-bet book like the other three is the
    -- owner's call. Reported, not changed here.
    if decidesTheWinner and ArenaBetting.IsEnabled() and ArenaBetting.CountSideBets(match.id) > 0 then
        return false, 'error.rules_locked_by_stakes'
    end

    match.arenaKey = arenaKey
    match.modeKey = modeKey
    match.lives = lives
    match.radar = radar
    match.roundTimeSeconds = roundTime
    match.winCondition = winCondition
    match.tierPlan = tierPlan
    match.scoreLimit = scoreLimit
    match.label = locale('match.label', match.hostName,
        (Arena.GetModeByKey(modeKey) or {}).label or modeKey)

    for _, player in pairs(match.players) do
        player.lives = lives
        if teamsChanged then player.team = nil end
    end

    ArenaLobby.Broadcast()
    return true, nil
end

function ArenaLobby.SetTeam(src, teamKey)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end
    if not Arena.ModeUsesTeams(match.modeKey) then return false, 'error.mode_has_no_teams' end
    if Config.Teams.allowChoose == false then return false, 'error.team_choice_disabled' end

    if not Arena.IsKey(teamKey) then return false, 'error.team_unavailable' end

    local team, reason = resolveTeam(match, teamKey, target)
    if reason then return false, reason end

    -- YOU DO NOT TAKE YOUR OWN MONEY OFF THE TABLE BY CHANGING SIDES EITHER.
    --
    -- ArenaLobby.MayLeave refuses a fighter holding a side-bet the chance to
    -- walk out, in those words, because a wager you can withdraw the moment
    -- it turns against you is not a wager. This door had no lock on it at
    -- all, and it is the same trade with an extra prize on the end:
    --
    --   `fighterBets.ownSideOnly` forces a fighter to back their own side, so
    --   the bet names a team rather than a person. `voided()` decides at
    --   settlement by reading the team off the LIVE roster row -- so a
    --   fighter who bets on crimson, watches the lobby fill, and then moves
    --   to ash is holding a bet on a side that is no longer theirs. It is
    --   voided and handed back in full, unjudged, whatever the result. And
    --   they are now fighting on the side they judged to be stronger.
    --
    -- Refused while they hold one. Their way out is to stay and play it, or
    -- to be in a lobby they never bet on -- and switching sides is free for
    -- everybody who has not backed the round, which is almost everybody.
    --
    -- Only when the side really changes: re-picking the side you are already
    -- on is legal everywhere else in this function and must not start
    -- refusing here.
    if team ~= player.team and ArenaBetting.IsEnabled()
        and ArenaBetting.HoldsSideBet(match.id, target)
    then
        return false, 'error.bet_then_switch'
    end

    local was = player.team
    player.team = team
    if was ~= team then ArenaLobby.Broadcast() end

    -- NAME THE SIDE BACK, EVERY TIME, AND NOT ONLY WHEN IT MOVED.
    --
    -- REPORTED THREE TIMES: "i clicked a team, had another member join my
    -- team, they switched teams, and in the match they could not kill each
    -- other". His log for that round reads `ash 1 v crimson 2 (0 assigned,
    -- 3 chose their own)` and then `crossfire: 4 may not damage 3 -- they
    -- are on the same team` -- so the server had the pair on ONE side and
    -- refused the shot correctly. The switch never happened.
    --
    -- IT NEVER HAPPENED BECAUSE NOTHING ANSWERED. server/main.lua drops a
    -- client event that arrives inside RATE.choice -- 250ms -- with a bare
    -- `return`: no refusal, no toast, no state push, nothing in any log.
    -- And the click before it, a re-pick of the side you are already on,
    -- changed nothing, so it broadcast nothing and the panel did not so
    -- much as flicker. A player whose click produces no visible answer
    -- clicks again, and the second click is the one the window eats.
    --
    -- So a click the server ACTS ON now always says which side you are on
    -- -- the pick, the switch and the re-pick alike. That is what makes
    -- silence mean something: no line back is a click that never arrived,
    -- and clicking again is the right thing to do. teamswitchtempo_spec
    -- drives it at the tempo a person clicks at and fails without this.
    --
    -- THE PANEL IS NOT ENOUGH ON ITS OWN. It renders the side the server
    -- holds and it is right to -- but it is repainted by a broadcast that a
    -- no-op does not send, and it cannot say anything about a message that
    -- never got here. server/match.lua says the same line again as the
    -- fighter is put on the ground, which is the last moment it can be
    -- heard.
    local side = Arena.GetTeamByKey(team)
    ArenaNotifyKey(target, 'notify.team_side', 'success', (side and side.label) or team)
    return true, nil
end

function ArenaLobby.SetLoadout(src, request)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    if Arena.PlaysLadder(match.modeKey) then
        ArenaDebug('loadout: %s picked, but %s issues its own loadout -- refused.',
            tostring(target), tostring(match.modeKey))
        return false, 'error.mode_picks_loadout'
    end

    local hostPicks = Arena.LoadoutChooser() == 'host'
    if hostPicks and match.hostSource ~= target then
        ArenaDebug('loadout: %s picked, but Config.Loadouts.chooser is \'host\' and the host is %s -- refused, they will carry the host\'s pick.',
            tostring(target), tostring(match.hostSource))
        return false, 'error.host_picks_loadout'
    end

    local loadout, rejected = Arena.ResolveLoadout(type(request) == 'table' and request or nil)
    local changed = not sameLoadout(player.loadout, loadout)
    player.loadout = loadout

    local asked = {}
    for _, entry in ipairs(type(request) == 'table' and request.weapons or {}) do
        if type(entry) == 'table' and entry.key then asked[#asked + 1] = tostring(entry.key) end
    end
    local got = {}
    for _, entry in ipairs(loadout.weapons or {}) do got[#got + 1] = tostring(entry.key or entry.weapon) end
    ArenaDebug('loadout: %s asked for [%s] and was allowed [%s]%s',
        tostring(target),
        #asked > 0 and table.concat(asked, ', ') or 'nothing -- no weapons in the request',
        #got > 0 and table.concat(got, ', ') or 'nothing',
        #rejected > 0 and (' -- REFUSED: ' .. table.concat(rejected, ', ')) or '')

    if #rejected > 0 then
        ArenaNotifyKey(target, 'notify.loadout_rejected', 'warning', table.concat(rejected, ', '))
    end

    -- PUSH ONLY WHEN SOMETHING CHANGED, which is the rule ArenaLobby.SetReady
    -- below already has and states at length. This handler shares setReady's
    -- RATE.choice bucket in server/main.lua and was the one door of the three
    -- left without the guard -- setReady has it, updateMatch has it.
    --
    -- THE FAN-OUT IS WHAT MADE IT WORTH THE TROUBLE. With
    -- Config.Loadouts.chooser = 'host', which is what ships, one setLoadout
    -- wrote and pushed a full snapshot to EVERY other player in the lobby:
    -- measured at 6 state builds per event in a six-player room, four times a
    -- second, for a pick the host had already sent and nobody's screen would
    -- move on. Config.Match.maxPlayers ships at 0, so the room has no ceiling
    -- and neither did the multiplier.
    --
    -- `#rejected > 0` STILL PUSHES, and that is not a hole in the guard. The
    -- weapon picker is a control holding a DRAFT -- server/main.lua says so
    -- beside the create/edit form, which copied the behaviour from this one
    -- -- so a request that was refused a weapon resolves to the SAME loadout
    -- the player already had, and without this clause their screen would go
    -- on showing the gun the server just turned down. The asker only: the
    -- room did not change and is not told. DO NOT tidy that clause away.
    if hostPicks and changed then
        for _, other in pairs(match.players) do
            if other.src ~= target then
                other.loadout = (Arena.ResolveLoadout(request))
                pushState(other.src)
            end
        end
    end

    if changed or #rejected > 0 then pushState(target) end
    return true, nil
end

function ArenaLobby.SetReady(src, ready)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match, player = findPlayer(target)
    if not match then return false, 'error.not_in_match' end
    if match.state ~= 'lobby' then return false, 'error.match_in_progress' end

    -- NO OPENING-HOURS CHECK HERE, DELIBERATELY. Readying up is intent
    -- inside a lobby that is allowed to go on existing while the arena is
    -- shut, and refusing it would tell a player their own tick box is
    -- broken. What they are actually blocked from is STARTING, and the
    -- auto-start branch below already forwards ArenaMatch.Begin's refusal
    -- key to every player in the roster -- so a full, readied lobby is told
    -- "the arena is shut" through code that already exists.
    --
    -- With auto-assignment off an unpicked side blocks the start. This is
    -- the last moment the player is still looking at the team picker, so it
    -- is the kindest place to say so.
    if ready == true
        and Arena.ModeUsesTeams(match.modeKey)
        and not Arena.IsKey(player.team)
        and Config.Teams.autoAssignIfUnchosen == false then
        return false, 'error.pick_a_team'
    end

    -- BROADCAST ONLY WHEN SOMETHING CHANGED.
    --
    -- Broadcast is not cheap and it is not local: it refreshes the
    -- leaderboard, rebuilds the config block and the whole match list, then
    -- builds a per-head player snapshot and fires one event for every
    -- recipient on the server. Sending it unconditionally made this handler
    -- an amplifier -- one client event costing N snapshots -- and setReady
    -- shares RATE.choice, which is 250ms, so a single client could pay four
    -- times a second for it with a value nobody's screen would change on.
    --
    -- The auto-start check below deliberately still runs on a repeat. It is
    -- cheap, and re-pressing Ready is the only way a full lobby retries a
    -- start that ArenaMatch.Begin refused for a reason that has since gone
    -- away -- the arena opening, most of all.
    local was = player.ready == true
    player.ready = ready == true
    if player.ready ~= was then ArenaLobby.Broadcast() end

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
            local began, why = ArenaMatch.Begin(match.id, nil)
            if not began and Arena.IsKey(why) then
                for _, entry in ipairs(roster) do
                    ArenaNotifyKey(entry.src, why, 'warning')
                end
            end
        end
    end

    return true, nil
end

function ArenaLobby.AddSpectator(src, matchId)
    local target = tonumber(src)
    if not target then return false, 'error.invalid_request' end

    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end

    local attachedTo = playerIndex[target]
    if attachedTo and (attachedTo ~= match.id or not isEliminated(match, target)) then
        return false, 'error.already_in_match'
    end

    if spectatorIndex[target] == match.id then return true, nil end

    ArenaLobby.RemoveSpectator(target, true)      -- one match at a time
    match.spectators[target] = true
    spectatorIndex[target] = match.id

    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.EnterBucket) == 'function' then
        ArenaDispatch.EnterBucket(target, match.id)
    end

    -- ONE SCREEN, BECAUSE ONLY ONE SCREEN CHANGED.
    --
    -- Starting or stopping a watch moves two fields, `spectating` and `bet`,
    -- and both live in snapshotPlayer -- the WATCHER'S OWN ROW.
    -- snapshotMatches carries no spectator anywhere in it, and snapshotKeepOut
    -- reads spectatorIndex only for the player it is building for. So a
    -- Broadcast here rebuilt the leaderboard, the config block, every lobby
    -- and a per-head row for every recipient on the server, and handed all
    -- but one of them a snapshot identical to the one they already had.
    --
    -- WHAT THAT BOUGHT A CLIENT: spectateMatch and stopSpectating hold
    -- SEPARATE rate-limit buckets in server/main.lua, so alternating them
    -- costs one of each per second -- measured at 66 full snapshots a second
    -- to a 32-recipient server, from somebody in no match holding no bet, and
    -- 60 of every 70 went to a screen that did not change. It is
    -- the same hole setReady's changed-value guard was added for, one door
    -- along.
    --
    -- ArenaMatch.OnDeath's elimination path does its own Broadcast after
    -- this returns, so the room still learns the eliminated fighter is out.
    -- DO NOT put a Broadcast back here, or in ArenaLobby.RemoveSpectator.
    ArenaLobby.PushState(target)
    return true, nil
end

function ArenaLobby.RemoveSpectator(src, quiet)
    local target = tonumber(src)
    if not target then return false end

    local matchId = spectatorIndex[target]
    if not matchId then return false end

    spectatorIndex[target] = nil
    local match = matches[matchId]
    if match then match.spectators[target] = nil end

    if not playerIndex[target]
        and type(ArenaDispatch) == 'table'
        and type(ArenaDispatch.ExitBucket) == 'function'
    then
        ArenaDispatch.ExitBucket(target)
    end

    -- The other half of AddSpectator's rule, and it says why up there --
    -- including why a Broadcast must not come back to either of them. This
    -- one also REACHES them, which the Broadcast could not: their spectatorIndex
    -- entry is already gone by this line, so recipients() no longer counts a
    -- watcher who never opened the panel -- and the exit half of this pair
    -- is exactly the one that must land.
    if not quiet then ArenaLobby.PushState(target) end
    return true
end

local SWEEP_INTERVAL_MS = 30000

local idleTimeout = math.max(0, Arena.ToInt(Config.Match.idleLobbyTimeoutSeconds) or 0)

if idleTimeout > 0 then
    CreateThread(function()
        while true do
            Wait(SWEEP_INTERVAL_MS)

            local now = os.time()
            local expired = {}

            for id, match in pairs(matches) do
                if match.state == 'lobby'
                    and readyCount(match) == 0
                    and (now - match.createdAt) >= idleTimeout then
                    expired[#expired + 1] = id
                end
            end

            for _, id in ipairs(expired) do
                ArenaLobby.Destroy(id, 'notify.lobby_timed_out')
            end
        end
    end)
end
