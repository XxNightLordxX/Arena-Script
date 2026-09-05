--[[
    crimson_arena/tests/schedule_spec.lua

    THE OPENING-HOURS ARITHMETIC, on its own, before anything depends on it.

    Config.Schedule turns a list of hour pairs into an answer to one
    question -- is the arena open right now, and if not, when -- and every
    interesting part of that is a boundary: the minute a window opens, the
    minute it shuts, midnight, and two windows that touch.

    WHY THIS FILE IS BRUTE-FORCED AND NOT JUST ENUMERATED. The first version
    of Arena.ScheduleSpans canonicalised a window that runs past midnight as
    { start, stop + 1440 } and fused the tail into the head afterwards. It
    passed every case worth writing by hand. It is wrong on

        { from = 0, to = 7 } + { from = 18, to = 16 } + { from = 10, to = 12 }

    where the fusion leaves two spans overlapping, their lengths sum past a
    day, the all-day guard trips, and the arena reports itself OPEN ALL DAY
    on a schedule that is genuinely shut from 16:00 to 18:00. Nothing short
    of checking every minute against an independent union found it. So that
    check stayed, at the bottom of this file, and it is the assertion that
    would catch the next rewrite too.

    The second bug it found: { from = 5, to = 0 } splits into {300,1440} and
    a ZERO-LENGTH {0,0}, which survives the merge and is then picked as the
    nearest opening -- so an arena shut at midnight answers "opens at
    00:00". That is `if e > 0` in the source, and a case here.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('schedule_spec')

--- A sandbox whose Config.Schedule is exactly the windows given.
--- @param windows table[]
--- @return table env
local function withWindows(windows)
    local env = Sandbox.newArenaEnv()
    env.Config.Schedule = { enabled = true, windows = windows, offsetHours = 0 }
    return env
end

local SHIPPED = {
    { from = 0, to = 2 }, { from = 5, to = 7 },
    { from = 12, to = 14 }, { from = 18, to = 20 },
}

-- ======================================================================
-- THE TWO BOUNDARY MINUTES
-- ======================================================================

t.test('a window is open on the minute it opens', function()
    local env = withWindows({ { from = 5, to = 7 } })
    -- THE BOUNDARY MINUTE ITSELF, not 05:01. `now >= start` mutated to
    -- `now > start` is invisible at 05:01 and caught only here.
    t.isTrue(env.Arena.ScheduleStatus(5, 0).open, '05:00 was shut on a 05:00-07:00 window')
end)

t.test('and SHUT on the minute it closes', function()
    local env = withWindows({ { from = 5, to = 7 } })
    t.isTrue(env.Arena.ScheduleStatus(6, 59).open, '06:59 was shut')
    -- The load-bearing one: `now < stop` mutated to `<=` survives 06:59.
    t.isFalse(env.Arena.ScheduleStatus(7, 0).open,
        '07:00 was open -- the upper bound must be exclusive or two touching windows claim the same hour twice')
end)

-- ======================================================================
-- MIDNIGHT
-- ======================================================================

t.test('a window may run over midnight', function()
    local env = withWindows({ { from = 22, to = 2 } })
    t.isTrue(env.Arena.ScheduleStatus(23, 0).open, '23:00 was shut on a 22:00-02:00 window')
    t.isTrue(env.Arena.ScheduleStatus(1, 0).open, '01:00 was shut on a 22:00-02:00 window')
    t.isFalse(env.Arena.ScheduleStatus(2, 0).open, '02:00 was open')
    t.isFalse(env.Arena.ScheduleStatus(21, 59).open, '21:59 was open')
end)

t.test('and a window that does NOT wrap never leaks into the small hours', function()
    -- The other half of the canonicaliser mutation: `if e < s` flipped to
    -- `if e > s` makes every ordinary window wrap instead.
    local env = withWindows({ { from = 5, to = 7 } })
    t.isFalse(env.Arena.ScheduleStatus(1, 0).open, '01:00 was open on a 05:00-07:00 window')
end)

t.test('DEFECT: a wrap must be split, not carried past the end of the day', function()
    -- The case the brute force found. Carrying { from=18, to=16 } as
    -- {1080, 2400} and fusing afterwards leaves the day reported as fully
    -- covered, and 16:00 -- genuinely shut -- reads as open.
    local env = withWindows({
        { from = 0, to = 7 }, { from = 18, to = 16 }, { from = 10, to = 12 },
    })
    local shut = env.Arena.ScheduleStatus(16, 0)
    t.isFalse(shut.open, '16:00 was open on a schedule that is shut from 16:00 to 18:00')
    t.isTrue(shut.always ~= true, 'the schedule reported itself as open all day')
    t.isTrue(env.Arena.ScheduleStatus(18, 0).open, '18:00 was shut')
end)

t.test('DEFECT: the zero-length tail of a window ending at midnight is dropped', function()
    local env = withWindows({ { from = 5, to = 0 } })
    t.equals(#env.Arena.ScheduleSpans(), 1, 'an empty span survived the split')
    t.isFalse(env.Arena.ScheduleStatus(0, 0).open, 'midnight was open on a 05:00-24:00 window')
    -- The symptom an operator would actually see: without the guard the
    -- empty span at 00:00 is the nearest opening, so the arena says it
    -- opens at the exact minute it is shut.
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(0, 0).opensAt), '05:00',
        'the arena said it opens at the minute it is shut')
    t.equals(env.Arena.ScheduleLine(), '05:00-24:00')
end)

-- ======================================================================
-- MERGING
-- ======================================================================

t.test('two windows that touch are one opening', function()
    local env = withWindows({ { from = 5, to = 7 }, { from = 7, to = 9 } })
    -- Containment alone cannot see this: 07:00 is covered either way. The
    -- count and the rendered line are what make `<=` load-bearing.
    t.equals(#env.Arena.ScheduleSpans(), 1, '05:00-07:00 and 07:00-09:00 stayed two spans')
    t.equals(env.Arena.ScheduleLine(), '05:00-09:00')
end)

t.test('and one window inside another is absorbed', function()
    local env = withWindows({ { from = 5, to = 12 }, { from = 6, to = 8 } })
    t.equals(#env.Arena.ScheduleSpans(), 1)
    t.equals(env.Arena.ScheduleLine(), '05:00-12:00')
end)

-- ======================================================================
-- WHEN IT SHUTS
-- ======================================================================

t.test('a wrapped window closes at its real end, not at midnight', function()
    local env = withWindows({ { from = 22, to = 2 } })
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(23, 0).closesAt), '02:00',
        'a player at 23:00 was told the arena shuts at midnight')
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(1, 0).closesAt), '02:00')
end)

t.test('and so do two SEPARATE windows that meet across midnight', function()
    -- 00:00-02:00 and 22:00-24:00 are written apart and are contiguous, so
    -- they are one overnight opening to the player standing in them.
    local env = withWindows({ { from = 0, to = 2 }, { from = 22, to = 24 } })
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(23, 0).closesAt), '02:00')
end)

t.test('but an ordinary window is not joined to the first one', function()
    -- Kills the half-mutant that joins on `spans[1].start == 0` alone,
    -- without also requiring this span to run to the end of the day.
    local env = withWindows(SHIPPED)
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(19, 0).closesAt), '20:00',
        'the 18:00-20:00 window was joined to the midnight one')
end)

-- ======================================================================
-- WHEN IT NEXT OPENS
-- ======================================================================

t.test('the next opening is the nearest one forward, wrapping past midnight', function()
    local env = withWindows(SHIPPED)
    local function opensAt(hour, minute)
        return env.Arena.ClockText(env.Arena.ScheduleStatus(hour, minute).opensAt)
    end

    -- MORE THAN ONE SAMPLE ON PURPOSE. `(start - now) % 1440` inverted to
    -- `(now - start) % 1440` gives the RIGHT answer at 21:00 by coincidence
    -- and the wrong one everywhere else, so a single-sample test would pass
    -- against the inverted subtraction. Do not simplify this back to one.
    t.equals(opensAt(7, 0), '12:00')
    t.equals(opensAt(11, 0), '12:00')
    t.equals(opensAt(2, 0), '05:00')
    t.equals(opensAt(21, 0), '00:00')
    t.equals(opensAt(23, 59), '00:00')
end)

t.test('and it is never a time in the past', function()
    -- math.fmod in place of `%` returns a negative here, which renders as
    -- an hour that has already gone.
    local env = withWindows({ { from = 22, to = 2 } })
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(12, 0).opensAt), '22:00')
    t.equals(env.Arena.ClockText(env.Arena.ScheduleStatus(2, 0).opensAt), '22:00')
end)

-- ======================================================================
-- THE DEGENERATE SCHEDULES, AND THE UPGRADE RULE
-- ======================================================================

t.test('THE UPGRADE RULE: no windows at all means always open', function()
    -- THE HIGHEST-VALUE ASSERTION IN THIS FILE. A server that pulls this
    -- code before its config.lua has a Config.Schedule must keep an arena
    -- that works. Reverse this and every existing install goes dark on
    -- update, at every hour, with nothing on screen explaining it.
    local env = withWindows({})
    t.isTrue(env.Arena.ScheduleStatus(3, 0).open, 'an empty window list shut the arena')
    t.isNil(env.Arena.ScheduleLine(), 'an empty window list advertised a schedule')
end)

t.test('and so does no Config.Schedule at all', function()
    local env = Sandbox.newArenaEnv()
    env.Config.Schedule = nil
    t.isTrue(env.Arena.ScheduleStatus(3, 0).open, 'a missing Config.Schedule shut the arena')
end)

t.test('and so does the switch being off', function()
    local env = withWindows(SHIPPED)
    env.Config.Schedule.enabled = false
    t.isTrue(env.Arena.ScheduleStatus(3, 0).open, 'enabled = false still shut the arena')
end)

t.test('a schedule covering the whole day advertises nothing', function()
    local env = withWindows({ { from = 0, to = 24 } })
    t.isTrue(env.Arena.ScheduleStatus(3, 0).always, 'all day was not recognised as all day')
    -- 1440 % 1440 renders as "00:00-00:00", which is why the guard is on
    -- coverage and not on the rendering.
    t.isNil(env.Arena.ScheduleLine(), 'an all-day schedule printed a window')
end)

t.test('a window that opens and shuts at the same hour is dropped, not guessed', function()
    local env = withWindows({ { from = 5, to = 5 } })
    t.equals(#env.Arena.ScheduleSpans(), 0, 'from == to was kept')
    t.isTrue(env.Arena.ScheduleStatus(3, 0).open,
        'dropping the only window left the arena shut rather than open')
end)

t.test('hours out of range are dropped rather than clamped', function()
    local env = withWindows({
        { from = -1, to = 7 }, { from = 5, to = 25 }, { from = 'x', to = 7 },
        { from = 12, to = 14 },
    })
    -- A clamped hour is a window nobody typed. Assert the COUNT: a clamp
    -- would leave three or four spans here, not one.
    t.equals(#env.Arena.ScheduleSpans(), 1, 'a bad window was clamped instead of dropped')
    t.equals(env.Arena.ScheduleLine(), '12:00-14:00')
end)

t.test('the shipped windows read back exactly as written', function()
    -- Sandbox.newArenaEnv switches hours OFF so that the rest of the suite
    -- is not a suite about what time it is; this file is the one that turns
    -- them back on, so it is also the one that has to check what ships.
    local env = Sandbox.newArenaEnv()
    env.Config.Schedule.enabled = true
    t.equals(env.Arena.ScheduleLine(), '00:00-02:00, 05:00-07:00, 12:00-14:00, 18:00-20:00',
        'the shipped Config.Schedule does not render as the four windows it lists')
end)

-- ======================================================================
-- THE REGRESSION GUARD AROUND THE TEMPTING WRONG PLACEMENT
-- ======================================================================

t.test('Arena.CanStartMatch carries NO hours term, and must not gain one', function()
    -- server/match.lua's goLive answers a CanStartMatch refusal with
    -- ArenaMatch.Abort, and the countdown thread re-asks every second. An
    -- hours term here would therefore tear a round down at the stroke of
    -- the hour, mid-freeze, and strand a fully readied lobby that the idle
    -- sweep can never collect -- that sweep requires readyCount == 0 -- with
    -- every stake escrowed for good.
    --
    -- The gate lives at the two doors instead: ArenaLobby.Join and
    -- ArenaMatch.Begin.
    -- DIFFERENTIAL, not an absolute. Whether this particular roster is
    -- startable is Arena.CanStartMatch's own business and is asserted
    -- elsewhere; what matters here is that the SCHEDULE does not move its
    -- answer. Building a roster it happens to accept would make this test
    -- about the roster.
    local env = withWindows({ { from = 5, to = 7 } })
    local match = {
        state = 'lobby',
        modeKey = env.Config.DefaultMode,
        players = { [1] = { src = 1, ready = true }, [2] = { src = 2, ready = true } },
        order = { 1, 2 },
    }

    local openAnswer, openReason = env.Arena.CanStartMatch(match)

    env.Config.Schedule.windows = {}
    local shutAnswer, shutReason = env.Arena.CanStartMatch(match)

    t.equals(tostring(shutAnswer), tostring(openAnswer),
        'CanStartMatch changed its answer with the schedule -- that term belongs at the doors, not here')
    t.equals(tostring(shutReason), tostring(openReason),
        'CanStartMatch changed its refusal reason with the schedule')
end)

-- ======================================================================
-- BRUTE FORCE
--
-- Kept in the suite rather than only used to find the bugs above: it is the
-- assertion that catches the NEXT rewrite of the span arithmetic.
-- ======================================================================

t.test('FUZZ: every minute of every random schedule agrees with a minute-by-minute union', function()
    local env = Sandbox.newArenaEnv()
    -- Fixed seed: a fuzz test that cannot be re-run on the same input is a
    -- fuzz test nobody can debug.
    math.randomseed(20260905)

    local broke = nil
    for _ = 1, 400 do
        local windows = {}
        for _ = 1, math.random(1, 5) do
            windows[#windows + 1] = { from = math.random(0, 23), to = math.random(0, 24) }
        end
        env.Config.Schedule = { enabled = true, windows = windows, offsetHours = 0 }

        -- The independent answer: paint every covered minute directly from
        -- what the operator typed, with no spans and no merging.
        local painted = {}
        for _, window in ipairs(windows) do
            if window.from ~= window.to then
                local s, e = window.from * 60, window.to * 60
                if e < s then
                    for m = s, 1439 do painted[m] = true end
                    for m = 0, e - 1 do painted[m] = true end
                else
                    for m = s, e - 1 do painted[m] = true end
                end
            end
        end

        local anyPainted = false
        for m = 0, 1439 do if painted[m] then anyPainted = true break end end

        for m = 0, 1439 do
            local status = env.Arena.ScheduleStatus(math.floor(m / 60), m % 60)
            -- An unusable list means always open, which the union cannot
            -- express -- so that case is checked by its own test above.
            --
            -- WRITTEN AS AN `if`, NOT `a and b or c`. That idiom silently
            -- yields `c` whenever `b` is false, so the whole fuzz would
            -- have expected "open" at every shut minute and passed against
            -- an implementation that never closes. It did exactly that
            -- until this line was changed.
            local expected = true
            if anyPainted then expected = painted[m] == true end
            if status.open ~= expected and not broke then
                broke = ('minute %d: schedule says %s, the union says %s'):format(
                    m, tostring(status.open), tostring(expected))
            end
        end
    end

    t.isNil(broke, broke or '')
end)

t.test('FUZZ: the minute it says it opens is open, and the one before it is not', function()
    local env = Sandbox.newArenaEnv()
    math.randomseed(20260906)

    local broke = nil
    for _ = 1, 400 do
        local windows = {}
        for _ = 1, math.random(1, 4) do
            windows[#windows + 1] = { from = math.random(0, 23), to = math.random(0, 24) }
        end
        env.Config.Schedule = { enabled = true, windows = windows, offsetHours = 0 }

        for _ = 1, 12 do
            local m = math.random(0, 1439)
            local status = env.Arena.ScheduleStatus(math.floor(m / 60), m % 60)
            if status.open == false then
                local at = status.opensAt
                local before = (at - 1) % 1440
                local openThen = env.Arena.ScheduleStatus(math.floor(at / 60), at % 60).open
                local openBefore = env.Arena.ScheduleStatus(math.floor(before / 60), before % 60).open
                if (not openThen or openBefore) and not broke then
                    broke = ('from %d it said it opens at %d, where open=%s and the minute before is open=%s')
                        :format(m, at, tostring(openThen), tostring(openBefore))
                end
            end
        end
    end

    t.isNil(broke, broke or '')
end)

os.exit(t.summary())
