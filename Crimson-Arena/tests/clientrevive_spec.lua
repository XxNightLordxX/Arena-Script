package.path = './?.lua;' .. package.path
local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ========================================================================
-- THE REVIVE, ON THE CLIENT
--
-- The arena stands its own dead back up rather than asking the server for
-- permission to run somebody else's /revive. That is the whole reason this
-- function exists, and it is called from four places -- a mid-match respawn,
-- an elimination, the way out, and a blanket sweep five seconds after the
-- match ends over EVERYONE who played.
--
-- The sweep is what makes this function's blast radius matter. By the time it
-- runs those players are home and doing something else, so anything the
-- revive does unconditionally is done to a player who was already fine.
-- ========================================================================

--- @param state table -- dead, health, ragdoll
local function newClient(state)
    local calls = {}
    local threads = {}
    local netHandlers = {}
    local function record(name)
        return function(...)
            calls[#calls + 1] = { name = name, args = { ... } }
            return nil
        end
    end

    local health = state.health or 200

    local env = Sandbox.newEnv({
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { 1.0, 2.0, 3.0 } end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityMaxHealth = function() return 200 end,
        GetEntityHealth = function() return health end,
        IsEntityDead = function() return state.dead == true end,
        IsPedRagdoll = function() return state.ragdoll == true end,
        IsPedInWrithe = function() return state.writhe == true end,

        SetEntityHealth = function(ped, value)
            health = value
            calls[#calls + 1] = { name = 'SetEntityHealth', args = { ped, value } }
        end,

        NetworkResurrectLocalPlayer = record('NetworkResurrectLocalPlayer'),
        ClearPedBloodDamage = record('ClearPedBloodDamage'),
        ResetPedVisibleDamage = record('ResetPedVisibleDamage'),
        ClearPedLastWeaponDamage = record('ClearPedLastWeaponDamage'),
        ClearPedTasksImmediately = record('ClearPedTasksImmediately'),
        AnimpostfxStopAll = record('AnimpostfxStopAll'),
        SetPedCanRagdoll = record('SetPedCanRagdoll'),
        SetEntityInvincible = record('SetEntityInvincible'),
        SetEntityVisible = record('SetEntityVisible'),
        SetEntityCollision = record('SetEntityCollision'),
        FreezeEntityPosition = record('FreezeEntityPosition'),

        -- Load-time surface. None of it is what this file is about; it is
        -- here so the real production file can be loaded unmodified.
        RegisterNetEvent = function(name, fn)
            if type(fn) == 'function' then netHandlers[name] = fn end
        end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        -- CAPTURED, not run. The assert window lives in a thread, and a spec
        -- that cannot step it cannot tell a window that watches from one that
        -- never looks again.
        CreateThread = function(fn) threads[#threads + 1] = fn end,
        Wait = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        exports = setmetatable({}, { __call = function() end }),
        lib = { notify = function() end },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../client/dispatch.lua', env)

    return {
        env = env,
        D = env.ArenaDispatch,
        state = state,
        health = function() return health end,
        called = function(name)
            for _, c in ipairs(calls) do
                if c.name == name then return true end
            end
            return false
        end,
        countOf = function(name)
            local n = 0
            for _, c in ipairs(calls) do
                if c.name == name then n = n + 1 end
            end
            return n
        end,
        fireNet = function(name, ...)
            local fn = netHandlers[name]
            if not fn then error('no net event registered called ' .. tostring(name), 2) end
            fn(...)
        end,
        --- Runs every thread started so far, once, to completion.
        step = function()
            local pending = threads
            threads = {}
            for _, fn in ipairs(pending) do fn() end
        end,
    }
end

-- ------------------------------------------------------------------
-- A player who actually died
-- ------------------------------------------------------------------

t.test('a dead player is resurrected, healed and cleaned up', function()
    local c = newClient({ dead = true, health = 0 })

    c.D.Revive()

    t.isTrue(c.called('NetworkResurrectLocalPlayer'), 'a dead player was never resurrected')
    t.equals(c.health(), 200, 'a revived player was left short of full health')
    t.isTrue(c.called('ClearPedTasksImmediately'),
        'the tasks a death leaves running were not cleared -- that is a player alive on the floor unable to stand')
    t.isTrue(c.called('ClearPedBloodDamage'))
    t.isTrue(c.called('AnimpostfxStopAll'),
        'the death screen effect was left on, so the player walks around a greyed-out world')
end)

t.test('and so is somebody alive but still wearing the death -- ragdolling', function()
    -- The case the unconditional version was written for, and the reason the
    -- guard is on "was hurt" rather than on "was dead".
    local c = newClient({ dead = false, ragdoll = true, health = 200 })

    c.D.Revive()

    t.isTrue(c.called('ClearPedTasksImmediately'),
        'a player stuck ragdolling was left there because they were technically alive')
    t.isTrue(c.called('AnimpostfxStopAll'))
end)

t.test('and so is somebody alive but hurt', function()
    local c = newClient({ dead = false, health = 40 })

    c.D.Revive()

    t.isTrue(c.called('ClearPedTasksImmediately'))
    t.equals(c.health(), 200, 'a hurt player was not healed')
end)

-- ------------------------------------------------------------------
-- A player who was already fine -- the post-match sweep
-- ------------------------------------------------------------------

t.test('a player who is already fine is not interrupted', function()
    -- THE REGRESSION THIS FILE EXISTS FOR.
    --
    -- The post-match sweep revives everyone who played, five seconds after
    -- the match, when they are home and getting on with something else.
    -- ClearPedTasksImmediately on a player who is fine cancels whatever they
    -- are doing -- an animation, an emote, climbing into a car -- and it did
    -- it to the whole roster on every single match.
    local c = newClient({ dead = false, health = 200 })

    c.D.Revive()

    t.isFalse(c.called('ClearPedTasksImmediately'),
        'the revive cancelled the tasks of a player who was never hurt -- the post-match sweep does this to everyone who played')
    t.isFalse(c.called('NetworkResurrectLocalPlayer'),
        'a living player was resurrected')
end)

t.test('and does not stop screen effects it does not own', function()
    -- AnimpostfxStopAll is not scoped to this resource. It stops EVERY effect
    -- on the client, including ones another script started and will not put
    -- back -- so running it over the whole roster after every match reaches a
    -- long way past the arena.
    local c = newClient({ dead = false, health = 200 })

    c.D.Revive()

    t.isFalse(c.called('AnimpostfxStopAll'),
        'every screen effect on the client was stopped for a player who was never hurt')
end)

t.test('but the cheap, idempotent half still runs, because that is the teardown', function()
    -- The guard is about what is EXPENSIVE and felt, not about doing nothing.
    -- Undoing the match's own flags has to happen whatever state the player
    -- is in: a player left invincible or frozen is the failure this whole
    -- path exists to prevent.
    local c = newClient({ dead = false, health = 200 })

    c.D.Revive()

    t.isTrue(c.called('SetEntityInvincible'), 'a player could be left invincible after a match')
    t.isTrue(c.called('SetEntityVisible'), 'a player could be left invisible after a match')
    t.isTrue(c.called('FreezeEntityPosition'), 'a player could be left frozen after a match')
    t.isTrue(c.called('SetEntityCollision'), 'a player could be left without collision after a match')
    t.isTrue(c.called('SetPedCanRagdoll'), 'ragdoll was left disabled after a match')
end)

t.test('a requested health is honoured, and never exceeds the maximum', function()
    local c = newClient({ dead = true, health = 0 })

    c.D.Revive(50)
    t.equals(c.health(), 50)

    local over = newClient({ dead = true, health = 0 })
    over.D.Revive(100000)
    t.equals(over.health(), 200, 'a caller could set health above the ped maximum')
end)

t.test('the net event the server sends lands on the same function', function()
    -- The server fires crimson_arena:client:revive with no arguments. If the
    -- handler were registered under a different name, or expected something
    -- the server does not send, every revive in the resource would be a
    -- no-op with nothing anywhere reporting it.
    local registered = {}
    local env = Sandbox.newEnv({
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { 1.0, 2.0, 3.0 } end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityMaxHealth = function() return 200 end,
        GetEntityHealth = function() return 0 end,
        IsEntityDead = function() return true end,
        IsPedRagdoll = function() return false end,
        SetEntityHealth = function() end,
        NetworkResurrectLocalPlayer = function() end,
        ClearPedBloodDamage = function() end,
        ResetPedVisibleDamage = function() end,
        ClearPedLastWeaponDamage = function() end,
        ClearPedTasksImmediately = function() end,
        AnimpostfxStopAll = function() end,
        SetPedCanRagdoll = function() end,
        SetEntityInvincible = function() end,
        SetEntityVisible = function() end,
        SetEntityCollision = function() end,
        FreezeEntityPosition = function() end,
        RegisterNetEvent = function(name, fn)
            if type(fn) == 'function' then registered[name] = fn end
        end,
        AddEventHandler = function(name, fn) registered[name] = registered[name] or fn end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        Wait = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        exports = setmetatable({}, { __call = function() end }),
        lib = { notify = function() end },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../client/dispatch.lua', env)

    local handler = registered['crimson_arena:client:revive']
    t.isNotNil(handler,
        'nothing is listening for crimson_arena:client:revive -- every revive the server sends is dropped on the floor')

    local ok, err = pcall(handler)
    t.isTrue(ok, 'the handler errored on the no-argument call the server actually makes: ' .. tostring(err))
end)

-- ------------------------------------------------------------------
-- STAYING UP -- the assert window, and why start order stopped mattering
-- ------------------------------------------------------------------

t.test('a player put back down after the revive is stood up again', function()
    -- THE ORDER PROBLEM, in one test. A medical script that registered its
    -- death handler before ours has already decided this player is a
    -- casualty, and drops them into bleed-out a few frames after our revive
    -- has been and gone. One revive loses. The window does not.
    local c = newClient({ dead = true, health = 0 })

    c.D.RevivePersistently()
    local afterFirst = c.countOf('NetworkResurrectLocalPlayer')

    -- Something else puts them down again.
    c.state.dead = true
    c.step()

    t.isTrue(c.countOf('NetworkResurrectLocalPlayer') > afterFirst,
        'the player was put back down after the revive and left there -- this is exactly what losing the start-order race looks like')
end)

t.test('and so is one left writhing rather than dead, which is what bleed-out is', function()
    -- The state that produces the "press G for EMS" prompt. The ped is not
    -- dead, so a check for death alone would walk straight past it.
    local c = newClient({ dead = true, health = 0 })

    c.D.RevivePersistently()
    local afterFirst = c.countOf('ClearPedTasksImmediately')

    c.state.dead = false
    c.state.writhe = true
    c.step()

    t.isTrue(c.countOf('ClearPedTasksImmediately') > afterFirst,
        'a player writhing on the floor was left there -- dead is not the only way a medical script puts somebody down')
end)

t.test('a player who stays up is left completely alone', function()
    local c = newClient({ dead = true, health = 0 })

    c.D.RevivePersistently()
    local afterFirst = c.countOf('NetworkResurrectLocalPlayer')

    -- Nothing puts them down. The window looks, finds them fine, does nothing.
    c.state.dead = false
    c.state.writhe = false
    c.step()

    t.equals(c.countOf('NetworkResurrectLocalPlayer'), afterFirst,
        'the window revived a player who was already on their feet')
end)

t.test('THE HOLD IS NOT A BLEED-OUT: an eliminated player is not dragged out of it', function()
    -- The dangerous case, and the reason the watcher tests for dead-or-
    -- writhing rather than for anything that looks wrong.
    --
    -- ClearDeadState resurrects an eliminated player and then holds them
    -- invincible, invisible and frozen while the spectator camera starts.
    -- That hold leaves the ped ALIVE. A watcher that fired on "invisible" or
    -- "frozen" would release them mid-elimination -- standing them up armed,
    -- visible, in a round they are out of.
    local c = newClient({ dead = false, health = 200 })

    c.D.RevivePersistently()
    local afterFirst = c.countOf('SetEntityVisible')

    -- The arena's own hold: alive, but held.
    c.state.dead = false
    c.state.writhe = false
    c.step()

    t.equals(c.countOf('SetEntityVisible'), afterFirst,
        'the assert window released a player the arena was deliberately holding -- an eliminated player would be stood back up in a live round')
end)

t.test('the window can be switched off, and then it is one revive again', function()
    local c = newClient({ dead = true, health = 0 })
    c.env.Config.Dispatch.revive.assertWindowMs = 0

    c.D.RevivePersistently()
    local afterFirst = c.countOf('NetworkResurrectLocalPlayer')

    c.state.dead = true
    c.step()

    t.equals(c.countOf('NetworkResurrectLocalPlayer'), afterFirst,
        'assertWindowMs = 0 still started a watcher')
end)

t.test('the net event the server sends goes through the persistent path', function()
    -- The whole point is that this is what the SERVER's revive reaches. A
    -- handler still wired to the one-shot revive would leave every real
    -- revive in the resource exposed to the ordering race, while these tests
    -- passed against a function nothing calls.
    local c = newClient({ dead = true, health = 0 })

    c.fireNet('crimson_arena:client:revive')
    local afterFirst = c.countOf('NetworkResurrectLocalPlayer')

    c.state.dead = true
    c.step()

    t.isTrue(c.countOf('NetworkResurrectLocalPlayer') > afterFirst,
        'the net event calls the one-shot revive, so nothing the server sends is protected by the window')
end)

print('clientrevive_spec')
os.exit(t.summary())
