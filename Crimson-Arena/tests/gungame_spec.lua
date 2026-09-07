--[[
    crimson_arena/tests/gungame_spec.lua

    GUN GAME: THE LADDER, PLAYED.

    Every kill moves you one rung up a fixed weapon ladder; finish the ladder
    and you have won the round outright. Knife somebody and they drop a rung,
    which is the comeback rule that makes the leader the one everybody hunts.

    THE MODE SHIPS OFF, so almost none of this runs on a default server --
    which is exactly why it needs its own file. A mode nobody tests is a mode
    that breaks the first time an operator turns it on, and "setting this to
    true is the whole of turning it on" is a promise config.lua makes.

    FIFTEEN TESTS, on deliberately different parts of it:

      THE LADDER ITSELF    what a rung is worth, what a broken rung does, and
                           what an empty ladder falls back to.
      CLIMBING             the arithmetic from score to rung, derived rather
                           than counted, and what happens on the top rung.
      THE KNIFE            demotion, its floor, and that it never edits a
                           kill that really happened.
      WINNING              a finished ladder ends the round over every other
                           win condition, including the clock.
      THE PLUMBING         the weapon item really swaps, the scoreboard
                           carries the rung, the round resets it, and an
                           unverified kill climbs nothing.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('gungame_spec')

local IDS = { 1, 2, 3, 4 }

--- A server with gun game switched ON, which no shipped config does.
--- @param mutate fun(config: table)?
local function newServer(mutate)
    local players = {}
    for _, id in ipairs(IDS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = 50000, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents = {}, {}, {}
    local swaps = {}
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
        -- RECORDED, because "the ladder gave them the weapon" is the half of
        -- this feature that a notification cannot prove. On an ox_inventory
        -- server the item IS the weapon, so a rung change that does not
        -- reach here changed nothing a player can hold.
        ArenaAmmo = {
            IsEnabled = function() return true end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            SwapWeapon = function(src, matchId, remove, add, rounds)
                swaps[#swaps + 1] = { src = src, matchId = matchId,
                    remove = remove, add = add, rounds = rounds }
                return true
            end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return true end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    -- THE SWITCH THIS WHOLE FILE IS ABOUT.
    env.Config.Modes.gungame.enabled = true
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Match.lives = 99          -- nobody is eliminated by accident
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, swaps = swaps,
        lobby = env.ArenaLobby, match = env.ArenaMatch, arena = env.Arena }
    local matchId

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- Opens and starts a gun game with `count` fighters.
    function server.play(count)
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'gungame', entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do server.fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src = 1, count do server.fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    function server.row(src) return server.lobby.Get(matchId).players[src] end
    function server.kill(victim, killer) server.match.OnDeath(victim, killer) end

    --- Puts a fighter back on their feet, the way the scheduled respawn
    --- does. OnDeath refuses a victim who is not alive -- correctly -- so a
    --- test that kills the same player twice without this delivers only the
    --- first blow and quietly proves nothing about the second.
    function server.revive(src) server.row(src).alive = true end
    function server.settle(times) for _ = 1, (times or 1) do threads.step() end end
    function server.matchId() return matchId end

    --- The ladder height this config actually plays, read the way the server
    --- reads it -- through the enabled catalogue, not off the config list.
    function server.rungCount()
        local playable = 0
        for _, key in ipairs(server.config.Modes.gungame.gunGameLadder) do
            if server.arena.GetWeaponByKey(key) then playable = playable + 1 end
        end
        return playable
    end

    function server.told(target)
        local said = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == target then
                said[#said + 1] = tostring((message.payload or {}).description or '')
            end
        end
        return table.concat(said, '\n')
    end

    function server.endedWith()
        for _, line in ipairs(console) do
            local reason = tostring(line):match('match %S+ ended: (%S+)')
            if reason then return reason end
        end
        return nil
    end

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

    function server.board()
        for index = #sent, 1, -1 do
            local message = sent[index]
            if message.event == 'crimson_arena:client:matchHud' and message.payload then
                return message.payload.scoreboard
            end
        end
        return nil
    end

    return server
end

-- ======================================================================
-- 1-3. THE LADDER ITSELF
-- ======================================================================

t.test('1. the mode ships OFF, which is what makes the rest of this matter', function()
    -- Read off the shipped config rather than the fixture's, so this is a
    -- statement about what an operator downloads.
    local shipped = Sandbox.shippedConfig()
    t.isFalse(shipped.Modes.gungame.enabled,
        'gun game now ships on -- every other test here runs a config nobody has')
    t.isTrue(type(shipped.Modes.gungame.gunGameLadder) == 'table'
        and #shipped.Modes.gungame.gunGameLadder > 1,
        'the shipped ladder is missing or too short to climb')
end)

t.test('2. and turning it on is the whole of turning it on', function()
    -- config.lua promises exactly this. A mode that needs a second step is
    -- a mode that will be reported broken.
    local server = newServer()
    local matchId = server.play(2)

    local live = server.lobby.Get(matchId)
    t.equals(live.modeKey, 'gungame', 'the match did not open on the mode that was asked for')
    t.equals(live.state, 'live', 'a gun game could not be started at all')
end)

t.test('3. a rung naming a weapon that is not enabled is dropped, not fatal', function()
    -- Promoting somebody onto a rung with no weapon on it would put them in
    -- the arena empty-handed; refusing to run would punish a full lobby for
    -- one typo. So the ladder is that much shorter and the round plays.
    local server = newServer(function(config)
        config.Modes.gungame.gunGameLadder = { 'pistol', 'not_a_weapon', 'smg' }
    end)
    server.play(2)

    t.equals(server.rungCount(), 2, 'the invented rung was not dropped from the ladder')
    t.equals(server.row(1).rung, 1, 'the round did not start anybody on the bottom rung')
end)

-- ======================================================================
-- 4-7. CLIMBING
-- ======================================================================

t.test('4. everybody starts on rung one, holding that rung and nothing they picked', function()
    local server = newServer()
    server.play(2)

    local row = server.row(1)
    t.equals(row.rung, 1, 'a fighter did not start on the bottom rung')
    t.equals(#row.loadout.weapons, 1, 'the ladder handed out more than the rung')
    t.equals(row.loadout.weapons[1].key, server.config.Modes.gungame.gunGameLadder[1],
        'the bottom rung is not the first weapon on the ladder')
end)

t.test('5. a kill moves the killer up exactly one rung', function()
    local server = newServer()
    server.play(2)

    server.kill(2, 1)

    t.equals(server.row(1).rung, 2, 'a kill did not move the killer up the ladder')
    t.equals(server.row(2).rung, 1, 'dying moved the victim')
end)

t.test('6. and the rung is DERIVED from the score, so two kills in one tick move two rungs', function()
    -- Never counted up. Two kills landing between one sweep and the next
    -- must move once per rung and never twice, and a kill the server refused
    -- to credit must not leave anybody standing above what they earned.
    local server = newServer()
    server.play(3)

    server.kill(2, 1)
    server.kill(3, 1)

    t.equals(server.row(1).rung, 3, 'two kills did not put the killer two rungs up')
end)

t.test('7. and a kill made ON the top rung finishes the ladder rather than overflowing', function()
    local server = newServer()
    server.play(2)
    local top = server.rungCount()

    -- One kill short of the top, then the one that finishes it.
    server.row(1).kills = top - 1
    server.kill(2, 1)

    t.equals(server.row(1).rung, top, 'the killer went past the end of the ladder')
    t.isTrue(server.row(1).ladderFinished, 'the last rung did not finish the ladder')
end)

-- ======================================================================
-- 8-10. THE KNIFE
-- ======================================================================

t.test('8. a melee kill knocks the victim back down a rung', function()
    -- The comeback rule. Without it the leader simply runs away with it.
    local server = newServer()
    server.play(2)

    -- Put the killer on the melee rung and the victim partway up.
    local top = server.rungCount()
    server.row(1).kills = top - 1
    server.kill(2, 1)                       -- 1 climbs to the top (melee) rung
    server.revive(2)
    server.row(2).kills = 3
    server.kill(2, 1)                       -- and knifes 2

    t.equals(server.row(2).rungsLost, 1, 'a knifed player lost no rung')
    t.equals(server.row(2).rung, 3, 'the knifed player did not drop exactly one rung')
end)

t.test('9. but a knife never edits a kill that really happened', function()
    -- The scoreboard, the leaderboard and the payout all read `kills`.
    -- Moving somebody down by deleting one would quietly rewrite history,
    -- so the ladder keeps its own number.
    local server = newServer()
    server.play(2)
    local top = server.rungCount()

    server.row(1).kills = top - 1
    server.kill(2, 1)
    server.revive(2)
    server.row(2).kills = 3
    server.kill(2, 1)

    t.equals(server.row(2).kills, 3, 'a demotion deleted a kill the player had really scored')
end)

t.test('10. and nobody is ever knocked below the bottom rung', function()
    local server = newServer()
    server.play(2)
    local top = server.rungCount()

    server.row(1).kills = top - 1
    server.kill(2, 1)                       -- 1 is on the melee rung

    for _ = 1, 5 do
        server.revive(2)
        server.kill(2, 1)
    end                                     -- knifed five times on rung 1

    t.equals(server.row(2).rung, 1, 'a knifed player was pushed below the bottom rung')
    t.isTrue((server.row(2).rungsLost or 0) <= 1,
        'a player already at the bottom kept losing rungs they did not have')
end)

t.test('11. and the knife does nothing when the operator switches it off', function()
    local server = newServer(function(config)
        config.Modes.gungame.demoteOnMelee = false
    end)
    server.play(2)
    local top = server.rungCount()

    server.row(1).kills = top - 1
    server.kill(2, 1)
    server.revive(2)
    server.row(2).kills = 3
    server.kill(2, 1)

    t.equals(server.row(2).rungsLost or 0, 0, 'the demotion ran with the setting off')
end)

-- ======================================================================
-- 12-13. WINNING
-- ======================================================================

t.test('12. a finished ladder ends the round, and the climber takes it', function()
    local server = newServer()
    server.play(3)
    local top = server.rungCount()

    server.row(2).kills = top - 1
    server.kill(3, 2)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_ladder', 'the finished ladder did not end the round')
    t.equals(table.concat(server.winners(), ','), '2', 'the climber did not win it')
end)

t.test('13. and it beats the clock, which would otherwise have decided it', function()
    -- Gun game IS its own win condition: 'score_limit' would settle a ladder
    -- race on a number nobody in it is playing for, and the clock would
    -- crown somebody else while the ladder was already finished.
    local server = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 1
    end)
    server.play(3)
    local top = server.rungCount()

    -- Fighter 3 is well past the score limit, so score_limit would pick
    -- them; fighter 2 finishes the ladder in the same sweep.
    server.row(3).kills = 50
    server.row(2).kills = top - 1
    server.kill(1, 2)
    server.settle(3)

    t.equals(server.endedWith(), 'match.ended_ladder',
        'the score limit decided a gun game')
    t.equals(table.concat(server.winners(), ','), '2', 'the ladder climber did not take it')
end)

-- ======================================================================
-- 14-15. THE PLUMBING
-- ======================================================================

t.test('14. the weapon ITEM really swaps, which is the half a toast cannot prove', function()
    -- On an ox_inventory server the item IS the weapon: a rung change that
    -- does not reach ArenaAmmo.SwapWeapon changed the server's idea of what
    -- somebody is holding and never their hands. That is exactly how the
    -- old gun game shipped -- it sent a client event nothing listened for.
    local server = newServer()
    server.play(2)

    server.kill(2, 1)

    local swap = server.swaps[#server.swaps]
    t.isNotNil(swap, 'climbing a rung swapped no weapon item at all')
    t.equals(swap.src, 1, 'the weapon went to the wrong player')
    t.equals(swap.add, server.row(1).loadout.weapons[1].weapon,
        'the item handed over is not the rung the player is standing on')
    t.isTrue(Sandbox.locale ~= nil, 'sanity')
end)

t.test('15. the scoreboard carries the rung, the round resets it, and a bad claim climbs nothing', function()
    local server = newServer()
    local matchId = server.play(2)

    -- The board everybody already looks at is where a gun game is read.
    server.kill(2, 1)
    server.settle(1)
    local board = server.board()
    t.isNotNil(board, 'no scoreboard was ever pushed')
    local mine
    for _, row in ipairs(board) do if row.id == 1 then mine = row end end
    t.isNotNil(mine, 'the climber is not on the board')
    t.equals(mine.rung, 2, 'the board does not carry the rung')
    t.equals(mine.rungs, server.rungCount(), 'the board does not carry the ladder height')

    -- An unverified kill claim credits nothing, so it can climb nothing:
    -- a client naming somebody who is not in the match must not move them.
    local before = server.row(1).rung
    server.match.OnDeath(2, 4242)
    t.equals(server.row(1).rung, before, 'an unverified kill claim moved somebody up the ladder')

    -- And a new round starts everybody back at the bottom. Rows are reused
    -- between rounds, so a finisher would otherwise open the next one
    -- holding the top rung and already flagged as having won it.
    local live = server.lobby.Get(matchId)
    live.state = 'lobby'
    server.match.Start(matchId)
    server.settle(1)
    t.equals(server.row(1).rung, 1, 'a new round did not put the climber back on rung one')
    t.equals(server.row(1).rungsLost or 0, 0, 'a new round kept the rungs a knife had cost')
    t.isTrue(server.row(1).ladderFinished ~= true, 'a new round started somebody already finished')
end)

os.exit(t.summary())
