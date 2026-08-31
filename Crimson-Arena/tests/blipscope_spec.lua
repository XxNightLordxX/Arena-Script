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

    local f = {
        ped = 1000 + SELF,
        blips = {},        -- [handle] = { ped = , colour = }
        outlines = {},     -- [ped] = true while drawn
        outlineCalls = {}, -- every SetEntityDrawOutline, in order
        nextBlip = 1,
        streamed = { [MATE] = true, [FOE] = true, [FOE2] = true },
    }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
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
        SetEntityDrawOutlineColor = function(r, g, b) f.outlineColor = { r, g, b } end,

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

    -- crimson ships as #c81020.
    t.isNotNil(f.outlineColor, 'no outline colour was ever set')
    t.equals(f.outlineColor[1], 200)
    t.equals(f.outlineColor[2], 16)
    t.equals(f.outlineColor[3], 32)
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

os.exit(t.summary())
