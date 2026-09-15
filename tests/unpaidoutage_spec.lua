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

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaGetPlayer = playerFor; env.ArenaLog = function() end; env.ArenaDebug = function() end
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)

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
        --- A copy of the whole stored table, to seed a "restart" with.
        snapshot = function()
            local out = {}
            for k, row in pairs(stored) do
                local copy = {}
                for f, v in pairs(row) do copy[f] = v end
                out[k] = copy
            end
            return out
        end,
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


-- ======================================================================
-- THE DEBT THAT CAME BACK FROM THE DEAD
--
-- Two replay queues hold statements the database never took: the INSERT
-- that files a debt, and the DELETE that removes it once it is paid. They
-- were replayed independently and nothing connected them.
--
-- So a part FILED while oxmysql was away and then PAID while it was still
-- away left both queued for the same key. The sweep replays drops and then
-- adds, in that order, and the add wins: a debt the arena had already
-- handed over is written straight back into the ledger.
--
-- It does not stop there. The phantom row is read back by the load thread
-- in the SAME RUN and paid a second time, and read back and paid again on
-- every restart after it. One 700 debt became 1400 in a single run.
--
-- An INSERT and a DELETE for one key annihilate, so cancelling the pair is
-- the correct resolution rather than the cheap one: if the insert never
-- landed there is nothing for the delete to remove, and a delete replayed
-- against a row that does not exist costs nothing. The asymmetry runs one
-- way only -- a lost DELETE pays a debt twice, a lost INSERT forgets one --
-- so the delete is the one that is kept.
-- ======================================================================

t.test('CONTROL: with the database up the whole time, paying a debt leaves no row behind', function()
    local s = newArena({})
    s.step(3)
    fileDebt(s)
    t.equals(s.storedAmount(), 700, 'the debt never reached the table, so this proves nothing')

    s.betting.SweepUnpaid()     -- the player is online, so it is paid
    s.betting.SweepUnpaid()     -- and the replays run again

    t.equals(s.storedAmount(), 0, 'a row survived a paid debt even with the database up')
end)

t.test('a debt filed AND paid during an outage is NOT written back by the replay', function()
    local s = newArena({ down = true })
    s.step(3)
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed in memory, so this proves nothing')
    t.equals(s.storedAmount(), 0, 'the ADD reached a database that was down, so this proves nothing')

    local before = s.wallet()
    s.betting.SweepUnpaid()     -- PAID, and the DELETE is queued behind it
    t.equals(s.wallet(), before + 700, 'the player was not paid, so this proves nothing')
    t.equals(s.owed(), 0, 'memory still owes it, so this proves nothing')

    s.control.down = false
    s.betting.SweepUnpaid()     -- replayDrops() and then replayAdds()

    t.equals(s.storedAmount(), 0,
        'a debt the arena had already paid was written back into the ledger table')
end)

t.test('and so it is not paid a SECOND time in the same run', function()
    -- `ensure Crimson-Arena` above `ensure oxmysql` is an ordinary mistake
    -- the load path is built to survive, and it is what puts the load thread
    -- behind the outage: it reads the ledger late, long after the sweep has
    -- already paid and dropped the debt.
    local s = newArena({ down = true })
    s.step(1)
    fileDebt(s)

    local start = s.wallet()
    s.betting.SweepUnpaid()     -- paid: +700
    s.control.down = false
    s.betting.SweepUnpaid()     -- the replay must not re-create the row
    s.step(4)                   -- the load thread finally reads the ledger
    s.betting.SweepUnpaid()     -- and pays whatever it read

    t.equals(s.wallet() - start, 700, 'the same 700 was paid twice in one run')
end)

t.test('and a restart does not read a phantom row back and pay it again', function()
    local s = newArena({ down = true })
    s.step(3)
    fileDebt(s)
    s.betting.SweepUnpaid()
    s.control.down = false
    s.betting.SweepUnpaid()

    -- Everything the database is holding when the server goes down.
    local r = newArena({ seed = s.snapshot() })
    r.step(3)

    local before = r.wallet()
    r.betting.SweepUnpaid()

    t.equals(r.wallet() - before, 0, 'the same 700 was paid again after a restart')
end)


-- ======================================================================
-- THE OTHER SIDE OF THAT PHOTOGRAPH
--
-- The test above guards the DELETE side: a debt paid while the read was out
-- must not be brought back by it. The ADD side had no such guard, and it
-- fails the other way -- it loses a player money rather than paying them
-- twice.
--
-- The load's SELECT is a photograph taken when it is ISSUED. A debt filed
-- after that -- or an outage ADD replayed after it -- reaches the row the
-- answer cannot see. `addStillPending` cannot cover it either: by the time
-- the answer arrives that write has SUCCEEDED and left the pending queue.
-- So the row is right, memory is right, and the merge splices them into a
-- number lower than both, assigning it over memory.
--
-- Measured before the fix: a character owed 1000 -- 300 from before the
-- restart and 700 filed while the read was out -- was paid 300. The other
-- 700 was gone from memory and gone from the row, which the payment then
-- deleted. Nothing anywhere said so.
-- ======================================================================

t.test('a debt filed while the read is in flight survives the read landing', function()
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    t.equals(s.owed(), 0, 'the read answered anyway, so there is no window and this proves nothing')

    -- Filed while the photograph is already taken. The store takes it; the
    -- answer still in flight knows nothing about it.
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed, so this proves nothing')
    t.equals(s.storedAmount(), 1000, 'the ADD did not reach the store, so this proves nothing')

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1000,
        'the read overwrote memory with a photograph taken before the debt was filed')
end)

t.test('and the player is paid all of it', function()
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    fileDebt(s)
    s.releaseRead()

    local before = s.wallet()
    s.betting.SweepUnpaid()

    t.equals(s.wallet() - before, 1000, 'the player was underpaid and nothing said so')
end)

t.test('an outage debt REPLAYED while the read is in flight survives it too', function()
    -- The same gap reached by the other route: the debt is filed during an
    -- outage so it queues, and the replay lands it after the SELECT went out.
    -- By the time the answer arrives the pending queue is empty, so the line
    -- that adds a still-waiting part back on has nothing to add.
    local s = newArena({ seed = SEED, down = true, holdSelect = true })
    s.step(3)
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed in memory, so this proves nothing')

    -- The player is kept AWAY for this sweep, so it replays the queued write
    -- without also paying and deleting the row -- the replay is the subject
    -- here, not the payment.
    s.control.down = false
    s.control.offline = true
    s.step(3)                        -- the load's SELECT goes out, and is held
    s.betting.SweepUnpaid()          -- replayAdds() lands the 700
    s.control.offline = false
    t.equals(s.storedAmount(), 1000, 'the replay did not reach the store, so this proves nothing')

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1000, 'the replayed debt was lost when the read landed')
end)

os.exit(t.summary())
