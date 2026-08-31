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

os.exit(t.summary())
