--[[
    crimson_arena/tests/ammo_spec.lua

    The door: what a player may bring into the arena, and what leaves with them.

    THE PROMISE. Nobody brings their own kit in. A player's whole inventory
    goes into a private stash at the door, they are given only what the loadout
    screen issued, and on the way out everything they are carrying is destroyed
    and their own inventory handed back.

    That is stronger than reconciling counts, and the difference is everything
    a match can produce. Reconciling can put a player back to what they started
    with. This makes the question not arise -- there is nothing in their
    pockets at the end that was not issued, because there was nothing in them
    at the start. Looting a body, scavenging off the floor and hoarding all
    come out in the wash.

    THE FAILURE MODE THAT MATTERS. This is the only code in the resource that
    holds somebody's entire inventory. Losing it is not a bug you get to
    apologise for. So the tests below care less about the happy path than about
    every way stowing can fail: in each one the player must keep their own kit
    and simply not be stripped. "The arena did not work properly" is an
    acceptable outcome. "Your inventory is gone" is not.

    The inventory double holds REAL CONTENTS rather than recording calls,
    because the thing worth asserting is where a player's things end up.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param pockets table<number, table[]>? -- { [src] = { {name, count, metadata} } }
--- @param mutate fun(config: table)?
--- @return table fixture
local function newServer(pockets, mutate)
    local inv, console, handlers, hooks = {}, {}, {}, {}
    local stashes = {}
    local fail = {}     -- which operation to break: register/read/stash/clear/give

    for src, items in pairs(pockets or {}) do
        inv[src] = {}
        for _, item in ipairs(items) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count, metadata = item.metadata }
        end
    end

    local function bucket(id)
        if type(id) == 'number' then
            inv[id] = inv[id] or {}
            return inv[id]
        end
        stashes[id] = stashes[id] or {}
        return stashes[id]
    end

    local ox = {
        RegisterStash = function(_self, id)
            if fail.register then error('no stash for you') end
            stashes[id] = stashes[id] or {}
            return true
        end,
        GetInventoryItems = function(_self, id)
            if fail.read and type(id) == 'number' then error('cannot read') end
            if fail.readStash and type(id) == 'string' then error('cannot read stash') end
            local out = {}
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata)
            if fail.stash and type(id) == 'string' then error('stash is full') end
            if fail.give and type(id) == 'number' then return false end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = metadata }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            local from = bucket(id)
            for index = #from, 1, -1 do
                if from[index].name == name and from[index].count == count then
                    table.remove(from, index)
                    return true
                end
            end
            return false
        end,
        ClearInventory = function(_self, id)
            if fail.clear and type(id) == 'number' then error('cannot clear') end
            if type(id) == 'number' then inv[id] = {} else stashes[id] = {} end
            return true
        end,
        registerHook = function(_self, name, fn)
            if fail.hook then error('this build has no hooks') end
            hooks[name] = fn
            return true
        end,
    }

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        CreateThread = function(fn) fn() end,
        TriggerClientEvent = function() end,
        print = function(line) console[#console + 1] = line end,
        lib = Sandbox.newOxLib(),
        ArenaGetPlayer = function(src)
            return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
        end,
    })
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    Sandbox.loadInto('../server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        --- Every item name a player is holding, sorted, as a comparable string.
        carrying = function(src)
            local names = {}
            for _, item in ipairs(inv[src] or {}) do names[#names + 1] = item.name end
            table.sort(names)
            return table.concat(names, ',')
        end,
        --- One item as it actually sits in the inventory, metadata and all.
        --- `carrying` flattens to names, which is the right shape for asking
        --- WHAT somebody holds and useless for asking what state it is in --
        --- and a weapon's magazine lives in its metadata.
        itemNamed = function(src, name)
            for _, item in ipairs(inv[src] or {}) do
                if item.name == name then return item end
            end
            return nil
        end,
        stashContents = function(src)
            local names = {}
            for _, item in ipairs(stashes['crimson_arena_CID' .. tostring(src)] or {}) do
                names[#names + 1] = item.name
            end
            table.sort(names)
            return table.concat(names, ',')
        end,
        give = function(src, name, count)
            inv[src] = inv[src] or {}
            inv[src][#inv[src] + 1] = { name = name, count = count }
        end,
        breakOn = function(what) fail[what] = true end,
        hook = function(name) return hooks[name] end,
        log = function() return table.concat(console, '\n') end,
        stopResource = function() handlers['onResourceStop']('crimson_arena') end,
    }
end

--- @return table
local function loadoutOf(item, ammo)
    return {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = ammo, ammoTypeItem = item, components = {} } },
        armor = 100, health = 200,
    }
end

local OWN = { { name = 'phone', count = 1 }, { name = 'water', count = 2 } }

-- ========================================================================
-- The door
-- ========================================================================

t.test('a player walks in with nothing of their own', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), '', 'their pockets are empty inside the arena')
    t.equals(s.stashContents(1), 'phone,water', 'and their kit is safe in their stash')
    t.isTrue(s.ammo.IsHolding(1))
end)

t.test('and walks out with exactly what they walked in with', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.carrying(1), 'phone,water')
    t.equals(s.stashContents(1), '', 'nothing left behind in the stash')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('everything the arena gave them is destroyed on the way out', function()
    local s = newServer({ [1] = OWN }, function(c) c.Loadouts.ammoItems.enabled = true end)
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle-ap', 250))

    -- THE WEAPON IS AN ITEM TOO, and this line is the change. On an
    -- ox_inventory server a weapon handed to the ped is reconciled straight
    -- back off the player, because ox_inventory decides what a ped holds
    -- from what the inventory contains -- and the door has just emptied it.
    -- So the arena issues the weapon here, as an item, and the client no
    -- longer touches the ped. Before this the assertion read
    -- 'ammo-rifle-ap' alone and every player spawned unarmed.
    t.equals(s.carrying(1), 'WEAPON_TEST,ammo-rifle-ap',
        'in the arena they have the issued weapon and the issued round, and nothing of their own')
    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.carrying(1), 'phone,water', 'and none of it leaves with them -- weapon included')
end)

t.test('ammunition LOOTED off a body does not leave either', function()
    local s = newServer({ [1] = OWN }, function(c) c.Loadouts.ammoItems.enabled = true end)
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle-ap', 100))

    -- They kill somebody and empty their pockets.
    s.give(1, 'ammo-rifle-ap', 500)
    s.give(1, 'gold-bar', 3)

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.carrying(1), 'phone,water', 'the arena is not a way to carry anything out of it')
end)

t.test('a player who owned nothing gets nothing back', function()
    local s = newServer(nil, function(c) c.Loadouts.ammoItems.enabled = true end)
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.equals(s.carrying(1), 'WEAPON_TEST,ammo-rifle', 'the weapon is issued as an item as well')

    s.ammo.Reclaim(1)
    t.equals(s.carrying(1), '')
end)

-- ========================================================================
-- THE WEAPON IS AN ITEM
--
-- The bug this covers spawned every player in the arena unarmed, on the
-- exact configuration this resource was written for.
--
-- Two of my own features collided. ox_inventory owns weapons: it decides
-- what a ped holds from what the inventory contains, and reconciles the two
-- continuously. The door empties the player's inventory into a stash on
-- entry. So a weapon handed to the ped by the client was a weapon with no
-- item behind it, and ox_inventory took it straight back off them -- with
-- nothing in any console, because neither half was doing anything wrong.
--
-- The weapon is issued as an ITEM now, from the server, magazine in its
-- metadata, and the client does not touch the ped when ox_inventory is
-- running. These tests are about the item, which is the part that decides
-- whether a player is armed.
-- ========================================================================

t.test('the loadout weapon is handed over as an item, not left to the ped', function()
    -- Deliberately with ammo items OFF -- the shipped setting. Weapons must
    -- not be behind that toggle: putting them there is what would leave a
    -- default install issuing nobody anything at all.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    t.equals(s.carrying(1), 'WEAPON_TEST',
        'the weapon did not arrive as an item, so ox_inventory will disarm the player on sight')
end)

t.test('the magazine rides in the item metadata rather than being set on the ped', function()
    -- SetPedAmmo is reconciled away exactly like the weapon, so a weapon
    -- whose rounds are not in its metadata arrives empty.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    local weapon = s.itemNamed(1, 'WEAPON_TEST')
    t.isNotNil(weapon, 'no weapon item to inspect')
    t.equals(weapon.metadata and weapon.metadata.ammo, 60,
        'the weapon was issued without its magazine')
end)

t.test('melee is issued with no ammo in its metadata at all', function()
    -- Not zero -- absent. ox_inventory reads a missing ammo key as "this is
    -- not an ammo weapon"; a present zero reads as an empty one.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', {
        weapons = { { key = 'blade', weapon = 'WEAPON_TEST', ammo = 0, components = {} } },
        armor = 100, health = 200,
    })

    local weapon = s.itemNamed(1, 'WEAPON_TEST')
    t.isNotNil(weapon)
    t.isNil(weapon.metadata and weapon.metadata.ammo,
        'a blade was issued carrying a magazine')
end)

t.test('DEFECT: with the door OFF the arena weapon has to be taken back by name', function()
    -- The door is what usually destroys the arena kit: it clears the whole
    -- inventory on the way out. Switch it off and nothing does -- Reclaim
    -- returned early the moment it found no stash, so every weapon the arena
    -- issued stayed in the player's pockets, permanently, and the arena
    -- became a weapon shop.
    local s = newServer({ [1] = OWN }, function(c)
        c.Loadouts.inventory.stripOnEntry = false
    end)

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.equals(s.carrying(1), 'WEAPON_TEST,phone,water',
        'with the door off they keep their own kit AND get the arena weapon')

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.carrying(1), 'phone,water',
        'the arena weapon left with them -- the arena is now a way to acquire guns')
end)

t.test('and taking it back does not touch anything of the player\'s own', function()
    local s = newServer({ [1] = OWN }, function(c)
        c.Loadouts.inventory.stripOnEntry = false
    end)

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.carrying(1), 'phone,water', 'their own kit is untouched, in order')
end)

-- ========================================================================
-- Every way stowing can fail -- the player must keep their kit
-- ========================================================================

t.test('a stash that will not register leaves them carrying their own kit', function()
    local s = newServer({ [1] = OWN })
    s.breakOn('register')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water', 'not stripped, because it could not be put anywhere safe')
    t.isFalse(s.ammo.IsHolding(1), 'and nothing is owed back to them')
    t.isTrue(s.log():find('keep their own kit', 1, true) ~= nil)
end)

t.test('an inventory that cannot be read leaves them carrying their own kit', function()
    local s = newServer({ [1] = OWN })
    s.breakOn('read')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('a stash that fills up halfway puts back what already moved', function()
    -- The worst shape of failure: an inventory split across two places, with
    -- the player holding half of it and no record of the rest.
    local s = newServer({ [1] = OWN })
    s.breakOn('stash')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water', 'still all theirs')
    t.equals(s.stashContents(1), '', 'and nothing stranded in the stash')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('a clear that fails after stashing puts everything back', function()
    local s = newServer({ [1] = OWN })
    s.breakOn('clear')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water')
    t.equals(s.stashContents(1), '', 'the stash was emptied again rather than left holding a copy')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('a player with no citizen id is not stripped', function()
    local s = newServer({ [1] = OWN })
    s.env.ArenaGetPlayer = function() return nil end
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('a stash that cannot be read back leaves the kit IN it, and says where', function()
    -- Not recoverable here, but not lost either: it is a real ox_inventory
    -- stash and an admin can open it. The console has to name it.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.breakOn('readStash')
    s.ammo.Reclaim(1, 'match ended')

    t.isTrue(s.log():find('crimson_arena_CID1', 1, true) ~= nil, 'the stash is named in the console')
    t.isTrue(s.log():find('STILL IN IT', 1, true) ~= nil)
end)

-- ========================================================================
-- Not making things worse
-- ========================================================================

t.test('a second reclaim does not touch them again', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Reclaim(1)
    s.give(1, 'rifle-they-bought-afterwards', 1)

    s.ammo.Reclaim(1)
    s.ammo.Reclaim(1)
    t.equals(s.carrying(1), 'phone,rifle-they-bought-afterwards,water')
end)

t.test('a player who never entered is left alone', function()
    local s = newServer({ [2] = OWN })
    t.equals(s.ammo.Reclaim(2), 0)
    t.equals(s.carrying(2), 'phone,water')
end)

t.test('stripOnEntry = false lets them bring their own kit in', function()
    local s = newServer({ [1] = OWN }, function(c) c.Loadouts.inventory.stripOnEntry = false end)
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water')
    t.isFalse(s.ammo.IsHolding(1), 'nothing was taken, so nothing is owed')
end)

-- ========================================================================
-- Dropping
-- ========================================================================

t.test('a player in a match cannot drop anything', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    local hook = s.hook('swapItems')
    t.isNotNil(hook, 'the drop guard should be registered')
    t.isFalse(hook({ source = 1, toInventory = 'drop-7' }), 'a drop is refused')
    t.isTrue(hook({ source = 1, toInventory = 1 }), 'moving things around their own pockets is fine')
end)

t.test('a player outside the arena drops whatever they like', function()
    local s = newServer({ [1] = OWN })
    local hook = s.hook('swapItems')
    t.isTrue(hook({ source = 1, toInventory = 'drop-7' }))
end)

t.test('an ox_inventory with no hooks degrades to allowing drops, loudly', function()
    local s = newServer({ [1] = OWN })
    s.breakOn('hook')
    -- Reload so the registration runs against the broken double.
    Sandbox.loadInto('../server/ammo.lua', s.env)
    t.isTrue(s.log():find('would not take a swapItems hook', 1, true) ~= nil)
end)

-- ========================================================================
-- Teardown
-- ========================================================================

t.test('ReclaimAll returns the kit of everybody in one match', function()
    local s = newServer({ [1] = OWN, [2] = OWN, [3] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Issue(2, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Issue(3, 'm2', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.ammo.ReclaimAll('m1', 'match ended'), 2)
    t.equals(s.carrying(1), 'phone,water')
    t.equals(s.carrying(2), 'phone,water')
    t.equals(s.carrying(3), '', 'the other match is still running')
end)

t.test('Clear REFUSES while anybody is still owed their kit', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.isFalse(s.ammo.Clear('m1'))
    t.isTrue(s.log():find('refusing to drop match', 1, true) ~= nil)

    s.ammo.Reclaim(1)
    t.isTrue(s.ammo.Clear('m1'))
end)

t.test('stopping the resource hands everybody their kit back', function()
    local s = newServer({ [1] = OWN, [2] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Issue(2, 'm2', { weapons = {}, armor = 100, health = 200 })

    s.stopResource()

    t.equals(s.carrying(1), 'phone,water')
    t.equals(s.carrying(2), 'phone,water')
end)

t.test('StashOf names where a kit is, for an admin who has to find it', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.equals(s.ammo.StashOf(1), 'crimson_arena_CID1')

    s.ammo.Reclaim(1)
    t.isNil(s.ammo.StashOf(1))
end)

print('ammo_spec')
os.exit(t.summary())
