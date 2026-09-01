--[[
    crimson_arena/tests/dispatch_spec.lua

    The real, unmodified server/dispatch.lua, loaded into a sandbox.

    This file exists because the flag it manages is the one piece of this
    resource that other people's scripts are meant to trust. A flag that
    outlives the match it belonged to does not fail loudly -- it quietly
    suppresses that player's police and medical alerts for the rest of their
    session, which is indistinguishable from "the dispatch script is broken"
    right up until somebody works out why one player can rob a bank in
    silence. Every test below is some version of that worry.

    WHAT IS STUBBED, and no more than that: Player(src).state:set,
    TriggerEvent, AddEventHandler, exports, and the two logging helpers
    server/util.lua would otherwise provide. Arena.IsKey comes from the real
    shared/arena.lua, because the guard in Set() genuinely depends on it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- One fresh, fully isolated load of server/dispatch.lua.
--- @param dispatchConfig table? -- replaces Config.Dispatch entirely when given
--- @return table fixture
local function newFixture(dispatchConfig)
    local bags = {}          -- [src] = last value written to that player's bag
    local bagWrites = {}     -- every write, in order, so a double-write shows up
    local events = {}        -- every TriggerEvent, in order
    local handlers = {}      -- AddEventHandler registrations
    local logs = {}
    local commands = {}      -- every ExecuteCommand line, in order
    local cancelled = 0      -- how many times CancelEvent() was called
    local toClients = {}     -- every TriggerClientEvent, in order
    local netRegistered = {} -- every RegisterNetEvent name, in order
    local threads = {}       -- every CreateThread body, in order
    local registeredCommands = {}  -- name -> handler
    local timeouts = {}      -- every SetTimeout body, in order
    local exportCalls = {}   -- every exports['res']:Name(...) call, in order
    local resourceStates = {}      -- name -> what GetResourceState reports

    local env = Sandbox.newEnv({
        ExecuteCommand = function(line) commands[#commands + 1] = line end,
        CancelEvent = function() cancelled = cancelled + 1 end,
        -- /arenarevive registers at load. Captured so a spec can run it
        -- directly instead of needing a whole round to reach the revive.
        RegisterCommand = function(name, fn) registeredCommands[name] = fn end,
        -- CAPTURED, NOT RUN. The permission grant runs in a thread so the
        -- command system is up before it adds to it; running it inline at
        -- load would test a different order to the real one. step() below is
        -- how a test asks for it.
        CreateThread = function(fn) threads[#threads + 1] = fn end,
        Wait = function() end,
        -- The cancel layer registers each alert event for the network before
        -- listening: without that, FXServer never delivers a client-triggered
        -- event to this resource at all. Recorded so a spec can assert it.
        RegisterNetEvent = function(name) netRegistered[#netRegistered + 1] = name end,
        TriggerClientEvent = function(name, target, ...)
            toClients[#toClients + 1] = { name = name, target = target, args = { ... } }
        end,
        Player = function(src)
            return {
                state = {
                    set = function(_self, key, value, replicated)
                        bags[src] = value
                        bagWrites[#bagWrites + 1] =
                            { src = src, key = key, value = value, replicated = replicated }
                    end,
                },
            }
        end,
        TriggerEvent = function(name, ...)
            events[#events + 1] = { name = name, args = { ... } }
        end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- 'missing' unless a spec says otherwise, which is the state the
        -- retract layer has to survive: an operator naming a resource they do
        -- not run must get one console line, never a broken alert handler.
        GetResourceState = function(name) return resourceStates[name] or 'missing' end,
        -- CAPTURED, NOT RUN, for the same reason CreateThread is. The
        -- withdrawal is deliberately deferred past the sending resource's own
        -- handler, and a spec that ran it inline would be testing an ordering
        -- the server never produces. runTimeouts() below is how a test asks
        -- for it.
        SetTimeout = function(_ms, fn) timeouts[#timeouts + 1] = fn end,
        -- __call is `exports('Name', fn)`, which this file uses to publish
        -- its own exports. __index is `exports['res']:Name(...)`, which the
        -- retract layer uses to reach somebody else's -- recorded rather than
        -- performed, so a spec can assert on exactly what was asked of it.
        exports = setmetatable({}, {
            __call = function() end,
            __index = function(_t, resource)
                return setmetatable({}, {
                    __index = function(_t2, name)
                        return function(_self, ...)
                            exportCalls[#exportCalls + 1] =
                                { resource = resource, export = name, args = { ... } }
                        end
                    end,
                })
            end,
        }),
        ArenaLog = function(fmt, ...) logs[#logs + 1] = (select('#', ...) > 0) and fmt:format(...) or fmt end,
        ArenaDebug = function() end,
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if dispatchConfig ~= nil then env.Config.Dispatch = dispatchConfig end

    -- AFTER the env exists, not inside its constructor. A closure written in
    -- the table above would capture a GLOBAL `env` -- nil -- rather than the
    -- local being declared by that very statement, and every lookup through
    -- it would quietly return nothing.
    --
    -- The location pin asks the lobby which arena a live match is in.
    -- Answered with the first enabled arena, which is where arenaPoints()
    -- takes its coordinates from, so the two agree by construction rather
    -- than through a hard-coded key.
    env.ArenaLobby = {
        Get = function(matchId)
            local first = env.Arena.GetEnabledArenas()[1]
            if not first then return nil end
            return { id = matchId, arenaKey = first.key }
        end,
    }

    Sandbox.loadInto('../server/dispatch.lua', env)

    return {
        env = env,
        D = env.ArenaDispatch,
        bag = function(src) return bags[src] end,
        bagWrites = bagWrites,
        events = events,
        logs = logs,
        commands = commands,
        --- Runs every handler registered for `name`, the way FXServer would.
        fire = function(name, ...)
            for _, fn in ipairs(handlers[name] or {}) do fn(...) end
        end,
        --- How many times CancelEvent() has been called so far.
        --- A function, not a number: a number captured here would be the
        --- value at construction -- zero, forever -- and every assertion
        --- against it would pass without the code under test running.
        cancelled = function() return cancelled end,
        toClients = toClients,
        netRegistered = netRegistered,
        --- Runs every thread this load started, once, in order.
        --- Runs a registered command as `src` with `args`.
        runCommand = function(name, src, args)
            local fn = registeredCommands[name]
            if not fn then error('no command registered called ' .. tostring(name), 2) end
            fn(src, args or {})
        end,
        step = function()
            local pending = threads
            threads = {}
            for _, fn in ipairs(pending) do fn() end
        end,
        --- Every exports['res']:Name(...) the code under test made, in order.
        exportCalls = exportCalls,
        --- Tells GetResourceState that `name` is running.
        setResource = function(name, state) resourceStates[name] = state or 'started' end,
        --- Runs every SetTimeout body this load queued, once, in order.
        runTimeouts = function()
            local pending = timeouts
            timeouts = {}
            for _, fn in ipairs(pending) do fn() end
        end,
        eventNames = function()
            local out = {}
            for _, e in ipairs(events) do out[#out + 1] = e.name end
            return table.concat(out, ',')
        end,
    }
end

-- ========================================================================
-- The flag itself
-- ========================================================================

t.test('Set flags the player, writes a replicated bag, and announces entry', function()
    local f = newFixture()
    f.D.Set(7, 'match-1')

    t.isTrue(f.D.IsPlayerInArena(7))
    t.equals(f.D.GetPlayerMatchId(7), 'match-1')

    local write = f.bagWrites[1]
    t.equals(write.src, 7)
    t.equals(write.key, 'crimsonArena')
    t.equals(write.value.active, true)
    t.equals(write.value.matchId, 'match-1')
    -- Unreplicated, the bag is invisible to the client half of any dispatch
    -- script that reads it -- which is half the point of publishing it.
    t.isTrue(write.replicated)

    t.equals(#f.events, 1)
    t.equals(f.events[1].name, 'crimson_arena:dispatch:enter')
    t.equals(f.events[1].args[1], 7)
    t.equals(f.events[1].args[2], 'match-1')
end)

t.test('Clear unflags, nils the bag, and announces the exit', function()
    local f = newFixture()
    f.D.Set(7, 'match-1')
    f.D.Clear(7)

    t.isFalse(f.D.IsPlayerInArena(7))
    t.isNil(f.D.GetPlayerMatchId(7))
    t.isNil(f.bag(7))
    t.equals(f.eventNames(), 'crimson_arena:dispatch:enter,crimson_arena:dispatch:exit')
end)

t.test('Clear announces even for somebody who was never flagged', function()
    -- A dispatch script that missed the entry -- it restarted, or was not
    -- running yet -- would otherwise keep that player ignored forever. A
    -- clear for somebody never flagged is a harmless no-op on its side.
    local f = newFixture()
    f.D.Clear(99)
    t.equals(#f.events, 1)
    t.equals(f.events[1].name, 'crimson_arena:dispatch:exit')
    t.isNil(f.events[1].args[2])
end)

t.test('Set refuses rubbish rather than flagging on it', function()
    local f = newFixture()
    f.D.Set(nil, 'match-1')
    f.D.Set(0, 'match-1')
    f.D.Set(-3, 'match-1')
    f.D.Set('7', 'match-1')
    f.D.Set(7, nil)
    f.D.Set(7, '')
    f.D.Set(7, {})

    t.equals(#f.bagWrites, 0)
    t.equals(#f.events, 0)
    t.equals(next(f.D.GetArenaPlayers()), nil)
end)

t.test('GetArenaPlayers hands back a copy, not the live record', function()
    local f = newFixture()
    f.D.Set(1, 'm')
    local snapshot = f.D.GetArenaPlayers()
    snapshot[1] = 'tampered'
    snapshot[2] = 'invented'

    t.equals(f.D.GetPlayerMatchId(1), 'm')
    t.isNil(f.D.GetPlayerMatchId(2))
end)

-- ========================================================================
-- Operator configuration
-- ========================================================================

t.test('a renamed stateBagKey is the one actually written', function()
    local f = newFixture({ custom = { stateBagKey = 'inTheArena' } })
    f.D.Set(4, 'm')
    t.equals(f.bagWrites[1].key, 'inTheArena')
end)

t.test('an absent or empty stateBagKey falls back rather than writing a nameless bag', function()
    for _, key in ipairs({ '', 42, {} }) do
        local f = newFixture({ custom = { stateBagKey = key } })
        f.D.Set(4, 'm')
        t.equals(f.bagWrites[1].key, 'crimsonArena')
    end

    local none = newFixture({ custom = {} })
    none.D.Set(4, 'm')
    t.equals(none.bagWrites[1].key, 'crimsonArena')
end)

t.test('an event name set to nil fires nothing, and the flag still works', function()
    local f = newFixture({ custom = { enterEvent = nil, exitEvent = nil } })
    f.D.Set(4, 'm')
    f.D.Clear(4)

    t.equals(#f.events, 0)
    t.equals(#f.bagWrites, 2)
end)

t.test('a non-string event name is refused rather than passed to TriggerEvent', function()
    local f = newFixture({ custom = { enterEvent = 12345, exitEvent = {} } })
    f.D.Set(4, 'm')
    f.D.Clear(4)
    t.equals(#f.events, 0)
end)

t.test('an entirely missing Config.Dispatch.custom still flags and still writes', function()
    local f = newFixture({})
    f.D.Set(4, 'm')
    t.isTrue(f.D.IsPlayerInArena(4))
    t.equals(f.bagWrites[1].key, 'crimsonArena')
    t.equals(#f.events, 0)
end)

-- ========================================================================
-- Somebody else's handler misbehaving
-- ========================================================================

t.test('a dispatch handler that throws does not take the caller down with it', function()
    local f = newFixture()
    f.env.TriggerEvent = function() error('their bug, not ours') end

    -- The flag must still be set: a broken listener on the far side cannot be
    -- allowed to stop this resource tracking who is in a match, or a match
    -- start would fail on somebody else's typo.
    local ok = pcall(f.D.Set, 5, 'm')
    t.isTrue(ok)
    t.isTrue(f.D.IsPlayerInArena(5))
    t.equals(#f.logs, 1)
end)

-- ========================================================================
-- Resync, and shutdown
-- ========================================================================

t.test('a named dispatch resource restarting re-announces everyone still fighting', function()
    local f = newFixture({ custom = {
        enterEvent = 'crimson_arena:dispatch:enter',
        exitEvent = 'crimson_arena:dispatch:exit',
        resyncResources = { 'my_dispatch' },
    } })
    f.D.Set(1, 'm1')
    f.D.Set(2, 'm1')
    local before = #f.events

    f.fire('onResourceStart', 'my_dispatch')

    t.equals(#f.events - before, 2)
    t.equals(f.events[#f.events].name, 'crimson_arena:dispatch:enter')
end)

t.test('an unrelated resource restarting announces nothing', function()
    local f = newFixture({ custom = {
        enterEvent = 'crimson_arena:dispatch:enter',
        resyncResources = { 'my_dispatch' },
    } })
    f.D.Set(1, 'm1')
    local before = #f.events

    f.fire('onResourceStart', 'some_other_script')
    f.fire('onResourceStart', 'crimson_arena')

    t.equals(#f.events, before)
end)

t.test('resync with nobody in an arena is silent, not an empty announcement', function()
    local f = newFixture({ custom = {
        enterEvent = 'crimson_arena:dispatch:enter',
        resyncResources = { 'my_dispatch' },
    } })
    f.fire('onResourceStart', 'my_dispatch')
    t.equals(#f.events, 0)
    t.equals(#f.logs, 0)
end)

t.test('no resyncResources means no resync, whatever restarts', function()
    local f = newFixture()
    f.D.Set(1, 'm1')
    local before = #f.events
    f.fire('onResourceStart', 'my_dispatch')
    t.equals(#f.events, before)
end)

t.test('stopping this resource leaves nobody flagged', function()
    -- A dispatch script outliving a restart would otherwise keep reading a
    -- stale bag and keep suppressing alerts for players standing in town.
    local f = newFixture()
    f.D.Set(1, 'm1')
    f.D.Set(2, 'm1')
    f.D.Set(3, 'm2')

    f.fire('onResourceStop', 'crimson_arena')

    t.equals(next(f.D.GetArenaPlayers()), nil)
    t.isNil(f.bag(1))
    t.isNil(f.bag(2))
    t.isNil(f.bag(3))
end)

t.test('another resource stopping leaves the flags alone', function()
    local f = newFixture()
    f.D.Set(1, 'm1')
    f.fire('onResourceStop', 'some_other_script')
    t.isTrue(f.D.IsPlayerInArena(1))
end)

print('dispatch_spec')
--- shared/compat/dispatch.lua loaded on its own, with the handful of natives
--- it reaches for at load time.
---
--- It is the one shared file that calls natives, and it decides which half of
--- itself to run from IsDuplicityVersion() -- so that answer is the fixture's
--- most important stub rather than a detail. Server side here: the report is
--- printed from both realms, and the server's is the one an operator reads.
--- @param mutate fun(config: table)?
--- @return table env
local function newCompat(mutate)
    local env = Sandbox.newArenaEnv({
        IsDuplicityVersion = function() return true end,
        GetResourceState = function() return 'missing' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        CreateThread = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        Wait = function() end,
        ArenaIsAdmin = function() return false end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
    })

    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../shared/compat/dispatch.lua', env)
    return env
end

-- ========================================================================
-- CANCELLING AN ALERT THAT SAYS ONLY *WHERE*
--
-- Some alert events carry no player. A resource raises them on the server
-- with a payload describing where something happened and nothing about who,
-- so `source` is meaningless and no argument holds a server id -- the
-- player pin has nothing to work with and the alert goes out.
--
-- The location is the one thing such a payload does have, and an arena is a
-- place. Requiring a LIVE match is the whole safety of it: these arenas sit
-- on real map locations that ordinary play uses the rest of the time, and
-- suppressing every alert that ever happens at an airfield would silence
-- real crimes -- a worse failure than the one this fixes.
-- ========================================================================

--- A dispatch config whose one cancel entry is pinned on location.
local function locationConfig()
    return {
        stateBagKey = 'crimsonArena',
        isolation = { enabled = false },
        custom = {
            enabled = true,
            disableExports = {},
            cancelEvents = { { event = 'alerts:raise', coordsArg = 1 } },
        },
        vanillaPolice = { enabled = false },
        revive = { enabled = false, commands = {}, serverEvents = {}, clientEvents = {}, exports = {} },
    }
end

--- The centre of the first shipped arena, and a point well outside it.
local function arenaPoints(env)
    local arena = env.Arena.GetEnabledArenas()[1]
    local b = env.Config.Arenas[arena.key].boundary
    return b.center, { x = b.center.x + (b.radius * 4), y = b.center.y, z = b.center.z }
end

-- ========================================================================
-- THE CANCEL LAYER HAS TO BE REGISTERED FOR THE NETWORK
--
-- THE DEFECT THIS EXISTS FOR. FXServer routes a network-sourced event only
-- to resources that have called RegisterNetEvent for that name. A resource
-- with AddEventHandler alone is never delivered it: no error, no warning,
-- the handler simply never runs.
--
-- Every alert a script raises with TriggerServerEvent from the player's own
-- client -- which is how gunfire and deaths are reported, because that is
-- where they are detected -- therefore passed this resource without touching
-- it. The whole layer was inert for the events it was written for, and the
-- startup report counted them as configured the entire time.
-- ========================================================================

t.test('every cancelEvents entry is registered for the network, not just listened for', function()
    local f = newFixture(locationConfig())

    t.equals(#f.netRegistered, 1,
        'the alert event was never registered for the network, so a client-triggered alert never arrives')
    t.equals(f.netRegistered[1], 'alerts:raise')
end)

t.test('the shipped sc-dispatch entries are the events those resources really raise', function()
    -- The config that actually ships, rather than a fixture's.
    --
    -- THIS TEST USED TO PASS ON TWO EVENT NAMES THAT DO NOT EXIST.
    -- 'sc-dispatch:server:AddNotification' and 'sc-dispatch:AddNotification'
    -- appear nowhere in sc-dispatch or sc-ambulance -- AddNotification is an
    -- EXPORT, and the events one step upstream of it are the four below. The
    -- old assertions were green the whole time the layer was listening to
    -- silence, which is exactly the failure a test is supposed to catch, so
    -- this one now names the events read off those resources' own source.
    local f = newFixture()

    local names = table.concat(f.netRegistered, ',')
    t.contains(names, 'sc-dispatch:server:ShotsFired',
        'the gunfire path is not registered -- it is the one that carries arena shots-fired alerts')
    t.contains(names, 'hospital:server:EMSDownAlert',
        'the "10-52 person down" path is not registered')
    t.contains(names, 'hospital:server:ambulanceAlert')
    t.contains(names, 'mydispatch:requestEMS')
end)

-- ========================================================================
-- WITHDRAWING AN ALERT THAT WAS ALREADY CREATED
--
-- THE DEFECT THESE EXIST FOR. CancelEvent() raises a flag and stops nothing:
-- Cfx's own documentation is explicit that it does not prevent another
-- resource's handler running, and sc-dispatch never calls
-- WasEventCanceled(). So the cancel layer above -- with the right event
-- names or the wrong ones -- was never going to stop a single 10-71. Police
-- and EMS were paged to every round, and the config said the alerts were
-- handled.
--
-- Withdrawal is what actually removes the call. These specs pin the two
-- halves that make it safe: it fires for a player who is IN a match, and it
-- rebuilds the id out of that player's OWN server id, so it can never reach
-- somebody else's call.
-- ========================================================================

t.test('an arena alert is withdrawn, not merely cancelled', function()
    local f = newFixture()
    f.setResource('sc-dispatch')
    f.D.Set(7, 'match-1')

    local at = os.time()
    f.env.source = 7
    f.fire('sc-dispatch:server:ShotsFired', { coords = { x = 0.0, y = 0.0, z = 0.0 } })

    -- Nothing yet: the withdrawal is deferred past the sending resource's own
    -- handler on purpose. Clearing a call that has not been inserted clears
    -- nothing at all, which is the failure this delay exists for.
    t.equals(#f.exportCalls, 0,
        'the withdrawal ran inline, so it would clear a call sc-dispatch has not created yet')

    f.runTimeouts()

    t.isTrue(#f.exportCalls > 0, 'the call was cancelled and then left standing')
    t.equals(f.exportCalls[1].resource, 'sc-dispatch')
    t.equals(f.exportCalls[1].export, 'ClearNotification')

    local ids = {}
    for _, call in ipairs(f.exportCalls) do ids[#ids + 1] = tostring(call.args[1]) end
    t.contains(table.concat(ids, ','), ('shots_7_%d'):format(at),
        'the id withdrawn is not the one sc-dispatch files a shots-fired call under')
end)

t.test('every id withdrawn carries the arena player\'s own server id', function()
    -- THE SAFETY OF THE WHOLE LAYER. The clock slack widens the TIMESTAMP,
    -- because the two handlers can straddle a one-second boundary. It must
    -- never widen the PLAYER: withdrawing a stranger's call is the same harm
    -- as cancelling their alert, arrived at from the other direction.
    local f = newFixture()
    f.setResource('sc-dispatch')
    f.D.Set(7, 'match-1')

    f.env.source = 7
    f.fire('sc-dispatch:server:ShotsFired', {})
    f.runTimeouts()

    for _, call in ipairs(f.exportCalls) do
        t.contains(tostring(call.args[1]), '_7_',
            'an id was withdrawn for somebody other than the arena player')
    end
end)

t.test('nothing is withdrawn for a player who is not in a match', function()
    local f = newFixture()
    f.setResource('sc-dispatch')

    f.env.source = 7
    f.fire('sc-dispatch:server:ShotsFired', {})
    f.runTimeouts()

    t.equals(#f.exportCalls, 0,
        'a real shots-fired call from an ordinary player was withdrawn')
end)

t.test('a retract resource that is not running costs one line, not a broken handler', function()
    -- This runs inside somebody else's event handler. An error raised here
    -- would surface as that resource misbehaving, which is a worse bug than
    -- the one being fixed -- so a missing resource must degrade, never throw.
    local f = newFixture()
    f.D.Set(7, 'match-1')

    f.env.source = 7
    f.fire('sc-dispatch:server:ShotsFired', {})
    f.runTimeouts()

    t.equals(#f.exportCalls, 0)
    t.contains(table.concat(f.logs, '\n'), 'not started')
end)

t.test('the jobs an alert names are reported, so EMS and police can be told apart', function()
    -- On this family of dispatch scripts police and EMS alerts travel the
    -- SAME event and differ only by the jobs in the payload -- so "police
    -- went quiet but the ambulance did not" is not something that event can
    -- do. Printing the jobs turns that from a guess into an observation.
    local f = newFixture(locationConfig())
    f.D.Set(1, 'm1')

    f.env.source = 1
    f.fire('alerts:raise', { job_table = { 'ambulance', 'doctor' }, title = '10-52' })

    t.contains(table.concat(f.logs, '\n'), 'ambulance, doctor',
        'an EMS alert arrived and nothing recorded which kind it was')
end)

t.test('and a payload that names no jobs is not invented for', function()
    local f = newFixture(locationConfig())
    f.D.Set(1, 'm1')

    f.env.source = 1
    f.fire('alerts:raise', { title = 'no jobs here' })

    t.notContains(table.concat(f.logs, '\n'), 'an alert for [',
        'jobs were reported for a payload that named none')
end)

t.test('a location-declared entry is pinned by location or not at all', function()
    -- The over-cancel this closes: with the point outside every arena, the
    -- handler used to fall through to the ambient `source`, which FiveM
    -- leaves set to whoever triggered the outermost net event. An alert
    -- about somewhere else, raised anywhere inside an arena player's call
    -- chain, was cancelled on the strength of who was on top of the stack.
    local f = newFixture(locationConfig())
    local _, outside = arenaPoints(f.env)

    f.D.Set(1, 'm1')
    f.env.source = 1                       -- an arena player is on the stack
    f.fire('alerts:raise', { coords = outside })

    t.equals(f.cancelled(), 0,
        'an alert about somewhere else was cancelled because an arena player triggered the chain')
end)

t.test('an alert about a spot inside a live arena is cancelled', function()
    local f = newFixture(locationConfig())
    local inside = arenaPoints(f.env)

    -- Somebody is in a match at that arena.
    f.D.Set(1, 'm1')
    f.fire('alerts:raise', { coords = inside, title = '10-13' })

    t.isTrue(f.cancelled() > 0, 'an alert from inside a live arena went out')
end)

t.test('the same alert is left alone with no match running', function()
    -- The safety line. Outside a match these coordinates are an ordinary
    -- airfield, and an alert about one is somebody else's business.
    local f = newFixture(locationConfig())
    local inside = arenaPoints(f.env)

    f.fire('alerts:raise', { coords = inside, title = '10-13' })

    t.equals(f.cancelled(), 0, 'a real alert was suppressed with no match running')
end)

t.test('an alert from outside the boundary is left alone even mid-match', function()
    local f = newFixture(locationConfig())
    local _, outside = arenaPoints(f.env)

    f.D.Set(1, 'm1')
    f.fire('alerts:raise', { coords = outside, title = '10-13' })

    t.equals(f.cancelled(), 0, 'an alert from outside the arena was suppressed')
end)

t.test('a payload that is the point itself, not wrapped in coords, still pins', function()
    local f = newFixture(locationConfig())
    local inside = arenaPoints(f.env)

    f.D.Set(1, 'm1')
    f.fire('alerts:raise', inside)

    t.isTrue(f.cancelled() > 0, 'only the wrapped shape is recognised')
end)

t.test('a payload with no usable location is left alone rather than guessed at', function()
    local f = newFixture(locationConfig())
    f.D.Set(1, 'm1')

    f.fire('alerts:raise', { title = 'no location at all' })
    f.fire('alerts:raise', { coords = { x = 'north', y = 'west' } })
    f.fire('alerts:raise', 'not a table')

    t.equals(f.cancelled(), 0, 'something without a location was cancelled anyway')
end)

-- ========================================================================
-- TELLING THE AMBULANCE SCRIPT THEY ARE ALIVE
--
-- The arena stands its own dead back up. That is the whole job for the ped
-- and none of it for the server: a medical script keeps its own record and
-- nothing about resurrecting a ped reaches it, so a player who died walks
-- out still dead as far as that script is concerned.
--
-- Most servers' revive is a command -- `/revive <id>`, run by an admin --
-- rather than an event or an export, so that is the form these cover.
-- ========================================================================

--- A dispatch config with revive wired to one command template.
local function reviveConfig(template)
    return {
        enabled = true,
        stateBagKey = 'crimsonArena',
        isolation = { enabled = false },
        custom = { enabled = false, disableExports = {}, cancelEvents = {} },
        vanillaPolice = { enabled = false },
        revive = {
            enabled = true,
            commands = { template },
            serverEvents = {},
            clientEvents = {},
            exports = {},
        },
    }
end

t.test('the revive command runs with the player id substituted in', function()
    local f = newFixture(reviveConfig('revive %s'))
    f.D.Revive(7)

    t.equals(#f.commands, 1, 'the command did not run')
    t.equals(f.commands[1], 'revive 7', 'the wrong player was revived')
end)

-- ========================================================================
-- THIS RESOURCE ASKS THE SERVER FOR NO PERMISSIONS
--
-- It used to try to grant itself the rights its revive command needed: an
-- ace for the command, and failing that membership of the admin group. Both
-- are removed, and this section is what stops either coming back.
--
--   THEY DID NOT WORK. A server that lets a resource write its own
--   permissions is a server with no permissions, so the sensible ones
--   refuse -- and a refusal is not an error. ExecuteCommand returns
--   normally and the console prints "Access denied", so the resource
--   carried a page of settings for a capability it did not have.
--
--   THEY WERE NOT NEEDED. The arena revives its own players in code and
--   asks nobody's permission to undo something it did itself.
--
--   AND THE ADMIN ONE COST SOMETHING REAL. Group membership made any flaw
--   anywhere in this resource a way to run any command on the box.
-- ========================================================================

t.test('nothing is granted, ever, whatever the revive is configured to do', function()
    -- Not "unless asked for" -- there is nothing left to ask with. A
    -- resource that never writes a permission cannot hold one it should not.
    local f = newFixture(reviveConfig('revive %s'))
    f.step()

    local ran = table.concat(f.commands, '\n')
    t.notContains(ran, 'add_ace', 'this resource granted itself a permission')
    t.notContains(ran, 'add_principal', 'this resource put itself in a group')
end)

t.test('and the settings that used to do it are gone from config, not merely off', function()
    -- OFF IS NOT ENOUGH FOR THESE TWO. A setting that ships false but is
    -- documented as something you may switch on is an invitation, and what
    -- it invites here is "any flaw in this resource runs any command".
    --
    -- It is also the shape that caused the last round of this: one of the
    -- pair had a page of config describing when to turn it on, a stated
    -- default that disagreed with its own value, and no code reading it at
    -- all. Removing them is what makes the documentation true.
    local revive = Sandbox.newArenaEnv().Config.Dispatch.revive

    t.isNil(revive.grantSelfAdmin, 'grantSelfAdmin is back in config')
    t.isNil(revive.grantSelfPermission, 'grantSelfPermission is back in config')
    t.isNil(revive.adminGroups, "the revive's own admin group list is back in config")
end)

t.test('and no source file reaches for the permission natives at all', function()
    -- The removal is only real if nothing anywhere still calls them. Read
    -- off the files rather than trusted: a second copy of this in another
    -- file would pass every test above.
    for _, path in ipairs({ '../server/dispatch.lua', '../server/main.lua', '../server/util.lua',
                            '../server/match.lua', '../server/lobby.lua', '../server/ammo.lua',
                            '../server/betting.lua', '../server/stats.lua' }) do
        local handle = assert(io.open(path, 'r'))
        local source = handle:read('a')
        handle:close()

        -- COMMENTS DO NOT COUNT. Both files explain, in prose, the
        -- server.cfg line an operator would write for themselves -- which is
        -- the whole point of the removal and must not be what fails this.
        local code = source:gsub('%-%-[^\n]*', '')

        -- The ExecuteCommand LINES, not the words: server/util.lua reads
        -- Config.Permissions.adminGroups to decide who may force-stop a
        -- match, which is a different thing entirely and stays.
        t.isNil(code:match('add_ace%s'), ('%s still writes an ace'):format(path))
        t.isNil(code:match('add_principal%s'), ('%s still writes a principal'):format(path))
        t.isNil(code:match('IsPrincipalAceAllowed'),
            ('%s still checks a permission it can no longer be granted'):format(path))
    end
end)

t.test('the shipped config still runs no console command at all', function()
    -- The remaining half of the same decision: with nothing granting itself
    -- anything, a configured command on a server that gates it is an
    -- "Access denied" line per death.
    local revive = Sandbox.newArenaEnv().Config.Dispatch.revive
    t.equals(#revive.commands, 0,
        'the shipped config runs a console command again -- on a server that gates it, that is an "Access denied" line per death')
end)

-- ========================================================================
-- TESTING THE REVIVE WITHOUT PLAYING A MATCH
--
-- The revive has been the hardest thing in this resource to get right, and
-- the reason is the feedback loop rather than the code: every attempt cost a
-- full round to learn one bit of information. /arenarevive fires the same
-- path on demand.
-- ========================================================================

t.test('/arenarevive runs the same path a finished match runs', function()
    local f = newFixture(reviveConfig('revive %s'))
    f.env.ArenaIsAdmin = function() return true end

    f.runCommand('arenarevive', 1, { '7' })

    t.equals(f.commands[1], 'revive 7', 'the command ran against the wrong player, or not at all')
end)

t.test('and defaults to whoever ran it, since that is the common case', function()
    -- An admin lying on the floor testing this on themselves should not have
    -- to look up their own server id first.
    local f = newFixture(reviveConfig('revive %s'))
    f.env.ArenaIsAdmin = function() return true end

    f.runCommand('arenarevive', 4, {})

    t.equals(f.commands[1], 'revive 4')
end)

t.test('a non-admin gets nothing, not even a revive of themselves', function()
    local f = newFixture(reviveConfig('revive %s'))
    f.env.ArenaIsAdmin = function() return false end

    f.runCommand('arenarevive', 9, { '9' })

    t.equals(#f.commands, 0, 'anybody could revive anybody by typing a command')
end)

t.test('/arenarevive still stands the player up when the handoff is switched off', function()
    -- THE REGRESSION THIS EXISTS FOR. The command used to return early here,
    -- logging "nothing would be called. Nothing was." -- true when the only
    -- revive was somebody else's command, and false the moment the arena
    -- started reviving players itself.
    --
    -- With `enabled = false` it was refusing to do the one thing that works,
    -- and telling an admin lying on the floor that nothing could be done for
    -- them. The switch governs telling OTHER scripts. It has never governed
    -- whether this resource picks its own players up.
    local config = reviveConfig('revive %s')
    config.revive.enabled = false

    local f = newFixture(config)
    f.env.ArenaIsAdmin = function() return true end

    f.runCommand('arenarevive', 1, { '3' })

    local revived = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:revive' then revived = message end
    end

    t.isNotNil(revived, 'the command refused to revive because the handoff to other scripts is off')
    t.equals(revived.target, 3, 'the wrong player was revived')

    t.equals(#f.commands, 0, 'a command ran despite the handoff being switched off')
    t.contains(table.concat(f.logs, '\n'), 'enabled is off',
        'nothing said why no other script was told')
end)

t.test('the arena revives the player itself, before anything is configured', function()
    -- THE CHANGE THAT MATTERS. Every route to somebody else's revive turned
    -- out to be shut: the command was refused because a resource may not run
    -- an admin command, and granting the permission was refused because a
    -- resource may not grant itself permissions -- which is correct, and is
    -- why that door exists.
    --
    -- So the arena stands its own players up directly and needs nobody's
    -- permission for it. This has to work on a config with NOTHING filled
    -- in, which is what this asserts.
    local f = newFixture({
        stateBagKey = 'crimsonArena',
        isolation = { enabled = false },
        custom = { disableExports = {}, cancelEvents = {} },
        vanillaPolice = { enabled = false },
        revive = { enabled = false, commands = {}, clientCommands = {}, serverEvents = {}, exports = {} },
    })

    f.D.Revive(5)

    local revived = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:revive' then revived = message end
    end

    t.isNotNil(revived, 'a player the arena knocked down was left on the floor by default')
    t.equals(revived.target, 5, 'the wrong player was revived')
    t.equals(#f.commands, 0, 'a command ran on a config that names none')
end)

t.test('the config AS SHIPPED revives, and runs no console command doing it', function()
    -- The test above proves the built-in revive works on an empty config.
    -- This one proves it on the config an operator actually downloads, which
    -- is a different question and the one that kept regressing: the code was
    -- right while the shipped defaults still pointed at an admin command
    -- this resource is not allowed to run.
    --
    -- Both halves matter. The revive has to happen, AND nothing may reach for
    -- the console to do it -- because a refused command is not an error, it
    -- is a line of "Access denied" per death with the player getting up
    -- anyway. That log is what made a working revive look broken.
    --
    -- newFixture() with no argument is the real ../config.lua, untouched.
    local f = newFixture()

    f.D.Revive(7)
    f.step()

    local revived = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:revive' then revived = message end
    end

    t.isNotNil(revived, 'the shipped config does not stand its own dead back up')
    t.equals(revived.target, 7, 'the shipped config revived the wrong player')

    local ran = table.concat(f.commands, '\n')
    t.equals(#f.commands, 0,
        'the shipped config runs a console command -- on a server that refuses it that is an "Access denied" line every death: ' .. ran)
end)

t.test('a client-side revive is sent to that player, and to nobody else', function()
    -- The failure this covers is silent by construction. A command
    -- registered CLIENT-side does not exist as far as the server console is
    -- concerned, so the server's own ExecuteCommand finds nothing, does
    -- nothing, and reports nothing wrong -- the arena says it revived
    -- everybody while every player is still on the floor.
    local config = reviveConfig('revive %s')
    config.revive.commands = {}
    config.revive.clientCommands = { 'revive' }

    local f = newFixture(config)
    f.D.Revive(9)

    t.equals(#f.commands, 0, 'a client command was run on the server console instead')

    -- FILTERED BY NAME NOW, because the arena's own revive is sent to the
    -- same client on the same path. Counting messages rather than naming
    -- them would make this test fail the moment a second, correct one
    -- appeared -- which is exactly what happened.
    local ran = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:runCommand' then ran = message end
    end

    t.isNotNil(ran, 'the client was never asked to run anything')
    t.equals(ran.target, 9, 'the wrong player was asked')
    t.equals(ran.args[1], 'revive')
end)

t.test('a client template WITH a placeholder still gets the id', function()
    local config = reviveConfig('revive %s')
    config.revive.commands = {}
    config.revive.clientCommands = { 'heal %s' }

    local f = newFixture(config)
    f.D.Revive(4)

    local ran = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:runCommand' then ran = message end
    end
    t.isNotNil(ran, 'the client was never asked to run anything')
    t.equals(ran.args[1], 'heal 4')
end)

t.test('both forms can run together, and each goes to its own realm', function()
    local config = reviveConfig('revive %s')
    config.revive.clientCommands = { 'revive' }

    local f = newFixture(config)
    f.D.Revive(6)

    t.equals(f.commands[1], 'revive 6', 'the server console line is gone')

    local sawRunCommand = false
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:runCommand' then sawRunCommand = true end
    end
    t.isTrue(sawRunCommand, 'the client line is gone')
end)

t.test('a server command that ran is reported, so a silent failure is visible', function()
    -- Running a command that has no effect looks exactly like running no
    -- command at all. An operator watching a player stay dead has to be able
    -- to tell those apart.
    local f = newFixture(reviveConfig('revive %s'))
    f.D.Revive(5)

    t.contains(table.concat(f.logs, '\n'), 'revive 5',
        'nothing was logged, so there is no way to tell the command ran')
end)

t.test('a template with no placeholder gets the id appended', function()
    -- 'revive' and 'revive %s' are both things an operator will reasonably
    -- write, and only one of them is documented. Guessing wrong here revives
    -- nobody, silently.
    local f = newFixture(reviveConfig('revive'))
    f.D.Revive(12)

    t.equals(f.commands[1], 'revive 12')
end)

t.test('a template that cannot be built is reported rather than run', function()
    -- A stray percent is a format error. Running the half-built line would
    -- be worse than not running it, and running nothing silently is how an
    -- operator concludes the arena is broken.
    local f = newFixture(reviveConfig('revive %q %d'))
    f.D.Revive(3)

    t.equals(#f.commands, 0, 'a malformed command line was executed anyway')
    t.contains(table.concat(f.logs, '\n'), 'revive',
        'nothing was logged, so the operator has no way to know')
end)

t.test('nothing runs while revive is switched off', function()
    local config = reviveConfig('revive %s')
    config.revive.enabled = false

    local f = newFixture(config)
    f.D.Revive(7)

    t.equals(#f.commands, 0, 'a disabled revive still ran a command')
end)

t.test('a bad server id never reaches the command line', function()
    -- The id is interpolated straight into a console command, so what may
    -- reach it is worth an assertion rather than an assumption.
    local f = newFixture(reviveConfig('revive %s'))
    f.D.Revive(nil)
    f.D.Revive(0)
    f.D.Revive(-1)
    f.D.Revive('7; quit')

    t.equals(#f.commands, 0, 'something other than a real server id was put on a command line')
end)

-- ========================================================================
-- THE REPORT SAYS WHETHER A DEAD PLAYER WILL COME BACK
--
-- Every other line of this report is about stopping alerts going OUT. This
-- one is about a player coming back, and it is here because the failure it
-- describes is completely silent: the arena stands its own dead back up, the
-- medical script keeps its own record and is never told, and the player
-- leaves the arena still dead with nothing in any console. An operator hits
-- that and concludes the arena is broken.
-- ========================================================================

t.test('an unconfigured revive is called out at start, with the consequence', function()
    -- Set up explicitly rather than leaned on: this resource now SHIPS with
    -- revive pointed at a /revive command, so the shipped config is the
    -- configured case and testing the warning against it would test nothing.
    local env = newCompat(function(config)
        config.Dispatch.revive = { enabled = false, commands = {}, serverEvents = {},
                                   clientEvents = {}, exports = {} }
    end)
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'revive: NOT configured')
    t.contains(report, 'still dead',
        'the report names the setting but never says what goes wrong without it')
    t.contains(report, 'Config.Dispatch.revive',
        'the report describes the problem but not where to fix it')
end)

t.test('and a configured one is reported as configured', function()
    local env = newCompat(function(config)
        config.Dispatch.revive = {
            enabled = true,
            serverEvents = { 'my_ambulance:server:revive' },
            clientEvents = {},
            exports = { { resource = 'my_ambulance', export = 'Revive' } },
        }
    end)

    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'revive: configured')
    t.notContains(report, 'revive: NOT configured')
end)

t.test('the shipped config reports the handoff as unconfigured -- and says the arena revives anyway', function()
    -- The default that ships is the one nearly every operator runs, so what
    -- it reports about itself is worth an assertion of its own.
    --
    -- It ships with NOTHING named, and that is correct: the only things it
    -- could name are another server's commands and events, and this resource
    -- cannot know them. Guessing produces a line that looks wired up and
    -- calls nothing, which is the worst of both.
    --
    -- So the report says NOT configured -- but the danger in that word is an
    -- operator reading it as "revives are broken" on an install where they
    -- work fine. They do work: the arena stands its own dead back up in code.
    -- The only thing missing is telling a SEPARATE medical script, so the
    -- report has to say both halves or it is scarier than the truth.
    local env = newCompat()
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'revive: NOT configured',
        'the shipped config claims a handoff it has not been given the names for')
    t.contains(report, 'stood back up by the arena',
        'the report says the handoff is missing without saying players still get up -- that reads as broken')
end)

t.test('enabled with nothing named counts as not configured', function()
    -- The trap: switching it on and leaving the lists empty looks configured
    -- in the file and calls nothing at run time. That has to read as OFF in
    -- the report, or the report is worse than not having one.
    local env = newCompat(function(config)
        config.Dispatch.revive = { enabled = true, commands = {}, serverEvents = {},
                                   clientEvents = {}, exports = {} }
    end)

    t.contains(table.concat(env.ArenaCompat.Report(), '\n'), 'revive: NOT configured')
end)

-- ========================================================================
-- NOTHING IN THE REPORT MAY BE OPTIMISTIC
--
-- This block is the only diagnostic an operator has, and all three defects
-- below are the same shape: the report sounding better than the setup it is
-- describing. Every one of them was reassuring, and every one of them left
-- police and EMS alerts going out of an arena.
--
-- The catalogue is the thread running through them. It is a list of names to
-- LOOK FOR, never a census -- so "recognised nothing" says nothing at all
-- about what this box runs, and must never be read as "nothing to do".
-- ========================================================================

--- newCompat, plus a say-so about which resources this box is running.
---
--- GetResourceState is re-read on every Detect() and never cached -- the
--- file says so and means it -- so replacing the stub after the load is
--- enough, and testing through the stub rather than around it keeps these
--- tests honest about how detection really answers.
--- @param runningNames string[] -- resources GetResourceState calls 'started'
--- @param mutate fun(config: table)?
--- @return table env
local function compatWith(runningNames, mutate)
    local env = newCompat(mutate)
    local started = {}
    for _, name in ipairs(runningNames) do started[name] = true end
    env.GetResourceState = function(name)
        return started[name] and 'started' or 'missing'
    end
    return env
end

t.test('the guard line is printed even when nothing was recognised by name', function()
    -- THE DEFECT. The paste block was gated on a count only a DETECTED row
    -- could ever raise, so it printed for a script the catalogue knew and
    -- stayed silent for one it did not -- leaving the operator running an
    -- uncatalogued dispatch script, the one person nothing else in this
    -- resource can help, with a report that named their problem and then
    -- withheld the fix.
    local env = compatWith({})
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'no police or EMS resource recognised by name')
    t.contains(report, 'Paste at the top of whatever sends the alert',
        'nothing was recognised, so nothing is wired -- and the line was withheld')
    t.contains(report, 'if Player(src).state.crimsonArena then return end')
    t.contains(report, 'if LocalPlayer.state.crimsonArena then return end')
end)

t.test('and withheld once an operator hook really reaches a running script', function()
    -- The other half of the same contract. A line that prints unconditionally
    -- is wallpaper, and an operator who has done the work has to be able to
    -- see that they have.
    local env = compatWith({ 'my_dispatch' }, function(config)
        config.Dispatch.custom.disableExports = {
            { resource = 'my_dispatch', export = 'SetIgnoredPlayer' },
        }
    end)

    t.notContains(table.concat(env.ArenaCompat.Report(), '\n'), 'Paste at the top')
end)

t.test('a disableExport naming a script that is not running counts for nothing', function()
    -- client/dispatch.lua skips exactly this entry at run time and says so in
    -- the console, so crediting it here would report an integration that
    -- never fires -- the same lie by a different route.
    local env = compatWith({}, function(config)
        config.Dispatch.custom.disableExports = {
            { resource = 'removed_dispatch', export = 'SetIgnoredPlayer' },
        }
    end)

    t.contains(table.concat(env.ArenaCompat.Report(), '\n'), 'Paste at the top')
end)

t.test('cancelEvents on its own is never counted as wired up', function()
    -- config.lua's own instruction, in its own words: if this is the only
    -- form on the list you have filled in, assume the alerts are still being
    -- sent. The report has to agree with the config that documents it.
    local env = compatWith({ 'my_dispatch' })
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'cancelEvent(s)',
        'the shipped config has none, so this test proves nothing')
    t.contains(report, 'Paste at the top')
end)

t.test('isolation keeps its caveat when nothing is confirmed wired', function()
    -- THE DEFECT. Isolation on plus nothing detected printed a flat "no OTHER
    -- player's client can see the fight" -- true, and the most misleading true
    -- sentence available, because the alerts an arena player's OWN client
    -- raises are precisely the ones still going out. The caveat was dropped in
    -- the one branch it exists for.
    local env = compatWith({})
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'Isolation is on')
    t.contains(report, 'own client still can',
        'isolation was reported as though it settled the matter')
    t.contains(report, 'nothing here is confirmed wired')
end)

t.test('and drops it once every detected resource is accounted for', function()
    local env = compatWith({ 'ps-dispatch' }, function(config)
        config.Dispatch.custom.disableExports = {
            { resource = 'ps-dispatch', export = 'SetIgnoredPlayer' },
        }
    end)
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'Isolation is on')
    t.notContains(report, 'own client still can')
end)

t.test('the caveat and the line it promises appear together or not at all', function()
    -- The caveat ends "that is what the line below is for", so a run where one
    -- prints without the other is a report contradicting itself on screen.
    -- Isolation ships on, which is the case the caveat is written for.
    local cases = { {}, { 'my_dispatch' }, { 'ps-dispatch' } }

    for _, running in ipairs(cases) do
        local report = table.concat(compatWith(running).ArenaCompat.Report(), '\n')
        local promised = report:find('that is what the line below is for', 1, true) ~= nil
        local printed = report:find('Paste at the top', 1, true) ~= nil

        t.equals(promised, printed,
            'the isolation caveat and the paste block disagreed about whether anything is wired')
    end
end)

t.test('the shipped entry/exit event names are not reported as configuration', function()
    -- THE DEFECT. config.lua ships both names non-nil, so hookLine() read an
    -- untouched install as an operator who had wired up entry/exit events.
    -- A name is not a listener: the events were firing into an empty room and
    -- the report called it an integration.
    local env = compatWith({})
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.notContains(report, 'Hooks configured: entry/exit events',
        'a shipped default was counted as something the operator had built')
    t.contains(report, 'nothing here can see a listener',
        'the events do still fire, and the report has to say so rather than go quiet')
end)

t.test('but they are, once a resource named in resyncResources is running', function()
    -- And not by comparing names against the shipped default: what earns the
    -- credit is something demonstrably riding the events, so renaming them
    -- changes nothing.
    local env = compatWith({ 'my_dispatch' }, function(config)
        config.Dispatch.custom.enterEvent = 'my_arena:enter'
        config.Dispatch.custom.exitEvent = 'my_arena:exit'
        config.Dispatch.custom.resyncResources = { 'my_dispatch' }
    end)
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'Hooks configured: entry/exit events')
    t.notContains(report, 'nothing here can see a listener')
end)

t.test('a resyncResources entry for a script that is not running earns nothing', function()
    local env = compatWith({}, function(config)
        config.Dispatch.custom.resyncResources = { 'my_dispatch' }
    end)
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.notContains(report, 'Hooks configured: entry/exit events')
    t.contains(report, 'Paste at the top')
end)

-- ========================================================================
-- THE VANILLA POLICE BLOCK, AND THE SWITCH THAT USED TO SIT ABOVE IT
--
-- THE DEFECT THESE EXIST FOR. Config.Dispatch opened with a key named
-- `suppressPoliceShotsFired`, introduced as one of "the two switches you
-- actually came here for" and shipped true. Its only reader was inside the
-- `vanillaPolice` branch of client/dispatch.lua, and that branch is gated on
-- `vanillaPolice.enabled`, which ships FALSE. So on a stock config the key
-- did nothing in either position -- and it was the first thing an operator
-- whose police still turned up at a round would reach for, and the one thing
-- that could not have been the cause.
--
-- The key is gone from config.lua and the branch is gated on
-- `vanillaPolice.enabled` alone. Both halves are asserted below, separately,
-- because either one can be put back on its own and the trap is back.
--
-- These are the only tests in this suite that load the REAL
-- client/dispatch.lua. Its natives are recorded by name rather than
-- emulated: the whole question here is whether a given config reaches them.
-- ========================================================================

--- One fresh load of client/dispatch.lua against the REAL shipped config,
--- with `mutate` free to change Config.Dispatch before the file sees it.
--- @param mutate fun(dispatch: table)?
--- @return table fixture
local function newClientFixture(mutate)
    local calls = {}    -- every recorded native, in call order

    local function record(name, value)
        return function()
            calls[#calls + 1] = name
            return value
        end
    end

    local env = Sandbox.newEnv({
        exports = setmetatable({}, { __call = function() end }),
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        ExecuteCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        print = function() end,

        PlayerId = function() return 0 end,
        PlayerPedId = function() return 11 end,

        -- The vanilla wanted system. Every one of these is recorded, so
        -- "touched nothing" is provable rather than assumed.
        SetPoliceIgnorePlayer = record('SetPoliceIgnorePlayer'),
        SetDispatchCopsForPlayer = record('SetDispatchCopsForPlayer'),
        GetPlayerWantedLevel = record('GetPlayerWantedLevel', 3),
        SetPlayerWantedLevel = record('SetPlayerWantedLevel'),
        SetPlayerWantedLevelNow = record('SetPlayerWantedLevelNow'),

        -- The dead-state side, for the switch that survived.
        GetEntityCoords = function() return { 1.0, 2.0, 3.0 } end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityMaxHealth = function() return 200 end,
        NetworkResurrectLocalPlayer = record('NetworkResurrectLocalPlayer'),
        SetEntityInvincible = record('SetEntityInvincible'),
        SetEntityVisible = record('SetEntityVisible'),
        SetEntityCollision = record('SetEntityCollision'),
        FreezeEntityPosition = record('FreezeEntityPosition'),
        SetEntityHealth = record('SetEntityHealth'),
    })

    Sandbox.loadInto('../config.lua', env)
    if mutate then mutate(env.Config.Dispatch) end
    Sandbox.loadInto('../client/dispatch.lua', env)

    return {
        env = env,
        D = env.ArenaDispatch,
        calls = calls,
        --- Whether a native was reached at all, by name.
        called = function(name)
            for _, seen in ipairs(calls) do
                if seen == name then return true end
            end
            return false
        end,
    }
end

t.test('the shipped config declares no suppressPoliceShotsFired switch', function()
    -- THE CONTRACT, stated: a key at the top of Config.Dispatch is read as
    -- something an operator can act on, so a key up there whose only reader
    -- lives inside a block that ships off must not exist. Put it back and
    -- this goes red, which is the whole job of this test.
    local f = newClientFixture()

    t.isNil(f.env.Config.Dispatch.suppressPoliceShotsFired,
        'the unreachable police switch is back at the top of Config.Dispatch')
end)

t.test('as shipped, entering a match touches no vanilla police native', function()
    -- The other half of the same fact, and the reason that key was
    -- unreachable rather than merely redundant.
    local f = newClientFixture()

    t.isFalse(f.env.Config.Dispatch.vanillaPolice.enabled,
        'vanillaPolice now ships ON, so this whole block is asserting the wrong world')

    f.D.Enter('match-1')
    t.equals(#f.calls, 0, 'the vanilla wanted system was touched on a stock config')
end)

t.test('vanillaPolice.enabled is the whole gate -- nothing above it can veto it', function()
    -- THE REGRESSION GUARD. The gate used to read
    --     vanilla.enabled == true and config.suppressPoliceShotsFired ~= false
    -- so a config could switch the block on and have a top-level key switch
    -- it silently back off. This sets exactly that pair, so restoring the old
    -- gate fails here rather than passing quietly on a nil.
    local f = newClientFixture(function(dispatch)
        dispatch.vanillaPolice.enabled = true
        dispatch.suppressPoliceShotsFired = false
    end)

    f.D.Enter('match-1')

    t.isTrue(f.called('SetPoliceIgnorePlayer'),
        'a key that no longer exists vetoed the block an operator switched on')
    t.isTrue(f.called('SetDispatchCopsForPlayer'))
    t.isTrue(f.called('SetPlayerWantedLevel'))
end)

t.test('and the three switches inside the block still gate one native each', function()
    -- Why the dead key was removed rather than moved down into this block:
    -- there is already a master switch here and already per-native control,
    -- so a second master switch would have been the same trap one level down.
    local f = newClientFixture(function(dispatch)
        dispatch.vanillaPolice = {
            enabled = true, ignorePlayer = false,
            stopDispatch = false, stashWantedLevel = true,
        }
    end)

    f.D.Enter('match-1')

    t.isFalse(f.called('SetPoliceIgnorePlayer'), 'ignorePlayer = false was ignored')
    t.isFalse(f.called('SetDispatchCopsForPlayer'), 'stopDispatch = false was ignored')
    t.isTrue(f.called('SetPlayerWantedLevel'), 'stashWantedLevel = true did nothing')
end)

t.test('suppressAmbulanceDown, the switch that survived, works on a stock config', function()
    -- The difference that decided which of the two headline switches was
    -- honest: this one's reader is gated on nothing an operator cannot see,
    -- so BOTH its positions change behaviour on the config as it ships.
    local on = newClientFixture()
    on.D.Enter('match-1')
    t.isTrue(on.D.ClearDeadState(11),
        'the shipped config no longer suppresses the person-down alert')

    local off = newClientFixture(function(dispatch)
        dispatch.suppressAmbulanceDown = false
    end)
    off.D.Enter('match-1')
    t.isFalse(off.D.ClearDeadState(11),
        'suppressAmbulanceDown = false left the medical suppression running')
    t.isFalse(off.called('NetworkResurrectLocalPlayer'))
end)

-- ========================================================================
-- THE HANDOFF TO A MEDICAL SCRIPT, WIRED FROM THE CATALOGUE
--
-- The half the arena cannot do by resurrecting. sc-ambulance keeps its own
-- `isDead` and `InLaststand`, and nothing about standing a ped up touches
-- either -- so the player is up and walking while everything that script
-- does to a casualty is still being done to them. That is the state reported
-- as "the revive is not working", and the ped genuinely is standing up,
-- which is exactly what makes it read as a lie.
--
-- 'hospital:client:Revive' is what clears the pair. Read out of
-- sc-ambulance's own client/main.lua, whose handler opens
--     if isDead or InLaststand then
-- which is the pair, named by the script itself. Not a guess, and not a name
-- that merely sounds right -- this file's own rule.
-- ========================================================================

t.test('a running medical script is told, without the operator naming a thing', function()
    local env = compatWith({ 'sc-ambulance' })
    local events = env.ArenaCompat.ReviveClientEvents()

    t.equals(#events, 1, 'sc-ambulance is running and nothing would be sent to it')
    t.equals(events[1], 'hospital:client:Revive',
        'the wrong event would be sent -- sc-ambulance clears isDead and InLaststand on hospital:client:Revive and on nothing else')
end)

t.test('a medical script this box does NOT run is not told', function()
    -- The catalogue is a list of names to look for, never a census. Firing at
    -- a resource that is not running is harmless but it would make the report
    -- claim a handoff that is not happening.
    local env = compatWith({})
    t.equals(#env.ArenaCompat.ReviveClientEvents(), 0,
        'an event was aimed at a medical script this box is not running')
end)

t.test('two scripts sharing the event name are told once, not twice', function()
    -- The QBCore family shares 'hospital:client:Revive'. A box running two of
    -- them would otherwise get the same event fired at it repeatedly.
    local env = compatWith({ 'sc-ambulance', 'qb-ambulancejob' })
    t.equals(#env.ArenaCompat.ReviveClientEvents(), 1,
        'the same revive event is sent once per resource rather than once per name')
end)

t.test('the arena revive really sends it, not just knows it', function()
    -- The gap this whole session kept falling into: a value correct at one end
    -- and never arriving. Knowing the event name is worth nothing unless
    -- ArenaDispatch.Revive actually fires it.
    local f = newFixture()
    f.env.ArenaCompat = {
        ReviveClientEvents = function() return { 'hospital:client:Revive' } end,
    }

    f.D.Revive(4)

    local told = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'hospital:client:Revive' then told = message end
    end

    t.isNotNil(told, 'the arena knows the medical script\'s revive event and never sends it')
    t.equals(told.target, 4, 'the wrong player was handed off')
end)

t.test('and it still stands the player up first, whatever the handoff does', function()
    -- Order matters and so does independence: a medical script that is absent,
    -- broken or throwing must not cost the player their own revive.
    local f = newFixture()
    f.env.ArenaCompat = { ReviveClientEvents = function() return {} end }

    f.D.Revive(4)

    local own = nil
    for _, message in ipairs(f.toClients) do
        if message.name == 'crimson_arena:client:revive' then own = message end
    end
    t.isNotNil(own, 'with no medical script detected the arena stopped reviving its own player')
end)

-- ========================================================================
-- START ORDER, which decides whether an EMS call can be stopped at all
--
-- Read out of sc-ambulance and sc-dispatch rather than reasoned about:
--
--   laststand.lua sends hospital:server:SetLaststandStatus (which sets the
--   player's `inlaststand` metadata) and THEN hospital:server:EMSDownAlert,
--   whose server handler admits the call only for a player carrying that
--   metadata. Both are TriggerServerEvent from the victim's own client, in
--   that order, so the guard's own condition is satisfied before it runs --
--   and no resource can cancel another resource's event.
--
-- So the only winnable moment is before laststand is entered at all, which
-- the arena does by resurrecting inside the same event dispatch. That is a
-- race decided by resource start order, and when it is lost the failure is
-- silent and looks exactly like the arena being broken. Hence a report line.
-- ========================================================================

--- A compat env loaded while `runningNames` are ALREADY started.
---
--- Different from compatWith on purpose: that one patches resource state
--- after the load, which is right for detection (re-read every time) and
--- useless for start order (captured once, at load). Getting these two mixed
--- up is how a start-order check turns into a permanent false warning.
--- @param runningNames string[]
--- @return table env
local function compatLoadedAfter(runningNames)
    local started = {}
    for _, name in ipairs(runningNames) do started[name] = true end

    local console = {}
    local env = Sandbox.newArenaEnv({
        print = function(line) console[#console + 1] = tostring(line) end,
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name) return started[name] and 'started' or 'missing' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        CreateThread = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        Wait = function() end,
        ArenaIsAdmin = function() return false end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
    })
    Sandbox.loadInto('../shared/compat/dispatch.lua', env)
    env.consoleText = function() return table.concat(console, '\n') end
    return env
end

t.test('an emergency script that started first is named, with the fix', function()
    local env = compatLoadedAfter({ 'sc-ambulance' })
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'start order', 'nothing tells the operator who answers a death first')
    t.contains(report, 'sc-ambulance', 'the report warns about start order without naming the resource')
    t.contains(report, 'server.cfg', 'the operator is told there is a problem and not where to fix it')
end)

t.test('and when the arena started first it says so, rather than staying quiet', function()
    -- Silence would be ambiguous: an operator who has just fixed their
    -- server.cfg needs to see that it took.
    local env = compatLoadedAfter({})
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'started first',
        'a correct start order is reported as nothing at all, so it cannot be confirmed')
end)

t.test('start order is judged at LOAD, not whenever the report is read', function()
    -- The whole signal is "was it already running while we were loading".
    -- Ask later and everything reports 'started', including resources that
    -- started after this one -- which would turn a correct setup into a
    -- permanent false warning.
    local env = compatLoadedAfter({})
    t.equals(#env.ArenaCompat.StartedBeforeUs(), 0)

    -- Everything comes up afterwards. The answer must not change.
    env.GetResourceState = function() return 'started' end
    t.equals(#env.ArenaCompat.StartedBeforeUs(), 0,
        'the check re-reads resource state after load, so a resource that started LATER is blamed for starting first')
end)

-- ----------------------------------------------------------------------
-- AND SAID AGAIN WHERE THE SYMPTOM IS
-- ----------------------------------------------------------------------
--
-- The boot report names the losing start order once, among six other
-- subjects, and the thing it predicts does not happen until somebody dies in
-- a match -- an EMS call for a fighter, which is the whole reason this file
-- exists. Between the warning and the symptom is every other line the server
-- printed while it was starting.

t.test('DEFECT: the first death in an arena repeats the start-order warning', function()
    local env = compatLoadedAfter({ 'sc-ambulance' })

    t.isTrue(env.ArenaCompat.WarnLateStartOnce(), 'the first death printed nothing')
    local said = env.consoleText()
    t.contains(said, 'sc-ambulance', 'the warning does not name the resource that won the race')
    t.contains(said, 'server.cfg', 'the warning does not say how to fix it')
    t.contains(said, 'crimsonArena', 'the warning does not offer the state-bag guard as a fallback')
end)

t.test('and says it ONCE, not on every death for the rest of the session', function()
    -- A warning printed every time a fighter falls is a warning nobody reads
    -- twice, and it would bury the console output the rest of this file
    -- checks its guarantees through.
    local env = compatLoadedAfter({ 'sc-ambulance' })

    t.isTrue(env.ArenaCompat.WarnLateStartOnce(), 'the first call printed nothing')
    for _ = 1, 5 do
        t.isFalse(env.ArenaCompat.WarnLateStartOnce(), 'it printed again on a later death')
    end
end)

t.test('and stays silent on a server that started this resource first', function()
    -- The correct setup, which is most of them. A frightening warning on a
    -- working server sends an operator to fix something that is not broken.
    local env = compatLoadedAfter({})
    t.isFalse(env.ArenaCompat.WarnLateStartOnce(),
        'a correctly ordered server was told its ambulance job would be paged')
    t.notContains(env.consoleText(), 'ANSWERED FIRST', 'it printed the warning anyway')
end)

os.exit(t.summary())
