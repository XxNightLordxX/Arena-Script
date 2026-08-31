--[[
    crimson_arena/tests/panel_spec.lua

    The real client/ui.lua and client/main.lua, loaded into a sandbox.

    Both files are deliberately thin -- they forward, they do not decide --
    so what is worth testing about them is the wiring itself, and wiring is
    the part that fails silently. An event the server fires that no handler
    answers looks exactly like a feature nobody built: the results board the
    README promises is computed, sent, and dropped on the floor, with nothing
    in either console. A state request made on every client's behalf at start
    looks exactly like nothing at all, right up until the server is
    serialising the whole match list to every player on it four times a
    second because it read that request as "my panel is open".

    WHAT IS STUBBED, and no more than that: the NUI bridge (SendNUIMessage,
    SetNuiFocus, RegisterNUICallback), ox_lib's callback and notify, and --
    for the lobby file -- the fixtures it builds at start: the ped, the blip
    and the command. Config is the real config.lua, because the interaction
    mode and the command name are read out of it.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

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

-- ========================================================================
-- client/main.lua -- the lobby fixtures and the startup thread
-- ========================================================================

--- One fresh, fully isolated load of client/main.lua, with its start-up
--- thread run to completion.
--- @return table fixture
local function newLobbyFixture()
    local serverEvents = {}
    local built = {}

    local env = Sandbox.newEnv({
        -- The start-up thread reaches every line below without waiting on
        -- anything: the model is already loaded, so its bounded wait never
        -- runs a pass.
        CreateThread = function(fn) fn() end,
        Wait = function() end,
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
        CreatePed = function() built.ped = true return 7 end,
        SetModelAsNoLongerNeeded = function() end,
        SetEntityAsMissionEntity = function() end,
        FreezeEntityPosition = function() end,
        SetEntityInvincible = function() end,
        SetBlockingOfNonTemporaryEvents = function() end,
        TaskStartScenarioInPlace = function() end,
        exports = { ox_target = { addLocalEntity = function() built.target = true end } },

        AddBlipForCoord = function() built.blip = true return 3 end,
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

    return { env = env, serverEvents = serverEvents, built = built }
end

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

print('panel_spec')
os.exit(t.summary())
