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

    -- THE BAG GOES FIRST, and the order is the contract rather than the
    -- tidier of two arrangements. Set() writes the flag and THEN announces,
    -- so a handler on the entry event that reads the bag -- the obvious way
    -- for a third-party script to find out which match -- sees it. Announce
    -- the exit before clearing and that same handler reads a player who is
    -- still flagged, concludes they are still fighting, and leaves whatever
    -- it was suppressing suppressed: the flag outliving its match, which is
    -- the one failure this function exists to prevent.
    --
    -- Guarded because a player who has already dropped has no state bag to
    -- write to, and the disconnect path reaches here after they are gone.
    -- The announcement below runs either way -- a bag that cannot be
    -- written is no reason to leave somebody muted.
    local ok = pcall(function()
        Player(src).state:set(stateKey(), nil, true)
    end)
    if not ok then
        ArenaDebug('dispatch: could not clear the arena flag for %s -- they are most likely already gone.', tostring(src))
    end

    -- Announced even when nothing was set, so a dispatch script that missed
    -- the enter -- it restarted, it was not running yet -- still gets told to
    -- drop this player rather than keeping them ignored forever. A clear for
    -- somebody who was never flagged is a harmless no-op on its side.
    announce(customConfig().exitEvent, src, matchId)
end

-- ======================================================================
-- READING THE FACT
-- ======================================================================

--- @param src number
--- @return boolean

-- ======================================================================
-- NO PERMISSIONS ARE ASKED FOR, AND NONE ARE GRANTED
--
-- This resource used to try to give ITSELF the rights its revive command
-- needed -- `add_ace` for the command, and failing that `add_principal` into
-- the admin group. Both are gone, and neither is coming back.
--
-- IT DID NOT WORK. A server that lets a resource write its own permissions
-- is a server with no permissions, so the sensible ones refuse, and a
-- refusal is not an error: ExecuteCommand returns normally, the console
-- prints "Access denied", and the arena carried a page of config explaining
-- a capability it did not have.
--
-- IT WAS NOT NEEDED EITHER. The arena revives its own players directly --
-- NetworkResurrectLocalPlayer plus the flags it set itself -- and asks
-- nobody's permission to undo something it did. The command hooks below
-- exist only to tell a SEPARATE medical script, which keeps its own death
-- list that no amount of resurrecting a ped reaches.
--
-- AND IT COST SOMETHING REAL. Admin group membership made any flaw anywhere
-- in this resource a way to run any command on the box, in exchange for a
-- capability that was no longer used.
--
-- If your own revive command is gated on an ace and you want the arena to be
-- able to run it, grant that yourself in server.cfg, where the console is
-- doing the granting and nothing has to ask:
--
--     add_ace resource.Crimson-Arena command.revive allow
-- ======================================================================

--- Clears the medical script's own down-state metadata for one player.
---
--- The keys come from Config.Dispatch.revive.clearMetadata, so an operator
--- whose script uses different names says so rather than being guessed at --
--- and an empty list switches this off entirely. The two shipped names are
--- the QB-family convention and are the ones this file's own catalogue
--- already documents sc-ambulance setting.
---
--- WRITES NOTHING IT DOES NOT HAVE TO. A key that is already false or absent
--- is left alone, so on a server using neither name this costs two lookups
--- and touches nobody's data.
--- @param src number
--- @return integer cleared -- how many keys were really changed
local function clearDownMetadata(src)
    local revive = (Config.Dispatch or {}).revive
    local keys = type(revive) == 'table' and revive.clearMetadata or nil
    if type(keys) ~= 'table' or #keys == 0 then return 0 end

    -- Guarded rather than assumed: this file is loaded on its own by
    -- tests/dispatch_spec.lua, and a framework that does not expose a player
    -- object at all is a framework this simply has nothing to say to.
    if type(ArenaGetPlayer) ~= 'function' then return 0 end

    local player = ArenaGetPlayer(src)
    local functions = player and player.Functions
    if type(functions) ~= 'table' then return 0 end
    if type(functions.SetMetaData) ~= 'function' then return 0 end

    local cleared = 0
    for _, key in ipairs(keys) do
        if Arena.IsKey(key) then
            -- READ FIRST. GetMetaData is not on every build of every
            -- framework, so a missing reader means "write it anyway" rather
            -- than "do nothing" -- the write is the point and it is
            -- idempotent. What the reader buys is silence on the common case.
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
--- @param keepHold boolean|nil -- true on elimination: the round is still running
function ArenaDispatch.Revive(src, keepHold)
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
    TriggerClientEvent('crimson_arena:client:revive', src, nil, keepHold == true)

    -- AND THE MEDICAL SCRIPT'S OWN RECORD, for every one this box is really
    -- running, without the operator naming a thing.
    --
    -- This is the half the arena cannot do by resurrecting: a medical script
    -- keeps its own list of who is down, nothing outside it can reach that
    -- list, and a player still on it is up and walking while everything that
    -- script does to a casualty is still being done to them. It is the exact
    -- state reported as "the revive is not working" -- and the ped genuinely
    -- is standing up, which is what makes it read as a lie.
    --
    -- The names come from shared/compat/dispatch.lua's catalogue and only for
    -- resources actually detected. An event no running resource listens for
    -- is a no-op, so this cannot do harm; a WRONG name would, which is why
    -- every one in that catalogue was read out of the script's own source.
    if type(ArenaCompat) == 'table' and type(ArenaCompat.ReviveClientEvents) == 'function' then
        for _, name in ipairs(ArenaCompat.ReviveClientEvents()) do
            TriggerClientEvent(name, src)
            ArenaDebug('revive: also told %s for %d.', name, src)
        end
    end

    -- THE MEDICAL SCRIPT'S OWN RECORD OF WHO IS DOWN, cleared where it
    -- actually lives.
    --
    -- This file has always said it cannot reach that record. One part of it
    -- it can: the QB-family scripts keep the down state as PLAYER METADATA
    -- on the framework object -- `inlaststand` and `isdead` -- and that is
    -- qbx_core's data, not theirs, so the arena can write it.
    --
    -- It is the lever that does not depend on winning a race. The start-order
    -- fight upstream is about stopping the flag being SET; this clears it
    -- again a moment later, and everything downstream reads the flag rather
    -- than the event:
    --
    --   sc-dispatch's client polls this metadata every 500ms and raises
    --   PlayerDown / PlayerDead by itself when it goes up. Cleared before the
    --   next poll, those two are never raised at all -- not cancelled, not
    --   withdrawn, never sent.
    --
    --   sc-ambulance's own EMSDownAlert handler admits the call ONLY for a
    --   player carrying `inlaststand`. Cleared, the alert is refused by that
    --   script's own guard rather than by anything here.
    --
    -- AND IT IS TRUE, which is the part that makes it safe rather than a
    -- trick. The arena has just stood this player up: they are not dead and
    -- not in a last stand, and the metadata saying otherwise is the thing
    -- that is wrong. Nothing is written for a player the arena is not
    -- currently holding, and nothing is written for a key that is not already
    -- set -- on a server that does not use these names this is a no-op that
    -- costs two table lookups.
    clearDownMetadata(src)

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

    -- NOT gated on revive.enabled, and that is the point.
    --
    -- It used to return here saying "nothing would be called, nothing was",
    -- which stopped being true the moment the arena started reviving players
    -- itself: the built-in revive runs first and unconditionally, so with
    -- `enabled = false` this command was refusing to do the one thing that
    -- actually works, and telling an admin on the floor that nothing could
    -- be done for them.
    local revive = (Config.Dispatch or {}).revive
    local handoff = type(revive) == 'table' and revive.enabled == true

    ArenaLog('arenarevive: running the end-of-match revive against %d. Everything below is what a real match would do.',
        target)
    ArenaDispatch.Revive(target)

    if handoff then
        ArenaLog('arenarevive: done. %d has been stood up by the arena, and the handoff in Config.Dispatch.revive ran as well.',
            target)
        ArenaLog('arenarevive: if %d is up but something still treats them as dead, the arena has done its part -- that is your medical script\'s own death list, and it needs its revive named in Config.Dispatch.revive.',
            target)
    else
        ArenaLog('arenarevive: done. %d has been stood up by the arena. Config.Dispatch.revive.enabled is off, so no other script was told -- which is fine unless one of them keeps its own death list.',
            target)
    end
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

--- network id -> server id, for the crossfire guard. Rebuilt whenever a
--- lookup cannot be confirmed; see ownerOfNetId.
--- @type table<integer, number>
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

--- What an operator typed, read as a yes or a no.
---
--- Convar booleans are free text: `set onesync_enabled 1`, `true`, `yes` and
--- `on` all mean the same thing to the server and arrive here as four
--- different strings. Case is not normalised by the server either, so it is
--- normalised here.
--- @param value any
--- @return boolean
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

--- The mode, for the startup report -- which has to describe what the server
--- IS rather than what config asked for.
--- @return string
function ArenaDispatch.OneSync()
    return oneSyncMode()
end

--- Said once, not once per match. An operator restarting into a misconfigured
--- server should see this; they should not have it printed at every round.
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

--- Whether routing buckets actually work here.
---
--- ONLY A DEFINITE 'off' REFUSES. Anything unrecognised is treated as
--- working, because it is far more likely to be a build newer than this file
--- than a mode that lacks buckets -- and guessing wrong in that direction
--- would switch off a layer that was doing its job.
--- @return boolean
local function bucketsAvailable()
    -- WHAT THE SERVER PROVED BEATS WHAT THE SERVER SAID. A convar is a
    -- statement of intent; a move that did not land is a measurement. See
    -- moveTo below for how one is taken.
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

--- Opt-OUT rather than opt-in: an operator upgrading from a config that
--- predates this block gets the isolation, because it is the setting that
--- protects them without their dispatch script agreeing to anything.
---
--- AND IT ASKS THE SERVER, NOT ONLY THE CONFIG. Reading the setting alone
--- answered "is isolation wanted"; what every caller needs is "is isolation
--- HAPPENING". Returning true on a server whose routing natives are inert
--- told server/match.lua the arena was safe to share, and it let a second
--- match start on top of a live one. With this false, GetBucket returns nil
--- and that same code refuses the second match instead -- which is the
--- fallback it was written for.
--- @return boolean
local function isolationEnabled()
    if isolationConfig().enabled == false then return false end
    return bucketsAvailable()
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

--- Which instance the SERVER says this player is in, right now.
---
--- ASKED RATHER THAN REMEMBERED, and guarded, because both halves matter. A
--- player who dropped between the roster being read and this line is an
--- error thrown inside a loop that is holding everybody else's instancing
--- together, and the answer for them is the default world either way.
--- @param src number
--- @return integer
local function currentBucket(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return Arena.ToInt(bucket) or 0
end

--- Whether the server still has this player, so a bucket that did not take
--- can be told apart from a player who left while it was being set.
---
--- Answered conservatively: anything other than a positively returned name
--- is read as "cannot tell", and a move is never held against the server on
--- a reading this function could not take.
--- @param src number
--- @return boolean
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
    -- GUARDED, BUT THE RESULT IS NOT THE ANSWER. Whether the call returned
    -- is a fact about this Lua runtime; whether the player moved is a fact
    -- about the server, and only the second one is being asked. The read
    -- below settles it either way, so the pcall is here to keep a native
    -- that throws from taking the rest of a match start down with it and
    -- for nothing else.
    pcall(SetPlayerRoutingBucket, src, bucket)

    if currentBucket(src) == bucket then return true end

    -- A player who has gone cannot be moved and cannot be read back, and
    -- neither says anything about whether buckets work here. Asked only
    -- AFTER the reading disagrees, because a move that landed needs no
    -- alibi.
    if not stillConnected(src) then return false end

    -- SAID ONCE, and by arithmetic rather than by a flag checked here.
    -- moveTo is only ever reached through EnterBucket, which reaches it only
    -- after GetBucket handed back a number -- and GetBucket answers nil for
    -- every match from the moment the line below runs. So the second player
    -- into a broken server never gets this far, and a guard against saying
    -- it twice would be a guard against something that cannot happen.
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
        -- In some other match's instance. Restore first, so `previous` below
        -- is the bucket they originally came from rather than one of ours.
        ArenaDispatch.ExitBucket(src)
    end

    local previous = currentBucket(src)

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

    -- RECORDED BEFORE THE MOVE, AND KEPT EVEN IF THE MOVE IS REFUSED. The
    -- record is what ExitBucket reads to put this player back where they
    -- came from; dropping it on a failed move would strand anyone the server
    -- HAD moved before it started refusing.
    return moveTo(src, bucket)
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

-- ======================================================================
-- /arenaisolation -- THE ANSWER TO "IS IT ROUTING THE BUCKET?"
--
-- WHY A COMMAND AND NOT ANOTHER LOG LINE. Isolation failing looks, from the
-- console, exactly like isolation working: the allocation runs, the moves
-- run, and every line this file prints is about what it decided rather than
-- about what the server did with it. An operator standing in an arena
-- watching another match happen on top of theirs had no way to turn that
-- into a fact, and neither did anybody they reported it to.
--
-- This prints the measurement instead of the intent: the mode the server
-- reports, whether a move has ever been caught not landing, the bucket each
-- live match was allocated, and -- the line that settles it -- the bucket the
-- server says each of those players is standing in RIGHT NOW, read back one
-- at a time. Two rows with the same number and two different match ids is
-- the whole diagnosis.
-- ======================================================================
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

    -- READ BACK FROM THE SERVER, not from this file's own record. The record
    -- is the claim under investigation.
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

-- ======================================================================
-- CROSSFIRE
--
-- Nobody outside a round may shoot into it, and nobody in one may shoot
-- out. Reported from the game about the trailer park, which is the arena
-- where it matters: the sky one hangs over open water with nobody within a
-- kilometre, and the trailer park is a real place people drive past.
--
-- WHY THE ROUTING BUCKET IS NOT ALREADY THE ANSWER. It is, for the ordinary
-- case -- a player outside the match is in a different network instance and
-- cannot see, hit or be hit by anyone inside. Three cases fall outside that:
--
--   A SPECTATOR IS PUT IN THE MATCH'S OWN BUCKET, because watching requires
--   seeing. Their body is hidden, frozen and collisionless while the camera
--   runs, but the camera stops itself when it runs out of fighters to
--   follow, and the stop hands the body back. Until they leave, they are a
--   player standing in a live round with a gun.
--
--   ISOLATION MAY NOT BE IN FORCE. Buckets need OneSync; an operator can
--   also switch them off. Either way every line of the instancing still
--   runs and nothing is separated.
--
--   AND IT IS THE WRONG PLACE TO REST A SAFETY PROPERTY ANYWAY. "Nobody can
--   shoot across this line" should not be an emergent consequence of a
--   network optimisation that four other things also depend on.
--
-- SO THIS IS THE AUTHORITATIVE LAYER, and it is server-side because only the
-- server knows who is in which match.
--
-- CANCELEVENT REALLY DOES WORK HERE, unlike on the dispatch alerts below --
-- and the two are worth keeping straight. Down there the event is raised by
-- another RESOURCE, and cancelling only raises a flag that a resource which
-- never calls WasEventCanceled() will ignore. weaponDamageEvent and
-- explosionEvent are raised by the SERVER itself from a client's network
-- packet, and the server is what reads the cancellation: cancelled, the
-- damage is never applied and never replicated. There is nobody else to
-- cooperate.
-- ======================================================================

--- @return table
local function crossfireConfig()
    return (Config.Match or {}).crossfireGuard or {}
end

--- Opt-OUT, like the isolation above and for the same reason: an operator
--- upgrading from a config written before this block gets the protection
--- without having to know it exists.
--- @return boolean
local function crossfireEnabled()
    return crossfireConfig().enabled ~= false
end

--- A damage packet naming more entities than this is not a shot, it is a
--- payload. A shotgun hits a handful; nothing legitimate hits thirty-two.
local MAX_HITS = 32

--- Which player owns a network id right now, or nil.
---
--- CACHED AND THEN VERIFIED, rather than trusted. A ped's network id changes
--- when the player respawns, so a cache alone goes stale in exactly the
--- situation this guard runs in -- and a stale answer here does not fail
--- safe in one direction: resolving a fighter's new id to nobody would let
--- an outsider shoot them, and resolving it to the wrong player would cancel
--- damage inside a legitimate round. So the cached answer is confirmed
--- against the world before it is used, which is two natives rather than a
--- walk of every player on the server.
--- @param netId integer
--- @return number|nil src
local function ownerOfNetId(netId)
    local cached = netIdOwners[netId]
    if cached and netIdOf(cached) == netId then return cached end

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
--- SELF-DAMAGE FALLS OUT OF THE RULE rather than being special-cased. A
--- fall or your own grenade compares a player's match against itself, which
--- is equal whether that is a match id or nil -- so it is allowed, which is
--- right: it is not crossfire, and refusing it would make a fighter immortal
--- to the one thing the arena does not control. An explicit early return for
--- it was written here first and taken back out: mutation testing showed it
--- could not change the answer, and this file does not keep lines that
--- assert behaviour nothing exercises.
--- @param attacker number
--- @param victim number
--- @return boolean
local function mayDamage(attacker, victim)
    local attackerMatch, victimMatch = active[attacker], active[victim]
    if attackerMatch == nil and victimMatch == nil then return true end
    return attackerMatch ~= nil and attackerMatch == victimMatch
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    if not crossfireEnabled() then return end

    -- THE CHEAPEST ANSWER FIRST. With nobody in an arena there is nothing to
    -- separate, which is how a server spends almost all of its time -- and
    -- this handler is on the path of every shot fired anywhere on it.
    if next(active) == nil then return end

    local attacker = tonumber(sender)
    if not attacker then return end

    local hits = type(data) == 'table' and data.hitGlobalIds or nil
    if type(hits) ~= 'table' then return end

    -- A list this long is a crafted packet rather than a shot. Refused
    -- rather than scanned: the scan is what it is trying to buy.
    if #hits > MAX_HITS then
        ArenaDebug('crossfire: refused a damage packet from %s naming %d entities.', tostring(attacker), #hits)
        CancelEvent()
        return
    end

    for _, entry in ipairs(hits) do
        local netId = tonumber(entry)
        local victim = netId and ownerOfNetId(netId) or nil
        if victim and not mayDamage(attacker, victim) then
            ArenaDebug('crossfire: %s may not damage %s -- they are not in the same round.',
                tostring(attacker), tostring(victim))
            CancelEvent()
            return
        end
    end
end)

AddEventHandler('explosionEvent', function(sender, data)
    if not crossfireEnabled() then return end
    if next(active) == nil then return end

    -- Somebody fighting in the round may explode things in it. This is about
    -- what arrives from OUTSIDE, which is the half a bucket cannot help with
    -- once isolation is not in force -- and an explosion is the one weapon
    -- whose reach does not care whether you can see what you are hitting.
    local exploder = tonumber(sender)
    if exploder and active[exploder] then return end

    if type(data) ~= 'table' then return end
    local x, y, z = tonumber(data.posX), tonumber(data.posY), tonumber(data.posZ)
    if not x or not y then return end

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

--- @return table
local function retractConfig()
    local block = customConfig().retract
    return type(block) == 'table' and block or {}
end

--- Withdraws the call this event is about to create, for a player who is in
--- a match right now.
---
--- Every failure here is a console line and never a throw: this runs inside
--- somebody else's event handler, and an error raised in it would surface as
--- that resource misbehaving.
--- @param entry table -- a normalised cancelEvents entry
--- @param src number -- the arena player the alert is about
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
            local id = template:format(src, at + offset)
            local ok, err = pcall(function()
                exports[config.resource][config.export](nil, id)
            end)
            if not ok then
                -- Once per resource, not once per alert: a round produces
                -- these every few seconds and a per-call warning would bury
                -- the console it is trying to inform.
                if not sawFiring['retract:err:' .. config.resource] then
                    sawFiring['retract:err:' .. config.resource] = true
                    ArenaLog('retract: %s:%s failed (%s). Check that export name against that resource\'s own documentation.',
                        config.resource, config.export, tostring(err))
                end
                return
            end
        end

        ArenaDebug('retract: withdrew the call "%s" would have left standing for %s.', entry.event, tostring(src))
    end)
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

        -- And then the layer that does not depend on the other resource
        -- agreeing to anything. The flag above is free and occasionally
        -- lands; this is what removes the call on a script that ignores it.
        retractFor(entry, src)
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
