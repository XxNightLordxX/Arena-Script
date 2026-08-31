--[[
    crimson_arena/tests/checklist_spec.lua

    DEPLOYMENT.md IS A DOCUMENT SOMEBODY FOLLOWS WITH A SERVER RUNNING.

    It is the only verification this build has for the half that has no
    natives outside the game, so a step that points at the wrong place is not
    a typo -- it is a check that does not get done.

    Two things go stale on their own and neither shows up by reading:

      SECTION NUMBERS. The checklist used to cross-reference itself by number
      ("test it with section 7 below"). Insert a section and every reference
      past it is quietly off by one -- which is exactly what happened the
      moment the sky-arena section was added, twice in one edit.

      A test that the referenced number EXISTS does not catch that: after the
      renumbering, "section 6" still existed, it was just the wrong one. So
      the failure mode is removed rather than tested around -- references are
      by NAME now, and the first test below is what stops numbers coming
      back.

      THE ARENAS IT NAMES. It used to tell an operator the two shipped arenas
      were Sandy Shores Airfield and Vespucci beach. Both had been switched
      off for a while by then, and the two that ship now are somewhere else
      entirely. Somebody following that would go and stand in an empty field.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('checklist_spec')

--- @return string
local function checklist()
    local handle = assert(io.open('../DEPLOYMENT.md', 'r'),
        'DEPLOYMENT.md is missing -- it is the only verification the native half of this build gets')
    local text = handle:read('a')
    handle:close()
    return text
end

t.test('it never cross-references itself by NUMBER', function()
    -- THE FRAGILITY, REMOVED RATHER THAN TESTED AROUND. A numeric reference
    -- silently retargets when a section is inserted above it, and it still
    -- points at a real section afterwards -- so the obvious test, "does the
    -- number exist", passes on the broken document. Names do not drift.
    local text = checklist()

    local numeric = {}
    for reference in text:gmatch('[Ss]ection%s+%d+') do
        numeric[#numeric + 1] = reference
    end

    t.equals(#numeric, 0, ('refers to sections by number, which goes stale the next time one is inserted: %s -- use the section name instead')
        :format(table.concat(numeric, ', ')))
end)

t.test('and its sections are still numbered, so a reader can follow an order', function()
    local text = checklist()
    local count = 0
    for _ in text:gmatch('###%s*%d+%.') do count = count + 1 end
    t.isTrue(count >= 5, ('only %d numbered sections -- did the checklist get gutted?'):format(count))
end)

t.test('and they are numbered 1..N with nothing skipped or repeated', function()
    -- A duplicate or a gap is the same defect from the other side: a
    -- reference that resolves to the wrong step rather than to none.
    local text = checklist()

    local seen, highest = {}, 0
    for number in text:gmatch('###%s*(%d+)%.') do
        local n = tonumber(number)
        t.isTrue(not seen[n], ('section %d appears twice'):format(n))
        seen[n] = true
        highest = math.max(highest, n)
    end

    for n = 1, highest do
        t.isTrue(seen[n] == true, ('section %d is missing, so the numbering skips'):format(n))
    end
end)

t.test('it names the arenas that actually ship enabled', function()
    -- An operator reads this to know where to stand. Naming an arena that is
    -- switched off sends them to an empty field, and the two it named for a
    -- while had both been off for longer than anybody noticed.
    local text = checklist()
    local config = Sandbox.shippedConfig()

    for key, arena in pairs(config.Arenas) do
        if arena.enabled ~= false then
            t.contains(text, key,
                ('%s ships enabled and the deployment checklist never mentions it'):format(key))
        end
    end
end)

t.test('and it tells them where the sky arena is, in the coordinates config uses', function()
    -- The one step that needs a player to fly somewhere specific. A number
    -- that has drifted from config sends them to open sky and they report
    -- the floor as missing.
    local text = checklist()
    local sky = Sandbox.shippedConfig().Arenas.skydome
    if not sky or sky.enabled == false then return end

    local area = sky.spawnArea
    t.isNotNil(area, 'the sky arena has no spawn area to name')

    -- Written as whole numbers in prose, which is how somebody types them
    -- into a teleport command.
    for _, value in ipairs({ area.center.x, area.center.y, area.center.z }) do
        t.contains(text, ('%d'):format(math.floor(value)),
            ('the checklist never names %d, so it is sending people somewhere else')
                :format(math.floor(value)))
    end
end)

os.exit(t.summary())
