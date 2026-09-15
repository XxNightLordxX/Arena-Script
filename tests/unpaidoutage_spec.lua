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
            -- A PHOTOGRAPH, AND WHICH INSTANT IT IS TAKEN AT IS THE WHOLE
            -- POINT. oxmysql is async, and it is a POOL: returning from
            -- `query` means the statement was accepted, not that it ran, and
            -- a SELECT's read view is established when it begins EXECUTING on
            -- its connection. So a write sent near a read can commit on
            -- either side of that instant, and nothing in Lua can tell which.
            --
            -- `lateSnapshot` is which side this test models. Default is the
            -- early one -- the rows as they were when the read was ISSUED --
            -- and `lateSnapshot = true` takes them when it is ANSWERED, so a
            -- write that happened while it was held IS in the answer. Both
            -- are legal; the arena must pay the same money either way.
            local function photograph()
                local rows = {}
                for _, row in pairs(stored) do
                    local copy = {}
                    for f, v in pairs(row) do copy[f] = v end
                    rows[#rows + 1] = copy
                end
                return rows
            end

            -- EVERY read is held while a test is holding one, not just the
            -- first: the load thread retries until it is answered, so
            -- delivering the second read would close the window the first one
            -- opened and the test would prove nothing.
            if control.holdSelect then
                if held == nil then
                    local early = not control.lateSnapshot and photograph() or nil
                    held = function() if cb then cb(early or photograph()) end end
                end
                return
            end

            -- ONCE, AND ONLY THE FIRST TIME. A read that answers with
            -- something that is not a list of rows is refused by the merge
            -- and leaves the load unfinished, which is how a real server
            -- reaches the state where a write goes out BETWEEN two reads.
            if control.junkRead then
                control.junkRead = false
                if cb then cb(false) end
                return
            end

            if cb then cb(photograph()) end
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
local function fileDebt(s, amount, matchId)
    matchId = matchId or 'm1'
    s.betting.TakeStake(1, matchId, amount or 700, 'cash')
    s.control.offline = true
    s.betting.RefundAll(matchId, 'match_cancelled')
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

t.test('a debt PAID while the ledger read was in flight is paid ONCE, and the row is not lost', function()
    -- THE PHOTOGRAPH THAT ARRIVES AFTER THE MONEY, and there are two ways to
    -- get this wrong in opposite directions. The load's SELECT is issued at
    -- start and answers whenever oxmysql gets round to it. In between, a debt
    -- can be filed, the player can walk in, and the sweep can pay them.
    --
    --   * Merge the row as it stands and a debt the arena has just handed
    --     over is reinstated, and the next sweep pays it again.
    --   * Delete the row on that payment -- which is what settling a part
    --     normally does -- and whatever the row held from BEFORE the restart
    --     goes with it, unread and unpaid.
    --
    -- The rule that answers both is that a payment made before the ledger has
    -- been read deletes nothing and suppresses nothing, because nothing it
    -- paid is in the table: no ADD of this run's has been sent yet. Here the
    -- player is owed 300 from before the restart and 700 filed this run, and
    -- the only right answer is that they end up with exactly 1000.
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    t.equals(s.owed(), 0, 'the read answered anyway, so there is no window and this proves nothing')

    -- A debt of 700 is filed in memory while that read is still out.
    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed, so this proves nothing')

    local before = s.wallet()
    s.betting.SweepUnpaid()
    t.equals(s.owed(), 0, 'the sweep did not settle the debt, so this proves nothing')
    t.equals(s.wallet(), before + 700, 'the player was not actually paid, so this proves nothing')

    -- And now the read lands, carrying a row from before any of that.
    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 300,
        'the debt from before the restart was taken by a payment that never covered it')

    s.betting.SweepUnpaid()
    t.equals(s.wallet(), before + 1000,
        'the player was paid the same debt twice, or paid short of what they are owed')
    t.equals(s.storedAmount(), 0, 'a settled row was left in the table for the next restart')
end)

t.test('AND THE ROW IS STILL THERE WHEN THE ANSWER IS TAKEN AFTER THE PAYMENT', function()
    -- THE ORDERING THAT PROVES IT, because the other one cannot. With the
    -- photograph taken when the read was ISSUED, a DELETE sent by that
    -- payment is too late to change what the answer carries -- so the 300
    -- arrives either way and the mistake is invisible. Taken when the read is
    -- ANSWERED, the row is simply gone, and the money with it.
    local s = newArena({ seed = SEED, holdSelect = true, lateSnapshot = true })
    s.step(3)
    fileDebt(s)

    local before = s.wallet()
    s.betting.SweepUnpaid()
    t.equals(s.wallet(), before + 700, 'the player was not actually paid, so this proves nothing')

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')
    t.equals(s.owed(), 300, 'the payment deleted a row it had not read and never paid')

    s.betting.SweepUnpaid()
    t.equals(s.wallet(), before + 1000, 'the player was paid short of what they are owed')
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
-- The load's SELECT is a photograph, and WHICH INSTANT IT IS TAKEN AT IS NOT
-- KNOWABLE FROM LUA. Returning from `query` means oxmysql accepted the
-- statement; a SELECT's read view is established when it starts executing on
-- a pooled connection. So an INSERT sent anywhere near the read can commit on
-- either side of that instant:
--
--   * after it  -- the answer does not have the debt, and merging the answer
--                  over memory cuts it;
--   * before it -- the answer already has the debt, and adding it back on
--                  hands the player the same money twice.
--
-- Both were measured against this file. Reconciling after the fact has to
-- guess which happened, and is wrong half the time; the halves cost
-- different people. Measured: 300 paid on a 1000 debt with one guess, 1700
-- paid on the same 1000 debt with the other.
--
-- So the arena sends NO INSERT while the read is out, and does not issue the
-- read while one is unanswered. What is held back sits in `pendingAdds`,
-- which the merge already splices on correctly, and goes out when the answer
-- lands. Every test below is run against BOTH orderings for that reason.
-- ======================================================================

t.test('nothing is added to the ledger while the read is in flight', function()
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    t.equals(s.owed(), 0, 'the read answered anyway, so there is no window and this proves nothing')

    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed, so this proves nothing')

    -- THE FIX ITSELF: the store still reads as it did before the debt was
    -- filed, because the INSERT is being held rather than raced.
    t.equals(s.storedAmount(), 300,
        'an INSERT went out while the read was in flight, which is the race itself')
end)

t.test('and TWO debts on the same key, both filed before the answer, both survive', function()
    -- ONE DEBT IS THE EASY CASE AND EVERY OTHER TEST HERE FILES ONE. The
    -- ledger key is account|reason, so two cancelled matches for the same
    -- player collide on `cash|match_cancelled` -- an ordinary Tuesday on a
    -- server that is restarting. Both are held back while the ledger is
    -- unread, so the queue has to ACCUMULATE them; keep only the last and
    -- the player is quietly short the first.
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)

    fileDebt(s, 700, 'm1')
    fileDebt(s, 400, 'm2')
    t.equals(s.owed(), 1100, 'the two debts were not both filed, so this proves nothing')

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1400, 'one of the two debts filed before the answer was lost by it')

    local before = s.wallet()
    s.betting.SweepUnpaid()
    t.equals(s.wallet() - before, 1400, 'the player was paid short of what the arena owes')
    t.equals(s.storedAmount(), 0, 'a settled row was left in the table')
end)

t.test('a debt filed while the read is in flight survives the read landing', function()
    local s = newArena({ seed = SEED, holdSelect = true })
    s.step(3)
    fileDebt(s)

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1000,
        'the read overwrote memory with a photograph taken before the debt was filed')
end)

t.test('AND IT IS THE SAME 1000 WHEN THE ANSWER ALREADY CONTAINS THE DEBT', function()
    -- THE OTHER ORDERING, which is the one that pays out of the OWNER'S
    -- pocket. Same debt, same seed; the only difference is that this read's
    -- view is established late enough to see anything that landed while it
    -- was held. An arena that adds a remembered write back on top of an
    -- answer that already has it pays 1700 here.
    local s = newArena({ seed = SEED, holdSelect = true, lateSnapshot = true })
    s.step(3)
    fileDebt(s)

    -- The player is kept AWAY across this sweep, so it flushes whatever the
    -- arena is willing to send without also paying and deleting the row.
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.control.offline = false

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1000, 'the debt was counted twice')

    local before = s.wallet()
    s.betting.SweepUnpaid()
    t.equals(s.wallet() - before, 1000, 'the player was paid more than the arena owes')
    t.equals(s.storedAmount(), 0, 'a row survived the payment')
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
    -- The same window reached by the other route: the debt is filed during an
    -- outage so it queues, and the sweep tries to replay it after the SELECT
    -- has gone out. The replay is held back for exactly as long as the read
    -- is, so the queue is still full when the answer arrives and the merge
    -- can see it.
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
    s.betting.SweepUnpaid()          -- replayAdds() is refused while it is out
    s.control.offline = false
    t.equals(s.storedAmount(), 300, 'the replay raced the read, which is the bug')

    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.owed(), 1000, 'the replayed debt was lost when the read landed')
end)

t.test('and the held-back replay goes out with the answer, not at the next sweep', function()
    -- refundRetrySeconds = 0 switches the sweep off entirely, so a debt left
    -- unmirrored until a sweep that never comes is one a restart forgets.
    local s = newArena({ seed = SEED, down = true, holdSelect = true })
    s.step(3)
    fileDebt(s)
    s.control.down = false
    s.control.offline = true
    s.step(3)
    s.betting.SweepUnpaid()
    t.isTrue(s.releaseRead(), 'there was no read in flight to release')

    t.equals(s.storedAmount(), 1000,
        'the answer landed and the held-back INSERT was not sent with it')
end)

t.test('a read that answers with junk does not open the ledger to writes either', function()
    -- THE HALF A NARROWER RULE WOULD MISS. "Send nothing while the read is in
    -- flight" is not the same as "send nothing until it has answered": a read
    -- that answers with something that is not a list of rows leaves the load
    -- unfinished and the flight over, and every debt filed before the retry
    -- goes out into the next read's blind spot with nothing left to splice it
    -- back on. Nothing contrived reaches this -- it is what a query error or
    -- a half-started oxmysql answers with.
    local s = newArena({ seed = SEED, junkRead = true })
    s.step(1)                        -- one attempt, and it answers with junk
    t.equals(s.owed(), 0, 'the junk read was merged, so this proves nothing')

    fileDebt(s)
    t.equals(s.owed(), 700, 'the debt was not filed, so this proves nothing')
    t.equals(s.storedAmount(), 300,
        'an INSERT went out between two reads, which is the race by another door')

    s.step(3)                        -- the retry reads properly this time
    t.equals(s.owed(), 1000, 'the debt filed between the two reads was lost by the second')
    t.equals(s.storedAmount(), 1000, 'the held-back INSERT never went out after the answer')
end)

os.exit(t.summary())
