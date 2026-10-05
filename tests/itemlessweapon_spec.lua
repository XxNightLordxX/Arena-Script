-- Crimson Arena: the gun that walked out of the arena with no item behind it.

--[[
    tests/itemlessweapon_spec.lua

    THE OWNER'S REPORT, WORD FOR WORD: "sometimes when you leave arena you
    still have a gun you can use until you refreshSkin, it was the carbine or
    any weapon from this zip no weapon comes out with it".

    Traced through ox_inventory's own client source (CommunityOx main and the
    overextended original, which agree), two ways the arena let it happen:

      1. THE DRAW THAT LANDS AFTER THE DOOR. ox plays the draw -- a 1200 ms
         Wait for every firearm -- BEFORE it puts the gun in the ped's hands,
         with its current weapon nil the whole time. The round ends inside
         that window, the door takes the kit back, ox is told the slot is
         empty and has nothing drawn to holster, and leaveArena's strip finds
         empty hands. Then the draw finishes: ox hands the ped the gun,
         records it as drawn, and never checks the slot again. Only a new ped
         -- refreshskin -- makes ox let go.

      2. THE ARENA'S OWN NATIVE GIVE. restoreOwnLoadout handed back every
         weapon the capture had seen with GiveWeaponToPed. On an ox server
         the ITEM is the weapon and the door returns it, so a native give can
         only ever add a second, item-less copy -- and one handed back here
         is captured again at the next entry, so it rides every exit after.

    crimson-backweapons is in neither chain: it draws props on backs and
    never gives, takes or selects a ped weapon. It is not loaded here because
    nothing it does can change what these tests read.

    THE FAKE ox_inventory below models exactly what the arena relies on and
    nothing more: getCurrentWeapon and GetPlayerItems answer COPIES (exports
    cross a resource boundary), and the 'ox_inventory:disarm' event clears
    the drawn weapon and every ped weapon, as ox's Weapon.Disarm does.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('itemlessweapon_spec')

local UNARMED = 'WEAPON_UNARMED'

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = copy(inner) end
    return out
end

--- A JSON reader for exactly what ox's ignore list is: an array of quoted
--- names or bare numbers. 'BAD' raises, which is what json.decode does with
--- text it cannot read.
local fakeJson = {
    decode = function(text)
        if text == 'BAD' then error('unexpected character', 0) end
        local out = {}
        for token in tostring(text):gmatch('[^%[%],%s]+') do
            local name = token:match('^"(.*)"$')
            out[#out + 1] = name or tonumber(token)
        end
        return out
    end,
}

--- @param opts table|nil { ox = 'started'|'missing', ignore = string, mutate = fn(Config),
---     deafOx = true -- an ox build that does not answer 'ox_inventory:disarm' }
local function newClient(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local world = {
        clock = 100000,
        oxState = opts.ox or 'started',
        ignore = opts.ignore or '[]',
        exportsTouched = false,
        events = {},
        serverEvents = {},
        printed = {},
        objects = {},
        deleted = {},
        inHand = {},
        attachChecks = 0,
    }
    local ox = { current = nil, items = {}, throw = false }
    local ped = { weapons = {}, selected = UNARMED, given = {}, removed = {}, selections = {}, wipes = 0 }

    local oxExports = {
        getCurrentWeapon = function(_self)
            if ox.throw then error('No such export getCurrentWeapon in resource ox_inventory', 0) end
            return copy(ox.current)
        end,
        GetItemCount = function(_self, name)
            if ox.throw then error('No such export GetItemCount in resource ox_inventory', 0) end
            local n = 0
            for _, it in pairs(ox.items) do if it.name == name then n = n + (it.count or 1) end end
            return n
        end,
        GetPlayerItems = function(_self)
            if ox.throw then error('No such export GetPlayerItems in resource ox_inventory', 0) end
            return copy(ox.items)
        end,
        -- ox's useSlot for a weapon: the slot already drawn is HOLSTERED,
        -- any other is drawn. `deafDraw` models a draw ox refuses.
        useSlot = function(_self, slot, noAnim)
            ox.used = ox.used or {}
            ox.used[#ox.used + 1] = { slot = slot, noAnim = noAnim }
            if ox.deafDraw then return end
            local it = ox.items[slot]
            if not it then return end
            if ox.current and ox.current.slot == slot then
                ox.current = nil; ped.selected = UNARMED; return
            end
            ox.current = { slot = slot, name = it.name, hash = it.name, timer = 0, metadata = it.metadata }
            ped.weapons[it.name] = 30
            ped.selected = it.name
        end,
    }

    local exportsTable
    if world.oxState == 'started' then
        exportsTable = setmetatable({ ox_inventory = oxExports }, { __call = function() end })
    else
        -- WITHOUT ox, READING THE EXPORT TABLE AT ALL IS A FINDING. It is
        -- recorded rather than raised, because the watch reads it inside a
        -- pcall that would swallow a raise and hide the very thing asked.
        exportsTable = setmetatable({}, {
            __index = function() world.exportsTouched = true; return nil end,
            __call = function() end,
        })
    end

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread, Wait = runner.Wait, SetTimeout = runner.SetTimeout,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn)
            if name == 'onResourceStop' then
                world.stops = world.stops or {}
                world.stops[#world.stops + 1] = fn
            else
                handlers[name] = fn
            end
        end,
        RegisterCommand = function() end,
        TriggerServerEvent = function(name, payload)
            world.serverEvents[#world.serverEvents + 1] = { name = name, payload = payload }
        end,
        TriggerEvent = function(name, ...)
            world.events[#world.events + 1] = { name = name, args = { ... } }
            if name == 'ox_inventory:disarm' and world.raiseOnDisarm then
                world.raiseOnDisarm = false
                error('a handler somewhere raised', 0)
            end
            if name == 'ox_inventory:disarm' and not opts.deafOx then
                -- ox's Weapon.Disarm: nothing drawn, nothing on the ped.
                ox.current = nil
                ped.weapons = {}
                ped.selected = UNARMED
            end
        end,
        exports = exportsTable,
        GetConvar = function(name, default)
            if name == 'inventory:ignoreweapons' then return world.ignore end
            return default
        end,
        json = fakeJson,
        print = function(line) world.printed[#world.printed + 1] = tostring(line) end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name)
            if name == 'ox_inventory' then return world.oxState end
            return 'missing'
        end,
        PlayerPedId = function() return 11 end,
        PlayerId = function() return 1 end,
        GetEntityCoords = function() return { x = 2344.0, y = 2565.0, z = 46.7 } end,
        SetEntityCoordsNoOffset = function() end,
        GetGroundZFor_3dCoord = function() return true, 46.0 end,
        IsEntityDead = function() return false end,
        GetEntityHealth = function() return world.health or 200 end,
        GetEntityMaxHealth = function() return 200 end,
        SetEntityHealth = function(_p, value) world.healthSet = value end,
        GetPedArmour = function() return world.armour or 0 end,
        SetPedArmour = function(_p, value) world.armourSet = value end,

        -- THE PED'S WEAPONS, AS STATE. A stub answering false to everything
        -- is how every client fixture in this suite has always run, and it
        -- is exactly why none of them could see a gun left on the ped.
        HasPedGotWeapon = function(_p, hash) return ped.weapons[hash] ~= nil end,
        GetAmmoInPedWeapon = function(_p, hash) return ped.weapons[hash] or 0 end,
        GetSelectedPedWeapon = function() return ped.selected end,
        SetCurrentPedWeapon = function(_p, hash)
            ped.selections[#ped.selections + 1] = hash
            ped.selected = hash
        end,
        GiveWeaponToPed = function(_p, hash, ammo)
            ped.given[#ped.given + 1] = { hash = hash, ammo = ammo }
            ped.weapons[hash] = (ped.weapons[hash] or 0) + (tonumber(ammo) or 0)
        end,
        SetPedAmmo = function(_p, hash, ammo)
            if ped.weapons[hash] ~= nil then ped.weapons[hash] = ammo end
        end,
        RemoveWeaponFromPed = function(_p, hash)
            ped.removed[#ped.removed + 1] = hash
            ped.weapons[hash] = nil
            if ped.selected == hash then ped.selected = UNARMED end
        end,
        RemoveAllPedWeapons = function()
            ped.wipes = ped.wipes + 1
            ped.weapons = {}
            ped.selected = UNARMED
        end,

        ClearPedBloodDamage = function() end,
        NetworkResurrectLocalPlayer = function() end,
        FreezeEntityPosition = function() end,
        SetEntityVisible = function() end,
        SetEntityCollision = function() end,
        SetEntityInvincible = function(_p, on) world.invincible = on; world.invincibleWrites = (world.invincibleWrites or 0) + 1 end,
        SetPlayerInvincible = function() end,
        GetPlayerInvincible = function() return false end,
        IsPedShooting = function() return world.shooting == true end,
        IsPedPerformingMeleeAction = function() return world.melee == true end,
        IsPedInMeleeCombat = function() return world.beingMeleed == true end,
        IsControlJustPressed = function(_g, control) return world.pressed == control end,
        IsDisabledControlJustPressed = function(_g, control) return world.disabledPressed == control end,
        SetEntityHeading = function() end,
        RequestCollisionAtCoord = function() end,
        HasCollisionLoadedAroundEntity = function() return true end,
        GetGameTimer = function() return world.clock end,
        joaat = function(name) return name end,
        lib = { notify = function() end },
        ArenaUI = { UpdateHud = function() end, Countdown = function() end },
        GetPlayerTeam = function() return -1 end,
        SetPlayerTeam = function() end,
        NetworkSetFriendlyFireOption = function() end,
        SetCanAttackFriendly = function() end,
        IsEntityVisible = function() return true end,
        GetEntityCollisionDisabled = function() return false end,
        IsEntityPositionFrozen = function() return false end,
        ArenaSpectate = { IsActive = function() return false end, Stop = function() end },
        GetEntityHeading = function() return 0.0 end,
        ClearOverrideWeather = function() end,
        NetworkClearClockTimeOverride = function() end,
        SetWeatherTypeNowPersist = function() end,
        NetworkOverrideClockTime = function() end,
        RemoveBlip = function() end,
        -- THE WORLD'S OBJECTS, for the back prop sweep: [handle] = { model,
        -- attachedTo, networked, owner }. Peds are always there.
        DoesEntityExist = function(h)
            if world.objects[h] then return true end
            return h == 11 or h == world.oldPed
        end,
        GetGamePool = function(pool)
            local out = {}
            if pool == 'CObject' then for h in pairs(world.objects) do out[#out + 1] = h end end
            table.sort(out)
            return out
        end,
        GetEntityModel = function(h) return world.objects[h] and world.objects[h].model or 0 end,
        IsEntityAttachedToEntity = function(h, to)
            world.attachChecks = world.attachChecks + 1
            return world.objects[h] ~= nil and world.objects[h].attachedTo == to
        end,
        GetCurrentPedWeaponEntityIndex = function(p) return world.inHand[p] or 0 end,
        GetWeapontypeModel = function(hash) return 'w_' .. tostring(hash) end,
        NetworkGetEntityIsNetworked = function(h) return world.objects[h] ~= nil and world.objects[h].networked == true end,
        NetworkGetEntityOwner = function(h) return world.objects[h] and world.objects[h].owner or 1 end,
        NetworkRequestControlOfEntity = function() end,
        SetEntityAsMissionEntity = function() end,
        DetachEntity = function() end,
        DeleteEntity = function(h)
            if world.objects[h] then
                world.objects[h] = nil
                world.deleted[#world.deleted + 1] = h
            end
        end,
        DeleteObject = function(h) world.objects[h] = nil end,
        SetEntityDrawOutline = function() end,
        ResetEntityDrawOutlineRenderTechnique = function() end,
        -- What the round's own per-frame loops call while a test stands in a
        -- live match. Answered plainly: nothing here is about them.
        DisableControlAction = function() end,
        IsPauseMenuActive = function() return false end,
        GetPlayerServerId = function() return 1 end,
        GetWeaponDamageType = function(hash) return (hash == 'WEAPON_KNIFE') and 2 or 3 end,
    })

    -- newArenaEnv has already loaded config.lua, config.weapons.lua and
    -- shared/arena.lua, in fxmanifest order. They are NOT loaded again here:
    -- a second config.lua replaces Config wholesale and takes the weapon
    -- catalogue with it -- and the catalogue is what says which guns ox owns.
    -- Nothing to build, so the entry handler does not yield on model loads.
    env.Arena.GetPlatform = function() return nil end
    env.Arena.GetCover = function() return {} end
    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/client/dispatch.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/spawnprotection.lua', env)
    Sandbox.loadInto('../Crimson-Arena/client/match.lua', env)

    local c = { env = env, world = world, ox = ox, ped = ped, runner = runner }

    function c.fire(event, payload)
        local handler = handlers['crimson_arena:client:' .. event]
        if not handler then error('no client handler for ' .. event, 2) end
        handler(payload)
    end

    function c.enter(freeze)
        c.fire('enterArena', {
            matchId = 'm1', arenaKey = 'trailerpark', modeKey = 'ffa',
            spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
            scatterRadius = 0.0, sizeFactor = 1.0, radar = false, loadout = {},
            boundary = { enabled = true, center = { x = 2344.4, y = 2565.0, z = 46.7 }, radius = 100.0 },
            freezeSeconds = freeze or 0,
        })
        c.fire('matchLive', {})
    end

    function c.exit() c.fire('exitArena', {}) end

    --- A gun prop on a ped: `name` is the weapon, `on` the ped it hangs from.
    local nextHandle = 5000
    function c.prop(name, on, extra)
        nextHandle = nextHandle + 1
        local object = { model = 'w_' .. name, attachedTo = on or 11 }
        for k, v in pairs(extra or {}) do object[k] = v end
        world.objects[nextHandle] = object
        return nextHandle
    end

    function c.itemCount(name, count)
        local handler = handlers['ox_inventory:itemCount']
        if handler then handler(name, count) end
    end

    --- Advances the clock and runs every captured thread once, `times` times.
    function c.poll(times, everyMs)
        for _ = 1, (times or 1) do
            world.clock = world.clock + (everyMs or 250)
            runner.step()
        end
    end

    --- ox finishes a draw: the gun is in the ped's hands and ox calls it drawn.
    function c.draw(weapon)
        ox.current = weapon
        ped.weapons[weapon.name] = (weapon.metadata and weapon.metadata.ammo) or 30
        ped.selected = weapon.name
    end

    function c.disarms()
        local n, first = 0, nil
        for _, event in ipairs(world.events) do
            if event.name == 'ox_inventory:disarm' then
                n = n + 1
                first = first or event
            end
        end
        return n, first
    end

    function c.gaveNatively(hash)
        for _, give in ipairs(ped.given) do
            if give.hash == hash then return true end
        end
        return false
    end

    return c
end

local function arenaCarbine(slot, serial)
    return { slot = slot or 1, name = 'WEAPON_CARBINERIFLE', hash = 'WEAPON_CARBINERIFLE', timer = 0,
        metadata = { serial = serial or 'ARENA-1', ammo = 30 } }
end

local function item(slot, name, serial)
    return { slot = slot, name = name, count = 1, metadata = { serial = serial } }
end

-- ======================================================================
-- THE DRAW THAT LANDS AFTER THE DOOR
-- ======================================================================

t.test('THE REPORT: a gun ox finishes drawing after the exit is put away', function()
    local c = newClient()
    c.enter()
    c.poll(2)

    -- The door has taken the kit back and nothing was drawn yet, so ox had
    -- nothing to holster and the strip found empty hands.
    c.ox.items = {}
    c.exit()

    -- The draw lands afterwards: a loaded carbine, no item anywhere.
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(1)
    t.equals((c.disarms()), 0,
        'it acted on the first sight -- one poll is not enough to tell a ghost from a moment of ox bookkeeping')
    c.poll(1)

    local n, first = c.disarms()
    t.equals(n, 1, 'the carbine with no item behind it is still in their hands -- usable until refreshskin')
    t.equals(first and first.args[1], true, 'it was holstered WITH the animation -- ox must be asked for noAnim')
    t.equals(c.ox.current, nil, 'ox still believes the carbine is drawn')
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'the carbine is still on the ped')

    c.poll(6)
    t.equals((c.disarms()), 1, 'it went on holstering after the gun was already gone')
end)

t.test('and the same when the player\'s own kit came back into the very slot the gun was drawn from', function()
    -- ox copies the new item's metadata onto a drawn weapon without comparing
    -- names, so a pistol of theirs landing in slot 1 must not read as the
    -- carbine's item.
    local c = newClient()
    c.enter()
    c.ox.items = { [1] = item(1, 'WEAPON_PISTOL', 'OWN-9') }
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)
    t.equals((c.disarms()), 1, 'a pistol in the slot was taken for the carbine\'s item')
end)

t.test('the player\'s OWN weapon, drawn with its item in their pockets, is never touched', function()
    local c = newClient()
    c.enter()
    c.exit()

    c.ox.items = { [5] = item(5, 'WEAPON_CARBINERIFLE', 'OWN-5') }
    c.draw(arenaCarbine(5, 'OWN-5'))
    for _ = 1, 80 do c.poll(2) end

    t.equals((c.disarms()), 0, 'a gun the player owns an item for was holstered')
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, 30, 'and it is no longer on the ped')
end)

t.test('but the arena\'s carbine drawn over the player\'s OWN carbine is still a gun with no item', function()
    -- Same name, different serial. ox would go on writing the arena gun's
    -- shots into the player's weapon; the serial is what tells them apart.
    local c = newClient()
    c.enter()
    c.ox.items = { [1] = item(1, 'WEAPON_CARBINERIFLE', 'OWN-1') }
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)
    t.equals((c.disarms()), 1, 'the name matched, so the arena\'s gun was let off as the player\'s own')
end)

t.test('a serialled gun drawn over a serial-less item of the same name is NOT its item', function()
    -- ox copies an item's metadata onto the gun it draws, so a real draw
    -- always carries its item's serial. Letting a serial-less copy stand in
    -- for the arena's gun was a way to keep that gun on purpose: own a
    -- serial-less carbine, press the key a second before the round ends.
    local c = newClient()
    c.enter()
    c.exit()
    c.ox.items = { [2] = { slot = 2, name = 'WEAPON_CARBINERIFLE', count = 1, metadata = {} } }
    c.draw(arenaCarbine(2, 'ARENA-1'))
    c.poll(3)
    t.equals((c.disarms()), 1, 'a serial-less carbine in the pockets let the arena\'s carbine walk out')
end)

t.test('and a gun with no serial over an item with no serial IS its item -- melee, anything unregistered', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.ox.items = { [2] = { slot = 2, name = 'WEAPON_BAT', count = 1, metadata = {} } }
    c.draw({ slot = 2, name = 'WEAPON_BAT', hash = 'WEAPON_BAT', timer = 0, metadata = {} })
    c.poll(6)
    t.equals((c.disarms()), 0, 'the player\'s own bat was holstered because nothing carries a serial')
end)

t.test('a drag inside the pockets is not a ghost: ox moves the slot before the pockets say so', function()
    -- ox's client sets the drawn weapon's slot as soon as the move is
    -- answered; the slot updates arrive a tick later. In between, the drawn
    -- weapon names slot 7 while the pockets still show it in slot 3.
    local c = newClient()
    c.enter()
    c.exit()
    c.ox.items = { [3] = item(3, 'WEAPON_CARBINERIFLE', 'OWN-3') }
    c.draw(arenaCarbine(7, 'OWN-3'))
    c.poll(4)
    c.ox.items = { [7] = item(7, 'WEAPON_CARBINERIFLE', 'OWN-3') }
    c.poll(4)
    t.equals((c.disarms()), 0, 'moving a gun inside the inventory got it holstered')
end)

t.test('a gun that looks item-less for ONE poll and then has its item is left alone', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.draw(arenaCarbine(4, 'OWN-4'))
    c.poll(1)
    c.ox.items = { [4] = item(4, 'WEAPON_CARBINERIFLE', 'OWN-4') }
    c.poll(6)
    t.equals((c.disarms()), 0, 'one sight of a gun without its item was enough to holster it')
end)

t.test('ox mid-holster is ox\'s business; the ghost is put away once ox has finished', function()
    local c = newClient()
    c.enter()
    c.exit()
    local ghost = arenaCarbine(1, 'ARENA-1')
    ghost.timer = nil
    c.draw(ghost)
    c.poll(6)
    t.equals((c.disarms()), 0, 'it acted while ox was holstering')

    c.ox.current.timer = 0
    c.poll(2)
    t.equals((c.disarms()), 1, 'the gun ox finished drawing was left in their hands')
end)

t.test('a draw still in flight -- nothing drawn yet -- is never interrupted', function()
    local c = newClient()
    c.enter()
    c.exit()
    -- ox's probe: the gun in the ped's hands for a moment, current weapon nil.
    c.ped.weapons.WEAPON_CARBINERIFLE = 0
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.poll(8)
    t.equals((c.disarms()), 0, 'the watch interrupted a draw ox had not finished')
end)

t.test('the watch is long enough for a slow draw, and it ends', function()
    -- Every draw loads its animation dictionary, and ox lets that load run to
    -- thirty seconds. A ten-second watch would have missed the slow ones.
    local c = newClient()
    c.enter()
    c.exit()
    local exitAt = c.world.clock

    c.world.clock = exitAt + 35000
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(2)
    t.equals((c.disarms()), 1, 'a draw that took 35 seconds to land after the exit was missed')

    -- Well past the window: the watch has stopped, and a later gun is not its
    -- business any more.
    c.world.clock = exitAt + 60000
    c.poll(3)
    local alive = c.runner.aliveCount()
    c.draw(arenaCarbine(1, 'ARENA-2'))
    c.poll(4)
    t.equals((c.disarms()), 1, 'the watch never ended -- it is policing ox for ever')
    t.equals(c.runner.aliveCount(), alive, 'something new started watching')
end)

t.test('ox restarting in the middle neither crashes the watch nor stops it', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.ox.throw = true
    local ok, err = pcall(c.poll, 4)
    t.isTrue(ok, 'a missing export took the watch down: ' .. tostring(err))
    t.equals((c.disarms()), 0, 'it acted on an answer it could not read')

    c.ox.throw = false
    c.poll(2)
    t.equals((c.disarms()), 1, 'once ox was back the ghost was never looked at again')
end)

t.test('the console says what was put away, and the server hears it with debug on', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)

    local said = false
    for _, line in ipairs(c.world.printed) do
        if line:find('put away WEAPON_CARBINERIFLE', 1, true) then said = true end
    end
    t.isTrue(said, 'the player was not told why their gun disappeared')

    local reported = false
    for _, sent in ipairs(c.world.serverEvents) do
        local line = type(sent.payload) == 'table' and sent.payload.line or ''
        if sent.name == 'crimson_arena:server:clientDebug' and tostring(line):find('itemless weapon', 1, true) then
            reported = true
        end
    end
    t.isTrue(reported, 'the server console never heard about it, so the owner cannot see it working')
end)

-- ======================================================================
-- INSIDE THE ROUND, ON RESTART, AND WHEN THE SERVER ASKS
-- ======================================================================

t.test('the mirror race at entry: the player\'s own gun drawn after the door stashed it', function()
    local c = newClient()
    c.ox.items = { [1] = item(1, 'WEAPON_CARBINERIFLE', 'ARENA-1') }
    c.enter()

    -- Their own SMG, stashed by the door, finishes drawing in the arena.
    c.draw({ slot = 4, name = 'WEAPON_SMG', hash = 'WEAPON_SMG', timer = 0, metadata = { serial = 'OWN-4' } })
    c.poll(3)
    t.equals((c.disarms()), 1, 'they are fighting with a gun they are not carrying')

    -- And the arena's own carbine, drawn properly, is left alone for the
    -- whole round -- long past forty seconds.
    c.draw(arenaCarbine(1, 'ARENA-1'))
    for _ = 1, 40 do c.poll(1, 30000) end
    t.equals((c.disarms()), 1, 'the arena\'s own weapon was holstered mid-round')

    -- And the watch is still running ten minutes in.
    c.draw(arenaCarbine(2, 'GONE-2'))
    c.poll(3)
    t.equals((c.disarms()), 2, 'the watch gave up mid-round')
end)

t.test('a restart starts the watch on its own -- no round, no exit', function()
    local c = newClient()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)
    t.equals((c.disarms()), 1, 'a restart that reclaimed kit mid-draw left the gun with nobody watching')
end)

t.test('the server can ask for the watch after the window has closed', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.world.clock = c.world.clock + 60000
    c.poll(3)

    c.draw(arenaCarbine(1, 'OWED-1'))
    c.poll(3)
    t.equals((c.disarms()), 0, 'the fixture is wrong: the window should have closed')

    c.fire('watchWeapons')
    c.poll(3)
    t.equals((c.disarms()), 1, 'the server took an owed gun back mid-draw and nothing looked')
end)

-- ======================================================================
-- THE EXIT ITSELF, WITH ox RUNNING
-- ======================================================================

t.test('THE REPORT: nothing ox owns is handed back natively at the door', function()
    local c = newClient()
    -- An item-less carbine on the ped as they walk in -- a ghost from before.
    c.ped.weapons.WEAPON_CARBINERIFLE = 60
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.world.health, c.world.armour = 180, 37
    c.enter()
    c.exit()

    t.isTrue(not c.gaveNatively('WEAPON_CARBINERIFLE'),
        'the exit gave the carbine to the ped natively -- a usable gun with no item')
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'the carbine is on the ped after the exit')
    t.isTrue(c.ped.selected ~= 'WEAPON_CARBINERIFLE', 'and in their hands')
    t.equals(c.world.healthSet, 180, 'health is no longer put back')
    t.equals(c.world.armourSet, 37, 'armour is no longer put back')
end)

t.test('and the arena\'s own gun still in hand at the exit comes off, one weapon at a time', function()
    local c = newClient()
    c.enter()
    c.ped.weapons.WEAPON_CARBINERIFLE = 12
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.exit()
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'the arena\'s carbine left the arena on the ped')
    t.equals(c.ped.selected, UNARMED, 'and they walked out holding it')
    t.equals(c.ped.wipes, 0, 'the whole ped was wiped on an ox server')
end)

t.test('what ox does NOT own is left as it was found: the parachute, and natives ox is told to ignore', function()
    -- WEAPON_STUNGUN is an ox item in stock ox_inventory; a job that hands it
    -- out natively has to list it in inventory:ignoreweapons, and does.
    local c = newClient({ ignore = '["WEAPON_PEPPERSPRAY","WEAPON_STUNGUN"]' })
    c.ped.weapons.GADGET_PARACHUTE = 1
    c.ped.weapons.WEAPON_STUNGUN = 3
    c.ped.weapons.WEAPON_PEPPERSPRAY = 5
    c.ped.selected = 'WEAPON_STUNGUN'
    c.enter()
    c.exit()

    t.equals(c.ped.weapons.GADGET_PARACHUTE, 1, 'the parachute was taken and never given back')
    t.equals(c.ped.weapons.WEAPON_STUNGUN, 3, 'the ignored stun gun was lost or its ammo changed')
    t.equals(c.ped.weapons.WEAPON_PEPPERSPRAY, 5, 'a weapon ox ignores was lost, or handed back with double ammo')
    t.equals(c.ped.selected, 'WEAPON_STUNGUN', 'their hands were not put back the way they walked in')
end)

t.test('an unreadable ignore list is read as empty, the way ox reads it, and raises nothing', function()
    local c = newClient({ ignore = 'BAD' })
    c.ped.weapons.WEAPON_PEPPERSPRAY = 5
    local ok, err = pcall(function()
        c.enter()
        c.exit()
    end)
    t.isTrue(ok, 'a malformed convar took the exit down: ' .. tostring(err))
    t.equals(c.ped.weapons.WEAPON_PEPPERSPRAY, nil, 'with no ignore list the spray is ox\'s, and it stayed on the ped')
    t.isTrue(not c.gaveNatively('WEAPON_PEPPERSPRAY'), 'and it was handed back natively')
end)

t.test('with the restore switched off the arena\'s gun still comes off, and nothing is given', function()
    local c = newClient({ mutate = function(config) config.Match.restoreLoadoutOnExit = false end })
    c.enter()
    c.ped.weapons.WEAPON_CARBINERIFLE = 12
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.exit()
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'the setting about handing things BACK let the arena\'s gun leave')
    t.equals(#c.ped.given, 0, 'something was given with the restore switched off')
end)

-- ======================================================================
-- A SERVER WITHOUT ox: EXACTLY WHAT IT HAD BEFORE
-- ======================================================================

t.test('without ox the ped is the inventory: wiped, and handed back what it walked in with', function()
    local c = newClient({ ox = 'missing' })
    c.ped.weapons.WEAPON_CARBINERIFLE = 60
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.enter()
    c.exit()

    t.equals(c.ped.wipes, 1, 'the exit no longer wipes the ped on a server without ox')
    t.isTrue(c.gaveNatively('WEAPON_CARBINERIFLE'), 'the carbine they walked in with was not given back')
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, 60, 'and not with the ammo they walked in with')
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'and it is not back in their hands')

    -- INSIDE the forty seconds an ox server would be watched for: polling
    -- after the window has closed proves nothing about the guard.
    local ok, err = pcall(c.poll, 4)
    t.isTrue(ok, 'something raised on a server without ox: ' .. tostring(err))
    t.equals((c.disarms()), 0, 'ox\'s disarm was asked for on a server with no ox')
    t.isTrue(not c.world.exportsTouched, 'the export table was read on a server with no ox')
end)

-- ======================================================================
-- EACH START ON ITS OWN, WITH EVERY OTHER WINDOW LONG CLOSED
--
-- The watch started at load and the one started at entry cover every draw a
-- short test makes, so deleting the exit's own start -- or the entry's --
-- left everything above green. These outlive every other window first.
-- ======================================================================

local function outliveEveryWindow(c)
    c.world.clock = c.world.clock + 60000
    c.poll(2)
end

t.test('after a round longer than the window, the exit itself starts the watch', function()
    local c = newClient()
    outliveEveryWindow(c)
    c.enter()
    for _ = 1, 10 do c.poll(1, 30000) end
    c.ox.items = {}
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)
    t.equals((c.disarms()), 1, 'the exit did not start a watch of its own -- the owner\'s report, unfixed')
end)

t.test('a round entered long after start-up is watched from the entry', function()
    local c = newClient()
    outliveEveryWindow(c)
    c.ox.items = { [1] = item(1, 'WEAPON_CARBINERIFLE', 'ARENA-1') }
    c.enter()
    c.draw({ slot = 4, name = 'WEAPON_SMG', hash = 'WEAPON_SMG', timer = 0, metadata = { serial = 'OWN-4' } })
    c.poll(3)
    t.equals((c.disarms()), 1, 'the entry did not start a watch of its own')
end)

t.test('however many times it is asked for, one watch thread runs', function()
    local c = newClient()
    c.enter()
    c.exit()
    local before = c.runner.aliveCount()
    c.fire('watchWeapons')
    c.fire('watchWeapons')
    t.equals(c.runner.aliveCount(), before, 'every request started another watch thread')
end)

t.test('pockets that cannot be read are not read as empty', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.draw(arenaCarbine(1, 'OWN-1'))
    c.env.exports.ox_inventory.GetPlayerItems = function() error('No such export', 0) end
    c.poll(6)
    t.equals((c.disarms()), 0, 'an unreadable inventory was taken as proof of a gun with no item')
end)

t.test('an ox that does not answer the disarm event still loses the gun', function()
    local c = newClient({ deafOx = true })
    c.enter()
    c.exit()
    c.draw(arenaCarbine(1, 'ARENA-1'))
    c.poll(3)
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'the disarm did not take and nothing else took the gun off')
    t.isTrue(c.ped.selected ~= 'WEAPON_CARBINERIFLE', 'and it is still in their hands')
end)

t.test('one poll that raises does not switch the watch off for the rest of the session', function()
    local c = newClient()
    c.enter()
    c.exit()
    c.world.raiseOnDisarm = true
    c.draw(arenaCarbine(1, 'ARENA-1'))
    local ok, err = pcall(c.poll, 3)
    t.isTrue(ok, 'the raise took the watch thread down: ' .. tostring(err))

    -- The same gun, still there: the watch must still be on duty.
    c.poll(3)
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'after one bad poll the watch never looked again')
end)

-- ======================================================================
-- WHAT THE CAPTURE MUST NOT RECORD, AND WHAT THE CATALOGUE COVERS
-- ======================================================================

t.test('an ox weapon outside the catalogue, drawn by ox at entry, is not handed back natively', function()
    -- One of the owner's addon katanas: an ox item on their server, and not
    -- in config.weapons.lua, so the catalogue test cannot recognise it.
    local c = newClient()
    c.ox.items = { [3] = { slot = 3, name = 'WEAPON_KATANA', count = 1, metadata = {} } }
    c.draw({ slot = 3, name = 'WEAPON_KATANA', hash = 'WEAPON_KATANA', timer = 0, metadata = {} })
    c.enter()
    -- Mid-round ox holsters it (the door took its item), and ox's holster
    -- wipes the ped.
    c.ox.current = nil
    c.ped.weapons = {}
    c.ped.selected = UNARMED
    c.exit()
    t.isTrue(not c.gaveNatively('WEAPON_KATANA'), 'the katana, an ox item, was given natively -- an item-less copy')
    t.equals(c.ped.weapons.WEAPON_KATANA, nil, 'the katana is on the ped with ox holding nothing')
    t.isTrue(c.ped.selected ~= 'WEAPON_KATANA', 'and it was put in their hands')
end)

t.test('a catalogue weapon switched OFF is still ox\'s, and is not handed back natively', function()
    -- enabled = false stops the arena ISSUING one, not the player owning one.
    local c = newClient({ mutate = function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.weapon == 'WEAPON_CARBINERIFLE' then weapon.enabled = false end
        end
    end })
    c.ped.weapons.WEAPON_CARBINERIFLE = 60
    c.ped.selected = 'WEAPON_CARBINERIFLE'
    c.enter()
    c.exit()
    t.isTrue(not c.gaveNatively('WEAPON_CARBINERIFLE'), 'a switched-off ox weapon was handed back with no item')
    t.equals(c.ped.weapons.WEAPON_CARBINERIFLE, nil, 'and it is on the ped')
end)

t.test('a hash in the ignore list is honoured the way ox honours it', function()
    local c = newClient({ ignore = '[12345]' })
    local plain = c.env.joaat
    c.env.joaat = function(name)
        if name == 'WEAPON_PEPPERSPRAY' then return 12345 end
        return plain(name)
    end
    c.ped.weapons[12345] = 5
    c.enter()
    c.exit()
    t.equals(c.ped.weapons[12345], 5, 'an ignored weapon listed by hash was taken off the ped')
end)

-- ======================================================================
-- THE GUN ON THE BACK THAT IS NOT IN THE INVENTORY
--
-- crimson-backweapons can build the same back prop twice and lose one copy.
-- The copy it lost is never removed, and outlives the arena taking the gun
-- back. The sweep takes gun props off the player's ped that they hold no
-- item for -- and nothing else.
-- ======================================================================

local function sweepWindow(c) for _ = 1, 3 do c.poll(1, 5000) end end

t.test('THE REPORT: the arena carbine left on the back after the exit is removed', function()
    local c = newClient()
    c.enter()
    local orphan = c.prop('WEAPON_CARBINERIFLE')
    c.ox.items = {}
    c.exit()
    sweepWindow(c)
    t.equals(c.world.objects[orphan], nil, 'the carbine prop is still on their back with no carbine in the inventory')
end)

t.test('a prop of a gun they DO hold is never touched', function()
    local c = newClient()
    c.enter()
    c.ox.items = { [5] = item(5, 'WEAPON_CARBINERIFLE', 'OWN-5') }
    local mine = c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[mine] ~= nil, 'the prop of the carbine they own was removed')
end)

t.test('FINAL CHECK: two props of a gun they hold one of -- both go, whatever the pool order', function()
    -- Keeping "the first" could delete back-weapons' real prop and keep the
    -- orphan. Both go; back-weapons redraws its one tracked prop.
    local c = newClient()
    c.enter()
    c.ox.items = { [5] = item(5, 'WEAPON_CARBINERIFLE', 'OWN-5') }
    local a, b = c.prop('WEAPON_CARBINERIFLE'), c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    sweepWindow(c)
    t.isNil(c.world.objects[a], 'a duplicate survived')
    t.isNil(c.world.objects[b], 'a duplicate survived')
end)

t.test('FINAL CHECK: one prop of a gun they hold, not in hand, is never touched', function()
    local c = newClient()
    c.enter()
    c.ox.items = { [5] = item(5, 'WEAPON_CARBINERIFLE', 'OWN-5') }
    local a = c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[a] ~= nil)
end)

t.test('the gun in their hands is never touched, even with no item behind it', function()
    local c = newClient()
    c.enter()
    c.ox.items = {}
    local inHand = c.prop('WEAPON_CARBINERIFLE')
    c.world.inHand[11] = inHand
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[inHand] ~= nil, 'the weapon object in their hand was deleted')
end)

t.test('another player\'s networked prop is skipped; a networked one this game owns is removed', function()
    local c = newClient()
    c.enter()
    c.ox.items = {}
    local theirs = c.prop('WEAPON_CARBINERIFLE', 11, { networked = true, owner = 7 })
    local ours = c.prop('WEAPON_SPECIALCARBINE', 11, { networked = true, owner = 1 })
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[theirs] ~= nil, 'a prop another player\'s game owns was deleted')
    t.equals(c.world.objects[ours], nil, 'a networked prop this game owns was left -- the carbine may well be one')
end)

t.test('a gun prop not on this player, and anything that is not a gun, is left alone', function()
    local c = newClient()
    c.enter()
    c.ox.items = {}
    local loose = c.prop('WEAPON_CARBINERIFLE', 0)
    local other = c.prop('WEAPON_CARBINERIFLE', 99)
    c.world.objects[6001] = { model = 'prop_cs_hat', attachedTo = 11 }
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[loose] ~= nil and c.world.objects[other] ~= nil, 'a prop not on this player was deleted')
    t.isTrue(c.world.objects[6001] ~= nil, 'a hat was deleted')
end)

t.test('an inventory that cannot be read is not read as empty', function()
    local c = newClient()
    c.enter()
    local prop = c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    c.ox.throw = true
    local ok = pcall(sweepWindow, c)
    t.isTrue(ok, 'an unreadable inventory raised out of the sweep')
    t.isTrue(c.world.objects[prop] ~= nil, 'the prop was deleted on an inventory nobody could read')
end)

t.test('a reclaim that reaches the client late is still cleaned up, whenever it lands', function()
    local c = newClient()
    c.enter()
    c.ox.items = { [1] = item(1, 'WEAPON_CARBINERIFLE', 'ARENA-1') }
    local orphan = c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    for _ = 1, 14 do c.poll(1, 5000) end         -- the exit's minute runs out, item still held
    t.isTrue(c.world.objects[orphan] ~= nil, 'the fixture is wrong: the item was still held')
    c.ox.items = {}
    c.itemCount('WEAPON_CARBINERIFLE', 0)          -- ox says the carbine just went to zero
    sweepWindow(c)
    t.equals(c.world.objects[orphan], nil, 'the late reclaim left the prop on their back for good')
end)

t.test('after a ped swap the prop left on the old ped is found too', function()
    local c = newClient()
    c.enter()
    c.ox.items = {}
    c.world.oldPed = 11
    local orphan = c.prop('WEAPON_CARBINERIFLE', 11)
    c.exit()
    c.env.PlayerPedId = function() return 12 end
    sweepWindow(c)
    t.equals(c.world.objects[orphan], nil, 'the orphan on the ped the player had at the exit was never looked at')
end)

t.test('without ox the sweep does nothing at all', function()
    local c = newClient({ ox = 'missing' })
    c.enter()
    local prop = c.prop('WEAPON_CARBINERIFLE')
    c.exit()
    sweepWindow(c)
    t.isTrue(c.world.objects[prop] ~= nil, 'a prop was removed on a server with no ox to ask')
end)

-- ======================================================================
-- WEAPON OUT ON SPAWN
--
-- "on match start or revive start with the weapon out". Drawn through ox's
-- own useSlot, never natively -- a native give is the item-less gun above.
-- ======================================================================

local function drawWindow(c) for _ = 1, 40 do c.poll(1, 250) end end
local function useCount(c) return #(c.ox.used or {}) end

t.test('THE ASK: the round goes live with the arena gun already in hand', function()
    local c = newClient()
    c.ox.items[1] = item(1, 'WEAPON_KNIFE')
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'the fighter did not start with the gun out')
    t.equals(useCount(c), 1, 'the draw was asked for more than once -- a second useSlot holsters it')
    t.equals(c.ox.used[1].slot, 4, 'the blade in a lower slot was drawn over the gun')
    t.isTrue(c.ox.used[1].noAnim == true, 'the draw played the slow animation')
    t.isTrue(not c.gaveNatively('WEAPON_CARBINERIFLE'), 'the gun was given natively, with no item behind it')
end)

t.test('with only a blade issued, the blade comes out', function()
    local c = newClient()
    c.ox.items[2] = item(2, 'WEAPON_KNIFE')
    c.enter()
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_KNIFE')
end)

t.test('during the start countdown the hands stay empty; the gun comes out as it ends', function()
    local c = newClient()
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter(3)
    c.poll(2, 250)
    t.equals(useCount(c), 0, 'the gun was drawn during the frozen countdown')
    for _ = 1, 8 do c.poll(1, 1000) end
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'the gun never came out once the round went live')
end)

t.test('kit that lands late is still drawn once it arrives', function()
    local c = newClient()
    c.enter()
    c.poll(6, 250)
    t.equals(useCount(c), 0)
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE')
    t.equals(useCount(c), 1)
end)

t.test('a fighter who already has something in hand keeps it', function()
    local c = newClient()
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.ox.items[5] = item(5, 'WEAPON_PISTOL', 'ARENA-2')
    c.enter()
    c.draw({ slot = 5, name = 'WEAPON_PISTOL', hash = 'WEAPON_PISTOL', timer = 0, metadata = { serial = 'ARENA-2' } })
    drawWindow(c)
    t.equals(useCount(c), 0, 'the pistol they had drawn was swapped out')
    t.equals(c.ped.selected, 'WEAPON_PISTOL')
end)

t.test('a draw ox refuses is retried at a settle, never hammered, and gives up', function()
    local c = newClient()
    c.ox.deafDraw = true
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    for _ = 1, 80 do c.poll(1, 250) end
    local n = useCount(c)
    t.isTrue(n >= 2 and n <= 9, 'retries were ' .. n .. ' -- expected a handful across the window')
    for _ = 1, 40 do c.poll(1, 250) end
    t.equals(useCount(c), n, 'the draw kept trying after its window')
end)

t.test('switched off, a respawn leaves the hands empty', function()
    local c = newClient({ mutate = function(Config) Config.Match.drawWeaponOnRespawn = false end })
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    drawWindow(c)
    c.ox.current = nil; c.ped.selected = UNARMED
    c.fire('respawn', { spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 }, scatterRadius = 0.0, loadout = {} })
    drawWindow(c)
    t.equals(useCount(c), 1, 'the gun was drawn again on a revive')
    t.equals(c.ped.selected, UNARMED)
end)

t.test('THE ASK: a revive comes back with the gun out', function()
    local c = newClient()
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    drawWindow(c)
    c.ox.current = nil; c.ped.selected = UNARMED
    c.fire('respawn', { spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 }, scatterRadius = 0.0, loadout = {} })
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'the revived fighter came back empty-handed')
    t.equals(useCount(c), 2)
end)

t.test('leaving before the kit lands draws nothing', function()
    local c = newClient()
    c.enter()
    c.poll(2, 250)
    c.exit()
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    drawWindow(c)
    t.equals(useCount(c), 0, 'a gun was drawn after the fighter had left the round')
end)

t.test('a weapon outside the arena catalogue is never drawn', function()
    local c = newClient()
    c.ox.items[1] = item(1, 'WEAPON_NOT_IN_CATALOGUE')
    c.enter()
    drawWindow(c)
    t.equals(useCount(c), 0)
end)

t.test('a revive with only a knife comes back with the knife out', function()
    local c = newClient()
    c.ox.items[2] = item(2, 'WEAPON_KNIFE')
    c.enter()
    drawWindow(c)
    c.ox.current = nil; c.ped.selected = UNARMED
    c.fire('respawn', { spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 }, scatterRadius = 0.0, loadout = {} })
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_KNIFE')
end)

t.test('switched off, the hands stay empty', function()
    local c = newClient({ mutate = function(Config) Config.Match.drawWeaponOnSpawn = false end })
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    drawWindow(c)
    t.equals(useCount(c), 0)
end)

t.test('without ox nothing is drawn and nothing raises', function()
    local c = newClient({ ox = 'missing' })
    c.enter()
    drawWindow(c)
    t.isTrue(not c.world.exportsTouched, 'ox exports were read with ox not running')
end)

-- ======================================================================
-- FIVE SECONDS OF INVULNERABILITY AFTER A REVIVE
-- ======================================================================

local function revive(c)
    c.fire('respawn', { spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 }, scatterRadius = 0.0, loadout = {} })
end

t.test('THE ASK: a revived fighter is invulnerable for 5 seconds, then not', function()
    local c = newClient()
    c.enter()
    revive(c)
    t.equals(c.world.invincible, true, 'the revive was not protected')
    for _ = 1, 45 do c.poll(1, 100) end
    t.equals(c.world.invincible, true, 'protection ended before 5 seconds')
    for _ = 1, 10 do c.poll(1, 100) end
    t.equals(c.world.invincible, false, 'protection never ended')
end)

t.test('firing ends the protection at once', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.poll(2, 100)
    c.world.shooting = true
    c.poll(1, 100)
    t.equals(c.world.invincible, false, 'a protected fighter could shoot while untouchable')
end)

t.test('a second revive inside the window restarts it, and the first never switches it off', function()
    local c = newClient()
    c.enter()
    revive(c)
    for _ = 1, 30 do c.poll(1, 100) end
    revive(c)
    for _ = 1, 30 do c.poll(1, 100) end
    t.equals(c.world.invincible, true, 'the first revive\'s timer cut the second one short')
    for _ = 1, 25 do c.poll(1, 100) end
    t.equals(c.world.invincible, false)
end)

t.test('leaving the round ends the protection', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.exit()
    c.poll(2, 100)
    t.equals(c.world.invincible, false, 'a fighter walked out of the round still invulnerable')
end)

t.test('round start is not a revive: nobody starts the round invulnerable', function()
    local c = newClient()
    c.enter()
    c.poll(2, 100)
    t.isTrue(c.world.invincible ~= true)
end)

t.test('seconds = 0 switches it off', function()
    local c = newClient({ mutate = function(Config) Config.Match.spawnProtection.seconds = 0 end })
    c.enter()
    revive(c)
    t.isTrue(c.world.invincible ~= true)
end)

t.test('the anticheat hooks are called at the start and the end of the window', function()
    local c = newClient()
    local calls = {}
    c.env.ArenaSpawnProtection.OnStart = function(_ped, seconds) calls[#calls + 1] = 'start:' .. seconds end
    c.env.ArenaSpawnProtection.OnEnd = function() calls[#calls + 1] = 'end' end
    c.enter()
    revive(c)
    for _ = 1, 60 do c.poll(1, 100) end
    t.equals(table.concat(calls, ','), 'start:5,end')
end)

t.test('a hook that raises cannot keep a fighter invulnerable', function()
    local c = newClient()
    c.env.ArenaSpawnProtection.OnStart = function() error('anticheat blew up') end
    c.env.ArenaSpawnProtection.OnEnd = function() error('anticheat blew up') end
    c.enter()
    revive(c)
    t.equals(c.world.invincible, true)
    for _ = 1, 60 do c.poll(1, 100) end
    t.equals(c.world.invincible, false)
end)

t.test('THE REVIEW: a restart inside the window does not leave the fighter invincible', function()
    local c = newClient()
    c.enter()
    revive(c)
    t.equals(c.world.invincible, true)
    -- The resource dies: its threads with it. Only the stop handlers run.
    for _, fn in ipairs(c.world.stops or {}) do fn('crimson_arena') end
    t.equals(c.world.invincible, false, 'a restart left the fighter invincible for good')
end)

t.test('another resource stopping does not end the window', function()
    local c = newClient()
    c.enter()
    revive(c)
    for _, fn in ipairs(c.world.stops or {}) do fn('some_other_resource') end
    t.equals(c.world.invincible, true)
end)

t.test('leaving the round ends the protection at once, not on the next poll', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.exit()
    t.equals(c.world.invincible, false)
end)

t.test('THE REVIEW: the reclaim emptying a gun does not cut the minute-long exit sweep short', function()
    local c = newClient()
    c.enter()
    c.exit()
    -- The door takes the arena carbine back: ox reports its count at zero.
    c.itemCount('WEAPON_CARBINERIFLE', 0)
    -- Well past 15 s, well inside the minute, the back-weapons redraw lands.
    for _ = 1, 6 do c.poll(1, 5000) end
    local prop = c.prop('WEAPON_CARBINERIFLE')
    for _ = 1, 3 do c.poll(1, 5000) end
    t.equals(c.world.objects[prop], nil, 'the sweep had already stopped at 15 s')
end)

t.test('THE REVIEW: a melee attack ends the protection too', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.poll(2, 100)
    c.world.melee = true
    c.poll(1, 16)
    t.equals(c.world.invincible, false, 'a knife fighter stayed untouchable while swinging')
end)

t.test('THE REVIEW: pressing attack ends it', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.poll(1, 16)
    c.world.pressed = 24
    c.poll(1, 16)
    t.equals(c.world.invincible, false)
end)

t.test('THE REVIEW: a press on a DISABLED control (menu, phone) is not an attack', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.poll(1, 16)
    c.world.disabledPressed = 24
    c.poll(1, 16)
    t.equals(c.world.invincible, true)
end)

t.test('THE REVIEW: being meleed by an ENEMY does not switch the protection off', function()
    local c = newClient()
    c.enter()
    revive(c)
    c.poll(1, 16)
    c.world.beingMeleed = true
    c.poll(1, 16)
    t.equals(c.world.invincible, true, 'a rusher punched the protection off a fresh spawn')
end)

t.test('FINAL CHECK: drawWeaponOnSpawn = false does not switch off the revive draw', function()
    local c = newClient({ mutate = function(Config) Config.Match.drawWeaponOnSpawn = false end })
    c.ox.items[4] = item(4, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.enter()
    drawWindow(c)
    t.equals(useCount(c), 0, 'round start drew with drawWeaponOnSpawn off')
    revive(c)
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'the revive draw was switched off by the spawn switch')
end)

t.test('FINAL CHECK: the issued gun is drawn, not the player\'s own catalogue gun in a lower slot', function()
    local c = newClient()
    c.ox.items[1] = item(1, 'WEAPON_PISTOL', 'OWN-1')
    c.ox.items[6] = item(6, 'WEAPON_CARBINERIFLE', 'ARENA-1')
    c.fire('enterArena', {
        matchId = 'm1', arenaKey = 'trailerpark', modeKey = 'ffa',
        spawn = { x = 2344.0, y = 2565.0, z = 46.7, w = 0.0 },
        scatterRadius = 0.0, sizeFactor = 1.0, radar = false,
        loadout = { weapons = { { weapon = 'WEAPON_CARBINERIFLE' } } },
        boundary = { enabled = true, center = { x = 2344.4, y = 2565.0, z = 46.7 }, radius = 100.0 },
        freezeSeconds = 0,
    })
    c.fire('matchLive', {})
    drawWindow(c)
    t.equals(c.ped.selected, 'WEAPON_CARBINERIFLE', 'the player\'s own pistol was drawn over the issued carbine')
end)

t.test('FINAL CHECK: cover/reload/sprint keys (140, 141) do not end protection', function()
    for _, key in ipairs({ 140, 141 }) do
        local c = newClient()
        c.enter()
        revive(c)
        c.poll(1, 16)
        c.world.pressed = key
        c.poll(1, 16)
        t.equals(c.world.invincible, true, 'control ' .. key .. ' ended protection')
    end
end)

os.exit(t.summary())
