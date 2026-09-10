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
        GetPlayerRoutingBucket = function() return 0 end, SetPlayerRoutingBucket = function() end,
        SetRoutingBucketEntityLockdownMode = function() end, SetRoutingBucketPopulationEnabled = function() end,
        ArenaStats = setmetatable({ GetLeaderboard = function(cb) cb({}) end }, { __index = function() return function() end end }),
        ArenaAmmo = setmetatable({ IsEnabled = function() return false end }, { __index = function() return function() return nil end end }),
    })
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end
    Sandbox.loadInto('../shared/compat/dispatch.lua', env)

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

for _, cmd in ipairs({
    { name = 'arenahours',     admin = 'hours' },
    { name = 'arenaisolation', admin = 'isolation' },
    { name = 'arenadispatch',  admin = 'dispatch' },
}) do
    t.test(('/%s is registered'):format(cmd.name), function()
        t.isTrue(newServer().registered(cmd.name), 'the command is not registered, so nothing below tests it')
    end)

    t.test(('/%s refuses a player who is not an admin, and does nothing else'):format(cmd.name), function()
        local s = newServer({ adminSrc = 4 })
        local sentTo, lines = s.run(cmd.name, 2, {})
        t.isTrue(refused(sentTo, 2), 'a non-admin was not told they are not cleared')
        t.isFalse(anyLine(lines, cmd.admin), ('the %s report ran for a non-admin'):format(cmd.admin))
    end)

    t.test(('/%s runs for an admin, which is the control'):format(cmd.name), function()
        local s = newServer({ adminSrc = 4 })
        local sentTo, lines = s.run(cmd.name, 4, {})
        t.isFalse(refused(sentTo, 4), 'an admin was refused their own command')
        t.isTrue(anyLine(lines, cmd.admin) or #sentTo > 0, ('the %s command did nothing for an admin'):format(cmd.admin))
    end)
end

os.exit(t.summary())
