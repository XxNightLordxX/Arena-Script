-- Crimson Arena: the rules both sides agree on. Modes, arenas, sums.

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
    it means this file can be loaded under plain lua5.4 and every rule
    exercised directly, and it means neither realm can quietly grow a
    dependency on the other's runtime. Keep it that way -- one native in
    here and the whole file becomes untestable outside a running server.

    WHO TRUSTS WHOM: the client calls into this file to BUILD the panel.
    The server calls into the same functions to CHECK what comes back. The
    client's copy is a convenience; the server's copy is the authority.
    Nothing here reads player input without validating it, because on the
    server side every argument arrived over the network.
]]

Arena = {}

local function warn(message)
    print(('[crimson_arena] %s'):format(message))
end

function Arena.ToInt(value)
    local number = tonumber(value)
    if not number or number ~= number then return nil end          -- nil or NaN
    if number == math.huge or number == -math.huge then return nil end
    return math.floor(number)
end

function Arena.ClampInt(value, minimum, maximum)
    local number = Arena.ToInt(value)
    if not number then return nil end
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

function Arena.IsKey(value)
    return type(value) == 'string' and value ~= ''
end

--- Whether a value is shaped like a coordinate this resource can read.
---
--- THE LIST OF TYPES IS THE WHOLE POINT, and leaving vectors off it is a
--- defect this codebase shipped four times over.
---
--- In the CitizenFX Lua runtime a vector is its OWN type: `type(v)` answers
--- 'vector3', never 'table' and never 'userdata'. config.lua writes every
--- coordinate as one, and GetEntityCoords and GetModelDimensions both return
--- them. So a guard that asks only for 'table' says NO to every real
--- coordinate on a real server -- and YES to every one in this suite, where
--- the stand-in vector is a table.
---
--- It never shows up as an error, which is what makes it expensive: a
--- rejected coordinate falls back, and every fallback here is silent and
--- plausible. The sky arena's floor was tiled on the 10m guess instead of
--- the measured 40m prop for exactly this reason -- eighty-one blocks
--- overlapping by thirty metres each where the design lays nine -- and the
--- respawn's "as far from the nearest opponent as the area allows" scored
--- every candidate against an empty threat list.
--- @param value any
--- @return boolean
function Arena.IsPoint(value)
    local kind = type(value)
    return kind == 'table' or kind == 'userdata'
        or kind == 'vector2' or kind == 'vector3' or kind == 'vector4'
end

local COVER_CLEARANCE = 7.0

local DEFAULT_MAGAZINE = 30

--- WHAT EVERY FIGHTER STARTS EVERY LIFE ON, and deliberately not a setting.
---
--- These used to be `Config.Loadouts.health` and a `Config.Loadouts.armor`
--- block with its own `allowChoose`, `options`, `default` and `max` -- four
--- keys deciding a thing that should not have been decidable. A round where
--- one player opened on a full plate and another on none because of a
--- picker, or because an operator lowered a default once and forgot, is not
--- a fair round; and a client sending its own armour value was a client
--- choosing how hard it was to kill.
---
--- 200 is a stock GTA full health bar and 100 a full plate. Whatever state a
--- player walked up to the arena in, and whatever their loadout says, a
--- round starts even. Their real health and armour are captured on the way
--- in and handed back on the way out.
local FULL_HEALTH = 200
local FULL_ARMOR = 100

function Arena.CoverClearance(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    local cover = type(arena) == 'table' and arena.cover or nil
    local configured = type(cover) == 'table' and tonumber(cover.clearance) or nil
    if configured and configured >= 0 then return configured end
    return COVER_CLEARANCE
end

function Arena.TangentHeading(dx, dy, longIsX)
    local x, y = tonumber(dx) or 0.0, tonumber(dy) or 0.0

    if x == 0.0 and y == 0.0 then return 0.0 end

    local phi = math.deg(math.atan(y, x))
    local heading
    if longIsX == false then
        heading = phi
    else
        heading = phi + 90.0
    end

    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    if heading >= 360.0 then heading = 0.0 end
    return heading
end

local function sizeFactor(factor)
    local value = tonumber(factor) or 1.0
    if value < 1.0 then return 1.0 end
    return value
end

function Arena.Count(tbl)
    if type(tbl) ~= 'table' then return 0 end
    local total = 0
    for _ in pairs(tbl) do total = total + 1 end
    return total
end

function Arena.GetEnabledWeapons()
    local out = {}
    for _, weapon in ipairs(Config.Loadouts.weapons or {}) do
        if weapon.enabled ~= false and Arena.IsKey(weapon.key) and Arena.IsKey(weapon.weapon) then
            out[#out + 1] = weapon
        end
    end
    return out
end

--- key -> entry, for the catalogue table it was built from.
---
--- MEMOISED, AND THE MEMO CANNOT BE TRUSTED ON ITS OWN. There is no config
--- reload in this resource -- Config is built once by config.lua and
--- config.weapons.lua at load -- but "there is no reloader today" is not a
--- thing to build a cache on, and the suites that exercise this file DO edit
--- the catalogue in place between calls: a spec that switches every weapon
--- off, or renames one entry's key, changes the answer without changing the
--- table it lives in. So the identity of the catalogue table is only enough
--- to say the index is worth LOOKING in; the entry it hands back is re-checked
--- against the live fields before it is returned, and a miss rebuilds and
--- looks again rather than reporting nothing.
---
--- The rebuild-on-miss is why this is never wrong and never slower than what
--- it replaced: a miss costs exactly the one full scan the old code did on
--- EVERY call, and a hit costs a hash lookup and three field reads.
local weaponIndexSource, weaponIndex = nil, nil

local function buildWeaponIndex(catalogue)
    local index = {}
    for _, weapon in ipairs(catalogue) do
        if weapon.enabled ~= false and Arena.IsKey(weapon.key) and Arena.IsKey(weapon.weapon)
            and index[weapon.key] == nil                  -- first entry wins, as the scan did
        then
            index[weapon.key] = weapon
        end
    end
    weaponIndexSource, weaponIndex = catalogue, index
    return index
end

--- The one weapon with this key, or nil. Returns nil for a disabled weapon
--- as well as an unknown one -- callers must not be able to tell the
--- difference, or `enabled = false` would only be a UI hint.
--- @param key any
--- @return table|nil
function Arena.GetWeaponByKey(key)
    if not Arena.IsKey(key) then return nil end

    -- DO NOT write `Config.Loadouts.weapons or {}` here, however much it
    -- looks like every other read of this field in the file. `or {}` builds a
    -- FRESH TABLE on each call whenever the catalogue is missing, and a fresh
    -- table never matches the memo -- so the guard below would rebuild the
    -- index on every single lookup, for ever, which is the cost this whole
    -- thing exists to remove.
    local catalogue = Config.Loadouts.weapons
    if type(catalogue) ~= 'table' then return nil end

    local index = (weaponIndexSource == catalogue and weaponIndex)
        or buildWeaponIndex(catalogue)

    local weapon = index[key]
    if weapon ~= nil and weapon.key == key and weapon.enabled ~= false
        and Arena.IsKey(weapon.weapon)
    then
        return weapon
    end

    -- Either a genuine miss, or an entry edited under the memo -- switched
    -- off, or its key moved to another block. Both are answered the same way.
    return buildWeaponIndex(catalogue)[key]
end

function Arena.GetEnabledTeams()
    local out = {}
    for key, team in pairs(Config.Teams.list or {}) do
        if team.enabled ~= false then
            out[#out + 1] = {
                key = key,
                label = team.label or key,
                color = team.color,
                blipColor = team.blipColor,
                order = Arena.ToInt(team.order) or 999,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)
    return out
end

function Arena.TeamIndex(teamKey)
    if not Arena.IsKey(teamKey) then return nil end
    for index, team in ipairs(Arena.GetEnabledTeams()) do
        if team.key == teamKey then return index end
    end
    return nil
end

function Arena.GetTeamByKey(key)
    if not Arena.IsKey(key) then return nil end
    for _, team in ipairs(Arena.GetEnabledTeams()) do
        if team.key == key then return team end
    end
    return nil
end

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
    -- COMPARED AS TEXT, BECAUSE THE KEY IS WHATEVER AN OPERATOR TYPED.
    -- `['pier']` is a string and `[3]` is a number, and Lua CANNOT order one
    -- against the other -- `a.key < b.key` raises "attempt to compare string
    -- with number" and takes the whole sort with it. This runs at start-up
    -- in both realms, inside Arena.ValidateConfig and inside the client
    -- thread that builds the lobby ped, so one mistyped bracket stopped the
    -- resource booting AND left no way into the arena. DO NOT put the bare
    -- comparison back: mixing the two orderings per pair is worse, because
    -- 2, 10 and '5' then have no consistent order and table.sort rejects it.
    table.sort(out, function(a, b) return tostring(a.key) < tostring(b.key) end)
    return out
end

function Arena.GetArenaByKey(key)
    if not Arena.IsKey(key) then return nil end
    local arena = (Config.Arenas or {})[key]
    if not arena or arena.enabled == false then return nil end
    return arena
end

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
                roundTimeSeconds = Arena.RoundSecondsFor(key),
                tiers = (function()
                    if not Arena.PlaysLadder(key) then return nil end
                    return #Arena.LadderTiersFor(key)
                end)(),
                tierClasses = (function()
                    local classes = Arena.GunGameClasses(key)
                    if #classes == 0 then return nil end
                    local rows = {}
                    for _, class in ipairs(classes) do
                        rows[#rows + 1] = {
                            key = class.key,
                            label = class.label,
                            tiers = class.tiers,
                            maxTiers = class.maxTiers,
                        }
                    end
                    return rows
                end)(),
                -- WHAT EVERYBODY IS HANDED, for the panel to say out loud on
                -- a screen it has just greyed out. Labels and counts only --
                -- the ox_inventory item NAME is deliberately not sent, the
                -- same rule Arena.ResolveSupplies follows: the key comes off
                -- the wire, the item name never does.
                startingKit = (function()
                    local kit = Arena.StartingKitFor(key)
                    if kit == nil then return nil end
                    local issued = {}
                    for _, supply in ipairs(kit) do
                        issued[#issued + 1] = { label = supply.label, count = supply.count }
                    end
                    return issued
                end)(),
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

local LADDER_MINIMUM = 2

function Arena.PlaysLadder(modeKey)
    return #Arena.LadderTiersFor(modeKey) >= LADDER_MINIMUM
end

function Arena.GunGameClasses(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    local configured = mode and mode.gunGameClasses
    if type(configured) ~= 'table' then return {} end

    local out = {}
    for _, class in ipairs(configured) do
        if type(class) == 'table' and Arena.IsKey(class.key) then
            local playable = {}
            for _, key in ipairs(type(class.weapons) == 'table' and class.weapons or {}) do
                local weapon = Arena.GetWeaponByKey(key)
                if weapon then playable[#playable + 1] = weapon end
            end

            if #playable > 0 then
                local ceiling = #playable
                local wanted = Arena.ToInt(class.tiers)
                if wanted == nil or wanted < 0 then wanted = 0 end

                out[#out + 1] = {
                    key = class.key,
                    label = class.label or class.key,
                    weapons = playable,
                    tiers = math.min(wanted, ceiling),
                    maxTiers = ceiling,
                }
            end
        end
    end
    return out
end

local function splitIntoRungs(weapons, count)
    local rungs = {}
    if count <= 0 or #weapons == 0 then return rungs end

    local size = math.floor(#weapons / count)
    local extra = #weapons % count

    local at = 1
    for index = 1, count do
        local take = size + (index <= extra and 1 or 0)
        local rung = {}
        for _ = 1, take do
            rung[#rung + 1] = weapons[at]
            at = at + 1
        end
        if #rung > 0 then rungs[#rungs + 1] = rung end
    end
    return rungs
end

function Arena.ResolveTierPlan(modeKey, requested)
    if requested == nil then return nil, nil end
    if type(requested) ~= 'table' then return nil, 'error.invalid_request' end

    local classes = Arena.GunGameClasses(modeKey)
    if #classes == 0 then return nil, nil end

    local plan, total = {}, 0
    for _, class in ipairs(classes) do
        local asked = requested[class.key]
        if asked ~= nil then
            local count = Arena.ToInt(asked)
            if count == nil or count < 0 or count > class.maxTiers then
                return nil, 'error.tier_count_out_of_range'
            end
            plan[class.key] = count
            total = total + count
        else
            total = total + class.tiers
        end
    end

    if total < LADDER_MINIMUM then return nil, 'error.ladder_too_short' end

    return plan, nil
end

function Arena.LadderTiersFor(modeKey, plan)
    local classes = Arena.GunGameClasses(modeKey)

    if #classes == 0 then
        local mode = Arena.GetModeByKey(modeKey)
        local configured = mode and mode.gunGameTiers
        if type(configured) ~= 'table' then return {} end

        local tiers = {}
        for _, pool in ipairs(configured) do
            local keys = type(pool) == 'table' and pool or { pool }
            local playable = {}
            for _, key in ipairs(keys) do
                local weapon = Arena.GetWeaponByKey(key)
                if weapon then playable[#playable + 1] = weapon end
            end
            if #playable > 0 then tiers[#tiers + 1] = playable end
        end
        return tiers
    end

    local tiers = {}
    for _, class in ipairs(classes) do
        local count = class.tiers
        if type(plan) == 'table' and plan[class.key] ~= nil then
            count = math.max(0, math.min(Arena.ToInt(plan[class.key]) or 0, class.maxTiers))
        end

        for _, rung in ipairs(splitIntoRungs(class.weapons, count)) do
            tiers[#tiers + 1] = rung
        end
    end
    return tiers
end

function Arena.RoundSecondsFor(modeKey, chosen)
    local picked = Arena.ToInt(chosen)
    if picked and picked > 0 then return picked end

    local mode = Arena.GetModeByKey(modeKey)
    local own = mode and Arena.ToInt(mode.roundTimeSeconds)
    return math.max(0, own or Arena.RoundTimeDefault())
end

--- How far apart two players may be for one to have killed the other, in
--- the arena the fight is actually being held in.
---
--- THE SPAN OF THE ARENA, NOT A FLAT NUMBER, and the flat number is what
--- made this a bug rather than a guard. Config.Match.maxKillDistance ships
--- at 150 against a comment claiming the shipped arenas were smaller than
--- that; they are not. The Trailer Park's boundary is a hundred-metre
--- RADIUS -- two hundred across, and 270 at the size it grows to for twenty
--- players -- and the skydome's is 110. Two fighters at opposite edges of
--- the arena they were put in were fifty metres or more over the ceiling, so
--- their kills were refused: no credit on the scoreboard, no tier on the
--- ladder, nothing towards the pot. It took the LONG shots, which is to say
--- the best ones, and left the point-blank kills alone.
---
--- SO THE ARENA RAISES IT AND NEVER LOWERS IT. The operator's number is a
--- floor -- an operator who wants a bigger allowance than the fence still
--- gets it, and an arena with no boundary at all falls back to it whole.
---
--- GROWN WITH THE ROSTER, like the fence and the floor, out of the same
--- Arena.SizeFactor the boundary payload uses. A ceiling that did not grow
--- would start refusing kills again the moment an arena did.
---
--- THE ARENA'S OWN DIAMETER, and the operator's number as a floor under it.
--- Two points in a circle are at most a diameter apart, so that is the
--- longest shot the ground allows; anything past it is two people who are not
--- in the same fight. There is no margin on top, and there used to be: read
--- the body for why a quarter of the radius was taken back off.
function Arena.KillCeilingFor(arenaKey, factor)
    local configured = math.max(0.0, tonumber((Config.Match or {}).maxKillDistance) or 0.0)
    if configured <= 0 then return 0.0 end

    local boundary = Arena.BoundaryOf(Arena.GetArenaByKey(arenaKey))
    local radius = boundary and tonumber(boundary.radius) or nil
    if not radius or radius <= 0 then return configured end

    local grown = radius * math.max(1.0, tonumber(factor) or 1.0)
    return math.max(configured, grown * 2.0)
end

local WIN_CONDITIONS = { 'last_standing', 'most_kills', 'score_limit' }

function Arena.WinConditions()
    local out = {}
    for _, key in ipairs(WIN_CONDITIONS) do out[#out + 1] = key end
    return out
end

local function isWinCondition(value)
    if not Arena.IsKey(value) then return false end
    for _, key in ipairs(WIN_CONDITIONS) do
        if key == value then return true end
    end
    return false
end

function Arena.WinConditionDefault()
    local setting = (Config.Match or {}).winCondition

    if type(setting) == 'table' then
        if isWinCondition(setting.default) then return setting.default end
        return WIN_CONDITIONS[1]
    end

    if isWinCondition(setting) then return setting end
    return WIN_CONDITIONS[1]
end

function Arena.WinConditionChoice()
    local setting = (Config.Match or {}).winCondition
    if type(setting) ~= 'table' or setting.allowChoose ~= true then return nil end
    return Arena.WinConditions()
end

function Arena.ResolveWinCondition(requested)
    if requested == nil or requested == '' then return '', nil end

    if not Arena.WinConditionChoice() then return '', nil end

    if not isWinCondition(requested) then return nil, 'error.win_condition_unavailable' end
    return requested, nil
end

function Arena.WinConditionFor(chosen)
    if isWinCondition(chosen) then return chosen end
    return Arena.WinConditionDefault()
end

function Arena.ScoreLimitDefault()
    local setting = (Config.Match or {}).scoreLimit

    if type(setting) ~= 'table' then
        return math.max(1, Arena.ToInt(setting) or 1)
    end

    local minimum = math.max(1, Arena.ToInt(setting.min) or 1)
    local maximum = math.max(minimum, Arena.ToInt(setting.max) or minimum)
    return Arena.ClampInt(setting.default, minimum, maximum) or minimum
end

function Arena.ScoreLimitChoice()
    local setting = (Config.Match or {}).scoreLimit
    if type(setting) ~= 'table' or setting.allowChoose ~= true then return nil end

    local minimum = math.max(1, Arena.ToInt(setting.min) or 1)
    local maximum = math.max(minimum, Arena.ToInt(setting.max) or minimum)
    if maximum <= minimum then return nil end
    return { min = minimum, max = maximum }
end

function Arena.ResolveScoreLimit(requested)
    local band = Arena.ScoreLimitChoice()
    if not band then return 0, nil end

    local wanted = Arena.ToInt(requested)
    if not wanted or wanted <= 0 then return 0, nil end
    if wanted < band.min or wanted > band.max then return nil, 'error.score_limit_out_of_range' end
    return wanted, nil
end

function Arena.ScoreLimitFor(chosen)
    local picked = Arena.ToInt(chosen)
    if picked and picked > 0 then return picked end
    return Arena.ScoreLimitDefault()
end

--- The win conditions under which a death costs nothing.
---
--- A SCORE LIMIT DOES NOT SPEND LIVES, at the operator's own instruction, and
--- the reason it cannot is arithmetic rather than taste: the round ends when
--- somebody reaches the limit, and a roster that can be eliminated will run
--- out of players first on any limit worth setting. Three lives and a limit
--- of 25 means the round is decided by last-man-standing every single time
--- and the number nobody reached was decorative.
---
--- MOST KILLS IS THE SAME ARITHMETIC, and it shipped without noticing.
--- IN A PLAYER'S WORDS: "on win condition it should not have a lives for
--- most kills till the clock runs out". The rule is "whoever has the most
--- kills when the clock stops" -- so the clock is the only thing that may
--- end it. Give it lives and the round ends the moment one player or one
--- side runs out of them, under `match.ended_last_standing`, with the clock
--- still running and the kill count never consulted. A host who picked
--- "most kills when the clock runs out" got last-man-standing wearing its
--- name, every single time.
---
--- A LIST RATHER THAN A COMPARISON. `~= 'score_limit'` was the old test, and
--- it silently answered "spends lives" for anything new -- which is how most
--- kills came to be in this state. A condition added here has to be thought
--- about.
local WIN_CONDITIONS_WITHOUT_LIVES = {
    score_limit = true,
    most_kills = true,
}

function Arena.WinConditionSpendsLives(condition)
    return WIN_CONDITIONS_WITHOUT_LIVES[Arena.WinConditionFor(condition)] ~= true
end

function Arena.WinConditionNeedsClock(condition)
    return Arena.WinConditionFor(condition) == 'most_kills'
end

function Arena.KillAmmoFor(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    if type(mode) ~= 'table' then return nil end

    local wanted = Arena.ToInt(mode.killAmmo)
    if not wanted or wanted <= 0 then return nil end
    return wanted
end

function Arena.TierAmmoFor(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    if type(mode) ~= 'table' then return nil end

    local wanted = Arena.ToInt(mode.tierAmmo)
    if not wanted or wanted <= 0 then return nil end
    return wanted
end

function Arena.RoundTimeDefault()
    local block = (Config.Match or {}).roundTimeSeconds
    if type(block) ~= 'table' then return math.max(0, Arena.ToInt(block) or 0) end

    local minimum = math.max(1, Arena.ToInt(block.min) or 1)
    local maximum = math.max(minimum, Arena.ToInt(block.max) or minimum)
    return Arena.ClampInt(block.default, minimum, maximum) or minimum
end

function Arena.RoundTimeChoice()
    local block = (Config.Match or {}).roundTimeSeconds
    if type(block) ~= 'table' or block.allowChoose ~= true then return nil end

    local minimum = math.max(1, Arena.ToInt(block.min) or 1)
    return { min = minimum, max = math.max(minimum, Arena.ToInt(block.max) or minimum) }
end

function Arena.ResolveRoundTime(requested)
    local choice = Arena.RoundTimeChoice()
    if not choice then return 0, nil end

    local wanted = Arena.ToInt(requested)
    if not wanted then return 0, nil end
    if wanted < choice.min or wanted > choice.max then
        return nil, 'error.round_time_out_of_range'
    end
    return wanted, nil
end

function Arena.GetModeByKey(key)
    if not Arena.IsKey(key) then return nil end
    local mode = (Config.Modes or {})[key]
    if not mode or mode.enabled == false then return nil end
    return mode
end

function Arena.ModeUsesTeams(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    return mode ~= nil and mode.teams == true
end

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

function Arena.AllowsCustomAmmo(weapon)
    if type(weapon) == 'table' and weapon.allowCustomAmmo ~= nil then
        return weapon.allowCustomAmmo == true
    end
    return Config.Loadouts.allowCustomAmmo == true
end

function Arena.ResolveAmmo(weapon, requested)
    local ammo = weapon and weapon.ammo or nil
    if type(ammo) ~= 'table' then return 0 end

    local maximum = Arena.ToInt(ammo.max) or Arena.ToInt(ammo.default) or 0
    local default = Arena.ClampInt(ammo.default, 0, maximum) or 0

    local wanted = Arena.ToInt(requested)
    if not wanted or wanted < 0 then return default end

    local options = Arena.GetAmmoOptions(weapon)
    if #options > 0 then
        for _, option in ipairs(options) do
            if option == wanted then
                return Arena.ClampInt(option, 0, maximum) or default
            end
        end

        if Arena.AllowsCustomAmmo(weapon) then
            return Arena.ClampInt(wanted, 0, maximum) or default
        end
        return default              -- rule 1: off-list is refused, not rounded
    end

    return Arena.ClampInt(wanted, 0, maximum) or default
end

function Arena.IsMeleeWeapon(weapon)
    if type(weapon) ~= 'table' then return false end
    if weapon.category == 'melee' then return true end

    local ammo = weapon.ammo
    local maximum = type(ammo) == 'table' and (Arena.ToInt(ammo.max) or 0) or 0
    return maximum <= 1
end

function Arena.GetAmmoTypes(weapon)
    if type(weapon) ~= 'table' then return {} end

    if weapon.ammoTypes == false then return {} end

    local list = weapon.ammoTypes
    if type(list) ~= 'table' then
        if Arena.IsMeleeWeapon(weapon) then return {} end

        list = Config.Loadouts.defaultAmmoTypes
    end
    if type(list) ~= 'table' then return {} end

    local out = {}
    for _, entry in ipairs(list) do
        if type(entry) == 'table' and entry.enabled ~= false and Arena.IsKey(entry.key) then
            out[#out + 1] = {
                key = entry.key,
                label = entry.label or entry.key,
                component = Arena.IsKey(entry.component) and entry.component or nil,
                item = Arena.IsKey(entry.item) and entry.item or nil,
            }
        end
    end
    return out
end

function Arena.AllAmmoItems()
    local items = {}

    local function collect(list)
        if type(list) ~= 'table' then return end
        for _, entry in ipairs(list) do
            if type(entry) == 'table' and Arena.IsKey(entry.item) then
                items[entry.item] = true
            end
        end
    end

    collect(Config.Loadouts.defaultAmmoTypes)
    -- Deliberately the RAW list rather than GetEnabledWeapons: a disabled
    -- weapon's ammo item is still an item a player could be holding.
    for _, weapon in ipairs(Config.Loadouts.weapons or {}) do
        collect(weapon.ammoTypes)
    end

    return items
end

--- EVERY ITEM NAME THIS ARENA CAN PUT IN SOMEBODY'S HANDS: the weapons, the
--- ammunition for them, and the supplies.
---
--- WHAT IT IS FOR. The door destroys whatever a fighter is carrying on the
--- way out, because at that moment everything in their pockets came from the
--- arena -- their own is in the stash. That is the promise which makes a
--- round free to enter, and it is the one an operator must not be able to
--- switch off by accident.
---
--- `Config.Loadouts.inventory.neverStash` is a list of things the door
--- leaves in a fighter's pockets, and naming an item there also protects it
--- from that clear. Naming an ARENA item there would therefore hand it over
--- for good: kept at the exit, and the arena no longer even recording that
--- it issued one. Two hundred rounds a round, for ever, from one line of
--- config. This is the list that says which names cannot be handed over.
---
--- THE RAW WEAPON LIST, not the enabled one, for the same reason
--- AllAmmoItems uses it: a weapon an operator switched off yesterday is
--- still a weapon somebody could be holding today.
--- @return table<string, boolean>
function Arena.AllIssuedItems()
    local items = Arena.AllAmmoItems()

    for _, weapon in ipairs((Config.Loadouts or {}).weapons or {}) do
        if type(weapon) == 'table' and Arena.IsKey(weapon.weapon) then
            items[weapon.weapon] = true
        end
    end

    local supplies = ((Config.Loadouts or {}).supplies or {}).items
    for _, entry in ipairs(type(supplies) == 'table' and supplies or {}) do
        if type(entry) == 'table' and Arena.IsKey(entry.item) then
            items[entry.item] = true
        end
    end

    return items
end

function Arena.ResolveAmmoType(weapon, requested)
    local types = Arena.GetAmmoTypes(weapon)
    if #types == 0 then return nil end

    local wantedDefault = weapon.defaultAmmoType or Config.Loadouts.defaultAmmoType
    local fallback = types[1]
    if Arena.IsKey(wantedDefault) then
        for _, entry in ipairs(types) do
            if entry.key == wantedDefault then
                fallback = entry
                break
            end
        end
    end

    if not Arena.IsKey(requested) then return fallback end

    for _, entry in ipairs(types) do
        if entry.key == requested then return entry end
    end
    return fallback
end

function Arena.MagazineFor(weapon, rounds)
    local total = math.max(0, Arena.ToInt(rounds) or 0)

    local explicit = Arena.ToInt(type(weapon) == 'table' and weapon.magazine or nil)
    if explicit and explicit > 0 then return math.min(explicit, total) end

    local ammo = type(weapon) == 'table' and weapon.ammo or nil
    local options = type(ammo) == 'table' and ammo.options or nil
    local smallest = nil
    for _, option in ipairs(type(options) == 'table' and options or {}) do
        local value = Arena.ToInt(option)
        if value and value > 0 and (smallest == nil or value < smallest) then
            smallest = value
        end
    end
    if smallest then return math.min(smallest, total) end

    local fallback = Arena.ToInt((Config.Loadouts.ammoItems or {}).defaultMagazine)
    if not fallback or fallback <= 0 then fallback = DEFAULT_MAGAZINE end
    return math.min(fallback, total)
end

--- What every fighter starts each life on: full health and a full plate.
---
--- CONSTANTS, NOT SETTINGS, and both realms read them from here so the panel
--- and the server can never disagree about how hard somebody is to kill.
--- @return integer health
--- @return integer armor
function Arena.StartingVitals()
    return FULL_HEALTH, FULL_ARMOR
end

-- ======================================================================
-- SUPPLIES -- what a player carries INTO the round on top of the kit
--
-- SEPARATE FROM THE STARTING ARMOUR, and the separation is the whole point.
-- The number above is what you are wearing when the countdown ends and it
-- is not negotiable. These are ITEMS in the inventory: a spare plate to put
-- on when the first one is gone, a bandage to patch up behind cover. What a
-- player picks here changes what they carry, never what they start on.
--
-- SHAPED LIKE THE WEAPON CATALOGUE on purpose, down to the key/label/item
-- triple and the `enabled` switch, because an operator who has already
-- edited one list should not have to learn a second grammar to edit this
-- one.
-- ======================================================================

local function suppliesConfig()
    return (Config.Loadouts or {}).supplies or {}
end

function Arena.GetEnabledSupplies()
    local out = {}
    if suppliesConfig().enabled ~= true then return out end

    for _, entry in ipairs(suppliesConfig().items or {}) do
        if type(entry) == 'table' and entry.enabled ~= false and Arena.IsKey(entry.key) then
            out[#out + 1] = entry
        end
    end
    return out
end

function Arena.SupplyMax(supply)
    if type(supply) ~= 'table' then return 0 end
    return math.max(0, Arena.ToInt(supply.max) or 0)
end

function Arena.SupplyTotalCap()
    return math.max(0, Arena.ToInt(suppliesConfig().totalItems) or 0)
end

--- One enabled supply by its key, or nil.
---
--- THROUGH Arena.GetEnabledSupplies rather than straight off the config
--- table, so a supply an operator switched off is invisible here for the
--- same reason it is invisible in the picker: one answer to "which supplies
--- exist", not two that can disagree.
--- @param key any
--- @return table|nil supply -- the config entry, `item` and all
function Arena.SupplyByKey(key)
    if not Arena.IsKey(key) then return nil end
    for _, supply in ipairs(Arena.GetEnabledSupplies()) do
        if supply.key == key then return supply end
    end
    return nil
end

--- The supplies a MODE hands everybody at the start of a round, whatever
--- they picked -- or nil when this mode has no opinion.
---
--- NOT Arena.ResolveSupplies, AND THE DIFFERENCE MATTERS TWICE. That
--- function judges a request a PLAYER made: it hands back the operator's
--- defaults when `allowChoose` is off, because a player who may not choose
--- does not get to. Neither reading is right for a kit nobody chose --
--- `allowChoose` is a rule about the picker, and this is the mode saying
--- what it issues. So the list is built here, from the same catalogue and
--- against the same per-supply `max`.
---
--- THE THREE ANSWERS ARE DIFFERENT ON PURPOSE:
---   nil -- this mode names no kit. The caller falls back to whatever the
---          rest of the resource would have given the player. A config that
---          predates the field lands here, which is why it is not `{}`.
---   {}  -- a kit that is explicitly empty, or a server with
---          Config.Loadouts.supplies switched off. Nobody carries anything.
---   a list -- what everybody carries, in config order so two players and
---          two rounds get the same list in the same order.
---
--- THE SERVER-WIDE SWITCH OUTRANKS THE MODE. `supplies.enabled = false` is
--- an operator saying this server does not do supplies at all, and a mode
--- talking them back into it would make that switch a suggestion.
--- @param modeKey any
--- @return table[]|nil supplies -- { { key, label, item, count }, ... }
function Arena.StartingKitFor(modeKey)
    local mode = Arena.GetModeByKey(modeKey)
    local kit = mode and mode.startingKit
    if type(kit) ~= 'table' then return nil end

    local wanted = {}
    for _, entry in ipairs(kit) do
        if type(entry) == 'table' and Arena.IsKey(entry.key) then
            wanted[entry.key] = Arena.ToInt(entry.count)
        end
    end

    local remaining = Arena.SupplyTotalCap()
    local capped = remaining > 0

    local out = {}
    for _, supply in ipairs(Arena.GetEnabledSupplies()) do
        local asked = wanted[supply.key]
        if asked ~= nil then
            local count = Arena.ClampInt(asked, 0, Arena.SupplyMax(supply)) or 0
            if capped and count > remaining then count = remaining end
            if count > 0 and Arena.IsKey(supply.item) then
                if capped then remaining = remaining - count end
                out[#out + 1] = {
                    key = supply.key,
                    label = supply.label or supply.key,
                    item = supply.item,
                    count = count,
                }
            end
        end
    end
    return out
end

--- Turns whatever a client asked to carry into a list the server is willing
--- to hand over.
---
--- THE KEY COMES OFF THE WIRE; THE ITEM NAME NEVER DOES. Exactly the rule
--- Arena.ResolveAmmoType follows, and for the same reason: an item name
--- taken from a client is a client choosing what to be given, and the answer
--- to "which item is a bandage" lives in config or nowhere.
---
--- THREE CAPS, and each of them exists because one of the others does not
--- catch what it catches. A per-item `max` stops one line asking for a
--- thousand plates. A `totalItems` cap stops twenty different supplies each
--- asking for their own legal maximum. And the entry list itself is bounded
--- by the caller, because a request with ten thousand entries is a request
--- that costs the server the whole tick before any of these are consulted.
---
--- FAILS SOFT, like every other resolver here: an unknown key is dropped and
--- the rest of the list is honoured. A player who sends rubbish carries
--- nothing extra, not nothing at all.
--- @param requested any -- { { key = string, count = any }, ... }
--- @return table[] supplies -- { { key, label, item, count }, ... }
function Arena.ResolveSupplies(requested)
    local out = {}

    local config = suppliesConfig()

    local wanted = requested
    if config.allowChoose == false then wanted = nil end

    local asked = {}
    for _, entry in ipairs(type(wanted) == 'table' and wanted or {}) do
        if type(entry) == 'table' and Arena.IsKey(entry.key) then
            asked[entry.key] = Arena.ToInt(entry.count)
        end
    end

    local ceiling = Arena.SupplyTotalCap()
    local capped = ceiling > 0
    local remaining = ceiling

    for _, supply in ipairs(Arena.GetEnabledSupplies()) do
        local maximum = Arena.SupplyMax(supply)
        local fallback = Arena.ClampInt(supply.default, 0, maximum) or 0

        local count = fallback
        if wanted ~= nil and asked[supply.key] ~= nil then
            count = Arena.ClampInt(asked[supply.key], 0, maximum) or 0
        end

        if capped and count > remaining then count = remaining end

        if count > 0 and Arena.IsKey(supply.item) then
            if capped then remaining = remaining - count end
            out[#out + 1] = {
                key = supply.key,
                label = supply.label or supply.key,
                item = supply.item,
                count = count,
            }
        end
    end

    return out
end

--- What `Config.Loadouts.slots` reads as when the operator never wrote it,
--- or wrote something that is not a whole number.
---
--- TWO, because that is what an unwritten config hands out today: the two
--- keys this replaces each defaulted to one, so a player carried one firearm
--- and one blade. Deliberately NOT the shipped value -- if it were, changing
--- what ships would silently change what an operator who deleted the line
--- gets, and the two questions are different ones.
local DEFAULT_SLOTS = 2

--- How many weapons one player may carry, guns and blades together.
---
--- ONE READER FOR BOTH REALMS, like Arena.LoadoutChooser above it and for the
--- same reason: the resolver enforces this number and server/lobby.lua mirrors
--- it to the panel, and if those two coerce, default and clamp it separately
--- they will eventually disagree -- at which point the panel tells the player
--- they may take four and the server hands them three.
---
--- 0 IS NOT A MISSING ANSWER, it is "no limit", so it survives the fallback.
--- @return integer slots -- 0 means unlimited
function Arena.SlotsPerPlayer()
    local slots = Arena.ToInt((Config.Loadouts or {}).slots)
    if slots == nil or slots < 0 then return DEFAULT_SLOTS end
    return slots
end

--- One weapon of a loadout, built.
---
--- POLICY-FREE ON PURPOSE, and split out of Arena.ResolveLoadout for it.
--- Everything that decides WHETHER a player may have this weapon -- the
--- slots, allowFirearms, allowMelee, the distinct-ammo-type cap, the
--- duplicate check -- stays in that function, where a player's request is
--- being judged. This is only the shape of the answer.
---
--- WHICH MATTERS BECAUSE THERE IS A SECOND CALLER. The gun game's ladder is
--- the operator's own list, not a request to be judged: a melee tier must be
--- handed over on a server that does not let players PICK a blade, because
--- nobody picked it. It used to hand-build its entry to get past that, and
--- the hand-built one was missing `ammoTypeItem` -- so every ladder weapon
--- was issued as though ammo items were switched off, the whole pick sat in
--- the magazine and no loose rounds were ever handed over -- so nothing was
--- recorded as issued, and the exit had nothing to take back.
--- @param weapon table -- a catalogue entry
--- @param ammoType table|nil -- an Arena.ResolveAmmoType result, already chosen
--- @param ammo any -- rounds asked for, or nil for this weapon's own default
--- @return table entry
function Arena.ResolveWeaponEntry(weapon, ammoType, ammo)
    local components = {}
    for _, component in ipairs(type(weapon.components) == 'table' and weapon.components or {}) do
        components[#components + 1] = component
    end
    if ammoType and ammoType.component then
        components[#components + 1] = ammoType.component
    end

    return {
        key = weapon.key,
        weapon = weapon.weapon,
        label = weapon.label or weapon.key,
        ammo = Arena.ResolveAmmo(weapon, ammo),
        ammoType = ammoType and ammoType.key or nil,
        ammoTypeLabel = ammoType and ammoType.label or nil,
        ammoTypeItem = ammoType and ammoType.item or nil,
        components = components,
        tint = Arena.ToInt(weapon.tint) or 0,
    }
end

function Arena.ResolveLoadout(request)
    local rejected = {}
    local resolved = {}
    local seen = {}

    local slots = Arena.SlotsPerPlayer()

    local allowFirearms = Config.Loadouts.allowFirearms ~= false
    local allowMelee = Config.Loadouts.allowMelee ~= false

    local typeCap = Arena.ToInt(Config.Loadouts.ammoTypeSlots) or 0
    if typeCap < 0 then typeCap = 0 end

    local used = 0
    local typesTaken, distinctTypes = {}, 0

    local source = request
    local wanted = (type(source) == 'table' and type(source.weapons) == 'table') and source.weapons or {}

    -- WALKED TO THE END, NEVER BROKEN OUT OF, and that is a fix rather than
    -- a transcription. The two-pool version broke once BOTH allowances were
    -- spent, so everything after that point was dropped without being named
    -- and `rejected` came back short -- the panel could not say which weapon
    -- had not made it in. snapshotcontract_spec carried that as a recorded
    -- DEFECT. With one pool a break would drop everything after the pool
    -- filled, which is more of the request lost, not less. The request is
    -- capped at 32 entries long before it reaches here, so walking it is free.
    for _, entry in ipairs(wanted) do
        do
            local key = type(entry) == 'table' and entry.key or entry
            local weapon = Arena.GetWeaponByKey(key)

            if not weapon then
                rejected[#rejected + 1] = tostring(key)
            elseif seen[weapon.key] then
                rejected[#rejected + 1] = weapon.key
            elseif Arena.IsMeleeWeapon(weapon) and not allowMelee then
                rejected[#rejected + 1] = weapon.key
            elseif not Arena.IsMeleeWeapon(weapon) and not allowFirearms then
                rejected[#rejected + 1] = weapon.key
            elseif slots > 0 and used >= slots then
                rejected[#rejected + 1] = weapon.key
            else
                used = used + 1

                seen[weapon.key] = true
                local ammoType = Arena.ResolveAmmoType(weapon, type(entry) == 'table' and entry.ammoType or nil)

                if ammoType and typeCap > 0 and not typesTaken[ammoType.key] and distinctTypes >= typeCap then
                    ammoType = Arena.ResolveAmmoType(weapon, nil)
                end
                if ammoType and not typesTaken[ammoType.key] then
                    typesTaken[ammoType.key] = true
                    distinctTypes = distinctTypes + 1
                end

                resolved[#resolved + 1] = Arena.ResolveWeaponEntry(weapon, ammoType,
                    type(entry) == 'table' and entry.ammo or nil)
            end
        end
    end

    local health, armor = Arena.StartingVitals()
    return {
        weapons = resolved,
        armor = armor,
        health = health,
        supplies = Arena.ResolveSupplies(type(source) == 'table' and source.supplies or nil),
    }, rejected
end

--- Whether this player row is out of the round for good.
---
--- ONE COPY, because there were two answers to this question and only one of
--- them was being asked. server/lobby.lua had the rule and used it for the
--- `alive` field it ships in every snapshot; server/betting.lua's pickExists
--- -- the check that a bet names something that CAN still win -- never asked
--- it at all, and its own comment two lines above says "Backing an empty team
--- is not a bet, it is a donation."
---
--- An eliminated fighter deliberately KEEPS their row: the results board
--- ranks off it. So "is on the roster" and "can still win" are different
--- questions, and only one of them is about the roster.
--- @param row table|nil -- a match player record

--- The boundary block of an arena, when it is switched on -- nil otherwise.
---
--- ONE READING OF `enabled`, because there were two and they disagreed about
--- the case an operator is most likely to produce: a boundary block copied
--- from the template with the `enabled = true` line dropped.
---
---   server/lobby.lua   `~= false` -- the keep-out fence went UP
---   server/dispatch.lua `~= false` -- explosions and alerts were SUPPRESSED
---   server/match.lua    `== true`  -- no boundary was sent to the client,
---                                     so nobody was warned and nobody bled
---   shared/arena.lua    `== true`  -- the floor-containment check, whose
---                                     message ends "standing on it bleeds
---                                     you", did not run at all
---
--- One field, four call sites, two answers. What that produced was the worst
--- possible split: every non-participant teleported away from a circle four
--- times a second, and every fighter free to walk out of it and sit outside
--- until the clock ran down, on an arena whose validator had quietly stopped
--- checking that its ground was inside its own edge.
---
--- MISSING MEANS ON, which is the reading the two outward-facing guards
--- already had. An operator who writes a boundary with a radius in it has
--- said what they want; a block that silently does nothing is the worse
--- surprise, and `enabled = false` is still there to say so out loud. Both
--- shipped arenas set it explicitly, so nothing changes for them.
---
--- The two client-side reads are NOT call sites of this: they check the
--- payload server/match.lua builds, which sets `enabled = true` on every
--- boundary it sends and omits the block entirely otherwise.
--- @param arena table|nil -- a raw Config.Arenas entry
--- @return table|nil
function Arena.BoundaryOf(arena)
    if type(arena) ~= 'table' then return nil end
    local boundary = arena.boundary
    if type(boundary) ~= 'table' then return nil end
    if boundary.enabled == false then return nil end
    return boundary
end

function Arena.IsEliminated(row)
    if type(row) ~= 'table' then return false end
    return row.alive ~= true and (Arena.ToInt(row.lives) or 0) <= 0
end

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

function Arena.SuggestTeam(players, rng)
    local counts = Arena.CountTeams(players)
    local cap = Arena.ToInt(Config.Teams.maxTeamSize) or 0

    local tied, bestCount = {}, nil
    for _, team in ipairs(Arena.GetEnabledTeams()) do
        local count = counts[team.key] or 0
        local hasRoom = cap <= 0 or count < cap
        if hasRoom then
            if bestCount == nil or count < bestCount then
                tied, bestCount = { team.key }, count
            elseif count == bestCount then
                tied[#tied + 1] = team.key
            end
        end
    end

    if #tied == 0 then return nil end
    if #tied == 1 then return tied[1] end

    rng = rng or math.random

    local pick = math.floor(rng() * #tied) + 1
    if pick < 1 then pick = 1 end
    if pick > #tied then pick = #tied end
    return tied[pick]
end

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
        -- FLOORED AT ZERO, the same as the number server/lobby.lua puts on
        -- the wire for the panel. Read raw, a negative allowance is not a
        -- stricter rule but a broken one: `largest - smallest` is never
        -- below zero, so with -1 the comparison `0 > -1` is true and a
        -- PERFECTLY LEVEL roster is refused as unbalanced -- 1v1, 3v3, 5v5,
        -- every team match on the server, for ever, while free-for-all
        -- carries on working. And 0 is a plausible typo here: two lines
        -- below it in config.lua, `maxTeamSize = 0` means "no limit", so an
        -- operator reaching for "no limit" on this one has already been
        -- taught to try a number that is not a real allowance.
        --
        -- Clamped rather than complained about at the point of use, because
        -- the panel was ALREADY told 0 (lobby.lua clamps its snapshot) and a
        -- rule that disagrees with the screen is the actual defect: the host
        -- saw two level sides, no warning, a lit Start button, and a toast
        -- saying the sides were too lopsided. Arena.ValidateConfig names the
        -- typo separately, at boot, where an operator can act on it.
        local allowed = math.max(0, Arena.ToInt(Config.Teams.maxTeamSizeDifference) or 1)
        if smallest and largest and (largest - smallest) > allowed then
            return false, 'error.teams_unbalanced'
        end
    end

    return true, nil
end

function Arena.CanDamage(modeKey, attackerTeam, victimTeam)
    if not Arena.ModeUsesTeams(modeKey) then return true end
    if not Arena.IsKey(attackerTeam) or not Arena.IsKey(victimTeam) then return true end
    if attackerTeam ~= victimTeam then return true end
    return Config.Teams.friendlyFire == true
end

--- HOW FAR OFF ITS OWN FLOOR A SPAWN MAY SIT, in metres, on an arena that
--- carries one. Arena.ValidateConfig warns on exactly this band and shares
--- these two numbers with the guard below, so that what an operator is
--- warned about and what is corrected under them can NEVER drift apart.
---
--- A LITTLE ABOVE IS A CHOICE; A LOT ABOVE IS A TYPO. A spawn a step over
--- the surface is a raised platform somebody meant. One far above it is a
--- fall the moment the countdown ends -- and on the sky arena the boundary
--- is a 110m sphere around the floor, so it is also outside the world,
--- bleeding on the way down. There is no keypress that gets you back.
local SPAWN_BELOW_FLOOR = 0.5
local SPAWN_ABOVE_FLOOR = 5.0

--- Bring a spawn point back down to the floor its arena carries, or hand it
--- back untouched.
---
--- ONLY DOWNWARDS, AND ONLY FROM ABSURDLY HIGH. THIS IS NOT SYMMETRICAL AND
--- MUST NOT BE MADE SO. A spawn BELOW the surface is already handled where it
--- has to be, on the client: client/match.lua places an exact-Z arena at
--- `math.max(z, floorZ)` and its ground probe refuses any ground under
--- floorZ, so a low number is lifted at the moment of placement by the one
--- piece of code that can see the world. Clamping it up here as well would
--- change nothing a player experiences and would quietly delete the evidence
--- the operator is meant to act on -- tests/skyarena_spec.lua asserts the low
--- number survives this call for exactly that reason.
---
--- Nothing anywhere bounds it from ABOVE. `math.max` does not, the ground
--- probe cannot -- there is no ground -- and a mistyped 12010 for 1201 puts
--- every fighter ten kilometres up, frozen, and then unfreezes them.
---
--- ONLY AN ARENA WITH A PLATFORM HAS A FLOOR TO ARGUE WITH. On real ground
--- there is no configured surface to compare against, so a ground arena's
--- points come back exactly as the operator wrote them -- which is what
--- Arena.PickSpawn's callers and the suite both expect.
---
--- The point is REBUILT only when it actually has to move, so the ordinary
--- case still hands back the operator's own vector4 rather than a copy of it.
--- @param arenaKey any
--- @param point any
--- @param factor number|nil
--- @return any point
local function settleOnFloor(arenaKey, point, factor)
    if not Arena.IsPoint(point) then return point end

    local x, y, z = tonumber(point.x), tonumber(point.y), tonumber(point.z)
    if not x or not y or not z then return point end

    local platform = Arena.GetPlatform(arenaKey, factor)
    if not platform or z <= platform.z + SPAWN_ABOVE_FLOOR then return point end

    return { x = x, y = y, z = platform.z, w = tonumber(point.w) or 0.0 }
end

function Arena.PickSpawn(arenaKey, teamKey, index)
    local arena = Arena.GetArenaByKey(arenaKey)
    if not arena then return nil end

    local list
    if Arena.IsKey(teamKey) and type(arena.teamSpawns) == 'table' then
        local teamList = arena.teamSpawns[teamKey]
        if type(teamList) == 'table' and #teamList > 0 then list = teamList end
    end
    if not list then list = arena.spawns end
    if type(list) ~= 'table' or #list == 0 then return nil end

    local position = Arena.ToInt(index) or 1
    if position < 1 then position = 1 end
    return settleOnFloor(arenaKey, list[((position - 1) % #list) + 1])
end

function Arena.ModelChain(entry)
    if type(entry) ~= 'table' then return {} end

    local out, seen = {}, {}
    local function want(name)
        if Arena.IsKey(name) and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end

    want(entry.model)
    for _, name in ipairs(entry.models or {}) do want(name) end
    return out
end

function Arena.GetPlatform(arenaKey, factor)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return nil end

    local platform = arena.platform
    if type(platform) ~= 'table' or platform.enabled == false then return nil end

    local grow = sizeFactor(factor)

    local models = Arena.ModelChain(platform)
    if #models == 0 then return nil end

    local tileSize = tonumber(platform.tileSize) or 0
    local radius = tonumber(platform.radius) or 0
    if tileSize <= 0 or radius <= 0 then return nil end
    radius = radius * grow

    return {
        models = models,
        model = models[1],
        tileSize = tileSize,
        radius = radius,
        z = tonumber(platform.z) or 0.0,
        maxTiles = math.floor((tonumber(platform.maxTiles) or 0) * grow * grow),
    }
end

function Arena.PlatformTiles(platform, centreX, centreY, measured)
    if type(platform) ~= 'table' then return {} end

    local sizeX, sizeY, top
    if type(measured) == 'table' then
        sizeX, sizeY, top = tonumber(measured.x), tonumber(measured.y), tonumber(measured.top)
    else
        sizeX = tonumber(measured)
        sizeY = sizeX
    end
    if not sizeX or sizeX <= 0 then sizeX = platform.tileSize end
    if not sizeY or sizeY <= 0 then sizeY = platform.tileSize end
    if not sizeX or sizeX <= 0 or not sizeY or sizeY <= 0 then return {} end
    top = tonumber(top) or 0.0

    local reach = platform.radius
    if not reach or reach <= 0 then return {} end

    local z = platform.z - top

    local out = {}
    local stepsX = math.ceil((reach + sizeX * 0.5) / sizeX)
    local stepsY = math.ceil((reach + sizeY * 0.5) / sizeY)
    for ix = -stepsX, stepsX do
        for iy = -stepsY, stepsY do
            local x, y = ix * sizeX, iy * sizeY
            local nx = math.max(0.0, math.abs(x) - sizeX * 0.5)
            local ny = math.max(0.0, math.abs(y) - sizeY * 0.5)
            if math.sqrt(nx * nx + ny * ny) <= reach then
                out[#out + 1] = {
                    x = centreX + x,
                    y = centreY + y,
                    z = z,
                    distance = math.sqrt(x * x + y * y),
                }
            end
        end
    end

    local maxTiles = tonumber(platform.maxTiles) or 0
    if maxTiles > 0 and #out > maxTiles then
        table.sort(out, function(a, b)
            if a.distance ~= b.distance then return a.distance < b.distance end
            if a.x ~= b.x then return a.x < b.x end
            return a.y < b.y
        end)
        for i = #out, maxTiles + 1, -1 do out[i] = nil end
    end

    for _, tile in ipairs(out) do tile.distance = nil end
    return out
end

function Arena.GetCover(arenaKey, factor)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return {} end

    local cover = arena.cover
    if type(cover) ~= 'table' or cover.enabled == false then return {} end

    -- THE LAYOUT SCALES, THE PIECES DO NOT. Offsets are multiplied so a
    -- grown arena keeps the shape somebody laid out -- an outer ring on the
    -- rim, a pinwheel in the middle -- rather than the same huddle of
    -- barriers marooned in the centre of a much larger floor. The props
    -- themselves are a fixed size, so a bigger arena has proportionally more
    -- open ground, which is the right way round: more fighters need more
    -- room to move, not more walls.
    local grow = sizeFactor(factor)

    local out = {}
    for _, piece in ipairs(cover.pieces or {}) do
        local models = Arena.ModelChain(piece)
        if type(piece) == 'table' and #models > 0 then
            out[#out + 1] = {
                models = models,
                model = models[1],
                x = (tonumber(piece.x) or 0.0) * grow,
                y = (tonumber(piece.y) or 0.0) * grow,
                z = tonumber(piece.z) or 0.0,
                heading = tonumber(piece.heading) or 0.0,
                align = piece.align,
            }
        end
    end
    return out
end

--- EVERYTHING AN ARENA HAS TO BUILD, in world coordinates: the tiled floor
--- and the cover on top of it, as one list.
---
--- One list on purpose. The client spawns these and deletes them again, and
--- a floor that is torn down by one code path while the barriers standing on
--- it are torn down by another is two chances to leave something behind at a
--- thousand metres.
--- @param arenaKey any
--- @return table[] -- { { kind, model, x, y, z, heading }, ... }, absolute
--- @param measured table|number|nil -- the floor prop's real size, measured
---        by the client. See Arena.PlatformTiles.
function Arena.ArenaProps(arenaKey, measured, factor)
    local out = {}

    local area = Arena.GetSpawnArea(arenaKey, factor)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return out end

    local centre = area
    if not centre then
        local boundary = type(arena.boundary) == 'table' and arena.boundary.center or nil
        if not Arena.IsPoint(boundary) then return out end
        centre = { x = tonumber(boundary.x) or 0.0, y = tonumber(boundary.y) or 0.0,
                   z = tonumber(boundary.z) or 0.0 }
    end

    local platform = Arena.GetPlatform(arenaKey, factor)
    if platform then
        for _, tile in ipairs(Arena.PlatformTiles(platform, centre.x, centre.y, measured)) do
            out[#out + 1] = {
                kind = 'floor',
                models = platform.models,
                model = platform.model,
                x = tile.x, y = tile.y, z = tile.z,
                heading = 0.0,
            }
        end
    end

    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        out[#out + 1] = {
            kind = 'cover',
            models = piece.models,
            model = piece.model,
            x = centre.x + piece.x,
            y = centre.y + piece.y,
            z = centre.z + piece.z,
            heading = piece.heading,
            align = piece.align,
            offsetX = piece.x,
            offsetY = piece.y,
        }
    end

    return out
end

--- How far past the floor's own radius a sweep still counts a piece as this
--- arena's. Deliberately generous: a tile is kept whenever ANY part of it
--- reaches the platform radius, so the last ring hangs half a tile further
--- out and the corners half a diagonal further than that. Missing a stray by
--- a metre leaves standing exactly the prop this exists to find.
local SWEEP_MARGIN = 80.0

local SWEEP_HEIGHT = 60.0

--- EVERYTHING THIS ARENA COULD HAVE LEFT STANDING: where to look for its
--- scenery, how far out, and which models count as its own.
---
--- FOR THE ONE FAILURE A HANDLE LIST CANNOT COVER. The client deletes what it
--- built by remembering each handle, and that is right until the memory and
--- the world disagree -- a build aborted halfway, a resource restarted with a
--- round live, an error landing between CreateObject and the table the handle
--- is appended to. Each of those leaves a piece standing that nothing is
--- tracking, and because the pieces are marked as mission entities the engine
--- will not collect them either. They stand for the rest of the session in
--- the exact spot the next round lays its own floor -- two copies of every
--- prop in one place, which is what an arena that is solid underfoot and
--- looks broken actually is.
---
--- SKY ARENAS ONLY, and that restriction is the whole safety argument. This
--- identifies scenery by MODEL within a radius, and at an arena on the real
--- map the same shipping container is very likely part of the map: a sweep
--- there would delete the scenery somebody chose the location for. An arena
--- that carries its own floor hangs over open air, where nothing within reach
--- is ours by accident.
--- @param arenaKey any
--- @param factor number|nil -- the size this match grew the arena to
--- @return table|nil -- { x, y, z, radius, height, models = { [name] = true } }
function Arena.PropSweep(arenaKey, factor)
    local platform = Arena.GetPlatform(arenaKey, factor)
    if not platform then return nil end

    local centre = Arena.GetSpawnArea(arenaKey, factor)
    if not centre then
        local arena = Arena.GetArenaByKey(arenaKey)
        local boundary = type(arena) == 'table' and type(arena.boundary) == 'table'
            and arena.boundary.center or nil
        if not Arena.IsPoint(boundary) then return nil end
        centre = { x = tonumber(boundary.x) or 0.0, y = tonumber(boundary.y) or 0.0,
                   z = tonumber(boundary.z) or 0.0 }
    end

    local models = {}
    for _, name in ipairs(platform.models) do models[name] = true end
    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        for _, name in ipairs(piece.models or {}) do models[name] = true end
    end

    return {
        x = tonumber(centre.x) or 0.0,
        y = tonumber(centre.y) or 0.0,
        z = platform.z,
        radius = platform.radius + SWEEP_MARGIN,
        height = SWEEP_HEIGHT,
        models = models,
    }
end

function Arena.SpawnFloor(arenaKey)
    local platform = Arena.GetPlatform(arenaKey)
    if not platform then return nil end
    return platform.z
end

--- Where a spectator's streamer should be pointed to see this arena.
---
--- THE VIEWER IS NEVER MOVED. Spectating hides their body where it stands,
--- and the engine streams what is near the FOCUS -- so watching a match
--- across the map, or the one a kilometre over the water, shows an empty
--- field until something points the streamer at it. A routing bucket does
--- not do that: it decides who a player COULD see, not what is loaded.
---
--- The boundary centre first, because every arena that has one is fought
--- inside it; the spawn area next; the first spawn point last. Nil for an
--- arena that describes none of those, which is an arena nothing can be
--- said about rather than one to guess at.
--- @param arenaKey any
--- @return table|nil point -- { x, y, z }
function Arena.SpectateFocus(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    if not arena then return nil end

    local boundary = arena.boundary
    if type(boundary) == 'table' and Arena.IsPoint(boundary.center) then
        return { x = boundary.center.x, y = boundary.center.y, z = boundary.center.z }
    end

    local area = arena.spawnArea
    if type(area) == 'table' and Arena.IsPoint(area.center) then
        return { x = area.center.x, y = area.center.y, z = area.center.z }
    end

    local spawns = arena.spawns
    if type(spawns) == 'table' and Arena.IsPoint(spawns[1]) then
        return { x = spawns[1].x, y = spawns[1].y, z = spawns[1].z }
    end

    return nil
end

function Arena.UsesExactSpawnZ(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    return type(arena) == 'table' and arena.exactSpawnZ == true
end

function Arena.SizeFactor(arenaKey, players)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return 1.0 end

    local scale = arena.scale
    if type(scale) ~= 'table' or scale.enabled ~= true then return 1.0 end

    local count = Arena.ToInt(players) or 0
    local baseline = Arena.ToInt(scale.baseline) or 6
    local extra = math.max(0, count - baseline)
    if extra == 0 then return 1.0 end

    local area = arena.spawnArea
    local base = (type(area) == 'table' and tonumber(area.radius)) or 0
    if base <= 0 then return 1.0 end

    local perPlayer = tonumber(scale.perPlayer) or 0
    if perPlayer <= 0 then return 1.0 end

    local factor = 1.0 + (extra * perPlayer) / base
    local ceiling = math.max(1.0, tonumber(scale.maxGrowth) or 2.0)
    return math.min(factor, ceiling)
end

function Arena.GetSpawnArea(arenaKey, factor)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return nil end

    local area = arena.spawnArea
    if type(area) ~= 'table' or area.enabled == false then return nil end

    local grow = sizeFactor(factor)

    local centre = area.center or area.centre
    local x = centre and tonumber(centre.x) or (centre and tonumber(centre[1]))
    local y = centre and tonumber(centre.y) or (centre and tonumber(centre[2]))
    local z = centre and tonumber(centre.z) or (centre and tonumber(centre[3]))
    if not x or not y or not z then return nil end

    local radius = math.max(1.0, tonumber(area.radius) or 60.0) * grow

    -- THE CIRCLE IS PUT ON THE FLOOR, because this is the one place every
    -- placement in this file reads it from -- Arena.PlanSpawns for the roster
    -- at the start of a round, Arena.PickRespawn for every death after it.
    --
    -- A RING WIDER THAN THE FLOOR PLACES PEOPLE OVER OPEN AIR, and under the
    -- sky arena open air is a thousand metres of it. A CENTRE FAR ABOVE THE
    -- FLOOR is the same fall with no bad radius to blame it on. Both are
    -- named by Arena.ValidateConfig at start-up -- off the RAW config, so
    -- those warnings survive this clamp and DO NOT go quiet the moment it
    -- starts working -- but a line in a console nobody is reading is not a
    -- floor under anybody's feet.
    --
    -- CLAMPED TO platform.radius, WHICH IS THE CONSERVATIVE EDGE. The floor
    -- is tiled and a tile is kept whenever ANY part of it reaches that
    -- radius, so the real surface hangs half a tile further out than this
    -- everywhere and a spawn on the clamped rim still has ground under it.
    --
    -- The height is brought DOWN only. See settleOnFloor for why the low
    -- side is the client's to fix and not this file's.
    local platform = Arena.GetPlatform(arenaKey, factor)
    if platform then
        if radius > platform.radius then radius = platform.radius end
        if z > platform.z + SPAWN_ABOVE_FLOOR then z = platform.z end
    end

    return {
        x = x, y = y, z = z,
        radius = radius,
        minSeparation = math.max(0.0, math.min(tonumber(area.minSeparation) or 10.0, radius)),
        mateSeparation = math.max(0.0, math.min(
            tonumber(area.mateSeparation) or math.min(tonumber(area.minSeparation) or 10.0, 4.0),
            radius)),
        teamRadius = tonumber(area.teamRadius)
            and math.max(1.0, tonumber(area.teamRadius) * grow)
            or math.max(1.0, radius * 0.25),
    }
end

local function distanceSquared(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

local function facingCentre(centreX, centreY, x, y)
    local toCentre = math.deg(math.atan(centreY - y, centreX - x))
    return (toCentre - 90.0 + 360.0) % 360.0
end

local function sampleDisc(rng, area, centreX, centreY, radius)
    local angle = rng() * math.pi * 2.0
    local distance = math.sqrt(rng()) * radius
    return {
        x = centreX + math.cos(angle) * distance,
        y = centreY + math.sin(angle) * distance,
        z = area.z,
        w = facingCentre(area.x, area.y,
            centreX + math.cos(angle) * distance,
            centreY + math.sin(angle) * distance),
    }
end

local SAMPLES_PER_ROUND = 96

local PACKING_EFFICIENCY = 0.80

local ANCHOR_CANDIDATES = 32

local function achievableSeparation(radius, count)
    if count <= 1 then return radius end
    return PACKING_EFFICIENCY * radius * math.sqrt((2.0 * math.pi / math.sqrt(3.0)) / count)
end

local function needBetween(other, team, mate, enemy)
    if other.clearance then return other.clearance end
    -- `team` is nil in a free-for-all, where everybody is an enemy -- so this
    -- deliberately does not fire on two nils.
    if team ~= nil and other.team == team then return mate end
    return enemy
end

local function scatterWithin(rng, area, centreX, centreY, radius, rules, count, placed, team)
    local out = {}

    for _ = 1, count do
        local chosen
        local enemy = rules.enemy
        local mate = rules.mate

        for _ = 1, 5 do
            for _ = 1, SAMPLES_PER_ROUND do
                local candidate = sampleDisc(rng, area, centreX, centreY, radius)
                local ok = true
                for _, other in ipairs(placed) do
                    local need = needBetween(other, team, mate, enemy)
                    if distanceSquared(candidate, other) < need * need then ok = false break end
                end
                if ok then chosen = candidate break end
            end
            if chosen then break end

            -- THE TWO ARE RELAXED SEPARATELY, AND THAT IS THE WHOLE POINT.
            --
            -- Relaxing them together was a real regression, measured rather
            -- than reasoned about: eight fighters do not fit inside one
            -- team's own circle at the operator's separation, so the mate
            -- constraint fails every round -- and sharing one decay dragged
            -- the ENEMY gap down with it, to under seven metres in a
            -- sixteen-player team match. Crowding among teammates says
            -- nothing whatever about how close the other side should be.
            --
            -- So the mate gap gives way, because teammates standing close
            -- together is the shape of a team. The enemy gap gives way only
            -- as far as the number the operator actually wrote, and never
            -- past it.
            -- THE MATE FLOOR DOES NOT MOVE. It is already the smallest
            -- distance this file asks for anywhere -- a body's width and a
            -- step -- and relaxing it means placing somebody inside
            -- somebody, which no amount of crowding makes acceptable.
            --
            -- What gives way is the enemy gap, down to `rules.floor` -- the
            -- operator's own minSeparation -- and no further. Relaxing it to
            -- the MATE floor instead was a regression I introduced and
            -- measured: it let two enemies in a crowded free-for-all come
            -- out four metres apart, which is the whole complaint arriving
            -- back through the door marked "teammates land together".
            enemy = math.max(rules.floor, enemy * 0.7)
        end

        if not chosen then
            local bestScore
            for _ = 1, SAMPLES_PER_ROUND do
                local candidate = sampleDisc(rng, area, centreX, centreY, radius)
                local nearest = math.huge
                for _, other in ipairs(placed) do
                    local gap = distanceSquared(candidate, other)
                    if gap < nearest then nearest = gap end
                end
                if bestScore == nil or nearest > bestScore then
                    chosen, bestScore = candidate, nearest
                end
            end
        end
        chosen.team = team
        placed[#placed + 1] = chosen
        out[#out + 1] = chosen
    end

    return out
end

local function pickAnchors(rng, area, count, spread)
    local reach = math.max(0.0, area.radius - spread)
    local anchors = {}

    for index = 1, count do
        local best, bestScore
        for _ = 1, ANCHOR_CANDIDATES do
            local angle = rng() * math.pi * 2.0
            local candidate = {
                x = area.x + math.cos(angle) * reach,
                y = area.y + math.sin(angle) * reach,
                z = area.z,
            }
            if index == 1 then
                best = candidate
                break
            end
            local nearest = math.huge
            for _, other in ipairs(anchors) do
                local gap = distanceSquared(candidate, other)
                if gap < nearest then nearest = gap end
            end
            if bestScore == nil or nearest > bestScore then
                best, bestScore = candidate, nearest
            end
        end
        best.w = facingCentre(area.x, area.y, best.x, best.y)
        anchors[#anchors + 1] = best
    end

    return anchors
end

function Arena.PlanSpawns(arenaKey, roster, rng, factor)
    local area = Arena.GetSpawnArea(arenaKey, factor)
    if not area or type(roster) ~= 'table' or #roster == 0 then return nil end

    rng = rng or math.random

    local order, byTeam = {}, {}
    for _, entry in ipairs(roster) do
        local team = Arena.IsKey(entry.team) and entry.team or nil
        local key = team or '\0ffa'
        if not byTeam[key] then
            byTeam[key] = {}
            order[#order + 1] = key
        end
        byTeam[key][#byTeam[key] + 1] = entry
    end

    local plan = {}

    local placed = {}
    local clearance = Arena.CoverClearance(arenaKey)
    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        placed[#placed + 1] = {
            x = area.x + piece.x,
            y = area.y + piece.y,
            clearance = clearance,
        }
    end

    if #order == 1 and order[1] == '\0ffa' then
        local roll = byTeam['\0ffa']

        local rules = {
            mate = area.mateSeparation,
            floor = area.minSeparation,
            enemy = math.max(area.minSeparation, achievableSeparation(area.radius, #roll)),
        }

        local points = scatterWithin(rng, area, area.x, area.y, area.radius, rules, #roll, placed, nil)
        for index, entry in ipairs(roll) do
            plan[entry.src] = points[index]
        end
        return plan
    end

    local anchors = pickAnchors(rng, area, #order, area.teamRadius)

    local rules = {
        mate = area.mateSeparation,
        floor = area.minSeparation,
        enemy = math.max(area.minSeparation, achievableSeparation(area.radius, #roster)),
    }

    for index, key in ipairs(order) do
        local anchor = anchors[index]

        local points = scatterWithin(rng, area, anchor.x, anchor.y, area.teamRadius,
            rules, #byTeam[key], placed, key)

        for slot, entry in ipairs(byTeam[key]) do
            local point = points[slot]
            point.w = anchor.w
            plan[entry.src] = point
        end
    end

    return plan
end

local RESPAWN_CANDIDATES = 48

local COVER_RETRIES = 12

--- HOW MUCH OF THE BEST GAP ON OFFER A RESPAWN HAS TO CLEAR, as a share.
---
--- A MAXIMIN IS NOT RANDOM, AND DO NOT PUT ONE BACK. The rule here used to
--- be "the candidate whose nearest enemy is furthest away", which sounds
--- like safety and is a cursor. Measured on the shipped skydome over 3,000
--- respawns with one enemy standing on the spawn rim: every single one
--- landed 64.2 to 70.0 metres away against a possible 70.0 -- a 5.8m window
--- on a 35m circle. With that enemy in the MIDDLE instead, all 3,000 landed
--- 34.4 to 35.0 metres out, which is the wall, every time, all the way
--- round. An arithmetic maximum has one answer, so an opponent who knows
--- where they are standing knows where you are about to appear: stand
--- still, watch the far wall, kill them again.
---
--- WHAT REPLACED IT: a bar, and a draw above it. Every candidate that
--- clears the bar is as good as every other and one of them is taken at
--- random. The bar is the gap the arena can actually promise --
--- achievableSeparation for the crowd on the field, floored at the
--- operator's own minSeparation -- and where the arena cannot promise that
--- much, it is this share of the best any candidate managed.
---
--- THE NUMBER, MEASURED RATHER THAN CHOSEN. Same arena, same 3,000 draws,
--- one enemy in the middle where the promise is out of reach: at 0.90 the
--- answer spans 31.2 to 35.0m, which is the maximin again with extra steps;
--- at 0.75, 26.4 to 35.0m; at 0.50, 17.4 to 35.0m and the rim case gives up
--- 4.3m of real distance (33.4 rather than 37.7) for spread nobody can see.
--- It must also stay UNDER 1.0: at exactly 1.0 the bar is the best gap
--- itself, one float round-trip puts the only candidate that reaches it on
--- the wrong side, nothing qualifies, and the draw falls back to the whole
--- disc -- measured at 0.49m from the enemy.
local SAFE_SHARE = 0.75

--- One of these, at random.
---
--- CLAMPED, because `rng` is a caller's function and not always math.random:
--- the suites pass a seeded stand-in, and a generator that can answer exactly
--- 1.0 indexes one past the end and hands back nil -- which reads to every
--- caller as "this arena has nowhere to put you".
local function drawFrom(rng, list)
    return list[math.min(#list, math.floor(rng() * #list) + 1)]
end

local function asPoint(value)
    if not Arena.IsPoint(value) then return nil end
    local ok, x, y = pcall(function() return value.x, value.y end)
    if not ok or type(x) ~= 'number' or type(y) ~= 'number' then
        if type(value) ~= 'table' then return nil end
        x, y = tonumber(value[1]), tonumber(value[2])
        if not x or not y then return nil end
    end
    return { x = x, y = y }
end

function Arena.PickRespawn(arenaKey, teamKey, avoid, rng, factor, prefer)
    rng = rng or math.random

    local threats = {}
    for _, entry in ipairs(type(avoid) == 'table' and avoid or {}) do
        local point = asPoint(entry)
        if point then threats[#threats + 1] = point end
    end

    local friends = {}
    for _, entry in ipairs(type(prefer) == 'table' and prefer or {}) do
        local point = asPoint(entry)
        if point then friends[#friends + 1] = point end
    end

    local blocked = {}
    local clearance = Arena.CoverClearance(arenaKey)
    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        blocked[#blocked + 1] = { x = piece.x, y = piece.y }
    end

    --- How much room a point has, squared: the distance to the NEAREST piece
    --- of cover, rather than a yes/no against the first piece that is close.
    --- The number is what lets the last resort below pick the least buried
    --- point instead of an arbitrary one.
    local function coverRoom(point, centreX, centreY)
        local nearest = math.huge
        for _, piece in ipairs(blocked) do
            local dx = point.x - (centreX + piece.x)
            local dy = point.y - (centreY + piece.y)
            local room = dx * dx + dy * dy
            if room < nearest then nearest = room end
        end
        return nearest
    end

    -- TWO ARRAYS, AND THE SECOND ONE IS NOT TIDINESS.
    --
    -- `candidates` holds what is handed back -- for a hand-written list that
    -- is the operator's own vector4, untouched. `planes` holds a plain
    -- { x, y } read of the same point, and every distance below is measured
    -- against THAT.
    --
    -- THE DEFECT this closes, which HEAD threw on: an operator may write a
    -- spawn as a bare array, `{ 1500.0, 3000.0, 1201.0, 0.0 }` -- the shape
    -- asPoint was taught to read for threat positions, so it is a shape
    -- somebody has already used. Scoring it directly reads `point.x` as nil
    -- and `nil - number` RAISES, inside the respawn thread, after
    -- scheduleRespawn has already set `entry.alive = true`. That is a corpse
    -- the roster counts as a living fighter: it can never report another
    -- death, `stillIn` never falls to one, and a round with no clock never
    -- ends. Measured at HEAD: throws the moment there is one live enemy.
    --
    -- An entry nothing can be read out of is DROPPED, exactly as a junk
    -- threat position is. If that empties the list the answer is nil, which
    -- server/match.lua already handles by leaving them down and saying so.
    local candidates, planes = {}, {}
    local area = Arena.GetSpawnArea(arenaKey, factor)
    if area then
        local wall = clearance * clearance

        -- WHAT HAPPENS WHEN EVERY DRAW IS INSIDE A PROP, which is the whole
        -- reason this is kept rather than counted.
        --
        -- THE DEFECT: the redraw loop ran up to twelve times and then used
        -- whatever the LAST draw was, inside cover or not, and the filter
        -- underneath fell back to the unfiltered list the moment nothing in
        -- it was clear. So an arena whose cover swallows its spawn ring --
        -- clearance set too high, a dense layout, a small ring inside a
        -- doubled wall -- placed fighters INSIDE the props, arbitrarily, and
        -- that is the complaint this whole clearance exists to answer:
        -- players spawning in the trailers.
        --
        -- Now nothing that is inside cover is ever a candidate. If 576 draws
        -- cannot find one clear point, the single ROOMIEST draw is used --
        -- the least buried place the arena has, which is the best answer
        -- there is and is never worse than an arbitrary one.
        local roomiest, roomiestRoom
        for _ = 1, RESPAWN_CANDIDATES do
            for _ = 1, COVER_RETRIES do
                local drawn = sampleDisc(rng, area, area.x, area.y, area.radius)
                local room = coverRoom(drawn, area.x, area.y)
                if room >= wall then
                    candidates[#candidates + 1] = drawn
                    planes[#planes + 1] = drawn
                    break
                end
                if roomiestRoom == nil or room > roomiestRoom then
                    roomiest, roomiestRoom = drawn, room
                end
            end
        end
        if #candidates == 0 and roomiest then candidates[1], planes[1] = roomiest, roomiest end
    else
        local arena = Arena.GetArenaByKey(arenaKey)
        if type(arena) ~= 'table' then return nil end

        local list
        if Arena.IsKey(teamKey) and type(arena.teamSpawns) == 'table' then
            local teamList = arena.teamSpawns[teamKey]
            if type(teamList) == 'table' and #teamList > 0 then list = teamList end
        end
        if not list then list = arena.spawns end
        if type(list) ~= 'table' or #list == 0 then return nil end

        -- Walked from a RANDOM start rather than from the front, so that two
        -- points which are equally good do not always resolve to the same
        -- one. Without this a small list plus one enemy is a cursor again.
        local offset = math.floor(rng() * #list)
        for step = 1, #list do
            local point = list[((offset + step - 1) % #list) + 1]
            local plane = asPoint(point)
            if plane then
                candidates[#candidates + 1] = settleOnFloor(arenaKey, point, factor)
                planes[#planes + 1] = plane
            end
        end

        -- A HAND-WRITTEN LIST IS THE OPERATOR'S CHOICE and is never thinned:
        -- these are points somebody placed on purpose, and dropping one
        -- because a barrier is near it can leave nothing to return at all.
        -- Cover clearance is for points this file INVENTED.
        --
        -- ITS HEIGHT IS NOT A CHOICE, which is why settleOnFloor is the one
        -- thing applied to it. A hand-typed z that misses the floor of a sky
        -- arena is not a placement somebody meant; it is a fighter under the
        -- platform or falling past it, and the arena knows exactly where its
        -- own surface is.
    end

    if #candidates == 0 then return nil end

    local pool = {}
    for index = 1, #candidates do pool[index] = index end

    -- The gap this arena PROMISES against the crowd currently on the field,
    -- and the floor it may never go under. Both are the operator's own
    -- numbers, and both are the same ones Arena.PlanSpawns places the
    -- opening roster to. A hand-written list has no circle and so no
    -- promise -- there the bar is a share of the best on offer and nothing
    -- else.
    local keepOut = 0.0
    local promised = math.huge
    if area then
        keepOut = area.minSeparation
        promised = math.max(keepOut, achievableSeparation(area.radius, #threats + 1))
    end

    local function nearestOf(index, crowd)
        local nearest = math.huge
        for _, other in ipairs(crowd) do
            local gap = distanceSquared(planes[index], other)
            if gap < nearest then nearest = gap end
        end
        return nearest
    end

    local safe, held = pool, true

    if #threats > 0 then
        local reach = 0.0
        for _, index in ipairs(pool) do
            local gap = nearestOf(index, threats)
            if gap > reach then reach = gap end
        end
        reach = math.sqrt(reach)

        local share = reach * SAFE_SHARE
        local bar = math.max(keepOut, math.min(promised, share))

        -- THE ONE CASE THE OPERATOR'S FLOOR CANNOT BE HONOURED: an arena
        -- whose minSeparation is as wide as the arena, or a field so crowded
        -- that nowhere in it is that far from everybody. Nothing qualifying
        -- means nothing to choose from, so the bar drops to the best on
        -- offer -- and `held` records that the promise was NOT kept, which
        -- is what stands the team rule below down. Rejoining your side must
        -- NEVER be the thing that walks you into the fight.
        if bar > reach then
            bar, held = share, false
        end

        local qualified = {}
        for _, index in ipairs(pool) do
            if nearestOf(index, threats) >= bar * bar then
                qualified[#qualified + 1] = index
            end
        end
        if #qualified > 0 then safe = qualified end
    end

    -- COMING BACK BESIDE YOUR OWN SIDE, IN A BAND RATHER THAN ON TOP OF THEM.
    --
    -- THE DEFECT, MEASURED on the shipped skydome over 3,000 team respawns
    -- with one team-mate 20m off centre: a mean of 4.20m from them, a median
    -- of 3.20m and a closest of 0.11m. The rule was "the qualifying point
    -- NEAREST a team-mate", and the nearest point to somebody is on top of
    -- them. An enemy who kills one of a pair then knows within a couple of
    -- metres where the other one is about to stand, and one grenade covers
    -- both of them.
    --
    -- THE TWO NUMBERS ARE THE OPERATOR'S, NOT MINE.
    --
    --   NEVER CLOSER THAN minSeparation. config.lua writes it down as
    --   "never closer than this to another player" -- another PLAYER, not
    --   another enemy -- and a respawn places exactly one body, so it has
    --   none of the packing pressure that makes Arena.PlanSpawns relax to
    --   mateSeparation when eight fighters will not fit in one team circle.
    --   There is no excuse for a respawn to come in under the number the
    --   arena states. On both shipped arenas that is 10 metres.
    --
    --   NEVER FURTHER THAN teamRadius. That is config.lua's own "how
    --   tightly one team lands together", and it is what Arena.PlanSpawns
    --   scatters a side inside at the start of the round. 16m on the
    --   skydome, 18m on the trailer park. Inside it you are with your side;
    --   outside it you have been dropped somewhere else.
    --
    -- So "close to an ally" is 10 to 16 metres of open annulus -- around
    -- 490 square metres of it -- drawn from at random. Close enough to be
    -- in the same fight, far enough that killing one of a pair does not
    -- tell you where the other will be.
    --
    -- WHEN NOTHING IS IN THE BAND -- your side is fighting in the middle and
    -- the enemy gap has pushed every candidate out to the rim -- the CEILING
    -- is what gives way, NEVER the floor, and it gives way to the whole safe
    -- set rather than to a single nearest point. Being unable to reach your
    -- team-mate is a disappointment; being placed on top of them is the
    -- defect. The floor only gives way where nothing at all can hold it,
    -- which is the same condition `held` records for the enemy gap.
    if held and #friends > 0 and #safe > 0 then
        local closest = math.huge
        for _, index in ipairs(safe) do
            local gap = nearestOf(index, friends)
            if gap < closest then closest = gap end
        end

        local ceiling = math.max(area and area.teamRadius or 0.0,
            math.sqrt(closest) / SAFE_SHARE)

        local band, spaced = {}, {}
        for _, index in ipairs(safe) do
            local gap = nearestOf(index, friends)
            if gap >= keepOut * keepOut then
                spaced[#spaced + 1] = index
                if gap <= ceiling * ceiling then band[#band + 1] = index end
            end
        end

        if #band == 0 then band = spaced end

        -- Everything near enough to a team-mate is also nearer than the
        -- arena allows, which happens only where the enemy gap and the team
        -- gap cannot both be had. Being with your side wins that one -- the
        -- enemy bar has already been cleared by every candidate here.
        if #band == 0 then
            for _, index in ipairs(safe) do
                if nearestOf(index, friends) <= ceiling * ceiling then
                    band[#band + 1] = index
                end
            end
        end

        if #band > 0 then return candidates[drawFrom(rng, band)] end
    end

    return candidates[drawFrom(rng, safe)]
end

--- How many lives a host may give a match, resolved from what they asked for.
---
--- Mirrors ResolveEntryFee deliberately: both are numbers a host picks at
--- creation, both are clamped to a range the operator sets, and both REFUSE
--- an out-of-range request rather than quietly clamping it -- a host who
--- typed 99 and silently got 5 would believe they were running a different
--- match to the one they are in.
---
--- Config.Match.lives takes two shapes. A plain number fixes the count for
--- every match, which is how an operator takes the decision away without a
--- second setting to find. A table opens it up to the host.
--- @param requested any
--- @return integer|nil lives
--- @return string|nil reason
function Arena.ResolveLives(requested)
    local lives = Config.Match.lives or {}

    if type(lives) ~= 'table' then
        return math.max(1, Arena.ToInt(lives) or 1), nil
    end

    local minimum = math.max(1, Arena.ToInt(lives.min) or 1)
    local maximum = math.max(minimum, Arena.ToInt(lives.max) or minimum)
    local fallback = Arena.ClampInt(lives.default, minimum, maximum) or minimum

    if lives.allowChoose ~= true then return fallback, nil end

    local wanted = Arena.ToInt(requested)
    if not wanted then return fallback, nil end
    if wanted < minimum or wanted > maximum then return nil, 'error.lives_out_of_range' end
    return wanted, nil
end

function Arena.ResolveRadar(requested)
    local radar = (Config.Match or {}).radar
    if type(radar) ~= 'table' then return false, nil end

    local fallback = radar.defaultOn == true
    if radar.allowChoose ~= true then return fallback, nil end
    if requested == true or requested == false then return requested, nil end
    return fallback, nil
end

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

local function resolveBetBand(rules, requested, disabledReason)
    if Config.Betting.enabled ~= true then return nil, 'error.betting_disabled' end

    rules = type(rules) == 'table' and rules or {}
    if rules.enabled ~= true then return nil, disabledReason end

    local minimum = math.max(0, Arena.ToInt(rules.min) or 0)
    local maximum = math.max(minimum, Arena.ToInt(rules.max) or minimum)

    local wanted = Arena.ToInt(requested)
    if not wanted then return nil, 'error.bet_invalid' end
    if wanted < minimum or wanted > maximum then return nil, 'error.bet_out_of_range' end
    return wanted, nil
end

function Arena.ResolveSpectatorBet(requested)
    return resolveBetBand(Config.Betting.spectatorBets, requested, 'error.spectator_bets_disabled')
end

function Arena.ResolveFighterBet(requested)
    return resolveBetBand(Config.Betting.fighterBets, requested, 'error.fighter_bets_disabled')
end

function Arena.ApplyHouseCut(pot)
    local total = math.max(0, Arena.ToInt(pot) or 0)
    local percent = Arena.ToInt(Config.Betting.houseCutPercent) or 0
    if percent <= 0 then return total, 0 end
    if percent >= 100 then return 0, total end
    local cut = math.floor((total * percent) / 100)
    return total - cut, cut
end

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

function Arena.HexToRgb(hex)
    if type(hex) ~= 'string' then return nil end

    local body = hex:gsub('^#', '')
    if #body == 3 then
        body = body:gsub('(%x)', '%1%1')
    end
    if #body ~= 6 or body:match('%X') then return nil end

    return tonumber(body:sub(1, 2), 16),
           tonumber(body:sub(3, 4), 16),
           tonumber(body:sub(5, 6), 16)
end

--- Splits a POOL among winners in proportion to what each of them staked.
---
--- THE POOL IS THE ONLY MONEY THERE IS. Fighter bets pay out of the stakes
--- everybody put in and nothing else -- a winner is paid with the losers'
--- money, and the sum of what is handed out equals the pool exactly. That is
--- the whole difference between this and Arena.ComputeSpectatorPayout, which
--- multiplies a stake by the operator's odds and is therefore funded by the
--- server: a fighter backing themselves must not be able to print money by
--- winning a round they were going to win anyway.
---
--- Proportional rather than even: somebody who staked twice as much carries
--- twice the risk and takes twice the share.
---
--- The remainder goes to the largest stake rather than being dropped, for
--- the same reason every other split here distributes it -- a pool that
--- leaks a few dollars a match is the bug nobody reports and everybody
--- notices.
--- @param pool integer -- every stake placed, winners and losers together
--- @param stakes integer[] -- the WINNERS' stakes, in order
--- @return integer[] shares -- same order; sums to `pool` exactly
function Arena.SplitByStake(pool, stakes)
    local total = math.max(0, Arena.ToInt(pool) or 0)
    if type(stakes) ~= 'table' or #stakes == 0 then return {} end

    local sum = 0
    for _, stake in ipairs(stakes) do sum = sum + math.max(0, Arena.ToInt(stake) or 0) end

    if sum <= 0 then return Arena.SplitEvenly(total, #stakes) end

    local shares, allocated, biggest = {}, 0, 1
    for index, stake in ipairs(stakes) do
        local own = math.max(0, Arena.ToInt(stake) or 0)
        local share = math.floor((total * own) / sum)
        shares[index] = share
        allocated = allocated + share
        if own > (math.max(0, Arena.ToInt(stakes[biggest]) or 0)) then biggest = index end
    end

    shares[biggest] = shares[biggest] + (total - allocated)
    return shares
end

--- Works out who gets paid what when a match ends.
---
--- `context` is deliberately plain data, not a live match object, so this
--- can be tested exhaustively without a server:
---   pot         -- integer, everything staked
---   players     -- array of { id, team, kills, stake, placement }
---   winners     -- array of ids (already decided by the match, not here)
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

    local contestants = math.max(#players, Arena.ToInt(context.contestants) or 0)
    local minimum = Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0
    if contestants < minimum then return refundEveryone('refund_too_few') end

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

function Arena.ComputeSpectatorPayout(stake)
    local amount = math.max(0, Arena.ToInt(stake) or 0)
    local multiplier = tonumber((Config.Betting.spectatorBets or {}).oddsMultiplier) or 2.0
    if multiplier <= 0 then return 0 end
    return math.floor(amount * multiplier)
end

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

function Arena.HasRoom(currentCount)
    local maximum = Arena.ToInt(Config.Match.maxPlayers) or 0
    if maximum <= 0 then return true end
    return (Arena.ToInt(currentCount) or 0) < maximum
end

local MINUTES_PER_DAY = 1440

function Arena.ScheduleSpans()
    local schedule = Config.Schedule
    if type(schedule) ~= 'table' or schedule.enabled ~= true then return {} end
    if type(schedule.windows) ~= 'table' then return {} end

    local raw = {}
    for _, window in ipairs(schedule.windows) do
        if type(window) == 'table' then
            local from = Arena.ToInt(window.from)
            local to = Arena.ToInt(window.to)

            -- DROPPED, NEVER CLAMPED. A clamped hour is a window nobody
            -- typed, and an operator reading the console would be told a
            -- number they did not write is in force.
            --
            -- `from == to` is dropped too: it reads as "no time at all" and
            -- as "the whole day" equally well, so guessing either would be
            -- guessing. The validator says which to write instead.
            if from and to and from >= 0 and from <= 23
                and to >= 0 and to <= 24 and from ~= to
            then
                local s, e = from * 60, to * 60

                if e < s then
                    raw[#raw + 1] = { start = s, stop = MINUTES_PER_DAY }
                    if e > 0 then raw[#raw + 1] = { start = 0, stop = e } end
                else
                    raw[#raw + 1] = { start = s, stop = e }
                end
            end
        end
    end

    table.sort(raw, function(a, b) return a.start < b.start end)

    local spans = {}
    for _, span in ipairs(raw) do
        local last = spans[#spans]
        if last and span.start <= last.stop then
            if span.stop > last.stop then last.stop = span.stop end
        else
            spans[#spans + 1] = { start = span.start, stop = span.stop }
        end
    end

    return spans
end

function Arena.ScheduleStatus(hour, minute)
    local spans = Arena.ScheduleSpans()
    if #spans == 0 then return { open = true, always = true } end

    local coverage = 0
    for _, span in ipairs(spans) do coverage = coverage + (span.stop - span.start) end
    if coverage >= MINUTES_PER_DAY then return { open = true, always = true } end

    local now = ((Arena.ToInt(hour) or 0) % 24) * 60 + ((Arena.ToInt(minute) or 0) % 60)

    for index, span in ipairs(spans) do
        if now >= span.start and now < span.stop then
            local stop = span.stop
            if stop == MINUTES_PER_DAY and spans[1].start == 0 then
                stop = spans[1].stop
            end
            return { open = true, always = false, closesAt = stop % MINUTES_PER_DAY, index = index }
        end
    end

    local best
    for _, span in ipairs(spans) do
        local wait = (span.start - now) % MINUTES_PER_DAY
        if not best or wait < best then best = wait end
    end

    return {
        open = false,
        always = false,
        opensAt = (now + best) % MINUTES_PER_DAY,
        -- MINUTES, AND DELIBERATELY NOT RENDERED ANYWHERE. It exists so the
        -- nearest window can be picked. Only absolute times reach a screen.
        opensIn = best,
    }
end

--- Minutes since midnight as 'HH:MM'. The one place that formatting lives,
--- so the NPC label, the panel line, the refusal and /arenahours cannot
--- disagree about how a time is written.
--- @param minutes any
--- @return string
function Arena.ClockText(minutes)
    local total = (Arena.ToInt(minutes) or 0) % MINUTES_PER_DAY
    return string.format('%02d:%02d', math.floor(total / 60), total % 60)
end

--- The whole schedule on one line -- '05:00-07:00, 12:00-14:00' -- or nil
--- when the arena keeps no hours at all.
---
--- Ascending, on purpose: if two entries in that line ever touch or overlap,
--- the merge above is broken and the line says so on sight.
--- @return string|nil
function Arena.ScheduleLine()
    local spans = Arena.ScheduleSpans()
    if #spans == 0 then return nil end

    local coverage = 0
    for _, span in ipairs(spans) do coverage = coverage + (span.stop - span.start) end
    if coverage >= MINUTES_PER_DAY then return nil end

    local first, last = spans[1], spans[#spans]
    local joined = #spans > 1 and first.start == 0 and last.stop == MINUTES_PER_DAY

    local parts = {}
    for index, span in ipairs(spans) do
        if not (joined and index == 1) then
            if joined and index == #spans then
                parts[#parts + 1] = Arena.ClockText(span.start) .. '-' .. Arena.ClockText(first.stop)
            else
                local stop = span.stop == MINUTES_PER_DAY and '24:00' or Arena.ClockText(span.stop)
                parts[#parts + 1] = Arena.ClockText(span.start) .. '-' .. stop
            end
        end
    end

    return table.concat(parts, ', ')
end

--- Who picks the loadout everyone fights with.
---
--- 'host'   -- the host picks once and every player in the match carries it.
--- 'player' -- each player picks their own.
---
--- One reader for both realms so the panel and the server can never disagree
--- about whose choice counts, and anything unrecognised falls back to 'host'
--- -- the safer of the two, because it cannot let a player arm themselves on
--- a server that meant to take that decision away from them.
--- @return string chooser
function Arena.LoadoutChooser()
    local chooser = (Config.Loadouts or {}).chooser
    return chooser == 'player' and 'player' or 'host'
end

--- The spawn area an operator TYPED, for the validator, and deliberately
--- not Arena.GetSpawnArea.
---
--- THE READER AND THE PLACER HAVE TO DISAGREE HERE, WHICH IS THE POINT.
--- Arena.GetSpawnArea now clamps a ring that overhangs the floor and a
--- height that misses it, because a placement has to put a body somewhere
--- solid. Read the clamped answer here and every warning about those two
--- mistakes goes quiet the moment the clamp starts working -- the operator
--- is silently rescued, keeps the typo, and finds it again the day they
--- move the arena onto real ground where nothing rescues anybody.
---
--- So this reads the block itself. It is the raw radius and the raw centre
--- height, at the configured size, exactly as written.
--- @param arenaKey any
--- @return table|nil -- { z, radius }, or nil if there is no readable area
local function arenaSpawnAreaOf(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return nil end

    local area = arena.spawnArea
    if type(area) ~= 'table' or area.enabled == false then return nil end

    local centre = area.center or area.centre
    local z = centre and tonumber(centre.z) or (centre and tonumber(centre[3]))
    if not z then return nil end

    return {
        z = z,
        radius = math.max(1.0, tonumber(area.radius) or 60.0),
    }
end

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
    local catalogue = Config.Loadouts.weapons
    if type(catalogue) ~= 'table' or #catalogue == 0 then
        complain('Config.Loadouts.weapons is empty or missing, so nobody can be issued anything. '
            .. 'THE WEAPON CATALOGUE IS IN config.weapons.lua, not config.lua. That file must be '
            .. 'present in the resource folder AND listed in fxmanifest.lua under shared_scripts '
            .. 'straight after config.lua. If you updated from a copy that predates the split, it '
            .. 'is a new file -- copy it across.')
    elseif #Arena.GetEnabledWeapons() == 0 then
        complain(('Config.Loadouts.weapons has %d entries and not one of them is enabled -- '
            .. 'players would spawn empty-handed. They are in config.weapons.lua.'):format(#catalogue))
    end

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

    -- CAN EVERY WEAPON THE ARENA WILL HAND OUT ACTUALLY BE LOADED.
    --
    -- WHAT THIS IS AND, JUST AS IMPORTANTLY, WHAT IT IS NOT. It reads
    -- config.weapons.lua and says whether an ENABLED entry describes a gun
    -- that can be issued with rounds in it. It does not look at
    -- ox_inventory, it does not correct anything, and nothing at run time
    -- reads its answer -- a weapon named here is still handed out exactly as
    -- written. THE OWNER'S VALUES ARE THE OWNER'S; this only says out loud
    -- what the code is about to do with them.
    --
    -- ONLY THE ENABLED ONES, and that is the whole reason it is a second
    -- loop rather than three more lines inside the one above. A switched-off
    -- entry is kept on purpose so it can be switched back on with one word --
    -- config.weapons.lua says so beside all three of them -- and complaining
    -- about a weapon nobody can be issued would teach an operator that these
    -- lines are noise. The predicate is GetEnabledWeapons's own, spelled out
    -- rather than borrowed, because this has to see the entries that function
    -- silently DROPS as well as the ones it returns.
    for _, weapon in ipairs(Config.Loadouts.weapons or {}) do
        if type(weapon) == 'table' and weapon.enabled ~= false and Arena.IsKey(weapon.key) then
            local name = tostring(weapon.key)

            if not Arena.IsKey(weapon.weapon) then
                complain(('Config.Loadouts.weapons["%s"] is switched on but names no `weapon`, so it is '
                    .. 'dropped from the catalogue without a word: it never reaches the loadout panel and '
                    .. 'nobody can ask for it. Give it the GTA weapon name, or set enabled = false.')
                    :format(name))

            elseif not Arena.IsMeleeWeapon(weapon) then
                local types = Arena.GetAmmoTypes(weapon)

                if #types == 0 then
                    complain(('Config.Loadouts.weapons["%s"] (%s) is switched on and is not a melee weapon, '
                        .. 'but no ammunition resolves for it -- its `ammoTypes` is empty or switched off and '
                        .. 'Config.Loadouts.defaultAmmoTypes does not cover it. It will be handed over with '
                        .. 'nothing to load it with.'):format(name, tostring(weapon.weapon)))
                elseif (Config.Loadouts.ammoItems or {}).enabled == true then
                    for _, entry in ipairs(types) do
                        if not Arena.IsKey(entry.item) then
                            complain(('Config.Loadouts.weapons["%s"] (%s) offers the ammo type "%s" with no '
                                .. '`item` on it. Ammo items are switched on, so every other weapon is issued '
                                .. 'rounds as items and this one is issued none -- a fighter who picks that '
                                .. 'ammo type gets the gun and an empty magazine. Put the ammo item name from '
                                .. 'your ox_inventory on it.'):format(name, tostring(weapon.weapon), tostring(entry.key)))
                        end
                    end
                end

            elseif weapon.category ~= 'melee' then
                -- MELEE IS DECIDED BY THE AMMO CEILING AND NOT ONLY BY THE
                -- CATEGORY, which is a rule an operator CANNOT guess from the
                -- file in front of him. Arena.IsMeleeWeapon reads any
                -- `ammo.max` of 1 or less as "there is nothing to load", so
                -- one firearm written `max = 1` quietly stops being a firearm
                -- -- no ammo row on the panel, no rounds issued, no kill ammo
                -- paid -- and nothing else in this resource would ever say so.
                -- DO NOT read this as a complaint about the shipped file:
                -- every enabled entry in it is well clear of the line.
                complain(('Config.Loadouts.weapons["%s"] (%s) is in category "%s" but its ammo max is 1 or '
                    .. 'less, so the arena reads it as a MELEE weapon: no ammunition is offered for it and '
                    .. 'none is issued. If it is meant to fire, raise Config.Loadouts.weapons["%s"].ammo.max.')
                    :format(name, tostring(weapon.weapon), tostring(weapon.category), name))
            end
        end
    end

    for _, supply in ipairs(Arena.GetEnabledSupplies()) do
        local maximum = Arena.SupplyMax(supply)
        local default = Arena.ClampInt(supply.default, 0, maximum) or 0

        if maximum <= 0 then
            complain(('Config.Loadouts.supplies.items["%s"] has a max of 0, so it can never be handed to anybody -- the picker still draws its row with every chip reading None. Give it a max, or switch the entry off with enabled = false.')
                :format(tostring(supply.key)))
        end

        local options = type(supply.options) == 'table' and supply.options or {}
        if #options == 0 then options = { 0, maximum } end

        local reachable = false
        for _, option in ipairs(options) do
            if (Arena.ClampInt(option, 0, maximum) or 0) == default then
                reachable = true
                break
            end
        end

        if not reachable then
            complain(('Config.Loadouts.supplies.items["%s"] defaults to %d, which is not one of its own options -- the picker offers chips and nothing else, so a player who touches that row can never get back to %d.')
                :format(tostring(supply.key), default, default))
        end
    end

    -- `or {}`, AND IT IS THE WHOLE POINT OF THIS LOOP RUNNING AT ALL.
    --
    -- The two calls disagree about what an arena is. GetEnabledArenas lists
    -- every key whose block is not `enabled = false`; GetArenaByKey refuses
    -- anything Arena.IsKey rejects, and Arena.IsKey rejects the empty string.
    -- So `Config.Arenas[''] = { ... }` is LISTED here and answers nil there,
    -- and an unguarded `arena.spawns` then indexes nil -- inside the
    -- validator, which is the first thing onResourceStart calls. It took
    -- EnsureSchema and the owed-kit read-back down with it, and on the client
    -- it took the thread that builds the lobby ped, which is the only way
    -- into the arena.
    --
    -- The loop twenty lines down already wrote `or {}` for the same pair.
    -- DO NOT take this one back off; a validator that cannot survive the
    -- config it is validating is not a validator.
    for _, entry in ipairs(Arena.GetEnabledArenas()) do
        local arena = Arena.GetArenaByKey(entry.key) or {}
        if type(arena.spawns) ~= 'table' or #arena.spawns == 0 then
            complain(('Config.Arenas["%s"] has no spawns -- players would have nowhere to land.'):format(tostring(entry.key)))
        end
        if not Arena.IsKey(entry.key) then
            complain(('Config.Arenas has an arena under the key %s (a %s). An arena key has to be a '
                .. 'non-empty piece of text in brackets and quotes -- ["pier"], not [pier], not [3] '
                .. 'and not [""]. This one is listed in the panel and cannot be looked up, so no '
                .. 'match can be created in it.'):format(
                    entry.key == '' and '""' or tostring(entry.key), type(entry.key)))
        end

        -- A CLEARANCE OF ZERO IS NOT "NO MARGIN", IT IS NO GUARD.
        --
        -- Arena.CoverClearance takes any number at or above zero, so a nought
        -- typed here is honoured -- and it is the ONE reading that switches
        -- the whole prop exclusion off rather than tightening it. Measured on
        -- the shipped skydome with clearance = 0: 1,260 respawns in 2,000
        -- landed within seven metres of a container's centre, which is inside
        -- it. Nothing else anywhere says so, and the report an operator gets
        -- back is "I keep spawning in the containers".
        --
        -- Named rather than overridden, because zero on an arena with no
        -- pieces is harmless and meaningless, and this cannot read the
        -- operator's mind -- only the pieces they wrote next to it.
        local cover = arena.cover
        if type(cover) == 'table' and cover.enabled ~= false
            and type(cover.pieces) == 'table' and #cover.pieces > 0
            and tonumber(cover.clearance) == 0
        then
            complain(('Config.Arenas["%s"].cover.clearance is 0, with %d piece(s) of cover standing. '
                .. 'That is not a tight margin, it is no check at all: fighters will be placed inside '
                .. 'the props. It has to be at least the widest piece\'s half-length -- about 7 for a '
                .. 'shipping container, which is what an unset clearance uses.')
                :format(tostring(entry.key), #cover.pieces))
        end
    end

    -- AN ARENA THAT CARRIES ITS OWN FLOOR WRITES ITS HEIGHT DOWN SEVERAL
    -- TIMES, and every one of them has to agree.
    --
    -- The sky arena states its height in the platform, the spawn area, the
    -- spawn list, each team list and the boundary. An operator moving it has
    -- to change all of them, and missing one is not a near miss: a spawn
    -- below the floor is a fighter placed underneath the arena, and a spawn
    -- far above it is a long fall the moment the countdown ends. Neither
    -- says anything at the time.
    --
    -- Named here, at start, rather than discovered in a round. A warning
    -- rather than a refusal: an operator may genuinely want a raised spawn,
    -- and this cannot tell that from a typo -- only that the two disagree.
    for _, entry in ipairs(Arena.GetEnabledArenas()) do
        local platform = Arena.GetPlatform(entry.key)
        if platform then
            local surface = platform.z
            local raw = Arena.GetArenaByKey(entry.key) or {}

            local function checkHeight(where, z)
                local value = tonumber(z)
                if not value then return end
                if value < surface - SPAWN_BELOW_FLOOR then
                    complain(('Config.Arenas["%s"].%s is at %.2f, BELOW the platform surface at %.2f -- a fighter placed there is under the arena.')
                        :format(entry.key, where, value, surface))
                elseif value > surface + SPAWN_ABOVE_FLOOR then
                    complain(('Config.Arenas["%s"].%s is at %.2f, %.2f above the platform surface at %.2f -- that is a fall when the countdown ends.')
                        :format(entry.key, where, value, value - surface, surface))
                end
            end

            local area = arenaSpawnAreaOf(entry.key)
            if type(area) == 'table' then
                checkHeight('spawnArea.center.z', area.z)

                if area.radius >= platform.radius then
                    complain(('Config.Arenas["%s"] has a %.2fm floor under a %.2fm spawn ring -- fighters would be placed over open air. platform.radius must be larger than spawnArea.radius.')
                        :format(entry.key, platform.radius, area.radius))
                end
            end

            for index, point in ipairs(raw.spawns or {}) do
                checkHeight(('spawns[%d].z'):format(index), point and point.z)
            end
            for team, list in pairs(raw.teamSpawns or {}) do
                for index, point in ipairs(list or {}) do
                    checkHeight(('teamSpawns.%s[%d].z'):format(tostring(team), index), point and point.z)
                end
            end

            if type(raw.boundary) == 'table' then
                local centre = raw.boundary.center
                if Arena.BoundaryOf(raw) and not (centre
                    and tonumber(centre.x) and tonumber(centre.y) and tonumber(centre.z)) then
                    complain(('Config.Arenas["%s"].boundary is switched on but its centre cannot be read -- it needs x, y and z. Nobody will be warned or bled for leaving this arena.')
                        :format(entry.key))
                end

                checkHeight('boundary.center.z', centre and centre.z)

                if Arena.BoundaryOf(raw) then
                    local tile = math.max(0.0, tonumber(platform.tileSize) or 0)

                    local reach = platform.radius + tile * math.sqrt(2)

                    if tile > 0 then
                        local steps = math.ceil((platform.radius + tile * 0.5) / tile)
                        local cells = (2 * steps + 1) ^ 2
                        if cells <= 40000 then
                            local half = tile * 0.5
                            local measured = 0.0
                            for _, piece in ipairs(Arena.PlatformTiles(platform, 0.0, 0.0,
                                { x = tile, y = tile, top = 0.0 })) do
                                local far = math.sqrt((math.abs(piece.x) + half) ^ 2
                                    + (math.abs(piece.y) + half) ^ 2)
                                if far > measured then measured = far end
                            end
                            if measured > 0.0 then reach = measured end
                        end
                    end

                    local sphere = tonumber(raw.boundary.radius) or 0
                    if sphere < reach then
                        complain(('Config.Arenas["%s"] has a %.2fm boundary around a floor that reaches at least %.2fm at the configured tileSize of %.2fm -- the outer ring of the platform is solid ground OUTSIDE the arena, and standing on it bleeds you. A floor prop that measures larger than tileSize reaches further still.')
                            :format(entry.key, sphere, reach, tile))
                    end
                end
            end
        end
    end

    for key, team in pairs(Config.Teams.list or {}) do
        if type(team) == 'table' and team.enabled ~= false
            and team.order ~= nil and Arena.ToInt(team.order) == nil
        then
            complain(('Config.Teams.list["%s"].order is a %s, not a number -- that team has fallen back to the end of the list.')
                :format(tostring(key), type(team.order)))
        end
    end

    local roundBlock = (Config.Match or {}).roundTimeSeconds
    if type(roundBlock) == 'table' then
        local low = Arena.ToInt(roundBlock.min)
        local high = Arena.ToInt(roundBlock.max)
        if low ~= nil and high ~= nil and high < low then
            complain(('Config.Match.roundTimeSeconds.max is %d, below its min of %d -- no round length would be accepted.')
                :format(high, low))
        end
        local wanted = Arena.ToInt(roundBlock.default)
        local choice = Arena.RoundTimeChoice()
        if choice and wanted ~= nil and (wanted < choice.min or wanted > choice.max) then
            complain(('Config.Match.roundTimeSeconds.default is %d, outside its own %d to %d range -- the create box opens on a number the server then refuses.')
                :format(wanted, choice.min, choice.max))
        end
        if roundBlock.allowChoose == true and Arena.RoundTimeDefault() <= 0 then
            complain('Config.Match.roundTimeSeconds lets the host choose but resolves to 0, which means no round clock at all -- give it a default inside its own range.')
        end
    elseif roundBlock ~= nil and Arena.ToInt(roundBlock) == nil then
        complain(('Config.Match.roundTimeSeconds is a %s -- it has to be a number of seconds, or a { allowChoose, min, max, default } table. It is being read as 0, which means no round clock at all.')
            :format(type(roundBlock)))
    end

    -- THE TWO SETTINGS THAT HAD NO BOOT CHECK AT ALL.
    --
    -- lives, roundTimeSeconds, entryFee and slots each get a complaint above
    -- or below when they are written in a way the code then reads as
    -- something else. scoreLimit and serverChecks did not, and both fall back
    -- SILENTLY -- which is the one thing a validator exists to stop.
    --
    -- DO NOT drop these on the grounds that the shipped numbers are fine.
    -- The shipped numbers are exactly why nobody notices: a silent fallback
    -- is invisible until somebody edits the file, which is the moment the
    -- check is for. serverChecks is the expensive one -- its fallbacks eject
    -- a fighter from a paid round and forfeit their stake, and the rule this
    -- block was written under is NEVER EJECT AN HONEST PLAYER.
    local scoreBlock = (Config.Match or {}).scoreLimit
    if type(scoreBlock) == 'table' then
        local low = Arena.ToInt(scoreBlock.min)
        local high = Arena.ToInt(scoreBlock.max)

        if scoreBlock.min ~= nil and low == nil then
            complain(('Config.Match.scoreLimit.min is a %s, not a number -- it is being read as 1.')
                :format(type(scoreBlock.min)))
        end
        if scoreBlock.max ~= nil and high == nil then
            complain(('Config.Match.scoreLimit.max is a %s, not a number -- it is being read as the min, so the host has no range to pick from.')
                :format(type(scoreBlock.max)))
        end

        local minimum = math.max(1, low or 1)
        if low ~= nil and low < 1 then
            complain(('Config.Match.scoreLimit.min is %d. A score limit of nought or less is a round that is already over, so it is being read as 1.')
                :format(low))
        end
        if high ~= nil and high < minimum then
            complain(('Config.Match.scoreLimit.max is %d, below its min of %d. It is being read as %d rather than refused, so the box on the create screen never opens and every score_limit round runs at %d.')
                :format(high, minimum, minimum, minimum))
        end

        local wanted = Arena.ToInt(scoreBlock.default)
        if scoreBlock.default ~= nil and wanted == nil then
            complain(('Config.Match.scoreLimit.default is a %s, not a number -- it is being read as the min, %d.')
                :format(type(scoreBlock.default), minimum))
        elseif wanted ~= nil and high ~= nil and high >= minimum
            and (wanted < minimum or wanted > high)
        then
            complain(('Config.Match.scoreLimit.default is %d, outside its own %d to %d range -- it is clamped, so score_limit rounds do not open on the number you wrote.')
                :format(wanted, minimum, high))
        end

        if scoreBlock.allowChoose == true and Arena.ScoreLimitChoice() == nil then
            complain(('Config.Match.scoreLimit lets the host choose but min and max leave nothing to choose between, so no box is drawn and every score_limit round runs at %d.')
                :format(Arena.ScoreLimitDefault()))
        end
    elseif scoreBlock ~= nil and Arena.ToInt(scoreBlock) == nil then
        complain(('Config.Match.scoreLimit is a %s -- it has to be a number of kills, or a { allowChoose, min, max, default } table. It is being read as 1, so a score_limit round ends on the first kill.')
            :format(type(scoreBlock)))
    end

    -- THE WIN CONDITION, WHICH HAD NO CHECK AT ALL while every setting
    -- around it did. Arena.WinConditionDefault falls back to last_standing
    -- for any value it does not recognise, silently, in both shapes -- so an
    -- operator who wrote most_kills with one letter wrong, or lastStanding,
    -- or score-limit, ran every round on the server under a rule they did
    -- not pick, with lives being spent when they wanted the clock, and the
    -- console said nothing. config.lua promises the opposite in as many
    -- words: a default this file does not know is named at start-up. Now it
    -- is. A table with no default is not an error -- that is "use the
    -- default" -- only a value that is present and wrong.
    local winBlock = (Config.Match or {}).winCondition
    if winBlock ~= nil then
        local named, where
        if type(winBlock) == 'table' then
            named, where = winBlock.default, 'Config.Match.winCondition.default'
            if winBlock.allowChoose ~= nil and type(winBlock.allowChoose) ~= 'boolean' then
                complain(('Config.Match.winCondition.allowChoose is a %s, not true or false -- it is being read as false, so the host is not offered the choice.')
                    :format(type(winBlock.allowChoose)))
            end
        elseif type(winBlock) == 'string' then
            named, where = winBlock, 'Config.Match.winCondition'
        else
            complain(('Config.Match.winCondition is a %s -- it has to be one of %s, or a { allowChoose, default } table. Every round is being run as %s.')
                :format(type(winBlock), table.concat(WIN_CONDITIONS, ', '), WIN_CONDITIONS[1]))
        end

        if named ~= nil and not isWinCondition(named) then
            complain(('%s is %s, which is not a win condition this resource knows -- it has to be one of %s. Every round is being run as %s instead, which is not what was picked.')
                :format(where, type(named) == 'string' and ("'" .. named .. "'") or tostring(named),
                    table.concat(WIN_CONDITIONS, ', '), WIN_CONDITIONS[1]))
        end
    end

    local checks = (Config.Match or {}).serverChecks
    if checks ~= nil and type(checks) ~= 'table' then
        complain(('Config.Match.serverChecks is a %s, not a table -- BOTH SERVER-SIDE CHECKS ARE OFF. Nobody is measured against the fence and no unreported death is booked.')
            :format(type(checks)))
    elseif type(checks) == 'table' and checks.enabled == true then
        -- OUT-OF-FENCE REMOVAL FORFEITS A STAKE, so a fallback here costs a
        -- player money. The owner's rule for this block is NEVER EJECT AN
        -- HONEST PLAYER, and every complaint below is one way of doing it.
        local metres = tonumber(checks.outsideMetres)
        if metres == nil then
            complain('Config.Match.serverChecks.outsideMetres is missing or unreadable, so it is being read as 60 METRES -- six times the shipped 10. Sixty metres of slack outside the fence is the pocket the setting was written to close: it is measured in three dimensions from the middle of the arena, so a point under the skydome floor sits inside it while the kill ceiling still covers the whole arena. Check the spelling -- it is outsideMetres, not outsideMeters.')
        elseif metres < 0 then
            complain(('Config.Match.serverChecks.outsideMetres is %.2f. A negative distance is read as 0, which is ZERO TOLERANCE: a fighter one centimetre past the fence is being counted as outside on that check.')
                :format(metres))
        end

        local ticks = Arena.ToInt(checks.outsideTicks)
        if checks.outsideTicks ~= nil and ticks == nil then
            complain(('Config.Match.serverChecks.outsideTicks is a %s, not a number -- it has fallen back to 8.')
                :format(type(checks.outsideTicks)))
        elseif ticks ~= nil and ticks < 1 then
            complain(('Config.Match.serverChecks.outsideTicks is %d, WHICH IS NOT AN OFF SWITCH. It is read as 1, the harshest setting there is: ONE sighting outside the fence removes a fighter from the round AND forfeits their stake, with no second look. deadTicks four lines below it DOES treat 0 as off, and these two do not agree. To stop the fence check, set Config.Match.serverChecks.enabled = false, or give the arena no boundary block.')
                :format(ticks))
        end

        local dead = Arena.ToInt(checks.deadTicks)
        if checks.deadTicks ~= nil and dead == nil then
            complain(('Config.Match.serverChecks.deadTicks is a %s, not a number -- it has fallen back to 4.')
                :format(type(checks.deadTicks)))
        elseif dead ~= nil and dead < 0 then
            complain(('Config.Match.serverChecks.deadTicks is %d. A negative count is read as 0, which switches the unreported-death half OFF entirely -- write 0 if that is what you meant.')
                :format(dead))
        end
    end

    local ceilingRaw = ((Config.Loadouts or {}).supplies or {}).totalItems
    local carryCeiling = Arena.ToInt(ceilingRaw)
    if ceilingRaw ~= nil and carryCeiling == nil then
        complain(('Config.Loadouts.supplies.totalItems is a %s, not a number -- it is read as 0, and 0 here means NO ceiling across all supplies together.')
            :format(type(ceilingRaw)))
    elseif carryCeiling ~= nil and carryCeiling < 0 then
        complain(('Config.Loadouts.supplies.totalItems is %d. A negative ceiling is read as 0, and 0 here means NO ceiling across all supplies together -- write the number of items you want carried, or 0 to remove the limit deliberately.')
            :format(carryCeiling))
    end

    if Config.Teams.allowUnequal == false then
        local rawAllowance = Config.Teams.maxTeamSizeDifference
        local allowance = Arena.ToInt(rawAllowance)
        -- `nil` IS THE DOCUMENTED DEFAULT and falls back to 1 on purpose, so
        -- only a value that was WRITTEN and cannot be read is worth saying
        -- anything about.
        if rawAllowance ~= nil and allowance == nil then
            complain(('Config.Teams.maxTeamSizeDifference is a %s, not a number -- it has fallen back to 1, so the sides may differ by one however wide or narrow you meant it to be.')
                :format(type(rawAllowance)))
        elseif allowance ~= nil and allowance < 0 then
            complain(('Config.Teams.maxTeamSizeDifference is %d. A negative allowance is read as 0 -- sides must be exactly equal. For no limit at all, set Config.Teams.allowUnequal = true.')
                :format(allowance))
        end
    end

    for _, mode in ipairs(Arena.GetEnabledModes()) do
        if mode.teams and #Arena.GetEnabledTeams() < 2 then
            complain(('Config.Modes["%s"] is a team mode but fewer than two teams are enabled.'):format(mode.key))
        end
    end

    -- A LADDER MODE THAT HAS NO LADDER, OR ONE THAT CANNOT BE READ.
    --
    -- Every layer below this one fails SOFT by design: a tier naming a
    -- weapon that is not enabled is dropped so one typo cannot disarm a
    -- lobby, a tier left empty goes with it, a ladder of fewer than two
    -- tiers is played as ordinary rules, and a number that will not parse
    -- falls back to something safe. Each of those is the right call in the
    -- moment and the wrong one over a whole config -- a gun game whose block
    -- was mistyped runs as an unlabelled free-for-all and nobody is told.
    -- That gap is what a start-up validator is for.
    for _, mode in ipairs(Arena.GetEnabledModes()) do
        local raw = (Config.Modes or {})[mode.key] or {}
        local declaresLadder = raw.gunGameTiers ~= nil or raw.gunGameClasses ~= nil

        -- AND NEVER BOTH. Arena.LadderTiersFor reads the classes and falls
        -- back to the flat list only when there are none, so a config with
        -- both has one of them doing nothing -- silently, and it is the one
        -- an operator is more likely to have just edited.
        if raw.gunGameTiers ~= nil and raw.gunGameClasses ~= nil then
            complain(('Config.Modes["%s"] sets BOTH gunGameClasses and gunGameTiers. The classes win and the flat list is ignored -- delete whichever one you did not mean to keep.')
                :format(mode.key))
        end

        if declaresLadder then
            local shapeWrong = (raw.gunGameTiers ~= nil and type(raw.gunGameTiers) ~= 'table')
                or (raw.gunGameClasses ~= nil and type(raw.gunGameClasses) ~= 'table')

            if shapeWrong then
                complain(('Config.Modes["%s"] declares a ladder that is not a table. gunGameClasses is a list of weapon classes; gunGameTiers is a list of tiers, weakest first, each one a list of weapon keys.')
                    :format(mode.key))
            else
                local playable = Arena.LadderTiersFor(mode.key)
                local listed = 0
                if type(raw.gunGameClasses) == 'table' then
                    for _, class in ipairs(raw.gunGameClasses) do
                        if type(class) == 'table' then
                            listed = listed + math.max(0, Arena.ToInt(class.tiers) or 0)
                        end
                    end
                elseif type(raw.gunGameTiers) == 'table' then
                    listed = #raw.gunGameTiers
                end

                if #playable < 2 then
                    complain(('Config.Modes["%s"] is enabled with %d tier(s) of the %d it lists actually playable -- a ladder needs at least two, so this mode will run as an ordinary free-for-all. Check the weapon keys against config.weapons.lua and that they are enabled.')
                        :format(mode.key, #playable, listed))
                else
                    if Arena.RoundSecondsFor(mode.key) <= 0 then
                        complain(('Config.Modes["%s"] climbs a ladder with no round clock -- nobody is eliminated in a ladder mode, so the round runs until somebody reaches the top tier however long that takes. Set roundTimeSeconds on the mode.')
                            :format(mode.key))
                    end

                    local seenOn = {}
                    for index, pool in ipairs(playable) do
                        for _, weapon in ipairs(pool) do
                            local first = seenOn[weapon.weapon]
                            if first ~= nil and first ~= index then
                                complain(('Config.Modes["%s"] can draw %s onto both tier %d and tier %d. Climbing between two tiers holding the same weapon is a promotion that changes nothing.')
                                    :format(mode.key, tostring(weapon.key), first, index))
                            end
                            seenOn[weapon.weapon] = seenOn[weapon.weapon] or index
                        end
                    end
                end

                if raw.teams == true then
                    complain(('Config.Modes["%s"] sets teams = true and climbs a ladder. A ladder is climbed and won by one player, so the sides decide nothing and only that one player is paid.')
                        :format(mode.key))
                end

                if raw.maxTiersPerVictim ~= nil then
                    local cap = Arena.ToInt(raw.maxTiersPerVictim)
                    if cap == nil then
                        complain(('Config.Modes["%s"].maxTiersPerVictim is %s, which is not a number -- the cap on how many tiers one killer may take off one opponent has fallen back to its default. 0 is how you remove it deliberately.')
                            :format(mode.key, type(raw.maxTiersPerVictim)))
                    elseif cap < 0 then
                        complain(('Config.Modes["%s"].maxTiersPerVictim is %d. A negative cap is not "no cap" -- write 0 for that -- and it has fallen back to its default.')
                            :format(mode.key, cap))
                    end
                end

                if raw.roundTimeSeconds ~= nil and Arena.ToInt(raw.roundTimeSeconds) == nil then
                    complain(('Config.Modes["%s"].roundTimeSeconds is %s, which is not a number -- the round is running on Config.Match.roundTimeSeconds instead.')
                        :format(mode.key, type(raw.roundTimeSeconds)))
                end

                local suppliesOff = ((Config.Loadouts or {}).supplies or {}).enabled ~= true
                if suppliesOff and (raw.killReward ~= nil or raw.startingKit ~= nil) then
                    complain(('Config.Modes["%s"] names supplies to hand out, but Config.Loadouts.supplies.enabled is off -- nobody carries any of it, and killReward and startingKit are both inert.')
                        :format(mode.key))
                end

                for _, field in ipairs({ 'killReward', 'startingKit' }) do
                    local list = raw[field]
                    if list ~= nil and not suppliesOff then
                        if type(list) ~= 'table' then
                            complain(('Config.Modes["%s"].%s is a %s. It has to be a list of { key = ..., count = ... } entries naming supplies from Config.Loadouts.supplies.items.')
                                :format(mode.key, field, type(list)))
                        else
                            local seen, named, total = {}, {}, 0

                            for index, reward in ipairs(list) do
                                if type(reward) ~= 'table' then
                                    complain(('Config.Modes["%s"].%s entry %d is a %s -- it has to be { key = ..., count = ... }, not a bare supply key.')
                                        :format(mode.key, field, index, type(reward)))
                                else
                                    local supply = Arena.SupplyByKey(reward.key)
                                    if not supply then
                                        complain(('Config.Modes["%s"].%s names the supply "%s", which is not an enabled entry in Config.Loadouts.supplies.items -- it is never handed over.')
                                            :format(mode.key, field, tostring(reward.key)))
                                    else
                                        local count = Arena.ToInt(reward.count)
                                        if count == nil or count <= 0 then
                                            complain(('Config.Modes["%s"].%s gives %s a count of %s -- nothing is handed over. Remove the entry if that is what you meant.')
                                                :format(mode.key, field, tostring(reward.key), tostring(reward.count)))
                                        elseif count > Arena.SupplyMax(supply) then
                                            complain(('Config.Modes["%s"].%s gives %d %s, over that supply\'s own max of %d -- it is clamped to the max.')
                                                :format(mode.key, field, count, tostring(reward.key), Arena.SupplyMax(supply)))
                                        end

                                        local capped = math.max(0, math.min(count or 0, Arena.SupplyMax(supply)))
                                        if named[supply.key] then
                                            if field == 'killReward' then
                                                complain(('Config.Modes["%s"].%s names the supply "%s" more than once. The lines share that supply\'s max of %d rather than getting one each -- write the amount you want on a single line.')
                                                    :format(mode.key, field, supply.key, Arena.SupplyMax(supply)))
                                            else
                                                complain(('Config.Modes["%s"].%s names the supply "%s" more than once. Only the last line counts -- the earlier ones are read and thrown away, so write the amount you want on a single line.')
                                                    :format(mode.key, field, supply.key))
                                            end
                                        end
                                        named[supply.key] = true

                                        -- COUNTED THE WAY THE FIELD'S OWN
                                        -- READER COUNTS IT. Summing every
                                        -- line reported a kit of
                                        -- {bandage 20, bandage 20} as 40
                                        -- against a ceiling of 30 while the
                                        -- server issued 20 -- a boot
                                        -- complaint about a config that
                                        -- fits.
                                        --
                                        -- A LINE THAT CAN NEVER PAY COSTS
                                        -- NOTHING either: `chance = 0` is the
                                        -- documented way to switch one kill
                                        -- reward off and `rolled` refuses it.
                                        -- killReward alone reads `chance` --
                                        -- a kit entry carrying one is issued
                                        -- regardless, and skipping it here
                                        -- would hide a kit that really is
                                        -- over the ceiling.
                                        if field == 'killReward' then
                                            local pays = reward.chance == nil
                                                or (Arena.ToInt(reward.chance) or 0) > 0
                                            if pays then
                                                local room = math.max(0, Arena.SupplyMax(supply) - (seen[supply.key] or 0))
                                                local paid = math.min(capped, room)
                                                seen[supply.key] = (seen[supply.key] or 0) + paid
                                                total = total + paid
                                            end
                                        else
                                            total = total - (seen[supply.key] or 0) + capped
                                            seen[supply.key] = capped
                                        end
                                    end

                                    if reward.chance ~= nil and Arena.ToInt(reward.chance) == nil then
                                        complain(('Config.Modes["%s"].%s gives %s a chance of %s, which is not a number -- it is never handed over. `chance` is a percentage; leave it out for every time.')
                                            :format(mode.key, field, tostring(reward.key), type(reward.chance)))
                                    end
                                end
                            end

                            local ceiling = Arena.SupplyTotalCap()
                            if ceiling > 0 and total > ceiling then
                                complain(('Config.Modes["%s"].%s adds up to %d items, over Config.Loadouts.supplies.totalItems of %d -- everything past the ceiling is dropped, %s.')
                                    :format(mode.key, field, total, ceiling,
                                        field == 'killReward'
                                            and 'in the order the entries are written'
                                            or 'in catalogue order'))
                            end
                        end
                    end
                end
            end
        end
    end

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

        -- A RAKE THAT IS NEVER TAKEN, and the operator has no way to tell.
        --
        -- houseCutPercent is applied by Arena.ComputePayouts, which only runs
        -- when the pot settles on its OWN. With betPayout.includeEntryPot on
        -- -- which is how this ships -- the entry fees are handed to the bet
        -- pool instead and ArenaBetting.Settle returns before ComputePayouts
        -- is reached, so the cut is not applied to anything. The round ends,
        -- the winner is paid the whole pool, and the console says nothing
        -- about a rake that did not happen.
        --
        -- NOT FIXED BY QUIETLY RAKING THE POOL, which is a different thing:
        -- a pool is the bettors' money and a cut off it takes a share of
        -- every spectator's stake as well as the fees. Which of those an
        -- operator wants is their decision, so this says the two settings
        -- disagree and names both, rather than picking one for them.
        local block = Config.Betting.betPayout
        local pooled = type(block) == 'table' and block.includeEntryPot == true

        if percent > 0 and pooled then
            complain(('Config.Betting.houseCutPercent is %d%% but betPayout.includeEntryPot is on, so NO CUT IS TAKEN: the entry fees become bets in the pool and the pot never settles on its own. Set includeEntryPot = false to rake the pot, or houseCutPercent = 0 to stop asking for a cut that is not collected.')
                :format(percent))
        end

        -- THE MULTIPLIER IS THE WHOLE PAYMENT, NOT THE PROFIT ON TOP OF IT.
        --
        -- Arena.ComputeSpectatorPayout returns stake x oddsMultiplier and the
        -- stake is INSIDE that number, so the break-even is 1.0 and not 0. It
        -- is the one setting in this file whose harmless-looking small number
        -- takes money off the person who was RIGHT: at 0.2 a winning 1,000 is
        -- paid 200, and at 0 the winner is paid nothing at all while the
        -- losers are no worse off. Nothing said so anywhere until here.
        --
        -- NAMED WHATEVER betPayout SAYS, because a number that is inert today
        -- is a trap on the day somebody switches a side to 'odds' -- but the
        -- message says which of those two it is, so an operator on 'pool' is
        -- not sent looking for a payout that never happened.
        --
        -- AND IT COMPLAINS RATHER THAN CLAMPING. DO NOT quietly read a value
        -- below 1.0 as 1.0: somebody who typed 0.2 meant a fifth of
        -- something, and this cannot tell whether they meant a fifth of the
        -- stake as profit or the rake that belongs in houseCutPercent.
        -- Guessing between those two moves a player's money on a guess.
        local oddsRaw = (Config.Betting.spectatorBets or {}).oddsMultiplier
        local odds = tonumber(oddsRaw)
        local payoutBlock = type(Config.Betting.betPayout) == 'table' and Config.Betting.betPayout or {}
        local onOdds = payoutBlock.fighters == 'odds' or payoutBlock.spectators == 'odds'
        local tail = onOdds
            and ' betPayout is set to \'odds\', so this is being paid out right now.'
            or ' Both halves of betPayout are on \'pool\', so nothing is paid at this number today -- it starts costing people the moment either one is set to \'odds\'.'

        if oddsRaw ~= nil and odds == nil then
            complain(('Config.Betting.spectatorBets.oddsMultiplier is a %s, not a number -- it has fallen back to 2.0.%s')
                :format(type(oddsRaw), tail))
        elseif odds ~= nil and odds <= 0 then
            complain(('Config.Betting.spectatorBets.oddsMultiplier is %s. A winning bet is then paid NOTHING -- the whole stake is kept and the winner ends up exactly where the losers do. This number is the TOTAL paid, stake included, so 1.0 hands the stake back and anything above 1.0 wins something.%s')
                :format(tostring(odds), tail))
        elseif odds ~= nil and odds < 1 then
            complain(('Config.Betting.spectatorBets.oddsMultiplier is %s. This number is the TOTAL paid, stake included, NOT the profit on top of it -- so anything below 1.0 CHARGES A WINNER FOR BEING RIGHT: a winning 1,000 is paid %d and the other %d of their own stake is kept. Write 1.0 to hand the stake back and nothing more, above 1.0 to pay a win, and use Config.Betting.houseCutPercent if a cut is what you wanted.%s')
                :format(tostring(odds), math.floor(1000 * odds), 1000 - math.floor(1000 * odds), tail))
        end

        local floorCount = Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0
        local smallest = math.max(2, Arena.ToInt(Config.Match.minPlayers) or 2)
        if floorCount > smallest and pooled then
            complain(('Config.Betting.minPlayersToPayOut is %d but betPayout.includeEntryPot is on, so IT IS NEVER CHECKED: the entry fees become bets in the pool and the pot never settles on its own, which is where the head count is read. A two-player match will pay out in full. Set includeEntryPot = false to enforce the threshold, or minPlayersToPayOut = 0 to stop asking for one that is not applied.')
                :format(floorCount))
        end
    end

    local lives = Config.Match.lives
    if type(lives) == 'table' then
        local minimum = Arena.ToInt(lives.min) or 1
        local maximum = Arena.ToInt(lives.max) or 1
        if minimum < 1 then
            complain('Config.Match.lives.min must be at least 1 -- a match nobody can lose is not a match.')
        end
        if maximum < minimum then
            complain('Config.Match.lives.max is below its min, so no host could pick a valid number.')
        end
        local fallback = Arena.ToInt(lives.default)
        if fallback and (fallback < minimum or fallback > maximum) then
            complain('Config.Match.lives.default sits outside min/max -- it will be clamped.')
        end
    elseif (Arena.ToInt(lives) or 0) < 1 then
        complain('Config.Match.lives must be at least 1.')
    end

    local chooser = (Config.Loadouts or {}).chooser
    if chooser ~= nil and chooser ~= 'host' and chooser ~= 'player' then
        complain(("Config.Loadouts.chooser is \"%s\" -- it must be 'host' or 'player'. Treating it as 'host'.")
            :format(tostring(chooser)))
    end

    local loadouts = Config.Loadouts or {}

    for _, gone in ipairs({ 'weaponSlots', 'meleeSlots' }) do
        if loadouts[gone] ~= nil then
            complain(('Config.Loadouts.%s is no longer read. Guns and melee now share '
                .. 'ONE count -- Config.Loadouts.slots -- and the player chooses the mix. '
                .. 'To switch a kind off, use allowFirearms / allowMelee.'):format(gone))
        end
    end

    local slots = loadouts.slots
    local slotsInt = Arena.ToInt(slots)
    if slots ~= nil and slotsInt == nil then
        complain(('Config.Loadouts.slots is "%s", which is not a whole number. Treating it as %d.')
            :format(tostring(slots), DEFAULT_SLOTS))
    elseif slotsInt ~= nil and slotsInt < 0 then
        complain(('Config.Loadouts.slots is %d. It cannot be negative; treating it as %d. '
            .. 'Zero means no limit.'):format(slotsInt, DEFAULT_SLOTS))
    end

    if loadouts.allowFirearms == false and loadouts.allowMelee == false then
        complain('Config.Loadouts.allowFirearms and allowMelee are BOTH false, so no player '
            .. 'can carry anything. Switch one back on.')
    end

    if loadouts.allowMelee == false then
        for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
            if weapon.category ~= 'melee' and Arena.IsMeleeWeapon(weapon) then
                complain(('Weapon "%s" is filed under "%s" but has no ammo ceiling, so it counts '
                    .. 'as melee -- and allowMelee is false, so nobody can take it. '
                    .. 'Give it an ammo.max, or file it under melee.')
                    :format(tostring(weapon.key), tostring(weapon.category)))
            end
        end
    end

    local logoStyle = Config.UI.logoStyle
    if logoStyle ~= nil and logoStyle ~= 'mark' and logoStyle ~= 'banner' then
        complain(("Config.UI.logoStyle is \"%s\" -- it must be 'mark' or 'banner'. Treating it as 'mark'.")
            :format(tostring(logoStyle)))
    end

    local schedule = Config.Schedule
    if type(schedule) == 'table' and schedule.enabled == true then
        local windows = type(schedule.windows) == 'table' and schedule.windows or {}
        local usable = 0

        for index, window in ipairs(windows) do
            if type(window) ~= 'table' then
                complain(('Config.Schedule.windows[%d] is not a pair of hours -- it needs '
                    .. '{ from = <hour>, to = <hour> }. Dropped.'):format(index))
            else
                local from = Arena.ToInt(window.from)
                local to = Arena.ToInt(window.to)

                if from == nil or from < 0 or from > 23 then
                    complain(('Config.Schedule.windows[%d] opens at %s -- an opening hour must be '
                        .. '0 to 23. Dropped rather than clamped: a clamped hour is a window '
                        .. 'nobody typed.'):format(index, tostring(window.from)))
                elseif to == nil or to < 0 or to > 24 then
                    complain(('Config.Schedule.windows[%d] shuts at %s -- a closing hour must be '
                        .. '0 to 24, where 0 and 24 both mean midnight. Dropped rather than '
                        .. 'clamped.'):format(index, tostring(window.to)))
                elseif from == to then
                    complain(('Config.Schedule.windows[%d] opens and shuts at the same hour (%d). '
                        .. 'That reads as "no time at all" and as "all day" equally well, so it '
                        .. 'is dropped rather than guessed. Delete the entry for no window, or '
                        .. 'write { from = 0, to = 24 } for all day.'):format(index, from))
                else
                    usable = usable + 1
                    if to < from then
                        complain(('Config.Schedule.windows[%d] runs %02d:00 to %02d:00, over '
                            .. 'midnight. That is legal, but it is far more often a from and a to '
                            .. 'written the wrong way round -- check it is what you meant.')
                            :format(index, from, to))
                    end
                end
            end
        end

        if #windows > 0 and usable == 0 then
            complain(('Config.Schedule.windows has %d entries and not one of them is usable, so '
                .. 'the arena is OPEN AT EVERY HOUR until one is.'):format(#windows))
        end
        if #windows == 0 then
            complain('Config.Schedule is enabled with no windows at all, so the arena never '
                .. 'shuts. Add a window, or set enabled = false.')
        end
        if usable > 0 and Arena.ScheduleLine() == nil then
            complain('Config.Schedule.windows covers every hour of the day, so the arena never '
                .. 'shuts. That is the same as switching hours off, and nothing will be refused.')
        end

        local offset = schedule.offsetHours
        if offset ~= nil and (Arena.ToInt(offset) == nil or math.abs(Arena.ToInt(offset)) > 14) then
            complain(('Config.Schedule.offsetHours is %s -- it must be a whole number of hours '
                .. 'between -14 and 14. Treating it as 0.'):format(tostring(offset)))
        end
    end

    return problems
end

function Arena.ReportConfigProblems()
    local problems = Arena.ValidateConfig()
    for _, problem in ipairs(problems) do
        warn('CONFIG: ' .. problem)
    end
    if #problems > 0 then
        warn(('CONFIG: %d problem(s) above. The resource is still running -- these are warnings, not failures.'):format(#problems))
    end
end
