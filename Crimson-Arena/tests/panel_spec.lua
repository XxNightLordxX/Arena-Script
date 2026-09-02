--[[
    crimson_arena/tests/panel_spec.lua

    The real client/ui.lua, client/main.lua and client/match.lua, loaded
    into a sandbox.

    The first two are deliberately thin -- they forward, they do not decide
    -- so what is worth testing about them is the wiring itself, and wiring
    is the part that fails silently. An event the server fires that no handler
    answers looks exactly like a feature nobody built: the results board the
    README promises is computed, sent, and dropped on the floor, with nothing
    in either console. A state request made on every client's behalf at start
    looks exactly like nothing at all, right up until the server is
    serialising the whole match list to every player on it four times a
    second because it read that request as "my panel is open".

    client/match.lua is here for the opposite reason: it DOES decide, once
    per frame, and the decision it gets wrong is a timing one -- which phase
    of a round a loop is allowed to run in. Its section is at the bottom,
    with its own fixture and its own note.

    WHAT IS STUBBED, and no more than that: the NUI bridge (SendNUIMessage,
    SetNuiFocus, RegisterNUICallback), ox_lib's callback and notify, and --
    for the lobby file -- the fixtures it builds at start: the ped, the blip
    and the command. Config is the real config.lua, because the interaction
    mode and the command name are read out of it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- Reads one file out of html/ as text.
---
--- There is no DOM in this suite and adding one would mean a browser
--- dependency for the whole build. Where a panel behaviour spans files that
--- cannot see each other -- config names a setting, the stylesheet draws it,
--- the script decides which -- text is enough to prove the three ends still
--- agree, which is the failure that actually happens. It does not prove a
--- browser lays the result out correctly; DEPLOYMENT.md's smoke checklist
--- is where that is answered.
--- @param name string -- e.g. 'app.js'
--- @return string body
local function readPanelFile(name)
    local handle = assert(io.open('../html/' .. name, 'r'), 'html/' .. name .. ' is missing')
    local body = handle:read('a')
    handle:close()
    return body
end

-- ========================================================================
-- client/ui.lua -- the NUI bridge
-- ========================================================================

--- One fresh, fully isolated load of client/ui.lua.
--- @return table fixture
local function newUiFixture()
    local sent = {}             -- every SendNUIMessage, in order
    local focus = {}            -- every SetNuiFocus, in order
    local handlers = {}         -- RegisterNetEvent / AddEventHandler
    local notifications = {}    -- everything that fell through to ox_lib

    local fixture = { sent = sent, focus = focus, notifications = notifications }
    -- What the server answers the panel's opening callback with. A spec
    -- wanting the failed-fetch path sets this to nil.
    fixture.snapshot = { config = {}, player = {} }

    local env = Sandbox.newEnv({
        SendNUIMessage = function(message) sent[#sent + 1] = message end,
        SetNuiFocus = function(hasFocus) focus[#focus + 1] = hasFocus end,
        RegisterNUICallback = function() end,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = {
            callback = {
                --- Stands in for the yield the real callback makes. Anything
                --- the spec puts in `duringAwait` happens at exactly the
                --- point the panel is waiting on the server, which is the
                --- window a closePanel has to land in to be interesting.
                await = function()
                    if fixture.duringAwait then fixture.duringAwait() end
                    return fixture.snapshot
                end,
            },
            notify = function(data) notifications[#notifications + 1] = data end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../client/ui.lua', env)

    fixture.env = env
    fixture.UI = env.ArenaUI

    --- Delivers a server event the way FiveM would. Returns false when this
    --- resource registered no handler for it at all -- which is the whole
    --- finding for two of the three events below.
    function fixture.fire(name, ...)
        local handler = handlers[name]
        if not handler then return false end
        handler(...)
        return true
    end

    --- The last `{ action, data }` envelope with this action, or nil.
    function fixture.last(action)
        for index = #sent, 1, -1 do
            if sent[index].action == action then return sent[index] end
        end
        return nil
    end

    function fixture.lastFocus()
        return focus[#focus]
    end

    return fixture
end

t.test('the results block the server builds reaches the panel', function()
    local f = newUiFixture()

    local delivered = f.fire('crimson_arena:client:results', {
        matchId = 'm1',
        reason = 'match.ended_last_standing',
        won = true,
        placement = 1,
        kills = 3,
        deaths = 1,
        earnings = 4000,
        scoreboard = { { id = 12, name = 'Ada', kills = 3, deaths = 1, alive = true } },
    })

    t.isTrue(delivered, 'no handler is registered for crimson_arena:client:results')

    local message = f.last('results')
    t.isNotNil(message, 'the results never reached the panel')
    t.equals(message.data.results.matchId, 'm1')
    t.equals(message.data.results.earnings, 4000)
    t.equals(message.data.results.scoreboard[1].name, 'Ada')
end)

t.test('a results payload wrapped in an envelope is unwrapped rather than nested twice', function()
    -- The block is built in one realm and drawn in another with no shared
    -- code between the two ends, so both shapes of the same payload are read.
    local f = newUiFixture()
    f.fire('crimson_arena:client:results', { results = { matchId = 'm2', won = false } })

    local message = f.last('results')
    t.isNotNil(message)
    t.equals(message.data.results.matchId, 'm2')
end)

t.test('rubbish where a results block should be draws nothing', function()
    local f = newUiFixture()
    f.fire('crimson_arena:client:results', 'not a table')
    f.UI.Results(nil)
    f.UI.Results('not a table')

    t.isNil(f.last('results'))
end)

t.test('closePanel gives the player their controls back', function()
    local f = newUiFixture()
    f.UI.Open()
    t.equals(f.lastFocus(), true, 'the panel never took focus to begin with')

    t.isTrue(f.fire('crimson_arena:client:closePanel'))
    t.equals(f.lastFocus(), false)
    t.isNotNil(f.last('close'))
end)

t.test('a close landing while the panel is still fetching its snapshot wins', function()
    -- The server closes the panel as it puts a player in the arena, and the
    -- panel opens on a callback that yields. Land one inside the other and
    -- the open must lose: otherwise the player stands in a live round with
    -- NUI focus swallowing every movement, aim and shot -- the exact failure
    -- closing the panel on entry exists to prevent.
    local f = newUiFixture()
    f.duringAwait = function() f.fire('crimson_arena:client:closePanel') end

    f.UI.Open()

    t.equals(f.lastFocus(), false, 'the player was left holding NUI focus')
    t.isNil(f.last('open'), 'the panel was drawn after the server had closed it')
    t.isFalse(f.UI.IsOpen())
end)

t.test('the panel can still be opened after a close that overtook one', function()
    -- The guard must invalidate one open, not every open after it.
    local f = newUiFixture()
    f.duringAwait = function() f.fire('crimson_arena:client:closePanel') end
    f.UI.Open()

    f.duringAwait = nil
    f.UI.Open()

    t.isNotNil(f.last('open'))
    t.equals(f.lastFocus(), true)
    t.isTrue(f.UI.IsOpen())
end)

t.test('a server notification lands on the panel rail with the panel open', function()
    -- Pins the payload the server sends against the fields read here: the
    -- two are written in different realms and only meet at run time.
    local f = newUiFixture()
    f.UI.Open()

    t.isTrue(f.fire('crimson_arena:client:notify', { description = 'Weapon refused.', type = 'warning' }))

    local message = f.last('notify')
    t.isNotNil(message, 'the notification never reached the panel')
    t.equals(message.data.message, 'Weapon refused.')
    t.equals(message.data.type, 'warning')
    t.equals(#f.notifications, 0, 'it went to ox_lib as well as the panel')
end)

t.test('the same notification falls through to ox_lib with the panel closed', function()
    local f = newUiFixture()
    f.fire('crimson_arena:client:notify', { description = 'Weapon refused.', type = 'info' })

    t.isNil(f.last('notify'))
    t.equals(#f.notifications, 1)
    t.equals(f.notifications[1].description, 'Weapon refused.')
    t.equals(f.notifications[1].title, f.env.Config.NotifyTitle)
    -- ox_lib spells the neutral level 'inform'; the rest of the resource
    -- says 'info', and this is the one place that is translated.
    t.equals(f.notifications[1].type, 'inform')
end)

t.test('restarting the resource with the panel open hands the mouse back', function()
    -- The page dies with the resource; the focus it took does not. Without
    -- this handler a `restart crimson_arena` with the menu open leaves the
    -- player with a captured mouse, no page to release it, and no way out
    -- short of relogging.
    local f = newUiFixture()
    f.UI.Open()
    t.equals(f.lastFocus(), true, 'the panel never took focus to begin with')

    t.isTrue(f.fire('onResourceStop', 'crimson_arena'), 'nothing releases focus on a restart')
    t.equals(f.lastFocus(), false, 'the player was left holding NUI focus after a restart')
end)

t.test('but SOME OTHER resource stopping does not touch this player\'s mouse', function()
    -- onResourceStop fires for EVERY resource on the server, not just this
    -- one. Reading the argument is the whole handler: without that check,
    -- any unrelated script restarting mid-menu rips the panel's focus away
    -- and the player is clicking on a page that no longer answers.
    local f = newUiFixture()
    f.UI.Open()
    local before = #f.focus

    t.isTrue(f.fire('onResourceStop', 'some_other_script'))

    t.equals(#f.focus, before, 'an unrelated resource stopping moved this player\'s focus')
    t.equals(f.lastFocus(), true, 'the open panel lost its focus to another resource stopping')
end)

-- ========================================================================
-- client/main.lua -- the lobby fixtures and the startup thread
-- ========================================================================

--- One fresh, fully isolated load of client/main.lua, with its start-up
--- thread run to completion.
---
--- `opts.targetState` is what GetResourceState('ox_target') answers -- the
--- one thing the lobby's shape depends on that is not in config.
--- @param opts table? -- { targetState = string }
--- @return table fixture
local function newLobbyFixture(opts)
    opts = opts or {}
    local serverEvents = {}
    local built = {}
    local console = {}
    local depth = 0

    local env = Sandbox.newEnv({
        -- ONLY THE OUTERMOST THREAD IS RUN. The start-up thread reaches every
        -- line below without waiting on anything, so running it inline is
        -- free -- but the marker it can now start is a `while true` render
        -- loop, and running THAT inline never returns. Recording the nested
        -- thread instead is the difference between asserting the marker went
        -- up and hanging the suite on it.
        CreateThread = function(fn)
            depth = depth + 1
            if depth == 1 then
                fn()
            else
                built.markerThread = true
            end
            depth = depth - 1
        end,
        Wait = function() end,
        -- Captured, not silenced: half of what this file asserts is that a
        -- failure says so out loud.
        print = function(line) console[#console + 1] = tostring(line) end,
        -- Started unless a test says otherwise: that is the shape every
        -- assertion written before the fallback existed was written against.
        GetResourceState = function(resource)
            if resource == 'ox_target' then return opts.targetState or 'started' end
            return 'started'
        end,
        -- No GetEntityCoords/PlayerPedId stub: the marker's render loop is
        -- recorded rather than run, so nothing inside it is ever reached.
        TriggerServerEvent = function(name, payload)
            serverEvents[#serverEvents + 1] = { name = name, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function(name) built.command = name end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        ArenaUI = { Open = function() end },

        joaat = function() return 1 end,
        IsModelInCdimage = function() return true end,
        IsModelValid = function() return true end,
        RequestModel = function() end,
        HasModelLoaded = function() return true end,
        GetGameTimer = function() return 0 end,
        -- WHERE, not just whether. The operator's whole interface to this
        -- resource is config.lua, and "the ped did not move when I changed
        -- the coordinates" is unanswerable from a fixture that only records
        -- that a ped was made.
        CreatePed = function(_kind, _model, x, y, z, heading)
            -- A raise here is not hypothetical: CreatePed, the scenario, and
            -- above all ox_target's addLocalEntity are all things another
            -- resource or the engine can refuse.
            if opts.pedRaises then error('the game would not make that ped') end
            built.ped = true
            built.pedAt = { x = x, y = y, z = z, w = heading }
            return 7
        end,
        SetModelAsNoLongerNeeded = function() end,
        SetEntityAsMissionEntity = function() end,
        FreezeEntityPosition = function() end,
        SetEntityInvincible = function() end,
        SetBlockingOfNonTemporaryEvents = function() end,
        TaskStartScenarioInPlace = function() end,
        exports = { ox_target = { addLocalEntity = function() built.target = true end } },

        AddBlipForCoord = function(x, y, z)
            built.blip = true
            built.blipAt = { x = x, y = y, z = z }
            return 3
        end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipScale = function() end,
        SetBlipAsShortRange = function() end,
        SetBlipDisplay = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../client/main.lua', env)

    return {
        env = env,
        serverEvents = serverEvents,
        built = built,
        --- Everything the resource printed while starting. Half of what this
        --- file asserts is that a failure is LOUD, and the console is where
        --- that lands.
        log = function() return table.concat(console, '\n') end,
    }
end

t.test('the lobby NPC goes exactly where config.lua says', function()
    -- THE OPERATOR'S WHOLE INTERFACE IS config.lua, and a coordinate that
    -- does not take it is the most confusing possible failure: the resource
    -- works, the panel works, and the arena is somewhere the operator did not
    -- put it. Asserted against Config rather than against numbers written
    -- here, so moving the arena can never turn this red.
    local f = newLobbyFixture()
    local wanted = f.env.Config.Lobby.ped.coords

    t.isNotNil(f.built.pedAt, 'no NPC was spawned at all')
    t.equals(f.built.pedAt.x, wanted.x)
    t.equals(f.built.pedAt.y, wanted.y)
    -- One unit down: config documents `z` as the GROUND z and CreatePed puts
    -- the ped's root there, which leaves it hovering.
    t.equals(f.built.pedAt.z, wanted.z - 1.0)
    t.equals(f.built.pedAt.w, wanted.w)
end)

t.test('and the map blip goes with it', function()
    -- A blip left behind at the old place is a player walking to an arena
    -- that is not there any more.
    local f = newLobbyFixture()
    local wanted = f.env.Config.Lobby.ped.coords

    t.isNotNil(f.built.blipAt, 'no blip was created')
    t.equals(f.built.blipAt.x, wanted.x)
    t.equals(f.built.blipAt.y, wanted.y)
end)

t.test('and with ox_target absent the blip still points at the NPC spot', function()
    -- The blip follows the SETTING, not what happened to succeed. A 'ped'
    -- lobby whose NPC could not go up still sends the operator to the place
    -- they have to stand to understand why it did not.
    local f = newLobbyFixture({ targetState = 'missing' })
    local wanted = f.env.Config.Lobby.ped.coords

    t.isNil(f.built.markerThread, 'a marker went up in a lobby nobody asked for one in')
    t.isNotNil(f.built.blipAt)
    t.equals(f.built.blipAt.x, wanted.x)
    t.equals(f.built.blipAt.y, wanted.y)
end)

t.test('DEFECT: an NPC that RAISES does not take the blip and the command with it', function()
    -- THE SYMPTOM, and it was unexplainable from outside: no NPC and no blip,
    -- on a resource reporting itself started. The blip is created two lines
    -- after the spawn on the same thread, so anything that raises in the
    -- spawn kills the rest of the start-up -- the blip and the /arena command
    -- with it, leaving the arena unreachable by any route and nothing in the
    -- console pointing at the cause.
    --
    -- This file already said exactly that, about ONE call inside the spawn,
    -- and guarded only that one.
    local f = newLobbyFixture({ pedRaises = true })

    t.isTrue(f.built.blip, 'A RAISE IN THE NPC TOOK THE MAP BLIP DOWN WITH IT')
    t.equals(f.built.command, f.env.Config.UI.command,
        'and the command, so there is not even a way to open the panel by typing')
end)

t.test('and the failure is named rather than swallowed', function()
    local f = newLobbyFixture({ pedRaises = true })
    t.isTrue(f.log():find('could not be spawned', 1, true) ~= nil,
        'the NPC vanished and the console says nothing about why: ' .. f.log())
end)

t.test('and the WHERE line still prints, which is what an operator is told to look for', function()
    -- The line an operator is pointed at to tell three identical-looking
    -- failures apart. It is printed at the END of the start-up thread, so it
    -- is exactly the thing a raise earlier in that thread used to eat -- and
    -- a diagnostic that disappears in the case it was written for is worse
    -- than none, because its absence gets read as "the resource is dead".
    local raised = newLobbyFixture({ pedRaises = true })
    t.isTrue(raised.log():find('lobby: ', 1, true) ~= nil,
        'the one line an operator is told to look for is missing exactly when they need it: '
        .. raised.log())
    t.isTrue(raised.log():find('NOTHING', 1, true) ~= nil,
        'the line does not say the lobby has nothing standing in it, which is what happened')

    -- And on the ordinary path it names the NPC instead.
    local fine = newLobbyFixture()
    t.isTrue(fine.log():find('lobby: NPC at', 1, true) ~= nil,
        'a healthy start says nothing about where it put itself: ' .. fine.log())
end)

t.test('starting the resource asks the server for nothing', function()
    -- The server reads a state request as "this player has a panel open" and
    -- never unreads it while they are connected. Asked here, on every
    -- client, it made every connected player a recipient of every broadcast
    -- for the rest of the session -- for a panel none of them had touched.
    -- ArenaUI.Open fetches its own snapshot before it draws anything, so
    -- nothing is lost by not asking.
    local f = newLobbyFixture()

    -- Proof the thread ran the whole way rather than dying before the line
    -- this test is about: both fixtures and the command exist.
    t.isTrue(f.built.ped)
    t.isTrue(f.built.blip)
    t.equals(f.built.command, f.env.Config.UI.command)

    t.equals(#f.serverEvents, 0, 'the start-up thread sent ' ..
        (f.serverEvents[1] and f.serverEvents[1].name or ''))
end)

t.test('the cached snapshot starts empty and is filled by the server push', function()
    local f = newLobbyFixture()
    t.isNil(f.env.ArenaState.Get())
    t.isFalse(f.env.ArenaState.IsInMatch())

    f.env.ArenaState.Set({ player = { matchId = 'm1' } })
    t.equals(f.env.ArenaState.MatchId(), 'm1')
end)

-- ------------------------------------------------------------------------
-- THE LOBBY WHEN ox_target IS NOT THERE
--
-- ox_target is not in fxmanifest.lua's dependencies block, deliberately: it
-- ships with Qbox but naming it would make it mandatory on every install,
-- including one that only ever wanted the marker. That decision is only safe
-- if its absence costs the NPC and nothing else -- and the failure mode it
-- replaced was not a missing NPC, it was `exports.ox_target` RAISING inside
-- the start-up thread and taking the marker, the blip and the fallback
-- command down with it. A lobby with no way into it at all, and no line in
-- the console naming the cause.
--
-- So these two tests are about what SURVIVES, not about the NPC.
-- ------------------------------------------------------------------------

t.test('with ox_target running the NPC goes up and no marker is drawn over it', function()
    local f = newLobbyFixture({ targetState = 'started' })

    t.isTrue(f.built.ped, 'no NPC was spawned')
    t.isTrue(f.built.target, 'the NPC was spawned with no way to interact with it')
    t.isNil(f.built.markerThread,
        "a marker was drawn as well as the NPC, but Config.Lobby.interaction ships as 'ped'")
end)

t.test('with ox_target stopped no NPC goes up, and the rest of the lobby survives', function()
    local f = newLobbyFixture({ targetState = 'missing' })

    -- No silent NPC. An NPC standing there with nothing able to target it
    -- looks like a working lobby and is not one.
    t.isNil(f.built.ped, 'an NPC was spawned that nothing can interact with')
    t.isNil(f.built.target)

    -- And no marker in its place: the operator asked for an NPC, and a
    -- resource that plays a setting other than the one in the file is a
    -- resource whose config cannot be trusted.
    t.isNil(f.built.markerThread, 'a marker went up in a lobby nobody asked for one in')

    -- These are the collateral the old raise took with it. Each is reached
    -- AFTER the ox_target call in the start-up thread, which is precisely
    -- why they are asserted here.
    t.isTrue(f.built.blip, 'the map blip is gone, so players cannot even find the lobby')
    t.equals(f.built.command, f.env.Config.UI.command,
        'the panel command was never registered')
    t.equals(#f.serverEvents, 0)
end)

-- ------------------------------------------------------------------------
-- THE LOGO, AND THE TWO SHAPES ONE CAN BE
--
-- Config.UI.logoStyle picks between a small badge beside the title and a
-- banner that replaces the title. The reason it exists: a finished server
-- logo usually already contains the server's name, so drawing the title
-- beside it prints that name twice -- once as text, once as pixels too
-- small to read.
--
-- The setting spans three files that cannot see each other -- config.lua
-- names it, style.css draws it, app.js decides which -- which is the exact
-- shape that has silently come apart four times in this build. Asserted
-- here as text because there is no DOM in this suite; the point is that all
-- three ends still agree, not that a browser lays it out correctly.
-- ------------------------------------------------------------------------

t.test('the panel reads logoStyle and hands the header over in banner mode', function()
    local app = readPanelFile('app.js')

    t.contains(app, "ui.logoStyle === 'banner'",
        'app.js no longer reads the setting, so choosing banner does nothing')
    t.contains(app, "classList.toggle('logo-banner'",
        'app.js reads the setting but never puts the class on the header')
end)

t.test('banner mode hides the title rather than drawing the name twice', function()
    local app = readPanelFile('app.js')
    t.contains(app, 'show(title, !banner)',
        'the title is still drawn in banner mode, so the server name appears twice')
    t.contains(app, 'show(subtitle, !banner)')
end)

t.test('the logo keeps a name for screen readers once it is the only heading', function()
    -- alt="" is correct while a real <h1> sits beside it and wrong the
    -- moment the logo IS the heading.
    local app = readPanelFile('app.js')
    t.contains(app, "logo.setAttribute('alt'",
        'the logo never gets an alt, so in banner mode the panel announces nothing')
end)

t.test('the stylesheet actually draws the class app.js sets', function()
    local css = readPanelFile('style.css')
    t.contains(css, '.logo-banner',
        'app.js sets a class the stylesheet never mentions, so banner mode looks identical to mark')
    t.contains(css, '#arena-header.logo-banner #arena-logo',
        'the banner class exists but never resizes the logo')
end)

t.test('the shipped setting is one the panel understands', function()
    -- tweaked() covers the typo case; this covers the file as it ships,
    -- since a default the panel silently ignores is the same defect with
    -- nobody to blame for it.
    local env = Sandbox.newArenaEnv()
    local style = env.Config.UI.logoStyle
    t.isTrue(style == 'mark' or style == 'banner',
        'config.lua ships logoStyle = ' .. tostring(style) .. ', which the panel does not recognise')
end)

-- ========================================================================
-- client/match.lua -- the loops that run while a player is in the arena
--
-- WHAT THESE ARE ABOUT. A round has two phases the player spends standing
-- in the arena: the frozen start countdown, and the live round. Only the
-- second one used to be watched, so a kill during the first was invisible
-- to every part of the system at once -- see the countdown tests below.
-- ========================================================================

--- Just enough vector3 for the two things client/match.lua does with one:
--- unpack it into three numbers, and take the length of a difference.
---
--- The shared sandbox stub is a plain { x, y, z } and says so, which is not
--- enough for `#(GetEntityCoords(ped) - center)`. LENGTH LIVES ON THE
--- DIFFERENCE rather than on the point: that is the only place production
--- asks for it, and it leaves `#coords` alone, which is what table.unpack
--- reads to decide how many values to hand back.
--- @return table
local function vec3(x, y, z)
    return setmetatable({ x, y, z, x = x, y = y, z = z }, {
        __sub = function(a, b)
            local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
            local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
            return setmetatable({}, { __len = function() return distance end })
        end,
    })
end

--- One fresh, fully isolated load of the REAL client/match.lua.
---
--- THE PED IS MODELLED, NOT STUBBED TO A CONSTANT: whether it is dead, and
--- the fact that a resurrect hands back a different handle, are the whole
--- subject of the countdown tests. The per-frame loops run on the sandbox's
--- thread runner so they can be stepped one pass at a time; collision is
--- answered as already-loaded so placeAt never yields and the entry handler
--- can be driven straight through.
--- @return table fixture
local function newMatchFixture()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 100,
        dead = false,
        coords = vec3(0.0, 0.0, 0.0),
        killerServerId = 7,
        serverEvents = {},
        notifications = {},
        resurrects = {},
        freezes = {},
        given = {},
        health = {},
        damage = {},
        cleared = 0,
    }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        vector3 = vec3,

        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            f.serverEvents[#f.serverEvents + 1] = { name = name, payload = payload }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- No inventory resource, so the client is the one that hands out the
        -- weapons -- which is the arrangement where "is this player armed"
        -- is a question this file's own calls can answer.
        GetResourceState = function() return 'missing' end,
        lib = { notify = function(data) f.notifications[#f.notifications + 1] = data end },

        -- The hash IS the name here. Nothing under test does arithmetic on
        -- one, and a readable value makes an assertion about which weapon
        -- was handed over readable too.
        joaat = function(name) return name end,

        PlayerPedId = function() return f.ped end,
        IsEntityDead = function() return f.dead end,
        GetEntityCoords = function() return f.coords end,
        GetEntityHeading = function() return 90.0 end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,

        NetworkResurrectLocalPlayer = function(x, y, z)
            f.resurrects[#f.resurrects + 1] = { x = x, y = y, z = z }
            f.dead = false
            -- A resurrect can hand back a new ped, and production says so in
            -- as many words. Modelled, so a call left pointing at the old
            -- handle shows up as one.
            f.ped = f.ped + 1
        end,
        FreezeEntityPosition = function(ped, frozen)
            f.freezes[#f.freezes + 1] = { ped = ped, frozen = frozen }
        end,
        GiveWeaponToPed = function(ped, weapon, ammo)
            f.given[#f.given + 1] = { ped = ped, weapon = weapon, ammo = ammo }
        end,
        SetEntityHealth = function(ped, health)
            f.health[#f.health + 1] = { ped = ped, health = health }
        end,
        ApplyDamageToPed = function(ped, amount)
            f.damage[#f.damage + 1] = { ped = ped, amount = amount }
        end,

        ClearPedBloodDamage = function() end,
        SetPedAmmo = function() end,
        SetPedArmour = function() end,
        SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end,
        SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end,
        RemoveWeaponFromPed = function() end,

        SetEntityCoordsNoOffset = function() end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGroundZFor_3dCoord = function() return false, nil end,
        GetGameTimer = function() return 0 end,

        DisableControlAction = function() end,

        DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end,
        SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 900 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 5 end,
        GetPlayerServerId = function() return f.killerServerId end,

        -- The team outline, which the blip loop now drives on every pass.
        PlayerId = function() return 0 end,
        DoesEntityExist = function() return true end,
        SetEntityDrawOutline = function() end,
        SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function() end,

        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,

        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ReleaseDeadState = function() end,
            -- Counted rather than performed: whether the LIVE path still
            -- routes a death through it is the contract, and the countdown
            -- path deliberately does not.
            ClearDeadState = function() f.cleared = f.cleared + 1 return true end,
        },
    })

    Sandbox.loadInto('../client/match.lua', env)

    f.env = env
    f.step = runner.step
    f.aliveThreads = runner.aliveCount

    function f.fire(name, ...)
        local handler = handlers[name]
        if not handler then error('client/match.lua registered no handler for ' .. name) end
        handler(...)
    end

    --- Puts this player in the arena the way ArenaMatch.Start does, and
    --- leaves them where the server leaves them: placed, armed, frozen, and
    --- with `startCountdownSeconds` still to run before the round is live.
    --- @param overrides table? -- merged into the enterArena payload
    function f.enter(overrides)
        local payload = {
            matchId = 'match-1',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
            scatterRadius = 0.0,
            freezeSeconds = 5,
            loadout = { weapons = { { weapon = 'WEAPON_PISTOL', ammo = 42 } }, health = 200, armor = 0 },
        }
        for key, value in pairs(overrides or {}) do payload[key] = value end
        f.fire('crimson_arena:client:enterArena', payload)
    end

    return f
end

t.test('a death during the start countdown is caught at all', function()
    -- THE DEFECT: the death watch was opened by the matchLive handler, and
    -- players are put in the arena a whole countdown before that event
    -- arrives. A kill in that window was reported to nobody, cleared for
    -- nobody, and left the victim a real corpse -- one the operator's own
    -- medical script sees, in a routing bucket no ambulance can reach.
    local f = newMatchFixture()
    f.enter()

    t.equals(#f.resurrects, 0, 'nothing should have happened before the player dies')

    f.dead = true
    f.step()

    t.equals(#f.resurrects, 1,
        'the countdown death was never noticed -- the watch is still waiting for matchLive')
    t.isFalse(f.dead, 'the player was left lying in the arena for the rest of the countdown')
end)

t.test('a countdown death is settled on the client, not reported and not held', function()
    -- ArenaMatch.OnDeath refuses any report from a match that is not 'live'
    -- yet, so sending one would set deathReported for a respawn that is
    -- never coming -- and ClearDeadState's hold, which the respawn is what
    -- releases, would keep the player invisible and frozen for the whole
    -- round. The round has not started: nobody is out, so nothing is sent.
    local f = newMatchFixture()
    f.enter()

    f.dead = true
    f.step()

    t.equals(#f.resurrects, 1, 'the countdown death was never noticed')
    t.equals(#f.serverEvents, 0,
        'a countdown death was reported to a server that refuses it, spending the round\'s one report')
    t.equals(f.cleared, 0,
        'the countdown death went into ClearDeadState\'s hold, which only a respawn releases')
end)

t.test('the countdown revive stands the player back up whole, still, and on the new handle', function()
    -- Measured on health rather than weapons: ox_inventory owns the weapons
    -- and this side never hands the ped one, so re-applying the loadout is
    -- visible as the vitals going back to full on the new handle.
    local f = newMatchFixture()
    f.enter()

    f.dead = true
    f.step()
    local revived = f.ped

    t.equals(f.health[#f.health].ped, revived, 'the health went to a handle the resurrect had replaced')
    t.equals(f.health[#f.health].health, 200, 'the revived player starts the round on a sliver of health')

    local lastFreeze = f.freezes[#f.freezes]
    t.equals(lastFreeze.ped, revived, 'the freeze was applied to a handle that no longer exists')
    t.isTrue(lastFreeze.frozen, 'dying became a way to start moving before the countdown ends')
end)

t.test('a countdown death does not spend the round\'s one report -- the first real kill still counts', function()
    local f = newMatchFixture()
    f.enter()

    f.dead = true
    f.step()
    t.equals(#f.resurrects, 1, 'the countdown death was never noticed')

    f.fire('crimson_arena:client:matchLive')
    f.dead = true
    f.step()

    t.equals(#f.serverEvents, 1, 'the death that actually counted was never reported')
    t.equals(f.serverEvents[1].name, 'crimson_arena:server:reportDeath')
    t.equals(f.serverEvents[1].payload.killerServerId, 7, 'the killer went unnamed, so nobody was credited')
end)

t.test('a death in the live round is still reported once and cleared once', function()
    local f = newMatchFixture()
    f.enter()
    f.fire('crimson_arena:client:matchLive')

    f.dead = true
    f.step()
    f.step()    -- the ped is still dead; a second pass must not report it again

    t.equals(#f.serverEvents, 1, 'the live death was reported a number of times that is not once')
    t.equals(f.cleared, 1, 'the live death was cleared a number of times that is not once')
    t.equals(#f.resurrects, 0,
        'a live death took the countdown path, which reports nothing and would leave it unscored')
end)

t.test('the boundary still waits for matchLive, and is not merely inert', function()
    -- The gating that stays. Fighters are frozen for the countdown, so a
    -- sphere that bit during it would bleed players who cannot walk back
    -- inside -- which is why only the death watch moved to entry.
    local f = newMatchFixture()
    f.coords = vec3(500.0, 0.0, 0.0)
    f.enter({
        boundary = {
            enabled = true,
            center = { x = 0.0, y = 0.0, z = 0.0 },
            radius = 50.0,
            warningSeconds = 0,
            damagePerTick = 25,
            tickMs = 1000,
        },
    })

    f.step()
    f.step()
    t.equals(#f.notifications, 0, 'the boundary warned a player frozen in place by the countdown')
    t.equals(#f.damage, 0, 'the boundary bled a player frozen in place by the countdown')

    f.fire('crimson_arena:client:matchLive')
    f.step()    -- one pass: out of bounds, warned
    f.step()    -- the grace period is zero, so the next pass bleeds

    t.equals(#f.notifications, 1, 'the boundary never warned once the round was live')
    t.equals(#f.damage, 1, 'the boundary warned and then never bled')
end)

t.test('leaving the arena ends the watch, countdown or not', function()
    -- The loop's own gate changed from `matchLive` to `currentMatch`, and
    -- leaveArena clearing that is the only thing that now stops it.
    local f = newMatchFixture()
    f.enter()
    f.fire('crimson_arena:client:exitArena', {})

    f.dead = true
    f.step()
    f.step()

    t.equals(#f.serverEvents, 0, 'a death outside the arena was reported as an arena death')
    t.equals(#f.resurrects, 0, 'a loop from a match this player has left is still touching their ped')
end)

-- ------------------------------------------------------------------------
-- THE CREATE FORM BECOMES AN EDIT FORM FOR A HOST
--
-- Asserted as text, like the other panel-wiring tests: there is no DOM here,
-- and what these guard is that the three ends still agree -- the helper that
-- decides, the render that relabels, and the submit that has to post a
-- DIFFERENT event depending on which job the form is doing.
-- ------------------------------------------------------------------------

t.test('the form knows when it is editing rather than creating', function()
    local app = readPanelFile('app.js')

    t.contains(app, 'function editableMatch()',
        'nothing decides whether the form is creating or editing')
    t.contains(app, "match.state !== 'lobby'",
        'a round being fought could be edited like a form')
    t.contains(app, "player().isHost !== true",
        'a guest could edit the host\'s match')
end)

t.test('and posts updateMatch instead of createMatch when it is', function()
    -- The half that would be easy to leave out: a form that relabels itself
    -- and then still creates a second match is worse than one that never
    -- relabelled, because it looks like it worked.
    local app = readPanelFile('app.js')

    t.contains(app, "post('updateMatch'", 'editing still posts createMatch')
    t.contains(app, "post('createMatch'", 'creating stopped working')
end)

t.test('the entry fee is not offered while editing, since it cannot change', function()
    local app = readPanelFile('app.js')
    t.contains(app, "if (editing) show(byId('create-fee-row'), false)",
        'the fee is still offered on a lobby where it has already been paid')
end)

t.test('the form is seeded from the match once, not on every broadcast', function()
    -- Re-seeding each push would overwrite the host mid-edit -- the same
    -- class of bug as writing into an input while it is focused.
    local app = readPanelFile('app.js')
    t.contains(app, 'state.seededFromMatch !== editable.id',
        'the seed is not keyed on the match, so it repeats on every push')
end)

print('panel_spec')
-- ======================================================================
-- HOW THIS PANEL HIDES THINGS, and it is a class rather than an attribute
--
-- app.js's show() does `classList.toggle('hidden', ...)` and never touches
-- the `hidden` ATTRIBUTE. So an element written with a bare `hidden` in the
-- markup is hidden by the attribute, and nothing in the panel can ever
-- reveal it -- show(node, true) removes a class that was not what was
-- hiding it. The element is invisible for the life of the resource.
--
-- That is not hypothetical: the radar row shipped that way for ten minutes.
-- It is also invisible to the panel tests, which load app.js and never read
-- index.html -- so the guard has to live here, on the markup itself.
-- ======================================================================

t.test('nothing in index.html hides with the attribute this panel cannot clear', function()
    local handle = assert(io.open('../html/index.html', 'r'), 'cannot open index.html')
    local markup = handle:read('a')
    handle:close()

    local offenders = {}
    for tag in markup:gmatch('<[^>!][^>]*>') do
        -- The attribute, standing on its own -- not `class="hidden"`, and
        -- not a word ending in `hidden` like `data-hidden`.
        if tag:match('%shidden%s*/?>') or tag:match('%shidden%s') then
            local id = tag:match('id="([^"]+)"') or tag:sub(1, 40)
            offenders[#offenders + 1] = id
        end
    end

    t.equals(table.concat(offenders, ', '), '',
        'these elements hide with the `hidden` attribute, which app.js never clears -- they can never be shown. Use class="hidden".')
end)

t.test('and the panel really does hide with a class, so that rule is the right one', function()
    -- Guards the guard: if show() ever switched to the attribute, the test
    -- above would be enforcing the opposite of the truth.
    local handle = assert(io.open('../html/app.js', 'r'))
    local source = handle:read('a')
    handle:close()

    t.contains(source, "classList.toggle('hidden'",
        'show() no longer hides with a class, so the markup rule above is now backwards')
end)

-- ========================================================================
-- NOTHING IS CLIPPED AWAY
--
-- REPORTED FROM LIVE TESTING: the Create Match button was partly cut off,
-- and "pretty much gone" once the radar row was switched on; and the
-- loadout screen clipped weapons off the bottom.
--
-- Both are the same shape of fault. #arena-body and .arena-panel are both
-- `overflow: hidden` -- deliberately, because a scrollbar on the page would
-- sit over the game -- so EVERY box inside them that can grow taller than
-- its row must either scroll or be bounded. One that does neither does not
-- overflow visibly; it is silently cut off, and what is cut off is the
-- bottom, which is where the buttons are.
--
-- Asserted against the stylesheet because there is no browser here to
-- measure in. It cannot prove a layout fits; it can prove that every box
-- which grows has somewhere for the growth to go, which is the property
-- that was missing.
-- ========================================================================

--- The declarations inside one CSS rule, or nil when the rule is absent.
--- @param css string
--- @param selector string -- exactly as written in the file
--- @return string|nil
local function ruleBody(css, selector)
    local pattern = selector:gsub('%p', '%%%0') .. '%s*{(.-)}'
    return css:match(pattern)
end

t.test('every growable box inside the hidden panel can scroll', function()
    local css = readPanelFile('style.css')

    -- Each of these holds content whose height depends on config or on
    -- what the player has picked, and each sits inside a container that
    -- clips. The create panel grows by a whole field when the radar is
    -- switched on; the loadout column carries a min-height floor on its
    -- melee section that stops it shrinking to fit.
    for _, selector in ipairs({ '#create-panel', '#loadout-lists', '#match-list' }) do
        local body = ruleBody(css, selector)
        t.isNotNil(body, ('%s has no rule at all'):format(selector))
        t.contains(body, 'overflow-y: auto',
            ('%s can grow taller than its row and has nowhere to put the overflow -- '
                .. 'it will be cut off rather than scroll'):format(selector))
        t.contains(body, 'min-height: 0',
            ('%s cannot shrink below its content, so its own overflow never becomes '
                .. 'scrollable'):format(selector))
    end
end)

t.test('and the create panel is bounded, or there is nothing to scroll within', function()
    -- align-self: start makes a grid item take its content height, which
    -- is right for a box that should hug its content -- and means
    -- overflow-y has no bound to act against unless one is given.
    local body = ruleBody(readPanelFile('style.css'), '#create-panel')

    t.contains(body, 'max-height',
        'the create panel scrolls against no bound, so it still grows past the panel')
end)

t.test('the panel body still refuses to scroll as a page', function()
    -- The control for all of the above: the fix must not be "let the page
    -- scroll". A scrollbar there sits over the game.
    local css = readPanelFile('style.css')

    local body = ruleBody(css, '#arena-body')
    t.isNotNil(body)
    t.contains(body, 'overflow: hidden', 'the panel body started scrolling as a page')
end)

os.exit(t.summary())
