--[[
    crimson_arena/tests/returnhome_spec.lua

    EVERYBODY GOES BACK TO THE ARENA NPC WHEN THE ROUND IS OVER.

    Four groups of people are standing somewhere they should not be when a
    match ends, and they leave by three different doors:

      the winner        still alive, still in the arena
      the losers        alive but beaten
      the eliminated    out of lives, watching from the spectate camera,
                        and physically still a body parked in the arena
      the spectators    never fought, but were moved into the round's own
                        routing bucket to watch it

    A player this forgets is left standing in an empty airfield in an
    instance nobody else is in, with no panel and no way back except
    reconnecting. So the assertion is a headcount: every one of them is sent
    home, and to the same place.

    The place itself is asserted too, against the NPC rather than against a
    number typed here. Config.Lobby.returnCoords is a separate hand-set
    coordinate, so an operator who moves the arena ped and does not think to
    move the return point sends everybody to a field near where the arena
    used to be -- silently, and only at the end of a round.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('returnhome_spec')

local function newServer(mutate)
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host', money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
        -- A THIRD FIGHTER, because the elimination test needs a round that
        -- survives the death it is about: with two players, one death is
        -- also last-man-standing and the match is torn down before the
        -- question can be asked.
        [3] = { citizenid = 'CCC33333', name = 'Third', money = { cash = 50000, bank = 0 } },
        -- And somebody to watch, who never fights.
        [4] = { citizenid = 'DDD44444', name = 'Watcher', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents, handlers, issued = {}, {}, {}, {}
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
            -- RECORDING, not silent. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; what this file is about is what reaches it,
            -- so the loadout handed over is kept rather than dropped.
            IsEnabled = function() return false end,
            Issue = function(src, _matchId, loadout)
                issued[#issued + 1] = { src = src, loadout = loadout }
                return {}
            end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function(src) dispatch.set[#dispatch.set + 1] = src end,
            Clear = function(src) dispatch.cleared[#dispatch.cleared + 1] = src end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function(src) dispatch.revived = (dispatch.revived or {}); dispatch.revived[#dispatch.revived + 1] = src end,
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
    -- Betting off: an entry fee would make every createMatch below a
    -- transaction, and this file is about one boolean.
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, dispatch = dispatch, config = env.Config,
        lobby = env.ArenaLobby, match = env.ArenaMatch }

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

    --- The payload of the LAST event of one name sent to one player, which
    --- is what a fighter actually entered the arena under.
    function server.payloadTo(event, target)
        local found = nil
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                found = message.payload
            end
        end
        return found
    end

    --- What the panel would draw from, for one player.
    function server.snapshot(src)
        return env.ArenaLobby.BuildState(src)
    end

    --- Every event of one name sent to one player, in order.
    function server.allPayloadsTo(event, target)
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                out[#out + 1] = message.payload
            end
        end
        return out
    end

    --- The stored choice, as the lobby holds it between save and start.
    function server.storedLoadout(matchId, src)
        local match = env.ArenaLobby.Get(matchId)
        local entry = match and match.players[src]
        return entry and entry.loadout or nil
    end

    return server
end




--- Distance on the plane between two points that may be vector4 or table.
local function gap(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

--- A live match with `ids` in it, everybody placed in the arena.
--- @param ids integer[]|nil -- defaults to two fighters
--- @return table server
--- @return string matchId
local function liveMatch(mutate, ids)
    ids = ids or { 1, 2 }
    local server = newServer(mutate)
    server.fire('createMatch', ids[1], { arenaKey = 'airfield', modeKey = 'ffa' })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
    end
    server.fire('startMatch', ids[1])
    server.step(6)

    t.equals(server.lobby.Get(match.id).state, 'live', 'the round never went live')
    return server, match.id
end

--- The exitArena a player was sent, if they were sent one.
local function wentHome(server, src)
    local all = server.allPayloadsTo('exitArena', src)
    return all[#all]
end

-- ======================================================================
-- THE PLACE
-- ======================================================================

t.test('the return point is at the arena NPC, not somewhere near it', function()
    -- Two hand-set coordinates that have to agree, in a config where nothing
    -- makes them. Ten metres is "the same spot" -- close enough that a player
    -- lands looking at the NPC they came in through.
    local config = newServer().config
    local ped = config.Lobby.ped.coords
    local home = config.Lobby.returnCoords

    t.isNotNil(home, 'there is no return point at all')
    t.isTrue(gap(home, ped) < 10.0,
        ('the return point is %0.1fm from the arena NPC -- a round ends by putting '):format(gap(home, ped))
        .. 'everybody somewhere they cannot get back in from')
    t.isTrue(math.abs(home.z - ped.z) < 5.0,
        'the return point is on a different level to the NPC')
end)

t.test('and the marker sits in the same place, so either door leads home', function()
    -- interaction may be 'ped', 'marker' or 'both'. Whichever the operator
    -- picked, the way back has to be next to the way in.
    local config = newServer().config
    local marker = config.Lobby.marker.coords
    local home = config.Lobby.returnCoords
    t.isTrue(gap(home, marker) < 10.0,
        ('the return point is %0.1fm from the lobby marker'):format(gap(home, marker)))
end)

-- ======================================================================
-- THE HEADCOUNT
-- ======================================================================

t.test('both fighters are sent home when the round ends', function()
    local server, matchId = liveMatch()
    server.match.End(matchId, 'match.ended')
    server.step(2)

    local home = server.config.Lobby.returnCoords
    for _, src in ipairs({ 1, 2 }) do
        local exit = wentHome(server, src)
        t.isNotNil(exit, ('player %d was left standing in the arena'):format(src))
        t.isNotNil(exit.returnCoords, ('player %d was sent out with nowhere to go'):format(src))
        t.equals(exit.returnCoords.x, home.x)
        t.equals(exit.returnCoords.y, home.y)
        t.equals(exit.returnCoords.z, home.z)
    end
end)

t.test('an ELIMINATED player is sent home too, though they died long before', function()
    -- The one most likely to be forgotten: they are already out, already
    -- watching from the camera, and their body is parked in the arena under
    -- ClearDeadState's hold. Nothing about the end of the round involves them
    -- except this.
    -- THREE fighters, deliberately. With two, the one death below is also
    -- the end of the round -- last man standing -- so the match is already
    -- torn down before this test gets to ask its question.
    local server, matchId = liveMatch(function(config) config.Match.lives = 1 end, { 1, 2, 3 })

    -- Player 2 dies to player 1, which with one life apiece puts them out.
    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.step(2)

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'the round ended on the first death, so nobody was eliminated INTO it')
    t.isFalse(match.players[2].alive,
        'the death did not take, so nobody was eliminated and this proves nothing')

    server.match.End(matchId, 'match.ended')
    server.step(2)

    local exit = wentHome(server, 2)
    t.isNotNil(exit, 'an eliminated player was left in the arena when the round ended')
    t.isNotNil(exit.returnCoords, 'an eliminated player was sent out with nowhere to go')
end)

t.test('and a spectator, who was never a fighter at all', function()
    local server, matchId = liveMatch()
    local ok = server.lobby.AddSpectator(4, matchId)
    t.isTrue(ok == true, 'the spectator could not be admitted, so this proves nothing')

    server.match.End(matchId, 'match.ended')
    server.step(2)

    local exit = wentHome(server, 4)
    t.isNotNil(exit, 'a spectator was left in the round\'s own instance after it ended')
    t.isNotNil(exit.returnCoords, 'a spectator was sent out with nowhere to go')
end)

t.test('nobody is sent home twice, which would fight the teleport', function()
    -- Two exits means two teleports and two weapon strips, and the second
    -- lands on a player who is already back at the NPC holding their own kit.
    local server, matchId = liveMatch()
    server.match.End(matchId, 'match.ended')
    server.step(4)

    for _, src in ipairs({ 1, 2 }) do
        t.equals(#server.allPayloadsTo('exitArena', src), 1,
            ('player %d was sent home more than once'):format(src))
    end
end)

os.exit(t.summary())
