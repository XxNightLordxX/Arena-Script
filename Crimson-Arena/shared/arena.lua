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

    if Config.Loadouts.allowChoose == false then return fallback end
    if not Arena.IsKey(requested) then return fallback end

    for _, entry in ipairs(types) do
        if entry.key == requested then return entry end
    end
    return fallback
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

    -- With choosing switched off the request is ignored entirely and the
    -- operator's `fixed` list is what everybody gets.
    local source = request
    if Config.Loadouts.allowChoose == false then
        source = { weapons = Config.Loadouts.fixed or {}, armor = nil }
    end

    local wanted = (type(source) == 'table' and type(source.weapons) == 'table') and source.weapons or {}

    for _, entry in ipairs(wanted) do
        -- Not a break: a melee weapon further down the list is still takeable
        -- once the firearm slots are full, and vice versa. Breaking here would
        -- make the answer depend on the order the panel happened to send.
        if usedFirearm >= slots and usedMelee >= meleeSlots then break end

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

                -- BOTH SPELLINGS, because the two loops speak different ones:
                -- a picked weapon is known by its catalogue key, and the
                -- `alwaysGive` guard below has only the GTA name to test with.
                seen[weapon.key] = true
                seen[weapon.weapon] = true
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

    -- `alwaysGive` is appended AFTER the slot limit is applied, on purpose:
    -- it is the operator's own list, not the player's, and it should not be
    -- possible to spend your slots in a way that denies you the house knife.
    -- A CATALOGUE KEY IS RESOLVED, A RAW WEAPON NAME IS TAKEN AS WRITTEN.
    --
    -- This used to gate on `entry.weapon` alone and never look at the weapon
    -- list, so the obvious way to write the operator's own line --
    --     { key = 'knife' }
    -- was skipped in silence, and the form that DID work produced a weapon
    -- labelled 'WEAPON_KNIFE', in no category, paired with no ammunition,
    -- because every one of those fields lives in the catalogue entry it never
    -- read.
    --
    -- Now a `key` is looked up and the real entry is inherited -- label,
    -- category, components, tint, and the ammo type that weapon actually
    -- takes -- while `weapon` still works verbatim for handing out something
    -- deliberately not in the list, like a parachute.
    for _, entry in ipairs(Config.Loadouts.alwaysGive or {}) do
        local catalogue = Arena.IsKey(entry.key) and Arena.GetWeaponByKey(entry.key) or nil
        local weapon = entry.weapon or (catalogue and catalogue.weapon)

        if Arena.IsKey(weapon) and not seen[weapon] then
            seen[weapon] = true

            -- The amount, in order of who gets to decide: the operator's own
            -- line, then the weapon's own default, then one -- never zero,
            -- because a weapon handed out with no ammunition at all is a
            -- weapon that looks broken to the player holding it.
            local ammo = Arena.ToInt(entry.ammo)
            if ammo == nil and catalogue then ammo = Arena.ToInt((catalogue.ammo or {}).default) end

            local types = catalogue and Arena.GetAmmoTypes(catalogue) or nil
            local firstType = types and types[1] or nil

            resolved[#resolved + 1] = {
                key = entry.key or (catalogue and catalogue.key) or weapon,
                weapon = weapon,
                label = entry.label or (catalogue and catalogue.label) or weapon,
                category = entry.category or (catalogue and catalogue.category) or nil,
                ammo = math.max(0, ammo or 1),
                ammoType = firstType and firstType.key or nil,
                ammoTypeLabel = firstType and firstType.label or nil,
                ammoTypeItem = firstType and firstType.item or nil,
                components = type(entry.components) == 'table' and entry.components
                    or (catalogue and catalogue.components) or {},
                tint = Arena.ToInt(entry.tint) or (catalogue and Arena.ToInt(catalogue.tint)) or 0,
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
                z = tonumber(piece.z) or 0.0,
                heading = tonumber(piece.heading) or 0.0,
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
        if type(boundary) ~= 'table' and type(boundary) ~= 'userdata' then return out end
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
        if type(boundary) ~= 'table' and type(boundary) ~= 'userdata' then return nil end
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

    local boundary = arena.boundary
    if type(boundary) == 'table' and type(boundary.center) == 'table' then
        return { x = boundary.center.x, y = boundary.center.y, z = boundary.center.z }
    end

    local area = arena.spawnArea
    if type(area) == 'table' and type(area.center) == 'table' then
        return { x = area.center.x, y = area.center.y, z = area.center.z }
    end

    local spawns = arena.spawns
    if type(spawns) == 'table' and type(spawns[1]) == 'table' then
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

--- The spawn AREA an arena defines, if it defines one.
---
--- `spawns` is a list of exact points; `spawnArea` is one point and a radius,
--- and the arena works out the rest. An operator who only wants to drop a
--- marker in the middle of a field and say "a hundred metres around here"
--- should not have to write out twenty coordinates to do it.
--- @param arenaKey any
--- @return table|nil
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

--- Turns an angle and a distance into a point, with a heading facing the
--- centre.
---
--- FACING INWARDS is deliberate. A player dropped at the edge of a circle
--- looking outwards is looking at empty scenery with the fight behind them,
--- and the first thing they do is spin around.
--- @return table point -- { x, y, z, w }
local function pointAt(area, angle, distance)
    local x = area.x + math.cos(angle) * distance
    local y = area.y + math.sin(angle) * distance
    -- Degrees, clockwise from north, which is what GTA headings are.
    local heading = (math.deg(angle) + 180.0) % 360.0
    return { x = x, y = y, z = area.z, w = heading }
end

--- Squared distance, because nothing here needs the square root -- it is
--- only ever compared against another distance.
local function distanceSquared(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return dx * dx + dy * dy
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
        w = (math.deg(math.atan(area.y - (centreY + math.sin(angle) * distance),
                                area.x - (centreX + math.cos(angle) * distance))) + 360.0) % 360.0,
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

--- start and the second is survivable.
--- @return table[] points
local function scatterWithin(rng, area, centreX, centreY, radius, separation, count, placed)
    local out = {}
    local wanted = separation

    for _ = 1, count do
        local chosen
        local floor = wanted

        for round = 1, 5 do
            for _ = 1, SAMPLES_PER_ROUND do
                local candidate = sampleDisc(rng, area, centreX, centreY, radius)
                local ok = true
                for _, other in ipairs(placed) do
                    -- A piece of cover carries its own clearance and keeps
                    -- it: the relaxation below is about fitting people
                    -- around each other, and no amount of crowding makes
                    -- spawning inside a wall acceptable.
                    local need = other.clearance or floor
                    if distanceSquared(candidate, other) < need * need then ok = false break end
                end
                if ok then chosen = candidate break end
            end
            if chosen then break end
            -- Nothing fitted. Ask for less rather than trying the same
            -- question again, and on the final round ask for nothing.
            floor = (round == 4) and 0.0 or floor * 0.6
        end

        chosen = chosen or sampleDisc(rng, area, centreX, centreY, radius)
        placed[#placed + 1] = chosen
        out[#out + 1] = chosen
    end

    return out
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
        local points = scatterWithin(rng, area, area.x, area.y, area.radius,
            area.minSeparation, #byTeam['\0ffa'], placed)
        for index, entry in ipairs(byTeam['\0ffa']) do
            plan[entry.src] = points[index]
        end
        return plan
    end

    -- TEAMS. Anchors evenly around the circle, rotated at random so a team
    -- does not always open in the same place, and pulled in from the edge so
    -- a team's own spread stays inside the area.
    local anchorDistance = math.max(0.0, area.radius - area.teamRadius)
    local rotation = rng() * math.pi * 2.0

    for index, key in ipairs(order) do
        local angle = rotation + ((index - 1) / #order) * math.pi * 2.0
        local anchor = pointAt(area, angle, anchorDistance)

        local points = scatterWithin(rng, area, anchor.x, anchor.y, area.teamRadius,
            area.minSeparation, #byTeam[key], placed)

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
--- Enough that the choice is a real choice; small enough that a respawn is
--- not a search.
local RESPAWN_CANDIDATES = 16

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
    if type(value) ~= 'table' and type(value) ~= 'userdata' then return nil end
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
--- @param arenaKey any
--- @param teamKey any -- the returning player's side, for the team point list
--- @param avoid table[]|nil -- positions to stay away from
--- @param rng fun():number|nil -- injectable; defaults to math.random
--- @return table|nil point -- { x, y, z, w }, or nil when the arena has neither
---         a spawn area nor any points to choose from
function Arena.PickRespawn(arenaKey, teamKey, avoid, rng, factor)
    rng = rng or math.random

    local threats = {}
    for _, entry in ipairs(type(avoid) == 'table' and avoid or {}) do
        local point = asPoint(entry)
        if point then threats[#threats + 1] = point end
    end

    -- THE ARENA'S OWN WALLS, WHICH THIS USED TO WALK STRAIGHT INTO.
    --
    -- Arena.PlanSpawns has always seeded its rejection list with every cover
    -- piece, so nobody is ever placed into a container at the START of a
    -- round. This function did none of it: it drew candidates from the disc
    -- and scored them on distance from the nearest live opponent, with no
    -- term for the scenery at all. Measured on the shipped skydome, whose
    -- twenty pieces cover about a tenth of the spawn disc, one respawn in ten
    -- landed inside one -- and a fighter respawned inside a shipping
    -- container has nowhere to walk to.
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

    local best, bestScore = nil, -1
    for _, candidate in ipairs(pool) do
        local nearest = math.huge
        for _, threat in ipairs(threats) do
            local gap = distanceSquared(candidate, threat)
            if gap < nearest then nearest = gap end
        end
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

--- Clamps a requested entry fee into the configured band. Returns nil when
--- betting or entry fees are off, which callers treat as "reject the bet"
--- rather than "bet zero".
--- @param requested any
--- @return integer|nil amount
--- @return string|nil reason
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
