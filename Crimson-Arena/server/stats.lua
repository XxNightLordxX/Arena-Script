-- Crimson Arena: the record. Wins, kills, streaks, and the database.

ArenaStats = {}

local pending = {}

local warnedNoDatabase = false

local function dbQuery(sql, params, cb)
    if GetResourceState('oxmysql') ~= 'started' then
        if not warnedNoDatabase then
            warnedNoDatabase = true
            ArenaLog('Config.Database.enabled is true but oxmysql is not started. ' ..
                     'No stats are being written or read -- the leaderboard is this ' ..
                     'server run only. Install oxmysql, or set Config.Database.enabled = false.')
        end
        if cb then cb(nil) end
        return false
    end

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

local session = {}

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

local MAX_RETAINED = 5000
local warnedQueueFull = false

local function accumulate(store, citizenid, delta)
    local row = store[citizenid]
    if not row then
        row = { citizenid = citizenid, name = delta.name, wins = 0, losses = 0, kills = 0, deaths = 0, earnings = 0 }
        store[citizenid] = row
    end
    row.name = delta.name
    row.wins = row.wins + delta.wins
    row.losses = row.losses + delta.losses
    row.kills = row.kills + delta.kills
    row.deaths = row.deaths + delta.deaths
    row.earnings = row.earnings + delta.earnings
end

local function sessionRows(size)
    local ordered = {}
    for _, row in pairs(session) do ordered[#ordered + 1] = row end

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

function ArenaStats.Record(entry)
    if type(entry) ~= 'table' or not Arena.IsKey(entry.citizenid) then return false end

    local delta = {
        name = (Arena.IsKey(entry.name) and entry.name or entry.citizenid):sub(1, 128),
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

function ArenaStats.RecordMatch(match)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return 0 end

    local won = {}
    for _, id in ipairs(match.winners or {}) do won[id] = true end

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

function ArenaStats.GetLeaderboard(cb)
    if type(cb) ~= 'function' then return end

    local size = math.max(1, Arena.ToInt(Config.Database.leaderboardSize) or 25)

    if Config.Database.enabled ~= true then
        cb(sessionRows(size))
        return
    end

    local query = ([[
        SELECT name, wins, kills, deaths, earnings
        FROM crimson_arena_stats
        ORDER BY wins DESC, kills DESC, earnings DESC
        LIMIT %d
    ]]):format(size)

    dbQuery(query, {}, function(result)
        if type(result) ~= 'table' then
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

function ArenaStats.Flush()
    if Config.Database.enabled ~= true then return 0 end

    local batch = pending
    pending = {}

    local room = MAX_RETAINED

    local function requeue(row)
        local existing = pending[row.citizenid]
        if not existing then
            if room <= 0 then
                if not warnedQueueFull then
                    warnedQueueFull = true
                    ArenaLog('more than %d players are waiting on a database write that keeps ' ..
                             'failing, so the oldest are now being dropped. Fix the database ' ..
                             'connection or set Config.Database.enabled = false.', MAX_RETAINED)
                end
                return
            end
            room = room - 1
        end

        local newerName = existing and existing.name
        accumulate(pending, row.citizenid, row)
        if newerName then pending[row.citizenid].name = newerName end
    end

    local dispatched = 0
    for citizenid, row in pairs(batch) do
        if dbQuery(UPSERT_SQL, {
            citizenid:sub(1, 64),
            row.name,
            row.wins,
            row.losses,
            row.kills,
            row.deaths,
            row.earnings,
        }, function(result)
            if result == nil then requeue(row) end
        end) then
            dispatched = dispatched + 1
        end
    end

    if dispatched > 0 then ArenaDebug('flushed %d stat row(s)', dispatched) end
    return dispatched
end

function ArenaStats.EnsureSchema()
    if Config.Database.enabled ~= true then return false end

    dbQuery(SCHEMA_SQL, {}, function()
        ArenaDebug('crimson_arena_stats is ready')
    end)
    return true
end

if Config.Database.enabled == true then
    CreateThread(function()
        local interval = math.max(1000, Arena.ToInt(Config.Database.flushIntervalMs) or 60000)
        while true do
            Wait(interval)
            ArenaStats.Flush()
        end
    end)
end
