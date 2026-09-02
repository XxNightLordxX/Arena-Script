--[[
    crimson_arena/tests/lobbyexit_spec.lua

    server/lobby.lua's two ways of losing a player, and the one word that
    hid both of them.

    'countdown' NAMES TWO PHASES. ArenaMatch.Begin uses it for the lobby
    countdown, where nobody has been moved anywhere and backing out is the
    documented feature. ArenaMatch.Start then reuses the SAME name for the
    frozen start countdown -- after teleporting the room into the arena,
    handing out loadouts, setting every routing bucket and raising every
    dispatch flag. Only goLive promotes it to 'live'.

    tests/countdownexit_spec.lua documents that window from the LEAVE side,
    where server/main.lua's detach() asked ArenaMatch.IsLive and got 'no'.
    This file is the other two ways into it, both of which live here:

      * ArenaLobby.Cancel accepted 'countdown' and called ArenaLobby.Destroy,
        which sends nobody an exitArena. One host, one stock button labelled
        "Cancel Start", and every fighter in the match was left standing in
        the arena holding the issued loadout with a dispatch flag they could
        not clear -- for the rest of their session.

      * ArenaLobby.Destroy is the single teardown every close funnels
        through, and the step that makes the match unreachable. Once it has
        run there is no record left of who was in the arena, so it is the
        last place a stranding can still be caught.

    AND THE SPECTATOR HALF. ArenaLobby.AddSpectator refused anybody with a
    playerIndex entry -- but an eliminated fighter KEEPS their row, because
    the results board ranks off it, so the guard refused exactly the case
    server/match.lua calls it for. The camera then died on the next
    broadcast, which told the eliminated player `spectating = false`.

    The state name cannot express any of this, so none of it is asserted
    through match.state: what is asserted is what was actually DONE to a
    player -- the dispatch flag, the bucket, and the exit they were or were
    not sent.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- A server with the real util/betting/lobby/match/main loaded, and an
--- ArenaDispatch double that REMEMBERS: this file's subject is a flag that
--- outlives the match it belonged to, so a stub answering a constant would
--- be answering the question under test.
--- @param mutate fun(config: table)? -- runs before the server files load
--- @return table server
local function newServer(mutate)
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host', money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
        [3] = { citizenid = 'CCC33333', name = 'Other', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents = {}, {}
    local flags, buckets = {}, {}
    local dispatch = { cleared = {}, bucketOut = {} }

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
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- A minute per read, so no RATE bucket in main.lua ever refuses a
        -- call: a throttled event and a refused one look identical here.
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
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
            Set = function(src, matchId) flags[src] = matchId end,
            Clear = function(src)
                flags[src] = nil
                dispatch.cleared[#dispatch.cleared + 1] = src
            end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function(src)
                dispatch.revived = dispatch.revived or {}
                dispatch.revived[#dispatch.revived + 1] = src
            end,
            IsPlayerInArena = function(src) return flags[src] ~= nil end,
            GetPlayerMatchId = function(src) return flags[src] end,
            ClearDownState = function() return 0 end,
            EnterBucket = function(src, matchId) buckets[src] = matchId end,
            ExitBucket = function(src)
                buckets[src] = nil
                dispatch.bucketOut[#dispatch.bucketOut + 1] = src
            end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- No lobby countdown and a long freeze by default: that puts everybody in
    -- the arena on the first step and holds the match at 'countdown' for the
    -- whole test, which IS the window under examination. A test that wants
    -- the OTHER 'countdown' -- the lobby one -- asks for it through `mutate`.
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 30
    env.Config.Match.minPlayers = 2

    -- Before the loads, not after: server/lobby.lua reads
    -- Config.Match.idleLobbyTimeoutSeconds once, at load, to decide whether
    -- its sweep thread is worth starting at all.
    if mutate then mutate(env.Config) end

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

    --- One pass of every live coroutine. Deliberately explicit: the freeze is
    --- a CreateThread + Wait, and the sandbox's Wait yields once, so a single
    --- extra step is the difference between a frozen countdown and a live
    --- round.
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

    --- The last payload of one event sent to one player, so a test can assert
    --- on what the client was actually told rather than only that it was.
    function server.lastPayload(event, target)
        local found
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                found = message.payload
            end
        end
        return found
    end

    function server.countOf(list, value)
        local hits = 0
        for _, entry in ipairs(list) do if entry == value then hits = hits + 1 end end
        return hits
    end

    --- The match id the dispatch flag says this player is in the arena for,
    --- or nil. This is the record the fixes under test read.
    function server.flag(src) return flags[src] end

    --- The match whose network instance this player is standing in, or nil.
    --- The end state rather than the call: a bucket handed back and taken
    --- straight out again leaves the same call count behind.
    function server.bucket(src) return buckets[src] end

    --- The `player` block of the snapshot, which is what the panel and
    --- client/spectate.lua actually act on.
    function server.snapshot(src) return server.lobby.BuildState(src).player end

    return server
end

--- Opens a match with 1 and 2 in it and starts it, leaving the match frozen
--- at 'countdown' with both players already standing in the arena.
--- @param mutate fun(config: table)?
--- @return table server
--- @return string matchId
local function frozenCountdown(mutate)
    local server = newServer(mutate)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.GetByPlayer(1)
    t.isNotNil(match, 'the host could not open a lobby')

    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })

    -- Exactly one: Start() runs and the freeze thread it spawns parks on its
    -- Wait. Two would resume that Wait and take us into 'live'.
    server.step(1)

    return server, match.id
end

--- The same match, one step further on, with weapons live.
--- @return table server
--- @return string matchId
--- A live round where ONE death eliminates.
---
--- Config.Match.lives ships at 3, so a single reported death now costs a
--- life and respawns the player rather than putting them out. Every test
--- below is about what happens to somebody who is ELIMINATED, so they set
--- the precondition they need rather than leaning on a default that has
--- since changed underneath them -- and they keep testing elimination
--- rather than quietly becoming tests of respawning.
local function liveRound(mutate)
    local server, matchId = frozenCountdown(function(config)
        config.Match.lives = 1
        if mutate then mutate(config) end
    end)
    server.step(1)
    t.isTrue(server.match.IsLive(matchId), 'the match never went live')
    return server, matchId
end

-- ========================================================================
-- CANCELLING -- the lobby control, and the window it leaked into
-- ========================================================================

t.test('the lobby countdown is still cancellable: nobody has been moved yet', function()
    -- README step 6 -- "a lobby countdown players can still back out of" --
    -- is this exact state, and it wears the same name as the frozen one. A
    -- fix that read the name would have taken this away.
    local server = newServer(function(config) config.Match.lobbyCountdownSeconds = 10 end)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })

    local matchId = server.lobby.GetByPlayer(1).id
    server.fire('joinMatch', 2, { matchId = matchId })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })

    t.equals(server.lobby.Get(matchId).state, 'countdown', 'the lobby countdown never started')
    t.isNil(server.flag(1), 'nobody should have been placed in the arena yet')

    local ok, reason = server.lobby.Cancel(1)

    t.isTrue(ok, 'the host could not call off a countdown nobody had been moved by')
    t.isNil(reason)
    t.isNil(server.lobby.Get(matchId), 'the lobby was not closed')
    t.equals(server.sentTo('exitArena', 2), 0,
        'an arena teardown was fired at a player standing in the lobby')
end)

t.test('cancelling once the fighters are in the arena is refused', function()
    local server, matchId = frozenCountdown()

    -- The panel offers this button for the whole of state 'countdown'
    -- (html/app.js relabels Start to "Cancel Start"), so this needs no
    -- modified client -- and by now both players have been teleported in.
    t.equals(server.flag(1), matchId, 'the host was never placed in the arena')
    t.equals(server.flag(2), matchId, 'the rival was never placed in the arena')

    -- Through the net event the panel really posts, so the refusal is proved
    -- where a host can actually reach it.
    server.fire('cancelMatch', 1)
    t.isNotNil(server.lobby.Get(matchId), 'the match record was destroyed out from under its players')

    local ok, reason = server.lobby.Cancel(1)
    t.isFalse(ok, 'the host cancelled a match whose fighters were already standing in the arena')
    t.equals(reason, 'error.match_in_progress')
    t.equals(server.flag(1), matchId, 'the host was cut loose from the arena they are standing in')
    t.equals(server.flag(2), matchId, 'the rival was cut loose from the arena they are standing in')
end)

t.test('a refused cancel leaves the round intact: it still goes live', function()
    local server, matchId = frozenCountdown()

    server.lobby.Cancel(1)
    server.step(1)

    t.isTrue(server.match.IsLive(matchId), 'the refused cancel still cost the room its round')
    t.equals(server.lobby.PlayerCount(server.lobby.Get(matchId)), 2, 'a fighter was lost to the refusal')
end)

t.test('the way out of that window is leaving, and it still works for the host', function()
    -- Cancel's own comment says so: once the round is running the way out is
    -- leaving it, or an admin stop. Refusing the cancel is only honest if
    -- that other door is really open.
    local server, matchId = frozenCountdown()

    server.fire('leaveMatch', 1)

    t.equals(server.sentTo('exitArena', 1), 1, 'the host was refused a cancel AND left in the arena')
    t.isNil(server.flag(1), 'the host kept the dispatch flag on the way out')
    t.isNotNil(server.lobby.Get(matchId), 'one player leaving should not close the match')
end)

-- ========================================================================
-- DESTROY -- the last place a stranding can be caught
-- ========================================================================

t.test('Destroy sends anybody still standing in the arena home, whatever the caller forgot', function()
    local server, matchId = frozenCountdown()

    -- Straight into the teardown, bypassing server/match.lua's exit choke
    -- point exactly as ArenaLobby.Cancel used to. After this call there is no
    -- record left of who was in the arena, so this is the last moment anyone
    -- could be sent home at all.
    server.lobby.Destroy(matchId, 'notify.match_cancelled')

    t.equals(server.sentTo('exitArena', 1), 1,
        'no exitArena: the host is standing in the arena with nothing coming to take them out of it')
    t.equals(server.sentTo('exitArena', 2), 1,
        'no exitArena: the rival is standing in the arena with nothing coming to take them out of it')
    t.isNil(server.flag(1), 'the flag outlived the match -- their alerts stay suppressed all session')
    t.isNil(server.flag(2), 'the flag outlived the match -- their alerts stay suppressed all session')
    t.equals(server.countOf(server.dispatch.bucketOut, 2), 1,
        'the routing bucket was never returned -- they are left in an instance nobody else is in')
    t.isNil(server.bucket(1), 'the host is still standing in the match instance')
    t.isNil(server.bucket(2), 'the rival is still standing in the match instance')
    t.isNil(server.lobby.Get(matchId), 'the match should still be gone')
end)

t.test('the exit Destroy sends carries no coords, so the client uses its own lobby', function()
    local server, matchId = frozenCountdown()

    server.lobby.Destroy(matchId, 'notify.match_cancelled')

    local payload = server.lastPayload('exitArena', 2)
    t.isNotNil(payload, 'nothing was sent at all')
    t.isNil(payload.returnCoords,
        'lobby.lua has no coords of its own to send; client/match.lua falls back to Config.Lobby.returnCoords')
end)

t.test('Destroy over a lobby nobody was placed in sends no arena exit', function()
    -- The other half of the guard: firing arena teardown at players standing
    -- in the lobby would strip weapons they never received and teleport
    -- people who never moved.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
    local matchId = server.lobby.GetByPlayer(1).id
    server.fire('joinMatch', 2, { matchId = matchId })

    server.lobby.Destroy(matchId, 'notify.match_closed')

    t.equals(server.sentTo('exitArena', 1), 0)
    t.equals(server.sentTo('exitArena', 2), 0)
    t.equals(#server.dispatch.bucketOut, 0)
end)

t.test('a normal finish still reaches Destroy with nobody left to rescue', function()
    -- Proof the belt-and-braces branch is belt-and-braces: every path that
    -- exists today goes through server/match.lua's exit first, so exactly one
    -- exitArena reaches each player, not two.
    local server, matchId = liveRound()

    server.fire('reportDeath', 2, { killerServerId = 1 })
    -- The sweep decides the round a tick after the death, by which point
    -- everybody who died in that tick has been counted.
    server.step(1)

    t.isNil(server.lobby.Get(matchId), 'the round never finished')
    t.equals(server.sentTo('exitArena', 1), 1, 'the winner was sent home twice')
    t.equals(server.sentTo('exitArena', 2), 1, 'the loser was sent home twice')
end)

-- ========================================================================
-- SPECTATORS -- the eliminated fighter the guard was written for
-- ========================================================================

t.test('an eliminated fighter is registered as a spectator of their own match', function()
    local server, matchId = liveRound()

    server.fire('reportDeath', 2, { killerServerId = 1 })

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'the round ended before the elimination could be examined')
    t.isTrue(match.spectators[2] == true,
        'AddSpectator refused the eliminated fighter -- the one case it is called for')
    t.equals(server.snapshot(2).spectating, matchId,
        'the next broadcast tells them spectating = false, and client/spectate.lua stands them back up')

    -- The other half of the same fact: the client is told what the server
    -- really did, so it only opens the camera when the registry will keep it.
    local payload = server.lastPayload('eliminated', 2)
    t.isNotNil(payload, 'the eliminated player was never told')
    t.isTrue(payload.spectate, 'the camera was never opened for them')
end)

t.test('the eliminated fighter keeps their row, so the results board can still rank them', function()
    local server, matchId = liveRound()

    server.fire('reportDeath', 2, { killerServerId = 1 })

    local match = server.lobby.Get(matchId)
    t.isNotNil(match.players[2], 'admitting them as a spectator must not cost them their row')
    t.isFalse(match.players[2].alive)
    t.equals(match.players[2].lives, 0)
end)

t.test('with the shipped three lives, one death costs a life instead of the match', function()
    -- The other side of the helper above, and the behaviour that actually
    -- ships now: a single unlucky opening exchange must not end somebody's
    -- round.
    local server, matchId = frozenCountdown()
    server.step(1)

    server.fire('reportDeath', 2, { killerServerId = 1 })

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'the round ended on the first death of a three-life match')
    t.equals(match.players[2].lives, 2, 'the death did not cost a life')
    t.isNil(match.spectators[2], 'a player with lives left was made a spectator')
end)

t.test('a second death while waiting to respawn is not counted twice', function()
    -- Learned by writing the test below wrongly first: firing three deaths
    -- back to back only spends ONE life, because a player lying there
    -- waiting on respawnDelaySeconds is already dead and cannot die again.
    -- That is correct, and worth pinning -- a double-counted death would
    -- burn a player's whole match on one kill.
    local server, matchId = frozenCountdown()
    server.step(1)

    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.fire('reportDeath', 2, { killerServerId = 1 })

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'three reports in one breath ended a three-life round')
    t.equals(match.players[2].lives, 2, 'a death was counted more than once')
end)

-- ======================================================================
-- WATCHING A MATCH YOU WERE NEVER IN
--
-- The camera and the registration were never the problem. Matches are fought
-- in their own ROUTING BUCKET -- the layer that keeps arena gunfire off the
-- rest of the server -- and a spectator who is not put in it flies to the
-- arena and finds an empty field. The server had them registered, the panel
-- said "Watching", and there was nobody there to see.
--
-- That is what "the watch button does not work" looked like, and no test
-- here caught it because every spectator test asked whether they were
-- REGISTERED, which they always were.
-- ======================================================================

t.test('an outsider who watches is put in the match instance, or there is nothing to see', function()
    local server, matchId = liveRound()

    -- Player 9 is nobody: never joined, never fought.
    local ok = server.lobby.AddSpectator(9, matchId)
    t.isTrue(ok, 'an outsider was refused a camera on a live match')

    t.equals(server.bucket(9), matchId,
        'the spectator is registered but left in the default world -- they arrive at the arena and see an empty field')
end)

t.test('and is taken back out when they stop watching', function()
    local server, matchId = liveRound()

    server.lobby.AddSpectator(9, matchId)
    server.lobby.RemoveSpectator(9)

    t.isNil(server.bucket(9),
        'a spectator who stopped watching was left inside the match instance, in a world nobody else is in')
end)

t.test('but an ELIMINATED player is not dragged out of their own round', function()
    -- They are still in the match -- their row is what the results board
    -- ranks off -- so pulling them out of the instance here would drop them
    -- into the live world mid-match. Their exit runs on the match's own path.
    local server, matchId = liveRound()
    server.fire('reportDeath', 2, { killerServerId = 1 })

    t.isTrue(server.lobby.AddSpectator(2, matchId), 'the eliminated fighter was refused their own camera')
    server.lobby.RemoveSpectator(2)

    t.equals(server.bucket(2), matchId,
        'an eliminated player who stopped watching was ejected from the match instance mid-round')
end)

t.test('a fighter who is still alive may not spectate the match they are fighting in', function()
    local server, matchId = liveRound()

    local ok, reason = server.lobby.AddSpectator(1, matchId)

    t.isFalse(ok, 'a live fighter was handed a spectator camera in their own round')
    t.equals(reason, 'error.already_in_match')
    t.isNil(server.lobby.Get(matchId).spectators[1])
end)

t.test('a fighter waiting to respawn may not spectate either', function()
    -- Down but not out: they still hold a life, so they are still in the
    -- fight and the camera is not theirs.
    local server, matchId = liveRound(function(config) config.Match.lives = 2 end)

    server.fire('reportDeath', 2, { killerServerId = 1 })

    local match = server.lobby.Get(matchId)
    t.equals(match.players[2].lives, 1, 'the rival should have a life left')
    t.isNil(match.spectators[2], 'a player on a respawn timer was parked behind a spectator camera')

    local ok, reason = server.lobby.AddSpectator(2, matchId)
    t.isFalse(ok)
    t.equals(reason, 'error.already_in_match')
end)

t.test('being knocked out of your own round is not a pass into somebody else', function()
    local server, matchId = liveRound()
    server.fire('reportDeath', 2, { killerServerId = 1 })

    -- A second lobby, opened by somebody with no connection to the first.
    server.fire('createMatch', 3, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
    local other = server.lobby.GetByPlayer(3).id

    local ok, reason = server.lobby.AddSpectator(2, other)

    t.isFalse(ok, 'an eliminated fighter walked into a match they are not in')
    t.equals(reason, 'error.already_in_match')
    t.isNil(server.lobby.Get(other).spectators[2])
    t.equals(server.snapshot(2).spectating, matchId, 'they were moved off their own match')
end)

t.test('an eliminated fighter who walks out stops being a spectator of the match they left', function()
    -- server/match.lua's sweep puts anyone the registry still calls a
    -- spectator into that match's routing bucket, so a leftover entry would
    -- keep dragging this player back into an instance of a round they left.
    local server, matchId = liveRound()
    server.fire('reportDeath', 2, { killerServerId = 1 })

    server.fire('leaveMatch', 2)

    local match = server.lobby.Get(matchId)
    if match then
        t.isNil(match.players[2], 'they are still counted as a fighter')
        t.isNil(match.spectators[2], 'they are still counted as a spectator of the match they left')
    end
    t.isFalse(server.snapshot(2).spectating, 'the snapshot still has them watching')
    t.isNil(server.flag(2), 'they walked out of the arena still flagged as being in it')
end)

t.test('a plain bystander may still watch a match they are in no part of', function()
    local server, matchId = liveRound()

    local ok, reason = server.lobby.AddSpectator(3, matchId)

    t.isTrue(ok, 'the guard was tightened onto somebody it was never about')
    t.isNil(reason)
    t.equals(server.snapshot(3).spectating, matchId)
end)

print('lobbyexit_spec')
os.exit(t.summary())
