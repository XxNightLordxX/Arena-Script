--[[
    crimson_arena/tests/hudsenthome_spec.lua

    THE SCOREBOARD IS FOR PEOPLE WHO CAN SEE THE ROUND.

    Every second of a live round server/match.lua pushes the in-match board
    -- scoreboard, remaining, the clock, the pot -- to every row on the roster
    and to every watcher. An ELIMINATED fighter keeps their row by design:
    the results board ranks off it and the payout reads it. So a fighter who
    was SENT HOME -- spectateOnElimination off, or a watch that could not be
    registered -- went on being sent that board, once a second, until the
    round ended, on a client that had already left the arena and throws it
    away: currentMatch is nil, nothing draws from it, and the overlay is told
    to stay hidden. About 1.2-1.5 KB a second each at twenty fighters.

    So the push skips exactly that fighter: `leftArena` true AND not watching
    this round. THE SPECTATOR HALF IS LOAD-BEARING. A fighter sent home can
    still choose Watch on the same round from the panel (AddSpectator lets
    an eliminated fighter watch their own round), and the spectator loop
    skips anybody who is still on the roster -- so without that half, the
    one person who asked to see the round would be the one who got nothing.

    What this file holds to, beyond the skip itself:

      EVERY FIGHTER STILL IN THE ARENA GETS ONE BOARD A TICK, AND EVERY
      WATCHER ONE, carrying the same shared fields and their own numbers.

      THE SHIPPED CONFIG CHANGES NOTHING. spectateOnElimination ships ON, so
      an eliminated fighter watches, and a watcher is never skipped.

      A SENT-HOME FIGHTER WHO WATCHES GETS THEIR OWN BOARD BACK -- kills,
      deaths and side -- not the blank one a stranger watching is sent.

      AND THE REST IS THE OLD LOOP, EXACTLY. A reference copy of the old
      push is kept below and driven against the real sweep over a seeded
      sweep of rosters, modes and win conditions: the recipients, their
      numbers and every shared field agree, except the fighters this change
      means to skip.

    Deterministic throughout: os.time and GetGameTimer are the fixture's,
    and the sweep draws from a local generator with a fixed seed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('hudsenthome_spec')

local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }
local NOW = 1700000000
local HUD = 'crimson_arena:client:matchHud'

--- Server ids 1..8 are fighters; 11..13 are onlookers who never join.
local FIGHTERS = { 1, 2, 3, 4, 5, 6, 7, 8 }
local ONLOOKERS = { 11, 12, 13 }

--- A whole arena server: the real util, betting, lobby, match and main.
--- @param opts table? -- { mutate = fn(config), fighters = n, mode = key, win = key }
--- @return table server
local function newServer(opts)
    opts = opts or {}
    local players = {}
    for _, src in ipairs(FIGHTERS) do
        players[src] = {
            citizenid = ('CID%03d'):format(src), name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    for _, src in ipairs(ONLOOKERS) do
        players[src] = {
            citizenid = ('CID%03d'):format(src), name = ('Onlooker %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent = {}, {}, {}
    local clock = 1000

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        os = setmetatable({ time = function() return NOW end }, { __index = os }),
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
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[tonumber(src)] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = CENTRE.x + ((tonumber(ped) or 0) % 16) * 2.0, y = CENTRE.y, z = CENTRE.z }
        end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            SwapWeapon = function() return true end,
            GrantSupply = function() return true end,
            PayKillAmmo = function() return true end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
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
    env.Config.Modes.gungame.enabled = true
    if opts.mutate then opts.mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, console = console, sent = sent,
        match = env.ArenaMatch, lobby = env.ArenaLobby, Arena = env.Arena }
    local matchId

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        -- Past every rate bucket main.lua keeps, so a throttled event can
        -- never pass for a refused one.
        clock = clock + 60000
        env.source = src
        handler(data)
    end

    --- Opens and starts a round through the ready path.
    --- @param count integer -- fighters 1..count take a seat
    function server.play(count, modeKey, winCondition)
        modeKey = modeKey or 'ffa'
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey, entryFee = 0, account = 'cash',
            winCondition = winCondition, scoreLimit = winCondition == 'score_limit' and 50 or nil,
            lives = env.Config.Match.lives,
        })
        local all = server.lobby.All()
        matchId = all[#all].id
        for src = 2, count do server.fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        if server.Arena.ModeUsesTeams(modeKey) then
            for src = 1, count do
                server.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        for src = 1, count do server.fire('setReady', src, { ready = true }) end
        for _ = 1, 6 do
            if server.lobby.Get(matchId).state == 'live' then break end
            threads.step()
        end
        assert(server.lobby.Get(matchId).state == 'live', 'the fixture failed to start the round')
        -- One more pass, so every thread the start queued has had its turn
        -- and the NEXT tick is a clean one.
        threads.step()
        return server.lobby.Get(matchId)
    end

    function server.live() return server.lobby.Get(matchId) end
    function server.matchId() return matchId end

    --- One pass of the once-a-second sweep. Returns the boards it pushed,
    --- as { [target] = { payload, ... } }, and how many there were.
    function server.tick()
        local from = #sent
        threads.step()
        local boards, total = {}, 0
        for index = from + 1, #sent do
            local message = sent[index]
            if message.event == HUD then
                boards[message.target] = boards[message.target] or {}
                table.insert(boards[message.target], message.payload)
                total = total + 1
            end
        end
        return boards, total
    end

    --- Runs pending threads without counting anything -- the respawn thread,
    --- the bets-close broadcast.
    function server.settle(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    return server
end

local function countFor(boards, src) return #(boards[src] or {}) end

-- ======================================================================
-- THE DEFECT, AND THE COST IT CARRIES
-- ======================================================================

t.test('DEFECT: a fighter SENT HOME and not watching is pushed no board', function()
    -- spectateOnElimination off: an eliminated fighter goes home, their row
    -- stays, and the old loop kept pushing their board once a second to a
    -- client that had already left the arena.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(4)

    s.match.OnDeath(2, 1)
    s.settle()
    t.isTrue(match.players[2] ~= nil, 'the eliminated fighter lost their row, so this proves nothing')
    t.isTrue(match.players[2].leftArena == true, 'the eliminated fighter was not sent home')
    t.isTrue(not (match.spectators or {})[2], 'the fighter sent home is registered as watching')

    local boards = s.tick()
    t.equals(countFor(boards, 2), 0, 'a fighter sent home and not watching was still pushed the board')
    for _, src in ipairs({ 1, 3, 4 }) do
        t.equals(countFor(boards, src), 1, 'fighter ' .. src .. ' still in the round did not get exactly one board')
    end
end)

t.test('THE BUDGET: boards per tick are fighters in the arena plus watchers, and not one more', function()
    -- Six fighters, three of them eliminated and sent home, two onlookers.
    -- The old loop pushed 6 + 2 = 8 a tick; the three sent home threw
    -- theirs away. This pins the count so an edit that brings the pushes
    -- back fails here rather than on a live server's bandwidth.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    s.play(6)
    for _, src in ipairs({ 11, 12 }) do s.fire('spectateMatch', src, { matchId = s.matchId() }) end
    for _, victim in ipairs({ 4, 5, 6 }) do
        s.match.OnDeath(victim, 1)
        s.settle()
    end
    t.equals(s.live().state, 'live', 'the round ended, so there is no tick to measure')

    for _ = 1, 3 do
        local boards, total = s.tick()
        t.equals(total, 5, 'the tick did not push exactly 3 fighters + 2 watchers')
        for _, src in ipairs({ 4, 5, 6 }) do t.equals(countFor(boards, src), 0, 'sent home, still pushed: ' .. src) end
        for _, src in ipairs({ 1, 2, 3, 11, 12 }) do t.equals(countFor(boards, src), 1, 'missed: ' .. src) end
    end
end)

-- ======================================================================
-- WHAT MUST NOT CHANGE: THE VETTED CASES
-- ======================================================================

t.test('SENT HOME, THEN WATCH: the board comes back, their own, one a tick', function()
    -- The case the spectator half of the guard is for. AddSpectator lets an
    -- eliminated fighter watch their own round; the spectator loop skips
    -- anybody still on the roster; so this board can only come from the
    -- fighters' loop -- and it must carry their own deaths and side, not
    -- the blank board a stranger watching is sent.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(4, 'tdm')

    s.match.OnDeath(2, 1)
    s.settle()
    t.isTrue(match.players[2].leftArena == true, 'premise: fighter 2 was sent home')

    s.fire('spectateMatch', 2, { matchId = s.matchId() })
    t.isTrue((match.spectators or {})[2] == true, 'the sent-home fighter could not watch their own round')

    for _ = 1, 2 do
        local boards = s.tick()
        t.equals(countFor(boards, 2), 1, 'a sent-home fighter who chose Watch did not get exactly one board')
        local board = (boards[2] or {})[1] or {}
        t.equals(board.deaths, 1, 'the watching fighter was sent somebody else\'s numbers')
        t.equals(board.team, match.players[2].team, 'the watching fighter was sent a board with no side')
        t.equals(board.matchId, s.matchId(), 'the board names the wrong round')
    end
end)

t.test('DEFECT, THE ROUND TRIP: home, then Watch, then Stop -- the board goes, comes, and goes again', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(4, 'tdm')
    s.match.OnDeath(2, 1)
    s.settle()

    t.equals(countFor(s.tick(), 2), 0, 'a fighter sent home is still pushed the board')
    s.fire('spectateMatch', 2, { matchId = s.matchId() })
    t.equals(countFor(s.tick(), 2), 1, 'watching did not bring the board back')
    s.fire('stopSpectating', 2)
    t.isTrue(not (match.spectators or {})[2], 'premise: they stopped watching')
    t.equals(countFor(s.tick(), 2), 0, 'a sent-home fighter who stopped watching is still pushed the board')
end)

t.test('SHIPPED CONFIG: an eliminated fighter watches, and gets exactly one board a tick', function()
    local s = newServer()
    t.isTrue(s.config.Match.spectateOnElimination == true, 'the shipped config no longer watches on elimination')
    local match = s.play(4)

    s.match.OnDeath(2, 1)
    s.settle()
    t.isTrue(match.players[2].leftArena ~= true, 'a watcher was sent home')
    t.isTrue((match.spectators or {})[2] == true, 'the eliminated fighter is not watching')

    local boards = s.tick()
    t.equals(countFor(boards, 2), 1, 'the eliminated watcher did not get exactly one board')
    t.equals(((boards[2] or {})[1] or {}).deaths, 1, 'the eliminated watcher was sent the stranger\'s board')
    for _, src in ipairs({ 1, 3, 4 }) do t.equals(countFor(boards, src), 1, 'missed fighter ' .. src) end
end)

t.test('AN ELIMINATED WATCHER WHO STOPS WATCHING, never sent home, keeps the board', function()
    -- leftArena is nil for them -- they are still standing in the arena --
    -- so they are not what this skips.
    local s = newServer()
    local match = s.play(4)
    s.match.OnDeath(2, 1)
    s.settle()
    s.fire('stopSpectating', 2)
    t.isTrue(not (match.spectators or {})[2], 'premise: they stopped watching')
    t.isTrue(match.players[2].leftArena ~= true, 'premise: they were never sent home')

    t.equals(countFor(s.tick(), 2), 1, 'an eliminated fighter still in the arena lost the board')
end)

t.test('AND THE NEXT ROUND: a fighter sent home in one round gets the board in the next', function()
    -- End tears the round down; Start writes `leftArena = nil` on every row
    -- of the next. Played end to end: 2 goes home, 3 goes home, 1 wins, and
    -- the same three sit down again.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local first = s.play(3)
    local firstId = s.matchId()
    s.match.OnDeath(2, 1)
    s.settle()
    s.match.OnDeath(3, 1)
    s.settle()
    s.tick()
    t.isTrue(s.lobby.Get(firstId) == nil or s.lobby.Get(firstId).state ~= 'live', 'the first round never ended')
    t.isTrue(first.players[2].leftArena == true, 'premise: fighter 2 was sent home in the first round')

    local second = s.play(3)
    t.isTrue(s.matchId() ~= firstId, 'the fixture replayed the same match')
    t.isTrue(second.players[2].leftArena ~= true, 'Start did not clear the last round\'s trip home')
    local boards = s.tick()
    for _, src in ipairs({ 1, 2, 3 }) do
        t.equals(countFor(boards, src), 1, 'fighter ' .. src .. ' got no board in the round after going home')
    end
end)

t.test('and Start clears a stale trip home on a row it is handed, whatever put it there', function()
    -- The reset is the only thing standing between a leftover flag and a
    -- fighter who never sees the board: pinned on the row directly.
    local s = newServer()
    s.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash' })
    local id = s.lobby.All()[1].id
    for src = 2, 3 do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
    s.lobby.Get(id).players[2].leftArena = true
    for src = 1, 3 do s.fire('setReady', src, { ready = true }) end
    s.settle(4)
    local match = s.lobby.Get(id)
    t.equals(match.state, 'live', 'the round did not start')
    t.isTrue(match.players[2].leftArena ~= true, 'Start kept a trip home from before the round')
    t.equals(countFor(s.tick(), 2), 1, 'the fighter with the stale flag got no board')
end)

t.test('ONLOOKERS: every watcher who is not a fighter gets one board, the blank one', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    s.play(4)
    for _, src in ipairs(ONLOOKERS) do s.fire('spectateMatch', src, { matchId = s.matchId() }) end
    s.match.OnDeath(3, 1)
    s.settle()

    local boards = s.tick()
    for _, src in ipairs(ONLOOKERS) do
        t.equals(countFor(boards, src), 1, 'onlooker ' .. src .. ' did not get exactly one board')
        local board = (boards[src] or {})[1] or {}
        t.equals(board.kills, 0, 'an onlooker was sent a fighter\'s kills')
        t.equals(board.deaths, 0, 'an onlooker was sent a fighter\'s deaths')
        t.isNil(board.team, 'an onlooker was sent a side')
    end
end)

t.test('THE SKIP DOES NOT SHRINK THE BOARD: the fighter sent home is still a row, and still counted', function()
    -- Only who RECEIVES the board changed. `total` and the scoreboard are
    -- still built off the whole roster -- the results rank off that row.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    s.play(4)
    s.match.OnDeath(2, 1)
    s.settle()

    local board = (s.tick()[1] or {})[1] or {}
    t.equals(board.total, 4, 'the fighter sent home stopped being counted in the round')
    t.equals(board.remaining, 3, 'the fighter sent home is counted as still in')
    local listed = false
    for _, row in ipairs(board.scoreboard or {}) do
        if row.id == 2 then listed = true end
    end
    t.isTrue(listed, 'the fighter sent home vanished from the scoreboard everybody else sees')
end)

-- ======================================================================
-- EDGES
-- ======================================================================

t.test('EDGE: only `leftArena == true` is a trip home -- a truthy stand-in is still pushed', function()
    -- sendPlayerHome writes `true` and Start writes nil. Anything else on
    -- that field was not written by a trip home and must not cost a board.
    local s = newServer()
    local match = s.play(4)
    for _, value in ipairs({ 'yes', 1, false }) do
        match.players[3].leftArena = value
        t.equals(countFor(s.tick(), 3), 1, 'leftArena = ' .. tostring(value) .. ' was read as a trip home')
    end
    match.players[3].leftArena = nil
end)

t.test('and the boundary itself: `true` with no watch is skipped, `true` WITH a watch is not', function()
    local s = newServer()
    local match = s.play(4)
    match.players[3].leftArena = true
    t.equals(countFor(s.tick(), 3), 0, 'leftArena = true and not watching was still pushed')
    match.spectators[3] = true
    t.equals(countFor(s.tick(), 3), 1, 'leftArena = true while watching lost the board')
    match.spectators[3] = nil
    match.players[3].leftArena = nil
    t.equals(countFor(s.tick(), 3), 1, 'CONTROL: an ordinary fighter lost the board')
end)

t.test('EDGE: a round with no spectators table at all does not throw', function()
    -- ArenaLobby.Create always writes one; the push reads it through
    -- `or {}` in both places, so a round that somehow lost it is a round
    -- with nobody watching, not a sweep that raises every second.
    local s = newServer()
    local match = s.play(4)
    local kept = match.spectators
    match.spectators = nil
    local ok, boards = pcall(s.tick)
    match.spectators = kept

    t.isTrue(ok, 'the sweep threw on a round with no spectators table: ' .. tostring(boards))
    if ok then
        for _, src in ipairs({ 1, 2, 3, 4 }) do t.equals(countFor(boards, src), 1, 'missed fighter ' .. src) end
    end
end)

t.test('and with a fighter sent home in it, it skips them and nobody else', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(4)
    s.match.OnDeath(2, 1)
    s.settle()

    local kept = match.spectators
    match.spectators = nil
    local ok, boards = pcall(s.tick)
    match.spectators = kept

    t.isTrue(ok, 'the sweep threw on a round with no spectators table: ' .. tostring(boards))
    if ok then
        t.equals(countFor(boards, 2), 0, 'the fighter sent home was pushed a board')
        for _, src in ipairs({ 1, 3, 4 }) do t.equals(countFor(boards, src), 1, 'missed fighter ' .. src) end
    end
end)

t.test('EDGE: a two-fighter round with one sent home ends rather than pushing anything', function()
    -- The empty-roster end of the boundary: once nobody is left to fight,
    -- the sweep ends the round instead of pushing a board at all.
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(2)
    s.match.OnDeath(2, 1)
    s.settle()
    local _, total = s.tick()
    t.equals(total, 0, 'a decided round pushed a board instead of ending')
    t.isTrue(match.state ~= 'live', 'the decided round was not ended')
end)

-- ======================================================================
-- THE DIFFERENTIAL: THE OLD LOOP AGAINST THE REAL SWEEP
-- ======================================================================

--- The push as server/match.lua wrote it before this change: every row on
--- the roster with their own numbers, then every watcher who is not on the
--- roster with a blank board. Returns the boards it would send, in order,
--- as { target, kills, deaths, team }.
local function oldRecipients(Arena, lobby, match)
    local out = {}
    for _, player in ipairs(lobby.PlayerArray(match)) do
        out[#out + 1] = {
            target = player.src,
            kills = math.max(0, Arena.ToInt(player.kills) or 0),
            deaths = math.max(0, Arena.ToInt(player.deaths) or 0),
            team = player.team,
            row = player,
        }
    end
    for src in pairs(match.spectators or {}) do
        if not match.players[src] then
            out[#out + 1] = { target = src, kills = 0, deaths = 0, team = nil }
        end
    end
    return out
end

--- The one difference this change intends: a row on the roster that was
--- sent home and is not watching.
local function meantToSkip(match, entry)
    return entry.row ~= nil and entry.row.leftArena == true and not (match.spectators or {})[entry.target]
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for key, value in pairs(a) do
        if not deepEqual(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

--- Every field but the three that are the recipient's own.
local SHARED = { 'matchId', 'remaining', 'total', 'timeLeft', 'pot', 'scoreboard', 'livesSpent',
    'winCondition', 'scoreLimit', 'teamScores', 'departedScores' }

local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return ((state // 65536) % n) + 1
    end
end

--- A fighter's state, as the round can leave it. The last three put junk
--- where only `true` and nil are ever written.
local STATES = {
    'alive', 'respawning', 'eliminated_watching', 'sent_home', 'sent_home_watching',
    'stopped_watching', 'left_yes', 'left_one', 'watch_false',
}

local function apply(match, src, state, random)
    local row = match.players[src]
    local spectators = match.spectators
    spectators[src] = nil
    row.leftArena = nil
    row.alive, row.lives = true, 3
    if state == 'respawning' then
        row.alive, row.lives = false, 2
    elseif state ~= 'alive' then
        row.alive, row.lives = false, 0
        if state == 'eliminated_watching' then spectators[src] = true
        elseif state == 'sent_home' then row.leftArena = true
        elseif state == 'sent_home_watching' then row.leftArena = true; spectators[src] = true
        elseif state == 'left_yes' then row.leftArena = 'yes'
        elseif state == 'left_one' then row.leftArena = 1
        elseif state == 'watch_false' then row.leftArena = true; spectators[src] = false
        end
    end
    -- Numbers of every shape the row can hold, junk included: the push
    -- clamps them, and the clamp is part of what must not move.
    local shapes = { 0, 1, 2, 7, -3, '4', 'x' }
    row.kills = shapes[random(#shapes)]
    row.deaths = shapes[random(#shapes)]
end

t.test('DIFFERENTIAL: the old loop and the real sweep, 360 seeded rosters over every mode and win condition', function()
    local random = generator(424243)
    local setups = {}
    for _, mode in ipairs({ 'ffa', 'tdm', 'gungame' }) do
        for _, win in ipairs({ 'last_standing', 'most_kills', 'score_limit' }) do
            setups[#setups + 1] = { mode = mode, win = win }
        end
    end

    local failures, cases, skipped, pushed = {}, 0, 0, 0
    local seenState = {}
    for index, setup in ipairs(setups) do
        local s = newServer({ mutate = function(config)
            config.Match.lives = 3
            config.Match.spectateOnElimination = (index % 2 == 0)
        end })
        local match = s.play(8, setup.mode, setup.win)

        for _ = 1, 40 do
            cases = cases + 1
            -- Fighters 1 and 2 stay in, on opposite sides in a team mode,
            -- so no roster below decides the round and the tick pushes.
            apply(match, 1, 'alive', random)
            apply(match, 2, 'alive', random)
            for src = 3, 8 do
                local state = STATES[random(#STATES)]
                seenState[state] = true
                apply(match, src, state, random)
            end
            for _, src in ipairs(ONLOOKERS) do
                match.spectators[src] = (random(2) == 1) or nil
            end

            local reference = oldRecipients(s.Arena, s.lobby, match)
            t.isTrue(not s.match.IsDecided(match), 'a generated roster decides the round, so the tick would not push')
            local boards, total = s.tick()

            local expected = 0
            for _, entry in ipairs(reference) do
                local got = boards[entry.target] or {}
                if meantToSkip(match, entry) then
                    skipped = skipped + 1
                    if #got ~= 0 then
                        failures[#failures + 1] = ('%s/%s: %d was sent home and not watching, and was pushed %d')
                            :format(setup.mode, setup.win, entry.target, #got)
                    end
                else
                    expected = expected + 1
                    if #got ~= 1 then
                        failures[#failures + 1] = ('%s/%s: %d got %d boards, the old loop sent 1')
                            :format(setup.mode, setup.win, entry.target, #got)
                    else
                        local board = got[1]
                        if board.kills ~= entry.kills or board.deaths ~= entry.deaths or board.team ~= entry.team then
                            failures[#failures + 1] = ('%s/%s: %d got %s/%s/%s, the old loop sent %s/%s/%s')
                                :format(setup.mode, setup.win, entry.target, tostring(board.kills),
                                    tostring(board.deaths), tostring(board.team), tostring(entry.kills),
                                    tostring(entry.deaths), tostring(entry.team))
                        end
                    end
                end
            end
            if total ~= expected then
                failures[#failures + 1] = ('%s/%s: %d boards pushed, the old loop less the skips is %d')
                    :format(setup.mode, setup.win, total, expected)
            end
            pushed = pushed + total

            -- EVERY BOARD IN ONE TICK CARRIES THE SAME SHARED FIELDS -- the
            -- change moved who receives it, never what it says.
            local first
            for _, list in pairs(boards) do
                for _, board in ipairs(list) do
                    if not first then first = board end
                    for _, field in ipairs(SHARED) do
                        if not deepEqual(board[field], first[field]) then
                            failures[#failures + 1] = ('%s/%s: the shared field %s differs between recipients')
                                :format(setup.mode, setup.win, field)
                        end
                    end
                end
            end
            if first and first.total ~= #s.lobby.PlayerArray(match) then
                failures[#failures + 1] = ('%s/%s: total %s is not the whole roster')
                    :format(setup.mode, setup.win, tostring(first.total))
            end
        end
    end

    t.equals(cases, 360, 'the sweep did not run the cases it names')
    for _, state in ipairs(STATES) do t.isTrue(seenState[state], 'never generated: ' .. state) end
    t.isTrue(skipped > 0, 'the sweep never produced a fighter to skip')
    t.isTrue(pushed > cases * 2, 'the sweep pushed almost nothing, so it compared little')
    t.equals(#failures, 0, table.concat(failures, '\n'))
end)

os.exit(t.summary())
