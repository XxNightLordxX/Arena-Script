--[[
    crimson_arena/tests/recycledid_spec.lua

    THE EXIT THAT RUNS WHEN THE ARENA COULD NOT READ WHO IT WAS ARMING.

    Every row the door writes about a fighter is stamped with their citizen
    id, and there is exactly one way for that stamp to come out empty: the
    framework could not answer `qbx_core:GetPlayer(src)` at the instant the
    kit was handed over. A player still loading, a drop-in, or qbx_core
    hiccuping is enough. The arena arms them anyway -- which is the right
    call, because refusing to arm somebody the framework is slow about would
    break every drop-in -- but from then on it is holding rows it cannot put
    a name to.

    THE SAME MOMENT ALSO STOPS A STASH RECORD BEING MADE (warnOwnKit: "there
    is no citizen id to stash against"), and a missing record is what routes
    the exit down reclaimWeapons' unguarded path. So the trigger and the
    exposure are the same event, and this happens with the door ON -- the
    shipped setting -- and not only with it off.

    WHAT THE EXIT MUST DO WITH A ROW IT CANNOT NAME. Nothing. By the time it
    runs, that server id may belong to somebody else -- a player who
    reconnected onto the freed slot, or the same person after a character
    switch -- and every question the exit asks about ownership answers
    against the person standing there NOW. An owner it cannot read must not
    quietly become the live holder, because then the arena settles a departed
    fighter's round against a stranger's pockets: their weapon, their
    ammunition, their plates, their bandages, and a debt on the operator's
    outstanding-kit screen for a loadout they have never held.

    The inventory double holds REAL CONTENTS and REAL SERIALS, because the
    thing worth asserting is whose property ends up where.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param mutate fun(config: table)?
local function newServer(mutate)
    -- [src|stashId] = { [slot] = { name, count, metadata } }, with holes,
    -- which is the shape ox_inventory really answers in.
    local bags = {}
    local console = {}
    local identity = {}
    local serials = 0

    -- The two reads that fail together in the case this file is about, kept
    -- APART so a test can say which one it is exercising. They come from the
    -- same outage in production and this fixture does not force that, because
    -- a test that can only fail both at once cannot show which one the
    -- production code was leaning on.
    local blindIdentity = false
    local blindInventory = false

    local function bag(id)
        bags[id] = bags[id] or {}
        return bags[id]
    end

    local function freeSlot(into)
        local slot = 1
        while into[slot] ~= nil do slot = slot + 1 end
        return slot
    end

    local ox = {
        RegisterStash = function() return true end,
        registerHook = function() return true end,

        -- NOT LOADED IS NOT EMPTY, and this fixture can say the difference.
        -- ox_inventory throws for an inventory it has not loaded, which is
        -- what a player at the character-select screen looks like -- and it
        -- is the read the arena uses to give an issued weapon its serial.
        GetInventoryItems = function(_self, id)
            if blindInventory and type(id) == 'number' then error('inventory is not loaded', 0) end
            local out = {}
            for slot, item in pairs(bag(id)) do
                out[slot] = { name = item.name, count = item.count, metadata = item.metadata, slot = slot }
            end
            return out
        end,

        -- A SERIAL PER WEAPON, exactly as ox_inventory does. Without it every
        -- weapon in this fixture is anonymous, and "anonymous" is one of the
        -- two cases below rather than all of them.
        AddItem = function(_self, id, name, count, metadata)
            local into = bag(id)
            local meta = metadata
            if type(name) == 'string' and name:find('^WEAPON') then
                meta = {}
                for key, value in pairs(metadata or {}) do meta[key] = value end
                serials = serials + 1
                meta.serial = ('SER%d'):format(serials)
            elseif meta == nil then
                for _, item in pairs(into) do
                    if item.name == name and item.metadata == nil then
                        item.count = item.count + count
                        return true
                    end
                end
            end
            into[freeSlot(into)] = { name = name, count = count, metadata = meta }
            return true
        end,

        --- METADATA IS A FILTER AND `slot` IS AN AIM, which is the whole
        --- subject of takeWeaponBack: a removal by name alone takes whichever
        --- slot it finds first, and a fixture that ignored the slot would
        --- make that indistinguishable from a removal that aimed.
        RemoveItem = function(_self, id, name, count, metadata, slot)
            local from = bag(id)

            local function matches(item)
                if item == nil or item.name ~= name then return false end
                for key, value in pairs(metadata or {}) do
                    if (item.metadata or {})[key] ~= value then return false end
                end
                return true
            end

            local candidates = {}
            if slot ~= nil then
                if matches(from[slot]) then candidates[#candidates + 1] = slot end
            else
                for at, item in pairs(from) do
                    if matches(item) then candidates[#candidates + 1] = at end
                end
                table.sort(candidates)
            end

            local total = 0
            for _, at in ipairs(candidates) do total = total + from[at].count end
            if total < count then return false end

            local want = count
            for _, at in ipairs(candidates) do
                if want <= 0 then break end
                local have = from[at].count
                if have <= want then
                    want = want - have
                    from[at] = nil
                else
                    from[at].count = have - want
                    want = 0
                end
            end
            return true
        end,

        GetItemCount = function(_self, id, name)
            local total = 0
            for _, item in pairs(bag(id)) do
                if item.name == name then total = total + item.count end
            end
            return total
        end,

        ClearInventory = function(_self, id)
            bags[id] = {}
            return true
        end,
    }

    local placed = {}
    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        ArenaDispatch = {
            Set = function(src) placed[src] = true end,
            Clear = function(src) placed[src] = nil end,
            IsPlayerInArena = function(src) return placed[src] == true end,
        },
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        Wait = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function() end,
        CreateThread = function(fn) fn() end,
        GetPlayers = function() return {} end,
        TriggerClientEvent = function() end,
        print = function(line) console[#console + 1] = line end,
        lib = Sandbox.newOxLib(),
    })

    -- OFF, for the reason ammo_spec gives: the retry sweep is a `while true`
    -- and CreateThread above runs a body to completion.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        if blindIdentity or identity[src] == nil then return nil end
        return { PlayerData = { citizenid = identity[src] } }
    end
    Sandbox.loadInto('../server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        --- Whether the framework can answer who is on a server id at all.
        blindIdentity = function(on) blindIdentity = on end,
        --- Whether ox_inventory can read a player's pockets.
        blindInventory = function(on) blindInventory = on end,
        identify = function(src, citizenid) identity[src] = citizenid end,
        give = function(src, name, count, metadata)
            local into = bag(src)
            into[freeSlot(into)] = { name = name, count = count, metadata = metadata }
        end,
        --- A DIFFERENT CHARACTER on a server id somebody else has vacated,
        --- which is what the server does with every freed slot.
        recycleId = function(src, citizenid, items)
            identity[src] = citizenid
            bags[src] = {}
            for _, item in ipairs(items or {}) do
                local into = bag(src)
                into[freeSlot(into)] = { name = item.name, count = item.count, metadata = item.metadata }
            end
        end,
        countOf = function(src, name) return ox.GetItemCount(ox, src, name) end,
        --- WHICH COPIES they are holding, not how many. Two weapons of one
        --- name are the same number and different property: the serial is
        --- the only thing that says whose a copy is, so a test about the
        --- arena taking back ITS gun has to read this rather than the count.
        --- A copy with no serial is somebody's own; 'none' says so out loud.
        serialsOf = function(src, name)
            local found = {}
            for _, item in pairs(bag(src)) do
                if item.name == name then
                    found[#found + 1] = (item.metadata or {}).serial or 'none'
                end
            end
            table.sort(found)
            return #found == 0 and 'empty' or table.concat(found, ',')
        end,
        carrying = function(src)
            local names = {}
            for _, item in pairs(bag(src)) do names[#names + 1] = item.name end
            table.sort(names)
            return table.concat(names, ',')
        end,
        --- The outstanding-kit screen, as one comparable line.
        slate = function()
            local rows = {}
            for _, row in ipairs(env.ArenaAmmo.OwedKit()) do
                local bits = {}
                for _, weapon in ipairs(row.weapons) do bits[#bits + 1] = weapon.name end
                for _, item in ipairs(row.items) do bits[#bits + 1] = ('%s x%d'):format(item.name, item.amount) end
                table.sort(bits)
                rows[#rows + 1] = ('%s owes %s'):format(row.citizenid, table.concat(bits, ','))
            end
            table.sort(rows)
            return #rows == 0 and 'nobody' or table.concat(rows, ' | ')
        end,
        log = function() return table.concat(console, '\n') end,
    }
end

print('recycledid_spec')

-- ========================================================================
-- THE WEAPON
-- ========================================================================

t.test('DEFECT: an arena weapon it could not name was taken off the stranger who inherited the id', function()
    -- The framework cannot say who is at the door, and the read that would
    -- give the issued copy a serial fails in the same breath -- so the row
    -- the arena keeps has neither an owner nor a serial on it.
    local s = newServer()
    s.blindIdentity(true)
    s.blindInventory(true)
    s.ammo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_BAT', key = 'bat' } }, supplies = {} })
    s.blindInventory(false)
    s.blindIdentity(false)

    -- That character walks off with the arena's bat, and the freed server id
    -- goes to somebody who has never been near the arena -- carrying a bat of
    -- their own, which on this build has no serial either.
    s.recycleId(1, 'CID_STRANGER', { { name = 'WEAPON_BAT', count = 1 } })

    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.countOf(1, 'WEAPON_BAT'), 1,
        'a player who has never been in the arena had their own weapon confiscated by somebody else\'s exit')
end)

t.test('DEFECT: and the debt for a row with no owner was filed against whoever holds the id now', function()
    -- Same outage, one square over: the inventory read works, so the row has
    -- a serial -- it just has nobody's name on it.
    local s = newServer()
    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } }, supplies = {} })
    s.blindIdentity(false)

    s.recycleId(1, 'CID_STRANGER', {})
    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.slate(), 'nobody',
        'the newcomer is on the outstanding-kit screen owing a weapon they have never held')
end)

t.test('and the console says the weapon was written off, and why', function()
    local s = newServer()
    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } }, supplies = {} })
    s.blindIdentity(false)

    s.recycleId(1, 'CID_STRANGER', {})
    s.ammo.Reclaim(1, 'disconnected')

    local said = s.log()
    t.isTrue(said:find('written off', 1, true) ~= nil and said:find('readable owner', 1, true) ~= nil,
        ('nothing in the console says the arena could not name the owner:\n%s'):format(said))
end)

t.test('and the stamp names the fighter as soon as anything can read it, so the debt lands on them', function()
    -- The hiccup is over by the time the fighter respawns and their bandages
    -- are topped up, and that top-up reads the citizen id again. The stamp
    -- written there is about the SAME round, so the weapon row it could not
    -- name at the door has an owner after all -- which is the difference
    -- between chasing the right character and writing the loadout off.
    local s = newServer()
    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } }, supplies = {} })
    s.blindIdentity(false)

    s.identify(1, 'CID_FIGHTER')
    s.ammo.Refresh(1, 'm1', { weapons = {}, supplies = { { item = 'bandage', count = 2 } } })

    s.recycleId(1, 'CID_STRANGER', {})
    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.slate(), 'CID_FIGHTER owes WEAPON_PISTOL',
        'the weapon is on the wrong slate, or on none at all')
end)

-- ========================================================================
-- THE CONSUMABLES
--
-- The biggest of the three, because rounds, plates and bandages have no
-- serial to protect them and there is no notification anywhere on this path.
-- ========================================================================

t.test('DEFECT: a stranger\'s own bandages were taken to settle a round they were never in', function()
    local s = newServer()
    t.isTrue(s.env.Config.Loadouts.inventory.stripOnEntry ~= false,
        'this test is only worth anything on the SHIPPED door setting')

    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', { weapons = {}, supplies = { { item = 'bandage', count = 5 } } })
    s.blindIdentity(false)

    s.recycleId(1, 'CID_STRANGER', { { name = 'bandage', count = 9 } })
    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.countOf(1, 'bandage'), 9,
        'the newcomer was charged the departed fighter\'s issued count out of their own pockets')
end)

t.test('and nothing is written down against them for it either', function()
    local s = newServer()
    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', { weapons = {}, supplies = { { item = 'bandage', count = 5 } } })
    s.blindIdentity(false)

    s.recycleId(1, 'CID_STRANGER', { { name = 'bandage', count = 9 } })
    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.slate(), 'nobody', 'the newcomer owes the arena consumables they were never issued')
end)

-- ========================================================================
-- AND THE ARENA STILL COLLECTS WHEN IT KNOWS WHOSE KIT IT IS
--
-- Refusing everything would pass every test above and cost the operator a
-- free loadout on each round. These two are the other half of the promise.
-- ========================================================================

t.test('CONTROL: with the door off the arena still takes back the kit it can name', function()
    local s = newServer(function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    s.identify(1, 'CID_FIGHTER')
    s.give(1, 'WEAPON_BAT', 1)

    s.ammo.Issue(1, 'm1', {
        weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } },
        supplies = { { item = 'bandage', count = 5 } },
    })
    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 1, 'the fighter was never armed, so this proves nothing')

    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 0, 'the arena did not take its own weapon back')
    t.equals(s.countOf(1, 'bandage'), 0, 'the arena did not take its own bandages back')
    t.equals(s.countOf(1, 'WEAPON_BAT'), 1, 'it took the fighter\'s OWN weapon instead')
end)

t.test('CONTROL: a fighter who keeps the arena\'s weapon is still chased for it', function()
    local s = newServer(function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    s.identify(1, 'CID_FIGHTER')
    s.ammo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } }, supplies = {} })

    -- They drop out with it, and the id goes to somebody else.
    s.recycleId(1, 'CID_STRANGER', {})
    s.ammo.Reclaim(1, 'disconnected')

    t.equals(s.slate(), 'CID_FIGHTER owes WEAPON_PISTOL',
        'the character who walked off with the loadout is not being chased for it')
end)

t.test('REGRESSION: a row the arena cannot name is still chased when it carries a serial', function()
    -- THE GUARD THAT STOPS A STRANGER BEING ROBBED WENT TOO WIDE. The framework
    -- could not answer who was at the door, so the row carries no owner -- but
    -- the inventory read worked, so it DOES carry a serial, and a serial names
    -- one weapon exactly. The fighter it was issued to is still standing here.
    --
    -- Writing that off hands the arena's pistol over for nothing, to anybody
    -- who can make the identity read fail at the door.
    local s = newServer(function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    s.give(1, 'WEAPON_BAT', 1)

    s.blindIdentity(true)
    s.ammo.Issue(1, 'm1', {
        weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } },
        supplies = {},
    })
    s.blindIdentity(false)
    s.identify(1, 'CID_FIGHTER')

    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 1, 'the fighter was never armed, so this proves nothing')

    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 0,
        'the arena wrote off a weapon it could have taken back by serial -- the player keeps it free')
    t.equals(s.countOf(1, 'WEAPON_BAT'), 1,
        'it took the fighter\'s own weapon instead of the one it issued')
end)

t.test('DEFECT: the arena takes back ITS gun, not the fighter\'s own copy of the same weapon', function()
    -- THE ONE CASE THE SERIAL FILTER EXISTS FOR, AND THE ONE CASE NOTHING
    -- HERE SET UP. Every test above hands the fighter a WEAPON_BAT and issues
    -- a WEAPON_PISTOL -- two names, so the removal can find the right copy
    -- with the name alone and the filter is never what decides. A removal
    -- given only a name takes whichever slot ox_inventory reaches first, and
    -- with the door off the fighter's own gun is very often the lower slot.
    --
    -- Measured by inverting the filter in takeWeaponBack: the fighter's own
    -- pistol is removed and the arena's is left in their pockets. They lose
    -- their property and keep the arena's, and every count in the suite reads
    -- the same on both sides -- one pistol before, one after.
    local s = newServer(function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    s.identify(1, 'CID_FIGHTER')

    -- Theirs, carried in through a door that is switched off. Nothing ever
    -- stamped it, so it holds no serial.
    s.give(1, 'WEAPON_PISTOL', 1)

    s.ammo.Issue(1, 'm1', {
        weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 30 } },
        supplies = {},
    })
    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 2, 'they should be holding two pistols now -- theirs and the arena\'s')
    t.equals(s.serialsOf(1, 'WEAPON_PISTOL'), 'SER1,none', 'and exactly one of them should carry the arena\'s serial')

    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.countOf(1, 'WEAPON_PISTOL'), 1, 'one pistol should be left')
    t.equals(s.serialsOf(1, 'WEAPON_PISTOL'), 'none',
        'THE ARENA TOOK THE FIGHTER\'S OWN PISTOL AND LEFT ITS OWN IN THEIR POCKETS')
    t.equals(s.slate(), 'nobody', 'and nothing is owed, because the arena has its weapon back')
end)

os.exit(t.summary())
