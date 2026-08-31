--[[
    crimson_arena/tests/fixtures/sandbox.lua

    Loads a REAL, unmodified production .lua file into an isolated
    environment table so its logic can be exercised under plain lua5.4,
    outside FiveM, without editing the file and without touching the real
    global table.

    HOW: Lua 5.2+ routes every global read/write in a chunk through the
    `_ENV` upvalue, and `load(chunk, name, mode, env)` lets us supply that
    upvalue. A production file's own `Arena = {}` therefore writes into OUR
    table, reachable afterwards as `env.Arena`.

    Specs run with `tests/` as the working directory, so paths passed to
    loadInto look like '../shared/arena.lua'.
]]

local Sandbox = {}

--- vector3/vector4 are CitizenFX Lua RUNTIME TYPES, not natives -- config.lua
--- calls them at file-load time, so plain lua5.4 needs a stand-in or every
--- spec that loads the real config dies on "attempt to call a nil value".
---
--- Deliberately minimal: a table carrying x/y/z(/w) and nothing else. They
--- model the fields production code READS, not CitizenFX's vector maths. If
--- production code ever does arithmetic on one (v1 - v2, #v), this stub will
--- not catch the bug -- the fix then is real metamethods here, not a
--- weakened test.
local function makeVector(fields)
    return function(...)
        local vector, args = {}, { ... }
        for index, name in ipairs(fields) do vector[name] = args[index] end
        return vector
    end
end

Sandbox.vector2 = makeVector({ 'x', 'y' })
Sandbox.vector3 = makeVector({ 'x', 'y', 'z' })
Sandbox.vector4 = makeVector({ 'x', 'y', 'z', 'w' })

-- ======================================================================
-- LOCALES
-- ======================================================================

--- Minimal JSON reader, sufficient for locales/en.json: nested objects
--- whose leaves are all strings. Deliberately NOT a general parser -- it
--- rejects anything outside that shape loudly rather than guessing, so a
--- locale file that grows arrays or numbers fails the suite instead of
--- half-loading.
local function parseJsonObject(text, pos)
    local out = {}
    pos = text:find('%S', pos)
    assert(text:sub(pos, pos) == '{', 'expected { at ' .. pos)
    pos = pos + 1
    while true do
        pos = text:find('%S', pos)
        assert(pos, 'unterminated object')
        local char = text:sub(pos, pos)
        if char == '}' then return out, pos + 1 end
        if char == ',' then
            pos = pos + 1
        else
            assert(char == '"', 'expected key string at ' .. pos)
            local key
            key, pos = text:match('^"([^"\\]*)"()', pos)
            assert(key, 'unsupported escape in object key')
            pos = text:find('%S', pos)
            assert(text:sub(pos, pos) == ':', 'expected : after key ' .. key)
            pos = text:find('%S', pos + 1)
            if text:sub(pos, pos) == '{' then
                out[key], pos = parseJsonObject(text, pos)
            else
                assert(text:sub(pos, pos) == '"', 'locale leaves must be strings; got non-string for ' .. key)
                local buf, index = {}, pos + 1
                while true do
                    local char2 = text:sub(index, index)
                    assert(char2 ~= '', 'unterminated string for ' .. key)
                    if char2 == '\\' then
                        local nextChar = text:sub(index + 1, index + 1)
                        local simple = ({ n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                                          ['"'] = '"', ['\\'] = '\\', ['/'] = '/' })[nextChar]
                        assert(simple, 'unsupported escape \\' .. nextChar .. ' in ' .. key)
                        buf[#buf + 1] = simple
                        index = index + 2
                    elseif char2 == '"' then
                        index = index + 1
                        break
                    else
                        buf[#buf + 1] = char2
                        index = index + 1
                    end
                end
                out[key] = table.concat(buf)
                pos = index
            end
        end
    end
end

local localeDict

--- Loads locales/en.json once and returns an ox_lib-shaped `locale()`.
--- Unlike ox_lib -- which hands back the key itself when a key is missing,
--- so the mistake shows up only as odd text in-game -- this RAISES. Every
--- spec that runs a code path through locale() therefore doubles as proof
--- that the key really exists.
function Sandbox.locale(key, ...)
    if not localeDict then
        local handle = assert(io.open('../locales/en.json', 'r'),
            'sandbox: could not open ../locales/en.json -- specs run with crimson_arena/tests as the working directory')
        local text = handle:read('a')
        handle:close()
        localeDict = (parseJsonObject(text, 1))
    end
    local group, leaf = key:match('^([^.]+)%.(.+)$')
    local value = group and localeDict[group] and localeDict[group][leaf] or localeDict[key]
    assert(type(value) == 'string', 'locale key missing from locales/en.json: ' .. tostring(key))
    if select('#', ...) > 0 then return value:format(...) end
    return value
end

--- Every key in locales/en.json, flattened to 'group.leaf' form. Used by the
--- locale-coverage spec to prove nothing in the file is orphaned and nothing
--- the code asks for is missing.
--- @return table<string, boolean>
function Sandbox.localeKeys()
    Sandbox.locale('meta.locale_probe')   -- forces the one-time load below
    local flat = {}
    for group, value in pairs(localeDict) do
        if type(value) == 'table' then
            for leaf in pairs(value) do flat[group .. '.' .. leaf] = true end
        else
            flat[group] = true
        end
    end
    return flat
end

-- ======================================================================
-- ENVIRONMENT
-- ======================================================================

--- A fresh sandbox: a shallow copy of the real _G (so the standard library
--- works normally inside a loaded chunk), with `overrides` layered on top
--- (FiveM native stubs, Config, etc.). `env._G` points at `env` itself so a
--- production file's explicit `_G.Something(...)` resolves inside the
--- sandbox rather than reaching the real process globals.
--- @param overrides table<string, any>?
--- @return table env
function Sandbox.newEnv(overrides)
    local env = {}
    for key, value in pairs(_G) do env[key] = value end
    env._G = env
    env.locale = Sandbox.locale
    env.vector2 = Sandbox.vector2
    env.vector3 = Sandbox.vector3
    env.vector4 = Sandbox.vector4
    env.vec2 = Sandbox.vector2
    env.vec3 = Sandbox.vector3
    env.vec4 = Sandbox.vector4
    for key, value in pairs(overrides or {}) do env[key] = value end
    return env
end

--- Loads and immediately executes `path` inside `env`. Any top-level
--- `function Foo() end` / `Foo = ...` in the source becomes `env.Foo`; any
--- RegisterNetEvent/RegisterCommand/etc. the file calls at load time hits
--- whatever stub `env` provides.
--- @param path string -- a real production file, never modified
--- @param env table
function Sandbox.loadInto(path, env)
    local chunk, err = loadfile(path, 't', env)
    if not chunk then
        error(('sandbox: failed to load %s: %s'):format(path, tostring(err)))
    end
    chunk()
end

--- Loads the REAL config.lua plus the REAL shared/arena.lua into one env --
--- the pair almost every spec needs, since Arena.* reads Config.* on every
--- call. Returns the env so a spec can then mutate `env.Config` to describe
--- the server it is testing.
--- @param overrides table<string, any>?
--- @return table env
function Sandbox.newArenaEnv(overrides)
    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    return env
end

-- ======================================================================
-- READING THE RESOURCE'S OWN MANIFESTS
-- ======================================================================

--- Executes a declaration file -- fxmanifest.lua or .luacheckrc -- and
--- returns what it declared.
---
--- Both are Lua scripts rather than data: a manifest line is a call to a
--- global the server defines (`fx_version 'cerulean'`), and .luacheckrc is
--- assignments into a plain environment. Reading either with patterns would
--- test a copy of the file rather than the file, so both are run for real
--- against an environment that records instead of applying.
---
--- Any global the file CALLS becomes a recorder under its own name; any
--- global it ASSIGNS lands in the same table. A directive added tomorrow is
--- therefore captured rather than crashing the read.
--- @param path string -- relative to tests/, e.g. '../fxmanifest.lua'
--- @return table declared
function Sandbox.readDeclarations(path)
    -- The environment IS the result table, which is what lets the two
    -- shapes coexist. fxmanifest.lua CALLS its directives, so a read finds
    -- nothing and gets a recorder back; .luacheckrc ASSIGNS them, so the
    -- value lands in the table directly and the NEXT read -- `files` again,
    -- to index into it -- finds the real table rather than a recorder.
    local declared = {}

    setmetatable(declared, {
        __index = function(_, key)
            return function(value)
                rawset(declared, key, value)
                return value
            end
        end,
    })

    local chunk, err = loadfile(path, 't', declared)
    if not chunk then
        error(('sandbox: failed to load %s: %s'):format(path, tostring(err)))
    end
    chunk()

    -- Handed back without the metatable: a caller checking `declared.foo`
    -- for a directive that was never declared must get nil, not a recorder.
    return setmetatable(declared, nil)
end

--- The scripts fxmanifest.lua loads into one realm, in manifest order, with
--- other resources' `@resource/file` includes dropped.
---
--- ORDER IS THE POINT. A file that calls a global another file defines later
--- is a hard error at start and nothing else in this suite would see it, so
--- the list is returned exactly as the manifest declares it rather than
--- sorted or de-duplicated.
--- @param manifest table -- from readDeclarations('../fxmanifest.lua')
--- @param realm string -- 'client' or 'server'
--- @return string[] paths
function Sandbox.realmScripts(manifest, realm)
    local lists = { 'shared_scripts', realm .. '_scripts' }
    local paths = {}

    for _, list in ipairs(lists) do
        for _, entry in ipairs(manifest[list] or {}) do
            if not entry:find('^@') then paths[#paths + 1] = entry end
        end
    end

    return paths
end

-- ======================================================================
-- COOPERATIVE THREADS
-- ======================================================================

--- A minimal CreateThread/Wait pair backed by coroutines, for specs that
--- need to step a `while true do Wait(x) ... end` loop one pass at a time
--- instead of hanging forever.
---
--- STEPPING SEMANTICS: because these loops call Wait() as the first
--- statement in the body, the FIRST step() only reaches that Wait and
--- yields -- it primes the coroutine without running a pass. Every step
--- after that runs exactly one full body. Call step() twice for "one pass".
--- @return table runner
function Sandbox.newThreadRunner()
    local threads = {}
    local runner = { elapsed = 0 }

    function runner.CreateThread(fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    function runner.Wait(ms)
        runner.elapsed = runner.elapsed + (tonumber(ms) or 0)
        coroutine.yield()
    end

    function runner.SetTimeout(_ms, fn)
        threads[#threads + 1] = coroutine.create(fn)
    end

    --- Resumes every still-alive captured thread once.
    function runner.step()
        for _, thread in ipairs(threads) do
            if coroutine.status(thread) ~= 'dead' then
                local ok, err = coroutine.resume(thread)
                if not ok then
                    error(('sandbox thread runner: captured thread errored: %s'):format(tostring(err)))
                end
            end
        end
    end

    function runner.aliveCount()
        local alive = 0
        for _, thread in ipairs(threads) do
            if coroutine.status(thread) ~= 'dead' then alive = alive + 1 end
        end
        return alive
    end

    return runner
end

-- ======================================================================
-- FAKE QBOX / OX_LIB
-- ======================================================================

--- A stand-in for the qbx_core player object and its money, plus the
--- exports table that reaches it. Money moves through the same
--- RemoveMoney/AddMoney calls the production code uses, and every movement
--- is recorded so a spec can assert on the ledger rather than on a balance
--- alone -- a refund that happens twice and a refund that never happens
--- both leave the same balance behind.
--- @param players table<number, table>? -- { [serverId] = { citizenid, name, money } }
--- @return table fake
--- @param players table
--- @param opts table? -- { quiet = boolean }
function Sandbox.newQbxCore(players, opts)
    local fake = { players = players or {}, ledger = {} }

    -- A FRAMEWORK THAT REPORTS SUCCESS BY SAYING NOTHING. `quiet` makes the
    -- money functions return nil when they succeed instead of true, which
    -- some builds of these frameworks do -- and which this fixture used to be
    -- unable to express at all.
    --
    -- That gap hid a live defect through seventy-three passing tests: the
    -- code required exactly `true`, so on a quiet server every stake read as
    -- refused after the money had already left the player's pocket, and the
    -- pot stayed empty while the players were charged. The fixture agreed
    -- with the documentation and the server did not.
    --
    -- Failure is still reported as `false` under `quiet`: that is the one
    -- answer that is unambiguous in every build, and a fixture that made it
    -- ambiguous too would be modelling nothing real.
    local quiet = type(opts) == 'table' and opts.quiet == true
    local function yes()
        if quiet then return nil end
        return true
    end

    local function wrap(serverId, record)
        record.money = record.money or { cash = 0, bank = 0 }
        return {
            PlayerData = {
                source = serverId,
                citizenid = record.citizenid,
                name = record.name,
                charinfo = { firstname = record.firstname, lastname = record.lastname },
                money = record.money,
                job = record.job or { name = 'unemployed', grade = { level = 0 } },
            },
            Functions = {
                RemoveMoney = function(account, amount, reason)
                    local balance = record.money[account] or 0
                    if amount <= 0 or balance < amount then return false end
                    record.money[account] = balance - amount
                    fake.ledger[#fake.ledger + 1] = { id = serverId, account = account, delta = -amount, reason = reason }
                    return yes()
                end,
                AddMoney = function(account, amount, reason)
                    if amount <= 0 then return false end
                    record.money[account] = (record.money[account] or 0) + amount
                    fake.ledger[#fake.ledger + 1] = { id = serverId, account = account, delta = amount, reason = reason }
                    return yes()
                end,
                GetMoney = function(account) return record.money[account] or 0 end,
            },
        }
    end

    fake.exports = {
        qbx_core = {
            GetPlayer = function(_self, serverId)
                local record = fake.players[serverId]
                if not record then return nil end
                return wrap(serverId, record)
            end,
        },
    }

    --- Net money movement for one player across the whole ledger.
    function fake.net(serverId, account)
        local total = 0
        for _, entry in ipairs(fake.ledger) do
            if entry.id == serverId and (not account or entry.account == account) then
                total = total + entry.delta
            end
        end
        return total
    end

    --- How many separate movements one player saw -- catches a double refund
    --- that nets out to the right balance.
    function fake.movements(serverId)
        local count = 0
        for _, entry in ipairs(fake.ledger) do
            if entry.id == serverId then count = count + 1 end
        end
        return count
    end

    return fake
end

--- A stand-in for ox_lib's `lib` global covering the pieces this resource
--- uses: callback registration, and notify. Captures everything.
--- @return table lib
function Sandbox.newOxLib()
    local lib = { callbacks = {}, notifications = {} }
    lib.callback = {
        register = function(name, fn) lib.callbacks[name] = fn end,
    }
    lib.notify = function(data) lib.notifications[#lib.notifications + 1] = data end
    lib.print = { info = function() end, warn = function() end, error = function() end }
    return lib
end

return Sandbox
