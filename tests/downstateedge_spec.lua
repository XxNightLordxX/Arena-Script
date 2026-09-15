--[[
    crimson_arena/tests/downstateedge_spec.lua

    THE HALF-SECOND THAT PAGES A MEDIC.

    A fighter goes on their side in the arena and an ambulance is called
    out. Not every time -- about every other time -- which is the shape of a
    race rather than a missing feature, and the race is this:

      qbx_medical keeps the truth in a state bag and MIRRORS it into two
      bits of player metadata, `inlaststand` and `isdead`, rewriting them
      from the bag every time it changes.

      sc-dispatch reads that mirror off its OWN client, every 500ms, and
      raises a person-down call on the rising edge.

      This resource writes the mirror back down, on a 250ms timer.

    Three resources, one value, and whether a medic gets paged comes down to
    where a poll happened to land. A 250ms hold against a 500ms poll loses
    about half the time, and shortening the interval only buys a smaller
    fraction of the same coin flip while writing metadata faster forever.

    So the arena stopped waiting to notice. It listens to the state bag the
    medical script actually changes, and clears on the tick after the
    change: the window goes from half a poll to one tick.

    WHAT THIS FILE DOES NOT CLAIM, and the production comment says the same
    thing at more length: this is not prevention. The decision is taken on
    the victim's client inside a resource this one cannot reach, and FiveM
    has no supported way for one resource to stop another's handler. What is
    asserted here is that the arena hears the edge, answers it immediately,
    answers it more than once, and never keeps answering for somebody who
    has left.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('downstateedge_spec')

local ALIVE, LAST_STAND, DEAD = 1, 2, 3
local BAG = 'qbx_medical:deathState'

--- server/dispatch.lua with the state-bag natives modelled.
---
--- The two the edge listener needs are exactly the two the other dispatch
--- fixtures leave out, which is why this file has its own: without them the
--- listener declines to register at all, and a test written against that
--- fixture would pass while asserting nothing.
--- @param opts table? -- { downState = <config override>, noNatives = true }
--- @return table fixture
local function newFixture(opts)
    opts = opts or {}
    local metadata, metaWrites, logs = {}, {}, {}
    local threads, bagHandlers, bags = {}, {}, {}
    local eventHandlers, exportCalls = {}, {}
    local clock = 0

    -- FXSERVER'S OWN CreateThread, for the tests that are about WHEN the
    -- work runs rather than what it does.
    --
    -- The default above is a queue: the body is put aside and runs on the
    -- next step(), which is right for everything that only cares about the
    -- end state and keeps a 13-pass burst inside one step. It cannot see the
    -- ordering guarantee, though, because it defers the body whether or not
    -- the body asked to be deferred -- so `Wait(0)`, which is the whole
    -- mechanism, can be deleted and the fixture behaves identically.
    --
    -- FXServer runs a thread body IMMEDIATELY and stops it at its first
    -- yield. That is why the burst opens with Wait(0) and it is the only
    -- thing standing between this resource and qbx_medical re-raising the
    -- flag after the clear on a server where the arena registered first.
    local live = {}
    local function tickCreate(fn)
        local co = coroutine.create(fn)
        local ok, err = coroutine.resume(co)
        if not ok then error(('fixture: a thread errored: %s'):format(tostring(err))) end
        if coroutine.status(co) ~= 'dead' then live[#live + 1] = co end
    end

    local function tickDrain()
        -- BOUNDED. A burst that stopped ending would otherwise hang the
        -- suite rather than fail it.
        for _ = 1, 500 do
            local alive = 0
            for _, co in ipairs(live) do
                if coroutine.status(co) ~= 'dead' then
                    alive = alive + 1
                    local ok, err = coroutine.resume(co)
                    if not ok then error(('fixture: a thread errored: %s'):format(tostring(err))) end
                end
            end
            if alive == 0 then return end
        end
        error('fixture: a thread would not finish')
    end

    local env = Sandbox.newArenaEnv({
        CreateThread = opts.tickThreads and tickCreate
            or function(fn) threads[#threads + 1] = fn end,
        Wait = opts.tickThreads
            and function(ms) clock = clock + (tonumber(ms) or 0) coroutine.yield() end
            or function(ms) clock = clock + (tonumber(ms) or 0) end,
        GetGameTimer = function() return clock end,
        SetTimeout = function(_ms, fn) threads[#threads + 1] = fn end,
        AddEventHandler = function(name, fn) eventHandlers[name] = fn end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name)
            return name == 'sc-dispatch' and 'started' or 'missing'
        end,
        GetPlayerName = function() return 'a fighter' end,
        ArenaLog = function(fmt, ...)
            logs[#logs + 1] = (select('#', ...) > 0) and fmt:format(...) or fmt
        end,
        ArenaDebug = function() end,
        ArenaIsAdmin = function() return true end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
        ArenaLobby = { Get = function() return nil end, All = function() return {} end },
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
        -- The arena raises its own replicated flag on a fighter. Modelled
        -- because ArenaDispatch.Set writes it, and `enter` below is how every
        -- test in this file puts somebody in a match.
        Player = function(src)
            bags[src] = bags[src] or {}
            local store = bags[src]
            return {
                state = {
                    set = function(_self, key, value) store[key] = value end,
                    get = function(_self, key) return store[key] end,
                },
            }
        end,
        ArenaGetPlayer = function(src)
            if metadata[src] == nil then return nil end
            return {
                Functions = {
                    -- `reassert` models the real thing an arena is up against:
                    -- a medical script that does not set its flag once and
                    -- stop, but holds it up for the whole bleed-out. Read as
                    -- still-true however many times the arena has put it down.
                    GetMetaData = function(key)
                        if opts.reassert and (key == 'inlaststand' or key == 'isdead') then
                            return true
                        end
                        return metadata[src][key]
                    end,
                    SetMetaData = function(key, value)
                        metadata[src][key] = value
                        metaWrites[#metaWrites + 1] = { src = src, key = key, value = value }
                    end,
                },
            }
        end,
    })

    if not opts.noNatives then
        env.AddStateBagChangeHandler = function(key, _filter, fn)
            bagHandlers[#bagHandlers + 1] = { key = key, fn = fn }
        end
        env.GetPlayerFromStateBagName = function(bagName)
            return tonumber(tostring(bagName):match('player:(%d+)')) or 0
        end
    end

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)

    env.Config.Dispatch = env.Config.Dispatch or {}
    env.Config.Dispatch.downState = env.Config.Dispatch.downState or {}
    -- The background hold is not this file's subject and a `while true` loop
    -- against a Wait that does not yield never comes back. Off.
    env.Config.Dispatch.downState.holdIntervalMs = 0
    if opts.downState then
        for key, value in pairs(opts.downState) do
            env.Config.Dispatch.downState[key] = value
        end
    end
    if opts.retract then
        env.Config.Dispatch.custom = env.Config.Dispatch.custom or {}
        env.Config.Dispatch.custom.retract = env.Config.Dispatch.custom.retract or {}
        for key, value in pairs(opts.retract) do
            env.Config.Dispatch.custom.retract[key] = value
        end
    end

    Sandbox.loadInto('../Crimson-Arena/server/dispatch.lua', env)

    -- Run the load-time threads, which is where the listener registers.
    for _, fn in ipairs(threads) do fn() end
    local ran = #threads

    local f = {
        env = env,
        metaWrites = metaWrites,
        logs = function() return table.concat(logs, '\n') end,
        exportCalls = exportCalls,
        --- Fires a local server event the way another resource would.
        fireEvent = function(name, ...)
            local fn = eventHandlers[name]
            if not fn then return false end
            fn(...)
            return true
        end,
        handlerCount = function() return #bagHandlers end,
        --- Threads started since load. A guard that declines to act is only
        --- provable by the work it did NOT start: the clear itself is a
        --- no-op against a flag that is already down, so counting writes
        --- cannot tell "declined" from "ran and found nothing to do".
        spawned = function() return #threads - ran end,
        handlerKey = function() return bagHandlers[1] and bagHandlers[1].key end,
        --- Puts `src` in a match, the way ArenaDispatch.Set does.
        enter = function(src)
            metadata[src] = { inlaststand = false, isdead = false }
            env.ArenaDispatch.Set(src, 'm1')
        end,
        leave = function(src) env.ArenaDispatch.Clear(src) end,
        --- A player the arena has never seen, but who still has metadata.
        stranger = function(src) metadata[src] = { inlaststand = false, isdead = false } end,
        metadata = function(src) return metadata[src] end,
        --- The medical script raises its own flag, AFTER the bag handlers
        --- have run -- which is the ordering on a server where this resource
        --- registered its handler first.
        goDownArenaFirst = function(src, value)
            metadata[src] = metadata[src] or {}
            for _, entry in ipairs(bagHandlers) do
                entry.fn(('player:%d'):format(src), entry.key, value)
            end
            metadata[src].isdead = (value == DEAD)
            metadata[src].inlaststand = (value == LAST_STAND)
        end,
        --- The medical script flips its state bag for `src`.
        goDown = function(src, value)
            metadata[src] = metadata[src] or {}
            -- What qbx_medical's own handler does on that same change.
            metadata[src].isdead = (value == DEAD)
            metadata[src].inlaststand = (value == LAST_STAND)
            for _, entry in ipairs(bagHandlers) do
                entry.fn(('player:%d'):format(src), entry.key, value)
            end
        end,
        --- Everything the arena has queued, run to completion.
        step = function()
            if opts.tickThreads then tickDrain() return 0 end
            local pending = {}
            for index = ran + 1, #threads do pending[#pending + 1] = threads[index] end
            ran = #threads
            for _, fn in ipairs(pending) do fn() end
            return #pending
        end,
        writesFor = function(src, key)
            local n = 0
            for _, w in ipairs(metaWrites) do
                if w.src == src and w.key == key and w.value == false then n = n + 1 end
            end
            return n
        end,
    }
    return f
end

-- ======================================================================
-- HEARING THE EDGE
-- ======================================================================

t.test('the listener registers against the bag the config names', function()
    local f = newFixture()
    t.equals(f.handlerCount(), 1, 'the arena is not listening to the death-state bag at all')
    t.equals(f.handlerKey(), BAG, 'it registered against the wrong bag')
end)

t.test('a fighter going into laststand has both flags cleared', function()
    local f = newFixture()
    f.enter(7)

    f.goDown(7, LAST_STAND)
    t.equals(f.metadata(7).inlaststand, true, 'the medical script did not set the flag, so nothing is being tested')

    f.step()

    t.equals(f.metadata(7).inlaststand, false,
        'a fighter went on their side and the arena left the flag up for a dispatch script to find')
    t.equals(f.metadata(7).isdead, false, 'the other flag was left alone')
end)

t.test('and so does one that dies', function()
    local f = newFixture()
    f.enter(7)

    f.goDown(7, DEAD)
    f.step()

    t.equals(f.metadata(7).isdead, false, 'a dead fighter kept the flag that raises a 10-54')
end)

t.test('the clear lands AFTER the medical script writes, whichever handler ran first', function()
    -- Both hang off the same bag change and nothing decides the order. What
    -- has to be true is not "we go second" but "the last word is ours", and
    -- that is what deferring the work off the handler buys. `goDown` applies
    -- the medical script's own write as part of the same change, so this
    -- asserts the end state rather than the ordering.
    local f = newFixture()
    f.enter(7)

    f.goDown(7, LAST_STAND)
    t.equals(f.metadata(7).inlaststand, true, 'the medical script did not write, so nothing is proved')

    f.step()

    t.equals(f.metadata(7).inlaststand, false,
        'the medical script had the last word, so a dispatch poll still finds the flag up')
end)

t.test('AND IT HOLDS WHEN THE ARENA RAN FIRST, which is what Wait(0) buys', function()
    -- THE ORDERING NOTHING COULD SEE. Both handlers hang off the same bag
    -- and nothing decides which runs first; the test above asserts the end
    -- state with the medical write applied BEFORE the handlers, so the arena
    -- goes second by construction and the guarantee is the fixture's rather
    -- than the code's. Here the arena's handler runs first and the medical
    -- script writes afterwards -- and the clear still has to land last.
    --
    -- `burstMs = 0` is what makes it an assertion rather than a coincidence:
    -- with the burst reduced to a single clear there is no second pass to
    -- paper over a first one that fired too early. Do the work inline and
    -- that one clear happens before the flag has even been raised, does
    -- nothing (it is conditional on the flag being up), and the flag stays
    -- up for the dispatch script's next poll -- which is the whole reported
    -- bug, back in full.
    --
    -- Run on FXServer's own thread semantics: a body that starts at once and
    -- stops at its first yield. The default fixture queues every body, so it
    -- cannot tell a deferred clear from an inline one.
    local f = newFixture({ tickThreads = true, downState = { burstMs = 0 } })
    f.enter(7)

    f.goDownArenaFirst(7, LAST_STAND)
    t.equals(f.metadata(7).inlaststand, true,
        'the medical script did not write after the handler, so this proves nothing')

    f.step()

    t.equals(f.metadata(7).inlaststand, false,
        'the clear ran inside the handler, so the medical script had the last word')
end)

t.test('one clear is enough while the flag STAYS down', function()
    -- The clear is conditional on the flag actually being up, so a burst
    -- against a settled flag costs one write and then nothing. That is the
    -- cheap case and it should stay cheap.
    local f = newFixture({ downState = { burstMs = 600, burstIntervalMs = 50 } })
    f.enter(7)

    f.goDown(7, LAST_STAND)
    f.step()

    t.equals(f.writesFor(7, 'inlaststand'), 1,
        'the burst kept writing to a flag that was already down')
end)

t.test('but a medical script that HOLDS the flag up is answered every pass', function()
    -- The case the operator actually has. A knockdown is not an instant: it
    -- is a bleed-out timer, and the medical script asserts its state for the
    -- whole of it. One clear at the edge would be overwritten a moment later
    -- and the next dispatch poll would find it up again.
    local f = newFixture({ reassert = true, downState = { burstMs = 600, burstIntervalMs = 50 } })
    f.enter(7)

    f.goDown(7, LAST_STAND)
    f.step()

    t.isTrue(f.writesFor(7, 'inlaststand') >= 5,
        ('the flag was put back down %d time(s) across a 600ms bleed-out -- a script that '
            .. 'holds it up wins'):format(f.writesFor(7, 'inlaststand')))
end)

-- ======================================================================
-- AND NOT TOUCHING ANYBODY ELSE
-- ======================================================================

t.test('a player who is not in a match is left completely alone', function()
    -- The whole layer is one mistake away from suppressing a real medical
    -- call for an ordinary player having a real emergency.
    local f = newFixture()
    f.stranger(9)

    f.goDown(9, LAST_STAND)

    -- CHECKED BEFORE THE STEP, because step() is what consumes the count.
    -- Asserting it afterwards reads zero whether a burst was started or not,
    -- which is a test that cannot fail.
    t.equals(f.spawned(), 0,
        'a burst was started for a player who is not in a match -- it would decline to write '
            .. 'only because there was nothing to write, which is luck, not a guard')

    f.step()

    t.equals(#f.metaWrites, 0, 'the arena cleared the down flag for somebody it has no claim on')
    t.equals(f.metadata(9).inlaststand, true, 'a stranger was quietly revived in the eyes of dispatch')
end)

t.test('and a fighter who leaves mid-burst stops being written to', function()
    -- A flag held down for somebody who has gone back to the city suppresses
    -- their alerts for the rest of their session.
    local f = newFixture({ downState = { burstMs = 600, burstIntervalMs = 50 } })
    f.enter(7)

    f.goDown(7, LAST_STAND)
    f.leave(7)
    f.step()

    t.equals(#f.metaWrites, 0, 'the burst kept writing for a player who had already left the match')
end)

t.test('ALIVE is not an edge worth answering', function()
    local f = newFixture()
    f.enter(7)

    f.goDown(7, ALIVE)

    t.equals(f.spawned(), 0,
        'a revive started a burst -- it wrote nothing only because the flags were already '
            .. 'down, so every revive in every round pays for a thread that does nothing')

    f.step()
    t.equals(#f.metaWrites, 0, 'a revive started a burst of writes for a flag that is already down')
end)

t.test('what ALIVE is called is read from the config, not assumed to be 1', function()
    -- An operator is invited to name a different bag, and a resource that
    -- lets you do that while hard-coding one of its values is offering a
    -- choice it does not honour. On an enum where 1 means "down", the old
    -- code skipped its burst at exactly the moment the burst exists for.
    local f = newFixture({ downState = { aliveValue = 7 } })
    f.enter(7)

    -- 1 IS THE VALUE SENT, and it has to be, or this test is not about its
    -- own name. On this server 1 is an ordinary down state and 7 is alive,
    -- so a resource that assumes 1 means alive skips the burst at exactly
    -- the moment the burst exists for. Sending 2 here -- as this did --
    -- passes against the hard-coded version too, because 2 is not 1 either.
    f.goDown(7, ALIVE)
    t.isTrue(f.spawned() > 0, 'a knockdown was ignored because 1 was assumed to mean alive')
    f.step()
    t.equals(f.metadata(7).inlaststand, false, 'the flag was left up')
end)

t.test('and the configured alive value is the one that is skipped', function()
    local f = newFixture({ downState = { aliveValue = 7 } })
    f.enter(7)

    f.goDown(7, 7)

    t.equals(f.spawned(), 0, 'a revive started a burst on a server whose ALIVE is 7')
end)

t.test('a bag that carries its value as a string still reads as alive', function()
    -- State bags carry whatever wrote them. '1' and 1 have to mean the same
    -- thing here or a revive starts a pointless burst every time.
    local f = newFixture()
    f.enter(7)

    f.goDown(7, '1')

    t.equals(f.spawned(), 0, 'a string ALIVE was treated as a knockdown')
end)

-- ======================================================================
-- AND DECLINING CLEANLY WHERE IT CANNOT WORK
-- ======================================================================

t.test('no bag named means no listener, and the hold is left to do its job', function()
    local f = newFixture({ downState = { watchStateBag = '' } })
    t.equals(f.handlerCount(), 0, 'it listened to a bag the operator did not name')
end)

t.test('a runtime without the natives declines instead of erroring', function()
    -- This file is loaded on servers and in specs that stub a fraction of
    -- the API. An unguarded AddStateBagChangeHandler here would take the
    -- whole resource down at load.
    local ok, err = pcall(newFixture, { noNatives = true })
    t.isTrue(ok, ('loading without the state-bag natives raised: %s'):format(tostring(err)))
end)

t.test('the burst cannot spin forever against a clock that does not move', function()
    -- A loop that ends only when a deadline passes does not end at all if
    -- GetGameTimer is a constant -- it spins the server flat out, in the
    -- middle of a knockdown. The pass count is the bound that cannot be
    -- argued with.
    local f = newFixture({ downState = { burstMs = 5000, burstIntervalMs = 10 } })
    f.enter(7)
    f.env.GetGameTimer = function() return 0 end

    f.goDown(7, LAST_STAND)
    f.step()

    t.isTrue(#f.metaWrites > 0, 'nothing happened at all')
    t.isTrue(#f.metaWrites <= 400,
        ('the burst wrote %d times -- it is not bounded'):format(#f.metaWrites))
end)


-- ======================================================================
-- WITHDRAWING THE CALL BY ITS REAL NAME
--
-- sc-dispatch announces every alert on a plain server event before it
-- writes a row or tells anybody, so the arena does not have to guess at id
-- shapes: it is handed the id, the jobs and the player the call is about.
-- What has to be true is that it withdraws the arena's calls, withdraws
-- nobody else's, and uses the id it was GIVEN rather than one it built.
-- ======================================================================

--- One announced call, shaped the way sc-dispatch announces them.
local function filedCall(src, id)
    return {
        unique_id = id or ('playerdown_' .. tostring(src) .. '_1700000000'),
        caller_source = src,
        job_table = { 'ambulance', 'doctor' },
        title = '10-52 - Person Down',
    }
end

t.test('a call filed about a fighter is withdrawn, with the id it was handed', function()
    local f = newFixture()
    f.enter(7)

    t.isTrue(f.fireEvent('sc-dispatch:server:witnessForward', filedCall(7, 'playerdown_7_1700000000')),
        'the arena is not listening for filed calls at all')
    f.step()

    t.isTrue(#f.exportCalls > 0, 'no withdrawal went out at all')
    local call = f.exportCalls[1]
    t.equals(call.resource, 'sc-dispatch')
    t.equals(call.export, 'ClearNotification')
    t.equals(call.args[1], 'playerdown_7_1700000000',
        'it withdrew some other id than the one it was given')
    t.equals(type(call.args[2]), 'table', 'the job list was not passed on, so the clear may not reach EMS')

    for i, again in ipairs(f.exportCalls) do
        t.equals(again.args[1], 'playerdown_7_1700000000',
            ('attempt %d asked for a different id'):format(i))
    end
end)

t.test('AND IT ASKS MORE THAN ONCE, because knowing the id says nothing about when the call exists', function()
    -- THE REPORT THIS PATH WAS WRITTEN FOR: "its not even recalling the
    -- alert for a person down". The announcement this handler listens to
    -- happens BEFORE the rows are written -- sc-dispatch awaits an oxmysql
    -- write several statements deep first, routinely longer than the 250ms
    -- pause -- so a withdrawal that arrives ahead of the insert matches no
    -- row, and then the call lands and stays. Indistinguishable from this
    -- layer never having run.
    --
    -- retractFor already knew this and asks four times on a widening
    -- schedule; the filed path asked once, on the one number that comment
    -- says is not enough. Asking again costs nothing: a clear for a call
    -- that is already gone matches no row either.
    local f = newFixture()
    f.enter(7)

    f.fireEvent('sc-dispatch:server:witnessForward', filedCall(7, 'playerdown_7_1700000000'))
    f.step()

    t.isTrue(#f.exportCalls >= 4,
        ('the withdrawal was asked for %d time(s) -- one shot at a write that has not '
            .. 'landed withdraws nothing'):format(#f.exportCalls))
end)

t.test('and a call about somebody NOT in a match is left alone', function()
    -- This handler sees every alert filed anywhere on the server. Withdraw
    -- the wrong one and a player with a real emergency is taken off the
    -- responders' screens by an arena they have never been near.
    local f = newFixture()
    f.enter(7)

    f.fireEvent('sc-dispatch:server:witnessForward', filedCall(9))
    f.step()

    t.equals(#f.exportCalls, 0, 'the arena withdrew a stranger\'s medical call')
end)

t.test('a call with no id, or no subject, is not acted on', function()
    local f = newFixture()
    f.enter(7)

    f.fireEvent('sc-dispatch:server:witnessForward', { caller_source = 7 })
    f.fireEvent('sc-dispatch:server:witnessForward', { unique_id = 'playerdown_7_1' })
    f.fireEvent('sc-dispatch:server:witnessForward', 'not a table')
    f.fireEvent('sc-dispatch:server:witnessForward', nil)
    f.step()

    t.equals(#f.exportCalls, 0, 'it tried to withdraw a call it could not name')
end)

t.test('a fighter who just left is still covered, because the call lands after they do', function()
    -- The post-match sweep runs seconds after the flag comes down, and the
    -- alert that is still in flight is exactly the one worth withdrawing.
    local f = newFixture()
    f.enter(7)
    f.leave(7)

    f.fireEvent('sc-dispatch:server:witnessForward', filedCall(7))
    f.step()

    t.isTrue(#f.exportCalls > 0, 'a call filed about a fighter as they walked out was left standing')
end)

t.test('and a dispatch resource that is not running is not called into', function()
    local f = newFixture()
    f.enter(7)
    f.env.GetResourceState = function() return 'missing' end

    f.fireEvent('sc-dispatch:server:witnessForward', filedCall(7))
    f.step()

    t.equals(#f.exportCalls, 0, 'it called an export on a resource that is not started')
end)

t.test('no announcement event configured means no listener', function()
    local f = newFixture({ retract = { filedEvent = '' } })
    t.isFalse(f.fireEvent('sc-dispatch:server:witnessForward', filedCall(7)),
        'it listened for an event the operator did not name')
end)

os.exit(t.summary())
