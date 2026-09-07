--[[
    crimson_arena/tests/interleave_spec.lua

    PRODUCTION SET 3 -- MANY MATCHES AT ONCE, IN A RANDOM ORDER.

    tests/concurrent_spec.lua already proves two matches at the same
    coordinates cannot see each other, and tests/isolation_spec.lua proves a
    routing bucket is never left set. Both drive a scenario somebody chose.

    This file runs FOUR matches at once and interleaves their events at
    random -- a join here, a kill there, a host cancelling a third while the
    fourth is being bet on -- and asserts the invariants that must hold no
    matter what order things happen in. That is the shape of a live server at
    peak and the one no hand-written scenario reaches.

      SEEDED, so a failure reproduces and can be bisected.

      THE INVARIANTS, checked after EVERY step rather than at the end -- a
      violation that heals itself before the sweep finishes is still a
      violation, and it is the one a player would have been standing in:

        ONE MATCH PER PLAYER.  playerIndex and match.players must agree, in
                               both directions, for everybody.

        NO DANGLING INDEX.     Nothing may point at a match that has been
                               destroyed.

        BUCKETS ARE PRIVATE.   Two live matches may never share a routing
                               bucket, and a player's bucket must be the
                               bucket of the match they are actually in.

        NOBODY IS IN TWO ROOMS. A fighter in match A must not also be
                               registered as a spectator of match B.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('interleave_spec')

local IDS = { 1, 2, 3, 4, 5, 6, 7, 8 }

--- One server, with the routing buckets modelled rather than stubbed: the
--- whole point of this file is what happens to them under load.
local function newServer()
    local players = {}
    for _, id in ipairs(IDS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}
    local buckets, inArena = {}, {}
    local clock = 0

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
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        GetResourceState = function() return 'missing' end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            -- TWO VALUES, because ArenaAmmo.SwapWeapon answers with a
            -- reason and the caller acts on it: a bare `false` reads as
            -- 'no-inventory' -- carry on, there are no items here -- and
            -- this double means the other one, 'refused'. Neither spec
            -- runs a ladder, so the stub decided nothing either way; it
            -- said the opposite of what it was written to say.
            SwapWeapon = function() return false, 'no-inventory' end,
        },
        -- MODELLED, not stubbed. A bucket left set is the defect this file
        -- exists for, so the fixture has to remember who is in which.
        ArenaDispatch = {
            Set = function(src) inArena[src] = true end,
            Clear = function(src) inArena[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return inArena[src] == true end,
            ClearDownState = function() return 0 end,
            EnterBucket = function(src, matchId) buckets[src] = matchId end,
            ExitBucket = function(src) buckets[src] = nil end,
            GetBucket = function(src) return buckets[src] end,
            ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Match.lives = 2
    env.Config.Match.maxConcurrentMatches = 0     -- unlimited, so four can run
    env.Config.Betting.enabled = true
    env.Config.Betting.entryFee.enabled = true

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, buckets = buckets, inArena = inArena,
        lobby = env.ArenaLobby, match = env.ArenaMatch }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then return false end
        env.source = src
        return (pcall(handler, data))
    end

    function server.drop(src)
        env.source = src
        if handlers['playerDropped'] then pcall(handlers['playerDropped']) end
    end

    function server.step() pcall(threads.step) end
    function server.log() return table.concat(console, '\n') end

    return server
end

--- Deterministic generator, independent of the interpreter's own.
local function rng(seed)
    local state = seed
    return function(n)
        state = (1103515245 * state + 12345) % 2147483648
        return (state % n) + 1
    end
end

--- Every invariant, checked at once. Returns a list of complaints, empty
--- when the world is consistent.
--- @return string[]
local function violations(server)
    local bad = {}
    local live = {}
    for _, match in ipairs(server.lobby.All()) do live[match.id] = match end

    -- ONE MATCH PER PLAYER, and the two records must agree in both
    -- directions: a roster row with no index is a player nothing can find,
    -- and an index with no row is a player who cannot leave.
    local seen = {}
    for id, match in pairs(live) do
        for src in pairs(match.players) do
            if seen[src] then
                bad[#bad + 1] = ('player %d is in matches %s and %s'):format(src, seen[src], id)
            end
            seen[src] = id
        end
    end

    for _, src in ipairs(IDS) do
        local found = server.lobby.GetByPlayer(src)
        if found and not live[found.id] then
            bad[#bad + 1] = ('player %d is indexed to destroyed match %s'):format(src, found.id)
        end
        if found and seen[src] ~= found.id then
            bad[#bad + 1] = ('player %d: index says %s, roster says %s')
                :format(src, found.id, tostring(seen[src]))
        end
        if not found and seen[src] then
            bad[#bad + 1] = ('player %d is on match %s roster but indexed to nothing')
                :format(src, seen[src])
        end
    end

    -- BUCKETS ARE PRIVATE, and belong to the match the player is in.
    for _, src in ipairs(IDS) do
        local bucket = server.buckets[src]
        if bucket then
            if not live[bucket] then
                bad[#bad + 1] = ('player %d is in the bucket of destroyed match %s'):format(src, bucket)
            else
                local match = server.lobby.GetByPlayer(src)
                local watching = live[bucket] and live[bucket].spectators[src]
                if not watching and (not match or match.id ~= bucket) then
                    bad[#bad + 1] = ('player %d is in bucket %s but belongs to %s')
                        :format(src, bucket, match and match.id or 'no match')
                end
            end
        end
    end

    -- NOBODY IS IN TWO ROOMS.
    for id, match in pairs(live) do
        for src in pairs(match.spectators or {}) do
            local fighting = seen[src]
            if fighting and fighting ~= id then
                bad[#bad + 1] = ('player %d fights in %s and watches %s'):format(src, fighting, id)
            end
        end
    end

    return bad
end

--- Four matches, interleaved at random, checked after every step.
--- @return string[] complaints
local function interleave(server, seed, steps)
    local pick = rng(seed)
    local complaints = {}

    for step = 1, steps do
        local who = IDS[pick(#IDS)]
        local all = server.lobby.All()
        local target = all[pick(math.max(1, #all))]
        local matchId = target and target.id or nil
        local action = pick(11)

        if action == 1 and #all < 4 then
            server.fire('createMatch', who, {
                arenaKey = 'trailerpark', modeKey = 'ffa',
                entryFee = ({ 0, 500 })[pick(2)], account = 'cash',
            })
        elseif action == 2 and matchId then
            server.fire('joinMatch', who, { matchId = matchId, account = 'cash' })
        elseif action == 3 then
            server.fire('setReady', who, { ready = pick(2) == 1 })
        elseif action == 4 and matchId then
            server.fire('startMatch', who, {})
        elseif action == 5 then
            server.fire('leaveMatch', who, {})
        elseif action == 6 then
            server.drop(who)
        elseif action == 7 and matchId then
            server.fire('spectateMatch', who, { matchId = matchId })
        elseif action == 8 then
            server.fire('stopSpectating', who, {})
        elseif action == 9 and matchId then
            local live = server.lobby.Get(matchId)
            local victim = IDS[pick(#IDS)]
            if live and live.players[victim] then
                live.players[victim].alive = true
                pcall(server.match.OnDeath, victim, IDS[pick(#IDS)])
            end
        elseif action == 10 then
            server.fire('cancelMatch', who, {})
        else
            server.step()
        end

        for _, complaint in ipairs(violations(server)) do
            complaints[#complaints + 1] = ('seed %d step %d: %s'):format(seed, step, complaint)
        end
        if #complaints > 0 then return complaints end
    end

    return complaints
end

local SEEDS = { 3, 11, 29, 64, 128, 501, 997, 2048, 7777, 40320,
                17, 23, 91, 314, 555, 1618, 2718, 31415, 88888, 123457 }

-- ======================================================================
-- THE INVARIANTS
-- ======================================================================

t.test('the interleaving really opens several matches at once', function()
    -- The guard. If every action were refused, or only one match ever
    -- opened, the invariants below would hold trivially.
    local server = newServer()
    local mostSeen = 0
    local pick = rng(64)
    for _ = 1, 200 do
        local who = IDS[pick(#IDS)]
        if pick(3) == 1 then
            server.fire('createMatch', who, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        else
            local all = server.lobby.All()
            local target = all[pick(math.max(1, #all))]
            if target then server.fire('joinMatch', who, { matchId = target.id }) end
        end
        mostSeen = math.max(mostSeen, #server.lobby.All())
    end
    t.isTrue(mostSeen >= 2,
        ('only %d match(es) were ever open at once -- this file proves nothing about concurrency')
            :format(mostSeen))
end)

t.test('and the invariant checker can actually SEE a violation', function()
    -- The other guard, and the more important one. Four sweeps reporting a
    -- clean world is worthless if the checker is blind -- and a checker that
    -- reads the wrong table, or asks a question the fixture cannot answer,
    -- is blind in exactly the way that looks like success.
    --
    -- So each invariant is broken by hand here and the complaint is
    -- required. This is the test that makes the sweep below mean something.
    local server = newServer()
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    server.fire('joinMatch', 2, { matchId = server.lobby.All()[1].id })
    t.equals(#violations(server), 0, 'an honest world was already reported as broken')

    local first = server.lobby.All()[1]
    server.fire('createMatch', 3, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second
    for _, match in ipairs(server.lobby.All()) do
        if match.id ~= first.id then second = match end
    end
    t.isNotNil(second, 'a second match could not be opened for the self-test')

    second.players[2] = first.players[2]
    t.isTrue(#violations(server) > 0, 'a player on two rosters was not noticed')
    second.players[2] = nil

    server.buckets[2] = second.id
    t.isTrue(#violations(server) > 0, 'a player in the wrong bucket was not noticed')
    server.buckets[2] = nil

    second.spectators[2] = true
    t.isTrue(#violations(server) > 0, 'a fighter watching another match was not noticed')
    second.spectators[2] = nil

    server.buckets[2] = 'a-match-that-never-existed'
    t.isTrue(#violations(server) > 0, 'a bucket pointing at nothing was not noticed')
    server.buckets[2] = nil

    t.equals(#violations(server), 0, 'the self-test left the world broken')
end)

t.test('no interleaving of four concurrent matches breaks an invariant', function()
    local broken = {}
    for _, seed in ipairs(SEEDS) do
        local server = newServer()
        for _, complaint in ipairs(interleave(server, seed, 150)) do
            broken[#broken + 1] = complaint
        end
    end
    t.equals(#broken, 0, ('%d invariant violation(s):\n  %s')
        :format(#broken, table.concat(broken, '\n  ', 1, math.min(#broken, 10))))
end)

t.test('and nothing in any of it ever raised', function()
    local raised = {}
    for _, seed in ipairs({ 3, 128, 7777 }) do
        local server = newServer()
        local ok, err = pcall(interleave, server, seed, 250)
        if not ok then raised[#raised + 1] = ('seed %d: %s'):format(seed, tostring(err)) end
    end
    t.equals(#raised, 0, table.concat(raised, '\n'))
end)

t.test('and every routing bucket is given back when the matches end', function()
    -- The one that matters after the storm: a bucket left set is a player
    -- alone in an invisible copy of the map with no way out.
    local stuck = {}
    for _, seed in ipairs(SEEDS) do
        local server = newServer()
        interleave(server, seed, 150)

        for _, match in ipairs(server.lobby.All()) do
            pcall(server.match.Abort, match.id, 'match.ended_abandoned')
            pcall(server.lobby.Destroy, match.id, 'notify.match_closed')
        end
        for _ = 1, 4 do server.step() end

        for _, src in ipairs(IDS) do
            if server.buckets[src] then
                stuck[#stuck + 1] = ('seed %d: player %d left in bucket %s')
                    :format(seed, src, tostring(server.buckets[src]))
            end
            if server.inArena[src] then
                stuck[#stuck + 1] = ('seed %d: player %d left flagged as in an arena'):format(seed, src)
            end
        end
    end
    t.equals(#stuck, 0, ('%d player(s) stranded:\n  %s')
        :format(#stuck, table.concat(stuck, '\n  ', 1, math.min(#stuck, 10))))
end)

os.exit(t.summary())
