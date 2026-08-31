--[[
    crimson_arena/tests/isolation_spec.lua

    ROUTING BUCKET ISOLATION: the real, unmodified server/dispatch.lua,
    loaded into a sandbox, with the four routing natives stubbed and every
    call to them recorded.

    WHY THIS FILE EXISTS, and it is a different worry from the one
    dispatch_spec.lua carries. That file guards a flag other people's scripts
    read; a flag left set suppresses somebody's alerts until they reconnect.
    A ROUTING BUCKET LEFT SET IS WORSE THAN THAT. A bucket lives in the
    server, not in this resource: a player left in one is alone in an
    invisible copy of the map -- no other players, no traffic, nobody able to
    see them -- and the only code that knew which bucket they came from is
    the code that stranded them. They cannot fix it, an admin cannot easily
    see it, and reconnecting does not clear it. Every test below is some
    version of that worry, and the sharpest of them is the pair that proves
    a player is put back where they were found rather than in bucket 0:
    restoring to 0 is right only on a server that instances nobody, and
    silently wrong -- with nothing printed anywhere -- on one that runs
    apartments, heists or per-job worlds.

    WHAT IS STUBBED, and no more than that: the four routing natives
    (SetPlayerRoutingBucket, GetPlayerRoutingBucket and the two
    SetRoutingBucket* configurators), Player(src).state:set, TriggerEvent,
    AddEventHandler, exports, and the two logging helpers server/util.lua
    would otherwise provide. Arena.IsKey and Arena.ToInt come from the real
    shared/arena.lua, because the guards in GetBucket and EnterBucket
    genuinely depend on them.

    THE LAST SECTION IS AN INTEGRATION SECTION. It loads the real
    server/match.lua on top of the real server/dispatch.lua, because two of
    the things worth proving are not decisions server/dispatch.lua makes on
    its own: that a SPECTATOR ends up in the bucket the fight they are
    watching is in -- watch it from outside and the round is an empty room --
    and that the once-a-second sweep puts back anybody holding a bucket who
    is no longer in a match, whichever exit they left by.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('isolation_spec')

-- ========================================================================
-- THE FIXTURE
-- ========================================================================

--- One fresh, fully isolated load of server/dispatch.lua.
---
--- `world` seeds the bucket each player is ALREADY in when the arena finds
--- them -- an apartment interior, a heist instance, whatever else the server
--- runs -- which is the value every restore assertion in this file is
--- really about. Anyone not named in it is standing in the default world.
--- @param dispatchConfig table? -- replaces Config.Dispatch entirely when given
--- @param world table<number, integer>? -- [src] = the bucket they start in
--- @return table fixture
local function newFixture(dispatchConfig, world)
    local buckets = {}       -- [src] = the bucket that player is in right now
    local calls = {}         -- every stubbed call, in order, across all kinds
    local handlers = {}      -- AddEventHandler registrations
    local logs, debugs = {}, {}

    for src, bucket in pairs(world or {}) do buckets[src] = bucket end

    --- Formats the way server/util.lua's own helpers do, so a broken format
    --- string in production shows up here as a failed test rather than as a
    --- silently mangled console line.
    local function record(sink)
        return function(fmt, ...)
            sink[#sink + 1] = (select('#', ...) > 0) and fmt:format(...) or fmt
        end
    end

    local env = Sandbox.newEnv({
        -- ---- the routing natives, which are the whole point of this file --
        GetPlayerRoutingBucket = function(src)
            calls[#calls + 1] = { kind = 'get', src = src }
            return buckets[src] or 0
        end,
        SetPlayerRoutingBucket = function(src, bucket)
            buckets[src] = bucket
            calls[#calls + 1] = { kind = 'move', src = src, bucket = bucket }
        end,
        SetRoutingBucketPopulationEnabled = function(bucket, enabled)
            calls[#calls + 1] = { kind = 'population', bucket = bucket, enabled = enabled }
        end,
        SetRoutingBucketEntityLockdownMode = function(bucket, mode)
            calls[#calls + 1] = { kind = 'lockdown', bucket = bucket, mode = mode }
        end,

        -- ---- everything else server/dispatch.lua touches at load or run ---
        Player = function(src)
            return {
                state = {
                    set = function(_self, key, value)
                        calls[#calls + 1] = { kind = 'bag', src = src, key = key, value = value }
                    end,
                },
            }
        end,
        TriggerEvent = function(name, ...)
            calls[#calls + 1] = { kind = 'event', name = name, args = { ... } }
        end,
        RegisterNetEvent = function() end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        exports = setmetatable({}, { __call = function() end }),
        ArenaLog = record(logs),
        ArenaDebug = record(debugs),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if dispatchConfig ~= nil then env.Config.Dispatch = dispatchConfig end
    Sandbox.loadInto('../server/dispatch.lua', env)

    local fixture = {
        env = env,
        D = env.ArenaDispatch,
        Config = env.Config,
        calls = calls,
        logs = logs,
        debugs = debugs,
    }

    --- Where a player is standing right now, as the stubbed native sees it.
    --- @return integer
    function fixture.bucketOf(src) return buckets[src] or 0 end

    --- Every recorded call of one kind, in order.
    --- @param kind string
    --- @return table[]
    function fixture.of(kind)
        local out = {}
        for _, call in ipairs(calls) do
            if call.kind == kind then out[#out + 1] = call end
        end
        return out
    end

    --- How many calls of one kind have been made. Counted rather than
    --- inferred from a final bucket number, because a move that happened
    --- twice and a move that happened once leave the player in the same
    --- place.
    --- @param kind string
    --- @return integer
    function fixture.count(kind) return #fixture.of(kind) end

    --- The ordered kinds, as one string, for the handful of assertions that
    --- are about SEQUENCE rather than about any one call.
    --- @return string
    function fixture.sequence()
        local out = {}
        for _, call in ipairs(calls) do out[#out + 1] = call.kind end
        return table.concat(out, ',')
    end

    --- @return string
    function fixture.log() return table.concat(logs, '\n') end

    --- @return string
    function fixture.debug() return table.concat(debugs, '\n') end

    --- Runs every handler registered for `name`, the way FXServer would.
    function fixture.fire(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end

    return fixture
end

--- Config.Dispatch with only the isolation block an operator would have
--- edited, and no `custom` block at all -- so no event fires and no
--- announcement noise lands in the call list of a test about buckets.
--- @param isolation table
--- @return table
local function isolationOnly(isolation)
    return { isolation = isolation }
end

-- ========================================================================
-- WHAT SHIPS
--
-- Every literal bucket number below comes from the shipped config. If this
-- test fails, the rest of this file is asserting against numbers the
-- resource no longer uses.
-- ========================================================================

t.test('the shipped isolation config is the one the numbers below assume', function()
    local f = newFixture()
    local isolation = f.Config.Dispatch.isolation

    -- On by default, and opt-OUT rather than opt-in: it is the one layer
    -- that protects an operator without their dispatch script agreeing to
    -- anything, so an operator upgrading from an older config gets it.
    t.isTrue(isolation.enabled)
    t.isTrue(isolation.perMatch)
    t.equals(isolation.firstBucket, 4210)
    -- An NPC that does not exist cannot witness a firefight.
    t.isFalse(isolation.populationEnabled)
    -- 'strict' would refuse the client-created entities a loadout is made
    -- of, and the player would arrive empty-handed with nothing saying why.
    t.equals(isolation.lockdownMode, 'relaxed')
end)

-- ========================================================================
-- ALLOCATING A NUMBER
-- ========================================================================

t.test('a match is given a bucket above the default world, and keeps it', function()
    local f = newFixture()
    t.equals(f.D.GetBucket('m1'), 4210)
    -- Asked twice is the same room: a match that changed instance mid-round
    -- would split its own fighters apart.
    t.equals(f.D.GetBucket('m1'), 4210)
end)

t.test('two matches at once are fought in two different instances', function()
    local f = newFixture()
    t.equals(f.D.GetBucket('m1'), 4210)
    t.equals(f.D.GetBucket('m2'), 4211)
    t.equals(f.D.GetBucket('m3'), 4212)
end)

t.test('perMatch = false puts every match in the one shared instance', function()
    -- Still hidden from the rest of the server, but two simultaneous arenas
    -- stand in one room hearing each other -- which is what config.lua says
    -- next to the setting.
    local f = newFixture(isolationOnly({ enabled = true, perMatch = false, firstBucket = 4210 }))
    t.equals(f.D.GetBucket('m1'), 4210)
    t.equals(f.D.GetBucket('m2'), 4210)
end)

t.test('the instance is configured once, when it is allocated, not once per player', function()
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm1')
    f.D.EnterBucket(3, 'm1')

    -- These are properties of the instance, not of the players in it. Three
    -- fighters would otherwise be six native calls for no change at all.
    t.equals(f.count('population'), 1)
    t.equals(f.count('lockdown'), 1)

    local population = f.of('population')[1]
    t.equals(population.bucket, 4210)
    t.isFalse(population.enabled)

    local lockdown = f.of('lockdown')[1]
    t.equals(lockdown.bucket, 4210)
    t.equals(lockdown.mode, 'relaxed')
end)

t.test('an operator asking for traffic and a strict lockdown gets both', function()
    local f = newFixture(isolationOnly({
        enabled = true,
        firstBucket = 4210,
        populationEnabled = true,
        lockdownMode = 'strict',
    }))
    f.D.GetBucket('m1')

    t.isTrue(f.of('population')[1].enabled)
    t.equals(f.of('lockdown')[1].mode, 'strict')
end)

t.test('a lockdown mode nobody recognises falls back to relaxed rather than being passed on', function()
    -- The native takes three strings and nothing else. Handing it a typo
    -- would fail inside FXServer with the arena named nowhere in it.
    for _, junk in ipairs({ 'strictly', '', 42, true }) do
        local f = newFixture(isolationOnly({ enabled = true, firstBucket = 4210, lockdownMode = junk }))
        f.D.GetBucket('m1')
        t.equals(f.of('lockdown')[1].mode, 'relaxed', ('%s should not have reached the native'):format(tostring(junk)))
    end
end)

t.test('firstBucket is never below 1, and rubbish falls back to the shipped default', function()
    -- Bucket 0 is the default world. A base of 0 would instance the entire
    -- server into the arena rather than the other way round.
    for _, low in ipairs({ 0, -5, 0.4 }) do
        local f = newFixture(isolationOnly({ enabled = true, firstBucket = low }))
        t.equals(f.D.GetBucket('m1'), 1, ('firstBucket %s'):format(tostring(low)))
    end

    for _, junk in ipairs({ 'high', {}, true }) do
        local f = newFixture(isolationOnly({ enabled = true, firstBucket = junk }))
        t.equals(f.D.GetBucket('m1'), 4210, ('firstBucket %s'):format(tostring(junk)))
    end
end)

t.test('GetBucket refuses a match id that is not one', function()
    local f = newFixture()
    for _, junk in ipairs({ '', 42, {}, true }) do
        t.isNil(f.D.GetBucket(junk))
    end
    t.isNil(f.D.GetBucket(nil))
    t.equals(#f.calls, 0)
end)

t.test('isolation switched off allocates nothing and moves nobody', function()
    -- Off means every match is fought in the ordinary world, in front of
    -- everybody, exactly as it was before this setting existed.
    local f = newFixture(isolationOnly({ enabled = false }))

    t.isNil(f.D.GetBucket('m1'))
    t.isFalse(f.D.EnterBucket(7, 'm1'))
    t.isFalse(f.D.ExitBucket(7))
    t.isFalse(f.D.ReleaseBucket('m1'))
    t.equals(#f.calls, 0)
end)

-- ========================================================================
-- THE BUCKET A PLAYER CAME FROM
--
-- The load-bearing section. Everything here is one claim: the arena puts a
-- player back where it found them.
-- ========================================================================

t.test('a fighter is moved into their match instance', function()
    local f = newFixture()
    t.isTrue(f.D.EnterBucket(7, 'm1'))

    t.equals(f.bucketOf(7), 4210)
    t.equals(f.count('move'), 1)
    t.equals(f.of('move')[1].src, 7)
    t.equals(f.of('move')[1].bucket, 4210)
end)

t.test('THE ONE THAT MATTERS: a player is restored to the bucket they came from, not to 0', function()
    -- 91 stands in for whatever else this server instances -- an apartment
    -- interior, a heist, a per-job world. Restoring to a hard-coded 0 is
    -- right only on a server that instances nobody, and on one that does it
    -- silently reassigns the player to the default world with nothing
    -- telling them or the operator it happened.
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    t.equals(f.bucketOf(7), 4210)

    t.isTrue(f.D.ExitBucket(7))
    t.equals(f.bucketOf(7), 91)

    local moves = f.of('move')
    t.equals(#moves, 2)
    t.equals(moves[2].bucket, 91)
end)

t.test('a player who came from the default world goes back to the default world', function()
    local f = newFixture()
    f.D.EnterBucket(7, 'm1')
    f.D.ExitBucket(7)
    t.equals(f.bucketOf(7), 0)
end)

t.test('entering the same match twice moves the player once and does not re-capture', function()
    -- The failure this guards: the second capture records OUR bucket as the
    -- one to restore, and the player lives in an empty instance for the rest
    -- of their session.
    local f = newFixture(nil, { [7] = 91 })

    t.isTrue(f.D.EnterBucket(7, 'm1'))
    t.isTrue(f.D.EnterBucket(7, 'm1'))
    t.equals(f.count('move'), 1)

    f.D.ExitBucket(7)
    t.equals(f.bucketOf(7), 91)
end)

t.test('a player moved straight from one match to another still lands back in the world they started in', function()
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    f.D.EnterBucket(7, 'm2')
    -- m1 was still allocated when m2 asked for a number, so the two rounds
    -- got separate rooms.
    t.equals(f.bucketOf(7), 4211)

    f.D.ExitBucket(7)
    t.equals(f.bucketOf(7), 91)
end)

t.test('a player found sitting in an arena bucket is sent back to the default world, and it is said out loud', function()
    -- 8 is standing in the number this resource is about to allocate, which
    -- can only mean an earlier exit never ran. Sending them "back" there
    -- afterwards would strand them in an arena nobody is fighting in.
    local f = newFixture(nil, { [8] = 4210 })
    f.D.EnterBucket(1, 'm1')            -- allocates and occupies 4210

    f.D.EnterBucket(8, 'm1')
    f.D.ExitBucket(8)

    t.equals(f.bucketOf(8), 0)
    t.contains(f.debug(), '4210')
end)

t.test('EnterBucket refuses rubbish rather than moving on it', function()
    local f = newFixture()
    t.isFalse(f.D.EnterBucket(nil, 'm1'))
    t.isFalse(f.D.EnterBucket(0, 'm1'))
    t.isFalse(f.D.EnterBucket(-3, 'm1'))
    t.isFalse(f.D.EnterBucket('7', 'm1'))
    t.isFalse(f.D.EnterBucket(7, nil))
    t.isFalse(f.D.EnterBucket(7, ''))
    t.isFalse(f.D.EnterBucket(7, {}))

    t.equals(f.count('move'), 0)
end)

t.test('ExitBucket for somebody this file never moved does nothing at all', function()
    -- It is called from every exit path there is, several of which can
    -- happen to one player in quick succession, and a stray restore would
    -- pull a player out of an instance some other resource put them in.
    local f = newFixture()
    t.isFalse(f.D.ExitBucket(99))
    t.isFalse(f.D.ExitBucket(nil))
    t.isFalse(f.D.ExitBucket(-1))
    t.equals(f.count('move'), 0)
end)

t.test('a routing native that throws for a player already gone still frees the record and the number', function()
    -- The disconnect path reaches ExitBucket after the player has left, and
    -- a native called against an id that no longer exists must not take the
    -- rest of the exit down with it -- least of all the release, which is
    -- what stops the number being held against a match that has ended.
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.env.SetPlayerRoutingBucket = function() error('no such player') end

    local ok, restored = pcall(f.D.ExitBucket, 1)
    t.isTrue(ok)
    t.isTrue(restored)
    t.contains(f.debug(), 'routing bucket')

    -- The record is gone, so a second exit finds nothing...
    t.isFalse(f.D.ExitBucket(1))
    -- ...and the number really did go back to the pool.
    t.equals(f.D.GetBucket('m2'), 4210)
end)

-- ========================================================================
-- HANDING THE NUMBER BACK
--
-- The one failure a bucket allocator can have is dropping a fresh match
-- into a room somebody is still standing in.
-- ========================================================================

t.test('a bucket is not freed while one of that match players is still in it', function()
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm1')

    t.isFalse(f.D.ReleaseBucket('m1'))

    -- The first fighter leaving frees nothing either: ExitBucket asks, and
    -- is refused, because the second is still in there.
    f.D.ExitBucket(1)
    t.equals(f.bucketOf(2), 4210)
    -- Still spoken for, so a new match is given the next number up rather
    -- than being dropped on top of player 2.
    t.equals(f.D.GetBucket('m2'), 4211)
end)

t.test('the last player out frees the number, and the next match reuses it', function()
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm1')
    f.D.ExitBucket(1)
    f.D.ExitBucket(2)

    -- Counted up from the base to the first free number rather than taken
    -- from a counter that only climbs: a server running for a week would
    -- otherwise walk off into whatever range the rest of the box is using.
    t.equals(f.D.GetBucket('m2'), 4210)
end)

t.test('ReleaseBucket collects the instance of a match everybody had already disconnected from', function()
    -- The End and Abort paths call this precisely because there was no last
    -- person to walk out, and the number would otherwise be held against a
    -- match id that no longer exists for the rest of the server's run.
    local f = newFixture()
    f.D.GetBucket('m1')

    t.isTrue(f.D.ReleaseBucket('m1'))
    -- Asked twice, it has nothing left to give back.
    t.isFalse(f.D.ReleaseBucket('m1'))
    t.equals(f.D.GetBucket('m2'), 4210)
end)

t.test('ReleaseBucket refuses a match id it never allocated for', function()
    local f = newFixture()
    t.isFalse(f.D.ReleaseBucket('never-started'))
    t.isFalse(f.D.ReleaseBucket(nil))
    t.isFalse(f.D.ReleaseBucket(42))
end)

t.test('with one shared bucket, a finished match releases its own mapping and not the other one', function()
    -- perMatch = false has both matches standing in 4210, so a release
    -- matched on the NUMBER alone would either free a room two matches are
    -- using or never free anything again. It is matched on the match id.
    local f = newFixture(isolationOnly({ enabled = true, perMatch = false, firstBucket = 4210 }))
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm2')
    t.equals(f.bucketOf(1), 4210)
    t.equals(f.bucketOf(2), 4210)

    t.isFalse(f.D.ReleaseBucket('m1'))      -- player 1 is still in it
    f.D.ExitBucket(1)
    t.isFalse(f.D.ReleaseBucket('m1'))      -- and now it is already released
    -- m2 is untouched: its fighter is still standing there.
    t.equals(f.bucketOf(2), 4210)
    t.isFalse(f.D.ReleaseBucket('m2'))
end)

-- ========================================================================
-- SPECTATORS
--
-- A spectator outside the bucket watches an empty room: nothing about the
-- fighters replicates to them, so the camera is pointed at a player id
-- their game does not have.
-- ========================================================================

t.test('a spectator put in the match they are watching lands in the fighters instance', function()
    local f = newFixture(nil, { [9] = 77 })
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(9, 'm1')

    t.equals(f.bucketOf(9), f.bucketOf(1))
    -- And they are still a visitor: the world they were watching from is
    -- what they go back to.
    f.D.ExitBucket(9)
    t.equals(f.bucketOf(9), 77)
end)

t.test('a bucket stays allocated while only a spectator is left in it', function()
    -- The last fighter leaving is not the last person leaving. Freeing the
    -- number here would drop the next match into the room somebody is still
    -- watching from.
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(9, 'm1')
    f.D.ExitBucket(1)

    t.equals(f.bucketOf(9), 4210)
    t.equals(f.D.GetBucket('m2'), 4211)
end)

-- ========================================================================
-- SHUTDOWN
--
-- A bucket lives in the server, not in this resource: stopping
-- crimson_arena does not empty one.
-- ========================================================================

t.test('stopping the resource returns every player to the bucket they came from', function()
    local f = newFixture(nil, { [1] = 91, [2] = 91, [3] = 0 })
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm1')
    f.D.EnterBucket(3, 'm2')

    f.fire('onResourceStop', 'crimson_arena')

    t.equals(f.bucketOf(1), 91)
    t.equals(f.bucketOf(2), 91)
    t.equals(f.bucketOf(3), 0)
    t.contains(f.log(), '3 player(s)')
end)

t.test('stopping hands every number back, so a restart starts from a clean pool', function()
    local f = newFixture()
    f.D.EnterBucket(1, 'm1')
    f.D.EnterBucket(2, 'm2')
    f.fire('onResourceStop', 'crimson_arena')

    -- Nobody held, nothing allocated: the next match gets the base number.
    t.equals(f.D.GetBucket('m3'), 4210)
    -- And nobody is left to restore a second time.
    t.isFalse(f.D.ExitBucket(1))
    t.isFalse(f.D.ExitBucket(2))
end)

t.test('the buckets are returned before the flags are cleared', function()
    -- Order is load-bearing rather than tidy: a flag left set is a bug in
    -- somebody else's script for one restart, a bucket left set is a player
    -- who cannot play. The moves must come first, before anything later in
    -- the shutdown gets the chance to fail.
    local f = newFixture(isolationOnly({ enabled = true, firstBucket = 4210 }))
    f.D.Set(1, 'm1')
    f.D.EnterBucket(1, 'm1')

    local before = #f.calls
    f.fire('onResourceStop', 'crimson_arena')

    local after = {}
    for index = before + 1, #f.calls do after[#after + 1] = f.calls[index].kind end
    t.equals(table.concat(after, ','), 'move,bag')
end)

t.test('another resource stopping leaves everybody exactly where they are', function()
    local f = newFixture(nil, { [1] = 91 })
    f.D.EnterBucket(1, 'm1')
    f.fire('onResourceStop', 'some_other_script')

    t.equals(f.bucketOf(1), 4210)
    -- Still ours to give back later.
    t.isTrue(f.D.ExitBucket(1))
end)

-- ========================================================================
-- THE REAL MATCH, END TO END
--
-- server/dispatch.lua owns the bookkeeping; server/match.lua decides WHEN.
-- Both are the shipped files here, over the shipped config, with only the
-- lobby, the escrow and the leaderboard stood in for -- none of which has
-- an opinion about routing buckets.
-- ========================================================================

--- The lobby record server/match.lua reads, and only the functions it calls.
--- @return table lobby
local function newLobby()
    local matches = {}
    local lobby = {}

    function lobby.Get(matchId) return matches[matchId] end
    function lobby.All()
        local out = {}
        for _, match in pairs(matches) do out[#out + 1] = match end
        return out
    end
    function lobby.PlayerArray(match)
        local out = {}
        if type(match) ~= 'table' then return out end
        for _, src in ipairs(match.order or {}) do
            local player = match.players[src]
            if player then out[#out + 1] = player end
        end
        return out
    end
    function lobby.PlayerCount(match) return #lobby.PlayerArray(match) end
    function lobby.GetByPlayer(src)
        for _, match in pairs(matches) do
            if match.players[src] then return match end
        end
        return nil
    end
    function lobby.Broadcast() end
    function lobby.AddSpectator(src, matchId)
        local match = matches[matchId]
        if not match then return false end
        match.spectators[src] = true
        -- `true`, because the real one returns it and ArenaMatch.OnDeath
        -- reads it with `== true` to decide whether an eliminated player is
        -- handed the camera at all. A double that answered nil made the
        -- elimination path in the spectator tests below the wrong shape.
        return true
    end
    function lobby.RemoveSpectator(src)
        for _, match in pairs(matches) do match.spectators[src] = nil end
    end
    function lobby.Leave() end
    function lobby.Destroy(matchId) matches[matchId] = nil end

    --- Test-side: puts a record where Get and All will find it.
    function lobby.put(match) matches[match.id] = match end

    return lobby
end

--- The real server/dispatch.lua and the real server/match.lua in one
--- sandbox, with the routing natives stubbed the same way as above.
--- @param world table<number, integer>? -- [src] = the bucket they start in
--- @return table fixture
local function newArena(world)
    local buckets = {}
    local lobby = newLobby()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    for src, bucket in pairs(world or {}) do buckets[src] = bucket end

    local env = Sandbox.newEnv({
        GetPlayerRoutingBucket = function(src) return buckets[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) buckets[src] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,

        Player = function() return { state = { set = function() end } } end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetPlayerName = function(src) return ('Fighter %d'):format(src) end,
        exports = setmetatable({ qbx_core = { GetPlayer = function() return nil end } },
            { __call = function() end }),
        print = function() end,

        CreateThread = runner.CreateThread,
        Wait = runner.Wait,

        ArenaLobby = lobby,
        ArenaAmmo = {
            -- No-op double: this file is about routing buckets, and
            -- server/match.lua now calls the ammo ledger at both arena
            -- choke points. tests/ammo_spec.lua covers the real thing.
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaStats = { RecordMatch = function() end },
        ArenaBetting = {
            GetPot = function() return 0 end,
            GetStake = function() return 0 end,
            Settle = function() return {} end,
            SettleSpectatorBets = function() end,
            RefundAll = function() end,
            Clear = function() end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    -- No freeze and one life each: the round is live on the first pass, and
    -- one death decides it. Both are about getting to the sweep this section
    -- is really testing, and neither touches a routing bucket.
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 1
    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)
    Sandbox.loadInto('../server/match.lua', env)

    local fixture = { env = env, D = env.ArenaDispatch, M = env.ArenaMatch, lobby = lobby }

    function fixture.bucketOf(src) return buckets[src] or 0 end

    --- One pass of every live thread. The sweep waits before it works, so
    --- the first call only primes it.
    function fixture.step() runner.step() end

    --- Runs every handler registered for `name`, the way FXServer would.
    function fixture.fire(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end

    --- A lobby record in the shape server/lobby.lua builds one.
    --- @param ids integer[]
    --- @return table match
    function fixture.newMatch(matchId, ids)
        local match = {
            id = matchId,
            arenaKey = 'airfield',
            modeKey = 'ffa',
            hostSource = ids[1],
            state = 'lobby',
            entryFee = 0,
            createdAt = os.time(),
            players = {},
            order = {},
            spectators = {},
        }
        for _, src in ipairs(ids) do
            match.players[src] = {
                src = src,
                citizenid = ('CID%03d'):format(src),
                name = ('Fighter %d'):format(src),
                ready = true,
                loadout = (env.Arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })),
                kills = 0,
                deaths = 0,
                alive = true,
                lives = 1,
                stake = 0,
                joinedAt = os.time(),
            }
            match.order[#match.order + 1] = src
        end
        lobby.put(match)
        return match
    end

    return fixture
end

t.test('starting a match instances every fighter, and the round ending brings them all back', function()
    local f = newArena({ [1] = 91, [2] = 0 })
    local match = f.newMatch('m1', { 1, 2 })

    t.isTrue((f.M.Start(match.id)))
    -- Instanced by Start, before the client is told to teleport in: appearing
    -- in the arena in the ordinary world for the frame in between would be
    -- the whole server watching the round begin.
    t.equals(f.bucketOf(1), 4210)
    t.equals(f.bucketOf(2), 4210)

    f.step()                                    -- the freeze thread lifts; the round is live
    t.equals(match.state, 'live')

    f.M.OnDeath(2, 1)
    f.step()                                    -- the sweep declares the last one standing

    t.equals(match.state, 'ended')
    t.equals(f.bucketOf(1), 91)
    t.equals(f.bucketOf(2), 0)
    -- The number went back with them, so the next match reuses it rather
    -- than holding one against a match id that no longer exists.
    t.equals(f.D.GetBucket('m2'), 4210)
end)

t.test('a spectator attached mid-round is swept into the bucket the fight is in', function()
    -- Spectators are attached and detached by server/lobby.lua from call
    -- sites server/match.lua does not own, so they are reconciled by the
    -- sweep rather than intercepted. Watch from outside the bucket and the
    -- arena is an empty room: nothing about the fighters replicates, so the
    -- camera is pointed at a player id that client does not have.
    local f = newArena({ [9] = 77 })
    local match = f.newMatch('m1', { 1, 2 })
    f.M.Start(match.id)
    f.step()

    f.lobby.AddSpectator(9, match.id)
    t.equals(f.bucketOf(9), 77)

    f.step()
    t.equals(f.bucketOf(9), 4210)
    t.equals(f.bucketOf(9), f.bucketOf(1))

    -- And they are let out again when they stop watching, by the same sweep.
    f.lobby.RemoveSpectator(9)
    f.step()
    t.equals(f.bucketOf(9), 77)
end)

t.test('a player who leaves by a path that sends no exit is swept back out within a tick', function()
    -- The point of reconciling rather than trusting every departure to
    -- remember: main.lua's countdown detach sends a player to
    -- ArenaLobby.Leave and no exit is sent for them at all. A stranded
    -- player cannot fix this themselves and an operator cannot easily see
    -- it, so it is worth a table walk a second.
    local f = newArena({ [3] = 91 })
    local match = f.newMatch('m1', { 1, 2, 3 })
    f.M.Start(match.id)
    f.step()
    t.equals(f.bucketOf(3), 4210)

    -- Straight out of the record, the way a path that forgot would leave it.
    match.players[3] = nil
    match.order = { 1, 2 }

    f.step()
    t.equals(f.bucketOf(3), 91)
    -- The two still fighting are untouched, and the round carries on.
    t.equals(match.state, 'live')
    t.equals(f.bucketOf(1), 4210)
    t.equals(f.bucketOf(2), 4210)
end)

t.test('stopping the resource mid-round returns every fighter to the world they came from', function()
    -- The worst case this whole layer has: the resource goes away while a
    -- round is live, and the only code that knows which bucket each fighter
    -- came from is the code that is stopping.
    local f = newArena({ [1] = 91, [2] = 0 })
    local match = f.newMatch('m1', { 1, 2 })
    f.M.Start(match.id)
    f.step()
    t.equals(f.bucketOf(1), 4210)

    f.fire('onResourceStop', 'crimson_arena')

    t.equals(f.bucketOf(1), 91)
    t.equals(f.bucketOf(2), 0)
end)

os.exit(t.summary())
