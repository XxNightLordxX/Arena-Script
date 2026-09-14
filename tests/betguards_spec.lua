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
    -- THROUGH THE DEAD-PICK REFUND, which is what hands a bet back now. The
    -- mode change that used to do it is refused instead: a host who could
    -- void the whole book for free, over and over, was worse than the loss
    -- that refund was written to prevent. The rule under test here is
    -- unchanged and has nothing to do with which door the refund came
    -- through -- a returned bet must stop counting as one that is held.
    t.equals((s.betting.ReturnBetsOn(matchId, 1)), 1, 'the bet was not handed back')

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

    s.betting.ReturnBetsOn(matchId, 1)

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

-- ========================================================================
-- A PICK THAT WALKED OUT IS NOT A PICK THAT LOST
--
-- ArenaLobby.UpdateMatch has returned every side-bet on a mode change since
-- the day it was written, and its comment says exactly why: a bet naming
-- something that can no longer win does not go back on its own, it LOSES --
-- "with nothing on screen saying so and no way for the bettor to have seen
-- it coming."
--
-- A fighter walking out does the identical thing to the people who backed
-- them, by the other door, and nothing was returning those. The bet is not
-- voided (its holder never fought), there IS a winner so it is not the
-- no-result refund, and on the shipped config -- sharedPool with
-- includeEntryPot -- the survivors' own entry fees make the pool contested,
-- so the uncontested-pool refund cannot reach it either. It falls to the
-- last `else` in SettleSpectatorBets and is marked `lost`.
--
-- Which is also a scam that runs itself: open a lobby with a friend, let the
-- room back them, have them walk before the start, win, collect. Nothing has
-- to be exploited. It was simply how a departed pick settled.
-- ========================================================================

t.test('DEFECT: backing a fighter who then walked out cost the whole stake', function()
    local s, matchId = withWatcher(1000)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 2, 25000, 'cash'),
        'the watcher could not back the fighter who is about to leave')
    t.equals(cash(3), 25000, 'the stake was never taken, so this proves nothing')

    -- Out of the lobby before the round starts -- the ordinary case, and the
    -- one the shipped refund rule treats most gently for the leaver.
    t.isTrue(s.lobby.Leave(2, 'bet.refund_left'), 'the fighter could not leave')

    -- Back already, unjudged, the moment the pick died. Not at settlement:
    -- by then the pool has been divided and it is too late to be fair.
    t.equals(cash(3), 50000,
        'the spectator did not get their stake back when the fighter they backed walked out')

    settleWith(s, matchId, 1)

    -- AND NOT TWICE. returnSideBet marks rather than deletes, which is the
    -- whole reason this can be asserted at all.
    t.equals(cash(3), 50000, 'the returned stake was paid out a second time at settlement')
end)

t.test('and the console says which bets went back and why', function()
    local s, matchId = withWatcher(1000)
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'))
    s.lobby.Leave(2, 'bet.refund_left')

    t.contains(s.log(), 'side-bet(s) backing them were returned unjudged',
        'a spectator was quietly handed their money back with nothing in the console about it')
end)

t.test('a bet on the fighter who STAYED is untouched by somebody else leaving', function()
    -- The control. A change that returned every bet on any leave would pass
    -- the test above and quietly refund the whole book on every walk-out.
    local s, matchId = withWatcher(1000)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 25000, 'cash'))
    t.equals(cash(3), 25000)

    s.lobby.Leave(2, 'bet.refund_left')

    t.equals(cash(3), 25000,
        'a live bet on a fighter who is still in the match was handed back')
    t.isNotNil(s.betting.GetSideBet(matchId, 3),
        'the bet was settled off the record even though its pick is still fighting')
end)

t.test('and a TEAM pick only dies with the last player on that side', function()
    -- One of four leaving a 2v2 leaves crimson perfectly able to win.
    -- Returning bets on it would be handing money back on a live wager.
    -- SERVER IDS THAT LOOK LIKE A SERVER'S, and this is not decoration.
    -- Written 1..5, this test passed against a guard that counted its roster
    -- with `ipairs` over a table keyed by server id -- because 1..5 is the
    -- one roster shape where that is accidentally right. A real lobby's
    -- lowest id is rarely 1, ipairs then stops at the first index, every
    -- side reads as empty, and the guard holds open for any departure at
    -- all. The numbers below are the whole reason this test can see that.
    local s = newArena({ [7] = 50000, [19] = 50000, [23] = 50000, [41] = 50000, [58] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        config.Betting.entryFee.enabled = false
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = 0
    end)

    local teamMode
    for _, mode in ipairs(s.env.Arena.GetEnabledModes()) do
        if mode.teams then teamMode = mode.key break end
    end
    t.isNotNil(teamMode, 'the config under test ships no team mode')

    local teams = s.env.Arena.GetEnabledTeams()
    t.isTrue(#teams >= 2, 'the config under test ships fewer than two teams')
    local sideA, sideB = teams[1].key, teams[2].key

    local matchId = s.lobby.Create(7, anArena(s), teamMode, 0, nil, nil, 'cash')
    t.isNotNil(matchId, 'the team match could not be created')
    t.isTrue(s.lobby.Join(19, matchId, nil, 'cash'))
    t.isTrue(s.lobby.Join(23, matchId, nil, 'cash'))
    t.isTrue(s.lobby.Join(41, matchId, nil, 'cash'))

    local match = s.lobby.Get(matchId)
    match.players[7].team,  match.players[19].team = sideA, sideA
    match.players[23].team, match.players[41].team = sideB, sideB

    local function cash(id) return s.qbx.players[id].money.cash end
    t.isTrue(s.betting.PlaceSpectatorBet(58, matchId, sideA, 10000, 'cash'))
    t.equals(cash(58), 40000)

    -- One of the two on that side goes. The side is still in the fight.
    s.lobby.Leave(19, 'bet.refund_left')
    t.equals(cash(58), 40000,
        ('a bet on "%s" was returned while a player was still on that side'):format(sideA))

    -- The last one goes. Now it cannot win.
    s.lobby.Leave(7, 'bet.refund_left')
    t.equals(cash(58), 50000,
        ('the last player on "%s" left and the bets on it were not returned'):format(sideA))
end)

t.test('and the pick is normalised the way the bet was written, not by hand', function()
    -- PlaceSpectatorBet stores a free-for-all pick through `canonicalPick`,
    -- which turns a server id into a STRING. A caller holding the number --
    -- which is what every id is everywhere else in the server -- must match
    -- the same rows, or ReturnBetsOn quietly returns nothing and reports a
    -- clean zero.
    --
    -- Written against the number on purpose: normalising by hand here would
    -- be a second copy of a rule that already exists once, and the whole
    -- reason this test is worth having is that the two are free to drift.
    local s, matchId = withWatcher(1000)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 2, 4000, 'cash'))
    t.equals(cash(3), 46000)

    local returned, owed = s.betting.ReturnBetsOn(matchId, 2)
    t.equals(returned, 1, 'a numeric pick matched no bet, though that is how server ids are held')
    t.equals(owed, 0)
    t.equals(cash(3), 50000, 'the stake was not handed back')
end)

t.test('but a FIGHTER cannot cancel their own losing bet by walking out', function()
    -- THE HOLE THE DEAD-PICK REFUND OPENS IF IT IS NOT AIMED CAREFULLY.
    --
    -- A fighter backing themselves picks their own server id, so their bet
    -- and a spectator's bet on them name the SAME pick. Returning everything
    -- on that pick when they leave hands the fighter their own wager back --
    -- and a wager you can cancel once it is going badly is not a wager. It
    -- is free money with an exit.
    --
    -- The spectator's case is the opposite and is why the refund exists at
    -- all: their pick died through somebody else's act, with nothing they
    -- could have done about it.
    local s, matchId = withWatcher(1000, function(config)
        config.Betting.fighterBets.enabled = true
        config.Betting.fighterBets.ownSideOnly = true
    end)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(1, matchId, 1, 5000, 'cash'), 'the fighter could not back themselves')
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 5000, 'cash'), 'the watcher could not back that fighter')

    local fighterAfterStake = cash(1)
    t.equals(cash(3), 45000, 'the watcher\'s stake was never taken')

    -- THEY CANNOT CLICK THEIR WAY OUT AT ALL ANY MORE, which is the first
    -- half of the same rule and the reason this test now goes through the
    -- other door. ArenaLobby.Leave refuses a voluntary exit from a lobby the
    -- player has a bet on, exactly as Join refuses a seat to somebody who has
    -- one -- and the size is why: fighterBets.max ships at twice the
    -- spectator ceiling, so a fighter who could stand up kept a 50,000
    -- position in a field capped at 25,000.
    local left, refusal = s.lobby.Leave(1, 'bet.refund_left')
    t.isTrue(left ~= true, 'a fighter walked out of a lobby holding a bet on it')
    t.equals(refusal, 'error.bet_then_leave', 'the refusal did not say what they had done')
    t.isNotNil(s.lobby.Get(matchId).players[1], 'the refused leave took them out anyway')

    -- SO THEY DROP INSTEAD, which cannot be refused: the player is already
    -- gone and holding their row would strand a stake, a routing bucket and a
    -- suppressed dispatch flag. Their own bet is still theirs to lose; the
    -- watcher's is on a pick that just died.
    t.isTrue(s.lobby.Leave(1, 'bet.refund_left', true), 'a disconnect was refused, which cannot work')

    t.equals(cash(3), 50000, 'the watcher did not get their stake back on a pick that walked out')
    t.equals(cash(1), fighterAfterStake + 1000,
        'the fighter got their own bet back by dropping -- only the 1000 entry fee should have returned')
end)

-- ========================================================================
-- A PICK THAT IS ALREADY OUT IS NOT A PICK
--
-- The book stays open for spectatorBets.closeAfterStartSeconds -- 30 on the
-- shipped config -- AFTER the round goes live. pickExists asked only whether
-- the id was on the roster, and an eliminated fighter deliberately KEEPS
-- their row, because the results board ranks off it. So inside that window a
-- spectator could be sold a bet, by the panel's own chip, on somebody who
-- was already out.
--
-- It is not voided at settlement either: `voided` only fires for a holder
-- who FOUGHT, and a spectator did not. It falls through to lost, and their
-- whole stake -- up to 25,000 -- goes to whoever backed the winner.
-- ========================================================================

t.test('DEFECT: a bet was taken on a fighter who was already eliminated', function()
    local s, matchId = withWatcher(0, function(config)
        config.Betting.spectatorBets.closeAfterStartSeconds = 30
    end)
    local match = s.lobby.Get(matchId)
    match.state = 'live'
    match.startsAt = os.time()

    -- Fighter 2 is out: no lives left and not alive, which is exactly what
    -- server/match.lua leaves behind on a final death.
    match.players[2].alive = false
    match.players[2].lives = 0

    local ok, why = s.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash')
    t.isFalse(ok, 'the arena sold a bet on a fighter who could not win it')
    t.equals(why, 'error.bet_invalid_pick')
    t.equals(s.qbx.players[3].money.cash, 50000, 'the stake was taken for a bet that was refused')
end)

t.test('and a fighter who is merely DOWN with lives left can still be backed', function()
    -- The control, and the distinction that matters: dead-this-second is not
    -- eliminated. A fighter waiting on a respawn is still in the round and
    -- still the favourite, and refusing bets on them would be a different
    -- bug wearing this fix as a disguise.
    local s, matchId = withWatcher(0, function(config)
        config.Betting.spectatorBets.closeAfterStartSeconds = 30
    end)
    local match = s.lobby.Get(matchId)
    match.state = 'live'
    match.startsAt = os.time()

    match.players[2].alive = false
    match.players[2].lives = 2

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 2, 5000, 'cash'),
        'a fighter waiting to respawn could not be backed, though they are still in the round')
end)

t.test('and a team is unbackable once its last player is out', function()
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000, [4] = 50000, [5] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.spectatorBets.enabled = true
        config.Betting.spectatorBets.closeAfterStartSeconds = 30
        config.Betting.entryFee.enabled = false
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = 0
    end)

    local teamMode
    for _, mode in ipairs(s.env.Arena.GetEnabledModes()) do
        if mode.teams then teamMode = mode.key break end
    end
    local teams = s.env.Arena.GetEnabledTeams()
    local sideA, sideB = teams[1].key, teams[2].key

    local matchId = s.lobby.Create(1, anArena(s), teamMode, 0, nil, nil, 'cash')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'))
    t.isTrue(s.lobby.Join(3, matchId, nil, 'cash'))

    local match = s.lobby.Get(matchId)
    match.players[1].team, match.players[2].team = sideA, sideA
    match.players[3].team = sideB
    match.state = 'live'
    match.startsAt = os.time()

    -- One of the two on sideA is out. The side is still in the fight.
    match.players[1].alive, match.players[1].lives = false, 0
    t.isTrue(s.betting.PlaceSpectatorBet(4, matchId, sideA, 1000, 'cash'),
        ('"%s" could not be backed while it still had a player standing'):format(sideA))

    -- Now the last one goes.
    match.players[2].alive, match.players[2].lives = false, 0
    local ok = s.betting.PlaceSpectatorBet(5, matchId, sideA, 1000, 'cash')
    t.isFalse(ok, ('a bet was sold on "%s" after every player on it was eliminated'):format(sideA))
end)

-- ========================================================================
-- THE BAIL-OUT: A BET THAT COULD NOT LOSE
-- ========================================================================
--
-- MayLeave refuses a fighter who HOLDS a bet, because a wager its owner can
-- cancel by standing up is a wager with no risk in it. Split the two roles
-- and the same free option comes back with somebody else's name on it:
--
--   a colluder backs an accomplice for the ceiling;
--   the accomplice holds NO bet, so MayLeave never looks at them;
--   winning, they play on and the pair take a share;
--   losing, they press Leave and the whole stake comes back, unjudged --
--   at any moment of the round, including after they are already out.
--
-- Never a loss. On a free-entry lobby it costs nothing to run, and one
-- colluder can hold the position on every open match at once.

t.test('THE FREE OPTION: a pick walking out of a LIVE round does not refund', function()
    local s, matchId = withWatcher(0)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 5000, 'cash'),
        'the watcher could not back a fighter')
    local staked = cash(3)

    s.match.Start(matchId)
    s.step()
    t.isTrue(s.lobby.Get(matchId).state ~= 'lobby', 'the round did not start')

    -- The accomplice bails out of a round being fought.
    s.lobby.Leave(1, 'match.left')

    t.equals(cash(3), staked,
        'the bet came back unjudged, so backing a friend who can quit is a bet that never loses')
end)

t.test('and a pick leaving the LOBBY still does, because nothing was fought', function()
    -- The other half, and the reason the rule is not simply "never refund".
    -- A pick that leaves a queue took nothing away from the person who
    -- backed them; a pick that leaves a fight did.
    local s, matchId = withWatcher(0)
    local function cash(id) return s.qbx.players[id].money.cash end

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 5000, 'cash'))
    local staked = cash(3)
    t.equals(s.lobby.Get(matchId).state, 'lobby', 'the round already started')

    s.lobby.Leave(1, 'match.left')

    t.equals(cash(3), staked + 5000,
        'a watcher whose pick left the queue was not given their stake back')
end)

t.test('POWERGAMING: walking out of a live round does not turn you into a spectator who can back the winner', function()
    -- THE TRADE THIS REFUSAL EXISTS TO STOP. A fighter who is losing leaves
    -- the round -- forfeiting their stake, which is the advertised cost --
    -- and then puts money on the opponent who is about to win. The forfeit
    -- becomes the entry fee for a bet that can hardly lose.
    --
    -- It is only worth anything while the book is still open, and on a live
    -- round that is exactly what spectatorBets.closeAfterStartSeconds leaves
    -- open: a grace window in which somebody who is NOT fighting may still
    -- back a side. The rule is one term in one line -- a player who walked
    -- out of a round being fought counts as a FIGHTER for that question, and
    -- fighters are closed out the moment the round starts.
    --
    -- Nothing named it: ArenaBetting.MarkWalkedOut appears in no other spec,
    -- and every existing refusal here is a round whose window has passed, so
    -- the term could be deleted with the suite still green.
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = false
        config.Betting.spectatorBets = config.Betting.spectatorBets or {}
        config.Betting.spectatorBets.enabled = true
        config.Betting.spectatorBets.closeAfterStartSeconds = 60
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, 0, nil, nil, 'cash')
    t.isNotNil(matchId, 'the match could not be created')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the second fighter could not join')

    local match = s.lobby.Get(matchId)
    match.state = 'live'
    match.startsAt = os.time()

    -- THE WINDOW IS GENUINELY OPEN: a real spectator can back a side right
    -- now. Without this the refusal below would prove only that the book was
    -- shut to everybody.
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'the grace window is closed, so this proves nothing')

    -- And player 2, who is losing, walks out and tries to back player 1.
    --
    -- THE ROSTER ROW GOES WITH THEM, because that is what leaving does -- and
    -- it is the whole reason this rule needs a term of its own. While they
    -- are still listed as a fighter the book is shut to them anyway; the
    -- moment they are not, the only thing standing between a forfeited stake
    -- and a free bet on the winner is `walkedOut`.
    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil
    local ok, err = s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash')

    t.isFalse(ok, 'A FIGHTER WALKED OUT OF A LIVE ROUND AND WAS SOLD A BET ON THE OTHER SIDE')
    t.equals(err, 'error.bets_closed')
    t.equals(s.qbx.players[2].money.cash, 50000, 'money moved on a refused bet')
end)

--- The setup the three tests below share: a live round, a grace window that
--- is genuinely open, and one fighter about to walk out of it.
--- @return table server, string matchId
local function liveRoundWithGrace()
    local s = newArena({ [1] = 50000, [2] = 50000, [3] = 50000, [4] = 50000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = false
        config.Betting.spectatorBets = config.Betting.spectatorBets or {}
        config.Betting.spectatorBets.enabled = true
        config.Betting.spectatorBets.closeAfterStartSeconds = 60
    end)
    local matchId = s.lobby.Create(1, anArena(s), nil, 0, nil, nil, 'cash')
    t.isNotNil(matchId, 'the match could not be created')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the second fighter could not join')

    local match = s.lobby.Get(matchId)
    match.state = 'live'
    match.startsAt = os.time()

    return s, matchId
end

t.test('THE DEFECT: the walked-out flag was a SEAT, and a seat is handed to whoever connects next', function()
    -- A server id is not a person. It is a slot the framework reuses the
    -- moment it is free, and this was the only gate in the file that did not
    -- ask `betIsHeldBy` who is holding it now.
    --
    -- THE STRANGER'S HALF. Player 2 quits the live round. The next player to
    -- connect is handed id 2 -- a different character, who has never been
    -- near this match -- and their bet comes back refused, with a message
    -- about a book that is open for everybody else in the same instant.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil

    -- The framework hands id 2 to somebody else entirely.
    s.qbx.players[2].citizenid = 'CID999'
    s.qbx.players[2].name = 'Somebody Else'

    local ok, err = s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash')
    t.isTrue(ok, 'A PLAYER WHO HAS NEVER BEEN NEAR THIS MATCH WAS REFUSED: ' .. tostring(err))

    -- THE CONTROL, in the same instant, from a seat nobody walked out of.
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'the window is shut anyway, so the assertion above proves nothing')
end)

t.test('and the walker is still refused on a FRESH seat, which is the half that costs money', function()
    -- The mirror, and the one the rule was written for. The same character
    -- reconnects on a new id and asks for the spectator ceiling on the round
    -- they abandoned seconds ago -- precisely the "a wager you can cancel
    -- once it is going badly" trade the flag exists to close.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    local walker = s.qbx.players[2].citizenid
    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil

    -- They come back on id 4.
    s.qbx.players[4].citizenid = walker

    local ok, err = s.betting.PlaceSpectatorBet(4, matchId, 1, 2000, 'cash')
    t.isFalse(ok, 'THE FIGHTER WHO WALKED OUT RECONNECTED AND WAS SOLD THE BET')
    t.equals(err, 'error.bets_closed')
    t.equals(s.qbx.players[4].money.cash, 50000, 'money moved on a refused bet')
end)

t.test('THE REGRESSION: the flag survives a DROP, where nothing can name the player', function()
    -- THE TRAP IN KEYING THIS ON THE CHARACTER. `citizenIdOf` reaches into
    -- the framework, and on a genuine disconnect the framework has usually
    -- forgotten the player before this resource's playerDropped handler runs.
    -- Written with no name and read with one, the two never match -- and the
    -- fighter who dropped out of a live round and reconnected was sold a bet
    -- on it. Measured, when this was keyed on the character alone: refused on
    -- a clean Leave, SOLD on a drop.
    --
    -- The roster row still holds their name at that moment, so ArenaLobby
    -- passes it in rather than leaving betting.lua to look up something that
    -- is already gone.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    -- THE FRAMEWORK HAS ALREADY LET GO OF THEM. This is what a real drop
    -- looks like from inside this resource, and it is the whole test: with
    -- the roster row still in hand the name survives it.
    s.qbx.players[2] = nil
    s.lobby.Leave(2, 'match.left', true)

    -- ...and they reconnect on the same id.
    s.qbx.players[2] = {
        citizenid = 'CID002', name = 'Fighter 2',
        money = { cash = 50000, bank = 0 },
        job = { name = 'unemployed', grade = { level = 0 } },
    }

    local ok, err = s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash')
    t.isFalse(ok, 'A FIGHTER WHO DROPPED OUT OF A LIVE ROUND RECONNECTED AND WAS SOLD A BET ON IT')
    t.equals(err, 'error.bets_closed')
    t.equals(match.state, 'live', 'the round stopped being fought, so this proves nothing')
end)

t.test('and on a fresh seat after a drop, which neither identity alone catches', function()
    -- The seat key cannot answer this one and the character key could not be
    -- written. Both halves are held now, so it is answered.
    local s, matchId = liveRoundWithGrace()
    local walker = s.qbx.players[2].citizenid

    s.qbx.players[2] = nil
    s.lobby.Leave(2, 'match.left', true)

    s.qbx.players[4].citizenid = walker

    local ok, err = s.betting.PlaceSpectatorBet(4, matchId, 1, 2000, 'cash')
    t.isFalse(ok, 'the walker came back on another id after a drop and was sold the bet')
    t.equals(err, 'error.bets_closed')
end)

t.test('CONTROL: a drop does not shut the book on the watchers', function()
    -- Every refusal above has to be about the walker. A flag that shut the
    -- round to everybody would pass all three and be a worse bug.
    local s, matchId = liveRoundWithGrace()

    s.qbx.players[2] = nil
    s.lobby.Leave(2, 'match.left', true)

    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'somebody who never fought was refused because a fighter dropped')
end)

t.test('and a caller that passes no name still falls back to looking one up', function()
    -- MarkWalkedOut's third argument is optional. A caller with nothing to
    -- pass must still get the rule, not a silent no-op.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil

    local ok, err = s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash')
    t.isFalse(ok, 'MarkWalkedOut recorded nothing when it was handed no name')
    t.equals(err, 'error.bets_closed')
end)

t.test('and a name passed in beats a framework that would answer differently', function()
    -- The argument is the authority, not a hint. If it were only consulted
    -- when the lookup failed, a framework mid-swap could overwrite it.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    s.betting.MarkWalkedOut(matchId, 2, 'CID-FROM-THE-ROSTER')
    match.players[2] = nil

    -- Somebody else is on that seat now, with a different name.
    s.qbx.players[2].citizenid = 'CID999'
    t.isTrue(s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash'),
        'a stranger on the freed seat was refused')

    -- ...and the character the roster named is still caught, on any seat.
    s.qbx.players[4].citizenid = 'CID-FROM-THE-ROSTER'
    t.isFalse(s.betting.PlaceSpectatorBet(4, matchId, 1, 2000, 'cash'),
        'the name the roster passed in was not the one remembered')
end)

t.test('and a walker NOBODY can name still holds their seat shut', function()
    -- THE LAST FALLBACK, and two mutations survived until it was written.
    --
    -- Every test above has a name available from one side or the other, so
    -- the character half of the rule answered all of them and the seat half
    -- could be deleted with the suite still green. This is the case it
    -- exists for: no name on the roster row, and a framework that cannot
    -- supply one either. The seat is then the whole of what is known, and
    -- the seat is what answers -- which is what this did before it knew any
    -- names at all.
    --
    -- IT ERRS TOWARDS REFUSING, deliberately. Somebody handed the freed id
    -- is turned down here, and that is the cost: refusing one newcomer a
    -- bet is a smaller wrong than selling a wager on a round the person in
    -- front of you abandoned, and there is nothing left to tell the two
    -- apart.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    s.qbx.players[2] = nil
    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil

    -- Somebody is on that seat now -- named, but there is no name on record
    -- to compare theirs against.
    s.qbx.players[2] = {
        citizenid = 'CID404', name = 'Anybody',
        money = { cash = 50000, bank = 0 },
        job = { name = 'unemployed', grade = { level = 0 } },
    }

    local ok, err = s.betting.PlaceSpectatorBet(2, matchId, 1, 2000, 'cash')
    t.isFalse(ok, 'a seat nobody could put a name to was left open on a live round')
    t.equals(err, 'error.bets_closed')

    -- AND ONLY THAT SEAT. An unnamed walker must not shut the book on the
    -- rest of the server -- that would be the worse half of the same bug.
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 2000, 'cash'),
        'an unnamed walker shut the round to everybody')
end)

t.test('and the panel is told, so it stops selling a bet the server refuses', function()
    -- THE RULE WAS RIGHT AND INVISIBLE. The roster no longer holds a walker,
    -- so the panel saw an ordinary onlooker: it drew an enabled Place Bet
    -- button with the stake and the account written out underneath, and the
    -- server answered error.bets_closed on the click. Nothing on the wire
    -- carried the one question their old seat still answers.
    local s, matchId = liveRoundWithGrace()
    local match = s.lobby.Get(matchId)

    t.equals(#s.state(2).player.walkedOut, 0,
        'somebody still fighting is listed as having walked out')

    s.betting.MarkWalkedOut(matchId, 2)
    match.players[2] = nil

    local listed = s.state(2).player.walkedOut
    t.equals(#listed, 1, 'the panel was not told the player walked out of anything')
    t.equals(listed[1], matchId, 'the panel was told about the wrong match')

    -- AND NOT EVERYBODY ELSE. A shared field would shut the book for the
    -- watchers too, which is the opposite defect.
    t.equals(#s.state(3).player.walkedOut, 0,
        'a watcher was told THEY had walked out of the round')
end)

-- ========================================================================
-- THE SERVER DOES NOT FUND BETS, AND THAT IS NOT A DEFAULT -- IT IS A GATE
--
-- A 'pool' bet is other players' money: whatever one bettor wins, another
-- lost, and the arena creates nothing. An 'odds' bet is the OPERATOR'S money,
-- and the person placing it can be the person deciding the result.
--
-- MEASURED, NOT ARGUED. One player, one alt they also control, one rigged
-- round, profit summed across BOTH accounts:
--
--     payout=pool  fee=0    stake=1,000     ->  +0
--     payout=pool  fee=500  stake=100,000   ->  +0
--     payout=odds  fee=0    stake=1,000     ->  +1,000
--     payout=odds  fee=500  stake=100,000   ->  +100,000
--
-- It scales with the stake, costs the farmer nothing, and repeats every
-- round. Config.Betting.allowServerFundedPayouts ships false and
-- Arena.BetPayoutMode refuses 'odds' without it.
-- ========================================================================

--- One rigged round: the farmer backs themselves and beats the alt.
--- @return integer profit across both accounts the farmer controls
local function farmProfit(mutate)
    local s = newArena({ [1] = 1000000, [2] = 1000000 }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.enabled = true
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.default = 500
        config.Betting.fighterBets.enabled = true
        config.Betting.fighterBets.min = 0
        config.Betting.fighterBets.max = 1000000
        config.Betting.spectatorBets.enabled = true
        config.Betting.spectatorBets.min = 0
        config.Betting.spectatorBets.oddsMultiplier = 2.0
        config.Betting.houseCutPercent = 0
        if mutate then mutate(config) end
    end)

    local before = s.qbx.players[1].money.cash + s.qbx.players[2].money.cash
    local matchId = s.lobby.Create(1, anArena(s), nil, 500, nil, nil, 'cash')
    t.isNotNil(matchId, 'the farm could not create a match')
    t.isTrue(s.lobby.Join(2, matchId, nil, 'cash'), 'the alt could not join')
    t.isTrue(s.betting.PlaceSpectatorBet(1, matchId, 1, 100000, 'cash'),
        'the farmer could not back themselves')

    local match = s.lobby.Get(matchId)
    match.state = 'live'
    for src, player in pairs(match.players) do player.alive = (src == 1) end
    s.betting.Settle(matchId, { winners = { 1 }, players = match.players })
    s.betting.SettleSpectatorBets(matchId, '1')
    s.step(); s.step(); s.step()

    return s.qbx.players[1].money.cash + s.qbx.players[2].money.cash - before
end

t.test('DEFECT: backing yourself to beat your own alt mints nothing', function()
    -- The shipped config: betPayout on 'pool', gate shut.
    t.equals(farmProfit(nil), 0, 'A RIGGED ROUND PAID THE FARMER')
end)

t.test('and writing betPayout = odds on its own still mints nothing', function()
    -- The operator asked for odds and did NOT open the gate, so it is refused
    -- and the bet settles as a pool bet -- which is zero-sum.
    t.equals(farmProfit(function(config)
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds',
                                     sharedPool = true, includeEntryPot = true }
    end), 0, 'ODDS RAN WITHOUT THE GATE BEING OPENED -- the printer is back')
end)

t.test('and the gate is what decides it, so the feature still exists', function()
    -- The control. Open it deliberately and the operator really is funding
    -- the win -- which is the whole reason it ships shut.
    local minted = farmProfit(function(config)
        config.Betting.allowServerFundedPayouts = true
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds',
                                     sharedPool = true, includeEntryPot = true }
    end)
    t.equals(minted, 100000,
        'opening the gate did not restore the odds payout, so the switch is not the thing deciding')
end)

t.test('the refusal is reported rather than left silent', function()
    local s = newArena({ [1] = 1000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout = { fighters = 'odds', spectators = 'pool' }
    end)
    t.isTrue(s.env.Arena.ServerFundedPayoutsRefused(),
        'an operator asking for odds with the gate shut was not flagged at all')
    t.equals(s.env.Arena.BetPayoutMode('fighter'), 'pool')
    t.equals(s.env.Arena.BetPayoutMode('spectator'), 'pool')
end)

t.test('and the BOOT LOG says it too, not just the flag behind it', function()
    -- THE FLAG WAS TESTED AND THE SENTENCE WAS NOT. A mutation sample of this
    -- session's own changes broke the validator's `if
    -- Arena.ServerFundedPayoutsRefused() then` and every spec still passed:
    -- the test above asserts the function, and nothing asserted that anybody
    -- is ever TOLD. An operator who writes betPayout = 'odds' and gets pool
    -- settlements in silence has no way to find out why.
    local s = newArena({ [1] = 1000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds' }
    end)

    local said = table.concat(s.env.Arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('allowServerFundedPayouts', 1, true) ~= nil,
        'the boot log never mentions the gate that is refusing their setting: ' .. said)
    t.isTrue(said:find('pool', 1, true) ~= nil,
        'and never says what is happening instead: ' .. said)
end)

t.test('and it says whether the odds multiplier is costing anything TODAY', function()
    -- The other half of the same block, and the other survivor. `onOdds` is
    -- what decides whether a bad multiplier is a live problem or a dormant
    -- one, and breaking it changed nothing any spec looked at.
    local function tailFor(mutate)
        local s = newArena({ [1] = 1000 }, function(config)
            config.Betting.enabled = true
            config.Betting.spectatorBets.oddsMultiplier = 0.5
            mutate(config)
        end)
        return table.concat(s.env.Arena.ValidateConfig() or {}, '\n')
    end

    -- GATE SHUT: the multiplier is written down and nothing is paid at it.
    local dormant = tailFor(function(config)
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds' }
        config.Betting.allowServerFundedPayouts = false
    end)
    t.isTrue(dormant:find('Nothing is paid at this number today', 1, true) ~= nil,
        'a dormant multiplier was reported as live: ' .. dormant)

    -- GATE OPEN: it is being paid right now, and the operator needs to know.
    local live = tailFor(function(config)
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds' }
        config.Betting.allowServerFundedPayouts = true
    end)
    t.isTrue(live:find('being paid out right now', 1, true) ~= nil,
        'a live multiplier was reported as harmless: ' .. live)
end)

t.test('and an operator on pool is not nagged about a gate they never asked for', function()
    local s = newArena({ [1] = 1000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout = { fighters = 'pool', spectators = 'pool' }
    end)
    t.isFalse(s.env.Arena.ServerFundedPayoutsRefused(),
        'a pool server was warned about odds it never set')
end)

t.test('the panel is told the mode the settlement will really use', function()
    -- The two used to read the config separately, so the panel could promise
    -- a multiplier the settlement was never going to pay.
    local s = newArena({ [1] = 1000 }, function(config)
        config.Betting.enabled = true
        config.Betting.betPayout = { fighters = 'odds', spectators = 'odds' }
    end)
    local wire = s.lobby.BuildState(1).config.betting.betPayout
    t.equals(wire.fighters, 'pool', 'the panel was promised odds the server refuses')
    t.equals(wire.spectators, 'pool', 'the panel was promised odds the server refuses')
end)

os.exit(t.summary())
