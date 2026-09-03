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

-- ======================================================================
-- CONSOLE
-- ======================================================================

--- A bad format string in a log line must never take down the code that was
--- only trying to explain itself, so a formatting failure degrades to the
--- raw template instead of raising.
--- @param fmt any
--- @param ... any
--- @return string
local function compose(fmt, ...)
    if select('#', ...) == 0 then return tostring(fmt) end
    local ok, text = pcall(string.format, fmt, ...)
    return ok and text or tostring(fmt)
end

--- Console line an operator will always see.
--- @param fmt string
--- @param ... any -- string.format arguments
function ArenaLog(fmt, ...)
    print(('[crimson_arena] %s'):format(compose(fmt, ...)))
end

--- The chatty half, gated on Config.Debug -- which ships ON. Off, this is a
--- single comparison at every call site; on, it is a line of console per
--- event, which is what it is there for.
--- @param fmt string
--- @param ... any
function ArenaDebug(fmt, ...)
    if Config.Debug ~= true then return end
    print(('[crimson_arena] [debug] %s'):format(compose(fmt, ...)))
end

-- ======================================================================
-- NOTIFICATIONS
-- ======================================================================

--- One player-visible message, handed to client/ui.lua to place.
---
--- SENT AS THIS RESOURCE'S OWN EVENT rather than straight to ox_lib because
--- WHERE it lands is a client-side question: ArenaUI.Notify puts it on the
--- panel's toast rail while the panel is up and falls through to ox_lib when
--- it is not. Triggering 'ox_lib:notify' from here answers that question for
--- it -- and answers it wrong for every refusal a player triggers from
--- inside the panel, which is most of them, since ox_lib draws its own toast
--- underneath the panel's full-screen scrim. The title comes back on the
--- ox_lib path in ArenaUI.Notify, so an arena message still names itself.
---
--- A nil, zero or negative source is a bug further up. TriggerClientEvent
--- would take it without complaint and the message would simply never
--- arrive, so it is refused out loud here rather than lost silently.
--- @param src any
--- @param description string
--- @param notifyType string? -- 'info'|'success'|'warning'|'error'
--- @return boolean sent
function ArenaNotify(src, description, notifyType)
    local target = tonumber(src)
    if not target or target <= 0 then
        ArenaLog('refused to notify invalid source %s: %s', tostring(src), tostring(description))
        return false
    end

    TriggerClientEvent('crimson_arena:client:notify', target, {
        description = tostring(description or ''),
        type = notifyType or 'info',
    })
    return true
end

--- The form almost every caller wants: Arena.* hands back locale KEYS, not
--- sentences, and they go straight through here.
--- @param src any
--- @param localeKey string
--- @param notifyType string?
--- @param ... any -- locale format arguments
--- @return boolean sent
function ArenaNotifyKey(src, localeKey, notifyType, ...)
    -- A nil key reaches here whenever a caller forwards a `reason` that was
    -- never set; locale() would raise on it, inside an event handler.
    if not Arena.IsKey(localeKey) then
        ArenaLog('refused to notify %s with an empty locale key', tostring(src))
        return false
    end
    return ArenaNotify(src, locale(localeKey, ...), notifyType)
end

-- ======================================================================
-- PLAYERS
-- ======================================================================

--- @param src any
--- @return table|nil player -- the qbx_core player object, nil if not loaded
function ArenaGetPlayer(src)
    local target = tonumber(src)
    if not target or target <= 0 then return nil end
    return exports.qbx_core:GetPlayer(target)
end

--- Never nil. The name ends up in log lines, webhooks and the panel, and a
--- nil in any of those is either an error or a blank row nobody can act on.
--- @param src any
--- @return string
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

    -- Connected but not loaded into qbx_core yet -- the account name is
    -- still better than nothing to log against.
    if target and target > 0 then
        local connected = GetPlayerName(target)
        if Arena.IsKey(connected) then return connected end
    end

    return locale('meta.unknown_player')
end

-- ======================================================================
-- PERMISSIONS
-- ======================================================================

--- ACE check against Config.Permissions.adminGroups.
---
--- Both spellings are tried because servers hand admin out both ways: a
--- `add_ace group.admin ...` line in a permissions.cfg, and a bare `admin`
--- ace from an admin menu that manages its own principals.
---
--- Source 0 is the server console, which cannot hold an ACE and must never
--- be locked out of its own admin command.
---
--- An EMPTY adminGroups list means NOBODY here, unlike the job lists below
--- it. Reading empty as "everyone" is right for an arena that is open to
--- the server; applied to force-stop and wipe it would hand every player
--- the ability to end other people's matches.
--- @param src any
--- @return boolean
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

    -- Operators write these lists both ways: { 'police' } and { police = true }.
    if jobs[name] then return true end
    for _, allowed in ipairs(jobs) do
        if allowed == name then return true end
    end
    return false
end

--- @param src any
--- @return boolean
function ArenaCanCreate(src)
    return jobAllowed(src, Config.Permissions.createJobs)
end

--- The same question asked of somebody joining a match they did not open.
--- One rule, two lists: a near-copy of the function above would let the two
--- permissions drift apart -- an operator who writes `{ police = true }` in
--- one and has it honoured, and writes it in the other and does not, has
--- found a bug rather than a setting.
--- @param src any
--- @return boolean
function ArenaCanJoin(src)
    return jobAllowed(src, Config.Permissions.joinJobs)
end

-- ======================================================================
-- RATE LIMITING
-- ======================================================================

--- Timestamp of the last ACCEPTED call, per source, per bucket. Buckets
--- keep one spammed event from starving another: a player hammering
--- joinMatch must not also lock themselves out of leaveMatch.
local lastCall = {}

--- @param src any
--- @param bucket string -- an event name, or anything stable
--- @param intervalMs any -- 0 or less means no limit
--- @return boolean allowed -- true when the caller may proceed
function ArenaRateLimit(src, bucket, intervalMs)
    -- A REAL PLAYER ID IS ALWAYS ABOVE ZERO, and everything else in this
    -- resource that takes one says so -- ArenaDispatch.Set and ArenaNotify
    -- above both refuse `<= 0`. This did not, so it was the one entry
    -- point that would open a bucket for an id no `playerDropped` will ever
    -- arrive for, and ArenaForgetPlayer is the only thing that clears one.
    --
    -- Not reachable from the wire: FXServer stamps `source` with a real
    -- player. It is consistency rather than a live defect, and the cost of
    -- being the odd one out is that the next person to read this has to work
    -- out which convention is the real one.
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

--- Drops one player's rate-limit history; main.lua calls it from
--- playerDropped. Without it `lastCall` gains a table per player who has
--- ever connected and never gives one back for the life of the resource.
--- @param src any
function ArenaForgetPlayer(src)
    local target = tonumber(src)
    if target then lastCall[target] = nil end
end

-- ======================================================================
-- WEBHOOK
-- ======================================================================

--- Posts one embed to the configured Discord webhook.
---
--- Fire and forget: the response is only ever looked at to say, under
--- Config.Debug, that Discord refused it. A match must never wait on an
--- HTTP round trip to somebody else's server.
--- @param title string
--- @param description string?
--- @param fields table[]? -- Discord embed fields: { { name, value, inline } }
function ArenaWebhook(title, description, fields)
    local webhook = Config.Webhook or {}
    if webhook.enabled ~= true then return end
    if not Arena.IsKey(webhook.url) then return end

    -- Discord rejects an embed whose `fields` is an empty object, which is
    -- exactly what json.encode makes of an empty Lua table.
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
        -- 204 is Discord's success for a webhook post; 200 covers proxies
        -- that answer with a body.
        if status ~= 200 and status ~= 204 then
            ArenaDebug('webhook POST answered %s', tostring(status))
        end
    end, 'POST', payload, { ['Content-Type'] = 'application/json' })
end

-- ======================================================================
-- IDS
-- ======================================================================

--- Both halves of a match id are load-bearing:
---   the counter makes a collision within one server run impossible, which
---   a random id of any length only makes unlikely;
---   the per-run salt stops a restart from re-issuing ids the previous run
---   already handed out -- a client can still be holding a snapshot full of
---   them, and would otherwise "join" an id that now belongs to somebody
---   else's lobby.
--- Base 16 keeps the result short enough to read out over a console line.
local idSalt = math.random(0, 0xffff)
local idCounter = 0

--- @return string id
function ArenaNewId()
    idCounter = idCounter + 1
    return ('m%04x%x'):format(idSalt, idCounter)
end
