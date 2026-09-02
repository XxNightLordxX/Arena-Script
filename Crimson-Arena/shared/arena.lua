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

--- Counts entries in a map-shaped table (`#` only works on arrays).
--- Coerces a size factor into something safe to multiply by. An arena never
--- shrinks: a factor under one would put spawns outside a floor built for
--- the full size, which is the one mistake here that is fatal.
--- How far a spawn is kept from the MIDDLE of a piece of cover, by default.
---
--- NOT minSeparation, and that distinction is the fix for a real defect.
--- Cover used to be excluded at the full player separation -- ten metres
--- from the centre of every barrier -- which took a 314 square-metre bite
--- out of the arena per piece. Twenty pieces did that to more than the whole
--- arena, so every placement fell through to the relaxation and NOBODY was
--- ever minSeparation apart, at any roster size.
---
--- MEASURED FROM THE PIECE'S ORIGIN, which is why it is not smaller still: a
--- shipping container is twelve metres long, so its own half-length is six.
--- Under that and a spawn "clear of the cover" is inside it, lengthwise,
--- with nowhere to walk to.
---
--- Unlike the separation between fighters this is never relaxed. A crowded
--- arena is a worse round; a spawn inside a wall is a player who cannot move.
local COVER_CLEARANCE = 7.0

--- What a weapon starts loaded with when its own config says nothing and the
--- operator has set no default. Thirty is a rifle magazine, and small enough
--- that it is never more than a player asked for on any shipped weapon.
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

--- The clearance this arena keeps around its cover.
---
--- Configurable because it depends on the props: an arena built out of
--- traffic cones wants less, one built out of shipping containers wants
--- exactly the default.
--- @param arenaKey any
--- @return number
function Arena.CoverClearance(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    local cover = type(arena) == 'table' and arena.cover or nil
    local configured = type(cover) == 'table' and tonumber(cover.clearance) or nil
    if configured and configured >= 0 then return configured end
    return COVER_CLEARANCE
end

--- The heading that lays a piece's LONG side across the radius rather than
--- along it -- side-on to the middle of the arena, which is what makes a ring
--- of containers a wall instead of a set of spokes.
---
--- WHY THIS IS A FUNCTION AND NOT A NUMBER TYPED INTO CONFIG. A heading turns
--- the model, and which way round the model is -- long side along its own X
--- or its own Y -- is a property of the prop, not of the arena. Get it wrong
--- by ninety degrees and every piece of a twenty-two segment wall turns to
--- point outwards, leaving a twelve-metre gap between each one. It is the
--- same class of number as the floor's tile spacing: knowable from inside the
--- game by measuring, and a guess from anywhere else.
---
--- The shipped ring was laid out by hand and had it both ways -- the four
--- pieces on the axes side-on, the four on the diagonals end-on -- which
--- nothing caught, because eight pieces twenty metres apart look like a ring
--- whichever way each one is turned.
---
--- HEADINGS HERE ARE GTA'S: degrees clockwise from north, so a piece's local
--- +X points along (cos h, -sin h) and its local +Y along (sin h, cos h).
--- @param dx number -- offset from the arena centre
--- @param dy number
--- @param longIsX boolean -- the model's long side runs along its own X
--- @return number heading -- degrees, 0-360
function Arena.TangentHeading(dx, dy, longIsX)
    local x, y = tonumber(dx) or 0.0, tonumber(dy) or 0.0

    -- Dead centre has no radius to be across, so nothing is turned.
    if x == 0.0 and y == 0.0 then return 0.0 end

    local phi = math.atan(y, x)
    local heading
    if longIsX == false then
        heading = math.deg(math.atan(-math.sin(phi), math.cos(phi)))
    else
        heading = math.deg(math.atan(-math.cos(phi), -math.sin(phi)))
    end

    heading = heading % 360.0
    if heading < 0.0 then heading = heading + 360.0 end
    return heading
end

--- @param factor number|nil
--- @return number
local function sizeFactor(factor)
    local value = tonumber(factor) or 1.0
    if value < 1.0 then return 1.0 end
    return value
end

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
-- load time. That is intentional: an operator editing config.lua -- or
-- config.weapons.lua, which is where the weapon catalogue lives -- and
-- restarting the resource gets the new list, and there is no second copy
-- that can drift out of sync with the first.
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

--- Whether a player may type their own ammunition amount rather than being
--- held to the preset list.
---
--- Read from ONE place by both ends. The panel decides whether to show the
--- box by asking this, and the server decides whether to honour what comes
--- back by asking this -- so a panel offering a box the server refuses, or a
--- server accepting a value no box could produce, is not expressible.
---
--- Per weapon first, then the global switch. A server can allow typed
--- amounts everywhere and still pin one weapon to its presets.
--- @param weapon table? -- a Config.Loadouts.weapons entry
--- @return boolean
function Arena.AllowsCustomAmmo(weapon)
    if type(weapon) == 'table' and weapon.allowCustomAmmo ~= nil then
        return weapon.allowCustomAmmo == true
    end
    return Config.Loadouts.allowCustomAmmo == true
end

--- Turns whatever a client asked for into an ammo count the server is
--- willing to hand out.
---
--- THE RULE, in order:
---   1. A weapon with a fixed `options` list only ever gets a value FROM
---      that list -- UNLESS `Config.Loadouts.allowCustomAmmo` is on, which
---      turns the list from the only legal values into suggested presets and
---      an off-list request is clamped into [0, max] instead.
---
---      With it OFF an off-list request falls back to the default rather
---      than being rounded, because "closest" would let a modified client
---      walk a value up past a preset by asking for one just above it.
---      Clamping to `max` is not that: `max` is the ceiling either way, so
---      allowing a custom amount widens what a player may ASK for and moves
---      the ceiling not at all.
---   2. A weapon with no `options` list is a free-form ammo weapon: the
---      request is clamped into [0, max].
---   3. Anything non-numeric gets the default.
--- @param weapon table
--- @param requested any -- straight off the wire; may be anything
--- @return integer ammo
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

        -- Off the list. Whether that is a request or a refusal is the one
        -- thing allowCustomAmmo decides, and `max` is the ceiling in both
        -- cases -- so this widens what may be ASKED for and nothing else.
        if Arena.AllowsCustomAmmo(weapon) then
            return Arena.ClampInt(wanted, 0, maximum) or default
        end
        return default              -- rule 1: off-list is refused, not rounded
    end

    return Arena.ClampInt(wanted, 0, maximum) or default
end

--- Whether a weapon is melee, which is the one distinction this resource
--- draws between kinds of weapon. It decides two things: that the weapon
--- takes no ammunition choice of any sort, and that it is counted against
--- `Config.Loadouts.meleeSlots` rather than `weaponSlots`.
---
--- EITHER test is enough. `category = 'melee'` is the honest declaration and
--- what an operator should write, but a weapon whose ammo ceiling is one round
--- is a bat whatever it was filed under, and treating it as a firearm would
--- offer a player an ammunition dropdown for a knife.
--- @param weapon table -- a Config.Loadouts.weapons entry
--- @return boolean
function Arena.IsMeleeWeapon(weapon)
    if type(weapon) ~= 'table' then return false end
    if weapon.category == 'melee' then return true end

    local ammo = weapon.ammo
    local maximum = type(ammo) == 'table' and (Arena.ToInt(ammo.max) or 0) or 0
    return maximum <= 1
end

-- ======================================================================
-- AMMO TYPES
--
-- BUILT FOR A CUSTOM AMMO SCRIPT, not just for MK II magazines.
--
-- GTA's own special rounds -- incendiary, hollow-point, armour-piercing, FMJ,
-- tracer -- exist only on MK II weapons, and only as weapon COMPONENTS. If
-- that is all you run, give an ammo type a `component` and this resource
-- attaches it; the client already applies components, so nothing else has to
-- change.
--
-- Most servers running ammo types do it differently: an inventory item, a
-- metadata field, a value their own script reads. So an ammo type may ALSO
-- carry an `item`, and every grant fires a configurable server event with the
-- weapon, the chosen type and the amount. Your script listens once and does
-- whatever it does. That hook is what makes this work on ANY weapon rather
-- than the four Rockstar shipped magazines for.
--
-- THE LIST APPLIES TO EVERY WEAPON THAT TAKES AMMO. Set it once in
-- `Config.Loadouts.defaultAmmoTypes` and it is offered for all of them;
-- override it on a single weapon by giving that weapon its own `ammoTypes`;
-- switch it off for one weapon with `ammoTypes = false`. Melee is excluded
-- automatically -- a knife has nothing to load.
-- ======================================================================

--- The ammo types on offer for one weapon: its own list, or the shared
--- default, or none.
--- @param weapon table -- a Config.Loadouts.weapons entry
--- @return table[] types -- { { key, label, component, item } }
function Arena.GetAmmoTypes(weapon)
    if type(weapon) ~= 'table' then return {} end

    -- An explicit `false` is an operator saying "not this one", and has to
    -- beat the shared default.
    if weapon.ammoTypes == false then return {} end

    local list = weapon.ammoTypes
    if type(list) ~= 'table' then
        -- Melee never inherits the shared list: it is not carrying
        -- ammunition, it is carrying a bat.
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
                -- Both optional, and independent. `component` is a GTA MK II
                -- magazine; `item` is whatever your own script calls this
                -- round. A type may carry neither and still be meaningful --
                -- the grant event names it either way.
                component = Arena.IsKey(entry.component) and entry.component or nil,
                item = Arena.IsKey(entry.item) and entry.item or nil,
            }
        end
    end
    return out
end

--- Every item name any ammo type in the catalogue can hand out, deduplicated.
---
--- This is the set the server reconciles a player's inventory against on the
--- way out of an arena. It has to include types on weapons an operator has
--- since disabled, and items only reachable through a per-weapon override --
--- a round somebody is carrying does not stop mattering because the weapon
--- that fired it was switched off mid-session.
--- @return table<string, boolean> items
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

--- Turns whatever ammo type a client asked for into one this server is
--- willing to load.
---
--- Same posture as ResolveAmmo: an unknown or disabled key is REFUSED back to
--- the default rather than guessed at, so shortening a list genuinely removes
--- that round from the arena. A weapon with no types resolves to nil, and nil
--- is a valid answer meaning "whatever this weapon loads normally".
--- @param weapon table
--- @param requested any -- straight off the wire; may be anything
--- @return table|nil type -- { key, label, component, item }
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

--- What a weapon starts LOADED with, when the rest of the rounds a player
--- picked are handed over as inventory items instead.
---
--- WHY THIS EXISTS. Picking sixty rounds used to put sixty in the magazine
--- AND hand over sixty loose rounds on top -- a hundred and twenty for a
--- player who asked for sixty, on every weapon, every round. The magazine and
--- the items were written by two different loops and neither knew the other
--- had already issued the whole amount.
---
--- So the pick is a TOTAL now, and this says where the split falls: this many
--- in the gun, the remainder in their pocket. A player is never handed an
--- empty gun, and never handed twice what they chose.
---
--- WHERE THE NUMBER COMES FROM, in order:
---   1. `magazine` on the weapon, for an operator who wants to say it outright.
---   2. THE SMALLEST AMOUNT THAT WEAPON'S OWN LIST OFFERS. Not invented: it is
---      the operator's own idea of a small quantity of this round, and it is
---      already sitting in the config next to the weapon. Every one of the 78
---      firearms this resource ships has one -- 30 for most, 4 for the
---      launchers -- so nothing needs adding to use this.
---   3. Config.Loadouts.ammoItems.defaultMagazine, for a weapon with no list
---      at all.
---
--- Never more than the player actually picked: asking for ten rounds gets ten
--- in the gun and none in the pocket, not a full magazine conjured out of a
--- default.
--- @param weapon table|nil -- the catalogue entry for this weapon
--- @param rounds any -- the total the player picked
--- @return integer loaded
function Arena.MagazineFor(weapon, rounds)
    -- Every branch below clamps to this, so a pick of zero comes back zero
    -- without needing a guard of its own -- and a guard nothing can break is
    -- a guard nobody can trust.
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

--- @return table
local function suppliesConfig()
    return (Config.Loadouts or {}).supplies or {}
end

--- Every supply an operator has left switched on, in config order.
--- @return table[]
function Arena.GetEnabledSupplies()
    local out = {}
    for _, entry in ipairs(suppliesConfig().items or {}) do
        if type(entry) == 'table' and entry.enabled ~= false and Arena.IsKey(entry.key) then
            out[#out + 1] = entry
        end
    end
    return out
end

--- The most of one supply a player may carry in.
--- @param supply table
--- @return integer
function Arena.SupplyMax(supply)
    if type(supply) ~= 'table' then return 0 end
    return math.max(0, Arena.ToInt(supply.max) or 0)
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
    if config.enabled ~= true then return out end

    -- With choosing switched off for supplies the whole request is ignored
    -- and everybody carries the operator's defaults.
    local wanted = requested
    if config.allowChoose == false then wanted = nil end

    local asked = {}
    for _, entry in ipairs(type(wanted) == 'table' and wanted or {}) do
        if type(entry) == 'table' and Arena.IsKey(entry.key) then
            asked[entry.key] = Arena.ToInt(entry.count)
        end
    end

    -- 0 MEANS NO CEILING, which is why this is tracked as "is there one"
    -- plus a remaining count rather than as a number that means both.
    local capped = (Arena.ToInt(config.totalItems) or 0) > 0
    local remaining = capped and Arena.ToInt(config.totalItems) or 0

    for _, supply in ipairs(Arena.GetEnabledSupplies()) do
        local maximum = Arena.SupplyMax(supply)
        -- The operator's own default is what a player who chose nothing
        -- carries, and it is clamped to that supply's own ceiling rather
        -- than trusted -- a default above `max` is a typo, not a licence.
        local fallback = Arena.ClampInt(supply.default, 0, maximum) or 0

        local count = fallback
        if wanted ~= nil and asked[supply.key] ~= nil then
            count = Arena.ClampInt(asked[supply.key], 0, maximum) or 0
        end

        -- CLAMPED EVEN WHEN THERE IS NOTHING LEFT, which is the whole
        -- difference between a ceiling and a suggestion. Reading "is there
        -- budget" as "is the remaining count above zero" stopped clamping
        -- the moment it hit zero, so the first supply took the whole
        -- allowance and every one after it was unbounded -- a ceiling of
        -- three handing out nine.
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
--- all still succeeds, empty-handed. A player who sends rubbish gets a bad
--- match, not a stuck lobby. The one thing it will not do is exceed
--- `weaponSlots` or hand out a weapon that is not in the enabled catalogue.
--- @param request table? -- { weapons = { { key = string, ammo = any }, ... }, supplies = { { key = string, count = any }, ... } }
--- @return table loadout -- { weapons = { { weapon = string, ammo = integer, components = table, tint = integer } }, armor = integer, health = integer, supplies = { { key, label, item, count } } }
--- @return string[] rejected -- keys that were dropped, for logging/telemetry
function Arena.ResolveLoadout(request)
    local rejected = {}
    local resolved = {}
    local seen = {}

    -- TWO SEPARATE ALLOWANCES, deliberately. With one shared count a player
    -- who wants a knife spends a rifle slot on it, so nobody ever takes one
    -- and the whole melee list is decoration. Counting them apart means a
    -- loadout is "two guns and a blade" rather than "any three things".
    local slots = Arena.ToInt(Config.Loadouts.weaponSlots) or 1
    if slots < 0 then slots = 0 end

    -- Absent rather than zero means "the operator has not thought about it",
    -- and one blade is the sane answer -- zero would silently remove every
    -- melee weapon from an arena whose config still lists them.
    local meleeSlots = Arena.ToInt(Config.Loadouts.meleeSlots)
    if meleeSlots == nil then meleeSlots = 1 end
    if meleeSlots < 0 then meleeSlots = 0 end

    -- 0 means no cap. A player may otherwise take a different round for every
    -- weapon they carry, which on a server with fifteen types is a lot of
    -- inventory churn per match.
    local typeCap = Arena.ToInt(Config.Loadouts.ammoTypeSlots) or 0
    if typeCap < 0 then typeCap = 0 end

    local usedFirearm, usedMelee = 0, 0
    local typesTaken, distinctTypes = {}, 0

    local source = request
    local wanted = (type(source) == 'table' and type(source.weapons) == 'table') and source.weapons or {}

    for _, entry in ipairs(wanted) do
        -- Not a break: a melee weapon further down the list is still takeable
        -- once the firearm slots are full, and vice versa. Breaking here would
        -- make the answer depend on the order the panel happened to send.
        if usedFirearm >= slots and usedMelee >= meleeSlots then break end

        do
            local key = type(entry) == 'table' and entry.key or entry
            local weapon = Arena.GetWeaponByKey(key)

            if not weapon then
                rejected[#rejected + 1] = tostring(key)
            elseif seen[weapon.key] then
                -- Asking for the same gun twice would otherwise burn two slots
                -- for one weapon and silently short-change the player.
                rejected[#rejected + 1] = weapon.key
            elseif Arena.IsMeleeWeapon(weapon) and usedMelee >= meleeSlots then
                -- Their melee allowance is spent. Rejected by name rather
                -- than dropped silently, so the panel can say which one did
                -- not make it in.
                rejected[#rejected + 1] = weapon.key
            elseif not Arena.IsMeleeWeapon(weapon) and usedFirearm >= slots then
                rejected[#rejected + 1] = weapon.key
            else
                if Arena.IsMeleeWeapon(weapon) then
                    usedMelee = usedMelee + 1
                else
                    usedFirearm = usedFirearm + 1
                end

                -- KEYED BY CATALOGUE KEY, which is the only spelling a
                -- request can be resolved under: `key` is what the panel and
                -- the wire send, and GetWeaponByKey is what turns it into an
                -- entry. A second write under the GTA name would be a key
                -- nothing ever reads.
                seen[weapon.key] = true
                local ammoType = Arena.ResolveAmmoType(weapon, type(entry) == 'table' and entry.ammoType or nil)

                -- Over the distinct-type cap: fall back to whatever this
                -- weapon's default is rather than refusing the weapon. Losing
                -- a gun because of an ammunition preference would be a
                -- surprising way to be told about a limit.
                if ammoType and typeCap > 0 and not typesTaken[ammoType.key] and distinctTypes >= typeCap then
                    ammoType = Arena.ResolveAmmoType(weapon, nil)
                end
                if ammoType and not typesTaken[ammoType.key] then
                    typesTaken[ammoType.key] = true
                    distinctTypes = distinctTypes + 1
                end

                -- Copied, never appended to in place: `weapon.components` is
                -- the operator's own table on the live config, and pushing a
                -- player's chosen clip into it would leak that choice into
                -- every later loadout for everybody.
                local components = {}
                for _, component in ipairs(type(weapon.components) == 'table' and weapon.components or {}) do
                    components[#components + 1] = component
                end
                if ammoType and ammoType.component then
                    components[#components + 1] = ammoType.component
                end

                resolved[#resolved + 1] = {
                    key = weapon.key,
                    weapon = weapon.weapon,
                    label = weapon.label or weapon.key,
                    ammo = Arena.ResolveAmmo(weapon, type(entry) == 'table' and entry.ammo or nil),
                    -- Carried for the panel's summary and the match log; the
                    -- component itself is already in `components`.
                    ammoType = ammoType and ammoType.key or nil,
                    ammoTypeLabel = ammoType and ammoType.label or nil,
                    ammoTypeItem = ammoType and ammoType.item or nil,
                    components = components,
                    tint = Arena.ToInt(weapon.tint) or 0,
                }
            end
        end
    end

    local health, armor = Arena.StartingVitals()
    return {
        weapons = resolved,
        -- CONSTANTS, not resolved from anything. See Arena.StartingVitals:
        -- what you start a life on is a rule of the arena, and neither a
        -- config edit nor a crafted payload gets a say in it. They are still
        -- carried on the loadout so the client has one thing to read.
        armor = armor,
        health = health,
        supplies = Arena.ResolveSupplies(type(source) == 'table' and source.supplies or nil),
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

--- A prop and its stand-ins, as a list to try in order.
---
--- FALLBACKS EXIST BECAUSE A MODEL NAME IS JUST A STRING until the game is
--- asked, and the first floor model shipped in this file was one I had
--- remembered rather than looked up. It did not exist, and an arena whose
--- floor model does not exist is an arena with no floor.
---
--- The name is checked against the game's own object list by a spec now, so
--- that particular mistake cannot recur -- but a name being real is not the
--- same as a name being on THIS server: a build without a DLC, or an
--- operator who has stripped assets, has fewer objects than the list does.
--- So each prop names a chain, and the client uses the first one the game
--- actually gives it.
---
--- Accepts either spelling, so a single `model = 'x'` stays valid.
--- @param entry table -- anything with `models` and/or `model`
--- @return string[]
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

--- THE FLOOR AN ARENA BRINGS WITH IT.
---
--- An arena in the sky has nothing under it, so it carries its own surface:
--- one prop model tiled into a disc, spawned when a fighter walks in and
--- deleted when they walk out.
---
--- TILED RATHER THAN LISTED, because a hand-written list of two hundred prop
--- coordinates is not something an operator can resize. `radius` and
--- `tileSize` are the two numbers that describe it, and this works the rest
--- out.
--- @param arenaKey any
--- @return table|nil -- { models, model, tileSize, radius, z, maxTiles }
function Arena.GetPlatform(arenaKey, factor)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return nil end

    local platform = arena.platform
    if type(platform) ~= 'table' or platform.enabled == false then return nil end

    local grow = sizeFactor(factor)

    local models = Arena.ModelChain(platform)
    if #models == 0 then return nil end

    -- tileSize is a FALLBACK now, not the answer: the client measures the
    -- model with GetModelDimensions and tiles on what is really there. It
    -- still has to be sane, because a client that cannot load the model at
    -- all has nothing to measure.
    local tileSize = tonumber(platform.tileSize) or 0
    local radius = tonumber(platform.radius) or 0
    if tileSize <= 0 or radius <= 0 then return nil end
    radius = radius * grow

    return {
        -- The chain, and the first of it under the old name so nothing that
        -- only wants "which prop is this" has to know about fallbacks.
        models = models,
        model = models[1],
        tileSize = tileSize,
        radius = radius,
        -- THE SURFACE, not where the pieces are created. The client lowers
        -- each piece by the prop's own measured height so its top lands on
        -- this number, which is what makes the walkable height a thing an
        -- operator sets rather than a thing they discover.
        z = tonumber(platform.z) or 0.0,
        -- 0 means no ceiling. See Arena.PlatformTiles.
        --
        -- GROWN WITH THE AREA, and by the SQUARE of the factor, because a
        -- floor is a disc and a disc's area goes up with the square of its
        -- radius. A ceiling that did not grow would cap a scaled-up arena
        -- back to the piece count of a small one -- which does not make it
        -- smaller, it makes it a small floor with a big spawn ring hanging
        -- off the edge.
        maxTiles = math.floor((tonumber(platform.maxTiles) or 0) * grow * grow),
    }
end

--- Every point one platform's pieces go, worked out from its two numbers.
---
--- A DISC, not a square: the boundary is a sphere and a square floor would
--- put its corners outside it, so a fighter standing in one would be bleeding
--- while still on solid ground.
---
--- TWO THINGS HERE ARE NOT OBVIOUS AND BOTH WERE WRONG.
---
--- 1. THE GRID IS PER AXIS. A shipping container is twelve metres one way
---    and two and a half the other. Spacing both axes on the larger number
---    -- which is what taking max(width, depth) does -- lays the pieces out
---    with ten-metre holes between them, and a floor with holes in it is a
---    floor people fall through. Each axis gets its own step.
---
--- 2. A TILE IS KEPT ON ITS NEAREST CORNER, not its centre. Keeping tiles
---    whose CENTRE is inside the radius leaves the diagonals bare: with a
---    forty-metre prop and a forty-five-metre radius, the point at (32, 32)
---    is inside the arena and inside no tile. Asking whether the closest
---    point of the tile is within reach covers the disc exactly, because
---    every point in it then falls inside some tile that was kept.
--- @param platform table -- Arena.GetPlatform output
--- @param measured table|number|nil -- the prop's real size, when the client
---        has asked the game for it: { x = width, y = depth, top = height
---        above its own origin }. A bare number is read as a square prop.
---        Beats the configured guess, which is only a fallback for a model
---        that will not load -- and nobody can get it right by hand.
--- @return table[] -- { { x, y, z }, ... }, absolute
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

    -- THE FLOOR IS HUNG FROM ITS SURFACE, not stood on its base.
    --
    -- `platform.z` is where people STAND. The piece is lowered by its own
    -- height so its top lands exactly there, whichever prop out of the chain
    -- the client got and whatever shape it is.
    --
    -- The other way round -- placing the piece at a configured Z and working
    -- the surface out afterwards -- is what this used to do, and it put the
    -- walkable surface at "1200 plus however tall that prop happens to be".
    -- Every cover piece, which is positioned from the spawn centre in
    -- config, was then buried that far under the floor.
    local z = platform.z - top

    local out = {}
    -- Far enough out that a tile still overlapping the edge is generated
    -- before it is tested.
    local stepsX = math.ceil((reach + sizeX * 0.5) / sizeX)
    local stepsY = math.ceil((reach + sizeY * 0.5) / sizeY)
    for ix = -stepsX, stepsX do
        for iy = -stepsY, stepsY do
            local x, y = ix * sizeX, iy * sizeY
            -- The closest point of this tile to the middle of the arena.
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

    -- A CEILING ON THE PIECE COUNT, because the fallback prop decides it.
    -- A floor tiled out of shipping containers needs a few hundred pieces
    -- where one tiled out of a stunt block needs nine, and several hundred
    -- objects per client per round is where the game starts to suffer.
    -- The middle is kept and the rim is dropped, so what is lost is the
    -- outside edge rather than a hole under somebody's feet.
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

--- THE COVER AN ARENA BRINGS WITH IT: barriers, blocks, crates.
---
--- A plain list rather than anything generated, because cover is the one
--- part of an arena that is a design decision. Where a barrier goes decides
--- how the ground is fought over, and no formula knows that -- so this is
--- laid out by hand and moved by hand.
---
--- Positions are OFFSETS from the arena's spawn-area centre, so `z = 0` is
--- standing on the floor and a piece can be nudged without recomputing a
--- world coordinate.
--- @param arenaKey any
--- @return table[] -- { { model, x, y, z, heading }, ... }, offsets
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
                -- THE ONE OFFSET THAT IS NOT SCALED, and it is what makes a
                -- stacked piece work: `z` is how far the piece stands above
                -- the one below it, in metres of prop. A container is 2.6m
                -- tall on a small arena and 2.6m tall on a large one, so
                -- growing this would lift the top of every stack into the
                -- air by however much the arena grew.
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

    -- The centre everything is measured from. The spawn area when there is
    -- one, the boundary otherwise -- an arena can define cover without
    -- scattering its spawns.
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
                -- WHICH PIECES ARE THE FLOOR, and the client counts them
                -- separately for it. Without this the only question it could
                -- ask was "did ANYTHING get built", and an arena whose floor
                -- model is missing but whose barriers are not answers yes --
                -- then drops everybody into a kilometre of air past a check
                -- that exists to stop exactly that.
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
            -- CARRIED THROUGH RATHER THAN RESOLVED HERE. Turning a piece to
            -- face across the arena needs to know which way round the model
            -- is -- long side along its own X or its own Y -- and that is a
            -- measurement only the client can take. See Arena.TangentHeading.
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

--- How far above and below the surface a sweep looks. Cover stands on the
--- floor and the floor hangs below it, so the pieces occupy a band around the
--- walkable height rather than a plane.
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

    -- The same centre Arena.ArenaProps builds around, worked out the same
    -- way. Two places deriving one coordinate separately is how a sweep comes
    -- to look somewhere the floor is not.
    local centre = Arena.GetSpawnArea(arenaKey, factor)
    if not centre then
        local arena = Arena.GetArenaByKey(arenaKey)
        local boundary = type(arena) == 'table' and type(arena.boundary) == 'table'
            and arena.boundary.center or nil
        if not Arena.IsPoint(boundary) then return nil end
        centre = { x = tonumber(boundary.x) or 0.0, y = tonumber(boundary.y) or 0.0,
                   z = tonumber(boundary.z) or 0.0 }
    end

    -- EVERY MODEL IN EVERY CHAIN, not just the one this build loaded. The
    -- piece left behind may have been created by a client that fell further
    -- down the chain than this one will, and a sweep that only knows its own
    -- answer walks straight past it.
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

--- The lowest Z a fighter may legitimately be placed at in this arena, or
--- nil where the ground answers that question.
---
--- FOR AN ARENA THAT CARRIES ITS OWN FLOOR. There is nothing under it but a
--- kilometre of air, so a spawn Z below the floor is not a near miss -- it is
--- a fighter placed underneath the arena, falling, with the boundary killing
--- them a second later and no way to tell why. That is a typo an operator
--- makes once and cannot diagnose, so it is caught rather than trusted.
--- @param arenaKey any
--- @return number|nil
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

    -- Arena.IsPoint on every branch, because config writes all three of
    -- these as vectors and a vector is not a 'table' in this runtime. Tested
    -- for one, all three said no for every arena that ships -- so this
    -- returned nil, nothing pointed the streamer, and a spectator watching
    -- the arena a kilometre over the water saw empty sky. Which is the exact
    -- symptom this function was added to fix.
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

--- Whether an arena's spawn Z is exact, rather than a hint to search from.
---
--- THE ONE THING THAT WOULD SILENTLY BREAK AN ARENA IN THE SKY. The client
--- places a fighter by asking GetGroundZFor_3dCoord, which searches DOWNWARD
--- for terrain -- so a spawn a kilometre up finds the real map far below,
--- reports success, and teleports every fighter out of the arena onto the
--- ground. Nothing about that reads as an error at either end.
---
--- With this on, the configured Z is used exactly and no search is made.
--- @param arenaKey any
--- @return boolean
function Arena.UsesExactSpawnZ(arenaKey)
    local arena = Arena.GetArenaByKey(arenaKey)
    return type(arena) == 'table' and arena.exactSpawnZ == true
end

--- HOW MUCH BIGGER THIS ARENA IS FOR THIS MATCH.
---
--- The radii in config describe an arena sized for a small round. Twenty
--- fighters in the same circle is not the same game: `minSeparation` stops
--- being satisfiable, the placement quietly relaxes it (see scatterWithin),
--- and everybody opens the round inside somebody else's sights.
---
--- So the arena grows with the roster, and one number does all of it. Every
--- radius is multiplied by the same factor, which is the point: the
--- relationships an operator set up between the spawn area, the floor and
--- the boundary are the arena's design, and scaling them independently would
--- quietly break the two that keep people alive -- spawns inside the floor,
--- and the floor inside the boundary.
---
--- Returns 1.0 for an arena that does not ask to grow, which is every arena
--- that shipped before this existed.
--- @param arenaKey any
--- @param players integer|nil
--- @return number factor -- always >= 1.0
function Arena.SizeFactor(arenaKey, players)
    local arena = Arena.GetArenaByKey(arenaKey)
    if type(arena) ~= 'table' then return 1.0 end

    local scale = arena.scale
    if type(scale) ~= 'table' or scale.enabled ~= true then return 1.0 end

    local count = Arena.ToInt(players) or 0
    local baseline = Arena.ToInt(scale.baseline) or 6
    local extra = math.max(0, count - baseline)
    if extra == 0 then return 1.0 end

    -- Written as metres per fighter rather than as a multiplier, because
    -- metres are what an operator can picture. Converted here against the
    -- arena's own size, so the same setting means the same thing whether the
    -- arena is thirty metres across or a hundred.
    local area = arena.spawnArea
    local base = (type(area) == 'table' and tonumber(area.radius)) or 0
    if base <= 0 then return 1.0 end

    local perPlayer = tonumber(scale.perPlayer) or 0
    if perPlayer <= 0 then return 1.0 end

    local factor = 1.0 + (extra * perPlayer) / base
    local ceiling = math.max(1.0, tonumber(scale.maxGrowth) or 2.0)
    return math.min(factor, ceiling)
end

--- The spawn AREA an arena defines, if it defines one.
---
--- `spawns` is a list of exact points; `spawnArea` is one point and a radius,
--- and the arena works out the rest. An operator who only wants to drop a
--- marker in the middle of a field and say "a hundred metres around here"
--- should not have to write out twenty coordinates to do it.
--- @param arenaKey any
--- @param factor number|nil -- growth from Arena.SizeFactor; 1.0 or nil asks for the size the operator typed
--- @return table|nil
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

    return {
        x = x, y = y, z = z,
        radius = radius,
        -- Never allowed to exceed the radius itself: a separation bigger than
        -- the area it has to fit inside cannot be satisfied by any placement,
        -- and the relaxation below would just grind through every attempt
        -- before giving up.
        minSeparation = math.max(0.0, math.min(tonumber(area.minSeparation) or 10.0, radius)),
        -- HOW CLOSE TWO PEOPLE ON THE SAME SIDE MAY LAND, which is a
        -- different question from how close two enemies may.
        --
        -- `minSeparation` used to answer both, and answering both is what
        -- made it untrue: on the shipped skydome, whose cover fills most of
        -- a 16m team circle, teammates were coming out FOUR METRES apart
        -- against a stated ten, because the placement relaxed its way down
        -- rather than admit it could not hold the number.
        --
        -- The honest split is that the ten was never about teammates.
        -- Landing together IS a team spawn, and a fighter four metres from
        -- their own side is exactly where they want to be -- what matters is
        -- that nobody lands INSIDE anybody, which is a body's width and a
        -- step, not ten metres. So this is its own number with its own
        -- promise, and unlike the enemy gap it is not relaxed on the way
        -- down.
        mateSeparation = math.max(0.0, math.min(
            tonumber(area.mateSeparation) or math.min(tonumber(area.minSeparation) or 10.0, 4.0),
            radius)),
        -- How tightly a team lands together. Defaults to a quarter of the
        -- area, which reads as "same corner of the field" rather than "same
        -- square metre".
        -- MULTIPLIED, LIKE THE RADIUS. `radius` above already carries the
        -- growth, so a teamRadius read from config has to be grown to match
        -- or a bigger arena lands each team in the same small huddle it did
        -- before -- which is the crowding this exists to fix, moved rather
        -- than solved. The default is a quarter of the area, and the area is
        -- already grown, so that branch needs nothing.
        teamRadius = tonumber(area.teamRadius)
            and math.max(1.0, tonumber(area.teamRadius) * grow)
            or math.max(1.0, radius * 0.25),
    }
end

--- Squared distance, because nothing here needs the square root -- it is
--- only ever compared against another distance.
local function distanceSquared(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
end

--- THE HEADING THAT LOOKS AT (centreX, centreY) FROM (x, y).
---
--- ONE FORMULA IN ONE PLACE, AND IT WAS NINETY DEGREES OUT IN BOTH OF THE
--- TWO PLACES IT USED TO LIVE. A GTA heading is degrees clockwise from
--- north, so a ped at heading h faces (-sin h, cos h) -- and the maths angle
--- of a direction, which is what atan gives back, is measured
--- anticlockwise from east. The two differ by a quarter turn, and neither
--- copy subtracted it: every fighter placed at the edge of a spawn circle
--- was turned side-on to the arena, looking along the rim, with the fight
--- ninety degrees to their left. Both copies carried a comment promising
--- the opposite, which is why it survived so long.
---
--- Checked rather than reasoned about: the forward vector this returns dots
--- to +1.000 with the direction to the centre, and spawnplan_spec asserts
--- exactly that.
--- @return number heading -- degrees, GTA convention
local function facingCentre(centreX, centreY, x, y)
    local toCentre = math.deg(math.atan(centreY - y, centreX - x))
    return (toCentre - 90.0 + 360.0) % 360.0
end

--- One random point inside a disc, uniformly.
---
--- sqrt() ON THE RADIUS, and it is not decoration: sampling the distance
--- uniformly instead crowds points towards the middle, because the area of a
--- ring grows with its radius. On a spawn circle that reads as everybody
--- landing in a heap around the centre with the edges empty.
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

--- Places `count` players inside a circle, no two closer than `separation`.
---
--- ALWAYS TERMINATES, and that is the whole design. A fixed number of tries
--- per player, then the separation is relaxed and they are tried again; the
--- last round accepts whatever it is given. A placement loop that can spin
--- forever on a crowded arena is worse than one that occasionally puts two
--- players a little close together, because the first one hangs the match
--- How many points to try per round before asking for less room.
---
--- IT WAS TWELVE, AND TWELVE WAS THE REASON THE SEPARATION WAS NOT KEPT.
--- Placement is rejection sampling: throw a dart, keep it if it is far
--- enough from everything already placed. As the arena fills, the share of
--- the disc that still qualifies shrinks, so twelve darts start missing --
--- and a miss here does not report anything, it quietly asks for less room
--- and tries again. Four fighters in an arena with plenty of space for them
--- were coming out under the stated separation once in every seventy
--- rounds, for no reason but bad luck.
---
--- This is one calculation per match, before anybody is placed, on a few
--- dozen points. Being generous with it costs nothing anybody can measure
--- and it is the difference between a rule and a preference.
local SAMPLES_PER_ROUND = 96

--- How much of the theoretical packing limit rejection sampling can really
--- reach. A perfect hexagonal lattice is not something darts thrown at a
--- disc produce, and asking for the full bound makes every placement fall
--- through to the relaxation -- which is the failure this whole file exists
--- to stop doing quietly.
local PACKING_EFFICIENCY = 0.80

--- How many places one team anchor is drawn from before the furthest is
--- kept. Cheap -- it runs once per team per match, on a handful of points --
--- and the difference between "random" and "random and far apart".
local ANCHOR_CANDIDATES = 32

--- THE LARGEST GAP THIS MANY PEOPLE CAN ACTUALLY BE GIVEN IN THIS CIRCLE.
---
--- WHY THIS EXISTS AT ALL, and it is the difference between a rule that is
--- kept and a rule worth keeping. `minSeparation` is one number in config,
--- and one number cannot be right for both ends of the roster: four
--- fighters on the shipped skydome were being placed ten metres apart in a
--- circle that could have given them twenty-six, and twenty-four fighters
--- were being asked for the same ten in a circle where ten is already close
--- to the packing limit. The rule was kept perfectly at every size and it
--- was the wrong rule -- everybody opened the round inside somebody's
--- sights, which is exactly what an operator reports as "you get shot the
--- moment you spawn".
---
--- So the ask is not a constant. Hexagonal packing fits `count` points at
--- spacing `s` into a disc of radius `R` while count <= (2pi/sqrt 3)(R/s)^2;
--- solved for `s` and scaled by what sampling can really reach, that is the
--- most room this roster can have. `minSeparation` stops being the target
--- and becomes the FLOOR: the distance below which a placement has failed
--- rather than merely been crowded.
--- @param radius number
--- @param count integer
--- @return number
local function achievableSeparation(radius, count)
    if count <= 1 then return radius end
    return PACKING_EFFICIENCY * radius * math.sqrt((2.0 * math.pi / math.sqrt(3.0)) / count)
end

--- What two placements have to keep between them.
---
--- THREE DIFFERENT ANSWERS, and collapsing them into one is what the old
--- single `separation` did. A piece of cover keeps its own clearance and
--- never relaxes -- no amount of crowding makes spawning inside a wall
--- acceptable. A TEAMMATE only has to not be stood inside: landing near your
--- own side is the point of having one. Anybody else is an enemy, and that
--- is the distance worth spending the arena on.
--- @param other table -- something already placed
--- @param team string|nil -- the side being placed now; nil in a free-for-all
--- @param mate number
--- @param enemy number
--- @return number
local function needBetween(other, team, mate, enemy)
    if other.clearance then return other.clearance end
    -- `team` is nil in a free-for-all, where everybody is an enemy -- so this
    -- deliberately does not fire on two nils.
    if team ~= nil and other.team == team then return mate end
    return enemy
end

--- start and the second is survivable.
---
--- THE RELAXATION HAPPENS IN TWO STAGES NOW, and the stages mean different
--- things. The first gives back the ENEMY gap -- the ambitious number,
--- worked out from what the circle can hold -- down to `rules.mate`, which
--- is the operator's own `minSeparation` and the point at which a placement
--- has stopped being generous and started being wrong. Only after that does
--- it give up the floor as well, and only on the last round, because a
--- placement loop that cannot terminate is worse than two players standing
--- close together.
--- @param rules table -- { mate = number, floor = number, enemy = number }
--- @param team string|nil -- the side being placed; nil in a free-for-all
--- @return table[] points
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

        -- NOT A BLIND DRAW. The old fallback took one random point, which on
        -- a crowded arena is where a fighter opens the round inside somebody
        -- else's sights -- the exact complaint the separation above exists
        -- to answer, arriving through the back door on the placements that
        -- needed it most. Sampling and keeping the point whose nearest enemy
        -- is furthest costs one more pass and cannot be worse than one dart.
        if not chosen then
            local bestScore
            for _ = 1, SAMPLES_PER_ROUND do
                local candidate = sampleDisc(rng, area, centreX, centreY, radius)
                -- EVERY PLACED PLAYER, not only the enemies. This is the
                -- draw taken when nothing fitted, so it is also the only
                -- thing standing between two teammates and the same square
                -- metre -- scoring enemies alone would keep somebody clear
                -- of the other side by stacking them on their own.
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
        -- TAGGED WITH WHOSE SIDE THEY ARE ON, so the next team placed sees
        -- them as an enemy and keeps the wider distance. Without this every
        -- pair after the first team would be measured by the same number and
        -- the whole point of two separations would be lost.
        chosen.team = team
        placed[#placed + 1] = chosen
        out[#out + 1] = chosen
    end

    return out
end

--- WHERE EACH TEAM OPENS, drawn at random and then chosen for being far
--- from the other teams.
---
--- IT USED TO BE A FIXED PATTERN. Anchors were spaced evenly around the
--- circle at a random rotation, which is a ring of k points rotated -- so
--- every team match had the same shape and only its orientation changed, and
--- on two teams that meant "directly opposite", every single round. Drawing
--- them instead makes the whole arena the answer, and scoring them keeps the
--- property the fixed pattern was there for.
---
--- Maximin, the same rule PickRespawn uses: each anchor after the first is
--- the candidate whose NEAREST existing anchor is furthest away. Not the one
--- furthest from their average -- an average is happily satisfied by landing
--- between two of them.
--- @param rng fun():number
--- @param area table
--- @param count integer -- how many teams
--- @param spread number -- the radius each team scatters over
--- @return table[] anchors -- { x, y, z, w }
local function pickAnchors(rng, area, count, spread)
    -- Pulled in from the edge by exactly what each side spreads over, so a
    -- team's own scatter stays inside the arena.
    local reach = math.max(0.0, area.radius - spread)
    local anchors = {}

    for index = 1, count do
        local best, bestScore
        for _ = 1, ANCHOR_CANDIDATES do
            -- ON THE RIM OF THE REACH CIRCLE, at a random angle, rather than
            -- anywhere inside it. Two teams drawn from the whole disc can
            -- both land near the middle, and then no amount of scoring can
            -- put them far apart -- measured, a four-player team match came
            -- out at fifteen metres where the old fixed pattern gave
            -- twenty-two. The rim is where the distance is, and the angle is
            -- what makes it random: teams still never open in the same place
            -- twice, and the middle of the arena is nobody's ground at the
            -- start of a round, which is what a team match wants anyway.
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

--- Works out where every player in a roster starts.
---
--- ONE ANSWER FOR THE WHOLE ROSTER, not one per player as they walk in.
--- Keeping two players apart is a fact about the pair, so it cannot be
--- decided by looking at either of them alone -- which is why this takes the
--- roster and returns a plan rather than answering `where does this player
--- go` one call at a time.
---
--- Free-for-all scatters everybody across the area. A team mode gives each
--- team its own anchor, spaced evenly around the circle at a random rotation
--- so the same team does not always start in the same corner, and lands that
--- team's players around their own anchor -- together, and away from the
--- others.
---
--- @param arenaKey any
--- @param roster table[] -- { { src = number, team = string|nil }, ... }
--- @param rng fun():number|nil -- injectable; defaults to math.random
--- @return table<number, table>|nil plan -- src -> { x, y, z, w }, or nil when
---         the arena defines no spawn area and the point list should be used
function Arena.PlanSpawns(arenaKey, roster, rng, factor)
    local area = Arena.GetSpawnArea(arenaKey, factor)
    if not area or type(roster) ~= 'table' or #roster == 0 then return nil end

    rng = rng or math.random

    -- Grouped in ENCOUNTER ORDER rather than by sorting the keys, so the plan
    -- for a given roster and a given rng is reproducible: a test that cannot
    -- predict which team gets which corner cannot assert anything about them.
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

    -- COVER IS AN OBSTACLE, NOT SCENERY, as far as placing people goes.
    --
    -- scatterWithin already refuses a point too close to anything in
    -- `placed`, which is how two fighters are kept apart. Seeding it with the
    -- arena's own walls and barriers makes the same rule keep them out of
    -- those -- otherwise a random spawn inside a shipping container is only a
    -- matter of time, and from inside one there is nowhere to walk to.
    local placed = {}
    local clearance = Arena.CoverClearance(arenaKey)
    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        -- ITS OWN CLEARANCE, MUCH SMALLER THAN A PLAYER'S. A barrier is
        -- three metres wide; keeping ten metres from the middle of one --
        -- which is what happened when cover shared minSeparation -- excluded
        -- a 314 square-metre disc per piece. Twenty pieces did that to more
        -- than the whole arena, so EVERY placement fell through to the
        -- relaxation below and nobody was ever minSeparation apart, at any
        -- roster size. The number that matters here is "not standing inside
        -- it", and that is a couple of metres.
        placed[#placed + 1] = {
            x = area.x + piece.x,
            y = area.y + piece.y,
            clearance = clearance,
        }
    end

    -- FREE FOR ALL, or a team mode nobody has picked a side in yet.
    if #order == 1 and order[1] == '\0ffa' then
        local roll = byTeam['\0ffa']

        -- EVERYBODY IS AN ENEMY HERE, so the gap between any two of them is
        -- the one worth spending the circle on. Asked for as much as the
        -- circle can give this many people, floored at what the operator
        -- wrote: four fighters get the twenty-six metres a 35m circle can
        -- hold rather than the ten a config line happened to name.
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

    -- TEAMS. An anchor per side, drawn at random and kept for being far from
    -- the other sides, then that side's players scattered around it.
    --
    local anchors = pickAnchors(rng, area, #order, area.teamRadius)

    -- THE ENEMY GAP IS WORKED OUT ON THE WHOLE ROSTER, not per team. It is
    -- the distance between two people on opposite sides, and both of them
    -- are standing in the same circle -- so what limits it is how many
    -- bodies are in that circle altogether.
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
            -- The team faces the middle together rather than each player
            -- facing wherever their own sample happened to land.
            point.w = anchor.w
            plan[entry.src] = point
        end
    end

    return plan
end

--- How many points to sample before picking the one furthest from trouble.
---
--- SIXTEEN WAS TOO FEW, AND IT WAS MEASURED RATHER THAN ARGUED. Maximin can
--- only pick the best of what it drew, so the size of the draw IS the
--- guarantee. Over three thousand respawns into a twenty-four player skydome
--- the worst return at sixteen candidates was 10.1m from a live opponent --
--- inside a rifle's first burst, and the whole complaint this function
--- exists to answer. At forty-eight it is 18.1m, and nothing lands inside
--- twelve at any roster size.
---
---     candidates   worst gap (n=24)   returns under 12m
---     16           10.1m              0.03%
---     32           14.6m              0
---     48           18.1m              0
---     64           17.1m              0
---
--- Sixty-four buys nothing over forty-eight, which is where the curve flattens
--- and where this sits. It costs one bounded loop over a few dozen points,
--- once, when somebody dies.
local RESPAWN_CANDIDATES = 48

--- How many times one respawn candidate is redrawn to get it out of a wall.
---
--- BOUNDED, because an arena CAN be built with no clear ground left in it and
--- a respawn that never returns is a fighter who never comes back. After this
--- many tries the last sample is taken as it is: standing on a barrier is a
--- bad respawn, and not respawning at all is a broken round.
local COVER_RETRIES = 12

--- Coerces one position into { x, y, z }, or nil.
---
--- Accepts what the callers actually hold: a vector3 from the engine, a
--- table with named fields, or a plain array. A position that cannot be read
--- is dropped rather than defaulted to the origin -- an unreadable enemy at
--- 0,0,0 would drag every respawn towards the far side of the map.
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

--- Where to put a player who has just lost a life.
---
--- RANDOM, AND AWAY FROM WHOEVER KILLED THEM. The respawn used to walk the
--- arena's point list with a cursor -- so a player came back at the next
--- point along, which is predictable, and which on a small list is where
--- they died a moment ago. Coming back inside somebody's crosshair is not a
--- respawn, it is a second death with extra steps.
---
--- The rule is maximin: sample the area, then take the candidate whose
--- NEAREST threat is furthest away. Not the one furthest from the average --
--- an average is happily satisfied by landing between two enemies.
---
--- `avoid` is whoever must be kept away from, which is the caller's decision
--- and not this function's: on a team mode it is the other side only,
--- because coming back near your own team is the point of having one.
---
--- An empty `avoid` is not an error and not a fallback to the old cursor: it
--- is a round where nobody is left to avoid, and the answer is still a random
--- point rather than a predictable one.
---
--- `prefer` is the other half of the same question in a team mode: coming
--- back away from the enemy is only half a respawn if it also drops you
--- alone on the far side of the arena from your own side. Given teammates to
--- head for, the choice is made among the candidates that ALREADY clear the
--- enemy gap -- so being near your team can never cost you the distance from
--- the people shooting at you.
--- @param arenaKey any
--- @param teamKey any -- the returning player's side, for the team point list
--- @param avoid table[]|nil -- positions to stay away from
--- @param rng fun():number|nil -- injectable; defaults to math.random
--- @param factor number|nil -- how much bigger the arena is for this match
--- @param prefer table[]|nil -- teammates' positions, to come back near
--- @return table|nil point -- { x, y, z, w }, or nil when the arena has neither
---         a spawn area nor any points to choose from
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

    -- THE ARENA'S OWN WALLS, WHICH THIS USED TO WALK STRAIGHT INTO.
    --
    -- Arena.PlanSpawns has always seeded its rejection list with every cover
    -- piece, so nobody is ever placed into a container at the START of a
    -- round. This function did none of it: it drew candidates from the disc
    -- and scored them on distance from the nearest live opponent, with no
    -- term for the scenery at all. On the shipped skydome that is 78 cover
    -- pieces, a third of them standing inside the spawn disc, so a fighter
    -- could and did come back inside a shipping container -- with nowhere to
    -- walk to.
    --
    -- It reads as the arena being broken in exactly the way the entry spawns
    -- were reported broken, which is why it went unnoticed: the first spawn
    -- of the round was fixed and looked right, and every one after it was
    -- rolling dice.
    local blocked = {}
    local clearance = Arena.CoverClearance(arenaKey)
    for _, piece in ipairs(Arena.GetCover(arenaKey, factor)) do
        blocked[#blocked + 1] = { x = piece.x, y = piece.y }
    end

    --- Is this candidate standing in a piece of cover?
    --- @param point table
    --- @param centreX number
    --- @param centreY number
    --- @return boolean
    local function insideCover(point, centreX, centreY)
        for _, piece in ipairs(blocked) do
            local dx = point.x - (centreX + piece.x)
            local dy = point.y - (centreY + piece.y)
            if (dx * dx + dy * dy) < (clearance * clearance) then return true end
        end
        return false
    end

    -- THE CANDIDATES. An arena with an area gets fresh random points; one
    -- with only a point list gets the list, which is every choice there is.
    local candidates = {}
    local area = Arena.GetSpawnArea(arenaKey, factor)
    if area then
        -- SAMPLED UNTIL THEY ARE CLEAR, not filtered afterwards. Filtering a
        -- fixed draw shrinks the pool the threat scoring then chooses from,
        -- and on a crowded arena can empty it -- so a rejected sample is
        -- REPLACED, up to a bounded number of tries, and the count of usable
        -- candidates stays the same whatever the cover looks like.
        for _ = 1, RESPAWN_CANDIDATES do
            local point
            for _ = 1, COVER_RETRIES do
                point = sampleDisc(rng, area, area.x, area.y, area.radius)
                if not insideCover(point, area.x, area.y) then break end
            end
            candidates[#candidates + 1] = point
        end
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
            candidates[#candidates + 1] = list[((offset + step - 1) % #list) + 1]
        end

        -- A HAND-WRITTEN LIST IS THE OPERATOR'S CHOICE and is never thinned:
        -- these are points somebody placed on purpose, and dropping one
        -- because a barrier is near it can leave nothing to return at all.
        -- Cover clearance is for points this file INVENTED.
    end

    if #candidates == 0 then return nil end

    -- AND CLEAR GROUND BEATS OPEN GROUND, whatever the threat scoring says.
    --
    -- The redraw above makes a blocked candidate rare rather than impossible,
    -- because it is bounded -- an arena with no clear ground left has to
    -- return SOMETHING. So the choice is made in two tiers: a candidate
    -- standing in a wall is only ever picked when every other one is too.
    -- Being far from an enemy is worth nothing from inside a container.
    local clear = {}
    if area then
        for _, candidate in ipairs(candidates) do
            if not insideCover(candidate, area.x, area.y) then
                clear[#clear + 1] = candidate
            end
        end
    end
    local pool = #clear > 0 and clear or candidates

    if #threats == 0 then
        -- Nobody to avoid. Still random: on an area the first sample already
        -- is, and on a list the offset above made it one.
        return pool[1]
    end

    --- How far the nearest live opponent is from a point, squared.
    --- @param candidate table
    --- @return number
    local function threatGap(candidate)
        local nearest = math.huge
        for _, threat in ipairs(threats) do
            local gap = distanceSquared(candidate, threat)
            if gap < nearest then nearest = gap end
        end
        return nearest
    end

    -- A GAP TO CLEAR, NOT ONLY A GAP TO MAXIMISE.
    --
    -- Maximin alone answers "the best of what I drew", and on a crowded
    -- arena the best of what it drew can still be close enough to be shot
    -- before the screen has finished fading in. So the candidates are first
    -- filtered by the same distance the ENTRY placement asks for -- what
    -- this many people can actually be given in this circle -- and the
    -- maximin below then runs on the survivors. When nothing clears it the
    -- filter is dropped rather than the respawn refused: the best available
    -- point is still the best available point.
    local safe = pool
    if area then
        local wanted = math.max(area.minSeparation,
            achievableSeparation(area.radius, #threats + 1))
        local qualified = {}
        for _, candidate in ipairs(pool) do
            if threatGap(candidate) >= wanted * wanted then qualified[#qualified + 1] = candidate end
        end
        if #qualified > 0 then safe = qualified end
    end

    -- WITH A SIDE TO REJOIN, the choice among those is the one nearest a
    -- teammate. Only ever among candidates that already cleared the gap
    -- above, so this cannot trade away the distance it was chosen for.
    if #friends > 0 and #safe > 1 then
        local best, bestScore = nil, math.huge
        for _, candidate in ipairs(safe) do
            local nearest = math.huge
            for _, friend in ipairs(friends) do
                local gap = distanceSquared(candidate, friend)
                if gap < nearest then nearest = gap end
            end
            if nearest < bestScore then best, bestScore = candidate, nearest end
        end
        if best then return best end
    end

    local best, bestScore = nil, -1
    for _, candidate in ipairs(safe) do
        local nearest = threatGap(candidate)
        -- Strictly greater, so the first of several equally distant
        -- candidates wins -- and the first is already a random one.
        if nearest > bestScore then best, bestScore = candidate, nearest end
    end

    return best
end

-- ======================================================================
-- BETTING MATHS
--
-- Integer money throughout. Every split below distributes the remainder
-- rather than dropping it, so the sum of what is paid out always equals
-- the net pot exactly -- a pot that leaks a few dollars per match is the
-- kind of bug nobody reports and everybody notices.
-- ======================================================================

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

--- Whether a match runs a radar, resolved from what the host asked for.
---
--- A MATCH SETTING, NOT A PERSONAL ONE. It used to be a per-player toggle
--- in the lobby, which made it a setting each fighter could give themselves
--- -- so a round was only as dark as its least patient player. It is the
--- host's now: one decision, taken once, that everybody in that match
--- fights under.
---
--- Unlike ResolveLives this never refuses. There is no out-of-range for a
--- boolean, and a host who sent one to a server where `allowChoose` is off
--- is a stale panel rather than a tampered payload -- the control it came
--- from is not even drawn there. Falling back to the operator's default is
--- the honest answer to that; an error would be a match that will not open
--- because of a checkbox nobody can see.
--- @param requested any
--- @return boolean radar
--- @return nil reason -- always; kept so callers read like ResolveLives
function Arena.ResolveRadar(requested)
    local radar = (Config.Match or {}).radar
    if type(radar) ~= 'table' then return false, nil end

    local fallback = radar.defaultOn == true
    if radar.allowChoose ~= true then return fallback, nil end
    if requested == true or requested == false then return requested, nil end
    return fallback, nil
end

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

--- One side-bet band, checked.
---
--- SHARED BY THE TWO KINDS BECAUSE THEY ARE THE SAME CHECK ON DIFFERENT
--- SETTINGS, and collapsing them into one function that always read the
--- spectator block was a real defect: config.lua gives fighterBets its own
--- `enabled`, its own `min` and its own `max`, the panel is sent all three,
--- and the server enforced the spectator ones. Shipped, that refused every
--- fighter stake between 25,001 and the 50,000 the panel was offering; and
--- with spectatorBets switched off -- a combination config documents,
--- since fighterBets has its own switch -- it refused every fighter bet
--- outright, with a message about side-bets being off.
--- @param rules table|nil -- Config.Betting.fighterBets or .spectatorBets
--- @param requested any
--- @param disabledReason string
--- @return integer|nil stake
--- @return string|nil reasonKey
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

--- A FIGHTER'S OWN STAKE, held to the fighter band rather than the
--- spectator one. Config.Betting.fighterBets has its own enabled/min/max,
--- and the panel is told all three -- so this is the function that makes
--- what the panel offers and what the server accepts the same numbers.
--- @param requested any
--- @return integer|nil stake
--- @return string|nil reasonKey
function Arena.ResolveFighterBet(requested)
    return resolveBetBand(Config.Betting.fighterBets, requested, 'error.fighter_bets_disabled')
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

--- A team's panel colour as three 0-255 channels.
---
--- ONE SOURCE FOR EVERY PLACE A TEAM IS COLOURED. The team already carries a
--- hex `color` for the panel, so the outline drawn round a teammate in the
--- world is derived from it rather than configured separately -- which is
--- what makes "the same colour as on the map" true by construction instead
--- of by an operator keeping two fields in step.
---
--- Accepts '#rgb' and '#rrggbb', with or without the hash. Anything else
--- returns nil, and the caller falls back rather than drawing a wrong
--- colour confidently.
--- @param hex any
--- @return integer|nil r
--- @return integer|nil g
--- @return integer|nil b
function Arena.HexToRgb(hex)
    if type(hex) ~= 'string' then return nil end

    local body = hex:gsub('^#', '')
    if #body == 3 then
        -- '#c12' is the same colour as '#cc1122'; doubling each digit is the
        -- standard reading and not an approximation.
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

    -- Nobody staked anything measurable, so proportion means nothing and an
    -- even split is the only honest reading.
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

--- The spawn area of an arena at its configured size, for the validator.
--- Separate from Arena.GetSpawnArea only so the intent is obvious: a check
--- about what an operator TYPED must not be reading a scaled copy of it.
--- @param arenaKey any
--- @return table|nil
local function arenaSpawnAreaOf(arenaKey)
    return Arena.GetSpawnArea(arenaKey, 1.0)
end

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
    if #Arena.GetEnabledWeapons() == 0 then
        complain('Config.Loadouts has no enabled weapon -- players would spawn empty-handed.')
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

            --- Every height in this arena has to agree with the surface.
            --- @param where string
            --- @param z any
            local function checkHeight(where, z)
                local value = tonumber(z)
                if not value then return end
                if value < surface - 0.5 then
                    complain(('Config.Arenas["%s"].%s is at %.2f, BELOW the platform surface at %.2f -- a fighter placed there is under the arena.')
                        :format(entry.key, where, value, surface))
                elseif value > surface + 5.0 then
                    complain(('Config.Arenas["%s"].%s is at %.2f, %.2f above the platform surface at %.2f -- that is a fall when the countdown ends.')
                        :format(entry.key, where, value, value - surface, surface))
                end
            end

            local area = arenaSpawnAreaOf(entry.key)
            if type(area) == 'table' then
                checkHeight('spawnArea.center.z', area.z)

                -- A FLOOR SMALLER THAN THE RING OF SPAWNS ON IT.
                --
                -- The one geometry mistake that builds successfully and is
                -- still fatal: the arena comes up, the floor check passes
                -- because pieces really were created, and everybody who does
                -- not draw the middle spawn is placed over open air.
                --
                -- Found by fuzzing junk into the radius -- 0.5 leaves half a
                -- metre of floor under a thirty-five metre spawn ring -- but
                -- the realistic version is a dropped digit.
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
                checkHeight('boundary.center.z', raw.boundary.center and raw.boundary.center.z)

                -- THE BOUNDARY HAS TO CONTAIN THE FLOOR.
                --
                -- A floor that reaches past the sphere is solid ground you
                -- bleed on: you walk to the edge of the platform, still
                -- standing on it, and start dying for it. That does not read
                -- as a boundary, it reads as the arena being broken -- and it
                -- shipped that way, with a 60m sphere around a floor that
                -- reached 77.
                --
                -- The floor is TILED, so it reaches further than
                -- platform.radius: a tile is kept whenever its NEAREST corner
                -- is inside that radius, which puts its FAR corner up to a
                -- whole tile diagonal beyond.
                --
                -- MEASURED BY TILING IT, not by a formula. The first version
                -- of this used `radius + tileSize * 0.708`, which is half a
                -- diagonal -- exactly half of what a kept tile can reach --
                -- so it stayed silent on a 60m sphere around a floor reaching
                -- 77, which is the arena its own comment cites as the reason
                -- it exists. Laying the tiles out and taking the furthest
                -- corner is not an approximation, and it also gets `maxTiles`
                -- right for free: a ceiling that trims the outer ring makes
                -- the floor genuinely smaller, and a formula would warn about
                -- ground that is not there.
                if raw.boundary.enabled == true then
                    local tile = math.max(0.0, tonumber(platform.tileSize) or 0)

                    -- THE CLOSED FORM FIRST, and it is exact for an untrimmed
                    -- floor. The furthest a kept tile can sit is with its
                    -- NEAREST corner exactly on the radius along the
                    -- diagonal, which puts its FAR corner one whole tile
                    -- diagonal beyond -- radius + tile * sqrt(2).
                    local reach = platform.radius + tile * math.sqrt(2)

                    -- AND THE REAL TILING WHEN IT IS CHEAP TO LAY OUT,
                    -- because the formula is only an upper bound. The last
                    -- ring rarely sits exactly on the diagonal, and
                    -- `maxTiles` can trim it away entirely -- both make the
                    -- floor genuinely smaller than radius + tile * sqrt(2),
                    -- and warning about ground that is not there sends an
                    -- operator to widen a boundary that already fits.
                    --
                    -- BUT THE TILING IS O(radius / tileSize) SQUARED, and
                    -- tileSize is an operator setting: a typo of 0.01 asks
                    -- for eighty billion cells and hangs the SERVER AT BOOT,
                    -- inside the validator written to catch typos. The
                    -- resource's own junk-value fuzz found that within a
                    -- minute of this being written.
                    --
                    -- So the cell count is worked out with arithmetic first
                    -- and the layout only done when it is small. Above the
                    -- ceiling the bound stands, which over-states the floor
                    -- and therefore only ever warns too eagerly -- the safe
                    -- direction, on a config that is already nonsense.
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
                        -- THE MEASURED PROP CAN BE BIGGER THAN tileSize, and
                        -- this cannot know: `tileSize` is what the client
                        -- falls back to when it cannot measure the model, and
                        -- a build whose floor prop is four times that tiles
                        -- four times as far out. So the number here is a
                        -- FLOOR on the real reach, never a ceiling, and the
                        -- message says so rather than quoting it as fact.
                        complain(('Config.Arenas["%s"] has a %.2fm boundary around a floor that reaches at least %.2fm at the configured tileSize of %.2fm -- the outer ring of the platform is solid ground OUTSIDE the arena, and standing on it bleeds you. A floor prop that measures larger than tileSize reaches further still.')
                            :format(entry.key, sphere, reach, tile))
                    end
                end
            end
        end
    end

    -- A team mode is enabled but no team is.
    for _, mode in ipairs(Arena.GetEnabledModes()) do
        if mode.teams and #Arena.GetEnabledTeams() < 2 then
            complain(('Config.Modes["%s"] is a team mode but fewer than two teams are enabled.'):format(mode.key))
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

        -- THE SIBLING NO-OP, and it is the same shape exactly.
        --
        -- minPlayersToPayOut is read in one place -- Arena.ComputePayouts --
        -- and ComputePayouts only runs when the pot settles on its own. With
        -- the entry fees folded into the pool, ArenaBetting.Settle returns
        -- before it, so the head count is never consulted. An operator who
        -- raises this to stop two friends farming each other watches two
        -- friends farm each other, with the setting sitting there saying it
        -- is switched on.
        --
        -- NOT ENFORCED INSIDE THE POOL PATH INSTEAD. Refusing to settle a
        -- pool is a decision about other people's SIDE-BETS, not about the
        -- fees, and it is the operator's to make -- the same argument the
        -- rake above is left alone for.
        -- ONLY WHEN IT WOULD EVER HAVE REFUSED ONE. The shipped value is 2,
        -- which is also the smallest match this server will start, so it can
        -- never turn a payout down and losing it costs nothing. Warning about
        -- that is noise on a working default, and noise in a start-up report
        -- is how a real complaint gets scrolled past. An operator who raises
        -- it above the minimum roster is asking for refusals they will not
        -- get, and that is worth a line.
        local floorCount = Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0
        local smallest = math.max(2, Arena.ToInt(Config.Match.minPlayers) or 2)
        if floorCount > smallest and pooled then
            complain(('Config.Betting.minPlayersToPayOut is %d but betPayout.includeEntryPot is on, so IT IS NEVER CHECKED: the entry fees become bets in the pool and the pot never settles on its own, which is where the head count is read. A two-player match will pay out in full. Set includeEntryPot = false to enforce the threshold, or minPlayersToPayOut = 0 to stop asking for one that is not applied.')
                :format(floorCount))
        end
    end

    -- Two shapes are legal here: a plain number, which fixes the count for
    -- every match, or a table the host picks from within.
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

    -- A typo here is silent otherwise: the panel falls back to 'mark' and an
    -- operator who wrote 'Banner' sees their full lockup drawn as a badge
    -- the size of a fingernail and concludes the setting does nothing.
    local chooser = (Config.Loadouts or {}).chooser
    if chooser ~= nil and chooser ~= 'host' and chooser ~= 'player' then
        complain(("Config.Loadouts.chooser is \"%s\" -- it must be 'host' or 'player'. Treating it as 'host'.")
            :format(tostring(chooser)))
    end

    local logoStyle = Config.UI.logoStyle
    if logoStyle ~= nil and logoStyle ~= 'mark' and logoStyle ~= 'banner' then
        complain(("Config.UI.logoStyle is \"%s\" -- it must be 'mark' or 'banner'. Treating it as 'mark'.")
            :format(tostring(logoStyle)))
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
