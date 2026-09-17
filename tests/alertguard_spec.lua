--[[
    crimson_arena/tests/alertguard_spec.lua

    THE BLOCK AN OPERATOR PASTES INTO SOMEBODY ELSE'S RESOURCE.

    ALERT-GUARD.md carries a block of Lua that goes at the bottom of
    sc-dispatch/server/main.lua and stops police and EMS alerts being raised
    for a fighter. It is the only code this repository ships that runs inside
    a resource nobody here controls, and it is the only code here that can
    take somebody's ambulance away by being wrong.

    THE BLOCK IS READ OUT OF THE DOCUMENT, not copied into this file. A test
    of a copy is a test of the copy: the day somebody improves the block in
    the document and not here, the copy still passes and the paste people
    actually make is untested. There is exactly one version of it and it is
    the published one.

    WHAT IS PINNED, and each of these is a way it could go wrong on a live
    server with nothing else noticing:

      1. IT IS A PASS-THROUGH BY DEFAULT. With no arena on the box -- not
         started, not installed, never heard of -- every alert must reach the
         real handler unchanged, with its return value intact.

      2. IT SUPPRESSES ONLY THE FIGHTER. The alert for a player in a match is
         dropped; the one for somebody shot in the city is not. Reading the
         subject out of the payload wrong in the unsafe direction means a real
         emergency with nobody paged.

      3. IT NEVER THROWS INTO sc-ambulance. That resource calls
         AddNotification inside a pcall and FALLS BACK to its own direct EMS
         alert when the pcall fails. An error raised from inside the guard
         would not suppress an alert -- it would send the very one being
         suppressed, by a route the guard cannot see.

      4. IT FAILS LOUD. Every failure to get an answer means raise the alert.

      5. IT REFUSES TO RUN WITH NOTHING TO WRAP. Pasted too high in the file
         there is no original handler to call, and a wrapper registered
         anyway would silently delete every alert on the server.
]]

local t = dofile('testkit.lua')

print('alertguard_spec')

-- ========================================================================
-- THE BLOCK, READ OUT OF ALERT-GUARD.md
-- ========================================================================

--- Pulls the fenced Lua block between the guard's own banner comments.
---
--- MATCHED ON THE BANNERS rather than on "the first ```lua in the file", so
--- adding an example above it to the document does not silently start
--- testing the example instead.
local function blockFromDocument()
    local handle = assert(io.open('../ALERT-GUARD.md', 'r'), 'ALERT-GUARD.md is missing')
    local text = handle:read('a')
    handle:close()

    local block = text:match('\n(%-%- =+\n%-%- CRIMSON ARENA ALERT GUARD\n.-END CRIMSON ARENA ALERT GUARD\n%-%- =+)\n')
    assert(block, 'the guard block could not be found in ALERT-GUARD.md')
    return block
end

local BLOCK = blockFromDocument()

-- ========================================================================
-- A STAND-IN FOR sc-dispatch
--
-- Faithful to the parts that matter and to nothing else. The export
-- mechanism is modelled the way FXServer's Lua runtime really works --
-- exports(name, fn) ADDS a handler for a per-resource event, and asking for
-- an export runs them all and keeps the LAST answer -- because the whole
-- block turns on that being true.
-- ========================================================================

--- @param opts table?
---   registerOriginal boolean? -- false models the block pasted TOO HIGH
---   arenaState       string?  -- 'started' | 'missing'
---   suppress         function? -- what ShouldSuppressAlert answers
---   noSuppressExport boolean? -- an older arena build: bag but no export
---   bag              table?   -- [src] = the replicated state bag value
local function newDispatch(opts)
    opts = opts or {}

    local handlers = {}        -- the __cfx_export_* event handlers
    local filed = {}           -- every payload that reached the REAL handler
    local console = {}
    local raiseFromOriginal = nil

    local env = {}
    env._G = env
    for _, name in ipairs({ 'type', 'tonumber', 'tostring', 'pcall', 'error', 'ipairs',
                            'pairs', 'select', 'string', 'table', 'math', 'os', 'setmetatable',
                            'getmetatable', 'rawget', 'rawset', 'next', 'assert' }) do
        env[name] = _G[name]
    end

    env.print = function(line) console[#console + 1] = tostring(line) end
    env.GetCurrentResourceName = function() return 'sc-dispatch' end
    env.GetResourceState = function(name)
        if name == 'Crimson-Arena' then return opts.arenaState or 'started' end
        return 'missing'
    end

    env.AddEventHandler = function(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
    end
    env.TriggerEvent = function(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end

    -- exports(name, fn), exactly as the runtime defines it.
    env.exports = setmetatable({}, {
        __call = function(_self, name, fn)
            env.AddEventHandler(('__cfx_export_%s_%s'):format('sc-dispatch', name), function(setCB)
                setCB(fn)
            end)
        end,
        -- exports['Crimson-Arena']:Name(...) -- somebody else's resource.
        __index = function(_t, resource)
            return setmetatable({}, {
                __index = function(_t2, name)
                    return function(_self, ...)
                        if resource ~= 'Crimson-Arena' then
                            error(('No such export %s in resource %s'):format(name, resource), 0)
                        end
                        if name == 'ShouldSuppressAlert' then
                            if opts.noSuppressExport then
                                error('No such export ShouldSuppressAlert in resource Crimson-Arena', 0)
                            end
                            return (opts.suppress or function() return false end)(...)
                        end
                        error(('No such export %s in resource %s'):format(name, resource), 0)
                    end
                end,
            })
        end,
    })

    env.Player = function(src)
        return { state = { crimsonArena = (opts.bag or {})[src] } }
    end

    -- THE REAL HANDLER. Registered BEFORE the block, which is what pasting
    -- at the bottom of the file means.
    if opts.registerOriginal ~= false then
        env.exports('AddNotification', function(data)
            if raiseFromOriginal then error(raiseFromOriginal, 0) end
            filed[#filed + 1] = data
            return 'call-' .. #filed
        end)
    end

    local chunk = assert(load(BLOCK, '=alert-guard', 't', env))
    chunk()

    --- Calls AddNotification the way sc-dispatch's own code does: through the
    --- export table, so the block's registration is what decides who answers.
    local function addNotification(data)
        local resolved
        env.TriggerEvent('__cfx_export_sc-dispatch_AddNotification', function(cb) resolved = cb end)
        if not resolved then error('nothing is registered for AddNotification', 0) end
        return resolved(data)
    end

    return {
        env = env,
        filed = filed,
        console = console,
        consoleText = function() return table.concat(console, '\n') end,
        addNotification = addNotification,
        --- sc-ambulance's shape: the call wrapped in a pcall, with a fallback
        --- on failure. Answers whether the fallback alert would have fired.
        ambulanceWouldFallBack = function(data)
            local ok = pcall(addNotification, data)
            return not ok
        end,
        makeOriginalRaise = function(message) raiseFromOriginal = message end,
        --- What the guard's marker export answers: true in effect, false
        --- registered but overridden, nil never registered at all.
        ---
        --- WRITTEN AS AN `if`, NOT `resolved ~= nil and resolved() or nil`.
        --- That form can never yield false: `true and false` is false, and
        --- `false or nil` is nil -- so a guard reporting itself NOT in effect
        --- came back indistinguishable from one that never registered, and
        --- the test below passed for the wrong reason. The same trap is
        --- documented twice in server/exports.lua; it caught this file too.
        guardMarker = function()
            local resolved
            env.TriggerEvent('__cfx_export_sc-dispatch_CrimsonArenaAlertGuard',
                function(cb) resolved = cb end)
            if resolved == nil then return nil end
            return resolved()
        end,
    }
end

local FIGHTER, CIVILIAN = 7, 3
local function arenaHolding(...)
    local held = {}
    for _, src in ipairs({ ... }) do held[src] = true end
    return function(src) return held[src] == true end
end

-- ========================================================================
-- 1. A PASS-THROUGH BY DEFAULT
-- ========================================================================

t.test('THE PROMISE: with no arena on the box, every alert goes through untouched', function()
    local d = newDispatch({ arenaState = 'missing' })

    local payload = { unique_id = 'shots_7_1699', caller_source = FIGHTER, message = 'hi' }
    local id = d.addNotification(payload)

    t.equals(#d.filed, 1, 'an alert was dropped on a server that does not run the arena')
    t.equals(d.filed[1], payload, 'the payload reaching the real handler is not the one sent')
    t.equals(id, 'call-1', 'the real handler\'s return value did not reach the caller')
end)

t.test('and the arena being STARTED but answering no changes nothing either', function()
    local d = newDispatch({ suppress = arenaHolding() })
    t.equals(d.addNotification({ caller_source = CIVILIAN }), 'call-1')
    t.equals(#d.filed, 1, 'an ordinary city alert was suppressed')
end)

t.test('and an alert about nobody in particular is never suppressed', function()
    -- A dispatcher-created call, or an alert about a place rather than a
    -- person. Nothing in the payload names a player, so nothing here has any
    -- business dropping it.
    local d = newDispatch({ suppress = function() return true end })

    for _, payload in ipairs({
        { title = 'Bank alarm' },
        { unique_id = 'dispatcher-created-call' },
        { unique_id = 12345 },
        { unique_id = 'shots_notanumber_1699' },
        { caller_source = 'abc' },
        { caller_source = 0 },
        { caller_source = -4 },
    }) do
        d.addNotification(payload)
    end

    t.equals(#d.filed, 7, 'an alert naming no player was dropped')
end)

t.test('and a payload that is not a table at all does not take the handler down', function()
    local d = newDispatch({ suppress = function() return true end })
    for _, junk in ipairs({ 'string', 42, true }) do
        local ok = pcall(d.addNotification, junk)
        t.isTrue(ok, ('a %s payload raised'):format(type(junk)))
    end
    t.equals(#d.filed, 3, 'junk was swallowed rather than passed to the real handler')
end)

-- ========================================================================
-- 2. IT SUPPRESSES ONLY THE FIGHTER
-- ========================================================================

t.test('THE POINT: a fighter\'s alert is never raised, by either payload shape', function()
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    -- caller_source: the person-down and person-dead calls.
    t.isNil(d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' }),
        'a suppressed call answered with an id, so the caller thinks it was filed')

    -- unique_id only: shots fired, panic, and sc-ambulance's own calls.
    for _, uid in ipairs({ 'shots_7_1699', 'panic_7_1699', 'playerdead_7_1699',
                           'emsdown_7_1699', 'doctoralert_7_1699' }) do
        d.addNotification({ unique_id = uid })
    end

    t.equals(#d.filed, 0, 'an arena alert reached the dispatch board')
end)

t.test('and the SAME shapes for somebody else go straight through', function()
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    d.addNotification({ caller_source = CIVILIAN, unique_id = 'playerdown_3_1699' })
    d.addNotification({ unique_id = 'shots_3_1699' })

    t.equals(#d.filed, 2, 'a city alert was suppressed because somebody else was fighting')
end)

t.test('THE HAZARD: the id pattern is anchored, so a timestamp is never read as a player',
function()
    -- An unanchored match reads the FIRST run of digits it finds. Get this
    -- wrong and the number that silences somebody is whatever happened to be
    -- in the id -- a clock, a row id, a house number in free text.
    local d = newDispatch({ suppress = arenaHolding(1699, 2024, 911) })

    for _, uid in ipairs({
        'shots_3_1699',              -- the timestamp is 1699; the player is 3
        'call 911 about shots_3_1',  -- free text with a number in it
        'shots_3_1699_extra',        -- a longer id than the pattern describes
        '1699',
    }) do
        d.addNotification({ unique_id = uid })
    end

    t.equals(#d.filed, 4, 'something other than the player\'s server id silenced an alert')
end)

t.test('and caller_source WINS over the id, because it is the one that is explicit', function()
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    -- sc-dispatch builds both onto the same payload. They agree in practice;
    -- if they ever disagreed, the field put there on purpose is the answer.
    d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_3_1699' })
    t.equals(#d.filed, 0, 'the explicit subject was ignored in favour of a parsed one')
end)

-- ========================================================================
-- 3. IT NEVER THROWS INTO sc-ambulance
-- ========================================================================

t.test('THE TRAP: suppressing must not look like a FAILURE to sc-ambulance', function()
    -- sc-ambulance calls AddNotification inside a pcall and falls back to its
    -- own direct EMS alert when that pcall fails. A guard that raised instead
    -- of returning nil would send the very alert it was suppressing, by a
    -- route it cannot see.
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    t.isFalse(d.ambulanceWouldFallBack({ caller_source = FIGHTER, unique_id = 'emsdown_7_1699' }),
        'suppressing an alert made sc-ambulance raise its own instead')
    t.equals(#d.filed, 0)
end)

t.test('and a real handler that raises still raises, exactly as it does today', function()
    -- The other half of the same contract. sc-ambulance's fallback exists
    -- because sc-dispatch really can fail -- a database that is down, for
    -- instance -- and the guard must not swallow that and leave nobody paged.
    local d = newDispatch({ suppress = arenaHolding() })
    d.makeOriginalRaise('database is down')

    local ok, err = pcall(d.addNotification, { caller_source = CIVILIAN })
    t.isFalse(ok, 'a failure inside sc-dispatch was swallowed by the guard')
    t.contains(tostring(err), 'database is down', 'the original failure was replaced')
end)

-- ========================================================================
-- 4. IT FAILS LOUD
-- ========================================================================

t.test('THE SAFETY DIRECTION: an arena that cannot answer means RAISE the alert', function()
    -- Mid-restart, an export that is not there, a module that threw. Every
    -- one of these is a maybe, and a maybe about a player bleeding out is a
    -- page, not a silence.
    for _, opts in ipairs({
        { suppress = function() error('mid-restart') end },
        { suppress = function() return nil end },
        { suppress = function() return 'yes' end },
        { suppress = function() return { 'truthy table' } end },
        { noSuppressExport = true },
    }) do
        local d = newDispatch(opts)
        d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' })
        t.equals(#d.filed, 1, 'an arena that could not answer silenced a medical alert')
    end
end)

t.test('and an older arena build with the state bag but no export still works', function()
    -- The fallback that makes this paste safe on a build that predates
    -- ShouldSuppressAlert. The bag is replicated and server-readable.
    local d = newDispatch({ noSuppressExport = true, bag = { [FIGHTER] = { active = true } } })

    d.addNotification({ caller_source = FIGHTER })
    d.addNotification({ caller_source = CIVILIAN })

    t.equals(#d.filed, 1, 'the state-bag fallback did not suppress the fighter')
    t.equals(d.filed[1].caller_source, CIVILIAN, 'it suppressed the wrong one')
end)

-- ========================================================================
-- 5. IT REFUSES TO RUN WITH NOTHING TO WRAP
-- ========================================================================

t.test('THE WORST OUTCOME, AND IT CANNOT HAPPEN: pasted too high, it registers nothing',
function()
    -- Above the line where AddNotification is registered there is no original
    -- to call. A wrapper registered anyway would become the only handler on
    -- the server and every alert would vanish -- police, EMS, fire, the lot --
    -- with nothing in the console to say why.
    local d = newDispatch({ registerOriginal = false })

    local ok = pcall(d.addNotification, { caller_source = CIVILIAN })
    t.isFalse(ok, 'the guard registered itself with no real handler behind it')
    t.contains(d.consoleText(), 'NOTHING was changed',
        'it went quiet instead of saying the paste is in the wrong place')
    t.isNil(d.guardMarker(),
        'it announced itself as active while having wrapped nothing')
end)

t.test('and when it DOES run it says so, in the console and to the arena', function()
    local d = newDispatch({ suppress = arenaHolding() })

    t.contains(d.consoleText(), 'active: arena alerts will not be raised',
        'a working paste said nothing at startup')
    t.isTrue(d.guardMarker(),
        'the arena\'s compat report cannot tell that the paste took')
end)

t.test('THE CLAIM IS "IN EFFECT", NOT "IT RAN": something registered after it is reported',
function()
    -- The marker export is a BRAND-NEW name, so it registers whether or not
    -- the re-registration of AddNotification replaced anything. A marker that
    -- only proved the block reached the bottom would report success on a
    -- build where the guard does nothing -- which is the exact reading an
    -- operator would then trust instead of checking.
    --
    -- So it answers by identity: is the function the runtime hands out for
    -- AddNotification ours? Here something else registers afterwards and
    -- wins, which is what a second paste, or another resource's own wrapper,
    -- would do.
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    t.isTrue(d.guardMarker(), 'the control failed: a clean paste reported itself not in effect')

    d.env.exports('AddNotification', function(data) return 'somebody-else' end)

    t.isFalse(d.guardMarker(),
        'the guard still reported itself in effect while something else was answering')

    -- AND IT REALLY IS NOT IN EFFECT, which is what makes the report matter
    -- rather than being a detail about registration order.
    t.equals(d.addNotification({ caller_source = FIGHTER }), 'somebody-else',
        'the fixture does not model the override it is asserting about')
end)

-- ========================================================================
-- THE PAYLOADS THE REAL SCRIPTS SEND
--
-- Read out of sc-dispatch and sc-ambulance rather than invented, so the
-- claim "one paste covers both scripts" is measured against their shapes.
-- ========================================================================

t.test('every alert shape the two scripts really build is covered', function()
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    local shapes = {
        -- sc-dispatch/server/main.lua
        { what = 'ShotsFired', payload = { unique_id = 'shots_7_1699', job_table = { 'police' } } },
        { what = 'PanicButton', payload = { unique_id = 'panic_7_1699' } },
        { what = 'PlayerDown',
          payload = { unique_id = 'playerdown_7_1699', caller_source = 7 } },
        { what = 'PlayerDead',
          payload = { unique_id = 'playerdead_7_1699', caller_source = 7 } },
        { what = 'requestEMS', payload = { unique_id = 'ems_7_1699', caller_source = 7 } },
        -- sc-ambulance/server/main.lua
        { what = 'EMSDownAlert',
          payload = { unique_id = 'emsdown_7_1699', caller_source = 7 } },
        { what = 'doctor alert', payload = { unique_id = 'doctoralert_7_1699' } },
    }

    for _, shape in ipairs(shapes) do
        local before = #d.filed
        d.addNotification(shape.payload)
        t.equals(#d.filed, before, shape.what .. ' reached the dispatch board for a fighter')
    end
end)

-- ========================================================================
-- WHAT A PLAYER COULD DO WITH IT
-- ========================================================================

t.test('THE EXPLOIT THAT IS NOT ONE: a forged subject only silences the forger\'s own call',
function()
    -- sc-dispatch has a net event a client can reach, so a player can put any
    -- caller_source they like on a payload. What that buys them is the
    -- suppression of an alert THEY were raising -- which they could have
    -- simply not raised. It reaches nobody else's.
    local d = newDispatch({ suppress = arenaHolding(FIGHTER) })

    -- The forged one is dropped...
    d.addNotification({ caller_source = FIGHTER, message = 'forged' })
    t.equals(#d.filed, 0)

    -- ...and the genuine alert for the player they named is untouched, because
    -- each payload is judged on its own subject and nothing is remembered
    -- between calls.
    d.addNotification({ caller_source = CIVILIAN, message = 'a real emergency' })
    t.equals(#d.filed, 1, 'a forged payload suppressed somebody ELSE\'s later alert')
    t.equals(d.filed[1].message, 'a real emergency')
end)

t.test('and the guard keeps no state between calls at all', function()
    -- A guard that cached "src 7 is fighting" would keep silencing 7 after
    -- the round -- and server ids are recycled, so that is the next person to
    -- connect losing their ambulance.
    local held = { [FIGHTER] = true }
    local d = newDispatch({ suppress = function(src) return held[src] == true end })

    d.addNotification({ caller_source = FIGHTER })
    t.equals(#d.filed, 0, 'the fighter was paged mid-round')

    held[FIGHTER] = nil        -- the round ends and the arena's window closes
    d.addNotification({ caller_source = FIGHTER })
    t.equals(#d.filed, 1, 'a player was still being silenced after the arena stopped saying so')
end)

-- ========================================================================
-- END TO END: THE REAL ARENA, THE REAL BLOCK, NOTHING STUBBED BETWEEN THEM
--
-- Everything above answers the arena's question with a fixture. This runs
-- the actual Crimson-Arena/server/dispatch.lua and server/exports.lua in one
-- environment, the published block in another, and wires the second to the
-- first through the export the way FXServer would.
--
-- WHY IT IS WORTH THE SETUP. Every test above would still pass if the arena
-- answered this question WRONG -- if ShouldSuppressAlert were really
-- IsPlayerInArena, say, which is honest and which would let the alert for a
-- body that fell in the arena out the moment the round resolved. The stub
-- cannot catch that, because the stub is not the arena.
-- ========================================================================

local Sandbox = dofile('fixtures/sandbox.lua')

--- The arena half: server/dispatch.lua and server/exports.lua loaded for
--- real, with the exports it registers captured.
local function newArena()
    local registered = {}
    local clockOffset = 0

    local env = Sandbox.newArenaEnv({
        IsDuplicityVersion = function() return true end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        GetNumResources = function() return 0 end,
        CreateThread = function() end,
        Wait = function() end,
        SetTimeout = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        GetGameTimer = function() return 0 end,
        print = function() end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        ArenaIsAdmin = function() return true end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
        ArenaGetPlayer = function() return nil end,
        ArenaLobby = { Get = function() return nil end, All = function() return {} end },
        Player = function() return { state = { set = function() end } } end,
        exports = setmetatable({}, {
            __call = function(_self, name, fn) registered[name] = fn end,
            __index = function()
                return setmetatable({}, { __index = function() return function() end end })
            end,
        }),
    })

    local handlers = {}
    env.AddEventHandler = function(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
    end

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    env.Config.Dispatch = env.Config.Dispatch or {}
    env.Config.Dispatch.downState = env.Config.Dispatch.downState or {}
    env.Config.Dispatch.downState.holdIntervalMs = 0

    Sandbox.loadInto('../Crimson-Arena/server/dispatch.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/exports.lua', env)

    -- THE CLOCK, MOVED RATHER THAN WAITED OUT. The grace window is a minute
    -- wide and a spec that slept for it would not be a test.
    local realTime = os.time
    env.os = setmetatable({ time = function() return realTime() + clockOffset end },
        { __index = os })

    return {
        D = env.ArenaDispatch,
        ShouldSuppressAlert = registered.ShouldSuppressAlert,
        advance = function(seconds) clockOffset = clockOffset + seconds end,
        drop = function(src)
            env.source = src
            for _, fn in ipairs(handlers['playerDropped'] or {}) do fn() end
        end,
    }
end

--- The block, wired to a REAL arena instead of a fixture.
local function newWiredDispatch(arena)
    local filed = {}
    local handlers = {}
    local env = {}
    env._G = env
    for _, name in ipairs({ 'type', 'tonumber', 'tostring', 'pcall', 'error', 'ipairs',
                            'pairs', 'select', 'string', 'table', 'math', 'os', 'setmetatable',
                            'getmetatable', 'rawget', 'rawset', 'next', 'assert' }) do
        env[name] = _G[name]
    end
    env.print = function() end
    env.GetCurrentResourceName = function() return 'sc-dispatch' end
    env.GetResourceState = function(name)
        return name == 'Crimson-Arena' and 'started' or 'missing'
    end
    env.AddEventHandler = function(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
    end
    env.TriggerEvent = function(name, ...)
        for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    end
    env.Player = function() return { state = {} } end
    env.exports = setmetatable({}, {
        __call = function(_self, name, fn)
            env.AddEventHandler(('__cfx_export_sc-dispatch_%s'):format(name), function(setCB)
                setCB(fn)
            end)
        end,
        __index = function(_t, resource)
            return setmetatable({}, {
                __index = function(_t2, name)
                    return function(_self, ...)
                        if resource == 'Crimson-Arena' and name == 'ShouldSuppressAlert' then
                            -- THE REAL ONE, out of the real exports.lua.
                            return arena.ShouldSuppressAlert(...)
                        end
                        error(('No such export %s in resource %s'):format(name, resource), 0)
                    end
                end,
            })
        end,
    })

    env.exports('AddNotification', function(data)
        filed[#filed + 1] = data
        return 'call-' .. #filed
    end)

    assert(load(BLOCK, '=alert-guard', 't', env))()

    return {
        filed = filed,
        addNotification = function(data)
            local resolved
            env.TriggerEvent('__cfx_export_sc-dispatch_AddNotification',
                function(cb) resolved = cb end)
            return resolved(data)
        end,
    }
end

t.test('END TO END: a real match silences the real alert, and only for its fighters', function()
    local arena = newArena()
    local d = newWiredDispatch(arena)

    arena.D.Set(FIGHTER, 'match-1')

    d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' })
    t.equals(#d.filed, 0, 'a live fighter was paged to EMS through the real arena')

    d.addNotification({ caller_source = CIVILIAN, unique_id = 'playerdown_3_1699' })
    t.equals(#d.filed, 1, 'a city death was silenced by a match somebody else was in')
end)

t.test('END TO END: THE GAP -- the body that falls as the round ENDS is still covered',
function()
    -- The reason ShouldSuppressAlert exists rather than the arena answering
    -- this with IsPlayerInArena. A round resolves, the flag comes down, and
    -- sc-dispatch files the person-down call for the body that just fell
    -- milliseconds later. IsPlayerInArena is honest and says no.
    local arena = newArena()
    local d = newWiredDispatch(arena)

    arena.D.Set(FIGHTER, 'match-1')
    arena.D.Clear(FIGHTER)

    t.isFalse(arena.D.IsPlayerInArena(FIGHTER),
        'the fixture no longer shows the gap the two answers differ over')

    d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' })
    t.equals(#d.filed, 0,
        'the alert for a body that fell in the arena went out as the round ended')
end)

t.test('END TO END: and the silence ENDS -- it is not a flag for the rest of a session',
function()
    local arena = newArena()
    local d = newWiredDispatch(arena)

    arena.D.Set(FIGHTER, 'match-1')
    arena.D.Clear(FIGHTER)
    arena.advance(61)

    d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' })
    t.equals(#d.filed, 1, 'a player was still having alerts swallowed a minute after the round')
end)

t.test('END TO END: and a RECYCLED server id does not inherit the last holder\'s silence',
function()
    -- The hazard this whole grace window has to be careful about: a fighter
    -- leaves, the server hands their id to the next person to connect, and
    -- that person is shot in the city inside the same minute.
    local arena = newArena()
    local d = newWiredDispatch(arena)

    arena.D.Set(FIGHTER, 'match-1')
    arena.D.Clear(FIGHTER)
    arena.drop(FIGHTER)

    d.addNotification({ caller_source = FIGHTER, unique_id = 'playerdown_7_1699' })
    t.equals(#d.filed, 1, 'somebody inherited a fighter\'s silence with their server id')
end)

os.exit(t.summary())
