--[[
    crimson_arena/tests/snapshotcontract_spec.lua

    THE SEAM BETWEEN TWO CORRECT HALVES.

    The arena panel is built entirely from one state snapshot. It renders
    nothing it was not sent, and it has no console anyone reads -- so a field
    that stops arriving in ArenaLobby.BuildState does not fail, it just
    quietly stops being a control. The weapon list keeps drawing; the ammo
    type chips are simply gone. Nothing is red anywhere. This project has
    already lost `contestants` exactly that way, between a server that built
    it and a client that read it, with both halves correct on their own.

    Several recent features cross that seam:

        * the per-weapon `melee` flag -- resolved SERVER-SIDE through
          Arena.IsMeleeWeapon so the panel and the server can never disagree
          about what a bat is,
        * `ammoTypes` / `defaultAmmoType` -- the rounds a weapon offers,
        * `weaponSlots` / `meleeSlots` / `ammoTypeSlots` -- the three
          allowances Arena.ResolveLoadout enforces and rejects by name.

    Nothing tested any of it. This file does, against the REAL server files
    loaded through tests/fixtures/sandbox.lua over the REAL config.lua, and
    asserts on the snapshot BuildState actually produces rather than on a
    hand-written copy of what it is supposed to produce.

    EVERYTHING IS DERIVED FROM CONFIG, NOTHING IS WRITTEN DOWN. There is not
    a weapon key, an ammo type key or a count hard-coded in an assertion
    below: every expectation is computed from Config.Loadouts and from the
    same Arena.* functions the server itself calls. Adding a weapon to
    config, disabling one, or renaming an ammo type must never turn this file
    red -- only a snapshot that stops matching the catalogue may.

    THE INVARIANT THIS WHOLE DESIGN RESTS ON is at the bottom: whatever the
    snapshot offers for a weapon, fed back in unchanged as a player's choice,
    is accepted by Arena.ResolveLoadout without a single rejection. A panel
    that can only offer things the server accepts is the reason the panel is
    allowed to decide nothing -- so it is pinned by a test rather than by
    intent.

    TWO FILES ARE STUBBED, as in tests/lobbyrules_spec.lua: server/stats.lua
    wants oxmysql and server/dispatch.lua wants server-side state bags.
    Neither decides anything about a weapon list. Every other server file
    here is the shipped one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('snapshotcontract_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- One whole arena server. Fresh per test: server/lobby.lua caches the
--- config third of the snapshot in an upvalue the first time it is asked
--- for one, so two tests sharing an env would share a weapon list.
--- @param mutate fun(config: table)? -- applied before any file that reads config at LOAD time
--- @param wallets table<integer, integer>? -- [serverId] = starting cash
--- @return table server
local function newArena(mutate, wallets)
    local players = {}
    for id, cash in pairs(wallets or { [1] = 100000, [2] = 100000 }) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents = {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),

        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,

        print = function(line) console[#console + 1] = line end,

        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        -- Captured nowhere on purpose: the production files register handlers
        -- at load time and this spec asserts on the snapshot, not on them.
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        -- Well past every RATE bucket in main.lua on every call: a throttled
        -- event would look exactly like a refused one.
        GetGameTimer = function() clock = clock + 60000; return clock end,

        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- Before the loads, not after: server/lobby.lua reads
    -- Config.Match.idleLobbyTimeoutSeconds once, at load.
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env,
        config = env.Config,
        Arena = env.Arena,
        lobby = env.ArenaLobby,
    }

    --- The whole snapshot one player is sent, straight out of BuildState.
    --- @param src integer?
    --- @return table
    function server.snapshot(src) return env.ArenaLobby.BuildState(src or 1) end

    --- The `config.loadouts` third -- everything the loadout tab is drawn
    --- from.
    --- @return table
    function server.loadouts(src) return server.snapshot(src).config.loadouts end

    --- One client -> server event, as the client sends it.
    --- @param event string -- the tail of crimson_arena:server:*
    --- @param src integer
    --- @param data table?
    function server.fire(event, src, data)
        local name = 'crimson_arena:server:' .. event
        local handler = netEvents[name]
        if not handler then error('no handler registered for ' .. name, 2) end
        env.source = src
        handler(data)
    end

    --- @return string
    function server.log() return table.concat(console, '\n') end

    return server
end

-- ======================================================================
-- DERIVING THE EXPECTATIONS FROM CONFIG
--
-- Every helper below answers a question about the SHIPPED catalogue by
-- reading it, so a spec assertion never has to name a weapon.
-- ======================================================================

--- The snapshot's entry for one weapon key, or nil.
--- @param loadouts table -- snapshot.config.loadouts
--- @param key string
--- @return table|nil
local function snapWeapon(loadouts, key)
    for _, weapon in ipairs(loadouts.weapons or {}) do
        if weapon.key == key then return weapon end
    end
    return nil
end

--- Every enabled weapon in the snapshot that this predicate accepts.
--- @param loadouts table
--- @param wanted boolean -- true for melee, false for shootable
--- @return table[]
local function snapWeaponsByKind(loadouts, wanted)
    local out = {}
    for _, weapon in ipairs(loadouts.weapons or {}) do
        if weapon.melee == wanted then out[#out + 1] = weapon end
    end
    return out
end

--- How many ammo types the SHARED default list actually offers, counted the
--- way Arena.GetAmmoTypes counts them. This is what decides whether a
--- firearm is entitled to a non-empty list at all -- an operator who empties
--- `defaultAmmoTypes` has switched the feature off, and no weapon without
--- its own list may then carry one.
--- @param Arena table
--- @param config table
--- @return integer
local function sharedAmmoTypeCount(Arena, config)
    local total = 0
    for _, entry in ipairs(config.Loadouts.defaultAmmoTypes or {}) do
        if type(entry) == 'table' and entry.enabled ~= false and Arena.IsKey(entry.key) then
            total = total + 1
        end
    end
    return total
end

--- Every ammo item name any type in the catalogue can hand out, as a sorted
--- array. These are the strings that must never cross the wire.
--- @param Arena table
--- @return string[]
local function ammoItemNames(Arena)
    local out = {}
    for item in pairs(Arena.AllAmmoItems()) do out[#out + 1] = item end
    table.sort(out)
    return out
end

--- Every place in `node` where one of `needles` appears, as a readable path.
--- Values are matched as SUBSTRINGS rather than whole strings, so an item
--- name smuggled inside a longer label is still found; table keys are
--- checked as well, since an items map would leak through its keys.
--- @param node any
--- @param needles string[]
--- @param path string
--- @param out string[]
--- @param seen table
--- @return string[] paths
local function findStrings(node, needles, path, out, seen)
    if type(node) == 'string' then
        for _, needle in ipairs(needles) do
            if node:find(needle, 1, true) then
                out[#out + 1] = ('%s = %q'):format(path, node)
                return out
            end
        end
        return out
    end
    if type(node) ~= 'table' or seen[node] then return out end
    seen[node] = true

    for key, value in pairs(node) do
        local step = type(key) == 'string' and ('.' .. key) or ('[' .. tostring(key) .. ']')
        if type(key) == 'string' then
            for _, needle in ipairs(needles) do
                if key:find(needle, 1, true) then
                    out[#out + 1] = ('%s%s (as a key)'):format(path, step)
                    break
                end
            end
        end
        findStrings(value, needles, path .. step, out, seen)
    end
    return out
end

--- @param root any
--- @param needles string[]
--- @param label string
--- @return string[] paths
local function leakPaths(root, needles, label)
    return findStrings(root, needles, label, {}, {})
end

--- Exactly what app.js's saveLoadout would put on the wire for one weapon
--- card, built ONLY from what the snapshot offered for that card.
---
--- `ammoType` is left OFF for a weapon offering no types, because that is
--- the distinction the panel draws: a missing field means "whatever this
--- weapon loads normally", which is the right answer for a bat and the wrong
--- thing to invent a value for.
--- @param weapon table -- a snapshot weapon entry
--- @param ammoIndex integer? -- which offered amount; the last one by default
--- @param typeIndex integer? -- which offered type; the default one otherwise
--- @return table entry
local function panelPick(weapon, ammoIndex, typeIndex)
    local options = weapon.ammo.options or {}
    local entry = {
        key = weapon.key,
        ammo = #options > 0 and options[ammoIndex or #options] or weapon.ammo.default,
    }

    local types = weapon.ammoTypes or {}
    if typeIndex ~= nil then
        entry.ammoType = types[typeIndex].key
    elseif weapon.defaultAmmoType ~= nil then
        entry.ammoType = weapon.defaultAmmoType
    end
    return entry
end

--- The resolved entry for one catalogue key, or nil.
--- @param loadout table -- what Arena.ResolveLoadout returned
--- @param key string
--- @return table|nil
local function resolvedByKey(loadout, key)
    for _, weapon in ipairs(loadout.weapons or {}) do
        if weapon.key == key then return weapon end
    end
    return nil
end

-- ======================================================================
-- WHAT THIS FILE ASSUMES ABOUT THE SHIPPED CATALOGUE
--
-- Not the values themselves -- those are read from config everywhere below
-- -- but that the catalogue is rich enough for the assertions to mean
-- something. A config with no melee weapon, or no ammo types, would let
-- every test in this file pass without exercising anything.
-- ======================================================================

t.test('the shipped catalogue is rich enough for the rest of this file to mean anything', function()
    local server = newArena()
    local Arena, config = server.Arena, server.config

    local enabled = Arena.GetEnabledWeapons()
    t.isTrue(#enabled > 0, 'no weapon is switched on at all')

    local melee, firearms, disabled = 0, 0, 0
    for _, weapon in ipairs(enabled) do
        if Arena.IsMeleeWeapon(weapon) then melee = melee + 1 else firearms = firearms + 1 end
    end
    for _, weapon in ipairs(config.Loadouts.weapons or {}) do
        if weapon.enabled == false then disabled = disabled + 1 end
    end

    t.isTrue(melee > 0, 'no melee weapon ships enabled, so the melee half of this file proves nothing')
    t.isTrue(firearms > 0, 'no shootable weapon ships enabled')
    t.isTrue(disabled > 0, 'nothing ships disabled, so "a disabled weapon never appears" proves nothing')
    t.isTrue(sharedAmmoTypeCount(Arena, config) > 0, 'the shared ammo type list is empty')
    t.isTrue(#ammoItemNames(Arena) > 0, 'no ammo type names an item, so the leak check has nothing to look for')
end)

-- ======================================================================
-- EVERY ENABLED WEAPON, AND THE `melee` FLAG
-- ======================================================================

t.test('every enabled weapon reaches the panel, in catalogue order, and nothing else does', function()
    local server = newArena()
    local loadouts = server.loadouts()
    local enabled = server.Arena.GetEnabledWeapons()

    t.equals(#(loadouts.weapons or {}), #enabled, 'the snapshot weapon list is not the enabled catalogue')

    for index, weapon in ipairs(enabled) do
        local sent = loadouts.weapons[index]
        t.isNotNil(sent, ('weapon %d never arrived'):format(index))
        t.equals(sent.key, weapon.key, 'the panel would draw the catalogue in a different order')
        t.equals(sent.label, weapon.label or weapon.key)
        t.equals(sent.category, weapon.category)
    end
end)

t.test('`melee` is the server answer, not a guess -- it matches Arena.IsMeleeWeapon for every weapon', function()
    -- Asserted against the FUNCTION rather than a list of keys: this is the
    -- one flag the panel is forbidden from working out for itself, so adding
    -- a weapon to config must not be able to turn this red.
    local server = newArena()
    local loadouts = server.loadouts()

    for _, weapon in ipairs(server.Arena.GetEnabledWeapons()) do
        local sent = snapWeapon(loadouts, weapon.key)
        t.isNotNil(sent, ('%s never reached the panel'):format(weapon.key))
        -- A nil `melee` does not survive the trip as a key at all, and the
        -- panel would read the absence as "not melee" for a bat.
        t.equals(type(sent.melee), 'boolean', ('%s: melee is not a boolean'):format(weapon.key))
        t.equals(sent.melee, server.Arena.IsMeleeWeapon(weapon),
            ('%s: the panel and the server disagree about what this is'):format(weapon.key))
    end
end)

t.test('a weapon filed under melee is melee even if its ammo block says otherwise', function()
    -- Both halves of Arena.IsMeleeWeapon, through the snapshot: the category
    -- declaration and the one-round ceiling. An operator who writes
    -- `category = 'melee'` on something with a magazine still gets a weapon
    -- counted against the melee allowance, and the panel is told so.
    local server = newArena(function(config)
        config.Loadouts.weapons[#config.Loadouts.weapons + 1] = {
            key = 'spec_odd_melee',
            weapon = 'WEAPON_SPEC_ODD_MELEE',
            label = 'Odd Melee',
            category = 'melee',
            enabled = true,
            ammo = { default = 30, options = { 30 }, max = 90 },
        }
        config.Loadouts.weapons[#config.Loadouts.weapons + 1] = {
            key = 'spec_one_round',
            weapon = 'WEAPON_SPEC_ONE_ROUND',
            label = 'One Round',
            category = 'heavy',
            enabled = true,
            ammo = { default = 1, options = nil, max = 1 },
        }
    end)
    local loadouts = server.loadouts()

    local odd = snapWeapon(loadouts, 'spec_odd_melee')
    t.isNotNil(odd)
    t.isTrue(odd.melee, 'a weapon declared melee was sent as a firearm')
    t.equals(#odd.ammoTypes, 0, 'melee inherited the shared ammo type list')

    local oneRound = snapWeapon(loadouts, 'spec_one_round')
    t.isNotNil(oneRound)
    t.isTrue(oneRound.melee, 'a weapon whose ceiling is one round was sent as a firearm')
end)

-- ======================================================================
-- AMMO TYPES
-- ======================================================================

t.test('melee carries an EMPTY ammoTypes list and a firearm carries the shared one', function()
    local server = newArena()
    local Arena, config = server.Arena, server.config
    local loadouts = server.loadouts()
    local shared = sharedAmmoTypeCount(Arena, config)

    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        local sent = snapWeapon(loadouts, weapon.key)
        t.isNotNil(sent, ('%s never reached the panel'):format(weapon.key))
        t.equals(type(sent.ammoTypes), 'table', ('%s: ammoTypes is not a list'):format(weapon.key))

        if Arena.IsMeleeWeapon(weapon) then
            -- The empty list is MEANINGFUL: it is what tells the panel to
            -- draw no type control at all rather than a dead one reading
            -- 'none'.
            t.equals(#sent.ammoTypes, 0, ('%s is melee and was offered rounds to load'):format(weapon.key))
        elseif weapon.ammoTypes == false then
            -- An operator switching types off for one weapon, which has to
            -- beat the shared default.
            t.equals(#sent.ammoTypes, 0, ('%s had its types switched off and was offered some anyway'):format(weapon.key))
        elseif shared > 0 or type(weapon.ammoTypes) == 'table' then
            t.isTrue(#sent.ammoTypes > 0, ('%s takes ammunition and was offered no type at all'):format(weapon.key))
        end

        -- Whatever the count, it is the count the server itself would use.
        t.equals(#sent.ammoTypes, #Arena.GetAmmoTypes(weapon),
            ('%s: the panel and the server offer different numbers of rounds'):format(weapon.key))
    end
end)

t.test('each offered type is the key and label the server resolved, and nothing else', function()
    local server = newArena()
    local Arena = server.Arena
    local loadouts = server.loadouts()

    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        local sent = snapWeapon(loadouts, weapon.key)
        local real = Arena.GetAmmoTypes(weapon)

        for index, offered in ipairs(sent.ammoTypes) do
            local resolved = real[index]
            t.isNotNil(resolved, ('%s: type %d was invented'):format(weapon.key, index))
            t.equals(offered.key, resolved.key)
            t.equals(offered.label, resolved.label)
            -- The panel needs a key to send back and a label to draw. The
            -- component is the client's business and the item is the
            -- operator's; neither belongs on the wire.
            t.isNil(offered.item, ('%s/%s: an inventory item name was sent to the client'):format(weapon.key, offered.key))
            t.isNil(offered.component, ('%s/%s: a GTA component name was sent in the type list'):format(weapon.key, offered.key))
        end
    end
end)

t.test('defaultAmmoType is one of that weapon own offered keys, or nil when it offers none', function()
    local server = newArena()
    local Arena = server.Arena
    local loadouts = server.loadouts()

    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        local sent = snapWeapon(loadouts, weapon.key)

        if #sent.ammoTypes == 0 then
            -- nil, not an empty string and not the shared default: "this
            -- weapon has no type" and "nobody has chosen one" are different
            -- answers, and the panel reads the difference.
            t.isNil(sent.defaultAmmoType,
                ('%s offers no rounds and still named a default'):format(weapon.key))
        else
            local found = false
            for _, offered in ipairs(sent.ammoTypes) do
                if offered.key == sent.defaultAmmoType then found = true end
            end
            t.isTrue(found, ('%s: defaultAmmoType %s is not one of the types it offers')
                :format(weapon.key, tostring(sent.defaultAmmoType)))

            -- And it is the one the server would really hand out, resolved
            -- through the same function rather than read off config.
            local resolved = Arena.ResolveAmmoType(weapon, nil)
            t.equals(sent.defaultAmmoType, resolved and resolved.key or nil,
                ('%s: the panel opens on a round the server would not issue'):format(weapon.key))
        end
    end
end)

t.test('an operator switching types off for one weapon empties that weapon list and no other', function()
    local base = newArena()
    local firearms = snapWeaponsByKind(base.loadouts(), false)
    t.isTrue(#firearms >= 2, 'need two shootable weapons to tell one from the other')
    local silenced, untouched = firearms[1].key, firearms[2].key
    t.isTrue(#firearms[1].ammoTypes > 0, 'the weapon to silence had no types to begin with')

    local server = newArena(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.key == silenced then weapon.ammoTypes = false end
        end
    end)
    local loadouts = server.loadouts()

    t.equals(#snapWeapon(loadouts, silenced).ammoTypes, 0, 'a switched-off type list still reached the panel')
    t.isNil(snapWeapon(loadouts, silenced).defaultAmmoType)
    t.isTrue(#snapWeapon(loadouts, untouched).ammoTypes > 0, 'silencing one weapon silenced another')
end)

-- ======================================================================
-- ITEM NAMES NEVER LEAVE THE SERVER
--
-- Which inventory item backs a round is the operator's business. It tells a
-- client nothing it can use and tells a modified one the exact name to ask
-- another script for.
-- ======================================================================

t.test('no ammo item name appears anywhere in the config third of the snapshot', function()
    local server = newArena()
    local items = ammoItemNames(server.Arena)
    t.isTrue(#items > 0, 'nothing to look for')

    local leaks = leakPaths(server.snapshot().config, items, 'snapshot.config')
    t.equals(#leaks, 0, 'an inventory item name reached the client at ' .. table.concat(leaks, ', '))
end)

t.test('no ammo item name appears in the match list or the leaderboard either', function()
    local server = newArena()
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')
    server.fire('joinMatch', 2, { matchId = match.id })

    local snapshot = server.snapshot(1)
    local items = ammoItemNames(server.Arena)

    local leaks = leakPaths(snapshot.matches, items, 'snapshot.matches')
    t.equals(#leaks, 0, 'an item name reached the client at ' .. table.concat(leaks, ', '))

    leaks = leakPaths(snapshot.leaderboard, items, 'snapshot.leaderboard')
    t.equals(#leaks, 0, 'an item name reached the client at ' .. table.concat(leaks, ', '))
end)

t.test('DEFECT: a saved loadout carries its ammo item name into the player block', function()
    -- server/lobby.lua stores what Arena.ResolveLoadout returned on the
    -- player, and snapshotPlayer sends that table verbatim as
    -- `player.loadout`. ResolveLoadout puts `ammoTypeItem` on every resolved
    -- firearm, so the operator's item name rides out to the client on the
    -- next push -- the one place snapshotConfig's own comment says it must
    -- not go.
    --
    -- This test states TODAY'S behaviour so the suite stays green, and
    -- upgrades itself to the contract the moment the field stops being sent.
    local server = newArena()
    local Arena = server.Arena
    local items = ammoItemNames(Arena)

    -- A firearm whose chosen round really does name an item -- derived, so a
    -- config where no type carries an item skips rather than fails.
    local carrier, carrierType
    for _, weapon in ipairs(Arena.GetEnabledWeapons()) do
        for _, entry in ipairs(Arena.GetAmmoTypes(weapon)) do
            if entry.item and not carrier then carrier, carrierType = weapon, entry end
        end
    end
    if not carrier then return end

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    server.fire('setLoadout', 1, {
        weapons = { { key = carrier.key, ammo = carrier.ammo.default, ammoType = carrierType.key } },
        armor = 0,
    })

    local leaks = leakPaths(server.snapshot(1).player, items, 'snapshot.player')
    if #leaks == 0 then
        -- Fixed since this spec was written. Hold the whole snapshot to the
        -- contract instead and delete the branch below.
        t.equals(#leakPaths(server.snapshot(1), items, 'snapshot'), 0,
            'an item name still reaches the client')
        return
    end

    -- Confined to the one known hole. A leak anywhere else is a NEW one and
    -- fails here immediately.
    for _, path in ipairs(leaks) do
        t.contains(path, 'loadout', 'an item name leaked outside the stored loadout: ' .. path)
        t.contains(path, 'ammoTypeItem', 'an item name leaked through a new field: ' .. path)
    end
end)

-- ======================================================================
-- THE THREE ALLOWANCES
-- ======================================================================

t.test('the shared pool and both kind switches arrive and match config', function()
    local server = newArena()
    local loadouts = server.loadouts()

    t.equals(type(loadouts.slots), 'number', 'slots never reached the panel')
    t.equals(loadouts.slots, server.config.Loadouts.slots)
    t.equals(loadouts.allowFirearms, server.config.Loadouts.allowFirearms)
    t.equals(loadouts.allowMelee, server.config.Loadouts.allowMelee)
end)

t.test('ammoTypeSlots -- the third allowance -- reaches the panel too', function()
    -- It did not, when this file was written. Arena.ResolveLoadout enforced
    -- Config.Loadouts.ammoTypeSlots while snapshotConfig sent every other
    -- allowance and not this one, so an operator who set a cap got a picker
    -- offering a different round for every weapon and a server that quietly
    -- issued defaults instead. This test was written as a defect note with a
    -- branch for the day it started arriving; that day came, and this is the
    -- branch it left behind.
    for _, cap in ipairs({ 0, 1, 2, 5 }) do
        local server = newArena(function(config)
            config.Loadouts.ammoTypeSlots = cap
        end)
        local loadouts = server.loadouts()

        t.equals(type(loadouts.ammoTypeSlots), 'number',
            ('ammoTypeSlots never reached the panel at a cap of %d'):format(cap))
        t.equals(loadouts.ammoTypeSlots, cap,
            'the panel is told a different cap than the server enforces')
    end
end)

t.test('the ammo type cap is real, and it is silent -- which is why the panel is told', function()
    -- Why that field has to arrive, asserted on the server side where it is
    -- observable. Two firearms, two different rounds, a cap of one: the second
    -- weapon is NOT refused, it is handed its default instead. A player is
    -- never told no -- they are told yes and then given something else -- so
    -- the only way the panel can warn them beforehand is to know the number.
    local base = newArena()
    local firearms = snapWeaponsByKind(base.loadouts(), false)
    local pair = {}
    for _, weapon in ipairs(firearms) do
        if #weapon.ammoTypes >= 2 and #pair < 2 then pair[#pair + 1] = weapon end
    end
    if #pair < 2 then return end

    local server = newArena(function(config)
        config.Loadouts.ammoTypeSlots = 1
        config.Loadouts.weaponSlots = 2
    end)

    -- Two DIFFERENT rounds, each one the snapshot itself offered.
    local first = pair[1].ammoTypes[1].key
    local second
    for _, offered in ipairs(pair[2].ammoTypes) do
        if offered.key ~= first then second = offered.key end
    end
    t.isNotNil(second, 'the two weapons offer only one round between them')

    local loadout, rejected = server.Arena.ResolveLoadout({
        weapons = {
            { key = pair[1].key, ammo = pair[1].ammo.default, ammoType = first },
            { key = pair[2].key, ammo = pair[2].ammo.default, ammoType = second },
        },
    })

    t.equals(#rejected, 0, 'a weapon was refused over an ammunition preference')
    t.equals(resolvedByKey(loadout, pair[1].key).ammoType, first, 'the first choice was not honoured')
    t.equals(resolvedByKey(loadout, pair[2].key).ammoType, snapWeapon(base.loadouts(), pair[2].key).defaultAmmoType,
        'the capped weapon was not fallen back to its own default')
end)

t.test('the allowances follow config rather than being constants', function()
    local server = newArena(function(config)
        config.Loadouts.slots = 6
        config.Loadouts.allowMelee = false
    end)
    local loadouts = server.loadouts()

    t.equals(loadouts.slots, 6)
    t.isFalse(loadouts.allowMelee, 'allowMelee = false was defaulted away')
    t.isTrue(loadouts.allowFirearms, 'switching melee off switched firearms off too')
end)

t.test('and ZERO survives as zero, because zero is the generous answer now', function()
    -- The reversal that makes this worth its own test. Under the two keys
    -- this replaces, 0 meant "none of this kind" and a default applied on
    -- the way to the panel would have ADDED weapons back. Under one pool it
    -- means "no limit", and a default applied here would TAKE them away --
    -- the panel would cap a picker the server does not cap.
    local server = newArena(function(config) config.Loadouts.slots = 0 end)
    t.equals(server.loadouts().slots, 0, 'slots = 0 was defaulted away')
end)

t.test('an allowance the operator never wrote reads the same in the snapshot as in the resolver', function()
    -- Both halves default on their own. If they ever default differently the
    -- panel draws a slot the server will not fill, or hides one it would.
    -- Arena.SlotsPerPlayer exists so there is only one half to get wrong;
    -- this is what proves the snapshot actually goes through it.
    local server = newArena(function(config) config.Loadouts.slots = nil end)
    local loadouts = server.loadouts()

    local pool = {}
    for _, weapon in ipairs(server.Arena.GetEnabledWeapons()) do
        pool[#pool + 1] = { key = weapon.key, ammo = weapon.ammo and weapon.ammo.default }
    end
    t.isTrue(#pool >= loadouts.slots, 'not enough weapons enabled to fill the advertised pool')

    local request = {}
    for index = 1, loadouts.slots do request[#request + 1] = pool[index] end

    local _, rejected = server.Arena.ResolveLoadout({ weapons = request })
    t.equals(#rejected, 0,
        'the snapshot advertised more slots than the resolver honours: ' .. table.concat(rejected, ', '))
end)

-- ======================================================================
-- A DISABLED WEAPON IS GONE, NOT GREYED OUT
-- ======================================================================

t.test('nothing an operator shipped disabled appears in the snapshot', function()
    local server = newArena()
    local loadouts = server.loadouts()
    local checked = 0

    for _, weapon in ipairs(server.config.Loadouts.weapons or {}) do
        if weapon.enabled == false then
            checked = checked + 1
            t.isNil(snapWeapon(loadouts, weapon.key),
                ('%s ships disabled and reached the panel anyway'):format(weapon.key))
        end
    end
    t.isTrue(checked > 0, 'the shipped config disables nothing, so this test checked nothing')
end)

t.test('switching a weapon off removes it from the panel and from what the server will hand out', function()
    -- The key is taken from the catalogue rather than written down, so this
    -- test does not care which weapon ships first.
    local victim = Sandbox.newArenaEnv().Arena.GetEnabledWeapons()[1].key

    local server = newArena(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.key == victim then weapon.enabled = false end
        end
    end)
    local loadouts = server.loadouts()

    t.isNil(snapWeapon(loadouts, victim), 'a disabled weapon was still offered')
    t.equals(#loadouts.weapons, #server.Arena.GetEnabledWeapons())
    t.isNil(server.Arena.GetWeaponByKey(victim), 'a disabled weapon is still reachable by key')

    -- And a panel left open across the change cannot smuggle it through:
    -- the request is refused BY NAME, which is what lets the server say
    -- which weapon did not make it in.
    local _, rejected = server.Arena.ResolveLoadout({ weapons = { { key = victim, ammo = 10 } } })
    t.equals(#rejected, 1, 'a disabled weapon was handed out on request')
    t.equals(rejected[1], victim)
end)

-- ======================================================================
-- THE ROUND TRIP
--
-- What the snapshot offers, fed back in unchanged, is accepted. This is the
-- invariant the whole design rests on: the panel decides nothing because it
-- can only ever offer what the server would already say yes to.
-- ======================================================================

t.test('every amount and every round the snapshot offers comes back accepted, unchanged', function()
    local server = newArena()
    local loadouts = server.loadouts()
    local checked = 0

    for _, weapon in ipairs(loadouts.weapons) do
        local typeCount = #weapon.ammoTypes
        local amounts = #weapon.ammo.options > 0 and #weapon.ammo.options or 1

        for ammoIndex = 1, amounts do
            for typeIndex = 0, typeCount do
                -- typeIndex 0 is the card with nothing picked: app.js leaves
                -- the field off the wire entirely, and the server is meant to
                -- answer with this weapon's own default.
                local entry = panelPick(weapon, ammoIndex, typeIndex > 0 and typeIndex or nil)
                if typeIndex == 0 then entry.ammoType = nil end

                local loadout, rejected = server.Arena.ResolveLoadout({ weapons = { entry } })
                t.equals(#rejected, 0, ('%s: the panel offered something the server refused: %s')
                    :format(weapon.key, table.concat(rejected, ', ')))

                local got = resolvedByKey(loadout, weapon.key)
                t.isNotNil(got, ('%s was accepted and then not handed out'):format(weapon.key))
                t.equals(got.ammo, entry.ammo, ('%s: the amount came back changed'):format(weapon.key))
                t.equals(got.label, weapon.label, ('%s: the panel name is not the name handed out'):format(weapon.key))

                if typeIndex > 0 then
                    t.equals(got.ammoType, entry.ammoType,
                        ('%s: the round the panel offered is not the round issued'):format(weapon.key))
                else
                    t.equals(got.ammoType, weapon.defaultAmmoType,
                        ('%s: no choice was sent and the default was not applied'):format(weapon.key))
                end
                checked = checked + 1
            end
        end
    end

    t.isTrue(checked > 0, 'the round trip checked nothing at all')
end)

t.test('a full loadout built from the snapshot -- every slot filled -- is accepted whole', function()
    local server = newArena()
    local loadouts = server.loadouts()

    -- FILLED WITH A MIX, because the pool takes either and the panel can
    -- build exactly this: blades first, then guns, in one list.
    local firearms = snapWeaponsByKind(loadouts, false)
    local melee = snapWeaponsByKind(loadouts, true)
    t.isTrue(#firearms + #melee >= loadouts.slots, 'not enough weapons enabled to fill the pool')

    local pool = {}
    for _, weapon in ipairs(melee) do pool[#pool + 1] = weapon end
    for _, weapon in ipairs(firearms) do pool[#pool + 1] = weapon end

    local request, wanted = {}, {}
    for index = 1, loadouts.slots do
        request[#request + 1] = panelPick(pool[index])
        wanted[#wanted + 1] = pool[index]
    end

    -- SUPPLIES COME OFF THE SNAPSHOT TOO, at the maximum the panel offers,
    -- because a request the panel can build has to be one the server takes.
    local supplies = {}
    for _, entry in ipairs((loadouts.supplies or {}).items or {}) do
        supplies[#supplies + 1] = { key = entry.key, count = entry.max }
    end

    local loadout, rejected = server.Arena.ResolveLoadout({ weapons = request, supplies = supplies })
    t.equals(#rejected, 0, 'a loadout the panel could build was refused: ' .. table.concat(rejected, ', '))

    -- AND THE TWO VITALS ARE THE RULE, not anything the request said.
    local fullHealth, fullArmour = server.Arena.StartingVitals()
    t.equals(loadout.health, fullHealth, 'a round did not start on full health')
    t.equals(loadout.armor, fullArmour, 'a round did not start on a full plate')

    for index, weapon in ipairs(wanted) do
        local got = resolvedByKey(loadout, weapon.key)
        t.isNotNil(got, ('%s filled a slot the panel showed and was dropped'):format(weapon.key))
        t.equals(got.ammo, request[index].ammo)
        t.equals(got.ammoType, weapon.defaultAmmoType)
    end
end)

t.test('the two allowances really are counted apart -- a blade does not cost a rifle', function()
    -- The reason meleeSlots exists at all, asserted end to end: the panel
    -- shows both numbers, and a loadout that fills both is accepted.
    local server = newArena(function(config)
        config.Loadouts.weaponSlots = 2
        config.Loadouts.meleeSlots = 1
    end)
    local loadouts = server.loadouts()
    local firearms = snapWeaponsByKind(loadouts, false)
    local melee = snapWeaponsByKind(loadouts, true)

    local _, rejected = server.Arena.ResolveLoadout({
        weapons = {
            panelPick(firearms[1]), panelPick(firearms[2]), panelPick(melee[1]),
        },
    })
    t.equals(#rejected, 0, 'two guns and a blade was refused: ' .. table.concat(rejected, ', '))
end)

t.test('and the round trip is not vacuous -- a weapon over the advertised allowance is refused by name', function()
    -- The negative control. Without it every assertion above would still
    -- pass against a ResolveLoadout that accepted everything.
    --
    -- OVERFILLED WITH EACH KIND IN TURN, because the pool must be spent by
    -- either -- an all-blade loadout that goes one over has to be refused
    -- exactly as an all-gun one is.
    local server = newArena(function(config) config.Loadouts.slots = 2 end)
    local loadouts = server.loadouts()
    local firearms = snapWeaponsByKind(loadouts, false)
    local melee = snapWeaponsByKind(loadouts, true)
    t.isTrue(#firearms > loadouts.slots, 'not enough firearms to overfill the pool')
    t.isTrue(#melee > loadouts.slots, 'not enough blades to overfill the pool')

    for _, case in ipairs({ { 'firearms', firearms }, { 'melee', melee } }) do
        local request = {}
        for index = 1, loadouts.slots + 1 do request[#request + 1] = panelPick(case[2][index]) end
        local _, rejected = server.Arena.ResolveLoadout({ weapons = request })
        t.equals(#rejected, 1, ('the pool was not enforced against %s'):format(case[1]))
        t.equals(rejected[1], case[2][loadouts.slots + 1].key,
            ('the extra %s entry was dropped without being named'):format(case[1]))
    end
end)

t.test('EVERY overflow is named, not just the first one past the line', function()
    -- WAS A RECORDED DEFECT, and the one pool is what fixed it.
    --
    -- The two-allowance resolver broke out of its loop the moment BOTH
    -- counters were spent, so anything after that point never reached the
    -- branch that appends to `rejected`. ArenaLobby.SetLoadout raises its
    -- notify.loadout_rejected toast from that list, so a player who sent
    -- three guns and two blades was told about the gun and never about the
    -- blade: the weapon simply was not in their loadout, with nothing said.
    -- Which one got named depended on the order the panel happened to send,
    -- which is the ordering dependence the break was there to avoid.
    --
    -- The shared pool walks to the end -- a request is capped at 32 entries
    -- long before it reaches here, so there is nothing to save -- and every
    -- entry past the pool is named. This test is written as the contract
    -- rather than as a defect note, and it must FAIL if a break comes back.
    local server = newArena(function(config) config.Loadouts.slots = 2 end)
    local loadouts = server.loadouts()
    local firearms = snapWeaponsByKind(loadouts, false)
    local melee = snapWeaponsByKind(loadouts, true)

    -- Two guns fill the pool; everything after it should be named, of both
    -- kinds, however far down the list it sits.
    local request = {
        panelPick(firearms[1]), panelPick(firearms[2]),
        panelPick(firearms[3]), panelPick(melee[1]), panelPick(melee[2]),
    }

    local loadout, rejected = server.Arena.ResolveLoadout({ weapons = request })

    t.equals(#loadout.weapons, 2, 'the pool was exceeded')
    t.equals(#rejected, 3,
        'an overflowing weapon was dropped without being named: ' .. table.concat(rejected, ', '))

    local named = table.concat(rejected, ',')
    t.contains(named, firearms[3].key)
    t.contains(named, melee[1].key)
    t.contains(named, melee[2].key,
        'the LAST entry was swallowed -- the loop broke out early again')
end)

t.test('a stored loadout re-resolves without losing anything -- the round trip survives a round trip', function()
    -- A loadout is stored RESOLVED and resolved again at match start, so the
    -- resolver's own output has to be a legal request -- every entry it
    -- produces carries a catalogue `key`, which is the only spelling the
    -- second pass can resolve under.
    local server = newArena()
    local loadouts = server.loadouts()
    local melee = snapWeaponsByKind(loadouts, true)
    local firearms = snapWeaponsByKind(loadouts, false)

    -- A MIXED loadout, so the second pass has to spend one pool on two kinds
    -- rather than two pools on one kind each.
    local pool = { melee[1], firearms[1], melee[2], firearms[2] }
    local request = {}
    for index = 1, loadouts.slots do request[#request + 1] = panelPick(pool[index]) end

    local once = server.Arena.ResolveLoadout({ weapons = request })
    local twice, rejected = server.Arena.ResolveLoadout({ weapons = once.weapons })

    t.equals(#rejected, 0, 'the server refused its own answer: ' .. table.concat(rejected, ', '))
    t.equals(#twice.weapons, #once.weapons, 'a weapon was lost or duplicated on the second pass')
    for index, weapon in ipairs(once.weapons) do
        t.equals(twice.weapons[index].weapon, weapon.weapon)
        t.equals(twice.weapons[index].ammo, weapon.ammo)
        t.equals(twice.weapons[index].ammoType, weapon.ammoType)
    end
end)

t.test('a player who has picked nothing still gets a preview and a catalogue', function()
    -- The snapshot has to describe what the player will be given even before
    -- they have opened the loadout tab, or that tab is a blank panel.
    local server = newArena()
    local loadouts = server.loadouts()

    t.isTrue(#loadouts.weapons > 0, 'the server sent no catalogue to display')

    local preview = server.snapshot(1).player.loadout
    t.isNotNil(preview, 'the player block carries no loadout to preview')
    t.equals(type(preview.weapons), 'table')
end)

-- ========================================================================
-- EVERY CONFIG FIELD THE PANEL READS MUST ACTUALLY ARRIVE
--
-- The general form of the defect the rest of this file catches one field at
-- a time. html/app.js reads settings off the snapshot's `config` block, and
-- a name that never arrives is not an error -- it is `undefined`, which the
-- panel treats as "the operator did not set that", so it renders a default
-- and reports nothing.
--
-- Two shipped settings were lost exactly that way, both enforced by the
-- server and neither ever sent:
--
--   restoreLoadoutOnExit  the panel has a written line about what happens
--                         to a player's own guns, and deliberately says
--                         NOTHING when the field is absent. So the line
--                         could not appear on any server, and the question
--                         every player asks before their first round went
--                         unanswered by a panel that had the answer in it.
--
--   maxTeamSizeDifference the server refuses a start only when the sides
--                         differ by MORE than this. The panel, not knowing
--                         the number, warned on any difference at all -- so
--                         a 3v2 lobby was told the round could not start
--                         when it could, and hosts levelled sides nobody
--                         had objected to.
--
-- So this reads the panel's own source for what it asks for, and checks the
-- snapshot against it. Named fields cannot drift out one at a time again.
-- ========================================================================

--- Every (block, field) html/app.js reads off the snapshot's config.
---
--- Both spellings the file actually uses: the direct
--- `(cfg().match || {}).minPlayers`, and the two-step
--- `var teams = cfg().teams || {}` followed by `teams.allowUnequal`.
--- betting() is a named accessor for `cfg().betting`, so it is a third.
--- @return table<string, table<string, boolean>>
local function panelConfigReads()
    local handle = assert(io.open('../html/app.js', 'r'), 'cannot open html/app.js')
    local source = handle:read('a')
    handle:close()

    local reads = {}
    local function want(block, field)
        if not block or not field then return end
        reads[block] = reads[block] or {}
        reads[block][field] = true
    end

    -- (cfg().block || {}).field
    for block, field in source:gmatch("%(cfg%(%)%.(%w+)%s*||%s*{}%)%.(%w+)") do
        want(block, field)
    end

    -- var name = cfg().block || {}   ...then...   name.field
    for name, block in source:gmatch("var%s+(%w+)%s*=%s*cfg%(%)%.(%w+)%s*||%s*{}") do
        for field in source:gmatch(name .. "%.(%w+)") do want(block, field) end
    end

    -- betting() is cfg().betting under another name.
    for field in source:gmatch("betting%(%)%.(%w+)") do want('betting', field) end

    return reads
end

--- Field names the panel reads that are NOT config settings -- helpers and
--- locals that happen to share a variable name with a config block. Listed
--- rather than pattern-matched, so adding one is a decision somebody makes
--- on purpose.
local NOT_SETTINGS = {
    -- `ui` is also the name of a local holding an already-extracted block,
    -- and `teams` is a per-MATCH boolean on the match card as well as a
    -- config block. Neither is a setting this file can look for.
    teams = { teams = true },
    ui = { ui = true },
}

t.test('every config field html/app.js reads is present in the snapshot', function()
    local server = newArena()
    local config = server.snapshot(1).config
    t.isNotNil(config, 'the snapshot carries no config block at all')

    local reads = panelConfigReads()
    t.isTrue(next(reads) ~= nil,
        'no config reads were found in html/app.js, so this test proved nothing')

    local missing = {}
    for block, fields in pairs(reads) do
        local sent = config[block]
        if sent == nil then
            missing[#missing + 1] = block .. ' (the whole block)'
        else
            for field in pairs(fields) do
                local skip = (NOT_SETTINGS[block] or {})[field]
                if not skip and sent[field] == nil then
                    missing[#missing + 1] = block .. '.' .. field
                end
            end
        end
    end
    table.sort(missing)

    t.equals(table.concat(missing, ', '), '',
        'the panel reads these off the snapshot and the server never sends them. They arrive as '
        .. 'undefined, which the panel reads as "the operator did not set that" -- so it renders a '
        .. 'default and says nothing, on every server')
end)

--- Every boolean leaf anywhere under `root`, as dotted path -> value.
--- @param root table
--- @return table<string, boolean>
local function booleanLeaves(root, prefix, out, seen)
    out, seen = out or {}, seen or {}
    if seen[root] then return out end
    seen[root] = true
    for key, value in pairs(root) do
        local path = (prefix or '') .. tostring(key)
        if type(value) == 'boolean' then
            out[path] = value
        elseif type(value) == 'table' then
            booleanLeaves(value, path .. '.', out, seen)
        end
    end
    return out
end

--- The blocks of Config the snapshot sends a version of. Named rather than
--- scraped, because scraping the SOURCE is self-defeating: a field hardcoded
--- to a constant no longer mentions its own setting, so it drops out of the
--- list of things to check at exactly the moment it stops working. The first
--- version of this test did that and let the hardcoding through.
local SENT_BLOCKS = { 'Match', 'Teams', 'Loadouts', 'Betting' }

t.test('DEFECT: every boolean the panel is sent carries the operator\'s answer, not its opposite', function()
    -- PRESENCE IS NOT FIDELITY, and the test above only asks for presence. A
    -- field sent with the wrong value is present, correctly named, and wrong
    -- -- which is what a flipped comparison produces: the panel draws a
    -- control the server will not honour, or hides one it would.
    --
    -- Mutations turning `Config.Match.restoreLoadoutOnExit == true` into
    -- `~= true`, and `fighter.ownSideOnly ~= false` into `~= true`, both
    -- survived the whole suite. Neither changes whether the field arrives.
    --
    -- AND A DIFFERENTIAL IS NOT ENOUGH EITHER. Flipping the setting and
    -- asserting the snapshot changed passes against both of those, because
    -- an inverted comparison still RESPONDS to the setting -- it just answers
    -- backwards. The value has to be compared.
    --
    -- Checked at BOTH values, because a field hardcoded to the shipped
    -- default agrees with config until somebody changes it.
    local shipped = newArena().env.Config
    local checked, wrong = 0, {}

    for _, block in ipairs(SENT_BLOCKS) do
        for path, current in pairs(booleanLeaves(shipped[block] or {})) do
            local expected = block:lower() .. '.' .. path

            -- Only where the snapshot keeps the same shape. A field it
            -- renames or restructures is covered by the round-trip tests
            -- further up this file; this one is about fidelity, not layout.
            if booleanLeaves(newArena().snapshot(1).config)[expected] ~= nil then
                checked = checked + 1
                for _, value in ipairs({ true, false }) do
                    local sent = booleanLeaves(newArena(function(config)
                        local target = config[block]
                        local segments = {}
                        for segment in path:gmatch('[^.]+') do segments[#segments + 1] = segment end
                        for index = 1, #segments - 1 do target = target[segments[index]] end
                        target[segments[#segments]] = value
                    end).snapshot(1).config)

                    if sent[expected] ~= value then
                        wrong[#wrong + 1] = ('Config.%s.%s set to %s arrives as config.%s = %s')
                            :format(block, path, tostring(value), expected, tostring(sent[expected]))
                    end
                end
            end
            local _ = current
        end
    end
    table.sort(wrong)

    t.isTrue(checked >= 8,
        ('only %d boolean settings were compared -- the walk is broken'):format(checked))
    t.equals(table.concat(wrong, '; '), '',
        'the panel is told the opposite of what the operator set')
end)

t.test('and that includes the nested ones, three levels down', function()
    -- fighterBets.ownSideOnly decides whether a fighter may back the OTHER
    -- side. The panel drawing the wrong answer offers a bet the server will
    -- refuse, or hides one it would take -- and it lives under
    -- Config.Betting.fighterBets, which a two-level walk never reaches.
    for _, value in ipairs({ true, false }) do
        local sent = booleanLeaves(newArena(function(config)
            config.Betting.fighterBets.ownSideOnly = value
        end).snapshot(1).config)

        t.equals(sent['betting.fighterBets.ownSideOnly'], value,
            ('ownSideOnly set to %s arrived as %s')
                :format(tostring(value), tostring(sent['betting.fighterBets.ownSideOnly'])))
    end
end)

t.test('and the two that were actually lost are named, so a failure says which', function()
    local config = newArena().snapshot(1).config

    t.isNotNil(config.match.restoreLoadoutOnExit,
        'the loadout tab cannot tell a player whether their own guns come back')
    t.isNotNil(config.teams.maxTeamSizeDifference,
        'the team picker is back to warning about any difference at all, including ones the server allows')
end)

os.exit(t.summary())
