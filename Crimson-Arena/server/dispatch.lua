--[[
    crimson_arena/server/dispatch.lua

    The authoritative answer to "is this player in the arena right now",
    published for any other resource to read.

    WHY THIS LIVES ON THE SERVER. A dispatch script asking that question is
    deciding whether to suppress an alert, which makes the answer worth
    lying about: a replicated state bag written from the client can be
    written by ANY client, so a player who has never been near the arena
    could pin the flag on themselves and have your dispatch script quietly
    ignore them shooting up a bank. Only the server knows who is genuinely
    in a match, so only the server writes it.

    THREE FORMS OF THE SAME FACT, because dispatch scripts are written
    differently and none of these is more correct than the others:

      EVENTS -- this resource tells you, so you can keep your own ignore
      list without polling anything:
          AddEventHandler('crimson_arena:dispatch:enter', function(src, matchId) ... end)
          AddEventHandler('crimson_arena:dispatch:exit',  function(src, matchId) ... end)
      Names are Config.Dispatch.custom.enterEvent / exitEvent, and either can
      be set to nil to fire nothing. Both are SERVER events and are never
      sent to a client.


      STATE BAG -- replicated, readable from both realms with no call:
          -- server
          if Player(src).state.crimsonArena then return end
          -- client, about yourself
          if LocalPlayer.state.crimsonArena then return end

      EXPORTS -- for scripts that would rather ask:
          exports.crimson_arena:IsPlayerInArena(src)
          exports.crimson_arena:GetPlayerMatchId(src)
          exports.crimson_arena:GetArenaPlayers()

    The key is Config.Dispatch.stateBagKey, renameable for a server that
    already uses `crimsonArena` for something else.

    AND ONE THING IT DOES ENFORCE: ROUTING BUCKET ISOLATION. Everything above
    asks another resource to decline. The bottom half of this file does not
    ask anybody anything -- it moves every player in a match into a private
    network instance, where the arena is not replicated to anyone outside it.
    A dispatch or ambulance script running on some other player's client
    cannot see arena gunfire, arena bodies or arena entities, because that
    client is never sent them. See ROUTING BUCKET ISOLATION below.

    THE LIMIT OF THAT, PLAINLY: a bucket hides the arena from OTHER people's
    clients. It cannot hide an arena player's gunfire from their OWN client,
    so a dispatch script polling IsPedShooting on the shooter's machine still
    sees it. That is the case the flag above exists for, and it is why both
    halves of this file ship on.

    WHAT THIS FILE DOES NOT DO: suppress anything on somebody else's behalf.
    The silencing of the game's own police, and the trick that stops a
    medical script's polling loop ever seeing a dead player, are both
    client-side -- see client/dispatch.lua. The reporting half of this file
    exists so that the alerts THIS resource cannot reach can be declined at
    their source, by the resource that owns them, on the strength of a fact
    it can trust.
]]

ArenaDispatch = {}

--- Mirrors what has been written to each player's bag, so Clear() can be
--- called unconditionally without a bag read, and so GetArenaPlayers() does
--- not have to walk every connected player asking.
--- @type table<number, string>
local active = {}

--- @return table
local function customConfig()
    return (Config.Dispatch and Config.Dispatch.custom) or {}
end

--- @return string
local function stateKey()
    local key = customConfig().stateBagKey
    return type(key) == 'string' and key ~= '' and key or 'crimsonArena'
end

--- Fires one of the two announcement events, if the operator has named it.
---
--- SERVER events, never sent to a client: "who may be ignored by dispatch"
--- is not a decision a client gets a say in, and an event carrying that fact
--- to every player would be handing them the answer.
--- @param eventName any -- whatever the operator put in config; validated here
--- @param src number
--- @param matchId string
local function announce(eventName, src, matchId)
    if type(eventName) ~= 'string' or eventName == '' then return end

    -- pcall because this crosses into somebody else's handler: a dispatch
    -- script that throws must not take a match start or a match end down
    -- with it.
    local ok, err = pcall(TriggerEvent, eventName, src, matchId)
    if not ok then
        ArenaLog('a handler for "%s" errored: %s', eventName, tostring(err))
    end
end

-- ======================================================================
-- WRITING THE FACT
-- ======================================================================

--- Marks a player as being in `matchId`. Called when they are placed in the
--- arena, not when they join the lobby -- somebody sitting in a menu
--- choosing a rifle is not in a fight, and suppressing their alerts would
--- be a hole rather than a feature.
--- @param src number
--- @param matchId string
function ArenaDispatch.Set(src, matchId)
    if type(src) ~= 'number' or src <= 0 then return end
    if not Arena.IsKey(matchId) then return end

    active[src] = matchId
    Player(src).state:set(stateKey(), { active = true, matchId = matchId }, true)
    announce(customConfig().enterEvent, src, matchId)
end

--- Clears the flag. Deliberately unconditional and idempotent: it is called
--- from every exit path there is -- match end, elimination, leaving, an
--- admin stopping a match, a disconnect, the resource shutting down -- and
--- several of those can happen to the same player in quick succession.
--- A flag that outlives the match it belonged to would suppress that
--- player's alerts for the rest of their session.
--- @param src number
function ArenaDispatch.Clear(src)
    if type(src) ~= 'number' or src <= 0 then return end

    local matchId = active[src]
    active[src] = nil

    -- Announced even when nothing was set, so a dispatch script that missed
    -- the enter -- it restarted, it was not running yet -- still gets told to
    -- drop this player rather than keeping them ignored forever. A clear for
    -- somebody who was never flagged is a harmless no-op on its side.
    announce(customConfig().exitEvent, src, matchId)

    -- Guarded because a player who has already dropped has no state bag to
    -- write to, and the disconnect path reaches here after they are gone.
    local ok = pcall(function()
        Player(src).state:set(stateKey(), nil, true)
    end)
    if not ok then
        ArenaDebug('dispatch: could not clear the arena flag for %s -- they are most likely already gone.', tostring(src))
    end
end

-- ======================================================================
-- READING THE FACT
-- ======================================================================

--- @param src number
--- @return boolean
function ArenaDispatch.IsPlayerInArena(src)
    return active[src] ~= nil
end

--- @param src number
--- @return string|nil
function ArenaDispatch.GetPlayerMatchId(src)
    return active[src]
end

--- Every player currently in a match, as a server-id -> match-id map. A
--- copy, so a caller cannot edit this file's own record.
--- @return table<number, string>
function ArenaDispatch.GetArenaPlayers()
    local out = {}
    for src, matchId in pairs(active) do out[src] = matchId end
    return out
end

exports('IsPlayerInArena', function(src) return ArenaDispatch.IsPlayerInArena(src) end)
exports('GetPlayerMatchId', function(src) return ArenaDispatch.GetPlayerMatchId(src) end)
exports('GetArenaPlayers', function() return ArenaDispatch.GetArenaPlayers() end)

-- ======================================================================
-- ROUTING BUCKET ISOLATION
--
-- A routing bucket is a separate network instance: entities and events in
-- one do not replicate to players outside it. Every player in a match is
-- moved into one, which means every OTHER player's client -- and so every
-- dispatch or ambulance script running on one -- is never sent the arena at
-- all. There is nothing for them to detect and therefore nothing to report,
-- and none of it needs a line of cooperation from those scripts. It also
-- keeps passers-by out of a live round and stops arena gunfire being heard
-- across the map.
--
-- WHAT IT CANNOT DO, and this is not a shortcoming that can be engineered
-- away: it cannot hide an arena player's own gunfire from that player's OWN
-- client. A dispatch script polling IsPedShooting on the shooter's machine
-- still sees the shooter shooting. The flag above is the answer for that.
--
-- SERVER-SIDE ONLY, ALWAYS. A bucket is assigned here and never on a
-- client's say-so: a client that could pick its own instance could pick the
-- one a match it is not in is being fought in, which is a spectating cheat
-- and a griefing tool in the same request.
-- ======================================================================

--- Which instance each match is being fought in. matchId -> bucket number.
--- @type table<string, integer>
local matchBuckets = {}

--- Everyone this file has moved, and -- the load-bearing half -- the bucket
--- they were in BEFORE it moved them.
--- @type table<number, table>
local held = {}

--- Bucket 0 is the default world. A base below 1 would instance the entire
--- server into the arena rather than the other way round.
local DEFAULT_FIRST_BUCKET = 4210

--- @return table
local function isolationConfig()
    return (Config.Dispatch and Config.Dispatch.isolation) or {}
end

--- Opt-OUT rather than opt-in: an operator upgrading from a config that
--- predates this block gets the isolation, because it is the setting that
--- protects them without their dispatch script agreeing to anything.
--- @return boolean
local function isolationEnabled()
    return isolationConfig().enabled ~= false
end

--- Whether a bucket number is spoken for -- by a match, or by a player still
--- standing in one whose match has already gone.
---
--- The second half is the one that matters: handing a number out while
--- somebody is still in it drops a fresh match into the room they are
--- stranded in, which is the one failure a bucket allocator can have.
--- @param bucket integer
--- @return boolean
local function bucketInUse(bucket)
    for _, allocated in pairs(matchBuckets) do
        if allocated == bucket then return true end
    end
    for _, record in pairs(held) do
        if record.bucket == bucket then return true end
    end
    return false
end

--- Applies the bucket's own rules. Called ONCE, when the number is
--- allocated: these are properties of the instance and not of the players in
--- it, so re-applying them per join would be two native calls a player for
--- no change at all.
--- @param bucket integer
local function configureBucket(bucket)
    local config = isolationConfig()

    -- Off by default. An NPC that does not exist cannot witness a firefight,
    -- panic in front of one, or be run over into somebody's report.
    SetRoutingBucketPopulationEnabled(bucket, config.populationEnabled == true)

    -- 'relaxed' unless the operator has said otherwise, and config.lua says
    -- why next to the setting: a 'strict' bucket refuses client-created
    -- entities, and a weapon or prop being handed out IS one.
    local mode = config.lockdownMode
    if mode ~= 'strict' and mode ~= 'inactive' then mode = 'relaxed' end
    SetRoutingBucketEntityLockdownMode(bucket, mode)
end

--- The instance a match is fought in, allocating and configuring one the
--- first time it is asked for.
--- @param matchId string
--- @return integer|nil bucket -- nil when isolation is off, or the id is not one
function ArenaDispatch.GetBucket(matchId)
    if not isolationEnabled() then return nil end
    if not Arena.IsKey(matchId) then return nil end

    local existing = matchBuckets[matchId]
    if existing then return existing end

    local config = isolationConfig()
    local bucket = math.max(1, Arena.ToInt(config.firstBucket) or DEFAULT_FIRST_BUCKET)

    if config.perMatch ~= false then
        -- Counted up from the base to the first free number rather than
        -- taken from a counter that only ever climbs. A counter cannot reuse
        -- what finished matches gave back, so a server that runs for a week
        -- walks off into whatever range the rest of the box is using.
        while bucketInUse(bucket) do bucket = bucket + 1 end
    end

    matchBuckets[matchId] = bucket
    configureBucket(bucket)
    ArenaDebug('dispatch: match %s is instanced in routing bucket %d.', tostring(matchId), bucket)
    return bucket
end

--- Moves a player into their match's instance, remembering what they were in
--- beforehand.
---
--- CAPTURING THE CURRENT BUCKET IS THE POINT OF THIS FUNCTION. Restoring to
--- a hard-coded 0 on the way out is right only on a server that instances
--- nobody. On one that does -- an apartment interior, a heist, a per-job
--- world -- it would silently reassign the player to the default world when
--- they left the arena, and nothing would tell them or the operator that it
--- had happened.
--- @param src number
--- @param matchId string
--- @return boolean moved
function ArenaDispatch.EnterBucket(src, matchId)
    if type(src) ~= 'number' or src <= 0 then return false end

    local bucket = ArenaDispatch.GetBucket(matchId)
    if not bucket then return false end

    local current = held[src]
    if current then
        -- Already where they belong. Re-capturing here would record OUR
        -- bucket as the one to restore, which is how a player ends up living
        -- in an empty instance for the rest of their session.
        if current.bucket == bucket then return true end
        -- In some other match's instance. Restore first, so `previous` below
        -- is the bucket they originally came from rather than one of ours.
        ArenaDispatch.ExitBucket(src)
    end

    local previous = Arena.ToInt(GetPlayerRoutingBucket(src)) or 0

    -- A bucket this resource is running a match in is not somewhere anybody
    -- can legitimately have been beforehand: finding one means an earlier
    -- exit never ran. Sending them "back" there afterwards would strand them
    -- in an arena nobody is fighting in.
    if bucketInUse(previous) then
        ArenaDebug('dispatch: %s was already sitting in arena bucket %d -- they will be restored to the default world instead.',
            tostring(src), previous)
        previous = 0
    end

    held[src] = { bucket = bucket, previous = previous, matchId = matchId }
    SetPlayerRoutingBucket(src, bucket)
    return true
end

--- Puts a player back in exactly the bucket EnterBucket found them in, and
--- hands the match's number back once the last person has left it.
---
--- Idempotent, like Clear above and for the same reason: it is called from
--- every exit path there is, several of which can happen to one player in
--- quick succession.
--- @param src number
--- @return boolean restored
function ArenaDispatch.ExitBucket(src)
    if type(src) ~= 'number' or src <= 0 then return false end

    local record = held[src]
    if not record then return false end
    held[src] = nil

    -- Guarded the way Clear's bag write is: the disconnect path reaches here
    -- after the player has gone, and a native called against an id that no
    -- longer exists must not take the rest of the exit down with it.
    local ok = pcall(SetPlayerRoutingBucket, src, record.previous)
    if not ok then
        ArenaDebug('dispatch: could not restore routing bucket %d for %s -- they are most likely already gone.',
            record.previous, tostring(src))
    end

    ArenaDispatch.ReleaseBucket(record.matchId)
    return true
end

--- Gives a match's bucket number back to the pool.
---
--- REFUSES WHILE ONE OF THAT MATCH'S PLAYERS IS STILL IN IT, so a number is
--- never handed to a second match while somebody is standing in the room.
--- Called from ExitBucket on every leave -- so the common case frees itself
--- as the last player walks out -- and again by server/match.lua when a
--- match ends, which is what collects the bucket of a match everybody
--- disconnected from.
--- @param matchId string
--- @return boolean freed
function ArenaDispatch.ReleaseBucket(matchId)
    local bucket = matchBuckets[matchId]
    if not bucket then return false end

    -- Matched on the match id, not the number alone: with `perMatch` off
    -- every match shares one bucket, and another match's fighters standing
    -- in it must not keep this finished match's mapping alive forever.
    for _, record in pairs(held) do
        if record.bucket == bucket and record.matchId == matchId then return false end
    end

    matchBuckets[matchId] = nil
    ArenaDebug('dispatch: routing bucket %d released by match %s.', bucket, tostring(matchId))
    return true
end


-- A dispatch script that restarts mid-round comes back with an empty ignore
-- list and starts alerting on a fight already in progress. Operators name
-- those resources in Config.Dispatch.custom.resyncResources and every player
-- currently in an arena is re-announced the moment one comes back up.
AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then return end

    local watched = customConfig().resyncResources
    if type(watched) ~= 'table' then return end

    local wanted = false
    for _, name in ipairs(watched) do
        if name == resource then wanted = true break end
    end
    if not wanted then return end

    local count = 0
    for src, matchId in pairs(active) do
        announce(customConfig().enterEvent, src, matchId)
        count = count + 1
    end

    if count > 0 then
        ArenaLog('%s restarted -- re-announced %d player(s) still in an arena.', resource, count)
    end
end)

-- THE HANDLER THAT MATTERS MOST IN THIS FILE.
--
-- Two things must not survive this resource going away, and the second one
-- is the worse of the two by a distance.
--
-- The flag, because a dispatch script that outlives a restart would keep
-- reading a stale bag and keep suppressing alerts for players standing in
-- the middle of town.
--
-- And THE ROUTING BUCKETS. A bucket lives in the server, not in this
-- resource: stopping crimson_arena does not empty one. A player left behind
-- in an arena instance is alone in an invisible copy of the map -- no other
-- players, no traffic, nobody able to see them -- and there is nothing they
-- can do about it, because the only code that knows which bucket they came
-- from is the code that has just stopped. They cannot fix it, an admin
-- cannot easily see it, and reconnecting does not clear it. So every player
-- this file has moved goes back to the bucket it captured for them, first,
-- unconditionally, and before anything else in the shutdown can fail.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Buckets before flags: a flag left set is a bug in somebody else's
    -- script for one restart, a bucket left set is a player who cannot play.
    -- Assigning nil to a key that exists is defined during traversal, which
    -- is what lets ExitBucket clear its own entry as this walks.
    local restored = 0
    for src in pairs(held) do
        if ArenaDispatch.ExitBucket(src) then restored = restored + 1 end
    end
    if restored > 0 then
        ArenaLog('stopping: returned %d player(s) to the routing bucket they came from.', restored)
    end

    for src in pairs(active) do
        ArenaDispatch.Clear(src)
    end
end)


-- ======================================================================
-- BEST-EFFORT EVENT CANCELLING (Config.Dispatch.custom.cancelEvents)
--
-- THE WEAKEST LAYER IN THIS RESOURCE, AND IT IS LABELLED THAT WAY EVERYWHERE
-- IT APPEARS. An operator names the events their dispatch or ambulance script
-- raises to send an alert; this registers a handler on each and calls
-- CancelEvent() when it can establish that the alert is about somebody who is
-- in a match right now.
--
-- WHY IT IS ONLY BEST EFFORT, stated here as bluntly as config.lua states it.
-- CancelEvent() raises a flag and nothing else. The alert is still sent unless
-- the code that raised the event checks WasEventCanceled() afterwards and
-- decides to drop it, AND MANY SCRIPTS NEVER CHECK. On top of that, a script
-- that checks inside its own handler only sees the flag if this resource's
-- handler was registered first -- which is decided by resource start order in
-- server.cfg, and no resource can guarantee that about another. An operator
-- who leaves this list as their only integration should assume their alerts
-- are still going out. The state bag above is one line in the sending script
-- and it always works; this is for the case where that script cannot be
-- edited at all.
--
-- WHY IT NEVER GUESSES. Cancelling an alert about a player who has never been
-- near the arena is a real harm -- it is the silent hole the state bag's own
-- security note is written against, arrived at from the other direction. A
-- failure to suppress costs an operator an unwanted call-out; a wrong
-- suppression costs somebody a crime nobody was told about. So a firing this
-- cannot pin on an arena player is passed straight through, untouched, and
-- the name is printed once so the operator can fix the config.
--
-- WHY AddEventHandler AND NEVER RegisterNetEvent. RegisterNetEvent is what
-- makes an event triggerable by a client. Calling it on somebody else's
-- server-only event name would let ANY player fire that event -- turning a
-- feature meant to silence false alerts into a way to forge real ones. So
-- this only ever listens. An event the owning resource has not itself opened
-- to clients stays closed.
-- ======================================================================

--- The operator's list, from either of the two places it is plausibly
--- written. shared/compat/dispatch.lua counts the same two for its startup
--- report, so what is reported and what is registered cannot disagree.
--- @return table
local function cancelConfig()
    local list = customConfig().cancelEvents
    if type(list) ~= 'table' then
        list = Config.Dispatch and Config.Dispatch.cancelEvents
    end
    return type(list) == 'table' and list or {}
end

--- Reads one config entry into { event = string, playerArg = integer|nil }.
---
--- Accepts the three shapes an operator plausibly writes -- a bare event
--- name, a table carrying `event`, or a set keyed by event name -- because
--- these are exactly the three shared/compat/dispatch.lua's report counts. A
--- shape it counted and this refused would be a report promising a handler
--- that was never registered.
--- @param key any -- the table key, which IS the event name in the set shape
--- @param entry any
--- @return table|nil
local function readCancelEntry(key, entry)
    if Arena.IsKey(entry) then return { event = entry } end

    if type(entry) == 'table' and Arena.IsKey(entry.event) then
        -- Lua counts arguments from 1. A zero or negative index is not a
        -- smaller mistake than a missing one, so it is dropped rather than
        -- clamped -- an entry with no usable index cancels nothing, which is
        -- the safe direction.
        local index = Arena.ToInt(entry.playerArg)
        if index and index < 1 then index = nil end
        return { event = entry.event, playerArg = index }
    end

    if entry == true and Arena.IsKey(key) then return { event = key } end

    return nil
end

--- The server id one firing of an alert event can be pinned on, or nil for
--- "cannot tell", which is the answer that leaves the event alone.
--- @param entry table -- a normalised cancelEvents entry
--- @param ... any -- the event's own arguments, exactly as it was raised
--- @return number|nil src
local function responsibleFor(entry, ...)
    -- A PLAIN SERVER EVENT another resource raised. There is no player behind
    -- it, so the only trustworthy answer is the one the operator gave: they
    -- have said which argument names the player the alert is about.
    --
    -- Checked BEFORE `source` rather than as a fallback to it, and that order
    -- is the point. FiveM leaves `source` set to whoever triggered the
    -- outermost net event, so a server event raised deep inside an arena
    -- player's own call chain still carries their id -- even when the alert
    -- it is carrying is about somebody else entirely. A declared argument is
    -- a statement about THIS event and beats an ambient one every time.
    if entry.playerArg then
        local declared = Arena.ToInt((select(entry.playerArg, ...)))
        if declared and declared > 0 then return declared end
        return nil
    end

    -- A NET EVENT a client triggered. FXServer sets `source` to the server id
    -- of the client that sent it, and that is the one thing in this whole
    -- file a client cannot lie about -- it is stamped by the server, not
    -- carried in the payload. Anything that is not a positive integer means
    -- this was not a net event, and is treated as "cannot tell".
    local fromSource = Arena.ToInt(source)
    if fromSource and fromSource > 0 then return fromSource end

    return nil
end

--- Event names already warned about, so the warning below is once per name
--- for the life of the resource.
--- @type table<string, boolean>
local warnedCancel = {}

--- One console line, the first time an entry turns out to be unusable.
---
--- Once, and never per firing: an alert event on a busy server fires
--- constantly, and a warning printed every time would bury the console far
--- more effectively than the alerts it was trying to stop.
--- @param entry table
local function warnUnpinnable(entry)
    if warnedCancel[entry.event] then return end
    warnedCancel[entry.event] = true

    ArenaLog('cancelEvents: "%s" fired with no player behind it, so it was left alone. If that event carries a server id, say which argument it is -- { event = \'%s\', playerArg = 1 } -- or drop it from the list.',
        entry.event, entry.event)
end

--- Listens on one alert event.
---
--- Registered at LOAD time, which is as early as this resource can be: a
--- handler added later would sit behind the owning resource's own, and a
--- WasEventCanceled() check inside that handler would run before the flag
--- was ever raised. It is still only as early as crimson_arena itself
--- starts, which is why config.lua does not promise this works.
--- @param entry table
local function registerCancelHandler(entry)
    AddEventHandler(entry.event, function(...)
        local src = responsibleFor(entry, ...)
        if not src then
            warnUnpinnable(entry)
            return
        end

        -- The whole safety of this layer is this one line: cancel for a
        -- player this resource is currently holding in a match, and nobody
        -- else. Read from the server's own record -- the same one the state
        -- bag is written from -- and never from anything the event carried.
        if not ArenaDispatch.IsPlayerInArena(src) then return end

        CancelEvent()
        ArenaDebug('dispatch: raised the cancel flag on "%s" for %s, who is in match %s. It only stops the alert if that resource checks WasEventCanceled().',
            entry.event, tostring(src), tostring(active[src]))
    end)
end

-- Registration itself. Deliberately quiet when the list is empty, which is
-- how it ships: shared/compat/dispatch.lua's startup report is the one place
-- an operator is told how many of these are live, and a second line saying
-- the same thing at every boot is how a console stops being read.
do
    local registered = {}
    for key, entry in pairs(cancelConfig()) do
        local normalised = readCancelEntry(key, entry)
        if not normalised then
            ArenaLog('cancelEvents: skipped an entry that is not an event name, { event = ... } or [event] = true.')
        elseif registered[normalised.event] then
            -- Two handlers on one name would cancel the same event twice, to
            -- no extra effect, and double every diagnostic it prints.
            ArenaDebug('dispatch: cancelEvents names "%s" more than once -- the later entry was ignored.', normalised.event)
        else
            registered[normalised.event] = true
            registerCancelHandler(normalised)
        end
    end
end
