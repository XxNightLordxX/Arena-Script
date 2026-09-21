--[[
    crimson_arena/tests/compatreport_spec.lua

    THE REPORT AN OPERATOR READS WHEN THE AMBULANCE STILL TURNS UP.

    shared/compat/dispatch.lua prints a block at every start, and again on
    demand as /arenadispatch. It is the resource's own answer to the one
    question an operator actually asks -- "the police/EMS still come to my
    arena, why" -- and it is the only place that can answer it, because
    every cause is something the arena can see and the operator cannot:
    which emergency scripts this box runs, whether anything is really
    wired to them, whether the arena started early enough to win the race
    for a death, and whether the handoff that clears a medical script's
    own casualty list has been named.

    A REPORT THAT IS WRONG IS WORSE THAN NO REPORT, because it is the one
    thing the operator trusts when nothing else makes sense. A mutation
    sample found twenty survivors in this file and a cluster of them are
    in exactly these lines: the counting that decides "configured" from
    "not configured", the guard that decides whether the paste-this line
    appears at all, and the row that names each resource and what is being
    done about it.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- shared/compat/dispatch.lua on the server, with the console captured and
--- the set of running resources under the test's control.
--- @param opts table? -- { running, config, startedBefore }
--- @return table fixture
local function newReport(opts)
    opts = opts or {}
    local running = opts.running or {}
    local console = {}

    local env = Sandbox.newArenaEnv({
        IsDuplicityVersion = function() return true end,
        GetResourceState = function(name)
            return running[name] and 'started' or 'missing'
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function() end,
        CreateThread = function() end,
        RegisterCommand = function() end,
        Wait = function() end,
        print = function(line) console[#console + 1] = tostring(line) end,
        ArenaIsAdmin = function() return true end,
        ArenaNotify = function() end,
        ArenaNotifyKey = function() end,
    })

    if opts.config then opts.config(env.Config.Dispatch) end
    Sandbox.loadInto('../Crimson-Arena/shared/compat/dispatch.lua', env)

    local fixture = { env = env, compat = env.ArenaCompat, console = console }

    --- The report as one block of text, which is how it is read.
    ---
    --- `opts.integrations` is what the SERVER realm establishes and this
    --- shared file cannot see for itself -- see statusOf. Absent by default,
    --- which is every pre-existing test in this file.
    function fixture.text()
        return table.concat(fixture.compat.Report(opts.integrations), '\n')
    end

    return fixture
end

-- ========================================================================
-- WHAT IS RUNNING
-- ========================================================================

t.test('a box running no emergency script at all says so, and says what to do', function()
    -- Not silence. An operator whose police still turn up needs to know
    -- the arena does not recognise their script by name, because that is
    -- the one cause they can fix in a minute and would never guess.
    local f = newReport({ running = {} })
    local said = f.text()

    t.contains(said, 'no police or EMS resource recognised')
    t.contains(said, 'Config.Dispatch.custom', 'the report does not name where to wire one up')
end)

t.test('and a box running one names it, and what is being done about it', function()
    local f = newReport({ running = { ['sc-dispatch'] = true } })
    local said = f.text()

    t.contains(said, 'sc-dispatch', 'the report does not name the script this box runs')
    t.contains(said, '1 police/EMS resource', 'the report does not count what it found')
end)

t.test('and counts them, rather than reporting the first', function()
    local f = newReport({ running = { ['sc-dispatch'] = true, ['qbx_ambulancejob'] = true } })
    local said = f.text()

    t.contains(said, '2 police/EMS resource', 'the report miscounts what is running')
    t.contains(said, 'sc-dispatch')
    t.contains(said, 'qbx_ambulancejob', 'the second script is missing from the report')
end)

t.test('a resource with nothing reaching it is called out as NOT muted', function()
    -- The whole point of the row. "Running" is not "handled", and an
    -- operator reading a list of names with no verdict against them
    -- learns nothing.
    local f = newReport({ running = { ['sc-dispatch'] = true } })

    t.contains(f.text(), 'NOT muted', 'a script nothing reaches was not called out')
end)

t.test('and one that mutes ITSELF for us is not called out either', function()
    -- REPORTED OFF A LIVE SERVER, and the report contradicted itself inside
    -- twenty lines. sc-dispatch ships its own arena integration -- a switch
    -- in ITS config that makes it ask this resource before paging anybody --
    -- and server/dispatch.lua reads that switch and says so in prose, at the
    -- foot of this very report: "no arena shot, death or help-call is paged".
    --
    -- The TABLE at the top said, of the same resource, in the same breath:
    --     sc-dispatch          police+EMS  NOT muted -- needs the line below
    --
    -- statusOf knew two ways an alert can be stopped -- a mute this resource
    -- carries, and a disableExports call -- and had never heard of the third,
    -- the other script asking us. So the operator was told to go and paste a
    -- guard into a script that was already guarded.
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        integrations = {
            ['sc-dispatch'] = { muted = true, note = 'muted by its own integration -- Integrations.CrimsonArena = true' },
        },
    })
    local said = f.text()

    t.contains(said, 'muted by its own integration',
        'a resource that mutes itself for us was not credited with it')
    t.notContains(said, 'NOT muted',
        'a resource that mutes itself for us was still called out as unmuted')
end)

t.test('AND THAT ROW NO LONGER DRAGS THE REST OF THE REPORT DOWN WITH IT', function()
    -- THE EXPENSIVE HALF OF THE SAME BUG. A row with no status raises
    -- `unhandled`, and `unhandled` is what turns OFF the "something is wired"
    -- verdict. So one wrong row did not just print one wrong line: it also
    -- printed the whole paste-this-into-your-dispatch block, and put "nothing
    -- here is confirmed wired" on the isolation line. Three pieces of wrong
    -- advice from one wrong answer.
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        integrations = {
            ['sc-dispatch'] = { muted = true, note = 'muted by its own integration' },
        },
    })
    local said = f.text()

    t.notContains(said, 'Paste at the top of whatever sends the alert',
        'an operator whose dispatch already asks us was still told to go and paste a guard into it')
    t.notContains(said, 'nothing here is confirmed wired',
        'the isolation line still doubted an integration this report had confirmed')
end)

t.test('and an integration that is OFF, or that could not be read, is NOT credited', function()
    -- THE SAFE DIRECTION, pinned so the fix above cannot be widened into
    -- "assume it is fine". Only a positive, checked mute is ever passed in.
    -- A switch read as false, or a config that could not be read at all,
    -- reaches this file as NO ENTRY -- and no entry must mean no credit,
    -- because an operator wrongly told they are covered stops looking.
    local off = newReport({
        running = { ['sc-dispatch'] = true },
        integrations = { ['sc-dispatch'] = { muted = false } },
    })
    t.contains(off.text(), 'NOT muted',
        'a resource whose own integration is switched OFF was reported as handled')

    local unknown = newReport({
        running = { ['sc-dispatch'] = true },
        integrations = {},
    })
    t.contains(unknown.text(), 'NOT muted',
        'a resource nothing could be established about was reported as handled')
end)

t.test('and the isolation line does not say NOTHING is wired while a row says otherwise', function()
    -- THE SECOND HALF OF THE SAME SELF-CONTRADICTION, which survived the
    -- first fix. `wired` is an ALL, not an ANY -- somethingWired returns
    -- false the moment ONE detected resource is unaccounted for -- so on the
    -- operator's real box the report printed, in this order:
    --
    --   sc-dispatch  police+EMS  muted by its own integration -- ...
    --   Isolation is on ... and nothing here is confirmed wired
    --   Hooks configured: ... retract via exports.sc-dispatch:ClearNotification
    --   sc-dispatch is running with Integrations.CrimsonArena = true ...
    --
    -- An operator cannot act on that. The safe reading sends them back to
    -- re-check an integration that is already working and already credited
    -- four lines away.
    local f = newReport({
        running = { ['sc-dispatch'] = true, ['sc-ambulance'] = true },
        integrations = {
            ['sc-dispatch'] = { muted = true, note = 'muted by its own integration' },
        },
    })
    local said = f.text()

    t.contains(said, 'muted by its own integration', 'the confirmed row is missing, so this proves nothing')
    t.notContains(said, 'nothing here is confirmed wired',
        'the isolation line denied a mute the table confirms three lines above it')
    t.contains(said, 'not everything here is confirmed wired',
        'the line did not say which of the two it actually means')
    -- AND THE PASTE BLOCK STAYS, because sc-ambulance really does need it.
    t.contains(said, 'Paste at the top of whatever sends the alert',
        'an unguarded ambulance script stopped being given the line it needs')
end)

t.test('and it still says NOTHING where nothing really is confirmed', function()
    -- THE CONTROL, and the direction that must never drift. Softening
    -- "nothing" to "not everything" on a box with no confirmed row would be
    -- weaker than the truth -- an operator told part of it works stops
    -- looking at the part that does not.
    local f = newReport({ running = { ['sc-dispatch'] = true, ['sc-ambulance'] = true } })
    local said = f.text()

    t.contains(said, 'nothing here is confirmed wired',
        'a box with no confirmed row was told part of it was wired')
    t.notContains(said, 'not everything here is confirmed wired',
        'a box with no confirmed row was told part of it was wired')
end)

t.test('and a confirmed mute for ONE resource says nothing about the others', function()
    -- sc-dispatch's switch is sc-dispatch's. sc-police and sc-ambulance raise
    -- their own alerts through their own handlers, and this report's own
    -- ambulance paragraph exists because sc-dispatch's integration does NOT
    -- cover them. Crediting a neighbour because their neighbour is wired is
    -- exactly the false all-clear the test above guards against.
    local f = newReport({
        running = { ['sc-dispatch'] = true, ['sc-ambulance'] = true },
        integrations = {
            ['sc-dispatch'] = { muted = true, note = 'muted by its own integration' },
        },
    })
    local said = f.text()

    t.contains(said, 'muted by its own integration', 'the wired resource lost its credit')
    t.contains(said, 'NOT muted',
        'an unguarded ambulance script was waved through because a DIFFERENT resource was wired')
end)

t.test('and one with an ignore export named is not', function()
    -- The control: without it, "NOT muted" passes against a report that
    -- says it about everything.
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        config = function(dispatch)
            dispatch.custom.disableExports = {
                { resource = 'sc-dispatch', export = 'setIgnore' },
            }
        end,
    })
    local said = f.text()

    t.contains(said, 'muted automatically', 'a wired-up script was not reported as handled')
    t.notContains(said, 'NOT muted', 'a wired-up script was still called out as unmuted')
end)

-- ========================================================================
-- THE LINE TO PASTE
-- ========================================================================

t.test('a box where nothing is wired is given the exact line, and where to put it', function()
    -- No resource can cancel another one's alert from outside it, so this
    -- is the arena declining from inside theirs. It is one line, and the
    -- report has to carry it exactly or it is a puzzle rather than a fix.
    local f = newReport({ running = { ['sc-dispatch'] = true } })
    local said = f.text()

    t.contains(said, 'Paste at the top', 'the report does not offer the line')
    t.contains(said, 'Player(src).state.', 'the server-realm line is missing')
    t.contains(said, 'LocalPlayer.state.', 'the client-realm line is missing')
end)

t.test('and the state key in that line is the one really being written', function()
    -- A paste-this line naming a key the resource does not set is worse
    -- than no line: it looks like the fix and silences nothing.
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        config = function(dispatch) dispatch.custom.stateBagKey = 'myArenaFlag' end,
    })

    t.contains(f.text(), 'myArenaFlag', 'the line to paste names a state key nobody writes')
end)

t.test('and a box where something IS wired is not told to paste anything', function()
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        config = function(dispatch)
            dispatch.custom.disableExports = {
                { resource = 'sc-dispatch', export = 'setIgnore' },
            }
        end,
    })

    t.notContains(f.text(), 'Paste at the top',
        'a server that is already wired up was told to paste a line it does not need')
end)

-- ========================================================================
-- START ORDER, WHICH IS THE ONE THING THE ARENA CANNOT FIX
-- ========================================================================

t.test('a script already running when this one loads is reported as EARLIER', function()
    -- START ORDER IS THE ONE THING THE ARENA CANNOT FIX, and it is decided
    -- before this file has run a line: anything already `started` when the
    -- catalogue is walked got there first, and will answer a death first.
    -- The report has to say so, because the operator's only lever is a
    -- line in server.cfg.
    local f = newReport({ running = { ['sc-dispatch'] = true } })
    local said = f.text()

    t.contains(said, 'started BEFORE this resource', 'the report says nothing about start order')
    t.contains(said, 'sc-dispatch', 'the start-order line does not name which script beat it')
end)

t.test('and the fix names THIS resource, so the line can be pasted as written', function()
    -- The folder name is whatever the operator called it, and the line
    -- they need is `ensure <that>`. A hardcoded name would send them to
    -- edit a line that is not in their server.cfg.
    local f = newReport({ running = { ['sc-dispatch'] = true } })
    local said = f.text()

    t.contains(said, 'ensure crimson_arena', 'the fix does not name this resource')
    t.contains(said, 'ABOVE those lines', 'the fix does not say where to put it')
end)

t.test('and a box running nothing has no start-order problem to report', function()
    -- The control: with nothing detected there is nobody to have gone
    -- first, and reporting a race against an empty field would send an
    -- operator editing server.cfg for no reason.
    local f = newReport({ running = {} })

    t.contains(f.text(), 'this resource started first',
        'a box running no emergency script was told it lost a race to one')
end)

-- ========================================================================
-- THE REVIVE HANDOFF
-- ========================================================================

t.test('A DETECTED MEDICAL SCRIPT IS TOLD DIRECTLY, with nothing configured', function()
    -- THE HALF OPERATORS KEPT MISTAKING FOR THE OTHER ONE. The catalogue
    -- carries the revive event three of these scripts really listen for --
    -- read out of their own source -- so a box running one of them has a
    -- working handoff with no configuration at all. The report has to say
    -- that, or an operator reads "NOT configured" and goes looking for a
    -- problem they do not have.
    local f = newReport({ running = { ['qbx_ambulancejob'] = true } })
    local said = f.text()

    t.contains(said, 'told to revive a player directly')
    t.contains(said, 'hospital:client:Revive',
        'the report does not name the event it is actually firing')
    t.notContains(said, 'NOTHING IS TELLING YOUR MEDICAL SCRIPT')
end)

t.test('and a box with nothing detected is warned, plainly', function()
    -- The case that is genuinely broken: no script this catalogue knows, so
    -- nothing is being told anything.
    --
    -- AND IT MUST NOT OVERSTATE IT. The ped really is stood up -- in the
    -- frame of the death and again on respawn -- so a warning that reads as
    -- "players stay on the floor" sends an operator hunting a bug that is
    -- not there. What is missing is the handoff, and only the handoff.
    local f = newReport({ running = {} })
    local said = f.text()

    t.contains(said, 'NOTHING IS TELLING YOUR MEDICAL SCRIPT')
    t.contains(said, 'still dead as far as that script is concerned',
        'the report does not say what a missing handoff actually costs')
    t.contains(said, 'shared/compat/dispatch.lua',
        'the report does not name where to add the script')
    t.contains(said, 'stands it up in the frame they died',
        'the report does not say the ped itself is fine, so it reads as a bug in the arena')
end)

t.test('and NOTHING an operator writes in config can silence that warning', function()
    -- THE CONTRACT. Whether a dead player comes back is a fact about which
    -- resources are running. Config used to be able to claim a handoff --
    -- an `enabled` switch and three lists of hand-written names -- and the
    -- report believed it, so a box with the switch on and a typo in the
    -- event name read as covered. Only detection counts now.
    local f = newReport({
        running = {},
        config = function(dispatch)
            dispatch.revive.enabled = true
            dispatch.revive.serverEvents = { 'hospital:server:revive' }
            dispatch.revive.clientEvents = { 'hospital:client:Revive' }
            dispatch.revive.exports = { { resource = 'ambulance', export = 'revive' } }
        end,
    })

    t.contains(f.text(), 'NOTHING IS TELLING YOUR MEDICAL SCRIPT',
        'config keys are being counted as a handoff again')
end)

-- ========================================================================
-- THE REPORT IS ALWAYS PRINTABLE
-- ========================================================================

t.test('every line is a string, whatever the config', function()
    -- printReport sends each through a format call. A nil or a number in
    -- that list is a raise inside the diagnostic an operator ran BECAUSE
    -- something was already wrong.
    local f = newReport({
        running = { ['sc-dispatch'] = true, ['qbx_ambulancejob'] = true },
        config = function(dispatch)
            dispatch.custom.stateBagKey = nil
            dispatch.custom.disableExports = nil
            dispatch.revive = nil
        end,
    })

    local lines = f.compat.Report()
    t.isTrue(#lines > 0, 'the report came back empty')
    for index, line in ipairs(lines) do
        t.equals(type(line), 'string', ('line %d of the report is not a string'):format(index))
    end
end)

t.test('and a state key an operator emptied falls back to the shipped one', function()
    -- The paste-this line has to name a real key. An empty setting means
    -- "I did not choose", not "write nothing".
    local f = newReport({
        running = { ['sc-dispatch'] = true },
        config = function(dispatch) dispatch.custom.stateBagKey = '' end,
    })

    t.contains(f.text(), 'crimsonArena',
        'an emptied state key left the paste-this line naming nothing')
end)

os.exit(t.summary())
