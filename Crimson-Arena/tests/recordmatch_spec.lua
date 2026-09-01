--[[
    crimson_arena/tests/recordmatch_spec.lua

    HOW A FINISHED MATCH BECOMES A LEADERBOARD ROW.

    ArenaStats.RecordMatch is the one call server/match.lua makes at the end
    of every round. It reads the match the way the match layer leaves it --
    a `winners` array, a `payouts` array -- and turns it into one Record()
    per player: who won, who lost, what they earned.

    IT HAD NEVER BEEN RUN. Eleven spec files name RecordMatch and every one
    of them stubs it to an empty function, because they are testing the
    match layer and want the stats layer out of the way. leaderboard_spec
    exercises Record() and the sort, which are the two things RecordMatch
    sits BETWEEN. A mutation sample of server/stats.lua found the whole
    block untested: winners never marked, payouts never accumulated,
    refunds never filtered, and the derived outcome never checked -- twelve
    surviving mutants in thirty lines, most of them money.

    THE REFUND FILTER IS THE POINT OF THIS FILE. A refund is a player's own
    stake handed back. Recorded as earnings it inflates an all-time
    leaderboard with money nobody won -- and it is precisely the shape of
    defect this resource keeps producing: a value that is correct where it
    is computed and wrong by the time it is stored.

    What this file holds:

      WINNERS AND LOSERS             the ids in `winners` are recorded as
                                     wins and everybody else in the match as
                                     a loss. There is no third outcome.

      PAYOUTS BECOME EARNINGS        accumulated per player when one player
                                     is paid more than once, and read off
                                     the payout's own id rather than the
                                     table position.

      REFUNDS DO NOT                 a payout whose reason starts 'refund'
                                     is a stake coming home, not a win.

      A MODE MAY OVERRIDE BOTH       `won` or `earnings` already written on
                                     the player record beat the derived
                                     value, so a mode that settles those
                                     itself does not have to fake a winners
                                     list to be recorded correctly.

      RUBBISH IS REFUSED, NOT        the match record is built by this
      GUESSED AT                     resource, but it arrives here after a
                                     round that may have gone wrong.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- The real server/stats.lua with the database OFF, so the session table is
--- the only store and the leaderboard read needs no query round trip.
--- @param mutate fun(config: table)?
--- @return table fixture
--- WITH THE DATABASE ON, and that is not an incidental choice.
---
--- GetLeaderboard hands the panel five fields and LOSSES IS NOT ONE OF
--- THEM -- the board shows wins, kills, deaths and earnings. So a spec
--- that only read the board could not tell a player recorded as a loss
--- from one not recorded at all, which is half of what RecordMatch
--- decides. The flush queue carries all seven columns, so this fixture
--- records every query oxmysql is handed and reads the row back out of
--- its own parameters.
--- @param mutate fun(config: table)? -- runs against Config before load
--- @param overrides table<string, any>? -- extra env stubs, layered last
--- @return table fixture
local function newStats(mutate, overrides)
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
                            -- NIL, not an empty table. There is no real
                            -- database behind this fixture, so a SELECT
                            -- has nothing to answer with -- and nil is
                            -- what makes GetLeaderboard take its
                            -- documented fallback to the session rows.
                            -- An empty TABLE is a valid result meaning
                            -- "the board is empty", which would hide every
                            -- assertion in this file behind a board that
                            -- is legitimately blank.
                            if type(cb) == 'function' then cb(nil) end
                        end
                    end,
                })
            end,
        }),
    })

    for key, value in pairs(overrides or {}) do env[key] = value end

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    env.Config.Database.enabled = true
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/stats.lua', env)

    local fixture = { env = env, S = env.ArenaStats, queries = queries }

    --- The whole board, keyed by name, as the panel would receive it.
    --- Wins, kills, deaths and earnings only -- see the note above.
    --- @return table<string, table>
    function fixture.board()
        local out = {}
        fixture.S.GetLeaderboard(function(rows)
            for _, row in ipairs(rows or {}) do out[row.name] = row end
        end)
        return out
    end

    --- Every queued row as the database would receive it, keyed by
    --- citizenid. Positional, because that is how the query is written --
    --- reading them by name here would hide a swapped pair of columns.
    --- @return table<string, table>
    function fixture.flushed()
        local before = #queries
        fixture.S.Flush()
        local out = {}
        for index = before + 1, #queries do
            local p = queries[index].params
            out[p[1]] = {
                citizenid = p[1], name = p[2], wins = p[3], losses = p[4],
                kills = p[5], deaths = p[6], earnings = p[7],
            }
        end
        return out
    end

    return fixture
end

--- A finished match record shaped the way server/match.lua leaves one.
--- Players are keyed by server id, which is what RecordMatch iterates.
local function match(players, winners, payouts)
    return { players = players, winners = winners, payouts = payouts }
end

--- One player record inside that match.
local function player(src, citizenid, name, extra)
    local p = { src = src, citizenid = citizenid, name = name, kills = 0, deaths = 0 }
    for key, value in pairs(extra or {}) do p[key] = value end
    return p
end

-- ========================================================================
-- WINNERS AND LOSERS
-- ========================================================================

t.test('the ids in `winners` are recorded as wins and everyone else as losses', function()
    local s = newStats()

    local recorded = s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben') },
        { 1 },
        {}
    ))

    t.equals(recorded, 2, 'not every player of the match was folded in')
    local board = s.board()
    t.equals(board['Ada'].wins, 1, 'the winner was not recorded as having won')
    t.equals(board['Ben'].wins, 0, 'a player who lost was recorded as a winner')

    -- There is no third outcome in this table: in a match and did not win
    -- means lost, and a board where nobody ever loses is a board of
    -- meaningless win counts. Read off the flush queue because the board
    -- the panel gets does not carry losses at all.
    local written = s.flushed()
    t.equals(written['char:B'].losses, 1, 'a player who lost was not recorded as having lost')
    t.equals(written['char:A'].losses, 0, 'the winner was ALSO recorded as having lost')
    t.equals(written['char:A'].wins, 1)
end)

t.test('more than one winner is possible -- a team match has several', function()
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben'), [3] = player(3, 'char:C', 'Cal') },
        { 1, 2 },
        {}
    ))

    local board = s.board()
    t.equals(board['Ada'].wins, 1)
    t.equals(board['Ben'].wins, 1, 'only the first winner in the list was credited')
    t.equals(board['Cal'].wins, 0)
end)

t.test('a match with no winners at all records everybody as a loss', function()
    -- A round that ended with nobody standing -- everyone left, the match
    -- was stopped -- still happened, and the deaths in it are real.
    local s = newStats()

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada') }, {}, {}))

    t.equals(s.board()['Ada'].wins, 0)
    t.equals(s.flushed()['char:A'].losses, 1, 'a match nobody won recorded no loss either')
end)

-- ========================================================================
-- PAYOUTS BECOME EARNINGS
-- ========================================================================

t.test('a payout is recorded as earnings against the player it names', function()
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben') },
        { 1 },
        { { id = 1, amount = 500, reason = 'payout' } }
    ))

    local board = s.board()
    t.equals(board['Ada'].earnings, 500, 'the winner was credited nothing')
    t.equals(board['Ben'].earnings, 0, 'a player who was paid nothing was credited anyway')
end)

t.test('and two payouts to the same player ADD UP rather than replacing', function()
    -- A winner who also had a side bet on themselves is paid twice, from
    -- two different pools. Both are earnings.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        { 1 },
        {
            { id = 1, amount = 500, reason = 'payout' },
            { id = 1, amount = 250, reason = 'sidebet_payout' },
        }
    ))

    t.equals(s.board()['Ada'].earnings, 750, 'the second payout replaced the first instead of adding to it')
end)

t.test('the payout is read off its OWN id, not its position in the list', function()
    -- The payouts array is not parallel to the players table and never has
    -- been. Reading by index would credit the wrong player -- silently, and
    -- only when the two happen to be ordered differently.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben') },
        { 2 },
        { { id = 2, amount = 900, reason = 'payout' } }
    ))

    local board = s.board()
    t.equals(board['Ben'].earnings, 900, 'the payout reached the wrong player')
    t.equals(board['Ada'].earnings, 0, 'a player who was paid nothing was credited')
end)

-- ========================================================================
-- REFUNDS DO NOT
-- ========================================================================

t.test('a REFUND is not earnings -- it is the player\'s own stake coming home', function()
    -- THE ASSERTION THIS FILE EXISTS FOR. Count a refund as earnings and
    -- an all-time leaderboard fills up with money nobody won: every
    -- cancelled match, every uncontested pool, every void quietly inflates
    -- the board.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        {},
        { { id = 1, amount = 500, reason = 'refund' } }
    ))

    t.equals(s.board()['Ada'].earnings, 0, 'a refunded stake was recorded as money won')
end)

t.test('and so is every reason that STARTS with refund', function()
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        {},
        {
            { id = 1, amount = 100, reason = 'refund_entry' },
            { id = 1, amount = 200, reason = 'refund_sidebet' },
            { id = 1, amount = 400, reason = 'payout' },
        }
    ))

    t.equals(s.board()['Ada'].earnings, 400, 'a refund variant was counted as earnings')
end)

t.test('but a reason that merely CONTAINS refund is still earnings', function()
    -- Anchored on purpose. A prize named for a refund is not one, and a
    -- substring match would silently swallow it.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        { 1 },
        { { id = 1, amount = 300, reason = 'no_refund_bonus' } }
    ))

    t.equals(s.board()['Ada'].earnings, 300, 'a payout was dropped because its name contained "refund"')
end)

t.test('a payout with no reason at all is earnings, not silently dropped', function()
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        { 1 },
        { { id = 1, amount = 300 } }
    ))

    t.equals(s.board()['Ada'].earnings, 300, 'a payout with no reason was thrown away')
end)

t.test('and a payout naming nobody is skipped rather than crashing the record', function()
    local s = newStats()

    local recorded = s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada') },
        { 1 },
        { { amount = 300, reason = 'payout' }, { id = 1, amount = 50, reason = 'payout' } }
    ))

    t.equals(recorded, 1, 'a payout with no id took the whole record down')
    t.equals(s.board()['Ada'].earnings, 50)
end)

-- ========================================================================
-- A MODE MAY OVERRIDE BOTH
-- ========================================================================

t.test('a `won` already on the player record beats the winners list', function()
    -- Gun game settles its own outcome. It must not have to fake a winners
    -- array to be recorded correctly.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada', { won = true }), [2] = player(2, 'char:B', 'Ben', { won = false }) },
        { 2 },
        {}
    ))

    local board = s.board()
    t.equals(board['Ada'].wins, 1, 'a mode\'s own outcome was overruled by the winners list')
    t.equals(board['Ben'].wins, 0, 'the winners list overruled an explicit `won = false`')
end)

t.test('and an `earnings` already on the record beats the payouts', function()
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada', { earnings = 1000 }) },
        { 1 },
        { { id = 1, amount = 25, reason = 'payout' } }
    ))

    t.equals(s.board()['Ada'].earnings, 1000, 'a mode\'s own earnings figure was overruled by the payouts')
end)

t.test('an explicit zero is an override too, not an absent value', function()
    -- `won = false` and `earnings = 0` are decisions. Treating either as
    -- "not set" would hand the player back to the derived path and undo
    -- exactly what the mode decided.
    local s = newStats()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada', { earnings = 0 }) },
        { 1 },
        { { id = 1, amount = 750, reason = 'payout' } }
    ))

    t.equals(s.board()['Ada'].earnings, 0, 'an explicit zero was treated as "no value" and overwritten')
end)

-- ========================================================================
-- THE KEY THE PLAYER IS FOUND BY
-- ========================================================================

t.test('the player\'s own src wins over the table key it is stored under', function()
    -- The players table is keyed by server id, but the record carries one
    -- too, and the record is the authority: a player table rebuilt during
    -- the match can be keyed by something else entirely.
    local s = newStats()

    s.S.RecordMatch({
        players = { ['slot-1'] = player(4, 'char:A', 'Ada') },
        winners = { 4 },
        payouts = { { id = 4, amount = 200, reason = 'payout' } },
    })

    local board = s.board()
    t.equals(board['Ada'].wins, 1, 'the winner was looked up by the table key rather than their src')
    t.equals(board['Ada'].earnings, 200, 'the payout was looked up by the table key rather than their src')
end)

t.test('and the table key is used when the record carries no src', function()
    local s = newStats()

    s.S.RecordMatch({
        players = { [9] = { citizenid = 'char:A', name = 'Ada', kills = 0, deaths = 0 } },
        winners = { 9 },
        payouts = { { id = 9, amount = 200, reason = 'payout' } },
    })

    local board = s.board()
    t.equals(board['Ada'].wins, 1, 'a player with no src on their record was never matched to the winners list')
    t.equals(board['Ada'].earnings, 200)
end)

-- ========================================================================
-- KILLS AND DEATHS RIDE ALONG
-- ========================================================================

t.test('kills and deaths are carried through from the player record', function()
    local s = newStats()

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 3, deaths = 2 }) }, { 1 }, {}))

    local board = s.board()
    t.equals(board['Ada'].kills, 3)
    t.equals(board['Ada'].deaths, 2)
end)

t.test('and two matches accumulate rather than overwriting', function()
    local s = newStats()

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 3, deaths = 2 }) }, { 1 },
        { { id = 1, amount = 100, reason = 'payout' } }))
    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 1, deaths = 4 }) }, {},
        { { id = 1, amount = 50, reason = 'payout' } }))

    local board = s.board()
    t.equals(board['Ada'].wins, 1, 'the second match reset the win count')
    t.equals(board['Ada'].kills, 4, 'kills did not accumulate across matches')
    t.equals(board['Ada'].deaths, 6, 'deaths did not accumulate across matches')
    t.equals(board['Ada'].earnings, 150, 'earnings did not accumulate across matches')
    t.equals(s.flushed()['char:A'].losses, 1, 'the lost match was not recorded as a loss')
end)

-- ========================================================================
-- RUBBISH IS REFUSED, NOT GUESSED AT
-- ========================================================================

t.test('a match that is not a table records nothing and says so', function()
    local s = newStats()
    for _, bad in ipairs({ 'match', 42, true, {} }) do
        t.equals(s.S.RecordMatch(bad), 0, ('%s was accepted as a finished match'):format(tostring(bad)))
    end
    t.equals(s.S.RecordMatch(nil), 0)
end)

t.test('a player with no citizenid is skipped, and the rest are still recorded', function()
    -- A player who dropped before the framework answered has no character
    -- to credit. That is one lost row, not a lost match.
    local s = newStats()

    local recorded = s.S.RecordMatch(match(
        { [1] = player(1, nil, 'Ghost'), [2] = player(2, 'char:B', 'Ben') },
        { 2 },
        {}
    ))

    t.equals(recorded, 1, 'the count includes a player who could not be recorded')
    local board = s.board()
    t.isNil(board['Ghost'], 'a player with no citizenid reached the board')
    t.equals(board['Ben'].wins, 1, 'one unrecordable player cost the rest of the match its stats')
end)

t.test('a missing winners or payouts array is empty, not a crash', function()
    local s = newStats()

    local recorded = s.S.RecordMatch({ players = { [1] = player(1, 'char:A', 'Ada') } })

    t.equals(recorded, 1, 'a match with no winners or payouts arrays was not recorded')
    t.equals(s.board()['Ada'].earnings, 0)
    t.equals(s.flushed()['char:A'].losses, 1)
end)

t.test('a match with no players records nothing', function()
    local s = newStats()
    t.equals(s.S.RecordMatch({ players = {}, winners = { 1 }, payouts = {} }), 0)
end)


-- ========================================================================
-- WHAT REACHES THE DATABASE
--
-- The row above is written through one upsert, and the whole all-time
-- board depends on that statement ADDING to what is already stored. An
-- upsert that assigns instead of adds turns every column into "the last
-- match only" -- a leaderboard that looks plausible, is wrong from the
-- second match onward, and reads as data loss nobody can date.
-- ========================================================================

t.test('the upsert ADDS to the stored totals rather than replacing them', function()
    local s = newStats()
    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 1, deaths = 1 }) }, { 1 },
        { { id = 1, amount = 10, reason = 'payout' } }))
    s.S.Flush()

    local sql = s.queries[#s.queries].sql
    for _, column in ipairs({ 'wins', 'losses', 'kills', 'deaths', 'earnings' }) do
        t.contains(sql, ('%s = %s + VALUES(%s)'):format(column, column, column),
            ('the upsert does not accumulate %s -- every match would overwrite the last'):format(column))
    end
    -- The name is the one column that must NOT accumulate: characters get
    -- renamed and the most recent name is the useful one.
    t.contains(sql, 'name = VALUES(name)')
    t.notContains(sql, 'name = name + VALUES(name)')
end)

t.test('and the parameters go out in the order the statement names them', function()
    -- Positional, so a swapped pair is invisible until somebody reads the
    -- board and finds their losses in the kills column.
    local s = newStats()
    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 5, deaths = 6 }) }, {},
        { { id = 1, amount = 70, reason = 'payout' } }))

    local row = s.flushed()['char:A']
    t.equals(row.citizenid, 'char:A')
    t.equals(row.name, 'Ada')
    t.equals(row.wins, 0)
    t.equals(row.losses, 1)
    t.equals(row.kills, 5)
    t.equals(row.deaths, 6)
    t.equals(row.earnings, 70)
end)

t.test('a flush writes one row per player, not one per match', function()
    local s = newStats()
    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben') }, { 1 }, {}))
    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada') }, { 1 }, {}))

    local before = #s.queries
    local written = s.S.Flush()

    t.equals(written, 2, 'the queue did not collapse a player\'s two matches into one row')
    t.equals(#s.queries - before, 2, 'more queries went out than rows were reported')
end)

t.test('and the queue is emptied, so a second flush writes nothing', function()
    -- The queue is swapped out before the first query goes out. A queue
    -- that survived its own flush would write every match again on the
    -- next timer tick, doubling the whole board every minute.
    local s = newStats()
    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada') }, { 1 }, {}))
    s.S.Flush()

    local before = #s.queries
    t.equals(s.S.Flush(), 0, 'the flush queue survived being flushed')
    t.equals(#s.queries, before, 'a second flush sent queries for rows already written')
end)

t.test('with the database OFF nothing is queued and the board still works', function()
    local s = newStats(function(config) config.Database.enabled = false end)

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada') }, { 1 },
        { { id = 1, amount = 400, reason = 'payout' } }))

    t.equals(s.S.Flush(), 0, 'rows were queued for a database that is switched off')
    t.equals(#s.queries, 0, 'a query went out with the database switched off')
    t.equals(s.board()['Ada'].earnings, 400, 'the session board stopped working without a database')
end)


-- ========================================================================
-- THE DATABASE IS ON AND OXMYSQL IS NOT THERE
--
-- The commonest deployment mistake there is: an operator switches
-- Config.Database.enabled on and never installs oxmysql. The resource has
-- to keep working -- the session board is still real -- and it has to say
-- what is wrong ONCE. A flush sends one query per player, so an unguarded
-- warning here prints the same sentence eight times a minute and buries
-- everything else in the console.
--
-- NOT COVERED, DELIBERATELY: dbQuery documents a `@return boolean
-- dispatched` and none of its four callers reads it. Mutating those two
-- returns changes nothing observable, so there is no honest assertion to
-- write -- the value is documentation, not behaviour.
-- ========================================================================

--- The same fixture with oxmysql absent and the console captured.
--- @return table fixture
local function newStatsNoDatabase()
    local logs = {}
    local fixture = newStats(nil, {
        GetResourceState = function() return 'missing' end,
        ArenaLog = function(fmt, ...)
            logs[#logs + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
        end,
    })
    fixture.logs = logs
    return fixture
end

t.test('the missing-database warning is printed exactly ONCE, not once per query', function()
    local s = newStatsNoDatabase()

    s.S.RecordMatch(match(
        { [1] = player(1, 'char:A', 'Ada'), [2] = player(2, 'char:B', 'Ben'), [3] = player(3, 'char:C', 'Cal') },
        { 1 }, {}))
    s.S.Flush()      -- three players, so three queries
    s.S.Flush()
    s.S.GetLeaderboard(function() end)

    local warnings = 0
    for _, line in ipairs(s.logs) do
        if line:find('oxmysql is not started', 1, true) then warnings = warnings + 1 end
    end
    t.equals(warnings, 1, 'the missing-database warning is being printed per query rather than once')
end)

t.test('and it names both ways out, because either one fixes it', function()
    local s = newStatsNoDatabase()
    s.S.GetLeaderboard(function() end)

    local said = table.concat(s.logs, '\n')
    t.contains(said, 'oxmysql', 'the warning does not name what is missing')
    t.contains(said, 'Config.Database.enabled', 'the warning does not name the setting that turns it off')
end)

t.test('the board still works without a database -- it is just this run only', function()
    -- The session totals are kept in BOTH modes. An operator who
    -- misconfigured the database gets a working leaderboard for the
    -- current run, not a broken panel.
    local s = newStatsNoDatabase()

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada', { kills = 2 }) }, { 1 },
        { { id = 1, amount = 300, reason = 'payout' } }))

    local board = s.board()
    t.isNotNil(board['Ada'], 'the leaderboard went blank because the database was missing')
    t.equals(board['Ada'].wins, 1)
    t.equals(board['Ada'].kills, 2)
    t.equals(board['Ada'].earnings, 300)
end)

t.test('and a working database prints no warning at all', function()
    -- The control. Without it the assertion above passes just as happily
    -- against a resource that warns on every start.
    local logs = {}
    local s = newStats(nil, {
        ArenaLog = function(fmt, ...)
            logs[#logs + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
        end,
    })

    s.S.RecordMatch(match({ [1] = player(1, 'char:A', 'Ada') }, { 1 }, {}))
    s.S.Flush()
    s.S.GetLeaderboard(function() end)

    for _, line in ipairs(logs) do
        t.notContains(line, 'oxmysql is not started')
    end
end)

os.exit(t.summary())
