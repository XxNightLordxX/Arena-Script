-- Crimson Arena: the round itself. Countdown, kills, and endings.

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

local SWEEP_INTERVAL_MS = 1000

local function toPoint(value)
    local kind = type(value)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then return nil end

    local indexed = kind == 'table' and value or nil
    local x = tonumber(value.x) or (indexed and tonumber(indexed[1]))
    local y = tonumber(value.y) or (indexed and tonumber(indexed[2]))
    local z = tonumber(value.z) or (indexed and tonumber(indexed[3]))
    if not x or not y or not z then return nil end

    local w = 0.0
    if kind ~= 'vector3' then
        w = tonumber(value.w) or (indexed and tonumber(indexed[4])) or 0.0
    end

    return { x = x, y = y, z = z, w = w }
end

local function scatterRadius()
    return math.max(0.0, tonumber(Config.Match.spawnScatterRadius) or 0.0)
end

local function boundaryPayload(arena, factor)
    -- Through Arena.BoundaryOf: one reading of `enabled` shared with the
    -- keep-out fence, the explosion guard and the validator, which used to
    -- disagree with this line about a block that omits the key.
    local boundary = Arena.BoundaryOf(arena)
    if not boundary then return nil end

    local center = toPoint(boundary.center)
    if not center then
        ArenaLog('BOUNDARY IGNORED: arena "%s" has a boundary switched on whose centre cannot be read -- ' ..
            'it needs x, y and z. Nobody will be warned or bled for leaving it.',
            tostring(arena.label or '?'))
        return nil
    end

    return {
        enabled = true,
        center = center,
        radius = (tonumber(boundary.radius) or 0.0) * math.max(1.0, tonumber(factor) or 1.0),
        warningSeconds = math.max(0, Arena.ToInt(boundary.warningSeconds) or 0),
        damagePerTick = math.max(0, Arena.ToInt(boundary.damagePerTick) or 0),
        tickMs = math.max(100, Arena.ToInt(boundary.tickMs) or 1000),
    }
end

-- ======================================================================
-- GUN GAME
--
-- Config.Modes.gungame, played.
--
-- THE CLOCK IS THE ROUND, NOT THE LIVES. Nobody is ever eliminated in a gun
-- game. A death costs a TIER and nothing else, so a player is in the round
-- from the first second to the last, and the round ends when the mode's own
-- roundTimeSeconds runs out or when somebody tops the ladder -- whichever
-- comes first. That is why `evaluate` skips the score limit and the
-- last-man-standing rule for a ladder match: neither has anything to decide.
--
-- THE LADDER IS THE LOADOUT. What a player picked in the panel is never
-- handed out in this mode -- the ladder replaces it on the way in, on every
-- tier change and on every respawn. Armour, health and supplies are not a
-- weapon choice and are left exactly as they are everywhere else.
--
-- A TIER IS DERIVED FROM THE SCORE, NEVER COUNTED UP. Two kills landing
-- between one sweep and the next move a player once per tier and never
-- twice, and a kill the server refused to credit cannot leave anybody
-- standing a tier above what they earned.
--
-- AND THE SCORE IS NOT THE KILL COUNT. It is ladder kills less tiers lost,
-- which is what makes a death cost the weapon: `kills` stays honest for the
-- scoreboard, the leaderboard and the payout, and the ladder keeps its own
-- two numbers next to it.
--
-- THE LADDER IS DRAWN ONCE PER MATCH AND THEN FIXED. Config gives ordered
-- POOLS -- melee, then sidearms, then up -- and one weapon is taken from
-- each when the round needs a ladder. Two matches on the same mode at the
-- same time therefore climb different guns, which is the point: the shape is
-- learnable, the ladder is not.
-- ======================================================================

--- What `maxTiersPerVictim` falls back to when config gives a value that
--- cannot be read as a number.
---
--- IT MATCHES THE SHIPPED CONFIG DELIBERATELY. Falling back to "no cap"
--- meant a typo switched the anti-collusion rule off; falling back to 1
--- would quietly make an operator's mode stricter than they wrote. The
--- shipped number is the one they had before they mistyped it.
local DEFAULT_TIERS_PER_VICTIM = 2

local function ladderOf(match)
    if type(match) ~= 'table' then return {} end
    if type(match.ladder) == 'table' then return match.ladder end

    -- THIS MATCH'S OWN SHAPE. `tierPlan` is what the host built in the
    -- creation menu -- how many rungs of each weapon class -- and nil means
    -- they left it alone, which falls through to the mode's own defaults.
    -- Read off the match rather than the config for the same reason its lives
    -- and its clock are: an operator editing the classes mid-session must not
    -- reshape a ladder that is already being climbed.
    local tiers = Arena.LadderTiersFor(match.modeKey, match.tierPlan)
    local drawn = {}
    for _, pool in ipairs(tiers) do
        drawn[#drawn + 1] = pool[math.random(#pool)]
    end

    if not Arena.PlaysLadder(match.modeKey) then
        if #drawn > 0 then
            ArenaDebug('gun game: %s has only %d playable tier(s) -- not a ladder, playing it as ordinary rules.',
                tostring(match.modeKey), #drawn)
        end
        drawn = {}
    else
        local names = {}
        for index, weapon in ipairs(drawn) do
            names[#names + 1] = ('%d:%s'):format(index, weapon.key)
        end
        ArenaDebug('gun game: match %s drew the ladder %s', tostring(match.id), table.concat(names, ' '))
    end

    match.ladder = drawn
    return drawn
end

--- The score a player climbs on: the kills that counted for the ladder, less
--- the tiers their deaths have cost them. Never below zero.
---
--- SEPARATE FROM `kills`, and that is the point of it. A death must not take
--- away a kill that really happened -- the scoreboard, the leaderboard and
--- the payout all read `kills`, and rewriting it to move somebody down a
--- tier would quietly edit history.
---
--- AND SEPARATE FROM `kills` IN THE OTHER DIRECTION TOO. `ladderKills` is
--- the kills that were allowed to move the killer: a kill past
--- `maxTiersPerVictim` on the same opponent still counts as a kill and still
--- pays, it just stops buying tiers. See `creditsTier`.
--- @param player table
--- @return integer
local function tierScore(player)
    local climbed = math.max(0, Arena.ToInt(player.ladderKills) or 0)
    local lost = math.max(0, Arena.ToInt(player.tiersLost) or 0)
    return math.max(0, climbed - lost)
end

local function tierForScore(score, tiers)
    local total = math.max(0, Arena.ToInt(tiers) or 0)
    local scored = math.max(0, Arena.ToInt(score) or 0)
    if total <= 0 then return 1, false end
    if scored >= total then return total, true end
    return scored + 1, false
end

local function kitFor(match, player)
    local kit = Arena.StartingKitFor(match and match.modeKey)
    if kit ~= nil then return kit end
    return type(player) == 'table' and type(player.loadout) == 'table'
        and player.loadout.supplies or nil
end

--- Whether this player's score has topped the ladder.
---
--- DERIVED, NEVER STORED, and it used to be a field. `player.ladderFinished`
--- was a second copy of something tierScore already answers, and the two
--- came apart the moment anything touched one without the other:
---
---   A DEMOTION THAT THE INVENTORY REFUSED. The death charged a tier, the
---   flag was recomputed as false, the swap was refused, and OnDeath rolled
---   the charge back -- leaving a player whose score had topped the ladder
---   flagged as not having done so. They could never win on it, and the
---   round went to whoever topped it next, as a sole win over a tie.
---
--- One reader is what makes that impossible rather than merely fixed, and it
--- is the same lesson as the scoreboard sorting on the held tier while the
--- winner was picked on the earned one.
--- @param player table
--- @param tiers integer -- how tall the drawn ladder is
--- @return boolean
local function topped(player, tiers)
    return select(2, tierForScore(tierScore(player), tiers)) == true
end

local function tierLoadout(weapon, supplies, rounds)
    -- THROUGH Arena.ResolveWeaponEntry, NOT HAND-BUILT, and the difference
    -- was four fields. The hand-built entry had no `ammoType`, no
    -- `ammoTypeLabel` and -- the one that showed -- no `ammoTypeItem`, which
    -- is what ArenaAmmo splits a magazine off and issues loose rounds
    -- against: without it the whole pick sat in the magazine, no rounds were
    -- ever handed over as items, and the arena never recorded owing them. It
    -- also held `weapon.components` by REFERENCE, which is the operator's
    -- live config table.
    --
    -- NOT Arena.ResolveLoadout, which is the other half of that function and
    -- deliberately not called: that one judges a PLAYER'S REQUEST against
    -- Config.Loadouts.allowMelee, allowFirearms and the slot count. The
    -- ladder is the operator's own list and nobody requested it -- a server
    -- that does not let players PICK a blade still opens its gun game on one.
    --
    -- THE MODE'S TIER AMMUNITION, not the weapon's own default, and the
    -- difference is what a climber has to fight a tier with. A promotion
    -- sweeps the previous rung's rounds away along with its gun, so whatever
    -- lands here is the whole supply for that tier -- and the per-weapon
    -- default is 60 for a sidearm, which is a magazine and a half.
    --
    -- nil falls straight back to that default: with no ask to resolve,
    -- ResolveAmmo hands back the weapon's own number clamped to its own max.
    -- So a mode that sets no `tierAmmo` behaves exactly as it did.
    local tier = Arena.ResolveWeaponEntry(weapon, Arena.ResolveAmmoType(weapon, nil), rounds)

    local base = Arena.ResolveLoadout({ weapons = {} })

    -- SUPPLIES ARE CARRIED FORWARD DELIBERATELY. A tier change rewrites the
    -- loadout in place, and a hand-built table that forgets a field silently
    -- takes it away -- here, the kit a player walked in with would vanish
    -- from the record the moment they moved a tier, and the exit would
    -- reclaim against a record that no longer mentioned it.
    --
    -- WHAT IS NOT IN HERE: the bandages a kill has paid. Those go through
    -- ArenaAmmo.GrantSupply onto the ammo ledger and never enter this
    -- record -- an earlier version of this comment said they did, which
    -- would have made the record the thing the exit reclaims against and it
    -- is not.
    --
    -- ARMOUR IS NOT CARRIED FORWARD EITHER, and cannot be: Arena.StartingVitals
    -- is a rule of the arena, and Arena.ResolveLoadout ignores any `armor`
    -- in the request it is handed. This used to pass the player's previous
    -- armour in and read the constant back out.
    return {
        weapons = { tier },
        armor = base.armor,
        health = base.health,
        supplies = supplies ~= nil and supplies or base.supplies,
    }
end

local function loadoutFor(match, player)
    local ladder = ladderOf(match)
    if #ladder == 0 then return Arena.ResolveLoadout(player.loadout) end

    local tier = Arena.ClampInt(player.tier, 1, #ladder) or 1
    player.tier = tier

    return tierLoadout(ladder[tier], kitFor(match, player), Arena.TierAmmoFor(match.modeKey)), {}
end

local function creditsTier(match, killer, victim)
    local mode = Arena.GetModeByKey(match.modeKey) or {}

    local configured = Arena.ToInt(mode.maxTiersPerVictim)
    if configured == nil or configured < 0 then configured = DEFAULT_TIERS_PER_VICTIM end

    -- AND IT CAN NEVER BE TIGHTER THAN THE LADDER NEEDS.
    --
    -- The cap makes you spread your kills across the field. In a field of
    -- two there is nothing to spread across: with seven tiers and a cap of
    -- two, topping the ladder takes four different victims, so the mode's
    -- own win condition was unreachable below five players while
    -- Config.Match.minPlayers ships at 2. A four-man lobby watched somebody
    -- collect "No tier for that one" forever and the round always went to
    -- the clock.
    --
    -- So the floor is what a lone climber would need against everybody else
    -- in the room. It is the same rule in both directions -- with enough
    -- opponents this is smaller than the configured cap and changes nothing,
    -- and it only ever loosens where a farm could not have paid anyway: the
    -- accomplice in a two-man match is the only other stake in the pot.
    local cap = configured
    if cap > 0 then
        local roster = Arena.ToInt(match.ladderSpread) or Arena.Count(match.players)
        local opponents = math.max(0, roster - 1)
        local height = #ladderOf(match)

        local spread = math.max(2, opponents)
        local needed = math.ceil(height / spread)
        if needed > cap then cap = needed end
    end

    if type(killer.ladderVictims) ~= 'table' then killer.ladderVictims = {} end
    local taken = math.max(0, Arena.ToInt(killer.ladderVictims[victim.src]) or 0)

    if cap > 0 and taken >= cap then
        ArenaDebug('gun game: %s has taken %d tier(s) off %s already -- this kill pays nothing.',
            tostring(killer.src), taken, tostring(victim.src))
        return false
    end

    killer.ladderVictims[victim.src] = taken + 1
    return true
end

--- Gives one per-victim credit back when a tier is lost.
---
--- IN A PLAYER'S WORDS: "when you hit your max tier then die a lot then you
--- kill that same person you wont go back up".
---
--- creditsTier counts kills PER VICTIM and the count only ever went up, while
--- a player's position is `ladderKills - tiersLost` and goes both ways. So a
--- climber who reached the top off three kills on somebody, then died three
--- times, was back on tier 1 with that opponent recorded as having bought
--- them three tiers -- and worth nothing to them for the rest of the round.
--- They could stand next to the only other player in the arena, kill them
--- repeatedly, and never move.
---
--- WHAT THE CAP IS ACTUALLY FOR is bounding how much of the ladder ONE
--- opponent can carry you up. A tier you climbed and then lost carried you
--- nowhere, so it should not be held against that opponent -- and once the
--- credit is refunded the count means "tiers this victim is holding me up
--- by", which is the thing worth capping.
---
--- THE LARGEST ENTRY PAYS. Which victim a lost tier belongs to is not
--- recorded and could not be without pretending to know something the round
--- never established, so the loss comes off whoever has bought the most --
--- the one the cap is policing. It cannot let a farm through: the total
--- refunded can never exceed the total lost, so a player who never dies is
--- capped exactly as before.
--- @param player table
local function refundTierCredit(player)
    if type(player.ladderVictims) ~= 'table' then return end

    local worst, most = nil, 0
    for src, taken in pairs(player.ladderVictims) do
        local count = math.max(0, Arena.ToInt(taken) or 0)
        if count > most then worst, most = src, count end
    end

    if worst == nil then return end
    if most <= 1 then
        player.ladderVictims[worst] = nil
    else
        player.ladderVictims[worst] = most - 1
    end
end

local function rolled(chance)
    if chance == nil then return true end

    local percent = Arena.ToInt(chance)
    if percent == nil then return false end

    if percent <= 0 then return false end
    if percent >= 100 then return true end
    return math.random(100) <= percent
end

local function payKillAmmo(match, killer)
    local rounds = Arena.KillAmmoFor(match.modeKey)
    if not rounds then return end

    local loadout = killer.loadout
    if type(loadout) ~= 'table' then return end

    -- PER WEAPON, NOT PER CALIBRE, and the loop is deliberately not
    -- de-duplicated by item. The rule config states is "this many rounds for
    -- each firearm you are carrying", so two nine-millimetre pistols are two
    -- payments of nine-millimetre: what you are carrying is what you are paid
    -- for. Collapsing them would quietly make a two-pistol loadout worth half
    -- what a pistol-and-rifle loadout is.
    --
    -- MELEE FALLS OUT ON ITS OWN. A blade names no ammoTypeItem -- see
    -- Arena.ResolveWeaponEntry -- so there is nothing to hand over and no
    -- rule of its own is needed.
    for _, entry in ipairs(loadout.weapons or {}) do
        if Arena.IsKey(entry.ammoTypeItem) then
            ArenaAmmo.GrantRounds(killer.src, match.id, entry.ammoTypeItem, rounds)
        end
    end
end

local function payKillReward(match, killer)
    local mode = Arena.GetModeByKey(match.modeKey) or {}
    local rewards = mode.killReward
    if type(rewards) ~= 'table' then return end

    local paid = {}
    local remaining = Arena.SupplyTotalCap()
    local capped = remaining > 0

    for _, entry in ipairs(rewards) do
        if type(entry) == 'table' then
            local supply = Arena.SupplyByKey(entry.key)

            -- CLAMPED TO THE SUPPLY'S OWN `max`, exactly as a player's
            -- request is by Arena.ResolveSupplies. Without it the picker and
            -- the kill reward disagreed about how many of a supply a player
            -- may hold: a reward of 99999 bandages against a configured
            -- ceiling of 30 handed over 99999.
            local room = supply
                and math.max(0, Arena.SupplyMax(supply) - (paid[supply.key] or 0))
                or 0
            local count = supply and (Arena.ClampInt(entry.count, 0, room) or 0) or 0

            if capped and count > remaining then count = remaining end

            if supply and Arena.IsKey(supply.item) and count > 0 and rolled(entry.chance) then
                if ArenaAmmo.GrantSupply(killer.src, match.id, supply.item, count) then
                    paid[supply.key] = (paid[supply.key] or 0) + count
                    if capped then remaining = remaining - count end
                end
            end
        end
    end
end

local function settleTier(match, player, reasonKey)
    local ladder = ladderOf(match)
    if #ladder == 0 then return true end

    local tier = tierForScore(tierScore(player), #ladder)

    if tier == player.tier then return true end

    local previous = player.tier and ladder[player.tier] or nil
    local moving = tierLoadout(ladder[tier], kitFor(match, player), Arena.TierAmmoFor(match.modeKey))
    local weapon = moving.weapons[1]

    local dropped = previous and previous.weapon or nil

    local rungs = {}
    for _, rung in ipairs(ladder) do
        if Arena.IsKey(rung.weapon) then rungs[#rungs + 1] = rung.weapon end
    end

    local swapped, why = ArenaAmmo.SwapWeapon(player.src, match.id, dropped, weapon, rungs)
    if not swapped and why == 'refused' then
        ArenaDebug('gun game: %s stays on tier %s -- ox_inventory would not take back %s.',
            tostring(player.src), tostring(player.tier), tostring(dropped))
        return false
    end

    player.tier = tier
    player.loadout = moving

    if reasonKey == 'notify.gungame_demoted' then
        ArenaNotifyKey(player.src, 'notify.gungame_demoted', 'error', tier, #ladder, weapon.label)
    else
        ArenaNotifyKey(player.src, 'notify.gungame_promoted', 'success', tier, #ladder, weapon.label)
    end

    local mode = Arena.GetModeByKey(match.modeKey) or {}
    if mode.announceFinalTier ~= false and tier == #ladder
        and not topped(player, #ladder)
    then
        for _, other in pairs(match.players) do
            if other.src ~= player.src then
                ArenaNotifyKey(other.src, 'notify.gungame_final_tier', 'warning', player.name)
            end
        end
    end

    return true
end

local function teamOf(match, player)
    if not Arena.ModeUsesTeams(match.modeKey) then return nil end
    return Arena.IsKey(player.team) and player.team or nil
end

local function placementFor(match)
    local total, placed = 0, 0
    for _, player in pairs(match.players) do
        total = total + 1
        if player.placement then placed = placed + 1 end
    end
    return math.max(1, total - placed)
end

local function stillIn(player)
    return not Arena.IsEliminated(player)
end

local function teamKills(match)
    local scores = {}

    for team, banked in pairs(match.departedKills or {}) do
        if Arena.IsKey(team) then scores[team] = math.max(0, Arena.ToInt(banked) or 0) end
    end

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
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        if player.team == teamKey then ids[#ids + 1] = player.src end
    end
    return ids
end

local function decideOnKills(match, teamMode)
    local scores, best = {}, 0

    if teamMode then
        scores = teamKills(match)
    else
        -- ONLY PLAYERS STILL IN THE ROUND ARE CANDIDATES. An eliminated
        -- fighter keeps their row on purpose -- the results board ranks off
        -- it, and the spectator gate reads it -- so scoring every row handed
        -- the round to somebody who was already out, with the last-place
        -- placement elimination gave them still on their record.
        --
        -- The clock is where that actually bit: rack up kills, get knocked
        -- out, wait, and the timer crowned you and paid you the pot over the
        -- people still fighting for it.
        --
        -- Teams are deliberately NOT filtered this way. A side is still in
        -- the round while any member is, and a fallen team-mate's kills were
        -- won for that side -- evaluate has already ended the round if only
        -- one side is left standing, so the sides being compared here are
        -- all still in it.
        for _, player in pairs(match.players) do
            if stillIn(player) then
                scores[player.src] = math.max(0, Arena.ToInt(player.kills) or 0)
            end
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

--- Who is winning a gun game when the clock runs out: the player standing
--- highest on the ladder.
---
--- NOT decideOnKills, AND THE DIFFERENCE IS THE MODE. A tier is kills less
--- deaths, so a player who traded twelve for eleven is standing one step up
--- and a player who took six for nothing is standing six -- raw kills would
--- crown the first of those, which is not the race anybody in the round
--- thought they were running.
---
--- KILLS BREAK A TIE, and only a tie. Two players level on tiers have
--- climbed the same distance; the one who fought more to get there takes it.
--- Level on both is a DRAW and returns nobody, which refunds the pot: paying
--- one of two identical runs out of the other's stake is a coin toss with
--- somebody else's money. A round where nobody climbed at all is a draw for
--- the same reason.
---
--- ONLY PLAYERS STILL IN THE ROUND ARE CANDIDATES, exactly as in
--- decideOnKills. Nobody is eliminated in a gun game, so in practice that is
--- everybody -- but the two functions answer the same question and must not
--- be able to disagree about who is eligible for it.
--- @param match table
--- @return integer[] winners -- empty when there is no clear leader
local function decideOnLadder(match)
    local bestTier, bestKills, leaders = 0, 0, {}

    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        if stillIn(player) then
            local tier = tierScore(player)
            -- THE TIE IS BROKEN ON LADDER KILLS, NOT RAW ONES.
            --
            -- `kills` is the one number in this mode the anti-collusion cap
            -- deliberately leaves uncapped -- a kill past the cap still
            -- counts as a kill, it just stops buying tiers -- so breaking a
            -- tier tie on it handed the decider straight back to the farm
            -- the cap exists to stop. `ladderKills` is the capped number and
            -- is what the tiers were actually climbed on.
            local kills = math.max(0, Arena.ToInt(player.ladderKills) or 0)
            if tier > bestTier or (tier == bestTier and kills > bestKills) then
                bestTier, bestKills, leaders = tier, kills, { player.src }
            elseif tier == bestTier and kills == bestKills then
                leaders[#leaders + 1] = player.src
            end
        end
    end

    if bestTier <= 0 then return {} end
    if #leaders ~= 1 then return {} end
    return leaders
end

local function reachedScoreLimit(match, teamMode)
    local limit = Arena.ScoreLimitFor(match.scoreLimit)

    if teamMode then
        for _, score in pairs(teamKills(match)) do
            if score >= limit then return true end
        end
        return false
    end

    -- Same candidates as decideOnKills, for the same reason and so the two
    -- cannot disagree: a limit reached by a player who is out would end the
    -- round on their score and then hand it to somebody else's.
    for _, player in pairs(match.players) do
        if stillIn(player) and (Arena.ToInt(player.kills) or 0) >= limit then return true end
    end
    return false
end

local function evaluate(match)
    local teamMode = Arena.ModeUsesTeams(match.modeKey)

    local total, standing, lastStanding = 0, 0, nil
    local standingTeams = {}
    for _, player in pairs(match.players) do
        total = total + 1
        if stillIn(player) then
            standing = standing + 1
            lastStanding = player
            if teamMode and Arena.IsKey(player.team) then
                standingTeams[player.team] = (standingTeams[player.team] or 0) + 1
            end
        end
    end

    if total == 0 then return {}, 'match.ended_abandoned' end

    local ladder = ladderOf(match)
    local playingLadder = #ladder > 0

    local climbed = {}
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        if playingLadder and stillIn(player) and topped(player, #ladder) then
            climbed[#climbed + 1] = player.src
        end
    end
    if #climbed == 1 then return climbed, 'match.ended_ladder' end
    if #climbed > 1 then return {}, 'match.ended_draw' end

    -- AND THE OTHER TWO CONDITIONS DO NOT APPLY TO A LADDER AT ALL.
    --
    -- Nobody is eliminated in a gun game -- a death costs a tier, not a life
    -- -- so the last-standing rule below can never fire in one: everybody is
    -- standing until the clock stops. It is skipped rather than left to be
    -- unreachable, because "unreachable" is a property of today's rules and
    -- a mode that ends on a count of survivors would silently start ending
    -- gun games on the wrong thing.
    --
    -- The score limit is different: it CAN fire, and it would be wrong when
    -- it did. It ends the round on raw kills, and a ladder is not raw kills
    -- -- a player who traded fifteen deaths for fifteen kills is standing on
    -- tier 1 and would take the pot off somebody six tiers above them.
    -- THE MATCH'S OWN CONDITION, not the config's. The host picks it when
    -- they create the round and it is stored on the match, so re-reading the
    -- config here would let an operator's mid-session edit change how a match
    -- already being fought is won.
    if not playingLadder and Arena.WinConditionFor(match.winCondition) == 'score_limit'
        and reachedScoreLimit(match, teamMode)
    then
        local winners = decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_score_limit' or 'match.ended_draw'
    end

    if not playingLadder then
        if teamMode then
            local occupied = Arena.Count(standingTeams)
            if occupied == 0 then return {}, 'match.ended_draw' end
            if occupied == 1 then return membersOfTeam(match, (next(standingTeams))), 'match.ended_last_standing' end
        else
            if standing == 0 then return {}, 'match.ended_draw' end
            if standing == 1 and total > 1 then return { lastStanding.src }, 'match.ended_last_standing' end
        end
    end

    if not teamMode and total == 1 then
        if lastStanding then return { lastStanding.src }, 'match.ended_abandoned' end
        return {}, 'match.ended_abandoned'
    end

    if match.endsAt and os.time() >= match.endsAt then
        local winners = playingLadder and decideOnLadder(match) or decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_time_up' or 'match.ended_draw'
    end

    return nil, nil
end

local function assignFinalPlacements(match, winners)
    local ordered = {}
    for _, player in pairs(match.players) do ordered[#ordered + 1] = player end

    local won = {}
    for _, src in ipairs(winners or {}) do won[src] = true end

    local ladder = #ladderOf(match)

    table.sort(ordered, function(a, b)
        local aWon, bWon = won[a.src] == true, won[b.src] == true
        if aWon ~= bWon then return aWon end

        local aOut, bOut = a.placement ~= nil, b.placement ~= nil
        if aOut ~= bOut then return bOut end
        if aOut and a.placement ~= b.placement then return a.placement < b.placement end

        if ladder > 0 then
            local aTier, bTier = tierScore(a), tierScore(b)
            if aTier ~= bTier then return aTier > bTier end
        end
        local aKills, bKills = Arena.ToInt(a.kills) or 0, Arena.ToInt(b.kills) or 0
        if aKills ~= bKills then return aKills > bKills end
        local aDeaths, bDeaths = Arena.ToInt(a.deaths) or 0, Arena.ToInt(b.deaths) or 0
        if aDeaths ~= bDeaths then return aDeaths < bDeaths end
        return a.src < b.src
    end)

    for index, player in ipairs(ordered) do player.placement = index end
end

local function scoreboardOf(players, tiers)
    local ladder = math.max(0, Arena.ToInt(tiers) or 0)
    local rows = {}
    for _, player in ipairs(players) do
        rows[#rows + 1] = {
            id = player.src,
            name = player.name or ArenaPlayerName(player.src),
            team = player.team,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            deaths = math.max(0, Arena.ToInt(player.deaths) or 0),
            -- THE TIER, and the height of the ladder, so the board everybody
            -- is already looking at is where a gun game is read. Absent in
            -- every other mode, which is how the panel knows not to draw a
            -- column for it.
            --
            -- This is the whole of the tier display. The client event that
            -- used to carry it is gone: ox_inventory owns weapons, the
            -- server has already swapped the item by the time anybody could
            -- be told, and a second channel saying the same thing is a
            -- second channel that can disagree.
            -- THE TIER THEIR SCORE HAS EARNED, not the one their pockets
            -- happen to hold. The two are the same in every ordinary round
            -- and diverge the moment a swap is refused -- and when they
            -- diverged, this board sorted on one number while
            -- `decideOnLadder` crowned the other, so the race was ranked
            -- backwards for the rest of the round and the winner came off
            -- the bottom of it. Read through the same two functions the
            -- winner is read through, and they cannot disagree.
            tier = ladder > 0 and (tierForScore(tierScore(player), ladder)) or nil,
            tiers = ladder > 0 and ladder or nil,
            alive = player.alive == true,
            remaining = stillIn(player),
        }
    end

    table.sort(rows, function(a, b)
        if a.tier ~= b.tier then return (a.tier or 0) > (b.tier or 0) end
        if a.kills ~= b.kills then return a.kills > b.kills end
        if a.deaths ~= b.deaths then return a.deaths < b.deaths end
        return a.id < b.id
    end)
    return rows
end

local function winningPick(match, winners, teamMode)
    local first = winners and winners[1]
    if first == nil then return nil end
    if not teamMode then return first end

    local player = match.players[first]
    return player and player.team or nil
end

local instanced = {}

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
    ArenaAmmo.Reclaim(src, 'left the arena')

    ArenaDispatch.Clear(src)
    ArenaDispatch.ExitBucket(src)
    instanced[src] = nil

    ArenaDispatch.Revive(src)

    TriggerClientEvent('crimson_arena:client:exitArena', src, payload)
end

local function sendPlayerHome(player, payload)
    if player.leftArena then return false end
    player.leftArena = true
    sendExitArena(player.src, payload)
    return true
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

local function pushHud(match)
    local players = ArenaLobby.PlayerArray(match)
    local scoreboard = scoreboardOf(players, #ladderOf(match))

    local remaining = 0
    for _, row in ipairs(scoreboard) do
        if row.remaining then remaining = remaining + 1 end
    end

    local common = {
        remaining = remaining,
        total = #players,
        livesSpent = #ladderOf(match) == 0
            and Arena.WinConditionSpendsLives(match.winCondition),
        timeLeft = match.endsAt and math.max(0, match.endsAt - os.time()) or nil,
        pot = ArenaBetting.GetPrizePool(match.id),
        scoreboard = scoreboard,
    }

    local function hudFor(kills, deaths)
        return {
            remaining = common.remaining,
            total = common.total,
            kills = kills,
            deaths = deaths,
            timeLeft = common.timeLeft,
            pot = common.pot,
            scoreboard = common.scoreboard,
        }
    end

    for _, player in ipairs(players) do
        TriggerClientEvent('crimson_arena:client:matchHud', player.src,
            hudFor(math.max(0, Arena.ToInt(player.kills) or 0), math.max(0, Arena.ToInt(player.deaths) or 0)))
    end

    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            TriggerClientEvent('crimson_arena:client:matchHud', src, hudFor(0, 0))
        end
    end
end

local function sendEnterArena(match, player, index, arena, freezeSeconds)
    local teamKey = teamOf(match, player)

    -- NOBODY STARTS A ROUND DEAD.
    --
    -- IN A PLAYER'S WORDS: "if i kill someone prior to a match start they
    -- spawn in dead". Being shot in the street is a thing that happens to
    -- somebody queued for a round, and nothing between the lobby and the
    -- arena floor looked at whether they were on their feet -- so they were
    -- teleported in, frozen for the countdown, and then stood there down for
    -- the whole match while everybody else fought over them.
    --
    -- THE SAME CALL THE RESPAWN AND THE TABLET MAKE, so a server's own
    -- medical script decides what standing somebody up means; this resource
    -- has not had a revive of its own since it was deliberately removed.
    -- Harmless for the overwhelming majority who walk in alive: reviving
    -- somebody who is already up is what the medical script is asked to
    -- ignore, and it does.
    ArenaDispatch.Revive(player.src)

    ArenaDispatch.Set(player.src, match.id)

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

    TriggerClientEvent('crimson_arena:client:closePanel', player.src)

    TriggerClientEvent('crimson_arena:client:enterArena', player.src, {
        matchId = match.id,
        arenaKey = match.arenaKey,
        modeKey = match.modeKey,
        teamKey = teamKey,
        spawn = toPoint((match.spawnPlan and match.spawnPlan[player.src])
            or Arena.PickSpawn(match.arenaKey, teamKey, index)),
        scatterRadius = (match.spawnPlan and match.spawnPlan[player.src]) and 0.0 or scatterRadius(),
        -- The client builds the floor and the cover, so it needs the same
        -- number the spawns and the boundary were worked out from. Sent
        -- rather than recomputed on that side: the roster is not a thing the
        -- client can see, and two ends deriving the same number separately
        -- is how they come to disagree.
        sizeFactor = match.sizeFactor,
        radar = match.radar == true,
        loadout = player.loadout,
        boundary = boundaryPayload(arena, match.sizeFactor),
        weatherOverride = arena.weatherOverride,
        timeOverride = arena.timeOverride,
        freezeSeconds = freezeSeconds,
    })
end

local function positionOf(src)
    local ped = GetPlayerPed(Arena.ToInt(src) or -1)
    if not ped or ped == 0 then return nil end

    local coords = GetEntityCoords(ped)
    if type(coords) ~= 'table' and type(coords) ~= 'userdata' then return nil end
    if (coords.x == 0.0 or coords.x == 0) and (coords.y == 0.0 or coords.y == 0) then return nil end
    return coords
end

local function metresBetween(a, b)
    if not a or not b then return nil end
    local dx = (a.x or 0.0) - (b.x or 0.0)
    local dy = (a.y or 0.0) - (b.y or 0.0)
    local dz = (a.z or 0.0) - (b.z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function livePositions(match, player, sameSideWanted)
    local teams = Arena.ModeUsesTeams(match.modeKey)
    local own = teams and teamOf(match, player) or nil

    if sameSideWanted and not (teams and Arena.IsKey(own)) then return {} end

    local out = {}
    for src, entry in pairs(match.players or {}) do
        local sameSide = teams and Arena.IsKey(own) and teamOf(match, entry) == own
        if src ~= player.src and entry.alive == true and sameSide == sameSideWanted then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                local coords = GetEntityCoords(ped)
                if coords and (coords.x ~= 0.0 or coords.y ~= 0.0) then
                    out[#out + 1] = coords
                end
            end
        end
    end
    return out
end

local function serverChecks()
    local block = (Config.Match or {}).serverChecks
    if type(block) ~= 'table' or block.enabled ~= true then return false, 0.0, 0, 0 end

    return true,
        math.max(0.0, tonumber(block.outsideMetres) or 60.0),
        math.max(1, Arena.ToInt(block.outsideTicks) or 8),
        math.max(0, Arena.ToInt(block.deadTicks) or 4)
end

local function metresOutside(match, src)
    local arena = Arena.GetArenaByKey(match.arenaKey)
    local boundary = Arena.BoundaryOf(arena)
    if not boundary then return nil end

    local centre = toPoint(boundary.center)
    if not centre then return nil end

    local radius = (tonumber(boundary.radius) or 0.0)
        * math.max(1.0, tonumber(match.sizeFactor) or 1.0)
    if radius <= 0 then return nil end

    local far = metresBetween(centre, positionOf(src))
    if not far then return nil end
    return far - radius
end

local function readsAsDead(src)
    if type(GetEntityHealth) ~= 'function' then return false end
    if positionOf(src) == nil then return false end

    local ped = GetPlayerPed(Arena.ToInt(src) or -1)
    if not ped or ped == 0 then return false end

    local health = tonumber(GetEntityHealth(ped))
    return health ~= nil and health <= 0
end

local function strike(store, src, sighted, needed)
    if not sighted then
        store[src] = nil
        return false
    end

    local count = (Arena.ToInt(store[src]) or 0) + 1
    store[src] = count
    if count < needed then return false end

    store[src] = nil
    return true
end

local function runServerChecks(match)
    local on, outsideMetres, outsideTicks, deadTicks = serverChecks()
    if not on then return end

    match.fenceStrikes = match.fenceStrikes or {}
    match.deadStrikes = match.deadStrikes or {}

    local roster = {}
    for src, player in pairs(match.players or {}) do
        if player.alive == true and player.leftArena ~= true then roster[#roster + 1] = src end
    end

    for _, src in ipairs(roster) do
        local player = (match.players or {})[src]
        if player and player.alive == true and match.state == 'live' then
            local past = metresOutside(match, src)
            if strike(match.fenceStrikes, src, past ~= nil and past > outsideMetres, outsideTicks) then
                ArenaLog('FENCE: %s has been %.0fm outside match %s for %d checks running -- removed from the round.',
                    tostring(src), past, tostring(match.id), outsideTicks)
                ArenaNotifyKey(src, 'notify.fence_removed', 'error')
                ArenaMatch.RemovePlayer(src, 'notify.fence_removed', true)
            elseif deadTicks > 0
                and strike(match.deadStrikes, src, readsAsDead(src), deadTicks)
            then
                ArenaLog('DEATH: %s has read as dead in match %s for %d checks running with nothing reported -- booking it.',
                    tostring(src), tostring(match.id), deadTicks)
                ArenaMatch.OnDeath(src, nil)
            end
        end
    end
end

local RECENT_SPAWN_MS = 3000

--- Points already handed to OTHER fighters a moment ago.
---
--- WHY THE ROSTER CANNOT ANSWER THIS. scheduleRespawn yields exactly once,
--- at its Wait, and then runs to the client event without yielding again. So
--- two fighters killed in the same frame -- a trade, a grenade -- produce two
--- threads that wake on the same tick and run back to back. Neither can see
--- where the other was just sent: liveOpponentPositions reads
--- GetEntityCoords, which for a player told to respawn microseconds ago is
--- still their CORPSE.
---
--- Both calls then run the same maximin over the same threats, and a maximin
--- on a disc with a handful of threats has one sharp optimum. Both find it.
--- Measured against the shipped arenas: on the skydome, 62-76% of same-tick
--- pairs land within ten metres of each other and over a third within five,
--- closest 0.03m -- two fighters materialising inside one another with full
--- loadouts, in a round whose stated contract is a 10m separation.
---
--- Entry placement has never had this problem because Arena.PlanSpawns plans
--- the whole roster at once, and says why: keeping two players apart is a
--- fact about the PAIR, so it cannot be decided by looking at either alone.
--- The respawn path is per-player and has no equivalent. This is the smallest
--- thing that gives it one: the points go into the avoid list, which
--- PickRespawn already takes.
--- @param match table
--- @param player table
--- @return table[] points
local function recentSpawnPoints(match, player)
    local out = {}
    local recent = match.recentSpawns
    if type(recent) ~= 'table' then return out end

    local now = GetGameTimer()
    for src, row in pairs(recent) do
        if type(row) ~= 'table' or (now - (row.at or 0)) > RECENT_SPAWN_MS then
            recent[src] = nil
        elseif src ~= player.src and type(row.point) == 'table' then
            out[#out + 1] = row.point
        end
    end
    return out
end

local function liveOpponentPositions(match, player)
    return livePositions(match, player, false)
end

local function liveTeammatePositions(match, player)
    return livePositions(match, player, true)
end

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

        current.spawnCursor = (current.spawnCursor or 0) + 1

        local loadout = loadoutFor(current, entry)
        entry.loadout = loadout
        entry.alive = true

        if #ladderOf(current) == 0 then
            ArenaAmmo.Refresh(src, current.id, loadout)
        end

        local team = teamOf(current, entry)

        local avoid = liveOpponentPositions(current, entry)
        for _, taken in ipairs(recentSpawnPoints(current, entry)) do
            avoid[#avoid + 1] = taken
        end

        local planned = Arena.PickRespawn(current.arenaKey, team, avoid,
            nil, current.sizeFactor, liveTeammatePositions(current, entry))
        local point = planned or Arena.PickSpawn(current.arenaKey, team, current.spawnCursor)

        if type(point) == 'table' then
            current.recentSpawns = current.recentSpawns or {}
            current.recentSpawns[src] = {
                point = { x = point.x, y = point.y, z = point.z },
                at = GetGameTimer(),
            }
        end

        TriggerClientEvent('crimson_arena:client:respawn', src, {
            spawn = toPoint(point),
            scatterRadius = planned and 0.0 or scatterRadius(),
            loadout = loadout,
        })

        local reviveAfter = math.max(0, Arena.ToInt(((Config.Dispatch or {}).revive or {}).afterRespawnDelayMs) or 0)
        if reviveAfter > 0 then
            CreateThread(function()
                Wait(reviveAfter)

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

local function resolveKiller(match, victim, killerSrc)
    local killerId = Arena.ToInt(killerSrc)
    if not killerId or killerId <= 0 or killerId == victim.src then return nil end

    local killer = match.players[killerId]
    if not killer then return nil end
    if not Arena.CanDamage(match.modeKey, killer.team, victim.team) then return nil end

    if killer.leftArena == true or Arena.IsEliminated(killer) then
        ArenaDebug('kill refused on match %s: %s named %s, who is out of the round.',
            tostring(match.id), tostring(victim.src), tostring(killerId))
        return nil
    end

    -- AND WERE THEY ANYWHERE NEAR. Everything above this line is a question
    -- about the ROSTER; none of it asks whether the kill could have happened.
    -- A dying client names its own killer, so without this one accomplice
    -- hands another every kill in the round from across the map, and that
    -- decides a team deathmatch, a last-man-standing round and the pot.
    --
    -- IT DOES NOT MAKE THE REPORT HONEST -- two players standing together
    -- can still trade kills nobody fired -- but it forces them to be there,
    -- which costs them the round they are trying to win.
    --
    -- FAILS OPEN, ON PURPOSE. GetEntityCoords answers a zero vector for a
    -- ped that has not streamed in, and refusing a real kill because the
    -- server could not see one of the two bodies would take a fought kill
    -- off an honest player. A ceiling nobody can reach is worth more than a
    -- guard that eats real results.
    --
    -- MEASURED AGAINST THIS ARENA, NOT A FLAT NUMBER. Config.Match
    -- .maxKillDistance is a floor; Arena.KillCeilingFor raises it to the span
    -- of the boundary the fight is being held inside, grown with the roster.
    -- Read flat it was SMALLER than both shipped arenas, so two fighters at
    -- opposite edges of the arena they were put in had their kills refused --
    -- the long shots, which is to say the good ones.
    local ceiling = Arena.KillCeilingFor(match.arenaKey, match.sizeFactor)
    if ceiling > 0 then
        local far = metresBetween(positionOf(killer.src), positionOf(victim.src))
        if far and far > ceiling then
            ArenaDebug('kill refused on match %s: %s says %s killed them from %.1fm, over the %.1fm ceiling.',
                tostring(match.id), tostring(victim.src), tostring(killerId), far, ceiling)
            return nil
        end
    end

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
    local assigned = 0
    for _, player in ipairs(players) do
        if not Arena.GetTeamByKey(player.team) then
            if Config.Teams.autoAssignIfUnchosen == false then return false end
            player.team = Arena.SuggestTeam(players)
            assigned = assigned + 1
        end
    end

    local counts, order = {}, {}
    for _, player in ipairs(players) do
        local key = Arena.IsKey(player.team) and player.team or 'none'
        if counts[key] == nil then order[#order + 1] = key end
        counts[key] = (counts[key] or 0) + 1
    end
    table.sort(order)

    local parts = {}
    for _, key in ipairs(order) do
        parts[#parts + 1] = ('%s %d'):format(key, counts[key])
    end
    ArenaDebug('teams: match %s starts %s (%d assigned, %d chose their own). Anyone alone on a side has no teammate to outline.',
        tostring(match.id), table.concat(parts, ' v '), assigned, #players - assigned)

    return true
end

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
        ArenaMatch.Abort(matchId, reason or 'match.ended_abandoned')
        return
    end

    match.state = 'live'
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

    local roundTime = Arena.RoundSecondsFor(match.modeKey, match.roundTimeSeconds)
    match.endsAt = roundTime > 0 and (match.startsAt + roundTime) or nil

    pushToMatch(match, 'crimson_arena:client:matchLive', { endsAt = match.endsAt })
    ArenaLobby.Broadcast()

    local untilClosed = ArenaBetting.SecondsUntilBetsClose(match)
    if untilClosed then
        CreateThread(function()
            Wait(untilClosed * 1000)
            local current = ArenaLobby.Get(matchId)
            if current and current.state == 'live' then ArenaLobby.Broadcast() end
        end)
    end

    ArenaDebug('match %s is live with %d player(s)', tostring(matchId), #players)
end

local function arenaIsFree(match)
    if ArenaDispatch.GetBucket(match.id) ~= nil then return true end

    for _, other in ipairs(ArenaLobby.All()) do
        if other.id ~= match.id and other.arenaKey == match.arenaKey
            and (other.state == 'live' or other.state == 'countdown')
        then
            ArenaLog('MATCH REFUSED: %s cannot start in arena "%s" while match %s is being fought there -- this server is not instancing matches, so they would share the ground.',
                tostring(match.id), tostring(match.arenaKey), tostring(other.id))
            return false
        end
    end
    return true
end

function ArenaMatch.Begin(matchId, requestedBy)
    local match = ArenaLobby.Get(matchId)
    if not match then return false, 'error.match_not_found' end
    if match.state ~= 'lobby' then return false, 'error.match_already_started' end

    -- OPENING HOURS, before anything is mutated. Begin is reachable without
    -- a fresh Join -- a lobby that formed while the arena was open and is
    -- started after the bell -- and it is the one gate the host's Start
    -- Match Now, an admin start and the auto-start when everybody readies
    -- all pass through.
    --
    -- Placed above assignMissingTeams on purpose: a refusal here must leave
    -- the roster exactly as it found it.
    if not ArenaHoursOpen() then return false, 'error.arena_shut' end

    if requestedBy ~= nil then
        local requester = Arena.ToInt(requestedBy)
        local isHost = requester ~= nil and requester == match.hostSource
        local isAdmin = ArenaIsAdmin(requester)

        if Config.Match.onlyHostCanStart ~= false and not isHost and not isAdmin then
            return false, 'error.not_host'
        end
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

    if not arenaIsFree(match) then return false, 'error.arena_in_use' end

    local countdown = math.max(0, Arena.ToInt(Config.Match.lobbyCountdownSeconds) or 0)
    match.state = 'countdown'

    match.countdownToken = (Arena.ToInt(match.countdownToken) or 0) + 1
    local token = match.countdownToken
    match.startsAt = os.time() + countdown + math.max(0, Arena.ToInt(Config.Match.startCountdownSeconds) or 0)
    ArenaLobby.Broadcast()

    CreateThread(function()
        local remaining = countdown
        while remaining > 0 do
            local current = ArenaLobby.Get(matchId)
            if not current or current.state ~= 'countdown' then return end

            local stillOk, why = Arena.CanStartMatch({
                arenaKey = current.arenaKey,
                modeKey = current.modeKey,
                players = ArenaLobby.PlayerArray(current),
            })
            if not stillOk then
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

        local current = ArenaLobby.Get(matchId)
        if not current or current.state ~= 'countdown' or current.countdownToken ~= token then
            return
        end

        local started, refusal = ArenaMatch.Start(matchId)
        if not started and Arena.IsKey(refusal) then
            local failed = ArenaLobby.Get(matchId)
            for _, player in ipairs(failed and ArenaLobby.PlayerArray(failed) or {}) do
                ArenaNotifyKey(player.src, refusal,
                    player.src == (failed and failed.hostSource) and 'error' or 'warning')
            end
        end
    end)

    return true, nil
end

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
    if ok and not ArenaHoursOpen() then
        ok, reason = false, 'error.arena_shut'
    end

    if ok and not arenaIsFree(match) then
        ok, reason = false, 'error.arena_in_use'
    end

    if not ok then
        match.state = 'lobby'
        match.startsAt = nil

        for _, player in pairs(match.players) do player.ready = false end

        ArenaLobby.Broadcast()
        return false, reason
    end

    local arena = Arena.GetArenaByKey(match.arenaKey)
    local freeze = math.max(0, Arena.ToInt(Config.Match.startCountdownSeconds) or 0)
    local lives = math.max(1, Arena.ToInt(match.lives) or 1)

    match.state = 'countdown'
    match.winners = nil
    match.payouts = nil

    match.ladder = nil

    -- Last round's leavers must not score for this one.
    match.departedKills = nil

    match.ladderSpread = #players
    match.spawnCursor = #players

    match.sizeFactor = Arena.SizeFactor(match.arenaKey, #players)

    match.spawnPlan = Arena.PlanSpawns(match.arenaKey, (function()
        local roster = {}
        for _, entry in ipairs(players) do
            roster[#roster + 1] = { src = entry.src, team = teamOf(match, entry) }
        end
        return roster
    end)(), nil, match.sizeFactor)

    if match.spawnPlan then
        ArenaDebug('spawns: planned %d placement(s) inside %s\'s spawn area (size factor %.2f).',
            #players, tostring(match.arenaKey), match.sizeFactor)
    end

    for index, player in ipairs(players) do
        player.kills = 0
        player.deaths = 0
        player.alive = true
        player.lives = lives
        player.placement = nil
        player.leftArena = nil

        player.tier = nil
        player.tiersLost = nil
        player.ladderKills = nil
        player.ladderVictims = nil

        local loadout, rejected = loadoutFor(match, player)
        player.loadout = loadout
        if #rejected > 0 then
            ArenaDebug('dropped %d loadout entr(ies) for %s on match %s: %s',
                #rejected, tostring(player.src), tostring(match.id), table.concat(rejected, ', '))
        end

        sendEnterArena(match, player, index, arena, freeze)
    end

    match.placed = true

    ArenaLobby.Broadcast()

    CreateThread(function()
        if freeze > 0 then Wait(freeze * 1000) end
        goLive(matchId)
    end)

    return true, nil
end

--- One player died. Scores it, and spends a life -- eliminating them when
--- they have none left -- in every mode EXCEPT a ladder, where a death costs
--- a tier instead and nobody is ever eliminated.
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
    if not player or player.alive ~= true then return false end

    -- AND WERE THEY EVEN IN THE ARENA. A death is reported by the dying
    -- player's own game, and until this line the server asked only whether
    -- the reporter was in a live match and currently alive -- never whether
    -- a death could have happened where they are standing. So a client sat
    -- outside the fight could report a death every respawn delay and hand an
    -- accomplice a kill for each one.
    --
    -- IT IS THE SAME LINE THE FENCE DRAWS, deliberately: a player far enough
    -- outside to be removed from the round is a player far enough outside to
    -- have nothing to die of. Anything closer is passed through -- an
    -- honest fighter bleeding to death a step past the boundary is exactly
    -- the death this must not refuse.
    --
    -- FAILS OPEN. metresOutside answers nil for an arena with no boundary and
    -- for a body the server cannot see, and neither is grounds for calling a
    -- player a liar.
    local on, outsideMetres = serverChecks()
    if on then
        local past = metresOutside(match, id)
        if past ~= nil and past > outsideMetres then
            ArenaDebug('death refused on match %s: %s reported dying %.0fm outside the arena.',
                tostring(match.id), tostring(id), past)
            return false
        end
    end

    player.alive = false
    player.deaths = (Arena.ToInt(player.deaths) or 0) + 1

    if type(ArenaCompat) == 'table' and type(ArenaCompat.WarnLateStartOnce) == 'function' then
        ArenaCompat.WarnLateStartOnce()
    end

    local playingLadder = #ladderOf(match) > 0

    local killer = resolveKiller(match, player, killerSrc)
    if killer then
        killer.kills = (Arena.ToInt(killer.kills) or 0) + 1

        if playingLadder then
            if creditsTier(match, killer, player) then
                killer.ladderKills = (Arena.ToInt(killer.ladderKills) or 0) + 1
                settleTier(match, killer, 'notify.gungame_promoted')
                payKillReward(match, killer)
            else
                ArenaNotifyKey(killer.src, 'notify.gungame_no_credit', 'warning', player.name)
            end
        else
            payKillAmmo(match, killer)
        end
    elseif killerSrc ~= nil then
        ArenaDebug('unverified kill claim on match %s: %s says %s killed them',
            tostring(match.id), tostring(id), tostring(killerSrc))
    end

    if playingLadder then
        if tierScore(player) > 0 then
            player.tiersLost = (Arena.ToInt(player.tiersLost) or 0) + 1
            refundTierCredit(player)
        end

        -- AND IT IS NEVER HANDED BACK. A refused swap means the weapon
        -- would not move, not that the death did not happen -- and refunding
        -- the tier for it made PARKING YOUR WEAPON A WAY OF NOT DYING.
        -- ox_inventory refuses the removal for a tier weapon sitting in a
        -- trunk, and refuses the add for a full inventory; both are things
        -- the player chooses. A climber who arranged either was immune to
        -- the only cost this mode has, while their kills went on counting.
        --
        -- The promotion was never refunded on the same failure, which is
        -- what made the pair asymmetric in the attacker's favour. Neither is
        -- now: the score is what a player EARNED, and what their pockets
        -- will hold is an inventory problem that settleTier retries on the
        -- next kill or death.
        settleTier(match, player, 'notify.gungame_demoted')
    end

    ArenaDispatch.ClearDownState(id)

    -- A GUN GAME SPENDS NO LIVES. Nobody is eliminated in one: the death
    -- above has already taken the tier, which is what a death costs in this
    -- mode, and the round ends on the clock or on the ladder rather than on
    -- a count of survivors. Leaving `lives` alone is what makes that true
    -- everywhere at once -- Arena.IsEliminated reads it, `stillIn` reads
    -- that, and the panel, the respawn picker, the spectator gate and every
    -- winner-selection path in this file read `stillIn`. A second rule
    -- saying "except in a ladder" in each of those places is five rules that
    -- can disagree.
    -- AND NEITHER DOES A SCORE LIMIT, for a reason that is arithmetic rather
    -- than taste. That round is meant to end when somebody reaches the limit,
    -- and a roster that can be eliminated runs out of players first on any
    -- limit worth setting: three lives and a limit of 25 means the round is
    -- decided by last-man-standing every single time and the number nobody
    -- reached was decorative. So it respawns for ever, exactly as a ladder
    -- does, and by the same mechanism -- leaving `lives` alone, which
    -- Arena.IsEliminated reads, which `stillIn` reads, which the panel, the
    -- respawn picker, the spectator gate and every winner-selection path in
    -- this file read.
    --
    -- Asked of Arena rather than spelled out here, so the panel's own answer
    -- and this one cannot drift apart.
    local remaining
    if playingLadder or not Arena.WinConditionSpendsLives(match.winCondition) then
        remaining = math.max(1, Arena.ToInt(player.lives) or 1)
    else
        remaining = (Arena.ToInt(player.lives) or 1) - 1
        player.lives = remaining
    end

    if remaining > 0 then
        scheduleRespawn(match, player)
    else
        player.placement = placementFor(match)

        local watching = Config.Match.spectateOnElimination == true
        local spectate = watching and ArenaLobby.AddSpectator(id, match.id) == true

        -- ELIMINATION IS A DEATH THE PLAYER DOES NOT COME BACK FROM, so it
        -- is the one that most needs saying out loud. A respawn revives them
        -- and so does the exit, but an eliminated player sits between those
        -- two for the rest of the round -- watching, flagged dead by the
        -- medical script, with whatever that script does to a corpse still
        -- being done to them.
        -- THE HOLD STAYS, and nothing anywhere on this path releases it.
        -- The point here is the medical script's list, not the player's
        -- freedom: the round is still running and they are out of it.
        -- Released, they would be visible, solid and MORTAL in a live arena
        -- -- spectate restores the first two and never touches
        -- invincibility. What keeps them held is client/match.lua's
        -- `eliminated` handler, which deliberately releases nothing;
        -- leaveArena is the only thing that ever does.
        ArenaDispatch.Revive(id)

        TriggerClientEvent('crimson_arena:client:eliminated', id, { matchId = match.id, spectate = spectate })
        ArenaNotifyKey(id, 'notify.eliminated', 'error')

        -- AND IF THEY ARE NOT WATCHING, THEY GO HOME. config.lua says what
        -- this setting means -- "Eliminated players watch the rest of the
        -- match instead of being sent straight back to the lobby" -- and
        -- switching it off did not send anybody anywhere. It only withheld
        -- the camera, and the hold above stayed: invisible, frozen,
        -- collisionless and looking at their own invisible body, with no
        -- panel, no camera and no way out, until the round happened to end.
        -- On a ten-minute round that is ten minutes of a black screen for
        -- dying first.
        --
        -- The hold is right to stay while they are WATCHING -- released,
        -- they would be visible and mortal in a live arena, which is what
        -- the comment above is about. Going home releases it properly:
        -- leaveArena stands them up, restores what they walked in with and
        -- puts them at the return point, which is what the setting says.
        --
        -- THE ROW STAYS EITHER WAY. They are still a contestant: the results
        -- board ranks off this row and the payout reads it, so this is an
        -- exit from the ARENA, not from the match. ArenaLobby.Leave is what
        -- would take them off the roster, and it is deliberately not called.
        --
        -- Refused registration counts as not watching, for the same reason:
        -- the camera it was going to open is exactly what will not be there.
        if not spectate then
            sendPlayerHome(player, { returnCoords = toPoint(Config.Lobby.returnCoords) })
        end
    end

    ArenaLobby.Broadcast()
    return true
end

function ArenaMatch.End(matchId, reasonKey, winners)
    local match = ArenaLobby.Get(matchId)
    if not match then return false end
    if match.state == 'ended' then return false end

    local players = ArenaLobby.PlayerArray(match)
    if #players == 0 then
        return ArenaMatch.Abort(matchId, reasonKey or 'match.ended_abandoned')
    end

    local teamMode = Arena.ModeUsesTeams(match.modeKey)
    if type(winners) ~= 'table' then
        winners = evaluate(match) or decideOnKills(match, teamMode)
    end

    match.state = 'ended'
    assignFinalPlacements(match, winners)
    match.winners = winners

    local endReason = Arena.IsKey(reasonKey) and reasonKey or 'match.ended'

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
        winners = winners,
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

    local payouts = ArenaBetting.Settle(match.id, context)
    match.payouts = payouts

    local pick = winningPick(match, winners, teamMode)

    local _, _, sideEarnings = ArenaBetting.SettleSpectatorBets(match.id, pick)

    local won, earned = {}, {}
    for _, id in ipairs(winners) do won[id] = true end

    local wonSide = pick
    if wonSide ~= nil then
        for _, src in ipairs(membersOfTeam(match, wonSide)) do
            if not won[src] then
                wonSide = nil
                break
            end
        end
    end

    for src, amount in pairs(sideEarnings or {}) do
        earned[src] = (earned[src] or 0) + (Arena.ToInt(amount) or 0)
    end

    for _, payout in ipairs(payouts) do
        -- REFUNDS ARE NOT EARNINGS. Settle hands its computed list back even
        -- when every line of it is a refund -- deliberately, as the report of
        -- what was decided -- and this summed the lot into `earnings`, which
        -- goes out in the results as money the player made. So a match that
        -- did not qualify to pay out (too few fought, no winner) told
        -- everybody they had WON their own entry fee back, while the pot was
        -- being handed straight back to them.
        local refund = ArenaBetting.IsRefundReason(payout.reason)
        if payout.id ~= nil and not refund then
            earned[payout.id] = (earned[payout.id] or 0) + (Arena.ToInt(payout.amount) or 0)
        end
    end

    -- THE SAME NUMBER IN BOTH PLACES, by construction rather than by two
    -- readers agreeing. ArenaStats.RecordMatch prefers `player.earnings` when
    -- it is set and falls back to reading match.payouts when it is not, so
    -- writing it here is what stops the all-time leaderboard and the board on
    -- the player's screen ever being able to disagree about one match.
    for _, player in ipairs(players) do
        local row = match.players[player.src]
        if row then row.earnings = earned[player.src] or 0 end
    end

    ArenaStats.RecordMatch(match)
    ArenaBetting.Clear(match.id)

    local board = scoreboardOf(players, #ladderOf(match))

    local placeOf = {}
    for _, player in ipairs(players) do placeOf[player.src] = player.placement end
    table.sort(board, function(a, b)
        local first = placeOf[a.id] or math.huge
        local second = placeOf[b.id] or math.huge
        if first ~= second then return first < second end
        return a.id < b.id
    end)
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
            reason = locale(endReason),
            won = won[player.src] == true,
            winningTeam = teamMode and wonSide or nil,
            placement = player.placement,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            deaths = math.max(0, Arena.ToInt(player.deaths) or 0),
            earnings = earned[player.src] or 0,
            scoreboard = board,
        }

        sendPlayerHome(player, { returnCoords = returnCoords, results = results })
        TriggerClientEvent('crimson_arena:client:results', player.src, results)
    end

    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            local results = {
                reason = locale(endReason),
                won = false,
                winningTeam = teamMode and wonSide or nil,
                earnings = 0,
                scoreboard = board,
            }
            sendExitArena(src, { returnCoords = returnCoords, results = results })
            TriggerClientEvent('crimson_arena:client:results', src, results)
        end
    end

    ArenaAmmo.Clear(match.id)

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
        CreateThread(function()
            Wait(sweepMs)

            for _, src in ipairs(roster) do
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
        ArenaWebhook(('Match %s finished'):format(tostring(match.id)), locale(endReason), {
            { name = 'Arena', value = tostring(match.arenaKey) },
            { name = 'Mode', value = tostring(match.modeKey) },
            { name = 'Winners', value = #names > 0 and table.concat(names, ', ') or 'none (draw)' },
            { name = 'Scoreboard', value = table.concat(lines, '\n') },
        })
    end

    ArenaDispatch.ReleaseBucket(match.id)

    ArenaLog('match %s ended: %s', tostring(match.id), endReason)
    ArenaLobby.Destroy(match.id, endReason)
    return true
end

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
        sendPlayerHome(player, { returnCoords = returnCoords })
    end
    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            sendExitArena(src, { returnCoords = returnCoords })
        end
    end

    ArenaBetting.RefundAll(match.id, reason)
    ArenaBetting.SettleSpectatorBets(match.id, nil)
    ArenaBetting.Clear(match.id)
    ArenaAmmo.Clear(match.id)

    ArenaDispatch.ReleaseBucket(match.id)

    ArenaLog('match %s aborted: %s', tostring(match.id), reason)
    ArenaLobby.Destroy(match.id, reason)
    return true
end

function ArenaMatch.RemovePlayer(src, reasonKey, dropped)
    local id = Arena.ToInt(src)
    if not id then return false end

    local match = ArenaLobby.GetByPlayer(id)
    if not match then
        ArenaLobby.RemoveSpectator(id)
        return false
    end

    local matchId = match.id
    local inProgress = match.state == 'live' or match.state == 'countdown'
    local player = match.players[id]

    local may, refusal = ArenaLobby.MayLeave(id, dropped)
    if not may then return true, refusal end

    if player and inProgress then
        player.alive = false
        if not player.placement then player.placement = placementFor(match) end
        sendPlayerHome(player, {
            returnCoords = toPoint(Config.Lobby.returnCoords),
        })
    end

    local left, refused = ArenaLobby.Leave(id, reasonKey or 'match.left', dropped)
    if not left and refused then return true, refused end

    local current = ArenaLobby.Get(matchId)
    if current and inProgress and ArenaLobby.PlayerCount(current) == 0 then
        ArenaMatch.Abort(matchId, 'match.ended_abandoned')
    end

    return true
end

--- Shuts every lobby that is still waiting to start, refunding as it goes.
---
--- ONLY LOBBIES, AND ONLY LOBBIES. A round already being fought is fought to
--- the end -- the doors being shut is about who may come in, not about who is
--- already inside. Widening this to `~= 'ended'` is the mutation that would
--- abort live rounds at the stroke of the hour.
---
--- DESTROY, NEVER CANCEL. Cancel is the one way of closing a lobby an
--- operator can make cost something, and an operator who chose to punish a
--- host for calling their own match off has not asked to punish a lobby the
--- SERVER closed. Destroy refunds every stake unconditionally.
---
--- CALLED FROM TWO PLACES, WHICH IS WHY IT IS A FUNCTION. The sweep runs it
--- when a schedule window closes; server/main.lua runs it the instant an admin
--- closes the arena from the tablet. Leaving the second to the first was the
--- shape of a real defect: the sweep only acts on the EDGE it notices for
--- itself, so an admin pressing Close watched a lobby go on queueing for a
--- round that could never start, with its host still out of pocket for the
--- entry fee.
--- @param reasonKey string
--- @return integer closed
function ArenaMatch.CloseWaitingLobbies(reasonKey)
    local function nobodyPlaced(match)
        if type(ArenaDispatch) ~= 'table'
            or type(ArenaDispatch.IsPlayerInArena) ~= 'function'
        then
            return false
        end
        for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
            if ArenaDispatch.IsPlayerInArena(player.src) then return false end
        end
        return true
    end

    local waiting = {}
    for _, match in ipairs(ArenaLobby.All()) do
        if match.state == 'lobby'
            or (match.state == 'countdown' and nobodyPlaced(match))
        then
            waiting[#waiting + 1] = match.id
        end
    end

    for _, id in ipairs(waiting) do
        ArenaLobby.Destroy(id, reasonKey)
    end
    return #waiting
end

function ArenaMatch.IsLive(matchId)
    local match = ArenaLobby.Get(matchId)
    return match ~= nil and match.state == 'live'
end

local function anyoneIsPlaced(match)
    for src in pairs(match.players or {}) do
        if ArenaDispatch.IsPlayerInArena(src) then return true end
    end
    return false
end

local function syncMatchBuckets()
    local wanted = {}

    local fighting = {}

    for _, match in ipairs(ArenaLobby.All()) do
        -- 'countdown' AS WELL AS 'live', BUT THE STATE IS NOT THE QUESTION.
        --
        -- This used to say "Start() has already put the fighters in the arena
        -- by then", and the comment twenty-five lines below flatly
        -- contradicts it -- correctly. ArenaMatch.Begin sets 'countdown' for
        -- the LOBBY countdown before anybody has been teleported anywhere,
        -- and ArenaMatch.Start reuses the same name for the frozen one after
        -- placement. Two different events, one word.
        --
        -- The flag half already knew: it withholds ArenaDispatch.Set from
        -- fighters precisely because this loop reaches people standing in the
        -- middle of town. EnterBucket sat outside every guard and moved them
        -- anyway -- so for the whole lobby countdown, every player in a
        -- starting lobby was pushed into a private, population-disabled
        -- instance while their body was still at the ped, in traffic, in a
        -- vehicle the move does not take with them, or inside somebody else's
        -- job instance. They stopped replicating to bystanders and bystanders
        -- to them, and they were simultaneously NOT flagged as being in an
        -- arena, so nothing else on the server could say why.
        --
        -- It bought nothing. The flag is deliberately false for that exact
        -- window, so no alert was being suppressed in exchange.
        --
        -- PLACEMENT IS THE QUESTION, and the flag is how placement is known:
        -- sendEnterArena raises it BEFORE it buckets, so a genuinely placed
        -- fighter is already flagged by the time the next pass sees them.
        -- server/lobby.lua's playersArePlaced leans on the same predicate for
        -- the same reason -- the two countdowns cannot be told apart by name.
        if (match.state == 'countdown' or match.state == 'live')
            and anyoneIsPlaced(match)
        then
            for src in pairs(match.players) do
                if ArenaDispatch.IsPlayerInArena(src) then wanted[src] = match.id end
                fighting[src] = true
            end
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
            instanced[src] = matchId
        end

        ArenaDispatch.EnterBucket(src, matchId)
    end

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

local hoursWereOpen = nil

CreateThread(function()
    while true do
        Wait(SWEEP_INTERVAL_MS)

        local hoursOpen = ArenaHoursOpen()
        if hoursWereOpen ~= nil and hoursWereOpen ~= hoursOpen then
            if not hoursOpen then
                ArenaMatch.CloseWaitingLobbies('notify.hours_lobby_closed')
            end

            ArenaLobby.Broadcast()
        end
        hoursWereOpen = hoursOpen

        syncMatchBuckets()

        for _, match in ipairs(ArenaLobby.All()) do
            if match.state == 'live' then
                runServerChecks(match)

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
