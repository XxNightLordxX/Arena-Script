-- Crimson Arena: small helpers the rest of the server shares.

--[[
    crimson_arena/server/util.lua

    The primitives every other server file leans on: telling a player
    something, writing a line to the console, finding a player object,
    answering "is this person allowed to", and stopping a spammed event from
    running a hundred times a second.

    Nothing here decides anything about the arena itself. Rules live in
    shared/arena.lua and are read from there; this file only handles what a
    pure rule cannot -- sources, permissions, wall-clock time and IO.

    Everything defined at the top level is deliberately global. server/*.lua
    load in the order fxmanifest.lua lists, this file is first, and so every
    later file can call these without a require or an existence guard.
]]

local function compose(fmt, ...)
    if select('#', ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, fmt, ...)
    return ok and text or tostring(fmt)
end

function ArenaLog(fmt, ...)
    print(('[crimson_arena] %s'):format(compose(fmt, ...)))
end

function ArenaDebug(fmt, ...)
    if Config.Debug ~= true then return end
    print(('[crimson_arena] [debug] %s'):format(compose(fmt, ...)))
end

function ArenaNotify(src, description, notifyType, toast)
    local target = tonumber(src)
    if not target or target <= 0 then
        ArenaLog('refused to notify invalid source %s: %s', tostring(src), tostring(description))
        return false
    end

    TriggerClientEvent('crimson_arena:client:notify', target, {
        description = tostring(description or ''),
        type = notifyType or 'info',
        toast = toast == true,
    })
    return true
end

--- The same notification, forced into ox_lib's toast instead of the panel.
---
--- WHY THIS EXISTS AT ALL. ArenaUI.Notify paints into the arena panel while
--- that panel is open, which is right for everything said to a player who is
--- reading it -- and wrong for anything said in the same tick the panel is
--- torn down. sendEnterArena does exactly that: it notifies, then sends
--- closePanel a dozen lines later. A warning delivered that way is painted
--- into a surface that no longer exists, and the players it was written for
--- -- the ones who sat watching the panel until the match started -- are
--- precisely the ones who NEVER see it.
---
--- Use this only for that case. Everything else belongs in the panel.
function ArenaToast(src, description, notifyType)
    return ArenaNotify(src, description, notifyType, true)
end

function ArenaToastKey(src, localeKey, notifyType, ...)
    if not Arena.IsKey(localeKey) then
        ArenaLog('refused to notify %s with an empty locale key', tostring(src))
        return false
    end
    return ArenaToast(src, locale(localeKey, ...), notifyType)
end

function ArenaNotifyKey(src, localeKey, notifyType, ...)
    if not Arena.IsKey(localeKey) then
        ArenaLog('refused to notify %s with an empty locale key', tostring(src))
        return false
    end
    return ArenaNotify(src, locale(localeKey, ...), notifyType)
end

--- WRAPPED, because this is on the issue and exit hot paths now.
---
--- The owner stamp calls it for every fighter as their kit is handed over,
--- and the exit calls it again for every row it settles -- so a framework
--- that raises on an unknown source no longer costs one lookup, it takes
--- the whole round down mid-issue with a player half-armed.
---
--- A nil answer is what every caller already handles: they all read through
--- `player and player.PlayerData`. Callers that need to tell "nobody there"
--- from "the framework fell over" must NOT use this. DO NOT unwrap it.
function ArenaGetPlayer(src)
    local target = tonumber(src)
    if not target or target <= 0 then return nil end

    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(target) end)
    return ok and player or nil
end

function ArenaPlayerName(src)
    local target = tonumber(src)
    local player = ArenaGetPlayer(target)
    local data = player and player.PlayerData

    if data then
        local charinfo = data.charinfo
        if charinfo and Arena.IsKey(charinfo.firstname) then
            local surname = Arena.IsKey(charinfo.lastname) and (' ' .. charinfo.lastname) or ''
            return charinfo.firstname .. surname
        end
        if Arena.IsKey(data.name) then return data.name end
    end

    if target and target > 0 then
        local connected = GetPlayerName(target)
        if Arena.IsKey(connected) then return connected end
    end

    return locale('meta.unknown_player')
end

function ArenaIsAdmin(src)
    local target = tonumber(src)
    if not target then return false end
    if target == 0 then return true end

    for _, group in ipairs(Config.Permissions.adminGroups or {}) do
        if Arena.IsKey(group) then
            if IsPlayerAceAllowed(target, 'group.' .. group) or IsPlayerAceAllowed(target, group) then
                return true
            end
        end
    end
    return false
end

--- Whether `src` holds one of the jobs in one of Config.Permissions' job
--- lists.
---
--- An EMPTY list means EVERYONE -- the shipped default for both of them, and
--- the common case, so it is answered before any player lookup happens.
--- adminGroups reads the opposite way and is deliberately not routed through
--- here; ArenaIsAdmin above says why.
--- @param src any
--- @param jobs table? -- a Config.Permissions job list
--- @return boolean
local function jobAllowed(src, jobs)
    jobs = jobs or {}
    if Arena.Count(jobs) == 0 then return true end

    local player = ArenaGetPlayer(src)
    local job = player and player.PlayerData and player.PlayerData.job
    local name = job and job.name
    if not Arena.IsKey(name) then return false end

    if jobs[name] then return true end
    for _, allowed in ipairs(jobs) do
        if allowed == name then return true end
    end
    return false
end

function ArenaCanCreate(src)
    return jobAllowed(src, Config.Permissions.createJobs)
end

function ArenaCanJoin(src)
    return jobAllowed(src, Config.Permissions.joinJobs)
end

--- Timestamp of the last ACCEPTED call, per source, per bucket. Buckets
--- keep one spammed event from starving another: a player hammering
--- joinMatch must not also lock themselves out of leaveMatch.
local lastCall = {}

function ArenaRateLimit(src, bucket, intervalMs)
    local target = tonumber(src)
    if not target or target <= 0 then return false end

    local interval = Arena.ToInt(intervalMs) or 0
    if interval <= 0 then return true end

    local key = Arena.IsKey(bucket) and bucket or 'default'
    local now = GetGameTimer()

    local buckets = lastCall[target]
    if not buckets then
        buckets = {}
        lastCall[target] = buckets
    end

    local previous = buckets[key]
    if previous and (now - previous) < interval then return false end

    buckets[key] = now
    return true
end

function ArenaForgetPlayer(src)
    local target = tonumber(src)
    if target then lastCall[target] = nil end
end

function ArenaWebhook(title, description, fields)
    local webhook = Config.Webhook or {}
    if webhook.enabled ~= true then return end
    if not Arena.IsKey(webhook.url) then return end

    local list = (type(fields) == 'table' and #fields > 0) and fields or nil

    local payload = json.encode({
        username = webhook.username or Config.ResourceLabel,
        embeds = { {
            title = tostring(title or Config.ResourceLabel),
            description = description and tostring(description) or nil,
            color = Arena.ToInt(webhook.color) or 0,
            fields = list,
            footer = { text = Config.ResourceLabel },
            timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        } },
    })

    PerformHttpRequest(webhook.url, function(status)
        if status ~= 200 and status ~= 204 then
            ArenaDebug('webhook POST answered %s', tostring(status))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

local idSalt = math.random(0, 0xffff)
local idCounter = 0

function ArenaNewId()
    idCounter = idCounter + 1
    return ('m%04x%x'):format(idSalt, idCounter)
end

-- ======================================================================
-- OPENING HOURS
--
-- THE ONE PLACE THE CLOCK IS READ. Whether the arena is open is a rule, and
-- rules live in shared/arena.lua -- but reading a clock is not a rule, it is
-- a source, which is what this file is for.
--
-- IT IS THE SERVER'S OWN CLOCK, THROUGH os.date, AND NOTHING ELSE.
--
-- The client is never asked what time it is, and that is deliberate twice
-- over. A player's own clock is their machine's, so two players in
-- different countries would be told different opening times for the same
-- arena. And a number a client supplies is a number a client can choose:
-- everything else in this resource is decided on the server for exactly
-- that reason, and an opening hour is not the place to start making
-- exceptions.
--
-- The GAME clock is not read either, and config.lua says why at length: a
-- GTA day is 48 real minutes, so hours written on it are a different
-- feature to the one anybody pictures when they write them down.
-- ======================================================================

function ArenaHoursNow()
    local schedule = Config.Schedule
    local offset = 0
    if type(schedule) == 'table' then
        local wanted = Arena.ToInt(schedule.offsetHours)
        if wanted and math.abs(wanted) <= 14 then offset = wanted end
    end

    local now = os.date('*t')
    local minutes = (now.hour * 60 + now.min + offset * 60) % 1440
    return math.floor(minutes / 60), minutes % 60
end

--- An admin's standing decision about the doors, overriding the schedule.
---
--- THREE STATES, NOT TWO: 'open' holds them open past the schedule, 'shut'
--- closes them inside it, and nil hands the question back to the clock. Nil
--- is not a third kind of shut -- it is the absence of a decision, which is
--- why it is nil rather than a string.
---
--- IN MEMORY AND DELIBERATELY SO. It is a decision about tonight, not a
--- setting: a restart puts the schedule back in charge, which is the safe
--- direction to be wrong in. An override forgotten about is an arena that
--- quietly never opens -- or never shuts -- with nothing on any screen to
--- say why, and a restart is the one thing certain to be tried.
--- @type string|nil
local hoursOverride = nil

function ArenaSetHoursOverride(mode)
    hoursOverride = (mode == 'open' or mode == 'shut') and mode or nil
    return hoursOverride
end

function ArenaHoursOverride()
    return hoursOverride
end

function ArenaHoursOpen()
    if hoursOverride == 'open' then return true end
    if hoursOverride == 'shut' then return false end

    local status = Arena.ScheduleStatus(ArenaHoursNow())

    -- SHUT ONLY ON AN EXPLICIT `false`, and written that way on purpose.
    --
    -- `status.open == true` reads more naturally and is the same thing today,
    -- because Arena.ScheduleStatus sets `open` on every return path. The
    -- difference is which way each one fails if that ever stops being true:
    -- `== true` treats a missing answer as SHUT and takes the arena offline
    -- for everybody at once, and `~= false` treats it as OPEN. Fail open is
    -- the whole posture of this feature, so the guard is written in the
    -- direction that keeps it.
    return type(status) ~= 'table' or status.open ~= false
end

function ArenaHoursSnapshot()
    local hour, minute = ArenaHoursNow()
    local status = Arena.ScheduleStatus(hour, minute)
    local line = Arena.ScheduleLine()

    local block = { open = status.open == true, now = Arena.ClockText(hour * 60 + minute) }

    if hoursOverride ~= nil then
        block.open = hoursOverride == 'open'
        block.forced = hoursOverride
    end

    if line then block.line = line end
    if status.opensAt then block.opensAt = Arena.ClockText(status.opensAt) end
    if status.closesAt then block.closesAt = Arena.ClockText(status.closesAt) end
    return block
end

function ArenaHoursState()
    local schedule = Config.Schedule
    local raw = os.date('*t')
    local hour, minute = ArenaHoursNow()

    return {
        enabled = type(schedule) == 'table' and schedule.enabled == true,
        serverClock = ('%02d:%02d'):format(raw.hour, raw.min),
        offsetHours = type(schedule) == 'table' and (Arena.ToInt(schedule.offsetHours) or 0) or 0,
        arenaClock = Arena.ClockText(hour * 60 + minute),
        line = Arena.ScheduleLine(),
        open = ArenaHoursOpen(),
        forced = hoursOverride,
        snapshot = ArenaHoursSnapshot(),
    }
end

--- Whether a database query can be sent right now.
---
--- ONE GATE FOR THE WHOLE RESOURCE, because there were two and they had
--- already drifted. The leaderboard's copy warned once per PROCESS, so
--- oxmysql stopping later -- a restart, a crash -- went by in total silence
--- while every write was dropped; the outstanding-kit copy had been fixed to
--- re-arm and the other had not. Two implementations of the same rule can
--- only ever be in two states, and the state that matters is the one nobody
--- looked at. DO NOT write a third.
---
--- `subject` names what stops working, so the console line stays actionable
--- rather than generic, and it is also the key the warning is remembered
--- against -- so two subjects do not silence each other.
---
--- ox_inventory's own tables are NOT this. They exist whether the arena
--- persists anything or not, so the stash scan asks GetResourceState
--- directly and must not come through here.
--- @param subject string
--- @return boolean
local warnedNoDb = {}

function ArenaDbReady(subject)
    if Config.Database.enabled ~= true then return false end

    if GetResourceState('oxmysql') ~= 'started' then
        -- SAID ONCE PER OUTAGE, NOT ONCE PER PROCESS. An operator who turned
        -- the database on and has not started oxmysql needs telling; they do
        -- not need telling per write. It re-arms below the moment oxmysql
        -- answers again, so a SECOND outage is heard about too. DO NOT latch
        -- this flag for the life of the process.
        if not warnedNoDb[subject] then
            warnedNoDb[subject] = true
            ArenaLog('Config.Database.enabled is true but oxmysql is not started, so %s CANNOT be '
                .. 'saved. It works for this run only and a restart forgets it. Start oxmysql, '
                .. 'or set Config.Database.enabled = false.', subject)
        end
        return false
    end

    warnedNoDb[subject] = nil
    return true
end

--- Sends one query, and NEVER lets the database take the round down with it.
---
--- THE CALLBACK ALWAYS FIRES. On every path that does not reach oxmysql it
--- is called with nil, because callers use it to decide whether an answer
--- ever came -- and one that is silently never called is a load that retries
--- for ever or a flag that latches on a read that never happened. DO NOT add
--- a path that returns without calling it.
--- @param subject string -- as ArenaDbReady
--- @return boolean -- whether oxmysql actually took the query
function ArenaDb(subject, sql, params, cb)
    if not ArenaDbReady(subject) then
        if cb then cb(nil) end
        return false
    end

    -- WRAPPED, because a database that is up is not a database that answers.
    -- Losing the durable copy must NEVER take the round down with it: what
    -- is in memory is the live answer and this is the backup of it.
    local ok, err = pcall(function() exports.oxmysql:query(sql, params, cb) end)
    if not ok then
        ArenaLog('a query for %s could not be sent (%s). It is still kept in memory for this run.',
            subject, tostring(err))
        if cb then cb(nil) end
        return false
    end

    return true
end
