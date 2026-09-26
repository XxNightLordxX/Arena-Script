--[[
    crimson_arena/tests/checklist_spec.lua

    THE DOCUMENTS THAT DESCRIBE THIS RESOURCE GO STALE ON THEIR OWN, and
    neither kind of staleness shows up by reading.

      THE ARENAS README.md NAMES. It has to name the arenas that really
      ship, and must not still describe a switched-off one as shipped.
      Somebody following a stale name goes and stands in an empty field.

      THE COUNTS AND TABLES IN REFERENCE.md. A spec-file count and a
      per-file function table, both maintained by hand, both wrong before
      now -- a reader who cannot trust the list has to go read the source,
      which is the whole point of the document.
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

--- The document that tells an operator where to go and what to expect.
local OPERATOR_DOCS = { '../Crimson-Arena/README.md' }

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
    local text = read('../Crimson-Arena/REFERENCE.md')

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

    -- THE CLAIM IS OPTIONAL NOW; BEING RIGHT ABOUT IT IS NOT.
    --
    -- The suite was stripped out of the shipped resource, and the sentence
    -- that counted it went with it -- REFERENCE.md's own header now says the
    -- document is a snapshot that nothing checks. A tree with no claim has
    -- nothing to be stale about, and demanding one back would be this spec
    -- insisting the release ship its test suite.
    --
    -- So: say nothing, or say the truth. A number that is there and wrong is
    -- exactly the rot this test was written for, and it still fails on it.
    local claimedLua = tonumber(text:match('%*%*(%d+) spec files%*%*'))
    local claimedPanel = tonumber(text:match('%*%*(%d+) panel suites%*%*'))

    if claimedLua then
        t.equals(claimedLua, lua,
            'REFERENCE.md counts the spec files and gets it wrong')
    end
    if claimedPanel then
        t.equals(claimedPanel, panel,
            'REFERENCE.md counts the panel suites and gets it wrong')
    end
end)

t.test('and its function tables list the functions each file really defines', function()
    -- THE SAME ROT, ONE LEVEL DOWN. REFERENCE.md carries a table per source
    -- file -- "#### `server/betting.lua` -- 21 functions" and a row for each
    -- -- and nothing checked it. Three sections had already drifted:
    -- shared/arena.lua was missing Arena.SlotsPerPlayer, client/match.lua
    -- was missing both of the spectator-scenery functions, and every
    -- heading counted the rows below it rather than the file beside it.
    --
    -- A reader who cannot trust the list has to go and read the source,
    -- which is what the list exists to save them.
    --
    -- BOTH DIRECTIONS. A function in the file and not in the table is a
    -- reader who never learns it exists; a row for a function that has been
    -- deleted sends them looking for something that is not there.
    local text = read('../Crimson-Arena/REFERENCE.md')

    -- WALKED LINE BY LINE rather than matched section by section. The
    -- obvious pattern -- '#### ...(.-)\n#### ' -- consumes the NEXT
    -- heading as its terminator, so gmatch sees every other section and
    -- silently checked half the document.
    local sections, current = {}, nil
    for line in text:gmatch('[^\n]*') do
        local path, claimed = line:match('^#### `([^`]+)` .- (%d+) functions%s*$')
        if path then
            current = { path = path, claimed = tonumber(claimed), rows = {} }
            sections[#sections + 1] = current
        elseif line:match('^#### ') then
            current = nil
        elseif current then
            local name = line:match('^| `([%a_][%w_.]*)%(')
            if name then current.rows[#current.rows + 1] = name end
        end
    end

    local checked = 0
    for _, section in ipairs(sections) do
        local path, claimed = section.path, section.claimed
        checked = checked + 1

        local documented, rows = {}, #section.rows
        for _, name in ipairs(section.rows) do documented[name] = true end

        local defined, count, order = {}, 0, {}
        for line in read('../Crimson-Arena/' .. path):gmatch('[^\n]+') do
            local name = line:match('^function ([%a_][%w_.]*)%(')
            if name then
                defined[name] = true
                count = count + 1
                order[#order + 1] = name
            end
        end

        t.equals(rows, claimed,
            ('%s: the heading says %d functions and %d are listed under it')
                :format(path, claimed, rows))
        t.equals(count, rows,
            ('%s: the file defines %d functions and REFERENCE.md lists %d')
                :format(path, count, rows))

        for name in pairs(defined) do
            t.isTrue(documented[name] == true,
                ('%s defines %s and REFERENCE.md never mentions it'):format(path, name))
        end
        -- AND IN THE ORDER THE FILE DEFINES THEM, which REFERENCE.md says
        -- of itself in as many words. The two checks above compare the rows
        -- and the definitions as SETS, so the order was free to rot and did:
        -- four of these tables had drifted out of it, one of them by
        -- seventy-four rows, and nothing anywhere noticed. A reader
        -- following the list down the file is the whole reason the order is
        -- claimed at all.
        for index, name in ipairs(order) do
            if section.rows[index] ~= name then
                t.equals(section.rows[index], name,
                    ('%s row %d: REFERENCE.md lists %s where the file defines %s -- '
                        .. 'the table is meant to be in definition order')
                        :format(path, index, tostring(section.rows[index]), name))
                break
            end
        end

        for name in pairs(documented) do
            t.isTrue(defined[name] == true,
                ('REFERENCE.md lists %s under %s and the file does not define it')
                    :format(name, path))
        end
    end

    -- A loop that runs zero times passes every assertion inside it, so the
    -- number of sections found is itself asserted: a rewrite of the
    -- headings that this walk stopped recognising would otherwise turn the
    -- whole test green while checking nothing.
    t.isTrue(checked >= 13,
        ('only %d function tables were found in REFERENCE.md, so this test checked almost nothing')
            :format(checked))
end)

os.exit(t.summary())
