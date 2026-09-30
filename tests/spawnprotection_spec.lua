-- Crimson Arena: the server's anticheat hook for the revive window.

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('spawnprotection_spec')

local function load(mutate)
    local logged = {}
    local env = Sandbox.newArenaEnv({ ArenaLog = function(fmt, ...) logged[#logged + 1] = fmt:format(...) end })
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/server/spawnprotection.lua', env)
    return env, logged
end

t.test('a revive calls the server hook with the window length', function()
    local env = load()
    local got
    env.ArenaSpawnProtection.OnStart = function(src, seconds) got = { src, seconds } end
    env.ArenaSpawnProtection.Revived(7)
    t.equals(got[1], 7)
    t.equals(got[2], 5)
end)

t.test('seconds = 0 calls nothing', function()
    local env = load(function(Config) Config.Match.spawnProtection.seconds = 0 end)
    local called = false
    env.ArenaSpawnProtection.OnStart = function() called = true end
    env.ArenaSpawnProtection.Revived(7)
    t.isTrue(not called)
end)

t.test('a hook that raises is logged, not thrown into the respawn', function()
    local env, logged = load()
    env.ArenaSpawnProtection.OnStart = function() error('anticheat blew up', 0) end
    env.ArenaSpawnProtection.Revived(7)
    t.contains(table.concat(logged, '\n'), 'anticheat blew up')
end)

t.test('the shipped hooks are empty: the arena calls no anticheat itself', function()
    for _, path in ipairs({ '../Crimson-Arena/server/spawnprotection.lua', '../Crimson-Arena/client/spawnprotection.lua' }) do
        local text = io.open(path):read('a')
        t.isNil(text:lower():find('exports%.'), path .. ' calls another resource')
    end
end)

t.test('the respawn sends the revive to the hook', function()
    local text = io.open('../Crimson-Arena/server/match.lua'):read('a')
    local at = text:find('ArenaSpawnProtection.Revived(src)', 1, true)
    local send = text:find("TriggerClientEvent('crimson_arena:client:respawn'", 1, true)
    t.isNotNil(at)
    t.isTrue(at < send, 'the hook runs after the client was already told')
end)

os.exit(t.summary())
