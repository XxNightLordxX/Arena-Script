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

    THE HANDLER LIST IS NOT WRITTEN DOWN HERE. It is whatever the resource
    registered, read back off RegisterNetEvent, so an entry point added later
    is fuzzed the day it is written rather than the day somebody remembers.
    Three more are reached by name because they do not register that way:
    `getState` is an ox_lib CALLBACK, and playerDropped / onResourceStop are
    AddEventHandler.

    WHAT AN EARLIER VERSION OF THIS FILE GOT WRONG, kept here because the
    same trap is waiting for the next person:

      IT NEVER REACHED THE MONEY. Not one corpus payload carried a usable
      matchId or pick, so ArenaBetting.PlaceSpectatorBet was entered zero
      times out of a hundred -- and "moved no money" was measured over code
      that never ran. An unconditional wallet debit planted at the top of
      that function did not turn this file red. So the corpus now sends a
      VALID ENVELOPE with hostile contents: the real match id, a real pick,
      and an amount that is NaN, infinite, negative or a table.

      IT READ ONE PLAYER'S LEDGER. movements(1) cannot see money moved
      between two OTHER players. The whole ledger is counted now.

      IT VISITED THE HANDLERS IN A RANDOM ORDER. Lua 5.4 seeds string hashes
      per process, so `pairs` gave a different order every run and one
      mutation was caught 4 times in 20. Sorted now.

      IT MEASURED THE END STATE. The sweep created matches and then tore
      them down with its own cancelMatch calls, so "left no match behind"
      was true of a room somebody had already tidied. The PEAK is measured
      now, after every single call.

    WHAT IS STILL STUBBED, stated rather than implied: ox_inventory and
    oxmysql are not present, so server/ammo.lua and server/stats.lua run
    against the sandbox's doubles. Every other server file is the shipped
    one, server/dispatch.lua included -- which matters, because it registers
    client-firable handlers of its own for Config.Dispatch.cancelEvents, and
    those are fuzzed here too.
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
    -- CALLABLE AND INDEXABLE. server/dispatch.lua publishes its own exports
    -- with `exports('name', fn)`, and the sandbox's is a plain table -- so
    -- that file could not be loaded at all, and its client-firable handlers
    -- went unfuzzed. This proxy is both.
    local published = {}
    local callableExports = setmetatable({}, {
        __index = function(_, key) return qbx.exports[key] end,
        __call = function(_, name, fn) published[name] = fn end,
    })
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers, notices = {}, {}, {}, {}
    local oxlib = Sandbox.newOxLib()
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = callableExports,
        lib = oxlib,
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            if event == 'crimson_arena:client:notify' then
                notices[#notices + 1] = { target = target, payload = payload }
            end
        end,
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
        -- server/dispatch.lua publishes a state bag per player and walks the
        -- server list; both are real calls now that the file is loaded.
        -- server/ammo.lua and server/stats.lua both ask whether their
        -- dependency is running before they touch it. Absent, every call
        -- into them raised -- 80 of them -- which looked like 80 findings
        -- and was one missing stub.
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
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
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

    env.Config.Betting.enabled = true
    env.Config.Betting.entryFee.enabled = true
    env.Config.Match.minPlayers = 2

    -- EVERY SERVER FILE, in manifest order. The earlier version loaded five
    -- of eight and called itself "every entry point"; server/dispatch.lua
    -- alone registers a client-firable handler per Config.Dispatch
    -- .cancelEvents entry, none of which were being fuzzed.
    for _, file in ipairs({ 'util', 'dispatch', 'ammo', 'stats',
                            'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    return {
        env = env, qbx = qbx, netEvents = netEvents, handlers = handlers,
        lobby = env.ArenaLobby, notices = notices, oxlib = oxlib,
        published = published,
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
--- @param matchId string? -- the REAL match to aim the valid-envelope cases at
local function corpus(matchId)
    local huge = string.rep('A', 100000)
    local real = matchId or 'no-such-match'
    return {
        -- A VALID ENVELOPE WITH HOSTILE CONTENTS, which is the shape an
        -- attacker actually sends and the one this file did not have. Every
        -- id and key below is real, so the payload gets past the shape
        -- guards and into the code that moves money; every AMOUNT is
        -- something no wallet may ever be debited by.
        { label = 'real match, NaN stake', value = {
            matchId = real, pick = '2', amount = 0 / 0, account = 'cash' } },
        { label = 'real match, infinite stake', value = {
            matchId = real, pick = '2', amount = math.huge, account = 'cash' } },
        { label = 'real match, negative stake', value = {
            matchId = real, pick = '2', amount = -100000, account = 'cash' } },
        { label = 'real match, enormous stake', value = {
            matchId = real, pick = '2', amount = math.maxinteger, account = 'bank' } },
        { label = 'real match, stake as a table', value = {
            matchId = real, pick = '2', amount = {}, account = 'cash' } },
        -- NOT '5000'. A numeric string is a LEGITIMATE amount -- Arena.ToInt
        -- accepts it, and it should -- so that case belongs in a test about
        -- coercion, not in a corpus whose whole premise is that nothing in
        -- it may ever be honoured. It cost an hour: the sweep took a valid
        -- 5,000 side-bet and the money assertion correctly reported a
        -- 5,000 move, which read as a defect and was the corpus lying.
        { label = 'real match, stake as junk text', value = {
            matchId = real, pick = '2', amount = 'five thousand', account = 'cash' } },
        -- The junk ACCOUNT is not what makes this hostile -- the amount is.
        -- accountsFor deliberately reads a name the player does not hold as
        -- "no preference" and falls back to the operator's list, and says so
        -- at length: refusing somebody who can plainly pay because a stale
        -- panel sent a word nobody recognises helps nobody. So a valid stake
        -- with a junk account is a bet this resource MEANS to honour, and
        -- putting it in this corpus made a correct 500 debit look like a
        -- defect. The rule the corpus has to obey: nothing in it may be
        -- something the design intends to accept.
        { label = 'real match, junk account AND no real amount', value = {
            matchId = real, pick = '2', amount = 0 / 0, account = 'crypto' } },
        { label = 'real match, pick nobody is', value = {
            matchId = real, pick = '4242', amount = 500, account = 'cash' } },
        { label = 'real match, junk everywhere else', value = {
            matchId = real, arenaKey = 'trailerpark', modeKey = 'ffa',
            ready = 'yes', teamKey = 0, entryFee = -1, lives = math.huge,
            account = {}, amount = 0 / 0 } },

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

--- Sources the sweep presents as, and what each one is for. Measured
--- rather than assumed: 0 and -1 are refused by ArenaRateLimit before any
--- handler body runs (server/util.lua rejects src <= 0), so they exercise
--- that floor and nothing else -- which is worth one line, not a third of
--- the sweep.
---   1  the host of the seeded match
---   2  the other fighter in it
---   3  a real player who is in NO match
--- 999  a server id with no player behind it
---   0  and -1: the rate limiter's floor
local SOURCES = { 1, 2, 3, 999, 0, -1 }

--- The sources used for the money assertion. NOBODY here is in the seeded
--- match, so any money movement at all is a defect -- a non-participant has
--- nothing legitimate to pay and nothing legitimate to be paid.
local OUTSIDERS = { 3, 999 }

-- ======================================================================
-- WHAT COUNTS AS AN ENTRY POINT
-- ======================================================================

--- Everything on this server that an outsider can reach, as a sorted list
--- of { kind, name, fire(payload) }.
---
--- RegisterNetEvent is not the whole surface, and treating it as such is
--- what left two thirds of this unfuzzed:
---
---   net      17 crimson_arena:server:* handlers.
---   callback getState, registered through ox_lib rather than
---            RegisterNetEvent -- and main.lua's own comment calls it the
---            most expensive thing a client can ask for.
---   handler  11 AddEventHandler registrations. Five are the third-party
---            names in Config.Dispatch.cancelEvents, which clients raise.
---            Two are FiveM's OWN client-triggered server events --
---            weaponDamageEvent and explosionEvent -- which carry data
---            straight from a player's machine and are the most attacker-
---            controlled input this resource reads.
local function entryPoints(server)
    local points = {}

    for name, handler in pairs(server.netEvents) do
        points[#points + 1] = { kind = 'net', name = name, fire = function(payload)
            return handler(payload)
        end }
    end

    for name, handler in pairs(server.oxlib.callbacks or {}) do
        points[#points + 1] = { kind = 'callback', name = name, fire = function(payload)
            return handler(1, payload)
        end }
    end

    for name, handler in pairs(server.handlers) do
        points[#points + 1] = { kind = 'handler', name = name, fire = function(payload)
            -- Two shapes reach these: a single payload, and the (sender,
            -- data) pair FiveM uses for weaponDamageEvent and
            -- explosionEvent. Both are tried, because guessing wrong would
            -- mean fuzzing a handler with an argument it never reads.
            handler(payload)
            handler(1, payload)
        end }
    end

    -- SORTED, so the sweep visits the same entry points in the same order
    -- every run. `pairs` looked fine and was not: Lua 5.4 seeds its string
    -- hashes per process, so the order changed on every run and one
    -- mutation was caught in 4 runs out of 20. A flaky test is worse than
    -- no test -- it teaches people to re-run until green.
    table.sort(points, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)
    return points
end

--- Opens a REAL match with a REAL entry fee and a second fighter in it.
---
--- Without this the sweep never reaches a single line that touches money:
--- no corpus payload carries a usable match id, so every betting call dies
--- at the shape guard and "moved no money" is measured over code that never
--- runs. With it, the corpus can send a valid envelope and hostile
--- contents, which is the shape an attacker actually uses.
--- @return string matchId
local function seedMatch(server)
    server.env.source = 1
    server.netEvents['crimson_arena:server:createMatch']({
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 1000, account = 'cash',
    })
    local all = server.lobby.All()
    t.equals(#all, 1, 'the fixture could not open a real match to fuzz against')

    server.env.source = 2
    server.netEvents['crimson_arena:server:joinMatch']({ matchId = all[1].id, account = 'cash' })
    t.isNotNil(server.lobby.Get(all[1].id).players[2], 'the second fighter could not join')

    return all[1].id
end

--- Runs the whole corpus at every entry point, from every source, recording
--- the highest match count seen at ANY point rather than the count at the
--- end -- the sweep fires cancelMatch and leaveMatch too, so it demolishes
--- what it builds and an end-state reading is of a tidied room.
--- @return table report
local function sweep(server, matchId, sources)
    local raised, calls, peak = {}, 0, #server.lobby.All()

    for _, point in ipairs(entryPoints(server)) do
        for _, case in ipairs(corpus(matchId)) do
            for _, src in ipairs(sources) do
                server.env.source = src
                calls = calls + 1
                local ok, err = pcall(point.fire, case.value)
                if not ok then
                    raised[#raised + 1] = ('%s %s <- %s (source %s): %s')
                        :format(point.kind, point.name, case.label, tostring(src), tostring(err))
                end
                local now = #server.lobby.All()
                if now > peak then peak = now end
            end
        end
    end

    return { raised = raised, calls = calls, peak = peak }
end

-- ======================================================================
-- THE SWEEP
-- ======================================================================

t.test('the surface this file fuzzes is the whole surface, not just net events', function()
    -- The guard that stops everything below passing over nothing -- and the
    -- one that catches an entry point registered through a mechanism this
    -- file does not know about yet.
    local server = newServer()
    local counts = { net = 0, callback = 0, handler = 0 }
    for _, point in ipairs(entryPoints(server)) do
        counts[point.kind] = counts[point.kind] + 1
    end

    t.equals(counts.net, 21, 'the number of client events changed -- update this file with it')
    t.isTrue(counts.callback >= 1, 'the ox_lib callback surface vanished')
    t.isTrue(counts.handler >= 8,
        ('only %d AddEventHandler entry points found'):format(counts.handler))

    -- Named rather than counted, because these three are the ones an
    -- attacker reaches without this resource ever inviting them.
    local byName = {}
    for _, point in ipairs(entryPoints(server)) do byName[point.name] = true end
    for _, required in ipairs({
        'crimson_arena:server:getState', 'weaponDamageEvent',
        'explosionEvent', 'playerDropped',
        -- THE ADMIN TABLET. Named rather than left to the count, because
        -- these four are the ones that STOP matches, revive people and empty
        -- stashes -- the highest-value things on the wire, and the ones an
        -- attacker reaches by firing the event rather than by running the
        -- command that draws the screen.
        'crimson_arena:server:adminState', 'crimson_arena:server:adminStop',
        'crimson_arena:server:adminRevive', 'crimson_arena:server:adminReturn',
    }) do
        t.isTrue(byName[required] == true, ('%s is no longer being fuzzed'):format(required))
    end
end)

t.test('no entry point raises on any hostile payload, from any source', function()
    local server = newServer()
    local matchId = seedMatch(server)
    local report = sweep(server, matchId, SOURCES)

    t.isTrue(report.calls > 1000, ('only %d calls were made'):format(report.calls))
    t.equals(#report.raised, 0, ('%d of %d hostile calls raised:\n  %s')
        :format(#report.raised, report.calls,
            table.concat(report.raised, '\n  ', 1, math.min(#report.raised, 8))))
end)

t.test('THE ONE THAT WAS UNFALSIFIABLE: no hostile stake ever debits a wallet', function()
    -- Aimed at placeSpectatorBet alone, and deliberately so. The broad
    -- sweep hands every handler a payload carrying the REAL match id, and
    -- to joinMatch that is simply a valid join -- an entry fee taken and
    -- later refunded when the sweep's own leaveMatch fires. Asserting "no
    -- money at all" over that would be asserting that a legal join is a
    -- defect; the conservation test below is what covers the sweep as a
    -- whole.
    --
    -- What was actually broken is here: this handler is the only one that
    -- debits on an attacker's say-so, and the earlier version of this file
    -- never reached it. An unconditional wallet debit planted at the top of
    -- PlaceSpectatorBet left the file green.
    --
    -- Every amount in the corpus is NaN, infinite, negative, enormous, a
    -- table or junk text. Not one may take a cent.
    local server = newServer()
    local matchId = seedMatch(server)
    local ledgerAfterSetup = #server.qbx.ledger

    for _, case in ipairs(corpus(matchId)) do
        for _, src in ipairs(OUTSIDERS) do
            server.env.source = src
            pcall(server.netEvents['crimson_arena:server:placeSpectatorBet'], case.value)
        end
    end

    -- THE WHOLE LEDGER, not one player's count. movements(1) cannot see
    -- money moved between two OTHER players, and a transfer that balances
    -- is exactly what a purse total is blind to.
    t.equals(#server.qbx.ledger, ledgerAfterSetup,
        ('%d wallet movement(s) were made by side-bets no amount of which was real')
            :format(#server.qbx.ledger - ledgerAfterSetup))
end)

t.test('and the sweep as a whole creates and destroys no money', function()
    -- The broad law over every entry point. Individual movements are
    -- legitimate here -- a valid join takes a fee, a leave hands it back --
    -- so this asserts the total, which is the thing that must not drift.
    -- MEASURED FROM BEFORE THE STAKES ARE TAKEN, and settled afterwards.
    -- Reading the purse after seeding puts the two entry fees in escrow
    -- rather than in wallets, so the sweep handing them back reads as +2000
    -- created. It is not: it is money going home. The law only closes when
    -- escrow is empty at both ends.
    local server = newServer()
    local before = purse(server)

    local matchId = seedMatch(server)
    sweep(server, matchId, SOURCES)

    for _, match in ipairs(server.lobby.All()) do
        pcall(server.env.ArenaMatch.Abort, match.id, 'match.ended_abandoned')
        pcall(server.lobby.Destroy, match.id, 'notify.match_closed')
    end

    t.equals(purse(server), before,
        'the hostile sweep created or destroyed money across the whole server')
end)

t.test('and the betting path really is entered, or the test above proves nothing', function()
    -- The teeth check for the test above. If the corpus stops reaching
    -- ArenaBetting.PlaceSpectatorBet, that test silently goes back to
    -- measuring an empty room -- which is how it shipped the first time.
    local server = newServer()
    local matchId = seedMatch(server)

    local entered = 0
    local real = server.env.ArenaBetting.PlaceSpectatorBet
    server.env.ArenaBetting.PlaceSpectatorBet = function(...)
        entered = entered + 1
        return real(...)
    end

    sweep(server, matchId, OUTSIDERS)
    server.env.ArenaBetting.PlaceSpectatorBet = real

    t.isTrue(entered > 0,
        'no hostile payload reached PlaceSpectatorBet, so the money assertion is vacuous')
end)

t.test('and no match is created by anything malformed, at any point', function()
    -- The PEAK, not the end state. The sweep fires cancelMatch and
    -- leaveMatch with the same sources it fires createMatch with, so it
    -- tears down whatever it builds; reading the count at the end is
    -- reading a room somebody already tidied.
    local server = newServer()
    local matchId = seedMatch(server)
    local report = sweep(server, matchId, SOURCES)

    t.equals(report.peak, 1,
        ('the match count reached %d -- malformed payloads opened matches'):format(report.peak))
end)

t.test('and a refusal actually reaches the player who sent it', function()
    -- Replaces an assertion that measured one debug print. It passed on 57
    -- characters from the one handler in the file that changes no state,
    -- and deleting the notification from refuse() entirely did not fail it.
    local server = newServer()
    seedMatch(server)

    local before = #server.notices
    server.env.source = 1
    server.netEvents['crimson_arena:server:joinMatch']({ matchId = 'no-such-match' })

    t.isTrue(#server.notices > before,
        'a refused request told the player nothing at all')
    local last = server.notices[#server.notices]
    t.equals(last.target, 1, 'the refusal went to somebody other than the sender')
    t.isTrue(type(last.payload) == 'table' and type(last.payload.description) == 'string'
        and #last.payload.description > 0,
        'the refusal carried no sentence')
end)

t.test('THE HALF THAT MATTERS: and the server still works afterwards', function()
    -- A resource that answered "no" to everything would pass every
    -- assertion above and be completely broken.
    -- Swept from OUTSIDERS. A sweep including the host is a sweep in which
    -- `leaveMatch` legitimately closes the lobby -- correct behaviour, and
    -- it would make "the match survived" a false thing to demand.
    local server = newServer()
    local matchId = seedMatch(server)
    sweep(server, matchId, OUTSIDERS)

    -- The seeded match survived the sweep intact...
    local live = server.lobby.Get(matchId)
    t.isNotNil(live, 'the real match was destroyed by malformed payloads')
    t.isNotNil(live.players[1], 'the host was removed from their own match by the sweep')
    t.isNotNil(live.players[2], 'the second fighter was removed by the sweep')

    -- ...and a new legitimate request still works.
    --
    -- Opening a match rather than joining the seeded one: the sweep leaves
    -- player 3 holding a side-bet on it, and ArenaLobby.Join refuses a
    -- player a seat in a match they have money on. That refusal is correct
    -- and documented -- a bet whose holder can join and walk straight out
    -- again is a bet with no risk in it -- so demanding the join would be
    -- asserting a bug.
    server.env.source = 3
    server.netEvents['crimson_arena:server:createMatch']({
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    t.equals(#server.lobby.All(), 2,
        'a real player could not open a match after the fuzz sweep')
end)

os.exit(t.summary())
