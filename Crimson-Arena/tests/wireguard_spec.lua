--[[
    crimson_arena/tests/wireguard_spec.lua

    THE WIRE, AND WHAT ARRIVES ON IT.

    server/main.lua is the whole client-facing surface: every event a player
    can send lands there, is rate-limited, is shape-checked, and is then
    handed on. Its own header says shape-checking is the whole job, because
    every argument came off the network and is therefore whatever a modified
    client felt like sending.

    THE RATE LIMITER HAD NO TEST. Not one spec in the suite mentioned
    ArenaRateLimit -- the anti-spam floor under every entry point in the
    resource. A mutation turning its `<` into `<=` survived; so would one
    turning the whole guard off, because nothing anywhere asks whether a
    second call in the same millisecond is refused.

    What this file holds:

      A SECOND CALL INSIDE THE       refused, and refused SILENTLY -- a
      INTERVAL DOES NOTHING          refusal that costs a table lookup is the
                                     point, and one that answers is a way to
                                     make the server work for a spammer.

      THE BUCKETS ARE SEPARATE,      per player and per event. One player
      IN BOTH DIRECTIONS             hammering `createMatch` must not stop
                                     another joining, and must not stop
                                     themselves leaving.

      A HOSTILE SHAPE IS REFUSED,    a table where a number belongs, a
      NOT COERCED                    string where a table belongs, a list
                                     ten thousand long, a table nested into
                                     itself. None of it may throw, and none
                                     of it may be acted on.

      AND THE PLAYER IS FORGOTTEN    ArenaForgetPlayer exists so `lastCall`
      WHEN THEY LEAVE                does not gain a table per player who
                                     has ever connected and never give one
                                     back.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('wireguard_spec')

--- A server whose clock this file drives, so the rate limiter can be tested
--- at all: a timer that jumps a minute per read makes every call look like
--- it arrived an hour after the last one.
local function newServer(mutate)
    local players = {}
    for src = 1, 4 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console = {}, {}

    -- NOT ZERO, and that is the whole reason this line has a comment.
    --
    -- GetGameTimer is milliseconds of uptime, and it is never zero by the
    -- time a player fires an event -- but a fixture that starts it there
    -- makes the limiter's own arithmetic untestable: with now and previous
    -- both 0, `now - previous` and `now + previous` are the same number,
    -- so a limiter that ADDS the two timestamps refuses the second call
    -- exactly as the correct one does and every assertion below passes
    -- against it. An hour of uptime is what a real server hands this
    -- function, and it tells the two apart.
    local clock = 3600000

local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- A CLOCK THIS FILE OWNS. The rate limiter is entirely about time,
        -- so a timer that advances a minute on every read cannot test it:
        -- every call would look like it arrived an hour after the last.
        GetGameTimer = function() return clock end,
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
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })


    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Betting.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, lobby = env.ArenaLobby, qbx = qbx }

    --- Fires one net event exactly as FXServer would, INCLUDING the rate
    --- limiter -- which is the point: a spec that calls ArenaLobby.Create
    --- directly walks past the whole of server/main.lua.
    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.advance(ms) clock = clock + (ms or 0) end
    function server.matches() return server.lobby.All() end
    function server.log() return table.concat(console, '\n') end
    function server.cash(src) return qbx.players[src].money.cash end

    return server
end

-- ======================================================================
-- THE RATE LIMITER, which nothing tested
-- ======================================================================

--- Opens a lobby and immediately leaves it, so the player is free to open
--- another and the ONLY thing that can refuse them is the rate limiter.
---
--- Without the leave, a second createMatch is refused by the lobby's own
--- "one match at a time" rule and the limiter is never consulted -- which is
--- how the first version of this test passed with the limiter switched off.
local function openAndLeave(server, src)
    server.fire('createMatch', src, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    server.fire('leaveMatch', src)
end

t.test('DEFECT: a second createMatch inside the interval does nothing', function()
    -- The first call opens a lobby. The second, in the same millisecond,
    -- must not open another -- and must not answer either: a refusal that
    -- costs one table lookup is the point, and one that replies is a way to
    -- make the server work for a spammer.
    local server = newServer()
    openAndLeave(server, 1)
    t.equals(#server.matches(), 0, 'the lobby was not left, so this proves nothing')

    -- Same millisecond, same player, nothing else standing in the way.
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 0,
        'a second createMatch from the same player inside the interval opened another lobby')
end)

t.test('and a DIFFERENT player is not held back by it', function()
    local server = newServer()
    openAndLeave(server, 1)

    server.fire('createMatch', 2, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 1, 'one player\'s spam rate-limited somebody else')
end)

t.test('and the same call after the interval is allowed', function()
    -- The other half. A limiter that never lets go is a resource that stops
    -- working, which is worse than one that never limits.
    local server = newServer()
    openAndLeave(server, 1)

    server.advance(60000)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 1, 'the player was still refused a minute later')
end)

t.test('and the boundary is exact -- at the interval, not one past it', function()
    -- `now - previous < interval` refuses; at exactly the interval the call
    -- is allowed. One millisecond either way is invisible to a player and
    -- is the difference between a limiter that lets go and one that holds a
    -- fraction longer every time it is hit -- which on a hot event is a
    -- player who cannot act at all.
    local server = newServer()
    openAndLeave(server, 1)

    -- One short: still refused.
    server.advance(2999)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 0, 'a call one millisecond inside the interval was let through')

    -- Exactly the interval: allowed.
    server.advance(1)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 1, 'a call at exactly the interval was refused')
end)

t.test('and the buckets are per EVENT, not one budget for everything', function()
    -- One player hammering createMatch must not lose the ability to leave.
    -- Sharing a bucket across events is how a rate limiter becomes a way to
    -- strand somebody in a match.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 1, 'the lobby was never opened')

    -- Same millisecond, different event: this must go through.
    server.fire('leaveMatch', 1)
    t.equals(#server.matches(), 0, 'leaving was refused because creating had just been called')
end)

t.test('and forgetting a player clears their history, not everybody\'s', function()
    -- ArenaForgetPlayer exists so `lastCall` does not gain a table per
    -- player who has ever connected and never give one back.
    local server = newServer()
    openAndLeave(server, 1)
    server.env.ArenaForgetPlayer(1)

    -- 1 is forgotten, so their next create is a first call again.
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    t.equals(#server.matches(), 1, 'a forgotten player was still rate-limited')
end)

t.test('and it refuses junk without being asked twice', function()
    -- The limiter takes whatever `source` was, which off a hostile client
    -- is not necessarily a number.
    local server = newServer()
    for _, junk in ipairs({ 'one', -1, 0 }) do
        local ok = server.env.ArenaRateLimit(junk, 'bucket', 1000)
        t.isFalse(ok == true, ('a junk source (%s) was rate-limit approved'):format(tostring(junk)))
    end
    t.isFalse(server.env.ArenaRateLimit(nil, 'bucket', 1000) == true,
        'a nil source was rate-limit approved')
end)

-- ======================================================================
-- A HOSTILE SHAPE IS REFUSED, NOT COERCED
-- ======================================================================

--- Payloads a modified client can send that a real panel never would.
local HOSTILE = {
    { name = 'nil', value = nil },
    { name = 'a string where a table belongs', value = 'not a table' },
    { name = 'a number where a table belongs', value = 42 },
    { name = 'a boolean', value = true },
    { name = 'an empty table', value = {} },
}

--- Every event server/main.lua registers, with a payload.
local EVENTS = {
    'createMatch', 'joinMatch', 'setTeam', 'setLoadout', 'updateMatch',
    'requestState', 'spectateMatch', 'placeSpectatorBet', 'reportDeath',
    'startMatch', 'cancelMatch', 'holdCountdown',
}

t.test('every wire event survives a hostile payload without throwing', function()
    -- None of this may raise. A handler that errors on a crafted payload is
    -- a way to take the resource down from a client.
    for _, event in ipairs(EVENTS) do
        for _, shape in ipairs(HOSTILE) do
            local server = newServer()
            local ok, err = pcall(server.fire, event, 1, shape.value)
            t.isTrue(ok, ('%s threw on %s: %s'):format(event, shape.name, tostring(err)))
        end
    end
end)

t.test('and a deeply nested table is refused rather than walked', function()
    -- A table nested into itself is the cheapest denial of service there is:
    -- anything that recurses without a depth bound never comes back.
    local server = newServer()
    local nest = {}
    local cursor = nest
    for _ = 1, 400 do
        cursor.next = {}
        cursor = cursor.next
    end
    nest.loop = nest   -- and a cycle, for good measure

    for _, event in ipairs(EVENTS) do
        local ok = pcall(server.fire, event, 1, nest)
        t.isTrue(ok, ('%s could not survive a self-referencing payload'):format(event))
    end
end)

t.test('and a huge list is bounded rather than walked to the end', function()
    local server = newServer()
    local weapons = {}
    for index = 1, 20000 do weapons[index] = { key = 'weapon_pistol', ammo = index } end

    local ok = pcall(server.fire, 'setLoadout', 1, { weapons = weapons })
    t.isTrue(ok, 'a twenty-thousand entry loadout was walked rather than bounded')
end)

t.test('and none of it opened a match, took money, or left a player in one', function()
    -- The real assertion: surviving is not enough. Nothing hostile may be
    -- ACTED on.
    local server = newServer()
    local before = server.cash(1)

    for _, event in ipairs(EVENTS) do
        for _, shape in ipairs(HOSTILE) do
            pcall(server.fire, event, 1, shape.value)
        end
    end

    t.equals(#server.matches(), 0, 'a hostile payload opened a match')
    t.equals(server.cash(1), before, 'a hostile payload moved money')
end)

-- ======================================================================
-- AND AUTHORITY IS RE-ASKED, NOT ASSUMED
-- ======================================================================

t.test('a match id the player is not in is refused', function()
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    local matchId = server.matches()[1].id

    -- 3 never joined. Nothing they send about this match may be acted on.
    server.fire('setReady', 3, { ready = true })
    server.fire('startMatch', 3, { matchId = matchId })

    local match = server.lobby.Get(matchId)
    t.isNotNil(match, 'the match vanished')
    t.isTrue(match.state ~= 'live',
        'a player who never joined started somebody else\'s match')
end)

t.test('and a bet on a side that does not exist is refused', function()
    -- pickExists is the guard. A bet on a pick that cannot win is a bet the
    -- settlement has no answer for.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    local matchId = server.matches()[1].id
    server.fire('joinMatch', 2, { matchId = matchId, account = 'cash' })

    local before = server.cash(3)
    local ok = server.env.ArenaBetting.PlaceSpectatorBet(3, matchId, 'no_such_team', 5000, 'cash')

    t.isFalse(ok, 'a bet was taken on a side that does not exist')
    t.equals(server.cash(3), before, 'money moved on a refused bet')
end)

os.exit(t.summary())
