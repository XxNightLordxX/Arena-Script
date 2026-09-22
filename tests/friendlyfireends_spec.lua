--[[
    crimson_arena/tests/friendlyfireends_spec.lua

    FRIENDLY FIRE IS THE SERVER'S JOB, AND THE ROUND MUST NOT FOLLOW ANYONE
    HOME.

    THIS FILE ONCE GUARDED A CLIENT-SIDE HOLD. It does not any more, and the
    reason is the most important thing in it.

    WHAT THE HOLD WAS. On entering a team round, client/match.lua called
    SetPlayerTeam(PlayerId(), Arena.TeamIndex(teamKey)) and
    NetworkSetFriendlyFireOption(false), re-asserted both once a second, and
    put them back on every exit. This file proved, in eleven client tests,
    that it did all of that correctly. Ten deliberate mutations of it were
    written and all ten were caught. Every one of those tests was green.

    THE ARENA WAS BROKEN ANYWAY. From a live team deathmatch, in the owner's
    words: "Enemies can't kill each other." That pair of writes was the only
    difference between the arena and the rest of a server where PvP works.

    IT IS THE SECOND TIME THESE NATIVES DID THAT. The first report -- "i can't
    shoot my enemies and they can't shoot me" (0baa2e3) -- was blamed on
    SetCanAttackFriendly alone, and this pair was kept on the strength of one
    sentence: "NetworkSetFriendlyFireOption is team-scoped, the two sides are
    on different engine teams, so it cannot refuse an enemy." Nothing ever
    supported that sentence. The native takes ONE BARE BOOL -- no player
    argument, no team argument -- its description field in the FiveM native
    reference is the EMPTY STRING, and no getter for it exists in any of the
    44 namespaces. Two readings fit the evidence and BOTH produce the reported
    symptom: the option is not team-scoped at all, or SetPlayerTeam does not
    replicate the way the file assumed and every client reads every other as
    one team. Both writes are gone, because removing both fixes it under
    either reading.

    WHY NO AMOUNT OF TESTING HERE COULD HAVE CAUGHT IT, which is the lesson
    worth keeping. Every client fixture in this suite wires GetPlayerTeam
    straight back to the same client's own SetPlayerTeam, so the suite can
    only ever watch this resource agree with itself. It cannot represent a
    second engine, and the failure lived between two engines. A green suite
    was never evidence about these natives and never could have been.

    SO WHAT IS LEFT, AND IT IS IN TWO HALVES.

      * THE SERVER, which is now the only thing that refuses damage at all.
        server/dispatch.lua cancels weaponDamageEvent and explosionEvent by
        asking `active[src]` which round a player is in and reading their side
        off the live roster. Both handlers are WEAPON-AGNOSTIC -- there is no
        weapon hash, type or melee branch anywhere in the file -- so a bottle
        is refused by the identical code that refuses a rifle round, provided
        the engine emits the packet. A flag left raised, or a lobby row left
        lying about, and two people who fought together are still allies in
        the street: that is what the server section below drives, through
        every way a round can end -- End, Abort, an admin stop, the lobby row
        torn down, a fighter disconnecting, the resource stopping mid-round,
        and an ally eliminated before the end. server.sentHome counts the exit
        the client is told by, because the refusal reads ArenaDispatch and
        would go green on a path that never told the client anything.

      * THE CLIENT, where the whole guard is now an absence. It must write
        none of SetPlayerTeam, NetworkSetFriendlyFireOption or
        SetCanAttackFriendly, on any path. Three tests drive the entry, exit,
        restart, respawn and free-for-all paths; a fourth reads the source,
        because the fixture parks partway through entry and a re-added write
        in a branch no test drives would pass the other three.

    WHAT IS GENUINELY LOST, stated rather than glossed. The hold was the only
    claimed cover for two things: the teammate's half of a shotgun spread,
    which the server lets through whole on purpose (crossfire_spec.lua:762),
    and melee, IF melee turns out not to raise weaponDamageEvent. Neither was
    ever measured to be covered by it. Its only measured effect in a live
    round is the one that removed it.

    DO NOT "RESTORE" THE CLIENT TESTS, and do not weaken the server section
    into asserting only that a live round refuses -- that half passes on its
    own.
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

t.test('DYING DOES NOT COST A FIGHTER THEIR SIDE, driven through the REAL death path', function()
    -- IN THE OWNER'S WORDS: "if you die it still saves the team and friendly
    -- fire thingy".
    --
    -- IT FAILS OPEN, WHICH IS WHY IT NEEDS A TEST AT ALL. Arena.CanDamage
    -- returns TRUE -- damage allowed -- as soon as either side's team key is
    -- missing, because an unteamed player in a team mode is nobody's
    -- team-mate. So anything that cleared a row's `team` while they were down
    -- would not start refusing shots, it would STOP refusing them, and the
    -- only sign would be a fighter dying to their own side moments after
    -- respawning.
    --
    -- WHY IT IS HERE AND NOT IN crossfire_spec. That file stubs ArenaLobby.Get
    -- and hands the guard a roster it built itself, so the real
    -- ArenaMatch.OnDeath never runs and mutating it changes nothing there.
    -- Measured: adding `player.team = nil` beside `player.alive = false` in
    -- the real OnDeath passed all 63 of crossfire_spec. This fixture runs the
    -- actual server, so the mutation has somewhere to bite.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = liveRound(server)
    local match = server.lobby.Get(matchId)

    -- 1 and 2 are on crimson, 3 is on ash. Kill 2 for real.
    server.match.OnDeath(2, 3)

    t.equals(match.players[2].team, 'crimson',
        'the death path cleared the dead fighter\'s side -- Arena.CanDamage fails OPEN on a '
        .. 'missing key, so their own team can now finish them')
    t.isTrue(server.shoot(1, { 2 }),
        'a team-mate on the floor is shootable by their own side')
    t.isFalse(server.shoot(3, { 2 }),
        'and the enemy could no longer touch them, so the respawn delay became a shield')

    -- AND THE KILLER KEEPS THEIRS TOO, which is the other half: a shooter
    -- with no side is not refused either.
    t.equals(match.players[3].team, 'ash', 'the death path cleared the KILLER\'s side')
    t.isTrue(server.shoot(2, { 1 }),
        'the dead fighter can now shoot their own team-mate')
end)

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
-- THE CLIENT, WHICH NO LONGER TOUCHES EITHER SETTING
-- ======================================================================

--- The real client/match.lua, driven far enough in to have written whatever
--- it is going to write about friendly fire.
---
--- NOT A WHOLE ROUND. The entry handler goes on to build an arena out of
--- props and yield inside model loads, and none of that is this section's
--- question: the hold used to run BEFORE any of it, so the handler is driven
--- until it parks or falls over and what it wrote -- now, nothing -- is read
--- off after.
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
        joaat = function(name) return name end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        SetCurrentPedWeapon = function() end,
        RemoveAllPedWeapons = function() end,

        -- THE THREE WRITES THIS SECTION IS ABOUT, AND ALL THREE MUST STAY
        -- UNTOUCHED. They are settings on the PLAYER rather than the ped,
        -- they are what the engine judges a bullet between two players
        -- against, and this resource has now been burned by two of them.
        SetPlayerTeam = function(_player, team) c.engineTeam = team end,
        GetPlayerTeam = function() return c.engineTeam or -1 end,
        NetworkSetFriendlyFireOption = function(on) c.friendlyFire = on end,
        SetCanAttackFriendly = function(_ped, can) c.canAttackFriendly = can end,
    })

    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    c.env = env
    c.Arena = env.Arena
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

    --- A round in a mode of the caller's choosing.
    function c.enterMode(modeKey, teamKey)
        c.fire('crimson_arena:client:enterArena', {
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
    end

    function c.enter(teamKey) c.enterMode('tdm', teamKey) end

    --- The round ending under this client, as the server ends it.
    function c.exit()
        c.fire('crimson_arena:client:exitArena',
            { returnCoords = { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } })
    end

    --- Nothing about friendly fire was written, in either direction.
    function c.untouched()
        return c.engineTeam == nil and c.friendlyFire == nil and c.canAttackFriendly == nil
    end

    return c
end

t.test('a team round writes NONE of the three friendly-fire natives', function()
    -- THE ASSERTION THAT USED TO BE HERE WAS THE EXACT OPPOSITE, and a live
    -- round says it was wrong. See this file's header.
    local client = newClient()
    client.enter('crimson')

    t.isNil(client.engineTeam,
        'SetPlayerTeam is being written again -- that write, with the friendly-fire option '
        .. 'beside it, is what stopped enemies killing each other in a live team deathmatch')
    t.isNil(client.friendlyFire,
        'NetworkSetFriendlyFireOption is being written again -- one bare BOOL, an EMPTY '
        .. 'description in the native reference, and no getter anywhere: nothing has ever '
        .. 'shown it doing what this resource claimed, and the one round it was measured '
        .. 'in it broke the arena')
    t.isNil(client.canAttackFriendly,
        'SetCanAttackFriendly is being written again -- the first cause of "i can\'t shoot '
        .. 'my enemies and they can\'t shoot me"')
end)

t.test('and leaving writes none of them either, because there is nothing to put back', function()
    -- A SETTING NEVER WRITTEN IS A SETTING NEVER LEFT BEHIND, and that is now
    -- the whole of this file's client-side promise -- the strongest form of
    -- it, because it needs no exit path to be reached, no ordering to hold,
    -- and no guessed constant to restore. The player walks out of the arena
    -- on exactly the team and exactly the option they walked in on, whatever
    -- those were, because nobody here ever looked.
    local client = newClient()
    client.engineTeam = 7        -- a job, gang or faction script's team
    client.enter('crimson')
    client.exit()
    client.fire('onResourceStop', 'crimson_arena')

    t.equals(client.engineTeam, 7,
        'the arena moved a player off the team another resource had them on')
    t.isNil(client.friendlyFire, 'the exit is writing NetworkSetFriendlyFireOption again')
    t.isNil(client.canAttackFriendly, 'the exit is writing SetCanAttackFriendly again')
end)

t.test('and neither does a free-for-all, a round that ends in a restart, or a respawn', function()
    local ffa = newClient()
    ffa.enterMode('ffa', nil)
    ffa.exit()
    t.isTrue(ffa.untouched(), 'a free-for-all touched one of the three')

    local restarted = newClient()
    restarted.enter('crimson')
    restarted.fire('onResourceStop', 'crimson_arena')
    t.isTrue(restarted.untouched(), 'a restart mid-round touched one of the three')

    local respawned = newClient()
    respawned.enter('crimson')
    respawned.fire('crimson_arena:client:respawn', {
        spawn = { x = 1.0, y = 2.0, z = 3.0, w = 0.0 },
        scatterRadius = 0.0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
    t.isTrue(respawned.untouched(), 'a respawn touched one of the three')
end)

--- Blanks out every LONG comment, keeping the newlines so line numbers hold.
---
--- THE NAME-ONLY RULE ABOVE MADE THIS NECESSARY. Skipping lines that begin
--- with `--` handles single-line comments, and that was enough while the rule
--- demanded a bracket after the name. It is not enough now: a `--[[ ]]` block
--- explaining why these natives are gone would have its CONTINUATION lines
--- read as code, and every mention of a name in it reported as a call.
--- MEASURED -- appending this to a client file failed the guard:
---
---     --[[
---         A note about SetCanAttackFriendly and why it is gone.
---     ]]
---
--- A guard that cries wolf at the documentation is a guard the next person
--- deletes. Handles the `--[=*[` forms too, and an unterminated block runs to
--- the end of the file, which is what Lua does.
--- @param text string
--- @return string
local function blankLongComments(text)
    local out, i = {}, 1
    while true do
        local open, openEnd, eq = text:find('%-%-%[(=*)%[', i)
        if not open then
            out[#out + 1] = text:sub(i)
            break
        end

        out[#out + 1] = text:sub(i, open - 1)

        local close = ']' .. eq .. ']'
        local closeAt = text:find(close, openEnd + 1, true)
        local body = closeAt and text:sub(open, closeAt + #close - 1) or text:sub(open)

        -- ONLY THE NEWLINES SURVIVE, so every line below keeps its number.
        out[#out + 1] = (body:gsub('[^\n]', ''))

        if not closeAt then break end
        i = closeAt + #close
    end
    return table.concat(out)
end

--- The four names no client file may mention outside a comment.
local BANNED_NAMES = {
    'SetPlayerTeam', 'GetPlayerTeam',
    'NetworkSetFriendlyFireOption', 'SetCanAttackFriendly',
}

--- The same four natives BY HASH, which a name check cannot see.
---
--- Taken from the native reference, not from memory:
---   SET_PLAYER_TEAM                   0x0299FA38396A4940  (PLAYER)
---   GET_PLAYER_TEAM                   0x37039302F4E0A008  (PLAYER)
---   SET_CAN_ATTACK_FRIENDLY           0xB3B1CB349FF9C75D  (PED)
---   NETWORK_SET_FRIENDLY_FIRE_OPTION  0xF808475FA571D823  (NETWORK)
local BANNED_HASHES = {
    SET_PLAYER_TEAM = '0X0299FA38396A4940',
    GET_PLAYER_TEAM = '0X37039302F4E0A008',
    SET_CAN_ATTACK_FRIENDLY = '0XB3B1CB349FF9C75D',
    NETWORK_SET_FRIENDLY_FIRE_OPTION = '0XF808475FA571D823',
}

t.test('THE GUARD THAT CANNOT BE SATISFIED BY LUCK: the source calls none of them', function()
    -- EVERY TEST ABOVE DRIVES ONE ENTRY PATH. This reads the file.
    --
    -- The three assertions above can only see the paths the fixture reaches,
    -- and the entry handler parks partway through on a native this fixture
    -- does not carry -- so a re-added write further down, in a branch no test
    -- drives, would pass all of them. This one cannot be fooled that way:
    -- there must be no CALL to any of the three anywhere in the file.
    --
    -- Comments are allowed and deliberately so -- the epitaph in
    -- client/match.lua names all three while explaining why they are gone --
    -- so this strips comment lines before looking.
    -- EVERY CLIENT FILE, AND IT USED TO READ ONE.
    --
    -- This opened client/match.lua alone -- because that is where the writes
    -- were -- and the guarantee it is named for is about the CLIENT, not
    -- about one file of it. The banned pair could go back into
    -- client/main.lua, client/spectate.lua or client/dispatch.lua and every
    -- spec in this suite would stay green. Measured, not assumed.
    --
    -- THE LIST COMES OUT OF fxmanifest.lua, so a client file added tomorrow
    -- is covered the day it is added rather than the day somebody remembers
    -- this test exists.
    local manifest = assert(io.open('../Crimson-Arena/fxmanifest.lua', 'r'))
    local manifestText = manifest:read('a')
    manifest:close()

    local block = manifestText:match('client_scripts%s*{(.-)}')
    t.isNotNil(block, 'fxmanifest.lua no longer has a client_scripts block this test can read')

    -- '@other_resource/file.lua' IS NOT THIS RESOURCE'S CODE. The manifest
    -- pulls qbx_core's playerdata into the client realm; it is not ours to
    -- police and it is not on our disk.
    local files = {}
    for name in block:gmatch("'([^']+%.lua)'") do
        if not name:match('^@') then files[#files + 1] = name end
    end
    t.isTrue(#files >= 5,
        ('only %d client file(s) were parsed out of fxmanifest.lua -- the parse has come '
            .. 'unstuck from the manifest and this test is now guarding almost nothing')
            :format(#files))

    local offenders = {}
    for _, name in ipairs(files) do
        local handle = assert(io.open('../Crimson-Arena/' .. name, 'r'),
            name .. ' is in the manifest and not on disk')
        local text = blankLongComments(handle:read('a'))
        handle:close()

        local n = 0
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local bare = line:gsub('^%s+', '')
            if not bare:match('^%-%-') then
                -- THE NAME ANYWHERE, NOT THE NAME FOLLOWED BY A BRACKET.
                --
                -- This looked for `Name%s*%(`, which is one of several ways
                -- to reach a native and the only one it caught. MEASURED --
                -- each of these was appended to client/main.lua in a copy and
                -- the whole suite stayed green:
                --
                --   local ff = SetCanAttackFriendly; ff(ped, true, true)
                --   _G['SetCanAttackFriendly'](ped, true, true)
                --
                -- A bare mention of one of these names outside a comment is
                -- a call, an alias or a string used to make one, and this
                -- resource has no reason to write any of the three. Verified:
                -- no client file mentions any of them outside a comment
                -- today, so this cannot fire on the epitaph that names all
                -- four.
                for _, native in ipairs(BANNED_NAMES) do
                    if bare:find(native, 1, true) then
                        offenders[#offenders + 1] = ('%s at %s:%d'):format(native, name, n)
                    end
                end

                -- AND THE HASHES, which no name check can ever see.
                --
                -- Citizen.InvokeNative(0xB3B1CB349FF9C75D, ...) is the
                -- ordinary way to call a native with no Lua wrapper, and it
                -- reaches SET_CAN_ATTACK_FRIENDLY without writing a letter of
                -- its name. Both hashes were appended to a client file in a
                -- copy and the whole suite stayed green. A guard named for not
                -- being satisfiable by luck has to read these too.
                for label, hash in pairs(BANNED_HASHES) do
                    if bare:upper():find(hash, 1, true) then
                        offenders[#offenders + 1] = ('%s (%s) at %s:%d'):format(label, hash, name, n)
                    end
                end
            end
        end
    end

    t.equals(#offenders, 0,
        'a client file is calling a friendly-fire native again (' .. table.concat(offenders, ', ')
        .. '). Two of these have each already caused the report "enemies cannot kill each other" '
        .. 'in a live round. Read the epitaph in client/match.lua before putting any of them back.')
end)

os.exit(t.summary())
