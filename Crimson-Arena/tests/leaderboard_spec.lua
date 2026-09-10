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
---
--- `control` is read on every call rather than at build time, so a test can
--- take the database away between two flushes on the same instance -- which
--- is the whole shape of the retry: fail, then come back.
---   control.oxmysql -- what GetResourceState answers ('started' by default)
---   control.throw   -- the export raises, the way an unreachable server does
---   control.fail    -- the query goes out and comes back nil
---   control.defer   -- the callback is HELD rather than called, so a test can
---                      run code in the window a real oxmysql leaves open
---                      between dispatch and answer, then settle it by hand
local function newStats(mutate, control)
    control = control or {}
    local queries = {}
    local held = {}
    local env = Sandbox.newEnv({
        CreateThread = function() end,
        Wait = function() end,
        SetTimeout = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return control.oxmysql or 'started' end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function()
                return setmetatable({}, {
                    __index = function()
                        return function(_self, sql, params, cb)
                            -- Raised BEFORE the query is recorded: a throw out
                            -- of the export means nothing reached the database.
                            if control.throw then error('database unreachable', 0) end
                            queries[#queries + 1] = { sql = sql, params = params }
                            if type(cb) ~= 'function' then return end
                            if control.defer then
                                held[#held + 1] = cb
                                return
                            end
                            -- Spelled out rather than `control.fail and nil or {}`,
                            -- which is `{}` in both directions: nil cannot be
                            -- carried through and/or.
                            if control.fail then cb(nil) else cb({}) end
                        end
                    end,
                })
            end,
        }),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    -- THE ONE DATABASE GATE, and it lives here now. ArenaDb/ArenaDbReady used
    -- to be stats.lua's own; they were consolidated into server/util.lua,
    -- which fxmanifest.lua loads FIRST of the server scripts. Loading it in
    -- that same order is what makes stats.lua's queries reach the fixture's
    -- exports double instead of dying on a nil global.
    Sandbox.loadInto('../server/util.lua', env)
    -- Re-silenced after the load, because util.lua defines the real ones over
    -- the no-ops above and this file is not about what the console says.
    env.ArenaLog = function() end
    env.ArenaDebug = function() end
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/stats.lua', env)

    --- Answers every held callback with `result`, the way oxmysql eventually
    --- would. nil is a failed write.
    local function settle(result)
        local batch = held
        held = {}
        for _, cb in ipairs(batch) do cb(result) end
        return #batch
    end

    return { env = env, S = env.ArenaStats, queries = queries, settle = settle }
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
-- A WRITE THAT FAILED IS NOT A WRITE
-- ======================================================================
--
-- Flush swaps the queue out before the first query goes out, which is what
-- makes a Record landing mid-flush safe -- and is also what makes a failed
-- write unrecoverable, because the delta is out of the queue before anybody
-- knows whether it landed. It used to count every row in the batch as
-- written, log a successful flush, and return that count, whether or not a
-- single byte reached the database.
--
-- The observable throughout is the NEXT flush: a row that was kept comes
-- back out as an upsert, carrying its full totals.

--- The upserts sent so far, as { citizenid, wins, kills, earnings }.
local function upserts(stats, from)
    local out = {}
    for index = (from or 0) + 1, #stats.queries do
        local params = stats.queries[index].params
        out[#out + 1] = {
            citizenid = params[1], wins = params[3], kills = params[5], earnings = params[7],
        }
    end
    return out
end

t.test('DEFECT: a flush with oxmysql gone keeps the rows instead of eating them', function()
    local control = { oxmysql = 'missing' }
    local s = newStats(function(config) config.Database.enabled = true end, control)
    record(s, 'A', 'Somebody', 1, 5, 100)

    t.equals(s.S.Flush(), 0, 'Flush reported a row written with oxmysql not started')
    t.equals(#s.queries, 0, 'a query went out to a database that is not running')

    -- oxmysql comes up. Nothing else happens -- no new match, no new record.
    control.oxmysql = 'started'
    t.equals(s.S.Flush(), 1, 'the row was dropped by the flush that could not send it')

    local sent = upserts(s)
    t.equals(#sent, 1, 'the recovered flush sent the wrong number of rows')
    t.equals(sent[1].citizenid, 'A', 'the wrong player came back')
    t.equals(sent[1].kills, 5, 'the kills did not survive the failed flush')
    t.equals(sent[1].earnings, 100, 'the earnings did not survive the failed flush')
end)

t.test('and a query that goes out and comes back nil is kept too', function()
    -- The other half. dbQuery dispatched, so the row is NOT a sync failure --
    -- only the callback knows it failed.
    local control = { fail = true }
    local s = newStats(function(config) config.Database.enabled = true end, control)
    record(s, 'A', 'Somebody', 1, 5, 100)

    t.equals(s.S.Flush(), 1, 'the row was never dispatched at all')
    local afterFirst = #s.queries

    control.fail = false
    t.equals(s.S.Flush(), 1, 'a query that came back nil was treated as written')

    local sent = upserts(s, afterFirst)
    t.equals(#sent, 1, 'the failed row was not retried')
    t.equals(sent[1].kills, 5, 'the retry sent different numbers than the failure did')
end)

t.test('and an export that raises is kept as well', function()
    local control = { throw = true }
    local s = newStats(function(config) config.Database.enabled = true end, control)
    record(s, 'A', 'Somebody', 1, 5, 100)

    t.equals(s.S.Flush(), 0, 'Flush counted a row the export refused to send')
    t.equals(#s.queries, 0, 'a query was recorded despite the export raising')

    control.throw = false
    t.equals(s.S.Flush(), 1, 'the row was lost when the export raised')
    t.equals(upserts(s)[1].earnings, 100, 'the earnings were lost when the export raised')
end)

t.test('and a match played during the outage ADDS to what is waiting', function()
    -- The requeue goes through the same accumulate as a fresh record, so the
    -- kept row and the new one are one upsert with the totals summed --
    -- not two rows, and not the newer one overwriting the older.
    local control = { oxmysql = 'missing' }
    local s = newStats(function(config) config.Database.enabled = true end, control)

    record(s, 'A', 'Somebody', 1, 5, 100)
    s.S.Flush()
    record(s, 'A', 'Somebody', 1, 3, 50)

    control.oxmysql = 'started'
    s.S.Flush()

    local sent = upserts(s)
    t.equals(#sent, 1, ('the same player was written as %d separate rows'):format(#sent))
    t.equals(sent[1].wins, 2, 'a win was lost across the outage')
    t.equals(sent[1].kills, 8, 'the kills were not summed across the outage')
    t.equals(sent[1].earnings, 150, 'the earnings were not summed across the outage')
end)

t.test('and a name recorded DURING the flush survives the kept row', function()
    -- accumulate takes the delta's name as the newest, which is backwards for
    -- a requeue: the kept row is older than anything recorded since the flush
    -- began. That window is real -- oxmysql answers asynchronously, and the
    -- queue was swapped out before the query went -- so a rename landing in
    -- it would otherwise be undone by the failure of the older write.
    local control = { defer = true }
    local s = newStats(function(config) config.Database.enabled = true end, control)

    record(s, 'A', 'Old Name', 1, 0, 0)
    s.S.Flush()

    -- Mid-flight: dispatched, not yet answered. This lands in the NEW queue.
    record(s, 'A', 'New Name', 1, 0, 0)
    t.equals(s.settle(nil), 1, 'the flush did not leave a write outstanding to settle')

    control.defer = false
    t.equals(s.S.Flush(), 1, 'the kept row and the fresh one were not written as one')

    local sent = upserts(s, 1)
    t.equals(sent[1].wins, 2, 'a win was lost in the window between dispatch and answer')
    t.equals(s.queries[2].params[2], 'New Name',
        'the requeued row put the stale name back over the one recorded since')
end)

t.test('and the queue does not grow without a bound while the database is down', function()
    -- A backstop, not a normal limit. With the setting on and no database
    -- ever reachable, an unbounded queue holds one entry per player who has
    -- ever fought, for the life of the server.
    local control = { oxmysql = 'missing' }
    local s = newStats(function(config) config.Database.enabled = true end, control)

    for index = 1, 5200 do record(s, ('P%d'):format(index), 'Player', 1, 1, 1) end
    s.S.Flush()

    control.oxmysql = 'started'
    local kept = s.S.Flush()
    t.isTrue(kept > 0, 'the bound threw the whole queue away rather than capping it')
    t.isTrue(kept <= 5000, ('%d rows were retained past the bound'):format(kept))
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
