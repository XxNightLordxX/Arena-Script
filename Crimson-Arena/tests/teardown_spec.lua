--[[
    crimson_arena/tests/teardown_spec.lua

    PRODUCTION SET 4 -- THE RESOURCE STOPS AT THE WORST POSSIBLE MOMENT.

    Restarts happen. An operator pushes a config change, a watchdog bounces a
    hung resource, a deploy script runs `ensure` across the server. It never
    waits for a convenient moment, and the inconvenient ones are exactly the
    states this resource holds real things in: money in escrow, players in
    routing buckets, inventories in stashes, dispatch flags raised on
    somebody's police alerts.

    Every other spec here stops the resource from ONE state -- usually a
    clean lobby. This file stops it from NINE, walking the whole lifecycle,
    and asserts the same five things every time.

      NOTHING IS OWED.      Every wallet comes back to where it started, with
                            escrow empty and nothing on the undeliverable
                            ledger. A stake held by a resource that is no
                            longer running is money nobody can get out again.

      NOBODY IS INSTANCED.  A routing bucket left set is a player alone in an
                            invisible copy of the map. The resource that put
                            them there has stopped, so nothing will ever take
                            them out.

      NOBODY IS FLAGGED.    A dispatch flag left raised suppresses that
                            player's police and medical alerts for the rest
                            of their session.

      NOBODY IS INDEXED.    No player may still be attached to a match that
                            no longer exists.

      AND IT SAID SO.       A restart that silently threw away three matches
                            is one an operator cannot account for afterwards.

    THE POINT IS THE POINTS. A teardown test that only ever fires from a
    lobby proves the easy case; the states that strand people are the ones
    where somebody has already been moved.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teardown_spec')

local IDS = { 1, 2, 3, 4 }
local START = 100000

local function newServer(mutate)
    local players = {}
    for _, id in ipairs(IDS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = START, bank = START },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}
    local buckets, flagged = {}, {}
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
        GetResourceState = function() return 'missing' end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() return 0 end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function() return true end,
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
        -- MODELLED. Whether somebody is left instanced or flagged is half of
        -- what this file asserts, so the fixture has to remember.
        ArenaDispatch = {
            Set = function(src) flagged[src] = true end,
            Clear = function(src) flagged[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return flagged[src] == true end,
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
    env.Config.Betting.enabled = true
    env.Config.Betting.entryFee.enabled = true
    env.Config.Betting.spectatorBets.enabled = true
    env.Config.Betting.houseCutPercent = 0
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, buckets = buckets, flagged = flagged,
        lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then return false end
        env.source = src
        return (pcall(handler, data))
    end

    function server.step(times) for _ = 1, (times or 2) do pcall(threads.step) end end
    function server.log() return table.concat(console, '\n') end

    --- The restart. Fired the way FXServer fires it, with this resource's
    --- own name, so the guard on the handler is exercised too.
    --- @param resourceName string? -- defaults to this resource
    function server.stop(resourceName)
        local fn = handlers['onResourceStop']
        t.isNotNil(fn, 'nothing registered an onResourceStop handler, so this file tests nothing')
        pcall(fn, resourceName or 'crimson_arena')
        server.step(4)
    end

    return server
end

local function purse(server)
    local total = 0
    for _, record in pairs(server.qbx.players) do
        total = total + (record.money.cash or 0) + (record.money.bank or 0)
    end
    return total
end

--- Everything that must be true once the resource has stopped.
--- @return string[] complaints
local function stranded(server)
    local bad = {}

    if purse(server) ~= START * 2 * #IDS then
        bad[#bad + 1] = ('money did not come home: %d, expected %d')
            :format(purse(server), START * 2 * #IDS)
    end

    local characters, owed = server.betting.Outstanding()
    if characters > 0 or owed > 0 then
        bad[#bad + 1] = ('%d character(s) still owed %d'):format(characters, owed)
    end

    for _, src in ipairs(IDS) do
        if server.buckets[src] then
            bad[#bad + 1] = ('player %d left in routing bucket %s')
                :format(src, tostring(server.buckets[src]))
        end
        if server.flagged[src] then
            bad[#bad + 1] = ('player %d left flagged as being in an arena'):format(src)
        end
        local attached = server.lobby.GetByPlayer(src)
        if attached then
            bad[#bad + 1] = ('player %d is still attached to match %s'):format(src, attached.id)
        end
    end

    return bad
end

-- ======================================================================
-- NINE POINTS ON THE LIFECYCLE
--
-- Each builds the world up to one state and stops the resource there. The
-- states are deliberately in order, so a failure names how far the round had
-- got before the restart landed.
-- ======================================================================

--- Opens a lobby with an entry fee. Returns the match id.
local function openLobby(server, fee)
    server.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = fee or 1000, account = 'cash',
    })
    local all = server.lobby.All()
    t.isNotNil(all[1], 'the lobby could not be opened')
    return all[1].id
end

local POINTS = {
    {
        name = 'an empty lobby nobody has joined',
        build = function(server) openLobby(server) end,
    },
    {
        name = 'a lobby with two fighters in it, stakes taken',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
        end,
    },
    {
        name = 'a lobby everybody has readied up in',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('setReady', 1, { ready = true })
            server.fire('setReady', 2, { ready = true })
        end,
    },
    {
        name = 'a lobby with a spectator watching it',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('spectateMatch', 3, { matchId = id })
        end,
    },
    {
        name = 'a lobby with a side-bet down on it',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('spectateMatch', 3, { matchId = id })
            server.fire('placeSpectatorBet', 3,
                { matchId = id, pick = '1', amount = 500, account = 'cash' })
        end,
    },
    {
        name = 'a round that has just been placed in the arena',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('setReady', 1, { ready = true })
            server.fire('setReady', 2, { ready = true })
            server.match.Start(id)
        end,
    },
    {
        name = 'a live round, first blood already taken',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('setReady', 1, { ready = true })
            server.fire('setReady', 2, { ready = true })
            server.match.Start(id)
            server.step(2)
            pcall(server.match.OnDeath, 2, 1)
        end,
    },
    {
        name = 'a live round with a fighter eliminated and watching',
        build = function(server)
            local id = openLobby(server)
            server.fire('joinMatch', 2, { matchId = id, account = 'cash' })
            server.fire('joinMatch', 3, { matchId = id, account = 'cash' })
            for _, src in ipairs({ 1, 2, 3 }) do server.fire('setReady', src, { ready = true }) end
            server.match.Start(id)
            server.step(2)
            local live = server.lobby.Get(id)
            live.players[3].lives = 1
            pcall(server.match.OnDeath, 3, 1)
        end,
    },
    {
        name = 'two live rounds at once, both mid-fight',
        build = function(server)
            local first = openLobby(server)
            server.fire('joinMatch', 2, { matchId = first, account = 'cash' })
            server.fire('setReady', 1, { ready = true })
            server.fire('setReady', 2, { ready = true })
            server.match.Start(first)

            server.fire('createMatch', 3, {
                arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 1000, account = 'cash',
            })
            local second
            for _, match in ipairs(server.lobby.All()) do
                if match.id ~= first then second = match.id end
            end
            server.fire('joinMatch', 4, { matchId = second, account = 'cash' })
            server.fire('setReady', 3, { ready = true })
            server.fire('setReady', 4, { ready = true })
            server.match.Start(second)
            server.step(2)
            pcall(server.match.OnDeath, 2, 1)
        end,
    },
}

for index, point in ipairs(POINTS) do
    t.test(('%d. the resource stops on %s'):format(index, point.name), function()
        local server = newServer()
        point.build(server)
        server.stop()

        local bad = stranded(server)
        t.equals(#bad, 0, ('stopping here stranded something:\n  %s')
            :format(table.concat(bad, '\n  ')))
        t.equals(#server.lobby.All(), 0, 'a match outlived the resource that owned it')
    end)
end

-- ======================================================================
-- AND THE GUARDS
-- ======================================================================

t.test('the teardown really had something to tear down', function()
    -- Every assertion above is satisfied by a server where nothing ever
    -- happened. This is what makes them mean something: the state each
    -- point builds must actually put money in escrow and people in buckets
    -- BEFORE the stop, or the file is nine tests of an empty room.
    local server = newServer()
    POINTS[#POINTS].build(server)

    local instanced = 0
    for _, src in ipairs(IDS) do
        if server.buckets[src] then instanced = instanced + 1 end
    end
    t.isTrue(instanced > 0, 'the busiest point put nobody in a routing bucket')
    t.isTrue(purse(server) < START * 2 * #IDS, 'the busiest point took nobody\'s stake')
    t.isTrue(#server.lobby.All() >= 2, 'the two-match point did not open two matches')
end)

t.test('and another resource stopping is left entirely alone', function()
    -- The guard on the handler itself. Firing for somebody else's resource
    -- must not abort this one's matches.
    local server = newServer()
    POINTS[6].build(server)
    local before = #server.lobby.All()

    -- An earlier version of this reached for a table the fixture does not
    -- have, so the loop ran zero times and the assertion held over nothing.
    -- The handler is fired for real now, with somebody else's name.
    server.stop('some_other_resource')

    t.isTrue(before > 0, 'the point built no match, so there was nothing to leave alone')
    t.equals(#server.lobby.All(), before,
        'another resource stopping tore this one down')
end)

t.test('and the operator is told how many matches the restart cost', function()
    -- A restart that silently threw away three matches is one nobody can
    -- account for afterwards.
    local server = newServer()
    POINTS[#POINTS].build(server)
    server.stop()

    t.contains(server.log(), 'aborted and refunded',
        'the stop said nothing about the matches it closed')
end)

os.exit(t.summary())
