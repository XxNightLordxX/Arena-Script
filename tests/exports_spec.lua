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
        'GetMatches GetOwedKit GetOwedMoney GetPot IsArenaOpen',
        'the public surface changed -- every caller of a removed or renamed '
        .. 'export breaks at run time, on their server, and this is the only '
        .. 'place that says so')
end)

-- ======================================================================
-- WHAT THEY ANSWER
-- ======================================================================

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
    local f = newExports({ 'ArenaLobby', 'ArenaBetting', 'ArenaAmmo', 'ArenaHoursOpen' })

    for _, name in ipairs({ 'IsArenaOpen', 'GetMatches', 'GetPot', 'GetOwedKit', 'GetOwedMoney' }) do
        local ok = pcall(f.call, name)
        t.isTrue(ok, name .. ' threw into its caller when the arena was not there')
    end
end)

t.test('and the answers it gives then are the quiet ones', function()
    -- A caller that never checks should behave as though the arena has
    -- nothing going on, rather than as though it has something it cannot
    -- describe.
    local f = newExports({ 'ArenaLobby', 'ArenaBetting', 'ArenaAmmo', 'ArenaHoursOpen' })

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
