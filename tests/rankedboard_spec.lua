--[[
    crimson_arena/tests/rankedboard_spec.lua

    WHICH MATCHES MOVE THE LEADERBOARD, AND WHICH ONES DO NOT.

    THE PROBLEM THIS ANSWERS. The board ranks on wins, then kills, then
    earnings, and it counted every match equally. So the shortest route to the
    top of a server was two accounts, a lobby nobody else could see, and a
    round decided in four seconds, repeated for an evening. Nothing in the
    resource could tell that apart from a contest, and the people who fought
    real ones were below it.

    WHAT WAS ADDED. Config.Leaderboard, read in exactly one place --
    ArenaStats.RecordMatch -- and three rules under it:

      minFighters          a match that only ever had one character in it is
                           a walkover.

      minSeconds           a round that ended before anybody could have
                           fought it is not a result.

      the repeat rule      and beating the SAME SET of people over and over
                           stops counting, inside a window, on rosters small
                           enough for one person to stage.

    WHAT IT DELIBERATELY IS NOT.

      NOT A LIMIT ON MATCHES. Every round still runs, still pays out, still
      hands the kit back, still shows every number on the results screen. An
      unranked match writes NOTHING to the board -- no win, no loss, no
      kills, no earnings -- and that is the whole of its effect.

      NOT A HEADCOUNT RULE. minFighters ships at TWO, not three. A 1v1
      between two real people is the oldest real contest there is, and a
      board that refused to count it would be limiting matches by the back
      door. The repeat rule is what actually catches a farm, because a farm
      is not "few players", it is the same few players forever.

      NOT WATCHING THE REGULARS. `repeatAppliesUpTo` keeps the repeat rule
      off rosters too big to stage. Eight people who play each other every
      evening are one set, and without that guard the rule would have stopped
      counting their fourth round of the night.

    THE TWO HALVES HAVE TO AGREE. `rankedReason` decides and `noteRanked`
    writes the result down for next time, and they read the same predicate --
    a match written down that the rule never looks at fills somebody's window
    for nothing, and a match the rule DOES look at that was never written
    down is a free win every single round. Both directions are covered below.

    Every assertion here was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('rankedboard_spec')

--- The real server/stats.lua, with the database on so the flush queue can be
--- read for losses -- GetLeaderboard does not carry them.
---
--- A FRESH ENV PER CALL, WHICH MATTERS MORE HERE THAN ANYWHERE. The repeat
--- rule's history is a local inside stats.lua, so one fixture is one server's
--- memory. Tests that want a clean window take a new fixture; the ones about
--- the window take one fixture and record into it repeatedly.
---
--- THE CLOCK IS MOVABLE, because the repeat rule is the only thing in this
--- resource that measures a span of REAL minutes. `os.time` is proxied rather
--- than replaced -- config.lua and util.lua want `os.date` off the same table
--- -- and `fixture.advance(seconds)` is the only way anything here can make an
--- hour pass. Winding the stored rows back instead would be testing the test.
--- @param mutate fun(config: table)?
--- @return table fixture
local function newStats(mutate)
    local queries = {}
    local offset = 0
    local clock = setmetatable({
        time = function(...) return os.time(...) + offset end,
    }, { __index = os })

    local env = Sandbox.newEnv({
        os = clock,
        CreateThread = function() end,
        Wait = function() end,
        SetTimeout = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'started' end,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function()
                return setmetatable({}, {
                    __index = function()
                        return function(_self, sql, params, cb)
                            queries[#queries + 1] = { sql = sql, params = params }
                            if type(cb) ~= 'function' then return end
                            if sql:find('INSERT', 1, true) then cb({}) else cb(nil) end
                        end
                    end,
                })
            end,
        }),
    })

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaLog = function() end
    env.ArenaDebug = function() end

    env.Config.Database.enabled = true
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/server/stats.lua', env)

    local fixture = { env = env, S = env.ArenaStats, queries = queries }

    --- Moves this server's clock forward. Nothing else in the fixture can.
    function fixture.advance(seconds) offset = offset + seconds end

    --- The board, keyed by name.
    function fixture.board()
        local out = {}
        fixture.S.GetLeaderboard(function(rows)
            for _, row in ipairs(rows or {}) do out[row.name] = row end
        end)
        return out
    end

    --- Every queued row as the database would receive it, keyed by citizenid.
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

--- A finished match, shaped the way server/match.lua leaves one.
---
--- `who` is a list of { citizenid, name } in roster order; the first one
--- wins. `opts` overrides `ranAgo` (how many seconds ago the round went
--- live), `fought` (the go-live character list) and `winners`.
local function match(who, opts)
    opts = opts or {}

    local players, winners, ids = {}, {}, {}
    for index, entry in ipairs(who) do
        players[index] = {
            src = index,
            citizenid = entry[1],
            name = entry[2],
            kills = 0,
            deaths = 0,
        }
        ids[#ids + 1] = entry[1]
        if index == 1 then winners[#winners + 1] = index end
    end
    table.sort(ids)

    local ranAgo = opts.ranAgo
    if ranAgo == nil then ranAgo = 300 end

    return {
        id = opts.id or 'm1',
        players = players,
        winners = opts.winners or winners,
        payouts = opts.payouts or {},
        startsAt = opts.startsAt ~= nil and opts.startsAt or (os.time() - ranAgo),
        contestantIds = opts.fought ~= nil and opts.fought or ids,
    }
end

local ADA, BEN, CAL = { 'char:A', 'Ada' }, { 'char:B', 'Ben' }, { 'char:C', 'Cal' }
local DEE, EVE = { 'char:D', 'Dee' }, { 'char:E', 'Eve' }

--- The pair every window test farms with.
local function duel(opts) return match({ ADA, BEN }, opts) end

-- ========================================================================
-- THE SHIPPED DEFAULTS, WHICH ARE WHAT MOST SERVERS RUN
-- ========================================================================

t.test('the shipped config counts an ordinary duel', function()
    -- THE CONTROL, AND THE MOST IMPORTANT TEST IN THE FILE. Every rule below
    -- refuses something; this is the one that proves they do not refuse
    -- everything. A 1v1 between two real people, five minutes long, counts.
    local s = newStats()
    local m = duel()

    t.equals(s.S.RecordMatch(m), 2, 'an ordinary duel was not recorded')
    t.isTrue(m.ranked, 'the match was not marked ranked')
    t.isNil(m.rankedWhy, 'a counted match was given a reason it did not count')
    t.equals(s.board()['Ada'].wins, 1)
    t.equals(s.flushed()['char:B'].losses, 1)
end)

t.test('and the shipped defaults are the ones this file assumes', function()
    -- A guard on the file rather than on the code. Change a default in
    -- config.lua and the numbers below stop meaning what they say.
    local s = newStats()
    local rules = s.env.Config.Leaderboard

    t.isTrue(rules.rankedOnly, 'rankedOnly no longer ships on')
    t.equals(rules.minFighters, 2, 'minFighters no longer ships at two -- a duel is a real match')
    t.equals(rules.minSeconds, 30)
    t.equals(rules.repeatWindowMinutes, 60)
    t.equals(rules.maxPerOpponentSet, 3)
    t.equals(rules.repeatAppliesUpTo, 3)
end)

t.test('rankedOnly off counts everything, which is how this behaved before', function()
    -- The escape hatch has to actually work: an operator who turns this off
    -- gets the old board back, warts and all.
    local s = newStats(function(config) config.Leaderboard.rankedOnly = false end)

    local m = match({ ADA }, { ranAgo = 0, startsAt = 0 })
    t.equals(s.S.RecordMatch(m), 1, 'a one-second walkover was refused with the rules off')
    t.isTrue(m.ranked)
end)

t.test('and a Config.Leaderboard deleted entirely counts everything too', function()
    -- An operator upgrading from a config without this block must not find
    -- their board silently frozen.
    local s = newStats(function(config) config.Leaderboard = nil end)

    t.equals(s.S.RecordMatch(match({ ADA }, { ranAgo = 0 })), 1,
        'a missing Config.Leaderboard stopped the board recording anything')
end)

-- ========================================================================
-- AN UNRANKED MATCH WRITES NOTHING AT ALL
-- ========================================================================

t.test('a refused match records no win, no loss, no kills and no earnings', function()
    -- THE SHAPE OF THE REFUSAL. Not "a win without the win" and not a
    -- penalty: the round simply is not evidence, so nothing about it is
    -- written down. A rule that recorded the loss but not the win would hand
    -- a farmer a way to bury a rival.
    local s = newStats()

    local m = match({ ADA, BEN }, { ranAgo = 2 })
    m.players[1].kills = 9
    m.players[2].deaths = 9
    m.payouts = { { id = 1, amount = 50000, reason = 'payout' } }

    t.equals(s.S.RecordMatch(m), 0, 'a refused match still recorded players')
    t.equals(next(s.board()), nil, 'a refused match reached the board')
    t.equals(next(s.flushed()), nil, 'a refused match reached the database queue')
end)

t.test('and says so on the match, in words, for the results screen', function()
    local s = newStats()
    local m = match({ ADA, BEN }, { ranAgo = 2 })
    s.S.RecordMatch(m)

    t.isTrue(m.ranked == false, 'the match was not marked unranked')
    t.equals(type(m.rankedWhy), 'string', 'no reason was written for the player')
    t.isTrue(m.rankedWhy:find('30') ~= nil,
        'the reason does not name the threshold that was missed: ' .. tostring(m.rankedWhy))
end)

-- ========================================================================
-- HOW MANY PEOPLE WERE IN IT
-- ========================================================================

t.test('one character is a walkover, not a win', function()
    local s = newStats()
    local m = match({ ADA }, { fought = { 'char:A' } })

    t.equals(s.S.RecordMatch(m), 0, 'a match with one character in it counted')
    t.isTrue(m.rankedWhy:find('1') ~= nil, tostring(m.rankedWhy))
end)

t.test('two is enough, because a duel is a real match', function()
    local s = newStats()
    t.equals(s.S.RecordMatch(duel()), 2, 'a 1v1 was refused -- that is limiting matches')
end)

t.test('and two LOGINS on one character is still one person', function()
    -- The smallest farm there is: the same citizen id twice. Counted by
    -- character rather than by server id is what refuses it.
    local s = newStats()
    local m = match({ ADA, { 'char:A', 'Ada' } })

    t.equals(s.S.RecordMatch(m), 0, 'one character logged in twice counted as two fighters')
end)

t.test('the count is the GO-LIVE roster, so a quitter does not strip the rest', function()
    -- THE DEFECT THIS FIELD EXISTS FOR. RecordMatch reads `players`, and
    -- ArenaLobby.Leave takes a quitter out of it -- so a real three-way that
    -- one player rage-quit would have reached the board as a two-man duel,
    -- and at a floor of three it would have reached it as nothing at all.
    -- The go-live list is what is judged.
    local s = newStats(function(config) config.Leaderboard.minFighters = 3 end)

    local m = match({ ADA, BEN }, { fought = { 'char:A', 'char:B', 'char:C' } })
    t.equals(s.S.RecordMatch(m), 2, 'one player quitting cost the other two their result')
end)

t.test('and with no go-live list at all it falls back to who is still here', function()
    -- A record from a match that never reached goLive, or from an older
    -- server. Falling back is what stops the rule reading every such match
    -- as having had nobody in it -- which would have refused the lot.
    local s = newStats()
    local m = duel()
    m.contestantIds = nil

    t.equals(s.S.RecordMatch(m), 2, 'a record with no go-live list was refused outright')
end)

t.test('an empty go-live list falls back too, rather than counting zero', function()
    local s = newStats()
    local m = duel()
    m.contestantIds = {}

    t.equals(s.S.RecordMatch(m), 2, 'an empty go-live list read as an empty match')
end)

t.test('and rubbish inside the go-live list is dropped, not counted', function()
    local s = newStats()
    local m = duel({ fought = { 'char:A', '', false, 42, 'char:B' } })

    t.equals(s.S.RecordMatch(m), 2, 'a list with junk in it was refused or miscounted')
end)

t.test('minFighters = 0 turns the floor off entirely', function()
    local s = newStats(function(config) config.Leaderboard.minFighters = 0 end)

    t.equals(s.S.RecordMatch(match({ ADA }, { fought = { 'char:A' } })), 1,
        'a floor of zero still refused a one-character match')
end)

-- ========================================================================
-- HOW LONG IT LASTED
-- ========================================================================

t.test('a round shorter than the floor does not count', function()
    local s = newStats()
    t.equals(s.S.RecordMatch(duel({ ranAgo = 29 })), 0, 'a 29 second round counted')
end)

t.test('and one exactly on the floor does', function()
    -- The boundary, stated: 30 is "thirty or more", not "more than thirty".
    local s = newStats()
    t.equals(s.S.RecordMatch(duel({ ranAgo = 30 })), 2, 'a 30 second round was refused')
end)

t.test('a match that never went live at all does not count', function()
    local s = newStats()
    local m = duel({ startsAt = 0 })

    t.equals(s.S.RecordMatch(m), 0, 'a match with no start time counted')
    t.isTrue(m.rankedWhy:find('never went live') ~= nil, tostring(m.rankedWhy))
end)

t.test('and neither does one that died during its COUNTDOWN', function()
    -- THE TRAP IN THIS FIELD. `startsAt` means two things: Begin sets it to
    -- the second the countdown is DUE to finish, and goLive overwrites it
    -- with the second the round really started. So a match abandoned during
    -- its countdown carries a start time in the FUTURE, and subtracting it
    -- from now gives a negative number -- which, clamped at zero the obvious
    -- way, reads as a round that lasted no time rather than one that never
    -- happened. Both answers refuse it here; only one of them says why.
    local s = newStats()
    local m = duel({ startsAt = os.time() + 120 })

    t.equals(s.S.RecordMatch(m), 0, 'a match killed during its countdown counted')
    t.isTrue(m.rankedWhy:find('never went live') ~= nil, tostring(m.rankedWhy))
end)

t.test('minSeconds = 0 turns the clock rule off', function()
    local s = newStats(function(config) config.Leaderboard.minSeconds = 0 end)

    t.equals(s.S.RecordMatch(duel({ ranAgo = 0 })), 2, 'a floor of zero still refused an instant round')
end)

t.test('and with the clock rule off a match that never started still counts', function()
    -- Deliberate: minSeconds = 0 is an operator saying they do not care how
    -- long a round ran, and "it never ran" is the same answer to that
    -- question. The other two rules still apply.
    local s = newStats(function(config) config.Leaderboard.minSeconds = 0 end)

    t.equals(s.S.RecordMatch(duel({ startsAt = 0 })), 2)
end)

-- ========================================================================
-- THE SAME PEOPLE, OVER AND OVER
-- ========================================================================

t.test('the same pair counts three times and then stops', function()
    -- THE RULE THAT ACTUALLY STOPS A FARM. The two floors above cost a
    -- farmer thirty seconds and a second account. This is the one that makes
    -- the farm not work.
    local s = newStats()

    for round = 1, 3 do
        t.equals(s.S.RecordMatch(duel({ id = 'm' .. round })), 2,
            ('round %d of three was refused'):format(round))
    end

    local fourth = duel({ id = 'm4' })
    t.equals(s.S.RecordMatch(fourth), 0, 'a fourth round against the same pair still counted')
    t.isTrue(fourth.rankedWhy:find('already counted') ~= nil, tostring(fourth.rankedWhy))
    t.equals(s.board()['Ada'].wins, 3, 'the board moved on the refused round')
end)

t.test('and the loser swapping places does not make it a new set', function()
    -- Keyed on the whole roster rather than on who lost, so two friends
    -- taking turns are one set and not two.
    local s = newStats()

    s.S.RecordMatch(duel({ id = 'm1' }))
    s.S.RecordMatch(duel({ id = 'm2' }))
    s.S.RecordMatch(match({ BEN, ADA }, { id = 'm3' }))

    t.equals(s.S.RecordMatch(match({ BEN, ADA }, { id = 'm4' })), 0,
        'turning the result round the other way bought a fourth counted round')
end)

t.test('a DIFFERENT set counts on its own window', function()
    local s = newStats()

    for round = 1, 3 do s.S.RecordMatch(duel({ id = 'a' .. round })) end
    t.equals(s.S.RecordMatch(duel({ id = 'a4' })), 0, 'the first pair is not full')

    t.equals(s.S.RecordMatch(match({ CAL, DEE }, { id = 'b1' })), 2,
        'a completely different pair was refused because somebody else had farmed')
end)

t.test('and a shared member carries their own history, not the group\'s', function()
    -- WHY THE RULE IS ASKED OF EVERY MEMBER. One row is written per
    -- character per counted match, so on an unchanged set every member holds
    -- the same count and reading only the first would be enough. It stops
    -- being enough the moment somebody joins the group late: a fresh face
    -- has fewer rows than the regulars, and a rule that read only theirs
    -- would let the group carry on counting by rotating one newcomer in.
    local s = newStats()

    for round = 1, 3 do s.S.RecordMatch(duel({ id = 'a' .. round })) end

    -- Ada and Ben are full. Cal has never played. A THREE-WAY is a new set
    -- and counts -- that is the point, a genuinely different match.
    t.equals(s.S.RecordMatch(match({ ADA, BEN, CAL }, { id = 'c1' })), 3,
        'adding a third person did not make it a different match')

    -- ...but the pair on its own is still full.
    t.equals(s.S.RecordMatch(duel({ id = 'a4' })), 0,
        'a three-way in between refilled the pair\'s window')
end)

t.test('the window rolls past, and the pair counts again', function()
    -- A CEILING, NOT A BAN. The rule has to let go, or two people who play
    -- each other on Monday are still capped on Friday -- which is not a
    -- repeat rule, it is a permanent one.
    local s = newStats()

    for round = 1, 3 do s.S.RecordMatch(duel({ id = 'm' .. round })) end
    t.equals(s.S.RecordMatch(duel({ id = 'm4' })), 0, 'the window did not fill')

    -- Fifty-nine minutes: still inside the hour.
    s.advance(59 * 60)
    t.equals(s.S.RecordMatch(duel({ id = 'm5' })), 0,
        'the window let go a minute early')

    -- And past it.
    s.advance(2 * 60)
    t.equals(s.S.RecordMatch(duel({ id = 'm6' })), 2,
        'the window never let go at all -- the cap is permanent')
end)

t.test('and it rolls one round at a time, not all at once', function()
    -- The rows expire individually, so a pair that has been playing steadily
    -- gets one counted round back per hour rather than three.
    local s = newStats()

    s.S.RecordMatch(duel({ id = 'm1' }))
    s.advance(30 * 60)
    s.S.RecordMatch(duel({ id = 'm2' }))
    s.S.RecordMatch(duel({ id = 'm3' }))
    t.equals(s.S.RecordMatch(duel({ id = 'm4' })), 0, 'the window did not fill')

    -- Thirty-one minutes on, only the FIRST of the three has aged out.
    s.advance(31 * 60)
    t.equals(s.S.RecordMatch(duel({ id = 'm5' })), 2, 'the oldest row never expired')
    t.equals(s.S.RecordMatch(duel({ id = 'm6' })), 0,
        'one row ageing out emptied the whole window')
end)

t.test('maxPerOpponentSet = 0 turns the repeat rule off', function()
    local s = newStats(function(config) config.Leaderboard.maxPerOpponentSet = 0 end)

    for round = 1, 6 do
        t.equals(s.S.RecordMatch(duel({ id = 'm' .. round })), 2,
            ('round %d was refused with the repeat rule off'):format(round))
    end
end)

t.test('and so does a window of zero minutes', function()
    local s = newStats(function(config) config.Leaderboard.repeatWindowMinutes = 0 end)

    for round = 1, 6 do
        t.equals(s.S.RecordMatch(duel({ id = 'm' .. round })), 2,
            ('round %d was refused with no window to count inside'):format(round))
    end
end)

-- ========================================================================
-- ...AND ONLY ON ROSTERS SMALL ENOUGH TO STAGE
-- ========================================================================

t.test('a roster larger than repeatAppliesUpTo is never watched', function()
    -- WITHOUT THIS THE RULE PUNISHES REGULARS. Five people who play each
    -- other every evening are one set, and the repeat rule would have
    -- stopped counting their fourth round of the night. A farm needs every
    -- player in the room to be in on it, and that stops being arrangeable
    -- very quickly.
    local s = newStats()

    for round = 1, 8 do
        t.equals(s.S.RecordMatch(match({ ADA, BEN, CAL, DEE }, { id = 'm' .. round })), 4,
            ('round %d of a four-way was refused'):format(round))
    end
end)

t.test('and a roster exactly on the line still is', function()
    -- Three is "up to three", not "under three".
    local s = newStats()

    for round = 1, 3 do s.S.RecordMatch(match({ ADA, BEN, CAL }, { id = 'm' .. round })) end
    t.equals(s.S.RecordMatch(match({ ADA, BEN, CAL }, { id = 'm4' })), 0,
        'a three-way was treated as too big to watch')
end)

t.test('repeatAppliesUpTo = 0 watches every size', function()
    local s = newStats(function(config) config.Leaderboard.repeatAppliesUpTo = 0 end)

    for round = 1, 3 do s.S.RecordMatch(match({ ADA, BEN, CAL, DEE, EVE }, { id = 'm' .. round })) end
    t.equals(s.S.RecordMatch(match({ ADA, BEN, CAL, DEE, EVE }, { id = 'm4' })), 0,
        'a five-way was left alone with the size guard switched off')
end)

-- ========================================================================
-- THE TWO HALVES AGREE
-- ========================================================================

t.test('a match the rule ignores is not written into anybody\'s window', function()
    -- THE FIRST DIRECTION. A four-way is too big for the repeat rule to
    -- watch, so it must not fill its members' windows either -- otherwise
    -- three evenings of honest four-ways would quietly use up the budget
    -- their 1v1s are counted against.
    local s = newStats()

    for round = 1, 5 do s.S.RecordMatch(match({ ADA, BEN, CAL, DEE }, { id = 'm' .. round })) end

    for round = 1, 3 do
        t.equals(s.S.RecordMatch(duel({ id = 'd' .. round })), 2,
            ('their %s duel was refused because of a four-way'):format(round))
    end
end)

t.test('and a match the rules REFUSE is not written into one either', function()
    -- THE SECOND DIRECTION, and the one that costs a player rather than
    -- helping them. Three four-second rounds must not use up a pair's budget
    -- for the real match they play afterwards.
    local s = newStats()

    for round = 1, 5 do s.S.RecordMatch(duel({ id = 'x' .. round, ranAgo = 2 })) end

    for round = 1, 3 do
        t.equals(s.S.RecordMatch(duel({ id = 'd' .. round })), 2,
            ('a real round was refused because of an earlier refused one (%d)'):format(round))
    end
end)

t.test('a refused match does not stop the NEXT one being recorded', function()
    -- The gate returns early; nothing about that may be sticky.
    local s = newStats()

    t.equals(s.S.RecordMatch(duel({ id = 'x1', ranAgo = 1 })), 0)
    t.equals(s.S.RecordMatch(duel({ id = 'x2' })), 2, 'one refusal froze the board')
end)

-- ========================================================================
-- RUBBISH IS REFUSED, NOT GUESSED AT
-- ========================================================================

t.test('every rule survives a config written in the wrong types', function()
    -- An operator typing a string, and every one of these used to be
    -- arithmetic on it.
    local s = newStats(function(config)
        config.Leaderboard.minFighters = 'two'
        config.Leaderboard.minSeconds = {}
        config.Leaderboard.repeatWindowMinutes = 'an hour'
        config.Leaderboard.maxPerOpponentSet = false
        config.Leaderboard.repeatAppliesUpTo = 'three'
    end)

    t.equals(s.S.RecordMatch(duel()), 2, 'a config full of junk stopped the board recording')
end)

t.test('and a negative threshold reads as off rather than as backwards', function()
    local s = newStats(function(config)
        config.Leaderboard.minFighters = -5
        config.Leaderboard.minSeconds = -60
    end)

    t.equals(s.S.RecordMatch(match({ ADA }, { fought = { 'char:A' }, startsAt = 0 })), 1)
end)

t.test('Config.Leaderboard written as something other than a table counts everything', function()
    local s = newStats(function(config) config.Leaderboard = 'yes please' end)

    t.equals(s.S.RecordMatch(match({ ADA }, { ranAgo = 0 })), 1,
        'a mistyped block froze the board instead of being ignored')
end)

os.exit(t.summary())
