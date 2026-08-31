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

    local env = Sandbox.newEnv({
        ExecuteCommand = function(line) commands[#commands + 1] = line end,
        CancelEvent = function() cancelled = cancelled + 1 end,
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
        exports = setmetatable({}, { __call = function() end }),
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
        step = function()
            local pending = threads
            threads = {}
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

t.test('the shipped sc-dispatch entries are both registered', function()
    -- The config that actually ships, rather than a fixture's. Both entries
    -- exist because a dispatch script can raise its alert from either realm.
    local f = newFixture()

    local names = table.concat(f.netRegistered, ',')
    t.contains(names, 'sc-dispatch:server:AddNotification',
        'the client -> server path is not registered -- it is the one that carries arena gunfire')
    t.contains(names, 'sc-dispatch:AddNotification')
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
-- THE RESOURCE HAS TO BE ALLOWED TO RUN THE COMMAND
--
-- THE DEFECT THIS EXISTS FOR, and it is the reason the revive appeared to
-- work and did nothing. A command run through ExecuteCommand from a resource
-- is run BY that resource, and an admin command checks whether its caller is
-- allowed. This resource is not an admin, so `revive` was refused -- and a
-- refused command is not an error, it is a command that did nothing. The
-- console honestly reported running it while the player stayed on the floor.
-- ========================================================================

t.test('the resource grants itself permission for the command it is configured with', function()
    local f = newFixture(reviveConfig('revive %s'))
    f.step()

    local ran = table.concat(f.commands, '\n')
    t.contains(ran, 'add_ace', 'no permission was granted, so the command is refused in silence')
    t.contains(ran, 'command.revive', 'the wrong permission was granted')
    t.contains(ran, 'resource.crimson_arena', 'the permission was not granted to this resource')
end)

t.test('and grants the command, never admin', function()
    -- Adding the arena to an admin group would also make the revive work,
    -- and would make every command on the server reachable from inside this
    -- resource. That trade is not worth making for one command, so the test
    -- pins the narrow grant rather than merely a working one.
    local f = newFixture(reviveConfig('revive %s'))
    f.step()

    local ran = table.concat(f.commands, '\n')
    t.notContains(ran, 'add_principal', 'the resource was added to a group instead of given one command')
    t.notContains(ran, 'group.admin')
end)

t.test('the permission follows the config: rename the command, rename the grant', function()
    local f = newFixture(reviveConfig('heal %s'))
    f.step()

    local ran = table.concat(f.commands, '\n')
    t.contains(ran, 'command.heal')
    t.notContains(ran, 'command.revive', 'a permission was granted for a command nobody configured')
end)

t.test('an operator who would rather grant it themselves can turn it off', function()
    local config = reviveConfig('revive %s')
    config.revive.grantSelfPermission = false

    local f = newFixture(config)
    f.step()

    t.notContains(table.concat(f.commands, '\n'), 'add_ace',
        'the grant ran despite being switched off')
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
    t.equals(#f.toClients, 1, 'the client was never asked to run anything')
    t.equals(f.toClients[1].name, 'crimson_arena:client:runCommand')
    t.equals(f.toClients[1].target, 9, 'the wrong player was asked')
    t.equals(f.toClients[1].args[1], 'revive')
end)

t.test('a client template WITH a placeholder still gets the id', function()
    local config = reviveConfig('revive %s')
    config.revive.commands = {}
    config.revive.clientCommands = { 'heal %s' }

    local f = newFixture(config)
    f.D.Revive(4)

    t.equals(f.toClients[1].args[1], 'heal 4')
end)

t.test('both forms can run together, and each goes to its own realm', function()
    local config = reviveConfig('revive %s')
    config.revive.clientCommands = { 'revive' }

    local f = newFixture(config)
    f.D.Revive(6)

    t.equals(f.commands[1], 'revive 6', 'the server console line is gone')
    t.equals(#f.toClients, 1, 'the client line is gone')
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

t.test('the shipped config is one that will actually revive somebody', function()
    -- The default that ships is the one nearly every operator runs, so it
    -- being wired up is worth an assertion of its own -- and a default that
    -- reported itself as broken would be the thing everyone sees first.
    local env = newCompat()
    local report = table.concat(env.ArenaCompat.Report(), '\n')

    t.contains(report, 'revive: configured')
    t.notContains(report, 'revive: NOT configured')
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

os.exit(t.summary())
