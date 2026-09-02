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
    -- OVER MANY MATCHES, NOT ONE. The anchors are drawn now rather than laid
    -- out, so a single seed proves only that one draw was lucky -- and a
    -- draw is exactly what a fixed pattern used to make impossible. What has
    -- to hold is that the WORST of twenty-four matches still opens the two
    -- sides a long way apart, which is the maximin doing its job.
    local env = envWith()
    local worst, worstSeed = math.huge, nil

    for seed = 1, 60 do
        local plan = env.Arena.PlanSpawns('ring', roster(8, { 'crimson', 'ash' }), seeded(seed * 31))

        local function centroid(predicate)
            local x, y, n = 0, 0, 0
            for src = 1, 8 do
                if predicate(src) then x, y, n = x + plan[src].x, y + plan[src].y, n + 1 end
            end
            return { x = x / n, y = y / n }
        end

        local apart = distance(centroid(function(s) return s % 2 == 1 end),
                               centroid(function(s) return s % 2 == 0 end))
        if apart < worst then worst, worstSeed = apart, seed end
    end

    -- Two anchors on opposite sides of a circle 75m from the middle are 150m
    -- apart; even allowing for the spread inside each team they should be a
    -- long way from each other, in every match rather than on average.
    --
    -- THE THRESHOLD IS SET WHERE IT SEPARATES TWO DESIGNS. Anchors drawn on
    -- the RIM hold the two sides 135m apart at worst over sixty matches;
    -- anchors drawn anywhere INSIDE the circle -- which is the obvious way
    -- to write this and the one that reads as more random -- manage only
    -- 71m, because both sides can land near the middle and no amount of
    -- scoring can then pull them apart.
    t.isTrue(worst > 100.0,
        ('the worst of 24 matches (seed %d) started the two teams %.1fm apart -- they are being dropped into each other')
            :format(worstSeed or 0, worst))
end)

t.test('a team is still kept apart from the other team, player by player', function()
    -- Teams together must not quietly mean teammates stacked. TWO FLOORS,
    -- though, not one: the operator's minSeparation is what two ENEMIES are
    -- held to, and teammates have their own smaller one -- landing together
    -- is what a team spawn is.
    local env = envWith()
    local roll = roster(8, { 'crimson', 'ash' })
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(13))
    local area = env.Arena.GetSpawnArea('ring')

    local worstEnemy, worstMate = math.huge, math.huge
    for a = 1, #roll do
        for b = a + 1, #roll do
            local gap = distance(plan[roll[a].src], plan[roll[b].src])
            if roll[a].team == roll[b].team then
                worstMate = math.min(worstMate, gap)
            else
                worstEnemy = math.min(worstEnemy, gap)
            end
        end
    end

    t.isTrue(worstEnemy >= 12.0,
        ('two enemies start %.1fm apart in a team match, inside the 12m minimum'):format(worstEnemy))
    t.isTrue(worstMate >= area.mateSeparation - 0.001,
        ('two teammates start %.1fm apart, inside their own %.1fm floor'):format(worstMate, area.mateSeparation))
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
-- Room to survive the first second
-- ------------------------------------------------------------------

--- The smallest gap between any two players on OPPOSITE sides. In a
--- free-for-all everybody is on a different side from everybody.
--- @param plan table
--- @param roll table[]
--- @return number
local function worstEnemyGap(plan, roll)
    local worst = math.huge
    for a = 1, #roll do
        for b = a + 1, #roll do
            local sameSide = roll[a].team ~= nil and roll[a].team == roll[b].team
            if not sameSide then
                worst = math.min(worst, distance(plan[roll[a].src], plan[roll[b].src]))
            end
        end
    end
    return worst
end

t.test('THE COMPLAINT: four fighters are not placed ten metres apart in a circle that fits twenty-six', function()
    -- ONE NUMBER CANNOT BE RIGHT FOR BOTH ENDS OF THE ROSTER, and this is
    -- the end where the old behaviour was worst. `minSeparation` was the
    -- target as well as the floor, so a small roster in a large circle got
    -- exactly the floor -- and everybody opened the round inside somebody
    -- else's sights, which is what an operator reports as being shot the
    -- moment they spawn.
    --
    -- 100m radius, four players: hexagonal packing says roughly 66m is the
    -- theoretical limit and sampling reaches about 80% of it. Anything near
    -- the 12m floor means the ask is still a constant.
    local env = envWith()
    local roll = roster(4)
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(5))

    local worst = worstEnemyGap(plan, roll)
    t.isTrue(worst > 30.0,
        ('four fighters in a 100m circle are only %.1fm apart -- the placement is still asking for the floor'):format(worst))
end)

t.test('and the gap shrinks with the roster rather than the arena getting more crowded than it has to', function()
    -- The ask is what the circle can actually give THIS many people, so it
    -- has to fall as the roster grows -- and it has to fall smoothly rather
    -- than collapsing to the floor the moment it is inconvenient.
    local env = envWith()
    local previous = math.huge
    for _, count in ipairs({ 4, 8, 16, 24 }) do
        local roll = roster(count)
        local plan = env.Arena.PlanSpawns('ring', roll, seeded(count * 7))
        local worst = worstEnemyGap(plan, roll)

        t.isTrue(worst >= 12.0,
            ('%d fighters came out %.1fm apart, inside the 12m floor'):format(count, worst))
        t.isTrue(worst <= previous + 0.001,
            ('%d fighters got MORE room (%.1fm) than the smaller roster before them (%.1fm)')
                :format(count, worst, previous))
        previous = worst
    end
end)

t.test('the floor is still a floor: a roster too big for the circle is not refused', function()
    -- The ask is ambitious on purpose, and an ambitious ask that cannot be
    -- met must degrade rather than fail. Sixty players in a circle that fits
    -- far fewer at 12m is the case where the placement has to hand back
    -- something for everybody.
    local env = envWith()
    local roll = roster(60)
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(3))

    for _, entry in ipairs(roll) do
        t.isNotNil(plan[entry.src], ('player %d was never placed'):format(entry.src))
        t.isTrue(fromCentre(plan[entry.src]) <= 100.0 + 0.001,
            ('player %d was placed outside the area'):format(entry.src))
    end
end)

t.test('teammates keep the small gap and enemies keep the big one', function()
    -- TWO DIFFERENT QUESTIONS, and the old code asked one. Landing near your
    -- own side is the point of having one; landing near the other side is
    -- the thing being fixed. So the two distances must come out different,
    -- with the enemy one larger.
    local env = envWith()
    local roll = roster(8, { 'crimson', 'ash' })
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(21))

    local worstMate = math.huge
    for a = 1, #roll do
        for b = a + 1, #roll do
            if roll[a].team == roll[b].team then
                worstMate = math.min(worstMate, distance(plan[roll[a].src], plan[roll[b].src]))
            end
        end
    end

    local worstEnemy = worstEnemyGap(plan, roll)
    t.isTrue(worstEnemy > worstMate,
        ('the nearest enemy (%.1fm) is no further than the nearest teammate (%.1fm) -- the two separations are not separate')
            :format(worstEnemy, worstMate))
    local area = env.Arena.GetSpawnArea('ring')
    t.isTrue(worstMate >= area.mateSeparation - 0.001,
        ('two teammates are %.1fm apart, inside their own %.1fm floor'):format(worstMate, area.mateSeparation))
end)

t.test('a crowded team does not drag the enemy gap down with it', function()
    -- THE REGRESSION THIS EXISTS TO STOP, found by measuring rather than by
    -- reading. Eight fighters do not fit inside one team's own 25m circle at
    -- the operator's separation, so the teammate constraint fails on every
    -- round of the relaxation -- and sharing one decay between the two
    -- dragged the ENEMY gap down with it, to under seven metres in a
    -- sixteen-player team match. Crowding among teammates says nothing
    -- whatever about how close the other side may be.
    local env = envWith({ teamRadius = 14.0 })
    local roll = roster(16, { 'crimson', 'ash' })
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(9))

    local worst = worstEnemyGap(plan, roll)
    t.isTrue(worst >= 12.0,
        ('the sides came out %.1fm apart because their own circles were crowded'):format(worst))
end)

t.test('OVERLAPPING TEAM CIRCLES: the per-pair enemy rule is what keeps the sides apart', function()
    -- WHERE THE ANCHOR SPACING STOPS DOING THE WORK. With a team circle small
    -- against the area, two sides are kept apart simply by being anchored
    -- far away from each other, and the per-pair rule never has to fire. Give
    -- each side most of the arena to spread over and the circles overlap --
    -- and then the only thing standing between a crimson fighter and an ash
    -- one is the distance the placement itself insists on.
    --
    -- This is also the case that catches an enemy gap relaxed below the
    -- operator's floor: the teams are crowded, the relaxation runs deep, and
    -- an unclamped decay walks the sides straight into each other.
    local env = envWith({ teamRadius = 70.0, minSeparation = 12.0 })

    -- ASSERTED WELL ABOVE THE FLOOR, because the floor is what the old
    -- behaviour already gave and what a constant ask still gives. Measured
    -- over sixty matches: the placement holds fourteen fighters sharing one
    -- circle 40m apart, and asking for the operator's twelve instead drops
    -- that to 12.1m -- which is the mutation this line exists to fail on.
    for _, spec in ipairs({ { 4, 40.0 }, { 14, 30.0 } }) do
        local count, wanted = spec[1], spec[2]
        local worst, worstSeed = math.huge, nil
        for seed = 1, 60 do
            local roll = roster(count, { 'crimson', 'ash' })
            local plan = env.Arena.PlanSpawns('ring', roll, seeded(seed * 17))
            local gap = worstEnemyGap(plan, roll)
            if gap < worst then worst, worstSeed = gap, seed end
        end
        t.isTrue(worst > wanted,
            ('%d fighters sharing one circle came out %.1fm apart on seed %d -- the sides are being held to the floor rather than to what the circle can give')
                :format(count, worst, worstSeed or 0))
    end
end)

t.test('and teammates in that same circle are still allowed to stand together', function()
    -- The other half of the same case. Tagging each placement with the side
    -- it belongs to is what lets one rule apply to a teammate and another to
    -- an enemy; drop the tag and everybody is measured by the enemy gap, so
    -- a team is scattered over the whole arena and stops being a team.
    local env = envWith({ teamRadius = 70.0, minSeparation = 12.0 })
    local roll = roster(10, { 'crimson', 'ash' })
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(77))

    local worstMate = math.huge
    for a = 1, #roll do
        for b = a + 1, #roll do
            if roll[a].team == roll[b].team then
                worstMate = math.min(worstMate, distance(plan[roll[a].src], plan[roll[b].src]))
            end
        end
    end

    local worstEnemy = worstEnemyGap(plan, roll)
    t.isTrue(worstMate < worstEnemy * 0.75,
        ('the closest teammates are %.1fm apart and the closest enemies %.1fm -- a teammate is being held to the enemy distance')
            :format(worstMate, worstEnemy))
end)

t.test('AND WHEN THE CIRCLE CANNOT GIVE EVEN THE FLOOR, the floor is what it keeps trying for', function()
    -- THE OTHER END OF THE SAME RULE. Everything above is about a circle
    -- with room to spare, where the ask is larger than the operator's
    -- number. Here it is smaller: twenty-four fighters in a 30m circle
    -- cannot have twelve metres each, so what the placement asks for falls
    -- back to the operator's floor -- and the relaxation must not then walk
    -- it below that on the way down. Unclamped, five rounds of decay leave
    -- the ask at under a quarter of the floor, and the arena stops trying
    -- for the one number the operator actually wrote.
    local env = envWith({ radius = 30.0, minSeparation = 12.0 })
    local roll = roster(24)

    local best, worst = 0, math.huge
    for seed = 1, 60 do
        local plan = env.Arena.PlanSpawns('ring', roll, seeded(seed * 23))
        local gap = worstEnemyGap(plan, roll)
        best = math.max(best, gap)
        worst = math.min(worst, gap)
    end

    -- Not every match can manage twelve -- that is what "cannot give even
    -- the floor" means -- but the placement has to be REACHING for it, and
    -- the difference is measurable at both ends. Clamped, sixty crowded
    -- matches come out between 7.7m and 9.8m; unclamped, the ask decays to
    -- under a quarter of the floor, low enough to be SATISFIED by a bad
    -- point -- so the placement stops falling through to the furthest-from-
    -- trouble draw that would have saved it, and the worst match drops to
    -- 5.9m.
    t.isTrue(worst >= 7.0,
        ('the worst of sixty crowded matches was %.1fm apart -- the ask is being relaxed below the floor rather than towards it'):format(worst))
    t.isTrue(best >= 9.5,
        ('the best of sixty crowded matches only managed %.1fm'):format(best))

    -- And everybody is still placed, inside the area.
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(1))
    for _, entry in ipairs(roll) do
        t.isNotNil(plan[entry.src])
        t.isTrue(fromCentre(plan[entry.src]) <= 30.0 + 0.001)
    end
end)

t.test('a team never has anybody standing outside the arena', function()
    -- THE ANCHOR HAS TO BE PULLED IN FROM THE EDGE, by exactly the radius
    -- the team then spreads over. Anchoring on the rim of the AREA instead
    -- of the rim of what is left after that spread puts half of each side
    -- outside the arena -- 161 fighters over 40 matches, measured -- and
    -- outside the arena on the skydome is a kilometre of air.
    local env = envWith()
    local strays = 0

    for seed = 1, 40 do
        local roll = roster(8, { 'crimson', 'ash' })
        local plan = env.Arena.PlanSpawns('ring', roll, seeded(seed * 5))
        for _, entry in ipairs(roll) do
            if fromCentre(plan[entry.src]) > 100.001 then strays = strays + 1 end
        end
    end

    t.equals(strays, 0, ('%d team placements landed outside the spawn area'):format(strays))
end)

t.test('team anchors are drawn rather than laid out on a fixed ring', function()
    -- Evenly spaced anchors at a random rotation are one shape rotated, so
    -- two teams meant "directly opposite" in every single round. Drawing the
    -- angle makes the whole rim the answer -- but the anchors still have to
    -- end up far apart, which is what the maximin below is for.
    local env = envWith()
    local seen = {}
    for seed = 1, 24 do
        local roll = roster(6, { 'crimson', 'ash', 'bone' })
        local plan = env.Arena.PlanSpawns('ring', roll, seeded(seed * 13))

        -- The angle each side opened at, to the nearest ten degrees.
        local x, y, n = 0, 0, 0
        for _, entry in ipairs(roll) do
            if entry.team == 'crimson' then
                x, y, n = x + plan[entry.src].x, y + plan[entry.src].y, n + 1
            end
        end
        local angle = math.floor((math.deg(math.atan(y / n - AREA.y, x / n - AREA.x)) + 360) % 360 / 10)
        seen[angle] = true
    end

    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    t.isTrue(distinct >= 8,
        ('crimson opened at only %d distinct angles over 24 matches -- the anchors are still a fixed pattern'):format(distinct))
end)

t.test('EVERY FIGHTER IS TURNED TO FACE THE MIDDLE, and for years none of them were', function()
    -- NINETY DEGREES OUT, IN BOTH PLACES IT WAS WRITTEN. A GTA heading is
    -- degrees clockwise from north, so a ped at heading h faces
    -- (-sin h, cos h) -- and the maths angle atan gives back is measured
    -- anticlockwise from east. The two differ by a quarter turn, and neither
    -- copy of the formula subtracted it: every fighter placed at the edge of
    -- a spawn circle was turned side-on to the arena, looking along the rim,
    -- with the fight ninety degrees to their left. Both copies carried a
    -- comment promising the opposite.
    --
    -- Asserted as a dot product rather than as an angle, because that is the
    -- question: does the direction this player is facing point at the middle.
    local env = envWith()
    local roll = roster(12)
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(4))

    local worst, worstAt = 1.0, nil
    for _, entry in ipairs(roll) do
        local point = plan[entry.src]
        local forward = { x = -math.sin(math.rad(point.w)), y = math.cos(math.rad(point.w)) }
        local toCentre = { x = AREA.x - point.x, y = AREA.y - point.y }
        local length = math.sqrt(toCentre.x ^ 2 + toCentre.y ^ 2)
        if length > 1.0 then
            local dot = (forward.x * toCentre.x + forward.y * toCentre.y) / length
            if dot < worst then worst, worstAt = dot, entry.src end
        end
    end

    t.isTrue(worst > 0.999,
        ('player %d is facing %.3f of the way towards the middle -- 0.000 is a quarter turn out, which is what the old formula gave')
            :format(worstAt or 0, worst))
end)

t.test('and so is every team, together', function()
    -- A team faces the middle as a side rather than each player facing
    -- wherever their own sample happened to land, so the anchor's heading is
    -- what they all get -- and it has to be right for the same reason.
    local env = envWith()
    local roll = roster(8, { 'crimson', 'ash' })
    local plan = env.Arena.PlanSpawns('ring', roll, seeded(6))

    for _, entry in ipairs(roll) do
        local point = plan[entry.src]
        local forward = { x = -math.sin(math.rad(point.w)), y = math.cos(math.rad(point.w)) }
        local toCentre = { x = AREA.x - point.x, y = AREA.y - point.y }
        local length = math.sqrt(toCentre.x ^ 2 + toCentre.y ^ 2)
        local dot = (forward.x * toCentre.x + forward.y * toCentre.y) / length
        -- Looser than the free-for-all case on purpose: a team shares ONE
        -- heading, so a player on the edge of their own circle is a few
        -- degrees off the middle by design. A quarter turn out is not a few
        -- degrees.
        t.isTrue(dot > 0.85,
            ('player %d faces %.3f of the way to the middle'):format(entry.src, dot))
    end
end)

t.test('TEAMMATES HAVE THEIR OWN FLOOR, and it is one the arena actually keeps', function()
    -- `minSeparation` used to answer for teammates as well as enemies, and
    -- answering both is what made it untrue: on an arena whose cover fills
    -- most of a team circle, teammates came out FOUR METRES apart against a
    -- stated ten, because the placement relaxed its way down rather than
    -- admit it could not hold the number.
    --
    -- The honest split is that the ten was never about teammates. Landing
    -- together IS a team spawn. What matters is that nobody lands INSIDE
    -- anybody -- a body's width and a step -- and unlike the enemy gap that
    -- floor is not relaxed on the way down.
    local env = envWith({ teamRadius = 14.0 })
    local area = env.Arena.GetSpawnArea('ring')
    t.isTrue(area.mateSeparation > 0, 'there is no teammate floor to keep')
    t.isTrue(area.mateSeparation < area.minSeparation,
        'the teammate floor is the enemy gap again, which is the thing that was untrue')

    --- The closest two players on the SAME side come, over `seeds` matches.
    local function worstMateOver(world, count, seeds)
        local worst = math.huge
        for seed = 1, seeds do
            local roll = roster(count, { 'crimson', 'ash' })
            local plan = world.Arena.PlanSpawns('ring', roll, seeded(seed * 3))
            for a = 1, #roll do
                for b = a + 1, #roll do
                    if roll[a].team == roll[b].team then
                        worst = math.min(worst, distance(plan[roll[a].src], plan[roll[b].src]))
                    end
                end
            end
        end
        return worst
    end

    local worst = worstMateOver(env, 16, 40)
    t.isTrue(worst >= area.mateSeparation - 0.001,
        ('two teammates landed %.2fm apart against a floor of %.2fm'):format(worst, area.mateSeparation))

    -- AND IN A CIRCLE FAR TOO SMALL FOR THE SIDE STANDING IN IT, which is
    -- where a floor stops being a formality. Eight fighters cannot be put
    -- eight metres apart inside an eight-metre circle, so every round of the
    -- relaxation fails and the placement falls through to its last-resort
    -- draw -- and BOTH of those paths have to keep the floor, or a team
    -- spawn becomes a pile.
    local tight = envWith({ teamRadius = 8.0 })
    local tightArea = tight.Arena.GetSpawnArea('ring')
    local crushed = worstMateOver(tight, 16, 40)

    t.isTrue(crushed >= tightArea.mateSeparation - 0.001,
        ('in a circle too small for the side, two teammates landed %.2fm apart against a floor of %.2fm')
            :format(crushed, tightArea.mateSeparation))

    -- AND PAST THE POINT WHERE NO FLOOR CAN BE KEPT, the last-resort draw is
    -- still the best of what it saw. Eight fighters in a THREE-metre circle
    -- cannot be four metres apart by any arrangement, so every constrained
    -- round fails and the fallback is what places them -- and that draw has
    -- to score against everyone already placed, not only the other side.
    -- Scoring enemies alone keeps a fighter clear of the opposition by
    -- stacking them on their own teammate: measured, 0.01m apart, which is
    -- two people standing inside each other.
    local hopeless = envWith({ teamRadius = 3.0 })
    local piled = worstMateOver(hopeless, 16, 40)
    t.isTrue(piled > 0.5,
        ('the last-resort draw put two teammates %.2fm apart -- it is scoring the other side only'):format(piled))
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
