-- Crimson Arena: kit in, kit out. Weapons, rounds, and the safe.

ArenaAmmo = {}

local stashed = {}

local owed = {}

local probed = {}

local issued = {}

--- Characters the empty-read warning has already been said for.
---
--- The retry keeps trying for ever by design, and the warning must not: one
--- entry here is the difference between a line worth reading and a line that
--- teaches an operator to ignore the console.
--- @type table<string, boolean>
local warnedEmptyRead = {}

--- The stash record sitting on `src`, but only when it belongs to whoever
--- holds that server id NOW.
---
--- `stashed` IS KEYED BY SERVER ID AND SERVER IDS ARE RECYCLED, and those two
--- facts are only safe together because a record is normally dropped the
--- moment its exit succeeds. A record whose exit could NOT finish is kept on
--- purpose -- it is what the sweep and the debt list work from -- so it
--- outlives its owner's disconnect, and FiveM will hand that id to the next
--- person who connects.
---
--- What that cost, before this existed: the swapItems guard reads this table
--- to decide who is "in the arena", so the new holder of that id was refused
--- every inventory move they made anywhere on the map -- their own house
--- stash, a glovebox, a shop, handing a friend an item -- for as long as they
--- stayed connected, with the arena's own "you fight with what you were
--- issued" notification explaining it. Nothing cleared it, because the sweep
--- that would have is itself gated on this table.
---
--- A MISSING PLAYER IS NOT A MISMATCH. Between a drop and the next connect
--- there is no character on that id at all, and answering "not theirs" then
--- would quietly switch the guard off for the seconds a player is loading in.
--- @param src number
--- @return table|nil
local function ownRecord(src)
    local record = stashed[src]
    if record == nil then return nil end
    if not Arena.IsKey(record.citizenid) then return record end

    local ok, citizenid = pcall(function()
        local player = ArenaGetPlayer(src)
        return player and player.PlayerData and player.PlayerData.citizenid or nil
    end)
    if not (ok and Arena.IsKey(citizenid)) then return record end

    if citizenid ~= record.citizenid then return nil end
    return record
end

function ArenaAmmo.IsEnabled()
    local ammoItems = Config.Loadouts.ammoItems
    return type(ammoItems) == 'table' and ammoItems.enabled == true
end

local function roundsPerItem()
    local per = Arena.ToInt((Config.Loadouts.ammoItems or {}).roundsPerItem) or 1
    return per > 0 and per or 1
end

--- ox_inventory, or nil when it is not running.
---
--- Looked up per call rather than cached at load: an operator restarting their
--- inventory resource must not leave this file holding a dead handle for the
--- rest of the session.
--- @return table|nil
local function inventory()
    if GetResourceState('ox_inventory') ~= 'started' then return nil end
    return exports.ox_inventory
end

local function itemsFor(rounds)
    local per = roundsPerItem()
    return math.ceil(math.max(0, Arena.ToInt(rounds) or 0) / per)
end

local function doorConfig()
    return (Config.Loadouts.inventory or {})
end

--- Whether a fighter's belongings are actually pinned to them mid-round.
---
--- THE ANSWER IS NOT ALWAYS YES, and a message that assumes it is lies on
--- three real servers. `blockDropsInArena` is a documented switch an operator
--- may turn off; ox_inventory may never start; ox_inventory may refuse the
--- hook. In all three the guard is simply absent and anything dropped in an
--- arena can be picked up by anybody.
---
--- NIL IS NOT FALSE. The hook registers on a thread that waits up to thirty
--- seconds for ox_inventory, so nil means "still starting up", and the
--- config's intent is the honest answer until the thread says otherwise. No
--- match can start in that window anyway.
local dropsHookOn = nil
local function dropsAreBlocked()
    if doorConfig().blockDropsInArena == false then return false end
    return dropsHookOn ~= false
end

--- Item names the door must not stash and must not clear -- as a lookup for
--- the stash loop, and as an array for ox_inventory's ClearInventory, whose
--- second argument is a `keep` list.
---
--- MONEY IS THE ONE THAT MATTERS. The pot and the side-bets are settled in
--- server/match.lua BEFORE anybody is sent home, so a payout is credited
--- while the player's own belongings are still in the stash. On a server
--- where cash is an ox_inventory item, that payout is a money item sitting
--- in an inventory the exit is about to clear -- on the reasoning that
--- everything in it belongs to the arena, which stopped being true the
--- moment the winnings arrived. Bank was never affected, because bank is
--- player data rather than an item; that asymmetry is what makes it look
--- like "cash bets do not pay out".
--- @return table<string, boolean>, string[]
--- The names protected when config.lua does not say. NOT an empty list.
---
--- `neverTouch` is new, and a key that is new is a key most running servers
--- do not have: an operator who keeps their own config.lua across the
--- upgrade -- which is the normal way to upgrade, and the exact population
--- that reported cash payouts vanishing -- has the `inventory` block without
--- this key in it.
---
--- Defaulting that to {} would hand them back the bug the key exists to fix,
--- silently, with the door still on because stripOnEntry ships true. So the
--- safe list is the default and config.lua OVERRIDES it rather than enabling
--- it. Same shape of trap as the weapon catalogue: a new thing whose absence
--- must not mean the broken behaviour.
--- NOTHING, and that is a deliberate answer rather than an oversight.
---
--- Everything a player owns goes into the stash on the way in. The arena's
--- one promise is that a match cannot cost anyone anything, and the way it
--- keeps that promise is by holding their belongings somewhere the round
--- cannot reach -- so anything left OUT of the stash is something the round
--- can reach: droppable, and lootable off their body once ox_inventory has
--- emptied their pockets onto the floor. It is spared the exit's own clear
--- -- see untouchable() -- but that is the smaller of the two ways an item
--- named here is lost, and the round will find the other one first.
local DEFAULT_NEVER_STASH = {}

--- The names the exit's clear must not destroy when config.lua does not say.
--- NOT an empty list.
---
--- These keys are new, and a key that is new is a key most running servers do
--- not have: an operator who keeps their own config.lua across the upgrade --
--- which is the normal way to upgrade, and the exact population that reported
--- cash payouts vanishing -- has the `inventory` block without them in it.
---
--- Defaulting that to {} would hand them back the bug the key exists to fix,
--- silently, with the door still on because stripOnEntry ships true. So the
--- safe list is the default and config.lua OVERRIDES it rather than enabling
--- it. Same shape of trap as the weapon catalogue: a new thing whose absence
--- must not mean the broken behaviour.
local DEFAULT_NEVER_DESTROY = { 'money', 'black_money' }

local function nameSet(names, fallback)
    local map, list = {}, {}
    if type(names) ~= 'table' then names = fallback end
    for _, name in ipairs(names) do
        if Arena.IsKey(name) and not map[name] then
            map[name] = true
            list[#list + 1] = name
        end
    end
    return map, list
end

--- TWO LISTS, NOT ONE, AND THEY ARE NOT THE SAME QUESTION.
---
--- They were one -- `neverTouch` -- and being one is what put a player in an
--- arena still carrying every note they own. The two jobs it was doing:
---
---   ON THE WAY IN, what stow() leaves in a player's pockets rather than
---   putting in the stash. Cash was on this list on the reasoning that it
---   "cannot be spent in an arena and cannot be looted off a body here", and
---   the second half of that stopped being true the moment ox_inventory
---   started dropping a dead fighter's inventory on the floor -- which it
---   always did. A player killed in a round was dropping their whole
---   wallet. Nothing should be in their pockets that the round did not issue,
---   and cash is not an exception to that; it is the most valuable case of
---   it.
---
---   ON THE WAY OUT, what the exit's wholesale ClearInventory must not
---   destroy. Cash HAS to stay on this one. The pot and the side-bets settle
---   in server/match.lua BEFORE anybody is sent home, so on a server where
---   cash is an ox_inventory item the winnings are a money item sitting in an
---   inventory the exit is about to clear -- and the clear is indiscriminate
---   on the reasoning that everything in it belongs to the arena, which
---   stopped being true the moment the winnings arrived. Bank was never
---   affected, because bank is player data rather than an item; that
---   asymmetry is exactly what made it look like "cash bets do not pay out".
---
--- So the same name belongs on the second list and not on the first, and one
--- list could not say that.
--- AND THE ENTRY CLEAR USES THE FIRST LIST, NOT THE SECOND. stow() puts
--- everything in the stash and then wipes the pockets; anything the wipe
--- KEEPS that the stash also took is duplicated -- the player walks into the
--- round still holding it and finds a second copy waiting at the exit.
--- Handing the exit's list to the entry clear did exactly that to cash the
--- moment cash started being stashed. So the two clears get their own lists,
--- for the same reason the two decisions do.
--- @return table<string, boolean> skipMap -- left out of the stash on entry
--- @return string[] skipList -- the same names, for the ENTRY clear
--- @return string[] keepList -- left alone by the EXIT clear
local function untouchable()
    local door = doorConfig()
    local _, rawSkip = nameSet(door.neverStash, DEFAULT_NEVER_STASH)
    local keepMap, keepList = nameSet(door.neverDestroy, DEFAULT_NEVER_DESTROY)

    local arenaIssues = Arena.AllIssuedItems()
    local skipMap, skipList = {}, {}
    for _, name in ipairs(rawSkip) do
        if arenaIssues[name] then
            ArenaLog('door: `neverStash` names %s, which is an item this arena issues. '
                .. 'Ignoring it -- it goes to the stash like everything else, and comes '
                .. 'back at the exit.', name)
        else
            skipMap[name] = true
            skipList[#skipList + 1] = name
        end
    end

    -- NOT STASHING SOMETHING IS NOT PERMISSION TO DESTROY IT.
    --
    -- These were two independent lists, and the gap between them destroyed
    -- things. `neverStash` says "leave this in their pockets on the way in";
    -- the exit then clears whatever is in their pockets, keeping only what
    -- `neverDestroy` names. So an item on the first list and not the second
    -- was carried through the whole round and then wiped at the door -- and
    -- the only warning was one clause in a config comment saying it "meets
    -- the wholesale clear".
    --
    -- There is no reading of "do not take this from them" that means
    -- "destroy it instead", so the first list now implies the second. An
    -- operator who wants an item destroyed can still say so by leaving it
    -- off `neverStash`, which is what puts it safely in the stash anyway.
    --
    -- `skipList` has already had the arena's own items taken out of it above,
    -- so nothing here can hand the kit over.
    for _, name in ipairs(skipList) do
        if not keepMap[name] then
            keepMap[name] = true
            keepList[#keepList + 1] = name
        end
    end

    return skipMap, skipList, keepList
end

--- HOW BIG THE BELONGINGS STASH IS, in slots and in weight.
---
--- ONE COPY, because there were two: stow() registers this stash on the way
--- in and ArenaAmmo.ReturnLeftovers registers it again when it comes back
--- for a return that did not go through, and both had the numbers written
--- into the call. A second copy of a rule is a second copy that drifts, and
--- these two drifting apart means a stash that accepts a player's kit on the
--- way in and refuses to be re-registered the same size on the way out.
---
--- DELIBERATELY MUCH BIGGER THAN ANY PLAYER INVENTORY. The stash is not
--- storage an operator sizes; it is a holding pen the size of one person's
--- pockets, and every slot short of that is somebody's belongings the arena
--- will not accept. It was 100, which is comfortably over ox_inventory's own
--- default of 50 but NOT over a server that has raised it -- and metadata
--- items do not stack, so a player carrying forty weapons is holding forty
--- slots on their own. Overshooting costs nothing: a slot count is a ceiling,
--- not an allocation.
---
--- FAILING IS STILL SAFE, and that is why this is a ceiling and not a check:
--- stow() verifies every single item into the stash before it clears
--- anything, and puts back what it moved the moment one is refused. A stash
--- too small has always meant "this player keeps their own kit and fights
--- with it", never "this player lost something".
local STASH_SLOTS = 500
local STASH_WEIGHT = 10000000

local function stashFor(citizenid)
    local prefix = doorConfig().stashPrefix
    if not Arena.IsKey(prefix) then prefix = 'crimson_arena_' end
    return prefix .. citizenid
end

--- Calls one ox_inventory export and answers the only question that
--- matters: did it actually do the thing.
---
--- THE BUG THIS EXISTS TO KILL. `pcall` returns (ok, result). Written as
---
---     local moved = pcall(function() return ox:AddItem(...) end)
---
--- `moved` is the pcall flag and NOTHING ELSE -- it is true whenever the call
--- did not throw, including when ox_inventory returned `false` to say it
--- refused the item. Every write in stow() and restore() was written that
--- way, and issueWeapons a hundred lines below was not, so the same file held
--- both the right pattern and the wrong one.
---
--- What that cost: stow() moves a player's inventory into their stash and
--- then calls ClearInventory. A stash that REFUSED the write -- full, or an
--- item its data does not know -- reported success, the loop carried on, and
--- the clear destroyed everything the player owned. The one promise this
--- resource makes is that a match cannot cost anyone anything.
---
--- A nil return is treated as success on purpose: several ox_inventory
--- exports return nothing at all on success, and demanding `true` from them
--- would turn every one of those calls into a false failure.
--- @param label string -- what to call this in the log
--- @param fn fun():any
--- @return boolean did
local function oxDid(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        ArenaLog('door: %s threw -- %s', label, tostring(result))
        return false
    end
    if result == false then
        ArenaLog('door: %s was REFUSED by ox_inventory.', label)
        return false
    end
    return true
end

--- Every real item in one ox_inventory items table, in slot order.
---
--- WHY THIS IS NOT `ipairs`, AND WHY IT COST PEOPLE THEIR BELONGINGS.
---
--- ox_inventory's GetInventoryItems hands back the inventory's own `items`
--- table, and that table is KEYED BY SLOT rather than packed into an array.
--- A player carrying things in slots 1, 2 and 5 has NOTHING AT ALL at 3 and
--- 4 -- which is the ordinary state of any inventory somebody has moved
--- things around in. `ipairs` stops dead at the first hole, so every slot
--- past the first gap was invisible to this file.
---
--- What that cost, in both directions:
---
---   stow()      never put those items in the stash -- and then called
---               ClearInventory on the inventory they were still sitting in.
---               They were DESTROYED, on the way in, by the one function
---               whose whole job is to keep them safe.
---
---   handBack()  never handed them back. They stayed in the stash and
---               nothing counted a failure, because nothing had looked --
---               so the exit reported a clean return over a stash that
---               still had items in it.
---
--- Both read from a player's seat as "the arena ate some of my stuff", and
--- both hit only the players whose inventory happens to have a hole in it,
--- which is why three people can leave the same match and one of them come
--- out short.
---
--- No test ever saw it, and none could: a fake ox_inventory returns a packed
--- array, which is the one shape where `ipairs` and this function agree.
---
--- Non-tables are skipped rather than trusted. Some builds park `false` in an
--- empty slot instead of leaving it nil, and `item.name` on a boolean throws
--- -- which would take the whole stow down rather than one slot.
--- @param items table
--- @return table[]
local function itemsIn(items)
    local out = {}
    if type(items) ~= 'table' then return out end

    for slot, item in pairs(items) do
        if type(item) == 'table' and Arena.IsKey(item.name) then
            out[#out + 1] = { item = item, slot = tonumber(item.slot) or tonumber(slot) or 0 }
        end
    end

    table.sort(out, function(a, b) return a.slot < b.slot end)

    local flat = {}
    for index, row in ipairs(out) do flat[index] = row.item end
    return flat
end

local function stow(src, citizenid)
    local ox = inventory()
    if not ox then
        -- SAID OUT LOUD, because the caller now tells the PLAYER their gear
        -- was not put away and an operator reading a report needs the other
        -- half of it. `inventory()` is re-resolved per call on purpose, so
        -- this fires when ox_inventory stops between the caller's check and
        -- this one -- a restart, which is exactly when it is worth knowing.
        -- DO NOT make this silent again.
        ArenaLog('door: ox_inventory is not running -- %s keeps their own kit.', tostring(src))
        return false, 0
    end

    local stash = stashFor(citizenid)

    local registered = oxDid('registering stash ' .. stash, function()
        return ox:RegisterStash(stash, 'Arena Belongings', STASH_SLOTS, STASH_WEIGHT, citizenid)
    end)
    if not registered then
        ArenaLog('door: could not register the stash for %s -- they keep their own kit.', tostring(src))
        return false, 0
    end

    local ok, items = pcall(function() return ox:GetInventoryItems(src) end)
    if not ok or type(items) ~= 'table' then
        -- THE THROW IS PRINTED. `items` holds the error when `ok` is false,
        -- and this discarded it -- leaving an operator a consequence with no
        -- cause, which is the one thing the exit side never does (handBack
        -- prints its own). DO NOT drop it again.
        ArenaLog('door: could not read %s\'s inventory (%s) -- they keep their own kit.',
            tostring(src), ok and 'it answered with no item list' or tostring(items))
        return false, 0
    end

    -- Nothing to put away is a success, not a failure: an empty-handed player
    -- is still stripped-and-restored correctly, they simply have nothing.
    -- The ENTRY clear's list, which is the same names the stash skipped and
    -- deliberately NOT the exit's -- see untouchable().
    local skip, keep = untouchable()
    local stowed = {}

    for _, item in ipairs(itemsIn(items)) do
        if not skip[item.name] then
        local moved = oxDid(('stashing %s x%s'):format(tostring(item.name), tostring(item.count)), function()
            return ox:AddItem(stash, item.name, item.count, item.metadata)
        end)
        if not moved then
            ArenaLog('door: could not stash %s x%s for %s -- putting it all back and letting them keep their kit.',
                tostring(item.name), tostring(item.count), tostring(src))
            for _, done in ipairs(stowed) do
                pcall(function() return ox:RemoveItem(stash, done.name, done.count, done.metadata) end)
            end
            return false, 0
        end
        stowed[#stowed + 1] = item
        end
    end

    local cleared = oxDid('clearing ' .. tostring(src) .. "'s inventory", function()
        return ox:ClearInventory(src, keep)
    end)
    if not cleared then
        ArenaLog('door: stashed %s\'s kit but could not clear their inventory -- putting it back.', tostring(src))
        for _, item in ipairs(stowed) do
            pcall(function() return ox:RemoveItem(stash, item.name, item.count, item.metadata) end)
        end
        return false, 0
    end

    return true, #stowed
end

local function handBack(ox, src, stash)
    local ok, items = pcall(function() return ox:GetInventoryItems(stash) end)
    if not ok or type(items) ~= 'table' then
        ArenaLog('door: could not read %s\'s stash (%s). THEIR KIT IS STILL IN IT -- it is a real ox_inventory stash and can be opened.',
            tostring(src), stash)
        return false, 0, 0
    end

    local failures, returned = 0, 0
    for _, item in ipairs(itemsIn(items)) do
        -- PROOF, NOT MERELY THE ABSENCE OF A DENIAL, and this is the one
        -- call in the file that has to be read that way.
        --
        -- The line after this REMOVES the item from the stash, which is the
        -- only irreversible thing the door does: the stash is where an item
        -- is safe, and taking it out on a false assumption destroys it. So
        -- this does not go through oxDid, which treats a nil return as
        -- success -- a reasonable rule for registering a stash or clearing
        -- an inventory, where nothing is lost by believing it, and the wrong
        -- one here. ox_inventory's AddItem answers `success, response`; a
        -- nil where a true belongs is a version or a code path we do not
        -- understand, and the safe reading of "I do not understand this
        -- answer" is to leave the item where it is.
        --
        -- The cost of being wrong in this direction is a loud line and an
        -- item still sitting in a stash the player can be pointed at. The
        -- cost of being wrong in the other direction is their belongings.
        local called, answer = pcall(function()
            return ox:AddItem(src, item.name, item.count, item.metadata)
        end)

        if not called then
            ArenaLog('door: returning %s x%s to %s threw -- %s. It stays in stash %s.',
                tostring(item.name), tostring(item.count), tostring(src), tostring(answer), stash)
        elseif answer == nil then
            ArenaLog('door: ox_inventory gave no answer when returning %s x%s to %s. Treating that as a refusal: it stays in stash %s rather than being taken out of it on a guess.',
                tostring(item.name), tostring(item.count), tostring(src), stash)
        elseif answer == false then
            ArenaLog('door: returning %s x%s to %s was REFUSED by ox_inventory -- most often a full inventory or a weight limit. It stays in stash %s.',
                tostring(item.name), tostring(item.count), tostring(src), stash)
        end

        if called and answer ~= nil and answer ~= false then
            pcall(function() return ox:RemoveItem(stash, item.name, item.count, item.metadata) end)
            returned = returned + 1
        else
            failures = failures + 1
        end
    end

    return true, failures, returned
end

local function restore(src, record)
    local ox = inventory()
    if not ox then
        ArenaLog('door: ox_inventory is gone, so %s keeps the arena kit and their own is still stashed at %s.',
            tostring(src), record.stash)
        return false
    end

    -- Everything the arena produced goes, whatever it is and however they came
    -- by it. This is the line that makes looting and floor-scavenging moot.
    --
    -- ITS RESULT IS READ NOW. It used to be thrown away entirely, so a clear
    -- that failed let the whole issued loadout walk out of the arena on top
    -- of the player's own kit -- the exact leak this line exists to prevent,
    -- reported as a clean exit. It is not fatal to the restore below (their
    -- own belongings still have to come back either way), so it is logged
    -- loudly and carried, rather than returned on.
    -- ONCE PER RECORD, AND THIS IS A DATA-LOSS GUARD, not tidiness.
    --
    -- The clear is here to destroy the ARENA's kit on the way out. It is
    -- indiscriminate, because at that moment everything the player is
    -- carrying belongs to the arena -- their own is in the stash.
    --
    -- THAT STOPS BEING TRUE THE MOMENT A RETURN ONLY PARTLY SUCCEEDS.
    -- handBack takes each item OUT of the stash as it hands it over, so a
    -- half-finished return leaves some of their belongings in their pockets
    -- and the rest in the stash -- and the record is deliberately kept, so
    -- the sweep can come back for the remainder. Run this clear a second
    -- time against that record and it destroys everything the first attempt
    -- gave back, then hands over the small remainder and reports a clean
    -- exit. The player is simply short, and nothing anywhere says so.
    --
    -- So the record remembers that its clear has been spent. A second pass
    -- takes the arena's weapons back BY NAME instead -- see ArenaAmmo.Reclaim,
    -- which does that before calling this -- which removes what the arena
    -- issued without touching anything else.
    -- WHETHER THE WHOLESALE CLEAR ACTUALLY HAPPENED, reported to the caller.
    --
    -- This function went on to return plain `true` whatever the clear did,
    -- so ArenaAmmo.Reclaim took its success branch and called forgetWeapons
    -- -- dropping the arena's record of every weapon, round and supply it
    -- had issued, while all of it was still in the player's pockets because
    -- the clear had just been refused. They left with their own belongings
    -- AND the whole arena kit, permanently: no later exit could take it
    -- back, because nothing remembered issuing it.
    local wiped = true

    if not record.cleared then
        local _, _, keep = untouchable()
        if not oxDid('clearing the arena kit from ' .. tostring(src), function()
            return ox:ClearInventory(src, keep)
        end) then
            ArenaLog('door: %s LEFT THE ARENA STILL HOLDING THE KIT IT ISSUED -- their own is being returned on top of it, and the arena kit is being taken back by name instead.',
                tostring(src))
            wiped = false
        end
        record.cleared = true
    end

    local readable, failures, returned = handBack(ox, src, record.stash)
    if not readable then return false, wiped end

    -- A STASH THAT READ EMPTY IS NOT A STASH THAT WAS EMPTY.
    --
    -- handBack cannot tell those apart: ox_inventory answers an empty list
    -- for both, and the second is what a forgotten or re-registered stash
    -- looks like -- a resource restart, a database hiccup, a stash id that
    -- came back namespaced differently. So a return of nothing was reported
    -- as a clean return of nothing: the record was dropped, `owed` was
    -- cleared, the retry had nothing to work from, and the player walked out
    -- with empty pockets while every log in the file said the exit had gone
    -- perfectly. Their belongings may well still be in the stash -- it is a
    -- real one, and ArenaAmmo.StashOf still names it -- but nothing in this
    -- resource remembered to go back for them.
    --
    -- The record knows how many items went IN. That is the one fact that can
    -- tell the two apart, and it is why stow() counts them.
    if returned == 0 and failures == 0 and (Arena.ToInt(record.stowedCount) or 0) > 0 then
        ArenaLog('door: %s\'s stash (%s) READ EMPTY, and %d item(s) were put into it. ' ..
            'NOTHING has been handed back and the record is being kept so the sweep can try again -- ' ..
            'the stash is a real one and can be opened.',
            tostring(src), record.stash, Arena.ToInt(record.stowedCount) or 0)
        return false, wiped
    end

    if failures > 0 then
        -- Deliberately NOT cleared. Anything that would not go back is still
        -- sitting in a stash the player can be pointed at.
        ArenaLog('door: %d item(s) of %s\'s could not be returned and are still in stash %s.',
            failures, tostring(src), record.stash)
        return false, wiped
    end

    return true, wiped
end

local issuedWeapons = {}

local issuedAmmo = {}

local issuedSupplies = {}

local heldBefore = {}

local function floorFor(matchId, src, item)
    local byMatch = heldBefore[matchId]
    local mine = byMatch and byMatch[src]
    return mine and (Arena.ToInt(mine[item]) or 0) or 0
end

local function rememberHeld(ox, src, matchId, item)
    if not (Arena.IsKey(matchId) and Arena.IsKey(item)) then return end

    heldBefore[matchId] = heldBefore[matchId] or {}
    local mine = heldBefore[matchId][src] or {}
    heldBefore[matchId][src] = mine
    if mine[item] ~= nil then return end

    local ok, answer = pcall(function() return ox:GetItemCount(src, item) end)
    mine[item] = ok and (Arena.ToInt(answer) or 0) or 0
end

local function splitRounds(entry)
    local total = math.max(0, Arena.ToInt(entry.ammo) or 0)
    if total == 0 then return 0, 0 end

    local melee = Arena.IsKey(entry.key) and Arena.GetWeaponByKey(entry.key) or nil
    if melee ~= nil and Arena.IsMeleeWeapon(melee) then return 0, 0 end

    if not ArenaAmmo.IsEnabled() or not Arena.IsKey(entry.ammoTypeItem) then
        return total, 0
    end

    local catalogue = Arena.IsKey(entry.key) and Arena.GetWeaponByKey(entry.key) or nil

    local loaded = Arena.MagazineFor(catalogue, total)
    return loaded, total - loaded
end

local function weaponMetadata(entry)
    local metadata = {}

    local loaded = select(1, splitRounds(entry))
    if loaded > 0 then metadata.ammo = loaded end

    if type(entry.components) == 'table' and #entry.components > 0 then
        local parts = {}
        for _, component in ipairs(entry.components) do
            if Arena.IsKey(component) then parts[#parts + 1] = component end
        end
        if #parts > 0 then metadata.components = parts end
    end

    local tint = Arena.ToInt(entry.tint) or 0
    if tint > 0 then metadata.tint = tint end

    return metadata, loaded
end

local function issueSpareRounds(ox, src, matchId, entry, pass)
    local item = entry.ammoTypeItem
    local _, spare = splitRounds(entry)
    local count = itemsFor(spare)
    if not (Arena.IsKey(item) and count > 0) then return true, 0 end

    local counted, answer = pcall(function() return ox:GetItemCount(src, item) end)
    if counted then
        local held = math.max(0, Arena.ToInt(answer) or 0)

        held = math.max(0, held - (Arena.ToInt(pass and pass[item]) or 0))

        count = count - held
        if count <= 0 then return true, 0 end
    end

    rememberHeld(ox, src, matchId, item)

    local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
    if not (ok and granted ~= false) then
        ArenaLog('ammo: %s x%d was refused for %s -- either their inventory has no room for '
            .. 'it (check the round weight against your ox_inventory player limit) or the '
            .. 'item does not exist on this server.',
            item, count, tostring(src))
        return false, 0
    end

    issuedAmmo[matchId] = issuedAmmo[matchId] or {}
    local byName = issuedAmmo[matchId][src] or {}
    issuedAmmo[matchId][src] = byName
    byName[item] = (byName[item] or 0) + count

    if pass then pass[item] = (pass[item] or 0) + count end

    issued[matchId] = issued[matchId] or {}
    issued[matchId][src] = (issued[matchId][src] or 0) + count

    ArenaDebug('ammo: gave %s x%d to %s.', item, count, tostring(src))

    return true, count
end

local function issueWeapons(ox, src, matchId, loadout)
    local failed = {}
    local given = {}

    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) then
            local metadata, loaded = weaponMetadata(entry)

            local ok, accepted = pcall(function() return ox:AddItem(src, name, 1, metadata) end)
            if ok and accepted ~= false then
                given[#given + 1] = { name = name, metadata = metadata }
                ArenaLog('weapons: gave %s x1 to %s (ammo %d).', name, tostring(src), loaded)
            else
                failed[#failed + 1] = entry.key or name
                ArenaLog('weapons: ox_inventory would not give %s to %s. Check that item exists in your ox_inventory weapon data -- the player is in the arena unarmed.',
                    tostring(name), tostring(src))
            end
        end
    end

    issuedWeapons[matchId] = issuedWeapons[matchId] or {}
    issuedWeapons[matchId][src] = given

    if #given == 0 and #(loadout.weapons or {}) > 0 then
        ArenaLog('weapons: %s was issued NOTHING despite a loadout of %d weapon(s). Every name was refused by ox_inventory -- check they exist in its weapon data, spelled exactly as in Config.Loadouts.weapons.',
            tostring(src), #loadout.weapons)
    end

    return failed
end

--- Takes back up to `count` of one stackable item, never more than the
--- player is actually holding.
---
--- ONE COPY, DELIBERATELY, because there were two and only one of them was
--- right. Ammunition and supplies are reclaimed by separate loops below, the
--- supplies loop was taught to clamp against what a player still holds, and
--- the ammunition loop was not -- so a fighter who fired their weapon kept
--- every round they had left.
---
--- WHY CLAMPING IS THE WHOLE JOB. ox_inventory refuses a removal it cannot
--- satisfy in full on most builds: it does not take what is there and shrug.
--- Ask a player holding 120 rounds for the 250 they were issued and the
--- answer is no, and all 120 leave the arena with them.
---
--- A build with no counter at all is asked for the full amount. Taking back
--- what was issued is the right answer when nothing can tell us otherwise,
--- and a refusal there costs the arena nothing it had.
--- @param ox table
--- @param src number
--- @param item string
--- @param count integer -- how much was issued
local function takeBack(ox, src, item, count, floor)
    local ok, answer = pcall(function() return ox:GetItemCount(src, item) end)
    local held = ok and (Arena.ToInt(answer) or 0) or count

    local mine = math.max(0, held - math.max(0, Arena.ToInt(floor) or 0))

    local take = math.min(Arena.ToInt(count) or 0, mine)
    if take > 0 then
        pcall(function() return ox:RemoveItem(src, item, take) end)
    end
end

local function takeRungBack(ox, src, record, name)
    if not Arena.IsKey(name) then return nil, false end

    local listed = false
    for _, row in ipairs(record) do
        if row.name == name then listed = true break end
    end
    if not listed then return nil, false end

    if not oxDid('taking back the tier weapon ' .. name,
        function() return ox:RemoveItem(src, name, 1) end)
    then
        return nil, true
    end

    local taken = nil
    for index = #record, 1, -1 do
        if record[index].name == name then
            taken = taken or record[index]
            table.remove(record, index)
        end
    end

    return taken, false
end

local function putRungsBack(ox, src, record, rows, context)
    for _, row in ipairs(rows) do
        local back, gave = pcall(function() return ox:AddItem(src, row.name, 1, row.metadata) end)
        if back and gave ~= false then
            record[#record + 1] = row
        else
            ArenaLog('weapons: %s was left empty-handed -- ox_inventory would take neither %s back nor %s away.',
                tostring(src), tostring(context), tostring(row.name))
        end
    end
end

--- Takes back every round the arena has issued this player EXCEPT the ones
--- the tier they are moving onto fires.
---
--- THIS IS THE OTHER HALF OF THE SWEEP ABOVE, and without it a ladder was a
--- one-way ammunition dispenser. A climber who walked a boundary collected
--- another batch of loose rounds each way -- deaths cost no lives in this
--- mode, so the loop was free -- and every rung they had ever stood on left
--- its ammunition in their pockets for the rest of the round. Ten tiers in,
--- a player was carrying ten calibres and could reload a gun they no longer
--- had.
---
--- WHAT THEY WALKED IN WITH IS NEVER TOUCHED. `floorFor` is the line a
--- player was already holding before the arena added to it, and the arena's
--- claim is only ever on what sits above it -- so with the door off
--- (`stripOnEntry = false`) a fighter's own ammunition is theirs throughout.
---
--- AND THE LEDGER IS CLEARED WITH IT, so the exit does not ask for the same
--- rounds a second time -- which on a name that collides with something of
--- the player's own takes theirs.
--- @param ox table
--- @param src number
--- @param matchId string
--- @param keep string|nil -- the incoming tier's ammo item, left alone
local function dropRungRounds(ox, src, matchId, keep)
    local byPlayer = issuedAmmo[matchId]
    local given = byPlayer and byPlayer[src] or nil
    if type(given) ~= 'table' then return end

    for item, count in pairs(given) do
        if item ~= keep then
            takeBack(ox, src, item, count, floorFor(matchId, src, item))
            given[item] = nil
            ArenaDebug('weapons: took %s back off %s -- it belongs to a tier they have left.',
                tostring(item), tostring(src))
        end
    end
end

function ArenaAmmo.SwapWeapon(src, matchId, removeWeapon, entry, alsoClear)
    local ox = inventory()
    if not ox then return false, 'no-inventory' end
    if type(entry) ~= 'table' or not Arena.IsKey(entry.weapon) then return false, 'refused' end

    local record = issuedWeapons[matchId] and issuedWeapons[matchId][src] or nil
    if type(record) ~= 'table' then
        ArenaDebug('weapons: no issued record for %s on match %s -- the tier swap is refused.',
            tostring(src), tostring(matchId))
        return false, 'refused'
    end

    local sweep = {}
    for _, name in ipairs(type(alsoClear) == 'table' and alsoClear or {}) do
        if Arena.IsKey(name) then sweep[name] = true end
    end

    -- THE RUNG THEY WERE STANDING ON IS THE ONE THAT CAN REFUSE THE SWAP.
    --
    -- It is taken first and on its own because a refusal there means
    -- something specific: the player parked that weapon somewhere
    -- ox_inventory cannot reach it -- a trunk, between the kill and the
    -- promotion -- and advancing anyway would arm them with both tiers and
    -- lose the lower one off the arena's books. That is the anti-parking
    -- rule, and it is unchanged.
    --
    -- EVERY OTHER RUNG IS BEST EFFORT, and deliberately cannot refuse. A
    -- weapon from four tiers ago that will not come off is not something the
    -- climber is doing right now, and letting it halt the ladder would freeze
    -- a player on a tier for the rest of a round over a gun they parked
    -- minutes ago. It is logged and left; the next tier change tries again.
    local taken = {}
    if Arena.IsKey(removeWeapon) then
        sweep[removeWeapon] = nil
        local row, refused = takeRungBack(ox, src, record, removeWeapon)
        if refused then return false, 'refused' end
        if row then taken[#taken + 1] = row end
    end

    for name in pairs(sweep) do
        local row, refused = takeRungBack(ox, src, record, name)
        if row then taken[#taken + 1] = row end
        if refused then
            ArenaDebug('weapons: %s is still holding the tier weapon %s -- ox_inventory would not take it back.',
                tostring(src), tostring(name))
        end
    end

    dropRungRounds(ox, src, matchId, entry.ammoTypeItem)

    local metadata, loaded = weaponMetadata(entry)

    local ok, accepted = pcall(function() return ox:AddItem(src, entry.weapon, 1, metadata) end)
    if not (ok and accepted ~= false) then
        putRungsBack(ox, src, record, taken, entry.weapon)

        ArenaLog('weapons: ox_inventory would not give the tier weapon %s to %s -- they keep the tier they had.',
            tostring(entry.weapon), tostring(src))
        return false, 'refused'
    end

    record[#record + 1] = { name = entry.weapon, metadata = metadata }

    -- AND THE ROUNDS THAT DO NOT FIT IN IT. `weaponMetadata` above loaded
    -- one magazine; the rest of the pick is an inventory item, and without
    -- this the ladder handed out half a weapon.
    --
    -- Measured before this line existed: a 60-round tier pistol arrived with
    -- 30 in the magazine and no ammo item at all, a 150-round rifle with 60.
    -- Since tier 1 is melee, ArenaAmmo.Issue hands a climber no rounds on
    -- the way in either -- so from their first promotion they held one
    -- magazine and owned nothing to reload from for the rest of the round.
    -- Switching `ammoItems.enabled` ON halved what the mode carried, which
    -- is the exact opposite of what that setting promises.
    --
    -- A REFUSAL HERE DOES NOT UNDO THE SWAP. They are holding the right
    -- weapon with a full magazine; the spare rounds would not fit, which is
    -- the same outcome ArenaAmmo.Issue accepts and logs.
    issueSpareRounds(ox, src, matchId, entry)

    ArenaDebug('weapons: the ladder gave %s x1 to %s (magazine %d).', entry.weapon, tostring(src), loaded)
    return true, nil
end

function ArenaAmmo.Refresh(src, matchId, loadout)
    if type(src) ~= 'number' or src <= 0 or not Arena.IsKey(matchId) then return false end
    if type(loadout) ~= 'table' then return false end

    local ox = inventory()
    if not ox then return false end

    local record = issuedWeapons[matchId] and issuedWeapons[matchId][src] or nil
    if type(record) ~= 'table' then return false end

    local pass = {}

    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) then
            local metadata = weaponMetadata(entry)

            local roundsOk = issueSpareRounds(ox, src, matchId, entry, pass)
            local armed = roundsOk
                or (Config.Loadouts.ammoItems or {}).allowWeaponWithoutAmmoItem ~= false

            local taken = takeRungBack(ox, src, record, name)

            if not armed then
                ArenaLog('weapons: %s was not re-issued to %s on respawn -- their rounds could not be '
                    .. 'issued and this server does not arm an empty gun.', tostring(name), tostring(src))
            else
                local ok, accepted = pcall(function() return ox:AddItem(src, name, 1, metadata) end)
                if ok and accepted ~= false then
                    record[#record + 1] = { name = name, metadata = metadata }
                else
                    if taken then putRungsBack(ox, src, record, { taken }, name) end
                    ArenaLog('weapons: could not refresh %s for %s -- ox_inventory refused it. They keep what they had.',
                        tostring(name), tostring(src))
                end
            end
        end
    end

    issuedSupplies[matchId] = issuedSupplies[matchId] or {}
    local supplyRecord = issuedSupplies[matchId][src] or {}
    issuedSupplies[matchId][src] = supplyRecord

    for _, entry in ipairs(loadout.supplies or {}) do
        local item = entry.item
        local wanted = Arena.ToInt(entry.count) or 0
        if Arena.IsKey(item) and wanted > 0 then
            rememberHeld(ox, src, matchId, item)

            local counted, answer = pcall(function() return ox:GetItemCount(src, item) end)
            local held = counted and math.max(0, Arena.ToInt(answer) or 0) or 0
            local mine = math.max(0, held - floorFor(matchId, src, item))

            local short = wanted - mine
            if short > 0 then
                local ok, granted = pcall(function() return ox:AddItem(src, item, short) end)
                if ok and granted ~= false then
                    supplyRecord[item] = (supplyRecord[item] or 0) + short
                    ArenaDebug('supplies: refreshed %s x%d for %s.', item, short, tostring(src))
                else
                    ArenaLog('supplies: %s x%d was refused for %s on a respawn -- either their inventory has '
                        .. 'no room for it or the item does not exist on this server.',
                        item, short, tostring(src))
                end
            end
        end
    end

    ArenaDebug('weapons: refreshed the loadout for %s on match %s.', tostring(src), tostring(matchId))
    return true
end

function ArenaAmmo.GrantRounds(src, matchId, item, count)
    local ox = inventory()
    if not ox then return false end

    if not (type(src) == 'number' and src > 0) then return false end
    if not Arena.IsKey(matchId) then return false end
    if not Arena.IsKey(item) then return false end

    local amount = Arena.ToInt(count) or 0
    if amount <= 0 then return false end

    -- THE SAME SWITCH EVERY OTHER ISSUE PATH IS BEHIND, and this is the only
    -- one that reached ox_inventory without it. Every sibling goes through
    -- splitRounds, which returns a spare of nothing when ammo items are off,
    -- so no ammo item ever reaches a player on such a server. This one read
    -- only the item NAME -- and Arena.ResolveWeaponEntry fills that in from
    -- the weapon catalogue whatever the switch says. On a server that turned
    -- ammo items off because those items do not exist in its ox_inventory
    -- data, every kill fired a refused AddItem into the debug log and the
    -- reward silently did nothing.
    if not ArenaAmmo.IsEnabled() then return false end

    rememberHeld(ox, src, matchId, item)

    local ok, granted = pcall(function() return ox:AddItem(src, item, amount) end)
    if not (ok and granted ~= false) then
        ArenaDebug('kill ammo: %s x%d was refused for %s -- no room, or no such item.',
            item, amount, tostring(src))
        return false
    end

    issuedAmmo[matchId] = issuedAmmo[matchId] or {}
    local byName = issuedAmmo[matchId][src] or {}
    issuedAmmo[matchId][src] = byName
    byName[item] = (byName[item] or 0) + amount

    issued[matchId] = issued[matchId] or {}
    issued[matchId][src] = (issued[matchId][src] or 0) + amount

    ArenaDebug('kill ammo: gave %s x%d to %s.', item, amount, tostring(src))
    return true
end

function ArenaAmmo.GrantSupply(src, matchId, item, count)
    local ox = inventory()
    if not ox then return false end

    if not (type(src) == 'number' and src > 0) then return false end
    if not Arena.IsKey(matchId) then return false end
    if not Arena.IsKey(item) then return false end

    local amount = Arena.ToInt(count) or 0
    if amount <= 0 then return false end

    rememberHeld(ox, src, matchId, item)

    local ok, granted = pcall(function() return ox:AddItem(src, item, amount) end)
    if not (ok and granted ~= false) then
        ArenaDebug('kill reward: %s x%d was refused for %s -- no room, or no such item.',
            item, amount, tostring(src))
        return false
    end

    issuedSupplies[matchId] = issuedSupplies[matchId] or {}
    local supplyRecord = issuedSupplies[matchId][src] or {}
    issuedSupplies[matchId][src] = supplyRecord
    supplyRecord[item] = (supplyRecord[item] or 0) + amount

    ArenaDebug('kill reward: gave %s x%d to %s.', item, amount, tostring(src))
    return true
end

local function reclaimWeapons(ox, src)
    for _, byPlayer in pairs(issuedWeapons) do
        local given = byPlayer[src]
        if given then
            for _, item in ipairs(given) do
                -- BY NAME ONLY. ox_inventory treats a metadata argument on a
                -- removal as a FILTER: it takes back the copy whose metadata
                -- MATCHES, and the metadata this record holds is what the
                -- weapon was ISSUED with -- `{ ammo = <a full magazine> }`.
                -- A player who fires a single round no longer matches it, so
                -- the removal found nothing and the arena's own gun stayed in
                -- their pockets. With the door on that never showed, because
                -- `restore` clears the inventory wholesale; with it off --
                -- a documented, supported setting -- it was a free firearm
                -- per player per round.
                --
                -- The metadata is still kept on the record, because
                -- SwapWeapon's rollback re-adds the weapon with it. It is
                -- only the removal that must not filter on it.
                pcall(function() return ox:RemoveItem(src, item.name, 1) end)
            end
            byPlayer[src] = nil
        end
    end

    for matchId, byPlayer in pairs(issuedAmmo) do
        local given = byPlayer[src]
        if given then
            for item, count in pairs(given) do
                takeBack(ox, src, item, count, floorFor(matchId, src, item))
            end
            byPlayer[src] = nil
        end
    end

    for matchId, byPlayer in pairs(issuedSupplies) do
        local given = byPlayer[src]
        if given then
            for item, count in pairs(given) do
                takeBack(ox, src, item, count, floorFor(matchId, src, item))
            end
            byPlayer[src] = nil
        end
    end
end

local function forgetWeapons(src)
    for _, byPlayer in pairs(issuedWeapons) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedAmmo) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedSupplies) do byPlayer[src] = nil end
end

local function removeWeaponsByKey(ox, src, matchId, keys, loadout)
    local wanted = {}
    for _, key in ipairs(keys) do wanted[key] = true end

    local removed = {}
    -- BY NAME, because that is what the issued record is keyed on. `wanted`
    -- holds whatever spelling the failure list used -- and Issue builds that
    -- from `entry.key or entry.weapon`, so on any loadout with keys it holds
    -- KEYS and nothing in it ever matches a record's `name`. Forgetting off
    -- `wanted` therefore forgot nothing at all on the shipped config, and
    -- left every confiscated weapon listed as still issued.
    -- WHAT THE ARENA ACTUALLY HANDED OVER, read BEFORE anything is taken.
    --
    -- `keys` is the FAILURE list, and a weapon can be on it for two quite
    -- different reasons: its ammunition would not go, or the weapon itself
    -- would not. Only the first is what this function is for -- "do not let
    -- anyone fight with an empty gun that looks loaded". The second means
    -- the player never got it, and removing a weapon nobody issued reaches
    -- straight past the arena into whatever the player brought in
    -- themselves: with the door off they are carrying their own kit, and if
    -- they own that weapon, ox_inventory takes THEIR copy and destroys it.
    --
    -- So the record of what was issued is the gate. It is read here rather
    -- than only below, where it was used solely for forgetting.
    local issuedHere = {}
    for _, record in ipairs((issuedWeapons[matchId] or {})[src] or {}) do
        if type(record) == 'table' and Arena.IsKey(record.name) then
            issuedHere[record.name] = true
        end
    end

    local takenBack = {}
    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) and (wanted[entry.key] or wanted[name]) and issuedHere[name] then
            if oxDid('taking back ' .. name, function() return ox:RemoveItem(src, name, 1) end) then
                removed[#removed + 1] = name
                takenBack[name] = true
            end
        end
    end

    local held = (issuedWeapons[matchId] or {})[src]
    if type(held) == 'table' then
        for index = #held, 1, -1 do
            local record = held[index]
            if type(record) == 'table' and takenBack[record.name] then table.remove(held, index) end
        end
    end

    return removed
end

--- Says, to the player and to the console, that the door did not shut on
--- somebody's own belongings.
---
--- BOTH DOORS, WHICH IS THE WHOLE POINT. There are two ways to end up
--- fighting in your own gear -- `stow` failed, or the player had no citizen
--- id to stash against -- and they leave the player in an identical state.
--- Only one of them used to say anything, and it was the console it said it
--- to.
---
--- THE WORDING FOLLOWS THE GUARD. Telling a player nothing they drop can be
--- picked back up is true only while the swapItems hook is actually on; on a
--- server that turned `blockDropsInArena` off it is a frightening lie. DO NOT
--- collapse these two keys into one.
---
--- FORCED PAST THE PANEL, because sendEnterArena closes it in this same tick.
--- @param src integer
--- @param matchId string
--- @param why string -- for the console only
local function warnOwnKit(src, matchId, why)
    ArenaLog('door: %s (%s) enters match %s carrying their own kit -- %s.',
        ArenaPlayerName(src), tostring(src), tostring(matchId), why)

    -- AND THE EXIT IS TOLD NOT TO CLEAR THEM OUT.
    --
    -- A record left over from an EARLIER match can still be sitting under
    -- this server id -- a restore that could not finish keeps one on purpose.
    -- restore() opens with an indiscriminate ClearInventory, on the reasoning
    -- that everything a fighter carries out belongs to the arena. THAT
    -- REASONING IS FALSE FOR THIS PLAYER: the door did not shut, so what they
    -- are carrying is their own. Left alone, their next exit destroys the
    -- very belongings the message above just warned them about.
    --
    -- `cleared` is the flag that routes an exit to the by-name reclaim
    -- instead, and it is the honest answer here: nothing of theirs is in the
    -- arena's hands, so there is nothing for a wholesale clear to take back.
    local stale = stashed[src]
    if stale ~= nil then stale.cleared = true end
    ArenaToastKey(src, dropsAreBlocked() and 'notify.kit_not_stashed'
        or 'notify.kit_not_stashed_open', 'error')
end

function ArenaAmmo.Issue(src, matchId, loadout)
    local failed = {}
    if type(src) ~= 'number' or src <= 0 or not Arena.IsKey(matchId) then return failed end
    if type(loadout) ~= 'table' then return failed end

    local ox = inventory()

    local held = stashed[src]
    local alreadyStowedForThisMatch = held ~= nil and held.matchId == matchId

    if ox and doorConfig().stripOnEntry ~= false and not alreadyStowedForThisMatch then
        local player = ArenaGetPlayer(src)
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if not Arena.IsKey(citizenid) then
            warnOwnKit(src, matchId, 'there is no citizen id to stash against')
        else
            -- WHAT THE STASH IS ALREADY HOLDING FOR THIS CHARACTER.
            --
            -- CARRIED FORWARD RATHER THAN REPLACED, and the difference is
            -- somebody's belongings. A record is KEPT on purpose when an exit
            -- could not empty the stash -- that is what the sweep works from
            -- -- and this line used to write the new entry's count straight
            -- over it. Re-entering with empty pockets therefore set it to
            -- ZERO, which disarmed restore()'s "read empty is not empty"
            -- guard for exactly the player it was written for: the next exit
            -- read nothing, called it a clean return, and forgot a stash that
            -- still had everything they own in it.
            local carried = 0
            if held ~= nil and held.citizenid == citizenid then
                carried = math.max(0, Arena.ToInt(held.stowedCount) or 0)
            end

            local put, count = stow(src, citizenid)
            if put then
                stashed[src] = {
                    stash = stashFor(citizenid),
                    matchId = matchId,
                    citizenid = citizenid,
                    stowedCount = carried + count,
                }
                ArenaDebug('door: stashed %d item(s) of %s\'s for match %s',
                    count, tostring(src), tostring(matchId))
            else
                -- THE PLAYER IS TOLD, ON PURPOSE. `stow` puts back
                -- everything it had already moved, so nothing is lost at
                -- this moment -- but it also leaves them carrying their own
                -- belongings into a round, and dying in one drops the lot on
                -- the arena floor. Silently that reads as the door having
                -- worked. The console line inside `stow` says WHY it failed;
                -- only the operator needs that. DO NOT quieten this.
                warnOwnKit(src, matchId, 'the door could not put their gear away')
            end
        end
    end

    if ox then
        local missingWeapons = issueWeapons(ox, src, matchId, loadout)
        for _, key in ipairs(missingWeapons) do failed[#failed + 1] = key end
    end

    -- ---- THE SUPPLIES ----------------------------------------------------
    --
    -- OUTSIDE THE AMMO-ITEM GATE, and that is a real distinction rather than
    -- a tidy one. `ArenaAmmo.IsEnabled` answers "is this server handing out
    -- ammunition as ITEMS", which is a question about rounds. A server that
    -- keeps its ammunition in the weapon's metadata can still want a fighter
    -- to carry a spare plate, and the two settings are in different blocks
    -- of config for that reason.
    --
    -- FAILURES DO NOT JOIN `failed`. That list is weapon KEYS: it goes back
    -- to server/match.lua and, with `allowWeaponWithoutAmmoItem = false`,
    -- feeds removeWeaponsByKey -- so a bandage item this server does not
    -- have would confiscate the player's rifle. A supply that cannot be
    -- handed over costs that supply and nothing else, and says so once.
    issuedSupplies[matchId] = issuedSupplies[matchId] or {}
    local supplyRecord = issuedSupplies[matchId][src] or {}
    issuedSupplies[matchId][src] = supplyRecord

    for _, entry in ipairs(loadout.supplies or {}) do
        local item = entry.item
        local count = Arena.ToInt(entry.count) or 0
        if Arena.IsKey(item) and count > 0 then
            rememberHeld(ox, src, matchId, item)

            local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
            if ok and granted ~= false then
                supplyRecord[item] = (supplyRecord[item] or 0) + count
                ArenaDebug('supplies: gave %s x%d to %s.', item, count, tostring(src))
            else
                ArenaLog('supplies: %s x%d was refused for %s -- either their inventory has no room '
                    .. 'for it (%d is a lot to carry: check the item weight against your '
                    .. 'ox_inventory player limit) or the item does not exist on this server.',
                    item, count, tostring(src), count)
            end
        end
    end

    if not ArenaAmmo.IsEnabled() then return failed end
    if not ox then
        ArenaLog('ammo items are switched on but ox_inventory is not started -- nobody is being given any.')
        return failed
    end

    local pass = {}

    for _, entry in ipairs(loadout.weapons or {}) do
        local handed = issueSpareRounds(ox, src, matchId, entry, pass)
        if not handed then failed[#failed + 1] = entry.key or entry.weapon end
    end

    -- ALLOWWEAPONWITHOUTAMMOITEM, and until now it decided nothing at all.
    --
    -- The setting has always shipped documented -- "on means a player with a
    -- full inventory fights with an empty gun rather than being refused the
    -- round; off means the match refuses to start them" -- and nothing in
    -- this resource read it. Both values behaved identically: the weapon was
    -- issued, the missing rounds were logged, and the player walked into the
    -- arena holding a gun that looked loaded and was not.
    --
    -- WHAT `false` DOES HERE, and it is narrower than that wording: the
    -- WEAPON is taken back, not the player. Ejecting somebody mid-placement
    -- means unwinding a dispatch flag, a routing bucket and a stash that have
    -- already been set for them, and every one of those has leaked in this
    -- codebase before. Taking the gun honours what the setting is for -- do
    -- not let anyone fight with an empty weapon that looks loaded -- without
    -- inventing a new way to strand a player. config.lua says so in these
    -- words now, rather than describing something that never happened.
    if #failed > 0 and (Config.Loadouts.ammoItems or {}).allowWeaponWithoutAmmoItem == false then
        local dropped = removeWeaponsByKey(ox, src, matchId, failed, loadout)
        if #dropped > 0 then
            ArenaLog('ammo: took back %s from %s -- their rounds could not be issued and this server does not arm an empty gun.',
                table.concat(dropped, ', '), tostring(src))
        end
    end

    return failed
end

function ArenaAmmo.Reclaim(src, reasonKey)
    if type(src) ~= 'number' or src <= 0 then return 0 end

    local record = stashed[src]

    -- WHOSE RECORD IS THIS, ACTUALLY.
    --
    -- `stashed` is keyed by SERVER ID, and a record deliberately OUTLIVES the
    -- player who made it: a failed restore keeps it so the sweep can retry,
    -- and the note above ("A DISCONNECT") is written on exactly that. What
    -- that note did not consider is that the id does not go with them. The
    -- server hands the freed slot to the NEXT person who connects, and from
    -- that moment `stashed[src]` names one character while `src` names
    -- another.
    --
    -- WHAT THAT COSTS IF IT IS NOT CHECKED, and it is not a leak, it is a
    -- deletion. restore() below opens with ClearInventory on the reasoning
    -- that everything this player is carrying belongs to the arena -- true
    -- of somebody walking out of a round, and false of a stranger who has
    -- never been in one. Their entire inventory is destroyed, and then the
    -- previous holder's stash is emptied into the wreckage: taken OUT of the
    -- stash, so the person it belongs to loses it for good as well. Two
    -- players robbed by one disconnect, on any server whose ids recycle,
    -- which is every server.
    --
    -- The record already carries the citizen id. This is the line that reads
    -- it. A mismatch is not an error to shout about and abandon -- the items
    -- are real and still owed -- so the stash goes onto `owed`, which is
    -- keyed by citizen id, survives reconnects and restarts, and is what the
    -- sweep at the bottom of this file already works from.
    if record then
        local holder = ArenaGetPlayer(src)
        local citizenid = holder and holder.PlayerData and holder.PlayerData.citizenid or nil

        if Arena.IsKey(citizenid) and Arena.IsKey(record.citizenid)
            and citizenid ~= record.citizenid then
            ArenaLog('door: server id %s now belongs to %s, but the kit stashed under that id belongs to %s. ' ..
                'NOTHING was taken from the player holding the id -- %s\'s belongings stay in stash %s and are queued to be returned when they are next seen.',
                tostring(src), tostring(citizenid), tostring(record.citizenid),
                tostring(record.citizenid), tostring(record.stash))
            owed[record.citizenid] = record.stash
            stashed[src] = nil
            forgetWeapons(src)
            return 0
        end
    end

    if not record then
        local ox = inventory()
        if ox then reclaimWeapons(ox, src) end
        return 0
    end

    if record.cleared then
        local ox = inventory()
        if ox then reclaimWeapons(ox, src) end
    end

    local ok, wiped = restore(src, record)

    if ok then
        stashed[src] = nil
        owed[record.citizenid] = nil

        if wiped then
            forgetWeapons(src)
        else
            local ox = inventory()
            if ox then reclaimWeapons(ox, src) end
        end
    elseif Arena.IsKey(record.citizenid) then
        owed[record.citizenid] = record.stash

        ArenaNotifyKey(src, 'notify.kit_held', 'error')
    end

    ArenaDebug('door: %s left (%s), kit %s', tostring(src), tostring(reasonKey),
        ok and 'returned' or 'STILL STASHED')
    return ok and 1 or 0
end

function ArenaAmmo.ReclaimAll(matchId, reasonKey)
    if not Arena.IsKey(matchId) then return 0 end

    local sources, seen = {}, {}
    local function add(src)
        if seen[src] then return end
        seen[src] = true
        sources[#sources + 1] = src
    end

    for src, record in pairs(stashed) do
        if record.matchId == matchId then add(src) end
    end
    for src in pairs(issuedWeapons[matchId] or {}) do add(src) end
    for src in pairs(issuedAmmo[matchId] or {}) do add(src) end
    for src in pairs(issuedSupplies[matchId] or {}) do add(src) end

    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, reasonKey)
    end

    issued[matchId] = nil
    issuedWeapons[matchId] = nil
    issuedAmmo[matchId] = nil
    issuedSupplies[matchId] = nil
    return #sources
end

function ArenaAmmo.Clear(matchId)
    if not Arena.IsKey(matchId) then return false end

    heldBefore[matchId] = nil

    for src, record in pairs(stashed) do
        if record.matchId == matchId then
            ArenaLog('door: refusing to drop match %s -- %s\'s kit is still stashed at %s.',
                tostring(matchId), tostring(src), record.stash)
            return false
        end
    end

    issued[matchId] = nil
    issuedAmmo[matchId] = nil
    issuedWeapons[matchId] = nil
    issuedSupplies[matchId] = nil
    return true
end

function ArenaAmmo.OnLoan(matchId)
    if not Arena.IsKey(matchId) then return 0 end

    local total = 0
    for _, count in pairs(issued[matchId] or {}) do
        total = total + (Arena.ToInt(count) or 0)
    end
    return total
end

--- Whether this resource is currently holding this player's inventory.
--- @param src number
--- @return boolean
-- THE THREE READERS BELOW ALL GO THROUGH ownRecord, and that is not
-- tidiness. `stashed` is keyed by server id, a record is deliberately KEPT
-- when an exit could not finish, and FiveM hands a freed id to whoever
-- connects next -- so a raw read answers a stranger's question with a
-- departed player's belongings.
--
-- ArenaAmmo.HeldFor is the one that made it visible: server/main.lua calls it
-- for every fighter on every admin-tablet push, so the escrow screen printed
-- the departed character's item list -- their cash included, now that
-- `neverStash` ships empty -- against the name of whoever inherited their id.
-- Nothing was ever MOVED, because the hand-back path re-derives the citizen
-- id from the live player, but the screen an operator reads to decide who is
-- short was naming the wrong person.
--
-- The swapItems guard was already asking through ownRecord. This is the rest
-- of the file agreeing with it, rather than half of it rejecting a record the
-- other half prints.
function ArenaAmmo.IsHolding(src)
    return ownRecord(src) ~= nil
end

function ArenaAmmo.StashOf(src)
    local record = ownRecord(src)
    return record and record.stash or nil
end

function ArenaAmmo.HeldFor(src)
    local record = ownRecord(src)
    if type(record) ~= 'table' then return nil end

    local out = {
        stash = record.stash,
        -- WHAT THE ARENA BELIEVES IT PUT IN. Shown beside what is actually
        -- there, because those two disagreeing is the whole of the bug that
        -- lost people their belongings -- and an admin staring at an empty
        -- list needs to know whether that is normal.
        expected = Arena.ToInt(record.stowedCount) or 0,
        items = {},
    }

    local ox = inventory()
    if not ox then return out end

    local ok, items = pcall(function() return ox:GetInventoryItems(record.stash) end)
    if not ok or type(items) ~= 'table' then return out end

    for _, item in ipairs(itemsIn(items)) do
        out.items[#out.items + 1] = {
            name = item.name,
            count = math.max(0, Arena.ToInt(item.count) or 0),
        }
    end
    return out
end

local RETRY_SECONDS = 30

local function midMatch(src)
    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.IsPlayerInArena) == 'function' then
        return ArenaDispatch.IsPlayerInArena(src) == true
    end
    return true
end

local function worthTrying(src, citizenid)
    if owed[citizenid] then return true end

    if probed[citizenid] then return false end

    -- THE ONE LOOK, and it is refused while a stash record is open for them.
    --
    -- An open record with nothing owed means the door has shut behind them
    -- and the exit has not run yet -- so their kit is in the stash on
    -- purpose, and handing it back now is handing it to somebody the next
    -- exit is about to clear. midMatch above catches that in every ordinary
    -- case; this catches the gap between the dispatch flag being cleared and
    -- the exit reclaiming.
    --
    -- THROUGH ownRecord, so a record left behind by a PREVIOUS holder of this
    -- server id does not speak for the person on it now. Without that, the
    -- one character who most needed a look -- the new arrival inheriting a
    -- stranded id -- was the one character the sweep would never take.
    return ownRecord(src) == nil
end

function ArenaAmmo.ReturnLeftovers(src)
    if type(src) ~= 'number' or src <= 0 then return false, 0, false end
    if midMatch(src) then return false, 0, false end

    local player = ArenaGetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil
    if not Arena.IsKey(citizenid) then return false, 0, false end

    local ox = inventory()
    if not ox then return false, 0, false end

    local stash = stashFor(citizenid)

    if not oxDid('registering stash ' .. stash, function()
        return ox:RegisterStash(stash, 'Arena Belongings', STASH_SLOTS, STASH_WEIGHT, citizenid)
    end) then
        return false, 0, false
    end

    local stowedCount = 0
    for _, record in pairs(stashed) do
        if record.citizenid == citizenid then
            stowedCount = math.max(stowedCount, Arena.ToInt(record.stowedCount) or 0)
        end
    end

    local readable, failures, returned = handBack(ox, src, stash)
    if not readable then return false, 0, false end

    -- A STASH THAT READ EMPTY IS NOT A STASH THAT WAS EMPTY -- and this is
    -- the same guard restore() applies, standing here because THIS is the
    -- function that actually retries.
    --
    -- Without it the guard lasted about thirty seconds. restore() would
    -- correctly refuse to call an empty read a clean return, keep the record,
    -- write the debt and tell the player their kit was safe and still being
    -- chased -- and then the very next pass of the sweep came through here,
    -- got the same empty read, found no such check, and ran the SETTLED block
    -- below: `owed` cleared, every record for that character deleted, the
    -- weapons forgotten. The retry then had nothing left to work from, which
    -- is the exact failure the guard was written to end, rebuilt inside the
    -- fix and on the one path guaranteed to run.
    --
    -- Bigger now than when it was written, too: `neverStash` ships empty, so
    -- what is in that stash is the player's cash as well as their things.
    if returned == 0 and failures == 0 and stowedCount > 0 then
        -- SAID ONCE PER CHARACTER, not once per pass.
        --
        -- The sweep comes back every returnRetrySeconds and this branch keeps
        -- the debt on purpose, so the two together are a loop -- and a line
        -- repeating the same sentence every thirty seconds for the life of
        -- the server is the log an operator stops reading, which is the rule
        -- stated sixty lines below about the partial-return branch. It is
        -- worth saying loudly the first time and worth nothing after that.
        if not warnedEmptyRead[citizenid] then
            warnedEmptyRead[citizenid] = true
            ArenaLog('door: %s\'s stash (%s) READ EMPTY on a retry, and %d item(s) are recorded as ' ..
                'being in it. Nothing has been handed back and the debt is being kept -- the stash ' ..
                'is a real one and /arenaadmin can open it. Said once; the sweep goes on trying.',
                tostring(src), stash, stowedCount)
        end
        owed[citizenid] = stash
        return false, 0, false
    end

    if returned > 0 then
        ArenaLog('door: handed %d item(s) back to %s out of stash %s -- a return that had not gone through.',
            returned, tostring(src), stash)
    end

    if failures > 0 then
        owed[citizenid] = stash
        return false, returned, true
    end

    owed[citizenid] = nil
    warnedEmptyRead[citizenid] = nil
    for other, record in pairs(stashed) do
        if record.citizenid == citizenid then
            stashed[other] = nil
            forgetWeapons(other)
        end
    end

    if returned > 0 then
        ArenaNotifyKey(src, 'notify.kit_returned', 'success')
    end

    return true, returned, true
end

function ArenaAmmo.SweepReturns()
    if not inventory() then return 0 end

    local handed = 0
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        local player = src and ArenaGetPlayer(src) or nil
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if Arena.IsKey(citizenid) and worthTrying(src, citizenid) then
            local _, returned, answered = ArenaAmmo.ReturnLeftovers(src)

            if answered then probed[citizenid] = true end
            if returned > 0 then handed = handed + 1 end
        end
    end

    return handed
end

function ArenaAmmo.Owed()
    local total = 0
    for _ in pairs(owed) do total = total + 1 end
    return total
end

local STASH_SCAN_LIMIT = 60

local STASH_SCAN_TIMEOUT = 8000

local OWED_LIMIT = 200

local warnedNoStashTable = false

--- Every arena stash this server has ever made, whether or not this run
--- remembers it.
---
--- WHY THIS GOES TO THE DATABASE. `owed` and `stashed` are in MEMORY. They
--- are the right shape for a running server -- they survive a reconnect, the
--- sweep works from them, and the exit writes them -- and they are gone the
--- moment the resource restarts. The STASHES are not: they are real
--- ox_inventory stashes with a real row, and a player whose belongings were
--- outstanding when the server went down is a player nothing in this file can
--- name afterwards. That is the exact case where somebody stays short for
--- ever, and it was invisible.
---
--- BY NAME, because the name is the one thing this resource controls: every
--- stash it makes is `stashPrefix .. citizenid`, so a LIKE on the prefix
--- finds them all and nothing else.
---
--- DEGRADES RATHER THAN FAILS. No oxmysql, an unreachable database, an
--- ox_inventory whose table is shaped differently -- any of those and this
--- answers with what memory knows, which is what it could always answer with.
--- The database is an enrichment here, never a dependency: this must not be
--- the one screen that stops working on a drag-and-drop install.
--- @param cb fun(rows: table[]) -- { citizenid, stash, items, remembered }
--- @param scanned fun(total: integer, read: integer)? -- how many rows exist
---        and how many had their contents read
function ArenaAmmo.AllStashes(cb, scanned)
    local prefix = doorConfig().stashPrefix
    if not Arena.IsKey(prefix) then prefix = 'crimson_arena_' end

    local known = {}
    for citizenid, stash in pairs(owed) do
        known[stash] = { citizenid = citizenid, stash = stash, remembered = true }
    end
    for _, record in pairs(stashed) do
        if type(record) == 'table' and Arena.IsKey(record.stash) then
            known[record.stash] = known[record.stash]
                or { citizenid = record.citizenid, stash = record.stash, remembered = true }
        end
    end

    local answered = false
    local function finish(names, total)
        if answered then return end
        answered = true

        local ox = inventory()
        local rows = {}

        for _, row in ipairs(names) do
            local items = {}
            if ox then
                pcall(function()
                    return ox:RegisterStash(row.stash, 'Arena Belongings',
                        STASH_SLOTS, STASH_WEIGHT, row.citizenid)
                end)

                local ok, held = pcall(function() return ox:GetInventoryItems(row.stash) end)
                if ok and type(held) == 'table' then
                    for _, item in ipairs(itemsIn(held)) do
                        items[#items + 1] = {
                            name = item.name,
                            count = math.max(0, Arena.ToInt(item.count) or 0),
                        }
                    end
                end
            end

            if #items > 0 then
                rows[#rows + 1] = {
                    citizenid = row.citizenid,
                    stash = row.stash,
                    items = items,
                    remembered = row.remembered == true,
                }
            end
        end

        table.sort(rows, function(a, b) return a.citizenid < b.citizenid end)
        if scanned then scanned(total, #names) end
        cb(rows)
    end

    local function fromMemory()
        local names = {}
        for _, row in pairs(known) do names[#names + 1] = row end
        table.sort(names, function(a, b) return a.stash < b.stash end)
        return names
    end

    if GetResourceState('oxmysql') ~= 'started' then
        if not warnedNoStashTable then
            warnedNoStashTable = true
            ArenaLog('door: oxmysql is not started, so the admin tablet can only list the '
                .. 'stashes THIS RUN knows about. A stash left outstanding by an earlier run '
                .. 'is still a real stash and still holds its owner\'s things -- it simply '
                .. 'cannot be found by name from here.')
        end
        local names = fromMemory()
        return finish(names, #names)
    end

    local pattern = prefix:gsub('([%%_\\])', '\\%1') .. '%'

    local sent = pcall(function()
        exports.oxmysql:query(
            'SELECT name, owner FROM ox_inventory WHERE name LIKE ? ORDER BY lastupdated DESC',
            { pattern },
            function(result)
                if type(result) ~= 'table' then
                    local names = fromMemory()
                    return finish(names, #names)
                end

                local names = {}
                local seen = {}
                for _, row in pairs(known) do
                    if #names >= STASH_SCAN_LIMIT then break end
                    seen[row.stash] = true
                    names[#names + 1] = row
                end

                for _, row in ipairs(result) do
                    local stash = row.name
                    if Arena.IsKey(stash) and not seen[stash] and #names < STASH_SCAN_LIMIT then
                        local citizenid = Arena.IsKey(row.owner) and row.owner
                            or stash:sub(#prefix + 1)
                        names[#names + 1] = {
                            citizenid = citizenid,
                            stash = stash,
                            remembered = false,
                        }
                    end
                end

                finish(names, #result)
            end)
    end)

    if not sent then
        local names = fromMemory()
        return finish(names, #names)
    end

    -- A QUERY THAT NEVER ANSWERS IS THE WORST OF THE THREE OUTCOMES because it
    -- is the silent one. The other two say something: a stopped oxmysql logs a
    -- line, a refused query fails the pcall. This one leaves every caller
    -- holding a callback that never runs -- which is exactly what made
    -- /arenaadmin do nothing at all rather than report a problem, since the
    -- whole screen was opened from inside that callback.
    SetTimeout(STASH_SCAN_TIMEOUT, function()
        if answered then return end
        ArenaLog('door: the stash scan did not answer within %d seconds, so this look is '
            .. 'listing only what THIS RUN remembers. The stashes it cannot name are still '
            .. 'real and still hold what they hold -- it is the database that did not answer.',
            STASH_SCAN_TIMEOUT / 1000)
        local names = fromMemory()
        finish(names, #names)
    end)
end

function ArenaAmmo.QueueReturn(citizenid, stash)
    if not (Arena.IsKey(citizenid) and Arena.IsKey(stash)) then return false end

    if #citizenid > 32 or citizenid:find('[^%w_%-]') then
        ArenaLog('door: refused to queue a return for %q -- that is not the shape of a '
            .. 'citizen id.', tostring(citizenid))
        return false
    end

    local prefix = doorConfig().stashPrefix
    if not Arena.IsKey(prefix) then prefix = 'crimson_arena_' end

    if stash:sub(1, #prefix) ~= prefix then
        ArenaLog('door: refused to queue %s as %s\'s belongings -- that is not one of this ' ..
            'arena\'s stashes.', tostring(stash), tostring(citizenid))
        return false
    end

    if owed[citizenid] == nil and ArenaAmmo.Owed() >= OWED_LIMIT then
        ArenaLog('door: refused to queue a return for %s -- %d characters are already owed '
            .. 'belongings, which is far past anything a working server reaches. Hand some '
            .. 'of them back before adding more.', tostring(citizenid), OWED_LIMIT)
        return false
    end

    owed[citizenid] = stash
    ArenaLog('door: %s\'s stash (%s) is queued -- it will be handed over the next time they are seen.',
        tostring(citizenid), tostring(stash))
    return true
end

CreateThread(function()
    local seconds = Arena.ToInt(doorConfig().returnRetrySeconds)
    if seconds == nil then seconds = RETRY_SECONDS end

    if seconds <= 0 then return end

    while true do
        Wait(seconds * 1000)
        ArenaAmmo.SweepReturns()
    end
end)

CreateThread(function()
    if doorConfig().blockDropsInArena == false then
        dropsHookOn = false
        return
    end

    -- WAITED FOR, not assumed present. This ran once at load and returned if
    -- ox_inventory was not started YET -- which is not a rare state: resource
    -- start order is not guaranteed, and this resource is deliberately asked
    -- to start early (before the medical script, for the death race). So on
    -- any server where ox_inventory came up second, the hook was never
    -- installed, drops were allowed for the whole session, and nothing said
    -- so: the one branch that logs is the one where ox_inventory refuses the
    -- hook, and this never reached it.
    --
    -- Thirty seconds, then it gives up LOUDLY. A resource that is not going
    -- to start in half a minute is not going to start.
    local ox = inventory()
    for _ = 1, 30 do
        if ox then break end
        Wait(1000)
        ox = inventory()
    end

    if not ox then
        dropsHookOn = false
        ArenaLog('door: ox_inventory never started, so dropping in an arena cannot be blocked. Anything dropped stays on the floor.')
        return
    end

    local ok = oxDid('registering the swapItems hook', function()
        return ox:registerHook('swapItems', function(payload)
            local src = payload and payload.source
            if not src then return true end

            -- IN THE ARENA, not merely STASHED, and the two are not the same
            -- player set.
            --
            -- This asked `stashed[src]`, which is only ever populated when
            -- the door is shut. With
            -- Config.Loadouts.inventory.stripOnEntry off -- where a player
            -- keeps their own inventory and is handed the arena's kit on top
            -- of it -- nobody is stashed at all, so this returned true for
            -- every fighter and the guard was off for the whole match. On
            -- exactly the setting where the arena's weapons are loose in a
            -- player's own pockets and dropping one is easiest.
            --
            -- The flag is the real question: it records who has actually
            -- been teleported into a round, which is what "mid-match" means
            -- here. The stash is kept as the fallback for the same reason
            -- every other guard in this file keeps one: the function is
            -- asked for rather than assumed. Not a load-order worry -- the
            -- manifest puts server/dispatch.lua BEFORE this file, and the
            -- claim that it came after was simply wrong -- but the hook runs
            -- on its own thread against whatever is loaded at the time, and
            -- an export the arena does not own is never assumed present.
            --
            -- THROUGH ownRecord, because this table is keyed by server id and
            -- a record is kept on purpose when an exit could not finish. Read
            -- raw, a record left behind by a player who then disconnected
            -- made the NEXT holder of that server id "in the arena": refused
            -- every inventory move anywhere on the map, their own house stash
            -- and glovebox included, with nothing able to clear it -- the
            -- sweep that would have is gated on the same table.
            -- A STASH RECORD IS NOT PRESENCE, and reading it as presence
            -- was a lockout with no way out of it.
            --
            -- A record is KEPT on purpose when an exit could not empty the
            -- stash -- that is what the retry works from -- and the read-empty
            -- guard in ReturnLeftovers keeps the debt written, so such a
            -- record is never settled and never dropped. Read as "this player
            -- is in the arena", it refused that player every inventory move
            -- they made anywhere on the map: their own house stash, a
            -- glovebox, a shop, handing a friend an item. For the rest of the
            -- session, through a reconnect, while standing nowhere near an
            -- arena, with the arena's own "you fight with what you were
            -- issued" line explaining it.
            --
            -- THE MATCH IS THE QUESTION. A fighter's record names a match that
            -- still exists; a stranded one names a round that ended and was
            -- destroyed long ago. Asked through ArenaLobby because that is the
            -- registry -- and asked for rather than assumed, since it loads
            -- after this file, in which case the older and stricter answer is
            -- kept.
            local record = ownRecord(src)
            local inArena = false
            if record ~= nil then
                if type(ArenaLobby) == 'table' and type(ArenaLobby.Get) == 'function' then
                    inArena = Arena.IsKey(record.matchId)
                        and ArenaLobby.Get(record.matchId) ~= nil
                else
                    inArena = true
                end
            end
            if not inArena and type(ArenaDispatch) == 'table'
                and type(ArenaDispatch.IsPlayerInArena) == 'function'
            then
                inArena = ArenaDispatch.IsPlayerInArena(src) == true
            end
            if not inArena then return true end

            local function theirs(id)
                if id == nil then return true end
                return id == src or tostring(id) == tostring(src)
            end

            if not theirs(payload.toInventory) then
                ArenaNotifyKey(src, 'error.no_dropping_in_arena', 'error')
                return false
            end

            -- AND IN, WHICH IS THE SAME RULE POINTED THE OTHER WAY.
            --
            -- THIS IS THE ONE THAT WAS MISSING, and it is the whole of a
            -- report that read as "killing someone gives you a hundred rounds
            -- per weapon". It was never a reward: ox_inventory drops a dead
            -- player's inventory on the floor as its own container, and a
            -- fighter who walked over the body could take the WHOLE arena kit
            -- the victim had just been issued -- their weapons and every round
            -- that came with them. Per kill, for as long as bodies kept
            -- falling. The half of the hook that existed refused moves OUT and
            -- permitted every move IN, so looting was not merely unguarded, it
            -- was the one direction the guard explicitly let through.
            --
            -- The exit was already catching the consequences -- reclaimWeapons
            -- takes back looted rounds by name, which is why nothing walked
            -- out of the arena -- but "it is confiscated at the door" is not
            -- the same as "it never happened": the round is still fought by
            -- somebody carrying four dead men's ammunition, and the loadout a
            -- player paid for stops meaning anything. What a kill is worth is
            -- paid openly instead -- see Arena.KillAmmoFor.
            --
            -- NOT ONLY BODIES. The same move covers a stash, a vehicle boot
            -- and another player's inventory, all of which are ways to bring
            -- something into a round that the round did not issue -- and the
            -- boot is the exact trick the tier swap's anti-parking rule exists
            -- to refuse from the other side.
            --
            -- WHAT IT DOES NOT TOUCH: anything the ARENA hands over. Every
            -- issue, top-up, kill reward and stash return goes through
            -- ox_inventory's AddItem, which is a server-side write and raises
            -- no swapItems hook at all. Nor does moving things around inside
            -- their own pockets, which stays their business.
            if not theirs(payload.fromInventory) then
                ArenaNotifyKey(src, 'error.no_looting_in_arena', 'error')
                return false
            end

            return true
        end, { print = false })
    end)

    -- WHY THIS DOES NOT JUST ASK WHETHER THE CALL THREW.
    --
    -- A bare `pcall` answers "no error was raised", which is NOT the same
    -- question. ox_inventory refuses a hook by RETURNING false, without
    -- throwing, and reading the pcall alone recorded that refusal as a
    -- success -- so `dropsAreBlocked` said yes on a server with no guard at
    -- all, and every fighter was told their belongings were pinned to them
    -- when anyone could walk off with them. oxDid is the file's answer to
    -- exactly this and it treats nil as success and false as refusal, which
    -- is ox_inventory's own convention. DO NOT put a bare pcall back.
    dropsHookOn = ok == true
    if not ok then
        ArenaLog('door: ox_inventory would not take a swapItems hook, so dropping cannot be blocked. Anything dropped in an arena stays on the floor.')
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    local sources = {}
    for src in pairs(stashed) do sources[#sources + 1] = src end
    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, 'resource stopping')
    end
end)
