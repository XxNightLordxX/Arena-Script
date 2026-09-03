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

      THE ARENAS IT NAMES. Both documents have to name the arenas that
      really ship, at the coordinates they really sit on. Somebody following
      a stale name goes and stands in an empty field.

    THAT SECOND ONE IS CHECKED IN BOTH DOCUMENTS, and the reason is that
    fixing it in one was not enough. DEPLOYMENT.md was corrected and README.md
    was left saying the identical wrong thing, in its INSTALL section -- the
    first page a new operator reads. A guard over one file would have passed
    the whole time.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('checklist_spec')

--- @param path string
--- @return string
local function read(path)
    local handle = assert(io.open(path, 'r'),
        ('%s is missing'):format(path))
    local text = handle:read('a')
    handle:close()
    return text
end

--- @return string
local function checklist()
    return read('../DEPLOYMENT.md')
end

--- The documents that tell an operator where to go and what to expect. Both
--- of them, because correcting one and leaving the other is exactly what
--- happened.
local OPERATOR_DOCS = { '../DEPLOYMENT.md', '../README.md' }

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

t.test('both operator documents name the arenas that actually ship enabled', function()
    -- An operator reads these to know where to go. Naming an arena that is
    -- switched off sends them to an empty field, and the two that were named
    -- for a while had both been off for longer than anybody noticed.
    --
    -- BOTH FILES, because fixing one and leaving the other is the mistake
    -- this test was written a day late for.
    local config = Sandbox.shippedConfig()

    for _, path in ipairs(OPERATOR_DOCS) do
        local text = read(path)
        local lower = text:lower()
        for key, arena in pairs(config.Arenas) do
            if arena.enabled ~= false then
                -- By KEY or by LABEL. The key is what an operator searches
                -- config.lua for; the label is what reads naturally in
                -- prose. Either identifies the arena, and demanding the key
                -- in a sentence would only produce worse sentences.
                local named = lower:find(key:lower(), 1, true)
                    or lower:find(tostring(arena.label or key):lower(), 1, true)
                t.isTrue(named ~= nil,
                    ('%s ships enabled and %s names neither its key nor its label (%s / %s)')
                        :format(key, path:gsub('^%.%./', ''), key, tostring(arena.label)))
            end
        end
    end
end)

t.test('and neither of them still points at an arena that ships switched off', function()
    -- The other half. An arena named as somewhere to go, which is off, is
    -- worse than one not named at all: the reader goes there.
    --
    -- Only the ones described as SHIPPED are a problem -- both files may
    -- mention a disabled arena to say it is disabled, which is useful. So
    -- this looks for the old claim rather than for the name.
    local config = Sandbox.shippedConfig()

    for _, path in ipairs(OPERATOR_DOCS) do
        local text = read(path):lower()
        for key, arena in pairs(config.Arenas) do
            if arena.enabled == false then
                local label = tostring(arena.label or key):lower()
                for _, claim in ipairs({
                    'two shipped arenas are open ground at ' .. label,
                    'shipped arenas suit you — they are open ground at ' .. label,
                }) do
                    t.isNil(text:find(claim, 1, true),
                        ('%s still describes %s as shipped, and it is switched off')
                            :format(path:gsub('^%.%./', ''), label))
                end
            end
        end
    end
end)

t.test('REFERENCE.md counts the specs that are actually on disk', function()
    -- ANOTHER NUMBER THAT GOES STALE ON ITS OWN, and it had gone stale
    -- twice over: the same document claimed 63 spec files in its feature
    -- list and 61 in its file table while 65 sat in tests/. Nobody reading
    -- either sentence could tell, and a wrong count in the one document
    -- that describes the test suite is the sentence an operator uses to
    -- decide how much of this resource is covered.
    --
    -- The file table no longer carries a second copy of the number. One
    -- count in the document is the other half of this fix.
    local text = read('../REFERENCE.md')

    -- Counted from THIS directory: run.sh cds into tests/ before running a
    -- spec, so the globs below are the same ones it uses to pick them.
    local function countOf(pattern)
        local pipe = io.popen(('ls %s 2>/dev/null'):format(pattern))
        if not pipe then return 0 end
        local found = 0
        for _ in pipe:lines() do found = found + 1 end
        pipe:close()
        return found
    end

    local lua, panel = countOf('*_spec.lua'), countOf('panel/*.test.js')

    t.isTrue(lua > 0, 'no spec files were found at all, so this test is measuring nothing')
    t.isTrue(panel > 0, 'no panel suites were found at all, so this test is measuring nothing')

    t.contains(text, ('**%d spec files**'):format(lua),
        ('REFERENCE.md does not say %d spec files, and that is how many there are')
            :format(lua))
    t.contains(text, ('**%d panel suites**'):format(panel),
        ('REFERENCE.md does not say %d panel suites, and that is how many there are')
            :format(panel))
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
