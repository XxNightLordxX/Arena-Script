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

t.test('the tiles cover a DISC, and every one is inside the radius', function()
    -- A square floor would put its corners outside the boundary sphere, so a
    -- fighter standing in one would be bleeding while on solid ground.
    local Arena = envWith().Arena
    local platform = Arena.GetPlatform('sky')
    local tiles = Arena.PlatformTiles(platform, CENTRE.x, CENTRE.y)

    t.isTrue(#tiles > 20, ('a 45m floor of 8m tiles produced only %d pieces'):format(#tiles))

    local corners = 0
    for _, tile in ipairs(tiles) do
        local out = plane(tile, CENTRE)
        t.isTrue(out <= platform.radius,
            ('a floor tile sits %0.1fm out, past a %0.1fm platform'):format(out, platform.radius))
        if out > platform.radius - platform.tileSize then corners = corners + 1 end
    end
    t.isTrue(corners > 0, 'nothing reaches the rim, so the floor is smaller than it claims')
end)

t.test('and they all sit at the platform height, not the spawn height', function()
    -- Two different numbers on purpose: the prop ORIGIN and the surface a
    -- player stands on are not the same place, and how far apart depends on
    -- the model.
    local Arena = envWith().Arena
    for _, tile in ipairs(Arena.PlatformTiles(Arena.GetPlatform('sky'), CENTRE.x, CENTRE.y)) do
        t.equals(tile.z, 1200.0)
    end
end)

t.test('the whole floor fits inside the boundary that kills for leaving it', function()
    -- The relationship that makes stepping off the edge lethal without a
    -- line of falling code: the floor ends before the sphere does.
    local config = envWith().Config
    local arena = config.Arenas.sky
    t.isTrue(arena.platform.radius < arena.boundary.radius,
        'the floor reaches past the boundary, so there is solid ground out of bounds')
    t.isTrue(arena.spawnArea.radius < arena.platform.radius,
        'a spawn can land past the edge of the floor')
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
    -- seeded into the same list of things to stay away from.
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
                t.isTrue(gap >= area.minSeparation * 0.6,
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

t.test('the skydome is the arena this server runs, and the only one', function()
    -- The operator asked for the ground arenas off. What matters is that
    -- SOMETHING is enabled: an arena list with nothing switched on is a panel
    -- that offers no match to create, which reads as a broken resource rather
    -- than as a decision.
    -- The SHIPPED config, untouched: newArenaEnv deliberately switches every
    -- arena on so the other specs can drive a match without caring which
    -- ones an operator runs.
    local config = Sandbox.shippedConfig()

    local on = {}
    for key, arena in pairs(config.Arenas) do
        if arena.enabled ~= false then on[#on + 1] = key end
    end

    t.equals(table.concat(on, ', '), 'skydome',
        'the enabled arenas are not the one this server was set up to run')
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
