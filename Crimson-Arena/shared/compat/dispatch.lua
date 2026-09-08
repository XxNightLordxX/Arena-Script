-- Crimson Arena: talking to whichever dispatch script you run.

--[[
    crimson_arena/shared/compat/dispatch.lua

    THE POLICE AND EMS SCRIPTS THIS SERVER ACTUALLY RUNS, FOUND BY NAME,
    AND A STARTUP REPORT SAYING WHAT THE ARENA CAN DO ABOUT EACH ONE.

    WHY THIS FILE EXISTS. Everything else under Config.Dispatch is an
    integration an operator has to know they need before they go looking for
    it. This file takes the guessing out: at startup it looks up every
    dispatch and ambulance resource name it knows about, sees which of them
    are running on THIS server, and prints a short block naming each one,
    whether the arena is already handling it, and -- when it is not -- the
    exact line to paste and roughly where it goes. Nobody should have to
    wonder whether this is working.

    WHERE IT SITS IN THE LAYERS, strongest first:
      1. ROUTING BUCKET ISOLATION (Config.Dispatch.isolation, server side).
         A match is fought in its own network instance, so no OTHER player's
         client -- and therefore no dispatch or ambulance script running on
         one -- can see arena gunfire, arena bodies or arena entities at
         all. Needs nothing from anybody.
      2. THE DEAD STATE (Config.Dispatch.clearDeadStateImmediately,
         client/dispatch.lua). An arena death is put back on its feet in the
         same instant, so an EMS script that polls "is this player dead"
         never catches one -- and, since client/match.lua also catches the
         death from gameEventTriggered rather than only from its own watch
         loop, an EMS script that hooks CEventNetworkEntityDamage and asks
         IsEntityDead in that same frame gets told no as well. That is the
         one layer that stops a medical alert at the source.
      3. THIS FILE. Detection and the report. It changes nothing by itself;
         it tells an operator the truth about layers 4 and 5, for the
         resources they really run.
      4. THE HOOKS (Config.Dispatch.custom): entry/exit events, the
         server-written state bag, the exports, and operator-named disable
         exports.
      5. EVENT CANCELLING (Config.Dispatch.custom.cancelEvents). Best effort
         and nothing more: CancelEvent() does nothing unless the resource
         that raised the event checks WasEventCanceled(), and many do not --
         sc-dispatch among them. This file only COUNTS those entries for the
         report -- it cancels nothing itself.
      6. WITHDRAWING THE CALL (Config.Dispatch.custom.retract). What layer 5
         cannot be: the arena calls the dispatch script's OWN "clear this
         call" export for the id that script files an arena alert under, so
         the call is removed whether it cooperates or not. Counted as wired
         up in the report, unlike layer 5, for exactly that reason.

    THE LIMIT NOTHING HERE GETS PAST, said once and plainly: no FiveM
    resource can reach into another one and cancel its events. If a dispatch
    script polls IsPedShooting on the shooter's OWN client, nothing in this
    resource can stop that loop seeing it. Isolation hides the fight from
    every other machine on the server; for the fighter's own machine, the
    line this report prints -- pasted into the script that sends the alert
    -- is the only thing that works. Making sure an operator is told that in
    so many words, about the resources they actually run, is this file's
    whole job.

    WHAT AN ADAPTER MAY CLAIM. An adapter is a resource NAME, what that
    resource is ('police' | 'ambulance' | 'both'), and OPTIONALLY a mute
    function. Nothing in the catalogue below carries a mute, and that is
    deliberate: a third-party script's export names cannot be verified from
    inside this repository, and a guessed export name is the worst outcome
    available -- it detects as present, reports itself as handled, and
    silently does nothing, which is strictly worse than admitting the
    resource is unhandled. Detection on its own is still worth having,
    because detection is what drives the report. If you know the real ignore
    export for a script you run, the place for it is
    Config.Dispatch.custom.disableExports -- the report reads that list too,
    and credits the resources it names -- or a `mute` added to a
    registration below, out of THAT script's own documentation.

    BOTH REALMS. This is a shared_script: it is loaded into the client VM
    and the server VM as two independent copies. It works out which one it
    is in rather than assuming -- the catalogue and the detection walk are
    realm-agnostic and safe to call from either side, while the report, the
    adapter mutes and the /arenadispatch command are server-only. The report
    belongs on the operator's console, and "who may be ignored by dispatch"
    is not a decision a client takes part in.
]]

ArenaCompat = {}

local IS_SERVER = IsDuplicityVersion() == true

local STARTUP_GRACE_MS = 5000

--- A console line in the same voice as server/util.lua's ArenaLog, and
--- deliberately not ArenaLog itself: this file is shared, the client VM
--- never loads server/util.lua, and a bad registration has to be able to
--- complain from either realm at load time.
--- @param fmt string
--- @param ... any -- string.format arguments
local function say(fmt, ...)
    local text = fmt
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        text = ok and formatted or fmt
    end
    print(('[crimson_arena] %s'):format(text))
end

-- ======================================================================
-- CONFIG READERS
--
-- Every one of these reads Config on each call rather than caching at load
-- time, for the reason shared/arena.lua gives for its own catalogue
-- lookups: there must not be a second copy of a setting that can drift out
-- of sync with the first.
-- ======================================================================

local function dispatchConfig()
    return (Config and Config.Dispatch) or {}
end

local function customConfig()
    return dispatchConfig().custom or {}
end

local function stateKey()
    local key = customConfig().stateBagKey
    return Arena.IsKey(key) and key or 'crimsonArena'
end

local function enterEventName()
    local name = customConfig().enterEvent
    return Arena.IsKey(name) and name or nil
end

local function exitEventName()
    local name = customConfig().exitEvent
    return Arena.IsKey(name) and name or nil
end

local function disableExportFor(resource)
    local list = customConfig().disableExports
    if type(list) ~= 'table' then return nil end

    for _, entry in ipairs(list) do
        if type(entry) == 'table' and entry.resource == resource and Arena.IsKey(entry.export) then
            return entry.export
        end
    end
    return nil
end

local function hasLiveDisableExport()
    local list = customConfig().disableExports
    if type(list) ~= 'table' then return false end

    for _, entry in ipairs(list) do
        if type(entry) == 'table' and Arena.IsKey(entry.resource) and Arena.IsKey(entry.export)
            and GetResourceState(entry.resource) == 'started' then
            return true
        end
    end
    return false
end

local function hasLiveRetract()
    local block = customConfig().retract
    if type(block) ~= 'table' then return false end
    if not Arena.IsKey(block.resource) or not Arena.IsKey(block.export) then return false end
    if GetResourceState(block.resource) ~= 'started' then return false end

    local templates = block.idTemplates
    if type(templates) ~= 'table' then return false end
    for _, template in pairs(templates) do
        if Arena.IsKey(template) then return true end
    end
    return false
end

local function countList(list)
    if type(list) ~= 'table' then return 0 end
    local total = 0
    for _ in ipairs(list) do total = total + 1 end
    return total
end

local function cancelEventCount()
    local list = customConfig().cancelEvents
    if type(list) ~= 'table' then list = dispatchConfig().cancelEvents end
    if type(list) ~= 'table' then return 0 end

    local total = 0
    for key, entry in pairs(list) do
        if Arena.IsKey(entry) then
            total = total + 1
        elseif type(entry) == 'table' and Arena.IsKey(entry.event) then
            total = total + 1
        elseif entry == true and Arena.IsKey(key) then
            total = total + 1
        end
    end
    return total
end

local KINDS = {
    police = 'police',
    ambulance = 'EMS',
    both = 'police+EMS',
}

local adapters = {}
local byResource = {}

function ArenaCompat.RegisterAdapter(adapter)
    if type(adapter) ~= 'table' or not Arena.IsKey(adapter.resource) then
        say('compat: refused an adapter with no resource name.')
        return false
    end
    if not KINDS[adapter.kind] then
        say('compat: refused the adapter for "%s" -- kind must be police, ambulance or both.', adapter.resource)
        return false
    end
    if adapter.mute ~= nil and type(adapter.mute) ~= 'function' then
        say('compat: refused the adapter for "%s" -- mute must be a function or nil.', adapter.resource)
        return false
    end
    if adapter.reviveClientEvent ~= nil and not Arena.IsKey(adapter.reviveClientEvent) then
        say('compat: refused the adapter for "%s" -- reviveClientEvent must be an event name or nil.', adapter.resource)
        return false
    end

    local entry = {
        resource = adapter.resource,
        kind = adapter.kind,
        mute = adapter.mute,
        reviveClientEvent = adapter.reviveClientEvent,
    }
    local existing = byResource[adapter.resource]

    if existing then
        for index, current in ipairs(adapters) do
            if current.resource == adapter.resource then adapters[index] = entry break end
        end
    else
        adapters[#adapters + 1] = entry
    end

    byResource[adapter.resource] = entry
    return true
end

-- ======================================================================
-- THE CATALOGUE
--
-- The resource NAMES this server's police dispatch and EMS run under.
--
-- DELIBERATELY SHORT, AND KEPT THAT WAY. A generous catalogue is not free:
-- every name in here is a name an operator reading the report has to decide
-- is irrelevant to them, and a row that never matches is a row nobody has
-- ever tested against a running copy of the thing it claims to recognise.
-- What is in it is Qbox's own scripts and this server's own, both of which
-- can be checked.
--
-- ADDING ONE IS FOUR CHARACTERS PLUS A NAME, and worth doing the day this
-- server actually runs that script -- not before. See this file's header for
-- what an entry may and may not claim.
--
-- NOT ONE CARRIES A MUTE CALL, because not one of their export names can be
-- verified from inside this repository, and a guessed export name detects as
-- working and then silently does nothing. What an EMS entry may carry is a
-- `reviveClientEvent`, and only where that name was read out of the script's
-- own source -- see the note on those entries.
--
-- A DISPATCH BOARD IS FILED AS 'both'. It carries the person-down call as
-- well as shots-fired, so an operator whose EMS keeps getting paged can see
-- which resource is really sending it.
-- ======================================================================

local CATALOGUE = {
    { resource = 'sc-dispatch', kind = 'both' },            -- dispatch for police AND EMS on this family of scripts
    { resource = 'sc-police', kind = 'police' },
    { resource = 'qbx_policejob', kind = 'police' },
    { resource = 'qbx_police', kind = 'police' },           -- the shorter spelling some builds use

    { resource = 'sc-ambulance', kind = 'ambulance', reviveClientEvent = 'hospital:client:Revive' },
    { resource = 'qbx_ambulancejob', kind = 'ambulance', reviveClientEvent = 'hospital:client:Revive' },
    { resource = 'qbx_medical', kind = 'ambulance' },       -- Qbox's death and injury system: the one that watches the dead state
}

for _, entry in ipairs(CATALOGUE) do
    ArenaCompat.RegisterAdapter(entry)
end

local startedBeforeUs = {}

for _, entry in ipairs(CATALOGUE) do
    if GetResourceState(entry.resource) == 'started' then
        startedBeforeUs[#startedBeforeUs + 1] = entry.resource
    end
end

function ArenaCompat.StartedBeforeUs()
    local out = {}
    for _, name in ipairs(startedBeforeUs) do out[#out + 1] = name end
    return out
end

local warnedOnDeath = false

function ArenaCompat.WarnLateStartOnce()
    if warnedOnDeath or #startedBeforeUs == 0 then return false end
    warnedOnDeath = true

    say('A FIGHTER DIED AND %s ANSWERED FIRST.', table.concat(startedBeforeUs, ' / '))
    say('  Those resources started before this one, so their death handler runs before ours.')
    say('  They see the fighter as dead, enter their own down state, and the EMS call is')
    say('  already sent from the player\'s own client before anything here can run.')
    say('  This is why your ambulance job is still being paged for people in the arena.')
    say('  Fix: in server.cfg, move `ensure %s` ABOVE those lines, then restart the server.',
        GetCurrentResourceName())
    say('  If you cannot change the order, paste this at the top of whatever raises the alert:')
    say('      if Player(src).state.%s then return end        -- server realm', stateKey())
    say('      if LocalPlayer.state.%s then return end        -- client realm', stateKey())

    -- THE OTHER HALF OF THE SAME DECISION, AND IT PULLS THE OPPOSITE WAY.
    --
    -- The team outline's colour and shader are ONE setting for the whole
    -- game, not a property of a ped. Every resource that writes them every
    -- frame -- a target script highlighting what you look at, a job script
    -- marking a delivery -- overwrites whatever the last one wrote, and the
    -- winner is simply whoever ticks LAST, which is start order. So the
    -- outline wants this resource started last, and the paragraph above
    -- wants it started first.
    --
    -- An operator who takes the advice above and never reads this has a
    -- working ambulance job and a team outline that is on, drawing, and the
    -- wrong colour or invisible -- which reads as "the haze does not work",
    -- with nothing in any log disagreeing, because as far as this resource
    -- is concerned it drew it.
    --
    -- Both are fixable at once and this says how: the snippet above is what
    -- makes the death fix independent of order, which frees the order to go
    -- the way the outline needs.
    say('  NOTE, if you use the team outline: it wants the OPPOSITE order.')
    say('    The outline colour is one game-wide setting and the last resource to')
    say('    write it each frame wins, so being started first loses it. If your')
    say('    teammates are outlined in somebody else\'s colour, or not visibly at')
    say('    all, use the two lines above instead of the reorder and put')
    say('    `ensure %s` LAST.', GetCurrentResourceName())
    return true
end

--- Every catalogued resource that is running right now, in catalogue order.
---
--- DELIBERATELY NOT CACHED. GetResourceState is a cheap lookup and the
--- catalogue is a handful of names, so the whole walk is nothing --
--- while a cache would have to be invalidated every time an operator
--- restarted their dispatch script, and a stale "not detected" is exactly
--- the wrong answer for a file whose entire purpose is telling the truth
--- about what is running.
--- @return table[] running -- the adapter entries, in a fresh array
function ArenaCompat.Detect()
    local running = {}
    for _, adapter in ipairs(adapters) do
        if GetResourceState(adapter.resource) == 'started' then
            running[#running + 1] = adapter
        end
    end
    return running
end

--- The client events that clear a RUNNING medical script's own death record.
---
--- THE HALF THE ARENA CANNOT DO ITSELF. Standing a ped up is entirely within
--- this resource's gift and needs nobody's permission. A medical script's
--- list of who is a casualty is not: it lives inside that script, nothing
--- outside it can reach in, and a player left on that list is up and walking
--- while everything that script does to a corpse is still being done to them.
--- That is the state an operator reports as "the revive is not working" --
--- and the ped really is standing up, which is why it reads as a lie.
---
--- Only DETECTED resources are asked. A name from the catalogue that this box
--- does not run is not an event anybody is listening for.
--- @return string[] -- event names, each sent to the one player concerned
function ArenaCompat.ReviveClientEvents()
    local events, seen = {}, {}
    for _, adapter in ipairs(ArenaCompat.Detect()) do
        local name = adapter.reviveClientEvent
        if Arena.IsKey(name) and not seen[name] then
            seen[name] = true
            events[#events + 1] = name
        end
    end
    return events
end

--- Calls every detected adapter's mute, if it has one.
---
--- SERVER ONLY, and wired below to the same entry and exit events
--- server/dispatch.lua announces -- so an adapter mute is driven by the
--- server's own record of who is in a match, never by a client saying so.
---
--- One pcall per adapter: a third-party export that throws must not take a
--- match start or a match end down with it, which is the same rule
--- server/dispatch.lua's announce() and client/dispatch.lua's
--- callDisableExports() both already follow.
--- @param src number -- server id
--- @param active boolean -- true entering a match, false leaving it
--- @return integer called -- how many adapters were asked
function ArenaCompat.Mute(src, active)
    if not IS_SERVER then return 0 end
    if type(src) ~= 'number' or src <= 0 then return 0 end

    local called = 0
    for _, adapter in ipairs(ArenaCompat.Detect()) do
        if adapter.mute then
            local ok, err = pcall(adapter.mute, src, active == true)
            if ok then
                called = called + 1
            else
                say('compat: the mute for "%s" errored (%s). Check that export against that resource\'s own documentation.',
                    adapter.resource, tostring(err))
            end
        end
    end
    return called
end

-- ======================================================================
-- THE REPORT
-- ======================================================================

local function statusOf(adapter)
    if adapter.mute then
        if not enterEventName() then
            return 'has a mute, but custom.enterEvent is nil so nothing triggers it'
        end

        if not exitEventName() then
            return 'muted on entry and NEVER UNMUTED -- custom.exitEvent is nil, so anyone who walks into the arena keeps this resource silenced for the rest of their session'
        end

        return 'muted automatically -- this resource carries a mute for it'
    end

    local exportName = disableExportFor(adapter.resource)
    if exportName then
        return ('muted automatically -- disableExports calls exports.%s:%s'):format(adapter.resource, exportName)
    end

    return nil
end

--- Whether anything in this setup demonstrably reaches a dispatch script.
--- It gates both the paste block and the caveat on the isolation line, and
--- it is deliberately hard to satisfy.
---
--- THE DEFECT IT ANSWERS. "Nothing detected" used to read as "nothing to
--- do", because the count it was gated on could only ever be raised by a
--- row -- so the paste block printed for a script the catalogue recognised
--- and stayed silent for one it had never heard of. The catalogue is a list
--- of names to LOOK FOR, not a census: finding none of them says nothing
--- whatsoever about what this box runs, and the operator running an unknown
--- dispatch script is precisely the one with nobody else to tell them.
---
--- cancelEvents is NOT counted, on config.lua's own instruction: if it is
--- the only form filled in, assume the alerts are still being sent.
--- @param running table[] -- ArenaCompat.Detect()
--- @param unhandled integer -- detected rows statusOf() could not account for
--- @return boolean
local function somethingWired(running, unhandled)
    if unhandled > 0 then return false end
    if #running > 0 then return true end

    return hasLiveDisableExport() or hasLiveRetract()
end

local function isolationLine(wired)
    local isolation = dispatchConfig().isolation
    if type(isolation) ~= 'table' then return nil end

    if isolation.enabled ~= true then
        return 'Isolation is off (Config.Dispatch.isolation) -- every client on the server can see arena gunfire and arena bodies. It is the one layer that needs nothing from anybody.'
    end

    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.IsolationState) == 'function' then
        local state = ArenaDispatch.IsolationState()
        if state and state.inForce == false then
            if state.provenInert then
                return 'Isolation is CONFIGURED ON BUT NOT IN FORCE: a player was put into a routing bucket and the server reported them somewhere else, so the routing natives are doing nothing here. Every client can see arena gunfire and arena bodies. Run /arenaisolation for the readings.'
            end
            return 'Isolation is CONFIGURED ON BUT NOT IN FORCE: this server has OneSync off (`set onesync on` in server.cfg), and routing buckets need it -- the natives do nothing without it. Every client can see arena gunfire and arena bodies, and two matches cannot share one arena.'
        end
    end
    if not wired then
        return 'Isolation is on: no OTHER player\'s client can see the fight. An arena player\'s own client still can, and nothing here is confirmed wired -- that is what the line below is for.'
    end
    return 'Isolation is on: no OTHER player\'s client can see the fight.'
end

--- Whether anything this file can see actually rides the entry/exit events.
---
--- THE DEFECT THIS ANSWERS. Both event names ship non-nil in config.lua, so
--- an install nobody has touched has them set -- and reading a name as
--- configuration told every such operator they had wired up entry/exit
--- events when what they had was a default firing into an empty room. A
--- name is not a listener. What counts is something demonstrably riding
--- them: a detected adapter carrying a mute this file calls off the entry
--- event itself.
--- @param running table[] -- ArenaCompat.Detect()
--- @return boolean
local function eventsAreRidden(running)
    if not enterEventName() then return false end

    for _, adapter in ipairs(running) do
        if adapter.mute then return true end
    end
    return false
end

local function hookLine(running)
    local parts = {}
    local enter, exit = enterEventName(), exitEventName()
    local ridden = eventsAreRidden(running)

    if ridden then
        if enter and exit then
            parts[#parts + 1] = 'entry/exit events'
        elseif enter or exit then
            parts[#parts + 1] = enter and 'entry event only' or 'exit event only'
        end
    end

    local exportCount = countList(customConfig().disableExports)
    if exportCount > 0 then parts[#parts + 1] = ('%d disableExport(s)'):format(exportCount) end

    local cancelCount = cancelEventCount()
    if cancelCount > 0 then
        parts[#parts + 1] = ('%d alert event(s) watched -- DIAGNOSTIC ONLY, they suppress nothing')
            :format(cancelCount)
    end

    if hasLiveRetract() then
        parts[#parts + 1] = ('retract via exports.%s:%s'):format(customConfig().retract.resource, customConfig().retract.export)
    end

    -- Named but unridden still earns a clause, because the events really do
    -- fire: an operator who has written a listener this file cannot see must
    -- not be told they have none. It is stated as a fact about the events
    -- rather than banked as credit for an integration -- this file can see a
    -- mute it calls itself, and nothing else.
    local tail = ''
    if not ridden and (enter or exit) then
        tail = ' The entry/exit events fire, but nothing here can see a listener for them.'
    end

    if #parts == 0 then
        return ('Hooks configured: none -- the state bag is written either way.%s /arenadispatch re-runs this report.'):format(tail)
    end
    return ('Hooks configured: %s.%s /arenadispatch re-runs this report.'):format(table.concat(parts, ', '), tail)
end

--- The startup block, as lines. Kept to a handful on purpose: an operator
--- who meets a wall of text at every restart stops reading it, and this is
--- the one block that has to still be read on the hundredth boot.
--- @return string[] lines
function ArenaCompat.Report()
    local lines = {}
    local running = ArenaCompat.Detect()
    local unhandled = 0

    if #running == 0 then
        lines[#lines + 1] = 'dispatch compat: no police or EMS resource recognised by name.'
        lines[#lines + 1] = '  If you run one, it is named something this catalogue does not know -- add the name in shared/compat/dispatch.lua, and wire it up with Config.Dispatch.custom.'
    else
        lines[#lines + 1] = ('dispatch compat: %d police/EMS resource(s) running.'):format(#running)
        for _, adapter in ipairs(running) do
            local status = statusOf(adapter)
            if not status then unhandled = unhandled + 1 end
            lines[#lines + 1] = ('  %-20s %-11s %s'):format(adapter.resource, KINDS[adapter.kind], status or 'NOT muted -- needs the line below')
        end
    end

    local wired = somethingWired(running, unhandled)

    local isolation = isolationLine(wired)
    if isolation then lines[#lines + 1] = isolation end

    if not wired then
        lines[#lines + 1] = '  Paste at the top of whatever sends the alert, in that script:'
        lines[#lines + 1] = ('      if Player(src).state.%s then return end        -- server realm'):format(stateKey())
        lines[#lines + 1] = ('      if LocalPlayer.state.%s then return end        -- client realm'):format(stateKey())
    end

    lines[#lines + 1] = hookLine(running)

    local late = ArenaCompat.StartedBeforeUs()
    if #late > 0 then
        lines[#lines + 1] = ('start order: %s started BEFORE this resource, so it answers a death first.')
            :format(table.concat(late, ', '))
        lines[#lines + 1] = '  That is the one thing here that cannot be fixed from inside this resource.'
        lines[#lines + 1] = '  An EMS call raised that way is already past anything the arena can cancel.'
        lines[#lines + 1] = '  Fix: in server.cfg, put `ensure ' .. GetCurrentResourceName() .. '` ABOVE those lines and restart.'
    else
        lines[#lines + 1] = 'start order: this resource started first, so it answers a death before any emergency script does.'
    end

    local detected = ArenaCompat.ReviveClientEvents()
    if #detected > 0 then
        lines[#lines + 1] = ('revive: %d detected medical script(s) are told to revive a player directly -- %s.')
            :format(#detected, table.concat(detected, ', '))
    else
        lines[#lines + 1] = 'revive: NOTHING IS TELLING YOUR MEDICAL SCRIPT. No script this catalogue knows is'
        lines[#lines + 1] = '  running, so a player who dies in a match walks out of the arena'
        lines[#lines + 1] = '  still dead as far as that script is concerned.'
        lines[#lines + 1] = '  Their PED is fine -- the arena stands it up in the frame they died and again on'
        lines[#lines + 1] = '  respawn. What is missing is the handoff: nothing has told the script that keeps'
        lines[#lines + 1] = '  its own list of who is down.'
        lines[#lines + 1] = '  Fix: add your medical script to the catalogue in shared/compat/dispatch.lua, with the'
        lines[#lines + 1] = '       revive event it listens for -- read out of its own source, never guessed.'
    end

    return lines
end

local function printReport(lines)
    for _, line in ipairs(lines) do say('%s', line) end
end

if IS_SERVER then
    local enter, exit = enterEventName(), exitEventName()

    if enter then
        AddEventHandler(enter, function(src)
            ArenaCompat.Mute(src, true)
        end)
    end

    if exit then
        AddEventHandler(exit, function(src)
            ArenaCompat.Mute(src, false)
        end)
    end

    AddEventHandler('onResourceStart', function(resource)
        if resource ~= GetCurrentResourceName() then return end

        CreateThread(function()
            Wait(STARTUP_GRACE_MS)
            printReport(ArenaCompat.Report())
        end)
    end)

    RegisterCommand('arenadispatch', function(src)
        if type(ArenaIsAdmin) ~= 'function' or not ArenaIsAdmin(src) then
            if src ~= 0 and type(ArenaNotifyKey) == 'function' then
                ArenaNotifyKey(src, 'error.no_permission', 'error')
            end
            return
        end

        local lines = ArenaCompat.Report()
        printReport(lines)

        if src ~= 0 and type(ArenaNotify) == 'function' then
            ArenaNotify(src, table.concat(lines, '\n'), 'info')
        end
    end, false)
end
