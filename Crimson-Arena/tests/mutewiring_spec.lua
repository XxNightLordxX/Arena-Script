--[[
    crimson_arena/tests/mutewiring_spec.lua

    THE ADAPTER MUTE, AND THE EVENTS IT RIDES.

    shared/compat/dispatch.lua is the file that answers the complaint an
    operator actually reports: "the ambulance job still gets a call every
    time somebody goes down in the arena". Three separate mechanisms in
    this resource exist to stop that, and the LAST of them is the adapter
    mute -- the escape hatch for a medical script that cannot be silenced
    by a state bag or by an ignore export, and only answers to a call of
    its own.

    NOT ONE LINE OF IT WAS TESTED. `ArenaCompat.Mute` appeared exactly
    three times in the whole repository: its own definition and the two
    AddEventHandler calls at the bottom of the file that drive it. No spec
    named it, no spec fired the events it hangs off, and deleting either
    handler broke nothing the suite could see -- on the one path an
    operator reaches for when the other two have already failed them.

    What this file holds:

      THE HANDLERS EXIST AT ALL      entering a match calls every detected
                                     adapter's mute with active=true, and
                                     leaving calls it with false. The
                                     BOOLEAN IS THE WHOLE POINT: a mute
                                     that never un-mutes leaves a player
                                     invisible to the ambulance job for the
                                     rest of their session.

      THEY RIDE THE CONFIGURED       an operator who renames enterEvent
      NAMES, NOT HARDCODED ONES      renames this too, with nothing to keep
                                     in sync -- and one set to nil registers
                                     NO handler rather than a dead one.

      ONLY RUNNING RESOURCES         a mute for a script this box does not
                                     run is not called. It would be a call
                                     into a resource that is not there.

      ONE THROW DOES NOT TAKE THE    a third-party export that errors must
      MATCH DOWN                     not stop the next adapter's mute, and
                                     must not be counted as having worked.

      A SERVER ID IS REQUIRED        Mute is driven by the server's own
                                     record of who is in a match. Rubbish
                                     where a source belongs is refused
                                     rather than passed to somebody else's
                                     export.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- shared/compat/dispatch.lua on the SERVER side, with the events it
--- registers captured rather than thrown away.
---
--- The stock fixture in dispatch_spec.lua stubs AddEventHandler to a no-op,
--- which is exactly why the mute wiring went untested: the handlers were
--- registered into nothing. Here they are kept, and `fire` delivers one the
--- way the server would.
---
--- @param opts table? -- { running = { [resource] = true }, config = fun(dispatch) }
--- @return table fixture
local function newCompat(opts)
    opts = opts or {}
    local running = opts.running or {}
    local handlers = {}

    local env = Sandbox.newArenaEnv({
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name)
            return running[name] and 'started' or 'missing'
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        CreateThread = function() end,
        RegisterCommand = function() end,
        Wait = function() end,
        ArenaIsAdmin = function() return false end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
    })

    if opts.config then opts.config(env.Config.Dispatch) end
    Sandbox.loadInto('../shared/compat/dispatch.lua', env)

    local fixture = { env = env, handlers = handlers }

    --- The names this file actually registered, so a spec can assert that
    --- one is absent rather than only that it does nothing.
    function fixture.registered(name) return handlers[name] ~= nil end

    --- Delivers a server event. Returns false when nothing is listening.
    function fixture.fire(name, ...)
        local handler = handlers[name]
        if not handler then return false end
        handler(...)
        return true
    end

    --- Registers an adapter whose mute records every call it is given.
    --- @return table calls -- { { src = number, active = boolean }, ... }
    function fixture.spyAdapter(resource, kind)
        local calls = {}
        t.isTrue(env.ArenaCompat.RegisterAdapter({
            resource = resource,
            kind = kind or 'ambulance',
            mute = function(src, active) calls[#calls + 1] = { src = src, active = active } end,
        }), 'the adapter this spec is built on was refused')
        return calls
    end

    return fixture
end

--- The two event names the shipped config announces entry and exit on.
local ENTER = 'crimson_arena:dispatch:enter'
local EXIT = 'crimson_arena:dispatch:exit'

-- ========================================================================
-- THE HANDLERS EXIST, AND CARRY THE BOOLEAN
-- ========================================================================

t.test('entering a match calls a detected adapter\'s mute', function()
    local f = newCompat({ running = { ps_dispatch = true } })
    local calls = f.spyAdapter('ps_dispatch')

    t.isTrue(f.fire(ENTER, 7), 'nothing is listening on the entry event')

    t.equals(#calls, 1, 'the mute was never called')
    t.equals(calls[1].src, 7, 'the mute was called for the wrong player')
    t.equals(calls[1].active, true, 'the mute was told the player was LEAVING on entry')
end)

t.test('and leaving it calls the same mute the other way', function()
    -- THE HALF THAT MATTERS MORE. A mute that fires on entry and never on
    -- exit reads as working -- the arena is quiet -- and leaves the player
    -- invisible to the ambulance job everywhere else on the map until they
    -- relog.
    local f = newCompat({ running = { ps_dispatch = true } })
    local calls = f.spyAdapter('ps_dispatch')

    f.fire(ENTER, 7)
    t.isTrue(f.fire(EXIT, 7), 'nothing is listening on the exit event')

    t.equals(#calls, 2, 'the exit never reached the mute')
    t.equals(calls[2].active, false, 'a player who left the arena was never un-muted')
end)

t.test('every detected adapter is asked, not just the first', function()
    local f = newCompat({ running = { ps_dispatch = true, qb_ambulancejob = true } })
    local first = f.spyAdapter('ps_dispatch')
    local second = f.spyAdapter('qb_ambulancejob')

    f.fire(ENTER, 3)

    t.equals(#first, 1)
    t.equals(#second, 1, 'the second dispatch script on the box was never muted')
end)

-- ========================================================================
-- THE NAMES COME FROM CONFIG
-- ========================================================================

t.test('the handlers ride the CONFIGURED event names, not hardcoded ones', function()
    -- server/dispatch.lua announces on whatever config says. If this file
    -- hardcoded the shipped names, an operator renaming them would get a
    -- resource that announces on one name and mutes off another, and the
    -- mute would simply stop -- silently, with the report still claiming
    -- the resource is "muted automatically".
    local f = newCompat({
        running = { ps_dispatch = true },
        config = function(dispatch)
            dispatch.custom.enterEvent = 'someserver:arena:in'
            dispatch.custom.exitEvent = 'someserver:arena:out'
        end,
    })
    local calls = f.spyAdapter('ps_dispatch')

    t.isFalse(f.registered(ENTER), 'the shipped name is still wired after a rename')
    t.isTrue(f.fire('someserver:arena:in', 5), 'the renamed entry event reached nothing')
    t.isTrue(f.fire('someserver:arena:out', 5), 'the renamed exit event reached nothing')

    t.equals(#calls, 2)
    t.equals(calls[1].active, true)
    t.equals(calls[2].active, false)
end)

t.test('an enterEvent set to nil registers NO handler rather than a dead one', function()
    -- The report has a row for exactly this: "has a mute, but
    -- custom.enterEvent is nil so nothing triggers it". That row is only
    -- honest if the handler really is absent.
    local f = newCompat({
        running = { ps_dispatch = true },
        config = function(dispatch) dispatch.custom.enterEvent = nil end,
    })
    f.spyAdapter('ps_dispatch')

    t.isFalse(f.registered(ENTER), 'a handler was registered for an event nobody announces')
    t.isTrue(f.registered(EXIT), 'the exit half was dropped along with the entry half')
end)

t.test('and a non-string event name is treated as nil, not wired as one', function()
    local f = newCompat({
        running = { ps_dispatch = true },
        config = function(dispatch) dispatch.custom.enterEvent = 12345 end,
    })

    t.isFalse(f.registered(ENTER))
    t.isFalse(f.registered(12345), 'a number was accepted as an event name')
end)

-- ========================================================================
-- ONLY WHAT THIS BOX ACTUALLY RUNS
-- ========================================================================

t.test('a mute for a resource this box does not run is never called', function()
    local f = newCompat({ running = {} })
    local calls = f.spyAdapter('ps_dispatch')

    f.fire(ENTER, 7)

    t.equals(#calls, 0, 'a script that is not installed was called into')
end)

t.test('and Mute reports how many adapters it actually reached', function()
    local f = newCompat({ running = { ps_dispatch = true } })
    f.spyAdapter('ps_dispatch')
    f.spyAdapter('qb_ambulancejob')  -- registered, but not running

    t.equals(f.env.ArenaCompat.Mute(7, true), 1, 'the count includes adapters that were skipped')
end)

-- ========================================================================
-- ONE THROW DOES NOT TAKE THE MATCH DOWN
-- ========================================================================

t.test('an adapter whose mute throws does not stop the next one', function()
    -- Same rule the announce path and the ignore-export path already
    -- follow. A third-party export is somebody else's code and is allowed
    -- to be broken; a match start is not allowed to die with it.
    local f = newCompat({ running = { broken_dispatch = true, ps_dispatch = true } })

    t.isTrue(f.env.ArenaCompat.RegisterAdapter({
        resource = 'broken_dispatch',
        kind = 'ambulance',
        mute = function() error('that export does not exist') end,
    }))
    local good = f.spyAdapter('ps_dispatch')

    local reached = f.env.ArenaCompat.Mute(7, true)

    t.equals(#good, 1, 'a broken third-party export stopped the working one behind it')
    t.equals(reached, 1, 'an export that threw was counted as having worked')
end)

t.test('and the throw does not escape the event handler either', function()
    local f = newCompat({ running = { broken_dispatch = true } })
    t.isTrue(f.env.ArenaCompat.RegisterAdapter({
        resource = 'broken_dispatch',
        kind = 'ambulance',
        mute = function() error('boom') end,
    }))

    -- Unprotected on purpose: if this throws, a match start throws.
    t.isTrue(f.fire(ENTER, 7))
end)

-- ========================================================================
-- A SERVER ID IS REQUIRED
-- ========================================================================

t.test('rubbish where a source belongs is refused before it reaches anyone', function()
    local f = newCompat({ running = { ps_dispatch = true } })
    local calls = f.spyAdapter('ps_dispatch')

    for _, bad in ipairs({ 0, -1, '7', {}, false }) do
        t.equals(f.env.ArenaCompat.Mute(bad, true), 0,
            ('%s was accepted as a server id'):format(tostring(bad)))
    end
    t.equals(f.env.ArenaCompat.Mute(nil, true), 0, 'nil was accepted as a server id')

    t.equals(#calls, 0, 'somebody else\'s export was called with a bad server id')
end)

-- ========================================================================
-- THE ADAPTER CONTRACT
-- ========================================================================

t.test('an adapter whose mute is not a function is refused outright', function()
    -- The operator writes these by hand, from a block in config.lua. A
    -- typo here must be named at boot, not discovered as a crash the first
    -- time somebody enters the arena.
    local f = newCompat({ running = { ps_dispatch = true } })

    t.isFalse(f.env.ArenaCompat.RegisterAdapter({
        resource = 'ps_dispatch', kind = 'ambulance', mute = 'exports.ps_dispatch:ignore',
    }), 'a string was accepted where a mute function belongs')

    t.isTrue(f.fire(ENTER, 7), 'the entry event stopped working after a refused adapter')
end)

t.test('re-registering a resource REPLACES its mute rather than adding a second', function()
    -- config.lua tells an operator they can paste an adapter to override a
    -- catalogue entry. Two mutes for one resource would call somebody
    -- else's export twice per entry.
    local f = newCompat({ running = { ps_dispatch = true } })
    local first = f.spyAdapter('ps_dispatch')
    local second = f.spyAdapter('ps_dispatch')

    f.fire(ENTER, 7)

    t.equals(#first, 0, 'the replaced mute is still being called')
    t.equals(#second, 1, 'the replacement mute was not called exactly once')
end)


-- ========================================================================
-- END TO END: THE ANNOUNCEMENT AND THE MUTE, IN ONE PROCESS
--
-- Every assertion above pins one END of the wire. Both ends name
-- 'crimson_arena:dispatch:enter' as a literal, so they agree because the
-- same string was typed twice -- which is exactly the defect class this
-- resource keeps producing: a value computed at one end and silently lost
-- before the other.
--
-- So this section loads server/dispatch.lua and shared/compat/dispatch.lua
-- into ONE environment with a real event bus between them, and asks the
-- only question an operator actually cares about: a player is put in the
-- arena -- does the ambulance script get told to shut up?
-- ========================================================================

--- Both halves of the dispatch story in one env, wired to each other.
--- @param opts table? -- { running = { [resource] = true }, config = fun(dispatch) }
--- @return table fixture
local function newWired(opts)
    opts = opts or {}
    local running = opts.running or {}
    local handlers, bags = {}, {}

    local env = Sandbox.newArenaEnv({
        IsDuplicityVersion = function() return true end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name) return running[name] and 'started' or 'missing' end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        -- THE BUS. A real one: this is the only stub in the file that is
        -- allowed to carry a value from one production file to another,
        -- and it is the whole point of the section.
        TriggerEvent = function(name, ...)
            for _, fn in ipairs(handlers[name] or {}) do fn(...) end
        end,
        RegisterNetEvent = function() end,
        TriggerClientEvent = function() end,
        Player = function(src)
            return { state = { set = function(_self, _key, value) bags[src] = value end } }
        end,
        CreateThread = function() end,
        SetTimeout = function() end,
        RegisterCommand = function() end,
        Wait = function() end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        ArenaGetPlayer = function() return nil end,
        ArenaIsAdmin = function() return false end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function() return setmetatable({}, { __index = function() return function() end end }) end,
        }),
    })

    if opts.config then opts.config(env.Config.Dispatch) end

    env.ArenaLobby = {
        Get = function(matchId)
            local first = env.Arena.GetEnabledArenas()[1]
            if not first then return nil end
            return { id = matchId, arenaKey = first.key }
        end,
    }

    Sandbox.loadInto('../shared/compat/dispatch.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)

    local fixture = { env = env, D = env.ArenaDispatch, bag = function(src) return bags[src] end }

    function fixture.spyAdapter(resource, kind)
        local calls = {}
        t.isTrue(env.ArenaCompat.RegisterAdapter({
            resource = resource,
            kind = kind or 'ambulance',
            mute = function(src, active) calls[#calls + 1] = { src = src, active = active } end,
        }))
        return calls
    end

    return fixture
end

t.test('END TO END -- putting a player in the arena mutes the ambulance script', function()
    -- The complaint this whole file exists for, reproduced end to end:
    -- nothing here is told an event name, and no test double stands
    -- between the two production files.
    local f = newWired({ running = { qb_ambulancejob = true } })
    local calls = f.spyAdapter('qb_ambulancejob')

    f.D.Set(7, 'match-1')

    t.equals(#calls, 1, 'entering the arena told the ambulance script nothing')
    t.equals(calls[1].src, 7, 'the mute was fired for the wrong player')
    t.equals(calls[1].active, true)
end)

t.test('and taking them back out un-mutes it', function()
    local f = newWired({ running = { qb_ambulancejob = true } })
    local calls = f.spyAdapter('qb_ambulancejob')

    f.D.Set(7, 'match-1')
    f.D.Clear(7)

    t.equals(#calls, 2, 'leaving the arena told the ambulance script nothing')
    t.equals(calls[2].active, false, 'the player stayed muted after the match ended')
end)

t.test('and renaming the event in config keeps BOTH ends together', function()
    -- The two ends read the same config key rather than sharing a literal.
    -- Rename it and the wire must still carry -- if either end had the
    -- shipped name baked in, this is where it breaks.
    local f = newWired({
        running = { qb_ambulancejob = true },
        config = function(dispatch)
            dispatch.custom.enterEvent = 'someserver:arena:in'
            dispatch.custom.exitEvent = 'someserver:arena:out'
        end,
    })
    local calls = f.spyAdapter('qb_ambulancejob')

    f.D.Set(7, 'match-1')
    f.D.Clear(7)

    t.equals(#calls, 2, 'a renamed event broke the link between the two files')
    t.equals(calls[1].active, true)
    t.equals(calls[2].active, false)
end)

t.test('a mute that throws does not stop the player being flagged', function()
    -- ORDER OF DAMAGE. The state bag is what every other dispatch script
    -- reads; a third-party mute that errors must not cost the player that
    -- flag, or one broken export silences nothing and breaks everything.
    local f = newWired({ running = { broken_dispatch = true } })
    t.isTrue(f.env.ArenaCompat.RegisterAdapter({
        resource = 'broken_dispatch',
        kind = 'ambulance',
        mute = function() error('that export does not exist') end,
    }))

    f.D.Set(7, 'match-1')

    local bag = f.bag(7)
    t.isNotNil(bag, 'a broken third-party mute cost the player their dispatch flag')
    t.equals(bag.active, true)
    t.equals(bag.matchId, 'match-1')
end)

t.test('the flag is already readable by the time the entry event fires', function()
    -- ORDERING IS A CONTRACT HERE, not an accident. Adapter mutes are only
    -- the handlers THIS resource registers on that event; an operator's own
    -- handler is on it too, and the first thing such a handler does is read
    -- the state bag to find out which match. Announce before writing and it
    -- reads nil -- the announcement arrives describing a player the rest of
    -- the server does not yet believe is fighting.
    local f = newWired({ running = { qb_ambulancejob = true } })
    local seen = {}
    t.isTrue(f.env.ArenaCompat.RegisterAdapter({
        resource = 'qb_ambulancejob',
        kind = 'ambulance',
        mute = function(src) seen[#seen + 1] = f.bag(src) end,
    }))

    f.D.Set(7, 'match-1')

    t.equals(#seen, 1)
    t.isNotNil(seen[1], 'the entry event fired BEFORE the player was flagged')
    t.equals(seen[1].matchId, 'match-1', 'the flag was not complete when the event fired')
end)

t.test('and it is already GONE by the time the exit event fires', function()
    -- The same contract in the other direction, and the one that actually
    -- bites: a handler that reads the bag on exit and finds the player
    -- still flagged concludes they are still fighting and leaves whatever
    -- it was suppressing suppressed.
    local f = newWired({ running = { qb_ambulancejob = true } })
    local seen, calls = {}, 0
    t.isTrue(f.env.ArenaCompat.RegisterAdapter({
        resource = 'qb_ambulancejob',
        kind = 'ambulance',
        -- WRAPPED, because `seen[#seen + 1] = nil` is a no-op in Lua: a
        -- correctly-cleared bag would leave the list empty and read as
        -- "the mute never ran", which is a different failure entirely.
        mute = function(src, active)
            calls = calls + 1
            if active == false then seen[#seen + 1] = { bag = f.bag(src) } end
        end,
    }))

    f.D.Set(7, 'match-1')
    f.D.Clear(7)

    t.equals(calls, 2)
    t.equals(#seen, 1, 'the un-mute never ran')
    t.isNil(seen[1].bag, 'the exit event fired while the player was still flagged')
end)

t.test('and a player who never entered is not muted by a stray Clear', function()
    -- Clear announces even for somebody who was never flagged -- that is
    -- deliberate, and it means the mute is asked to un-mute a player it
    -- never muted. Un-muting somebody who is not muted is harmless; the
    -- assertion here is that it is the ONLY thing that happens.
    local f = newWired({ running = { qb_ambulancejob = true } })
    local calls = f.spyAdapter('qb_ambulancejob')

    f.D.Clear(7)

    t.equals(#calls, 1)
    t.equals(calls[1].active, false, 'a stray Clear MUTED a player instead of un-muting them')
end)


os.exit(t.summary())
