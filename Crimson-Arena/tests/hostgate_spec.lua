--[[
    crimson_arena/tests/hostgate_spec.lua

    WHO MAY START A MATCH.

    ArenaMatch.Begin is the one place that decides it, and the decision has
    three parts that a mutation sample of server/match.lua found untested
    together: whether the asker is the host, whether the operator has
    allowed anyone else to start, and -- when they have -- whether the asker
    is even IN the lobby they are starting.

    THAT LAST ONE IS THE INTERESTING ONE. With onlyHostCanStart off, "anyone
    may start it" means anyone in it. Without the second check, a player
    standing anywhere else on the server can start somebody else's round
    from the match browser -- putting a lobby of people into an arena
    before they were ready, from outside it.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- The real server/lobby.lua with the framework and the arena's own
--- neighbours modelled. Same shape as lobbyrules_spec's fixture, kept
--- separate so this file cannot break that one.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)?
--- @return table server
local function newArena(wallets, mutate)
    local qbx = Sandbox.newQbxCore(roster(wallets))
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents = {}, {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- Well past every rate bucket on every call: this file is about
        -- lobby rules, and a throttled event looks exactly like a refused one.
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
        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env, qbx = qbx, config = env.Config,
        lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting,
    }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.step() threads.step(); threads.step() end
    function server.log() return table.concat(console, '\n') end

    --- The snapshot this player would be sent, as the panel receives it.
    function server.state(src) return server.lobby.BuildState(src) end

    --- The one match in `matches`, or nil.
    function server.onlyMatch(src)
        local matches = server.state(src).matches or {}
        return matches[1]
    end

    --- One player's row inside that match, by server id.
    function server.rowFor(src, target)
        for _, player in ipairs((server.onlyMatch(src) or {}).players or {}) do
            if player.id == target then return player end
        end
        return nil
    end

    return server
end


--- The key of the first arena this config ships enabled.
local function anArena(s)
    local arenas = s.env.Arena.GetEnabledArenas()
    t.isTrue(#arenas > 0, 'the config under test ships no enabled arena')
    return arenas[1].key
end

--- A lobby with a host (1), a guest (2) and an outsider (3) on the server
--- but not in it.
--- @return table server, string matchId
local function lobbyOfTwo(mutate)
    local s = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, mutate)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, nil, nil, nil, nil)
    t.isNotNil(matchId, 'the match could not be created: ' .. tostring(err))
    t.isTrue(s.lobby.Join(2, matchId, nil, nil), 'the guest could not join')

    -- Nobody is an admin unless a test says so. ArenaIsAdmin is the one
    -- door past every rule below, so it has to be shut by default or the
    -- rules are untestable.
    s.admins = {}
    s.env.ArenaIsAdmin = function(src) return s.admins[src] == true end

    return s, matchId
end

-- ========================================================================
-- THE SHIPPED RULE: THE HOST, AND NOBODY ELSE
-- ========================================================================

t.test('the host may start their own match', function()
    local s, matchId = lobbyOfTwo()

    local ok, err = s.match.Begin(matchId, 1)

    t.isTrue(ok, 'the host could not start their own match: ' .. tostring(err))
end)

t.test('and a guest in the same lobby may not', function()
    -- The control for every test below: without it, "the host may start"
    -- passes against a gate that lets everybody through.
    local s, matchId = lobbyOfTwo()

    local ok, err = s.match.Begin(matchId, 2)

    t.isFalse(ok, 'a guest started the host\'s match')
    t.equals(err, 'error.not_host')
end)

t.test('and neither may somebody who is not in it at all', function()
    local s, matchId = lobbyOfTwo()

    local ok = s.match.Begin(matchId, 3)

    t.isFalse(ok, 'a player elsewhere on the server started somebody else\'s match')
end)

-- ========================================================================
-- WITH THE OPERATOR'S RULE RELAXED
-- ========================================================================

t.test('with onlyHostCanStart off, a guest IN the lobby may start it', function()
    local s, matchId = lobbyOfTwo(function(config)
        config.Match.onlyHostCanStart = false
    end)

    local ok, err = s.match.Begin(matchId, 2)

    t.isTrue(ok, 'a guest could not start a match the operator opened up: ' .. tostring(err))
end)

t.test('but somebody NOT in it still may not', function()
    -- THE ASSERTION THIS FILE EXISTS FOR. "Anyone may start it" means
    -- anyone IN it. Without the second check a player standing anywhere
    -- else on the server can start a lobby of people into an arena from
    -- the match browser, before they were ready.
    local s, matchId = lobbyOfTwo(function(config)
        config.Match.onlyHostCanStart = false
    end)

    local ok, err = s.match.Begin(matchId, 3)

    t.isFalse(ok, 'an outsider started a match they were not standing in')
    t.equals(err, 'error.not_in_match')
end)

-- ========================================================================
-- THE DOOR PAST BOTH
-- ========================================================================

t.test('an admin may start any match, in either configuration', function()
    for _, onlyHost in ipairs({ true, false }) do
        local s, matchId = lobbyOfTwo(function(config)
            config.Match.onlyHostCanStart = onlyHost
        end)
        s.admins[3] = true

        local ok, err = s.match.Begin(matchId, 3)

        t.isTrue(ok, ('an admin could not start a match with onlyHostCanStart = %s: %s')
            :format(tostring(onlyHost), tostring(err)))
    end
end)

t.test('and the server console asks for nobody\'s permission', function()
    -- requestedBy nil is the console and the resource's own paths. There
    -- is nobody to check, and checking anyway would stop the arena
    -- starting its own matches.
    local s, matchId = lobbyOfTwo()

    t.isTrue(s.match.Begin(matchId, nil), 'the server itself could not start a match')
end)

-- ========================================================================
-- AND ONLY A MATCH THAT HAS NOT STARTED
-- ========================================================================

t.test('a match already under way cannot be started again', function()
    -- Begin is reachable from the panel, and a second press mid-countdown
    -- would re-run the placement on players already standing in the arena.
    local s, matchId = lobbyOfTwo()
    t.isTrue(s.match.Begin(matchId, 1))

    local ok, err = s.match.Begin(matchId, 1)

    t.isFalse(ok, 'a match already started was started a second time')
    t.equals(err, 'error.match_already_started')
end)

t.test('and a match that does not exist is refused rather than raising', function()
    local s = newArena({ [1] = 5000 })

    for _, bad in ipairs({ 'no-such-match', '', 42 }) do
        local ok, err = s.match.Begin(bad, 1)
        t.isFalse(ok, ('%s was accepted as a match to start'):format(tostring(bad)))
        t.equals(err, 'error.match_not_found')
    end
end)

os.exit(t.summary())
