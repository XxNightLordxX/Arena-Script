--[[
    crimson_arena/tests/matchflow_spec.lua

    One whole round, driven end to end through the REAL server/match.lua over
    the REAL config.lua, shared/arena.lua and server/util.lua: a lobby is put
    into the arena, a fighter is eliminated, another walks out mid-round, and
    the round is settled.

    THE SERVER HALF ASSERTS ON TWO EDGES AND NOTHING ELSE -- what went on the
    wire, and the one table this file hands to the money. Everything past
    either of those belongs to a client file or to server/betting.lua, and a
    spec that stubbed its way across one would only be proving the stub.

    ONE SECTION AT THE BOTTOM CROSSES THE WIRE ON PURPOSE, and says why: the
    respawn is the one step of a round whose contract is about the ORDER the
    client does things in during the frames after the message lands, which no
    assertion on this side can see. It loads the real client/match.lua rather
    than describing it.

    WHAT IS STUBBED, and no more: the lobby that owns the match record, the
    escrow, the leaderboard, the dispatch flag and the routing bucket, and
    CreateThread/Wait. The player-facing messages come from the real
    server/util.lua, so a message whose locale key does not exist fails here,
    in the sandbox's locale(), rather than on somebody's screen.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('matchflow_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- The lobby that owns the match record. Only the functions
--- server/match.lua actually calls are here -- a file that starts calling a
--- twelfth one fails as a nil call naming it rather than passing against a
--- fixture that agreed with it in advance.
---
--- Leave() and AddSpectator() are MODELLED, not silenced, because this file
--- measures what a departure and an elimination do to the round: a Leave
--- that left the roster alone would make the payout-roster tests below
--- assert nothing at all.
--- @return table lobby
local function newLobby()
    local matches = {}
    local lobby = { destroyed = {}, left = {}, spectating = {}, refuseSpectators = false }

    function lobby.Get(matchId) return matches[matchId] end

    function lobby.GetByPlayer(src)
        for _, match in pairs(matches) do
            if match.players[src] then return match end
        end
        return nil
    end

    function lobby.All()
        local out = {}
        for _, match in pairs(matches) do out[#out + 1] = match end
        return out
    end

    -- Join order, exactly like the real one: the winners list -- and so the
    -- payout order -- must not depend on pairs().
    function lobby.PlayerArray(match)
        local out = {}
        if type(match) ~= 'table' then return out end
        for _, src in ipairs(match.order or {}) do
            local player = match.players[src]
            if player then out[#out + 1] = player end
        end
        return out
    end

    function lobby.PlayerCount(match) return #lobby.PlayerArray(match) end
    function lobby.Broadcast() end

    --- server/lobby.lua admits a fighter of THIS match as a spectator only
    --- once they are out of it, and refuses anybody still in the fight.
    --- Modelled rather than always-yes because match.lua now believes the
    --- answer.
    function lobby.AddSpectator(src, matchId)
        local match = matches[matchId]
        if not match then return false, 'error.match_not_found' end
        if lobby.refuseSpectators then return false, 'error.already_in_match' end

        local player = match.players[src]
        if player and (player.alive == true or (player.lives or 0) > 0) then
            return false, 'error.already_in_match'
        end

        match.spectators[src] = true
        lobby.spectating[#lobby.spectating + 1] = { src = src, matchId = matchId }
        return true
    end

    function lobby.RemoveSpectator(src)
        for _, match in pairs(matches) do match.spectators[src] = nil end
        return true
    end

    -- MODELLED, NOT SILENCED, like Leave below. server/match.lua asks this
    -- before it touches a departing player -- a lobby or countdown the player
    -- has a side-bet on will not let them out -- and a stub that answered nil
    -- would crash RemovePlayer rather than let this file measure it. Nothing
    -- in this file places a bet, so the honest model of the shipped answer is
    -- "yes, always".
    function lobby.MayLeave() return true end

    function lobby.Leave(src, reasonKey)
        local match = lobby.GetByPlayer(src)
        if not match then return false end

        match.players[src] = nil
        match.spectators[src] = nil
        for index, id in ipairs(match.order) do
            if id == src then table.remove(match.order, index) break end
        end
        lobby.left[#lobby.left + 1] = { src = src, reason = reasonKey }

        if next(match.players) == nil then lobby.Destroy(match.id, reasonKey) end
        return true
    end

    function lobby.Destroy(matchId, reasonKey)
        lobby.destroyed[#lobby.destroyed + 1] = { id = matchId, reason = reasonKey }
        matches[matchId] = nil
    end

    --- Test-side: puts a record where Get and GetByPlayer will find it.
    function lobby.put(match) matches[match.id] = match end

    return lobby
end

--- One arena server: real config, real rules, real util.lua, real
--- match.lua, and stand-ins for everything match.lua leans on but does not
--- own. Fresh per test.
--- @param mutate fun(config: table)? -- applied before match.lua is loaded
--- @return table fixture
local function newFixture(mutate)
    local sent, console = {}, {}
    local runner = Sandbox.newThreadRunner()
    local lobby = newLobby()
    local recorded, settled = {}, {}

    -- What the escrow answers with, and what Settle hands back. Owned by the
    -- test so a payout can be described without a second betting stub.
    local money = { pot = 0, stake = 0, payouts = {} }

    local revived = {}
    local inArena = {}       -- every ArenaDispatch.Revive(src), in order

    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        print = function(line) console[#console + 1] = line end,
        GetPlayerName = function(src) return ('Fighter %d'):format(src) end,
        exports = { qbx_core = { GetPlayer = function() return nil end } },

        ArenaLobby = lobby,
        ArenaStats = { RecordMatch = function(match) recorded[#recorded + 1] = match end },
        ArenaAmmo = {
            -- No-op double. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; here it only has to exist, because
            -- server/match.lua calls it at both arena choke points.
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
            -- THE FLAG IS TRACKED RATHER THAN SWALLOWED. server/match.lua's
            -- bucket sweep asks IsPlayerInArena to tell the LOBBY countdown
            -- from the frozen one -- the two share a state name and nothing
            -- else separates them -- so a stub without it is a nil call, and
            -- one that always answered `false` would quietly make the sweep
            -- skip every match this file starts.
            Set = function(src, matchId) inArena[src] = matchId or true end,
            Clear = function(src) inArena[src] = nil end,
            IsPlayerInArena = function(src) return inArena[src] ~= nil end,
            -- Recorded, not swallowed: the arena telling whatever handles
            -- death that a player is alive again is the whole reason a
            -- player does not walk out of a match still dead, so WHO gets
            -- told and HOW MANY TIMES is the thing worth asserting.
            Revive = function(src)
                revived[#revived + 1] = src
            end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
        ArenaBetting = {
            -- Refunds are not earnings, and server/match.lua asks this to
            -- tell them apart. A double missing it is a nil call naming it.
            IsRefundReason = function(reason)
                return type(reason) == 'string' and reason:sub(1, 6) == 'refund'
            end,
            GetPot = function() return money.pot end,
            GetStake = function() return money.stake end,
            Settle = function(matchId, context)
                -- The whole point of this file's last section: the context is
                -- kept exactly as it arrived, never normalised.
                settled[#settled + 1] = { id = matchId, context = context }
                return money.payouts
            end,
            -- goLive schedules ONE broadcast at the instant the side-bet
            -- window shuts, and asks this when it is. nil is "no window to
            -- wait on", which is the right answer for a fixture that models
            -- no betting at all.
            SecondsUntilBetsClose = function() return nil end,
            SettleSpectatorBets = function() end,
            RefundAll = function() end,
            Clear = function() end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    -- Loaded by hand here rather than through newArenaEnv, so the arenas are
    -- switched on by hand too. Nothing in this file is about which ones an
    -- operator ships enabled.
    Sandbox.enableAllArenas(env)
    -- And the doors, for the same reason the fixture does it: this spec
    -- is about routing buckets, not about what time it is.
    Sandbox.openTheDoors(env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/match.lua', env)

    local fixture = {
        env = env,
        M = env.ArenaMatch,
        Arena = env.Arena,
        Config = env.Config,
        lobby = lobby,
        sent = sent,
        money = money,
        recorded = recorded,
        settled = settled,
        revived = revived,
        --- How many revives have been aimed at `src`.
        lastRevive = function(src)
            local count = 0
            for _, id in ipairs(revived) do
                if id == src then count = count + 1 end
            end
            return count
        end,
    }

    --- One pass of every live thread. The FIRST call only primes the sweep,
    --- which waits before it works.
    function fixture.step() runner.step() end

    --- Every payload of `event` sent to `target` (any target when nil).
    --- @return table[]
    function fixture.payloads(event, target)
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == event and (target == nil or message.target == target) then
                out[#out + 1] = message.payload
            end
        end
        return out
    end

    --- How many times `target` was sent `event`. Counted off the messages
    --- rather than their payloads, because closePanel carries none and a
    --- nil appended to an array is not an element.
    --- @return integer
    function fixture.count(event, target)
        local total = 0
        for _, message in ipairs(sent) do
            if message.event == event and (target == nil or message.target == target) then
                total = total + 1
            end
        end
        return total
    end

    --- The last payload of `event` sent to `target`, or nil.
    function fixture.lastPayload(event, target)
        local all = fixture.payloads(event, target)
        return all[#all]
    end

    --- Where in the whole outbound stream `target` first saw `event`, so two
    --- messages to one player can be put in order. nil when it never arrived.
    --- @return integer|nil
    function fixture.firstIndex(event, target)
        for index, message in ipairs(sent) do
            if message.event == event and message.target == target then return index end
        end
        return nil
    end

    --- What one player was told, in order, through this resource's own
    --- notification relay.
    --- @return table[] -- { { description, type } }
    function fixture.told(target)
        return fixture.payloads('crimson_arena:client:notify', target)
    end

    function fixture.log() return table.concat(console, '\n') end

    return fixture
end

--- The round rules these tests drive: no countdowns to wait out, and one
--- life, so a single death eliminates.
--- @param config table
local function instantRound(config)
    config.Match.lobbyCountdownSeconds = 0
    config.Match.startCountdownSeconds = 0
    config.Match.respawnDelaySeconds = 0
    config.Match.lives = 1
end

--- A lobby record in the shape server/lobby.lua builds one.
--- @param fixture table
--- @param count integer -- how many fighters
--- @return table match
local function newMatch(fixture, count)
    local match = {
        id = 'm1',
        label = 'test match',
        arenaKey = 'trailerpark',
        modeKey = 'ffa',
        hostSource = 1,
        state = 'lobby',
        -- LIVES LIVE ON THE MATCH NOW, not in config: the host picks the
        -- number when they open the lobby, and every player seeded into that
        -- match takes it from here. A fixture that builds a match by hand has
        -- to say what the host chose -- left nil, every player is seeded with
        -- one life and a round ends on the first death.
        --
        -- Resolved through the real function against this fixture's own
        -- config, so a spec that sets Config.Match.lives still gets what it
        -- asked for rather than a literal written here.
        lives = fixture.Arena.ResolveLives(nil),
        entryFee = 1000,
        createdAt = os.time(),
        startsAt = 0,
        endsAt = 0,
        players = {},
        order = {},
        spectators = {},
    }

    for index = 1, count do
        match.players[index] = {
            src = index,
            citizenid = ('CID%03d'):format(index),
            name = ('Fighter %d'):format(index),
            team = nil,
            ready = true,
            loadout = (fixture.Arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })),
            kills = 0,
            deaths = 0,
            alive = true,
            lives = math.max(1, fixture.Arena.ToInt(fixture.Config.Match.lives) or 1),
            stake = 1000,
            joinedAt = os.time(),
            placement = 0,
        }
        match.order[#match.order + 1] = index
    end

    fixture.lobby.put(match)
    return match
end

--- Start the match and let the freeze thread run, so the round is live.
--- @param fixture table
--- @param match table
local function goLive(fixture, match)
    local ok, reason = fixture.M.Start(match.id)
    t.isTrue(ok, ('Start refused: %s'):format(tostring(reason)))
    fixture.step()
    t.equals(match.state, 'live', 'match never went live')
end

-- ======================================================================
-- F20 -- THE PANEL IS CLOSED ON THE WAY INTO THE ARENA
--
-- The panel is where a player waits to be readied, so it is very often the
-- thing holding NUI focus at the moment the server teleports them in. The
-- event that releases that focus is registered in client/ui.lua; until this
-- was sent, nothing in either realm fired it.
-- ======================================================================

t.test('every fighter placed in the arena is told to close the panel, exactly once', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 3)

    goLive(f, match)

    for src = 1, 3 do
        t.equals(f.count('crimson_arena:client:closePanel', src), 1,
            ('fighter %d was not told to close the panel'):format(src))
    end
end)

t.test('the panel is closed before the client is told to teleport in', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)

    goLive(f, match)

    -- Focus has to go before the ped moves: released afterwards, there is a
    -- window in which the player is standing in the arena with every input
    -- still going to the browser.
    for src = 1, 2 do
        local closed = f.firstIndex('crimson_arena:client:closePanel', src)
        local entered = f.firstIndex('crimson_arena:client:enterArena', src)
        t.isNotNil(closed, ('fighter %d never got closePanel'):format(src))
        t.isNotNil(entered, ('fighter %d never got enterArena'):format(src))
        t.isTrue(closed < entered, ('fighter %d was teleported in before the panel was closed'):format(src))
    end
end)

t.test('a spectator, who was never placed in the arena, is not told to close anything', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    t.isTrue(f.lobby.AddSpectator(9, match.id))

    goLive(f, match)

    -- Closing the panel is what entering the arena costs. Somebody watching
    -- from the menu has not entered anything, and shutting their panel would
    -- take the screen they are using away from them.
    t.equals(f.count('crimson_arena:client:closePanel', 9), 0)
end)

-- ======================================================================
-- F21 -- SERVER MESSAGES GO THROUGH THIS RESOURCE'S OWN RELAY
--
-- ArenaUI.Notify chooses between the panel's toast rail and ox_lib based on
-- whether the panel is up. Triggering 'ox_lib:notify' from the server
-- answered that question for it -- and answered it wrong for every refusal
-- a player raises from inside the panel, which ox_lib then draws underneath
-- the panel's own full-screen scrim.
-- ======================================================================

t.test('an elimination reaches the player as this resource own relay, in the shape ArenaUI.Notify reads', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))

    local told = f.told(2)
    t.equals(#told, 1, 'the eliminated player was told once')
    -- The two fields client/ui.lua's handler reads. The title is deliberately
    -- absent: ArenaUI.Notify puts Config.NotifyTitle back on the ox_lib path
    -- and the panel rail does not want one.
    t.equals(told[1].description, f.env.locale('notify.eliminated'))
    t.equals(told[1].type, 'error')
end)

t.test('nothing a whole round says is addressed to ox_lib', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    -- Start, elimination and settlement between them cover every message a
    -- round sends. Not one of them may pick the client's renderer for it.
    for _, message in ipairs(f.sent) do
        if message.event == 'ox_lib:notify' then
            error(('a round message was sent straight to ox_lib for %s'):format(tostring(message.target)))
        end
    end

    -- ...and the messages really were sent, so the loop above is not passing
    -- on an empty stream.
    t.isTrue(f.count('crimson_arena:client:notify') > 0, 'no notifications were sent at all')
end)

-- ======================================================================
-- ELIMINATION AND THE SPECTATOR CAMERA
--
-- `spectate` is the client's instruction to come out of the dead-state hold
-- and open the camera. The only thing that keeps an eliminated player out of
-- the round afterwards is the registry listing them as a spectator, so the
-- flag has to say what the registry actually did.
-- ======================================================================

t.test('an eliminated fighter is told to open the camera once the registry has taken them', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))

    local payload = f.lastPayload('crimson_arena:client:eliminated', 2)
    t.isNotNil(payload, 'the eliminated player was never told')
    t.isTrue(payload.spectate, 'the camera was refused to a player the registry accepted')
    t.isTrue(match.spectators[2] == true, 'the registry never recorded them as watching')
end)

t.test('an eliminated player is revived for the medical script and NOT released', function()
    -- The server revives an eliminated player on purpose -- to get them off
    -- the medical script's casualty list -- while the round carries on
    -- without them. What it must not do is free them: spectate re-hides and
    -- re-freezes the parked body but never restores invincibility, so a
    -- released player is MORTAL and killable, and with spectate off they
    -- simply stand back up, armed, in a live round.
    --
    -- ASSERTED AS "NOTHING RELEASES", not as a flag. Revive used to take a
    -- `keepHold` argument that its own body never read, so a test that
    -- checked the flag was passed proved nothing about the hold. The hold is
    -- kept by client/match.lua's `eliminated` handler releasing nothing, and
    -- that is what the client test below pins.
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    -- COUNTED FROM THE DEATH, not from the start of time: everybody is
    -- revived once on the way INTO the arena now -- nobody starts a round
    -- dead -- so a fixed total here would be measuring that entry revive as
    -- well as the one this test is about.
    --
    -- AND AS A DELTA, not as `>= 1`. The entry revive has already happened
    -- by this line, so `>= 1` was satisfied before OnDeath was called at all
    -- -- deleting the elimination revive outright left this test green.
    local before = f.lastRevive(2)
    t.isTrue(f.M.OnDeath(2, 1))

    t.equals(f.lastRevive(2), before + 1,
        'the eliminated player was never revived for the medical script')
    t.isNil(f.lastPayload('crimson_arena:client:respawn', 2),
        'an eliminated player was sent a respawn, which is what releases the hold')
end)

t.test('a registry that refuses the spectator refuses the camera with it', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.lobby.refuseSpectators = true
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))

    -- Telling the client to open a camera the server did not register leaves
    -- them released from the dead-state hold and standing in a live round the
    -- next time the lobby broadcasts. Keeping the hold is the recoverable
    -- half of that choice.
    local payload = f.lastPayload('crimson_arena:client:eliminated', 2)
    t.isNotNil(payload)
    t.isFalse(payload.spectate)
    t.isNil(match.spectators[2])
end)

-- ======================================================================
-- F19 -- THE RESULTS BOARD IS SENT
--
-- The board the README promises at payout is drawn by client/ui.lua's
-- `crimson_arena:client:results` handler, and until this file fired it that
-- handler had no sender. The figures did go out -- inside the exitArena
-- payload, which the client's teardown reads for its return coordinates and
-- nothing else, so they arrived and were dropped. They still ride that
-- payload; what the tests below measure is the message that gets drawn.
--
-- `earnings` is the reason the board matters and the reason it is asserted
-- on hardest: what a fighter was actually paid out of the pot is worked out
-- here and said nowhere else.
-- ======================================================================

t.test('the winner leaves with a results block naming their placement, score and earnings', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    f.money.stake = 1000
    f.money.payouts = { { id = 1, amount = 1800, reason = 'winner' } }

    goLive(f, match)
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    local results = f.lastPayload('crimson_arena:client:results', 1)
    t.isNotNil(results, 'the winner was never sent a results board')

    -- HOW THE ROUND ENDED, as a SENTENCE. This field used to carry the
    -- locale key, which the panel has no locale file to render -- so it was
    -- dead on the wire for as long as it existed. `matchId` sat beside it,
    -- read by nothing, and went with it.
    t.isTrue(type(results.reason) == 'string' and #results.reason > 0,
        'the board carries no sentence saying how the round ended')
    t.notContains(results.reason, 'match.',
        'the board was sent a locale key rather than the sentence it renders to: ' .. tostring(results.reason))
    t.isNil(results.matchId, 'the results block still carries a match id nothing reads')
    t.isTrue(results.won)
    t.equals(results.placement, 1)
    t.equals(results.kills, 1)
    t.equals(results.deaths, 0)
    -- The one figure that exists nowhere else: what they were actually paid
    -- out of the pot.
    t.equals(results.earnings, 1800)
    t.equals(#results.scoreboard, 2)
end)

t.test('the loser leaves with the same board and nothing earned', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    f.money.payouts = { { id = 1, amount = 1800, reason = 'winner' } }

    goLive(f, match)
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    local results = f.lastPayload('crimson_arena:client:results', 2)
    t.isNotNil(results)
    t.isFalse(results.won)
    t.equals(results.placement, 2)
    t.equals(results.deaths, 1)
    t.equals(results.earnings, 0)
    t.equals(#results.scoreboard, 2)
end)

t.test('a spectator is sent the board too, and is owed nothing by it', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    t.isTrue(f.lobby.AddSpectator(9, match.id))
    f.money.pot = 2000
    f.money.payouts = { { id = 1, amount = 2000, reason = 'winner' } }

    goLive(f, match)
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    -- The board is the only reason a spectator is told anything at the end
    -- of a round they were never in.
    local results = f.lastPayload('crimson_arena:client:results', 9)
    t.isNotNil(results, 'the spectator was sent home with nothing to show for it')
    -- AND IT IS THE ONLY THING THAT TELLS THEM. A spectator is sent no
    -- notification at the end of a round -- they staked nothing and won
    -- nothing -- so a board with no sentence on it left the one person
    -- watching with no idea how the fight had finished.
    t.isTrue(type(results.reason) == 'string' and #results.reason > 0,
        'the spectator\'s board never says how the round ended')
    t.isFalse(results.won)
    t.equals(results.earnings, 0)
    t.equals(#results.scoreboard, 2)
end)

t.test('the board arrives after the player has been sent home, not before', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    f.money.payouts = { { id = 1, amount = 1800, reason = 'winner' } }

    goLive(f, match)
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    -- The teardown is what closes the round down on the client. A board
    -- drawn ahead of it would be cleared by the tidy-up that follows.
    for src = 1, 2 do
        local home = f.firstIndex('crimson_arena:client:exitArena', src)
        local board = f.firstIndex('crimson_arena:client:results', src)
        t.isNotNil(home)
        t.isNotNil(board)
        t.isTrue(home < board, ('fighter %d saw the board before they were sent home'):format(src))
    end
end)

-- ======================================================================
-- F22 -- THE ROSTER THE PAYOUT IS JUDGED ON
--
-- Two different head counts ride in the same table and they are not the same
-- number. `players` is who is still here to be PAID. `contestants` is how
-- many the round was FOUGHT with, and it is the one Config.Betting
-- .minPlayersToPayOut has to be counted against -- read off the survivors
-- instead, a 1v1 that one side quits reads as "too few players", refunds the
-- whole pot, hands the quitter back the stake leaving was supposed to
-- forfeit, and pays the winner nothing.
-- ======================================================================

--- The context server/match.lua handed the money, exactly as it arrived.
--- @param fixture table
--- @return table
local function settlement(fixture)
    t.equals(#fixture.settled, 1, 'the round settled once')
    return fixture.settled[1].context
end

t.test('a mid-round quitter is off the roster that gets paid', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    goLive(f, match)

    -- Fighter 2 walks out of a fight they are losing. Their stake stays in
    -- the pot; their name must not stay on the list the pot is handed to.
    t.isTrue(f.M.RemovePlayer(2, 'match.left'))
    f.step()

    local context = settlement(f)
    t.equals(#context.players, 1)
    t.equals(context.players[1].id, 1)
    t.equals(#context.winners, 1)
    t.equals(context.winners[1], 1, 'the survivor took the round')
end)

t.test('the payout is judged on how many fought, not on how many are left', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    goLive(f, match)

    t.isTrue(f.M.RemovePlayer(2, 'match.left'))
    f.step()

    local context = settlement(f)
    t.equals(context.contestants, 2, 'the round was fought by two')

    -- The whole reason the count is carried separately: the survivors alone
    -- are below the shipped threshold, so a payout judged on them would
    -- refund a round that was properly won.
    t.equals(f.Config.Betting.minPlayersToPayOut, 2)
    t.isTrue(#context.players < f.Config.Betting.minPlayersToPayOut)
end)

t.test('an eliminated fighter is still a contestant and still on the paid roster', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    f.money.pot = 2000
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    -- Losing is not leaving. They fought the round to the end, so a round
    -- that refunds owes them their stake like anybody else.
    local context = settlement(f)
    t.equals(context.contestants, 2)
    t.equals(#context.players, 2)
end)

t.test('somebody who backed out during the frozen countdown was never a contestant', function()
    local f = newFixture(function(config)
        instantRound(config)
        -- The freeze is what makes the window real; the thread runner is what
        -- makes it steppable. Start places everybody, goLive runs on the next
        -- step, and this test acts in between.
        config.Match.startCountdownSeconds = 5
    end)
    local match = newMatch(f, 3)

    t.isTrue((f.M.Start(match.id)))
    t.equals(match.state, 'countdown')
    t.isTrue(f.M.RemovePlayer(3, 'match.left'))

    -- Their stake went home with them -- ArenaLobby.Leave reads that phase as
    -- "before start" -- so counting them would judge the pot against money it
    -- does not hold.
    f.step()
    f.step()
    t.equals(match.state, 'live')
    t.equals(match.contestants, 2)

    f.money.pot = 2000
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    local context = settlement(f)
    t.equals(context.contestants, 2)
end)

t.test('every winner handed to the payout is somebody still on the roster', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 3)
    f.money.pot = 3000
    goLive(f, match)

    t.isTrue(f.M.RemovePlayer(3, 'match.left'))
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    local context = settlement(f)
    local paid = {}
    for _, player in ipairs(context.players) do paid[player.id] = true end
    for _, id in ipairs(context.winners) do
        t.isTrue(paid[id] == true, ('winner %s is not on the roster being paid'):format(tostring(id)))
    end
end)

-- ========================================================================
-- NOBODY WALKS OUT OF A MATCH STILL DEAD
--
-- The arena stands its own players up, and for the character model that is
-- the whole job. It is not the whole job for the server: a medical or
-- ambulance script keeps its own record of who is dead, and nothing about
-- resurrecting a body reaches it.
--
-- There are two calls, on purpose. The per-player one runs as each player is
-- sent home -- BEFORE the body is stood up, before the teleport, before they
-- leave the arena instance -- so a script told "alive" then is being told it
-- about somebody who is still a corpse somewhere else, and anything it does
-- can be undone by the teardown behind it. The sweep runs once afterwards,
-- over the whole roster, when everybody is home.
-- ========================================================================

t.test('every player is revived on the way out of a finished match', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    f.M.End(match.id, 'match.ended', { 1 })

    local seen = {}
    for _, src in ipairs(f.revived) do seen[src] = true end
    t.isTrue(seen[1], 'the winner was never revived')
    t.isTrue(seen[2], 'the loser was never revived -- they walk out still dead')
end)

t.test('and swept again once everybody is home', function()
    -- The belt to the exit path's braces, and the thing the operator asked
    -- for after watching players stay dead anyway. It runs on a delay, so
    -- stepping the threads is what makes it happen.
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    f.M.End(match.id, 'match.ended', { 1 })
    local duringExit = #f.revived

    f.step()
    f.step()

    t.isTrue(#f.revived > duringExit,
        'the post-match sweep never ran -- a player the exit path missed stays dead')
end)

t.test('the sweep can be switched off without breaking the exit path', function()
    local f = newFixture(instantRound)
    f.Config.Dispatch.revive.sweepAfterMatchMs = 0

    local match = newMatch(f, 2)
    goLive(f, match)

    f.M.End(match.id, 'match.ended', { 1 })
    local duringExit = #f.revived

    f.step()
    f.step()

    t.equals(#f.revived, duringExit, 'the sweep ran with its delay set to 0')
    t.isTrue(duringExit >= 2, 'and the per-player revives stopped happening too')
end)

-- ========================================================================
-- THE CLIENT END OF A RESPAWN -- the REAL client/match.lua
--
-- Everything above stops at the wire, because everything above is a
-- PAYLOAD question. A respawn is the one step of the round where the two
-- sides have to agree about TIME instead: the server sends one message,
-- and the client then spends however many frames the ground takes to
-- stream standing that body back up. What the client does DURING those
-- frames is not visible on any wire, so it is asserted here, against the
-- real file, or nowhere.
-- ========================================================================

--- One fresh, fully isolated load of the REAL client/match.lua, with the
--- respawn handler drivable a frame at a time.
---
--- THE GROUND IS THE FIXTURE'S TO GIVE, and that is the whole trick.
--- placeAt waits for collision to stream in and that wait is a YIELD; the
--- window these tests are about lives inside it. `f.groundReady` is what
--- ends it, so a test can park the handler mid-placement, shoot the player,
--- and only then let the placement finish.
---
--- ArenaDispatch is COUNTED, not performed: whether the hold is still on is
--- a question about call order, which is what this section measures, and
--- what the calls themselves do to a ped belongs to client/dispatch.lua and
--- its own spec.
--- @return table fixture
local function newClientFixture(mutate)
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 100,
        dead = false,
        groundReady = true,
        --- How many times the ped was wiped wholesale.
        wiped = 0,
        --- Every weapon removed one at a time, in order.
        takenBack = {},
        --- Every SetCurrentPedWeapon, in order. The first one on the way into
        --- an arena is what says whether the player walked in holding their
        --- own gun.
        selected = {},
        disabled = {},
        clock = 3600000,
        --- What GetPedSourceOfDeath answers. 900 keeps the ordinary
        --- slow-death path -- the watch loop, a frame or more after the
        --- death -- working exactly as it did; a test about the same-frame
        --- hook sets it to 0, which is what the engine really returns there.
        sourceOfDeath = 900,
        --- ped -> player index, and index -> server id, for tests that need
        --- two different killers to be distinguishable.
        playerIndexOf = {},
        serverIdOf = {},
        serverEvents = {},
        released = {},
        cleared = 0,
        given = {},
        -- Where the player has been put, in order. A placement that happens
        -- AFTER they have gone home is the defect the last test covers.
        placements = {},
        --- THE DICE, when a test needs to know where somebody landed.
        ---
        --- The spawn scatter draws two numbers per point -- an angle and a
        --- distance -- so a list here is read in pairs and cycles when it
        --- runs out. Left nil, the real math.random is used and the scatter
        --- is as random as it is on a server, which is what every test that
        --- is not ABOUT the scatter wants.
        randomDraws = nil,
        --- Every spawn-clearance probe fired, in order. An arena that builds
        --- its own floor must fire none at all.
        probes = {},
    }

    --- The scatter's own dice, replaced only when a test loaded some.
    local nextDraw = 0
    local function steeredRandom(lower, upper)
        local rolls = f.randomDraws
        -- ONLY THE ARGUMENT-LESS FORM is steered. math.random(a, b) is a
        -- different question -- pick an integer in a range -- and the code
        -- that asks it wants a real answer. One guard, not two: with `lower`
        -- nil a `upper` on its own is an error in math.random anyway, so a
        -- second branch for it could never be reached.
        if lower ~= nil then return math.random(lower, upper) end
        if type(rolls) ~= 'table' or #rolls == 0 then return math.random() end
        -- READ IN PAIRS, so a list with an odd number in it swaps the angle
        -- and the distance round on the second lap and every assertion about
        -- where somebody landed quietly changes meaning.
        assert(#rolls % 2 == 0, 'randomDraws is read in pairs -- an angle and a distance')
        nextDraw = nextDraw % #rolls + 1
        return rolls[nextDraw]
    end

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,

        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            f.serverEvents[#f.serverEvents + 1] = { name = name, payload = payload }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- No inventory resource: the client is the one handing out weapons,
        -- which is the arrangement where "was this player re-armed" is a
        -- question this file's own calls can answer.
        GetResourceState = function() return 'missing' end,

        joaat = function(name) return name end,

        -- `math` ITSELF, so the scatter's dice can be loaded. Everything
        -- else on the table is the real one: only the argument-less
        -- math.random() the scatter uses is steered, and only when a test
        -- has said what it should roll.
        math = setmetatable({ random = steeredRandom }, { __index = math }),

        PlayerPedId = function() return f.ped end,
        IsEntityDead = function() return f.dead end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,

        NetworkResurrectLocalPlayer = function()
            f.dead = false
            -- A resurrect can hand back a new ped and production says so in
            -- as many words, so a call left pointing at the old handle shows
            -- up here as one.
            f.ped = f.ped + 1
        end,

        FreezeEntityPosition = function() end,
        ClearPedBloodDamage = function() end,
        SetEntityCoordsNoOffset = function(_ped, x, y, z)
            f.placements[#f.placements + 1] = { x = x, y = y, z = z }
        end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return f.groundReady end,
        -- SETTABLE, like every other native here that a test needs to steer.
        -- Nil means "the ground is not known", which is the default and the
        -- case placeAt's fallback exists for.
        GetGroundZFor_3dCoord = function()
            if f.groundZ == nil then return false, nil end
            return true, f.groundZ
        end,
        -- THE SPAWN CLEARANCE PROBE. The handle carries the point it was
        -- asked about, so the result can answer per point -- which is the
        -- whole question: is THIS spot under a trailer.
        -- THE FLAGS ARE RECORDED TOO. This stub took only x1 and y1 and
        -- threw the rest away, so the value telling the engine WHAT to look
        -- for was the one argument no test could see -- and it shipped
        -- wrong: `1 + 2 + 8` is the map, vehicles and ragdolls, where the
        -- comment above the call claimed objects and disclaimed peds.
        StartExpensiveSynchronousShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2, flags)
            f.probes[#f.probes + 1] = {
                x = x1, y = y1, fromZ = z1, toZ = z2, flags = flags,
            }
            return { x = x1, y = y1 }
        end,
        GetShapeTestResult = function(handle)
            -- A HIT WHOSE COORDINATE IS NOT A COORDINATE. `f.shapeAnswer` is
            -- what a build whose native answers in a shape this code does
            -- not expect hands back -- a number, a boolean, a string. The
            -- read used to index it, which threw out of the whole entry.
            if f.shapeAnswer ~= nil then return 2, 1, f.shapeAnswer end

            local within = f.roofedWithin
            if within == nil or type(handle) ~= 'table' then
                return 2, 0, { x = 0.0, y = 0.0, z = 0.0 }
            end
            local dx = (handle.x or 0.0) - (f.roofedAtX or 0.0)
            local dy = (handle.y or 0.0) - (f.roofedAtY or 0.0)
            if math.sqrt(dx * dx + dy * dy) <= within then
                -- Hit, well above the ground: a roof.
                return 2, 1, { x = handle.x, y = handle.y, z = (f.groundZ or 0.0) + 10.0 }
            end
            return 2, 0, { x = 0.0, y = 0.0, z = 0.0 }
        end,
        -- Frozen, so placeAt's five-second bail-out never trips and
        -- `groundReady` stays the only thing that ends the wait.
        -- A REAL CLOCK the tests can move. Frozen at zero, every deadline
        -- this file's code takes -- the re-assert window below among them
        -- -- is permanently in the future, so a bounded loop and an
        -- unbounded one are indistinguishable.
        GetGameTimer = function() return f.clock end,

        GiveWeaponToPed = function(ped, weapon, ammo)
            f.given[#f.given + 1] = { ped = ped, weapon = weapon, ammo = ammo }
        end,
        SetPedAmmo = function() end,
        -- RECORDED, not swallowed. SetPedArmour is stubbed to an empty
        -- function in every other spec in this suite, so no test anywhere
        -- has ever asserted that a fighter is given the armour their
        -- loadout says -- on entry or on any life after it.
        SetPedArmour = function(_ped, value) f.armour = value end,
        SetEntityHealth = function(_ped, value) f.health = value end,
        -- RECORDED, because a stub that answers nothing cannot tell "the
        -- arena put this player's hands away on the way in" from "it did
        -- not", and that is a real question about what somebody walks into
        -- the arena holding.
        SetCurrentPedWeapon = function(_ped, hash) f.selected[#f.selected + 1] = hash end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        -- RECORDED, for the same reason SetPedArmour above is. These two are
        -- how the arena takes weapons back, and stubbed to nothing no test
        -- could tell a full wipe of the player's own guns from taking back
        -- only what the arena issued -- which is exactly the difference
        -- Config.Match.restoreLoadoutOnExit turns on.
        RemoveAllPedWeapons = function() f.wiped = (f.wiped or 0) + 1 end,
        RemoveWeaponFromPed = function(_ped, hash)
            f.takenBack[#f.takenBack + 1] = hash
        end,

        -- RECORDED WITH ITS CONTROL, because "the player cannot shoot
        -- while dead" is a claim about WHICH controls are refused and a
        -- stub that drops the number cannot check it.
        DisableControlAction = function(_group, control) f.disabled[control] = true end,
        DisablePlayerFiring = function(_player, on) f.firingBlocked = on end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        -- SETTABLE, AND 0 IS A REAL ANSWER.
        --
        -- This was hard-wired to 900, so the source of death was ALWAYS
        -- available -- and the one defect this native has is that it is NOT:
        -- the engine fills it in when the ped's death state is finalised,
        -- which is after CEventNetworkEntityDamage has been dispatched. A
        -- fixture that always answers hides the entire race, and hid it: a
        -- kill that landed in one shot named nobody, and every test here
        -- passed.
        GetPedSourceOfDeath = function() return f.sourceOfDeath or 0 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        -- Per ped, so a test can tell WHICH killer was named rather than only
        -- that one was.
        NetworkGetPlayerIndexFromPed = function(ped)
            return (f.playerIndexOf or {})[ped] or 5
        end,
        GetPlayerServerId = function(index)
            return (f.serverIdOf or {})[index] or 7
        end,

        -- The team outline. Recorded rather than ignored: an outline that is
        -- put on and never taken off outlives the match that drew it, and
        -- these are what a spec would assert that against.
        PlayerId = function() return 0 end,
        DoesEntityExist = function() return true end,
        -- One ped per server id, distinct, so a test can tell WHICH players
        -- were outlined rather than only how many calls were made.
        GetPlayerFromServerId = function(serverId) return serverId end,
        NetworkIsPlayerActive = function() return true end,

        -- The map blips, which the same loop draws. Stubbed rather than
        -- asserted here: this block is about the OUTLINE, and a loop that
        -- errors on a blip native never reaches the outline at all.
        AddBlipForEntity = function(ped) return 5000 + (ped or 0) end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        EndTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        SetBlipDisplay = function() end,
        DoesBlipExist = function() return true end,
        RemoveBlip = function() end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        -- The engine's own side, told so friendly fire can be refused
        -- before any damage exists. Recorded rather than ignored: leaving it
        -- set is what would follow a player out of the arena.
        SetPlayerTeam = function(_player, team) f.team = team end,
        -- READ BACK, rather than answering -1 for ever. The sandbox's default
        -- says "no team" whatever has been written, and the per-frame hold
        -- compares what it wrote against what the engine reports -- so
        -- against a stub that never agrees with SetPlayerTeam, "the arena put
        -- its team back" and "the arena never noticed" look identical.
        GetPlayerTeam = function() return f.team or -1 end,
        NetworkSetFriendlyFireOption = function(on) f.friendlyFire = on end,
        SetCanAttackFriendly = function() end,
        SetEntityDrawOutline = function(ped, on)
            f.outlines = f.outlines or {}
            f.outlines[#f.outlines + 1] = { ped = ped, on = on == true }
        end,
        SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function(r, g, b)
            f.outlineColor = { r = r, g = g, b = b }
        end,

        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,

        -- Recorded, not swallowed: the frozen start countdown is drawn
        -- from client/match.lua through this call, and a stub that dropped
        -- it would let the clock disappear again without a test noticing.
        ArenaUI = {
            UpdateHud = function() end,
            Countdown = function(seconds, label)
                f.countdowns = f.countdowns or {}
                f.countdowns[#f.countdowns + 1] = { seconds = seconds, label = label }
            end,
        },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() f.cleared = f.cleared + 1 return true end,
            ReleaseDeadState = function(ped)
                f.released[#f.released + 1] = { ped = ped }
            end,
        },
    })

    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../client/match.lua', env)

    -- Exposed so a spec can compare against the SAME Arena the client is
    -- running, rather than a second copy of the config that could drift.
    f.env = env
    f.step = runner.step

    function f.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('client/match.lua registered no handler for ' .. name) end
        handler(...)
    end

    --- Fires a handler the way FiveM does -- inside a coroutine -- so the
    --- yield in placeAt parks it instead of erroring out.
    function f.fireThreaded(name, ...)
        local args = table.pack(...)
        runner.CreateThread(function() f.fire(name, table.unpack(args, 1, args.n)) end)
    end

    --- Into the arena, through the countdown, and one death down: the exact
    --- state the server sends a respawn to.
    function f.toFirstDeath()
        f.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
            scatterRadius = 0.0,
            freezeSeconds = 0,
            loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
        })
        f.fire('crimson_arena:client:matchLive')

        f.dead = true
        f.step()
    end

    --- Forgets the controls refused so far, so a test can ask what a
    --- SINGLE frame did rather than what every frame since load did.
    function f.forgetControls()
        f.disabled = {}
        f.firingBlocked = nil
    end

    --- The message the server sends back. Threaded, because it yields.
    function f.respawn()
        f.fireThreaded('crimson_arena:client:respawn', {
            spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
            loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
        })
    end

    --- The events of ONE kind, which is what every assertion below actually
    --- means. Counting the whole list couples a test about death reporting
    --- to every other message the client will ever send -- and a diagnostic
    --- line added years later then fails a test about corpses, which says
    --- nothing true about corpses.
    --- @param name string
    --- @return table[]
    function f.eventsNamed(name)
        local out = {}
        for _, event in ipairs(f.serverEvents) do
            if event.name == name then out[#out + 1] = event end
        end
        return out
    end

    return f
end

t.test('the first death is reported and held, so the respawn tests below start where they claim to', function()
    local f = newClientFixture()
    f.toFirstDeath()

    local reports = f.eventsNamed('crimson_arena:server:reportDeath')
    t.equals(#reports, 1, 'the death nobody reported cannot be the one a respawn answers')
    t.equals(f.cleared, 1, 'the body was left lying there instead of going into the hold')
    t.equals(#f.released, 0, 'nothing has released the hold yet -- the respawn has not been sent')
end)

t.test('a kill landed while the respawn is still streaming the ground in is still reported', function()
    -- THE DEFECT: the handler used to release the hold FIRST -- mortal,
    -- visible, collidable -- then call placeAt, which yields for as long as
    -- the ground takes to arrive, and only reset `deathReported` after that.
    -- For the whole of that wait the player stood in a live round killable
    -- with the death watch switched off. A kill there was reported to
    -- nobody, so the server never scored it and never sent a respawn; and it
    -- was cleared for nobody, so it left a real corpse for the operator's
    -- medical script to find and page an ambulance to -- into a routing
    -- bucket no ambulance can reach.
    local f = newClientFixture()
    f.toFirstDeath()

    f.groundReady = false
    f.respawn()
    f.step()

    t.equals(#f.eventsNamed('crimson_arena:server:reportDeath'), 1,
        'the respawn re-reported the death it was sent to answer -- the watch was re-armed over a body')

    -- Shot where they stand, mid-placement.
    f.dead = true
    f.step()

    t.equals(#f.eventsNamed('crimson_arena:server:reportDeath'), 2,
        'a kill during the respawn placement was reported to nobody -- the server never scored it')
    t.equals(f.cleared, 2,
        'and it was never cleared, so the corpse is still there for the medical script to find')
end)

t.test('the respawn does not hand the ped back to the world until it has been placed', function()
    -- The other half of the same contract, and the reason the re-arm alone
    -- is not the whole fix: a ped released before placeAt is a ped that is
    -- killable for the length of the wait. Left inside ClearDeadState's hold
    -- across the yield instead, it cannot be shot at all -- and the release,
    -- which is also what unfreezes it (client/dispatch.lua), is the single
    -- instant it becomes a target again.
    local f = newClientFixture()
    f.toFirstDeath()

    f.groundReady = false
    f.respawn()
    f.step()

    t.equals(#f.released, 0,
        'the hold was dropped before the player had been placed, leaving them killable mid-teleport')

    f.groundReady = true
    f.step()

    t.equals(#f.released, 1, 'the placement finished and the player was never let out of the hold')
    t.equals(f.released[1].ped, f.ped, 'the release went to a handle the resurrect had already replaced')
end)

t.test('a respawned fighter has their loadout re-applied, once the round still wants them', function()
    -- Measured on the vitals rather than the weapons: ox_inventory owns the
    -- weapons and this side does not touch them, so applying the loadout is
    -- visible here as the plate and the health going back to full.
    local f = newClientFixture()
    f.toFirstDeath()
    f.armour = 0
    f.health = 5

    f.respawn()
    f.step()

    t.equals(f.armour, 100, 'the respawned player came back with no plate')
    t.equals(f.health, 200, 'the respawned player came back hurt')
    t.equals(#f.released, 1, 'a respawn with the ground already streamed in still releases exactly once')
end)

t.test('the next death after a respawn is reported too -- the watch stays armed', function()
    -- The re-arm moved, so this is the thing that must not have moved with
    -- it: one respawn, then the next kill counts.
    local f = newClientFixture()
    f.toFirstDeath()

    f.respawn()
    f.step()

    f.dead = true
    f.step()

    t.equals(#f.eventsNamed('crimson_arena:server:reportDeath'), 2, 'the fighter the server put back in the round could never die again')
end)

t.test('being ELIMINATED releases nothing -- the hold is what keeps them safe', function()
    -- THE OTHER HALF OF THE ELIMINATION REVIVE, and the half that actually
    -- enforces it. The server asks a medical script to revive an eliminated
    -- player so they come off its casualty list, and nothing about that may
    -- free them: spectate re-hides and re-freezes the parked body but never
    -- restores invincibility, so a released player is MORTAL in a live
    -- round, and with spectate off they stand back up armed in one.
    --
    -- This used to be asserted server-side, as a `keepHold` argument passed
    -- to ArenaDispatch.Revive -- which that function never read. The flag is
    -- gone; the guarantee lives here, where releasing is a thing that can
    -- actually happen.
    local f = newClientFixture()
    f.toFirstDeath()
    local releasedByDeath = #f.released

    f.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = false })
    f.step()

    t.equals(#f.released, releasedByDeath,
        'elimination let the player out of the hold -- they are mortal, or standing up, in a live round')
end)

t.test('a round that ends mid-placement still lets the player out of the hold', function()
    -- The token guard below the placement returns without arming anybody,
    -- and it must not return without releasing either: leaveArena has
    -- already spent its one release by then, and placeAt has re-frozen the
    -- ped since. Anything that bails out ahead of the release leaves the
    -- player FROZEN -- and only frozen. Not invisible and not in the lobby:
    -- leaveArena made them visible and mortal on its way past, and it sent
    -- them home. Frozen on its own is enough to strand somebody, which is
    -- the whole point; the earlier wording here overstated it and an
    -- adversarial check caught that before it could mislead anybody.
    local f = newClientFixture()
    f.toFirstDeath()

    f.groundReady = false
    f.respawn()
    f.step()

    f.armour = 0
    local releasedByExit = #f.released
    f.fire('crimson_arena:client:exitArena', {})
    t.equals(#f.released, releasedByExit + 1, 'leaveArena did not release the hold on the way home')

    f.groundReady = true
    f.step()

    t.equals(#f.released, releasedByExit + 2,
        'the parked respawn re-froze the ped on its way out and left nothing to unfreeze it')
    t.equals(f.armour, 0, 'a player already home had the arena loadout applied to them anyway')
end)

t.test('DEFECT: with the restore switched off, the exit does not wipe the player\'s own guns', function()
    -- Config.Match.restoreLoadoutOnExit says, in config's own words, "give
    -- players back the weapons and armour they walked in with". Off, the
    -- restore deliberately gave nothing back -- and the exit still wiped the
    -- ped wholesale. The player walked out having lost every weapon they
    -- arrived with, which is not what "do not give them back" means, and
    -- nobody asks for a match that confiscates their guns.
    --
    -- ox_inventory owns the weapons and re-equips the ped from the inventory
    -- afterwards, which is what makes the wipe survivable at all -- but only
    -- for what the player still owns an item for. A wipe with no restore
    -- behind it is still the arena reaching for their kit.
    local f = newClientFixture(function(config)
        config.Match.restoreLoadoutOnExit = false
    end)
    f.toFirstDeath()

    -- Counted from HERE. Entry wipes the ped too, before issuing the arena
    -- kit, and that one is not what this is about.
    local wipedOnEntry = f.wiped

    f.fire('crimson_arena:client:exitArena', {})

    t.equals(f.wiped, wipedOnEntry,
        ('the exit wiped the ped %d time(s) with nothing going to be restored')
            :format(f.wiped - wipedOnEntry))
end)

t.test('and with it on, the wipe happens and everything comes back', function()
    -- The other direction, so the fix above is not "never wipe". The full
    -- wipe is what stops a weapon picked up INSIDE the arena leaving with
    -- somebody, and it is safe precisely because the restore follows it.
    local f = newClientFixture()
    t.isTrue(f.env.Config.Match.restoreLoadoutOnExit == true,
        'the shipped default changed, so this test is describing the wrong thing')

    f.toFirstDeath()
    local wipedOnEntry = f.wiped
    f.fire('crimson_arena:client:exitArena', {})

    t.isTrue(f.wiped > wipedOnEntry,
        'the exit left whatever the player picked up in the arena on them')
end)

t.test('and does not teleport a player who has gone home back to the arena', function()
    -- FOUND BY AN ADVERSARIAL CHECK ON THE FIX ABOVE, not by the fix itself.
    -- placeAt waits up to five seconds for the world to stream in, and a
    -- round can end inside that wait: the player is sent home, given their
    -- own gear back, and put in the lobby -- and then the parked placement
    -- wakes up and puts them back at the arena spawn. Nothing downstream
    -- undid it, because the exit had already run by then.
    --
    -- The release count says nothing about this, which is exactly why it
    -- stayed invisible. What is asserted is the teleport.
    local f = newClientFixture()
    f.toFirstDeath()

    f.groundReady = false
    f.respawn()
    f.step()

    f.fire('crimson_arena:client:exitArena', {})
    local afterExit = #f.placements

    f.groundReady = true
    f.step()

    t.equals(#f.placements, afterExit,
        'the parked placement fired after the player had already left, dragging them back into the arena')
end)
-- ======================================================================
-- THE TEAM OUTLINE, and the one thing it must never do
--
-- A coloured edge round a teammate draws THROUGH geometry. That is the
-- whole point of it for finding a friend behind a wall, and exactly the
-- problem with it for finding a target behind one -- an outline on an enemy
-- is a wallhack with a colour scheme.
--
-- The teammates-only rule is therefore the security property here, not a
-- preference, and it was not covered: outlining everybody passed the whole
-- suite.
-- ======================================================================

--- Drives the client into a live TEAM match with a roster of one teammate
--- and one enemy, then runs the loop that draws outlines.
--- @return table f
local function outlinedTeamMatch()
    local f = newClientFixture()

    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'tdm',
        teamKey = 'crimson',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
    f.fire('crimson_arena:client:matchLive')

    -- The roster the loop reads comes off the HUD push, which is where the
    -- server really puts it.
    f.fire('crimson_arena:client:matchHud', {
        scoreboard = {
            { id = 11, name = 'Teammate', team = 'crimson', alive = true },
            { id = 22, name = 'Enemy', team = 'ash', alive = true },
        },
    })

    f.step()
    return f
end

t.test('a teammate is outlined', function()
    local f = outlinedTeamMatch()

    local on = {}
    for _, call in ipairs(f.outlines or {}) do
        if call.on then on[#on + 1] = call.ped end
    end

    t.isTrue(#on > 0, 'nobody was outlined at all, so this test proves nothing about who')
end)

t.test('and an ENEMY is never outlined, whatever else is on', function()
    -- pedForServerId is stubbed to answer for any id in this fixture, so an
    -- outline aimed at the enemy would show up here. If the filter is
    -- dropped, both peds are outlined and this fails.
    local f = outlinedTeamMatch()

    local peds = {}
    for _, call in ipairs(f.outlines or {}) do
        if call.on then peds[call.ped] = true end
    end

    local count = 0
    for _ in pairs(peds) do count = count + 1 end

    t.equals(count, 1,
        'more than one ped was outlined in a two-player roster with one teammate -- the enemy is being drawn through walls')
end)

t.test('the outline colour is the team own colour, not a guess', function()
    local f = outlinedTeamMatch()
    local team = f.env.Arena.GetTeamByKey('crimson')
    local r, g, b = f.env.Arena.HexToRgb(team.color)

    t.isNotNil(f.outlineColor, 'no outline colour was ever set')
    t.equals(f.outlineColor.r, r, 'the outline is not the team colour')
    t.equals(f.outlineColor.g, g)
    t.equals(f.outlineColor.b, b)
end)

-- ======================================================================
-- THE SPAWN IS NOT NUDGED OFF THE POINT THAT WAS CHOSEN FOR IT
--
-- Two different spawn mechanisms, and only one of them wants scattering.
--
-- The `spawns` LIST is round-robin: twenty players can share four points, so
-- without a scatter they land inside each other. The spawn PLAN is not --
-- Arena.PlanSpawns spread this roster across the area itself, kept them
-- minSeparation apart, and placed them clear of the arena's own cover.
-- Scattering that result undoes all three, and on an arena with barriers it
-- can put somebody inside one.
-- ======================================================================

t.test('a planned spawn is sent with no extra scatter', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 3)
    goLive(f, match)

    for src = 1, 3 do
        local entry = f.lastPayload('crimson_arena:client:enterArena', src)
        t.isNotNil(entry, ('fighter %d was never placed'):format(src))
        t.equals(entry.scatterRadius, 0.0,
            'a planned spawn was sent a scatter radius, which undoes the separation it was planned for')
    end
end)

t.test('and a round-robin spawn still gets the scatter it needs', function()
    -- The other half, and the reason this is a condition rather than a
    -- deletion: four points and twenty players without a scatter is twenty
    -- players in four piles.
    local f = newFixture(function(config)
        instantRound(config)
        config.Arenas.trailerpark.spawnArea.enabled = false
    end)
    local match = newMatch(f, 3)
    goLive(f, match)

    local entry = f.lastPayload('crimson_arena:client:enterArena', 1)
    t.isNotNil(entry)
    t.equals(entry.scatterRadius, f.Config.Match.spawnScatterRadius,
        'an arena using its point list was sent no scatter, so its players land in a pile')
end)

-- ======================================================================
-- THE ARENA GROWS WITH THE ROSTER, AND EVERY CLIENT IS TOLD THE SAME NUMBER
-- ======================================================================

--- An arena that grows, so a roster can be measured against it.
local function growing(config)
    instantRound(config)
    config.Arenas.trailerpark.scale = {
        enabled = true, baseline = 2, perPlayer = 4.0, maxGrowth = 3.0,
    }
end

t.test('the size factor is sent to every client, and it is the same one', function()
    -- The client builds the floor. If it works the growth out for itself it
    -- has to see the roster, which it cannot -- and two ends deriving the
    -- same number separately is how they come to disagree about where the
    -- floor ends.
    local f = newFixture(growing)
    local match = newMatch(f, 3)
    goLive(f, match)

    local first = f.lastPayload('crimson_arena:client:enterArena', 1)
    t.isNotNil(first)
    t.isTrue((first.sizeFactor or 0) > 1.0,
        ('three fighters over a baseline of two produced a factor of %s')
            :format(tostring(first.sizeFactor)))

    for src = 2, 3 do
        t.equals(f.lastPayload('crimson_arena:client:enterArena', src).sizeFactor,
            first.sizeFactor, ('fighter %d was told a different arena size'):format(src))
    end
end)

t.test('DEFECT: and the boundary grows with it, so the floor is never outside the sphere', function()
    -- The boundary is the only one of the three radii the client does not
    -- work out for itself -- it arrives on this payload. A boundary that
    -- stayed at its configured size while the floor and the spawn ring grew
    -- would leave solid ground, and spawns, outside the sphere that bleeds
    -- you for leaving it.
    local f = newFixture(growing)
    local match = newMatch(f, 3)
    goLive(f, match)

    local configured = f.Config.Arenas.trailerpark.boundary.radius
    local entry = f.lastPayload('crimson_arena:client:enterArena', 1)

    t.isNotNil(entry.boundary, 'the arena sent no boundary at all')
    t.isTrue(math.abs(entry.boundary.radius - configured * entry.sizeFactor) < 0.001,
        ('the boundary came through at %0.1f -- configured %0.1f, arena grown by %0.2f')
            :format(entry.boundary.radius, configured, entry.sizeFactor))
end)

t.test('and an arena that does not scale is sent exactly what config says', function()
    local f = newFixture(instantRound)
    local match = newMatch(f, 3)
    goLive(f, match)

    local entry = f.lastPayload('crimson_arena:client:enterArena', 1)
    t.equals(entry.sizeFactor, 1.0)
    t.equals(entry.boundary.radius, f.Config.Arenas.trailerpark.boundary.radius)
end)


-- ========================================================================
-- NO SHOOTING FROM BEYOND THE GRAVE
--
-- THE REPORTED SYMPTOM: "a split second after dying, when you have lives
-- still, you can shoot for a split second."
--
-- ClearDeadState makes the dead player invincible, invisible, frozen and
-- collisionless, and its own comment says that is there to stop "a player
-- who could shoot during that gap". NOT ONE OF THOSE FOUR NATIVES STOPS A
-- TRIGGER BEING PULLED. A frozen ped aims and fires exactly as well as a
-- standing one and the rounds are real -- so the code documented a
-- guarantee it did not implement, and the window between dying and being
-- put back was a window to kill somebody in.
-- ========================================================================

t.test('a player who has just died cannot fire', function()
    local f = newClientFixture()
    f.toFirstDeath()

    f.forgetControls()
    f.step()

    t.equals(f.firingBlocked, true, 'a dead player can still pull the trigger')
    t.isTrue(f.disabled[24], 'attack was left enabled on a dead player')
    t.isTrue(f.disabled[257], 'the alternate attack control was left enabled on a dead player')
    t.isTrue(f.disabled[263], 'melee was left enabled on a dead player')
end)

t.test('THE FROZEN COUNTDOWN IS NOT A FREE-FIRE PERIOD', function()
    -- REPORTED BY PLAYING IT. Everyone is teleported in, ARMED, and frozen
    -- for Config.Match.startCountdownSeconds. Freezing a ped stops it
    -- walking, not shooting -- the note above this block in client/match.lua
    -- has said so about the DEAD hold since it was written -- so the
    -- countdown was five seconds in which you could empty a magazine into
    -- somebody who could not move.
    --
    -- And it did not even score: handleDeath's `not matchLive` branch
    -- re-heals, re-armours and re-freezes the victim with nothing said to
    -- either player. So the visible result was people dying and popping back
    -- before the round began, which reads as the arena being broken -- and
    -- whoever pre-aimed had rounds in the air the instant weapons went live.
    local f = newClientFixture()
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 5,
        loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
    })
    -- Deliberately NOT sending matchLive: this is the window between being
    -- placed and the round starting.

    f.forgetControls()
    f.step()

    t.equals(f.firingBlocked, true, 'a frozen fighter could shoot during the countdown')
    t.isTrue(f.disabled[24], 'attack was left enabled during the countdown')
    t.isTrue(f.disabled[257], 'the alternate attack control was left enabled during the countdown')
    t.isTrue(f.disabled[263], 'melee was left enabled during the countdown')
end)

t.test('and the frozen countdown puts a CLOCK on screen while it holds them', function()
    -- The other half of the same five seconds. A player teleported into an
    -- arena, frozen where they land and unable to shoot was given nothing
    -- saying why or for how long: the LOBBY countdown has had a clock since
    -- it was written, and this one -- the one you spend standing in the
    -- open looking at the people about to shoot you -- had none. It reads
    -- as the game having locked up.
    --
    -- Drawn from the client, off the number `enterArena` already carries,
    -- rather than pushed per second per fighter from the server.
    local f = newClientFixture()
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 3,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })

    -- One pass to start the freeze thread and draw its first second.
    f.step()

    local drawn = f.countdowns or {}
    t.isTrue(#drawn > 0, 'the frozen countdown put nothing on screen at all')
    t.equals(drawn[1].seconds, 3, 'the clock did not open on the length of the freeze')
    t.isTrue(type(drawn[1].label) == 'string' and #drawn[1].label > 0,
        'the clock was drawn with no label to say what it is counting to')

    -- And it counts DOWN rather than repeating the same number.
    for _ = 1, 3 do f.step() end
    drawn = f.countdowns or {}
    t.isTrue(#drawn >= 2, 'the clock was drawn once and never ticked')
    t.isTrue(drawn[2].seconds < drawn[1].seconds,
        ('the clock went %d -> %d'):format(drawn[1].seconds, drawn[2].seconds))
end)

t.test('and a round with no freeze at all draws no clock', function()
    -- startCountdownSeconds = 0 is a legal setting: straight into the
    -- fight. A countdown overlay flashed up over a round that has already
    -- started is worse than none.
    --
    -- GUARDED TWICE, so no single mutation breaks this: the freeze branch
    -- is not entered at all at zero, and the loop inside it would not draw
    -- a zero second even if it were. Break both -- `if false` on the branch
    -- and `>= 0` on the loop -- and this fails with one countdown drawn.
    local f = newClientFixture()
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
    for _ = 1, 3 do f.step() end

    t.equals(#(f.countdowns or {}), 0,
        'a round with no frozen countdown still drew one')
end)

t.test('and a LIVING player in the same round can', function()
    -- The control, and it is the whole point: this must be a hold on the
    -- dead, not a match that nobody can shoot in.
    local f = newClientFixture()
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
    })
    f.fire('crimson_arena:client:matchLive')

    f.forgetControls()
    f.step()

    t.isTrue(f.firingBlocked ~= true, 'a living fighter was stopped from shooting')
    t.isTrue(f.disabled[24] ~= true, 'attack was refused to a living fighter')
end)

t.test('and the block lifts once they are put back', function()
    -- It is keyed on the same flag the respawn clears, so the instant the
    -- player is handed back to the round they can fight in it.
    local f = newClientFixture()
    f.toFirstDeath()
    f.respawn()
    -- The respawn yields on the ground streaming in; run it out before
    -- asking what a frame after it looks like.
    for _ = 1, 6 do f.step() end

    f.forgetControls()
    f.step()

    t.isTrue(f.firingBlocked ~= true, 'a respawned fighter was left unable to shoot')
    t.isTrue(f.disabled[24] ~= true, 'attack was still refused after the respawn')
end)


-- ========================================================================
-- FULL HEALTH AND FULL ARMOUR, ON EVERY LIFE
--
-- README and the PR both promise "every match starts at full health and
-- full armour". NO SPEC IN THIS SUITE HAS EVER CHECKED IT: SetPedArmour is
-- stubbed to an empty function in every fixture that has one, so a fighter
-- being armoured has never been asserted on entry, and a fighter being
-- RE-armoured has never been asserted at all.
--
-- The entry and respawn payloads both carry the numbers -- verified against
-- the real server/lobby.lua and server/match.lua -- so these ask the other
-- half of the question: does the client apply what it is sent, every time?
-- ========================================================================

--- Enters a match carrying `armor` points of armour.
local function enterWithArmour(f, armour)
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = {
            weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } },
            health = 200,
            armor = armour,
        },
    })
    f.fire('crimson_arena:client:matchLive')
end

t.test('entering the arena gives the fighter the armour their loadout says', function()
    local f = newClientFixture()

    enterWithArmour(f, 100)

    t.equals(f.armour, 100, 'the fighter walked into the arena with no armour')
    t.equals(f.health, 200, 'the fighter walked in on less than full health')
end)

t.test('AND A LOADOUT THAT SAYS NONE STILL STARTS THEM ON A FULL PLATE', function()
    -- THE CONTROL, INVERTED, because the rule it is controlling for changed.
    -- It used to prove that armour came from the loadout rather than being
    -- hard-coded on the client; a server shipping zero got zero. Both realms
    -- now read one rule -- Arena.StartingVitals -- and what the client
    -- applies is a FLOOR, so a payload carrying nothing, or a stale one
    -- built before the rule existed, still opens the round on a full plate
    -- instead of on whatever happened to be in the table.
    local f = newClientFixture()

    enterWithArmour(f, 0)

    t.equals(f.armour, 100, 'a loadout asking for no armour was honoured')
end)

t.test('AND THE MEDICAL HANDOFF DOES NOT TAKE THE PLATE STRAIGHT BACK OFF', function()
    -- THE HOLE THE REVIVE REMOVAL OPENED, and it lands on exactly the
    -- promise this section is about.
    --
    -- Two seconds after a respawn the server asks the medical script to
    -- revive this player. A medical revive does not only clear a death
    -- record -- it sets health, and most of them set ARMOUR TO ZERO doing
    -- it. So the arena hands a fighter a full plate for their next life and
    -- then, by its own handoff, has it taken off them again, on every
    -- respawn of every round.
    --
    -- The client insists on the arena's numbers for a moment afterwards.
    -- That used to ride on the arena's own revive event; that event went
    -- with the self-made revive, and the signal went with it, so it is its
    -- own event now.
    local f = newClientFixture()
    enterWithArmour(f, 100)

    f.dead = true
    f.step()
    f.fireThreaded('crimson_arena:client:respawn', {
        spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
        loadout = {
            weapons = {},
            health = 200,
            armor = 100,
        },
    })
    for _ = 1, 6 do f.step() end
    t.equals(f.armour, 100, 'the respawn did not apply the plate at all')

    -- The medical script, doing what medical scripts do.
    f.armour = 0
    f.health = 150

    -- The server tells the client it has just asked another script to touch
    -- this body.
    f.fire('crimson_arena:client:holdVitals')
    for _ = 1, 4 do f.step() end

    t.equals(f.armour, 100, 'the medical handoff took the plate off and nothing put it back')
    t.equals(f.health, 200, 'the medical handoff left the fighter on less than full health')
end)

t.test('EVERY LIFE, not just the first -- a respawn re-armours too', function()
    -- The reported symptom is about the lives AFTER the first. The
    -- respawn payload carries the same numbers the entry did, and this is
    -- the assertion that they are put back on the ped.
    local f = newClientFixture()
    enterWithArmour(f, 100)

    -- Spend it, the way being shot does.
    f.armour = 0
    f.health = 5

    f.dead = true
    f.step()
    f.fireThreaded('crimson_arena:client:respawn', {
        spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
        loadout = {
            weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } },
            health = 200,
            armor = 100,
        },
    })
    for _ = 1, 6 do f.step() end

    t.equals(f.armour, 100, 'a fighter came back from a life with no armour')
    t.equals(f.health, 200, 'a fighter came back from a life on less than full health')
end)

t.test('and again on the life after that', function()
    -- Twice, because a first respawn that works and a second that does not
    -- is a different defect from neither working, and the report says
    -- "after each life".
    local f = newClientFixture()
    enterWithArmour(f, 100)

    for _ = 1, 2 do
        f.armour = 0
        f.health = 5
        f.dead = true
        f.step()
        f.fireThreaded('crimson_arena:client:respawn', {
            spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
            loadout = {
                weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } },
                health = 200,
                armor = 100,
            },
        })
        for _ = 1, 6 do f.step() end
        f.dead = false
    end

    t.equals(f.armour, 100, 'the second respawn left the fighter with no armour')
    t.equals(f.health, 200, 'the second respawn left the fighter hurt')
end)

t.test('a respawn payload carrying NO loadout still starts the life full', function()
    -- AN OLDER SERVER, OR A PAYLOAD THAT LOST ITS LOADOUT ON THE WAY -- and
    -- the answer changed when the vitals did.
    --
    -- This used to assert that the client left the ped alone, because armour
    -- was a loadout FIELD and "no instruction" is not the same as "no
    -- armour". It is not a field any more: full health and a full plate on
    -- every life is a rule of the arena, so a payload that says nothing
    -- about them says nothing that could stop it. A fighter who comes back
    -- on 55 armour because a message was malformed is exactly the outcome
    -- the rule exists to remove.
    local f = newClientFixture()
    enterWithArmour(f, 100)
    f.armour = 55
    f.health = 90

    f.dead = true
    f.step()
    f.fireThreaded('crimson_arena:client:respawn', {
        spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
    })
    for _ = 1, 6 do f.step() end

    t.equals(f.armour, 100, 'a respawn with no loadout left the fighter on partial armour')
    t.equals(f.health, 200, 'a respawn with no loadout left the fighter on partial health')
end)


-- ========================================================================
-- AND THE ARENA GETS THE LAST WORD OVER THE MEDICAL SCRIPT
--
-- THE REPORTED SYMPTOM: health and armour are not restored "all the way"
-- after each life.
--
-- The client applies the loadout correctly -- the tests above prove that.
-- What happens next is the revive handoff: the arena asks the operator's
-- medical script to take this player off its casualty list, and standing
-- somebody up is exactly when such a script writes its OWN health and
-- clears armour. It lands AFTER the loadout, so the fighter comes back on
-- that script's numbers rather than the arena's.
--
-- The arena cannot see inside that script and will not guess at it, so it
-- insists on its own numbers for a moment afterwards instead.
-- ========================================================================

t.test('a medical script that clears armour on revive does not get the last word', function()
    local f = newClientFixture()
    enterWithArmour(f, 100)

    f.armour = 0
    f.health = 5
    f.dead = true
    f.step()
    f.fireThreaded('crimson_arena:client:respawn', {
        spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
        loadout = { weapons = {}, health = 200, armor = 100 },
    })
    for _ = 1, 6 do f.step() end
    f.dead = false
    t.equals(f.armour, 100, 'the respawn itself failed, so this test is about the wrong thing')

    -- The handoff, and the medical script behind it doing what medical
    -- scripts do.
    f.fire('crimson_arena:client:holdVitals')
    f.armour = 0
    f.health = 150

    f.step()

    t.equals(f.armour, 100, 'a medical script stripped the fighter\'s armour and kept it')
    t.equals(f.health, 200, 'a medical script left the fighter on less than the arena\'s health')
end)

t.test('but armour lost to being SHOT is not handed back', function()
    -- The re-assert is bounded for this. A loop that restored armour for
    -- the whole round would make every fighter bulletproof, which is a
    -- worse bug than the one it fixes.
    local f = newClientFixture()
    enterWithArmour(f, 100)

    f.fire('crimson_arena:client:holdVitals')
    for _ = 1, 3 do f.step() end
    f.clock = f.clock + 30000            -- well past the re-assert window

    f.armour = 20                        -- shot, mid-round
    f.step()

    t.equals(f.armour, 20, 'armour lost in a firefight was handed straight back')
end)

t.test('and a revive OUTSIDE a match re-asserts nothing', function()
    -- The post-match sweep revives everybody five seconds after the round,
    -- by which point they are home. Re-arming their arena armour there
    -- would hand a player a hundred points of it in the middle of town.
    local f = newClientFixture()

    f.fire('crimson_arena:client:holdVitals')
    f.armour = 0
    f.step()

    t.equals(f.armour, 0, 'a revive outside the arena handed out arena armour')
end)

-- ======================================================================
-- WHAT "NOT WATCHING" ACTUALLY DOES TO AN ELIMINATED FIGHTER
--
-- config.lua describes Config.Match.spectateOnElimination as "Eliminated
-- players watch the rest of the match instead of being sent straight back to
-- the lobby". Switching it off sent nobody anywhere. It withheld the camera
-- and left the fighter inside ClearDeadState's hold -- invisible, frozen,
-- collisionless, no panel, no camera, no way out -- until the round happened
-- to end on its own.
--
-- Going home is what the setting says, and it is also the only safe release:
-- the hold is deliberately kept while a player is WATCHING, because standing
-- them up in a live arena makes them visible and mortal in a round they are
-- out of.
-- ======================================================================

--- Three fighters, so an elimination leaves a round still being fought.
local function threeUp(mutate)
    local f = newFixture(function(config)
        instantRound(config)
        if mutate then mutate(config) end
    end)
    return f, newMatch(f, 3)
end

t.test('THE DEFECT: with spectating off, an eliminated fighter is sent home', function()
    local f, match = threeUp(function(config) config.Match.spectateOnElimination = false end)
    goLive(f, match)

    t.isTrue(f.M.OnDeath(3, 1), 'the death was not accepted')
    t.equals(match.state, 'live', 'the round ended, so nobody was left held anywhere')

    t.equals(f.count('crimson_arena:client:exitArena', 3), 1,
        'the eliminated fighter was left in the dead-state hold for the rest of the round')

    local told = f.lastPayload('crimson_arena:client:eliminated', 3)
    t.isNotNil(told, 'they were never told they were out')
    t.isFalse(told.spectate, 'a camera was opened with spectating switched off')
end)

t.test('and they are still a contestant while they wait', function()
    -- An exit from the ARENA, not from the match. ArenaLobby.Leave is what
    -- takes somebody off the roster, and this path deliberately does not
    -- call it: the results board ranks off this row and the payout reads it.
    local f, match = threeUp(function(config) config.Match.spectateOnElimination = false end)
    goLive(f, match)
    f.M.OnDeath(3, 1)

    t.isNotNil(match.players[3], 'going home took them off the roster')
    t.isTrue(match.players[3].placement ~= nil, 'they left without a placement to be ranked by')
end)

t.test('and the round end does not teleport them a second time', function()
    -- The only symptom of a double exit, and the one that would have read as
    -- a stray teleport: minutes after walking away from the lobby they would
    -- be pulled back to the arena return point.
    local f, match = threeUp(function(config) config.Match.spectateOnElimination = false end)
    f.money.pot = 3000
    f.money.payouts = { { id = 1, amount = 2700, reason = 'winner' } }
    goLive(f, match)

    f.M.OnDeath(3, 1)
    t.equals(f.count('crimson_arena:client:exitArena', 3), 1, 'the early exit did not happen')

    f.M.OnDeath(2, 1)       -- one left standing: the round ends
    f.step()

    t.equals(f.count('crimson_arena:client:exitArena', 3), 1,
        'the fighter who had already gone home was sent home again at the end of the round')

    -- And they still get the board, which is the reason the row was kept.
    t.isNotNil(f.lastPayload('crimson_arena:client:results', 3),
        'the fighter who left early was never shown how the round finished')

    -- The other two are unaffected: they leave at the end, once each.
    t.equals(f.count('crimson_arena:client:exitArena', 1), 1, 'the winner did not go home')
    t.equals(f.count('crimson_arena:client:exitArena', 2), 1, 'the runner-up did not go home')
end)

t.test('and with spectating ON they stay, and go home with everybody else', function()
    -- The other direction. A fix that sent every eliminated fighter home
    -- would delete the spectator feature and pass the tests above.
    local f, match = threeUp()
    t.isTrue(f.Config.Match.spectateOnElimination,
        'spectating no longer ships on -- this test is aimed at the wrong default')
    goLive(f, match)

    f.M.OnDeath(3, 1)
    t.equals(f.count('crimson_arena:client:exitArena', 3), 0,
        'a fighter who was supposed to watch the rest of the round was sent home')

    local told = f.lastPayload('crimson_arena:client:eliminated', 3)
    t.isNotNil(told, 'they were never told they were out')
    t.isTrue(told.spectate, 'they were told to watch nothing')

    f.M.OnDeath(2, 1)
    f.step()
    t.equals(f.count('crimson_arena:client:exitArena', 3), 1,
        'the watching fighter was never sent home at all')
end)

t.test('and a new round clears the flag, so they can be sent home again', function()
    -- Rows are reused between rounds -- which is why `placement` is reset on
    -- the line above this flag rather than assumed nil. Left set, the guard
    -- that stops the SECOND exit of one round becomes the thing that stops
    -- the FIRST exit of the next: the player finishes that round still
    -- standing in the arena while everybody else is sent home.
    local f, match = threeUp(function(config) config.Match.spectateOnElimination = false end)
    goLive(f, match)
    f.M.OnDeath(3, 1)
    t.isTrue(match.players[3].leftArena, 'the early exit did not happen, so there is no flag to clear')

    match.state = 'lobby'
    goLive(f, match)

    for src = 1, 3 do
        t.isNil(match.players[src].leftArena,
            ('fighter %d started the round already marked as having left it'):format(src))
    end

    f.M.OnDeath(3, 1)
    t.equals(f.count('crimson_arena:client:exitArena', 3), 2,
        'the second round could not send the same fighter home')
end)

-- ======================================================================
-- THE FRIENDLY-FIRE HOLD, AGAINST THE REST OF THE SERVER
-- ======================================================================

t.test('a team match puts the player on their side and turns friendly fire off', function()
    local f = outlinedTeamMatch()
    t.equals(f.team, f.env.Arena.TeamIndex('crimson'),
        'the engine was never told which side this fighter is on')
    t.isFalse(f.friendlyFire, 'and friendly fire was left on in a mode whose rule is that it is off')
end)

t.test('and another resource moving the player off it does not switch friendly fire back on', function()
    -- IN A PLAYER'S WORDS: "when switching teams on team deathmatch, when you
    -- try to start it with the same team then switch again, it keeps friendly
    -- fire".
    --
    -- SetPlayerTeam and NetworkSetFriendlyFireOption are settings on the
    -- PLAYER, not the ped, and every other resource on the box can write
    -- them: a gang script, a job script, a spectator or freecam resource
    -- putting you on a side of its own. The arena wrote them once at entry
    -- and never looked again -- so the first resource to touch either one
    -- turned friendly fire back on for the rest of the round, teammates
    -- shooting each other in a mode whose whole rule is that they cannot,
    -- with nothing said at either end.
    local f = outlinedTeamMatch()
    local ours = f.team

    -- SOMEBODY ELSE'S RESOURCE, mid-round.
    f.team = 7
    f.friendlyFire = true

    f.step()

    t.equals(f.team, ours, 'the arena never put its own side back')
    t.isFalse(f.friendlyFire, 'and friendly fire stayed on for the rest of the round')
end)

t.test('and the hold is not re-written every frame while nothing has touched it', function()
    -- A GUARD THAT ALWAYS FIRES IS NOT A GUARD. The re-hold is meant to cost
    -- one native read a frame on an untouched server; a comparison that never
    -- matches would have it writing three natives a frame for every fighter
    -- in every team round, for ever.
    local f = outlinedTeamMatch()
    local writes = 0
    local realSet = f.env.SetPlayerTeam
    f.env.SetPlayerTeam = function(...) writes = writes + 1 return realSet(...) end

    f.step()
    f.step()

    t.equals(writes, 0, 'the hold rewrote itself on a frame where nothing had drifted')
    f.env.SetPlayerTeam = realSet
end)

-- ======================================================================
-- WHO KILLED YOU, WHEN THE KILL LANDED IN ONE SHOT
-- ======================================================================

--- Into a live round, then killed by the SAME-FRAME path -- the damage-event
--- hook rather than the watch loop.
---
--- The two are not interchangeable, and that is the whole of this section:
--- the watch loop finds the body a frame or more later, by which time the
--- engine has filled in the ped's source of death; the hook runs in the frame
--- the ped dies, deliberately, because that is what stops a medical script
--- filing an ambulance out of the arena -- and there the source is still 0.
--- @param attacker integer|nil
local function killedInOneShot(f, attacker)
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'ffa',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
    f.fire('crimson_arena:client:matchLive')

    -- WHAT THE ENGINE REALLY ANSWERS THIS EARLY.
    f.sourceOfDeath = 0
    f.dead = true

    f.fire('gameEventTriggered', 'CEventNetworkEntityDamage', { f.ped, attacker, nil, 1 })
end

t.test('THE BUG: a kill that landed in one shot named nobody at all', function()
    -- IN A PLAYER'S WORDS: "headshots do not give points, on any of the
    -- matches -- FFA, gun game and team deathmatch".
    --
    -- It was never about headshots as such and never about the mode: it was
    -- about how FAST the victim died. A kill that took several shots, or that
    -- ended in a bleed-out, was found by the watch loop a frame later with the
    -- source of death set, and was credited. One that killed outright was
    -- caught by the damage-event hook in the same frame, where the source is
    -- 0 -- so killerServerId went out nil, the server had no claim to check,
    -- and nothing was logged at either end because a nil claim is not a
    -- rejected claim. The better the shot, the more reliably it happened.
    local f = newClientFixture()
    f.playerIndexOf = { [901] = 3 }
    f.serverIdOf = { [3] = 42 }

    killedInOneShot(f, 901)

    local reports = f.eventsNamed('crimson_arena:server:reportDeath')
    t.equals(#reports, 1, 'the death was not reported at all')
    t.equals(reports[1].payload.killerServerId, 42,
        'the killer the damage event named was dropped, so the kill was credited to nobody')
end)

t.test('and the slow-death path still names the killer it always did', function()
    -- The watch loop, a frame or more after the death, where the engine HAS
    -- filled the source in. This is the path that always worked, and it must
    -- go on working: reading the damage event first must not mean ignoring
    -- the native when there is no damage event to read.
    local f = newClientFixture()
    f.toFirstDeath()

    local reports = f.eventsNamed('crimson_arena:server:reportDeath')
    t.equals(#reports, 1, 'the watch loop stopped reporting deaths')
    t.equals(reports[1].payload.killerServerId, 7,
        'the source of death stopped being read when there is no attacker to prefer')
end)

t.test('and an attacker that is nobody falls back to the native rather than to nil', function()
    -- A death with no attacker in the payload -- a fall, the boundary bleed,
    -- drowning -- must not be worse off than it was. The native is asked
    -- exactly as before.
    local f = newClientFixture()
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'ffa',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
    f.fire('crimson_arena:client:matchLive')

    -- The native HAS been filled in by the time this one is spotted.
    f.sourceOfDeath = 900
    f.dead = true
    f.fire('gameEventTriggered', 'CEventNetworkEntityDamage', { f.ped, 0, nil, 1 })

    local reports = f.eventsNamed('crimson_arena:server:reportDeath')
    t.equals(#reports, 1, 'the death was not reported')
    t.equals(reports[1].payload.killerServerId, 7,
        'an attacker of 0 should fall through to the source of death, not to nobody')
end)

t.test('and the victim cannot name themselves however the death was spotted', function()
    -- The server refuses a self-report anyway -- resolveKiller does -- but a
    -- client that sends one is a client claiming something untrue, and the
    -- cheapest place to not say it is here.
    local f = newClientFixture()
    killedInOneShot(f, f.ped)

    local reports = f.eventsNamed('crimson_arena:server:reportDeath')
    t.equals(#reports, 1, 'the death was not reported')
    t.isNil(reports[1].payload.killerServerId, 'the victim named themselves as their own killer')
end)


-- ======================================================================
-- NOBODY WALKS IN HOLDING THEIR OWN GUN
-- ======================================================================

t.test('THE REPORT: a player holding a weapon when the round starts is emptied', function()
    -- IN A PLAYER'S WORDS: "what if someone has a weapon in hand before a
    -- match start and the match starts so that needs fixed".
    --
    -- ox_inventory owns the weapons here -- the item IS the weapon -- so
    -- nothing between the lobby and the arena floor looked at what was
    -- already in somebody's hands. They walked in with it and opened the
    -- round holding a gun the arena never issued them anything for.
    local f = newClientFixture()

    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'ffa',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })

    t.isTrue(#f.selected > 0, 'nothing was ever done to what the player is holding')
    t.equals(f.selected[1], f.env.joaat('WEAPON_UNARMED'),
        'the first thing the arena did to their hands was not to empty them')
end)

t.test('and it is HOLSTERED, not confiscated', function()
    -- ox_inventory owns the weapons in this resource -- the item IS the
    -- weapon -- so wiping the ped on the way IN would destroy things a
    -- player still owns an item for on a server running with the door off.
    -- That is the same mistake the exit path made once and carries a
    -- comment about.
    local f = newClientFixture()

    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'ffa',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })

    -- READ ON A RUN WHERE THE HOLSTER DEMONSTRABLY HAPPENED. On its own,
    -- "nothing was wiped" was already true before any of this existed --
    -- entry never called RemoveAllPedWeapons -- so deleting the holster left
    -- this test green. The two halves have to be asserted together, or this
    -- one is a claim about a code path that is not running.
    t.equals(f.selected[1], f.env.joaat('WEAPON_UNARMED'),
        'their hands were never emptied, so there is no holstering here to be the gentle version of')
    t.equals(f.wiped or 0, 0,
        'the arena wiped the ped on the way in, which destroys weapons the player owns')
end)

-- ======================================================================
-- NOBODY STARTS A ROUND DEAD
-- ======================================================================

t.test('THE REPORT: somebody killed before the match starts is stood up on entry', function()
    -- IN A PLAYER'S WORDS: "if i kill someone prior to a match start they
    -- spawn in dead".
    --
    -- Being shot in the street is a thing that happens to somebody queued
    -- for a round, and nothing between the lobby and the arena floor looked
    -- at whether they were on their feet. They were teleported in, frozen
    -- for the countdown, and then lay there for the whole match while
    -- everybody else fought over them.
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)

    goLive(f, match)

    t.isTrue(f.lastRevive(1) >= 1, 'fighter 1 was placed in the arena without being stood up')
    t.isTrue(f.lastRevive(2) >= 1, 'and neither was fighter 2')
end)

t.test('and it is the medical script that does it, not a revive of our own', function()
    -- This resource deliberately has no revive of its own -- it was removed
    -- so a server's own ambulance script decides what standing somebody up
    -- means. The entry has to go through the same door as the respawn and
    -- the admin tablet, or it is that removed revive coming back by the side.
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    -- The fixture records ArenaDispatch.Revive, which is the handoff.
    t.isTrue(f.lastRevive(1) >= 1,
        'the entry stood a player up without telling the medical script')

    -- AND THE NEGATIVE THIS TEST IS NAMED FOR. The line above is a strict
    -- subset of the test before it -- both go red on the same deletion, so
    -- alone it was a duplicate. What is actually being claimed is that the
    -- entry has no revive OF ITS OWN, and the tell for one would be the
    -- server running a death path on somebody who never died.
    t.isNil(f.lastPayload('crimson_arena:client:respawn', 1),
        'the entry sent a respawn of its own instead of handing off to the medical script')
    t.isNil(f.lastPayload('crimson_arena:client:eliminated', 1),
        'the entry ran the elimination path on a player who never died')
end)

-- ======================================================================
-- NOBODY IS PUT DOWN INSIDE THE SCENERY
-- ======================================================================
--
-- IN A PLAYER'S WORDS: "in the trailer park i keep spawning in trailers".
--
-- THESE SEND `scatterRadius = 0.0`, WHICH IS WHAT THE SERVER REALLY SENDS.
-- The first version of this section passed 12.0 and the whole feature was
-- tested against a number production never uses: both shipped arenas plan
-- every spawn, and a planned spawn is sent with no scatter at all
-- (server/match.lua) precisely so the client does not undo the spacing the
-- plan just worked out. A clearance check written as "redraw inside the
-- scatter radius" therefore had one candidate and could not move anybody --
-- which is why the check now lives in placeAt, next to the ground, and
-- steps OUTWARD from the planned point instead of redrawing.

--- How many points placeAt tries: the one it was given, then the rings.
--- Mirrored from client/match.lua's SPAWN_ESCAPE_RINGS and
--- SPAWN_ESCAPE_PER_RING.
local SPAWN_ESCAPE_POINTS = 1 + 3 * 4

--- A client on flat ground with a roof over everything within
--- `blockedRadius` of the spawn point, and open sky outside it.
--- @param blockedRadius number
--- @return table f
local function worldWithARoof(blockedRadius)
    local f = newClientFixture()
    f.groundZ = 30.0
    f.roofedAtX, f.roofedAtY = 10.0, 20.0
    f.roofedWithin = blockedRadius
    return f
end

--- Where the fighter was actually put down.
local function landedAt(f)
    return f.placements[#f.placements]
end

--- How far from the planned spawn point they ended up.
local function movedBy(f)
    local placed = landedAt(f)
    if not placed then return nil end
    local dx, dy = placed.x - 10.0, placed.y - 20.0
    return math.sqrt(dx * dx + dy * dy)
end

--- One fighter walked into an arena, on the payload the server really sends
--- for a planned spawn: the point, and no scatter.
local function enterTrailerPark(f, arenaKey)
    f.fire('crimson_arena:client:enterArena', {
        matchId = 'match-1',
        modeKey = 'ffa',
        arenaKey = arenaKey or 'trailerpark',
        spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
        scatterRadius = 0.0,
        freezeSeconds = 0,
        loadout = { weapons = {}, health = 200, armor = 0 },
    })
end

t.test('THE REPORT: a fighter is moved out from under a trailer', function()
    -- GetGroundZFor_3dCoord searches downward for TERRAIN and knows nothing
    -- about what is standing on it, so on a real map location with trailers
    -- on it the probe answered with the dirt UNDERNEATH one and the fighter
    -- was put down inside it. Both natives behaved exactly as documented.
    --
    -- Three metres of cover: the planned point is under it, the first ring
    -- at four metres is not.
    local f = worldWithARoof(3.0)

    enterTrailerPark(f)

    local placed = landedAt(f)
    t.isNotNil(placed, 'the fighter was never placed anywhere')
    t.isTrue(movedBy(f) > 3.0,
        'the fighter was put down under the roof, which is the inside of a trailer')
end)

t.test('and moved as little as will clear it, because the spacing was earned',
    function()
        -- THE PLAN ALREADY SPREAD THIS ROSTER. Every metre the escape spends
        -- is a metre of separation the server worked out and this gave back,
        -- so the rings are walked nearest first and the search stops at the
        -- first clear point rather than the best one.
        local f = worldWithARoof(3.0)

        enterTrailerPark(f)

        t.isTrue(movedBy(f) < 4.5,
            'a three-metre obstruction moved the fighter further than the first ring')
    end)

t.test('and further out when the near ring is under it too', function()
    -- The other direction: an escape that only ever tried one distance
    -- would pass the test above and leave anybody under something bigger
    -- than four metres exactly where they were. A caravan is about ten
    -- metres long, which is the whole reason there is more than one ring.
    local f = worldWithARoof(5.0)

    enterTrailerPark(f)

    t.isTrue(movedBy(f) > 5.0,
        'the fighter was left under a five-metre roof because only one ring was tried')
    t.isTrue(movedBy(f) < 8.5, 'and was moved further than the ring that cleared it')
end)

t.test('and an arena roofed over EVERY ring still places somebody', function()
    -- FAILS OPEN, ONTO THE POINT THE PLAN CHOSE. A poor spawn is a worse
    -- round; no spawn at all is no round -- and the planned point is a
    -- better answer than the furthest ring of a search that failed, because
    -- it is the one the server separated everybody on.
    local f = worldWithARoof(1000.0)

    enterTrailerPark(f)

    local placed = landedAt(f)
    t.isNotNil(placed, 'an arena with cover everywhere placed nobody at all')
    t.equals(placed.x, 10.0, 'the fall-back was not the point the plan chose')
    t.equals(placed.y, 20.0, 'the fall-back was not the point the plan chose')

    -- AND IT REALLY TRIED. A check that answered "clear" for everything
    -- would place somebody here too, on the first point.
    t.equals(#f.probes, SPAWN_ESCAPE_POINTS,
        'the picker did not walk every ring before giving up')
end)

t.test('and an arena that builds its OWN floor is never probed', function()
    -- THE OTHER HALF OF THE SAME REPORT: "in the skydome ... you dont spawn
    -- to low in props or to high". The skydome's surface is a prop THIS
    -- resource spawns, and the ground search does not know about props
    -- either -- which is why an exact-Z arena is placed at the Z it was
    -- given and nothing is asked. There is no ground answer to hang a roof
    -- test off, and its own floor is what a downward ray would find.
    --
    -- The trailer park, told to use its Z exactly -- the flag the sky arena
    -- carries. The sky arena itself builds a floor out of dozens of props on
    -- the way in, which is client/world.lua's spec to exercise, not this
    -- one's; the flag is what the placement actually reads.
    local f = newClientFixture(function(config)
        local arena = (config.Arenas or {})['trailerpark']
        t.isNotNil(arena, 'the trailer park is gone from config, so this test steers nothing')
        arena.exactSpawnZ = true
    end)
    f.groundZ = 30.0
    f.roofedAtX, f.roofedAtY = 10.0, 20.0
    f.roofedWithin = 1000.0

    enterTrailerPark(f)

    t.equals(#f.probes, 0,
        'an arena that builds its own floor was probed, and that floor is the roof')
    t.isNotNil(landedAt(f), 'nobody was placed in the arena at all')

    -- AND THE SAME WORLD WITHOUT THE FLAG IS PROBED, in the same test.
    -- On its own, "no probes were fired" is also what a build with the
    -- clearance check ripped out answers -- so the exemption would be
    -- borrowing its proof from a different test. This half is the control:
    -- one flag apart, thirteen probes apart.
    local probed = worldWithARoof(1000.0)
    enterTrailerPark(probed)
    t.isTrue(#probed.probes > 0,
        'no arena is probed at all, so the exemption above proves nothing')
end)

t.test('and the probe asks about the things a spawn can be inside of', function()
    -- WHAT THE RAY IS LOOKING FOR, which is the one argument no test could
    -- see until the stub started recording it. `1 + 2 + 8` shipped here: the
    -- map, vehicles and RAGDOLLS -- the exact opposite of the comment above
    -- the call, which claimed objects and said peds were left out.
    --
    -- The trailers are baked map geometry, so flag 1 covered the report that
    -- started this. What the wrong value cost was every prop anything
    -- SPAWNS: a shipping container laid out as cover read as open sky.
    local f = worldWithARoof(3.0)

    enterTrailerPark(f)

    local probe = f.probes[1]
    t.isNotNil(probe, 'nothing was probed at all, so this test read nothing')

    local flags = probe.flags or 0
    -- 1 IntersectWorld: the trailers, and every other piece of baked map.
    t.isTrue(flags % 2 == 1, 'the probe does not ask about the map itself')
    -- 16 IntersectObjects: anything CreateObject put there, this resource's
    -- own cover included.
    t.isTrue(math.floor(flags / 16) % 2 == 1, 'the probe does not ask about spawned props')
    -- 4 peds, 8 ragdolls: a person standing on the spot is not a roof, and
    -- on the respawn path the probe runs while the player is still a corpse.
    t.isTrue(math.floor(flags / 4) % 2 == 0, 'the probe treats a standing player as a roof')
    t.isTrue(math.floor(flags / 8) % 2 == 0, 'the probe treats a body on the ground as a roof')

    -- AND IT LOOKS DOWNWARD. A ray fired the other way answers about the
    -- ground, not about what is over it.
    t.isTrue(probe.fromZ > probe.toZ, 'the probe is fired upward, away from the spot')
end)

t.test('and a shape test that answers something unreadable leaves the point alone',
    function()
        -- FAILS OPEN, and this exit used to be the one that did not. A hit
        -- whose end coordinate cannot be read is an answer of nothing, and
        -- an answer of nothing has to leave the point usable -- otherwise a
        -- build whose native answers in a shape this code does not expect
        -- refuses every point in the arena.
        --
        -- AND IT MUST NOT THROW. The read used to index whatever it was
        -- handed, so a number or a `true` came back out of the placement and
        -- out of the entry handler -- which has already set the dispatch
        -- flag and the friendly-fire hold. The player is then standing in
        -- the city, flagged as being in an arena they never reached.
        for _, answer in ipairs({ 7.5, true, 'nowhere' }) do
            local f = newClientFixture()
            f.groundZ = 30.0
            f.shapeAnswer = answer

            local ok = pcall(enterTrailerPark, f)
            t.isTrue(ok, 'an unreadable shape-test answer threw out of the entry')

            local placed = landedAt(f)
            t.isNotNil(placed, 'nobody was placed at all')
            t.equals(placed.x, 10.0, 'the planned point was refused over an unreadable answer')
            -- PROBED ONCE, which is the half that says WHY it landed there.
            -- Failing closed lands on the planned point too -- by walking
            -- all thirteen and giving up -- so the coordinate alone cannot
            -- tell "the point was accepted" from "everything was refused".
            t.equals(#f.probes, 1,
                'the point was refused and the rings walked, which is failing closed')
        end
    end)

t.test('and open ground is used exactly as the plan chose it', function()
    -- The control: a world with nothing overhead must place the fighter on
    -- the point the server planned, unmoved, and must not start walking the
    -- rings -- or every spawn gives back the separation the plan bought.
    local f = newClientFixture()
    f.groundZ = 30.0

    enterTrailerPark(f)

    local placed = landedAt(f)
    t.isNotNil(placed, 'nobody was placed on open ground')
    t.equals(placed.x, 10.0, 'the fighter was moved off a spawn point with nothing over it')
    t.equals(placed.y, 20.0, 'the fighter was moved off a spawn point with nothing over it')
    t.equals(#f.probes, 1, 'open ground was not probed, or the rings were walked anyway')
end)

t.test('and a scatter radius, where a server sends one, still spreads people out',
    function()
        -- An arena with its spawn area switched off falls back to a
        -- round-robin list of points, and THAT is sent with a real radius --
        -- the one case where the client is meant to move somebody itself.
        local f = newClientFixture()
        f.groundZ = 30.0
        -- Dice read in pairs, an angle then a distance: the full radius due
        -- east of the point.
        f.randomDraws = { 0.0, 1.0 }

        f.fire('crimson_arena:client:enterArena', {
            matchId = 'match-1',
            modeKey = 'ffa',
            arenaKey = 'trailerpark',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
            scatterRadius = 12.0,
            freezeSeconds = 0,
            loadout = { weapons = {}, health = 200, armor = 0 },
        })

        local placed = landedAt(f)
        t.isNotNil(placed, 'nobody was placed at all')
        t.equals(placed.x, 22.0, 'the scatter did not move the fighter to the point it drew')
        t.equals(placed.y, 20.0, 'the scatter did not move the fighter to the point it drew')
    end)

os.exit(t.summary())
