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

    local env = Sandbox.newEnv({
        ExecuteCommand = function(line) commands[#commands + 1] = line end,
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

os.exit(t.summary())
