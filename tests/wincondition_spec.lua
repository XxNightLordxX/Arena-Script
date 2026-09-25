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
      most_kills      the highest count when the round clock stops.

    And two rules that are easy to get wrong and silent when you do:

      A TIE IS A DRAW, NOT A WIN.  A round that crowns the first of two level
                                   players pays a pot to somebody who did not
                                   earn it, and the server cannot honestly
                                   order two kills reported in the same tick.

      RUNNING OUT OF OPPONENTS     with one side left standing there is
      ENDS IT UNDER EVERY RULE     nothing left to decide it with, whatever
                                   the configured condition says.

      ONLY THE LAST ONE STANDING   both rules that end on a COUNT have to
      SPENDS A LIFE                keep everybody in the fight until the
                                   count decides it. Eliminate people under
                                   either and the round ends on the survivor
                                   with the count never read.
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
    local netEvents, console, sent, posts, recorded = {}, {}, {}, {}, {}
    --- The commands server/main.lua registers, by name. Captured so a test can
    --- run the REAL handler rather than a copy of what it is believed to do --
    --- "can an ordinary player use this" is a question about the body of that
    --- function, and reading it back is not an answer.
    local commands = {}
    local gameEvents = {}
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
        -- CAPTURED, because playerDropped is registered here rather than as
        -- a net event, and whether a crash is recorded the way a rage-quit
        -- is is a rule this file is the home of. A stub that swallowed the
        -- registration left that rule with no test at all.
        AddEventHandler = function(name, fn) gameEvents[name] = fn end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
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
        -- CAPTURED, because what the operator's Discord log actually says is
        -- the subject of the last test in this file.
        PerformHttpRequest = function(_url, _cb, _method, body) posts[#posts + 1] = body end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
            -- RECORDED, not a no-op. server/lobby.lua books a leaver's loss
            -- through this on the way out, and a stub without it would have
            -- let the type guard there skip the call and pass the tests at
            -- the foot of this file without recording anything at all.
            Record = function(entry) recorded[#recorded + 1] = entry return true end,
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
    -- GUN GAME IS SWITCHED ON HERE RATHER THAN INHERITED. It is an OPERATOR
    -- setting: config.lua ships it off, and Arena.GetModeByKey answers nil for
    -- a disabled mode, so every lobby.Create('gungame') in this file failed the
    -- moment the owner turned it off. A test about ladder plumbing must not
    -- depend on whether the shipped server offers the mode. Set BEFORE the
    -- caller's mutate, so a test that wants it off can still say so.
    env.Config.Modes.gungame.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, commands = commands,
        match = env.ArenaMatch, lobby = env.ArenaLobby }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- One client event, from one player. Exposed so a test can drive a
    --- path server.play does not cover -- walking out, for one.
    server.fire = fire

    --- One player's connection going away, through the same handler the
    --- server really registers for it.
    --- @param src integer
    function server.drop(src)
        local handler = gameEvents['playerDropped']
        if not handler then error('nothing handles playerDropped', 2) end
        env.source = src
        handler()
    end

    --- How many snapshots have been pushed to one player.
    ---
    --- Counted rather than merely looked for, because a snapshot goes out
    --- when a lobby opens -- so "is there one" is answered yes by a server
    --- that has sent nothing since.
    --- @param src integer
    --- @return integer
    function server.statePushes(src)
        local seen = 0
        for _, message in ipairs(sent) do
            if message.target == src and message.event == 'crimson_arena:client:state' then
                seen = seen + 1
            end
        end
        return seen
    end

    --- The LAST snapshot pushed to one player, or nil where none was.
    --- @param src integer
    --- @return table|nil
    function server.lastState(src)
        local found
        for _, message in ipairs(sent) do
            if message.target == src and message.event == 'crimson_arena:client:state' then
                found = message.payload
            end
        end
        return found
    end

    --- Opens a match with `count` fighters and starts it.
    --- @param count integer
    --- @param teams boolean|nil
    --- @param rules table|nil -- what the HOST picks in the creation menu:
    ---        winCondition and scoreLimit. Passed through the real create
    ---        event rather than written onto the match afterwards, so these
    ---        tests walk the same validation a panel does.
    function server.play(count, teams, rules)
        rules = rules or {}
        fire('createMatch', 1, {
            arenaKey = 'trailerpark',
            modeKey = teams and 'tdm' or 'ffa',
            entryFee = 0, account = 'cash',
            winCondition = rules.winCondition,
            scoreLimit = rules.scoreLimit,
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

    --- play(), but with the sides chosen by the caller. Needed for a THIRD
    --- team: play() splits by parity and starts the round in one breath, and
    --- a team cannot be changed once it has.
    --- @param sideOf fun(src: integer): string
    function server.playSides(count, sideOf, rules)
        rules = rules or {}
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'tdm',
            entryFee = 0, account = 'cash',
            winCondition = rules.winCondition, scoreLimit = rules.scoreLimit,
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src = 1, count do fire('setTeam', src, { teamKey = sideOf(src) }) end
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

    --- Every webhook body posted, as raw JSON.
    function server.posts() return posts end

    --- Every entry handed to ArenaStats.Record, in order.
    function server.recorded() return recorded end

    --- Every line this server printed to the console, in order.
    ---
    --- Exposed for the reports an operator reads: a report that is built
    --- correctly and never printed is the defect, so the assertion has to be
    --- made against what reached the console rather than the return value.
    server.console = console

    --- Every wallet movement the fixture has seen, with its reason.
    ---
    --- Exposed for the property test at the foot of this file: money is the
    --- one thing a round can get wrong without any screen showing it.
    server.ledger = qbx.ledger

    --- Every player's whole balance, cash and bank together.
    --- @return integer
    function server.moneyInCirculation()
        local total = 0
        for id = 1, 6 do
            local record = qbx.players[id]
            if record then
                total = total + (record.money.cash or 0) + (record.money.bank or 0)
            end
        end
        return total
    end

    --- Every notification one player was sent, oldest first, as plain text.
    ---
    --- Read off the wire because that is where the defect was: the string
    --- existed, was passed down the call as a reason key, and reached the
    --- other players and the bet refunds while never reaching the person who
    --- had asked to leave.
    --- @param src integer
    --- @return string[]
    function server.noticesTo(src)
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == src then
                out[#out + 1] = tostring((message.payload or {}).description or '')
            end
        end
        return out
    end

    --- The LAST in-match overlay one player was pushed, or nil.
    ---
    --- Read off the wire rather than from the match record: what the round
    --- is won on has to reach the SCREEN of the player fighting it, and a
    --- field that is correct on the server and never sent is the whole of
    --- the defect the tests at the foot of this file are about.
    function server.hudOf(src)
        local found
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:matchHud' and message.target == src then
                found = message.payload
            end
        end
        return found
    end

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
    -- THROUGH THE RESOLVER, NOT OFF THE RAW SETTING. Config.Match
    -- .winCondition now takes two shapes -- a plain string on a server that
    -- fixes it, a { allowChoose, default } block on one that lets the host
    -- pick -- exactly as `lives` and `roundTimeSeconds` already do. Read raw,
    -- this compared a string against a TABLE and every test below it was
    -- aimed at a rule nobody was running.
    local server = newServer()
    t.equals(server.env.Arena.WinConditionDefault(), 'last_standing',
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
    -- RUNNING OUT OF OPPONENTS BEATS EVERY RULE, and it still does -- but
    -- under a score limit you can no longer run out of them by KILLING them.
    --
    -- A score limit spends no lives, at the operator's own instruction and
    -- for a reason that is arithmetic rather than taste: the round is meant
    -- to end when somebody reaches the number, and a roster that can be
    -- eliminated runs out of players first on any limit worth setting. So a
    -- death here costs nothing and the victim is back on their feet -- which
    -- means the only way to be the last one left is for everybody else to
    -- actually LEAVE, and that is what this walks now.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 99
    end)
    server.play(2)

    server.kill(2, 1)
    server.settle(3)
    t.equals(server.endedWith(), nil,
        'a death ended a score-limit round -- it spends no lives, so nobody was eliminated')

    server.fire('leaveMatch', 2, {})
    server.settle(3)

    -- UNDER ITS OWN NAME. A roster that empties out is 'abandoned' rather
    -- than 'last_standing' -- the same rule, reached by people leaving rather
    -- than by people being eliminated -- and the survivor still takes it,
    -- which is the part that matters and the part a score limit must not
    -- have broken.
    t.equals(server.endedWith(), 'match.ended_abandoned',
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
    -- NOT BY ELIMINATION ANY MORE. A score limit spends no lives, so the
    -- leader cannot be knocked out of one -- they can only leave, which puts
    -- them out of the round by the other door and is the case this rule has
    -- to hold for either way.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
    end)
    server.play(5)
    server.kill(2, 1)
    server.kill(3, 1)
    t.equals(server.rowOf(1).kills, 2, 'fighter 1 did not reach the limit, so this proves nothing')

    server.fire('leaveMatch', 1, {})
    server.settle(3)

    t.equals(server.endedWith(), nil,
        'the round ended on a score limit reached by a fighter who is no longer in it')
    t.equals(listed(server.winners()), '', 'somebody was paid for a round that is still being fought')

    -- And it can still end normally afterwards -- on the limit, reached by
    -- somebody who is actually in the round. Two kills, because that is the
    -- limit and a score-limit round eliminates nobody: fighter 5 is back on
    -- their feet after the first one.
    server.kill(5, 4)
    server.settle(3)
    t.equals(server.endedWith(), nil, 'one kill against a limit of two ended the round')

    server.kill(5, 4)
    server.settle(3)
    t.equals(listed(server.winners()), '4', 'the round could no longer be won at all')
end)

-- ======================================================================
-- WHAT THE OPERATOR'S DISCORD LOG SAYS
-- ======================================================================

t.test('THE DEFECT: the match webhook posts the sentence, not the locale key', function()
    -- Every other webhook this resource sends carries a written line. The
    -- end-of-match one was handed `endReason`, which is a locale key, so an
    -- operator's Discord read "match.ended_last_standing".
    local server = newServer(function(config)
        config.Webhook.enabled = true
        config.Webhook.url = 'https://discord.example/webhook'
        config.Webhook.logResults = true
    end)
    server.play(2)
    server.kill(2, 1)
    server.settle(3)

    local body = server.posts()[1]
    t.isNotNil(body, 'no webhook was posted, so this test asserts nothing')
    t.isTrue(body:find('match.ended_last_standing', 1, true) == nil,
        'the raw locale key went to Discord: ' .. tostring(body))

    local sentence = Sandbox.locale('match.ended_last_standing')
    t.isTrue(body:find(sentence, 1, true) ~= nil,
        ('the webhook never carried the sentence %q: %s'):format(sentence, tostring(body)))
end)

t.test('and the SERVER log still carries the key, which is what it is for', function()
    -- The other half. A machine-readable server log wants the key; swapping
    -- both to the sentence would break grepping a log by reason.
    local server = newServer(function(config)
        config.Webhook.enabled = true
        config.Webhook.url = 'https://discord.example/webhook'
        config.Webhook.logResults = true
    end)
    server.play(2)
    server.kill(2, 1)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_last_standing',
        'the server log stopped naming the reason by key')
end)

-- ======================================================================
-- QUITTING A ROUND IS LOSING IT
-- ======================================================================
--
-- ArenaStats.RecordMatch walks match.players at the end of the round, and
-- ArenaLobby.Leave takes the leaver out of that table. So the leaderboard
-- only ever saw the people still standing on the roster when the round
-- finished: quitting a round you were losing cost nothing, and the kills and
-- deaths already on your record left with you.
--
-- The stake is already forfeited on this exact path -- shipped config keeps
-- a mid-match leaver's entry fee in the pot -- so this is the one half of
-- the penalty that was missing.

--- One player walking out, through the same event the panel's Leave sends.
local function walkOut(server, src)
    server.fire('leaveMatch', src, {})
end

t.test('THE DEFECT: leaving a live round is recorded as a loss', function()
    local server = newServer()
    server.play(3)
    server.kill(3, 1)       -- fighter 1 has a kill; 3 is out. 1 and 2 remain.

    walkOut(server, 1)

    local rows = server.recorded()
    t.equals(#rows, 1, ('the leaver was recorded %d time(s)'):format(#rows))
    t.equals(rows[1].citizenid, 'CID001', 'the wrong player was recorded')
    t.isFalse(rows[1].won, 'walking out of a live round was recorded as a WIN')
end)

t.test('and the kills and deaths they had already taken go with it', function()
    -- Not merely a loss row. Quitting used to erase the whole round for
    -- them, so a player could farm kills and drop before the result.
    local server = newServer()
    server.play(3)
    server.kill(3, 1)

    walkOut(server, 1)

    local row = server.recorded()[1]
    t.isNotNil(row, 'nothing was recorded at all')
    t.equals(row.kills, 1, 'the kill they took before quitting was not recorded')
    t.equals(row.earnings, 0, 'a leaver was credited with earnings')
end)

t.test('AND A CRASH IS NOT A QUIT: a dropped connection wears no loss', function()
    -- THE TWO RULES DISAGREE ON PURPOSE, and server/lobby.lua says so where
    -- it makes the call. The MONEY does not separate a quit from a crash --
    -- charging only genuine disconnects would take the stake from the player
    -- whose game died and hand it back to the one who quit on purpose. The
    -- LEADERBOARD is the opposite call: a loss follows you for the life of
    -- the server, and somebody whose game crashed should not wear one.
    --
    -- Untested until now, which is how a tidy-up that folded either rule
    -- into the other would have gone unnoticed.
    local server = newServer()
    server.play(3)
    server.kill(3, 1)       -- fighter 1 has a kill and is still standing

    server.drop(1)

    t.equals(#server.recorded(), 0,
        'a fighter whose connection went away was given a loss on the board')
end)

t.test('and walking out of the SAME round still is one, which is the control',
    function()
        -- Side by side with the test above, because the two differ by one
        -- boolean and a rule that recorded nobody would pass that one.
        local server = newServer()
        server.play(3)
        server.kill(3, 1)

        walkOut(server, 1)

        local rows = server.recorded()
        t.equals(#rows, 1, 'walking out recorded nothing, so the crash rule proves nothing')
        t.isFalse(rows[1].won, 'walking out of a live round was recorded as a WIN')
    end)

t.test('and a drop from a LOBBY records nothing either, for the other reason',
    function()
        -- Not the crash rule: nobody is recorded for leaving a lobby at all,
        -- however they go. Here so a reading of the test above as "drops are
        -- never recorded" cannot be mistaken for the rule.
        --
        -- BUILT WITHOUT server.play, which starts the round. A fourth
        -- argument would have been ignored and the match would have gone
        -- live -- and a live round spares a dropped fighter for the OTHER
        -- reason, so the test would have passed without touching a lobby.
        local server = newServer()
        local id = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
            nil, nil, nil, nil)
        t.isNotNil(id, 'no lobby was opened at all')
        t.isTrue((server.lobby.Join(2, id, nil, 'cash')), 'nobody else could join it')
        t.equals(server.lobby.Get(id).state, 'lobby',
            'the match is not sitting in its lobby, so this is not testing one')

        server.drop(1)

        t.equals(#server.recorded(), 0, 'leaving a lobby was put on the board')
    end)

t.test('and a LOBBY is not a round, so leaving one records nothing', function()
    -- The same answer their stake gets on that path: handed back, nothing
    -- happened. A fix that recorded every departure would give a loss to
    -- anybody who looked at a lobby and changed their mind.
    local server = newServer(function(config)
        config.Match.lobbyCountdownSeconds = 30       -- keep it in the lobby
    end)
    server.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    local matchId = server.lobby.All()[1].id
    server.fire('joinMatch', 2, { matchId = matchId, account = 'cash' })

    walkOut(server, 2)

    t.equals(#server.recorded(), 0, 'backing out of a lobby was recorded as a loss')
end)

t.test('and the leaver is recorded ONCE, not again when the round ends', function()
    -- End sets state to 'ended' before it calls RecordMatch, and the guard
    -- is 'live' rather than the money predicate for exactly that reason: a
    -- disconnect arriving in that window would otherwise be booked twice.
    local server = newServer()
    server.play(3)
    walkOut(server, 1)
    t.equals(#server.recorded(), 1, 'the walk-out was not recorded')

    server.kill(3, 2)       -- 2 is the last one standing: the round ends
    server.settle(3)

    local mine = 0
    for _, row in ipairs(server.recorded()) do
        if row.citizenid == 'CID001' then mine = mine + 1 end
    end
    t.equals(mine, 1, ('the leaver was booked %d times across the round'):format(mine))
end)

t.test("and a drop that lands once the round has ENDED is left to RecordMatch", function()
    -- The window the 'live' guard exists for, forced directly because
    -- ArenaMatch.End runs straight through it: End sets 'ended' and only
    -- then walks match.players into RecordMatch, so a disconnect arriving
    -- between the two is already going to be booked there. Guarding on the
    -- money predicate instead -- 'live' OR 'ended' -- books it twice.
    local server = newServer()
    server.play(3)

    local live = server.lobby.All()[1]
    live.state = 'ended'

    walkOut(server, 1)

    t.equals(#server.recorded(), 0,
        'a drop after the round ended was recorded here as well as by RecordMatch')
end)

-- ======================================================================
-- WHICH SIDE TOOK IT
-- ======================================================================

t.test('a team round says on the card which side won it', function()
    -- THE ONE FACT THE BOARD DID NOT CARRY. Everything on the results card
    -- is about the reader -- "You Won", their placement, their kills -- and
    -- the rows are individuals. A spectator is sent this board and nothing
    -- else at the end of a round, so the fight they had just watched
    -- finished with the panel declining to say who had won it.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
        config.Match.lives = 9
    end)
    -- 1 and 3 are crimson, 2 and 4 are ash.
    server.play(4, true)

    server.kill(2, 1)
    server.revive(2)
    server.kill(4, 3)
    server.revive(4)
    server.settle(3)

    t.equals(listed(server.winners()), '1,3', 'the fixture did not produce a crimson win')

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        local card = server.resultOf(src)
        t.isTrue(card ~= nil, ('fighter %d was sent no results card at all'):format(src))
        t.equals(card.winningTeam, 'crimson',
            ('fighter %d was not told which side took the round'):format(src))
    end
end)

t.test('and a free-for-all is told nothing, because there is no side to name', function()
    -- `winningPick` answers the winning FIGHTER's src in a free-for-all,
    -- which is a different fact and one the card already carries twice over.
    -- Sending it under a field the panel reads as a team key would have the
    -- panel looking up team "3" and drawing whatever it found.
    local server = newServer()
    server.play(3)

    server.kill(2, 1)
    server.kill(3, 1)
    server.settle(3)

    local card = server.resultOf(1)
    t.isTrue(card ~= nil, 'the winner was sent no results card at all')
    t.isNil(card.winningTeam, 'a free-for-all put something in the winning-side field')
end)

t.test('and no winner in a team round is not a side either', function()
    -- A draw has no winners, so there is nothing to name -- and naming one
    -- would be the card asserting a result the server did not reach.
    local server = newServer(function(config) config.Match.lives = 1 end)
    server.play(4, true)

    -- Both sides wiped in the same tick: `evaluate` finds no side standing.
    server.kill(1, 2)
    server.kill(3, 4)
    server.kill(2, 1)
    server.kill(4, 3)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_draw', 'the fixture did not produce a draw')
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        local card = server.resultOf(src)
        if card then
            t.isNil(card.winningTeam,
                ('fighter %d was told a side won a drawn round'):format(src))
        end
    end
end)

t.test('and a winner is never handed a placement below somebody who lost', function()
    -- The round is decided on the SIDE's total kills and the board was
    -- ranked on the individual's, so the two asked different questions: a
    -- winner on the side that out-fragged the other could sit below the
    -- losing side's top fragger. "You Won · Placed #3" on one card, over a
    -- board whose top row is somebody who lost.
    --
    -- It cannot be ranked away: a team win has two or more winners and only
    -- one of them can be #1. Sorting the winning side to the top is what
    -- makes the placement mean "you were on the side that won, and here is
    -- where you came within it".
    local server = newServer(function(config) config.Match.lives = 9 end)
    server.play(4, true)

    -- Ash's fighter 2 out-frags everybody: three kills on fighter 1.
    for _ = 1, 3 do
        server.kill(1, 2)
        server.revive(1)
    end
    -- Crimson takes the round 4-3 between them, on two fighters.
    server.kill(4, 1)
    server.revive(4)
    server.kill(4, 1)
    server.revive(4)
    server.kill(4, 3)
    server.revive(4)
    server.kill(4, 3)
    server.revive(4)

    server.expire()
    server.settle(3)

    t.equals(listed(server.winners()), '1,3', 'the fixture did not produce a crimson win')

    local best = nil
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        local card = server.resultOf(src)
        t.isTrue(card ~= nil, ('fighter %d was sent no results card'):format(src))
        if card.won ~= true then
            if best == nil or card.placement < best then best = card.placement end
        end
    end

    for _, src in ipairs({ 1, 3 }) do
        local card = server.resultOf(src)
        t.isTrue(card.won == true, ('fighter %d should be a winner'):format(src))
        t.isTrue(card.placement < best,
            ('a winner was placed #%d, below a loser at #%d'):format(card.placement, best))
    end
end)

t.test('and an ELIMINATED member of the winning side is not left below the losers', function()
    -- THE HALF THE FIRST FIX COULD NOT REACH. A team win crowns the whole
    -- side, corpses included, and every corpse was numbered from the bottom
    -- up by placementFor on the way out -- while the winners-first sort only
    -- ever saw players who had NO number yet. So the one case the fix was
    -- written for, an ordinary last_standing round, still produced
    -- "You Won" + "Crimson takes it" + "Placed #4" under two losers.
    --
    -- lives = 1 and a last_standing finish, which is the shipped shape of
    -- the mode rather than a contrived one.
    local server = newServer(function(config) config.Match.lives = 1 end)
    -- 1 and 3 are crimson, 2 and 4 are ash.
    server.play(4, true)

    server.kill(1, 2)   -- crimson's 1 out first
    server.kill(2, 3)   -- ash's 2 out
    server.kill(4, 3)   -- ash's 4 out; crimson left standing
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_last_standing',
        'the fixture did not produce a last-one-standing finish')
    t.equals(listed(server.winners()), '1,3', 'crimson should have taken it as a side')

    local cards = {}
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        cards[src] = server.resultOf(src)
        t.isTrue(cards[src] ~= nil, ('fighter %d was sent no results card'):format(src))
    end

    local worstWinner, bestLoser = nil, nil
    for src, card in pairs(cards) do
        if card.won == true then
            if worstWinner == nil or card.placement > worstWinner then worstWinner = card.placement end
        elseif bestLoser == nil or card.placement < bestLoser then
            bestLoser = card.placement
        end
        t.isTrue(card.placement ~= nil, ('fighter %d was sent no placement'):format(src))
    end

    t.isTrue(worstWinner < bestLoser,
        ('a winner was placed #%d, below a loser at #%d -- fighter 1 (eliminated first, on the '
            .. 'winning side) is the one this is about'):format(worstWinner, bestLoser))

    -- AND NO TWO PEOPLE SHARE A NUMBER. Renumbering only some of the roster
    -- against numbers another rule wrote is how a board comes to have two
    -- #2s, which reads as a bug to anybody looking at it.
    local seen = {}
    for src, card in pairs(cards) do
        t.isNil(seen[card.placement],
            ('fighters %s and %d were both placed #%d')
                :format(tostring(seen[card.placement]), src, card.placement))
        seen[card.placement] = src
    end
end)

t.test('and the eliminated keep the order they went out in', function()
    -- placementFor numbers from the bottom up as each player is eliminated,
    -- so among the losers a LOWER stored number means they lasted LONGER --
    -- and that ordering is real information the board should keep rather
    -- than re-derive from kills.
    local server = newServer(function(config) config.Match.lives = 1 end)
    server.play(4, true)

    server.kill(1, 2)
    server.kill(2, 3)
    server.kill(4, 3)
    server.settle(3)

    local out2 = server.resultOf(2).placement   -- ash, out second
    local out4 = server.resultOf(4).placement   -- ash, out third (lasted longer)

    t.isTrue(out4 < out2,
        ('the fighter who lasted longer was placed #%d, below the one who went out before them at #%d')
            :format(out4, out2))
end)

t.test('and the board under the placement is in the same order as it', function()
    -- TWO RANKINGS ON ONE CARD. scoreboardOf ranks on tier, then kills, then
    -- deaths -- right for the LIVE board, where there is no placement to
    -- rank by. The end-of-round board is a different one: it is drawn under
    -- "Placed #N", and a winner reading "Placed #2" over a board whose top
    -- row is somebody who lost has been handed two answers to one question.
    local server = newServer(function(config) config.Match.lives = 9 end)
    server.play(4, true)

    -- Ash's fighter 2 out-frags everybody; crimson takes it 4-3 between two.
    for _ = 1, 3 do
        server.kill(1, 2)
        server.revive(1)
    end
    for _ = 1, 2 do
        server.kill(4, 1)
        server.revive(4)
        server.kill(4, 3)
        server.revive(4)
    end

    server.expire()
    server.settle(3)

    local card = server.resultOf(1)
    t.isTrue(card ~= nil and type(card.scoreboard) == 'table',
        'the winner was sent no board at all')

    local order, places = {}, {}
    for _, src in ipairs({ 1, 2, 3, 4 }) do places[src] = server.resultOf(src).placement end
    for _, row in ipairs(card.scoreboard) do order[#order + 1] = places[row.id] end

    for index = 2, #order do
        t.isTrue(order[index - 1] < order[index],
            ('the board is ordered %s, and the placements printed over it are not')
                :format(table.concat({ table.unpack(order) }, ',')))
    end

    t.equals(order[1], 1, 'the top row of the board is not the player placed first')
end)

-- ======================================================================
-- THE HOST NAMES THE FINISH LINE
-- ======================================================================

t.test('a host can name the kill limit, and the round is played to theirs', function()
    -- "on the win condition kill limit, ability to name the kill limit".
    --
    -- The number was the operator's alone: a host could pick the CONDITION
    -- and not the line it finishes on, which is most of the decision.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.scoreLimit = { allowChoose = true, min = 1, max = 200, default = 25 }
    end)
    server.play(3, false, { winCondition = 'score_limit', scoreLimit = 2 })

    server.kill(2, 1)
    server.settle(3)
    t.equals(server.endedWith(), nil, 'one kill against a limit of two ended the round')

    server.kill(3, 1)
    server.settle(3)
    t.equals(server.endedWith(), 'match.ended_score_limit',
        'the host\'s own limit of 2 was not what the round was played to')
    t.equals(listed(server.winners()), '1', 'the fighter who reached it did not take it')
end)

t.test('and the server\'s own number is what a host who names none plays to', function()
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'score_limit' }
        config.Match.scoreLimit = { allowChoose = true, min = 1, max = 200, default = 3 }
    end)
    server.play(3)

    server.kill(2, 1)
    server.kill(3, 1)
    server.settle(3)
    t.equals(server.endedWith(), nil, 'two kills against the default of three ended the round')

    server.kill(2, 1)
    server.settle(3)
    t.equals(server.endedWith(), 'match.ended_score_limit',
        'the server\'s own default was not what the round was played to')
end)

t.test('and a limit outside the band is refused, so no match opens on it', function()
    -- REFUSED, NOT CLAMPED. A host dropped into a round with a different
    -- finish line from the one they set would have no way of knowing.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.scoreLimit = { allowChoose = true, min = 5, max = 50, default = 25 }
    end)

    -- nil for the round length, not 0: on a server that offers a range, 0 is
    -- BELOW the floor and is refused on its own -- which would make this test
    -- pass on the wrong refusal. nil is "the host left the box alone".
    local ok, reason = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', nil,
        'score_limit', nil, 500)
    t.isNil(ok, 'a limit over the ceiling opened a match anyway')
    t.equals(reason, 'error.score_limit_out_of_range', 'and the host was not told why')

    t.equals(#server.lobby.All(), 0, 'a refused create left a match behind')
end)

-- ======================================================================
-- MOST KILLS WHEN THE CLOCK RUNS OUT
-- ======================================================================
--
-- IN A PLAYER'S WORDS: "on win condition it should not have a lives for most
-- kills till the clock runs out".
--
-- The third condition shipped spending lives, because the test for "does a
-- death cost anything" was `~= 'score_limit'` and most kills was simply not
-- 'score_limit'. So the rule a host picked -- whoever has the most kills
-- when the clock stops -- was decided by the roster instead: the round ended
-- the moment one player ran out of lives, under ended_last_standing, with
-- the clock still running and the kill count never read.

t.test('THE REPORT: under most kills, a death costs no life', function()
    -- ONE LIFE EACH, so the old rule cannot be mistaken for the new one:
    -- two kills is two eliminations out of three fighters, and the round
    -- ended on the survivor before this fix.
    local server = newServer(function(config)
        config.Match.winCondition = 'most_kills'
        config.Match.lives = 1
    end)
    server.play(3)

    server.kill(2, 1)
    server.kill(3, 1)
    server.settle(3)

    -- THE ROUND FIRST. An eliminated fighter keeps their row, but a round
    -- that has ENDED has no rows at all -- so asking about the row first
    -- fails on a nil index and says nothing about why.
    t.equals(server.endedWith(), nil,
        'the round ended on the last one standing, which is not the rule the host picked')
    t.isNil(server.rowOf(2).placement,
        'a death under most kills eliminated the fighter')
end)

t.test('and the clock is what ends it, on the count', function()
    local server = newServer(function(config)
        config.Match.winCondition = 'most_kills'
        config.Match.lives = 1
    end)
    server.play(3)

    server.kill(2, 1)
    server.kill(3, 1)
    server.expire()
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_time_up',
        'the clock did not decide a most-kills round')
    t.equals(listed(server.winners()), '1', 'the kill leader did not take it')
end)

t.test('and a fighter who died most still wins it on kills', function()
    -- THE WHOLE POINT OF THE RULE, and the case lives made impossible: the
    -- leader on kills has been killed more often than anybody. With lives
    -- spent they were out of the round long before the clock; without them
    -- they are still in it and the count is what is read.
    local server = newServer(function(config)
        config.Match.winCondition = 'most_kills'
        config.Match.lives = 1
    end)
    server.play(3)

    server.kill(1, 2)
    server.kill(1, 3)   -- fighter 1 has died twice on a one-life setting
    server.kill(2, 1)
    server.kill(3, 1)
    server.kill(2, 1)   -- and has three kills to everybody else's one
    server.expire()
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_time_up', 'the clock did not decide the round')
    t.equals(listed(server.winners()), '1',
        'the fighter with the most kills did not take it')
end)

t.test('and last standing still spends lives, so this did not turn them off everywhere',
    function()
        -- The control. A change that stopped lives being spent AT ALL would
        -- pass all three tests above and break the shipped default.
        local server = newServer(function(config)
            config.Match.winCondition = 'last_standing'
            config.Match.lives = 1
        end)
        server.play(3)

        server.kill(2, 1)
        server.settle(3)

        t.isNotNil(server.rowOf(2).placement,
            'a death under last standing no longer eliminates anybody')
    end)

t.test('and a round with no clock at all is refused, not left running', function()
    -- THE OTHER HALF OF TAKING LIVES OFF IT. Nothing about the roster ends a
    -- most-kills round any more, so on a mode whose clock resolves to 0 it
    -- would run until the last player walked out. Lives were quietly ending
    -- those rounds before, on the wrong rule.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.roundTimeSeconds = 0
    end)

    local ok, reason = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', nil,
        'most_kills', nil, nil)
    t.isNil(ok, 'a most-kills round with no clock opened anyway')
    t.equals(reason, 'error.win_condition_needs_clock', 'and the host was not told why')
    t.equals(#server.lobby.All(), 0, 'a refused create left a match behind')
end)

t.test('and the same round WITH a clock opens', function()
    -- The control: a guard that refused every most-kills match would pass
    -- the test above and take the condition off the server.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.roundTimeSeconds = 600
    end)

    local ok, reason = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', nil,
        'most_kills', nil, nil)
    t.isNotNil(ok, 'a most-kills round with a clock was refused: ' .. tostring(reason))
end)

t.test('and a LADDER mode with no clock is not refused, because it ignores all of it',
    function()
        -- A gun game is won by topping the ladder, whatever the win
        -- condition says -- server/match.lua reads the ladder BEFORE the
        -- condition and overrides it, and config.lua documents
        -- `gungame.roundTimeSeconds = 0` as a supported setting that leaves
        -- the ladder as the only thing that ends the round.
        --
        -- So a guard that did not ask about the ladder first took the mode
        -- off a server running it that way: every attempt to open a gun game
        -- refused over a rule the mode never consults.
        local server = newServer(function(config)
            config.Match.winCondition = 'most_kills'
            config.Match.roundTimeSeconds = 0
            config.Modes.gungame.roundTimeSeconds = 0
        end)

        local ok, reason = server.lobby.Create(1, 'trailerpark', 'gungame', 0, 3, false, 'cash',
            nil, nil, nil, nil)
        t.isNotNil(ok, 'a clockless gun game was refused: ' .. tostring(reason))
    end)

t.test('and the same server still refuses a free-for-all on it, which is the control',
    function()
        -- The other direction: an exemption written as "skip the guard" would
        -- pass the test above and take the guard off every mode.
        local server = newServer(function(config)
            config.Match.winCondition = 'most_kills'
            config.Match.roundTimeSeconds = 0
            config.Modes.gungame.roundTimeSeconds = 0
        end)

        local ok, reason = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
            nil, nil, nil, nil)
        t.isNil(ok, 'a clockless free-for-all on most kills opened anyway')
        t.equals(reason, 'error.win_condition_needs_clock', 'and the host was not told why')
    end)

-- ======================================================================
-- A REFUSED EDIT PUTS THE FORM BACK
-- ======================================================================
--
-- The create/edit form is the second control in the panel that holds a
-- DRAFT -- values that exist only in the browser until the server agrees.
-- It seeds once per lobby id, on purpose: a broadcast lands on every join,
-- ready, bet and match start anywhere on the server, and re-seeding on
-- those would overwrite a host mid-edit.
--
-- Which leaves exactly one moment it MUST seed again. A refused "Apply
-- changes" was only a red toast, so the form went on showing the rule the
-- server had just turned down, over a lobby still fought under the old one,
-- with the lobby card beside it disagreeing and nothing saying which was
-- real. server/main.lua's own note beside the loadout picker states the
-- rule this was breaking.

t.test('THE SILENT DRAFT: a refused edit counts, and the snapshot goes back', function()
    -- A server that offers the choice and has no clock to offer with it, so
    -- picking most kills is refused for the reason this file is about.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.roundTimeSeconds = 0
    end)

    local id = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
        nil, nil, nil, nil)
    t.isNotNil(id, 'no lobby was opened, so there is nothing to edit')

    local before, pushedBefore = server.lastState(1), server.statePushes(1)
    t.equals(before and tonumber(before.player and before.player.editRefused) or 0, 0,
        'the count started above zero, so a rise proves nothing')

    server.fire('updateMatch', 1, { winCondition = 'most_kills' })

    -- COUNTED, not merely present. A snapshot already exists from opening
    -- the lobby, so `isNotNil` on the last one is satisfied whether the
    -- refusal pushed anything or not -- it would report "a snapshot arrived"
    -- over a server that sent nothing.
    t.isTrue(server.statePushes(1) > pushedBefore,
        'the refusal pushed no snapshot at all, so the form never hears about it')

    local after = server.lastState(1)
    t.equals(tonumber(after.player and after.player.editRefused), 1,
        'a refused edit was not counted, so the form keeps the rule the server turned down')

    -- AND AGAIN, because the production comments say a COUNT rather than a
    -- flag, and nothing was checking the difference: a `= 1` would satisfy
    -- every assertion above and then never move again, so the second refusal
    -- in one lobby would leave the form holding the rejected rule.
    server.fire('updateMatch', 1, { winCondition = 'most_kills' })
    t.equals(tonumber(server.lastState(1).player.editRefused), 2,
        'the second refusal did not move the count, so the form re-seeds only once')

    -- AND THE MATCH IS UNTOUCHED, which is the other half: a refusal that
    -- half-applied would be worse than one that said nothing.
    t.equals(server.lobby.Get(id).winCondition, '',
        'the refused rule was written onto the match anyway')
end)

t.test('and the count goes with them when their connection does', function()
    -- A SERVER ID IS HANDED ON. Everything else keyed by source in this
    -- resource is dropped on playerDropped and says so where it is dropped
    -- -- the admin tablet's refresh ticket, the rate-limit history. This
    -- count was the one that was not tested, and the cost of leaking it is
    -- the next player to be given that id opening a form that re-seeds
    -- itself on a refusal somebody else was told about.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.roundTimeSeconds = 0
    end)

    local id = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
        nil, nil, nil, nil)
    t.isNotNil(id, 'no lobby was opened, so there is nothing to refuse')

    server.fire('updateMatch', 1, { winCondition = 'most_kills' })
    t.equals(tonumber(server.lastState(1).player.editRefused), 1,
        'the refusal was not counted, so this test has nothing to watch being dropped')

    server.drop(1)

    -- The same source, back on the server and in a lobby of their own.
    local second = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
        nil, nil, nil, nil)
    t.isNotNil(second, 'the recycled source could not open a lobby')

    t.equals(tonumber(server.lastState(1).player.editRefused) or 0, 0,
        'the new player inherited a refusal count that was never theirs')
end)

t.test('and an edit the server ACCEPTS does not count as a refusal', function()
    -- The control. A count that rose on every edit would re-seed the form
    -- constantly and throw away whatever the host was typing next.
    local server = newServer(function(config)
        config.Match.winCondition = { allowChoose = true, default = 'last_standing' }
        config.Match.roundTimeSeconds = 600
    end)

    local id = server.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash',
        nil, nil, nil, nil)
    t.isNotNil(id)

    local pushedBefore = server.statePushes(1)
    server.fire('updateMatch', 1, { winCondition = 'most_kills' })

    -- A SNAPSHOT REALLY ARRIVED, so the zero below is read off a fresh one.
    -- Reading it off a stale snapshot cannot tell "not counted" from "the
    -- panel never heard anything at all".
    t.isTrue(server.statePushes(1) > pushedBefore,
        'an accepted edit broadcast nothing, so the panel still shows the old rule')

    local after = server.lastState(1)
    t.equals(tonumber(after.player and after.player.editRefused) or 0, 0,
        'an accepted edit was counted as a refusal')
    t.equals(server.lobby.Get(id).winCondition, 'most_kills',
        'the accepted rule was not written onto the match')
end)


-- ======================================================================
-- A SIDE WITH NOBODY LEFT IN IT CANNOT WIN ON THE CLOCK
-- ======================================================================

local function threeWay(src)
    if src <= 2 then return 'crimson' elseif src <= 4 then return 'ash' else return 'bone' end
end

local function withThirdTeam()
    return newServer(function(config)
        config.Teams.list.bone.enabled = true
        config.Match.lives = { allowChoose = true, min = 1, max = 10, default = 3 }
    end)
end

t.test('THE DEFECT: the clock crowned a side that had been wiped out', function()
    -- bone takes four kills and is then eliminated; crimson ends on two,
    -- ash on one, both still standing.
    local s = withThirdTeam()
    s.playSides(6, threeWay)
    s.kill(2, 5); s.revive(2)
    s.kill(2, 5); s.revive(2)
    s.kill(4, 6); s.revive(4)
    s.kill(4, 6); s.revive(4)
    s.kill(5, 1); s.revive(5)
    s.kill(6, 3); s.revive(6)
    s.kill(3, 1); s.revive(3)
    s.kill(5, nil); s.revive(5)
    s.kill(5, nil)
    s.kill(6, nil); s.revive(6)
    s.kill(6, nil)

    t.isTrue(s.rowOf(5).placement ~= nil and s.rowOf(6).placement ~= nil,
        'bone was not actually eliminated, so this test proves nothing')

    s.expire()
    s.settle(3)

    t.equals(s.endedWith(), 'match.ended_time_up', 'the clock did not decide the round')
    t.equals(listed(s.winners()), '1,2',
        'the round went to the side with the most kills rather than the best side still in it')
end)

t.test('and a side that walked out with its kills banked does not turn the round into a draw', function()
    -- crimson takes three kills and both of its fighters leave; ash and bone
    -- are standing on one kill each, ash with one more.
    local s = withThirdTeam()
    s.playSides(6, threeWay)
    s.kill(3, 1); s.revive(3)
    s.kill(5, 1); s.revive(5)
    s.kill(6, 2); s.revive(6)
    s.kill(1, 3); s.revive(1)
    s.kill(2, 3); s.revive(2)
    s.kill(4, 5); s.revive(4)
    s.drop(1)
    s.drop(2)

    s.expire()
    s.settle(3)

    t.isTrue(s.endedWith() ~= 'match.ended_draw',
        'a side that had left the round still led on banked kills, and the round ended as a draw')
    t.equals(listed(s.winners()), '3,4',
        'the pot did not go to the best side still standing')
end)


t.test('and a score limit reached by a side that has since left does not end the round as a draw', function()
    -- crimson reaches the limit and both fighters leave before the sweep
    -- notices; ash and bone are standing.
    local s = withThirdTeam()
    s.playSides(6, threeWay, { winCondition = 'score_limit', scoreLimit = 2 })
    s.kill(3, 1); s.revive(3)
    s.kill(4, 2); s.revive(4)
    s.kill(5, 3); s.revive(5)
    s.drop(1)
    s.drop(2)

    s.settle(3)

    t.isTrue(s.endedWith() ~= nil and s.endedWith() ~= 'match.ended_draw',
        ('a departed side reached the limit and the round ended as: %s'):format(tostring(s.endedWith())))
    t.equals(listed(s.winners()), '3,4', 'the pot did not go to the best side still standing')
end)


t.test('THE AUDIT: a side that has left entirely drops off everybody\'s tally', function()
    -- crimson leads 3-2-1 and both of its fighters leave. The round goes on
    -- between ash and bone, and the clock is going to give it to ash -- so
    -- "Crimson 3" at the top of the tally is a lead nobody can lose to.
    local s = withThirdTeam()
    s.playSides(6, threeWay)
    s.kill(3, 1); s.revive(3)
    s.kill(5, 1); s.revive(5)
    s.kill(6, 2); s.revive(6)
    s.kill(1, 3); s.revive(1)
    s.kill(2, 3); s.revive(2)
    s.kill(4, 5); s.revive(4)
    s.settle(1)
    t.equals(((s.hudOf(3) or {}).teamScores or {}).crimson, 3, 'the fixture did not put crimson on 3')

    -- ONE of the two leaves. Crimson is still in the round, and its banked
    -- kills still count and are still explained.
    s.drop(1)
    s.settle(1)
    local hud = s.hudOf(3)
    t.equals(hud.teamScores.crimson, 3,
        'a side with a fighter still in it lost its banked kills from the tally')
    t.equals((hud.departedScores or {}).crimson, 2, 'the banked kills are no longer explained')

    -- And the other. Nobody is left on crimson.
    s.drop(2)
    s.settle(1)
    hud = s.hudOf(3)
    t.isNil(hud.teamScores.crimson, 'a side that has left entirely still leads everybody\'s tally')
    t.equals(hud.teamScores.ash, 2, 'the sides still fighting lost their own numbers')
    t.equals(hud.teamScores.bone, 1, 'the sides still fighting lost their own numbers')
    t.isNil(hud.departedScores, 'kills banked by a side that has gone are still being explained')

    -- DOWN IS NOT GONE. Both bone fighters are waiting to respawn, and under
    -- a kill count nobody runs out of lives, so bone is still in the round.
    s.kill(5, 3)
    s.kill(6, 4)
    t.isFalse(s.rowOf(5).alive == true or s.rowOf(6).alive == true, 'the fixture did not put bone down')
    s.settle(1)
    hud = s.hudOf(3)
    -- Read off the board sent WITH that tally, because the respawn can land
    -- in the same step once the tally has gone out.
    local bone = {}
    for _, row in ipairs(hud.scoreboard or {}) do
        if row.team == 'bone' then bone[#bone + 1] = row.alive and 'up' or 'down' end
    end
    t.equals(table.concat(bone, ','), 'down,down', 'bone was not down when the tally went out, so this proves nothing')
    t.equals(hud.teamScores.bone, 1, 'a side waiting to respawn dropped off the tally')

    -- The tally and the clock agree about who is ahead.
    s.expire()
    s.settle(3)
    t.equals(listed(s.winners()), '3,4', 'the clock gave the round to a side the tally did not show leading')
end)


-- ======================================================================
-- LEAVING, AND WHAT THE HOST LEAVING DOES NOT DO
--
-- Asked for by the owner: "make it where anyone can leave even if the host
-- leaves it will not cancel the match". The second half was already true --
-- ArenaLobby.Leave hands the lobby on rather than closing it -- and that is
-- exactly why it is pinned here: a promise nothing tests is a promise the
-- next refactor gets to break quietly.
-- ======================================================================

t.test('the HOST leaving hands the lobby on rather than cancelling the match', function()
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'tdm', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    local before = s.lobby.Get(id)
    t.equals(before.hostSource, 1, 'the fixture did not make 1 the host')
    t.equals(s.lobby.PlayerCount(before), 4, 'the fixture did not seat four')

    t.isTrue(s.lobby.Leave(1, 'notify.you_left'), 'the host could not leave')

    local after = s.lobby.Get(id)
    t.isNotNil(after, 'THE HOST LEAVING CANCELLED THE MATCH')
    t.equals(s.lobby.PlayerCount(after), 3, 'the wrong number of fighters were left behind')
    t.isTrue(after.hostSource ~= 1, 'the departed host is still the host')
    t.isNotNil(after.players[after.hostSource], 'the lobby was handed to somebody not in it')
    t.equals(after.hostName, after.players[after.hostSource].name,
        'the heading still carries the name of the host who walked out')
end)

t.test('and it is only destroyed when the LAST player goes', function()
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'tdm', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    for _, src in ipairs({ 1, 2, 3 }) do
        s.lobby.Leave(src, 'notify.you_left')
        t.isNotNil(s.lobby.Get(id),
            ('the match died when %d left, with players still in it'):format(src))
    end

    s.lobby.Leave(4, 'notify.you_left')
    t.isNil(s.lobby.Get(id), 'an empty match was kept alive')
end)

t.test('a fighter may walk out of a LIVE round even holding a side bet', function()
    -- THE FIRST VERSION OF THIS TEST PROVED NOTHING, and its own mutation
    -- caught it. It set the round live and asserted MayLeave said yes -- which
    -- it does either way, because with the live-state line deleted the two
    -- guards below it do not fire for a live round either. Deleting the line
    -- under test left the test green.
    --
    -- WHAT THE LINE ACTUALLY BUYS is this case. A side bet held on a match
    -- refuses a leave -- that is `error.bet_then_leave`, and it is deliberate:
    -- backing a fighter and then walking out is a way to move a pot. It is a
    -- LOBBY rule. Once the round is running the bet is already placed and the
    -- money already committed, so holding somebody in the arena over it buys
    -- nothing and traps a player who wants out.
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'tdm', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    -- The bet is asserted through the same two calls MayLeave makes, so this
    -- cannot pass by the betting stub being switched off.
    s.env.ArenaBetting.IsEnabled = function() return true end
    s.env.ArenaBetting.HoldsSideBet = function(_, src) return src == 1 end
    t.isTrue(s.env.ArenaBetting.IsEnabled(), 'the fixture did not switch betting on')

    local row = s.lobby.Get(id)

    -- IN THE LOBBY the bet holds them, which is the control: without it, a
    -- pass below would not be telling us the live state is what freed them.
    row.state = 'lobby'
    local mayInLobby, lobbyWhy = s.lobby.MayLeave(1)
    t.isFalse(mayInLobby, 'a side-bet holder walked out of a LOBBY')
    t.equals(lobbyWhy, 'error.bet_then_leave', 'refused for the wrong reason')

    -- AND IN A LIVE ROUND they are free to go.
    row.state = 'live'
    local may, why = s.lobby.MayLeave(1)
    t.isTrue(may, ('a side-bet holder was trapped in a live round: %s'):format(tostring(why)))

    -- and somebody holding nothing is free either way
    t.isTrue(s.lobby.MayLeave(3), 'an ordinary fighter was held in a live round')
end)

t.test('/arenaleave is for ANY player in a match, not just the host', function()
    -- ASKED FOR IN THOSE WORDS: "make it where it's not just the host that can
    -- do /arenaleave it is any player in a match". It already was -- the
    -- handler checks for a console caller, a rate bucket and nothing else --
    -- and that is exactly why this test exists. A permission nobody asked for
    -- is one line, and an admin check added here later would read as tidying.
    --
    -- THE REAL HANDLER, not a copy of it. The fixture captures what
    -- server/main.lua registers, so this runs the function an operator's
    -- players run.
    local s = newServer()
    t.isNotNil(s.commands.arenaleave, '/arenaleave is not registered at all')

    local id = s.lobby.Create(1, 'trailerpark', 'tdm', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end
    t.equals(s.lobby.Get(id).hostSource, 1, 'the fixture did not make 1 the host')

    -- AN ORDINARY PLAYER FIRST, deliberately. A host-only gate fails here
    -- rather than three assertions later.
    s.commands.arenaleave(3)
    local row = s.lobby.Get(id)
    t.isNil(row.players[3], 'a non-host player could not leave with the command')
    t.equals(s.lobby.PlayerCount(row), 3, 'the wrong number of fighters were left behind')

    s.commands.arenaleave(4)
    row = s.lobby.Get(id)
    t.isNil(row.players[4], 'a second non-host player could not leave')

    -- AND THE HOST TOO, whose leaving still must not take the round with them.
    s.commands.arenaleave(1)
    row = s.lobby.Get(id)
    t.isNotNil(row, 'the host using the command cancelled the match')
    t.isNil(row.players[1], 'the host could not leave with the command')
    t.equals(row.hostSource, 2, 'the lobby was not handed on')
end)

t.test('and somebody in no match at all is told so rather than ignored', function()
    local s = newServer()
    local refusals = {}
    s.env.ArenaNotifyKey = function(src, key) refusals[#refusals + 1] = { src = src, key = key } end

    s.commands.arenaleave(6)

    t.equals(#refusals, 1, 'a player who is in no match was told nothing at all')
    t.equals(refusals[1].src, 6, 'the wrong player was answered')
    t.equals(refusals[1].key, 'error.not_in_match',
        'answered with something other than "you are not in a match"')
end)

-- ======================================================================
-- WHAT THE ROUND IS WON ON, ON THE SCREEN OF THE PLAYER FIGHTING IT
--
-- MEASURED by driving four fighters through a real score_limit round: the
-- round ends the instant a side reaches the limit, and the in-match overlay
-- named neither the limit nor anybody's total. It carried "Kills 4 Deaths 1"
-- and a per-player board, so a team racing to 25 had to add its own four
-- rows up in its head, every kill, under fire -- and under `most_kills`
-- nothing said the clock decides it on kills at all. `last_standing` was the
-- only rule the overlay expressed, and only by accident, through the
-- survivor count it already drew.
--
-- The numbers are read through the DECIDER'S OWN functions, so the figure a
-- player races cannot disagree with the figure that ends their round -- which
-- is what the third test here pins.
-- ======================================================================

t.test('a score_limit round tells every fighter the target', function()
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, false, { winCondition = 'score_limit', scoreLimit = 7 })
    s.kill(2, 1)
    s.settle(2)

    local hud = s.hudOf(1)
    t.isTrue(hud ~= nil, 'no overlay ever reached the player')
    t.equals(hud.winCondition, 'score_limit', 'the rule never reached the screen')
    t.equals(hud.scoreLimit, 7, 'the target never reached the screen')
end)

t.test('and a TEAM round carries both sides, counted the decider\'s way', function()
    -- THE NUMBER THAT ENDS THE ROUND AND THE NUMBER ON THE SCREEN ARE ONE
    -- NUMBER. reachedScoreLimit counts teamKills; so does this. A second
    -- tally assembled for the overlay is a second tally that can disagree
    -- with the one the round is stopped on.
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, true, { winCondition = 'score_limit', scoreLimit = 5 })
    s.kill(2, 1); s.revive(2)              -- crimson +1
    s.kill(4, 1); s.revive(4)              -- crimson +1
    s.kill(1, 2); s.revive(1)              -- ash     +1
    s.settle(2)

    local mine = s.hudOf(1)
    t.equals(mine.team, 'crimson', 'the overlay does not say which side is reading it')
    t.equals((mine.teamScores or {}).crimson, 2, 'crimson\'s total is wrong on the screen')
    t.equals((mine.teamScores or {}).ash, 1, 'ash\'s total is wrong on the screen')

    -- AND THE OTHER SIDE READS THE SAME TOTALS, tagged as themselves.
    local theirs = s.hudOf(2)
    t.equals(theirs.team, 'ash', 'the ash fighter is told they are on crimson')
    t.equals((theirs.teamScores or {}).crimson, 2, 'the two sides disagree about crimson')
end)

t.test('the figure on the screen is the figure the round is stopped on', function()
    -- Driven to one kill short, read, then over. A screen that said 4 while
    -- the server stopped the round at 5 would be worse than no screen.
    local s = newServer(function(c) c.Match.lives = 9 end)
    local id = s.play(4, true, { winCondition = 'score_limit', scoreLimit = 3 })
    s.kill(2, 1); s.revive(2)
    s.kill(4, 1); s.revive(4)
    s.settle(2)

    t.equals((s.hudOf(1).teamScores or {}).crimson, 2, 'the overlay is not one short')
    t.isTrue(s.lobby.Get(id) ~= nil, 'the round ended a kill early')

    s.kill(2, 1)
    s.settle(3)
    t.equals(s.endedWith(), 'match.ended_score_limit',
        'the round did not stop on the number the screen was counting to')
end)

t.test('a most_kills round says so, and names no target', function()
    -- The rule with nothing to count TO. A fighter under most_kills read the
    -- same overlay as one under last_standing and had no way to tell that
    -- staying alive is not what the round pays for.
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, false, { winCondition = 'most_kills' })
    s.settle(2)

    local hud = s.hudOf(1)
    t.equals(hud.winCondition, 'most_kills', 'the rule never reached the screen')
    t.isNil(hud.scoreLimit, 'a rule with no target advertised one')
end)

t.test('CONTROL: last_standing carries no target either', function()
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, false, { winCondition = 'last_standing' })
    s.settle(2)

    local hud = s.hudOf(1)
    t.equals(hud.winCondition, 'last_standing', 'the rule never reached the screen')
    t.isNil(hud.scoreLimit, 'last_standing advertised a score target')
    t.isNil(hud.teamScores, 'a mode with no teams sent team totals')
end)

t.test('CONTROL: a LADDER round sends none of it', function()
    -- `evaluate` skips both counting rules outright in a gun game, so a
    -- target on that overlay would be a number that ends nothing. The host
    -- here picks score_limit deliberately: the field is accepted on the
    -- match and must still be withheld from the screen.
    local s = newServer()
    s.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'gungame',
        entryFee = 0, account = 'cash', winCondition = 'score_limit', scoreLimit = 5 })
    local id = s.lobby.All()[1].id
    for src = 2, 4 do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
    for src = 1, 4 do s.fire('setReady', src, { ready = true }) end
    s.match.Start(id)
    s.settle(2)

    local hud = s.hudOf(1)
    t.isTrue(hud ~= nil, 'the gun game fixture never pushed an overlay')
    t.isTrue(#(hud.scoreboard or {}) > 0, 'the fixture is not really in a live round')
    t.isNil(hud.winCondition, 'a ladder round advertised a counting rule')
    t.isNil(hud.scoreLimit, 'a ladder round advertised a score target')
end)

-- ======================================================================
-- WALKING OUT SAYS SO
--
-- MEASURED by walking a player out of a lobby with the panel shut:
-- `/arenaleave` sent them NOTHING AT ALL. No toast, and no state push
-- either -- Broadcast reaches the roster and the panel-open list, and a
-- leaver is on neither -- so the only thing telling them the command had
-- worked was the absence of anything telling them it had not.
--
-- `notify.you_left` has been in the locale the whole time and has been
-- passed down this very call as the reason key. It reached the OTHER
-- players and the bet refunds, and never the person who typed it.
--
-- Joining answers "You are in." on exactly this line of exactly this
-- shape. Leaving was the one action a player could take and be told
-- nothing about.
-- ======================================================================

--- Every notification one player was sent, newest last, as plain text.
local function toldOnLeaving(s, src, leave)
    local before = #s.noticesTo(src)
    leave()
    local after = s.noticesTo(src)
    return after[#after], #after - before
end

t.test('/arenaleave answers the player who typed it', function()
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    local said, count = toldOnLeaving(s, 3, function() s.commands.arenaleave(3) end)
    t.isNil(s.lobby.Get(id).players[3], 'the fixture did not actually leave')
    t.equals(count, 1, 'the leaver was told nothing at all')
    t.equals(said, 'You are out of the arena.', 'the leaver was told the wrong thing')
end)

t.test('and so does the panel button, which is the same action', function()
    -- TWO ROUTES TO ONE ACTION ANSWER THE SAME WAY. A button that confirms
    -- and a command that does not is the shape a player reports as "the
    -- command is broken".
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    local said, count = toldOnLeaving(s, 3, function() s.fire('leaveMatch', 3) end)
    t.isNil(s.lobby.Get(id).players[3], 'the fixture did not actually leave')
    t.equals(count, 1, 'the leaver was told nothing at all')
    t.equals(said, 'You are out of the arena.', 'the two routes answer differently')
end)

t.test('a fighter who walks out of a LIVE round is answered too', function()
    -- The path that already changes the screen under them. The exit is a
    -- screen transition, not a sentence, and the two do not say the same
    -- thing twice.
    local s = newServer(function(c) c.Match.lives = 3 end)
    local id = s.play(4)

    local said = toldOnLeaving(s, 3, function() s.commands.arenaleave(3) end)
    t.isNil(s.lobby.Get(id).players[3], 'the fighter never left the live round')
    t.equals(said, 'You are out of the arena.', 'a live-round leaver was told nothing')
end)

t.test('CONTROL: a REFUSED leave is not reported as a successful one', function()
    -- The half that would turn this into a worse bug than the one it fixes.
    -- A player held by a side bet must read the refusal, not "You are out of
    -- the arena." while still standing in the lobby.
    local s = newServer()
    local id = s.lobby.Create(1, 'trailerpark', 'ffa', 0, 3, false, 'cash', 900)
    for src = 2, 4 do s.lobby.Join(src, id, nil, 'cash') end

    -- THE HOLD, STUBBED AT ITS SOURCE, the way the two tests above this one
    -- in this file already do it. Turning the Config switches on is NOT
    -- enough and the first version of this test proved nothing because of
    -- it: the flags were set, no stake was ever placed, MayLeave answered
    -- true, and the assertion sat inside an `if` that never ran.
    s.env.ArenaBetting.IsEnabled = function() return true end
    s.env.ArenaBetting.HoldsSideBet = function(_, src) return src == 2 end
    t.equals(s.lobby.MayLeave(2), false, 'the fixture did not actually hold player 2')

    local held = toldOnLeaving(s, 2, function() s.commands.arenaleave(2) end)
    t.isTrue(s.lobby.Get(id).players[2] ~= nil, 'the held player left anyway')
    t.isTrue(held ~= 'You are out of the arena.',
        'a refused leave was announced as a successful one')

    -- AND SOMEBODY IN NO MATCH AT ALL, which must not be congratulated on
    -- leaving one. This half needs no fixture and always runs.
    local said = toldOnLeaving(s, 6, function() s.commands.arenaleave(6) end)
    t.isTrue(said ~= 'You are out of the arena.',
        'a player who was never in a match was told they had left one')
end)

t.test('the kills of a fighter who left are named, not left unaccounted', function()
    -- THE BOARD AND THE LINE ABOVE IT DISAGREED, and both were right.
    -- teamKills BANKS a departing fighter's kills so a side does not lose
    -- its progress, and they still decide the round; the scoreboard lists
    -- who is HERE. So the rows added to 0 under a line that said 2, which a
    -- player reads as a broken score rather than a rule.
    local s = newServer(function(c) c.Match.lives = 9 end)
    local id = s.play(4, true, { winCondition = 'score_limit', scoreLimit = 9 })
    s.kill(2, 1); s.revive(2)        -- crimson's p1 takes two
    s.kill(4, 1); s.revive(4)
    s.settle(1)

    t.isNil(s.hudOf(3).departedScores, 'a round nobody left carried the clause anyway')

    s.fire('leaveMatch', 1, {})
    s.settle(2)

    local hud = s.hudOf(3)
    t.equals((hud.teamScores or {}).crimson, 2, 'the banked kills left the total')
    t.equals((hud.departedScores or {}).crimson, 2, 'the unaccounted kills were never named')

    -- AND THE ROWS REALLY DO NOT ADD UP, which is the whole reason the field
    -- exists. A fixture where they did would prove nothing.
    local onBoard = 0
    for _, row in ipairs(hud.scoreboard or {}) do
        if row.team == 'crimson' then onBoard = onBoard + row.kills end
    end
    t.equals(onBoard, 0, 'the fixture did not actually take the scorer off the board')
end)

t.test('and by every way out of a round, not just the button', function()
    -- Reachable three ways and the player cannot tell them apart.
    local function bankedAfter(exit)
        local s = newServer(function(c) c.Match.lives = 9 end)
        s.play(4, true, { winCondition = 'score_limit', scoreLimit = 9 })
        s.kill(2, 1); s.revive(2)
        s.settle(1)
        exit(s)
        s.settle(2)
        return ((s.hudOf(3) or {}).departedScores or {}).crimson
    end

    t.equals(bankedAfter(function(s) s.commands.arenaleave(1) end), 1, 'the command left it unaccounted')
    t.equals(bankedAfter(function(s) s.drop(1) end), 1, 'a disconnect left it unaccounted')
    t.equals(bankedAfter(function(s) s.fire('leaveMatch', 1, {}) end), 1, 'the button left it unaccounted')
end)

t.test('CONTROL: a leaver with NO kills adds no clause', function()
    -- Nothing to explain, so nothing is said. A field that answered for
    -- every departure would put a "(incl. 0 ...)" on an ordinary round.
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, true, { winCondition = 'score_limit', scoreLimit = 9 })
    s.kill(2, 1); s.revive(2)          -- p1 scores; p3 does not
    s.settle(1)
    s.fire('leaveMatch', 3, {})        -- the one with nothing to their name
    s.settle(2)

    t.isNil(s.hudOf(1).departedScores, 'a scoreless leaver produced a clause')
end)

t.test('CONTROL: free-for-all sends none of it', function()
    -- reachedScoreLimit reads the LIVE roster outside team mode, so a
    -- leaver's kills stop counting there and there is nothing to reconcile.
    -- A clause here would explain a gap that does not exist.
    local s = newServer(function(c) c.Match.lives = 9 end)
    s.play(4, false, { winCondition = 'score_limit', scoreLimit = 9 })
    s.kill(2, 1); s.revive(2)
    s.settle(1)
    s.fire('leaveMatch', 1, {})
    s.settle(2)

    local hud = s.hudOf(3)
    t.isNil(hud.teamScores, 'a mode with no teams sent team totals')
    t.isNil(hud.departedScores, 'a mode with no teams sent banked team kills')
end)

-- ======================================================================
-- THE PROPERTIES, OVER RANDOMISED ROUNDS
--
-- Every other test in this file names a case. These name a RULE and then
-- go looking for a round that breaks it: 150 rounds of randomised mode,
-- win condition, entry fee, lives, roster size, side bets, kills, walkouts
-- and disconnections, with the invariants checked after every single event
-- rather than only at the end.
--
-- IT FOUND A REAL DEFECT BEFORE IT WAS WRITTEN DOWN. The reconcile rule
-- below -- the scoreboard rows plus the kills banked from fighters who
-- left must equal the total the round is decided on -- is what caught the
-- overlay printing a team total the board underneath it could not account
-- for. No amount of reading either file raises that question.
--
-- TWO OF ITS FIRST FINDINGS WERE ITS OWN FAULT, and both are guarded
-- against here in the way the probe is built rather than in a comment:
--
--   NEGATIVE LIVES came from the probe putting ELIMINATED fighters back on
--   their feet, which nothing in the resource does. The elimination rule is
--   under test; a probe that bypasses it tests nothing. Only a fighter who
--   is still in is revived below.
--
--   MONEY "DESTROYED" came from asserting a closed system with no house. A
--   stake forfeited by walking out is kept deliberately -- server/betting.lua
--   says so at length and an admin stop is the one thing that unwinds it --
--   so the rule is that money is never CREATED, and never leaves except
--   where somebody walked out.
--
-- SEEDED, so a failure names a round that can be replayed exactly.
-- ======================================================================

local FUZZ_ROUNDS = 150
local FUZZ_MODES = { 'ffa', 'tdm', 'gungame' }
local FUZZ_CONDITIONS = { 'last_standing', 'score_limit', 'most_kills' }

--- One randomised round, returning every rule it broke.
--- @param seed integer
--- @return string[]
local function fuzzRound(seed)
    math.randomseed(seed)

    local broken = {}
    local function broke(rule, detail)
        broken[#broken + 1] = ('seed %d: %s -- %s'):format(seed, rule, detail)
    end

    local mode = FUZZ_MODES[math.random(#FUZZ_MODES)]
    local condition = FUZZ_CONDITIONS[math.random(#FUZZ_CONDITIONS)]
    local roster = math.random(2, 4)

    local s = newServer(function(config)
        config.Betting.enabled = true
        config.Match.lives = math.random(1, 4)
        config.Modes.gungame.enabled = true
    end)
    -- The ladder swaps a weapon and pays a supply on every promotion, and
    -- this file's ammo stub predates the mode.
    s.env.ArenaAmmo.SwapWeapon = function() return true end
    s.env.ArenaAmmo.GrantSupply = function() return true end

    local moneyBefore = s.moneyInCirculation()
    local somebodyWalkedOut = false

    local ok, err = pcall(function()
        s.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = mode, entryFee = math.random(0, 2) * 500,
            account = 'cash', winCondition = condition, scoreLimit = math.random(2, 5),
        })
        -- A create CAN be refused on purpose -- most_kills needs a clock --
        -- and a refused create is not a round to measure.
        local opened = s.lobby.All()[1]
        if not opened then return end
        local id = opened.id

        for src = 2, roster do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
        if mode == 'tdm' then
            for src = 1, roster do
                s.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        if math.random() < 0.5 then
            s.fire('spectateMatch', 5, { matchId = id })
            s.fire('placeSpectatorBet', 5, { matchId = id, pick = tostring(math.random(1, roster)),
                amount = math.random(1, 5) * 200, account = 'cash' })
        end
        for src = 1, roster do s.fire('setReady', src, { ready = true }) end
        s.match.Start(id)
        s.settle(1)

        for _ = 1, math.random(3, 12) do
            local live = s.lobby.Get(id)
            if not live or live.state ~= 'live' then break end

            local roll = math.random()
            local victim, killer = math.random(1, roster), math.random(1, roster)
            if roll < 0.70 then
                if victim ~= killer then s.match.OnDeath(victim, killer) end
                if math.random() < 0.6 then
                    local row = s.lobby.Get(id) and s.lobby.Get(id).players[victim]
                    -- STILL IN, or not at all. See the note above.
                    if row and (row.lives == nil or row.lives > 0) then row.alive = true end
                end
            elseif roll < 0.85 then
                s.fire('leaveMatch', victim, {}); somebodyWalkedOut = true
            else
                s.drop(victim); somebodyWalkedOut = true
            end
            s.settle(1)

            local now = s.lobby.Get(id)
            local hud = s.hudOf(1) or s.hudOf(2)
            if now and hud then
                if hud.remaining > hud.total then
                    broke('more fighters remaining than there are',
                        ('%d/%d'):format(hud.remaining, hud.total))
                end

                for _, row in ipairs(hud.scoreboard or {}) do
                    if row.kills < 0 or row.deaths < 0 then
                        broke('a negative score reached the board',
                            ('%s %d/%d'):format(tostring(row.name), row.kills, row.deaths))
                    end
                    if row.tiers and (row.tier < 1 or row.tier > row.tiers) then
                        broke('a tier outside the ladder reached the board',
                            ('%s/%s'):format(tostring(row.tier), tostring(row.tiers)))
                    end
                end

                -- THE RULE THAT CAUGHT THE DEFECT.
                for team, total in pairs(hud.teamScores or {}) do
                    local onBoard = 0
                    for _, row in ipairs(hud.scoreboard or {}) do
                        if row.team == team then onBoard = onBoard + row.kills end
                    end
                    local banked = (hud.departedScores or {})[team] or 0
                    if onBoard + banked ~= total then
                        broke('the board does not add up to the total above it',
                            ('%s: rows %d + banked %d ~= %d'):format(team, onBoard, banked, total))
                    end
                end

                if hud.winCondition and now.winCondition
                    and hud.winCondition ~= s.env.Arena.WinConditionFor(now.winCondition)
                then
                    broke('the overlay and the match disagree about the rule',
                        ('%s vs %s'):format(tostring(hud.winCondition), tostring(now.winCondition)))
                end

                -- The pot a player is shown is its own two halves added up:
                -- the bet screen reads the halves and the overlay the whole.
                local card = (s.lastState(1) or {}).matches
                card = card and card[1]
                if card and card.pot and card.entryPot and card.betPool
                    and card.pot ~= card.entryPot + card.betPool
                then
                    broke('the pot is not its own halves',
                        ('%d ~= %d + %d'):format(card.pot, card.entryPot, card.betPool))
                end

                for _, player in pairs(now.players or {}) do
                    if (player.lives or 0) < 0 then
                        broke('a fighter was driven below nought lives', tostring(player.lives))
                    end
                end
            end
        end

        local guard = 0
        while s.lobby.Get(id) and guard < 30 do
            local live = s.lobby.Get(id)
            if live.state == 'live' and guard == 10 then live.endsAt = os.time() - 1 end
            s.settle(1)
            guard = guard + 1
        end
        if s.lobby.Get(id) then
            broke('the round never ended', 'still open after thirty sweeps and a spent clock')
        end
    end)

    if not ok then broke('the round threw', tostring(err)) end

    local moneyAfter = s.moneyInCirculation()
    if moneyAfter > moneyBefore then
        broke('money was created', ('%+d'):format(moneyAfter - moneyBefore))
    end
    if moneyAfter < moneyBefore and not somebodyWalkedOut then
        broke('money left circulation with nobody having walked out',
            ('%+d'):format(moneyAfter - moneyBefore))
    end

    local stillHeld = 0
    for _, match in ipairs(s.lobby.All()) do
        stillHeld = stillHeld + (s.env.ArenaBetting.GetPrizePool(match.id) or 0)
    end
    if stillHeld > 0 then
        broke('a finished lobby is still holding stakes', tostring(stillHeld))
    end

    return broken
end

t.test(('the rules hold across %d randomised rounds'):format(FUZZ_ROUNDS), function()
    local broken = {}
    for seed = 1, FUZZ_ROUNDS do
        for _, entry in ipairs(fuzzRound(seed)) do broken[#broken + 1] = entry end
    end

    if #broken > 0 then
        local shown = {}
        for index = 1, math.min(5, #broken) do shown[index] = broken[index] end
        t.equals(#broken, 0, ('%d violation(s); first few: %s')
            :format(#broken, table.concat(shown, ' | ')))
    end
    t.equals(#broken, 0, 'the randomised rounds broke a rule')
end)

t.test('CONTROL: the randomised rounds really do reach a live round', function()
    -- A property test that silently created no matches would pass for ever.
    -- This measures that the generator actually gets fighters into an arena
    -- and kills happening, which is what every rule above is checked against.
    local sawLive, sawKills, sawLadder, sawTeams = false, false, false, false

    for seed = 1, 25 do
        math.randomseed(seed * 7)
        local s = newServer(function(config)
            config.Betting.enabled = true
            config.Match.lives = 3
            config.Modes.gungame.enabled = true
        end)
        s.env.ArenaAmmo.SwapWeapon = function() return true end
        s.env.ArenaAmmo.GrantSupply = function() return true end

        local mode = FUZZ_MODES[(seed % #FUZZ_MODES) + 1]
        s.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = mode,
            entryFee = 0, account = 'cash', winCondition = 'score_limit', scoreLimit = 9 })
        local opened = s.lobby.All()[1]
        if opened then
            for src = 2, 4 do s.fire('joinMatch', src, { matchId = opened.id, account = 'cash' }) end
            if mode == 'tdm' then
                for src = 1, 4 do
                    s.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
                end
            end
            for src = 1, 4 do s.fire('setReady', src, { ready = true }) end
            s.match.Start(opened.id)
            s.settle(1)
            local live = s.lobby.Get(opened.id)
            if live and live.state == 'live' then
                sawLive = true
                s.match.OnDeath(2, 1)
                s.settle(1)
                local hud = s.hudOf(1)
                if hud then
                    for _, row in ipairs(hud.scoreboard or {}) do
                        if row.kills > 0 then sawKills = true end
                        if row.tiers then sawLadder = true end
                    end
                    if hud.teamScores then sawTeams = true end
                end
            end
        end
    end

    t.isTrue(sawLive, 'the generator never got a round live')
    t.isTrue(sawKills, 'the generator never recorded a kill')
    t.isTrue(sawLadder, 'the generator never reached a ladder round')
    t.isTrue(sawTeams, 'the generator never reached a team round')
end)

-- ======================================================================
-- A HOSTILE CLIENT
--
-- Every other test in this file sends what the panel sends. This one sends
-- what a cheat sends: all 26 client-reachable events, each fired with a
-- battery of malformed and malicious payloads, by somebody with no right to
-- fire them, against three stages of round.
--
-- Nothing may throw (a handler that errors on a malformed payload is a
-- denial of service anybody can trigger), no money may be invented, and
-- nothing that belongs to the host or to another player may move.
--
-- THREE LESSONS ARE BUILT INTO ITS SHAPE, each learnt by an injected
-- vulnerability the first versions could not see:
--
--   AN OUTSIDER IS TOO WEAK AN ATTACKER. Somebody in no match is turned
--   away by "you are not in a match" long before any authority check is
--   reached, so a MISSING host check is invisible to them. The dangerous
--   attacker is an ordinary member of the round.
--
--   GARBAGE TESTS THE PARSING, NOT THE AUTHORITY. Malformed payloads stop
--   at the type guards. A request that is perfectly well formed and merely
--   sent by the wrong person is what a real cheat sends, and it is the only
--   shape that arrives at an authority check with something to change.
--
--   LAYERED DEFENCES MASK EACH OTHER. A live round refuses host-only
--   actions on STATE, and a PAID lobby refuses rule changes because people
--   have already staked -- for the host too -- both before authority is
--   consulted. A free lobby is the only world where the host check on the
--   rules is the thing actually doing the refusing.
-- ======================================================================

local HOSTILE_EVENTS = {
    'adminHours', 'adminReturn', 'adminRevive', 'adminState', 'adminStop', 'adminTool',
    'adminUnjam', 'adminWipe', 'cancelMatch', 'clientDebug', 'createMatch', 'holdCountdown',
    'joinMatch', 'leaveMatch', 'outlineReason', 'panelClosed', 'placeSpectatorBet',
    'reportDeath', 'requestState', 'setLoadout', 'setReady', 'setTeam', 'spectateMatch',
    'startMatch', 'stopSpectating', 'updateMatch',
}

--- The payload shapes, trimmed to the ones that discriminate. The full
--- battery took a third of this suite's whole runtime; these are the rows
--- that actually caught the injected holes, plus cheap insurance on strings.
local HOSTILE_PAYLOADS = {
    { name = 'nil', value = nil },
    { name = 'wrong types', value = {
        matchId = true, amount = 'lots', pick = false, account = 0,
        killer = 'someone', ready = 'yes', weapons = 'all' } },
    { name = 'negative numbers', value = {
        matchId = 'X', amount = -999999, pick = '1', account = 'cash',
        entryFee = -5000, scoreLimit = -1, lives = -1, killer = -1, ready = true } },
    { name = 'fractions', value = {
        matchId = 'X', amount = 0.5, pick = '1.5', account = 'cash',
        entryFee = 1.7, scoreLimit = 2.5, lives = 1.5, killer = 2.5, ready = true } },
    { name = 'nested tables', value = {
        matchId = {{{}}}, amount = {}, pick = {}, account = {}, killer = {},
        weapons = {{{{}}}} } },
    { name = 'hostile strings', value = {
        matchId = "'; DROP TABLE x;--", pick = '../../etc/passwd',
        account = '<script>', teamKey = '%s%s%s%n' } },
    -- THE ONE THAT TESTS AUTHORITY RATHER THAN PARSING.
    { name = 'WELL FORMED, wrong sender', value = {
        -- A REAL, ENABLED ARENA THAT IS NOT THE ONE THIS MATCH IS ON. The
        -- first version named 'pier', which does not exist on this server, so
        -- UpdateMatch refused it on 'error.arena_unavailable' and the
        -- arena-changing path was never reached at all -- a well-formed
        -- payload that could not actually change anything.
        matchId = 'X', arenaKey = 'skydome', modeKey = 'ffa', lives = 9, radar = true,
        roundTimeSeconds = 1200, winCondition = 'most_kills', scoreLimit = 2,
        teamKey = 'ash', ready = true, account = 'cash', amount = 200, pick = '1',
        killer = 1, entryFee = 0, weapons = { { key = 'rifle' } } } },
}

local HOSTILE_ATTACKERS = {
    { name = 'an outsider in no match', src = 6, insider = false },
    { name = 'a non-host member', src = 3, insider = true },
}

local HOSTILE_STAGES = {
    { name = 'a free lobby', live = false, fee = 0 },
    { name = 'a paid lobby', live = false, fee = 500 },
    { name = 'a live round', live = true, fee = 500 },
}

--- WALLETS PLUS ESCROW. Wallets alone is the wrong measure, and the first
--- run of this sweep proved it: a player leaving a lobby is refunded their
--- entry fee, their wallet rises, and nothing has been created -- the money
--- came out of the pot it was already in. Counting the pot makes a refund a
--- transfer and leaves only real invention showing.
local function systemTotal(s)
    local total = s.moneyInCirculation()
    for _, match in ipairs(s.lobby.All()) do
        total = total + (s.env.ArenaBetting.GetPrizePool(match.id) or 0)
    end
    return total
end

local function hostileWorld(live, fee)
    local s = newServer(function(config)
        config.Betting.enabled = true
        config.Match.lives = 3
    end)
    s.env.ArenaAmmo.SwapWeapon = function() return true end
    s.env.ArenaAmmo.GrantSupply = function() return true end

    s.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'tdm', entryFee = fee,
        account = 'cash', winCondition = 'score_limit', scoreLimit = 5 })
    local id = s.lobby.All()[1].id
    for src = 2, 3 do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
    for src = 1, 3 do
        s.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
    end
    if live then
        for src = 1, 3 do s.fire('setReady', src, { ready = true }) end
        s.match.Start(id)
        s.settle(1)
    end
    return s, id
end

--- Runs the whole sweep and returns everything it caught.
local function sweep()
    local caught = {}
    local probes = 0

    for _, stage in ipairs(HOSTILE_STAGES) do
        for _, attacker in ipairs(HOSTILE_ATTACKERS) do
            for _, event in ipairs(HOSTILE_EVENTS) do
                for _, shot in ipairs(HOSTILE_PAYLOADS) do
                    probes = probes + 1
                    local s, id = hostileWorld(stage.live, stage.fee)
                    local before = systemTotal(s)
                    local snap = s.lobby.Get(id)
                    local was = {
                        state = snap and snap.state, scoreLimit = snap and snap.scoreLimit,
                        arenaKey = snap and snap.arenaKey, modeKey = snap and snap.modeKey,
                        winCondition = snap and snap.winCondition, lives = snap and snap.lives,
                        host = snap and snap.hostSource, roster = {}, kills = {},
                    }
                    for src, row in pairs(snap and snap.players or {}) do
                        was.roster[src] = true
                        was.kills[src] = row.kills
                    end

                    local function caughtIt(what)
                        caught[#caught + 1] = ('[%s | %s] %s <- %s : %s')
                            :format(stage.name, attacker.name, event, shot.name, what)
                    end

                    -- The real match id, spliced in: a cheat reads it off
                    -- their own screen, so withholding it tests nothing.
                    local payload = shot.value
                    if type(payload) == 'table' and payload.matchId == 'X' then
                        payload.matchId = id
                    end

                    local ok, err = pcall(function() s.fire(event, attacker.src, payload) end)
                    if not ok then caughtIt('THREW: ' .. tostring(err)) end

                    if systemTotal(s) > before then
                        caughtIt(('money appeared: +%d'):format(systemTotal(s) - before))
                    end

                    local now = s.lobby.Get(id)
                    if now == nil then
                        caughtIt('DESTROYED THE MATCH')
                    else
                        if now.state ~= was.state then
                            caughtIt(('moved the round on: %s -> %s')
                                :format(tostring(was.state), tostring(now.state)))
                        end
                        -- THE GROUND AND THE GAME, which nothing here checked
                        -- until the well-formed payload was given values that
                        -- could really move them.
                        if now.arenaKey ~= was.arenaKey then
                            caughtIt(('moved the round to another arena: %s -> %s')
                                :format(tostring(was.arenaKey), tostring(now.arenaKey)))
                        end
                        if now.modeKey ~= was.modeKey then
                            caughtIt(('changed the mode: %s -> %s')
                                :format(tostring(was.modeKey), tostring(now.modeKey)))
                        end
                        if now.scoreLimit ~= was.scoreLimit then caughtIt('moved the kill limit') end
                        if now.winCondition ~= was.winCondition then caughtIt('changed how it is won') end
                        if now.lives ~= was.lives then caughtIt('changed the lives') end
                        if now.hostSource ~= was.host then caughtIt('TOOK THE MATCH OVER') end
                        if not attacker.insider and now.players[attacker.src] then
                            caughtIt('AN OUTSIDER GOT IN')
                        end
                        for src = 1, 3 do
                            if was.roster[src] and not now.players[src] and src ~= attacker.src then
                                caughtIt(('threw player %d out'):format(src))
                            end
                            local before2, after2 = was.kills[src], now.players[src] and now.players[src].kills
                            if before2 and after2 and after2 > before2 then
                                caughtIt(('conjured %d kill(s) for player %d')
                                    :format(after2 - before2, src))
                            end
                        end
                    end
                end
            end
        end
    end

    return caught, probes
end

t.test('a hostile client cannot crash, enrich itself or take what is not its own', function()
    local caught, probes = sweep()
    t.isTrue(probes >= 1000, ('the sweep barely ran: only %d probe(s)'):format(probes))

    if #caught > 0 then
        local head = {}
        for index = 1, math.min(4, #caught) do head[index] = caught[index] end
        t.equals(#caught, 0, ('%d hole(s); first few: %s')
            :format(#caught, table.concat(head, ' | ')))
    end
    t.equals(#caught, 0, 'the hostile sweep got through')
end)

t.test('EXPLOIT: a player cannot credit themselves for their own death', function()
    -- READ THE FIELD NAME TWICE. The first version of this test sent
    -- `killer`, and the handler reads `killerServerId` -- so it named nobody
    -- at all, measured a death with no claimed killer, and "proved" that kill
    -- farming was impossible. It was asserting something FALSE about the
    -- resource and would never have caught a regression. The control below
    -- is what would have caught it: a claim that DOES credit somebody, in the
    -- same fixture, so a refusal can be told apart from a payload that was
    -- never understood.
    local s = newServer(function(c) c.Match.lives = 99 end)
    local id = s.play(4, false, { winCondition = 'score_limit', scoreLimit = 99 })

    for _ = 1, 10 do
        s.fire('reportDeath', 3, { killerServerId = 3 })
        local row = s.lobby.Get(id) and s.lobby.Get(id).players[3]
        if row then row.alive = true end
    end

    t.equals(s.rowOf(3).kills, 0, 'a player bought kills off their own corpse')
    t.isTrue(s.rowOf(3).deaths > 0, 'the deaths themselves went unrecorded')

    -- THE CONTROL THAT MAKES THE ASSERTION ABOVE MEAN ANYTHING. Naming
    -- somebody else, through the same event and the same field, DOES credit
    -- them -- so the nought above is a refusal and not a payload the server
    -- quietly ignored.
    s.fire('reportDeath', 4, { killerServerId = 2 })
    t.equals(s.rowOf(2).kills, 1,
        'the fixture credits nobody at all, so the refusal above proves nothing')
end)

t.test('EXPLOIT: a killer who is not on the roster is refused', function()
    local s = newServer(function(c) c.Match.lives = 99 end)
    local id = s.play(4, false, { winCondition = 'score_limit', scoreLimit = 99 })

    -- Every kill on the roster, before and after. Asserting only that the
    -- outsider is absent from the roster was too weak: it passes even where
    -- the claim is honoured and the credit goes somewhere. What must be true
    -- is that naming somebody who is not fighting buys NOBODY anything.
    local function killsOnRoster()
        local tally = {}
        for src, row in pairs(s.lobby.Get(id).players) do tally[src] = row.kills end
        return tally
    end

    local before = killsOnRoster()
    s.fire('reportDeath', 3, { killerServerId = 6 })
    local after = killsOnRoster()

    t.isNil(s.lobby.Get(id).players[6],
        'naming an outsider as the killer let them into the round')
    for src, kills in pairs(after) do
        t.equals(kills, before[src] or 0,
            ('naming an outsider moved player %d\'s kill count'):format(src))
    end
    t.isTrue(s.rowOf(3).deaths > 0,
        'refusing the CREDIT turned into refusing the death, which strands the player')

    -- THE CONTROL, again: the same event with a real fighter named DOES
    -- credit, so the untouched counts above are a refusal and not a payload
    -- the fixture never understood.
    s.fire('reportDeath', 4, { killerServerId = 2 })
    t.equals(s.rowOf(2).kills, (before[2] or 0) + 1,
        'the fixture credits nobody at all, so the refusal above proves nothing')
end)

t.test('KNOWN AND ACCEPTED: two accomplices standing together can trade kills', function()
    -- NOT A DEFECT, AND WRITTEN DOWN HERE SO NOBODY "FIXES" IT BY ACCIDENT.
    -- resolveKiller says so itself: a dying client names its own killer, and
    -- the guard is the kill-distance ceiling, which "does not make the report
    -- honest -- two players standing together can still trade kills nobody
    -- fired -- but it forces them to be there, which costs them the round
    -- they are trying to win."
    --
    -- MEASURED: twenty self-reported deaths naming a neighbour bought that
    -- neighbour twenty kills. This test PINS that, so the day somebody
    -- tightens it the change is deliberate and this expectation is updated
    -- on purpose rather than a test quietly going green.
    --
    -- TWO THINGS SLOW IT ON A REAL SERVER AND NEITHER IS VISIBLE HERE: the
    -- rate limit on the event, which this fixture's clock jumps a minute per
    -- call and so never trips, and the respawn delay between deaths.
    local s = newServer(function(c) c.Match.lives = 99 end)
    local id = s.play(4, false, { winCondition = 'score_limit', scoreLimit = 99 })

    for _ = 1, 20 do
        s.fire('reportDeath', 3, { killerServerId = 2 })
        local row = s.lobby.Get(id) and s.lobby.Get(id).players[3]
        if row then row.alive = true end
    end

    t.equals(s.rowOf(2).kills, 20,
        'the close-range trade stopped working -- if that was deliberate, update this test')
    t.equals(s.rowOf(3).deaths, 20, 'the deaths paid for those kills went unrecorded')
end)

-- ======================================================================
-- WHAT THE RESOURCE IS STILL HOLDING AFTER A LONG DAY
--
-- A FiveM resource is a PROCESS that runs for days. Every test above asks
-- whether one round is correct; this one asks whether ten thousand rounds
-- leave anything behind. A per-player table that fills and never drains is
-- invisible in every functional test ever written and takes the server down
-- on a Saturday night.
--
-- The tables are found by INTROSPECTION rather than by a list somebody has
-- to remember to update: every table held as an upvalue by any exported
-- function of any module is long-lived by definition, so a new one added
-- next year is tracked the day it appears without anybody touching this.
-- ======================================================================

--- Every table that lives for the resource's uptime, by module and name.
local function longLivedTables(s)
    local found, seen = {}, {}
    local modules = {
        lobby = s.env.ArenaLobby, match = s.env.ArenaMatch,
        betting = s.env.ArenaBetting, ammo = s.env.ArenaAmmo,
        dispatch = s.env.ArenaDispatch, stats = s.env.ArenaStats,
    }

    local function harvest(label, fn)
        if type(fn) ~= 'function' then return end
        local index = 1
        while true do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if type(value) == 'table' and name ~= '_ENV' and not seen[value] then
                seen[value] = true
                found[#found + 1] = { key = label .. '.' .. name, table = value }
            end
            index = index + 1
        end
    end

    for module, exports in pairs(modules) do
        if type(exports) == 'table' then
            for _, fn in pairs(exports) do harvest(module, fn) end
        end
    end
    harvest('util', s.env.ArenaRateLimit)

    table.sort(found, function(a, b) return a.key < b.key end)
    return found
end

--- THE FIXTURE'S OWN RECORDERS, which accumulate ON PURPOSE so tests above
--- can read what the match told them. They are this file's tables, not the
--- resource's, and counting them as leaks would make this test cry wolf on
--- every run. Named rather than pattern-matched so adding a recorder without
--- thinking about it fails here.
local FIXTURE_RECORDERS = {
    ['dispatch.downCleared'] = true,
    ['stats.recorded'] = true,
}

local function countOf(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

t.test('a long day of rounds leaves nothing behind', function()
    local s = newServer(function(config)
        config.Betting.enabled = true
        config.Match.lives = 1
    end)
    s.env.ArenaAmmo.SwapWeapon = function() return true end
    s.env.ArenaAmmo.GrantSupply = function() return true end

    local tracked = longLivedTables(s)
    t.isTrue(#tracked >= 10,
        ('introspection found only %d long-lived table(s) -- it has stopped working')
            :format(#tracked))

    local atRest = {}
    for _, entry in ipairs(tracked) do atRest[entry.key] = countOf(entry.table) end

    -- Sixty complete lifecycles, with panels opened and shut, entry fees
    -- paid, fighters walking out and fighters disconnecting mid-round --
    -- every path that puts a player into a table somebody has to take them
    -- out of again.
    local peak = 0
    for round = 1, 60 do
        for src = 1, 6 do s.fire('requestState', src, { panel = true }) end
        s.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa',
            entryFee = 500, account = 'cash' })
        local id = s.lobby.All()[1].id
        for src = 2, 4 do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
        for src = 1, 4 do s.fire('setReady', src, { ready = true }) end
        s.match.Start(id)
        s.settle(1)

        -- THE HIGH-WATER MARK, so this test can prove the tables FILL. One
        -- that measured nought throughout would pass on a resource that had
        -- stopped tracking anything at all.
        for _, entry in ipairs(tracked) do
            if not FIXTURE_RECORDERS[entry.key] then
                peak = math.max(peak, countOf(entry.table) - (atRest[entry.key] or 0))
            end
        end

        if round % 3 == 0 then s.fire('leaveMatch', 4, {}) end
        if round % 5 == 0 then s.drop(3) end
        s.kill(2, 1); s.settle(1); s.kill(3, 1); s.kill(4, 1)
        s.settle(5)
        for src = 1, 6 do s.fire('panelClosed', src, {}) end
    end

    for src = 1, 6 do s.drop(src) end
    s.settle(5)

    t.isTrue(peak > 0,
        'no tracked table ever filled, so draining to nought proves nothing')

    local held = {}
    for _, entry in ipairs(tracked) do
        if not FIXTURE_RECORDERS[entry.key] then
            local now = countOf(entry.table)
            local was = atRest[entry.key] or 0
            if now > was then
                held[#held + 1] = ('%s %d -> %d'):format(entry.key, was, now)
            end
        end
    end

    t.equals(#held, 0, ('still holding after sixty rounds: %s')
        :format(table.concat(held, ', ')))
end)

t.test('CONTROL: the leak check can actually see a table that does not drain', function()
    -- A leak test that cannot fail is the most reassuring useless thing in a
    -- suite. This plants a table that fills and never empties, on the same
    -- introspection path the test above uses, and requires it to be caught.
    local s = newServer()
    local planted = {}
    -- Held as an upvalue of an exported function, which is exactly how every
    -- real long-lived table in the resource is held.
    s.env.ArenaLobby.LeakForTest = function(src) planted[src] = true end

    local tracked = longLivedTables(s)
    local sawIt = false
    for _, entry in ipairs(tracked) do
        if entry.table == planted then sawIt = true end
    end
    t.isTrue(sawIt, 'introspection missed a table held exactly the way the real ones are')

    for src = 1, 25 do s.env.ArenaLobby.LeakForTest(src) end
    t.equals(countOf(planted), 25, 'the planted table did not fill')

    -- and nothing anywhere empties it, which is the whole point
    for src = 1, 6 do s.drop(src) end
    t.isTrue(countOf(planted) > 0, 'the planted leak drained itself, so it proves nothing')
end)

t.test('the clock the opening hours are kept in is the operator\'s to name', function()
    -- THE PANEL CANNOT WORK IT OUT AND MUST NOT GUESS. offsetHours says how
    -- far to move the SERVER'S clock and nothing anywhere says what that
    -- clock is set to, so -5 is EST on a UTC box and something else on any
    -- other. The shut screen printed "EST" flat: true by coincidence, and
    -- silently wrong the first time the offset or the host changed.
    local s = newServer(function(config)
        config.Schedule.enabled = true
        config.Schedule.timezoneLabel = 'UK time'
    end)

    t.equals(s.env.ArenaHoursSnapshot().timezoneLabel, 'UK time',
        'the operator\'s label never reached the panel')
end)

t.test('CONTROL: no label is sent where none was written', function()
    -- The honest fallback: with nothing configured the panel lists the hours
    -- and claims no timezone. A field that always carried something would put
    -- an invented clock on a locked-out player's screen.
    local blank = newServer(function(config)
        config.Schedule.enabled = true
        config.Schedule.timezoneLabel = ''
    end)
    local gone = newServer(function(config)
        config.Schedule.enabled = true
        config.Schedule.timezoneLabel = nil
    end)

    t.isNil(blank.env.ArenaHoursSnapshot().timezoneLabel, 'an empty label was sent as one')
    t.isNil(gone.env.ArenaHoursSnapshot().timezoneLabel, 'a missing label was invented')
end)

t.test('and a label that is not text is withheld AND reported at boot', function()
    -- Withholding it alone would be a silent repair: the screen stops naming
    -- the clock and nobody is told why. Both halves are asserted.
    local s = newServer(function(config)
        config.Schedule.enabled = true
        config.Schedule.timezoneLabel = 5
    end)

    t.isNil(s.env.ArenaHoursSnapshot().timezoneLabel, 'a number was sent as a timezone')

    local said = false
    for _, problem in ipairs(s.env.Arena.ValidateConfig()) do
        if tostring(problem):find('timezoneLabel', 1, true) then said = true end
    end
    t.isTrue(said, 'a mistyped label was repaired silently, with nothing said at boot')
end)

t.test('and the label is checked even with the hours switched OFF', function()
    -- A label typed wrong today is still typed wrong the day the gate is
    -- switched on, and that is the day it matters. The shipped config keeps
    -- the gate off, so a check that only ran when it was on would never see
    -- this server's own label at all.
    local s = newServer(function(config)
        config.Schedule.enabled = false
        config.Schedule.timezoneLabel = {}
    end)

    local said = false
    for _, problem in ipairs(s.env.Arena.ValidateConfig()) do
        if tostring(problem):find('timezoneLabel', 1, true) then said = true end
    end
    t.isTrue(said, 'the label went unchecked because the gate was off')
end)

-- ======================================================================
-- THE REPORT AN OPERATOR CAN ASK FOR
--
-- WeaponItemReport ran once, at boot, and nowhere else -- while the
-- ATTACHMENT report beside it had always been on /arenaconsole and the
-- admin tablet. That is backwards, and the boot thread that runs the pair
-- says why in its own words: a missing weapon item empties the whole
-- loadout, a missing attachment costs a scope.
--
-- IT IS ASKED AGAIN BECAUSE THE ANSWER CHANGES. Adding a weapon to
-- config.weapons.lua, installing or dropping a weapon addon, or updating
-- ox_inventory all change it, and the only way to find out whether the
-- arena could still arm anybody was to restart the server and scroll back
-- for a line printed thirty seconds in. That is a poor answer for any
-- operator and no answer at all for one who cannot watch a round.
-- ======================================================================

t.test('/arenaconsole reports the issued items, not just the attachments', function()
    local s = newServer()
    t.isNotNil(s.commands.arenaconsole, '/arenaconsole is not registered at all')

    local before = #s.console
    -- Source 0 is the server console, which the command answers without an ace.
    s.commands.arenaconsole(0, {}, '/arenaconsole')

    local titles = {}
    for index = before + 1, #s.console do
        local title = tostring(s.console[index]):match('arenaconsole: %-%-%-%- (.+) %-%-%-%-')
        if title then titles[#titles + 1] = title end
    end

    local sawItems, sawAttachments = nil, nil
    for index, title in ipairs(titles) do
        if title == 'Issued items' then sawItems = index end
        if title == 'Attachments' then sawAttachments = index end
    end

    t.isNotNil(sawItems, 'the issued-items report is still only printed at boot: '
        .. table.concat(titles, ', '))

    -- AND BEFORE THE SMALLER FAILURE, the same order the boot thread reads
    -- them in. A report buried under the one that matters less is a report an
    -- operator scrolls past.
    t.isNotNil(sawAttachments, 'the attachment report went missing')
    t.isTrue(sawItems < sawAttachments,
        'the whole-loadout failure is printed after the missing-scope one')
end)

t.test('and the tablet offers it as a tool of its own', function()
    -- The panel draws whatever the server lists, so a tool that reaches
    -- /arenaconsole and not the tablet is a tool half the operators never
    -- find. Both read the SAME function, so they cannot disagree about what
    -- this ox_inventory has.
    local s = newServer()
    local before = #s.console
    s.commands.arenaconsole(0, {}, '/arenaconsole')

    local counted
    for index = before + 1, #s.console do
        local n = tostring(s.console[index]):match('arenaconsole: (%d+) report%(s%) above')
        if n then counted = tonumber(n) end
    end

    t.isNotNil(counted, 'the console never said how many reports it took')
    t.equals(counted, 7, 'the tool list changed size unexpectedly -- was a report added or lost?')
end)

os.exit(t.summary())
