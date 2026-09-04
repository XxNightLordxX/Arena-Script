--[[
    crimson_arena/tests/betguards_spec.lua

    THE REFUSALS AND THE VOID RULES, which are where the money is decided.

    bettingdefects_spec covers the settlement itself -- who is paid, out of
    which pool, and what happens to a bet whose holder joined the fight. A
    mutation sample of server/betting.lua found seventeen survivors, and the
    ones worth having cluster in two places that spec does not reach: the
    guards that refuse a bet before the money moves, and two lines that are
    the regression guards for defects fixed earlier in this session and
    never pinned.

    THE TWO THAT WERE MY OWN FIXES:

      `if bet.fromEntryFee == true then return false end` in voided() is
      what stops an operator's entry pot being handed straight back on a
      server with fighter bets switched OFF. Without it, every entry stake
      is a bet held by a fighter, so every one is voided and returned, the
      pot is never won by anybody, and nothing says so -- the round ends,
      the winner is announced, and the money quietly goes home.

      `paidFrom[winner] or paidFrom[payout.id]` is what pays the pot back
      into the account the winner actually staked FROM. Paying it into the
      server's configured account instead turns bank money into cash, which
      is a laundering route through the arena.

    Both were fixed, and neither had a test. A fix nothing guards is a fix
    that comes back.

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

--- Two fighters in a lobby, with an entry fee and betting on.
--- @return table server, string matchId
local function twoFighters(fee, mutate)
    local s = newArena({ [1] = 50000, [2] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = fee > 0
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = fee
        if mutate then mutate(config) end
    end)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, fee, nil, nil, 'cash')
    t.isNotNil(matchId, 'the match could not be created: ' .. tostring(err))
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the second player could not join')
    return s, matchId
end

--- Runs the round to a finish with `winner` the last one standing.
local function finish(s, matchId, winner)
    local match = s.lobby.Get(matchId)
    match.state = 'live'
    for src, player in pairs(match.players) do player.alive = (src == winner) end
    s.betting.Settle(matchId, { winners = { winner }, players = match.players })
    s.betting.SettleSpectatorBets(matchId, winner)
end

-- ========================================================================
-- AN ENTRY FEE IS NOT A BET SOMEBODY PLACED
-- ========================================================================

t.test('the entry pot is still won where FIGHTER BETS ARE OFF', function()
    -- THE REGRESSION GUARD. With includeEntryPot on, every fighter's fee
    -- becomes a pool bet on their own side. Without the fromEntryFee check
    -- in voided(), every one of those is "a bet held by a fighter" on a
    -- server that does not allow fighter bets -- so every one is voided and
    -- handed back, the pot is never won, and nothing anywhere says so.
    local s, matchId = twoFighters(1000, function(config)
        config.Betting.fighterBets.enabled = false
    end)
    local function cash(id) return s.qbx.players[id].money.cash end
    t.equals(cash(1), 49000, 'the entry fee was never taken')

    finish(s, matchId, 1)

    t.equals(cash(1), 51000, 'the winner was not paid the pot -- their own fee went home instead')
    t.equals(cash(2), 49000, 'the loser got their entry fee back')
end)

t.test('and where they are ON, which is the shipped config', function()
    -- The control, so the assertion above cannot pass against a server
    -- that simply always pays.
    local s, matchId = twoFighters(1000)
    finish(s, matchId, 1)

    t.equals(s.qbx.players[1].money.cash, 51000, 'the winner was not paid the pot')
end)

t.test('but a fighter\'s OWN bet is still void where fighter bets are off', function()
    -- The other half of the same guard: the entry fee is exempt, a bet
    -- they chose to place is not. Placed before the switch is read, the
    -- way a stale panel would.
    local s, matchId = twoFighters(0)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash'))
    t.equals(cash(1), 48000, 'the stake was never taken')

    s.config.Betting.fighterBets.enabled = false
    finish(s, matchId, 1)

    t.equals(cash(1), 50000, 'a fighter\'s own bet was paid on a server that forbids them')
end)

-- ========================================================================
-- THE POT GOES BACK WHERE IT CAME FROM
-- ========================================================================

t.test('a winner who paid from the BANK is paid into the bank', function()
    -- THE OTHER REGRESSION GUARD. Paying into the server's configured
    -- account instead turns bank money into cash, which is a laundering
    -- route through the arena -- and it is invisible from a single
    -- balance.
    local s = newArena({ [1] = 50000, [2] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = true
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = 1000
        config.Betting.account = 'cash'
        -- THE POT MUST BE PAID BY Settle FOR THIS TO BE ABOUT ANYTHING.
        -- With includeEntryPot on -- the shipped default -- Settle folds
        -- the stakes into the bet pool and returns an EMPTY payout list,
        -- so the loop that chooses which account to credit never runs at
        -- all and this test passes without reaching the line it is named
        -- after.
        config.Betting.betPayout.includeEntryPot = false
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, 1000, nil, nil, 'bank')
    t.isNotNil(matchId, 'the match could not be created')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'bank'), 'the second player could not join')

    local function bank(id) return s.qbx.players[id].money.bank end
    local function cash(id) return s.qbx.players[id].money.cash end
    t.equals(bank(1), 49000, 'the fee did not come out of the bank')
    local cashBefore = cash(1)

    finish(s, matchId, 1)

    t.equals(bank(1), 51000, 'the pot was not paid back into the account it was staked from')
    t.equals(cash(1), cashBefore, 'the pot arrived as CASH on a player who staked from the bank')
end)

-- ========================================================================
-- THE GUARDS THAT REFUSE BEFORE THE MONEY MOVES
-- ========================================================================

t.test('the book closes once the round is under way', function()
    local s, matchId = twoFighters(0)
    local match = s.lobby.Get(matchId)
    match.state = 'live'
    match.startsAt = 0

    local ok, err = s.betting.PlaceSpectatorBet(1, matchId, 1, 2000, 'cash')

    t.isFalse(ok, 'a bet was taken on a round already being fought')
    t.equals(err, 'error.bets_closed')
    t.equals(s.qbx.players[1].money.cash, 50000, 'the money moved on a refused bet')
end)

t.test('and a stake outside the band is refused before anything is taken', function()
    local s, matchId = twoFighters(0)
    local band = s.config.Betting.fighterBets

    local low, lowErr = s.betting.PlaceSpectatorBet(1, matchId, 1, band.min - 1, 'cash')
    t.isFalse(low, 'a stake under the minimum was accepted')
    t.isNotNil(lowErr)

    local high = s.betting.PlaceSpectatorBet(1, matchId, 1, band.max + 1, 'cash')
    t.isFalse(high, 'a stake over the maximum was accepted')

    t.equals(s.qbx.players[1].money.cash, 50000, 'money moved on a refused stake')
end)

t.test('and a pick nothing in the match answers to is refused', function()
    -- ASKED BY A SPECTATOR, and the reason is asserted. A FIGHTER is held
    -- to their own side, so a made-up pick is refused by that rule first
    -- and the test passes without the pick check existing at all -- which
    -- is exactly what it did before this comment was written.
    local s, matchId = twoFighters(0)
    local spectator = 3
    s.qbx.players[spectator] = {
        citizenid = 'CID003', name = 'Watcher',
        money = { cash = 50000, bank = 50000 },
        job = { name = 'unemployed', grade = { level = 0 } },
    }

    for _, bad in ipairs({ 999, 'nobody', '' }) do
        local ok, err = s.betting.PlaceSpectatorBet(spectator, matchId, bad, 200, 'cash')
        t.isFalse(ok, ('%s was accepted as somebody to back'):format(tostring(bad)))
        t.equals(err, 'error.bet_invalid_pick',
            ('%s was refused, but for the wrong reason (%s)'):format(tostring(bad), tostring(err)))
    end

    t.equals(s.qbx.players[spectator].money.cash, 50000, 'money moved on a bet nobody could win')
end)

t.test('and a fighter backing the OTHER side is refused, not settled later', function()
    -- Being paid to lose on purpose is the thing an arena is exactly the
    -- place for, so it is stopped at the door rather than judged at the
    -- end.
    local s, matchId = twoFighters(0)

    local ok, err = s.betting.PlaceSpectatorBet(1, matchId, 2, 2000, 'cash')

    t.isFalse(ok, 'a fighter was allowed to back their opponent')
    t.equals(err, 'error.bet_not_own_side')
    t.equals(s.qbx.players[1].money.cash, 50000, 'the money moved on a refused bet')
end)

t.test('but is allowed where the operator switched the rule off', function()
    -- The control for the guard above.
    local s, matchId = twoFighters(0, function(config)
        config.Betting.fighterBets.ownSideOnly = false
    end)

    t.isTrue(s.betting.PlaceSpectatorBet(1, matchId, 2, 2000, 'cash'),
        'a server that allows backing any side still refused it')
end)

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

-- ========================================================================
-- A BET THAT HAS BEEN HANDED BACK IS NOT A BET THAT IS HELD
--
-- returnSideBet MARKS a row rather than deleting it -- `bet.settled = true`
-- -- and four functions ask "does this player hold a bet on this match".
-- Two checked the mark and two did not, which is the whole defect.
-- ========================================================================

t.test('DEFECT: a refunded side-bet locked the bettor out of that match for good', function()
    -- ArenaLobby.UpdateMatch hands every side-bet back when the host changes
    -- the mode, and says why in as many words: "They get their money and can
    -- back the one that replaced it." They could not. PlaceSpectatorBet
    -- gates on HasSpectatorBet, oneBetPerMatch ships true, and that function
    -- counted the refunded row -- so every later bet came back "One side-bet
    -- per match. Yours is down." about a bet the server had already
    -- returned. For the life of the match.
    local s, matchId = withWatcher(0)

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'the first side-bet was refused, so there is nothing to hand back')
    t.equals(s.betting.ReturnSideBets(matchId), 1, 'the bet was not handed back')

    local ok, err = s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash')
    t.isTrue(ok, ('a bettor who had been refunded could not back the match again: %s'):format(tostring(err)))
end)

t.test('and the snapshot stops claiming they have money on it', function()
    -- The other half, and the one the player actually reads. GetSideBet fed
    -- snapshotPlayer, so the panel went on printing "You have $2000 on ..."
    -- over a stake that was back in their wallet -- and after a mode change,
    -- on a side the match no longer has, so it printed the raw key.
    local s, matchId = withWatcher(0)

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))
    t.isNotNil(s.betting.GetSideBet(matchId, 3), 'a live bet was not reported at all')

    s.betting.ReturnSideBets(matchId)

    t.isNil(s.betting.GetSideBet(matchId, 3),
        'the panel is still being told about a bet that was handed back')
end)

t.test('and a bet that is still LIVE is reported by both, exactly as before', function()
    -- The control. A guard that answered "no bet" unconditionally would pass
    -- both tests above and take the feature away.
    local s, matchId = withWatcher(0)

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'))

    t.isTrue(s.betting.HasSpectatorBet(matchId, 3),
        'a live bet is not counted as held, so nothing enforces one bet per match')
    local bet = s.betting.GetSideBet(matchId, 3)
    t.isNotNil(bet, 'a live bet is not reported to the panel')
    t.equals(bet.amount, 2000)
end)

-- ========================================================================
-- WHAT A FIGHTER IS TOLD WHEN THE POT SETTLES
--
-- With betPayout.includeEntryPot on -- the shipped default -- Settle folds
-- every entry fee into the side-bet pool as a row and returns an EMPTY
-- payout list, so the pot is paid out of SettleSpectatorBets. Those rows
-- then took the ordinary side-bet branches, and told fighters about a
-- "pick" they never made.
-- ========================================================================

--- Runs the settlement the way ArenaMatch.End does: Settle first, then
--- SettleSpectatorBets against the winning pick.
local function settleWith(s, matchId, winnerId)
    local match = s.lobby.Get(matchId)
    local context = { teams = false, winners = { winnerId }, contestants = 2, players = {} }
    for src in pairs(match.players) do
        context.players[#context.players + 1] = {
            id = src, team = nil, kills = 0,
            stake = s.betting.GetStake(matchId, src), placement = nil,
        }
    end
    s.betting.Settle(matchId, context)
    return s.betting.SettleSpectatorBets(matchId, winnerId)
end

t.test('DEFECT: the winner was congratulated on a PICK, and never told the pot was theirs', function()
    local s, matchId = twoFighters(1000)
    t.isTrue(s.config.Betting.betPayout.includeEntryPot,
        'includeEntryPot is off, so this test is about the wrong settlement path')

    local mark = s.mark()
    settleWith(s, matchId, 1)

    local said = s.noticesSince(mark, 1)
    t.contains(said, 'pot is yours',
        'the winner was never told they took the pot: ' .. said)
    t.notContains(said, 'pick came in',
        'the winner was congratulated on a bet they never placed: ' .. said)
end)

t.test('and the loser was told their PICK went down, for a bet they never placed', function()
    local s, matchId = twoFighters(1000)

    local mark = s.mark()
    settleWith(s, matchId, 1)

    local said = s.noticesSince(mark, 2)
    t.notContains(said, 'pick went down',
        'a fighter who placed no bet was told their pick lost: ' .. said)
    t.contains(said, 'Stake gone',
        'the loser was not told what happened to their entry fee: ' .. said)
end)

t.test('but a real side-bet is still settled in the words of a bet', function()
    -- The control, and the reason the two above are worth having: a change
    -- that used the pot wording for everything would pass them and start
    -- telling spectators they had won a pot they were never in.
    local s, matchId = withWatcher(1000)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'the watcher could not back anybody')

    local mark = s.mark()
    settleWith(s, matchId, 1)

    local said = s.noticesSince(mark, 3)
    t.contains(said, 'pick came in',
        'a spectator who really did back a fighter was not told their pick came in: ' .. said)
    t.notContains(said, 'pot is yours',
        'a spectator was told they had taken the pot: ' .. said)
end)

os.exit(t.summary())
