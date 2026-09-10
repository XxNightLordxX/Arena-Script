--[[
    crimson_arena/tests/unpaidoutage_spec.lua

    A DEBT FILED WHILE oxmysql WAS DOWN, AND THE READ THAT CUT IT.

    The ledger is read back at start and the stored total wins, on the premise
    that every memory write was mirrored first. A debt filed during an outage
    was not -- ArenaDb refuses what it cannot send and queues nothing -- so
    the moment oxmysql came back the load ran, the stored total won, and the
    money owed during the outage was gone with no line anywhere. The README
    says the start order does not matter; an operator following it hits this.

    Real server/util.lua + server/betting.lua, oxmysql modelled as a TABLE that
    can be down, a thread runner so the load thread's retry can be stepped.
    THE SEED IS COPIED PER TEST and the player is kept OFFLINE whenever the
    store is read back, because the sweep pays a connected player and deletes
    their row -- a shared seed and an online player made every number lie.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('unpaidoutage_spec')

local KEY = 'cash|match_cancelled'

local function newArena(control)
    control = control or {}
    local stored = {}
    --- The read that has been issued and not yet answered, if this test is
    --- holding one. Released by hand with s.releaseRead().
    local held = nil
    for k, row in pairs(control.seed or {}) do
        local copy = {}
        for f, v in pairs(row) do copy[f] = v end
        stored[k] = copy
    end
    local wallets = { [1] = { cash = 5000, bank = 0 } }
    local threads = Sandbox.newThreadRunner()

    local function query(_self, sql, params, cb)
        local flat = sql:gsub('%s+', ' ')
        if flat:find('CREATE TABLE') then if cb then cb({}) end return end
        if flat:find('^SELECT') then
            -- A PHOTOGRAPH, TAKEN NOW AND DELIVERED LATER. oxmysql is async:
            -- the rows a read answers with are the rows that existed when it
            -- was ISSUED, and anything that happens to the ledger while it is
            -- in flight is not in them. Modelled synchronously, that window
            -- does not exist and the guard against it cannot be reached.
            local rows = {}
            for _, row in pairs(stored) do
                local copy = {}
                for f, v in pairs(row) do copy[f] = v end
                rows[#rows + 1] = copy
            end
            -- EVERY read is held while a test is holding one, not just the
            -- first: the load thread retries until it is answered, so
            -- delivering the second read would close the window the first one
            -- opened and the test would prove nothing.
            if control.holdSelect then
                if held == nil then held = function() if cb then cb(rows) end end end
                return
            end
            if cb then cb(rows) end
            return
        end
        if flat:find('^DELETE') then
            stored[params[1] .. '|' .. params[2]] = nil
            if cb then cb({ affectedRows = 1 }) end
            return
        end
        local key = params[1] .. '|' .. params[2]
        local have = stored[key]
        stored[key] = { citizenid = params[1], ledger_key = params[2], name = params[3],
            account = params[4], reason = params[5], amount = (have and have.amount or 0) + params[6] }
        if cb then cb({ affectedRows = 1 }) end
    end

    local function playerFor(src)
        if control.offline then return nil end
        local purse = wallets[src]
        if not purse then return nil end
        return {
            PlayerData = { citizenid = 'CID' .. tostring(src), money = purse },
            Functions = {
                AddMoney = function(account, amount) purse[account] = (purse[account] or 0) + amount return true end,
                RemoveMoney = function(account, amount)
                    if (purse[account] or 0) < amount then return false end
                    purse[account] = purse[account] - amount return true
                end,
            },
        }
    end

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ oxmysql = { query = query } }, { __call = function() end }),
        GetResourceState = function(name)
            if name == 'oxmysql' then return control.down and 'missing' or 'started' end
            return 'missing'
        end,
        GetPlayers = function() return { '1' } end,
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        AddEventHandler = function() end, RegisterNetEvent = function() end, RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = Sandbox.newOxLib(), print = function() end,
        ArenaGetPlayer = playerFor, ArenaLog = function() end, ArenaDebug = function() end,
        ArenaNotifyKey = function() end, ArenaToastKey = function() end,
        ArenaPlayerName = function(src) return 'P' .. tostring(src) end,
    })
    env.Config.Database = { enabled = true }
    env.Config.Betting.refundRetrySeconds = 0

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = playerFor; env.ArenaLog = function() end; env.ArenaDebug = function() end
    Sandbox.loadInto('../server/betting.lua', env)

    return {
        betting = env.ArenaBetting, control = control,
        step = function(n) for _ = 1, (n or 1) do threads.step() end end,
        owed = function() local _, total = env.ArenaBetting.Outstanding() return total end,
        storedAmount = function() local r = stored['CID1|' .. KEY] return r and r.amount or 0 end,
        --- Deliver the read that has been in flight since the load began.
        releaseRead = function()
            local deliver = held
            held = nil
            if deliver then deliver() end
            return deliver ~= nil
        end,
        wallet = function() return wallets[1].cash end,
    }
end

local SEED = { ['CID1|' .. KEY] = { citizenid = 'CID1', ledger_key = KEY, name = 'P1',
    account = 'cash', reason = 'match_cancelled', amount = 300 } }

--- Files a 700 debt for CID1 by refunding a stake while they are away.
local function fileDebt(s)
    s.betting.TakeStake(1, 'm1', 700, 'cash')
    s.control.offline = true
    s.betting.RefundAll('m1', 'match_cancelled')
    s.control.offline = false
end

t.test('CONTROL: with the database up throughout, an old row and a new debt add up', function()
    local s = newArena({ seed = SEED })
    s.step(3)
    fileDebt(s)
    s.step(3)
    t.equals(s.owed(), 1000, 'the stored 300 and the new 700 did not add up')
    t.equals(s.storedAmount(), 1000, 'the ADD did not reach the store')
end)

t.test('DEFECT: a debt filed while oxmysql was down was cut to the stored total on the next read', function()
    local s = newArena({ seed = SEED, down = true })
    s.step(3)
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed in memory, so this proves nothing')
    t.equals(s.storedAmount(), 300, 'the ADD reached a database that was down, so this proves nothing')

    s.control.down = false
    s.step(6)

    t.equals(s.owed(), 1000,
        'the read let the stored total overwrite the debt filed during the outage')
end)

t.test('and the missing ADD reaches the store on the next sweep, once', function()
    local s = newArena({ seed = SEED, down = true })
    s.step(3)
    fileDebt(s)
    s.control.down = false
    s.step(6)

    s.control.offline = true            -- nobody to pay, so the row is not settled and deleted
    s.betting.SweepUnpaid()
    t.equals(s.storedAmount(), 1000, 'the store never heard about the debt filed during the outage')
    s.betting.SweepUnpaid()
    t.equals(s.storedAmount(), 1000, 'the replayed ADD was sent twice and counted the money twice')
end)

t.test('CONTROL: an ADD the database DID take is not replayed', function()
    local s = newArena({ seed = SEED })
    s.step(3)
    fileDebt(s)
    s.step(3)
    s.control.offline = true
    s.betting.SweepUnpaid()
    t.equals(s.storedAmount(), 1000, 'a debt the store already held was added again by a replay')
end)

t.test('DEFECT: a debt PAID while the ledger read was in flight is not brought back by it', function()
    -- THE PHOTOGRAPH THAT ARRIVES AFTER THE MONEY. The load's SELECT is
    -- issued at start and answers whenever oxmysql gets round to it. In
    -- between, a debt can be filed, the player can walk in, and the sweep can
    -- pay them -- and the row that read is still carrying says they are owed
    -- it. Merging that row reinstates a debt the arena has already handed
    -- over, and the next sweep pays it a second time.
    --
    -- The guard is one line in loadUnpaid: a part whose DROP has not reached
    -- the database yet is read back as zero. Inverting it left the suite
    -- green, because nothing here could hold a read open -- the fixture's
    -- database answered on the spot, so the window did not exist.
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    t.equals(s.owed(), 0, 'the read answered anyway, so there is no window and this proves nothing')

    -- A debt of 700 is filed in memory while that read is still out.
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed, so this proves nothing')

    -- The database goes away, so the DROP that follows the payment cannot
    -- land and stays queued. Then the player walks in and is paid.
    s.control.down = true
    local before = s.wallet()
    s.betting.SweepUnpaid()
    t.equals(s.owed(), 0, 'the sweep did not settle the debt, so this proves nothing')
    t.equals(s.wallet(), before + 700, 'the player was not actually paid, so this proves nothing')

    -- And now the read lands, carrying a row from before any of that.
    s.control.down = false
    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 0,
        'A DEBT THE ARENA HAD ALREADY PAID WAS BROUGHT BACK by a read taken before the payment')

    -- And the proof that it matters: the next sweep pays nothing more.
    s.betting.SweepUnpaid()
    t.equals(s.wallet(), before + 700, 'they were paid the same debt twice')
end)

os.exit(t.summary())
