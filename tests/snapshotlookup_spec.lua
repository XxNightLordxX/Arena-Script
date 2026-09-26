--[[
    crimson_arena/tests/snapshotlookup_spec.lua

    ONE FRAMEWORK READ PER PLAYER PER STATE PUSH.

    Every ArenaLobby.Broadcast -- each kill, join, ready, bet, start and end --
    builds a panel snapshot for every recipient, and server/lobby.lua's
    snapshotPlayer used to ask qbx_core for the SAME player six times to
    build one of them: once for the money line, then again inside
    ArenaPlayerName, ArenaBetting.Wallet, GetSideBet, MatchesBackedBy and
    MatchesWalkedOutOf -- seven for a player backing one lobby they are not
    in. Each is a cross-resource export that marshals the whole player
    object. Thirty-two fighters and one kill was 192 of them.

    It now reads the player ONCE and hands that read to each helper as an
    optional trailing argument. A helper handed nil reads the framework for
    itself, exactly as before, so every other caller -- and every player the
    framework has not loaded -- is answered the old way.

    THE FIELDS THIS FEEDS WERE BARELY GUARDED. Passing the ROSTER row
    (snapshotPlayer's other local called `player`) where the framework
    player belongs is an easy slip, and four of the five such slips passed
    every spec in the suite: no spec asserted a fighter's name, wallet,
    backing or walked-out list against the framework's record. So this file
    pins, through the real server files:

      * the count -- one export per recipient per Broadcast, one per
        BuildState, and each helper once;
      * every field the read feeds, for fighters, watchers, backers, walkers
        and the stranger handed a walker's seat, against the framework record;
      * the helpers' own contract: only nil sends them back to the framework;
      * and, above all, that every snapshot every recipient is sent is
        IDENTICAL to what the old code sent. A second server is built from
        the same files with the old code put back -- the exact old lines are
        kept below -- and the two are driven through the same seeded,
        randomised rounds side by side, every push and every BuildState
        compared field for field and in the order the wire would carry it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('snapshotlookup_spec')

-- ======================================================================
-- THE OLD CODE
--
-- Each pair is the current text and the exact text it replaced. The
-- reference server is loaded from the real files with every pair swapped
-- back, so it IS the old code -- not a model of it -- while every line this
-- change did not touch is shared with the real server.
--
-- IF THIS STOPS LOADING it is because one of the `new` texts below is no
-- longer in the file. That is on purpose: somebody has edited the lines
-- this spec compares against the old behaviour, and the pair must be
-- brought up to date by hand -- the old text stays exactly as it is, since
-- it is the behaviour being preserved. A file still holding the OLD text is
-- accepted as it stands, which is also what lets this spec run against the
-- code from before the change.
-- ======================================================================

local OLD_CODE = {
    {
        file = 'util.lua',
        new = 'function ArenaPlayerName(src, known)\n'
            .. '    local target = tonumber(src)\n'
            .. '    local player = known\n'
            .. '    if player == nil then player = ArenaGetPlayer(target) end\n',
        old = 'function ArenaPlayerName(src)\n'
            .. '    local target = tonumber(src)\n'
            .. '    local player = ArenaGetPlayer(target)\n',
    },
    {
        file = 'betting.lua',
        new = 'local function citizenIdOf(src, known)\n'
            .. '    local player = known\n'
            .. '    if player == nil then player = ArenaGetPlayer(src) end\n',
        old = 'local function citizenIdOf(src)\n'
            .. '    local player = ArenaGetPlayer(src)\n',
    },
    {
        file = 'betting.lua',
        new = 'function ArenaBetting.Wallet(src, known)\n'
            .. '    local player = known\n'
            .. '    if player == nil then player = ArenaGetPlayer(serverId(src)) end\n',
        old = 'function ArenaBetting.Wallet(src)\n'
            .. '    local player = ArenaGetPlayer(serverId(src))\n',
    },
    {
        file = 'betting.lua',
        new = 'function ArenaBetting.GetSideBet(matchId, src, known)\n',
        old = 'function ArenaBetting.GetSideBet(matchId, src)\n',
    },
    {
        file = 'betting.lua',
        new = 'function ArenaBetting.MatchesWalkedOutOf(src, known)\n',
        old = 'function ArenaBetting.MatchesWalkedOutOf(src)\n',
    },
    {
        file = 'betting.lua',
        new = 'function ArenaBetting.MatchesBackedBy(src, known)\n',
        old = 'function ArenaBetting.MatchesBackedBy(src)\n',
    },
    {
        file = 'betting.lua',
        new = '    local citizenid = citizenIdOf(id, known)\n'
            .. '    for _, bet in ipairs(sideBets[matchId] or {}) do\n'
            .. '        -- The one they CHOSE.',
        old = '    local citizenid = citizenIdOf(id)\n'
            .. '    for _, bet in ipairs(sideBets[matchId] or {}) do\n'
            .. '        -- The one they CHOSE.',
    },
    {
        file = 'betting.lua',
        new = '    local citizenid = citizenIdOf(id, known)\n'
            .. '    for matchId in pairs(walkedOutOf) do\n',
        old = '    local citizenid = citizenIdOf(id)\n'
            .. '    for matchId in pairs(walkedOutOf) do\n',
    },
    {
        file = 'betting.lua',
        new = '    local citizenid = citizenIdOf(id, known)\n'
            .. '\n'
            .. '    for matchId, bets in pairs(sideBets) do\n',
        old = '    local citizenid = citizenIdOf(id)\n'
            .. '\n'
            .. '    for matchId, bets in pairs(sideBets) do\n',
    },
    {
        file = 'lobby.lua',
        new = '    local qbx = ArenaGetPlayer(src)\n'
            .. '    local backing = ArenaBetting.MatchesBackedBy(src, qbx)\n',
        old = '',
    },
    {
        file = 'lobby.lua',
        new = '        if #backing == 1 then betOn = backing[1] end\n',
        old = '        local backed = ArenaBetting.MatchesBackedBy(src)\n'
            .. '        if #backed == 1 then betOn = backed[1] end\n',
    },
    {
        file = 'lobby.lua',
        new = '    local money = 0\n'
            .. '    local data = qbx and qbx.PlayerData\n',
        old = '    local money = 0\n'
            .. '    local qbx = ArenaGetPlayer(src)\n'
            .. '    local data = qbx and qbx.PlayerData\n',
    },
    {
        file = 'lobby.lua',
        new = '        name = ArenaPlayerName(src, qbx),\n',
        old = '        name = ArenaPlayerName(src),\n',
    },
    {
        file = 'lobby.lua',
        new = '        wallet = ArenaBetting.Wallet(src, qbx),\n',
        old = '        wallet = ArenaBetting.Wallet(src),\n',
    },
    {
        file = 'lobby.lua',
        new = '        bet = (betOn and ArenaBetting.GetSideBet(betOn, src, qbx)) or false,\n',
        old = '        bet = (betOn and ArenaBetting.GetSideBet(betOn, src)) or false,\n',
    },
    {
        file = 'lobby.lua',
        new = '        backing = backing,\n',
        old = '        backing = ArenaBetting.MatchesBackedBy(src),\n',
    },
    {
        file = 'lobby.lua',
        new = '        walkedOut = ArenaBetting.MatchesWalkedOutOf(src, qbx),\n',
        old = '        walkedOut = ArenaBetting.MatchesWalkedOutOf(src),\n',
    },
}

--- How many times `needle` occurs in `text`, as plain text.
local function occurrences(text, needle)
    local count, from = 0, 1
    while true do
        local at, stop = text:find(needle, from, true)
        if not at then return count end
        count = count + 1
        from = stop + 1
    end
end

--- `text` with every plain occurrence of `needle` replaced.
local function replaced(text, needle, with)
    local out, from = {}, 1
    while true do
        local at, stop = text:find(needle, from, true)
        if not at then break end
        out[#out + 1] = text:sub(from, at - 1)
        out[#out + 1] = with
        from = stop + 1
    end
    out[#out + 1] = text:sub(from)
    return table.concat(out)
end

--- One server file as it is, or with the old code put back.
--- @param file string
--- @param variant string -- 'new' | 'old'
--- @return string text
local function sourceOf(file, variant)
    local handle = assert(io.open('../Crimson-Arena/server/' .. file, 'r'))
    local text = handle:read('a')
    handle:close()
    if variant ~= 'old' then return text end

    for _, pair in ipairs(OLD_CODE) do
        if pair.file == file then
            local want = pair.times or 1
            local found = occurrences(text, pair.new)
            if found == want then
                text = replaced(text, pair.new, pair.old)
            elseif found == 0 and (pair.old == '' or occurrences(text, pair.old) == want) then
                -- Already the old code: the file predates the change.
            else
                error(('THE OLD CODE CANNOT BE PUT BACK: server/%s holds %d copies of %q where '
                    .. '%d were expected. Bring OLD_CODE in tests/snapshotlookup_spec.lua up to date.')
                    :format(file, found, pair.new, want), 0)
            end
        end
    end
    return text
end

-- ======================================================================
-- SEEDED CHANCE, AND VALUES AS TEXT
-- ======================================================================

--- @param seed integer
--- @return fun(n: integer?): integer -- 1..n, or the raw state with no n
local function newRng(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function(n)
        state = (state * 48271) % 2147483647
        if not n then return state end
        return (state % n) + 1
    end
end

--- A value as text, walking tables in the order `pairs` walks them -- the
--- order the msgpack encoder puts a map on the wire in -- so two payloads
--- whose texts match would have gone out as the same bytes. Integer and
--- float are told apart, as msgpack tells them apart.
--- @param value any
--- @param memo table? -- [table] = text, for blocks shared between payloads
--- @return string
local function wire(value, memo, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == 'number' then
        if value ~= value then return 'nan' end
        return (math.type(value) == 'integer' and 'i' or 'f') .. tostring(value)
    end
    if kind == 'string' then return ('%q'):format(value) end
    if kind ~= 'table' then return kind .. ':' .. tostring(value) end
    if memo and memo[value] then return memo[value] end
    if depth > 12 then return '<deep>' end

    local parts = {}
    for key, item in pairs(value) do
        parts[#parts + 1] = wire(key, nil, depth + 1) .. '=' .. wire(item, memo, depth + 1)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

--- The same, with keys sorted: equal content, whatever the order.
local function canon(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == 'number' then
        if value ~= value then return 'nan' end
        return (math.type(value) == 'integer' and 'i' or 'f') .. tostring(value)
    end
    if kind == 'string' then return ('%q'):format(value) end
    if kind ~= 'table' then return kind .. ':' .. tostring(value) end
    if depth > 12 then return '<deep>' end
    local parts = {}
    for key, item in pairs(value) do
        parts[#parts + 1] = canon(key, depth + 1) .. '=' .. canon(item, depth + 1)
    end
    table.sort(parts)
    return '{' .. table.concat(parts, ',') .. '}'
end

-- ======================================================================
-- A SERVER, BUILT FROM THE REAL FILES
-- ======================================================================

--- The framework records for a world, copied so each server owns its own.
local function copyRecords(records)
    local out = {}
    for src, record in pairs(records) do
        out[src] = {
            citizenid = record.citizenid,
            name = record.name,
            firstname = record.firstname,
            lastname = record.lastname,
            money = { cash = record.money.cash, bank = record.money.bank },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    return out
end

--- One whole arena server.
---
--- @param world table -- { records, handles, mutate, seed }
--- @param variant string -- 'new' | 'old'
--- @return table server
local function newServer(world, variant)
    local records = copyRecords(world.records)
    local qbx = Sandbox.newQbxCore(records)
    local threads = Sandbox.newThreadRunner()
    local sent, console, netEvents, handlers = {}, {}, {}, {}
    local clock = 0
    local server = { now = 1800000000, reads = 0, throwing = {}, variant = variant }

    -- EVERY FRAMEWORK READ, COUNTED AT THE EXPORT. server/util.lua's
    -- ArenaGetPlayer is the only caller of it in the resource, so this is
    -- the whole of what a state push costs the framework.
    local realGet = qbx.exports.qbx_core.GetPlayer
    qbx.exports.qbx_core.GetPlayer = function(self, id)
        server.reads = server.reads + 1
        if server.throwing[id] then error('qbx_core fell over reading ' .. tostring(id)) end
        return realGet(self, id)
    end

    -- ITS OWN CLOCK AND ITS OWN DICE, so two servers driven side by side
    -- see the same time and draw the same numbers whatever the other one
    -- has done.
    local dice = newRng(world.seed or 1)
    local ownMath = setmetatable({
        random = function(m, n)
            if m == nil then return (dice() % 1000000) / 1000000 end
            if n == nil then m, n = 1, m end
            return m + (dice() % (n - m + 1))
        end,
        randomseed = function() end,
    }, { __index = math })
    local ownOs = setmetatable({
        time = function(when)
            if when ~= nil then return os.time(when) end
            return server.now
        end,
        date = function(format, when) return os.date(format, when or server.now) end,
    }, { __index = os })

    -- The config block is one cached table handed to every push, and it is
    -- most of each payload: written out once per table rather than per push.
    local configMemo = setmetatable({}, { __mode = 'k' })
    function server.text(payload)
        if type(payload) == 'table' and type(payload.config) == 'table' then
            local config = payload.config
            if not configMemo[config] then configMemo[config] = wire(config) end
            return wire(payload, { [config] = configMemo[config] })
        end
        return wire(payload)
    end

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        math = ownMath,
        os = ownOs,
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = tostring(line) end,
        TriggerClientEvent = function(event, target, payload)
            -- Written down AS SENT: a table sent now and edited later must
            -- be compared as it was when it left.
            sent[#sent + 1] = { event = event, target = target, text = server.text(payload), payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        -- THE CONNECTION'S NAME, deliberately NOT the character's: a name
        -- read off the wrong object then shows up as the wrong words.
        GetPlayerName = function(src) return world.handles[src] or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0, y = 2565.1, z = 46.7 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Refresh = function() return true end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
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

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.autoStartWhenAllReady = false
    env.Config.Betting.enabled = true
    env.Config.Betting.spectatorBets.enabled = true
    env.Config.Betting.fighterBets.enabled = true
    env.Config.Betting.accounts = { 'cash', 'bank' }
    if world.mutate then world.mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        local path = '../Crimson-Arena/server/' .. file .. '.lua'
        local chunk = assert(load(sourceOf(file .. '.lua', variant), '@' .. path, 't', env))
        chunk()
    end

    server.env = env
    server.qbx = qbx
    server.config = env.Config
    server.records = records
    server.lobby = env.ArenaLobby
    server.match = env.ArenaMatch
    server.betting = env.ArenaBetting
    server.sent = sent
    server.console = console

    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.dropped(src)
        env.source = src
        for _, fn in ipairs(handlers.playerDropped or {}) do fn('dropped') end
    end

    --- Framework reads made while `fn` runs.
    function server.readsDuring(fn, ...)
        local before = server.reads
        local results = table.pack(fn(...))
        return server.reads - before, table.unpack(results, 1, results.n)
    end

    --- Every state push sent while `fn` runs, as { target = text }.
    function server.pushesDuring(fn, ...)
        local mark = #sent
        fn(...)
        local out = {}
        for index = mark + 1, #sent do
            if sent[index].event == 'crimson_arena:client:state' then out[#out + 1] = sent[index] end
        end
        return out
    end

    return server
end

-- ======================================================================
-- A WORLD: WHO IS ON THE SERVER
-- ======================================================================

--- A framework record whose three names are all different, so the one the
--- panel shows says which object it was read from.
local function record(src, cash, bank)
    return {
        citizenid = ('CID%03d'):format(src),
        name = ('Data Name %d'):format(src),
        firstname = ('First%d'):format(src),
        lastname = ('Last%d'):format(src),
        money = { cash = cash, bank = bank },
    }
end

--- `count` players, each with cash and bank that differ from everybody
--- else's, connected under a handle that is not their character's name.
local function plainWorld(count, mutate)
    local world = { records = {}, handles = {}, mutate = mutate, seed = 7 }
    for src = 1, count do
        world.records[src] = record(src, 100000 + src * 1111, 200000 + src * 777)
        world.handles[src] = ('Handle%d'):format(src)
    end
    return world
end

-- ======================================================================
-- A ROOM WITH ONE OF EVERYBODY IN IT
-- ======================================================================

--- One of every kind of recipient the panel is pushed to:
---
---   1       hosts an FFA lobby with a 500 fee
---   2       fights in it, paid from bank, and has backed themselves
---   3, 4    a live team round: 3 hosts on crimson, 4 was killed out of it
---   5       THE STRANGER: seat 5 fought in the team round and walked out, and
---           the seat has since been handed to a different character, who
---           now fights in the FFA lobby
---   6       watching the live round, holding a bet on it
---   7       backing the FFA lobby from outside it -- one backing, which is
---           the seven-read case
---   8       backing BOTH rounds from outside them
---   9       fights on ash in the live team round
---   10      THE WALKER, back: the character who left seat 5, reconnected on
---           seat 10 and now fighting in the FFA lobby
---   11      panel open, in nothing
---   12      panel open, and the framework has never loaded them
--- @param variant string -- 'new' | 'old'
--- @param mutate function?
--- @return table server, table ids -- { ffa, team }
local function populated(variant, mutate)
    local world = plainWorld(12, mutate)
    local s = newServer(world, variant)
    local lobby, match = s.lobby, s.match
    local function must(what, ok, why)
        if not ok then error(('the room could not be built -- %s: %s'):format(what, tostring(why)), 2) end
        return ok
    end

    local ffa = must('create ffa', lobby.Create(1, 'trailerpark', 'ffa', 500, nil, nil, 'cash'))
    must('join 2', lobby.Join(2, ffa, nil, 'bank'))

    local team = must('create team', lobby.Create(3, 'skydome', 'tdm', 0, nil, nil, nil))
    must('team 3', lobby.SetTeam(3, 'crimson'))
    must('join 4', lobby.Join(4, team, 'ash', nil))
    must('join 5', lobby.Join(5, team, 'crimson', nil))
    must('join 9', lobby.Join(9, team, 'ash', nil))

    must('bet 2', s.betting.PlaceSpectatorBet(2, ffa, 2, 1500, 'cash'))
    must('bet 7', s.betting.PlaceSpectatorBet(7, ffa, 1, 1200, 'bank'))
    must('bet 8 on ffa', s.betting.PlaceSpectatorBet(8, ffa, 2, 900, 'cash'))
    must('bet 8 on team', s.betting.PlaceSpectatorBet(8, team, 'crimson', 800, 'bank'))
    must('bet 6', s.betting.PlaceSpectatorBet(6, team, 'ash', 700, 'cash'))

    for src in pairs(lobby.Get(team).players) do lobby.SetReady(src, true) end
    must('begin', match.Begin(team, 3))
    s.step(2)
    must('live', lobby.Get(team).state == 'live', lobby.Get(team).state)

    must('spectate 6', lobby.AddSpectator(6, team))
    match.OnDeath(4, 3)
    s.step(1)

    -- 5 walks out of the live round...
    s.fire('leaveMatch', 5)
    -- ...and the seat is handed to a different character.
    s.records[5] = record(5, 5555, 6666)
    s.records[5].citizenid = 'CID-STRANGER'
    world.handles[5] = 'Handle5b'
    -- The walker's character comes back on seat 10.
    s.records[10].citizenid = 'CID005'

    must('the stranger joins', lobby.Join(5, ffa, nil, 'cash'))
    must('the walker joins', lobby.Join(10, ffa, nil, 'cash'))

    for _, src in ipairs({ 7, 8, 11, 12 }) do lobby.MarkPanelOpen(src) end
    s.records[12] = nil

    return s, { ffa = ffa, team = team }
end

--- The snapshot one player is sent, and what it cost the framework.
local function snapshotOf(s, src)
    local reads, state = s.readsDuring(s.lobby.BuildState, src)
    return state.player, reads
end

--- An array as a sorted, comma-joined string, so two lists holding the same
--- ids compare equal whatever order `pairs` produced them in.
local function setOf(list)
    local copy = {}
    for index, value in ipairs(list or {}) do copy[index] = tostring(value) end
    table.sort(copy)
    return table.concat(copy, ',')
end

-- ======================================================================
-- THE COST
-- ======================================================================

t.test('ONE framework read per recipient per state push, where the old code made six or seven', function()
    local s = populated('new')
    local old = populated('old')

    -- 12 is the one recipient the framework has never loaded; see below.
    s.records[12] = record(12, 1212, 2121)
    old.records[12] = record(12, 1212, 2121)

    local pushes
    local reads = s.readsDuring(function() pushes = s.pushesDuring(s.lobby.Broadcast) end)
    local oldPushes
    local oldReads = old.readsDuring(function() oldPushes = old.pushesDuring(old.lobby.Broadcast) end)

    t.equals(#pushes, 12, 'the room should hold twelve recipients')
    t.equals(#oldPushes, 12)
    t.equals(reads, #pushes, ('a Broadcast to %d recipients made %d framework reads'):format(#pushes, reads))

    -- THE SAVING IS REAL: the reference is the old code, and it paid six a
    -- head plus one for the lobby backer outside every round.
    t.equals(oldReads, 6 * 12 + 1, 'the old code no longer costs what this file says it did')
end)

t.test('and ONE per BuildState, for every kind of recipient -- fighter, watcher, backer, walker, stranger', function()
    local s = populated('new')
    local old = populated('old')
    for src = 1, 11 do
        local _, reads = snapshotOf(s, src)
        t.equals(reads, 1, ('player %d cost %d framework reads to snapshot'):format(src, reads))
        local _, oldReads = snapshotOf(old, src)
        t.equals(oldReads, src == 7 and 7 or 6,
            ('the old code read the framework %d times for player %d'):format(oldReads, src))
    end
end)

t.test('a player backing one lobby from outside it costs one read, not seven', function()
    -- THE SEVENTH READ: with no round of their own to show a bet on, the old
    -- code asked MatchesBackedBy once to find the backed round and again for
    -- the `backing` field, each reaching into the framework.
    local s = populated('new')
    local player, reads = snapshotOf(s, 7)
    t.equals(reads, 1, 'the lobby backer still costs ' .. reads .. ' reads')
    t.isTrue(player.bet ~= false, 'and the bet the reads were for is no longer shown')
end)

t.test('each helper is asked once per snapshot: the framework read, and MatchesBackedBy for both its uses', function()
    local s = populated('new')
    local calls = {}
    local function counted(owner, name, label)
        local real = owner[name]
        owner[name] = function(...)
            calls[label] = (calls[label] or 0) + 1
            return real(...)
        end
    end
    counted(s.env, 'ArenaGetPlayer', 'ArenaGetPlayer')
    counted(s.betting, 'MatchesBackedBy', 'MatchesBackedBy')
    counted(s.betting, 'MatchesWalkedOutOf', 'MatchesWalkedOutOf')
    counted(s.betting, 'Wallet', 'Wallet')
    counted(s.env, 'ArenaPlayerName', 'ArenaPlayerName')

    for src = 1, 11 do
        calls = {}
        s.lobby.BuildState(src)
        for _, label in ipairs({ 'ArenaGetPlayer', 'MatchesBackedBy', 'MatchesWalkedOutOf', 'Wallet', 'ArenaPlayerName' }) do
            t.equals(calls[label] or 0, 1, ('player %d: %s was called %d times for one snapshot')
                :format(src, label, calls[label] or 0))
        end
    end
end)

t.test('a player the framework has NOT loaded still costs no more than before, and every helper asks for itself', function()
    -- THE NIL FALLBACK, and why it is there. The single read comes back nil
    -- for a player who is not loaded, has dropped mid-push, or whose read
    -- raised -- and each helper then reads the framework for itself, as it
    -- always did, rather than answering from nothing.
    local s = populated('new')
    local old = populated('old')
    local player, reads = snapshotOf(s, 12)
    local _, oldReads = snapshotOf(old, 12)
    t.equals(oldReads, 6)
    t.equals(reads, 5, 'the unloaded player: one read, then name, wallet, backing and walked-out each ask')
    t.equals(player.name, 'Handle12', 'an unloaded player is not named by their connection')
end)

-- ======================================================================
-- WHAT THE READ FEEDS, AGAINST THE FRAMEWORK'S OWN RECORD
-- ======================================================================

t.test('a FIGHTER is named, paid and credited off the framework record, not off their roster row', function()
    -- THE SLIP THIS GUARDS. snapshotPlayer holds two players: `player`, the
    -- roster row, and `qbx`, the framework's. Hand the row to a helper and
    -- nothing raises: the name falls back to the connection's, the wallet to
    -- zero, and the bet, the backing and the walked-out list to "nobody's".
    -- Fighter 2 is set up so every one of those shows.
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        local record2 = s.records[2]
        local player = snapshotOf(s, 2)

        t.equals(player.name, 'First2 Last2', variant .. ': the fighter is not named by their character')
        t.equals(player.money, record2.money.cash, variant .. ': the money line is not the framework balance')
        t.equals(player.wallet.cash, record2.money.cash, variant .. ': wallet cash')
        t.equals(player.wallet.bank, record2.money.bank, variant .. ': wallet bank')
        t.isTrue(record2.money.cash > 0 and record2.money.bank > 0, 'a zero wallet would prove nothing')
        t.isTrue(type(player.bet) == 'table', variant .. ': the fighter\'s own bet is not shown')
        t.equals(player.bet.amount, 1500, variant .. ': bet amount')
        t.equals(player.bet.kind, 'fighter', variant .. ': bet kind')
        t.equals(tostring(player.bet.pick), '2', variant .. ': bet pick')
        t.equals(player.bet.account, 'cash', variant .. ': bet account')
        t.equals(setOf(player.backing), ids.ffa, variant .. ': backing')
        t.equals(#player.walkedOut, 0, variant .. ': walkedOut')
        t.equals(player.matchId, ids.ffa)
    end
end)

t.test('THE STRANGER on a walker\'s seat, fighting, is not told they walked out', function()
    -- Seat 5 walked out of the live team round; the seat now belongs to a
    -- different character, who has sat down in the FFA lobby. The walked-out
    -- list is answered for the CHARACTER on the seat, which only the
    -- framework record can name -- the roster row cannot.
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        local player = snapshotOf(s, 5)
        t.equals(player.matchId, ids.ffa, variant .. ': the stranger is not seated in the FFA lobby')
        t.equals(#player.walkedOut, 0, variant .. ': a stranger was blamed for the walker\'s walk-out')
        t.equals(player.name, 'First5 Last5', variant .. ': the stranger is named wrongly')
        t.equals(player.wallet.cash, s.records[5].money.cash, variant .. ': the stranger\'s cash')
        t.equals(player.wallet.bank, 6666, variant .. ': the stranger\'s bank')
    end
end)

t.test('THE WALKER back on a new seat, fighting, IS told they walked out', function()
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        local player = snapshotOf(s, 10)
        t.equals(player.matchId, ids.ffa, variant .. ': the walker is not seated in the FFA lobby')
        t.equals(setOf(player.walkedOut), ids.team,
            variant .. ': the walker\'s character, on a new seat, is not told which round they left')
    end
end)

t.test('a WATCHER is shown the bet on the round they watch; a backer of one lobby the bet on that lobby', function()
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        local watcher = snapshotOf(s, 6)
        t.equals(watcher.spectating, ids.team, variant .. ': 6 is not watching')
        t.isTrue(type(watcher.bet) == 'table', variant .. ': the watcher\'s bet is not shown')
        t.equals(watcher.bet.amount, 700)
        t.equals(tostring(watcher.bet.pick), 'ash')
        t.equals(setOf(watcher.backing), ids.team)

        local backer = snapshotOf(s, 7)
        t.equals(backer.matchId, false)
        t.equals(backer.spectating, false)
        t.isTrue(type(backer.bet) == 'table', variant .. ': a lobby backer is not shown their bet')
        t.equals(backer.bet.amount, 1200)
        t.equals(backer.bet.account, 'bank')
        t.equals(setOf(backer.backing), ids.ffa)
    end
end)

t.test('money on TWO rounds shows no single bet, and both backings', function()
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        local player = snapshotOf(s, 8)
        t.equals(player.bet, false, variant .. ': a player backing two rounds was shown one of the bets')
        local both = { ids.ffa, ids.team }
        t.equals(setOf(player.backing), setOf(both), variant .. ': backing')
    end
end)

t.test('a watcher who ALSO backs another lobby is shown the bet on the round they watch', function()
    -- The order of the two answers, which the change moved: the watched
    -- round decides first, and a single backing elsewhere must not take over.
    for _, variant in ipairs({ 'new', 'old' }) do
        local s, ids = populated(variant)
        t.isTrue(s.betting.PlaceSpectatorBet(6, ids.ffa, 1, 300, 'cash') == true,
            variant .. ': the watcher could not back the FFA lobby as well')
        local player = snapshotOf(s, 6)
        t.equals(player.spectating, ids.team)
        t.isTrue(type(player.bet) == 'table' and player.bet.amount == 700,
            variant .. ': the watcher was shown the wrong round\'s bet')
        t.equals(setOf(player.backing), setOf({ ids.ffa, ids.team }))
    end
end)

t.test('an UNLOADED player is named by their connection and shown nothing of anybody else\'s', function()
    for _, variant in ipairs({ 'new', 'old' }) do
        local s = populated(variant)
        local player = snapshotOf(s, 12)
        t.equals(player.name, 'Handle12', variant)
        t.equals(player.money, 0, variant)
        t.equals(player.wallet.cash, 0, variant)
        t.equals(player.wallet.bank, 0, variant)
        t.equals(player.bet, false, variant)
        t.equals(#player.backing, 0, variant)
        t.equals(#player.walkedOut, 0, variant)
    end
end)

t.test('the money line follows Config.Betting.account, and the wallet follows the account list', function()
    local mutate = function(config)
        config.Betting.account = 'bank'
        config.Betting.accounts = { 'bank' }
    end
    for _, variant in ipairs({ 'new', 'old' }) do
        local s = newServer(plainWorld(3, mutate), variant)
        local id = s.lobby.Create(1, 'trailerpark', 'ffa', 0, nil, nil, nil)
        t.isNotNil(id, variant .. ': the lobby could not be created')
        t.isTrue(s.lobby.Join(2, id, nil, nil), variant .. ': 2 could not join')
        for _, src in ipairs({ 1, 2, 3 }) do
            local player = snapshotOf(s, src)
            t.equals(player.money, s.records[src].money.bank, variant .. ': money is not the bank balance')
            t.equals(player.wallet.bank, s.records[src].money.bank, variant)
            t.isNil(player.wallet.cash, variant .. ': an account the operator did not list is in the wallet')
        end
    end
end)

-- ======================================================================
-- THE HELPERS' OWN CONTRACT
-- ======================================================================

t.test('a helper handed the framework player uses it and does not read again; only nil sends it back', function()
    -- `local player = known; if player == nil then player = <lookup> end`,
    -- and NOT `known or <lookup>`: the two agree today only because the
    -- framework read never answers false. This pins the written form -- a
    -- pre-read is taken as given whatever it is, and the framework is asked
    -- only when there was none.
    local s, ids = populated('new')
    local standIn = {
        PlayerData = {
            citizenid = 'CID002',
            name = 'Stand In',
            charinfo = { firstname = 'Pre', lastname = 'Read' },
            money = { cash = 7, bank = 8 },
        },
    }
    local reads, name = s.readsDuring(s.env.ArenaPlayerName, 2, standIn)
    t.equals(name, 'Pre Read', 'ArenaPlayerName did not use the player it was handed')
    t.equals(reads, 0, 'ArenaPlayerName read the framework again')

    local wallet
    reads, wallet = s.readsDuring(s.betting.Wallet, 2, standIn)
    t.equals(canon(wallet), canon({ cash = 7, bank = 8 }), 'Wallet did not use the player it was handed')
    t.equals(reads, 0, 'Wallet read the framework again')

    local bet
    reads, bet = s.readsDuring(s.betting.GetSideBet, ids.ffa, 2, standIn)
    t.isTrue(bet ~= nil and bet.amount == 1500, 'GetSideBet did not find the bet by the handed player\'s character')
    t.equals(reads, 0, 'GetSideBet read the framework again')

    local backed
    reads, backed = s.readsDuring(s.betting.MatchesBackedBy, 2, standIn)
    t.equals(setOf(backed), ids.ffa, 'MatchesBackedBy did not use the handed player')
    t.equals(reads, 0, 'MatchesBackedBy read the framework again')

    local walked
    local walker = { PlayerData = { citizenid = 'CID005' } }
    reads, walked = s.readsDuring(s.betting.MatchesWalkedOutOf, 10, walker)
    t.equals(setOf(walked), ids.team, 'MatchesWalkedOutOf did not use the handed player')
    t.equals(reads, 0, 'MatchesWalkedOutOf read the framework again')

    -- A DIFFERENT character handed in is believed: the seat's bet is not
    -- theirs, so it is not found. That is what proves the argument is used
    -- rather than merely tolerated.
    local other = { PlayerData = { citizenid = 'SOMEBODY-ELSE', money = { cash = 1, bank = 2 } } }
    t.isNil(s.betting.GetSideBet(ids.ffa, 2, other), 'a bet was found for a character that did not place it')
    t.equals(#s.betting.MatchesBackedBy(2, other), 0)

    -- FALSE IS A PRE-READ TOO, meaning nobody. It must not send the helper
    -- back to the framework the way `known or <lookup>` would.
    reads, name = s.readsDuring(s.env.ArenaPlayerName, 2, false)
    t.equals(reads, 0, 'handed false, ArenaPlayerName went back to the framework')
    t.equals(name, 'Handle2', 'handed false, the name did not fall to the connection')
    reads, wallet = s.readsDuring(s.betting.Wallet, 2, false)
    t.equals(reads, 0, 'handed false, Wallet went back to the framework')
    t.equals(canon(wallet), canon({ cash = 0, bank = 0 }))
    reads = s.readsDuring(s.betting.GetSideBet, ids.ffa, 2, false)
    t.equals(reads, 0, 'handed false, GetSideBet went back to the framework')
    reads = s.readsDuring(s.betting.MatchesBackedBy, 2, false)
    t.equals(reads, 0, 'handed false, MatchesBackedBy went back to the framework')
    reads = s.readsDuring(s.betting.MatchesWalkedOutOf, 2, false)
    t.equals(reads, 0, 'handed false, MatchesWalkedOutOf went back to the framework')

    -- AND NIL, OR NOTHING AT ALL, IS THE OLD CALL: one read, the framework's answer.
    for _, handed in ipairs({ { nil }, {} }) do
        reads, name = s.readsDuring(s.env.ArenaPlayerName, 2, table.unpack(handed))
        t.equals(reads, 1)
        t.equals(name, 'First2 Last2')
        reads, wallet = s.readsDuring(s.betting.Wallet, 2, table.unpack(handed))
        t.equals(reads, 1)
        t.equals(wallet.cash, s.records[2].money.cash)
    end
    reads, bet = s.readsDuring(s.betting.GetSideBet, ids.ffa, 2, nil)
    t.equals(reads, 1)
    t.isTrue(bet ~= nil and bet.amount == 1500)
    reads, backed = s.readsDuring(s.betting.MatchesBackedBy, 2, nil)
    t.equals(reads, 1)
    t.equals(setOf(backed), ids.ffa)
    reads, walked = s.readsDuring(s.betting.MatchesWalkedOutOf, 10, nil)
    t.equals(reads, 1)
    t.equals(setOf(walked), ids.team)
end)

t.test('REFERENCE.md shows each changed helper with the argument list the file defines', function()
    -- checklist_spec reads only the NAME off each row, so a signature can go
    -- stale there with the suite green. These are the five that gained an
    -- argument with this change.
    local handle = assert(io.open('../Crimson-Arena/REFERENCE.md', 'r'))
    local reference = handle:read('a')
    handle:close()
    local wanted = {
        { file = 'util.lua', name = 'ArenaPlayerName' },
        { file = 'betting.lua', name = 'ArenaBetting.Wallet' },
        { file = 'betting.lua', name = 'ArenaBetting.GetSideBet' },
        { file = 'betting.lua', name = 'ArenaBetting.MatchesWalkedOutOf' },
        { file = 'betting.lua', name = 'ArenaBetting.MatchesBackedBy' },
    }
    for _, fn in ipairs(wanted) do
        local text = sourceOf(fn.file, 'new')
        local escaped = fn.name:gsub('%.', '%%.')
        local defined = text:match('\nfunction ' .. escaped .. '(%b())')
        t.isNotNil(defined, fn.name .. ' is not defined in ' .. fn.file)
        local row = reference:match('\n| `' .. escaped .. '(%b())` |')
        t.isNotNil(row, fn.name .. ' has no row in REFERENCE.md')
        t.equals(row, defined, fn.name .. ': REFERENCE.md shows a different argument list from the file')
    end
end)

-- ======================================================================
-- OLD AGAINST NEW
-- ======================================================================

--- The texts of every state push sent since `mark`, as one comparable list.
local function sentSince(s, mark)
    local out = {}
    for index = mark + 1, #s.sent do
        local message = s.sent[index]
        out[#out + 1] = message.event .. ' -> ' .. wire(message.target) .. ' :: ' .. message.text
    end
    return out
end

--- One BuildState as text, or the error it raised.
local function builtText(s, src)
    local ok, state = pcall(s.lobby.BuildState, src)
    if not ok then return 'RAISED ' .. (tostring(state):gsub('^[^:]*:%d+: ', '')) end
    return s.text(state), state
end

--- Every kind of source a snapshot can be asked for: every seat, plus
--- sources no real caller passes -- strings, halves, floats that are whole,
--- nothing, and nonsense.
local ODD_SOURCES = { 0, -1, 1.0, 2.0, 2.5, 3.5, 10.5, '2', ' 3', '2.5', 'abc', 99, math.huge }

t.test('DIFFERENTIAL: in a room with one of everybody, every snapshot for every source is identical to the old code\'s', function()
    local s = populated('new')
    local old = populated('old')
    local sources = {}
    for src = 1, 13 do sources[#sources + 1] = src end
    for _, src in ipairs(ODD_SOURCES) do sources[#sources + 1] = src end
    sources[#sources + 1] = 0 / 0
    sources[#sources + 1] = {}
    sources[#sources + 1] = true

    local compared = 0
    for _, src in ipairs(sources) do
        local newText, oldText = builtText(s, src), builtText(old, src)
        compared = compared + 1
        t.equals(newText, oldText, ('BuildState(%s) differs from the old code'):format(canon(src)))
    end
    local ok = pcall(s.lobby.BuildState, nil)
    local okOld = pcall(old.lobby.BuildState, nil)
    t.equals(ok, okOld, 'BuildState(nil) raised in one and not the other')
    t.isTrue(compared >= 29)

    local newPushes = s.pushesDuring(s.lobby.Broadcast)
    local oldPushes = old.pushesDuring(old.lobby.Broadcast)
    t.equals(#newPushes, #oldPushes)
    for index = 1, #oldPushes do
        t.equals(newPushes[index].target, oldPushes[index].target, 'the recipients went out in another order')
        t.equals(newPushes[index].text, oldPushes[index].text,
            ('the push to %s differs from the old code\'s'):format(tostring(oldPushes[index].target)))
    end
end)

--- A random world: who is on the server, with what names and money, and
--- how the operator set betting up.
local function randomWorld(seed)
    local rng = newRng(seed)
    local count = 8 + rng(6)
    local world = { records = {}, handles = {}, seed = seed, count = count }
    for src = 1, count do
        local r = record(src, (rng(5) == 1) and 0 or rng(300000), (rng(5) == 1) and 0 or rng(300000))
        local shape = rng(6)
        if shape == 1 then
            r.firstname, r.lastname = nil, nil
        elseif shape == 2 then
            r.lastname = nil
        elseif shape == 3 then
            r.firstname, r.lastname, r.name = nil, nil, nil
        end
        world.records[src] = r
        world.handles[src] = ('Handle%d'):format(src)
    end
    local betting = rng(6) ~= 1
    local spectators = rng(4) ~= 1
    local fighters = rng(3) ~= 1
    local accounts = ({ { 'cash', 'bank' }, { 'bank', 'cash' }, { 'cash' }, { 'bank' }, 'junk' })[rng(5)]
    local account = rng(3) == 1 and 'bank' or 'cash'
    local countdown = ({ 0, 0, 3 })[rng(3)]
    local lives = ({ 1, 1, 2 })[rng(3)]
    world.mutate = function(config)
        config.Betting.enabled = betting
        config.Betting.spectatorBets.enabled = spectators
        config.Betting.fighterBets.enabled = fighters
        config.Betting.accounts = accounts
        config.Betting.account = account
        config.Match.startCountdownSeconds = countdown
        config.Match.lives = lives
    end
    return world, rng
end

--- Matches on a server, in id order, optionally only in one state.
local function matchesOf(s, state)
    local out = {}
    for _, match in ipairs(s.lobby.All()) do
        if state == nil or match.state == state then out[#out + 1] = match end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function sortedKeys(map)
    local out = {}
    for key in pairs(map or {}) do out[#out + 1] = key end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

local TEAMS = { 'crimson', 'ash', 'bone' }
local ACCOUNTS = { 'cash', 'bank', 'junk' }

--- Weighted towards what moves a round along -- a uniform draw spends most
--- of its turns on actions that cannot apply and never gets a round live.
local ACTIONS = {
    'create', 'create', 'join', 'join', 'join', 'join', 'join', 'team', 'ready',
    'bet', 'bet', 'bet', 'bet', 'panel', 'panel', 'begin', 'begin', 'begin', 'step', 'step', 'clock',
    'kill', 'kill', 'kill', 'spectate', 'spectate', 'unspectate', 'leave', 'leave', 'drop',
    'recycle', 'returns', 'unload', 'reload', 'throw', 'money', 'end', 'abort',
    'broadcast', 'broadcast', 'broadcast', 'refused',
}

--- Who is in no round at all, and who is in one, on a server, in seat order.
local function seatsOf(s, count)
    local idle, fighting = {}, {}
    for src = 1, count do
        if s.lobby.GetByPlayer(src) then fighting[#fighting + 1] = src else idle[#idle + 1] = src end
    end
    return idle, fighting
end

--- One of `list`, or `fallback` when it is empty.
local function oneOf(rng, list, fallback)
    if #list == 0 then return fallback end
    return list[rng(#list)]
end

--- An account a player might name: usually a real one, sometimes none, and
--- now and then one the operator never listed.
local function anAccount(rng)
    local pick = rng(5)
    if pick <= 2 then return nil end
    return ACCOUNTS[pick - 2]
end

--- Draws one action off the NEW server's state, and returns it as two
--- halves: what happens to the world both servers share (the connection
--- list), and what each server is then asked to do. Both servers are handed
--- the same arguments, so any difference afterwards is the code's.
local function drawAction(rng, world, s, forced)
    local kind = forced or ACTIONS[rng(#ACTIONS)]
    local idle, fighting = seatsOf(s, world.count)
    local src = rng(world.count)
    local shared = function() end
    local run = function() end

    if kind == 'create' then
        local who = oneOf(rng, idle, src)
        local busy = {}
        for _, match in ipairs(matchesOf(s)) do busy[match.arenaKey] = true end
        local arena = (not busy.trailerpark) and 'trailerpark' or 'skydome'
        if rng(4) == 1 then arena = ({ 'trailerpark', 'skydome' })[rng(2)] end
        local mode = rng(3) == 1 and 'tdm' or 'ffa'
        local fee = ({ 0, 0, 500, 2000 })[rng(4)]
        local account = anAccount(rng)
        run = function(server) return server.lobby.Create(who, arena, mode, fee, nil, nil, account) end
    elseif kind == 'join' then
        local open = matchesOf(s, 'lobby')
        if #open > 0 then
            local who = oneOf(rng, idle, src)
            local id = open[rng(#open)].id
            local team = TEAMS[rng(3)]
            if rng(4) == 1 then team = nil end
            local account = anAccount(rng)
            run = function(server) return server.lobby.Join(who, id, team, account) end
        end
    elseif kind == 'team' then
        local who = oneOf(rng, fighting, src)
        local team = TEAMS[rng(3)]
        run = function(server) return server.lobby.SetTeam(who, team) end
    elseif kind == 'ready' then
        local who = oneOf(rng, fighting, src)
        local flag = rng(3) ~= 1
        run = function(server) return server.lobby.SetReady(who, flag) end
    elseif kind == 'bet' then
        local all = matchesOf(s)
        if #all > 0 then
            local match = all[rng(#all)]
            local pick
            if s.env.Arena.ModeUsesTeams(match.modeKey) then
                pick = TEAMS[rng(3)]
            else
                pick = oneOf(rng, sortedKeys(match.players), rng(world.count))
                if rng(6) == 1 then pick = rng(world.count) end
            end
            local amount = 100 + rng(9900)
            local account = anAccount(rng)
            local id = match.id
            if rng(2) == 1 then
                run = function(server) return server.betting.PlaceSpectatorBet(src, id, pick, amount, account) end
            else
                run = function(server)
                    return server.fire('placeSpectatorBet', src,
                        { matchId = id, pick = pick, amount = amount, account = account })
                end
            end
        end
    elseif kind == 'panel' then
        local who = oneOf(rng, idle, src)
        local open = rng(5) ~= 1
        run = function(server)
            if open then return server.lobby.MarkPanelOpen(who) end
            return server.lobby.MarkPanelClosed(who)
        end
    elseif kind == 'begin' then
        local open = {}
        for _, match in ipairs(matchesOf(s, 'lobby')) do
            if #sortedKeys(match.players) >= 2 then open[#open + 1] = match end
        end
        if #open > 0 then
            local id = open[rng(#open)].id
            local steps = rng(3) - 1
            run = function(server)
                local match = server.lobby.Get(id)
                for _, who in ipairs(sortedKeys(match and match.players)) do server.lobby.SetReady(who, true) end
                local result = server.match.Begin(id, match and match.hostSource)
                server.step(steps)
                return result
            end
        end
    elseif kind == 'step' then
        local times = rng(2)
        run = function(server) server.step(times) end
    elseif kind == 'clock' then
        local seconds = rng(40)
        run = function(server)
            server.now = server.now + seconds
            server.step(1)
        end
    elseif kind == 'kill' then
        local live = matchesOf(s, 'live')
        if #live > 0 then
            local match = live[rng(#live)]
            local standing = {}
            for _, who in ipairs(sortedKeys(match.players)) do
                if match.players[who].alive then standing[#standing + 1] = who end
            end
            if #standing >= 2 then
                local victim = standing[rng(#standing)]
                local killer = standing[rng(#standing)]
                if rng(5) == 1 then killer = nil end
                run = function(server)
                    local result = server.match.OnDeath(victim, killer)
                    server.step(1)
                    return result
                end
            end
        end
    elseif kind == 'spectate' then
        local live = matchesOf(s, 'live')
        if #live > 0 then
            local who = oneOf(rng, idle, src)
            local id = live[rng(#live)].id
            run = function(server) return server.lobby.AddSpectator(who, id) end
        end
    elseif kind == 'unspectate' then
        run = function(server) return server.lobby.RemoveSpectator(src) end
    elseif kind == 'leave' then
        local who = oneOf(rng, fighting, src)
        run = function(server) return server.fire('leaveMatch', who) end
    elseif kind == 'drop' then
        -- The framework forgets them BEFORE playerDropped reaches this
        -- resource, which is the order a real disconnect arrives in.
        shared = function() world.handles[src] = nil end
        run = function(server)
            server.saved = server.saved or {}
            server.saved[src] = server.records[src] or server.saved[src]
            server.records[src] = nil
            server.dropped(src)
        end
    elseif kind == 'recycle' then
        local stamp = rng(100000)
        shared = function() world.handles[src] = ('Handle%d-%d'):format(src, stamp) end
        run = function(server)
            local fresh = record(src, 1000 + stamp, 2000 + stamp)
            fresh.citizenid = ('CID-NEW-%d'):format(stamp)
            server.records[src] = fresh
        end
    elseif kind == 'returns' then
        local donor = rng(world.count)
        run = function(server)
            if server.records[src] then server.records[src].citizenid = ('CID%03d'):format(donor) end
        end
    elseif kind == 'unload' then
        run = function(server)
            server.saved = server.saved or {}
            server.saved[src] = server.records[src] or server.saved[src]
            server.records[src] = nil
        end
    elseif kind == 'reload' then
        shared = function() world.handles[src] = world.handles[src] or ('Handle%d'):format(src) end
        run = function(server)
            if server.records[src] == nil and server.saved and server.saved[src] then
                server.records[src] = server.saved[src]
            end
        end
    elseif kind == 'throw' then
        run = function(server) server.throwing[src] = not server.throwing[src] end
    elseif kind == 'money' then
        local cash, bank = rng(300000) - 1, rng(300000) - 1
        run = function(server)
            local r = server.records[src]
            if r then r.money.cash, r.money.bank = cash, bank end
        end
    elseif kind == 'end' then
        local live = matchesOf(s, 'live')
        if #live > 0 and rng(2) == 1 then
            local match = live[rng(#live)]
            local winners = { sortedKeys(match.players)[1] }
            local id = match.id
            run = function(server)
                local result = server.match.End(id, 'match.ended', winners)
                server.step(2)
                return result
            end
        end
    elseif kind == 'abort' then
        local all = matchesOf(s)
        if #all > 0 and rng(2) == 1 then
            local id = all[rng(#all)].id
            run = function(server) return server.match.Abort(id, 'match.aborted') end
        end
    elseif kind == 'broadcast' then
        run = function(server) return server.lobby.Broadcast() end
    elseif kind == 'refused' then
        run = function(server) return server.lobby.NoteEditRefused(src) end
    end

    return kind, shared, run
end

--- The opening every world plays before the random part: two rounds made
--- and filled, some money on them, and a few panels open.
local OPENING = {
    'create', 'join', 'join', 'join', 'create', 'join', 'join', 'bet', 'bet', 'bet',
    'panel', 'panel', 'begin', 'step', 'bet', 'spectate', 'broadcast',
}

--- Drives a NEW and an OLD server side by side through seeded random
--- rounds and records every way they differ, and what the run reached.
--- Run once; the two tests below read its findings.
local function runFuzz(worlds, steps)
    local mismatches, stats = {}, {
        worlds = 0, actions = 0, pushes = 0, snapshots = 0, exact = 0, exactWrong = {},
        broadcasts = 0, states = {}, kinds = {}, betsShown = 0, walkedShown = 0, unloadedShown = 0,
        fighterBets = 0, oddSources = 0, watching = 0, feeRounds = 0, eliminated = 0,
    }
    local function complain(line)
        if #mismatches < 8 then mismatches[#mismatches + 1] = line end
        stats.mismatchCount = (stats.mismatchCount or 0) + 1
    end

    for seed = 1, worlds do
        local world, rng = randomWorld(seed * 7919)
        local s = newServer(world, 'new')
        local old = newServer(world, 'old')
        stats.worlds = stats.worlds + 1

        local seats = {}
        for src = 1, world.count + 1 do seats[#seats + 1] = src end

        for step = 1, #OPENING + steps do
            local kind, shared, run = drawAction(rng, world, s, OPENING[step])
            stats.kinds[kind] = (stats.kinds[kind] or 0) + 1
            stats.actions = stats.actions + 1
            shared()

            local markNew, markOld = #s.sent, #old.sent
            local readsNew, readsOld = s.reads, old.reads
            local okNew, errNew = pcall(run, s)
            local okOld, errOld = pcall(run, old)
            readsNew, readsOld = s.reads - readsNew, old.reads - readsOld
            local where = ('seed %d, step %d (%s)'):format(seed, step, kind)

            if okNew ~= okOld then
                complain(('%s: raised in one server only: new %s / old %s'):format(where,
                    tostring(errNew), tostring(errOld)))
            end

            local newSent, oldSent = sentSince(s, markNew), sentSince(old, markOld)
            if #newSent ~= #oldSent then
                complain(('%s: new sent %d events, old sent %d'):format(where, #newSent, #oldSent))
            else
                for index = 1, #oldSent do
                    if newSent[index] ~= oldSent[index] then
                        complain(('%s: event %d differs:\n  new %s\n  old %s'):format(where, index,
                            newSent[index]:sub(1, 400), oldSent[index]:sub(1, 400)))
                        break
                    end
                end
            end

            if kind == 'broadcast' then
                stats.broadcasts = stats.broadcasts + 1
                local heads, loaded = 0, true
                for index = markNew + 1, #s.sent do
                    local message = s.sent[index]
                    if message.event == 'crimson_arena:client:state' then
                        heads = heads + 1
                        if s.records[message.target] == nil or s.throwing[message.target] then loaded = false end
                    end
                end
                stats.pushes = stats.pushes + heads
                -- Never more than the old code, whoever is loaded...
                if readsNew > readsOld then
                    complain(('%s: the new code read the framework %d times, the old %d'):format(where, readsNew, readsOld))
                end
                -- ...and the reference really is the old code, which paid six
                -- or seven a head for everybody.
                if readsOld < 6 * heads or readsOld > 7 * heads then
                    complain(('%s: the old code read %d times for %d heads'):format(where, readsOld, heads))
                end
                if loaded and heads > 0 then
                    stats.exact = stats.exact + 1
                    if readsNew ~= heads and #stats.exactWrong < 5 then
                        stats.exactWrong[#stats.exactWrong + 1] =
                            ('%s: %d loaded recipients cost %d reads'):format(where, heads, readsNew)
                    end
                end
            end

            for _, src in ipairs(seats) do
                local newText, state = builtText(s, src)
                local oldText = builtText(old, src)
                stats.snapshots = stats.snapshots + 1
                if newText ~= oldText then
                    complain(('%s: BuildState(%s) differs:\n  new %s\n  old %s'):format(where, canon(src),
                        newText:sub(1, 400), oldText:sub(1, 400)))
                elseif state then
                    local player = state.player
                    if player.bet ~= false then
                        stats.betsShown = stats.betsShown + 1
                        if player.bet.kind == 'fighter' then stats.fighterBets = stats.fighterBets + 1 end
                    end
                    if #player.walkedOut > 0 then stats.walkedShown = stats.walkedShown + 1 end
                    if player.spectating ~= false then stats.watching = stats.watching + 1 end
                    if s.records[src] == nil and src <= world.count then
                        stats.unloadedShown = stats.unloadedShown + 1
                    end
                end
            end
            -- The odd sources every fifth step: they cost as much as a seat
            -- and answer the same way every time.
            if step % 5 == 0 then
                for _, src in ipairs(ODD_SOURCES) do
                    local newText, oldText = builtText(s, src), builtText(old, src)
                    stats.snapshots = stats.snapshots + 1
                    stats.oddSources = stats.oddSources + 1
                    if newText ~= oldText then
                        complain(('%s: BuildState(%s) differs:\n  new %s\n  old %s'):format(where, canon(src),
                            newText:sub(1, 400), oldText:sub(1, 400)))
                    end
                end
            end

            for _, match in ipairs(matchesOf(s)) do
                stats.states[match.state] = true
                if (tonumber(match.entryFee) or 0) > 0 then stats.feeRounds = stats.feeRounds + 1 end
                for _, row in pairs(match.players) do
                    if row.alive == false then stats.eliminated = stats.eliminated + 1 end
                end
            end
        end

        -- NOTHING ELSE MOVED EITHER: the money ledger and the console agree.
        if wire(s.qbx.ledger) ~= wire(old.qbx.ledger) then
            complain(('seed %d: the money ledgers differ'):format(seed))
        end
        if table.concat(s.console, '\n') ~= table.concat(old.console, '\n') then
            complain(('seed %d: the console output differs'):format(seed))
        end
    end
    return mismatches, stats
end

local fuzzOk, fuzzMismatches, fuzzStats = pcall(runFuzz, 24, 40)

t.test('DIFFERENTIAL: 24 seeded random servers, 40 actions each -- every push and every snapshot identical to the old code\'s', function()
    t.isTrue(fuzzOk, 'the run itself raised: ' .. tostring(fuzzMismatches))
    local stats = fuzzStats
    t.equals(stats.mismatchCount or 0, 0, table.concat(fuzzMismatches, '\n'))

    -- A FUZZ THAT NEVER REACHED ANYTHING PROVES NOTHING, so what it reached
    -- is asserted.
    t.isTrue(stats.snapshots >= 10000, 'only ' .. stats.snapshots .. ' snapshots were compared')
    t.isTrue(stats.oddSources >= 1000, 'only ' .. stats.oddSources .. ' odd sources were compared')
    t.isTrue(stats.pushes >= 200, 'only ' .. stats.pushes .. ' pushes were compared on broadcasts')
    for _, state in ipairs({ 'lobby', 'countdown', 'live' }) do
        t.isTrue(stats.states[state] == true, 'no round was ever seen in state ' .. state)
    end
    t.isTrue(stats.betsShown >= 50, 'a bet was shown only ' .. stats.betsShown .. ' times')
    t.isTrue(stats.fighterBets >= 10, 'a fighter\'s own bet was shown only ' .. stats.fighterBets .. ' times')
    t.isTrue(stats.walkedShown >= 10, 'a walk-out was shown only ' .. stats.walkedShown .. ' times')
    t.isTrue(stats.unloadedShown >= 20, 'an unloaded player was snapshotted only ' .. stats.unloadedShown .. ' times')
    t.isTrue(stats.watching >= 20, 'a watcher was snapshotted only ' .. stats.watching .. ' times')
    t.isTrue(stats.feeRounds >= 20, 'a round with an entry fee was seen only ' .. stats.feeRounds .. ' times')
    t.isTrue(stats.eliminated >= 20, 'an eliminated fighter was seen only ' .. stats.eliminated .. ' times')
end)

t.test('and on every broadcast in that run with every recipient loaded, ONE framework read a head', function()
    t.isTrue(fuzzOk, 'the run itself raised: ' .. tostring(fuzzMismatches))
    t.isTrue(fuzzStats.exact >= 20, 'only ' .. fuzzStats.exact .. ' broadcasts had every recipient loaded')
    t.equals(#fuzzStats.exactWrong, 0, table.concat(fuzzStats.exactWrong, '\n'))
end)

os.exit(t.summary())
