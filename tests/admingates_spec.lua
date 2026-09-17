--[[
    crimson_arena/tests/admingates_spec.lua

    THE THREE ADMIN COMMANDS NOBODY TESTED.

    Every admin NET EVENT gate is pinned -- mutate one and a spec goes red.
    Three admin CHAT COMMANDS were pinned by nothing at all: /arenahours,
    /arenaisolation and /arenadispatch. Each gate was replaced with `if false
    then` in turn and the whole suite stayed green. A chat command passes
    through no rate limiter and no wrapper; the line in the handler is the
    only protection there is. These are its tests, and each is proven by
    disabling the gate it guards and watching it go red.

    Real util, dispatch, compat/dispatch, betting, lobby, match and main.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('admingates_spec')

local function newServer(opts)
    opts = opts or {}
    local players = {}
    for src = 1, 4 do
        players[src] = { citizenid = ('CID%03d'):format(src), name = ('Player %d'):format(src),
            money = { cash = 5000, bank = 5000 }, job = { name = 'unemployed', grade = { level = 0 } } }
    end
    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local commands, sent, lines = {}, {}, {}
    -- REAL, NOT NO-OPS. These answered 0 and did nothing, which is exactly
    -- what FXServer does when routing buckets are unavailable -- so
    -- server/dispatch.lua caught the move not landing, latched provenInert
    -- and switched isolation off for this whole fixture. Every bucket line
    -- in the file it loads was dead here, and anything in this spec's own
    -- subject that touches instancing was being asked of a server that had
    -- none.
    local buckets = {}

    local env = Sandbox.newArenaEnv({
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread, Wait = threads.Wait, SetTimeout = threads.SetTimeout,
        print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            lines[#lines + 1] = table.concat(parts, ' ')
        end,
        TriggerClientEvent = function(event, target, ...)
            sent[#sent + 1] = { event = event, target = target, args = { ... } }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return 0 end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayers = function() return {} end,
        IsPlayerAceAllowed = function(src) return opts.adminSrc ~= nil and tonumber(src) == opts.adminSrc end,
        PerformHttpRequest = function() end,
        GetResourceState = function() return 'missing' end,
        IsDuplicityVersion = function() return true end,
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
        SetRoutingBucketEntityLockdownMode = function() end, SetRoutingBucketPopulationEnabled = function() end,
        ArenaStats = setmetatable({ GetLeaderboard = function(cb) cb({}) end }, { __index = function() return function() end end }),
        ArenaAmmo = setmetatable({ IsEnabled = function() return false end }, { __index = function() return function() return nil end end }),
    })
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end
    Sandbox.loadInto('../Crimson-Arena/shared/compat/dispatch.lua', env)

    local s = { env = env }
    function s.run(name, src, args)
        assert(commands[name], 'no such command registered: ' .. name)
        local n1, n2 = #sent, #lines
        commands[name](src, args or {}, table.concat(args or {}, ' '))
        local outSent, outLines = {}, {}
        for i = n1 + 1, #sent do outSent[#outSent + 1] = sent[i] end
        for i = n2 + 1, #lines do outLines[#outLines + 1] = lines[i] end
        return outSent, outLines
    end
    function s.registered(name) return commands[name] ~= nil end
    return s
end

--- Whether any client event sent to `src` carries the no-permission key.
local function refused(sentList, src)
    for _, m in ipairs(sentList) do
        if m.target == src then
            for _, a in ipairs(m.args) do
                local text = type(a) == 'table' and (a.description or a.message or a.title or '') or tostring(a)
                if type(a) == 'table' then for _, v in pairs(a) do if type(v) == 'string' then text = text .. ' ' .. v end end end
                if text:find('no_permission', 1, true) or text:find('not cleared', 1, true) then return true end
            end
        end
    end
    return false
end

local function anyLine(lines, needle)
    for _, l in ipairs(lines) do if l:lower():find(needle, 1, true) then return true end end
    return false
end

-- THESE WERE THREE COMMANDS OF THEIR OWN -- /arenahours, /arenaisolation and
-- /arenadispatch -- and then, briefly, three subcommands of /arenaadmin.
-- They are neither now. This resource registers ONE command, it takes NO
-- arguments, and every reading they printed is a button on the tablet under
-- Tools. The owner's words: open the tablet and click, without typing.
--
-- SO WHAT IS LEFT TO GUARD HERE is the command itself: who may run it, what a
-- player gets, and what a console gets instead of a screen it cannot be
-- shown. Who may press each BUTTON is the adminTool event's gate, in
-- tests/admintablet_spec.lua.

t.test('/arenaadmin is the one command, and it is registered', function()
    t.isTrue(newServer().registered('arenaadmin'),
        'the command is not registered, so nothing below tests it')
end)

t.test('a player who is not an admin is refused, and no screen is sent', function()
    local s = newServer({ adminSrc = 4 })
    local sentTo = s.run('arenaadmin', 2, {})

    t.isTrue(refused(sentTo, 2), 'a non-admin was not told they are not cleared')
    for _, m in ipairs(sentTo) do
        t.isTrue(m.event ~= 'crimson_arena:client:openAdmin',
            'a non-admin was sent the admin tablet')
    end
end)

-- THE ADMIN CONTROL FOR THIS COMMAND IS NOT IN THIS FILE, and saying so is
-- better than the test that used to sit here.
--
-- This fixture's ArenaAmmo is a stub answering nil for everything, so
-- building the tablet payload throws inside it whatever the permission code
-- does -- there is no observable difference between an admin getting the
-- screen and an admin hitting that throw. The version of this test that was
-- here swallowed the throw and then looped over an empty list, so it passed
-- unconditionally: a control that cannot fail is worse than no control,
-- because it reads as cover.
--
-- tests/admintablet_spec.lua builds a real fixture and asserts the screen
-- actually goes out to an admin, in "/arenaadmin with no arguments opens the
-- tablet for a player". That is the control.

t.test('and a word typed after it is not treated as an action', function()
    -- There are no subcommands to name, so there is no wrong word either. DO
    -- NOT make this a refusal: refusing implies a right word exists.
    --
    -- What is checked at a CONSOLE, where the payload above cannot throw: the
    -- answer is the same whatever word follows.
    local s = newServer({ adminSrc = 4 })
    local _, plain = s.run('arenaadmin', 0, {})

    for _, word in ipairs({ 'wipe', 'stop', 'hours', 'nonsense' }) do
        local _, withWord = s.run('arenaadmin', 0, { word })
        t.equals(#withWord, #plain,
            ('typing "%s" after it changed what the command did'):format(word))
    end
end)

t.test('and the CONSOLE gets the match list, because it cannot be shown a screen', function()
    -- Source 0 has no NUI and never will. This is deliberately the whole of
    -- what a console can do: see what is running. Anything else is on the
    -- tablet, in the game.
    local s = newServer({ adminSrc = 4 })
    local sentTo, lines = s.run('arenaadmin', 0, {})

    t.equals(#sentTo, 0, 'the server console was sent a client event')
    t.isTrue(#lines > 0, 'the console was told nothing at all')
end)

t.test('and the console is NOT given the reports it used to have', function()
    -- The readings are on the tablet now. A console that printed them would
    -- be the second route this change exists to remove.
    local s = newServer({ adminSrc = 4 })
    local _, lines = s.run('arenaadmin', 0, {})
    local text = table.concat(lines, '\n'):lower()

    t.isFalse(text:find('isolation', 1, true) ~= nil, 'the console printed the instancing report')
    t.isFalse(text:find('dispatch', 1, true) ~= nil, 'the console printed the police report')
end)

os.exit(t.summary())
