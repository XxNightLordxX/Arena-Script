--[[
    tests/dropin_spec.lua

    THE DRAG-AND-DROP CONTRACT. One promise, stated as tests: an operator
    unzips the folder, drops it in `resources`, adds one `ensure` line, and
    plays. No SQL to import, no folder to rename, no third-party resource to
    install first beyond the two every Qbox server already runs.

    That promise is not a property of any one file, which is exactly why it
    kept quietly breaking. It is a property of the AGREEMENT between
    fxmanifest.lua and the code -- a manifest listing a file that is not
    there, a dependency the config can switch off but the manifest cannot, a
    panel addressing calls to a folder name the operator was free to change.
    Each of those looks correct in the file you are reading and is wrong from
    outside it.

    So this spec reads the manifest the way FXServer does -- by EXECUTING it,
    with every manifest directive captured instead of applied -- and then
    checks the code against what it actually said.

    It calls no natives and loads no game state: it is text and the file
    system, which is all these particular defects ever lived in.
]]

local t = dofile('testkit.lua')

-- ======================================================================
-- READING THE MANIFEST THE WAY THE SERVER DOES
-- ======================================================================

--- Executes fxmanifest.lua and returns everything it declared.
---
--- A manifest is not data, it is a Lua script whose every line is a call to
--- a global the server defines: `fx_version 'cerulean'`, `dependencies {...}`.
--- Parsing it with patterns would test a copy of the file rather than the
--- file, so the environment below defines those globals as recorders and the
--- real manifest runs against them. The recorder is generated on demand from
--- the name that was called, so a directive added tomorrow is captured too
--- rather than crashing the read.
--- @return table declared -- directive name -> the last value it was given
local function readManifest()
    local declared = {}

    local env = setmetatable({}, {
        -- Any global the manifest calls becomes a recorder under its own
        -- name. Unknown directives are therefore captured rather than
        -- crashing the read, which keeps this spec from being the thing that
        -- blocks adding one.
        __index = function(_, key)
            return function(value)
                declared[key] = value
                return value
            end
        end,
    })

    local chunk = assert(loadfile('../fxmanifest.lua', 't', env))
    chunk()
    return declared
end

local manifest = readManifest()

--- @param path string -- repo-relative
--- @return boolean
local function fileExists(path)
    local handle = io.open('../' .. path, 'r')
    if not handle then return false end
    handle:close()
    return true
end

--- @param path string -- repo-relative
--- @return string
local function readFile(path)
    local handle = assert(io.open('../' .. path, 'r'), path .. ' is missing')
    local body = handle:read('a')
    handle:close()
    return body
end

-- ======================================================================
-- WHAT THE SERVER DEMANDS BEFORE IT WILL START US
-- ======================================================================

print('==> the dependencies block')

t.test('the manifest demands exactly the two resources every Qbox server already runs', function()
    local deps = manifest.dependencies
    t.isNotNil(deps, 'fxmanifest.lua declares no dependencies block at all')

    local named = {}
    for _, dep in ipairs(deps) do named[dep] = true end

    t.isTrue(named.qbx_core == true, 'qbx_core must stay required -- there is no arena without it')
    t.isTrue(named.ox_lib == true, 'ox_lib must stay required -- notifications, callbacks and locales')

    -- THE POINT OF THIS SPEC. FXServer reads this list before config.lua
    -- exists, so anything added here is required on every install no matter
    -- what the operator switched off. Adding one is a decision, not a
    -- detail, and it should have to be made here as well as there.
    t.equals(#deps, 2,
        'a third hard dependency was added; it is now required even on installs that switched its feature off')
end)

t.test('the three optional resources are asked for at run time, not by the manifest', function()
    local deps = manifest.dependencies
    for _, dep in ipairs(deps) do
        t.isFalse(dep == 'oxmysql',
            'oxmysql is back in the manifest -- the database ships OFF, so this would demand it for nothing')
        t.isFalse(dep == 'ox_inventory',
            'ox_inventory is back in the manifest -- ammo items ship OFF')
        t.isFalse(dep == 'ox_target',
            'ox_target is back in the manifest -- the marker already covers its absence')
    end
end)

t.test('no manifest include drags in a resource the dependencies block does not name', function()
    -- An `@resource/file.lua` entry is as hard a requirement as a dependency
    -- -- the server resolves it at load and fails the resource when it
    -- cannot. This is the loophole the oxmysql fix had to close, and the one
    -- a future edit is most likely to reopen without noticing.
    local allowed = { qbx_core = true, ox_lib = true }

    local lists = { 'shared_scripts', 'client_scripts', 'server_scripts' }
    for _, list in ipairs(lists) do
        for _, entry in ipairs(manifest[list] or {}) do
            local resource = entry:match('^@([^/]+)/')
            if resource then
                t.isTrue(allowed[resource] == true, ('%s includes @%s/, which makes %s a hard requirement, but the dependencies block does not name it')
                    :format(list, resource, resource))
            end
        end
    end
end)

t.test('oxmysql specifically is not included, so a server with no database still starts', function()
    for _, entry in ipairs(manifest.server_scripts or {}) do
        t.notContains(entry, 'oxmysql',
            'a manifest include cannot be switched off by config.lua -- stats must go through the export')
    end
end)

-- ======================================================================
-- THE MANIFEST AND THE FOLDER AGREE
-- ======================================================================

print('')
print('==> the manifest describes files that are actually there')

t.test('every script the manifest loads exists in the folder', function()
    local checked = 0
    for _, list in ipairs({ 'shared_scripts', 'client_scripts', 'server_scripts' }) do
        for _, entry in ipairs(manifest[list] or {}) do
            -- `@other_resource/file` is somebody else's file; only our own
            -- paths are ours to guarantee.
            if not entry:find('^@') then
                checked = checked + 1
                t.isTrue(fileExists(entry),
                    ('%s lists %s, which is not in the folder -- the resource fails to start'):format(list, entry))
            end
        end
    end
    t.isTrue(checked > 10, 'the manifest walk found almost no scripts, so this test proved nothing')
end)

t.test('every file the manifest sends to clients exists in the folder', function()
    -- A missing entry here does NOT fail the resource. It is served as
    -- nothing, with no error in either console -- which is why the panel's
    -- logo and locale are worth a test rather than a look.
    local checked = 0
    for _, entry in ipairs(manifest.files or {}) do
        checked = checked + 1
        t.isTrue(fileExists(entry),
            ('files{} lists %s, which is not in the folder -- it is served as nothing, silently'):format(entry))
    end
    t.isTrue(checked > 3, 'the files{} walk found almost nothing, so this test proved nothing')
end)

t.test('the panel page the manifest opens is also in the list of files it sends', function()
    local page = manifest.ui_page
    t.isNotNil(page, 'no ui_page declared -- the panel would never open')
    t.isTrue(fileExists(page), ('ui_page %s is not in the folder'):format(tostring(page)))

    local listed = false
    for _, entry in ipairs(manifest.files or {}) do
        if entry == page then listed = true end
    end
    t.isTrue(listed, ('ui_page %s is not in files{}, so clients are never sent it'):format(tostring(page)))
end)

t.test('the logo is listed, so replacing the file is all an operator has to do', function()
    local listed = false
    for _, entry in ipairs(manifest.files or {}) do
        if entry == 'html/images/logo.png' then listed = true end
    end
    t.isTrue(listed, 'the logo is not in files{} -- an operator who swaps it gets a blank header and no error')
    t.isTrue(fileExists('html/images/logo.png'), 'the shipped logo file is missing')
end)

-- ======================================================================
-- THE FOLDER NAME IS THE OPERATOR'S TO CHOOSE
-- ======================================================================

print('')
print('==> the panel survives being renamed')

t.test('the panel asks the game what it was installed as instead of assuming', function()
    local app = readFile('html/app.js')
    t.contains(app, 'GetParentResourceName',
        'app.js does not ask for the resource name; a renamed folder gives a panel that answers no button')
end)

t.test('the NUI host is the answer to that question, not a literal', function()
    local app = readFile('html/app.js')

    -- The fetch below is the only place the resource name reaches the wire.
    -- Asserting on the assignment rather than the fetch is deliberate: the
    -- fetch has looked correct through every version of this defect.
    local assignment = app:match('var RESOURCE%s*=%s*(.-);')
    t.isNotNil(assignment, 'app.js no longer assigns RESOURCE in a form this test can read')
    t.contains(assignment, 'GetParentResourceName',
        'RESOURCE is assigned a fixed name again -- rename the folder and every button stops working')

    t.contains(app, "fetch('https://' + RESOURCE + '/'",
        'the callback fetch no longer builds its host from RESOURCE')
end)

t.test('nothing else in the panel addresses a fixed folder name', function()
    for _, page in ipairs({ 'html/index.html', 'html/style.css' }) do
        local body = readFile(page)
        t.notContains(body, 'https://crimson_arena',
            ('%s addresses a fixed folder name'):format(page))
        t.notContains(body, 'nui://crimson_arena',
            ('%s addresses a fixed folder name'):format(page))
    end
end)

-- ======================================================================
-- THE OPTIONAL RESOURCES ARE REALLY OPTIONAL
-- ======================================================================

print('')
print('==> a missing optional resource degrades one feature, not the boot')

t.test('the lobby asks whether ox_target is running before it reaches for it', function()
    local main = readFile('client/main.lua')

    -- `exports.ox_target` on a server without it RAISES rather than
    -- returning nil, and the raise happens inside the startup thread -- so
    -- an unguarded reach here costs the marker, the blip and the fallback
    -- command as well as the NPC, with nothing in the console naming why.
    t.contains(main, "GetResourceState('ox_target')",
        'client/main.lua reaches for ox_target without checking it is running')

    -- THE RULE IS ONE DOOR, NOT NO DOOR. `exports.ox_target` has to appear
    -- somewhere; what must not happen is a second reach that skips the
    -- check. So: exactly one mention outside comments, and it has to be the
    -- one inside the accessor that does the checking.
    local reaches = 0
    for line in main:gmatch('[^\n]+') do
        if line:find('exports%.ox_target') and not line:find('^%s*%-%-') then
            reaches = reaches + 1
        end
    end
    t.equals(reaches, 1,
        'client/main.lua reaches for ox_target somewhere other than the single guarded accessor')

    local accessor = main:match('local function targeting%(%)(.-)\nend\n')
    t.isNotNil(accessor, 'the guarded ox_target accessor is gone from client/main.lua')
    t.contains(accessor, "GetResourceState('ox_target')",
        'the accessor no longer checks whether ox_target is running')
    t.contains(accessor, 'exports.ox_target',
        'the accessor no longer returns the export, so the one reach is somewhere unguarded')
end)

t.test('the ammunition door asks whether ox_inventory is running before it reaches for it', function()
    local ammo = readFile('server/ammo.lua')
    t.contains(ammo, "GetResourceState('ox_inventory')",
        'server/ammo.lua reaches for ox_inventory without checking it is running')
end)

t.test('stats go through the oxmysql export, so the database is a run-time question', function()
    local stats = readFile('server/stats.lua')

    t.contains(stats, "GetResourceState('oxmysql')",
        'server/stats.lua does not check oxmysql is running before querying it')

    -- `MySQL.query` is the name the manifest include provides. Its presence
    -- in a call means the include came back, and the include is the thing
    -- that made a database mandatory.
    for line in stats:gmatch('[^\n]+') do
        if line:find('MySQL%.query%s*%(') and not line:find('^%s*%-%-') then
            error('server/stats.lua calls MySQL.query again, which needs the manifest include: ' .. line)
        end
    end
end)

t.test('every database call sits behind the switch that ships off', function()
    -- Not a style point. With Config.Database.enabled false the resource
    -- must not merely fail its queries quietly -- it must not make any, so
    -- that a server with no database resource sees nothing about one.
    local stats = readFile('server/stats.lua')
    local guards = select(2, stats:gsub('Config%.Database%.enabled', ''))
    t.isTrue(guards >= 4,
        'the number of Config.Database.enabled guards in stats.lua dropped; a query may have escaped one')
end)

-- ======================================================================
-- NOTHING HAS TO BE IMPORTED, EDITED OR CREATED FIRST
-- ======================================================================

print('')
print('==> the shipped settings are the playable settings')

t.test('the database ships off, so there is no SQL to import', function()
    local config = readFile('config.lua')
    local block = config:match('Config%.Database%s*=%s*{(.-)}')
    t.isNotNil(block, 'Config.Database is no longer a readable table literal')
    t.contains(block, 'enabled = false',
        'the database ships ON -- a drop-in install would now need a table imported or created')
end)

t.test('the locale the resource loads by default is in the folder and is sent to clients', function()
    -- ox_lib resolves locales/<code>.json at load. A locale that is present
    -- but not in files{} is never sent, and every player-facing string in
    -- the panel becomes its own key.
    t.isTrue(fileExists('locales/en.json'), 'locales/en.json is missing')

    local listed = false
    for _, entry in ipairs(manifest.files or {}) do
        if entry == 'locales/en.json' then listed = true end
    end
    t.isTrue(listed, 'locales/en.json is not in files{}, so clients never receive it')
end)

t.test('the manifest still declares the Lua version the whole resource is written against', function()
    t.equals(manifest.lua54, 'yes',
        "lua54 is not 'yes' -- goto, integer division and the // operator in this codebase stop parsing")
end)

os.exit(t.summary())
