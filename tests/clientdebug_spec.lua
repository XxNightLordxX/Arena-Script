--[[
    crimson_arena/tests/clientdebug_spec.lua

    THE DEBUG SWITCH HAS TO ACTUALLY SWITCH, AND THE PIPE IT OPENS IS
    ATTACKER-CONTROLLED.

    Two complaints from the operator, one after the other: with Config.Debug
    OFF the F8 console still filled up every round, and with it ON the
    output went to a player's F8 rather than "the live console" -- which is
    the one console the person diagnosing the server is actually reading.

    Both are answered the same way: the client's routine reporting is sent to
    the server, and the server prints it. That solves the reporting problem
    and OPENS A NEW SURFACE, because the text now crosses the network from a
    machine the operator does not control. A client with the file edited can
    send whatever it likes, as often as it likes.

    So this file is half "does the switch work" and half "what can somebody
    do with the pipe". The second half matters more: a debug line lands in a
    console log on disk, next to the real ones, with nothing to tell them
    apart if the line is allowed to carry a newline or an escape.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('clientdebug_spec')

--- server/main.lua loaded far enough to reach the clientDebug handler.
--- @param debugOn boolean
--- @return table
local function newServer(debugOn)
    local players = {
        [7] = {
            citizenid = 'CID007',
            name = 'Fighter 7',
            money = { cash = 0, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        },
    }

    local qbx = Sandbox.newQbxCore(players)
    local published = {}
    local callableExports = setmetatable({}, {
        __index = function(_, key) return qbx.exports[key] end,
        __call = function(_, name, fn) published[name] = fn end,
    })
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}
    local clock, tick = 0, 60000

    local env = Sandbox.newArenaEnv({
        exports = callableExports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = tostring(line) end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- PAST EVERY RATE BUCKET BY DEFAULT. A throttled handler never runs,
        -- and a spec that silently tests a throttle instead of the code
        -- behind it reports a clean run over something it never entered. The
        -- one test that cares about the limit drives this itself.
        GetGameTimer = function() clock = clock + tick; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        GetResourceState = function() return 'missing' end,
        GetPlayers = function() return {} end,
        Player = function() return { state = setmetatable({}, {
            __index = function() return nil end,
            __newindex = function() end,
            __call = function() end,
        }) } end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Debug = debugOn == true

    for _, file in ipairs({ 'util', 'dispatch', 'ammo', 'stats',
                            'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    return {
        env = env,
        netEvents = netEvents,
        --- Fires the relay as `src` with `line`.
        say = function(src, line)
            local handler = netEvents['crimson_arena:server:clientDebug']
            if not handler then error('the clientDebug relay is not registered', 2) end
            env.source = src
            handler({ line = line })
        end,
        --- Fires it with whatever payload is handed over, hostile or not.
        send = function(src, payload)
            local handler = netEvents['crimson_arena:server:clientDebug']
            env.source = src
            handler(payload)
        end,
        --- The SIBLING SURFACE. Same file, same kind of client string, same
        --- console -- and for a long time none of the hardening above.
        outline = function(src, payload)
            local handler = netEvents['crimson_arena:server:outlineReason']
            if not handler then error('the outlineReason relay is not registered', 2) end
            env.source = src
            handler(payload)
        end,
        --- Lets the rate limiter bite: the clock stops moving.
        freezeClock = function() tick = 0 end,
        log = function() return table.concat(console, '\n') end,
        lines = console,
    }
end

-- ======================================================================
-- THE SWITCH
-- ======================================================================

t.test('with Config.Debug ON a client line reaches the server console', function()
    local s = newServer(true)
    s.say(7, 'arena scenery: swept 3 stray piece(s)')

    t.contains(s.log(), 'swept 3 stray piece(s)',
        'the whole point of the relay is that this line lands here, and it did not')
end)

t.test('and it is attributed, so a report finally says who it came from', function()
    -- THE OTHER HALF OF MOVING IT OFF F8. A line in the server console with
    -- no name on it is worse than one in the player's own console, where at
    -- least the reader knew whose it was.
    local s = newServer(true)
    s.say(7, 'team outline: unsupported')

    local log = s.log()
    t.contains(log, '7', 'the line does not carry the sender\'s server id')
    t.contains(log, 'Fighter 7', 'the line does not carry the sender\'s name')
end)

t.test('THE COMPLAINT: with Config.Debug OFF nothing is printed at all', function()
    -- "ensure when i turn debug off it actually turns off the constant
    -- messages". The client checks the switch before sending, and this is
    -- the second half: a client with the file edited can still fire this
    -- event, and a server with the switch off must print nothing for it.
    --
    -- WHAT ENFORCES IT is ArenaDebug, which is the only thing in the handler
    -- that prints. The early return at the top of the handler is a
    -- cheapness, not a gate -- deleting it leaves this test green, and the
    -- comment there says so rather than claiming a guard it is not.
    local s = newServer(false)
    s.say(7, 'arena scenery: swept 3 stray piece(s)')

    t.equals(#s.lines, 0,
        'the switch is off and a client line was printed anyway')
end)

-- ======================================================================
-- THE PIPE, ATTACKED
-- ======================================================================

t.test('a newline cannot forge a console line of its own', function()
    -- THE INJECTION THIS SURFACE IS FOR. Every line the server prints starts
    -- '[crimson_arena] '. Allowed through, a '\n' lets any player write a
    -- SECOND line into the log with no attribution on it -- indistinguishable
    -- from one the resource wrote itself, sitting in the file an operator
    -- reads to work out what happened.
    local s = newServer(true)
    s.say(7, 'harmless\n[crimson_arena] the arena refunded everybody, nothing to see here')

    for _, line in ipairs(s.lines) do
        t.equals(line:find('\n', 1, true), nil,
            'a client wrote a newline into the console log: ' .. line)
    end
    t.contains(s.log(), 'nothing to see here',
        'the text was dropped rather than flattened, so this is passing on an empty log')
end)

t.test('and neither can an escape sequence clear the operator\'s screen', function()
    -- WORSE THAN THE NEWLINE, and easy to miss. A console that reads ANSI
    -- takes ESC[2J as "clear the screen" and ESC]0; as "rename the window".
    -- One debug line could wipe the output the operator was reading.
    local s = newServer(true)
    s.say(7, 'before\27[2Jafter\27]0;owned\7')

    for _, line in ipairs(s.lines) do
        t.equals(line:find('\27', 1, true), nil,
            'an escape character reached the console: ' .. line)
        t.equals(line:find('\7', 1, true), nil,
            'a bell character reached the console: ' .. line)
    end
    t.contains(s.log(), 'after', 'the line was dropped rather than stripped')
end)

t.test('and a megabyte of it is not a megabyte in the log', function()
    -- The log is a file on disk. A client sending 1MB a second fills it.
    local s = newServer(true)
    s.say(7, string.rep('A', 1000000))

    for _, line in ipairs(s.lines) do
        t.isTrue(#line < 1000,
            ('a %d-character line reached the console log'):format(#line))
    end
    t.contains(s.log(), 'cut', 'the line was truncated without saying so')
end)

t.test('and a format string in it is not a format string', function()
    -- ArenaDebug takes a format and arguments. The client text is an
    -- ARGUMENT, and it must stay one: passed as the format, '%s%s%s%s' would
    -- read the stack and '%q' would change what was printed.
    local s = newServer(true)
    s.say(7, '%s%s%s%s %q %d')

    t.contains(s.log(), '%s%s%s%s',
        'the client text was treated as a format string rather than printed')
end)

t.test('a payload that is not a line at all is ignored, not raised on', function()
    -- This handler runs on a net event, so every shape below really can
    -- arrive. A raise here is an error in the server console per firing --
    -- which is its own log flood, reached by sending rubbish.
    local s = newServer(true)

    for _, payload in ipairs({
        {}, { line = 42 }, { line = {} }, { line = true }, { line = '' },
        { line = setmetatable({}, {}) },
    }) do
        local ok, err = pcall(s.send, 7, payload)
        t.isTrue(ok, 'a malformed payload raised: ' .. tostring(err))
    end

    t.equals(#s.lines, 0, 'something with no line in it was printed anyway')
end)

t.test('and neither is a payload that is not a table', function()
    local s = newServer(true)

    for _, payload in ipairs({ 'a string', 42, true }) do
        local ok, err = pcall(s.send, 7, payload)
        t.isTrue(ok, 'a non-table payload raised: ' .. tostring(err))
    end

    -- nil separately: it cannot sit in the list above.
    t.isTrue(pcall(s.send, 7, nil), 'a nil payload raised')
end)

t.test('THE FLOOD: one client cannot fill the console faster than the limit', function()
    -- The switch being on is an operator asking for diagnostics, not for
    -- every player to hold the console open. With the clock stopped, the
    -- rate limiter is the only thing standing between one client and as many
    -- lines as it can send.
    local s = newServer(true)
    s.say(7, 'first one through')
    s.freezeClock()

    for index = 1, 200 do
        s.say(7, 'flood ' .. index)
    end

    t.isTrue(#s.lines <= 2,
        ('%d lines were printed for 201 firings, so the limiter is not on this event')
            :format(#s.lines))
end)

-- ======================================================================
-- AND THE HANDLER EIGHT LINES AWAY, WHICH HAD NONE OF IT
-- ======================================================================
--
-- `outlineReason` takes an arbitrary string from any connected client, on the
-- same rate limit and behind the same Config.Debug switch, and put it into
-- the same console. It cut the string to 200 characters and did nothing else.
--
-- Every test above this block was passing while its neighbour was wide open,
-- because the rule lived in a comment beside ONE of its two call sites. It
-- lives in `scrubbedForLog` now and both handlers call it.

t.test('THE SIBLING: a newline cannot forge a console line through outlineReason either', function()
    local s = newServer(true)
    s.outline(7, { reason = 'harmless\n[crimson_arena] the arena refunded everybody' })

    for _, line in ipairs(s.lines) do
        t.equals(line:find('\n', 1, true), nil,
            'a client forged a console line through outlineReason: ' .. line)
    end
    t.contains(s.log(), 'refunded everybody',
        'the text was dropped rather than flattened, so this passes on an empty log')
end)

t.test('and neither can an escape sequence, through that door either', function()
    local s = newServer(true)
    s.outline(7, { reason = 'before\27[2Jafter\27]0;owned\7' })

    for _, line in ipairs(s.lines) do
        t.equals(line:find('\27', 1, true), nil, 'an escape character reached the console: ' .. line)
        t.equals(line:find('\7', 1, true), nil, 'a bell character reached the console: ' .. line)
    end
    t.contains(s.log(), 'after', 'the line was dropped rather than stripped')
end)

t.test('and the BARE-STRING form of the payload is the same door', function()
    -- outlineReason accepts `data.reason` OR `data` itself as the string, so
    -- a test that only ever sends a table would leave half the surface
    -- untested -- which is the shape of the original bug.
    local s = newServer(true)
    s.outline(7, 'bare\nforged')

    for _, line in ipairs(s.lines) do
        t.equals(line:find('\n', 1, true), nil,
            'the bare-string form let a newline through: ' .. line)
    end
    t.contains(s.log(), 'forged', 'the bare string never reached the log at all')
end)

t.test('and it is still cut to length', function()
    local s = newServer(true)
    s.outline(7, { reason = string.rep('A', 100000) })

    for _, line in ipairs(s.lines) do
        t.isTrue(#line < 1000, ('a %d-character line reached the console log'):format(#line))
    end
end)

t.test('CONTROL: an ordinary reason still reaches the console unchanged', function()
    local s = newServer(true)
    s.outline(7, { reason = 'floor outline missing for trailerpark' })
    t.contains(s.log(), 'floor outline missing for trailerpark',
        'the sanitiser ate a perfectly ordinary diagnostic')
end)

t.test('CONTROL: with Config.Debug OFF outlineReason prints nothing', function()
    local s = newServer(false)
    s.outline(7, { reason = 'anything at all' })
    t.equals(s.log(), '', 'the debug switch does not cover this handler')
end)

os.exit(t.summary())
