--[[
    crimson_arena/tests/countdownexit_spec.lua

    One narrow window, and the regression that lived in it.

    Start() teleports everybody into the arena, hands out weapons, sets each
    player's routing bucket and raises their dispatch flag -- and leaves the
    match at state 'countdown'. Only goLive(), Config.Match.startCountdownSeconds
    later, promotes it to 'live'. For the whole of that frozen countdown a
    player is physically standing in the arena while the match does not yet
    call itself live.

    server/main.lua's detach() used to ask ArenaMatch.IsLive, which is
    `state == 'live'` and nothing else. So a player who left during that
    window was routed to ArenaLobby.Leave instead of ArenaMatch.RemovePlayer,
    and no exit was ever sent for them. Two things leaked, neither of which
    the player could fix:

      * the dispatch flag, so their police and medical alerts stayed
        suppressed for the rest of their session -- they could rob a bank in
        silence;
      * their routing bucket, leaving them in an instance nobody else is in.

    ArenaMatch.RemovePlayer's own predicate has always been the correct one
    ('live' OR 'countdown'). detach() held a narrower copy of it that drifted.

    The whole suite passed before the fix and after it, which is exactly why
    this file exists: nothing else drives an exit through this window.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- A server with the real util/betting/lobby/match/main loaded, and an
--- ArenaDispatch double that RECORDS rather than ignores -- the leak this
--- file is about is a call that never happened, so the calls are the
--- assertion.
--- @return table server
local function newServer()
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host', money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents, handlers = {}, {}, {}
    local dispatch = { cleared = {}, set = {}, bucketIn = {}, bucketOut = {} }

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
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
            Set = function(src) dispatch.set[#dispatch.set + 1] = src end,
            Clear = function(src) dispatch.cleared[#dispatch.cleared + 1] = src end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function(src) dispatch.bucketIn[#dispatch.bucketIn + 1] = src end,
            ExitBucket = function(src) dispatch.bucketOut[#dispatch.bucketOut + 1] = src end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- No lobby countdown, and a long freeze: that puts everybody in the arena
    -- immediately and holds the match at 'countdown' for the whole test,
    -- which IS the window under examination.
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 30
    env.Config.Match.minPlayers = 2

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, dispatch = dispatch, lobby = env.ArenaLobby, match = env.ArenaMatch }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    --- One pass of every live coroutine. Deliberately explicit: the freeze
    --- is a CreateThread + Wait, and the sandbox's Wait yields once, so a
    --- single extra step is the difference between a frozen countdown and a
    --- live round.
    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Every event of one name sent to one player.
    function server.sentTo(event, target)
        local hits = 0
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                hits = hits + 1
            end
        end
        return hits
    end

    function server.countOf(list, value)
        local hits = 0
        for _, entry in ipairs(list) do if entry == value then hits = hits + 1 end end
        return hits
    end

    return server
end

--- Opens a match with 1 and 2 in it and starts it, leaving the match frozen
--- at 'countdown' with both players already in the arena.
--- @return table server
--- @return string matchId
local function frozenCountdown()
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })

    -- Exactly one: Start() runs and the freeze thread it spawns parks on its
    -- Wait. Two would resume that Wait and take us into 'live'.
    server.step(1)

    return server, match.id
end

-- ========================================================================
-- The window itself
-- ========================================================================

t.test('the window exists: players are in the arena while the match is still "countdown"', function()
    local server, matchId = frozenCountdown()
    local match = server.lobby.Get(matchId)

    t.isNotNil(match, 'the match vanished before the countdown')
    t.equals(match.state, 'countdown', 'the match should still be frozen, not live')
    t.isFalse(server.match.IsLive(matchId), 'IsLive is false here -- that is the whole trap')

    -- Physically in the arena: both were sent there and both were flagged.
    t.equals(server.sentTo('enterArena', 1), 1)
    t.equals(server.sentTo('enterArena', 2), 1)
    t.equals(server.countOf(server.dispatch.set, 2), 1, 'the rival was flagged as being in an arena')
end)

-- ========================================================================
-- Leaving through it -- the regression
-- ========================================================================

t.test('leaving during the countdown sends an exit, clears the flag and gives the bucket back', function()
    local server, matchId = frozenCountdown()

    server.fire('leaveMatch', 2)

    t.equals(server.sentTo('exitArena', 2), 1,
        'no exitArena: the player is standing in the arena with nothing coming to take them out of it')
    t.equals(server.countOf(server.dispatch.cleared, 2), 1,
        'the dispatch flag was never cleared -- their alerts stay suppressed for the rest of the session')
    t.equals(server.countOf(server.dispatch.bucketOut, 2), 1,
        'the routing bucket was never returned -- they are left in an instance nobody else is in')

    local match = server.lobby.Get(matchId)
    if match then t.isNil(match.players[2], 'they are still counted as a fighter') end
end)

t.test('disconnecting during the countdown does the same', function()
    local server = frozenCountdown()

    server.drop(2)

    -- At least once, not exactly once: main.lua's playerDropped handler
    -- clears again after detach on purpose, as a catch for a player who
    -- dropped between being placed in the arena and the match recording it.
    -- Clear is idempotent, so the second call is a no-op -- what matters
    -- here is that it happened at all.
    t.isTrue(server.countOf(server.dispatch.cleared, 2) >= 1, 'a dropped player kept the flag')
    t.isTrue(server.countOf(server.dispatch.bucketOut, 2) >= 1, 'a dropped player kept the bucket')
end)

t.test('the host leaving during the countdown is cleaned up too', function()
    local server = frozenCountdown()

    server.fire('leaveMatch', 1)

    t.equals(server.sentTo('exitArena', 1), 1)
    t.equals(server.countOf(server.dispatch.cleared, 1), 1)
    t.equals(server.countOf(server.dispatch.bucketOut, 1), 1)
end)

-- ========================================================================
-- The states either side of it, so the fix did not widen anything
-- ========================================================================

t.test('leaving a plain lobby still does NOT send an arena exit', function()
    -- Nobody has been teleported anywhere, so there is nothing to exit from.
    -- A fix that sent one here would be firing arena teardown at a player
    -- standing in the lobby.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })

    server.fire('leaveMatch', 2)

    t.equals(server.sentTo('exitArena', 2), 0)
    t.equals(server.sentTo('enterArena', 2), 0)
    t.isNil(match.players[2])
end)

t.test('leaving once the round is live is cleaned up, as it always was', function()
    local server, matchId = frozenCountdown()
    -- One more pass resumes the freeze thread's Wait, which calls goLive.
    server.step(2)
    t.isTrue(server.match.IsLive(matchId), 'the match never went live')

    server.fire('leaveMatch', 2)

    t.equals(server.sentTo('exitArena', 2), 1)
    t.equals(server.countOf(server.dispatch.cleared, 2), 1)
end)

t.test('a player in no match at all is not sent an arena exit', function()
    local server = newServer()
    server.fire('leaveMatch', 2)
    t.equals(server.sentTo('exitArena', 2), 0)
end)

print('countdownexit_spec')
os.exit(t.summary())
