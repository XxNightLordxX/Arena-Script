package.path = './?.lua;' .. package.path
local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- ========================================================================
-- WHERE EVERYBODY LANDS
--
-- An operator sets ONE point and a radius. The arena works out the rest:
-- everybody somewhere random inside the circle, nobody on top of anybody,
-- and in a team mode each team together on its own side of it.
--
-- These assert PROPERTIES rather than coordinates, because the placement is
-- random by design and a test that pins exact numbers would either be
-- asserting the random number generator or would have to defeat it. What
-- matters is true of every arrangement it can produce: inside the area, far
-- enough apart, teams not interleaved.
-- ========================================================================

local AREA = { x = 1000.0, y = 2000.0, z = 30.0 }

--- @param overrides table? -- merged into the spawn area
local function envWith(overrides)
    local env = Sandbox.newArenaEnv()
    env.Config.Arenas = {
        ring = {
            label = 'Ring',
            enabled = true,
            spawnArea = {
                enabled = true,
                center = { x = AREA.x, y = AREA.y, z = AREA.z },
                radius = 100.0,
                minSeparation = 12.0,
                teamRadius = 25.0,
            },
            spawns = { { x = 1.0, y = 2.0, z = 3.0, w = 0.0 } },
        },
    }
    for key, value in pairs(overrides or {}) do
        env.Config.Arenas.ring.spawnArea[key] = value
    end
    return env
end

--- A roster of `count` players, optionally split across `teams`.
local function roster(count, teams)
    local out = {}
    for index = 1, count do
        local team = teams and teams[((index - 1) % #teams) + 1] or nil
        out[#out + 1] = { src = index, team = team }
    end
    return out
end

--- A deterministic stand-in for math.random, so a failure is reproducible.
--- Not uniform and not trying to be: it only has to be spread out enough to
--- exercise the placement, and the SAME every run.
local function seeded(seed)
    local state = seed or 1
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

local function distance(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function fromCentre(p)
    return distance(p, AREA)
end

-- ------------------------------------------------------------------
-- Free for all
-- ------------------------------------------------------------------

t.test('every player gets a place, and it is inside the area', function()
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(12), seeded(7))

    t.isNotNil(plan, 'an arena with a spawn area returned no plan at all')
    local placed = 0
    for src = 1, 12 do
        local point = plan[src]
        t.isNotNil(point, 'player ' .. src .. ' was given nowhere to stand')
        t.isTrue(fromCentre(point) <= 100.0 + 0.001,
            ('player %d landed %.1fm from the centre of a 100m area'):format(src, fromCentre(point)))
        placed = placed + 1
    end
    t.equals(placed, 12)
end)

t.test('nobody lands on top of anybody else', function()
    -- THE POINT OF THE WHOLE THING. Twelve players in a hundred-metre circle
    -- at twelve metres apart is comfortably satisfiable, so every pair should
    -- clear it -- no relaxation needed.
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(12), seeded(3))

    local worst, pair = math.huge, nil
    for a = 1, 12 do
        for b = a + 1, 12 do
            local gap = distance(plan[a], plan[b])
            if gap < worst then worst, pair = gap, ('%d and %d'):format(a, b) end
        end
    end

    t.isTrue(worst >= 12.0,
        ('%s are %.1fm apart, closer than the 12m minimum'):format(tostring(pair), worst))
end)

t.test('and they are actually spread, not all in one corner', function()
    -- A placement that satisfied the separation by lining everybody up along
    -- one edge would pass the test above and still be wrong.
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(16), seeded(11))

    local near = 0
    for src = 1, 16 do
        if fromCentre(plan[src]) < 50.0 then near = near + 1 end
    end

    -- Half the RADIUS is a quarter of the AREA, so a uniform scatter puts
    -- roughly a quarter of the roster inside it. Anything from one to
    -- thirteen is fine; zero or sixteen means the sampling is degenerate.
    t.isTrue(near > 0 and near < 16,
        ('%d of 16 players landed in the inner half -- the scatter is not covering the area'):format(near))
end)

t.test('a crowd that cannot possibly fit still gets placed, rather than hanging', function()
    -- A separation bigger than the area can honour is an operator mistake,
    -- and the answer to it is a slightly crowded round -- never a match start
    -- that never finishes. Every attempt is bounded and the last one accepts
    -- whatever it is handed.
    local env = envWith({ radius = 20.0, minSeparation = 19.0 })
    local plan = env.Arena.PlanSpawns('ring', roster(30), seeded(5))

    t.isNotNil(plan)
    for src = 1, 30 do
        t.isNotNil(plan[src], 'player ' .. src .. ' was left without a spawn on a crowded arena')
    end
end)

-- ------------------------------------------------------------------
-- Teams
-- ------------------------------------------------------------------

t.test('a team lands together', function()
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(8, { 'crimson', 'ash' }), seeded(2))

    -- Odd srcs are crimson, even are ash -- see roster().
    local crimson, ash = {}, {}
    for src = 1, 8 do
        if src % 2 == 1 then crimson[#crimson + 1] = plan[src] else ash[#ash + 1] = plan[src] end
    end

    local function widest(group)
        local worst = 0
        for a = 1, #group do
            for b = a + 1, #group do
                worst = math.max(worst, distance(group[a], group[b]))
            end
        end
        return worst
    end

    -- Inside their own circle, so at most twice its radius apart.
    t.isTrue(widest(crimson) <= 50.0 + 0.001,
        ('crimson is spread over %.1fm, wider than its own 25m spawn circle'):format(widest(crimson)))
    t.isTrue(widest(ash) <= 50.0 + 0.001,
        ('ash is spread over %.1fm, wider than its own 25m spawn circle'):format(widest(ash)))
end)

t.test('and the two teams do not start on top of each other', function()
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(8, { 'crimson', 'ash' }), seeded(2))

    local function centroid(predicate)
        local x, y, n = 0, 0, 0
        for src = 1, 8 do
            if predicate(src) then x, y, n = x + plan[src].x, y + plan[src].y, n + 1 end
        end
        return { x = x / n, y = y / n }
    end

    local apart = distance(centroid(function(s) return s % 2 == 1 end),
                           centroid(function(s) return s % 2 == 0 end))

    -- Two anchors on opposite sides of a circle 75m from the middle are 150m
    -- apart; even allowing for the spread inside each team they should be a
    -- long way from each other.
    t.isTrue(apart > 50.0,
        ('the two teams start %.1fm apart -- they are being dropped into each other'):format(apart))
end)

t.test('a team is still kept apart from the other team, player by player', function()
    -- Teams together must not quietly mean teammates stacked: the minimum
    -- separation applies across the whole roster, not within each team.
    local env = envWith()
    local plan = env.Arena.PlanSpawns('ring', roster(8, { 'crimson', 'ash' }), seeded(13))

    local worst = math.huge
    for a = 1, 8 do
        for b = a + 1, 8 do
            worst = math.min(worst, distance(plan[a], plan[b]))
        end
    end
    t.isTrue(worst >= 12.0,
        ('two players start %.1fm apart in a team match, inside the 12m minimum'):format(worst))
end)

t.test('teams do not always open in the same corner', function()
    -- The rotation is random per match. Without it every team match starts
    -- identically, and both teams learn one map by heart.
    local env = envWith()
    local first = env.Arena.PlanSpawns('ring', roster(4, { 'crimson', 'ash' }), seeded(1))
    local second = env.Arena.PlanSpawns('ring', roster(4, { 'crimson', 'ash' }), seeded(99))

    t.isTrue(distance(first[1], second[1]) > 1.0,
        'two matches placed the same team in the same place, so the rotation is not being applied')
end)

-- ------------------------------------------------------------------
-- Falling back
-- ------------------------------------------------------------------

t.test('an arena with no spawn area returns no plan, and the point list is used', function()
    -- The compatibility promise: this feature is additive. An operator who
    -- has written out exact spawns must see no change at all.
    local env = envWith()
    env.Config.Arenas.ring.spawnArea = nil

    t.isNil(env.Arena.PlanSpawns('ring', roster(4)),
        'an arena with no spawn area produced a plan, overriding its exact spawn list')
end)

t.test('and switching the area off does the same', function()
    local env = envWith({ enabled = false })
    t.isNil(env.Arena.PlanSpawns('ring', roster(4)),
        'enabled = false was ignored')
end)

t.test('an empty roster plans nothing rather than erroring', function()
    local env = envWith()
    t.isNil(env.Arena.PlanSpawns('ring', {}))
end)

t.test('a separation wider than the arena is clamped, not obeyed', function()
    -- Obeying it is impossible, and the honest answer is to fit what will
    -- fit. Left unclamped this is the input that makes every placement burn
    -- its whole attempt budget for nothing.
    local env = envWith({ radius = 50.0, minSeparation = 500.0 })
    local area = env.Arena.GetSpawnArea('ring')
    t.equals(area.minSeparation, 50.0)
end)

-- ------------------------------------------------------------------
-- The shipped arenas
-- ------------------------------------------------------------------

t.test('both shipped arenas place a full roster inside their own boundary', function()
    -- A spawn that lands outside the arena's boundary starts the round by
    -- bleeding the player, which is a very confusing first impression.
    local env = Sandbox.newArenaEnv()

    for _, arena in ipairs(env.Arena.GetEnabledArenas()) do
        local plan = env.Arena.PlanSpawns(arena.key, roster(10), seeded(4))
        if plan then
            local raw = env.Config.Arenas[arena.key]
            local boundary = raw.boundary
            if type(boundary) == 'table' and boundary.enabled ~= false and boundary.center then
                local centre = { x = boundary.center.x, y = boundary.center.y }
                for src = 1, 10 do
                    local gap = distance(plan[src], centre)
                    t.isTrue(gap <= boundary.radius,
                        ('%s: player %d spawns %.1fm out, past its %.1fm boundary'):format(
                            arena.key, src, gap, boundary.radius))
                end
            end
        end
    end
end)

-- ------------------------------------------------------------------
-- The boundary that has to actually kill
-- ------------------------------------------------------------------

t.test('every shipped arena has a boundary, and it is switched on', function()
    -- Without one the arena has no edge: a player can walk out of the fight
    -- and the round waits for them.
    local env = Sandbox.newArenaEnv()

    for _, arena in ipairs(env.Arena.GetEnabledArenas()) do
        local boundary = env.Config.Arenas[arena.key].boundary
        t.equals(type(boundary), 'table', arena.key .. ' has no boundary at all')
        t.isTrue(boundary.enabled ~= false, arena.key .. ' ships with its boundary switched off')
        t.isTrue((tonumber(boundary.radius) or 0) > 0, arena.key .. ' has a boundary with no radius')
    end
end)

t.test('and leaving it kills, rather than mildly discouraging', function()
    -- THE NUMBERS ARE THE FEATURE. The bleed loop was always correct; it was
    -- the damage that made it pointless. 8 a second against 200 health and a
    -- 100 plate is 35 seconds -- long enough to leave the arena, look around
    -- and walk back with most of a bar left. That is not a boundary.
    --
    -- Asserted as a time-to-die rather than as a damage number, because the
    -- damage on its own means nothing without the tick rate beside it, and
    -- the two have been changed independently before.
    local env = Sandbox.newArenaEnv()
    local effectiveHealth = 300     -- 200 health plus a full 100 plate

    for _, arena in ipairs(env.Arena.GetEnabledArenas()) do
        local boundary = env.Config.Arenas[arena.key].boundary
        local damage = tonumber(boundary.damagePerTick) or 0
        local tick = tonumber(boundary.tickMs) or 1000

        t.isTrue(damage > 0, arena.key .. ' has a boundary that does no damage at all')

        local perSecond = damage * (1000.0 / tick)
        local seconds = effectiveHealth / perSecond
        t.isTrue(seconds <= 15.0,
            ('%s: out of bounds takes %.0fs to kill a full-health player (%.0f dps) -- long enough to ignore'):format(
                arena.key, seconds, perSecond))
    end
end)

t.test('but there is a warning first, so it is a boundary and not a trap', function()
    -- Killing somebody who stepped a metre over a line they cannot see is not
    -- a boundary either. The grace period is what makes it fair.
    local env = Sandbox.newArenaEnv()

    for _, arena in ipairs(env.Arena.GetEnabledArenas()) do
        local boundary = env.Config.Arenas[arena.key].boundary
        local grace = tonumber(boundary.warningSeconds) or 0
        t.isTrue(grace > 0,
            arena.key .. ' starts damaging the moment the line is crossed, with no warning')
        t.isTrue(grace <= 10.0,
            arena.key .. ' waits so long before doing anything that a player can cross and return freely')
    end
end)

t.test('the spawn area sits inside the boundary, with room to spare', function()
    -- Spawning ON the edge means the warning fires before the round does.
    -- Already covered per player above; this asserts the CONFIG leaves room
    -- rather than relying on where the random sampling happened to land.
    local env = Sandbox.newArenaEnv()

    for _, arena in ipairs(env.Arena.GetEnabledArenas()) do
        local raw = env.Config.Arenas[arena.key]
        local area = env.Arena.GetSpawnArea(arena.key)
        local boundary = raw.boundary

        if area and type(boundary) == 'table' and boundary.enabled ~= false then
            local drift = distance({ x = area.x, y = area.y },
                                   { x = boundary.center.x, y = boundary.center.y })
            t.isTrue(drift + area.radius <= boundary.radius,
                ('%s: the spawn circle reaches %.1fm out, past its %.1fm boundary -- players would spawn already bleeding'):format(
                    arena.key, drift + area.radius, boundary.radius))
        end
    end
end)

print('spawnplan_spec')
os.exit(t.summary())
