--[[
    crimson_arena/tests/radarrule_spec.lua

    THE RADAR, AFTER IT STOPPED BEING A PERSONAL SETTING.

    It began as a per-player toggle in the lobby, kept only on the client
    that owned it and never put on the wire -- on the reasoning that a thing
    only you can see is nothing the server needs an opinion about.

    That reasoning was wrong about what the setting is. A radar is not a
    display preference; it is how much of the other side a round lets you
    see. Leaving it to each fighter made a match only as dark as its least
    patient player: anyone who wanted enemies on their map simply switched
    them on for themselves, and the sweep interval the setting exists for was
    a formality.

    So it is a rule of the match now, set by the host beside the arena, the
    mode and the lives. Which puts it on the seam this build has broken on
    more than any other -- a value decided at one end that never arrives at
    the other -- so these follow it the whole way: in through the wire, onto
    the match, out in the snapshot the panel draws from, and finally into the
    enterArena payload that is the only thing the client acts on.

    Nothing goes in through a function call where a player would use the
    wire, because the wire is where the last three of these bugs lived.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('radarrule_spec')

local function newServer(mutate)
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

    return server
end


--- The lobby the tests below edit. Host is 1, rival is 2.
--- @return table server
--- @return string matchId
local function lobby(radar, mutate)
    local server = newServer(mutate)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', radar = radar })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')
    return server, match.id
end

--- One match's card, out of the snapshot a given player would receive.
local function card(server, src, matchId)
    for _, entry in ipairs(server.snapshot(src).matches or {}) do
        if entry.id == matchId then return entry end
    end
    return nil
end

-- ======================================================================
-- IN, THROUGH THE WIRE
-- ======================================================================

t.test('the host creating a match with the radar on gets a match with it on', function()
    local server, matchId = lobby(true)
    t.equals(server.lobby.Get(matchId).radar, true,
        'the host asked for a radar and the match was opened without one')
end)

t.test('and off means off, not "unset"', function()
    local server, matchId = lobby(false)
    t.equals(server.lobby.Get(matchId).radar, false)
end)

t.test('a host who sends nothing gets the operator default', function()
    -- Not "off". An operator who defaults it on has said what an untouched
    -- form means, and a panel that posts nothing must not overrule them.
    local on = select(1, lobby(nil, function(config) config.Match.radar.defaultOn = true end))
    t.equals(on.lobby.All()[1].radar, true,
        'a server defaulting the radar ON opened a match without one')

    local off = select(1, lobby(nil, function(config) config.Match.radar.defaultOn = false end))
    t.equals(off.lobby.All()[1].radar, false)
end)

t.test('an operator who turned the radar off entirely cannot be overruled by a host', function()
    -- allowChoose off is the operator taking the decision away. The panel
    -- does not draw the control there at all, so a `true` on the wire is a
    -- stale client or a crafted payload -- and neither gets a radar.
    local server = select(1, lobby(true, function(config)
        config.Match.radar.allowChoose = false
        config.Match.radar.defaultOn = false
    end))
    t.equals(server.lobby.All()[1].radar, false,
        'a host switched on a radar the operator had disabled for the whole server')
end)

t.test('a junk value is not a radar', function()
    -- boolArg in server/main.lua: anything that is not a real boolean
    -- arrives as nil, which means "did not choose" and falls to the default.
    for _, junk in ipairs({ 'true', 1, {}, 'yes' }) do
        local server = newServer(function(config) config.Match.radar.defaultOn = false end)
        server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', radar = junk })
        t.equals(server.lobby.All()[1].radar, false,
            ('%s was accepted as a radar'):format(tostring(junk)))
    end
end)

-- ======================================================================
-- EDITING IT, AND WHO MAY
-- ======================================================================

t.test('the host can turn it on after the lobby is already open', function()
    local server, matchId = lobby(false)
    server.fire('updateMatch', 1, { radar = true })
    t.equals(server.lobby.Get(matchId).radar, true, 'Apply Changes did not reach the radar')
end)

t.test('and back off again', function()
    local server, matchId = lobby(true)
    server.fire('updateMatch', 1, { radar = false })
    t.equals(server.lobby.Get(matchId).radar, false,
        'the radar could be switched on but not off -- a false read as "unset"')
end)

t.test('HOST ONLY -- a fighter in the lobby cannot change it', function()
    local server, matchId = lobby(false)
    server.fire('joinMatch', 2, { matchId = matchId })
    t.isNotNil(server.lobby.Get(matchId).players[2], 'the rival could not join')

    server.fire('updateMatch', 2, { radar = true })
    t.equals(server.lobby.Get(matchId).radar, false,
        'somebody who is not the host set the radar for everybody in the match')
end)

t.test('an update that says nothing about the radar leaves it alone', function()
    -- The panel sends the whole form, but a partial payload must not read as
    -- "switch it off" -- that is the same nil-means-default trap the lives
    -- box fell into, pointed the other way.
    local server, matchId = lobby(true)
    server.fire('updateMatch', 1, { lives = 2 })
    t.equals(server.lobby.Get(matchId).radar, true,
        'editing the lives silently switched the radar off')
    t.equals(server.lobby.Get(matchId).lives, 2, 'the lives edit itself did not land')
end)

-- ======================================================================
-- OUT, TO THE PANEL
-- ======================================================================

t.test('the snapshot carries it, so the host form can show what it is', function()
    local server, matchId = lobby(true)
    t.equals(card(server, 1, matchId).radar, true,
        'the match card omits the radar, so a host reopening the panel is shown the default '
        .. 'instead of their own setting -- and re-applies it by pressing Apply')
end)

t.test('and everybody else is told too, not only the host', function()
    -- Not cosmetic: whether the round you are joining has a radar in it is
    -- part of what you are joining.
    local server, matchId = lobby(true)
    server.fire('joinMatch', 2, { matchId = matchId })
    t.equals(card(server, 2, matchId).radar, true)
end)

t.test('an edit reaches the snapshot, not just the match record', function()
    local server, matchId = lobby(false)
    server.fire('updateMatch', 1, { radar = true })
    t.equals(card(server, 1, matchId).radar, true,
        'the match changed and the card did not, so the panel keeps drawing the old setting')
end)

-- ======================================================================
-- AND FINALLY INTO THE ARENA, WHICH IS THE ONLY PART THE CLIENT ACTS ON
-- ======================================================================

--- Opens a two-player lobby and starts it, returning what each fighter was
--- handed on the way in.
local function started(radar)
    local server, matchId = lobby(radar)
    server.fire('joinMatch', 2, { matchId = matchId })
    server.fire('startMatch', 1)
    server.step(4)
    return server
end

t.test('every fighter enters the arena carrying the host\'s decision', function()
    local server = started(true)
    for _, src in ipairs({ 1, 2 }) do
        local payload = server.payloadTo('enterArena', src)
        t.isNotNil(payload, ('player %d was never sent into the arena'):format(src))
        t.equals(payload.radar, true,
            ('player %d entered a radar match with no radar in their payload -- '):format(src)
            .. 'the setting is stored, broadcast and then dropped at the one door that matters')
    end
end)

t.test('and a match with no radar says so explicitly', function()
    -- `false`, not absent. The client applies whatever arrives, and an
    -- absent field would leave the last match's setting in place.
    local server = started(false)
    local payload = server.payloadTo('enterArena', 1)
    t.isNotNil(payload)
    t.equals(payload.radar, false, 'the payload left the radar unstated')
    t.isTrue(payload.radar ~= nil, 'the radar field is absent, so a client keeps its previous value')
end)

os.exit(t.summary())
