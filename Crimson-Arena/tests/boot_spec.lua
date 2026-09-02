--[[
    tests/boot_spec.lua

    DOES THE RESOURCE START? Every other spec in this suite loads the one or
    two files it needs and asserts on their behaviour. None of them answers
    the first question a server asks, which is whether the whole thing comes
    up at all.

    That question has its own failure mode, and it is invisible from inside
    any single file: file A runs a line at load time that calls something
    file B defines, and B is listed after A in the manifest. Both files read
    correctly. Every spec covering either one passes. The resource dies on
    start with one line in the console naming a nil value.

    So this spec loads EVERY file, in the order fxmanifest.lua declares, into
    one environment per realm -- exactly the sequence FXServer performs.

    WHAT COUNTS AS A NATIVE. A stub for every unknown global would make this
    test pass by construction: the load-order bug above would be stubbed away
    along with the natives. Instead the stubs come from .luacheckrc, which
    lists -- exactly, per realm, by hand -- every global these files are
    allowed to touch. luacheck is clean, so that list is complete. Anything
    reached during boot that is NOT on it is therefore one of two things:

      * a global this resource defines, read before the file defining it has
        run -- the load-order bug, and
      * a native nobody declared, which luacheck would have caught, so it
        cannot happen while the suite is green.

    Either way the environment raises and names it, rather than quietly
    handing back a function.

    The two lists checking each other is the point: .luacheckrc proves the
    boot has no undeclared globals, and the boot proves .luacheckrc is not
    missing an entry.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local manifest = Sandbox.readDeclarations('../fxmanifest.lua')
local luacheck = Sandbox.readDeclarations('../.luacheckrc')

-- ======================================================================
-- THE ALLOWED NAMES, TAKEN FROM .luacheckrc
-- ======================================================================

--- The names .luacheckrc says this realm's files only ever READ.
---
--- THE TWO LISTS ARE NOT THE SAME THING, and treating them as one made an
--- earlier version of this spec unable to see a module dropped from the
--- manifest. luacheck's `read_globals` is what a file reads and never
--- writes -- natives, and other resources' globals. Its `globals` is what
--- this resource DEFINES. Only the first may be stubbed:
---
---   * a native has no meaning outside the game, so a stub is the truthful
---     stand-in and its absence proves nothing;
---   * one of our own globals is defined by one of the files being loaded,
---     so reading it and finding nothing is exactly the defect this spec
---     exists to catch. Stubbing it hides a module that never loaded behind
---     a function that does nothing.
---
--- Shared files load into BOTH realms, so their entries are unioned into
--- each. A directory entry ('server/') covers every file beneath it, which
--- is how luacheck reads them too.
--- @param realm string -- 'client' or 'server'
--- @return table<string, boolean> natives
local function stubbableNatives(realm)
    local sections = {
        'config.lua',
        'shared/arena.lua',
        'shared/compat/dispatch.lua',
        realm .. '/',
    }

    local natives = {}
    for _, section in ipairs(sections) do
        local entry = luacheck.files[section]
        if entry then
            for _, name in ipairs(entry.read_globals or {}) do natives[name] = true end
        end
    end

    -- A name this resource defines is never stubbable, even where another
    -- section lists it as read-only. config.lua writes Config and every
    -- other file reads it, so it appears in both lists; the write is what
    -- decides.
    for _, section in ipairs(sections) do
        local entry = luacheck.files[section]
        if entry then
            for _, name in ipairs(entry.globals or {}) do natives[name] = nil end
        end
    end

    return natives
end

-- ======================================================================
-- THE ENVIRONMENT ONE REALM BOOTS INTO
-- ======================================================================

--- Loads every file of one realm, in manifest order, and reports what
--- happened.
---
--- Threads are RECORDED, NOT RUN. A `CreateThread` at load time is a thread
--- FXServer schedules rather than executes, and several of them are
--- `while true` render or tick loops -- running one inline would hang the
--- suite instead of testing it. What matters here is that the file reached
--- its CreateThread call without dying, which recording proves just as well.
--- @param realm string
--- @param overrides table?
--- @return table result
local function boot(realm, overrides)
    local natives = stubbableNatives(realm)
    local record = { threads = 0, netEvents = {}, handlers = {}, commands = {},
                     exports = {}, callbacks = {}, loaded = {}, prints = {} }

    local function noop() end

    -- `exports` is used two ways in this codebase and has to answer both:
    -- called, to REGISTER one of this resource's exports; and indexed, to
    -- REACH another resource's. Nothing is invoked at load time either way.
    local exportsTable = setmetatable({}, {
        __call = function(_, name) record.exports[#record.exports + 1] = name end,
        __index = function()
            return setmetatable({}, { __index = function() return noop end })
        end,
    })

    local env
    env = Sandbox.newEnv({
        -- Realm identity. shared/compat/dispatch.lua branches on this to
        -- decide which half of itself to run, so it must be honest.
        IsDuplicityVersion = function() return realm == 'server' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        CreateThread = function() record.threads = record.threads + 1 end,
        SetTimeout = function() record.threads = record.threads + 1 end,
        Wait = noop,

        RegisterNetEvent = function(name) record.netEvents[name] = true end,
        AddEventHandler = function(name) record.handlers[name] = true end,
        RegisterCommand = function(name) record.commands[name] = true end,
        RegisterNUICallback = function(name) record.callbacks[name] = true end,
        TriggerEvent = noop,
        exports = exportsTable,

        -- Nothing is installed in this environment, so every optional
        -- resource answers honestly. The boot has to survive that.
        GetResourceState = function() return 'missing' end,

        lib = Sandbox.newOxLib(),
        print = function(text) record.prints[#record.prints + 1] = tostring(text) end,
    })

    for key, value in pairs(overrides or {}) do env[key] = value end

    -- THE GUARD. Applied after the stubs above so they are found normally,
    -- and only reached by a name nothing has defined.
    setmetatable(env, {
        __index = function(_, key)
            if natives[key] then
                -- A native, declared in .luacheckrc and meaningless outside
                -- the game. A function that returns nothing is the truthful
                -- stand-in for one called for its side effect.
                return noop
            end
            error(('boot(%s): read undefined global %q -- either a file ran before the one that defines it, or it is a native missing from .luacheckrc')
                :format(realm, tostring(key)), 2)
        end,
    })

    for _, path in ipairs(Sandbox.realmScripts(manifest, realm)) do
        record.loaded[#record.loaded + 1] = path
        Sandbox.loadInto('../' .. path, env)
    end

    record.env = env
    return record
end

-- ======================================================================
-- THE SERVER COMES UP
-- ======================================================================

print('==> the server realm')

--- Boots a realm, turning a failure into a NAMED test failure rather than a
--- dead process. Without this a load-time error escapes at file scope and
--- the whole spec reports as a crash -- red either way, but a crash says
--- "this file is broken" where the point is to say which global, in which
--- file, was reached before it existed.
--- @param realm string
--- @return table result
local function bootOrExplain(realm)
    local ok, result = pcall(boot, realm)
    if ok then return result end

    -- Every later test in this realm's section needs the boot to have
    -- happened, so they are given a table that fails them by name instead of
    -- an error about indexing nil.
    local message = tostring(result)
    return setmetatable({ failure = message, loaded = {}, netEvents = {},
                          handlers = {}, commands = {}, callbacks = {}, exports = {} }, {
        __index = function() error(message, 2) end,
    })
end

local server = bootOrExplain('server')

t.test('the server realm boots at all', function()
    t.isNil(rawget(server, 'failure'), rawget(server, 'failure'))
end)

t.test('every server file loads, in manifest order, without one reaching for something later', function()
    t.isTrue(#server.loaded > 8,
        'the manifest walk found almost no server files, so this test proved nothing')

    -- Proof the walk covered both halves of the load rather than one: a
    -- shared file first, a server file last.
    t.equals(server.loaded[1], 'config.lua',
        'config.lua is no longer loaded first; every other file reads Config at load time')
    t.contains(table.concat(server.loaded, ' '), 'server/main.lua')
end)

t.test('the shared rules and the operator config both survive into the server realm', function()
    t.isNotNil(server.env.Config, 'Config is not defined after boot')
    t.isNotNil(server.env.Arena, 'Arena is not defined after boot')
    t.equals(type(server.env.Arena.ResolveLoadout), 'function')
end)

t.test('every module the server realm is built from is defined by the time boot ends', function()
    -- These are the globals server/main.lua wires together. One of them nil
    -- at this point is the load-order bug in its finished form.
    for _, name in ipairs({ 'ArenaLog', 'ArenaAmmo', 'ArenaBetting', 'ArenaLobby',
                            'ArenaMatch', 'ArenaStats', 'ArenaDispatch' }) do
        t.isNotNil(server.env[name], name .. ' is nil after the server realm booted')
    end
end)

t.test('booting registers the events the client actually sends', function()
    -- A registration that silently never happened is the other half of the
    -- same failure: the resource starts, and one feature is simply inert.
    local registered = 0
    for _ in pairs(server.netEvents) do registered = registered + 1 end
    t.isTrue(registered >= 5,
        ('only %d net events were registered on the server; the wiring did not run'):format(registered))
end)

t.test('a server with none of the optional resources installed still comes up', function()
    -- GetResourceState answered 'missing' for everything throughout the
    -- boot above -- no ox_target, no ox_inventory, no oxmysql. Reaching
    -- this line at all is the assertion.
    t.isTrue(#server.loaded > 8)
end)

-- ======================================================================
-- THE CLIENT COMES UP
-- ======================================================================

print('')
print('==> the client realm')

local client = bootOrExplain('client')

t.test('the client realm boots at all', function()
    t.isNil(rawget(client, 'failure'), rawget(client, 'failure'))
end)

t.test('every client file loads, in manifest order, without one reaching for something later', function()
    t.isTrue(#client.loaded > 5,
        'the manifest walk found almost no client files, so this test proved nothing')
    t.equals(client.loaded[1], 'config.lua')
end)

t.test('the shared rules and the operator config both survive into the client realm', function()
    t.isNotNil(client.env.Config)
    t.isNotNil(client.env.Arena)
    t.equals(type(client.env.Arena.ResolveLoadout), 'function')
end)

t.test('the panel wiring is in place after boot', function()
    t.isNotNil(client.env.ArenaUI, 'ArenaUI is nil after the client realm booted')
    t.isNotNil(client.env.ArenaState, 'ArenaState is nil after the client realm booted')

    local callbacks = 0
    for _ in pairs(client.callbacks) do callbacks = callbacks + 1 end
    t.isTrue(callbacks >= 3,
        ('only %d NUI callbacks were registered; the panel would answer nothing'):format(callbacks))
end)

-- ======================================================================
-- THE TWO REALMS AGREE
-- ======================================================================

print('')
print('==> the two realms')

t.test('both realms load the same shared files, so the rules cannot drift apart', function()
    local shared = {}
    for _, entry in ipairs(manifest.shared_scripts or {}) do
        if not entry:find('^@') then shared[#shared + 1] = entry end
    end
    t.isTrue(#shared >= 3, 'the shared list shrank; a rules file may have moved into one realm')

    for _, path in ipairs(shared) do
        t.contains(table.concat(server.loaded, ' '), path, 'server realm')
        t.contains(table.concat(client.loaded, ' '), path, 'client realm')
    end
end)

t.test('the weapon catalogue is loaded straight after the config it writes into', function()
    -- LOAD ORDER, NOT TIDINESS. config.weapons.lua assigns
    -- `Config.Loadouts.weapons`, and Config.Loadouts is built by config.lua.
    -- The other way round is a nil index at start-up, and the resource does
    -- not come up at all -- which is worth failing here rather than there.
    local order = {}
    for index, entry in ipairs(manifest.shared_scripts or {}) do order[entry] = index end

    t.isNotNil(order['config.lua'], 'config.lua is not in shared_scripts')
    t.isNotNil(order['config.weapons.lua'], 'the weapon catalogue is not loaded at all')
    t.isTrue(order['config.weapons.lua'] > order['config.lua'],
        'config.weapons.lua is loaded before the table it writes into exists')
end)

t.test('and the catalogue it loads really has weapons in it', function()
    -- The other half: the file could be listed, load cleanly, and assign an
    -- empty table -- which is a server where nobody can pick anything.
    local shipped = Sandbox.shippedConfig()
    t.isTrue(#((shipped.Loadouts or {}).weapons or {}) > 0,
        'the shipped weapon catalogue is empty -- every player would fight unarmed')
end)

t.test('no file is loaded into a realm twice', function()
    for _, realm in ipairs({ server, client }) do
        local seen = {}
        for _, path in ipairs(realm.loaded) do
            t.isNil(seen[path], path .. ' is listed twice in the manifest; it would run twice')
            seen[path] = true
        end
    end
end)

t.test('the dispatch compatibility layer knows which realm it is in', function()
    -- One file, two behaviours, chosen by IsDuplicityVersion(). Loaded into
    -- both realms above; if it read the wrong half it would have called a
    -- native the other realm's allow-list does not carry, and the guard
    -- would have raised during boot rather than here.
    t.isNotNil(server.env.ArenaCompat, 'ArenaCompat is nil on the server')
    t.isNotNil(client.env.ArenaCompat, 'ArenaCompat is nil on the client')
end)

os.exit(t.summary())
