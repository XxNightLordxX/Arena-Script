-- Crimson Arena: the book. Stakes, odds, and who gets paid.

--[[
    crimson_arena/server/betting.lua

    The only file in this resource that moves money.

    ESCROW, NOT BOOKKEEPING. A stake leaves the player's account the moment
    they lock in and is held here against a match id. From then on the money
    exists in exactly one place -- this file's tables -- until RefundOne,
    RefundAll or Settle hands it back out. Nothing anywhere reads a balance to
    work out what is owed, because a balance is a running total, and a running
    total cannot tell a refund that happened twice from one that never
    happened at all.

    THE INVARIANT: no sequence of join / leave / disconnect / match-abort /
    resource-stop may create or destroy a single dollar. What holds it up:
      - a stake is recorded only AFTER the removal actually succeeded;
      - a settled stake is marked rather than deleted, so a second payout of
        it is refused and printed instead of silently doubled, and only
        `Clear` -- once nothing is owed -- drops the record;
      - a stake the operator's config forfeits is marked settled and kept
        rather than quietly dropped from the books: it is the one movement
        here that ends with nobody credited, so it is logged and sent to the
        webhook every time. ForfeitAll says where that money goes and why;
      - money that cannot be handed back stays on the books and stays loud;
      - `Clear` refuses to drop a match that still holds anything. A leaked
        table entry is a bug someone can find later; a swallowed pot is one
        nobody can.

    TWO SEPARATE POOLS. The entry-fee pot is what the fighters are playing
    for; `maxPot` caps it and only it. Spectator side-bets are house action
    paid at `oddsMultiplier` and live in their own table, because a side-bet
    that reached the pot would let a bystander change what the winner takes
    home.

    All of the maths -- what a fee may be, what the house takes, how a pot
    splits, what a winning side-bet returns -- belongs to shared/arena.lua.
    This file decides only WHERE money goes and WHETHER it has already gone.
]]

ArenaBetting = {}

local escrow = {}

--- Money this resource took and could not give back, keyed by CITIZEN ID.
---
--- WHY IT CANNOT BE KEYED BY MATCH, which is what it was before and is the
--- whole defect. Escrow is `escrow[matchId]`, reachable only through
--- stakesOf(matchId), and nothing anywhere iterates it. A refund that fails
--- leaves the stake unsettled with a comment promising "a later RefundAll
--- tries again" -- but there is no later: ArenaLobby.Leave sees the lobby is
--- empty and calls Destroy in the same call chain, Destroy calls RefundAll
--- (which fails the same way) and then Clear (which correctly REFUSES,
--- because the pot is still held) -- and then drops `matches[match.id]`
--- anyway. From that instant no id exists to call Clear, RefundAll or GetPot
--- with, and the escrow row sits in memory until the server stops.
---
--- Destroy's own comment states the invariant it does not enforce: "escrow
--- against a match nobody can look up is money nobody can get out again."
---
--- And the failure is not exotic. credit() needs a LOADED character, so the
--- commonest reason a refund cannot be delivered is the commonest reason one
--- is owed: they crashed. A single-host lobby whose host crashes destroys
--- the match immediately, and takes the entry fee with it.
---
--- Keyed by citizen id, the debt survives the reconnect, the teardown and
--- the recycled server id -- exactly as server/ammo.lua's `owed` does for
--- belongings, for exactly the same reason.
local unpaid = {}

local sideBets = {}

--- Matches whose pot payout is part-way through, or was.
---
--- THE COST OF SETTLING AFTER PAYING. Marking the stakes below the payout
--- loop is right -- a mark set first turns a failure mid-loop into money
--- recorded as paid and filed nowhere -- but it leaves the other half open:
--- a loop that stops part-way leaves every stake unsettled, so GetPot still
--- reports the FULL pot and a second Settle on that match pays the whole
--- list again, winners already paid included.
---
--- Neither order is safe on its own. This is the half that was missing:
--- Settle refuses to start a payout for a match it has already started one
--- for. A match whose payout did not finish stays refused rather than being
--- silently re-run -- the money is still on the books, an operator can see
--- it, and settling it by hand is a smaller problem than paying it twice.
--- DO NOT drop this and rely on the stake marks alone.
local settling = {}

--- Matches whose side-bet book has already been judged.
---
--- `settling` ABOVE CANNOT ANSWER THIS, and one flag for both is why the
--- book could be settled twice. On the shipped config
--- (betPayout.includeEntryPot) ArenaBetting.Settle hands the entry stakes
--- straight to SettleSpectatorBets and raises `settling` on the way past --
--- so that flag is already up the first and only legitimate time the side
--- book runs, and a guard reading it would refuse the payout the pot
--- depends on. This one is raised by that run itself, so the SECOND run --
--- an ArenaMatch.Abort arriving after ArenaMatch.End, or an operator
--- retrying a payout that died part-way -- is refused instead of paying
--- every winner again. Measured on the shipped config: a 15,000 pot paid
--- 15,000 a second time. DO NOT collapse the two into one flag.
local sideSettled = {}

--- Who walked out of a round that was being FOUGHT, per match.
---
--- `match.players` CANNOT BE ASKED THIS. It is the roster as it stands, and
--- ArenaLobby.Leave drops the leaver's row on the way out -- so one second
--- after quitting a live round the book read them as an ordinary onlooker
--- and sold them the watcher's spectatorBets.closeAfterStartSeconds on the
--- very round they had just abandoned. Refused while fighting, accepted
--- twenty seconds after walking out, on the shipped config.
---
--- Recorded rather than derived, because by the time MarkWalkedOut runs the
--- roster row is already gone and nothing else remembers they were ever on
--- it. Dropped with the match in Clear.
local walkedOutOf = {}

--- Has this match's pot payout begun?
---
--- EVERY PATH THAT HANDS MONEY BACK HAS TO ASK. Both payout loops mark a
--- stake settled AFTER the money has moved -- on purpose, so a credit that
--- failed is retried rather than recorded as paid and filed nowhere -- and
--- the price of that order is a window in which a stake is PAID and still
--- reads unsettled. ArenaLobby.Destroy's RefundAll, ArenaMatch.Abort's, and
--- Clear's own side-bet return all read unsettled as "not yet paid" and
--- handed the same money out a second time: a 15,000 pot paid its winner
--- 15,000 and then refunded all three stakes on the way down. That is
--- 15,000 of new money in a file whose whole invariant is that no sequence
--- of join, leave, abort or stop creates a dollar.
---
--- SO THE REFUND PATHS ARE GATED AND THE SETTLE PATH IS NOT. Marking the
--- stakes earlier is the other way to shut this and it is the wrong one --
--- read the note under the pot loop for what a mark set before the payment
--- costs. What a half-finished payout leaves on the books is loud, visible
--- and fixable by hand; money paid twice is none of those.
local function payoutBegun(matchId)
    return settling[matchId] == true
end

local function trace(fmt, ...)
    if Config.Debug then ArenaLog(fmt, ...) end
end

local function money(amount)
    return ('%s%d'):format(Config.Betting.currencySymbol or '$', math.max(0, Arena.ToInt(amount) or 0))
end

local function serverId(value)
    local id = Arena.ToInt(value)
    if not id or id <= 0 then return nil end
    return id
end

local function citizenIdOf(src)
    local player = ArenaGetPlayer(src)
    return player and player.PlayerData and player.PlayerData.citizenid or nil
end

local function balanceOf(player, account)
    local wallet = player and player.PlayerData and player.PlayerData.money
    if type(wallet) ~= 'table' then return nil end
    return Arena.ToInt(wallet[account or Config.Betting.account])
end

local function debitAccounts()
    local list = Config.Betting.accounts
    local out = {}
    if type(list) == 'table' then
        for _, name in ipairs(list) do
            if Arena.IsKey(name) then out[#out + 1] = name end
        end
    end
    if #out == 0 then out[1] = Config.Betting.account or 'cash' end
    return out
end

function ArenaBetting.Accounts()
    return debitAccounts()
end

--- What one player holds in each of them, for the panel's own display. Read
--- through the same balanceOf every debit uses, so the figure on screen and
--- the figure the debit checks cannot disagree.
--- @param src any
--- @return table<string, integer>
function ArenaBetting.Wallet(src)
    local player = ArenaGetPlayer(serverId(src))
    local out = {}
    for _, account in ipairs(debitAccounts()) do
        out[account] = balanceOf(player, account) or 0
    end
    return out
end

--- Did `amount` actually move, in the direction expected?
---
--- WHY THIS DOES NOT JUST READ THE RETURN VALUE. It used to, and required it
--- to be exactly `true` -- and a framework function that returns nil on
--- success, as some builds of these do, then read as failure. The
--- consequences were not symmetrical and not obvious: money was taken from
--- the player and the stake was recorded as never taken, so the pot stayed
--- empty and a match nobody appeared to have paid for paid nobody out. Every
--- test passed throughout, because the fixture returned `true` like the
--- documentation says and unlike the server.
---
--- So the balance is the authority. `>=` rather than `==` because another
--- resource may move the same account in the same instant, and the question
--- here is only whether OUR movement happened.
--- @param before integer|nil
--- @param after integer|nil
--- @param amount integer
--- @param outward boolean
--- @return boolean|nil moved -- nil when the balance could not be read
local function moved(before, after, amount, outward)
    if not before or not after then return nil end
    local delta = outward and (before - after) or (after - before)
    return delta >= amount
end

--- The accounts to try for one debit, honouring a player's own choice.
---
--- A CHOSEN ACCOUNT IS THE ONLY ONE TRIED. Falling back to the other would
--- take money out of a pocket the player deliberately did not pick -- they
--- chose `bank` because they wanted the cash left alone, and quietly spending
--- it instead is the same class of mistake as clamping a number somebody
--- typed. Refused with a reason they can act on is the honest answer.
---
--- THREE ANSWERS, NOT TWO, and collapsing the last two was a hole in exactly
--- the promise above.
---
---   NO NAME GIVEN -- "no preference". Every server that has not switched
---   the choice on, and every panel that has not been touched. Falls back to
---   the operator's list, and must, or an old panel cannot pay at all.
---
---   A NAME THAT IS NOT ONE OF THIS PLAYER'S ACCOUNTS -- junk. A stale
---   panel, a typo in a payload, a crafted request. Nothing was really
---   chosen, so this is "no preference" too: refusing a player who can
---   plainly pay, because something sent a word nobody recognises, helps
---   nobody.
---
---   A REAL ACCOUNT OF THEIRS THAT THIS SERVER DOES NOT DEBIT -- a choice
---   that cannot be honoured. This is a player who picked cash on a server
---   that has since stopped taking it, and falling back spends the pocket
---   they deliberately left alone. That is the one outcome this whole
---   function exists to prevent, so nothing moves and they are told.
---
--- The player's own wallet is what separates the last two, because it is the
--- only thing that knows which account names are real for them.
--- @param player table|nil
--- @param preferred any
--- @return string[]|nil -- nil where a real choice cannot be honoured
local function accountsFor(player, preferred)
    local allowed = debitAccounts()
    if not Arena.IsKey(preferred) then return allowed end

    for _, name in ipairs(allowed) do
        if name == preferred then return { name } end
    end

    local wallet = player and player.PlayerData and player.PlayerData.money
    if type(wallet) ~= 'table' or wallet[preferred] == nil then return allowed end

    return nil
end

local function debit(src, amount, reason, preferred)
    local player = ArenaGetPlayer(src)
    if not player then return false, nil end

    local accounts = accountsFor(player, preferred)
    if not accounts then
        ArenaLog('betting: refused a payment from \'%s\' -- that account exists for this player but is not one Config.Betting.accounts lets this server debit. Nothing was taken from the other one.',
            tostring(preferred))
        return false, nil
    end

    for _, account in ipairs(accounts) do
        local before = balanceOf(player, account)

        if before == nil or before >= amount then
            -- WRAPPED, LIKE EVERY OTHER CALL INTO ANOTHER RESOURCE. This
            -- and the AddMoney below are the only two places money moves,
            -- and they were the only two calls in this file that could throw
            -- straight out of the arena. A framework that raises here takes
            -- the whole settle with it -- and the note below the payout loop
            -- says what that used to cost. DO NOT unwrap these.
            local sent, answer = pcall(function()
                return player.Functions.RemoveMoney(account, amount, reason)
            end)

            if not sent then
                ArenaLog('betting: taking %d from %s threw -- %s. Nothing was taken.',
                    amount, tostring(account), tostring(answer))
                answer = false
            end

            if answer ~= false then
                local confirmed = moved(before, balanceOf(ArenaGetPlayer(src), account), amount, true)

                -- nil is an unreadable balance, so the return value is all
                -- there is. Only an explicit false counts against it --
                -- checked above -- because a framework that reports success
                -- by staying quiet must not be read as refusing.
                if confirmed == nil or confirmed then return true, account end

                -- AND AN UNCONFIRMED REMOVAL IS NOT A REFUSAL EITHER, WHICH
                -- IS WHY THIS STOPS HERE INSTEAD OF TRYING THE NEXT ACCOUNT.
                --
                -- THE DEFECT: it used to fall through. RemoveMoney did not
                -- say no, so the money may well be gone -- and the balance
                -- can read short for a reason that has nothing to do with us,
                -- because AddMoney and RemoveMoney fire the framework's own
                -- money-changed event and every tax, bank and paycheck script
                -- on the server hangs off it. One of those moving the same
                -- account in the same instant is indistinguishable from our
                -- own call failing. Falling through then took the WHOLE
                -- amount out of the second account as well, and recorded one
                -- stake for it.
                --
                -- SO A MOVEMENT NOBODY CAN CONFIRM IS TREATED AS HAVING
                -- HAPPENED, and the seat is granted. The two ways to be wrong
                -- are not equal: charging twice for one seat takes money that
                -- was never staked and leaves no record to refund from, while
                -- granting a seat for a payment that silently failed costs the
                -- pot one entry fee and is written down here in full.
                ArenaLog('betting: took %d from \'%s\' for %s and could not confirm it from the balance -- the account moved by less than that in the same instant, which is usually another resource writing to it. TREATED AS PAID and NOT retried against the other account: charging twice is the worse mistake. If this line is frequent, something else on this server is moving money on the same event.',
                    amount, tostring(account), tostring(src))
                return true, account
            end
        end
    end

    return false, nil
end

local function credit(src, amount, reason, citizenid, account)
    local player = ArenaGetPlayer(src)
    if not player then return false end
    if citizenid and (player.PlayerData and player.PlayerData.citizenid) ~= citizenid then return false end

    -- BACK WHERE IT CAME FROM when we know, and to the configured account
    -- when we do not. Refunding bank money as cash is a way to launder
    -- through the arena, and refunding cash into the bank is a surprise for
    -- somebody who was carrying it on purpose.
    local target = Arena.IsKey(account) and account
        or (debitAccounts()[1] or Config.Betting.account)

    local before = balanceOf(player, target)
    local sent, answer = pcall(function()
        return player.Functions.AddMoney(target, amount, reason)
    end)

    if not sent then
        ArenaLog('betting: paying %d into %s threw -- %s. Nothing was paid.',
            amount, tostring(target), tostring(answer))
        return false
    end
    if answer == false then return false end

    -- THE BALANCE CAN CONFIRM THIS AND CANNOT REFUTE IT, and reading it the
    -- other way is how the arena paid people twice.
    --
    -- THE DEFECT: this returned `confirmed` -- so a balance that had gone up
    -- by LESS than the amount was read as "the credit failed". AddMoney fires
    -- the framework's money-changed event, which is exactly where a deposit
    -- rake or a tax script hangs, so a short delta is the ordinary shape of a
    -- successful credit on a server that has one.
    --
    -- What that cost: the caller recorded the money as still owed, the unpaid
    -- sweep came back `refundRetrySeconds` later and paid it AGAIN -- and
    -- where the cause was systemic, such as a percentage taken on every
    -- deposit, the delta was short every single time and the same debt was
    -- paid every thirty seconds for as long as the player stayed online.
    --
    -- So a confirmation is worth something and a failure to confirm is worth
    -- nothing: only an explicit refusal from AddMoney, checked above, means
    -- the money did not move.
    local confirmed = moved(before, balanceOf(ArenaGetPlayer(src), target), amount, false)
    if confirmed == false then
        ArenaLog('betting: paid %d into \'%s\' for %s and could not confirm it from the balance -- the account moved by less than that in the same instant, which is usually another resource taking a cut on the way in. TREATED AS PAID: retrying it is how the same debt gets paid over and over.',
            amount, tostring(target), tostring(src))
    end

    return true
end

-- ----------------------------------------------------------------------
-- THE DEBT THE ARENA OWES, WRITTEN SOMEWHERE A RESTART CANNOT REACH.
--
-- THE ASYMMETRY WAS THE DEFECT. What players owe the arena is persisted --
-- server/ammo.lua's owed-kit table, keyed by citizen id for exactly the
-- reasons written over `unpaid` above. What the ARENA owes a player lived in
-- this file's memory and nowhere else: there was not one ArenaDb call in it.
-- So a pot that could not be delivered because the winner's game died was
-- filed faithfully against their character and then forgiven by the next
-- restart, and on a server that restarts nightly the ledger could not
-- survive the night it was written on. The debts run one way and only one of
-- them was durable.
--
-- SAME SHAPE AS THE OWED-KIT TABLE, on purpose: citizen id and a key
-- composed in Lua, one row per thing owed, accumulating with
-- ON DUPLICATE KEY UPDATE, deleted the moment it is settled. An operator who
-- has read one of these two tables has read both.
--
-- `ledger_key` is the account the money came out of and the reason it is
-- owed, joined by a character neither can contain. It is what lets an entry
-- fee and a side-bet payout owed to the same character off the same collapse
-- be two rows instead of one overwriting the other -- the property the
-- in-memory `parts` list has always had, carried into the table.
--
-- NO PARAMETER IS EVER NIL, which is why account and reason are NOT NULL
-- with an empty default and are written as '' rather than left out. A Lua
-- table with a hole in it is not one value short, it is undefined: `#t` and
-- `ipairs` disagree about it, and which one oxmysql happens to use decides
-- whether the statement runs, fails, or writes the wrong columns. DO NOT
-- pass a nil through here.
-- ----------------------------------------------------------------------
local UNPAID_SUBJECT = 'the money the arena still owes players'

local UNPAID_SCHEMA_SQL = [[
    CREATE TABLE IF NOT EXISTS crimson_arena_unpaid (
        citizenid VARCHAR(64) NOT NULL,
        ledger_key VARCHAR(191) NOT NULL,
        name VARCHAR(128) NOT NULL DEFAULT '',
        account VARCHAR(32) NOT NULL DEFAULT '',
        reason VARCHAR(64) NOT NULL DEFAULT '',
        amount BIGINT NOT NULL DEFAULT 0,
        written_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (citizenid, ledger_key)
    )
]]

local UNPAID_ADD_SQL = [[
    INSERT INTO crimson_arena_unpaid
        (citizenid, ledger_key, name, account, reason, amount)
    VALUES (?, ?, ?, ?, ?, ?)
    ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount), name = VALUES(name)
]]

local UNPAID_DROP_SQL =
    'DELETE FROM crimson_arena_unpaid WHERE citizenid = ? AND ledger_key = ?'

-- NEWEST FIRST AND BOUNDED, for the reason ammo.lua's read is: the table has
-- no expiry, a character who never comes back is never paid, and the newest
-- debt is the one most likely still collectable. This is the only thing
-- `written_at` is for. DO NOT drop the column.
local UNPAID_READ_SQL =
    'SELECT citizenid, ledger_key, name, account, reason, amount FROM crimson_arena_unpaid '
    .. 'ORDER BY written_at DESC LIMIT 5000'

--- How long a read may be outstanding before the retry may try again.
local UNPAID_READ_TIMEOUT_MS = 30000
local UNPAID_RETRY_MS = 30000

local unpaidLoaded = false
local unpaidReading = false
local unpaidWriteRefused = false

--- Watches whether a write actually landed, and says so ONCE.
---
--- A READ IS NOT EVIDENCE OF A WRITE. The commonest careful production setup
--- -- import sql/install.sql as an admin, run the resource as a user with
--- SELECT and nothing else -- fails asynchronously: oxmysql reports it on its
--- own console and the pcall inside ArenaDb never sees a thing. The operator
--- has to be told here or not at all. DO NOT report a read as proof of a
--- write.
local function unpaidWrote(answer)
    if answer ~= nil or unpaidWriteRefused then return end

    -- A NIL ANSWER IS ONLY A REFUSAL WHEN THERE WAS SOMETHING TO REFUSE IT.
    -- ArenaDb calls back with nil on every path that does not reach oxmysql
    -- at all, which says nothing about whether this user may write. Latching
    -- on those would leave the ledger reported as unsaved for the rest of the
    -- run after an outage that has since ended. DO NOT drop this test.
    if not ArenaDbReady(UNPAID_SUBJECT) then return end

    unpaidWriteRefused = true
    ArenaLog('betting: money the arena owes players could NOT be written to the database. The table '
        .. 'can be read but not changed, which is almost always a database user with SELECT and no '
        .. 'INSERT or DELETE. The ledger still works for this run and a restart forgets it. The '
        .. 'real error is on oxmysql\'s console, not this one.')
end

--- `account` and `reason` joined by a character neither can contain.
local function partKey(account, reason)
    return ('%s|%s'):format(Arena.IsKey(account) and account or '',
        Arena.IsKey(reason) and reason or '')
end

--- WRAPPED, AND THE WRAP IS NOT BELT AND BRACES. Both of these run on the
--- money path -- `owe` is the line inside each payout loop that catches what
--- a winner could not be handed -- and losing the durable copy must NEVER
--- take the payout down with it. ArenaDb already swallows what oxmysql
--- throws; this covers everything above oxmysql, an operator's Config among
--- it. What is in memory is the live answer and the table is the backup of
--- it, so a backup that fails is a line in the log and nothing more. DO NOT
--- unwrap these.
local mirrorThrew = false

local function mirror(sql, params)
    local ok, err = pcall(function() ArenaDb(UNPAID_SUBJECT, sql, params, unpaidWrote) end)
    if ok or mirrorThrew then return end

    -- SAID ONCE. These fire per debt and per collection; an operator whose
    -- Config or database wrapper is broken needs telling, not spamming. DO
    -- NOT make this a counter that resets.
    mirrorThrew = true
    ArenaLog('betting: money the arena owes players could not be written down (%s), so a restart '
        .. 'will forget it. It is still kept in memory for this run and paid to anyone who comes '
        .. 'back before then.', tostring(err))
end

local function saveUnpaidPart(citizenid, name, part, added)
    mirror(UNPAID_ADD_SQL, {
        citizenid,
        part.key,
        tostring(name or citizenid),
        Arena.IsKey(part.account) and part.account or '',
        Arena.IsKey(part.reason) and part.reason or '',
        added,
    })
end

-- ======================================================================
-- A DELETE THAT IS LOST PAYS THE SAME DEBT TWICE
--
-- Every other statement on this ledger can be dropped and cost the arena
-- nothing worse than forgetting a debt it owes -- the player is out of
-- pocket, which is bad, and `mirror` says so out loud. THE DELETE IS THE
-- OTHER WAY ROUND. PayOutstanding credits the player and then drops the row;
-- if that drop never reaches the database the money has been paid and the
-- row is still there, so the next start reads it back and SweepUnpaid pays
-- it AGAIN, out of the owner's pocket, for as many restarts as it takes.
--
-- So this one is remembered until the database says it is gone, and re-sent
-- until then. It is the same treatment the outstanding-kit slate already
-- gives its own statements, and for the same reason; see replayPending in
-- server/ammo.lua. DO NOT put this drop back through `mirror`, which cannot
-- tell one statement from another and forgets it either way.
-- ======================================================================
local pendingDrops = {}
local pendingDropCount = 0
local PENDING_DROP_LIMIT = 500

--- Sends one drop, and forgets it only when the database has answered.
local function sendDrop(citizenid, key)
    local ok = pcall(function()
        ArenaDb(UNPAID_SUBJECT, UNPAID_DROP_SQL, { citizenid, key }, function(answer)
            unpaidWrote(answer)

            -- NIL IS NOT AN ANSWER, IT IS THE ABSENCE OF ONE. ArenaDb calls
            -- back with nil on every path that never reached oxmysql, which
            -- is exactly the outage this exists for -- so clearing on nil
            -- would forget the drop precisely when it had not happened. DO
            -- NOT relax this to a bare callback.
            if answer == nil then return end

            local keys = pendingDrops[citizenid]
            if keys == nil or keys[key] == nil then return end

            keys[key] = nil
            pendingDropCount = pendingDropCount - 1
            if next(keys) == nil then pendingDrops[citizenid] = nil end
        end)
    end)

    if not ok then mirrorThrew = true end
end

local function dropUnpaidPart(citizenid, key)
    local keys = pendingDrops[citizenid]

    if keys == nil or keys[key] == nil then
        -- THE CAP REFUSES A NEW KEY RATHER THAN MAKING ROOM FOR IT, the same
        -- judgement the kit slate's cap makes: everything in here is a drop
        -- the database has not taken, so evicting one to admit another loses
        -- exactly as much and does it to the older debt. The drop is still
        -- SENT -- it just is not replayed if it goes missing.
        if pendingDropCount < PENDING_DROP_LIMIT then
            if keys == nil then
                keys = {}
                pendingDrops[citizenid] = keys
            end
            keys[key] = true
            pendingDropCount = pendingDropCount + 1
        end
    end

    sendDrop(citizenid, key)
end

--- True while this part has been paid but the database has not yet agreed.
local function dropStillPending(citizenid, key)
    local keys = pendingDrops[citizenid]
    return keys ~= nil and keys[key] ~= nil
end

--- Re-sends every drop the database has not taken.
local function replayDrops()
    if pendingDropCount == 0 then return 0 end
    if not ArenaDbReady(UNPAID_SUBJECT) then return 0 end

    -- LISTED BEFORE ANY OF IT IS SENT, because the callback can answer on
    -- this very line and take its key out of the table being walked. DO NOT
    -- dispatch from inside the pairs loop.
    local flat = {}
    for citizenid, keys in pairs(pendingDrops) do
        for key in pairs(keys) do flat[#flat + 1] = { citizenid, key } end
    end

    for _, entry in ipairs(flat) do sendDrop(entry[1], entry[2]) end
    return #flat
end

--- Reads the ledger back at start, and MERGES rather than assigns.
---
--- WITHOUT THIS THE TABLE IS A WRITE-ONLY LOG -- every debt recorded
--- faithfully and never read again, the rows just sitting there proving the
--- restart forgot them.
---
--- A debt can be incurred in the seconds between the CREATE and the answer
--- landing, and it must not be wiped by the read that follows it. Where both
--- have the same row THE STORED TOTAL WINS, because every write to memory is
--- mirrored into that same row before this runs -- so the column already
--- holds the older total plus the new part, and keeping memory's number
--- instead would forgive everything from before the restart.
--- @return boolean loaded
local function loadUnpaid()
    if unpaidLoaded then return true end
    if unpaidReading or not ArenaDbReady(UNPAID_SUBJECT) then return false end

    unpaidReading = true

    -- AND THE FLAG IS FREED IF NOTHING EVER ANSWERS. ArenaDb calls back on
    -- every path it controls, but a query oxmysql accepts and then never
    -- answers is not one of them -- and a flag stuck on would turn a guard
    -- against reading twice into a guarantee of never reading at all. DO NOT
    -- set the flag without this releasing it.
    SetTimeout(UNPAID_READ_TIMEOUT_MS, function() unpaidReading = false end)

    ArenaDb(UNPAID_SUBJECT, UNPAID_SCHEMA_SQL, {}, function()
        ArenaDb(UNPAID_SUBJECT, UNPAID_READ_SQL, {}, function(rows)
            unpaidReading = false
            if type(rows) ~= 'table' then return end

            -- A LATE ANSWER IS REFUSED OUTRIGHT. The timeout above can free
            -- the flag while a read is still out there, so the flag alone
            -- does not prove this is the only answer -- and a second one is
            -- a photograph of the table BEFORE whatever has been paid since.
            -- Merging it reinstates settled debts. DO NOT drop this check.
            if unpaidLoaded then return end

            -- NOT `money`, WHICH IS THE FORMATTER THIS BLOCK CALLS BELOW.
            -- DO NOT rename it back: a local of that name here shadows it
            -- and the log line at the end of this function stops being a
            -- call and starts being an attempt to call a number.
            local people, owedTotal = 0, 0
            for _, row in ipairs(rows) do
                local citizenid = type(row) == 'table' and row.citizenid or nil
                local amount = math.max(0, Arena.ToInt(row and row.amount) or 0)
                local key = type(row) == 'table' and row.ledger_key or nil

                -- A PART THAT HAS BEEN PAID IS NOT READ BACK IN. This read
                -- can land after PayOutstanding has already settled somebody
                -- -- the comment above says so -- and the row it returns is a
                -- photograph taken before that payment. Merging it would
                -- reinstate a debt the arena has already handed over, and the
                -- stored total wins here, so it would win over the payment
                -- too. DO NOT drop this test.
                if Arena.IsKey(citizenid) and Arena.IsKey(key) and dropStillPending(citizenid, key) then
                    amount = 0
                end

                if Arena.IsKey(citizenid) and Arena.IsKey(key) and amount > 0 then
                    local held = unpaid[citizenid]
                    if not held then
                        held = { citizenid = citizenid, name = row.name, total = 0, parts = {} }
                        unpaid[citizenid] = held
                        people = people + 1
                    end

                    local part
                    for _, have in ipairs(held.parts) do
                        if have.key == key then part = have break end
                    end
                    if part then
                        held.total = held.total - part.amount
                        part.amount = amount
                    else
                        part = {
                            key = key,
                            amount = amount,
                            account = Arena.IsKey(row.account) and row.account or nil,
                            reason = Arena.IsKey(row.reason) and row.reason or nil,
                        }
                        held.parts[#held.parts + 1] = part
                    end
                    held.total = held.total + amount
                    owedTotal = owedTotal + amount
                end
            end

            unpaidLoaded = true
            if people > 0 then
                ArenaLog('betting: read back %s owed to %d character(s) from before the restart. '
                    .. 'It is paid the next time each of them is seen.', money(owedTotal), people)
            end
        end)
    end)

    return false
end

--- Records money this resource owes a character and could not deliver.
---
--- THE POINT IS THE KEY. A debt filed against a match id dies with the
--- match, and the match is torn down in the same call chain that failed to
--- pay. Filed against the citizen id it survives the teardown, the
--- reconnect, and the recycled server id -- and the sweep at the bottom of
--- this file pays it the next time that character is seen.
---
--- Accumulated rather than overwritten: a player can be owed an entry fee
--- and a side-bet off the same collapse, and the second must not erase the
--- first.
--- @param citizenid any
--- @param name any -- for the log only
--- @param amount integer
--- @param account string|nil -- the account it was taken FROM
--- @param reason string|nil
--- @return boolean recorded -- false when there is no citizen id to file under
local function owe(citizenid, name, amount, account, reason)
    local id = Arena.IsKey(citizenid) and citizenid or nil
    local value = math.max(0, Arena.ToInt(amount) or 0)
    if not id or value <= 0 then return false end

    local row = unpaid[id]
    if not row then
        row = { citizenid = id, name = name, total = 0, parts = {} }
        unpaid[id] = row
    end

    row.name = name or row.name
    row.total = row.total + value

    -- ONE PART PER ACCOUNT AND REASON, which is the shape of the row that
    -- backs it. Two debts off the same collapse -- an entry fee and a
    -- side-bet payout -- have different reasons and stay two parts, which is
    -- what "accumulated rather than overwritten" has always meant here; two
    -- of the SAME thing add up, exactly as the stack of rounds in
    -- server/ammo.lua's slate does. DO NOT go back to appending blind: a
    -- part with no identity cannot be deleted from the table when it is
    -- paid, and a debt that cannot be deleted is one the next restart hands
    -- out again.
    local key = partKey(account, reason)
    local part
    for _, held in ipairs(row.parts) do
        if held.key == key then part = held break end
    end

    if part then
        part.amount = part.amount + value
    else
        part = { key = key, amount = value, account = account, reason = reason }
        row.parts[#row.parts + 1] = part
    end

    -- THE MEMORY IS THE LIVE ANSWER AND THIS IS THE BACKUP OF IT, which is
    -- the order everything below `mirror` depends on: a database that is
    -- down, switched off or broken costs this line nothing and CANNOT stop
    -- the debt being recorded. DO NOT make the write conditional on the
    -- mirror having worked.
    saveUnpaidPart(id, row.name, part, value)
    return true
end

local function transaction(kind, matchId)
    return ('crimson_arena:%s:%s'):format(kind, tostring(matchId))
end

local function payoutWebhook(title, description, fields)
    if Config.Webhook.logPayouts ~= true then return end
    ArenaWebhook(title, description, fields)
end

--- Discord log of money this file could not deliver. Deliberately NOT gated
--- on `logPayouts`: an operator who turned payout logging off still needs to
--- hear about a player who is owed. ArenaWebhook itself no-ops when webhooks
--- are switched off entirely.
local function incidentWebhook(title, description, fields)
    ArenaWebhook(title, description, fields)
end

local function stakesOf(matchId)
    return escrow[matchId] or {}
end

local function canonicalPick(value)
    if type(value) == 'number' then
        local id = Arena.ToInt(value)
        return id and tostring(id) or nil
    end
    if Arena.IsKey(value) then return value end
    return nil
end

local function lobbyMatch(matchId)
    if type(ArenaLobby) ~= 'table' or type(ArenaLobby.Get) ~= 'function' then return nil end
    local match = ArenaLobby.Get(matchId)
    if type(match) ~= 'table' then return nil end
    return match
end

local function fightersOf(matchId)
    local match = lobbyMatch(matchId)
    if not match or type(match.players) ~= 'table' then return nil end
    return match.players
end

--- Is this row held by the character sitting on that server id RIGHT NOW?
---
--- A SERVER ID IS NOT AN IDENTITY, and every payment in this file already
--- knew it: `credit` refuses a payout whose citizen id does not match the
--- character holding the id, and has since the day somebody won a pot and
--- switched character before it was settled. THE DEFECT is that the GATES
--- never got the same test. A bettor who disconnects leaves an unsettled
--- row behind, FiveM hands their server id to the next player through the
--- door, and that stranger was refused the lobby by holdsSideBet, shown the
--- departed player's stake by GetSideBet, counted as a backer by
--- MatchesBackedBy and refused a bet of their own by HasSpectatorBet. No
--- money could move -- credit would have refused it -- but every gate in
--- front of the money was answering about somebody else.
---
--- A ROW WITH NO CITIZEN ID OF ITS OWN is judged on the server id alone,
--- because that is all it has: it was placed in a moment the framework
--- could not say who the player was, and falling back is exactly what
--- `credit` does with the same gap. DO NOT tighten this into a refusal --
--- it would strand the bet behind every gate at once.
--- @param bet table
--- @param id integer
--- @param citizenid string|nil -- who holds `id` now; read once by the caller
--- @return boolean
local function betIsHeldBy(bet, id, citizenid)
    if bet.src ~= id then return false end
    if not Arena.IsKey(bet.citizenid) then return true end
    return bet.citizenid == citizenid
end

local function holdsSideBet(matchId, src)
    local citizenid = citizenIdOf(src)
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if betIsHeldBy(bet, src, citizenid) and not bet.settled then return true end
    end
    return false
end

--- `countdown` IS TWO DIFFERENT STATES WEARING ONE NAME, and reading the
--- name alone is what left the fighters' book open inside the arena.
---
--- A lobby counting down has nobody on the ground. A match in its FIVE-SECOND
--- FREEZE -- after ArenaMatch.Start has teleported the whole roster in and
--- set `match.placed` -- is a round being fought that has not been promoted
--- to `live` yet. Measured: a fighter standing in the arena, weapon in hand,
--- was sold a 25,000 bet on himself.
---
--- server/lobby.lua works the identical distinction out for what leaving
--- costs, off the identical two fields, and its comment calls reading the
--- state name alone the defect. That fix never reached this file.
---
--- THE BOOK SHUTS FOR A FIGHTER THE MOMENT THE ROUND GOES LIVE AND THERE IS
--- NO SETTING FOR IT. Nothing below is configurable and nothing here should
--- be: spectatorBets.closeAfterStartSeconds is the WATCHER's grace and has
--- never applied to the people in the fight. DO NOT wire this to a config
--- key.
local function roundIsBeingFought(match)
    return match.state == 'live' or (match.state == 'countdown' and match.placed == true)
end

local function betsAreOpen(match, isFighter)
    local state = match.state
    if isFighter and roundIsBeingFought(match) then return false end
    if state == 'lobby' or state == 'countdown' then return true end
    if state ~= 'live' then return false end

    if isFighter then return false end

    local spectator = Config.Betting.spectatorBets or {}
    local grace = math.max(0, Arena.ToInt(spectator.closeAfterStartSeconds) or 0)
    local startedAt = Arena.ToInt(match.startsAt)
    local now = os.time()
    if not startedAt or startedAt > now then return false end
    return (now - startedAt) < grace
end

function ArenaBetting.BetsAreOpen(match)
    return type(match) == 'table' and betsAreOpen(match) or false
end

function ArenaBetting.FighterBetsAreOpen(match)
    return type(match) == 'table' and betsAreOpen(match, true) or false
end

function ArenaBetting.SecondsUntilBetsClose(match)
    if type(match) ~= 'table' or match.state ~= 'live' then return nil end

    local spectator = Config.Betting.spectatorBets or {}
    local grace = math.max(0, Arena.ToInt(spectator.closeAfterStartSeconds) or 0)
    local startedAt = Arena.ToInt(match.startsAt)
    if grace <= 0 or not startedAt then return nil end

    local left = (startedAt + grace) - os.time()
    if left <= 0 then return nil end
    return left
end

local function pickExists(match, pick)
    local players = type(match.players) == 'table' and match.players or {}

    -- ELIMINATED IS NOT ON THE ROSTER, for this question.
    --
    -- An eliminated fighter deliberately KEEPS their row -- the results board
    -- ranks off it -- so "is in match.players" and "can still win" are two
    -- different questions and this only ever asked the first. The book stays
    -- open for spectatorBets.closeAfterStartSeconds (30 on the shipped
    -- config) AFTER the round goes live, so inside that window a spectator
    -- could be sold a bet, by the panel's own chip, on somebody who was
    -- already out. It is not voided at settlement either -- the holder never
    -- fought -- so it falls through to lost and their whole stake, up to
    -- 25,000, goes to whoever backed the winner.
    if Arena.ModeUsesTeams(match.modeKey) then
        if not Arena.GetTeamByKey(pick) then return false end
        for _, player in pairs(players) do
            if player.team == pick and not Arena.IsEliminated(player) then return true end
        end
        return false
    end

    for id, player in pairs(players) do
        if canonicalPick(id) == pick and not Arena.IsEliminated(player) then return true end
    end
    return false
end

local function isRefundReason(reason)
    return type(reason) == 'string' and reason:sub(1, 6) == 'refund'
end

--- Whether a payout line is a stake coming back rather than money won.
---
--- Exported because server/match.lua has to tell them apart and could not:
--- Settle hands its computed list back even when the whole thing is a
--- refund -- deliberately, as the report of what was decided -- and End
--- summed every line into a player's `earnings`. So a match that did not
--- qualify to pay out told everybody they had WON their own entry fee back.
--- @param reason any
--- @return boolean
function ArenaBetting.IsRefundReason(reason)
    return isRefundReason(reason)
end

local function returnSideBet(bet, matchId)
    if bet.settled then return false end

    -- FORFEITED MONEY IS NEVER HANDED BACK, and it is settled rather than
    -- skipped so the escrow can still be closed out -- the same shape
    -- RefundOne uses for a forfeited stake. Returning TRUE is the honest
    -- answer: nothing is owed, so nothing should be reported as unpaid.
    if bet.forfeited then
        bet.settled = true
        bet.settledAs = 'forfeit'
        ArenaLog('SIDE-BET RETURN REFUSED: %d from %s on match %s was FORFEITED when they walked out '
            .. 'and stays with the house. They were told so at the time.',
            bet.amount, tostring(bet.name or bet.src), tostring(matchId))
        return true
    end

    if not credit(bet.src, bet.amount, transaction('sidebet_refund', matchId),
        bet.citizenid, bet.account) then
        if owe(bet.citizenid, bet.name or bet.src, bet.amount, bet.account, 'sidebet_refund') then
            bet.settled = true
            bet.settledAs = 'owed'
            ArenaLog('SIDE-BET REFUND DEFERRED: %d owed to %s (citizenid %s) on match %s -- recorded against ' ..
                'their character and paid when they are next seen.',
                bet.amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
        else
            ArenaLog('SIDE-BET REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the bet stays held, ' ..
                'and there is no citizen id to file it against.',
                bet.amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
        end
        incidentWebhook('Side-bet not returned',
            'A spectator side-bet could not be handed back and is still owed.', {
                { name = 'Match', value = tostring(matchId) },
                { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                { name = 'Amount', value = money(bet.amount) },
            })
        return false
    end

    bet.settled = true
    bet.settledAs = 'refund'
    trace('returned side-bet of %d to %s on match %s', bet.amount, tostring(bet.src), tostring(matchId))
    ArenaNotifyKey(bet.src, 'notify.spectator_bet_refunded', 'info', money(bet.amount))
    return true
end

function ArenaBetting.IsEnabled()
    return Config.Betting.enabled == true
end

function ArenaBetting.StakeOf(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return 0, nil end

    local stake = stakesOf(matchId)[id]
    if type(stake) ~= 'table' or stake.settled then return 0, nil end
    return math.max(0, Arena.ToInt(stake.amount) or 0), stake.account
end

function ArenaBetting.GetPot(matchId)
    local total = 0
    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then total = total + stake.amount end
    end
    return total
end

--- Whether anybody OTHER THAN `exceptSrc` holds an unsettled entry stake on
--- the match.
---
--- THIS IS THE QUESTION THE RULES LOCK ACTUALLY ASKS, and GetPot was never
--- it. The lock's sentence is "People have already paid to be in this
--- round" -- other people, who paid to play under the rules they saw. The
--- host's own stake is taken by ArenaLobby.Create the instant the lobby
--- exists, so a pot that is merely non-zero says nothing about whether a
--- second person has ever paid. Counting it locked every lobby on the
--- shipped fee against the only person in it. DO NOT go back to GetPot > 0
--- here.
--- @param matchId string
--- @param exceptSrc any -- the host, whose own stake does not count
--- @return boolean
function ArenaBetting.OthersStaked(matchId, exceptSrc)
    local host = serverId(exceptSrc)
    for id, stake in pairs(stakesOf(matchId)) do
        if not stake.settled and id ~= host and (Arena.ToInt(stake.amount) or 0) > 0 then
            return true
        end
    end
    return false
end

function ArenaBetting.GetStake(matchId, src)
    local id = serverId(src)
    if not id then return 0 end
    local stake = stakesOf(matchId)[id]
    if not stake or stake.settled then return 0 end
    return stake.amount
end

--- Takes a player's entry fee and holds it against `matchId`.
---
--- Betting switched off, or entry fees switched off, is SUCCESS with nothing
--- taken: a free match must not become unjoinable because there is no pot.
--- Every other refusal happens BEFORE any money moves, so a false return
--- always means the player's account is untouched.
--- @param src integer
--- @param matchId string
--- @param amount any -- as requested; re-resolved through Arena.ResolveEntryFee
--- @param account any -- which account the player chose to pay from, if any
--- @return boolean ok
--- @return string|nil reasonKey
function ArenaBetting.TakeStake(src, matchId, amount, account)
    if not ArenaBetting.IsEnabled() then return true, nil end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    if holdsSideBet(matchId, id) then return false, 'error.bet_not_spectator' end

    local fee, reason = Arena.ResolveEntryFee(amount)
    if not fee then return false, reason or 'error.bet_invalid' end
    if fee <= 0 then return true, nil end

    local held = stakesOf(matchId)[id]
    if held and not held.settled then
        local fighters = fightersOf(matchId)
        local vacated = fighters ~= nil and fighters[id] == nil
        local theirs = held.citizenid ~= nil and held.citizenid == citizenIdOf(id)

        if not vacated or not theirs then
            ArenaLog('DOUBLE STAKE REFUSED: %s already holds %d on match %s. Nothing was taken.',
                tostring(held.citizenid or id), held.amount, tostring(matchId))
            return false, 'error.bet_already_staked'
        end

        -- AND IT IS THEIR LIVE STAKE AGAIN, so the forfeit comes off it.
        --
        -- Leaving marks a stake forfeited so no later refund can hand it
        -- back. Sitting back down on that same money makes them a paying
        -- fighter again -- and a fighter whose stake still carried the flag
        -- would be refused their entry fee on an abort they had nothing to do
        -- with, having paid for the round like everybody else.
        held.forfeited = nil

        trace('%s took a seat on match %s back on the %d already forfeited to its pot -- nothing taken',
            tostring(held.citizenid or id), tostring(matchId), held.amount)
        return true, nil
    end

    local ceiling = Arena.ToInt(Config.Betting.maxPot) or 0
    if ceiling > 0 and (ArenaBetting.GetPot(matchId) + fee) > ceiling then
        return false, 'error.pot_limit_reached'
    end

    local took, paidFrom = debit(id, fee, transaction('stake', matchId), account)
    if not took then
        return false, 'error.not_enough_money'
    end

    escrow[matchId] = escrow[matchId] or {}
    escrow[matchId][id] = {
        amount = fee,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
        account = paidFrom,
        takenAt = os.time(),
        settled = false,
    }

    trace('took stake of %d from %s for match %s (pot now %d)',
        fee, tostring(id), tostring(matchId), ArenaBetting.GetPot(matchId))
    ArenaNotifyKey(id, 'notify.stake_taken', 'info', money(fee))
    return true, nil
end

--- The reason keys that mean AN OPERATOR STOPPED THIS ROUND.
---
--- WHY A LIST OF KEYS AND NOT A FLAG. ArenaMatch.Abort is the admin stop --
--- the tablet's Stop button, /arenaadmin stop, /arenaadmin wipe and the
--- onResourceStop sweep every one of them reach the books through it -- and
--- the only thing Abort hands this file is the reason it was given. Nothing
--- else here can tell an operator pulling a round down from a lobby that
--- emptied by itself, and the two must not be treated alike. If a key is
--- ever renamed in server/main.lua it has to be renamed here with it.
---
--- WHAT IT CHANGES, AND IT IS ONE THING: on an admin stop a stake that was
--- forfeited by walking out goes BACK to the player who walked out.
--- Everywhere else the forfeit stands exactly as it always has -- leaving a
--- round that is still being fought costs you the stake and the survivors
--- play for it. The money only comes back when an operator has taken the
--- round away and there is no longer anybody who can win it.
---
--- 'match.aborted' is Abort's own default, for a caller that names no
--- reason. 'match.ended_abandoned' is DELIBERATELY ABSENT: that is
--- everybody walking out, which is the case the forfeit exists for.
local ADMIN_STOP_REASONS = {
    ['notify.match_stopped_by_admin'] = true,
    ['notify.resource_stopping'] = true,
    ['match.aborted'] = true,
}

local function adminStop(reasonKey)
    return type(reasonKey) == 'string' and ADMIN_STOP_REASONS[reasonKey] == true
end

--- Says, once, why a refund path is refusing a match that has been paid.
local function refusePaidOut(matchId, what)
    ArenaLog('%s REFUSED: match %s has already begun paying out, so what still reads unsettled on '
        .. 'it is money that may ALREADY be in a winner\'s pocket -- both payout loops mark a '
        .. 'stake settled AFTER the money moves, on purpose, so that a credit which failed is '
        .. 'retried instead of being recorded as paid and filed nowhere. Handing it back here '
        .. 'would pay it a second time and CREATE money. Nothing was paid. It stays on the books '
        .. 'and this match will not be dropped; look above for what stopped the payout and settle '
        .. 'the rest by hand.', what, tostring(matchId))
end

function ArenaBetting.RefundOne(matchId, src, reasonKey)
    local id = serverId(src)
    if not id then return false end

    if payoutBegun(matchId) then
        refusePaidOut(matchId, 'REFUND')
        return false
    end

    local stake = stakesOf(matchId)[id]
    if not stake then
        ArenaLog('REFUND IGNORED: no stake is held for %s on match %s.', tostring(id), tostring(matchId))
        return false
    end
    if stake.settled then
        ArenaLog('DOUBLE REFUND REFUSED: %d for %s on match %s was already returned as "%s". Nothing was paid.',
            stake.amount, tostring(stake.citizenid or id), tostring(matchId), tostring(stake.settledAs))
        return false
    end

    -- SETTLED RATHER THAN SKIPPED, and the difference is whether the match
    -- can ever be dropped. A forfeited stake is real money still sitting in
    -- the pot, so GetPot counts it and Clear refuses to drop a match while it
    -- does. Merely refusing to pay it would leave it counted for ever and the
    -- escrow could never be closed out. Settling it as a forfeit takes it out
    -- of the pot without paying anybody -- which is what ForfeitAll does with
    -- the same money at the end of a round.
    --
    -- TRUE, because nothing is owed. A false here reads as "could not pay"
    -- and would have RefundAll report the match as still owing money it has
    -- deliberately kept.
    --
    -- AND AN ADMIN STOP IS THE ONE UNWIND THAT UNDOES IT. A forfeited stake
    -- stays in the pot because the survivors are playing for it; an operator
    -- stopping the round takes away the thing it was forfeited TO, and from
    -- that moment keeping it is not a penalty, it is the arena destroying
    -- money. Four fighters dropping out of a live round and an admin then
    -- pressing Stop used to burn the whole pot -- 200,000 at the shipped
    -- ceiling -- with nobody credited and nothing to show for it.
    --
    -- ONLY an admin stop. A lobby that empties, a round that ends, a single
    -- player walking out: the forfeit stands, because there is still a round
    -- for the money to be won in. See ADMIN_STOP_REASONS.
    if stake.forfeited and not adminStop(reasonKey) then
        stake.settled = true
        stake.settledAs = 'forfeit'
        stake.reason = reasonKey
        ArenaLog('REFUND REFUSED: %d for %s on match %s was FORFEITED when they left and stays in the pot. ' ..
            'They were told so at the time. Nothing was paid back.',
            stake.amount, tostring(stake.citizenid or id), tostring(matchId))
        return true
    end

    if stake.forfeited then
        ArenaLog('FORFEIT RETURNED: %d for %s on match %s was forfeited when they left, but the round '
            .. 'was stopped (%s) -- there is nobody left to win it, so it goes back.',
            stake.amount, tostring(stake.citizenid or id), tostring(matchId), tostring(reasonKey))
    end

    if not credit(id, stake.amount, transaction('refund', matchId),
        stake.citizenid, stake.account) then
        -- Left unsettled deliberately: this is money still held and still
        -- owed, so a later RefundAll tries again and Clear goes on refusing
        -- to drop the match until it lands. Writing it off here would be the
        -- one thing this file must never do.
        -- MOVED OFF THE MATCH RATHER THAN LEFT ON IT. The stake is marked
        -- settled so Clear can drop this match's escrow, and the money is
        -- filed against the CHARACTER, where the sweep can still find it
        -- after Destroy has dropped the id. Left on the match it was
        -- destroyed a few milliseconds later; the log line that used to sit
        -- here promised a retry that had nowhere to run.
        if owe(stake.citizenid, stake.name or id, stake.amount, stake.account, reasonKey) then
            stake.settled = true
            stake.settledAs = 'owed'
            ArenaLog('REFUND DEFERRED: %d owed to %s (citizenid %s) could not be delivered on match %s -- ' ..
                'they are not on the server. It is recorded against their character and will be paid when they are next seen.',
                stake.amount, tostring(stake.name or id), tostring(stake.citizenid), tostring(matchId))
        else
            ArenaLog('REFUND FAILED: %d owed to %s (citizenid %s) on match %s -- the stake stays held, ' ..
                'and there is no citizen id to file it against.',
                stake.amount, tostring(stake.name or id), tostring(stake.citizenid), tostring(matchId))
        end
        incidentWebhook('Stake not refunded', 'An entry fee could not be returned and is still held in escrow.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Player', value = ('%s (%s)'):format(tostring(stake.name or id), tostring(stake.citizenid)) },
            { name = 'Amount', value = money(stake.amount) },
        })
        return false
    end

    stake.settled = true
    stake.settledAs = 'refund'
    stake.reason = reasonKey

    trace('refunded %d to %s on match %s (%s)',
        stake.amount, tostring(id), tostring(matchId), tostring(reasonKey))
    ArenaNotifyKey(id, 'notify.stake_refunded', 'info', money(stake.amount))
    return true
end

function ArenaBetting.RefundAll(matchId, reasonKey)
    local refunded, total, owed, handedBackForfeits = 0, 0, 0, 0

    -- ASKED ONCE HERE AS WELL AS PER STAKE, so a match that has been paid
    -- says so in one line instead of one per player.
    if payoutBegun(matchId) then
        refusePaidOut(matchId, 'REFUND ALL')
        return false, 0, 0
    end

    for id, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            local amount = stake.amount

            -- READ BEFORE THE CALL, because RefundOne settles it.
            --
            -- AND NOT THROUGH THE ADMIN-STOP TEST ANY MORE, WHICH IS THE
            -- WHOLE OF THIS FIX. That test was the right one when a forfeit
            -- reaching RefundAll could still be kept; the clear a few lines
            -- below then made every one of them handed back, and this line
            -- was left reading as though some still were. So on a lobby
            -- teardown or a settle mismatch -- every reason that is NOT an
            -- admin stop -- the money went back to the player while this
            -- counted it as kept, and the console said the arena "kept N
            -- forfeited stake(s) rather than refunding them" about stakes it
            -- had just refunded. The comment that used to sit here warned
            -- about exactly that outcome and named the wrong cause.
            --
            -- Nothing that reaches this loop is kept. The only question worth
            -- recording is how many of the stakes handed back had been
            -- forfeits, because that is the line an operator reads when a pot
            -- unwinds.
            --
            -- RefundOne's REFUSAL IS STILL THERE AND STILL WORKS -- "was
            -- FORFEITED when they left and stays in the pot", keeping the
            -- money and returning true. It is not dead code and it has not
            -- been weakened. It is simply unreachable FROM HERE, because the
            -- clear below drops the flag it tests before it is called, and it
            -- is still reached by RefundOne's other caller, which hands a
            -- single player their stake back when they quit a round that
            -- carries on without them. DO NOT go looking for a missing
            -- refusal path; look at the clear.
            --
            -- AND THE RETURN VALUES CHANGE WITH THIS, deliberately. A forfeit
            -- that is handed back now counts in `refunded` and `total`,
            -- because that is what happened to it. It used to land in `kept`
            -- and be missing from both.
            local wasForfeit = stake.forfeited == true

            -- AND NO PATH THAT REACHES RefundAll HAS A WINNER LEFT EITHER.
            -- An admin stop is the obvious one and RefundOne knows about it,
            -- but the other three callers are a lobby being torn down and
            -- Settle's two refund branches, and none of those has survivors
            -- playing for the pot any more than a stopped round does. A
            -- forfeit is only honest while somebody else is being paid it;
            -- everywhere else it deletes the money. Four fighters dropping
            -- out and the lobby emptying burned the whole pot, and the log
            -- said the stake "stays in the pot" one line before the pot
            -- stopped existing. DO NOT narrow this back to the admin stop
            -- alone without first giving the other three a recipient.
            --
            -- RefundOne is left alone on purpose: its other caller hands a
            -- SINGLE player their stake back when they quit, and that one
            -- still forfeits, because the round they walked out of carries on
            -- without them.
            if stake.forfeited == true then stake.forfeited = nil end
            if ArenaBetting.RefundOne(matchId, id, reasonKey) then
                refunded = refunded + 1
                total = total + amount
                if wasForfeit then handedBackForfeits = handedBackForfeits + 1 end
            else
                owed = owed + amount
            end
        end
    end

    if handedBackForfeits > 0 then
        ArenaLog('betting: match %s handed back %d forfeited stake(s) because there was nobody left '
            .. 'to win them (%s).', tostring(matchId), handedBackForfeits, tostring(reasonKey))
    end

    if owed > 0 then
        ArenaLog('REFUND INCOMPLETE: match %s still owes %d across its players.', tostring(matchId), owed)
    elseif refunded > 0 then
        trace('refunded %d stake(s) worth %d on match %s (%s)',
            refunded, total, tostring(matchId), tostring(reasonKey))
    end

    return owed == 0, refunded, total
end

function ArenaBetting.KeepInPot(matchId, src)
    local id = serverId(src)
    if not id then return 0 end

    local stake = stakesOf(matchId)[id]
    if not stake or stake.settled then return 0 end

    -- WRITTEN DOWN, NOT JUST ANNOUNCED.
    --
    -- `settled` in this file means "this money has left the pot", which is
    -- why a forfeit deliberately does NOT set it: the stake stays in the pot
    -- and the survivors win it. But every refund path reads unsettled as
    -- REFUNDABLE, so the stake this line just told a player they had lost
    -- was handed straight back on the next abort -- and the commonest abort
    -- of all is the match dropping under minPlayersToPayOut BECAUSE they
    -- left. Leaving paid for itself.
    --
    -- So the flag is its own: still in the pot for GetPot and for Settle,
    -- never returnable to the player who walked out. RefundOne is the one
    -- place that has to honour it.
    stake.forfeited = true

    trace('kept %d of %s in the pot on match %s', stake.amount, tostring(id), tostring(matchId))
    ArenaNotifyKey(id, 'notify.stake_forfeited', 'error', money(stake.amount))
    return stake.amount
end

function ArenaBetting.ForfeitAll(matchId, reasonKey)
    local forfeited, total = 0, 0

    for id, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            stake.settled = true
            stake.settledAs = 'forfeit'
            stake.reason = reasonKey
            forfeited = forfeited + 1
            total = total + stake.amount
            ArenaNotifyKey(id, 'notify.stake_forfeited', 'error', money(stake.amount))
        end
    end

    if total > 0 then
        ArenaLog('FORFEIT: match %s kept %d across %d stake(s) (%s). Nobody was paid it.',
            tostring(matchId), total, forfeited, tostring(reasonKey))
        incidentWebhook('Pot forfeited', 'A cancelled lobby kept its stakes instead of returning them.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Kept', value = money(total) },
            { name = 'Stakes', value = tostring(forfeited) },
            { name = 'Reason', value = tostring(reasonKey) },
        })
    end

    return forfeited, total
end

local function entryPotJoinsPool()
    local block = Config.Betting.betPayout
    return type(block) == 'table' and block.includeEntryPot == true
end

local function addEntryStakesAsBets(matchId, context)
    local sides = {}
    for _, row in ipairs((type(context) == 'table' and context.players) or {}) do
        local id = Arena.ToInt(row.id)
        if id then
            sides[id] = Arena.IsKey(row.team) and row.team or tostring(id)
        end
    end

    local added = 0
    for src, stake in pairs(stakesOf(matchId)) do
        local amount = Arena.ToInt(stake.amount) or 0
        if not stake.settled and amount > 0 then
            sideBets[matchId] = sideBets[matchId] or {}
            sideBets[matchId][#sideBets[matchId] + 1] = {
                src = src,
                citizenid = stake.citizenid,
                name = stake.name,
                pick = sides[src] or tostring(src),
                amount = amount,
                account = stake.account,
                kind = 'fighter',
                mode = 'pool',
                fromEntryFee = true,
                -- CARRIED ONTO THE BET, because the money does not stop being
                -- forfeited just because it changed table. This was dropped
                -- here, and it was the last way round the forfeit: a fighter
                -- who walked out was told their stake was lost, the entry pot
                -- then joined the betting pool, and on a DRAW -- where nobody
                -- backed a winner and every bet is handed back -- the arena
                -- returned it to them with a "your bet was returned" message.
                -- DO NOT drop this again.
                forfeited = stake.forfeited == true,
                placedAt = stake.takenAt,
                settled = false,
            }

            stake.settled = true
            added = added + 1
        end
    end

    return added
end

function ArenaBetting.Settle(matchId, context)
    if not Arena.IsKey(matchId) then return {} end

    -- ABOVE THE ENTRY-POT BRANCH, WHICH IS WHERE THIS GUARD WAS DEAD.
    --
    -- betPayout.includeEntryPot SHIPS TRUE, and the branch below returned
    -- before the test ever ran -- so on the default install the one guard in
    -- this file against a second payout was unreachable code. Measured on
    -- the shipped config: a payout that died part-way, asked to run again,
    -- paid the winner the whole 15,000 pot a SECOND time. DO NOT move this
    -- back underneath the branch.
    if settling[matchId] then
        ArenaLog('betting: match %s was asked to pay out a SECOND time and was refused. The first '
            .. 'attempt did not finish, so its stakes are still open and the pot still reads full '
            .. '-- paying again would pay every winner who already had their money. Nothing has '
            .. 'been paid twice. Look above this line for what stopped the first attempt, and '
            .. 'settle what is left by hand.', tostring(matchId))
        return {}
    end

    if entryPotJoinsPool() then
        -- RAISED BEFORE THE STAKES MOVE, and it is not the same flag the
        -- pot loop below raises for itself. This branch does not pay
        -- anybody: it hands the entry stakes to SettleSpectatorBets, which
        -- is where the money actually leaves on the default config. The
        -- flag is what stops ArenaLobby.Destroy and ArenaMatch.Abort
        -- refunding those stakes on the way down AFTER they have been paid
        -- out as bets -- see payoutBegun. DO NOT wait for the payout to
        -- start; the whole window is between here and there.
        settling[matchId] = true

        local added = addEntryStakesAsBets(matchId, context)
        if added > 0 then
            trace('entry fees joined the bet pool on match %s (%d stake(s))', tostring(matchId), added)
        end
        return {}
    end

    local pot = ArenaBetting.GetPot(matchId)
    if pot <= 0 then
        ArenaLog('betting: match %s had NOTHING IN THE POT to pay out. Either the match was created with no entry fee, or every stake had already been refunded or forfeited before it ended. Side-bets are a separate pool and are unaffected.',
            tostring(matchId))
        return {}
    end

    context = type(context) == 'table' and context or {}
    local payouts, houseCut = Arena.ComputePayouts({
        pot = pot,
        players = context.players,
        winners = context.winners,
        teams = context.teams,
        contestants = context.contestants,
    })

    local refundingEveryone = #payouts > 0
    for _, payout in ipairs(payouts) do
        if not isRefundReason(payout.reason) then
            refundingEveryone = false
            break
        end
    end
    if refundingEveryone then
        ArenaLog('betting: match %s refunded its pot of %s instead of paying out -- %s. Fought by %d, %d winner(s), Config.Betting.minPlayersToPayOut = %d.',
            tostring(matchId), money(pot), tostring(payouts[1].reason),
            math.max(#(context.players or {}), Arena.ToInt(context.contestants) or 0),
            #(context.winners or {}),
            Arena.ToInt(Config.Betting.minPlayersToPayOut) or 0)

        ArenaBetting.RefundAll(matchId, payouts[1].reason)
        payoutWebhook('Pot refunded', 'The match did not qualify to pay out.', {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Pot', value = money(pot) },
            { name = 'Reason', value = tostring(payouts[1].reason) },
        })
        return payouts
    end

    local distributed = 0
    for _, payout in ipairs(payouts) do
        distributed = distributed + math.max(0, Arena.ToInt(payout.amount) or 0)
    end

    -- Arena.ComputePayouts cannot overspend the pot it was handed, so this
    -- only trips when the caller's player list disagrees with escrow. The
    -- honest answer to that is everyone's own stake back, not a guess.
    if (distributed + houseCut) > pot then
        ArenaLog('SETTLE REFUSED: match %s computed %d + %d house against a held pot of %d. Refunding instead.',
            tostring(matchId), distributed, houseCut, pot)
        ArenaBetting.RefundAll(matchId, 'refund_settle_mismatch')
        return {}
    end

    ArenaLog('betting: match %s paid out %s of a %s pot to %d player(s) (%s), house kept %s.',
        tostring(matchId), money(distributed), money(pot), #payouts,
        tostring(Config.Betting.payout or 'winner_takes_all'), money(houseCut))

    local paidFrom, citizenOf, nameOf = {}, {}, {}
    for id, stake in pairs(stakesOf(matchId)) do
        paidFrom[id] = stake.account
        citizenOf[id] = stake.citizenid
        nameOf[id] = stake.name
    end

    settling[matchId] = true

    local lines, undelivered = {}, 0
    for _, payout in ipairs(payouts) do
        local amount = math.max(0, Arena.ToInt(payout.amount) or 0)
        local winner = serverId(payout.id)
        if amount > 0 then
            -- PAID TO THE CHARACTER WHO STAKED, not to whoever holds the
            -- server id when the round ends. Every other credit in this file
            -- passes a citizen id and `credit` refuses when it does not
            -- match; this one passed nil, so winning a round and switching
            -- character before it ended paid the pot into the character who
            -- had just taken over the id. A way to move money between your
            -- own characters, through the arena, with no record of it.
            --
            -- A refusal is not a loss: it falls through to the unpaid ledger
            -- below, filed against the citizen id that actually won, and is
            -- paid when they are next seen. DO NOT pass nil here.
            if winner and credit(winner, amount, transaction('payout', matchId),
                citizenOf[winner] or citizenOf[payout.id],
                paidFrom[winner] or paidFrom[payout.id]) then
                lines[#lines + 1] = ('%s: %s (%s)'):format(ArenaPlayerName(winner), money(amount), tostring(payout.reason))
                trace('paid %d to %s on match %s (%s)',
                    amount, tostring(winner), tostring(matchId), tostring(payout.reason))
                ArenaNotifyKey(winner, 'notify.pot_won', 'success', money(amount))
            else
                undelivered = undelivered + amount

                local citizenid = citizenOf[payout.id] or citizenIdOf(payout.id)
                if owe(citizenid, payout.name or nameOf[payout.id] or payout.id, amount,
                    paidFrom[payout.id], 'pot_payout') then
                    ArenaLog('PAYOUT UNDELIVERED: %d owed to %s (citizenid %s) on match %s -- they are not on the server. It is on the unpaid ledger and will be paid when they come back; /arenaadmin can list it.',
                        amount, tostring(payout.id), tostring(citizenid), tostring(matchId))
                else
                    ArenaLog('PAYOUT LOST: %d owed to %s on match %s -- they are not on the server and there is no citizen id to file it against. Settle by hand.',
                        amount, tostring(payout.id), tostring(matchId))
                end
                incidentWebhook('Payout not delivered', 'A settled payout could not be paid to its winner.', {
                    { name = 'Match', value = tostring(matchId) },
                    { name = 'Player', value = tostring(payout.id) },
                    { name = 'Amount', value = money(amount) },
                })
            end
        end
    end

    -- SETTLED AFTER THE MONEY MOVED, NEVER BEFORE.
    --
    -- This ran above the payout loop, so every stake was marked paid before
    -- the first credit went out. The mark exists to stop a SECOND payout, and
    -- setting it first inverted it: anything that stopped the loop part-way
    -- -- and the two calls it makes into the framework were the only
    -- unwrapped ones in this file until now -- left the winners below it
    -- unpaid, unrecorded on the unpaid ledger, and unpayable, because the pot
    -- they were owed was already settled on the books. The money simply
    -- vanished, with a log line saying it had been paid.
    --
    -- Below the loop, the loop has either finished or it has not, and an
    -- unfinished one leaves the stakes unsettled -- which is the state every
    -- refund and retry path in this file already knows how to read.
    for _, stake in pairs(stakesOf(matchId)) do
        if not stake.settled then
            stake.settled = true
            stake.settledAs = 'payout'
        end
    end

    payoutWebhook('Pot paid out', ('%d payout(s) from a pot of %s.'):format(#payouts, money(pot)), {
        { name = 'Match', value = tostring(matchId) },
        { name = 'Pot', value = money(pot) },
        { name = 'House cut', value = money(houseCut) },
        { name = 'Undelivered', value = money(undelivered) },
        { name = 'Payouts', value = #lines > 0 and table.concat(lines, '\n') or 'none' },
    })

    return payouts
end

function ArenaBetting.GetSideBetPool(matchId)
    local total = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.settled ~= true and bet.mode ~= 'odds' then
            total = total + (Arena.ToInt(bet.amount) or 0)
        end
    end
    return total
end

function ArenaBetting.GetPrizePool(matchId)
    local pot = ArenaBetting.GetPot(matchId)
    if not entryPotJoinsPool() then return pot end
    return pot + ArenaBetting.GetSideBetPool(matchId)
end

--- One player's own side-bet on a match, or nil.
---
--- THE PANEL COULD NOT SEE ITS OWN BET. Side-bets are kept in this file and
--- nothing carried them into the snapshot, so a player who placed one
--- watched their money leave and the screen say nothing: no stake, no side,
--- no way to tell a bet that was taken from one that was refused. The pot on
--- that screen is the ENTRY pot and deliberately does not move for a
--- side-bet -- two pools, and conflating them is its own confusion -- which
--- left nothing at all to change.
--- @param matchId string
--- @param src any
--- @return table|nil -- { amount, pick, kind, account }
function ArenaBetting.GetSideBet(matchId, src)
    local id = serverId(src)
    if not id then return nil end

    local citizenid = citizenIdOf(id)
    for _, bet in ipairs(sideBets[matchId] or {}) do
        -- The one they CHOSE. An entry fee folded into the pool at settle
        -- time is not a bet they placed and must not be shown as one.
        -- AND NOT ONE THAT HAS ALREADY BEEN SETTLED. returnSideBet does not
        -- delete a row, it marks it -- `bet.settled = true` -- so a bet that
        -- has been handed back was still reported here as money on the
        -- result. ArenaLobby.UpdateMatch used to return every side-bet when
        -- the host changed the mode, and the panel then went on printing "You
        -- have $500 on crimson." over a stake that was back in the player's
        -- wallet, backing a side the match no longer has. That refund is gone
        -- -- the mode change is refused instead -- but a bet still comes back
        -- through half a dozen other doors, and this is the check that keeps
        -- the panel honest about every one of them.
        if betIsHeldBy(bet, id, citizenid) and not bet.settled and bet.fromEntryFee ~= true then
            return {
                amount = bet.amount,
                pick = bet.pick,
                kind = bet.kind,
                account = bet.account,
            }
        end
    end
    return nil
end

function ArenaBetting.HoldsSideBet(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false end
    return holdsSideBet(matchId, id)
end

--- Every match this player currently has an unsettled side-bet on.
---
--- THE PANEL CANNOT WORK THIS OUT FOR ITSELF. `player.bet` in the snapshot
--- reports one bet -- the one on the match they are IN or WATCHING -- and a
--- side-bet is placed from the Bets tab on a match they are doing neither
--- with. So the Join button on a match the player had money on stayed lit,
--- and clicking it came back "Fighters do not bet on themselves.", which is
--- not what they did and not why they were refused.
---
--- An array rather than one id: one bet per match is a rule, one bet per
--- PLAYER is not, and a player watching the board can have money on several
--- lobbies at once.
--- @param src any
--- @return string[] matchIds
function ArenaBetting.MatchesBackedBy(src)
    local id = serverId(src)
    local out = {}
    if not id then return out end

    -- READ ONCE, OUTSIDE BOTH LOOPS. It reaches into the framework for the
    -- player, and this walks every match on the server.
    local citizenid = citizenIdOf(id)

    for matchId, bets in pairs(sideBets) do
        for _, bet in ipairs(bets) do
            if betIsHeldBy(bet, id, citizenid) and not bet.settled and bet.fromEntryFee ~= true then
                out[#out + 1] = matchId
                break
            end
        end
    end
    return out
end

function ArenaBetting.HasSpectatorBet(matchId, src)
    local id = serverId(src)
    if not id then return false end
    local citizenid = citizenIdOf(id)
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if betIsHeldBy(bet, id, citizenid) and not bet.settled then return true end
    end
    return false
end

local function payoutMode(kind)
    local block = Config.Betting.betPayout
    local wanted = type(block) == 'table'
        and block[kind == 'fighter' and 'fighters' or 'spectators']
        or nil
    return wanted == 'odds' and 'odds' or 'pool'
end

local function fighterBetsOn()
    local block = Config.Betting.fighterBets
    return type(block) == 'table' and block.enabled == true
end

local function spectatorCeiling()
    local rules = Config.Betting.spectatorBets
    if type(rules) ~= 'table' or rules.enabled ~= true then return nil end

    local minimum = math.max(0, Arena.ToInt(rules.min) or 0)
    return math.max(minimum, Arena.ToInt(rules.max) or minimum)
end

local function ownSideOf(match, src)
    local row = type(match.players) == 'table' and match.players[src] or nil
    if not row then return nil end
    if Arena.ModeUsesTeams(match.modeKey) and Arena.IsKey(row.team) then return row.team end
    return tostring(src)
end

local function voided(bet, fighters)
    -- NOT ON THE FINAL ROSTER, WHICH IS TWO DIFFERENT PEOPLE.
    --
    -- A spectator who never joined, judged on the pick they chose -- which is
    -- what this line was written for -- and a FIGHTER who placed a bet at the
    -- fighter band and then came off the roster, who was judged on the same
    -- terms and should not have been. That second one was a live exploit:
    -- fighterBets.max ships at twice spectatorBets.max, so a fighter could
    -- take a 50,000 position, walk out of the lobby for nothing, and settle
    -- it against a field nobody else could put more than 25,000 into.
    --
    -- THE ANSWER IS NOT HERE, and deliberately so. Voiding it would hand the
    -- stake back, which is the exact refund ArenaBetting.MarkWalkedOut exists
    -- to withhold -- a wager you can cancel once it is going badly is not a
    -- wager. And trimming it here is too late: the pools above have already
    -- been totalled and every winner's share is a proportion of them, so
    -- shrinking a stake at settlement would move other people's money.
    --
    -- So the band is enforced at the moment the fact changes instead.
    -- MarkWalkedOut trims the stake to what a non-fighter may hold, returns
    -- the difference, and re-files the bet as a spectator's. By the time this
    -- runs there is nothing left to correct, and this line is once again
    -- about the only person it was ever about.
    local row = fighters[bet.src]
    if not row then return false end

    if bet.fromEntryFee == true then return false end

    if not fighterBetsOn() then return true end
    if (Config.Betting.fighterBets or {}).ownSideOnly == false then return false end

    local team = type(row) == 'table' and row.team or nil
    local own = Arena.IsKey(team) and team or tostring(bet.src)
    return bet.pick ~= own
end

local function poolKeyFor(kind)
    local block = Config.Betting.betPayout
    if type(block) == 'table' and block.sharedPool == false then return kind end
    return 'all'
end

function ArenaBetting.PlaceSpectatorBet(src, matchId, pick, amount, account)
    if not ArenaBetting.IsEnabled() then return false, 'error.betting_disabled' end

    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return false, 'error.bet_invalid' end

    local match = lobbyMatch(matchId)
    if not match then return false, 'error.match_not_found' end

    local isFighter = type(match.players) == 'table' and match.players[id] ~= nil
    if isFighter and not fighterBetsOn() then
        return false, 'error.bet_not_spectator'
    end

    -- THE AMOUNT IS CHECKED AGAINST THE RIGHT BAND, which means it cannot be
    -- checked until we know which kind of bet this is.
    --
    -- It used to be resolved at the top of this function, before `isFighter`
    -- existed, and always against Config.Betting.spectatorBets. Every other
    -- rule below already picks the right block -- ownSideOnly and
    -- oneBetPerMatch both do -- and the amount was the one that did not. On
    -- the shipped config that refused every fighter stake over 25,000 while
    -- the panel, which is sent fighterBets.max, was offering 50,000; and
    -- with spectatorBets switched off it refused fighter bets entirely,
    -- with a message about side-bets being off.
    --
    -- WRITTEN AS AN IF RATHER THAN `isFighter and X or Y`, deliberately.
    -- That idiom collapses to Y whenever X is nil -- which here is exactly
    -- the refused-bet case -- so a fighter over their band would have
    -- silently fallen through to the spectator check. It is the single
    -- commonest defect in this codebase and it is not worth being clever
    -- about.
    local stake, reason
    if isFighter then
        stake, reason = Arena.ResolveFighterBet(amount)
    else
        stake, reason = Arena.ResolveSpectatorBet(amount)
    end
    if not stake then return false, reason or 'error.bet_invalid' end

    -- A FIGHTER WHO WALKED OUT IS NOT A WATCHER, whatever the roster says,
    -- and the roster CANNOT say otherwise -- it no longer holds them.
    -- `isFighter` above reads match.players, which no longer holds them --
    -- see MarkWalkedOut. Asked here rather than folded into `isFighter`
    -- because they really are no longer a fighter for every OTHER rule in
    -- this function: the band, the own-side test and the one-bet limit are
    -- all a departed player's spectator ones. This is the single question
    -- their old seat still answers.
    local walkedOut = (walkedOutOf[matchId] or {})[id] == true

    if not betsAreOpen(match, isFighter or walkedOut) then return false, 'error.bets_closed' end

    local wanted = canonicalPick(pick)
    if not wanted or not pickExists(match, wanted) then return false, 'error.bet_invalid_pick' end

    -- A FIGHTER MAY ONLY BACK THEIR OWN SIDE, when the operator says so.
    -- Backing the other side is a way to be paid for losing on purpose, and
    -- an arena is exactly where that is worth doing.
    if isFighter and (Config.Betting.fighterBets or {}).ownSideOnly ~= false then
        local own = ownSideOf(match, id)
        if own and wanted ~= own then return false, 'error.bet_not_own_side' end
    end

    local rules = isFighter and (Config.Betting.fighterBets or {})
        or (Config.Betting.spectatorBets or {})
    if rules.oneBetPerMatch ~= false and ArenaBetting.HasSpectatorBet(matchId, id) then
        return false, 'error.bet_already_placed'
    end

    local took, paidFrom = debit(id, stake, transaction('sidebet', matchId), account)
    if not took then
        return false, 'error.not_enough_money'
    end

    local kind = isFighter and 'fighter' or 'spectator'

    sideBets[matchId] = sideBets[matchId] or {}
    sideBets[matchId][#sideBets[matchId] + 1] = {
        src = id,
        citizenid = citizenIdOf(id),
        name = ArenaPlayerName(id),
        pick = wanted,
        amount = stake,
        account = paidFrom,
        kind = kind,
        mode = payoutMode(kind),
        placedAt = os.time(),
        settled = false,
    }

    trace('took side-bet of %d from %s on "%s" in match %s',
        stake, tostring(id), wanted, tostring(matchId))
    ArenaNotifyKey(id, 'notify.spectator_bet_placed', 'info', money(stake))

    -- THE ONE MONEY MOVEMENT THAT NEVER REFRESHED THE PANEL. Everything else
    -- that takes or returns money runs through a lobby path that broadcasts
    -- afterwards; a side-bet is placed from the Bets tab and settled here,
    -- and nothing told anyone. So the bettor was left reading their balance
    -- from before the bet and a pot that did not include it, until some
    -- unrelated change to the lobby happened to refresh them.
    --
    -- Guarded the way lobbyMatch above guards: this file loads before
    -- server/lobby.lua, so the global is checked rather than assumed.
    if type(ArenaLobby) == 'table' and type(ArenaLobby.Broadcast) == 'function' then
        ArenaLobby.Broadcast()
    end

    return true, nil
end

--- How many unsettled side-bets are riding on this match.
---
--- THE BOOK, AS A NUMBER, so a caller that must not change the shape of a
--- match under the people who backed it can ask whether anybody has.
---
--- IT REPLACED A REFUND, and the refund was the defect. ArenaLobby.UpdateMatch
--- used to hand the WHOLE BOOK back whenever the host changed the mode --
--- correct on its own, because a bet naming a side the match no longer has
--- cannot be judged -- but the host is a fighter with money on the outcome
--- and flipping the mode cost them nothing and could be done again a second
--- later. That is a "cancel everyone's bets" button, theirs alone, pressable
--- the moment the book turns against them. Nothing had to be exploited; it
--- was simply what the setting did.
---
--- So the mode is refused instead, and this is the question that refuses it.
--- An honest host -- an open lobby nobody has backed -- gets the same free
--- hand they always had, because the answer is zero.
---
--- Entry-fee rows are not bets anybody placed and are not counted. Settle
--- writes them at the moment the round is decided, so one cannot exist while
--- a lobby is still editable anyway.
--- @param matchId string
--- @return integer
function ArenaBetting.CountSideBets(matchId)
    local count = 0
    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled and bet.fromEntryFee ~= true then count = count + 1 end
    end
    return count
end

--- Marks every unsettled bet this player is holding on this match as one
--- placed by somebody who then walked out of it.
---
--- WHAT IT IS FOR, AND IT IS A HOLE THE REFUND BELOW OPENS RATHER THAN ONE
--- IT FOUND. A fighter backing themselves picks their own server id, so
--- their bet and a spectator's bet on them name the SAME pick. Returning
--- everything on that pick when they leave hands the fighter their own wager
--- back -- and a wager you can cancel once it is going badly is not a wager,
--- it is free money with an exit. `fighterBets` ships ON, so that is the
--- default configuration.
---
--- The spectator's case is the exact opposite, and is the reason the refund
--- exists: their pick died through somebody else's act, with nothing they
--- could have done about it. This is the one line that tells the two apart.
---
--- MARKED RATHER THAN SETTLED. The bet is still live and still judged at
--- settlement the way it always was -- the holder is no longer a fighter, so
--- `voided` passes it through, and a pick that did not win loses. All this
--- withholds is the refund.
---
--- It also closes the second departure: two players on one side who both
--- backed it, both leaving, would otherwise see the first one's bet returned
--- when the second emptied the side.
---
--- AND IT IS WHERE THE FIGHTER BAND LAPSES, which is the other half of the
--- same fact and was missing for as long as fighter bets have existed.
---
--- A fighter's stake is held to Config.Betting.fighterBets, which ships at
--- TWICE the spectator ceiling. That is not a bonus, it is the price of being
--- in the fight: the money is riding on a round the holder has to stand up
--- in. Take the holder off the roster and every reason for the larger number
--- goes with them -- but the stake did not move, and nothing re-read the
--- band, so a fighter could put down 50,000, walk out of the lobby for
--- nothing (the shipped entry fee is zero), and settle a fighter-sized
--- position against a field capped at 25,000. On the shipped config that paid
--- the leaver the honest spectator's whole stake.
---
--- TRIMMED, NOT VOIDED. Handing the bet back is the refund the whole function
--- exists to withhold. What is returned is only the part the fighter band
--- alone ever justified; what is left is a position any onlooker could have
--- taken, judged on the pick the holder chose, and it still loses if that
--- pick loses. Exactly the bet PlaceSpectatorBet would have written for them
--- one second after they left.
---
--- AND RE-FILED AS A SPECTATOR'S, because standing is what changed. With
--- betPayout.sharedPool off the two kinds settle in separate pools, and a
--- lone walked-out fighter left in the fighters' pool is the only bet in it
--- -- uncontested -- so SettleSpectatorBets hands the whole thing back and
--- undoes the trim. `mode` is deliberately NOT touched: that is who funds the
--- payout, which was agreed when the stake was taken, and changing it after
--- the fact would move a pool bet onto the operator's own money.
---
--- THE MONEY MOVES FIRST AND THE RECORD FOLLOWS. `bet.amount` is only cut
--- once the difference has actually been credited, or failing that filed
--- against the character on the unpaid ledger. A trim recorded over money
--- that went nowhere is money this resource has quietly destroyed.
--- @param matchId string
--- @param src any
--- @return integer marked
--- @return integer returned -- money handed back because the band lapsed
function ArenaBetting.MarkWalkedOut(matchId, src)
    local id = serverId(src)
    if not id or not Arena.IsKey(matchId) then return 0, 0 end

    -- WRITTEN DOWN FIRST, AND WRITTEN DOWN FOR PEOPLE HOLDING NO BET AT ALL.
    --
    -- This is the only moment anything is told that a fighter left, and by
    -- the time it runs ArenaLobby.Leave has already dropped their roster row
    -- -- so if it is not recorded here, nothing afterwards can tell a
    -- departed fighter from somebody who wandered up to watch. What that
    -- cost: the walker was handed the WATCHER's grace period on the round
    -- they had just abandoned, and could bet on it up to
    -- spectatorBets.closeAfterStartSeconds after the start, having been
    -- refused a second earlier while standing in it.
    --
    -- Above the loop, because the loop only ever visits their BETS and this
    -- has to be true of a fighter who never placed one. DO NOT fold it in.
    local match = lobbyMatch(matchId)
    if match and roundIsBeingFought(match) then
        walkedOutOf[matchId] = walkedOutOf[matchId] or {}
        walkedOutOf[matchId][id] = true
    end

    local ceiling = spectatorCeiling()
    local marked, returned = 0, 0

    for _, bet in ipairs(sideBets[matchId] or {}) do
        if bet.src == id and not bet.settled and bet.fromEntryFee ~= true then
            bet.walkedOut = true
            marked = marked + 1

            if bet.kind == 'fighter' then
                if ceiling == nil then
                    local whole = Arena.ToInt(bet.amount) or 0
                    if returnSideBet(bet, matchId) then
                        returned = returned + whole
                        ArenaLog('SIDE-BET BAND LAPSED: %s left match %s and this server allows non-fighters no side-bet at all -- the whole %d went back.',
                            tostring(bet.name or id), tostring(matchId), whole)
                    end
                else
                    local held = Arena.ToInt(bet.amount) or 0
                    local excess = held - ceiling
                    if excess > 0 then
                        local paid = credit(id, excess, transaction('sidebet_trim', matchId),
                            bet.citizenid, bet.account)
                        if paid then
                            ArenaNotifyKey(id, 'notify.bet_trimmed', 'info', money(excess))
                        else
                            paid = owe(bet.citizenid, bet.name or id, excess, bet.account, 'sidebet_trim')
                            if paid then
                                ArenaLog('SIDE-BET TRIM DEFERRED: %d owed to %s (citizenid %s) on match %s -- recorded against their character and paid when they are next seen.',
                                    excess, tostring(bet.name or id), tostring(bet.citizenid), tostring(matchId))
                            end
                        end

                        if paid then
                            bet.amount = ceiling
                            returned = returned + excess
                            ArenaLog('SIDE-BET TRIMMED: %s left match %s holding a fighter stake of %d; the fighter band went with them, so %d was returned and %d stands as a spectator bet.',
                                tostring(bet.name or id), tostring(matchId), held, excess, ceiling)
                        else
                            ArenaLog('SIDE-BET TRIM FAILED: %d could not be returned to %s (citizenid %s) on match %s -- the bet stands at its full %d and is still held to the fighter band.',
                                excess, tostring(bet.name or id), tostring(bet.citizenid), tostring(matchId), held)
                            incidentWebhook('Side-bet band could not be trimmed',
                                'A fighter left a match holding a stake above the spectator ceiling and the difference could not be returned.', {
                                    { name = 'Match', value = tostring(matchId) },
                                    { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or id), tostring(bet.citizenid)) },
                                    { name = 'Held', value = money(held) },
                                    { name = 'Over the ceiling by', value = money(excess) },
                                })
                        end
                    end

                    bet.kind = 'spectator'
                end
            end
        end
    end

    return marked, returned
end

--- Returns every outstanding side-bet on one pick, because that pick can no
--- longer win.
---
--- THE SAME UNFAIRNESS AS A MODE CHANGE, ARRIVING BY A DIFFERENT DOOR.
--- Changing the mode of a lobby leaves every bet on it naming something that
--- cannot win, and such a bet must not simply lose: there is nothing on
--- screen saying so and no way for the bettor to have seen it coming. That
--- one is answered by refusing the change now -- see CountSideBets -- because
--- a host who could void the book on demand was worse than the loss. This
--- door cannot be refused the same way.
---
--- A FIGHTER WALKING OUT does exactly the same thing to the people who
--- backed them, and nothing was returning those. The bet was not voided and
--- not refunded -- it fell through every branch of SettleSpectatorBets to
--- the last `else` and was marked `lost`, and on the shipped config
--- (sharedPool, includeEntryPot) the pool is contested by the remaining
--- fighters' own entry fees, so the uncontested-pool refund could not catch
--- it either. The spectator's whole stake -- up to `spectatorBets.max` --
--- was handed to whoever backed the winner, and the only thing they were
--- told was "your pick went down", which is not what happened.
---
--- It is also the shape of a scam that runs itself: open a lobby with a
--- friend, talk the room into backing them, have them walk before the start,
--- win, collect. Nothing in the resource had to be exploited for that to
--- work; it was simply how a departed pick settled.
---
--- Entry-fee rows are skipped. They are written by Settle at the moment the
--- round is decided and cannot exist while somebody is still leaving -- but
--- one is a stake escrowed in the pot rather than a bet anybody placed, and
--- handing it back here would take money out of a pot the survivors are
--- fighting for.
--- @param matchId string
--- @param pick any -- a team key, or a fighter's server id as a string
--- @return integer returned
--- @return integer owed -- money that could not be handed back
function ArenaBetting.ReturnBetsOn(matchId, pick)
    local returned, owed = 0, 0
    if not Arena.IsKey(matchId) or pick == nil then return 0, 0 end

    local wanted = canonicalPick(pick)
    if not wanted then return 0, 0 end

    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled and bet.fromEntryFee ~= true and bet.walkedOut ~= true
            and bet.pick == wanted then
            if returnSideBet(bet, matchId) then
                returned = returned + 1
            else
                owed = owed + (Arena.ToInt(bet.amount) or 0)
            end
        end
    end

    return returned, owed
end

--- Settles every side-bet on a match. Winners are paid
--- `Arena.ComputeSpectatorPayout` (their stake included in it); losers are
--- kept by the house.
---
--- A nil `winningPick` means the match produced no result at all. There is
--- nothing to judge a bet against then, so the house has no claim on it and
--- every bet is returned rather than swallowed.
---
--- A BET HELD BY A FIGHTER IS RE-JUDGED, not automatically void. With
--- fighterBets on, backing your own side is a bet like any other and is
--- settled out of the pool; backing the OTHER side is being paid to lose on
--- purpose, and goes back unjudged. With fighterBets off, any bet held by a
--- fighter is void -- the original rule, unchanged.
---
--- Checked here as well as at placement because the placement check alone is
--- defeated by doing the two things in the other order: bet on the side you
--- are about to fight against, then join. This is the check that cannot be
--- ordered around, because it runs where the money moves and reads the
--- roster as it finally stood. See `voided` for the rule itself.
--- WHAT IT PAID, PER PLAYER, is the third return and it is not a
--- convenience. With betPayout.includeEntryPot on -- which is how this ships
--- -- ArenaBetting.Settle hands the entry stakes to this function and returns
--- an EMPTY payout list, so every downstream reader of that list saw a match
--- where nobody was paid anything. The winner's own results board said they
--- earned nothing while the money landed in their account, and the all-time
--- leaderboard recorded zero earnings for everybody, for ever, on the default
--- configuration. This is the number those two have to read instead.
---
--- WON BETS ONLY. A refund is a player's own stake handed back -- including
--- the uncontested-pool refund above -- and has never counted as earnings.
--- @param matchId string
--- @param winningPick any -- team key, winning fighter's server id, or nil
--- @return integer paid -- winning bets settled
--- @return integer total -- money paid out
--- @return table<integer, integer> earnings -- { [src] = won }, refunds excluded
function ArenaBetting.SettleSpectatorBets(matchId, winningPick)
    local bets = sideBets[matchId]
    if type(bets) ~= 'table' then return 0, 0, {} end

    -- ONCE PER MATCH, AND THIS HAD NO GUARD AT ALL.
    --
    -- ArenaBetting.Settle has refused a second payout since the day the pot
    -- loop was moved below its payments; this function, which is where the
    -- pot is actually paid on the shipped config, had nothing. Every branch
    -- below marks a bet settled AFTER the money moves -- on purpose, and the
    -- note over the credit says why -- so a run that dies part-way leaves
    -- winners it has already paid reading as unsettled, and a second run
    -- pays them again. Measured: 15,000 paid twice out of a 15,000 pot.
    --
    -- The second run is not hypothetical. ArenaMatch.Abort calls this after
    -- ArenaMatch.End has already called it, on any teardown that follows a
    -- settle.
    --
    -- RAISED BEFORE THE FIRST PAYMENT, deliberately, and it is the same
    -- trade Settle makes: a book whose settlement did not finish stays
    -- REFUSED rather than being silently re-run. What is left is on the
    -- books, loud, and Clear will not drop the match while it is there.
    -- DO NOT move this below the loop to make a retry possible.
    if sideSettled[matchId] then
        ArenaLog('betting: the side-bet book on match %s was asked to settle a SECOND time and was '
            .. 'refused. Every bet it paid the first time still reads unsettled if that run did not '
            .. 'finish, so settling again would pay those winners twice. Nothing has been paid. '
            .. 'Look above this line for what stopped the first run.', tostring(matchId))
        return 0, 0, {}
    end
    sideSettled[matchId] = true

    local fighters = fightersOf(matchId) or {}
    local wanted = canonicalPick(winningPick)
    local paid, total, kept, lines = 0, 0, 0, {}
    local earnings = {}

    -- THE POOLS, built before anything is paid.
    --
    -- A pool bet is paid with other bettors' money and nothing else, so the
    -- pool has to be known in full before the first payment leaves -- and the
    -- winners' stakes with it, because a share is a proportion of the whole.
    -- Working it out as we go would pay the first winner out of a pool that
    -- had not finished being counted.
    --
    -- 'odds' bets are deliberately absent from both. They are funded by the
    -- server, so letting one into the pool would pay it out of other people's
    -- stakes as well as the operator's pocket.
    local pools, winners, backed = {}, {}, {}
    for _, bet in ipairs(bets) do
        if not bet.settled and bet.mode ~= 'odds' and not voided(bet, fighters) then
            local key = poolKeyFor(bet.kind or 'spectator')
            local stake = Arena.ToInt(bet.amount) or 0
            pools[key] = (pools[key] or 0) + stake

            if wanted and bet.pick == wanted then
                winners[key] = winners[key] or {}
                winners[key][#winners[key] + 1] = bet
                backed[key] = (backed[key] or 0) + stake
            end
        end
    end

    local uncontested = {}
    for key, pool in pairs(pools) do
        if (backed[key] or 0) >= pool then uncontested[key] = true end
    end

    for key, pool in pairs(pools) do
        local list = winners[key]
        if list and #list > 0 then
            local stakes = {}
            for index, bet in ipairs(list) do stakes[index] = bet.amount end
            local shares = Arena.SplitByStake(pool, stakes)
            for index, bet in ipairs(list) do bet.poolShare = shares[index] or 0 end
        end
    end

    for _, bet in ipairs(bets) do
        if not bet.settled then
            if voided(bet, fighters) then
                ArenaLog('SIDE-BET VOID: %s backed "%s" on match %s and then fought in it -- returning %d unjudged.',
                    tostring(bet.name or bet.src), tostring(bet.pick), tostring(matchId), bet.amount)
                returnSideBet(bet, matchId)
            elseif not wanted then
                returnSideBet(bet, matchId)
            elseif bet.mode ~= 'odds' and uncontested[poolKeyFor(bet.kind or 'spectator')] then
                ArenaLog('SIDE-BET UNCONTESTED: nobody bet against %s on match %s -- returning %d.',
                    tostring(bet.name or bet.src), tostring(matchId), bet.amount)
                returnSideBet(bet, matchId)
            elseif bet.pick == wanted and not bet.forfeited then
                -- AND NOT FORFEITED, which is belt to a brace held in another
                -- file. An entry stake that walked out carries the flag onto
                -- the bet it becomes, and a walker's `pick` is their bare
                -- server id -- which matches no team and no winner, because
                -- ArenaLobby drops them from the roster in the same breath as
                -- forfeiting them. That is the only thing standing between a
                -- forfeited stake and this payout, and it is an invariant in
                -- a file this one cannot see. DO NOT rely on it alone.
                local amount = (bet.mode == 'odds')
                    and Arena.ComputeSpectatorPayout(bet.amount)
                    or (Arena.ToInt(bet.poolShare) or 0)
                -- SETTLED AFTER THE MONEY MOVED, the way the pot is.
                --
                -- This marked first, on the argument that a settlement which
                -- runs twice must not pay twice -- but the pot loop was moved
                -- below its payments for the opposite and stronger reason: a
                -- mark set first turns any failure between here and the
                -- credit into money that is recorded as paid, filed nowhere,
                -- and unpayable afterwards. `credit` reaches into the
                -- framework, and the arena would rather risk a second attempt
                -- it can see than a silent loss it cannot. DO NOT move the
                -- mark back above the payment.
                --
                -- AND THE TOTALS COUNT ONLY WHAT WENT SOMEWHERE. `earnings`
                -- is handed to the match and read back to the player as their
                -- winnings, and it was incremented before anything moved --
                -- so an undeliverable payout was still announced to them as
                -- money they had won.
                local delivered = amount <= 0

                if amount > 0 then
                    if credit(bet.src, amount, transaction('sidebet_payout', matchId),
                        bet.citizenid, bet.account) then
                        delivered = true
                        lines[#lines + 1] = ('%s: %s on "%s"'):format(tostring(bet.name or bet.src), money(amount), bet.pick)
                        ArenaNotifyKey(bet.src,
                            bet.fromEntryFee == true and 'notify.pot_won' or 'notify.spectator_bet_won',
                            'success', money(amount))
                    elseif owe(bet.citizenid, bet.name or bet.src, amount, bet.account, 'sidebet_payout') then
                        -- READ, NOT ASSUMED. `owe` refuses when there is no
                        -- citizen id to file against, and this ignored the
                        -- answer and logged that the money was safe on the
                        -- ledger either way. The pot loop tells the truth
                        -- about the same failure. DO NOT promise a filing
                        -- that did not happen.
                        delivered = true
                        ArenaLog('SIDE-BET PAYOUT UNDELIVERED: %d owed to %s (citizenid %s) on match %s. It is on the unpaid ledger and will be paid when they come back.',
                            amount, tostring(bet.name or bet.src), tostring(bet.citizenid), tostring(matchId))
                        incidentWebhook('Side-bet payout not delivered',
                            'A winning spectator side-bet could not be paid.', {
                                { name = 'Match', value = tostring(matchId) },
                                { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                                { name = 'Amount', value = money(amount) },
                            })
                    else
                        ArenaLog('SIDE-BET PAYOUT LOST: %d owed to %s on match %s -- they are not on the server and there is no citizen id to file it against. Settle by hand.',
                            amount, tostring(bet.name or bet.src), tostring(matchId))
                        incidentWebhook('Side-bet payout lost',
                            'A winning spectator side-bet could be neither paid nor filed.', {
                                { name = 'Match', value = tostring(matchId) },
                                { name = 'Player', value = ('%s (%s)'):format(tostring(bet.name or bet.src), tostring(bet.citizenid)) },
                                { name = 'Amount', value = money(amount) },
                            })
                    end
                end

                bet.settled = true
                bet.settledAs = 'won'
                paid = paid + 1

                if delivered then
                    total = total + amount
                    earnings[bet.src] = (earnings[bet.src] or 0) + amount
                end
            elseif bet.mode ~= 'odds' and not (winners[poolKeyFor(bet.kind or 'spectator')] or {})[1] then
                returnSideBet(bet, matchId)
            else
                bet.settled = true
                bet.settledAs = 'lost'
                if bet.mode == 'odds' then kept = kept + bet.amount end
                ArenaNotifyKey(bet.src,
                    bet.fromEntryFee == true and 'notify.stake_forfeited' or 'notify.spectator_bet_lost',
                    'error', money(bet.amount))
            end
        end
    end

    if paid > 0 or kept > 0 then
        trace('settled side-bets on match %s: %d winner(s) paid %d, %d kept',
            tostring(matchId), paid, total, kept)
        payoutWebhook('Side-bets settled', ('Winning pick: %s'):format(tostring(wanted)), {
            { name = 'Match', value = tostring(matchId) },
            { name = 'Paid out', value = money(total) },
            { name = 'Kept', value = money(kept) },
            { name = 'Winners', value = #lines > 0 and table.concat(lines, '\n') or 'none' },
        })
    end

    return paid, total, earnings
end

function ArenaBetting.PayOutstanding(src)
    local id = serverId(src)
    if not id then return 0 end

    local player = ArenaGetPlayer(id)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil
    if not Arena.IsKey(citizenid) then return 0 end

    local row = unpaid[citizenid]
    if not row then return 0 end

    local paid, left = 0, {}
    for _, part in ipairs(row.parts) do
        if credit(id, part.amount, transaction(part.reason or 'refund_owed', 'owed'),
            citizenid, part.account) then
            paid = paid + part.amount
            -- THE ROW GOES WITH THE PART. Dropped from memory alone, the
            -- next restart reads the settled debt straight back in and pays
            -- it a second time -- which is the same mistake, one table over,
            -- that the DELETE warning in sql/install.sql is about. DO NOT
            -- drop a part from `parts` anywhere without deleting its row.
            dropUnpaidPart(citizenid, part.key)
        else
            left[#left + 1] = part
        end
    end

    if paid > 0 then
        ArenaLog('betting: paid %s of money owed to %s (citizenid %s) that could not be delivered earlier.',
            money(paid), tostring(row.name or id), tostring(citizenid))
        ArenaNotifyKey(id, 'notify.stake_refunded', 'info', money(paid))
    end

    if #left > 0 then
        row.parts = left
        row.total = 0
        for _, part in ipairs(left) do row.total = row.total + part.amount end
    else
        unpaid[citizenid] = nil
    end

    return paid
end

function ArenaBetting.SweepUnpaid()
    -- BEFORE THE EARLY RETURN, NOT AFTER. A drop still outstanding is a debt
    -- the DATABASE believes in, and it survives the last part being paid out
    -- of memory -- which is exactly when `unpaid` is empty. Putting this
    -- below the test would switch the replay off in the one state it exists
    -- for: everything paid, nothing owed, and a row still sitting in the
    -- table waiting for the next restart to pay it again. DO NOT move this
    -- under the early return.
    replayDrops()

    if next(unpaid) == nil then return 0, 0 end

    local people, total = 0, 0
    for _, id in ipairs(GetPlayers()) do
        local src = Arena.ToInt(id)
        if src then
            local paid = ArenaBetting.PayOutstanding(src)
            if paid > 0 then
                people = people + 1
                total = total + paid
            end
        end
    end
    return people, total
end

function ArenaBetting.Outstanding()
    local characters, total = 0, 0
    for _, row in pairs(unpaid) do
        characters = characters + 1
        total = total + (row.total or 0)
    end
    return characters, total
end

--- ONE ATTEMPT AT START IS NOT ENOUGH, and this is why it is a thread of
--- its own rather than a line in the sweep below. `ensure crimson_arena`
--- above `ensure oxmysql` in a server.cfg is an ordinary mistake, at which
--- point a single read at load never happens, every debt from previous runs
--- sits in the table unread, and new ones begin writing fine the moment
--- oxmysql comes up -- a working table full of rows nothing will ever pay.
--- The sweep below is ALSO the wrong place for it: it is switched off
--- entirely by refundRetrySeconds = 0, and whether the ledger is read has
--- nothing to do with how often it is swept. DO NOT fold this into it.
CreateThread(function()
    -- WRAPPED FOR THE SAME REASON THE WRITES ARE. A throw here would end
    -- the retry for the life of the process, which is the one thing this
    -- loop exists to prevent. DO NOT unwrap it.
    while true do
        local ok, loaded = pcall(loadUnpaid)
        if ok and loaded then return end
        Wait(UNPAID_RETRY_MS)
    end
end)

CreateThread(function()
    local seconds = Arena.ToInt(Config.Betting.refundRetrySeconds)
    if seconds == nil then seconds = 30 end

    if seconds <= 0 then return end

    while true do
        Wait(seconds * 1000)

        ArenaBetting.SweepUnpaid()
    end
end)

function ArenaBetting.Clear(matchId)
    local owed = 0

    -- AN UNSETTLED BET ON A MATCH THAT HAS BEEN PAID IS NOT AN UNPAID BET,
    -- and this loop must NEVER hand one back.
    -- It is the other half of the order every payout in this file uses: the
    -- mark goes on AFTER the money moves, so a run that stopped part-way
    -- leaves winners it has already paid reading exactly like winners it has
    -- not. This loop handed those back, which paid them twice -- and it is
    -- the last of the three doors, with ArenaLobby.Destroy's RefundAll and
    -- ArenaMatch.Abort's. Counted as still owed instead, which is what keeps
    -- the match on the books and this function refusing to drop it.
    local paidOut = payoutBegun(matchId)

    for _, bet in ipairs(sideBets[matchId] or {}) do
        if not bet.settled then
            if paidOut then
                owed = owed + (Arena.ToInt(bet.amount) or 0)
            else
                ArenaLog('CLEAR: match %s had an unresolved side-bet of %d from %s -- returning it.',
                    tostring(matchId), bet.amount, tostring(bet.name or bet.src))
                if not returnSideBet(bet, matchId) then owed = owed + bet.amount end
            end
        end
    end

    if paidOut and owed > 0 then refusePaidOut(matchId, 'CLEAR') end

    local held = ArenaBetting.GetPot(matchId)
    if held > 0 then
        ArenaLog('CLEAR REFUSED: match %s still holds %d in escrow. Settle or refund it first -- nothing was dropped.',
            tostring(matchId), held)
        incidentWebhook('Match cleared while holding escrow',
            'A match was cleared while its pot was still held. The escrow was kept.', {
                { name = 'Match', value = tostring(matchId) },
                { name = 'Held', value = money(held) },
            })
    end
    if owed > 0 then
        ArenaLog('CLEAR REFUSED: match %s still owes %d in side-bets that could not be returned. Nothing was dropped.',
            tostring(matchId), owed)
    end
    if held > 0 or owed > 0 then return false end

    escrow[matchId] = nil
    sideBets[matchId] = nil

    -- CLEARED ONLY WITH THE MATCH ITSELF, below every refusal above. Clearing
    -- it at the top of this function would have freed the guard on a Clear
    -- that then REFUSED -- and a refused clear is exactly the state where the
    -- pot is still held and a second payout would pay it out again. The flag
    -- goes when the pot and the bets go, and not before. DO NOT hoist this.
    settling[matchId] = nil
    sideSettled[matchId] = nil
    walkedOutOf[matchId] = nil
    return true
end
