--[[
    crimson_arena/tests/leaderboard_spec.lua

    THE ALL-TIME BOARD, AND THE SWITCH THAT SHIPS OFF.

    `Config.Database.enabled` ships `false`, which is the configuration
    almost every operator runs on day one -- so the in-memory path is the
    one that actually serves the panel, and it was the one nothing tested.
    A mutation campaign found four survivors in server/stats.lua alone:
    the sort order could be reversed, and every one of the three
    database-off guards could be inverted, without a single spec noticing.

    Those guards matter more than they look. Getting one backwards on a
    server with no database means calling oxmysql that is not running --
    which is not a wrong number on a panel, it is a stack trace on every
    match end.

      THE ORDER IS THE BOARD.        Wins, then kills, then earnings, then
                                     citizenid to break the last tie -- so
                                     two reads of identical data can never
                                     render the panel differently.

      OFF MEANS NO DATABASE IS       not "queries that quietly fail". EnsureSchema
      TOUCHED                        creates nothing, Flush writes nothing,
                                     and the board still answers.

      IT ALWAYS ANSWERS, EXACTLY     GetLeaderboard calls back once, in both
      ONCE, WITH AN ARRAY            modes, with a table -- never nil, and
                                     never by raising.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('leaderboard_spec')

--- The real server/stats.lua, with oxmysql modelled rather than stubbed:
--- every query is recorded, so "the database was not touched" is a fact
--- this file can check rather than an assumption.
local function newStats(mutate)
    local queries = {}
    local env = Sandbox.newEnv({
        CreateThread = function() end,
        Wait = function() end,
        SetTimeout = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'started' end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function()
                return setmetatable({}, {
                    __index = function()
                        return function(_self, sql, params, cb)
                            queries[#queries + 1] = { sql = sql, params = params }
                            if type(cb) == 'function' then cb({}) end
                        end
                    end,
                })
            end,
        }),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/stats.lua', env)

    return { env = env, S = env.ArenaStats, queries = queries }
end

--- Reads the board back as a list of names, in the order the panel gets it.
local function names(stats)
    local out
    stats.S.GetLeaderboard(function(rows)
        out = {}
        for _, row in ipairs(rows or {}) do out[#out + 1] = row.name end
    end)
    return out
end

--- Records one finished player.
local function record(stats, citizenid, name, wins, kills, earnings)
    stats.S.Record({
        citizenid = citizenid, name = name, won = wins > 0,
        kills = kills, deaths = 0, earnings = earnings,
    })
end

-- ======================================================================
-- THE ORDER IS THE BOARD
-- ======================================================================

t.test('DEFECT: the board is sorted by wins, best first', function()
    local s = newStats()
    record(s, 'A', 'Loser', 0, 0, 0)
    record(s, 'B', 'Winner', 1, 0, 0)

    local board = names(s)
    t.equals(board[1], 'Winner', 'the board put the player with no wins at the top')
    t.equals(board[2], 'Loser', 'the board is not in win order at all')
end)

t.test('and kills break a tie on wins', function()
    local s = newStats()
    record(s, 'A', 'Fewer', 1, 2, 0)
    record(s, 'B', 'More', 1, 9, 0)

    t.equals(names(s)[1], 'More', 'two players level on wins were not separated by kills')
end)

t.test('and earnings break a tie on kills', function()
    local s = newStats()
    record(s, 'A', 'Poorer', 1, 3, 100)
    record(s, 'B', 'Richer', 1, 3, 900)

    t.equals(names(s)[1], 'Richer', 'two players level on wins and kills were not separated by earnings')
end)

t.test('and citizenid breaks the last one, so the board is never unstable', function()
    -- Without it the order comes from `pairs`, and two reads of identical
    -- data can render the panel differently -- which reads as the board
    -- being wrong rather than as the board being arbitrary.
    local s = newStats()
    record(s, 'zzz', 'Last', 1, 1, 1)
    record(s, 'aaa', 'First', 1, 1, 1)

    local first = names(s)
    for _ = 1, 8 do
        local again = names(s)
        t.equals(table.concat(again, ','), table.concat(first, ','),
            'two reads of the same data came back in different orders')
    end
    t.equals(first[1], 'First', 'the last tie was not broken by citizenid')
end)

t.test('and the board is capped at leaderboardSize', function()
    local s = newStats(function(config) config.Database.leaderboardSize = 3 end)
    for index = 1, 8 do
        record(s, ('C%d'):format(index), ('P%d'):format(index), 1, index, 0)
    end
    t.equals(#names(s), 3, 'the board ignored leaderboardSize')
end)

-- ======================================================================
-- OFF MEANS NO DATABASE IS TOUCHED
-- ======================================================================

t.test('the database ships OFF, which is what makes the rest of this matter', function()
    t.isFalse(newStats().env.Config.Database.enabled,
        'the database now ships on -- the in-memory path is no longer the default')
end)

t.test('DEFECT: with it off, EnsureSchema creates nothing', function()
    -- An operator running without a database must never find a table they
    -- did not ask for -- and calling oxmysql when it is not running is a
    -- stack trace, not a wrong number.
    local s = newStats()
    t.isFalse(s.S.EnsureSchema(), 'EnsureSchema reported that it ran with the database off')
    t.equals(#s.queries, 0, 'a schema query went out with the database off')
end)

t.test('DEFECT: and Flush writes nothing', function()
    local s = newStats()
    record(s, 'A', 'Somebody', 1, 5, 100)
    t.equals(s.S.Flush(), 0, 'Flush reported rows written with the database off')
    t.equals(#s.queries, 0, 'an upsert went out with the database off')
end)

t.test('and the board still answers, from memory', function()
    -- The whole point: off is a working configuration, not a broken one.
    local s = newStats()
    record(s, 'A', 'Somebody', 1, 5, 100)

    local board = names(s)
    t.isNotNil(board, 'the board never called back with the database off')
    t.equals(board[1], 'Somebody', 'the in-memory board lost the only player on it')
    t.equals(#s.queries, 0, 'reading the board queried a database that is switched off')
end)

t.test('and with it ON, the schema and the flush really go out', function()
    -- The other direction. A guard that is never satisfied is the same
    -- defect wearing the opposite sign.
    local s = newStats(function(config) config.Database.enabled = true end)
    t.isTrue(s.S.EnsureSchema(), 'EnsureSchema declined with the database on')
    t.isTrue(#s.queries > 0, 'no schema query went out with the database on')

    record(s, 'A', 'Somebody', 1, 5, 100)
    t.equals(s.S.Flush(), 1, 'Flush wrote nothing with the database on')
end)

-- ======================================================================
-- IT ALWAYS ANSWERS, EXACTLY ONCE
-- ======================================================================

t.test('GetLeaderboard calls back exactly once, in both modes', function()
    for _, on in ipairs({ false, true }) do
        local s = newStats(function(config) config.Database.enabled = on end)
        local calls = 0
        s.S.GetLeaderboard(function(rows)
            calls = calls + 1
            t.isTrue(type(rows) == 'table',
                ('the board came back as %s rather than a table'):format(type(rows)))
        end)
        t.equals(calls, 1, ('the board called back %d time(s) with the database %s')
            :format(calls, tostring(on)))
    end
end)

t.test('and an empty board is an empty array, never nil', function()
    local s = newStats()
    local rows
    s.S.GetLeaderboard(function(result) rows = result end)
    t.isNotNil(rows, 'an empty board came back as nil')
    t.equals(#rows, 0, 'an empty board came back with rows in it')
end)

t.test('and a caller that is not a function is refused rather than called', function()
    local s = newStats()
    s.S.GetLeaderboard(nil)
    s.S.GetLeaderboard('not a function')
    t.equals(#s.queries, 0, 'a junk callback still went to the database')
end)

os.exit(t.summary())
