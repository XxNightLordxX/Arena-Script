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
--- @param opts table? -- { inventoryStartsAfter = integer } -- how many Waits
---        ox_inventory takes to come up, for the late-start path
---        { noDispatch = true } -- load with no ArenaDispatch at all, which
---        is what this file sees before server/dispatch.lua has loaded
---        { retry = true } -- run the return sweep on a STEPPING thread
---        runner, so `s.step()` drives one pass. Off by default because this
---        fixture runs a CreateThread body straight through and the sweep is
---        a `while true`, which would never come back.
local function newServer(pockets, mutate, opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local inv, console, handlers, hooks = {}, {}, {}, {}
    -- How many times anything has yielded, which is the only clock this
    -- fixture has and what the late-start test counts against.
    local waits = 0
    local stashes = {}
    -- Which operation to break, and HOW. The distinction is the whole point
    -- of half the tests below: a call that THROWS is caught by pcall, and a
    -- call that RETURNS FALSE is ox_inventory politely refusing -- which for
    -- a long time this resource could not tell from success.
    --   register / read / readStash / stash / clear : throw
    --   stashRefuse / clearRefuse / give            : return false
    local fail = {}

    -- Who the server thinks is online. GetPlayers is what the return sweep
    -- walks, and a player who is not on it is one it never looks at.
    local connected = {}

    -- Which CHARACTER a server id belongs to. Overridable because the stash
    -- is named from the citizen id and not the id, which is the whole reason
    -- somebody can come back on a different one and still be handed their
    -- things -- and there is no way to test that if the two are welded.
    local identity = {}
    local function cidOf(src) return identity[src] or ('CID' .. tostring(src)) end

    -- How many times each stash has been READ. The retry looks once at a
    -- stash nothing in memory knows about, and "once" is a promise about
    -- cost that only a count can hold it to.
    local stashReads = {}

    for src, items in pairs(pockets or {}) do
        connected[src] = true
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
            if type(id) == 'string' then stashReads[id] = (stashReads[id] or 0) + 1 end
            if fail.readStash and type(id) == 'string' then error('cannot read stash') end
            local out = {}
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata)
            if fail.stash and type(id) == 'string' then error('stash is full') end
            -- REFUSED, not thrown. This is what a full stash, or an item the
            -- operator's ox_inventory data does not know, actually does.
            if fail.stashRefuse and type(id) == 'string' then return false end
            if fail.give and type(id) == 'number' then return false end
            -- NO ANSWER AT ALL, which is not the same as a refusal and was
            -- being read as success. The stash is where an item is safe, and
            -- removing it from there on a nil is how it gets destroyed.
            if fail.giveSilent and type(id) == 'number' then return nil end
            -- ONE NAMED ITEM, not everything. A return that fails COMPLETELY
            -- and one that fails PARTLY are different animals: the partial
            -- one has already put some of the player's belongings back in
            -- their pockets and taken them out of the stash, which is the
            -- state the door has to survive being run over a second time.
            if type(fail.refuseNamed) == 'table' and type(id) == 'number'
                and fail.refuseNamed[name] then
                return false
            end
            -- ONLY the ammo item, never the weapon. `give` above refuses
            -- everything a player is handed, so a test using it to break the
            -- ammunition also stops the weapon being issued -- and then
            -- "the player is not carrying that weapon" is true for the wrong
            -- reason.
            if fail.ammoItem and type(id) == 'number'
                and type(name) == 'string' and name:find('^ammo') then
                return false
            end
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
            if fail.clearRefuse and type(id) == 'number' then return false end
            if type(id) == 'number' then inv[id] = {} else stashes[id] = {} end
            return true
        end,
        registerHook = function(_self, name, fn)
            if fail.hook then error('this build has no hooks') end
            hooks[name] = fn
            return true
        end,
    }

    --- Who the dispatch flag says has actually been teleported into a round.
    --- The drop guard asks this rather than the stash, because with the door
    --- off nobody is stashed and every fighter would look like a bystander.
    local placed = {}

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        ArenaDispatch = not opts.noDispatch and {
            Set = function(src) placed[src] = true end,
            Clear = function(src) placed[src] = nil end,
            IsPlayerInArena = function(src) return placed[src] == true end,
        } or nil,
        -- ox_inventory can come up AFTER this resource. Resource start order
        -- is not guaranteed and Crimson-Arena is deliberately asked to start
        -- early, so "not started yet" is an ordinary state and not an error.
        GetResourceState = function(name)
            if name ~= 'ox_inventory' then return 'missing' end
            return waits >= (opts.inventoryStartsAfter or 0) and 'started' or 'missing'
        end,
        Wait = opts.retry and runner.Wait or function() waits = waits + 1 end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        CreateThread = opts.retry and runner.CreateThread or function(fn) fn() end,
        GetPlayers = function()
            local out = {}
            for src in pairs(connected) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        TriggerClientEvent = function() end,
        print = function(line) console[#console + 1] = line end,
        lib = Sandbox.newOxLib(),
        ArenaGetPlayer = function(src)
            return { PlayerData = { citizenid = cidOf(src) } }
        end,
    })
    -- OFF UNLESS A TEST ASKS FOR IT. The retry sweep is a `while true do
    -- Wait(...) end`, and the CreateThread above runs a body to completion,
    -- so leaving the shipped default on would hang every test in this file.
    -- Tests that want it set it back through `mutate`, with opts.retry.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = cidOf(src) } }
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
        breakOn = function(what, value) fail[what] = value == nil and true or value end,
        --- Runs the retry sweep's thread one pass. Two steps is one pass:
        --- the loop's Wait is its first statement, so the first resume only
        --- primes the coroutine. Needs opts.retry.
        step = function() runner.step() end,
        --- Puts a player on the server, so GetPlayers reports them.
        connect = function(src) connected[src] = true end,
        disconnect = function(src) connected[src] = nil end,
        --- The same CHARACTER coming back on a different server id, which is
        --- what a reconnect actually is.
        reconnect = function(oldSrc, newSrc)
            identity[newSrc] = cidOf(oldSrc)
            connected[oldSrc] = nil
            connected[newSrc] = true
        end,
        --- What is in one CHARACTER's stash, by citizen id rather than by
        --- server id -- the only handle that still works across a reconnect.
        --- Puts something into a character's stash directly, with nothing in
        --- this resource's memory knowing about it -- which is exactly the
        --- state a server restart leaves behind.
        putInStash = function(citizenid, name, count)
            local id = 'crimson_arena_' .. citizenid
            stashes[id] = stashes[id] or {}
            stashes[id][#stashes[id] + 1] = { name = name, count = count }
        end,
        stashReadsOf = function(citizenid)
            return stashReads['crimson_arena_' .. citizenid] or 0
        end,
        --- Marks a player as actually being in a round, the way the dispatch
        --- flag does in production.
        place = function(src) placed[src] = true end,
        stashOfCid = function(citizenid)
            local names = {}
            for _, item in ipairs(stashes['crimson_arena_' .. citizenid] or {}) do
                names[#names + 1] = item.name
            end
            table.sort(names)
            return table.concat(names, ',')
        end,
        --- Puts ox_inventory back together, so a retry after a failed
        --- restore can be driven.
        fixOn = function(what) fail[what] = nil end,
        config = env.Config,
        --- What is sitting in one player's arena stash, by name. The stash is
        --- the promise: anything that could not be handed back has to still
        --- be in it, because a player can be pointed at a real ox_inventory
        --- stash and cannot be pointed at a deleted item.
        stashed = function(src)
            local names = {}
            for id, items in pairs(stashes) do
                if tostring(id):find(tostring(src), 1, true) then
                    for _, item in ipairs(items) do names[#names + 1] = item.name end
                end
            end
            table.sort(names)
            return table.concat(names, ',')
        end,
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
    -- AMMO ITEMS OFF, and now said out loud rather than inherited.
    --
    -- This used to lean on the shipped default, with a comment calling it
    -- "the shipped setting" -- and then the shipped setting changed, and the
    -- test started failing for a reason that had nothing to do with what it
    -- checks. A test about weapons should not move when an ammunition
    -- default does.
    --
    -- What it is really asserting: weapons are NOT behind the ammo-items
    -- toggle. Putting them there would leave a default install issuing
    -- nobody anything at all.
    local s = newServer({ [1] = OWN }, function(c)
        c.Loadouts.ammoItems.enabled = false
    end)
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    t.equals(s.carrying(1), 'WEAPON_TEST',
        'the weapon did not arrive as an item, so ox_inventory will disarm the player on sight')
end)

t.test('the magazine rides in the item metadata rather than being set on the ped', function()
    -- SetPedAmmo is reconciled away exactly like the weapon, so a weapon
    -- whose rounds are not in its metadata arrives empty.
    --
    -- ONE MAGAZINE OF THE SIXTY, not all of it: the rest is handed over as
    -- items, and the test below this one is the one that holds the total.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    local weapon = s.itemNamed(1, 'WEAPON_TEST')
    t.isNotNil(weapon, 'no weapon item to inspect')
    t.equals(weapon.metadata and weapon.metadata.ammo, 30,
        'the weapon was issued without its magazine')
end)

t.test('DEFECT: sixty rounds picked is sixty rounds carried, not a hundred and twenty', function()
    -- THE ONE ASSERTION NEITHER HALF EVER MADE. The magazine was written by
    -- issueWeapons and the items by the loop after it, each correct on its
    -- own and each with its own passing test -- and both were issuing the
    -- WHOLE pick. Sixty chosen, sixty in the gun, sixty in the pocket, a
    -- hundred and twenty carried, on every weapon of every round ever
    -- fought here. The total was the thing nobody asserted.
    --
    -- Driven through the REAL catalogue rather than a synthetic entry,
    -- because that is where it happened: a shipped weapon, a shipped ammo
    -- item, and the shipped magazine read off the weapon's own options.
    local s = newServer({ [1] = {} })
    local loadout = s.env.Arena.ResolveLoadout({ weapons = { { key = 'pistol', ammo = 60 } } })

    t.equals(#loadout.weapons, 1, 'the shipped pistol stopped resolving, so this proves nothing')
    t.equals(loadout.weapons[1].ammoTypeItem, 'ammo-9',
        'the pistol stopped pulling its own round, which is the other half of this')

    s.ammo.Issue(1, 'm1', loadout)

    local weapon = s.itemNamed(1, 'WEAPON_PISTOL')
    local rounds = s.itemNamed(1, 'ammo-9')
    t.isNotNil(weapon, 'the pistol was never issued')

    local loaded = (weapon.metadata and weapon.metadata.ammo) or 0
    local spare = (rounds and rounds.count) or 0

    t.equals(loaded + spare, 60,
        ('a player who picked 60 rounds is carrying %d (%d loaded, %d spare)')
            :format(loaded + spare, loaded, spare))

    -- And the split is the one the operator's own config describes: the
    -- smallest amount the pistol's own list offers is 30.
    t.equals(loaded, 30, 'the magazine is not the weapon\'s own smallest option')
    t.equals(spare, 30, 'the remainder did not reach the inventory as items')
end)

t.test('and a pick that fits in one magazine hands over no loose rounds at all', function()
    -- Thirty rounds is thirty rounds. Issuing a magazine AND thirty items
    -- would be the same doubling one size down.
    local s = newServer({ [1] = {} })
    local loadout = s.env.Arena.ResolveLoadout({ weapons = { { key = 'pistol', ammo = 30 } } })
    s.ammo.Issue(1, 'm1', loadout)

    local weapon = s.itemNamed(1, 'WEAPON_PISTOL')
    t.equals(weapon.metadata and weapon.metadata.ammo, 30, 'the gun did not get the rounds')
    t.isNil(s.itemNamed(1, 'ammo-9'), 'loose rounds were issued on top of a full magazine')
end)

t.test('and the split is read off the WEAPON, not one number for every gun', function()
    -- THE PISTOL CANNOT PROVE THIS. Its smallest option is 30 and the
    -- blanket default is also 30, so a door that never looked at the weapon
    -- at all would issue exactly the same thing. The heavy sniper's own
    -- list starts at 10, which tells the two apart.
    local s = newServer({ [1] = {} })
    local loadout = s.env.Arena.ResolveLoadout({ weapons = { { key = 'heavysniper', ammo = 40 } } })
    t.equals(#loadout.weapons, 1, 'the shipped heavy sniper stopped resolving')

    s.ammo.Issue(1, 'm1', loadout)

    local weapon = s.itemNamed(1, 'WEAPON_HEAVYSNIPER')
    local rounds = s.itemNamed(1, 'ammo-heavysniper')
    t.isNotNil(weapon, 'the heavy sniper was never issued')

    local loaded = (weapon.metadata and weapon.metadata.ammo) or 0
    local spare = (rounds and rounds.count) or 0

    t.equals(loaded, 10, 'the sniper was loaded with something other than its own 10')
    t.equals(spare, 30, 'the remainder is wrong, so the total is wrong')
    t.equals(loaded + spare, 40, 'a player who picked 40 rounds is carrying a different number')
end)

t.test('and with ammo items switched off the whole pick stays in the magazine', function()
    -- config.lua promises exactly this: "rounds then travel in the weapon's
    -- own metadata instead". Splitting a pick that has nowhere to be split
    -- INTO would hand somebody thirty rounds when they asked for sixty.
    local s = newServer({ [1] = {} }, function(config)
        config.Loadouts.ammoItems.enabled = false
    end)
    local loadout = s.env.Arena.ResolveLoadout({ weapons = { { key = 'pistol', ammo = 60 } } })
    s.ammo.Issue(1, 'm1', loadout)

    local weapon = s.itemNamed(1, 'WEAPON_PISTOL')
    t.equals(weapon.metadata and weapon.metadata.ammo, 60,
        'the pick was split even though there are no items to split it into')
    t.isNil(s.itemNamed(1, 'ammo-9'), 'ammo items were issued while they are switched off')
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

t.test('DEFECT: and a REAL blade, resolved the way the server resolves one', function()
    -- THE TEST ABOVE WAS VACUOUS AND SAID SO CONFIDENTLY. It hands in
    -- `ammo = 0` -- a value Arena.ResolveAmmo never produces for a melee
    -- weapon. Every one of the shipped blades resolves to 1, because
    -- config.weapons.lua gives them `default = max = 1` so the ammo
    -- machinery has a number to agree on. So the branch this is about was
    -- never reached: splitRounds returned 1, and every knife and bat on
    -- every server was issued carrying `metadata.ammo = 1`, which is
    -- precisely the "present zero reads as an empty one" mistake the comment
    -- above warns against -- one worse.
    --
    -- The fix reads the CATALOGUE, so the test has to go through the
    -- catalogue too. Nothing is hand-fed here but the key.
    local s = newServer({ [1] = OWN })

    local blade = nil
    for _, entry in ipairs(s.env.Arena.GetEnabledWeapons()) do
        if s.env.Arena.IsMeleeWeapon(entry) then blade = entry break end
    end
    t.isNotNil(blade, 'no melee weapon is enabled, so this proves nothing')

    -- Through the real resolver, so the ammo is whatever the server would
    -- actually have put on it.
    local loadout = s.env.Arena.ResolveLoadout({ weapons = { { key = blade.key } } })
    t.equals(#loadout.weapons, 1, 'the blade did not resolve')
    t.isTrue((loadout.weapons[1].ammo or 0) > 0,
        'the blade resolved to zero ammo, so this test is back to proving nothing')

    s.ammo.Issue(1, 'm1', loadout)

    local given = s.itemNamed(1, loadout.weapons[1].weapon)
    t.isNotNil(given, 'the blade was never handed over')
    t.isNil(given.metadata and given.metadata.ammo,
        'a real blade was issued carrying a magazine of '
            .. tostring(given.metadata and given.metadata.ammo))
end)

t.test('a weapon ox_inventory refuses is named in the console, not swallowed', function()
    -- "No weapon appeared" has two completely different causes: the item was
    -- refused, or it was accepted and something took it back afterwards.
    -- Without a line for each they are the same silence, and the operator
    -- has nothing to go on.
    local s = newServer({ [1] = OWN })
    s.breakOn('give')
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    local console = s.log()
    t.contains(console, 'WEAPON_TEST', 'the refused weapon is not named')
    t.contains(console, 'issued NOTHING', 'a player left unarmed is not called out')
end)

t.test('and a weapon that WAS accepted says so, with what it was loaded with', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    local console = s.log()
    t.contains(console, 'gave WEAPON_TEST')
    t.contains(console, 'ammo 30', 'the magazine it was issued with is not recorded')
    t.notContains(console, 'issued NOTHING')
end)

t.test('DEFECT: with the door OFF the arena weapon has to be taken back by name', function()
    -- The door is what usually destroys the arena kit: it clears the whole
    -- inventory on the way out. Switch it off and nothing does -- Reclaim
    -- returned early the moment it found no stash, so every weapon the arena
    -- issued stayed in the player's pockets, permanently, and the arena
    -- became a weapon shop.
    local s = newServer({ [1] = OWN }, function(c)
        c.Loadouts.inventory.stripOnEntry = false
        -- Weapons only, so this stays a test about the weapon reclaim. The
        -- ammunition reclaim is its own test below.
        c.Loadouts.ammoItems.enabled = false
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
        c.Loadouts.ammoItems.enabled = false
    end)

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    s.ammo.Reclaim(1, 'match ended')

    t.equals(s.carrying(1), 'phone,water', 'their own kit is untouched, in order')
end)

t.test('DEFECT: the ROUNDS come back too, or the arena is a slower weapon shop', function()
    -- The leak that turning ammo items on opened, and it is the same shape as
    -- the weapon one above.
    --
    -- Issued ammunition was recorded as a running COUNT -- enough for the
    -- console line, useless to the exit, because knowing sixty rounds were
    -- given says nothing about which item to take back. With the door on that
    -- never showed: the door clears the whole inventory anyway. With the door
    -- off the rounds simply stayed. Join, collect sixty, leave, keep them,
    -- repeat -- a weapon shop with extra steps.
    local s = newServer({ [1] = OWN }, function(c)
        c.Loadouts.inventory.stripOnEntry = false
        c.Loadouts.ammoItems.enabled = true
    end)

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.contains(s.carrying(1), 'ammo-rifle',
        'the rounds were never issued, so this proves nothing about taking them back')

    s.ammo.Reclaim(1, 'match ended')
    t.equals(s.carrying(1), 'phone,water',
        'the rounds left with the player -- the arena is now a way to farm ammunition')
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

t.test('DEFECT: a stash that REFUSES the write must not strip them either', function()
    -- THE DIFFERENCE BETWEEN A THROW AND A NO. Every write in this file was
    -- written as
    --
    --     local moved = pcall(function() return ox:AddItem(...) end)
    --
    -- where `moved` is the pcall flag and nothing else -- true whenever the
    -- call did not throw, INCLUDING when ox_inventory returned false to say
    -- it refused the item. A full stash, or an item the operator's own
    -- ox_inventory data does not know, returns false rather than throwing.
    --
    -- So the loop reported success on a stash that had taken nothing, and the
    -- ClearInventory behind it destroyed everything the player owned. The one
    -- promise this resource makes is that a match cannot cost anyone
    -- anything.
    --
    -- The test above proves the THROWING case was handled. Nothing proved
    -- this one, and the whole suite passed with the bug in place.
    local s = newServer({ [1] = OWN })
    s.breakOn('stashRefuse')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water',
        'THE PLAYER WAS STRIPPED INTO A STASH THAT REFUSED THEIR KIT -- it is gone')
    t.isFalse(s.ammo.IsHolding(1), 'and nothing is owed back to them')
end)

t.test('and a clear that REFUSES puts the stashed kit back rather than losing it', function()
    -- The other half of the same mistake, one line further down: the clear
    -- reported success, so the kit stayed in the stash while the player was
    -- treated as stripped -- and the record saying whose stash it was is what
    -- the exit path reads to give it back.
    local s = newServer({ [1] = OWN })
    s.breakOn('clearRefuse')
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), 'phone,water',
        'a refused clear left the player without their kit')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('DEFECT: an item the player cannot be GIVEN back is left in the stash, not deleted', function()
    -- restore() read the same value the same wrong way, and then removed the
    -- item from the stash on the strength of it. So an item ox_inventory
    -- refused to hand back was deleted from the one place it was safe --
    -- and the exit reported the kit as returned.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.isTrue(s.ammo.IsHolding(1), 'nothing was stashed, so this proves nothing')

    s.breakOn('give')
    s.ammo.Reclaim(1, 'm1')

    -- Not on the player (ox refused), so it must still be in the stash.
    t.isTrue(s.stashed(1):find('phone', 1, true) ~= nil,
        'AN ITEM THAT COULD NOT BE RETURNED WAS DELETED FROM THE STASH')
    t.isTrue(s.log():find('still in stash', 1, true) ~= nil,
        'and the player was never told where their belongings are')
end)

t.test('DEFECT: allowWeaponWithoutAmmoItem off takes the empty gun back', function()
    -- The setting shipped documented and READ BY NOTHING: both values issued
    -- the weapon, logged the missing rounds, and sent the player in holding a
    -- gun that looked loaded and was not.
    local s = newServer({ [1] = OWN }, function(config)
        config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem = false
    end)
    s.breakOn('ammoItem')   -- ox refuses the ROUNDS, and issues the weapon

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-test', 60))

    t.isFalse(s.carrying(1):find('WEAPON_TEST', 1, true) ~= nil,
        'the weapon was left on a player who could not be given a single round for it')
    t.isTrue(s.log():find('took back', 1, true) ~= nil,
        'and nothing in the console says why they are unarmed')
end)

t.test('and ON -- the default -- it is left with them, empty', function()
    -- The other half, so the test above is not passing on a build that simply
    -- stopped issuing weapons.
    local s = newServer({ [1] = OWN })
    t.isTrue(s.config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem,
        'the shipped default changed, and this test is about the old one')
    s.breakOn('ammoItem')

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-test', 60))

    t.isTrue(s.carrying(1):find('WEAPON_TEST', 1, true) ~= nil,
        'the weapon was taken back on a server that allows an empty gun')
end)

t.test('DEFECT: a finished match\'s records are actually dropped', function()
    -- ArenaAmmo.Clear has always existed and was called from NOWHERE, so
    -- every match a server ran left its issued-weapon and issued-ammunition
    -- tables behind for good -- an unbounded leak on a resource whose whole
    -- job is running matches back to back.
    --
    -- And Clear itself only dropped one of the three tables it is supposed
    -- to, so wiring it up alone would have fixed a third of it.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-test', 60))
    t.isTrue(s.ammo.OnLoan('m1') > 0, 'nothing was issued, so this proves nothing')

    -- Reclaimed first: Clear refuses while anybody is still owed their kit,
    -- which is the guard and not the leak.
    s.ammo.Reclaim(1, 'm1')
    t.isTrue(s.ammo.Clear('m1'), 'a match nobody is owed anything on could not be dropped')

    t.equals(s.ammo.OnLoan('m1'), 0, 'the match kept its issued-ammunition record for ever')
end)

t.test('DEFECT: an item ox_inventory answers NOTHING about is not taken out of the stash', function()
    -- oxDid treats a nil return as success, which is a fine rule for
    -- registering a stash or clearing an inventory -- nothing is lost by
    -- believing it. It is the wrong rule for the one call whose next line
    -- REMOVES the item from the stash, because that is the only
    -- irreversible thing the door does.
    --
    -- ox_inventory's AddItem answers `success, response`. A nil where a true
    -- belongs is a version or a code path we do not understand, and the safe
    -- reading of an answer we do not understand is to leave the item where
    -- it is.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.isTrue(s.ammo.IsHolding(1), 'nothing was stashed, so this proves nothing')

    s.breakOn('giveSilent')
    s.ammo.Reclaim(1, 'm1')

    t.isTrue(s.stashed(1):find('phone', 1, true) ~= nil,
        'AN ITEM OX_INVENTORY SAID NOTHING ABOUT WAS TAKEN OUT OF THE STASH')
    t.isTrue(s.log():find('no answer', 1, true) ~= nil,
        'and the operator was never told which item, or where it is')
end)

t.test('and it can still be handed back once ox_inventory answers properly', function()
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('giveSilent')
    s.ammo.Reclaim(1, 'm1')

    s.fixOn('giveSilent')
    t.equals(s.ammo.Reclaim(1, 'm1'), 1, 'the retry could not hand the kit back')
    t.isFalse(s.ammo.IsHolding(1))
end)

t.test('DEFECT: a restore that FAILS keeps the record of where the kit is', function()
    -- restore() returns false in exactly the cases where the player's
    -- belongings are STILL IN THE STASH -- ox_inventory gone, or the stash
    -- unreadable -- and its own log offers the stash name, because it is a
    -- real openable stash.
    --
    -- Reclaim cleared the record on the line ABOVE that call, so the name was
    -- thrown away with it: nothing could retry, Clear stopped refusing over
    -- them, IsHolding said there was nothing held, and the debug line printed
    -- STILL STASHED about a record it had just deleted.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.isTrue(s.ammo.IsHolding(1), 'nothing was stashed, so this proves nothing')

    s.breakOn('readStash')
    t.equals(s.ammo.Reclaim(1, 'm1'), 0, 'a restore that could not read the stash reported success')

    t.isTrue(s.ammo.IsHolding(1),
        'the arena forgot it was holding a kit it had just failed to hand back')
    t.isNotNil(s.ammo.StashOf(1),
        'and forgot WHICH stash it is in, which is the one thing the player needs')
    t.equals(s.ammo.Owed(), 1,
        'and does not count itself as owing anybody anything, so nothing will come back for it')
end)

t.test('and the match cannot be dropped while that is outstanding', function()
    -- The guard is the whole point: dropping the match's records while a kit
    -- is unreturned is how it becomes unreturnable.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('readStash')
    s.ammo.Reclaim(1, 'm1')

    t.isFalse(s.ammo.Clear('m1'),
        'the match was dropped while somebody\'s belongings were still in a stash')
end)

t.test('and once ox_inventory is working again the kit still comes back', function()
    -- What keeping the record buys. A retry is only possible because the
    -- stash name survived the failure.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('readStash')
    s.ammo.Reclaim(1, 'm1')

    s.fixOn('readStash')
    t.equals(s.ammo.Reclaim(1, 'm1'), 1, 'the retry could not find the kit it had been told about')
    t.isFalse(s.ammo.IsHolding(1), 'the kit came back and the record stayed behind')
    t.isTrue(s.ammo.Clear('m1'), 'the match still could not be dropped afterwards')
    t.equals(s.ammo.Owed(), 0,
        'and it still says it owes them, which is a stash it will keep re-opening for ever')
end)

t.test('and it still refuses while somebody is owed their kit', function()
    -- The guard the leak fix must not trade away: dropping the record while
    -- a stash is outstanding is how a kit becomes unreturnable.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-test', 60))

    t.isFalse(s.ammo.Clear('m1'), 'a match still holding somebody\'s inventory was dropped')
    t.isTrue(s.ammo.IsHolding(1), 'and their kit is now unreachable')
end)

-- ========================================================================
-- The retry
--
-- The door already refused to destroy anything it could not hand back --
-- a full inventory, a weight limit, a disconnect and a dead ox_inventory
-- all leave a player's belongings sitting in a real, openable stash. What
-- it did NOT do was ever try again: it logged the stash name and waited for
-- an operator to read the console.
--
-- These are about the promise being kept without anybody watching. Every
-- one of them ends with the player holding their own things again, and
-- nothing in any of them opens a stash by hand.
-- ========================================================================

t.test('DEFECT: a second match does not destroy what a partial return handed back', function()
    -- THE HOLE THE RETRY OPENED. Keeping the record on a failed restore is
    -- what lets the sweep find the stash again -- and it is also what makes
    -- the door skip a player who already has one. So:
    --
    --   they leave a match, half their kit goes back and half stays in the
    --   stash; they join another, the door sees a record and does NOT stow
    --   the half they are carrying; the round ends, and the exit's clear --
    --   which is there to destroy the ARENA's kit -- destroys their own.
    --
    -- The remainder then fits, restore() returns true, and the exit reports
    -- a clean return. Nothing anywhere records a loss.
    local s = newServer({ [1] = OWN })

    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'the door did not stow their kit')

    -- The water will not go back -- a weight limit, a full inventory. The
    -- phone does.
    s.breakOn('refuseNamed', { water = true })
    t.equals(s.ammo.Reclaim(1, 'm1'), 0, 'a partial return reported success')
    t.equals(s.carrying(1), 'phone', 'the half that COULD go back did not')
    t.equals(s.stashOfCid('CID1'), 'water', 'the half that could not is not in the stash')

    -- Whatever was wrong clears up, and they join another round.
    s.fixOn('refuseNamed')
    s.ammo.Issue(1, 'm2', { weapons = {}, armor = 100, health = 200 })
    s.ammo.Reclaim(1, 'm2')

    t.equals(s.carrying(1), 'phone,water',
        'a match cost this player their phone, and reported a clean exit')
end)

t.test('and a second pass over the same record does not destroy it either', function()
    -- THE DISCONNECT ROUTE INTO THE SAME HOLE, with no second match in it.
    -- playerDropped reclaims unconditionally, and the sweep reclaims again
    -- afterwards -- two passes over one record. If the second one clears the
    -- player out, everything the first handed back goes with it.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('refuseNamed', { water = true })
    s.ammo.Reclaim(1, 'disconnected')
    t.equals(s.carrying(1), 'phone', 'the half that could go back did not')

    s.fixOn('refuseNamed')
    s.ammo.Reclaim(1, 'retry')

    t.equals(s.carrying(1), 'phone,water', 'the second pass destroyed what the first handed back')
    t.equals(s.stashOfCid('CID1'), '', 'and their belongings are still in the stash')
    t.isFalse(s.ammo.IsHolding(1), 'the record survived a return that finally completed')
end)

t.test('and the arena kit still comes off on that second pass, by name', function()
    -- WHAT REFUSING TO CLEAR TWICE COULD HAVE COST. The wholesale clear is
    -- how the arena's own weapons are destroyed on the way out; a pass that
    -- skips it has to take them back some other way, or the fix for losing
    -- a player's phone becomes a way to walk out with the arena's rifle.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.equals(s.itemNamed(1, 'WEAPON_TEST') ~= nil, true, 'the arena weapon was never issued')

    -- The clear is REFUSED, so the arena kit survives the first pass, and
    -- one of their own items will not go back either.
    s.breakOn('clearRefuse')
    s.breakOn('refuseNamed', { water = true })
    s.ammo.Reclaim(1, 'm1')

    t.isNotNil(s.itemNamed(1, 'WEAPON_TEST'),
        'the fixture cleared anyway, so this proves nothing')

    s.fixOn('clearRefuse')
    s.fixOn('refuseNamed')
    s.ammo.Reclaim(1, 'm1')

    t.isNil(s.itemNamed(1, 'WEAPON_TEST'),
        'the arena weapon walked out of the arena with them')
    t.equals(s.carrying(1), 'phone,water', 'and their own belongings did not survive it')
end)

t.test('DEFECT: a stale record does not let somebody carry their own kit into the next round', function()
    -- THE OTHER HALF OF THE SAME HOLE. Keeping the record after a partial
    -- return is what lets the sweep find the stash again -- and the door
    -- used to read "has a record" as "already stripped", so a player with
    -- half their belongings back walked into their NEXT round still holding
    -- them. Two things follow, and both are the arena's core promise:
    -- nobody brings their own kit in, and nothing they loot leaves with them.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('refuseNamed', { water = true })
    s.ammo.Reclaim(1, 'm1')
    t.equals(s.carrying(1), 'phone', 'the partial return this is built on did not happen')

    s.fixOn('refuseNamed')
    s.ammo.Issue(1, 'm2', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.carrying(1), '', 'they walked into the next round carrying their own phone')
    t.equals(s.stashOfCid('CID1'), 'phone,water',
        'the phone they were holding never made it back into the stash')
end)

t.test('and issuing the same match twice does not stash the arena\'s own kit', function()
    -- The guard the fix above has to keep. The player is stripped by the
    -- FIRST pass, so by the second they are carrying nothing but what the
    -- arena issued -- and a door that stows again puts the arena's rifle
    -- into their stash, to be handed back on the way out as their own
    -- property. That is the arena paying out weapons.
    --
    -- Nothing calls Issue twice for one match today; server/match.lua does
    -- it once per player from sendEnterArena. This is here so that stays
    -- true by test rather than by nobody having tried.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'the door did not stow their kit at all')

    s.ammo.Issue(1, 'm1', loadoutOf('ammo-rifle', 60))

    t.equals(s.stashOfCid('CID1'), 'phone,water',
        'the arena\'s own kit was stowed into the player\'s stash')
end)

t.test('DEFECT: an item that would not go back is handed over on the next sweep', function()
    -- The plain case, and the commonest one: their pockets were full at the
    -- moment the match ended. The door correctly left everything in the
    -- stash -- and then nothing ever asked ox_inventory a second time.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('give')
    t.equals(s.ammo.Reclaim(1, 'm1'), 0, 'a refused restore reported success')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'the refused items were not left in the stash')
    t.equals(s.carrying(1), '', 'they were handed things ox_inventory had refused')

    -- Whatever was wrong stops being wrong. NOBODY IS TOLD.
    s.fixOn('give')
    t.equals(s.ammo.SweepReturns(), 1, 'the sweep did not hand anybody anything')

    t.equals(s.carrying(1), 'phone,water', 'their own belongings never came back')
    t.equals(s.stashOfCid('CID1'), '', 'and are still sitting in the stash')
    t.equals(s.ammo.Owed(), 0, 'and it still counts them as owed')
    t.isFalse(s.ammo.IsHolding(1), 'the arena still thinks it is holding their kit')
    t.isTrue(s.ammo.Clear('m1'), 'and the finished match still cannot be dropped')

    -- AND THEN IT STOPS. A debt that is not written off when it is paid is a
    -- stash this resource re-opens for the rest of the server's life.
    local reads = s.stashReadsOf('CID1')
    s.ammo.SweepReturns()
    t.equals(s.stashReadsOf('CID1'), reads, 'it kept re-opening a stash it had already emptied')
end)

t.test('and it goes on trying for as long as it has to', function()
    -- One retry is not the fix. A player whose inventory is full stays full
    -- until they do something about it, and the sweep has to still be there
    -- when they do.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('give')
    s.ammo.Reclaim(1, 'm1')

    t.equals(s.ammo.SweepReturns(), 0, 'it handed something over while ox_inventory was still refusing')
    t.equals(s.ammo.SweepReturns(), 0, 'and again')
    t.equals(s.ammo.Owed(), 1, 'and stopped counting them as owed while it was still true')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'their belongings did not survive the failed attempts')

    s.fixOn('give')
    t.equals(s.ammo.SweepReturns(), 1, 'it had given up by the time it could have worked')
    t.equals(s.carrying(1), 'phone,water', 'their belongings never came back')
end)

t.test('DEFECT: somebody who comes back on a new server id is still handed their things', function()
    -- The disconnect case, which is the one that actually loses people their
    -- inventory. playerDropped reclaims -- into a source that has already
    -- gone, so ox_inventory refuses it -- and `stashed` is keyed by SERVER
    -- ID, an id they will not be given again. Every handle on their stash
    -- went with the connection.
    --
    -- The stash name is built from the CITIZEN ID and nothing else, which is
    -- the only reason this is recoverable at all.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('give')
    s.ammo.Reclaim(1, 'disconnected')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'nothing was left in the stash to come back for')

    -- Same character, different server id. Nothing keyed by 1 is any use.
    s.reconnect(1, 7)
    s.fixOn('give')
    t.equals(s.ammo.SweepReturns(), 1, 'they reconnected and nothing looked for their stash')

    t.equals(s.carrying(7), 'phone,water', 'they came back to an empty inventory')
    t.equals(s.stashOfCid('CID1'), '', 'and their things are still in a stash they cannot open')
    t.isFalse(s.ammo.IsHolding(1), 'the record under their OLD id was left behind for ever')
    t.isTrue(s.ammo.Clear('m1'), 'and it pinned the finished match with it')
end)

t.test('DEFECT: a stash a restart left behind is found with nothing in memory naming it', function()
    -- `stashed` and the debt list are both in memory and go with a restart.
    -- The stash does not: ox_inventory persists it, named from the character.
    -- So after a restart the resource has no idea anyone is owed anything,
    -- and the only thing that can tell it is looking.
    local s = newServer({ [1] = {} })
    s.putInStash('CID1', 'phone', 1)
    s.putInStash('CID1', 'water', 2)

    t.equals(s.ammo.SweepReturns(), 1, 'a stash left over from before the restart was never looked at')
    t.equals(s.carrying(1), 'phone,water', 'their belongings did not come back')
    t.equals(s.stashOfCid('CID1'), '', 'and are still in the stash')
end)

t.test('and a stash ox_inventory has forgotten is registered before it is read', function()
    -- The restart case has a second half. ox_inventory forgets every stash
    -- it was told about when IT restarts, and a stash it does not know is
    -- not one it will read -- so looking without registering first finds
    -- nothing, on precisely the servers where there is something to find.
    local s = newServer({ [1] = {} })
    s.putInStash('CID1', 'phone', 1)
    s.breakOn('register')

    t.equals(s.ammo.SweepReturns(), 0, 'it read a stash ox_inventory had refused to register')
    t.equals(s.stashOfCid('CID1'), 'phone', 'and moved things out of it on that basis')

    s.fixOn('register')
    t.equals(s.ammo.SweepReturns(), 1, 'and then never tried again once registering worked')
    t.equals(s.carrying(1), 'phone', 'their belongings never came back')
end)

t.test('and that look costs one read per character, not one per sweep', function()
    -- The restart check is a stash read for somebody nothing says is owed
    -- anything, which on a full server is a read per player. Once each is a
    -- bounded cost. Every pass is a permanent tax on a resource whose whole
    -- job is running matches back to back.
    local s = newServer({ [1] = {} })

    s.ammo.SweepReturns()
    s.ammo.SweepReturns()
    s.ammo.SweepReturns()

    t.equals(s.stashReadsOf('CID1'), 1, 'the sweep re-read a stash it had already found empty')
end)

t.test('DEFECT: nothing is handed to somebody who is in a round', function()
    -- THE GUARD THAT MATTERS MOST, and it is not a nicety. The exit clears
    -- a player's whole inventory BEFORE it reads their stash. Put their own
    -- belongings into their pockets mid-match and the next exit destroys
    -- them -- the retry would become the thing it exists to prevent.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    s.breakOn('give')
    s.ammo.Reclaim(1, 'm1')

    -- They are owed their kit AND they have started another round.
    s.place(1)
    s.fixOn('give')

    t.equals(s.ammo.SweepReturns(), 0, 'it handed a fighter their own inventory mid-round')
    t.equals(s.carrying(1), '', 'which the next exit would have destroyed')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'their belongings left the stash mid-match')
end)

t.test('and not to somebody the door has just shut behind either', function()
    -- The same hazard one step earlier, and the reason the sweep asks about
    -- the stash record as well as the dispatch flag. A player whose kit has
    -- been stashed and whose exit has not run yet is owed nothing: their
    -- belongings are in the stash on purpose.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })

    t.equals(s.ammo.SweepReturns(), 0, 'the sweep undid the door while the match was still on')
    t.equals(s.carrying(1), '', 'they walked into the arena carrying their own kit')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'which had been taken back out of the stash')
end)


t.test('DEFECT: a stash the sweep could not empty is remembered, not written off', function()
    -- The two halves have to work together. The once-only look is what makes
    -- checking every player affordable; the debt list is what remembers the
    -- ones that look found something wrong with. Keep the first without the
    -- second and a stash the sweep DID find, and could not empty, is written
    -- off for the rest of the session -- worse than never having looked.
    local s = newServer({ [1] = {} })
    s.putInStash('CID1', 'phone', 1)

    s.breakOn('give')
    t.equals(s.ammo.SweepReturns(), 0, 'ox_inventory was refusing and something was handed over anyway')
    t.equals(s.stashOfCid('CID1'), 'phone', 'and it came out of the stash')

    s.fixOn('give')
    t.equals(s.ammo.SweepReturns(), 1, 'the one look was spent on a refusal and never repeated')
    t.equals(s.carrying(1), 'phone', 'their belongings never came back')
end)

t.test('and an exit that WORKED is not swept over again for ever', function()
    -- The ordinary case, which is every match: the kit went back at the door
    -- and this resource owes nobody anything. A debt that is not cleared when
    -- it is paid turns that into a stash read per player per pass, for ever.
    local s = newServer({ [1] = OWN })
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.equals(s.ammo.Reclaim(1, 'm1'), 1, 'the ordinary exit failed, so this proves nothing')

    s.ammo.SweepReturns()
    local reads = s.stashReadsOf('CID1')
    s.ammo.SweepReturns()
    s.ammo.SweepReturns()

    t.equals(s.stashReadsOf('CID1'), reads,
        'it goes on opening the stash of somebody who was paid in full at the door')
end)

t.test('DEFECT: with no dispatch flag to ask, it hands over nothing at all', function()
    -- server/dispatch.lua loads after this file, so "is this player in a
    -- round?" is a question that can have no answer. It is answered NO
    -- RETURN, and that direction is not arbitrary: the exit clears a
    -- player's whole inventory before it reads their stash, so handing
    -- somebody their own kit during a round is how the retry would come to
    -- destroy the very thing it exists to protect. Waiting costs minutes.
    local s = newServer({ [1] = {} }, nil, { noDispatch = true })
    s.putInStash('CID1', 'phone', 1)

    t.equals(s.ammo.SweepReturns(), 0,
        'it handed things over without being able to tell who was mid-round')
    t.equals(s.stashOfCid('CID1'), 'phone', 'and took them out of the stash to do it')
    t.equals(s.carrying(1), '', 'and put them somewhere they could be cleared')
end)

t.test('DEFECT: the sweep runs on its own, with nobody calling it', function()
    -- Everything above drives the sweep by hand, which proves it works and
    -- not that it ever happens. This is the difference between "an operator
    -- can fix it" and "it fixes itself", and it is the entire point.
    local s = newServer({ [1] = OWN }, function(config)
        config.Loadouts.inventory.returnRetrySeconds = 30
    end, { retry = true })

    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.breakOn('give')
    s.ammo.Reclaim(1, 'm1')
    s.fixOn('give')

    -- Two resumes is one pass: the loop waits before it works, so the first
    -- only reaches that wait.
    s.step()
    s.step()

    t.equals(s.carrying(1), 'phone,water',
        'nothing swept on its own -- their belongings needed somebody to notice')
end)

t.test('and setting the interval to zero switches it off, as config.lua says', function()
    -- An operator who turns it off gets exactly what this resource did
    -- before: their things stay in the stash until somebody opens it.
    local s = newServer({ [1] = OWN }, function(config)
        config.Loadouts.inventory.returnRetrySeconds = 0
    end, { retry = true })

    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    s.breakOn('give')
    s.ammo.Reclaim(1, 'm1')
    s.fixOn('give')

    s.step()
    s.step()

    t.equals(s.carrying(1), '', 'the sweep ran on a server that had switched it off')
    t.equals(s.stashOfCid('CID1'), 'phone,water', 'and emptied a stash it had been told to leave alone')
end)

t.test('DEFECT: the drop block waits for an ox_inventory that starts late', function()
    -- It ran once at load and returned if ox_inventory was not started YET.
    -- That is not a rare state: start order is not guaranteed, and this
    -- resource is deliberately asked to start early, before the medical
    -- script, to win the death race. So on any server where ox_inventory
    -- came up second the hook was never installed, dropping in an arena was
    -- allowed for the whole session, and nothing said so -- the only branch
    -- that logs is the one where ox_inventory REFUSES the hook, which this
    -- never reached.
    local s = newServer({ [1] = OWN }, nil, { inventoryStartsAfter = 3 })

    t.isNotNil(s.hook('swapItems'),
        'ox_inventory started three seconds late and the drop block was never installed')
end)

t.test('and gives up loudly on one that never starts', function()
    -- Thirty seconds, then it says so. Silence here reads as "drops are
    -- blocked" to an operator, which is the opposite of what is true.
    local s = newServer({ [1] = OWN }, nil, { inventoryStartsAfter = 9999 })

    t.isNil(s.hook('swapItems'))
    t.isTrue(s.log():find('never started', 1, true) ~= nil,
        'dropping is allowed and the console does not mention it')
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

t.test('DEFECT: and cannot drop with the door OFF either', function()
    -- The guard asked `stashed[src]`, which is only ever populated when the
    -- door is SHUT. With Config.Loadouts.inventory.stripOnEntry off -- where
    -- a player keeps their own inventory and is handed the arena's kit on
    -- top of it -- nobody is stashed, so this returned "allowed" for every
    -- fighter and the block was off for the whole match.
    --
    -- Which is the setting where it matters most: the arena's weapons are
    -- loose in the player's own pockets, so dropping one on the floor for
    -- somebody to collect is a single drag.
    local s = newServer({ [1] = OWN }, function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    s.ammo.Issue(1, 'm1', { weapons = {}, armor = 100, health = 200 })
    t.isFalse(s.ammo.IsHolding(1), 'the door was shut after all, so this tests the wrong thing')

    -- What actually says they are mid-match.
    s.env.ArenaDispatch.Set(1, 'm1')

    local hook = s.hook('swapItems')
    t.isNotNil(hook, 'the drop guard should be registered')
    t.isFalse(hook({ source = 1, toInventory = 'drop-7' }),
        'a fighter dropped the arena kit on the floor with the door off')
    t.isTrue(hook({ source = 1, toInventory = 1 }),
        'moving things around their own pockets stopped being their business')
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
