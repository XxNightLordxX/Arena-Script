--[[
    crimson_arena/tests/exports_spec.lua

    THE PUBLIC SURFACE, AND WHETHER IT IS SAFE TO HAND OUT.

    server/exports.lua is the one file other resources on the server are meant
    to talk to. That makes it the only part of this resource whose SHAPE is a
    promise: once sc-dispatch or a phone app reads `pot` off GetMatches, the
    day that field changes their server goes wrong quietly -- no error, just a
    wrong number on somebody's screen. Nothing else in this repository has
    that property, so nothing else needed a file like this one.

    THREE THINGS ARE PINNED HERE, and each of them is a way the file could go
    wrong without a single test failing anywhere else:

      1. WHICH NAMES EXIST. A renamed export is a caller's error at run time,
         on their server, in their code.

      2. THAT NOTHING INTERNAL LEAKS. ArenaLobby.All() hands back the LIVE
         match tables. An export that passed one through would let any
         resource on the box rename a match, empty its roster or zero its pot
         by writing to a field, and the arena would never know. The test below
         writes to what came back and then checks the arena's own copy.

      3. THAT NOTHING THROWS INTO A CALLER. A resource asking the arena a
         question must not be able to die because the arena is mid-restart or
         a module has not loaded. Every body is asked again with the modules
         it depends on removed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('exports_spec')

--- Loads server/exports.lua with the arena modules stubbed, and captures
--- every export it registers.
---
--- THE STUBS ANSWER THE REAL SHAPES, read out of the files rather than
--- invented: ArenaLobby.All returns match tables, OwedKit returns rows with
--- `weapons` and `items`, Outstanding returns a count AND a total.
--- @param strip table? -- module names to remove before loading
local function newExports(strip)
    local registered = {}
    local live = {
        { id = 'm1', label = 'Trailer Park', arenaKey = 'trailerpark', modeKey = 'ffa',
          state = 'live', players = { [1] = {}, [2] = {} } },
        { id = 'm2', label = 'Docks', arenaKey = 'docks', modeKey = 'ffa',
          state = 'lobby', players = {} },
    }
    local slate = {
        { citizenid = 'CID001', count = 1,
          weapons = { { name = 'WEAPON_PISTOL', serial = 'AA1' } }, items = {} },
        { citizenid = 'CID002', count = 0, weapons = {},
          items = { { name = 'bandage', amount = 3 } } },
    }

    local env = Sandbox.newEnv({
        exports = setmetatable({}, {
            __call = function(_self, name, fn) registered[name] = fn end,
        }),
        ArenaHoursOpen = function() return true end,
        ArenaLobby = {
            All = function() return live end,
            PlayerCount = function(match)
                local n = 0
                for _ in pairs(match.players or {}) do n = n + 1 end
                return n
            end,
        },
        ArenaBetting = {
            GetPot = function(matchId) return matchId == 'm1' and 500 or 0 end,
            Outstanding = function() return 2, 750 end,
        },
        ArenaAmmo = {
            OwedKit = function() return slate end,
        },
        ArenaDispatch = {
            IsPlayerInArena = function(src) return src == 7 end,
            GetPlayerMatchId = function(src) return src == 7 and 'm1' or nil end,
            -- A FRESH TABLE PER CALL, as the real one builds. The export does
            -- not copy it again, so a double handing back one shared table
            -- would make a no-leak claim pass for the wrong reason.
            GetArenaPlayers = function() return { [7] = 'm1' } end,
            -- 7 is fighting; 8 is the one who just left, which is the case
            -- ShouldSuppressAlert exists for and IsPlayerInArena answers no to.
            ShouldSuppressAlert = function(src) return src == 7 or src == 8 end,
        },
    })

    for _, name in ipairs(strip or {}) do env[name] = nil end

    Sandbox.loadInto('../Crimson-Arena/server/exports.lua', env)

    return {
        env = env,
        live = live,
        slate = slate,
        names = function()
            local out = {}
            for name in pairs(registered) do out[#out + 1] = name end
            table.sort(out)
            return out
        end,
        call = function(name, ...)
            local fn = registered[name]
            if not fn then error('no export called ' .. tostring(name), 2) end
            return fn(...)
        end,
        has = function(name) return registered[name] ~= nil end,
    }
end

-- ======================================================================
-- WHICH NAMES EXIST
-- ======================================================================

t.test('every export this resource promises is registered, and nothing else', function()
    -- NAMED ONE BY ONE rather than counted. A count passes when one is
    -- renamed and another added in the same commit, which is exactly the
    -- change that breaks somebody else's server.
    local f = newExports()

    t.equals(table.concat(f.names(), ' '),
        'GetArenaPlayers GetMatches GetOwedKit GetOwedMoney GetPlayerMatchId '
        .. 'GetPot IsArenaOpen IsPlayerInArena ShouldSuppressAlert',
        'the public surface changed -- every caller of a removed or renamed '
        .. 'export breaks at run time, on their server, and this is the only '
        .. 'place that says so')
end)

-- ======================================================================
-- WHAT THEY ANSWER
-- ======================================================================

-- ======================================================================
-- THE THREE THAT MOVED IN FROM server/dispatch.lua
--
-- Same names, same answers, same shapes -- a resource already calling them
-- must not be able to tell they moved, which is the only acceptable way to
-- move an export. These pin that.
-- ======================================================================

t.test('IsPlayerInArena answers for one player', function()
    local f = newExports()
    t.isTrue(f.call('IsPlayerInArena', 7))
    t.isFalse(f.call('IsPlayerInArena', 3), 'somebody outside a match answered as in one')
end)

t.test('and answers a real BOOLEAN, whatever the module hands back', function()
    -- MEASURED: dropping the `== true` from this export left every other test
    -- green, because the fixture's stub answers a real boolean and so does
    -- the live one today. The export's promise is a boolean -- a caller may
    -- compare it, or send it over a wire -- so the shape has to hold even
    -- when what it asked answered something else.
    --
    -- AND IT FAILS CLOSED, which is the half worth stating: `== true` is an
    -- identity test rather than a truthiness one, so a truthy table answers
    -- FALSE. For "is this player in a match", an answer nobody can read is
    -- safer treated as no. This asserts the type first, because that is what
    -- tells the coercion from its absence, and the direction second.
    local f = newExports()

    for _, shape in ipairs({ { 'truthy table' }, 0, 'yes' }) do
        f.env.ArenaDispatch.IsPlayerInArena = function() return shape end

        local got = f.call('IsPlayerInArena', 7)
        t.equals(type(got), 'boolean',
            ('a %s was passed through to the caller instead of a boolean'):format(type(shape)))
        t.isFalse(got, 'an answer that is not literally true should read as not-in-a-match')
    end

    -- THE CONTROL. A real `true` must still come back as true, or the
    -- coercion above is just breaking the export.
    f.env.ArenaDispatch.IsPlayerInArena = function() return true end
    t.isTrue(f.call('IsPlayerInArena', 7), 'a player who IS in a match answered false')
end)

t.test('GetPlayerMatchId answers the id, or nil for somebody not in a match', function()
    local f = newExports()
    t.equals(f.call('GetPlayerMatchId', 7), 'm1')
    t.isNil(f.call('GetPlayerMatchId', 3), 'a player in no match was given a match id')
end)

t.test('GetArenaPlayers answers everybody in a match, keyed by server id', function()
    local f = newExports()
    t.equals(f.call('GetArenaPlayers')[7], 'm1', 'the player in a match is not in the answer')
end)

t.test('ShouldSuppressAlert covers the player who JUST left, where IsPlayerInArena does not',
function()
    -- The whole reason the export exists. An alert is raised from a death,
    -- and the arena's flag comes down when the round resolves -- often before
    -- the other script gets round to filing the call.
    local f = newExports()

    t.isTrue(f.call('ShouldSuppressAlert', 7), 'a fighter\'s alert was not suppressed')
    t.isTrue(f.call('ShouldSuppressAlert', 8),
        'somebody who left the round a moment ago would still be paged')
    t.isFalse(f.call('IsPlayerInArena', 8),
        'the fixture no longer shows the gap the two answers differ over')
    t.isFalse(f.call('ShouldSuppressAlert', 3),
        'an ordinary city death was silenced -- that is a real player bleeding out')
end)

t.test('and it FAILS LOUD, unlike every other export here', function()
    -- Every other fallback in exports.lua is the quiet answer. This one is
    -- the loud one on purpose: a spurious alert during an arena round is an
    -- annoyance, a swallowed one for a city death is not. MEASURED -- flip
    -- the fallback to `true` and this is the only test that notices.
    for _, f in ipairs({ newExports({ 'ArenaDispatch' }), newExports() }) do
        if f.env.ArenaDispatch then
            f.env.ArenaDispatch.ShouldSuppressAlert = function() error('boom') end
        end
        t.isFalse(f.call('ShouldSuppressAlert', 7),
            'an arena that could not answer told a medical script to stay silent')
    end
end)

t.test('and it answers a real BOOLEAN too', function()
    local f = newExports()
    for _, shape in ipairs({ { 'truthy table' }, 0, 'yes' }) do
        f.env.ArenaDispatch.ShouldSuppressAlert = function() return shape end
        local got = f.call('ShouldSuppressAlert', 7)
        t.equals(type(got), 'boolean',
            ('a %s was passed through to the caller instead of a boolean'):format(type(shape)))
        t.isFalse(got, 'an unreadable answer should raise the alert, not swallow it')
    end
end)

t.test('and all three answer quietly on a build with no dispatch module', function()
    local f = newExports({ 'ArenaDispatch' })

    t.isFalse(f.call('IsPlayerInArena', 7), 'a build that cannot tell said somebody IS in a match')
    t.isNil(f.call('GetPlayerMatchId', 7))

    -- COUNTED WITH pairs, NOT `#`. GetArenaPlayers answers a map keyed by
    -- SERVER ID -- { [7] = 'm1' } -- and `#` on that is 0 whatever is in it,
    -- so the assertion this replaces could not fail for any roster at all.
    local roster, n = f.call('GetArenaPlayers'), 0
    for _ in pairs(roster) do n = n + 1 end
    t.equals(n, 0, 'a build with no dispatch module handed out a roster')
end)

t.test('and THAT count really can fail, which `#` on a map never could', function()
    -- The control for the line above. With the module present the same count
    -- has to come back non-zero, or the fix is just a different way of
    -- asserting nothing.
    local f = newExports()
    local roster, n = f.call('GetArenaPlayers'), 0
    for _ in pairs(roster) do n = n + 1 end

    t.equals(n, 1, 'the roster count sees nothing even when somebody is fighting')
    t.equals(#roster, 0, 'the fixture no longer shows why `#` was the wrong tool here')
end)

t.test('IsArenaOpen answers the schedule', function()
    local f = newExports()
    t.isTrue(f.call('IsArenaOpen'))

    f.env.ArenaHoursOpen = function() return false end
    t.isFalse(f.call('IsArenaOpen'), 'a shut arena reported itself open')
end)

t.test('GetMatches answers one flat row per match', function()
    local f = newExports()
    local rows = f.call('GetMatches')

    t.equals(#rows, 2, 'the match list came back the wrong length')
    t.equals(rows[1].id, 'm1')
    t.equals(rows[1].label, 'Trailer Park')
    t.equals(rows[1].state, 'live')
    t.equals(rows[1].players, 2, 'the roster count is wrong')
    t.equals(rows[1].pot, 500, 'the pot did not reach the row')
    t.equals(rows[2].pot, 0, 'a match with nothing staked reported a pot')
end)

t.test('GetPot answers one match, and zero for one that does not exist', function()
    local f = newExports()
    t.equals(f.call('GetPot', 'm1'), 500)
    t.equals(f.call('GetPot', 'nosuchmatch'), 0, 'an unknown match did not answer zero')
end)

t.test('GetOwedKit answers the whole slate, or one character', function()
    local f = newExports()

    local all = f.call('GetOwedKit')
    t.equals(#all, 2, 'the slate came back the wrong length')

    local one = f.call('GetOwedKit', 'CID001')
    t.isNotNil(one, 'a character who IS on the slate came back as nothing')
    t.equals(one.citizenid, 'CID001')
    t.equals(one.weapons[1].serial, 'AA1', 'the weapon did not survive the copy')
end)

t.test('and a character nobody is owed anything for is nil, not an empty row', function()
    -- An empty row reads as "they owe nothing and the arena knows it", which
    -- is a different claim from "nobody by that name is on the slate".
    local f = newExports()
    t.isNil(f.call('GetOwedKit', 'CID999'))
end)

t.test('GetOwedMoney answers the total', function()
    local f = newExports()
    t.equals(f.call('GetOwedMoney'), 750)
end)

-- ======================================================================
-- NOTHING INTERNAL LEAKS
-- ======================================================================

t.test('THE HAZARD: a caller cannot reach into a live match through GetMatches', function()
    -- ArenaLobby.All() hands back the LIVE tables -- a fresh array, but the
    -- same tables the round is being fought in. An export that passed one
    -- through would let any resource on the server rename a match, empty its
    -- roster or zero its pot by writing to a field.
    local f = newExports()

    local rows = f.call('GetMatches')
    rows[1].id = 'hijacked'
    rows[1].state = 'finished'
    rows[1].label = 'gone'

    t.equals(f.live[1].id, 'm1', 'a caller renamed a live match through an export')
    t.equals(f.live[1].state, 'live', 'a caller changed a live match state')
    t.equals(f.live[1].label, 'Trailer Park', 'a caller relabelled a live match')
end)

t.test('and cannot reach the owed-kit slate through GetOwedKit either', function()
    local f = newExports()

    local rows = f.call('GetOwedKit')
    rows[1].citizenid = 'hijacked'
    rows[1].count = 9999
    rows[1].weapons[1].serial = 'FORGED'

    t.equals(f.slate[1].citizenid, 'CID001', 'a caller rewrote the slate through an export')
    t.equals(f.slate[1].count, 1, 'a caller rewrote a debt count')
    t.equals(f.slate[1].weapons[1].serial, 'AA1', 'a caller forged a weapon serial')
end)

t.test('and the nested tables handed back are copies too, not shared', function()
    -- The shallow half of the same bug: copying the row and passing its
    -- `weapons` list through by reference protects the row and nothing in it.
    local f = newExports()

    local first = f.call('GetOwedKit')
    local second = f.call('GetOwedKit')

    t.isTrue(first[1].weapons ~= second[1].weapons,
        'two calls share one weapons table, so one caller can change another\'s answer')
end)

-- ======================================================================
-- NOTHING THROWS INTO A CALLER
-- ======================================================================

t.test('THE GUARANTEE: every export answers on a build with no arena modules at all', function()
    -- Mid-restart, a module that failed to load, a stripped environment. A
    -- resource asking the arena a question must not die because of any of it.
    local f = newExports({ 'ArenaLobby', 'ArenaBetting', 'ArenaAmmo', 'ArenaHoursOpen',
                           'ArenaDispatch' })

    for _, name in ipairs({ 'IsArenaOpen', 'GetMatches', 'GetPot', 'GetOwedKit', 'GetOwedMoney',
                            'IsPlayerInArena', 'GetPlayerMatchId', 'GetArenaPlayers',
                            'ShouldSuppressAlert' }) do
        local ok = pcall(f.call, name)
        t.isTrue(ok, name .. ' threw into its caller when the arena was not there')
    end
end)

t.test('and the answers it gives then are the quiet ones', function()
    -- A caller that never checks should behave as though the arena has
    -- nothing going on, rather than as though it has something it cannot
    -- describe.
    local f = newExports({ 'ArenaLobby', 'ArenaBetting', 'ArenaAmmo', 'ArenaHoursOpen',
                           'ArenaDispatch' })

    t.isFalse(f.call('IsArenaOpen'), 'an arena that cannot answer reported itself OPEN')
    t.equals(#f.call('GetMatches'), 0)
    t.equals(f.call('GetPot', 'm1'), 0)
    t.equals(f.call('GetOwedMoney'), 0)
    t.equals(#f.call('GetOwedKit'), 0, 'the whole slate should be an empty list')
end)

t.test('THE TRAP: asked about ONE character on that build, the answer is nil', function()
    -- `citizenid ~= nil and nil or {}` can NEVER yield nil -- `true and nil`
    -- is nil and `nil or {}` is {} -- so the obvious way to write this
    -- answers "they owe nothing" on a build that cannot tell. Two defects in
    -- this repository have already been that exact trap.
    local f = newExports({ 'ArenaAmmo' })

    t.isNil(f.call('GetOwedKit', 'CID001'),
        'a build with no door claimed to know that CID001 owes nothing')
end)

t.test('and a module that THROWS is survived too, not just one that is missing', function()
    local f = newExports()
    f.env.ArenaLobby.All = function() error('boom') end
    f.env.ArenaBetting.Outstanding = function() error('boom') end

    local ok, rows = pcall(f.call, 'GetMatches')
    t.isTrue(ok, 'a throwing module took the caller down with it')
    t.equals(#rows, 0, 'and the answer was not the quiet one')

    t.equals(f.call('GetOwedMoney'), 0)
end)

os.exit(t.summary())
