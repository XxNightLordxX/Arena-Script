--[[
    crimson_arena/tests/teamlookup_spec.lua

    ONE TEAM, LOOKED UP BY ITS KEY -- AND WHAT THAT ANSWER HAS TO STAY.

    Arena.GetTeamByKey is asked on every blip pass on the client (the dot's
    colour, the outline's colour, the team-mate marker's colour) and at every
    team decision on the server (a pick in the lobby, a side-bet, the side a
    fighter is put on at the start). It used to answer by building the WHOLE
    enabled-team list -- a record per team, a sort closure, a sort -- and
    walking it for the one it wanted. It now reads the one entry it was asked
    for.

    NOTHING PINNED THE ANSWER ITSELF. With the `enabled == false` check
    deleted, every spec in the suite still passed: a side the operator had
    switched off could be picked in the lobby, backed with a side-bet, and
    fought on. So this file pins, against the REAL shared/arena.lua:

      * a switched-off side is not a side, on the shipped config and the
        moment an operator switches one off on a running server;
      * the record is the same five fields the picker list carries, as a
        FRESH table every call, read live off the config with no memo;
      * a key that is not a non-empty string is refused BEFORE the list is
        read, so an array-style list cannot answer for side 1;
      * the lobby, the side-bet book and the start all still refuse or
        re-seat a side that is switched off -- the three server callers that
        act on the answer;
      * the lookup costs one read of the list -- no list built, no sort;
      * and, over a grid and a seeded random sweep, it answers EXACTLY what
        the old build-and-walk answered, value for value and error for error,
        against a verbatim copy of that old code kept below.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teamlookup_spec')

local NAN = 0 / 0

-- ======================================================================
-- THE OLD CODE, VERBATIM, AS THE REFERENCE
--
-- This is Arena.GetEnabledTeams and Arena.GetTeamByKey exactly as they
-- stood before the lookup was made direct. It is loaded into the SAME
-- sandbox as the real file, so it reads the same live Config and the same
-- Arena.IsKey / Arena.ToInt, and only the lookup itself differs. Its own
-- private copy of the list builder is deliberate: if GetEnabledTeams is
-- ever changed on purpose, this reference must go on describing what the
-- lookup USED to answer, not follow it.
-- ======================================================================

local OLD_LOOKUP = [[
local function GetEnabledTeams()
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

return function(key)
    if not Arena.IsKey(key) then return nil end
    for _, team in ipairs(GetEnabledTeams()) do
        if team.key == key then return team end
    end
    return nil
end
]]

--- The old lookup, bound to one sandbox.
--- @param env table
--- @return function
local function oldLookupIn(env)
    return assert(load(OLD_LOOKUP, '=old GetTeamByKey', 't', env))()
end

-- ======================================================================
-- HELPERS
-- ======================================================================

--- A value as text that two equal values always share and two different
--- ones never do: integer and float are told apart, NaN equals NaN, and a
--- table is written with its keys sorted so construction order cannot
--- matter.
--- @param value any
--- @param depth integer?
--- @return string
local function canon(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == 'number' then
        if value ~= value then return 'nan' end
        return (math.type(value) or 'number') .. ':' .. tostring(value)
    end
    if kind == 'string' then return ('%q'):format(value) end
    if kind ~= 'table' then return kind .. ':' .. tostring(value) end
    if depth > 6 then return 'table:<deep>' end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    local texts = {}
    for index, key in ipairs(keys) do texts[index] = { canon(key, depth + 1), key } end
    table.sort(texts, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, pair in ipairs(texts) do
        out[#out + 1] = pair[1] .. '=' .. canon(value[pair[2]], depth + 1)
    end
    return '{' .. table.concat(out, ',') .. '}'
end

--- An error message without the file and line in front of it, so the old
--- copy (loaded from a string) and the real file can be compared on WHAT
--- went wrong rather than where the text of it lives.
--- @param message any
--- @return string
local function bare(message)
    return (tostring(message):gsub('^[^:]*:%d+: ', ''))
end

--- Asks both lookups the same question and says how they differ, or nil.
--- @return string|nil
local function differs(oldLookup, newLookup, key)
    local okOld, old = pcall(oldLookup, key)
    local okNew, new = pcall(newLookup, key)
    if okOld ~= okNew then
        return ('old %s, new %s'):format(okOld and ('answered ' .. canon(old)) or ('raised ' .. bare(old)),
            okNew and ('answered ' .. canon(new)) or ('raised ' .. bare(new)))
    end
    if not okOld then
        if bare(old) ~= bare(new) then
            return ('both raised, differently: old %q, new %q'):format(bare(old), bare(new))
        end
        return nil
    end
    if canon(old) ~= canon(new) then
        return ('old answered %s, new answered %s'):format(canon(old), canon(new))
    end
    return nil
end

local FIELDS = { 'blipColor', 'color', 'key', 'label', 'order' }

--- The field names of a record, sorted.
local function fieldsOf(record)
    local names = {}
    for name in pairs(record) do names[#names + 1] = tostring(name) end
    table.sort(names)
    return table.concat(names, ',')
end

--- @param seed integer
--- @return fun(n: integer?): integer -- 1..n, or the raw state with no n
local function newRng(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function(n)
        state = (state * 48271) % 2147483647
        if not n then return state end
        return (state % n) + 1
    end
end

-- ======================================================================
-- A SWITCHED-OFF SIDE IS NOT A SIDE
-- ======================================================================

t.test('a side that ships switched off is not found: bone and ember', function()
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list

    -- Asserted first, so this test cannot pass on a config that no longer
    -- ships them switched off.
    t.equals(list.bone.enabled, false, 'the shipped config no longer switches bone off')
    t.equals(list.ember.enabled, false, 'the shipped config no longer switches ember off')

    t.isNil(env.Arena.GetTeamByKey('bone'), 'a side the operator switched off was handed out')
    t.isNil(env.Arena.GetTeamByKey('ember'), 'a side the operator switched off was handed out')

    -- And the two that ship on ARE found, or the two lines above prove
    -- nothing about the switch.
    t.isNotNil(env.Arena.GetTeamByKey('crimson'), 'crimson ships on and was not found')
    t.isNotNil(env.Arena.GetTeamByKey('ash'), 'ash ships on and was not found')
end)

t.test('switching a side off on a running server takes effect on the very next lookup', function()
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list
    t.isNotNil(env.Arena.GetTeamByKey('crimson'))

    list.crimson.enabled = false
    t.isNil(env.Arena.GetTeamByKey('crimson'), 'crimson was still handed out after being switched off')
    t.isNotNil(env.Arena.GetTeamByKey('ash'), 'switching crimson off took ash with it')

    list.crimson.enabled = true
    t.isNotNil(env.Arena.GetTeamByKey('crimson'), 'crimson did not come back when switched back on')

    -- A side that ships off is switched ON the same way.
    list.bone.enabled = true
    local bone = env.Arena.GetTeamByKey('bone')
    t.isNotNil(bone, 'bone, switched on, was not found')
    t.equals(bone.label, 'Bone')
end)

t.test('ONLY a literal false switches a side off: nil, 0, "false" and true all leave it on', function()
    -- The boundary is exactly `enabled == false`, as it is in the picker
    -- list. A lookup that read `enabled ~= true`, or truthiness, would lose
    -- a side the picker still offers -- and a pick the panel offers that the
    -- server refuses is a button that never works.
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list
    for _, value in ipairs({ true, 0, 'false', 1, 'no', {} }) do
        list.crimson.enabled = value
        t.isNotNil(env.Arena.GetTeamByKey('crimson'),
            ('enabled = %s switched crimson off'):format(canon(value)))
    end
    list.crimson.enabled = nil
    t.isNotNil(env.Arena.GetTeamByKey('crimson'), 'enabled = nil (the setting left out) switched crimson off')
    list.crimson.enabled = false
    t.isNil(env.Arena.GetTeamByKey('crimson'), 'enabled = false left crimson on')
end)

-- ======================================================================
-- THE RECORD
-- ======================================================================

t.test('an enabled side is answered with exactly the five fields the picker carries', function()
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list

    for _, key in ipairs({ 'crimson', 'ash' }) do
        local team = env.Arena.GetTeamByKey(key)
        t.isNotNil(team, key .. ' was not found')
        t.equals(fieldsOf(team), table.concat(FIELDS, ','), key .. ' came back with the wrong set of fields')
        t.equals(team.key, key, 'the record names the wrong side')
        t.equals(team.label, list[key].label, key .. ': label')
        t.equals(team.color, list[key].color, key .. ': color, which the outline and the marker draw in')
        t.equals(team.blipColor, list[key].blipColor, key .. ': blipColor, which the map dot is drawn in')
        t.equals(team.order, list[key].order, key .. ': order')
        t.equals(math.type(team.order), 'integer', key .. ': order is not a whole number')
    end
end)

t.test('the answer is the same record GetEnabledTeams carries for that side, under every edit', function()
    -- TWO FUNCTIONS, ONE ANSWER. The picker is built from the list and every
    -- decision is taken off the lookup; if they ever disagree on a label or
    -- a colour, the panel says one thing and the map another.
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list
    local edits = {
        function() end,
        function() list.bone.enabled = true end,
        function() list.ash.label = nil end,
        function() list.crimson.order = '7' end,
        function() list.crimson.order = 'first' end,
        function() list.ash.color = nil end,
        function() list.bone.blipColor = 'red' end,
        function() list.jade = { label = 'Jade', color = '#00aa55', blipColor = 2, order = 0 } end,
        function() list.ember.enabled = nil end,
        function() list.crimson.enabled = false end,
    }
    for step, edit in ipairs(edits) do
        edit()
        local listed = {}
        for _, team in ipairs(env.Arena.GetEnabledTeams()) do
            listed[team.key] = true
            t.equals(canon(env.Arena.GetTeamByKey(team.key)), canon(team),
                ('edit %d: the lookup and the picker list disagree about %s'):format(step, team.key))
        end
        for key in pairs(list) do
            if not listed[key] then
                t.isNil(env.Arena.GetTeamByKey(key),
                    ('edit %d: %s is not in the picker list but the lookup found it'):format(step, key))
            end
        end
    end
end)

t.test('label falls back to the key, and order is read as a whole number or 999', function()
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list

    list.ash.label = nil
    t.equals(env.Arena.GetTeamByKey('ash').label, 'ash', 'a side with no label was not named by its key')
    list.ash.label = false
    t.equals(env.Arena.GetTeamByKey('ash').label, 'ash', 'label = false was not replaced by the key')

    local cases = {
        { value = '2', want = 2 }, { value = 2.9, want = 2 }, { value = -3, want = -3 },
        { value = 0, want = 0 }, { value = 'first', want = 999 }, { value = NAN, want = 999 },
        { value = {}, want = 999 }, { value = math.huge, want = 999 }, { value = true, want = 999 },
        { value = nil, want = 999 },
    }
    for _, case in ipairs(cases) do
        list.ash.order = case.value
        local team = env.Arena.GetTeamByKey('ash')
        t.equals(team.order, case.want, ('order = %s'):format(canon(case.value)))
        t.equals(math.type(team.order), 'integer', ('order = %s is not a whole number'):format(canon(case.value)))
    end
end)

t.test('every call hands back a FRESH table: writing into one changes neither the next answer nor the config', function()
    -- Callers keep the record for a moment and some write into what they
    -- are handed; a record shared between calls, or the config entry
    -- itself, would let one caller repaint a side for everybody after it.
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list
    local before = canon(list)

    local first = env.Arena.GetTeamByKey('crimson')
    local second = env.Arena.GetTeamByKey('crimson')
    t.isTrue(first ~= second, 'two lookups handed back the SAME table')
    t.isTrue(first ~= list.crimson, 'the lookup handed back the config entry itself')

    first.label = 'Scribbled'
    first.color = '#000000'
    first.blipColor = 99
    first.enabled = false
    first.key = 'ash'

    local third = env.Arena.GetTeamByKey('crimson')
    t.equals(third.label, 'Crimson', 'a caller writing into its record renamed the side for the next caller')
    t.equals(third.color, '#ff2233', 'a caller writing into its record repainted the side')
    t.equals(third.blipColor, 1, 'a caller writing into its record changed the dot colour')
    t.equals(third.key, 'crimson')
    t.equals(canon(list), before, 'the config itself was changed by a lookup or by a caller\'s write')
end)

t.test('NO MEMO: every edit to the list is seen by the very next lookup', function()
    -- The specs and the callers edit Config.Teams.list on a live server, and
    -- the picker list is rebuilt from it every time. A lookup that
    -- remembered would answer about a config that no longer exists.
    local env = Sandbox.newArenaEnv({})
    local list = env.Config.Teams.list
    t.equals(env.Arena.GetTeamByKey('ash').label, 'Ash')

    list.ash.label = 'Cinders'
    t.equals(env.Arena.GetTeamByKey('ash').label, 'Cinders', 'a renamed side kept its old name')
    list.ash.color = '#123456'
    t.equals(env.Arena.GetTeamByKey('ash').color, '#123456', 'a recoloured side kept its old colour')
    list.ash.blipColor = 38
    t.equals(env.Arena.GetTeamByKey('ash').blipColor, 38, 'a side kept its old dot colour')
    list.ash.order = 9
    t.equals(env.Arena.GetTeamByKey('ash').order, 9, 'a side kept its old order')

    list.jade = { label = 'Jade', color = '#00aa55', blipColor = 2, order = 5 }
    t.equals((env.Arena.GetTeamByKey('jade') or {}).label, 'Jade', 'a side added to the list was not found')

    list.ash = nil
    t.isNil(env.Arena.GetTeamByKey('ash'), 'a side taken out of the list was still found')

    -- A whole new list, as a reload would write it.
    env.Config.Teams.list = { onyx = { label = 'Onyx', color = '#111111', blipColor = 40, order = 1 } }
    t.isNil(env.Arena.GetTeamByKey('crimson'), 'a side from the replaced list was still found')
    t.equals((env.Arena.GetTeamByKey('onyx') or {}).label, 'Onyx', 'the new list was not read')
end)

t.test('no list, an empty list, or `false` means no sides, and nothing raises', function()
    local env = Sandbox.newArenaEnv({})
    for _, empty in ipairs({ {}, false }) do
        env.Config.Teams.list = empty
        for _, key in ipairs({ 'crimson', 'ash', 'bone', 'format', '__index' }) do
            local ok, team = pcall(env.Arena.GetTeamByKey, key)
            t.isTrue(ok, ('list = %s, key %s: raised %s'):format(canon(empty), key, tostring(team)))
            t.isNil(team, ('list = %s answered for %s'):format(canon(empty), key))
        end
    end
    env.Config.Teams.list = nil
    for _, key in ipairs({ 'crimson', 'ash', 'format' }) do
        local ok, team = pcall(env.Arena.GetTeamByKey, key)
        t.isTrue(ok, 'no list at all raised: ' .. tostring(team))
        t.isNil(team, 'no list at all answered for ' .. key)
    end
end)

-- ======================================================================
-- THE KEY IS CHECKED FIRST
-- ======================================================================

t.test('a key that is not a non-empty string is refused before the list is read', function()
    -- AN ARRAY-STYLE LIST IS THE CASE THIS IS FOR. `list = { {label=...} }`
    -- is a list an operator can write, and its sides live at 1, 2, 3. A
    -- lookup that read the entry before checking the key would answer for
    -- side 1 -- while Arena.CountTeams, which filters with the same IsKey,
    -- would never count anybody on it.
    local env = Sandbox.newArenaEnv({})
    env.Config.Teams.list = {
        { label = 'First', color = '#ff0000', blipColor = 1, order = 1 },
        { label = 'Second', color = '#0000ff', blipColor = 3, order = 2 },
        [true] = { label = 'Yes' },
    }
    for _, key in ipairs({ 1, 2, 1.0, true, false, {}, NAN, '', 0 }) do
        t.isNil(env.Arena.GetTeamByKey(key), ('key %s was answered'):format(canon(key)))
    end
    t.isNil(env.Arena.GetTeamByKey(nil), 'a nil key was answered')

    -- AND NOT READ AT ALL: a list that raises on any access proves the key
    -- was refused before the list was touched, not merely that nothing
    -- happened to be there.
    env.Config.Teams.list = setmetatable({}, {
        __index = function(_, key) error('the list was read for key ' .. tostring(key)) end,
        __pairs = function() error('the list was walked') end,
    })
    for _, key in ipairs({ 1, 1.0, true, {}, NAN, '' }) do
        local ok, team = pcall(env.Arena.GetTeamByKey, key)
        t.isTrue(ok, ('key %s reached the list: %s'):format(canon(key), tostring(team)))
        t.isNil(team)
    end
    local ok, team = pcall(env.Arena.GetTeamByKey, nil)
    t.isTrue(ok, 'a nil key reached the list: ' .. tostring(team))
end)

-- ======================================================================
-- THE COST
-- ======================================================================

t.test('a lookup is ONE read of the list: no team list is built and nothing is sorted', function()
    -- WHAT THE CHANGE WAS FOR, pinned so an edit that brings the cost back
    -- fails here. The old lookup built a record for every enabled side,
    -- sorted them with a fresh closure and walked the result -- six times a
    -- blip pass in a five-a-side round, on every client, for one entry.
    local env = Sandbox.newArenaEnv({})

    local built, sorted = 0, 0
    local realList = env.Arena.GetEnabledTeams
    env.Arena.GetEnabledTeams = function(...)
        built = built + 1
        return realList(...)
    end
    env.table = setmetatable({
        sort = function(...)
            sorted = sorted + 1
            return table.sort(...)
        end,
    }, { __index = table })

    local real = env.Config.Teams.list
    local reads, walks = 0, 0
    env.Config.Teams.list = setmetatable({}, {
        __index = function(_, key)
            reads = reads + 1
            return real[key]
        end,
        __pairs = function()
            walks = walks + 1
            return next, real, nil
        end,
    })

    for _, key in ipairs({ 'crimson', 'ash', 'bone', 'ember', 'nobody' }) do
        reads, walks, built, sorted = 0, 0, 0, 0
        env.Arena.GetTeamByKey(key)
        t.equals(built, 0, key .. ': the lookup built the whole team list to find one side')
        t.equals(sorted, 0, key .. ': the lookup sorted the team list to find one side')
        t.equals(walks, 0, key .. ': the lookup walked the whole team list')
        t.equals(reads, 1, key .. ': the lookup did not read exactly its own entry')
    end

    -- A key refused up front costs nothing at all.
    reads, walks = 0, 0
    env.Arena.GetTeamByKey(1)
    env.Arena.GetTeamByKey('')
    t.equals(reads + walks, 0, 'a key that is not a key still read the list')

    -- The answers are unaffected by being counted.
    t.equals(env.Arena.GetTeamByKey('crimson').label, 'Crimson')
    t.isNil(env.Arena.GetTeamByKey('bone'))
end)

-- ======================================================================
-- OLD AGAINST NEW
-- ======================================================================

--- The grid the change was vetted on: sixteen edits to the shipped list,
--- plus no list at all.
local MUTATIONS = {
    { 'as shipped', function() end },
    { 'crimson switched off', function(list) list.crimson.enabled = false end },
    { 'crimson enabled = nil', function(list) list.crimson.enabled = nil end },
    { 'crimson enabled = 0', function(list) list.crimson.enabled = 0 end },
    { "crimson enabled = 'false'", function(list) list.crimson.enabled = 'false' end },
    { 'ash has no label', function(list) list.ash.label = nil end },
    { "ash order = '2'", function(list) list.ash.order = '2' end },
    { "ash order = 'first'", function(list) list.ash.order = 'first' end },
    { 'ash order = {}', function(list) list.ash.order = {} end },
    { 'ash order = NaN', function(list) list.ash.order = NAN end },
    { 'every order tied', function(list) for _, team in pairs(list) do team.order = 1 end end },
    { 'crimson has no color', function(list) list.crimson.color = nil end },
    { "crimson blipColor = 'red'", function(list) list.crimson.blipColor = 'red' end },
    { 'extra fields', function(list)
        list.crimson.extra = 'x'
        list.crimson.key = 'ash'
        list.ash.label = 12
    end },
    { 'a side added', function(list)
        list.jade = { label = 'Jade', color = '#00aa55', blipColor = 2, order = 0 }
    end },
    { 'every side removed', function(list) for key in pairs(list) do list[key] = nil end end },
}

--- Sixteen keys: the four shipped sides, one added, unknown and wrongly
--- cased names, and everything that is not a key at all.
local KEYS = {
    'crimson', 'ash', 'bone', 'ember', 'jade', 'nobody', 'Crimson', '',
    nil, 1, 1.0, true, {}, NAN, 'format', '__index',
}
local KEY_COUNT = 16

t.test('DIFFERENTIAL: the grid it was vetted on -- 16 edits x 16 keys, plus no list -- old and new agree', function()
    local cases, mismatches = 0, {}
    local function run(label, mutate)
        local env = Sandbox.newArenaEnv({})
        mutate(env.Config.Teams.list)
        if label == 'no list at all' then env.Config.Teams.list = nil end
        local old = oldLookupIn(env)
        for index = 1, KEY_COUNT do
            local key = KEYS[index]
            local before = canon(env.Config.Teams)
            local why = differs(old, env.Arena.GetTeamByKey, key)
            cases = cases + 1
            if why then mismatches[#mismatches + 1] = ('%s / key %s: %s'):format(label, canon(key), why) end
            if canon(env.Config.Teams) ~= before then
                mismatches[#mismatches + 1] = ('%s / key %s: the lookup changed the config'):format(label, canon(key))
            end
        end
    end
    for _, mutation in ipairs(MUTATIONS) do run(mutation[1], mutation[2]) end
    run('no list at all', function() end)

    t.equals(cases, 17 * 16, 'the grid did not run every case')
    t.equals(#mismatches, 0, table.concat(mismatches, '\n'))
end)

t.test('DIFFERENTIAL: and with no Config.Teams at all, both raise the same error', function()
    -- The one shape where both answers are an error. Not a config anybody
    -- ships -- config.lua always writes the block -- but "the same answer"
    -- includes the failures.
    local env = Sandbox.newArenaEnv({})
    env.Config.Teams = nil
    local old = oldLookupIn(env)
    local raised = 0
    for index = 1, KEY_COUNT do
        local key = KEYS[index]
        local why = differs(old, env.Arena.GetTeamByKey, key)
        t.isNil(why, ('key %s: %s'):format(canon(key), tostring(why)))
        if not pcall(env.Arena.GetTeamByKey, key) then raised = raised + 1 end
    end
    -- The nine non-empty string keys raise; the rest are refused before the
    -- config is read.
    t.equals(raised, 9, 'the missing block should raise for exactly the nine string keys')
end)

--- One random side, drawn from values an operator could really type and a
--- few they could not.
local ENABLED = { true, false, false, nil, 0, 'false', 1 }
local LABELS = { 'Crimson', 'Ash', 'L', '', 7, false }
local COLORS = { '#112233', '#ff2233', 'red', 5 }
local BLIPS = { 1, 3, 5, 17, '2', 'red', 2.5 }
local ORDERS = { 1, 2, 3, 4, -1, 0, '2', 'first', 2.9, NAN, {}, math.huge, true }
local POOL = { 'crimson', 'ash', 'bone', 'ember', 'jade', 'onyx', 'Crimson', 'x', 'format' }
local NOT_KEYS = { '', 1, 1.0, true, false, {}, NAN, 'nobody', '__index' }

local function randomSide(rng)
    if rng(20) == 1 then return 'junk' end   -- a string entry: indexes to nil in both
    local side = {}
    local function maybe(field, values)
        local pick = rng(#values + 1)
        if pick <= #values then side[field] = values[pick] end
    end
    maybe('enabled', ENABLED)
    maybe('label', LABELS)
    maybe('color', COLORS)
    maybe('blipColor', BLIPS)
    maybe('order', ORDERS)
    if rng(4) == 1 then side.extra = 'e' end
    return side
end

t.test('DIFFERENTIAL: 400 seeded random lists x 5 keys each -- old and new agree on every one', function()
    -- ONE sandbox, the list REPLACED between rounds: both lookups read the
    -- config live, so this is also a second proof there is no memo -- one
    -- would answer round N+1 from round N.
    local rng = newRng(20260925)
    local env = Sandbox.newArenaEnv({})
    local old = oldLookupIn(env)
    local cases, found, refused, mismatches = 0, 0, 0, {}

    for round = 1, 400 do
        local list = {}
        for _ = 1, rng(7) - 1 do list[POOL[rng(#POOL)]] = randomSide(rng) end
        env.Config.Teams.list = list

        local present = {}
        for key in pairs(list) do present[#present + 1] = key end
        table.sort(present)

        for _ = 1, 5 do
            -- A third not keys at all, a third any name, a third a name this
            -- list really holds -- so hits are common enough to mean something.
            local key
            local draw = rng(3)
            if draw == 1 then
                key = NOT_KEYS[rng(#NOT_KEYS)]
            elseif draw == 2 or #present == 0 then
                key = POOL[rng(#POOL)]
            else
                key = present[rng(#present)]
            end
            local why = differs(old, env.Arena.GetTeamByKey, key)
            cases = cases + 1
            if why then
                mismatches[#mismatches + 1] = ('round %d, list %s, key %s: %s')
                    :format(round, canon(list), canon(key), why)
            end
            if env.Arena.GetTeamByKey(key) then found = found + 1 else refused = refused + 1 end
        end
    end

    t.equals(cases, 2000)
    t.equals(#mismatches, 0, table.concat(mismatches, '\n', 1, math.min(#mismatches, 5)))
    -- A sweep that only ever answered nil would agree with anything.
    t.isTrue(found > 400, ('only %d of the lookups found a side, so the sweep proves little'):format(found))
    t.isTrue(refused > 400, ('only %d of the lookups were refused'):format(refused))
end)

-- ======================================================================
-- THE ONE INTENDED DIFFERENCE: A BROKEN LIST
-- ======================================================================

t.test('ONE BAD ENTRY IN THE LIST NO LONGER TAKES EVERY LOOKUP DOWN WITH IT', function()
    -- A NUMBER KEY BESIDE THE NAMED SIDES, at the same order as one of them.
    -- The old lookup sorted the whole list to find one entry, and Lua cannot
    -- order 'crimson' against 7 -- so EVERY lookup raised, and on the client
    -- that raise is inside the blip pass: no dots, no outline, no marker for
    -- anybody. The picker list still refuses such a config at start-up
    -- (Arena.ValidateConfig reads it); what changes is that one mistyped
    -- bracket no longer takes the colour of every side with it.
    local env = Sandbox.newArenaEnv({})
    env.Config.Teams.list[7] = { label = 'Seven', color = '#777777', blipColor = 7, order = 1 }
    local old = oldLookupIn(env)
    t.isFalse((pcall(old, 'crimson')), 'the reference no longer raises here, so this proves nothing')

    local ok, crimson = pcall(env.Arena.GetTeamByKey, 'crimson')
    t.isTrue(ok, 'a number key in the list still takes every lookup down: ' .. tostring(crimson))
    t.equals(type(crimson) == 'table' and crimson.color, '#ff2233', 'crimson was not answered with its colour')
    local okAsh, ash = pcall(env.Arena.GetTeamByKey, 'ash')
    t.isTrue(okAsh and ash ~= nil and ash.blipColor == 3, 'ash was not answered: ' .. tostring(ash))
    t.isNil(env.Arena.GetTeamByKey(7), 'the number key itself was handed out as a side')

    -- A SIDE THAT IS NOT A TABLE costs only its own lookup now.
    local env2 = Sandbox.newArenaEnv({})
    env2.Config.Teams.list.bogus = 5
    local old2 = oldLookupIn(env2)
    t.isFalse((pcall(old2, 'crimson')), 'the reference no longer raises here, so this proves nothing')
    local ok2, crimson2 = pcall(env2.Arena.GetTeamByKey, 'crimson')
    t.isTrue(ok2 and crimson2 ~= nil and crimson2.label == 'Crimson',
        'one entry that is not a table still takes every other side down: ' .. tostring(crimson2))
end)

-- ======================================================================
-- THE SERVER CALLERS THAT ACT ON THE ANSWER
-- ======================================================================

--- The real server files, with just enough of the framework to create a
--- team lobby, take a side-bet and start a round. Same shape as
--- lobbystate_spec's fixture, kept separate so neither can break the other.
--- @param mutate fun(config: table)?
--- @return table server
local function newServer(mutate)
    local players = {}
    for src = 1, 5 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 50000, bank = 50000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local clock = 0
    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0, y = 2565.1, z = 46.7 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Refresh = function() return true end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.autoStartWhenAllReady = false
    env.Config.Betting.enabled = true
    env.Config.Betting.spectatorBets.enabled = true
    if mutate then mutate(env.Config) end
    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end
    return {
        env = env, config = env.Config, qbx = qbx,
        lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting,
        step = function(times) for _ = 1, (times or 1) do threads.step() end end,
    }
end

--- A team lobby: 1 hosts on crimson, 2 sits on ash.
local function teamLobby(mutate)
    local s = newServer(mutate)
    local id, why = s.lobby.Create(1, 'trailerpark', 'tdm', 0, nil, nil, nil)
    t.isNotNil(id, 'a team lobby could not be created: ' .. tostring(why))
    t.isTrue(s.lobby.SetTeam(1, 'crimson'), 'the host could not pick crimson')
    local joined, reason = s.lobby.Join(2, id, 'ash', nil)
    t.isTrue(joined, 'the second fighter could not join on ash: ' .. tostring(reason))
    return s, id
end

t.test('the lobby refuses a side that ships switched off, for a pick and for a join', function()
    local s, id = teamLobby()

    local ok, why = s.lobby.SetTeam(2, 'bone')
    t.isFalse(ok, 'a fighter moved onto a side the operator switched off')
    t.equals(why, 'error.team_unavailable')
    t.equals(s.lobby.Get(id).players[2].team, 'ash', 'the refused pick still moved them')

    local joined, joinWhy = s.lobby.Join(3, id, 'bone', nil)
    t.isFalse(joined, 'a fighter joined on a side the operator switched off')
    t.equals(joinWhy, 'error.team_unavailable')
    t.isNil(s.lobby.Get(id).players[3], 'the refused join still took a seat')

    -- The same answer as a side that does not exist at all.
    local okUnknown, whyUnknown = s.lobby.SetTeam(2, 'nobody')
    t.isFalse(okUnknown)
    t.equals(whyUnknown, 'error.team_unavailable')
end)

t.test('and a side switched off on a running server is refused from the next click', function()
    local s, id = teamLobby()
    local list = s.config.Teams.list

    list.crimson.enabled = false
    local ok, why = s.lobby.SetTeam(2, 'crimson')
    t.isFalse(ok, 'a fighter moved onto a side switched off a moment ago')
    t.equals(why, 'error.team_unavailable')

    list.crimson.enabled = true
    t.isTrue(s.lobby.SetTeam(2, 'crimson'), 'switched back on, the side still refused a pick')
    t.equals(s.lobby.Get(id).players[2].team, 'crimson')
end)

t.test('the side-bet book refuses a side that is switched off, even with a fighter standing on it', function()
    local s, id = teamLobby()
    s.lobby.MarkPanelOpen(4)

    local ok, why = s.betting.PlaceSpectatorBet(4, id, 'bone', 1000, 'cash')
    t.isFalse(ok, 'a side-bet was sold on a side the operator switched off')
    t.equals(why, 'error.bet_invalid_pick')

    -- ash has a fighter on it, and is switched off under them: the book
    -- must not take money on a side the server no longer recognises.
    s.config.Teams.list.ash.enabled = false
    local okAsh, whyAsh = s.betting.PlaceSpectatorBet(4, id, 'ash', 1000, 'cash')
    t.isFalse(okAsh, 'a side-bet was sold on a side switched off under its fighter')
    t.equals(whyAsh, 'error.bet_invalid_pick')

    -- And the same bet on a side that IS on goes through, or the refusals
    -- above could be refusing everything.
    t.isTrue(s.betting.PlaceSpectatorBet(4, id, 'crimson', 1000, 'cash') == true,
        'a side-bet on an enabled side with a fighter on it was refused')
end)

t.test('a fighter whose side was switched off before the start is fought on a side that is on', function()
    -- server/match.lua's start re-seats anybody whose side the lookup does
    -- not recognise. A lookup that still answered for a switched-off side
    -- would put a round on the ground with a side the picker never offered.
    local s, id = teamLobby(function(config) config.Teams.list.bone.enabled = true end)
    local joined, reason = s.lobby.Join(3, id, 'bone', nil)
    t.isTrue(joined, 'the third fighter could not join on bone while it was on: ' .. tostring(reason))

    s.config.Teams.list.bone.enabled = false
    for src in pairs(s.lobby.Get(id).players) do s.lobby.SetReady(src, true) end
    -- Begin, which is what the host's Start button reaches, is where sides
    -- are checked and filled in.
    local started, why = s.match.Begin(id, 1)
    t.isTrue(started, 'the round would not start: ' .. tostring(why))
    s.step(1)

    local team = s.lobby.Get(id).players[3].team
    t.isTrue(team == 'crimson' or team == 'ash',
        ('the fighter on a switched-off side was fought on %s'):format(tostring(team)))
    t.equals(s.lobby.Get(id).players[1].team, 'crimson', 'a fighter on an enabled side was moved')
    t.equals(s.lobby.Get(id).players[2].team, 'ash', 'a fighter on an enabled side was moved')
end)

os.exit(t.summary())
