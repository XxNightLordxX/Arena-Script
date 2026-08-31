--[[
    crimson_arena/tests/ammo_spec.lua

    The real server/ammo.lua, against a stateful inventory.

    THE PROMISE UNDER TEST: a player leaves the arena with exactly the
    ammunition they walked in with. Not "what we gave them, minus what we took
    back" -- the actual count they held before the match, restored.

    That distinction is the whole file. A ledger of what was ISSUED can take
    back what was issued, and knows nothing about a player who killed somebody
    and emptied their pockets. On a server where ammunition is an inventory
    item, looting is the obvious way to carry a match's worth of rounds out of
    the arena, so the baseline has to be the player's own inventory rather than
    a record of this resource's generosity.

    The inventory double below holds REAL COUNTS rather than recording calls,
    because the thing worth asserting is where a player's pockets end up.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- @param pockets table<number, table<string, integer>>? -- starting inventories
--- @param mutate fun(config: table)?
--- @return table fixture
local function newServer(pockets, mutate)
    local held = {}
    for src, items in pairs(pockets or {}) do
        held[src] = {}
        for item, count in pairs(items) do held[src][item] = count end
    end

    local console, handlers = {}, {}
    local refuseAdd, refuseRemove, blindTo = false, false, {}
    local resourceState = 'started'

    local ox = {
        Search = function(_self, src, mode, item)
            if blindTo[item] then error('ox_inventory cannot read ' .. item) end
            if mode ~= 'count' then return 0 end
            return (held[src] or {})[item] or 0
        end,
        AddItem = function(_self, src, item, count)
            if refuseAdd then return false end
            held[src] = held[src] or {}
            held[src][item] = (held[src][item] or 0) + count
            return true
        end,
        RemoveItem = function(_self, src, item, count)
            if refuseRemove then return false end
            held[src] = held[src] or {}
            held[src][item] = math.max(0, (held[src][item] or 0) - count)
            return true
        end,
    }

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        GetResourceState = function(name)
            return name == 'ox_inventory' and resourceState or 'missing'
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerClientEvent = function() end,
        print = function(line) console[#console + 1] = line end,
        lib = Sandbox.newOxLib(),
    })
    env.Config.Loadouts.ammoItems.enabled = true
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        holds = function(src, item) return (held[src] or {})[item] or 0 end,
        setHeld = function(src, item, count)
            held[src] = held[src] or {}
            held[src][item] = count
        end,
        log = function() return table.concat(console, '\n') end,
        stopResource = function() handlers['onResourceStop']('crimson_arena') end,
        refuseAdd = function(on) refuseAdd = on end,
        refuseRemove = function(on) refuseRemove = on end,
        blind = function(item) blindTo[item] = true end,
        setInventoryMissing = function() resourceState = 'missing' end,
    }
end

--- The first item name the shipped config can actually hand out, so these
--- tests follow the real catalogue rather than inventing item names it would
--- never reconcile against.
--- @param env table
--- @return string
local function shippedItem(env, index)
    local names = {}
    for item in pairs(env.Arena.AllAmmoItems()) do names[#names + 1] = item end
    table.sort(names)
    return names[index or 1]
end

--- @param item string
--- @param ammo integer
--- @return table
local function loadoutOf(item, ammo)
    return {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = ammo, ammoTypeItem = item, components = {} } },
        armor = 100,
        health = 200,
    }
end

-- ========================================================================
-- Off by default
-- ========================================================================

t.test('the shipped config has ammo items switched off', function()
    local env = Sandbox.newArenaEnv({})
    t.isFalse(env.Config.Loadouts.ammoItems.enabled,
        'shipping this on with placeholder item names hands out nothing and reads as broken')
end)

t.test('with the feature off nobody is snapshotted and nothing moves', function()
    local s = newServer({ [1] = { ['ammo-rifle'] = 40 } }, function(c)
        c.Loadouts.ammoItems.enabled = false
    end)
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    t.equals(s.holds(1, 'ammo-rifle'), 40)
    t.isFalse(s.ammo.IsHolding(1))
end)

-- ========================================================================
-- The promise
-- ========================================================================

t.test('a player leaves with exactly what they arrived with', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 250))
    t.equals(s.holds(1, item), 290, 'they were given the round they picked')

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.holds(1, item), 40, 'and are back to their own forty')
end)

t.test('ammunition LOOTED off a body in the arena does not leave with them', function()
    -- The case a ledger of what-we-issued cannot see, and the reason this file
    -- reconciles against the player's own inventory instead.
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    -- They kill somebody and take everything the body was carrying.
    s.setHeld(1, item, s.holds(1, item) + 500)

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.holds(1, item), 40, 'the arena is not a way to carry rounds out of it')
end)

t.test('their OWN rounds come back even if the match spent them', function()
    -- Arena ammunition is issued first and spent first. A player who walks out
    -- lighter than they walked in would rightly call that a bug.
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    s.setHeld(1, item, 10)   -- fired 130: all 100 issued, and 30 of their own

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.holds(1, item), 40, 'the arena costs them nothing')
end)

t.test('a player who arrived with none leaves with none', function()
    local s = newServer()
    local item = shippedItem(s.env)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 250))
    t.equals(s.holds(1, item), 250)

    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 0)
end)

t.test('items the arena never issued are still reconciled', function()
    -- Looting is not limited to the round you happen to be carrying.
    local s = newServer()
    local mine, theirs = shippedItem(s.env, 1), shippedItem(s.env, 2)
    t.isNotNil(theirs, 'the shipped catalogue should offer more than one item')

    s.setHeld(1, mine, 20)
    s.ammo.Issue(1, 'm1', loadoutOf(mine, 100))
    s.setHeld(1, theirs, 300)      -- taken off a body

    s.ammo.Reclaim(1)
    t.equals(s.holds(1, mine), 20)
    t.equals(s.holds(1, theirs), 0, 'a round they never chose still goes back')
end)

-- ========================================================================
-- Not making things worse
-- ========================================================================

t.test('a second reclaim touches nothing', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 40)

    -- Whatever they pick up afterwards, out in the world, is theirs.
    s.setHeld(1, item, 999)
    s.ammo.Reclaim(1)
    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 999, 'reclaiming twice must not reach into their pocket again')
end)

t.test('a player who never entered is left alone', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(2, item, 500)

    t.equals(s.ammo.Reclaim(2), 0)
    t.equals(s.holds(2, item), 500)
end)

t.test('an item whose count cannot be read is never touched', function()
    -- Guessing zero here would hand somebody a pile of ammunition on the way
    -- out. No change beats a wrong one.
    local s = newServer()
    local item = shippedItem(s.env)
    s.blind(item)
    s.setHeld(1, item, 77)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 177, 'left exactly as found, because it could not be reasoned about')
end)

t.test('an inventory that refuses to give the item back says so', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)
    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))

    s.refuseRemove(true)
    s.ammo.Reclaim(1, 'match ended')
    t.isTrue(s.log():find('could not be taken back', 1, true) ~= nil,
        'a surplus that will not come out is named, not written off')
end)

t.test('ox_inventory not running is reported rather than silently skipped', function()
    local s = newServer()
    s.setInventoryMissing()
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.isTrue(s.log():find('ox_inventory', 1, true) ~= nil)
end)

t.test('reclaimOnExit = false leaves everything with the player', function()
    local s = newServer(nil, function(c) c.Loadouts.ammoItems.reclaimOnExit = false end)
    local item = shippedItem(s.env)
    s.setHeld(1, item, 40)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 140, 'the switch exists for servers that want the arena to be a source')
end)

t.test('roundsPerItem rounds UP so nobody is short-changed', function()
    local s = newServer(nil, function(c) c.Loadouts.ammoItems.roundsPerItem = 30 end)
    local item = shippedItem(s.env)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 61))
    t.equals(s.holds(1, item), 3, '61 rounds at 30 a box needs a third box')
end)

-- ========================================================================
-- Whole-match teardown
-- ========================================================================

t.test('ReclaimAll squares up everybody in one match and nobody in another', function()
    local s = newServer()
    local item = shippedItem(s.env)

    for _, src in ipairs({ 1, 2 }) do
        s.setHeld(src, item, 10)
        s.ammo.Issue(src, 'm1', loadoutOf(item, 100))
    end
    s.setHeld(3, item, 10)
    s.ammo.Issue(3, 'm2', loadoutOf(item, 100))

    t.equals(s.ammo.ReclaimAll('m1', 'match ended'), 2)
    t.equals(s.holds(1, item), 10)
    t.equals(s.holds(2, item), 10)
    t.equals(s.holds(3, item), 110, 'the other match is still running')
end)

t.test('Clear REFUSES while anybody is still unsquared', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))

    t.isFalse(s.ammo.Clear('m1'))
    t.isTrue(s.ammo.IsHolding(1))
    t.isTrue(s.log():find('refusing to drop match', 1, true) ~= nil)

    s.ammo.Reclaim(1)
    t.isTrue(s.ammo.Clear('m1'))
end)

t.test('stopping the resource squares up every arena', function()
    local s = newServer()
    local item = shippedItem(s.env)
    s.setHeld(1, item, 25)
    s.setHeld(2, item, 0)
    s.ammo.Issue(1, 'm1', loadoutOf(item, 100))
    s.ammo.Issue(2, 'm2', loadoutOf(item, 100))

    s.stopResource()

    t.equals(s.holds(1, item), 25)
    t.equals(s.holds(2, item), 0)
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('a snapshot is taken BEFORE anything is handed over', function()
    -- Taken afterwards it would bake the arena's own ammunition into what the
    -- player "arrived with", and they would keep every round of it.
    local s = newServer()
    local item = shippedItem(s.env)

    s.ammo.Issue(1, 'm1', loadoutOf(item, 250))
    s.ammo.Reclaim(1)
    t.equals(s.holds(1, item), 0, 'they arrived with nothing, so they leave with nothing')
end)

t.test('rubbish arguments are refused', function()
    local s = newServer()
    s.ammo.Issue(nil, 'm1', loadoutOf('x', 1))
    s.ammo.Issue(0, 'm1', loadoutOf('x', 1))
    s.ammo.Issue(1, '', loadoutOf('x', 1))
    s.ammo.Issue(1, 'm1', 'not a loadout')
    t.isFalse(s.ammo.IsHolding(1))
end)

print('ammo_spec')
os.exit(t.summary())
