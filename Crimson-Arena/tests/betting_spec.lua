--[[
    crimson_arena/tests/betting_spec.lua

    The money maths, exercised against the REAL shared/arena.lua loaded
    through tests/fixtures/sandbox.lua. Nothing here re-implements a rule --
    a spec carrying its own copy of the arithmetic would agree with itself
    forever while production drifted.

    THE PROPERTY THIS FILE EXISTS FOR: what goes into the pot comes out of
    it. Every split assertion checks the TOTAL, not only the individual
    shares, because the way this breaks on a live server is a few dollars a
    match rounding into nowhere -- nobody reports that and everybody
    notices it.

    THE SECOND PROPERTY: a refund returns each player their OWN stake. That
    only differs from an even share of the pot when stakes differ, which is
    exactly the case an even-share bug survives -- it balances the books
    while quietly moving money between players.

    Config variations are made by mutating `env.Config` after loading, so a
    spec describing a 50%-house-cut server never edits config.lua.
]]

local t = dofile('testkit.lua')
local sandbox = dofile('fixtures/sandbox.lua')

print('betting_spec')

-- ======================================================================
-- HELPERS
-- ======================================================================

--- A fresh `Arena` over a fresh `Config`, with `mutate` applied to
--- Config.Betting before any test touches it. Fresh per test on purpose:
--- one shared env would let a house cut set in one test decide the answer
--- in the next.
--- @param mutate fun(betting: table)?
--- @return table Arena
local function arenaWith(mutate)
    local env = sandbox.newArenaEnv()
    if mutate then mutate(env.Config.Betting) end
    return env.Arena
end

--- @param list integer[]
--- @return integer
local function sum(list)
    local total = 0
    for _, value in ipairs(list) do total = total + value end
    return total
end

--- @param payouts table[] -- { { id, amount, reason }, ... }
--- @return integer
local function payoutTotal(payouts)
    local total = 0
    for _, payout in ipairs(payouts) do total = total + payout.amount end
    return total
end

--- What one id was paid, or nil when they got no row at all. The two are
--- different outcomes: a row of 0 is a payment of nothing, no row is not
--- being paid.
--- @param payouts table[]
--- @param id any
--- @return integer|nil
local function amountFor(payouts, id)
    for _, payout in ipairs(payouts) do
        if payout.id == id then return payout.amount end
    end
    return nil
end

--- @param payouts table[]
--- @param id any
--- @return string|nil
local function reasonFor(payouts, id)
    for _, payout in ipairs(payouts) do
        if payout.id == id then return payout.reason end
    end
    return nil
end

--- Money is integer money all the way to AddMoney. A float share prints the
--- same and then gets rounded somewhere this resource cannot see.
--- @param list integer[]
--- @param message string
local function assertIntegers(list, message)
    for index, value in ipairs(list) do
        t.equals(math.type(value), 'integer', ('%s: entry %d (%s)'):format(message, index, tostring(value)))
    end
end

--- Players for a payout context. Stakes are deliberately unequal in most
--- tests below -- equal stakes hide the refund bug this file hunts.
--- @param rows table[] -- { { id, kills, stake }, ... }
--- @return table[]
local function playersOf(rows)
    local players = {}
    for index, row in ipairs(rows) do
        players[index] = { id = row.id, team = row.team, kills = row.kills or 0, stake = row.stake or 0 }
    end
    return players
end

-- ======================================================================
-- SplitEvenly
-- ======================================================================

t.test('SplitEvenly hands out the remainder rather than dropping it: 7 into 3', function()
    local shares = arenaWith().SplitEvenly(7, 3)
    t.equals(#shares, 3)
    t.equals(shares[1], 3)
    t.equals(shares[2], 2)
    t.equals(shares[3], 2)
    t.equals(sum(shares), 7, 'the pot leaked')
    assertIntegers(shares, '7 into 3')
end)

t.test('SplitEvenly gives the single unit to one recipient: 1 into 5', function()
    local shares = arenaWith().SplitEvenly(1, 5)
    t.equals(#shares, 5)
    t.equals(shares[1], 1)
    t.equals(shares[5], 0)
    t.equals(sum(shares), 1, 'the pot leaked')
end)

t.test('SplitEvenly of nothing pays everybody nothing: 0 into 4', function()
    local shares = arenaWith().SplitEvenly(0, 4)
    t.equals(#shares, 4)
    t.equals(sum(shares), 0)
    assertIntegers(shares, '0 into 4')
end)

t.test('SplitEvenly with nobody to pay returns no shares at all', function()
    local Arena = arenaWith()
    t.equals(#Arena.SplitEvenly(500, 0), 0)
    t.equals(#Arena.SplitEvenly(500, -3), 0)
    -- No money is lost here: there is nobody to hand it to, and the one
    -- caller that could reach this -- ComputePayouts with no winners --
    -- refunds before it ever gets to the split.
end)

t.test('SplitEvenly refuses to invent money from a negative or non-numeric amount', function()
    local Arena = arenaWith()
    t.equals(sum(Arena.SplitEvenly(-500, 2)), 0)
    t.equals(sum(Arena.SplitEvenly('not money', 2)), 0)
    t.equals(sum(Arena.SplitEvenly(nil, 2)), 0)
    t.equals(#Arena.SplitEvenly(100, 'two'), 0, 'a non-numeric head count is nobody, not one')
end)

t.test('SplitEvenly never loses or invents a unit, 0..40 into 1..7', function()
    local Arena = arenaWith()
    for amount = 0, 40 do
        for count = 1, 7 do
            local shares = Arena.SplitEvenly(amount, count)
            local case = ('%d into %d'):format(amount, count)
            t.equals(#shares, count, case .. ': wrong number of shares')
            t.equals(sum(shares), amount, case .. ': total moved')

            -- Fair as well as complete: with the remainder handed out one
            -- unit at a time, no two winners can differ by more than 1.
            local lowest, highest = shares[1], shares[1]
            for _, share in ipairs(shares) do
                if share < lowest then lowest = share end
                if share > highest then highest = share end
            end
            t.isTrue(highest - lowest <= 1, case .. ': shares differ by more than one unit')
        end
    end
end)

-- ======================================================================
-- SplitByPercent
-- ======================================================================

t.test('SplitByPercent splits by a list that sums to 100', function()
    local shares = arenaWith().SplitByPercent(1000, { 60, 30, 10 })
    t.equals(shares[1], 600)
    t.equals(shares[2], 300)
    t.equals(shares[3], 100)
    t.equals(sum(shares), 1000)
end)

t.test('SplitByPercent normalises a list that sums to less than 100', function()
    -- 60 and 30 of a pot is 90% of it. The missing 10% is not left in the
    -- pot -- there is no pot left to leave it in -- so the list is treated
    -- as a ratio and the whole amount goes out.
    local shares = arenaWith().SplitByPercent(1000, { 60, 30 })
    t.equals(shares[1], 667)
    t.equals(shares[2], 333)
    t.equals(sum(shares), 1000, 'the missing percent must not become a leak')
end)

t.test('SplitByPercent normalises a list that sums to more than 100', function()
    local shares = arenaWith().SplitByPercent(100, { 50, 50, 50 })
    t.equals(shares[1], 34)
    t.equals(shares[2], 33)
    t.equals(shares[3], 33)
    t.equals(sum(shares), 100, 'an over-100 list must not pay out more than the pot')
end)

t.test('SplitByPercent gives the rounding remainder to the first recipient', function()
    local shares = arenaWith().SplitByPercent(10, { 1, 1, 1 })
    t.equals(shares[1], 4)
    t.equals(shares[2], 3)
    t.equals(shares[3], 3)
    t.equals(sum(shares), 10)
end)

t.test('SplitByPercent falls back to an even split when every percent is zero', function()
    local shares = arenaWith().SplitByPercent(7, { 0, 0 })
    t.equals(sum(shares), 7, 'a zeroed split list must not swallow the pot')
    t.equals(shares[1], 4)
    t.equals(shares[2], 3)
end)

t.test('SplitByPercent with an empty or missing list pays nobody', function()
    local Arena = arenaWith()
    t.equals(#Arena.SplitByPercent(1000, {}), 0)
    t.equals(#Arena.SplitByPercent(1000, nil), 0)
    t.equals(#Arena.SplitByPercent(1000, 'sixty forty'), 0)
end)

t.test('SplitByPercent stays exact on a pot large enough to expose float rounding', function()
    local shares = arenaWith().SplitByPercent(999999999, { 60, 30, 10 })
    t.equals(sum(shares), 999999999)
    assertIntegers(shares, 'large pot')
end)

t.test('SplitByPercent never loses or invents a unit across awkward lists', function()
    local Arena = arenaWith()
    local lists = {
        { 60, 30, 10 }, { 60, 30 }, { 60 }, { 50, 50, 50 }, { 1, 1, 1 },
        { 0, 0, 0 }, { 100, 0, 0 }, { 33, 33, 33 }, { 7 }, { 1, 99 },
    }
    for _, percents in ipairs(lists) do
        for _, amount in ipairs({ 0, 1, 3, 7, 100, 999, 1000, 12345 }) do
            local shares = Arena.SplitByPercent(amount, percents)
            local case = ('%d by %d entries'):format(amount, #percents)
            t.equals(#shares, #percents, case .. ': wrong number of shares')
            t.equals(sum(shares), amount, case .. ': total moved')
            assertIntegers(shares, case)
        end
    end
end)

-- ======================================================================
-- ApplyHouseCut
-- ======================================================================

t.test('ApplyHouseCut at 0 percent takes nothing', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 0 end).ApplyHouseCut(1000)
    t.equals(net, 1000)
    t.equals(cut, 0)
end)

t.test('ApplyHouseCut at 1 percent takes one hundredth', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 1 end).ApplyHouseCut(1000)
    t.equals(net, 990)
    t.equals(cut, 10)
end)

t.test('ApplyHouseCut at 50 percent halves the pot', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 50 end).ApplyHouseCut(1000)
    t.equals(net, 500)
    t.equals(cut, 500)
end)

t.test('ApplyHouseCut at 99 percent leaves a hundredth to play for', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 99 end).ApplyHouseCut(1000)
    t.equals(net, 10)
    t.equals(cut, 990)
end)

t.test('ApplyHouseCut at 100 percent leaves nothing to pay out', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 100 end).ApplyHouseCut(1000)
    t.equals(net, 0)
    t.equals(cut, 1000)
end)

--- The complaints ValidateConfig produced for this config, as one string.
local function complaintsFrom(mutate)
    local env = sandbox.newArenaEnv()
    if mutate then mutate(env.Config) end
    local list = env.Arena.ValidateConfig()
    return table.concat(type(list) == 'table' and list or {}, '\n')
end

t.test('DEFECT: a rake that cannot be taken is said out loud, not left to the payouts', function()
    -- houseCutPercent is applied by ComputePayouts, which only runs when the
    -- pot settles on its OWN. betPayout.includeEntryPot ships ON and hands
    -- the fees to the bet pool instead, so Settle returns before the cut is
    -- ever reached: the operator sets a rake, takes none, and the console
    -- says nothing. Silence is the defect -- an operator can read a warning
    -- and decide, and cannot read an absence.
    t.contains(complaintsFrom(function(config) config.Betting.houseCutPercent = 25 end),
        'NO CUT IS TAKEN', 'a rake under includeEntryPot passed without a word')
end)

t.test('and it names both settings, because either one resolves it', function()
    -- Which of the two an operator wants is their decision: rake the pot, or
    -- stop asking. A complaint that names one of them has chosen for them.
    local said = complaintsFrom(function(config) config.Betting.houseCutPercent = 25 end)
    t.contains(said, 'includeEntryPot', 'the complaint does not name the switch that disables the cut')
    t.contains(said, 'houseCutPercent', 'the complaint does not name the cut itself')
end)

t.test('DEFECT: and so is a head-count threshold that is never checked', function()
    -- The same defect one setting over. minPlayersToPayOut is read in exactly
    -- one place -- Arena.ComputePayouts -- and that only runs when the pot
    -- settles on its own. With the fees folded into the pool, Settle returns
    -- before it. An operator who raises this to stop two friends farming each
    -- other watches two friends farm each other.
    t.contains(complaintsFrom(function(config) config.Betting.minPlayersToPayOut = 5 end),
        'NEVER CHECKED', 'an unenforceable head count passed without a word')
end)

t.test('and the shipped threshold is left alone, because it could never refuse one', function()
    -- The shipped value is 2, which is also the smallest match this server
    -- will start, so it can never turn a payout down. Warning about it is
    -- noise on a working default, and this whole area only works if the
    -- start-up report stays worth reading.
    t.notContains(complaintsFrom(nil), 'NEVER CHECKED',
        'the shipped config warns about a threshold that costs nothing')
    t.notContains(complaintsFrom(function(config)
        config.Betting.minPlayersToPayOut = 3
        config.Match.minPlayers = 4
    end), 'NEVER CHECKED', 'a threshold below the smallest roster was complained about')
end)

t.test('and one the pot really checks is not complained about', function()
    t.notContains(complaintsFrom(function(config)
        config.Betting.minPlayersToPayOut = 5
        config.Betting.betPayout.includeEntryPot = false
    end), 'NEVER CHECKED', 'an enforced threshold was reported as dead')
end)

t.test('but a rake that IS taken passes without comment', function()
    -- The other half. A warning that fires on a working config is noise, and
    -- noise in a startup report is how a real one gets scrolled past.
    t.notContains(complaintsFrom(function(config)
        config.Betting.houseCutPercent = 25
        config.Betting.betPayout.includeEntryPot = false
    end), 'NO CUT IS TAKEN', 'a rake that the pot really pays was complained about')
end)

t.test('and so does the shipped config, which asks for no cut at all', function()
    t.notContains(complaintsFrom(nil), 'NO CUT IS TAKEN',
        'the shipped config warns about a rake it does not ask for')
end)

t.test('ApplyHouseCut treats an out-of-range percent as its nearest legal end', function()
    -- ValidateConfig complains about both of these, but complaining is all
    -- it does -- the maths still has to answer, and it answers by clamping
    -- rather than by taking a negative cut or more than the pot.
    local negative = arenaWith(function(betting) betting.houseCutPercent = -25 end)
    local netLow, cutLow = negative.ApplyHouseCut(1000)
    t.equals(netLow, 1000)
    t.equals(cutLow, 0)

    local excessive = arenaWith(function(betting) betting.houseCutPercent = 150 end)
    local netHigh, cutHigh = excessive.ApplyHouseCut(1000)
    t.equals(netHigh, 0)
    t.equals(cutHigh, 1000)
end)

t.test('ApplyHouseCut treats a non-numeric percent as no cut', function()
    local net, cut = arenaWith(function(betting) betting.houseCutPercent = 'half' end).ApplyHouseCut(1000)
    t.equals(net, 1000)
    t.equals(cut, 0)
end)

t.test('ApplyHouseCut refuses a negative or non-numeric pot', function()
    local Arena = arenaWith(function(betting) betting.houseCutPercent = 50 end)
    local netNegative, cutNegative = Arena.ApplyHouseCut(-1000)
    t.equals(netNegative, 0)
    t.equals(cutNegative, 0)

    local netJunk, cutJunk = Arena.ApplyHouseCut('a lot')
    t.equals(netJunk, 0)
    t.equals(cutJunk, 0)
end)

t.test('ApplyHouseCut net plus cut is always exactly the pot', function()
    for _, percent in ipairs({ -5, 0, 1, 7, 33, 50, 99, 100, 200 }) do
        local Arena = arenaWith(function(betting) betting.houseCutPercent = percent end)
        for _, pot in ipairs({ 0, 1, 7, 99, 100, 999, 1000, 123457 }) do
            local net, cut = Arena.ApplyHouseCut(pot)
            local case = ('%d%% of %d'):format(percent, pot)
            t.equals(net + cut, pot, case .. ': the house cut leaked')
            t.isTrue(net >= 0 and cut >= 0, case .. ': negative money')
            t.equals(math.type(net), 'integer', case .. ': net is not an integer')
            t.equals(math.type(cut), 'integer', case .. ': cut is not an integer')
        end
    end
end)

-- ======================================================================
-- ComputePayouts -- winner_takes_all
-- ======================================================================

t.test('winner_takes_all pays one winner the whole net pot', function()
    local Arena = arenaWith(function(betting) betting.payout = 'winner_takes_all' end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 500 }, { id = 2, stake = 500 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 1)
    t.equals(amountFor(payouts, 1), 1000)
    t.equals(reasonFor(payouts, 1), 'winner')
    t.equals(cut, 0)
    t.equals(payoutTotal(payouts) + cut, 1000, 'the pot leaked')
end)

t.test('winner_takes_all splits evenly across a whole winning team', function()
    local Arena = arenaWith(function(betting) betting.payout = 'winner_takes_all' end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({
            { id = 1, team = 'crimson', stake = 250 }, { id = 2, team = 'crimson', stake = 250 },
            { id = 3, team = 'crimson', stake = 250 }, { id = 4, team = 'ash', stake = 250 },
        }),
        winners = { 1, 2, 3 },
        teams = true,
    })
    t.equals(#payouts, 3)
    t.equals(amountFor(payouts, 1), 334)
    t.equals(amountFor(payouts, 2), 333)
    t.equals(amountFor(payouts, 3), 333)
    t.equals(payoutTotal(payouts), 1000, 'the remainder unit was dropped')
end)

t.test('winning on the stacked side of a 7v1 is worth less per head', function()
    -- This is the balance that makes uneven teams safe to allow, so it is
    -- a rule and not an accident: the pot is split across the winners, not
    -- awarded per winner.
    local Arena = arenaWith(function(betting) betting.payout = 'winner_takes_all' end)
    local rows, winners = {}, {}
    for id = 1, 7 do
        rows[id] = { id = id, team = 'crimson', stake = 125 }
        winners[id] = id
    end
    rows[8] = { id = 8, team = 'ash', stake = 125 }

    local payouts = Arena.ComputePayouts({
        pot = 1000, players = playersOf(rows), winners = winners, teams = true,
    })
    t.equals(#payouts, 7)
    t.equals(payoutTotal(payouts), 1000, 'the pot leaked across seven winners')
    t.isTrue(amountFor(payouts, 1) < 1000, 'a stacked side must not pay each member the whole pot')
    t.equals(amountFor(payouts, 1), 143)
    t.equals(amountFor(payouts, 7), 142)
end)

t.test('an unrecognised payout mode falls back to winner_takes_all', function()
    local Arena = arenaWith(function(betting) betting.payout = 'winner_takes_everything' end)
    local payouts = Arena.ComputePayouts({
        pot = 900,
        players = playersOf({ { id = 1, stake = 450 }, { id = 2, stake = 450 } }),
        winners = { 1, 2 },
        teams = false,
    })
    t.equals(reasonFor(payouts, 1), 'winner')
    t.equals(payoutTotal(payouts), 900, 'a typo in config must not eat the pot')
end)

t.test('the house cut comes out of the pot before the winners split it', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'winner_takes_all'
        betting.houseCutPercent = 10
    end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 500 }, { id = 2, stake = 500 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(cut, 100)
    t.equals(amountFor(payouts, 1), 900)
    t.equals(payoutTotal(payouts) + cut, 1000, 'money vanished between the pot and the payouts')
end)

t.test('a 100 percent house cut pays nobody and hands the house the lot', function()
    local Arena = arenaWith(function(betting) betting.houseCutPercent = 100 end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 500 }, { id = 2, stake = 500 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 0)
    t.equals(cut, 1000)
    t.equals(payoutTotal(payouts) + cut, 1000)
end)

-- ======================================================================
-- ComputePayouts -- top_three
-- ======================================================================

t.test('top_three pays three qualifying finishers by the configured split', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 60, 30, 10 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({
            { id = 1, stake = 250 }, { id = 2, stake = 250 },
            { id = 3, stake = 250 }, { id = 4, stake = 250 },
        }),
        winners = { 1, 2, 3 },
        teams = false,
    })
    t.equals(#payouts, 3)
    t.equals(amountFor(payouts, 1), 600)
    t.equals(amountFor(payouts, 2), 300)
    t.equals(amountFor(payouts, 3), 100)
    t.equals(reasonFor(payouts, 1), 'placement')
    t.equals(payoutTotal(payouts), 1000)
end)

t.test('top_three with only two finishers still pays the whole pot out', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 60, 30, 10 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 500 }, { id = 2, stake = 500 } }),
        winners = { 1, 2 },
        teams = false,
    })
    t.equals(#payouts, 2)
    t.equals(amountFor(payouts, 1), 667)
    t.equals(amountFor(payouts, 2), 333)
    t.equals(payoutTotal(payouts), 1000, 'the third place share must not be left in the pot')
end)

t.test('top_three with a single finisher pays them everything', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 60, 30, 10 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 500 }, { id = 2, stake = 500 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 1)
    t.equals(amountFor(payouts, 1), 1000)
    t.equals(payoutTotal(payouts), 1000)
end)

t.test('top_three pays nobody past third place', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 60, 30, 10 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({
            { id = 1, stake = 200 }, { id = 2, stake = 200 }, { id = 3, stake = 200 },
            { id = 4, stake = 200 }, { id = 5, stake = 200 },
        }),
        winners = { 1, 2, 3, 4, 5 },
        teams = false,
    })
    t.equals(#payouts, 3)
    t.isNil(amountFor(payouts, 4), 'fourth place is not paid')
    t.equals(payoutTotal(payouts), 1000)
end)

t.test('top_three with a short split list pays the remaining place nothing, not a share', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 70, 30 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 400 }, { id = 2, stake = 300 }, { id = 3, stake = 300 } }),
        winners = { 1, 2, 3 },
        teams = false,
    })
    t.equals(amountFor(payouts, 1), 700)
    t.equals(amountFor(payouts, 2), 300)
    t.equals(amountFor(payouts, 3), 0)
    t.equals(payoutTotal(payouts), 1000)
end)

t.test('top_three in a team match falls back to splitting across the winning team', function()
    -- Placement is a free-for-all idea. A team win has no second place, so
    -- the split would be paying three members of one side by finishing
    -- order they never had.
    local Arena = arenaWith(function(betting)
        betting.payout = 'top_three'
        betting.topThreeSplit = { 60, 30, 10 }
    end)
    local payouts = Arena.ComputePayouts({
        pot = 900,
        players = playersOf({
            { id = 1, team = 'crimson', stake = 300 }, { id = 2, team = 'crimson', stake = 300 },
            { id = 3, team = 'ash', stake = 300 },
        }),
        winners = { 1, 2 },
        teams = true,
    })
    t.equals(reasonFor(payouts, 1), 'winner')
    t.equals(amountFor(payouts, 1), 450)
    t.equals(amountFor(payouts, 2), 450)
    t.equals(payoutTotal(payouts), 900)
end)

-- ======================================================================
-- ComputePayouts -- per_kill
-- ======================================================================

t.test('per_kill pays by share of the total kills', function()
    local Arena = arenaWith(function(betting) betting.payout = 'per_kill' end)
    local payouts = Arena.ComputePayouts({
        pot = 100,
        players = playersOf({
            { id = 1, kills = 3, stake = 40 },
            { id = 2, kills = 1, stake = 30 },
            { id = 3, kills = 0, stake = 30 },
        }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 2)
    t.equals(amountFor(payouts, 1), 75)
    t.equals(amountFor(payouts, 2), 25)
    t.isNil(amountFor(payouts, 3), 'a player with no kills is not paid in per_kill')
    t.equals(reasonFor(payouts, 1), 'per_kill')
    t.equals(payoutTotal(payouts), 100)
end)

t.test('per_kill pays the loser of a match they scored in', function()
    -- The winner list only decides whether the match pays out at all. In
    -- per_kill it does not decide who is paid, which is the whole point of
    -- the mode.
    local Arena = arenaWith(function(betting) betting.payout = 'per_kill' end)
    local payouts = Arena.ComputePayouts({
        pot = 100,
        players = playersOf({ { id = 1, kills = 1, stake = 50 }, { id = 2, kills = 1, stake = 50 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(amountFor(payouts, 2), 50)
    t.equals(payoutTotal(payouts), 100)
end)

t.test('per_kill spreads an indivisible pot without dropping a dollar', function()
    local Arena = arenaWith(function(betting) betting.payout = 'per_kill' end)
    local payouts = Arena.ComputePayouts({
        pot = 10,
        players = playersOf({
            { id = 1, kills = 1, stake = 4 },
            { id = 2, kills = 1, stake = 3 },
            { id = 3, kills = 1, stake = 3 },
        }),
        winners = { 1 },
        teams = false,
    })
    t.equals(amountFor(payouts, 1), 4)
    t.equals(amountFor(payouts, 2), 3)
    t.equals(amountFor(payouts, 3), 3)
    t.equals(payoutTotal(payouts), 10)
end)

t.test('per_kill refunds when nobody got a kill instead of dividing by zero', function()
    local Arena = arenaWith(function(betting)
        betting.payout = 'per_kill'
        betting.houseCutPercent = 25
    end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 1500,
        players = playersOf({
            { id = 1, kills = 0, stake = 100 },
            { id = 2, kills = 0, stake = 400 },
            { id = 3, kills = 0, stake = 1000 },
        }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 3)
    t.equals(amountFor(payouts, 1), 100)
    t.equals(amountFor(payouts, 2), 400)
    t.equals(amountFor(payouts, 3), 1000)
    t.equals(reasonFor(payouts, 1), 'refund_no_kills')
    t.equals(cut, 0, 'a refund is not a payout -- the house takes nothing from it')
    t.equals(payoutTotal(payouts), 1500)
end)

-- ======================================================================
-- ComputePayouts -- the refund paths
--
-- Stakes differ in every one of these. With equal stakes an "even share of
-- the pot" bug and a correct "own stake back" both produce the same
-- numbers, so an equal-stake refund test proves nothing.
-- ======================================================================

t.test('a match below minPlayersToPayOut refunds each player their own stake', function()
    local Arena = arenaWith(function(betting) betting.minPlayersToPayOut = 3 end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 1000,
        players = playersOf({ { id = 1, stake = 100 }, { id = 2, stake = 900 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 2)
    -- An even share would have paid both of them 500.
    t.equals(amountFor(payouts, 1), 100)
    t.equals(amountFor(payouts, 2), 900)
    t.equals(reasonFor(payouts, 1), 'refund_too_few')
    t.equals(cut, 0)
    t.equals(payoutTotal(payouts), 1000, 'the refund did not add up to the pot')
end)

t.test('a match with no winner at all refunds each player their own stake', function()
    local Arena = arenaWith()
    local payouts, cut = Arena.ComputePayouts({
        pot = 1500,
        players = playersOf({
            { id = 1, stake = 100 }, { id = 2, stake = 400 }, { id = 3, stake = 1000 },
        }),
        winners = {},
        teams = false,
    })
    t.equals(#payouts, 3)
    t.equals(amountFor(payouts, 1), 100)
    t.equals(amountFor(payouts, 2), 400)
    t.equals(amountFor(payouts, 3), 1000)
    t.equals(reasonFor(payouts, 3), 'refund_no_winner')
    t.equals(cut, 0)
    t.equals(payoutTotal(payouts), 1500)
end)

t.test('a refund is not reduced by the house cut', function()
    -- The house is paid for running a match that paid out. A refunded match
    -- did not, so taking a cut here would charge players for a round that
    -- never resolved.
    local Arena = arenaWith(function(betting) betting.houseCutPercent = 40 end)
    local payouts, cut = Arena.ComputePayouts({
        pot = 700,
        players = playersOf({ { id = 1, stake = 200 }, { id = 2, stake = 500 } }),
        winners = {},
        teams = false,
    })
    t.equals(cut, 0)
    t.equals(amountFor(payouts, 1), 200)
    t.equals(amountFor(payouts, 2), 500)
    t.equals(payoutTotal(payouts), 700)
end)

t.test('a refund gives a player who staked nothing no payout row', function()
    local Arena = arenaWith()
    local payouts = Arena.ComputePayouts({
        pot = 500,
        players = playersOf({ { id = 1, stake = 0 }, { id = 2, stake = 100 }, { id = 3, stake = 400 } }),
        winners = {},
        teams = false,
    })
    t.equals(#payouts, 2, 'a free entrant must not be handed somebody else money')
    t.isNil(amountFor(payouts, 1))
    t.equals(payoutTotal(payouts), 500)
end)

t.test('an empty pot pays and refunds nothing at all', function()
    local Arena = arenaWith()
    local payouts, cut = Arena.ComputePayouts({
        pot = 0,
        players = playersOf({ { id = 1, stake = 0 }, { id = 2, stake = 0 } }),
        winners = { 1 },
        teams = false,
    })
    t.equals(#payouts, 0)
    t.equals(cut, 0)
end)

t.test('ComputePayouts survives an empty context', function()
    local Arena = arenaWith()
    local payouts, cut = Arena.ComputePayouts({})
    t.equals(#payouts, 0)
    t.equals(cut, 0)

    local nilPayouts, nilCut = Arena.ComputePayouts(nil)
    t.equals(#nilPayouts, 0)
    t.equals(nilCut, 0)
end)

t.test('every payout mode conserves the pot across cuts and pot sizes', function()
    local modes = { 'winner_takes_all', 'top_three', 'per_kill', 'nonsense' }
    local percents = { 0, 1, 33, 99, 100 }
    for _, mode in ipairs(modes) do
        for _, percent in ipairs(percents) do
            local Arena = arenaWith(function(betting)
                betting.payout = mode
                betting.houseCutPercent = percent
            end)
            for _, pot in ipairs({ 1, 7, 100, 999, 12345 }) do
                local payouts, cut = Arena.ComputePayouts({
                    pot = pot,
                    players = playersOf({
                        { id = 1, kills = 3, stake = 1 },
                        { id = 2, kills = 2, stake = 1 },
                        { id = 3, kills = 1, stake = 1 },
                    }),
                    winners = { 1, 2, 3 },
                    teams = false,
                })
                local case = ('%s at %d%% of %d'):format(mode, percent, pot)
                t.equals(payoutTotal(payouts) + cut, pot, case .. ': the pot leaked')
                for _, payout in ipairs(payouts) do
                    t.equals(math.type(payout.amount), 'integer', case .. ': a share is not an integer')
                    t.isTrue(payout.amount >= 0, case .. ': a negative payout')
                end
            end
        end
    end
end)

-- ======================================================================
-- ResolveEntryFee
-- ======================================================================

t.test('ResolveEntryFee accepts an amount inside the configured band', function()
    local amount, reason = arenaWith().ResolveEntryFee(2500)
    t.equals(amount, 2500)
    t.isNil(reason)
end)

t.test('ResolveEntryFee accepts both ends of the band', function()
    local Arena = arenaWith(function(betting)
        betting.entryFee.min = 500
        betting.entryFee.max = 5000
    end)
    t.equals((Arena.ResolveEntryFee(500)), 500)
    t.equals((Arena.ResolveEntryFee(5000)), 5000)
end)

t.test('ResolveEntryFee rejects an amount below the minimum', function()
    local Arena = arenaWith(function(betting) betting.entryFee.min = 500 end)
    local amount, reason = Arena.ResolveEntryFee(499)
    t.isNil(amount, 'a below-minimum fee must be refused, not raised to the minimum')
    t.equals(reason, 'error.bet_out_of_range')
end)

t.test('ResolveEntryFee rejects a negative amount against the shipped zero minimum', function()
    local amount, reason = arenaWith().ResolveEntryFee(-1)
    t.isNil(amount)
    t.equals(reason, 'error.bet_out_of_range')
end)

t.test('ResolveEntryFee rejects an amount above the maximum', function()
    local amount, reason = arenaWith().ResolveEntryFee(50001)
    t.isNil(amount, 'an over-maximum fee must be refused, not clamped down to it')
    t.equals(reason, 'error.bet_out_of_range')
end)

t.test('ResolveEntryFee falls back to the default for a non-numeric request', function()
    -- Read off config rather than written as 1000: the shipped default is
    -- now 0 -- a match is free unless the host asks for a fee -- and this
    -- test is about the FALLBACK, not about today's number.
    local Arena = arenaWith()
    local fallback = Arena.ResolveEntryFee(nil)
    t.equals((Arena.ResolveEntryFee('all of it')), fallback)
    t.equals((Arena.ResolveEntryFee({ amount = 500 })), fallback)
    t.equals((Arena.ResolveEntryFee(true)), fallback)
    t.equals((Arena.ResolveEntryFee(math.huge)), fallback)
    t.equals((Arena.ResolveEntryFee(0 / 0)), fallback)

    -- And the fallback is not vacuously whatever came back: it is the
    -- operator's configured default, which now ships at 0.
    t.equals(fallback, 0, 'the shipped entry fee is no longer free by default')
end)

t.test('ResolveEntryFee falls back to the default when nothing was requested', function()
    local amount, reason = arenaWith().ResolveEntryFee(nil)
    t.equals(amount, 0, 'a host who never touches the fee field should open a free match')
    t.isNil(reason)
end)

t.test('ResolveEntryFee clamps a default that sits outside its own band', function()
    local Arena = arenaWith(function(betting)
        betting.entryFee.min = 1000
        betting.entryFee.max = 5000
        betting.entryFee.default = 100
    end)
    t.equals((Arena.ResolveEntryFee(nil)), 1000)
end)

t.test('ResolveEntryFee reads a numeric string off the wire as a number', function()
    -- JSON from the panel arrives with the amount as whatever the input
    -- element produced, so a stringly typed number is a normal request and
    -- not an attack.
    t.equals((arenaWith().ResolveEntryFee('2500')), 2500)
end)

t.test('ResolveEntryFee floors a fractional amount into integer money', function()
    t.equals((arenaWith().ResolveEntryFee(1000.9)), 1000)
end)

t.test('ResolveEntryFee returns a free entry when entry fees are switched off', function()
    local Arena = arenaWith(function(betting) betting.entryFee.enabled = false end)
    local amount, reason = Arena.ResolveEntryFee(5000)
    t.equals(amount, 0, 'entry fees off means free to enter, not rejected')
    t.isNil(reason)
end)

t.test('ResolveEntryFee refuses everything when betting is switched off', function()
    local Arena = arenaWith(function(betting) betting.enabled = false end)
    local amount, reason = Arena.ResolveEntryFee(1000)
    t.isNil(amount, 'betting off must reject the bet, not stake zero')
    t.equals(reason, 'error.betting_disabled')

    local defaulted, defaultReason = Arena.ResolveEntryFee(nil)
    t.isNil(defaulted)
    t.equals(defaultReason, 'error.betting_disabled')
end)

-- ======================================================================
-- ResolveSpectatorBet
-- ======================================================================

t.test('DEFECT: a fighter\'s stake is held to the FIGHTER band, not the spectator one', function()
    -- config.lua gives fighterBets its own min and max, the snapshot sends
    -- both blocks to the panel, and the panel offers a fighter the fighter
    -- band. The server checked the spectator one.
    --
    -- Shipped, that is 50,000 offered and 25,000 accepted: every stake in
    -- between refused, with "that amount is outside the limits", to a player
    -- looking at an input that let them type it.
    local Arena = arenaWith(function(betting)
        betting.fighterBets.min = 100
        betting.fighterBets.max = 50000
        betting.spectatorBets.min = 100
        betting.spectatorBets.max = 25000
    end)

    t.equals((Arena.ResolveFighterBet(50000)), 50000,
        'a fighter cannot stake the maximum their own band allows')
    t.equals((Arena.ResolveFighterBet(25001)), 25001,
        'a fighter was held to the spectator ceiling')

    -- And the spectator band still means what it says.
    local refused, reason = Arena.ResolveSpectatorBet(25001)
    t.equals(refused, nil, 'a spectator got past their own ceiling')
    t.equals(reason, 'error.bet_out_of_range')
end)

t.test('and the two bands are independent in both directions', function()
    -- The mirror, so this cannot be "fixed" by making fighters use the wider
    -- of the two.
    local Arena = arenaWith(function(betting)
        betting.fighterBets.min = 500
        betting.fighterBets.max = 1000
        betting.spectatorBets.min = 100
        betting.spectatorBets.max = 25000
    end)

    t.equals((Arena.ResolveFighterBet(1001)), nil, 'a fighter got past a ceiling BELOW the spectator one')
    t.equals((Arena.ResolveFighterBet(499)), nil, 'a fighter got under a floor ABOVE the spectator one')
    t.equals((Arena.ResolveSpectatorBet(20000)), 20000, 'the spectator band was narrowed by the fighter one')
end)

t.test('DEFECT: fighter bets work with spectator bets switched off', function()
    -- A combination config documents by giving fighterBets its own `enabled`
    -- flag. Reading the spectator switch refused every fighter bet on it,
    -- with a message about side-bets being off -- so an operator who wanted
    -- fighters backing themselves and nobody else betting had a feature that
    -- silently did nothing.
    local Arena = arenaWith(function(betting)
        betting.spectatorBets.enabled = false
        betting.fighterBets.enabled = true
    end)

    t.equals((Arena.ResolveFighterBet(1000)), 1000,
        'a fighter bet was refused because SPECTATOR bets are off')

    local refused, reason = Arena.ResolveSpectatorBet(1000)
    t.equals(refused, nil, 'spectator bets ran while switched off')
    t.equals(reason, 'error.spectator_bets_disabled')
end)

t.test('and the other way round, a fighter bet can be switched off on its own', function()
    local Arena = arenaWith(function(betting)
        betting.spectatorBets.enabled = true
        betting.fighterBets.enabled = false
    end)

    local refused, reason = Arena.ResolveFighterBet(1000)
    t.equals(refused, nil, 'a fighter bet ran while switched off')
    t.equals(reason, 'error.fighter_bets_disabled')
    t.equals((Arena.ResolveSpectatorBet(1000)), 1000, 'spectator bets were switched off with them')
end)

t.test('and both refuse everything when betting itself is off', function()
    local Arena = arenaWith(function(betting) betting.enabled = false end)
    local a, aReason = Arena.ResolveFighterBet(1000)
    local b, bReason = Arena.ResolveSpectatorBet(1000)
    t.equals(a, nil)
    t.equals(aReason, 'error.betting_disabled')
    t.equals(b, nil)
    t.equals(bReason, 'error.betting_disabled')
end)

t.test('ResolveSpectatorBet accepts an amount inside the configured band', function()
    local amount, reason = arenaWith().ResolveSpectatorBet(500)
    t.equals(amount, 500)
    t.isNil(reason)
end)

t.test('ResolveSpectatorBet accepts both ends of the band', function()
    local Arena = arenaWith()
    t.equals((Arena.ResolveSpectatorBet(100)), 100)
    t.equals((Arena.ResolveSpectatorBet(25000)), 25000)
end)

t.test('ResolveSpectatorBet rejects an amount outside the band', function()
    local Arena = arenaWith()
    local low, lowReason = Arena.ResolveSpectatorBet(99)
    t.isNil(low)
    t.equals(lowReason, 'error.bet_out_of_range')

    local high, highReason = Arena.ResolveSpectatorBet(25001)
    t.isNil(high)
    t.equals(highReason, 'error.bet_out_of_range')
end)

t.test('ResolveSpectatorBet has no default -- a non-numeric bet is invalid', function()
    -- Unlike an entry fee, a side-bet nobody named an amount for cannot be
    -- guessed: staking a default of somebody else money is worse than
    -- refusing.
    local Arena = arenaWith()
    for _, request in ipairs({ 'a grand', {}, true }) do
        local amount, reason = Arena.ResolveSpectatorBet(request)
        t.isNil(amount)
        t.equals(reason, 'error.bet_invalid')
    end

    local nilAmount, nilReason = Arena.ResolveSpectatorBet(nil)
    t.isNil(nilAmount)
    t.equals(nilReason, 'error.bet_invalid')

    local nanAmount, nanReason = Arena.ResolveSpectatorBet(0 / 0)
    t.isNil(nanAmount)
    t.equals(nanReason, 'error.bet_invalid')
end)

t.test('ResolveSpectatorBet floors a fractional amount into integer money', function()
    t.equals((arenaWith().ResolveSpectatorBet(250.9)), 250)
end)

t.test('ResolveSpectatorBet refuses everything when side-bets are switched off', function()
    local Arena = arenaWith(function(betting) betting.spectatorBets.enabled = false end)
    local amount, reason = Arena.ResolveSpectatorBet(500)
    t.isNil(amount)
    t.equals(reason, 'error.spectator_bets_disabled')
end)

t.test('ResolveSpectatorBet reports betting off ahead of side-bets off', function()
    -- Both are true here; the player should be told the switch that
    -- actually stopped them.
    local Arena = arenaWith(function(betting)
        betting.enabled = false
        betting.spectatorBets.enabled = false
    end)
    local amount, reason = Arena.ResolveSpectatorBet(500)
    t.isNil(amount)
    t.equals(reason, 'error.betting_disabled')
end)

-- ======================================================================
-- ComputeSpectatorPayout
-- ======================================================================

t.test('ComputeSpectatorPayout returns stake times the shipped multiplier', function()
    local paid = arenaWith().ComputeSpectatorPayout(500)
    t.equals(paid, 1000, 'the shipped 2.0 multiplier pays the stake back plus the same again')
    t.equals(math.type(paid), 'integer')
end)

t.test('ComputeSpectatorPayout at a multiplier of 1 is break-even', function()
    -- The return includes the stake, so 1.0 is the no-win-no-loss line and
    -- anything under it pays a winner back less than they put in.
    local Arena = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = 1.0 end)
    t.equals(Arena.ComputeSpectatorPayout(750), 750)
end)

t.test('ComputeSpectatorPayout floors a fractional multiplier', function()
    local Arena = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = 1.5 end)
    t.equals(Arena.ComputeSpectatorPayout(333), 499)
    t.equals(math.type(Arena.ComputeSpectatorPayout(333)), 'integer')

    local half = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = 0.5 end)
    t.equals(half.ComputeSpectatorPayout(101), 50)
end)

t.test('ComputeSpectatorPayout at a multiplier of 0 pays nothing', function()
    local Arena = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = 0 end)
    t.equals(Arena.ComputeSpectatorPayout(5000), 0)
end)

t.test('ComputeSpectatorPayout pays nothing on a negative multiplier', function()
    local Arena = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = -2 end)
    t.equals(Arena.ComputeSpectatorPayout(5000), 0, 'a negative multiplier must not become a charge')
end)

t.test('ComputeSpectatorPayout falls back to 2.0 for a missing or non-numeric multiplier', function()
    local missing = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = nil end)
    t.equals(missing.ComputeSpectatorPayout(500), 1000)

    local junk = arenaWith(function(betting) betting.spectatorBets.oddsMultiplier = 'double' end)
    t.equals(junk.ComputeSpectatorPayout(500), 1000)
end)

t.test('ComputeSpectatorPayout pays nothing on a negative or non-numeric stake', function()
    local Arena = arenaWith()
    t.equals(Arena.ComputeSpectatorPayout(-500), 0)
    t.equals(Arena.ComputeSpectatorPayout('500'), 1000, 'a numeric string off the wire is still a stake')
    t.equals(Arena.ComputeSpectatorPayout('lots'), 0)
    t.equals(Arena.ComputeSpectatorPayout(nil), 0)
end)

-- ======================================================================
-- REJECTION REASONS
-- ======================================================================

t.test('every rejection reason the betting maths returns is a real locale key', function()
    -- The sandbox locale() raises on a missing key, so this is proof the
    -- player gets a sentence rather than the key itself.
    local seen = {}
    local function record(_, reason)
        if reason then seen[reason] = true end
    end

    record(arenaWith(function(betting) betting.enabled = false end).ResolveEntryFee(1000))
    record(arenaWith().ResolveEntryFee(50001))
    record(arenaWith(function(betting) betting.enabled = false end).ResolveSpectatorBet(500))
    record(arenaWith(function(betting) betting.spectatorBets.enabled = false end).ResolveSpectatorBet(500))
    record(arenaWith().ResolveSpectatorBet(nil))
    record(arenaWith().ResolveSpectatorBet(99))

    local count = 0
    for reason in pairs(seen) do
        count = count + 1
        t.isTrue(#sandbox.locale(reason) > 0, reason .. ' has no text')
    end
    t.equals(count, 4, 'expected four distinct rejection reasons')
end)

os.exit(t.summary())
