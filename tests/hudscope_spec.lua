--[[
    crimson_arena/tests/hudscope_spec.lua

    WHOSE SCOREBOARD A PLAYER IS ALLOWED TO SEE -- asked of the two client
    files TOGETHER, which is the only way the question has a true answer.

    client/match.lua refuses a board belonging to somebody else's round. That
    refusal was written, reviewed, and covered by a passing test, and for as
    long as it existed it did nothing at all: client/ui.lua registered a
    SECOND handler for the same event that forwarded every board it was
    handed, unconditionally, with `visible = true` bolted on. FiveM runs
    every handler registered for an event, and fxmanifest.lua loads ui.lua
    FIRST -- so the foreign board was already at the panel by the time the
    guard ran, and a guard cannot un-send a message.

    NOTHING THAT LOADED ONE FILE COULD HAVE SEEN IT. tests/blipscope_spec.lua
    drives the real client/match.lua and stubs `ArenaUI` with a table of its
    own, so ui.lua is not in the room; tests/panel_spec.lua loads the real
    ui.lua and never loads match.lua. Each was green, both were honest about
    the file they tested, and the defect lived in the space between them.

    So this file loads BOTH, in fxmanifest.lua's order, behind a handler
    registry that keeps a LIST per event rather than the last writer -- which
    is what FiveM does and what every other fixture in this suite, reasonably,
    does not bother to model. The assertions are about what reached
    SendNUIMessage, because that is the last thing this resource controls
    before the board is on somebody's screen.

    WHAT IS STUBBED: the NUI bridge, ox_lib, client/dispatch.lua's ArenaDispatch,
    and the natives client/match.lua calls on the way into a round. Not
    ArenaUI -- the whole point is that it is the real one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('hudscope_spec')

--- Natives whose return value nothing on these paths reads.
local SILENT = {
    'FreezeEntityPosition', 'GiveWeaponToPed', 'SetEntityHealth', 'ApplyDamageToPed',
    'ClearPedBloodDamage', 'SetPedAmmo', 'SetPedArmour', 'SetCurrentPedWeapon',
    'GiveWeaponComponentToPed', 'SetPedWeaponTintIndex', 'RemoveAllPedWeapons',
    'RemoveWeaponFromPed', 'SetEntityCoordsNoOffset', 'SetEntityHeading',
    'RequestCollisionAtCoord', 'DisableControlAction', 'DisablePlayerFiring',
    'SetFrontendActive', 'SetWeatherTypeNowPersist', 'NetworkOverrideClockTime',
    'ClearOverrideWeather', 'NetworkClearClockTimeOverride', 'NetworkResurrectLocalPlayer',
    'SetBlipSprite', 'SetBlipColour', 'SetBlipDisplay', 'SetBlipAsShortRange',
    'BeginTextCommandSetBlipName', 'AddTextComponentSubstringPlayerName',
    'EndTextCommandSetBlipName', 'RemoveBlip', 'SetEntityDrawOutline',
    'SetEntityDrawOutlineShader', 'SetEntityDrawOutlineColor',
    'SetEntityDrawOutlineRenderTechnique', 'ResetEntityDrawOutlineRenderTechnique',
    'SetPlayerTeam', 'NetworkSetFriendlyFireOption', 'SetCanAttackFriendly',
}

--- One fresh load of the REAL client/ui.lua and client/match.lua, together.
--- @return table fixture
local function newFixture()
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local f = { sent = {} }

    -- EVERY handler kept, in registration order. A fixture that wrote
    -- `handlers[name] = fn` would silently drop one of the two this whole
    -- file exists to catch, and would have reported the defect as fixed.
    local function register(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
    end

    local overrides = {
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        RegisterNetEvent = register,
        AddEventHandler = register,
        RegisterNUICallback = function() end,
        SendNUIMessage = function(message) f.sent[#f.sent + 1] = message end,
        SetNuiFocus = function() end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        print = function() end,
        joaat = function(value) return #tostring(value) end,
        PlayerPedId = function() return 1001 end,
        PlayerId = function() return 0 end,
        IsEntityDead = function() return false end,
        GetEntityHeading = function() return 0.0 end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 0 end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        GetPlayerServerId = function() return 1 end,
        GetPlayerFromServerId = function(id) return id end,
        NetworkIsPlayerActive = function() return true end,
        DoesEntityExist = function() return true end,
        AddBlipForEntity = function() return 1 end,
        DoesBlipExist = function() return true end,
        GetBlipInfoIdEntityIndex = function() return 0 end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGroundZFor_3dCoord = function() return true, 30.0 end,
        GetGameTimer = function() return 0 end,
        IsPauseMenuActive = function() return false end,
        GetPedSourceOfDeath = function() return 0 end,
        IsEntityAPed = function() return false end,
        IsPedAPlayer = function() return false end,
        NetworkGetPlayerIndexFromPed = function() return -1 end,
        lib = {
            callback = { await = function() return nil end },
            notify = function() end,
        },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ReleaseDeadState = function() end,
            ClearDeadState = function() return true end,
        },
    }
    for _, name in ipairs(SILENT) do overrides[name] = function() end end

    local env = Sandbox.newEnv(overrides)
    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/config.weapons.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    -- fxmanifest.lua's own order. Reversing these two would hide the defect
    -- this file is about, because then the guard would run last and win.
    Sandbox.loadInto('../Crimson-Arena/client/ui.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    f.env = env

    --- How many handlers this resource registered for an event.
    function f.handlerCount(name)
        return #(handlers[name] or {})
    end

    --- Delivers a server event the way FiveM does: every handler, in order.
    function f.fire(name, ...)
        for _, handler in ipairs(handlers[name] or {}) do handler(...) end
    end

    --- Every `hud` message posted since `mark`, newest last.
    function f.hudSince(mark)
        local found = {}
        for index = mark + 1, #f.sent do
            if f.sent[index].action == 'hud' then found[#found + 1] = f.sent[index].data or {} end
        end
        return found
    end

    --- The board inside a hud payload, whichever shape it arrived in.
    function f.boardOf(payload)
        local hud = payload.hud
        if type(hud) == 'table' then return hud.scoreboard end
        return payload.scoreboard
    end

    --- Walks in as a fighter in `matchId` on the crimson side.
    function f.enterMatch(matchId)
        f.fire('crimson_arena:client:enterArena', {
            matchId = matchId,
            modeKey = 'tdm',
            teamKey = 'crimson',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 90.0 },
            scatterRadius = 0.0,
            freezeSeconds = 0,
            loadout = { weapons = {}, health = 200, armor = 0 },
        })
        f.fire('crimson_arena:client:matchLive')
    end

    return f
end

--- A board the server would build, named as belonging to `matchId`.
local function board(matchId, name)
    return {
        matchId = matchId,
        remaining = 3,
        total = 4,
        kills = 2,
        deaths = 1,
        scoreboard = { { id = 99, name = name, team = 'ash', alive = true } },
    }
end

t.test('ONE handler answers matchHud, not two', function()
    local f = newFixture()

    -- The count is the defect stated at its smallest. It is not the whole
    -- test -- a second handler somewhere else would still pass this -- but
    -- it is the line that goes red the instant anybody adds one back, and it
    -- says why in a sentence.
    t.equals(f.handlerCount('crimson_arena:client:matchHud'), 1,
        'more than one handler is registered for matchHud. FiveM runs them ALL, so whichever '
        .. 'one refuses a foreign board cannot stop the other from sending it -- see the note '
        .. 'at the top of this file and the one where the handler used to be in client/ui.lua')
end)

t.test('and NO client file registers a second one, which the count above cannot see', function()
    -- THE HANDLER COUNT ABOVE ONLY SEES THE TWO FILES THIS FIXTURE LOADS.
    -- fxmanifest.lua puts six Lua files in the client realm, and the note
    -- left where the handler used to be in client/ui.lua tells a future
    -- maintainer that this spec 'fails if a second handler comes back'. That
    -- was true of ui.lua and match.lua and of nowhere else: the identical
    -- three lines added to client/main.lua would have undone the guard in
    -- exactly the same way with every spec green.
    --
    -- So this reads the source of every client file the manifest names, the
    -- same way tests/friendlyfireends_spec.lua guards its own banned natives,
    -- and the list comes out of the manifest so a file added tomorrow is
    -- covered the day it is added.
    local manifest = assert(io.open('../Crimson-Arena/fxmanifest.lua', 'r'))
    local manifestText = manifest:read('a')
    manifest:close()

    local block = manifestText:match('client_scripts%s*{(.-)}')
    t.isNotNil(block, 'fxmanifest.lua no longer has a client_scripts block this test can read')

    local files = {}
    for name in block:gmatch("'([^']+%.lua)'") do
        -- '@other_resource/file.lua' is not this resource's code.
        if not name:match('^@') then files[#files + 1] = name end
    end
    t.isTrue(#files >= 5,
        ('only %d client file(s) were parsed out of fxmanifest.lua -- the parse has come '
            .. 'unstuck and this test is guarding almost nothing'):format(#files))

    local sites = {}
    for _, name in ipairs(files) do
        local handle = assert(io.open('../Crimson-Arena/' .. name, 'r'),
            name .. ' is in the manifest and not on disk')
        local text = handle:read('a')
        handle:close()

        local n = 0
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local bare = line:gsub('^%s+', '')
            -- Comments are allowed: the note in client/ui.lua names the event
            -- at length while explaining why it registers nothing.
            if not bare:match('^%-%-')
                and bare:find("RegisterNetEvent%s*%(%s*'crimson_arena:client:matchHud'")
            then
                sites[#sites + 1] = ('%s:%d'):format(name, n)
            end
        end
    end

    t.equals(#sites, 1,
        ('%d client file(s) register a handler for matchHud (%s). FiveM runs them ALL, so a '
            .. 'second one undoes the guard in client/match.lua no matter which file it is in.')
            :format(#sites, table.concat(sites, ', ')))
end)

t.test('a board from somebody else\'s round never reaches the panel', function()
    local f = newFixture()
    f.enterMatch('match-1')

    local mark = #f.sent
    f.fire('crimson_arena:client:matchHud', board('match-2', 'SomebodyElse'))

    local posted = f.hudSince(mark)
    t.equals(#posted, 0,
        ('a fighter in match-1 was sent match-2\'s scoreboard -- %d hud message(s) reached the panel')
            :format(#posted))
end)

t.test('and the panel is not forced open to show it', function()
    -- The separate half of the same defect. UpdateHud writes `visible = true`
    -- into every payload it builds, so the stray handler did not merely leak
    -- a roster: it opened the HUD on a player who was mid-round with their
    -- own board already drawn, and replaced what was on it.
    --
    -- THE FIRST VERSION OF THIS TEST RAN NO ASSERTIONS AT ALL. It was written
    -- as `for _, payload in ipairs(f.hudSince(mark)) do t.isFalse(...) end`,
    -- and when production is CORRECT that list is empty -- so the loop body
    -- never ran and the test passed having checked nothing. It could only
    -- ever fire in the state the test above already fails on, which makes it
    -- a duplicate of that test wearing a different name, not a second check.
    --
    -- A loop over a list that is empty on the happy path is never a test.
    -- Assert the list is non-empty first, or assert on a single value.
    local f = newFixture()
    f.enterMatch('match-1')

    local mark = #f.sent
    f.fire('crimson_arena:client:matchHud', board('match-2', 'SomebodyElse'))

    -- The CONTROL: a board this player IS in must reach the panel visible, or
    -- everything below is satisfied by a HUD that never opens for anybody.
    local ownMark = #f.sent
    f.fire('crimson_arena:client:matchHud', board('match-1', 'You'))
    local own = f.hudSince(ownMark)
    t.equals(#own, 1, 'the player\'s own board did not reach the panel, so this proves nothing')
    t.isTrue(own[1].visible == true, 'the HUD never opens at all, so "not forced open" is empty')

    -- And the foreign one, asserted as a COUNT rather than by walking a list
    -- that is empty when the code is right.
    local opened = 0
    for _, payload in ipairs(f.hudSince(mark)) do
        if payload.visible == true and (payload.hud or {}).matchId == 'match-2' then
            opened = opened + 1
        end
    end
    t.equals(opened, 0,
        'a foreign board was posted with visible = true, which opens the panel over the '
        .. 'player\'s own round')
end)

t.test('the player\'s OWN board still reaches the panel', function()
    -- The control. Deleting the handler in client/ui.lua is only a fix if
    -- the board still arrives by the other route; a test file that proved
    -- the foreign board was refused and nothing else would be just as green
    -- with the HUD switched off entirely.
    local f = newFixture()
    f.enterMatch('match-1')

    local mark = #f.sent
    f.fire('crimson_arena:client:matchHud', board('match-1', 'You'))

    local posted = f.hudSince(mark)
    t.equals(#posted, 1, 'the player\'s own scoreboard did not reach the panel')
    t.isTrue(posted[1].visible == true, 'the player\'s own board arrived with the HUD hidden')

    local rows = f.boardOf(posted[1])
    t.isNotNil(rows, 'the payload carried no scoreboard at all')
    t.equals(rows[1].name, 'You', 'the wrong roster was posted')
end)

t.test('a board carrying no match id at all is still drawn', function()
    -- BACKWARD COMPATIBILITY IS PART OF THE GUARD'S CONTRACT. The refusal is
    -- written as "we are in a round AND the board names a DIFFERENT one", so
    -- a payload with no id is drawn rather than dropped. A guard that read
    -- `data.matchId ~= currentMatch.id` without the nil test would blank the
    -- HUD of every player the moment any push went out without one.
    local f = newFixture()
    f.enterMatch('match-1')

    local mark = #f.sent
    f.fire('crimson_arena:client:matchHud', {
        remaining = 2,
        total = 4,
        scoreboard = { { id = 1, name = 'You', team = 'crimson', alive = true } },
    })

    t.equals(#f.hudSince(mark), 1,
        'a board with no matchId was refused -- every push that predates the id field would '
        .. 'blank the HUD')
end)

t.test('a SPECTATOR is still shown the board of the match they are watching', function()
    -- Not in a round, so `currentMatch` is nil and the guard does not apply.
    -- Rejecting this would blank the HUD of the player who opened the camera
    -- on purpose, which is the case the guard's own comment names.
    local f = newFixture()

    local mark = #f.sent
    f.fire('crimson_arena:client:matchHud', board('match-2', 'SomebodyElse'))

    local posted = f.hudSince(mark)
    t.equals(#posted, 1, 'a watcher who is in no round of their own was refused the board')
end)

os.exit(t.summary())
