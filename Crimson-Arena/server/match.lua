--[[
    crimson_arena/server/match.lua

    The round itself: putting players in the arena, counting what happens
    there, and deciding when it is over.

    THE LOBBY OWNS THE RECORD, THIS FILE OWNS THE ROUND. Everything here
    reads and writes the match record server/lobby.lua created. It keeps no
    second list of who is playing, because two lists of players is one list
    too many the moment somebody disconnects.

    NOTHING A CLIENT SAYS IS A FACT. A death report is a hint: the server
    already knows who is in the match, which side they are on and whether
    they are still alive, and it re-checks all three before crediting a kill.
    A claim it cannot verify scores nobody -- but the reporter is still
    eliminated, because that part was never in doubt.

    ONE SWEEP THREAD, NOT ONE PER MATCH. The round clock, the win check and
    the scoreboard push all ride on a single one-second pass over the live
    matches. That is also what turns a double knockout into a draw: two
    players who die in the same tick are both counted before anything is
    decided, so neither one is declared the last standing.

    A ROUND IS FOUGHT IN ITS OWN NETWORK INSTANCE. Entering the arena moves a
    player into the match's routing bucket and leaving it puts them back in
    the one they came from, both on the same two choke points that raise and
    clear the dispatch flag -- sendEnterArena and sendExitArena -- so the two
    cannot end up disagreeing about who is in a match. The sweep reconciles
    that against the registry once a second, so a departure that never
    reaches those choke points -- and there is one -- still ends with the
    player back in the world they came from. What all that buys, what it does
    not, and why the bucket is captured rather than assumed to be 0 are in
    server/dispatch.lua.

    MONEY IS NOT DECIDED HERE. This file decides who won; what that is worth
    is Arena.ComputePayouts' arithmetic and server/betting.lua's escrow. The
    one thing it must get exactly right is the ORDER of the settlement in
    End(), which is spelled out where it happens.
]]

ArenaMatch = {}

--- How often the sweep looks at every live match. One second is the
--- coarsest tick a round clock can be drawn from and the finest a
--- scoreboard needs.
local SWEEP_INTERVAL_MS = 1000

-- ======================================================================
-- SHAPES ON THE WIRE
-- ======================================================================

--- Copies a config coordinate into a plain table.
---
--- Spawns are vector4s and boundary centres are vector3s, but an operator
--- may equally have written a table of numbers, and the client has to
--- receive one shape whichever it was.
--- @param value any
--- @return table|nil point -- { x, y, z, w }
local function toPoint(value)
    local kind = type(value)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then return nil end

    local indexed = kind == 'table' and value or nil
    local x = tonumber(value.x) or (indexed and tonumber(indexed[1]))
    local y = tonumber(value.y) or (indexed and tonumber(indexed[2]))
    local z = tonumber(value.z) or (indexed and tonumber(indexed[3]))
    if not x or not y or not z then return nil end

    -- A vector3 has no `w` to ask for, and asking is not worth finding out
    -- what this runtime's vector metatable does with an unknown field.
    local w = 0.0
    if kind ~= 'vector3' then
        w = tonumber(value.w) or (indexed and tonumber(indexed[4])) or 0.0
    end

    return { x = x, y = y, z = z, w = w }
end

--- Metres the client scatters a player around the spawn point they drew.
--- Sent with the spawn rather than left for the client to look up, so the
--- point and the radius it is scattered by always come from one decision.
--- @return number
local function scatterRadius()
    return math.max(0.0, tonumber(Config.Match.spawnScatterRadius) or 0.0)
end

--- @param arena table -- a raw Config.Arenas entry
--- @return table|nil boundary -- nil for an open arena
local function boundaryPayload(arena)
    local boundary = arena.boundary
    if type(boundary) ~= 'table' or boundary.enabled ~= true then return nil end

    return {
        enabled = true,
        center = toPoint(boundary.center),
        radius = tonumber(boundary.radius) or 0.0,
        warningSeconds = math.max(0, Arena.ToInt(boundary.warningSeconds) or 0),
        damagePerTick = math.max(0, Arena.ToInt(boundary.damagePerTick) or 0),
        tickMs = math.max(100, Arena.ToInt(boundary.tickMs) or 1000),
    }
end

-- ======================================================================
-- READING THE MATCH
-- ======================================================================

--- The team key a player's spawn and damage rules key off. Free-for-all
--- returns nil, which is what makes Arena.PickSpawn use the arena's shared
--- spawn list rather than a team one.
--- @param match table
--- @param player table
--- @return string|nil
local function teamOf(match, player)
    if not Arena.ModeUsesTeams(match.modeKey) then return nil end
    return Arena.IsKey(player.team) and player.team or nil
end

--- Places an eliminated player from the bottom up: the first player out of
--- a four-way match finishes fourth.
--- @param match table
--- @return integer placement
local function placementFor(match)
    local total, placed = 0, 0
    for _, player in pairs(match.players) do
        total = total + 1
        if player.placement then placed = placed + 1 end
    end
    return math.max(1, total - placed)
end

--- @param match table
--- @return table<string, integer> kills per team
local function teamKills(match)
    local scores = {}
    for _, player in pairs(match.players) do
        if Arena.IsKey(player.team) then
            scores[player.team] = (scores[player.team] or 0) + math.max(0, Arena.ToInt(player.kills) or 0)
        end
    end
    return scores
end

--- EVERY member of a side, alive or not.
---
--- Arena.ComputePayouts splits the pot evenly across the winners it is
--- handed, so a seven-man team takes a seventh each while a lone winner
--- takes the lot. That is deliberate, and it is what makes uneven teams
--- (Config.Teams.allowUnequal) safe to allow: stacking a side dilutes what
--- winning on it is worth instead of guaranteeing it.
--- @param match table
--- @param teamKey string
--- @return integer[] ids
local function membersOfTeam(match, teamKey)
    local ids = {}
    -- Join order, so the winners list -- and therefore the payout order --
    -- never depends on pairs() iteration.
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        if player.team == teamKey then ids[#ids + 1] = player.src end
    end
    return ids
end

--- Most kills takes it.
---
--- A TIE IS A DRAW and returns nobody, which refunds the pot: paying one of
--- two equal scores out of the other's stake is not a result, it is a coin
--- toss with somebody else's money. A round where nobody killed anybody is
--- a draw for the same reason.
--- @param match table
--- @param teamMode boolean
--- @return integer[]|string[] winners -- empty when there is no clear leader
local function decideOnKills(match, teamMode)
    local scores, best = {}, 0

    if teamMode then
        scores = teamKills(match)
    else
        for _, player in pairs(match.players) do
            scores[player.src] = math.max(0, Arena.ToInt(player.kills) or 0)
        end
    end

    for _, score in pairs(scores) do
        if score > best then best = score end
    end
    if best <= 0 then return {} end

    local leaders = {}
    for key, score in pairs(scores) do
        if score == best then leaders[#leaders + 1] = key end
    end
    if #leaders ~= 1 then return {} end

    if teamMode then return membersOfTeam(match, leaders[1]) end
    return leaders
end

--- @param match table
--- @param teamMode boolean
--- @return boolean
local function reachedScoreLimit(match, teamMode)
    local limit = math.max(1, Arena.ToInt(Config.Match.scoreLimit) or 1)

    if teamMode then
        for _, score in pairs(teamKills(match)) do
            if score >= limit then return true end
        end
        return false
    end

    for _, player in pairs(match.players) do
        if (Arena.ToInt(player.kills) or 0) >= limit then return true end
    end
    return false
end

--- Whether the round is over, and who took it.
---
--- Called only from the sweep, never from the death report itself: everyone
--- who died since the last pass is already counted by the time this runs,
--- so a mutual kill leaves nobody alive and settles as a draw instead of
--- crowning whichever corpse reported first.
--- @param match table
--- @return table|nil winners -- nil means the round carries on
--- @return string|nil reasonKey
local function evaluate(match)
    local teamMode = Arena.ModeUsesTeams(match.modeKey)

    -- STILL IN THE ROUND, not still breathing. With Config.Match.lives above
    -- 1 a player lying on the floor waiting out respawnDelaySeconds has not
    -- lost yet, and counting them as eliminated would hand the match to
    -- whoever shot them before they got back up.
    local total, standing, lastStanding = 0, 0, nil
    local standingTeams = {}
    for _, player in pairs(match.players) do
        total = total + 1
        if player.alive == true or (Arena.ToInt(player.lives) or 0) > 0 then
            standing = standing + 1
            lastStanding = player
            if teamMode and Arena.IsKey(player.team) then
                standingTeams[player.team] = (standingTeams[player.team] or 0) + 1
            end
        end
    end

    if total == 0 then return {}, 'match.ended_abandoned' end

    -- THE LADDER OVERRIDES Config.Match.winCondition, and this is the one
    -- mode that overrides anything: gun game IS its own win condition.
    -- 'most_kills' and 'score_limit' would settle a ladder race on a number
    -- nobody in it is playing for, and 'last_standing' would leave a finished
    -- ladder waiting for a corpse. Read before the clock, too -- a ladder
    -- finished on the last second of the round was still finished.
    --
    -- A ladder is climbed by one player, so it is won by one player whatever
    -- the mode's `teams` setting says. Two who finish inside the same sweep
    -- both took it and split the pot, the way a winning team does -- the
    -- server cannot honestly order two kills reported in the same second.
    local climbed = {}
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        if player.ladderFinished == true then climbed[#climbed + 1] = player.src end
    end
    if #climbed > 0 then return climbed, 'match.ended_ladder' end

    if Config.Match.winCondition == 'score_limit' and reachedScoreLimit(match, teamMode) then
        local winners = decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_score_limit' or 'match.ended_draw'
    end

    -- Nobody left to fight ends the round whatever the condition is: with
    -- one side still standing there is nothing left to decide it with, so
    -- the survivors take it under every win condition, not just
    -- 'last_standing'.
    if teamMode then
        local occupied = Arena.Count(standingTeams)
        if occupied == 0 then return {}, 'match.ended_draw' end
        if occupied == 1 then return membersOfTeam(match, (next(standingTeams))), 'match.ended_last_standing' end
    else
        if standing == 0 then return {}, 'match.ended_draw' end
        if standing == 1 and total > 1 then return { lastStanding.src }, 'match.ended_last_standing' end
        -- One player left in the record at all: there is no match here any
        -- more. Whether a one-man round pays is Config.Betting's
        -- minPlayersToPayOut to answer, not this file's.
        if total == 1 then return { lastStanding.src }, 'match.ended_abandoned' end
    end

    -- The clock. `roundTimeSeconds = 0` leaves endsAt unset and the round
    -- runs until one side is left.
    if match.endsAt and os.time() >= match.endsAt then
        local winners = decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_time_up' or 'match.ended_draw'
    end

    return nil, nil
end

--- Ranks everybody who is still standing when the round stops, so the
--- results board and a `top_three` payout have a full finishing order to
--- read rather than a hole where the survivors are.
--- @param match table
local function assignFinalPlacements(match)
    local unplaced = {}
    for _, player in pairs(match.players) do
        if not player.placement then unplaced[#unplaced + 1] = player end
    end

    table.sort(unplaced, function(a, b)
        local aKills, bKills = Arena.ToInt(a.kills) or 0, Arena.ToInt(b.kills) or 0
        if aKills ~= bKills then return aKills > bKills end
        local aDeaths, bDeaths = Arena.ToInt(a.deaths) or 0, Arena.ToInt(b.deaths) or 0
        if aDeaths ~= bDeaths then return aDeaths < bDeaths end
        return a.src < b.src
    end)

    for index, player in ipairs(unplaced) do player.placement = index end
end

--- Server ids in finishing order, best first.
--- @param match table
--- @return integer[]
local function standings(match)
    local ordered = {}
    for _, player in pairs(match.players) do ordered[#ordered + 1] = player end
    table.sort(ordered, function(a, b)
        local aPlace, bPlace = a.placement or math.maxinteger, b.placement or math.maxinteger
        if aPlace ~= bPlace then return aPlace < bPlace end
        return a.src < b.src
    end)

    local ids = {}
    for index, player in ipairs(ordered) do ids[index] = player.src end
    return ids
end

--- The live scoreboard, sorted the way the panel renders it.
--- @param players table[] -- in join order
--- @return table[]
local function scoreboardOf(players)
    local rows = {}
    for _, player in ipairs(players) do
        rows[#rows + 1] = {
            id = player.src,
            name = player.name or ArenaPlayerName(player.src),
            team = player.team,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            deaths = math.max(0, Arena.ToInt(player.deaths) or 0),
            alive = player.alive == true,
        }
    end

    table.sort(rows, function(a, b)
        if a.kills ~= b.kills then return a.kills > b.kills end
        if a.deaths ~= b.deaths then return a.deaths < b.deaths end
        -- Id last, so two identical rows never swap places between ticks and
        -- make the board flicker.
        return a.id < b.id
    end)
    return rows
end

--- What spectator side-bets are judged against: the winning team in a team
--- mode, the winning fighter in a free-for-all, and nil when the round
--- produced no result at all -- which is what makes SettleSpectatorBets
--- hand every bet back instead of keeping it.
--- @param match table
--- @param winners table
--- @param teamMode boolean
--- @return any pick
local function winningPick(match, winners, teamMode)
    local first = winners and winners[1]
    if first == nil then return nil end
    if not teamMode then return first end

    -- Every winner in a team mode is on the winning team, so the first one
    -- names it.
    local player = match.players[first]
    return player and player.team or nil
end

-- ======================================================================
-- GUN GAME
--
-- Config.Modes.gungame.gunGameLadder, played.
--
-- THE LADDER IS THE LOADOUT. What a player picked in the panel is never
-- handed out in this mode -- the ladder replaces it on the way in, on every
-- promotion and on every respawn, which is what config.lua has always said
-- happens. Armour, health and the operator's alwaysGive list are not a
-- weapon choice and are left exactly as they are everywhere else.
--
-- A RUNG IS DERIVED FROM THE KILL COUNT, NEVER COUNTED UP. Two kills landing
-- between one sweep and the next promote once per rung and never twice, and
-- a kill the server refused to credit cannot leave anybody standing a rung
-- above their own score.
-- ======================================================================

--- The rungs of a mode's ladder that can actually be handed out, in ladder
--- order.
---
--- A RUNG NAMING A WEAPON THAT IS NOT IN THE ENABLED CATALOGUE IS DROPPED
--- and the ladder is that much shorter. Promoting somebody onto a rung with
--- no weapon on it would put a player in the arena empty-handed, and
--- refusing to run the mode at all would punish a full lobby for one typo.
--- An EMPTY result -- no ladder, or nothing in it survived -- is what makes
--- every caller below fall back to ordinary play.
--- @param modeKey any
--- @return table[] rungs -- Config.Loadouts.weapons entries, never bare keys
local function ladderFor(modeKey)
    -- nil for a mode an operator has switched off, so a disabled gun game
    -- never plays a ladder no matter what is stored on a match record.
    local mode = Arena.GetModeByKey(modeKey)
    local ladder = mode and mode.gunGameLadder
    if type(ladder) ~= 'table' then return {} end

    local rungs = {}
    for _, key in ipairs(ladder) do
        -- GetWeaponByKey answers nil for a disabled weapon exactly as it
        -- does for an invented one, which is the whole reason the ladder is
        -- read through it rather than trusted.
        local weapon = Arena.GetWeaponByKey(key)
        if weapon then
            rungs[#rungs + 1] = weapon
        else
            ArenaDebug('gun game rung "%s" is not an enabled weapon -- dropped from the ladder', tostring(key))
        end
    end
    return rungs
end

--- Which rung a kill count has earned, and whether it finished the ladder.
---
--- Everybody starts on rung 1, so the Nth kill puts a player on rung N+1 and
--- the kill made ON the last rung is the one that finishes it.
--- @param kills any
--- @param rungs any -- how many playable rungs the ladder has
--- @return integer rung -- 1-based, and never past the end of the ladder
--- @return boolean finished
local function rungForKills(kills, rungs)
    local total = math.max(0, Arena.ToInt(rungs) or 0)
    local scored = math.max(0, Arena.ToInt(kills) or 0)
    if total <= 0 then return 1, false end
    if scored >= total then return total, true end
    return scored + 1, false
end

--- What a player holds on one rung: that rung's weapon at its own configured
--- default ammo, and nothing they chose for themselves.
--- @param weapon table -- a Config.Loadouts.weapons entry
--- @param previous table? -- what they were holding, read for its armour only
--- @return table loadout -- the shape Arena.ResolveLoadout returns
local function ladderLoadout(weapon, previous)
    local rung = {
        key = weapon.key,
        weapon = weapon.weapon,
        label = weapon.label or weapon.key,
        -- Nothing requested: with no ask to resolve, ResolveAmmo hands back
        -- this weapon's own default clamped to its own max, which is exactly
        -- what a rung is worth.
        ammo = Arena.ResolveAmmo(weapon, nil),
        components = type(weapon.components) == 'table' and weapon.components or {},
        tint = Arena.ToInt(weapon.tint) or 0,
    }

    -- Armour, health and alwaysGive still come from the ordinary path so the
    -- ladder never grows a second copy of those rules. Only the alwaysGive
    -- entries are kept out of what comes back: with Config.Loadouts
    -- .allowChoose off, ResolveLoadout answers with the operator's `fixed`
    -- weapon list, and in this mode the ladder outranks that list too.
    local base = Arena.ResolveLoadout({
        weapons = {},
        armor = type(previous) == 'table' and previous.armor or nil,
    })

    local weapons = { rung }
    for _, given in ipairs(base.weapons) do
        -- A house knife the ladder is already handing out must not arrive
        -- twice: the client gives what it is sent, entry for entry.
        if given.alwaysGive == true and given.weapon ~= rung.weapon then
            weapons[#weapons + 1] = given
        end
    end

    return { weapons = weapons, armor = base.armor, health = base.health }
end

--- The loadout a player should be holding for this match right now: their
--- own choice re-resolved in every mode, and the rung they are standing on
--- in a gun game.
--- @param match table
--- @param player table
--- @return table loadout
--- @return string[] rejected -- keys dropped from a player's own choice
local function loadoutFor(match, player)
    local rungs = ladderFor(match.modeKey)
    if #rungs == 0 then return Arena.ResolveLoadout(player.loadout) end

    -- Clamped rather than trusted: an operator who shortened the ladder
    -- since the round started leaves somebody standing on a rung that is no
    -- longer there.
    local rung = Arena.ClampInt(player.rung, 1, #rungs) or 1
    player.rung = rung
    return ladderLoadout(rungs[rung], player.loadout), {}
end

--- Scores one gun-game kill: moves the killer up the ladder when that kill
--- earned it, and marks the ladder finished when it was made on the last
--- rung.
---
--- DECIDES NOTHING. The flag it sets is read by the sweep a tick later, the
--- same as every other way a round ends here.
--- @param match table
--- @param killer table
local function promote(match, killer)
    local rungs = ladderFor(match.modeKey)
    if #rungs == 0 then return end

    local rung, finished = rungForKills(killer.kills, #rungs)
    killer.ladderFinished = finished

    -- Already standing there: the rung is read off the kill count, so a kill
    -- made FROM the top rung -- and any second pass over a count already
    -- granted -- would otherwise re-issue a weapon the player is holding and
    -- refill its ammo for free.
    if rung == killer.rung then return end

    local previous = killer.rung and rungs[killer.rung] or nil
    killer.rung = rung
    killer.loadout = ladderLoadout(rungs[rung], killer.loadout)

    local weapon = killer.loadout.weapons[1]

    -- THE ITEM IS THE WEAPON on an ox_inventory server, so the promotion has
    -- to happen here rather than in the message below: a ped handed a gun it
    -- has no item for is disarmed again within moments. Safe to call when
    -- ox_inventory is absent -- it answers false and the client event below
    -- does the work instead.
    ArenaAmmo.SwapWeapon(killer.src, match.id,
        (previous and previous.weapon ~= weapon.weapon) and previous.weapon or nil,
        weapon.weapon, weapon.ammo)

    TriggerClientEvent('crimson_arena:client:gunGameRung', killer.src, {
        matchId = match.id,
        rung = rung,
        rungs = #rungs,
        weapon = weapon.weapon,
        ammo = weapon.ammo,
        components = weapon.components,
        tint = weapon.tint,
        -- The rung below is taken back and nothing else is -- the house
        -- alwaysGive list was never part of the ladder. A ladder naming the
        -- same weapon on two rungs would otherwise strip the gun it was
        -- handed in the same breath.
        remove = (previous and previous.weapon ~= weapon.weapon) and previous.weapon or nil,
    })
    ArenaNotifyKey(killer.src, 'notify.gungame_promoted', 'success', rung, #rungs, weapon.label)
end

-- ======================================================================
-- TALKING TO THE ARENA
-- ======================================================================

--- Everybody this file has moved into a match's routing bucket, fighter or
--- spectator, as src -> matchId.
---
--- WHY THERE IS A SECOND LIST AT ALL, in a file whose opening comment says
--- two lists of players is one too many: this is not a list of players, it
--- is a record of what has been DONE to them, and nothing else in the
--- resource holds it. It is written on the two choke points below and
--- reconciled against the match registry by the sweep, which is what makes
--- the isolation self-healing rather than merely careful.
---
--- IT HAS TO BE SELF-HEALING, because not every departure comes through
--- those choke points. A spectator is attached and detached by
--- server/lobby.lua from call sites this file does not own.
---
--- The frozen countdown used to be the other one: main.lua's detach() asked
--- ArenaMatch.IsLive, which is false while Start() has already put everybody
--- in the arena and goLive() has not yet flipped the match to 'live', so a
--- player leaving in that window was routed to ArenaLobby.Leave and no exit
--- was sent. That is fixed -- detach() now asks RemovePlayer, whose own
--- predicate covers both phases -- and tests/countdownexit_spec.lua holds it
--- fixed. This sweep is no longer the thing standing between that bug and a
--- stranded player, and it stays anyway: a leaked flag is a bug somebody
--- else's script lives with for one session, but a leaked BUCKET is a player
--- alone in an invisible copy of the map with no way out, and that is worth
--- a table walk a second against the departure nobody has written yet.
--- @type table<number, string>
local instanced = {}

--- One event to every fighter and every spectator of a match.
--- @param match table
--- @param event string
--- @param payload table
--- The ONE way anybody is told to leave the arena.
---
--- Every exit path in this file routes through here specifically so the
--- dispatch flag cannot be left set: there are five separate places a
--- player can be sent home from -- winning, watching someone else win, an
--- abort, an admin stop, walking out mid-round -- and a flag that survives
--- any one of them would suppress that player's police and medical alerts
--- for the rest of their session. One choke point, rather than five call
--- sites and the hope that a sixth remembers.
---
--- THE ROUTING BUCKET RIDES ON THE SAME CHOKE POINT, and deliberately so:
--- put the two on separate call sites and they can disagree about who is in
--- a match, which means either a player left instanced in an empty world
--- after the flag says they went home, or a player back in the world with
--- the flag still suppressing their alerts. Neither is visible from a log.
--- @param src number
--- @param payload table
local function sendExitArena(src, payload)
    -- FIRST, before anything else about this player is torn down. Ammunition
    -- is the one thing they are holding that has value outside the arena, and
    -- the exit is the last moment it can be taken back.
    ArenaAmmo.Reclaim(src, 'left the arena')

    ArenaDispatch.Clear(src)
    -- Before the client is told, so the teleport back to the lobby happens
    -- in the world the player is going to be standing in rather than in the
    -- instance they are leaving.
    ArenaDispatch.ExitBucket(src)
    instanced[src] = nil

    -- The ped is stood back up by the client on the way out, but a medical
    -- or ambulance script keeps its OWN death state and nothing about
    -- resurrecting a ped reaches it. Without this a player who died in the
    -- match leaves the arena on their feet and is still dead as far as that
    -- script is concerned. Fired before the client is told, so the state is
    -- already clean when they land in the lobby.
    ArenaDispatch.Revive(src)

    TriggerClientEvent('crimson_arena:client:exitArena', src, payload)
end

local function pushToMatch(match, event, payload)
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        TriggerClientEvent(event, player.src, payload)
    end
    for src in pairs(match.spectators or {}) do
        -- An eliminated fighter who stayed to watch is in both tables and
        -- must not be sent the same thing twice.
        if not match.players[src] then
            TriggerClientEvent(event, src, payload)
        end
    end
end

--- One second of scoreboard for everybody watching this match.
--- @param match table
local function pushHud(match)
    local players = ArenaLobby.PlayerArray(match)
    local scoreboard = scoreboardOf(players)

    local alive = 0
    for _, row in ipairs(scoreboard) do
        if row.alive then alive = alive + 1 end
    end

    -- Shared by reference across every recipient; only the personal kill and
    -- death counts differ, and nothing on the client writes back.
    local common = {
        alive = alive,
        total = #players,
        timeLeft = match.endsAt and math.max(0, match.endsAt - os.time()) or nil,
        pot = ArenaBetting.GetPot(match.id),
        scoreboard = scoreboard,
        teamCounts = Arena.CountTeams(players),
    }

    local function hudFor(kills, deaths)
        return {
            alive = common.alive,
            total = common.total,
            kills = kills,
            deaths = deaths,
            timeLeft = common.timeLeft,
            pot = common.pot,
            scoreboard = common.scoreboard,
            teamCounts = common.teamCounts,
        }
    end

    for _, player in ipairs(players) do
        TriggerClientEvent('crimson_arena:client:matchHud', player.src,
            hudFor(math.max(0, Arena.ToInt(player.kills) or 0), math.max(0, Arena.ToInt(player.deaths) or 0)))
    end

    -- A spectator has no numbers of their own, only the board.
    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            TriggerClientEvent('crimson_arena:client:matchHud', src, hudFor(0, 0))
        end
    end
end

--- Sends one player into the arena, frozen, with the loadout they are
--- actually going to hold.
--- @param match table
--- @param player table
--- @param index integer -- position in join order; the spawn is drawn from it
--- @param arena table
--- @param freezeSeconds integer
local function sendEnterArena(match, player, index, arena, freezeSeconds)
    local teamKey = teamOf(match, player)

    -- Set here rather than at join: somebody sitting in a lobby menu picking
    -- a rifle is not in a fight, and suppressing their alerts while they
    -- stand in the middle of town would be a hole, not a feature.
    ArenaDispatch.Set(player.src, match.id)

    -- Issued against this match so it can be reclaimed against it. A weapon
    -- whose ammo item could not be handed over is named for the operator;
    -- whether that player still fights is Config.Loadouts.ammoItems'
    -- allowWeaponWithoutAmmoItem to decide, not this line's.
    local missingAmmo = ArenaAmmo.Issue(player.src, match.id, player.loadout)
    if #missingAmmo > 0 then
        ArenaDebug('ammo: %s starts without items for %s', tostring(player.src), table.concat(missingAmmo, ', '))
    end

    -- Instanced BEFORE the client is told to teleport in, so the player
    -- materialises inside the match's own network instance rather than
    -- appearing in the arena in front of the whole server for the frame in
    -- between. Same choke point as the flag above for the reason given on
    -- sendExitArena: split them and they can disagree.
    ArenaDispatch.EnterBucket(player.src, match.id)
    instanced[player.src] = match.id

    -- The panel is where a player waits to be readied, so it is very often
    -- still open -- and still holding NUI focus -- at this exact moment.
    -- Focus routes every movement, aim and fire input into the browser, so a
    -- player who is not told to shut it stands in a live round as a
    -- motionless target behind a modal that also hides the countdown.
    -- Unconditional because ArenaUI.Close is safe on a panel already closed.
    TriggerClientEvent('crimson_arena:client:closePanel', player.src)

    TriggerClientEvent('crimson_arena:client:enterArena', player.src, {
        matchId = match.id,
        arenaKey = match.arenaKey,
        modeKey = match.modeKey,
        teamKey = teamKey,
        -- The plan first, the point list as the fallback. An arena with no
        -- spawnArea behaves exactly as it always did.
        spawn = toPoint((match.spawnPlan and match.spawnPlan[player.src])
            or Arena.PickSpawn(match.arenaKey, teamKey, index)),
        scatterRadius = scatterRadius(),
        -- The host's radar decision, carried in with everything else the
        -- round is fought under. The client keeps no preference of its own
        -- any more, so this is the only thing that turns a sweep on. Sent
        -- on entry only: the respawn payload does not repeat it, because a
        -- death is not an opportunity to re-decide the rules of the match.
        radar = match.radar == true,
        loadout = player.loadout,
        boundary = boundaryPayload(arena),
        weatherOverride = arena.weatherOverride,
        timeOverride = arena.timeOverride,
        freezeSeconds = freezeSeconds,
    })
end

--- Where every LIVE OPPONENT of one player currently is.
---
--- Teammates are deliberately left out: coming back near your own side is
--- the point of having one, and counting them as something to avoid would
--- push a returning player out to the empty edge of the arena alone.
---
--- Read from the engine rather than from anything the arena stores, because
--- what matters is where they are NOW, not where they started. A position
--- the server cannot read -- a player mid-stream, or one whose ped has not
--- been created yet -- is skipped rather than guessed at: an unreadable
--- opponent placed at the origin would drag every respawn to the far side of
--- the map.
--- @param match table
--- @param player table -- the one coming back
--- @return table[] positions
local function liveOpponentPositions(match, player)
    local teams = Arena.ModeUsesTeams(match.modeKey)
    local own = teams and teamOf(match, player) or nil

    local out = {}
    for src, entry in pairs(match.players or {}) do
        local sameSide = teams and Arena.IsKey(own) and teamOf(match, entry) == own
        if src ~= player.src and entry.alive == true and not sameSide then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local coords = GetEntityCoords(ped)
                -- The origin is what this native returns for a ped that does
                -- not really exist yet, and no arena is at 0,0,0.
                if coords and (coords.x ~= 0.0 or coords.y ~= 0.0) then
                    out[#out + 1] = coords
                end
            end
        end
    end
    return out
end

--- Puts a player back in at a fresh point with a fresh loadout once
--- `respawnDelaySeconds` is up.
---
--- Re-checked on the way back in rather than trusted from the way out: a
--- player can leave, or the round can end, while the timer is running.
--- @param match table
--- @param player table
local function scheduleRespawn(match, player)
    local matchId, src = match.id, player.src
    local delay = math.max(0, Arena.ToInt(Config.Match.respawnDelaySeconds) or 0)

    ArenaNotifyKey(src, 'notify.respawning', 'info', delay)

    CreateThread(function()
        if delay > 0 then Wait(delay * 1000) end

        local current = ArenaLobby.Get(matchId)
        if not current or current.state ~= 'live' then return end

        local entry = current.players[src]
        if not entry or entry.alive then return end

        -- Still counted, because it is what the fallback below uses on an
        -- arena that defines no spawn area at all.
        current.spawnCursor = (current.spawnCursor or 0) + 1

        -- Gun game hands back the rung they are on rather than the loadout
        -- they picked: coming back down the ladder on every death is not the
        -- mode. Every other mode re-resolves the stored choice as before.
        local loadout = loadoutFor(current, entry)
        entry.loadout = loadout
        entry.alive = true

        -- SOMEWHERE RANDOM, AND AWAY FROM WHOEVER IS STILL ALIVE TO SHOOT.
        --
        -- This used to be Arena.PickSpawn with the cursor above, which walks
        -- the arena's point list in order -- predictable, and on a short list
        -- that is the corner they died in a moment ago. Coming back inside
        -- somebody's crosshair is not a respawn.
        --
        -- PickRespawn samples the spawn area and takes the point whose
        -- nearest opponent is furthest away, falling back to the point list
        -- (from a random start) on an arena with no area. The cursor is kept
        -- only for that fallback.
        local team = teamOf(current, entry)
        local point = Arena.PickRespawn(current.arenaKey, team, liveOpponentPositions(current, entry))
            or Arena.PickSpawn(current.arenaKey, team, current.spawnCursor)

        TriggerClientEvent('crimson_arena:client:respawn', src, {
            spawn = toPoint(point),
            scatterRadius = scatterRadius(),
            loadout = loadout,
        })

        -- REVIVED AFTER THE CLIENT HAS STOOD THEM UP, NOT BEFORE.
        --
        -- This used to run first, and that was the bug: the medical script
        -- was told a player was alive while their body was still a corpse
        -- waiting on an event that had not been sent yet. Whatever it did
        -- then was undone by the resurrect and the teleport behind it, so a
        -- player with lives left came back still dead.
        --
        -- The client needs a moment to resurrect, wait for collision and be
        -- placed. Only once it has is there a living player for a revive to
        -- be about.
        -- Named apart from the respawn `delay` this function already has:
        -- one is how long a player lies there, the other is how long after
        -- they are up before the medical script is told. Confusing them
        -- would be easy and silent.
        local reviveAfter = math.max(0, Arena.ToInt(((Config.Dispatch or {}).revive or {}).afterRespawnDelayMs) or 0)
        if reviveAfter > 0 then
            CreateThread(function()
                Wait(reviveAfter)

                -- Re-checked rather than trusted: the round can end, or the
                -- player leave, while this is waiting. Reviving somebody who
                -- has gone home is harmless but pointless, and reviving into
                -- a match that has ended would fight its teardown.
                local live = ArenaLobby.Get(matchId)
                if not live or live.state ~= 'live' then return end
                if not live.players[src] then return end

                ArenaDispatch.Revive(src)
            end)
        else
            ArenaDispatch.Revive(src)
        end
    end)
end

-- ======================================================================
-- STARTING
-- ======================================================================

--- The client's killer claim, checked against what the server already knows.
---
--- Accepted only for a DIFFERENT player who is in this same match and whom
--- the mode would have let land the shot -- with friendly fire off a
--- teammate cannot be credited however the death was reported. The killer
--- is not required to still be alive: two players who kill each other in
--- the same exchange both earn the kill.
--- @param match table
--- @param victim table
--- @param killerSrc any -- straight off the wire
--- @return table|nil killer
local function resolveKiller(match, victim, killerSrc)
    local killerId = Arena.ToInt(killerSrc)
    if not killerId or killerId <= 0 or killerId == victim.src then return nil end

    local killer = match.players[killerId]
    if not killer then return nil end
    if not Arena.CanDamage(match.modeKey, killer.team, victim.team) then return nil end
    return killer
end

--- Drops anyone who never picked a side onto the smallest team.
---
--- Config.Teams.autoAssignIfUnchosen is applied at start rather than at join
--- time on purpose: "smallest team" means smallest when the fighting starts,
--- not smallest when the first player wandered in.
--- @param match table
--- @return boolean ok -- false only when the setting is off and somebody has no side
local function assignMissingTeams(match)
    if not Arena.ModeUsesTeams(match.modeKey) then return true end

    local players = ArenaLobby.PlayerArray(match)
    for _, player in ipairs(players) do
        if not Arena.GetTeamByKey(player.team) then
            if Config.Teams.autoAssignIfUnchosen == false then return false end
            -- Assigned in place, so the next unchosen player counts this one.
            player.team = Arena.SuggestTeam(players)
        end
    end
    return true
end

--- Weapons go live. Split out of Start because the freeze between the two is
--- long enough for the last player to disconnect.
--- @param matchId string
local function goLive(matchId)
    local match = ArenaLobby.Get(matchId)
    if not match or match.state ~= 'countdown' then return end

    local players = ArenaLobby.PlayerArray(match)
    local startable, reason = Arena.CanStartMatch({
        arenaKey = match.arenaKey,
        modeKey = match.modeKey,
        players = players,
    })
    if not startable then
        -- Nobody threw a punch, so nobody has earned anything: this is the
        -- refund path, not the results path.
        ArenaMatch.Abort(matchId, reason or 'match.ended_abandoned')
        return
    end

    match.state = 'live'
    -- Re-stamped to the real moment the fighting starts. server/betting.lua
    -- closes the side-bet window `closeAfterStartSeconds` after this, and a
    -- startsAt still sitting in the future would leave it uncloseable.
    match.startsAt = os.time()

    -- HOW MANY THE ROUND IS FOUGHT WITH, and this is the last moment it can
    -- be counted: ArenaLobby.Join refuses anything but a lobby, so from here
    -- the roster only ever shrinks, and every player in it has already paid
    -- a stake that is now in the pot. End() hands this to the payout as
    -- `contestants` -- read it there for what depends on it.
    --
    -- Counted here rather than in Start() because the two disagree: somebody
    -- who walks out during the frozen countdown is refunded by
    -- ArenaLobby.Leave -- that phase is still "before start" to the refund
    -- rules -- so counting them would judge the pot against a stake that has
    -- gone home.
    match.contestants = #players

    local roundTime = math.max(0, Arena.ToInt(Config.Match.roundTimeSeconds) or 0)
    match.endsAt = roundTime > 0 and (match.startsAt + roundTime) or nil

    pushToMatch(match, 'crimson_arena:client:matchLive', { endsAt = match.endsAt })
    ArenaLobby.Broadcast()
    ArenaDebug('match %s is live with %d player(s)', tostring(matchId), #players)
end

--- Validates a lobby and runs the countdown players may still back out of.
---
--- Returns as soon as the checks pass -- the countdown itself is a thread,
--- so the caller (a net event handler, or the lobby auto-starting) is not
--- held for `lobbyCountdownSeconds`.
--- @param matchId string
--- @param requestedBy integer? -- nil is the server itself, and is never refused
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaMatch.Begin(matchId, requestedBy)
    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end
    if match.state ~= 'lobby' then return false, 'error.match_already_started' end

    if requestedBy ~= nil then
        local requester = Arena.ToInt(requestedBy)
        local isHost = requester ~= nil and requester == match.hostSource
        local isAdmin = ArenaIsAdmin(requester)

        if Config.Match.onlyHostCanStart ~= false and not isHost and not isAdmin then
            return false, 'error.not_host'
        end
        -- With that setting off anyone in the lobby may start it -- anyone
        -- IN it. A player elsewhere on the server may not start a match they
        -- are not standing in.
        if not isHost and not isAdmin and not (requester and match.players[requester]) then
            return false, 'error.not_in_match'
        end
    end

    if not assignMissingTeams(match) then return false, 'error.no_team_chosen' end

    local ok, reason = Arena.CanStartMatch({
        arenaKey = match.arenaKey,
        modeKey = match.modeKey,
        players = ArenaLobby.PlayerArray(match),
    })
    if not ok then return false, reason end

    local countdown = math.max(0, Arena.ToInt(Config.Match.lobbyCountdownSeconds) or 0)
    match.state = 'countdown'
    -- An estimate for the panel's clock. goLive replaces it with the real
    -- one the moment the fighting starts.
    match.startsAt = os.time() + countdown + math.max(0, Arena.ToInt(Config.Match.startCountdownSeconds) or 0)
    ArenaLobby.Broadcast()

    CreateThread(function()
        local remaining = countdown
        while remaining > 0 do
            local current = ArenaLobby.Get(matchId)
            -- Gone, aborted, or already started by something else: this
            -- countdown is not the one that owns it any more.
            if not current or current.state ~= 'countdown' then return end

            local stillOk, why = Arena.CanStartMatch({
                arenaKey = current.arenaKey,
                modeKey = current.modeKey,
                players = ArenaLobby.PlayerArray(current),
            })
            if not stillOk then
                -- Someone backed out during the countdown, which they are
                -- allowed to do. The lobby goes back to waiting rather than
                -- closing, so the rest of the room keeps their seats.
                current.state = 'lobby'
                current.startsAt = nil
                for _, player in ipairs(ArenaLobby.PlayerArray(current)) do
                    ArenaNotifyKey(player.src, why or 'notify.start_cancelled', 'warning')
                end
                ArenaLobby.Broadcast()
                return
            end

            pushToMatch(current, 'crimson_arena:client:countdown', {
                seconds = remaining,
                label = locale('match.countdown_label'),
            })

            Wait(1000)
            remaining = remaining - 1
        end

        ArenaMatch.Start(matchId)
    end)

    return true, nil
end

--- Teleports everybody in, hands out the loadouts, and starts the frozen
--- countdown that ends with weapons live.
--- @param matchId string
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaMatch.Start(matchId)
    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end
    if match.state ~= 'lobby' and match.state ~= 'countdown' then
        return false, 'error.match_already_started'
    end

    local players = ArenaLobby.PlayerArray(match)
    local ok, reason = Arena.CanStartMatch({
        arenaKey = match.arenaKey,
        modeKey = match.modeKey,
        players = players,
    })
    if not ok then
        -- Nobody has been moved yet, so the lobby simply goes back to
        -- waiting.
        match.state = 'lobby'
        match.startsAt = nil
        ArenaLobby.Broadcast()
        return false, reason
    end

    local arena = Arena.GetArenaByKey(match.arenaKey)
    local freeze = math.max(0, Arena.ToInt(Config.Match.startCountdownSeconds) or 0)
    -- The host's choice, taken from the match rather than re-read from
    -- config, so a round plays the rule it was opened with.
    local lives = math.max(1, Arena.ToInt(match.lives) or 1)

    match.state = 'countdown'
    match.winners = nil
    match.payouts = nil
    -- Respawns carry on round-robin from where the initial placement left
    -- off.
    match.spawnCursor = #players

    -- THE WHOLE ROSTER AT ONCE, before anybody is placed.
    --
    -- Keeping two players apart is a fact about the PAIR, so it cannot be
    -- decided by looking at either one alone -- which is why this is planned
    -- for everybody here rather than answered per player inside the loop
    -- below. Nil when the arena defines no spawn area, and the exact point
    -- list is used exactly as before.
    match.spawnPlan = Arena.PlanSpawns(match.arenaKey, (function()
        local roster = {}
        for _, entry in ipairs(players) do
            roster[#roster + 1] = { src = entry.src, team = teamOf(match, entry) }
        end
        return roster
    end)())

    if match.spawnPlan then
        ArenaDebug('spawns: planned %d placement(s) inside %s\'s spawn area.',
            #players, tostring(match.arenaKey))
    end

    for index, player in ipairs(players) do
        player.kills = 0
        player.deaths = 0
        player.alive = true
        player.lives = lives
        player.placement = nil
        -- Round state like the rest of this block, and dead weight in every
        -- mode but gun game: everybody starts on the bottom rung with the
        -- ladder ahead of them.
        player.rung = 1
        player.ladderFinished = false

        -- RE-RESOLVED, NOT TRUSTED. What the lobby stored was checked against
        -- the catalogue as it stood when the player picked it, and an
        -- operator may have reloaded config since. Feeding the stored
        -- loadout back through the same function re-checks every weapon key
        -- and re-clamps every ammo count against the list that is live now.
        --
        -- In gun game it is not re-resolved but REPLACED, by the bottom rung
        -- of the ladder: the mode ignores the player's weapon choice, which
        -- is what config.lua promises next to the ladder itself.
        local loadout, rejected = loadoutFor(match, player)
        player.loadout = loadout
        if #rejected > 0 then
            ArenaDebug('dropped %d loadout entr(ies) for %s on match %s: %s',
                #rejected, tostring(player.src), tostring(match.id), table.concat(rejected, ', '))
        end

        sendEnterArena(match, player, index, arena, freeze)
    end

    ArenaLobby.Broadcast()

    CreateThread(function()
        if freeze > 0 then Wait(freeze * 1000) end
        goLive(matchId)
    end)

    return true, nil
end

-- ======================================================================
-- SCORING
-- ======================================================================

--- One player died. Scores it, spends a life, and eliminates them when they
--- have none left.
---
--- Deliberately does NOT decide the match: the sweep does that a tick later,
--- by which point everybody who died in this tick has been counted.
--- @param src integer -- the reporter; the only identity trusted here
--- @param killerSrc any -- claimed by the client, verified below
--- @return boolean counted
function ArenaMatch.OnDeath(src, killerSrc)
    local id = Arena.ToInt(src)
    if not id then return false end

    local match = ArenaLobby.GetByPlayer(id)
    if not match or match.state ~= 'live' then return false end

    local player = match.players[id]
    -- An already-dead player reporting another death is a client repeating
    -- itself or someone farming eliminations. Either way there is nothing to
    -- score, which also makes a spammed report cost one table lookup.
    if not player or player.alive ~= true then return false end

    player.alive = false
    player.deaths = (Arena.ToInt(player.deaths) or 0) + 1

    local killer = resolveKiller(match, player, killerSrc)
    if killer then
        killer.kills = (Arena.ToInt(killer.kills) or 0) + 1
        -- The kill is what moves them up the ladder, so the promotion sits
        -- with the score it is earned by and not with the elimination below.
        promote(match, killer)
    elseif killerSrc ~= nil then
        ArenaDebug('unverified kill claim on match %s: %s says %s killed them',
            tostring(match.id), tostring(id), tostring(killerSrc))
    end

    local remaining = (Arena.ToInt(player.lives) or 1) - 1
    player.lives = remaining

    if remaining > 0 then
        scheduleRespawn(match, player)
    else
        player.placement = placementFor(match)

        -- REGISTERED FIRST, AND THE CLIENT IS TOLD WHAT THE SERVER ACTUALLY
        -- DID. `spectate` is the client's instruction to come out of the
        -- dead-state hold and open the camera, and the only thing that keeps
        -- them out of the round afterwards is the registry listing them as a
        -- spectator: the very next Broadcast tells them `spectating = false`
        -- otherwise, and client/spectate.lua answers that by standing them
        -- back up -- visible, unfrozen and still holding the arena loadout,
        -- in a round they are out of. Refused registration therefore means
        -- refused camera: the hold stays, which is inert and recoverable.
        local spectate = Config.Match.spectateOnElimination == true
            and ArenaLobby.AddSpectator(id, match.id) == true

        -- ELIMINATION IS A DEATH THE PLAYER DOES NOT COME BACK FROM, so it
        -- is the one that most needs saying out loud. A respawn revives them
        -- and so does the exit, but an eliminated player sits between those
        -- two for the rest of the round -- watching, flagged dead by the
        -- medical script, with whatever that script does to a corpse still
        -- being done to them.
        -- KEEPING THE HOLD, which is the whole difference between this revive
        -- and every other one. The point here is the medical script's list,
        -- not the player's freedom: the round is still running and they are
        -- out of it. Released, they would be visible, solid and MORTAL in a
        -- live arena -- spectate restores the first two and never touches
        -- invincibility.
        ArenaDispatch.Revive(id, true)

        TriggerClientEvent('crimson_arena:client:eliminated', id, { matchId = match.id, spectate = spectate })
        ArenaNotifyKey(id, 'notify.eliminated', 'error')
    end

    ArenaLobby.Broadcast()
    return true
end

-- ======================================================================
-- FINISHING
-- ======================================================================

--- Ends a round that was actually fought: decides the winners, settles the
--- money, records it, and sends everybody home with a result.
--- @param matchId string
--- @param reasonKey string? -- locale key; what the players are told
--- @param winners table? -- as decided by the sweep; recomputed when absent
--- @return boolean ok
function ArenaMatch.End(matchId, reasonKey, winners)
    local match = ArenaLobby.Get(matchId)
    if not match then return false end
    -- Settling twice would pay twice; server/betting.lua would refuse the
    -- second one, loudly, but this is the guard that keeps it from getting
    -- there.
    if match.state == 'ended' then return false end

    local players = ArenaLobby.PlayerArray(match)
    if #players == 0 then
        -- Arena.ComputePayouts refunds an empty room by handing every player
        -- their stake back -- and with no players there is nobody to hand it
        -- to, so Settle would mark the pot spent and pay none of it out.
        -- Abort returns the money from escrow instead, which is where it
        -- still is.
        return ArenaMatch.Abort(matchId, reasonKey or 'match.ended_abandoned')
    end

    local teamMode = Arena.ModeUsesTeams(match.modeKey)
    if type(winners) ~= 'table' then
        -- Called by hand, without a decision: take the one the round has
        -- earned, and failing that the one the clock would have given it.
        winners = evaluate(match) or decideOnKills(match, teamMode)
    end

    match.state = 'ended'
    assignFinalPlacements(match)
    match.winners = winners

    local endReason = Arena.IsKey(reasonKey) and reasonKey or 'match.ended'

    -- `top_three` reads `winners` as a podium, best first, so under that
    -- payout a free-for-all hands over the finishing order rather than the
    -- single survivor. Every other payout mode splits evenly across whoever
    -- is in the list, which is why the list stays exactly the winners
    -- everywhere else.
    local payoutWinners = winners
    if Config.Betting.payout == 'top_three' and not teamMode and #winners > 0 then
        local ranked = standings(match)
        payoutWinners = {}
        for index = 1, math.min(3, #ranked) do payoutWinners[index] = ranked[index] end
    end

    -- TWO DIFFERENT HEAD COUNTS, and conflating them is what let a mid-round
    -- quitter take their stake home.
    --
    -- `players` is who is still here to be PAID, and it stays the surviving
    -- roster: Arena.ComputePayouts hands `stake` back off this list and
    -- splits per_kill across it, so a player who walked out must not be on
    -- it -- their stake was forfeited to the pot the moment they left, and
    -- listing them would hand it straight back. An ELIMINATED player is a
    -- different thing and stays: they fought the round to the end, and a
    -- round that refunds owes them their stake like anybody else.
    --
    -- `contestants` is how many the round was FOUGHT with, recorded at
    -- goLive. THE CONTRACT THIS RELIES ON: whatever judges Config.Betting
    -- .minPlayersToPayOut counts THIS, not #players. Counted off the
    -- survivors instead, a 1v1 that one side quits reads as "too few
    -- players" and refunds the whole pot -- which pays the winner nothing
    -- and hands the quitter back the stake that leaving was supposed to
    -- forfeit. It has to survive ArenaBetting.Settle, which rebuilds this
    -- table field by field on its way to Arena.ComputePayouts.
    --
    -- The fallback is for a round that never reached goLive and so has no
    -- fought-with count to have; the roster it still holds is the closest
    -- true answer available.
    local context = {
        teams = teamMode,
        winners = payoutWinners,
        contestants = match.contestants or #players,
        players = {},
    }
    for _, player in ipairs(players) do
        context.players[#context.players + 1] = {
            id = player.src,
            team = player.team,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            stake = ArenaBetting.GetStake(match.id, player.src),
            placement = player.placement,
        }
    end

    -- THE ORDER OF THESE FIVE IS FIXED, and each one depends on the one
    -- above it:
    --   Settle first -- it is what turns held stakes into payouts, and
    --     nothing below it can run against an undecided pot;
    --   RecordMatch second -- a player's earnings ARE those payouts, so a
    --     leaderboard written before them records every winner at zero;
    --   SettleSpectatorBets third -- it needs a decided result to judge
    --     bets against, and Clear hands unsettled side-bets BACK, so a Clear
    --     that ran first would quietly refund every winning side-bet;
    --   Clear fourth -- the only step that drops escrow, and it refuses
    --     while anything is still held, so running it before Settle would
    --     strand the pot with the match record already gone;
    --   Destroy last -- it removes the record all four of the others read.
    local payouts = ArenaBetting.Settle(match.id, context)
    match.payouts = payouts
    ArenaStats.RecordMatch(match)
    ArenaBetting.SettleSpectatorBets(match.id, winningPick(match, winners, teamMode))
    ArenaBetting.Clear(match.id)
    -- AND THE INVENTORY RECORDS, which nothing called at all. ArenaAmmo.Clear
    -- has always existed and always refused while anybody's kit is still
    -- stashed -- exactly like the betting Clear above refuses over escrow --
    -- and no path in this resource ever reached it. So every match this
    -- server ran left its issued-weapon and issued-ammunition tables behind
    -- for good. It sits beside the betting Clear because it is the same step:
    -- the point where a finished match stops being owed anything.
    ArenaAmmo.Clear(match.id)

    local won, earned = {}, {}
    for _, id in ipairs(winners) do won[id] = true end
    for _, payout in ipairs(payouts) do
        if payout.id ~= nil then
            earned[payout.id] = (earned[payout.id] or 0) + (Arena.ToInt(payout.amount) or 0)
        end
    end

    local board = scoreboardOf(players)
    local returnCoords = toPoint(Config.Lobby.returnCoords)
    local names = {}

    for _, player in ipairs(players) do
        if won[player.src] then
            names[#names + 1] = player.name or ArenaPlayerName(player.src)
            ArenaNotifyKey(player.src, 'notify.match_won', 'success')
        else
            ArenaNotifyKey(player.src, endReason, 'info')
        end

        local results = {
            matchId = match.id,
            reason = endReason,
            won = won[player.src] == true,
            placement = player.placement,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            deaths = math.max(0, Arena.ToInt(player.deaths) or 0),
            earnings = earned[player.src] or 0,
            scoreboard = board,
        }

        -- THE BOARD GOES OUT TWICE, and the second one is the one a player
        -- sees. It has ridden the exitArena payload since before anything on
        -- the client drew it, and that payload is this round's teardown
        -- message -- the numbers are there for a client that wants them at
        -- the moment it goes home. The board itself is a PANEL message:
        -- client/ui.lua registers `crimson_arena:client:results` for it, and
        -- with nothing firing that event the payout board this file spends
        -- the whole of End() working out was never drawn for anybody.
        --
        -- Sent after the exit rather than before it because the exit is what
        -- closes the round down on the client -- the HUD, the countdown, the
        -- teleport home. A board drawn ahead of that is cleared by the tidy
        -- up behind it.
        sendExitArena(player.src, { returnCoords = returnCoords, results = results })
        TriggerClientEvent('crimson_arena:client:results', player.src, results)
    end

    -- Spectators watched it, so they see the board; they were never in the
    -- arena, so they win nothing and are owed nothing. The board is the only
    -- reason they are sent anything at all at the end of a round.
    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            local results = {
                matchId = match.id,
                reason = endReason,
                won = false,
                earnings = 0,
                scoreboard = board,
            }
            sendExitArena(src, { returnCoords = returnCoords, results = results })
            TriggerClientEvent('crimson_arena:client:results', src, results)
        end
    end

    -- THE REVIVE SWEEP, and it is deliberately not the same call as the one
    -- inside sendExitArena above.
    --
    -- That one runs BEFORE the client is told to leave: before the ped is
    -- stood up, before the teleport home, before the arena instance is left.
    -- A medical script revived at that moment is being told somebody is
    -- alive while they are still a corpse in another routing bucket, and
    -- whatever it does next can be undone by the teardown that follows.
    --
    -- So the whole roster is swept again once all of that has finished. It is
    -- idempotent -- reviving somebody who is already alive costs nothing --
    -- and it is the belt to the earlier call's braces: whatever went wrong on
    -- the way out, nobody is left standing in the lobby dead.
    local roster = {}
    for _, player in ipairs(players) do
        if type(player.src) == 'number' then roster[#roster + 1] = player.src end
    end

    local sweepMs = Arena.ToInt(((Config.Dispatch or {}).revive or {}).sweepAfterMatchMs)
    if sweepMs and sweepMs > 0 and #roster > 0 then
        -- CreateThread + Wait rather than SetTimeout: it is the delay idiom
        -- everywhere else in this file, it is what the test harness can step,
        -- and it is one fewer native for the allow-list to carry.
        CreateThread(function()
            Wait(sweepMs)

            for _, src in ipairs(roster) do
                -- Not filtered on "was in a match": they have left one by
                -- now, which is the entire point. Anyone who has since
                -- disconnected is a no-op inside Revive.
                ArenaDispatch.Revive(src)
            end
            ArenaDebug('revive: swept %d player(s) %dms after the match ended.', #roster, sweepMs)
        end)
    end

    if Config.Webhook.logResults == true then
        local lines = {}
        for _, row in ipairs(board) do
            lines[#lines + 1] = ('%s -- %d kill(s), %d death(s)'):format(row.name, row.kills, row.deaths)
        end
        ArenaWebhook(('Match %s finished'):format(tostring(match.id)), endReason, {
            { name = 'Arena', value = tostring(match.arenaKey) },
            { name = 'Mode', value = tostring(match.modeKey) },
            { name = 'Winners', value = #names > 0 and table.concat(names, ', ') or 'none (draw)' },
            { name = 'Scoreboard', value = table.concat(lines, '\n') },
        })
    end

    -- The instance goes back to the pool. ExitBucket already frees it as the
    -- last person walks out, so on a normal finish this is a no-op -- it is
    -- here for the match everybody had already disconnected from, where
    -- there was no last person to walk out and the number would otherwise be
    -- held against a match id that no longer exists.
    ArenaDispatch.ReleaseBucket(match.id)

    ArenaLog('match %s ended: %s', tostring(match.id), endReason)
    ArenaLobby.Destroy(match.id, endReason)
    return true
end

--- The refund-everything path: a resource stop, an admin force-stop, a
--- lobby that emptied out, a round that could not start.
---
--- Nothing is recorded and nobody is paid, because no result was reached.
--- Every stake goes back, and every side-bet goes back with it -- with no
--- outcome to judge them against the house has no claim on either.
--- @param matchId string
--- @param reasonKey string?
--- @return boolean ok
function ArenaMatch.Abort(matchId, reasonKey)
    local match = ArenaLobby.Get(matchId)
    if not match then return false end

    local reason = Arena.IsKey(reasonKey) and reasonKey or 'match.aborted'
    match.state = 'ended'
    match.winners = nil
    match.payouts = nil

    local returnCoords = toPoint(Config.Lobby.returnCoords)
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        ArenaNotifyKey(player.src, reason, 'warning')
    end
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        sendExitArena(player.src, { returnCoords = returnCoords })
    end
    for src in pairs(match.spectators or {}) do
        -- Same double-send guard pushToMatch applies: an eliminated fighter
        -- who stayed to watch sits in both tables.
        if not match.players[src] then
            sendExitArena(src, { returnCoords = returnCoords })
        end
    end

    ArenaBetting.RefundAll(match.id, reason)
    ArenaBetting.SettleSpectatorBets(match.id, nil)
    ArenaBetting.Clear(match.id)
    -- AND THE INVENTORY RECORDS, which nothing called at all. ArenaAmmo.Clear
    -- has always existed and always refused while anybody's kit is still
    -- stashed -- exactly like the betting Clear above refuses over escrow --
    -- and no path in this resource ever reached it. So every match this
    -- server ran left its issued-weapon and issued-ammunition tables behind
    -- for good. It sits beside the betting Clear because it is the same step:
    -- the point where a finished match stops being owed anything.
    ArenaAmmo.Clear(match.id)

    -- Same reason as in End: the abort path is the one that runs when
    -- everybody has already gone, so it is the one that has to collect the
    -- bucket nobody was left to release.
    ArenaDispatch.ReleaseBucket(match.id)

    ArenaLog('match %s aborted: %s', tostring(match.id), reason)
    ArenaLobby.Destroy(match.id, reason)
    return true
end

--- One player out, mid-round: they left, they were dropped, or an admin
--- pulled them.
---
--- The lobby owns what leaving costs them -- the refund rules and the host
--- transfer are its call. This owns only what their leaving does to the
--- round they were in.
--- @param src integer
--- @param reasonKey string?
--- @return boolean ok
function ArenaMatch.RemovePlayer(src, reasonKey)
    local id = Arena.ToInt(src)
    if not id then return false end

    local match = ArenaLobby.GetByPlayer(id)
    if not match then
        -- Not fighting in one. They may still be watching one.
        ArenaLobby.RemoveSpectator(id)
        return false
    end

    local matchId = match.id
    local inProgress = match.state == 'live' or match.state == 'countdown'
    local player = match.players[id]

    if player and inProgress then
        player.alive = false
        -- Placed on the way out so the results board can still rank them
        -- rather than leaving a hole where they were.
        if not player.placement then player.placement = placementFor(match) end
        sendExitArena(id, {
            returnCoords = toPoint(Config.Lobby.returnCoords),
        })
    end

    ArenaLobby.Leave(id, reasonKey or 'match.left')

    -- Leave may already have destroyed the match -- it does when the last
    -- player walks out of a lobby.
    local current = ArenaLobby.Get(matchId)
    if current and inProgress and ArenaLobby.PlayerCount(current) == 0 then
        -- Everybody disconnected mid-round. There is nobody to declare a
        -- winner over and nobody to pay, so the money goes back.
        ArenaMatch.Abort(matchId, 'match.ended_abandoned')
    end

    return true
end

-- ======================================================================
-- QUERIES
-- ======================================================================

--- @param matchId string
--- @return boolean
function ArenaMatch.IsLive(matchId)
    local match = ArenaLobby.Get(matchId)
    return match ~= nil and match.state == 'live'
end

--- The rungs of a mode's gun-game ladder that can actually be handed out,
--- resolved against the live weapon catalogue. Empty for every other mode,
--- and for a ladder whose every rung names a weapon an operator switched off.
--- @param modeKey any
--- @return table[] rungs
function ArenaMatch.GetLadder(modeKey)
    return ladderFor(modeKey)
end

--- Which rung `kills` has earned on a ladder `rungs` long, and whether that
--- finished it. Exposed because this arithmetic IS the mode -- it is worth
--- checking on its own, without a match record around it.
--- @param kills any
--- @param rungs any
--- @return integer rung
--- @return boolean finished
function ArenaMatch.RungForKills(kills, rungs)
    return rungForKills(kills, rungs)
end

--- Every match currently being fought. IsLive is true for every record this
--- returns -- a lobby still filling up is not one of them.
--- @return table[] matches
function ArenaMatch.GetLive()
    local out = {}
    for _, match in ipairs(ArenaLobby.All()) do
        if match.state == 'live' then out[#out + 1] = match end
    end
    return out
end

-- ======================================================================
-- THE SWEEP
--
-- One thread for every live match rather than one thread each: the work is
-- a handful of table walks a second, and a thread per match is a thread per
-- match to leak when one ends badly.
-- ======================================================================

--- Reconciles who is standing in a match's routing bucket against who the
--- registry says is in a match. Does two jobs, and the second is the reason
--- it is a reconcile rather than another call site.
---
--- ONE: SPECTATORS. Without this a spectator watches an empty room -- the
--- fighters are in a bucket their watcher is not in, so nothing about them
--- replicates to that client: no peds, no gunfire, and a spectator camera
--- pointed at a player id its game does not have. Spectators are attached
--- and detached by server/lobby.lua from three call sites this file does not
--- own, so they are reconciled rather than intercepted. Being the only thing
--- that puts them in the arena, this is also the only thing that can PUBLISH
--- that it did -- so the dispatch flag is raised and dropped here alongside
--- the bucket, for spectators and for nobody else.
---
--- TWO: EVERY LEAK, INCLUDING THE ONES NOT WRITTEN YET. sendExitArena is the
--- exit this file controls, and it is not the only way out of a countdown or
--- a live round. The frozen-countdown hole it was written for is closed --
--- main.lua's detach() now routes through RemovePlayer, which handles both
--- phases -- but this does not depend on that staying true. Rather than trust
--- that every current and future departure remembers, anyone holding a bucket
--- who is no longer in a countdown or live match is put back where they came
--- from within a tick.
--- A stranded player cannot fix this themselves and an operator cannot
--- easily see it, so it is worth a table walk a second.
local function syncMatchBuckets()
    local wanted = {}

    --- Everyone SOME countdown or live match calls a FIGHTER. A separate
    --- record rather than a read of `wanted`, because it answers a different
    --- question and has to answer it the same way whichever order
    --- ArenaLobby.All() handed the matches back in: an eliminated fighter is
    --- in both of their match's tables, and "not claimed yet" would make the
    --- answer depend on which loop reached them first.
    --- @type table<number, boolean>
    local fighting = {}

    for _, match in ipairs(ArenaLobby.All()) do
        -- 'countdown' as well as 'live': Start() has already put the
        -- fighters in the arena by then, so a match in its frozen countdown
        -- is every bit as instanced as one being fought.
        if match.state == 'countdown' or match.state == 'live' then
            for src in pairs(match.players) do
                wanted[src] = match.id
                fighting[src] = true
            end
            -- An eliminated fighter who stayed to watch is in both tables and
            -- has already been claimed by the loop above.
            for src in pairs(match.spectators or {}) do
                if wanted[src] == nil then wanted[src] = match.id end
            end
        end
    end

    for src, matchId in pairs(wanted) do
        if instanced[src] ~= matchId then
            -- THE FLAG FOLLOWS THE BUCKET, for the one group no choke point
            -- covers. sendEnterArena raises it for every fighter in the same
            -- breath as it instances them; a spectator is put in that same
            -- instance by this sweep and was left unflagged, so the state-bag
            -- guard an operator pastes into their dispatch script suppressed
            -- nothing their client raised -- and their client is inside the
            -- fight, seeing every shot of it.
            --
            -- FIGHTERS ARE DELIBERATELY NOT FLAGGED HERE. 'countdown' names
            -- the LOBBY countdown as well as the frozen one, so this loop
            -- reaches players who have not been teleported anywhere yet.
            -- Flagging those would suppress the alerts of someone standing in
            -- the middle of town -- the hole ArenaDispatch.Set's own comment
            -- refuses to open -- and would make server/lobby.lua's
            -- playersArePlaced read a filling lobby as a round in progress and
            -- refuse its host the cancel button. sendEnterArena is what raises
            -- a fighter's flag, and it runs when they are actually placed.
            if not fighting[src] then ArenaDispatch.Set(src, matchId) end
            ArenaDispatch.EnterBucket(src, matchId)
            instanced[src] = matchId
        end
    end

    -- Clearing an entry during the walk is defined in Lua, which is what
    -- makes this safe to do in place rather than into a second table.
    for src in pairs(instanced) do
        if wanted[src] == nil then
            ArenaDispatch.ExitBucket(src)
            -- Paired with the bucket for the reason sendExitArena gives: put
            -- the two on separate call sites and they can disagree about who
            -- is in a match. Unconditional and safe on somebody who was never
            -- flagged -- ArenaDispatch.Clear documents that no-op -- and an
            -- eliminated fighter cannot reach it, because match.players kept
            -- them in `wanted` above.
            ArenaDispatch.Clear(src)
            instanced[src] = nil
        end
    end
end

CreateThread(function()
    while true do
        Wait(SWEEP_INTERVAL_MS)

        -- Before the win check, not after: a match that ends this tick sends
        -- everybody home through sendExitArena, and reconciling afterwards
        -- would read a registry it had just been removed from.
        syncMatchBuckets()

        -- ArenaLobby.All() hands back a fresh array, so ending a match --
        -- which removes it from the registry -- cannot disturb this loop.
        for _, match in ipairs(ArenaLobby.All()) do
            if match.state == 'live' then
                local winners, reason = evaluate(match)
                if winners then
                    ArenaMatch.End(match.id, reason, winners)
                else
                    pushHud(match)
                end
            end
        end
    end
end)
