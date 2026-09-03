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
--- `opts` models the two things a server can do that no config setting
--- describes: answer OneSync through the older pair of convars instead of
--- the modern one, and accept a SetPlayerRoutingBucket call while doing
--- nothing with it. The second is the failure an operator actually reported
--- and the reason `inert` exists -- every line of the allocation still runs
--- and still looks right, and the players are simply not separated.
--- @param dispatchConfig table? -- replaces Config.Dispatch entirely when given
--- @param world table<number, integer>? -- [src] = the bucket they start in
--- @param oneSyncMode string? -- what GetConvar('onesync') answers
--- @param opts table? -- { inert = boolean, convars = table, connected = table|boolean }
--- @return table fixture
local function newFixture(dispatchConfig, world, oneSyncMode, opts)
    opts = opts or {}
    local buckets = {}       -- [src] = the bucket that player is in right now
    -- ON unless a test says otherwise, so every case above describes a
    -- server where isolation CAN work and only the ones about OneSync
    -- have to think about it.
    local oneSync = oneSyncMode or 'on'
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
            -- `inert` is the whole point: the call is accepted, recorded,
            -- and changes nothing -- which is exactly what FXServer does
            -- with these natives when routing buckets are not available.
            if not opts.inert then buckets[src] = bucket end
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
        -- ONESYNC, WHICH ROUTING BUCKETS NEED. Defaults to on so every test
        -- above this one still describes a server where isolation can work;
        -- the tests that care set it themselves.
        GetConvar = function(name, fallback)
            if opts.convars and opts.convars[name] ~= nil then return opts.convars[name] end
            if name == 'onesync' then return oneSync end
            return fallback
        end,

        -- WHO IS STILL HERE. A bucket that did not take and a player who
        -- left while it was being set look identical from the inside, and
        -- only one of them is the server's fault. Everyone is connected
        -- unless a test names otherwise; `connected = false` is a server
        -- this resource cannot ask, which must not be read as proof of
        -- anything either.
        GetPlayerName = opts.connected ~= 'absent' and function(src)
            -- 'error' models a build where the native itself is unusable --
            -- a server this file cannot ask, which is not the same as a
            -- server that answered no.
            if opts.connected == 'error' then error('no such player') end
            -- Builds differ on what a player who has gone answers with:
            -- some hand back nil, some hand back an empty string, and only
            -- one of those is caught by a nil check.
            if opts.connected == 'empty' then return '' end
            if opts.connected == false then return nil end
            if type(opts.connected) == 'table' and not opts.connected[src] then return nil end
            return 'player' .. tostring(src)
        end,

        RegisterNetEvent = function() end,
        -- /arenarevive registers at load. Dropped rather than captured: this
        -- fixture is about routing buckets and never runs a command.
        RegisterCommand = function() end,
        -- The permission grant runs in a thread at load. Captured and
        -- dropped: this fixture is about routing buckets, and running it
        -- would only add noise to every assertion below.
        CreateThread = function() end,
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
    -- Loaded by hand here rather than through newArenaEnv, so the arenas are
    -- switched on by hand too. Nothing in this file is about which ones an
    -- operator ships enabled.
    Sandbox.enableAllArenas(env)
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

    --- Makes the routing natives stop working PART WAY THROUGH, which is the
    --- only way to reach the drift repair on a server that is not honouring
    --- buckets: the first refused move takes isolation down with it, and
    --- every later call gives up before the repair is reached.
    function fixture.goInert() opts.inert = true end

    --- Moves a player the way another resource on the box would -- an
    --- interior, a job, a heist, an admin tool -- with this file told
    --- nothing about it.
    function fixture.somebodyElseMoves(src, bucket) buckets[src] = bucket end

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

-- ======================================================================
-- WHETHER THE SERVER CAN INSTANCE AT ALL
-- ======================================================================

t.test('with OneSync off there is no bucket, because the natives do nothing', function()
    -- ROUTING BUCKETS REQUIRE ONESYNC. Without it SetPlayerRoutingBucket and
    -- the SetRoutingBucket* natives do nothing at all -- no error, no return
    -- value, no warning. Every line of the allocation still runs and still
    -- looks right; the players simply are not separated.
    --
    -- Answering nil here is what makes the rest of the resource safe: the
    -- guard in server/match.lua refuses a second match at an arena when
    -- GetBucket returns nil, and that fallback exists for exactly this. With
    -- a number returned instead, it told that code the ground was safe to
    -- share and let a second round start on top of a live one.
    local f = newFixture(nil, nil, 'off')
    t.equals(f.D.GetBucket('m1'), nil, 'a bucket was handed out on a server that cannot honour it')
    t.equals(f.D.EnterBucket(7, 'm1'), false)
    t.equals(f.count('move'), 0, 'a player was moved into an instance that does not exist')
end)

t.test('and it says so, once, loudly', function()
    -- An operator whose isolation is silently absent has no way to find out.
    local f = newFixture(nil, nil, 'off')
    f.D.GetBucket('m1')
    f.D.GetBucket('m2')
    f.D.EnterBucket(7, 'm1')

    local said = f.log()
    t.isTrue(said:find('OneSync', 1, true) ~= nil,
        'isolation was refused and OneSync was never mentioned')
    -- Once, not once per match: a line printed every round is a line nobody
    -- reads.
    local count, from = 0, 1
    while true do
        local at = said:find('OneSync', from, true)
        if not at then break end
        count = count + 1
        from = at + 1
    end
    t.equals(count, 1, ('OneSync was named %d times; it should be said once'):format(count))
end)

t.test('every OneSync mode that is not off still instances', function()
    -- ONLY A DEFINITE off REFUSES. An unrecognised value is far more likely
    -- to be a build newer than this code than a mode without buckets, and
    -- guessing wrong there switches off a layer that was working.
    for _, mode in ipairs({ 'on', 'legacy', 'infinity', 'something_new' }) do
        local f = newFixture(nil, nil, mode)
        t.isTrue(f.D.GetBucket('m1') ~= nil,
            ('OneSync "%s" was treated as no isolation at all'):format(mode))
    end
end)

t.test('the older pair of convars counts, however the operator spelled the yes', function()
    -- A CONVAR BOOLEAN IS NOT THE STRING 'true'. `set onesync_enabled 1` is
    -- the spelling half the guides on the internet use, and yes/on both turn
    -- up in the wild -- GetConvar hands back whatever was typed, verbatim.
    -- Comparing against 'true' alone read every one of those as OneSync OFF
    -- and switched isolation off on servers that had it running.
    for _, said in ipairs({ '1', 'true', 'TRUE', 'yes', 'on' }) do
        local f = newFixture(nil, nil, nil, { convars = { onesync = '', onesync_enabled = said } })
        t.isTrue(f.D.GetBucket('m1') ~= nil,
            ('onesync_enabled "%s" was read as OneSync being off'):format(said))
    end

    -- And the same for the infinity half of the pair, read through the one
    -- reader that survived: ArenaDispatch.OneSync was a public one-line
    -- wrapper with no production caller, so it went.
    local inf = newFixture(nil, nil, nil, { convars = { onesync = '', onesync_enableInfinity = '1' } })
    t.equals(inf.D.IsolationState().oneSync, 'infinity')
end)

t.test('and a no is a no however THAT is spelled', function()
    for _, said in ipairs({ 'off', 'false', '0', 'no', 'OFF' }) do
        local f = newFixture(nil, nil, said)
        t.equals(f.D.GetBucket('m1'), nil,
            ('onesync "%s" was read as OneSync being on'):format(said))
    end

    -- Neither list is the other's complement, and that is deliberate: a mode
    -- name this file has never heard of is not a refusal, because it is far
    -- more likely to be a build newer than this code.
    local newer = newFixture(nil, nil, 'something_new')
    t.isTrue(newer.D.GetBucket('m1') ~= nil)
end)

-- ======================================================================
-- WHETHER THE SERVER ACTUALLY DID IT
--
-- Every test above this line asks the server a QUESTION -- which convar is
-- set, what does it name -- and trusts the answer for the rest of the run.
-- An operator reported twice that matches were still sharing a world while
-- all of those questions answered yes, and nothing in the resource could
-- have told them otherwise: the allocation ran, the move ran, the log said
-- the match was instanced, and the players stood in each other.
--
-- Setting a routing bucket is a synchronous write to a field the server
-- keeps for that client -- there is no race to lose and no tick to wait for
-- -- so reading it back is a measurement rather than a poll, and a
-- disagreement is proof rather than a hint.
-- ======================================================================

t.test('a server that accepts the move and does nothing with it is CAUGHT', function()
    local f = newFixture(nil, { [7] = 91 }, 'on', { inert = true })

    -- The allocation looks perfectly healthy, because it is: the numbers are
    -- this file's own and nothing about them needs the server.
    t.equals(f.D.GetBucket('m1'), 4210)

    t.isFalse(f.D.EnterBucket(7, 'm1'), 'a move that did not land was reported as having landed')
    t.equals(f.count('move'), 1, 'the native was never even called')
    t.equals(f.bucketOf(7), 91, 'the fixture is not modelling an inert server')
end)

t.test('and it says so, loudly, naming what it read', function()
    local f = newFixture(nil, { [7] = 91 }, 'on', { inert = true })
    f.D.EnterBucket(7, 'm1')

    local said = f.log()
    t.isTrue(said:find('4210', 1, true) ~= nil, 'the bucket it asked for was not named')
    t.isTrue(said:find('91', 1, true) ~= nil, 'the bucket the server actually reported was not named')
    -- The mode the server reports is named too, because that is the thing
    -- the operator has to go and change.
    t.isTrue(said:find('onesync', 1, true) ~= nil, 'the operator was not told where to look')

    -- IN THE OPERATOR'S CONSOLE, not in a debug channel they would have to
    -- switch on first -- and they cannot switch it on to find out about a
    -- problem they do not know they have.
    t.isTrue(f.debug():find('ISOLATION IS NOT IN FORCE', 1, true) == nil,
        'the one line that explains what they are watching was sent to the debug channel')
end)

t.test('once, not once a player', function()
    local f = newFixture(nil, nil, 'on', { inert = true })
    f.D.EnterBucket(7, 'm1')
    f.D.EnterBucket(8, 'm1')
    f.D.EnterBucket(9, 'm2')

    local said, count, from = f.log(), 0, 1
    while true do
        local at = said:find('ISOLATION IS NOT IN FORCE', from, true)
        if not at then break end
        count = count + 1
        from = at + 1
    end
    t.equals(count, 1, ('the operator was told %d times; a line printed every round is a line nobody reads'):format(count))
end)

t.test('THE FALLBACK IT UNLOCKS: no bucket is handed out afterwards', function()
    -- This is the half that matters more than the log line. With no bucket
    -- to hand out, server/match.lua refuses to start a second match at an
    -- arena somebody is already fighting in -- two rounds sharing one
    -- platform is the symptom the operator sees, and that guard was written
    -- for exactly this and was never reachable, because nothing in the
    -- resource could tell that it was needed.
    local f = newFixture(nil, nil, 'on', { inert = true })
    t.equals(f.D.GetBucket('m1'), 4210, 'the first allocation happens before anything is known')
    f.D.EnterBucket(7, 'm1')

    t.equals(f.D.GetBucket('m2'), nil, 'a second match was still told the ground was safe to share')
    t.equals(f.D.GetBucket('m1'), nil)
    t.isFalse(f.D.IsolationState().inForce)
    t.isTrue(f.D.IsolationState().provenInert)
end)

t.test('a player who left while it was being set is NOT held against the server', function()
    -- The two look identical from the inside and only one of them is the
    -- server's fault. Reading a disconnect as proof would switch isolation
    -- off for everybody else on the box for the rest of the run, on the
    -- strength of somebody's alt-F4.
    local f = newFixture(nil, nil, 'on', { inert = true, connected = {} })
    f.D.EnterBucket(7, 'm1')

    t.isFalse(f.D.IsolationState().provenInert)
    t.isTrue(f.D.GetBucket('m2') ~= nil, 'isolation was switched off by a player leaving')
end)

t.test('nor is a server this file cannot ask', function()
    -- CONVICTED ON A READING NOBODY COULD TAKE. If the native that answers
    -- "is this player still here" is unusable, then the difference between a
    -- broken server and a player who left cannot be established -- and
    -- guessing "broken" there switches isolation off for everybody on the
    -- box for the rest of the run, on no evidence at all.
    local f = newFixture(nil, nil, 'on', { inert = true, connected = 'error' })
    f.D.EnterBucket(7, 'm1')

    t.isFalse(f.D.IsolationState().provenInert)
    t.isTrue(f.D.GetBucket('m2') ~= nil, 'isolation was switched off on a reading that could not be taken')

    -- Same conclusion when the native is not there to call at all, which is
    -- what every other fixture in this suite looks like from the inside.
    local absent = newFixture(nil, nil, 'on', { inert = true, connected = 'absent' })
    absent.D.EnterBucket(7, 'm1')
    t.isFalse(absent.D.IsolationState().provenInert)
    t.isTrue(absent.D.GetBucket('m2') ~= nil)

    -- And when the player who left is reported as an empty name rather than
    -- as nil, which is the same departure spelled the way half the builds
    -- spell it.
    local blank = newFixture(nil, nil, 'on', { inert = true, connected = 'empty' })
    blank.D.EnterBucket(7, 'm1')
    t.isFalse(blank.D.IsolationState().provenInert)
    t.isTrue(blank.D.GetBucket('m2') ~= nil)
end)

t.test('IsolationState keeps the three facts apart', function()
    -- An operator reading "isolation: off" cannot act on it without knowing
    -- WHICH of the three said no: they turned it off, their server has no
    -- OneSync, or their server said one thing and did another.
    local off = newFixture(isolationOnly({ enabled = false }))
    t.isFalse(off.D.IsolationState().wanted)
    t.isFalse(off.D.IsolationState().inForce)
    t.isFalse(off.D.IsolationState().provenInert)

    local noSync = newFixture(nil, nil, 'off')
    t.isTrue(noSync.D.IsolationState().wanted)
    t.equals(noSync.D.IsolationState().oneSync, 'off')
    t.isFalse(noSync.D.IsolationState().inForce)
    t.isFalse(noSync.D.IsolationState().provenInert)

    local healthy = newFixture()
    t.isTrue(healthy.D.IsolationState().inForce)
    t.isTrue(healthy.D.IsolationState().perMatch)
end)

t.test('and a server that stops honouring buckets MID-ROUND is caught by that same repair', function()
    -- THE ONE ROUTE INTO THE DRIFT REPAIR ON A BROKEN SERVER, and the reason
    -- the repair has to verify rather than just call the native. A server
    -- that was never instancing is caught by the first fighter and shuts
    -- isolation off for the run; a server that WAS instancing and stops --
    -- OneSync restarted, another resource taking the sync component down --
    -- has live matches already allocated, already held, and every later pass
    -- walks into the repair branch instead. Firing the native there and not
    -- reading it back put a player back in the arena on paper, once a
    -- second, for the rest of the round.
    local f = newFixture(nil, { [7] = 91 })
    t.isTrue(f.D.EnterBucket(7, 'm1'), 'the fixture did not start from a working server')
    t.equals(f.bucketOf(7), 4210)

    f.goInert()
    f.somebodyElseMoves(7, 91)

    -- Same call the sweep makes once a second on everybody in a match.
    f.D.EnterBucket(7, 'm1')

    t.isTrue(f.D.IsolationState().provenInert,
        'the repair fired the native, never read it back, and reported a player instanced who was not')
    t.isTrue(f.log():find('ISOLATION IS NOT IN FORCE', 1, true) ~= nil,
        'the operator was never told isolation had stopped working')
end)

t.test('THE OTHER ONE THAT MATTERS: a player moved out of the arena by something else is put back', function()
    -- HOW ISOLATION GOES QUIETLY MISSING. A routing bucket is server-wide
    -- state and any resource can set it -- an interior, a job, a heist, an
    -- admin tool, another script's own cleanup. Nothing tells this file when
    -- one does.
    --
    -- The record still said the player was where they belonged, so every
    -- later pass agreed there was nothing to do, and they fought the rest of
    -- the round in the ordinary world in front of the whole server -- with
    -- the arena's one real defence against a dispatch script simply absent
    -- and nothing anywhere saying so.
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    t.equals(f.bucketOf(7), 4210)
    t.equals(f.count('move'), 1)

    -- Somebody else's resource, mid-round.
    f.env.SetPlayerRoutingBucket(7, 55)
    t.equals(f.bucketOf(7), 55)

    -- The next sweep pass. EnterBucket is what runs on it, and it is called
    -- unconditionally rather than only on the first pass -- see the loop in
    -- server/match.lua.
    t.isTrue(f.D.EnterBucket(7, 'm1'))
    t.equals(f.bucketOf(7), 4210, 'the player was left outside the instance their match is in')
end)

t.test('and they still go home to the world they started in, not to wherever they drifted', function()
    -- The half that is easy to break while fixing the half above. Re-reading
    -- the current bucket during the correction records the instance somebody
    -- else moved them into as the place to send them back to, and the player
    -- ends the round somewhere they have never been.
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    f.env.SetPlayerRoutingBucket(7, 55)
    f.D.EnterBucket(7, 'm1')

    f.D.ExitBucket(7)
    t.equals(f.bucketOf(7), 91, 'the drift was recorded as the bucket to restore')
end)

t.test('and the correction is said out loud rather than done silently', function()
    -- A player being moved out of the arena repeatedly is a conflict with
    -- another resource, and an operator cannot see it any other way. A fix
    -- that hides its own symptom is how the cause stays unfound.
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    f.env.SetPlayerRoutingBucket(7, 55)
    f.D.EnterBucket(7, 'm1')

    t.isTrue(table.concat(f.debugs, '\n'):find('drifted', 1, true) ~= nil,
        'a player was put back into the arena instance and nothing was said about it')
end)

t.test('and a player who has not drifted is left alone rather than moved every pass', function()
    -- The correction reads the world before it writes to it. Without that
    -- read it is a SetPlayerRoutingBucket per arena player per second,
    -- forever, for no change at all.
    local f = newFixture(nil, { [7] = 91 })

    f.D.EnterBucket(7, 'm1')
    local afterEntry = f.count('move')

    for _ = 1, 5 do f.D.EnterBucket(7, 'm1') end

    t.equals(f.count('move'), afterEntry,
        'a player already in the right instance is being re-set on every pass')
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
        -- /arenarevive registers at load. Dropped: this fixture is about
        -- routing buckets and never runs a command.
        RegisterCommand = function() end,
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
            -- Refunds are not earnings, and server/match.lua asks this to
            -- tell them apart. A double missing it is a nil call naming it.
            IsRefundReason = function(reason)
                return type(reason) == 'string' and reason:sub(1, 6) == 'refund'
            end,
            GetPot = function() return 0 end,
            GetStake = function() return 0 end,
            Settle = function() return {} end,
            -- goLive schedules ONE broadcast at the instant the side-bet
            -- window shuts, and asks this when it is. nil is "no window to
            -- wait on", which is the right answer for a fixture that models
            -- no betting at all.
            SecondsUntilBetsClose = function() return nil end,
            SettleSpectatorBets = function() end,
            RefundAll = function() end,
            Clear = function() end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    -- Loaded by hand here rather than through newArenaEnv, so the arenas are
    -- switched on by hand too. Nothing in this file is about which ones an
    -- operator ships enabled.
    Sandbox.enableAllArenas(env)
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
            arenaKey = 'trailerpark',
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

-- ========================================================================
-- THE FLAG FOLLOWING THE BUCKET
--
-- The sweep above is wider than the arena's own choke point: sendEnterArena
-- raises the dispatch flag for FIGHTERS as it instances them, while the
-- sweep instances match.spectators too and raised nothing. So a spectator
-- sat inside the match instance -- their client receiving every shot of the
-- round -- while the state bag an operator's dispatch script reads still
-- said they had never been near an arena, and nothing that client raised
-- was suppressed.
--
-- These four hold the flag and the bucket together on the one call site
-- that owns both: raised for a spectator, dropped for a spectator, NOT
-- taken off an eliminated fighter who is in both tables, and NOT put on a
-- lobby that is merely counting down.
-- ========================================================================

t.test('a spectator put in the arena instance is published as being in the arena', function()
    local f = newArena({ [9] = 77 })
    local match = f.newMatch('m1', { 1, 2 })
    f.M.Start(match.id)
    f.step()

    f.lobby.AddSpectator(9, match.id)
    -- Registered, but nothing has been done to them yet. Flagging at
    -- registration rather than at the move is the same hole the flag has
    -- always refused: it is a record of what has been DONE to a player.
    t.isFalse(f.D.IsPlayerInArena(9))

    f.step()
    t.equals(f.bucketOf(9), 4210)
    t.isTrue(f.D.IsPlayerInArena(9))
    -- The match, not merely a boolean: a dispatch script keeping its own
    -- ignore list keys it by match id, and the enter event carries the same.
    t.equals(f.D.GetPlayerMatchId(9), 'm1')
end)

t.test('and the flag comes off in the same pass that lets the spectator out', function()
    local f = newArena({ [9] = 77 })
    local match = f.newMatch('m1', { 1, 2 })
    f.M.Start(match.id)
    f.step()

    f.lobby.AddSpectator(9, match.id)
    f.step()
    t.isTrue(f.D.IsPlayerInArena(9))

    f.lobby.RemoveSpectator(9)
    f.step()

    t.equals(f.bucketOf(9), 77)
    -- A flag that outlived the bucket is the worse half of the pair: the
    -- player is back in the ordinary world with their police and medical
    -- alerts suppressed for the rest of the session, and nothing anywhere
    -- says so.
    t.isFalse(f.D.IsPlayerInArena(9))
end)

t.test('an eliminated fighter who stays to watch is NOT unflagged mid-round', function()
    -- THE HAZARD IN THE PAIR ABOVE, and it is worse than the bug they fix.
    -- An eliminated player sits in match.players AND in match.spectators, so
    -- a clear driven off "the registry calls them a spectator" would strip
    -- the flag from somebody still standing in the instance of a round that
    -- is still being fought around them.
    --
    -- What holds it: match.players claims every fighter unconditionally
    -- while match.spectators only fills the gaps, and the exit half of the
    -- sweep reaches nobody a live match still claims.
    local f = newArena()
    local match = f.newMatch('m1', { 1, 2, 3 })
    f.M.Start(match.id)
    f.step()
    t.equals(match.state, 'live')
    t.isTrue(f.D.IsPlayerInArena(3))

    f.M.OnDeath(3, 1)
    -- In both tables, which is the whole point of this test.
    t.isTrue(match.spectators[3])
    t.isNotNil(match.players[3])
    -- Two still standing, so the round carries on around them rather than
    -- ending and sending everybody home before the sweep is asked anything.
    f.step()
    t.equals(match.state, 'live')

    t.isTrue(f.D.IsPlayerInArena(3))
    t.equals(f.D.GetPlayerMatchId(3), 'm1')
    t.equals(f.bucketOf(3), 4210)

    -- Still true a second later: a sweep that only got it right on the first
    -- pass would be a bug on a two-minute round.
    f.step()
    t.isTrue(f.D.IsPlayerInArena(3))

    -- AND FROM THE OTHER SIDE: they close the camera. server/lobby.lua drops
    -- them out of match.spectators and leaves the fighter row alone, so a
    -- clear keyed on "has stopped watching" rather than on the reconcile
    -- would fire right here -- on somebody still standing in the instance of
    -- a round still being fought around them.
    f.lobby.RemoveSpectator(3)
    f.step()

    t.equals(match.state, 'live')
    t.isTrue(f.D.IsPlayerInArena(3))
    t.equals(f.bucketOf(3), 4210)
end)

t.test('a lobby still counting down is not published as a fight', function()
    -- WHY THE SWEEP FLAGS SPECTATORS AND NOT FIGHTERS. `state` cannot tell
    -- the two countdowns apart: ArenaMatch.Begin uses 'countdown' for the
    -- LOBBY countdown, where nobody has been teleported anywhere, and
    -- ArenaMatch.Start uses the same name for the frozen one after moving
    -- the room in. Flagging everybody the sweep touches would therefore
    -- suppress the police and medical alerts of players standing in the
    -- middle of town waiting for a round to begin -- the exact hole
    -- ArenaDispatch.Set's own comment refuses to open -- and would make
    -- server/lobby.lua's playersArePlaced read a filling lobby as a round in
    -- progress and refuse its host the cancel button.
    --
    -- Only sendEnterArena raises a fighter's flag, and it runs when they are
    -- actually placed. This says nothing about where the lobby countdown
    -- leaves their routing bucket; that is a separate question.
    local f = newArena()
    local match = f.newMatch('m1', { 1, 2 })

    t.isTrue((f.M.Begin(match.id)))
    t.equals(match.state, 'countdown')

    -- Several sweeps' worth of the lobby countdown, which is ten seconds in
    -- the shipped config -- comfortably long enough to matter.
    f.step()
    f.step()
    f.step()

    t.isFalse(f.D.IsPlayerInArena(1))
    t.isFalse(f.D.IsPlayerInArena(2))
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
