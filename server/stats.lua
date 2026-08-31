--[[
    crimson_arena/server/stats.lua

    The leaderboard, and the only place this resource talks to a database.

    TWO MODES, ONE API. With Config.Database.enabled on, finished matches
    are folded into `crimson_arena_stats` and the leaderboard is all-time.
    With it off nothing is written anywhere, the same numbers live in a Lua
    table, and the leaderboard covers this server run only. Callers cannot
    tell which mode they are in: Record takes the same entry, GetLeaderboard
    hands the same rows to the same callback, and neither mode errors when
    the other's half of the machinery is missing.

    WRITES ARE QUEUED, NOT IMMEDIATE. A match end would otherwise fire one
    round trip per player at the exact moment the server is busiest -- the
    teleports, the payouts and the state broadcast all land in the same
    frame. The queue turns that into one batch per Config.Database
    flushIntervalMs.
]]

ArenaStats = {}

--- Rows recorded but not yet written, keyed by citizenid. These are DELTAS,
--- never totals: the upsert adds them to whatever the row already holds, so
--- a flush never has to read a row back first, and two servers sharing one
--- database cannot overwrite each other's numbers.
local pending = {}

--- Runs one query through oxmysql, or reports that it could not.
---
--- WHY THIS IS NOT `MySQL.query`. That name comes from `@oxmysql/lib/MySQL.lua`
--- in the manifest, and a manifest include is not optional: FXServer resolves
--- it before this file is ever read, so listing it would make oxmysql
--- mandatory for every install -- including the drag-and-drop default, where
--- Config.Database.enabled is false and this resource has no table, no query
--- and no reason to need a database at all. Going through the export instead
--- moves the question to run time, where the answer can be "not installed,
--- and that is fine".
---
--- Every caller is already behind a Config.Database.enabled check, so this
--- only ever reports a database that was switched ON and then not installed.
--- @param sql string
--- @param params table
--- @param cb fun(result: any)
--- @return boolean dispatched
local warnedNoDatabase = false

local function dbQuery(sql, params, cb)
    if GetResourceState('oxmysql') ~= 'started' then
        -- Said once. A flush sends one query per player, so an unguarded
        -- line here would print the same sentence eight times a minute and
        -- bury everything else in the console.
        if not warnedNoDatabase then
            warnedNoDatabase = true
            ArenaLog('Config.Database.enabled is true but oxmysql is not started. ' ..
                     'No stats are being written or read -- the leaderboard is this ' ..
                     'server run only. Install oxmysql, or set Config.Database.enabled = false.')
        end
        if cb then cb(nil) end
        return false
    end

    -- pcall because a database that is installed but unreachable throws out
    -- of the export rather than into the callback, and a throw here would
    -- take down the flush timer for the rest of the run.
    local ok, err = pcall(function()
        exports.oxmysql:query(sql, params, cb)
    end)

    if not ok then
        ArenaLog('a stats query could not be sent (%s). The numbers for this run are still kept in memory.',
            tostring(err))
        if cb then cb(nil) end
        return false
    end

    return true
end

--- Totals since the resource started. Kept in BOTH modes -- it is the
--- leaderboard when there is no database, and the answer when a query
--- cannot be answered.
local session = {}

-- MySQL 8 would rather this used a row alias than VALUES(), but MariaDB --
-- what most FiveM servers actually run -- has no alias syntax at all, and
-- VALUES() works on both.
local UPSERT_SQL = [[
    INSERT INTO crimson_arena_stats
        (citizenid, name, wins, losses, kills, deaths, earnings, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, NOW())
    ON DUPLICATE KEY UPDATE
        name = VALUES(name),
        wins = wins + VALUES(wins),
        losses = losses + VALUES(losses),
        kills = kills + VALUES(kills),
        deaths = deaths + VALUES(deaths),
        earnings = earnings + VALUES(earnings),
        updated_at = NOW()
]]

local SCHEMA_SQL = [[
    CREATE TABLE IF NOT EXISTS crimson_arena_stats (
        citizenid VARCHAR(64) NOT NULL,
        name VARCHAR(128) NOT NULL DEFAULT '',
        wins INT NOT NULL DEFAULT 0,
        losses INT NOT NULL DEFAULT 0,
        kills INT NOT NULL DEFAULT 0,
        deaths INT NOT NULL DEFAULT 0,
        earnings BIGINT NOT NULL DEFAULT 0,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (citizenid)
    )
]]

--- Adds one delta into a totals table, creating the row on first sight.
--- @param store table<string, table>
--- @param citizenid string
--- @param delta table
local function accumulate(store, citizenid, delta)
    local row = store[citizenid]
    if not row then
        row = { citizenid = citizenid, name = delta.name, wins = 0, losses = 0, kills = 0, deaths = 0, earnings = 0 }
        store[citizenid] = row
    end
    -- Characters get renamed; the most recent name is the useful one.
    row.name = delta.name
    row.wins = row.wins + delta.wins
    row.losses = row.losses + delta.losses
    row.kills = row.kills + delta.kills
    row.deaths = row.deaths + delta.deaths
    row.earnings = row.earnings + delta.earnings
end

--- The session table as leaderboard rows -- the same five fields, in the
--- same order, that the database query produces.
--- @param size integer
--- @return table[]
local function sessionRows(size)
    local ordered = {}
    for _, row in pairs(session) do ordered[#ordered + 1] = row end

    -- citizenid breaks the last tie, so `pairs` ordering can never make two
    -- reads of identical data render the panel differently.
    table.sort(ordered, function(a, b)
        if a.wins ~= b.wins then return a.wins > b.wins end
        if a.kills ~= b.kills then return a.kills > b.kills end
        if a.earnings ~= b.earnings then return a.earnings > b.earnings end
        return a.citizenid < b.citizenid
    end)

    local rows = {}
    for index = 1, math.min(size, #ordered) do
        local row = ordered[index]
        rows[index] = {
            name = row.name,
            wins = row.wins,
            kills = row.kills,
            deaths = row.deaths,
            earnings = row.earnings,
        }
    end
    return rows
end

--- Folds one player's finished match into the totals.
--- @param entry table -- { citizenid, name, won, kills, deaths, earnings }
--- @return boolean recorded -- false when there was no citizenid to key on
function ArenaStats.Record(entry)
    if type(entry) ~= 'table' or not Arena.IsKey(entry.citizenid) then return false end

    local delta = {
        -- Truncated to the column widths here rather than at write time: a
        -- MySQL in strict mode rejects an over-long value outright, and one
        -- long name would take the whole batch down with it.
        name = (Arena.IsKey(entry.name) and entry.name or entry.citizenid):sub(1, 128),
        -- There is no third outcome in this table. A player who was in a
        -- match and did not win it lost it.
        wins = entry.won == true and 1 or 0,
        losses = entry.won == true and 0 or 1,
        kills = math.max(0, Arena.ToInt(entry.kills) or 0),
        deaths = math.max(0, Arena.ToInt(entry.deaths) or 0),
        earnings = Arena.ToInt(entry.earnings) or 0,
    }

    accumulate(session, entry.citizenid, delta)
    if Config.Database.enabled == true then
        accumulate(pending, entry.citizenid, delta)
    end
    return true
end

--- Records every player of a finished match in one call.
---
--- It reads the match the way server/match.lua leaves it: `winners` is the
--- array of ids the win condition settled on, `payouts` is what
--- Arena.ComputePayouts returned. A `won` or `earnings` already written
--- onto a player record wins over both, so a mode that decides those for
--- itself does not have to fake a winners list to be recorded correctly.
--- @param match table -- a finished lobby record
--- @return integer recorded -- players folded in
function ArenaStats.RecordMatch(match)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return 0 end

    local won = {}
    for _, id in ipairs(match.winners or {}) do won[id] = true end

    -- A refund is a player's own stake handed back, not something they won,
    -- so it must never show up as earnings on an all-time leaderboard.
    local earned = {}
    for _, payout in ipairs(match.payouts or {}) do
        local reason = type(payout.reason) == 'string' and payout.reason or ''
        if payout.id ~= nil and not reason:find('^refund') then
            earned[payout.id] = (earned[payout.id] or 0) + (Arena.ToInt(payout.amount) or 0)
        end
    end

    local recorded = 0
    for src, player in pairs(match.players) do
        local id = player.src or src

        local outcome = player.won
        if outcome == nil then outcome = won[id] == true end

        local amount = player.earnings
        if amount == nil then amount = earned[id] or 0 end

        if ArenaStats.Record({
            citizenid = player.citizenid,
            name = player.name,
            won = outcome,
            kills = player.kills,
            deaths = player.deaths,
            earnings = amount,
        }) then
            recorded = recorded + 1
        end
    end

    return recorded
end

--- Hands the top rows to `cb`. Always calls back exactly once, in both
--- modes, with an array that may be empty -- never with nil, and never by
--- raising.
---
--- What the database returns is what the last flush left behind: a match
--- that ended seconds ago appears once the queue is written.
--- @param cb fun(rows: table[]) -- rows = { { name, wins, kills, deaths, earnings } }
function ArenaStats.GetLeaderboard(cb)
    if type(cb) ~= 'function' then return end

    local size = math.max(1, Arena.ToInt(Config.Database.leaderboardSize) or 25)

    if Config.Database.enabled ~= true then
        cb(sessionRows(size))
        return
    end

    -- LIMIT is spliced in rather than bound: a placeholder there is not
    -- portable across oxmysql's prepared path, and `size` has already been
    -- forced through Arena.ToInt, so there is no string to inject.
    local query = ([[
        SELECT name, wins, kills, deaths, earnings
        FROM crimson_arena_stats
        ORDER BY wins DESC, kills DESC, earnings DESC
        LIMIT %d
    ]]):format(size)

    dbQuery(query, {}, function(result)
        if type(result) ~= 'table' then
            -- The query could not be answered. This run's own numbers beat
            -- an empty panel and a client waiting on a callback that the
            -- error path never fired.
            cb(sessionRows(size))
            return
        end

        local rows = {}
        for _, row in ipairs(result) do
            rows[#rows + 1] = {
                name = row.name or '',
                wins = Arena.ToInt(row.wins) or 0,
                kills = Arena.ToInt(row.kills) or 0,
                deaths = Arena.ToInt(row.deaths) or 0,
                earnings = Arena.ToInt(row.earnings) or 0,
            }
        end
        cb(rows)
    end)
end

--- Writes everything queued and empties the queue.
---
--- main.lua calls this on resource stop as well as on the timer, and that
--- is the entire reason it is exported: a server that restarts 59 seconds
--- into a 60-second flush interval would otherwise throw away every match
--- played in that minute.
--- @return integer rows -- player rows dispatched
function ArenaStats.Flush()
    if Config.Database.enabled ~= true then return 0 end

    -- Swapped out before the first query goes out, so anything recorded
    -- while this runs queues for the next flush instead of being written
    -- twice or dropped.
    local batch = pending
    pending = {}

    local written = 0
    for citizenid, row in pairs(batch) do
        written = written + 1
        -- The empty callback is not decoration: without one oxmysql awaits
        -- the result, and a flush called from the resource-stop handler has
        -- to dispatch and return rather than block the stop.
        dbQuery(UPSERT_SQL, {
            citizenid:sub(1, 64),
            row.name,
            row.wins,
            row.losses,
            row.kills,
            row.deaths,
            row.earnings,
        }, function() end)
    end

    if written > 0 then ArenaDebug('flushed %d stat row(s)', written) end
    return written
end

--- Creates the table if it is not there. Safe on every start, and does
--- nothing at all when the database is off -- an operator running without
--- one never finds a table they did not ask for.
--- @return boolean ran
function ArenaStats.EnsureSchema()
    if Config.Database.enabled ~= true then return false end

    dbQuery(SCHEMA_SQL, {}, function()
        ArenaDebug('crimson_arena_stats is ready')
    end)
    return true
end

-- The flush timer. Only worth a thread when something can be queued: with
-- the database off, Record never fills `pending`. The floor stops a
-- flushIntervalMs of 0 from turning this into a per-frame loop.
if Config.Database.enabled == true then
    CreateThread(function()
        local interval = math.max(1000, Arena.ToInt(Config.Database.flushIntervalMs) or 60000)
        while true do
            Wait(interval)
            ArenaStats.Flush()
        end
    end)
end
