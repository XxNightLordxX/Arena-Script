--[[
    crimson_arena/tests/sweeporder_spec.lua

    THE STRAY SWEEP ASKS WHAT A THING IS BEFORE IT ASKS WHETHER IT EXISTS.

    sweepStrayArenaProps walks the client's whole object pool -- every prop
    the engine is holding, the map's and every other resource's as well as
    ours -- looking for the handful that are pieces of this arena. It used to
    ask DoesEntityExist of every one of them first and GetEntityModel second,
    so a pool of a thousand objects cost two thousand natives to find, most
    rounds, nothing at all. Asking the model first means the thousand that
    are not ours cost one native each, and existence is asked only of the few
    whose model matches.

    WHAT HAS TO STAY THE SAME is everything the sweep DOES: which objects it
    deletes, in what order, what it reads before touching them, how many it
    reports, and that it still refuses to touch a handle that has died. This
    file pins each of those against the real client/match.lua, and then runs
    the real sweep beside a copy of the OLD one over a few hundred seeded
    pools -- dead handles, deletes that fail, deletes that take a second
    object with them, handles nothing knows -- and requires the two to agree
    on every effect. The only difference allowed is the one this change is
    for: fewer existence checks on objects that are not ours.

    WHAT NO SPEC HERE CAN PROVE is the live engine's answer to GetEntityModel
    on a handle that has stopped existing. FiveM client code leans on it
    being 0 everywhere; this file runs both answers -- 0, and the stale model
    this fixture's world gives -- and the sweep skips the handle either way.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('sweeporder_spec')

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }
local OURS = 'stt_prop_stunt_bblock_huge_01'
local FOREIGN = 'prop_bench_01a'

-- ======================================================================
-- A CLIENT, AND A POOL THE SPEC WRITES
-- ======================================================================

--- A client/match.lua in a modelled game, cut down to what a sweep touches.
--- Its own copy rather than propsweep_spec's: that harness answers what a
--- build leaves behind, this one has to lay a pool of its own design over
--- the world and count every native the sweep spends on it.
--- @param factor number|nil
--- @param arenaKey string|nil
local function newClient(factor, arenaKey)
    local world = World.new({ streamRange = 100000.0 })
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { world = world, printed = {}, toServer = {} }

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            c.toServer[#c.toServer + 1] = { name = name, payload = payload }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        NetworkResurrectLocalPlayer = function() end,
        ClearPedBloodDamage = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        SetPedArmour = function() end,
        SetEntityHealth = function() end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end,
        RemoveWeaponFromPed = function() end,
        DisableControlAction = function() end,
        DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 900 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 5 end,
        GetPlayerServerId = function() return 7 end,
        PlayerId = function() return 0 end,
        GetPlayerFromServerId = function(serverId) return serverId end,
        NetworkIsPlayerActive = function() return true end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        AddBlipForEntity = function(ped) return 6000 + (ped or 0) end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        EndTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        SetBlipDisplay = function() end,
        DoesBlipExist = function() return true end,
        RemoveBlip = function() end,
        SetEntityDrawOutline = function() end,
        SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function() end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,
        SetLocalPlayerVisibleLocally = function() end,
        TaskStartScenarioInPlace = function() end,
        SetBlockingOfNonTemporaryEvents = function() end,
        SetPedCanRagdoll = function() end,
        print = function(line) c.printed[#c.printed + 1] = tostring(line) end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end
    overrides.GetGameTimer = function() return runner.elapsed end

    local env = Sandbox.newArenaEnv(overrides)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)
    c.env = env

    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('no handler for ' .. name) end
        local args = table.pack(...)
        local thread = coroutine.create(function() handler(table.unpack(args, 1, args.n)) end)
        for _ = 1, 400 do
            if coroutine.status(thread) == 'dead' then break end
            local ok, err = coroutine.resume(thread)
            if not ok then error(err) end
        end
        assert(coroutine.status(thread) == 'dead', name .. ' never finished')
    end

    function c.enter(key, sizeFactor)
        local arena = env.Config.Arenas[key]
        local spawn = env.Arena.PickSpawn(key, nil, 1)
        c.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1', arenaKey = key, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false, loadout = { weapons = {} },
            sizeFactor = sizeFactor,
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius * math.max(1.0, sizeFactor or 1.0),
                warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        })
    end

    --- One teardown of the arena this client last built, which is exactly
    --- one sweep of it: builtArena outlives the round on purpose, so every
    --- exit sweeps it again whether or not there is a match left.
    function c.sweep()
        c.fire('crimson_arena:client:exitArena', {})
    end

    --- Every "swept N" line the server console was sent since `from`.
    function c.sweptLines(from)
        local out = {}
        for i = (from or 0) + 1, #c.toServer do
            local sent = c.toServer[i]
            if sent.name == 'crimson_arena:server:clientDebug' and type(sent.payload) == 'table'
                and type(sent.payload.line) == 'string'
                and sent.payload.line:find('swept', 1, true) then
                out[#out + 1] = sent.payload.line
            end
        end
        return out
    end

    --- The same, as the counts they carry.
    function c.sweptCounts(from)
        local out = {}
        for _, line in ipairs(c.sweptLines(from)) do
            out[#out + 1] = tonumber(line:match('swept (%d+) stray piece'))
        end
        return out
    end

    -- Built once, then taken down, so builtArena names the arena and the
    -- pool starts empty of our own pieces.
    c.enter(arenaKey or 'skydome', factor)
    c.sweep()
    return c
end

--- A POOL OF OBJECTS THE SPEC DESCRIBES, and a record of every native the
--- sweep spends on them.
---
--- Each entry: { handle, model, x, y, z, alive, deadModel, sticky, takes }.
---   alive      false = the handle is in the pool's list but has died
---   deadModel  what GetEntityModel answers for a dead handle: 'zero' (the
---              live engine) or 'stale' (this fixture's world)
---   sticky     DeleteObject does nothing to it -- somebody else owns it
---   takes      deleting it also kills this other handle
--- `extra` lists handles the pool reports that nothing describes -- garbage
--- the natives must answer without raising.
--- @param spec table[]
--- @param extra integer[]|nil
--- @param fallback table|nil -- natives for any handle not in `spec`
local function newPool(spec, extra, fallback)
    local pool = { byHandle = {}, order = {}, calls = {}, effects = {}, extra = extra }
    for _, entry in ipairs(spec) do
        local copy = {}
        for k, v in pairs(entry) do copy[k] = v end
        pool.byHandle[copy.handle] = copy
        pool.order[#pool.order + 1] = copy
    end
    local listed, stranger = {}, {}
    for _, entry in ipairs(pool.order) do listed[#listed + 1] = entry.handle end
    for _, handle in ipairs(extra or {}) do
        listed[#listed + 1] = handle
        stranger[handle] = true
    end

    local function count(native, handle)
        local key = native .. ':' .. tostring(handle)
        pool.calls[key] = (pool.calls[key] or 0) + 1
        pool.calls[native] = (pool.calls[native] or 0) + 1
    end
    local function effect(what, handle) pool.effects[#pool.effects + 1] = what .. ':' .. tostring(handle) end

    local N = {}
    N.joaat = function(name) return name end
    N.GetGamePool = function(kind)
        count('GetGamePool', kind)
        if pool.nilPool then return nil end
        local out = {}
        if fallback then
            for _, handle in ipairs(fallback.GetGamePool(kind) or {}) do out[#out + 1] = handle end
        end
        if kind == 'CObject' then
            for _, handle in ipairs(listed) do out[#out + 1] = handle end
        end
        return out
    end
    --- Is this handle one the spec is answering for -- described, or a
    --- stranger it listed on purpose -- rather than one of the world's own?
    local function ours(handle)
        return pool.byHandle[handle] ~= nil or stranger[handle] == true
            or not (fallback and fallback.owns(handle))
    end

    N.GetEntityModel = function(handle)
        if not ours(handle) then return fallback.GetEntityModel(handle) end
        count('GetEntityModel', handle)
        local entry = pool.byHandle[handle]
        if not entry then return 0 end
        if entry.alive then return entry.model end
        return entry.deadModel == 'stale' and entry.model or 0
    end
    N.DoesEntityExist = function(handle)
        if not ours(handle) then return fallback.DoesEntityExist(handle) end
        count('DoesEntityExist', handle)
        effect('exists?', handle)
        local entry = pool.byHandle[handle]
        -- The world's rule for a handle it does not know: a ped, and peds
        -- always exist.
        if not entry then return true end
        return entry.alive == true
    end
    N.GetEntityCoords = function(handle)
        if not ours(handle) then return fallback.GetEntityCoords(handle) end
        count('GetEntityCoords', handle)
        effect('coords', handle)
        local entry = pool.byHandle[handle]
        if not entry then return { x = 0.0, y = 0.0, z = 0.0 } end
        return { x = entry.x, y = entry.y, z = entry.z }
    end
    N.SetEntityAsMissionEntity = function(handle, ...)
        if not ours(handle) then return fallback.SetEntityAsMissionEntity(handle, ...) end
        effect('mission', handle)
    end
    N.DeleteObject = function(handle)
        if not ours(handle) then return fallback.DeleteObject(handle) end
        effect('delete', handle)
        local entry = pool.byHandle[handle]
        if not entry then return end
        if not entry.sticky then entry.alive = false end
        if entry.takes and pool.byHandle[entry.takes] then pool.byHandle[entry.takes].alive = false end
    end

    --- Which of the described objects are still alive, as one string.
    function pool.alive()
        local out = {}
        for _, entry in ipairs(pool.order) do
            out[#out + 1] = tostring(entry.handle) .. (entry.alive and '+' or '-')
        end
        return table.concat(out, ' ')
    end

    pool.N = N
    return pool
end

--- Lays a pool over a client: every native the sweep reads goes through it,
--- and anything it does not describe falls through to the world.
local function lay(c, pool)
    local world = c.world
    local fallback = {
        owns = function(handle) return world.objects[handle] ~= nil end,
        GetGamePool = world.natives.GetGamePool,
        GetEntityModel = world.natives.GetEntityModel,
        DoesEntityExist = world.natives.DoesEntityExist,
        GetEntityCoords = world.natives.GetEntityCoords,
        SetEntityAsMissionEntity = world.natives.SetEntityAsMissionEntity,
        DeleteObject = world.natives.DeleteObject,
    }
    -- Rebuilt with the world behind it, then installed.
    local laid = newPool(pool.order, pool.extra, fallback)
    laid.nilPool = pool.nilPool
    for _, name in ipairs({ 'GetGamePool', 'GetEntityModel', 'DoesEntityExist', 'GetEntityCoords',
                            'SetEntityAsMissionEntity', 'DeleteObject' }) do
        c.env[name] = laid.N[name]
    end
    return laid
end

--- Puts the world's own natives back.
local function lift(c)
    for _, name in ipairs({ 'GetGamePool', 'GetEntityModel', 'DoesEntityExist', 'GetEntityCoords',
                            'SetEntityAsMissionEntity', 'DeleteObject' }) do
        c.env[name] = c.world.natives[name]
    end
end

--- THE OLD SWEEP, KEPT HERE AS THE REFERENCE. Existence first, model second
--- -- exactly the loop client/match.lua ran before the order was swapped.
--- It is the thing the new one is compared against, so it is never edited.
--- @return integer removed
--- @return string|nil line
local function oldSweep(N, sweep, arenaKey)
    if not sweep then return 0, nil end

    local wanted = {}
    for name in pairs(sweep.models) do wanted[N.joaat(name)] = true end

    local removed = 0
    for _, object in ipairs(N.GetGamePool('CObject') or {}) do
        if N.DoesEntityExist(object) and wanted[N.GetEntityModel(object)] then
            local at = N.GetEntityCoords(object)
            local dx = (at.x or 0.0) - sweep.x
            local dy = (at.y or 0.0) - sweep.y
            local dz = (at.z or 0.0) - sweep.z
            if (dx * dx + dy * dy) <= sweep.radius * sweep.radius
                and math.abs(dz) <= sweep.height
            then
                N.SetEntityAsMissionEntity(object, true, true)
                N.DeleteObject(object)
                if not N.DoesEntityExist(object) then removed = removed + 1 end
            end
        end
    end

    local line = nil
    if removed > 0 then
        line = ('arena scenery: swept %d stray piece(s) still standing at \'%s\' from an earlier round.')
            :format(removed, tostring(arenaKey))
    end
    return removed, line
end

--- The sweep a client at this factor runs, straight from the real Arena.
local function sweepFor(c, factor) return c.env.Arena.PropSweep('skydome', factor) end

local function entry(handle, model, x, y, z, extra)
    local e = { handle = handle, model = model, x = x, y = y, z = z, alive = true }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
end

-- ======================================================================
-- THE COST THIS CHANGE IS FOR
-- ======================================================================

t.test('THE COST: a sweep asks existence only of the objects whose model is ours', function()
    -- A busy server's object pool is hundreds of props that are not ours.
    -- Every one of them used to cost a DoesEntityExist before the sweep even
    -- looked at what it was; now the model is asked first, and existence
    -- only of the few that match.
    local c = newClient(1.0)
    local spec = {}
    for i = 1, 300 do
        spec[#spec + 1] = entry(90000 + i, FOREIGN, SKY.x + (i % 17), SKY.y - (i % 13), SKY.z)
    end
    -- Three of ours among them, inside the reach.
    spec[#spec + 1] = entry(91001, OURS, SKY.x, SKY.y, SKY.z - 10.0)
    spec[#spec + 1] = entry(91002, 'prop_container_01a', SKY.x + 20.0, SKY.y, SKY.z)
    spec[#spec + 1] = entry(91003, 'prop_barrier_work05', SKY.x, SKY.y + 30.0, SKY.z + 1.0)

    local laid = lay(c, newPool(spec))
    c.sweep()
    lift(c)

    local foreignExists = 0
    for i = 1, 300 do foreignExists = foreignExists + (laid.calls['DoesEntityExist:' .. (90000 + i)] or 0) end
    t.equals(foreignExists, 0,
        ('the sweep asked DoesEntityExist %d time(s) of props that are not ours'):format(foreignExists))

    -- Existence is still asked of ours: once before, once after the delete.
    for _, handle in ipairs({ 91001, 91002, 91003 }) do
        t.equals(laid.calls['DoesEntityExist:' .. handle], 2,
            ('our own piece %d was not checked before and after its delete'):format(handle))
    end

    -- THE BUDGET, AS A WHOLE: one model read per object in the pool, and
    -- existence only for ours. An edit that puts the check back in front
    -- spends 300 more and fails here.
    t.equals(laid.calls['GetEntityModel'], 303, 'the model was not read exactly once per pooled object')
    t.equals(laid.calls['DoesEntityExist'], 6, 'existence was asked of more than our own three pieces')
    t.equals(laid.calls['GetGamePool'], 1, 'one teardown walked the pool more than once')
end)

t.test('and the saving holds on a pool with nothing of ours in it at all', function()
    -- The common round: the teardown just took everything down, the sweep
    -- walks the pool and finds nothing. That walk is now one native per
    -- object instead of two.
    local c = newClient(1.0)
    local spec = {}
    for i = 1, 200 do spec[#spec + 1] = entry(80000 + i, FOREIGN, SKY.x, SKY.y, SKY.z) end
    local laid = lay(c, newPool(spec))
    c.sweep()
    lift(c)
    t.equals(laid.calls['DoesEntityExist'] or 0, 0, 'existence was asked of a pool with nothing of ours in it')
    t.equals(laid.calls['GetEntityModel'], 200)
end)

-- ======================================================================
-- WHAT THE SWEEP DOES, PINNED
-- ======================================================================

t.test('existence is still asked of our own piece BEFORE it is read or touched', function()
    -- The half of the old order that has to survive: a matching handle is
    -- confirmed alive before its coordinates are read and before it is
    -- claimed and deleted. Moving the check after any of those is reading a
    -- dead handle, which is exactly what the check is for.
    local c = newClient(1.0)
    local laid = lay(c, newPool({ entry(70001, OURS, SKY.x, SKY.y, SKY.z) }))
    c.sweep()
    lift(c)
    t.equals(table.concat(laid.effects, ' '),
        'exists?:70001 coords:70001 mission:70001 delete:70001 exists?:70001',
        'the sweep touched our piece in a different order')
end)

t.test('a handle that died before it was read is skipped -- whatever the engine says its model is', function()
    -- The engine hands back a list; an object in it can stop existing before
    -- the loop reaches it. The live engine answers 0 for the model of a
    -- handle that has gone, and this fixture answers the old model. Either
    -- way it must not be read, claimed, deleted or counted.
    for _, deadModel in ipairs({ 'zero', 'stale' }) do
        local c = newClient(1.0)
        local laid = lay(c, newPool({
            entry(60001, OURS, SKY.x, SKY.y, SKY.z, { alive = false, deadModel = deadModel }),
            entry(60002, OURS, SKY.x + 5.0, SKY.y, SKY.z),
        }))
        local from = #c.toServer
        c.sweep()
        lift(c)
        t.equals(laid.calls['GetEntityCoords:60001'], nil, deadModel .. ': a dead handle had its coordinates read')
        for _, e in ipairs(laid.effects) do
            t.isTrue(e ~= 'mission:60001' and e ~= 'delete:60001',
                deadModel .. ': a dead handle was claimed or deleted: ' .. e)
        end
        t.equals(table.concat(c.sweptCounts(from), ','), '1',
            deadModel .. ': the dead handle was counted as swept')
    end
end)

t.test('a delete that takes a second object with it does not touch or count the second one', function()
    for _, deadModel in ipairs({ 'zero', 'stale' }) do
        local c = newClient(1.0)
        local laid = lay(c, newPool({
            entry(61001, OURS, SKY.x, SKY.y, SKY.z, { takes = 61002 }),
            entry(61002, OURS, SKY.x + 1.0, SKY.y, SKY.z, { deadModel = deadModel }),
        }))
        local from = #c.toServer
        c.sweep()
        lift(c)
        t.equals(laid.alive(), '61001- 61002-')
        t.equals(laid.calls['GetEntityCoords:61002'], nil, deadModel .. ': the second object was read after it died')
        t.equals(table.concat(c.sweptCounts(from), ','), '1', deadModel .. ': one delete was counted twice')
    end
end)

t.test('a piece that will not delete is not counted as swept', function()
    -- Owned by something else, it survives DeleteObject. The count is what
    -- actually went, checked after the delete -- a count of attempts would
    -- tell the operator a floor was cleared that is still standing.
    local c = newClient(1.0)
    local laid = lay(c, newPool({
        entry(62001, OURS, SKY.x, SKY.y, SKY.z),
        entry(62002, OURS, SKY.x + 3.0, SKY.y, SKY.z, { sticky = true }),
        entry(62003, 'prop_container_01b', SKY.x - 3.0, SKY.y, SKY.z),
    }))
    local from = #c.toServer
    c.sweep()
    lift(c)
    t.equals(laid.alive(), '62001- 62002+ 62003-')
    t.equals(table.concat(c.sweptCounts(from), ','), '2', 'the count included a piece that did not go')
end)

t.test('nothing swept, nothing said', function()
    local c = newClient(1.0)
    lay(c, newPool({ entry(63001, FOREIGN, SKY.x, SKY.y, SKY.z), entry(63002, OURS, SKY.x + 500.0, SKY.y, SKY.z) }))
    local from = #c.toServer
    c.sweep()
    lift(c)
    t.equals(#c.sweptCounts(from), 0, 'a sweep that removed nothing still reported')
end)

t.test('both sides of the reach: at the radius is swept, a hair past it is not', function()
    -- sweep.x + radius is exact in binary for the shipped skydome, so the
    -- first entry sits ON the boundary and the comparison's `<=` decides it.
    local c = newClient(1.0)
    local sweep = sweepFor(c, 1.0)
    t.equals((SKY.x + sweep.radius) - SKY.x, sweep.radius, 'the boundary point is not exact, so this proves nothing')
    local laid = lay(c, newPool({
        entry(64001, OURS, SKY.x + sweep.radius, SKY.y, SKY.z),
        entry(64002, OURS, SKY.x, SKY.y - sweep.radius, SKY.z),
        entry(64003, OURS, SKY.x + sweep.radius + 0.01, SKY.y, SKY.z),
        entry(64004, OURS, SKY.x, SKY.y - sweep.radius - 0.01, SKY.z),
        entry(64005, OURS, SKY.x + sweep.radius - 0.01, SKY.y, SKY.z),
    }))
    c.sweep()
    lift(c)
    t.equals(laid.alive(), '64001- 64002- 64003+ 64004+ 64005-')
end)

t.test('both sides of the height: at the limit is swept, a hair past it is not, above and below', function()
    local c = newClient(1.0)
    local sweep = sweepFor(c, 1.0)
    local laid = lay(c, newPool({
        entry(65001, OURS, SKY.x, SKY.y, SKY.z + sweep.height),
        entry(65002, OURS, SKY.x, SKY.y, SKY.z - sweep.height),
        entry(65003, OURS, SKY.x, SKY.y, SKY.z + sweep.height + 0.01),
        entry(65004, OURS, SKY.x, SKY.y, SKY.z - sweep.height - 0.01),
    }))
    c.sweep()
    lift(c)
    t.equals(laid.alive(), '65001- 65002- 65003+ 65004+')
end)

t.test('a pool that answers nil is an empty pool, not an error', function()
    local c = newClient(1.0)
    local pool = newPool({ entry(66001, OURS, SKY.x, SKY.y, SKY.z) })
    pool.nilPool = true
    local laid = lay(c, pool)
    local ok, err = pcall(c.sweep)
    lift(c)
    t.isTrue(ok, 'a nil pool raised: ' .. tostring(err))
    t.equals(laid.calls['GetGamePool'], 1)
    t.equals(laid.calls['GetEntityModel'] or 0, 0)
end)

t.test('a handle nothing knows is answered without raising and left alone', function()
    -- The pool is the engine's list; this sweep must survive whatever is in
    -- it. A handle neither this world nor the pool describes reads as model
    -- 0, which is nobody's.
    local c = newClient(1.0)
    local laid = lay(c, newPool({ entry(67001, OURS, SKY.x, SKY.y, SKY.z) }, { 0, -1, 424242 }))
    local from = #c.toServer
    local ok, err = pcall(c.sweep)
    lift(c)
    t.isTrue(ok, 'an unknown handle raised: ' .. tostring(err))
    t.equals(table.concat(c.sweptCounts(from), ','), '1')
    for _, handle in ipairs({ 0, -1, 424242 }) do
        t.equals(laid.calls['GetEntityModel:' .. handle], 1, 'an unknown handle was not asked what it is')
        for _, e in ipairs(laid.effects) do
            t.isTrue(e ~= 'coords:' .. handle and e ~= 'mission:' .. handle and e ~= 'delete:' .. handle,
                'an unknown handle was touched: ' .. e)
        end
    end
end)

t.test('an arena with no sweep never walks the pool at all', function()
    -- The ground arena is the safety argument for the whole sweep: it names
    -- a container the map is full of. Its teardown must not so much as list
    -- the pool.
    local c = newClient(nil, 'trailerpark')
    local laid = lay(c, newPool({ entry(68001, 'prop_container_01a', -282.0, -2030.0, 30.0) }))
    c.sweep()
    lift(c)
    t.equals(laid.calls['GetGamePool'] or 0, 0, 'a ground arena walked the object pool')
    t.equals(laid.alive(), '68001+')
end)

t.test('the pool is read fresh on every sweep, never remembered', function()
    local c = newClient(1.0)
    local first = lay(c, newPool({}))
    c.sweep()
    t.equals(first.calls['GetGamePool'], 1)
    local second = lay(c, newPool({ entry(69001, OURS, SKY.x, SKY.y, SKY.z) }))
    c.sweep()
    lift(c)
    t.equals(second.alive(), '69001-', 'a piece that appeared after the last sweep was not found by the next')
end)

t.test('ours is matched by the hash the engine reports, never by the name the config writes', function()
    -- THIS FIXTURE'S WORLD HASHES A NAME TO ITSELF, so every other test in
    -- this file would still pass on a sweep that keyed its wanted set by the
    -- NAME -- and with the model now asked first, that set is the only thing
    -- deciding whether existence is ever asked. The engine reports a model
    -- as its joaat hash, a number. Here the hash is a number too (FNV-1a,
    -- fixed, so every run agrees), and a prop reporting a bare name, which
    -- no engine does, is not ours.
    local c = newClient(1.0)
    local function hash(name)
        local h = 2166136261
        for i = 1, #name do h = ((h ~ name:byte(i)) * 16777619) & 0xffffffff end
        return h
    end
    local original = c.env.joaat
    c.env.joaat = hash
    local laid = lay(c, newPool({
        entry(67001, hash(OURS), SKY.x, SKY.y, SKY.z - 10.0),
        entry(67002, hash('prop_container_01a'), SKY.x + 20.0, SKY.y, SKY.z),
        entry(67003, hash(FOREIGN), SKY.x, SKY.y, SKY.z),
        entry(67004, OURS, SKY.x, SKY.y + 5.0, SKY.z),
    }))
    local from = #c.toServer
    c.sweep()
    lift(c)
    c.env.joaat = original
    t.equals(laid.alive(), '67001- 67002- 67003+ 67004+', 'the sweep did not match by the model\'s hash')
    t.equals(table.concat(c.sweptCounts(from), ','), '2')
    -- Ours were confirmed alive before and after the delete, whatever order
    -- the other two were asked in.
    for _, handle in ipairs({ 67001, 67002 }) do
        t.equals(laid.calls['DoesEntityExist:' .. handle], 2, ('%d was not checked before and after'):format(handle))
    end
end)

-- ======================================================================
-- THE DIFFERENTIAL: THE REAL SWEEP AGAINST THE OLD ONE
-- ======================================================================

--- A deterministic generator: the same seed is the same cases on every
--- machine and every run.
local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return (state // 65536) % n + 1
    end
end

local CLIENTS = { [1.0] = newClient(1.0), [1.5] = newClient(1.5), [2.0] = newClient(2.0) }
local FACTORS = { 1.0, 1.5, 2.0 }

--- FOUR HUNDRED AND TWENTY POOLS, the same ones on every run. Each is up to
--- thirty objects: two in three of our own models, placed inside the reach,
--- exactly on its radius or height, a hair outside, or far away; one in
--- seven already dead when read, answering 0 or its stale model; one in
--- eight that will not delete; one in eight whose delete kills another; and
--- now and then a handle nothing describes.
local function makeCases()
    local wantedNames = {}
    for name in pairs(sweepFor(CLIENTS[1.0], 1.0).models) do wantedNames[#wantedNames + 1] = name end
    table.sort(wantedNames)
    local foreignNames = { FOREIGN, 'prop_tree_pine_01', 'prop_container_05a', 'prop_barrier_work06a' }

    local rand = generator(20260925)
    local cases = {}
    for case = 1, 420 do
        local factor = FACTORS[rand(#FACTORS)]
        local sweep = sweepFor(CLIENTS[factor], factor)

        local spec, extra = {}, {}
        local size = rand(31) - 1
        local base = 100000 + case * 100
        for i = 1, size do
            local model = rand(3) == 1 and foreignNames[rand(#foreignNames)] or wantedNames[rand(#wantedNames)]
            local x, y, z = sweep.x, sweep.y, sweep.z
            local where = rand(9)
            if where == 1 then x = x + sweep.radius
            elseif where == 2 then y = y - sweep.radius - 0.01
            elseif where == 3 then x = x + sweep.radius + 100.0
            elseif where == 4 then z = z + sweep.height
            elseif where == 5 then z = z - sweep.height - 0.01
            else
                x = x + (rand(201) - 101) * sweep.radius / 150.0
                y = y + (rand(201) - 101) * sweep.radius / 150.0
                z = z + (rand(101) - 51) * sweep.height / 60.0
            end
            local e = entry(base + i, model, x, y, z)
            if rand(7) == 1 then e.alive = false end
            e.deadModel = rand(2) == 1 and 'zero' or 'stale'
            if rand(8) == 1 then e.sticky = true end
            spec[#spec + 1] = e
        end
        for i = 1, size do
            if rand(8) == 1 then spec[i].takes = base + rand(size) end
        end
        if rand(10) == 1 then extra[#extra + 1] = ({ 0, -1, 999999 })[rand(3)] end

        cases[#cases + 1] = { n = case, factor = factor, sweep = sweep, spec = spec, extra = extra }
    end
    return cases
end

--- One case, twice: the reference on its own copy of the pool, and the real
--- client/match.lua on another.
local function runCase(case)
    local ref = newPool(case.spec, case.extra)
    local refRemoved, refLine = oldSweep(ref.N, case.sweep, 'skydome')

    local c = CLIENTS[case.factor]
    local laid = lay(c, newPool(case.spec, case.extra))
    local from = #c.toServer
    c.sweep()
    lift(c)

    return {
        ref = ref, laid = laid, refRemoved = refRemoved, refLine = refLine,
        lines = c.sweptLines(from),
        label = ('case %d (factor %.1f, %d objects)'):format(case.n, case.factor, #case.spec),
    }
end

local CASES = makeCases()

t.test('over four hundred seeded pools the real sweep does exactly what the old one did', function()
    local swept, dead, sticky, takes, strangers = 0, 0, 0, 0, 0

    for _, case in ipairs(CASES) do
        local r = runCase(case)
        local label = r.label
        t.equals(r.laid.alive(), r.ref.alive(), label .. ': different objects survived')

        -- EVERY READ AND EVERY WRITE, IN ORDER, except the one thing the
        -- change moves: the existence check made BEFORE the model is known.
        -- The check made after a delete -- the one the count is built on --
        -- is kept in the comparison.
        local function strip(list)
            local out = {}
            for i, e in ipairs(list) do
                local what, handle = e:match('^(.-):(.*)$')
                if what ~= 'exists?' or list[i - 1] == 'delete:' .. handle then out[#out + 1] = e end
            end
            return table.concat(out, ' ')
        end
        t.equals(strip(r.laid.effects), strip(r.ref.effects), label .. ': the sweep read or touched different objects')

        -- AND EXISTENCE IS STILL ASKED RIGHT BEFORE A READ: no object's
        -- coordinates are read unless the effect just before is that same
        -- object confirmed alive. True of the old order; kept by the new.
        for i, e in ipairs(r.laid.effects) do
            local handle = e:match('^coords:(.*)$')
            if handle then
                t.equals(r.laid.effects[i - 1], 'exists?:' .. handle,
                    label .. ': coordinates were read without existence asked first')
            end
        end

        t.equals(r.laid.calls['GetEntityCoords'] or 0, r.ref.calls['GetEntityCoords'] or 0,
            label .. ': a different number of coordinates was read')
        t.equals(r.laid.calls['GetGamePool'], 1, label .. ': one teardown, one walk of the pool')
        if r.refRemoved > 0 then
            t.equals(#r.lines, 1, label .. ': one sweep, one line')
            t.equals(r.lines[1], r.refLine, label .. ': a different line was reported')
            swept = swept + 1
        else
            t.equals(#r.lines, 0, label .. ': a sweep that removed nothing reported')
        end

        for _, e in ipairs(case.spec) do
            if not e.alive then dead = dead + 1 end
            if e.sticky then sticky = sticky + 1 end
            if e.takes then takes = takes + 1 end
        end
        strangers = strangers + #case.extra
    end

    -- THE CASES REALLY COVERED WHAT THEY CLAIM, asserted rather than hoped.
    t.equals(#CASES, 420)
    t.isTrue(swept > 100, 'fewer than a hundred cases swept anything: ' .. swept)
    t.isTrue(dead > 50 and sticky > 50 and takes > 50 and strangers > 10,
        ('too few dead (%d), sticky (%d), cascading (%d) or stranger (%d) handles')
            :format(dead, sticky, takes, strangers))
end)

t.test('and over the same pools it never asks existence of a prop that is not ours', function()
    -- THE SAVING, case by case: never more existence checks than the old
    -- order, and none at all on an object whose model is not ours.
    local saved = 0
    for _, case in ipairs(CASES) do
        local r = runCase(case)
        t.isTrue((r.laid.calls['DoesEntityExist'] or 0) <= (r.ref.calls['DoesEntityExist'] or 0),
            r.label .. ': the new order asked existence MORE often')
        for _, e in ipairs(case.spec) do
            if not case.sweep.models[e.model] then
                t.equals(r.laid.calls['DoesEntityExist:' .. e.handle], nil,
                    r.label .. ': existence was asked of a prop that is not ours')
            end
        end
        -- One model read per object in the pool, never more.
        t.equals(r.laid.calls['GetEntityModel'] or 0, #case.spec + #case.extra,
            r.label .. ': the model was not read exactly once per pooled object')
        saved = saved + (r.ref.calls['DoesEntityExist'] or 0) - (r.laid.calls['DoesEntityExist'] or 0)
    end
    t.isTrue(saved > 1000, 'the new order saved almost nothing: ' .. saved)
end)

os.exit(t.summary())
