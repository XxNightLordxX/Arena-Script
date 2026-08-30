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

    local env = Sandbox.newEnv({
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
os.exit(t.summary())
