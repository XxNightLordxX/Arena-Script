--[[
    crimson_arena/tests/lobbyrules_spec.lua

    The three operator switches a lobby answers to, exercised through the
    REAL server files -- util.lua, betting.lua, lobby.lua, match.lua and the
    net events in main.lua -- loaded unmodified into one sandbox over the
    real config.lua and shared/arena.lua:

        Config.Betting.refundOnCancel
        Config.Betting.refundOnDisconnectBeforeStart
        Config.Permissions.joinJobs

    Each one used to be a value an operator could change with no effect at
    all, so every test below is written the way the operator would find out:
    set the key, do the thing, and count what happened to the money.

    THE LEDGER, NOT THE BALANCE. A refund that ran twice and a refund that
    never ran leave the same balance behind, so every assertion about money
    counts MOVEMENTS as well. That matters twice over here, because "forfeit"
    means "no movement at all" -- a forfeit that is really a silently failed
    refund looks identical on a balance sheet and leaves the pot stranded in
    escrow.

    NOTHING GOES IN THROUGH A FUNCTION CALL WHERE A PLAYER WOULD USE THE
    WIRE. Cancels, joins, leaves and disconnects are all fired as the net
    events and handlers main.lua registers, with `source` set the way FiveM
    sets it, so a rule that is wired into the lobby but never reached from
    the wire fails here.

    TWO FILES ARE STUBBED RATHER THAN LOADED. server/stats.lua wants oxmysql
    and server/dispatch.lua wants server-side state bags; neither decides
    anything about money or permission, and both are reached only through
    ArenaStats.* / ArenaDispatch.*, so they are supplied as the small tables
    those call sites use. Every other server file here is the shipped one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('lobbyrules_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- Wallets and jobs for a set of server ids, in the shape
--- Sandbox.newQbxCore wants.
--- @param wallets table<integer, integer> -- [serverId] = starting cash
--- @param jobs table<integer, string>? -- [serverId] = job name; unemployed otherwise
--- @return table<integer, table>
local function roster(wallets, jobs)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = (jobs or {})[id] or 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- One whole arena server. Fresh per test: escrow, the match registry and
--- the snapshot cache are all module state, so two tests sharing an env
--- would share a pot.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)? -- applied before any file that reads config at LOAD time
--- @param jobs table<integer, string>?
--- @return table server
local function newArena(wallets, mutate, jobs)
    local qbx = Sandbox.newQbxCore(roster(wallets, jobs))
    local oxlib = Sandbox.newOxLib()
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents, handlers, commands = {}, {}, {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = oxlib,

        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,

        -- Captured, not silenced: half of what this file asserts is that a
        -- refusal or a forfeit is LOUD, and the console is where that lands.
        print = function(line) console[#console + 1] = line end,

        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        -- Well past every RATE bucket in main.lua on every call: this spec is
        -- about permissions and money, and a throttled event would look
        -- exactly like a refused one.
        GetGameTimer = function() clock = clock + 60000; return clock end,

        -- An id with no wallet is somebody who has left the server, which is
        -- how ArenaLobby.Broadcast prunes them.
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetVehiclePedIsIn = function() return 0 end,
        -- Nobody holds an ACE here. Source 0 -- the server console -- is an
        -- admin without one, which is what the admin test leans on.
        IsPlayerAceAllowed = function() return false end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        -- The arena flag, and the routing bucket a round is fought in. Both
        -- ride the same two choke points in server/match.lua, so a stub
        -- missing either half fails as a nil call naming it.
        ArenaAmmo = {
            -- No-op double. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; here it only has to exist, because
            -- server/match.lua calls it at both arena choke points.
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- Before the loads below, not after: server/lobby.lua reads
    -- Config.Match.idleLobbyTimeoutSeconds once, at load, to decide whether
    -- its sweep thread is worth starting at all.
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env,
        qbx = qbx,
        config = env.Config,
        betting = env.ArenaBetting,
        lobby = env.ArenaLobby,
        match = env.ArenaMatch,
    }

    --- One client -> server event, as the client sends it.
    --- @param event string -- the tail of crimson_arena:server:*
    --- @param src integer
    --- @param data table?
    function server.fire(event, src, data)
        local name = 'crimson_arena:server:' .. event
        local handler = netEvents[name]
        if not handler then error('no handler registered for ' .. name, 2) end
        env.source = src
        handler(data)
    end

    --- A player losing their connection, through main.lua's own handler.
    --- @param src integer
    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    --- /arenaadmin from the server console, which always qualifies.
    --- @param ... string
    function server.adminCommand(...)
        commands['arenaadmin'](0, { ... })
    end

    --- Resumes every captured thread once. The sweeps call Wait first, so a
    --- full pass is two steps.
    function server.step()
        threads.step()
        threads.step()
    end

    --- @return integer
    function server.cash(id) return qbx.players[id].money.cash end

    --- @return integer
    function server.movements(id) return qbx.movements(id) end

    --- Money created or destroyed across every account. A pot only ever
    --- moves money between players, so this is 0 for every path that pays or
    --- refunds -- and stays negative by exactly the forfeited amount for the
    --- one path that keeps it.
    --- @return integer
    function server.ledgerTotal()
        local total = 0
        for _, entry in ipairs(qbx.ledger) do total = total + entry.delta end
        return total
    end

    --- @return string
    function server.log() return table.concat(console, '\n') end

    --- What one player was told, in order. Only the toasts: the state
    --- snapshot goes to the same players down the same native.
    ---
    --- ArenaNotify sends this resource's own relay rather than 'ox_lib:notify'
    --- -- client/ui.lua is what chooses between the panel's toast rail and
    --- ox_lib, and it cannot choose once the server has chosen for it.
    --- @param id integer
    --- @return string
    function server.told(id)
        local said = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == id then
                said[#said + 1] = message.payload.description
            end
        end
        return table.concat(said, '\n')
    end

    return server
end

--- One lobby: `ids[1]` opens it at `fee` and everybody after that joins.
--- The id comes back from the registry, never from the spec -- a create that
--- was refused fails here rather than three assertions later.
--- @param server table
--- @param fee integer
--- @param ids integer[]
--- @return string matchId
local function openLobby(server, fee, ids)
    server.fire('createMatch', ids[1], { arenaKey = 'airfield', modeKey = 'ffa', entryFee = fee })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
        t.isNotNil(match.players[ids[index]], ('player %d could not join'):format(ids[index]))
    end

    return match.id
end

-- ======================================================================
-- WHAT THESE TESTS ASSUME
-- ======================================================================

t.test('the shipped config is the one the numbers below assume', function()
    local config = newArena({}).config
    t.isTrue(config.Betting.enabled)
    t.equals(config.Betting.account, 'cash')
    t.equals(config.Betting.houseCutPercent, 0)
    t.equals(config.Betting.payout, 'winner_takes_all')
    t.equals(config.Betting.minPlayersToPayOut, 2)

    -- The three keys this file wires, in their shipped positions.
    t.equals(config.Betting.refundOnCancel, true)
    t.equals(config.Betting.refundOnDisconnectBeforeStart, true)
    t.equals(config.Betting.refundOnDisconnectDuringMatch, false, 'the mid-round key is not this change to make')
    t.equals(Sandbox.newArenaEnv().Arena.Count(config.Permissions.joinJobs), 0, 'joinJobs ships empty')
end)

-- ======================================================================
-- refundOnCancel -- THE HOST CALLING THEIR OWN LOBBY OFF
-- ======================================================================

t.test('with refundOnCancel on, a host cancel hands every stake back exactly once', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2, 3 })
    t.equals(server.betting.GetPot(matchId), 3000)

    server.fire('cancelMatch', 1)

    for _, id in ipairs({ 1, 2, 3 }) do
        t.equals(server.cash(id), 5000, ('player %d was not made whole'):format(id))
        t.equals(server.movements(id), 2, ('player %d: expected a stake out and one refund in'):format(id))
    end
    t.equals(server.ledgerTotal(), 0, 'a cancelled lobby created or destroyed money')
    t.isNil(server.lobby.Get(matchId), 'the match record outlived its cancel')
    t.notContains(server.log(), 'CLEAR REFUSED')
end)

t.test('with refundOnCancel off, a host cancel keeps the stakes and pays nobody', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    server.fire('cancelMatch', 1)

    for _, id in ipairs({ 1, 2, 3 }) do
        t.equals(server.cash(id), 4000, ('player %d was refunded anyway'):format(id))
        -- One movement, not two: the stake left and nothing came back. A
        -- balance check alone could not tell this from a refund that failed.
        t.equals(server.movements(id), 1, ('player %d saw a second movement'):format(id))
        t.contains(server.told(id), 'Stake gone', ('player %d was not told'):format(id))
    end

    -- Where it went is a decision, so it is logged as one.
    t.contains(server.log(), 'FORFEIT')
    t.equals(server.ledgerTotal(), -3000, 'a forfeited pot leaves the economy; nobody is credited it')
    t.isNil(server.lobby.Get(matchId))
end)

t.test('a forfeited pot is dropped cleanly rather than stranded in escrow', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.fire('cancelMatch', 1)

    -- Clear refuses to drop a match still holding anything, and that refusal
    -- is the last line of defence for a pot. Forfeiting has to satisfy it,
    -- not sidestep it.
    t.notContains(server.log(), 'CLEAR REFUSED')
    t.equals(server.betting.GetPot(matchId), 0)
    t.isTrue(server.betting.Clear(matchId), 'the escrow record was left behind')
end)

t.test('a forfeited stake is marked, not deleted -- a later refund of it is refused out loud', function()
    local server = newArena({ [1] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)

    local forfeited, total = server.betting.ForfeitAll('m1', 'notify.match_cancelled')
    t.equals(forfeited, 1)
    t.equals(total, 1000)
    t.equals(server.betting.GetPot('m1'), 0)
    t.equals(server.betting.GetStake('m1', 1), 0)

    -- Both of these are the same mistake from opposite ends: paying a stake
    -- that has already been settled.
    t.isFalse(server.betting.RefundOne('m1', 1, 'notify.match_cancelled'))
    t.contains(server.log(), 'DOUBLE REFUND REFUSED')

    local again, moreMoney = server.betting.ForfeitAll('m1', 'notify.match_cancelled')
    t.equals(again, 0, 'the same stake was forfeited twice')
    t.equals(moreMoney, 0)

    t.equals(server.movements(1), 1, 'money moved after the stake was taken')
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('Clear still refuses while a stake is genuinely held', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    server.betting.TakeStake(1, 'm1', 1000)
    server.betting.TakeStake(2, 'm1', 1000)

    t.isFalse(server.betting.Clear('m1'), 'a held pot was dropped')
    t.contains(server.log(), 'CLEAR REFUSED')
    t.equals(server.betting.GetPot('m1'), 2000, 'the money must stay reachable by a later refund')

    -- And a forfeit is what makes it droppable, because the money is then
    -- settled rather than still owed.
    server.betting.ForfeitAll('m1', 'notify.match_cancelled')
    t.isTrue(server.betting.Clear('m1'))
end)

t.test('an idle-timeout close refunds even with refundOnCancel off', function()
    -- The sweep closes a lobby nobody readied up in. That is the server
    -- giving up on a match, not a host calling one off, so refundOnCancel
    -- has nothing to say about it.
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
        config.Match.idleLobbyTimeoutSeconds = 60
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })

    -- Aged rather than waited out: the sweep reads os.time() against the
    -- record's own createdAt.
    server.lobby.Get(matchId).createdAt = os.time() - 600
    server.step()

    t.isNil(server.lobby.Get(matchId), 'the idle lobby was never swept')
    t.equals(server.cash(1), 5000)
    t.equals(server.cash(2), 5000)
    t.equals(server.movements(1), 2)
    t.equals(server.ledgerTotal(), 0)
    t.notContains(server.log(), 'FORFEIT')
end)

t.test('an admin force-stop refunds even with refundOnCancel off', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.adminCommand('stop', matchId)

    t.isNil(server.lobby.Get(matchId))
    t.equals(server.cash(1), 5000, 'an admin stop is not a host cancel')
    t.equals(server.cash(2), 5000)
    t.equals(server.movements(2), 2)
    t.equals(server.ledgerTotal(), 0)
    t.notContains(server.log(), 'FORFEIT')
end)

t.test('a cancel from anybody but the host is refused and costs nothing', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.fire('cancelMatch', 2)

    t.isNotNil(server.lobby.Get(matchId), 'a guest closed somebody else lobby')
    t.contains(server.told(2), 'Only the host calls that.')
    t.equals(server.betting.GetPot(matchId), 2000, 'a refused cancel must not touch the pot')
    t.equals(server.movements(1), 1)
end)

t.test('a cancel from somebody in no match at all is refused', function()
    local server = newArena({ [1] = 5000, [9] = 5000 })
    openLobby(server, 1000, { 1 })

    server.fire('cancelMatch', 9)
    t.contains(server.told(9), 'You are not in a match.')
end)

t.test('a live round cannot be cancelled, whatever refundOnCancel says', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Betting.refundOnCancel = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })
    server.lobby.Get(matchId).state = 'live'

    server.fire('cancelMatch', 1)

    t.isNotNil(server.lobby.Get(matchId), 'a cancel ended a round that was being fought')
    t.equals(server.betting.GetPot(matchId), 2000)
    t.contains(server.told(1), 'That match has already kicked off.')
end)

t.test('a countdown is still a lobby, so the host may still cancel it', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2 })
    server.lobby.Get(matchId).state = 'countdown'

    server.fire('cancelMatch', 1)

    t.isNil(server.lobby.Get(matchId))
    t.equals(server.cash(1), 5000, 'backing out of a countdown still refunds')
    t.equals(server.movements(1), 2)
end)

-- ======================================================================
-- refundOnDisconnectBeforeStart -- LEAVING A LOBBY THAT HAS NOT STARTED
--
-- Every player who drops below is left in the fake qbx roster on purpose.
-- A stake that is not refunded has to be the server DECIDING not to refund
-- it; if the wallet were gone the same test would pass on a refund that
-- silently failed, which is the opposite outcome -- money still owed.
-- ======================================================================

t.test('with refundOnDisconnectBeforeStart on, a drop from a lobby hands the stake back', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    server.drop(3)

    t.equals(server.cash(3), 5000)
    t.equals(server.movements(3), 2, 'expected the stake out and one refund in')
    t.equals(server.betting.GetPot(matchId), 2000, 'the refunded stake stayed in the pot')
    t.equals(server.ledgerTotal(), -2000, 'only the two players still in the lobby are staked')
end)

t.test('with refundOnDisconnectBeforeStart off, a drop from a lobby leaves the stake in the pot', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Betting.refundOnDisconnectBeforeStart = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    server.drop(3)

    t.equals(server.cash(3), 4000)
    t.equals(server.movements(3), 1, 'the stake came back after all')
    t.isNil(server.lobby.Get(matchId).players[3], 'they are out of the match')
    -- FORFEITED TO THE POT, not to nowhere: the pot is still the full 3000
    -- and the players who stayed are fighting for all of it.
    t.equals(server.betting.GetPot(matchId), 3000)
end)

t.test('a stake forfeited to the pot is really paid out to whoever wins it', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Betting.refundOnDisconnectBeforeStart = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    server.drop(3)
    server.match.End(matchId, 'match.ended_last_standing', { 1 })

    -- 3000 out of three pockets, 3000 into one. Not a dollar of it stayed
    -- behind with the player who dropped, and not a dollar was invented.
    t.equals(server.cash(1), 7000, 'the winner was not paid the forfeited stake')
    t.equals(server.movements(1), 2, 'expected one stake out and one payout in')
    t.equals(server.cash(2), 4000)
    t.equals(server.movements(2), 1)
    t.equals(server.cash(3), 4000)
    t.equals(server.movements(3), 1, 'the player who dropped was paid something')
    t.equals(server.ledgerTotal(), 0, 'the pot did not add up')

    t.notContains(server.log(), 'CLEAR REFUSED')
    t.isNil(server.lobby.Get(matchId))
end)

t.test('with refundOnDisconnectBeforeStart off, walking out of a lobby forfeits too', function()
    -- The key does not separate a player who quit from one who crashed, and
    -- neither does its mid-round sibling. A rule that only charged real
    -- disconnects would take money from the players whose game fell over and
    -- hand it back to the ones who chose to leave.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Betting.refundOnDisconnectBeforeStart = false
    end)
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    server.fire('leaveMatch', 3)

    t.equals(server.movements(3), 1)
    t.contains(server.told(3), 'Stake gone')
    t.equals(server.betting.GetPot(matchId), 3000)
end)

t.test('the lobby key does not reach into a live round -- that is refundOnDisconnectDuringMatch', function()
    -- Shipped positions for both: the lobby refunds, the live round does
    -- not. A drop from a match being fought must still read the mid-round
    -- key, whatever the lobby key says.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2, 3 })
    server.lobby.Get(matchId).state = 'live'

    server.drop(3)

    t.equals(server.cash(3), 4000, 'a mid-round drop was refunded by the lobby rule')
    t.equals(server.movements(3), 1)
    t.equals(server.betting.GetPot(matchId), 3000)
end)

t.test('a live round still refunds when refundOnDisconnectDuringMatch says so', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        -- The two keys set against each other, so neither can be answering
        -- for the other.
        config.Betting.refundOnDisconnectBeforeStart = false
        config.Betting.refundOnDisconnectDuringMatch = true
    end)
    local matchId = openLobby(server, 1000, { 1, 2, 3 })
    server.lobby.Get(matchId).state = 'live'

    server.drop(3)

    t.equals(server.cash(3), 5000)
    t.equals(server.movements(3), 2)
    t.equals(server.betting.GetPot(matchId), 2000)
end)

-- ======================================================================
-- Config.Permissions.joinJobs
-- ======================================================================

t.test('an empty joinJobs list admits everybody', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })

    -- Answered without a player lookup at all, which is what makes the
    -- shipped default free: even an id with no character behind it passes.
    t.isTrue(server.env.ArenaCanJoin(1))
    t.isTrue(server.env.ArenaCanJoin(999))

    local matchId = openLobby(server, 1000, { 1, 2 })
    t.equals(server.betting.GetPot(matchId), 2000, 'both players were let in and staked')
end)

t.test('a joinJobs list admits only the jobs on it', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Permissions.joinJobs = { 'police' }
    end, { [1] = 'police', [2] = 'police' })

    local matchId = openLobby(server, 1000, { 1, 2 })
    server.fire('joinMatch', 3, { matchId = matchId })

    t.isNil(server.lobby.Get(matchId).players[3], 'an unlisted job got into the match')
    t.contains(server.told(3), 'You are not cleared for that.')
    -- Refused BEFORE the stake, the way ArenaCanCreate is: a player told no
    -- must not be a player charged for it.
    t.equals(server.movements(3), 0, 'a refused join took money')
    t.equals(server.betting.GetPot(matchId), 2000)
end)

t.test('joinJobs is read in both the spellings an operator writes it in', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Permissions.joinJobs = { police = true }
    end, { [1] = 'police' })

    t.isTrue(server.env.ArenaCanJoin(1), 'the map spelling was not honoured')
    t.isFalse(server.env.ArenaCanJoin(2))
end)

t.test('a source with no loaded character is refused by a non-empty joinJobs', function()
    local server = newArena({ [1] = 5000 }, function(config)
        config.Permissions.joinJobs = { 'police' }
    end)
    t.isFalse(server.env.ArenaCanJoin(999), 'an unknown source cleared a job check')
    t.isFalse(server.env.ArenaCanJoin(nil))
end)

t.test('a host joinJobs excludes cannot open a match either', function()
    -- The host joins through the same door as everybody else, so the create
    -- unwinds whole: no match, no seat, no stake.
    local server = newArena({ [1] = 5000 }, function(config)
        config.Permissions.joinJobs = { 'police' }
    end)

    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 1000 })

    t.equals(#server.lobby.All(), 0, 'a lobby its own host may not enter was left open')
    t.equals(server.movements(1), 0)
    t.contains(server.told(1), 'You are not cleared for that.')
end)

t.test('createJobs and joinJobs stay two separate lists', function()
    -- One rule reads both, so the test that matters is that it reads them
    -- from different keys: police may open a match here, anyone may join it.
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Permissions.createJobs = { 'police' }
        config.Permissions.joinJobs = {}
    end, { [1] = 'police' })

    t.isTrue(server.env.ArenaCanCreate(1))
    t.isFalse(server.env.ArenaCanCreate(2), 'createJobs stopped being enforced')
    t.isTrue(server.env.ArenaCanJoin(2))

    local matchId = openLobby(server, 1000, { 1, 2 })
    t.equals(server.betting.GetPot(matchId), 2000)

    server.fire('createMatch', 2, { arenaKey = 'beach', modeKey = 'ffa', entryFee = 1000 })
    t.equals(#server.lobby.All(), 1, 'an unlisted job opened a second match')
end)

-- ========================================================================
-- ONE LOADOUT FOR THE WHOLE MATCH
--
-- Config.Loadouts.chooser = 'host' makes the host pick once for everybody,
-- so a round is decided by the players rather than by who picked the better
-- gun. The panel greys the picker out for everyone else, but the panel is a
-- suggestion: these tests are about the server, which is the only thing that
-- can actually refuse.
-- ========================================================================

--- What one player will be handed when the round starts.
--- @return string
local function weaponsOf(server, matchId, src)
    local player = server.lobby.Get(matchId).players[src]
    local names = {}
    for _, entry in ipairs(player.loadout.weapons or {}) do
        names[#names + 1] = entry.key or entry.weapon
    end
    table.sort(names)
    return table.concat(names, ',')
end

--- A loadout request naming one weapon by its config key.
local function pick(key)
    return { weapons = { { key = key } } }
end

t.test("in host mode the host's pick is what every player carries", function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Loadouts.chooser = 'host'
    end)
    local matchId = openLobby(server, 0, { 1, 2, 3 })

    server.fire('setLoadout', 1, pick('sniper'))

    local host = weaponsOf(server, matchId, 1)
    t.contains(host, 'sniper', 'the host did not get their own pick')
    t.equals(weaponsOf(server, matchId, 2), host, 'player 2 is carrying something else')
    t.equals(weaponsOf(server, matchId, 3), host, 'player 3 is carrying something else')
end)

t.test('a player who is not the host cannot change it, panel or no panel', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Loadouts.chooser = 'host'
    end)
    local matchId = openLobby(server, 0, { 1, 2 })

    server.fire('setLoadout', 1, pick('sniper'))
    local before = weaponsOf(server, matchId, 2)

    -- A crafted request, exactly as a modified client would send it.
    server.fire('setLoadout', 2, pick('pistol'))

    t.equals(weaponsOf(server, matchId, 2), before,
        'a guest armed themselves past the host')
    t.equals(weaponsOf(server, matchId, 1), before,
        "and did not rewrite the host's either")
end)

t.test('somebody who joins after the pick inherits it rather than the default', function()
    -- The one that would otherwise be missed: everything looks right for the
    -- players who were present, and the late joiner is the only one on the
    -- shipped default, holding a different gun to the rest of the match.
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Loadouts.chooser = 'host'
    end)
    local matchId = openLobby(server, 0, { 1 })

    server.fire('setLoadout', 1, pick('sniper'))
    server.fire('joinMatch', 2, { matchId = matchId })

    t.equals(weaponsOf(server, matchId, 2), weaponsOf(server, matchId, 1),
        'the late joiner is armed differently to everybody else')
end)

t.test('the copies are separate tables, so one player cannot climb for everyone', function()
    -- Gun game rewrites a player's loadout in place as they climb the
    -- ladder. Share one table between players and the first kill promotes
    -- the entire match at once.
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Loadouts.chooser = 'host'
    end)
    local matchId = openLobby(server, 0, { 1, 2 })
    server.fire('setLoadout', 1, pick('sniper'))

    local match = server.lobby.Get(matchId)
    t.isFalse(match.players[1].loadout == match.players[2].loadout,
        'two players share one loadout table')
end)

t.test("in player mode everybody picks their own again", function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Loadouts.chooser = 'player'
    end)
    local matchId = openLobby(server, 0, { 1, 2 })

    server.fire('setLoadout', 1, pick('sniper'))
    server.fire('setLoadout', 2, pick('pistol'))

    t.contains(weaponsOf(server, matchId, 1), 'sniper')
    t.contains(weaponsOf(server, matchId, 2), 'pistol')
    t.isFalse(weaponsOf(server, matchId, 1) == weaponsOf(server, matchId, 2),
        'host mode is still in force with chooser set to player')
end)

-- ========================================================================
-- THE POT REACHES THE WINNER
--
-- THE SEAM NOTHING COVERED. matchflow_spec stubs ArenaBetting entirely, so it
-- proves a round runs but never that money moves. payoutchain_spec calls
-- Settle directly with a context built by hand, so it proves the arithmetic
-- but never that server/match.lua builds that context correctly from a real
-- match. Between those two specs sat the entire chain an operator actually
-- runs -- stakes taken at the lobby, held through a round, and handed to a
-- winner -- with nothing driving it end to end.
--
-- This file already loads the REAL util, betting, lobby and match, so it is
-- where that chain can be driven for real.
-- ========================================================================

t.test('two players stake, one wins, and the pot reaches them', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2 })

    t.equals(server.betting.GetPot(matchId), 2000, 'the stakes never reached escrow')
    t.equals(server.cash(1), 4000)
    t.equals(server.cash(2), 4000)

    server.lobby.Get(matchId).state = 'live'
    server.match.End(matchId, 'match.ended', { 1 })

    t.equals(server.cash(1), 6000, 'the winner was not paid the pot')
    t.equals(server.cash(2), 4000, 'the loser got money back')
    t.equals(server.ledgerTotal(), 0, 'money was created or destroyed')
end)

t.test('and the pot is empty afterwards rather than paid twice', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.lobby.Get(matchId).state = 'live'
    server.match.End(matchId, 'match.ended', { 1 })

    t.equals(server.betting.GetPot(matchId), 0, 'the pot still claims to hold money')
    t.equals(server.cash(1), 6000)
end)

t.test('a three-way pot goes entirely to the one winner', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2, 3 })

    t.equals(server.betting.GetPot(matchId), 3000)

    server.lobby.Get(matchId).state = 'live'
    server.match.End(matchId, 'match.ended', { 2 })

    t.equals(server.cash(2), 7000, 'the winner did not receive the whole pot')
    t.equals(server.cash(1), 4000)
    t.equals(server.cash(3), 4000)
    t.equals(server.ledgerTotal(), 0)
end)

t.test('the winner is paid exactly once, counted by movements not by balance', function()
    -- A double payout and a missing one can leave the same number behind
    -- once other movements are in play, so the count is the assertion.
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.lobby.Get(matchId).state = 'live'
    server.match.End(matchId, 'match.ended', { 1 })

    -- One out (the stake), one in (the pot).
    t.equals(server.movements(1), 2, 'the winner was paid a number of times that is not once')
    t.equals(server.movements(2), 1, 'the loser was paid or refunded')
end)

t.test('THE REAL FINISH: a kill ends the round through the sweep and the pot is paid', function()
    -- The previous tests call End() themselves, which skips the part of the
    -- chain a server actually runs: a death is reported, the sweep thread
    -- evaluates the round, and IT decides who won. If evaluate() hands back
    -- an empty winner list the pot is refunded rather than paid -- money
    -- comes back, nobody wins, and from a player's seat that is
    -- indistinguishable from the arena being broken.
    -- One life, stated rather than inherited: lives now default to three and
    -- a host may pick, so a single death no longer ends a round. This test is
    -- about the MONEY reaching a winner, and it needs a round that finishes.
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Match.lives = 1
    end)
    local matchId = openLobby(server, 1000, { 1, 2 })

    t.equals(server.betting.GetPot(matchId), 2000)

    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.fire('startMatch', 1)

    -- Whatever the countdown does, get the round live and then kill one.
    local match = server.lobby.Get(matchId)
    match.state = 'live'
    server.fire('reportDeath', 2, { matchId = matchId, killer = 1 })

    -- The sweep is what ends a round. Two steps: the first only primes it.
    server.step()
    server.step()

    t.isNil(server.lobby.Get(matchId), 'the round never ended')
    t.equals(server.cash(1), 6000, 'the winner was not paid -- the pot was refunded instead')
    t.equals(server.cash(2), 4000, 'the loser got their stake back')
    t.equals(server.ledgerTotal(), 0)
end)

-- ========================================================================
-- THE HOST CHOOSES HOW MANY LIVES
-- ========================================================================

t.test('the number the host picks is the number every player gets', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, lives = 5 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the lobby was refused')
    t.equals(match.lives, 5, 'the host\'s choice was not recorded on the match')

    server.fire('joinMatch', 2, { matchId = match.id })
    t.equals(match.players[2].lives, 5, 'a joiner is playing a different match to the host')
end)

t.test('a number outside the allowed range is refused, not quietly clamped', function()
    -- A host who typed 99 and silently got 10 would believe they were running
    -- a different match to the one they are in.
    local server = newArena({ [1] = 5000 })
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, lives = 99 })

    t.equals(#server.lobby.All(), 0, 'an out-of-range choice opened a lobby anyway')
end)

t.test('a host who picks nothing gets the operator default', function()
    local server = newArena({ [1] = 5000 })
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match)
    t.equals(match.lives, 3, 'the shipped default is not what an unspecified match gets')
end)

t.test('an operator who fixes the number takes the choice away entirely', function()
    -- Config.Match.lives as a plain number rather than a table: nobody
    -- chooses, and a host asking for something else is ignored rather than
    -- refused, because there is no range to be outside of.
    local server = newArena({ [1] = 5000 }, function(config)
        config.Match.lives = 2
    end)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, lives = 9 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'a fixed-lives server refused a match')
    t.equals(match.lives, 2, 'the host overrode a number the operator had fixed')
end)

-- ========================================================================
-- THE HOST EDITING A LOBBY THEY HAVE ALREADY OPENED
--
-- Picking the wrong arena used to mean closing the lobby and opening
-- another, which refunds and re-takes every stake, drops everybody who had
-- joined, and costs the host their own place -- for a mistake that takes one
-- click to make.
-- ========================================================================

t.test('the host can change the arena, the mode and the lives of an open lobby', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 0, { 1, 2 })

    server.fire('updateMatch', 1, { arenaKey = 'beach', modeKey = 'tdm', lives = 5 })

    local match = server.lobby.Get(matchId)
    t.equals(match.arenaKey, 'beach', 'the arena did not change')
    t.equals(match.modeKey, 'tdm', 'the mode did not change')
    t.equals(match.lives, 5, 'the lives did not change')
end)

t.test('and the change reaches everybody already in the lobby, not only the next joiner', function()
    -- A lobby where the host changed the rules and half the room is still on
    -- the old ones is worse than not allowing the change at all.
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 0, { 1, 2 })

    server.fire('updateMatch', 1, { lives = 7 })

    local match = server.lobby.Get(matchId)
    t.equals(match.players[1].lives, 7)
    t.equals(match.players[2].lives, 7, 'a player already in the lobby kept the old rule')
end)

t.test('a guest cannot edit the host\'s match', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 0, { 1, 2 })

    server.fire('updateMatch', 2, { arenaKey = 'beach', lives = 9 })

    local match = server.lobby.Get(matchId)
    t.equals(match.arenaKey, 'airfield', 'a guest moved the match to another arena')
    t.equals(match.lives, 3, 'a guest rewrote the rules')
end)

t.test('the entry fee is refused, because it has already been paid', function()
    -- Not a limitation, a decision. Everybody in the lobby paid the fee that
    -- was advertised when they joined; changing it afterwards either charges
    -- them for something they did not agree to or gives late joiners a
    -- different deal. A host who wants a different fee opens another lobby.
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 1000, { 1, 2 })

    server.fire('updateMatch', 1, { entryFee = 4000 })

    t.equals(server.lobby.Get(matchId).entryFee, 1000, 'the entry fee was changed after it was paid')
    t.equals(server.betting.GetPot(matchId), 2000, 'the pot moved')
end)

t.test('nothing can be edited once the round has started', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openLobby(server, 0, { 1, 2 })
    server.lobby.Get(matchId).state = 'live'

    server.fire('updateMatch', 1, { arenaKey = 'beach', lives = 9 })

    local match = server.lobby.Get(matchId)
    t.equals(match.arenaKey, 'airfield', 'a match being fought is not a form')
    t.equals(match.lives, 3)
end)

t.test('a request naming an arena that does not exist changes nothing at all', function()
    -- Validated before anything is written, so a half-legal request does not
    -- leave the match half changed.
    local server = newArena({ [1] = 5000 })
    local matchId = openLobby(server, 0, { 1 })

    server.fire('updateMatch', 1, { arenaKey = 'atlantis', lives = 8 })

    local match = server.lobby.Get(matchId)
    t.equals(match.arenaKey, 'airfield')
    t.equals(match.lives, 3, 'the legal half of an illegal request was applied anyway')
end)

os.exit(t.summary())
