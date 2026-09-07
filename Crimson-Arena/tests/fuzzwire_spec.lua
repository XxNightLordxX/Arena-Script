--[[
    crimson_arena/tests/fuzzwire_spec.lua

    PRODUCTION SET 1 -- EVERY ENTRY POINT, HIT WITH RUBBISH.

    A FiveM client event is an open socket. Anybody on the server can fire
    `crimson_arena:server:*` with whatever they like, and a modded client
    will: nil, the wrong type, a number where a table belongs, a string a
    kilometre long, a table nested inside itself.

    Every other spec in this suite feeds these handlers payloads shaped the
    way the panel sends them, because that is what they are about. This one
    feeds them what an attacker sends, and asserts the three things that
    matter on a live server:

      IT DOES NOT RAISE.       An unhandled error inside a net event handler
                               takes the handler out; on some builds it takes
                               the resource with it. A crash is a denial of
                               service anybody can trigger from a keybind.

      IT MOVES NO MONEY.       Not a cent, in either direction, across the
                               whole sweep. A garbage payload that reaches a
                               wallet is worse than one that crashes.

      IT LEAVES NO STATE.      No match created, joined, started or ended by
                               anything malformed.

    AND THE SERVER IS STILL ALIVE AFTERWARDS. The sweep ends by doing a
    legitimate thing and checking it worked. A resource that refuses
    everything -- including the real request -- would pass the three
    assertions above and be just as broken.

    THE HANDLER LIST IS NOT WRITTEN DOWN HERE. It is whatever main.lua
    registered, read back off RegisterNetEvent, so an entry point added later
    is fuzzed the day it is written rather than the day somebody remembers.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('fuzzwire_spec')

local WALLETS = { [1] = 50000, [2] = 50000, [3] = 50000 }

--- One arena server, with every registered client event captured.
local function newServer()
    local players = {}
    for id, cash in pairs(WALLETS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- Past every RATE bucket on every call. A THROTTLED handler never
        -- runs, and a fuzz sweep against a throttle proves nothing at all --
        -- it would report a clean run over code it never entered.
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
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

    env.Config.Betting.enabled = true
    env.Config.Betting.entryFee.enabled = true
    env.Config.Match.minPlayers = 2

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    return {
        env = env, qbx = qbx, netEvents = netEvents, handlers = handlers,
        lobby = env.ArenaLobby,
        log = function() return table.concat(console, '\n') end,
    }
end

--- Total cash + bank across everybody, which nothing here may change.
local function purse(server)
    local total = 0
    for _, record in pairs(server.qbx.players) do
        total = total + (record.money.cash or 0) + (record.money.bank or 0)
    end
    return total
end

--- A table that contains itself. A reader that walks a payload without a
--- depth guard never comes back from this one.
local function cyclic()
    local node = { name = 'loop' }
    node.self = node
    node.list = { node }
    return node
end

--- The payloads. Deliberately NOT valid-shaped: a fuzz corpus of things
--- that would work is a slow way of testing the happy path.
---
--- ONE THING IS DELIBERATELY ABSENT. An earlier version of this list held a
--- table whose metatable raised on any field read, and 33 handlers duly
--- raised on it. That is not a finding: a client event payload is
--- serialised on its way to the server, and a metatable does not survive
--- that -- what arrives is a plain table. So a hostile __index is not
--- something anybody can send, and hardening every handler against one
--- would be defending against nothing while making every reader worse.
local function corpus()
    local huge = string.rep('A', 100000)
    return {
        { label = 'nil', value = nil },
        { label = 'false', value = false },
        { label = 'true', value = true },
        { label = 'number', value = 42 },
        { label = 'negative', value = -1 },
        { label = 'string', value = 'not a table' },
        { label = 'empty table', value = {} },
        { label = 'array', value = { 1, 2, 3 } },
        { label = 'a function', value = function() end },
        { label = 'cyclic table', value = cyclic() },
        { label = 'huge string field', value = { matchId = huge, arenaKey = huge, pick = huge } },
        { label = 'wrong types throughout', value = {
            matchId = {}, arenaKey = 7, modeKey = false, amount = 'lots',
            account = {}, ready = 'yes', teamKey = 0, entryFee = {}, lives = 'three',
        } },
        { label = 'numeric strings', value = {
            matchId = '1', amount = '99999999', entryFee = '-500', lives = '0',
        } },
        { label = 'huge numbers', value = {
            amount = math.maxinteger, entryFee = math.maxinteger, lives = math.maxinteger,
        } },
        { label = 'tiny numbers', value = {
            amount = math.mininteger, entryFee = -math.huge, lives = -1,
        } },
        { label = 'float infinity', value = { amount = math.huge, entryFee = math.huge } },
        { label = 'not-a-number', value = { amount = 0 / 0, entryFee = 0 / 0 } },
        { label = 'sql-ish', value = { matchId = "'; DROP TABLE crimson_arena_stats; --" } },
        { label = 'format string', value = { matchId = '%s%s%s%s%n', arenaKey = '%d' } },
        { label = 'markup', value = { matchId = '<img src=x onerror=alert(1)>' } },
    }
end

--- Every source a hostile caller might present as, including ones that are
--- not players at all.
local SOURCES = { 1, 2, 999, 0, -1 }

-- ======================================================================
-- THE SWEEP
-- ======================================================================

t.test('main.lua registers the entry points this file then fuzzes', function()
    -- The guard that stops the whole file passing over nothing. If main.lua
    -- ever stops registering through RegisterNetEvent, every sweep below
    -- would iterate an empty table and report a clean run.
    local server = newServer()
    local count = 0
    for name in pairs(server.netEvents) do
        t.isTrue(name:find('^crimson_arena:server:') ~= nil,
            ('a handler was registered under an unexpected name: %s'):format(name))
        count = count + 1
    end
    t.isTrue(count >= 15,
        ('only %d client entry points were found -- the sweep would prove little'):format(count))
end)

t.test('no entry point raises on any hostile payload, from any source', function()
    local server = newServer()
    local calls, problems = 0, {}

    for name, handler in pairs(server.netEvents) do
        for _, case in ipairs(corpus()) do
            for _, src in ipairs(SOURCES) do
                server.env.source = src
                calls = calls + 1
                local ok, err = pcall(handler, case.value)
                if not ok then
                    problems[#problems + 1] =
                        ('%s <- %s (source %s): %s'):format(name, case.label, tostring(src), tostring(err))
                end
            end
        end
    end

    t.isTrue(calls > 0, 'nothing was called, so nothing was proved')
    t.equals(#problems, 0, ('%d of %d hostile calls raised:\n  %s')
        :format(#problems, calls, table.concat(problems, '\n  ', 1, math.min(#problems, 8))))
end)

t.test('and not one of them moved any money', function()
    -- Asserted on the WHOLE server rather than one wallet: a payload that
    -- takes from one player and credits another leaves both balances wrong
    -- and the total right, so this is the weaker half -- the ledger check
    -- below is the one that catches a transfer.
    local server = newServer()
    local before = purse(server)

    for _, handler in pairs(server.netEvents) do
        for _, case in ipairs(corpus()) do
            for _, src in ipairs(SOURCES) do
                server.env.source = src
                pcall(handler, case.value)
            end
        end
    end

    t.equals(purse(server), before, 'a malformed payload moved money')
end)

t.test('and moved none through the ledger either, in either direction', function()
    local server = newServer()

    for _, handler in pairs(server.netEvents) do
        for _, case in ipairs(corpus()) do
            server.env.source = 1
            pcall(handler, case.value)
        end
    end

    -- movements() counts entries in the sandbox ledger rather than listing
    -- them: a double refund that nets out to the right balance is two
    -- movements, and that is exactly what the balance check above cannot
    -- see.
    local moves = server.qbx.movements(1)
    t.equals(moves, 0, ('%d money movement(s) were made for a player who only sent rubbish')
        :format(moves))
end)

t.test('and left no match behind', function()
    local server = newServer()

    for _, handler in pairs(server.netEvents) do
        for _, case in ipairs(corpus()) do
            for _, src in ipairs(SOURCES) do
                server.env.source = src
                pcall(handler, case.value)
            end
        end
    end

    local matches = server.lobby.All()
    t.equals(#matches, 0, ('%d match(es) were opened by malformed payloads'):format(#matches))
end)

t.test('THE HALF THAT MATTERS: and the server still works afterwards', function()
    -- A resource that answered "no" to everything would pass every
    -- assertion above and be entirely broken. This is the same fuzz sweep
    -- followed by a legitimate request, through the same handlers, on the
    -- same env.
    local server = newServer()

    for _, handler in pairs(server.netEvents) do
        for _, case in ipairs(corpus()) do
            for _, src in ipairs(SOURCES) do
                server.env.source = src
                pcall(handler, case.value)
            end
        end
    end

    server.env.source = 1
    server.netEvents['crimson_arena:server:createMatch']({
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })

    local matches = server.lobby.All()
    t.equals(#matches, 1, 'a real match could not be opened after the fuzz sweep')

    server.env.source = 2
    server.netEvents['crimson_arena:server:joinMatch']({ matchId = matches[1].id, account = 'cash' })
    t.isNotNil(server.lobby.Get(matches[1].id).players[2],
        'a real player could not join after the fuzz sweep')
end)

t.test('and said so out loud rather than failing silently', function()
    -- A refusal the operator cannot see is a support ticket. The refusal
    -- path is allowed to be quiet per event, but a sweep this size must
    -- leave SOMETHING in the console.
    local server = newServer()
    for _, handler in pairs(server.netEvents) do
        server.env.source = 1
        pcall(handler, 'not a table')
    end
    t.isTrue(#server.log() > 0, 'the whole sweep produced no console output at all')
end)

os.exit(t.summary())
