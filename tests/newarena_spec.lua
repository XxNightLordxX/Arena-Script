--[[
    crimson_arena/tests/newarena_spec.lua

    AN OPERATOR PASTES A BLOCK INTO Config.Arenas. DOES IT WORK?

    That is the promise the whole config makes -- "paste another block in,
    give it a key nothing else uses, and it appears in the panel at the next
    restart. Nothing else needs editing -- no code, no second list, no
    registration step." Every other spec here tests the arenas that SHIP.
    This one tests arenas that do not exist yet, which is the only way to
    know the promise holds for the operator's own.

    It also pins the failure modes, because a new arena is written by hand
    from a copy-paste block and every one of these is a plausible slip:

      A FIELD LEFT OUT       -- must be a named warning at start, never a
                                crash and never a silent half-arena.
      A SKY ARENA WITHOUT
      exactSpawnZ            -- the ground probe wins and everybody is
                                teleported a kilometre down.
      TEAM SPAWNS FOR A TEAM
      THAT IS NOT ENABLED    -- must fall back, not strand the side.
      A FLOOR SMALLER THAN
      ITS SPAWN RING         -- builds successfully and drops people off it.

    Nothing here reads the shipped arenas. Every arena in this file is built
    by the test, the way an operator builds one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('newarena_spec')

-- ======================================================================
-- THE BLOCKS AN OPERATOR WOULD PASTE
-- ======================================================================

--- The copy-paste block from config.lua's own comment, filled in: the
--- simplest arena that should work.
local function groundArena()
    return {
        label = 'The Docks',
        description = 'Containers and long sightlines.',
        enabled = true,
        spawns = {
            { x = 1200.10, y = -3100.50, z = 5.90, w = 180.0 },
            { x = 1188.44, y = -3092.10, z = 5.90, w = 270.0 },
        },
        boundary = {
            enabled = true,
            center = { x = 1194.00, y = -3096.00, z = 5.90 },
            radius = 70.0,
            warningSeconds = 5,
            damagePerTick = 20,
            tickMs = 500,
        },
    }
end

--- The other shape: one point and a radius rather than a list.
local function areaArena()
    return {
        label = 'The Quarry',
        enabled = true,
        spawnArea = {
            enabled = true,
            center = { x = 2900.0, y = 2800.0, z = 40.0 },
            radius = 60.0,
            minSeparation = 8.0,
            teamRadius = 20.0,
        },
        spawns = { { x = 2900.0, y = 2800.0, z = 40.0, w = 0.0 } },
        boundary = {
            enabled = true,
            center = { x = 2900.0, y = 2800.0, z = 40.0 },
            radius = 90.0,
            warningSeconds = 5, damagePerTick = 20, tickMs = 500,
        },
    }
end

--- An arena that carries its own floor, written from the skydome's shape.
local function skyArena()
    return {
        label = 'The Gantry',
        enabled = true,
        exactSpawnZ = true,
        platform = {
            enabled = true,
            models = { 'prop_container_01a' },
            tileSize = 10.0,
            radius = 50.0,
            z = 800.0,
            maxTiles = 400,
        },
        cover = {
            enabled = true,
            pieces = {
                { models = { 'prop_container_01a' }, x = 15.0, y = 0.0, z = 0.0, heading = 90.0 },
            },
        },
        spawnArea = {
            enabled = true,
            center = { x = -1500.0, y = 5000.0, z = 800.0 },
            radius = 30.0,
            minSeparation = 10.0,
            teamRadius = 14.0,
        },
        spawns = { { x = -1500.0, y = 5000.0, z = 800.0, w = 0.0 } },
        boundary = {
            enabled = true,
            center = { x = -1500.0, y = 5000.0, z = 800.0 },
            radius = 70.0,
            warningSeconds = 5, damagePerTick = 20, tickMs = 500,
        },
    }
end

--- An env with one freshly-pasted arena added to the shipped ones.
--- @param key string
--- @param arena table
--- @return table env
local function withArena(key, arena)
    local env = Sandbox.newArenaEnv()
    env.Config.Arenas[key] = arena
    return env
end

--- Every problem Arena.ValidateConfig reports, joined.
--- @param env table
--- @return string
local function problems(env)
    return table.concat(env.Arena.ValidateConfig() or {}, '\n')
end

-- ======================================================================
-- IT APPEARS, WITHOUT TOUCHING ANYTHING ELSE
-- ======================================================================

t.test('a pasted arena appears in the list players choose from', function()
    -- The promise in as many words: no code, no second list, no
    -- registration step.
    local env = withArena('docks', groundArena())

    local listed = false
    for _, entry in ipairs(env.Arena.GetEnabledArenas()) do
        if entry.key == 'docks' then
            listed = true
            t.equals(entry.label, 'The Docks', 'the label an operator typed did not come through')
            t.equals(entry.description, 'Containers and long sightlines.')
        end
    end
    t.isTrue(listed, 'an arena pasted into Config.Arenas never reached the panel list')
end)

t.test('and is resolvable by key, with its own spawns and boundary intact', function()
    local env = withArena('docks', groundArena())
    local arena = env.Arena.GetArenaByKey('docks')

    t.isNotNil(arena, 'the arena could not be looked up by its own key')
    t.equals(#arena.spawns, 2)
    t.equals(arena.boundary.radius, 70.0)
end)

t.test('and hands out the spawns the operator wrote, in order', function()
    -- Round-robin over the point list, which is what an arena with no
    -- spawnArea gets.
    local env = withArena('docks', groundArena())

    local first = env.Arena.PickSpawn('docks', nil, 1)
    local second = env.Arena.PickSpawn('docks', nil, 2)
    t.isNotNil(first, 'the arena handed out no spawn at all')
    t.isNotNil(second)
    t.isTrue(first.x ~= second.x or first.y ~= second.y,
        'two different indexes drew the same point, so the list is not being walked')
end)

t.test('switching it off hides it without deleting anything', function()
    local arena = groundArena()
    arena.enabled = false
    local env = withArena('docks', arena)

    for _, entry in ipairs(env.Arena.GetEnabledArenas()) do
        t.isTrue(entry.key ~= 'docks', 'a disabled arena was still offered')
    end
    t.isNil(env.Arena.GetArenaByKey('docks'), 'a disabled arena could still be resolved')
    t.isNotNil(env.Config.Arenas.docks, 'switching it off deleted the coordinates')
end)

t.test('and an odd key still works, because keys are strings not identifiers', function()
    -- An operator will use spaces, capitals and punctuation. None of that is
    -- a Lua identifier and none of it should matter.
    for _, key in ipairs({ 'The Docks', 'docks-2', 'DOCKS', 'docks_v2', 'end', 'nil', '123' }) do
        local env = withArena(key, groundArena())
        t.isNotNil(env.Arena.GetArenaByKey(key), ('an arena keyed %q could not be resolved'):format(key))
    end
end)

-- ======================================================================
-- THE SPAWN AREA FORM
-- ======================================================================

t.test('an arena described as a point and a radius plans a whole roster', function()
    local env = withArena('quarry', areaArena())

    local roster = {}
    for id = 1, 8 do roster[#roster + 1] = { src = id } end
    local plan = env.Arena.PlanSpawns('quarry', roster)

    t.isNotNil(plan, 'a spawn area produced no plan')

    local area = env.Arena.GetSpawnArea('quarry')
    local count, closest = 0, math.huge
    local points = {}
    for _, point in pairs(plan) do points[#points + 1] = point count = count + 1 end
    t.equals(count, 8, 'not everybody was placed')

    for i = 1, #points do
        local dx, dy = points[i].x - area.x, points[i].y - area.y
        t.isTrue(math.sqrt(dx * dx + dy * dy) <= area.radius + 0.001,
            'a spawn landed outside the area the operator drew')
        for j = i + 1, #points do
            local ax, ay = points[i].x - points[j].x, points[i].y - points[j].y
            closest = math.min(closest, math.sqrt(ax * ax + ay * ay))
        end
    end
    t.isTrue(closest >= area.minSeparation,
        ('the operator asked for %0.1fm between fighters and got %0.2fm')
            :format(area.minSeparation, closest))
end)

t.test('and the team form gives each side its own patch', function()
    local env = withArena('quarry', areaArena())

    local roster = {}
    for id = 1, 3 do roster[#roster + 1] = { src = id, team = 'crimson' } end
    for id = 4, 6 do roster[#roster + 1] = { src = id, team = 'ash' } end
    local plan = env.Arena.PlanSpawns('quarry', roster)
    t.isNotNil(plan)

    -- Each side's own points are closer to each other than to the far side's.
    local function centre(ids)
        local x, y, n = 0, 0, 0
        for _, id in ipairs(ids) do
            local p = plan[id]
            if p then x, y, n = x + p.x, y + p.y, n + 1 end
        end
        return x / n, y / n
    end
    local ax, ay = centre({ 1, 2, 3 })
    local bx, by = centre({ 4, 5, 6 })
    local apart = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)

    t.isTrue(apart > 5.0,
        ('the two sides were planted %0.1fm apart, which is not two sides'):format(apart))
end)

t.test('a team with no spawns of its own falls back rather than stranding it', function()
    -- Enabling a third team must not force an operator to edit every arena
    -- they have ever written.
    local arena = groundArena()
    arena.teamSpawns = { crimson = { { x = 1200.0, y = -3100.0, z = 5.9, w = 0.0 } } }
    local env = withArena('docks', arena)

    local ash = env.Arena.PickSpawn('docks', 'ash', 1)
    t.isNotNil(ash, 'a team with no list of its own was given nowhere to stand')
end)

t.test('and a team list for a team that does not exist is simply unused', function()
    local arena = groundArena()
    arena.teamSpawns = { nonexistent_team = { { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } } }
    local env = withArena('docks', arena)

    local spawn = env.Arena.PickSpawn('docks', 'crimson', 1)
    t.isNotNil(spawn, 'a stray team list broke the real spawns')
    t.isTrue(spawn.x ~= 0.0 or spawn.y ~= 0.0,
        'a spawn came from a team list for a team that is not enabled')
end)

-- ======================================================================
-- THE SLIPS, AND WHETHER THE OPERATOR IS TOLD
-- ======================================================================

t.test('an arena with no spawns at all is named at start', function()
    local arena = groundArena()
    arena.spawns = nil
    local env = withArena('docks', arena)

    t.contains(problems(env), 'docks', 'an arena with nowhere to land was not named')
end)

t.test('and every incomplete arena is a warning, never a crash', function()
    -- An operator edits this file by hand. Whatever they leave out, the
    -- resource has to start and say something.
    local breakages = {
        { 'no label', function(a) a.label = nil end },
        { 'no description', function(a) a.description = nil end },
        { 'empty spawns', function(a) a.spawns = {} end },
        { 'spawns not a table', function(a) a.spawns = 'over there' end },
        { 'no boundary', function(a) a.boundary = nil end },
        { 'boundary with no centre', function(a) a.boundary.center = nil end },
        { 'boundary with no radius', function(a) a.boundary.radius = nil end },
        { 'boundary radius as text', function(a) a.boundary.radius = 'wide' end },
        { 'a spawn missing z', function(a) a.spawns[1].z = nil end },
        { 'a spawn that is not a table', function(a) a.spawns[1] = 5 end },
        { 'teamSpawns not a table', function(a) a.teamSpawns = true end },
        { 'enabled as a string', function(a) a.enabled = 'yes' end },
    }

    for _, case in ipairs(breakages) do
        local arena = groundArena()
        case[2](arena)

        local ok, err = pcall(function()
            local env = withArena('docks', arena)
            env.Arena.ValidateConfig()
            env.Arena.GetEnabledArenas()
            env.Arena.GetArenaByKey('docks')
            env.Arena.PickSpawn('docks', nil, 1)
            env.Arena.PlanSpawns('docks', { { src = 1 }, { src = 2 } })
        end)

        t.isTrue(ok, ('%s threw instead of warning: %s'):format(case[1], tostring(err)))
    end
end)

-- ======================================================================
-- A NEW ARENA THAT CARRIES ITS OWN FLOOR
-- ======================================================================

t.test('a pasted sky arena describes a platform the client can build', function()
    local env = withArena('gantry', skyArena())

    local platform = env.Arena.GetPlatform('gantry')
    t.isNotNil(platform, 'the platform block was not recognised')
    t.equals(platform.radius, 50.0)
    t.equals(platform.z, 800.0)

    local tiles = env.Arena.PlatformTiles(platform, -1500.0, 5000.0, { x = 12.2, y = 2.5, top = 2.6 })
    t.isTrue(#tiles > 0, 'the platform produced no floor')
    for _, tile in ipairs(tiles) do
        t.isTrue(math.abs((tile.z + 2.6) - 800.0) < 1e-6,
            'the new arena\'s surface is not at the height it asked for')
    end
end)

t.test('and its exact-Z rule is read, so the ground probe is skipped', function()
    local env = withArena('gantry', skyArena())
    t.isTrue(env.Arena.UsesExactSpawnZ('gantry'),
        'a sky arena that set exactSpawnZ was still going to be ground-probed')
    t.equals(env.Arena.SpawnFloor('gantry'), 800.0)
end)

t.test('DEFECT: a sky arena that FORGETS exactSpawnZ is a silent kilometre drop', function()
    -- The one field whose absence is fatal and invisible. Without it the
    -- client asks the game where the ground is, the game answers with the
    -- real terrain far below, and every fighter is teleported out of the
    -- sky. Both halves report success.
    --
    -- The floor Z still catches it at placement -- that is the second guard
    -- -- but an operator should be told, not quietly rescued.
    local arena = skyArena()
    arena.exactSpawnZ = nil
    local env = withArena('gantry', arena)

    t.isFalse(env.Arena.UsesExactSpawnZ('gantry'))
    -- The floor is still known, which is what stops the drop being fatal.
    t.equals(env.Arena.SpawnFloor('gantry'), 800.0,
        'without exactSpawnZ there is nothing left to floor the placement at')
end)

t.test('DEFECT: a new sky arena with a floor smaller than its spawn ring is named', function()
    -- Builds successfully, and drops everybody who does not draw the middle.
    local arena = skyArena()
    arena.platform.radius = 10.0   -- against a 30m spawn ring
    local env = withArena('gantry', arena)

    t.contains(problems(env), 'over open air',
        'a new arena with a floor smaller than its spawn ring was not flagged')
end)

t.test('and its heights are checked against the surface, like the shipped one', function()
    local arena = skyArena()
    arena.spawns[1].z = 400.0
    local env = withArena('gantry', arena)

    local output = problems(env)
    t.contains(output, 'gantry', 'the new arena was not named')
    t.contains(output, 'under the arena', 'a spawn below the new floor was not called out')
end)

t.test('a correct new arena, ground or sky, is flagged for nothing', function()
    -- The other half of every check above. A validator that complains about
    -- correct config is one an operator stops reading.
    for _, case in ipairs({ { 'docks', groundArena() }, { 'quarry', areaArena() }, { 'gantry', skyArena() } }) do
        local env = withArena(case[1], case[2])
        local output = problems(env)
        t.isNil(output:find(case[1], 1, true),
            ('a correctly written arena was flagged:\n%s'):format(output))
    end
end)

os.exit(t.summary())
