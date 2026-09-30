--[[
    crimson_arena/tests/moneyguards_spec.lua

    SIX GUARDS IN server/betting.lua THAT NOTHING HELD DOWN.

    Each of the six is a `if <already done> then return end` with a comment
    beside it recording what it cost when it was not there -- "Measured:
    15,000 paid twice out of a 15,000 pot", "the same debt was paid every
    thirty seconds for as long as the player stayed online", "a way to move
    money between your own characters, through the arena, with no record of
    it". Every one of them was DELETED in turn and the whole money suite --
    thirteen spec files, 282 tests -- stayed green.

    That is the worst shape a hole can have: the most expensive bugs this
    file has ever shipped are the ones with nothing watching the repair. A
    guard nobody tests is a guard somebody deletes.

    Two of the six needed the fixture to be able to express the state at all.
    A framework that moves EXACTLY what it was asked for can never produce an
    unconfirmable movement, so `rake` and `skim` -- another resource taking
    its own cut on the way in and on the way out, on the money-changed event
    both calls raise -- are what reach those two.

    Real server/util.lua and server/betting.lua over the real config.lua and
    shared/arena.lua. THE LEDGER, NOT THE BALANCE: a payment that ran twice
    and one that never ran leave the same balance, and telling them apart is
    the whole subject.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('moneyguards_spec')

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
        }
    end
    return players
end

--- @param wallets table<integer, integer>
--- @param opts table? -- { mutate = fun(config), rake = n, payIn = n }
local function newServer(wallets, opts)
    opts = opts or {}
    local qbx = Sandbox.newQbxCore(roster(wallets), { rake = opts.rake, payIn = opts.payIn })
    local console = {}

    -- A NOTIFICATION THAT RAISES, WHICH IS THE ONLY WAY INTO THE TWO GUARDS
    -- BELOW. ArenaNotify calls TriggerClientEvent unwrapped (server/util.lua),
    -- so a raise there propagates straight out of the payout loop -- AFTER
    -- the credit and BEFORE the stakes are marked settled, which betting.lua
    -- puts below the loop deliberately. That leaves an already-paid winner
    -- reading as unsettled, and it is the state the second-run guards exist
    -- for. Calling a finished settle twice reaches neither of them.
    local failNotifies = 0
    local env = Sandbox.newArenaEnv({
        CreateThread = function() end,
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        TriggerClientEvent = function()
            if failNotifies > 0 then
                failNotifies = failNotifies - 1
                error('the client event bus fell over')
            end
        end,
        print = function(line) console[#console + 1] = tostring(line) end,
    })
    if opts.mutate then opts.mutate(env.Config) end

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)

    local server = { env = env, qbx = qbx, betting = env.ArenaBetting, config = env.Config }

    --- The next `count` notifications raise instead of being delivered.
    function server.breakNotify(count) failNotifies = count end

    function server.cash(id) return qbx.players[id].money.cash end
    function server.bank(id) return qbx.players[id].money.bank end
    function server.log() return table.concat(console, '\n') end

    --- How many times money moved for one player, rake and skim included.
    function server.movements(id)
        local n = 0
        for _, entry in ipairs(qbx.ledger) do if entry.id == id then n = n + 1 end end
        return n
    end

    --- Money movements for one player that this resource caused.
    function server.arenaMovements(id)
        local n = 0
        for _, entry in ipairs(qbx.ledger) do
            if entry.id == id and entry.reason ~= 'rake' and entry.reason ~= 'payIn' then
                n = n + 1
            end
        end
        return n
    end

    --- The character behind a server id is replaced by somebody else.
    function server.reassignId(id, cash)
        qbx.players[id] = {
            citizenid = ('NEW%03d'):format(id),
            name = ('Newcomer %d'):format(id),
            money = { cash = cash, bank = 0 },
        }
    end

    return server
end

--- The separate-pot arrangement, where ArenaBetting.Settle really pays the
--- pot. On the shipped `includeEntryPot = true` the entry stakes are handed
--- to the side-bet book instead and Settle returns having paid nothing.
local function separatePot(config)
    config.Betting.betPayout = { fighters = 'pool', spectators = 'pool',
        sharedPool = true, includeEntryPot = false }
end

local function seat(src, team)
    return { src = src, team = team, alive = true, lives = 3, kills = 0, deaths = 0 }
end

--- The context server/match.lua hands Settle at the end of a round.
---
--- A LIST OF WINNERS IS NOT A CONTEXT. Settle reads `players`, `winners`,
--- `teams` and `contestants` off this table; handed `{ 1 }` it finds no
--- roster, pays nobody, and a test built on that measures nothing.
local function endedWith(winner)
    return {
        players = {
            { id = 1, team = 'crimson', kills = 1, stake = 1000, placement = 1 },
            { id = 2, team = 'ash', kills = 0, stake = 1000, placement = 2 },
        },
        winners = { winner },
        teams = false,
        contestants = 2,
    }
end

--- Two fighters staked into one match, with a lobby record to bet on.
local function staked(opts)
    local server = newServer({ [1] = 20000, [2] = 20000, [3] = 20000 }, opts)
    local record = {
        id = 'm1', state = 'lobby', modeKey = 'tdm',
        players = { [1] = seat(1, 'crimson'), [2] = seat(2, 'ash') },
    }
    server.env.ArenaLobby = { Get = function(id) return record == nil and nil or (id == 'm1' and record or nil) end }
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)
    return server, record
end

-- ======================================================================
-- PAYING THE SAME POT TWICE
-- ======================================================================

t.test('Settle refuses to run twice on one match', function()
    -- betting.lua's own note: "a payout that died part-way, asked to run
    -- again, paid the winner the whole 15,000 pot a SECOND time." The second
    -- run is not hypothetical -- ArenaMatch.Abort calls Settle on a teardown
    -- that follows ArenaMatch.End having called it.
    local s = staked({ mutate = separatePot })

    local before = s.cash(1)

    -- The first run pays the winner and then dies on the notification, so
    -- the stakes below the loop are never marked.
    s.breakNotify(1)
    local finished = pcall(function() return s.betting.Settle('m1', endedWith(1)) end)
    t.isFalse(finished, 'the settle did not die part-way, so this proves nothing')

    local afterFirst = s.cash(1)
    t.isTrue(afterFirst > before, 'the winner was not paid before it died, so this proves nothing')
    t.isTrue(s.betting.GetPot('m1') > 0,
        'the stakes were marked settled anyway, so the second run has nothing to pay from')

    s.betting.Settle('m1', endedWith(1))

    t.equals(s.cash(1), afterFirst, 'THE WINNER WAS PAID THE SAME POT A SECOND TIME')
    t.contains(s.log(), 'SECOND time', 'the refusal was not written down')
end)

t.test('and SettleSpectatorBets refuses to run twice, which is where the pot is really paid', function()
    -- The more dangerous of the two on the shipped config:
    -- betPayout.includeEntryPot ships TRUE, so Settle hands the entry stakes
    -- to the side-bet book and returns, and the pot is paid out HERE.
    local s, record = staked()
    -- THE PICK IS THE SIDE, not the player: this is a team match, and a
    -- server id where a team name belongs is refused as an invalid pick.
    t.isTrue(s.betting.PlaceSpectatorBet(3, 'm1', 'crimson', 500),
        'the side-bet was refused, so there is nothing to settle twice')
    record.state = 'live'

    local before = s.cash(3)
    s.betting.Settle('m1', endedWith(1))

    s.breakNotify(1)
    local finished = pcall(function() return s.betting.SettleSpectatorBets('m1', 'crimson') end)
    t.isFalse(finished, 'the settle did not die part-way, so this proves nothing')

    local afterFirst = s.cash(3)
    t.isTrue(afterFirst > before, 'the backer was not paid before it died, so this proves nothing')

    s.betting.SettleSpectatorBets('m1', 'crimson')

    t.equals(s.cash(3), afterFirst, 'THE SIDE-BET POOL WAS PAID OUT A SECOND TIME')
    t.contains(s.log(), 'SECOND time', 'the refusal was not written down')
end)

t.test('and a stake is not refunded twice', function()
    -- The cheapest of the three to regress: unlike the two above it needs no
    -- part-way failure, just a second call. Two leave paths naming the same
    -- player -- an explicit leave, then the disconnect handler -- is enough.
    local s = staked()

    local before = s.cash(1)
    t.isTrue(s.betting.RefundOne('m1', 1, 'left'), 'the first refund did not run, so this proves nothing')
    local afterFirst = s.cash(1)
    t.equals(afterFirst, before + 1000, 'the refund did not reach the player')

    t.isFalse(s.betting.RefundOne('m1', 1, 'left'), 'the second refund reported success')
    t.equals(s.cash(1), afterFirst, 'THE SAME STAKE WAS HANDED BACK TWICE')
end)

-- ======================================================================
-- PAYING THE RIGHT CHARACTER
-- ======================================================================

t.test('the pot is paid to the character who staked it, not whoever holds the id', function()
    -- betting.lua: "winning a round and switching character before it ended
    -- paid the pot into the character who had just taken over the id. A way
    -- to move money between your own characters, through the arena, with no
    -- record of it." The rule is covered for side-bets, side-bet refunds and
    -- the unpaid ledger, and was covered nowhere for the pot itself.
    local s = staked({ mutate = separatePot })

    -- The winner switches character before the round is settled. Same server
    -- id, different person, different wallet.
    s.reassignId(1, 100)

    s.betting.Settle('m1', endedWith(1))

    t.equals(s.cash(1), 100, 'THE POT WAS PAID INTO A CHARACTER THAT NEVER STAKED IT')
    t.contains(s.log(), 'PAYOUT UNDELIVERED',
        'the money went nowhere and nothing was written down about it')
end)

-- ======================================================================
-- A MOVEMENT NOBODY CAN CONFIRM
-- ======================================================================

t.test('a removal the balance cannot confirm is not retried against the other account', function()
    -- THE DEFECT betting.lua:390-411 RECORDS: RemoveMoney did not say no, so
    -- the money may well be gone -- but the balance read short because some
    -- other resource moved the same account on the same money-changed event.
    -- Falling through "took the WHOLE amount out of the second account as
    -- well, and recorded one stake for it": the player pays their entry fee
    -- twice, once from cash and once from bank.
    --
    -- `payIn` is that other resource: a paycheck landing on the same
    -- account while the fee is being taken, so the balance afterwards is
    -- short of the full removal and cannot confirm it.
    local s = newServer({ [1] = 20000 }, {
        payIn = 5,
        mutate = function(config) config.Betting.accounts = { 'cash', 'bank' } end,
    })
    s.qbx.players[1].money.bank = 20000
    local record = { id = 'm1', state = 'lobby', modeKey = 'tdm', players = { [1] = seat(1) } }
    s.env.ArenaLobby = { Get = function() return record end }

    local bankBefore = s.bank(1)
    t.isTrue(s.betting.TakeStake(1, 'm1', 1000), 'the stake was refused, so this proves nothing')

    t.equals(s.bank(1), bankBefore, 'THE ENTRY FEE WAS TAKEN OUT OF BOTH ACCOUNTS')
    t.equals(s.betting.GetPot('m1'), 1000, 'the pot holds something other than one entry fee')
    t.contains(s.log(), 'could not confirm it from the balance',
        'the unconfirmable removal was not written down')
end)

t.test('and a credit the balance cannot confirm is not paid again', function()
    -- The mirror, and the more expensive one. Reading a short delta as
    -- "the credit failed" meant "the caller recorded the money as still
    -- owed, the unpaid sweep came back refundRetrySeconds later and paid it
    -- AGAIN -- and where the cause was systemic, such as a percentage taken
    -- on every deposit, the delta was short every single time and the same
    -- debt was paid every thirty seconds for as long as the player stayed
    -- online."
    local s = newServer({ [1] = 20000, [2] = 20000 }, { rake = 5 })
    local record = {
        id = 'm1', state = 'lobby', modeKey = 'tdm',
        players = { [1] = seat(1, 'crimson'), [2] = seat(2, 'ash') },
    }
    s.env.ArenaLobby = { Get = function() return record end }
    s.betting.TakeStake(1, 'm1', 1000)
    s.betting.TakeStake(2, 'm1', 1000)

    s.betting.RefundAll('m1', 'match_cancelled')

    local _, owed = s.betting.Outstanding()
    t.equals(owed, 0,
        'A REFUND THAT REALLY LANDED WAS RECORDED AS STILL OWED, and the sweep pays it again')

    -- And the sweep agrees: there is nothing left to hand over.
    local people, total = s.betting.SweepUnpaid()
    t.equals(people, 0, 'the sweep found somebody to pay a debt that was already settled')
    t.equals(total, 0, 'the sweep paid out money that had already been paid')
    t.contains(s.log(), 'could not confirm it from the balance',
        'the unconfirmable credit was not written down')
end)

-- ======================================================================
-- AND WHETHER AN OPERATOR CAN SEE WHAT THEY ARE OWED
--
-- When a pot cannot be delivered, Settle prints: "It is on the unpaid ledger
-- and will be paid when they come back; /arenaadmin can list it." It could
-- not. ArenaBetting.Outstanding -- the only reader of the `unpaid` table --
-- had no caller anywhere in the resource, and the admin snapshot's `owed`
-- field is the ITEM stash slate from server/ammo.lua, a different ledger
-- entirely. An operator sent to go and look found nothing, and had no way to
-- tell an empty ledger from a screen that does not exist.
-- ======================================================================

t.test('the money the arena owes can actually be read back', function()
    local s = staked({ mutate = separatePot })
    s.qbx.players[1] = nil                       -- the winner has gone
    s.betting.Settle('m1', endedWith(1))

    t.contains(s.log(), 'unpaid ledger', 'nothing was filed, so this proves nothing')

    local report = table.concat(s.betting.OwedReport(), '\n')

    t.contains(report, 'CID001', 'the report does not name the character the money is owed to')
    t.contains(report, 'pot_payout', 'the report does not say what the debt is for')
end)

t.test('and says plainly when it owes nobody anything', function()
    local s = staked()
    local report = table.concat(s.betting.OwedReport(), '\n')

    t.contains(report, 'owes nobody', 'an empty ledger read as a broken screen')
end)

t.test('AND IT DOES NOT SAY "owes nobody" BEFORE THE LEDGER HAS BEEN READ BACK', function()
    -- THE MOMENT THIS SCREEN IS MOST LIKELY TO BE OPENED is just after a
    -- restart, to check the arena did not forget what it owed somebody --
    -- and that is the one window in which it was wrong.
    --
    -- OwedReport built its list from the in-memory `unpaid` table alone and
    -- never looked at unpaidLoaded. On a server where oxmysql starts after
    -- this resource -- the README says the order does not matter -- the
    -- start-up read is a retry thread that waits between attempts, so every
    -- debt from the previous run can be sitting in crimson_arena_unpaid with
    -- none of it in memory. The screen said "owes nobody anything" and, in
    -- the same breath, accused the operator's database of being unwritable,
    -- because the durability verdict needs a read that landed.
    --
    -- They tell the player there is no debt, and go and re-grant a database
    -- that was fine.
    local s = staked({ mutate = function(config) config.Database.enabled = true end })
    local report = table.concat(s.betting.OwedReport(), '\n')

    t.notContains(report, 'owes nobody',
        'an unread ledger was reported as an empty one, on the screen an operator reads '
        .. 'before telling a player there is no debt')
    t.contains(report, 'been read back',
        'the report did not say why its list may be incomplete')
    t.notContains(report, 'cannot write to it',
        'the operator was accused of a broken database while the read was still out')
end)

t.test('and the shipped default -- database off -- is NOT dragged into that warning', function()
    -- THE REGRESSION THE OBVIOUS FIX WOULD HAVE CAUSED, pinned so it cannot
    -- come back. With Config.Database.enabled off -- which is what ships --
    -- the start-up read never runs at all, so the "loaded" flag is false for
    -- the life of the process. Gating on that flag alone would put a
    -- permanent "not read back yet" on the majority of installs: a new false
    -- alarm in place of a correct answer.
    local s = staked()
    local report = table.concat(s.betting.OwedReport(), '\n')

    t.contains(report, 'owes nobody',
        'a memory-only server was told its ledger might be incomplete, which it cannot be')
    t.notContains(report, 'been read back',
        'the unread-ledger warning leaked onto a server that never reads one')
    t.contains(report, 'restart forgets it', 'the durability line went missing')
end)

t.test('and says on the same line whether a restart would forget it', function()
    -- The question an operator looking at a debt actually has, and the
    -- answer depends on a config flag they may not have set themselves.
    local off = staked()
    t.contains(table.concat(off.betting.OwedReport(), '\n'), 'restart forgets it',
        'a memory-only ledger did not say it is memory-only')

    local on = staked({ mutate = function(config) config.Database.enabled = true end })
    t.contains(table.concat(on.betting.OwedReport(), '\n'), 'oxmysql is NOT started',
        'a database that is on with no oxmysql behind it was reported as durable')
end)

-- ======================================================================
-- A WAGER YOU CAN CANCEL ONCE IT IS GOING BADLY IS NOT A WAGER
--
-- betting.lua says it twice, in as many words: "Handing the bet back is the
-- refund the whole function exists to withhold." On a server that allows
-- non-fighters no side-bet at all there is no smaller band to trim a
-- departing fighter's stake to -- and the branch that answered that handed
-- the whole thing back, whatever the state of the round. Back yourself,
-- watch it go badly, walk out, take the stake home: a free option, paid for
-- by whoever backed the other side.
--
-- It does not fire on the shipped config, where spectator bets are on and
-- both ceilings are level. An operator running a fighters-only book is who
-- gets hit, and they are the operator least likely to notice.
-- ======================================================================

--- A server with no spectator book at all, which is what leaves the
--- departing fighter's stake with nothing smaller to fall back to.
local function fightersOnly(config)
    config.Betting.spectatorBets = config.Betting.spectatorBets or {}
    config.Betting.spectatorBets.enabled = false
end

t.test('a fighter who backs themselves and walks out MID-ROUND keeps the bet down', function()
    local s, record = staked({ mutate = fightersOnly })
    t.isTrue(s.betting.PlaceSpectatorBet(1, 'm1', 'crimson', 2000),
        'the fighter could not back their own side, so this proves nothing')

    record.state = 'live'
    local before = s.cash(1)

    local _, returned = s.betting.MarkWalkedOut('m1', 1)

    t.equals(returned, 0, 'THE WHOLE STAKE WAS HANDED BACK MID-ROUND -- a wager you can cancel')
    t.equals(s.cash(1), before, 'the money went back to the player who walked out')
end)

t.test('and the same walk-out BEFORE the round starts is handed back, which is a cancellation', function()
    -- The other side of the same branch, and it has to keep working: before
    -- the round is fought nothing has been risked, so this is the answer a
    -- lobby cancellation gives everybody else.
    local s = staked({ mutate = fightersOnly })
    t.isTrue(s.betting.PlaceSpectatorBet(1, 'm1', 'crimson', 2000),
        'the fighter could not back their own side, so this proves nothing')

    local before = s.cash(1)
    local _, returned = s.betting.MarkWalkedOut('m1', 1)

    t.equals(returned, 2000, 'a bet on a round that had not started was kept')
    t.equals(s.cash(1), before + 2000, 'the money did not reach the player')
end)

t.test('a trim that FAILED leaves the bet in the fighters\' book, as its own log line says', function()
    -- `bet.kind = 'spectator'` sat below the whole block and ran on both
    -- outcomes, so the console said "the bet stands at its full %d and is
    -- still held to the fighter band" and the next statement moved it into
    -- the spectators' book anyway. With betPayout.sharedPool off that puts an
    -- untrimmed fighter-band stake into the pool capped at the spectator
    -- ceiling -- the exact mismatch the trim exists to prevent.
    --
    -- Reaching the failure needs the credit to fail AND the unpaid ledger to
    -- refuse it, and the ledger only refuses a bet with no citizen id.
    local s, record = staked({ mutate = function(config)
        config.Betting.fighterBets = { enabled = true, min = 1, max = 50000 }
        config.Betting.spectatorBets = { enabled = true, min = 1, max = 1000,
            closeAfterStartSeconds = 60 }
        -- SEPARATE POOLS, which is the arrangement the mismatch matters in
        -- and the only one where the two books can be told apart at all.
        config.Betting.betPayout = { fighters = 'pool', spectators = 'pool',
            sharedPool = false, includeEntryPot = false }
    end })
    -- NO CITIZEN ID ON THE BET, WHICH IS THE ONLY WAY THE LEDGER REFUSES IT.
    -- Stripped before the bet is placed, because the bet copies it then.
    s.qbx.players[1].citizenid = nil
    local placed, why = s.betting.PlaceSpectatorBet(1, 'm1', 'crimson', 5000)
    t.isTrue(placed, 'the fighter stake was refused (' .. tostring(why) .. '), so this proves nothing')

    -- And the player is gone, so the credit cannot land either.
    s.qbx.players[1] = nil

    record.state = 'live'
    s.betting.MarkWalkedOut('m1', 1)

    t.contains(s.log(), 'TRIM FAILED', 'the trim did not fail, so this proves nothing')
    t.notContains(s.log(), 'stands as a spectator bet',
        'a failed trim was reported as a successful one')

    -- AND THE STATE, NOT ONLY THE LOG. The log line is on the failure path
    -- and says the right thing either way; what used to happen next is that
    -- the bet was moved into the spectators' book regardless, so the two
    -- disagreed. Split the pools apart and the untrimmed stake has to still
    -- be in the fighters' one.
    local byPool = s.betting.SideBetTotals('m1')
    local inFighters, inSpectators = 0, 0
    for key, side in pairs(byPool) do
        for _, amount in pairs(side) do
            if tostring(key):find('fighter') then inFighters = inFighters + amount
            else inSpectators = inSpectators + amount end
        end
    end

    t.equals(inSpectators, 0,
        'an untrimmed fighter-band stake was re-filed into the pool capped at the spectator ceiling')
    t.equals(inFighters, 5000, 'the untrimmed stake left the fighters\' book')
end)

os.exit(t.summary())
