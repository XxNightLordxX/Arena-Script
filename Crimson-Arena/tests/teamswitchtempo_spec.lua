--[[
    crimson_arena/tests/teamswitchtempo_spec.lua

    THE SAME TEAM SWITCH teamswitch_spec DRIVES, AT THE TEMPO A PERSON
    CLICKS AT.

    Reported from the live server three times, in the owner's words:

        "in the menu on team deathmatch i clicked a team, had another member
         join my team, they switched teams, and in the match they could not
         kill each other"

        "I had one guy that switched teams prior to the match starting and it
         bugged them where they couldnt shoot each other"

    His server said, for that round:

        teams: match mfa9fa starts ash 1 v crimson 2 (0 assigned, 3 chose their own)
        crossfire: 4 may not damage 3 -- they are on the same team and friendly fire is off.

    Three fighters, nobody auto-assigned, and the refusal fired between two
    the SERVER had on one side. So the switch did not do what the player
    thought it had done.

    WHY teamswitch_spec CANNOT SEE IT, and this is the whole reason this file
    exists. That file stubs the clock like this:

        GetGameTimer = function() clock = clock + 60000; return clock end,

    -- a minute between every call, "well past every RATE bucket in main.lua
    on every call". Its own comment then promises the exception:

        "THE ONE EXCEPTION IS DELIBERATE AND LIVES IN ITS OWN TEST BELOW: a
         switch that arrives inside 250ms of the pick before it is a
         different question, and it is asked there rather than accidentally
         here."

    There is no such test below. It was never written. So every switch in
    this suite has been made by a player who waited a minute between clicks,
    and server/main.lua's RATE.choice -- 250ms, shared by team, loadout and
    ready -- has never been exercised by anything.

    THE CLOCK HERE IS A CLOCK. It moves when a test moves it, by the number
    of milliseconds a person really would have taken, and every choice goes
    in through the net event server/main.lua registers with `source` set the
    way FiveM sets it. The bullet is the engine's own weaponDamageEvent,
    fired at server/dispatch.lua, which is the only place in this resource a
    shot can be stopped.

    AND THE CLIENT HALF IS RUN, NOT REASONED ABOUT. A fighter cannot shoot
    an opponent the GAME thinks is a teammate either, whatever the server
    allows -- client/match.lua puts the player on an engine team and turns
    NetworkSetFriendlyFireOption off. The last section loads that real file
    and asks what it tells the engine.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teamswitchtempo_spec')

-- ======================================================================
-- THE SERVER, WITH A CLOCK THAT ONLY MOVES WHEN A TEST MOVES IT
-- ======================================================================

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- One whole arena server, with the REAL dispatch, lobby, match and front
--- door in it, and a clock a test drives by hand.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)?
--- @return table server
local function newArena(wallets, mutate)
    local qbx = Sandbox.newQbxCore(roster(wallets))
    local oxlib = Sandbox.newOxLib()
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents, handlers, commands = {}, {}, {}, {}, {}

    -- STARTED WELL AWAY FROM ZERO. ArenaRateLimit's first call for a bucket
    -- always passes, so a clock that starts at 0 hides nothing -- but a
    -- rate window measured against `now - previous` behaves differently at
    -- the origin than it does an hour into a server's life, and the
    -- interesting case is the second one.
    local clock = { now = 3600000 }

    local present = {}
    for id in pairs(wallets) do present[id] = true end

    local buckets = {}

    local exportsTable = setmetatable(qbx.exports, {
        __call = function(_, _name, _fn) end,
    })

    local env = Sandbox.newArenaEnv({
        exports = exportsTable,
        lib = oxlib,

        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,

        print = function(line) console[#console + 1] = line end,

        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        -- THE POINT OF THIS FILE. Not a counter, not a minute a call: the
        -- millisecond a test says it is.
        GetGameTimer = function() return clock.now end,

        GetPlayerName = function(src)
            local record = qbx.players[src]
            if not record or not present[src] then return '' end
            return record.name
        end,
        GetPlayers = function()
            local out = {}
            for src in pairs(present) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        NetworkGetNetworkIdFromEntity = function(ped)
            local src = (tonumber(ped) or 0) - 1000
            return present[src] and (5000 + src) or 0
        end,
        GetEntityCoords = function(ped)
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,

        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) buckets[tonumber(src)] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        Player = function() return { state = { set = function() end } } end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
            Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Refresh = function() return true end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
    })

    local cancelled = false
    env.CancelEvent = function() cancelled = true end

    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env,
        qbx = qbx,
        config = env.Config,
        lobby = env.ArenaLobby,
        match = env.ArenaMatch,
        dispatch = env.ArenaDispatch,
    }

    --- Moves the server clock on by `ms`. Every click below is separated by
    --- one of these, and the number is the thing under test.
    function server.after(ms)
        clock.now = clock.now + math.max(0, math.floor(tonumber(ms) or 0))
    end

    --- One client -> server event, as the panel sends it.
    function server.fire(event, src, data)
        local name = 'crimson_arena:server:' .. event
        local handler = netEvents[name]
        if not handler then error('no handler registered for ' .. name, 2) end
        env.source = src
        handler(data)
    end

    function server.step()
        threads.step()
        threads.step()
    end

    --- Fires the engine's damage packet from `attacker` at `victims`.
    --- @return boolean cancelled -- true when the server refused the shot
    function server.shoot(attacker, victims)
        cancelled = false
        local hits = {}
        for _, victim in ipairs(victims) do
            hits[#hits + 1] = 5000 + victim
        end
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do
            fn(tostring(attacker), { hitGlobalIds = hits })
        end
        return cancelled
    end

    --- Everything one player has been told, in order.
    function server.told(id)
        local said = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == id then
                said[#said + 1] = tostring(message.payload.description)
            end
        end
        return table.concat(said, '\n')
    end

    --- How many lines this player has been told. A click that reaches the
    --- server and is acted on must move this; a click the server never saw
    --- must not.
    function server.lines(id)
        local count = 0
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == id then
                count = count + 1
            end
        end
        return count
    end

    --- The teamKey the SERVER told this client to fight under.
    function server.toldTeam(id)
        local team = nil
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:enterArena' and message.target == id then
                team = message.payload.teamKey
            end
        end
        return team
    end

    --- What the panel last showed this player as their own side.
    function server.panelTeam(id)
        return server.lobby.BuildState(id).player.team
    end

    function server.log() return table.concat(console, '\n') end

    return server
end

--- Opens a team-deathmatch lobby at the trailer park with `ids[1]` hosting.
--- Every join is separated by seconds, because that is how long walking up
--- to a panel and clicking Join takes.
--- @return string matchId
local function openTdm(server, ids)
    server.after(4000)
    server.fire('createMatch', ids[1], {
        arenaKey = 'trailerpark', modeKey = 'tdm', entryFee = 0,
    })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a team deathmatch lobby')

    for index = 2, #ids do
        server.after(4000)
        server.fire('joinMatch', ids[index], { matchId = match.id })
        t.isNotNil(match.players[ids[index]], ('player %d could not join'):format(ids[index]))
    end

    return match.id
end

--- Starts the match and runs the countdown out, so the fighters are placed.
local function startAndPlace(server, matchId, host)
    server.after(4000)
    local ok, reason = server.match.Begin(matchId, host)
    t.isTrue(ok, ('the match would not start: %s'):format(tostring(reason)))
    for _ = 1, 40 do server.step() end
end

-- ======================================================================
-- WHAT THIS FILE ASSUMES ABOUT THE SHIPPED CONFIGURATION
-- ======================================================================

t.test('the shipped tempo and team rules are the ones these tests assume', function()
    local server = newArena({})
    t.equals(server.config.Modes.tdm.teams, true)
    t.equals(server.config.Teams.friendlyFire, false, 'friendly fire ships OFF -- that is what makes a stale side fatal')
    t.equals(server.config.Teams.allowChoose, true)
    t.equals(server.config.Teams.maxTeamSize, 0, 'no cap ships, so nothing refuses a switch for room')
    t.equals(server.config.Match.crossfireGuard.enabled, true)
end)

-- ======================================================================
-- THE ROUND HE REPORTED, REPRODUCED
-- ======================================================================

t.test('DEFECT: a correction clicked 200ms after the pick is answered rather than swallowed', function()
    -- The shape his log records: three fighters, all three picking for
    -- themselves. 2 lands on 1's side and immediately corrects himself --
    -- the ordinary misclick correction, a fifth of a second later, because
    -- the tile he clicked has not lit up yet and will not until the server
    -- answers.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 3, { teamKey = 'ash' })

    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    local before = server.lines(2)
    server.after(200)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    -- server/main.lua's onClient drops a client event that arrives inside
    -- RATE.choice, and it is right to: the limiter is what stops a client
    -- flooding this server. What it must NOT do is drop it in silence,
    -- which is what it did -- no refusal, no toast, no state push, nothing
    -- in any log -- while every other way a switch can be turned down says
    -- so out loud. The player clicked the other side, nothing moved, and
    -- nothing told him.
    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson',
        'the throttle let the click through, so this test is no longer driving the path it is about')

    t.isTrue(server.lines(2) > before,
        'the throttled click was swallowed without a word -- the fighter has no way to know he did not move')
    t.contains(server.told(2), 'Crimson',
        'the answer to a throttled click must name the side he is actually on')

    -- AND CLICKING AGAIN WORKS, which is what the answer above is for.
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })
    t.equals(server.lobby.Get(matchId).players[2].team, 'ash',
        'the second attempt did not take either')
    t.contains(server.told(2), 'Ash',
        'a switch the server TOOK still told the player nothing')
end)

t.test('DEFECT: the fighter walks into the round on the side he tried to leave, and is never told', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 3, { teamKey = 'ash' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.after(200)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    startAndPlace(server, matchId, 1)

    -- His log, line for line.
    t.contains(server.log(), 'ash 1 v crimson 2',
        'the round did not start in the shape his server recorded')

    -- His symptom, line for line: the pair the server has on one side
    -- cannot touch each other, and 2 believes he is on the other one.
    t.isTrue(server.shoot(1, { 2 }), '1 and 2 are both crimson -- the shot must die')
    t.isTrue(server.shoot(2, { 1 }))
    t.isFalse(server.shoot(2, { 3 }), 'and the line 2 never crossed is open')

    -- THE FIX. Whatever the panel did or did not manage to show him in the
    -- lobby, a fighter standing in the arena is told which side he is
    -- fighting for, by name, before a shot is fired. He cannot walk into
    -- this round believing he is on ash.
    t.contains(server.told(2), 'Crimson',
        'the fighter was never told which side he is on')
    t.contains(server.told(1), 'Crimson')
    t.contains(server.told(3), 'Ash')
end)

-- ======================================================================
-- EVERY CLICK THE SERVER ACTS ON ANSWERS
-- ======================================================================

t.test('a switch that is taken names the side it moved you to', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    local before = server.lines(2)
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'ash')
    t.isTrue(server.lines(2) > before, 'the switch was taken in silence')
    t.contains(server.told(2), 'Ash')
end)

t.test('re-clicking the side you are already on answers too -- it is not a black hole', function()
    -- THE CLICK THAT MADE THE ONE ABOVE POSSIBLE. Picking the side you are
    -- already on changes nothing, so nothing was broadcast and nothing was
    -- said -- the panel did not so much as flicker. A player whose click
    -- produces no visible answer clicks again, and THAT is the click the
    -- 250ms window eats.
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    local before = server.lines(2)
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson')
    t.isTrue(server.lines(2) > before,
        'a re-click of your own side said nothing at all, which is what teaches a player to click twice')
end)

t.test('a refused switch says so and moves nobody', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Teams.maxTeamSize = 1
    end)
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    local before = server.lines(2)
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'ash', 'the cap was not enforced')
    t.equals(server.panelTeam(2), 'ash', 'the panel and the server disagree')
    t.isTrue(server.lines(2) > before, 'a refused switch said nothing')
end)

t.test('a switch refused during the countdown says so, and the round is fought on the old sides', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'ash' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    server.after(3000)
    t.isTrue((server.match.Begin(matchId, 1)))
    t.equals(server.lobby.Get(matchId).state, 'countdown')

    local before = server.lines(2)
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson',
        'a countdown switch half-applied')
    t.isTrue(server.lines(2) > before, 'the countdown refusal was silent')
    t.equals(server.panelTeam(2), 'crimson')
end)

-- ======================================================================
-- THE SWITCH SHAPES, AT PANEL TEMPO, DRIVEN TO A BULLET
-- ======================================================================

--- Runs a list of { src, teamKey, gapMs } picks and starts the round.
local function play(server, matchId, picks)
    for _, pick in ipairs(picks) do
        server.after(pick[3] or 3000)
        server.fire('setTeam', pick[1], { teamKey = pick[2] })
    end
    startAndPlace(server, matchId, 1)
end

t.test('only B switches: the shot across the line lands', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })
    play(server, matchId, {
        { 1, 'crimson' }, { 2, 'crimson' }, { 2, 'ash' },
    })

    t.equals(server.toldTeam(1), 'crimson')
    t.equals(server.toldTeam(2), 'ash')
    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('both switch, ending on opposite sides', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })
    play(server, matchId, {
        { 1, 'crimson' }, { 2, 'crimson' }, { 1, 'ash' }, { 2, 'ash' }, { 2, 'crimson' },
    })

    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('B switches twice and ends where they started', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })
    play(server, matchId, {
        { 1, 'crimson' }, { 2, 'crimson' }, { 3, 'ash' }, { 2, 'ash' }, { 2, 'crimson' },
    })

    t.isTrue(server.shoot(1, { 2 }), 'two on one side must not be able to shoot each other')
    t.isFalse(server.shoot(2, { 3 }))
end)

t.test('B switches, leaves and rejoins', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    server.after(3000)
    server.fire('leaveMatch', 2)
    server.after(3000)
    server.fire('joinMatch', 2, { matchId = matchId })
    t.isNil(server.lobby.Get(matchId).players[2].team,
        'the rejoin walked back in already on a side')

    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    startAndPlace(server, matchId, 1)
    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('the countdown is held, the switch is taken, and the round starts on the new sides', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'ash' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    -- Everyone on one side: the start is refused rather than taken, which
    -- is the other half of the report -- "you try to start it with the same
    -- team then switch again".
    server.after(3000)
    local began, why = server.match.Begin(matchId, 1)
    t.isFalse(began, 'a one-sided team round started')
    t.equals(why, 'error.need_two_teams')

    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson')

    startAndPlace(server, matchId, 1)
    t.isFalse(server.shoot(1, { 2 }), 'the shot across the line was refused after a refused start')
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('a switch refused over a side bet leaves the fighter where the bullet will judge them', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 3, { teamKey = 'ash' })

    server.after(3000)
    server.fire('placeSpectatorBet', 2, { matchId = matchId, pick = 'crimson', amount = 500 })

    local before = server.lines(2)
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson',
        'a fighter took their own money off the table by changing sides')
    t.isTrue(server.lines(2) > before, 'the refusal was silent')
    t.equals(server.panelTeam(2), 'crimson')

    startAndPlace(server, matchId, 1)
    t.isTrue(server.shoot(1, { 2 }), '1 and 2 are still both crimson')
    t.isFalse(server.shoot(2, { 3 }))
end)

-- ======================================================================
-- THE CLIENT'S OWN IDEA OF ITS SIDE
-- ======================================================================

--- The real client/match.lua, far enough in to have told the engine which
--- side this player is on.
---
--- NOT A WHOLE ROUND. The entry handler goes on to build an arena out of
--- props and yield inside model loads, and none of that is this section's
--- question: holdFriendlyFire runs BEFORE any of it, so the handler is
--- driven until it parks or falls over and what it wrote is read off after.
--- @return table client
local function newClient()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { printed = {}, notified = {} }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,

        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,

        print = function(line) c.printed[#c.printed + 1] = tostring(line) end,
        lib = { notify = function(payload) c.notified[#c.notified + 1] = payload end },
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },

        PlayerId = function() return 0 end,
        PlayerPedId = function() return c.ped or 1000 end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        DoesEntityExist = function() return true end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        -- The identity, as fixtures/world.lua does it: a weapon hash IS its
        -- name here, which is all this section needs of it.
        joaat = function(name) return name end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        SetCurrentPedWeapon = function() end,
        RemoveAllPedWeapons = function() end,

        -- THE THREE WRITES THIS SECTION IS ABOUT. They are settings on the
        -- PLAYER rather than the ped, they are what the engine judges a
        -- bullet between two players against, and nothing else on a server
        -- puts them back.
        SetPlayerTeam = function(_player, team) c.engineTeam = team end,
        GetPlayerTeam = function() return c.engineTeam or -1 end,
        NetworkSetFriendlyFireOption = function(on) c.friendlyFire = on end,
        SetCanAttackFriendly = function(_ped, can) c.canAttackFriendly = can end,
    })

    Sandbox.loadInto('../client/match.lua', env)

    c.env = env
    c.Arena = env.Arena

    --- Drives the entry handler until it parks in a yield or falls over on a
    --- native this fixture does not carry. Either is fine: the engine team
    --- is set in the first dozen lines.
    function c.enter(teamKey)
        local handler = handlers['crimson_arena:client:enterArena']
        assert(handler, 'client/match.lua registered no enterArena handler')
        local thread = coroutine.create(function()
            handler({
                matchId = 'match-1',
                arenaKey = 'trailerpark',
                modeKey = 'tdm',
                teamKey = teamKey,
                spawn = { x = 2344.4, y = 2565.1, z = 46.7, w = 90.0 },
                scatterRadius = 0.0,
                sizeFactor = 1.0,
                loadout = { weapons = {}, health = 200, armor = 0 },
                freezeSeconds = 0,
            })
        end)
        for _ = 1, 50 do
            if coroutine.status(thread) == 'dead' then break end
            if not select(1, coroutine.resume(thread)) then break end
        end
    end

    return c
end

t.test('the client fights under the side the server sent it, and two sides are never one engine team', function()
    local client = newClient()

    client.enter('crimson')
    local crimson = client.engineTeam
    t.equals(crimson, client.Arena.TeamIndex('crimson'),
        'the engine was told a side that is not the one the server sent')
    t.isFalse(client.friendlyFire, 'friendly fire was left on in a mode whose rule is that it is off')

    -- The next round, on the other side. Nothing about the first may follow
    -- this player into it -- a cached side here is the client half of the
    -- reported bug, and it would look exactly the same from inside the game.
    client.enter('ash')
    local ash = client.engineTeam
    t.equals(ash, client.Arena.TeamIndex('ash'),
        'the client kept the side it was told last round')

    t.isNotNil(crimson)
    t.isNotNil(ash)
    t.isTrue(crimson ~= ash,
        'both sides map to ONE engine team, so the game would refuse every shot between them whatever the server allowed')
end)

t.test('the enabled sides map onto engine teams one for one, in a fixed order', function()
    -- EVERY CLIENT HAS TO AGREE, and nothing synchronises this: each one
    -- works its own index out from the shared config. Arena.GetEnabledTeams
    -- walks `pairs` over a hash table, so the SORT underneath it is the only
    -- thing standing between two players and the same engine team.
    local client = newClient()
    local seen = {}
    for _, team in ipairs(client.Arena.GetEnabledTeams()) do
        local index = client.Arena.TeamIndex(team.key)
        t.isNotNil(index, ('enabled side %s has no engine team'):format(team.key))
        t.isNil(seen[index], ('two sides share engine team %s'):format(tostring(index)))
        seen[index] = team.key
    end

    -- Asked twice, because an order that changes between two calls in one
    -- process is an order that changes between two players.
    for _, team in ipairs(client.Arena.GetEnabledTeams()) do
        t.equals(seen[client.Arena.TeamIndex(team.key)], team.key,
            'the side-to-team mapping is not stable across calls')
    end
end)

os.exit(t.summary())
