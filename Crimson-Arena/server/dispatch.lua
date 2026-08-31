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

--- Puts this resource in the server's admin role so its revive command is
--- not refused.
---
--- WHY THIS IS NEEDED. A command run through ExecuteCommand from a resource
--- is run BY that resource, and an admin command checks whether the caller is
--- allowed. crimson_arena is not an admin, so the command was refused --
--- silently, because a refused command is not an error, it is just a command
--- that did nothing. That is why the console could report running `revive 3`
--- while the player stayed on the floor.
---
--- WHY IT GRANTS THE COMMAND AND NOT ADMIN. The obvious version of this is
--- one line -- add this resource to the admin group -- and it would work. It
--- would also mean every command on the server was reachable from inside the
--- arena, so any flaw in any part of this resource became a way to run
--- anything. What is granted here is exactly the commands the operator named
--- in Config.Dispatch.revive.commands and nothing else: `command.revive`
--- lets it revive, and lets it do nothing else at all.
---
--- Runtime only. Nothing is written to a .cfg and nothing survives a restart
--- -- it is re-granted at every start, from config, so removing the command
--- from config removes the permission with it.
local function grantReviveAce()
    local revive = (Config.Dispatch or {}).revive
    if type(revive) ~= 'table' or revive.enabled ~= true then return end

    -- THE ADMIN ROLE, NOT THE COMMAND'S OWN PERMISSION.
    --
    -- An earlier version granted `command.revive` and nothing else, on the
    -- reasoning that the narrowest grant which works is the right one. It did
    -- not work, and the reason is worth keeping: this server's revive is not
    -- gated on a permission named after itself. It asks whether the caller is
    -- an ADMIN, and no amount of permission to run one command answers that
    -- question.
    --
    -- So the grant is the role. `command allow` comes with it because a check
    -- of the other common shape -- may this caller run commands at all --
    -- reads the ace list rather than group membership, and either could be
    -- the one in the way.
    --
    -- WHAT IT COSTS, said here rather than buried: any flaw anywhere in this
    -- resource becomes a way to run any command on the server. It is
    -- runtime-only and re-applied at every start, so setting grantSelfAdmin
    -- false and restarting takes all of it back.
    if revive.grantSelfAdmin ~= true then return end

    local resource = GetCurrentResourceName()

    -- TWO PRINCIPALS, because there are two identities in play and only one
    -- of them is obvious.
    --
    -- `resource.<name>` is this resource. It satisfies a check that asks
    -- whether the CALLING RESOURCE may do something.
    --
    -- `system.console` is who the command is running AS. ExecuteCommand from
    -- a server script runs on the console's behalf, so a command that asks
    -- whether its INVOKER is an admin -- the common shape, and the one an
    -- identifier-keyed permission list is built for -- is asking about the
    -- console and never about this resource. Granting only the resource is
    -- how the arena could hold admin and still be told access denied.
    local principals = { ('resource.%s'):format(resource), 'system.console' }

    local wide = {}
    for _, principal in ipairs(principals) do
        wide[#wide + 1] = ('add_ace %s command allow'):format(principal)
        for _, group in ipairs(revive.adminGroups or { 'group.admin' }) do
            if Arena.IsKey(group) then
                wide[#wide + 1] = ('add_principal %s %s'):format(principal, group)
            end
        end
    end

    for _, line in ipairs(wide) do
        pcall(ExecuteCommand, line)
    end

    -- CHECKED, NOT ASSUMED, and the earlier version of this was a lie worth
    -- describing. It counted a pcall that did not throw as a grant that
    -- worked -- but ExecuteCommand does not throw when a command is refused,
    -- it returns normally and the refusal appears on the console as
    -- "Access denied for command add_ace". So the resource announced it had
    -- been given full admin at the exact moment the server was refusing to
    -- give it anything, which is the worst thing a diagnostic can do: it
    -- sends whoever reads it looking somewhere else.
    --
    -- IsPrincipalAceAllowed asks the permission system itself, which is the
    -- only answer worth having.
    local ok, held = pcall(IsPrincipalAceAllowed, ('resource.%s'):format(resource), 'command')
    if ok and held == true then
        ArenaLog('revive: this resource now holds full command rights and admin group membership, because Config.Dispatch.revive.grantSelfAdmin is on. Any flaw in it can run any command -- turn it off once the revive works another way.')
        return
    end

    -- A resource may not grant itself permissions, which is correct and is
    -- the whole reason that door is shut. Said once, with the exact lines to
    -- paste, rather than left as four "Access denied" lines an operator has
    -- to work backwards from.
    ArenaLog('revive: this resource is NOT allowed to grant itself permissions -- the add_ace lines above were refused by the server, which is correct behaviour. Nothing was granted.')
    ArenaLog('revive: it does not matter. The arena revives its own players directly and needs no permission for that. These lines are only needed if you want it to run YOUR revive command as well, in server.cfg:')
    ArenaLog('    add_ace resource.%s command allow', resource)
    for _, group in ipairs(revive.adminGroups or { 'group.admin' }) do
        if Arena.IsKey(group) then
            ArenaLog('    add_principal resource.%s %s', resource, group)
        end
    end
end

-- At start, and every start: the grant is runtime-only and deliberately does
-- not persist, so it is made again from whatever config says now.
CreateThread(function()
    -- One tick, so the command system is up before anything is added to it.
    Wait(0)
    grantReviveAce()
end)

--- Tells whatever handles death on this server that a player is alive again.
---
--- WHY THIS IS NEEDED AT ALL. The arena stands its own players back up with
--- NetworkResurrectLocalPlayer, and for the PED that is the whole job. It is
--- not the whole job for the SERVER: an ambulance or medical script keeps its
--- own death state -- metadata, a table, a state bag -- and nothing about
--- resurrecting a ped tells it anything. So a player who died in a match
--- walks out of the arena on their feet and their medical script still has
--- them dead: downed on the next check, or refused a respawn, or simply
--- unable to do anything until someone revives them.
---
--- NOTHING IS GUESSED HERE. Every name comes from config; an empty config
--- calls nothing. A guessed export or event name is worse than none, because
--- it detects as wired up and then silently does nothing -- the same reason
--- the catalogue further down this file is detection-only.
--- @param src number
function ArenaDispatch.Revive(src)
    if type(src) ~= 'number' or src <= 0 then return end

    local revive = (Config.Dispatch or {}).revive
    if type(revive) ~= 'table' then revive = {} end

    -- THE ARENA'S OWN REVIVE, FIRST AND UNCONDITIONALLY.
    --
    -- Every route to somebody else's revive turned out to be shut. The
    -- command answered "Access denied", because a resource may not run an
    -- admin command. Granting the permission answered "Access denied" too,
    -- because a resource may not grant itself permissions either -- which is
    -- correct, and is exactly why that door is closed.
    --
    -- So the arena stops knocking on it. Standing up a player this resource
    -- knocked down is not a privileged act, and it needs no permission from
    -- anybody: client/dispatch.lua does it directly. This runs whether or not
    -- anything below is configured, which is what makes a fresh install work
    -- with no integration at all.
    --
    -- Everything after this point is for reaching a MEDICAL SCRIPT's own
    -- records, which the arena cannot see and will not guess at.
    TriggerClientEvent('crimson_arena:client:revive', src)

    if revive.enabled ~= true then return end

    -- COMMANDS, and this is the form most servers actually have. An
    -- ambulance script's revive is very often just `/revive <id>`, run by an
    -- admin, with no event and no export behind it worth calling directly.
    -- ExecuteCommand runs it from the server console, which is the identity
    -- a restricted command already trusts.
    for _, template in ipairs(revive.commands or {}) do
        if Arena.IsKey(template) then
            -- `%s` is where the player's id goes. A template without one is
            -- taken as the bare command and the id is appended, because
            -- "revive" and "revive %s" are both things an operator will
            -- reasonably write and only one of them is documented.
            local line
            if template:find('%%') then
                local ok, formatted = pcall(string.format, template, src)
                line = ok and formatted or nil
                if not line then
                    ArenaLog('revive: could not build a command from "%s" -- use %%s where the player id goes.',
                        template)
                end
            else
                line = ('%s %d'):format(template, src)
            end

            if line then
                local ok, err = pcall(ExecuteCommand, line)
                if ok then
                    -- SAID OUT LOUD, not traced. Running a command that has
                    -- no effect looks exactly like running no command at all,
                    -- and an operator watching a player stay dead needs to
                    -- know which of those they are looking at. If this line
                    -- appears and the player is still down, the command is
                    -- not the right mechanism on this server -- try
                    -- clientCommands below.
                    ArenaLog('revive: ran "%s" on the server console.', line)
                else
                    ArenaLog('revive: command "%s" errored (%s).', line, tostring(err))
                end
            end
        end
    end

    -- THE SAME THING, ON THE PLAYER'S OWN CLIENT. A command registered
    -- client-side does not exist as far as the server console is concerned:
    -- ExecuteCommand above finds nothing, does nothing, and reports nothing
    -- wrong -- which is the quietest possible failure and exactly what a
    -- server whose /revive lives on the client would see.
    for _, template in ipairs(revive.clientCommands or {}) do
        if Arena.IsKey(template) then
            local line
            if template:find('%%') then
                local ok, formatted = pcall(string.format, template, src)
                line = ok and formatted or nil
            else
                line = template
            end

            if line then
                TriggerClientEvent('crimson_arena:client:runCommand', src, line)
                ArenaLog('revive: asked %s\'s client to run "%s".', tostring(src), line)
            else
                ArenaLog('revive: could not build a client command from "%s" -- use %%s where the player id goes.',
                    template)
            end
        end
    end

    for _, name in ipairs(revive.serverEvents or {}) do
        if Arena.IsKey(name) then
            -- pcall because these are other people's handlers: one that
            -- throws must not take the arena's exit path down with it and
            -- strand the player mid-transfer.
            local ok, err = pcall(TriggerEvent, name, src)
            if not ok then
                ArenaLog('revive: server event %s errored (%s). The player is out of the arena either way.',
                    name, tostring(err))
            end
        end
    end

    for _, name in ipairs(revive.clientEvents or {}) do
        if Arena.IsKey(name) then
            TriggerClientEvent(name, src)
        end
    end

    for _, entry in ipairs(revive.exports or {}) do
        local resource = type(entry) == 'table' and entry.resource or nil
        local method = type(entry) == 'table' and entry.export or nil

        if Arena.IsKey(resource) and Arena.IsKey(method) then
            if GetResourceState(resource) ~= 'started' then
                ArenaLog('revive: %s is not started, so %s was not called.', resource, method)
            else
                local ok, err = pcall(function() return exports[resource][method](nil, src) end)
                if not ok then
                    ArenaLog('revive: exports.%s:%s failed (%s). Check the name and its arguments.',
                        resource, method, tostring(err))
                end
            end
        end
    end
end

-- ======================================================================
-- TESTING THE REVIVE WITHOUT PLAYING A MATCH
--
-- The revive has been the hardest thing here to get right, and the reason is
-- the feedback loop rather than the code: every attempt cost a full round --
-- open a lobby, join, start, die, wait for the end -- to learn one bit of
-- information. That is a terrible way to test a one-line integration.
--
-- /arenarevive <id> fires exactly the same path ArenaDispatch.Revive takes at
-- the end of a match, on demand, against any player. Lie on the floor, run
-- it, and the console says what it did.
-- ======================================================================
RegisterCommand('arenarevive', function(src, args)
    if type(ArenaIsAdmin) ~= 'function' or not ArenaIsAdmin(src) then
        if src ~= 0 and type(ArenaNotifyKey) == 'function' then
            ArenaNotifyKey(src, 'error.no_permission', 'error')
        end
        return
    end

    -- Defaults to whoever ran it, because the common case is an admin lying
    -- on the floor testing this on themselves.
    local target = Arena.ToInt(args and args[1]) or (src > 0 and src or nil)
    if not target or target <= 0 then
        ArenaLog('arenarevive: give a server id -- /arenarevive 3.')
        return
    end

    local revive = (Config.Dispatch or {}).revive
    if type(revive) ~= 'table' or revive.enabled ~= true then
        ArenaLog('arenarevive: Config.Dispatch.revive.enabled is off, so nothing would be called. Nothing was.')
        return
    end

    ArenaLog('arenarevive: running the end-of-match revive against %d. Everything below is what a real match would do.',
        target)
    ArenaDispatch.Revive(target)
    ArenaLog('arenarevive: done. If %d is still on the floor, the lines above are the whole of what this resource can do -- the revive is gated on something no permission grant reaches, and it needs that script\'s own export or event in Config.Dispatch.revive instead.',
        target)
end, false)

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
        local coordsIndex = Arena.ToInt(entry.coordsArg)
        if coordsIndex and coordsIndex < 1 then coordsIndex = nil end

        -- Lua counts arguments from 1. A zero or negative index is not a
        -- smaller mistake than a missing one, so it is dropped rather than
        -- clamped -- an entry with no usable index cancels nothing, which is
        -- the safe direction.
        local index = Arena.ToInt(entry.playerArg)
        if index and index < 1 then index = nil end
        return { event = entry.event, playerArg = index, coordsArg = coordsIndex }
    end

    if entry == true and Arena.IsKey(key) then return { event = key } end

    return nil
end

--- Is a point inside an arena that has a match being fought in it RIGHT NOW?
---
--- WHY THIS EXISTS. Some alert events carry no player at all -- a resource
--- raises them on the server with a payload describing WHERE something
--- happened and nothing about who. `source` is meaningless for those and
--- there is no argument holding a server id, so the player-based pin has
--- nothing to work with and the alert goes out.
---
--- The location is the one thing such a payload does have, and an arena is a
--- place. If the alert is about a spot inside an arena with a live match in
--- it, it is an arena alert.
---
--- REQUIRING A LIVE MATCH IS THE WHOLE SAFETY OF IT. The arenas sit on real
--- map locations that ordinary play uses the rest of the time -- an airfield
--- and a public beach. Suppressing every alert that ever happens there would
--- silence real crimes, which is a worse failure than the one this is fixing.
--- With no match running, nothing here suppresses anything.
--- @param point any -- a vector3, or any table carrying x/y/z
--- @return boolean
local function insideLiveArena(point)
    if type(point) ~= 'table' and type(point) ~= 'vector3' then return false end

    local px, py = tonumber(point.x), tonumber(point.y)
    if not px or not py then return false end

    -- Which arenas currently have somebody in them. Read from the same
    -- `active` table the player pin uses, so the two layers can never
    -- disagree about whether a match is running.
    for _, matchId in pairs(active) do
        local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId) or nil
        local arena = match and Arena.GetArenaByKey(match.arenaKey) or nil
        local boundary = arena and arena.boundary or nil

        if boundary and boundary.enabled ~= false and boundary.center then
            local cx, cy = tonumber(boundary.center.x), tonumber(boundary.center.y)
            local radius = tonumber(boundary.radius)

            if cx and cy and radius and radius > 0 then
                local dx, dy = px - cx, py - cy
                -- Compared squared, so no square root and no chance of a
                -- rounding difference between this and the client's own
                -- boundary check.
                if (dx * dx + dy * dy) <= (radius * radius) then return true end
            end
        end
    end

    return false
end

--- Should this firing be cancelled on the strength of WHERE it happened?
--- @param entry table
--- @param ... any
--- @return boolean
local function pinnedByLocation(entry, ...)
    if not entry.coordsArg then return false end

    local payload = (select(entry.coordsArg, ...))

    -- vector3 as well as table, to match what insideLiveArena accepts. These
    -- two disagreed: a payload that WAS the point rather than a table
    -- carrying one was rejected here, forty lines before the function that
    -- would have taken it.
    local kind = type(payload)
    if kind ~= 'table' and kind ~= 'vector3' then return false end

    if kind == 'vector3' then return insideLiveArena(payload) end

    -- Either the argument IS the point, or it is a table with the point
    -- under `coords` -- which is the shape a dispatch payload usually takes.
    return insideLiveArena(payload.coords or payload)
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

    -- A LOCATION-DECLARED ENTRY IS PINNED BY LOCATION OR NOT AT ALL. Falling
    -- through to `source` here was a real over-cancel: the caller has already
    -- decided the point was OUTSIDE every live arena, and FiveM leaves
    -- `source` set to whoever triggered the outermost net event -- so an
    -- alert about somewhere else entirely, raised anywhere inside an arena
    -- player's own call chain, was being cancelled on the strength of who
    -- happened to be at the top of the stack.
    if entry.coordsArg then return nil end

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

--- Event names this resource has actually seen fire, so the line above is
--- printed once per name rather than once per alert on a busy server.
--- @type table<string, boolean>
local sawFiring = {}

--- Job lists already reported, so the line below is once per KIND of alert
--- rather than once per alert.
--- @type table<string, boolean>
local sawJobs = {}

--- One console line, the first time an entry turns out to be unusable.
---
--- Once, and never per firing: an alert event on a busy server fires
--- constantly, and a warning printed every time would bury the console far
--- more effectively than the alerts it was trying to stop.
--- @param entry table
local function warnUnpinnable(entry)
    if warnedCancel[entry.event] then return end
    warnedCancel[entry.event] = true

    if entry.coordsArg then
        -- Telling an operator to add the coordsArg they already added is
        -- worse than saying nothing: it sends them to fix a line that is
        -- correct.
        ArenaLog('cancelEvents: "%s" fired but its location was not inside any arena with a live match, so it was left alone. That is the normal answer for an alert about somewhere else -- if it should have matched, check argument %d really carries the coordinates.',
            entry.event, entry.coordsArg)
        return
    end

    ArenaLog('cancelEvents: "%s" fired with no player behind it, so it was left alone. Say which argument carries the server id -- { event = \'%s\', playerArg = 1 } -- or, if the payload only says WHERE, which argument carries that -- { event = \'%s\', coordsArg = 1 } -- or drop it from the list.',
        entry.event, entry.event, entry.event)
end

--- Which jobs an alert was aimed at, as text, or nil when it does not say.
---
--- WHY THIS IS WORTH READING. On this family of dispatch scripts police and
--- EMS alerts travel the SAME event and differ only by the jobs named in the
--- payload -- so "the police stopped getting calls but the ambulance did
--- not" is not a thing that event can do. Printing the jobs turns that from
--- a guess into an observation: if EMS alerts are still arriving, this line
--- shows them arriving and being cancelled, and if they never appear then
--- they are coming from somewhere else entirely and no amount of work on
--- this event will ever reach them.
---
--- Read defensively -- it is another resource's payload, in whatever shape
--- that resource felt like, and this is a diagnostic rather than a
--- decision. Nothing is suppressed or allowed on the strength of it.
--- @param ... any
--- @return string|nil
local function jobsNamedIn(...)
    for index = 1, select('#', ...) do
        local argument = (select(index, ...))
        if type(argument) == 'table' then
            local jobs = argument.job_table or argument.jobs
            if type(jobs) == 'table' then
                local names = {}
                for _, job in ipairs(jobs) do
                    if type(job) == 'string' then names[#names + 1] = job end
                end
                if #names > 0 then return table.concat(names, ', ') end
            end
        end
    end
    return nil
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
    -- REGISTERED FOR THE NETWORK, and without this line the whole layer is
    -- dead for the events that matter most.
    --
    -- FXServer routes a network-sourced event only to resources that have
    -- called RegisterNetEvent for that name. A resource with AddEventHandler
    -- alone is never delivered it -- no error, no warning, the handler is
    -- simply never run. Every alert a script raises with TriggerServerEvent
    -- from a player's own client -- which is how gunfire and deaths are
    -- reported, because that is where they are detected -- was therefore
    -- passing this resource without ever touching it.
    --
    -- THE OLD REASON FOR NOT DOING THIS WAS WRONG, and worth stating because
    -- it read convincingly for a long time. It said RegisterNetEvent would
    -- "open somebody else's server-only event to clients". It does not:
    -- safe-for-net is per RESOURCE, so this marks the name callable into
    -- CRIMSON_ARENA's handlers and changes nothing about the resource that
    -- owns the event -- that one still needs its own RegisterNetEvent to be
    -- reachable, exactly as before.
    --
    -- What it does allow is a client invoking THIS handler with made-up
    -- arguments. That costs nothing: the handler's only power is
    -- CancelEvent(), which applies to the invocation it is running in --
    -- a forged one that no alert script is listening to. Cancelling a
    -- pretend alert achieves nothing at all.
    RegisterNetEvent(entry.event)

    AddEventHandler(entry.event, function(...)
        -- ONE LINE, THE FIRST TIME THIS HANDLER IS REACHED AT ALL.
        --
        -- It answers the only question worth asking when alerts keep coming
        -- through: is the event even being raised? "Nothing was cancelled"
        -- has two completely different causes and they need completely
        -- different fixes -- the handler never ran, so the alert script is
        -- calling an export instead of raising an event and NOTHING here can
        -- ever reach it; or the handler ran and declined, which is a pinning
        -- problem this file can solve. Without this line those are the same
        -- silence, and an operator cannot tell which they are looking at.
        local jobs = jobsNamedIn(...)

        if not sawFiring[entry.event] then
            sawFiring[entry.event] = true
            ArenaLog('cancelEvents: "%s" reached this resource for the first time -- the hook is live. If alerts still get through from here it is a pinning problem, not a plumbing one.',
                entry.event)
        end

        -- Once per set of jobs, not once per alert: a busy server raises
        -- these constantly, and the question this answers -- WHICH kinds of
        -- alert reach us at all -- is answered by the first of each kind.
        if jobs and not sawJobs[jobs] then
            sawJobs[jobs] = true
            ArenaLog('cancelEvents: an alert for [%s] came through "%s". Alerts for jobs never listed here are being raised somewhere this resource cannot see.',
                jobs, entry.event)
        end

        -- LOCATION FIRST, because it is the answer for the firings the player
        -- pin cannot see at all: an alert raised on the server with a payload
        -- describing where something happened and nothing about who.
        if pinnedByLocation(entry, ...) then
            CancelEvent()
            ArenaDebug('cancelEvents: cancelled "%s" -- it is about a spot inside a live arena.', entry.event)
            return
        end

        local src = responsibleFor(entry, ...)
        if not src then
            warnUnpinnable(entry)
            return
        end

        -- The whole safety of this layer is this one line: cancel for a
        -- player this resource is currently holding in a match, and nobody
        -- else. Read from the server's own record -- the same one the state
        -- bag is written from -- and never from anything the event carried.
        if not ArenaDispatch.IsPlayerInArena(src) then
            ArenaDebug('cancelEvents: "%s" fired for %s, who is not in a match -- left alone, which is correct.',
                entry.event, tostring(src))
            return
        end

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
