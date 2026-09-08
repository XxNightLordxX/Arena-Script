--[[
    crimson_arena/tests/holdstart_spec.lua

    STOPPING A COUNTDOWN WITHOUT DESTROYING THE MATCH.

    The panel has a button that reads "Stop The Countdown", with a tooltip
    that reads "Hold the start. Everybody stays in the lobby and nobody loses
    their place." It posted `cancelMatch`, which destroys the match, evicts
    every player in it, and on a server with refundOnCancel switched off
    burns every stake in the pot.

    So a host who read the button and pressed it broke up their own lobby --
    and there was nothing on screen to tell them that is what it did.

    Nothing had to be undone to fix it. ArenaMatch.Begin's countdown thread
    re-reads the match every second and returns the moment its state is not
    'countdown', so putting the state back IS the stop. What these assert is
    that it is a HOLD and not a cancel: the match survives, the roster
    survives, the money stays exactly where it was, and the round can be
    started again afterwards.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('holdstart_spec')

--- @param wallets table<integer, table> -- [src] = { cash = n, bank = n }
local function newServer(wallets, mutate)
    local players = {}
    for src, money in pairs(wallets) do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = money.cash or 0, bank = money.bank or 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent = {}, {}, {}
    -- Who has actually been teleported into the arena, which is a different
    -- question to what the match calls its own state.
    local inArena = {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        -- CAPTURED, not swallowed. What the room is TOLD when a countdown
        -- ends in nothing is the whole of the last test in this file, and a
        -- stub that drops every client event answers "nothing was said" no
        -- matter what the server did.
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        -- Nothing here drives a disconnect, so the handlers are taken and
        -- dropped rather than kept: an unused table that looks like a
        -- fixture is a fixture somebody will wonder why nothing uses.
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        -- RECORDING, because playersArePlaced is exactly what decides whether
        -- a start may still be held, and it asks this double. A stub that
        -- always says "nobody is in the arena" would let the guard pass every
        -- test while never being exercised once.
        ArenaDispatch = {
            Set = function(src) inArena[src] = true end,
            Clear = function(src) inArena[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return inArena[src] == true end,
            ClearDownState = function() return 0 end,
            EnterBucket = function(src) inArena[src] = true end,
            ExitBucket = function(src) inArena[src] = nil end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, lobby = env.ArenaLobby, match = env.ArenaMatch }

    --- The SENTENCES notified to one player, oldest first.
    ---
    --- Rendered, not keys, and the docstring said the opposite for a while.
    --- This fixture loads the real locales/en.json and ArenaNotifyKey renders
    --- before it sends, so what reaches the wire is finished text. Use
    --- `server.wasTold` below rather than this: it renders the key it is
    --- given and compares like with like. An assertion written against a raw
    --- key here would never match, and would be a test of nothing.
    --- @param src integer
    --- @return string[]
    function server.notices(src)
        local out = {}
        for _, message in ipairs(sent) do
            if message.target == src and tostring(message.event):find('notify', 1, true) then
                out[#out + 1] = tostring(type(message.payload) == 'table'
                    and (message.payload.description or message.payload.key)
                    or message.payload)
            end
        end
        return out
    end

    --- Whether `src` was told the thing `key` names, at any point.
    ---
    --- RENDERED, because this fixture loads the real locale file and
    --- ArenaNotifyKey renders before it sends -- so what arrives on the wire
    --- is the sentence. Compared against locale(key) rather than against a
    --- sentence typed into the test, so rewording en.json does not
    --- quietly turn these into tests of nothing.
    --- @param src integer
    --- @param key string
    --- @return boolean
    function server.wasTold(src, key)
        local wanted = env.locale(key)
        for _, said in ipairs(server.notices(src)) do
            if said == wanted then return true end
        end
        return false
    end

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- One pass of every captured coroutine, which is how the countdown
    --- thread gets to notice it has been stood down.
    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Whether anybody has been put in the arena yet.
    function server.placedAnyone()
        return next(inArena) ~= nil
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    return server
end


--- A lobby with two players in it, counting down.
--- @return table server
--- @return string matchId
local function counting(fee, mutate)
    local server = newServer({
        [1] = { cash = 50000, bank = 50000 },
        [2] = { cash = 50000, bank = 50000 },
    }, mutate)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = fee or 0 })
    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('startMatch', 1)

    t.equals(server.lobby.Get(match.id).state, 'countdown',
        'the match is not counting down, so there is nothing to stop')
    return server, match.id
end

-- A lobby countdown long enough to be stopped in the middle of.
local function slowLobby(config) config.Match.lobbyCountdownSeconds = 10 end

-- ======================================================================
-- IT IS A HOLD, NOT A CANCEL
-- ======================================================================

t.test('holding a countdown puts the match back to a lobby', function()
    local server, matchId = counting(0, slowLobby)
    local ok = server.lobby.HoldCountdown(1)
    t.isTrue(ok, 'the host could not stop their own countdown')

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'THE MATCH WAS DESTROYED -- this is a cancel, not a hold')
    t.equals(match.state, 'lobby')
    t.equals(match.startsAt, 0, 'the panel is still counting down to a moment that is not coming')
end)

t.test('and everybody keeps their place in it', function()
    local server, matchId = counting(0, slowLobby)
    server.lobby.HoldCountdown(1)

    local match = server.lobby.Get(matchId)
    t.isNotNil(match.players[1], 'the host lost their own place')
    t.isNotNil(match.players[2], 'a player was evicted by a button that said they would not be')
end)

t.test('and every stake stays exactly where it was', function()
    -- The worst of it. With refundOnCancel off, the cancel this button used
    -- to post FORFEITS the pot -- so a host stopping a start they had just
    -- called took everybody's entry fee with it.
    local server, matchId = counting(1000, function(config)
        slowLobby(config)
        config.Betting.refundOnCancel = false
    end)
    t.equals(server.betting.GetPot(matchId), 2000, 'the fees were never taken')

    server.lobby.HoldCountdown(1)

    t.equals(server.betting.GetPot(matchId), 2000,
        'THE POT MOVED. Holding a start is not a settlement and must touch no money')
    t.equals(server.cash(1), 49000, 'the host was charged twice, or refunded')
    t.equals(server.cash(2), 49000)
end)

t.test('the countdown thread really does stand down', function()
    -- The mechanism, asserted rather than assumed: the thread re-reads the
    -- match each second, and a thread that missed the change would start the
    -- round anyway a few ticks later.
    local server, matchId = counting(0, slowLobby)
    server.lobby.HoldCountdown(1)

    server.step(12)

    t.equals(server.lobby.Get(matchId).state, 'lobby',
        'the round started anyway -- the countdown never noticed it was stopped')
end)

-- A one-second lobby countdown, so the thread's FINAL Wait is a place a
-- test can stand: one step parks it there, and everything after that step
-- happens in the window the loop never re-read.
local function lastSecond(config) config.Match.lobbyCountdownSeconds = 1 end

t.test('DEFECT: holding it in the LAST second stops it too', function()
    -- The check that stands the thread down runs at the TOP of the loop --
    -- before each Wait, never after the final one. So whatever happened
    -- during the last second was never read: a hold in it returned success
    -- to the host, put the lobby back to waiting, told the room it was held,
    -- and the round started anyway a moment later. ArenaMatch.Start accepts
    -- 'lobby' as well as 'countdown', so nothing further down caught it.
    local server, matchId = counting(0, lastSecond)

    -- One step: the thread has made its only state check and is parked in
    -- its final Wait.
    server.step(1)
    t.equals(server.lobby.Get(matchId).state, 'countdown',
        'the countdown finished before the window opened, so this tests nothing')
    t.isFalse(server.env.ArenaDispatch.IsPlayerInArena(1), 'the room is already in the arena')

    t.isTrue(server.lobby.HoldCountdown(1), 'the host could not stop their own countdown')
    server.step(4)

    t.equals(server.lobby.Get(matchId).state, 'lobby',
        'the round started after the host was told it had been stopped')
    t.isFalse(server.env.ArenaDispatch.IsPlayerInArena(1),
        'the room was teleported into the arena by a countdown that had been stopped')
end)

t.test('and starting again opens a NEW countdown the old one cannot claim', function()
    -- `state` cannot tell a parked thread whether it still owns the match:
    -- hold and start again and it goes countdown -> lobby -> countdown,
    -- which the old thread cannot distinguish from never having been held.
    -- It would wake into the NEW countdown, find its own count spent, and
    -- start the round -- with the panel still showing seconds and players
    -- still choosing weapons. So each countdown is numbered, and the thread
    -- checks its own number before starting anything.
    --
    -- WHAT THIS ASSERTS IS THE NUMBERING, not the race. This fixture's Wait
    -- does not model elapsed time -- a hundred-second countdown finishes in
    -- the same two steps as a ten-second one -- so the two threads cannot be
    -- told apart here by stepping. The number changing is the part that is
    -- observable, and it is the part the guard depends on.
    local server, matchId = counting(0, lastSecond)
    local first = server.lobby.Get(matchId).countdownToken
    t.isNotNil(first, 'a countdown is not numbered at all, so no thread can tell whose it is')

    server.step(1)
    server.lobby.HoldCountdown(1)
    server.fire('startMatch', 1)

    local second = server.lobby.Get(matchId).countdownToken
    t.equals(server.lobby.Get(matchId).state, 'countdown')
    t.isTrue(second ~= first,
        ('both countdowns are numbered %s, so the held one still owns the match'):format(tostring(second)))
end)

t.test('and the countdown that IS the current one still starts the round', function()
    -- The other direction, so none of this is "fixed" by never starting.
    local server, matchId = counting(0, lastSecond)
    server.step(4)

    t.isTrue(server.env.ArenaDispatch.IsPlayerInArena(1),
        'a countdown nobody touched never put anybody in the arena')
    t.isFalse(server.lobby.Get(matchId).state == 'lobby')
end)

t.test('and the round can be started again afterwards', function()
    -- A hold that leaves the match unstartable is a cancel with extra steps.
    local server, matchId = counting(0, slowLobby)
    server.lobby.HoldCountdown(1)

    server.fire('startMatch', 1)
    t.equals(server.lobby.Get(matchId).state, 'countdown',
        'the match could not be started again after being held')
end)

-- ======================================================================
-- WHO MAY, AND WHEN
-- ======================================================================

t.test('a player who is not the host cannot stop the start', function()
    local server, matchId = counting(0, slowLobby)
    local ok, reason = server.lobby.HoldCountdown(2)

    t.isFalse(ok, 'anybody in the lobby could stop the host\'s start')
    t.equals(reason, 'error.host_only')
    t.equals(server.lobby.Get(matchId).state, 'countdown')
end)

t.test('and a lobby that is not counting down has nothing to stop', function()
    local server = newServer({ [1] = { cash = 50000, bank = 50000 } })
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local ok = server.lobby.HoldCountdown(1)
    t.isFalse(ok, 'a lobby that never started was "stopped"')
end)

t.test('nor may it be stopped once the room is standing in the arena', function()
    -- `state` cannot answer this: ArenaMatch.Begin calls the LOBBY countdown
    -- 'countdown' and ArenaMatch.Start calls the FROZEN start countdown the
    -- same thing, after teleporting everybody in. Stopping the second one
    -- would leave a room full of armed players in an arena the match record
    -- says is a lobby.
    local server, matchId = counting(0, function(config)
        config.Match.lobbyCountdownSeconds = 0
        config.Match.startCountdownSeconds = 30
    end)
    server.step(4)
    t.isTrue(server.placedAnyone(), 'nobody was teleported in, so this proves nothing')

    local ok, reason = server.lobby.HoldCountdown(1)
    t.isFalse(ok, 'a start was held after the room was already standing in the arena')
    t.equals(reason, 'error.match_in_progress')
    t.isNotNil(matchId)
end)

-- ======================================================================
-- AND A COUNTDOWN THAT ENDS IN NOTHING SAYS WHY
-- ======================================================================
--
-- The same thread, one line further on. ArenaMatch.Start can refuse at the
-- moment the countdown reaches zero -- the arena taken by another round,
-- somebody without a side, the doors shutting inside the last few seconds,
-- a roster that dropped under the minimum -- and everything around that
-- refusal is careful: nobody is moved, the lobby goes back to `waiting`,
-- the state is broadcast.
--
-- And then the reason was thrown away. `ArenaMatch.Start(matchId)` was
-- called for its side effects and its two return values were dropped, so
-- the numbers counted to zero, stopped, and the room stood in the lobby
-- with no word of any kind about what had just happened.

t.test('THE SILENCE: a start refused at zero left the room with no word', function()
    local server, matchId = counting(0, lastSecond)

    -- One step parks the thread in its final Wait, which is the window the
    -- round is decided in.
    server.step(1)
    t.equals(server.lobby.Get(matchId).state, 'countdown',
        'the countdown finished before the window opened, so this tests nothing')

    -- The arena goes away underneath them. Any of Start's refusals would do;
    -- this one needs no second match and no clock.
    server.config.Arenas.trailerpark.enabled = false
    server.step(4)

    t.equals(server.lobby.Get(matchId).state, 'lobby',
        'the round started on an arena that is no longer there')
    t.isTrue(server.wasTold(1, 'error.arena_unavailable'),
        'the host watched their countdown reach zero and was told nothing: '
            .. table.concat(server.notices(1), ', '))
    t.isTrue(server.wasTold(2, 'error.arena_unavailable'),
        'the other fighter was told nothing either: '
            .. table.concat(server.notices(2), ', '))
end)

t.test('and a countdown that DOES start says nothing, which is the control', function()
    -- A fix that notified unconditionally would pass the test above and put
    -- an error in front of every player at the start of every round.
    local server, matchId = counting(0, lastSecond)

    server.step(6)

    t.isTrue(server.lobby.Get(matchId).state ~= 'lobby',
        'the round never started, so this proves nothing about a good one')
    t.isFalse(server.wasTold(1, 'error.arena_unavailable'),
        'a round that started told the host it had been refused')
    t.isFalse(server.wasTold(2, 'error.arena_unavailable'))
end)

t.test('and every ready is taken back, or the lobby can never try again', function()
    -- A round starts two ways: the host presses Start, or the LAST person
    -- readies up and SetReady begins it. So a lobby where everybody is
    -- already ready has no way to retry -- there is no last person left.
    --
    -- Left alone, the refusal produced a room where every row read Ready,
    -- every button offered to take a ready back, the clock was gone, and on
    -- the shipped `onlyHostCanStart` a fighter who is not the host had
    -- nothing on screen to press at all.
    local server, matchId = counting(0, lastSecond)

    -- READY, the way a full lobby that started itself would be. `counting`
    -- begins the round directly, so nothing has set these.
    for _, src in ipairs({ 1, 2 }) do server.lobby.Get(matchId).players[src].ready = true end

    server.step(1)
    t.equals(server.lobby.Get(matchId).state, 'countdown',
        'the countdown finished before the window opened, so this tests nothing')
    t.isTrue(server.lobby.Get(matchId).players[1].ready,
        'nobody was ready to begin with, so this proves nothing')

    server.config.Arenas.trailerpark.enabled = false
    server.step(4)

    local failed = server.lobby.Get(matchId)
    t.equals(failed.state, 'lobby', 'the round started on an arena that is no longer there')
    t.isFalse(failed.players[1].ready == true,
        'the host was left marked ready with nothing that would ever act on it')
    t.isFalse(failed.players[2].ready == true, 'and so was the other fighter')
end)

t.test('and a countdown that DOES start leaves them ready, which is the control',
    function()
        -- Clearing readiness on the way IN would take the roster apart at
        -- the moment the round begins.
        local server, matchId = counting(0, lastSecond)
        for _, src in ipairs({ 1, 2 }) do server.lobby.Get(matchId).players[src].ready = true end

        server.step(6)

        local match = server.lobby.Get(matchId)
        t.isTrue(match.state ~= 'lobby', 'the round never started, so this proves nothing')
        t.isTrue(match.players[1].ready == true,
            'a round that started took everybody\'s ready away')
    end)

t.test('THE DOUBLE BOOKING: a held countdown cannot take an arena back', function()
    -- Begin asks whether the arena is free, and then the countdown runs.
    -- ArenaMatch.Start accepts a lobby in `lobby` as readily as one in
    -- `countdown` -- deliberately, so a held start can be pressed again --
    -- and it did not re-ask for the ground.
    --
    -- So: one lobby counts down and is HELD, which frees the arena. A second
    -- lobby takes it. The first host then presses Start Match Now, and both
    -- rosters end up on the same piece of map. The opening hours are re-asked
    -- at that exact moment for exactly this reason; the ground was not.
    local server = newServer({
        [1] = { cash = 50000, bank = 50000 },
        [2] = { cash = 50000, bank = 50000 },
        [3] = { cash = 50000, bank = 50000 },
        [4] = { cash = 50000, bank = 50000 },
    }, slowLobby)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local first = server.lobby.All()[1].id
    server.fire('joinMatch', 2, { matchId = first })
    t.isTrue((server.env.ArenaMatch.Begin(first, 1)), 'the first lobby would not begin')

    -- HELD, which puts it back to `lobby` and lets go of the arena.
    t.isTrue(server.lobby.HoldCountdown(1), 'the host could not hold their own countdown')

    server.fire('createMatch', 3, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second
    for _, match in ipairs(server.lobby.All()) do
        if match.id ~= first then second = match.id end
    end
    t.isNotNil(second, 'the second lobby never opened, so this tests nothing')
    server.fire('joinMatch', 4, { matchId = second })
    t.isTrue((server.env.ArenaMatch.Begin(second, 3)), 'the second lobby could not take the arena')
    t.equals(server.lobby.Get(second).state, 'countdown', 'the second lobby is not counting down')

    -- And now the first host presses Start Match Now.
    local started, reason = server.env.ArenaMatch.Start(first)

    t.isFalse(started == true,
        'two rounds were put on the same arena at once -- they share the ground')
    t.equals(reason, 'error.arena_in_use', 'and the host was not told why')
    t.isFalse(server.placedAnyone(), 'somebody was teleported in anyway')
end)

os.exit(t.summary())
