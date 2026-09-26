--[[
    crimson_arena/tests/teammarker_spec.lua

    THE MARKER OVER A TEAMMATE'S HEAD, AND WHAT IT COSTS A FRAME.

    The marker is drawn every frame, from the one thread in client/match.lua
    that also carries the death backstop. It is the heaviest thing that
    thread does -- fourteen native calls for every teammate on screen, where
    the rest of the frame is about eleven -- so it is the first thing anybody
    tuning the frame will reach for. Until this file nothing ran it at all.

    WHY NOTHING DID. MARKER_NATIVES is read ONCE, when client/match.lua
    loads, from SET_DRAW_ORIGIN, CLEAR_DRAW_ORIGIN, DRAW_RECT and
    IS_ENTITY_ON_SCREEN. No other fixture stubs those four, so in every other
    spec the flag is false and drawTeamMarks returns on its first line. A
    version that raised the moment a teammate was drawn, or that marked the
    enemy team through walls, passed the whole suite.

    SO THE STUBS GO IN BEFORE THE FILE LOADS, and they live HERE rather than
    in sandbox.lua's shared defaults:

      - blipscope_spec switches a native off by setting it nil AFTER the
        load. That works for the outline technique, which is looked up when
        it is called, and it does nothing at all here -- the flag has
        already been computed. A spec written that way passes without
        testing anything, which is why the first test below asserts that a
        rectangle was really drawn.

      - Putting them in the shared defaults would quietly move every other
        spec that loads client/match.lua into a world where the marker
        draws, and move blipscope's start-up check test from one branch to
        the other. What those specs are about is not this.

    A RAISE ANYWHERE IN THE MARKER FAILS THIS SPEC. Production does not catch
    one: nothing wraps the call in the frame loop, and the comment above that
    call says the function is written so that it cannot raise. The thread
    runner re-raises whatever a captured thread throws, so a raise surfaces
    out of f.step() and fails the test that stepped -- and one test below
    proves that this is still so, because a runner that swallowed it would
    turn every other test here green over a dead backstop.

    THE BUDGETS COUNT CALLS, NOT TIME. How long 24 DRAW_RECT and 4
    GET_PED_BONE_COORDS take in a frame is only measurable in the game, with
    resmon. What a spec CAN hold is how many calls the frame makes, per
    state, and it holds them EXACTLY: a change that makes the frame cheaper
    is welcome and must say so here, on purpose, in the same commit. With
    these stubs every teammate is on screen unless a test says otherwise, so
    the numbers are the worst case.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teammarker_spec')

-- Server ids. This player is 1. A full five-a-side: four on this side, five
-- on the other. Peds are 1000 + server id unless a test remakes one.
local SELF = 1
local MATES = { 2, 5, 6, 7 }
local FOES = { 3, 4, 8, 9, 10 }

--- The natives the marker draws with, and the lookups it resolves a ped
--- through. In the arena frame nothing but drawTeamMarks calls any of these
--- -- the death path's own lookups are different natives -- so counting
--- them in that thread's calls IS counting the marker.
local MARKER_PATH = {
    GetPlayerFromServerId = true, NetworkIsPlayerActive = true,
    GetPlayerPed = true, DoesEntityExist = true,
    IsEntityOnScreen = true, GetPedBoneCoords = true,
    SetDrawOrigin = true, DrawRect = true, ClearDrawOrigin = true,
}

--- What ONE teammate on screen costs, by name. Four to turn a server id
--- back into a ped, one to ask whether it is in front of the camera, one to
--- find the head, and the draw: an origin, six rectangles, and the close.
local ON_SCREEN_COST = 'ClearDrawOrigin=1 DoesEntityExist=1 DrawRect=6 GetPedBoneCoords=1 '
    .. 'GetPlayerFromServerId=1 GetPlayerPed=1 IsEntityOnScreen=1 NetworkIsPlayerActive=1 SetDrawOrigin=1'

--- And one BEHIND the camera: the lookup and the question, nothing drawn.
local OFF_SCREEN_COST = 'DoesEntityExist=1 GetPlayerFromServerId=1 GetPlayerPed=1 '
    .. 'IsEntityOnScreen=1 NetworkIsPlayerActive=1'

--- The scoreboard as server/match.lua builds it, everybody alive.
--- @param overrides table? -- [serverId] = { alive?, team?, ... }
--- @param selfTeam string? -- this player's side; the others are the other one
local function scoreboard(overrides, selfTeam)
    local mine = selfTeam or 'crimson'
    local theirs = mine == 'crimson' and 'ash' or 'crimson'
    local rows = { { id = SELF, name = 'You', alive = true, team = mine } }
    for _, id in ipairs(MATES) do rows[#rows + 1] = { id = id, name = 'Mate ' .. id, alive = true, team = mine } end
    for _, id in ipairs(FOES) do rows[#rows + 1] = { id = id, name = 'Foe ' .. id, alive = true, team = theirs } end
    for _, row in ipairs(rows) do
        for key, value in pairs((overrides or {})[row.id] or {}) do row[key] = value end
    end
    return rows
end

--- Every teammate but the ones named, dead -- so a test can ask for exactly
--- `n` living teammates on an otherwise unchanged board.
local function livingMates(n)
    local over = {}
    for index, id in ipairs(MATES) do
        if index > n then over[id] = { alive = false } end
    end
    return scoreboard(over)
end

--- One fresh load of the real client/match.lua with every native it calls
--- in the arena frame stubbed, recorded, and attributed to the thread that
--- called it.
--- @param opts table? -- { mutate = fn(Config), without = { [native] = true }, raiseIn = native }
---   f.raiseIn can be set after the load too, to break one native from then on.
local function newFixture(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 1000 + SELF,
        clock = 100000,
        pedOf = {},        -- [serverId] = a remade ped handle
        streamed = {},     -- [serverId] = false for one this client has not got
        inactive = {},     -- [serverId] = true for one NETWORK_IS_PLAYER_ACTIVE denies
        gone = {},         -- [ped] = true for a handle that no longer exists
        offScreen = {},    -- [ped] = true for one behind the camera
        dead = false,
        printed = {},
        serverEvents = {},
        calls = {},        -- every native call this step: { name, args, co }
        arena = nil,       -- the per-frame arena thread, once it has run
        raiseIn = opts.raiseIn,  -- a native whose stub raises; a test may set it later
    }

    local function serverIdOf(player) return player == 0 and SELF or player end

    local natives = {
        PlayerPedId = function() return f.ped end,
        PlayerId = function() return 0 end,
        IsEntityDead = function() return f.dead == true end,
        -- A teammate's feet are at x = their ped, so the fallback test below
        -- can read who was marked from the draw origin, as the bone test can.
        GetEntityCoords = function(entity)
            if entity ~= f.ped and type(entity) == 'number' and entity > 1000 then
                return Sandbox.vector3(entity + 0.0, 0.0, 5.0)
            end
            return Sandbox.vector3(0.0, 0.0, 0.0)
        end,
        GetEntityHeading = function() return 0.0 end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,

        GetPlayerServerId = function(player) return serverIdOf(player) end,
        -- AN INTEGER NATIVE, AND THE STUB IS STRICT ABOUT IT. The runtime
        -- hands a Lua float to the engine as a float, and a native that
        -- reads an int cannot be relied on to read 4.75 -- or even 4.0 --
        -- as player 4. Arena.ToInt floors every id off the board before it
        -- gets here; a path that skipped it raises, in whichever thread
        -- asked, and fails whichever test was running.
        GetPlayerFromServerId = function(serverId)
            if math.type(serverId) ~= 'integer' then
                error(('GetPlayerFromServerId was given %s (%s), not an integer server id')
                    :format(tostring(serverId), math.type(serverId) or type(serverId)))
            end
            if serverId == SELF then return 0 end
            if f.streamed[serverId] == false then return -1 end
            return serverId
        end,
        NetworkIsPlayerActive = function(player)
            return player == 0 or not f.inactive[player]
        end,
        GetPlayerPed = function(player)
            local id = serverIdOf(player)
            return f.pedOf[id] or (1000 + id)
        end,
        DoesEntityExist = function(entity) return entity ~= 0 and not f.gone[entity] end,

        AddBlipForEntity = function() return 1 end,
        RemoveBlip = function() end,
        DoesBlipExist = function() return false end,
        GetBlipInfoIdEntityIndex = function() return 0 end,
        SetBlipSprite = function() end, SetBlipColour = function() end,
        SetBlipDisplay = function() end, SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,

        SetEntityDrawOutlineRenderTechnique = function() end,
        ResetEntityDrawOutlineRenderTechnique = function() end,
        GetPlayerTeam = function() return -1 end,
        SetPlayerTeam = function() end,
        NetworkSetFriendlyFireOption = function() end,
        SetCanAttackFriendly = function() end,
        SetEntityDrawOutline = function() end,
        SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function() end,

        NetworkResurrectLocalPlayer = function() f.ped = f.ped + 1 end,
        FreezeEntityPosition = function() end, GiveWeaponToPed = function() end,
        SetEntityHealth = function() end, ApplyDamageToPed = function() end,
        ClearPedBloodDamage = function() end, SetPedAmmo = function() end,
        SetPedArmour = function() end, SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end, SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end, RemoveWeaponFromPed = function() end,
        SetEntityCoordsNoOffset = function() end, SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGroundZFor_3dCoord = function() return false, nil end,
        -- A FRAME CLOCK: it moves only when a test moves it, so every read
        -- inside one frame answers the same, as the game's does.
        GetGameTimer = function() return f.clock end,
        DisableControlAction = function() end, DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end, SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 0 end,
        IsEntityAPed = function() return true end, IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 0 end,
        SetWeatherTypeNowPersist = function() end, NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end, NetworkClearClockTimeOverride = function() end,

        -- THE FIVE THE MARKER DRAWS WITH.
        IsEntityOnScreen = function(ped) return not f.offScreen[ped] end,
        -- x IS THE PED, so an assertion about who was marked reads directly.
        GetPedBoneCoords = function(ped) return Sandbox.vector3(ped + 0.0, 0.0, 10.0) end,
        SetDrawOrigin = function() end,
        ClearDrawOrigin = function() end,
        DrawRect = function() end,
    }

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        vector3 = Sandbox.vector3,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        print = function(line) f.printed[#f.printed + 1] = tostring(line) end,
        -- IN THE SAME LOG AS THE NATIVES, marked as an event, so a test can
        -- ask what the frame did FIRST -- and never counted as a native.
        TriggerServerEvent = function(name, payload)
            f.serverEvents[#f.serverEvents + 1] = { name = name, payload = payload }
            f.calls[#f.calls + 1] = { name = 'event:' .. tostring(name), args = { payload }, co = coroutine.running() }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        lib = { notify = function() end },
        joaat = function(name) return name end,
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        ArenaDispatch = {
            Enter = function() end, Exit = function() end,
            ReleaseDeadState = function() end,
            ClearDeadState = function() return true end,
        },
    }

    for name, fn in pairs(natives) do
        overrides[name] = function(...)
            local co = coroutine.running()
            -- THE ARENA FRAME IS THE THREAD THAT HOLDS THE PAUSE MENU SHUT.
            -- Nothing else in the file asks for control 199, so the first
            -- thread that does is the one being measured.
            if name == 'DisableControlAction' and select(2, ...) == 199 and f.arena ~= co then
                f.arena = co
                f.arenaThreads = (f.arenaThreads or 0) + 1
            end
            f.calls[#f.calls + 1] = { name = name, args = { ... }, co = co }
            if name == f.raiseIn then error('the ' .. name .. ' stub raised, as a broken marker would') end
            return fn(...)
        end
    end

    -- LEFT OUT BEFORE THE LOAD, which is the only moment it can matter.
    for name in pairs(opts.without or {}) do overrides[name] = false end
    local env = Sandbox.newArenaEnv(overrides)
    for name in pairs(opts.without or {}) do env[name] = nil end

    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    f.env = env
    f.runner = runner

    --- One frame: every captured thread resumed once, and the arena
    --- thread's own calls handed back in the order it made them.
    function f.step()
        f.calls = {}
        runner.step()
        local frame = {}
        for _, call in ipairs(f.calls) do
            if f.arena ~= nil and call.co == f.arena then frame[#frame + 1] = call end
        end
        return frame
    end

    function f.fire(name, payload)
        local handler = handlers[name]
        if not handler then error('client/match.lua registered no handler for ' .. name) end
        handler(payload)
    end

    function f.hud(rows, matchId)
        f.fire('crimson_arena:client:matchHud', {
            visible = true, scoreboard = rows or scoreboard(), matchId = matchId or f.matchId,
        })
    end

    --- Into the arena, still counting down. No matchLive, so no blip loop.
    function f.enter(over)
        local payload = {
            matchId = 'match-1', modeKey = 'tdm', teamKey = 'crimson',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 0.0 },
            scatterRadius = 0.0, freezeSeconds = 0, radar = false,
            loadout = { weapons = {}, health = 200, armor = 0 },
        }
        for key, value in pairs(over or {}) do payload[key] = value end
        f.matchId = payload.matchId
        f.fire('crimson_arena:client:enterArena', payload)
    end

    function f.enterLive(over)
        f.enter(over)
        f.fire('crimson_arena:client:matchLive', { matchId = f.matchId })
    end

    --- Which server id a draw origin was opened over. The bone stub puts x
    --- at the ped, so this reads a remade ped back to its player too.
    function f.serverIdAt(x)
        local ped = math.floor(x)
        for id, remade in pairs(f.pedOf) do
            if remade == ped then return id end
        end
        return ped - 1000
    end

    function f.console() return table.concat(f.printed, '\n') end
    return f
end

local function named(frame, name)
    local out = {}
    for _, call in ipairs(frame) do
        if call.name == name then out[#out + 1] = call end
    end
    return out
end

--- The natives in a frame, counted by name and sorted, so a failure says
--- WHICH one moved rather than only that the total did. Events are not
--- natives and are left out.
--- @param only table? -- a set of names to keep; every native when nil
local function breakdown(frame, only)
    local by, total = {}, 0
    for _, call in ipairs(frame) do
        if not call.name:find('^event:') and (only == nil or only[call.name]) then
            by[call.name] = (by[call.name] or 0) + 1
            total = total + 1
        end
    end
    local keys = {}
    for name, n in pairs(by) do keys[#keys + 1] = name .. '=' .. n end
    table.sort(keys)
    return table.concat(keys, ' '), total
end

local function nativeCount(frame, only)
    local _, total = breakdown(frame, only)
    return total
end

--- Which players got a marker this frame, as a sorted list of server ids.
local function marked(f, frame)
    local ids = {}
    for _, call in ipairs(named(frame, 'SetDrawOrigin')) do ids[#ids + 1] = f.serverIdAt(call.args[1]) end
    table.sort(ids)
    return table.concat(ids, ',')
end

local function sortedIds(list)
    local copy = {}
    for index, id in ipairs(list) do copy[index] = id end
    table.sort(copy)
    return table.concat(copy, ',')
end

local ALL_MATES = sortedIds(MATES)

--- Live, the board delivered, and three frames run so the blip loop has
--- taken the outline and everything is in its steady state. Returns the
--- fourth frame.
local function live(f, rows, over)
    f.enterLive(over)
    f.hud(rows)
    f.step(); f.step(); f.step()
    return f.step()
end

--- THE PLATE'S MARGIN, the one piece of the marker's geometry held as a
--- number: MARKER_EDGE_X on each side (so twice over the width) and
--- MARKER_EDGE_Y once over the height, on every row alike. The comment over
--- those two says why they differ -- DrawRect measures a width against the
--- screen's width and a height against its height -- so they are pinned
--- here as a pair. The rows themselves are held by what the comment over
--- MARKER_ROWS promises of them (below), not by their numbers: a re-sized
--- arrow is a design change, a plate that frames one row and not the next
--- is a defect. A re-tuned margin changes these two here, on purpose.
local PLATE_MARGIN_W = 0.0016 * 2.0
local PLATE_MARGIN_H = 0.0028

--- Asserts the shape every marker must have, on every frame it is drawn:
--- an origin opened, six rectangles, the origin closed, nothing drawn with
--- no origin open, and no origin left open at the end of the frame.
--- @return integer markers -- how many were drawn
local function assertWellFormed(frame, expectRgb)
    local open, rects, markers, seq = false, 0, 0, {}
    for _, call in ipairs(frame) do
        if call.name == 'SetDrawOrigin' then
            t.isFalse(open, 'a draw origin was opened while another was still open')
            open, rects, seq = true, 0, {}
        elseif call.name == 'DrawRect' then
            t.isTrue(open, 'a DrawRect was issued with no draw origin open')
            rects = rects + 1
            seq[#seq + 1] = call.args
        elseif call.name == 'ClearDrawOrigin' then
            t.isTrue(open, 'ClearDrawOrigin was called with nothing open')
            t.equals(rects, 6, 'a marker is six rectangles')
            -- THE DARK PLATE FIRST, then the colour over it -- so a plate
            -- can never land on top of the row it sits behind.
            for i = 1, 3 do
                t.equals(('%d,%d,%d,%d'):format(seq[i][5], seq[i][6], seq[i][7], seq[i][8]), '0,0,0,190',
                    'rectangle ' .. i .. ' is not the dark plate')
            end
            for i = 4, 6 do
                t.equals(('%d,%d,%d,%d'):format(seq[i][5], seq[i][6], seq[i][7], seq[i][8]), expectRgb .. ',255',
                    'rectangle ' .. i .. ' is not the team colour')
            end
            -- EACH PLATE SITS BEHIND ITS OWN ROW: same centre, and larger by
            -- THE SAME MARGIN on every row, so each row is framed evenly
            -- rather than covered, or framed on one row and not the next.
            for i = 1, 3 do
                local plate, row = seq[i], seq[i + 3]
                t.equals(plate[1], row[1], 'plate ' .. i .. ' is not centred on its row (x)')
                t.equals(plate[2], row[2], 'plate ' .. i .. ' is not centred on its row (y)')
                t.isTrue(math.abs((plate[3] - row[3]) - PLATE_MARGIN_W) < 1e-9,
                    ('plate %d is %.6f wider than its row, not %.4f'):format(i, plate[3] - row[3], PLATE_MARGIN_W))
                t.isTrue(math.abs((plate[4] - row[4]) - PLATE_MARGIN_H) < 1e-9,
                    ('plate %d is %.6f taller than its row, not %.4f'):format(i, plate[4] - row[4], PLATE_MARGIN_H))
            end
            -- CENTRED OVER THE HEAD, and THE POINT ON THE ORIGIN: the draw
            -- origin is MARKER_LIFT above the head, and that lift is where
            -- the point is meant to sit -- a bottom row off the origin moves
            -- the whole arrow off the height the lift was chosen for.
            for i = 1, 6 do t.equals(seq[i][1], 0.0, 'rectangle ' .. i .. ' is not centred over the head') end
            t.equals(seq[4][2], 0.0, 'the point of the arrow is not on the draw origin')
            -- AN ARROW AIMED AT THE HEAD: widest at the top, a point at the
            -- bottom, every row the same height, and EVERY PAIR of rows
            -- overlapping so it reads as one shape. A gap anywhere -- not
            -- only between the first two -- is "three separated bars", which
            -- the comment over MARKER_ROWS says is three bars.
            t.isTrue(seq[4][3] < seq[5][3] and seq[5][3] < seq[6][3], 'the rows do not widen upwards')
            t.isTrue(seq[4][2] > seq[5][2] and seq[5][2] > seq[6][2], 'the rows are not stacked upwards')
            t.isTrue(seq[4][4] == seq[5][4] and seq[5][4] == seq[6][4], 'the rows are not one height')
            for i = 4, 5 do
                t.isTrue(seq[i][2] - seq[i + 1][2] < seq[i][4],
                    ('rows %d and %d are separate bars, not one arrow'):format(i - 3, i - 2))
            end
            open = false
            markers = markers + 1
        end
    end
    t.isFalse(open, 'the frame ended with a draw origin still open')
    t.equals(#named(frame, 'SetDrawOrigin'), #named(frame, 'ClearDrawOrigin'), 'unbalanced draw origins')
    return markers
end

-- ======================================================================
-- THE FIXTURE ITSELF, BEFORE ANYTHING IS BELIEVED
-- ======================================================================

t.test('the fixture really does switch the marker on (else everything below is vacuous)', function()
    local f = newFixture()
    local frame = live(f)
    t.isTrue(#named(frame, 'DrawRect') >= 1, 'MARKER_NATIVES stayed false: no DrawRect was ever called')
end)

t.test('and it measures ONE thread, one frame per step', function()
    local f = newFixture()
    live(f)
    t.equals(f.arenaThreads, 1, 'more than one thread asked for the pause menu')
    for _ = 1, 5 do
        local frame = f.step()
        local pause = 0
        for _, call in ipairs(named(frame, 'DisableControlAction')) do
            if call.args[2] == 199 then pause = pause + 1 end
        end
        t.equals(pause, 1, 'a step ran the arena frame other than exactly once')
    end
end)

t.test('A RAISE IN THE MARKER FAILS THE STEP -- the runner does not swallow it', function()
    -- The proof every other test here leans on. If the runner, or a pcall
    -- added round the call in production, ate this, a marker that threw on
    -- every frame would pass this whole file with the backstop dead. A
    -- pcall in the frame loop is an owner's decision, and taking it means
    -- changing this test on purpose.
    for _, native in ipairs({ 'DrawRect', 'SetDrawOrigin', 'IsEntityOnScreen', 'GetPedBoneCoords', 'ClearDrawOrigin' }) do
        local f = newFixture({ raiseIn = native })
        f.enterLive()
        f.hud()
        local ok, err = pcall(f.step)
        t.isFalse(ok, native .. ': a raise inside the marker passed the step')
        t.contains(tostring(err), 'captured thread errored', native)
        t.contains(tostring(err), 'the ' .. native .. ' stub raised', native)
    end
end)

-- ======================================================================
-- WHO IS MARKED
-- ======================================================================

t.test('living teammates are marked, and nobody else -- not self, not an enemy', function()
    local f = newFixture()
    local frame = live(f)
    t.equals(marked(f, frame), ALL_MATES, 'the wrong players carry a marker')
end)

t.test('A SIDE OF ANY SIZE: fifteen teammates, and thirty-one, every one marked, fourteen natives each', function()
    -- Config.Teams.maxTeamSize = 0 is "no cap", and Config.Match.maxPlayers
    -- = 0 is the same, so the marker has no cap either. A limit on the list
    -- -- the first saving anybody tuning this frame reaches for -- would
    -- leave the ninth teammate on a big server unmarked, and every other
    -- fixed board in this file is a five-a-side that could not see it.
    for _, n in ipairs({ 15, 31 }) do
        local f = newFixture()
        local rows, want = { { id = SELF, alive = true, team = 'crimson' } }, {}
        for index = 1, n do
            rows[#rows + 1] = { id = 100 + index, alive = true, team = 'crimson' }
            want[#want + 1] = 100 + index
        end
        for index = 1, 6 do rows[#rows + 1] = { id = 200 + index, alive = true, team = 'ash' } end
        local frame = live(f, rows)
        t.equals(marked(f, frame), sortedIds(want), n .. ' teammates: the wrong players carry a marker')
        t.equals(nativeCount(frame, MARKER_PATH), 14 * n, n .. ' teammates: what the marker cost')
        t.equals(assertWellFormed(frame, '255,34,51'), n, n .. ' teammates: not one marker each')
    end
end)

t.test('the other side sees its own side, never this one', function()
    local f = newFixture()
    -- The same board, read by a fighter on 'ash': their teammates are the
    -- five FOES, and the four crimson players are the enemy.
    local rows = scoreboard()
    for _, row in ipairs(rows) do
        if row.id == SELF then row.team = 'ash' end
    end
    local frame = live(f, rows, { teamKey = 'ash' })
    t.equals(marked(f, frame), sortedIds(FOES), 'an ash fighter marked the wrong side')
    t.equals(assertWellFormed(frame, '42,166,255'), #FOES, 'not one marker per ash teammate')
end)

t.test('a dead teammate is not marked, and is marked again on the very next frame the board says alive', function()
    local f = newFixture()
    local frame = live(f, scoreboard({ [MATES[1]] = { alive = false } }))
    t.equals(marked(f, frame), sortedIds({ MATES[2], MATES[3], MATES[4] }), 'a dead teammate was marked')

    -- THE NEXT FRAME, not the blip loop's next pass: the arena thread runs
    -- before the blip loop in a step, so only the board's own refresh can
    -- have put the teammate back by then.
    f.hud(scoreboard())
    t.equals(marked(f, f.step()), ALL_MATES, 'the respawned teammate was not marked on the next frame')

    f.hud(scoreboard({ [MATES[2]] = { alive = false } }))
    t.equals(marked(f, f.step()), sortedIds({ MATES[1], MATES[3], MATES[4] }),
        'a teammate who just died was still marked on the next frame')
end)

t.test('the board refreshes the marker even with the scoreboard panel switched off', function()
    -- The refresh sits ABOVE the showMatchHud return in the handler. Moved
    -- below it, switching off a panel would also switch off the marker --
    -- and the blip loop would hide it by catching up a frame later.
    local f = newFixture({ mutate = function(c) c.UI.showMatchHud = false end })
    live(f)
    f.hud(scoreboard({ [MATES[1]] = { alive = false } }))
    t.equals(marked(f, f.step()), sortedIds({ MATES[2], MATES[3], MATES[4] }),
        'with the panel off, a death did not reach the marker on the next frame')
end)

t.test('a board for another match changes nothing', function()
    local f = newFixture()
    live(f)
    local everyoneDead = {}
    for _, id in ipairs(MATES) do everyoneDead[id] = { alive = false } end
    f.hud(scoreboard(everyoneDead), 'match-other')
    t.equals(marked(f, f.step()), ALL_MATES, 'a board from another round moved the marker')
end)

t.test('free-for-all and gun game mark nobody, even with a teamKey on the payload', function()
    for _, mode in ipairs({ 'ffa', 'gungame' }) do
        local f = newFixture()
        f.enterLive({ modeKey = mode, teamKey = 'crimson' })
        f.hud()
        for _ = 1, 4 do
            local frame = f.step()
            t.equals(nativeCount(frame, MARKER_PATH), 0, mode .. ' spent a native on the marker')
        end
    end
end)

t.test('showTeamMarker must be exactly true: false, nil and a truthy string all draw nothing', function()
    for _, value in ipairs({ false, 'nil', 'true', 1 }) do
        local f = newFixture({ mutate = function(c)
            if value == 'nil' then c.Teams.showTeamMarker = nil else c.Teams.showTeamMarker = value end
        end })
        local frame = live(f)
        t.equals(nativeCount(frame, MARKER_PATH), 0, 'showTeamMarker = ' .. tostring(value) .. ' drew')
    end
end)

t.test('a side with no readable colour marks nobody rather than marking in some other colour', function()
    for _, colour in ipairs({ 'not-a-colour', '#12345', 42, false }) do
        local f = newFixture({ mutate = function(c) c.Teams.list.crimson.color = colour end })
        local frame = live(f)
        t.equals(nativeCount(frame, MARKER_PATH), 0, 'colour ' .. tostring(colour) .. ' still drew')
    end
end)

t.test('a round with no side of its own marks nobody', function()
    for _, teamKey in ipairs({ false, '', 'no-such-side' }) do
        local f = newFixture()
        local rows = scoreboard()
        local frame = live(f, rows, { teamKey = teamKey })
        t.equals(nativeCount(frame, MARKER_PATH), 0, 'teamKey ' .. tostring(teamKey) .. ' drew')
    end
end)

t.test('an empty board, or none at all, costs the marker nothing', function()
    local f = newFixture()
    local frame = live(f, {})
    t.equals(nativeCount(frame, MARKER_PATH), 0, 'an empty board spent natives')

    f.fire('crimson_arena:client:matchHud', { visible = true, matchId = f.matchId, scoreboard = 'garbage' })
    t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'a board that is not a table spent natives')
    f.fire('crimson_arena:client:matchHud', 'garbage')
    t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'a payload that is not a table spent natives')
end)

t.test('garbage rows are passed over; an id sent as a string or a fraction reaches the native as an integer', function()
    local f = newFixture()
    local rows = {
        { id = SELF, alive = true, team = 'crimson' },
        'not a row', 42, false,
        { id = nil, alive = true, team = 'crimson' },
        { id = 'x', alive = true, team = 'crimson' },
        { id = 0 / 0, alive = true, team = 'crimson' },
        { id = math.huge, alive = true, team = 'crimson' },
        { id = MATES[1], alive = 'true', team = 'crimson' },   -- alive must be exactly true
        { id = MATES[2], alive = 1, team = 'crimson' },
        { id = MATES[3], alive = true, team = nil },
        { id = MATES[4], alive = true, team = 'CRIMSON' },
        { id = tostring(FOES[1]), alive = true, team = 'crimson' },  -- server ids arrive as numbers; a string is read
        { id = FOES[2] + 0.75, alive = true, team = 'crimson' },     -- and a fraction is floored, as Arena.ToInt does
        { id = tostring(SELF), alive = true, team = 'crimson' },    -- which must still not make it this player
        { id = SELF + 0.5, alive = true, team = 'crimson' },         -- nor may a fraction of this player's id
    }
    local frame = live(f, rows)
    t.equals(marked(f, frame), sortedIds({ FOES[1], FOES[2] }), 'garbage rows were read wrongly')
    t.equals(assertWellFormed(frame, '255,34,51'), 2, 'the valid rows were not both drawn')

    -- FLOORED BEFORE THE NATIVE, NOT AFTER. The stub raises on a float, so
    -- reaching here already says so; this says WHICH ids were asked about,
    -- and that the string and the fraction arrived as the integers they
    -- stand for. `marked` cannot tell: it floors the draw origin itself when
    -- it reads the player back from it.
    local asked = {}
    for _, call in ipairs(named(frame, 'GetPlayerFromServerId')) do
        t.equals(math.type(call.args[1]), 'integer', 'a server id reached the native as ' .. tostring(call.args[1]))
        asked[#asked + 1] = call.args[1]
    end
    t.equals(sortedIds(asked), sortedIds({ FOES[1], FOES[2] }), 'the native was asked about the wrong ids')
end)

-- ======================================================================
-- WHERE AND HOW IT IS DRAWN
-- ======================================================================

t.test('a teammate behind the camera is asked about and skipped', function()
    local f = newFixture()
    f.offScreen[1000 + MATES[1]] = true
    local frame = live(f)
    t.equals(marked(f, frame), sortedIds({ MATES[2], MATES[3], MATES[4] }), 'an off-screen teammate got a draw origin')
    t.equals(#named(frame, 'IsEntityOnScreen'), #MATES, 'every teammate should have been asked about')
    for _, call in ipairs(named(frame, 'GetPedBoneCoords')) do
        t.isTrue(call.args[1] ~= 1000 + MATES[1], 'the head of an off-screen teammate was looked up')
    end
end)

t.test('a teammate who cannot be turned into a ped is skipped without a raise, and never asked about', function()
    -- The four ways pedForServerId gives up, one teammate each.
    local f = newFixture()
    f.streamed[MATES[1]] = false          -- not streamed to this client
    f.inactive[MATES[2]] = true           -- not an active network player
    f.pedOf[MATES[3]] = 0                 -- no ped
    f.gone[1000 + MATES[4]] = true        -- a ped handle that no longer exists
    local frame = live(f)
    t.equals(marked(f, frame), '', 'an unresolvable teammate was marked')
    t.equals(#named(frame, 'IsEntityOnScreen'), 0, 'a teammate with no ped was asked about the screen')
    -- The lookups stop where each one fails: 1 + 2 + 3 + 4.
    t.equals(nativeCount(frame, MARKER_PATH), 10, 'the lookups did not stop where they failed')
end)

t.test('a remade ped is followed on the next frame', function()
    local f = newFixture()
    live(f)
    f.pedOf[MATES[1]] = 7002
    local frame = f.step()
    local xs = {}
    for _, call in ipairs(named(frame, 'SetDrawOrigin')) do xs[#xs + 1] = math.floor(call.args[1]) end
    table.sort(xs)
    local want = { 7002 }
    for index = 2, #MATES do want[#want + 1] = 1000 + MATES[index] end
    t.equals(table.concat(xs, ','), sortedIds(want), 'the marker did not follow the new ped handle')

    -- And back again, which a cache keyed on the first handle would miss.
    f.pedOf[MATES[1]] = nil
    t.equals(marked(f, f.step()), ALL_MATES, 'the marker did not follow the ped back')
end)

t.test('the marker sits over the HEAD bone, lifted, with the origin flag the engine wants', function()
    local f = newFixture()
    local frame = live(f)
    for _, call in ipairs(named(frame, 'GetPedBoneCoords')) do
        t.equals(call.args[2], 31086, 'not SKEL_Head')
        t.equals(call.args[3] .. ',' .. call.args[4] .. ',' .. call.args[5], '0.0,0.0,0.0', 'the bone was offset')
    end
    for _, call in ipairs(named(frame, 'SetDrawOrigin')) do
        t.equals(call.args[2], 0.0, 'y moved off the bone')
        t.isTrue(math.abs(call.args[3] - 10.42) < 1e-9, 'not 0.42m above the head bone: ' .. tostring(call.args[3]))
        t.equals(call.args[4], 0, 'the fourth argument changed')
    end
end)

t.test('a build without GET_PED_BONE_COORDS marks from the feet instead, and still draws', function()
    local f = newFixture({ without = { GetPedBoneCoords = true } })
    local frame = live(f)
    t.equals(marked(f, frame), ALL_MATES, 'the fallback marked the wrong players')
    for _, call in ipairs(named(frame, 'SetDrawOrigin')) do
        t.isTrue(math.abs(call.args[3] - 6.32) < 1e-9, 'not 1.32m above the feet: ' .. tostring(call.args[3]))
    end
    assertWellFormed(frame, '255,34,51')
end)

t.test('every draw origin is closed, six rects inside it, plates before colour', function()
    local f = newFixture()
    local frame = live(f)
    t.equals(assertWellFormed(frame, '255,34,51'), #MATES, 'expected one closed marker per on-screen teammate')
end)

-- ======================================================================
-- WHEN IT STOPS
-- ======================================================================

t.test('nothing is drawn once the player leaves the arena, and the frame thread ends', function()
    local f = newFixture()
    live(f)
    local thread = f.arena
    f.fire('crimson_arena:client:exitArena', {})
    for _ = 1, 5 do
        local frame = f.step()
        t.equals(#frame, 0, 'the arena frame outlived the match')
    end
    t.equals(coroutine.status(thread), 'dead', 'the arena thread is still running')
end)

t.test('nor after the resource stops', function()
    local f = newFixture()
    live(f)
    f.fire('onResourceStop', 'crimson_arena')
    for _ = 1, 3 do
        t.equals(#f.step(), 0, 'the arena frame outlived the resource')
    end
end)

t.test('the countdown marks teammates once a board arrives, and not before', function()
    local f = newFixture()
    f.enter()
    for _ = 1, 3 do t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'marked before any board arrived') end
    f.hud()
    t.equals(marked(f, f.step()), ALL_MATES, 'the countdown did not mark from its board')
end)

t.test('LAST ROUND\'S SIDE IS NOT MARKED IN THE NEXT COUNTDOWN', function()
    -- Round one was on crimson, with a board. Round two is on ash and no
    -- board has come yet. A marker list that outlived the exit would draw
    -- round one's allies -- now possibly enemies -- through the walls of
    -- round two's countdown.
    local f = newFixture()
    f.enter()
    f.hud()
    t.equals(marked(f, f.step()), ALL_MATES, 'the control: round one was not marked')
    f.fire('crimson_arena:client:exitArena', {})
    f.enter({ matchId = 'match-2', teamKey = 'ash' })
    for _ = 1, 4 do
        t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'round one\'s marker was drawn in round two')
    end
end)

t.test('and a live round replaced without an exit takes its marker with its blip loop', function()
    -- The blip loop ends when its round does and clears the list on its way
    -- out. Stepped here, that happens before the new round's frame runs;
    -- in the game the old loop may sleep up to a second first, which is why
    -- the first frame is not asserted on. What must never happen is the
    -- stale list surviving the old loop.
    local f = newFixture()
    live(f)
    f.enter({ matchId = 'match-2', teamKey = 'ash' })
    f.step()
    for _ = 1, 4 do
        t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'the old round\'s marker survived its blip loop')
    end
end)

t.test('the blip loop re-reads the rules on its own pass, with no board', function()
    -- The loop is the marker's SECOND source: a mid-round change reaches
    -- the marker from there even if no scoreboard ever arrives again.
    local f = newFixture()
    live(f)
    f.env.Config.Teams.showTeamMarker = false
    f.step()
    t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'the blip loop did not refresh the marker')
    f.env.Config.Teams.showTeamMarker = true
    f.step()
    t.equals(marked(f, f.step()), ALL_MATES, 'and it did not bring it back either')
end)

t.test('A PASS WHOSE OUTLINE RAISES HAS ALREADY REFRESHED THE MARKER -- the order in the blip loop', function()
    -- The loop refreshes the marker BEFORE the outline, on purpose (see the
    -- comment at the top of it): two answers that must not fail together.
    -- Swapped, a raise in the outline takes the marker's refresh with it.
    -- Here the rules change with no board to carry the change, and the
    -- outline raises on the very pass that must pass it on.
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.env.Config.Teams.showTeamMarker = false
    f.raiseIn = 'SetEntityDrawOutline'     -- called by refreshOutlines, never by the arena frame
    local ok, err = pcall(f.step)
    t.isFalse(ok, 'the outline did not raise, so this proves nothing')
    t.contains(tostring(err), 'the SetEntityDrawOutline stub raised', 'something else raised')
    f.raiseIn = nil
    for _ = 1, 3 do
        t.equals(nativeCount(f.step(), MARKER_PATH), 0,
            'the pass that raised in the outline had not refreshed the marker first')
    end
end)

t.test('and the radar\'s sweep refreshes the marker in its lit half and all through its dark one', function()
    -- A round with the radar on spends almost all of its time inside the
    -- sweep: a lit half, then some thirty seconds of dark in 500 ms steps.
    -- The marker is refreshed at the end of the lit half and on every dark
    -- step; without those, a change of rules would wait out the whole cycle.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()
    -- The first pass: refreshed at the top, then the sweep lights and waits.
    t.equals(marked(f, f.step()), ALL_MATES, 'the control: the round was not marked')
    -- AND IT REALLY IS THE SWEEP: an enemy was lit on that pass, which only
    -- the radar's lit half does with showEnemyBlips off. Without it every
    -- pass is the plain branch, refreshed at the top, and nothing below
    -- would be testing the sweep at all.
    local litEnemy = false
    for _, call in ipairs(f.calls) do
        if call.name == 'AddBlipForEntity' and call.args[1] == 1000 + FOES[1] then litEnemy = true end
    end
    t.isTrue(litEnemy, 'the control: the radar did not sweep, so this proves nothing')

    -- THE LIT HALF ENDS on the next pass. This frame is drawn before it.
    f.env.Config.Teams.showTeamMarker = false
    t.equals(marked(f, f.step()), ALL_MATES, 'the frame before the lit half ended changed already')
    t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'the end of the lit half did not refresh the marker')

    -- THE DARK HALF, a step at a time: each one refreshes.
    for round = 1, 3 do
        f.env.Config.Teams.showTeamMarker = true
        f.step()
        t.equals(marked(f, f.step()), ALL_MATES, 'dark step ' .. round .. ': the marker did not come back')
        f.env.Config.Teams.showTeamMarker = false
        f.step()
        t.equals(nativeCount(f.step(), MARKER_PATH), 0, 'dark step ' .. round .. ': the marker did not go')
    end
end)

-- ======================================================================
-- THE DEATH BACKSTOP IN THE SAME THREAD
-- ======================================================================

t.test('a death on a frame that draws markers is still reported, BEFORE the marker is drawn', function()
    local f = newFixture()
    live(f)
    f.dead = true
    local frame = f.step()
    local reportAt, firstOrigin
    for index, call in ipairs(frame) do
        if call.name == 'event:crimson_arena:server:reportDeath' and not reportAt then reportAt = index end
        if call.name == 'SetDrawOrigin' and not firstOrigin then firstOrigin = index end
    end
    t.isNotNil(reportAt, 'a death on a frame that drew markers was not reported')
    t.isNotNil(firstOrigin, 'the death frame drew no marker, so this proves nothing')
    t.isTrue(reportAt < firstOrigin, 'the marker ran before the death backstop in the frame')

    -- And the thread goes on: the next frame still draws, and does not
    -- report the same death twice.
    local after = f.step()
    t.equals(marked(f, after), ALL_MATES, 'the marker stopped after the death')
    local reports = 0
    for _, ev in ipairs(f.serverEvents) do
        if ev.name == 'crimson_arena:server:reportDeath' then reports = reports + 1 end
    end
    t.equals(reports, 1, 'the death was reported other than once')
end)

t.test('and after a long run of marker frames the backstop is still alive', function()
    local f = newFixture()
    live(f)
    for _ = 1, 300 do f.step() end
    f.dead = true
    f.step()
    local reported = false
    for _, ev in ipairs(f.serverEvents) do
        if ev.name == 'crimson_arena:server:reportDeath' then reported = true end
    end
    t.isTrue(reported, 'three hundred marker frames later a death went unreported')
end)

-- ======================================================================
-- A BUILD MISSING A DRAW NATIVE
-- ======================================================================

t.test('a build missing any one of the four draw natives draws nothing, raises nothing, and says so', function()
    for _, native in ipairs({ 'SetDrawOrigin', 'ClearDrawOrigin', 'DrawRect', 'IsEntityOnScreen' }) do
        local f = newFixture({ without = { [native] = true } })
        for _, frame in ipairs({ live(f), f.step(), f.step() }) do
            t.equals(nativeCount(frame, MARKER_PATH), 0, native .. ' missing: the marker still spent natives')
        end
        t.contains(f.console(), 'THE TEAMMATE MARKER CANNOT DRAW', native .. ' missing was not reported')
        local told = false
        for _, ev in ipairs(f.serverEvents) do
            if ev.name == 'crimson_arena:server:outlineReason'
                and tostring(ev.payload):find('OVERHEAD TEAMMATE MARKER', 1, true)
            then
                told = true
            end
        end
        t.isTrue(told, native .. ' missing was not reported to the server')
    end
end)

t.test('with every native present the start-up check does not nag', function()
    local f = newFixture()
    live(f)
    for _ = 1, 3 do f.step() end
    t.notContains(f.console(), 'CANNOT DRAW', 'nagged a healthy build')
    -- The outline sends its own running reasons on the same event; what
    -- must not go is the start-up check's line about the marker.
    for _, ev in ipairs(f.serverEvents) do
        if ev.name == 'crimson_arena:server:outlineReason' then
            t.notContains(tostring(ev.payload), 'MARKER', 'reported a healthy build to the server')
        end
    end
end)

-- ======================================================================
-- WHAT IT COSTS
--
-- Counted on the arena thread alone, in natives, by name. See the header:
-- these are calls, not milliseconds, and they are held exactly.
-- ======================================================================

t.test('BUDGET: each teammate on screen costs exactly 14 natives, and these 14', function()
    -- The rest of the frame is the same for one teammate as for four: the
    -- marker is the only part that scales. (With none alive there is no
    -- outline up either, so nothing is held; that frame is pinned below.)
    local rest
    for n = 0, #MATES do
        local f = newFixture()
        local frame = live(f, livingMates(n))
        local cost = nativeCount(frame, MARKER_PATH)
        t.equals(cost, 14 * n, n .. ' teammates on screen')
        local other = nativeCount(frame) - cost
        if n == 1 then rest = other end
        if n > 1 then t.equals(other, rest, n .. ' teammates: the rest of the frame moved') end
    end

    local f = newFixture()
    local frame = live(f, livingMates(1))
    t.equals((breakdown(frame, MARKER_PATH)), ON_SCREEN_COST, 'one teammate on screen')
end)

t.test('BUDGET: each teammate off screen costs exactly 5, and draws nothing', function()
    for n = 1, #MATES do
        local f = newFixture()
        for index = 1, n do f.offScreen[1000 + MATES[index]] = true end
        local frame = live(f)
        t.equals(nativeCount(frame, MARKER_PATH), 5 * n + 14 * (#MATES - n), n .. ' of them off screen')
    end
    local f = newFixture()
    f.offScreen[1000 + MATES[1]] = true
    local frame = live(f, livingMates(1))
    t.equals((breakdown(frame, MARKER_PATH)), OFF_SCREEN_COST, 'one teammate off screen')
end)

t.test('BUDGET: a free-for-all spends nothing on the marker, frame after frame', function()
    for _, mode in ipairs({ 'ffa', 'gungame' }) do
        local f = newFixture()
        live(f, nil, { modeKey = mode })
        for _ = 1, 10 do
            t.equals(nativeCount(f.step(), MARKER_PATH), 0, mode)
        end
    end
end)

--- THE WHOLE ARENA FRAME, per state, on a five-a-side with all four
--- teammates on screen. Measured on this code and held exactly.
---
--- The states differ in what the loop holds or checks: the firing block
--- while dead or counting down, the vitals re-assert for 1.5 s after a
--- respawn, the floor check every 2 s, and the outline hold while an
--- outline is up.
---
--- The clock is read once a frame in every one of them: the vitals window
--- and the floor check share that read (frameclock_spec says why that is
--- safe). They each read it for themselves once, and the repair frame, the
--- vitals window and every frame after it cost one more here.
---
--- THERE IS NO HEADROOM IN THESE, ON PURPOSE. A native legitimately added
--- to this loop turns one of them red, and the fix is to change the number
--- here in the same commit and say why -- which is the whole of what a
--- budget is for. A change that makes a frame cheaper does the same.
local FRAME_STATES = {
    {
        name = 'live and alive, no vitals window yet, not a repair frame',
        want = 67,
        byName = 'ClearDrawOrigin=4 DisableControlAction=4 DoesEntityExist=4 DrawRect=24 GetGameTimer=1 '
            .. 'GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 IsEntityOnScreen=4 '
            .. 'IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerPedId=1 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f) live(f); return f.step() end,
    },
    {
        name = 'the floor-repair frame, every two seconds',
        want = 67,
        byName = 'ClearDrawOrigin=4 DisableControlAction=4 DoesEntityExist=4 DrawRect=24 GetGameTimer=1 '
            .. 'GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 IsEntityOnScreen=4 '
            .. 'IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerPedId=1 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f) live(f); f.clock = f.clock + 2000; return f.step() end,
    },
    {
        name = 'inside the 1.5 s vitals window after a respawn',
        want = 70,
        byName = 'ClearDrawOrigin=4 DisableControlAction=4 DoesEntityExist=4 DrawRect=24 GetGameTimer=1 '
            .. 'GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 IsEntityOnScreen=4 '
            .. 'IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerPedId=2 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1 '
            .. 'SetEntityHealth=1 SetPedArmour=1',
        run = function(f)
            live(f)
            f.fire('crimson_arena:client:holdVitals')
            f.clock = f.clock + 1000
            return f.step()
        end,
    },
    {
        name = 'after a vitals window has run out, not a repair frame',
        want = 67,
        byName = 'ClearDrawOrigin=4 DisableControlAction=4 DoesEntityExist=4 DrawRect=24 GetGameTimer=1 '
            .. 'GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 IsEntityOnScreen=4 '
            .. 'IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerPedId=1 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f)
            live(f)
            f.fire('crimson_arena:client:holdVitals')
            f.clock = f.clock + 1600
            return f.step()
        end,
    },
    {
        name = 'the frame a death is reported in',
        want = 68,
        byName = 'ClearDrawOrigin=4 DisableControlAction=4 DoesEntityExist=4 DrawRect=24 GetGameTimer=1 '
            .. 'GetPedBoneCoords=4 GetPedSourceOfDeath=1 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 '
            .. 'IsEntityOnScreen=4 IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerPedId=1 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f) live(f); f.dead = true; return f.step() end,
    },
    {
        name = 'dead, the death already reported',
        want = 72,
        byName = 'ClearDrawOrigin=4 DisableControlAction=8 DisablePlayerFiring=1 DoesEntityExist=4 DrawRect=24 '
            .. 'GetGameTimer=1 GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityOnScreen=4 '
            .. 'IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerId=1 PlayerPedId=1 SetDrawOrigin=4 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f) live(f); f.dead = true; f.step(); return f.step() end,
    },
    {
        name = 'counting down, before any board',
        want = 14,
        byName = 'DisableControlAction=8 DisablePlayerFiring=1 GetGameTimer=1 IsEntityDead=1 '
            .. 'IsPauseMenuActive=1 PlayerId=1 PlayerPedId=1',
        run = function(f) f.enter(); f.step(); return f.step() end,
    },
    {
        name = 'counting down, with the board',
        want = 70,
        byName = 'ClearDrawOrigin=4 DisableControlAction=8 DisablePlayerFiring=1 DoesEntityExist=4 DrawRect=24 '
            .. 'GetGameTimer=1 GetPedBoneCoords=4 GetPlayerFromServerId=4 GetPlayerPed=4 IsEntityDead=1 '
            .. 'IsEntityOnScreen=4 IsPauseMenuActive=1 NetworkIsPlayerActive=4 PlayerId=1 PlayerPedId=1 '
            .. 'SetDrawOrigin=4',
        run = function(f) f.enter(); f.hud(); f.step(); return f.step() end,
    },
    {
        name = 'a team round with the marker switched off',
        want = 11,
        mutate = function(c) c.Teams.showTeamMarker = false end,
        byName = 'DisableControlAction=4 GetGameTimer=1 IsEntityDead=1 IsPauseMenuActive=1 PlayerPedId=1 '
            .. 'SetEntityDrawOutlineColor=1 SetEntityDrawOutlineRenderTechnique=1 SetEntityDrawOutlineShader=1',
        run = function(f) live(f); return f.step() end,
    },
    {
        name = 'a free-for-all',
        want = 8,
        byName = 'DisableControlAction=4 GetGameTimer=1 IsEntityDead=1 IsPauseMenuActive=1 PlayerPedId=1',
        run = function(f) live(f, nil, { modeKey = 'ffa' }); return f.step() end,
    },
}

for _, state in ipairs(FRAME_STATES) do
    t.test('BUDGET: the whole arena frame, ' .. state.name .. ' -- ' .. state.want .. ' natives', function()
        local f = newFixture({ mutate = state.mutate })
        local frame = state.run(f)
        local byName, total = breakdown(frame)
        t.equals(byName, state.byName, state.name)
        t.equals(total, state.want, state.name)
    end)
end

-- ======================================================================
-- FUZZ: THE RULE, AGAINST A MODEL OF IT
--
-- A seeded, deterministic generator -- its own, so nothing the resource
-- does with math.random can move it -- builds a board, a side, a mode and
-- a world, and the marker is held to a model written out below from the
-- rules in the comments above refreshTeamMarks and drawTeamMarks: WHO is
-- marked, what it COSTS, and that every marker is well formed.
-- ======================================================================

local function rng(seed)
    local state = seed
    return function(n)
        -- Park-Miller, which is exact in a double and the same on every
        -- machine this suite runs on.
        state = (state * 48271) % 2147483647
        return (state % n) + 1
    end
end

local function pick(roll, list) return list[roll(#list)] end

t.test('FUZZ: 300 seeded boards, each re-sent once -- who, what it costs, and the shape, against a model', function()
    local LOOKUP_COST = { unstreamed = 1, inactive = 2, noped = 3, gone = 4, offscreen = 5, drawn = 14 }
    local seen = {}
    local function saw(what) seen[what] = (seen[what] or 0) + 1 end

    --- THE MODEL: which rows are teammates to mark, in board order, and
    --- what the frame's marker must cost for them.
    local function expect(rows, fate, mode, mine, markerOn)
        local want, cost, listed = {}, 0, 0
        if mode ~= 'tdm' then saw('no-teams mode') return want, cost end
        if markerOn ~= true then saw('marker off') return want, cost end
        for _, row in ipairs(rows) do
            -- FLOORED, as Arena.ToInt floors it: a fraction names the
            -- player below it, and the stub raises if it arrives unfloored.
            local number = type(row) == 'table' and tonumber(row.id) or nil
            local id = number and math.floor(number)
            if type(row) ~= 'table' then
                saw('garbage row')
            elseif id == SELF then
                saw('self')
            elseif row.alive ~= true then
                saw('not alive')
            elseif row.team ~= mine then
                saw('not this side')
            else
                saw(fate[id])
                if type(row.id) == 'string' then saw('an id as text, listed') end
                if math.type(number) == 'float' then saw('an id with a fraction, listed') end
                listed = listed + 1
                cost = cost + LOOKUP_COST[fate[id]]
                if fate[id] == 'drawn' then want[#want + 1] = id end
            end
        end
        -- A BIG SIDE: more living teammates on the list than any fixed
        -- board here has, so a cap on the list cannot hide in the fuzz.
        if listed > 10 then saw('more than ten teammates') end
        return want, cost
    end

    local cases = 0
    for seed = 1, 300 do
        local roll = rng(seed * 7919)
        local mode = pick(roll, { 'tdm', 'tdm', 'tdm', 'tdm', 'ffa', 'gungame' })
        local mine = pick(roll, { 'crimson', 'ash' })
        local markerOn = pick(roll, { true, true, true, true, true, false, 'true' })
        local f = newFixture({ mutate = function(c) c.Teams.showTeamMarker = markerOn end })

        -- A board of up to fifteen rows -- or, one time in four, of
        -- twenty-five to fifty, a big server's round -- a few of them
        -- garbage, and a world in which each player is drawable or fails in
        -- one particular way. An id arrives now and then as text, or with a
        -- fraction on it.
        local rows = { { id = SELF, alive = true, team = mine } }
        local fate = {}
        local players = roll(4) == 1 and 24 + roll(26) or roll(14)
        for id = 2, 1 + players do
            local shape = roll(20)
            if shape == 1 then
                rows[#rows + 1] = 'garbage'
            else
                local sent = id
                if shape == 2 then sent = tostring(id) end
                if shape == 3 then sent = id + roll(3) * 0.25 end
                rows[#rows + 1] = {
                    id = sent,
                    alive = pick(roll, { true, true, true, true, false, 'true', 1 }),
                    team = pick(roll, { mine, mine, mine, 'crimson', 'ash', 'CRIMSON', '' }),
                }
                fate[id] = pick(roll, { 'drawn', 'drawn', 'drawn', 'drawn', 'offscreen',
                    'unstreamed', 'inactive', 'noped', 'gone' })
                if fate[id] == 'offscreen' then f.offScreen[1000 + id] = true end
                if fate[id] == 'unstreamed' then f.streamed[id] = false end
                if fate[id] == 'inactive' then f.inactive[id] = true end
                if fate[id] == 'noped' then f.pedOf[id] = 0 end
                if fate[id] == 'gone' then f.gone[1000 + id] = true end
            end
        end

        local label = ('seed %d (%s, %s, marker %s)'):format(seed, mode, mine, tostring(markerOn))
        local rgb = mine == 'crimson' and '255,34,51' or '42,166,255'

        local want, cost = expect(rows, fate, mode, mine, markerOn)
        local frame = live(f, rows, { modeKey = mode, teamKey = mine })
        t.equals(marked(f, frame), sortedIds(want), label .. ': who')
        t.equals(nativeCount(frame, MARKER_PATH), cost, label .. ': cost')
        t.equals(assertWellFormed(frame, rgb), #want, label .. ': shape')

        -- THE BOARD AGAIN, with some of the living dead and some of the dead
        -- back -- which must reach the very next frame.
        for _, row in ipairs(rows) do
            if type(row) == 'table' and row.id ~= SELF and roll(3) == 1 then
                row.alive = row.alive ~= true
            end
        end
        want, cost = expect(rows, fate, mode, mine, markerOn)
        f.hud(rows)
        frame = f.step()
        t.equals(marked(f, frame), sortedIds(want), label .. ': who, after the second board')
        t.equals(nativeCount(frame, MARKER_PATH), cost, label .. ': cost, after the second board')
        t.equals(assertWellFormed(frame, rgb), #want, label .. ': shape, after the second board')
        cases = cases + 1
    end
    t.equals(cases, 300, 'not every case ran')

    -- A FUZZ IS ONLY WORTH WHAT IT REACHED. Every branch of the model has to
    -- have been taken often enough to mean something, or a generator change
    -- could quietly stop testing one of them.
    for _, what in ipairs({ 'drawn', 'offscreen', 'unstreamed', 'inactive', 'noped', 'gone',
        'not alive', 'not this side', 'garbage row', 'self', 'no-teams mode', 'marker off',
        'more than ten teammates', 'an id as text, listed', 'an id with a fraction, listed' })
    do
        t.isTrue((seen[what] or 0) >= 20, ('the fuzz reached "%s" only %d times'):format(what, seen[what] or 0))
    end
end)

os.exit(t.summary())
