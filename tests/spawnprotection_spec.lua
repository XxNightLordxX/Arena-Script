-- Crimson Arena: the server's anticheat hook for the revive window.

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('spawnprotection_spec')

local function load(mutate, opts)
    opts = opts or {}
    local logged, handlers, threads, hooks = {}, {}, {}, {}
    local clock = { now = 1000 }
    local fini = {
        AddDetectionHook = function(_self, fn)
            if opts.hookRaises then error('export missing', 0) end
            hooks[#hooks + 1] = fn
        end,
    }
    local env = Sandbox.newArenaEnv({
        ArenaLog = function(fmt, ...) logged[#logged + 1] = fmt:format(...) end,
        GetGameTimer = function() return clock.now end,
        GetConvarInt = function(name, default)
            if name == 'FiniAC:Started' then return opts.fini == 'missing' and 0 or 1 end
            return default
        end,
        -- NOT what decides: FiniAC's docs say the export is not ready the
        -- moment the resource is 'started'. Always answers started here so a
        -- regression back to reading it is caught by the convar-0 case.
        GetResourceState = function() return 'started' end,
        exports = setmetatable({ FiniAC = fini }, { __call = function() end }),
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        CreateThread = function(fn) threads[#threads + 1] = fn end,
    })
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/server/spawnprotection.lua', env)
    for _, fn in ipairs(threads) do fn() end
    local f = { env = env, SP = env.ArenaSpawnProtection, logged = logged, hooks = hooks,
        handlers = handlers, clock = clock }
    function f.detect(src, kind) return hooks[1]({ source = src }, { type = kind, data = {} }) end
    return f, logged
end

t.test('a revive calls the server hook with the window length', function()
    local f = load()
    local env = f.env
    local got
    env.ArenaSpawnProtection.OnStart = function(src, seconds) got = { src, seconds } end
    env.ArenaSpawnProtection.Revived(7)
    t.equals(got[1], 7)
    t.equals(got[2], 5)
end)

t.test('seconds = 0 calls nothing', function()
    local env = load(function(Config) Config.Match.spawnProtection.seconds = 0 end).env
    local called = false
    env.ArenaSpawnProtection.OnStart = function() called = true end
    env.ArenaSpawnProtection.Revived(7)
    t.isTrue(not called)
end)

t.test('a hook that raises is logged, not thrown into the respawn', function()
    local f, logged = load()
    local env = f.env
    env.ArenaSpawnProtection.OnStart = function() error('anticheat blew up', 0) end
    env.ArenaSpawnProtection.Revived(7)
    t.contains(table.concat(logged, '\n'), 'anticheat blew up')
end)

t.test('the operator hooks ship empty', function()
    local f = load()
    t.isNil(f.SP.OnStart(1, 5))
end)

-- ---- FiniAC ------------------------------------------------------------

t.test('THE ASK: a god-mode detection inside the revive window is cancelled, and logged', function()
    local f = load()
    t.equals(#f.hooks, 1, 'the FiniAC hook was not registered')
    f.SP.Revived(7)
    t.equals(f.detect(7, 'GodMode'), false)
    t.contains(table.concat(f.logged, '\n'), 'cancelled FiniAC GodMode on 7')
end)

t.test('any other detection in the window goes through untouched', function()
    local f = load()
    f.SP.Revived(7)
    local got = f.detect(7, 'BlacklistedWeapon')
    t.equals(got.type, 'BlacklistedWeapon')
end)

t.test('the same detection on a player with no window goes through', function()
    local f = load()
    f.SP.Revived(7)
    t.equals(f.detect(8, 'GodMode').type, 'GodMode')
end)

t.test('THE REVIEW: the window covers the client\'s placement wait -- 5 + 5 + 2 = 12 s', function()
    local f = load()
    f.SP.Revived(7)
    f.clock.now = f.clock.now + 11900
    t.equals(f.detect(7, 'GodMode'), false, 'the window closed while an honest client could still be protected')
    f.clock.now = f.clock.now + 200
    t.equals(f.detect(7, 'GodMode').type, 'GodMode', 'the window stayed open past 12 seconds')
end)

t.test('FINAL CHECK: leaving shrinks the window to the network grace, never lengthens it', function()
    local f = load()
    f.SP.Revived(7)
    f.SP.Clear(7)
    f.clock.now = f.clock.now + 1900
    t.equals(f.detect(7, 'GodMode'), false, 'a detection in flight during the exit trip was not cancelled')
    f.clock.now = f.clock.now + 200
    t.equals(f.detect(7, 'GodMode').type, 'GodMode', 'the window outlived the exit grace')
    -- A window with under 2 s left is not lengthened by a Clear.
    f.SP.Revived(8)
    f.clock.now = f.clock.now + 11000
    f.SP.Clear(8)
    f.clock.now = f.clock.now + 1100
    t.equals(f.detect(8, 'GodMode').type, 'GodMode', 'Clear lengthened a window')
end)

t.test('a player leaving closes their window', function()
    local f = load()
    f.SP.Revived(7)
    f.env.source = 7
    f.handlers['playerDropped']()
    t.equals(f.detect(7, 'GodMode').type, 'GodMode')
end)

t.test('finiHook = false registers nothing', function()
    local f = load(function(Config) Config.Match.spawnProtection.finiHook = false end)
    t.equals(#f.hooks, 0)
end)

t.test('enabled = false: no server hook call, no FiniAC hook', function()
    local f = load(function(Config) Config.Match.spawnProtection.enabled = false end)
    t.equals(#f.hooks, 0, 'the FiniAC hook was registered with protection switched off')
    local called = false
    f.env.ArenaSpawnProtection.OnStart = function() called = true end
    f.env.ArenaSpawnProtection.Revived(7)
    t.isTrue(not called, 'OnStart ran with protection switched off')
end)

t.test('protection off (seconds = 0) registers nothing', function()
    local f = load(function(Config) Config.Match.spawnProtection.seconds = 0 end)
    t.equals(#f.hooks, 0)
end)

t.test('DOCS: FiniAC not yet running (convar 0) -- nothing at start; hooks on FiniAC:Started', function()
    local f = load(nil, { fini = 'missing' })
    t.equals(#f.hooks, 0, 'the export was called before FiniAC said it had started')
    f.handlers['FiniAC:Started']()
    t.equals(#f.hooks, 1)
end)

t.test('DOCS: a FiniAC restart re-registers the hook', function()
    local f = load()
    t.equals(#f.hooks, 1)
    f.handlers['FiniAC:Started']()
    t.equals(#f.hooks, 2)
end)

t.test('DOCS: FiniAC\'s own god-mode names are all cancelled in the window; others are not', function()
    local f = load()
    f.SP.Revived(7)
    for _, kind in ipairs({ 'GodModePed', 'GodModeV2', 'GodModeV3' }) do
        t.equals(f.detect(7, kind), false, kind .. ' was not cancelled')
    end
    for _, kind in ipairs({ 'NoclipV2', 'InvisiblePed', 'SpeedHack', 'BlacklistedWeapon', 'Teleport' }) do
        t.equals(f.detect(7, kind).type, kind, kind .. ' was cancelled')
    end
end)

t.test('an export that fails is logged, never thrown', function()
    local f = load(nil, { hookRaises = true })
    t.contains(table.concat(f.logged, '\n'), 'could not be registered')
end)

t.test('junk from FiniAC is handed back, never raised on', function()
    local f = load()
    f.SP.Revived(7)
    t.equals(f.env.ArenaSpawnProtection.FiniDetectionHook(nil, 'x'), 'x')
    local d = { type = nil }
    t.equals(f.env.ArenaSpawnProtection.FiniDetectionHook({ source = 7 }, d), d)
end)

t.test('the respawn sends the revive to the hook', function()
    local text = io.open('../Crimson-Arena/server/match.lua'):read('a')
    local at = text:find('ArenaSpawnProtection.Revived(src)', 1, true)
    local send = text:find("TriggerClientEvent('crimson_arena:client:respawn'", 1, true)
    t.isNotNil(at)
    t.isTrue(at < send, 'the hook runs after the client was already told')
end)

os.exit(t.summary())
