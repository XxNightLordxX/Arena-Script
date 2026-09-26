--[[
    crimson_arena/tests/buildnotes_spec.lua

    THE NUMBERS IN THE BUILD'S OWN NOTES, MEASURED.

    Two notes in client/match.lua's build section steer what the next person
    to touch it does, and both carried a number that was not true:

      - "The build does up to four hundred CreateObjects." On a client
        without the stunt blocks the floor is tiled from shipping
        containers, and since the arena grows with the roster that is 369
        pieces at the smallest size and 1,127 at the largest on the test
        world's container (375 and 1,149 on config.lua's). Somebody
        weighing the one-frame build against a freeze was reading a third
        of the real worst case.

      - "The rim `maxTiles` trims ..." -- read as a fact about the shipped
        arena, it says the cap cuts the container floor at some roster
        size. It never does: the cap grows with the square of the size
        factor exactly as the floor does, and the container floor stays
        under it at every size there is.

    The first half of this file measures those facts on the test world --
    the same world, and the same approximations of the props, that the
    notes' other numbers (291 tiles, a hole at 43m and at 39m) were taken
    from -- AND again on the container size config.lua itself describes
    (12.19m by 2.44m), because an exact count is only true of the prop it
    was counted on, and the note says which is which. The second half
    holds the notes to what was measured, number by number and each with
    the words it belongs to: change the config so a number moves, swap two
    of them, or turn a "smallest" into a "largest", and this says which
    note is now wrong.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
local World = dofile('fixtures/world.lua')

print('buildnotes_spec')

local env = Sandbox.newArenaEnv()
local Arena = env.Arena

local CONTAINER = World.DEFAULT_MODELS['prop_container_01a']

--- THE CONTAINER AS config.lua DESCRIBES IT: "a container is 12.19m long"
--- (the wall's note) and "2.44m across" (the platform radius's). The test
--- world's stand-in is a little bigger; the note gives the counts for both.
local CONFIG_CONTAINER = { x = 12.19, y = 2.44, top = CONTAINER.top }

--- Every distinct size the arena can be built at, smallest first, with the
--- smallest roster that reaches each.
local function sizes()
    local out, seen = {}, {}
    for players = 1, 200 do
        local factor = Arena.SizeFactor('skydome', players)
        if not seen[factor] then
            seen[factor] = true
            out[#out + 1] = { players = players, factor = factor }
        end
    end
    table.sort(out, function(a, b) return a.factor < b.factor end)
    return out
end

--- The container floor at one size: tiles before the cap, the cap, and
--- tiles kept.
--- @param container table|nil -- { x, y }; the test world's by default
local function containerFloor(factor, container)
    container = container or CONTAINER
    local platform = Arena.GetPlatform('skydome', factor)
    local area = Arena.GetSpawnArea('skydome', factor)
    local uncapped = {}
    for k, v in pairs(platform) do uncapped[k] = v end
    uncapped.maxTiles = 0
    return #Arena.PlatformTiles(uncapped, area.x, area.y, container), platform.maxTiles,
           #Arena.PlatformTiles(platform, area.x, area.y, container)
end

--- How many objects the real client creates entering the skydome at a size,
--- on a build with or without the stunt blocks, with the containers the
--- test world's size or `container`'s.
local function built(factor, withStunt, container)
    local models = {}
    for name, size in pairs(World.DEFAULT_MODELS) do models[name] = size end
    if container then
        models['prop_container_01a'] = container
        models['prop_container_01b'] = container
    end
    if not withStunt then
        for _, name in ipairs({ 'stt_prop_stunt_bblock_huge_01', 'bkr_prop_biker_bblock_huge_01',
                                'imp_prop_impexp_bblock_huge_01', 'ar_prop_ar_bblock_huge_01' }) do
            models[name] = nil
        end
    end
    local world = World.new({ models = models, streamRange = 100000.0 })
    local runner = Sandbox.newThreadRunner()
    local handlers = {}
    local overrides = {
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return 200 end,
        GetPedArmour = function() return 0 end,
        GetSelectedPedWeapon = function() return 'WEAPON_UNARMED' end,
        HasPedGotWeapon = function() return false end,
        GetAmmoInPedWeapon = function() return 0 end,
        NetworkResurrectLocalPlayer = function() end, ClearPedBloodDamage = function() end,
        GiveWeaponToPed = function() end, SetPedAmmo = function() end, SetPedArmour = function() end,
        SetEntityHealth = function() end, SetCurrentPedWeapon = function() end,
        GiveWeaponComponentToPed = function() end, SetPedWeaponTintIndex = function() end,
        RemoveAllPedWeapons = function() end, RemoveWeaponFromPed = function() end,
        DisableControlAction = function() end, DisablePlayerFiring = function() end,
        IsPauseMenuActive = function() return false end, SetFrontendActive = function() end,
        GetPedSourceOfDeath = function() return 900 end, IsEntityAPed = function() return true end,
        IsPedAPlayer = function() return true end, NetworkGetPlayerIndexFromPed = function() return 5 end,
        GetPlayerServerId = function() return 7 end, PlayerId = function() return 0 end,
        GetPlayerFromServerId = function(serverId) return serverId end,
        NetworkIsPlayerActive = function() return true end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        AddBlipForEntity = function(ped) return 6000 + (ped or 0) end,
        SetBlipSprite = function() end, SetBlipColour = function() end, SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end, EndTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end, SetBlipDisplay = function() end,
        DoesBlipExist = function() return true end, RemoveBlip = function() end,
        SetEntityDrawOutline = function() end, SetEntityDrawOutlineShader = function() end,
        SetEntityDrawOutlineColor = function() end, SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end, ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end, SetLocalPlayerVisibleLocally = function() end,
        TaskStartScenarioInPlace = function() end, SetBlockingOfNonTemporaryEvents = function() end,
        SetPedCanRagdoll = function() end,
        print = function() end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end },
        ArenaDispatch = { Enter = function() end, Exit = function() end,
                          ClearDeadState = function() return true end, ReleaseDeadState = function() end },
    }
    for name, fn in pairs(world.natives) do overrides[name] = fn end
    overrides.GetGameTimer = function() return runner.elapsed end
    local created = 0
    overrides.CreateObject = function(...)
        created = created + 1
        return world.natives.CreateObject(...)
    end
    local clientEnv = Sandbox.newArenaEnv(overrides)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', clientEnv)

    local arena = clientEnv.Config.Arenas['skydome']
    local spawn = clientEnv.Arena.PickSpawn('skydome', nil, 1)
    local thread = coroutine.create(function()
        handlers['crimson_arena:client:enterArena']({
            matchId = 'match-1', arenaKey = 'skydome', modeKey = 'ffa',
            spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w or 0.0 },
            scatterRadius = 0.0, radar = false, loadout = { weapons = {} }, sizeFactor = factor,
            boundary = { enabled = true, center = arena.boundary.center,
                         radius = arena.boundary.radius * factor,
                         warningSeconds = 5, damagePerTick = 20, tickMs = 500 },
            freezeSeconds = 0,
        })
    end)
    for _ = 1, 400 do
        if coroutine.status(thread) == 'dead' then break end
        assert(coroutine.resume(thread))
    end
    assert(coroutine.status(thread) == 'dead', 'the entry never finished')
    return created, #world.live()
end

--- 1127 -> '1,127'
local function grouped(n)
    local text = tostring(n)
    while true do
        local done
        text, done = text:gsub('^(%d+)(%d%d%d)', '%1,%2')
        if done == 0 then return text end
    end
end

-- ======================================================================
-- THE FACTS, MEASURED
-- ======================================================================

local SIZES = sizes()
local SMALLEST, LARGEST = SIZES[1], SIZES[#SIZES]

t.test('the arena really does grow, and stops growing', function()
    t.equals(SMALLEST.factor, 1.0)
    t.isTrue(LARGEST.factor > 1.5, 'the arena barely grows, so nothing below measures growth')
    t.isTrue(#SIZES > 5, 'only a handful of sizes: ' .. #SIZES)
end)

--- The two containers every count below is taken on, named as the note
--- names them.
local CONTAINERS = {
    { name = 'the test world\'s', size = CONTAINER },
    { name = 'config.lua\'s', size = CONFIG_CONTAINER },
}

t.test('the shipped maxTiles never trims the container floor, at any roster size', function()
    for _, container in ipairs(CONTAINERS) do
        for _, size in ipairs(SIZES) do
            local uncapped, cap, kept = containerFloor(size.factor, container.size)
            t.isTrue(cap > 0, 'the cap is off, so this proves nothing')
            t.isTrue(uncapped <= cap,
                ('%s container, %d players (factor %.3f): the floor is %d tiles and the cap %d -- the cap TRIMS here')
                    :format(container.name, size.players, size.factor, uncapped, cap))
            t.equals(kept, uncapped)
            -- "It grows with the square of the size factor."
            t.equals(cap, math.floor(400 * size.factor * size.factor),
                ('factor %.3f: the cap does not grow with the square of the size'):format(size.factor))
        end
    end
end)

--- Which size the floor comes closest to the cap at.
local function closestAt(container)
    local closest, at = -1, nil
    for _, size in ipairs(SIZES) do
        local uncapped, cap = containerFloor(size.factor, container)
        if uncapped / cap > closest then closest, at = uncapped / cap, size end
    end
    return at
end

t.test('and it comes closest at the smallest size, where the floor is 291 of 400 -- 297 on config.lua\'s container', function()
    for _, case in ipairs({ { CONTAINER, 291, 1049 }, { CONFIG_CONTAINER, 297, 1071 } }) do
        t.equals(closestAt(case[1]).factor, SMALLEST.factor,
            'the floor comes closest to the cap at a size other than the smallest')
        local uncapped, cap = containerFloor(SMALLEST.factor, case[1])
        t.equals(uncapped, case[2])
        t.equals(cap, 400)
        uncapped, cap = containerFloor(LARGEST.factor, case[1])
        t.equals(uncapped, case[3])
        t.equals(cap, 1600)
    end
end)

--- Where a floor capped at `cap` tiles first leaves a hole, walking out
--- from the middle a tenth of a metre and a degree at a time.
local function holeAt(cap)
    local platform = Arena.GetPlatform('skydome', 1.0)
    local area = Arena.GetSpawnArea('skydome', 1.0)
    local capped = {}
    for k, v in pairs(platform) do capped[k] = v end
    capped.maxTiles = cap
    local tiles = Arena.PlatformTiles(capped, area.x, area.y, CONTAINER)
    local function covered(x, y)
        for _, tile in ipairs(tiles) do
            if math.abs(x - tile.x) <= CONTAINER.x * 0.5 and math.abs(y - tile.y) <= CONTAINER.y * 0.5 then
                return true
            end
        end
        return false
    end
    for tenths = 0, 500 do
        local r = tenths / 10
        for degrees = 0, 359 do
            if not covered(area.x + r * math.cos(math.rad(degrees)), area.y + r * math.sin(math.rad(degrees))) then
                return r
            end
        end
    end
    return nil
end

--- The wall's radius, from the config: its first piece stands on it.
local WALL = env.Config.Arenas['skydome'].cover.pieces[1].x

t.test('lowering the cap is what opens a hole inside the wall, at 43m for 250 and 39m for 200', function()
    -- The numbers the note already quotes, measured on the same world.
    t.equals(WALL, 44.5, 'the wall has moved; the note\'s 44.5m is now wrong')
    for _, case in ipairs({ { 250, 43.0 }, { 200, 38.8 } }) do
        local hole = holeAt(case[1])
        t.equals(hole, case[2], ('a cap of %d'):format(case[1]))
        t.isTrue(hole < WALL, 'the hole is not inside the wall')
    end
end)

t.test('the real build creates 369 objects at the smallest size without the stunt blocks, and 1,127 at the largest', function()
    local small = built(SMALLEST.factor, false)
    local large = built(LARGEST.factor, false)
    t.equals(small, 369)
    t.equals(large, 1127)
    -- With the stunt blocks the same arena is a handful of floor pieces and
    -- its cover, at every size.
    t.equals(built(SMALLEST.factor, true), 87)
    t.equals(built(LARGEST.factor, true), 103)
end)

t.test('and 375 and 1,149 on the container config.lua describes', function()
    t.equals(built(SMALLEST.factor, false, CONFIG_CONTAINER), 375)
    t.equals(built(LARGEST.factor, false, CONFIG_CONTAINER), 1149)
end)

-- ======================================================================
-- THE NOTES, HELD TO THE FACTS
-- ======================================================================

local function read(path)
    local handle = assert(io.open(path, 'r'))
    local text = handle:read('a')
    handle:close()
    return text
end

local LINES = {}
for line in (read('../Crimson-Arena/client/match.lua') .. '\n'):gmatch('([^\n]*)\n') do LINES[#LINES + 1] = line end

--- Comment prose, from the line holding `first` until `stop(line)` says
--- so, joined into one string with the comment markers and the wrapping
--- taken out.
local function prose(first, stop)
    for i, line in ipairs(LINES) do
        if line:find(first, 1, true) then
            local words = {}
            for j = i, #LINES do
                local text = LINES[j]:match('^%s*%-%-%s?(.*)$')
                if not text or (j > i and stop(text)) then break end
                words[#words + 1] = text
            end
            return (table.concat(words, ' '):gsub('%s+', ' '))
        end
    end
    return nil
end

--- The whole NO YIELD note: every comment line from its heading to the
--- code below it.
local function buildNote()
    return prose('-- NO YIELD IN THIS LOOP', function() return false end)
end

--- One paragraph of it: from its first words to the next blank comment
--- line.
local function paragraph(first)
    return prose(first, function(text) return text:match('^%s*$') ~= nil end)
end

--- 1127 -> '1,127', 12.2 -> '12.2'
local function metres(n) return ('%g'):format(n) end

--- Requires `phrase` word for word in `text`.
local function says(text, phrase, why)
    t.isTrue(text ~= nil and text:find(phrase, 1, true) ~= nil,
        ('%s -- the note should say: "%s"'):format(why, phrase))
end

t.test('the build note says how many objects the build really creates, and on which container', function()
    local note = buildNote()
    t.isTrue(note ~= nil, 'the NO YIELD note is gone')
    local fixture = { built(SMALLEST.factor, false), built(LARGEST.factor, false) }
    local config = { built(SMALLEST.factor, false, CONFIG_CONTAINER), built(LARGEST.factor, false, CONFIG_CONTAINER) }
    t.isTrue(fixture[2] > 1000 and config[2] > 1000, 'the worst case is no longer over a thousand')
    says(note, 'The build does over a thousand CreateObjects at its worst', 'the worst case is wrong')
    says(note, ('%s pieces at the smallest size and %s once the roster has grown the arena as far as it goes '
        .. 'on the test world\'s %sm by %sm container'):format(grouped(fixture[1]), grouped(fixture[2]),
            metres(CONTAINER.x), metres(CONTAINER.y)), 'the counts, or the sizes they belong to, are wrong')
    says(note, ('or %s and %s on the %sm by %sm one config.lua describes'):format(grouped(config[1]),
        grouped(config[2]), metres(CONFIG_CONTAINER.x), metres(CONFIG_CONTAINER.y)),
        'the counts on config.lua\'s container are wrong')
    -- What the note used to say, and the ways of saying it again.
    for _, stale in ipairs({ 'up to four hundred', 'under a thousand' }) do
        t.isTrue(note:find(stale, 1, true) == nil, ('the note says "%s"'):format(stale))
    end
    t.isTrue(note:find('up to %d') == nil and note:find('up to %a+ hundred') == nil,
        'the note gives the build an "up to" count again')
end)

t.test('and it says the shipped cap never trims, with the numbers either end and which end is closest', function()
    local note = buildNote()
    local para = paragraph('AND THE SHIPPED CAP NEVER TRIMS AT ALL')
    t.isTrue(para ~= nil, 'the note does not say the shipped cap never trims')
    t.isTrue(note:find(para, 1, true) ~= nil, 'the NEVER TRIMS paragraph is no longer part of the NO YIELD note')
    says(para, 'AND THE SHIPPED CAP NEVER TRIMS AT ALL, at any roster size', 'the claim is gone or hedged')
    says(para, 'It grows with the square of the size factor', 'the reason is gone')
    local s1, c1 = containerFloor(SMALLEST.factor)
    local s2, c2 = containerFloor(LARGEST.factor)
    local closest = closestAt(CONTAINER) == SMALLEST and 'smallest' or 'largest'
    says(para, ('from the smallest arena (%s of %s) to the largest (%s of %s), and it is closest at the %s')
        :format(grouped(s1), grouped(c1), grouped(s2), grouped(c2), closest), 'the ends are wrong')
    local r1, d1 = containerFloor(SMALLEST.factor, CONFIG_CONTAINER)
    local r2, d2 = containerFloor(LARGEST.factor, CONFIG_CONTAINER)
    says(para, ('on config.lua\'s %sm by %sm one the floor is %s of %s and %s of %s, still under')
        :format(metres(CONFIG_CONTAINER.x), metres(CONFIG_CONTAINER.y), grouped(r1), grouped(d1),
            grouped(r2), grouped(d2)), 'the ends on config.lua\'s container are wrong')
    says(para, ('are the test world\'s %sm by %sm container'):format(metres(CONTAINER.x), metres(CONTAINER.y)),
        'the note does not say which container its counts are')
    -- NEVER, and nothing after it that takes it back.
    t.isTrue(para:find('trims', 1, true) == nil, 'the paragraph goes on to say the cap trims somewhere')
    for _, hedge in ipairs({ 'except', 'Except', 'unless', 'Unless', 'but at', 'only at', 'RARELY', 'SELDOM' }) do
        t.isTrue(para:find(hedge, 1, true) == nil, ('the paragraph hedges its NEVER: "%s"'):format(hedge))
    end
    -- The rim is what a LOWERED cap would trim; the shipped one trims none.
    t.isTrue(note:find('The rim `maxTiles` trims', 1, true) == nil,
        'the note still speaks of a rim the shipped cap trims')
    says(note, 'The rim a LOWERED `maxTiles` would trim', 'the rim sentence no longer says the cap is lowered')
end)

t.test('and the warning against lowering the cap gives the tiles and the holes as measured', function()
    local para = paragraph('AND DO NOT REACH FOR `maxTiles`')
    t.isTrue(para ~= nil, 'the maxTiles warning is gone')
    t.isTrue(buildNote():find(para, 1, true) ~= nil, 'the maxTiles warning is no longer part of the NO YIELD note')
    local tiles = containerFloor(SMALLEST.factor)
    says(para, ('needs all %d of its container tiles to reach the wall'):format(tiles), 'the tile count is wrong')
    says(para, ('Trimming to 250 opens a hole in the floor at %.0fm, and 200 opens one at %.0fm')
        :format(holeAt(250), holeAt(200)), 'a hole is in the wrong place')
    says(para, ('INSIDE a wall at %sm'):format(metres(WALL)), 'the wall is in the wrong place')
end)

os.exit(t.summary())
