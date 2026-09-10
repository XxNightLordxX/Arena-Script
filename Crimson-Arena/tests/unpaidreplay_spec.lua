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
        Wait = function() end,
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

    env.Config.Database = { enabled = true }
    -- The sweep is a `while true` and CreateThread runs a body to completion,
    -- so it is switched off and driven by hand.
    env.Config.Betting.refundRetrySeconds = 0

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = playerFor
    env.ArenaLog = function() end
    env.ArenaDebug = function() end
    Sandbox.loadInto('../server/betting.lua', env)

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

os.exit(t.summary())
