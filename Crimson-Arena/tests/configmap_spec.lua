--[[
    crimson_arena/tests/configmap_spec.lua

    THE MAP AT THE TOP OF config.lua HAS TO BE TRUE.

    config.lua opens with a table of line numbers, because it is three
    thousand lines long and the alternative is scrolling. A line-number map
    is also the most perishable thing anybody can write into a file: it is
    wrong the moment somebody inserts a paragraph above it, and nothing about
    reading it says so. An operator sent to the wrong line trusts what they
    find there.

    So it is checked rather than maintained by hand. Move a section, add a
    comment, delete a setting -- whatever moves the file, this fails with the
    number it should have been.

    It also checks the other half of the promise the header makes: that the
    file really is ordered settings-first, with the two long lists after
    them and the optional integrations last.
]]

local t = dofile('testkit.lua')

print('configmap_spec')

--- config.lua, as lines.
local function configLines()
    local handle = assert(io.open('../config.lua', 'r'),
        'config.lua is not where every spec in this suite expects it')
    local out = {}
    for line in handle:lines() do out[#out + 1] = line end
    handle:close()
    return out
end

--- Every row of the map: { line, name }.
local function mapRows(lines)
    local rows = {}
    for _, line in ipairs(lines) do
        -- The map rows, and only those: leading spaces, a number, a name.
        local number, name = line:match('^%s+(%d+)%s+([%w]+)%s%s')
        if number and name then
            rows[#rows + 1] = { line = tonumber(number), name = name }
        end
        -- The map is the first thing in the file; stop at the end of the
        -- header comment so a stray line further down cannot join it.
        if line == ']]' then break end
    end
    return rows
end

--- Where each `Config.X = ` really is.
local function realLines(lines)
    local at = {}
    for index, line in ipairs(lines) do
        local name = line:match('^Config%.(%w+) = ')
        if name and not at[name] then at[name] = index end
    end
    return at
end

t.test('the map is not empty, and every row names a real setting', function()
    local lines = configLines()
    local rows = mapRows(lines)
    local real = realLines(lines)

    t.isTrue(#rows >= 10, ('the map has %d rows -- did it get deleted?'):format(#rows))
    for _, row in ipairs(rows) do
        t.isNotNil(real[row.name],
            ('the map points at Config.%s, which does not exist'):format(row.name))
    end
end)

t.test('and every line number in it is the line that setting is really on', function()
    -- THE WHOLE POINT. A map that is one paragraph out of date is worse than
    -- no map: it is confidently wrong.
    local lines = configLines()
    local real = realLines(lines)

    for _, row in ipairs(mapRows(lines)) do
        t.equals(row.line, real[row.name],
            ('the map sends you to line %d for Config.%s, which is on line %d')
                :format(row.line, row.name, real[row.name] or -1))
    end
end)

t.test('and nothing in the file is missing from it', function()
    -- A section nobody can find is a section nobody edits.
    local lines = configLines()
    local listed = {}
    for _, row in ipairs(mapRows(lines)) do listed[row.name] = true end

    for name in pairs(realLines(lines)) do
        -- The three one-line settings at the top are above the map and in
        -- plain sight; everything with a body of its own has to be listed.
        if name ~= 'ResourceLabel' and name ~= 'Debug' and name ~= 'NotifyTitle' then
            t.isTrue(listed[name] == true,
                ('Config.%s is in the file and not in the map'):format(name))
        end
    end
end)

t.test('the file is ordered settings first, then the long lists, then the optional bits', function()
    -- The promise the header makes, kept mechanically. The two big lists
    -- used to sit in the middle: reaching Betting meant scrolling past
    -- fourteen hundred lines of weapons.
    local at = realLines(configLines())

    local function before(a, b)
        t.isTrue(at[a] < at[b],
            ('Config.%s (line %d) should come before Config.%s (line %d)')
                :format(a, at[a] or -1, b, at[b] or -1))
    end

    -- Settings you tune, before the data you paste.
    for _, key in ipairs({ 'Lobby', 'Match', 'Teams', 'Modes', 'Betting', 'UI', 'Permissions' }) do
        before(key, 'Arenas')
        before(key, 'Loadouts')
    end
    -- And the optional integrations last of all.
    for _, key in ipairs({ 'Database', 'Webhook', 'Dispatch' }) do
        before('Loadouts', key)
    end
end)

os.exit(t.summary())
