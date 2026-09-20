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

    NOTHING WAS FOUND WRONG IN THE RESOURCE. This file is a guard, not a fix
    -- and it is checked against the mutations it is meant to catch: delete
    the ArenaDispatch.Clear on the exit path, or the releaseFriendlyFire at
    the top of leaveArena, and it goes red. DO NOT weaken it into asserting
    only that a live round refuses -- that half passes on its own.

    TWO THINGS WERE FOUND WRONG IN THIS FILE, both of the same kind: an
    assertion that could not fail. They are worth naming because the shape
    recurs.

      * THE RELEASE COULD NOT BE TOLD FROM A CONSTANT. Every client test
        started from engine team -1, which is both the default AND what a
        release that had forgotten its reading would hand back. Replacing
        `SetPlayerTeam(PlayerId(), priorTeam or -1)` with a bare -1 passed
        the whole file. The tests below now walk in on team 7 -- a job or
        gang script's team, which is the ordinary case on a roleplay server
        and the one where the two answers differ.

      * THE SERVER HALF WENT GREEN WITHOUT TELLING THE CLIENT ANYTHING.
        Every server assertion here asks whether the server would still
        refuse a bullet, and the server answers out of ArenaDispatch, which
        each exit path clears directly. Delete the exitArena from
        ArenaLobby.Destroy's fighter loop and all of it still passed --
        while every fighter in a torn-down round kept the arena's team and
        its friendly fire setting for the rest of their session. The client
        section proves the release happens WHEN TOLD; server.sentHome is
        the other half of that sentence, and wentHome puts it on every end
        path.

    EIGHT MUTATIONS ARE KILLED BY THIS FILE, and they are listed so the next
    person can re-run them: release hands back a hardcoded -1; release loses
    its not-held guard; being eliminated drops the hold mid-round;
    Arena.TeamIndex collapses both sides onto one number; Destroy stops
    sending exitArena; sendExitArena stops sending; sendPlayerHome always
    refuses; leaveArena forgets to release.
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

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/dispatch.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/lobby.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/match.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/main.lua', env)

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

    --- HOW MANY TIMES THE SERVER HAS TOLD THIS CLIENT THE ROUND IS OVER.
    ---
    --- THE ONLY THING THAT RELEASES THE CLIENT-SIDE HOLD, and the seam this
    --- file was blind down. The section below proves client/match.lua puts
    --- the engine team and NetworkSetFriendlyFireOption back WHEN IT IS
    --- TOLD TO LEAVE. This is the other half of that sentence -- that it IS
    --- told -- and the two halves live in different processes, so neither
    --- one alone says a fighter walks out of a round able to hurt the
    --- people they fought beside.
    ---
    --- MEASURED BECAUSE IT WAS SURVIVED. Delete the exitArena from
    --- ArenaLobby.Destroy's fighter loop and every server assertion in this
    --- file still passed: the refusal reads ArenaDispatch, which that path
    --- clears separately, so the server half looked perfect while every
    --- fighter in a torn-down round kept the arena's team and its friendly
    --- fire setting FOR THE REST OF THEIR SESSION. That is the exact defect
    --- this file exists to prevent, and it walked straight through it.
    ---
    --- A COUNT AND NOT A BOOLEAN, so a path that sends it twice is visible
    --- rather than rounded off.
    function server.sentHome(id)
        local count = 0
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:exitArena' and message.target == id then
                count = count + 1
            end
        end
        return count
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

--- AND THE OTHER PROCESS WAS TOLD, which bothWays cannot see.
---
--- bothWays asks the SERVER whether it would still refuse a bullet, and the
--- server answers out of ArenaDispatch -- a table every exit path clears
--- directly. So bothWays goes green on a path that never tells the client
--- anything at all, and the client is where SetPlayerTeam and
--- NetworkSetFriendlyFireOption are still set. Measured: deleting the
--- exitArena from ArenaLobby.Destroy's fighter loop left every server
--- assertion in this file passing.
---
--- EXACTLY ONCE, and that is not pedantry. Twice is the shape that wipes the
--- team a player walked in on -- see "and a second exit does not take it off
--- them again" below for what the client does with a repeat, and why it is
--- guarded there as well as counted here.
--- @param ids integer[] -- everyone who was standing in the arena
local function wentHome(server, ids, what)
    for _, id in ipairs(ids) do
        t.equals(server.sentHome(id), 1,
            ('%s: nobody told fighter %d the round was over, so their client is still holding its side'):format(what, id))
    end
end

t.test('when the round ends properly, two former allies can shoot each other again', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.End(matchId, 'match.ended')
    for _ = 1, 60 do server.step() end

    t.isNil(server.lobby.Get(matchId), 'the lobby row outlived the round')
    t.isFalse(server.dispatch.IsPlayerInArena(1), 'the arena flag was left raised on a fighter who is home')
    t.isFalse(server.dispatch.IsPlayerInArena(2))
    wentHome(server, { 1, 2, 3 }, 'the round ended properly')
    bothWays(server, 1, 2, 'two people who fought on one side are still allies out in the city')
end)

t.test('and when it is aborted rather than won', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.Abort(matchId, 'match.aborted')
    for _ = 1, 60 do server.step() end

    t.isFalse(server.dispatch.IsPlayerInArena(1))
    wentHome(server, { 1, 2, 3 }, 'the round was aborted')
    bothWays(server, 1, 2, 'an aborted round left its sides behind')
end)

t.test('and when an admin stops it', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    server.match.Abort(matchId, 'notify.match_stopped_by_admin')
    for _ = 1, 60 do server.step() end

    wentHome(server, { 1, 2, 3 }, 'an admin stopped the round')
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
    wentHome(server, { 1, 2, 3 }, 'the resource went down mid-round')
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
    wentHome(server, { 2 }, 'a fighter walked out of a live round')
    t.equals(server.sentHome(1), 0, 'one fighter leaving sent everybody else home too')
    t.equals(server.sentHome(3), 0, 'one fighter leaving sent everybody else home too')
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

    wentHome(server, { 1, 2, 3 }, 'the round ended with an eliminated fighter on the roster')
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

t.test('and when the lobby row is torn down under a round that is still being fought', function()
    -- THE THIRD PUBLIC WAY OUT, and the only one whose exit is behind a
    -- gate. End and Abort send theirs to every fighter unconditionally;
    -- ArenaLobby.Destroy sends its own only `if IsPlayerInArena(src)`, and
    -- that gate is the whole question here -- it is what decides whether a
    -- fighter standing in a live arena is told the round has gone.
    --
    -- Reached in production from the idle sweep, the host cancelling, and
    -- the last fighter leaving; End and Abort both call it as their own
    -- last act. Driven directly because the gate, not the caller, is what
    -- can break.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)

    t.isTrue(server.dispatch.IsPlayerInArena(1), 'the control: the gate is open before the row is torn down')

    server.lobby.Destroy(matchId, 'notify.match_closed')
    for _ = 1, 60 do server.step() end

    t.isFalse(server.dispatch.IsPlayerInArena(1), 'tearing the row down left the arena flag raised on a fighter')
    t.isFalse(server.dispatch.IsPlayerInArena(2))
    wentHome(server, { 1, 2, 3 }, 'the lobby row was torn down under a live round')
    bothWays(server, 1, 2, 'a round whose row was torn down left its sides behind')
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

    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

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
    -- ONE OF THE TWO IS WRITTEN, AND ONLY ONE.
    --
    -- NetworkSetFriendlyFireOption IS. It is team-scoped, so it cannot refuse
    -- an enemy, and it is the only thing that zeroes the teammate's half of a
    -- spread the server deliberately lets through whole (crossfire_spec's
    -- "THE REGRESSION: a spread that catches a teammate still hits the
    -- enemy"), or a melee blow the server mostly never sees -- measured in
    -- this repo's history: three team rounds of bottles and crowbars produced
    -- exactly ONE friendly-fire refusal, and it was a gun.
    --
    -- SetCanAttackFriendly IS NOT. It answers a RELATIONSHIP question, and
    -- GTA's one PLAYER group makes every player friendly to every other, so
    -- refusing "friendlies" refused every player regardless of the team index
    -- set alongside it -- the report, "i can't shoot my enemies and they
    -- can't shoot me".

    t.isFalse(client.friendlyFire,
        'friendly fire was left ON in a mode whose rule is that it is off')
    t.isNil(client.canAttackFriendly, 'this resource is writing SetCanAttackFriendly again')
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
    -- A SETTING NEVER WRITTEN IS A SETTING NEVER LEFT BEHIND. This is the
    -- half of the header's promise that used to need a release at all: both
    -- of these lack a getter, so the release could only ever hand back a
    -- GUESS at what the operator had -- the exact thing
    -- client/dispatch.lua:147 forbids. Now they are untouched going in, so
    -- there is nothing to hand back coming out.
    t.isTrue(client.friendlyFire, 'friendly fire stayed OFF after the round that turned it off')
    t.isNil(client.canAttackFriendly, 'the exit path is writing SetCanAttackFriendly')
end)

t.test('and so does the resource going down under them', function()
    local client = newClient()
    client.enter('crimson')
    client.fire('onResourceStop', 'crimson_arena')

    t.equals(client.engineTeam, -1, 'a restart left the arena team on the player')
    t.isTrue(client.friendlyFire, 'a restart left friendly fire OFF')
end)

t.test('a free-for-all never touches either of them, so it has nothing to leave behind', function()
    local client = newClient()
    client.enterMode('ffa', nil)

    t.isNil(client.engineTeam, 'a mode with no sides put the player on one')
    t.isNil(client.friendlyFire, 'a mode with no sides had an opinion about friendly fire')
    t.isNil(client.canAttackFriendly, 'a mode with no sides touched SetCanAttackFriendly')
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

t.test('and the two sides are given DIFFERENT engine numbers, which is what makes an enemy shootable at all', function()
    -- THE REPORT THIS WHOLE FIX CAME FROM WAS "i can't shoot my enemies",
    -- and one number for both sides is the other way to cause it. The
    -- engine judges a bullet between two players by the team index; two
    -- sides sharing one index ARE one side, and the
    -- NetworkSetFriendlyFireOption(false) set alongside it then refuses
    -- every shot in the round -- enemies included.
    --
    -- Arena.TeamIndex is POSITIONAL, over a list an operator edits. This
    -- asserts the property the hold depends on rather than the numbers,
    -- so it still means something after that list is reordered.
    local client = newClient()
    local crimson = client.Arena.TeamIndex('crimson')
    local ash = client.Arena.TeamIndex('ash')

    t.isTrue(crimson ~= nil, 'a configured side has no engine number to be put on')
    t.isTrue(ash ~= nil, 'a configured side has no engine number to be put on')
    t.isTrue(crimson ~= ash, 'both sides of a team round were given the SAME engine number, so nobody can shoot anybody')
    t.isTrue(crimson ~= -1 and ash ~= -1,
        'a side was given the engine default as its number, so every unteamed player in the city is on it too')
end)

t.test('the side the player ARRIVED on is what comes back, not the engine default', function()
    -- EVERY OTHER TEST IN THIS SECTION STARTS FROM -1, which is the engine
    -- default and is also the constant the release would hand back if it
    -- had forgotten what it read. From -1 those two are the same answer and
    -- the release cannot be told from a hardcoded SetPlayerTeam(-1).
    --
    -- A job, gang, whitelist or war script putting its people on a team is
    -- ordinary on a roleplay server, and -1 is emphatically not what those
    -- players had. Left on -1 by the arena, they come out of a round having
    -- quietly resigned from their own faction -- and the one thing this
    -- file exists to prevent is the round changing something about a player
    -- that outlives it.
    local client = newClient()
    client.engineTeam = 7
    client.enter('crimson')

    t.equals(client.engineTeam, client.Arena.TeamIndex('crimson'),
        'the round never put this fighter on their side')

    client.exit()

    t.equals(client.engineTeam, 7,
        'the round handed back the engine default instead of the team this player walked in on')
    t.isTrue(client.friendlyFire, 'and left friendly fire off with it')
end)

t.test('and a second exit does not take it off them again', function()
    -- The exit is not sent once. ArenaMatch.End sends it, ArenaLobby.Destroy
    -- can send another behind it, and onResourceStop runs leaveArena on top
    -- of whatever already happened -- an operator restarting the resource a
    -- moment after a round ends is all it takes. A release that runs twice
    -- has no reading left to hand back the second time, so without its own
    -- guard the second run writes the -1 the first one was careful not to.
    local client = newClient()
    client.engineTeam = 7
    client.enter('crimson')
    client.exit()
    client.exit()
    client.fire('onResourceStop', 'crimson_arena')

    t.equals(client.engineTeam, 7, 'a repeated exit wiped the team the player walked in on')
end)

t.test('and a free-for-all ending does not hand back a side it never took', function()
    -- THE SAME GUARD FROM THE OTHER DIRECTION, and the cheaper one to break.
    -- A mode with no sides writes neither setting going in, so the way out
    -- must write neither either. Without the guard the exit hands back a
    -- reading it never took -- and a player who walked into an FFA on their
    -- faction's team walks out of it on nobody's.
    local client = newClient()
    client.engineTeam = 7
    client.enterMode('ffa', nil)
    client.exit()

    t.equals(client.engineTeam, 7, 'a round that never touched the team wrote one on the way out')
    t.isNil(client.friendlyFire, 'a round that never touched friendly fire had an opinion about it on the way out')
end)

t.test('an eliminated fighter is still held while the round runs, and let go when it ends', function()
    -- BEING KNOCKED OUT IS NOT LEAVING. An eliminated fighter stays in the
    -- match -- they spectate, they are still on the roster, the server still
    -- reads their side off it -- and the server deliberately does NOT send
    -- them an exit at that moment. So the hold must survive it: dropped
    -- there, a dead ally watching from the sidelines is a body their own
    -- side can shoot at, and a respawn in a mode with lives puts them back
    -- in the round with no hold at all.
    --
    -- And it must not survive the round. The exit that does come, when the
    -- match actually ends, is the one that has to put them back.
    local client = newClient()
    client.engineTeam = 7
    client.enter('crimson')
    client.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = true })

    t.equals(client.engineTeam, client.Arena.TeamIndex('crimson'),
        'being knocked out of a live round dropped the side mid-round')
    t.isFalse(client.friendlyFire, 'being knocked out of a live round turned friendly fire back on mid-round')

    client.exit()

    t.equals(client.engineTeam, 7, 'an eliminated fighter was left on the arena team after the round ended')
    t.isTrue(client.friendlyFire, 'an eliminated fighter was left with friendly fire off after the round ended')
end)

os.exit(t.summary())
