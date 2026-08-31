--[[
    crimson_arena/tests/matchflow_spec.lua

    One whole round, driven end to end through the REAL server/match.lua over
    the REAL config.lua, shared/arena.lua and server/util.lua: a lobby is put
    into the arena, a fighter is eliminated, another walks out mid-round, and
    the round is settled.

    IT ASSERTS ON TWO EDGES AND NOTHING ELSE -- what went on the wire, and the
    one table this file hands to the money. Everything past either of those
    belongs to a client file or to server/betting.lua, and a spec that stubbed
    its way across one would only be proving the stub.

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
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
        ArenaBetting = {
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

os.exit(t.summary())
