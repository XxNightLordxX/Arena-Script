--[[
    crimson_arena/tests/lobbystate_spec.lua

    THE SNAPSHOT, AND THE HOST CONTROLS THAT CHANGE IT.

    server/lobby.lua builds the object every panel on the server renders
    itself from. lobbyrules_spec covers the RULES -- who may create, who
    may join, what the entry fee does, what a forfeit costs. This file
    covers what the snapshot SAYS afterwards, and the four host actions
    that edit a lobby in place.

    A mutation sample found thirty survivors, and the ones worth having
    are all of the same kind: a boolean that the panel renders directly.

      ready = player ~= nil and player.ready == true

    Flip that `true` and every player in every lobby is reported as the
    opposite of what they are: the ready column inverts, the "2 / 4 ready"
    line inverts with it, and the host is looking at a screen that
    disagrees with the button every one of them just pressed. Nothing
    raises, nothing is logged, and the match still starts on the server's
    own count -- which is read from the same field the panel is being lied
    about.

    The host actions are the other half. Stop The Countdown, Set Team,
    Set Ready and the match edit each guard on the match's STATE, and
    every one of those guards had a surviving mutant: a countdown that can
    be held after it has already started, a team switch mid-round, a
    capacity check that counts a player against a cap they are already
    inside.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Players with a wallet, keyed by server id.
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
---
--- Asked for rather than written down: which arenas ship enabled is the
--- operator's choice and it changes, and a spec that hardcodes one goes
--- red the day somebody switches it off for a reason that has nothing to
--- do with lobbies.
local function anArena(s)
    local arenas = s.env.Arena.GetEnabledArenas()
    t.isTrue(#arenas > 0, 'the config under test ships no enabled arena')
    return arenas[1].key
end

--- The commonest starting point: two players in one lobby, host first.
---
--- Create returns the MATCH ID, not a boolean -- nil is the refusal -- and
--- Join returns ok plus a reason. Reading either the other way round is a
--- test that passes on a lobby that was never made.
--- @return table server, string matchId
local function twoInLobby(mutate)
    local s = newArena({ [1] = 5000, [2] = 5000 }, mutate)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, nil, nil, nil, nil)
    t.isNotNil(matchId, 'the host could not create a match: ' .. tostring(err))
    t.isTrue(s.lobby.Join(2, matchId, nil, nil), 'the second player could not join')
    return s, matchId
end

-- ========================================================================
-- WHAT THE SNAPSHOT SAYS ABOUT READY
-- ========================================================================

t.test('a player who has not readied up is reported as not ready', function()
    local s = twoInLobby()

    t.equals(s.state(1).player.ready, false, 'a fresh player is reported READY')
    t.equals(s.rowFor(1, 1).ready, false, 'a fresh player\'s row says they are ready')
end)

t.test('and one who HAS is reported as ready', function()
    -- Both directions. Either assertion alone passes against a snapshot
    -- that hardcodes its answer, and hardcoding it is the whole failure:
    -- always-ready starts rounds nobody agreed to, always-not-ready means
    -- no round ever starts.
    local s = twoInLobby()

    t.isTrue(s.lobby.SetReady(1, true), 'the player could not ready up')

    t.equals(s.state(1).player.ready, true, 'a player who readied up is reported as not ready')
    t.equals(s.rowFor(1, 1).ready, true, 'their row in the lobby still says not ready')
end)

t.test('and un-readying puts it back', function()
    local s = twoInLobby()
    s.lobby.SetReady(1, true)

    t.isTrue(s.lobby.SetReady(1, false))

    t.equals(s.state(1).player.ready, false, 'a player who un-readied is still reported ready')
end)

t.test('one player readying does not report the OTHER as ready', function()
    -- The row is built per player. Read off the wrong one and the host
    -- sees a lobby that is ready to go when half of it has not pressed
    -- anything.
    local s = twoInLobby()

    s.lobby.SetReady(1, true)

    t.equals(s.rowFor(1, 1).ready, true)
    t.equals(s.rowFor(1, 2).ready, false, 'one player readying marked everybody ready')
end)

t.test('a player is reported ALIVE while they still have lives', function()
    -- `alive` is not "in a live round" -- it is "not out". A fighter
    -- sitting in the lobby has every life they were given, and the
    -- results board ranks off the same field, so reporting them out
    -- before a shot is fired would rank them last.
    local s = twoInLobby()

    t.equals(s.rowFor(1, 1).alive, true, 'a player who has lost nothing is reported as out')
    t.equals(s.rowFor(1, 2).alive, true)
end)

-- ========================================================================
-- WHO THE HOST IS
-- ========================================================================

t.test('the host is marked as the host, and nobody else is', function()
    local s = twoInLobby()

    t.equals(s.state(1).player.isHost, true, 'the host is not told they are the host')
    t.equals(s.state(2).player.isHost, false, 'a guest was told they are the host')
    t.equals(s.rowFor(1, 1).isHost, true, 'the host\'s row does not mark them')
    t.equals(s.rowFor(1, 2).isHost, false, 'a guest\'s row marks them as host')
end)

t.test('and the snapshot names the match each player is in', function()
    local s, matchId = twoInLobby()

    t.equals(s.state(1).player.matchId, matchId)
    t.equals(s.state(2).player.matchId, matchId)

    local outsider = newArena({ [3] = 100 })
    t.equals(outsider.state(3).player.matchId, false,
        'a player in no match was told they are in one')
end)

-- ========================================================================
-- STOP THE COUNTDOWN
-- ========================================================================

t.test('the countdown can only be held while one is actually running', function()
    -- Holding a countdown that is not running would report success for
    -- doing nothing, and the button that posts it is on screen whenever
    -- the host is in a lobby.
    local s = twoInLobby()

    local ok, err = s.lobby.HoldCountdown(1)

    t.isFalse(ok, 'the countdown was "held" in a lobby that had not started one')
    t.isNotNil(err, 'holding nothing was refused without saying why')
end)

t.test('and holding a running one keeps everybody in place', function()
    -- THE DEFECT THIS REPLACED. Stop The Countdown used to post
    -- cancelMatch, which destroyed the lobby and -- with refundOnCancel
    -- off -- burned the pot, while the tooltip promised the opposite.
    local s, matchId = twoInLobby()
    s.lobby.SetReady(1, true)
    s.lobby.SetReady(2, true)
    -- BY MATCH ID, not by source. Start is a match-layer call and takes
    -- the lobby it is starting; handing it a server id starts nothing and
    -- reports a match that does not exist.
    local started, why = s.match.Start(matchId)
    t.isTrue(started, 'the match never started counting down: ' .. tostring(why))

    local ok = s.lobby.HoldCountdown(1)

    t.isTrue(ok, 'a running countdown could not be held')
    local match = s.onlyMatch(1)
    t.isNotNil(match, 'holding the countdown destroyed the lobby')
    t.equals(#match.players, 2, 'holding the countdown emptied the lobby')
end)

-- ========================================================================
-- SWITCHING TEAMS
-- ========================================================================

--- Two players in a lobby playing a mode that has sides.
local function inTeamMode()
    local s = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        for _, mode in pairs(config.Modes) do
            if mode.teams == true then mode.enabled = true end
        end
    end)
    local teamMode
    for key, mode in pairs(s.config.Modes) do
        if mode.teams == true and mode.enabled ~= false then teamMode = key break end
    end
    t.isNotNil(teamMode, 'the shipped config has no team mode to test with')
    local matchId, err = s.lobby.Create(1, anArena(s), teamMode, nil, nil, nil, nil)
    t.isNotNil(matchId, 'no team-mode match could be created: ' .. tostring(err))
    s.lobby.Join(2, matchId, nil, nil)
    return s, matchId
end

t.test('a team key that is not a real team is refused', function()
    -- Sending nothing is the panel's "I have not picked". Sending a key
    -- that is not a live team is a stale panel or a forged payload.
    local s = inTeamMode()

    local ok, err = s.lobby.SetTeam(1, 'not_a_team')

    t.isFalse(ok, 'a made-up team key was accepted')
    t.isNotNil(err, 'a made-up team key was refused without saying why')
end)

t.test('and NO team key at all is refused rather than treated as "unpick me"', function()
    -- A different guard from the one above: 'not_a_team' IS a key, and is
    -- refused further down for naming no live team. This one is reached
    -- only by a MISSING key -- and clearing a side is not something the
    -- panel offers. Treated as "unpick me", a player could dodge a full
    -- team by emptying their own.
    local s = inTeamMode()
    local key = s.state(1).config.teams.list[1].key
    s.lobby.SetTeam(1, key)

    for _, bad in ipairs({ '', 42, {}, true }) do
        local ok = s.lobby.SetTeam(1, bad)
        t.isFalse(ok, ('%s was accepted as a team to switch to'):format(tostring(bad)))
    end
    t.isFalse(s.lobby.SetTeam(1, nil), 'sending no team at all cleared the player\'s side')

    t.equals(s.state(1).player.team, key, 'a refused switch still changed the player\'s side')
end)

t.test('and a real one is taken', function()
    local s = inTeamMode()
    -- The team LIST lives in config; `match.teams` is a boolean saying
    -- whether this mode has sides at all.
    local teams = s.state(1).config.teams.list
    t.isTrue(#teams > 0, 'the shipped config defines no teams')

    t.isTrue(s.lobby.SetTeam(1, teams[1].key), 'a real team was refused')

    t.equals(s.state(1).player.team, teams[1].key, 'the switch did not reach the snapshot')
end)

t.test('switching WITHIN your own team is not counted against its cap', function()
    -- A player already inside the team must not be counted twice against
    -- the cap they are already inside -- otherwise re-picking the side you
    -- are already on is refused as full.
    local s = inTeamMode()
    local key = s.state(1).config.teams.list[1].key
    s.config.Teams.maxTeamSize = 1

    t.isTrue(s.lobby.SetTeam(1, key), 'the first pick was refused')
    t.isTrue(s.lobby.SetTeam(1, key), 're-picking the team they are already on was refused as full')
end)

t.test('but a team that IS full refuses somebody new', function()
    -- The control: without it, "not counted twice" passes against a cap
    -- that is never enforced at all.
    local s = inTeamMode()
    local key = s.state(1).config.teams.list[1].key
    s.config.Teams.maxTeamSize = 1
    s.lobby.SetTeam(1, key)

    local ok, err = s.lobby.SetTeam(2, key)

    t.isFalse(ok, 'a second player joined a team capped at one')
    t.isNotNil(err)
end)

-- ========================================================================
-- WHAT THE PANEL IS TOLD ABOUT BETTING
-- ========================================================================

t.test('the snapshot names the payout mode the server really uses', function()
    -- The panel writes a different sentence for each -- "the stake is
    -- gone" against fixed odds, a share of the pool against parimutuel --
    -- and it can only be right if this field is.
    local s = newArena({ [1] = 5000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout.spectators = 'odds'
    end)
    t.equals(s.state(1).config.betting.betPayout.spectators, 'odds',
        'the panel is told the wrong payout mode for spectator bets')

    local pool = newArena({ [1] = 5000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout.spectators = 'pool'
    end)
    t.equals(pool.state(1).config.betting.betPayout.spectators, 'pool',
        'a pool server is described to the panel as fixed odds')
end)

t.test('and anything that is not "odds" is described as a pool', function()
    -- The panel has two sentences and the config has one free-text field.
    -- Anything unrecognised has to land on the safe one rather than on
    -- whichever the code happens to check for.
    local s = newArena({ [1] = 5000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout.spectators = 'something_else'
    end)

    t.equals(s.state(1).config.betting.betPayout.spectators, 'pool',
        'an unrecognised payout mode was described to the panel as fixed odds')
end)

t.test('the entry-fee presets reach the panel, and an absent list is empty', function()
    local s = newArena({ [1] = 5000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = true
        config.Betting.entryFee.presets = { 100, 500, 1000 }
    end)
    t.equals(#s.state(1).config.betting.entryFee.presets, 3, 'the fee presets never reached the panel')

    local none = newArena({ [1] = 5000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = true
        config.Betting.entryFee.presets = nil
    end)
    t.equals(type(none.state(1).config.betting.entryFee.presets), 'table',
        'an operator who named no presets sends the panel a nil to index')
    t.equals(#none.state(1).config.betting.entryFee.presets, 0)
end)

os.exit(t.summary())
