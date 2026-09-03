--[[
    crimson_arena/tests/blipscope_spec.lua

    WHO SEES WHAT ON THE MAP, AND FOR HOW LONG.

    Three separate rules share one loop in client/match.lua, and all three
    are the kind that fail silently -- nobody files a bug saying "I could see
    slightly too much", they just win more:

      TEAMMATES     always on the map, and wearing a coloured edge in their
                    team's own colour so the dot and the player match.
      ENEMIES       never on the map, except for the moment a radar sweep is
                    lit -- and never, ever wearing the edge, which draws
                    THROUGH walls and would be a wallhack with a palette.
      EVERYBODY ELSE  nothing at all. Not the spectator watching from the
                    camera, not the player standing outside the fence, not
                    the one who just walked out of the round.

    And all of it goes when the match does. A blip nobody removes stays on
    the map until the player reconnects; an outline nobody removes follows a
    ped around the city.

    These drive the REAL client/match.lua and count the natives. The
    scoreboard is delivered the way the server delivers it -- as matchHud,
    which every watcher of a match receives, fighters and spectators alike --
    because "the roster arrived" and "the roster may be drawn" are two
    different questions and this file is about the second one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('blipscope_spec')

-- Server ids. This player is 1; 2 is on their side, 3 and 4 are not.
local SELF, MATE, FOE, FOE2 = 1, 2, 3, 4

--- The scoreboard as server/match.lua builds it.
--- @param overrides table? -- [serverId] = { alive?, team? }
local function scoreboard(overrides)
    local rows = {
        { id = SELF, name = 'You',   alive = true, team = 'crimson' },
        { id = MATE, name = 'Mate',  alive = true, team = 'crimson' },
        { id = FOE,  name = 'Foe',   alive = true, team = 'ash' },
        { id = FOE2, name = 'Foe 2', alive = true, team = 'ash' },
    }
    for _, row in ipairs(rows) do
        for key, value in pairs((overrides or {})[row.id] or {}) do row[key] = value end
    end
    return rows
end

--- One fresh load of the real client/match.lua, with every blip and outline
--- native recorded instead of performed.
---
--- Peds are 1000 + serverId, so an assertion about which player was drawn
--- reads as the server id it is about.
local function newFixture(mutate)
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local clocks = {}          -- [coroutine] = ms that thread has waited

    local f = {
        ped = 1000 + SELF,
        blips = {},        -- [handle] = { ped = , colour = }
        outlines = {},     -- [ped] = true while drawn
        outlineCalls = {}, -- every SetEntityDrawOutline, in order
        outlineTicks = {}, -- the blip loop's own clock at each colour refresh
        colorCalls = {},   -- every SetEntityDrawOutlineColor, with its caller's clock
        shaderCalls = {},  -- every SetEntityDrawOutlineShader, likewise
        nextBlip = 1,
        streamed = { [MATE] = true, [FOE] = true, [FOE2] = true },
    }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        -- A PER-THREAD CLOCK, because the runner's own is global.
        --
        -- runner.elapsed sums every Wait from every captured thread, so it
        -- cannot tell "the blip loop slept for thirty seconds" from "six
        -- threads each slept five". The cadence tests below are entirely
        -- about how long ONE loop sleeps between two reconciliations, so
        -- each coroutine gets its own total.
        Wait = function(ms)
            local co = coroutine.running()
            clocks[co] = (clocks[co] or 0) + (tonumber(ms) or 0)
            return runner.Wait(ms)
        end,
        vector3 = function(x, y, z) return { x = x, y = y, z = z } end,

        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        lib = { notify = function() end },
        joaat = function(name) return name end,

        PlayerPedId = function() return f.ped end,
        PlayerId = function() return 0 end,
        IsEntityDead = function() return false end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetEntityHeading = function() return 0.0 end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,

        -- Player index 0 is us; every other index IS the server id, which
        -- keeps the two id spaces legible in the assertions below.
        GetPlayerServerId = function(player) return player == 0 and SELF or player end,
        GetPlayerFromServerId = function(serverId)
            if serverId == SELF then return 0 end
            return f.streamed[serverId] and serverId or -1
        end,
        NetworkIsPlayerActive = function(player) return player == 0 or f.streamed[player] == true end,
        GetPlayerPed = function(player) return 1000 + (player == 0 and SELF or player) end,
        DoesEntityExist = function(entity) return entity ~= 0 end,

        AddBlipForEntity = function(ped)
            local handle = f.nextBlip
            f.nextBlip = handle + 1
            f.blips[handle] = { ped = ped }
            return handle
        end,
        RemoveBlip = function(handle) f.blips[handle] = nil end,
        DoesBlipExist = function(handle) return f.blips[handle] ~= nil end,
        SetBlipSprite = function() end,
        SetBlipColour = function(handle, colour)
            if f.blips[handle] then f.blips[handle].colour = colour end
        end,
        SetBlipDisplay = function() end,
        SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,

        SetEntityDrawOutline = function(ped, on)
            f.outlineCalls[#f.outlineCalls + 1] = { ped = ped, on = on }
            if on then f.outlines[ped] = true else f.outlines[ped] = nil end
        end,
        SetEntityDrawOutlineShader = function(shader)
            f.outlineShader = shader
            f.shaderCalls[#f.shaderCalls + 1] = { clock = clocks[coroutine.running()] or 0 }
        end,
        SetEntityDrawOutlineColor = function(r, g, b)
            f.outlineColor = { r, g, b }

            -- EVERY call, with the caller's own clock beside it. The tick
            -- list below is the blip loop's alone; this one is how a spec
            -- can tell WHICH kind of loop set the colour -- a thread whose
            -- clock never moves has never slept, so it is running every
            -- frame, and that is exactly the claim the hold makes.
            f.colorCalls[#f.colorCalls + 1] = { clock = clocks[coroutine.running()] or 0 }

            -- WHICH THREAD IS DOING THE RECONCILING, learned once and then
            -- held.
            --
            -- This used to re-learn it on every call, which was fine while
            -- exactly one loop set the colour. It is not: the per-frame arena
            -- thread re-asserts colour and shader every frame, because both
            -- are ONE global setting for the whole game and any other
            -- resource that writes them every frame owns them the rest of the
            -- time. With two callers, re-learning made the tick list alternate
            -- between two threads' clocks and the measured gap became
            -- nonsense -- 74,800ms out of a loop that sleeps 500.
            --
            -- The blip loop is always the first to call this: it is
            -- refreshOutlines that works the colour out at all, and the arena
            -- thread only re-asserts what refreshOutlines has already set. So
            -- the first caller is the one this test is about, and ticks from
            -- anything else are not reconciliations.
            local co = coroutine.running()
            if f.outlineThread == nil then f.outlineThread = co end
            if co ~= f.outlineThread then return end

            f.outlineTicks[#f.outlineTicks + 1] = clocks[co] or 0
        end,

        NetworkResurrectLocalPlayer = function() end,
        FreezeEntityPosition = function() end,
        GiveWeaponToPed = function() end,
        SetEntityHealth = function() end,
        ApplyDamageToPed = function() end,
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
        GetPedSourceOfDeath = function() return 0 end,
        IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end,
        NetworkGetPlayerIndexFromPed = function() return 0 end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,

        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = {
            Enter = function() end,
            Exit = function() end,
            ReleaseDeadState = function() end,
            ClearDeadState = function() return true end,
        },
    })

    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../client/match.lua', env)

    f.env = env
    f.step = runner.step
    -- THE CLOCK THE THREAD RUNNER WAS ALREADY KEEPING, and never read. Every
    -- guarantee in this file until now is about WHAT is drawn; the cadence
    -- tests below are about HOW OFTEN, and they cannot be written without it.
    -- The blip loop's OWN clock. It is the only thread that draws outlines,
    -- so it is the one whose coroutine has ticked when a colour is set.
    f.blipClock = function() return clocks[f.outlineThread] or 0 end

    function f.fire(name, payload)
        local handler = handlers[name]
        if not handler then error('client/match.lua registered no handler for ' .. name) end
        handler(payload)
    end

    --- The scoreboard, delivered the way the server delivers it.
    function f.hud(rows)
        f.fire('crimson_arena:client:matchHud', { visible = true, scoreboard = rows or scoreboard() })
    end

    --- Into the arena as a fighter, then live, which is what starts the loop.
    function f.enterLive(overrides)
        local payload = {
            matchId = 'match-1',
            modeKey = 'tdm',
            teamKey = 'crimson',
            spawn = { x = 10.0, y = 20.0, z = 30.0, w = 0.0 },
            scatterRadius = 0.0,
            freezeSeconds = 0,
            radar = false,
            loadout = { weapons = {}, health = 200, armor = 0 },
        }
        for key, value in pairs(overrides or {}) do payload[key] = value end
        f.fire('crimson_arena:client:enterArena', payload)
        f.fire('crimson_arena:client:matchLive', { matchId = 'match-1' })
    end

    --- Which server ids currently carry a blip.
    function f.blipped()
        local ids = {}
        for _, blip in pairs(f.blips) do ids[blip.ped - 1000] = true end
        return ids
    end

    function f.blipCount()
        local n = 0
        for _ in pairs(f.blips) do n = n + 1 end
        return n
    end

    function f.outlineCount()
        local n = 0
        for _ in pairs(f.outlines) do n = n + 1 end
        return n
    end

    return f
end

--- @param ids table -- set of server ids
--- @return string -- sorted, for a readable failure
local function listed(ids)
    local out = {}
    for id in pairs(ids) do out[#out + 1] = id end
    table.sort(out)
    return table.concat(out, ',')
end

-- ======================================================================
-- ANYBODY WHO IS NOT IN THE ARENA
-- ======================================================================

t.test('somebody who never entered the arena draws nothing at all', function()
    -- The scoreboard REACHES them: matchHud goes to everybody watching a
    -- match, which is how a spectator gets a HUD to read. Receiving the
    -- roster and being allowed to draw it are different things.
    local f = newFixture()
    f.hud()
    f.step()
    f.step()

    t.equals(f.blipCount(), 0,
        'a player who is not in the match was given blips for the fighters in it')
    t.equals(f.outlineCount(), 0, 'and an outline round them as well')
end)

t.test('and no amount of stepping starts a loop for them', function()
    -- The guard is the loop never starting, not the loop drawing nothing --
    -- but both have to hold, because a future change to either is the bug.
    local f = newFixture()
    f.hud()
    for _ = 1, 20 do f.step() end

    t.equals(f.blipCount(), 0, 'a loop started for somebody with no match')
    t.equals(#f.outlineCalls, 0, 'an outline native was called for somebody with no match')
end)

t.test('a fighter who walks out stops drawing, and takes it all with them', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()
    t.isTrue(f.blipCount() > 0, 'nothing was drawn while they were in the round, so this proves nothing')

    f.fire('crimson_arena:client:exitArena', {})

    t.equals(f.blipCount(), 0, 'their blips outlived the match -- these stay until they reconnect')
    t.equals(f.outlineCount(), 0, 'an outline followed a teammate out of the arena')

    -- And nothing comes back. A stopped loop that is merely paused would
    -- redraw on the next scoreboard.
    f.hud()
    for _ = 1, 5 do f.step() end
    t.equals(f.blipCount(), 0, 'the loop was still running after the player left the arena')
end)

-- ======================================================================
-- TEAMMATES
-- ======================================================================

t.test('a fighter sees their own side and nobody else', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()

    local ids = f.blipped()
    t.isTrue(ids[MATE] == true, 'a teammate was missing from the map')
    t.isNil(ids[FOE], 'an enemy was on the map with no radar sweep lit: ' .. listed(ids))
    t.isNil(ids[FOE2], 'an enemy was on the map with no radar sweep lit: ' .. listed(ids))
    t.isNil(ids[SELF], 'the player was blipped on top of their own map marker')
end)

t.test('and wears the haze -- teammates only, never the other side', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()

    t.isTrue(f.outlines[1000 + MATE] == true, 'a teammate had no coloured edge')
    t.isNil(f.outlines[1000 + FOE], 'AN ENEMY WAS OUTLINED -- the outline draws through walls')
    t.isNil(f.outlines[1000 + FOE2], 'an enemy was outlined')
    t.isNil(f.outlines[1000 + SELF], 'the player was outlined to themselves')
end)

t.test('the haze is the team colour, so the edge matches the dot', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()

    -- THE CONFIGURED COLOUR, not a hex pinned here.
    --
    -- The claim in the test name is that the edge round a teammate is the
    -- same colour the team is everywhere else, and that claim has to survive
    -- the palette being retuned -- which it has been, from #c81020 to a
    -- brighter #ff2233. A pinned triple turns a colour change into a failing
    -- test about nothing. Read the hex the fighters' team actually ships
    -- with and take it apart here rather than calling Arena.HexToRgb, so
    -- this is a second reading of the config and not an echo of the one
    -- under test.
    local hex = (((f.env.Config.Teams or {}).list or {}).crimson or {}).color
    t.isNotNil(hex, 'the crimson team ships with no colour to draw')

    local body = tostring(hex):gsub('^#', '')
    t.equals(#body, 6, 'the crimson colour is not a #rrggbb hex: ' .. tostring(hex))

    local want = {
        tonumber(body:sub(1, 2), 16),
        tonumber(body:sub(3, 4), 16),
        tonumber(body:sub(5, 6), 16),
    }

    t.isNotNil(f.outlineColor, 'no outline colour was ever set')
    t.equals(f.outlineColor[1], want[1], 'the outline red channel is not the team colour')
    t.equals(f.outlineColor[2], want[2], 'the outline green channel is not the team colour')
    t.equals(f.outlineColor[3], want[3], 'the outline blue channel is not the team colour')
end)

t.test('a dead teammate is neither blipped nor hazed', function()
    local f = newFixture()
    f.enterLive()
    f.hud(scoreboard({ [MATE] = { alive = false } }))
    f.step()

    t.isNil(f.blipped()[MATE], 'a fighter who is out was still on the map')
    t.isNil(f.outlines[1000 + MATE], 'a fighter who is out was still hazed')
end)

t.test('a free-for-all has no teammates, so it has no blips and no haze', function()
    local f = newFixture()
    f.enterLive({ modeKey = 'ffa', teamKey = nil })
    f.hud()
    f.step()

    t.equals(f.blipCount(), 0, 'a free-for-all put the other fighters on the map: ' .. listed(f.blipped()))
    t.equals(f.outlineCount(), 0, 'a free-for-all outlined the other fighters')
end)

-- ======================================================================
-- THE RADAR SWEEP
-- ======================================================================

t.test('with the radar on, a sweep lights the enemies and then goes dark', function()
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()

    -- LIT: the first pass of the loop draws everybody.
    f.step()
    local lit = f.blipped()
    t.isTrue(lit[FOE] == true, 'the sweep did not light the enemies: ' .. listed(lit))
    t.isTrue(lit[MATE] == true, 'the sweep dropped the teammates it should have kept')

    -- DARK: the loop's own Wait, then the removal.
    f.step()
    local dark = f.blipped()
    t.isNil(dark[FOE], 'the sweep never went dark -- this is a permanent enemy blip: ' .. listed(dark))
    t.isTrue(dark[MATE] == true,
        'going dark took the teammates with it -- your own side is not what the radar reveals')
end)

t.test('a lit sweep still does not haze the enemy it just lit', function()
    -- The two are deliberately separate: the sweep is a moment on the map,
    -- the outline is a permanent edge on a body. An enemy may have the first
    -- and must never have the second.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()
    f.step()

    t.isTrue(f.blipped()[FOE] == true, 'the sweep was not lit, so this proves nothing')
    t.isNil(f.outlines[1000 + FOE], 'a radar sweep put a permanent outline on an enemy')
end)

t.test('DEFECT: the blip loop never sleeps a whole sweep between reconciliations', function()
    -- refreshOutlines runs at the top of the blip loop, so whatever that loop
    -- WAITS is the rate your own side is reconciled at. The radar branch used
    -- to wait the entire sweep interval in one go, so switching the radar on
    -- silently dropped teammate reconciliation from twice a second to once
    -- every thirty -- an eliminated teammate kept a coloured edge drawn
    -- through walls for half a minute after the board said they were out, and
    -- one who respawned onto a new ped had no edge at all until it came round.
    --
    -- Measured on the LOOP'S OWN clock. The thread runner's `elapsed` is a
    -- global sum across every captured thread, so it cannot tell one loop
    -- sleeping thirty seconds from six sleeping five -- which is exactly the
    -- distinction this test is about, and why an earlier version of it passed
    -- against the defect.
    for _, radar in ipairs({ true, false }) do
        local f = newFixture()
        f.enterLive({ radar = radar })
        f.hud()
        for _ = 1, 150 do f.step() end

        local ticks = f.outlineTicks
        t.isTrue(#ticks >= 3,
            ('the outline was refreshed %d time(s) with the radar %s -- too few to measure a gap')
                :format(#ticks, tostring(radar)))

        local worst = 0
        for index = 2, #ticks do
            local gap = ticks[index] - ticks[index - 1]
            if gap > worst then worst = gap end
        end

        -- A SECOND, which is what the radar-off branch already waited. The
        -- number this keeps out is 30,000.
        t.isTrue(worst <= 1000,
            ('with the radar %s the loop went %dms between reconciling your own side')
                :format(tostring(radar), worst))
    end
end)

t.test('and the sweep itself is not made faster by slicing it', function()
    -- THE BUG IN THE OTHER DIRECTION. Slicing the dark phase must not
    -- SHORTEN it: a radar that lights the enemies more often than the
    -- operator asked for gives away positions the sweep interval exists to
    -- protect, which is the thing this whole file is about.
    --
    -- Read off the blip loop's own clock, like the cadence test above, and
    -- measured between the moments an enemy appears on the map.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()

    local enemyBlip = function()
        for _, blip in pairs(f.blips) do
            if blip.ped == 1000 + FOE then return true end
        end
        return false
    end

    local lit = {}
    for _ = 1, 400 do
        local before = enemyBlip()
        f.step()
        if not before and enemyBlip() then lit[#lit + 1] = f.blipClock() end
    end

    t.isTrue(#lit >= 2, ('the radar lit up %d time(s) -- too few to measure an interval'):format(#lit))

    local interval = f.env.Config.Match.radar.intervalMs
    for index = 2, #lit do
        local gap = lit[index] - lit[index - 1]
        t.isTrue(gap >= interval * 0.9,
            ('the radar lit up again after %dms, against a configured %dms')
                :format(gap, interval))
    end
end)

t.test('with the radar off there is no sweep to catch, ever', function()
    local f = newFixture()
    f.enterLive({ radar = false })
    f.hud()

    for _ = 1, 12 do
        f.step()
        t.isNil(f.blipped()[FOE], 'an enemy appeared on a map with the radar switched off')
    end
end)

t.test('an operator who wants the old permanent enemy blips still gets them', function()
    -- The escape hatch, and the reason the predicate above is narrow rather
    -- than deleted: showEnemyBlips is a server saying it does not want a
    -- radar at all. It must still switch every enemy on permanently, and the
    -- sweep must not run underneath it.
    local f = newFixture(function(config) config.Teams.showEnemyBlips = true end)
    f.enterLive({ radar = false })
    f.hud()

    for _ = 1, 6 do
        f.step()
        t.isTrue(f.blipped()[FOE] == true,
            'a server that asked for permanent enemy blips lost them to a sweep')
    end

    -- Still no outline on them, though. That switch is a separate one and
    -- draws through walls; nothing here turns it on for the other side.
    t.isNil(f.outlines[1000 + FOE],
        'permanent enemy blips also outlined the enemies, which is a wallhack')
end)

t.test('and the match ending clears the sweep with everything else', function()
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()
    f.step()
    t.isTrue(f.blipCount() > 0, 'nothing was lit, so this proves nothing')

    f.fire('crimson_arena:client:exitArena', {})
    t.equals(f.blipCount(), 0, 'a sweep that was lit when the round ended stayed lit')
    t.equals(f.outlineCount(), 0)
end)

-- ======================================================================
-- SOMEBODY ELSE'S MATCH
--
-- The strongest form of "nobody outside sees it". Not a bystander in the
-- street -- another fighter, in another round, at the same coordinates, in
-- their own routing bucket. If any of this leaked, it would leak there
-- first: same event names, same natives, same loop, and a scoreboard
-- arriving on both clients at once.
-- ======================================================================

t.test('a fighter in ANOTHER match draws nothing of this one', function()
    local mine = newFixture()
    mine.enterLive()
    mine.hud()
    mine.step()

    local theirs = newFixture()
    theirs.enterLive({ matchId = 'match-2' })
    -- The other round's scoreboard arrives on their client too, because
    -- matchHud is delivered per match and this fixture can hand them one.
    -- What matters is whose it is.
    theirs.hud()
    theirs.step()

    -- Both are drawing their OWN roster; the point is that neither draws the
    -- other's ids in addition to it.
    t.isTrue(mine.blipCount() > 0, 'the first match drew nothing, so this proves nothing')
    t.equals(theirs.blipCount(), mine.blipCount(),
        'the second match drew a different number of blips to the first')
end)

t.test('and a scoreboard for a match this client is not in is not drawn', function()
    -- THE ACTUAL LEAK TO WORRY ABOUT. A client that draws whatever roster it
    -- is handed would put the other arena's fighters on the map the moment
    -- one message went to the wrong bucket. Nobody would report it -- they
    -- would just start winning.
    local f = newFixture()
    f.enterLive()

    -- Deliver a roster of ids this client shares no match with.
    f.hud(scoreboard({
        [7] = { team = 'crimson', alive = true },
        [8] = { team = 'ash', alive = true },
    }))
    f.step()

    local drawn = f.blipped()
    t.isNil(drawn[7], 'a fighter from another roster was blipped')
    t.isNil(drawn[8], 'a fighter from another roster was blipped')
end)

-- ======================================================================
-- NOTHING ACCUMULATES, AND NOTHING IS LEFT BEHIND
--
-- Every one of these outlives the round if it is missed. A blip nobody
-- removes stays on the map until the player reconnects; an outline nobody
-- removes follows a ped around the city.
-- ======================================================================

t.test('a hundred sweeps do not leave a hundred blips', function()
    -- The loop redraws every pass. A redraw that adds without removing looks
    -- perfectly correct for the first few seconds of a round.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()

    for _ = 1, 5 do f.step() end
    local settled = f.blipCount()
    t.isTrue(settled > 0, 'nothing was drawn at all')

    for _ = 1, 100 do f.step() end
    t.equals(f.blipCount(), settled,
        ('the blip count grew from %d to %d over a hundred passes'):format(settled, f.blipCount()))
end)

t.test('and a hundred passes do not leave a hundred outlines', function()
    local f = newFixture()
    f.enterLive()
    f.hud()

    for _ = 1, 5 do f.step() end
    local settled = f.outlineCount()
    t.isTrue(settled > 0, 'nobody was hazed at all')

    for _ = 1, 100 do f.step() end
    t.equals(f.outlineCount(), settled,
        ('the outline count grew from %d to %d'):format(settled, f.outlineCount()))
end)

t.test('a teammate who leaves the roster loses their blip and their haze', function()
    -- Somebody disconnecting mid-round is the ordinary case, and their dot
    -- staying on the map is the kind of thing that reads as a live player.
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()
    t.isTrue(f.blipped()[MATE] == true, 'the teammate was never blipped')

    -- The next scoreboard simply does not have them. Built by hand rather
    -- than by override: the override helper edits an existing row, so there
    -- is no value it takes that means "this player is gone".
    f.hud({
        { id = SELF, name = 'You',   alive = true, team = 'crimson' },
        { id = FOE,  name = 'Foe',   alive = true, team = 'ash' },
        { id = FOE2, name = 'Foe 2', alive = true, team = 'ash' },
    })
    f.step()

    t.isNil(f.blipped()[MATE], 'a teammate who left the round kept their blip')
    t.equals(f.outlineCount(), 0, 'a teammate who left the round kept their haze')
end)

t.test('stopping the resource takes every blip and outline with it', function()
    -- The one exit that does not go through the server, and the one an
    -- operator performs most often.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()
    for _ = 1, 5 do f.step() end
    t.isTrue(f.blipCount() > 0)

    f.fire('onResourceStop', 'crimson_arena')

    t.equals(f.blipCount(), 0, ('%d blips survived the resource stopping'):format(f.blipCount()))
    t.equals(f.outlineCount(), 0, ('%d outlines survived the resource stopping'):format(f.outlineCount()))
end)

t.test('and the round ending leaves neither behind, sweep lit or not', function()
    -- Both states, because the sweep is the one that has extra to clean up
    -- and "it worked when nothing was lit" is not the interesting case.
    for _, radar in ipairs({ false, true }) do
        local f = newFixture()
        f.enterLive({ radar = radar })
        f.hud()
        for _ = 1, 5 do f.step() end

        f.fire('crimson_arena:client:exitArena', {})

        t.equals(f.blipCount(), 0,
            ('radar=%s: %d blips left after the round'):format(tostring(radar), f.blipCount()))
        t.equals(f.outlineCount(), 0,
            ('radar=%s: %d outlines left after the round'):format(tostring(radar), f.outlineCount()))
    end
end)

-- ======================================================================
-- THE HAZE IS NEVER A WALLHACK
--
-- The outline draws THROUGH walls. On a teammate that is the point; on an
-- enemy it is an aimbot with a palette, and it would be invisible as a bug
-- to everyone except the person benefiting.
-- ======================================================================

t.test('no number of radar sweeps ever hazes an enemy', function()
    -- Once is a test. A hundred passes is the question actually worth
    -- asking, because the sweep toggles and the haze does not.
    local f = newFixture()
    f.enterLive({ radar = true })
    f.hud()

    local hazedFoe = false
    for _ = 1, 200 do
        f.step()
        for ped in pairs(f.outlines) do
            local id = ped - 1000
            if id == FOE or id == FOE2 then hazedFoe = true end
        end
    end

    t.isFalse(hazedFoe, 'an enemy was outlined during a radar sweep -- that draws through walls')
end)

t.test('and nobody at all is hazed in a free-for-all, however long it runs', function()
    -- No teams means no teammates means nothing to haze. The rule is not
    -- "haze fewer people", it is "there is nobody this applies to".
    local f = newFixture()
    f.enterLive({ modeKey = 'ffa', teamKey = nil, radar = true })
    f.hud(scoreboard({
        [MATE] = { team = nil, alive = true },
        [FOE] = { team = nil, alive = true },
    }))

    for _ = 1, 200 do
        f.step()
        t.equals(f.outlineCount(), 0, 'somebody was hazed in a free-for-all')
    end
end)

-- ======================================================================
-- ROSTERS AND ORDERS NOBODY CHOSE
--
-- Every case above uses a roster I wrote: four players, two a side, one of
-- them dead. The rule that matters -- an enemy is NEVER outlined, because
-- the outline draws through walls -- has to hold for rosters nobody wrote
-- and for event orders nobody designed.
--
-- Seeded, so a failure names a seed that reproduces it.
-- ======================================================================

--- A roster of `count` fighters with random teams and random alive flags.
--- @param count integer
--- @param selfTeam string
local function randomRoster(count, selfTeam)
    local teams = { 'crimson', 'ash' }
    local rows = { { id = SELF, name = 'You', alive = math.random() < 0.5, team = selfTeam } }
    for id = 2, count do
        rows[#rows + 1] = {
            id = id,
            name = ('Fighter %d'):format(id),
            alive = math.random() < 0.7,
            team = teams[math.random(2)],
        }
    end
    return rows
end

t.test('FUZZ: an enemy is never outlined, on any roster', function()
    -- THE WALLHACK INVARIANT. On a teammate the outline is the point; on an
    -- enemy it is an aimbot with a palette, and the only person who would
    -- ever notice is the one benefiting from it.
    local caught = nil

    for seed = 1, 200 do
        math.randomseed(seed + 4242)

        local f = newFixture()
        local selfTeam = (math.random() < 0.5) and 'crimson' or 'ash'
        f.enterLive({ teamKey = selfTeam, radar = math.random() < 0.5 })

        local rows = randomRoster(2 + math.random(6), selfTeam)
        f.hud(rows)

        -- Team lookup for the assertion, built from the same rows.
        local teamOf = {}
        for _, row in ipairs(rows) do teamOf[row.id] = row.team end

        for _ = 1, 20 do
            f.step()
            for ped in pairs(f.outlines) do
                local id = ped - 1000
                if id ~= SELF and teamOf[id] ~= selfTeam and not caught then
                    caught = ('seed %d: fighter %d (%s) outlined by a %s player')
                        :format(seed, id, tostring(teamOf[id]), selfTeam)
                end
            end
        end
    end

    t.isNil(caught, caught or '')
end)

t.test('FUZZ: and a dead player is never blipped or outlined', function()
    -- A dot on a corpse is a free read on where somebody died, and an
    -- outline on one is that plus a wall to see it through.
    local caught = nil

    for seed = 1, 200 do
        math.randomseed(seed + 8484)

        local f = newFixture()
        f.enterLive({ teamKey = 'crimson', radar = math.random() < 0.5 })

        local rows = randomRoster(2 + math.random(6), 'crimson')
        f.hud(rows)

        local aliveOf = {}
        for _, row in ipairs(rows) do aliveOf[row.id] = row.alive end

        for _ = 1, 20 do
            f.step()
            for id in pairs(f.blipped()) do
                if aliveOf[id] == false and not caught then
                    caught = ('seed %d: dead fighter %d was blipped'):format(seed, id)
                end
            end
            for ped in pairs(f.outlines) do
                local id = ped - 1000
                if aliveOf[id] == false and not caught then
                    caught = ('seed %d: dead fighter %d was outlined'):format(seed, id)
                end
            end
        end
    end

    t.isNil(caught, caught or '')
end)

t.test('FUZZ: no event order leaves a blip or an outline behind', function()
    -- Every one of these outlives the round if it is missed: a blip stays on
    -- the map until the player reconnects, an outline follows a ped around
    -- the city.
    local names = { 'enter', 'hud', 'step', 'exit', 'stop', 'otherStop' }
    local leaked = nil

    for seed = 1, 150 do
        math.randomseed(seed + 1717)

        local f = newFixture()
        local order = {}
        local menu = {
            enter = function() f.enterLive({ radar = math.random() < 0.5 }) end,
            hud = function() f.hud(randomRoster(2 + math.random(5), 'crimson')) end,
            step = function() f.step() end,
            exit = function() f.fire('crimson_arena:client:exitArena', {}) end,
            stop = function() f.fire('onResourceStop', 'crimson_arena') end,
            otherStop = function() f.fire('onResourceStop', 'other_resource') end,
        }

        for _ = 1, 8 do
            local pick = names[math.random(#names)]
            order[#order + 1] = pick
            menu[pick]()
        end

        menu.exit()

        if f.blipCount() ~= 0 and not leaked then
            leaked = ('seed %d after [%s] then exit: %d blips left')
                :format(seed, table.concat(order, ' '), f.blipCount())
        end
        if f.outlineCount() ~= 0 and not leaked then
            leaked = ('seed %d after [%s] then exit: %d outlines left')
                :format(seed, table.concat(order, ' '), f.outlineCount())
        end
    end

    t.isNil(leaked, leaked or '')
end)

t.test('FUZZ: and a client in no match draws nothing, whatever it is sent', function()
    -- The whole "nobody outside the arena sees it" claim, against rosters
    -- and orders nobody picked. A client that never entered has no loop to
    -- run, so nothing it is handed should ever reach the map.
    local drew = nil

    for seed = 1, 150 do
        math.randomseed(seed + 3131)

        local f = newFixture()
        for _ = 1, 6 do
            f.hud(randomRoster(2 + math.random(6), 'crimson'))
            f.step()
        end

        if (f.blipCount() ~= 0 or f.outlineCount() ~= 0) and not drew then
            drew = ('seed %d: a client in no match drew %d blips and %d outlines')
                :format(seed, f.blipCount(), f.outlineCount())
        end
    end

    t.isNil(drew, drew or '')
end)


-- ========================================================================
-- THE OUTLINE HAS TO DRAW THROUGH THE WALL
--
-- REPORTED FROM LIVE TESTING, in a team deathmatch: no haze on a teammate
-- at all.
--
-- Every test above proves the right PEDS are outlined -- a teammate is, an
-- enemy is not, a corpse is not, and nothing is left behind. None of them
-- could see that the outline was being drawn with the DEFAULT shader,
-- which is occluded by anything in front of it and faint even in the open.
-- The note over refreshOutlines says the outline draws through geometry
-- and that this is the whole point of it; nothing switched that on.
-- ========================================================================

t.test('the see-through shader is selected, not the default one', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    f.step()

    t.isTrue(f.outlines[1000 + MATE] == true, 'the teammate was not outlined at all')
    t.equals(f.outlineShader, 1,
        'the outline is drawn with the default shader, so a teammate behind cover shows nothing')
end)

-- ========================================================================
-- AND HELD AGAINST EVERY OTHER RESOURCE ON THE BOX
--
-- REPORTED FROM THE GAME, twice: "Also team player haze not working", and
-- then "I want the team haze to work" after the shader above was already
-- in. The colour and the shader are not properties of the ped -- they are
-- ONE setting for the whole game. Setting them once per reconciliation is
-- correct only if nothing else ever sets them, and a live server runs
-- several scripts that set them EVERY FRAME: a target script highlighting
-- what you look at, a job script marking a delivery. Between two of our
-- refreshes they win every frame, and the teammate outline draws in their
-- colour on the default shader -- which is occluded by everything in front
-- of it. That is indistinguishable, in the game, from the haze not working.
--
-- So both are re-asserted every frame. What follows is how a spec can see
-- that: a thread that has never slept is a per-frame thread, and its clock
-- stays at zero while the blip loop's climbs by BLIP_REFRESH_MS a pass.
-- ========================================================================

--- Calls made by a loop that has never waited -- i.e. one running per frame.
local function perFrame(calls)
    local count = 0
    for _, call in ipairs(calls) do
        if call.clock == 0 then count = count + 1 end
    end
    return count
end

t.test('the colour is re-asserted every frame, not once a refresh', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    for _ = 1, 8 do f.step() end

    -- The blip loop's first pass is at clock 0 as well, so one such call is
    -- not evidence of anything. Eight frames of holding is.
    t.isTrue(perFrame(f.colorCalls) >= 8,
        ('the outline colour was set %d time(s) by a per-frame loop over 8 frames -- '
            .. 'any resource that sets it every frame owns it in between')
            :format(perFrame(f.colorCalls)))
end)

t.test('and so is the shader, which is the half that hides behind walls', function()
    local f = newFixture()
    f.enterLive()
    f.hud()
    for _ = 1, 8 do f.step() end

    t.isTrue(perFrame(f.shaderCalls) >= 8,
        ('the see-through shader was selected %d time(s) by a per-frame loop over 8 frames')
            :format(perFrame(f.shaderCalls)))
end)

t.test('and the hold stops when there is nothing outlined', function()
    -- IT MUST NOT BECOME A RESOURCE THAT STOMPS EVERYBODY ELSE. The
    -- complaint this fixes is exactly that behaviour from someone else's
    -- script; holding a colour for an outline we are not drawing would make
    -- this resource the offender for every other one on the server.
    local f = newFixture()
    f.enterLive({ modeKey = 'ffa', teamKey = nil })
    f.hud()
    for _ = 1, 8 do f.step() end

    t.equals(f.outlineCount(), 0, 'a free-for-all outlined somebody')
    t.equals(perFrame(f.colorCalls), 0,
        'the outline colour was held for the whole server with nothing of ours outlined')
    t.equals(perFrame(f.shaderCalls), 0,
        'the outline shader was held for the whole server with nothing of ours outlined')
end)

t.test('and it lets go when the match ends', function()
    -- The same rule at the other end: a match that is over draws no
    -- outline, so it has no business holding the setting.
    local f = newFixture()
    f.enterLive()
    f.hud()
    for _ = 1, 4 do f.step() end
    t.isTrue(perFrame(f.colorCalls) > 0, 'the hold never started, so this proves nothing')

    f.fire('crimson_arena:client:exitArena', {})
    local held = perFrame(f.colorCalls)
    for _ = 1, 8 do f.step() end

    t.equals(perFrame(f.colorCalls), held,
        'the outline colour was still being held every frame after the match ended')
end)

os.exit(t.summary())
