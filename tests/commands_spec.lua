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

t.test('THE FIX THAT OUTLIVED THE BUG: there are exactly TWO commands now', function()
    -- /arenadispatch was the command nobody could discover, and this file was
    -- written because of it. Six commands became one -- /arenaadmin, which
    -- takes no arguments and opens a screen where everything is a button --
    -- and then a second was added back deliberately: /arenaconsole, which
    -- prints every report in one pass for the one place a screen cannot go.
    --
    -- Two names, both discoverable, neither taking an argument. The guard
    -- still fails the moment a THIRD is registered without being made
    -- discoverable too, which is the whole job of this file.
    local commands = registeredCommands()

    local names = {}
    for name in pairs(commands) do names[#names + 1] = name end
    table.sort(names)

    t.equals(#names, 2, 'this resource registers ' .. table.concat(names, ', '))
    t.equals(names[1], 'arenaadmin', 'the tablet command is not registered')
    t.equals(names[2], 'arenaconsole', 'the console command is not registered')
    t.equals(commands.arenaadmin, 'server/main.lua')
    t.equals(commands.arenaconsole, 'server/main.lua',
        'the two commands have drifted into different files')
end)

t.test('and BOTH offer themselves to autocomplete', function()
    local client = loadClient()

    for _, wanted in ipairs({ '/arenaadmin', '/arenaconsole' }) do
        local found
        for _, entry in ipairs(client.suggested) do
            if entry.command == wanted then found = entry end
        end
        t.isNotNil(found, 'typing /arena does not offer ' .. wanted .. ' -- the reported bug is back')
        t.isTrue(type(found.help) == 'string' and #found.help > 0,
            wanted .. ' is suggested with no help text, which is a name and nothing else')
    end
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

-- ======================================================================
-- NOTHING THIS RESOURCE SAYS OUT LOUD NAMES A COMMAND THAT IS NOT THERE
--
-- THE DEFECT THIS EXISTS TO STOP COMING BACK, and it was real and it was
-- everywhere. Six commands were retired into tablet buttons -- /arenahours,
-- /arenadispatch, /arenaisolation, /arenarevive, /arenaattachments and
-- /arenaunjam -- and the messages that told operators to run them were not
-- retired with them. A jam report ended "or run /arenaunjam <name> in the
-- server console, which does the same thing"; a compat report ended
-- "/arenadispatch re-runs this report"; an isolation warning said "Run
-- /arenaisolation for the readings". README listed `/arenaadmin stop <id>`
-- and `/arenaadmin wipe` in its command table, and REFERENCE.md sent people
-- to `/arenaadmin dispatch` -- and /arenaadmin has never taken an argument
-- in its life; a word after it is IGNORED, so those do not error, they open
-- the tablet and look like the operator did something wrong.
--
-- WHY NO OTHER SPEC CATCHES IT. Every one of these is a string. It formats,
-- it prints, it reaches the screen, and the only thing wrong with it is that
-- the instruction inside it is false -- which no assertion about lines,
-- shapes or gates can see. What it costs is the one thing this resource
-- cannot afford to spend twice: an operator reading a report, doing what it
-- says, watching nothing happen, and from then on disbelieving the report as
-- well. That is the exact complaint -- "there is no /arenadispatch command"
-- -- that this whole file was written for.
--
-- SO THE RULE IS MECHANICAL. Any `/arenaword` this resource SAYS must be a
-- command it REGISTERS. The registered set is read from the sources above,
-- not typed here, so retiring a command fails this until every message that
-- named it has been rewritten.
--
-- COMMENTS ARE EXEMPT, and deliberately: "`/arenadispatch` USED TO BE
-- REGISTERED HERE and is not a command any more" is exactly the note a
-- future reader needs, and a rule that forbade it would delete the history
-- of why these buttons exist. Only what the resource says OUT LOUD is held
-- to this.
-- ======================================================================

--- `body` with its comments blanked out, so what is left is what the file
--- can actually say to somebody.
---
--- LINE COUNT PRESERVED, because a failure here has to be able to name the
--- line an operator would have to open.
---
--- ESCAPES ARE HONOURED, and that was a real hole rather than a nicety. The
--- first version counted raw `'` and `\"` characters to decide whether a `--`
--- was inside a string. An escaped apostrophe -- `\\'` -- counted as a quote,
--- flipped the parity back to even, and the rest of the line was blanked as a
--- comment. This resource writes `%s\\'s` in log lines constantly: 26 live
--- message strings were being truncated that way, so a retired command
--- re-added after one of them would have sailed through the very check
--- written to stop it. Measured: adding /arenaunjam after the `--` in
--- server/ammo.lua's `could not read %s\\'s inventory` line passed 13/13;
--- removing only the `\\'s` from the same line made it fail.
---
--- LINE COUNT IS PRESERVED, including through block comments, because a
--- failure here has to name the line an operator would open. Blanking a
--- `--[[ ]]` span to nothing shifted every line number after it.
---
--- THE LIMIT, stated rather than hidden: this is a scanner, not a Lua parser.
--- It does not know long-bracket strings (`[[ ... ]]`), so a `--` inside one
--- can still fool it. It has no false NEGATIVES that matter -- an ordinary
--- quoted message survives the strip -- and a false positive is a comment
--- reported as a message, which is a five-second read, not a wrong build.
--- @param body string
--- @return string
local function withoutComments(body)
    -- Block comments first: --[[ ... ]] and the --[==[ ... ]==] forms. The
    -- span is replaced by its OWN newlines so nothing below it moves.
    --
    -- THE WHOLE SPAN IS CAPTURED (the outer parentheses) because gsub hands a
    -- function its CAPTURES, not the match -- so capturing only the `=` run
    -- gave the replacement nothing to count newlines in, and the span
    -- collapsed to one line. `%2` back-references the `=` run so the closing
    -- bracket has to match the opening one.
    local stripped = body:gsub('(%-%-%[(=*)%[.-%]%2%])', function(span)
        return (span:gsub('[^\n]', ''))
    end)

    local out = {}
    for line in (stripped .. '\n'):gmatch('([^\n]*)\n') do
        -- Walk the line once, tracking which quote (if any) we are inside and
        -- skipping the character after a backslash. The first `--` reached
        -- outside a string starts a comment; everything from there goes.
        local quote, i, cut = nil, 1, nil
        while i <= #line do
            local ch = line:sub(i, i)
            if quote then
                if ch == '\\' then
                    i = i + 1                     -- the escaped character, whatever it is
                elseif ch == quote then
                    quote = nil
                end
            elseif ch == "'" or ch == '"' then
                quote = ch
            elseif ch == '-' and line:sub(i + 1, i + 1) == '-' then
                cut = i
                break
            end
            i = i + 1
        end
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, '\n')
end

t.test('THE DEFECT CLASS: nothing the resource SAYS names a command it does not register',
function()
    local registered = registeredCommands()

    local offences, checked = {}, 0
    for path, body in pairs(everyLuaFile()) do
        checked = checked + 1
        local lineNo = 0
        for line in (withoutComments(body) .. '\n'):gmatch('([^\n]*)\n') do
            lineNo = lineNo + 1
            for name in line:gmatch('/(arena%w+)') do
                if not registered[name] then
                    offences[#offences + 1] = ('%s:%d names /%s, which is not a registered command')
                        :format(path, lineNo, name)
                end
            end
        end
    end

    t.isTrue(checked > 0, 'no Lua file was read at all, so this checked nothing')
    t.equals(#offences, 0, table.concat(offences, '\n'))
end)

--- The JavaScript half of withoutComments: /* ... */ spans and whole // lines,
--- with line count preserved for the same reason.
--- @param body string
--- @return string
local function withoutJsComments(body)
    local stripped = body:gsub('/%*.-%*/', function(span)
        return (span:gsub('[^\n]', ''))
    end)

    local out = {}
    for line in (stripped .. '\n'):gmatch('([^\n]*)\n') do
        out[#out + 1] = line:match('^%s*//') and '' or line
    end
    return table.concat(out, '\n')
end

t.test('and the panel does not either, which is the screen an admin is looking at', function()
    -- app.js is not Lua and is not in the walk above, and it is the one
    -- surface an operator reads WHILE deciding what to do. A dead command
    -- named there is read in the worst possible moment.
    local handle = assert(io.open('../Crimson-Arena/html/app.js', 'r'), 'app.js is missing')
    local body = handle:read('a')
    handle:close()

    local registered = registeredCommands()
    local offences, lineNo = {}, 0
    for line in (withoutJsComments(body) .. '\n'):gmatch('([^\n]*)\n') do
        lineNo = lineNo + 1
        for name in line:gmatch('/(arena%w+)') do
            if not registered[name] then
                offences[#offences + 1] =
                    ('html/app.js:%d names /%s, which is not a registered command')
                        :format(lineNo, name)
            end
        end
    end

    t.equals(#offences, 0, table.concat(offences, '\n'))
end)

t.test('and the panel scan has a CONTROL, because today it matches nothing at all', function()
    -- EVERY /arena name in app.js is currently inside a /* */ comment, so the
    -- loop above walks zero candidates and would pass with its matching
    -- broken, its stripper inverted, or its pattern misspelt. This drives the
    -- same two functions over text that does contain both cases.
    local registered = registeredCommands()

    local live = 'var msg = "run /arenaunjam <name> to clear it";'
    local found = 0
    for name in withoutJsComments(live):gmatch('/(arena%w+)') do
        if not registered[name] then found = found + 1 end
    end
    t.equals(found, 1, 'the panel scan does not notice a dead command in live JavaScript')

    for _, note in ipairs({
        '/* `/arenaunjam <name> force` USED TO BE the way in. */',
        '    // /arenaunjam was retired into a button.',
    }) do
        local left = 0
        for _ in withoutJsComments(note):gmatch('/(arena%w+)') do left = left + 1 end
        t.equals(left, 0, 'a JavaScript comment was read as a live instruction: ' .. note)
    end

    -- AND A LIVE COMMAND IS NOT AN OFFENCE, or the scan would fail the day
    -- the panel legitimately names /arenaadmin.
    local ok = 'var hint = "open /arenaadmin";'
    local bad = 0
    for name in withoutJsComments(ok):gmatch('/(arena%w+)') do
        if not registered[name] then bad = bad + 1 end
    end
    t.equals(bad, 0, 'a registered command was reported as dead')
end)

t.test('and the CONTROL: the rule really does fire on a command that is not registered',
function()
    -- Without this, the two tests above pass on a build where the patterns
    -- match nothing at all -- which is how the first version of the
    -- README cross-check in publicapi_spec managed to check zero things
    -- while reporting success.
    local registered = registeredCommands()

    local sample = "ArenaLog('run /arenaunjam to clear it')"
    local found = 0
    for name in withoutComments(sample):gmatch('/(arena%w+)') do
        if not registered[name] then found = found + 1 end
    end
    t.equals(found, 1, 'the scan does not notice a dead command in a live string')

    -- And a comment saying the same thing is NOT an offence.
    local note = '-- `/arenaunjam` USED TO BE REGISTERED HERE and is not a command any more.'
    local left = 0
    for _ in withoutComments(note):gmatch('/(arena%w+)') do left = left + 1 end
    t.equals(left, 0, 'a historical note was read as a live instruction')

    -- AND THE LINE NUMBER IS THE REAL ONE. Blanking a --[[ ]] span to nothing
    -- shifted every line after it, so the failure named a line an operator
    -- would open to find something else entirely. The span keeps its newlines.
    local withBlock = table.concat({
        'local a = 1',
        '--[[',
        'a block comment',
        'spanning lines',
        ']]',
        "ArenaLog('run /arenaunjam')",
    }, '\n')

    local at = 0
    local n = 0
    for line in (withoutComments(withBlock) .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if line:find('/arenaunjam', 1, true) then at = n end
    end
    t.equals(at, 6, 'the reported line number moved, so a failure names the wrong line')

    -- AND AN ESCAPED QUOTE DOES NOT HIDE THE REST OF THE LINE. `%s\\'s` in a
    -- single-quoted string used to flip the quote parity and blank everything
    -- after the next `--`, which is where this resource puts half its prose.
    local escaped = "ArenaLog('could not read %s\\'s inventory -- run /arenaunjam to fix it.')"
    local seen = 0
    for _ in withoutComments(escaped):gmatch('/(arena%w+)') do seen = seen + 1 end
    t.equals(seen, 1, 'an escaped quote hid a dead command from the scan')
end)

os.exit(t.summary())
