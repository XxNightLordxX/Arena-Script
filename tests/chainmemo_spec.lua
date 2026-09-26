--[[
    crimson_arena/tests/chainmemo_spec.lua

    ONE MODEL LOOKUP PER CHAIN PER BUILD, NOT ONE PER PIECE.

    Every piece of an arena names a CHAIN of models -- the prop it wants
    first, then the ones to fall back on -- and the build used to walk that
    chain again for every single piece: hash it, ask the streamer whether it
    has it, request it, time it, ask twice more whether it arrived. The
    shipped skydome is three chains and eighty-seven pieces; on a client
    without the stunt blocks it is the same three chains and three hundred
    and sixty-nine pieces, at the largest size over eleven hundred, and on
    that client every walk starts by failing four DLC names before it gets
    to the container. All of it inside the one frame the build is kept to.

    Now each build remembers which model a chain resolved to, and a later
    piece of the same chain reuses it -- but only while the streamer still
    says it is loaded, and only for a chain that DID resolve:

      - a chain that failed is not remembered, so it is retried on every
        piece exactly as before;
      - a remembered model that is no longer loaded is not trusted, and the
        piece falls back to the full walk, waits and all;
      - a miss still goes through loadPropModel with the build's
        `stillWanted`, so a camera build can still be called off at every
        wait it has left -- the thing a first draft of this change broke;
      - the memory is one build long. The models are released at teardown,
        and a memory that outlived it would hand the next build a model the
        streamer has already been told it may drop.

    ONE THING CHANGES ON PURPOSE, and it is pinned below rather than hidden:
    a chain whose first model arrives only AFTER its ten-second wait, with a
    fallback behind it, used to build its first piece from the fallback and
    every later piece from the late arrival -- a mix of two props in one
    wall. It now builds every piece from the fallback it first got.

    The harness here is a STREAMER WITH A CLOCK: a model arrives some time
    after it is first requested, can be taken away for a window, and a
    frame is a hundred milliseconds -- so the ten-second wait really runs
    out. A differential at the foot plays a few hundred seeded builds on the
    real client and on the same file with the old per-piece walk put back,
    and requires every object, every console line, every model released and
    every place the build yields to match.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('chainmemo_spec')

local MATCH_FILE = '../Crimson-Arena/client/match.lua'
local FRAME_MS = 100
local NEVER = math.huge
local STUNT = { 'stt_prop_stunt_bblock_huge_01', 'bkr_prop_biker_bblock_huge_01',
                'imp_prop_impexp_bblock_huge_01', 'ar_prop_ar_bblock_huge_01' }

local function read(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

-- ======================================================================
-- THE REFERENCE: THE SAME FILE WITH THE OLD PER-PIECE WALK
-- ======================================================================

--- The old head of the piece loop, exactly as it shipped before the memo.
local OLD_HEAD = [[
    for _, piece in ipairs(wanted) do
        local hash, _, abandoned = loadPropModel(piece.models or piece.model, stillWanted)
        if abandoned then return false end
        if hash then
]]

--- The file as shipped, and the same file with the loop's head put back to
--- the old walk. Found by the two markers the memo sits between -- the
--- `resolvedChains` table and the `if hash then` that follows its block --
--- or, on a file without the memo, the old head itself. Neither found is a
--- test failure below, never a silently equal reference.
local SOURCE = read(MATCH_FILE)
local REFERENCE_SOURCE, SHAPE
do
    local first = SOURCE:find('\n    local resolvedChains = {}\n', 1, true)
    local head = first and SOURCE:find('\n    for _, piece in ipairs(wanted) do\n', first, true)
    local tail = head and SOURCE:find('\n        if hash then\n', head, true)
    if first and head and tail then
        -- Everything from the memo table to the loop's `if hash then`
        -- becomes the old head. The comment above the table goes too, which
        -- changes nothing a spec can see.
        REFERENCE_SOURCE = SOURCE:sub(1, first) .. OLD_HEAD .. SOURCE:sub(tail + #'\n        if hash then\n')
        SHAPE = 'memo'
    elseif SOURCE:find(OLD_HEAD, 1, true) then
        REFERENCE_SOURCE = SOURCE
        SHAPE = 'old'
    else
        SHAPE = 'unknown'
    end
end

-- ======================================================================
-- A CLIENT, AND A STREAMER WITH A CLOCK
-- ======================================================================

--- @param opts table|nil
---   reference  load the old per-piece walk instead of the file as shipped
---   models     the models this build has (default: every one the world knows)
---   arrive     { [name] = ms after its first request, or NEVER } (default 0)
---   evict      { [name] = { from, to } } absolute ms the streamer drops it
---   cover      arena keys to switch cover on for
---   pieces     function(real) -> the pieces Arena.ArenaProps hands the build
local function newClient(opts)
    opts = opts or {}
    local models = opts.models or World.DEFAULT_MODELS
    local world = World.new({ streamRange = 100000.0, models = models })
    local handlers = {}
    local c = {
        world = world, printed = {}, toServer = {}, released = {}, calls = {},
        yields = {}, unloadedCreates = 0, unrequestedCreates = 0, watching = true, clock = 0,
        builtWith = {}, goneAsked = 0,
    }
    --- Models released at a teardown and not asked for since.
    local letGo = {}
    local arrive, evict = opts.arrive or {}, opts.evict or {}
    local requestedAt = {}

    local function tally(name) c.calls[name] = (c.calls[name] or 0) + 1 end

    --- Is this model resident right now, by the streamer's own rules?
    local function resident(name)
        if world.models[name] == nil or requestedAt[name] == nil then return false end
        if c.clock < requestedAt[name] + (arrive[name] or 0) then return false end
        local window = evict[name]
        if window and c.clock >= window[1] and c.clock < window[2] then return false end
        return true
    end
    c.resident = resident

    local overrides = {
        CreateThread = function() end,
        SetTimeout = function() end,
        -- A FRAME IS A HUNDRED MILLISECONDS, whatever the caller asked for.
        -- The sandbox's own Wait(0) moves no time at all, so a ten-second
        -- model wait there never runs out; this one does, in a hundred
        -- frames. Every yield is written down with how many pieces were
        -- standing, which is how "the build parks in the same places" is
        -- checked rather than supposed.
        Wait = function(ms)
            c.clock = c.clock + math.max(FRAME_MS, tonumber(ms) or 0)
            c.yields[#c.yields + 1] = #world.live()
            coroutine.yield()
        end,
        GetGameTimer = function() tally('GetGameTimer'); return c.clock end,
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
        ArenaSpectate = {
            IsActive = function() return c.watching == true end,
            Stop = function() c.watching = false end,
            Start = function() c.watching = true end,
        },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end
    overrides.GetGameTimer = function() tally('GetGameTimer'); return c.clock end

    -- THE MODEL PATH, COUNTED AND RULED.
    overrides.joaat = function(name) tally('joaat'); return name end
    overrides.IsModelInCdimage = function(name)
        tally('IsModelInCdimage'); tally('IsModelInCdimage:' .. tostring(name))
        return world.models[name] ~= nil
    end
    overrides.IsModelValid = function(name) tally('IsModelValid'); return world.models[name] ~= nil end
    overrides.RequestModel = function(name)
        tally('RequestModel'); tally('RequestModel:' .. tostring(name))
        if requestedAt[name] == nil then requestedAt[name] = c.clock end
        letGo[name] = nil
    end
    overrides.HasModelLoaded = function(name)
        tally('HasModelLoaded')
        -- HOW OFTEN THE BUILD FOUND A MODEL IT HAD ALREADY BUILT WITH GONE:
        -- the moment a remembered model is not to be trusted. Counted so a
        -- seeded run can show it reached that moment, not just hoped to.
        if c.builtWith[name] and not resident(name) then c.goneAsked = c.goneAsked + 1 end
        return resident(name)
    end
    -- RELEASED IS NOT GONE, AND THAT IS THE DANGEROUS HALF. A model the
    -- streamer has been told it may drop usually stays resident a while, so
    -- HasModelLoaded still says yes -- and a memory kept past the teardown
    -- would build the next round from it without ever asking for it again,
    -- on the streamer's goodwill. Counted at CreateObject. `dropOnRelease`
    -- makes the streamer drop it at once instead.
    overrides.SetModelAsNoLongerNeeded = function(name)
        c.released[#c.released + 1] = tostring(name)
        letGo[name] = true
        if opts.dropOnRelease then requestedAt[name] = nil end
    end
    overrides.GetModelDimensions = function(name)
        tally('GetModelDimensions')
        return world.natives.GetModelDimensions(name)
    end
    -- AN OBJECT FROM A MODEL THAT IS NOT RESIDENT IS NOT CREATED, and it is
    -- counted, because it is the one thing trusting a stale memory does.
    overrides.CreateObject = function(name, ...)
        tally('CreateObject')
        if not resident(name) then
            c.unloadedCreates = c.unloadedCreates + 1
            return 0
        end
        if letGo[name] then c.unrequestedCreates = c.unrequestedCreates + 1 end
        c.builtWith[name] = true
        return world.natives.CreateObject(name, ...)
    end

    local env = Sandbox.newArenaEnv(overrides)
    for _, key in ipairs(opts.cover or {}) do
        local arena = env.Config.Arenas[key]
        if arena and type(arena.cover) == 'table' then arena.cover.enabled = true end
    end
    local source = opts.reference and REFERENCE_SOURCE or SOURCE
    assert(source, 'there is no reference to load: see the first test')
    assert(load(source, '@' .. MATCH_FILE, 't', env))()
    c.env = env

    if opts.pieces then
        local real = env.Arena.ArenaProps
        env.Arena.ArenaProps = function(...) return opts.pieces(real(...)) end
    end

    --- Runs `fn` as a thread, one frame per resume, until it finishes.
    --- `onFrame(n)` is called before the n-th resume -- the seam a camera
    --- stopping mid-build is simulated from.
    function c.run(fn, onFrame)
        local thread = coroutine.create(fn)
        local frames = 0
        while coroutine.status(thread) ~= 'dead' do
            frames = frames + 1
            assert(frames < 200000, 'the thread never finished')
            if onFrame then onFrame(frames) end
            local ok, err = coroutine.resume(thread)
            if not ok then error(err) end
        end
        return frames
    end

    function c.enter(key, factor, onFrame)
        local arena = env.Config.Arenas[key]
        local spawn = env.Arena.PickSpawn(key, nil, 1)
        local handler = handlers['crimson_arena:client:enterArena']
        return c.run(function()
            handler({
                matchId = 'match-1', arenaKey = key, modeKey = 'ffa',
                spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
                scatterRadius = 0.0, radar = false, loadout = { weapons = {} },
                sizeFactor = factor,
                boundary = arena.boundary and {
                    enabled = true,
                    center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                    radius = arena.boundary.radius * math.max(1.0, factor or 1.0),
                    warningSeconds = 5, damagePerTick = 20, tickMs = 500,
                } or nil,
                freezeSeconds = 0,
            })
        end, onFrame)
    end

    function c.exit()
        local handler = handlers['crimson_arena:client:exitArena']
        return c.run(function() handler({}) end)
    end

    --- The camera asking for scenery. `stopAt` is the frame its watcher
    --- walks away on, if they do.
    function c.watch(key, factor, stopAt)
        c.watching = true
        local result
        c.run(function() result = env.ArenaMatch.EnsureSpectatorScenery(key, factor) end, function(frame)
            if stopAt and frame >= stopAt then c.watching = false end
        end)
        return result
    end

    return c
end

-- ======================================================================
-- WHAT A BUILD LEFT BEHIND, AS STRINGS TO COMPARE
-- ======================================================================

local function objects(c)
    local out = {}
    for _, object in ipairs(c.world.live()) do
        out[#out + 1] = ('%s %.3f %.3f %.3f %.2f %s %s %s'):format(object.model, object.x, object.y, object.z,
            object.heading or 0.0, tostring(object.frozen), tostring(object.collision), tostring(object.lodDist))
    end
    return table.concat(out, '\n')
end

local function console(c)
    local out = {}
    for _, line in ipairs(c.printed) do out[#out + 1] = 'F8 ' .. line end
    for _, sent in ipairs(c.toServer) do
        local payload = sent.payload
        local text = sent.name
        if type(payload) == 'table' then
            if type(payload.lines) == 'table' then text = text .. ' ' .. table.concat(payload.lines, ' | ') end
            if payload.line ~= nil then text = text .. ' ' .. tostring(payload.line) end
        end
        out[#out + 1] = 'SV ' .. text
    end
    -- An error quoted from the file carries its line number, and the
    -- reference is the same file a few dozen lines shorter.
    return (table.concat(out, '\n'):gsub('match%.lua:%d+:', 'match.lua:N:'))
end

--- Released models as a sorted list: removeArenaProps walks a set with
--- pairs(), whose order is not something either version promises.
local function released(c)
    local copy = {}
    for i, name in ipairs(c.released) do copy[i] = name end
    table.sort(copy)
    return table.concat(copy, ' ')
end

local function modelsOf(c)
    local count = {}
    for _, object in ipairs(c.world.live()) do count[object.model] = (count[object.model] or 0) + 1 end
    return count
end

--- Every model this world knows, minus some.
local function without(names)
    local out = {}
    for name, size in pairs(World.DEFAULT_MODELS) do out[name] = size end
    for _, name in ipairs(names) do out[name] = nil end
    return out
end

--- The distinct chains a build of this arena hands its piece loop.
local function distinctChains(c, key, measured, factor)
    local seen, count, pieces = {}, 0, 0
    for _, piece in ipairs(c.env.Arena.ArenaProps(key, measured, factor)) do
        pieces = pieces + 1
        local chain = table.concat(piece.models or { piece.model }, '|')
        if not seen[chain] then seen[chain] = true; count = count + 1 end
    end
    return count, pieces
end

t.test('the reference really is the old walk, and the file has one of the two shapes', function()
    t.isTrue(SHAPE == 'memo' or SHAPE == 'old',
        'the piece loop no longer opens in either shape the reference knows -- rebuild the reference')
    if SHAPE == 'memo' then
        t.isTrue(REFERENCE_SOURCE:find(OLD_HEAD, 1, true) ~= nil, 'the reference does not carry the old walk')
        t.isTrue(REFERENCE_SOURCE:find('local resolvedChains', 1, true) == nil, 'the reference still carries the memo')
        -- AND IT IS STILL THE WHOLE FILE: the edit removed the memo and
        -- nothing else.
        t.isTrue(#REFERENCE_SOURCE < #SOURCE and #SOURCE - #REFERENCE_SOURCE < 6000,
            'the reference lost more than the memo block')
    end
end)

-- ======================================================================
-- THE COST THIS CHANGE IS FOR
-- ======================================================================

t.test('THE COST: the shipped skydome asks for each chain once per build, not once per piece', function()
    local c = newClient()
    c.enter('skydome', 1.0)
    local chains, pieces = distinctChains(c, 'skydome', { x = 40.0, y = 40.0, top = 10.0 }, 1.0)
    t.equals(pieces, 87, 'the shipped skydome is not the arena this was measured on')
    t.equals(#c.world.live(), pieces, 'the build did not finish whole')
    -- One request for the measuring load, one per distinct chain.
    t.equals(c.calls['RequestModel'], 1 + chains,
        ('%d model requests for %d chains'):format(c.calls['RequestModel'], chains))
    -- A remembered model is still checked once per piece, and no more.
    t.isTrue(c.calls['HasModelLoaded'] <= pieces + 2 * chains + 2,
        ('%d HasModelLoaded calls for %d pieces'):format(c.calls['HasModelLoaded'], pieces))
    t.isTrue(c.calls['IsModelInCdimage'] <= 1 + chains,
        ('%d cdimage checks for %d chains'):format(c.calls['IsModelInCdimage'], chains))
end)

t.test('and on a client without the stunt blocks, at the largest size, the chain walk is not per piece', function()
    -- THE HEAVY CLIENT: every floor piece's walk used to fail four DLC
    -- names before it reached the container, eleven hundred times over.
    local c = newClient({ models = without(STUNT) })
    c.enter('skydome', 2.0)
    local chains, pieces = distinctChains(c, 'skydome', { x = 12.2, y = 2.5, top = 2.6 }, 2.0)
    t.isTrue(pieces > 1000, 'the container floor at the largest size is not over a thousand pieces: ' .. pieces)
    t.equals(#c.world.live(), pieces, 'the build did not finish whole')
    t.equals(c.calls['RequestModel'], 1 + chains)
    -- Four failed names and the container for the measuring load, the same
    -- for the floor chain's one walk, and one each for the two cover chains.
    t.isTrue(c.calls['IsModelInCdimage'] <= 5 + 5 + 2,
        ('%d cdimage checks on a build of %d pieces'):format(c.calls['IsModelInCdimage'], pieces))
    t.isTrue(c.calls['IsModelValid'] <= 1 + chains, ('%d validity checks'):format(c.calls['IsModelValid']))
    t.isTrue(c.calls['HasModelLoaded'] <= pieces + 2 * chains + 2)
    t.isTrue(c.calls['GetGameTimer'] <= 200, ('%d clock reads'):format(c.calls['GetGameTimer']))
end)

-- ======================================================================
-- WHAT MUST NOT CHANGE, PINNED
-- ======================================================================

--- Builds the same thing on the real client and the reference, and
--- compares everything a player or an operator could see.
local function sameAsReference(opts, run, label)
    local real, ref = newClient(opts), newClient(setmetatable({ reference = true }, { __index = opts }))
    run(real)
    run(ref)
    t.equals(objects(real), objects(ref), label .. ': the arena came out different')
    t.equals(console(real), console(ref), label .. ': the consoles differ')
    t.equals(released(real), released(ref), label .. ': different models were released')
    t.equals(table.concat(real.yields, ','), table.concat(ref.yields, ','), label .. ': it yields in different places')
    t.equals(real.unloadedCreates, 0, label .. ': an object was created from a model that was not loaded')
    t.equals(real.unrequestedCreates, ref.unrequestedCreates,
        label .. ': an object was created from a model released and not asked for since')
    return real, ref
end

t.test('every piece comes out of the same model, in the same place, in each shipped model set', function()
    for _, set in ipairs({
        { 'everything', without({}) },
        { 'no stunt blocks', without(STUNT) },
        { 'only the last stunt block', without({ STUNT[1], STUNT[2], STUNT[3] }) },
        { 'no first container', without({ 'prop_container_01a' }) },
        { 'no barriers but the last', without({ 'prop_mp_barrier_02b' }) },
        { 'no cover at all', without({ 'prop_container_01a', 'prop_container_01b', 'prop_mp_barrier_02b',
                                       'prop_barrier_work05', 'prop_conc_blocks01a' }) },
        { 'no floor at all', without(STUNT) },
    }) do
        local models = set[2]
        if set[1] == 'no floor at all' then models['prop_container_01a'] = nil; models['prop_container_01b'] = nil end
        for _, factor in ipairs({ 1.0, 1.5, 2.0 }) do
            sameAsReference({ models = models }, function(c)
                c.enter('skydome', factor)
                c.exit()
                c.enter('skydome', factor)
            end, ('%s at %.1f'):format(set[1], factor))
        end
    end
end)

t.test('and the trailer park with its cover switched on, which shares a container chain with the sky', function()
    for _, models in ipairs({ without({}), without({ 'prop_container_01a', 'prop_mp_barrier_02b' }) }) do
        sameAsReference({ models = models, cover = { 'trailerpark' } }, function(c)
            c.enter('trailerpark')
            c.exit()
            c.enter('skydome', 1.0)
        end, 'trailer park then skydome')
    end
end)

t.test('a slow model parks the build with the same pieces standing as before', function()
    -- The build waits on a model the streamer has not finished with. Which
    -- pieces are standing while it waits is the window every race test in
    -- floorrepair_spec aims at, so it must not move.
    for _, case in ipairs({
        { 'slow container', {}, { prop_container_01a = 3000 } },
        { 'slow barrier', {}, { prop_mp_barrier_02b = 3000 } },
        { 'container floor, slow barrier', STUNT, { prop_mp_barrier_02b = 3000 } },
        { 'slow floor', {}, { stt_prop_stunt_bblock_huge_01 = 4000 } },
    }) do
        local real = sameAsReference({ models = without(case[2]), arrive = case[3] }, function(c)
            c.enter('skydome', 1.0)
        end, case[1])
        t.isTrue(#real.yields > 0, case[1] .. ': the build never waited, so this tests nothing')
    end
end)

t.test('a camera build is still called off at a chain\'s first load, and leaves nothing standing', function()
    -- THE CONTRACT THE FIRST DRAFT OF THIS CHANGE BROKE: a miss still goes
    -- through loadPropModel with the build's stillWanted.
    for _, case in ipairs({
        { 'on the container chain', { prop_container_01a = 5000 } },
        { 'on the barrier chain', { prop_mp_barrier_02b = 5000 } },
    }) do
        local c = newClient({ arrive = case[2] })
        c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
        local result = c.watch('skydome', 1.0, 20)
        t.isTrue(result == false, case[1] .. ': a camera whose watcher left still reported an arena')
        t.equals(#c.world.live(), 0, case[1] .. ': the abandoned camera build left pieces standing')
        t.isTrue(c.clock < 5000, case[1] .. ': the build waited out the model instead of being called off')
        -- And every model it had loaded was let go -- and the one it was
        -- still waiting for when it was called off.
        local let = {}
        for _, name in ipairs(c.released) do let[name] = true end
        t.isTrue(let['stt_prop_stunt_bblock_huge_01'], case[1] .. ': the floor model was never released')
        local waited = next(case[2])
        t.isTrue(let[waited], case[1] .. ': THE DEFECT: the model the called-off build was waiting for stayed requested')
    end
end)

t.test('and at a load forced by a remembered model that went away mid-build', function()
    -- THE GUARDED HIT. The container chain is remembered from the wall;
    -- while the build waits on the barrier, the streamer drops the
    -- container. The next container piece must not trust the memory: it
    -- walks the chain again, waits -- and that wait can be called off too.
    local c = newClient({
        arrive = { prop_mp_barrier_02b = 1000 },
        evict = { prop_container_01a = { 500, 60000 } },
    })
    c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
    local result = c.watch('skydome', 1.0, 40)
    t.isTrue(result == false, 'the camera build was not called off at the forced reload')
    t.equals(#c.world.live(), 0, 'the abandoned build left pieces standing')
    t.equals(c.unloadedCreates, 0, 'a piece was created from a model the streamer had dropped')
    t.isTrue((c.calls['RequestModel:prop_container_01a'] or 0) >= 2,
        'the dropped container was never asked for again')
end)

t.test('THE BUILD WAITS IN ONE PLACE: nothing in layArenaProps yields, the memo\'s guard included', function()
    -- The item this memo came with forbids adding a wait, and a Wait(0) in
    -- the hit guard behaves almost the same -- the forced walk would have
    -- waited that frame anyway -- so no behaviour test is sure to see it:
    -- a camera watcher leaving on that very frame gets one yield more before
    -- the build is called off. So the rule is read off the source: the only
    -- yield on the build path is loadPropModel's, where stillWanted is asked.
    local source = read('../Crimson-Arena/client/match.lua')
    local function body(name)
        local start = source:find('\nlocal function ' .. name .. '%(')
        t.isNotNil(start, name .. ' is not where this test looks for it')
        local stop = source:find('\nend\n', start or 1, true)
        return source:sub(start or 1, stop or #source)
    end
    local function codeOnly(text)
        local out = {}
        for line in text:gmatch('[^\n]+') do out[#out + 1] = (line:gsub('%-%-.*$', '')) end
        return table.concat(out, '\n')
    end
    local function yields(text)
        local count = 0
        for _ in codeOnly(text):gmatch('[^%w_]Wait%s*%(') do count = count + 1 end
        for _ in codeOnly(text):gmatch('[^%w_]Citizen%.Wait%s*%(') do count = count + 1 end
        return count
    end
    t.equals(yields(body('layArenaProps')), 0, 'layArenaProps yields, and the one-frame build can be called off late')
    t.equals(yields(body('loadPropModel')), 1, 'loadPropModel no longer has exactly the one wait the build relies on')
end)

t.test('a remembered model is only trusted while the streamer still has it', function()
    -- The same drop, with nobody calling the build off: the container comes
    -- back, and the rest of the wall is built from it -- never from a model
    -- that was not there.
    local real = sameAsReference({
        arrive = { prop_mp_barrier_02b = 1000 },
        evict = { prop_container_01a = { 500, 2500 } },
    }, function(c) c.enter('skydome', 1.0) end, 'container dropped mid-build')
    t.equals(#real.world.live(), 87, 'the wall was not finished once the container came back')
    t.isTrue((real.calls['RequestModel:prop_container_01a'] or 0) >= 2,
        'the dropped container was never asked for again')
end)

t.test('a chain that will not load is retried on every piece, exactly as before', function()
    -- FAILURES ARE NOT REMEMBERED. A chain none of whose models this build
    -- has fails on every piece and says so once; one whose only model is
    -- in the build but never arrives waits on every piece, as it always did.
    local barrierChain = { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' }
    local real = sameAsReference({ models = without(barrierChain) },
        function(c) c.enter('skydome', 1.0) end, 'no barrier models')
    local barriers = 0
    for _, piece in ipairs(real.env.Arena.ArenaProps('skydome', { x = 40.0, y = 40.0, top = 10.0 }, 1.0)) do
        if table.concat(piece.models or {}, ' ') == table.concat(barrierChain, ' ') then barriers = barriers + 1 end
    end
    t.isTrue(barriers > 1, 'the arena has one barrier piece or none, so this proves nothing')
    t.equals(real.calls['IsModelInCdimage:prop_mp_barrier_02b'], barriers,
        'a failed chain was not walked again for every piece')
    t.isTrue(console(real):find(table.concat(barrierChain, ' / '), 1, true) ~= nil,
        'the failed chain was not reported')

    local never = sameAsReference({ arrive = { prop_mp_barrier_02b = NEVER, prop_barrier_work05 = NEVER,
                                               prop_conc_blocks01a = NEVER } },
        function(c) c.enter('skydome', 1.0) end, 'barriers never arrive')
    t.equals(never.calls['RequestModel:prop_mp_barrier_02b'], barriers,
        'a chain that timed out was not asked for again on its next piece')
end)

t.test('the memory lasts one build: the next round asks for every chain again', function()
    -- THE TEARDOWN RELEASES EVERY MODEL. A memory that outlived the build
    -- would create the next round from models nobody has asked for since --
    -- still resident, most of the time, which is what would hide it.
    for _, drop in ipairs({ false, true }) do
        local label = drop and 'a streamer that drops released models' or 'a streamer that keeps them'
        local c = newClient({ dropOnRelease = drop })
        c.enter('skydome', 1.0)
        local first = c.calls['RequestModel']
        c.exit()
        t.isTrue(#c.released > 0, 'the teardown released nothing, so this proves nothing')
        c.enter('skydome', 1.0)
        t.equals(c.calls['RequestModel'] - first, first, label .. ': the second round asked for fewer models')
        t.equals(c.unrequestedCreates, 0, label .. ': the second round built from models released at the teardown')
        t.equals(c.unloadedCreates, 0, label .. ': the second round built from models that were not loaded')
        t.equals(#c.world.live(), 87, label .. ': the second round did not build whole')

        -- And a camera build after an entry, the other caller.
        local before = c.calls['RequestModel']
        c.exit()
        t.isTrue(c.watch('skydome', 1.0), label .. ': the camera build failed')
        t.equals(c.calls['RequestModel'] - before, first, label)
        t.equals(c.unrequestedCreates, 0, label)
        t.equals(c.unloadedCreates, 0, label)
    end
end)

t.test('the models held and released are exactly the ones before, abandoned builds included', function()
    for _, case in ipairs({
        { 'everything', {}, {} },
        { 'no stunt blocks', STUNT, {} },
        { 'slow barrier', {}, { prop_mp_barrier_02b = 2000 } },
    }) do
        sameAsReference({ models = without(case[2]), arrive = case[3] }, function(c)
            c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
            c.watch('skydome', 1.0, 3)
            c.enter('skydome', 1.0)
            c.exit()
        end, case[1])
    end
end)

-- ======================================================================
-- CHAINS AS KEYS: WHAT COUNTS AS THE SAME ONE
-- ======================================================================

--- Pieces written by the spec, handed to the build in place of the arena's.
local function cover(x, y, models, extra)
    local piece = { kind = 'cover', x = 1500.0 + x, y = 3000.0 + y, z = 1201.0, heading = 0.0,
                    offsetX = x, offsetY = y, models = models }
    for k, v in pairs(extra or {}) do piece[k] = v end
    return piece
end

t.test('two chains that share a first model but not a fallback are told apart', function()
    -- Keyed by the whole chain, not its head: with the head missing, each
    -- falls back to its OWN second model.
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        for i = 1, 4 do
            out[#out + 1] = cover(i * 3.0, 0.0, { 'prop_does_not_exist', 'prop_barrier_work05' })
            out[#out + 1] = cover(i * 3.0, 10.0, { 'prop_does_not_exist', 'prop_conc_blocks01a' })
            out[#out + 1] = cover(i * 3.0, 20.0, { 'prop_does_not_exist', 'prop_conc_blocks01a', 'prop_barrier_work05' })
            -- Two chains whose names run together into the same letters: one
            -- resolves, the other names nothing this build has.
            out[#out + 1] = cover(i * 3.0, 30.0, { 'prop_barrier_work05' })
            out[#out + 1] = cover(i * 3.0, 40.0, { 'prop_barrier_', 'work05' })
        end
        return out
    end
    local real = sameAsReference({ pieces = pieces }, function(c) c.enter('skydome', 1.0) end, 'shared heads')
    local count = modelsOf(real)
    t.equals(count['prop_barrier_work05'], 8)
    t.equals(count['prop_conc_blocks01a'], 8)
end)

--- What each hand-written piece was built from, as 'model@x,y' offsets from
--- the arena's centre in creation order -- the floor left out.
local function placed(c)
    local out = {}
    for _, object in ipairs(c.world.live()) do
        if object.model ~= 'stt_prop_stunt_bblock_huge_01' then
            out[#out + 1] = ('%s@%.0f,%.0f'):format(object.model, object.x - 1500.0, object.y - 3000.0)
        end
    end
    return table.concat(out, ' ')
end

t.test('and two chains of the same models in a different order are two chains', function()
    -- THE ORDER IS THE PREFERENCE. config.lua gives every cover piece a
    -- models list of its own, so one ring can say {work05, blocks} and the
    -- next {blocks, work05}; each wants its own first choice, and this
    -- build has both. A key that forgot the order would build the second
    -- ring from whichever prop the first ring got. Once with each list's
    -- head in the build, once behind a head it does not have.
    local lists = {
        { 'prop_barrier_work05', 'prop_conc_blocks01a' },
        { 'prop_conc_blocks01a', 'prop_barrier_work05' },
        { 'prop_does_not_exist', 'prop_barrier_work05', 'prop_conc_blocks01a' },
        { 'prop_does_not_exist', 'prop_conc_blocks01a', 'prop_barrier_work05' },
        -- AND TWO THAT DIFFER ONLY IN THEIR LAST NAME, behind two heads the
        -- build does not have: a key built from the first names alone would
        -- hand the second list the first one's prop.
        { 'prop_does_not_exist', 'prop_not_here_either', 'prop_barrier_work05' },
        { 'prop_does_not_exist', 'prop_not_here_either', 'prop_conc_blocks01a' },
    }
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        for i = 1, 3 do
            for n, list in ipairs(lists) do
                -- A fresh table per piece, as ArenaProps hands them out.
                out[#out + 1] = cover(i * 3.0, n * 10.0, { table.unpack(list) })
            end
        end
        return out
    end
    local real = sameAsReference({ pieces = pieces }, function(c) c.enter('skydome', 1.0) end, 'permuted chains')
    local want = {}
    for i = 1, 3 do
        for n, first in ipairs({ 'prop_barrier_work05', 'prop_conc_blocks01a', 'prop_barrier_work05',
                                 'prop_conc_blocks01a', 'prop_barrier_work05', 'prop_conc_blocks01a' }) do
            want[#want + 1] = ('%s@%d,%d'):format(first, i * 3, n * 10)
        end
    end
    t.equals(placed(real), table.concat(want, ' '), 'a chain was built from another order\'s first choice')
end)

--- Hand-written chains of every shape a piece could carry. NONE OF THESE
--- CAN COME OUT OF Arena.ArenaProps, whose chains are lists of names by
--- construction. They are here because the key is built from whatever a
--- piece carries, and a key that raised would abandon the whole build.
local function oddPieces(real)
    local out = {}
    for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
    for i = 1, 3 do
        out[#out + 1] = cover(i * 3.0, 0.0, nil, { model = 'prop_conc_blocks01a' })
        out[#out + 1] = cover(i * 3.0, 5.0, {})
        out[#out + 1] = cover(i * 3.0, 10.0, nil)
        out[#out + 1] = cover(i * 3.0, 15.0, { 'prop_barrier_work05', 42 })
        out[#out + 1] = cover(i * 3.0, 20.0, { 42, 'prop_barrier_work05' })
        out[#out + 1] = cover(i * 3.0, 25.0, { 'prop_mp_barrier_02b' })
        out[#out + 1] = cover(i * 3.0, 30.0, { 'prop_does_not_exist' })
    end
    return out
end

t.test('a chain given as one name, an empty chain, no chain and a chain with junk in it all build as before', function()
    -- Anything that is not a clean list of names gets no key, and is walked
    -- on every piece exactly as before -- counted, not assumed, against the
    -- reference.
    local real, ref = sameAsReference({ pieces = oddPieces }, function(c) c.enter('skydome', 1.0) end, 'odd chains')
    for _, name in ipairs({ 'prop_conc_blocks01a', 'prop_barrier_work05' }) do
        t.equals(real.calls['RequestModel:' .. name], ref.calls['RequestModel:' .. name],
            name .. ': a chain with no clean key was not walked on every piece')
    end
    t.equals(real.calls['IsModelInCdimage:prop_does_not_exist'], ref.calls['IsModelInCdimage:prop_does_not_exist'],
        'a chain that failed was not walked on every piece')

    -- AND A CHAIN WITH A HOLE IN IT, which raises in the failure report on
    -- both -- the same way, at the same piece, with the same pieces placed.
    local holed = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        out[#out + 1] = cover(3.0, 35.0, { 'prop_mp_barrier_02b' })
        out[#out + 1] = cover(6.0, 35.0, { 'prop_does_not_exist', nil, 'prop_barrier_work05' })
        return out
    end
    sameAsReference({ pieces = holed }, function(c) c.enter('skydome', 1.0) end, 'a chain with a hole')

    -- AND ONE WITH A HOLE WHOSE FIRST MODEL LOADS, which the old walk built
    -- without a murmur: ipairs stops at the hole, so the chain it walks is
    -- its first name. The key has to stop there too -- a concat across the
    -- hole raises, and the build it raises in is the whole arena.
    local holedLoads = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        out[#out + 1] = cover(3.0, 45.0, { 'prop_mp_barrier_02b', nil, 'prop_barrier_work05' })
        out[#out + 1] = cover(6.0, 45.0, { 'prop_mp_barrier_02b', nil, 'prop_barrier_work05' })
        out[#out + 1] = cover(9.0, 45.0, { 'prop_conc_blocks01a' })
        return out
    end
    local loads = sameAsReference({ pieces = holedLoads }, function(c) c.enter('skydome', 1.0) end,
        'a chain with a hole whose first model loads')
    t.equals(placed(loads), 'prop_mp_barrier_02b@3,45 prop_mp_barrier_02b@6,45 prop_conc_blocks01a@9,45',
        'the chain with a hole was not built from its first model')
end)

t.test('and a clean chain written by hand among them is remembered like any other', function()
    local c = newClient({ pieces = oddPieces })
    c.enter('skydome', 1.0)
    t.equals(c.calls['RequestModel:prop_mp_barrier_02b'], 1, 'a clean one-name chain was not remembered')
end)

t.test('floor pieces sharing one chain table, and cover pieces each with their own, are all one chain each', function()
    -- ArenaProps hands every floor piece the SAME models table and every
    -- cover piece a fresh one; a memory keyed by the table itself would
    -- remember the floor and nothing else.
    local c = newClient()
    c.enter('skydome', 1.0)
    t.equals(c.calls['RequestModel:prop_container_01a'], 1, 'the container chain was asked for more than once')
    t.equals(c.calls['RequestModel:prop_mp_barrier_02b'], 1, 'the barrier chain was asked for more than once')
    t.equals(c.calls['RequestModel:stt_prop_stunt_bblock_huge_01'], 2, 'the floor chain: measuring load and one walk')
end)

-- ======================================================================
-- A REMEMBERED MODEL THAT WENT AWAY
-- ======================================================================

t.test('a walk forced by a remembered model going away remembers what it comes back with', function()
    -- THE LATEST SUCCESS WINS. Five hand-written pieces in a camera build
    -- (no entry hold in front of it, so the clock starts at nothing):
    --
    --   container chain  its first model is due at 12s, past its ten-second
    --                    wait, so this piece takes the fallback at 10s;
    --   barrier          due a second after it is asked for: waits to 11s;
    --   container again  the fallback was dropped at 10.5s (back at 11.5s),
    --                    so the memory is not trusted: the chain is walked
    --                    again, and its first model arrives at 12s. This
    --                    piece is built from it, and so is the rest of the
    --                    wall -- exactly what the old walk built.
    --
    -- A memory that kept its first answer, or that forgot to write the new
    -- one down, builds the last two from the fallback, which is back by
    -- then: one wall, two props, a mix the old walk never made.
    local C = { 'prop_container_01a', 'prop_container_01b' }
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        out[#out + 1] = cover(20.0, 0.0, { table.unpack(C) })
        out[#out + 1] = cover(0.0, 20.0, { 'prop_mp_barrier_02b' })
        out[#out + 1] = cover(-20.0, 0.0, { table.unpack(C) })
        out[#out + 1] = cover(0.0, -20.0, { table.unpack(C) })
        out[#out + 1] = cover(10.0, 10.0, { table.unpack(C) })
        return out
    end
    local real, ref = sameAsReference({
        pieces = pieces,
        arrive = { prop_container_01a = 12000, prop_mp_barrier_02b = 1000 },
        evict = { prop_container_01b = { 10500, 11500 } },
    }, function(c)
        c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
        t.isTrue(c.watch('skydome', 1.0), 'the camera build failed')
    end, 'a reload that comes back as the first model')
    t.equals(real.clock, 12000, 'the build did not run to the timeline this test was written for')
    t.equals(placed(real), 'prop_container_01b@20,0 prop_mp_barrier_02b@0,20 prop_container_01a@-20,0 '
        .. 'prop_container_01a@0,-20 prop_container_01a@10,10', 'the wall is not the one the old walk built')
    t.equals(placed(ref), placed(real))
end)

t.test('a remembered floor model is held to the same check as any other', function()
    -- The shipped arenas lay every floor piece before the first piece of
    -- cover, so no wait can fall between two floor pieces there. Written
    -- by hand, one can: the floor model goes while the build waits on a
    -- barrier, and the floor piece after that wait must walk its chain
    -- again -- not be created from a model that is not there, which the
    -- engine refuses, leaving a hole where the floor should be.
    local first
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do
            if piece.kind == 'floor' then out[#out + 1] = piece; first = first or piece end
        end
        out[#out + 1] = cover(0.0, 20.0, { 'prop_mp_barrier_02b' })
        out[#out + 1] = { kind = 'floor', models = first.models, model = first.model,
                          x = first.x + 300.0, y = first.y, z = first.z, heading = 0.0 }
        return out
    end
    local real = sameAsReference({
        pieces = pieces,
        arrive = { prop_mp_barrier_02b = 2000 },
        evict = { stt_prop_stunt_bblock_huge_01 = { 500, 3000 } },
    }, function(c)
        c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
        t.isTrue(c.watch('skydome', 1.0), 'the camera build failed')
    end, 'a floor model dropped mid-build')
    -- Measured once, walked for once by the floor, and at least once more
    -- after the drop (the old walk asked on every floor piece).
    t.isTrue(real.calls['RequestModel:stt_prop_stunt_bblock_huge_01'] >= 3,
        'the dropped floor model was not walked for again')
    local live = real.world.live()
    t.equals(live[#live].model, 'stt_prop_stunt_bblock_huge_01', 'the floor piece after the drop is missing')
    t.equals(('%.0f'):format(live[#live].x - first.x), '300')
end)

-- ======================================================================
-- THE ONE DIFFERENCE, ON PURPOSE
-- ======================================================================

t.test('ON PURPOSE: a chain whose first model arrives late uses its fallback for every piece, not a mix', function()
    -- The first container is in the build but takes twelve seconds; the
    -- second is instant. The first wall piece waits ten, gives up and takes
    -- the second. The old walk then asked for the first again on every
    -- later piece, got it, and built the rest of the wall from it: one wall,
    -- two props, and one extra ten-second wait on the way. Now the whole
    -- chain is what its first piece resolved to.
    local c = newClient({ arrive = { prop_container_01a = 12000 } })
    c.enter('skydome', 1.0)
    local count = modelsOf(c)
    t.equals(count['prop_container_01a'], nil, 'the late container was mixed into the wall')
    t.isTrue((count['prop_container_01b'] or 0) > 70, 'the wall was not built from the fallback')
    t.equals(#c.world.live(), 87, 'the build did not finish whole')

    local ref = newClient({ reference = true, arrive = { prop_container_01a = 12000 } })
    ref.enter('skydome', 1.0)
    t.isTrue(c.clock <= ref.clock, 'the memo made the build slower')
    -- The positions are the same pieces either way: only the model differs,
    -- and the two containers are the same shape in this world.
    local a, b = {}, {}
    for _, object in ipairs(c.world.live()) do a[#a + 1] = ('%.2f %.2f'):format(object.x, object.y) end
    for _, object in ipairs(ref.world.live()) do b[#b + 1] = ('%.2f %.2f'):format(object.x, object.y) end
    t.equals(table.concat(a, ' '), table.concat(b, ' '), 'the pieces are not where the old walk put them')

    -- AND THE TEARDOWN STILL LETS GO OF EVERY MODEL THE BUILD ASKED FOR.
    -- The late container is asked for once and never built from. Held only
    -- when a piece was built from it, it stayed requested for the session;
    -- loadPropModel holds every model it asks for, so it is released with
    -- the rest -- the same set the old walk released by building from it.
    local containers = 0
    for _, piece in ipairs(c.env.Arena.ArenaProps('skydome', { x = 40.0, y = 40.0, top = 10.0 }, 1.0)) do
        if (piece.models or {})[1] == 'prop_container_01a' then containers = containers + 1 end
    end
    t.isTrue(containers > 70, 'the skydome has too few container pieces for this to mean anything')
    t.equals(c.calls['RequestModel:prop_container_01a'], 1, 'the late container was asked for more than once')
    t.equals(ref.calls['RequestModel:prop_container_01a'], containers,
        'the old walk did not ask for the late container on every container piece')
    c.exit()
    ref.exit()
    t.equals(released(c), 'prop_container_01a prop_container_01b prop_mp_barrier_02b stt_prop_stunt_bblock_huge_01',
        'THE DEFECT: the late container the memo build asked for was never released')
    t.equals(released(ref), 'prop_container_01a prop_container_01b prop_mp_barrier_02b stt_prop_stunt_bblock_huge_01',
        'the teardown after the old walk released a different set')
end)

t.test('a model asked for and never built from is released at teardown, late or never at all', function()
    -- With one container piece there is no later piece to build from the
    -- late model, so nothing but the request ever held it. It is released
    -- with the rest all the same -- and so is one that never arrives.
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        out[#out + 1] = cover(20.0, 0.0, { 'prop_container_01a', 'prop_container_01b' })
        out[#out + 1] = cover(0.0, 20.0, { 'prop_mp_barrier_02b' })
        return out
    end
    for _, case in ipairs({ { 'late', 12000 }, { 'never', 1e12 } }) do
        local real, ref = sameAsReference({ pieces = pieces, arrive = { prop_container_01a = case[2] } }, function(c)
            c.enter('skydome', 1.0)
            c.exit()
        end, 'one ' .. case[1] .. ' container piece')
        for _, c in ipairs({ real, ref }) do
            t.equals(c.calls['RequestModel:prop_container_01a'], 1, case[1] .. ': the container was asked for more than once')
            t.isTrue(released(c):find('prop_container_01a', 1, true) ~= nil,
                case[1] .. ': THE DEFECT: a model the build asked for stayed requested after the teardown')
            t.isTrue(released(c):find('prop_container_01b', 1, true) ~= nil, case[1] .. ': the fallback it was built from was not released')
        end
    end
end)

t.test('ON PURPOSE: and it keeps to that fallback after one of its pieces could not be built at all', function()
    -- THE MEMORY HOLDS WHAT THE CHAIN RESOLVED TO, AND ONLY A SUCCESS WRITES
    -- IT. Five hand-written pieces, timed by a camera build (no entry hold
    -- in front of it, so the clock starts at nothing):
    --
    --   container chain  first model due at 25s, far past its first wait,
    --                    so the chain resolves to its fallback at 10s;
    --   barrier          arrives at 11s;
    --   container again  the fallback has been dropped since 10.5s: the
    --                    piece walks the chain, the first model times out
    --                    at 21s, the fallback at 31s -- no piece;
    --   barrier again    dropped too until 31.5s, so the build waits;
    --   container again  the fallback is back (31.2s) and so is the first
    --                    model (25s). The memory still names the fallback,
    --                    and the fallback is what this piece is built from.
    --
    -- A failed walk does not erase the memory -- nothing but a success
    -- writes it -- and a remembered model that is not loaded is never used:
    -- the missing piece above is missing, not built from a model that was
    -- not there.
    local C = { 'prop_container_01a', 'prop_container_01b' }
    local B = { 'prop_mp_barrier_02b' }
    local pieces = function(real)
        local out = {}
        for _, piece in ipairs(real) do if piece.kind == 'floor' then out[#out + 1] = piece end end
        out[#out + 1] = cover(20.0, 0.0, C)
        out[#out + 1] = cover(0.0, 20.0, B)
        out[#out + 1] = cover(-20.0, 0.0, C)
        out[#out + 1] = cover(0.0, -20.0, B)
        out[#out + 1] = cover(10.0, 10.0, C)
        return out
    end
    local c = newClient({
        pieces = pieces,
        arrive = { prop_container_01a = 25000, prop_mp_barrier_02b = 1000 },
        evict = { prop_container_01b = { 10500, 31200 }, prop_mp_barrier_02b = { 30000, 31500 } },
    })
    c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
    t.isTrue(c.watch('skydome', 1.0), 'the camera build failed')
    t.equals(c.clock, 31500, 'the build did not run to the timeline this test was written for')

    local built = {}
    for _, object in ipairs(c.world.live()) do
        if object.model ~= 'stt_prop_stunt_bblock_huge_01' then
            built[#built + 1] = ('%s@%.0f,%.0f'):format(object.model, object.x - 1500.0, object.y - 3000.0)
        end
    end
    t.equals(table.concat(built, ' '),
        'prop_container_01b@20,0 prop_mp_barrier_02b@0,20 prop_mp_barrier_02b@0,-20 prop_container_01b@10,10',
        'the chain did not keep to the model it resolved to')
    t.equals(c.unloadedCreates, 0, 'a piece was built from a remembered model that was not loaded')
    t.isTrue(console(c):find('prop_container_01a / prop_container_01b', 1, true) ~= nil,
        'the piece that could not be built was not reported')
end)

-- ======================================================================
-- THE DIFFERENTIAL: THE REAL CLIENT AGAINST THE OLD WALK
-- ======================================================================

local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return (state // 65536) % n + 1
    end
end

local ALL_MODELS = {}
for name in pairs(World.DEFAULT_MODELS) do ALL_MODELS[#ALL_MODELS + 1] = name end
table.sort(ALL_MODELS)

--- One seeded scenario: which models the build has, how long each takes to
--- arrive (always well inside the ten-second wait, so the old walk and the
--- new one wait in exactly the same places), a window the streamer drops one,
--- the arena, the size, and whether a camera builds first and walks away.
local function scenario(rand)
    local drop = {}
    for _, name in ipairs(ALL_MODELS) do if rand(4) == 1 then drop[#drop + 1] = name end end
    local arrive, evict = {}, {}
    -- BOTH BOUNDED AT FOUR AND A HALF SECONDS, so no wait -- an arrival,
    -- a drop, or a drop straddling an arrival -- can reach the ten-second
    -- give-up. Past it is the one place the two walks are meant to differ,
    -- and that has a test of its own above.
    for _, name in ipairs(ALL_MODELS) do
        if rand(3) == 1 then arrive[name] = rand(45) * 100 end
    end
    if rand(3) == 1 then
        local name = ALL_MODELS[rand(#ALL_MODELS)]
        local from = rand(80) * 100
        evict[name] = { from, from + rand(45) * 100 }
    end
    return {
        models = without(drop), arrive = arrive, evict = evict,
        cover = rand(2) == 1 and { 'trailerpark' } or nil,
        key = rand(5) == 1 and 'trailerpark' or 'skydome',
        factor = ({ 1.0, 1.25, 1.5, 2.0 })[rand(4)],
        cameraFirst = rand(3) == 1,
        stopAt = rand(3) == 1 and rand(60) or nil,
        rounds = rand(2),
    }
end

local DIFF = { cases = 0, yields = 0, evictions = 0, cameras = 0, stopped = 0 }

t.test('over three hundred seeded builds the real client does exactly what the old walk did', function()
    local rand = generator(915)
    for n = 1, 300 do
        local s = scenario(rand)
        local label = ('scenario %d (%s %.2f)'):format(n, s.key, s.factor)
        local real = sameAsReference(s, function(c)
            if s.cameraFirst then
                c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
                c.watch('skydome', s.factor, s.stopAt)
                if not c.watching then c.env.ArenaMatch.DropSpectatorScenery() end
            end
            for _ = 1, s.rounds do
                c.enter(s.key, s.factor)
                c.exit()
            end
            c.enter(s.key, s.factor)
        end, label)
        DIFF.cases = DIFF.cases + 1
        DIFF.yields = DIFF.yields + #real.yields
        if next(s.evict) then DIFF.evictions = DIFF.evictions + 1 end
        if s.cameraFirst then DIFF.cameras = DIFF.cameras + 1 end
        if s.cameraFirst and s.stopAt then DIFF.stopped = DIFF.stopped + 1 end
    end
    t.equals(DIFF.cases, 300)
    t.isTrue(DIFF.yields > 1000 and DIFF.evictions > 50 and DIFF.cameras > 50 and DIFF.stopped > 20,
        ('the scenarios did too little: %d yields, %d evictions, %d camera builds, %d called off')
            :format(DIFF.yields, DIFF.evictions, DIFF.cameras, DIFF.stopped))
end)

--- HAND-WRITTEN LAYOUTS FOR THE SECOND SEEDED RUN. The shipped arenas lay
--- each chain's pieces in one run, so a model the streamer drops while the
--- build waits is seldom one a later piece still wants -- the run above can
--- go its whole length without a remembered model going away under a hit.
--- These interleave chains (heads shared, orders swapped, a head the build
--- lacks, a floor piece after cover) so it happens all the time.
local HAND_CHAINS = {
    { 'prop_container_01a', 'prop_container_01b' },
    { 'prop_mp_barrier_02b', 'prop_barrier_work05', 'prop_conc_blocks01a' },
    { 'prop_barrier_work05', 'prop_conc_blocks01a' },
    { 'prop_conc_blocks01a', 'prop_barrier_work05' },
    { 'prop_does_not_exist', 'prop_barrier_work05' },
    { 'prop_container_01b' },
}
local HAND_MODELS = { 'prop_container_01a', 'prop_container_01b', 'prop_mp_barrier_02b', 'prop_barrier_work05',
                      'prop_conc_blocks01a', 'stt_prop_stunt_bblock_huge_01' }

--- One seeded hand-written scenario. Every arrival and every drop is at
--- most four and a half seconds, so no wait can reach the ten-second
--- give-up -- the one place the two walks are meant to differ.
local function handScenario(rand)
    local layout = {}
    for i = 1, 10 + rand(20) do layout[i] = rand(6) == 1 and 'floor' or rand(#HAND_CHAINS) end
    local arrive, evict = {}, {}
    for i = 1, 5 do
        if rand(4) > 1 then arrive[HAND_MODELS[i]] = rand(45) * 100 end
    end
    for _ = 1, 1 + rand(3) do
        local from = rand(60) * 100
        evict[HAND_MODELS[rand(#HAND_MODELS)]] = { from, from + rand(45) * 100 }
    end
    return {
        layout = layout, arrive = arrive, evict = evict,
        models = without(rand(4) == 1 and { HAND_MODELS[rand(5)] } or {}),
        camera = rand(2) == 1,
        stopAt = rand(5) == 1 and rand(80) or nil,
    }
end

local function handPieces(layout)
    return function(real)
        local out, first = {}, nil
        for _, piece in ipairs(real) do
            if piece.kind == 'floor' then out[#out + 1] = piece; first = first or piece end
        end
        for i, what in ipairs(layout) do
            local x, y = (i % 5) * 4.0 - 8.0, (i // 5) * 4.0 + 12.0
            if what == 'floor' then
                out[#out + 1] = { kind = 'floor', models = first.models, model = first.model,
                                  x = first.x + 300.0 + i * 10.0, y = first.y, z = first.z, heading = 0.0 }
            else
                out[#out + 1] = cover(x, y, { table.unpack(HAND_CHAINS[what]) })
            end
        end
        return out
    end
end

t.test('and over a hundred and fifty seeded hand-written builds whose models go away between pieces', function()
    local rand = generator(20260926)
    local gone, cases, called = 0, 0, 0
    for n = 1, 150 do
        local s = handScenario(rand)
        s.pieces = handPieces(s.layout)
        local label = ('hand-written scenario %d (%d pieces)'):format(n, #s.layout)
        local snaps = {}
        local real, ref = sameAsReference(s, function(c)
            c.world.pedPos = { x = 1500.0, y = 3000.0, z = 1201.0 }
            if s.camera then
                c.watch('skydome', 1.0, s.stopAt)
                snaps[c] = objects(c)
                c.env.ArenaMatch.DropSpectatorScenery()
            else
                c.enter('skydome', 1.0)
                snaps[c] = objects(c)
                c.exit()
            end
        end, label)
        -- sameAsReference compares what is left after the teardown; what
        -- stood before it is the arena itself.
        t.equals(snaps[real], snaps[ref], label .. ': the arena came out different')
        cases = cases + 1
        if real.goneAsked > 0 then gone = gone + 1 end
        if s.camera and s.stopAt and not real.watching then called = called + 1 end
    end
    t.equals(cases, 150)
    -- THE POINT OF THIS RUN: a build found a model it had already built
    -- with gone, in a good share of the cases -- the moment the guarded
    -- hit exists for.
    t.isTrue(gone >= 30, ('only %d of %d builds found a model they had built with gone'):format(gone, cases))
    t.isTrue(called >= 5, ('only %d camera builds were called off'):format(called))
end)

t.test('and where a model never arrives at all, the same arena -- sooner', function()
    -- A model in the build that never streams in times out on every piece
    -- of the old walk that asks for it FIRST. When it heads a chain with a
    -- fallback, the old walk paid ten seconds per piece to reach the same
    -- fallback the memo reaches once; what is built is identical.
    local rand = generator(4242)
    for n = 1, 40 do
        local s = scenario(rand)
        s.arrive[({ 'prop_container_01a', 'prop_mp_barrier_02b', 'stt_prop_stunt_bblock_huge_01' })[rand(3)]] = NEVER
        s.evict = {}
        s.stopAt, s.cameraFirst, s.rounds = nil, false, 1
        local real, ref = newClient(s), newClient(setmetatable({ reference = true }, { __index = s }))
        for _, c in ipairs({ real, ref }) do c.enter(s.key, s.factor) end
        local label = ('never-arrives scenario %d'):format(n)
        t.equals(objects(real), objects(ref), label .. ': the arena came out different')
        t.equals(console(real), console(ref), label .. ': the consoles differ')
        t.equals(released(real), released(ref), label .. ': different models were released')
        t.isTrue(real.clock <= ref.clock, label .. ': the memo made the build slower')
        t.equals(real.unloadedCreates, 0, label)
    end
end)

os.exit(t.summary())
