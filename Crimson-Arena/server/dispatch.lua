-- Crimson Arena: keeping arena gunfire off the city call system.

ArenaDispatch = {}

local active = {}

local function customConfig()
    return (Config.Dispatch and Config.Dispatch.custom) or {}
end

local function stateKey()
    local key = customConfig().stateBagKey
    return type(key) == 'string' and key ~= '' and key or 'crimsonArena'
end

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

    local ok = pcall(function()
        Player(src).state:set(stateKey(), nil, true)
    end)
    if not ok then
        ArenaDebug('dispatch: could not clear the arena flag for %s -- they are most likely already gone.', tostring(src))
    end

    announce(customConfig().exitEvent, src, matchId)
end

-- ======================================================================
-- THIS RESOURCE ASKS THE SERVER FOR NO PERMISSIONS, AND RUNS NO COMMANDS
--
-- A server that lets a resource write its own permissions has no
-- permissions, so this one does not ask for any and has no route that would
-- need them: it runs nothing on the server console and has no client channel
-- for running anything. The medical handoff is events and exports -- things
-- a script publishes on purpose for other scripts to call, needing no
-- permission from anybody. NOTHING CHECKS THIS ANY MORE -- the test that
-- failed the build if any source file reached for the permission natives was
-- retired with the rest of the suite -- so it is on whoever edits this file.
-- ======================================================================

local function downStateConfig()
    return (Config.Dispatch or {}).downState or {}
end

local function clearDownMetadata(src)
    local keys = downStateConfig().keys
    if type(keys) ~= 'table' or #keys == 0 then return 0 end

    if type(ArenaGetPlayer) ~= 'function' then return 0 end

    local player = ArenaGetPlayer(src)
    local functions = player and player.Functions
    if type(functions) ~= 'table' then return 0 end
    if type(functions.SetMetaData) ~= 'function' then return 0 end

    local cleared = 0
    for _, key in ipairs(keys) do
        if Arena.IsKey(key) then
            local current = true
            if type(functions.GetMetaData) == 'function' then
                local ok, value = pcall(functions.GetMetaData, key)
                current = ok and value or false
            end

            if current then
                local ok, err = pcall(functions.SetMetaData, key, false)
                if ok then
                    cleared = cleared + 1
                    ArenaDebug('revive: cleared \'%s\' metadata for %d.', key, src)
                else
                    ArenaLog('revive: could not clear \'%s\' metadata for %d (%s).',
                        key, src, tostring(err))
                end
            end
        end
    end

    return cleared
end

--- Puts the medical script's "this player is down" flags back down, now.
---
--- THE BUG THIS EXISTS TO CLOSE, and it is the one that actually produces
--- the calls an operator sees. The flags were only ever cleared from
--- ArenaDispatch.Revive, and on the path a fighter takes MOST -- dying with
--- lives left -- that runs `respawnDelaySeconds` (5s) plus
--- `afterRespawnDelayMs` (2000ms) after the death. Seven seconds. Against a
--- dispatch client polling that metadata every 500ms, that is fourteen
--- windows: PlayerDown and PlayerDead were not "never raised", they were
--- CERTAIN, on every death of every round, while the config beside them
--- claimed prevention.
---
--- Called at the moment of death rather than at the end of the respawn, and
--- backed by the hold below, the window shrinks from seven seconds to less
--- than one poll.
--- @param src number
--- @return integer cleared
function ArenaDispatch.ClearDownState(src)
    return clearDownMetadata(src)
end

--- HOLDING THEM DOWN, because clearing once is not the same as keeping
--- clear.
---
--- A medical script does not set its flag once and stop. It sets it from the
--- victim's own client at the moment of death, and several of them re-assert
--- it -- on a respawn, on a poll of their own, on a resource restart. One
--- clear at one instant answers one of those. So while a player is in a
--- match the arena re-asserts the answer on its own clock, which is a wall
--- clock and not a race: it does not matter who wrote last, only that the
--- arena writes again within the poll window.
---
--- WHAT IT IS NOT. It is not a guarantee and must never be described as one.
--- A dispatch client polling on its own 500ms timer can still catch the flag
--- inside this interval, and sc-ambulance's own EMSDownAlert is sent from
--- the victim's client back-to-back with the flag it reads, so no
--- server-side clear can arrive before its guard. What this removes is the
--- CERTAIN loss above; what is left is a narrow one.
---
--- Guarded on `active` rather than on a list of its own, so it can never
--- outlive a match: ArenaDispatch.Clear empties that table on every exit
--- path there is, and a flag held down for a player who has gone home is the
--- exact failure Clear was written to prevent.
--- One pass: the flags put back down for everybody currently in a match.
---
--- SEPARATED FROM THE THREAD ON PURPOSE, and for the same reason
--- ArenaAmmo.SweepReturns is: a `while true` loop is not a thing a test can
--- drive, so the loop is one line and the work is a function, and what gets
--- tested is the work.
--- @return integer touched -- players whose flags were actually written
function ArenaDispatch.HoldDownState()
    local touched = 0
    for src in pairs(active) do
        if clearDownMetadata(src) > 0 then touched = touched + 1 end
    end
    return touched
end

CreateThread(function()
    local interval = Arena.ToInt(downStateConfig().holdIntervalMs) or 0
    if interval <= 0 then return end

    while true do
        Wait(interval)
        ArenaDispatch.HoldDownState()
    end
end)

function ArenaDispatch.Revive(src)
    if type(src) ~= 'number' or src <= 0 then return end

    -- THE ARENA DOES NOT STAND PLAYERS UP HERE, and that is deliberate.
    -- Resurrecting the ped from this function would make it a second writer
    -- for a body the medical script also has an opinion about, racing
    -- whatever that script does next. Two resources arguing over one ped is
    -- not a revive; it is a flicker with a winner.
    --
    -- NOTHING IS LEFT ON THE FLOOR BY LEAVING IT OUT. ClearDeadState already
    -- resurrects in the frame the ped dies -- that is death handling, not a
    -- revive, and it is what keeps the death from registering anywhere at all
    -- -- and the respawn releases that hold and re-applies the loadout, which
    -- starts every life on full health and a full plate by rule. A player is
    -- stood up by the arena's ordinary flow either way.
    --
    -- What this function does is the half the arena genuinely cannot: reach a
    -- MEDICAL SCRIPT's own records, which it cannot see and will not guess at.

    if type(ArenaCompat) == 'table' and type(ArenaCompat.ReviveClientEvents) == 'function' then
        for _, name in ipairs(ArenaCompat.ReviveClientEvents()) do
            TriggerClientEvent(name, src)
            ArenaDebug('revive: also told %s for %d.', name, src)
        end
    end

    TriggerClientEvent('crimson_arena:client:holdVitals', src)

    clearDownMetadata(src)

end

RegisterCommand('arenarevive', function(src, args)
    if type(ArenaIsAdmin) ~= 'function' or not ArenaIsAdmin(src) then
        if src ~= 0 and type(ArenaNotifyKey) == 'function' then
            ArenaNotifyKey(src, 'error.no_permission', 'error')
        end
        return
    end

    local target = Arena.ToInt(args and args[1]) or (src > 0 and src or nil)
    if not target or target <= 0 then
        ArenaLog('arenarevive: give a server id -- /arenarevive 3.')
        return
    end

    ArenaLog('arenarevive: running the end-of-match revive against %d. Everything below is what a real match would do.',
        target)
    ArenaDispatch.Revive(target)

    local told = 0
    if type(ArenaCompat) == 'table' and type(ArenaCompat.ReviveClientEvents) == 'function' then
        told = #ArenaCompat.ReviveClientEvents()
    end

    if told > 0 then
        ArenaLog('arenarevive: done. %d\'s down metadata was cleared and %d medical script(s) were asked to revive them.',
            target, told)
        ArenaLog('arenarevive: if %d is up but something still treats them as dead, that script is not in the catalogue in shared/compat/dispatch.lua -- add it there with the revive event it listens for.',
            target)
    else
        ArenaLog('arenarevive: done. %d\'s down metadata was cleared. No medical script was detected on this box, so none was asked to revive them.',
            target)
    end
end, false)

function ArenaDispatch.IsPlayerInArena(src)
    return ArenaDispatch.GetPlayerMatchId(src) ~= nil
end

function ArenaDispatch.GetPlayerMatchId(src)
    local id = tonumber(src)
    if not id then return nil end
    return active[id]
end

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

local matchBuckets = {}

local netIdOwners = {}

--- The network id of a player's ped right now, or nil for a player who has
--- gone. Guarded because it is asked on the path of every shot fired on the
--- server, and a player who disconnected mid-burst must not take that path
--- down with them.
--- @param src number
--- @return integer|nil
local function netIdOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotId, netId = pcall(NetworkGetNetworkIdFromEntity, ped)
    if not gotId then return nil end

    netId = tonumber(netId)
    if not netId or netId == 0 then return nil end
    return netId
end

local held = {}

local DEFAULT_FIRST_BUCKET = 4210

local function isolationConfig()
    return (Config.Dispatch and Config.Dispatch.isolation) or {}
end

local function isTruthy(value)
    value = tostring(value):lower()
    return value == 'true' or value == '1' or value == 'yes' or value == 'on'
end

--- The other half, and deliberately not `not isTruthy(...)`: a mode name this
--- file has never heard of is neither a yes nor a no, and must not be read as
--- a refusal.
--- @param value any
--- @return boolean
local function isFalsey(value)
    value = tostring(value):lower()
    return value == 'false' or value == '0' or value == 'no' or value == 'off'
end

--- Whether this server has OneSync on, and in which mode.
---
--- ROUTING BUCKETS REQUIRE ONESYNC, AND THIS RESOURCE NEVER ASKED. With it
--- off, SetPlayerRoutingBucket and the SetRoutingBucket* natives do nothing
--- at all -- no error, no return value, no warning. Every line of the
--- allocation below still runs and still looks right; the players simply are
--- not separated. Two matches at one arena then stand in each other, which
--- is precisely what an operator reported.
---
--- Worse than the failure is that the startup report SAID isolation was on,
--- because it read the config setting rather than the world. A guarantee
--- printed to an operator who does not have it is the defect class this
--- codebase keeps producing.
---
--- Two spellings, because builds differ: modern servers answer the single
--- `onesync` convar ('off' / 'legacy' / 'on' / 'infinity'), older ones the
--- pair below.
---
--- AND A CONVAR BOOLEAN IS NOT THE STRING 'true'. `set onesync_enabled 1` is
--- the spelling half the guides on the internet use, and `yes` and `on` both
--- appear in the wild -- GetConvar hands back whatever the operator typed,
--- verbatim. Comparing against 'true' alone read every one of those as OFF,
--- which switched isolation off on servers that had OneSync running, and did
--- it in the one direction nobody notices: quietly, on a server whose
--- startup line then said so in a report nobody re-reads.
--- @return string mode
local function oneSyncMode()
    if type(GetConvar) ~= 'function' then return 'unknown' end

    -- RETURNED VERBATIM, whatever it says. Some builds answer this one as a
    -- mode name and some as a boolean, and tidying the booleans up here
    -- would put a second opinion about what counts as a no in a second
    -- place -- which is how the older pair below came to disagree with
    -- bucketsAvailable in the first place. One reader decides that, and it
    -- is isFalsey. What this function is for is telling an operator what
    -- their server actually said.
    local mode = GetConvar('onesync', '')
    if mode ~= '' then return mode end

    if isTruthy(GetConvar('onesync_enableInfinity', 'false')) then return 'infinity' end
    if isTruthy(GetConvar('onesync_enabled', 'false')) then return 'legacy' end
    return 'off'
end

local warnedNoOneSync = false

--- SET WHEN THE SERVER HAS BEEN CAUGHT NOT HONOURING A BUCKET, and never
--- cleared while the resource runs.
---
--- THE DEFECT CLASS THIS EXISTS TO END. Everything above this line asks the
--- server a QUESTION -- which convar is set, what mode does it name -- and
--- then trusts the answer for the rest of the run. An operator reported
--- twice that matches were still sharing a world while every one of those
--- questions answered yes, and there was no line anywhere in the resource
--- that could have told them otherwise: the allocation ran, the move ran,
--- the log said the match was instanced, and the players stood in each
--- other. A convar is what the server was CONFIGURED with; whether a routing
--- bucket actually took is a different fact, and the only honest way to
--- learn it is to set one and read it back.
local provenInert = false

local function bucketsAvailable()
    if provenInert then return false end

    local mode = oneSyncMode()
    if not isFalsey(mode) then return true end

    if not warnedNoOneSync then
        warnedNoOneSync = true
        ArenaLog('ISOLATION IS NOT AVAILABLE: this server has OneSync off, and routing buckets need it -- ' ..
            'the natives that instance a match do nothing without it, silently. Matches will be fought in the ' ..
            'open world where every client can see them, and two matches cannot share one arena. Set ' ..
            '`set onesync on` in server.cfg (and restart) to get it back.')
    end
    return false
end

local function isolationEnabled()
    if isolationConfig().enabled == false then return false end
    return bucketsAvailable()
end

local function bucketInUse(bucket)
    for _, allocated in pairs(matchBuckets) do
        if allocated == bucket then return true end
    end
    for _, record in pairs(held) do
        if record.bucket == bucket then return true end
    end
    return false
end

local function currentBucket(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return Arena.ToInt(bucket) or 0
end

local function stillConnected(src)
    if type(GetPlayerName) ~= 'function' then return false end
    local ok, name = pcall(GetPlayerName, src)
    if not ok then return false end
    return type(name) == 'string' and name ~= ''
end

--- Moves one player into a bucket AND PROVES IT LANDED.
---
--- SETTING A ROUTING BUCKET IS NOT A REQUEST. It is a synchronous write to a
--- field the server keeps for that client, so on a server where buckets work
--- the read below always agrees with the write above -- there is no race to
--- lose and no tick to wait for. Which is what makes the disagreement worth
--- acting on: it does not mean "not yet", it means the natives are not doing
--- anything, and every promise this resource makes about instancing is
--- already false.
---
--- WHAT IT DOES WITH THAT. It says so once, loudly, in the operator's console
--- rather than in a debug channel they would have to switch on -- and then it
--- stops claiming isolation for the rest of the run. That second half is the
--- important one: with `provenInert` set, GetBucket answers nil, and the
--- guard in server/match.lua refuses to start a second match at an arena
--- somebody is already fighting in. Two rounds sharing a platform is the
--- symptom an operator sees; refusing the second one is the fallback this
--- codebase already had, and it was never reachable because nothing could
--- tell that it was needed.
--- @param src number
--- @param bucket integer
--- @return boolean landed
local function moveTo(src, bucket)
    pcall(SetPlayerRoutingBucket, src, bucket)

    if currentBucket(src) == bucket then return true end

    -- A player who has gone cannot be moved and cannot be read back, and
    -- neither says anything about whether buckets work here. Asked only
    -- AFTER the reading disagrees, because a move that landed needs no
    -- alibi.
    if not stillConnected(src) then return false end

    provenInert = true
    ArenaLog('ISOLATION IS NOT IN FORCE, AND THIS SERVER JUST PROVED IT: %s was put into routing ' ..
        'bucket %d and the server still reports them in %d. The routing natives are not doing anything ' ..
        'here, so matches are being fought in the open world where every client can see them. The usual ' ..
        'cause is OneSync -- `set onesync on` in server.cfg, then restart -- and the server currently ' ..
        'reports onesync as "%s". Until that is fixed the arena will refuse to start a second match at ' ..
        'an arena somebody is already fighting in, because it can no longer keep the two apart.',
        tostring(src), bucket, currentBucket(src), tostring(oneSyncMode()))
    return false
end

local function configureBucket(bucket)
    local config = isolationConfig()

    SetRoutingBucketPopulationEnabled(bucket, config.populationEnabled == true)

    local mode = config.lockdownMode
    if mode ~= 'strict' and mode ~= 'inactive' then mode = 'relaxed' end
    SetRoutingBucketEntityLockdownMode(bucket, mode)
end

function ArenaDispatch.GetBucket(matchId)
    if not isolationEnabled() then return nil end
    if not Arena.IsKey(matchId) then return nil end

    local existing = matchBuckets[matchId]
    if existing then return existing end

    local config = isolationConfig()
    local bucket = math.max(1, Arena.ToInt(config.firstBucket) or DEFAULT_FIRST_BUCKET)

    if config.perMatch ~= false then
        while bucketInUse(bucket) do bucket = bucket + 1 end
    end

    matchBuckets[matchId] = bucket
    configureBucket(bucket)
    ArenaDebug('dispatch: match %s is instanced in routing bucket %d.', tostring(matchId), bucket)
    return bucket
end

function ArenaDispatch.EnterBucket(src, matchId)
    if type(src) ~= 'number' or src <= 0 then return false end

    local bucket = ArenaDispatch.GetBucket(matchId)
    if not bucket then return false end

    local current = held[src]
    if current then
        if current.bucket == bucket then
            -- OURS ON PAPER IS NOT THE SAME AS ACTUALLY BEING THERE, and
            -- reading the record instead of the world is how isolation goes
            -- quietly missing.
            --
            -- A routing bucket is server-wide state that any resource can
            -- set. An interior, a job, a heist, an admin tool, or simply
            -- another script's own cleanup can move a player out of the
            -- match's instance, and nothing tells this file. The record
            -- still says they are where they belong, so every later pass
            -- agrees there is nothing to do -- and the player fights the
            -- rest of the round in the ordinary world, in front of the
            -- whole server, with the arena's one real defence against
            -- dispatch scripts simply absent.
            --
            -- `previous` is deliberately NOT re-captured. Where they came
            -- from has not changed just because somebody moved them since,
            -- and taking the reading now would record whatever instance
            -- they drifted into as the place to send them home to.
            if currentBucket(src) ~= bucket then
                ArenaDebug('dispatch: %s had drifted out of arena bucket %d -- putting them back.',
                    tostring(src), bucket)
                moveTo(src, bucket)
            end
            return true
        end
        ArenaDispatch.ExitBucket(src)
    end

    local previous = currentBucket(src)

    if bucketInUse(previous) then
        ArenaDebug('dispatch: %s was already sitting in arena bucket %d -- they will be restored to the default world instead.',
            tostring(src), previous)
        previous = 0
    end

    held[src] = { bucket = bucket, previous = previous, matchId = matchId }

    return moveTo(src, bucket)
end

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

--- What isolation is ACTUALLY doing right now, for the startup report and
--- for /arenaisolation.
---
--- Three separate facts, kept separate on purpose, because an operator
--- reading "isolation: off" cannot act on it without knowing which of the
--- three said no.
--- @return table
function ArenaDispatch.IsolationState()
    return {
        wanted = isolationConfig().enabled ~= false,
        oneSync = oneSyncMode(),
        provenInert = provenInert,
        inForce = isolationEnabled(),
        perMatch = isolationConfig().perMatch ~= false,
    }
end

RegisterCommand('arenaisolation', function(src, _args)
    if type(ArenaIsAdmin) ~= 'function' or not ArenaIsAdmin(src) then
        if src ~= 0 and type(ArenaNotifyKey) == 'function' then
            ArenaNotifyKey(src, 'error.no_permission', 'error')
        end
        return
    end

    local state = ArenaDispatch.IsolationState()
    ArenaLog('arenaisolation: config says %s, server reports onesync "%s", a move has %sbeen caught not landing.',
        state.wanted and 'ON' or 'OFF', tostring(state.oneSync), state.provenInert and '' or 'NOT ')
    ArenaLog('arenaisolation: isolation is %s right now, %s.',
        state.inForce and 'IN FORCE' or 'NOT IN FORCE',
        state.perMatch and 'one bucket per match' or 'one bucket shared by every match')

    local matches = 0
    for matchId, bucket in pairs(matchBuckets) do
        matches = matches + 1
        ArenaLog('arenaisolation:   match %s was allocated bucket %d.', tostring(matchId), bucket)
    end
    if matches == 0 then
        ArenaLog('arenaisolation:   no match holds a bucket at the moment.')
    end

    local players = 0
    for player, record in pairs(held) do
        players = players + 1
        local actually = currentBucket(player)
        ArenaLog('arenaisolation:   %s (match %s) should be in %d and the server says %d%s',
            tostring(player), tostring(record.matchId), record.bucket, actually,
            actually == record.bucket and '.' or '  <-- NOT INSTANCED')
    end
    if players == 0 then
        ArenaLog('arenaisolation:   nobody is being held in an arena bucket.')
    end
end, false)

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
-- WHY BOTH RegisterNetEvent AND AddEventHandler, which is not obvious and
-- was got wrong here once. FXServer delivers a network-sourced event only to
-- resources that have called RegisterNetEvent for that name, so a handler
-- registered with AddEventHandler alone never runs for the alerts that
-- matter -- gunfire and deaths are raised with TriggerServerEvent from the
-- player's own client, because that is where they are detected. The full
-- reasoning, including why this does not open anybody else's event to
-- clients, is at the RegisterNetEvent call itself further down.
-- ======================================================================

local function cancelConfig()
    local list = customConfig().cancelEvents
    return type(list) == 'table' and list or {}
end

local function readCancelEntry(key, entry)
    if Arena.IsKey(entry) then return { event = entry } end

    if type(entry) == 'table' and Arena.IsKey(entry.event) then
        local coordsIndex = Arena.ToInt(entry.coordsArg)
        if coordsIndex and coordsIndex < 1 then coordsIndex = nil end

        local index = Arena.ToInt(entry.playerArg)
        if index and index < 1 then index = nil end
        return { event = entry.event, playerArg = index, coordsArg = coordsIndex }
    end

    if entry == true and Arena.IsKey(key) then return { event = key } end

    return nil
end

--- The x and y of anything shaped like a coordinate, or nil.
---
--- THROUGH Arena.IsPoint, WHICH IS THE ONE PLACE THAT KNOWS THE LIST.
---
--- Written out here it read `table` or `vector3` and nothing else -- so a
--- vector4, which is what a dispatch resource hands over when it sends
--- coordinates WITH a heading, was refused. In this runtime a vector is
--- its own type, so `type()` on one answers 'vector4' and NEVER 'table'.
--- The whole point of this is to recognise that a shot was fired inside an
--- arena; refusing the payload means it is not recognised, and the alert the
--- arena exists to swallow goes out to the city police instead. Silent, and
--- only on the servers whose dispatch sends a heading. DO NOT write the
--- types out again.
--- @param point any
--- @return number|nil x
--- @return number|nil y
local function pointXY(point)
    if not Arena.IsPoint(point) then return nil end

    local px, py = tonumber(point.x), tonumber(point.y)
    if not px or not py then return nil end
    return px, py
end

--- Whether ONE live match's arena covers this spot.
---
--- SPLIT OUT OF insideLiveArena ON PURPOSE, because the explosion guard has
--- to ask WHICH round a blast landed in and not merely whether it landed in
--- one. Two questions off one circle: a second copy of the radius maths is
--- how the keep-out fence and this file came to disagree about a grown
--- round in the first place.
--- @param matchId string
--- @param px number
--- @param py number
--- @return boolean
local function matchCoversPoint(matchId, px, py)
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId) or nil
    local arena = match and Arena.GetArenaByKey(match.arenaKey) or nil
    local boundary = Arena.BoundaryOf(arena)
    if not boundary or not boundary.center then return false end

    local cx, cy = tonumber(boundary.center.x), tonumber(boundary.center.y)

    local factor = math.max(1.0, tonumber(match.sizeFactor) or 1.0)
    local radius = (tonumber(boundary.radius) or 0) * factor

    if not cx or not cy or not radius or radius <= 0 then return false end

    local dx, dy = px - cx, py - cy
    return (dx * dx + dy * dy) <= (radius * radius)
end

local function insideLiveArena(point)
    local px, py = pointXY(point)
    if not px then return false end

    -- Which arenas currently have somebody in them. Read from the same
    -- `active` table the player pin uses, so the two layers can never
    -- disagree about whether a match is running.
    for _, matchId in pairs(active) do
        if matchCoversPoint(matchId, px, py) then return true end
    end

    return false
end

local function pinnedByLocation(entry, ...)
    if not entry.coordsArg then return false end

    local payload = (select(entry.coordsArg, ...))

    -- THE SAME QUESTION AS insideLiveArena, SO IT MUST BE THE SAME ANSWER.
    --
    -- These two kept their own hand-written type lists and drifted: a payload
    -- that WAS the point rather than a table carrying one was rejected here,
    -- forty lines before the function that would have taken it. Both now ask
    -- Arena.IsPoint, which is the only thing that knows every shape a
    -- coordinate arrives in -- vector4 included, and a vector is its own type
    -- here, never a 'table'. DO NOT give either of them a private list again.
    if not Arena.IsPoint(payload) then return false end

    -- A BARE POINT HAS NO `coords`, and reading one off it must not be
    -- mistaken for a payload that carries one.
    if type(payload) ~= 'table' then return insideLiveArena(payload) end

    return insideLiveArena(payload.coords or payload)
end

--- Who an alert is about, and the answer has to survive a client saying so.
---
--- THE DEFECT. `playerArg` names an argument carrying a server id, and every
--- one of these events is registered for the network -- so the "server id"
--- was whatever the sender put in that slot, and the sender can be any
--- player on the box. A client naming SOMEBODY ELSE's id is the shape of
--- every server-id bug this project has already fixed, and here it reaches
--- both halves of the layer at once: the cancel flag is raised over a
--- stranger's alert, and Form 5 then asks the dispatch script to withdraw a
--- call filed under that stranger's id. The retract block's own promise --
--- "the server id in the middle is the arena player's own" -- was true of
--- the arithmetic and false of the input.
---
--- WHAT DECIDES IT. `source` is the server's answer, not the payload's, and
--- it is set for the whole of an event handler. When it names a player, that
--- player is who fired this event and a declared id that disagrees is a
--- claim about somebody else -- refused, which leaves the alert alone. When
--- it is 0 or absent the firing came from another RESOURCE on the server,
--- which is the case `playerArg` was written for and the one shape a client
--- CANNOT produce, so the declared id stands.
--- @return integer|nil src -- who the alert is about, or nil for "leave it alone"
--- @return integer|nil impostor -- the player who claimed somebody else's id
local function responsibleFor(entry, ...)
    local fromSource = Arena.ToInt(source)
    if fromSource and fromSource <= 0 then fromSource = nil end

    if entry.playerArg then
        local declared = Arena.ToInt((select(entry.playerArg, ...)))
        if not declared or declared <= 0 then return nil end
        if fromSource and declared ~= fromSource then return nil, fromSource end
        return declared
    end

    if entry.coordsArg then return nil end

    return fromSource
end

local warnedCancel = {}

local sawFiring = {}

local sawJobs = {}

local MAX_JOB_KINDS = 32
local sawJobCount = 0
local warnedJobFlood = false

local MAX_JOB_NAMES = 12
local MAX_JOB_TEXT = 200

local function warnUnpinnable(entry)
    if warnedCancel[entry.event] then return end
    warnedCancel[entry.event] = true

    if entry.coordsArg then
        ArenaLog('cancelEvents: "%s" fired but its location was not inside any arena with a live match, so it was left alone. That is the normal answer for an alert about somewhere else -- if it should have matched, check argument %d really carries the coordinates.',
            entry.event, entry.coordsArg)
        return
    end

    ArenaLog('cancelEvents: "%s" fired with no player behind it, so it was left alone. Say which argument carries the server id -- { event = \'%s\', playerArg = 1 } -- or, if the payload only says WHERE, which argument carries that -- { event = \'%s\', coordsArg = 1 } -- or drop it from the list.',
        entry.event, entry.event, entry.event)
end

local function jobsNamedIn(...)
    for index = 1, select('#', ...) do
        local argument = (select(index, ...))
        if type(argument) == 'table' then
            local jobs = argument.job_table or argument.jobs
            if type(jobs) == 'table' then
                local names = {}
                for _, job in ipairs(jobs) do
                    if type(job) == 'string' then
                        names[#names + 1] = job
                        if #names >= MAX_JOB_NAMES then break end
                    end
                end
                if #names > 0 then
                    local text = table.concat(names, ', ')
                    if #text > MAX_JOB_TEXT then
                        text = text:sub(1, MAX_JOB_TEXT) .. '...'
                    end
                    return text
                end
            end
        end
    end
    return nil
end

local function crossfireConfig()
    return (Config.Match or {}).crossfireGuard or {}
end

local function crossfireEnabled()
    return crossfireConfig().enabled ~= false
end

local MAX_HITS = 32

local function ownerOfNetId(netId, packet)
    local cached = netIdOwners[netId]
    if cached and netIdOf(cached) == netId then return cached end

    if packet then
        if packet.rebuilt then return netIdOwners[netId] end
        packet.rebuilt = true
    end

    netIdOwners = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        if src then
            local owned = netIdOf(src)
            if owned then netIdOwners[owned] = src end
        end
    end

    return netIdOwners[netId]
end

--- Whether these two may damage each other.
---
--- SYMMETRIC ON PURPOSE, and it answers both halves of the request in one
--- rule: an outsider cannot hurt a fighter, and a fighter cannot hurt an
--- outsider. Two people in DIFFERENT matches are as separate as a fighter
--- and a passer-by, which matters at an arena two rounds share.
---
--- Nobody in a round means this is not our business, and the answer is yes.
---
--- SELF-DAMAGE IS ALLOWED, and it now needs saying out loud. It used to
--- fall out of the crossfire rule -- a player's match compared against
--- itself is equal whether that is a match id or nil -- and an explicit
--- early return for it was written here first and taken back out, because
--- mutation testing showed it could not change the answer. The team check
--- below changed that: a fighter is on their own team, so `friendlyFire =
--- false` would refuse a player their own grenade and their own fall, and
--- make every fighter in a team mode immortal to the one thing the arena
--- does not control. The line earns its place now; crossfire_spec fails
--- without it.
--- @param attacker number
--- @param victim number
--- @return boolean ok
--- @return string|nil reason -- why not, for the log
--- @return string|nil kind -- 'crossfire' or 'team', which decides how much of the packet dies
local function mayDamage(attacker, victim)
    if attacker == victim then return true end

    local attackerMatch, victimMatch = active[attacker], active[victim]
    if attackerMatch == nil and victimMatch == nil then return true end
    if attackerMatch == nil or attackerMatch ~= victimMatch then
        return false, 'they are not in the same round', 'crossfire'
    end

    -- SAME ROUND. NOW THE TEAMS DECIDE, and this is where friendlyFire was
    -- doing nothing at all.
    --
    -- Arena.CanDamage existed, was tested, and had exactly one caller:
    -- server/match.lua's kill attribution, which decides whether a kill is
    -- CREDITED. Nothing ever stopped the bullet. So Config.Teams.friendlyFire
    -- = false meant "shooting your teammate does not score" rather than "you
    -- cannot shoot your teammate" -- and a player emptying a magazine into
    -- their own side, killing them, and seeing no score change is not what
    -- that setting says.
    --
    -- weaponDamageEvent is the only place the damage itself can be refused,
    -- and this handler is already here doing the same job across matches.
    --
    -- ArenaLobby is defined by a file loaded after this one; this runs inside
    -- an event handler long after load, which is the arrangement
    -- fxmanifest.lua's server_scripts note describes. Guarded anyway, because
    -- a missing lobby must not turn every shot into an error.
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(attackerMatch)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return true end

    -- A WATCHER IS NOT A FIGHTER, and this is the first case config.lua names
    -- as the reason this guard exists at all.
    --
    -- server/match.lua's syncMatchBuckets puts a spectator in the match's own
    -- routing bucket -- deliberately, because watching requires seeing -- and
    -- raises the SAME dispatch flag on them that a fighter carries, so
    -- `active` says they are in the round. The crossfire half above therefore
    -- passes for a fighter shooting a spectator, and it always has. The team
    -- half could not catch it either: a spectator is not on `match.players`,
    -- so Arena.CanDamage was handed a nil team, read it as "not the same
    -- side" and allowed the shot. Their body is invisible and collisionless
    -- while the camera runs, but it is not invincible, and the camera hands
    -- it back the moment it runs out of fighters to follow.
    --
    -- FAILS CLOSED, unlike the missing-lobby case above, and the difference is
    -- what is unknown. There, the roster had not answered and refusing would
    -- have frozen a live round into a stalemate. Here the roster answered and
    -- one of these two is not in it.
    local shooter, target = match.players[attacker], match.players[victim]
    if shooter == nil or target == nil then
        return false, 'one of them is watching rather than fighting', 'crossfire'
    end

    -- AND BEING OUT OF THE ROUND IS WATCHING, WHATEVER THE ROSTER SAYS.
    --
    -- An eliminated fighter KEEPS their row on purpose -- the results board
    -- ranks off it, and with spectateOnElimination on they stay in the
    -- match's routing bucket to watch. Both tests above therefore pass for
    -- them, and their shots at the people still fighting were never
    -- cancelled: a player who is out for the round could spend the rest of
    -- it deleting whoever was about to win.
    --
    -- Nothing was gained by it on the board -- resolveKiller refuses to
    -- credit a kill to somebody eliminated -- which is exactly what made it
    -- pure griefing, and free.
    --
    -- Their own client holds them invisible and collisionless while the
    -- camera runs; that is a hold their own client owns, and this is the
    -- half the server owns.
    if Arena.IsEliminated(shooter) then
        return false, 'the shooter is out of the round', 'crossfire'
    end

    if Arena.CanDamage(match.modeKey, shooter.team, target.team) then
        return true
    end
    return false, 'they are on the same team and friendly fire is off', 'team'
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    -- THE CROSSFIRE SWITCH CARRIES THE FRIENDLY-FIRE CHECK TOO, and that is
    -- deliberate rather than an oversight.
    --
    -- Both refusals happen here, because weaponDamageEvent is the only place
    -- a shot can be refused at all. Running this handler with the guard
    -- switched off would break the promise crossfire_spec holds us to --
    -- "switching the guard off restores the old behaviour exactly" -- and an
    -- operator who turned it off asked for this resource to stop touching
    -- other people's damage.
    --
    -- crossfireGuard.enabled ships true, so friendly fire is enforced out of
    -- the box. config.lua says so beside the switch.
    if not crossfireEnabled() then return end

    if next(active) == nil then return end

    local attacker = tonumber(sender)
    if not attacker then return end

    local hits = type(data) == 'table' and data.hitGlobalIds or nil
    if type(hits) ~= 'table' then return end

    if #hits > MAX_HITS then
        ArenaDebug('crossfire: refused a damage packet from %s naming %d entities.', tostring(attacker), #hits)
        CancelEvent()
        return
    end

    local allowed, refusal, crossfire = 0, nil, false

    local packet = {}

    for _, entry in ipairs(hits) do
        local netId = tonumber(entry)
        local victim = netId and ownerOfNetId(netId, packet) or nil
        if victim then
            local ok, reason, kind = mayDamage(attacker, victim)
            if ok then
                if victim ~= attacker then allowed = allowed + 1 end
            else
                refusal = refusal or { victim = victim, reason = reason }
                if kind ~= 'team' then crossfire = true end
            end
        end
    end

    if refusal == nil then return end

    if crossfire or allowed == 0 then
        ArenaDebug('crossfire: %s may not damage %s -- %s.',
            tostring(attacker), tostring(refusal.victim), refusal.reason or 'refused')
        CancelEvent()
    end
end)

-- ======================================================================
-- THE SECOND PLACE DAMAGE IS REFUSED, and mayDamage's own comment above
-- says weaponDamageEvent is the only one. It was wrong about this handler
-- and this handler enforced nothing.
--
-- THE DEFECT. Anybody in ANY match was exempted here, unconditionally: no
-- same-round test and no team test. So on a team round with friendlyFire
-- off a grenade killed the thrower's own side, a fighter in one match could
-- shell the round being fought next door, and a fighter who was already OUT
-- of the round -- still in `active`, because an eliminated fighter stays to
-- watch -- could delete whoever was about to win with a launcher while
-- their bullets were being refused three functions up. All thirteen heavy
-- weapons ship enabled, at the owner's own instruction, so it is reachable
-- with the shipped catalogue.
--
-- WHAT AN EXPLOSION CANNOT BE ASKED. The packet carries a PLACE and never a
-- victim list, so the per-victim answer weaponDamageEvent gets is not
-- available here: who is standing in the blast is read off the fighters'
-- own positions instead. BLAST_METRES is this file's own number and DO NOT
-- read it as the game's -- it is how close a team-mate has to be before the
-- arena treats them as caught.
--
-- AND IT BENDS FOR A LAWFUL VICTIM, exactly as the spread rule does.
-- CancelEvent kills the whole explosion, so refusing one that also caught an
-- enemy would make standing next to a team-mate a shield against every
-- launcher in the arena -- the same regression crossfire_spec already
-- refuses for shotguns.
-- ======================================================================

local BLAST_METRES = 10.0

--- Where a fighter is standing right now, or nil.
---
--- Guarded the way netIdOf is: a server-side read of a client-owned entity
--- can legitimately fail, and a player who left mid-blast must not take the
--- handler down with them.
--- @param src number
--- @return any|nil coords
local function positionOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotIt, coords = pcall(GetEntityCoords, ped)
    if not gotIt then return nil end
    return coords
end

--- Why this fighter may not set off this explosion, or nil for "they may".
--- @param exploder number
--- @param matchId string
--- @param px number
--- @param py number
--- @return string|nil reason
local function explosionRefusal(exploder, matchId, px, py)
    -- FAILS OPEN ON A LOBBY THAT HAS NOT ANSWERED, deliberately, and for the
    -- reason mayDamage gives: the thrower is already known to be in the round
    -- this blast landed in, and freezing a live round over a roster that is
    -- not there costs more than one unrefused grenade. DO NOT turn this into
    -- a refusal.
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return nil end

    local thrower = match.players[exploder]
    if thrower == nil then return 'they are watching rather than fighting' end
    if Arena.IsEliminated(thrower) then return 'the thrower is out of the round' end

    local reach = BLAST_METRES * BLAST_METRES
    local caught, lawful = false, false

    -- `match.players` is keyed by SERVER ID, so this is pairs and not ipairs.
    for src, row in pairs(match.players) do
        if src ~= exploder and not Arena.IsEliminated(row) then
            local at = positionOf(src)
            if at then
                local x, y = pointXY(at)
                if x then
                    local dx, dy = x - px, y - py
                    if (dx * dx + dy * dy) <= reach then
                        if Arena.CanDamage(match.modeKey, thrower.team, row.team) then
                            lawful = true
                        else
                            caught = true
                        end
                    end
                end
            end
        end
    end

    if caught and not lawful then
        return 'it would land on their own team and friendly fire is off'
    end
    return nil
end

AddEventHandler('explosionEvent', function(sender, data)
    if not crossfireEnabled() then return end
    if next(active) == nil then return end

    if type(data) ~= 'table' then return end
    local x, y, z = tonumber(data.posX), tonumber(data.posY), tonumber(data.posZ)
    if not x or not y then return end

    local exploder = tonumber(sender)
    local ownMatch = exploder and active[exploder] or nil

    -- THEIR OWN ROUND, AND NOT MERELY SOME ROUND. "Are they in a match" is
    -- what this asked, and DO NOT put that test back: it made a fighter at
    -- one arena free to shell the round being fought at another.
    if ownMatch and matchCoversPoint(ownMatch, x, y) then
        local refusal = explosionRefusal(exploder, ownMatch, x, y)
        if refusal then
            ArenaDebug('crossfire: refused an explosion from %s -- %s.', tostring(sender), refusal)
            CancelEvent()
        end
        return
    end

    if insideLiveArena({ x = x, y = y, z = z or 0.0 }) then
        ArenaDebug('crossfire: refused an explosion from %s inside a live arena.', tostring(sender))
        CancelEvent()
    end
end)

-- ======================================================================
-- WITHDRAWING AN ALERT THAT WAS ALREADY CREATED
-- (Config.Dispatch.custom.retract)
--
-- WHY THIS EXISTS AND CANCELEVENT DOES NOT REPLACE IT. CancelEvent() raises
-- a flag. Cfx's own documentation is explicit that it does not stop another
-- resource's handler from running, and a dispatch script that never calls
-- WasEventCanceled() -- which is most of them, sc-dispatch included -- will
-- create its call regardless. The layer above is therefore diagnostics on
-- this kind of script, not suppression. This is the layer that removes the
-- call.
--
-- HOW IT CAN KNOW THE ID. Dispatch scripts file a call under an id built
-- from facts that are not secret: sc-dispatch uses
-- '<kind>_<serverId>_<os.time()>', both of which this resource is holding at
-- the moment the same event reaches it. So the id is rebuilt rather than
-- read, and the operator states the shape in config rather than this file
-- assuming one.
--
-- WHY IT IS DELAYED. Both handlers hang off one event and nothing decides
-- which runs first. Clearing a call the other handler has not inserted yet
-- clears nothing, so the withdrawal is pushed past that handler's own work
-- with SetTimeout.
--
-- WHY IT CANNOT REACH SOMEBODY ELSE'S CALL. Every id it builds carries the
-- arena player's own server id in the middle. The clock slack widens the
-- timestamp, never the player.
-- ======================================================================

local function retractConfig()
    local block = customConfig().retract
    return type(block) == 'table' and block or {}
end

local function retractFor(entry, src)
    local config = retractConfig()
    if not Arena.IsKey(config.resource) or not Arena.IsKey(config.export) then return end

    local templates = config.idTemplates
    local template = type(templates) == 'table' and templates[entry.event] or nil
    if not Arena.IsKey(template) then
        -- Not a warning. An event listed for cancelling with no id shape is
        -- an ordinary, deliberate state: Form 4 covers it and Form 5 does
        -- not claim to.
        return
    end

    if GetResourceState(config.resource) ~= 'started' then
        if not sawFiring['retract:' .. config.resource] then
            sawFiring['retract:' .. config.resource] = true
            ArenaLog('retract: Config.Dispatch.custom.retract names "%s", which is not started. Arena alerts will be raised and left standing.',
                config.resource)
        end
        return
    end

    local delay = Arena.ToInt(config.delayMs) or 250
    if delay < 0 then delay = 0 end

    local slack = Arena.ToInt(config.clockSlack) or 0
    if slack < 0 then slack = 0 end
    if slack > 5 then slack = 5 end

    local at = os.time()

    SetTimeout(delay, function()
        for offset = -slack, slack do
            -- THE FORMAT IS OPERATOR TEXT AND IT WAS OUTSIDE THE pcall.
            --
            -- `idTemplates` is a string typed into config.lua. string.format
            -- RAISES on a shape it cannot fill -- a stray '%q', a '%d' handed
            -- something that is not a number, one specifier too many -- and
            -- this line sat above the guard that was catching the export
            -- call, inside a SetTimeout body with nothing above it to catch
            -- anything. One mistyped template therefore threw out of a timer
            -- rather than printing a line an operator could act on, and it
            -- did it on every arena alert for the rest of the run.
            --
            -- Built the way shared/compat/dispatch.lua's say() builds its
            -- own: pcall(string.format, ...) and DO NOT put the colon call
            -- back.
            local built, id = pcall(string.format, template, src, at + offset)
            if not built then
                if not sawFiring['retract:id:' .. entry.event] then
                    sawFiring['retract:id:' .. entry.event] = true
                    ArenaLog('retract: the id template for "%s" (%s) cannot be filled in (%s). It wants exactly two placeholders -- the player\'s server id and a unix timestamp, both numbers, as in \'shots_%%d_%%d\'. Nothing is being withdrawn for that event.',
                        entry.event, tostring(template), tostring(id))
                end
                return
            end

            local ok, err = pcall(function()
                exports[config.resource][config.export](nil, id)
            end)
            if not ok then
                if not sawFiring['retract:err:' .. config.resource] then
                    sawFiring['retract:err:' .. config.resource] = true
                    ArenaLog('retract: %s:%s failed (%s). Check that export name against that resource\'s own documentation.',
                        config.resource, config.export, tostring(err))
                end
                break
            end
        end

        local shown, sample = pcall(string.format, template, src, at)
        ArenaDebug('retract: asked %s to clear "%s" (+/-%ds) for %s.',
            config.resource, shown and sample or tostring(template), slack, tostring(src))
    end)
end

--- The tempo one player may fire one of these events at, in ms.
---
--- server/main.lua's loosest bucket on purpose, and for its stated reason:
--- "this only has to catch a flood, not pace anything." A dispatch alert is
--- at most as frequent as the death report that number was chosen for.
local CANCEL_RATE_MS = 200

--- Whether this firing is paced enough to do the work for.
---
--- THE DEFECT. Every one of these handlers is registered for the network,
--- because that is the only way FXServer delivers the client-triggered
--- alerts they exist for -- and not one of them had a limit of any kind.
--- Any player on the box could fire one in a loop: each firing walked the
--- payload for job names, walked the live arenas for the pin, and then
--- queued a timer whose body makes one call into another resource per second
--- of clock slack. A thousand firings bought a thousand timers and three
--- thousand of those calls, from a keybind.
---
--- THE HOUSE LIMITER, NOT A NEW ONE. ArenaRateLimit is what every
--- crimson_arena net event in server/main.lua already sits behind, keyed per
--- player and per bucket so one spammed event cannot starve another.
---
--- KEYED ON `source`, WHICH IS WHY IT IS SAFE. The limit is per PLAYER, so a
--- flooder can only throttle themselves; nobody can pace anybody else's
--- alerts by firing these. A firing with no player behind it -- another
--- resource raising the event on the server, which is the ordinary path -- is
--- never throttled at all.
---
--- WHAT A THROTTLED FIRING COSTS, said plainly rather than left implied: the
--- flag is not raised, so that one alert is not cancelled. This file's own
--- note on guessing says which way that error should fall -- "a failure to
--- suppress costs an operator an unwanted call-out; a wrong suppression costs
--- somebody a crime nobody was told about" -- and the player who pays is the
--- one doing the flooding.
--- @param eventName string
--- @return boolean
local function pacedEnough(eventName)
    local src = Arena.ToInt(source)
    if not src or src <= 0 then return true end

    -- server/util.lua is first in fxmanifest.lua's server_scripts, so this is
    -- always there in production; guarded because a file that loads without
    -- it must degrade rather than throw inside somebody else's event.
    if type(ArenaRateLimit) ~= 'function' then return true end

    return ArenaRateLimit(src, 'cancelEvents:' .. eventName, CANCEL_RATE_MS) == true
end

local warnedImpostor = {}

local function warnImpostor(entry, from)
    if warnedImpostor[entry.event] then return end
    warnedImpostor[entry.event] = true

    ArenaLog('cancelEvents: "%s" was fired by player %s naming a DIFFERENT server id, so it was left alone. A client CANNOT be taken at its word about who an alert is about -- acting on it would raise the cancel flag over a stranger\'s alert and ask your dispatch script to withdraw a call filed under their id. If your script really raises this from one player\'s client about another, drop playerArg from that entry and let `source` answer.',
        entry.event, tostring(from))
end

local function registerCancelHandler(entry)
    RegisterNetEvent(entry.event)

    AddEventHandler(entry.event, function(...)
        -- FIRST, AND BEFORE ANY OF THE BOOKKEEPING BELOW -- that is the
        -- expensive half and it reads a payload the caller chose, so DO NOT
        -- move this line down past it.
        if not pacedEnough(entry.event) then return end

        local jobs = jobsNamedIn(...)

        if not sawFiring[entry.event] then
            sawFiring[entry.event] = true
            ArenaLog('cancelEvents: "%s" reached this resource for the first time -- the hook is live. If alerts still get through from here it is a pinning problem, not a plumbing one.',
                entry.event)
        end

        if jobs and not sawJobs[jobs] then
            if sawJobCount < MAX_JOB_KINDS then
                sawJobs[jobs] = true
                sawJobCount = sawJobCount + 1
                ArenaLog('cancelEvents: an alert for [%s] came through "%s". Alerts for jobs never listed here are being raised somewhere this resource cannot see.',
                    jobs, entry.event)
            elseif not warnedJobFlood then
                warnedJobFlood = true
                ArenaLog('cancelEvents: more than %d different job lists have come through these events, so no more will be recorded. On a normal server there are a handful; this many means either an unusual dispatch script or a player raising the event by hand.',
                    MAX_JOB_KINDS)
            end
        end

        if pinnedByLocation(entry, ...) then
            CancelEvent()
            ArenaDebug('cancelEvents: cancelled "%s" -- it is about a spot inside a live arena.', entry.event)
            return
        end

        local src, impostor = responsibleFor(entry, ...)
        if not src then
            if impostor then warnImpostor(entry, impostor) else warnUnpinnable(entry) end
            return
        end

        if not ArenaDispatch.IsPlayerInArena(src) then
            ArenaDebug('cancelEvents: "%s" fired for %s, who is not in a match -- left alone, which is correct.',
                entry.event, tostring(src))
            return
        end

        CancelEvent()
        ArenaDebug('dispatch: raised the cancel flag on "%s" for %s, who is in match %s. It only stops the alert if that resource checks WasEventCanceled().',
            entry.event, tostring(src), tostring(active[src]))

        retractFor(entry, src)
    end)
end

-- Registration itself. Deliberately quiet: shared/compat/dispatch.lua's
-- startup report is the one place an operator is told how many of these are
-- live, and a second line saying the same thing at every boot is how a
-- console stops being read.
do
    local registered = {}
    for key, entry in pairs(cancelConfig()) do
        local normalised = readCancelEntry(key, entry)
        if not normalised then
            ArenaLog('cancelEvents: skipped an entry that is not an event name, { event = ... } or [event] = true.')
        elseif registered[normalised.event] then
            ArenaDebug('dispatch: cancelEvents names "%s" more than once -- the later entry was ignored.', normalised.event)
        else
            registered[normalised.event] = true
            registerCancelHandler(normalised)
        end
    end
end
