--[[
    crimson_arena/tests/commands_spec.lua

    THE SIX COMMANDS, AND WHETHER A PLAYER CAN FIND ANY OF THEM.

    An operator reported "there is no /arenadispatch command". It was
    registered the whole time -- shared/compat/dispatch.lua, inside the
    `if IS_SERVER then` half, since that file was written. What did not
    exist was any way to DISCOVER it: `grep -r chat:addSuggestion` over the
    whole resource came back empty, so typing /arenad offered nothing and
    the only route to a command's name was the source or the README.

    A missing autocomplete entry is invisible in exactly the way that
    matters: the command still works, so nothing errors, nothing logs, and
    no existing spec notices. That is why the drift guard below reads the
    RegisterCommand calls out of the Lua sources rather than trusting a
    hand-kept list -- the next command added to this resource fails this
    file until it is discoverable too, and a renamed one fails it until the
    suggestion is renamed with it.

    The behavioural half runs the REAL client/main.lua: the suggestions are
    asserted by capturing the events the loaded file actually raises, not
    by reading its source back.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function readFile(path)
    local handle = assert(io.open('../Crimson-Arena/' .. path, 'r'), path .. ' is missing')
    local body = handle:read('a')
    handle:close()
    return body
end

--- Every .lua file this resource ships, as { path = body }.
--- @return table
local function everyLuaFile()
    local files = {}
    local pipe = assert(io.popen("find ../Crimson-Arena -name '*.lua' -type f | sort"))
    for line in pipe:lines() do
        local path = line:gsub('^%.%./Crimson%-Arena/', '')
        files[path] = readFile(path)
    end
    pipe:close()
    return files
end

--- Every command name passed to RegisterCommand anywhere in the resource.
---
--- The resource registers commands from FOUR different files and one of
--- them is a shared_script, which is precisely how /arenadispatch came to
--- be overlooked: a search of server/*.lua does not find it.
--- @return table set -- { [name] = path }
local function registeredCommands()
    local found = {}
    for path, body in pairs(everyLuaFile()) do
        for name in body:gmatch("RegisterCommand%(%s*'([%w_]+)'") do
            found[name] = path
        end
        for name in body:gmatch('RegisterCommand%(%s*"([%w_]+)"') do
            found[name] = path
        end
    end
    return found
end

--- One load of the REAL client/main.lua, with every chat:addSuggestion it
--- raises captured.
---
--- The natives here are the ones that file touches on the way up. It is
--- the same shape lobbyworld_spec uses, trimmed to what a start-up pass
--- needs: the point is to run the file, not to model the world.
--- @return table fixture
local function loadClient()
    local runner = Sandbox.newThreadRunner()
    local suggested = {}
    local blips = {}

    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        SetTimeout = runner.SetTimeout,
        print = function() end,

        vector3 = function(x, y, z) return { x = x, y = y, z = z } end,
        PlayerPedId = function() return 1 end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetResourceState = function() return 'started' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        TriggerServerEvent = function() end,
        TriggerEvent = function(name, ...)
            if name == 'chat:addSuggestion' then
                local command, help, params = ...
                suggested[#suggested + 1] = { command = command, help = help, params = params }
            end
        end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        ArenaUI = { Open = function() end },

        joaat = function() return 1 end,
        IsModelInCdimage = function() return true end,
        IsModelValid = function() return true end,
        RequestModel = function() end,
        HasModelLoaded = function() return true end,
        GetGameTimer = function() return runner.elapsed end,

        CreatePed = function() return 7 end,
        SetModelAsNoLongerNeeded = function() end,
        DoesEntityExist = function() return true end,
        DeleteEntity = function() end,
        SetEntityAsMissionEntity = function() end,
        FreezeEntityPosition = function() end,
        SetEntityInvincible = function() end,
        SetBlockingOfNonTemporaryEvents = function() end,
        TaskStartScenarioInPlace = function() end,
        exports = setmetatable({}, {
            __index = function()
                return setmetatable({}, { __index = function() return function() end end })
            end,
        }),

        AddBlipForCoord = function() blips[#blips + 1] = true; return 3 end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipScale = function() end,
        SetBlipAsShortRange = function() end,
        SetBlipDisplay = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,
        DoesBlipExist = function() return true end,
        RemoveBlip = function() end,

        DrawMarker = function() end,
        BeginTextCommandDisplayHelp = function() end,
        EndTextCommandDisplayHelp = function() end,
        IsControlJustReleased = function() return false end,
    })

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/config.weapons.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/main.lua', env)

    runner.step()

    return { suggested = suggested, env = env }
end

-- ======================================================================
-- THE BUG THAT STARTED THIS FILE
-- ======================================================================

print('==> the command an operator could not find')

t.test('/arenadispatch is registered, in the shared realm where a server-only grep misses it', function()
    local commands = registeredCommands()
    t.isNotNil(commands.arenadispatch, '/arenadispatch is not registered anywhere in this resource')
    t.equals(commands.arenadispatch, 'shared/compat/dispatch.lua',
        '/arenadispatch moved; the spec header explaining why it was missed needs moving with it')
end)

t.test('/arenadispatch offers itself to autocomplete', function()
    local client = loadClient()
    local found
    for _, entry in ipairs(client.suggested) do
        if entry.command == '/arenadispatch' then found = entry end
    end
    t.isNotNil(found, 'typing /arenad still offers nothing -- the reported bug is back')
    t.isTrue(type(found.help) == 'string' and #found.help > 0,
        '/arenadispatch is suggested with no help text, which is a name and nothing else')
end)

t.test('the in-game reply points at somewhere the report can be read', function()
    local body = readFile('shared/compat/dispatch.lua')
    t.notContains(body, "table.concat(lines, '\\n')",
        'the in-game reply is back to one toast holding the whole report, which nobody can read')
    t.contains(body, 'Tools -> Police & EMS',
        'the in-game reply no longer says where the report can actually be read')
end)

-- ======================================================================
-- THE DRIFT GUARD
-- ======================================================================

print('==> every command is discoverable')

t.test('every RegisterCommand in the resource has a chat suggestion', function()
    local client = loadClient()
    local suggested = {}
    for _, entry in ipairs(client.suggested) do
        suggested[(entry.command or ''):gsub('^/', '')] = true
    end

    local missing = {}
    for name, path in pairs(registeredCommands()) do
        if not suggested[name] then missing[#missing + 1] = ('/%s (%s)'):format(name, path) end
    end
    table.sort(missing)
    t.equals(#missing, 0, ('these commands cannot be found by autocomplete: %s')
        :format(table.concat(missing, ', ')))
end)

t.test('every chat suggestion names a command that is actually registered', function()
    local client = loadClient()
    local commands = registeredCommands()

    local orphans = {}
    for _, entry in ipairs(client.suggested) do
        local name = (entry.command or ''):gsub('^/', '')
        if not commands[name] then orphans[#orphans + 1] = '/' .. name end
    end
    table.sort(orphans)
    t.equals(#orphans, 0, ('autocomplete offers commands that do not exist: %s')
        :format(table.concat(orphans, ', ')))
end)

t.test('every suggestion is a slash command with help, and every parameter is described', function()
    local client = loadClient()
    t.isTrue(#client.suggested > 0, 'the client raised no chat:addSuggestion at all')

    for _, entry in ipairs(client.suggested) do
        local label = tostring(entry.command)
        t.equals(label:sub(1, 1), '/', label .. ' is suggested without a leading slash')
        t.isTrue(type(entry.help) == 'string' and #entry.help > 0, label .. ' is suggested with no help text')

        if entry.params ~= nil then
            t.isTrue(type(entry.params) == 'table', label .. ' has params that are not a table')
            for index, param in ipairs(entry.params) do
                t.isTrue(type(param.name) == 'string' and #param.name > 0,
                    ('%s parameter %d has no name'):format(label, index))
                t.isTrue(type(param.help) == 'string' and #param.help > 0,
                    ('%s parameter %d has no help'):format(label, index))
            end
        end
    end
end)

t.test('the admin-only commands say so, so a player is not told to run one', function()
    local client = loadClient()
    for _, entry in ipairs(client.suggested) do
        t.contains(entry.help, '(admin)',
            tostring(entry.command) .. ' does not tell a player it is admin-only')
    end
end)

os.exit(t.summary())
