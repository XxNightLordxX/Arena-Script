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
---
--- `wholeRealm` loads EVERY client-realm file the manifest names instead, and
--- records which of them registered what. Only the census test wants that:
--- the behavioural tests below want the two files the defect lived in and
--- nothing else attaching handlers to the same events.
--- @param wholeRealm boolean? -- load every client-realm file, not just two
--- @return table fixture
local function newFixture(wholeRealm)
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local f = { sent = {}, registeredIn = {} }

    --- Which file is being loaded right now, so a registration can be blamed
    --- on it. nil while the fixture is not walking the manifest.
    local loading = nil

    -- EVERY handler kept, in registration order. A fixture that wrote
    -- `handlers[name] = fn` would silently drop one of the two this whole
    -- file exists to catch, and would have reported the defect as fixed.
    local function register(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
        if loading then
            f.registeredIn[name] = f.registeredIn[name] or {}
            local where = f.registeredIn[name]
            where[#where + 1] = loading
        end
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
        -- client/exports.lua calls `exports('name', fn)`; without this it
        -- cannot be loaded at all, which is why the census below never
        -- looked at the one file the manifest marks LAST.
        exports = setmetatable({}, { __call = function() end }),
        -- WHICH VM THIS IS, and false is the honest answer here: a
        -- shared_script asks it to decide which half of itself to run, and
        -- this fixture is the CLIENT. shared/compat/dispatch.lua cannot be
        -- loaded at all without it.
        IsDuplicityVersion = function() return false end,
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ReleaseDeadState = function() end,
            ClearDeadState = function() return true end,
        },
    }
    for _, name in ipairs(SILENT) do overrides[name] = function() end end

    local env = Sandbox.newEnv(overrides)

    if wholeRealm then
        -- THE MANIFEST'S OWN LIST, IN THE MANIFEST'S OWN ORDER, so this
        -- cannot drift from what FXServer loads and cannot be narrowed by
        -- somebody editing a list in here.
        local manifest = Sandbox.readDeclarations('../Crimson-Arena/fxmanifest.lua')
        for _, name in ipairs(Sandbox.realmScripts(manifest, 'client')) do
            loading = name
            Sandbox.loadInto('../Crimson-Arena/' .. name, env)
        end
        loading = nil
    else
        Sandbox.loadInto('../Crimson-Arena/config.lua', env)
        Sandbox.loadInto('../Crimson-Arena/config.weapons.lua', env)
        Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
        -- fxmanifest.lua's own order. Reversing these two would hide the
        -- defect this file is about, because then the guard would run last
        -- and win.
        Sandbox.loadInto('../Crimson-Arena/client/ui.lua', env)
        Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)
    end

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
    -- fxmanifest.lua puts far more than two Lua files into the client VM, and
    -- the note left where the handler used to be in client/ui.lua tells a
    -- future maintainer that this spec 'fails if a second handler comes
    -- back'. Making that true took three corrections, each of which was
    -- silent while it was wrong:
    --
    --   AddEventHandler. Once any file has called RegisterNetEvent for an
    --     event name -- client/match.lua:2844 does -- a handler attached
    --     anywhere with AddEventHandler(name, fn) runs on every server push
    --     too, in registration order. This fixture concedes the point by
    --     aliasing both natives to one recorder. The census greped only for
    --     RegisterNetEvent. MEASURED: the original defect re-added with
    --     AddEventHandler left all 129 spec files green.
    --
    --   Long comments. The comment test is a leading `--`, so `--[[x]]
    --     RegisterNetEvent('...matchHud', ...)` was discarded as a comment
    --     while the registration after it executes. MEASURED: also green.
    --
    --   The file list. A hand-rolled regex over the client_scripts block read
    --     single-quoted names only, stopped at the first closing brace, and
    --     never looked at shared_scripts -- which loads into the client VM as
    --     well. Sandbox.readDeclarations EXECUTES the manifest instead, so
    --     quoting and formatting stop mattering, and Sandbox.realmScripts
    --     unions the shared list in.
    local manifest = Sandbox.readDeclarations('../Crimson-Arena/fxmanifest.lua')
    local files = Sandbox.realmScripts(manifest, 'client')

    -- AND THE LIST IS CROSS-CHECKED AGAINST THE DISK, which is what the floor
    -- below cannot do. friendlyfireends_spec's twin of this census already
    -- does it; this one had only the floor, and a floor has SLACK -- ten
    -- client-realm files against `>= 8` means two could go missing and this
    -- census would shrink, pass, and go on reporting that exactly one file
    -- registers the handler. The number is not the guard; the list is.
    local seen = {}
    for _, name in ipairs(files) do seen[name] = true end

    local onDisk = io.popen('ls ../Crimson-Arena/client/*.lua ../Crimson-Arena/shared/*.lua '
        .. '../Crimson-Arena/shared/compat/*.lua 2>/dev/null')
    if onDisk then
        for line in onDisk:lines() do
            local name = line:gsub('^%.%./Crimson%-Arena/', '')
            t.isTrue(seen[name] == true,
                name .. ' is on disk and not in the client-realm list this census scans -- '
                .. 'either the manifest no longer loads it, or the manifest read has come '
                .. 'unstuck. Either way a second matchHud handler in it would go unreported')
        end
        onDisk:close()
    end

    t.isTrue(#files >= 8,
        ('only %d client-realm file(s) came back from the manifest -- the read has come unstuck '
            .. 'and this census is covering almost nothing'):format(#files))

    local sites = {}
    for _, name in ipairs(files) do
        local handle = assert(io.open('../Crimson-Arena/' .. name, 'r'),
            name .. ' is in the manifest and not on disk')
        local text = Sandbox.blankLongComments(handle:read('a'))
        handle:close()

        -- MATCHED ACROSS THE WHOLE FILE, NOT LINE BY LINE.
        --
        -- A per-line scan needs the native and the quoted event name on the
        -- same physical line, and breaking a long registration over lines is
        -- an ordinary formatting choice:
        --
        --     RegisterNetEvent(
        --         'crimson_arena:client:matchHud',
        --         function(d) ArenaUI.UpdateHud(d) end
        --     )
        --
        -- MEASURED: written that way in client/main.lua, the census found
        -- nothing and all 129 spec files stayed green. Lua's `%s` matches a
        -- newline, so matching the whole file closes it -- and both quote
        -- styles are accepted, because fxmanifest.lua is not the only place
        -- this resource is ordinary Lua.
        --
        -- Long comments are already blanked above. A `--` LINE comment
        -- containing the full pattern would be a false positive; verified
        -- against the shipped tree that none does, including the note in
        -- client/ui.lua that names the event at length while explaining why
        -- it registers nothing.
        for _, native in ipairs({ 'RegisterNetEvent', 'AddEventHandler' }) do
            local pattern = native .. '%s*%(%s*[\'"]crimson_arena:client:matchHud'
            local from = 1
            while true do
                local at = text:find(pattern, from)
                if not at then break end
                local _, newlines = text:sub(1, at):gsub('\n', '')
                sites[#sites + 1] = ('%s at %s:%d'):format(native, name, newlines + 1)
                from = at + 1
            end
        end
    end

    t.equals(#sites, 1,
        ('%d handler(s) for matchHud are registered across the client realm (%s). FiveM runs '
            .. 'them ALL -- RegisterNetEvent and AddEventHandler alike -- so a second one undoes '
            .. 'the guard in client/match.lua whichever file and whichever native it uses.')
            :format(#sites, table.concat(sites, ', ')))
end)

t.test('and the same question asked by LOADING the realm, which no spelling can dodge', function()
    -- THE CENSUS ABOVE READS TEXT, AND TEXT CAN ALWAYS BE WRITTEN ANOTHER WAY.
    --
    -- It has been widened three times -- AddEventHandler, long comments,
    -- across newlines, either quote style -- and each widening was prompted
    -- by a form it had missed. MEASURED against the current pattern, five
    -- forms are caught and two are not:
    --
    --     local E = 'crimson_arena:client:matchHud'
    --     RegisterNetEvent(E, function(d) ArenaUI.UpdateHud(d) end)
    --
    --     RegisterNetEvent('crimson_arena:client:' .. 'matchHud', ...)
    --
    -- Both leave the census green, because the literal is not next to the
    -- call. Widening the pattern again would buy the next two forms and not
    -- the two after that: a source scan cannot win this.
    --
    -- SO ASK THE RUNTIME INSTEAD. This loads every client-realm file the
    -- manifest names, into the same recorder the fixture already uses for
    -- both natives, and counts what actually attached. A hoisted local, a
    -- concatenation, a name off a table -- all of them register, so all of
    -- them are counted. MEASURED: each of the three forms above makes this
    -- read 2, and the shipped tree reads 1.
    --
    -- THE TEXT CENSUS STAYS. It names the FILE AND LINE of an offender,
    -- which a count cannot, and it reads the four client files this fixture
    -- would otherwise never have loaded at all. The two fail differently and
    -- that is the point of having both.
    local f = newFixture(true)

    local where = f.registeredIn['crimson_arena:client:matchHud'] or {}
    t.equals(f.handlerCount('crimson_arena:client:matchHud'), 1,
        ('%d handler(s) for matchHud attached when the whole client realm was loaded (%s). '
            .. 'FiveM runs them ALL, so a second one undoes the guard in client/match.lua '
            .. 'however its name was spelled at the call.')
            :format(f.handlerCount('crimson_arena:client:matchHud'),
                #where > 0 and table.concat(where, ', ') or 'no file recorded'))

    -- AND IT REALLY LOADED THE WHOLE REALM, not the two files the other
    -- fixture loads -- otherwise a count of 1 is satisfied by never looking.
    local loaded = {}
    for _, names in pairs(f.registeredIn) do
        for _, name in ipairs(names) do loaded[name] = true end
    end
    local seen = 0
    for _ in pairs(loaded) do seen = seen + 1 end
    t.isTrue(seen >= 4,
        ('only %d client-realm file(s) registered anything, so this fixture is not loading the '
            .. 'realm and the count above proves nothing'):format(seen))
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
    -- COUNTED THROUGH boardOf, WHICH ACCEPTS EITHER SHAPE -- and the first
    -- version of this read `(payload.hud or {}).matchId`, the NESTED shape
    -- client/match.lua posts. The defect it is named for posts the board
    -- FLAT: ui.lua's deleted handler called ArenaUI.UpdateHud(data), which
    -- puts matchId at the top level and leaves payload.hud nil. So under the
    -- real defect this counter never incremented, and the test went red on
    -- its control instead -- fallible, but not for the reason on the tin.
    local opened = 0
    for _, payload in ipairs(f.hudSince(mark)) do
        local hud = type(payload.hud) == 'table' and payload.hud or payload
        if payload.visible == true and hud.matchId == 'match-2' then
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

t.test('and the caller\'s visibility survives ArenaUI.UpdateHud', function()
    -- UpdateHud used to open `{ visible = true }` and depend on every caller
    -- passing a key that overwrote it. Nothing pinned that override, so
    -- putting the bolt-on back -- which is the shape of the original defect
    -- -- would have gone unnoticed.
    --
    -- Driven through the real exitArena path, which is one of the three
    -- callers that asks for the HUD to be HIDDEN.
    local f = newFixture()
    f.enterMatch('match-1')

    local mark = #f.sent
    f.fire('crimson_arena:client:exitArena', { returnCoords = { x = 0.0, y = 0.0, z = 0.0, w = 0.0 } })

    local posted = f.hudSince(mark)
    t.isTrue(#posted > 0, 'leaving the arena posted no hud message at all, so this proves nothing')

    for _, payload in ipairs(posted) do
        t.isFalse(payload.visible == true,
            'a caller asked for the HUD to be hidden and UpdateHud posted it visible anyway -- '
            .. 'the bolt-on default is back, which is the original defect wearing a new hat')
    end
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
