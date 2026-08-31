--[[
    crimson_arena/shared/arena.lua

    The rules, with no game attached.

    Every decision this resource makes that is not "draw something" or "move
    something" lives here: which weapons are real, how much ammo is legal,
    whether a team split may start, and how a pot is divided. It is loaded
    into BOTH Lua VMs from `shared_scripts`, which is the whole point --
    the panel a player sees and the server that answers them run the exact
    same code, so the UI can never offer something the server will refuse.

    IT CALLS NO NATIVES. Not one. That is deliberate and load-bearing:
    it means tests/ can load this file under plain lua5.4 and exercise every
    rule directly, and it means neither realm can quietly grow a dependency
    on the other's runtime.

    WHO TRUSTS WHOM: the client calls into this file to BUILD the panel.
    The server calls into the same functions to CHECK what comes back. The
    client's copy is a convenience; the server's copy is the authority.
    Nothing here reads player input without validating it, because on the
    server side every argument arrived over the network.
]]

Arena = {}

--- Namespaced so a console line is always attributable.
--- @param message string
local function warn(message)
    print(('[crimson_arena] %s'):format(message))
end

-- ======================================================================
-- SMALL SHARED PRIMITIVES
-- ======================================================================

--- Rounds toward zero and returns an integer. Used everywhere money and
--- ammo are involved -- a float ammo count or a fractional payout is a bug
--- in every direction, so it is squashed at the boundary rather than at
--- each call site.
--- @param value any
--- @return integer|nil
function Arena.ToInt(value)
    local number = tonumber(value)
    if not number or number ~= number then return nil end          -- nil or NaN
    if number == math.huge or number == -math.huge then return nil end
    return math.floor(number)
end

--- Clamps `value` into [`minimum`, `maximum`] as an integer. Returns nil for
--- anything that is not a number at all, so callers can tell "out of range"
--- (clamped) from "not a number" (rejected).
--- @param value any
--- @param minimum integer
--- @param maximum integer
--- @return integer|nil
function Arena.ClampInt(value, minimum, maximum)
    local number = Arena.ToInt(value)
    if not number then return nil end
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

--- True only for a non-empty string. Every key that arrives over the wire
--- goes through this before it is used to index a config table -- indexing
--- with a table or a number would either error or, worse, silently hit an
--- array position.
--- @param value any
--- @return boolean
function Arena.IsKey(value)
    return type(value) == 'string' and value ~= ''
end

--- Counts entries in a map-shaped table (`#` only works on arrays).
--- @param tbl table?
--- @return integer
function Arena.Count(tbl)
    if type(tbl) ~= 'table' then return 0 end
    local total = 0
    for _ in pairs(tbl) do total = total + 1 end
    return total
end

-- ======================================================================
-- CATALOGUE LOOKUPS
--
-- All four read straight from Config every call rather than caching at
-- load time. That is intentional: an operator editing config.lua and
-- restarting the resource gets the new list, and there is no second copy
-- of the catalogue that can drift out of sync with the first.
-- ======================================================================

--- Every weapon an operator has left switched on, in config order.
--- @return table[] weapons
function Arena.GetEnabledWeapons()
    local out = {}
    for _, weapon in ipairs(Config.Loadouts.weapons or {}) do
        if weapon.enabled ~= false and Arena.IsKey(weapon.key) and Arena.IsKey(weapon.weapon) then
            out[#out + 1] = weapon
        end
    end
    return out
end

--- The one weapon with this key, or nil. Returns nil for a disabled weapon
--- as well as an unknown one -- callers must not be able to tell the
--- difference, or `enabled = false` would only be a UI hint.
--- @param key any
--- @return table|nil
function Arena.GetWeaponByKey(key)
    if not Arena.IsKey(key) then return nil end
    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        if weapon.key == key then return weapon end
    end
    return nil
end

--- Enabled teams, sorted by their `order` then key so every client renders
--- the picker in the same sequence.
--- @return table[] teams -- array of { key = string, ... } (config fields copied through)
function Arena.GetEnabledTeams()
    local out = {}
    for key, team in pairs(Config.Teams.list or {}) do
        if team.enabled ~= false then
            out[#out + 1] = {
                key = key,
                label = team.label or key,
                color = team.color,
                blipColor = team.blipColor,
                order = team.order or 999,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    return out
end

--- @param key any
--- @return table|nil
function Arena.GetTeamByKey(key)
    if not Arena.IsKey(key) then return nil end
    for _, team in ipairs(Arena.GetEnabledTeams()) do
        if team.key == key then return team end
    end
    return nil
end

--- @return table[] arenas -- array of { key = string, ... }
function Arena.GetEnabledArenas()
    local out = {}
    for key, arena in pairs(Config.Arenas or {}) do
        if arena.enabled ~= false then
            out[#out + 1] = {
                key = key,
                label = arena.label or key,
                description = arena.description,
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- @param key any
--- @return table|nil -- the RAW config entry (spawns, boundary and all)
function Arena.GetArenaByKey(key)
    if not Arena.IsKey(key) then return nil end
    local arena = (Config.Arenas or {})[key]
    if not arena or arena.enabled == false then return nil end
    return arena
end

--- @return table[] modes -- array of { key = string, ... }
function Arena.GetEnabledModes()
    local out = {}
    for key, mode in pairs(Config.Modes or {}) do
        if mode.enabled ~= false then
            out[#out + 1] = {
                key = key,
                label = mode.label or key,
                description = mode.description,
                teams = mode.teams == true,
                icon = mode.icon,
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- @param key any
--- @return table|nil
function Arena.GetModeByKey(key)
    if not Arena.IsKey(key) then return nil end
    local mode = (Config.Modes or {})[key]
    if not mode or mode.enabled == false then return nil end
    return mode
end

--- True when this mode puts players on sides. Everything team-shaped --
--- the picker, the spawn split, the payout -- keys off this one answer
--- rather than re-reading `mode.teams` in five places.
--- @param modeKey any
--- @return boolean
function Arena.ModeUsesTeams(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    return mode ~= nil and mode.teams == true
end

-- ======================================================================
-- AMMO
-- ======================================================================

--- The ammo values the panel offers for one weapon. An empty list means
--- "no choice to make" (melee) -- NOT "no ammo".
--- @param weapon table -- a Config.Loadouts.weapons entry
--- @return integer[] options
function Arena.GetAmmoOptions(weapon)
    local ammo = weapon and weapon.ammo or nil
    if type(ammo) ~= 'table' or type(ammo.options) ~= 'table' then return {} end
    local out = {}
    for _, option in ipairs(ammo.options) do
        local value = Arena.ToInt(option)
        if value and value >= 0 then out[#out + 1] = value end
    end
    table.sort(out)
    return out
end

--- Turns whatever a client asked for into an ammo count the server is
--- willing to hand out.
---
--- THE RULE, in order:
---   1. A weapon with a fixed `options` list only ever gets a value FROM
---      that list. An off-list request is not clamped to the nearest legal
---      value -- it falls back to the default, because "closest" would let
---      a modified client walk a value up past a preset by asking for one
---      just above it.
---   2. A weapon with no `options` list is a free-form ammo weapon: the
---      request is clamped into [0, max].
---   3. Anything non-numeric, and any weapon at all when
---      `Config.Loadouts.allowChoose` is off, gets the default.
--- @param weapon table
--- @param requested any -- straight off the wire; may be anything
--- @return integer ammo
function Arena.ResolveAmmo(weapon, requested)
    local ammo = weapon and weapon.ammo or nil
    if type(ammo) ~= 'table' then return 0 end

    local maximum = Arena.ToInt(ammo.max) or Arena.ToInt(ammo.default) or 0
    local default = Arena.ClampInt(ammo.default, 0, maximum) or 0

    if Config.Loadouts.allowChoose == false then return default end

    local wanted = Arena.ToInt(requested)
    if not wanted or wanted < 0 then return default end

    local options = Arena.GetAmmoOptions(weapon)
    if #options > 0 then
        for _, option in ipairs(options) do
            if option == wanted then
                return Arena.ClampInt(option, 0, maximum) or default
            end
        end
        return default              -- rule 1: off-list is refused, not rounded
    end

    return Arena.ClampInt(wanted, 0, maximum) or default
end

--- Same shape of decision for body armour.
--- @param requested any
--- @return integer armor
function Arena.ResolveArmor(requested)
    local armor = Config.Loadouts.armor or {}
    local maximum = Arena.ToInt(armor.max) or 100
    local default = Arena.ClampInt(armor.default, 0, maximum) or 0

    if armor.allowChoose == false or Config.Loadouts.allowChoose == false then
        return default
    end

    local wanted = Arena.ToInt(requested)
    if not wanted or wanted < 0 then return default end

    if type(armor.options) == 'table' and #armor.options > 0 then
        for _, option in ipairs(armor.options) do
            if Arena.ToInt(option) == wanted then
                return Arena.ClampInt(wanted, 0, maximum) or default
            end
        end
        return default
    end

    return Arena.ClampInt(wanted, 0, maximum) or default
end

-- ======================================================================
-- LOADOUTS
-- ======================================================================

--- Validates a whole loadout request and returns the concrete thing to
--- hand a player -- real GTA weapon names and real ammo counts, nothing
--- the caller supplied passed through untouched.
---
--- This is THE function the server calls before giving anybody a gun. It
--- is also what the client calls to preview the loadout, so a player never
--- sees a summary that differs from what they are about to receive.
---
--- FAILS SOFT, NOT CLOSED. An unknown weapon key is dropped and the rest
--- of the request is honoured; a request that ends up with no weapons at
--- all still succeeds, carrying only `alwaysGive`. A player who sends
--- rubbish gets a knife and a bad match, not a stuck lobby. The one thing
--- it will not do is exceed `weaponSlots` or hand out a weapon that is not
--- in the enabled catalogue.
--- @param request table? -- { weapons = { { key = string, ammo = any }, ... }, armor = any }; a weapons entry flagged `alwaysGive` is the operator's own and is skipped, since the list below re-appends it
--- @return table loadout -- { weapons = { { weapon = string, ammo = integer, components = table, tint = integer } }, armor = integer, health = integer }
--- @return string[] rejected -- keys that were dropped, for logging/telemetry
function Arena.ResolveLoadout(request)
    local rejected = {}
    local resolved = {}
    local seen = {}

    local slots = Arena.ToInt(Config.Loadouts.weaponSlots) or 1
    if slots < 0 then slots = 0 end

    -- With choosing switched off the request is ignored entirely and the
    -- operator's `fixed` list is what everybody gets.
    local source = request
    if Config.Loadouts.allowChoose == false then
        source = { weapons = Config.Loadouts.fixed or {}, armor = nil }
    end

    local wanted = (type(source) == 'table' and type(source.weapons) == 'table') and source.weapons or {}

    for _, entry in ipairs(wanted) do
        if #resolved >= slots then break end

        -- An `alwaysGive` entry coming back round. A loadout is stored
        -- resolved and re-resolved at match start, so the operator's list
        -- below arrives here as part of the request, under a GTA weapon name
        -- that is not a catalogue key. Ignored rather than read: the loop
        -- below appends it again regardless, so honouring it here would spend
        -- a player's slot on the house weapon, and rejecting it would name
        -- that weapon in the dropped-weapon log of every match ever started.
        if not (type(entry) == 'table' and entry.alwaysGive == true) then
            local key = type(entry) == 'table' and entry.key or entry
            local weapon = Arena.GetWeaponByKey(key)

            if not weapon then
                rejected[#rejected + 1] = tostring(key)
            elseif seen[weapon.key] then
                -- Asking for the same gun twice would otherwise burn two slots
                -- for one weapon and silently short-change the player.
                rejected[#rejected + 1] = weapon.key
            else
                -- BOTH SPELLINGS, because the two loops speak different ones:
                -- a picked weapon is known by its catalogue key, and the
                -- `alwaysGive` guard below has only the GTA name to test with.
                seen[weapon.key] = true
                seen[weapon.weapon] = true
                resolved[#resolved + 1] = {
                    key = weapon.key,
                    weapon = weapon.weapon,
                    label = weapon.label or weapon.key,
                    ammo = Arena.ResolveAmmo(weapon, type(entry) == 'table' and entry.ammo or nil),
                    components = type(weapon.components) == 'table' and weapon.components or {},
                    tint = Arena.ToInt(weapon.tint) or 0,
                }
            end
        end
    end

    -- `alwaysGive` is appended AFTER the slot limit is applied, on purpose:
    -- it is the operator's own list, not the player's, and it should not be
    -- possible to spend your slots in a way that denies you the house knife.
    for _, entry in ipairs(Config.Loadouts.alwaysGive or {}) do
        if Arena.IsKey(entry.weapon) and not seen[entry.weapon] then
            seen[entry.weapon] = true
            resolved[#resolved + 1] = {
                key = entry.key or entry.weapon,
                weapon = entry.weapon,
                label = entry.label or entry.weapon,
                ammo = math.max(0, Arena.ToInt(entry.ammo) or 0),
                components = type(entry.components) == 'table' and entry.components or {},
                tint = Arena.ToInt(entry.tint) or 0,
                alwaysGive = true,
            }
        end
    end

    return {
        weapons = resolved,
        armor = Arena.ResolveArmor(type(source) == 'table' and source.armor or nil),
        health = Arena.ClampInt(Config.Loadouts.health, 100, 200) or 200,
    }, rejected
end

-- ======================================================================
-- TEAMS
-- ======================================================================

--- Head count per team, from a list of players.
--- @param players table[] -- entries carrying a `.team` field
--- @return table<string, integer> counts -- only teams with at least one player
function Arena.CountTeams(players)
    local counts = {}
    for _, player in ipairs(players or {}) do
        local team = player.team
        if Arena.IsKey(team) then
            counts[team] = (counts[team] or 0) + 1
        end
    end
    return counts
end

--- The team a newly joining player should land on when they did not pick
--- one: the smallest enabled team WITH ROOM IN IT, ties broken by config
--- order so the choice is deterministic rather than dependent on pairs()
--- ordering.
---
--- `Config.Teams.maxTeamSize` is read here as well as in
--- Arena.TeamsAreStartable because a suggestion that ignored it does not
--- avoid the refusal, it only moves it to the start button -- with the
--- over-capacity side already written onto the player, and with the switch
--- they would need to fix it themselves refused for the same reason.
--- @param players table[]
--- @return string|nil teamKey -- nil when no team is enabled, and when every enabled team is full
function Arena.SuggestTeam(players)
    local counts = Arena.CountTeams(players)
    local cap = Arena.ToInt(Config.Teams.maxTeamSize) or 0
    local best, bestCount
    for _, team in ipairs(Arena.GetEnabledTeams()) do
        local count = counts[team.key] or 0
        local hasRoom = cap <= 0 or count < cap
        if hasRoom and (not bestCount or count < bestCount) then
            best, bestCount = team.key, count
        end
    end
    return best
end

--- Whether a team match may start with these sides.
---
--- UNEVEN TEAMS: with `Config.Teams.allowUnequal` on (the default) this
--- only ever refuses for a reason that is not about balance -- a team with
--- nobody in it, a team over its size cap, or more players still without a
--- side than the caps have seats left for them. 7v1 passes.
--- @param players table[]
--- @return boolean ok
--- @return string|nil reason -- a locale key, not a sentence
function Arena.TeamsAreStartable(players)
    local counts = Arena.CountTeams(players)
    local teams = Arena.GetEnabledTeams()

    if #teams == 0 then return false, 'error.no_teams_enabled' end

    local cap = Arena.ToInt(Config.Teams.maxTeamSize) or 0
    local occupied, freeSeats = 0, 0
    for _, team in ipairs(teams) do
        local count = counts[team.key] or 0
        if count > 0 then occupied = occupied + 1 end

        if cap > 0 then
            if count > cap then return false, 'error.team_over_capacity' end
            freeSeats = freeSeats + (cap - count)
        end
    end

    -- Anybody who has not picked is dropped onto the smallest team with room
    -- at start (Arena.SuggestTeam), so a roster carrying more of them than
    -- the caps have seats for cannot be made startable by that assignment.
    -- Refused here rather than started: a team match that ran anyway would
    -- carry a fighter with no side, which no win condition can rank and no
    -- friendly-fire rule can place.
    if cap > 0 then
        local unassigned = 0
        for _, player in ipairs(players or {}) do
            if not Arena.IsKey(player.team) then unassigned = unassigned + 1 end
        end
        if unassigned > freeSeats then return false, 'error.team_over_capacity' end
    end

    if Config.Teams.requireBothTeamsOccupied ~= false and occupied < 2 then
        return false, 'error.need_two_teams'
    end

    if Config.Teams.allowUnequal == false then
        local smallest, largest
        for _, team in ipairs(teams) do
            local count = counts[team.key] or 0
            if count > 0 then
                if not smallest or count < smallest then smallest = count end
                if not largest or count > largest then largest = count end
            end
        end
        local allowed = Arena.ToInt(Config.Teams.maxTeamSizeDifference) or 1
        if smallest and largest and (largest - smallest) > allowed then
            return false, 'error.teams_unbalanced'
        end
    end

    return true, nil
end

--- Whether one player may hurt another. In free-for-all everybody can hurt
--- everybody; in a team mode this is what `friendlyFire` actually means.
--- @param modeKey any
--- @param attackerTeam any
--- @param victimTeam any
--- @return boolean
function Arena.CanDamage(modeKey, attackerTeam, victimTeam)
    if not Arena.ModeUsesTeams(modeKey) then return true end
    if not Arena.IsKey(attackerTeam) or not Arena.IsKey(victimTeam) then return true end
    if attackerTeam ~= victimTeam then return true end
    return Config.Teams.friendlyFire == true
end

-- ======================================================================
-- SPAWNS
-- ======================================================================

--- Picks the spawn point for the `index`-th player (1-based) on a team.
---
--- Round-robin, so an arena with four spawn points serves forty players --
--- the caller scatters them within `Config.Match.spawnScatterRadius`, which
--- is what actually stops two players materialising inside each other.
--- @param arenaKey any
--- @param teamKey any -- nil in free-for-all
--- @param index integer
--- @return table|nil spawn -- a vector4-shaped value straight from config
function Arena.PickSpawn(arenaKey, teamKey, index)
    local arena = Arena.GetArenaByKey(arenaKey)
    if not arena then return nil end

    local list
    if Arena.IsKey(teamKey) and type(arena.teamSpawns) == 'table' then
        local teamList = arena.teamSpawns[teamKey]
        if type(teamList) == 'table' and #teamList > 0 then list = teamList end
    end
    -- Falling back to the shared list is what lets an operator enable a
    -- third team without editing every arena.
    if not list then list = arena.spawns end
    if type(list) ~= 'table' or #list == 0 then return nil end

    local position = Arena.ToInt(index) or 1
    if position < 1 then position = 1 end
    return list[((position - 1) % #list) + 1]
end

-- ======================================================================
-- BETTING MATHS
--
-- Integer money throughout. Every split below distributes the remainder
-- rather than dropping it, so the sum of what is paid out always equals
-- the net pot exactly -- a pot that leaks a few dollars per match is the
-- kind of bug nobody reports and everybody notices.
-- ======================================================================

--- Clamps a requested entry fee into the configured band. Returns nil when
--- betting or entry fees are off, which callers treat as "reject the bet"
--- rather than "bet zero".
--- @param requested any
--- @return integer|nil amount
--- @return string|nil reason
function Arena.ResolveEntryFee(requested)
    if Config.Betting.enabled ~= true then return nil, 'error.betting_disabled' end

    local fee = Config.Betting.entryFee or {}
    if fee.enabled ~= true then return 0, nil end

    local minimum = math.max(0, Arena.ToInt(fee.min) or 0)
    local maximum = math.max(minimum, Arena.ToInt(fee.max) or minimum)

    local wanted = Arena.ToInt(requested)
    if not wanted then
        return Arena.ClampInt(fee.default, minimum, maximum) or minimum, nil
    end
    if wanted < minimum or wanted > maximum then
        return nil, 'error.bet_out_of_range'
    end
    return wanted, nil
end

--- @param requested any
--- @return integer|nil amount
--- @return string|nil reason
function Arena.ResolveSpectatorBet(requested)
    if Config.Betting.enabled ~= true then return nil, 'error.betting_disabled' end

    local spectator = Config.Betting.spectatorBets or {}
    if spectator.enabled ~= true then return nil, 'error.spectator_bets_disabled' end

    local minimum = math.max(0, Arena.ToInt(spectator.min) or 0)
    local maximum = math.max(minimum, Arena.ToInt(spectator.max) or minimum)

    local wanted = Arena.ToInt(requested)
    if not wanted then return nil, 'error.bet_invalid' end
    if wanted < minimum or wanted > maximum then return nil, 'error.bet_out_of_range' end
    return wanted, nil
end

--- The house cut, and what is left to pay out.
--- @param pot integer
--- @return integer net
--- @return integer cut
function Arena.ApplyHouseCut(pot)
    local total = math.max(0, Arena.ToInt(pot) or 0)
    local percent = Arena.ToInt(Config.Betting.houseCutPercent) or 0
    if percent <= 0 then return total, 0 end
    if percent >= 100 then return 0, total end
    local cut = math.floor((total * percent) / 100)
    return total - cut, cut
end

--- Splits `amount` between `count` recipients as evenly as integers allow,
--- handing the remainder out one unit at a time from the front. Sum of the
--- returned list is always exactly `amount`.
--- @param amount integer
--- @param count integer
--- @return integer[] shares
function Arena.SplitEvenly(amount, count)
    local total = math.max(0, Arena.ToInt(amount) or 0)
    local recipients = Arena.ToInt(count) or 0
    if recipients <= 0 then return {} end

    local base = math.floor(total / recipients)
    local remainder = total - (base * recipients)

    local shares = {}
    for index = 1, recipients do
        shares[index] = base + (index <= remainder and 1 or 0)
    end
    return shares
end

--- Splits `amount` by a list of percentages, again losing nothing: whatever
--- rounding leaves over goes to the first recipient.
--- @param amount integer
--- @param percents number[]
--- @return integer[] shares
function Arena.SplitByPercent(amount, percents)
    local total = math.max(0, Arena.ToInt(amount) or 0)
    if type(percents) ~= 'table' or #percents == 0 then return {} end

    local sum = 0
    for _, percent in ipairs(percents) do sum = sum + (tonumber(percent) or 0) end
    if sum <= 0 then return Arena.SplitEvenly(total, #percents) end

    local shares, allocated = {}, 0
    for index, percent in ipairs(percents) do
        local share = math.floor((total * (tonumber(percent) or 0)) / sum)
        shares[index] = share
        allocated = allocated + share
    end
    shares[1] = shares[1] + (total - allocated)
    return shares
end

--- Works out who gets paid what when a match ends.
---
--- `context` is deliberately plain data, not a live match object, so this
--- can be tested exhaustively without a server:
---   pot         -- integer, everything staked
---   players     -- array of { id, team, kills, stake, placement }
---   winners     -- array of ids (already decided by the match, not here)
---   teams       -- boolean, whether this was a team mode
---   contestants -- integer, how many the round was FOUGHT with; optional,
---                  and only ever read for the minPlayersToPayOut threshold
---
--- RETURNS `payouts` (array of { id, amount, reason }) plus the house cut.
--- A `reason` of 'refund' means the match did not qualify to pay out and
--- everybody is getting their own stake back -- the caller pays those out
--- exactly the same way, but should say something different to the player.
--- @param context table
--- @return table[] payouts
--- @return integer houseCut
function Arena.ComputePayouts(context)
    context = context or {}
    local players = type(context.players) == 'table' and context.players or {}
    local winners = type(context.winners) == 'table' and context.winners or {}
    local pot = math.max(0, Arena.ToInt(context.pot) or 0)

    local function refundEveryone(reason)
        local payouts = {}
        for _, player in ipairs(players) do
            local stake = math.max(0, Arena.ToInt(player.stake) or 0)
            if stake > 0 then
                payouts[#payouts + 1] = { id = player.id, amount = stake, reason = reason or 'refund' }
            end
        end
        return payouts, 0
    end

    if pot <= 0 then return {}, 0 end

    -- Too few players for the pot to mean anything: give it all back.
    --
    -- Judged on how many FOUGHT the round, not on how many are left to be
    -- paid. Read off the survivors, a 1v1 whose loser walked out mid-round
    -- becomes a one-player match and refunds the pot -- handing the quitter
    -- back the stake that leaving was supposed to forfeit, and paying the
    -- winner nothing but their own. A caller that does not know the figure --
    -- a lobby closed before it ever went live -- passes none, where the two
    -- numbers are the same one anyway. Never below the roster in hand: this
    -- count only ever grows the head count, so a stale or missing one cannot
    -- refund a match that is standing in front of it.
    local contestants = math.max(#players, Arena.ToInt(context.contestants) or 0)
    local minimum = Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0
    if contestants < minimum then return refundEveryone('refund_too_few') end

    -- Nobody won (everyone left, double knockout, clock ran out on a tie
    -- the match could not break): refund rather than invent a winner.
    if #winners == 0 then return refundEveryone('refund_no_winner') end

    local net, cut = Arena.ApplyHouseCut(pot)
    if net <= 0 then return {}, cut end

    local mode = Config.Betting.payout or 'winner_takes_all'
    local payouts = {}

    if mode == 'per_kill' then
        local totalKills = 0
        for _, player in ipairs(players) do
            totalKills = totalKills + math.max(0, Arena.ToInt(player.kills) or 0)
        end
        -- A match where nobody killed anybody cannot be split by kills.
        if totalKills <= 0 then return refundEveryone('refund_no_kills') end

        local percents, recipients = {}, {}
        for _, player in ipairs(players) do
            local kills = math.max(0, Arena.ToInt(player.kills) or 0)
            if kills > 0 then
                percents[#percents + 1] = kills
                recipients[#recipients + 1] = player.id
            end
        end
        local shares = Arena.SplitByPercent(net, percents)
        for index, id in ipairs(recipients) do
            payouts[#payouts + 1] = { id = id, amount = shares[index] or 0, reason = 'per_kill' }
        end
        return payouts, cut
    end

    if mode == 'top_three' and context.teams ~= true then
        -- Ordered by finishing position; `winners` is already in placement
        -- order for FFA, best first.
        local placed = {}
        for index = 1, math.min(3, #winners) do placed[index] = winners[index] end
        local percents = {}
        for index = 1, #placed do
            percents[index] = (Config.Betting.topThreeSplit or {})[index] or 0
        end
        local shares = Arena.SplitByPercent(net, percents)
        for index, id in ipairs(placed) do
            payouts[#payouts + 1] = { id = id, amount = shares[index] or 0, reason = 'placement' }
        end
        return payouts, cut
    end

    -- winner_takes_all, and the fallback for any unrecognised mode: split
    -- evenly across every winner. In a team match that is the whole winning
    -- team, which is what makes a 7v1 win worth less per head than a 1v1 --
    -- deliberate, and the reason uneven teams are safe to allow.
    local shares = Arena.SplitEvenly(net, #winners)
    for index, id in ipairs(winners) do
        payouts[#payouts + 1] = { id = id, amount = shares[index] or 0, reason = 'winner' }
    end
    return payouts, cut
end

--- What one winning spectator side-bet pays back, stake included.
--- @param stake any
--- @return integer
function Arena.ComputeSpectatorPayout(stake)
    local amount = math.max(0, Arena.ToInt(stake) or 0)
    local multiplier = tonumber((Config.Betting.spectatorBets or {}).oddsMultiplier) or 2.0
    if multiplier <= 0 then return 0 end
    return math.floor(amount * multiplier)
end

-- ======================================================================
-- MATCH READINESS
-- ======================================================================

--- Whether a lobby may start. Runs the same checks the server will, which
--- is what lets the panel grey the start button out for the right reason
--- instead of letting a player press it and be told no.
--- @param match table -- { arenaKey, modeKey, players = { { id, team, ready } } }
--- @return boolean ok
--- @return string|nil reason -- locale key
function Arena.CanStartMatch(match)
    match = match or {}
    local players = type(match.players) == 'table' and match.players or {}

    if not Arena.GetArenaByKey(match.arenaKey) then return false, 'error.arena_unavailable' end
    if not Arena.GetModeByKey(match.modeKey) then return false, 'error.mode_unavailable' end

    local minimum = math.max(1, Arena.ToInt(Config.Match.minPlayers) or 1)
    if #players < minimum then return false, 'error.not_enough_players' end

    local maximum = Arena.ToInt(Config.Match.maxPlayers) or 0
    if maximum > 0 and #players > maximum then return false, 'error.match_full' end

    if Arena.ModeUsesTeams(match.modeKey) then
        local ok, reason = Arena.TeamsAreStartable(players)
        if not ok then return false, reason end
    end

    return true, nil
end

--- Whether one more player will fit. `maxPlayers = 0` means unlimited, so
--- this is the single place that rule is spelled out.
--- @param currentCount integer
--- @return boolean
function Arena.HasRoom(currentCount)
    local maximum = Arena.ToInt(Config.Match.maxPlayers) or 0
    if maximum <= 0 then return true end
    return (Arena.ToInt(currentCount) or 0) < maximum
end

-- ======================================================================
-- CONFIG VALIDATION
--
-- Run once at start on BOTH realms. It does not throw: a bad value is
-- reported by name and left alone, because a hard failure here would take
-- the whole resource down over a typo in a weapon label.
-- ======================================================================

--- @return string[] problems -- empty when the config is clean
function Arena.ValidateConfig()
    local problems = {}
    local function complain(message)
        problems[#problems + 1] = message
    end

    if #Arena.GetEnabledArenas() == 0 then
        complain('Config.Arenas has no enabled arena -- no match can be created.')
    end
    if #Arena.GetEnabledModes() == 0 then
        complain('Config.Modes has no enabled mode -- no match can be created.')
    end
    if #Arena.GetEnabledWeapons() == 0 and #(Config.Loadouts.alwaysGive or {}) == 0 then
        complain('Config.Loadouts has no enabled weapon and no alwaysGive entry -- players would spawn empty-handed.')
    end

    -- A weapon key used twice means one of the two is unreachable.
    local seenKeys = {}
    for _, weapon in ipairs(Config.Loadouts.weapons or {}) do
        if Arena.IsKey(weapon.key) then
            if seenKeys[weapon.key] then
                complain(('Config.Loadouts.weapons has two entries with key "%s" -- only the first is reachable.'):format(weapon.key))
            end
            seenKeys[weapon.key] = true
        else
            complain('Config.Loadouts.weapons has an entry with no key.')
        end

        local ammo = weapon.ammo
        if type(ammo) == 'table' then
            local maximum = Arena.ToInt(ammo.max)
            for _, option in ipairs(Arena.GetAmmoOptions(weapon)) do
                if maximum and option > maximum then
                    complain(('Config.Loadouts.weapons["%s"] offers %d ammo but caps at %d -- that option can never be granted.')
                        :format(tostring(weapon.key), option, maximum))
                end
            end
        end
    end

    -- Every arena needs somewhere to put people.
    for _, entry in ipairs(Arena.GetEnabledArenas()) do
        local arena = Arena.GetArenaByKey(entry.key)
        if type(arena.spawns) ~= 'table' or #arena.spawns == 0 then
            complain(('Config.Arenas["%s"] has no spawns -- players would have nowhere to land.'):format(entry.key))
        end
    end

    -- A team mode is enabled but no team is.
    for _, mode in ipairs(Arena.GetEnabledModes()) do
        if mode.teams and #Arena.GetEnabledTeams() < 2 then
            complain(('Config.Modes["%s"] is a team mode but fewer than two teams are enabled.'):format(mode.key))
        end
        if mode.key == 'gungame' then
            local ladder = (Config.Modes[mode.key] or {}).gunGameLadder
            if type(ladder) ~= 'table' or #ladder == 0 then
                complain('Config.Modes["gungame"] is enabled but its gunGameLadder is empty.')
            end
        end
    end

    -- Betting numbers that cannot be satisfied.
    if Config.Betting.enabled == true then
        local fee = Config.Betting.entryFee or {}
        if fee.enabled == true then
            local minimum = Arena.ToInt(fee.min) or 0
            local maximum = Arena.ToInt(fee.max) or 0
            if maximum < minimum then
                complain('Config.Betting.entryFee.max is below its min -- no entry fee would be accepted.')
            end
            local default = Arena.ToInt(fee.default) or 0
            if default < minimum or default > maximum then
                complain('Config.Betting.entryFee.default sits outside min/max -- it will be clamped.')
            end
        end
        local percent = Arena.ToInt(Config.Betting.houseCutPercent) or 0
        if percent < 0 or percent > 100 then
            complain('Config.Betting.houseCutPercent must be between 0 and 100.')
        end
    end

    local lives = Arena.ToInt(Config.Match.lives) or 1
    if lives < 1 then
        complain('Config.Match.lives must be at least 1.')
    end

    return problems
end

--- Prints whatever ValidateConfig found. Called once from each realm's own
--- start-up so an operator sees the same list in the console whether the
--- problem would have shown up client-side or server-side.
function Arena.ReportConfigProblems()
    local problems = Arena.ValidateConfig()
    for _, problem in ipairs(problems) do
        warn('CONFIG: ' .. problem)
    end
    if #problems > 0 then
        warn(('CONFIG: %d problem(s) above. The resource is still running -- these are warnings, not failures.'):format(#problems))
    end
end
