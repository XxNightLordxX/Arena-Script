--[[
    crimson_arena/tests/hoursgate_spec.lua

    WHERE OPENING HOURS BITE, AND -- just as load-bearing -- WHERE THEY DO
    NOT. Exercised through the real server files, not through the rule.

    tests/schedule_spec.lua already proves the arithmetic: which minutes are
    open, when the next window is, what a wrap over midnight does. None of
    that says anything about whether the gate is wired to the right doors,
    and the wrong door here is expensive:

      Arena.CanStartMatch      goLive answers a refusal with ArenaMatch.Abort
                               and the countdown re-asks every second, so a
                               term there tears a round down mid-freeze and
                               strands a readied lobby the idle sweep cannot
                               collect -- it requires readyCount == 0 -- with
                               every stake escrowed for good.

      ArenaLobby.AddSpectator  server/match.lua calls it on EVERY elimination
                               to hand a knocked-out fighter their camera. A
                               refusal at the stroke of the hour stands them
                               back up, visible and unfrozen, in a live round.

      ArenaLobby.SetReady      readying is intent inside a lobby that is
                               allowed to exist while shut. The refusal a
                               ready room needs is Begin's, and the auto-start
                               already forwards it.

    So there are as many NEGATIVE assertions here as positive ones.

    HOW THE CLOCK IS PINNED. ArenaHoursOpen reads the SERVER's real clock, so
    a spec that hard-coded an hour would pass in the morning and fail in the
    afternoon. Every test here builds its windows RELATIVE to the hour it is
    actually running in -- openNow() and shutNow() below -- which is
    deterministic at any time of day.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('hoursgate_spec')

--- A window list that is open at whatever time this suite is running.
--- @return table
local function openNow()
    local hour = tonumber(os.date('*t').hour)
    -- The whole hour we are standing in. `to` is exclusive, so this is open
    -- for every minute of it and shut on the hour after.
    return { { from = hour, to = (hour + 1) % 24 } }
end

--- A window list that is SHUT at whatever time this suite is running.
--- @return table
local function shutNow()
    local hour = tonumber(os.date('*t').hour)
    -- Two hours ahead, so neither this hour nor the boundary minute of the
    -- next one is covered.
    return { { from = (hour + 2) % 24, to = (hour + 3) % 24 } }
end

--- Wallets and jobs for a set of server ids, in the shape
--- Sandbox.newQbxCore wants.
--- @param wallets table<integer, integer> -- [serverId] = starting cash
--- @param jobs table<integer, string>? -- [serverId] = job name; unemployed otherwise
--- @return table<integer, table>
local function roster(wallets, jobs)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = (jobs or {})[id] or 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- One whole arena server. Fresh per test: escrow, the match registry and
--- the snapshot cache are all module state, so two tests sharing an env
--- would share a pot.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)? -- applied before any file that reads config at LOAD time
--- @param jobs table<integer, string>?
--- @return table server
local function newArena(wallets, mutate, jobs)
    local qbx = Sandbox.newQbxCore(roster(wallets, jobs))
    local oxlib = Sandbox.newOxLib()
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents, handlers, commands = {}, {}, {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = oxlib,

        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,

        -- Captured, not silenced: half of what this file asserts is that a
        -- refusal or a forfeit is LOUD, and the console is where that lands.
        print = function(line) console[#console + 1] = line end,

        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        -- Well past every RATE bucket in main.lua on every call: this spec is
        -- about permissions and money, and a throttled event would look
        -- exactly like a refused one.
        GetGameTimer = function() clock = clock + 60000; return clock end,

        -- An id with no wallet is somebody who has left the server, which is
        -- how ArenaLobby.Broadcast prunes them.
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        -- Nobody holds an ACE here. Source 0 -- the server console -- is an
        -- admin without one, which is what the admin test leans on.
        IsPlayerAceAllowed = function() return false end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        -- The arena flag, and the routing bucket a round is fought in. Both
        -- ride the same two choke points in server/match.lua, so a stub
        -- missing either half fails as a nil call naming it.
        ArenaAmmo = {
            -- No-op double. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; here it only has to exist, because
            -- server/match.lua calls it at both arena choke points.
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- Before the loads below, not after: server/lobby.lua reads
    -- Config.Match.idleLobbyTimeoutSeconds once, at load, to decide whether
    -- its sweep thread is worth starting at all.
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env,
        qbx = qbx,
        config = env.Config,
        betting = env.ArenaBetting,
        lobby = env.ArenaLobby,
        match = env.ArenaMatch,
    }

    --- One client -> server event, as the client sends it.
    --- @param event string -- the tail of crimson_arena:server:*
    --- @param src integer
    --- @param data table?
    function server.fire(event, src, data)
        local name = 'crimson_arena:server:' .. event
        local handler = netEvents[name]
        if not handler then error('no handler registered for ' .. name, 2) end
        env.source = src
        handler(data)
    end

    --- A player losing their connection, through main.lua's own handler.
    --- @param src integer
    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    --- /arenaadmin from the server console, which always qualifies.
    --- @param ... string
    function server.adminCommand(...)
        commands['arenaadmin'](0, { ... })
    end

    --- Resumes every captured thread once. The sweeps call Wait first, so a
    --- full pass is two steps.
    function server.step()
        threads.step()
        threads.step()
    end

    --- @return integer
    function server.cash(id) return qbx.players[id].money.cash end

    --- @return integer
    function server.movements(id) return qbx.movements(id) end

    --- Every client event this server has pushed, in order.
    --- @return table[]
    function server.sent() return sent end

    --- The notify payloads sent to one player, oldest first.
    ---
    --- The KEY, not the rendered sentence: ArenaNotifyKey forwards a locale
    --- key and the sandbox's locale() hands it straight back, so asserting on
    --- the key is asserting on what the server actually chose to say.
    --- @param id integer
    --- @return string[]
    function server.notices(id)
        local out = {}
        for _, message in ipairs(sent) do
            if message.target == id and tostring(message.event):find('notify', 1, true) then
                out[#out + 1] = tostring(type(message.payload) == 'table'
                    and (message.payload.description or message.payload.key)
                    or message.payload)
            end
        end
        return out
    end

    --- Only what was said AFTER a mark taken with server.notices(id).
    --- Written because a whole-session search finds the join and the stake as
    --- readily as the thing under test.
    --- @param id integer
    --- @param mark integer
    --- @return string[]
    function server.noticesSince(id, mark)
        local all, out = server.notices(id), {}
        for index = mark + 1, #all do out[#out + 1] = all[index] end
        return out
    end

    return server
end

--- The server with opening hours switched ON and the given windows.
--- @param windows table
--- @param wallets table?
--- @return table
local function arenaWithHours(windows, wallets)
    return newArena(wallets or { [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Schedule = { enabled = true, windows = windows, offsetHours = 0 }
    end)
end

-- ======================================================================
-- THE TWO DOORS
-- ======================================================================

t.test('while the arena is OPEN, a match can be created and joined', function()
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isNotNil(id, 'an open arena refused a match')
    t.isTrue((s.lobby.Join(2, id, nil, nil)), 'an open arena refused a join')
end)

t.test('and while it is SHUT, creating one is refused by name', function()
    local s = arenaWithHours(shutNow())
    local id, reason = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isNil(id, 'a shut arena let a match be created')
    t.equals(reason, 'error.arena_shut')
end)

t.test('and the refused creation leaves NO half-built match behind', function()
    -- Create funnels its host through Join and unwinds on a refusal. A design
    -- that gated Create separately would leave the record standing.
    local s = arenaWithHours(shutNow())
    s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.equals(#s.lobby.All(), 0, 'a refused creation left a match in the registry')
end)

t.test('and joining an existing lobby is refused too', function()
    -- The lobby formed while the arena was open; the doors shut afterwards.
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isNotNil(id)

    s.config.Schedule.windows = shutNow()
    local ok, reason = s.lobby.Join(2, id, nil, nil)
    t.isFalse(ok, 'a shut arena let somebody join')
    t.equals(reason, 'error.arena_shut')
end)

t.test('and STARTING a lobby that formed while it was open is refused', function()
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isTrue((s.lobby.Join(2, id, nil, nil)))

    s.config.Schedule.windows = shutNow()
    local ok, reason = s.match.Begin(id, 1)
    t.isFalse(ok, 'a shut arena started a round')
    t.equals(reason, 'error.arena_shut')
    -- Refused ABOVE assignMissingTeams, so the roster is untouched.
    t.equals(s.lobby.Get(id).state, 'lobby', 'a refused Begin still moved the match on')
end)

-- ======================================================================
-- THE THREE DELIBERATE NON-PLACEMENTS
-- ======================================================================

t.test('readying up is NOT refused while shut', function()
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isTrue((s.lobby.Join(2, id, nil, nil)))

    s.config.Schedule.windows = shutNow()
    local ok = s.lobby.SetReady(1, true)
    t.isTrue(ok, 'a shut arena refused a player their own ready tick box')
end)

t.test('and a ready room is told WHY it is not starting', function()
    -- The auto-start branch forwards ArenaMatch.Begin's refusal key to every
    -- player in the roster, so the sentence a full lobby needs arrives
    -- through code that already exists rather than a second gate.
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isTrue((s.lobby.Join(2, id, nil, nil)))

    s.config.Schedule.windows = shutNow()
    local before = #s.notices(1)
    s.lobby.SetReady(1, true)
    s.lobby.SetReady(2, true)

    -- Compared against what the LOCALE resolves the key to, not against the
    -- key: ArenaNotifyKey renders before it sends, so asserting on the raw
    -- key would pass against a key that resolves to nothing at all.
    local wanted = s.env.locale('error.arena_shut')
    t.isTrue(wanted ~= nil and wanted ~= '' and wanted ~= 'error.arena_shut',
        'error.arena_shut does not resolve to a sentence')

    local said = false
    for _, notice in ipairs(s.noticesSince(1, before)) do
        if tostring(notice) == wanted then said = true end
    end
    t.isTrue(said, 'a full, readied lobby sat still and was told nothing')
end)

t.test('and WATCHING a live round is never refused by the clock', function()
    -- server/match.lua calls AddSpectator on every elimination. A refusal
    -- here is an eliminated fighter standing back up inside a live round.
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isTrue((s.lobby.Join(2, id, nil, nil)))
    t.isTrue((s.match.Begin(id, 1)))
    s.step()
    s.step()

    s.config.Schedule.windows = shutNow()
    local ok = s.lobby.AddSpectator(3, id)
    t.isTrue(ok, 'the clock refused a spectator a camera on a round already being fought')
end)

-- ======================================================================
-- THE BELL
-- ======================================================================

t.test('THE BELL: a waiting lobby is closed when the doors shut, and every stake goes back', function()
    local s = arenaWithHours(openNow(), { [1] = 5000, [2] = 5000, [3] = 5000 })
    s.config.Betting.enabled = true
    s.config.Betting.entryFee.enabled = true

    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 500, nil, nil, nil)
    t.isNotNil(id, 'the lobby could not be opened')
    t.isTrue((s.lobby.Join(2, id, nil, nil)))

    local staked = s.cash(1) + s.cash(2)
    t.isTrue(staked < 10000, 'no stake was taken, so this test proves nothing about refunds')

    -- One sweep to record the doors as open, then shut them and sweep again.
    s.step()
    s.config.Schedule.windows = shutNow()
    s.step()

    t.equals(#s.lobby.All(), 0, 'the bell left a lobby standing that could never start')
    t.equals(s.cash(1) + s.cash(2), 10000, 'the bell closed a lobby without giving the stakes back')
end)

t.test('and a round already being fought is left alone', function()
    local s = arenaWithHours(openNow())
    local id = s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil)
    t.isTrue((s.lobby.Join(2, id, nil, nil)))
    t.isTrue((s.match.Begin(id, 1)))
    s.step()
    s.step()

    s.step()
    s.config.Schedule.windows = shutNow()
    s.step()

    -- Widening the bell's filter from == 'lobby' to ~= 'ended' is the
    -- mutation this kills, and it is the one that aborts live rounds.
    t.isNotNil(s.lobby.Get(id), 'the bell tore down a round that was already being fought')
end)

-- ======================================================================
-- THE FAIL-OPEN RULE
-- ======================================================================

t.test('THE UPGRADE RULE: no Config.Schedule at all leaves every door open', function()
    -- A server that pulls this code before its config has the block must
    -- keep an arena that works. This single assertion is why the rest of the
    -- suite is green: reverse it and every existing install goes dark.
    local s = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Schedule = nil
    end)
    t.isNotNil(s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil),
        'a server with no Config.Schedule had its arena shut')
end)

t.test('and so does the switch being off, whatever the windows say', function()
    local s = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Schedule = { enabled = false, windows = shutNow(), offsetHours = 0 }
    end)
    t.isNotNil(s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil),
        'enabled = false still shut the arena')
end)

t.test('and a rule that answers with nothing at all', function()
    -- The direction the guard fails in, asserted rather than assumed.
    -- Arena.ScheduleStatus sets `open` on every path it has today, so this
    -- is the only way to reach the branch -- and the branch is the reason
    -- the arena cannot be taken offline for everybody by a shape change.
    local s = newArena({ [1] = 5000 }, function(config)
        config.Schedule = { enabled = true, windows = shutNow(), offsetHours = 0 }
    end)
    t.isFalse(s.env.ArenaHoursOpen(), 'the setup did not actually shut the arena')

    s.env.Arena.ScheduleStatus = function() return nil end
    t.isTrue(s.env.ArenaHoursOpen(),
        'a rule that answered with nothing shut the arena instead of leaving it open')

    s.env.Arena.ScheduleStatus = function() return {} end
    t.isTrue(s.env.ArenaHoursOpen(),
        'a rule that answered with no verdict shut the arena instead of leaving it open')
end)

t.test('and a window list where nothing is usable', function()
    local s = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Schedule = { enabled = true, offsetHours = 0, windows = {
            { from = 99, to = 3 }, { from = 5, to = 5 },
        } }
    end)
    t.isNotNil(s.lobby.Create(1, 'trailerpark', s.config.DefaultMode, 0, nil, nil, nil),
        'a schedule with no usable window shut the arena instead of leaving it open')
end)

-- ======================================================================
-- THE OFFSET
-- ======================================================================

t.test('offsetHours moves the hour the schedule is judged against', function()
    local s = newArena({ [1] = 5000 }, function(config)
        config.Schedule = { enabled = true, windows = openNow(), offsetHours = 0 }
    end)
    t.isTrue(s.env.ArenaHoursOpen(), 'the arena was shut inside its own window')

    -- Five hours out of step, so the window this hour is no longer this hour.
    s.config.Schedule.offsetHours = 5
    t.isFalse(s.env.ArenaHoursOpen(), 'offsetHours changed nothing')
end)

t.test('and an offset outside the band is ignored rather than honoured', function()
    local s = newArena({ [1] = 5000 }, function(config)
        config.Schedule = { enabled = true, windows = openNow(), offsetHours = 500 }
    end)
    -- Silently honouring 500 would put the arena's day somewhere nobody
    -- asked for. The validator has already named it.
    t.isTrue(s.env.ArenaHoursOpen(), 'a nonsense offsetHours was applied instead of ignored')
end)

-- ======================================================================
-- THE WIRE
-- ======================================================================

t.test('the schedule reaches the panel on BOTH payloads', function()
    -- keepOut was missing from Broadcast for its whole life and the fence was
    -- dead in production as a result: it worked on a panel opening and was
    -- gone one broadcast later. Both payloads are assembled by hand, so both
    -- are asserted.
    local s = arenaWithHours(openNow())

    local built = s.lobby.BuildState(1)
    t.isNotNil(built.schedule, 'BuildState sent no schedule block')
    t.isTrue(built.schedule.open, 'BuildState reported an open arena as shut')
    t.isNotNil(built.schedule.line, 'BuildState sent no window line while hours are enforced')

    local seen = nil
    s.lobby.MarkPanelOpen(1)
    s.lobby.Broadcast()
    for _, message in ipairs(s.sent()) do
        if message.event == 'crimson_arena:client:state' and message.target == 1 then
            seen = message.payload.schedule
        end
    end
    t.isNotNil(seen, 'Broadcast sent no schedule block')
    t.equals(tostring(seen.open), tostring(built.schedule.open),
        'the two payloads disagree about the same instant')
end)

t.test('and carries NO window line when hours are not being enforced', function()
    -- The panel must never advertise a schedule the server is not keeping.
    local s = newArena({ [1] = 5000 }, function(config) config.Schedule = nil end)
    local built = s.lobby.BuildState(1)
    t.isTrue(built.schedule.open)
    t.isNil(built.schedule.line, 'a server keeping no hours advertised a schedule')
end)

os.exit(t.summary())
