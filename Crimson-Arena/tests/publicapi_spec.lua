--[[
    crimson_arena/tests/publicapi_spec.lua

    THE FIVE EXPORTS OTHER RESOURCES CALL.

    Everything else in this suite tests what the arena does to itself. This
    file tests the one surface it offers OUTWARDS: `exports['crimson_arena']`,
    which a server's dispatch, ambulance or anti-cheat script calls to ask
    whether a player is in a match. README.md names all five, so an operator
    reading it writes them into their own script and expects them to be there.

    NOT ONE OF THEM WAS EXERCISED. `deadcode_spec` counts a function as used
    when `exports()` registers it, which is true and is not the same as
    working -- and the two client-side ones, IsInArena and MatchId, had no
    test of any kind. The fixture that loads client/dispatch.lua stubs
    `exports` as a function that swallows its arguments, so even the
    registration went unobserved.

    Three things this holds, and the first is the one that breaks integrations
    silently:

      THE NAMES ARE PART OF THE      renaming an export is not a refactor.
      CONTRACT                      It is a break in somebody else's script,
                                    with no error on either side -- a nil
                                    export call just returns nothing.

      THE REGISTERED FUNCTION IS     a spec that calls ArenaDispatch.IsInArena
      THE ONE THAT ANSWERS          proves nothing about what `exports(...)`
                                    was actually handed.

      THEY TELL THE TRUTH ACROSS     entering, leaving, entering again, and
      THE WHOLE LIFECYCLE           an exit that was never entered.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('publicapi_spec')

-- ======================================================================
-- THE CLIENT SIDE
-- ======================================================================

--- Loads the real client/dispatch.lua and RECORDS what it exports, rather
--- than swallowing the registration the way every other fixture does.
local function newClient()
    local registered = {}
    local env = Sandbox.newEnv({
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { 1.0, 2.0, 3.0 } end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityMaxHealth = function() return 200 end,
        GetEntityHealth = function() return 200 end,
        IsEntityDead = function() return false end,
        IsPedRagdoll = function() return false end,
        IsPedInWrithe = function() return false end,
        SetEntityHealth = function() end,
        NetworkResurrectLocalPlayer = function() end,
        ClearPedBloodDamage = function() end,
        ResetPedVisibleDamage = function() end,
        ClearPedLastWeaponDamage = function() end,
        ClearPedTasksImmediately = function() end,
        AnimpostfxStopAll = function() end,
        SetPedCanRagdoll = function() end,
        SetEntityInvincible = function() end,
        SetEntityVisible = function() end,
        SetEntityCollision = function() end,
        FreezeEntityPosition = function() end,
        SetPoliceIgnorePlayer = function() end,
        SetDispatchCopsForPlayer = function() end,
        GetPlayerWantedLevel = function() return 0 end,
        SetPlayerWantedLevel = function() end,
        SetPlayerWantedLevelNow = function() end,

        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        Wait = function() end,
        TriggerServerEvent = function() end,
        TriggerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        lib = { notify = function() end },

        -- THE POINT OF THIS FIXTURE. Every other one throws these away.
        exports = setmetatable({}, {
            __call = function(_self, name, fn) registered[name] = fn end,
        }),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../client/dispatch.lua', env)

    return { env = env, D = env.ArenaDispatch, exported = registered }
end

t.test('DEFECT: the client registers the two exports README promises', function()
    -- A rename here is a break in somebody else's script with no error at
    -- either end: calling an export that does not exist just returns nothing.
    local c = newClient()
    t.isNotNil(c.exported['IsInArena'], 'exports("IsInArena") was never registered')
    t.isNotNil(c.exported['GetArenaMatchId'], 'exports("GetArenaMatchId") was never registered')
end)

t.test('and the registered functions are the ones that answer', function()
    -- Calling ArenaDispatch.IsInArena proves nothing about what was handed to
    -- exports(). These call what a third-party script would really reach.
    local c = newClient()
    local inArena = c.exported['IsInArena']
    local matchId = c.exported['GetArenaMatchId']

    t.isFalse(inArena(), 'the export says a fresh client is already in a match')
    t.isNil(matchId(), 'the export handed out a match id before any match')

    c.D.Enter('m-77')
    t.isTrue(inArena(), 'the export did not notice the player entering')
    t.equals(matchId(), 'm-77', 'the export handed out the wrong match id')

    c.D.Exit()
    t.isFalse(inArena(), 'the export still says the player is in a match after leaving')
    t.isNil(matchId(), 'the export still hands out a match id after leaving')
end)

t.test('and they survive a second match, which is the ordinary case', function()
    local c = newClient()
    c.D.Enter('first')
    c.D.Exit()
    c.D.Enter('second')

    t.isTrue(c.exported['IsInArena'](), 'a second match was not noticed')
    t.equals(c.exported['GetArenaMatchId'](), 'second',
        'the export is still reporting the previous match')
end)

t.test('and an Enter that arrives twice does not change the answer', function()
    -- Enter guards against a double call because overwriting the restore
    -- record would strand the player. The published fact must agree with it.
    local c = newClient()
    c.D.Enter('m-1')
    c.D.Enter('m-2')
    t.equals(c.exported['GetArenaMatchId'](), 'm-1',
        'a repeated Enter overwrote the match id the player is really in')
end)

t.test('and an Exit with nothing to exit is answered, not thrown', function()
    -- client/match.lua calls Exit on every teardown path without first
    -- working out whether it needs to, so this is reached constantly.
    local c = newClient()
    c.D.Exit()
    t.isFalse(c.exported['IsInArena'](), 'an unmatched Exit left the player marked in-arena')
end)

-- ======================================================================
-- THE SERVER SIDE
-- ======================================================================

--- The real server/dispatch.lua, again recording its registrations.
local function newServer(players)
    local registered = {}

    local env = Sandbox.newEnv({
        ExecuteCommand = function() end,
        CancelEvent = function() end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        Wait = function() end,
        RegisterNetEvent = function() end,
        TriggerClientEvent = function() end,
        SetTimeout = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        -- The state bag is server/dispatch.lua's business and isolation_spec
        -- already holds it to account; here it only has to not throw.
        Player = function()
            return { state = { set = function() end } }
        end,
        TriggerEvent = function() end,
        AddEventHandler = function() end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        exports = setmetatable({}, {
            __call = function(_self, name, fn) registered[name] = fn end,
            __index = function() return setmetatable({}, { __index = function() return function() end end }) end,
        }),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    env.ArenaLobby = { Get = function(matchId)
        local first = env.Arena.GetEnabledArenas()[1]
        return first and { id = matchId, arenaKey = first.key } or nil
    end }
    Sandbox.loadInto('../server/dispatch.lua', env)

    return { env = env, D = env.ArenaDispatch, exported = registered, players = players }
end

t.test('DEFECT: the server registers the three exports README promises', function()
    local s = newServer()
    for _, name in ipairs({ 'IsPlayerInArena', 'GetPlayerMatchId', 'GetArenaPlayers' }) do
        t.isNotNil(s.exported[name], ('exports("%s") was never registered'):format(name))
    end
end)

t.test('and they answer for a player the arena is really holding', function()
    local s = newServer()
    local inArena = s.exported['IsPlayerInArena']
    local matchOf = s.exported['GetPlayerMatchId']
    local roster = s.exported['GetArenaPlayers']

    -- A MAP, KEYED BY SERVER ID -- `{ [serverId] = matchId }`, exactly as
    -- README documents it. Counting it with `#` returns 0 whatever is in it,
    -- which is how the first version of this test passed while asserting
    -- nothing at all.
    local function size(map)
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        return n
    end

    t.isFalse(inArena(42), 'a player nobody flagged was reported as fighting')
    t.isNil(matchOf(42), 'a match id was handed out for a player in no match')
    t.equals(size(roster()), 0, 'the roster listed somebody before any match')

    s.D.Set(42, 'm-9')

    t.isTrue(inArena(42), 'a flagged player was not reported as fighting')
    t.equals(matchOf(42), 'm-9', 'the wrong match id came back')
    t.equals(size(roster()), 1, 'the roster did not list the one player in a match')
    t.equals(roster()[42], 'm-9', 'the roster mapped the player to the wrong match')

    s.D.Clear(42)
    t.isFalse(inArena(42), 'a cleared player is still reported as fighting')
    t.equals(size(roster()), 0, 'a cleared player is still on the roster')
end)

t.test('and a junk player id is refused rather than answered', function()
    -- These are called by other people's scripts, with whatever they have.
    local s = newServer()
    for _, junk in ipairs({ 'nine', -1, 0, 1 / 0 }) do
        t.isFalse(s.exported['IsPlayerInArena'](junk) == true,
            ('a junk id (%s) was reported as being in an arena'):format(tostring(junk)))
    end
    t.isFalse(s.exported['IsPlayerInArena'](nil) == true, 'nil was reported as being in an arena')
end)

t.test('and the roster is a copy, so a caller cannot edit the arena', function()
    -- It is handed to somebody else's script. If it were the live table, a
    -- third-party resource could empty this resource's idea of who is
    -- fighting -- and nothing here would ever know why.
    local s = newServer()
    s.D.Set(1, 'm')
    s.D.Set(2, 'm')

    local function size(map)
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        return n
    end

    local roster = s.exported['GetArenaPlayers']()
    t.equals(size(roster), 2, 'the roster did not list both fighters')

    -- Emptied by KEY, because it is a map. The first version of this walked
    -- it as an array, which touched nothing and then compared two zeroes.
    for src in pairs(roster) do roster[src] = nil end
    t.equals(size(roster), 0, 'the local copy was not actually emptied')

    t.equals(size(s.exported['GetArenaPlayers']()), 2,
        'emptying the returned roster emptied the arena as well')
end)

-- ======================================================================
-- AND THE NAMES MATCH WHAT AN OPERATOR IS TOLD
-- ======================================================================

t.test('every export README names is really registered, and vice versa', function()
    -- The documentation is where an integrator gets these names from, so a
    -- name in one and not the other is a broken instruction either way.
    local readme = assert(io.open('../README.md', 'r'))
    local text = readme:read('a')
    readme:close()

    local registered = {}
    for name in pairs(newClient().exported) do registered[name] = true end
    for name in pairs(newServer().exported) do registered[name] = true end

    for name in pairs(registered) do
        t.contains(text, name, ('the resource exports "%s" and README never mentions it'):format(name))
    end

    -- AND THE OTHER DIRECTION, in the spelling README really uses:
    -- `exports.crimson_arena:Name(...)`. The first version of this matched
    -- the bracket spelling, found nothing, and looped zero times -- a check
    -- that could not fail is not a check.
    local named = 0
    for name in text:gmatch('exports%.crimson_arena:(%w+)') do
        named = named + 1
        t.isTrue(registered[name] == true,
            ('README tells an operator to call "%s", which is not registered'):format(name))
    end
    t.equals(named, 5, 'README stopped listing the five exports, so this checked nothing')
end)

os.exit(t.summary())
