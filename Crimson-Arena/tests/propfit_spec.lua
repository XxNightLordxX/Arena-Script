--[[
    crimson_arena/tests/propfit_spec.lua

    HOW THE BUILT ARENA LOOKS, not whether it exists.

    Reported from a live server: "props spawn but it looks glitchy as hell."
    Everything else in this suite asks whether a piece is THERE -- is the
    floor whole, is the spawn on it, does it come down again. None of it
    asks whether two pieces are standing in the same place, and two props
    sharing a volume is exactly what "glitchy as hell" describes: surfaces
    that flicker against each other because the renderer has no way to
    decide which one is in front, and corners poking out of each other.

    Four properties, all of them geometric and all of them checkable without
    the game:

      TILES MEET, THEY DO NOT       edge to edge on both axes. Overlapping
      OVERLAP                       tiles z-fight along every seam; separated
                                    ones leave a slot to fall through.

      NO TWO PIECES SHARE A         cover against cover, cover against floor.
      VOLUME

      COVER STANDS ON THE FLOOR,    a barrier hanging over the rim looks like
      NOT OVER THE EDGE OF IT       it is floating, because it is.

      AND IT ALL HOLDS AT EVERY     the arena grows with the roster, and
      SIZE THE ARENA GROWS TO       growth moves cover and floor by different
                                    rules -- which is where a layout that is
                                    fine at six fighters stops being fine at
                                    twenty.

    Sizes are taken from the same measurement the client feeds in, so a prop
    whose bounding box is not its tile size is tested rather than assumed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('propfit_spec')

local CENTRE = { x = 1500.0, y = 3000.0, z = 1201.0 }

--- A sky arena with a floor and a ring of cover on it.
--- @param mutate fun(arena: table)?
local function envWith(mutate)
    local env = Sandbox.newArenaEnv()
    local arena = {
        label = 'Skydome',
        enabled = true,
        platform = { enabled = true, model = 'test_floor', tileSize = 8.0, radius = 45.0, z = 1200.0 },
        cover = {
            enabled = true,
            pieces = {
                { model = 'test_block', x = 26.0, y = 0.0, z = 0.0, heading = 90.0 },
                { model = 'test_block', x = 18.4, y = 18.4, z = 0.0, heading = 135.0 },
                { model = 'test_block', x = 0.0, y = 26.0, z = 0.0, heading = 180.0 },
                { model = 'test_block', x = -18.4, y = 18.4, z = 0.0, heading = 225.0 },
                { model = 'test_block', x = -26.0, y = 0.0, z = 0.0, heading = 270.0 },
                { model = 'test_block', x = -18.4, y = -18.4, z = 0.0, heading = 315.0 },
                { model = 'test_block', x = 0.0, y = -26.0, z = 0.0, heading = 0.0 },
                { model = 'test_block', x = 18.4, y = -18.4, z = 0.0, heading = 45.0 },
            },
        },
        exactSpawnZ = true,
        spawnArea = {
            enabled = true,
            center = { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z },
            radius = 35.0, minSeparation = 10.0, teamRadius = 16.0,
        },
        spawns = { { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z, w = 0.0 } },
        boundary = { enabled = true, center = { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z }, radius = 90.0 },
    }
    if mutate then mutate(arena) end
    env.Config.Arenas = { sky = arena }
    return env
end

--- The floor pieces of a build, in world coordinates.
local function floorOf(props)
    local out = {}
    for _, piece in ipairs(props) do
        if piece.kind == 'floor' then out[#out + 1] = piece end
    end
    return out
end

local function coverOf(props)
    local out = {}
    for _, piece in ipairs(props) do
        if piece.kind == 'cover' then out[#out + 1] = piece end
    end
    return out
end

--- How far two axis-aligned footprints overlap on each axis. Positive on
--- both means they are in each other; zero means they touch.
--- @return number gapX, number gapY -- overlap depth, 0 when they only meet
local function overlap(a, b, aSize, bSize)
    local reachX = (aSize.x + bSize.x) * 0.5
    local reachY = (aSize.y + bSize.y) * 0.5
    return reachX - math.abs(a.x - b.x), reachY - math.abs(a.y - b.y)
end

-- ======================================================================
-- TILES MEET, THEY DO NOT OVERLAP
-- ======================================================================

--- Every pair of tiles, checked for a shared volume.
--- @return table|nil -- the offending pair, or nil
local function overlappingTiles(tiles, sizeX, sizeY)
    -- 1mm of slack: a floating-point seam is not an overlap, and asserting
    -- on exact equality of sums of floats is a test that fails on arithmetic
    -- rather than on geometry.
    local slack = 0.001
    local size = { x = sizeX, y = sizeY }
    for i = 1, #tiles do
        for j = i + 1, #tiles do
            local gapX, gapY = overlap(tiles[i], tiles[j], size, size)
            if gapX > slack and gapY > slack then
                return { tiles[i], tiles[j], gapX, gapY }
            end
        end
    end
    return nil
end

t.test('DEFECT: no two floor tiles stand in the same place', function()
    -- TWO SURFACES IN ONE PLANE IS THE FLICKER. The renderer has nothing to
    -- break the tie with, so the seam shimmers as the camera moves -- and it
    -- shimmers across the whole floor, not at one corner.
    local Arena = envWith().Arena
    local tiles = floorOf(Arena.ArenaProps('sky', { x = 8.0, y = 8.0, top = 1.0 }))

    t.isTrue(#tiles > 40, ('only %d tiles -- the floor is too small to test'):format(#tiles))
    local clash = overlappingTiles(tiles, 8.0, 8.0)
    t.isNil(clash and ('%.2f,%.2f overlaps %.2f,%.2f by %.3fm x %.3fm')
        :format(clash[1].x, clash[1].y, clash[2].x, clash[2].y, clash[3], clash[4]))
end)

t.test('and none of them is a duplicate of another', function()
    -- The cheapest way to get a flickering floor: build the same tile twice.
    local Arena = envWith().Arena
    local seen = {}
    for _, tile in ipairs(floorOf(Arena.ArenaProps('sky', { x = 8.0, y = 8.0, top = 1.0 }))) do
        local key = ('%.3f/%.3f'):format(tile.x, tile.y)
        t.isNil(seen[key], ('two tiles at %s'):format(key))
        seen[key] = true
    end
end)

t.test('and they meet exactly, whatever the prop measures', function()
    -- Edge to edge on BOTH axes and at every size: a tile that steps by less
    -- than it measures overlaps its neighbour, and one that steps by more
    -- leaves a slot to fall through. Checked against the measurement rather
    -- than against tileSize, because the client measures the model it got.
    for _, size in ipairs({
        { x = 8.0, y = 8.0 }, { x = 3.25, y = 3.25 }, { x = 12.0, y = 4.0 },
        { x = 4.0, y = 12.0 }, { x = 0.75, y = 1.6 }, { x = 60.0, y = 60.0 },
    }) do
        local Arena = envWith().Arena
        local tiles = floorOf(Arena.ArenaProps('sky', { x = size.x, y = size.y, top = 1.0 }))
        t.isTrue(#tiles > 0, ('no floor at all for a %.2fx%.2f prop'):format(size.x, size.y))

        local clash = overlappingTiles(tiles, size.x, size.y)
        t.isNil(clash and ('a %.2fx%.2f prop overlaps itself by %.3fm x %.3fm')
            :format(size.x, size.y, clash[3], clash[4]))

        -- And the other half: every neighbour is exactly one step away, so
        -- there is no seam wider than the arithmetic.
        for _, tile in ipairs(tiles) do
            local offX = (tile.x - CENTRE.x) / size.x
            local offY = (tile.y - CENTRE.y) / size.y
            t.isTrue(math.abs(offX - math.floor(offX + 0.5)) < 1e-6,
                ('a tile is off the %.2fm grid on x'):format(size.x))
            t.isTrue(math.abs(offY - math.floor(offY + 0.5)) < 1e-6,
                ('a tile is off the %.2fm grid on y'):format(size.y))
        end
    end
end)

t.test('and the whole floor is one plane, so nothing steps or clips', function()
    local Arena = envWith().Arena
    local tiles = floorOf(Arena.ArenaProps('sky', { x = 8.0, y = 8.0, top = 1.4 }))
    local first = tiles[1].z
    for _, tile in ipairs(tiles) do
        t.equals(tile.z, first, 'a tile sits at a different height from its neighbours')
    end
end)

-- ======================================================================
-- NO TWO PIECES SHARE A VOLUME
-- ======================================================================

--- Cover is placed by its own centre and can be rotated, so its footprint is
--- taken as the circle its longest half-diagonal sweeps -- the shape it
--- occupies at ANY heading. Two of those touching is two props touching at
--- some rotation, which is the case worth failing on.
local function coverClashes(pieces, span)
    for i = 1, #pieces do
        for j = i + 1, #pieces do
            local dx = pieces[i].x - pieces[j].x
            local dy = pieces[i].y - pieces[j].y
            local apart = math.sqrt(dx * dx + dy * dy)
            if apart < span then return { pieces[i], pieces[j], apart } end
        end
    end
    return nil
end

t.test('DEFECT: no two cover pieces are standing in each other', function()
    -- A 4m container swings a 2.83m half-diagonal, so two of them are clear
    -- of each other at any heading from 5.66m apart.
    local Arena = envWith().Arena
    local pieces = coverOf(Arena.ArenaProps('sky', { x = 8.0, y = 8.0, top = 1.0 }))

    t.isTrue(#pieces >= 8, 'the fixture stopped having cover to test')
    local clash = coverClashes(pieces, 5.66)
    t.isNil(clash and ('two pieces are %.2fm apart at %.1f,%.1f'):format(clash[3], clash[1].x, clash[1].y))
end)

t.test('and the shipped skydome layout is clear of itself too', function()
    -- The fixture above proves the CHECK; this proves the arena operators
    -- actually get. A layout that reads fine in config and puts two barriers
    -- through each other in the world is the whole complaint.
    local env = Sandbox.newArenaEnv()
    local pieces = coverOf(env.Arena.ArenaProps('skydome', { x = 8.0, y = 8.0, top = 1.0 }))
    t.isTrue(#pieces > 0, 'the skydome ships with no cover at all')

    local clash = coverClashes(pieces, 5.66)
    t.isNil(clash and ('the shipped layout puts two pieces %.2fm apart'):format(clash[3]))
end)

t.test('and it is still clear of itself at the twenty-player size', function()
    -- Growth scales the offsets, so pieces move APART rather than together
    -- -- but that is a property of the formula, not a promise, and this is
    -- the size the arena is advertised to hold.
    local env = Sandbox.newArenaEnv()
    local factor = env.Arena.SizeFactor('skydome', 20)
    t.isTrue(factor > 1.0, 'the skydome stopped growing with the roster')

    local pieces = coverOf(env.Arena.ArenaProps('skydome', { x = 8.0, y = 8.0, top = 1.0 }, factor))
    local clash = coverClashes(pieces, 5.66)
    t.isNil(clash and ('at %.2fx growth two pieces are %.2fm apart'):format(factor, clash[3]))
end)

-- ======================================================================
-- COVER STANDS ON THE FLOOR, NOT OVER THE EDGE OF IT
-- ======================================================================

--- The tile a point is on, if any.
local function tileUnder(tiles, x, y, sizeX, sizeY)
    for _, tile in ipairs(tiles) do
        if math.abs(x - tile.x) <= sizeX * 0.5 + 1e-6
            and math.abs(y - tile.y) <= sizeY * 0.5 + 1e-6 then
            return tile
        end
    end
    return nil
end

--- Every corner of a piece's swept footprint, so an overhang on any side is
--- caught rather than only one at the centre.
local function cornersOf(piece, half)
    return {
        { x = piece.x - half, y = piece.y - half },
        { x = piece.x + half, y = piece.y - half },
        { x = piece.x - half, y = piece.y + half },
        { x = piece.x + half, y = piece.y + half },
        { x = piece.x, y = piece.y },
    }
end

t.test('DEFECT: every cover piece has floor under all four corners', function()
    -- A barrier half over the rim is standing on nothing on one side, and
    -- that is what it looks like: floating, with a shadow onto empty air.
    local env = Sandbox.newArenaEnv()
    local props = env.Arena.ArenaProps('skydome', { x = 8.0, y = 8.0, top = 1.0 })
    local tiles, pieces = floorOf(props), coverOf(props)
    t.isTrue(#tiles > 0 and #pieces > 0, 'the skydome built no floor or no cover')

    for _, piece in ipairs(pieces) do
        for _, corner in ipairs(cornersOf(piece, 2.0)) do
            t.isNotNil(tileUnder(tiles, corner.x, corner.y, 8.0, 8.0),
                ('a piece at %.1f,%.1f hangs over the edge'):format(piece.x, piece.y))
        end
    end
end)

t.test('and it still does at the largest roster the arena takes', function()
    local env = Sandbox.newArenaEnv()
    local factor = env.Arena.SizeFactor('skydome', 20)
    local props = env.Arena.ArenaProps('skydome', { x = 8.0, y = 8.0, top = 1.0 }, factor)
    local tiles, pieces = floorOf(props), coverOf(props)

    for _, piece in ipairs(pieces) do
        for _, corner in ipairs(cornersOf(piece, 2.0)) do
            t.isNotNil(tileUnder(tiles, corner.x, corner.y, 8.0, 8.0),
                ('at %.2fx growth a piece at %.1f,%.1f hangs over the edge'):format(factor, piece.x, piece.y))
        end
    end
end)

t.test('and the floor under it is the same plane the cover is placed against', function()
    -- Cover is offset from the spawn centre and the floor is hung from
    -- platform.z. Those are two different numbers in config, and a build
    -- where they disagree buries the barriers or floats them.
    local env = Sandbox.newArenaEnv()
    local props = env.Arena.ArenaProps('skydome', { x = 8.0, y = 8.0, top = 1.4 })
    local tiles, pieces = floorOf(props), coverOf(props)

    local surface = tiles[1].z + 1.4
    for _, piece in ipairs(pieces) do
        t.isTrue(math.abs(piece.z - surface) < 0.001,
            ('a piece sits %.3fm off the walkable surface'):format(piece.z - surface))
    end
end)

-- ======================================================================
-- AND THE TRAILER PARK, WHICH BUILDS NOTHING
-- ======================================================================

t.test('the trailer park puts no prop of its own on the map', function()
    -- The one arena where a prop IS a bug: there is already a trailer park
    -- standing here, and a container dropped at a config offset goes through
    -- somebody's caravan.
    local env = Sandbox.newArenaEnv()
    local props = env.Arena.ArenaProps('trailerpark', { x = 8.0, y = 8.0, top = 1.0 })
    t.equals(#props, 0, 'the trailer park built scenery onto real ground')
end)

t.test('and its boundary is well outside the ring it spawns people in', function()
    -- The complaint was that it bled fighters for walking around the park
    -- they came here to fight in.
    local env = Sandbox.newArenaEnv()
    local arena = env.Config.Arenas['trailerpark']
    t.isTrue(arena.boundary.radius >= arena.spawnArea.radius * 2.0,
        ('a %.0fm boundary around a %.0fm spawn ring is not much room')
            :format(arena.boundary.radius, arena.spawnArea.radius))

    -- And at the size it grows to, because both scale together.
    local factor = env.Arena.SizeFactor('trailerpark', 20)
    t.isTrue(factor > 1.0, 'the trailer park does not grow with the roster')
    t.isTrue(arena.boundary.radius * factor >= arena.spawnArea.radius * factor * 2.0,
        'the boundary stops being generous once the arena grows')
end)

os.exit(t.summary())
