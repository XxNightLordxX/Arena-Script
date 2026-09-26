--[[
    crimson_arena/tests/localheadroom_spec.lua

    NO FILE THE MANIFEST LOADS GETS WITHIN TWENTY LOCALS OF LUA'S LIMIT.

    Lua 5.4 lets one function hold at most 200 active local variables, and a
    file's main chunk is a function like any other. One more than that and
    the file does not compile: `too many local variables (limit is 200) in
    main function`. For a server file that means the file does not load, and
    every global it defines is nil for the rest of the session -- for
    server/ammo.lua that is every stash, every kit and every hand-back path.

    server/ammo.lua's main chunk grew from 9 file-level locals to 169 in under
    a month. The parse gate (tests/run.sh, and CI's `Every Lua file parses`)
    does see the limit, but only on the day it is crossed, when the change
    that crosses it is already written and the fix is a refactor. This spec
    names the file while there is still room to do that calmly.

    HOW. Each file's source gets HEADROOM lines of `local _headroomProbe =
    nil` appended and is COMPILED ONLY -- load() with an empty environment,
    never called -- so nothing in the file runs and no fixture is needed. If
    the probed source compiles, the file has at least HEADROOM locals left.
    If not, the failure carries the compiler's own message. It is plain Lua:
    no luac, no debug library.

    THIS SPEC IS MEANT TO GO RED, AND SOON. With HEADROOM at 20 it fails the
    day any file's main chunk reaches 181 active locals. server/ammo.lua
    reached 169; moving its twelve SQL statements into one table took it back
    to 158 -- 23 away -- and nothing else is above 120.
    When it fires, the remedy is moving file-level locals into tables or
    splitting the file, and that is a refactor of its own with its own
    vetting: the trap in it is the FORWARD-DECLARED local (`local
    markWeaponOut, strikeWeaponOff` in server/ammo.lua), which a careless move
    turns into a global that compiles and is nil at run time. HANDOFF.md
    section 8 ("The declaration is in the file, so it is in scope") is the
    time that nearly shipped, and CI's `No local is used before it is
    defined` gate is the check for it. If the owner would rather not have a
    red build that early, HEADROOM is the setting to change -- one line, an
    owner's choice, not a safety question. The pin on it below is so that
    the change is made on purpose and not by a stray edit.

    THERE IS NO ENVIRONMENT SWITCH FOR IT, deliberately. tests/run.sh
    explains why: a switch to turn a guard off is how the guard stops
    guarding. A test below reads this file to keep it that way.

    WHAT IT DOES NOT SEE, stated so that a pass is not read as more than it
    is:

      ONLY THE END OF EACH MAIN CHUNK. The probe measures the locals still
      active when the file ends. A peak inside a block mid-file is not seen:
      server/dispatch.lua peaks at 85 inside one while 77 are active at its
      end.

      NESTED FUNCTIONS ARE NOT CHECKED. Each has its own 200, and the
      largest -- a single function in shared/arena.lua -- declares 275
      locals over its length but never has more than 45 active at once.

      BOTH PEAKS ARE THE COMPILER'S COUNT, WHICH IS NOT THE NAMED LOCALS.
      Every `for` holds hidden slots of its own for as long as it runs --
      three for a numeric loop, four for a generic one -- and they count
      toward the 200 exactly as a named local does. Of the two peaks above,
      81 and 33 are named; the rest are loops. Measured by appending locals
      at the peak until the compile failed, not by counting names.

      THE HARD LIMIT ITSELF is still the parse gate's to catch, in both of
      those cases.

      FIVEM'S CFXLUA IS ASSUMED TO SHARE PLAIN LUA 5.4'S LIMIT OF 200. The
      parse gate already assumes the same; it could not be confirmed
      offline.

    THE FILE LIST IS THE MANIFEST'S. Sandbox.readDeclarations runs
    fxmanifest.lua and Sandbox.realmScripts reads both realms from it, the
    same way tests/hudscope_spec.lua does, so a file added to the manifest is
    checked from its first commit and the `@ox_lib`/`@qbx_core` includes,
    which are other resources' files, are not.

    AND WHAT realmScripts DOES NOT READ IS READ HERE AS WELL. It reads the
    plural lists only. FiveM takes `server_script 'x.lua'` exactly as it
    takes the list form, and a plural handed one string instead of a table
    loads that file too. realmScripts sees neither: a 190-local file added
    with `server_script` was measured passing this spec unchecked. So the
    manifest is also run here with every script directive recorded, in any
    form; and a test holds the list to the manifest's own text, so a file
    that reaches the manifest by a road neither reader knows fails by name.

    A FILE THAT STARTS WITH A UTF-8 BYTE-ORDER MARK, OR WITH A `#` LINE, IS
    REPORTED AS THAT AND FAILS. luac and loadfile skip both, so the parse
    gate and every spec that loads the file pass it; load() on the file's
    text -- which is what this spec does -- does not. Whether FXServer's
    loader skips them could not be confirmed offline, so this spec does not
    assume it does: nothing in this resource needs either, and removing
    them is the fix. It is never reported as a file that does not compile,
    which is what a bare load() error makes it look like.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('localheadroom_spec')

-- THE OWNER'S SETTING. Hard-coded on purpose: see the header. Lowering it
-- buys a later red build, not a safer file.
local HEADROOM = 20

-- Lua 5.4's MAXVARS (lparser.c). Not a setting: the compiler's own number,
-- written here so the boundary tests below can name it.
local LIMIT = 200

-- One local per line. `nil` rather than a constant, so the probe can never be
-- folded away as a compile-time constant by a future compiler.
local PROBE_LINE = 'local _headroomProbe = nil\n'

--- @param path string
--- @return string
local function read(path)
    local handle = assert(io.open(path, 'r'), ('%s is missing'):format(path))
    local text = handle:read('a')
    handle:close()
    return text
end

--- The six directives a manifest names a script with: each realm, singular
--- and plural. FiveM treats the two forms of each as one list.
local SCRIPT_DIRECTIVES = {
    shared_script = true, shared_scripts = true,
    client_script = true, client_scripts = true,
    server_script = true, server_scripts = true,
}

--- Every entry of every script directive in a manifest's source, in the
--- order written: singular or plural, one string or a list, `@` includes
--- and all. Runs the manifest the way FiveM does -- each directive is a call
--- -- with every call recorded rather than the last one kept.
---
--- WHY NOT Sandbox.readDeclarations ALONE. It keeps one value per directive
--- name, so `server_script` written twice keeps the second; and
--- Sandbox.realmScripts reads the plural lists only, walking them with
--- ipairs, which finds nothing in a plural handed one string. Either way a
--- file FiveM loads is not checked, and nothing says so.
--- @param text string -- fxmanifest.lua's source
--- @param chunkname string
--- @return string[] entries
local function scriptEntries(text, chunkname)
    local entries = {}

    local function record(value)
        if type(value) == 'string' then
            entries[#entries + 1] = value
        elseif type(value) == 'table' then
            for _, entry in ipairs(value) do
                if type(entry) == 'string' then entries[#entries + 1] = entry end
            end
        end
    end

    -- Any directive at all is a call that takes a value and may be called
    -- again (`data_file 'KIND' 'path'`), so every name answers with a
    -- function that answers with itself; only the script ones record.
    local env = setmetatable({}, {
        __index = function(_, key)
            local directive
            directive = function(value)
                if SCRIPT_DIRECTIVES[key] then record(value) end
                return directive
            end
            return directive
        end,
    })

    local chunk = assert(load(text, chunkname, 't', env))
    chunk()
    return entries
end

--- The files to check, from both readers: what Sandbox.realmScripts reads
--- for each realm first, in manifest order, then anything the full read
--- above found that it did not. Shared files once, and no `@` include.
--- @param manifest table -- from Sandbox.readDeclarations
--- @param entries string[] -- from scriptEntries
--- @return string[] names -- relative to Crimson-Arena/, as the manifest writes them
local function filesOf(manifest, entries)
    local seen, names = {}, {}

    local function add(name)
        -- The shared scripts are in BOTH realms' lists, and every plural
        -- entry is in `entries` as well; one compile of each is the same
        -- answer twice.
        if type(name) ~= 'string' or name:find('^@') or seen[name] then return end
        seen[name] = true
        names[#names + 1] = name
    end

    for _, realm in ipairs({ 'client', 'server' }) do
        for _, name in ipairs(Sandbox.realmScripts(manifest, realm)) do add(name) end
    end
    for _, name in ipairs(entries) do add(name) end
    return names
end

--- Every Lua file fxmanifest.lua loads, shared ones once, in manifest order.
---
--- `text` stands in for the file's source in the full read, so a test can
--- hand it the real manifest with a line added and see that line's file
--- come back; the spec itself never passes it.
--- @param path string
--- @param text string|nil
--- @return string[] names -- relative to Crimson-Arena/, as the manifest writes them
local function manifestFiles(path, text)
    return filesOf(Sandbox.readDeclarations(path), scriptEntries(text or read(path), '@' .. path))
end

--- Compiles `source` with `count` probe locals appended to its main chunk.
--- Runs nothing.
---
--- THE NEWLINE IN FRONT IS LOAD-BEARING. A file whose last line is a `--`
--- comment with no newline after it would otherwise swallow the first probe
--- line into that comment, and the check would pass one local short -- or,
--- with HEADROOM probes on one line, pass with none at all.
--- @param source string
--- @param chunkname string
--- @param count integer
--- @return function|nil chunk
--- @return string|nil err
local function compileWithProbes(source, chunkname, count)
    return load(source .. '\n' .. PROBE_LINE:rep(count), chunkname, 't', {})
end

--- What luaL_loadfile skips at the very start of a file and load() does
--- not: a UTF-8 byte-order mark, and after it a first line that starts with
--- `#`. Named, so that a failure says which instead of "does not compile".
--- @param source string
--- @return string|nil what
local function skippedPrefix(source)
    if source:sub(1, 3) == '\239\187\191' then return 'a UTF-8 byte-order mark' end
    if source:sub(1, 1) == '#' then return 'a first line that starts with `#`' end
    return nil
end

--- Whether `source` keeps `headroom` locals free at the end of its main chunk.
---
--- FOUR ANSWERS, NOT TWO, because a failure has to say which it is. A file
--- that does not compile at all is the parse gate's business and must not be
--- reported as a headroom problem; a file that starts with what only luac
--- skips (see the header) must not be reported as one that does not
--- compile; and a file whose probed copy fails for any reason OTHER than the
--- local limit -- today none, but a file ending in a top-level `return`
--- would fail with "'<eof>' expected" -- has not been measured at all. Only
--- the first answer below is a pass.
--- @param source string
--- @param chunkname string
--- @param headroom integer
--- @return boolean ok
--- @return string|nil why
local function check(source, chunkname, headroom)
    local prefix = skippedPrefix(source)
    if prefix then
        return false, ('starts with %s, which luac and loadfile skip and load() does not, so nothing was measured -- remove it')
            :format(prefix)
    end

    local plain, plainErr = load(source, chunkname, 't', {})
    if not plain then
        return false, ('does not compile at all, before any probe: %s'):format(tostring(plainErr))
    end

    local probed, err = compileWithProbes(source, chunkname, headroom)
    if probed then return true end

    if tostring(err):find('too many local variables', 1, true) then
        return false, ('has fewer than %d file-level locals left before Lua\'s limit of %d: %s')
            :format(headroom, LIMIT, tostring(err))
    end
    return false, ('could not be probed -- the probed copy fails for a reason other than the local limit, so nothing was measured: %s')
        :format(tostring(err))
end

--- How many more main-chunk locals `source` can take before it stops
--- compiling, or nil when that cannot be measured -- the same three cases
--- check() refuses to pass. For the test names, which show the trend on a
--- green run, and for the tests of the mechanism; the pass/fail above does
--- not depend on it. A nil shows as "not measured" rather than as 0, which
--- read as a file with no room at all when it was a file nothing had
--- measured.
--- @param source string
--- @param chunkname string
--- @return integer|nil spare
local function spareLocals(source, chunkname)
    -- A file that starts with what only luac skips fails this load too.
    if not load(source, chunkname, 't', {}) then return nil end

    -- Compiles succeed for every count up to the spare and fail for every
    -- count above it, so a binary search over 0..LIMIT finds it.
    local low, high = 0, LIMIT
    while low < high do
        local mid = (low + high + 1) // 2
        if compileWithProbes(source, chunkname, mid) then low = mid else high = mid - 1 end
    end

    -- And the count above it must fail for THE LIMIT. A file ending in a
    -- top-level `return` fails at one probe for another reason entirely,
    -- and "0 left" is not what that means.
    if low < LIMIT then
        local _, err = compileWithProbes(source, chunkname, low + 1)
        if not tostring(err):find('too many local variables', 1, true) then return nil end
    end
    return low
end

--- Every name assertHeadroom has passed, in order, so the test after the
--- per-file ones can see that every file went through THAT assertion -- a
--- per-file test that lost the call would otherwise pass on its own.
local measured = {}

--- The assertion each file's own test makes. A function rather than inline
--- so the tests of the mechanism below can hand it a file that is over the
--- line and prove it fails -- on today's tree every real file passes, so
--- nothing else would notice this assertion going missing.
--- @param name string -- as the manifest writes it
--- @param source string
local function assertHeadroom(name, source)
    local ok, why = check(source, '@' .. name, HEADROOM)
    t.isTrue(ok, ('%s %s'):format(name, tostring(why)))
    measured[#measured + 1] = name
end

--- The per-file test's name. The spare count goes in it so a green run
--- still shows the trend in the log; a file nothing could measure says so
--- rather than showing a count it does not have.
--- @param name string
--- @param spare integer|nil -- from spareLocals
--- @return string
local function perFileName(name, spare)
    return ('%s compiles, and keeps %d locals free at the end of its main chunk (%s)')
        :format(name, HEADROOM, spare and (spare .. ' left') or 'not measured')
end

--- A source with exactly `count` file-level locals and nothing else.
--- @param count integer
--- @return string
local function syntheticWith(count)
    local lines = {}
    for index = 1, count do lines[index] = ('local v%d = %d'):format(index, index) end
    return table.concat(lines, '\n')
end

-- ======================================================================
-- THE LIST IS THE MANIFEST'S, AND IT IS ALL OF IT
-- ======================================================================

local MANIFEST_PATH = '../Crimson-Arena/fxmanifest.lua'

local FILES = manifestFiles(MANIFEST_PATH)

t.test('the manifest yields every Lua file it loads, at least fifteen of them', function()
    -- 19 as this is written. A floor rather than an exact count, so a file
    -- added to the manifest is simply checked; a read that came back nearly
    -- empty is what this is for.
    t.isTrue(#FILES >= 15, ('only %d files came back from fxmanifest.lua'):format(#FILES))
end)

t.test('the list covers both realms and the shared scripts, and the largest files', function()
    local present = {}
    for _, name in ipairs(FILES) do present[name] = true end
    -- One from each list, and the two files nearest the limit.
    for _, name in ipairs({ 'config.lua', 'shared/arena.lua', 'client/match.lua',
                            'server/ammo.lua', 'server/exports.lua', 'client/exports.lua' }) do
        t.isTrue(present[name] == true, ('%s is loaded by the manifest and is not checked here'):format(name))
    end
end)

t.test('no other resource\'s include is in the list, and no file is in it twice', function()
    local seen = {}
    for _, name in ipairs(FILES) do
        t.isNil(name:find('^@'), ('%s is another resource\'s file, not this one\'s'):format(name))
        t.isNil(seen[name], ('%s is listed twice'):format(name))
        seen[name] = true
    end
end)

--- `text` with every comment blanked: long comments by
--- Sandbox.blankLongComments, and a `--` outside a quoted string cut to the
--- end of its line. For the manifest, whose comments name files it
--- deliberately does not load, and for this file's own switch check.
---
--- `quotedToo` blanks what is inside each quoted string as well, for a
--- check about code that a message quoting the same characters must not
--- trip. Quotes only: a long-bracket string is left as it is, and the quote
--- state ends with the line, which is all either use needs.
--- @param text string
--- @param quotedToo boolean|nil
--- @return string
local function codeOf(text, quotedToo)
    local lines = {}
    for line in (Sandbox.blankLongComments(text) .. '\n'):gmatch('(.-)\n') do
        local out, quote, index = {}, nil, 1
        while index <= #line do
            local char = line:sub(index, index)
            if quote then
                local width = char == '\\' and 2 or 1
                if char == quote then quote = nil end
                out[#out + 1] = (quotedToo and quote) and (' '):rep(width) or line:sub(index, index + width - 1)
                index = index + width
            elseif line:sub(index, index + 1) == '--' then
                break
            else
                if char == "'" or char == '"' then quote = char end
                out[#out + 1] = char
                index = index + 1
            end
        end
        lines[#lines + 1] = table.concat(out)
    end
    return table.concat(lines, '\n')
end

--- Every quoted `*.lua` name in a manifest's code that is not another
--- resource's `@` include, in order.
--- @param text string
--- @return string[]
local function quotedLuaNames(text)
    local names = {}
    for _, name in codeOf(text):gmatch([=[(['"])(.-)%1]=]) do
        if name:find('%.lua$') and not name:find('^@') then names[#names + 1] = name end
    end
    return names
end

t.test('every Lua file the manifest\'s text names is in the list, and nothing else is', function()
    -- THE LIST HELD TO THE TEXT, whatever read it. A file that reaches the
    -- manifest by a directive neither reader knows, or a list that stopped
    -- being read from the manifest at all, fails here on the commit that
    -- adds the file.
    local present, named = {}, {}
    for _, name in ipairs(FILES) do present[name] = true end
    local names = quotedLuaNames(read(MANIFEST_PATH))
    t.isTrue(#names >= 15, ('only %d Lua names found in the manifest\'s text'):format(#names))
    for _, name in ipairs(names) do
        named[name] = true
        t.isTrue(present[name] == true, ('the manifest names %s and it is not checked here'):format(name))
    end
    for _, name in ipairs(FILES) do
        t.isTrue(named[name] == true, ('%s is checked here and the manifest does not name it'):format(name))
    end
end)

t.test('a file named in the singular, or by a plural given one string, is read too', function()
    -- The measured gap: realmScripts reads neither form, and a 190-local
    -- file added with `server_script` was not checked at all.
    local text = table.concat({
        "fx_version 'cerulean'",
        "data_file 'DLC_ITYP_REQUEST' 'stream/x.ytyp'",
        "shared_scripts { '@ox_lib/init.lua', 'config.lua' }",
        "client_script 'client/one.lua'",
        "server_scripts 'server/two.lua'",
        "server_script { 'server/three.lua', 'server/four.lua' }",
        "shared_script 'shared/five.lua'",
        "server_script 'server/two.lua'",
        "files { 'html/app.js', 'not/a/script.lua' }",
        "client_scripts { 'client/six.lua', 7, false }",
    }, '\n')
    t.equals(table.concat(scriptEntries(text, '@synthetic/fxmanifest.lua'), ','),
        '@ox_lib/init.lua,config.lua,client/one.lua,server/two.lua,server/three.lua,server/four.lua,'
        .. 'shared/five.lua,server/two.lua,client/six.lua')

    -- Merged with what realmScripts read, which comes first; every file
    -- once, no include, and nothing from a directive that is not a script.
    local manifest = { shared_scripts = { '@ox_lib/init.lua', 'config.lua' }, client_scripts = { 'client/six.lua' },
                       server_scripts = 'server/two.lua' }
    t.equals(table.concat(filesOf(manifest, scriptEntries(text, '@synthetic/fxmanifest.lua')), ','),
        'config.lua,client/six.lua,client/one.lua,server/two.lua,server/three.lua,server/four.lua,shared/five.lua')
end)

t.test('on the real manifest, a server_script line added at the end is checked', function()
    for _, line in ipairs({ "server_script 'server/_probe_only_extra.lua'", "server_scripts 'server/_probe_only_extra.lua'",
                            "shared_script 'server/_probe_only_extra.lua'", "client_script { 'server/_probe_only_extra.lua' }" }) do
        local files = manifestFiles(MANIFEST_PATH, read(MANIFEST_PATH) .. '\n' .. line .. '\n')
        t.equals(files[#files], 'server/_probe_only_extra.lua', line)
        t.equals(#files, #FILES + 1, line)
    end
    -- And the list this spec checks is that same read of the real file, not
    -- something written down beside it.
    t.equals(table.concat(manifestFiles(MANIFEST_PATH, read(MANIFEST_PATH)), ','), table.concat(FILES, ','))
    local own = read('localheadroom_spec.lua')
    t.isNotNil(own:find('\n' .. 'local FILES = manifest' .. 'Files(MANIFEST_PATH)\n', 1, true),
        'FILES is not read from the manifest')
end)

t.test('a manifest with no script directive at all yields nothing, and the merge copes', function()
    t.equals(#scriptEntries("fx_version 'cerulean'\ngame 'gta5'\n", '@synthetic/empty.lua'), 0)
    t.equals(#scriptEntries('', '@synthetic/empty.lua'), 0)
    t.equals(#filesOf({}, {}), 0)
    t.equals(table.concat(filesOf({}, { '@a/b.lua', 'x.lua', 'x.lua' }), ','), 'x.lua')
end)

t.test('the manifest\'s comments name nothing the text check would count', function()
    -- `'@oxmysql/lib/MySQL.lua' is NOT listed on purpose` is in a comment;
    -- a name in a comment is not a file FiveM loads, and a check that read
    -- comments would cry wolf the first time one quoted a local path.
    t.equals(table.concat(quotedLuaNames("-- 'server/not.lua'\nserver_script 'server/yes.lua' -- 'x.lua'\n"
        .. "--[[ 'y.lua' ]] server_script \"server/also.lua\"\n"), ','), 'server/yes.lua,server/also.lua')
    t.equals(table.concat(quotedLuaNames("description 'a -- b'\nserver_script 'z.lua'"), ','), 'z.lua')

    -- And the blanking the switch check below relies on: what is quoted
    -- goes, escapes included, the quotes and the code around them stay.
    t.equals(codeOf("x('a...b', \"c\\\"...\") -- ...\ny = z ... w", true), "x('     ', \"      \") \ny = z ... w")
    t.equals(codeOf("x('a...b') -- c"), "x('a...b') ")
end)

-- ======================================================================
-- THE CHECK ITSELF, ONE TEST PER FILE
-- ======================================================================

for _, name in ipairs(FILES) do
    local chunkname = '@' .. name
    -- Read here rather than in the test so the spare count can go in the
    -- test's NAME -- a green run then still shows the trend in the log. The
    -- pass itself is the probe compile inside, not that count; and a file
    -- the manifest names that cannot be read fails its own test instead of
    -- stopping the spec.
    local readable, source = pcall(read, '../Crimson-Arena/' .. name)
    local spare = readable and spareLocals(source, chunkname) or nil

    t.test(perFileName(name, spare), function()
        t.isTrue(readable, tostring(source))
        assertHeadroom(name, source)
    end)
end

t.test('every file in the list was checked, and passed', function()
    -- A loop that quietly checked nothing would leave every test above
    -- green by leaving it out; so would a per-file test that lost its
    -- assertion. Every file, in order, through assertHeadroom, and passed.
    t.equals(table.concat(measured, ','), table.concat(FILES, ','))
end)

-- ======================================================================
-- THE MECHANISM BITES, ON BOTH SIDES OF THE LINE
-- ======================================================================

t.test('the shipped headroom is twenty, and changing it is a decision made here', function()
    -- The pin the header promises. Edit both lines together or neither.
    t.equals(HEADROOM, 20)
    t.equals(LIMIT, 200)
end)

t.test('a file exactly HEADROOM short of the limit passes; one local more fails with the compiler\'s message', function()
    local atLine = syntheticWith(LIMIT - HEADROOM)
    local ok, why = check(atLine, '@synthetic/at.lua', HEADROOM)
    t.isTrue(ok, 'a file with exactly HEADROOM locals to spare must pass: ' .. tostring(why))

    local over = syntheticWith(LIMIT - HEADROOM + 1)
    ok, why = check(over, '@synthetic/over.lua', HEADROOM)
    t.isFalse(ok, 'a file one local past the line must fail')
    t.contains(why, ('fewer than %d file-level locals left'):format(HEADROOM))
    -- The compiler's own words, and the chunk name, so the failure names
    -- the file without anybody having to go and find it.
    t.contains(why, 'too many local variables (limit is 200)')
    t.contains(why, 'synthetic/over.lua')
end)

t.test('the spare count is the compiler\'s: a file of N locals has 200 - N left', function()
    for _, count in ipairs({ 0, 1, 42, 169, 180, 181, 199, 200 }) do
        t.equals(spareLocals(syntheticWith(count), '@synthetic/n.lua'), LIMIT - count,
            ('spare locals for a file of %d'):format(count))
    end
end)

t.test('a file whose last line is a comment with no newline is still probed', function()
    -- Without the newline compileWithProbes puts in front, the first probe
    -- line lands inside the comment and a file one local over the line
    -- passes. Both sides, so a probe that went missing entirely fails too.
    local ok = check(syntheticWith(LIMIT - HEADROOM) .. '\n-- the end, with no newline', '@synthetic/c.lua', HEADROOM)
    t.isTrue(ok, 'exactly at the line, ending in a comment')

    local why
    ok, why = check(syntheticWith(LIMIT - HEADROOM + 1) .. '\n-- the end, with no newline', '@synthetic/c.lua', HEADROOM)
    t.isFalse(ok, 'one over the line, ending in a comment, must still fail')
    t.contains(why, 'too many local variables')
end)

t.test('a file ending in a top-level return is reported as not measured, never passed', function()
    local ok, why = check('local a = 1\nreturn a', '@synthetic/r.lua', HEADROOM)
    t.isFalse(ok, 'nothing was measured, so it must not pass')
    t.contains(why, 'could not be probed')
    t.notContains(why, 'fewer than')
end)

t.test('a file that does not compile is reported as that, not as a headroom problem', function()
    local ok, why = check('local = = broken', '@synthetic/b.lua', HEADROOM)
    t.isFalse(ok)
    t.contains(why, 'does not compile at all')
    t.notContains(why, 'could not be probed')
    t.notContains(why, 'fewer than')
end)

t.test('the per-file assertion fails every file that was not measured, not only check()', function()
    -- The 19 per-file tests go through assertHeadroom, so it is what has to
    -- refuse these; check() refusing them is not enough on its own if the
    -- assertion is loosened to let one through.
    for _, case in ipairs({
        { 'synthetic/r.lua', 'local a = 1\nreturn a', 'could not be probed' },
        { 'synthetic/b.lua', 'local = = broken', 'does not compile at all' },
        { 'synthetic/bom.lua', '\239\187\191local a = 1', 'byte-order mark' },
        { 'synthetic/hash.lua', '#!/usr/bin/lua\nlocal a = 1', 'starts with `#`' },
        { 'synthetic/over.lua', syntheticWith(LIMIT - HEADROOM + 1), 'fewer than' },
    }) do
        local passed, message = pcall(assertHeadroom, case[1], case[2])
        t.isFalse(passed, case[1] .. ' passed the per-file assertion')
        t.contains(tostring(message), case[1])
        t.contains(tostring(message), case[3])
    end
    -- And one that is fine still passes it, so the above is not a function
    -- that fails everything.
    t.isTrue((pcall(assertHeadroom, 'synthetic/fine.lua', syntheticWith(LIMIT - HEADROOM))))
end)

t.test('a byte-order mark or a # line is reported as that, never as a file that does not compile', function()
    local config = read('../Crimson-Arena/config.lua')
    t.isTrue((check(config, '@config.lua', HEADROOM)), 'config.lua as shipped must pass')

    for _, case in ipairs({
        { '\239\187\191', 'a UTF-8 byte-order mark' },
        { '#!/usr/bin/env lua\n', 'a first line that starts with `#`' },
        { '\239\187\191#!/usr/bin/env lua\n', 'a UTF-8 byte-order mark' },
    }) do
        local ok, why = check(case[1] .. config, '@config.lua', HEADROOM)
        t.isFalse(ok, 'nothing was measured, so it must not pass')
        t.contains(why, 'starts with ' .. case[2])
        t.contains(why, 'remove it')
        t.notContains(why, 'does not compile')
        t.notContains(why, 'fewer than')
        t.isNil(spareLocals(case[1] .. config, '@config.lua'), 'a spare count for a file nothing measured')
    end

    -- The two bytes of a mark, or a `#` further in, are not what luac skips,
    -- and are left to the ordinary answers.
    local ok, why = check('\239\187local a = 1', '@synthetic/half.lua', HEADROOM)
    t.isFalse(ok)
    t.contains(why, 'does not compile at all')
    t.isTrue((check('local a = 1\n-- # not first\n', '@synthetic/later.lua', HEADROOM)))
end)

t.test('a file nothing measured shows "not measured" in its test name, never a count', function()
    t.isNil(spareLocals('local a = 1\nreturn a', '@synthetic/r.lua'), 'a return-ending file has no spare count')
    t.isNil(spareLocals('local = = broken', '@synthetic/b.lua'), 'a broken file has no spare count')
    -- Nor one already past the limit, which fails for the limit at every
    -- count and would otherwise read as "0 left" on a file that does not
    -- compile.
    t.isNil(spareLocals(syntheticWith(LIMIT + 1), '@synthetic/past.lua'), 'a file past the limit has no spare count')
    t.contains(select(2, check(syntheticWith(LIMIT + 1), '@synthetic/past.lua', HEADROOM)), 'does not compile at all')
    t.equals(spareLocals(syntheticWith(LIMIT), '@synthetic/full.lua'), 0, 'a full file is measured at 0')
    t.equals(spareLocals(syntheticWith(1), '@synthetic/one.lua'), LIMIT - 1)

    t.contains(perFileName('x.lua', nil), '(not measured)')
    t.contains(perFileName('x.lua', 0), '(0 left)')
    t.contains(perFileName('x.lua', 31), '(31 left)')
    t.contains(perFileName('x.lua', 31), ('keeps %d locals free'):format(HEADROOM))
end)

t.test('an empty file passes with all 200 free', function()
    t.isTrue((check('', '@synthetic/empty.lua', HEADROOM)))
    t.equals(spareLocals('', '@synthetic/empty.lua'), LIMIT)
end)

t.test('the probe compiles and never runs: nothing in the file is executed', function()
    -- A file that would throw the moment it ran. If the check ever calls
    -- the chunk it compiled, this fails.
    local ok, why = check('error("this file was run")', '@synthetic/run.lua', HEADROOM)
    t.isTrue(ok, tostring(why))

    -- AND NOT EVEN UNDER A pcall, which the line above cannot see: a chunk
    -- with an empty environment has no other way to be noticed. So a line
    -- hook watches for any line of the synthetic file being run, through
    -- check() and spareLocals() both. The mechanism itself uses no debug
    -- library; only this test does, to watch it.
    local ran = {}
    debug.sethook(function()
        local info = debug.getinfo(2, 'S')
        if info and info.source == '@synthetic/watched.lua' then ran[#ran + 1] = true end
    end, 'l')
    local watchedOk = check('local a = 1\nlocal b = a + 1\n', '@synthetic/watched.lua', HEADROOM)
    local watchedSpare = spareLocals('local a = 1\nlocal b = a + 1\n', '@synthetic/watched.lua')
    debug.sethook()
    t.isTrue(watchedOk)
    t.equals(watchedSpare, LIMIT - 2)
    t.equals(#ran, 0, 'lines of the checked file were run')

    -- And the hook does see a chunk that IS run, so the zero above means
    -- something.
    debug.sethook(function()
        local info = debug.getinfo(2, 'S')
        if info and info.source == '@synthetic/watched.lua' then ran[#ran + 1] = true end
    end, 'l')
    pcall(load('local a = 1\nlocal b = a + 1\n', '@synthetic/watched.lua', 't', {}))
    debug.sethook()
    t.isTrue(#ran > 0, 'the hook did not see a chunk that was run')
end)

t.test('the header\'s stated limits are true: block and nested-function locals are not counted', function()
    -- Written down as tests so the header cannot overclaim. If this spec is
    -- ever widened to see them, these are the two to turn round.
    local inBlock = 'do\n' .. syntheticWith(LIMIT - 1) .. '\nend'
    t.isTrue((check(inBlock, '@synthetic/block.lua', HEADROOM)), 'a mid-file block peak is not seen')

    local nested = 'local function f()\n' .. syntheticWith(LIMIT - 1) .. '\nend'
    t.isTrue((check(nested, '@synthetic/nested.lua', HEADROOM)), 'a nested function is not checked')
end)

t.test('growing the real server/ammo.lua past the line turns this spec red while it still parses', function()
    -- THE PROOF IT BITES ON THE FILE IT WAS WRITTEN FOR, worked out from
    -- today's count so it keeps working as the file changes: the most it
    -- can grow and still pass, then one more.
    local source = read('../Crimson-Arena/server/ammo.lua')
    local spare = spareLocals(source, '@server/ammo.lua')
    local room = spare - HEADROOM
    t.isTrue(room >= 0, ('server/ammo.lua is already inside the headroom (%d left)'):format(spare))

    local grown = source .. '\n' .. ('local _grown = nil\n'):rep(room)
    t.isTrue((check(grown, '@server/ammo.lua', HEADROOM)), ('+%d must still pass'):format(room))
    assertHeadroom('server/ammo.lua', grown)

    local tooFar = source .. '\n' .. ('local _grown = nil\n'):rep(room + 1)
    local ok, why = check(tooFar, '@server/ammo.lua', HEADROOM)
    t.isFalse(ok, ('+%d must fail'):format(room + 1))
    t.contains(why, 'server/ammo.lua')
    t.contains(why, 'too many local variables (limit is 200)')
    -- And the per-file test's own assertion fails on it, with the message
    -- CI would print.
    local passed, message = pcall(assertHeadroom, 'server/ammo.lua', tooFar)
    t.isFalse(passed, 'the per-file assertion let a file over the line through')
    t.contains(message, 'server/ammo.lua has fewer than')
    -- The compiler's own location too, file and line, so the chunk name the
    -- per-file test compiles under is the file's.
    t.isNotNil(tostring(message):find('server/ammo.lua:%d+: too many local variables'),
        'the compiler\'s message does not name the file and line: ' .. tostring(message))
    -- And the parse gate would not yet have seen it: that is the point.
    t.isNotNil(load(tooFar, '@server/ammo.lua', 't', {}), 'the grown file must still compile on its own')
end)

t.test('the headroom has no switch: this file reads no environment variable and no argument', function()
    -- A guard with an off switch is not a guard (tests/run.sh). Built from
    -- pieces throughout so these lines do not match themselves.
    local own = read('localheadroom_spec.lua')

    -- THE LINE ITSELF, EXACTLY, AND IT IS THE ONLY ASSIGNMENT. Banning the
    -- spellings of a switch misses the next spelling -- `(...)`,
    -- `os['getenv']`, a file read -- and every one of them has to either
    -- change this line or assign HEADROOM a second time.
    t.isNotNil(own:find('\n' .. 'local HEAD' .. 'ROOM = 20\n', 1, true), 'the HEADROOM line is not the plain constant')
    local _, assignments = codeOf(own):gsub('%f[%w_]HEAD' .. 'ROOM%s*=[^=]', '')
    t.equals(assignments, 1, 'assignments to HEADROOM')

    -- And the spellings too, in any form, so a switch that reaches the
    -- check some other way than through HEADROOM is still named.
    -- `os['getenv']` spells the name inside a string, so that one is read
    -- with the strings kept; `...` inside a message is not a switch, so that
    -- one is read with them blanked.
    local code = codeOf(own)
    t.isNil(code:find('get' .. 'env', 1, true), 'an environment switch was added')
    t.isNil(code:find('%f[%w_]' .. 'arg' .. '%s*%['), 'a command-line switch was added')
    t.isNil(codeOf(own, true):find('.' .. '..', 1, true),
        'this file\'s code has a `...` in it: the chunk\'s own arguments are a command-line switch '
        .. '(a vararg helper needs this check narrowed, not dropped)')
end)

os.exit(t.summary())
