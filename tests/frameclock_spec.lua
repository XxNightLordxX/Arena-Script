--[[
    crimson_arena/tests/frameclock_spec.lua

    ONE CLOCK READ A FRAME, IN THE THREAD THAT CARRIES THE DEATH BACKSTOP.

    The per-frame arena loop in client/match.lua asks the clock two things:
    whether the vitals re-assert after a respawn is still running (1.5 s),
    and whether the floor is due its check for holes (every 2 s). It used to
    ask GET_GAME_TIMER separately at each of three places -- the window, the
    repair's gate and the repair's next due time -- and holdVitals never
    lowers the window, so after the first respawn of a session every frame
    read the clock twice, three times on a repair frame.

    GET_GAME_TIMER is the frame's clock: it does not move inside a frame,
    and nothing between the three reads yields. So one read at the top of
    the frame answers all three the same. That claim is what this file
    holds, three ways:

      THE COST. Exactly one read per arena frame, in every state the loop
      can be in. This is the half that failed before the change.

      THE TWO FEATURES THE CLOCK DRIVES, pinned on both sides of their
      edges: the vitals window re-asserts on every frame strictly before its
      end and on none at or after it, and the floor is checked on the first
      frame at or after its due time, never on one before.

      THE EQUIVALENCE. The loop as it was is kept below, verbatim in its
      code, and spliced back into the real file to make a reference client.
      Both are driven through the same seeded sequences of frames, clock
      jumps, respawns, deaths -- live, and in the countdown, where the frame
      itself revives the player -- vanishing floor tiles, exits and
      re-entries. Every native either one calls, except the clock reads
      that were removed, must be the same, with the same arguments, in the
      same order, from the same thread.

    WHAT ONLY THE GAME CAN SAY. That the engine's timer really is the same
    for every read inside one frame. The fixture's clock is, by construction.
    If it ever were not, the reads it replaced were microseconds apart, so
    neither the 1.5 s window nor the 2 s cadence could move by anything a
    player could see.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('frameclock_spec')

local PATH = '../Crimson-Arena/client/match.lua'

local function readFile(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

-- ======================================================================
-- THE REFERENCE: THE LOOP AS IT WAS
--
-- Everything between the pause-menu block and the end of the floor check,
-- as it stood before the clock was read once. Comments dropped; code
-- verbatim. It is spliced over the same stretch of the real file, so the
-- reference client differs from the real one in this stretch and nowhere
-- else.
-- ======================================================================

local SPLICE_FROM = '            if IsPauseMenuActive() then\n                SetFrontendActive(false)\n            end\n'
local SPLICE_TO = '                repairArenaProps()\n            end\n'

local REFERENCE_STRETCH = SPLICE_FROM .. [[

            if deathReported or not matchLive then
                DisablePlayerFiring(PlayerId(), true)
                DisableControlAction(0, 24, true)
                DisableControlAction(0, 25, true)
                DisableControlAction(0, 257, true)
                DisableControlAction(0, 263, true)
            end

            if not deathReported
                and arenaVitals.until_ > 0
                and GetGameTimer() < arenaVitals.until_
            then
                local ped = PlayerPedId()
                if arenaVitals.health then SetEntityHealth(ped, arenaVitals.health) end
                if arenaVitals.armour then SetPedArmour(ped, arenaVitals.armour) end
            end

            handleDeath(PlayerPedId())

            if repairArenaProps and GetGameTimer() >= nextArenaRepairAt then
                nextArenaRepairAt = GetGameTimer() + ARENA_REPAIR_MS
]] .. SPLICE_TO

--- The real file with the reference stretch put back.
local function referenceSource()
    local text = readFile(PATH)
    local from = text:find(SPLICE_FROM, 1, true)
    t.isNotNil(from, 'the pause-menu block the reference is spliced after is gone')
    t.isNil(text:find(SPLICE_FROM, from + 1, true), 'the pause-menu block appears twice')
    local to = text:find(SPLICE_TO, from, true)
    t.isNotNil(to, 'the end of the floor check the reference is spliced up to is gone')
    local stretch = text:sub(from, to + #SPLICE_TO - 1)
    t.contains(stretch, 'handleDeath(PlayerPedId())', 'the spliced stretch is not the frame loop')
    t.isTrue(#stretch < 4000, 'the spliced stretch runs past the frame loop')
    return text:sub(1, from - 1) .. REFERENCE_STRETCH .. text:sub(to + #SPLICE_TO)
end

-- ======================================================================
-- THE FIXTURE
-- ======================================================================

local ARMOUR = 100

--- A client/match.lua in the modelled world, with a FRAME clock under the
--- test's hand and every native recorded with the thread that called it.
--- @param opts table? -- { source = text of client/match.lua }
local function newClient(opts)
    opts = opts or {}
    local world = World.new()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = {
        world = world, runner = runner, clock = 50000,
        log = {},          -- every native call: { name, args, co }
        toServer = {},
        vitals = {},       -- every SetEntityHealth / SetPedArmour on the player, with the frame clock
        dead = false,
        arenas = {},       -- every thread that has ever been the arena frame, for this client
    }

    -- THREADS NAMED IN THE ORDER THEY ARE FIRST SEEN, so two clients driven
    -- the same way name the same thread the same thing.
    local labels, nextLabel = {}, 0
    local function label(co)
        if not labels[co] then
            nextLabel = nextLabel + 1
            labels[co] = 'thread' .. nextLabel
        end
        return labels[co]
    end

    local natives = {
        IsEntityDead = function() return c.dead end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        NetworkResurrectLocalPlayer = function() c.dead = false end,
        ClearPedBloodDamage = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        SetPedArmour = function(ped, value)
            c.vitals[#c.vitals + 1] = { what = 'armour', ped = ped, value = value, at = c.clock, co = coroutine.running() }
        end,
        SetEntityHealth = function(ped, value)
            c.vitals[#c.vitals + 1] = { what = 'health', ped = ped, value = value, at = c.clock, co = coroutine.running() }
        end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end,
        RemoveWeaponFromPed = function() end,
        DisableControlAction = function() end,
        DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 0 end,
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
    }
    for name, fn in pairs(world.natives) do natives[name] = fn end
    -- THE FRAME CLOCK. It moves only when a test moves it -- every read in
    -- one frame answers the same, which is what the game's timer does.
    natives.GetGameTimer = function() return c.clock end
    natives.joaat = nil
    natives.vector3 = nil
    natives.vec3 = nil

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            c.toServer[#c.toServer + 1] = { name = name, payload = payload }
            c.log[#c.log + 1] = { name = 'event:' .. tostring(name), args = {}, co = label(coroutine.running()) }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        print = function() end,
        lib = { notify = function() end },
        joaat = world.natives.joaat,
        vector3 = world.natives.vector3,
        vec3 = world.natives.vec3,
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() return true end,
            ReleaseDeadState = function() end,
        },
        -- THE RUNTIME'S table.unpack, which takes a vector apart into its
        -- three numbers. A death in the countdown is revived where the
        -- player lies, and reviveForCountdown asks exactly that of it; plain
        -- Lua's reads this world's vectors by their LENGTH, which is a
        -- float, and raises. Everything that is not a vector is unpacked by
        -- the real one.
        table = setmetatable({
            unpack = function(list, i, j)
                if Sandbox.type(list) == 'vector3' then return list.x, list.y, list.z end
                return table.unpack(list, i, j)
            end,
        }, { __index = table }),
    }
    for name, fn in pairs(natives) do
        overrides[name] = function(...)
            local co = coroutine.running()
            if name == 'DisableControlAction' and select(2, ...) == 199 then
                c.arena = co
                c.arenas[co] = true
            end
            c.log[#c.log + 1] = { name = name, args = { ... }, co = label(co), raw = co }
            return fn(...)
        end
    end

    local env = Sandbox.newArenaEnv(overrides)
    local chunk = assert(load(opts.source or readFile(PATH), '@' .. PATH, 't', env))
    chunk()
    c.env = env

    function c.payloadFor(arenaKey)
        local arena = env.Config.Arenas[arenaKey]
        local spawn = env.Arena.PickSpawn(arenaKey, nil, 1)
        return {
            matchId = 'match-1', arenaKey = arenaKey, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false,
            loadout = { weapons = {}, health = 200, armor = ARMOUR },
            boundary = nil,
            sizeFactor = arena and 1.0 or nil,
            freezeSeconds = 0,
        }
    end

    --- A handler run to the end, in a coroutine of its own because entry
    --- and respawn wait on the world.
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

    function c.enter(arenaKey) c.fire('crimson_arena:client:enterArena', c.payloadFor(arenaKey or 'skydome')) end
    function c.goLive() c.fire('crimson_arena:client:matchLive', { matchId = 'match-1' }) end
    function c.respawn()
        local payload = c.payloadFor('skydome')
        c.fire('crimson_arena:client:respawn', { spawn = payload.spawn, scatterRadius = 0.0,
            loadout = payload.loadout })
    end

    --- One frame. Returns the arena thread's own calls in it.
    function c.step()
        local from = #c.log + 1
        runner.step()
        local frame = {}
        for index = from, #c.log do
            local call = c.log[index]
            if c.arena ~= nil and call.raw == c.arena then frame[#frame + 1] = call end
        end
        return frame
    end

    function c.clockReads(frame)
        local n = 0
        for _, call in ipairs(frame) do
            if call.name == 'GetGameTimer' then n = n + 1 end
        end
        return n
    end

    --- Vitals written by the FRAME LOOP at a given clock -- not the ones
    --- the entry itself writes when it hands out the loadout.
    function c.vitalsAt(clock)
        local out = {}
        for _, v in ipairs(c.vitals) do
            if v.at == clock and v.co == c.arena then out[#out + 1] = v.what .. '=' .. tostring(v.value) end
        end
        return table.concat(out, ',')
    end

    function c.vanish(handle)
        local object = world.objects[handle]
        assert(object and not object.deleted, 'the fixture tried to vanish something that is not there')
        object.deleted = true
    end

    return c
end

--- In the sky arena, live, with the arena's first free floor check spent.
local function standing(c)
    c.enter('skydome')
    t.isTrue(#c.world.live() > 0, 'the fixture built no arena, so nothing below tests anything')
    c.goLive()
    c.step()
    c.step()
    return #c.world.live()
end

-- ======================================================================
-- THE COST
-- ======================================================================

t.test('THE COST: the clock is read ONCE per arena frame, in every state the loop can be in', function()
    local c = newClient()
    standing(c)
    local states = {}
    local function frame(name) states[#states + 1] = { name = name, reads = c.clockReads(c.step()) } end

    frame('live, no vitals window yet')
    c.clock = c.clock + 2000
    frame('the floor-check frame')
    c.fire('crimson_arena:client:holdVitals')
    c.clock = c.clock + 100
    frame('inside the vitals window')
    c.clock = c.clock + 1600
    frame('after the window, no floor check')
    c.clock = c.clock + 400
    frame('after the window, on a floor-check frame')
    frame('after the window, the frame after a floor check')
    c.dead = true
    frame('the frame a death is reported in')
    frame('dead, the death reported')
    c.respawn()
    frame('the first frame after a respawn')

    for _, state in ipairs(states) do
        t.equals(state.reads, 1, state.name)
    end
end)

t.test('and counting down, before the round is live', function()
    local c = newClient()
    c.enter('skydome')
    for _ = 1, 3 do t.equals(c.clockReads(c.step()), 1, 'a countdown frame') end
    c.clock = c.clock + 2000
    t.equals(c.clockReads(c.step()), 1, 'a countdown frame that checks the floor')
end)

t.test('and a death in the countdown, revived in its own frame, costs that frame one read too', function()
    -- The countdown's death is settled on this side -- revived where the
    -- player fell, and never reported -- from inside the same frame, between
    -- the one read and the floor check that shares it.
    local c = newClient()
    c.enter('skydome')
    c.step()
    for _, repair in ipairs({ false, true }) do
        if repair then c.clock = c.clock + 2000 end
        c.dead = true
        local frame = c.step()
        local revived = 0
        for _, call in ipairs(frame) do
            if call.name == 'NetworkResurrectLocalPlayer' then revived = revived + 1 end
        end
        t.equals(revived, 1, 'the countdown death was not revived on its frame, so this proves nothing')
        t.isFalse(c.dead, 'the player is still dead after the revive')
        t.equals(c.clockReads(frame), 1, repair and 'a countdown death on a floor-check frame' or 'a countdown death')
        t.equals(c.clockReads(c.step()), 1, 'the frame after a countdown death')
    end
    for _, event in ipairs(c.toServer) do
        t.isTrue(event.name ~= 'crimson_arena:server:reportDeath', 'a countdown death was reported')
    end
end)

-- ======================================================================
-- THE VITALS WINDOW, ON BOTH SIDES OF ITS EDGE
-- ======================================================================

t.test('the vitals are re-asserted on every frame strictly before the window ends, and on none after', function()
    local c = newClient()
    standing(c)
    local start = c.clock
    c.fire('crimson_arena:client:holdVitals')
    local wanted = 'health=200,armour=' .. ARMOUR

    for _, at in ipairs({ 0, 1, 750, 1498, 1499 }) do
        c.clock = start + at
        c.step()
        t.equals(c.vitalsAt(c.clock), wanted, ('%d ms into the window'):format(at))
    end
    for _, at in ipairs({ 1500, 1501, 1999, 5000 }) do
        c.clock = start + at
        c.step()
        t.equals(c.vitalsAt(c.clock), '', ('%d ms after the window opened, which is at or past its end'):format(at))
    end
end)

t.test('a second hold inside the window extends it from ITS clock, not the first one\'s', function()
    local c = newClient()
    standing(c)
    local start = c.clock
    c.fire('crimson_arena:client:holdVitals')
    c.clock = start + 1000
    c.fire('crimson_arena:client:holdVitals')
    c.clock = start + 2499
    c.step()
    t.equals(c.vitalsAt(c.clock), 'health=200,armour=' .. ARMOUR, 'the second hold did not extend the window')
    c.clock = start + 2500
    c.step()
    t.equals(c.vitalsAt(c.clock), '', 'the extended window did not end on time')
end)

t.test('nothing is re-asserted on a player whose death has been reported, even inside the window', function()
    local c = newClient()
    standing(c)
    c.fire('crimson_arena:client:holdVitals')
    c.dead = true
    c.clock = c.clock + 10
    c.step()     -- the death is reported here
    c.clock = c.clock + 10
    c.step()
    t.equals(c.vitalsAt(c.clock), '', 'a reported death was handed its health back')
end)

t.test('and a respawn opens a fresh window, on the frames after it', function()
    local c = newClient()
    standing(c)
    c.dead = true
    c.step()
    c.clock = c.clock + 5000
    c.respawn()
    local opened = c.clock
    c.clock = opened + 1499
    c.step()
    t.equals(c.vitalsAt(c.clock), 'health=200,armour=' .. ARMOUR, 'the respawn opened no window')
    c.clock = opened + 1500
    c.step()
    t.equals(c.vitalsAt(c.clock), '', 'the respawn window did not close')
end)

t.test('a hold with no round to hold it for opens nothing', function()
    local c = newClient()
    c.fire('crimson_arena:client:holdVitals')
    c.enter('skydome')
    c.goLive()
    c.step()
    t.equals(c.vitalsAt(c.clock), '', 'a hold sent before the round re-asserted inside it')
end)

-- ======================================================================
-- THE FLOOR CHECK, ON BOTH SIDES OF ITS DUE TIME
-- ======================================================================

local FLOOR_MODEL = 'stt_prop_stunt_bblock_huge_01'

local function firstFloorHandle(c)
    for _, object in ipairs(c.world.liveOf(FLOOR_MODEL)) do return object.handle end
    error('the arena has no floor tile to take away')
end

t.test('a fresh arena is checked on its first frame', function()
    local c = newClient()
    c.enter('skydome')
    local pieces = #c.world.live()
    c.vanish(firstFloorHandle(c))
    c.goLive()
    c.step()
    t.equals(#c.world.live(), pieces, 'the first frame of the arena did not put the tile back')
end)

t.test('the floor is checked on the first frame at or after its due time, and never on one before', function()
    local c = newClient()
    local pieces = standing(c)
    -- The last check was the first frame after going live, at this clock.
    local checkedAt = c.clock

    c.vanish(firstFloorHandle(c))
    for _, at in ipairs({ 0, 1, 1000, 1999 }) do
        c.clock = checkedAt + at
        c.step()
        t.equals(#c.world.live(), pieces - 1, ('the floor was checked %d ms after the last check'):format(at))
    end
    c.clock = checkedAt + 2000
    c.step()
    t.equals(#c.world.live(), pieces, 'the floor was not checked at its due time')

    -- AND THE NEXT ONE IS DUE TWO SECONDS AFTER THAT FRAME, not after the
    -- first one and not after some later read.
    local second = c.clock
    c.vanish(firstFloorHandle(c))
    c.clock = second + 1999
    c.step()
    t.equals(#c.world.live(), pieces - 1, 'the next check came early')
    c.clock = second + 2000
    c.step()
    t.equals(#c.world.live(), pieces, 'the next check did not come on time')
end)

t.test('a late frame is checked once, and the next due time counts from that late frame', function()
    local c = newClient()
    local pieces = standing(c)
    c.clock = c.clock + 7777
    local late = c.clock
    c.vanish(firstFloorHandle(c))
    c.step()
    t.equals(#c.world.live(), pieces, 'a frame long past its due time was not checked')
    c.vanish(firstFloorHandle(c))
    c.clock = late + 1999
    c.step()
    t.equals(#c.world.live(), pieces - 1, 'the late check did not reset the cadence from its own frame')
    c.clock = late + 2000
    c.step()
    t.equals(#c.world.live(), pieces, 'the cadence after a late check is not two seconds')
end)

t.test('the floor and the vitals can fall in one frame and both happen', function()
    local c = newClient()
    local pieces = standing(c)
    local checkedAt = c.clock
    c.clock = checkedAt + 1000
    c.fire('crimson_arena:client:holdVitals')
    c.vanish(firstFloorHandle(c))
    c.clock = checkedAt + 2000     -- the floor is due, and the window has 500 ms to run
    c.step()
    t.equals(#c.world.live(), pieces, 'the floor was not checked on its frame')
    t.equals(c.vitalsAt(c.clock), 'health=200,armour=' .. ARMOUR, 'the vitals were not re-asserted on it')
end)

-- ======================================================================
-- THE EQUIVALENCE
-- ======================================================================

--- One call as text, arguments and all, with the thread it came from.
local function render(call)
    local parts = {}
    for index = 1, select('#', table.unpack(call.args)) do
        local value = call.args[index]
        if type(value) == 'number' then
            parts[#parts + 1] = ('%.6g'):format(value)
        elseif type(value) == 'table' then
            parts[#parts + 1] = ('{%s,%s,%s}'):format(tostring(value.x), tostring(value.y), tostring(value.z))
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    return ('%s %s(%s)'):format(call.co, call.name, table.concat(parts, ','))
end

--- Everything a client did since `from`, without its clock reads.
local function trace(c, from)
    local out = {}
    for index = from, #c.log do
        local call = c.log[index]
        if call.name ~= 'GetGameTimer' then out[#out + 1] = render(call) end
    end
    return out
end

local function standingPieces(c)
    local out = {}
    for _, object in ipairs(c.world.live()) do
        out[#out + 1] = ('%s@%.3f,%.3f,%.3f'):format(object.model, object.x, object.y, object.z)
    end
    return table.concat(out, ';')
end

local function rng(seed)
    local state = seed
    return function(n)
        -- Park-Miller: exact in a double, the same on every machine.
        state = (state * 48271) % 2147483647
        return (state % n) + 1
    end
end

t.test('THE REFERENCE is the loop as it was, and differs from the real file only in the frame loop', function()
    local reference = referenceSource()
    t.isNil(reference:find('local now = GetGameTimer()', 1, true), 'the reference still reads the clock once')
    local _, reads = reference:gsub('GetGameTimer%(%) < arenaVitals%.until_', '')
    t.equals(reads, 1, 'the reference has lost the window\'s own read')
    local _, gates = reference:gsub('GetGameTimer%(%) >= nextArenaRepairAt', '')
    t.equals(gates, 1, 'the reference has lost the floor gate\'s own read')
    local c = newClient({ source = reference })
    standing(c)
    c.clock = c.clock + 2000
    t.equals(c.clockReads(c.step()), 2, 'the reference does not read the clock the way the old loop did')
end)

t.test('DIFFERENTIAL: 300 seeded runs of 60 operations -- the one-read loop does exactly what the three-read loop did', function()
    local reference = referenceSource()
    local ran, frames, removed, revivals = 0, 0, 0, 0
    local seen = {}

    for seed = 1, 300 do
        local roll = rng(seed * 104729)
        local old = newClient({ source = reference })
        local new = newClient()
        local clients = { old, new }
        local marks = { 1, 1 }
        local inRound, isLive = false, false

        --- The same operation on both clients, from the same random state:
        --- the scatter on a respawn is the one thing either may roll.
        local reseeds = 0
        local function both(fn)
            reseeds = reseeds + 1
            for _, c in ipairs(clients) do
                math.randomseed(seed, reseeds)
                fn(c)
            end
        end

        for op = 1, 60 do
            local what = roll(12)
            local label = ('seed %d, op %d'):format(seed, op)
            if not inRound and what <= 9 then what = 10 end

            --- n frames, dt ms apart, on both.
            local function runFrames(n, dt)
                for _ = 1, n do
                    both(function(c)
                        c.clock = c.clock + dt
                        local frame = c.step()
                        if c == old then
                            removed = removed + c.clockReads(frame)
                        else
                            removed = removed - c.clockReads(frame)
                            t.isTrue(c.clockReads(frame) <= 1, label .. ': the new loop read the clock twice')
                        end
                    end)
                    frames = frames + 1
                end
            end

            if what <= 4 then
                local n = roll(5)
                runFrames(n, roll(4) == 1 and 0 or roll(40))
                seen.frames = (seen.frames or 0) + 1
            elseif what == 5 then
                local jump = roll(3) == 1 and 2000 or roll(3000)
                both(function(c) c.clock = c.clock + jump end)
                seen.jump = (seen.jump or 0) + 1
            elseif what == 6 then
                both(function(c) c.fire('crimson_arena:client:holdVitals') end)
                seen.hold = (seen.hold or 0) + 1
            elseif what == 7 then
                local live = #old.world.live()
                if live > 0 then
                    local pick = roll(live)
                    both(function(c) c.vanish(c.world.live()[pick].handle) end)
                    seen.vanish = (seen.vanish or 0) + 1
                end
            elseif what == 8 then
                -- A DEATH, LIVE OR COUNTING DOWN. One in the countdown takes
                -- the revive path, settled inside the same frame as the read
                -- -- which is why the fixture models the runtime's unpack of a
                -- vector rather than leaving this path out.
                -- Three in four in the countdown, which is the shorter
                -- stretch of a run and would otherwise see few of them.
                if roll(4) <= (isLive and 2 or 3) then
                    both(function(c) c.dead = true end)
                    if isLive then
                        seen.die = (seen.die or 0) + 1
                    else
                        -- AND ITS FRAME RUNS NOW, before the round can go
                        -- live under it and make it a live death instead.
                        runFrames(roll(3), roll(40))
                        seen.dieInCountdown = (seen.dieInCountdown or 0) + 1
                    end
                else
                    both(function(c) c.respawn() end)
                    seen.respawn = (seen.respawn or 0) + 1
                    if not isLive then
                        -- A respawn in the countdown is not something the
                        -- server sends; it is harmless here and changes
                        -- nothing about which state is live.
                        seen.respawnInCountdown = (seen.respawnInCountdown or 0) + 1
                    end
                end
            elseif what == 9 then
                both(function(c) c.fire('crimson_arena:client:exitArena', {}) end)
                inRound, isLive = false, false
                seen.exit = (seen.exit or 0) + 1
            else
                if not inRound then
                    local arena = roll(2) == 1 and 'skydome' or 'trailerpark'
                    both(function(c)
                        c.dead = false
                        c.enter(arena)
                    end)
                    if roll(3) ~= 1 then
                        both(function(c) c.goLive() end)
                        isLive = true
                    end
                    inRound = true
                    seen.enter = (seen.enter or 0) + 1
                elseif not isLive and roll(3) ~= 1 then
                    -- A COUNTDOWN LASTS A WHILE: one time in three this is a
                    -- moment more of it, rather than the round going live.
                    both(function(c) c.goLive() end)
                    isLive = true
                else
                    -- ROLLED ONCE, OUTSIDE `both`: a roll inside it would be
                    -- a different number for each client.
                    local extra = roll(100)
                    both(function(c) c.clock = c.clock + extra end)
                end
            end

            t.equals(new.clock, old.clock, label .. ': the test drove the two clocks apart')
            local a, b = trace(old, marks[1]), trace(new, marks[2])
            marks[1], marks[2] = #old.log + 1, #new.log + 1
            if #a ~= #b then
                t.equals(#b, #a, label .. ': the two loops made a different number of calls')
            end
            for index = 1, #a do
                if a[index] ~= b[index] then
                    t.equals(b[index], a[index], ('%s: call %d differs'):format(label, index))
                end
            end
            t.equals(#new.toServer, #old.toServer, label .. ': the server was told different things')
            t.equals(standingPieces(new), standingPieces(old), label .. ': different scenery is standing')
            t.equals(#new.vitals, #old.vitals, label .. ': different vitals were written')
        end
        for index = 1, #new.log do
            if new.log[index].name == 'NetworkResurrectLocalPlayer' and new.arenas[new.log[index].raw] then
                revivals = revivals + 1
            end
        end
        ran = ran + 1
    end

    t.equals(ran, 300, 'not every run finished')
    -- WHAT THE RUNS REACHED. A differential is only as wide as its inputs.
    for _, what in ipairs({ 'frames', 'jump', 'hold', 'vanish', 'die', 'respawn', 'exit', 'enter' }) do
        t.isTrue((seen[what] or 0) >= 200, ('the runs did "%s" only %d times'):format(what, seen[what] or 0))
    end
    -- The countdown is a short stretch of most runs, so its deaths are
    -- fewer; what matters is that they are there, and were revived by the
    -- frame loop itself rather than turned into live deaths by a go-live.
    t.isTrue((seen.dieInCountdown or 0) >= 80,
        ('the runs died in the countdown only %d times'):format(seen.dieInCountdown or 0))
    t.isTrue(revivals >= 80, ('only %d countdown deaths were revived on a frame'):format(revivals))
    t.isTrue(frames >= 15000, 'too few frames were compared: ' .. frames)
    -- AND IT DID SAVE SOMETHING, or this is two copies of one loop.
    t.isTrue(removed > 5000, 'the new loop read the clock nearly as often as the old one: ' .. removed .. ' fewer')
end)

os.exit(t.summary())
