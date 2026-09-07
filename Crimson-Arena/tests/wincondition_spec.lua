--[[
    crimson_arena/tests/wincondition_spec.lua

    HOW A ROUND IS DECIDED, and there is more than one way.

    `Config.Match.winCondition` is one of the first settings in the file and
    it decides the shape of a whole match. Before this file, one of its two
    values was tested and the other was not: a mutation that inverted the
    comparison deciding whether `score_limit` is even consulted survived all
    fifty-two spec files.

      last_standing   the shipped default: the last side alive takes it.
      score_limit     first to `Config.Match.scoreLimit` kills.

    And two rules that are easy to get wrong and silent when you do:

      A TIE IS A DRAW, NOT A WIN.  A round that crowns the first of two level
                                   players pays a pot to somebody who did not
                                   earn it, and the server cannot honestly
                                   order two kills reported in the same tick.

      RUNNING OUT OF OPPONENTS     with one side left standing there is
      ENDS IT UNDER EVERY RULE     nothing left to decide it with, whatever
                                   the configured condition says.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('wincondition_spec')

--- A server with six possible fighters, driven through the real events.
--- @param mutate function? -- last word on Config, before the files load
local function newServer(mutate)
    local downCleared = {}
    local players = {}
    for src = 1, 6 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent = {}, {}, {}
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
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
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
            -- RECORDED, because when this is called is the whole point. The
            -- flags used to be put back down only by the revive, seven
            -- seconds after the death, against a dispatch client polling the
            -- same metadata twice a second.
            ClearDownState = function(src)
                downCleared[#downCleared + 1] = src
                return 0
            end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })


    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 1
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config,
        match = env.ArenaMatch, lobby = env.ArenaLobby }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- Opens a match with `count` fighters and starts it.
    function server.play(count, teams)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark',
            modeKey = teams and 'tdm' or 'ffa',
            entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        if teams then
            for src = 1, count do
                fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        for src = 1, count do fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    --- A death, reported the way the client reports one.
    --- Every src the match told ArenaDispatch to put back down, in order.
    server.downCleared = downCleared

    function server.kill(victim, killer) server.match.OnDeath(victim, killer) end

    --- One pass of the sweep, which is what decides a round.
    function server.settle(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Runs the round clock out. `evaluate` compares match.endsAt against
    --- os.time(), so putting it in the past is the whole of "time is up" --
    --- there is no timer thread to step.
    function server.expire()
        local live = server.lobby.Get(matchId)
        if live then live.endsAt = os.time() - 1 end
    end

    --- One fighter's live record.
    function server.rowOf(src)
        local live = server.lobby.Get(matchId)
        return live and live.players[src]
    end

    --- The results payload one player was sent.
    function server.resultOf(src)
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:results' and message.target == src then
                return message.payload
            end
        end
        return nil
    end

    --- Puts a respawned fighter back on their feet, the way the scheduled
    --- respawn does. Stepping alone will not: the delay thread and the sweep
    --- are separate, and a test that stepped until it happened would also be
    --- stepping the sweep it is trying to observe.
    function server.revive(src)
        local live = server.lobby.Get(matchId)
        local row = live and live.players[src]
        if row then row.alive = true end
    end

    --- Why the round ended, read off the console the way an operator would.
    function server.endedWith()
        for _, line in ipairs(console) do
            local reason = tostring(line):match('match %S+ ended: (%S+)')
            if reason then return reason end
        end
        return nil
    end

    --- Who the results board told the players had won, as a sorted list.
    function server.winners()
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:results'
                and message.payload and message.payload.won == true then
                out[#out + 1] = message.target
            end
        end
        table.sort(out)
        return out
    end

    function server.log() return table.concat(console, '\n') end

    return server
end

--- Two lists of numbers, as one comparable string.
local function listed(values)
    local parts = {}
    for _, v in ipairs(values) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ',')
end

-- ======================================================================
-- LAST STANDING, the shipped default
-- ======================================================================

t.test('the shipped default is last_standing', function()
    local server = newServer()
    t.equals(server.config.Match.winCondition, 'last_standing',
        'the default changed -- everything below is aimed at the wrong rule')
end)

t.test('THE DOWN FLAG COMES BACK DOWN AT THE DEATH ITSELF', function()
    -- SEVEN SECONDS, AND EVERY ONE OF THEM COST A CALL. The medical
    -- script's "this player is down" metadata was cleared only by the
    -- revive, and on the path a fighter takes most -- dying with lives left
    -- -- the revive runs Config.Match.respawnDelaySeconds (5s) plus
    -- revive.afterRespawnDelayMs (2000ms) after the death. A dispatch client
    -- polls that same metadata every 500ms and files PlayerDown and
    -- PlayerDead off it with nobody pressing anything. Fourteen windows.
    --
    -- So it is cleared from OnDeath, with nothing waited on in between, and
    -- this asserts the call has already happened by the time the death has
    -- been scored -- not after a respawn, not after a settle.
    local server = newServer()
    server.play(3)
    server.kill(2, 1)

    t.equals(#server.downCleared, 1,
        'the death did not put the medical script\'s down flag back down')
    t.equals(server.downCleared[1], 2,
        'the flag was cleared for the wrong player')
end)

t.test('and for every death, not only the first', function()
    -- A round is many deaths. One clear on the first and silence after it
    -- would read as fixed for exactly one kill.
    local server = newServer()
    server.play(3)
    server.kill(2, 1)
    server.kill(3, 1)

    t.equals(#server.downCleared, 2,
        'the second death did not clear the flag')
end)

t.test('the last fighter alive takes the round', function()
    local server = newServer()
    server.play(2)
    server.kill(2, 1)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_last_standing',
        'the round did not end on the last survivor')
    t.equals(listed(server.winners()), '1', 'the survivor did not take it')
end)

t.test('and a mutual kill is a draw, not a race between two corpses', function()
    -- Both deaths are counted before anything is decided, deliberately: the
    -- server cannot honestly order two kills reported in the same tick.
    local server = newServer()
    server.play(2)
    server.kill(1, 2)
    server.kill(2, 1)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_draw', 'a double knockout crowned somebody')
    t.equals(listed(server.winners()), '', 'a draw produced winners')
end)

-- ======================================================================
-- SCORE LIMIT -- shipped, documented, and untested until now
-- ======================================================================

t.test('DEFECT: under score_limit, reaching the limit ends the round', function()
    -- Nobody is eliminated here: 2 is revived after each death, so
    -- last_standing could not possibly have ended this round. Only the score
    -- limit can, which is what makes this test about the setting.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
        config.Match.lives = 5
    end)
    server.play(3)

    server.kill(2, 1)
    server.revive(2)
    server.kill(3, 1)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_score_limit',
        'the score limit was reached and the round carried on')
    t.equals(listed(server.winners()), '1', 'the player who reached the limit did not take it')
end)

t.test('and stopping one short of it does not', function()
    -- The other half. A rule that ends the round EARLY is worse than one
    -- that never ends it, and only this direction catches an off-by-one.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 3
        config.Match.lives = 5
    end)
    server.play(3)

    server.kill(2, 1)
    server.revive(2)
    server.kill(3, 1)
    server.revive(3)
    server.settle(3)

    t.isNil(server.endedWith(), 'the round ended two kills into a limit of three')
end)

t.test('and the limit really comes from config, at more than one value', function()
    for _, limit in ipairs({ 1, 2, 4 }) do
        local server = newServer(function(config)
            config.Match.winCondition = 'score_limit'
            config.Match.scoreLimit = limit
            config.Match.lives = 9
        end)
        server.play(3)

        for _ = 1, limit - 1 do
            server.kill(2, 1)
            server.revive(2)
            server.settle(1)
            t.isNil(server.endedWith(), ('a limit of %d ended the round early'):format(limit))
        end

        server.kill(2, 1)
        server.revive(2)
        server.settle(3)
        t.equals(server.endedWith(), 'match.ended_score_limit',
            ('a limit of %d was never reached'):format(limit))
    end
end)

t.test('and last_standing ignores the limit entirely', function()
    -- The condition is a switch, not a suggestion: leaving it on the default
    -- must not quietly end rounds on kill count.
    local server = newServer(function(config)
        config.Match.scoreLimit = 1
        config.Match.lives = 5
    end)
    server.play(3)

    server.kill(2, 1)
    server.revive(2)
    server.settle(2)

    t.isNil(server.endedWith(),
        'a last_standing round ended on a score limit it is not playing to')
end)

-- ======================================================================
-- A TEAM SCORE IS THE TEAM'S, NOT ITS BEST PLAYER'S
-- ======================================================================
--
-- teamKills sums the SIDE, so two players on three kills each reach a limit
-- of six that neither of them reached alone. That branch of reachedScoreLimit
-- had no test at all: a mutation turning its `>=` into `>` survived every
-- spec in the suite, because every score-limit test was a free-for-all.

t.test('DEFECT: in a team mode the limit is measured against the SIDE', function()
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
        config.Match.lives = 9
    end)
    -- 1 and 3 are crimson, 2 and 4 are ash.
    server.play(4, true)

    -- One kill each for the two crimson players: neither has reached two,
    -- and their side has.
    server.kill(2, 1)
    server.revive(2)
    server.kill(4, 3)
    server.revive(4)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_score_limit',
        'two players on one kill each did not add up to their side\'s limit of two')

    -- And the WHOLE side takes it, not just the two who scored.
    t.equals(listed(server.winners()), '1,3', 'the winning side was not crowned as a side')
end)

t.test('and one kill short of it, the side has not won', function()
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 3
        config.Match.lives = 9
    end)
    server.play(4, true)

    server.kill(2, 1)
    server.revive(2)
    server.kill(4, 3)
    server.revive(4)
    server.settle(2)

    t.isNil(server.endedWith(), 'a side on two kills took a limit of three')
end)

-- ======================================================================
-- A TIE IS A DRAW, NOT A WIN
-- ======================================================================

t.test('DEFECT: two players level on kills is a draw, not the first of them', function()
    -- decideOnKills returns nobody when the lead is shared, and crowning the
    -- first of two equal players pays a pot to somebody who did not earn it.
    -- The mutual-kill test above never reaches this rule: with nobody left
    -- standing the round is decided a different way entirely.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 1
        config.Match.lives = 9
    end)
    server.play(3)

    -- 1 and 2 both take a kill in the same sweep, so both reach the limit.
    server.kill(3, 1)
    server.revive(3)
    server.kill(3, 2)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_draw',
        'a shared lead crowned somebody instead of ending in a draw')
    t.equals(listed(server.winners()), '', 'a draw produced winners')
end)

-- ======================================================================
-- RUNNING OUT OF OPPONENTS BEATS EVERY RULE
-- ======================================================================

t.test('one side left standing ends it even under score_limit', function()
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 99
    end)
    server.play(2)
    server.kill(2, 1)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_last_standing',
        'a round with one fighter left waited for a score limit of 99')
    t.equals(listed(server.winners()), '1', 'the survivor did not take it')
end)

-- ======================================================================
-- A PLAYER WHO IS OUT CANNOT WIN IT
-- ======================================================================
--
-- Both kill-counted endings -- the clock and the score limit -- used to
-- score every row in match.players. An eliminated fighter keeps their row
-- on purpose (the results board ranks off it, the spectator gate reads it),
-- so the leader on kills took the round whether or not they were still in
-- it. Nothing in the suite ran the clock at all: `time_up` did not appear
-- in a single spec file, which is how this shipped.

--- Five fighters, of whom 1 racks up two kills and is then knocked out.
--- Leaves 4 (one kill) and 5 (none) still standing.
local function leaderKnockedOut(server)
    server.play(5)
    server.kill(2, 1)
    server.kill(3, 1)
    server.kill(1, 4)
    return server
end

t.test('THE DEFECT: the clock crowned a fighter who was already out', function()
    local server = leaderKnockedOut(newServer())

    t.isTrue(server.rowOf(1).placement ~= nil,
        'fighter 1 was not actually eliminated, so this test proves nothing')
    t.equals(server.rowOf(1).kills, 2, 'fighter 1 did not end up the kill leader')

    server.expire()
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_time_up', 'the clock did not decide the round')
    t.equals(listed(server.winners()), '4',
        'the round was handed to the fighter with the most kills rather than the best of those still in it')
end)

t.test('and the crowned winner is not carrying a losing placement', function()
    -- The tell that the old winner was wrong: elimination had already
    -- written them a placement counted up from the bottom, so the results
    -- board announced a winner and ranked them fourth of five in the same
    -- payload.
    local server = leaderKnockedOut(newServer())
    server.expire()
    server.settle(3)

    local result = server.resultOf(4)
    t.isNotNil(result, 'the winner was sent no results at all')
    t.isTrue(result.won, 'the winner was not told they won')
    t.equals(result.placement, 1, 'the winner was ranked below somebody')
end)

t.test('and a tie among those still in is still a draw', function()
    -- The filter must not turn a draw into a win by removing the other half
    -- of the tie.
    local server = newServer()
    server.play(4)
    server.kill(3, 1)
    server.kill(4, 2)   -- 1 and 2 both on one kill, both still standing
    server.expire()
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_draw',
        'two level fighters still in the round were not a draw')
    t.equals(listed(server.winners()), '', 'a tie paid somebody')
end)

t.test('and the clock still crowns the leader when they ARE still in', function()
    -- The other direction: a filter that removed everybody would make every
    -- timed round a draw, and pass the test above for the wrong reason.
    -- Five, so knocking two out still leaves somebody besides the leader:
    -- with one fighter left the round ends on last_standing before the
    -- clock is ever consulted.
    local server = newServer()
    server.play(5)
    server.kill(2, 1)
    server.kill(3, 1)   -- 1 has two kills and is still standing
    server.expire()
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_time_up', 'the clock did not decide the round')
    t.equals(listed(server.winners()), '1', 'the leader still in the round did not take it')
end)

t.test('and a score limit reached by somebody who is OUT does not end the round', function()
    -- The same rule on the other caller. Reaching the limit and being
    -- knocked out before the sweep sees it used to end the round on that
    -- score -- and then hand it to whoever led among everybody else.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
    end)
    leaderKnockedOut(server)
    server.settle(3)

    t.equals(server.endedWith(), nil,
        'the round ended on a score limit reached by a fighter who was already out')
    t.equals(listed(server.winners()), '', 'somebody was paid for a round that is still being fought')

    -- And it can still end normally afterwards.
    server.kill(5, 4)
    server.settle(3)
    t.equals(listed(server.winners()), '4', 'the round could no longer be won at all')
end)

os.exit(t.summary())
