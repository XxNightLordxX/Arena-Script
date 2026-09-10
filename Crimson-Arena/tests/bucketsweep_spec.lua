--[[
    crimson_arena/tests/bucketsweep_spec.lua

    EMPTYING A ROUTING BUCKET, WHICH DELETES THINGS.

    ArenaDispatch.ClearBucket is the one function in this resource that calls
    DeleteEntity. It runs when a match is over, to clear out the props, cars
    and peds left standing in the instance that match was fought in -- and a
    routing bucket number is reused, so what it does not clear is what the
    next round starts among.

    NOTHING IN THIS SUITE HAD EVER RUN IT. A coverage ledger -- every public
    function wrapped at load, the whole suite run, entered or not recorded --
    put ArenaDispatch.ClearBucket in the "never entered" column, and a
    mutation ledger then confirmed what that meant: its guards could be
    inverted one at a time with all ninety-one spec files staying green.
    isolation_spec.lua stubs the four ROUTING natives and asks who is in which
    bucket; no fixture anywhere modelled the ENTITY pools, so the body of this
    function had no way to run.

    The one that matters is the second test below. ClearBucket refuses to
    sweep a bucket somebody is standing in -- in a vehicle, on foot, stranded
    by a restore that did not land -- and an unanswerable server counts as
    occupied. Sweeping one anyway deletes the car a player is sitting in, in
    an instance nobody else can see.

    WHAT IS STUBBED: the entity pools (GetAllVehicles, GetAllObjects,
    GetAllPeds), GetEntityRoutingBucket, DeleteEntity and DoesEntityExist,
    plus the routing and player natives isolation_spec already models. The
    real server/dispatch.lua does the deciding.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('bucketsweep_spec')

--- A world with entities in it.
---
--- @param opts table
---   players  [src] = the bucket that player is standing in
---   peds     [src] = that player's ped handle
---   entities list of { handle, bucket, kind = 'vehicle'|'object'|'ped' }
---   refuse   [handle] = true, for an entity the engine will not delete
---   blind    true: GetPlayers answers nothing, as a server under load can
local function newWorld(opts)
    opts = opts or {}
    local players = opts.players or {}
    local peds = opts.peds or {}
    local deleted = {}
    local logs, debugs = {}, {}

    local function pool(kind)
        return function()
            local out = {}
            for _, entity in ipairs(opts.entities or {}) do
                if entity.kind == kind and not deleted[entity.handle] then
                    out[#out + 1] = entity.handle
                end
            end
            return out
        end
    end

    local function bucketOfEntity(handle)
        for _, entity in ipairs(opts.entities or {}) do
            if entity.handle == handle then return entity.bucket end
        end
        return 0
    end

    local function record(sink)
        return function(fmt, ...)
            sink[#sink + 1] = (select('#', ...) > 0) and fmt:format(...) or fmt
        end
    end

    local env = Sandbox.newEnv({
        GetPlayers = function()
            if opts.blind then return nil end
            local list = {}
            for src in pairs(players) do list[#list + 1] = tostring(src) end
            table.sort(list)
            return list
        end,
        GetPlayerRoutingBucket = function(src) return players[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) players[tonumber(src)] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetPlayerPed = function(src) return peds[tonumber(src)] or 0 end,
        GetPlayerName = function(src) return players[tonumber(src)] and ('player' .. tostring(src)) or nil end,
        GetAllVehicles = pool('vehicle'),
        GetAllObjects = pool('object'),
        GetAllPeds = pool('ped'),
        GetEntityRoutingBucket = function(handle) return bucketOfEntity(handle) end,
        DeleteEntity = function(handle)
            if opts.refuse and opts.refuse[handle] then return end
            deleted[handle] = true
        end,
        DoesEntityExist = function(handle) return deleted[handle] ~= true end,
        Player = function()
            return { state = { set = function() end } }
        end,
        TriggerEvent = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        AddEventHandler = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        exports = setmetatable({}, { __call = function() end }),
        ArenaLog = record(logs),
        ArenaDebug = record(debugs),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.enableAllArenas(env)
    Sandbox.openTheDoors(env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)

    return {
        env = env,
        D = env.ArenaDispatch,
        debugs = debugs,
        gone = function(handle) return deleted[handle] == true end,
        --- Put something in the world after it has been built, which is the
        --- only way to have property in a bucket that was allocated first:
        --- allocating one sweeps it, on purpose, because the number is reused.
        place = function(handle, bucket, kind)
            opts.entities = opts.entities or {}
            opts.entities[#opts.entities + 1] = { handle = handle, bucket = bucket, kind = kind or 'vehicle' }
        end,
        --- Every handle still standing, in order, as one comparable string.
        standing = function()
            local left = {}
            for _, entity in ipairs(opts.entities or {}) do
                if not deleted[entity.handle] then left[#left + 1] = entity.handle end
            end
            table.sort(left)
            return table.concat(left, ',')
        end,
        said = function(needle)
            for _, line in ipairs(debugs) do
                if line:find(needle, 1, true) then return line end
            end
            return nil
        end,
    }
end

-- ======================================================================
-- IT DOES SWEEP
-- ======================================================================

t.test('an empty bucket is emptied, and only of what is actually in it', function()
    local w = newWorld({
        players = { [1] = 0 },                     -- standing in the world, not the bucket
        peds = { [1] = 900 },
        entities = {
            { handle = 11, bucket = 7, kind = 'vehicle' },
            { handle = 12, bucket = 7, kind = 'object' },
            { handle = 13, bucket = 7, kind = 'ped' },
            { handle = 21, bucket = 8, kind = 'vehicle' },   -- another instance
            { handle = 31, bucket = 0, kind = 'object' },    -- the world everybody else is in
        },
    })

    local removed = w.D.ClearBucket(7, 'm1')

    t.equals(removed, 3, 'the three entities left in that instance were not cleared out')
    t.equals(w.standing(), '21,31', 'it reached outside the bucket it was asked to empty')
end)

t.test('and a player\'s own ped is never deleted, even standing in the bucket being swept', function()
    -- The sweep runs at the end of a round, and a player whose restore has
    -- not landed yet is still in the bucket with their ped. Deleting a ped
    -- out from under a player is not something they can recover from.
    local w = newWorld({
        players = { [1] = 0 },
        peds = { [1] = 900 },
        entities = {
            { handle = 900, bucket = 7, kind = 'ped' },      -- a player's own ped
            { handle = 901, bucket = 7, kind = 'ped' },      -- an NPC
        },
    })

    local removed = w.D.ClearBucket(7, 'm1')

    t.equals(removed, 1, 'it should have taken the NPC and nothing else')
    t.isFalse(w.gone(900), 'IT DELETED A PLAYER\'S OWN PED')
    t.isTrue(w.gone(901), 'and the NPC was left standing')
end)

t.test('an entity the engine refuses to delete is counted as refused, not as removed', function()
    local w = newWorld({
        players = { [1] = 0 },
        entities = {
            { handle = 11, bucket = 7, kind = 'vehicle' },
            { handle = 12, bucket = 7, kind = 'object' },
        },
        refuse = { [12] = true },
    })

    t.equals(w.D.ClearBucket(7, 'm1'), 1, 'a refused delete was counted as a removal')
    t.isNotNil(w.said('1 entity(s) removed, 1 refused'),
        'the count the operator reads does not say anything was refused')
end)

-- ======================================================================
-- IT REFUSES TO SWEEP
-- ======================================================================

t.test('DEFECT: a bucket somebody is standing in is left exactly as it is', function()
    -- THE GUARD THIS FILE WAS WRITTEN FOR. Inverting it deleted every entity
    -- in an instance with a player still in it, and the whole suite stayed
    -- green -- the body of this function had never run in any test.
    local w = newWorld({
        players = { [1] = 7 },                     -- still in the instance
        peds = { [1] = 900 },
        entities = {
            { handle = 11, bucket = 7, kind = 'vehicle' },   -- the car they are sitting in
            { handle = 12, bucket = 7, kind = 'object' },
        },
    })

    local removed = w.D.ClearBucket(7, 'm1')

    t.equals(removed, 0, 'it swept a bucket with a player standing in it')
    t.equals(w.standing(), '11,12', 'IT DELETED THE CAR A PLAYER WAS SITTING IN')
    t.isNotNil(w.said('somebody is in it'), 'and said nothing about why it stood down')
end)

t.test('and a server that will not say who is connected counts as occupied', function()
    -- An unanswerable server is the case that looks like an empty bucket and
    -- is not. The only thing this sweep can cost anybody is running while
    -- they are in there, so silence is read as "somebody is".
    local w = newWorld({
        blind = true,
        entities = {
            { handle = 11, bucket = 7, kind = 'vehicle' },
        },
    })

    t.equals(w.D.ClearBucket(7, 'm1'), 0, 'it swept on a server that could not say the room was empty')
    t.equals(w.standing(), '11')
end)

t.test('and a bucket another match is using is left to that match', function()
    local w = newWorld({ players = { [1] = 0 } })

    -- Allocating a bucket SWEEPS it first, on purpose -- the numbers are
    -- reused, and a new round must not start among the last one's wreckage.
    -- So the other match's property goes in after that, which is also the
    -- order it happens in on a real server.
    local theirs = w.D.GetBucket('m2')
    t.isNotNil(theirs, 'isolation is off in this fixture, so this proves nothing')
    w.place(11, theirs, 'vehicle')

    t.equals(w.D.ClearBucket(theirs, 'm1'), 0, 'it emptied a bucket another match was fighting in')
    t.equals(w.standing(), '11', 'the other match\'s round was cleared out from under it')
    t.isNotNil(w.said('another match is using the same number'), 'and it did not say why it stood down')
end)

-- ======================================================================
-- AND THE SHAPES THAT ARE NOT A BUCKET
-- ======================================================================

t.test('bucket 0 and junk are refused outright -- 0 is the world everybody is in', function()
    local w = newWorld({
        players = { [1] = 0 },
        entities = {
            { handle = 11, bucket = 0, kind = 'vehicle' },
            { handle = 12, bucket = 0, kind = 'object' },
        },
    })

    t.equals(w.D.ClearBucket(0, 'm1'), 0, 'IT SWEPT THE WHOLE WORLD')
    t.equals(w.D.ClearBucket(-3, 'm1'), 0)
    t.equals(w.D.ClearBucket('seven', 'm1'), 0)
    t.equals(w.D.ClearBucket(nil, 'm1'), 0)
    t.equals(w.standing(), '11,12', 'the world was cleared out from under everybody in it')
end)

os.exit(t.summary())
