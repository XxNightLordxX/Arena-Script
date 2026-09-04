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
            ClearDownState = function() return 0 end,
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

    --- One pass of every live coroutine, twice by default.
    ---
    --- The count is exposed because a broadcast scheduled BY a thread is
    --- resumed inside the same pass that created it -- ipairs sees an entry
    --- appended while it is walking -- so a two-pass step can run a timer
    --- and its wake-up before a test has looked.
    function server.step(times)
        for _ = 1, (times or 2) do threads.step() end
    end
    function server.log() return table.concat(console, '\n') end

    --- The snapshot this player would be sent, as the panel receives it.
    function server.state(src) return server.lobby.BuildState(src) end

    --- How much has been sent so far, so a test can ask what happened
    --- AFTER a call rather than at any point in the lobby's life.
    function server.mark() return #sent end

    --- Every notification sentence one player has been shown since `mark`.
    --- Rendered by the real server/util.lua off the real locale file, so a
    --- message whose key does not exist fails here rather than on somebody's
    --- screen.
    function server.noticesSince(mark, target)
        local out = {}
        for index = (mark or 0) + 1, #sent do
            local message = sent[index]
            if message.event == 'crimson_arena:client:notify' and message.target == target then
                out[#out + 1] = tostring((message.payload or {}).description or '')
            end
        end
        return table.concat(out, '\n')
    end

    --- How many pushes of one client event have gone out, to anybody.
    --- A broadcast is measured by the fact that it HAPPENED: what it
    --- carries is what every other test in this file already asserts.
    function server.pushesOf(event)
        local hits = 0
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event then hits = hits + 1 end
        end
        return hits
    end

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

-- ========================================================================
-- WHAT A BETTOR IS TOLD ABOUT THEIR OWN BET
-- ========================================================================

--- A lobby with two fighters and a third player free to watch it.
local function lobbyWithWatcher(mutate)
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        if mutate then mutate(config) end
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, nil, nil, nil, nil)
    t.isNotNil(matchId, 'the host could not create a match')
    t.isTrue(s.lobby.Join(2, matchId, nil, nil), 'the second player could not join')
    t.isTrue(s.lobby.AddSpectator(3, matchId) == true,
        'the watcher could not be admitted, so nothing below proves anything')
    return s, matchId
end

t.test('DEFECT: a spectator is told about the side-bet they placed', function()
    -- The `bet` field was read off ArenaLobby.GetByPlayer, which answers the
    -- match a player is FIGHTING in. A spectator is not in match.players, so
    -- for them it answered nil -- and the one person whose bet is the ONLY
    -- thing they have riding on the round was the one person never told they
    -- had placed it. No stake, no side; and the entry pot deliberately does
    -- not move for a side-bet, so nothing else on the screen changed either.
    local s, matchId = lobbyWithWatcher()

    local placed, why = s.betting.PlaceSpectatorBet(3, matchId, 1, 1000, 'cash')
    t.isTrue(placed, ('the side-bet was refused: %s'):format(tostring(why)))

    local bet = s.state(3).player.bet
    t.isTrue(bet ~= false and bet ~= nil,
        'a spectator who placed a side-bet is told they have none')
    t.equals(bet.amount, 1000, 'the stake reached the panel wrong')
end)

t.test('and somebody watching who has NOT bet is still told they have none', function()
    -- The other direction, so this is not "always report a bet".
    local s = lobbyWithWatcher()
    t.equals(s.state(3).player.bet, false, 'somebody who has bet nothing was shown a bet')
end)

t.test('and a fighter is still told about their own', function()
    -- The case that already worked, kept so the fix cannot have moved the
    -- lookup off the fighters onto the watchers.
    local s, matchId = lobbyWithWatcher(function(config)
        config.Betting.fighterBets.enabled = true
    end)

    local placed, why = s.betting.PlaceSpectatorBet(1, matchId, 1, 1000, 'cash')
    t.isTrue(placed, ('the fighter\'s own bet was refused: %s'):format(tostring(why)))

    local bet = s.state(1).player.bet
    t.isTrue(bet ~= false and bet ~= nil, 'a fighter who backed themselves is told they have not')
    t.equals(bet.amount, 1000)
end)

t.test('DEFECT: somebody backing a FREE match cannot take a seat in it', function()
    -- The refusal lives in ArenaBetting.TakeStake, and ArenaLobby.Join only
    -- reaches TakeStake when the match has an entry fee. The shipped default
    -- fee is ZERO -- so on the commonest configuration there was a
    -- documented guard that nothing ever ran.
    --
    -- TakeStake's own comment says why it matters: a bet its holder can
    -- cancel at a moment of their choosing, by joining and walking straight
    -- out again, is a bet with no risk in it. And moneyconservation_spec has
    -- been walking this route for a while under the name "THE BET-THEN-JOIN
    -- HOLE", to reach a settlement path that only the hole could produce.
    local s, matchId = lobbyWithWatcher()
    t.equals(s.lobby.Get(matchId).entryFee, 0, 'this match is not free, so it tests the wrong thing')

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 1000, 'cash') == true,
        'the side-bet was refused, so there is nothing to exploit')

    local joined, why = s.lobby.Join(3, matchId, nil, nil)
    t.isFalse(joined, 'somebody backing the match took a seat in it')
    -- IN THE WORDS OF THE THING THEY DID. This used to answer
    -- 'error.bet_not_spectator' -- "Fighters do not bet on themselves." --
    -- which describes the half of the rule server/betting.lua enforces, and
    -- names an action the player clicking Join did not take.
    t.equals(why, 'error.bet_then_join')
end)

t.test('and somebody with no money on it joins freely', function()
    -- The other direction, so this is not "free matches refuse everybody".
    local s, matchId = lobbyWithWatcher()
    t.isTrue(s.lobby.Join(3, matchId, nil, nil) == true,
        'a watcher who has bet nothing was refused a seat')
end)

t.test('the snapshot says whether the book is still taking bets', function()
    -- server/betting.lua stops taking side-bets `closeAfterStartSeconds`
    -- after the fighting starts. Nothing carried that to the panel, so
    -- Place Bet stayed lit for the whole of a live round and every click on
    -- it past the window came back "Book is closed on this one."
    local s, matchId = lobbyWithWatcher(function(config)
        config.Betting.spectatorBets.closeAfterStartSeconds = 30
    end)
    local match = s.lobby.Get(matchId)

    t.equals(s.onlyMatch(3).betsOpen, true, 'a lobby was reported as closed to bets')

    -- Put the round live with the window still running. Written onto the
    -- match rather than driven through Start(), because the subject is what
    -- the SNAPSHOT reports for a given clock, not how a round begins.
    match.state = 'live'
    match.startsAt = os.time() - 5
    t.equals(s.onlyMatch(3).betsOpen, true,
        'the book was reported shut five seconds into a thirty-second window')

    match.startsAt = os.time() - 45
    t.equals(s.onlyMatch(3).betsOpen, false,
        'the book was reported open forty-five seconds into a thirty-second window')
end)

t.test('and the round tells every open panel the moment it shuts', function()
    -- ArenaLobby.Broadcast is driven by things people DO -- a join, a ready,
    -- a bet, a match ending -- and a window closing is a thing that happens
    -- to nobody. Without a broadcast of its own the flag above would stay
    -- true on every open panel until somebody else happened to act, which on
    -- a quiet server is the rest of the round.
    local s, matchId = lobbyWithWatcher(function(config)
        config.Betting.spectatorBets.closeAfterStartSeconds = 30
        config.Match.lobbyCountdownSeconds = 0
        config.Match.startCountdownSeconds = 0
        config.Match.minPlayers = 2
    end)

    s.lobby.SetReady(1, true)
    s.lobby.SetReady(2, true)
    t.isTrue(s.match.Start(matchId), 'the round never started')
    -- ONE pass, not the default two. goLive runs on this one and the thread
    -- it schedules is resumed inside the same pass -- far enough to park on
    -- its Wait, no further -- so a second pass here would run the wake-up
    -- before this test had looked at anything.
    s.step(1)
    t.equals(s.lobby.Get(matchId).state, 'live', 'the round never reached live')

    local before = s.pushesOf('state')
    -- The sandbox's Wait yields once whatever the duration, so one more pass
    -- is the whole of the delay: what is under test is that a thread was
    -- scheduled at all and that it broadcasts when it wakes.
    s.step(1)
    t.isTrue(s.pushesOf('state') > before,
        'nothing was pushed when the book shut, so every open panel kept offering the bet')
end)

t.test('and the snapshot NAMES the matches they have money on', function()
    -- THE PANEL COULD NOT SEE THE BET AT ALL, so the Join button on a
    -- backed match stayed lit and the refusal above arrived as a toast
    -- after the click.
    --
    -- `player.bet` cannot answer it: that field is the bet on the match
    -- they are IN or WATCHING, and a side-bet is placed from the Bets tab
    -- on a match they are doing neither with. A list, not one id, because
    -- one bet per MATCH is a rule and one bet per player is not.
    local s, matchId = lobbyWithWatcher()

    t.equals(#s.state(3).player.backing, 0,
        'a player who has bet nothing was listed as backing something')

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 1000, 'cash') == true,
        'the side-bet was refused, so there is nothing to report')

    local backing = s.state(3).player.backing
    t.equals(#backing, 1, 'the snapshot named ' .. tostring(#backing) .. ' backed matches, not 1')
    t.equals(backing[1], matchId, 'the snapshot named the wrong match')

    -- AND NOT EVERYBODY ELSE'S. This is per-head, and a list built off the
    -- whole book would refuse every player a seat the moment anyone bet.
    t.equals(#s.state(1).player.backing, 0,
        'another player was told they had money on a bet they did not place')
end)

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


-- ========================================================================
-- THE POT ON SCREEN IS THE POT THAT GETS PAID
--
-- REPORTED FROM LIVE TESTING: placing a bet did not change the pool.
--
-- betPayout.includeEntryPot ships ON and does what it says: at settle time
-- every fighter's entry fee becomes a stake on their own side and the whole
-- thing pays out as ONE pool. The number the panel showed was not that
-- pool -- it was the entry stakes and nothing else -- so a player's own
-- side-bet went into the half of the pot the screen could not see, and the
-- figure sat perfectly still.
-- ========================================================================

--- A lobby with an entry fee, both players in and paid up.
local function withFee(fee, mutate)
    local s = newArena({ [1] = 50000, [2] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = true
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = fee
        if mutate then mutate(config) end
    end)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, fee, nil, nil, 'cash')
    t.isNotNil(matchId, 'the match could not be created: ' .. tostring(err))
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the second player could not join')
    return s, matchId
end

t.test('the entry fees show as the pot before anybody bets', function()
    local s = withFee(500)

    t.equals(s.onlyMatch(1).pot, 1000, 'two 500 entry fees are not a pot of 1000')
    t.equals(s.onlyMatch(1).entryPot, 1000, 'the entry half is not reported')
    t.equals(s.onlyMatch(1).betPool, 0, 'a lobby with no bets reports a side-bet pool')
end)

t.test('and a side-bet RAISES the pot, because it is paid out of the same one', function()
    -- THE ASSERTION THIS SECTION EXISTS FOR. The old figure did not move.
    local s, matchId = withFee(500)

    t.isTrue(s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash'))

    t.equals(s.onlyMatch(1).pot, 3000, 'the pot did not move when a bet was placed into it')
    t.equals(s.onlyMatch(1).entryPot, 1000, 'the entry half changed when only a bet was placed')
    t.equals(s.onlyMatch(1).betPool, 2000, 'the side-bet half is not reported')
end)

t.test('but NOT where the two settle separately', function()
    -- With includeEntryPot off they are two prizes decided by different
    -- rules, and adding them would tell a player the entry pot is bigger
    -- than it is.
    local s, matchId = withFee(500, function(config)
        config.Betting.betPayout.includeEntryPot = false
    end)

    s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash')

    t.equals(s.onlyMatch(1).pot, 1000, 'a separately-settled side-bet was added to the entry pot')
    t.equals(s.onlyMatch(1).betPool, 2000, 'the side-bet pool is not reported on its own')
end)

t.test('and an ODDS bet never joins the pool, because the server funds it', function()
    -- Counting it would promise the winner money that is not in the pot.
    local s, matchId = withFee(500, function(config)
        config.Betting.betPayout.fighters = 'odds'
    end)

    s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash')

    t.equals(s.onlyMatch(1).betPool, 0, 'a server-funded bet was counted into the pool')
    t.equals(s.onlyMatch(1).pot, 1000, 'a server-funded bet was added to the prize pool')
end)

-- ========================================================================
-- AND A PLAYER CAN SEE THE BET THEY PLACED
-- ========================================================================

t.test('a player with no bet down is told so, rather than sent a nil', function()
    -- False rather than nil so the field is always on the wire: the panel
    -- has to tell "no bet" from "not sent".
    local s = withFee(500)

    t.equals(s.state(1).player.bet, false, 'a player with no bet was sent something else')
end)

t.test('and one who placed a bet gets the stake and the side back', function()
    local s, matchId = withFee(500)

    s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash')

    local mine = s.state(1).player.bet
    t.isTrue(type(mine) == 'table', 'the bet never reached the snapshot')
    t.equals(mine.amount, 2000, 'the stake is wrong on the way to the panel')
    t.equals(mine.pick, '1', 'the side backed is wrong on the way to the panel')
end)

t.test('and nobody ELSE sees it, because it is their own bet only', function()
    local s, matchId = withFee(500)

    s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash')

    t.equals(s.state(2).player.bet, false, 'one player was shown another player\'s bet')
end)

t.test('an entry fee folded into the pool is NOT reported as a bet they placed', function()
    -- addEntryStakesAsBets writes a row per fighter at settle time. That is
    -- bookkeeping, not a wager, and showing it as "you have 500 on
    -- yourself" would be the panel inventing a bet nobody made.
    local s, matchId = withFee(500)
    local match = s.lobby.Get(matchId)
    match.state = 'live'
    for src, player in pairs(match.players) do player.alive = (src == 1) end

    s.betting.Settle(matchId, { winners = { 1 }, players = match.players })

    t.equals(s.state(1).player.bet, false,
        'an entry fee folded into the pool was shown to the player as a bet they placed')
end)

-- ========================================================================
-- THE ROUND THAT STARTS ON ITS OWN, OR SAYS WHY IT DOES NOT
-- ========================================================================

--- The key of the first enabled team, for a test that needs to put two
--- players on the same side by hand.
local function firstTeamKey(s)
    local teams = s.env.Arena.GetEnabledTeams()
    t.isTrue(#teams > 0, 'the config under test enables no teams')
    return teams[1].key
end

t.test('DEFECT: a ready TEAM lobby never started, and nothing said why', function()
    -- Config.Match.autoStartWhenAllReady ships TRUE, and
    -- Config.Teams.autoAssignIfUnchosen ships TRUE -- the second exists so
    -- that nobody HAS to touch the team picker. Put them together in a team
    -- mode and the round never began.
    --
    -- SetReady ran Arena.CanStartMatch ITSELF before calling Begin, against
    -- the raw roster, where a player who skipped the picker still has
    -- team = nil. CountTeams counts only real keys, so `occupied` was 0 and
    -- the answer was 'error.need_two_teams'. Begin asks the same question
    -- but AFTER assignMissingTeams -- so the host pressing Start Match Now
    -- started the identical lobby instantly, while readying up did nothing
    -- at all, with no toast, no reason and no clock.
    local s, matchId = inTeamMode()
    s.config.Match.autoStartWhenAllReady = true
    s.config.Teams.autoAssignIfUnchosen = true
    s.config.Match.minPlayers = 2

    -- Neither of them picks a side, which is exactly what the setting allows.
    t.isNil(s.lobby.Get(matchId).players[1].team, 'the fixture pre-picked a side for player 1')
    t.isNil(s.lobby.Get(matchId).players[2].team, 'the fixture pre-picked a side for player 2')

    s.lobby.SetReady(1, true)
    s.lobby.SetReady(2, true)

    t.equals(s.lobby.Get(matchId).state, 'countdown',
        'everybody readied up on a server that promises to start on its own, and it did not')
end)

t.test('and where it genuinely cannot start, the whole room is told', function()
    -- The other half, and the reason the fix is not simply "call Begin".
    -- The refusal used to be discarded: `local startable = ...` takes only
    -- the first return, and the `if` had no else -- so a lobby that could
    -- not start was left sitting there with nothing on screen about it.
    --
    -- Both fighters on ONE side, which requireBothTeamsOccupied refuses.
    local s, matchId = inTeamMode()
    s.config.Match.autoStartWhenAllReady = true
    s.config.Match.minPlayers = 2

    local only = firstTeamKey(s)
    s.lobby.Get(matchId).players[1].team = only
    s.lobby.Get(matchId).players[2].team = only

    local mark = s.mark()
    s.lobby.SetReady(1, true)
    s.lobby.SetReady(2, true)

    t.equals(s.lobby.Get(matchId).state, 'lobby', 'a round with one empty side started anyway')
    t.isTrue(#s.noticesSince(mark, 1) > 0,
        'a lobby that could not start was left with nothing on screen saying so')
    t.isTrue(#s.noticesSince(mark, 2) > 0,
        'only one of the two was told')
end)

os.exit(t.summary())
