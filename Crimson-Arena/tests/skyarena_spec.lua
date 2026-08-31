--[[
    crimson_arena/tests/skyarena_spec.lua

    AN ARENA THAT BRINGS ITS OWN GROUND.

    Most of a server's map is already spoken for, so an arena can be put in
    the sky instead -- where there is nothing at all, including a floor. It
    carries one: a prop tiled into a disc, with cover standing on it, built
    when a fighter walks in and deleted when they walk out.

    ONE SKY ARENA SERVES EVERY MATCH AT ONCE. That looks wrong and is not:
    every match is fought in its own routing bucket, so two matches at these
    exact coordinates are in different instances of the world and cannot see,
    shoot or collide with each other. Nothing has to be moved, numbered or
    torn down between matches.

    These assert the geometry and the rules. The half that cannot be checked
    outside the game -- whether a given prop model exists on a given build,
    and how thick it is -- is why the shipped arena ships DISABLED.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('skyarena_spec')

local CENTRE = { x = 1500.0, y = 3000.0, z = 1201.0 }

--- An env holding one sky arena, with whatever this test wants changed.
--- @param mutate fun(arena: table)?
local function envWith(mutate)
    local env = Sandbox.newArenaEnv()
    local arena = {
        label = 'Skydome',
        enabled = true,
        platform = {
            enabled = true,
            model = 'test_floor',
            tileSize = 8.0,
            radius = 45.0,
            z = 1200.0,
        },
        cover = {
            enabled = true,
            pieces = {
                { model = 'test_block', x = 10.0, y = 0.0, z = 0.0, heading = 90.0 },
                { model = 'test_block', x = -10.0, y = 5.0, z = 0.0, heading = 270.0 },
            },
        },
        exactSpawnZ = true,
        spawnArea = {
            enabled = true,
            center = { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z },
            radius = 35.0,
            minSeparation = 10.0,
            teamRadius = 16.0,
        },
        spawns = { { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z, w = 0.0 } },
        boundary = {
            enabled = true,
            center = { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z },
            radius = 60.0,
        },
    }
    if mutate then mutate(arena) end
    env.Config.Arenas = { sky = arena }
    return env
end

local function plane(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

-- ======================================================================
-- THE FLOOR
-- ======================================================================

t.test('a platform is described by two numbers, not two hundred coordinates', function()
    -- Hand-listing every tile would make the floor unresizable, which is the
    -- one thing an operator laying out an arena actually wants to do.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')

    t.isNotNil(platform, 'the arena describes no floor at all')
    t.equals(platform.model, 'test_floor')
    t.equals(platform.tileSize, 8.0)
    t.equals(platform.radius, 45.0)
    t.equals(platform.z, 1200.0)
end)

t.test('and an arena on the ground describes none', function()
    local Arena = envWith(function(arena) arena.platform = nil end).Arena
    t.isNil(Arena.GetPlatform('sky'), 'an arena with no platform block was given one')

    local off = envWith(function(arena) arena.platform.enabled = false end).Arena
    t.isNil(off.GetPlatform('sky'), 'a switched-off platform was still built')
end)

t.test('a platform with no model or no size is not a platform', function()
    -- Half a description is worse than none: it would build nothing and
    -- report that it had.
    for _, break_ in ipairs({
        function(a) a.platform.model = nil end,
        function(a) a.platform.tileSize = 0 end,
        function(a) a.platform.radius = 0 end,
    }) do
        t.isNil(envWith(break_).Arena.GetPlatform('sky'))
    end
end)

--- Whether a world point lands on any of these tiles.
--- @param tiles table[]
--- @param px number
--- @param py number
--- @param sizeX number
--- @param sizeY number
local function onSomeTile(tiles, px, py, sizeX, sizeY)
    for _, tile in ipairs(tiles) do
        if math.abs(px - tile.x) <= sizeX * 0.5 + 1e-6
            and math.abs(py - tile.y) <= sizeY * 0.5 + 1e-6 then
            return true
        end
    end
    return false
end

t.test('the tiles COVER the disc -- every point inside the radius is on one', function()
    -- THE INVARIANT THAT MATTERS, and the one the first version got wrong.
    -- It kept a tile when its CENTRE was inside the radius, which is a
    -- different question: the diagonals come up bare, because a point can be
    -- inside the arena while every tile whose centre is inside it is too far
    -- away to reach.
    --
    -- A floor is not judged on where its pieces are. It is judged on whether
    -- there is a piece under every point somebody can stand.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')
    local size = 8.0
    local tiles = Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, size)

    t.isTrue(#tiles > 20, ('a 45m floor of 8m tiles produced only %d pieces'):format(#tiles))

    local hole = nil
    for ring = 0, math.floor(platform.radius) do
        for step = 0, 47 do
            local angle = (step / 48) * math.pi * 2
            local px = CENTRE.x + ring * math.cos(angle)
            local py = CENTRE.y + ring * math.sin(angle)
            if not onSomeTile(tiles, px, py, size, size) and not hole then
                hole = ('%0.1f, %0.1f'):format(px - CENTRE.x, py - CENTRE.y)
            end
        end
    end
    t.isNil(hole, hole and ('a hole in the floor at offset %s -- that is a fall'):format(hole) or '')

    -- And it is still a DISC rather than a square: nothing is built out at
    -- the far corner, which would be solid ground a long way out of bounds.
    t.isTrue(not onSomeTile(tiles, CENTRE.x + platform.radius, CENTRE.y + platform.radius, size, size),
        'the floor is square, so its corners are solid ground outside the arena')
end)

t.test('DEFECT: a prop WIDER than the arena still makes a floor, not one tile', function()
    -- The failure the coverage rule exists for, and the one that broke the
    -- shipped arena. A 40m block on a 45m radius used to inset by half a
    -- tile, floor(25/40) = 0, and lay exactly ONE piece in the middle --
    -- twenty metres of floor under a thirty-five metre spawn ring. Everybody
    -- who did not draw the centre spawned on air.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')
    local tiles = Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, 40.0)

    t.isTrue(#tiles >= 9, ('a 40m prop laid only %d piece(s) on a 45m floor'):format(#tiles))

    -- Every spawn the arena can hand out has a piece under it.
    local hole = nil
    for step = 0, 23 do
        local angle = (step / 24) * math.pi * 2
        local px = CENTRE.x + 35.0 * math.cos(angle)
        local py = CENTRE.y + 35.0 * math.sin(angle)
        if not onSomeTile(tiles, px, py, 40.0, 40.0) and not hole then
            hole = ('%0.1f, %0.1f'):format(px - CENTRE.x, py - CENTRE.y)
        end
    end
    t.isNil(hole, hole and ('the spawn ring hangs over nothing at %s'):format(hole) or '')
end)

t.test('DEFECT: a long thin prop is tiled on BOTH axes, not on its longest side', function()
    -- A shipping container is 12.2m by 2.5m. Taking max(width, depth) and
    -- spacing both axes on it -- which is what measuring a single "width"
    -- forces -- lays the pieces out with ten-metre gaps between the rows,
    -- and a floor with gaps in it is a floor people fall through.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')
    local tiles = Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, { x = 12.2, y = 2.5 })

    local hole = nil
    for ring = 0, math.floor(platform.radius) do
        for step = 0, 23 do
            local angle = (step / 24) * math.pi * 2
            local px = CENTRE.x + ring * math.cos(angle)
            local py = CENTRE.y + ring * math.sin(angle)
            if not onSomeTile(tiles, px, py, 12.2, 2.5) and not hole then
                hole = ('%0.1f, %0.1f'):format(px - CENTRE.x, py - CENTRE.y)
            end
        end
    end
    t.isNil(hole, hole and ('a gap between the rows at %s'):format(hole) or '')
end)

t.test('DEFECT: the floor hangs from its SURFACE -- the prop is lowered by its own height', function()
    -- `platform.z` is where people STAND, not where the pieces are created.
    --
    -- The other way round is what shipped, and it is why the arena did not
    -- work: the pieces were created at the configured Z and the walkable
    -- surface came out at "that, plus however tall the prop turned out to
    -- be". Cover is positioned from the spawn centre in config, so every
    -- barrier was then buried that far underneath the floor -- and the
    -- height nobody could measure was the height everything else depended
    -- on.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')

    for _, tile in ipairs(Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, { x = 8.0, y = 8.0, top = 3.5 })) do
        t.equals(tile.z, platform.z - 3.5,
            'the piece was not lowered by its own height, so the surface is not where config says')
    end

    -- A taller prop is dropped further, and the surface does not move.
    for _, tile in ipairs(Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, { x = 8.0, y = 8.0, top = 12.0 })) do
        t.equals(tile.z, platform.z - 12.0)
    end
end)

t.test('maxTiles keeps the middle and drops the rim', function()
    -- The container fallback needs a few hundred pieces where a block needs
    -- nine, and several hundred objects per client per round is where the
    -- game starts to suffer. What a capped floor loses has to be edge nobody
    -- spawns on, never a hole in the middle.
    local Arena = envWith(function(arena) arena.platform.maxTiles = 12 end).Arena
    local platform = Arena.GetPlatform('sky')
    local tiles = Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, 8.0)

    t.equals(#tiles, 12, 'the ceiling was not applied')

    -- The centre piece survived, and the furthest one did not.
    t.isTrue(onSomeTile(tiles, CENTRE.x, CENTRE.y, 8.0, 8.0), 'the cap ate the middle of the floor')
    local furthest = 0.0
    for _, tile in ipairs(tiles) do
        furthest = math.max(furthest, plane(tile, CENTRE))
    end
    t.isTrue(furthest < platform.radius, 'the cap kept the rim and dropped the middle')
end)

t.test('and no ceiling is the default, so an uncapped floor is whole', function()
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')
    t.equals(platform.maxTiles, 0)
    t.isTrue(#Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y, 8.0) > 50,
        'an uncapped floor came back small')
end)

t.test('and they all sit at the platform height when nothing has been measured', function()
    -- Nothing measured means nothing to lower the piece by. The surface is
    -- then the configured Z exactly, which is the best answer available and
    -- the one the server-side planner works from.
    local Arena = envWith().Arena
    for _, tile in ipairs(Arena.PlatformTiles(Arena.GetPlatform('sky'), CENTRE.x, CENTRE.y)) do
        t.equals(tile.z, 1200.0)
    end
end)

t.test('the spawn ring sits inside the floor, and the floor inside the boundary', function()
    -- THE TWO RELATIONSHIPS THAT KEEP PEOPLE ALIVE, in order of severity.
    --
    -- A spawn outside the floor is a fall, and a fall out of this arena is
    -- a kilometre. A spawn outside the boundary is a fighter bleeding from
    -- the first second of the round. Both are silent: neither reads as an
    -- error at either end, and both are one mistyped radius away.
    --
    -- The floor's PIECES may overhang the boundary at the corners, because
    -- coverage beats tidiness: a piece is kept whenever any part of it is
    -- inside the radius, so a prop wider than the inset reaches further out
    -- than `platform.radius` says. That is deliberate and it is safe -- the
    -- worst it produces is solid ground somebody bleeds on, which is what
    -- walking out of any arena does. The alternative, trimming to the
    -- radius, is a hole, and a hole here is fatal.
    local config = envWith().Config
    local arena = config.Arenas.sky
    t.isTrue(arena.spawnArea.radius < arena.platform.radius,
        'a spawn can land past the edge of the floor')
    t.isTrue(arena.spawnArea.radius < arena.boundary.radius,
        'a spawn can land out of bounds, bleeding from the first second')
    t.isTrue(arena.platform.radius < arena.boundary.radius,
        'the floor is described as wider than the arena it is the floor of')
end)

-- ======================================================================
-- THE COVER
-- ======================================================================

t.test('cover is a hand-written list, because where a barrier goes is a decision', function()
    local Arena = envWith().Arena
    local cover = Arena.GetCover('sky')

    t.equals(#cover, 2)
    t.equals(cover[1].model, 'test_block')
    t.equals(cover[1].x, 10.0)
    t.equals(cover[1].heading, 90.0)
end)

t.test('and switching it off leaves the floor alone', function()
    local Arena = envWith(function(arena) arena.cover.enabled = false end).Arena
    t.equals(#Arena.GetCover('sky'), 0)
    t.isNotNil(Arena.GetPlatform('sky'), 'turning the cover off took the floor with it')
end)

t.test('a piece with no model is dropped rather than built as nothing', function()
    local Arena = envWith(function(arena)
        arena.cover.pieces[#arena.cover.pieces + 1] = { x = 1.0, y = 1.0 }
    end).Arena
    t.equals(#Arena.GetCover('sky'), 2, 'a nameless piece reached the build list')
end)

-- ======================================================================
-- WHAT THE CLIENT IS ASKED TO BUILD
-- ======================================================================

t.test('floor and cover arrive as ONE list, in world coordinates', function()
    -- One list on purpose. A floor torn down by one path while the barriers
    -- standing on it are torn down by another is two chances to leave
    -- something behind at a thousand metres.
    local Arena = envWith().Arena
    local props = Arena.ArenaProps('sky')

    local tiles = #Arena.PlatformTiles(Arena.GetPlatform('sky'), CENTRE.x, CENTRE.y)
    t.equals(#props, tiles + 2, 'the build list is not the floor plus the cover')

    local floors, blocks = 0, 0
    for _, piece in ipairs(props) do
        if piece.model == 'test_floor' then floors = floors + 1 end
        if piece.model == 'test_block' then blocks = blocks + 1 end
    end
    t.equals(floors, tiles)
    t.equals(blocks, 2)
end)

t.test('cover offsets are resolved against the arena centre', function()
    -- `z = 0` has to mean "standing on the floor", or every piece needs a
    -- world coordinate worked out by hand.
    local Arena = envWith().Arena
    local found = nil
    for _, piece in ipairs(Arena.ArenaProps('sky')) do
        if piece.model == 'test_block' and piece.heading == 90.0 then found = piece end
    end

    t.isNotNil(found, 'the cover piece never reached the build list')
    t.equals(found.x, CENTRE.x + 10.0)
    t.equals(found.y, CENTRE.y)
    t.equals(found.z, CENTRE.z, 'z = 0 did not land on the arena surface')
end)

t.test('an ordinary ground arena asks for nothing to be built', function()
    -- Every arena that already has a floor is this case, and it must stay
    -- free: no models loaded, no objects made, no teardown to get wrong.
    local Arena = envWith(function(arena)
        arena.platform = nil
        arena.cover = nil
    end).Arena
    t.equals(#Arena.ArenaProps('sky'), 0)
end)

t.test('and an arena nobody has heard of asks for nothing either', function()
    local Arena = envWith().Arena
    t.equals(#Arena.ArenaProps('nosucharena'), 0)
    t.isNil(Arena.GetPlatform('nosucharena'))
    t.equals(#Arena.GetCover('nosucharena'), 0)
end)

-- ======================================================================
-- THE RULE THAT MAKES IT WORK AT ALL
-- ======================================================================

t.test('a sky arena declares its spawn Z EXACT', function()
    -- The one thing that would silently break the whole idea. The client
    -- places a fighter by asking the game where the ground is, and that
    -- search runs DOWNWARD looking for terrain -- so from a kilometre up it
    -- finds the real map far below, reports success, and teleports every
    -- fighter out of the arena onto the ground. Both halves behave exactly as
    -- documented and the arena is unusable.
    t.isTrue(envWith().Arena.UsesExactSpawnZ('sky'),
        'a sky arena is letting the client search downward for a floor a kilometre below it')
end)

t.test('and an arena on the ground does not', function()
    -- The search is right for every ordinary arena, and turning it off
    -- everywhere would drop players through terrain that had not streamed in.
    local Arena = envWith(function(arena) arena.exactSpawnZ = nil end).Arena
    t.isFalse(Arena.UsesExactSpawnZ('sky'))
    t.isFalse(Arena.UsesExactSpawnZ('nosucharena'))
end)

-- ======================================================================
-- NOBODY IS PUT UNDER THE ARENA, OR UNDER THE MAP
-- ======================================================================

t.test('an arena that carries its floor knows the lowest Z it may use', function()
    t.equals(envWith().Arena.SpawnFloor('sky'), 1200.0)
end)

t.test('and an arena on real ground has no such floor -- the ground answers', function()
    -- Clamping an ordinary arena to a number would be worse than not
    -- clamping it: terrain is not flat, and the probe is right about it.
    local Arena = envWith(function(arena) arena.platform = nil end).Arena
    t.isNil(Arena.SpawnFloor('sky'))
    t.isNil(Arena.SpawnFloor('nosucharena'))
end)

t.test('NO SPAWN LANDS INSIDE A WALL', function()
    -- Cover and spawns are laid out by two things that do not know about
    -- each other: a hand-written list and a random scatter. Left alone, a
    -- fighter appearing inside a shipping container is a matter of time --
    -- and from inside one there is nowhere to walk to.
    --
    -- The planner keeps fighters minSeparation apart already, so the cover is
    -- seeded into the same list of things to stay away from -- but with its
    -- OWN clearance, not the player one. Excluding ten metres around every
    -- barrier took a bigger bite out of the arena than the arena had, so
    -- every placement fell through to the relaxation and nobody was ever
    -- minSeparation from anybody. Cover's number only has to mean "not
    -- inside it": Arena.CoverClearance, measured from the piece's origin,
    -- which is why it is a container's half-length rather than a token
    -- metre.
    local env = envWith()
    local Arena = env.Arena
    local area = Arena.GetSpawnArea('sky')

    local cover = {}
    for _, piece in ipairs(Arena.GetCover('sky')) do
        cover[#cover + 1] = { x = area.x + piece.x, y = area.y + piece.y }
    end
    t.isTrue(#cover > 0, 'this arena has no cover, so this test proves nothing')

    -- Many rosters, so this is not one lucky arrangement.
    for _ = 1, 40 do
        local roster = {}
        for id = 1, 8 do roster[#roster + 1] = { src = id } end

        local plan = Arena.PlanSpawns('sky', roster)
        t.isNotNil(plan, 'no plan was produced at all')

        for src, point in pairs(plan) do
            for _, wall in ipairs(cover) do
                local dx, dy = point.x - wall.x, point.y - wall.y
                local gap = math.sqrt(dx * dx + dy * dy)
                t.isTrue(gap >= Arena.CoverClearance('sky'),
                    ('player %s spawned %0.1fm from a wall, inside it'):format(tostring(src), gap))
            end
        end
    end
end)

t.test('and they still land on the floor, not past its edge', function()
    local env = envWith()
    local Arena = env.Arena
    local area = Arena.GetSpawnArea('sky')
    local platform = Arena.GetPlatform('sky')

    for _ = 1, 40 do
        local roster = {}
        for id = 1, 8 do roster[#roster + 1] = { src = id } end

        for _, point in pairs(Arena.PlanSpawns('sky', roster)) do
            local out = plane(point, { x = area.x, y = area.y })
            t.isTrue(out <= platform.radius,
                ('a fighter was placed %0.1fm out, past a %0.1fm floor -- in mid air'):format(out, platform.radius))
        end
    end
end)

t.test('a spawn Z below the floor is a typo an operator cannot diagnose', function()
    -- Which is why it is caught rather than trusted: under the arena there is
    -- nothing but a kilometre of air, the boundary kills them a second later,
    -- and the round reads as "the arena is broken".
    local Arena = envWith(function(arena)
        arena.spawnArea.center.z = arena.platform.z - 30.0
    end).Arena

    local floor = Arena.SpawnFloor('sky')
    local area = Arena.GetSpawnArea('sky')
    t.isTrue(area.z < floor,
        'this test no longer describes a spawn below the floor, so it proves nothing')
    -- The client clamps to this number; what is asserted here is that the
    -- number exists and is the floor, which is what makes the clamp possible.
    t.equals(floor, 1200.0)
end)

-- ======================================================================
-- THE ARENA GROWS WITH THE MATCH
--
-- Twenty fighters in a circle sized for six cannot be minSeparation apart.
-- The placement did not say so -- it quietly settled for less -- so an
-- operator's stated separation was never the separation anybody got, at any
-- roster size, and the first thing twenty players saw was each other.
-- ======================================================================

--- An env whose sky arena grows with the roster.
local function growingEnv(mutate)
    return envWith(function(arena)
        arena.scale = { enabled = true, baseline = 6, perPlayer = 1.6, maxGrowth = 2.0 }
        if mutate then mutate(arena) end
    end)
end

t.test('an arena that does not ask to grow never does', function()
    -- Every arena that shipped before this existed, and every arena on the
    -- ground. A geometry change nobody asked for is a change nobody can
    -- diagnose.
    local Arena = envWith().Arena
    for _, players in ipairs({ 0, 1, 6, 20, 200 }) do
        t.equals(Arena.SizeFactor('sky', players), 1.0)
    end
end)

t.test('and one that does stays exactly as configured up to its baseline', function()
    local Arena = growingEnv().Arena
    for _, players in ipairs({ 0, 2, 5, 6 }) do
        t.equals(Arena.SizeFactor('sky', players), 1.0,
            ('%d players moved an arena sized for six'):format(players))
    end
    t.equals(Arena.GetSpawnArea('sky', Arena.SizeFactor('sky', 6)).radius, 35.0)
end)

t.test('and grows past it, in metres of spawn radius per fighter', function()
    local Arena = growingEnv().Arena
    -- Fourteen fighters over the baseline at 1.6m each is 22.4m on a 35m
    -- radius: the arena is 64% bigger.
    local factor = Arena.SizeFactor('sky', 20)
    t.isTrue(math.abs(factor - (1.0 + (14 * 1.6) / 35.0)) < 0.0001,
        ('the growth came out at %0.4f'):format(factor))
    t.isTrue(Arena.GetSpawnArea('sky', factor).radius > 57.0)
end)

t.test('and never past the ceiling, however many turn up', function()
    local Arena = growingEnv().Arena
    t.equals(Arena.SizeFactor('sky', 500), 2.0, 'the ceiling was not applied')
end)

t.test('DEFECT: every radius grows together, so the arena stays a valid arena', function()
    -- THE RELATIONSHIPS ARE THE DESIGN. Spawns inside the floor, floor
    -- inside the boundary -- scaling any one of the three on its own breaks
    -- one of the two rules that keep people alive, and does it silently.
    local Arena = growingEnv().Arena

    for _, players in ipairs({ 6, 10, 16, 20, 32, 100 }) do
        local factor = Arena.SizeFactor('sky', players)
        local area = Arena.GetSpawnArea('sky', factor)
        local platform = Arena.GetPlatform('sky', factor)
        local boundary = 60.0 * factor

        t.isTrue(area.radius < platform.radius,
            ('%d players: the spawn ring (%0.1f) is wider than the floor (%0.1f)')
                :format(players, area.radius, platform.radius))
        t.isTrue(platform.radius < boundary,
            ('%d players: the floor (%0.1f) is wider than the boundary (%0.1f)')
                :format(players, platform.radius, boundary))
        t.isTrue(area.teamRadius < area.radius,
            ('%d players: a team spreads wider than the area it is in'):format(players))
    end
end)

t.test('and the cover layout grows with it rather than staying in a huddle', function()
    -- An outer ring that did not move would be an inner ring on a bigger
    -- floor, leaving the whole rim as open ground.
    local Arena = growingEnv().Arena
    local small = Arena.GetCover('sky', 1.0)
    local large = Arena.GetCover('sky', 2.0)

    t.equals(#small, #large, 'growing the arena changed how many pieces it has')
    for index, piece in ipairs(small) do
        t.isTrue(math.abs(large[index].x - piece.x * 2.0) < 0.0001,
            'a cover piece did not move out with the arena')
        t.equals(large[index].z, piece.z, 'growing the arena changed a cover height')
    end
end)

t.test('and the tile ceiling grows by the SQUARE, because a floor is a disc', function()
    -- A ceiling that grew linearly would cap a doubled arena back to a
    -- quarter of the floor it needs -- which is not a smaller arena, it is a
    -- small floor with a large spawn ring hanging off it.
    local Arena = growingEnv(function(arena) arena.platform.maxTiles = 100 end).Arena
    t.equals(Arena.GetPlatform('sky', 1.0).maxTiles, 100)
    t.equals(Arena.GetPlatform('sky', 2.0).maxTiles, 400)
end)

t.test('TWENTY FIGHTERS ALL LAND THE FULL minSeparation APART', function()
    -- THE REQUIREMENT, stated as a test. Twenty is the roster this arena was
    -- asked to hold, and "holds twenty" means twenty people who are not
    -- standing on each other when the countdown ends.
    --
    -- Before the arena grew, this was 6.11m against a stated 10.
    local Arena = growingEnv().Arena
    local factor = Arena.SizeFactor('sky', 20)
    local area = Arena.GetSpawnArea('sky', factor)

    -- Many rosters: one lucky arrangement proves nothing about the next one.
    for attempt = 1, 25 do
        local roster = {}
        for id = 1, 20 do roster[#roster + 1] = { src = id } end

        local plan = Arena.PlanSpawns('sky', roster, nil, factor)
        t.isNotNil(plan, 'twenty fighters produced no plan at all')

        local points = {}
        for _, point in pairs(plan) do points[#points + 1] = point end
        t.equals(#points, 20, 'not everybody got a spawn')

        local closest = math.huge
        for i = 1, #points do
            -- Inside the arena they were planned for, too.
            local dx, dy = points[i].x - area.x, points[i].y - area.y
            t.isTrue(math.sqrt(dx * dx + dy * dy) <= area.radius + 0.001,
                'a spawn landed outside the spawn area')
            for j = i + 1, #points do
                local ax, ay = points[i].x - points[j].x, points[i].y - points[j].y
                closest = math.min(closest, math.sqrt(ax * ax + ay * ay))
            end
        end

        t.isTrue(closest >= area.minSeparation,
            ('attempt %d: the closest two of twenty are %0.2fm apart, against a stated %0.1f')
                :format(attempt, closest, area.minSeparation))
    end
end)

t.test('DEFECT: cover does not eat the arena it is standing in', function()
    -- THE BUG THIS SEPARATES FROM. Cover used to be excluded at the full
    -- player separation -- ten metres from the centre of every barrier --
    -- which takes a 314 square-metre bite out of the arena per piece.
    -- Twenty pieces did that to more than the whole arena, so every
    -- placement fell through to the relaxation and NOBODY was ever
    -- minSeparation from anybody, at any roster size.
    --
    -- THE REAL ARENA, WITH ITS GROWTH SWITCHED OFF, and both halves of that
    -- are deliberate. It needs the shipped arena's twenty-odd cover pieces,
    -- because two test barriers do not eat an arena; and it needs the
    -- ungrown size, because a big enough circle has room for the mistake --
    -- which is exactly why a test of the grown arena would not notice this
    -- coming back.
    local env = Sandbox.newArenaEnv()
    env.Config.Arenas.skydome.scale.enabled = false
    local Arena = env.Arena

    local area = Arena.GetSpawnArea('skydome')
    t.isTrue(#Arena.GetCover('skydome') >= 12,
        'the shipped arena no longer has enough cover for this test to mean anything')

    -- SIXTY ROSTERS, because the failure this guards is probabilistic. The
    -- placement is rejection sampling: a defect here does not fail every
    -- round, it fails one in eight, which is exactly the kind of thing a
    -- five-attempt test lets through and a player notices.
    for attempt = 1, 60 do
        local roster = {}
        for id = 1, 8 do roster[#roster + 1] = { src = id } end

        local plan = Arena.PlanSpawns('skydome', roster)
        local points = {}
        for _, point in pairs(plan) do points[#points + 1] = point end

        local closest = math.huge
        for i = 1, #points do
            for j = i + 1, #points do
                local dx, dy = points[i].x - points[j].x, points[i].y - points[j].y
                closest = math.min(closest, math.sqrt(dx * dx + dy * dy))
            end
        end

        t.isTrue(closest >= area.minSeparation,
            ('attempt %d: eight fighters in an arena sized for them came out %0.2fm apart, against a stated %0.1f -- the cover is eating the arena')
                :format(attempt, closest, area.minSeparation))
    end
end)

t.test('and an operator can say how much room their own props need', function()
    local Arena = envWith(function(arena) arena.cover.clearance = 1.0 end).Arena
    t.equals(Arena.CoverClearance('sky'), 1.0)
    t.isTrue(Arena.CoverClearance('sky') < envWith().Arena.CoverClearance('sky'),
        'the configured clearance was ignored in favour of the default')
end)

t.test('and the shipped skydome is the one that grows', function()
    -- The operator asked for an arena that holds twenty. This is the setting
    -- that makes the one they run do it.
    local sky = Sandbox.shippedConfig().Arenas.skydome
    t.isNotNil(sky.scale, 'the shipped sky arena no longer scales')
    t.isTrue(sky.scale.enabled, 'scaling is switched off on the arena that needs it')
    t.isTrue(sky.scale.perPlayer > 0, 'it grows by nothing per player')
end)

-- ======================================================================
-- THE PROPS ARE REAL
-- ======================================================================

--- Every object name the base game and its DLC ship, as a set.
local function realObjects()
    local handle = assert(io.open('fixtures/gta-object-names.txt', 'r'),
        'the GTA object list fixture is missing -- see its header for how to regenerate it')
    local names = {}
    for line in handle:lines() do
        local name = line:match('^([a-z0-9_]+)$')
        if name then names[name] = true end
    end
    handle:close()
    return names
end

--- Every prop model config.lua names, across every arena -- INCLUDING THE
--- FALLBACKS.
---
--- Checking only the first of each chain would be worse than not checking:
--- a fallback is exactly the name nobody looks at, right up to the day the
--- primary is missing and it is the only thing standing between a round and
--- an arena with no floor.
local function configuredModels(config)
    local Arena = Sandbox.newArenaEnv().Arena
    local out, seen = {}, {}
    local function want(entry, where)
        for index, model in ipairs(Arena.ModelChain(entry)) do
            if not seen[model] then
                seen[model] = true
                out[#out + 1] = {
                    model = model,
                    where = ('%s#%d'):format(where, index),
                }
            end
        end
    end

    for key, arena in pairs(config.Arenas or {}) do
        if type(arena) == 'table' then
            if type(arena.platform) == 'table' then
                want(arena.platform, key .. '.platform')
            end
            for _, piece in ipairs((arena.cover or {}).pieces or {}) do
                want(piece, key .. '.cover')
            end
        end
    end
    return out
end

t.test('EVERY prop model config.lua names is a real GTA V object', function()
    -- A MODEL NAME THAT IS NOT REAL FAILS SILENTLY. The game does not raise:
    -- it simply never loads the model, the prop never appears, and what an
    -- operator sees is an arena with no floor in it and nothing anywhere
    -- saying why.
    --
    -- The first floor model written into config.lua was
    -- 'stt_prop_stunt_track_widey' -- remembered rather than looked up, and
    -- not a real object. Nothing in this suite could tell, because a prop
    -- name is a string until the game is asked. This asks a list of all
    -- 21,629 of them instead.
    local real = realObjects()
    t.isTrue(real['prop_container_01a'] == true,
        'the object list fixture did not load properly, so this test proves nothing')

    local models = configuredModels(Sandbox.shippedConfig())
    t.isTrue(#models > 0, 'no arena names any prop models, so this test proves nothing')
    t.isTrue(#models >= 5,
        ('only %d model(s) were found -- the fallback chains are not being walked'):format(#models))

    local missing = {}
    for _, entry in ipairs(models) do
        if not real[entry.model] then
            missing[#missing + 1] = ('%s (%s)'):format(entry.model, entry.where)
        end
    end
    table.sort(missing)

    t.equals(table.concat(missing, ', '), '',
        'these prop models are not real GTA V objects. The game will never load them, so the '
        .. 'props simply do not appear -- an arena with no floor, and nothing to say why. If one '
        .. 'is a model your own server streams, that is fine and this test needs to know about it')
end)

t.test('every prop has a fallback, so one missing model is not a missing arena', function()
    -- A name being real is not the same as it being on a given server: a
    -- build without a DLC has fewer objects than the game's own list does.
    -- And the first floor model this resource shipped was invented, which is
    -- the case a fallback is really for.
    local env = Sandbox.newArenaEnv()
    local sky = env.Config.Arenas.skydome

    t.isTrue(#env.Arena.ModelChain(sky.platform) >= 2,
        'the floor has no stand-in -- one missing model and the arena has no ground')

    for index, piece in ipairs(sky.cover.pieces) do
        t.isTrue(#env.Arena.ModelChain(piece) >= 2,
            ('cover piece %d has no stand-in'):format(index))
    end
end)

t.test('and a chain is tried in order, first name first', function()
    local Arena = Sandbox.newArenaEnv().Arena

    -- Both spellings, because `model = 'x'` stays valid on its own.
    t.equals(table.concat(Arena.ModelChain({ model = 'a', models = { 'b', 'c' } }), ','), 'a,b,c')
    t.equals(table.concat(Arena.ModelChain({ models = { 'b', 'c' } }), ','), 'b,c')
    t.equals(table.concat(Arena.ModelChain({ model = 'a' }), ','), 'a')
    -- A name twice is one name: it would only be tried twice for nothing.
    t.equals(table.concat(Arena.ModelChain({ model = 'a', models = { 'a', 'b' } }), ','), 'a,b')
    t.equals(#Arena.ModelChain({}), 0)
    t.equals(#Arena.ModelChain(nil), 0)
end)

t.test('and the model that was actually wrong is named, so a failure says which', function()
    -- Guards the guard: a fixture that quietly matched everything would let
    -- the original mistake straight back through.
    local real = realObjects()
    t.isNil(real['stt_prop_stunt_track_widey'],
        'the object list contains a name that is not a real object, so it cannot catch one')
    t.isTrue(real['stt_prop_stunt_bblock_huge_01'] == true,
        'the floor this arena is built from is not in the object list')
end)

-- ======================================================================
-- WHAT SHIPS
-- ======================================================================

t.test('the skydome and the trailer park are the arenas this server runs', function()
    -- The operator asked for the two shipped ground arenas off, and later
    -- for a third at their own coordinates. What matters is that SOMETHING
    -- is enabled: an arena list with nothing switched on is a panel that
    -- offers no match to create, which reads as a broken resource rather
    -- than as a decision.
    -- The SHIPPED config, untouched: newArenaEnv deliberately switches every
    -- arena on so the other specs can drive a match without caring which
    -- ones an operator runs.
    local config = Sandbox.shippedConfig()

    -- SORTED, because `pairs` has no order and this assertion used to depend
    -- on one. It passed for as long as the answer was a single key.
    local on = {}
    for key, arena in pairs(config.Arenas) do
        if arena.enabled ~= false then on[#on + 1] = key end
    end
    table.sort(on)

    t.equals(table.concat(on, ', '), 'skydome, trailerpark',
        'the enabled arenas are not the ones this server was set up to run')
end)

t.test('and the ground arenas are switched off, not deleted', function()
    -- Keeping the coordinates means turning one back on is one word rather
    -- than an afternoon with a map.
    local config = Sandbox.shippedConfig()
    for _, key in ipairs({ 'airfield', 'beach' }) do
        local arena = config.Arenas[key]
        t.isNotNil(arena, ('%s was deleted rather than disabled'):format(key))
        t.isFalse(arena.enabled)
        t.isTrue(#(arena.spawns or {}) > 0, ('%s lost the spawns that make it re-enableable'):format(key))
        t.isNotNil(arena.boundary, ('%s lost its boundary'):format(key))
    end
end)

t.test('and the shipped skydome is completely described', function()
    local env = Sandbox.newArenaEnv()

    local platform = env.Arena.GetPlatform('skydome')
    t.isNotNil(platform, 'the shipped sky arena has no floor described')
    t.isTrue(#env.Arena.PlatformTiles(platform, 0.0, 0.0) > 20, 'its floor is a handful of tiles')
    t.isTrue(#env.Arena.GetCover('skydome') > 0, 'it has nothing to hide behind')
    t.isTrue(env.Arena.UsesExactSpawnZ('skydome'),
        'the shipped sky arena would teleport everybody to the ground')

    local sky = env.Config.Arenas.skydome
    t.isTrue(sky.platform.radius < sky.boundary.radius)
    t.isTrue(sky.spawnArea.radius < sky.platform.radius)
end)

os.exit(t.summary())
