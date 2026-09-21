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
    the next line. The door was fixed and tested. The other place with the
    same shape was not:

      issueWeapons        a weapon missing from an operator's ox_inventory
                          data is the single likeliest thing to go wrong
                          here, and the player is in the arena unarmed.

    That guard is `not (ok and accepted ~= false)`, it had surviving
    mutants, and it is one operator typo away from mattering.

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
    local commands, refusals = {}, {}
    --- BROKEN FROM THE START when a test asks for it. The boot report thread
    --- runs while this fixture is being built, so a fault switched on
    --- afterwards is switched on too late to be the first thing ox_inventory
    --- was asked -- and the question this file cares most about is asked once
    --- and remembered.
    local fail = opts.fail or {}
    local calls = {}          -- every AddItem, in order, arguments kept

    --- The component items this server's ox_inventory has. The default is
    --- the handful the tests below fit; a test that wants an unknown name
    --- passes its own set.
    --- ox_inventory tags every item as it builds its list -- `component`,
    --- `weapon`, `ammo` or `tint` -- and the server keeps those tags. The
    --- doubles carry them because a name being REAL and a name being a
    --- COMPONENT are different questions, and only the second one is safe to
    --- write onto a weapon.
    local knownItems = opts.knownItems or {
        at_scope_medium = { name = 'at_scope_medium', component = true },
        at_suppressor_heavy = { name = 'at_suppressor_heavy', component = true },
        at_grip = { name = 'at_grip', component = true },
        at_flashlight = { name = 'at_flashlight', component = true },
        at_clip_extended_rifle = { name = 'at_clip_extended_rifle', component = true },
        -- Real items that are NOT components. Naming one of these on a
        -- weapon is exactly as fatal as naming something imaginary.
        water = { name = 'water' },
        ammo_rifle = { name = 'ammo_rifle', ammo = true },
        WEAPON_PISTOL = { name = 'WEAPON_PISTOL', weapon = true },
        -- An item from an ox_inventory too old to tag anything.
        at_untagged = { name = 'at_untagged' },
    }

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
        --- THE ITEM REGISTRY, which decides whether an attachment equips or
        --- takes the weapon out of the fight.
        ---
        --- ox_inventory fits a component with `Items[name].client.component`
        --- and does not guard that index. A name it does not know is nil,
        --- the index throws, and the throw lands between GiveWeaponToPed and
        --- SetCurrentPedWeapon -- so the player ends up holding a weapon the
        --- game will not draw. Modelled here as a plain set of names,
        --- because the name is the only part of it server/ammo.lua can see:
        --- the server's copy of an item has its `client` table stripped.
        Items = function(_self, name)
            if fail.noRegistry then error('this build has no Items export') end
            -- NOT A THROW, AND NOT nil. A fork or a shim that answers with
            -- something that is not a table at all is not caught by pcall --
            -- `ok` is true and the value is rubbish -- and indexing it throws
            -- somewhere with no pcall around it.
            --
            -- A NUMBER RATHER THAN A STRING, and the difference matters. Lua
            -- gives strings a metatable, so indexing one quietly answers nil
            -- and a test built on a string proves nothing at all. A number
            -- has none, and indexing it throws the way the real fault does.
            if fail.junkRegistry then return 42 end
            -- ox_inventory UP TO v2.11.5 answers an unknown name with FALSE,
            -- not nil: `return ItemList[item] or false`. From v2.12.0 it
            -- returns nil. Both mean "no such item" and the guard has to read
            -- them the same way.
            if fail.oldFalse and name ~= nil and knownItems[name] == nil then return false end
            -- A BUILD THAT TAGS NOTHING YET. The list has items in it and not
            -- one of them carries a tag.
            if fail.untaggedList and name == nil then
                local out = {}
                for k, v in pairs(knownItems) do
                    local copy = {}
                    for f2, v2 in pairs(v) do
                        if f2 ~= 'component' and f2 ~= 'weapon' and f2 ~= 'ammo' and f2 ~= 'tint' then
                            copy[f2] = v2
                        end
                    end
                    out[k] = copy
                end
                return out
            end
            -- ox_inventory STILL BUILDING ITS LIST: the export is there and
            -- answers, and what it has to say so far is nothing.
            if fail.emptyRegistry and name == nil then return {} end
            if name == nil then return knownItems end
            return knownItems[name]
        end,
        registerHook = function() return true end,
    }

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        GetResourceState = function(name)
            if name ~= 'ox_inventory' then return 'missing' end
            return fail.noInventory and 'missing' or 'started'
        end,
        Wait = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function() end,
        CreateThread = function(fn) fn() end,
        TriggerClientEvent = function() end,
        GetPlayers = function() return {} end,
        print = function(line) console[#console + 1] = tostring(line) end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        lib = Sandbox.newOxLib(),
    })
    -- The return sweep is a `while true do Wait(...) end`, and the
    -- CreateThread above runs a body straight through. This file is about
    -- what the loadout hands over, not about the door's retry -- which
    -- ammo_spec drives on a stepping runner -- so it is switched off here.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    if opts.mutate then opts.mutate(env.Config) end

    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    -- AFTER util.lua, WHICH DEFINES THE REAL ONES. Set on the env before it,
    -- these are simply overwritten as the file loads, and every command test
    -- below then runs against ArenaIsAdmin's real ace lookup on a server with
    -- no ace system -- which throws, rather than testing the gate.
    --- Only src 4 is cleared, so a gate can be told apart from a no-op.
    env.ArenaIsAdmin = function(src) return src == 4 end
    env.ArenaNotifyKey = function(src, key) refusals[#refusals + 1] = { src = src, key = key } end
    Sandbox.loadInto('../Crimson-Arena/server/ammo.lua', env)

    return {
        env = env,
        ammo = env.ArenaAmmo,
        config = env.Config,
        calls = calls,
        breakOn = function(what, value) fail[what] = value == nil and true or value end,
        --- Whether this file registered a console command by that name.
        registered = function(name) return commands[name] ~= nil end,
        --- Runs one, and answers with what the console gained and who was refused.
        runCommand = function(name, src, args)
            assert(commands[name], 'no such command registered: ' .. name)
            local before, refusedBefore = #console, #refusals
            commands[name](src, args or {})
            local out = {}
            for i = before + 1, #console do out[#out + 1] = console[i] end
            return table.concat(out, '\n'), #refusals > refusedBefore
        end,
        --- A server where ox_inventory never started.
        stopInventory = function() fail.noInventory = true end,
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

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'at_suppressor_heavy', 'at_scope_medium' } }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'the attachments were dropped between config and the item')
    t.equals(#parts, 2)
    t.equals(parts[1], 'at_suppressor_heavy')
end)

-- ========================================================================
-- THE ATTACHMENT THAT TOOK THE WEAPON OUT OF THE FIGHT
--
-- Reported from a live server: "when using components it does not allow the
-- weapon to be pulled out -- I can go in the picker, click the components
-- off, and the weapon is able to be used."
--
-- ox_inventory's equip path, verbatim:
--
--     GiveWeaponToPed(playerPed, data.hash, 0, false, true)
--     ...
--     local components = Items[item.metadata.components[i]].client.component
--     ...
--     SetCurrentPedWeapon(playerPed, data.hash, true)
--     SetPedCurrentWeaponVisible(playerPed, true, false, false, false)
--
-- A name Items does not know is nil. Indexing it throws. The throw is AFTER
-- the weapon is given and BEFORE it is made current and made visible -- so
-- the weapon is in the inventory, in the hands, and will not come out. Every
-- symptom in that report, in that order.
--
-- What put an unknown name there: Config.Loadouts.weaponAttachments shipped
-- GTA's own COMPONENT_ names, and ox_inventory has never accepted those. The
-- config is fixed. These tests are the other half -- so the NEXT wrong name,
-- whatever puts it there, costs an attachment instead of the weapon.
-- ========================================================================

t.test('a component ox_inventory does not know is DROPPED, not fitted', function()
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({
        components = { 'at_scope_medium', 'COMPONENT_AT_SCOPE_MEDIUM' },
    }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'the good attachment went with the bad one')
    t.equals(#parts, 1, ('%d attachment(s) were written, so a name ox_inventory throws on '
        .. 'reached the weapon'):format(#parts))
    t.equals(parts[1], 'at_scope_medium', 'the wrong one of the two was kept')
end)

t.test('a real item that is NOT a component is dropped too', function()
    -- The gap a name-exists check leaves wide open. ox_inventory reads
    -- Items[name].client.component and walks it; `water` is a real item with
    -- no component list, so walking nil throws in the same place and leaves
    -- the weapon just as undrawable as an imaginary name did.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({
        components = { 'at_scope_medium', 'water', 'ammo_rifle', 'WEAPON_PISTOL' },
    }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'the good attachment went with the bad ones')
    t.equals(#parts, 1, ('%d name(s) were written -- a real item that is not a component reached '
        .. 'the weapon'):format(#parts))
    t.equals(parts[1], 'at_scope_medium')
end)

t.test('but on an inventory that tags NOTHING, an untagged name is allowed through', function()
    -- Refusing everything this cannot interrogate would strip every
    -- attachment off every weapon on an older ox_inventory, to guard against
    -- a typo. That is much worse than the thing being guarded against.
    --
    -- The registry here has no tagged item anywhere, which is what an
    -- ox_inventory older than the tagging looks like. Handing it the default
    -- registry would prove nothing: that one DOES tag, so the latch would
    -- correctly refuse an untagged name, which is the opposite case.
    local f = newKit({ knownItems = {
        at_untagged = { name = 'at_untagged' },
        at_also_untagged = { name = 'at_also_untagged' },
    } })

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'at_untagged' } }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'an older ox_inventory had every attachment stripped off the weapon')
    t.equals(parts[1], 'at_untagged')
end)

t.test('and the weapon is still issued, which is the whole point', function()
    -- Dropping the attachment must not turn into dropping the weapon: a
    -- fighter with no scope is in the round, a fighter with no gun is not.
    local f = newKit()

    local failed = f.ammo.Issue(1, 'match-1', oneWeapon({
        components = { 'COMPONENT_AT_AR_SUPP' },
    }))

    t.equals(#failed, 0, 'a bad attachment name stopped the weapon being issued')
    t.isNotNil(f.itemNamed(1, 'WEAPON_TEST'), 'the fighter went in unarmed')
end)

t.test('and a weapon whose attachments are ALL unknown carries no components field', function()
    -- Not an empty list: ox_inventory reads an empty components list as a
    -- weapon whose attachments were deliberately stripped, which is a
    -- different thing from one that was never given any.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({
        components = { 'COMPONENT_AT_AR_SUPP', 'COMPONENT_AT_SCOPE_MEDIUM' },
    }))

    t.isNil(f.itemNamed(1, 'WEAPON_TEST').metadata.components,
        'an all-rubbish attachment list reached ox_inventory as an empty one')
end)

t.test('and the console names the component, the weapon and the fix', function()
    -- An operator reading this line has a weapon that will not draw and no
    -- idea which of their config rows did it. The name is the answer.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'COMPONENT_AT_SCOPE_MEDIUM' } }))

    local log = f.log()
    t.contains(log, 'COMPONENT_AT_SCOPE_MEDIUM', 'the console did not say which name was dropped')
    t.contains(log, 'WEAPON_TEST', 'the console did not say which weapon it was on')
    t.contains(log, 'at_scope_medium', 'the console did not show what a real name looks like')
end)

t.test('and it says so ONCE, not once per weapon per fighter per round', function()
    -- Eight fighters with the same loadout is the normal case. A per-issue
    -- warning turns one config mistake into a console nobody can read.
    local f = newKit()

    for src = 1, 4 do
        f.ammo.Issue(src, 'match-1', oneWeapon({ components = { 'COMPONENT_AT_AR_SUPP' } }))
    end

    local seen = select(2, f.log():gsub('DROPPED attachment', ''))
    t.equals(seen, 1, ('the same bad name was reported %d times'):format(seen))
end)

t.test('a build whose registry cannot be read keeps the names, and says why', function()
    -- The check must not become its own outage. An ox_inventory with no
    -- Items export cannot tell a good name from a bad one -- and silently
    -- stripping every attachment off every weapon because of that would be a
    -- worse failure than the one being guarded against.
    local f = newKit()
    f.breakOn('noRegistry')

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'at_scope_medium' } }))

    local parts = f.itemNamed(1, 'WEAPON_TEST').metadata.components
    t.isNotNil(parts, 'a build with no readable registry lost its attachments')
    t.equals(parts[1], 'at_scope_medium')
    t.contains(f.log(), 'NOT checked',
        'the console did not say the attachment names were going through unchecked')
end)

t.test('and THAT is said once too', function()
    local f = newKit()
    f.breakOn('noRegistry')

    for src = 1, 4 do
        f.ammo.Issue(src, 'match-1', oneWeapon({ components = { 'at_scope_medium' } }))
    end

    local seen = select(2, f.log():gsub('would not answer Items', ''))
    t.equals(seen, 1, ('the unreadable registry was reported %d times'):format(seen))
end)

t.test('THE LOG NAMES WHAT WENT ON THE GUN', function()
    -- When fitting a component stopped the weapon being drawn, the line that
    -- recorded the issue said nothing about what had been fitted -- so the
    -- log of a server with the bug was identical to the log of one without
    -- it, and the operator had nothing to send anybody.
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon({
        components = { 'at_scope_medium', 'at_grip' },
    }))

    t.contains(f.log(), 'at_scope_medium+at_grip',
        'the issue line still does not say what was fitted')
end)

t.test('and says so plainly when nothing was', function()
    local f = newKit()

    f.ammo.Issue(1, 'match-1', oneWeapon())

    t.contains(f.log(), 'fitted nothing',
        'a bare weapon was logged without saying it was bare')
end)

t.test('THE START-UP CHECK names every configured attachment ox_inventory lacks', function()
    -- The alternative is what happened: the mistake stays invisible until a
    -- fighter is standing in the arena holding a weapon that will not come
    -- out. A name that is wrong is wrong at boot.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', grip = 'COMPONENT_AT_AR_AFGRIP' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'COMPONENT_AT_AR_AFGRIP', 'the report did not name the bad attachment')
    t.contains(report, 'WEAPON_TEST', 'the report did not say which weapon carries it')
    t.contains(report, 'grip', 'the report did not say which kind it was configured as')
    t.notContains(report, 'at_scope_medium (', 'the report listed a name ox_inventory does have')
end)

t.test('and it reads the hand-written lists and the ammunition components too', function()
    -- Three places can name a component and an operator editing any of them
    -- can make the same mistake. A check that reads only the attachment
    -- table passes a server that is still broken.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = {}
        config.Loadouts.weapons = {
            {
                key = 'w1', weapon = 'WEAPON_TEST', enabled = true,
                components = { 'COMPONENT_BY_HAND' },
                ammoTypes = { { key = 'fmj', item = 'ammo-fmj', component = 'COMPONENT_FMJ_CLIP' } },
            },
        }
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'COMPONENT_BY_HAND', "a weapon's own components list was not checked")
    t.contains(report, 'COMPONENT_FMJ_CLIP', "an ammunition type's component was not checked")
end)

t.test('A NAME UNDER A KIND THIS SERVER NEVER FITS IS NOT REPORTED AS BROKEN', function()
    -- THE FALSE ALARM. The walk took every name in weaponAttachments
    -- whatever KIND it was filed under -- but a kind absent from
    -- Config.Loadouts.attachments.fit is dropped before the component ever
    -- reaches a weapon, so nothing about it can leave a fighter holding an
    -- undrawable gun.
    --
    -- On the shipped config that is both suppressor components, on 39
    -- weapons between them. An operator whose ox_inventory does not carry
    -- those at_* items -- common, since suppressors are exactly what a
    -- server strips -- pressed Tools -> Attachments and was told a component
    -- was being dropped and weapons would be undrawable. Nothing was wrong.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope' }
        config.Loadouts.attachments.deliberatelyUnfitted = { 'suppressor' }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'COMPONENT_NOT_AN_ITEM' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.notContains(report, 'COMPONENT_NOT_AN_ITEM',
        'a bad name under a kind this server never fits was reported as about to break a weapon')
    t.notContains(report, 'DROPPED', 'a config with nothing wrong with it was reported as broken')
end)

t.test('and the SAME name under a kind the server DOES fit is still reported', function()
    -- The control. Without it the test above passes against a report that
    -- has stopped checking anything at all.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope', 'suppressor' }
        config.Loadouts.attachments.deliberatelyUnfitted = {}
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'COMPONENT_NOT_AN_ITEM' },
        }
        config.Loadouts.weapons = {}
    end })

    t.contains(table.concat(f.ammo.AttachmentReport(), '\n'), 'COMPONENT_NOT_AN_ITEM',
        'a bad name under a kind this server DOES fit stopped being reported')
end)

t.test('and a bad name is counted across EVERY weapon it is on, not blamed on one', function()
    -- It kept only the first place it saw and threw the rest away, so a name
    -- configured on thirty-four weapons was reported against ONE of them --
    -- and `pairs` order meant which one changed between restarts, so two
    -- readings of an unchanged config could blame different weapons.
    --
    -- The operator sizes the job from what they read: one name, one weapon,
    -- and they put it behind more urgent work when every weapon in the
    -- catalogue is going out without its flashlight.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'flashlight' }
        config.Loadouts.weaponAttachments = {
            WEAPON_ONE   = { flashlight = 'COMPONENT_NOT_AN_ITEM' },
            WEAPON_TWO   = { flashlight = 'COMPONENT_NOT_AN_ITEM' },
            WEAPON_THREE = { flashlight = 'COMPONENT_NOT_AN_ITEM' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'on 3 place(s)',
        'the report still blames one weapon for a name configured on three')
end)

t.test('and says everything is fine when it is', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', grip = 'at_grip' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'every one is an item this ox_inventory has')
    t.notContains(report, 'DROPPED', 'a clean config was reported as broken')
end)

t.test('and does NOT report a pass when it could not check anything', function()
    -- The check lets names through when it cannot read the item list, which
    -- is right -- stripping every attachment because an export is missing
    -- would be worse. Rounding that up to "all present" in a REPORT is not:
    -- an operator reading it would believe their names had been checked.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'COMPONENT_AT_SCOPE_MEDIUM' },
        }
        config.Loadouts.weapons = {}
    end })
    f.breakOn('noRegistry')

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'NONE checked', 'an unchecked config was reported as checked')
    t.notContains(report, 'every one is an item', 'an unchecked config was reported as clean')
end)

t.test('THE CHECK IS ACTUALLY RUN AT START, not merely available to be run', function()
    -- Every test around this one calls AttachmentReport() by hand, so the
    -- whole boot thread could be emptied and all of them stay green -- and
    -- the claim the feature is sold on is "the mistake is named at boot,
    -- before a fighter is standing in the arena holding a weapon that will
    -- not come out". A report nobody runs names nothing.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'COMPONENT_AT_AR_AFGRIP' } }
        config.Loadouts.weapons = {}
    end })

    -- NOTHING HAS BEEN ASKED FOR YET. This is the console as it stands the
    -- moment the resource has finished loading.
    t.contains(f.log(), 'COMPONENT_AT_AR_AFGRIP',
        'the start-up check did not run, so a broken config reaches the first round unannounced')
end)

t.test('A NAME IS REFUSED ON A SERVER THAT HAS NO COMPONENT ITEMS AT ALL', function()
    -- THE SERVER THE WHOLE CHECK EXISTS FOR, and the one it used to wave
    -- straight through. Telling a component from an ordinary item means
    -- knowing whether this ox_inventory tags anything, and asking that by
    -- watching for a tagged COMPONENT to come past answers "too old to tag"
    -- on a current ox_inventory whose operator has simply not installed the
    -- at_* items. Then `water` goes onto the weapon and the report calls the
    -- config clean -- measured, with that line quoted back.
    --
    -- This registry is what such a server looks like: weapons and ammo,
    -- tagged the way any current build tags them, and not one component.
    local f = newKit({
        knownItems = {
            water = { name = 'water' },
            ammo_rifle = { name = 'ammo_rifle', ammo = true },
            WEAPON_PISTOL = { name = 'WEAPON_PISTOL', weapon = true },
        },
        mutate = function(config)
            config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'water' } }
            config.Loadouts.weapons = {}
        end,
    })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'water', 'an ordinary item was accepted onto a weapon and reported clean')
    t.notContains(report, 'every one is an item', 'a broken config was reported as clean')
end)

t.test('and the verdict on a name does not depend on what was checked before it', function()
    -- The question "does this build tag" is asked of the whole item list, so
    -- it cannot be answered differently on a second call -- which it was,
    -- when the walk armed the very latch it consulted as it went.
    local f = newKit({
        knownItems = {
            water = { name = 'water' },
            at_grip = { name = 'at_grip', component = true },
        },
        mutate = function(config)
            config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'water' } }
            config.Loadouts.weapons = {}
        end,
    })

    local first = table.concat(f.ammo.AttachmentReport(), '\n')
    local second = table.concat(f.ammo.AttachmentReport(), '\n')

    t.equals(first, second, 'the report changed its mind between two calls on one config')
    t.contains(first, 'water', 'the ordinary item was not caught')
end)

t.test('and a registry that comes back is checked again, not written off', function()
    -- `ensure ox_inventory` while the arena is up gives a window where the
    -- export throws. Writing the registry off for the life of the process
    -- left the report saying "NONE checked" forever after one such moment,
    -- about a registry it could read perfectly well -- and its own reason for
    -- existing is to be readable without restarting the server.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'COMPONENT_AT_AR_AFGRIP' } }
        config.Loadouts.weapons = {}
    end })

    f.breakOn('noRegistry')
    t.contains(table.concat(f.ammo.AttachmentReport(), '\n'), 'NONE checked',
        'the broken registry was not reported as unchecked, so this proves nothing')

    f.breakOn('noRegistry', false)
    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.notContains(report, 'NONE checked', 'a registry that came back was still written off')
    t.contains(report, 'COMPONENT_AT_AR_AFGRIP', 'the bad name was not checked once it could be')
end)

t.test('and a registry that answers with rubbish does not take the issue down', function()
    -- The pcall wraps the CALL and not the field reads after it, so an answer
    -- that is neither a table nor nil threw outside any pcall -- during a
    -- live issue, between GiveWeaponToPed and the weapon being drawn.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'at_grip' } }
        config.Loadouts.weapons = {}
    end })
    f.breakOn('junkRegistry')

    local ok = pcall(function() return f.ammo.AttachmentReport() end)
    t.isTrue(ok, 'a registry answering with a number took the report down')

    local issued = pcall(function()
        f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'at_grip' } }))
    end)
    t.isTrue(issued, 'a registry answering with a number took a live weapon issue down')
end)

t.test('and the drop says a name can fail by being the wrong KIND of item', function()
    -- An operator told their item does not exist goes and adds the item, and
    -- the drop persists, because the name was real and simply not a
    -- component. The message has to name both ways in.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'water' } }
        config.Loadouts.weapons = {}
    end })

    f.ammo.Issue(1, 'match-1', oneWeapon({ components = { 'water' } }))
    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    -- MATCHED ON THE CONSOLE LINE'S OWN WORDING. The report is printed to
    -- the same console at start-up and says something similar, so a looser
    -- match here passes on the report's text while the drop line itself
    -- still tells the operator their real item does not exist.
    t.contains(f.log(), 'or has one that is not a component',
        'the console told the operator their real item does not exist')
    t.contains(report, 'not a component',
        'the report told the operator their real item does not exist')
end)

t.test('and a registry that is still filling is asked again, not written off', function()
    -- ox_inventory builds its item list at ITS start, and this resource is
    -- deliberately asked to start early. An export that is there and has
    -- nothing to say yet is not an ox_inventory too old to tag its items --
    -- and remembering it as one answers every later question with it, which
    -- is the whole check switched off for the life of the process.
    local f = newKit({ fail = { emptyRegistry = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'water' } }
        config.Loadouts.weapons = {}
    end })

    t.notContains(table.concat(f.ammo.AttachmentReport(), '\n'), 'DROPPED',
        'an empty registry answered the question anyway, so this proves nothing')

    f.breakOn('emptyRegistry', false)
    t.contains(table.concat(f.ammo.AttachmentReport(), '\n'), 'water',
        'the registry filled up and the check was still answering from the empty one')
end)

-- ======================================================================
-- AND WHETHER ANYBODY CAN READ IT WITHOUT RESTARTING THE SERVER
--
-- The report's own doc said it was split out of the boot thread "so it can
-- be read without restarting the server, the same way IsolationReport and
-- CompatReport are". Those two are genuinely reachable -- a command each and
-- a button each on the admin tablet. This one had one caller in the whole
-- resource, the boot thread, so a restart was the only way to read it --
-- which matters most in exactly the states where the answer CHANGED after
-- start-up: an ox_inventory restarted underneath the arena, an item list
-- that was still filling when the boot check ran.
--
-- BOTH USED TO BE COMMANDS OF THEIR OWN -- /arenaattachments and
-- /arenaunjam -- and neither is any more. This resource registers exactly one
-- command, and both readings are on the admin tablet: Attachments and
-- Held-back stashes under Tools, with the clearing on the Stashes tab.
--
-- SO THE PERMISSION TESTS MOVED WITH THEM, rather than being dropped. The
-- gate is now on `/arenaadmin` and on the tablet's own events, which is where
-- tests/admingates_spec.lua and tests/admintablet_spec.lua check it. What is
-- left to prove HERE is what this file was always for: that the readings can
-- be taken at all without restarting the server, which is exactly the state
-- where the answer has changed since boot.
-- ======================================================================

t.test('the attachment reading can be taken without a restart', function()
    local f = newKit()
    t.isTrue(#f.ammo.AttachmentReport() > 0, 'the report came back with nothing to show')
end)

t.test('and so can the hold list, which had no caller at all before', function()
    -- ArenaAmmo.JamReport is what the tablet's Tools -> Held-back stashes
    -- draws. It takes no src and checks no permission ON PURPOSE: the event
    -- that presses it refuses a non-admin first. What is checked here is that
    -- it answers rather than throws.
    local f = newKit()
    t.isTrue(type(f.ammo.JamReport) == 'function',
        'nothing can list the held-back stashes at all')
    local ok, lines = pcall(f.ammo.JamReport)
    t.isTrue(ok, 'listing the held-back stashes threw')
    t.isTrue(type(lines) == 'table' and #lines > 0, 'the listing came back with nothing to show')
end)

t.test('an unknown name is refused on an ox_inventory that answers with FALSE', function()
    -- ox_inventory said "no such item" two different ways. Up to v2.11.5 the
    -- export is `return ItemList[item] or false`; from v2.12.0 an unknown
    -- name is nil. Reading only nil, `false` fell through to the
    -- cannot-interrogate branch and was LET THROUGH -- so on those builds a
    -- typo went onto the weapon and the weapon would not draw, which is the
    -- one failure this whole check exists to prevent.
    local f = newKit({ fail = { oldFalse = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { scope = 'at_scope_imaginary' } }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')
    t.contains(report, 'at_scope_imaginary',
        'a name this ox_inventory does not have was accepted because it said false, not nil')
    t.contains(report, 'DROPPED')
end)

t.test('and a REAL name is still accepted on that same build, which is the control', function()
    local f = newKit({ fail = { oldFalse = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { grip = 'at_grip' } }
        config.Loadouts.weapons = {}
    end })

    t.notContains(table.concat(f.ammo.AttachmentReport(), '\n'), 'DROPPED',
        'a real component was refused on a build that answers unknown names with false')
end)

t.test('a build that cannot be asked is SAID SO, not reported as a pass', function()
    -- The control for the pair below. inventoryKnowsItem waves a name
    -- through when this ox_inventory tags nothing anywhere -- correctly, on
    -- the evidence -- and a report that rounds that up to "checked" is the
    -- false all-clear the whole layer exists to avoid.
    -- `at_untagged` IS THE WHOLE POINT and a tagged name would prove nothing.
    -- inventoryKnowsItem answers a tagged item off its own tag and never
    -- reaches the unverified branch at all; it is an item with NO tag, on a
    -- build where nothing is tagged, that cannot be told from a component.
    local f = newKit({ fail = { untaggedList = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { scope = 'at_untagged' } }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'could not be asked',
        'a build that tags nothing was reported as having checked the names')
    t.notContains(report, 'every one is an item',
        'names nobody could check were reported as present')
end)

t.test('DEFECT: and the caveat survives a report that ALSO found a bad name', function()
    -- THE CAVEAT USED TO LIVE INSIDE THE `#missing == 0` BRANCH, so the
    -- moment a single name came back provably wrong it vanished -- and that
    -- is the reading an operator acts on.
    --
    -- They are handed the bad names, they fix those, they run it again, and
    -- now the list is empty and they are told every one is an item this
    -- ox_inventory has. The rest were never checked either way, on a build
    -- that cannot be asked, and nothing on the screen ever said so.
    --
    -- It is WORSE on the failing path than on the clean one: the report has
    -- just proved it can find bad names, which is precisely what makes its
    -- silence about the others read as a pass.
    local f = newKit({ fail = { untaggedList = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = {
                -- Real, and carries no tag on a build that tags nothing, so
                -- it is let through unchecked. See the note above.
                scope = 'at_untagged',
                -- Not an item here at all, so it is provably wrong.
                grip = 'at_nothing_like_this',
            },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'at_nothing_like_this',
        'the bad name was not found at all, so this proves nothing about the caveat beside it')
    t.contains(report, 'could not be asked',
        'a report that found one bad name went silent about the names it could not check -- '
        .. 'the operator fixes the one they were shown and believes the rest were verified')
end)

t.test('CONTROL: and a build that CAN be asked adds no caveat to its bad names', function()
    -- A caveat printed unconditionally would be worse than one printed on
    -- the wrong branch: it would teach the operator to ignore it.
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', grip = 'at_nothing_like_this' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'at_nothing_like_this', 'the bad name was not found, so this proves nothing')
    t.notContains(report, 'could not be asked',
        'an ox_inventory that answered every question was reported as unaskable')
end)

t.test('a build that tagged nothing when asked is asked again, not written off', function()
    -- "This list has items and none is tagged" is a statement about the list
    -- AS IT WAS READ. Cached, one early or unlucky read switches the
    -- component check off for the rest of the run -- and the check is the
    -- only thing standing between a wrong name and an undrawable weapon.
    local f = newKit({ fail = { untaggedList = true }, mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { scope = 'water' } }
        config.Loadouts.weapons = {}
    end })

    -- Nothing tags, so `water` is let through: the old-build answer, and the
    -- right one on the evidence available.
    t.notContains(table.concat(f.ammo.AttachmentReport(), '\n'), 'DROPPED',
        'a build with no tags anywhere refused a name, so this proves nothing')

    -- The list is read again and this time it does tag.
    f.breakOn('untaggedList', false)

    t.contains(table.concat(f.ammo.AttachmentReport(), '\n'), 'water',
        'the tagging question was never asked again, so the check stayed off for the run')
end)

-- ======================================================================
-- A KIND THIS SERVER NEVER FITS
--
-- Arena.AttachmentsFor reads only the kinds in Config.Loadouts.attachments.fit.
-- A kind missing from that list is dropped without a word: the component never
-- reaches the weapon, the picker offers no switch, and every name check here
-- passes, because the name was never wrong.
--
-- On the shipped config that is `suppressor` -- fitted to 39 weapons, absent
-- from `fit`, so 39 of 180 slots are dead and the report called the config
-- clean. It IS clean. It also did nothing.
-- ======================================================================

t.test('a kind the server never fits is named, with how many rows it kills', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments = { enabled = true, allowChoose = true, fit = { 'scope', 'grip' } }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
            WEAPON_OTHER = { suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'suppressor', 'the dead kind was not named')
    t.contains(report, 'NEVER PUTS ONE ON', 'the report did not say the rows do nothing')
    t.contains(report, '2 weapon(s)', 'the report did not count the rows it kills')
    t.contains(report, 'attachments.fit', 'the report does not say where to switch it on')
end)

t.test('and a kind the server DOES fit is not reported, which is the control', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments = { enabled = true, allowChoose = true,
            fit = { 'scope', 'suppressor' } }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    t.notContains(table.concat(f.ammo.AttachmentReport(), '\n'), 'NEVER PUTS ONE ON',
        'a kind this server really fits was reported as dead')
end)

t.test('and a server with attachments switched off entirely is not shouted at', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments = { enabled = false, fit = {} }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    t.notContains(table.concat(f.ammo.AttachmentReport(), '\n'), 'NEVER PUTS ONE ON',
        'an operator who turned attachments off was told their config is broken')
end)

t.test('and the warning survives ox_inventory being absent, because it is not about ox_inventory', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments = { enabled = true, allowChoose = true, fit = { 'scope' } }
        -- A SCOPE AS WELL AS THE DEAD SUPPRESSOR. The report only reaches its
        -- ox_inventory line when there is something it would actually fit --
        -- and since names under an unfitted kind stopped being counted (they
        -- cannot break a weapon, so reporting them was a false alarm), a
        -- suppressor on its own leaves nothing to check and the report says
        -- so instead. The dead-kind warning this test is about is unaffected;
        -- it is said before any of that.
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { suppressor = 'at_suppressor_heavy', scope = 'at_scope_medium' },
        }
        config.Loadouts.weapons = {}
    end })
    f.stopInventory()

    local report = table.concat(f.ammo.AttachmentReport(), '\n')
    t.contains(report, 'ox_inventory is not running', 'the fixture did not stop ox_inventory')
    t.contains(report, 'NEVER PUTS ONE ON',
        'the dead-kind warning was hidden behind an ox_inventory early return')
end)

t.test('and switching it on is not offered without saying what it collides with', function()
    -- ox_inventory types a suppressor and a muzzle brake alike as "muzzle" and
    -- a weapon takes ONE. An operator who acts on the advice above with both
    -- configured loses one of the two, and should hear it here rather than
    -- afterwards. `muzzle` is fitted, so `suppressor` is the only dead kind
    -- and the only weapons named anywhere are the colliding ones.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments = { enabled = true, allowChoose = true,
            fit = { 'scope', 'muzzle' } }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { muzzle = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
            WEAPON_OTHER = { suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')
    t.contains(report, 'a weapon takes one', 'the collision was not explained')
    t.contains(report, 'WEAPON_TEST', 'the colliding weapon was not named')
    t.notContains(report, 'WEAPON_OTHER', 'a weapon with no muzzle row was listed as colliding')
end)

t.test('and says so plainly when ox_inventory is not running at all', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.weaponAttachments = { WEAPON_TEST = { scope = 'at_scope_medium' } }
        config.Loadouts.weapons = {}
    end })
    f.stopInventory()

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'ox_inventory is not running')
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

-- ========================================================================
-- A SETTLED DECISION IS NOT A MISTAKE
-- ========================================================================
--
-- The report above walks weaponAttachments for kinds `fit` never names and
-- says those rows do nothing. On the shipped config that finds `suppressor`
-- on 39 weapons -- and being absent from `fit` is DELIBERATE there: a
-- suppressed shot does not put the shooter on the minimap, which changes how
-- a round is fought, and attachments_spec guards it.
--
-- A warning that repeats a settled decision at every boot is the line an
-- operator learns to scroll past, and the next one -- about a kind they
-- really did forget -- goes with it. `deliberatelyUnfitted` is how they
-- answer back, and it must silence exactly the kinds they named.

t.test('THE DEFECT: a kind the operator declared deliberate is not reported', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope' }
        config.Loadouts.attachments.deliberatelyUnfitted = { 'suppressor' }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.notContains(report, 'NEVER PUTS ONE ON',
        'a decision the operator already recorded was reported as a mistake at boot')
end)

t.test('CONTROL: and a kind they did NOT declare is still reported', function()
    -- The whole value of the list is that it silences one thing. If it
    -- silenced the check, the next genuinely forgotten kind goes unnoticed.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope' }
        config.Loadouts.attachments.deliberatelyUnfitted = { 'suppressor' }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy',
                            flashlight = 'at_flashlight' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'NEVER PUTS ONE ON', 'a forgotten kind was silenced along with the declared one')
    t.contains(report, 'flashlight', 'the report did not name the kind that really was forgotten')
    t.notContains(report, '"suppressor" is fitted', 'the declared kind was reported anyway')
end)

t.test('CONTROL: an empty declaration changes nothing', function()
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope' }
        config.Loadouts.attachments.deliberatelyUnfitted = {}
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'NEVER PUTS ONE ON',
        'declaring nothing silenced the check, so the list is a switch rather than a list')
end)

t.test('and naming a kind in BOTH lists is reported as the contradiction it is', function()
    -- The one thing the new list could newly hide. `fit` is what the code
    -- reads, so a kind in both IS fitted while the config claims it never is
    -- -- and staying quiet would leave the operator reading their own config
    -- backwards.
    local f = newKit({ mutate = function(config)
        config.Loadouts.attachments.fit = { 'scope', 'suppressor' }
        config.Loadouts.attachments.deliberatelyUnfitted = { 'suppressor' }
        config.Loadouts.weaponAttachments = {
            WEAPON_TEST = { scope = 'at_scope_medium', suppressor = 'at_suppressor_heavy' },
        }
        config.Loadouts.weapons = {}
    end })

    local report = table.concat(f.ammo.AttachmentReport(), '\n')

    t.contains(report, 'BOTH', 'a config that contradicts itself was reported as fine')
    t.contains(report, 'suppressor', 'the contradiction did not name the kind')
end)

os.exit(t.summary())
