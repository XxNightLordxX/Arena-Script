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
         never catches one.
      3. THIS FILE. Detection and the report. It changes nothing by itself;
         it tells an operator the truth about layers 4 and 5, for the
         resources they really run.
      4. THE HOOKS (Config.Dispatch.custom): entry/exit events, the
         server-written state bag, the exports, and operator-named disable
         exports.
      5. EVENT CANCELLING (Config.Dispatch.custom.cancelEvents). Best effort
         and nothing more: CancelEvent() does nothing unless the resource
         that raised the event checks WasEventCanceled(), and many do not.
         This file only COUNTS those entries for the report -- it cancels
         nothing itself.

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

-- ======================================================================
-- REALM, AND THE ONE CONSOLE VOICE
-- ======================================================================

--- Worked out once, for the life of this VM. IsDuplicityVersion() is the
--- native that answers "am I the server" from a file loaded into both;
--- assuming a realm in a shared_script is how a client ends up calling a
--- server-only native and taking the file down with it at load time.
local IS_SERVER = IsDuplicityVersion() == true

--- How long after our own start the first report waits before looking.
--- Resource start order is not guaranteed, so a dispatch script listed
--- below this one in server.cfg has not started yet at t=0 -- reporting
--- then would print a confident "nothing detected" that is simply wrong.
--- The report prints once, so the wait costs nothing, and /arenadispatch
--- re-runs the whole detection live whenever it is asked.
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
        -- A broken format string in a diagnostic must never take down the
        -- diagnostic, so it degrades to the raw template -- the same trade
        -- server/util.lua's own compose() makes.
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

--- @return table
local function dispatchConfig()
    return (Config and Config.Dispatch) or {}
end

--- @return table
local function customConfig()
    return dispatchConfig().custom or {}
end

--- The state bag key a third-party script reads. Same default as
--- server/dispatch.lua's own stateKey(), and both read the same setting, so
--- the line this report tells an operator to paste is the key that is
--- really being written.
--- @return string
local function stateKey()
    local key = customConfig().stateBagKey
    return Arena.IsKey(key) and key or 'crimsonArena'
end

--- The event server/dispatch.lua announces arena entry on -- which is also
--- what this file hangs its adapter mutes off. Nil when the operator has
--- set it to nil, in which case a mute-carrying adapter has no trigger and
--- the report says so instead of claiming a mute that cannot fire.
--- @return string|nil
local function enterEventName()
    local name = customConfig().enterEvent
    return Arena.IsKey(name) and name or nil
end

--- @return string|nil
local function exitEventName()
    local name = customConfig().exitEvent
    return Arena.IsKey(name) and name or nil
end

--- The operator's own ignore export for this resource, if they named one.
--- client/dispatch.lua really calls these on entry and exit, which is what
--- makes "muted automatically" a true statement in the report rather than a
--- hopeful one.
--- @param resource string
--- @return string|nil exportName
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

--- Whether the operator named this resource in resyncResources. They only
--- do that for a script they have already wired to the entry/exit events,
--- so it is good evidence they have handled it -- evidence, not proof,
--- which is why the report words that row as an assumption.
--- @param resource string
--- @return boolean
local function inResyncList(resource)
    local list = customConfig().resyncResources
    if type(list) ~= 'table' then return false end

    for _, name in ipairs(list) do
        if name == resource then return true end
    end
    return false
end

--- @param list any
--- @return integer
local function countList(list)
    if type(list) ~= 'table' then return 0 end
    local total = 0
    for _ in ipairs(list) do total = total + 1 end
    return total
end

--- Counts the operator's cancelEvents entries for the report. COUNTS ONLY
--- -- the cancelling itself belongs to the server file that registers those
--- handlers, and this file must never be a second place that does it.
---
--- Tolerant of all three shapes an operator plausibly writes, because a
--- report that said "0 cancelEvents" at somebody who had configured five
--- would be worse than no line at all: a list of event names, a list of
--- tables carrying an `event` field, or a set keyed by event name.
--- @return integer
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

-- ======================================================================
-- THE REGISTRY
-- ======================================================================

--- What a catalogued resource is, and therefore which alert it is expected
--- to send. Only ever used as a label in the report -- nothing branches on
--- it -- so a resource filed under the wrong one costs a word, not a bug.
local KINDS = {
    police = 'police',
    ambulance = 'EMS',
    both = 'police+EMS',
}

--- Registration order, which is report order. An array as well as a map so
--- the report does not shuffle between restarts -- pairs() order is
--- unspecified, and a block an operator re-reads at every boot should look
--- the same every time.
local adapters = {}
local byResource = {}

--- Adds one adapter to the catalogue.
---
--- Re-registering a name REPLACES the earlier entry, keeping its place in
--- the order. That is what lets an operator paste a `mute` they have
--- confirmed against a script's own documentation underneath the catalogue
--- below, rather than editing a shipped line and losing it at the next
--- update.
---
--- A malformed adapter is refused with one console line and never thrown:
--- this runs at load time, in both VMs, and an error here would take the
--- rest of the file -- and the report that would have explained it -- down
--- with it.
--- @param adapter table -- { resource: string, kind: 'police'|'ambulance'|'both', mute: fun(src: number, active: boolean)? }
--- @return boolean registered
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

    local entry = { resource = adapter.resource, kind = adapter.kind, mute = adapter.mute }
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
-- The resource NAMES police dispatch and EMS are commonly run under. This
-- resource is Qbox -- it talks to qbx_core and nothing else -- but plenty of
-- Qbox servers run a dispatch script that predates Qbox, so the catalogue
-- carries those older names too. It is a list of things to LOOK FOR, not a
-- statement about which framework is supported. Every one of them is
-- DETECTION-ONLY: a name, and
-- what that resource is. Not one carries a mute call, because not one of
-- their export names can be verified from inside this repository, and a
-- guessed export name detects as working and then silently does nothing.
-- See this file's header before adding one.
--
-- A name that nobody runs simply never matches -- GetResourceState answers
-- 'missing' and the row is never printed -- so a catalogue that is generous
-- with spellings (qbx_policejob AND qbx_police) costs nothing, while a
-- missing spelling costs an operator a silent gap in the report.
--
-- A DISPATCH BOARD IS FILED AS 'both'. Almost all of them carry the person-
-- down call as well as shots-fired, so an operator whose EMS keeps getting
-- paged can see which resource is really sending it.
-- ======================================================================

local CATALOGUE = {
    -- ---- Dispatch boards -------------------------------------------
    { resource = 'ps-dispatch', kind = 'both' },            -- Project Sloth; the common one on Qbox
    { resource = 'cd_dispatch', kind = 'both' },            -- Codesign
    { resource = 'qs-dispatch', kind = 'both' },            -- Quasar
    { resource = 'core_dispatch', kind = 'both' },
    { resource = 'rcore_dispatch', kind = 'both' },
    { resource = 'codem-dispatch', kind = 'both' },         -- CodeM
    { resource = 'emergencydispatch', kind = 'both' },
    { resource = 'linden_outlawalert', kind = 'police' },   -- police alerts only, by design

    -- ---- Police jobs, which alert on their own ---------------------
    { resource = 'origen_police', kind = 'police' },        -- ships its own alerting
    { resource = 'qbx_policejob', kind = 'police' },
    { resource = 'qbx_police', kind = 'police' },           -- the shorter spelling some builds use
    { resource = 'qb-policejob', kind = 'police' },
    { resource = 'wasabi_police', kind = 'police' },
    { resource = 'sc-police', kind = 'police' },
    { resource = 'sc-dispatch', kind = 'both' },            -- dispatch for police AND EMS on this family of scripts

    -- ---- EMS -------------------------------------------------------
    { resource = 'qbx_ambulancejob', kind = 'ambulance' },
    { resource = 'qbx_medical', kind = 'ambulance' },       -- Qbox's death and injury system: the one that watches the dead state
    { resource = 'qb-ambulancejob', kind = 'ambulance' },
    { resource = 'wasabi_ambulance', kind = 'ambulance' },
    { resource = 'sc-ambulance', kind = 'ambulance' },
}

for _, entry in ipairs(CATALOGUE) do
    ArenaCompat.RegisterAdapter(entry)
end

-- HOW TO ADD A MUTE YOU HAVE ACTUALLY CONFIRMED. Copy this under the
-- catalogue, with the export name read out of that script's own
-- documentation -- never one that merely sounds right:
--
--     ArenaCompat.RegisterAdapter({
--         resource = 'my_dispatch',
--         kind = 'police',
--         mute = function(src, active)
--             exports.my_dispatch:TheirRealIgnoreExport(src, active)
--         end,
--     })
--
-- `src` is a server id and `active` is true on entry, false on exit. The
-- call is made on the server, wrapped in pcall, from the same entry and
-- exit events server/dispatch.lua already announces.

-- ======================================================================
-- DETECTION
-- ======================================================================

--- Every catalogued resource that is running right now, in catalogue order.
---
--- DELIBERATELY NOT CACHED. GetResourceState is a cheap lookup and the
--- catalogue is a couple of dozen names, so the whole walk is nothing --
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

--- @param resource any
--- @return boolean
function ArenaCompat.IsRunning(resource)
    local adapter = Arena.IsKey(resource) and byResource[resource]
    return adapter ~= nil and GetResourceState(resource) == 'started'
end

-- ======================================================================
-- MUTING
-- ======================================================================

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

--- How a detected resource is being handled right now, as a phrase for its
--- row -- or nil, meaning "nothing here reaches it", which is what makes
--- the row print the line to paste.
--- @param adapter table
--- @return string|nil status
local function statusOf(adapter)
    if adapter.mute then
        if enterEventName() then
            return 'muted automatically -- this resource carries a mute for it'
        end
        return 'has a mute, but custom.enterEvent is nil so nothing triggers it'
    end

    local exportName = disableExportFor(adapter.resource)
    if exportName then
        return ('muted automatically -- disableExports calls exports.%s:%s'):format(adapter.resource, exportName)
    end

    if inResyncList(adapter.resource) and enterEventName() then
        return ('assumed handled -- you named it in resyncResources, so it hears %s'):format(enterEventName())
    end

    return nil
end

--- One line about Config.Dispatch.isolation, and only when that block
--- exists: it is another file's setting, and a report announcing
--- "isolation is off" on a build that has no isolation would be inventing a
--- feature rather than describing one.
---
--- It is what decides how much a row marked NOT muted actually matters:
--- with isolation on, the only machine left that can see the fight is a
--- fighter's own.
--- @param unhandled integer -- how many rows need the line pasting
--- @return string|nil
local function isolationLine(unhandled)
    local isolation = dispatchConfig().isolation
    if type(isolation) ~= 'table' then return nil end

    if isolation.enabled ~= true then
        return 'Isolation is off (Config.Dispatch.isolation) -- every client on the server can see arena gunfire and arena bodies. It is the one layer that needs nothing from anybody.'
    end
    if unhandled > 0 then
        return 'Isolation is on: no OTHER player\'s client can see the fight. An arena player\'s own client still can -- that is what the line below is for.'
    end
    return 'Isolation is on: no OTHER player\'s client can see the fight.'
end

--- What the operator has already wired up, so the report describes their
--- setup rather than a template.
--- @return string
local function hookLine()
    local parts = {}
    local enter, exit = enterEventName(), exitEventName()

    if enter and exit then
        parts[#parts + 1] = 'entry/exit events'
    elseif enter or exit then
        parts[#parts + 1] = enter and 'entry event only' or 'exit event only'
    end

    local exportCount = countList(customConfig().disableExports)
    if exportCount > 0 then parts[#parts + 1] = ('%d disableExport(s)'):format(exportCount) end

    local cancelCount = cancelEventCount()
    if cancelCount > 0 then parts[#parts + 1] = ('%d cancelEvent(s) (best effort)'):format(cancelCount) end

    local resyncCount = countList(customConfig().resyncResources)
    if resyncCount > 0 then parts[#parts + 1] = ('%d resyncResource(s)'):format(resyncCount) end

    if #parts == 0 then
        return 'Hooks configured: none -- the state bag is written either way. /arenadispatch re-runs this report.'
    end
    return ('Hooks configured: %s. /arenadispatch re-runs this report.'):format(table.concat(parts, ', '))
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

    local isolation = isolationLine(unhandled)
    if isolation then lines[#lines + 1] = isolation end

    if unhandled > 0 then
        -- The exact line, and roughly where it goes. No resource can cancel
        -- another one's alert from outside it, so this is the arena
        -- declining from inside theirs -- and it is one line, at the top,
        -- in whichever realm that script sends from.
        lines[#lines + 1] = '  Paste at the top of whatever sends the alert, in that script:'
        lines[#lines + 1] = ('      if Player(src).state.%s then return end        -- server realm'):format(stateKey())
        lines[#lines + 1] = ('      if LocalPlayer.state.%s then return end        -- client realm'):format(stateKey())
    end

    lines[#lines + 1] = hookLine()

    -- THE OTHER HALF OF THE PROBLEM, and worth its own line because nothing
    -- else in this report is about it. Everything above is about stopping
    -- alerts going OUT. This is about a player coming back: the arena stands
    -- its own dead back up itself, but a medical or ambulance script keeps
    -- its own record of who is dead and nothing about resurrecting a ped
    -- reaches it. Unconfigured, that player leaves the arena on their feet
    -- and is still dead to that script -- which reads as the arena being
    -- broken, with nothing anywhere saying why. So it says why, here, at
    -- every start.
    local revive = (Config.Dispatch or {}).revive
    local named = type(revive) == 'table'
        and (#(revive.commands or {}) + #(revive.serverEvents or {})
             + #(revive.clientEvents or {}) + #(revive.exports or {}))
        or 0
    local reviveOn = type(revive) == 'table' and revive.enabled == true and named > 0

    if reviveOn then
        lines[#lines + 1] = ('revive: configured -- %d command(s), %d event(s) and %d export(s) run when a player leaves the arena.')
            :format(#(revive.commands or {}),
                #(revive.serverEvents or {}) + #(revive.clientEvents or {}),
                #(revive.exports or {}))
    else
        lines[#lines + 1] = 'revive: NOT configured. A player who dies in a match will be stood back up by the arena,'
        lines[#lines + 1] = '  but your medical/ambulance script keeps its own death state and nothing here has told it.'
        lines[#lines + 1] = '  They will walk out of the arena still dead as far as that script is concerned.'
        lines[#lines + 1] = '  Fix: name whatever revives a player on this server in Config.Dispatch.revive'
        lines[#lines + 1] = '       (serverEvents / clientEvents / exports) and set enabled = true.'
    end

    return lines
end

--- @param lines string[]
local function printReport(lines)
    -- '%s' rather than the line itself: a resource name carrying a percent
    -- sign would otherwise be read as a format spec.
    for _, line in ipairs(lines) do say('%s', line) end
end

-- ======================================================================
-- SERVER-ONLY WIRING
--
-- Everything below runs on the server and nowhere else. The report is for
-- the operator's console, the mutes act on a server id the server itself
-- decided, and the command names every emergency script this box runs --
-- which is not information for every player.
-- ======================================================================

if IS_SERVER then
    -- Adapter mutes ride the resource's own public entry/exit events rather
    -- than a private hook, so they fire from exactly the moment
    -- server/dispatch.lua flags a player -- and an operator who renames
    -- those events in config renames this too, with nothing to keep in
    -- sync. Registered once at load; the names cannot change without a
    -- restart, because config.lua cannot.
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

    -- The same report on demand, so it can be checked without a restart --
    -- after installing a dispatch script, or after pasting the line it
    -- asked for.
    --
    -- Gated on ArenaIsAdmin, which answers true for source 0: the server
    -- console cannot hold an ACE and must never be locked out of its own
    -- diagnostic. Fails closed if ArenaIsAdmin is somehow not there --
    -- nobody, never everybody.
    RegisterCommand('arenadispatch', function(src)
        if type(ArenaIsAdmin) ~= 'function' or not ArenaIsAdmin(src) then
            if src ~= 0 and type(ArenaNotifyKey) == 'function' then
                ArenaNotifyKey(src, 'error.no_permission', 'error')
            end
            return
        end

        local lines = ArenaCompat.Report()
        printReport(lines)

        -- A player who ran this has no console to read, so they get the
        -- block as one notification. It is not run through locale(): it
        -- names resources, config keys and a line of Lua, none of which is
        -- prose to translate -- the same reason no ArenaLog line is.
        if src ~= 0 and type(ArenaNotify) == 'function' then
            ArenaNotify(src, table.concat(lines, '\n'), 'info')
        end
    end, false)
end
