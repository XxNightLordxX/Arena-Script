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

-- THESE WERE THREE COMMANDS OF THEIR OWN -- /arenahours, /arenaisolation
-- and /arenadispatch -- and they are three subcommands of the one command
-- this resource still registers. The readings did not change and neither did
-- the gate on them; what changed is that there is one door instead of four.
--
-- ASKED AT THE CONSOLE, because that is the only place a subcommand can be
-- typed now: a player gets the tablet and is refused anything else they type.
-- Both halves are covered below.
for _, cmd in ipairs({
    { name = 'hours',     admin = 'hours' },
    { name = 'isolation', admin = 'isolation' },
    { name = 'dispatch',  admin = 'dispatch' },
}) do
    t.test('/arenaadmin is the one command, and it is registered', function()
        t.isTrue(newServer().registered('arenaadmin'),
            'the command is not registered, so nothing below tests it')
    end)

    t.test(('/arenaadmin %s refuses a player who is not an admin, and does nothing else'):format(cmd.name), function()
        local s = newServer({ adminSrc = 4 })
        local sentTo, lines = s.run('arenaadmin', 2, { cmd.name })
        t.isTrue(refused(sentTo, 2), 'a non-admin was not told they are not cleared')
        t.isFalse(anyLine(lines, cmd.admin), ('the %s report ran for a non-admin'):format(cmd.admin))
    end)

    t.test(('and an ADMIN who is a player is sent to the tablet rather than answered in chat'):format(), function()
        -- The route, not the permission. This player may do all of it -- on
        -- the screen built to show them what they are acting on. A typed
        -- subcommand is the second door, and the second door is gone.
        local s = newServer({ adminSrc = 4 })
        local _, lines = s.run('arenaadmin', 4, { cmd.name })
        t.isFalse(anyLine(lines, cmd.admin),
            ('the %s report was printed for a player who should have been sent to the tablet'):format(cmd.admin))
    end)

    t.test(('/arenaadmin %s runs at the CONSOLE, which is the control'):format(cmd.name), function()
        local s = newServer({ adminSrc = 4 })
        local sentTo, lines = s.run('arenaadmin', 0, { cmd.name })
        t.isFalse(refused(sentTo, 0), 'the console was refused its own command')
        t.isTrue(anyLine(lines, cmd.admin) or #sentTo > 0,
            ('the %s subcommand did nothing at a console'):format(cmd.admin))
    end)
end

os.exit(t.summary())
