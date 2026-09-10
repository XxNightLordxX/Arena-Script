--[[
    crimson_arena/tests/handback_spec.lua

    WHAT THE ARENA CHANGES ABOUT A PLAYER, AND WHETHER IT PUTS IT BACK.

    THREE THINGS, ALL REPORTED FROM THE SAME SEAT.

      GOD MODE IS SWITCHED OFF ON THE WAY OUT, and it was never switched on
      by this resource. The exit calls SetEntityInvincible(ped, false)
      unconditionally, so an admin who walked in with god mode on walks out
      mortal -- along with anybody who was deliberately invisible or without
      collision.

      THE FENCE FOLLOWS A FIGHTER INTO HIS OWN ROUND. The client's keep-out
      loop asks only "is this point inside a zone the server sent"; it never
      asks "am I in a match". The server's exemption lives in a snapshot that
      arrives AFTER the enterArena that teleports him in, so between the two
      the ped is inside a fence and gets teleported to the rim and snapped to
      the ground, four times a second.

      AND THE FENCE OUTLIVES THE ROUND. A player who has left a match with
      the panel shut is in no recipient set, so no further state ever reaches
      him -- and his client goes on enforcing the last list it was given for
      the rest of the session.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('handback_spec')

-- ======================================================================
-- THE FOUR PROPERTIES THE DEAD-STATE HOLD WRITES
-- ======================================================================

--- The real client/dispatch.lua, with every property write recorded and the
--- ped's prior state under the test's control.
local function newDispatch(before)
    before = before or {}
    local writes = {}
    local ped = { invincible = before.invincible == true,
        visible = before.visible ~= false,
        collision = before.collision ~= false,
        frozen = before.frozen == true }

    local env = Sandbox.newArenaEnv({
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        CreateThread = function() end,
        exports = setmetatable({}, { __call = function() end }),
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,

        PlayerPedId = function() return 11 end,
        GetEntityCoords = function() return { x = 1.0, y = 2.0, z = 3.0 } end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityMaxHealth = function() return 200 end,
        NetworkResurrectLocalPlayer = function() end,
        SetEntityHealth = function() end,

        SetEntityInvincible = function(_, on)
            writes[#writes + 1] = { 'invincible', on }; ped.invincible = on
        end,
        SetEntityVisible = function(_, on)
            writes[#writes + 1] = { 'visible', on }; ped.visible = on
        end,
        SetEntityCollision = function(_, on)
            writes[#writes + 1] = { 'collision', on }; ped.collision = on
        end,
        FreezeEntityPosition = function(_, on)
            writes[#writes + 1] = { 'frozen', on }; ped.frozen = on
        end,

        -- The readers a real client has. A build without them is covered by
        -- its own test further down.
        IsEntityVisible = function() return ped.visible end,
        GetEntityCollisionDisabled = function() return not ped.collision end,
        IsEntityPositionFrozen = function() return ped.frozen end,
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../client/dispatch.lua', env)

    return { env = env, ped = ped, writes = writes, dispatch = env.ArenaDispatch }
end

local function wrote(writes, name)
    for _, entry in ipairs(writes) do
        if entry[1] == name then return true end
    end
    return false
end

t.test('DEFECT: an admin who never died walks out of a match without god mode', function()
    local c = newDispatch({ invincible = true })
    c.dispatch.Enter('m1')

    -- Nobody died, so the hold was never taken. This is the exit path:
    -- leaveArena calls ReleaseDeadState on every way out of a round.
    c.dispatch.ReleaseDeadState(11)

    t.isTrue(c.ped.invincible,
        'the exit switched god mode off, and this resource never switched it on')
    t.isFalse(wrote(c.writes, 'invincible'),
        'invincibility was written on an exit that never held anybody')
end)

t.test('and a player who was deliberately invisible is not made visible by it', function()
    local c = newDispatch({ visible = false, collision = false })
    c.dispatch.Enter('m1')
    c.dispatch.ReleaseDeadState(11)

    t.isFalse(c.ped.visible, 'the exit made an invisible player visible')
    t.isFalse(c.ped.collision, 'the exit gave collision back to a player who had none')
end)

t.test('and a player who froze themselves is not unfrozen by it', function()
    local c = newDispatch({ frozen = true })
    c.dispatch.Enter('m1')
    c.dispatch.ReleaseDeadState(11)

    t.isTrue(c.ped.frozen, 'the exit unfroze a player this resource never froze')
end)

t.test('but a real death is still held, and still released', function()
    local c = newDispatch()
    c.dispatch.Enter('m1')

    t.isTrue(c.dispatch.ClearDeadState(11), 'the casualty was not picked up')
    t.isTrue(c.ped.invincible, 'a held casualty is shootable')
    t.isFalse(c.ped.visible, 'a held casualty is on show')
    t.isFalse(c.ped.collision, 'a held casualty can be walked into')
    t.isTrue(c.ped.frozen, 'a held casualty can walk')

    c.dispatch.ReleaseDeadState(11)

    t.isFalse(c.ped.invincible, 'the hold left the player invincible')
    t.isTrue(c.ped.visible, 'the hold left the player invisible')
    t.isTrue(c.ped.collision, 'the hold left the player without collision')
    t.isFalse(c.ped.frozen, 'the hold left the player frozen')
end)

t.test('and a held casualty who was ALREADY invisible stays invisible after it', function()
    -- EXACTLY HOW THEY WERE, which is not the same as "normal".
    local c = newDispatch({ visible = false })
    c.dispatch.Enter('m1')
    c.dispatch.ClearDeadState(11)
    c.dispatch.ReleaseDeadState(11)

    t.isFalse(c.ped.visible,
        'the release handed back a constant instead of what the player had')
end)

t.test('and releasing twice does not write anything the second time', function()
    local c = newDispatch()
    c.dispatch.Enter('m1')
    c.dispatch.ClearDeadState(11)
    c.dispatch.ReleaseDeadState(11)

    local mark = #c.writes
    c.dispatch.ReleaseDeadState(11)
    t.equals(#c.writes, mark, 'a second release wrote to the ped again')
end)

t.test('and a build with no readers still hands the hold back rather than keeping it', function()
    -- A CLIENT THAT CANNOT BE ASKED IS NOT A CLIENT THAT IS LEFT HELD.
    -- Without a getter the release cannot know what it was, so it undoes
    -- what it itself wrote -- which is strictly what it did before, and is
    -- never worse than leaving a player invisible and frozen for ever.
    local c = newDispatch()
    c.env.IsEntityVisible = nil
    c.env.GetEntityCollisionDisabled = nil
    c.env.IsEntityPositionFrozen = nil

    c.dispatch.Enter('m1')
    c.dispatch.ClearDeadState(11)
    c.dispatch.ReleaseDeadState(11)

    t.isTrue(c.ped.visible, 'a build with no getters left the player invisible')
    t.isTrue(c.ped.collision, 'a build with no getters left the player without collision')
    t.isFalse(c.ped.frozen, 'a build with no getters left the player frozen')
    t.isFalse(c.ped.invincible, 'a build with no getters left the player invincible')
end)

t.test('and the hold is reported, so the spectator exit knows who owns the ped', function()
    local c = newDispatch()
    c.dispatch.Enter('m1')
    t.isFalse(c.dispatch.IsHoldingDeadState(), 'nothing is held before anybody dies')
    c.dispatch.ClearDeadState(11)
    t.isTrue(c.dispatch.IsHoldingDeadState(), 'a held casualty is not reported as held')
    c.dispatch.ReleaseDeadState(11)
    t.isFalse(c.dispatch.IsHoldingDeadState(), 'the hold was reported after it was let go')
end)

-- ======================================================================
-- THE FENCE, AND THE ROUND THE PLAYER IS STANDING IN
--
-- The zone below is the SHIPPED skydome boundary. A fighter placed into that
-- arena is, by construction, inside it.
-- ======================================================================

local ARENA = { x = 1500.0, y = 3000.0, z = 1201.0, radius = 110.0, label = 'The Skydome' }

--- The real client/match.lua, with the barrier loop steppable and every
--- teleport recorded.
local function newClient(inRound, watching)
    local runner = Sandbox.newThreadRunner()
    local moves = {}
    local pos = { x = ARENA.x + 10.0, y = ARENA.y, z = ARENA.z }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,

        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { x = pos.x, y = pos.y, z = pos.z } end,
        SetEntityCoordsNoOffset = function(_ped, x, y, z)
            moves[#moves + 1] = { x = x, y = y, z = z }
            pos = { x = x, y = y, z = z }
        end,
        -- The desert under the platform, which is where the fence puts you.
        GetGroundZFor_3dCoord = function() return true, 30.0 end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        FreezeEntityPosition = function() end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGameTimer = function() return 1000 end,
        joaat = function(name) return name end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end, Exit = function() end,
            ClearDeadState = function() return true end, ReleaseDeadState = function() end,
            IsInArena = function() return inRound == true end,
        },
        ArenaSpectate = { IsActive = function() return watching == true end },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../client/match.lua', env)

    return {
        env = env, moves = moves,
        at = function(x, y, z) pos = { x = x, y = y, z = z } end,
        step = runner.step,
        setZones = function(zones) env.ArenaMatch.SetKeepOut(zones) end,
    }
end

t.test('DEFECT: the fence throws a fighter out of the arena he is fighting in', function()
    -- THE SEQUENCE IS THE SERVER'S OWN, not an invented one. A player
    -- standing outside a live skydome round is sent a fence round it; he
    -- then starts a round of his own there, and the server sends enterArena
    -- -- which teleports him in -- BEFORE the state push that drops the
    -- fence. Between the two his client holds a circle round the ground he
    -- has just been put on, and this loop acts on it four times a second.
    local c = newClient(true)
    c.setZones({ ARENA })
    c.step(); c.step(); c.step()

    t.equals(#c.moves, 0,
        ('the fence moved a fighter %d time(s) out of his own live arena'):format(#c.moves))
end)

t.test('and it leaves a spectator parked at the arena he is watching alone', function()
    local c = newClient(false, true)
    c.setZones({ ARENA })
    c.step(); c.step(); c.step()

    t.equals(#c.moves, 0, 'the fence teleported a spectator away from the round he is watching')
end)

t.test('but an outsider standing in that same arena is still moved out', function()
    -- The fence has to go on working, or the fix has traded one bug for a
    -- hole. Nobody in a round, nobody watching: the ordinary case.
    local c = newClient(false, false)
    c.setZones({ ARENA })
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'the fence stopped keeping outsiders out altogether')

    local last = c.moves[#c.moves]
    local dx, dy = last.x - ARENA.x, last.y - ARENA.y
    t.isTrue(math.sqrt(dx * dx + dy * dy) > ARENA.radius,
        'the outsider was left inside the fence')
end)

-- ======================================================================
-- THE WHOLE ROUND, DRIVEN THROUGH THE REAL EVENT HANDLERS
--
-- The two sections above test the pieces. This one puts a player into a
-- round, kills him, respawns him and takes him out again through the same
-- events the server sends, and reads the ped afterwards -- which is the
-- thing the owner is actually looking at.
-- ======================================================================

--- @param before table -- what the ped was like before the arena touched it
local function newRound(before, mutate)
    before = before or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local ped = { frozen = before.frozen == true, visible = before.visible ~= false,
        collision = before.collision ~= false, invincible = before.invincible == true,
        armour = before.armour or 0 }
    local world = { weatherCleared = 0, clockCleared = 0, inArenaWhenStopped = nil }

    -- Read at call time: the environment does not exist yet when the
    -- ArenaSpectate double below is written into it.
    local built
    local function dispatch() return built.ArenaDispatch end
    local pos = { x = 2344.0, y = 2565.0, z = 46.7 }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        exports = setmetatable({}, { __call = function() end }),
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { x = pos.x, y = pos.y, z = pos.z } end,
        SetEntityCoordsNoOffset = function(_p, x, y, z) pos = { x = x, y = y, z = z } end,
        GetGroundZFor_3dCoord = function() return true, 46.0 end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        GetEntityMaxHealth = function() return 200 end,
        SetEntityHealth = function() end,
        GetPedArmour = function() return ped.armour end,
        SetPedArmour = function(_p, value) ped.armour = value end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        GetSelectedPedWeapon = function() return 0 end,
        SetCurrentPedWeapon = function() end,
        RemoveAllPedWeapons = function() end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        ClearPedBloodDamage = function() end,
        NetworkResurrectLocalPlayer = function() end,
        FreezeEntityPosition = function(_p, on) ped.frozen = on end,
        SetEntityVisible = function(_p, on) ped.visible = on end,
        SetEntityCollision = function(_p, on) ped.collision = on end,
        SetEntityInvincible = function(_p, on) ped.invincible = on end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGameTimer = function() return 1000 end,
        joaat = function(name) return name end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        GetPlayerTeam = function() return -1 end,
        SetPlayerTeam = function() end,
        NetworkSetFriendlyFireOption = function() end,
        SetCanAttackFriendly = function() end,
        IsEntityVisible = function() return ped.visible end,
        GetEntityCollisionDisabled = function() return not ped.collision end,
        IsEntityPositionFrozen = function() return ped.frozen end,
        ArenaSpectate = {
            IsActive = function() return false end,
            -- Records what the round flag said at the instant leaveArena
            -- stopped the camera, which is the whole of the ordering test
            -- below.
            Stop = function() world.inArenaWhenStopped = dispatch().IsInArena() end,
        },
        GetEntityHeading = function() return 0.0 end,
        ClearOverrideWeather = function() world.weatherCleared = world.weatherCleared + 1 end,
        NetworkClearClockTimeOverride = function() world.clockCleared = world.clockCleared + 1 end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        RemoveBlip = function() end,
        DoesEntityExist = function() return true end,
        SetEntityDrawOutline = function() end,
        ResetEntityDrawOutlineRenderTechnique = function() end,
    })

    built = env

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    -- An arena with nothing to build, so the handler does not yield on model
    -- loads. What is being tested is the ped, not the scenery.
    env.Arena.GetPlatform = function() return nil end
    env.Arena.GetCover = function() return {} end
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../client/dispatch.lua', env)
    Sandbox.loadInto('../client/match.lua', env)

    local round = { env = env, ped = ped, world = world, step = runner.step }

    function round.fire(event, payload)
        local handler = handlers['crimson_arena:client:' .. event]
        if not handler then error('no client handler for ' .. event, 2) end
        handler(payload)
    end

    function round.enter()
        round.fire('enterArena', {
            matchId = 'm1', arenaKey = 'trailerpark', modeKey = 'ffa',
            spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
            scatterRadius = 0.0, sizeFactor = 1.0, radar = false, loadout = {},
            boundary = { enabled = true, center = { x = 2344.4, y = 2565.0, z = 46.7 }, radius = 100.0 },
            freezeSeconds = 0,
        })
        round.fire('matchLive', {})
    end

    function round.respawn()
        round.fire('respawn', {
            spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
            scatterRadius = 0.0, loadout = {},
        })
    end

    return round
end

t.test('DEFECT: god mode survives a round nobody died in', function()
    local r = newRound({ invincible = true })
    r.enter()
    r.fire('exitArena', {})

    t.isTrue(r.ped.invincible, 'the arena switched god mode off on the way out')
end)

t.test('and it survives a round the player died in and was put back into', function()
    local r = newRound({ invincible = true })
    r.enter()
    -- The arena's own hold takes the invincibility while the body is held,
    -- and hands it back at the respawn. It cannot hand back a reading it has
    -- no getter for, so god mode is off from here -- and the point of this
    -- test is that the far more common case above is not paying for it.
    r.respawn()
    r.fire('exitArena', {})
    t.isFalse(r.ped.frozen, 'the exit left the player frozen')
end)

t.test('and a respawn is never left frozen, on a server that holds no casualties', function()
    -- Config.Dispatch.clearDeadStateImmediately off means no hold is ever
    -- taken, so there is no release to lean on for the unfreeze.
    local r = newRound(nil, function(config)
        config.Dispatch.clearDeadStateImmediately = false
    end)
    r.enter()
    r.respawn()

    t.isFalse(r.ped.frozen,
        'the respawn left the fighter frozen to the spot for the rest of the round')
end)

t.test('and the exit still stands a held casualty back up', function()
    local r = newRound()
    r.enter()
    r.env.ArenaDispatch.ClearDeadState(11)
    t.isFalse(r.ped.visible, 'the casualty was not held')

    r.fire('exitArena', {})
    t.isTrue(r.ped.visible, 'the exit left the player invisible')
    t.isTrue(r.ped.collision, 'the exit left the player without collision')
    t.isFalse(r.ped.frozen, 'the exit left the player frozen')
    t.isFalse(r.ped.invincible, 'the exit left the player invincible')
end)

-- ======================================================================
-- AND THE FENCE MUST NOT OUTLIVE THE ROUND IT WAS PUT UP FOR
--
-- The real server, two matches, and a player who finishes his round with the
-- panel shut -- which is every player who ever fights one.
-- ======================================================================

local PLACES = {
    trailerpark = { x = 2344.4, y = 2565.1, z = 46.7 },
    skydome = { x = 1500.0, y = 3000.0, z = 1201.0 },
}

local function newServer()
    local players = {}
    for src = 1, 4 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 50000, bank = 50000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, sent, bucketOf, at = {}, {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, src, payload)
            sent[src] = sent[src] or {}
            sent[src][#sent[src] + 1] = { event = event, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            local point = at[tonumber(ped) or -1] or PLACES.trailerpark
            return { x = point.x, y = point.y, z = point.z }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end, ReclaimAll = function() return 0 end,
            Clear = function() return true end, OnLoan = function() return 0 end,
        },
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return bucketOf[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) bucketOf[src] = bucket end,
        SetRoutingBucketEntityLockdownMode = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.maxConcurrentMatches = 0

    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { lobby = env.ArenaLobby, match = env.ArenaMatch }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        env.source = src
        handler(data)
    end
    function server.step(times) for _ = 1, (times or 1) do threads.step() end end

    --- The fence the LAST state push actually told this player about, which
    --- is the only thing their client is acting on.
    function server.fenceOn(src)
        local list = sent[src] or {}
        for i = #list, 1, -1 do
            if list[i].event == 'crimson_arena:client:state' then
                local zones = list[i].payload.keepOut or {}
                local labels = {}
                for _, zone in ipairs(zones) do labels[#labels + 1] = tostring(zone.label) end
                table.sort(labels)
                return table.concat(labels, ' + ')
            end
        end
        return nil
    end

    function server.run(arenaKey, ids)
        server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })
        local match
        for _, entry in ipairs(server.lobby.All()) do
            if entry.hostSource == ids[1] then match = entry end
        end
        for i = 2, #ids do server.fire('joinMatch', ids[i], { matchId = match.id }) end
        for _, src in ipairs(ids) do at[src] = PLACES[arenaKey] end
        server.fire('startMatch', ids[1])
        server.step(6)
        return match.id
    end

    return server
end

t.test('DEFECT: the fence a player carries out of his round is never taken down', function()
    local server = newServer()
    local mine = server.run('skydome', { 1, 2 })
    local theirs = server.run('trailerpark', { 3, 4 })

    t.equals(server.fenceOn(1), 'Trailer Park',
        'fighter 1 was not fenced out of the other live round, so this proves nothing')

    -- His own round finishes. He has no panel open -- nobody does, mid-fight
    -- -- so from here he is in no recipient set at all.
    server.match.End(mine, 'match.ended', { 2 })
    server.step(3)

    -- And now the round he WAS fenced out of finishes too.
    server.match.End(theirs, 'match.ended', { 4 })
    server.step(3)

    t.equals(server.fenceOn(1), '',
        'his client is still holding a fence round an arena where nothing is happening')
end)

t.test('and a player who walks out mid-round has his taken down too', function()
    local server = newServer()
    server.run('skydome', { 1, 2 })
    local theirs = server.run('trailerpark', { 3, 4 })

    server.fire('leaveMatch', 1, {})
    server.step(3)
    t.equals(server.fenceOn(1), 'Trailer Park',
        'a man standing outside a live round is meant to still be fenced out of it')

    server.match.End(theirs, 'match.ended', { 4 })
    server.step(3)
    t.equals(server.fenceOn(1), '', 'the fence outlived the round that put it up')
end)

t.test('and a fighter is never fenced out of the arena he is standing in', function()
    -- The half the server already had right, kept honest.
    local server = newServer()
    server.run('skydome', { 1, 2 })
    server.run('skydome', { 3, 4 })

    t.equals(server.fenceOn(1), '', 'a fighter was sent a fence round his own arena')
    t.equals(server.fenceOn(3), '', 'the second match at the same arena fenced its own fighters')
end)

t.test('DEFECT: the arena keeps a player in its own armour when the loadout is not handed back', function()
    -- Config.Match.restoreLoadoutOnExit off means "do not hand their weapons
    -- back", and it was reading as "let them keep ours".
    local r = newRound({ armour = 0 }, function(config)
        config.Match.restoreLoadoutOnExit = false
    end)
    r.enter()
    r.env.ArenaMatch.SetKeepOut(nil)
    -- The arena's own plate, written straight onto the ped.
    r.ped.armour = 100

    r.fire('exitArena', {})
    t.equals(r.ped.armour, 0, 'the fighter walked out wearing the arena\'s armour')
end)

t.test('and it hands back the armour a player walked in with', function()
    local r = newRound({ armour = 45 })
    r.enter()
    r.ped.armour = 100
    r.fire('exitArena', {})
    t.equals(r.ped.armour, 45, 'the player did not get their own armour back')
end)

t.test('DEFECT: a round with no weather of its own cancelled the server\'s', function()
    -- Neither native has a getter, so calling ClearOverrideWeather is not
    -- "put it back" -- it is "cancel whoever set it".
    local r = newRound()
    r.enter()
    r.fire('exitArena', {})

    t.equals(r.world.weatherCleared, 0,
        'the exit cancelled a weather override this round never set')
    t.equals(r.world.clockCleared, 0,
        'the exit cancelled a clock override this round never set')
end)

t.test('the exit takes the arena flag down BEFORE it stops the spectator camera', function()
    -- client/spectate.lua's Stop reads that flag to decide whether it may put
    -- the watcher's ped back. Stopped first, the answer is always "still in a
    -- round" and the watcher's half never runs on the way out -- which used
    -- to be covered by ReleaseDeadState writing at every ped it was handed,
    -- and is not any more.
    local r = newRound()
    r.enter()
    r.fire('exitArena', {})

    t.isFalse(r.world.inArenaWhenStopped,
        'the camera was stopped while the arena flag was still up, so a watcher '
        .. 'who never died is left invisible')
end)

os.exit(t.summary())
