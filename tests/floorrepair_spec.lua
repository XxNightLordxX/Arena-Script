--[[
    crimson_arena/tests/floorrepair_spec.lua

    THE FLOOR THAT WAS THERE AND THEN WAS NOT.

    THE REPORT, from the owner of a live server, over three messages:

      "The floor keeps disappearing occasionally in the match"
      "It was there then disappeared"
      "some of the floor disappears where you can fall through it, just
       disappears, but not the whole floor"

    Every word of that narrows it. BUILT, then GONE, so it is not a model
    this build lacks and not a draw distance -- both of those are wrong from
    the first frame. FALL THROUGH, so it is not the pieces going invisible
    and staying solid, which is what a model being evicted looks like. NOT
    THE WHOLE FLOOR, so it is not one teardown taking the arena down: it is
    individual objects ceasing to exist while the round carries on around
    the hole they leave. On the shipped skydome the floor is nine huge tiles
    and the drop is a kilometre, so one missing tile is a hole you die in.

    Two things are tested here, and they are different halves of it.

    THE HALF THIS RESOURCE CAUSES. buildArenaProps yields -- loadPropModel
    waits for a model the streamer has not finished with -- and it was not
    re-entrant. A second build starting inside that window deletes every
    piece the first has placed so far and empties the list; the first then
    carries on appending what it had left. What is standing afterwards is a
    floor with holes in it, and BOTH builds report "87 of 87 piece(s) built"
    because each counts only its own CreateObjects. Every measured fact the
    owner sent is consistent with that, including the honest-looking count.

    THE HALF THIS RESOURCE CANNOT SEE. These are client-local objects on a
    server running two hundred other resources, any of which may sweep the
    object pool, clear an area, or tidy up entities it does not recognise --
    and the engine itself reclaims entities when the object pool fills.
    Nothing in this file can stop that. What it can do is notice and put the
    piece back, and say so in the operator's console so the culprit can be
    found by what is in the log beside it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('floorrepair_spec')

local FLOOR_MODEL = 'stt_prop_stunt_bblock_huge_01'

--- A client/match.lua in a modelled game, with the clock and the streamer
--- under the test's hand.
---
--- IT IS ITS OWN FIXTURE, not propsweep_spec's. That one answers questions
--- about what a build leaves behind; these need to stop a build halfway, to
--- move the clock without moving the threads, and to take an object away
--- behind the resource's back. A fixture pulled in both directions stops
--- answering either.
local function newClient(opts)
    opts = opts or {}
    local world = World.new()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local c = { world = world, runner = runner, printed = {}, toServer = {}, released = {} }

    --- Models this world pretends are still streaming in.
    c.slowModels = {}

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

    -- A STREAMER THAT CAN BE HELD, which is the only way to get two builds
    -- overlapping. The real one holds a model for as long as it likes and
    -- loadPropModel waits on it; this world answers instantly for every
    -- model until a test says otherwise.
    overrides.HasModelLoaded = function(name)
        if c.slowModels[name] and c.slowModels[name] > 0 then
            c.slowModels[name] = c.slowModels[name] - 1
            return false
        end
        return world.models[name] ~= nil
    end

    -- RECORDED, because when a model is released is now a decision this file
    -- makes on purpose -- held for the life of the arena so a repair needs
    -- no wait -- and a stub that swallowed it could not tell that apart from
    -- releasing it at the end of the build, which is what it used to do.
    overrides.SetModelAsNoLongerNeeded = function(name)
        c.released[#c.released + 1] = name
    end

    if opts.overrides then
        for name, fn in pairs(opts.overrides) do overrides[name] = fn end
    end

    local clientEnv = Sandbox.newArenaEnv(overrides)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', clientEnv)
    c.env = clientEnv

    local function payloadFor(arenaKey)
        local arena = clientEnv.Config.Arenas[arenaKey]
        local spawn = clientEnv.Arena.PickSpawn(arenaKey, nil, 1)
        return {
            matchId = 'match-1', arenaKey = arenaKey, modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false, loadout = { weapons = {} },
            boundary = arena.boundary and {
                enabled = true,
                center = { x = arena.boundary.center.x, y = arena.boundary.center.y, z = arena.boundary.center.z },
                radius = arena.boundary.radius,
                warningSeconds = 5, damagePerTick = 20, tickMs = 500,
            } or nil,
            freezeSeconds = 0,
        }
    end
    c.payloadFor = payloadFor

    function c.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('no handler for ' .. name) end
        local args = table.pack(...)
        local thread = coroutine.create(function() handler(table.unpack(args, 1, args.n)) end)
        for _ = 1, 400 do
            if coroutine.status(thread) == 'dead' then break end
            assert(coroutine.resume(thread))
        end
        assert(coroutine.status(thread) == 'dead', name .. ' never finished')
    end

    --- Starts an entry WITHOUT running it to the end, so a test can stop it
    --- halfway and do something else on the same client.
    function c.beginEnter(arenaKey)
        local handler = handlers['crimson_arena:client:enterArena']
        local payload = payloadFor(arenaKey)
        return coroutine.create(function() handler(payload) end)
    end

    --- Resume a half-run handler `times` times, or until it finishes.
    function c.pump(thread, times)
        for _ = 1, (times or 1) do
            if coroutine.status(thread) == 'dead' then return true end
            assert(coroutine.resume(thread))
        end
        return coroutine.status(thread) == 'dead'
    end

    function c.enter(arenaKey) c.fire('crimson_arena:client:enterArena', arenaKey and arenaKey or 'skydome') end
    function c.enterArena(arenaKey) c.fire('crimson_arena:client:enterArena', payloadFor(arenaKey)) end

    --- Move the clock without moving the threads.
    function c.advance(ms) runner.elapsed = runner.elapsed + ms end

    --- One pass of every running thread, which is where the repair lives.
    function c.step(times)
        for _ = 1, (times or 1) do runner.step() end
    end

    --- Takes an object away the way something ELSE on the server would:
    --- straight out of the world, with this resource never told.
    function c.vanish(handle)
        local object = world.objects[handle]
        assert(object and not object.deleted, 'the fixture tried to vanish something that is not there')
        object.deleted = true
    end

    --- The handles of every standing piece of one model.
    function c.handlesOf(model)
        local out = {}
        for _, object in ipairs(world.liveOf(model)) do out[#out + 1] = object.handle end
        return out
    end

    --- Every line this client has sent to the server console.
    function c.serverLines()
        local out = {}
        for _, sent in ipairs(c.toServer) do
            if sent.name == 'crimson_arena:server:clientDebug' then
                local payload = sent.payload or {}
                if type(payload.lines) == 'table' then
                    for _, line in ipairs(payload.lines) do out[#out + 1] = line end
                elseif type(payload.line) == 'string' then
                    out[#out + 1] = payload.line
                end
            end
        end
        return out
    end

    function c.saidToServer(fragment)
        for _, line in ipairs(c.serverLines()) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    return c
end

--- The arena, entered, with the repair's first free pass already spent.
local function standing(c)
    c.enterArena('skydome')
    local pieces = #c.world.live()
    t.isTrue(pieces > 0, 'the fixture built no arena at all, so nothing below tests anything')
    c.step(1)
    return pieces
end

-- ======================================================================
-- THE HOLE, AND PUTTING IT BACK
-- ======================================================================

t.test('CONTROL: an arena nobody has touched is not rebuilt and says nothing', function()
    -- The repair runs on a timer over every standing round. If it did
    -- ANYTHING to an intact arena -- one duplicate tile, one line in the
    -- operator's log every two seconds -- it would be worse than the fault.
    local c = newClient()
    local pieces = standing(c)

    for _ = 1, 5 do
        c.advance(2500)
        c.step(1)
    end

    t.equals(#c.world.live(), pieces, 'an intact arena came back a different size')
    t.isTrue(not c.saidToServer('PUT BACK'), 'an intact arena reported a repair')
end)

t.test('THE REPORT: a floor tile that stops existing is put back', function()
    local c = newClient()
    local pieces = standing(c)

    local floor = c.handlesOf(FLOOR_MODEL)
    t.isTrue(#floor >= 2, 'the sky arena did not build a tiled floor, so this tests nothing')

    -- Taken away the way anything else on the server would: no call into
    -- this resource, no event, just gone.
    c.vanish(floor[1])
    t.equals(#c.world.live(), pieces - 1, 'the fixture did not actually take the tile away')

    c.advance(2500)
    c.step(1)

    t.equals(#c.world.live(), pieces, 'THE DEFECT: the hole in the floor was left there')
    t.equals(#c.handlesOf(FLOOR_MODEL), #floor, 'the floor came back a different number of tiles')
end)

t.test('and it goes back in exactly the place it was, not near it', function()
    -- A tile an inch out is a seam, and a seam on a platform a kilometre up
    -- is the same fall as the hole. The replacement is built from what
    -- CreateObject was given the first time and never from the arithmetic
    -- again, which is what this pins.
    local c = newClient()
    standing(c)

    local floor = c.handlesOf(FLOOR_MODEL)
    local was = c.world.objects[floor[1]]
    local wasX, wasY, wasZ, wasHeading = was.x, was.y, was.z, was.heading

    c.vanish(floor[1])
    c.advance(2500)
    c.step(1)

    local now = nil
    for _, object in ipairs(c.world.liveOf(FLOOR_MODEL)) do
        if object.handle ~= floor[1] and math.abs(object.x - wasX) < 0.001 then now = object end
    end

    t.isTrue(now ~= nil, 'no tile was put back at the missing one\'s position')
    t.equals(now.y, wasY, 'the replacement tile landed at a different y')
    t.equals(now.z, wasZ, 'the replacement tile landed at a different height')
    t.equals(now.heading, wasHeading, 'the replacement tile was laid at a different heading')
end)

t.test('and it is solid and drawn, like the one it replaces', function()
    -- COLLISION IS THE HALF THAT MATTERS. A replacement that is drawn but
    -- not solid is a floor you can see and still fall through, which is the
    -- reported symptom with an extra step.
    local c = newClient()
    standing(c)

    local floor = c.handlesOf(FLOOR_MODEL)
    c.vanish(floor[1])
    c.advance(2500)
    c.step(1)

    local now = nil
    for _, object in ipairs(c.world.liveOf(FLOOR_MODEL)) do
        local fresh = true
        for _, old in ipairs(floor) do if old == object.handle then fresh = false end end
        if fresh then now = object end
    end

    t.isTrue(now ~= nil, 'nothing was put back, so this tests nothing')
    t.isTrue(now.collision == true, 'the tile went back with no collision -- you can still fall through it')
    t.isTrue((now.lodDist or 0) > 0, 'the tile went back with no draw distance')
end)

t.test('several pieces at once, floor and cover together', function()
    local c = newClient()
    local pieces = standing(c)

    local live = c.world.live()
    local taken = {}
    for i = 1, 6 do taken[#taken + 1] = live[i].handle end
    for _, handle in ipairs(taken) do c.vanish(handle) end
    t.equals(#c.world.live(), pieces - 6, 'the fixture did not take six pieces away')

    c.advance(2500)
    c.step(1)

    t.equals(#c.world.live(), pieces, 'the arena did not come back whole')
end)

t.test('it tells the SERVER console, in one event', function()
    -- The operator watching a floor vanish is reading the server console,
    -- not the player's F8 -- and the server allows one debug event per
    -- second per player, so a report sent a line at a time arrives as its
    -- first line and nothing else.
    local c = newClient()
    standing(c)

    c.vanish(c.handlesOf(FLOOR_MODEL)[1])
    c.advance(2500)
    c.step(1)

    -- COUNTED BY WHAT THEY CARRY, not by how many arrived. Other threads on
    -- this client talk to the server in the same pass -- the outline reason
    -- is one -- so a bare count of events would have been asserting their
    -- behaviour and not this one's.
    local carrying = 0
    for _, sent in ipairs(c.toServer) do
        local payload = sent.payload or {}
        local lines = type(payload.lines) == 'table' and payload.lines
            or (type(payload.line) == 'string' and { payload.line } or {})
        for _, line in ipairs(lines) do
            if line:find('PUT BACK', 1, true) then carrying = carrying + 1 break end
        end
    end
    t.equals(carrying, 1, 'the repair report was split across several events')
    t.isTrue(c.saidToServer('PUT BACK'), 'the repair was not reported to the server at all')
    t.isTrue(c.saidToServer('something else on this server is removing them'),
        'the report does not say what an operator should go and look for')
end)

t.test('and it does not walk the arena more often than its interval', function()
    -- A walk over ninety entities every frame is the cost of getting this
    -- wrong, on a client already drawing a round.
    --
    -- THE CLOCK IS HELD STILL RATHER THAN RACED, and that is the second
    -- version of this test. The first stepped twenty frames and asserted
    -- nothing had been repaired -- but other threads on this client sleep in
    -- whole seconds, and in this fixture a sleep MOVES the clock, so twenty
    -- frames quietly went past the interval and the test was asserting the
    -- opposite of what it says. Frozen, there is no window to fall out of.
    local c = newClient()
    local pieces = standing(c)

    -- Spend the pass the arena is owed, so the next one is on the timer.
    c.advance(2500)
    c.step(1)

    c.vanish(c.handlesOf(FLOOR_MODEL)[1])

    local frozen = c.runner.elapsed
    for _ = 1, 10 do
        c.step(1)
        c.runner.elapsed = frozen
    end

    t.equals(#c.world.live(), pieces - 1,
        'the repair ran with the clock standing still, so it runs every frame')

    c.advance(2500)
    c.step(1)
    t.equals(#c.world.live(), pieces, 'and then it never ran at all')
end)

t.test('a client that has left the arena repairs nothing', function()
    -- The repair must not outlive the round: pieces taken down on purpose
    -- are exactly the pieces it would be putting back.
    local c = newClient()
    standing(c)
    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, 'the ordinary teardown already failed')

    for _ = 1, 5 do
        c.advance(2500)
        c.step(1)
    end

    t.equals(#c.world.live(), 0, 'the repair rebuilt an arena the player had left')
end)

t.test('the models are held while the arena stands and released when it comes down', function()
    -- HELD FOR THE LIFE OF THE ARENA, not for the life of the build. A
    -- repair that had to RequestModel and wait is a hole in the floor for as
    -- long as the wait -- and on the path this exists for, somebody is
    -- standing on that hole.
    local c = newClient()
    standing(c)

    t.equals(#c.released, 0, 'the arena released its models the moment it finished building')

    c.fire('crimson_arena:client:exitArena', {})

    local releasedFloor = false
    for _, name in ipairs(c.released) do if name == FLOOR_MODEL then releasedFloor = true end end
    t.isTrue(releasedFloor, 'the teardown never released the floor model, which is a leak')
end)

-- ======================================================================
-- THE RACE THAT MADE THE HOLES IN THE FIRST PLACE
-- ======================================================================

t.test('THE DEFECT: the spectator camera does not eat a build that is still running', function()
    -- THE RACE, AS IT ACTUALLY HAPPENS. buildArenaProps yields inside
    -- loadPropModel, waiting on a model the streamer has not finished with.
    -- ArenaMatch.EnsureSpectatorScenery runs off a per-frame loop and its
    -- "is one already standing" guard reads `#arenaProps > 0` -- which is
    -- false for the whole of that wait, because the first piece has not been
    -- placed yet. So it starts a build of its own, and that build's opening
    -- act used to be clearArenaScenery: every piece the first build had
    -- placed, deleted, and the list emptied under it.
    --
    -- The first build then carried on appending what it had left to an empty
    -- list and stopped. What is standing afterwards is a floor with holes in
    -- it -- and BOTH builds report a full count, because each counts only its
    -- own CreateObjects. That is the owner's report exactly: built, then
    -- partly gone, with the log insisting everything was built.
    --
    -- ONE CLIENT DOES BOTH. A fighter who is eliminated and starts watching
    -- their own round is the spectator loop and the arena on one machine.
    local c = newClient()

    -- Hold the streamer on the cover model, so the first build gets its
    -- floor down and then parks mid-arena.
    c.slowModels['prop_container_01a'] = 40

    local first = c.beginEnter('skydome')
    c.pump(first, 12)
    t.isTrue(coroutine.status(first) ~= 'dead', 'the fixture never stopped the first build halfway')

    local placed = #c.world.live()
    t.isTrue(placed > 0, 'the first build had placed nothing yet, so this tests nothing')

    -- The camera, arriving while the first build is parked.
    c.slowModels['prop_container_01a'] = 0
    c.env.ArenaMatch.EnsureSpectatorScenery('skydome', 1.0)

    t.isTrue(#c.world.live() >= placed,
        'THE DEFECT: the spectator build deleted the pieces the entry build had already placed')

    -- And the entry build is allowed to finish into a world it still owns.
    c.pump(first, 400)
    t.isTrue(coroutine.status(first) == 'dead', 'the entry build never finished')

    t.isTrue(#c.handlesOf(FLOOR_MODEL) > 0, 'the arena ended up with no floor at all')

    -- EVERY PIECE EXACTLY ONCE, which is the other half of the fault: two
    -- builds that both completed is two props in the same place, and that
    -- flickers while staying solid.
    local clean = newClient()
    clean.enterArena('skydome')
    t.equals(#c.world.live(), #clean.world.live(),
        ('the racing client ended up with %d piece(s) where a clean one has %d')
            :format(#c.world.live(), #clean.world.live()))
end)

t.test('THE INVARIANT: nothing tears down what a build is still placing', function()
    -- MUTATION TESTING WROTE THIS TEST. Deleting the refusal in
    -- clearArenaScenery failed nothing in this file -- the two race tests
    -- above are both stopped one level higher, by
    -- EnsureSpectatorScenery's own "is one already standing" guard -- so the
    -- rule that actually protects the pieces had no test at all and could
    -- have been deleted by anybody tidying up.
    --
    -- THE PATH IT LEAVES OPEN is not the camera; it is a round ENDING while
    -- a client is still laying the arena for it. leaveArena's first act is
    -- clearArenaScenery, and it runs before it checks anything else at all.
    -- The client/match.lua note at enterArena's post-build re-check already
    -- describes this window in as many words.
    --
    -- ASSERTED IN THE MIDDLE, NOT AT THE END, and that is the only place it
    -- can be seen. Both ways round the arena is empty when everything has
    -- finished -- with the guard because the build's own post-check takes it
    -- down, without it because the teardown already did. What differs is
    -- whether the pieces survive the moment, and a build whose pieces are
    -- deleted out from under it carries on appending to an empty list.
    local c = newClient()
    c.slowModels['prop_container_01a'] = 40

    local first = c.beginEnter('skydome')
    c.pump(first, 12)
    t.isTrue(coroutine.status(first) ~= 'dead', 'the fixture never stopped the build halfway')

    local placed = #c.world.live()
    t.isTrue(placed > 0, 'the build had placed nothing yet, so there is nothing to protect')

    c.slowModels['prop_container_01a'] = 0
    c.fire('crimson_arena:client:exitArena', {})

    t.equals(#c.world.live(), placed,
        'THE DEFECT: a teardown deleted the pieces a build was still placing')

    -- AND THE ARENA STILL COMES DOWN. Refusing the teardown must not leave
    -- scenery standing after the round: the build's own post-check finds the
    -- match gone and clears it, by which time the flag is down.
    c.pump(first, 400)
    t.isTrue(coroutine.status(first) == 'dead', 'the build never finished')
    t.equals(#c.world.live(), 0, 'the arena was left standing after the round it belonged to')
end)

t.test('and the refusal is said once, not swallowed', function()
    -- THE FLOOR MODEL IS THE ONE HELD HERE, not the cover, and the
    -- difference is the whole test. Held on the cover, the entry build has
    -- already put its floor tiles down -- so EnsureSpectatorScenery's own
    -- "is one already standing" guard answers yes and it never asks for a
    -- build at all. That is the guard working one level up, and it is what
    -- the test above measures. To reach the REFUSAL the second caller has
    -- to find nothing standing, which means stopping the first build before
    -- it places anything: held on the very first model it asks for.
    local c = newClient()
    c.slowModels[FLOOR_MODEL] = 40

    local first = c.beginEnter('skydome')
    c.pump(first, 12)
    t.equals(#c.world.live(), 0, 'the entry build placed something, so nothing will be refused')

    c.slowModels[FLOOR_MODEL] = 0
    c.env.ArenaMatch.EnsureSpectatorScenery('skydome', 1.0)

    local said = false
    for _, line in ipairs(c.printed) do
        if line:find('a second build was asked for', 1, true) then said = true end
    end
    t.isTrue(said, 'a build was refused and nothing anywhere says so')

    -- AND THE REFUSAL COST THE FIRST BUILD NOTHING. Its caller's failure
    -- path runs clearArenaScenery, which is where the damage used to be
    -- done; refused while a build is in flight, it is a no-op.
    c.pump(first, 400)
    t.isTrue(coroutine.status(first) == 'dead', 'the entry build never finished')

    local clean = newClient()
    clean.enterArena('skydome')
    t.equals(#c.world.live(), #clean.world.live(),
        'the entry build came out a different size after the camera was refused')
end)

t.test('and a refused build does not leave the guard up for the session', function()
    -- A flag left raised by an early return refuses every build for the rest
    -- of the session: arenas that never appear at all, which is worse than
    -- the race it was raised to stop.
    local c = newClient()
    c.slowModels[FLOOR_MODEL] = 40

    local first = c.beginEnter('skydome')
    c.pump(first, 12)
    c.slowModels[FLOOR_MODEL] = 0
    c.env.ArenaMatch.EnsureSpectatorScenery('skydome', 1.0)
    c.pump(first, 400)

    c.fire('crimson_arena:client:exitArena', {})
    t.equals(#c.world.live(), 0, 'the teardown failed, so the next build is not a clean test')

    c.enterArena('skydome')
    t.isTrue(#c.world.live() > 0, 'the next round built no arena at all -- the guard was left up')
end)

t.test('and an ordinary round after an ordinary round still builds', function()
    -- The plain control for the guard: nothing exotic, twice.
    local c = newClient()
    c.enterArena('skydome')
    local first = #c.world.live()
    c.fire('crimson_arena:client:exitArena', {})

    c.enterArena('skydome')
    t.equals(#c.world.live(), first, 'the second ordinary round came out a different size')
end)

os.exit(t.summary())
