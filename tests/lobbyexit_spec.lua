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
            -- INSIDE THE ARENA THESE FIGHTERS ARE SUPPOSED TO BE IN, which
            -- this used to be nowhere near: it answered a point 1,450m from
            -- the Trailer Park, so every fighter in every one of these specs
            -- was standing well outside the fence they were fighting inside.
            -- Nothing read it until Config.Match.serverChecks did, and then
            -- it read as the whole roster having walked out of the round.
            --
            -- Spread three metres apart, so they are also close enough for
            -- the kill-distance ceiling -- the other thing that reads this.
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
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
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function() return true end,
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
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
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
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

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
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

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
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
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
    server.fire('createMatch', 3, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
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

-- ------------------------------------------------------------------------
-- AND THERE HAS TO BE A FIGHT TO WATCH.
--
-- html/app.js offers Watch only for a match that is `live`, and says at
-- length why: watching a LOBBY teleports the body to an arena with nothing
-- in it, shows twelve seconds of nothing while the camera waits for
-- something to stream, and the quit key is unreachable for the whole wait.
--
-- That reasoning was written on the BUTTON, and a button is not a gate.
-- `crimson_arena:server:spectateMatch` is an ordinary net event carrying a
-- client-supplied match id, so a hand-fired one walked past it entirely and
-- reached ArenaDispatch.EnterBucket for a round nobody had started.

t.test('THE DEFECT: a lobby nobody has started cannot be watched', function()
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)
    server.fire('joinMatch', 2, { matchId = match.id })
    t.equals(server.lobby.Get(match.id).state, 'lobby', 'the match is not a lobby, so this proves nothing')

    local ok, reason = server.lobby.AddSpectator(3, match.id)

    t.isFalse(ok, 'a player was bucketed into an arena for a round nobody had started')
    t.equals(reason, 'error.nothing_to_watch', 'refused, but for the wrong reason')
    t.isFalse(server.snapshot(3).spectating, 'refused, and registered as a watcher anyway')
    t.isNil(server.flag(3), 'refused, and moved into the arena bucket anyway')
end)

t.test('and the net event a client actually fires is refused too, not just the helper', function()
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)

    server.fire('spectateMatch', 3, { matchId = match.id })

    t.isFalse(server.snapshot(3).spectating,
        'the hand-fired event put a watcher on a lobby')
end)

t.test('CONTROL: the ELIMINATED fighter the round hands over is still admitted', function()
    -- Load-bearing exemption: ArenaMatch.OnDeath calls AddSpectator for a
    -- player knocked out of the round they are standing in. They are not
    -- watching a round that has not started -- they are already in it. If
    -- the gate catches them, elimination spectating dies with it.
    local server, matchId = liveRound()
    local match = server.lobby.Get(matchId)
    match.state = 'lobby'                       -- the harshest case for the gate
    match.players[2].alive = false
    match.players[2].lives = 0

    local ok, reason = server.lobby.AddSpectator(2, matchId)

    t.isTrue(ok, 'an eliminated fighter was refused a watch of their own round: ' .. tostring(reason))
end)

print('lobbyexit_spec')
-- ========================================================================
-- THE IDLE SWEEP CLOSES ABANDONED LOBBIES, NOT BUSY ONES
--
-- The sweep destroys any lobby that has had NOBODY ready since it was
-- created. That is right for a lobby somebody opened and wandered away from,
-- and it asked the question by measuring from `createdAt` -- so it could not
-- tell a lobby nobody had touched in a quarter of an hour from one people
-- had been drifting in and out of the whole time.
--
-- That only became reachable when ArenaLobby.UpdateMatch started clearing
-- the HOST's Ready as well as everybody else's (it has to: SetReady refuses
-- to mint a ready-with-no-side row, and a mode change wipes sides). Put the
-- two together and a host editing a fifteen-minute-old lobby into team
-- deathmatch had it destroyed under them, with everybody in it ejected.
--
-- Measured: alive without the ready-clearing, CLOSED with it.
-- ========================================================================

--- A lobby of two that has been open longer than the idle timeout.
--- @return table server, string matchId
local function staleLobby(mutate)
    local server = newServer(function(config)
        config.Match.idleLobbyTimeoutSeconds = 900
        config.Match.autoStartWhenAllReady = false
        config.Teams.autoAssignIfUnchosen = false
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
        if mutate then mutate(config) end
    end)
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)
    t.isNotNil(match, 'the host could not open a lobby')
    server.fire('joinMatch', 2, { matchId = match.id })

    -- Sixteen minutes of people drifting in and out.
    match.createdAt = os.time() - 1000
    match.idleSince = match.createdAt

    return server, match.id
end

--- How many players in this lobby are readied, which is the sweep's other
--- condition -- asserted rather than assumed by the tests below.
local function readyCount(server, matchId)
    local n = 0
    for _, player in pairs(server.lobby.Get(matchId).players) do
        if player.ready == true then n = n + 1 end
    end
    return n
end

t.test('THE DEFECT: editing a stale lobby does not hand it to the sweep', function()
    local server, matchId = staleLobby()
    server.fire('setReady', 1, { ready = true })

    -- The host changes the mode to a team one, which wipes every side and --
    -- with auto-assignment off -- must take their own Ready with it.
    t.isTrue(server.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm' }),
        'the mode could not be changed')
    t.isFalse(server.lobby.Get(matchId).players[1].ready == true,
        'the host kept a Ready they cannot legally hold, so this proves nothing')

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'THE HOST ASKED FOR A MODE CHANGE AND HAD THEIR LOBBY CLOSED UNDER THEM')
end)

t.test('and a lobby opened SECONDS ago is never swept, whatever nobody has done in it', function()
    -- THE STARTING VALUE, which every other test here overwrites by hand to
    -- age the lobby -- so a mutation that seeded it at zero survived the lot.
    -- Seeded wrong, the very first sweep would destroy every lobby on the
    -- server the moment it was opened, because nobody has readied up yet in
    -- the first fifteen seconds of any lobby that ever existed.
    local server = newServer(function(config)
        config.Match.idleLobbyTimeoutSeconds = 900
        config.Match.autoStartWhenAllReady = false
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
    end)
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)
    t.isNotNil(match, 'the host could not open a lobby')
    server.fire('joinMatch', 2, { matchId = match.id })

    -- Nothing is aged. Nobody readies. This is a lobby two people are
    -- standing in, right now.
    t.equals(server.lobby.Get(match.id).players[1].ready, false,
        'somebody readied up, so this proves nothing')

    server.step(40)

    t.isNotNil(server.lobby.Get(match.id),
        'A LOBBY OPENED SECONDS AGO WAS SWEPT AWAY')
end)

t.test('CONTROL: a lobby nobody has touched at all is still closed', function()
    -- The sweep must keep doing its job. A fix that simply stopped it would
    -- pass the test above and leave dead lobbies on the server for ever.
    local server, matchId = staleLobby()

    server.step(40)

    t.isNil(server.lobby.Get(matchId),
        'an abandoned lobby was left standing -- the sweep has stopped working')
end)

t.test('and a lobby somebody readied in is never swept, edited or not', function()
    local server, matchId = staleLobby()
    server.fire('setReady', 1, { ready = true })

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'a lobby with somebody ready in it was swept')
end)

-- ---------------------------------------------------------------------------
-- THE SWEEP CANNOT SEE ANYBODY ARRIVE.
--
-- `idleSince` was written in exactly two places -- Create and UpdateMatch --
-- so for everybody who was not the host editing the rules, the sweep was
-- still measuring from `createdAt`, which is the bug the field was added to
-- fix. Its own comment said it meant "the last time anybody did ANYTHING to
-- this lobby". Joining, leaving, picking a side and ticking Ready all left it
-- alone.
--
-- The tests below each do one ordinary thing to a lobby that is already older
-- than the timeout, then run the sweep. The lobby has to survive. The control
-- above -- "a lobby opened seconds ago is never swept" -- and the one below,
-- which does nothing at all and requires the lobby to DIE, are what keep
-- these honest: without the second one, a sweep that never fired would pass
-- every test here.

t.test('CONTROL: a genuinely abandoned stale lobby is still closed', function()
    local server, matchId = staleLobby()
    server.step(40)
    t.isNil(server.lobby.Get(matchId),
        'the sweep did not fire at all, so every test below proves nothing')
end)

t.test('THE DEFECT: somebody walking in is activity, and saves the lobby', function()
    local server, matchId = staleLobby()
    server.fire('joinMatch', 3, { matchId = matchId })
    t.isNotNil(server.lobby.Get(matchId).players[3], 'the join did not happen')

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'A THIRD PLAYER WALKED IN AND THE LOBBY WAS CLOSED UNDER ALL THREE OF THEM')
end)

t.test('and somebody walking OUT is activity too', function()
    local server, matchId = staleLobby()
    server.fire('leaveMatch', 2, {})
    t.isNil(server.lobby.Get(matchId).players[2], 'the leave did not happen')

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'one of two players left and the host lost the lobby they were still standing in')
end)

t.test('and ticking Ready is activity', function()
    local server, matchId = staleLobby()
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 1, { ready = false })
    t.equals(readyCount(server, matchId), 0,
        'somebody is still readied, so the sweep would skip this lobby regardless')

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'THE MOST ORDINARY ACT THERE IS -- changing your mind -- handed the lobby to the sweep')
end)

t.test('and picking a side is activity', function()
    local server, matchId = staleLobby(function(config)
        config.Teams.allowChoose = true
    end)
    t.isTrue(server.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm' }),
        'the mode could not be changed to a team one')
    -- UpdateMatch stamps the field itself, so age it again: this test is
    -- about SetTeam and nothing else.
    local match = server.lobby.Get(matchId)
    match.createdAt = os.time() - 1000
    match.idleSince = match.createdAt

    local teams = server.env.Arena.GetEnabledTeams()
    t.isTrue(server.lobby.SetTeam(2, teams[1].key), 'the side could not be picked')

    server.step(40)

    t.isNotNil(server.lobby.Get(matchId),
        'a player picked a side and the lobby was closed under them')
end)

-- ---------------------------------------------------------------------------
-- A STALE WATCH FLAG IS NOT A PLAYER STANDING IN THIS ARENA.
--
-- playersArePlaced gates HoldCountdown ("Stop The Countdown") and Cancel
-- ("Close Lobby"), and it asked ArenaDispatch.IsPlayerInArena -- "is this
-- player in ANY arena", which is true of somebody merely WATCHING one. The
-- watch flag outlives the watch: RemoveSpectator calls ExitBucket and not
-- Clear, and only the match sweep takes the flag down, a tick later.
--
-- So a player who stopped watching some other round a second ago, and walked
-- into your lobby, made YOU -- the host -- unable to hold your own countdown
-- or close your own lobby. This is the file for it: its own header calls the
-- subject "a flag that outlives the match it belonged to".

--- A lobby of two, counting down, with `joiner` carrying a dispatch flag for
--- `flagFor` -- nil for no flag at all.
local function countingDownWithFlag(flagFor)
    local server = newServer(function(config)
        config.Match.lobbyCountdownSeconds = 30
        config.Match.autoStartWhenAllReady = true
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
    end)
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)
    t.isNotNil(match, 'the host could not open a lobby')
    server.fire('joinMatch', 2, { matchId = match.id })

    if flagFor ~= nil then
        server.env.ArenaDispatch.Set(2, flagFor == 'this' and match.id or 'some-other-match')
    end

    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    t.equals(server.lobby.Get(match.id).state, 'countdown',
        'the lobby is not counting down, so there is nothing to hold')
    return server, match.id
end

t.test('CONTROL: the host of an ordinary lobby may hold their own countdown', function()
    local server = countingDownWithFlag(nil)
    local ok, why = server.lobby.HoldCountdown(1)
    t.isTrue(ok, 'the host could not hold a countdown with nobody flagged at all: ' .. tostring(why))
end)

t.test('THE DEFECT: a joiner who watched ANOTHER match does not block the host', function()
    local server = countingDownWithFlag('other')
    local ok, why = server.lobby.HoldCountdown(1)
    t.isTrue(ok, 'THE HOST WAS REFUSED THEIR OWN COUNTDOWN: ' .. tostring(why))
end)

t.test('and the same host may still close their own lobby', function()
    local server, matchId = countingDownWithFlag('other')
    local ok, why = server.lobby.Cancel(1)
    t.isTrue(ok, 'THE HOST COULD NOT CLOSE THEIR OWN LOBBY: ' .. tostring(why))
    t.isNil(server.lobby.Get(matchId), 'the lobby survived a cancel that reported success')
end)

t.test('CONTROL: a roster actually teleported in still blocks the hold', function()
    -- The whole point of the gate, and it has to keep working: once the
    -- roster is on the ground, stopping the countdown would strand them.
    --
    -- Driven through the real path rather than by setting a flag -- this
    -- file's default fixture is built for exactly this window (no lobby
    -- countdown, a 30s freeze), so one step teleports the roster and holds
    -- the match at 'countdown' with ArenaMatch.Start's own `placed` set.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.GetByPlayer(1)
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(1)

    local live = server.lobby.Get(match.id)
    t.equals(live.state, 'countdown', 'the match is not in its freeze, so this proves nothing')
    t.isTrue(live.placed == true, 'the roster was never teleported in, so there is nobody to strand')

    local ok, why = server.lobby.HoldCountdown(1)
    t.isFalse(ok, 'a roster standing in the arena no longer stops the countdown being held')
    t.equals(why, 'error.match_in_progress', 'refused, but for the wrong reason')
end)

os.exit(t.summary())
