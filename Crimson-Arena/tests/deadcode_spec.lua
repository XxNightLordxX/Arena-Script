--[[
    crimson_arena/tests/deadcode_spec.lua

    NOTHING IS DEFINED THAT NOTHING USES.

    A function with no caller is not "spare capacity". In a resource that
    documents itself as heavily as this one it is worse than that: it carries
    a doc comment asserting behaviour that nothing exercises and nothing
    checks, so it reads as verified and is not. The next person to need that
    behaviour finds it, believes the comment, and calls it.

    Six of them were found by hand: a radar getter, two HUD helpers, an
    issued-ammunition accessor, a live-match lister and a resource-state
    check. All were one-line wrappers, all were referenced by nothing at all,
    and all had been that way long enough that no one remembered writing them.
    Finding those by reading is not a plan. This is.

    WHAT COUNTS AS A USE, in descending order of how much it proves:

      Called by another source file          -- production behaviour
      Called by a spec                       -- checked behaviour
      Registered with exports()              -- another resource's to call
      Named in README.md                     -- documented for an operator

    Any one of those is enough. None of them is dead code.

    luacheck already catches an unused `local function`; this is about the
    public ones -- `function Arena.Thing()` -- which are globals on a shared
    table and which no linter can see the far end of.
]]

local t = dofile('testkit.lua')

print('deadcode_spec')

--- Every non-test Lua file in the resource.
local function sourceFiles()
    local out = {}
    -- Listed rather than globbed: Lua has no directory listing without a
    -- library, and the manifest is the list that matters anyway.
    local manifest = assert(io.open('../fxmanifest.lua', 'r'))
    local text = manifest:read('a')
    manifest:close()

    for path in text:gmatch("'([%w_/]+%.lua)'") do
        out[#out + 1] = '../' .. path
    end
    return out
end

--- @param path string
--- @return string|nil
local function read(path)
    local handle = io.open(path, 'r')
    if not handle then return nil end
    local text = handle:read('a')
    handle:close()
    return text
end

--- Source with its comments removed, so a function named only in a comment
--- does not count as used. A doc comment mentioning it is the very thing
--- that makes dead code look alive.
--- @param text string
--- @return string
local function withoutComments(text)
    return (text:gsub('%-%-%[%[.-%]%]', ''):gsub('%-%-[^\n]*', ''))
end

t.test('every public function is called, tested, exported or documented', function()
    local files = sourceFiles()
    t.isTrue(#files > 10, ('the manifest listed only %d Lua files'):format(#files))

    -- WHERE A USE MAY COME FROM.
    local haystack = {}

    for _, path in ipairs(files) do
        local text = read(path)
        t.isNotNil(text, ('%s is in the manifest and not on disk'):format(path))
        haystack[#haystack + 1] = withoutComments(text)
    end

    -- The specs, which are a real use: behaviour a test drives is checked
    -- behaviour, even where production has not called it yet.
    for _, spec in ipairs({
        'ammo_spec', 'ammochain_spec', 'arena_spec', 'betting_spec', 'bettingdefects_spec',
        'blipscope_spec', 'boot_spec', 'clientrevive_spec', 'concurrent_spec',
        'countdownexit_spec', 'deadcode_spec', 'dispatch_spec', 'doorguarantee_spec',
        'dropin_spec', 'gungame_spec', 'holdstart_spec', 'isolation_spec', 'lobbyexit_spec',
        'lobbyrules_spec', 'locale_spec', 'matchflow_spec', 'nuicontract_spec',
        'panel_spec', 'panelpresence_spec', 'payaccount_spec', 'payoutchain_spec',
        'radarrule_spec', 'respawn_spec', 'returnhome_spec', 'rulesdefects_spec',
        'server_spec', 'skyarena_spec', 'skyworld_spec', 'snapshotcontract_spec',
        'spawnplan_spec', 'unrestorable_spec', 'configmap_spec',
    }) do
        local text = read(spec .. '.lua')
        if text then haystack[#haystack + 1] = text end
    end

    -- And the operator-facing documentation: a function named in README.md
    -- is a promise to somebody outside this repo.
    for _, doc in ipairs({ '../README.md', '../DEPLOYMENT.md' }) do
        local text = read(doc)
        if text then haystack[#haystack + 1] = text end
    end

    local all = table.concat(haystack, '\n')

    local dead = {}
    for _, path in ipairs(files) do
        local text = read(path)
        for name in withoutComments(text):gmatch('function%s+([%w_]+%.[%w_]+)%s*%(') do
            local short = name:match('%.([%w_]+)$')

            -- Every mention of the short name anywhere, minus the one that
            -- is the definition itself. The short name rather than the
            -- dotted one because a caller may hold the table in a local.
            local uses = 0
            for _ in all:gmatch('%f[%w_]' .. short .. '%f[^%w_]') do uses = uses + 1 end

            if uses <= 1 then
                dead[#dead + 1] = ('%s (%s)'):format(name, path:gsub('^%.%./', ''))
            end
        end
    end

    t.equals(#dead, 0, ('nothing calls, tests, exports or documents: %s')
        :format(table.concat(dead, ', ')))
end)

t.test('and the manifest lists every Lua file that exists', function()
    -- THE OTHER HALF, and the more dangerous one. A file missing from the
    -- manifest is not loaded by FXServer at all: its functions are nil at
    -- the call site, at run time, on a server. Nothing above would notice --
    -- an unlisted file is simply not part of the resource.
    local listed = {}
    for _, path in ipairs(sourceFiles()) do listed[path:gsub('^%.%./', '')] = true end

    -- Read off the disk rather than from a second list here, so this cannot
    -- agree with the manifest by both being wrong in the same way.
    local found = io.popen('ls ../client/*.lua ../server/*.lua ../shared/*.lua ../shared/compat/*.lua ../config.lua 2>/dev/null')
    t.isNotNil(found, 'could not read the resource directory')

    local missing = {}
    for line in found:lines() do
        local path = line:gsub('^%.%./', '')
        if not listed[path] then missing[#missing + 1] = path end
    end
    found:close()

    t.equals(#missing, 0, ('on disk and not in fxmanifest.lua, so never loaded: %s')
        :format(table.concat(missing, ', ')))
end)

os.exit(t.summary())
