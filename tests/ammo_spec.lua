--[[
    crimson_arena/tests/ammo_spec.lua

    The real server/ammo.lua, and the one thing it must never do.

    On a server where ammo types are inventory items, this file is the only
    code in the resource that puts an item into a player's pocket. That makes
    it the only code that can duplicate one. An arena that gives out two
    hundred armour-piercing rounds and does not take them back is an ammo
    printer: join, collect, walk out, repeat.

    So these tests are about the ledger, not the giving. Most of them assert on
    the RECORDED CALLS rather than on a balance, for the same reason
    tests/server_spec.lua counts ledger movements: an item handed out twice and
    an item never taken back can leave an inventory looking identical, and only
    the sequence of calls tells them apart.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- A server with the real util and ammo files loaded, and an ox_inventory
--- double that records every call and can be told to refuse.
--- @param mutate fun(config: table)?
--- @return table fixture
local function newServer(mutate)
    local calls, console = {}, {}
    local refuseAdd, refuseRemove, throwOnAdd = false, false, false
    local resourceState = 'started'
    local handlers = {}

    local ox = {
        AddItem = function(_self, src, item, count)
            calls[#calls + 1] = { op = 'add', src = src, item = item, count = count }
            if throwOnAdd then error('ox_inventory blew up') end
            return not refuseAdd
        end,
        RemoveItem = function(_self, src, item, count)
            calls[#calls + 1] = { op = 'remove', src = src, item = item, count = count }
            return not refuseRemove
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
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        calls = calls,
        log = function() return table.concat(console, '\n') end,
        stopResource = function() handlers['onResourceStop']('crimson_arena') end,
        refuseAdd = function(on) refuseAdd = on end,
        refuseRemove = function(on) refuseRemove = on end,
        throwOnAdd = function(on) throwOnAdd = on end,
        setInventoryMissing = function() resourceState = 'missing' end,
        --- Calls of one kind, optionally for one item.
        countOf = function(op, item)
            local n = 0
            for _, c in ipairs(calls) do
                if c.op == op and (not item or c.item == item) then n = n + 1 end
            end
            return n
        end,
        totalOf = function(op, item)
            local n = 0
            for _, c in ipairs(calls) do
                if c.op == op and (not item or c.item == item) then n = n + c.count end
            end
            return n
        end,
    }
end

--- A loadout as Arena.ResolveLoadout produces one, carrying ammo items.
--- @param entries table[] -- { { item, ammo } }
--- @return table
local function loadout(entries)
    local weapons = {}
    for index, entry in ipairs(entries) do
        weapons[index] = {
            key = 'w' .. index,
            weapon = 'WEAPON_TEST' .. index,
            ammo = entry.ammo,
            ammoTypeItem = entry.item,
            components = {},
        }
    end
    return { weapons = weapons, armor = 0, health = 200 }
end

local function enabled(config)
    config.Loadouts.ammoItems.enabled = true
end

-- ========================================================================
-- Off by default
-- ========================================================================

t.test('the shipped config has ammo items switched off', function()
    t.isFalse(newServer().env.Config.Loadouts.ammoItems.enabled,
        'shipping this on with placeholder item names would hand out nothing and look broken')
end)

t.test('with the feature off nothing is given and nothing is asked of the inventory', function()
    local s = newServer()
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    t.equals(#s.calls, 0)
    t.isFalse(s.ammo.IsEnabled())
end)

-- ========================================================================
-- Issuing
-- ========================================================================

t.test('a weapon with an ammo item has it handed over, once, in the right amount', function()
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle-ap', ammo = 60 } }))

    t.equals(s.countOf('add'), 1)
    t.equals(s.calls[1].item, 'ammo-rifle-ap')
    t.equals(s.calls[1].count, 60)
    t.equals(s.calls[1].src, 1)
end)

t.test('a weapon with no ammo item is skipped rather than given a nil item', function()
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = nil, ammo = 60 }, { item = 'ammo-9', ammo = 30 } }))

    t.equals(s.countOf('add'), 1, 'only the one that named an item')
    t.equals(s.calls[1].item, 'ammo-9')
end)

t.test('roundsPerItem rounds UP, so nobody is short-changed', function()
    -- 60 rounds at 30 per box is two boxes. Rounding down would hand somebody
    -- 30 rounds when they asked for 60.
    local s = newServer(function(c)
        enabled(c)
        c.Loadouts.ammoItems.roundsPerItem = 30
    end)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-box', ammo = 60 } }))
    t.equals(s.calls[1].count, 2)

    local odd = newServer(function(c)
        enabled(c)
        c.Loadouts.ammoItems.roundsPerItem = 30
    end)
    odd.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-box', ammo = 61 } }))
    t.equals(odd.calls[1].count, 3, '61 rounds needs a third box')
end)

t.test('an inventory that REFUSES the item does not have it recorded as issued', function()
    -- The bug this exists for: a refused AddItem that got recorded anyway
    -- would have Reclaim later remove an item the player was never given.
    local s = newServer(enabled)
    s.refuseAdd(true)

    local failed = s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    t.equals(#failed, 1, 'the caller is told which weapon has no ammunition')
    t.equals(s.ammo.OnLoan(1), 0, 'nothing is on loan, because nothing was given')

    s.refuseAdd(false)
    s.ammo.Reclaim(1)
    t.equals(s.countOf('remove'), 0, 'nothing was taken back, because nothing was handed out')
end)

t.test('an inventory that THROWS is caught and not recorded either', function()
    local s = newServer(enabled)
    s.throwOnAdd(true)

    local ok, failed = pcall(s.ammo.Issue, 1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    t.isTrue(ok, 'a broken inventory script must not take a match start down with it')
    t.equals(#failed, 1)
    t.equals(s.ammo.OnLoan(1), 0)
end)

t.test('ox_inventory not running is reported, not silently ignored', function()
    local s = newServer(enabled)
    s.setInventoryMissing()
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))

    t.equals(#s.calls, 0)
    t.isTrue(s.log():find('ox_inventory', 1, true) ~= nil, 'the console says why nobody got any')
end)

-- ========================================================================
-- Reclaiming -- the whole point
-- ========================================================================

t.test('everything issued comes back on the way out', function()
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({
        { item = 'ammo-rifle-ap', ammo = 60 },
        { item = 'ammo-9', ammo = 30 },
    }))

    t.equals(s.ammo.OnLoan(1), 90)
    s.ammo.Reclaim(1, 'left')

    t.equals(s.totalOf('remove', 'ammo-rifle-ap'), 60)
    t.equals(s.totalOf('remove', 'ammo-9'), 30)
    t.equals(s.ammo.OnLoan(1), 0)
end)

t.test('a second reclaim takes nothing -- counted in CALLS, not in what is held', function()
    -- A double reclaim and a correct one both end with nothing on loan. Only
    -- the call count tells them apart, and a double would take the player's
    -- own ammunition.
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))

    s.ammo.Reclaim(1)
    t.equals(s.countOf('remove'), 1)

    s.ammo.Reclaim(1)
    s.ammo.Reclaim(1)
    t.equals(s.countOf('remove'), 1, 'reclaiming twice must not reach into their own pocket')
end)

t.test('reclaiming from somebody who holds nothing is a silent no-op', function()
    local s = newServer(enabled)
    t.equals(s.ammo.Reclaim(999), 0)
    t.equals(#s.calls, 0)
end)

t.test('an item that cannot be removed is named rather than written off', function()
    -- They fired it, dropped it, or already left. Not an error -- but the
    -- console has to say so, or a teardown that took nothing back reads as a
    -- clean one.
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    s.refuseRemove(true)
    s.ammo.Reclaim(1, 'left the arena')

    t.isTrue(s.log():find('ammo-rifle', 1, true) ~= nil, 'the item is named in the console')
    t.isTrue(s.log():find('left the arena', 1, true) ~= nil, 'so is why it was being taken back')
end)

t.test('reclaimOnExit = false leaves the ammunition with the player', function()
    -- The switch exists for servers that genuinely want the arena to be a
    -- source of ammunition. It must actually do that, and only that.
    local s = newServer(function(c)
        enabled(c)
        c.Loadouts.ammoItems.reclaimOnExit = false
    end)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    s.ammo.Reclaim(1)

    t.equals(s.countOf('remove'), 0)
    t.equals(s.ammo.OnLoan(1), 60, 'still recorded as out, because it is')
end)

-- ========================================================================
-- Whole-match teardown
-- ========================================================================

t.test('ReclaimAll empties a match and reaches every player in it', function()
    local s = newServer(enabled)
    for _, src in ipairs({ 1, 2, 3 }) do
        s.ammo.Issue(src, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    end

    t.equals(s.ammo.ReclaimAll('m1', 'match ended'), 3)
    t.equals(s.totalOf('remove'), 180)
    for _, src in ipairs({ 1, 2, 3 }) do
        t.equals(s.ammo.OnLoan(src), 0, 'player ' .. src)
    end
end)

t.test('Clear REFUSES while anything is still on loan', function()
    -- The same refusal ArenaBetting.Clear makes about escrow, for the same
    -- reason: a record dropped with items outstanding is ammunition nothing
    -- will ever ask for back.
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))

    t.isFalse(s.ammo.Clear('m1'))
    t.equals(s.ammo.OnLoan(1), 60, 'a refused Clear drops nothing')
    t.isTrue(s.log():find('refusing to drop match', 1, true) ~= nil)

    s.ammo.Reclaim(1)
    t.isTrue(s.ammo.Clear('m1'), 'and allows it once everything is back')
end)

t.test('stopping the resource takes back every round in every match', function()
    -- A restart with ammunition on loan hands every player in every arena a
    -- permanent supply.
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    s.ammo.Issue(2, 'm2', loadout({ { item = 'ammo-9', ammo = 30 } }))

    s.stopResource()

    t.equals(s.totalOf('remove'), 90)
    t.equals(s.ammo.OnLoan(1), 0)
    t.equals(s.ammo.OnLoan(2), 0)
end)

t.test('one player in two matches has both lots taken back', function()
    -- Should not happen, and the ledger does not assume it cannot.
    local s = newServer(enabled)
    s.ammo.Issue(1, 'm1', loadout({ { item = 'ammo-rifle', ammo = 60 } }))
    s.ammo.Issue(1, 'm2', loadout({ { item = 'ammo-9', ammo = 30 } }))

    t.equals(s.ammo.OnLoan(1), 90)
    s.ammo.Reclaim(1)
    t.equals(s.ammo.OnLoan(1), 0)
    t.equals(s.totalOf('remove'), 90)
end)

t.test('rubbish arguments are refused rather than recorded', function()
    local s = newServer(enabled)
    s.ammo.Issue(nil, 'm1', loadout({ { item = 'a', ammo = 1 } }))
    s.ammo.Issue(0, 'm1', loadout({ { item = 'a', ammo = 1 } }))
    s.ammo.Issue(1, '', loadout({ { item = 'a', ammo = 1 } }))
    s.ammo.Issue(1, 'm1', 'not a loadout')
    t.equals(#s.calls, 0)
end)

print('ammo_spec')
os.exit(t.summary())
