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

    local revived = {}       -- every ArenaDispatch.Revive(src), in order
    local revivedHold = {}   -- the same calls, carrying their keepHold flag

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
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            -- Recorded, not swallowed: the arena telling whatever handles
            -- death that a player is alive again is the whole reason a
            -- player does not walk out of a match still dead, so WHO gets
            -- told and HOW MANY TIMES is the thing worth asserting.
            -- The keepHold flag is captured alongside the id, because
            -- WHETHER a revive frees the player is as load-bearing as who
            -- gets one: elimination revives on purpose and must NOT free
            -- them, and a fixture that threw the flag away is how that
            -- shipped.
            Revive = function(src, keepHold)
                revived[#revived + 1] = src
                revivedHold[#revivedHold + 1] = { src = src, keepHold = keepHold == true }
            end,
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
        revivedHold = revivedHold,
        --- The keepHold flag of the last revive aimed at `src`, or nil.
        lastHold = function(src)
            for index = #revivedHold, 1, -1 do
                if revivedHold[index].src == src then return revivedHold[index].keepHold end
            end
            return nil
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
        arenaKey = 'airfield',
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

t.test('and eliminating them does NOT let them out of the hold', function()
    -- Found by an audit, not by these tests, which is why it is here.
    --
    -- The server revives an eliminated player on purpose -- to get them off
    -- the medical script's casualty list -- while the round carries on
    -- without them. That revive used to free them as well, because the calls
    -- it makes are byte-for-byte ReleaseDeadState's: spectate re-hides and
    -- re-freezes the parked body but never restores invincibility, so they
    -- were left MORTAL and killable, and with spectate off they simply stood
    -- back up, armed, in a live round.
    local f = newFixture(instantRound)
    local match = newMatch(f, 2)
    goLive(f, match)

    t.isTrue(f.M.OnDeath(2, 1))

    t.equals(f.lastHold(2), true,
        'the eliminated player was revived without keepHold, so the hold is dropped and they are mortal in a live round')
end)

t.test('while a revive on the way OUT does free them, or they leave frozen', function()
    -- The other side of the same flag, and the reason it cannot simply
    -- default to keeping the hold: a player going home must be released.
    local f = newFixture(instantRound)
    goLive(f, newMatch(f, 2))

    t.isTrue(f.M.RemovePlayer(2, 'match.left'))

    t.equals(f.lastHold(2), false,
        'a player sent home was revived with the hold kept, so they leave invisible and frozen')
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

    t.equals(results.matchId, 'm1')
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
local function newClientFixture()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 100,
        dead = false,
        groundReady = true,
        serverEvents = {},
        released = {},
        cleared = 0,
        given = {},
        -- Where the player has been put, in order. A placement that happens
        -- AFTER they have gone home is the defect the last test covers.
        placements = {},
    }

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
        GetGroundZFor_3dCoord = function() return false, nil end,
        -- Frozen, so placeAt's five-second bail-out never trips and
        -- `groundReady` stays the only thing that ends the wait.
        GetGameTimer = function() return 0 end,

        GiveWeaponToPed = function(ped, weapon, ammo)
            f.given[#f.given + 1] = { ped = ped, weapon = weapon, ammo = ammo }
        end,
        SetPedAmmo = function() end,
        SetPedArmour = function() end,
        SetEntityHealth = function() end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end,
        RemoveWeaponFromPed = function() end,

        DisableControlAction = function() end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 900 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 5 end,
        GetPlayerServerId = function() return 7 end,

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
        SetEntityDrawOutline = function(ped, on)
            f.outlines = f.outlines or {}
            f.outlines[#f.outlines + 1] = { ped = ped, on = on == true }
        end,
        SetEntityDrawOutlineColor = function(r, g, b)
            f.outlineColor = { r = r, g = g, b = b }
        end,

        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,

        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ClearDeadState = function() f.cleared = f.cleared + 1 return true end,
            ReleaseDeadState = function(ped)
                f.released[#f.released + 1] = { ped = ped }
            end,
        },
    })

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

    --- The message the server sends back. Threaded, because it yields.
    function f.respawn()
        f.fireThreaded('crimson_arena:client:respawn', {
            spawn = { x = 11.0, y = 21.0, z = 31.0, w = 0.0 },
            loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
        })
    end

    return f
end

t.test('the first death is reported and held, so the respawn tests below start where they claim to', function()
    local f = newClientFixture()
    f.toFirstDeath()

    t.equals(#f.serverEvents, 1, 'the death nobody reported cannot be the one a respawn answers')
    t.equals(f.serverEvents[1].name, 'crimson_arena:server:reportDeath')
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

    t.equals(#f.serverEvents, 1,
        'the respawn re-reported the death it was sent to answer -- the watch was re-armed over a body')

    -- Shot where they stand, mid-placement.
    f.dead = true
    f.step()

    t.equals(#f.serverEvents, 2,
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

t.test('a respawned fighter is re-armed, and only once the round still wants them', function()
    local f = newClientFixture()
    f.toFirstDeath()
    local armedOnEntry = #f.given

    f.respawn()
    f.step()

    t.equals(#f.given, armedOnEntry + 1, 'the respawned player came back empty-handed')
    t.equals(f.given[#f.given].ped, f.ped, 'the weapon went to the handle the resurrect replaced')
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

    t.equals(#f.serverEvents, 2, 'the fighter the server put back in the round could never die again')
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

    local releasedByExit = #f.released
    f.fire('crimson_arena:client:exitArena', {})
    t.equals(#f.released, releasedByExit + 1, 'leaveArena did not release the hold on the way home')

    f.groundReady = true
    f.step()

    t.equals(#f.released, releasedByExit + 2,
        'the parked respawn re-froze the ped on its way out and left nothing to unfreeze it')
    t.equals(#f.given, 1, 'a player already home was re-armed with the arena loadout')
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

os.exit(t.summary())
