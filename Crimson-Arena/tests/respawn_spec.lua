--[[
    crimson_arena/tests/respawn_spec.lua

    WHERE A PLAYER GOES WHEN THEY LOSE A LIFE.

    The respawn used to be Arena.PickSpawn with a cursor: the next point
    along the arena's list, every time. Predictable, and on a short list that
    is the corner they died in a moment ago -- so a player with three lives
    could be killed three times in the same spot by somebody who never moved.

    Arena.PickRespawn replaces it. Two properties, and both matter:

      RANDOM      two respawns in the same arena are not the same point, and
                  the sequence does not walk.
      AWAY        of the points it could use, it takes the one whose NEAREST
                  live opponent is furthest off -- maximin, not the furthest
                  from the average, because an average is happily satisfied
                  by landing exactly between two enemies.

    Teammates are not opponents and are not avoided: coming back near your
    own side is the point of having one.

    These assert PROPERTIES, not coordinates. The placement is random by
    design, so a test pinning exact numbers would either be asserting the
    random number generator or defeating it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('respawn_spec')

local AREA = { x = 1000.0, y = 2000.0, z = 30.0 }

--- @param options table? -- { noArea = true, noPoints = true }
---
--- FLAGS, NOT AN OVERRIDE TABLE. The first version of this took overrides
--- and merged them with pairs(), so `{ spawnArea = nil }` -- the obvious way
--- to write "an arena with no spawn area" -- removed nothing at all: a nil
--- value is not a key. Every test asking for the point-list path silently got
--- the area path and passed on the wrong branch.
local function envWith(options)
    options = options or {}
    local env = Sandbox.newArenaEnv()
    local arena = {
        label = 'Ring',
        enabled = true,
        spawnArea = {
            enabled = true,
            center = { x = AREA.x, y = AREA.y, z = AREA.z },
            radius = 100.0,
            minSeparation = 12.0,
            teamRadius = 25.0,
        },
        spawns = {
            { x = AREA.x - 90.0, y = AREA.y, z = AREA.z, w = 0.0 },
            { x = AREA.x,        y = AREA.y, z = AREA.z, w = 0.0 },
            { x = AREA.x + 90.0, y = AREA.y, z = AREA.z, w = 0.0 },
        },
    }
    if options.noArea then arena.spawnArea = nil end
    if options.noPoints then arena.spawns = {} end
    env.Config.Arenas = { ring = arena }
    return env
end

--- Plane distance between two points.
local function gap(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ======================================================================
-- RANDOM
-- ======================================================================

t.test('two respawns in the same arena are not the same point', function()
    local Arena = envWith().Arena

    local seen = {}
    for _ = 1, 20 do
        local point = Arena.PickRespawn('ring', nil, nil)
        t.isNotNil(point, 'no respawn point was produced at all')
        seen[('%0.3f:%0.3f'):format(point.x, point.y)] = true
    end

    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    t.isTrue(distinct > 10,
        ('twenty respawns produced only %d distinct points -- this is a cursor, not a scatter'):format(distinct))
end)

t.test('and every one of them is inside the arena', function()
    local Arena = envWith().Arena
    for _ = 1, 40 do
        local point = Arena.PickRespawn('ring', nil, nil)
        t.isTrue(gap(point, AREA) <= 100.0 + 0.001,
            ('a respawn landed %0.1fm from the centre of a 100m area'):format(gap(point, AREA)))
    end
end)

t.test('an arena with only a point list still moves around it', function()
    -- No spawnArea, so the list IS every choice there is. Walked from a
    -- random start rather than from the front, or a short list plus one
    -- enemy is a cursor again.
    local Arena = envWith({ noArea = true }).Arena

    local seen = {}
    for _ = 1, 30 do
        local point = Arena.PickRespawn('ring', nil, nil)
        t.isNotNil(point)
        seen[('%0.1f'):format(point.x)] = true
    end

    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    t.isTrue(distinct >= 2,
        'every respawn on a three-point list came back to the same point')
end)

t.test('an arena with neither an area nor points has no answer, and says so', function()
    local Arena = envWith({ noArea = true, noPoints = true }).Arena
    t.isNil(Arena.PickRespawn('ring', nil, nil),
        'a point was invented for an arena that defines none')
    t.isNil(Arena.PickRespawn('nosucharena', nil, nil))
end)

-- ======================================================================
-- AWAY FROM WHOEVER IS STILL ALIVE
-- ======================================================================

t.test('a respawn lands away from the one live enemy', function()
    local Arena = envWith().Arena

    -- An enemy pinned at the western edge. Every respawn should come back
    -- east of the centre, because that is where the distance is.
    local enemy = { x = AREA.x - 95.0, y = AREA.y, z = AREA.z }

    local nearest = math.huge
    for _ = 1, 30 do
        local point = Arena.PickRespawn('ring', nil, { enemy })
        nearest = math.min(nearest, gap(point, enemy))
    end

    t.isTrue(nearest > 100.0,
        ('a respawn landed %0.1fm from the only enemy on the field -- '):format(nearest)
        .. 'the picker is not reading the positions it was given')
end)

t.test('and it is the NEAREST enemy that is maximised, not the average', function()
    -- THE TRAP. Two enemies on opposite edges: the point furthest from their
    -- AVERAGE is the centre, which is the worst place on the field -- equally
    -- close to both. Maximin puts it out at the edge instead, as far from one
    -- of them as the circle allows.
    local Arena = envWith().Arena
    local west = { x = AREA.x - 95.0, y = AREA.y, z = AREA.z }
    local east = { x = AREA.x + 95.0, y = AREA.y, z = AREA.z }

    for _ = 1, 25 do
        local point = Arena.PickRespawn('ring', nil, { west, east })
        local nearest = math.min(gap(point, west), gap(point, east))
        t.isTrue(nearest > 60.0,
            ('a respawn landed %0.1fm from an enemy with two on the field -- '):format(nearest)
            .. 'the middle is the furthest point from their average and the worst place to stand')
    end
end)

t.test('an empty threat list is not an error, and not a fallback to a cursor', function()
    local Arena = envWith().Arena
    local seen = {}
    for _ = 1, 20 do
        local point = Arena.PickRespawn('ring', nil, {})
        t.isNotNil(point, 'a round with nobody left to avoid produced no spawn')
        seen[('%0.3f:%0.3f'):format(point.x, point.y)] = true
    end

    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    t.isTrue(distinct > 10, 'with nobody to avoid the picker stopped being random')
end)

t.test('a junk entry does not disturb the real enemy it sits beside', function()
    local Arena = envWith().Arena
    local real = { x = AREA.x - 95.0, y = AREA.y, z = AREA.z }

    for _ = 1, 20 do
        local point = Arena.PickRespawn('ring', nil, { real, 'nonsense', nil, 42, {} })
        t.isTrue(gap(point, real) > 100.0,
            'a junk entry in the threat list changed where the real enemy pushed the spawn to')
    end
end)

t.test('and it is DROPPED, not read as the origin', function()
    -- The distinction is invisible on an arena far from 0,0 -- the origin is
    -- two kilometres away there, so it is never the nearest threat and never
    -- binds. This arena is centred ON the origin, where a junk position read
    -- as 0,0 sits in the middle of the field and pushes every respawn out to
    -- the rim.
    local env = Sandbox.newArenaEnv()
    env.Config.Arenas = {
        ring = {
            label = 'Ring', enabled = true,
            spawnArea = {
                enabled = true,
                center = { x = 0.0, y = 0.0, z = 30.0 },
                radius = 100.0, minSeparation = 12.0, teamRadius = 25.0,
            },
            spawns = { { x = 0.0, y = 0.0, z = 30.0, w = 0.0 } },
        },
    }
    local centre = { x = 0.0, y = 0.0 }

    local closest = math.huge
    for _ = 1, 60 do
        local point = env.Arena.PickRespawn('ring', nil, { 'nonsense', 42, {}, true })
        closest = math.min(closest, gap(point, centre))
    end

    t.isTrue(closest < 50.0,
        ('sixty respawns with nothing real to avoid never came within 50m of the middle '
         .. '(closest was %0.1fm) -- the junk entries are being treated as an enemy standing there'):format(closest))
end)

t.test('vector-shaped and array-shaped positions are both understood', function()
    -- The caller holds whatever the engine handed it. A position shape that
    -- silently reads as nothing is an enemy the picker cannot see.
    local Arena = envWith().Arena
    local west = AREA.x - 95.0

    for _, threat in ipairs({
        { x = west, y = AREA.y, z = AREA.z },        -- named fields
        { west, AREA.y, AREA.z },                    -- plain array
        Sandbox.vector3(west, AREA.y, AREA.z),       -- what the engine returns
    }) do
        local nearest = math.huge
        for _ = 1, 15 do
            local point = Arena.PickRespawn('ring', nil, { threat })
            nearest = math.min(nearest, gap(point, { x = west, y = AREA.y }))
        end
        t.isTrue(nearest > 100.0,
            'a threat in this shape was invisible to the picker: ' .. type(threat))
    end
end)

-- ======================================================================
-- REJOINING YOUR SIDE MAY NOT COST YOU THE GAP
--
-- The teammate preference scores candidates on distance from a TEAMMATE and
-- has no threat term at all. It was written to run only on candidates that
-- had already cleared the enemy gap -- its comment said so -- but the filter
-- that produced them falls back to the FULL pool when nothing clears, and
-- then the teammate rule ran on that. A teammate in a fight is standing next
-- to the enemy, so "nearest a teammate" is "nearest the enemy".
--
-- AND THE FILTER EMPTIES ROUTINELY. The gap it asks for is
-- achievableSeparation(R, threats + 1), which with ONE live enemy is
-- 1.0774 * R -- bigger than the arena. Nothing in the disc can clear it
-- while that enemy is near the middle, which is the team-deathmatch endgame:
-- last enemy holding the centre, one of your side engaging them, every
-- respawn you have left aimed at the pair of them.
--
-- Measured against the shipped skydome before the fix: 66% of respawns
-- inside the promised ten metres, closest 0.02m.
-- ======================================================================

t.test('DEFECT: rejoining a teammate put the player on top of the enemy', function()
    local Arena = envWith().Arena
    -- The endgame. The enemy holds the middle, a teammate is fighting them.
    local enemy = { x = AREA.x, y = AREA.y, z = AREA.z }
    local mate  = { x = AREA.x + 3.0, y = AREA.y, z = AREA.z }

    local closest, breaches = math.huge, 0
    for _ = 1, 400 do
        local point = Arena.PickRespawn('ring', nil, { enemy }, nil, nil, { mate })
        t.isNotNil(point, 'no respawn point was produced at all')
        local distance = gap(point, enemy)
        if distance < closest then closest = distance end
        if distance < 12.0 then breaches = breaches + 1 end
    end

    t.equals(breaches, 0,
        ('%d of 400 respawns landed inside the 12m this arena promises -- closest %.2fm')
            :format(breaches, closest))
end)

t.test('and the preference itself still works, or the fix is just the maximin', function()
    -- THE CONTROL, and without it the test above is passed by deleting the
    -- teammate rule outright. Landing beside your own side is the whole
    -- reason the rule exists; what it may not do is go under the promise.
    --
    -- Compared against the SAME call with no teammate, so this measures the
    -- preference rather than the geometry.
    local Arena = envWith().Arena
    local enemy = { x = AREA.x - 80.0, y = AREA.y, z = AREA.z }
    local mate  = { x = AREA.x + 60.0, y = AREA.y, z = AREA.z }

    local withMate, without = 0, 0
    for _ = 1, 300 do
        withMate = withMate + gap(Arena.PickRespawn('ring', nil, { enemy }, nil, nil, { mate }), mate)
        without  = without  + gap(Arena.PickRespawn('ring', nil, { enemy }), mate)
    end

    t.isTrue((withMate / 300) < (without / 300),
        ('naming a teammate made no difference to where the player came back: %.1fm with, %.1fm without')
            :format(withMate / 300, without / 300))
end)

t.test('and where nothing can hold the gap at all, safety alone decides', function()
    -- Nothing left to spend. With the promised separation as large as the
    -- arena itself no candidate can clear it, so the teammate rule has no
    -- qualifying list to choose from and must stand down entirely rather
    -- than fall back to the whole pool.
    local env = envWith()
    env.Config.Arenas.ring.spawnArea.minSeparation = 100.0   -- == the radius
    local Arena = env.Arena

    local enemy = { x = AREA.x, y = AREA.y, z = AREA.z }
    local mate  = { x = AREA.x + 3.0, y = AREA.y, z = AREA.z }

    local nearMate = 0
    for _ = 1, 200 do
        local point = Arena.PickRespawn('ring', nil, { enemy }, nil, nil, { mate })
        if gap(point, mate) < 50.0 then nearMate = nearMate + 1 end
    end

    t.equals(nearMate, 0,
        ('%d of 200 respawns were placed beside the teammate -- and so beside the enemy -- '
            .. 'though no candidate could hold the gap'):format(nearMate))
end)

os.exit(t.summary())
