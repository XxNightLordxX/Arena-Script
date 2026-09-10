--[[
    crimson_arena/tests/friendlyfireends_spec.lua

    THE FRIENDLY-FIRE HOLD MUST NOT OUTLIVE THE ROUND THAT PUT IT ON.

    IN A PLAYER'S WORDS: "Ensure the friendly fire etc does not follow after
    a match is over."

    He asks it having just been bitten by the opposite mistake -- a round
    where two fighters could not hurt each other, which he read as friendly
    fire being broken and which was really a team switch the server never
    took (see teamswitchtempo_spec). This is the other end of the same
    worry, and it is a fair one, because BOTH halves of the rule are state
    somebody has to remember to put back:

      * THE SERVER refuses a damage packet in server/dispatch.lua by asking
        `active[src]` which round a player is in and then reading their side
        off the live roster row. A flag left raised, or a lobby row left
        lying about, and two people who fought together are still allies in
        the street.

      * THE CLIENT sets SetPlayerTeam and NetworkSetFriendlyFireOption,
        which are settings on the PLAYER and not on the ped. Nothing else on
        a server writes them and nothing else will ever put them back, so a
        path out of a round that forgets to release them leaves them set for
        the rest of that player's session -- through every respawn, every
        death, every other resource, until they reconnect.

    MEASURED, NOT REASONED ABOUT. Every way a round can end is driven here
    and then a bullet is fired: End, Abort, an admin stop, the host closing
    the lobby, a fighter disconnecting, the resource stopping mid-round, and
    an ally who was eliminated before the end. The client half is the real
    file, entered and left.

    NOTHING WAS FOUND WRONG. This file is a guard, not a fix -- and it was
    checked against the mutations it is meant to catch: delete the
    ArenaDispatch.Clear on the exit path, or the releaseFriendlyFire at the
    top of leaveArena, and it goes red. DO NOT weaken it into asserting only
    that a live round refuses -- that half passes on its own.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('friendlyfireends_spec')

-- ======================================================================
-- THE SERVER
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

    --- Their connection going away, through every handler that wants it.
    function server.drop(src)
        env.source = src
        for _, fn in ipairs(handlers['playerDropped'] or {}) do fn() end
        present[src] = nil
    end

    --- The resource going down under a live round.
    function server.stop()
        for _, fn in ipairs(handlers['onResourceStop'] or {}) do fn('crimson_arena') end
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
-- A TEAM ROUND WITH TWO ON ONE SIDE, WHICH IS THE ONLY SHAPE THAT CAN
-- LEAVE ANYTHING BEHIND
-- ======================================================================

--- 1 and 2 on crimson, 3 on ash, placed and fighting.
--- @return string matchId
local function liveRound(server)
    local matchId = openTdm(server, { 1, 2, 3 })
    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 3, { teamKey = 'ash' })
    startAndPlace(server, matchId, 1)

    -- THE CONTROL, and it is not decoration: every test below asserts that
    -- a shot LANDS, and a guard that had stopped working entirely would
    -- pass all of them. This is the line that says the guard was on.
    t.isTrue(server.shoot(1, { 2 }), 'the two allies could shoot each other DURING the round')
    return matchId
end

--- Both directions between two people who were on one side, after the fact.
local function bothWays(server, a, b, message)
    t.isFalse(server.shoot(a, { b }), message)
    t.isFalse(server.shoot(b, { a }), message)
end

t.test('when the round ends properly, two former allies can shoot each other again', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.End(matchId, 'match.ended')
    for _ = 1, 60 do server.step() end

    t.isNil(server.lobby.Get(matchId), 'the lobby row outlived the round')
    t.isFalse(server.dispatch.IsPlayerInArena(1), 'the arena flag was left raised on a fighter who is home')
    t.isFalse(server.dispatch.IsPlayerInArena(2))
    bothWays(server, 1, 2, 'two people who fought on one side are still allies out in the city')
end)

t.test('and when it is aborted rather than won', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.Abort(matchId, 'match.aborted')
    for _ = 1, 60 do server.step() end

    t.isFalse(server.dispatch.IsPlayerInArena(1))
    bothWays(server, 1, 2, 'an aborted round left its sides behind')
end)

t.test('and when an admin stops it', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.Abort(matchId, 'notify.match_stopped_by_admin')
    for _ = 1, 60 do server.step() end

    bothWays(server, 1, 2, 'an admin stop left its sides behind')
end)

t.test('and when the resource goes down with the round still running', function()
    -- THE ONE NOBODY IS AROUND FOR. A restart is the case where nothing
    -- politely walks each fighter out first, and it is also the commonest
    -- thing an operator does to a live server.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    liveRound(server)

    server.stop()
    for _ = 1, 40 do server.step() end

    t.isFalse(server.dispatch.IsPlayerInArena(1), 'a restart left the arena flag raised')
    t.isFalse(server.dispatch.IsPlayerInArena(2))
    bothWays(server, 1, 2, 'a restart left two fighters allied for the rest of the session')
end)

t.test('a fighter who drops leaves nothing on their server id for whoever inherits it', function()
    -- SERVER IDS ARE RECYCLED, and this resource has already been bitten by
    -- that twice -- the exit robbing whoever inherited a departed fighter's
    -- id, and the strike counts following one. A dispatch flag is the same
    -- trap: left on the id, the next person to connect as 2 is in a round
    -- they have never heard of.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    liveRound(server)

    server.drop(2)
    for _ = 1, 20 do server.step() end

    t.isFalse(server.dispatch.IsPlayerInArena(2), 'the flag stayed on the id after the player behind it left')
    t.isNil(server.dispatch.GetPlayerMatchId(2), 'and it still names the round they walked out of')
end)

t.test('an ally who was eliminated before the end is not still an ally after it', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    local match = server.lobby.Get(matchId)
    match.players[2].lives = 0
    match.players[2].alive = false
    t.isTrue(server.shoot(1, { 2 }), 'the control: they are still on one side while the round runs')

    server.match.End(matchId, 'match.ended')
    for _ = 1, 60 do server.step() end

    bothWays(server, 1, 2, 'an eliminated ally stayed an ally after the round was over')
end)

t.test('and the next round judges them by the sides they are on in THAT round', function()
    -- The whole point, stated as a round rather than as a flag: nothing
    -- about who you fought beside may reach the next fight.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local first = liveRound(server)
    server.match.End(first, 'match.ended')
    for _ = 1, 60 do server.step() end

    local second = openTdm(server, { 1, 2, 3 })
    server.after(3000)
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.after(3000)
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.after(3000)
    server.fire('setTeam', 3, { teamKey = 'ash' })
    startAndPlace(server, second, 1)

    bothWays(server, 1, 2, 'last round\'s side decided this round\'s bullet')
    t.isTrue(server.shoot(2, { 3 }), 'and this round\'s side is not being read either')
end)

t.test('NOR IS THE OTHER HALF WEAKENED: a live round is still sealed off from the street', function()
    -- Everything above asserts that a shot LANDS, so the cheapest way to
    -- make this file green is to stop refusing anything at all. This is the
    -- test that costs.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000, [4] = 5000 })
    liveRound(server)

    t.isTrue(server.shoot(4, { 1 }), 'a passer-by shot a fighter in a live round')
    t.isTrue(server.shoot(1, { 4 }), 'a fighter shot a passer-by from inside a live round')
    t.isTrue(server.shoot(1, { 2 }), 'and two on one side can still not touch each other')
    t.isFalse(server.shoot(1, { 3 }), 'while the line between the sides is open')
end)

-- ======================================================================
-- THE CLIENT
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

    c.handlers = handlers

    --- Any handler, driven the way FiveM drives one.
    function c.fire(name, ...)
        local handler = handlers[name]
        assert(handler, 'client/match.lua registered no ' .. name .. ' handler')
        local args = table.pack(...)
        local thread = coroutine.create(function() handler(table.unpack(args, 1, args.n)) end)
        for _ = 1, 50 do
            if coroutine.status(thread) == 'dead' then break end
            if not select(1, coroutine.resume(thread)) then break end
        end
    end

    --- The round ending under this client, as the server ends it.
    function c.exit()
        c.fire('crimson_arena:client:exitArena',
            { returnCoords = { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } })
    end

    --- A round in a mode of the caller's choosing, for the free-for-all
    --- case -- where there is no side and nothing may be held at all.
    function c.enterMode(modeKey, teamKey)
        local handler = handlers['crimson_arena:client:enterArena']
        local thread = coroutine.create(function()
            handler({
                matchId = 'match-1',
                arenaKey = 'trailerpark',
                modeKey = modeKey,
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

t.test('a team round puts the player on their side and turns friendly fire off', function()
    local client = newClient()
    client.enter('crimson')

    t.equals(client.engineTeam, client.Arena.TeamIndex('crimson'),
        'the engine was never told which side this fighter is on')
    t.isFalse(client.friendlyFire, 'friendly fire was left on in a mode whose rule is that it is off')
    t.isFalse(client.canAttackFriendly)
end)

t.test('and walking out of the round puts all three back', function()
    -- THE ONE THAT FOLLOWS YOU HOME. These are settings on the PLAYER, not
    -- on the ped, so a respawn does not clear them and neither does
    -- anything else on the box. Left set, this player spends the rest of
    -- their session unable to hurt -- or be hurt by -- everyone the engine
    -- still has on team 1.
    local client = newClient()
    client.enter('crimson')
    client.exit()

    t.equals(client.engineTeam, -1, 'the arena kept this player on its own team after the round')
    t.isTrue(client.friendlyFire, 'friendly fire stayed off after the round that turned it off')
    t.isTrue(client.canAttackFriendly)
end)

t.test('and so does the resource going down under them', function()
    local client = newClient()
    client.enter('crimson')
    client.fire('onResourceStop', 'crimson_arena')

    t.equals(client.engineTeam, -1, 'a restart left the arena team on the player')
    t.isTrue(client.friendlyFire, 'a restart left friendly fire off')
end)

t.test('a free-for-all never touches either of them, so it has nothing to leave behind', function()
    local client = newClient()
    client.enterMode('ffa', nil)

    t.isNil(client.engineTeam, 'a mode with no sides put the player on one')
    t.isNil(client.friendlyFire, 'a mode with no sides had an opinion about friendly fire')
end)

t.test('a second round on the other side starts from the engine default, not from the first', function()
    local client = newClient()
    client.enter('crimson')
    client.exit()
    client.enter('ash')

    t.equals(client.engineTeam, client.Arena.TeamIndex('ash'),
        'the second round inherited the first round\'s side')

    client.exit()
    t.equals(client.engineTeam, -1,
        'and the second round put back the side the FIRST one had set, not the engine default')
end)

os.exit(t.summary())
