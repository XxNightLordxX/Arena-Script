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
local function boundaryPayload(arena, factor)
    -- Through Arena.BoundaryOf: one reading of `enabled` shared with the
    -- keep-out fence, the explosion guard and the validator, which used to
    -- disagree with this line about a block that omits the key.
    local boundary = Arena.BoundaryOf(arena)
    if not boundary then return nil end

    -- NOT SENT AT ALL RATHER THAN SENT BROKEN. toPoint answers nil for a
    -- centre missing an x, y or z, and this used to put that nil straight
    -- onto the wire -- where the client indexed it and threw, taking the
    -- blip thread down with the boundary. An arena the server cannot
    -- describe is an arena with no boundary, said once, here.
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
        -- GROWN WITH THE REST OF THE ARENA. The floor and the spawn ring
        -- both scale with the roster, and a boundary that did not would put
        -- solid ground -- and spawns -- outside the sphere that bleeds you
        -- for leaving it.
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

--- The ladder this match is climbing: one weapon per tier, in climbing
--- order, EMPTY when this is ordinary play.
---
--- DRAWN ON FIRST ASK AND KEPT ON THE MATCH RECORD, rather than in Start.
--- Every reader below goes through here -- the scoreboard, the loadout, the
--- promotion -- so drawing here is what makes the ladder the same one all
--- round for all of them, including on the paths that run before Start's
--- player loop has touched anybody. `ArenaMatch.Start` clears the record so
--- the next round draws again.
---
--- FEWER THAN TWO TIERS IS NOT A LADDER and is answered as ordinary play: a
--- one-tier ladder would be finished by the first kill of the round, which
--- is a worse outcome than the mode quietly behaving like a free-for-all.
--- Arena.ValidateConfig complains about that at start-up, where an operator
--- will see it.
--- @param match table
--- @return table[] ladder -- catalogue entries, never bare keys
local function ladderOf(match)
    if type(match) ~= 'table' then return {} end
    if type(match.ladder) == 'table' then return match.ladder end

    local tiers = Arena.LadderTiersFor(match.modeKey)
    local drawn = {}
    for _, pool in ipairs(tiers) do
        -- ONE FROM EACH POOL. math.random over the pool length, and a pool
        -- of one draws that one.
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

--- Which tier a ladder score has earned, and whether it finished the ladder.
---
--- Everybody starts on tier 1, so the Nth point puts a player on tier N+1
--- and the point scored ON the last tier is the one that finishes it.
--- @param score any
--- @param tiers any -- how tall the drawn ladder is
--- @return integer tier -- 1-based, and never past the top of the ladder
--- @return boolean finished
local function tierForScore(score, tiers)
    local total = math.max(0, Arena.ToInt(tiers) or 0)
    local scored = math.max(0, Arena.ToInt(score) or 0)
    if total <= 0 then return 1, false end
    if scored >= total then return total, true end
    return scored + 1, false
end

--- The supplies everybody in this match walks in with.
---
--- THE MODE'S KIT, OR THE PLAYER'S OWN. `Arena.StartingKitFor` answers nil
--- for a mode that names no kit, which is not the same as a mode that names
--- an empty one -- so this cannot be written as `kit or theirs`, and the
--- distinction is the whole reason it is a function rather than one line at
--- each call site. A ladder mode with `startingKit` set issues that and only
--- that; without it, players carry what they picked, exactly as they do in
--- every other mode.
---
--- WHY A LADDER FIXES IT AT ALL. The mode's loadout screen is shut: the
--- ladder decides the weapon, so there is nothing to choose. Leaving the
--- SUPPLIES pickable would make it a mode where the guns are equal and the
--- plates are not, and everybody meets on tier 1 holding a blade.
--- @param match table
--- @param player table
--- @return table[]|nil supplies
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

--- What a player holds on one tier: that tier's weapon at its own configured
--- default ammo, the mode's kit, and nothing they chose for themselves.
--- @param weapon table -- a catalogue entry
--- @param supplies table[]|nil -- kitFor's answer; nil falls back to the
---        ordinary resolver, which is what a mode with no kit wants
--- @return table loadout -- the shape Arena.ResolveLoadout returns
local function tierLoadout(weapon, supplies)
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
    -- Nothing requested for the ammo: with no ask to resolve, ResolveAmmo
    -- hands back this weapon's own default clamped to its own max, which is
    -- exactly what a tier is worth.
    local tier = Arena.ResolveWeaponEntry(weapon, Arena.ResolveAmmoType(weapon, nil), nil)

    -- Armour and health still come from the ordinary path so the ladder
    -- never grows a second copy of those rules. Arena.StartingVitals is
    -- behind them and is a rule of the arena, not a choice.
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

--- The loadout a player should be holding for this match right now: their
--- own choice re-resolved in every mode, and the tier they are standing on
--- in a gun game.
--- @param match table
--- @param player table
--- @return table loadout
--- @return string[] rejected -- keys dropped from a player's own choice
local function loadoutFor(match, player)
    local ladder = ladderOf(match)
    if #ladder == 0 then return Arena.ResolveLoadout(player.loadout) end

    -- Clamped rather than trusted: a ladder redrawn shorter since this row
    -- was last touched leaves somebody standing on a tier that is not there.
    local tier = Arena.ClampInt(player.tier, 1, #ladder) or 1
    player.tier = tier

    -- TWO RETURNS, like the branch above. Callers read `loadout, rejected`,
    -- and the ladder rejects nothing -- it never consults the player's own
    -- choice in the first place. Returning one value left `rejected` nil at
    -- the call site and took the round down on the first placement.
    return tierLoadout(ladder[tier], kitFor(match, player)), {}
end

--- Whether this kill is allowed to move the killer up the ladder, and
--- counts it against the victim if it is.
---
--- WHY THERE IS A CAP AT ALL. The server cannot see a kill happen: it is
--- told who died and who they say killed them, and `resolveKiller` can only
--- check that the named killer is a real opponent in the same match. In
--- every other mode a friend feeding you kills buys a scoreboard position.
--- Here, with no lives to spend and a finished ladder ending the round
--- outright over every other condition, one accomplice reporting their own
--- death on a loop buys the entire pot in well under a minute -- measured,
--- not supposed.
---
--- SO THE CAP IS ON THE PAIR, not on the rate. An honest round has you
--- killing several different people; a farm has one name over and over, and
--- that is the shape this refuses. Kills past the cap are still kills --
--- `kills`, the scoreboard, the leaderboard and the payout are untouched --
--- they simply stop buying tiers, and stop paying the kill reward with them.
---
--- `maxTiersPerVictim = 0` removes the cap, which is an operator's call to
--- make on a closed server.
--- @param match table
--- @param killer table
--- @param victim table
--- @return boolean credited
local function creditsTier(match, killer, victim)
    local mode = Arena.GetModeByKey(match.modeKey) or {}

    -- THE TYPO FAILS CLOSED, NOT OPEN. `0` means no cap, and every
    -- unparseable value used to resolve to it -- nil, -3, 'two', true, a
    -- table -- so the one setting in the block that exists to stop an
    -- accomplice buying the whole pot switched ITSELF off on a typo, and
    -- said nothing. Only a number reaching this now removes the cap;
    -- anything else falls back to the shipped default, and
    -- Arena.ValidateConfig says so at start-up.
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
        -- THE ROSTER THE ROUND STARTED WITH, NOT THE ONE LEFT STANDING.
        --
        -- This counted `match.players` live, on every kill -- and
        -- ArenaLobby.Leave deletes a departed fighter's row, so the divisor
        -- shrank as people walked out and the cap rose with it. The attacker
        -- chooses when that happens.
        --
        -- MEASURED, END TO END: a six-man gun game with a 5,000 entry fee.
        -- Farm three accomplices flat out and the seven-tier ladder is
        -- exactly one credit short -- the cap works. Then two accomplices
        -- fire leaveMatch, the roster drops to four, the floor rises from 2
        -- to 3, and ONE more kill on a victim who was already farmed out now
        -- credits: ladder topped, round over, the whole 30,000 pot to the
        -- attacker. The spent count persists, so the raise RETROACTIVELY
        -- reopens a victim the cap had closed.
        --
        -- Latched at the start of the round instead. What the floor exists
        -- for is a property of the lobby that was assembled -- can a climber
        -- reach the top against this many people -- not of who happens to be
        -- left at the moment of a kill.
        local roster = Arena.ToInt(match.ladderSpread) or Arena.Count(match.players)
        local opponents = math.max(0, roster - 1)
        local height = #ladderOf(match)

        -- TWO VICTIMS, ALWAYS. The floor is divided by at least two however
        -- few opponents there really are, so topping the ladder can never be
        -- done off one person.
        --
        -- WITHOUT THAT DIVISOR THE RAISE WAS THE EXPLOIT. In a two-player
        -- match it worked out at the whole ladder, so two accounts -- one
        -- reporting its own death on a loop -- topped it and took the pot,
        -- which is the exact run the cap exists to stop, handed back by the
        -- rule that was meant to make small lobbies playable. And the
        -- attacker chooses the roster the floor is computed from.
        --
        -- The cost is honest and small: in a 1v1 the ladder cannot be
        -- topped. That round still has a winner -- decideOnLadder crowns the
        -- highest tier when the clock stops -- and a 1v1 gun game was never
        -- the shape this mode is for.
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

--- Whether a percentage chance came up. No chance named at all means every
--- time, which is what makes `chance` an optional field rather than one
--- every reward entry has to carry.
--- @param chance any -- a percentage, or nil
--- @return boolean
local function rolled(chance)
    -- ABSENT MEANS EVERY TIME. That is what makes `chance` an optional field
    -- rather than one every reward entry has to carry.
    if chance == nil then return true end

    -- PRESENT AND UNREADABLE MEANS NEVER, which is the opposite of absent
    -- and has to be: `chance = 'abc'` used to fall into the branch above and
    -- pay on every single kill -- indistinguishable, in the pockets, from an
    -- operator who had asked for exactly that. A number they cannot have
    -- meant should cost them nothing until they fix it, and
    -- Arena.ValidateConfig names it at start-up.
    local percent = Arena.ToInt(chance)
    if percent == nil then return false end

    if percent <= 0 then return false end
    if percent >= 100 then return true end
    return math.random(100) <= percent
end

--- Pays the mode's `killReward` to a killer whose kill counted for the
--- ladder: the bandages that keep a run going, and the plate that does not
--- come every time.
---
--- BY SUPPLY KEY, RESOLVED THROUGH THE SUPPLIES CATALOGUE, so the item name
--- lives in exactly one place -- an operator who renamed the bandage item
--- once does not have to remember they also named it in the mode block. A
--- key naming a supply this server has switched off is skipped, for the same
--- reason the loadout picker does not offer it.
---
--- PAID ONLY ON A CREDITED KILL. Hanging it off the same gate as the tier is
--- what stops an accomplice being farmed for bandages after
--- `maxTiersPerVictim` has stopped paying tiers.
--- @param match table
--- @param killer table
local function payKillReward(match, killer)
    local mode = Arena.GetModeByKey(match.modeKey) or {}
    local rewards = mode.killReward
    if type(rewards) ~= 'table' then return end

    -- ONE BUDGET FOR THE WHOLE PAYMENT rather than one per line, and it is
    -- what makes the two ceilings below mean anything when a reward list
    -- names the same supply twice. Clamping each entry on its own read the
    -- `max` as a per-line allowance: two bandage lines of 30 against a
    -- ceiling of 30 paid 60, five paid 150, and an operator who wanted a
    -- better-than-even chance at one plate by writing four 25% lines got
    -- four plates on the roll where they all came up.
    --
    -- SPENT ON WHAT WAS ACTUALLY HANDED OVER. A line whose chance did not
    -- come up costs nothing, and neither does one ox_inventory refused for
    -- want of room -- the player is not holding it, so it cannot be what
    -- stops the next line paying.
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

            -- And under `supplies.totalItems` as well, which is the ceiling
            -- on everything together -- the one the picker enforces and this
            -- path used to walk straight past.
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

--- Moves one player onto the tier their ladder score has earned, handing
--- over the weapon and telling them. Does nothing when they are already
--- standing there.
---
--- DECIDES NOTHING about the round. The sweep reads the score a tick later
--- and works out for itself whether anybody has topped the ladder, the same
--- as every other way a round ends.
--- @param match table
--- @param player table
--- @param reasonKey string -- what to tell them: promoted, or knocked back
--- @return boolean settled -- false ONLY when the swap was refused and the
---         player is therefore standing somewhere their score does not say
local function settleTier(match, player, reasonKey)
    local ladder = ladderOf(match)
    if #ladder == 0 then return true end

    local tier = tierForScore(tierScore(player), #ladder)

    -- ALREADY STANDING THERE. The tier is read off the score, so a kill made
    -- FROM the top tier -- and any second pass over a score already granted
    -- -- would otherwise re-issue a weapon the player is holding and refill
    -- its magazine for free.
    --
    -- THE FLAG IS STILL SET, and this is the branch that sets it in the case
    -- that matters: reaching the top tier does not finish the ladder, the
    -- kill made FROM it does, and that kill moves nobody.
    if tier == player.tier then return true end

    local previous = player.tier and ladder[player.tier] or nil
    local moving = tierLoadout(ladder[tier], kitFor(match, player))
    local weapon = moving.weapons[1]

    -- WHATEVER THEY WERE HOLDING COMES OFF, INCLUDING THE SAME GUN AGAIN.
    --
    -- This used to skip the removal when the two tiers resolved to the same
    -- GTA weapon, on the reasoning that taking a gun off to hand the same
    -- one back is churn. It is not churn, it is the only thing standing
    -- between a shared weapon and a free copy: nothing was removed and one
    -- was still added, so every crossing of a boundary where two tiers name
    -- the same weapon handed out another. Deaths are free in this mode, so a
    -- player could sit on that boundary and pump it.
    --
    -- Two tiers CAN share a weapon without a duplicate key in config -- two
    -- catalogue entries pointing at one GTA name, or two pools that overlap
    -- and happen to draw the same one. Arena.ValidateConfig complains about
    -- the pools it can see; this is what makes the ones it cannot harmless.
    --
    -- And re-issuing is the right answer anyway: a tier change re-arms you,
    -- so crossing onto the same weapon should still come with a full
    -- magazine rather than the empty one you climbed with.
    local dropped = previous and previous.weapon or nil

    -- THE ITEM IS THE WEAPON on an ox_inventory server, so the swap has to
    -- happen here rather than in the message below: a ped handed a gun it
    -- has no item for is disarmed again within moments.
    --
    -- AND A REFUSED SWAP DOES NOT MOVE THE TIER. `refused` means the weapon
    -- being taken back would not come off -- a player who parked it in a
    -- trunk between the kill and the promotion -- and advancing anyway would
    -- arm them with both tiers and lose the lower one off the arena's books.
    -- The score is untouched, so the next kill or death tries again.
    --
    -- `no-inventory` is not that: it is a server without ox_inventory
    -- started, where there are no items to move and the record on this side
    -- is the whole truth. The tier moves.
    local swapped, why = ArenaAmmo.SwapWeapon(player.src, match.id, dropped, weapon)
    if not swapped and why == 'refused' then
        ArenaDebug('gun game: %s stays on tier %s -- ox_inventory would not take back %s.',
            tostring(player.src), tostring(player.tier), tostring(dropped))
        return false
    end

    player.tier = tier
    player.loadout = moving

    -- NO CLIENT EVENT. The old gun game sent one, and the client file never
    -- registered a handler for it -- so for its whole life the server's idea
    -- of what a climber was holding walked up the ladder without them. It is
    -- not restored here because the reason it existed is gone: ox_inventory
    -- owns weapons now, SwapWeapon has already moved the item above, and a
    -- second channel telling the client to hand out a gun would only fight
    -- it. What a player is standing on is on the scoreboard.

    -- THE KEYS ARE LITERAL ON BOTH BRANCHES, and that is not a style choice.
    -- tests/locale_spec.lua checks a notify string's placeholder count
    -- against the arguments at its call site, and it can only do that when
    -- the key is a literal it can read -- passing the caller's `reasonKey`
    -- variable straight through made both of these invisible to it. A
    -- placeholder count that drifts on the promoted string raises inside an
    -- event handler; on the demoted one it silently drops the weapon name.
    if reasonKey == 'notify.gungame_demoted' then
        ArenaNotifyKey(player.src, 'notify.gungame_demoted', 'error', tier, #ladder, weapon.label)
    else
        ArenaNotifyKey(player.src, 'notify.gungame_promoted', 'success', tier, #ladder, weapon.label)
    end

    -- THE TOP TIER IS EVERYBODY'S BUSINESS. A race nobody can see is a
    -- surprise ending; told, the whole room knows who to hunt for the last
    -- thirty seconds, which is the best part of a gun game.
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

--- STILL IN THE ROUND, not still breathing.
---
--- With Config.Match.lives above 1 -- and the shipped default is 3 -- a
--- player lying on the floor waiting out respawnDelaySeconds has not lost
--- anything yet. They are coming back, and every count that decides or
--- reports how much round is left has to say so.
---
--- THE REASON THIS IS ONE FUNCTION AND NOT TWO COPIES: the round-end rule
--- and the scoreboard header used to answer it differently. `evaluate` had
--- this predicate; `pushHud` counted `player.alive` alone. So on the shipped
--- config a 1v1 read "Alive 1 / 2" for five seconds after every single death
--- while the round carried on, and a player watching the number they are
--- given to judge the fight by was told it was already over. Two readers of
--- the same question is what let them drift; one function is what stops it.
---
--- And it is the SAME rule as Arena.IsEliminated, which the panel, the
--- respawn picker and the spectator gate all read -- so this is that
--- function with the sign flipped, not a third spelling of it. It stays
--- named because "still in" is what the readers below are asking.
---
--- It has to sit ABOVE decideOnKills. Lua closes a local over the scope it
--- is written in, so a use before this line would compile as a global read
--- and be nil at run time.
--- @param player table
--- @return boolean
local function stillIn(player)
    return not Arena.IsEliminated(player)
end

--- @param match table
--- @return table<string, integer> kills per team
local function teamKills(match)
    local scores = {}

    -- WHAT THE PEOPLE WHO LEFT SCORED FOR THIS SIDE, first. ArenaLobby.Leave
    -- deletes a departed fighter's row -- correctly, so nobody can be
    -- crowned after walking out -- and that used to take their kills out of
    -- their TEAM's total with them. Six kills for your side and a rage-quit
    -- handed the round to the other one.
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

    -- Join order, so the winners list -- and therefore the payout order --
    -- never depends on pairs() iteration.
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

    -- Same candidates as decideOnKills, for the same reason and so the two
    -- cannot disagree: a limit reached by a player who is out would end the
    -- round on their score and then hand it to somebody else's.
    for _, player in pairs(match.players) do
        if stillIn(player) and (Arena.ToInt(player.kills) or 0) >= limit then return true end
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

    -- Counting them as eliminated would hand the match to whoever shot them
    -- before they got back up; stillIn is what stops that.
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

    -- THE LADDER OVERRIDES Config.Match.winCondition, and it is the one mode
    -- that overrides anything: gun game IS its own win condition. Read
    -- before the clock too -- a ladder topped on the last second of the
    -- round was still topped.
    local ladder = ladderOf(match)
    local playingLadder = #ladder > 0

    -- STILL IN THE ROUND, like every other winner-selection path in this
    -- function. Nobody is eliminated in a gun game, so on the shipped mode
    -- this filters nobody out -- but the ladder branch was written for a
    -- codebase where NOTHING filtered eliminated players, and dropped into
    -- one where everything else does. An operator running a ladder alongside
    -- lives would otherwise have it crown a fighter the same results board
    -- ranks third of four.
    --
    -- AND ONE WINNER, OR NONE. Two players topping the ladder inside the
    -- same sweep is a genuine tie, and a ladder is the only non-team mode
    -- that can produce one: `winningPick` collapses a free-for-all result to
    -- `winners[1]`, so the second finisher was told they had won, recorded
    -- as a winner by ArenaStats, and paid nothing -- while their own stake
    -- was judged a loser against the first. A tie is a DRAW here for exactly
    -- the reason it is one in decideOnKills: paying one of two identical
    -- runs out of the other's stake is a coin toss with somebody else's
    -- money, and the server cannot honestly order two kills reported in the
    -- same second.
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
    if not playingLadder and Config.Match.winCondition == 'score_limit' and reachedScoreLimit(match, teamMode) then
        local winners = decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_score_limit' or 'match.ended_draw'
    end

    -- Nobody left to fight ends the round whatever the condition is: with
    -- one side still standing there is nothing left to decide it with, so
    -- the survivors take it under every win condition, not just
    -- 'last_standing'.
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

    -- ONE PLAYER LEFT IN THE RECORD AT ALL is not a win condition, it is the
    -- absence of a match, and it applies to every mode including a ladder --
    -- a gun game whose lobby walked out is not a race the last player is
    -- still running. Whether a one-man round pays is Config.Betting's
    -- minPlayersToPayOut to answer, not this file's.
    --
    -- `lastStanding` IS CHECKED, and this is why. The line used to sit
    -- inside the block above, after the `standing == 0` draw had already
    -- returned -- so the one row left was guaranteed to be a standing one.
    -- Lifting it out past a guard a ladder skips left it reachable with the
    -- last row eliminated and `lastStanding` nil, which indexes nil and
    -- kills the sweep thread. It is unreachable today only because a ladder
    -- spends no lives, and the comment twelve lines above refuses to lean on
    -- exactly that kind of "unreachable".
    if not teamMode and total == 1 then
        if lastStanding then return { lastStanding.src }, 'match.ended_abandoned' end
        return {}, 'match.ended_abandoned'
    end

    -- THE CLOCK, which in a gun game is the ordinary ending rather than the
    -- backstop it is everywhere else -- and the ladder is what it reads.
    -- `roundTimeSeconds = 0` leaves endsAt unset; ordinary modes then run
    -- until one side is left, and a ladder runs until somebody tops it.
    if match.endsAt and os.time() >= match.endsAt then
        local winners = playingLadder and decideOnLadder(match) or decideOnKills(match, teamMode)
        return winners, #winners > 0 and 'match.ended_time_up' or 'match.ended_draw'
    end

    return nil, nil
end

--- Ranks everybody who is still standing when the round stops, so the
--- results board has a full finishing order to read rather than a hole
--- where the survivors are.
--- @param match table
--- @param winners table|nil -- the srcs the round was decided for, so the
---        order agrees with the result instead of being worked out again
local function assignFinalPlacements(match, winners)
    local unplaced = {}
    for _, player in pairs(match.players) do
        if not player.placement then unplaced[#unplaced + 1] = player end
    end

    -- WHO ACTUALLY WON, FIRST, ahead of every score term below.
    --
    -- The round is decided by one function and ranked here by another, and
    -- in a team mode the two ask different questions: decideOnKills crowns
    -- the side with the most kills between them, while this ranked every
    -- fighter individually -- so a winner on a side that out-fragged the
    -- other could easily sit below the losing side's top fragger. Measured:
    -- a 2v2 that crimson took 4-3 handed a crimson winner "You Won" and
    -- "Placed #3" on the same card, under a board whose top row was the ash
    -- player who beat them.
    --
    -- It cannot be avoided by ranking harder: a team win has two or more
    -- winners and only one of them can be #1, so ANY individual ranking
    -- contradicts the card for everybody else on the winning side. Sorting
    -- the winning side to the top is what makes the placement mean "you were
    -- on the side that won, and here is where you came within it".
    local won = {}
    for _, src in ipairs(winners or {}) do won[src] = true end

    -- RANKED ON THE LADDER WHERE THERE IS ONE, and that is the third reader
    -- of this question to be pointed at the same two functions. The board
    -- sorts on the earned tier and decideOnLadder crowns it; this ranked on
    -- raw kills, so a gun game handed its WINNER a losing placement -- the
    -- results card read "You Won" and "Placed #2" at the same time, because
    -- a player who traded three kills for three deaths outranked one who
    -- took two for nothing and was six tiers below them.
    local ladder = #ladderOf(match)

    table.sort(unplaced, function(a, b)
        local aWon, bWon = won[a.src] == true, won[b.src] == true
        if aWon ~= bWon then return aWon end
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

    for index, player in ipairs(unplaced) do player.placement = index end
end

--- The live scoreboard, sorted the way the panel renders it.
--- @param players table[] -- in join order
--- @param tiers any -- how tall this match's ladder is, and 0 in every mode
---        that does not climb one. It decides whether the rows carry a
---        `tier` column at all, which is how the panel knows not to draw
---        one -- so it is the parameter the gun game's whole display hangs
---        off, and it went undocumented when it was added.
--- @return table[]
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
            -- Two different facts, and the board needs both. `alive` is
            -- literally breathing and is what greys a row out -- a corpse
            -- on the floor should look like one. `remaining` is stillIn:
            -- whether they can still win, which is what the header counts.
            alive = player.alive == true,
            remaining = stillIn(player),
        }
    end

    table.sort(rows, function(a, b)
        -- THE TIER SORTS FIRST WHERE THERE IS ONE, because in a gun game it
        -- IS the standing. Sorting a ladder on raw kills puts a player who
        -- traded twelve deaths for twelve kills above one who took six for
        -- nothing, and the second of those is six tiers higher and winning
        -- -- so the board would have ranked the race backwards for the whole
        -- round and then decideOnLadder would have crowned somebody else.
        if a.tier ~= b.tier then return (a.tier or 0) > (b.tier or 0) end
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

--- Sends one member of the roster home, unless they have already gone.
---
--- An eliminated fighter can now leave the arena before the round is over
--- (see OnDeath), and they keep their row while they do -- the results board
--- ranks off it and the payout reads it. So every roster walk that ends a
--- round reaches somebody who is already standing in the lobby, and telling
--- them to leave a second time teleports them back to the arena's return
--- point from wherever they had walked to in the minutes since.
---
--- Nothing else about a second exit is harmful -- the ammunition is already
--- reclaimed, the flag already down, and the client's restore nils what it
--- carried on the first pass -- which is exactly why the teleport was the
--- only symptom and would have been read as a stray teleport rather than a
--- double exit.
---
--- One helper rather than a check at each of the three round-ending walks,
--- for the reason sendExitArena gives above itself.
--- @param player table -- a live roster row
--- @param payload table
--- @return boolean sent
local function sendPlayerHome(player, payload)
    if player.leftArena then return false end
    player.leftArena = true
    sendExitArena(player.src, payload)
    return true
end

--- One event to every fighter and every spectator of a match.
--- @param match table
--- @param event string
--- @param payload table
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
    local scoreboard = scoreboardOf(players, #ladderOf(match))

    -- The header count, and it is `remaining` rather than `alive` in the
    -- payload as well as in the sum: a field named for one fact and holding
    -- another is how the two drifted apart in the first place.
    local remaining = 0
    for _, row in ipairs(scoreboard) do
        if row.remaining then remaining = remaining + 1 end
    end

    -- Shared by reference across every recipient; only the personal kill and
    -- death counts differ, and nothing on the client writes back.
    local common = {
        remaining = remaining,
        total = #players,
        timeLeft = match.endsAt and math.max(0, match.endsAt - os.time()) or nil,
        -- WHAT A WINNER IS ACTUALLY PLAYING FOR, the same figure the lobby
        -- card shows. This was GetPot -- the entry pot ALONE -- while
        -- server/lobby.lua:750 uses GetPrizePool and says why: with
        -- betPayout.includeEntryPot on, the shipped default, the side-bets
        -- settle in the same pool. The card was fixed for that reason and
        -- this screen was missed, so a fighter read "Pot $2,000" for a whole
        -- round while the lobby card read "Pot $9,500" and the winner was
        -- paid the larger one.
        --
        -- Worse on the shipped defaults, where entryFee.default is 0:
        -- GetPot is then 0 for the entire round, and the panel hides the pot
        -- line on `amount > 0` -- so a fighter playing for a pool built
        -- entirely out of bets was shown no prize at all.
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
            -- `teamCounts` used to ride here too and nothing ever read it.
            -- The panel's teamCountOf() takes the LOBBY SNAPSHOT's match
            -- (server/lobby.lua:761), which is a different table on a
            -- different event; grep for hud.teamCounts finds nothing.
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
    -- whether that player keeps the WEAPON is
    -- Config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem to decide -- with
    -- it off the gun is taken back too, rather than the player being kept
    -- out of the round.
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
        -- NO EXTRA SCATTER ON A PLANNED SPAWN. The plan has already spread
        -- this roster across the area, kept them minSeparation apart, and
        -- placed them clear of the arena's own cover. Nudging the result a
        -- few more metres on the client undoes all three: it can halve the
        -- separation the plan just guaranteed and it can drop somebody
        -- inside a barrier. The round-robin `spawns` list makes none of
        -- those promises, so it still gets the scatter it has always needed.
        scatterRadius = (match.spawnPlan and match.spawnPlan[player.src]) and 0.0 or scatterRadius(),
        -- The client builds the floor and the cover, so it needs the same
        -- number the spawns and the boundary were worked out from. Sent
        -- rather than recomputed on that side: the roster is not a thing the
        -- client can see, and two ends deriving the same number separately
        -- is how they come to disagree.
        sizeFactor = match.sizeFactor,
        -- The host's radar decision, carried in with everything else the
        -- round is fought under. The client keeps no preference of its own
        -- any more, so this is the only thing that turns a sweep on. Sent
        -- on entry only: the respawn payload does not repeat it, because a
        -- death is not an opportunity to re-decide the rules of the match.
        radar = match.radar == true,
        loadout = player.loadout,
        boundary = boundaryPayload(arena, match.sizeFactor),
        weatherOverride = arena.weatherOverride,
        timeOverride = arena.timeOverride,
        freezeSeconds = freezeSeconds,
    })
end

--- Where every live player on ONE SIDE of a match currently is -- the
--- opposition when `sameSideWanted` is false, this player's own team when it
--- is true. The two wrappers below name the two questions.
---
--- The distinction is the point: coming back near your own side is what
--- having one is for, while coming back near the opposition is what a
--- respawn must never do -- so the two lists are scored differently and
--- cannot share one call.
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
--- Where one player's body is, or nil when the server cannot see it.
---
--- NIL RATHER THAN THE ORIGIN. GetEntityCoords answers a zero vector for a
--- ped that has not streamed in, and no arena in this resource sits at
--- 0,0,0 -- the same reading livePositions below takes, and the reason both
--- of them check it.
--- @param src any
--- @return table|nil coords
local function positionOf(src)
    local ped = GetPlayerPed(Arena.ToInt(src) or -1)
    if not ped or ped == 0 then return nil end

    local coords = GetEntityCoords(ped)
    if type(coords) ~= 'table' and type(coords) ~= 'userdata' then return nil end
    if (coords.x == 0.0 or coords.x == 0) and (coords.y == 0.0 or coords.y == 0) then return nil end
    return coords
end

--- How far apart two positions are, or nil when either is unknown.
---
--- IN THREE DIMENSIONS, because the sky arena is a platform above the world
--- and a flat measurement between a player on it and one who has fallen off
--- would read as "next to each other".
--- @param a table|nil
--- @param b table|nil
--- @return number|nil metres
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

    -- A MODE WITH NO SIDES HAS NO TEAMMATES, and asking for them must answer
    -- nothing rather than everybody: in a free-for-all "not an opponent" is
    -- true of nobody except yourself, and reading it the other way would hand
    -- the respawn the whole roster to head towards.
    if sameSideWanted and not (teams and Arena.IsKey(own)) then return {} end

    local out = {}
    for src, entry in pairs(match.players or {}) do
        local sameSide = teams and Arena.IsKey(own) and teamOf(match, entry) == own
        if src ~= player.src and entry.alive == true and sameSide == sameSideWanted then
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

--- Everyone still alive who is allowed to shoot the player coming back.
--- @param match table
--- @param player table
--- @return table[] positions
--- How long a point handed to one respawning fighter keeps other respawns
--- away from it.
---
--- MONOTONIC MILLISECONDS -- GetGameTimer, the clock server/util.lua's rate
--- limiter uses, NOT the os.time() epoch seconds that stamp a match. This is
--- a "how recently" question measured in fractions of a second, and os.time
--- cannot see inside one.
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
            -- Pruned as we pass, so this table cannot grow with the round.
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

--- Everyone still alive on the returning player's OWN side.
---
--- Coming back away from the enemy is only half a respawn if it drops you
--- alone on the far side of the arena from your team. Arena.PickRespawn uses
--- this only to choose among points that ALREADY clear the enemy gap, so
--- rejoining your side can never cost you the distance you were placed for.
--- @param match table
--- @param player table
--- @return table[] positions
local function liveTeammatePositions(match, player)
    return livePositions(match, player, true)
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

        -- Re-resolved rather than reused, so a weapon an operator switched
        -- off between lives is not handed back out.
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

        -- THE LIVE ENEMIES, AND THE POINTS THE LAST FEW RESPAWNS WERE GIVEN.
        -- The second half is what stops two deaths in one tick converging on
        -- the same optimum; recentSpawnPoints above says why the roster
        -- cannot supply it.
        local avoid = liveOpponentPositions(current, entry)
        for _, taken in ipairs(recentSpawnPoints(current, entry)) do
            avoid[#avoid + 1] = taken
        end

        local planned = Arena.PickRespawn(current.arenaKey, team, avoid,
            nil, current.sizeFactor, liveTeammatePositions(current, entry))
        local point = planned or Arena.PickSpawn(current.arenaKey, team, current.spawnCursor)

        -- RECORDED BEFORE THE CLIENT IS TOLD, so the next thread to wake on
        -- this same tick already sees it. Copied field by field rather than
        -- held by reference: `point` may be a config table an arena shares
        -- between every fallback spawn, and stamping our own key onto one of
        -- those would reach into the config.
        if type(point) == 'table' then
            current.recentSpawns = current.recentSpawns or {}
            current.recentSpawns[src] = {
                point = { x = point.x, y = point.y, z = point.z },
                at = GetGameTimer(),
            }
        end

        TriggerClientEvent('crimson_arena:client:respawn', src, {
            spawn = toPoint(point),
            -- Same rule as entry: a point chosen to be as far from the
            -- nearest live opponent as the area allows, and clear of the
            -- cover, is not improved by moving it again at random.
            scatterRadius = planned and 0.0 or scatterRadius(),
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

    -- AND ARE THEY STILL IN THE FIGHT. A fighter who is out of the round --
    -- eliminated, or already sent back to the lobby ped -- was being
    -- credited with kills, and those kills decided the round: they ranked
    -- last on the board, stood at the NPC with `spectateOnElimination` off,
    -- and won on most-kills anyway.
    --
    -- THIS IS NOT THE "killer is dead" CASE, which stays credited on
    -- purpose: two fighters who kill each other in the same tick are both
    -- corpses when the reports arrive, and refusing those would delete half
    -- of every trade. Elimination is a different fact -- they have no lives
    -- left and the round has finished with them. The one case this does cost
    -- is a fighter whose own last life ran out in the same tick as the kill
    -- they were making, which is rare and errs toward "you were out" rather
    -- than "you win from the lobby".
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
    local ceiling = math.max(0, tonumber(Config.Match.maxKillDistance) or 0)
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
            -- Assigned in place, so the next unchosen player counts this one.
            player.team = Arena.SuggestTeam(players)
            assigned = assigned + 1
        end
    end

    -- WHO ACTUALLY ENDED UP ON WHICH SIDE, said once, here.
    --
    -- The join line reports the team a player CHOSE, and on a server where
    -- nobody touches the picker that is `nil` for everybody -- so a console
    -- full of "team nil" is the normal state of a working team round and
    -- says nothing at all about the sides that were then fought on.
    --
    -- That gap is expensive. "The team outline is not working" and "you were
    -- the odd one out in a 2v1, so you had no teammate to outline" produce
    -- the same report from a player and looked identical from this log,
    -- which is a question the server can simply answer.
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

    -- THE MODE'S OWN CLOCK, falling back to Config.Match's. Gun game is the
    -- mode this exists for: it is the only one where nobody is ever
    -- eliminated, so the clock is the whole ending rather than a backstop,
    -- and it wants a shorter round than a last-man-standing match does.
    local roundTime = Arena.RoundSecondsFor(match.modeKey)
    match.endsAt = roundTime > 0 and (match.startsAt + roundTime) or nil

    pushToMatch(match, 'crimson_arena:client:matchLive', { endsAt = match.endsAt })
    ArenaLobby.Broadcast()

    -- AND ONE MORE BROADCAST, AT THE MOMENT THE SIDE-BET WINDOW SHUTS.
    --
    -- ArenaLobby.Broadcast is driven by things people DO -- a join, a ready,
    -- a bet, a match ending -- and a window closing is a thing that happens
    -- to nobody. Without this the snapshot's `betsOpen` would stay true on
    -- every open panel until somebody else happened to act, which on a quiet
    -- server is the rest of the round.
    --
    -- One timer per live match, at a known instant, and it is cheap to be
    -- wrong: the broadcast is the same one a join would have sent, and the
    -- guard below drops it if the round is already over.
    local untilClosed = ArenaBetting.SecondsUntilBetsClose(match)
    if untilClosed then
        CreateThread(function()
            Wait(untilClosed * 1000)
            local current = ArenaLobby.Get(matchId)
            -- Ended, or restarted as a different round under the same id:
            -- either way this broadcast is about a match that no longer
            -- exists and End() has already sent its own.
            if current and current.state == 'live' then ArenaLobby.Broadcast() end
        end)
    end

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

    -- THE FALLBACK FOR WHEN INSTANCING IS NOT DOING ITS JOB.
    --
    -- Two matches can share one arena because each is fought in its own
    -- routing bucket -- they are in different instances of the world and
    -- cannot see, shoot or collide with each other. That is what makes ONE
    -- arena, in the sky or anywhere else, enough for a whole server.
    --
    -- It is also the single assumption the whole arrangement rests on. With
    -- Config.Dispatch.isolation switched off, or on a build where the routing
    -- natives do nothing, that separation is simply absent -- and then two
    -- matches in one arena is two groups of armed strangers dropped on top of
    -- each other, on a platform sized for one round.
    --
    -- So the sharing is allowed only while the thing that makes it safe is
    -- actually in force. Asked of ArenaDispatch rather than of the config,
    -- because the config is what an operator INTENDED and this is about what
    -- the server is really doing.
    if ArenaDispatch.GetBucket(matchId) == nil then
        for _, other in ipairs(ArenaLobby.All()) do
            if other.id ~= matchId and other.arenaKey == match.arenaKey
                and (other.state == 'live' or other.state == 'countdown')
            then
                ArenaLog('MATCH REFUSED: %s cannot start in arena "%s" while match %s is being fought there -- this server is not instancing matches, so they would share the ground.',
                    tostring(matchId), tostring(match.arenaKey), tostring(other.id))
                return false, 'error.arena_in_use'
            end
        end
    end

    local countdown = math.max(0, Arena.ToInt(Config.Match.lobbyCountdownSeconds) or 0)
    match.state = 'countdown'

    -- WHICH COUNTDOWN THIS IS, so a thread can tell whether it is still the
    -- one that owns the match.
    --
    -- `state` alone cannot answer that. Hold the countdown and start again
    -- and the state goes 'countdown' -> 'lobby' -> 'countdown', which the
    -- OLD thread cannot distinguish from never having been held -- so it
    -- wakes into the new countdown, finishes its own shorter run, and starts
    -- the round early while the panel is still showing seconds on the clock.
    match.countdownToken = (Arena.ToInt(match.countdownToken) or 0) + 1
    local token = match.countdownToken
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

        -- ASKED AGAIN AFTER THE LAST WAIT, and this is the whole reason the
        -- token exists.
        --
        -- The check at the top of the loop runs before each Wait, never
        -- after the final one -- so anything that happened during the last
        -- second was never read. "Stop The Countdown" in that second
        -- returned success to the host, put the lobby back to waiting, told
        -- the room it was held, and the round started anyway a moment later.
        -- ArenaMatch.Start accepts 'lobby' as well as 'countdown', so
        -- nothing further down caught it either.
        local current = ArenaLobby.Get(matchId)
        if not current or current.state ~= 'countdown' or current.countdownToken ~= token then
            return
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

    -- A FRESH LADDER EVERY ROUND. `ladderOf` draws one weapon per configured
    -- tier the first time anything asks and keeps it on the match record for
    -- the rest of the round -- so clearing it here is what makes the next
    -- round of the same match a different climb, and leaving it set is what
    -- makes THIS one the same climb for the scoreboard, the loadout and the
    -- promotion alike.
    match.ladder = nil

    -- Last round's leavers must not score for this one.
    match.departedKills = nil

    -- HOW MANY THE ROUND STARTED WITH, latched here and read by creditsTier.
    -- See there for why counting the live roster instead was an exploit.
    match.ladderSpread = #players
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
    -- HOW BIG THIS ARENA IS FOR THIS MATCH, decided once, here, and carried
    -- on the match for the rest of the round.
    --
    -- Twenty fighters in a circle sized for six cannot be minSeparation
    -- apart, so the placement quietly settled for less and everybody opened
    -- the round in somebody's sights. An arena that says so in config grows
    -- to fit the roster instead -- spawn area, floor, boundary and cover
    -- together, so the relationships between them survive.
    --
    -- DECIDED ONCE because every part of the round has to agree about it:
    -- the plan below, the boundary each client is given, the floor each
    -- client builds, and every respawn for the rest of the match. A factor
    -- recomputed later from a roster that has since lost a player would
    -- shrink the arena under the people standing in it.
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

        -- THE LADDER STARTS AT THE BOTTOM, every round, and every number it
        -- keeps goes with it. Rows are reused between rounds, so a player
        -- who topped the ladder last time would otherwise open the next one
        -- holding the top weapon and standing on a score that has already
        -- won, with last round's victims still counted against this round's
        -- cap.
        player.tier = nil
        player.tiersLost = nil
        player.ladderKills = nil
        player.ladderVictims = nil

        -- RE-RESOLVED, NOT TRUSTED. What the lobby stored was checked against
        -- the catalogue as it stood when the player picked it, and an
        -- operator may have reloaded config since. Feeding the stored
        -- loadout back through the same function re-checks every weapon key
        -- and re-clamps every ammo count against the list that is live now.
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
    -- An already-dead player reporting another death is a client repeating
    -- itself or someone farming eliminations. Either way there is nothing to
    -- score, which also makes a spammed report cost one table lookup.
    if not player or player.alive ~= true then return false end

    player.alive = false
    player.deaths = (Arena.ToInt(player.deaths) or 0) + 1

    -- THE START-ORDER WARNING, REPEATED WHERE THE SYMPTOM IS. It goes out
    -- once at boot in the middle of a report about six other things, and the
    -- thing it predicts -- an EMS call for somebody in the arena -- does not
    -- happen until here. Said once per resource lifetime, not per death.
    if type(ArenaCompat) == 'table' and type(ArenaCompat.WarnLateStartOnce) == 'function' then
        ArenaCompat.WarnLateStartOnce()
    end

    local playingLadder = #ladderOf(match) > 0

    local killer = resolveKiller(match, player, killerSrc)
    if killer then
        killer.kills = (Arena.ToInt(killer.kills) or 0) + 1

        -- THE LADDER MOVES ON A VERIFIED KILL AND NOWHERE ELSE. An
        -- unverified claim is logged below and changes nothing, so a client
        -- cannot climb by reporting deaths that did not happen.
        --
        -- AND NOT ON EVERY VERIFIED ONE EITHER. `resolveKiller` can only
        -- check that the named killer is a real, damageable opponent in this
        -- match -- it cannot see the kill -- so the same opponent named over
        -- and over is a farm, and creditsTier is what refuses it. The kill
        -- itself still counts; only the climb and the reward are withheld.
        if playingLadder then
            if creditsTier(match, killer, player) then
                killer.ladderKills = (Arena.ToInt(killer.ladderKills) or 0) + 1
                settleTier(match, killer, 'notify.gungame_promoted')
                payKillReward(match, killer)
            else
                ArenaNotifyKey(killer.src, 'notify.gungame_no_credit', 'warning', player.name)
            end
        end
    elseif killerSrc ~= nil then
        ArenaDebug('unverified kill claim on match %s: %s says %s killed them',
            tostring(match.id), tostring(id), tostring(killerSrc))
    end

    -- AND A DEATH COSTS A TIER, WHOEVER CAUSED IT. That is the whole shape of
    -- the mode: kills carry you up, deaths carry you back down, so where you
    -- are standing says you are winning NOW rather than that you once were.
    --
    -- WHOEVER CAUSED IT INCLUDES YOURSELF, and it has to. A demotion only on
    -- kills the server could verify would leave one free way down the ladder
    -- and back up it -- step off a roof, respawn, climb again with a full
    -- magazine each time -- and a mode where dying is the resupply is not
    -- the mode. A fall, a stray grenade and a knife all cost the same tier.
    --
    -- `tiersLost` IS ITS OWN NUMBER rather than an edit to `kills` or to
    -- `ladderKills`: the scoreboard, the leaderboard and the payout all read
    -- kills, and moving somebody down by deleting one would quietly rewrite
    -- what happened. Nobody drops below tier 1 -- tierScore floors at zero
    -- and this does not count a loss a player has no tier to pay it with --
    -- so a brutal round cannot push anyone into debt they can never climb
    -- out of.
    if playingLadder then
        if tierScore(player) > 0 then
            player.tiersLost = (Arena.ToInt(player.tiersLost) or 0) + 1
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

    -- THE DOWN FLAG COMES BACK DOWN HERE, at the death, not at the revive.
    --
    -- A dispatch script polls the medical script's "this player is down"
    -- metadata and files its own call the moment it goes up. The revive is
    -- seven seconds away on the respawn path -- five for the respawn delay,
    -- two more before the medical handoff -- and the poll runs every half
    -- second, so waiting for it lost the flag fourteen times over on every
    -- death of every round. ArenaDispatch holds it down from here.
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
    local remaining
    if playingLadder then
        remaining = math.max(1, Arena.ToInt(player.lives) or 1)
    else
        remaining = (Arena.ToInt(player.lives) or 1) - 1
        player.lives = remaining
    end

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

    -- THE ORDER OF THESE FIVE IS FIXED, and each one depends on the one
    -- above it:
    --   Settle first -- it is what turns held stakes into payouts, and
    --     nothing below it can run against an undecided pot;
    --   SettleSpectatorBets second -- it needs a decided result to judge bets
    --     against, and Clear hands unsettled side-bets BACK, so a Clear that
    --     ran first would quietly refund every winning side-bet;
    --   RecordMatch third, AND THIS IS WHY IT MOVED. A player's earnings are
    --     what they were paid, and the rule used to be "so record after
    --     Settle". That was right about the reason and wrong about the line:
    --     with betPayout.includeEntryPot on -- the shipped default -- Settle
    --     folds the entry stakes into the bet pool and returns an EMPTY
    --     payout list, and the money is paid one line further down by
    --     SettleSpectatorBets. So the leaderboard recorded every player at
    --     zero earnings on a default server, for ever, and the winner's own
    --     results board told them they had earned nothing while the pot
    --     arrived in their pocket. Recorded after BOTH now, from both.
    --   Clear fourth -- the only step that drops escrow, and it refuses
    --     while anything is still held, so running it before either settle
    --     would strand the pot with the match record already gone. The ammo
    --     Clear sits with it: same step, same rule, different ledger;
    --   Destroy last -- it removes the record all four of the others read.
    local payouts = ArenaBetting.Settle(match.id, context)
    match.payouts = payouts

    -- HOISTED, because two things want it now. It has always decided the
    -- spectator side-bets; it is also the only place that works out WHICH
    -- SIDE took a team round, and the results card never said. Everybody in
    -- a team deathmatch -- the winners, the losers and the spectators, whose
    -- only end-of-round message this is -- was shown a board with no mention
    -- of the winning team on it, ordered by individual kills, whose top row
    -- was as likely as not the losing side's best fragger.
    local pick = winningPick(match, winners, teamMode)

    local _, _, sideEarnings = ArenaBetting.SettleSpectatorBets(match.id, pick)

    local won, earned = {}, {}
    for _, id in ipairs(winners) do won[id] = true end

    -- WHAT THE SIDE-BET POOL PAID, folded in before the pot's own list --
    -- because on the shipped config the pot's own list is empty and this is
    -- the whole of it. Refunds are already excluded on the other side.
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
            -- THE SENTENCE, NOT THE KEY. This used to carry `endReason` --
            -- a locale key -- and nothing on the client could do anything
            -- with it: the panel has no locale file, so the field was dead
            -- on the wire for as long as it has existed.
            --
            -- Rendered here instead, and drawn on the board. It is not a
            -- duplicate of the toast below: the toast tells a LOSER why the
            -- round ended and tells a winner they won, and the spectators
            -- further down are sent no toast at all -- so the one screen
            -- everybody in the round is shown was also the one that never
            -- said what had happened.
            --
            -- `matchId` went with it, for the same reason: sent since the
            -- payload was written, read by nothing.
            reason = locale(endReason),
            won = won[player.src] == true,
            -- THE SIDE THAT TOOK IT, in a team mode and nowhere else -- in a
            -- free-for-all `pick` is the winning fighter's src, which is a
            -- different fact and is already carried by `won` and the board.
            -- The KEY, not a label: the panel has the team list on the wire
            -- already and draws it in the operator's own words and colour,
            -- the same rule the scoreboard rows follow.
            winningTeam = teamMode and pick or nil,
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
        -- The board still goes to a fighter who left the arena early: they
        -- are on the roster, they may have been paid, and the results event
        -- below is the one the panel actually draws.
        sendPlayerHome(player, { returnCoords = returnCoords, results = results })
        TriggerClientEvent('crimson_arena:client:results', player.src, results)
    end

    -- Spectators watched it, so they see the board; they were never in the
    -- arena, so they win nothing and are owed nothing. The board is the only
    -- reason they are sent anything at all at the end of a round.
    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            -- A spectator is sent no notification at the end of a round --
            -- they staked nothing and won nothing -- so this board is the
            -- only thing that tells them how the fight they just watched
            -- finished.
            local results = {
                reason = locale(endReason),
                won = false,
                -- Sent to a spectator for the same reason it is sent to a
                -- fighter, only more so: this board is the whole of what
                -- they are told, and "who won" is the one thing somebody
                -- who just watched a round wants off it.
                winningTeam = teamMode and pick or nil,
                earnings = 0,
                scoreboard = board,
            }
            sendExitArena(src, { returnCoords = returnCoords, results = results })
            TriggerClientEvent('crimson_arena:client:results', src, results)
        end
    end

    -- AND THE INVENTORY RECORDS -- AFTER THE EXITS, WHICH IS THE WHOLE POINT
    -- OF WHERE THIS LINE SITS.
    --
    -- ArenaAmmo.Clear drops the match's row from `issuedWeapons` and
    -- `issuedAmmo`, and those rows ARE the record of what the arena handed
    -- out. With the door off -- Config.Loadouts.inventory.stripOnEntry =
    -- false, where a player keeps their own inventory and is simply handed
    -- the arena's kit on top of it -- the exit's only way to take that kit
    -- back is to remove it BY NAME, from those rows. Clearing them first
    -- leaves nothing to remove, and every fighter walks out of a finished
    -- match still holding the arena's weapon and its ammunition. A free gun
    -- per round, per player, from a resource whose stated promise is that a
    -- match cannot cost or pay anyone anything.
    --
    -- Clear's own comment calls this "the point where a finished match stops
    -- being owed anything", which is exactly right and is why it belongs
    -- here rather than beside the betting Clear: the match is still owed
    -- every reclaim until the exits above have run. ArenaMatch.Abort has
    -- always had it in this order; End did not.
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
        -- THE SENTENCE, NOT THE KEY, for the same reason the results board
        -- twenty lines up says so. An operator reading their Discord log got
        -- "match.ended_time_up" where every other webhook in this resource
        -- posts a written line -- and the one place the raw key belongs is
        -- ArenaLog below, which is a machine-readable server log.
        ArenaWebhook(('Match %s finished'):format(tostring(match.id)), locale(endReason), {
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
        sendPlayerHome(player, { returnCoords = returnCoords })
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
--- @param dropped boolean? -- their connection went away; see detach()
function ArenaMatch.RemovePlayer(src, reasonKey, dropped)
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
        sendPlayerHome(player, {
            returnCoords = toPoint(Config.Lobby.returnCoords),
        })
    end

    ArenaLobby.Leave(id, reasonKey or 'match.left', dropped)

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
--- Whether any fighter in this match has actually been teleported in.
---
--- THE FLAG, NOT THE STATE. 'countdown' names both the lobby countdown --
--- before anybody has moved -- and the frozen one after placement, and
--- nothing else tells them apart. server/lobby.lua's playersArePlaced is the
--- same predicate for the same reason; it is local to that file, so this is
--- the same question asked where this file can reach it.
--- @param match table
--- @return boolean
local function anyoneIsPlaced(match)
    for src in pairs(match.players or {}) do
        if ArenaDispatch.IsPlayerInArena(src) then return true end
    end
    return false
end

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
                -- Only the ones actually standing in the arena. An unplaced
                -- fighter is recorded as a fighter -- so the spectator branch
                -- below cannot claim them and flag them -- and is left in the
                -- world where they are.
                if ArenaDispatch.IsPlayerInArena(src) then wanted[src] = match.id end
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
            instanced[src] = matchId
        end

        -- EVERY PASS, NOT ONLY THE FIRST, and that is the whole point of
        -- moving it out of the branch above.
        --
        -- `instanced` records what this file decided; it cannot record what
        -- another resource did afterwards. A player moved out of the match's
        -- instance by anything else on the server still matches
        -- `instanced[src] == matchId`, so the guarded version agreed there
        -- was nothing to do and they finished the round in the ordinary
        -- world. EnterBucket is idempotent and now checks where the player
        -- actually is rather than where we recorded them, so calling it on
        -- every pass costs one read a player a second and closes that.
        ArenaDispatch.EnterBucket(src, matchId)
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

--- What the opening-hours answer was last tick, so the BELL below fires on
--- the CHANGE and not once a second forever. nil until the first tick, which
--- is why the first comparison is against a value and not against `false`.
local hoursWereOpen = nil

CreateThread(function()
    while true do
        Wait(SWEEP_INTERVAL_MS)

        -- THE BELL. A window opening or shutting is, in goLive's own words,
        -- a thing that happens to nobody: ArenaLobby.Broadcast fires on a
        -- join, a ready, a bet, a start and an end, so without this an open
        -- panel would go on offering Create Match for the rest of the round
        -- and a shut arena would go on looking open.
        --
        -- It rides this sweep rather than starting a thread of its own. The
        -- idle-lobby sweep in server/lobby.lua cannot be used: that whole
        -- thread sits inside `if idleTimeout > 0 then` and is simply absent
        -- on a server that has switched the idle timeout off.
        local hoursOpen = ArenaHoursOpen()
        if hoursWereOpen ~= nil and hoursWereOpen ~= hoursOpen then
            if not hoursOpen then
                -- ONLY LOBBIES, and only lobbies. A round already being
                -- fought is fought to the end -- the doors being shut is
                -- about who may come in, not about who is already inside.
                -- Widening this to `~= 'ended'` is the mutation that would
                -- abort live rounds at the stroke of the hour.
                --
                -- Ids collected before destroying, the pattern the idle
                -- sweep already uses, because Destroy removes from the very
                -- registry All() was read from.
                local waiting = {}
                for _, match in ipairs(ArenaLobby.All()) do
                    if match.state == 'lobby' then waiting[#waiting + 1] = match.id end
                end

                -- DESTROY, NEVER CANCEL. Cancel is the one way of closing a
                -- lobby an operator can make cost something, and an operator
                -- who chose to punish a host for calling their own match off
                -- has not asked to punish a lobby the SERVER closed. Destroy
                -- refunds every stake unconditionally.
                for _, id in ipairs(waiting) do
                    ArenaLobby.Destroy(id, 'notify.hours_lobby_closed')
                end
            end

            ArenaLobby.Broadcast()
        end
        hoursWereOpen = hoursOpen

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
