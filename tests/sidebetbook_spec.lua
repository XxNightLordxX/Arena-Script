--[[
    crimson_arena/tests/sidebetbook_spec.lua

    THE BREAKDOWN THE PANEL DRAWS THE BOOK FROM.

    GetSideBetPool has always told the panel how much is riding on a match.
    It never said how that money was SPLIT, so the Bets tab could not answer
    the one question a bettor has to answer before staking anything: is there
    anybody on the other side? On a pool server a winning bet is paid out of
    the losing stakes and out of nothing else, so backing a side nobody has
    bet against pays back the stake and not a penny more.

    ArenaBetting.SideBetTotals is that breakdown, and the property that
    matters is not that it is roughly right -- it is that it is built from
    the SAME filter as the total drawn beside it. A reader adds the parts up
    and expects the whole. These pin that: every case that changes the pool
    has to change the breakdown the same way, and the two are asserted
    against each other rather than against hand-written numbers.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = cash },
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

    --- How much has been sent so far, so a test can ask what happened AFTER
    --- a call rather than at any point in the round. Taking a stake and
    --- placing a bet both post their own toast on the way in, so a search
    --- of the whole session finds those instead of the settlement.
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

--- The same two fighters, plus a watcher (3) with a wallet who is not in
--- the match and can therefore place an ordinary spectator side-bet.
local function withWatcher(fee, mutate)
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        config.Betting.entryFee.enabled = fee > 0
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = fee
        if mutate then mutate(config) end
    end)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, fee, nil, nil, 'cash')
    t.isNotNil(matchId, 'the match could not be created: ' .. tostring(err))
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the second fighter could not join')
    return s, matchId
end

--- The breakdown, and the total it is drawn beside, asked for together.
--- @return table byPick, integer pool, integer sum
local function book(s, matchId)
    local byPick = s.betting.SideBetTotals(matchId)
    local sum = 0
    for _, amount in pairs(byPick) do sum = sum + amount end
    return byPick, s.betting.GetSideBetPool(matchId), sum
end

-- ========================================================================
-- THE PARTS ADD UP TO THE WHOLE
-- ========================================================================

t.test('the breakdown sums to the pool it is shown beside', function()
    local s, matchId = withWatcher(0)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))

    local byPick, pool, sum = book(s, matchId)
    t.equals(byPick['1'], 2000, 'the stake did not land on the side it backed')
    t.equals(sum, pool, 'THE PARTS DO NOT ADD UP TO THE TOTAL BESIDE THEM')
end)

t.test('two bets on the same side are one figure, not two', function()
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000, [4] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        config.Betting.entryFee.enabled = false
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, 0, nil, nil, 'cash')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'))

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))
    t.isTrue(s.betting.PlaceSpectatorBet(4, matchId, 1, 500, 'cash'))

    local byPick, pool, sum = book(s, matchId)
    t.equals(byPick['1'], 2500, 'two backers of one side were not added together')
    t.equals(sum, pool, 'the parts stopped adding up once a side had two backers')
end)

t.test('money on opposite sides is kept apart', function()
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000, [4] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        config.Betting.entryFee.enabled = false
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, 0, nil, nil, 'cash')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'))

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))
    t.isTrue(s.betting.PlaceSpectatorBet(4, matchId, 2, 800, 'cash'))

    local byPick, pool, sum = book(s, matchId)
    t.equals(byPick['1'], 2000)
    t.equals(byPick['2'], 800)
    t.equals(sum, pool, 'the parts do not add up with both sides backed')
end)

t.test('a match nobody has bet on is empty, not nil', function()
    local s, matchId = withWatcher(0)
    local byPick, pool, sum = book(s, matchId)
    t.equals(type(byPick), 'table', 'an empty book was not a table')
    t.equals(sum, 0)
    t.equals(pool, 0)
end)

t.test('and an id that names no match at all is the same empty answer', function()
    local s = withWatcher(0)
    local byPick = s.betting.SideBetTotals('no-such-match')
    t.equals(type(byPick), 'table')
    t.equals(next(byPick), nil, 'an unknown match produced side-bet money')
end)

-- ========================================================================
-- THE SAME FILTER, WHICH IS THE WHOLE POINT
-- ========================================================================

t.test('DEFECT: a refunded bet leaves the breakdown when it leaves the pool', function()
    -- returnSideBet MARKS the row rather than deleting it. A breakdown that
    -- read the marked row would keep showing money on a side the settlement
    -- no longer has any, and the figures beside each other would disagree.
    local s, matchId = withWatcher(0)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))

    local _, poolBefore, sumBefore = book(s, matchId)
    t.equals(sumBefore, poolBefore)
    t.equals(poolBefore, 2000)

    s.betting.ReturnBetsOn(matchId, '1')

    local byPick, pool, sum = book(s, matchId)
    t.equals(pool, 0, 'the pool kept a bet that was handed back')
    t.equals(sum, 0, 'A REFUNDED BET IS STILL SHOWN AS MONEY ON THAT SIDE')
    t.equals(byPick['1'], nil, 'the side kept a figure with nothing behind it')
end)

t.test('an odds bet is out of both, because the server funds it', function()
    -- An 'odds' bet is paid by the operator and not out of the pool, so
    -- letting one into either figure would tell a pool bettor there is money
    -- to win that no winning bet can ever be paid from.
    local s, matchId = withWatcher(0, function(config)
        config.Betting.betPayout = config.Betting.betPayout or {}
        config.Betting.betPayout.spectators = 'odds'
    end)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))

    local byPick, pool, sum = book(s, matchId)
    t.equals(pool, 0, 'an odds bet was counted into the pool')
    t.equals(sum, 0, 'AN ODDS BET WAS SHOWN AS POOL MONEY ON THAT SIDE')
    t.equals(byPick['1'], nil)
end)

-- ========================================================================
-- AND IT REACHES THE PANEL
-- ========================================================================

t.test('the snapshot carries the breakdown beside the total', function()
    local s, matchId = withWatcher(0)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))

    local match = s.onlyMatch(3)
    t.isNotNil(match, 'the watcher was sent no match at all')
    t.equals(type(match.betsByPick), 'table', 'betsByPick never reached the wire')
    t.equals(match.betsByPick['1'], 2000, 'the wire figure is not the one on the books')
    t.equals(match.betPool, 2000, 'the pool on the wire disagrees with the breakdown')
end)

t.test('and every side on the wire is a pick the panel can draw a chip for', function()
    -- The panel matches these keys against a fighter's server id in a
    -- free-for-all and against a team key in a team match. A key it cannot
    -- match draws no chip, and the money on it vanishes off the screen
    -- while still counting towards the pool beside it.
    local s, matchId = withWatcher(0)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 2, 1500, 'cash'))

    local match = s.onlyMatch(3)
    local ids = {}
    for _, row in ipairs(match.players or {}) do ids[tostring(row.id)] = true end

    for pick in pairs(match.betsByPick or {}) do
        t.isTrue(ids[pick] == true,
            'the wire named a side "' .. tostring(pick) .. '" that is nobody in this match')
    end
end)

os.exit(t.summary())
