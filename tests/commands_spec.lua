--[[
    crimson_arena/tests/commands_spec.lua

    THE SEVEN COMMANDS, AND WHETHER A PLAYER CAN FIND ANY OF THEM.

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
--- @return integer calls -- how many RegisterCommand calls were seen at all
local function registeredCommands()
    local found, names, calls = {}, 0, 0
    for path, body in pairs(everyLuaFile()) do
        for _ in body:gmatch('RegisterCommand%s*%(') do
            calls = calls + 1
        end
        for name in body:gmatch("RegisterCommand%(%s*'([%w_]+)'") do
            if found[name] == nil then names = names + 1 end
            found[name] = path
        end
        for name in body:gmatch('RegisterCommand%(%s*"([%w_]+)"') do
            if found[name] == nil then names = names + 1 end
            found[name] = path
        end
    end
    return found, calls, names
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
    local handlers = {}

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
        AddEventHandler = function(name, fn) handlers[name] = fn end,
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

    return {
        suggested = suggested, env = env,
        --- Fire one of the events the client registered for.
        fire = function(name, ...)
            if handlers[name] then handlers[name](...) end
            return handlers[name] ~= nil
        end,
        --- Forget every suggestion raised so far, the way the chat resource
        --- forgets its own list when it restarts.
        forgetSuggestions = function()
            for index = #suggested, 1, -1 do suggested[index] = nil end
        end,
    }
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

t.test('and the suggestions come back when the chat resource restarts', function()
    -- THE SAME BUG BY A DIFFERENT ROUTE. The suggestions live in the CHAT
    -- resource's own per-client list, not in this one, so `restart chat` --
    -- or chat starting after crimson_arena, which is the start order this
    -- resource deliberately asks for -- empties it and every name goes with
    -- it. Nothing errors and nothing logs: the commands still work, so the
    -- only symptom is typing /arenad and being offered nothing, which is
    -- exactly the report this file exists for.
    local client = loadClient()
    local before = #client.suggested
    t.isTrue(before > 0, 'nothing was suggested at start, so this proves nothing')

    client.forgetSuggestions()
    t.equals(#client.suggested, 0, 'the list did not empty, so this proves nothing')

    t.isTrue(client.fire('onClientResourceStart', 'chat'),
        'the client does not listen for the chat resource coming back at all')
    t.equals(#client.suggested, before, 'the suggestions were not raised again')
end)

t.test('and not for every other resource that starts', function()
    -- onClientResourceStart fires for every resource on the server.
    local client = loadClient()
    client.forgetSuggestions()

    client.fire('onClientResourceStart', 'some_other_resource')

    t.equals(#client.suggested, 0,
        'six suggestions were re-raised because an unrelated resource started')
end)

t.test('the in-game reply points at somewhere the report can be read', function()
    -- READ OUT OF THE FILE'S SOURCE, WHICH IS THE WEAK HALF. A grep cannot
    -- tell a toast from a comment: putting the whole report back through
    -- `table.concat(lines, "\n")` -- double quotes this time -- and leaving
    -- the phrase behind in a comment restores the exact reported bug with
    -- both assertions below still passing. The behavioural half lives in
    -- dispatch_spec ('the in-game reply is one short line, not the report'),
    -- which captures the toast the command actually raises; these two stay
    -- because they name the shape, and the pair is what closes it.
    local body = readFile('shared/compat/dispatch.lua')
    t.notContains(body, "table.concat(lines, '\\n')",
        'the in-game reply is back to one toast holding the whole report, which nobody can read')
    t.contains(body, 'Tools -> Police & EMS',
        'the in-game reply no longer says where the report can actually be read')
end)

-- ======================================================================
-- THE DRIFT GUARD
-- ======================================================================

t.test('and the scan sees every RegisterCommand call, not only the ones it can name', function()
    -- THE GUARD ON THE GUARD, and the hole is the same shape as the bug this
    -- file exists for: something invisible to a search. The two patterns
    -- above read a name only out of a quoted literal, so a command
    -- registered under a variable, a config value, or a name with a hyphen
    -- in it is not in `found` at all -- it ships with no autocomplete entry
    -- and the drift test below goes quietly green over a shorter list.
    --
    -- Counting the calls costs nothing and says so: every RegisterCommand in
    -- this resource has to be one this file can read the name of.
    local found, calls, names = registeredCommands()
    t.isTrue(calls > 0, 'no RegisterCommand call was found anywhere, so nothing below is tested')
    t.equals(names, calls,
        ('%d RegisterCommand call(s) in the resource and %d name(s) could be read out of them -- '
            .. 'a command whose name is not a quoted literal is invisible to this file')
            :format(calls, names))

    local counted = 0
    for _ in pairs(found) do counted = counted + 1 end
    t.equals(counted, names, 'two files register the same command name')
end)

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
