--[[
    crimson_arena/tests/loadoutkit_spec.lua

    THE KIT, AND THE PROMISE THAT A MATCH CANNOT COST ANYBODY ANYTHING.

    server/ammo.lua is the door. It moves a player's own belongings into a
    real ox_inventory stash, issues them what they picked, hands the stash
    back on the way out, and destroys only what it created. ammo_spec
    covers the door itself -- stashing, returning, the refusals, the
    resource stopping mid-match.

    A mutation sample found twenty-four survivors, and they cluster
    somewhere ammo_spec does not go: the WEAPON metadata, the GUN GAME
    swap, and the arithmetic underneath the ammunition count.

    THE PATTERN THIS FILE IS ABOUT. ox_inventory refuses an item by
    RETURNING FALSE, not by throwing. `pcall` catches the throw and
    reports success either way, so `ok` alone is not an answer -- and
    reading it as one is the defect that once destroyed players'
    belongings: an item ox_inventory refused was removed from the stash on
    the next line. The door was fixed and tested. The two other places
    with the same shape were not:

      issueWeapons        a weapon missing from an operator's ox_inventory
                          data is the single likeliest thing to go wrong
                          here, and the player is in the arena unarmed.

      SwapWeapon          the gun game promotion. Read wrong, a player is
                          recorded as holding a rung they were refused --
                          so the exit tries to take back a weapon they
                          never had, and the ladder moved on without them.

    Both guards are `not (ok and accepted ~= false)`, both had surviving
    mutants, and both are one operator typo away from mattering.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- The real server/ammo.lua with ox_inventory modelled, including the
--- difference between a call that THROWS and one that politely returns
--- false -- which is the whole subject of this file.
--- @param opts table? -- { mutate = fun(config) }
--- @return table fixture
local function newKit(opts)
    opts = opts or {}
    local inv, stashes, console = {}, {}, {}
    local fail = {}
    local calls = {}          -- every AddItem, in order, arguments kept

    local function bucket(id)
        if type(id) == 'number' then
            inv[id] = inv[id] or {}
            return inv[id]
        end
        stashes[id] = stashes[id] or {}
        return stashes[id]
    end

    local ox = {
        RegisterStash = function(_self, id) stashes[id] = stashes[id] or {}; return true end,
        GetInventoryItems = function(_self, id)
            if fail.readStash and type(id) == 'string' then error('cannot read stash') end
            -- NOT A THROW. An ox_inventory build that answers with
            -- something other than a list is not caught by pcall at all --
            -- `ok` is true and the value is rubbish, which is the same
            -- shape as the refusal that once destroyed kits.
            if fail.readStashJunk and type(id) == 'string' then return 'not a list' end
            local out = {}
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata)
            calls[#calls + 1] = { id = id, name = name, count = count, metadata = metadata }
            if fail.giveThrows and type(id) == 'number' then error('ox_inventory fell over') end
            -- REFUSED, not thrown: a full stash, or an item the operator's
            -- ox_inventory data has never heard of.
            if fail.giveRefuses and type(id) == 'number' then return false end
            if fail.refuseNamed and fail.refuseNamed[name] then return false end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = metadata }
            return true
        end,
        --- HOW MANY OF ONE ITEM A PLAYER REALLY HOLDS. Modelled because the
        --- reclaim asks: a supply exists to be spent, so what was issued and
        --- what is still there are different numbers, and taking back the
        --- first from a player holding the second is how a build refuses the
        --- whole removal.
        GetItemCount = function(_self, id, name)
            if fail.noCounter then error('this build has no GetItemCount') end
            local total = 0
            for _, item in ipairs(bucket(id)) do
                if item.name == name then total = total + (tonumber(item.count) or 1) end
            end
            return total
        end,
        RemoveItem = function(_self, id, name, count)
            local from = bucket(id)
            -- COUNT-AWARE, and refusing outright when there are not enough,
            -- which is what ox_inventory really does. A fixture that removes
            -- one entry whatever it was asked for cannot see the defect this
            -- models.
            local held = 0
            for _, item in ipairs(from) do
                if item.name == name then held = held + (tonumber(item.count) or 1) end
            end
            local wanted = tonumber(count) or 1
            if held < wanted then return false end

            local left = wanted
            for index = #from, 1, -1 do
                if from[index].name == name and left > 0 then
                    local have = tonumber(from[index].count) or 1
                    if have <= left then
                        left = left - have
                        table.remove(from, index)
                    else
                        from[index].count = have - left
                        left = 0
                    end
                end
            end
            return true
        end,
        ClearInventory = function(_self, id)
            if type(id) == 'number' then inv[id] = {} else stashes[id] = {} end
            return true
        end,
        registerHook = function() return true end,
    }

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        Wait = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function() end,
        CreateThread = function(fn) fn() end,
        TriggerClientEvent = function() end,
        GetPlayers = function() return {} end,
        print = function(line) console[#console + 1] = tostring(line) end,
        lib = Sandbox.newOxLib(),
    })
    -- The return sweep is a `while true do Wait(...) end`, and the
    -- CreateThread above runs a body straight through. This file is about
    -- what the loadout hands over, not about the door's retry -- which
    -- ammo_spec drives on a stepping runner -- so it is switched off here.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    if opts.mutate then opts.mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    Sandbox.loadInto('../server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        config = env.Config,
        calls = calls,
        breakOn = function(what, value) fail[what] = value == nil and true or value end,
        --- One item as it sits in a player's inventory, metadata and all.
        itemNamed = function(src, name)
            for _, item in ipairs(inv[src] or {}) do
                if item.name == name then return item end
            end
            return nil
        end,
        --- How many of one item a player is holding right now.
        countOf = function(src, name)
            local total = 0
            for _, item in ipairs(inv[src] or {}) do
                if item.name == name then total = total + (tonumber(item.count) or 1) end
            end
            return total
        end,
        --- Every item name a player holds, sorted.
        carrying = function(src)
            local names = {}
            for _, item in ipairs(inv[src] or {}) do names[#names + 1] = item.name end
            table.sort(names)
            return table.concat(names, ',')
        end,
        give = function(src, name, count)
            inv[src] = inv[src] or {}
            inv[src][#inv[src] + 1] = { name = name, count = count }
        end,
        log = function() return table.concat(console, '\n') end,
    }
end

--- A loadout carrying one weapon, with whatever extras a test wants on it.
local function oneWeapon(extra)
    local entry = { key = 'w1', weapon = 'WEAPON_TEST', ammo = 0, components = {} }
    for key, value in pairs(extra or {}) do entry[key] = value end
    return { weapons = { entry }, melee = {} }
end

-- ========================================================================
-- A REFUSAL IS NOT A SUCCESS
-- ========================================================================

t.test('a weapon ox_inventory REFUSES is reported as failed, not issued', function()
    -- The refusal that actually happens: a weapon name that is not in the
    -- operator's ox_inventory data. It does not throw -- it returns false,
    -- and for a long time this resource could not tell that from yes.
    local f = newKit()
    f.breakOn('giveRefuses')

    local failed = f.ammo.Issue(1, 'match-1', oneWeapon())

    t.equals(#failed, 1, 'a weapon ox_inventory refused was reported as issued')
    t.equals(failed[1], 'w1', 'the failure names something other than the loadout key')
    t.equals(f.carrying(1), '', 'a refused weapon ended up in the player\'s hands anyway')
end)

t.test('and one it THROWS on is reported the same way', function()
    local f = newKit()
    f.breakOn('giveThrows')

    local failed = f.ammo.Issue(1, 'match-1', oneWeapon())

    t.equals(#failed, 1, 'a weapon that threw was reported as issued')
end)

t.test('while one it accepts is not reported failed', function()
    -- The control. Without it, "everything is reported failed" passes both
    -- assertions above.
    local f = newKit()

    local failed = f.ammo.Issue(1, 'match-1', oneWeapon())

    t.equals(#failed, 0, 'a weapon that was issued fine was reported as a failure')
    t.equals(f.carrying(1), 'WEAPON_TEST')
end)

t.test('a player issued NOTHING out of a real loadout is called out by name', function()
    -- The silence this replaces: an unarmed player in a live round, and
    -- nothing in the console saying the arena knew.
    local f = newKit()
    f.breakOn('giveRefuses')

    f.ammo.Issue(1, 'match-1', oneWeapon())

    t.contains(f.log(), 'issued NOTHING', 'a player was sent in unarmed with nothing said')
end)

t.test('and a player who got their weapon is NOT', function()
    local f = newKit()
    f.ammo.Issue(1, 'match-1', oneWeapon())
    t.notContains(f.log(), 'issued NOTHING', 'an armed player was reported as unarmed')
end)

t.test('an EMPTY loadout is not reported as a failure to issue', function()
    -- Nothing asked for and nothing given is not the same as everything
    -- refused, and a console line for it is noise on every melee-only or
    -- fists-only round.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', { weapons = {}, melee = {} })

    t.notContains(f.log(), 'issued NOTHING', 'a loadout with no weapons was reported as a failed issue')
end)

-- ========================================================================
-- WHAT RIDES IN THE METADATA
-- ========================================================================

t.test('ammunition is written into the weapon\'s metadata, not handed separately', function()
    -- ox_inventory owns weapons and reconciles the ped against the
    -- inventory, so a magazine given with a native is taken straight back
    -- off. The metadata is the only place it survives.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ ammo = 120 }))

    local item = f.itemNamed(1, 'WEAPON_TEST')
    t.isNotNil(item, 'the weapon was never issued')
    t.equals(item.metadata.ammo, 120, 'the weapon arrived with the wrong magazine')
end)

t.test('and a weapon with no ammunition carries no ammo field at all', function()
    -- Not zero: a zero magazine and an unspecified one are different
    -- things to ox_inventory, and writing zero is a decision nobody made.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ ammo = 0 }))

    t.isNil(f.itemNamed(1, 'WEAPON_TEST').metadata.ammo, 'an unspecified magazine was written as a real value')
end)

t.test('attachments an operator configured reach the item', function()
    -- THE DEFECT THIS REPLACED. client/match.lua applies components with
    -- natives on a server WITHOUT ox_inventory, so a suppressor arrived on
    -- one kind of server and not the other, from the same config line,
    -- with nothing to say why.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'COMPONENT_AT_AR_SUPP', 'COMPONENT_AT_SCOPE' } }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'the attachments were dropped between config and the item')
    t.equals(#parts, 2)
    t.equals(parts[1], 'COMPONENT_AT_AR_SUPP')
end)

t.test('but an EMPTY attachment list is left off entirely', function()
    -- ox_inventory reads an empty components list as a weapon whose
    -- attachments were explicitly removed, which is not the same as one
    -- that was never given any.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = {} }))

    t.isNil(f.itemNamed(1, 'WEAPON_TEST').metadata.components,
        'a weapon with no attachments was issued with its attachments explicitly stripped')
end)

t.test('and a list of nothing but rubbish is left off too', function()
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 42, {}, false } }))

    t.isNil(f.itemNamed(1, 'WEAPON_TEST').metadata.components,
        'junk from config was written into the item as attachments')
end)

t.test('a tint an operator set reaches the item, and a zero does not', function()
    local f = newKit()
    f.ammo.Issue(1, 'match-1', oneWeapon({ tint = 3 }))
    t.equals(f.itemNamed(1, 'WEAPON_TEST').metadata.tint, 3, 'the weapon tint was dropped')

    local g = newKit()
    g.ammo.Issue(1, 'match-1', oneWeapon({ tint = 0 }))
    t.isNil(g.itemNamed(1, 'WEAPON_TEST').metadata.tint, 'tint zero -- meaning none -- was written as a real tint')
end)

-- ========================================================================
-- THE GUN GAME LADDER
-- ========================================================================

--- A player already issued their first rung.
local function onRungOne()
    local f = newKit()
    f.ammo.Issue(1, 'match-1', oneWeapon())
    return f
end

t.test('a promotion takes the old weapon away and hands over the new one', function()
    local f = onRungOne()

    t.isTrue(f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60))

    t.equals(f.carrying(1), 'WEAPON_NEXT', 'the player kept the rung below as well as the new one')
    t.equals(f.itemNamed(1, 'WEAPON_NEXT').metadata.ammo, 60, 'the new rung arrived with no magazine')
end)

t.test('a promotion ox_inventory REFUSES leaves the player on the rung below', function()
    -- THE ASSERTION THIS SECTION EXISTS FOR. `pcall` did not throw, so
    -- `ok` is true and the item was still refused. Report success here and
    -- the player is recorded as holding a weapon they do not have: the
    -- exit tries to take back something that was never issued, and the
    -- ladder has moved on without them.
    local f = onRungOne()
    f.breakOn('refuseNamed', { WEAPON_NEXT = true })

    t.isFalse(f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60),
        'a refused promotion was reported as a successful one')
    t.contains(f.log(), 'keep the rung below')
end)

t.test('and one it throws on does too', function()
    local f = onRungOne()
    f.breakOn('giveThrows')

    t.isFalse(f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60),
        'a promotion that threw was reported as successful')
end)

t.test('a promotion to nothing is refused before anything is taken away', function()
    -- The old weapon is removed first, so a junk `addWeapon` that got
    -- past this would disarm the player entirely.
    local f = onRungOne()

    for _, bad in ipairs({ '', 42, {}, true }) do
        t.isFalse(f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', bad, 60),
            ('%s was accepted as a weapon to promote to'):format(tostring(bad)))
    end
    t.equals(f.carrying(1), 'WEAPON_TEST', 'a junk promotion disarmed the player')
end)

t.test('a promotion with nothing to remove still hands over the new rung', function()
    -- The first rung of a ladder replaces nothing.
    local f = newKit()
    f.ammo.Issue(1, 'match-1', { weapons = {}, melee = {} })

    t.isTrue(f.ammo.SwapWeapon(1, 'match-1', nil, 'WEAPON_FIRST', 30))
    t.equals(f.carrying(1), 'WEAPON_FIRST')
end)

--- A player on rung one with the DOOR OFF -- no stash, so nothing is
--- wholesale-cleared on the way out and the exit has to take the arena's
--- weapons back BY NAME, off the issued record. That record is what these
--- two tests are about, and it is the only route that can see it.
local function onRungOneNoStash()
    local f = newKit({ mutate = function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end })
    f.ammo.Issue(1, 'match-1', oneWeapon())
    return f
end

t.test('the swap FORGETS the old weapon, so the exit does not chase it', function()
    -- Removed and forgotten are two different lists. Remembered after
    -- removal, the exit tries to take back a weapon the ladder already
    -- took -- and on a name that collides with something of the player's
    -- own, it takes THEIRS.
    local f = onRungOneNoStash()
    f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60)

    -- The player's own copy of the same weapon, bought before the match.
    f.give(1, 'WEAPON_TEST', 1)
    f.ammo.Reclaim(1, 'test')

    t.equals(f.carrying(1), 'WEAPON_TEST',
        'the exit took back the player\'s OWN weapon, chasing one the ladder had already removed')
end)

t.test('and REMEMBERS the new one, so the exit does take that back', function()
    -- The other half. Given but not remembered, the arena's own ladder
    -- weapon walks out in the player's pocket -- a weapon shop with extra
    -- steps.
    local f = onRungOneNoStash()
    f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60)

    f.ammo.Reclaim(1, 'test')

    t.equals(f.carrying(1), '', 'a ladder weapon left the arena with the player')
end)

t.test('a swap with no ox_inventory changes nothing and says no', function()
    local f = newKit()
    f.env.GetResourceState = function() return 'missing' end

    t.isFalse(f.ammo.SwapWeapon(1, 'match-1', 'WEAPON_TEST', 'WEAPON_NEXT', 60))
end)

-- ========================================================================
-- HOW MANY ROUNDS ONE ITEM IS WORTH
-- ========================================================================

--- Issues 30 SPARE rounds of a real ammo item with `per` rounds to an item.
---
--- SIXTY PICKED, THIRTY SPARE. The pick is a total now: one magazine goes
--- into the gun and only what is left over becomes items, so a weapon asked
--- for exactly one magazine hands over nothing at all and there would be no
--- item here to count. Sixty against the default magazine of thirty leaves
--- thirty spare, which is the amount every expectation below is written for.
--- @return table? item -- the ammunition as it reached the player
local function ammoIssuedWith(per)
    local f = newKit({ mutate = function(config)
        config.Loadouts.ammoItems.enabled = true
        config.Loadouts.ammoItems.roundsPerItem = per
    end })
    f.ammo.Issue(1, 'match-1', {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 60, ammoTypeItem = 'ammo_rifle', components = {} } },
        melee = {},
    })
    return f.itemNamed(1, 'ammo_rifle')
end

t.test('rounds are converted to items by rounding UP', function()
    -- Rounding down hands somebody 59 rounds when they asked for 60 and an
    -- item is worth 30.
    t.equals(ammoIssuedWith(30).count, 1, '30 rounds at 30 a item is not one item')
    t.equals(ammoIssuedWith(20).count, 2, '30 rounds at 20 a item was rounded DOWN to one')
    t.equals(ammoIssuedWith(7).count, 5, '30 rounds at 7 a item is not five items')
end)

t.test('and an operator asking for ZERO rounds per item is floored to one', function()
    -- ZERO IS A DIVISOR HERE. Without the floor this is 30/0 -- infinity
    -- in Lua, not an error -- and the player is handed an item count that
    -- is not a number at all. An assertion of "at least one" passes
    -- against that quite happily, which is why this one is exact.
    local item = ammoIssuedWith(0)

    t.isNotNil(item, 'no ammunition was issued at all')
    t.equals(item.count, 30, 'a roundsPerItem of zero did not fall back to one round an item')
    t.isTrue(item.count == math.floor(item.count), 'the item count is not a whole number')
    t.isTrue(item.count < math.huge, 'the item count is INFINITE -- roundsPerItem was divided by zero')
end)

t.test('and a negative one is floored the same way', function()
    local item = ammoIssuedWith(-50)

    t.isNotNil(item, 'no ammunition was issued at all')
    t.equals(item.count, 30, 'a negative roundsPerItem did not fall back to one round an item')
    t.isTrue(item.count > 0, 'a negative roundsPerItem produced a negative item count')
end)

t.test('and a missing one is too, rather than raising', function()
    local item = ammoIssuedWith(nil)
    t.isNotNil(item, 'no ammunition was issued when roundsPerItem was unset')
    t.equals(item.count, 30)
end)

-- ========================================================================
-- WHO IS ASKING
-- ========================================================================

t.test('rubbish where a server id belongs issues nothing', function()
    local f = newKit()
    for _, bad in ipairs({ 0, -1, '1', {}, false }) do
        t.equals(#f.ammo.Issue(bad, 'match-1', oneWeapon()), 0,
            ('%s was accepted as a server id'):format(tostring(bad)))
    end
    t.equals(#f.calls, 0, 'ox_inventory was called for a player who does not exist')
end)

t.test('and rubbish where a match id belongs does too', function()
    local f = newKit()
    for _, bad in ipairs({ '', 42, {}, true }) do
        t.equals(#f.ammo.Issue(1, bad, oneWeapon()), 0,
            ('%s was accepted as a match id'):format(tostring(bad)))
    end
    t.equals(#f.calls, 0, 'ox_inventory was called for a match that does not exist')
end)

t.test('a loadout that is not a table issues nothing rather than raising', function()
    local f = newKit()
    for _, bad in ipairs({ 'loadout', 42, true }) do
        t.equals(#f.ammo.Issue(1, 'match-1', bad), 0)
    end
end)


-- ========================================================================
-- WHEN THE STASH CANNOT BE READ
--
-- The stash is the promise. If it cannot even be opened, the one thing
-- that must not happen is the player being told their kit came back.
-- ========================================================================

t.test('a stash that cannot be read leaves the kit in it and says so', function()
    local f = newKit()
    f.give(1, 'phone', 1)
    f.give(1, 'water', 1)
    f.ammo.Issue(1, 'match-1', oneWeapon())

    f.breakOn('readStash')
    local returned = f.ammo.Reclaim(1, 'test')

    t.equals(returned, 0, 'a kit that could not be read was reported as returned')
    t.contains(f.log(), 'STILL IN IT', 'the console does not say where the player\'s kit is')
    t.contains(f.log(), 'can be opened', 'the console does not say the stash is a real one they can be pointed at')
end)

t.test('and a stash that reads fine reports the kit as returned', function()
    -- The control: without it, "returns 0" passes against a door that
    -- never reports success at all.
    local f = newKit()
    f.give(1, 'phone', 1)
    f.ammo.Issue(1, 'match-1', oneWeapon())

    local returned = f.ammo.Reclaim(1, 'test')

    t.equals(returned, 1, 'a kit that came back fine was reported as still stashed')
    t.equals(f.carrying(1), 'phone', 'the player did not get their own kit back')
end)

t.test('an item ox_inventory refuses to hand back stays in the stash', function()
    -- THE GUARANTEE. Read the refusal as success and the next line removes
    -- it from the stash -- so the one thing the stash exists to prevent,
    -- that nothing is destroyed, happens here.
    local f = newKit()
    f.give(1, 'phone', 1)
    f.ammo.Issue(1, 'match-1', oneWeapon())

    f.breakOn('refuseNamed', { phone = true })
    local returned = f.ammo.Reclaim(1, 'test')

    t.equals(returned, 0, 'a kit with an item still stuck in it was reported as returned')
    t.equals(f.carrying(1), '', 'the refused item ended up in the player\'s hands anyway')
    t.contains(f.log(), 'still in stash', 'the console does not say the item is still recoverable')
end)

t.test('rubbish where a server id belongs is refused rather than compared', function()
    -- The guard is two conditions and the ORDER of them is load-bearing:
    -- reach `src <= 0` with a string and Lua raises on the comparison
    -- rather than returning.
    local f = newKit()
    for _, bad in ipairs({ '1', {}, true }) do
        t.equals(f.ammo.Reclaim(bad, 'test'), 0,
            ('%s was accepted as a server id on the way out'):format(tostring(bad)))
    end
    t.equals(f.ammo.Reclaim(nil, 'test'), 0)
    t.equals(f.ammo.Reclaim(0, 'test'), 0)
end)

-- ========================================================================
-- AN EMPTY GUN, ON A SERVER THAT DOES NOT ARM ONE
-- ========================================================================

t.test('a weapon whose rounds could not be issued is taken back', function()
    -- allowWeaponWithoutAmmoItem = false means what it says. The WEAPON is
    -- taken back rather than the player ejected: unwinding a dispatch
    -- flag, a routing bucket and a stash mid-placement is how players get
    -- stranded.
    local f = newKit({ mutate = function(config)
        config.Loadouts.ammoItems.enabled = true
        config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem = false
    end })
    f.breakOn('refuseNamed', { ammo_rifle = true })

    -- SIXTY, so there are spare rounds to refuse. A weapon picked at one
    -- magazine has nothing left over to issue as items, so nothing can be
    -- refused and this setting is never reached -- correctly, because that
    -- gun is carrying every round the player asked for.
    f.ammo.Issue(1, 'match-1', {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 60, ammoTypeItem = 'ammo_rifle', components = {} } },
        melee = {},
    })

    t.equals(f.carrying(1), '', 'the player was armed with a gun it cannot reload')
    t.contains(f.log(), 'does not arm an empty gun')
end)

t.test('and the same server leaves an ARMED player alone', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.ammoItems.enabled = true
        config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem = false
    end })

    f.ammo.Issue(1, 'match-1', {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 30, ammoTypeItem = 'ammo_rifle', components = {} } },
        melee = {},
    })

    t.contains(f.carrying(1), 'WEAPON_TEST', 'a properly armed player had their weapon taken away')
end)

t.test('a server that DOES arm an empty gun leaves the weapon there', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.ammoItems.enabled = true
        config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem = true
    end })
    f.breakOn('refuseNamed', { ammo_rifle = true })

    f.ammo.Issue(1, 'match-1', {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 30, ammoTypeItem = 'ammo_rifle', components = {} } },
        melee = {},
    })

    t.contains(f.carrying(1), 'WEAPON_TEST',
        'a weapon was confiscated on a server that allows an empty one')
end)


t.test('a stash that answers with something that is not a list is refused too', function()
    -- pcall does not catch this: the call returned normally, it just
    -- returned rubbish. Checking only that it did not throw walks the
    -- return value as though it were a list of items and returns success
    -- having handed the player nothing.
    local f = newKit()
    f.give(1, 'phone', 1)
    f.ammo.Issue(1, 'match-1', oneWeapon())

    f.breakOn('readStashJunk')
    local returned = f.ammo.Reclaim(1, 'test')

    t.equals(returned, 0, 'a stash that answered with rubbish was reported as returned')
    t.contains(f.log(), 'STILL IN IT')
end)

t.test('a confiscated weapon is FORGOTTEN as well as taken back', function()
    -- Same rule as the ladder swap, on the other path that removes a
    -- weapon mid-match. Taken back but still remembered, the exit removes
    -- it a second time -- and on a name that collides with something of
    -- the player's own, it removes theirs.
    local f = newKit({ mutate = function(config)
        config.Loadouts.inventory.stripOnEntry = false
        config.Loadouts.ammoItems.enabled = true
        config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem = false
    end })
    f.breakOn('refuseNamed', { ammo_rifle = true })

    f.ammo.Issue(1, 'match-1', {
        weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 60, ammoTypeItem = 'ammo_rifle', components = {} } },
        melee = {},
    })
    t.equals(f.carrying(1), '', 'the unreloadable gun was not confiscated in the first place')

    -- The player's own copy of the same weapon, bought before the match.
    f.give(1, 'WEAPON_TEST', 1)
    f.ammo.Reclaim(1, 'test')

    t.equals(f.carrying(1), 'WEAPON_TEST',
        'the exit took the player\'s OWN weapon, chasing one already confiscated')
end)

-- ======================================================================
-- SUPPLIES -- the spare plate and the bandage
--
-- A DIFFERENT PROMISE FROM THE AMMUNITION, and the difference is what a
-- player DOES with them. Rounds come back because nobody spends an item to
-- fire; a plate and a bandage exist to be spent, so what was issued and what
-- is still held are different numbers by the time the round ends. Ask
-- ox_inventory to take back two bandages from somebody holding none and it
-- refuses the whole removal -- so the arena would take back nothing at all
-- from exactly the players who used the most, which is the free-item shop
-- this record exists to close, arriving through the one path nobody would
-- think to test.
-- ======================================================================

--- A loadout carrying one weapon and whatever supplies a test names.
local function withSupplies(...)
    local kit = oneWeapon()
    kit.supplies = { ... }
    return kit
end

t.test('the supplies a player picked are handed over', function()
    local f = newKit()
    f.ammo.Issue(7, 'm1', withSupplies(
        { key = 'armour', item = 'armour', count = 2 },
        { key = 'bandage', item = 'bandage', count = 3 }))

    t.equals(f.countOf(7, 'armour'), 2, 'the plates were not handed over')
    t.equals(f.countOf(7, 'bandage'), 3, 'the bandages were not handed over')
end)

t.test('and they do not depend on ammunition being handed out as items', function()
    -- TWO DIFFERENT SETTINGS IN TWO DIFFERENT BLOCKS. ammoItems answers "is
    -- this server handing out ROUNDS as items", which is a question about
    -- ammunition. A server keeping its ammunition in the weapon's metadata
    -- can still want a fighter to carry a spare plate.
    local f = newKit()
    f.config.Loadouts.ammoItems.enabled = false
    f.ammo.Issue(7, 'm1', withSupplies({ key = 'armour', item = 'armour', count = 1 }))

    t.equals(f.countOf(7, 'armour'), 1,
        'switching ammunition items off took the supplies with them')
end)

t.test('A SUPPLY ox_inventory REFUSES DOES NOT COST THE PLAYER THEIR GUN', function()
    -- THE TRAP. `failed` is a list of WEAPON keys: it goes back to
    -- server/match.lua and, with allowWeaponWithoutAmmoItem off, feeds
    -- removeWeaponsByKey. Push a bandage refusal into it and an operator
    -- whose ox_inventory has never heard of `bandage` confiscates every
    -- fighter's rifle, every round, for a missing consumable.
    local f = newKit()
    f.breakOn('refuseNamed', { bandage = true })

    local failed = f.ammo.Issue(7, 'm1', withSupplies({ key = 'bandage', item = 'bandage', count = 2 }))

    t.equals(#failed, 0, 'a refused supply was reported as a failed WEAPON')
    t.isTrue(f.log():find('bandage', 1, true) ~= nil,
        'a supply that could not be handed over was not named in the console')
end)

t.test('what was issued is taken back on the way out', function()
    local f = newKit()
    f.config.Loadouts.inventory.stripOnEntry = false

    f.ammo.Issue(7, 'm1', withSupplies({ key = 'armour', item = 'armour', count = 2 }))
    t.equals(f.countOf(7, 'armour'), 2)

    f.ammo.Reclaim(7)
    t.equals(f.countOf(7, 'armour'), 0, 'the player walked out still holding arena plates')
end)

t.test('THE FARM: a player who SPENT some still has the rest taken back', function()
    -- The whole point. Issued three, used two, holds one. Asking for three
    -- back is refused outright by ox_inventory -- so an exit that removes
    -- what it issued rather than what is there takes back NOTHING, and the
    -- player keeps a bandage every round for as long as they care to.
    local f = newKit()
    f.config.Loadouts.inventory.stripOnEntry = false

    f.ammo.Issue(7, 'm1', withSupplies({ key = 'bandage', item = 'bandage', count = 3 }))
    t.equals(f.countOf(7, 'bandage'), 3)

    -- Two of them used during the round.
    f.env.exports.ox_inventory:RemoveItem(7, 'bandage', 2)
    t.equals(f.countOf(7, 'bandage'), 1)

    f.ammo.Reclaim(7)
    t.equals(f.countOf(7, 'bandage'), 0,
        'a player who used most of their supplies kept the remainder')
end)

t.test('and a player who spent them ALL is not an error', function()
    local f = newKit()
    f.config.Loadouts.inventory.stripOnEntry = false

    f.ammo.Issue(7, 'm1', withSupplies({ key = 'bandage', item = 'bandage', count = 2 }))
    f.env.exports.ox_inventory:RemoveItem(7, 'bandage', 2)

    f.ammo.Reclaim(7)
    t.equals(f.countOf(7, 'bandage'), 0)
end)

t.test('a build with no counter is asked for the whole amount', function()
    -- Taking back what was issued is the right answer when nothing can say
    -- otherwise, and a refusal there costs the arena nothing it had.
    local f = newKit()
    f.config.Loadouts.inventory.stripOnEntry = false
    f.ammo.Issue(7, 'm1', withSupplies({ key = 'armour', item = 'armour', count = 2 }))
    f.breakOn('noCounter')

    f.ammo.Reclaim(7)
    t.equals(f.countOf(7, 'armour'), 0, 'nothing was taken back on a build with no item counter')
end)

t.test('a second reclaim takes nothing more', function()
    -- The player's OWN plates, bought with their own money, must not be
    -- taken by a record that was never cleared.
    local f = newKit()
    f.config.Loadouts.inventory.stripOnEntry = false

    f.ammo.Issue(7, 'm1', withSupplies({ key = 'armour', item = 'armour', count = 1 }))
    f.ammo.Reclaim(7)

    f.give(7, 'armour', 3)
    f.ammo.Reclaim(7)
    t.equals(f.countOf(7, 'armour'), 3, 'the arena took plates it never issued')
end)

-- ======================================================================
-- WHAT THE SERVER WILL AGREE TO CARRY
-- ======================================================================

t.test('the item name comes from config and never off the wire', function()
    -- The rule ResolveAmmoType follows, for the same reason: an item name
    -- taken from a client is a client choosing what to be given.
    local f = newKit()
    local resolved = f.env.Arena.ResolveSupplies({
        { key = 'armour', count = 1, item = 'gold_bar' },
    })

    -- Every enabled supply comes back -- one the request did not name comes
    -- back at the operator's default, which is what a partial request from
    -- an older panel has to mean. What matters here is the armour row.
    local plates
    for _, entry in ipairs(resolved) do
        if entry.key == 'armour' then plates = entry end
    end
    t.isNotNil(plates, 'the armour row was dropped')
    t.isTrue(plates.item ~= 'gold_bar', 'a client named the item it wanted and got it')
    t.equals(plates.item, 'armour')
end)

t.test('an unknown or disabled key is dropped, and the rest is honoured', function()
    local f = newKit()
    local resolved = f.env.Arena.ResolveSupplies({
        { key = 'nonsense', count = 5 },
        { key = 'armour', count = 1 },
    })

    for _, entry in ipairs(resolved) do
        t.isTrue(entry.key ~= 'nonsense', 'a key nobody configured was carried anyway')
        t.isTrue(entry.item ~= 'nonsense')
    end

    local carried = false
    for _, entry in ipairs(resolved) do
        if entry.key == 'armour' and entry.count == 1 then carried = true end
    end
    t.isTrue(carried, 'the good half of the request was dropped along with the bad')
end)

t.test('a count over the item\'s own max is clamped to it', function()
    local f = newKit()
    local resolved = f.env.Arena.ResolveSupplies({ { key = 'armour', count = 9999 } })

    local max = 0
    for _, entry in ipairs(f.config.Loadouts.supplies.items) do
        if entry.key == 'armour' then max = entry.max end
    end
    t.equals(resolved[1].count, max, 'a client asked for nine thousand plates and got them')
end)

t.test('and the whole list is held to the shared ceiling', function()
    -- A per-item max alone lets a server with six supplies hand one player
    -- every entry's own maximum at once, which is a different match to the
    -- one those numbers describe.
    local f = newKit({ mutate = function(config)
        config.Loadouts.supplies.totalItems = 3
    end })
    local resolved = f.env.Arena.ResolveSupplies({
        { key = 'armour', count = 4 },
        { key = 'bandage', count = 6 },
    })

    local total = 0
    for _, entry in ipairs(resolved) do total = total + entry.count end
    t.isTrue(total <= 3, ('the ceiling of 3 was passed: %d items carried'):format(total))
end)

t.test('a negative or fractional count cannot become a negative carry', function()
    local f = newKit()
    for _, bad in ipairs({ -5, -1, 0.4 }) do
        local resolved = f.env.Arena.ResolveSupplies({ { key = 'armour', count = bad } })
        for _, entry in ipairs(resolved) do
            t.isTrue(entry.count >= 0, ('%s produced a count of %d'):format(tostring(bad), entry.count))
        end
    end
end)

t.test('with the section off, nothing is carried whatever the client asks', function()
    local f = newKit({ mutate = function(config) config.Loadouts.supplies.enabled = false end })
    t.equals(#f.env.Arena.ResolveSupplies({ { key = 'armour', count = 4 } }), 0)
end)

t.test('and with choosing off, everybody carries the operator\'s defaults', function()
    local f = newKit({ mutate = function(config) config.Loadouts.supplies.allowChoose = false end })
    local resolved = f.env.Arena.ResolveSupplies({ { key = 'armour', count = 0 } })

    local byKey = {}
    for _, entry in ipairs(resolved) do byKey[entry.key] = entry.count end
    for _, entry in ipairs(f.config.Loadouts.supplies.items) do
        if entry.default > 0 then
            t.equals(byKey[entry.key], entry.default,
                ('%s did not fall back to the operator default'):format(entry.key))
        end
    end
end)

t.test('THE VITALS ARE A RULE, not a field a client can send', function()
    -- Full health and a full plate on every life, whatever the request says
    -- and whatever config says -- there is no longer a config key for either.
    local f = newKit()
    local fullHealth, fullArmour = f.env.Arena.StartingVitals()

    local loadout = f.env.Arena.ResolveLoadout({ weapons = {}, armor = 0, health = 1 })
    t.equals(loadout.health, fullHealth)
    t.equals(loadout.armor, fullArmour)
    t.equals(fullHealth, 200)
    t.equals(fullArmour, 100)
end)

os.exit(t.summary())
