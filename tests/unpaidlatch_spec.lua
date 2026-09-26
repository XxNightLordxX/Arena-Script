--[[
    crimson_arena/tests/unpaidlatch_spec.lua

    THE WARNING THAT SAYS THE ARENA CANNOT SAVE WHAT IT OWES, AND WHETHER IT
    EVER STOPS SAYING IT.

    server/betting.lua tells an operator, once, when a write of the unpaid
    ledger is refused -- the commonest careful production setup, a database
    user with SELECT and nothing else, fails exactly this way and fails it on
    oxmysql's console where nothing in Lua can see it.

    There are two ways to get that warning wrong and they cost different
    things:

      STUCK      it latched for the life of the process, so an operator who
                 did what it asked -- GRANT INSERT, UPDATE, DELETE -- pressed
                 Money owed again and was told it was still broken. Annoying,
                 and it teaches them the money screen lies.

      FALSE      one flag cleared by any landing statement. This callback
                 answers for the INSERT and for the DELETE alike, so on a
                 user with INSERT and no DELETE a landing insert wipes a
                 refusal the delete raised, and the screen goes back to
                 promising durability on a setup that is still broken. A lost
                 DELETE pays a debt TWICE, out of the owner's pocket, once
                 per restart.

    So the all-clear waits until nothing is queued in either direction. This
    file is the three readings that separates: it latches, it clears when the
    write really is fixed, and it does NOT clear while a delete is still
    outstanding.

    Real server/util.lua + server/betting.lua. oxmysql is a table whose reads
    always land and whose WRITES are switched by the test, because that -- not
    a total outage -- is the shape of the fault. ArenaLog is captured, because
    the console line IS the feature.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('unpaidlatch_spec')

local REFUSED = 'could NOT be written to the database'
local ALL_CLEAR = 'being written to the database again'

--- One arena whose database reads land and whose writes obey `control`.
---
--- `control.failWrites` starts true for every test here; flipping it to false
--- is the operator running the GRANT.
local function newArena(control)
    control = control or {}
    if control.failWrites == nil then control.failWrites = true end

    local stored = {}
    local logged = {}
    local wallets = { [1] = { cash = 5000, bank = 5000 } }
    local threads = Sandbox.newThreadRunner()
    --- Writes sent while `control.holdWrites` is on, answered by hand.
    local heldWrites = {}

    local function query(_self, sql, params, cb)
        local flat = sql:gsub('%s+', ' ')
        if flat:find('CREATE TABLE') then if cb then cb({}) end return end

        if flat:find('^SELECT') then
            local rows = {}
            for _, row in pairs(stored) do
                local copy = {}
                for field, value in pairs(row) do copy[field] = value end
                rows[#rows + 1] = copy
            end
            if cb then cb(rows) end
            return
        end

        -- A WRITE. oxmysql took the statement either way -- that is what
        -- makes this fault invisible from Lua -- and the answer is where the
        -- refusal shows up.
        local function answer()
            -- PER STATEMENT KIND, because the two are granted separately and
            -- refuse asymmetrically. `failWrites` refuses both, as before;
            -- `failInserts` and `failDeletes` model GRANT SELECT, DELETE and
            -- GRANT SELECT, INSERT -- and equally any INSERT-specific refusal
            -- (a constraint, a deadlock, a row too long) on a server that
            -- then settles a debt.
            local isDelete = flat:find('^DELETE') ~= nil
            if control.failWrites
                or (isDelete and control.failDeletes)
                or ((not isDelete) and control.failInserts)
            then
                if cb then cb(nil) end
                return
            end
            if flat:find('^DELETE') then
                stored[params[1] .. '|' .. params[2]] = nil
            else
                local key = params[1] .. '|' .. params[2]
                local have = stored[key]
                stored[key] = {
                    citizenid = params[1], ledger_key = params[2], name = params[3],
                    account = params[4], reason = params[5],
                    amount = (have and have.amount or 0) + params[6],
                }
            end
            if cb then cb({ affectedRows = 1 }) end
        end

        if control.holdWrites then
            heldWrites[#heldWrites + 1] = answer
            return
        end
        answer()
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

    local function log(fmt, ...)
        local ok, text = pcall(string.format, fmt, ...)
        logged[#logged + 1] = ok and text or tostring(fmt)
    end

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ oxmysql = { query = query } }, { __call = function() end }),
        GetResourceState = function(name)
            -- UP THROUGHOUT unless a test says otherwise. An outage is a
            -- different fault with a different warning, and mixing the two is
            -- how the refusal latch came to be tested by nothing -- so only
            -- the pending-writes tests at the bottom, which are ABOUT an
            -- outage, ever set this.
            if name ~= 'oxmysql' then return 'missing' end
            return control.down and 'missing' or 'started'
        end,
        GetPlayers = function() return { '1' } end,
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        AddEventHandler = function() end, RegisterNetEvent = function() end,
        RegisterCommand = function() end, TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = Sandbox.newOxLib(), print = function() end,
        ArenaGetPlayer = playerFor, ArenaLog = log, ArenaDebug = function() end,
        ArenaNotifyKey = function() end, ArenaToastKey = function() end,
        ArenaPlayerName = function(src) return 'P' .. tostring(src) end,
    })
    env.Config.Database = { enabled = true }
    env.Config.Betting.refundRetrySeconds = 0

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaGetPlayer = playerFor
    env.ArenaLog = log
    env.ArenaDebug = function() end
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)

    local s = {
        betting = env.ArenaBetting,
        control = control,
        step = function(n) for _ = 1, (n or 1) do threads.step() end end,
        log = function() return table.concat(logged, '\n') end,
        --- How many console lines contain `needle`.
        says = function(needle)
            local seen = 0
            for _, line in ipairs(logged) do
                if line:find(needle, 1, true) then seen = seen + 1 end
            end
            return seen
        end,
        forget = function() logged = {} end,
        report = function() return table.concat(env.ArenaBetting.OwedReport(), '\n') end,
        rows = function()
            local n = 0
            for _ in pairs(stored) do n = n + 1 end
            return n
        end,
        --- Answers exactly ONE held write, the oldest, and leaves the rest.
        ---
        --- Needed to let a single statement land while its siblings are still
        --- outstanding, which is the only way to ask whether the all-clear
        --- waits for the whole queue or just for the one being answered.
        releaseOne = function()
            if #heldWrites == 0 then return false end
            local answer = table.remove(heldWrites, 1)
            answer()
            return true
        end,
        --- Answers every write that was held, oldest first.
        releaseWrites = function()
            local pending = heldWrites
            heldWrites = {}
            for _, answer in ipairs(pending) do answer() end
            return #pending
        end,
    }

    --- Files a debt for CID1 by refunding a stake while they are away, which
    --- is the ordinary way a row is INSERTed.
    ---
    --- `account` IS NOT DECORATION. The ledger key is the account and the
    --- reason joined, and sendAdd refuses outright to send an INSERT for a
    --- key that has a DELETE still queued -- deliberately, because the pair
    --- would annihilate and leave a phantom row. So a test that wants an
    --- insert to LAND while a drop is outstanding has to file it on a
    --- different key, and one that does not is a test whose insert is never
    --- sent at all. That is not a hypothetical: the first version of the
    --- interleave test below filed both on `cash`, no statement ever went
    --- out, and it passed against a build with the guard removed entirely.
    function s.fileDebt(amount, matchId, account)
        matchId = matchId or 'm1'
        s.betting.TakeStake(1, matchId, amount or 700, account or 'cash')
        control.offline = true
        s.betting.RefundAll(matchId, 'match_cancelled')
        control.offline = false
    end

    return s
end

--- Lets the start-up read land, which is what opens the ledger to writes.
local function opened(control)
    local s = newArena(control)
    s.step(3)
    s.forget()
    return s
end

t.test('a refused write is reported, once, not once per statement', function()
    local s = opened()

    s.fileDebt(700, 'm1')
    s.fileDebt(400, 'm2')
    s.fileDebt(200, 'm3')
    s.step(3)

    t.equals(s.says(REFUSED), 1,
        'the refusal was either never reported or reported once per write')
end)

t.test('DEFECT: and the all-clear is said once the writes land again', function()
    -- THE READING THIS FILE WAS WRITTEN FOR. The all-clear was gated on two
    -- counters named from a function defined hundreds of lines ABOVE them --
    -- so both reads reached a nil GLOBAL rather than the upvalue, `nil == 0`
    -- is false, and the clause could never be true. The operator ran the
    -- GRANT the warning asked for, came back, and was told it was still
    -- broken for the rest of the process. tools/verify_release.sh check 2
    -- catches the shape; this catches the behaviour.
    local s = opened()

    s.fileDebt(700, 'm1')
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refusal never fired, so this proves nothing')

    -- The operator runs GRANT INSERT, UPDATE, DELETE.
    s.control.failWrites = false
    s.fileDebt(400, 'm2')
    s.step(3)

    t.equals(s.says(ALL_CLEAR), 1,
        'writes are landing again and the money screen is still saying they are refused')
end)

t.test('and the all-clear is said ONCE, not once per landing write', function()
    local s = opened()

    s.fileDebt(700, 'm1')
    s.step(3)

    s.control.failWrites = false
    s.fileDebt(400, 'm2')
    s.fileDebt(300, 'm3')
    s.fileDebt(100, 'm4')
    s.step(3)

    t.equals(s.says(ALL_CLEAR), 1, 'the all-clear repeated itself for every write that landed')
end)

t.test('CONTROL: a healthy database says neither line', function()
    local s = opened({ failWrites = false })

    s.fileDebt(700, 'm1')
    s.step(3)

    t.equals(s.says(REFUSED), 0, 'a healthy database was reported as unwritable')
    t.equals(s.says(ALL_CLEAR), 0, 'an all-clear was given for a refusal that never happened')
end)

t.test('DEFECT: a landing INSERT does NOT clear a refusal while a DELETE is still out', function()
    -- THE READING THAT COSTS MONEY, and the one the first attempt at the
    -- re-arm got wrong. This callback answers for both statements, so a
    -- single flag cleared on any non-nil answer lets an insert that landed
    -- speak for a delete that did not -- and the setup where that happens,
    -- INSERT granted and DELETE not, is one this file elsewhere calls a
    -- common way to set a user up by accident.
    --
    -- A lost DELETE is not a lost warning. PayOutstanding credits the player
    -- and then drops the row; if the drop never reaches the database the
    -- money has been paid and the row is still there, so the next start
    -- reads it back and pays it AGAIN, out of the owner's pocket, for as
    -- many restarts as it takes.
    local s = opened()

    -- A debt that exists in the database, filed while writes worked.
    s.control.failWrites = false
    s.fileDebt(700, 'm1')
    s.step(3)
    t.equals(s.rows(), 1, 'the seed debt never reached the database, so this proves nothing')
    s.forget()

    -- Now the DELETE is refused: the player is paid, the row stays.
    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused DELETE was never reported')
    t.equals(s.rows(), 1, 'the fixture deleted the row it was told to refuse')

    -- An INSERT lands while that drop is still queued and unanswered. It
    -- must NOT speak for the delete.
    -- ON THE BANK LEDGER, not on cash -- see the note on fileDebt. An
    -- insert for the key the queued drop names is never sent, so filing this
    -- on `cash` would prove nothing about which statement the all-clear
    -- listens to.
    s.control.failWrites = false
    s.control.holdWrites = true
    s.fileDebt(400, 'm2', 'bank')
    s.control.holdWrites = false
    t.isTrue(s.releaseWrites() > 0,
        'no write was sent at all, so no landing INSERT was ever offered to the all-clear')
    s.step(3)

    t.equals(s.rows(), 2,
        'the INSERT did not reach the database, so this proves nothing about what a landing '
        .. 'write is allowed to clear')

    t.equals(s.says(ALL_CLEAR), 0,
        'an INSERT that landed cleared a refusal raised by a DELETE that had not -- the money '
        .. 'screen is promising durability on a setup that still pays debts twice')
end)

t.test('and the all-clear DOES arrive once the delete has landed too', function()
    -- The other half of the pair. A rule that never clears is the stuck
    -- latch again, wearing a better comment.
    local s = opened()

    s.control.failWrites = false
    s.fileDebt(700, 'm1')
    s.step(3)

    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused DELETE was never reported')
    s.forget()

    -- Everything granted. The queued drop replays and lands, emptying the
    -- queue, and the next write that lands with nothing outstanding clears.
    -- THE SWEEP IS CALLED BY HAND, and that is a fixture fact rather than a
    -- production one. replayDrops runs from SweepUnpaid and nowhere else; on
    -- a real server the thread at the bottom of betting.lua calls it every
    -- Config.Betting.refundRetrySeconds, which ships at 30. This fixture
    -- sets that to 0 -- as every betting spec here does, so a refund retry
    -- cannot fire in the middle of an unrelated assertion -- and 0 makes
    -- that thread return without starting. Calling it is what the timer
    -- would have done.
    --
    -- AND NOTHING IS FILED AFTERWARDS, which is the whole of this test.
    -- The first version ended with `s.fileDebt(400, 'm2')` before asserting,
    -- so the all-clear it observed was issued by that INSERT and the DELETE
    -- proved nothing -- the test passed against a build where a landing
    -- delete could never clear the latch at all, which is what the build
    -- actually did. The delete has to be the last statement standing.
    s.control.failWrites = false
    s.betting.SweepUnpaid()
    s.step(5)
    t.equals(s.rows(), 0, 'the queued DELETE was never replayed, so this proves nothing')

    t.equals(s.says(ALL_CLEAR), 1,
        'the DELETE the operator had just granted landed, and the money screen went on '
        .. 'reporting writes as refused -- the latch sticks for the whole run on a server '
        .. 'whose writes are all deletes')
end)

-- ======================================================================
-- AND THE MONEY SCREEN MUST NOT PROMISE DURABILITY FOR A DEBT STILL IN THE AIR
--
-- `durable` says the TABLE is writable. It does not say every debt on the
-- screen has landed in it. A debt filed while oxmysql was away was never
-- sent -- ArenaDb refuses what it cannot reach and queues it for replay --
-- so it exists in memory alone until the sweep gets to it.
--
-- The line above it reads "so a restart does not forget it", which is
-- precisely the sentence somebody about to restart a server that owes money
-- goes looking for.
-- ======================================================================

t.test('DEFECT: a debt still queued is named, not covered by "a restart does not forget it"', function()
    local s = opened({ failWrites = false })

    -- Proof the screen is in the durable state at all, or the rest proves
    -- nothing about what that state covers over.
    t.contains(s.report(), 'a restart does not forget it',
        'the ledger is not reported as durable, so there is no promise here to qualify')

    -- oxmysql goes away, and a debt is filed while it is gone. Nothing is
    -- sent: it is queued for replay and lives in memory only.
    s.control.down = true
    s.fileDebt(700, 'm1')
    s.step(3)
    t.equals(s.rows(), 0, 'the debt reached the database anyway, so it is not queued')

    -- And it comes back. The table is writable again -- durable is true --
    -- and that debt has still never been written.
    s.control.down = false

    local said = s.report()
    t.contains(said, 'a restart does not forget it',
        'the ledger stopped reading as durable, so this is a different branch')
    t.contains(said, 'EXCEPT 1',
        'a debt the code KNOWS has not reached the table was covered by "a restart does not '
        .. 'forget it" -- read by the one person deciding whether it is safe to restart')
    t.contains(said, 'ARE forgotten by a restart',
        'the report named a count without saying what it costs')
end)

t.test('and the qualifier goes once the queued debt has actually landed', function()
    -- A warning that never clears is a warning nobody reads. The replay runs
    -- from SweepUnpaid, which the thread at the bottom of betting.lua drives
    -- every Config.Betting.refundRetrySeconds on a real server; this fixture
    -- sets that to 0, which stops that thread starting. See the note in the
    -- delete test above.
    local s = opened({ failWrites = false })

    s.control.down = true
    s.fileDebt(700, 'm1')
    s.step(3)
    s.control.down = false

    t.contains(s.report(), 'EXCEPT 1', 'nothing was queued, so this proves nothing')

    -- THE DEBTOR IS KEPT AWAY ACROSS THE SWEEP. SweepUnpaid replays the
    -- queued statements AND pays everybody it can see -- so with player 1
    -- connected the row this test is watching for is written and immediately
    -- deleted again, and `rows` reads 0 for the right reason and the wrong
    -- question.
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.step(3)
    s.control.offline = false

    t.equals(s.rows(), 1, 'the queued debt was never replayed, so this proves nothing')
    t.equals(s.betting.PendingUnpaidWrites(), 0, 'the queue was never emptied')
    t.notContains(s.report(), 'EXCEPT',
        'the debt has reached the table and the screen is still warning that a restart '
        .. 'forgets it')
end)

t.test('DEFECT: and a landing DELETE does NOT clear it while an INSERT is still queued', function()
    -- THE OTHER HALF OF unpaidQueueIdle, AND IT WAS PINNED BY NOTHING.
    -- The predicate reads `pendingAddCount == 0 and pendingDropCount == 0`;
    -- deleting the FIRST term left all nine tests in this file green, so half
    -- of the rule the whole re-arm rests on was decoration.
    --
    -- It is the half that matters in the same direction as everything else
    -- here. A debt filed while oxmysql was away was never sent -- it sits in
    -- pendingAdds, in memory only. If a landing DELETE is allowed to issue
    -- the all-clear while that INSERT is still queued, the money screen says
    -- the ledger is being written again at the moment it is holding a debt
    -- the database has never seen.
    local s = opened({ failWrites = false })

    -- A debt that really is in the table, so there is something to delete.
    s.fileDebt(700, 'm1')
    s.step(3)
    t.equals(s.rows(), 1, 'the seed debt never landed, so this proves nothing')

    -- The DELETE is refused: the player is paid, the row stays, latch on.
    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused DELETE was never reported')
    s.forget()

    -- Now oxmysql goes away and a SECOND debt is filed on another ledger key.
    -- Nothing is sent: it is queued for replay and lives in memory alone.
    s.control.down = true
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    t.equals(s.betting.PendingUnpaidWrites(), 1, 'the debt was not queued, so this proves nothing')

    -- Everything granted and oxmysql back. SweepUnpaid replays drops BEFORE
    -- adds, so the DELETE lands while that INSERT is still outstanding.
    s.control.down = false
    s.control.failWrites = false
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.step(5)
    s.control.offline = false

    t.equals(s.says(ALL_CLEAR), 0,
        'a landing DELETE issued the all-clear while a debt was still queued and had never '
        .. 'reached the database -- the money screen promises durability for a debt only '
        .. 'memory is holding')
end)

t.test('and with TWO drops queued the all-clear waits for the LAST one, not the first', function()
    -- THE PROPERTY THE REORDER COULD HAVE BROKEN. Moving unpaidWrote below
    -- the dequeue makes the all-clear see the queue WITHOUT the drop being
    -- answered -- which is the point. The risk is that it now sees an EMPTY
    -- queue too early: with several drops outstanding, the first one to land
    -- must not speak for the ones still waiting.
    --
    -- Two debts on different ledger keys give two independent drops, and
    -- SweepUnpaid replays them one at a time.
    local s = opened({ failWrites = false })

    -- Two debts that really reach the table, on different keys.
    s.fileDebt(700, 'm1', 'cash')
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    t.equals(s.rows(), 2, 'both seed debts did not land, so this proves nothing')

    -- Both DELETEs refused: the player is paid, both rows stay, latch on.
    s.control.failWrites = true
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused DELETEs were never reported')
    t.equals(s.rows(), 2, 'the fixture deleted rows it was told to refuse')
    s.forget()

    -- Everything granted. Let the FIRST drop land on its own, by holding the
    -- writes and releasing exactly one.
    s.control.failWrites = false
    s.control.holdWrites = true
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.control.holdWrites = false

    local answered = s.releaseOne()
    s.step(3)
    t.isTrue(answered, 'no drop was sent at all, so this proves nothing')
    t.equals(s.rows(), 1, 'one drop should have landed and exactly one row should be left')

    t.equals(s.says(ALL_CLEAR), 0,
        'the FIRST of two queued deletes issued the all-clear while the second was still '
        .. 'outstanding -- the money screen promises durability with a statement still unsent')

    -- Now the second.
    s.releaseWrites()
    s.step(3)
    s.control.offline = false

    t.equals(s.rows(), 0, 'the second drop never landed, so this proves nothing')
    t.equals(s.says(ALL_CLEAR), 1,
        'both deletes landed and the money screen is still reporting writes as refused')
end)

t.test('DEFECT: a landing DELETE does NOT clear a refusal the INSERT is still raising', function()
    -- THE FALSE ALL-CLEAR THE QUEUE-IDLE GATE LET THROUGH, on the exact grant
    -- this whole layer exists for.
    --
    -- The two kinds record refusals ASYMMETRICALLY. A refused DELETE sits in
    -- pendingDrops before it is ever sent, so it keeps the queue non-idle. A
    -- refused INSERT is never queued at all: ArenaDb returns TRUE when
    -- oxmysql TOOK the statement, and the refusal arrives later as a nil
    -- answer -- so pendingAddCount stays 0 and the queue reads idle.
    --
    -- So on GRANT SELECT, DELETE with no INSERT: an insert is refused, the
    -- operator settles a debt, that delete lands, the queue reads idle, and
    -- the money screen announces the ledger is being written again while
    -- every insert is still being refused. Worse than the stuck latch it
    -- replaced -- a stuck warning is annoying, this one is believed.
    local s = opened({ failWrites = false })

    -- A debt that really reaches the table, while the INSERT still works.
    s.fileDebt(700, 'm1', 'cash')
    s.step(3)
    t.equals(s.rows(), 1, 'the seed debt never landed, so this proves nothing')

    -- Now the INSERT is refused. Nothing is queued -- that is the whole point.
    s.control.failInserts = true
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused INSERT was never reported')
    t.equals(s.betting.PendingUnpaidWrites(), 0,
        'the refused INSERT was queued, so the queue would have covered this and the test '
        .. 'proves nothing about the refusal being tracked per kind')
    s.forget()

    -- And a DELETE lands: the operator settles the seed debt.
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.rows(), 0, 'the DELETE did not land, so this proves nothing')

    t.equals(s.says(ALL_CLEAR), 0,
        'a landing DELETE announced the ledger was being written again while every INSERT was '
        .. 'still refused -- the operator is told the money is safe on the one setup where a '
        .. 'restart forgets every debt filed since')
end)

t.test('and it DOES clear once the INSERT lands too, which is the other half', function()
    -- A rule that never clears is the stuck latch again. Both kinds have to
    -- be answerable, and the INSERT is the one that was refused here.
    local s = opened({ failWrites = false })

    s.fileDebt(700, 'm1', 'cash')
    s.step(3)

    s.control.failInserts = true
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused INSERT was never reported')

    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(ALL_CLEAR), 0, 'the DELETE cleared it, so this is the other test')
    s.forget()

    -- The operator runs GRANT INSERT.
    s.control.failInserts = false
    s.fileDebt(300, 'm3', 'cash')
    s.step(3)

    t.equals(s.says(ALL_CLEAR), 1,
        'the INSERT the operator had just granted landed and the money screen went on '
        .. 'reporting writes as refused')
end)

t.test('and with BOTH kinds refused, the one that recovers does not speak for the other', function()
    -- THE ONE MUTATION NOTHING CAUGHT. Deleting `if anyUnpaidRefusal() then
    -- return end` left every other test green, because no test had both kinds
    -- refused at once -- and in the other direction the queue check shadows
    -- it (a refused DELETE is queued, so a landing INSERT stops at the queue
    -- test before ever reaching this one).
    --
    -- The direction that needs it: both refused, then the operator grants
    -- DELETE and not INSERT. The queued delete replays, lands, empties the
    -- queue -- and the insert is still refused. Nothing but this line is
    -- standing between the operator and "the ledger is being written again".
    local s = opened({ failWrites = false })

    -- A row in the table, while both statements still work.
    s.fileDebt(700, 'm1', 'cash')
    s.step(3)
    t.equals(s.rows(), 1, 'the seed debt never landed, so this proves nothing')

    -- Everything refused. The INSERT latches its kind and queues nothing;
    -- the DELETE latches its kind and stays queued.
    s.control.failWrites = true
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 2,
        'both kinds should have been reported once each -- if only one line was printed the '
        .. 'refusals are not being tracked per kind and this test proves nothing')
    s.forget()

    -- GRANT DELETE, and only DELETE.
    s.control.failWrites = false
    s.control.failInserts = true
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.step(5)
    s.control.offline = false

    t.equals(s.rows(), 0, 'the queued DELETE never landed, so this proves nothing')
    t.equals(s.betting.PendingUnpaidWrites(), 0, 'something is still queued, so the queue '
        .. 'check would cover this and the test proves nothing about the per-kind rule')

    t.equals(s.says(ALL_CLEAR), 0,
        'the DELETE recovered and announced the whole ledger safe while the INSERT was still '
        .. 'refused -- one statement kind vouching for the other, which is the defect the '
        .. 'per-kind memory exists to prevent')
end)

t.test('and the refusal NAMES which statement was refused, so the grant is actionable', function()
    -- One boolean could only say "a write was refused". A user with INSERT
    -- and no DELETE and a user with DELETE and no INSERT are different faults
    -- with different costs -- a lost DELETE pays a debt twice, a lost INSERT
    -- forgets one -- and the operator can only act on the one they are told.
    local insertOnly = opened({ failWrites = false })
    insertOnly.control.failInserts = true
    insertOnly.fileDebt(700, 'm1', 'cash')
    insertOnly.step(3)
    t.contains(insertOnly.log(), 'the INSERT was refused',
        'a refused INSERT did not say so, so the operator cannot tell which grant is missing')

    local deleteOnly = opened({ failWrites = false })
    deleteOnly.fileDebt(700, 'm1', 'cash')
    deleteOnly.step(3)
    deleteOnly.control.failDeletes = true
    deleteOnly.betting.PayOutstanding(1)
    deleteOnly.step(3)
    t.contains(deleteOnly.log(), 'the DELETE was refused',
        'a refused DELETE did not say so -- the costlier of the two faults, and the one that '
        .. 'pays a debt twice per restart')
end)

t.test('a drop answered TWICE does not drive the queue count below zero', function()
    -- THE GUARD NOTHING PINNED, and it is the only thing between this ledger
    -- and a latch that can never be cleared again.
    --
    -- replayDrops re-sends every key in pendingDrops on each sweep -- every
    -- Config.Betting.refundRetrySeconds, shipped at 30 -- and keeps no record
    -- of what is in flight. So a DELETE whose answer takes longer than one
    -- sweep interval, which is the database-under-stress case, is sent twice
    -- and answered twice. Without the `keys[key] ~= nil` test the second
    -- answer decrements pendingDropCount again, taking it NEGATIVE -- and
    -- unpaidQueueIdle asks `pendingDropCount == 0`, which a negative number
    -- never satisfies. The warning then sticks for the rest of the process no
    -- matter what the operator fixes, which is the exact failure the re-arm
    -- was written to remove.
    local s = opened({ failWrites = false })

    s.fileDebt(700, 'm1', 'cash')
    s.step(3)
    t.equals(s.rows(), 1, 'the seed debt never landed, so this proves nothing')

    -- The DELETE is refused, so it stays queued and latches its kind.
    s.control.failDeletes = true
    s.betting.PayOutstanding(1)
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the refused DELETE was never reported')
    s.forget()

    -- Granted, but the answers are held -- so two sweeps send the SAME drop
    -- twice before either is answered.
    s.control.failDeletes = false
    s.control.holdWrites = true
    s.control.offline = true
    s.betting.SweepUnpaid()
    s.betting.SweepUnpaid()
    s.control.holdWrites = false

    -- Both answers arrive for the one key.
    s.releaseWrites()
    s.step(5)
    s.control.offline = false

    t.equals(s.rows(), 0, 'the drop never landed, so this proves nothing')

    -- THE CONSEQUENCE HAS TO BE OBSERVED AFTER THE CORRUPTION, NOT DURING IT.
    -- Asserting the all-clear here proves nothing: the FIRST of the two
    -- answers sees a count of 0 and announces quite legitimately, and only
    -- the SECOND takes it to -1. Measured -- with the guard removed this test
    -- passed until the check below was added.
    --
    -- So: put the ledger through a whole fresh refusal-and-recovery cycle. A
    -- negative count makes unpaidQueueIdle answer false for the rest of the
    -- process, so the all-clear can never be issued again by anything.
    s.forget()

    s.control.failInserts = true
    s.fileDebt(400, 'm2', 'bank')
    s.step(3)
    t.equals(s.says(REFUSED), 1, 'the second refusal never latched, so this proves nothing')

    s.control.failInserts = false
    s.fileDebt(300, 'm3', 'cash')
    s.step(3)

    t.equals(s.says(ALL_CLEAR), 1,
        'a drop answered twice left the queue count below zero, so the queue reads permanently '
        .. 'non-idle and the write-refused warning can never be cleared again for the life of '
        .. 'the process, whatever the operator fixes')
end)

t.test('CONTROL: a ledger with nothing queued carries no qualifier at all', function()
    -- Without this, both tests above are satisfied by a report that says
    -- EXCEPT on every server with a debt on it -- which would teach an
    -- operator to read past the one line that matters.
    local s = opened({ failWrites = false })

    s.fileDebt(700, 'm1')
    s.step(3)

    local said = s.report()
    t.contains(said, 'a restart does not forget it', 'a healthy ledger was not reported as durable')
    t.notContains(said, 'EXCEPT',
        'a debt that is safely in the table was reported as at risk from a restart')
end)

os.exit(t.summary())
