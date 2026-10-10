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
            -- INSIDE THE ARENA THESE FIGHTERS ARE SUPPOSED TO BE IN, which
            -- this used to be nowhere near: it answered a point 1,450m from
            -- the Trailer Park, so every fighter in every one of these specs
            -- was standing well outside the fence they were fighting inside.
            -- Nothing read it until Config.Match.serverChecks did, and then
            -- it read as the whole roster having walked out of the round.
            --
            -- Spread three metres apart, so they are also close enough for
            -- the kill-distance ceiling -- the other thing that reads this.
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
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
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function() return true end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
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

    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/betting.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/lobby.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/match.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/main.lua', env)

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

-- ========================================================================
-- AND THE LOBBY IS NAMED AFTER WHOEVER IS HOSTING IT NOW
-- ========================================================================

t.test('DEFECT: the title follows the host when the first one walks out', function()
    -- `label` is built from the host's name at creation and was written in
    -- only two places in the file -- creation, and the host pressing Apply.
    -- The handoff moved hostSource and hostName and left the heading alone,
    -- so a lobby kept the departed host's name in its title while the line
    -- underneath it named the player who had actually inherited it. That
    -- heading is what a stranger reads on the Matches tab before joining.
    local s, matchId = lobbyOfTwo()

    local before = s.lobby.Get(matchId).label
    t.isNotNil(before, 'the match was created without a title')

    t.isTrue(s.lobby.Leave(1, 'left'), 'the host could not leave')

    local match = s.lobby.Get(matchId)
    t.isNotNil(match, 'the match died when the host left')
    t.isNotNil(match.label, 'the handoff cleared the title instead of rewriting it')
    t.isTrue(match.label:find(match.hostName, 1, true) ~= nil,
        'THE TITLE STILL NAMES THE HOST WHO LEFT: "' .. tostring(match.label)
            .. '" while the host is ' .. tostring(match.hostName))
    t.isTrue(match.label ~= before, 'the title did not change at all')
end)

t.test('and a lobby whose host stays keeps the title it was made with', function()
    local s, matchId = lobbyOfTwo()
    local before = s.lobby.Get(matchId).label
    t.isTrue(s.lobby.Leave(2, 'left'), 'the guest could not leave')
    t.equals(s.lobby.Get(matchId).label, before,
        'a guest leaving rewrote the title')
end)

-- ========================================================================
-- A START THAT DOES NOT HAPPEN LEAVES THE ROSTER ALONE
--
-- ArenaMatch.Begin auto-places anybody who has not picked a side, so the
-- smallest team is smallest WHEN THE FIGHTING STARTS rather than when the
-- first player wandered in. That is right, and it ran before two gates that
-- can still turn the start down -- so a start that never happened committed
-- players to sides they never chose.
--
-- Not merely cosmetic. The placement SHAPES THE NEXT ATTEMPT: a host frozen
-- onto a side is a side the second player can then join, and a lobby that
-- would have begun as a 1v1 -- the host auto-placed onto the empty side --
-- is refused 'error.need_two_teams' instead.
--
-- Begin's other refusals already say in their own comments that a refusal
-- must leave the roster exactly as it found it. These two did not.
-- ========================================================================

--- A team-deathmatch lobby with `count` fighters in it, none of whom has
--- picked a side.
local function tdmLobby(count, mutate)
    local s = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 }, mutate)
    local matchId, err = s.lobby.Create(1, anArena(s), 'tdm', nil, nil, nil, nil)
    t.isNotNil(matchId, 'the team match could not be created: ' .. tostring(err))
    for src = 2, count do
        t.isTrue(s.lobby.Join(src, matchId, nil, nil),
            ('fighter %d could not join'):format(src))
    end

    local match = s.lobby.Get(matchId)
    for _, player in pairs(match.players) do player.team = nil end

    s.admins = {}
    s.env.ArenaIsAdmin = function(src) return s.admins[src] == true end
    return s, matchId
end

t.test('THE DEFECT: a start refused for too few players leaves nobody on a side', function()
    -- The host presses "Start Match Now" before the second player arrives.
    -- They never touched the team picker.
    local s, matchId = tdmLobby(1)

    local ok, reason = s.match.Begin(matchId, 1)
    t.isFalse(ok, 'a one-player team match started')
    t.equals(reason, 'error.not_enough_players')

    t.isNil(s.lobby.Get(matchId).players[1].team,
        'A REFUSED START PUT THE HOST ON A SIDE THEY NEVER CHOSE')
    t.isNil(s.rowFor(1, 1).team, 'and the panel was shown it')
end)

t.test('and neither does one refused because the arena is already in use', function()
    -- The auto-start path reaches this with no client-side gate in front of
    -- it: two players tick Ready, Begin fires, the arena is busy.
    local s, matchId = tdmLobby(2)

    -- A second lobby holding the same ground, live.
    local other = s.lobby.Create(3, anArena(s), 'tdm', nil, nil, nil, nil)
    t.isNotNil(other, 'the second lobby could not be created')
    s.lobby.Get(other).state = 'live'

    local ok, reason = s.match.Begin(matchId, 1)
    t.isFalse(ok, 'a match started on ground another round is being fought on')
    t.equals(reason, 'error.arena_in_use')

    local match = s.lobby.Get(matchId)
    t.isNil(match.players[1].team, 'A REFUSED START PUT THE HOST ON A SIDE')
    t.isNil(match.players[2].team, 'and the guest with them')
end)

t.test('CONTROL: a start that DOES happen still places everybody', function()
    -- Without this the two above pass just as well against a Begin that
    -- never assigns anybody, which would break the rule they are guarding.
    local s, matchId = tdmLobby(2)

    local ok, reason = s.match.Begin(matchId, 1)
    t.isTrue(ok, 'a startable team match was refused: ' .. tostring(reason))

    local match = s.lobby.Get(matchId)
    t.isNotNil(match.players[1].team, 'a started team match left the host with no side')
    t.isNotNil(match.players[2].team, 'and the guest with none either')
    t.isTrue(match.players[1].team ~= match.players[2].team,
        'both fighters were put on the same side of a two-player team match')
end)

t.test('and a side somebody CHOSE is never taken off them by a refusal', function()
    -- The rollback undoes this call's own placements and nothing else.
    local s, matchId = tdmLobby(1)
    local chosen = s.env.Arena.GetEnabledTeams()[2].key
    s.lobby.Get(matchId).players[1].team = chosen

    t.isFalse(s.match.Begin(matchId, 1), 'a one-player team match started')
    t.equals(s.lobby.Get(matchId).players[1].team, chosen,
        'a refused start wiped a side the player had picked themselves')
end)

-- ========================================================================
-- WHO FOUGHT IT, WRITTEN DOWN AT GO-LIVE
--
-- ArenaStats reads `match.players` at the END of a round, and ArenaLobby.Leave
-- takes a quitter out of it -- so the roster the leaderboard would otherwise
-- judge is "whoever was still standing". A real three-way one player rage-quit
-- would reach the board as a two-man duel, and a farm could rotate who walks
-- out to keep changing the set the repeat rule keys on.
--
-- goLive writes the answer down while it is still settled: nobody else can
-- join from there.
--
-- NOTHING WAS HOLDING THIS. Deleting the whole write left all 122 spec files
-- passing -- rankedboard_spec and recordmatch_spec hand RecordMatch a match
-- table with the list already filled in, and every spec that drives a real
-- goLive stubs ArenaStats out. So the field the rule depends on was written
-- by code no test ran.
-- ========================================================================

--- A team lobby that goes live the moment everybody is ready, with no
--- countdown to step through.
local function liveTeamRound(count, seats)
    local s = newArena(seats or { [1] = 5000, [2] = 5000, [3] = 5000 }, function(config)
        config.Match.lobbyCountdownSeconds = 0
        config.Match.startCountdownSeconds = 0
        config.Teams.autoAssignIfUnchosen = true
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
    end)
    local matchId, err = s.lobby.Create(1, anArena(s), 'tdm', nil, nil, nil, nil)
    t.isNotNil(matchId, 'the team match could not be created: ' .. tostring(err))
    for src = 2, count do
        t.isTrue(s.lobby.Join(src, matchId, nil, nil), ('fighter %d could not join'):format(src))
    end

    local ok, why = s.match.Begin(matchId, 1)
    t.isTrue(ok, 'the round would not begin: ' .. tostring(why))

    -- JUST FAR ENOUGH TO GO LIVE. This fixture answers GetEntityCoords with
    -- the Trailer Park, and anArena() hands back whichever arena ships first
    -- -- so keep stepping and Config.Match.serverChecks reads the whole
    -- roster as having walked a kilometre out of the fence and closes the
    -- round. One step is the countdown thread; the rest is the fence.
    s.step()

    local match = s.lobby.Get(matchId)
    t.equals(match.state, 'live', 'the round never went live')
    return s, matchId, match
end

t.test('going live writes down who fought it, by character', function()
    local s, matchId, match = liveTeamRound(3)

    t.equals(type(match.contestantIds), 'table',
        'nothing was written down at go-live at all')
    t.equals(table.concat(match.contestantIds, ','), 'CID001,CID002,CID003',
        'the go-live roster was recorded as ' .. table.concat(match.contestantIds or {}, ','))
end)

t.test('and a quitter does not take themselves out of it', function()
    -- THE WHOLE REASON THE FIELD EXISTS. match.players loses them; this does
    -- not, so the two who stayed keep a real three-way result.
    local s, matchId, match = liveTeamRound(3)

    s.lobby.Leave(3, 'match.left', false)

    t.isNil(match.players[3], 'the quitter is still on the roster, so this proves nothing')
    t.equals(table.concat(match.contestantIds, ','), 'CID001,CID002,CID003',
        'THE QUITTER WAS ERASED FROM THE ROUND THEY FOUGHT IN')
end)

t.test('and two logins on one character are one fighter', function()
    -- The smallest farm there is. Counted by citizen id at the moment it is
    -- written, not left to the reader to notice.
    local s, matchId, match = liveTeamRound(3, {
        [1] = 5000, [2] = 5000, [3] = 5000,
    })
    -- Two of the three seats are the same character.
    t.equals(#match.contestantIds, 3, 'three distinct characters did not produce three ids')

    local again = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Match.lobbyCountdownSeconds = 0
        config.Match.startCountdownSeconds = 0
        config.Teams.autoAssignIfUnchosen = true
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
    end)
    again.qbx.players[2].citizenid = again.qbx.players[1].citizenid
    local id = again.lobby.Create(1, anArena(again), 'tdm', nil, nil, nil, nil)
    again.lobby.Join(2, id, nil, nil)
    again.match.Begin(id, 1)
    again.step()

    local m = again.lobby.Get(id)
    t.equals(#m.contestantIds, 1,
        'one character logged in twice was written down as two fighters')
end)

-- ========================================================================
-- AND A RULES REWRITE DOES NOT MINT A ROW SetReady WOULD REFUSE
-- ========================================================================

--- A lobby a host can actually rewrite: no stake to lock the rules behind,
--- and no auto-start to run the round out from under the test.
--- @param autoAssign boolean
local function editableLobby(autoAssign)
    return lobbyOfTwo(function(config)
        config.Teams.autoAssignIfUnchosen = autoAssign
        -- ArenaLobby.UpdateMatch refuses a mode change once money is riding
        -- on the result -- 'error.rules_locked_by_stakes' -- which is its own
        -- rule and not the one under test here.
        config.Betting.enabled = false
        config.Betting.entryFee.enabled = false
        -- And two ticked boxes would otherwise START the round, which makes
        -- every assertion below 'error.match_in_progress'.
        config.Match.autoStartWhenAllReady = false
    end)
end

t.test('THE DEFECT: switching a readied FFA lobby to teams unticks the host too', function()
    -- SetReady refuses 'error.pick_a_team' to anybody ticking Ready in a
    -- team mode with no side, while autoAssignIfUnchosen is off. Changing the
    -- mode wipes teams and deliberately keeps the HOST's tick -- they wrote
    -- the change, they know what it is -- which produced exactly the row
    -- SetReady will not mint.
    --
    -- What it cost: the guest picks a side and readies, the auto-start fires,
    -- Begin refuses 'error.no_team_chosen', and BOTH players are told
    -- somebody has not picked a side -- while the one player who has to act
    -- is the one whose roster row says they are done.
    local s, matchId = editableLobby(false)

    t.isTrue(s.lobby.SetReady(1, true), 'the host could not ready up in a free-for-all')
    t.isTrue(s.lobby.Get(matchId).players[1].ready, 'the tick did not stick')

    local ok, reason = s.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm' })
    t.isTrue(ok, 'the mode could not be changed: ' .. tostring(reason))

    local match = s.lobby.Get(matchId)
    t.isNil(match.players[1].team, 'the mode change did not wipe the sides')
    t.isFalse(match.players[1].ready == true,
        'THE HOST IS READY IN A TEAM MODE WITH NO SIDE -- a row SetReady refuses to mint')

    -- AND THEY CAN GET BACK TO IT THE ORDINARY WAY.
    local retick, why = s.lobby.SetReady(1, true)
    t.isFalse(retick, 'SetReady accepted the very row this test says it refuses')
    t.equals(why, 'error.pick_a_team', 'and it refused for the wrong reason')
end)

t.test('and with auto-assignment ON the host keeps their tick, as the rule says', function()
    -- The exemption is deliberate and is not being taken away. On the shipped
    -- config Begin places them, so the row is one they could have reached.
    local s, matchId = editableLobby(true)

    t.isTrue(s.lobby.SetReady(1, true), 'the host could not ready up')
    t.isTrue(s.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm' }))

    t.isTrue(s.lobby.Get(matchId).players[1].ready,
        'the host lost a tick the rule says they keep')
end)

t.test('and a lives-only edit IN A TEAM MODE leaves the host ticked', function()
    -- THE NARROW ONE, and a mutation sample found it: writing `needsSide =
    -- ruleChanged` instead of `teamsChanged` passed every test there was.
    -- The two differ only here -- an edit that changes a rule WITHOUT
    -- changing the mode, in a mode that already uses teams.
    --
    -- Nothing has been wiped: the host still holds the side they picked, and
    -- SetReady would take their tick right now. Clearing it would be the
    -- server unticking a box for no reason the player can see.
    local s, matchId = editableLobby(false)

    t.isTrue(s.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm' }),
        'the lobby could not be made a team match')

    local sides = s.env.Arena.GetEnabledTeams()
    t.isTrue(s.lobby.SetTeam(1, sides[1].key), 'the host could not pick a side')
    t.isTrue(s.lobby.SetTeam(2, sides[2].key), 'the guest could not pick a side')
    t.isTrue(s.lobby.SetReady(1, true), 'the host could not ready up in the team match')

    -- A lives-only edit. The mode does not move, so no side is wiped.
    t.isTrue(s.lobby.UpdateMatch(1, { matchId = matchId, modeKey = 'tdm', lives = 5 }),
        'the lives could not be changed')

    local match = s.lobby.Get(matchId)
    t.equals(match.players[1].team, sides[1].key,
        'a lives-only edit wiped the host\'s side')
    t.isTrue(match.players[1].ready,
        'THE HOST WAS UNTICKED BY AN EDIT THAT TOOK NOTHING AWAY FROM THEM')
end)

t.test('and a rewrite that changes no mode leaves every tick alone', function()
    local s, matchId = editableLobby(false)

    t.isTrue(s.lobby.SetReady(1, true))
    t.isTrue(s.lobby.SetReady(2, true))
    t.isTrue(s.lobby.UpdateMatch(1, { matchId = matchId, lives = 2 }))

    local match = s.lobby.Get(matchId)
    t.isTrue(match.players[1].ready, 'a lives change unticked the host')
end)

os.exit(t.summary())
