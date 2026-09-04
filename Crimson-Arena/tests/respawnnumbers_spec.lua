--[[
    crimson_arena/tests/respawnnumbers_spec.lua

    THE FIVE SECONDS AFTER A DEATH, which on the shipped config
    (`lives.default = 3`, `respawnDelaySeconds = 5`) happen several times
    a round, to everybody.

    A player lying on the floor waiting to be put back in has NOT lost.
    server/match.lua's own round-end rule has always known that -- it asks
    "alive, or lives left?" before deciding a winner -- but three other
    places asked a narrower question and got a different answer:

      * the scoreboard header counted `player.alive` alone, so a 1v1 read
        "Alive 1 / 2" for five seconds after every death while the round
        carried on. The one number a fighter is given to judge how much
        round is left told them it was already over;

      * the lobby snapshot reported the same flag under a field its own
        spec documents as "not out", so the spectator bet board struck a
        respawning fighter's name through and printed "somebody is out of
        this round" underneath -- every death, of anyone;

      * and a player who walked out of a live round forfeited their entry
        fee in silence. The lobby forfeit named the amount; the mid-round
        one, which is the one that costs money you have already spent a
        round earning, said nothing at all.

    None of that is visible to a test that only looks at a lobby, which is
    why none of it was caught: in a lobby every player has every life and
    `alive` is true, so the narrow question and the correct one agree.
    Every assertion below kills somebody first.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('respawnnumbers_spec')

-- ======================================================================
-- A REAL SERVER, WITH A ROUND THAT CAN ACTUALLY GO LIVE
-- ======================================================================

--- The real util/betting/lobby/match/main over the real config.
---
--- The point of difference from lobbyexit_spec's fixture, which this is
--- shaped after: that one holds the match FROZEN at 'countdown' on
--- purpose. This one needs the opposite -- a round that reaches 'live',
--- because only a live round has deaths in it.
--- @param mutate fun(config: table)?
--- @return table server
local function newServer(mutate)
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host',  money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
        [3] = { citizenid = 'CCC33333', name = 'Third', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents = {}, {}
    local flags = {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- A minute per read, so no RATE bucket in main.lua ever refuses:
        -- a throttled event and a refused one look identical from here.
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        -- Spread apart by server id, so the respawn picker's "furthest from
        -- the nearest threat" has a real answer rather than a tie.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
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
            Set = function(src, matchId) flags[src] = matchId end,
            Clear = function(src) flags[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return flags[src] ~= nil end,
            GetPlayerMatchId = function(src) return flags[src] end,
            ClearDownState = function() return 0 end,
            -- Not recorded: which routing bucket a player is standing in is
            -- tests/isolation_spec.lua's subject, and a table this file
            -- wrote and never read would only look like an assertion.
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- Straight into the fight: no lobby countdown, no frozen start, two
    -- players enough to begin. Three lives each is the shipped default and
    -- is the whole subject -- written down rather than inherited, so a
    -- server owner setting `lives = 1` cannot quietly make this file stop
    -- testing anything.
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.minPlayers = 2
    env.Config.Match.lives = { allowChoose = false, min = 1, max = 10, default = 3 }
    env.Config.Match.winCondition = 'last_standing'

    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- The last payload of one client event sent to one player.
    function server.lastPayload(event, target)
        local found
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                found = message.payload
            end
        end
        return found
    end

    --- How much has been sent so far, so a test can ask what happened
    --- AFTER a call rather than at any point in the round.
    ---
    --- THIS IS NOT TIDINESS. Taking a stake posts "$500 staked. It sits in
    --- the pot until this is settled." on the way IN, so a test that
    --- searched the whole session for "$500" found the joining message and
    --- passed with the forfeit notice deleted -- which is exactly what the
    --- first draft of this file did. Every money assertion below reads from
    --- a mark taken immediately before the departure.
    function server.mark() return #sent end

    --- Every notification sentence one player has been shown since `mark`,
    --- joined into one string. The real server/util.lua renders these off
    --- the real locale file, so a message whose key does not exist fails
    --- here rather than on somebody's screen.
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

    --- One player's row in the snapshot the panel renders, as another
    --- player receives it.
    function server.rowFor(viewer, target)
        local matches = server.lobby.BuildState(viewer).matches or {}
        for _, match in ipairs(matches) do
            for _, player in ipairs(match.players or {}) do
                if player.id == target then return player end
            end
        end
        return nil
    end

    return server
end

--- The key of the first arena this config ships enabled. Asked for rather
--- than written down: which arenas ship enabled is the operator's choice.
local function anArena(s)
    local arenas = s.env.Arena.GetEnabledArenas()
    t.isTrue(#arenas > 0, 'the config under test ships no enabled arena')
    return arenas[1].key
end

--- A live round with nobody dead yet.
---
--- THE ROSTER SIZE IS A REAL CHOICE, not a default worth ignoring. In a
--- 1v1 an ELIMINATION ends the round on the next sweep, and the sweep is
--- also the only thing that pushes a scoreboard -- so a test that wants to
--- read the header after an elimination has to leave somebody alive to
--- push it to.
--- @param fee integer? -- entry fee each, 0 for none
--- @param mutate fun(config: table)?
--- @param count integer? -- fighters, 2 by default
--- @return table server, string matchId
local function liveRound(fee, mutate, count)
    local s = newServer(mutate)
    local matchId, err = s.lobby.Create(1, anArena(s), nil, fee or 0, nil, nil, nil)
    t.isNotNil(matchId, 'the host could not create a match: ' .. tostring(err))

    for src = 2, (count or 2) do
        t.isTrue(s.lobby.Join(src, matchId, nil, nil),
            ('player %d could not join'):format(src))
    end

    for src = 1, (count or 2) do s.lobby.SetReady(src, true) end

    local started, why = s.match.Start(matchId)
    t.isTrue(started, 'the round never started: ' .. tostring(why))

    -- Start teleports everybody in and leaves the state at 'countdown';
    -- only goLive promotes it, one thread step later.
    s.step()

    local match = s.lobby.Get(matchId)
    t.equals(match.state, 'live', 'the round never reached "live", so nothing below is about a fight')
    return s, matchId
end

--- Kills `victim`, leaving them on the floor with lives still to spend.
--- Asserted rather than assumed: a death that took their LAST life is a
--- different case entirely, and would make every test here vacuous.
local function knockDown(s, matchId, victim, killer)
    local match = s.lobby.Get(matchId)
    s.fire('reportDeath', victim, { killerServerId = killer })

    local entry = match.players[victim]
    t.isFalse(entry.alive, 'the death report was refused, so nobody is down')
    t.isTrue((entry.lives or 0) > 0,
        'the victim spent their last life, so this is an elimination and not a respawn')
    return match
end

-- ======================================================================
-- THE SCOREBOARD HEADER
-- ======================================================================

t.test('a player waiting to respawn is still COUNTED in the header', function()
    local s, matchId = liveRound()
    knockDown(s, matchId, 2, 1)

    -- One step runs the sweep, which is what pushes the header.
    s.step()

    local hud = s.lastPayload('matchHud', 1)
    t.isNotNil(hud, 'no scoreboard was pushed at all')
    t.equals(hud.total, 2, 'the roster size changed when somebody merely died')
    t.equals(hud.remaining, 2,
        'a player with lives left was counted out of the round while they were waiting to come back')
end)

t.test('and is counted OUT once their last life is gone', function()
    -- The other direction, and the reason the first assertion is worth
    -- something: a header that answered 2 unconditionally would pass the
    -- test above and be just as wrong.
    -- Three of them, so one elimination leaves a round for the sweep to
    -- carry on pushing a header for.
    local s = liveRound(nil, function(config)
        config.Match.lives = { allowChoose = false, min = 1, max = 10, default = 1 }
    end, 3)

    s.fire('reportDeath', 2, { killerServerId = 1 })
    s.step()

    local hud = s.lastPayload('matchHud', 1)
    t.isNotNil(hud, 'no scoreboard was pushed at all')
    t.equals(hud.total, 3, 'the roster size changed when somebody was eliminated')
    t.equals(hud.remaining, 2, 'an eliminated player was still counted as being in the round')
end)

t.test('and the row itself still says they are not breathing', function()
    -- Two different facts, and the board needs both. The header counts who
    -- can still win; the row greys out a corpse. Collapsing them into one
    -- field is what made the header wrong, and collapsing them the other
    -- way would stop a death showing on the board at all.
    local s, matchId = liveRound()
    knockDown(s, matchId, 2, 1)
    s.step()

    local hud = s.lastPayload('matchHud', 1)
    local row
    for _, entry in ipairs(hud.scoreboard or {}) do
        if entry.id == 2 then row = entry end
    end

    t.isNotNil(row, 'the dead player fell off the scoreboard entirely')
    t.isFalse(row.alive, 'a player lying on the floor is drawn as though nothing had happened')
    t.isTrue(row.remaining, 'the row says they are out of a round they can still win')
end)

-- ======================================================================
-- THE SPECTATOR BET BOARD
-- ======================================================================

t.test('the snapshot reports a respawning fighter as still IN', function()
    -- html/app.js strikes a row through and prints "somebody is out of
    -- this round" off exactly this field.
    local s, matchId = liveRound()
    knockDown(s, matchId, 2, 1)

    local row = s.rowFor(1, 2)
    t.isNotNil(row, 'the dead player fell out of the snapshot entirely')
    t.isTrue(row.alive, 'a fighter who is coming back was reported knocked out of the match')
end)

t.test('and as OUT once they are actually eliminated', function()
    local s = liveRound(nil, function(config)
        config.Match.lives = { allowChoose = false, min = 1, max = 10, default = 1 }
    end)

    s.fire('reportDeath', 2, { killerServerId = 1 })

    local row = s.rowFor(1, 2)
    t.isNotNil(row, 'the eliminated player fell out of the snapshot entirely')
    t.isFalse(row.alive, 'an eliminated fighter is still shown as in the fight')
end)

-- ======================================================================
-- WALKING OUT OF A LIVE ROUND
-- ======================================================================

t.test('quitting mid-round SAYS what it cost', function()
    -- refundOnDisconnectDuringMatch ships false: the stake stays in the pot
    -- for whoever is still fighting for it. That is the intended rule. What
    -- was wrong is that the player it takes the money from was told nothing,
    -- and the only way to find out was to count your wallet afterwards.
    local s, matchId = liveRound(500)
    t.equals(s.betting.GetPot(matchId), 1000, 'both entry fees were not held against the match')

    local mark = s.mark()
    s.fire('leaveMatch', 2)

    -- The sentence AND the amount. server/betting.lua renders money as
    -- symbol-then-number, so a notice that named the wrong stake, or none at
    -- all, fails here.
    t.contains(s.noticesSince(mark, 2),
        'Stake gone: ' .. (s.env.Config.Betting.currencySymbol or '$') .. '500',
        'the quitter was never told what leaving cost them')

    -- SAYING SO IS NOT SETTLING. The stake stays escrowed against the match
    -- for whoever is still fighting for it; a notice that moved money would
    -- hand the quitter their forfeit straight back.
    t.equals(s.betting.GetPot(matchId), 1000,
        'telling the quitter what it cost also paid it back to them')
end)

t.test('and a refunding server says the opposite, not nothing', function()
    -- The same call, the other setting: the guard that makes the assertion
    -- above worth having. A message that fired on every departure whatever
    -- the rule says would pass that test and be a lie half the time.
    local s, matchId = liveRound(500, function(config)
        config.Betting.refundOnDisconnectDuringMatch = true
    end)

    local mark = s.mark()
    s.fire('leaveMatch', 2)

    t.equals(s.betting.GetPot(matchId), 500, 'the refund never left escrow')
    t.notContains(s.noticesSince(mark, 2), 'Stake gone',
        'a player who WAS refunded was told their stake had been kept')
end)

t.test('and a free round says nothing about money at all', function()
    -- Nobody paid anything, so there is nothing to forfeit and nothing to
    -- announce. A notice here would be noise on the commonest lobby there
    -- is -- and it would name $0.
    --
    -- GUARDED TWICE, which is why this one is the only assertion in the
    -- file that no SINGLE mutation breaks: server/lobby.lua refuses to call
    -- KeepInPot on a player holding nothing, and KeepInPot itself refuses a
    -- stake that was never taken. Break either alone and the other still
    -- catches it; break both -- `if true then` here, `or { amount = 0 }`
    -- there -- and this fails with "Stake gone: $0. Nothing comes back."
    local s = liveRound(0)

    local mark = s.mark()
    s.fire('leaveMatch', 2)

    t.notContains(s.noticesSince(mark, 2), 'Stake gone',
        'a player who staked nothing was told they had lost a stake')
end)

-- ======================================================================
-- WHAT THE OVERLAY SAYS THE ROUND IS WORTH
-- ======================================================================

t.test('the HUD shows the PRIZE POOL, not the entry pot alone', function()
    -- server/lobby.lua's match card was changed to GetPrizePool for a
    -- written reason: with betPayout.includeEntryPot on -- the shipped
    -- default -- the side-bets settle in the same pool, so a screen showing
    -- only the entry half stands still while a player watches their own
    -- stake go into the part it cannot see. The in-arena HUD was missed, so
    -- a fighter read one number for a whole round while the lobby card read
    -- another, and the winner was paid the larger one.
    local s, matchId = liveRound(500)

    -- A watcher backs somebody. That money is in the prize pool and NOT in
    -- the entry pot, which is what makes the two figures differ at all.
    t.isTrue(s.betting.PlaceSpectatorBet(3, matchId, 1, 1000, 'cash'),
        'the side-bet was refused, so both figures would agree and this proves nothing')

    local entryOnly = s.betting.GetPot(matchId)
    local prize = s.betting.GetPrizePool(matchId)
    t.isTrue(prize > entryOnly,
        ('the two figures agree (%d vs %d), so this test cannot tell them apart')
            :format(prize, entryOnly))

    s.step()

    local hud = s.lastPayload('matchHud', 1)
    t.isNotNil(hud, 'no scoreboard was pushed at all')
    t.equals(hud.pot, prize, 'the overlay showed the entry pot rather than what the winner is paid')
end)

t.summary()
