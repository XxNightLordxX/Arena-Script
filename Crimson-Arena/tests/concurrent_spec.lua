--[[
    crimson_arena/tests/concurrent_spec.lua

    TWO MATCHES AT ONCE, IN THE SAME PLACE.

    An arena in the sky is one platform at one set of coordinates, and the
    obvious worry is what happens when two matches want it at the same time:
    do the fighters see each other, shoot each other, land on each other?

    They do not, and the reason is that a match is not a PLACE -- it is a
    routing bucket. Every match is fought in its own instance of the world, so
    two matches at identical coordinates are as separate as two matches on
    opposite sides of the map. Nothing has to be moved, numbered, duplicated
    or torn down between them, and the same one arena serves as many
    simultaneous matches as the server has players for.

    That is a strong claim resting on one module, so this file tests it
    against the REAL server/dispatch.lua and the real routing natives rather
    than a double that agrees with it: two matches on THE SAME ARENA, both
    live at once, and then everything that could leak between them.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('concurrent_spec')

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
    local netEvents, console = {}, {}
    -- Who has actually been teleported into the arena, which is a different
    -- question to what the match calls its own state.
    local bucketOf = {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        -- CALLABLE, because server/dispatch.lua registers this resource's own
        -- exports with `exports('name', fn)` at load. A plain table raises
        -- there and takes the whole module down with it.
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
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
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        -- RECORDING, because playersArePlaced is exactly what decides whether
        -- a start may still be held, and it asks this double. A stub that
        -- always says "nobody is in the arena" would let the guard pass every
        -- test while never being exercised once.
        -- THE REAL ROUTING NATIVES, recorded. The whole question this file
        -- asks is which instance of the world each fighter is standing in,
        -- so the one module that answers it is the real one.
        -- The state bag server/dispatch.lua raises the arena flag on. Not
        -- what this file is about, but a nil call here takes the module down.
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return bucketOf[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) bucketOf[src] = bucket end,
        SetRoutingBucketEntityLockdownMode = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    -- dispatch BEFORE the rest: lobby and match call ArenaDispatch at load
    -- time to decide what they can do.
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, lobby = env.ArenaLobby,
        match = env.ArenaMatch, dispatch = env.ArenaDispatch }

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

    --- Which instance of the world one player is standing in.
    function server.bucket(src) return bucketOf[src] or 0 end

    --- Every player currently in some arena instance.
    function server.instanced()
        local out = {}
        for src, bucket in pairs(bucketOf) do
            if bucket ~= 0 then out[src] = bucket end
        end
        return out
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    return server
end



--- Opens a match on `arenaKey` with `ids` in it and starts it.
--- @return string matchId
local function runMatch(server, arenaKey, ids)
    server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })

    -- The newest match, since earlier ones are still open.
    local match
    for _, entry in ipairs(server.lobby.All()) do
        if entry.hostSource == ids[1] then match = entry end
    end
    t.isNotNil(match, ('player %d could not open a lobby'):format(ids[1]))

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
        t.isNotNil(match.players[ids[index]], ('player %d could not join'):format(ids[index]))
    end

    server.fire('startMatch', ids[1])
    server.step(6)
    return match.id
end

--- Four players, enough for two matches of two.
--- @param extra number[]? -- ids of bystanders, in nothing, who are on the
---        server while the matches run
local function fourPlayers(extra)
    local roster = {
        [1] = { cash = 50000, bank = 50000 },
        [2] = { cash = 50000, bank = 50000 },
        [3] = { cash = 50000, bank = 50000 },
        [4] = { cash = 50000, bank = 50000 },
    }
    for _, src in ipairs(extra or {}) do
        roster[src] = { cash = 50000, bank = 50000 }
    end
    return newServer(roster, function(config)
        config.Match.minPlayers = 2
        config.Match.lobbyCountdownSeconds = 0
        config.Match.maxConcurrentMatches = 0
    end)
end

-- ======================================================================
-- THE SAME ARENA, TWICE, AT ONCE
-- ======================================================================

t.test('two matches can be fought in the SAME arena at the same time', function()
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })

    t.isNotNil(server.lobby.Get(first), 'the first match did not survive the second being opened')
    t.isNotNil(server.lobby.Get(second), 'the second match could not be opened in an arena already in use')
    t.equals(server.lobby.Get(first).state, 'live')
    t.equals(server.lobby.Get(second).state, 'live')
    t.equals(server.lobby.Get(first).arenaKey, server.lobby.Get(second).arenaKey,
        'the two matches are not actually in the same arena, so this proves nothing')
end)

t.test('and their fighters stand in DIFFERENT instances of the world', function()
    -- The whole mechanism. Same coordinates, different buckets: they cannot
    -- see, shoot or collide with each other.
    local server = fourPlayers()
    runMatch(server, 'airfield', { 1, 2 })
    runMatch(server, 'airfield', { 3, 4 })

    local a, b = server.bucket(1), server.bucket(3)
    t.isTrue(a ~= 0, 'the first match fights in the open world, where everybody can see it')
    t.isTrue(b ~= 0, 'the second match fights in the open world')
    t.isTrue(a ~= b, ('BOTH MATCHES ARE IN INSTANCE %d -- they are fighting each other'):format(a))

    -- And teammates within one match share theirs, or they cannot fight.
    t.equals(server.bucket(2), a, 'two fighters in the SAME match were split into different instances')
    t.equals(server.bucket(4), b)
end)

t.test('AND SO DO TWO MATCHES IN AN ARENA ON THE REAL MAP', function()
    -- Asked for from the game: "make the trailer park act like a separate
    -- map also". It already does, and this is what makes that an answer
    -- rather than a claim.
    --
    -- Instancing is a property of the MATCH, not of the arena -- the bucket
    -- is allocated against a match id and nothing in that path asks which
    -- arena is being fought in. So an arena standing on the real map is
    -- separated exactly as hard as the one built over open water: the
    -- fighters cannot see each other, and neither can anybody standing in
    -- the trailer park in the ordinary world.
    --
    -- What is NOT hidden, and cannot be, is the map itself. The trailers,
    -- the fences and the vehicles are in every instance because they are the
    -- world; only the people are separated. That is the difference between
    -- the two arenas, and it is the whole reason the sky one builds its own
    -- floor.
    local server = fourPlayers()
    local first = runMatch(server, 'trailerpark', { 1, 2 })
    local second = runMatch(server, 'trailerpark', { 3, 4 })

    t.isNotNil(server.lobby.Get(first), 'the first match on real ground did not survive the second')
    t.isNotNil(server.lobby.Get(second), 'a second match was refused an arena on the real map')

    local a, b = server.bucket(1), server.bucket(3)
    t.isTrue(a ~= 0, 'a match in the trailer park is fought in the open world')
    t.isTrue(b ~= 0, 'the second trailer park match is fought in the open world')
    t.isTrue(a ~= b,
        ('BOTH TRAILER PARK MATCHES ARE IN INSTANCE %d -- they are standing on each other'):format(a))
    t.equals(server.bucket(2), a, 'teammates in one trailer park match were split apart')
    t.equals(server.bucket(4), b)
end)

--- How many keep-out circles the server would hand this player.
--- @param server table
--- @param src number
--- @return table[]
local function fencesFor(server, src)
    local state = server.lobby.BuildState(src)
    return (type(state) == 'table' and type(state.keepOut) == 'table') and state.keepOut or {}
end

t.test('DEFECT: neither group is fenced out of the ground they are fighting on', function()
    -- REPORTED FROM THE GAME as matches interfering with each other.
    --
    -- The keep-out fence is drawn round an ARENA and the exemption used to be
    -- per MATCH, so the two disagreed the moment a second round started on
    -- the same ground. For each fighter of the first match the second match
    -- is live and they are not in it -- so they were handed a circle centred
    -- on the arena they were standing and fighting in, and the client's
    -- barrier loop teleports anyone inside a zone to its radius plus the
    -- push, four times a second. Both groups, at once, each shoved out of
    -- the other's fence.
    local server = fourPlayers()
    runMatch(server, 'trailerpark', { 1, 2 })
    runMatch(server, 'trailerpark', { 3, 4 })

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        local fences = fencesFor(server, src)
        t.equals(#fences, 0,
            ('fighter %d was fenced out of their own arena by %d zone(s)'):format(src, #fences))
    end
end)

t.test('and the same holds at the arena that is a kilometre up', function()
    -- Worse there than anywhere. The skydome's boundary is 110m and the push
    -- is 6, so a fighter inside the fence is teleported to 116m from the
    -- middle -- which is off the edge of a platform that reaches 90, into a
    -- kilometre of air.
    local server = fourPlayers()
    runMatch(server, 'skydome', { 1, 2 })
    runMatch(server, 'skydome', { 3, 4 })

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        t.equals(#fencesFor(server, src), 0,
            ('fighter %d was pushed off the skydome by their own arena'):format(src))
    end
end)

t.test('but somebody with no business there is still kept out, exactly once', function()
    -- The other direction, and the reason this cannot be fixed by simply not
    -- sending zones. Player 5 is in neither match: the fence is the only
    -- thing keeping them out of a live round on real ground.
    --
    -- ONCE, not once per match. Two live matches on one arena used to send
    -- two identical circles, which the client then tested against twice a
    -- tick for no different answer.
    local server = fourPlayers({ 5 })
    runMatch(server, 'trailerpark', { 1, 2 })
    runMatch(server, 'trailerpark', { 3, 4 })

    local fences = fencesFor(server, 5)
    t.equals(#fences, 1,
        ('an outsider got %d zone(s) for one arena'):format(#fences))
    t.isTrue(fences[1].radius > 0, 'the zone has no radius, so it fences nothing')
end)

t.test('every fighter is in exactly one instance, and it is their own match\'s', function()
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })

    local instanced = server.instanced()
    t.equals(server.bucket(1), server.bucket(2))
    t.equals(server.bucket(3), server.bucket(4))

    local count = 0
    for _ in pairs(instanced) do count = count + 1 end
    t.equals(count, 4, 'somebody who is fighting was left in the open world')
    t.isTrue(first ~= second)
end)

-- ======================================================================
-- WHAT MUST NOT LEAK BETWEEN THEM
-- ======================================================================

t.test('a death in one match is not a death in the other', function()
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })

    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.step(2)

    local other = server.lobby.Get(second)
    t.isNotNil(other, 'a death in one match tore the other one down')
    for src, entry in pairs(other.players) do
        t.isTrue(entry.alive, ('player %d in the OTHER match was killed by it'):format(src))
    end
    t.isNotNil(first)
end)

t.test('and a kill is credited in the match it happened in, to nobody else', function()
    local server = fourPlayers()
    runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })

    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.step(2)

    for src, entry in pairs(server.lobby.Get(second).players) do
        t.equals(entry.kills or 0, 0, ('player %d was credited a kill from another match'):format(src))
        t.equals(entry.deaths or 0, 0, ('player %d was charged a death from another match'):format(src))
    end
end)

t.test('a fighter cannot be claimed as a killer from a match they are not in', function()
    -- The report is a hint from the victim's client, so it names a killer by
    -- server id -- and an id from another match is exactly the shape of a
    -- crafted one.
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    runMatch(server, 'airfield', { 3, 4 })

    -- Player 2 dies and blames player 3, who is fighting somewhere else.
    server.fire('reportDeath', 2, { killerServerId = 3 })
    server.step(2)

    t.equals(server.lobby.Get(first).players[3], nil, 'somebody joined a match they were never in')
    for _, entry in pairs(server.lobby.All()) do
        for src, player in pairs(entry.players) do
            if src == 3 then
                t.equals(player.kills or 0, 0, 'a fighter was credited a kill in another match entirely')
            end
        end
    end
end)

t.test('ending one match leaves the other running, and its fighters where they are', function()
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })
    local held = server.bucket(3)

    server.match.End(first, 'match.ended')
    server.step(4)

    t.isNil(server.lobby.Get(first), 'the ended match was not torn down')
    t.isNotNil(server.lobby.Get(second), 'ending one match ended the other')
    t.equals(server.lobby.Get(second).state, 'live')
    t.equals(server.bucket(3), held,
        'a fighter in the OTHER match was moved out of their instance when this one ended')
    t.equals(server.bucket(4), held)
end)

t.test('and the finished match hands its instance back to the world', function()
    -- Or a server that has run for a week is carrying a bucket per match it
    -- has ever held.
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })

    server.match.End(first, 'match.ended')
    server.step(4)

    t.equals(server.bucket(1), 0, 'a fighter was left in an instance nobody else is in')
    t.equals(server.bucket(2), 0)
end)

t.test('a third match opens into an instance of its own', function()
    -- Two is the case that breaks; three is the one that proves the rule is
    -- not "the second one gets a special number".
    local server = newServer({
        [1] = { cash = 50000, bank = 50000 }, [2] = { cash = 50000, bank = 50000 },
        [3] = { cash = 50000, bank = 50000 }, [4] = { cash = 50000, bank = 50000 },
        [5] = { cash = 50000, bank = 50000 }, [6] = { cash = 50000, bank = 50000 },
    }, function(config)
        config.Match.minPlayers = 2
        config.Match.lobbyCountdownSeconds = 0
        config.Match.maxConcurrentMatches = 0
    end)

    runMatch(server, 'airfield', { 1, 2 })
    runMatch(server, 'airfield', { 3, 4 })
    runMatch(server, 'airfield', { 5, 6 })

    local seen = {}
    for _, src in ipairs({ 1, 3, 5 }) do
        local bucket = server.bucket(src)
        t.isTrue(bucket ~= 0, ('match hosted by %d is in the open world'):format(src))
        t.isNil(seen[bucket], ('two of three matches share instance %d'):format(bucket))
        seen[bucket] = true
    end
end)

-- ======================================================================
-- AND WHAT HAPPENS IF THE INSTANCING IS NOT THERE
-- ======================================================================

t.test('with instancing OFF, a second match is refused the arena in use', function()
    -- The whole arrangement above rests on one assumption: that each match
    -- really is in its own instance. With Config.Dispatch.isolation switched
    -- off -- or on a build where the routing natives do nothing -- that
    -- separation is simply absent, and two matches in one arena becomes two
    -- groups of armed strangers dropped on top of each other, on ground
    -- sized for one round.
    --
    -- So the sharing is allowed only while the thing that makes it safe is
    -- in force. Asked of ArenaDispatch rather than of the config, because
    -- the config is what an operator INTENDED.
    local server = newServer({
        [1] = { cash = 50000, bank = 50000 }, [2] = { cash = 50000, bank = 50000 },
        [3] = { cash = 50000, bank = 50000 }, [4] = { cash = 50000, bank = 50000 },
    }, function(config)
        config.Match.minPlayers = 2
        config.Match.lobbyCountdownSeconds = 0
        config.Match.maxConcurrentMatches = 0
        config.Dispatch.isolation.enabled = false
    end)

    runMatch(server, 'airfield', { 1, 2 })
    t.isNil(server.dispatch.GetBucket('anything'), 'isolation is still on, so this proves nothing')

    -- The second lobby opens -- that is not what is refused -- but it cannot
    -- be STARTED into ground somebody is already fighting on.
    server.fire('createMatch', 3, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
    local second
    for _, entry in ipairs(server.lobby.All()) do
        if entry.hostSource == 3 then second = entry end
    end
    t.isNotNil(second, 'the second lobby could not even be opened')
    server.fire('joinMatch', 4, { matchId = second.id })

    server.fire('startMatch', 3)
    server.step(4)

    t.equals(server.lobby.Get(second.id).state, 'lobby',
        'TWO MATCHES WERE STARTED ON THE SAME GROUND with nothing keeping them apart')
    t.isTrue(server.log():find('MATCH REFUSED', 1, true) ~= nil,
        'and nothing in the console says why the round would not start')
end)

t.test('but a DIFFERENT arena is still fine with instancing off', function()
    -- The guard is about sharing ground, not about running two matches. Two
    -- arenas are two places, instanced or not.
    local server = newServer({
        [1] = { cash = 50000, bank = 50000 }, [2] = { cash = 50000, bank = 50000 },
        [3] = { cash = 50000, bank = 50000 }, [4] = { cash = 50000, bank = 50000 },
    }, function(config)
        config.Match.minPlayers = 2
        config.Match.lobbyCountdownSeconds = 0
        config.Match.maxConcurrentMatches = 0
        config.Dispatch.isolation.enabled = false
    end)

    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'beach', { 3, 4 })

    t.equals(server.lobby.Get(first).state, 'live')
    t.equals(server.lobby.Get(second).state, 'live',
        'a match on its own separate ground was refused')
end)

t.test('and with instancing ON the same arena is shared, as designed', function()
    -- The other side of the guard: it must not cost the feature it protects.
    local server = fourPlayers()
    local first = runMatch(server, 'airfield', { 1, 2 })
    local second = runMatch(server, 'airfield', { 3, 4 })

    t.equals(server.lobby.Get(first).state, 'live')
    t.equals(server.lobby.Get(second).state, 'live',
        'the fallback is refusing the very thing routing buckets make safe')
end)

os.exit(t.summary())
