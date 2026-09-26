--[[
    crimson_arena/tests/ammosql_spec.lua

    EVERY STATEMENT server/ammo.lua SENDS oxmysql, BYTE FOR BYTE.

    server/ammo.lua writes to two tables of its own -- the outstanding-kit
    slate (crimson_arena_owed_kit) and the jam list
    (crimson_arena_jammed_stash) -- through twelve statements. They are the
    file's only contract with a database somebody else runs: a changed word is
    a changed table, a changed placeholder count is a query oxmysql refuses on
    its own console, and neither shows up in the game. Every one of them is
    also a copy of something an operator may have imported by hand from
    sql/install.sql, which says so in its own header.

    SO THIS FILE HOLDS THE TWELVE AS REFERENCE TEXT, and drives the real
    server/ammo.lua down every path that sends one: the two schema statements
    and the two reads at start, the age-out, the jam written and deleted and
    replayed both ways, the weapon marked out, the weapon and the stack
    written down as owed, the stack re-sent at its total, and the row
    dropped. What reaches oxmysql on each path is compared with the reference
    for that path, byte for byte, parameters included. A statement that
    changes -- by a word, a space or a placeholder -- or a call site that
    sends the wrong one, fails here by name.

    AND THE ORDER THE CALL SITES PROMISE, WHICH A FIXTURE THAT ANSWERS AT
    ONCE CANNOT SEE. Each read is sent from inside its CREATE TABLE's
    callback, and the age-out's answer is what licenses collecting a
    consumable debt at all; both sit on the call sites this file's statements
    are sent from, and un-nesting a read or dropping the `answer ~= nil` test
    passed every spec there was. So the fixture can also hold answers back
    and release them one at a time, and read rows back, and the tests under
    their own headings below use both.

    AND THE TWELVE LIVE IN ONE TABLE. They were twelve file-level locals, and
    a Lua main chunk has room for 200: server/ammo.lua reached 169, which is
    what tests/localheadroom_spec.lua is about. Holding them as fields of one
    `SQL` table gave eleven of those back. The source-level tests at the foot
    of this file keep it that way, and keep sql/install.sql's pointers to the
    Lua copies of its schema pointing at names that exist.

    CHANGING A STATEMENT ON PURPOSE means changing its reference here in the
    same commit, and sql/install.sql with it if it is a CREATE TABLE -- which
    is the point: nobody changes one of these without being told what else
    has to move.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('ammosql_spec')

-- ======================================================================
-- THE REFERENCE TEXT
--
-- BYTE FOR BYTE, INDENTATION INCLUDED. The multi-line statements are Lua
-- long strings in server/ammo.lua, so their first newline is dropped and
-- every other character -- the four-space indent, the blank line inside the
-- CREATE TABLE, the newline before the closing brackets -- is part of what
-- oxmysql receives. DO NOT reindent these to suit this file.
-- ======================================================================

local REFERENCE = {}

REFERENCE.JAM_SCHEMA = [[
    CREATE TABLE IF NOT EXISTS crimson_arena_jammed_stash (

        stash VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
        jammed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (stash)
    ) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
]]

REFERENCE.JAM_WRITE = [[
    INSERT IGNORE INTO crimson_arena_jammed_stash (stash) VALUES (?)
]]

REFERENCE.JAM_DELETE = [[
    DELETE FROM crimson_arena_jammed_stash WHERE stash = ?
]]

REFERENCE.JAM_READ = [[
    SELECT stash FROM crimson_arena_jammed_stash
]]

REFERENCE.KIT_SCHEMA = [[
    CREATE TABLE IF NOT EXISTS crimson_arena_owed_kit (

        citizenid VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
        ledger_key VARCHAR(191) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
        kind VARCHAR(16) NOT NULL,
        name VARCHAR(128) NOT NULL,
        serial VARCHAR(128) NULL,
        amount INT NOT NULL DEFAULT 1,
        written_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (citizenid, ledger_key)
    ) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
]]

REFERENCE.KIT_WEAPON = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, serial, amount)
    VALUES (?, ?, 'weapon', ?, ?, 1)
    ON DUPLICATE KEY UPDATE kind = 'weapon', amount = 1
]]

REFERENCE.KIT_OUT = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, serial, amount)
    VALUES (?, ?, 'out', ?, ?, 1)
    ON DUPLICATE KEY UPDATE kind = 'out', amount = 1
]]

REFERENCE.KIT_ITEM_ADD = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, amount)
    VALUES (?, ?, 'item', ?, ?)
    ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)
]]

REFERENCE.KIT_ITEM_SET = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, amount)
    VALUES (?, ?, 'item', ?, ?)
    ON DUPLICATE KEY UPDATE amount = VALUES(amount)
]]

-- The three single-line ones are built by concatenation in the source; the
-- numbers are KIT_READ_LIMIT and OWED_KIT_MAX_DAYS, inlined on purpose there.
REFERENCE.KIT_DROP = 'DELETE FROM crimson_arena_owed_kit WHERE citizenid = ? AND ledger_key = ?'

REFERENCE.KIT_READ = 'SELECT citizenid, ledger_key, kind, name, serial, amount FROM crimson_arena_owed_kit '
    .. 'ORDER BY written_at DESC LIMIT 5000'

REFERENCE.KIT_PURGE = 'DELETE FROM crimson_arena_owed_kit WHERE written_at < (NOW() - INTERVAL 30 DAY)'

--- The reference names, sorted, so every loop below runs in the same order.
local NAMES = {}
for name in pairs(REFERENCE) do NAMES[#NAMES + 1] = name end
table.sort(NAMES)

--- Which reference a statement is, by exact text; nil for anything else.
--- @param sql any
--- @return string|nil
local function referenceOf(sql)
    for _, name in ipairs(NAMES) do
        if sql == REFERENCE[name] then return name end
    end
    return nil
end

--- Whether a statement touches one of the two tables this file owns.
--- @param sql any
--- @return boolean
local function ours(sql)
    return type(sql) == 'string'
        and (sql:find('crimson_arena_owed_kit', 1, true) ~= nil
            or sql:find('crimson_arena_jammed_stash', 1, true) ~= nil)
end

--- @param sql string
--- @return integer
local function placeholders(sql)
    local _, count = sql:gsub('%?', '')
    return count
end

-- ======================================================================
-- THE FIXTURE
--
-- The real server/util.lua and server/ammo.lua, with ox_inventory holding
-- real contents and oxmysql RECORDING every statement it is handed, in
-- order, with its parameters. Modelled on tests/outagereplay_spec.lua.
--
--   control.refuse     -- a removal from a PLAYER is refused, which is what
--                         leaves a debt behind at the exit
--   control.stuck      -- a removal from a STASH is refused, which is what
--                         jams one
--   control.failWrites -- oxmysql takes a write and answers nil, the way a
--                         user without INSERT or DELETE does
--   control.down       -- oxmysql is not started
--   control.offline    -- nobody is connected, so the sweep collects from
--                         nobody and only replays
--   control.strip      -- Config.Loadouts.inventory.stripOnEntry
--   control.dbOff      -- Config.Database.enabled false, the shipped default
--   control.hold       -- oxmysql takes each statement and answers it only
--                         when the test calls fixture.answer, the way a real
--                         one answers later on its own thread; a statement
--                         sent from inside a held answer is held in turn
--   control.kitRows    -- what the slate's SELECT reads back (default none)
--   control.jamRows    -- what the jam list's SELECT reads back (default none)
--
-- THE AGE-OUT IS ANSWERED AS A DELETE THAT MATCHED NOTHING, {affectedRows =
-- 0}, which is the ordinary answer on a healthy server and the one that
-- matters to server/ammo.lua: any answer at all is its proof that a write
-- lands (kitWriteLanded). With control.failWrites it is nil like every
-- other write.
-- ======================================================================

local function newArena(control)
    control = control or {}

    local queries = {}
    local inv = {}
    local serials = 0

    local function bucket(id)
        inv[id] = inv[id] or {}
        return inv[id]
    end

    local ox = {
        RegisterStash = function() return true end,
        registerHook = function() return 1 end,
        GetInventoryItems = function(_self, id)
            local out = {}
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        GetItemCount = function(_self, id, name)
            local total = 0
            for _, item in ipairs(bucket(id)) do
                if item.name == name then total = total + (tonumber(item.count) or 0) end
            end
            return total
        end,
        AddItem = function(_self, id, name, count, metadata)
            -- ox_inventory stamps a serial on a weapon that arrives without
            -- one; the serial is what every weapon row is keyed by.
            local meta = metadata
            if type(name) == 'string' and name:find('^WEAPON_')
                and (meta == nil or meta.serial == nil) then
                serials = serials + 1
                meta = meta or {}
                meta.serial = 'ARENA-' .. serials
            end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = meta }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            if control.refuse and type(id) == 'number' then return false end
            if control.stuck and type(id) ~= 'number' then return false end

            local from = bucket(id)
            local want = tonumber(count) or 0
            local total = 0
            for _, item in ipairs(from) do
                if item.name == name then total = total + (tonumber(item.count) or 0) end
            end
            if total < want then return false end

            for index = #from, 1, -1 do
                if want <= 0 then break end
                if from[index].name == name then
                    local have = tonumber(from[index].count) or 0
                    if have <= want then
                        want = want - have
                        table.remove(from, index)
                    else
                        from[index].count = have - want
                        want = 0
                    end
                end
            end
            return true
        end,
        ClearInventory = function(_self, id)
            inv[id] = {}
            return true
        end,
    }

    --- What oxmysql answers a statement with, decided when it answers.
    local function answerFor(sql)
        local text = type(sql) == 'string' and sql or ''

        if text:find('CREATE TABLE', 1, true) then return {} end
        if text:find('SELECT', 1, true) then
            if text:find('crimson_arena_owed_kit', 1, true) then return control.kitRows or {} end
            if text:find('crimson_arena_jammed_stash', 1, true) then return control.jamRows or {} end
            return {}
        end
        if control.failWrites then return nil end
        if text == REFERENCE.KIT_PURGE then return { affectedRows = 0 } end
        return { affectedRows = 1 }
    end

    --- Statements taken and not yet answered, oldest first (control.hold).
    local held = {}

    --- oxmysql: records the statement exactly as handed over, then answers
    --- -- at once, or with control.hold when fixture.answer says so.
    local function query(_self, sql, params, cb)
        queries[#queries + 1] = { sql = sql, params = params }
        if control.hold then
            held[#held + 1] = { sql = sql, cb = cb }
            return
        end
        if cb then cb(answerFor(sql)) end
    end

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox, oxmysql = { query = query } },
            { __call = function() end }),
        GetResourceState = function(name)
            if name == 'ox_inventory' then return 'started' end
            if name == 'oxmysql' then return control.down and 'missing' or 'started' end
            return 'missing'
        end,
        GetPlayers = function()
            if control.offline then return {} end
            return { '1' }
        end,
        Wait = function() end,
        CreateThread = function(fn) fn() end,
        SetTimeout = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = Sandbox.newOxLib(),
        print = function() end,
        ArenaGetPlayer = function(src)
            return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
        end,
        ArenaDebug = function() end,
        ArenaNotifyKey = function() end,
        ArenaToastKey = function() end,
        ArenaPlayerName = function(src) return 'P' .. tostring(src) end,
        ArenaDispatch = { Set = function() end, Clear = function() end,
            IsPlayerInArena = function() return false end },
    })

    -- The sweep is a `while true`, and CreateThread above runs a body to
    -- completion, so every pass here is driven by hand.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    env.Config.Loadouts.inventory.stripOnEntry = control.strip == true
    env.Config.Database = { enabled = control.dbOff ~= true }

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    env.ArenaDebug = function() end
    env.ArenaLog = function() end
    Sandbox.loadInto('../Crimson-Arena/server/ammo.lua', env)

    local fixture = { env = env, ammo = env.ArenaAmmo, queries = queries, control = control }

    --- How many statements have been sent so far; pass it to `since`.
    function fixture.mark() return #queries end

    --- Every statement to one of this file's tables sent after `mark`.
    function fixture.since(mark)
        local out = {}
        for index = (mark or 0) + 1, #queries do
            if ours(queries[index].sql) then out[#out + 1] = queries[index] end
        end
        return out
    end

    --- Answers the oldest held statement that is reference `name`. False
    --- when none is held, so a test can say so.
    function fixture.answer(name)
        for index, entry in ipairs(held) do
            if entry.sql == REFERENCE[name] then
                table.remove(held, index)
                if entry.cb then entry.cb(answerFor(entry.sql)) end
                return true
            end
        end
        return false
    end

    --- The reference names of every statement still waiting for an answer.
    function fixture.waiting()
        local out = {}
        for _, entry in ipairs(held) do out[#out + 1] = referenceOf(entry.sql) or tostring(entry.sql) end
        return table.concat(out, ',')
    end

    --- How many of one item a player holds, across stacks.
    function fixture.count(src, name)
        return ox:GetItemCount(src, name)
    end

    function fixture.give(src, name, count)
        local into = bucket(src)
        into[#into + 1] = { name = name, count = count }
    end

    --- Sets how many of one item a player holds, across stacks.
    function fixture.setCount(src, name, count)
        for index = #bucket(src), 1, -1 do
            if bucket(src)[index].name == name then table.remove(bucket(src), index) end
        end
        if count > 0 then fixture.give(src, name, count) end
    end

    function fixture.issue(src, matchId, weapons, supplies)
        local loadout = { weapons = {}, supplies = {}, armor = 0, health = 200 }
        for index = 1, weapons or 1 do
            loadout.weapons[index] = { key = 'w' .. index, weapon = 'WEAPON_TEST' .. index,
                ammo = 0, components = {} }
        end
        for index, count in ipairs(supplies or { 30 }) do
            loadout.supplies[index] = { item = index == 1 and 'bandage' or 'armour', count = count }
        end
        return fixture.ammo.Issue(src, matchId, loadout)
    end

    --- An exit that cannot take the kit back, which writes the debt down.
    function fixture.leaveOwing(src, matchId)
        fixture.issue(src, matchId or 'm1')
        control.refuse = true
        fixture.ammo.Reclaim(src, 'match ended')
        control.refuse = false
    end

    --- An exit that hands the player's own things back and cannot take them
    --- out of the stash, which jams it. Needs control.strip.
    function fixture.jam(src)
        fixture.give(src, 'phone', 1)
        fixture.issue(src, 'mj', 0, {})
        control.stuck = true
        fixture.ammo.Reclaim(src, 'match ended')
        control.stuck = false
    end

    return fixture
end

--- The parameters as one comparable string. `n` is how many there must be:
--- anything past it, and any nil before it, shows up.
local function paramsOf(sent, n)
    local out = {}
    local params = sent.params
    if type(params) ~= 'table' then return 'NOT A TABLE: ' .. tostring(params) end
    for index = 1, math.max(n, #params) do out[index] = tostring(params[index]) end
    return table.concat(out, '|')
end

--- Asserts `sent` is exactly reference `name`, with exactly `params`.
local function sends(sent, name, params)
    t.isNotNil(sent, ('nothing was sent where %s should have been'):format(name))
    t.equals(referenceOf(sent.sql), name,
        ('a different statement went out where %s should have: %q'):format(name, tostring(sent.sql)))
    t.equals(sent.sql, REFERENCE[name], name .. ' is not byte for byte what it was')
    if params then
        t.equals(paramsOf(sent, #params), table.concat(params, '|'), name .. ' parameters')
    end
end

--- The statements in `sent`, by the ledger key or stash they are about.
---
--- ORDER-FREE ON PURPOSE where ammo.lua does not promise an order. A replay
--- walks `pendingKeys` with pairs(), and Lua 5.4 seeds its string hashing
--- per process, so which of two keys goes first changes from run to run.
--- The start-up sequence below IS an order ammo.lua promises, and is
--- checked in order.
local function byKey(sent)
    local out, count = {}, 0
    for _, statement in ipairs(sent) do
        local params = type(statement.params) == 'table' and statement.params or {}
        local key = tostring(params[2] ~= nil and params[2] or params[1])
        -- Two statements about one key is not what any test here expects;
        -- say so rather than keep whichever came second.
        out[key] = out[key] and { sql = 'TWO STATEMENTS FOR ' .. key } or statement
        count = count + 1
    end
    return out, count
end

-- ======================================================================
-- AT START: THE SCHEMA, THE AGE-OUT AND THE TWO READS
-- ======================================================================

t.test('LoadOwedKit sends the slate\'s CREATE TABLE, then the age-out, then the read', function()
    local s = newArena()
    t.isTrue(s.ammo.LoadOwedKit(), 'the read did not start')
    local sent = s.since(0)
    t.equals(#sent, 3, 'statements sent')
    sends(sent[1], 'KIT_SCHEMA', {})
    sends(sent[2], 'KIT_PURGE', {})
    sends(sent[3], 'KIT_READ', {})
end)

t.test('LoadJams sends the jam list\'s CREATE TABLE, then its read', function()
    local s = newArena()
    t.isTrue(s.ammo.LoadJams(), 'the read did not start')
    local sent = s.since(0)
    t.equals(#sent, 2, 'statements sent')
    sends(sent[1], 'JAM_SCHEMA', {})
    sends(sent[2], 'JAM_READ', {})
end)

t.test('the reads run once: a second LoadOwedKit or LoadJams sends nothing', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.ammo.LoadJams()
    local mark = s.mark()
    t.isFalse(s.ammo.LoadOwedKit())
    t.isFalse(s.ammo.LoadJams())
    t.equals(#s.since(mark), 0)
end)

-- ======================================================================
-- AND EACH READ WAITS FOR ITS OWN TABLE TO EXIST
--
-- The tests above answer every statement the moment it is sent, so a read
-- sent BEFORE its CREATE TABLE had answered looked exactly like one sent
-- after. It is not: oxmysql runs statements on a pool of connections, and
-- on a fresh database a SELECT that overtakes the CREATE finds no table.
-- Nesting each read inside its schema statement's callback is what orders
-- them, and un-nesting either one passed every spec there was. These hold
-- the answers back, the way a real oxmysql does, and release them one at a
-- time.
-- ======================================================================

t.test('with nothing answered yet, start sends the two CREATE TABLEs and nothing else', function()
    local s = newArena({ hold = true })
    t.isTrue(s.ammo.LoadJams(), 'the jam read did not start')
    t.isTrue(s.ammo.LoadOwedKit(), 'the slate read did not start')
    local sent = s.since(0)
    t.equals(#sent, 2, 'statements sent before any answer')
    sends(sent[1], 'JAM_SCHEMA', {})
    sends(sent[2], 'KIT_SCHEMA', {})
    t.equals(s.waiting(), 'JAM_SCHEMA,KIT_SCHEMA')
end)

t.test('the slate\'s CREATE answered: the age-out, then the read -- and still nothing for the jam list', function()
    local s = newArena({ hold = true })
    s.ammo.LoadJams()
    s.ammo.LoadOwedKit()
    local mark = s.mark()
    t.isTrue(s.answer('KIT_SCHEMA'))
    local sent = s.since(mark)
    t.equals(#sent, 2, 'statements sent once the slate\'s table exists')
    sends(sent[1], 'KIT_PURGE', {})
    sends(sent[2], 'KIT_READ', {})

    mark = s.mark()
    t.isTrue(s.answer('JAM_SCHEMA'))
    sent = s.since(mark)
    t.equals(#sent, 1, 'statements sent once the jam list\'s table exists')
    sends(sent[1], 'JAM_READ', {})
    t.equals(s.waiting(), 'KIT_PURGE,KIT_READ,JAM_READ')
end)

t.test('the jam list\'s CREATE answered first: its read, and nothing for the slate until its own', function()
    local s = newArena({ hold = true })
    s.ammo.LoadOwedKit()
    s.ammo.LoadJams()
    local mark = s.mark()
    t.isTrue(s.answer('JAM_SCHEMA'))
    local sent = s.since(mark)
    t.equals(#sent, 1, 'statements sent once the jam list\'s table exists')
    sends(sent[1], 'JAM_READ', {})

    mark = s.mark()
    t.isTrue(s.answer('KIT_SCHEMA'))
    sent = s.since(mark)
    t.equals(#sent, 2)
    sends(sent[1], 'KIT_PURGE', {})
    sends(sent[2], 'KIT_READ', {})
end)

t.test('a CREATE that is never answered sends no read, however often start is retried', function()
    local s = newArena({ hold = true, offline = true })
    s.ammo.LoadJams()
    s.ammo.LoadOwedKit()
    for _ = 1, 3 do
        t.isFalse(s.ammo.LoadJams(), 'a second jam read started while the first is out')
        t.isFalse(s.ammo.LoadOwedKit(), 'a second slate read started while the first is out')
        s.ammo.SweepReturns()
    end
    t.equals(#s.since(0), 2, 'statements sent with neither CREATE answered')
    t.equals(s.waiting(), 'JAM_SCHEMA,KIT_SCHEMA')

    -- And one answered while the other is not: only its own read follows.
    t.isTrue(s.answer('JAM_SCHEMA'))
    s.ammo.SweepReturns()
    t.equals(s.waiting(), 'KIT_SCHEMA,JAM_READ')
end)

t.test('held answers still land: rows read back after both CREATEs are on the slate and the jam list', function()
    -- The mode above is a real one, not a way of making nothing happen:
    -- released in order, the reads land and are merged.
    local s = newArena({
        hold = true,
        kitRows = { { citizenid = 'CID4', ledger_key = 'i:bandage', kind = 'item', name = 'bandage', amount = 5 } },
        jamRows = { { stash = 'crimson_arena_CID7' } },
    })
    s.ammo.LoadJams()
    s.ammo.LoadOwedKit()
    local jammed, known = s.ammo.IsJammed('crimson_arena_CID7')
    t.isFalse(jammed)
    t.isFalse(known, 'the jam list claims to be known before it was read')
    t.equals(#s.ammo.OwedKit(), 0)

    for _, name in ipairs({ 'KIT_SCHEMA', 'JAM_SCHEMA', 'KIT_PURGE', 'KIT_READ', 'JAM_READ' }) do
        t.isTrue(s.answer(name), name .. ' was not waiting to be answered')
    end
    t.equals(s.waiting(), '')

    jammed, known = s.ammo.IsJammed('crimson_arena_CID7')
    t.isTrue(jammed, 'the jam read back was not merged')
    t.isTrue(known)
    local slate = s.ammo.OwedKit()
    t.equals(#slate, 1)
    t.equals(slate[1].citizenid, 'CID4')
    t.equals(#slate[1].items, 1)
    t.equals(slate[1].items[1].amount, 5)
end)

-- ======================================================================
-- THE AGE-OUT'S ANSWER IS THE PROOF THAT A WRITE LANDS
--
-- server/ammo.lua will not collect a consumable debt until some write on the
-- slate has come back with an answer, because settling one is a DELETE that
-- has to land or the next start reads the debt back and takes it again. On a
-- process whose only slate traffic is collections, the age-out at start is
-- the ONLY write -- so `if answer ~= nil` on its callback is the whole of the
-- gate. Setting the flag on a nil answer took 5 of a player's 10 bandages on
-- a database user that can SELECT and not DELETE, once per restart.
-- ======================================================================

local OWED_BANDAGES = { { citizenid = 'CID1', ledger_key = 'i:bandage', kind = 'item', name = 'bandage', amount = 5 } }

t.test('a database that answers every write nil, the age-out included, never collects a debt it read back', function()
    local s = newArena({ failWrites = true, kitRows = OWED_BANDAGES })
    t.isTrue(s.ammo.LoadOwedKit())
    -- The jam read too, which the sweep would otherwise start, so what is
    -- sent below is the sweep's own.
    t.isTrue(s.ammo.LoadJams())
    local slate = s.ammo.OwedKit()
    t.equals(#slate, 1, 'the debt was not read back, so this proves nothing')
    t.equals(slate[1].items[1].amount, 5)

    s.setCount(1, 'bandage', 10)
    local mark = s.mark()
    s.ammo.SweepReturns()
    t.equals(s.count(1, 'bandage'), 10, 'bandages taken on a database that cannot write the settlement down')
    s.ammo.SweepReturns()
    t.equals(s.count(1, 'bandage'), 10, 'taken on the second sweep')
    t.equals(#s.since(mark), 0, 'a settlement was sent for a collection that did not happen')
    t.equals(s.ammo.OwedKit()[1].items[1].amount, 5, 'the debt left the slate without being collected')
end)

t.test('and one whose age-out is answered, even with nothing to delete, collects it and drops the row', function()
    -- The control for the test above: the same debt, the same player, and
    -- the age-out answered {affectedRows = 0}. Without it the test above
    -- could pass on a sweep that collects nothing for some other reason.
    local s = newArena({ kitRows = OWED_BANDAGES })
    t.isTrue(s.ammo.LoadOwedKit())
    t.isTrue(s.ammo.LoadJams())
    s.setCount(1, 'bandage', 10)
    local mark = s.mark()
    s.ammo.SweepReturns()
    t.equals(s.count(1, 'bandage'), 5, 'the debt of 5 was not collected')
    local sent = s.since(mark)
    t.equals(#sent, 1)
    sends(sent[1], 'KIT_DROP', { 'CID1', 'i:bandage' })
    t.equals(#s.ammo.OwedKit(), 0)
end)

t.test('an age-out still out on the wire proves nothing either: no collection until it answers', function()
    -- The same gate from the other side. Answered late, as oxmysql answers,
    -- the collection waits for it and then goes ahead.
    local s = newArena({ hold = true, kitRows = OWED_BANDAGES })
    s.ammo.LoadOwedKit()
    t.isTrue(s.answer('KIT_SCHEMA'))
    t.isTrue(s.answer('KIT_READ'))
    t.equals(#s.ammo.OwedKit(), 1, 'the debt was not read back')
    s.setCount(1, 'bandage', 10)
    s.ammo.SweepReturns()
    t.equals(s.count(1, 'bandage'), 10, 'collected before any write had answered')
    t.isTrue(s.answer('KIT_PURGE'))
    s.ammo.SweepReturns()
    t.equals(s.count(1, 'bandage'), 5, 'not collected once the age-out answered')
end)

-- ======================================================================
-- THE SLATE
-- ======================================================================

t.test('a weapon handed out is marked out on the slate', function()
    local s = newArena()
    -- BOTH reads first: Issue starts whichever has not run yet, and this
    -- test is about the one statement the issue itself sends.
    s.ammo.LoadOwedKit()
    s.ammo.LoadJams()
    local mark = s.mark()
    s.issue(1, 'm1', 1, {})
    local sent = s.since(mark)
    t.equals(#sent, 1, 'statements sent')
    sends(sent[1], 'KIT_OUT', { 'CID1', 'w:ARENA-1', 'WEAPON_TEST1', 'ARENA-1' })
end)

t.test('a weapon taken back cleanly has its row dropped', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.issue(1, 'm1', 1, {})
    local mark = s.mark()
    s.ammo.Reclaim(1, 'match ended')
    local sent = s.since(mark)
    t.equals(#sent, 1, 'statements sent')
    sends(sent[1], 'KIT_DROP', { 'CID1', 'w:ARENA-1' })
end)

t.test('an exit that cannot take the kit back writes the weapon and the stack down as owed', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.issue(1, 'm1', 1, { 30 })
    local mark = s.mark()
    s.control.refuse = true
    s.ammo.Reclaim(1, 'match ended')
    s.control.refuse = false
    local sent, count = byKey(s.since(mark))
    t.equals(count, 2, 'statements sent')
    sends(sent['w:ARENA-1'], 'KIT_WEAPON', { 'CID1', 'w:ARENA-1', 'WEAPON_TEST1', 'ARENA-1' })
    sends(sent['i:bandage'], 'KIT_ITEM_ADD', { 'CID1', 'i:bandage', 'bandage', '30' })
end)

t.test('a debt collected later drops each row it settles', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.leaveOwing(1)
    local mark = s.mark()
    s.ammo.SweepReturns()
    local sent, count = byKey(s.since(mark))
    t.equals(count, 2, 'statements sent')
    sends(sent['w:ARENA-1'], 'KIT_DROP', { 'CID1', 'w:ARENA-1' })
    sends(sent['i:bandage'], 'KIT_DROP', { 'CID1', 'i:bandage' })
end)

t.test('a stack collected in part is re-written at its remainder, not added to', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.leaveOwing(1)
    s.setCount(1, 'bandage', 10)
    local mark = s.mark()
    s.ammo.SweepReturns()
    local sent, count = byKey(s.since(mark))
    t.equals(count, 2, 'statements sent')
    sends(sent['w:ARENA-1'], 'KIT_DROP', { 'CID1', 'w:ARENA-1' })
    sends(sent['i:bandage'], 'KIT_ITEM_SET', { 'CID1', 'i:bandage', 'bandage', '20' })
end)

t.test('writes the database refused are replayed as the absolute forms: the weapon row and the stack SET', function()
    local s = newArena()
    s.ammo.LoadOwedKit()
    s.issue(1, 'm1', 1, { 30 })
    s.control.failWrites = true
    s.control.refuse = true
    s.ammo.Reclaim(1, 'match ended')
    s.control.refuse = false
    s.control.failWrites = false
    s.control.offline = true

    local mark = s.mark()
    s.ammo.SweepReturns()
    local sent, count = byKey(s.since(mark))
    t.equals(count, 2, 'statements sent')
    sends(sent['w:ARENA-1'], 'KIT_WEAPON', { 'CID1', 'w:ARENA-1', 'WEAPON_TEST1', 'ARENA-1' })
    -- NEVER the adding form on a replay; ammo.lua's pendingKeys says why.
    sends(sent['i:bandage'], 'KIT_ITEM_SET', { 'CID1', 'i:bandage', 'bandage', '30' })
end)

-- ======================================================================
-- THE JAM LIST
-- ======================================================================

t.test('a jammed stash is written to the jam list', function()
    local s = newArena({ strip = true })
    s.ammo.LoadJams()
    local mark = s.mark()
    s.jam(1)
    t.isTrue(s.ammo.IsJammed('crimson_arena_CID1'), 'the fixture did not jam the stash')
    local jams = {}
    for _, sent in ipairs(s.since(mark)) do
        if sent.sql:find('jammed_stash', 1, true) then jams[#jams + 1] = sent end
    end
    t.equals(#jams, 1, 'jam statements sent')
    sends(jams[1], 'JAM_WRITE', { 'crimson_arena_CID1' })
end)

t.test('clearing the hold deletes the row', function()
    local s = newArena({ strip = true })
    s.ammo.LoadJams()
    s.jam(1)
    local mark = s.mark()
    t.isTrue(s.ammo.Unjam('crimson_arena_CID1'))
    local sent = s.since(mark)
    t.equals(#sent, 1, 'statements sent')
    sends(sent[1], 'JAM_DELETE', { 'crimson_arena_CID1' })
end)

t.test('a jam the database refused is replayed as the INSERT while the stash is held', function()
    local s = newArena({ strip = true })
    s.ammo.LoadJams()
    s.control.failWrites = true
    s.jam(1)
    s.control.failWrites = false
    s.control.offline = true

    local mark = s.mark()
    s.ammo.SweepReturns()
    local jams = {}
    for _, sent in ipairs(s.since(mark)) do
        if sent.sql:find('jammed_stash', 1, true) then jams[#jams + 1] = sent end
    end
    t.equals(#jams, 1, 'jam statements sent')
    sends(jams[1], 'JAM_WRITE', { 'crimson_arena_CID1' })
end)

t.test('a settlement the database refused is replayed as the DELETE', function()
    local s = newArena({ strip = true })
    s.ammo.LoadJams()
    s.jam(1)
    s.control.failWrites = true
    t.isTrue(s.ammo.Unjam('crimson_arena_CID1'))
    s.control.failWrites = false
    s.control.offline = true

    local mark = s.mark()
    s.ammo.SweepReturns()
    local jams = {}
    for _, sent in ipairs(s.since(mark)) do
        if sent.sql:find('jammed_stash', 1, true) then jams[#jams + 1] = sent end
    end
    t.equals(#jams, 1, 'jam statements sent')
    sends(jams[1], 'JAM_DELETE', { 'crimson_arena_CID1' })
end)

t.test('Unjam on nil, junk or a stash never held sends nothing', function()
    local s = newArena({ strip = true })
    s.ammo.LoadJams()
    local mark = s.mark()
    for _, junk in ipairs({ false, 0, '', 'crimson_arena_CID9', {}, 'x' }) do
        t.isFalse(s.ammo.Unjam(junk), 'Unjam accepted ' .. tostring(junk))
    end
    t.isFalse(s.ammo.Unjam(nil))
    t.equals(#s.since(mark), 0)
end)

-- ======================================================================
-- NOTHING AT ALL WITH THE DATABASE OFF OR DOWN
-- ======================================================================

for _, case in ipairs({
    { label = 'switched off (the shipped default)', control = { dbOff = true } },
    { label = 'not started', control = { down = true } },
}) do
    t.test('with the database ' .. case.label .. ', no path sends either table a statement', function()
        local s = newArena(case.control)
        s.ammo.LoadOwedKit()
        s.ammo.LoadJams()

        -- A REAL DEBT AND A REAL JAM, or this proves nothing about the paths
        -- that write them. The debt with the stripping off: with it on, the
        -- exit takes the kit back through ClearInventory, which the fixture
        -- never refuses, and nothing is owed at all.
        s.leaveOwing(1)
        local slate = s.ammo.OwedKit()
        t.equals(#slate, 1, 'the exit left no debt, so the writes that record one never ran')
        t.equals(#slate[1].weapons, 1)
        t.equals(#slate[1].items, 1)
        s.ammo.SweepReturns()

        s.env.Config.Loadouts.inventory.stripOnEntry = true
        s.jam(2)
        t.isTrue((s.ammo.IsJammed('crimson_arena_CID2')), 'the stash did not jam, so the jam write never ran')
        t.isTrue(s.ammo.Unjam('crimson_arena_CID2'), 'the hold was not cleared, so the delete never ran')
        s.ammo.SweepReturns()

        -- And a second debt collected in part, for the SET form and the drop.
        s.env.Config.Loadouts.inventory.stripOnEntry = false
        s.leaveOwing(3, 'm3')
        s.setCount(3, 'bandage', 10)
        s.ammo.SweepReturns()

        t.equals(#s.since(0), 0)

        -- NOT STARTED IS AN OUTAGE, and what it held back goes out the moment
        -- oxmysql answers -- which is what proves the paths above had
        -- something to send. Switched off, nothing ever goes.
        if case.control.down then
            s.control.down = false
            s.ammo.LoadOwedKit()
            s.ammo.LoadJams()
            s.ammo.SweepReturns()
            local sent = s.since(0)
            t.isTrue(#sent > 4, ('only %d statement(s) once oxmysql started'):format(#sent))
            local replayed = {}
            for _, statement in ipairs(sent) do
                local name = referenceOf(statement.sql)
                t.isNotNil(name, 'not one of the twelve: ' .. tostring(statement.sql))
                if name then replayed[name] = true end
            end
            -- The owed weapon and the owed stacks as memory holds them, the
            -- collected weapon's row dropped, and the cleared hold deleted.
            for _, name in ipairs({ 'KIT_WEAPON', 'KIT_ITEM_SET', 'KIT_DROP', 'JAM_DELETE' }) do
                t.isTrue(replayed[name] == true, name .. ' was not replayed once oxmysql started')
            end
            -- NEVER the adding form, which would add the stack a second time.
            t.isNil(replayed.KIT_ITEM_ADD, 'a stack was replayed with the adding statement')
        end
    end)
end

-- ======================================================================
-- EVERY PATH AT ONCE, OVER A SEEDED CORPUS
--
-- The tests above each walk one path to one statement. This walks random
-- sequences of the same operations -- exits clean and refused, jams,
-- clears, outages of every kind, partial spending, sweeps -- and holds EVERY
-- statement either table is sent to the same rule: it is one of the twelve,
-- byte for byte, and it carries exactly as many parameters as it has
-- placeholders, none of them nil. A 32-bit LCG with a fixed seed, so a
-- failure names a case that fails the same way every run.
-- ======================================================================

local function lcg(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return state % n + 1
    end
end

local CASES = 300
local seen = {}
local corpusStatements = 0

t.test(('%d seeded sequences: every statement sent is one of the twelve, with every placeholder filled'):format(CASES),
function()
    local problems = {}

    for case = 1, CASES do
        local roll = lcg(case * 7919)
        local s = newArena({ strip = roll(2) == 1 })
        s.give(1, 'phone', 1)
        s.ammo.LoadOwedKit()
        s.ammo.LoadJams()

        for step = 1, 4 + roll(8) do
            local op = roll(10)
            if op == 1 then
                s.issue(1, ('m%d_%d'):format(case, step), roll(3) - 1, ({ {}, { 30 }, { 30, 2 } })[roll(3)])
            elseif op == 2 then
                s.control.refuse = roll(2) == 1
                s.control.stuck = roll(3) == 1
                s.ammo.Reclaim(1, 'match ended')
                s.control.refuse, s.control.stuck = false, false
            elseif op == 3 then
                s.control.failWrites = not s.control.failWrites
            elseif op == 4 then
                s.control.down = not s.control.down
            elseif op == 5 then
                s.control.offline = not s.control.offline
            elseif op == 6 or op == 7 then
                s.ammo.SweepReturns()
            elseif op == 8 then
                s.ammo.Unjam('crimson_arena_CID1')
            elseif op == 9 then
                s.setCount(1, 'bandage', roll(40) - 1)
            else
                s.ammo.LoadOwedKit()
                s.ammo.LoadJams()
            end
        end
        -- And a last clean pass, so whatever was queued is replayed.
        s.control.failWrites, s.control.down, s.control.offline = false, false, false
        s.ammo.SweepReturns()

        for index, sent in ipairs(s.since(0)) do
            corpusStatements = corpusStatements + 1
            local name = referenceOf(sent.sql)
            if not name then
                problems[#problems + 1] = ('case %d statement %d is not one of the twelve: %q')
                    :format(case, index, tostring(sent.sql))
            else
                seen[name] = (seen[name] or 0) + 1
                local want = placeholders(REFERENCE[name])
                local params = sent.params
                local count = type(params) == 'table' and #params or -1
                if count ~= want then
                    problems[#problems + 1] = ('case %d: %s sent %d parameter(s) for %d placeholder(s)')
                        :format(case, name, count, want)
                end
                for slot = 1, want do
                    local value = type(params) == 'table' and params[slot] or nil
                    if type(value) ~= 'string' and type(value) ~= 'number' then
                        problems[#problems + 1] = ('case %d: %s parameter %d is %s')
                            :format(case, name, slot, tostring(value))
                    end
                end
            end
        end
        if #problems > 5 then break end
    end

    t.equals(#problems, 0, table.concat(problems, '\n'))
end)

t.test('and the corpus reached all twelve, so the rule above was tested against each', function()
    t.isTrue(corpusStatements > CASES, ('only %d statements in the whole corpus'):format(corpusStatements))
    for _, name in ipairs(NAMES) do
        t.isTrue((seen[name] or 0) > 0, name .. ' was never sent by any case')
    end
end)

-- ======================================================================
-- THE TWELVE LIVE IN ONE TABLE, AND EVERY NAME POINTS AT ONE OF THEM
-- ======================================================================

--- @param path string
--- @return string
local function read(path)
    local handle = assert(io.open(path, 'r'), ('%s is missing'):format(path))
    local text = handle:read('a')
    handle:close()
    return text
end

local AMMO = read('../Crimson-Arena/server/ammo.lua')

--- The lines of the file that are code: long comments blanked, and every
--- line whose first non-blank characters are `--` dropped.
local function codeLines(text)
    local out = {}
    local number = 0
    for line in (Sandbox.blankLongComments(text) .. '\n'):gmatch('(.-)\n') do
        number = number + 1
        if not line:find('^%s*%-%-') then out[#out + 1] = { number = number, text = line } end
    end
    return out
end

--- `SQL.NAME = ` definitions at the top level of the file, by name.
local function definitions()
    local defined, order = {}, {}
    for _, line in ipairs(codeLines(AMMO)) do
        local name = line.text:match('^SQL%.([%u_]+)%s*=')
        if name then
            defined[name] = (defined[name] or 0) + 1
            order[#order + 1] = { name = name, line = line.number }
        end
    end
    return defined, order
end

t.test('the statements are fields of one file-level SQL table, declared once, above all of them', function()
    local declared, anyLocal = {}, {}
    for _, line in ipairs(codeLines(AMMO)) do
        if line.text:find('^local SQL = {}%s*$') then declared[#declared + 1] = line.number end
        -- And no other local of that name anywhere, in any form: a second
        -- one -- `local SQL = SQL` above the slate's statements, say -- works
        -- exactly like the first and quietly spends a local on nothing,
        -- which is the one thing this table is for.
        if line.text:find('%f[%w_]local%s+[%w_,%s]*%f[%w_]SQL%f[^%w_]') then
            anyLocal[#anyLocal + 1] = line.number
        end
    end
    t.equals(#declared, 1, '`local SQL = {}` declarations at the top of the file')
    t.equals(table.concat(anyLocal, ','), table.concat(declared, ','), 'lines that declare a local SQL')

    -- ABOVE EVERY DEFINITION AND EVERY USE IN CODE. Above a use in a
    -- function body matters as much as above a definition: a closure
    -- compiled before the local exists reaches for a global SQL, which is
    -- nil when the statement is sent. ammo.lua's forward declarations say
    -- how nearly that shipped once already.
    local first = math.huge
    for _, line in ipairs(codeLines(AMMO)) do
        if line.text:find('%f[%w_]SQL%.[%u_]') then
            first = line.number
            break
        end
    end
    t.isTrue((declared[1] or math.huge) < first,
        ('SQL is declared at line %s, after its first use at line %s'):format(tostring(declared[1]), tostring(first)))
end)

t.test('the table holds exactly the twelve, each defined once, under the reference names', function()
    local defined = definitions()
    for _, name in ipairs(NAMES) do
        t.equals(defined[name], 1, ('SQL.%s definitions'):format(name))
    end
    for name in pairs(defined) do
        t.isNotNil(REFERENCE[name], ('SQL.%s is not one of the twelve this file checks -- add its reference'):format(name))
    end
end)

t.test('every SQL.NAME the file mentions, code or comment, is one it defines', function()
    -- A mistyped field is nil when it is sent, exactly as a mistyped local
    -- name was a nil global. The paths above catch it at run time; this
    -- catches it in a line no test reaches, and in the comments that point
    -- a reader at a statement.
    local defined = definitions()
    local strangers = {}
    for name in AMMO:gmatch('%f[%w_]SQL%.([%a_][%w_]*)') do
        if not defined[name] then strangers[#strangers + 1] = name end
    end
    t.equals(table.concat(strangers, ', '), '', 'names nothing defines')
end)

t.test('no statement is a file-level local of its own any more', function()
    -- THE ELEVEN LOCALS THIS GAVE BACK STAY GIVEN BACK. A thirteenth
    -- statement goes in the table with the others. Judged on what the value
    -- SAYS, not on what the local is called: a file-level local whose string
    -- opens with a SQL verb, on its own line or the next one.
    local VERB = { CREATE = true, INSERT = true, DELETE = true, SELECT = true, UPDATE = true, REPLACE = true }
    local function opensWithVerb(text)
        local verb = text and text:match('^%s*[\'"]?%s*(%u+)%f[^%u]')
        return verb ~= nil and VERB[verb] == true
    end

    local lines = {}
    for line in (Sandbox.blankLongComments(AMMO) .. '\n'):gmatch('(.-)\n') do lines[#lines + 1] = line end

    local locals = {}
    for index, text in ipairs(lines) do
        local name, rest = text:match('^local%s+([%w_]+)%s*=%s*(.-)%s*$')
        if name then
            local holds
            if rest == '' or rest:find('^%[=*%[$') then
                holds = opensWithVerb(lines[index + 1])
            else
                holds = opensWithVerb(rest)
            end
            if holds then locals[#locals + 1] = name end
        end
    end
    t.equals(table.concat(locals, ', '), '', 'file-level locals holding a statement')
end)

t.test('nothing still names the old per-statement locals: not the code, not a comment, not install.sql', function()
    local stale = {}
    for _, path in ipairs({ '../Crimson-Arena/server/ammo.lua', '../Crimson-Arena/sql/install.sql' }) do
        local text = read(path)
        for _, prefix in ipairs({ 'JAM', 'KIT' }) do
            for name in text:gmatch('%f[%w_](' .. prefix .. '_[%u_]+_SQL)%f[^%w_]') do
                stale[#stale + 1] = path:gsub('^%.%./', '') .. ': ' .. name
            end
        end
    end
    t.equals(table.concat(stale, '; '), '', 'stale names')
end)

t.test('SQL stays private to server/ammo.lua: no global of that name, and none of the old ones', function()
    local s = newArena()
    t.isNil(rawget(s.env, 'SQL'), 'SQL leaked into the global table')
    for _, name in ipairs(NAMES) do
        t.isNil(rawget(s.env, name .. '_SQL'), name .. '_SQL is a global')
    end
end)

t.test('sql/install.sql names, for each table, a Lua copy that exists and creates that table', function()
    -- install.sql's header lists each table next to the file and the name
    -- of its runtime CREATE TABLE, and tells an operator to keep the two in
    -- step. Nothing else checks that those names are real. A rename that
    -- missed this list would send the next person looking for a name that
    -- is not there.
    local install = read('../Crimson-Arena/sql/install.sql')
    local rows = 0
    for tableName, file, name in install:gmatch('\n%-%-%s+(crimson_arena_[%w_]+)%s+(server/[%w_]+%.lua)%s+([%w_%.]+)') do
        rows = rows + 1
        local source = read('../Crimson-Arena/' .. file)
        local escaped = name:gsub('%.', '%%.')
        local found = source:find('%f[%w_.]' .. escaped .. '%s*=%s*%[%[%s*CREATE TABLE IF NOT EXISTS '
            .. tableName .. '%f[^%w_]')
        t.isNotNil(found, ('install.sql says %s is created by %s in %s, and it is not'):format(tableName, name, file))
    end
    t.equals(rows, 4, 'tables install.sql lists a Lua copy for')
end)

os.exit(t.summary())
