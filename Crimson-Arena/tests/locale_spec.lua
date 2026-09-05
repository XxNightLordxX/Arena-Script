--[[
    crimson_arena/tests/locale_spec.lua

    The code and locales/en.json, checked against each other in both
    directions.

    A missing key is invisible until a player hits the one branch that asks
    for it, and ox_lib answers a missing key by printing the key itself --
    so the bug ships as "error.not_enough_money" on somebody's screen rather
    than as anything a console would show. An ORPHANED key is the same
    mistake from the other end: text an operator translates, proofreads and
    maintains that no line of code will ever print.

    NOTHING HERE IS A HARD-CODED LIST OF KEYS. The keys come from en.json
    through the sandbox, and the call sites come from reading every .lua
    file under client/, server/ and shared/ off disk. Add a file, add a
    call, add a key -- this spec covers it without being edited. The one
    list it does carry is ALLOWED_ORPHANS, which is small, and which is
    itself checked: an exception that stops being needed fails the suite
    instead of quietly living on.

    WHY IT READS THE SOURCE AS TEXT rather than loading it: client files
    call natives at load time and none of them can run outside FiveM. The
    text is also the only place a key that is passed around as a `reason`
    string -- never handed to locale() at that call site at all -- can be
    seen.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('locale_spec')

-- The directories holding this resource's Lua, scanned whole. A spec that
-- named its own input files would stop covering the resource the day
-- somebody added one.
local SOURCE_DIRS = { '../client', '../server', '../shared' }

-- Every group a locale key may open with, per the contract. Deliberately
-- WIDER than en.json's own top level: a literal in a group the file has
-- never heard of is the interesting failure, and taking the vocabulary from
-- en.json would make that case invisible.
local KEY_GROUPS = {
    meta = true, cmd = true, error = true, match = true, bet = true, notify = true, ui = true,
}

-- Keys en.json may hold that no file under SOURCE_DIRS names, and why each
-- is not dead weight. Every entry is checked for still being unreferenced,
-- so this list cannot rot into a way of hiding a genuine orphan.
local ALLOWED_ORPHANS = {
    ['meta.locale_probe'] =
        'tests/fixtures/sandbox.lua asks for this key to force the one-time load of en.json; no production file prints it.',
}

-- Where a locale key sits in each call shape this resource uses, and which
-- argument the locale() substitutions start at.
--
-- ArenaNotifyKey(src, key, notifyType, ...) and client/match.lua's local
-- notify(key, notifyType, ...) both forward their tail straight into
-- locale(), so their argument counts are the same claim about the same
-- format string.
--
-- A key reached through some OTHER wrapper is still proved to exist -- the
-- literal scan below sees every string in the file regardless of what
-- consumes it. Only its placeholder count goes unchecked, which is why a
-- new wrapper belongs in this table.
local CALL_SHAPES = {
    ['locale'] = { keyIndex = 1, firstArg = 2 },
    ['ArenaNotifyKey'] = { keyIndex = 2, firstArg = 4 },
    ['notify'] = { keyIndex = 1, firstArg = 3 },
}

-- ======================================================================
-- READING THE SOURCE
-- ======================================================================

--- Every .lua file under SOURCE_DIRS. `find` rather than a fixed list, so
--- a subdirectory added later is scanned too.
--- @return string[] paths
local function sourceFiles()
    local pipe = assert(io.popen(('find %s -type f -name "*.lua"'):format(table.concat(SOURCE_DIRS, ' ')), 'r'),
        'locale_spec: io.popen is unavailable, so the source tree cannot be listed')
    local paths = {}
    for line in pipe:lines() do paths[#paths + 1] = line end
    pipe:close()
    table.sort(paths)
    return paths
end

--- @param path string
--- @return string
local function readFile(path)
    local handle = assert(io.open(path, 'r'), 'locale_spec: could not read ' .. path)
    local text = handle:read('a')
    handle:close()
    return text
end

--- Blanks every comment, keeping the file's length and line breaks so a
--- position found afterwards still points at the right line.
---
--- Comments go first, and by a scanner rather than a pattern, because every
--- file in this resource opens with a long `--[[ ]]` block full of prose --
--- apostrophes and all. A stripper that treated those apostrophes as string
--- quotes would lose the rest of the file and this spec would pass by
--- reading nothing.
--- @param src string
--- @return string
local function stripComments(src)
    local out, index, length = {}, 1, #src

    while index <= length do
        local char = src:sub(index, index)

        if char == '-' and src:sub(index + 1, index + 1) == '-' then
            local level = src:match('^%[(=*)%[', index + 2)
            local stop
            if level then
                local close = src:find(']' .. level .. ']', index + 2, true)
                stop = close and (close + #level + 1) or length
            else
                stop = (src:find('\n', index, true) or (length + 1)) - 1
            end
            out[#out + 1] = (src:sub(index, stop):gsub('[^\n]', ' '))
            index = stop + 1
        elseif char == '"' or char == "'" then
            local stop = index + 1
            while stop <= length do
                local inner = src:sub(stop, stop)
                if inner == '\\' then
                    stop = stop + 2
                elseif inner == char or inner == '\n' then
                    break
                else
                    stop = stop + 1
                end
            end
            stop = math.min(stop, length)
            out[#out + 1] = src:sub(index, stop)
            index = stop + 1
        elseif char == '[' and src:match('^%[=*%[', index) then
            local level = src:match('^%[(=*)%[', index)
            local close = src:find(']' .. level .. ']', index + 2, true)
            local stop = close and (close + #level + 1) or length
            out[#out + 1] = src:sub(index, stop)
            index = stop + 1
        else
            out[#out + 1] = char
            index = index + 1
        end
    end

    return table.concat(out)
end

--- @param src string
--- @param pos integer
--- @return integer line
local function lineAt(src, pos)
    local _, breaks = src:sub(1, pos):gsub('\n', '')
    return breaks + 1
end

--- Every short-string literal in already-stripped source, with its offset.
--- @param src string
--- @return table[] literals -- { { value, pos }, ... }
local function stringLiterals(src)
    local found, index, length = {}, 1, #src

    while index <= length do
        local char = src:sub(index, index)
        if char == '"' or char == "'" then
            local buffer, cursor = {}, index + 1
            while cursor <= length do
                local inner = src:sub(cursor, cursor)
                if inner == '\\' then
                    buffer[#buffer + 1] = src:sub(cursor, cursor + 1)
                    cursor = cursor + 2
                elseif inner == char or inner == '\n' then
                    break
                else
                    buffer[#buffer + 1] = inner
                    cursor = cursor + 1
                end
            end
            found[#found + 1] = { value = table.concat(buffer), pos = index }
            index = cursor + 1
        else
            index = index + 1
        end
    end

    return found
end

--- The argument list of a call, split at top level. Quote- and depth-aware,
--- so `table.concat(rejected, ', ')` counts as one argument and not three.
--- @param src string
--- @param openPos integer -- index of the '('
--- @return string[]|nil args -- nil when the parentheses never close
--- @return integer|nil closePos
local function splitArgs(src, openPos)
    local args, depth, start = {}, 0, openPos + 1
    local index, length = openPos, #src

    while index <= length do
        local char = src:sub(index, index)

        if char == '"' or char == "'" then
            local cursor = index + 1
            while cursor <= length do
                local inner = src:sub(cursor, cursor)
                if inner == '\\' then
                    cursor = cursor + 2
                elseif inner == char or inner == '\n' then
                    break
                else
                    cursor = cursor + 1
                end
            end
            index = math.min(cursor, length) + 1
        elseif char == '(' or char == '{' or char == '[' then
            depth = depth + 1
            index = index + 1
        elseif char == ')' or char == '}' or char == ']' then
            depth = depth - 1
            if depth == 0 then
                local tail = src:sub(start, index - 1)
                if tail:match('%S') or #args > 0 then args[#args + 1] = tail end
                return args, index
            end
            index = index + 1
        elseif char == ',' and depth == 1 then
            args[#args + 1] = src:sub(start, index - 1)
            start = index + 1
            index = index + 1
        else
            index = index + 1
        end
    end

    return nil, nil
end

--- The contents of an argument that is one plain string literal, or nil for
--- anything else -- a variable, a concatenation, a function call.
--- @param arg string
--- @return string|nil
local function literalOf(arg)
    local trimmed = arg:match('^%s*(.-)%s*$')
    return trimmed:match("^'([^'\\]*)'$") or trimmed:match('^"([^"\\]*)"$')
end

--- @param value any
--- @return boolean
local function looksLikeKey(value)
    if type(value) ~= 'string' then return false end
    local group = value:match('^([a-z][a-z0-9_]*)%.[a-z][a-z0-9_]*$')
    return group ~= nil and KEY_GROUPS[group] == true
end

-- ======================================================================
-- THE SCAN
-- ======================================================================

local files = sourceFiles()

-- Every key-shaped literal anywhere in the source, whether it reaches
-- locale() at that call site or is passed on as a `reason` first.
local referenced = {}       -- [key] = 'file:line'
-- Call sites that name a key AND declare how many substitutions it takes.
local sites = {}            -- { { file, line, name, key, argCount, vararg }, ... }
-- Files whose parentheses could not be walked; a silent scan is worse than
-- a failing one, so these are asserted on rather than skipped.
local malformed = {}
local literalCount = 0

for _, path in ipairs(files) do
    local code = stripComments(readFile(path))
    local shown = path:gsub('^%.%./', '')

    for _, literal in ipairs(stringLiterals(code)) do
        literalCount = literalCount + 1
        if looksLikeKey(literal.value) and not referenced[literal.value] then
            referenced[literal.value] = ('%s:%d'):format(shown, lineAt(code, literal.pos))
        end
    end

    for name, shape in pairs(CALL_SHAPES) do
        local from = 1
        while true do
            local start, open = code:find('%f[%w_]' .. name .. '%s*%(', from)
            if not start then break end

            local args, close = splitArgs(code, open)
            if not args then
                malformed[#malformed + 1] = ('%s:%d (%s)'):format(shown, lineAt(code, start), name)
                break
            end

            local key = args[shape.keyIndex] and literalOf(args[shape.keyIndex])
            if key then
                local vararg = false
                for index = shape.firstArg, #args do
                    if args[index]:match('^%s*%.%.%.%s*$') then vararg = true end
                end
                sites[#sites + 1] = {
                    file = shown,
                    line = lineAt(code, start),
                    name = name,
                    key = key,
                    argCount = math.max(0, #args - (shape.firstArg - 1)),
                    vararg = vararg,
                }
            end

            from = close + 1
        end
    end
end

local jsonKeys = Sandbox.localeKeys()

-- ======================================================================
-- THE SCAN ITSELF
--
-- Every test below is an assertion that a set is empty, and an empty set is
-- exactly what a scanner that read nothing produces. These floors are what
-- separates "clean" from "never looked".
-- ======================================================================

t.test('the scan reached the source it is meant to police', function()
    t.equals(#malformed, 0, 'unwalkable call sites: ' .. table.concat(malformed, ', '))

    for _, dir in ipairs(SOURCE_DIRS) do
        local seen = false
        for _, path in ipairs(files) do
            if path:sub(1, #dir) == dir then seen = true end
        end
        t.isTrue(seen, ('no .lua file found under %s'):format(dir))
    end

    t.isTrue(#files >= 10, ('only %d source file(s) found'):format(#files))
    t.isTrue(literalCount >= 100, ('only %d string literal(s) read'):format(literalCount))
    t.isTrue(#sites >= 10, ('only %d locale call site(s) found'):format(#sites))
    t.isTrue(Sandbox.locale('meta.locale_probe') ~= nil)
end)

-- ======================================================================
-- CODE -> en.json
-- ======================================================================

t.test('every locale() key literal in the source exists in en.json', function()
    local missing = {}
    for _, site in ipairs(sites) do
        if not jsonKeys[site.key] then
            missing[#missing + 1] = ('%s:%d %s(%q)'):format(site.file, site.line, site.name, site.key)
        end
    end
    t.equals(#missing, 0, 'keys asked for and never defined: ' .. table.concat(missing, ' | '))
end)

t.test('every key-shaped literal anywhere in the source exists in en.json', function()
    -- Wider than the call sites above on purpose: Arena.* and the server
    -- files hand keys around as `reason` strings for a caller to print
    -- later, so the string and the locale() that consumes it are usually in
    -- different files.
    local missing = {}
    for key, where in pairs(referenced) do
        if not jsonKeys[key] then
            missing[#missing + 1] = ('%s (%s)'):format(key, where)
        end
    end
    table.sort(missing)
    t.equals(#missing, 0, 'keys named in code and never defined: ' .. table.concat(missing, ' | '))
end)

t.test('every error.* reason shared/arena.lua returns exists in en.json', function()
    -- These are the reasons the panel and the server both render, returned
    -- as bare strings by rules that never call locale() themselves -- so
    -- nothing else in the suite would notice one going missing.
    local code = stripComments(readFile('../shared/arena.lua'))
    local reasons, missing = {}, {}

    for _, literal in ipairs(stringLiterals(code)) do
        if literal.value:match('^error%.[a-z0-9_]+$') and not reasons[literal.value] then
            reasons[literal.value] = true
            if not jsonKeys[literal.value] then missing[#missing + 1] = literal.value end
        end
    end

    local count = 0
    for _ in pairs(reasons) do count = count + 1 end
    -- The contract names twelve. A scan that finds far fewer has stopped
    -- reading the file, not found a tidier rules layer.
    t.isTrue(count >= 10, ('only %d error.* reason(s) found in shared/arena.lua'):format(count))
    table.sort(missing)
    t.equals(#missing, 0, 'reasons returned and never defined: ' .. table.concat(missing, ' | '))
end)

-- ======================================================================
-- en.json -> CODE
-- ======================================================================

t.test('every key in en.json is named somewhere in the source', function()
    local orphans = {}
    for key in pairs(jsonKeys) do
        if not referenced[key] and not ALLOWED_ORPHANS[key] then
            orphans[#orphans + 1] = key
        end
    end
    table.sort(orphans)
    t.equals(#orphans, 0, 'defined and never used: ' .. table.concat(orphans, ' | '))
end)

t.test('every documented orphan is still an orphan, and still in en.json', function()
    -- An exception that has quietly become wrong is worse than no exception
    -- list at all: it is a hole in the check above with a reason attached.
    for key, why in pairs(ALLOWED_ORPHANS) do
        t.isTrue(jsonKeys[key] == true, ('%s is excused as an orphan but is not in en.json'):format(key))
        t.isNil(referenced[key],
            ('%s is excused as an orphan (%s) but %s names it -- drop the exception'):format(key, why, tostring(referenced[key])))
    end
end)

-- ======================================================================
-- PLACEHOLDERS
-- ======================================================================

--- How many substitutions a format string consumes. `%%` is a literal
--- percent and consumes nothing.
--- @param text string
--- @return integer count
--- @return string|nil broken -- the first `%` that is no format spec at all
local function placeholderCount(text)
    local count, index = 0, 1

    while true do
        local at = text:find('%%', index)
        if not at then return count, nil end

        if text:sub(at + 1, at + 1) == '%' then
            index = at + 2
        else
            local _, stop = text:find('^[-+ #0]*%d*%.?%d*[cdiouxXeEfgGqs]', at + 1)
            if not stop then return count, text:sub(at, at + 4) end
            count = count + 1
            index = stop + 1
        end
    end
end

t.test('no string in en.json carries a broken format spec', function()
    local broken = {}
    for key in pairs(jsonKeys) do
        local _, bad = placeholderCount(Sandbox.locale(key))
        if bad then broken[#broken + 1] = ('%s (%q)'):format(key, bad) end
    end
    table.sort(broken)
    t.equals(#broken, 0, 'string.format would raise on: ' .. table.concat(broken, ' | '))
end)

t.test('every call site passes exactly as many substitutions as its string takes', function()
    -- Too few and string.format raises inside an event handler; too many and
    -- the extra is silently dropped, which is how a message loses the one
    -- number it existed to carry.
    local wrong, checked = {}, 0

    for _, site in ipairs(sites) do
        if jsonKeys[site.key] and not site.vararg then
            local wanted = placeholderCount(Sandbox.locale(site.key))
            checked = checked + 1
            if wanted ~= site.argCount then
                wrong[#wrong + 1] = ('%s:%d %s(%q) passes %d for %d placeholder(s)')
                    :format(site.file, site.line, site.name, site.key, site.argCount, wanted)
            end
        end
    end

    t.isTrue(checked >= 10, ('only %d call site(s) were checked'):format(checked))
    table.sort(wrong)
    t.equals(#wrong, 0, table.concat(wrong, ' | '))
end)

os.exit(t.summary())
