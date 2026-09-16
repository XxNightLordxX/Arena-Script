--[[
    crimson_arena/tests/unpaidreplay_spec.lua

    THE DELETE THAT PAYS A DEBT TWICE.

    ArenaDb throws a statement away when it cannot send it -- there is no queue
    behind it. For almost everything on this ledger that is survivable: a lost
    INSERT means the arena forgets money it owes, which costs the player and is
    said out loud.

    THE DELETE IS THE OTHER WAY ROUND, and it costs the OWNER. PayOutstanding
    credits the player and then drops the row. If that drop evaporates, the
    money has been handed over and the row is still in the table -- so the next
    start reads it back as an open debt and SweepUnpaid pays it a second time,
    for as many restarts as it takes.

    The outstanding-kit slate in server/ammo.lua was given a replay for exactly
    this; the betting ledger never got one. This file is the proof it now has.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('unpaidreplay_spec')

--- The real server/betting.lua with oxmysql modelled as a TABLE, so "the row
--- is still in the database" is a fact this file can check rather than infer.
---
---   control.failWrites -- oxmysql takes the statement and answers nil, the
---                         way it does through an outage
---   control.offline    -- ArenaGetPlayer answers nil, so a credit fails and
---                         the money becomes a debt
local function newArena(control)
    control = control or {}
    local waits = 0

    local stored = {}
    local wallets = { [1] = { cash = 500, bank = 0 } }

    local function query(_self, sql, params, cb)
        local flat = sql:gsub('%s+', ' ')

        if flat:find('CREATE TABLE') then
            if cb then cb({}) end
            return
        end

        if flat:find('^SELECT') then
            local rows = {}
            for _, row in pairs(stored) do rows[#rows + 1] = row end
            if cb then cb(rows) end
            return
        end

        -- THE OUTAGE. The statement is taken and NOT applied, and the answer
        -- is nil -- which is exactly what a dropped write looks like.
        if control.failWrites then
            if cb then cb(nil) end
            return
        end

        if flat:find('^DELETE') then
            stored[params[1] .. '|' .. params[2]] = nil
            if cb then cb({ affectedRows = 1 }) end
            return
        end

        local key = params[1] .. '|' .. params[2]
        local have = stored[key]
        stored[key] = {
            citizenid = params[1], ledger_key = params[2], name = params[3],
            account = params[4], reason = params[5],
            amount = (have and have.amount or 0) + params[6],
        }
        if cb then cb({ affectedRows = 1 }) end
    end

    local function playerFor(src)
        if control.offline then return nil end
        local purse = wallets[src]
        if not purse then return nil end
        return {
            PlayerData = { citizenid = 'CID' .. tostring(src), money = purse },
            Functions = {
                AddMoney = function(account, amount)
                    purse[account] = (purse[account] or 0) + amount
                    return true
                end,
                RemoveMoney = function(account, amount)
                    if (purse[account] or 0) < amount then return false end
                    purse[account] = purse[account] - amount
                    return true
                end,
            },
        }
    end

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ oxmysql = { query = query } },
            { __call = function() end }),
        GetResourceState = function(name)
            return name == 'oxmysql' and 'started' or 'missing'
        end,
        GetPlayers = function() return { '1' } end,
        -- A BOUNDED Wait, BECAUSE THE ALTERNATIVE IS A HANG.
        --
        -- CreateThread here runs the body to completion and Wait does
        -- nothing, so any `while true do ... Wait(n) end` in the resource
        -- spins forever instead of yielding. betting.lua has exactly that:
        -- the loop that retries reading the money slate until it lands. With
        -- the database reachable it lands on the first pass and returns; with
        -- the database OFF it never does, and loading the file never
        -- returns. That cost a debugging session, and a hang is the worst
        -- failure a suite can give you -- no output, no name, no line.
        Wait = function()
            waits = waits + 1
            if waits > 10000 then
                error('Wait called 10000 times -- a `while true` loop in the resource is spinning '
                    .. 'because this fixture never yields. Load with the database reachable, or '
                    .. 'drive that loop by hand.', 2)
            end
        end,
        CreateThread = function(fn) fn() end,
        SetTimeout = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = Sandbox.newOxLib(),
        print = function() end,
        ArenaGetPlayer = playerFor,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        ArenaNotifyKey = function() end,
        ArenaToastKey = function() end,
        ArenaPlayerName = function(src) return 'P' .. tostring(src) end,
    })

    -- `not control.databaseOff`, NOT `control.databaseOff and false or true`.
    -- That idiom is a trap in Lua and it bit here: `true and false` is
    -- false, and `false or true` is true, so the switch was stuck ON and the
    -- database-off test silently ran with the database on.
    env.Config.Database = { enabled = not control.databaseOff }
    -- The sweep is a `while true` and CreateThread runs a body to completion,
    -- so it is switched off and driven by hand.
    env.Config.Betting.refundRetrySeconds = 0

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaGetPlayer = playerFor
    local console = {}
    env.ArenaLog = function(fmt, ...)
        local ok, text = pcall(string.format, fmt, ...)
        console[#console + 1] = ok and text or tostring(fmt)
    end
    env.ArenaDebug = function() end
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)

    return {
        env = env,
        betting = env.ArenaBetting,
        control = control,
        wallets = wallets,
        rows = function()
            local n = 0
            for _ in pairs(stored) do n = n + 1 end
            return n
        end,
        cash = function(src) return wallets[src].cash end,
        log = function() return table.concat(console, '\n') end,
    }
end

--- Takes a stake, then refunds it while the player is away, so the money
--- becomes a recorded debt with a row behind it.
local function debtOf(s)
    s.betting.TakeStake(1, 'm1', 100, 'cash')
    s.control.offline = true
    s.betting.RefundAll('m1', 'match_cancelled')
    s.control.offline = false
end

t.test('CONTROL: an ordinary payout drops its row', function()
    local s = newArena()
    debtOf(s)
    t.equals(s.rows(), 1, 'the debt was never written down, so this proves nothing')

    s.betting.PayOutstanding(1)

    t.equals(s.rows(), 0, 'the row outlived a payout that went through cleanly')
end)

t.test('DEFECT: a drop lost to an outage leaves the row behind to be paid again', function()
    local s = newArena()
    debtOf(s)
    local before = s.cash(1)

    -- The database goes away in the window between crediting and dropping.
    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.control.failWrites = false

    t.equals(s.cash(1), before + 100, 'the player was not actually paid, so this proves nothing')
    t.equals(s.rows(), 1, 'the row should still be there -- that is the outage being modelled')

    -- The database comes back. Nothing else happens: no new debt, no new
    -- payout, just the sweep that already runs on a timer.
    s.betting.SweepUnpaid()

    t.equals(s.rows(), 0,
        'the settled row is STILL in the table -- the next restart reads it back and pays it again')
end)

t.test('and the sweep replays even when nothing is owed in memory any more', function()
    -- The state the replay exists for, and the one an early return hides:
    -- every part paid, `unpaid` empty, and a row still in the table.
    local s = newArena()
    debtOf(s)

    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.control.failWrites = false

    t.equals(s.betting.Outstanding(), 0, 'memory still owes something, so this is not that state')

    s.betting.SweepUnpaid()

    t.equals(s.rows(), 0, 'the sweep returned early because nothing was owed, and left the row')
end)

t.test('a late read does not reinstate a debt whose drop is still in flight', function()
    local s = newArena()
    debtOf(s)

    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.control.failWrites = false

    -- The row is settled in memory but still in the table. A read landing now
    -- is a photograph taken before the payment.
    t.equals(s.betting.Outstanding(), 0,
        'the payment did not settle in memory, so the merge is not being tested')
end)

-- ========================================================================
-- AND THE PROMISE HAS TO SAY WHETHER IT OUTLIVES A RESTART
-- ========================================================================
--
-- When a refund cannot be delivered the console says the money "will be paid
-- when they are next seen". That is true for the length of one uptime
-- whatever the database is doing, because `owe` records the debt in memory
-- FIRST and cannot be stopped by a database that is off -- which is the
-- right order and is not what these tests are about.
--
-- What they are about is that on the SHIPPED config Config.Database.enabled
-- is FALSE, so nothing is mirrored and a restart forgets the debt entirely
-- -- and the sentence read exactly the same either way. The kit slate has
-- had ArenaAmmo.OwedKitIsSaved on the admin screen for a long time; the
-- slate holding actual cash had no equivalent at all.

t.test('CONTROL: with the database on and read back, the slate reports itself saved', function()
    local s = newArena()
    s.betting.SweepUnpaid()
    t.isTrue(s.betting.UnpaidIsSaved(),
        'a working database reports the money slate as unsaved, so the warning would never stop')
end)

t.test('and the deferred-refund line carries no warning in that case', function()
    local s = newArena()
    s.betting.SweepUnpaid()
    debtOf(s)

    t.contains(s.log(), 'REFUND DEFERRED', 'no refund was deferred, so this proves nothing')
    t.notContains(s.log(), 'MEMORY ONLY',
        'a server whose slate IS saved was warned that it is not')
end)

t.test('THE DEFECT: with the database off, the same line says the debt dies at the restart', function()
    -- SWITCHED OFF AFTER THE LOAD, not before it. betting.lua retries
    -- reading the slate in a `while true` loop until it lands, and this
    -- fixture's CreateThread runs a body to completion without yielding --
    -- so loading the file with the database already off never returns. What
    -- is being tested is the same either way: whether the console tells an
    -- operator that this debt does not survive a restart.
    local s = newArena()
    s.env.Config.Database.enabled = false
    debtOf(s)

    t.contains(s.log(), 'REFUND DEFERRED', 'no refund was deferred, so this proves nothing')
    t.contains(s.log(), 'MEMORY ONLY',
        'the console promised the money would be paid and said nothing about the restart that forgets it')
end)

t.test('and the slate says so when asked directly', function()
    local s = newArena()
    s.env.Config.Database.enabled = false
    t.isFalse(s.betting.UnpaidIsSaved(),
        'the money slate claims to be saved on a server with no database at all')
end)

os.exit(t.summary())
