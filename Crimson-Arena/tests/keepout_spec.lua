--[[
    crimson_arena/tests/keepout_spec.lua

    THE FENCE ROUND A LIVE ARENA, which had no test of any kind.

    Isolation already stops an outsider seeing a fight or shooting into it --
    a live match is in its own routing bucket, which is the strongest answer
    there is. This is the PHYSICAL half of the same idea: without it somebody
    who is not in the round can walk into the middle of it, invisible to
    everybody there, and on a server that has turned isolation off they are
    standing in a live firefight.

    `Config.Match.keepOutBarrier` ships ENABLED, and before this file not one
    assertion in the suite mentioned it. A mutation campaign found it: the
    arithmetic that decides which way somebody is pushed, and how far, could
    be inverted in three separate places without a single spec noticing.

    Four properties, and the second is the one that makes it usable:

      IT PUSHES YOU OUT, NOT TO THE   a target of exactly the radius leaves
      EDGE                           you on the line, back inside on the next
                                     tick, and bouncing for as long as you
                                     stand there. `pushBackMetres` past it is
                                     what makes leaving stick.

      IT PUSHES YOU BACK THE WAY      along the line from the centre through
      YOU CAME                       where you are -- not spun round to
                                     somewhere you were not heading.

      A FIGHTER IS NEVER FENCED       out of their own round. The server
                                     never sends a player their own match.

      DEAD CENTRE STILL HAS A         there is no direction to push along
      DIRECTION                       from the exact middle, so one is
                                     chosen rather than dividing by zero.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('keepout_spec')

local ZONE = { x = 1000.0, y = 2000.0, z = 30.0, radius = 60.0, label = 'The Airfield' }

--- The real client/match.lua, with the ped somewhere we choose and every
--- teleport recorded.
local function newClient(mutate)
    local runner = Sandbox.newThreadRunner()
    local moves, notes = {}, {}
    local pos = { x = 0.0, y = 0.0, z = 30.0 }

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
        -- THE GROUND OUTSIDE IS HIGHER THAN THE GROUND INSIDE, and the probe
        -- SEARCHES DOWN from where it is asked -- both of which are why the
        -- production line asks from 200m up rather than from the player.
        --
        -- Modelled rather than waved through: a fixture that answers 30.0 to
        -- every query cannot tell the two apart, and the mutation that asks
        -- from the player's own height survives it.
        GetGroundZFor_3dCoord = function(x, y, z)
            local dx, dy = x - 1000.0, y - 2000.0
            local ground = (math.sqrt(dx * dx + dy * dy) < 60.0) and 30.0 or 45.0
            if (tonumber(z) or 0) < ground then return false, 0.0 end
            return true, ground
        end,

        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        FreezeEntityPosition = function() end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGameTimer = function() return 1000 end,
        joaat = function(name) return name end,
        lib = { notify = function(payload) notes[#notes + 1] = payload end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end, Exit = function() end,
            ClearDeadState = function() return true end, ReleaseDeadState = function() end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../client/match.lua', env)

    return {
        env = env,
        moves = moves,
        notes = notes,
        -- The HEIGHT IS A PARAMETER, defaulting to the zone's own. The
        -- whole vertical axis used to be nailed to 30.0 here and in `pos`
        -- above, so a fence that ignored z entirely -- which is what shipped
        -- -- passed every test in this file.
        at = function(x, y, z) pos = { x = x, y = y, z = z or 30.0 } end,
        pos = function() return pos end,
        step = runner.step,
        setZones = function(zones) env.ArenaMatch.SetKeepOut(zones) end,
    }
end

--- How far a point is from the zone centre.
local function distance(p)
    local dx, dy = p.x - ZONE.x, p.y - ZONE.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ======================================================================
-- IT PUSHES YOU OUT
-- ======================================================================

t.test('DEFECT: somebody standing in a live arena they are not in is moved out', function()
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)      -- 10m in, well inside a 60m circle
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'nobody was moved out of a live arena they had walked into')
    t.isTrue(distance(c.pos()) > ZONE.radius,
        ('they were left %0.2fm from the middle of a %0.1fm zone'):format(distance(c.pos()), ZONE.radius))
end)

t.test('and OUT, not onto the line, or they bounce there for ever', function()
    -- A target of exactly the radius puts them back inside on the next tick.
    -- pushBackMetres past it is the whole point of the setting.
    local c = newClient()
    local push = c.env.Config.Match.keepOutBarrier.pushBackMetres
    c.setZones({ ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)
    c.step(); c.step()

    local out = distance(c.pos())
    t.isTrue(math.abs(out - (ZONE.radius + push)) < 0.01,
        ('they were put %0.2fm out, and the radius plus pushBackMetres is %0.2fm')
            :format(out, ZONE.radius + push))
end)

t.test('and back the way they came, not spun somewhere else', function()
    -- Along the line from the centre through where they are standing. Coming
    -- in from the north must not put them out to the east.
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x, ZONE.y + 20.0)      -- due north of the middle
    c.step(); c.step()

    local p = c.pos()
    t.isTrue(math.abs(p.x - ZONE.x) < 0.01,
        ('pushed sideways: x moved from %0.2f to %0.2f'):format(ZONE.x, p.x))
    t.isTrue(p.y > ZONE.y, 'pushed out through the opposite side to the one they came in')
end)

t.test('and from dead centre they are still pushed somewhere', function()
    -- No direction to push along, so one is chosen. The alternative is a
    -- divide by zero and a player standing in the middle of a round.
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x, ZONE.y)
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'somebody in the exact middle was left there')
    local out = distance(c.pos())
    t.isTrue(out > ZONE.radius, ('left %0.2fm from the middle'):format(out))
end)

t.test('and put on the ground, not at the height they were standing', function()
    -- The ground outside can be higher than the ground inside, which is why
    -- the probe is asked from well above rather than from the player.
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)
    c.step(); c.step()
    -- The ground outside this zone stands at 45; inside it is 30. A player
    -- pushed out and left at their old height is standing inside a hillside.
    t.isTrue(math.abs(c.pos().z - 45.15) < 0.001,
        ('left at z=%0.2f rather than on the ground outside, which is 45'):format(c.pos().z))
end)

-- ======================================================================
-- AND LEAVES EVERYBODY ELSE ALONE
-- ======================================================================

t.test('somebody standing outside is not touched', function()
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x + 200.0, ZONE.y)
    c.step(); c.step(); c.step()
    t.equals(#c.moves, 0, 'a player nowhere near a match was teleported')
end)

t.test('and with no zones at all nothing runs', function()
    -- The server sends no zone for a match you are IN, which is how a
    -- fighter is kept from being fenced out of their own round.
    local c = newClient()
    c.setZones({})
    c.at(ZONE.x, ZONE.y)
    c.step(); c.step(); c.step()
    t.equals(#c.moves, 0, 'a player was pushed out of a zone that was never sent')
end)

t.test('and switching the barrier off stops it, with zones still sent', function()
    local c = newClient(function(config) config.Match.keepOutBarrier.enabled = false end)
    c.setZones({ ZONE })
    c.at(ZONE.x, ZONE.y)
    c.step(); c.step(); c.step()
    t.equals(#c.moves, 0, 'the barrier pushed somebody with the setting switched off')
end)

t.test('and a zone the server sent as junk is stepped over, not crashed on', function()
    local c = newClient()
    c.setZones({ { x = 'north', y = nil, radius = false, label = 7 }, ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)
    c.step(); c.step()
    t.isTrue(distance(c.pos()) > ZONE.radius,
        'a malformed zone in the list stopped the real one being enforced')
end)

-- ======================================================================
-- AND SAYS SO, ONCE
-- ======================================================================

t.test('crossing the line says something, and says it once', function()
    -- Four times a second for as long as somebody stands there is not a
    -- warning, it is a reason to turn warnings off.
    local c = newClient()
    c.setZones({ ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)
    for _ = 1, 6 do
        c.at(ZONE.x + 10.0, ZONE.y)   -- walk back in each tick
        c.step()
    end

    t.isTrue(#c.notes > 0, 'nobody was told why they had been moved')
    t.equals(#c.notes, 1, ('they were told %d times for one zone'):format(#c.notes))
end)

t.test('and the operator can turn the telling off', function()
    local c = newClient(function(config) config.Match.keepOutBarrier.notify = false end)
    c.setZones({ ZONE })
    c.at(ZONE.x + 10.0, ZONE.y)
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'the barrier stopped working when the notice was switched off')
    t.equals(#c.notes, 0, 'a notice went out with notify = false')
end)

-- ========================================================================
-- THE FENCE IS A SPHERE, NOT A COLUMN
--
-- server/lobby.lua says of this fence: "The BOUNDARY is the fence,
-- deliberately -- the same circle the fighters themselves are bled for
-- leaving." The fighters' edge is spherical; this one tested x and y alone
-- and the height the server sends was read by nothing.
--
-- On the shipped skydome -- centre (1500, 3000, 1201), radius 110 -- that
-- made every player standing on the ground a KILOMETRE BELOW IT part of a
-- live match's keep-out zone: shoved 116 m sideways four times a second and
-- told a match was being fought where they were standing.
-- ========================================================================

t.test('DEFECT: somebody a kilometre below the zone was fenced out of it', function()
    local c = newClient()
    c.setZones({ ZONE })

    -- Directly under the middle, far enough down to be nowhere near the
    -- sphere. Horizontally they are dead centre, which is what the old
    -- 2D test called "as far inside as it is possible to be".
    c.at(ZONE.x, ZONE.y, ZONE.z - 1000.0)
    c.step(); c.step()

    t.equals(#c.moves, 0,
        'a player a kilometre below the arena was teleported out of it')
    t.equals(#c.notes, 0,
        'and told a match was being fought where they were standing')
end)

t.test('and somebody flying high over it is left alone too', function()
    -- The other direction, which is what pulled aircraft out of the sky
    -- over the trailer park.
    local c = newClient()
    c.setZones({ ZONE })

    c.at(ZONE.x, ZONE.y, ZONE.z + 500.0)
    c.step(); c.step()

    t.equals(#c.moves, 0, 'a player flying over the arena was yanked out of the air')
end)

t.test('but somebody INSIDE the sphere is still pushed out', function()
    -- The control, and the whole point: a fence that refused everything
    -- would pass both tests above and stop being a fence.
    local c = newClient()
    c.setZones({ ZONE })

    c.at(ZONE.x + 10.0, ZONE.y, ZONE.z)
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'the barrier stopped working for somebody standing in the arena')
    t.isTrue(distance(c.pos()) > ZONE.radius,
        'they were left inside the zone')
end)

t.test('and height only counts against them within the sphere', function()
    -- Just under the rim: still inside a 60m sphere centred at z = 30 if you
    -- are 20m below it and 10m out horizontally (sqrt(10^2 + 20^2) = 22.4).
    local c = newClient()
    c.setZones({ ZONE })

    c.at(ZONE.x + 10.0, ZONE.y, ZONE.z - 20.0)
    -- ONE pass, deliberately. A second tick re-measures from wherever the
    -- first put them and pushes again, which papers over a push that was
    -- aimed with the wrong length -- it simply takes two ticks to get them
    -- out instead of one. The contract is that ONE crossing puts them
    -- outside.
    c.step()

    t.isTrue(#c.moves > 0,
        'somebody genuinely inside the sphere, below its centre, was not moved')

    -- AND THE PUSH IS AIMED WITH THE HORIZONTAL DISTANCE, which is why
    -- zoneAt returns that rather than the 3D reach it now tests against.
    -- The push normalises (dx, dy) by the distance it is handed: give it the
    -- 3D length and the horizontal step shrinks by the ratio between them,
    -- so this player -- 10 m out and 20 m down -- would be moved to 29 m
    -- from the middle of a 60 m zone and left standing inside it.
    t.isTrue(distance(c.pos()) > ZONE.radius,
        ('pushed only %0.2fm from the middle of a %0.1fm zone -- still inside it')
            :format(distance(c.pos()), ZONE.radius))
end)

t.test('and a zone with NO height still fences its own ground', function()
    -- An older server, or an arena whose boundary centre was written without
    -- a z. Refusing to fence at all would be worse than fencing a column.
    local c = newClient()
    c.setZones({ { x = ZONE.x, y = ZONE.y, radius = ZONE.radius, label = ZONE.label } })

    c.at(ZONE.x + 10.0, ZONE.y, ZONE.z)
    c.step(); c.step()

    t.isTrue(#c.moves > 0, 'a zone without a height fenced nobody at all')
end)

os.exit(t.summary())
