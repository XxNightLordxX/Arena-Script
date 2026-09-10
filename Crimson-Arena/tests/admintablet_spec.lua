--[[
    crimson_arena/tests/admintablet_spec.lua

    /arenaadmin -- THE TABLET.

    A small screen for whoever is watching the server: the live matches, who
    is in one, what the arena is holding for them, a button to stop the round
    and a button to put a fighter back on their feet.

    THE GATE IS ON THE ACTION, NOT ON THE COMMAND, and that is the whole of
    what this file is about. The command OPENS the screen; it is not
    authorisation for anything the screen does. A client can fire these events
    without ever having run it -- that is what a client is -- so every handler
    re-checks ArenaIsAdmin on arrival, and these walk each one with a player
    who is not an admin to prove it.

    AND STOPPING A MATCH UNWINDS IT. Every stake goes back, every kit goes
    back, as though the round had not happened -- it is ArenaMatch.Abort, the
    same call the text command and the idle sweep make. That guarantee is
    asserted here against the TABLET's own path rather than borrowed from the
    text command's tests, because the two are different doors into it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('admintablet_spec')

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- @param admins table<integer, boolean> -- who IsPlayerAceAllowed says yes for
local function newArena(admins, mutate)
    local qbx = Sandbox.newQbxCore(roster({ [1] = 100000, [2] = 100000, [3] = 100000 }))
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents = {}, {}, {}
    local clock = 0

    --- What the arena believes it is holding for each player, and what the
    --- stash really contains. Two numbers rather than one, because the whole
    --- point of the escrow view is that they can disagree.
    local held = {}
    --- Stashes nobody has had back, as ArenaAmmo.OwedRows would answer, and
    --- who ArenaAmmo.ReturnLeftovers was asked to hand one to.
    ---
    --- HELD IN A BOX RATHER THAN AS A BARE LOCAL, so `server.owe` can replace
    --- the list. Assigning a field on the returned table looks like it works
    --- and changes nothing: the double closes over the local, not the field.
    local owedBox, returned, queued = { rows = {}, pending = {} }, {}, {}

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
        AddEventHandler = function(name, fn) netEvents['on:' .. name] = fn end,
        RegisterCommand = function(name, fn) netEvents['cmd:' .. name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- Well past every rate bucket on every call: a throttled event looks
        -- exactly like a refused one, and this file is about refusals.
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayers = function() return { '1', '2', '3' } end,
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
        IsPlayerAceAllowed = function(src) return admins[src] == true end,
        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Refresh = function() return true end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
            OwedKit = function() return owedBox.kit or {} end,
            OwedKitIsSaved = function() return owedBox.kitSaved == true end,
            HeldFor = function(src) return held[src] end,
            AllStashes = function(cb, scanned)
                -- NEVER ANSWERING IS A REAL OUTCOME, and it is the one this
                -- API's shape makes invisible: the production version issues
                -- an oxmysql query, and a database that is down, has no
                -- ox_inventory table, or is simply wedged leaves that
                -- callback never running -- with no error to catch, because
                -- the query was ACCEPTED. `stall` is that state.
                if owedBox.stall then return end

                -- HELD, NOT ANSWERED, when the test wants two scans in
                -- flight at once. The real one goes to a database: a second
                -- ask can overtake the first, and which of them draws the
                -- screen is the whole question.
                if owedBox.defer then
                    owedBox.pending[#owedBox.pending + 1] = function()
                        if scanned then scanned(owedBox.found or #owedBox.rows, #owedBox.rows) end
                        cb(owedBox.rows)
                    end
                    return
                end

                -- SYNCHRONOUS OTHERWISE, ASYNCHRONOUS IN PRODUCTION. The real
                -- one goes to the database; this answers straight away, which
                -- is the shape a callback API is allowed to take and the one
                -- that keeps these tests readable.
                if scanned then scanned(owedBox.found or #owedBox.rows, #owedBox.rows) end
                cb(owedBox.rows)
            end,
            ReturnLeftovers = function(src)
                returned[#returned + 1] = src
                return true, 1, false
            end,
            QueueReturn = function(citizenid, stash)
                queued[#queued + 1] = { citizenid = citizenid, stash = stash }
                return true
            end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end,
            Revive = function(src)
                netEvents.revived = netEvents.revived or {}
                netEvents.revived[#netEvents.revived + 1] = src
            end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Permissions = env.Config.Permissions or {}
    env.Config.Permissions.adminGroups = { 'admin' }
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env, qbx = qbx, config = env.Config, held = held,
        lobby = env.ArenaLobby, match = env.ArenaMatch, betting = env.ArenaBetting,
    }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.command(name, src, args)
        local handler = netEvents['cmd:' .. name]
        if not handler then error('no command ' .. name, 2) end
        env.source = src
        handler(src, args or {})
    end

    function server.step() threads.step(); threads.step() end

    --- Drops one player the way FiveM does, through the real handler.
    function server.dropPlayer(src)
        local handler = netEvents['on:playerDropped']
        if not handler then error('nothing handles playerDropped', 2) end
        env.source = src
        handler()
    end
    function server.revived() return netEvents.revived or {} end
    function server.returned() return returned end
    function server.queued() return queued end
    --- What ArenaAmmo.AllStashes will answer from here on.
    --- @param list table[]
    --- @param found integer? -- how many rows exist, when more than were read
    function server.owe(list, found)
        owedBox.rows = list
        owedBox.found = found
    end

    --- Makes ArenaAmmo.AllStashes accept every ask and answer none of them,
    --- which is what a wedged database looks like from in here.
    function server.stallStashes()
        owedBox.stall = true
    end

    --- Holds every stash scan open instead of answering it, so a test can
    --- decide the order they come back in.
    function server.deferStashes()
        owedBox.defer = true
    end

    --- Answers one held scan, oldest first.
    --- @return boolean whether there was one to answer
    function server.answerStash(index)
        local waiting = table.remove(owedBox.pending, index or 1)
        if not waiting then return false end
        waiting()
        return true
    end

    function server.pendingStashes() return #owedBox.pending end
    function server.log() return table.concat(console, '\n') end

    --- Every client event of one name, newest last.
    function server.sentNamed(name)
        local out = {}
        for _, row in ipairs(sent) do
            if row.event == 'crimson_arena:client:' .. name then out[#out + 1] = row end
        end
        return out
    end

    --- The newest one, which is what the tablet would be drawing.
    function server.lastNamed(name)
        local rows = server.sentNamed(name)
        return rows[#rows]
    end

    function server.open(count)
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
        })
        local id = server.lobby.All()[1].id
        for src = 2, count do
            server.fire('joinMatch', src, { matchId = id, account = 'cash' })
        end
        return id
    end

    return server
end

-- ======================================================================
-- WHO MAY USE IT
-- ======================================================================

t.test('THE GATE IS ON THE ACTION, not on the command that opens the screen', function()
    -- A client can fire these without ever running /arenaadmin. If the
    -- command were the only check, the tablet would be a list of admin
    -- powers any player could reach by name.
    local s = newArena({ [1] = true })
    local id = s.open(2)

    s.fire('adminStop', 2, { matchId = id })
    t.isNotNil(s.lobby.Get(id), 'a player who is not an admin stopped a match')

    s.fire('adminRevive', 2, { target = 1 })
    t.equals(#s.revived(), 0, 'a player who is not an admin revived somebody')

    s.fire('adminState', 2, {})
    t.isNil(s.lastNamed('adminState'), 'a player who is not an admin was sent the match list')
end)

t.test('and an admin gets all three', function()
    local s = newArena({ [1] = true })
    local id = s.open(2)

    s.fire('adminState', 1, {})
    local pushed = s.lastNamed('adminState')
    t.isNotNil(pushed, 'an admin was sent nothing at all')
    t.equals(#pushed.payload.matches, 1, 'the live match was not listed')
    t.equals(pushed.payload.matches[1].id, id, 'the wrong match was listed')
end)

-- ======================================================================
-- WHAT IT SHOWS
-- ======================================================================

t.test('opening a match lists the fighters in it', function()
    local s = newArena({ [1] = true })
    local id = s.open(3)

    s.fire('adminState', 1, { matchId = id })
    local focused = s.lastNamed('adminState').payload.focused
    t.isNotNil(focused, 'the match was not opened at all')
    t.equals(#focused.players, 3, 'the wrong number of fighters')
    t.equals(focused.id, id)
end)

t.test('and a fighter carries what the arena is holding for them', function()
    -- THE POINT OF THE SCREEN. "Their kit is safe" and "their stake is held"
    -- are claims this resource makes constantly and could not be asked to
    -- demonstrate: both lived in local tables with no reader, so the only way
    -- to see either was to end the round and watch what came back.
    local s = newArena({ [1] = true })
    local id = s.open(2)

    s.held[2] = {
        stash = 'crimson_arena_CID002',
        expected = 3,
        items = { { name = 'phone', count = 1 }, { name = 'burger', count = 2 } },
    }

    s.fire('adminState', 1, { matchId = id })
    local rows = s.lastNamed('adminState').payload.focused.players

    local row
    for _, candidate in ipairs(rows) do
        if candidate.src == 2 then row = candidate end
    end

    t.isNotNil(row, 'fighter 2 was not in the list')
    t.equals(#row.escrow, 2, 'the stash contents did not reach the screen')
    t.equals(row.escrowStash, 'crimson_arena_CID002', 'and neither did which stash it is')

    -- AND WHAT THE ARENA BELIEVES IT PUT AWAY, beside it. Those two
    -- disagreeing is the whole of the bug that lost people their belongings,
    -- and an admin staring at a short list needs to see the difference rather
    -- than work it out.
    t.equals(row.escrowExpected, 3,
        'the screen cannot show that the stash is holding less than it was given')
end)

t.test('and a fighter with no stash shows an empty one rather than throwing', function()
    -- The door can be off, or a stow can have failed, and neither is an error
    -- for this screen to fall over on.
    local s = newArena({ [1] = true })
    local id = s.open(2)

    s.fire('adminState', 1, { matchId = id })
    local rows = s.lastNamed('adminState').payload.focused.players
    t.equals(#rows[1].escrow, 0, 'a player with no stash was given contents from somewhere')
    t.equals(rows[1].escrowExpected, 0)
end)

-- ======================================================================
-- WHAT IT DOES
-- ======================================================================

t.test('THE GUARANTEE: stopping a match refunds every stake', function()
    -- IN THE OPERATOR'S WORDS: "when I stop a match it gives all items that
    -- are held in escrow, refunds all bets etc, as if the match never
    -- happened."
    --
    -- It is ArenaMatch.Abort -- the same call the text command, the idle
    -- sweep and a resource restart make -- and this asserts it against the
    -- TABLET's own door rather than borrowing the text command's coverage.
    local s = newArena({ [1] = true }, function(config)
        config.Betting.enabled = true
        config.Betting.entryFee = { enabled = true, min = 0, max = 50000, default = 5000 }
    end)

    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 5000, account = 'cash',
    })
    local id = s.lobby.All()[1].id
    s.fire('joinMatch', 2, { matchId = id, account = 'cash' })

    t.equals(s.qbx.players[1].money.cash, 95000, 'the host was not charged')
    t.equals(s.qbx.players[2].money.cash, 95000, 'the joiner was not charged')
    t.isTrue(s.betting.GetPot(id) > 0, 'nothing is in the pot, so there is nothing to refund')

    s.fire('adminStop', 1, { matchId = id })

    t.isNil(s.lobby.Get(id), 'the match was not stopped')
    t.equals(s.qbx.players[1].money.cash, 100000, 'the host was not refunded')
    t.equals(s.qbx.players[2].money.cash, 100000, 'the joiner was not refunded')
    t.equals(s.betting.GetPot(id), 0, 'the pot still holds money for a match that is gone')
end)

t.test('and the tablet is sent back to the list, not left on a dead match', function()
    local s = newArena({ [1] = true })
    local id = s.open(2)

    s.fire('adminStop', 1, { matchId = id })
    local pushed = s.lastNamed('adminState')
    t.isNotNil(pushed, 'the tablet was told nothing after the match ended')
    t.isNil(pushed.payload.focused,
        'the tablet is still showing a match that no longer exists')
    t.equals(#pushed.payload.matches, 0, 'and still listing it')
end)

t.test('and stopping a match that does not exist is refused rather than thrown', function()
    local s = newArena({ [1] = true })
    s.fire('adminStop', 1, { matchId = 'nosuchmatch' })
    -- Reaching here at all is the assertion; the refusal is the notification.
    t.isTrue(true)
end)

t.test('reviving puts one fighter back on their feet', function()
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.match.Start(id)
    -- LIVE, not merely started. ArenaMatch.Start places everybody and leaves
    -- the round in `countdown`; goLive runs on the thread it spawns, and
    -- OnDeath refuses a match that is not live -- so without this the death
    -- lands on nothing and the test proves the opposite of what it says.
    s.step()
    s.match.OnDeath(2, 1)

    t.isFalse(s.lobby.Get(id).players[2].alive, 'fighter 2 is not down, so this proves nothing')

    s.fire('adminRevive', 1, { target = 2 })

    -- BACK IN THE ROUND BY THE RESPAWN, NOT BY THE FLAG. A fighter dead in a
    -- live round with lives left already has a respawn scheduled; Revive
    -- used to flip the row alive on the spot, which made that thread bail
    -- and left them held on the floor with no respawn ever sent -- counted
    -- as standing, and once able to win. So the button leaves the standing
    -- alone there and the round stands them up itself. Step it.
    for _ = 1, 10 do s.step() end
    t.isTrue(s.lobby.Get(id).players[2].alive, 'the roster still says they are down')
    -- THE LAST ONE, not the first: everybody is revived once on the way into
    -- the arena now, so the first entry in this list is that rather than the
    -- button this test pressed.
    local told = s.revived()
    t.equals(told[#told], 2, 'the medical script was never told')
end)

t.test('and nobody outside a match can be revived through it', function()
    -- There is a /arenarevive for that. Taking the id straight off the wire
    -- would make this a revive-anybody button dressed as an arena tool.
    local s = newArena({ [1] = true })
    s.open(2)

    s.fire('adminRevive', 1, { target = 3 })
    t.equals(#s.revived(), 0, 'somebody who is not in a match was revived from the arena tablet')
end)

t.test('and a payload with no target at all is refused', function()
    local s = newArena({ [1] = true })
    s.open(2)
    s.fire('adminRevive', 1, {})
    t.equals(#s.revived(), 0, 'an empty payload revived somebody')
end)

-- ======================================================================
-- THE COMMAND
-- ======================================================================

t.test('/arenaadmin with no arguments opens the tablet for a player', function()
    local s = newArena({ [1] = true })
    s.open(2)

    s.command('arenaadmin', 1, {})

    local opened = s.lastNamed('openAdmin')
    t.isNotNil(opened, 'the command did not open anything')
    t.equals(opened.target, 1, 'the tablet was opened for the wrong person')
    t.equals(#opened.payload.matches, 1, 'it opened on an empty list')
end)

t.test('and the console still gets the text list it always had', function()
    -- The console has no NUI to open a screen in, so `tablet` is deliberately
    -- only the default for a real player.
    local s = newArena({})
    s.open(2)

    s.command('arenaadmin', 0, {})
    t.isNil(s.lastNamed('openAdmin'), 'the console was sent a screen it cannot draw')
    t.isTrue(s.log():find('lobby', 1, true) ~= nil,
        'the console was not given the match list: ' .. s.log())
end)

t.test('and a player who is not an admin gets neither', function()
    local s = newArena({ [1] = true })
    s.open(2)

    s.command('arenaadmin', 2, {})
    t.isNil(s.lastNamed('openAdmin'), 'the command opened the tablet for a non-admin')
end)

-- ======================================================================
-- WHAT NEVER MADE IT BACK
-- ======================================================================

t.test('the tablet lists stashes nobody has had back', function()
    -- THE COUNT WAS THE ONLY THING ANYBODY COULD ASK FOR, and a count is not
    -- actionable: "3 outstanding" tells an operator that three people are
    -- short and nothing about who, what, or whether the sweep is getting
    -- anywhere. The retry runs on its own, but the case it CANNOT finish --
    -- somebody who has not been back on the server since -- is exactly the
    -- one a person has to see.
    local s = newArena({ [1] = true })
    s.owe({
        { citizenid = 'CID002', stash = 'crimson_arena_CID002',
          items = { { name = 'phone', count = 1 } } },
    })

    s.fire('adminState', 1, {})
    local owed = s.lastNamed('adminState').payload.owed
    t.equals(#owed, 1, 'the outstanding stash did not reach the screen')
    t.equals(owed[1].citizenid, 'CID002', 'and neither did whose it is')
    t.equals(owed[1].items[1].name, 'phone', 'nor what is in it')
end)

t.test('and names the server id of whoever is online to receive it', function()
    -- `owed` is keyed by citizen id on purpose -- a server id is whoever
    -- holds it now, and that table has to survive a reconnect -- but a
    -- hand-back needs a live source to give items to. The absence of one is a
    -- real answer the screen shows rather than a row it hides.
    local s = newArena({ [1] = true })
    s.owe({
        { citizenid = 'CID002', stash = 'crimson_arena_CID002', items = {} },
        { citizenid = 'CID999', stash = 'crimson_arena_CID999', items = {} },
    })

    s.fire('adminState', 1, {})
    local owed = s.lastNamed('adminState').payload.owed

    local byId = {}
    for _, row in ipairs(owed) do byId[row.citizenid] = row end

    t.equals(byId.CID002.src, 2, 'a player who IS on the server was not matched to their stash')
    t.isNil(byId.CID999.src, 'a stash whose owner is gone was given somebody else\'s id')
end)

t.test('and an admin can hand one back from the tablet', function()
    local s = newArena({ [1] = true })
    s.owe({ { citizenid = 'CID002', stash = 'crimson_arena_CID002', items = {} } })

    s.fire('adminReturn', 1, { target = 2 })
    t.equals(#s.returned(), 1, 'nothing was handed back')
    t.equals(s.returned()[1], 2, 'it was handed to the wrong person')
end)

t.test('and a player who is not an admin cannot', function()
    -- The same rule as every other button on this screen: the command opens
    -- it, the handler decides.
    local s = newArena({ [1] = true })
    s.owe({ { citizenid = 'CID002', stash = 'crimson_arena_CID002', items = {} } })

    s.fire('adminReturn', 3, { target = 2 })
    t.equals(#s.returned(), 0, 'a player who is not an admin emptied somebody\'s stash')
end)

t.test('and a payload with no target is refused', function()
    local s = newArena({ [1] = true })
    s.fire('adminReturn', 1, {})
    t.equals(#s.returned(), 0, 'an empty payload handed something back')
end)

t.test('and says how many older stashes it did not open', function()
    -- Four stashes with things in them means something different depending on
    -- whether that is all of them or the first sixty of nine hundred, and an
    -- admin cannot tell those apart from the list alone.
    local s = newArena({ [1] = true })
    s.owe({
        { citizenid = 'CID002', stash = 'crimson_arena_CID002', items = {} },
    }, 900)

    s.fire('adminState', 1, {})
    local pushed = s.lastNamed('adminState').payload
    t.equals(pushed.stashesFound, 900, 'the screen was not told how many exist')
    t.equals(pushed.stashesRead, 1, 'nor how many were opened')
end)

t.test('and a stash this run has never heard of is still listed', function()
    -- THE WHOLE POINT OF GOING TO THE DATABASE. `owed` and `stashed` are in
    -- MEMORY: they survive a reconnect, the sweep works from them, and they
    -- are gone the moment the resource restarts. The stashes are not -- they
    -- are real ox_inventory rows -- so a player whose belongings were
    -- outstanding when the server went down was somebody nothing in this
    -- resource could name afterwards. That is the exact case where a person
    -- stays short for ever, and it was invisible.
    local s = newArena({ [1] = true })
    s.owe({
        {
            citizenid = 'CID777', stash = 'crimson_arena_CID777',
            items = { { name = 'phone', count = 1 } },
            -- Not in `owed` and not in `stashed`: found by name, not by
            -- memory.
            remembered = false,
        },
    })

    s.fire('adminState', 1, {})
    local rows = s.lastNamed('adminState').payload.owed
    t.equals(#rows, 1, 'a stash from an earlier run was not listed')
    t.equals(rows[1].citizenid, 'CID777')
    t.isFalse(rows[1].remembered,
        'the screen cannot tell a stash this run knows from one it found by name')
end)

t.test('and an offline owner has their return QUEUED rather than refused', function()
    -- THE GAP THIS CLOSES, and it is not a convenience. There is no live
    -- inventory to put items into for somebody who is not on the server, so
    -- the only safe thing an admin can do for them is make sure the server
    -- tries the instant they come back.
    --
    -- And it has to be possible, because `owed` is in MEMORY: a restart
    -- empties it, and the sweep only ever tries the people ON it. A stash
    -- left outstanding when the server went down was invisible to the retry
    -- for ever after -- the items safe in a real stash, and nothing ever
    -- going to hand them over. This is what puts it back on the list.
    local s = newArena({ [1] = true })

    s.fire('adminReturn', 1, {
        target = 0,
        citizenid = 'CID777',
        stash = 'crimson_arena_CID777',
    })

    t.equals(#s.returned(), 0, 'it tried to hand items to somebody who is not there')
    t.equals(#s.queued(), 1, 'the return was not queued for when they come back')
    t.equals(s.queued()[1].citizenid, 'CID777', 'it was queued under the wrong name')
    t.equals(s.queued()[1].stash, 'crimson_arena_CID777', 'and against the wrong stash')
end)

t.test('and an online owner is still handed it there and then', function()
    -- The same button, and the live path must not have been traded away for
    -- the offline one.
    local s = newArena({ [1] = true })

    s.fire('adminReturn', 1, {
        target = 2,
        citizenid = 'CID002',
        stash = 'crimson_arena_CID002',
    })

    t.equals(#s.returned(), 1, 'a player who IS on the server was only queued')
    t.equals(s.returned()[1], 2)
    t.equals(#s.queued(), 0, 'and queued as well, which would hand it over twice')
end)

t.test('and a queue with no stash to queue is refused', function()
    local s = newArena({ [1] = true })
    s.fire('adminReturn', 1, { target = 0, citizenid = 'CID777' })
    t.equals(#s.queued(), 0, 'a half-named stash was queued')

    s.fire('adminReturn', 1, { target = 0, stash = 'crimson_arena_CID777' })
    t.equals(#s.queued(), 0, 'a stash with no owner was queued')
end)

t.test('and a player who is not an admin cannot queue one either', function()
    local s = newArena({ [1] = true })
    s.fire('adminReturn', 3, {
        target = 0, citizenid = 'CID777', stash = 'crimson_arena_CID777',
    })
    t.equals(#s.queued(), 0, 'a non-admin queued a return')
end)

-- ======================================================================
-- AND THE SCREEN GOES UP EVEN WHEN THE DATABASE DOES NOT ANSWER
-- ======================================================================

t.test('THE BUG: a stash sweep that never answered meant /arenaadmin did NOTHING', function()
    -- The whole screen used to be opened from INSIDE the sweep's callback, on
    -- the reasoning that a first draw without the stash list would tell an
    -- operator "nothing outstanding" when somebody is short. Right about the
    -- lie, wrong about the cure: the sweep is a database read, and a database
    -- that never answers is not an error anybody can catch -- the query was
    -- accepted, so the pcall around it succeeded and the callback simply
    -- never ran.
    --
    -- What that looked like from a seat: type /arenaadmin, and nothing
    -- happens. No screen, no refusal, nothing in the console.
    local s = newArena({ [1] = true })
    s.open(2)
    s.stallStashes()

    s.command('arenaadmin', 1, {})

    local opened = s.lastNamed('openAdmin')
    t.isNotNil(opened, 'the command put no screen up at all')
    t.equals(opened.target, 1, 'the screen was opened for the wrong person')
    t.equals(#opened.payload.matches, 1, 'and it opened without the live matches on it')
end)

t.test('and the screen it puts up does not claim nobody is short', function()
    -- The first draw is honest about what it does not know yet: an EMPTY
    -- owed list draws no "not handed back yet" section at all, rather than an
    -- empty one captioned as good news. The counts say the same thing -- zero
    -- found, zero read, which is "not looked yet" rather than "looked and
    -- found none".
    local s = newArena({ [1] = true })
    s.open(2)
    s.stallStashes()

    s.command('arenaadmin', 1, {})

    local payload = s.lastNamed('openAdmin').payload
    t.equals(#payload.owed, 0, 'the first draw invented a stash list it had not read')
    t.equals(payload.stashesFound, 0, 'it claimed to know how many stashes exist')
    t.equals(payload.stashesRead, 0, 'and how many it had opened')
end)

t.test('and the stash list follows on its own once the sweep DOES answer', function()
    -- The command opens the screen and then asks for exactly the refresh the
    -- screen's own button asks for, so an admin never has to press anything
    -- to see the half of it they opened it for.
    local s = newArena({ [1] = true })
    s.open(2)
    s.owe({
        { citizenid = 'CID002', stash = 'crimson_arena_CID002',
          items = { { name = 'phone', count = 1 } } },
    })

    s.command('arenaadmin', 1, {})

    t.isNotNil(s.lastNamed('openAdmin'), 'the screen never went up')
    local pushed = s.lastNamed('adminState')
    t.isNotNil(pushed, 'the stash sweep was never asked for')
    t.equals(pushed.target, 1, 'it was pushed to the wrong person')
    t.equals(#pushed.payload.owed, 1, 'and it arrived without the outstanding stash on it')
    t.equals(pushed.payload.owed[1].citizenid, 'CID002')
end)

t.test('and a player who is not an admin still gets neither half', function()
    local s = newArena({ [1] = true })
    s.open(2)
    s.owe({ { citizenid = 'CID002', stash = 'crimson_arena_CID002', items = {} } })

    s.fire('adminState', 1, {})   -- one legitimate push, so `lastNamed` has a floor
    local before = #s.sentNamed('adminState')

    s.command('arenaadmin', 2, {})
    t.isNil(s.lastNamed('openAdmin'), 'the command opened the tablet for a non-admin')
    t.equals(#s.sentNamed('adminState'), before,
        'a non-admin got the stash sweep pushed at them anyway')
end)

-- ======================================================================
-- A REVIVE IS NOT A RESURRECTION INTO THE ROUND
-- ======================================================================

t.test('THE BUG: reviving an ELIMINATED fighter put them back in the running', function()
    -- Arena.IsEliminated is exactly `alive ~= true and lives <= 0`, so
    -- flipping the flag alone put a fighter the round had already finished
    -- with back into every winner-selection path in server/match.lua -- while
    -- standing outside the arena, unkillable, and not fighting.
    --
    -- Two things followed. The round could no longer END by last-man-
    -- standing, because a spectator was being counted as standing; and once
    -- the real fighters had eliminated each other, that spectator was the
    -- last one left, crowned, and paid the pot.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.match.Start(id)
    s.step()

    local row = s.lobby.Get(id).players[2]
    row.alive = false
    row.lives = 0
    t.isTrue(s.env.Arena.IsEliminated(row), 'fighter 2 is not eliminated, so this proves nothing')

    s.fire('adminRevive', 1, { target = 2 })

    t.isTrue(s.env.Arena.IsEliminated(s.lobby.Get(id).players[2]),
        'an eliminated fighter was put back into the running from the tablet -- they can now '
        .. 'be crowned and paid the pot without firing a shot')
end)

t.test('THE REPORT: and a fighter down during the START COUNTDOWN can be revived', function()
    -- IN A PLAYER'S WORDS: "i was unable to use arenaadmin tablet to revive
    -- them", of somebody killed before the match started.
    --
    -- The guard read `state == 'live'`, and the start countdown is
    -- `countdown` -- everybody standing in the arena, frozen, waiting for the
    -- guns. Somebody who arrived down is exactly the person an admin is
    -- reaching for at that moment, and the tablet refused: the medical revive
    -- went out while the roster went on calling them dead, so they stood up
    -- and the round still treated them as a corpse.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.match.Start(id)
    t.equals(s.lobby.Get(id).state, 'countdown', 'the round is not in its countdown')

    local row = s.lobby.Get(id).players[2]
    row.alive = false

    s.fire('adminRevive', 1, { target = 2 })

    t.isTrue(s.lobby.Get(id).players[2].alive,
        'a fighter down in the start countdown could not be put back on their feet')
end)

t.test('and a lobby that has not started is still refused', function()
    -- Nobody is in an arena then, so there is no round standing to restore --
    -- and the medical revive is /arenarevive's job, not this screen's.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    t.equals(s.lobby.Get(id).state, 'lobby', 'the match already started')

    local row = s.lobby.Get(id).players[2]
    row.alive = false

    s.fire('adminRevive', 1, { target = 2 })

    t.isFalse(s.lobby.Get(id).players[2].alive,
        'a lobby that has not begun had a round standing restored in it')
end)

t.test('and is still picked up off the floor, because that is what the button says', function()
    -- The two halves are separate on purpose. Standing somebody up medically
    -- is never the wrong thing to do; putting them back into a round that has
    -- finished with them is.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.match.Start(id)
    s.step()

    local row = s.lobby.Get(id).players[2]
    row.alive = false
    row.lives = 0

    s.fire('adminRevive', 1, { target = 2 })
    -- THE LAST ONE, not the first: everybody is revived once on the way into
    -- the arena now, so the first entry in this list is that rather than the
    -- button this test pressed.
    local told = s.revived()
    t.equals(told[#told], 2, 'the medical script was never told')
end)

t.test('and a fighter with lives LEFT is still put back into the round', function()
    -- The control. A fix that simply stopped touching `alive` would pass the
    -- test above and turn the button into a no-op for everybody it is for.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.match.Start(id)
    s.step()
    s.match.OnDeath(2, 1)

    local row = s.lobby.Get(id).players[2]
    t.isFalse(row.alive, 'fighter 2 is not down, so this proves nothing')
    t.isTrue((row.lives or 0) > 0, 'and they are out of lives, which is the other test')

    s.fire('adminRevive', 1, { target = 2 })
    -- BACK IN THE ROUND BY THE RESPAWN, NOT BY THE FLAG. A fighter dead in a
    -- live round with lives left already has a respawn scheduled; Revive
    -- used to flip the row alive on the spot, which made that thread bail
    -- and left them held on the floor with no respawn ever sent -- counted
    -- as standing, and once able to win. So the button leaves the standing
    -- alone there and the round stands them up itself. Step it.
    for _ = 1, 10 do s.step() end
    t.isTrue(s.lobby.Get(id).players[2].alive, 'the roster still says they are down')
end)

-- ======================================================================
-- AND A SLOW REFRESH DOES NOT PAINT OVER A NEW ONE
-- ======================================================================

t.test('THE BUG: a stash scan that answered late threw the admin out of the match', function()
    -- The stash sweep is a database read and can take seconds. Nothing
    -- sequenced two of them and the tablet applies every payload it is sent
    -- -- so an admin who refreshed against a slow database and then clicked
    -- into a match had the first scan answer afterwards, with `focused` nil
    -- and match rows several seconds old. A match aborted in between still
    -- showed as live, and still offered a Stop button for it.
    local s = newArena({ [1] = true })
    local id = s.open(2)
    s.deferStashes()

    s.fire('adminState', 1, {})              -- scan 1: the match list
    s.fire('adminState', 1, { matchId = id }) -- scan 2: one match, opened
    t.equals(s.pendingStashes(), 2, 'the fixture did not hold both scans')

    s.answerStash(2)   -- the NEWER one draws
    t.isNotNil(s.lastNamed('adminState').payload.focused, 'the newer scan drew nothing')

    s.answerStash(1)   -- and the older one, arriving late, must not

    t.isNotNil(s.lastNamed('adminState').payload.focused,
        'a stale scan threw the admin back out to the match list')
end)

t.test('and an ordinary refresh still draws', function()
    -- The control: a ticket that refused everything would pass the test above
    -- and leave the screen permanently frozen on its first draw.
    local s = newArena({ [1] = true })
    s.open(2)
    s.deferStashes()

    s.fire('adminState', 1, {})
    t.isTrue(s.answerStash(1), 'there was no scan to answer')
    t.isNotNil(s.lastNamed('adminState'), 'the refresh drew nothing at all')
end)

t.test('and a scan still in flight when its admin leaves is dropped', function()
    -- The ticket is keyed by server id, and server ids are recycled. A scan
    -- answering after its admin has gone would otherwise be sent to whoever
    -- holds that id next.
    local s = newArena({ [1] = true })
    s.open(2)
    s.deferStashes()

    s.fire('adminState', 1, {})
    local before = #s.sentNamed('adminState')

    s.dropPlayer(1)
    s.answerStash(1)

    t.equals(#s.sentNamed('adminState'), before,
        'a scan was pushed at a server id whose admin had already left')
end)

-- ======================================================================
-- AND THE DOORS ARE ON EVERY PUSH
--
-- The tablet has a switch for them and draws a whole screen off them, and a
-- switch that cannot show its own state is a switch nobody can trust.
-- ======================================================================

t.test('the tablet is told whether the arena is open, and who decided that', function()
    local s = newArena({ [1] = true })
    s.open(2)

    s.fire('adminState', 1, {})
    local payload = s.lastNamed('adminState').payload

    t.isTrue(payload.hoursOpen, 'the tablet was not told the arena is open')
    t.isNil(payload.hoursForced, 'it was told somebody had decided that, and nobody had')
end)

t.test('and the same on the very first draw, not only on a refresh', function()
    -- The command opens the screen before the stash sweep answers. A doors
    -- state that only arrived with the refresh would leave the first frame
    -- drawing a closed arena as open, or the other way about.
    local s = newArena({ [1] = true })
    s.open(2)

    s.command('arenaadmin', 1, {})
    local opened = s.lastNamed('openAdmin').payload

    t.isTrue(opened.hoursOpen, 'the first draw was not told whether the arena is open')
end)

t.test('and it carries the HOURS, so a closed arena can say what it is closed until', function()
    -- A field the server does not send is a field the screen cannot draw, and
    -- both ends look correct while it is missing. This resource has shipped
    -- that bug more than once.
    -- NO MATCH OPENED, deliberately: with hours enforced this window may well
    -- be shut at the moment the suite runs, and a lobby that could not be
    -- created would fail this test for a reason it is not about.
    local s = newArena({ [1] = true }, function(config)
        config.Schedule = { enabled = true, windows = { { from = 5, to = 7 } }, offsetHours = 0 }
    end)

    s.fire('adminState', 1, {})
    local payload = s.lastNamed('adminState').payload

    t.equals(payload.hoursLine, '05:00-07:00', 'the schedule did not reach the screen')
end)

t.test('and says so plainly on a server that keeps no hours at all', function()
    -- Not the same as "open all day" said badly: there is no window to quote,
    -- and the screen has its own words for that.
    local s = newArena({ [1] = true }, function(config)
        config.Schedule = { enabled = false, windows = {}, offsetHours = 0 }
    end)

    s.fire('adminState', 1, {})
    t.isNil(s.lastNamed('adminState').payload.hoursLine,
        'a server keeping no hours sent some anyway')
end)

t.test('and an admin closing it is reported back as an admin closing it', function()
    local s = newArena({ [1] = true })
    s.open(2)

    s.fire('adminHours', 1, { forced = 'shut' })

    local payload = s.lastNamed('adminState').payload
    t.isFalse(payload.hoursOpen, 'the tablet still thinks the arena is open')
    t.equals(payload.hoursForced, 'shut', 'and cannot tell an admin closed it')
end)

os.exit(t.summary())
