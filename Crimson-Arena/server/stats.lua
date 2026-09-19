-- Crimson Arena: the record. Wins, kills, streaks, and the database.

ArenaStats = {}

local pending = {}

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

        citizenid VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
        name VARCHAR(128) NOT NULL DEFAULT '',
        wins INT NOT NULL DEFAULT 0,
        losses INT NOT NULL DEFAULT 0,
        kills INT NOT NULL DEFAULT 0,
        deaths INT NOT NULL DEFAULT 0,
        earnings BIGINT NOT NULL DEFAULT 0,
        updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (citizenid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
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
        -- CUT ON A CHARACTER BOUNDARY, NOT A BYTE ONE. This was `:sub(1, 128)`,
        -- and a name mixing ASCII with multi-byte characters cut mid-character
        -- -- which MySQL refuses the whole row for. See ArenaCutText: the row
        -- then requeues on every flush for the rest of the run, in silence,
        -- so that player's statistics are never written and nothing says so.
        name = ArenaCutText(Arena.IsKey(entry.name) and entry.name or entry.citizenid, 128),
        wins = entry.won == true and 1 or 0,
        losses = entry.won == true and 0 or 1,
        kills = math.max(0, Arena.ToInt(entry.kills) or 0),
        deaths = math.max(0, Arena.ToInt(entry.deaths) or 0),
        -- CLAMPED LIKE THE TWO ABOVE IT. No producer can emit a negative
        -- today -- every settlement path was walked -- so this changes nothing
        -- any input can currently reach. It is here because the two lines
        -- above it clamp and this one did not, and a column that accumulates
        -- with `earnings + VALUES(earnings)` has no way back from a negative.
        earnings = math.max(0, Arena.ToInt(entry.earnings) or 0),
    }

    accumulate(session, entry.citizenid, delta)
    if Config.Database.enabled == true then
        accumulate(pending, entry.citizenid, delta)
    end
    return true
end

--- WHO HAS BEATEN WHOM, LATELY. { [citizenid] = { { set = 'A|B', at = 123 } } }
---
--- The repeat rule needs to know that this is the fourth time tonight you
--- have beaten the same two people. Kept in memory on purpose: it is a
--- fairness heuristic, not an accounting record, and a restart forgiving a
--- few repeats is a far smaller problem than a table nobody knew to migrate.
local recentWins = {}

--- How many matches since the whole history was last swept.
---
--- IT ONLY EVER PRUNED THE PEOPLE WHO CAME BACK. The repeat rule drops a
--- character's expired rows when it reads them, which keeps a regular's
--- history bounded -- and does nothing at all for the people who played once
--- and never returned. Nothing visits them again, so their rows sat there for
--- the life of the server. Measured: twenty thousand matches between pairs
--- who never came back retained 22 MB, about 1.1 KB a match, for ever. A
--- FiveM server is expected to run for weeks.
local sinceSweep = 0
local SWEEP_EVERY = 100

--- Drops every row the repeat window has rolled past, for everybody.
---
--- WHOLESALE, RATHER THAN PER CHARACTER, because the whole point is the
--- characters nobody is going to ask about. One pass over a table that is
--- bounded by the window itself, once every SWEEP_EVERY matches -- a cost
--- nobody can measure against a resource that is settling a round's money in
--- the same breath.
---
--- Setting a field to nil during `pairs` is the one mutation Lua guarantees
--- is safe mid-traversal, which is why the empty entries go here.
--- @param window integer -- the repeat window in seconds
local function sweepRankingHistory(window)
    local now = os.time()
    for id, rows in pairs(recentWins) do
        local kept = {}
        for _, row in ipairs(rows) do
            if now - row.at < window then kept[#kept + 1] = row end
        end
        recentWins[id] = (#kept > 0) and kept or nil
    end
end

--- The characters who fought a match, deduplicated and sorted.
---
--- BY CITIZEN ID, NOT BY SERVER ID. Two logins on one character is one
--- person, and counting the ids would make the smallest farm legal again.
---
--- `match.contestantIds` FIRST, and the fallback is only for a match that
--- never went live. ArenaMatch writes that list at go-live -- read the note
--- there -- and it is the honest answer to "who was in this round": the
--- table below is the roster at the END, and ArenaLobby.Leave takes a
--- quitter out of it. Judging on the leftovers would let one player's
--- disconnect strip a real three-way of its result, and would let a farm
--- rotate who walks out to keep changing the set the repeat rule keys on.
--- @return string[] ids, integer count
local function charactersIn(match)
    local listed = match.contestantIds
    if type(listed) == 'table' and #listed > 0 then
        -- DEDUPLICATED HERE TOO, not only in the fallback below.
        --
        -- ArenaMatch writes this list already deduplicated, so on every path
        -- that produces one honestly the loop below changes nothing -- which
        -- is exactly why it has to be here. The one thing this whole rule
        -- exists to refuse is one person counting as two, and leaving the
        -- guard to the writer means the rule holds only as long as every
        -- future writer remembers. It does not cost anything to be certain.
        local seen, copy = {}, {}
        for _, id in ipairs(listed) do
            if Arena.IsKey(id) and not seen[id] then
                seen[id] = true
                copy[#copy + 1] = id
            end
        end
        table.sort(copy)
        if #copy > 0 then return copy, #copy end
    end

    local seen, out = {}, {}
    for _, player in pairs(match.players or {}) do
        local id = player.citizenid
        if Arena.IsKey(id) and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out, #out
end

--- How long the round actually ran, in seconds, or nil when it never went
--- live.
---
--- `startsAt` MEANS TWO THINGS and this has to tell them apart. Begin sets it
--- to a time in the FUTURE -- the second the countdown is due to finish --
--- and goLive overwrites it with the second the round actually started. So a
--- match that died during its countdown still carries a `startsAt`, and
--- subtracting it from now gives a NEGATIVE number rather than a short round.
--- Negative is the tell, and it means nothing was fought at all.
local function secondsFought(match)
    local started = Arena.ToInt(match.startsAt) or 0
    if started <= 0 then return nil end
    local ran = os.time() - started
    if ran < 0 then return nil end
    return ran
end

--- Whether the repeat rule is switched on AND watching a roster this size.
---
--- TWO SEPARATE WAYS OF BEING OFF, and they mean different things. A ceiling
--- or a window of zero is an operator turning the rule off. `repeatAppliesUpTo`
--- is the rule declining to watch: a roster larger than that is not something
--- anybody can stage repeatedly, and applying the rule to it would stop
--- counting the rounds of the regulars who play together every evening --
--- which is the opposite of the job. See the note above Config.Leaderboard.
--- @param rules table
--- @param count integer -- how many characters were in the match
--- @return boolean
local function repeatRuleApplies(rules, count)
    if (Arena.ToInt(rules.maxPerOpponentSet) or 0) <= 0 then return false end
    if (Arena.ToInt(rules.repeatWindowMinutes) or 0) <= 0 then return false end

    local watched = math.max(0, Arena.ToInt(rules.repeatAppliesUpTo) or 0)
    if watched > 0 and count > watched then return false end

    return true
end

--- Whether this result should move anybody's ranking, and why not when it
--- should not.
---
--- NOTHING HERE STOPS A MATCH. The round has already happened, the money has
--- already moved and the kit is already back. This decides only whether the
--- board hears about it -- see the note above Config.Leaderboard.
--- @param match table
--- @return boolean ranked
--- @return string? why -- the reason it is not, for the log
local function rankedReason(match)
    local rules = Config.Leaderboard
    if type(rules) ~= 'table' or rules.rankedOnly ~= true then return true, nil end

    local characters, count = charactersIn(match)

    local floor = math.max(0, Arena.ToInt(rules.minFighters) or 0)
    if count < floor then
        return false, ('only %d character(s) fought it, and the board counts %d or more')
            :format(count, floor)
    end

    local shortest = math.max(0, Arena.ToInt(rules.minSeconds) or 0)
    if shortest > 0 then
        local ran = secondsFought(match)
        if ran == nil then
            return false, 'it never went live, so there is nothing to rank'
        end
        if ran < shortest then
            return false, ('it lasted %ds, and the board counts %ds or more'):format(ran, shortest)
        end
    end

    if not repeatRuleApplies(rules, count) then return true, nil end

    -- THE SAME PEOPLE, AGAIN. Keyed on the whole roster rather than on the
    -- loser, so three friends taking turns are one set and not three.
    local ceiling = math.max(0, Arena.ToInt(rules.maxPerOpponentSet) or 0)
    local window = math.max(0, Arena.ToInt(rules.repeatWindowMinutes) or 0) * 60
    local key = table.concat(characters, '|')
    local now = os.time()

    -- ASKED OF EVERY MEMBER, and answered by the first one that is full.
    --
    -- One row is written per character per counted match, so on a set that
    -- has not changed every member holds the same count and the loop is
    -- redundant. It stops being redundant the moment somebody's history
    -- differs -- a character who joined the group late has fewer rows than
    -- the regulars, and reading only the first would let the group carry on
    -- counting by keeping one fresh face in the lobby.
    for _, id in ipairs(characters) do
        local rows, kept = recentWins[id] or {}, {}
        local seenSet = 0
        for _, row in ipairs(rows) do
            if now - row.at < window then
                kept[#kept + 1] = row
                if row.set == key then seenSet = seenSet + 1 end
            end
        end
        recentWins[id] = kept
        if seenSet >= ceiling then
            return false, ('these same %d fighters have already counted %d time(s) in the last %d minute(s)')
                :format(count, seenSet, window // 60)
        end
    end

    return true, nil
end

--- Would this match move anybody's ranking, asked from outside?
---
--- FOR THE ONE ROW THAT DOES NOT COME THROUGH RecordMatch. ArenaLobby.Leave
--- records a fighter who walks out of a live round itself -- their row is
--- gone from the roster by the time the round ends, so RecordMatch will never
--- see them -- and that call went straight to Record, around the gate.
---
--- What it cost: two accounts, a four-second round, and the farmer presses
--- Leave before it settles. Every round is refused by minSeconds, the
--- surviving fighter is shown "This round does not count towards the ladder"
--- -- and the walker's KILL is written to the board anyway, one per round,
--- without limit. The board's second sort key is kills, so it climbs.
---
--- ASKED, NOT NOTED. This does not write anything down against the repeat
--- rule: the round is still being fought and RecordMatch will make that
--- decision properly when it ends. Reading the window prunes rows that have
--- expired, which is true whoever asks.
--- @param match table
--- @return boolean
function ArenaStats.WouldRank(match)
    if type(match) ~= 'table' then return true end
    return (rankedReason(match))
end

--- Writes this result down against the repeat rule, once it has counted.
local function noteRanked(match)
    local rules = Config.Leaderboard
    if type(rules) ~= 'table' or rules.rankedOnly ~= true then return end

    local characters, count = charactersIn(match)

    -- THE SAME PREDICATE THE RULE READS, and it has to be: a match written
    -- down that the rule will never look at is a row that can only ever fill
    -- somebody else's window up, and a match the rule WILL look at that was
    -- never written down is a free win every time.
    if not repeatRuleApplies(rules, count) then return end

    local key = table.concat(characters, '|')
    local now = os.time()
    for _, id in ipairs(characters) do
        recentWins[id] = recentWins[id] or {}
        table.insert(recentWins[id], { set = key, at = now })
    end
end

function ArenaStats.RecordMatch(match)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return 0 end

    -- DOES THIS RESULT MOVE ANYBODY'S RANKING?
    --
    -- Asked here and nowhere else, because this is the only door into the
    -- board that a whole match comes through. A round that does not qualify
    -- is not penalised and is not hidden: it was fought, it was paid, the
    -- results screen shows every number it always did. It simply writes
    -- nothing down -- no win, no loss, no kills, no earnings -- so it cannot
    -- be used to climb.
    --
    -- The answer rides home on the match so ArenaMatch.End can put it on the
    -- results screen. Telling the player is the point: a rule nobody is told
    -- about reads as the board being broken.
    -- AND THE HISTORY IS TIDIED, occasionally, from here.
    --
    -- HERE RATHER THAN IN noteRanked, which is the tempting place and the
    -- wrong one: noteRanked returns early whenever the repeat rule is off, so
    -- an operator who switched the rule off would have frozen whatever had
    -- already accumulated for the life of the server. This line runs for every
    -- finished match whatever the rules say.
    local rules = Config.Leaderboard
    sinceSweep = sinceSweep + 1
    if sinceSweep >= SWEEP_EVERY then
        sinceSweep = 0
        local window = 0
        if type(rules) == 'table' then
            window = math.max(0, Arena.ToInt(rules.repeatWindowMinutes) or 0) * 60
        end
        -- A window of zero is the rule switched off, and then EVERY row is
        -- expired -- which is exactly right: nothing is ever going to read
        -- them again.
        sweepRankingHistory(window)
    end

    local ranked, why = rankedReason(match)
    match.ranked = ranked
    match.rankedWhy = why

    if not ranked then
        ArenaDebug('leaderboard: match %s does not count -- %s', tostring(match.id), tostring(why))
        return 0
    end

    -- WRITTEN DOWN BEFORE THE ROWS ARE, and only when it counted. The repeat
    -- rule is what stops the patient farm, and it can only count results it
    -- was told about -- so a match that failed one of the rules above must
    -- not fill the window up as well, or two friends could keep a third
    -- honest pairing out of the board by playing four-second rounds.
    noteRanked(match)

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

    ArenaDb('the leaderboard', query, {}, function(result)
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
        if ArenaDb('the leaderboard', UPSERT_SQL, {
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

    ArenaDb('the leaderboard', SCHEMA_SQL, {}, function()
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
