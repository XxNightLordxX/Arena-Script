-- Crimson Arena: kit in, kit out. Weapons, rounds, and the safe.

ArenaAmmo = {}

local stashed = {}

local owed = {}

local probed = {}

--- When each character's stash was last looked at, so the extra looks above
--- are spread over minutes rather than spent in one burst of sweeps.
local probedAt = {}

--- Stashes the door has stopped touching because it can no longer tell what
--- it has already handed over -- keyed by stash name.
---
--- WHY A STASH IS EVER ABANDONED, AND WHY THAT IS THE SAFE ANSWER.
---
--- Handing an item back is two calls: put it in the player's hands, then take
--- it out of the stash. Between those two the item exists in BOTH places. If
--- the second is refused, the copy in the stash stays -- and every later pass
--- over that stash finds it and hands it over again. Measured, with nothing
--- more exotic than a refused removal: one phone became two, then four, then
--- eight, then sixteen over five rounds, with the same again still sitting in
--- the stash.
---
--- So the first refusal stops the door touching that stash at all. Nothing of
--- theirs is destroyed -- it is a real ox_inventory stash, /arenaadmin names
--- it and an operator can open it -- and the alternative is minting copies of
--- somebody's property until the ledger is meaningless. DO NOT hand back out
--- of a stash whose removals are being refused.
local jammedStash = {}

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

--- Calls one ox_inventory export that PUTS SOMETHING INTO SOMEBODY'S HANDS
--- and answers whether it can be PROVED to have landed.
---
--- THE OPPOSITE READING OF `nil` TO oxDid, AND THAT OPPOSITE IS THE WHOLE
--- POINT. oxDid treats "no answer" as success, which is right for registering
--- a stash or clearing an inventory -- nothing is lost by believing it. It is
--- the wrong reading for a hand-over, because ox_inventory answers nil for an
--- inventory IT HAS NOT LOADED, and a fighter placed in a round a fraction of
--- a second before their inventory finishes loading is exactly that.
---
--- What reading nil as success cost, measured: the loadout never arrives, the
--- arena records issuing it anyway, and the exit takes the recorded amount
--- back out of the pockets it eventually can read -- which by then hold
--- nothing but the player's OWN stock. A player walked in with 500 rounds and
--- 30 bandages of their own and walked out with 280 and 25. The arena ate
--- their property to settle a debt that never existed.
---
--- handBack already reads an AddItem answer this way and says why at length.
--- This is the same rule, in one place, for the paths that hand kit OUT. DO
--- NOT read a nil from a hand-over as success.
--- @param fn fun():any
--- @return boolean did, string|nil why, any answer
local function oxGave(fn)
    local called, answer = pcall(fn)
    if not called then return false, 'threw', answer end
    if answer == nil then return false, 'no-answer', nil end
    if answer == false then return false, 'refused', nil end
    return true, nil, answer
end

--- What to put in a log line about why a hand-over did not happen.
local function gaveWhy(why, answer)
    if why == 'threw' then return 'it threw -- ' .. tostring(answer) end
    if why == 'no-answer' then
        return 'ox_inventory gave no answer at all, which is what it does for an inventory it has '
            .. 'not loaded yet'
    end
    return 'ox_inventory refused it'
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

    -- THE KEY IS THE AUTHORITY ON THE SLOT, AND THIS IS WHERE IT WAS BEING LOST.
    -- ox_inventory omits item.slot on some builds, so the slot resolved from the
    -- table key above was worked out and then thrown away here. copiesOf then read
    -- nil, removeSlot refused without ever calling RemoveItem, and every by-slot
    -- take-back silently did nothing: the exit reclaim, the owed-kit chase, the
    -- gun game ladder and allowWeaponWithoutAmmoItem all failed to take the
    -- arena's own weapons back. DO NOT drop the resolved slot again.
    local flat = {}
    for index, row in ipairs(out) do
        local item = row.item
        if tonumber(item.slot) ~= row.slot then
            local copy = {}
            for key, value in pairs(item) do copy[key] = value end
            copy.slot = row.slot
            item = copy
        end
        flat[index] = item
    end
    return flat
end

--- What one inventory is holding, keyed by SLOT: { [slot] = { name, count } }.
--- Nil when it could not be read at all, which is never the same answer as
--- "it is empty".
local function slotMap(ox, who)
    local read, items = pcall(function() return ox:GetInventoryItems(who) end)
    if not read or type(items) ~= 'table' then return nil end

    local map = {}
    for _, item in ipairs(itemsIn(items)) do
        local slot = Arena.ToInt(item.slot)
        if slot then
            map[slot] = { name = item.name, count = math.max(0, Arena.ToInt(item.count) or 0) }
        end
    end
    return map
end

--- Undoes a half-finished stow: takes back out of the stash whatever this
--- attempt put into it, and nothing else.
---
--- BY SLOT, AGAINST A SNAPSHOT, BECAUSE A METADATA FILTER IS NOT AN ADDRESS.
--- The rollback used to be `RemoveItem(stash, name, count, metadata)` inside a
--- bare pcall with the answer thrown away -- two mistakes compounding. The
--- filter misses whenever ox_inventory augments an item's metadata as it
--- stores it, which it does; the removal is then refused; and the discarded
--- result meant nobody noticed. The player kept the kit the rollback was
--- written to give them AND a copy of it stayed in the stash, to be handed
--- over at the next exit. Reproduced with no synthetic refusal at all: the
--- player ended the round with two phones.
---
--- Highest slot first, so a build that closes the gap behind a removal cannot
--- renumber a slot this loop has not reached yet.
--- @return boolean -- whether every extra copy was actually taken back out
local function unstow(ox, stash, before)
    if type(before) ~= 'table' then return false end

    local now = slotMap(ox, stash)
    if now == nil then return false end

    local slots = {}
    for slot in pairs(now) do slots[#slots + 1] = slot end
    table.sort(slots, function(a, b) return a > b end)

    local undone = true
    for _, slot in ipairs(slots) do
        local has = now[slot]
        local was = before[slot]
        local kept = (was ~= nil and was.name == has.name) and was.count or 0
        local extra = has.count - kept
        if extra > 0 then
            if not oxDid(('putting %s x%d back out of slot %d of %s'):format(
                    tostring(has.name), extra, slot, tostring(stash)),
                function() return ox:RemoveItem(stash, has.name, extra, nil, slot) end)
            then
                undone = false
            end
        end
    end
    return undone
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

    -- NOTHING MORE GOES INTO A STASH THE DOOR HAS STOPPED HANDING BACK OUT
    -- OF. The exit refuses to empty a jammed stash on purpose -- see
    -- jammedStash -- so putting this player's belongings in would lock them in
    -- beside whatever is already stuck there. They keep their own kit instead,
    -- which is the same outcome as any other stash the door cannot use, and
    -- the one path in this file that has never cost anybody anything.
    if jammedStash[stash] then
        ArenaLog('door: stash %s has a removal outstanding and is NOT being added to -- %s keeps '
            .. 'their own kit rather than have it locked in there too.', stash, tostring(src))
        return false, 0
    end

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

    -- READ BEFORE A SINGLE ITEM GOES IN, and it is what the rollback below
    -- subtracts from. A stash can already have things in it -- an earlier exit
    -- that could not finish leaves them there on purpose -- so "take out what
    -- is in the stash" and "take out what THIS attempt put in the stash" are
    -- different sentences, and only the second is a rollback. DO NOT roll back
    -- against anything but a snapshot taken here.
    local before = slotMap(ox, stash)
    if before == nil then
        ArenaLog('door: could not read the stash %s before filling it, so nothing was put in it and '
            .. '%s keeps their own kit. A stow that cannot be undone must not be started.',
            stash, tostring(src))
        return false, 0
    end

    local function rollback(why)
        ArenaLog('door: %s -- putting it all back and letting %s keep their kit.',
            why, tostring(src))
        if unstow(ox, stash, before) then return end

        -- THE ROLLBACK ITSELF WAS REFUSED, which is the one outcome that
        -- leaves a copy of somebody's property in two places at once. The
        -- stash is shut rather than handed back out later, because handing it
        -- back is what turns the copy into a duplicate. DO NOT let an exit
        -- empty a stash a rollback could not clean.
        jammedStash[stash] = true
        ArenaLog('door: some of %s\'s belongings could NOT be taken back out of stash %s after the '
            .. 'door failed. They are carrying their own kit AND a copy is stuck in that stash, so '
            .. 'the door will not hand that stash back on its own. Open it with /arenaadmin and '
            .. 'settle it by hand.', tostring(src), stash)
    end

    local stowed = 0

    for _, item in ipairs(itemsIn(items)) do
        if not skip[item.name] then
            -- PROOF THAT IT LANDED, NOT MERELY THE ABSENCE OF A DENIAL. The
            -- next thing that happens to this player is ClearInventory, so an
            -- item this believes is safely in the stash and is not gets
            -- DESTROYED. ox_inventory answers nil for an inventory it has not
            -- loaded, and a stash it has just been asked to register is
            -- exactly such an inventory. DO NOT relax this to oxDid.
            local moved, why, answer = oxGave(function()
                return ox:AddItem(stash, item.name, item.count, item.metadata)
            end)
            if not moved then
                rollback(('could not stash %s x%s for %s (%s)'):format(
                    tostring(item.name), tostring(item.count), tostring(src), gaveWhy(why, answer)))
                return false, 0
            end
            stowed = stowed + 1
        end
    end

    local cleared = oxDid('clearing ' .. tostring(src) .. "'s inventory", function()
        return ox:ClearInventory(src, keep)
    end)
    if not cleared then
        rollback(('stashed %s\'s kit but could not clear their inventory'):format(tostring(src)))
        return false, 0
    end

    -- PROOF THAT THE POCKETS ARE EMPTY, NOT MERELY THAT THE CLEAR WAS NOT
    -- REFUSED.
    --
    -- `oxDid` reads a nil as success, and ox_inventory answers nil for an
    -- inventory it has not loaded -- so the clear can do NOTHING AT ALL and
    -- still read as done. Measured against a clear that answers nil: "door:
    -- stashed 5 item(s)" printed, the player walked into the round still
    -- carrying every item they own, a COPY of the lot sat in the stash, and
    -- the exit handed that copy over -- they left with two of everything,
    -- with not one line anywhere saying so. It is also how a fighter ends up
    -- fighting on their own ammunition while the arena believes it stripped
    -- them.
    --
    -- The AddItem fifteen lines above is already written this way and says
    -- why at length. This is the same rule applied to the very next call.
    -- DO NOT go back to trusting the answer to a clear.
    --
    -- AN UNREADABLE INVENTORY TAKES THE SAME PATH, and it is not the
    -- dangerous reading it looks like: the pockets were read successfully a
    -- few lines ago, and the one state that stops them being readable now is
    -- the unloaded inventory that also makes the clear do nothing -- so
    -- their own items are still in their hands. The rollback takes back out
    -- of the STASH only what this attempt put in, and leaves those hands
    -- alone.
    local after = slotMap(ox, src)
    local left = nil
    if after ~= nil then
        for _, has in pairs(after) do
            if not skip[has.name] then
                left = has.name
                break
            end
        end
    end

    if after == nil or left ~= nil then
        rollback(('ox_inventory reported clearing %s\'s inventory and %s -- which is what it does '
            .. 'for an inventory it has not loaded: it answers nothing and nothing happens'):format(
            tostring(src),
            after == nil and 'their pockets can no longer be read at all'
                or ('they are STILL carrying ' .. tostring(left))))
        return false, 0
    end

    return true, stowed
end

local function handBack(ox, src, stash)
    if jammedStash[stash] then
        ArenaLog('door: stash %s is NOT being handed back. A removal from it was refused earlier, '
            .. 'so the door cannot tell what it has already given out and will not risk handing the '
            .. 'same things over twice. Everything left is still in it -- open it with /arenaadmin '
            .. 'and give it back by hand.', tostring(stash))
        return false, 0, 0
    end

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
        local landed, why, answer = oxGave(function()
            return ox:AddItem(src, item.name, item.count, item.metadata)
        end)

        if not landed then
            ArenaLog('door: returning %s x%s to %s did not happen -- %s. It stays in stash %s. '
                .. '(A refusal is most often a full inventory or a weight limit.)',
                tostring(item.name), tostring(item.count), tostring(src),
                gaveWhy(why, answer), stash)
            failures = failures + 1
            goto nextItem
        end

        -- ITS ANSWER IS READ, because the item is in BOTH places at this
        -- instant: AddItem copied it to the player and this is what takes it
        -- out of the stash. A refusal that goes unnoticed leaves a duplicate
        -- in a real ox_inventory stash the player can open again -- and
        -- `returned` was counted regardless, so the exit called it a clean
        -- hand-back. DO NOT drop this result.
        --
        -- AND WHEN THE FILTER MISSES, THE SLOT IS TRIED. A metadata filter is
        -- a FILTER AND NOT AN ADDRESS: ox_inventory augments an item's
        -- metadata as it stores it, so the table this read back out is not the
        -- table the filter was built from, nothing matches, the removal is
        -- refused, and the copy stays behind to be handed over again on the
        -- next pass. Reproduced with no synthetic refusal at all -- the player
        -- ended the round with two phones.
        --
        -- The filter is still tried first, because on a build that honours it
        -- that is one call rather than two, and it aims at the exact item this
        -- loop just read. The slot is the fallback, and it is the address:
        -- `itemsIn` resolves it from the table key, so it is present on every
        -- build. Quietly, because a miss here is not news -- it is what the
        -- fallback exists for. DO NOT drop either half.
        local out = oxDid(('clearing %s x%s from %s'):format(
                tostring(item.name), tostring(item.count), tostring(stash)),
            function() return ox:RemoveItem(stash, item.name, item.count, item.metadata) end)

        if not out and Arena.ToInt(item.slot) then
            out = oxDid(('clearing %s x%s from slot %d of %s'):format(
                    tostring(item.name), tostring(item.count),
                    Arena.ToInt(item.slot), tostring(stash)),
                function()
                    return ox:RemoveItem(stash, item.name, item.count, nil, Arena.ToInt(item.slot))
                end)
        end

        if not out then
            -- AND THE DOOR STOPS HERE, WHICH IS THE POINT OF THE WHOLE
            -- BRANCH. This counted the item as returned and carried on, so
            -- the copy still in the stash was found by the next sweep and
            -- handed over again, and again: one phone became two, four,
            -- eight, sixteen over five rounds.
            --
            -- Everything handed back before this line came out of the stash
            -- cleanly and is theirs. This one item is now in both places, and
            -- the arena cannot fix that without risking taking one of the
            -- two off them -- so it says so, stops, and never touches this
            -- stash again on its own. DO NOT count this as a return.
            jammedStash[stash] = true
            failures = failures + 1
            ArenaLog('door: %s was given back %s x%s but it could NOT be taken out of stash %s. '
                .. 'There is now a copy in both places. The door is handing NOTHING further out of '
                .. 'that stash -- open it with /arenaadmin, compare it against what they are '
                .. 'carrying, and settle it by hand.',
                tostring(src), tostring(item.name), tostring(item.count), tostring(stash))
            return true, failures, returned
        end

        returned = returned + 1

        ::nextItem::
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
            ArenaLog('door: %s LEFT THE ARENA STILL HOLDING THE KIT IT ISSUED -- their own is being returned on top of it, and the arena kit is being taken back one weapon at a time, by the serial each was issued with.',
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
    -- real one, and the admin screen still names it -- but nothing in this
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

--- What this fighter walked into the match already holding of one item, or
--- NIL when nobody ever managed to read it.
---
--- NIL IS AN ANSWER AND IT IS NOT ZERO. This returned 0 for both, and the
--- callers below subtract it from what a player is holding to decide how much
--- of that is the arena's -- so "we never looked" read as "they owned none of
--- this", and the arena took the whole issued amount out of their own stock.
--- DO NOT put an `or 0` back on this.
local function floorFor(matchId, src, item)
    local byMatch = heldBefore[matchId]
    local mine = byMatch and byMatch[src]
    if mine == nil then return nil end
    return Arena.ToInt(mine[item])
end

--- Which character the arena issued a match's consumables to:
--- { [matchId] = { [src] = citizenid } }.
---
--- WEAPONS CARRY THEIR OWNER AND ROUNDS CANNOT. An issued weapon is a row
--- with a serial and a citizen id on it; `issuedAmmo` is `[item] = count`,
--- a bare number with nowhere to write whose it was. So the one thing the
--- exit needed to know on a disconnect -- who to bill for what it could not
--- collect -- was the one thing the stock rows could not say, and the debt
--- was dropped rather than charged to whoever happened to hold the id.
---
--- STAMPED ONCE PER PLAYER PER MATCH, from rememberHeld, which already runs
--- before every consumable the arena hands over and already early-returns
--- once it has its answer. It costs one player lookup per fighter per round.
--- DO NOT read this as "who is on that id now" -- that is the question it
--- exists to stop being asked.
local issuedOwner = {}

local function rememberHeld(ox, src, matchId, item)
    if not (Arena.IsKey(matchId) and Arena.IsKey(item)) then return end

    local owners = issuedOwner[matchId] or {}
    issuedOwner[matchId] = owners
    if owners[src] == nil then
        local holder = ArenaGetPlayer(src)
        local citizenid = holder and holder.PlayerData and holder.PlayerData.citizenid or nil
        if Arena.IsKey(citizenid) then owners[src] = citizenid end
    end

    heldBefore[matchId] = heldBefore[matchId] or {}
    local mine = heldBefore[matchId][src] or {}
    heldBefore[matchId][src] = mine
    if mine[item] ~= nil then return end

    -- A READ THAT DID NOT HAPPEN IS NOT A FLOOR OF ZERO, and writing it down
    -- as one is how the arena ends up taking a player's own ammunition.
    --
    -- This was `mine[item] = ok and (Arena.ToInt(answer) or 0) or 0`, so both
    -- ways of failing to read -- a throw, and the nil ox_inventory answers for
    -- an inventory it has not loaded -- landed on ZERO. The entry is written
    -- ONCE and never revisited, so a player placed a moment before their
    -- inventory loaded had "they walked in with nothing" carved in for the
    -- whole match. Every later top-up then measured against that, and the exit
    -- took the full issued amount off them: measured at 30 bandages of their
    -- own, all 30 gone.
    --
    -- Left unset it is tried again on the next call, and until one of those
    -- succeeds the floor reads as UNKNOWN rather than as zero -- which is what
    -- takeBack and the ledger below are taught to refuse to act on. DO NOT
    -- collapse an unreadable count back to a number.
    local ok, answer = pcall(function() return ox:GetItemCount(src, item) end)
    local counted = ok and Arena.ToInt(answer) or nil
    if counted == nil then return end
    mine[item] = math.max(0, counted)
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

--- Every serial the player is holding for one weapon name, as a set.
---
--- Every copy of one weapon the player is holding, with its slot.
---
--- THE SLOT IS THE WHOLE REASON THIS EXISTS. `itemsIn` already reads it and
--- this threw it away, which left a removal with nothing to aim at but the
--- item name -- and a name cannot tell the arena's carbine from the player's.
--- ox_inventory will remove from ONE NAMED SLOT, and that is exact on every
--- build, whether or not it can match on a partial metadata table.
---
--- NIL AND EMPTY ARE DIFFERENT ANSWERS, and callers must not conflate them:
--- nil is "the inventory could not be read", an empty table is "they hold
--- none of these". Reading nil as empty would report every arena weapon as
--- already gone.
--- @return table[]|nil -- { { slot = integer, serial = string|nil } }
local function copiesOf(ox, src, name)
    local ok, items = pcall(function() return ox:GetInventoryItems(src) end)
    if not ok or type(items) ~= 'table' then return nil end

    local out = {}
    for _, item in ipairs(itemsIn(items)) do
        if item.name == name then
            local serial = type(item.metadata) == 'table' and item.metadata.serial or nil
            out[#out + 1] = {
                slot = Arena.ToInt(item.slot),
                serial = Arena.IsKey(serial) and serial or nil,
            }
        end
    end
    return out
end

--- The serials of those copies, as a set.
--- @return table<string, boolean>|nil
local function serialsFor(ox, src, name)
    local copies = copiesOf(ox, src, name)
    if copies == nil then return nil end

    local out = {}
    for _, copy in ipairs(copies) do
        if copy.serial ~= nil then out[copy.serial] = true end
    end
    return out
end

--- Hands one weapon over and writes down WHICH COPY it is.
---
--- A SERIAL, NOT A NAME, AND THAT DISTINCTION COSTS PEOPLE THEIR GUNS.
--- ox_inventory gives every weapon its own serial, so a player's own carbine
--- and the arena's are two different objects wearing the same item name. The
--- exit removed one BY NAME and took whichever slot it found first -- and on
--- any server where a fighter carries their own kit into the round (the door
--- switched off, or a stash that failed), that was a coin flip on somebody's
--- own weapon, with its components, tint and serial destroyed to leave an
--- arena clone behind. Ammunition and supplies have had a floor against
--- exactly this for a long time; weapons had nothing. DO NOT go back to
--- removing a weapon by name alone.
---
--- READ BACK RATHER THAN ASSUMED. The serial is taken from the inventory
--- AFTER the item lands, by diffing against what was there before, because
--- ox_inventory owns serial generation and CANNOT be assumed to use the one
--- it was handed. Asking what it actually did is the only answer that cannot
--- drift.
---
--- A NIL SERIAL IS NOT A FAILURE. If the inventory cannot be read the weapon
--- is still issued and still recorded -- reclaim falls back to the old
--- by-name removal for that one record. Degrading to what the resource did
--- before is correct; refusing to arm the player is NEVER the answer -- a
--- fighter sent into a round unarmed is a worse bug than an imprecise exit.
--- @return boolean, table|nil
local function giveWeapon(ox, src, name, metadata)
    local before = serialsFor(ox, src, name)

    local landed, why, accepted = oxGave(function() return ox:AddItem(src, name, 1, metadata) end)
    if not landed then
        ArenaDebug('weapons: %s did not reach %s -- %s.', name, tostring(src), gaveWhy(why, accepted))
        return false, nil
    end

    -- NIL AND EMPTY KEPT APART HERE TOO, which the `or {}` this replaced did
    -- not do: an unreadable inventory became an empty one, and the loop then
    -- reported "no new serial" for a read that never happened. Same answer by
    -- luck, wrong reasoning, and the next edit inherits it.
    local serial
    local after = before and serialsFor(ox, src, name) or nil
    if before and after then
        for candidate in pairs(after) do
            if not before[candidate] then
                serial = candidate
                break
            end
        end
    end

    -- AND WHO IT WENT TO. A server id says who is standing there now; this
    -- says who the arena actually armed. They stop being the same person the
    -- moment somebody switches character or drops and the id is recycled --
    -- and without it the exit cannot tell "take this back off them" from
    -- "this belongs to somebody who is not here".
    local holder = ArenaGetPlayer(src)

    return true, {
        name = name,
        metadata = metadata,
        serial = serial,
        citizenid = holder and holder.PlayerData and holder.PlayerData.citizenid or nil,
    }
end

--- Takes back one issued weapon -- that exact copy, and no other.
---
--- BY SLOT, WHICH IS THE ONLY THING THAT IS EXACT ON EVERY BUILD.
---
--- The serial names the copy; the SLOT is how ox_inventory is told to take
--- that one. A removal given only an item name takes whichever slot it finds
--- first, and a fighter carrying their own gun of that name -- the door
--- switched off, or a stash that failed -- had a coin flip run on their
--- property every time they left. Proving the arena's serial was somewhere in
--- their pockets was never enough: it says the weapon is THERE, not that the
--- removal will pick it.
---
--- The metadata filter is still tried first, because on a build that supports
--- it that is one call rather than two. What changed is the fallback: it used
--- to be a bare removal by name, and now it is a removal from the slot the
--- inventory says holds that serial. DO NOT put a by-name removal back.
---
--- WITH NO SERIAL, ONE COPY IS THE ONLY SAFE CASE. Melee weapons on some
--- builds carry no serial at all, and an unreadable inventory at issue time
--- leaves one off any weapon. Then the arena can only act when there is
--- nothing else it could possibly take: exactly one copy of that name on
--- them, which must be the one it issued. Two, and it stops -- losing a
--- weapon rather than taking somebody's.
---
--- THREE ANSWERS, AND MERGING TWO OF THEM IS WHAT MADE THE LADDER AND THE
--- RESPAWN DISAGREE. `taken` is "this call removed the arena's copy".
--- `absent` is "the inventory was READ and the arena's copy is not in it" --
--- destroyed on death, dropped, or parked somewhere the arena cannot reach,
--- and NOTHING here can tell those apart. Neither remaining answer fits it:
--- calling it taken hands a parked rung off the books, and calling it
--- refused sends a respawning fighter in unarmed. Only the caller knows
--- whether a death came first, so only the caller can decide. DO NOT
--- collapse this back to one boolean.
--- @return boolean taken, boolean absent
local function takeWeaponBack(ox, src, record)
    if type(record) ~= 'table' or not Arena.IsKey(record.name) then return false, false end

    local function removeSlot(slot, why)
        if not slot then return false end
        return oxDid(('taking back %s from slot %d (%s)'):format(record.name, slot, why),
            function() return ox:RemoveItem(src, record.name, 1, nil, slot) end)
    end

    -- ONLY THE SERIAL GOES IN THE FILTER, NEVER THE WHOLE METADATA. The
    -- metadata on this record is what the weapon was ISSUED with --
    -- `{ ammo = <a full magazine> }` -- and a player who fires one round no
    -- longer matches it, so the removal found nothing and the arena's gun
    -- stayed in their pockets. The serial does not move.
    --
    -- QUIETLY, because a refusal here is not news: the weapon being gone and
    -- the build not supporting the filter both land on it, and the answer is
    -- worked out below. Shouting here trained operators to ignore the log.
    --
    -- READ FIRST, BECAUSE THE REMOVAL DESTROYS THE EVIDENCE. Once the filter
    -- has run, "the serial is not in these pockets" means either that it
    -- worked or that the weapon was NEVER there, and the answer below is
    -- opposite in the two cases. This is the only moment the difference can
    -- still be seen. DO NOT move it under the removal.
    local before = Arena.IsKey(record.serial) and serialsFor(ox, src, record.name) or nil
    if Arena.IsKey(record.serial) then
        pcall(function()
            return ox:RemoveItem(src, record.name, 1, { serial = record.serial })
        end)
    end

    local copies = copiesOf(ox, src, record.name)
    if copies == nil then return false, false end

    if Arena.IsKey(record.serial) then
        -- THE INVENTORY SAYS WHETHER IT WORKED, NOT THE RETURN VALUE.
        --
        -- This took `nil` for success -- the house reading of an ox answer
        -- everywhere else in this file, and the wrong one HERE, because the
        -- cost of being wrong is opposite. A player at the character-select
        -- screen has no loaded inventory, so the removal answers nil, the
        -- arena called it taken, no debt was written, and the whole loadout
        -- walked. It also made the by-slot fallback below unreachable on any
        -- build that answers nil rather than false.
        --
        -- Asking what they are holding settles it either way, and it is a
        -- read this function already had to do. DO NOT go back to trusting
        -- the return value.
        for _, copy in ipairs(copies) do
            if copy.serial == record.serial then
                return removeSlot(copy.slot, 'by serial ' .. record.serial), false
            end
        end

        -- IT IS ONLY TAKEN IF THIS CALL IS WHAT TOOK IT. The serial was in
        -- these pockets before the filter ran and is not in them now, so the
        -- filter is the only thing that can have moved it. `before` is the
        -- only witness to that: DO NOT drop the read that makes it, or this
        -- line goes back to calling a weapon that was never here a success.
        if before and before[record.serial] then return true, false end

        -- AND OTHERWISE IT WAS NEVER IN THESE POCKETS AT ALL. Reporting that
        -- as a successful removal is what let a climber park each rung in a
        -- trunk and keep it, with the row struck off the arena's books on the
        -- way past. It is not a refusal either -- ox_inventory empties a dead
        -- fighter's pockets onto the floor on EVERY death here, so a
        -- respawning fighter reaches this line in the ordinary course of
        -- play, and refusing would leave them unarmed for the rest of the
        -- round. The caller settles it.
        return false, true
    end

    -- AND ONLY IF THAT COPY HAS NO SERIAL EITHER.
    --
    -- The arena's row has no serial, so it can be matched to nothing. This
    -- took the single copy anyway, on the reasoning that one copy cannot be
    -- the wrong one -- and it can. The arena's copy is destroyed on death,
    -- dropped, or already taken on plenty of ordinary paths, and what is left
    -- in those pockets is then the player's OWN gun of that name.
    --
    -- A weapon that carries a serial is somebody's identified property. It
    -- may be theirs, it may be one they took off somebody else, and either
    -- way that serial is what a police script, an evidence system or the
    -- owner reads to know whose it is. Confiscating it does not just cost
    -- them a gun, it erases the only thing that says where it came from --
    -- and the arena CANNOT have issued it, because a row with no serial has
    -- nothing to match against.
    --
    -- So the fallback now only fires on a copy that is as anonymous as the
    -- record is. That is the melee-on-some-builds case it was written for.
    -- Anything with a serial is left alone, and the arena writes its own
    -- weapon off instead -- the same rule the ledger already follows for a
    -- serial it cannot read. DO NOT take an identified weapon on a record
    -- that cannot identify anything.
    --
    -- AND NONE AT ALL IS THE SAME ABSENCE THE SERIAL BRANCH REPORTS. The
    -- inventory was read and holds no copy of that name, which is what a
    -- weapon dropped by a corpse looks like from here. This fell through to
    -- the refusal at the bottom, so a fighter whose record carried no serial
    -- -- melee on some builds, or anything issued while the inventory could
    -- not be read -- was NEVER re-armed after their first death.
    if #copies == 0 then return false, true end

    if #copies == 1 and not Arena.IsKey(copies[1].serial) then
        return removeSlot(copies[1].slot, 'the only copy they hold, and neither it nor the record has a serial'), false
    end

    if #copies == 1 then
        ArenaLog('weapons: %s is holding one %s and it carries serial %s, which the arena has no '
            .. 'record of issuing -- its own row for that weapon has no serial at all. That gun is '
            .. 'theirs or somebody else\'s, and taking it would destroy the serial that says which. '
            .. 'It is LEFT WITH THEM and the arena writes its own copy off.',
            tostring(src), record.name, tostring(copies[1].serial))
    end

    if #copies > 1 then
        ArenaLog('weapons: %s is holding %d copies of %s and the arena\'s was issued without a '
            .. 'serial, so its own copy CANNOT be told from theirs. It is left with them rather '
            .. 'than take the wrong one.', tostring(src), #copies, record.name)
    end

    return false, false
end

local function issueSpareRounds(ox, src, matchId, entry, pass)
    local item = entry.ammoTypeItem
    local _, spare = splitRounds(entry)
    local count = itemsFor(spare)
    if not (Arena.IsKey(item) and count > 0) then return true, 0 end

    -- BEFORE THE COUNT IS READ, NOT AFTER IT, and that order is the whole of
    -- a fighter's own ammunition.
    --
    -- This sat below the early return, so on the one path that needed it --
    -- a player already holding rounds of this kind -- the floor was never
    -- stamped at all. `rememberHeld` writes what they walked in with ONCE per
    -- player per match and every subtraction below and at the exit is
    -- measured against it, so it has to be taken before the first thing the
    -- arena hands over, not after. DO NOT move it back down.
    rememberHeld(ox, src, matchId, item)

    local counted, answer = pcall(function() return ox:GetItemCount(src, item) end)
    if counted then
        local held = math.max(0, Arena.ToInt(answer) or 0)

        -- WHAT OF THIS IS THE ARENA'S. Without this line `held` was
        -- EVERYTHING in their pockets, so a fighter carrying 270 rounds of
        -- their own was issued ZERO -- measured -- and then fought the round
        -- on their own stock. Nothing was recorded as issued, so the exit
        -- took nothing back and there was no line anywhere: the rounds they
        -- fired were simply gone. The supplies half of ArenaAmmo.Refresh has
        -- always subtracted the floor here; the rounds half never did, and
        -- the same loadout came out right for plates and wrong for rounds.
        --
        -- AN UNKNOWN FLOOR COUNTS AS ZERO HERE, for the reason spelled out
        -- against the same `or 0` in ArenaAmmo.Refresh: this line decides how
        -- much to ADD and can only ever hand out one magazine too few. The
        -- lines that TAKE refuse to act on an unknown floor instead -- see
        -- takeBack. DO NOT copy this `or 0` to a line that removes anything.
        held = math.max(0, held - (floorFor(matchId, src, item) or 0))

        -- AND WHAT THIS PASS HAS ALREADY HANDED OVER COMES OFF AGAIN, which
        -- is NOT double-counting the line above: it is what gives two
        -- weapons sharing one ammo type their own allowance each. `held` is
        -- read live, so the rounds issued for the first weapon are already
        -- in it, and without this the second weapon would read them as "they
        -- have plenty" and issue nothing. Measured before this change and
        -- unchanged by it: two 270-round weapons on one ammo type arrive as
        -- 540. DO NOT drop this as a double subtraction of the same rounds --
        -- the line above takes off what is THEIRS, this one takes off what
        -- this pass has just handed over, and they are different rounds.
        held = math.max(0, held - (Arena.ToInt(pass and pass[item]) or 0))

        count = count - held
        if count <= 0 then return true, 0 end
    end

    local landed, why, granted = oxGave(function() return ox:AddItem(src, item, count) end)
    if not landed then
        ArenaLog('ammo: %s x%d did not reach %s -- %s. Nothing is recorded as issued, so the '
            .. 'exit will not take it back out of their own stock.',
            item, count, tostring(src), gaveWhy(why, granted))
        return false, 0
    end

    issuedAmmo[matchId] = issuedAmmo[matchId] or {}
    local byName = issuedAmmo[matchId][src] or {}
    issuedAmmo[matchId][src] = byName
    byName[item] = (byName[item] or 0) + count

    if pass then pass[item] = (pass[item] or 0) + count end

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

            local ok, issued = giveWeapon(ox, src, name, metadata)
            if ok then
                given[#given + 1] = issued
                ArenaLog('weapons: gave %s x1 to %s (ammo %d, serial %s).',
                    name, tostring(src), loaded, tostring(issued.serial or 'unread'))
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
--- @return integer taken, integer short, boolean measured
--- `short` is the arena's own, still with them; `measured` says whether the
--- count could be read at all.
--- @param strict boolean? -- refuse to act at all on an unreadable inventory
local function takeBack(ox, src, item, count, floor, strict)
    local ok, answer = pcall(function() return ox:GetItemCount(src, item) end)

    -- WHETHER A NUMBER CAME BACK, not merely whether the call survived.
    -- ox_inventory answers nil for an inventory it has not loaded, and this
    -- read that as a count of zero and reported it as MEASURED -- so a debt
    -- was settled at "they hold none" against pockets nobody had looked in.
    local counted = ok and Arena.ToInt(answer) or nil
    local readable = counted ~= nil

    -- THE FALLBACK IS ONLY SAFE AT THE EXIT IT WAS WRITTEN FOR. Assuming the
    -- player still holds everything the arena just issued costs nothing when
    -- the arena issued it seconds ago and the alternative is letting a whole
    -- loadout walk. Applied to a debt collected a week later it is the
    -- opposite: the only rounds in those pockets are the player's own, and
    -- removing the full amount by name takes them. Callers chasing an old
    -- slate pass `strict` and get nothing rather than a guess.
    if not readable and strict then
        ArenaLog('weapons: could not read how much %s %s has, so nothing was taken. The debt stands.',
            item, tostring(src))
        return 0, math.max(0, Arena.ToInt(count) or 0), false
    end

    local base = Arena.ToInt(floor)

    -- A COUNT WITH NO FLOOR TO SUBTRACT FROM IT IS NOT AN ANSWER, AND ACTING
    -- ON IT TAKES THE PLAYER'S OWN STOCK.
    --
    -- `floor` is what this fighter walked in holding, and everything below
    -- subtracts it to work out how much of what is in those pockets is the
    -- arena's. Nil means nobody ever managed to read it -- which is what an
    -- inventory ox_inventory had not loaded at issue time leaves behind -- and
    -- treating that as zero claims the LOT. Measured: a player lost all 30 of
    -- their own bandages that way.
    --
    -- Only when the live count IS readable, though. With no count at all this
    -- is already the documented guess above -- "assume they still hold exactly
    -- what was issued" -- and a floor changes nothing about a guess; refusing
    -- there would stop a build with no item counter taking its own kit back at
    -- all. The third return still says nothing was measured, so no caller
    -- writes a debt out of either case. DO NOT extend this to the unreadable
    -- one, and DO NOT default the floor to zero.
    if readable and base == nil then
        ArenaLog('weapons: nobody could read what %s walked in holding of %s, so NOTHING is being '
            .. 'taken back and nothing is written down. The arena would rather lose what it issued '
            .. 'than take theirs.', tostring(src), tostring(item))
        return 0, math.max(0, Arena.ToInt(count) or 0), false
    end

    local held = readable and counted or count

    local mine = math.max(0, held - math.max(0, base or 0))

    local take = math.min(math.max(0, Arena.ToInt(count) or 0), mine)
    if take <= 0 then return 0, 0, readable end

    -- THE ANSWER IS READ AND HANDED BACK, and the caller needs both halves.
    -- This was a bare pcall whose result went in the bin, so a refused
    -- removal was indistinguishable from a clean one: the arena's rounds
    -- stayed in a player's pockets, the record was dropped a line later, and
    -- nothing anywhere remembered they had been issued.
    --
    -- WHAT IS SHORT IS THE ARENA'S, NOT THEIRS. `mine` has already taken
    -- their own floor off, so anything this could not collect is a real debt
    -- and safe to write down. DO NOT throw the result away again.
    if oxDid(('taking back %d %s'):format(take, item),
        function() return ox:RemoveItem(src, item, take) end)
    then
        return take, 0, readable
    end

    -- THE THIRD RETURN IS "COULD I SEE WHAT THEY HAVE", and a caller writing
    -- a debt down must read it. With no count the fallback assumes they still
    -- hold everything the arena issued, which is the right guess for a
    -- removal and a terrible one for a LEDGER: it invents a debt out of an
    -- unreadable inventory and collects it later out of the player's own
    -- stock. DO NOT record a shortfall this did not measure.
    return 0, take, readable
end

--- @param keepAbsent boolean? -- whether a row naming a weapon that is NOT
--- in these pockets is left on the record. OFF by default, which is what the
--- arena has always done. A caller that is about to REFUSE over that row
--- turns it on, and DO NOT leave it off there: the row is the only thing the
--- next call has to refuse over, so the refusal would last exactly one call
--- and the attempt after it sails through on an empty candidate list.
--- @return table|nil row, boolean refused, boolean absent
local function takeRungBack(ox, src, record, name, keepAbsent)
    if not Arena.IsKey(name) then return nil, false, false end

    -- THE ROW IS KEPT ON PURPOSE, not just a yes/no, because the removal has
    -- to name WHICH copy it is taking. A rung weapon and the player's own can
    -- share an item name, and a by-name removal picks whichever slot comes
    -- first -- so demoting a climber could confiscate their own gun.
    --
    -- EVERY LISTED COPY IS TRIED, NOT JUST THE FIRST. Pinning to one row
    -- turned "does the player still hold any of the arena's copies" into
    -- "does the player still hold THIS one" -- so a rung weapon lost on death
    -- refused the take-back for ever, and a climber whose first row was dead
    -- could NEVER be promoted again: the swap refused, the row was never
    -- pruned, and it stayed first for the rest of the round.
    local candidates = {}
    for index = #record, 1, -1 do
        if record[index].name == name then candidates[#candidates + 1] = index end
    end
    if #candidates == 0 then return nil, false, false end

    -- EVERY CANDIDATE IS TRIED BEFORE ANY ANSWER IS GIVEN, and the order of
    -- the two failures is fixed: one copy the player IS holding that
    -- ox_inventory would not take outranks any number of rows naming weapons
    -- that are simply not there. Arming them again on top of a weapon they
    -- still have is the double-issue the refusal exists to stop, and it must
    -- not be reached by a stale row further down the same record.
    local missing = {}
    local balked = false

    for _, index in ipairs(candidates) do
        local row = record[index]
        local took, absent = takeWeaponBack(ox, src, row)
        if took then
            -- ONLY THE ROW ACTUALLY TAKEN. This deleted EVERY row of the
            -- name after removing a single weapon, so a second copy the arena
            -- had issued was forgotten while the player kept it. One removal
            -- must not forget two guns.
            table.remove(record, index)
            return row, false, false
        end
        if absent then
            missing[#missing + 1] = index
        else
            balked = true
        end
    end

    if #missing > 0 and not balked then
        -- COLLECTED DESCENDING, so removing them in order cannot shift an
        -- index that has not been used yet. DO NOT re-sort this.
        if not keepAbsent then
            for _, index in ipairs(missing) do table.remove(record, index) end
        end
        return nil, false, true
    end

    return nil, true, false
end

local function putRungsBack(ox, src, record, rows, context)
    for _, row in ipairs(rows) do
        -- RE-READ, NEVER REUSED. Handing the weapon back makes a NEW object
        -- with a NEW serial -- ox_inventory does not resurrect the one that
        -- was taken. Re-filing the old row would leave the record naming a
        -- serial that no longer exists anywhere, and the exit would then find
        -- nothing to take back: a free weapon for every rollback.
        local back, issued = giveWeapon(ox, src, row.name, row.metadata)
        if back then
            record[#record + 1] = issued
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

    -- WHAT WOULD NOT COME BACK STAYS ON THE BOOKS. This wiped the row
    -- whether or not the removal worked, so a refused take-back on a tier
    -- change left the rounds with the player and erased the only record that
    -- the arena had issued them -- invisible to the exit, invisible to the
    -- slate. It is the one place still doing the exact thing this file says
    -- twice over must NEVER be done again, and it runs on every promotion.
    for item, count in pairs(given) do
        if item ~= keep then
            local _, short = takeBack(ox, src, item, count, floorFor(matchId, src, item))

            given[item] = short > 0 and short or nil
            ArenaDebug('weapons: took %s back off %s -- it belongs to a tier they have left.%s',
                tostring(item), tostring(src),
                short > 0 and (' %d would not come back and is still recorded.'):format(short) or '')
        end
    end
end

--- @param allowAbsent boolean? -- treat a rung that is NOT in these pockets
--- as nothing left to take rather than as parked. OFF by default, because
--- the anti-parking rule is the only reason the rung below can refuse at
--- all. The one caller that KNOWS the pockets were emptied by something
--- other than the player's own choice -- a demotion, which follows their own
--- death -- opts in, and settleTier already had the answer in its reason key.
--- DO NOT switch it on for a promotion: a promotion follows somebody else's
--- death, and the climber's own pockets are theirs to have emptied.
function ArenaAmmo.SwapWeapon(src, matchId, removeWeapon, entry, alsoClear, allowAbsent)
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

        -- THE ROW IS KEPT WHILE THIS CALL MIGHT REFUSE OVER IT, and DO NOT
        -- drop it here. Dropping it makes the refusal last exactly one
        -- promotion: the next kill finds no candidate row at all, reads that
        -- as nothing to take back, and hands over the tier anyway.
        local row, refused, absent =
            takeRungBack(ox, src, record, removeWeapon, allowAbsent ~= true)
        if refused then return false, 'refused' end

        -- PARKED, UNLESS THE CALLER KNOWS BETTER, and this is the whole
        -- anti-parking rule. The rung is not in these pockets and the
        -- inventory read fine, so either the player put it somewhere
        -- ox_inventory cannot reach -- in which case advancing arms them with
        -- both tiers and strikes the lower one off the books, which is a free
        -- weapon per rung -- or a death emptied their pockets onto the floor,
        -- which happens on every death here. Nothing at this level separates
        -- the two, and only a demotion follows the player's own death -- so
        -- DO NOT try to answer it here instead of asking the caller.
        if absent and allowAbsent ~= true then
            ArenaDebug('weapons: %s is not carrying the tier weapon %s the arena issued them, so the '
                .. 'promotion is refused rather than hand over a second one.',
                tostring(src), tostring(removeWeapon))
            return false, 'refused'
        end

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

    local ok, issued = giveWeapon(ox, src, entry.weapon, metadata)
    if not ok then
        putRungsBack(ox, src, record, taken, entry.weapon)

        ArenaLog('weapons: ox_inventory would not give the tier weapon %s to %s -- they keep the tier they had.',
            tostring(entry.weapon), tostring(src))
        return false, 'refused'
    end

    record[#record + 1] = issued

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

            -- THE STALE ROW GOES WITH THE WEAPON IT NAMED, which is what
            -- the arena has always done here and what makes the re-issue
            -- below a replacement rather than a second copy. A respawn is the
            -- one moment the arena KNOWS the pockets were emptied by a death
            -- rather than by the player, so `refused` stays false for it and
            -- the skip below does not fire -- a fighter whose weapon died
            -- with them is armed again on the next life, and DO NOT put that
            -- skip back in the way of it. See reclaimWeapons for the half of
            -- this decision that is the owner's -- there, an absent weapon is
            -- billed; here it must NEVER be.
            local taken, refused = takeRungBack(ox, src, record, name, false)

            if refused then
                -- NOT RE-ISSUED WHILE THE OLD ONE IS STILL ON THEM, on
                -- purpose. This dropped the refusal on the floor and handed
                -- over a fresh copy anyway, so every respawn where
                -- ox_inventory would not take the old weapon back left the
                -- player holding one more arena weapon than the round before
                -- -- and one more record row, for ever.
                ArenaLog('weapons: %s still has the arena\'s %s and ox_inventory would not take it '
                    .. 'back, so they are NOT being handed another. They keep the one they have.',
                    tostring(src), tostring(name))
            elseif not armed then
                ArenaLog('weapons: %s was not re-issued to %s on respawn -- their rounds could not be '
                    .. 'issued and this server does not arm an empty gun.', tostring(name), tostring(src))
            else
                local ok, issued = giveWeapon(ox, src, name, metadata)
                if ok then
                    record[#record + 1] = issued
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

            -- AN UNKNOWN FLOOR COUNTS AS ZERO HERE AND ONLY HERE. This line
            -- decides how much to ADD, never how much to take, so the worst a
            -- wrong answer does is hand a player one plate too few or too
            -- many. Every place the floor decides a REMOVAL refuses to act on
            -- an unknown one instead -- see takeBack. DO NOT copy this `or 0`
            -- to a line that takes something away.
            local mine = math.max(0, held - (floorFor(matchId, src, item) or 0))

            local short = wanted - mine
            if short > 0 then
                local landed, why, granted = oxGave(function() return ox:AddItem(src, item, short) end)
                if landed then
                    supplyRecord[item] = (supplyRecord[item] or 0) + short
                    ArenaDebug('supplies: refreshed %s x%d for %s.', item, short, tostring(src))
                else
                    ArenaLog('supplies: %s x%d did not reach %s on a respawn -- %s. Nothing is '
                        .. 'recorded as issued, so the exit will not take it out of their own stock.',
                        item, short, tostring(src), gaveWhy(why, granted))
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

    -- ROUNDS IN, ITEMS OUT -- the conversion every other issue path makes and
    -- this one did not.
    --
    -- `Config.Modes.*.killAmmo` is documented in config as ROUNDS PER KILL,
    -- PER WEAPON, and it was handed straight to AddItem, which counts ITEMS.
    -- The two agree only while `roundsPerItem` is 1, which is the shipped
    -- value -- so it read correct. Set it to 30, which the config explicitly
    -- invites ("if one item on your server is a box of 30, put 30 here"), and
    -- a hundred-round reward paid a hundred BOXES: three thousand rounds a
    -- kill, per firearm. itemsFor is the same rounding issueSpareRounds
    -- uses, and this must NEVER go back to passing rounds straight through.
    local rounds = Arena.ToInt(count) or 0
    if rounds <= 0 then return false end

    local amount = itemsFor(rounds)
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

    local landed, why, granted = oxGave(function() return ox:AddItem(src, item, amount) end)
    if not landed then
        ArenaDebug('kill ammo: %s x%d did not reach %s -- %s.',
            item, amount, tostring(src), gaveWhy(why, granted))
        return false
    end

    issuedAmmo[matchId] = issuedAmmo[matchId] or {}
    local byName = issuedAmmo[matchId][src] or {}
    issuedAmmo[matchId][src] = byName
    byName[item] = (byName[item] or 0) + amount

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

    local landed, why, granted = oxGave(function() return ox:AddItem(src, item, amount) end)
    if not landed then
        ArenaDebug('kill reward: %s x%d did not reach %s -- %s.',
            item, amount, tostring(src), gaveWhy(why, granted))
        return false
    end

    issuedSupplies[matchId] = issuedSupplies[matchId] or {}
    local supplyRecord = issuedSupplies[matchId][src] or {}
    issuedSupplies[matchId][src] = supplyRecord
    supplyRecord[item] = (supplyRecord[item] or 0) + amount

    ArenaDebug('kill reward: gave %s x%d to %s.', item, amount, tostring(src))
    return true
end

--- Arena weapons that left with a character, keyed by the CITIZEN ID that
--- owes them: { [citizenid] = { { name = ..., serial = ... }, ... } }.
---
--- WHY A LEDGER AND NOT A REMOVAL. The exit can only take a kit off the
--- player who is standing there, and there are two ordinary ways for the kit
--- to leave without them: a character switch mid-round, and a disconnect that
--- ox_inventory saved before this resource ran. Both end in the same place --
--- Reclaim finds the server id now answers to somebody ELSE, so it cannot
--- touch the loadout, and up to now it simply forgot the kit had been issued.
--- Logging out mid-round was a free arena loadout, every round, for anybody
--- who noticed. DO NOT reduce this back to forgetting the kit.
---
--- KEYED BY CITIZEN ID FOR THE SAME REASON `owed` IS: a server id is whoever
--- holds it now, and this debt has to outlive a reconnect to be worth
--- writing down at all.
---
--- IT CAN ONLY EVER TAKE THE ARENA'S OWN COPY, because every row carries the
--- serial ox_inventory gave that weapon when the arena handed it over. A
--- player's own gun of the same name has a different serial and is NEVER
--- touched. That is the only thing making it safe to chase a stranger's
--- inventory at all, so a row with no serial must not be chased across
--- characters.
local owedKit = {}

local OWED_KIT_LIMIT = 200

--- Arena AMMUNITION AND SUPPLIES that left with a character:
--- { [citizenid] = { [itemName] = amount } }.
---
--- A SEPARATE LEDGER BECAUSE IT IS A DIFFERENT KIND OF DEBT. A weapon is an
--- object with a serial and the arena takes back THAT ONE. A round of 9mm is
--- fungible: there is no telling the arena's from the player's, and there is
--- no need to -- what is owed is a NUMBER, and any two hundred rounds settle
--- a debt of two hundred rounds.
---
--- WHAT MAKES IT SAFE TO COLLECT LATER is that the amount is worked out at
--- the moment the kit walks, while `heldBefore` still remembers what that
--- fighter came in carrying. takeBack subtracts that floor, so the figure
--- written down here is what the ARENA issued and did not get back, never a
--- share of somebody's own stock. Reading their pockets a week later could
--- not tell the difference; this does not have to.
---
--- IT USED TO BE NOTHING AT ALL. The rounds, plates and bandages simply went
--- with whoever walked off, unrecorded -- and with kill rewards paying per
--- kill, a farmed round plus a logout was an open tap. DO NOT let this fall
--- back to being forgotten.
local owedItems = {}

local OWED_ITEM_LIMIT = 40

local OWED_KIT_CHARACTERS = 200

-- ----------------------------------------------------------------------
-- THE SLATE, WRITTEN DOWN SOMEWHERE THAT SURVIVES A RESTART
--
-- WHY THIS TABLE EXISTS WHEN THE STASHES NEED NONE. A stash is a real
-- ox_inventory row: `AllStashes` finds one again after any restart by
-- scanning for the name prefix, which is why `owed` can live in memory
-- and lose nothing. A weapon debt has no such artefact -- the serial is
-- the only fact that identifies it and it exists nowhere but this Lua
-- table. So a restart wrote every outstanding debt off, and "wait for the
-- nightly restart" was a way to keep an arena loadout. This must not go
-- back to being memory-only.
--
-- OFF BY DEFAULT, LIKE EVERY OTHER DATABASE FEATURE HERE. With
-- Config.Database.enabled false the ledgers still work exactly as before
-- for the length of one uptime; nothing is required, and no SQL has to be
-- imported. Turning it on is what makes them
-- outlive the process -- DO NOT read the default as "this is optional
-- polish".
--
-- ONE ROW PER THING OWED. `ledger_key` is `w:` and the serial for a weapon,
-- `i:` and the item name for a stack, so a weapon can never be written down
-- twice and a stack accumulates instead.
--
-- THE PREFIX IS LOAD-BEARING, not decoration: without it a serial that
-- happened to read like an item name would collide on the primary key and
-- one debt would silently overwrite the other. DO NOT drop it.
--
-- The column exists because a UNIQUE index on "the serial, or the name when
-- there is no serial" needs a generated column or a functional index, and
-- composing the key in Lua is simpler than either and portable to every
-- MySQL a server might be running.
-- ----------------------------------------------------------------------
local KIT_SCHEMA_SQL = [[
    CREATE TABLE IF NOT EXISTS crimson_arena_owed_kit (
        citizenid VARCHAR(64) NOT NULL,
        ledger_key VARCHAR(191) NOT NULL,
        kind VARCHAR(16) NOT NULL,
        name VARCHAR(128) NOT NULL,
        serial VARCHAR(128) NULL,
        amount INT NOT NULL DEFAULT 1,
        written_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (citizenid, ledger_key)
    )
]]

-- NO PARAMETER IS EVER NIL, and the two statements are split for that one
-- reason. A weapon row carries a serial and an item row does not, so the
-- obvious single statement wanted a nil in the middle of the parameter list
-- -- and a Lua table with a hole in it is not one value short, it is
-- UNDEFINED. `#t` answers 6, `ipairs` stops at 4, and which of those
-- oxmysql happens to use decides whether the query runs, fails, or silently
-- writes the wrong columns. The item statement simply does not mention the
-- column; the database default fills it in.
--
-- `kind` is written by the statement rather than passed, for the same
-- reason it is worth being strict here: it is not data, it is which
-- statement you called. DO NOT merge these back into one.
local KIT_WEAPON_SQL = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, serial, amount)
    VALUES (?, ?, 'weapon', ?, ?, 1)
    ON DUPLICATE KEY UPDATE amount = 1
]]

local KIT_ITEM_ADD_SQL = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, amount)
    VALUES (?, ?, 'item', ?, ?)
    ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)
]]

local KIT_ITEM_SET_SQL = [[
    INSERT INTO crimson_arena_owed_kit
        (citizenid, ledger_key, kind, name, amount)
    VALUES (?, ?, 'item', ?, ?)
    ON DUPLICATE KEY UPDATE amount = VALUES(amount)
]]

local KIT_DROP_SQL =
    'DELETE FROM crimson_arena_owed_kit WHERE citizenid = ? AND ledger_key = ?'

-- NEWEST FIRST, AND BOUNDED. This read the whole table on every start, and
-- the table has no expiry: a character who never comes back is never
-- collected from, so it grows with player churn for the life of an install.
-- The in-memory caps refuse most of what an unbounded read would hand them
-- anyway, so the query stops asking for rows there is no room to keep -- and
-- the newest debt is the one most likely still collectable. This is also the
-- only thing `written_at` is for; DO NOT drop the column.
local KIT_READ_LIMIT = 5000

local KIT_READ_SQL =
    'SELECT citizenid, ledger_key, kind, name, serial, amount FROM crimson_arena_owed_kit '
    .. 'ORDER BY written_at DESC LIMIT ' .. KIT_READ_LIMIT

--- How long a debt stays chaseable before the arena gives up on it.
---
--- SOMETHING HAS TO EXPIRE A ROW, and until now nothing did. There are debts
--- nothing can EVER collect: a weapon destroyed on death is not in anybody's
--- pockets, and the chase keeps it on purpose rather than pretend it can prove
--- otherwise. Every one of those is permanent, so the table only grows, the
--- read-back skips what it has no room for, and the skipped rows are never
--- looked at again by anything. Two hundred stale characters is also what
--- pushes real, collectable debts off the slate at the cap.
---
--- A MONTH, because the debt this exists to collect is settled the next time
--- the player is seen and that is usually the same evening. A weapon parked in
--- a trunk to dodge the exit comes back out long before this. DO NOT shorten
--- it to something a holiday could outlast.
local OWED_KIT_MAX_DAYS = 30

--- THE ONLY THING THAT EVER TAKES A ROW OUT OF THE TABLE ON AGE, and it runs
--- ONCE per process, ahead of the read-back, so a debt older than the limit is
--- never read into memory in the first place.
---
--- WRITTEN AS THE CLOCK THE ROW WAS STAMPED BY -- the database's, through
--- `written_at` -- and NOT the server's. This is the one place the two can be
--- compared, and comparing them anywhere else would need the column read back
--- and parsed by a Lua that has no date type. The number is inlined for the
--- same reason KIT_READ_LIMIT is: it is a constant of this file, never input.
--- DO NOT turn it into a placeholder -- an INTERVAL will not take one on every
--- MySQL a server might be running.
local KIT_PURGE_SQL =
    'DELETE FROM crimson_arena_owed_kit WHERE written_at < (NOW() - INTERVAL '
    .. OWED_KIT_MAX_DAYS .. ' DAY)'

--- Set only from inside a callback that actually ran -- see LoadOwedKit.
---
--- MEASURED, NOT INFERRED, and the difference is a screen that lies. Whether
--- the slate survives a restart was read off the config and ox_inventory's
--- resource state, which says the operator MEANT to persist it, not that a
--- single row ever landed. A database user without CREATE, or without DELETE,
--- fails asynchronously: oxmysql reports it on its own console and the pcall
--- here never sees a thing. So the tablet told exactly the careful operator
--- who runs a least-privilege user that their debts were safe, while every
--- query was being refused. DO NOT go back to answering this from Config.
local kitSchemaConfirmed = false

--- Whether a WRITE to the slate has ever been refused.
---
--- A READ IS NOT EVIDENCE OF A WRITE, and the screen was reporting one as
--- the other. `kitSchemaConfirmed` is set by a successful SELECT, which is
--- exactly what a least-privilege database user has: import the table from
--- sql/install.sql, grant SELECT and nothing else, and every INSERT and
--- DELETE is refused asynchronously on oxmysql's own console while the
--- tablet tells the operator their slate is safely persisted.
---
--- That is the precise operator the DELETE warning in install.sql is aimed
--- at, and the one this screen was reassuring. Every write now carries a
--- callback: oxmysql answers nil when a statement did not land, and one such
--- answer is enough to stop claiming the slate is durable. DO NOT report a
--- read as proof of a write.
local kitWriteRefused = false

--- Whether a write to the slate has ever been PROVEN to land.
---
--- THE ABSENCE OF A REFUSAL IS NOT PROOF OF A WRITE, and reading it as one
--- costs a player their own stock exactly once per process. `kitWriteRefused`
--- can only be set by a write that has already been sent and refused -- so on
--- a database user with SELECT and no DELETE, the FIRST fungible collection of
--- every run goes ahead, takes the rounds, and only then learns that the
--- settlement could not be recorded. The row survives, the next start reads it
--- back, and the same debt is collected a second time. Measured: 10 taken on a
--- debt of 5, once per restart, out of stock the player bought themselves.
---
--- So the fungible half now waits for evidence rather than for a refusal. This
--- is set by any kit-slate statement whose callback comes back with an answer,
--- which on a working database is the first thing that happens at start.
--- CANNOT be answered from Config or from the read: a SELECT is exactly what
--- that user has. DO NOT set this anywhere but a write's own callback.
local kitWriteLanded = false

--- Ledger keys whose settlement has NOT been written down yet.
---
--- A SETTLEMENT IS A DELETE, AND ArenaDb THROWS AWAY A STATEMENT IT CANNOT
--- SEND. There is no queue behind it. So with oxmysql stopped the chase takes
--- the arena's rifle back off a player, clears the row in memory, and the
--- DELETE evaporates: the table still says the debt is open, the next start
--- reads it back, and the slate carries a debt for a weapon the arena is
--- already holding. That row CANNOT ever be collected -- the chase refuses on
--- purpose to delete a row it cannot see -- and it holds a slate slot until
--- the cap forgets it. Measured: one settled weapon, one phantom debt on the
--- next start, and it survives every further sweep.
---
--- A DELETE IS THE ONLY STATEMENT SAFE TO REPLAY, which is why this holds
--- KEYS and NEVER SQL. Sending the same DELETE twice costs nothing; an INSERT
--- that adds to a stack is a different debt every time it lands. DO NOT put an
--- adding write in here.
---
--- AND A KEY LEAVES THE SET THE MOMENT IT IS OWED AGAIN. A stack settled and
--- then re-incurred writes a NEW row under the same key, and replaying the old
--- DELETE would erase it -- so every save clears the key it writes.
local settledKeys = {}
local settledCount = 0

--- Bounded like everything else on this slate. Reached only when the database
--- has been refusing writes for a very long time, at which point the operator
--- has a much louder problem -- but a set with no bound is a leak whatever
--- feeds it. DO NOT take the cap off.
local SETTLED_LIMIT = 4000

--- Whether the read-back has been attempted and succeeded.
---
--- ONE ATTEMPT AT START WAS NOT ENOUGH. LoadOwedKit is called from
--- onResourceStart, and `ensure crimson_arena` above `ensure oxmysql` in a
--- server.cfg is an ordinary mistake -- at which point the read never
--- happened, every debt from previous runs sat in the table unread, and new
--- ones began writing fine the moment oxmysql came up. The operator saw a
--- working table full of rows nothing would ever collect, and no line saying
--- why. The sweep retries until it lands. DO NOT make this a one-shot again.
local kitLoaded = false

--- Whether a read is already out on the wire.
---
--- `kitLoaded` CANNOT DO THIS JOB. It is set inside the innermost callback,
--- which is the last thing to happen, so between dispatching the read and it
--- landing the guard is still open and every retry tick fires another one.
--- The sweep runs every `returnRetrySeconds`; a database slow enough to need
--- the retry is a database slow enough to still be answering the last one.
---
--- Two reads in flight is not merely wasteful. The snapshots are taken at
--- different instants, and nothing makes them land in that order -- so a
--- collection that happened in between is undone when the older one lands:
--- a settled stack reinstated at its old total and charged again, or a
--- returned weapon re-inserted as a debt the arena can never collect because
--- it already has the gun. DO NOT drop this flag and lean on kitLoaded.
local kitLoading = false

--- How long a slate read may be outstanding before the retry is allowed to
--- try again. Generous on purpose: it is a deadlock release, not a deadline.
local RETRY_TIMEOUT_MS = 30000

local function weaponKey(serial) return 'w:' .. tostring(serial) end

local function itemKey(name) return 'i:' .. tostring(name) end

--- Watches whether a write actually landed.
---
--- ONE REFUSAL IS ENOUGH and it is never un-said: a user who cannot write
--- now will not start being able to mid-session, and the operator needs to
--- see it whether or not the next statement happens to be a SELECT. Said
--- once, because these fire per weapon per exit. DO NOT make this a counter
--- that resets.
local function wrote(answer)
    -- AN ANSWER IS THE PROOF, and it is the only one there is. See
    -- kitWriteLanded: without it the fungible half treats "nothing has been
    -- refused yet" as "this user can write", which is true of every process
    -- until the moment it is expensively false. Only a WRITE's own callback
    -- may set it; DO NOT set it from a read, which is exactly what the user
    -- this guards against does have.
    if answer ~= nil then
        kitWriteLanded = true
        return
    end

    if kitWriteRefused then return end

    -- A NIL ANSWER IS ONLY A REFUSAL WHEN THERE WAS SOMETHING TO REFUSE IT.
    -- ArenaDb calls back with nil on every path that does not reach oxmysql,
    -- which includes the database being switched off and oxmysql being down
    -- -- neither of which says anything about whether this user may write.
    -- Latching on those would leave the screen reporting a slate as unsaved
    -- for the rest of the run after an outage that has since ended. DO NOT
    -- drop this test.
    if not ArenaDbReady('the outstanding-kit slate') then return end

    kitWriteRefused = true
    ArenaLog('weapons: the outstanding-kit slate could NOT be written to the database. The table '
        .. 'can be read but not changed, which is almost always a database user with SELECT and '
        .. 'no INSERT, UPDATE or DELETE. The slate still works for this run and a restart forgets '
        .. 'it; /arenaadmin now says so instead of reporting it as saved. The real error is on '
        .. 'oxmysql\'s console, not this one.')
end

--- Takes one key off the replay set, because a debt has just been written
--- under it again. DO NOT save a row without calling this first: a replayed
--- DELETE would take the new debt with the old one.
local function owedAgain(citizenid, key)
    local keys = settledKeys[citizenid]
    if keys == nil or keys[key] == nil then return end

    keys[key] = nil
    settledCount = settledCount - 1
    if next(keys) == nil then settledKeys[citizenid] = nil end
end

--- THE ONE PLACE A LEDGER ROW IS DELETED, and it remembers the key until the
--- database says the row is gone. Every DELETE on this slate comes through
--- here; see settledKeys for what a dropped one costs. DO NOT send
--- KIT_DROP_SQL from anywhere else.
local function dropLedgerRow(citizenid, key)
    local keys = settledKeys[citizenid]
    if keys == nil and settledCount < SETTLED_LIMIT then
        keys = {}
        settledKeys[citizenid] = keys
    end
    if keys ~= nil and keys[key] == nil and settledCount < SETTLED_LIMIT then
        keys[key] = true
        settledCount = settledCount + 1
    end

    ArenaDb('the outstanding-kit slate', KIT_DROP_SQL, { citizenid, key }, function(answer)
        wrote(answer)
        if answer ~= nil then owedAgain(citizenid, key) end
    end)
end

--- Re-sends the settlements the database never took.
---
--- ORDERED AHEAD OF THE READ-BACK BY EVERY CALLER, and that ordering is the
--- whole of its correctness: LoadOwedKit's SELECT is a photograph of the
--- table, so a settlement still waiting to be sent when the photograph is
--- taken comes straight back as an open debt. The merge refuses a pending key
--- as well, because a statement in flight is not a statement that has landed.
--- DO NOT call this after a read has been dispatched.
local function replaySettled()
    if settledCount == 0 or kitWriteRefused then return 0 end
    if not ArenaDbReady('the outstanding-kit slate') then return 0 end

    -- LISTED BEFORE ANY OF IT IS SENT. The callback can answer on this very
    -- line and takes its key out of the table being walked; building the list
    -- first is what keeps that from being a traversal of a table that is
    -- changing underneath it. DO NOT dispatch from inside the pairs loop.
    local flat = {}
    for citizenid, keys in pairs(settledKeys) do
        for key in pairs(keys) do flat[#flat + 1] = { citizenid, key } end
    end

    for _, entry in ipairs(flat) do dropLedgerRow(entry[1], entry[2]) end

    ArenaLog('weapons: %d settlement(s) the database never took have been sent again. They are '
        .. 'debts the arena has ALREADY collected, and the rows would otherwise be read back as '
        .. 'open on the next start.', #flat)
    return #flat
end

local function saveOwedWeapon(citizenid, row)
    owedAgain(citizenid, weaponKey(row.serial))
    ArenaDb('the outstanding-kit slate', KIT_WEAPON_SQL,
        { citizenid, weaponKey(row.serial), row.name, row.serial }, wrote)
end

local function saveOwedItem(citizenid, name, amount)
    owedAgain(citizenid, itemKey(name))
    ArenaDb('the outstanding-kit slate', KIT_ITEM_ADD_SQL,
        { citizenid, itemKey(name), name, amount }, wrote)
end

--- Writes a stack's CURRENT total, rather than adding to it -- used after a
--- partial collection, where the remainder is already known. DO NOT confuse
--- it with saveOwedItem, which ADDS: calling the wrong one silently doubles
--- a debt or erases one.
local function setOwedItem(citizenid, name, amount)
    if amount <= 0 then
        dropLedgerRow(citizenid, itemKey(name))
        return
    end
    owedAgain(citizenid, itemKey(name))
    ArenaDb('the outstanding-kit slate', KIT_ITEM_SET_SQL, { citizenid, itemKey(name), name, amount }, wrote)
end

local function dropOwedWeapon(citizenid, serial)
    dropLedgerRow(citizenid, weaponKey(serial))
end

--- Trims a character's weapon slate to the cap, oldest first.
---
--- THE DATABASE ROW GOES WITH IT. Three places trimmed the Lua table and
--- left the row behind, so the next restart read the evicted debt straight
--- back in -- a cap that capped nothing, and a slate that could only grow.
--- DO NOT trim `owedKit` anywhere without coming through here.
local function trimOwedKit(citizenid, rows)
    while #rows > OWED_KIT_LIMIT do
        local gone = table.remove(rows, 1)
        if type(gone) == 'table' and Arena.IsKey(gone.serial) then
            ArenaLog('weapons: %s\'s slate is full at %d, so the arena has given up on its %s (%s).',
                tostring(citizenid), OWED_KIT_LIMIT, tostring(gone.name), tostring(gone.serial))
            dropOwedWeapon(citizenid, gone.serial)
        end
    end
    return rows
end

--- How many characters owe the arena ANYTHING -- a weapon, an item, or both.
---
--- COUNTED ACROSS BOTH LEDGERS, and counted as CHARACTERS rather than rows.
--- One cap over the pair is the honest bound: two tables each allowed two
--- hundred names is four hundred, and a player who owes a rifle and some
--- rounds is still one debtor. It is also why this is declared here rather
--- than beside the first table that happened to need it -- both do, and a
--- forward reference to it from the other is a nil call. DO NOT move it
--- back down beside one of them.
local function owedKitCharacters()
    local seen, total = {}, 0
    for citizenid in pairs(owedKit) do
        seen[citizenid] = true
        total = total + 1
    end
    for citizenid in pairs(owedItems) do
        if not seen[citizenid] then total = total + 1 end
    end
    return total
end

--- The order characters were last written down in, newest highest.
---
--- A COUNTER RATHER THAN A CLOCK, because all this has to answer is "which of
--- these is the stalest", and a counter cannot be moved by an operator
--- correcting the machine's time.
local owedKitSeen = {}
local owedKitClock = 0

local function touchOwedKit(citizenid)
    owedKitClock = owedKitClock + 1
    owedKitSeen[citizenid] = owedKitClock
end

--- Takes one character off both slates and out of the table with them.
local function dropOwedCharacter(citizenid)
    for _, row in ipairs(owedKit[citizenid] or {}) do
        if type(row) == 'table' and Arena.IsKey(row.serial) then
            dropOwedWeapon(citizenid, row.serial)
        end
    end
    for name in pairs(owedItems[citizenid] or {}) do
        -- THE STORED ROW GOES WITH THE MEMORY ONE. Dropped from memory alone
        -- it is read straight back in on the next start, and the cap this
        -- serves would be back where it was within a restart.
        dropLedgerRow(citizenid, itemKey(name))
    end
    owedKit[citizenid] = nil
    owedItems[citizenid] = nil
    owedKitSeen[citizenid] = nil
end

--- Whether this character may be written down -- MAKING ROOM IF THERE IS NONE.
---
--- A FULL LEDGER USED TO BE A SHUT LEDGER, SERVER-WIDE AND FOR EVER.
---
--- Every writer asked `owedKitCharacters() >= OWED_KIT_CHARACTERS` and simply
--- refused. Nothing in this file expires a row, and there are debts nothing
--- can ever collect -- a weapon that was destroyed on death is not in anyone's
--- pockets, so the chase keeps it on purpose rather than pretend it can prove
--- otherwise. Two hundred characters carrying one of those and the ledger
--- latched shut: every NEW debt on the server, from every player, refused,
--- with one console line each. Proven at exactly two hundred.
---
--- So the cap now evicts instead of refusing, oldest character first -- the
--- same rule trimOwedKit already applies to one character's rows, for the same
--- reason: the newest debt is the one most likely still to be collectable, and
--- a ledger that cannot accept a new one is not a ledger. DO NOT go back to
--- refusing at the cap.
local function admitToLedger(citizenid)
    if owedKit[citizenid] ~= nil or owedItems[citizenid] ~= nil then return true end
    if owedKitCharacters() < OWED_KIT_CHARACTERS then return true end

    local oldest, seen = nil, nil
    local function consider(id)
        local at = owedKitSeen[id] or 0
        if seen == nil or at < seen then oldest, seen = id, at end
    end
    for id in pairs(owedKit) do consider(id) end
    for id in pairs(owedItems) do
        if owedKit[id] == nil then consider(id) end
    end

    if oldest == nil then return false end

    ArenaLog('weapons: the outstanding-kit ledger is full at %d characters, so the stalest one on '
        .. 'it (%s) has been written off to make room for %s. A ledger this full means something is '
        .. 'not collecting -- read the lines above.',
        OWED_KIT_CHARACTERS, tostring(oldest), tostring(citizenid))
    dropOwedCharacter(oldest)
    return true
end

--- Puts a number of one stackable item on a character's slate. It ADDS to
--- what is already there; DO NOT use it to write an absolute total.
local function oweItem(citizenid, name, amount)
    local count = math.max(0, Arena.ToInt(amount) or 0)
    if not (Arena.IsKey(citizenid) and Arena.IsKey(name)) or count <= 0 then return false end

    local rows = owedItems[citizenid]
    if rows == nil then
        -- THE UNION, because that is what the counter counts. Asking only
        -- whether the ITEM table knows them refused a new stack for somebody
        -- already on the slate for a weapon -- a character the cap had
        -- already admitted and who adds nothing to the count by owing one
        -- more kind of thing. DO NOT test one table against a count of both.
        if not admitToLedger(citizenid) then return false end
        rows = {}
        owedItems[citizenid] = rows
    end

    -- ONE ROW PER ITEM NAME, so this CANNOT grow with the number of rounds
    -- owed -- only with the number of distinct things. The cap is on names.
    if rows[name] == nil then
        local names = 0
        for _ in pairs(rows) do names = names + 1 end
        if names >= OWED_ITEM_LIMIT then return false end
    end

    rows[name] = (rows[name] or 0) + count
    touchOwedKit(citizenid)
    saveOwedItem(citizenid, name, count)
    return true
end

--- Writes this player's issued weapons down against the character that owes
--- them.
---
--- IT DOES NOT CLEAR `issuedWeapons`; the caller does that with
--- forgetWeapons, and it must not be done here -- this reads those rows and
--- would be dropping them from under itself.
--- @param counted table|nil -- item counts read BEFORE anything was handed
---        back to this player. See the call in ReturnLeftovers.
local function queueOwedKit(citizenid, src, counted)
    if not Arena.IsKey(citizenid) then return 0 end

    -- THE CAP IS DECIDED FIRST, BEFORE A SINGLE ROW IS WRITTEN ANYWHERE.
    --
    -- It used to be checked at the bottom, after every weapon had already
    -- been saved to the database -- so on the refusal path the database held
    -- rows that memory did not, the log told the operator they were "written
    -- off rather than tracked", and the next restart read them straight back
    -- in and proved that false. A decision to record nothing has to be taken
    -- before the recording starts.
    if not admitToLedger(citizenid) then
        ArenaLog('weapons: the outstanding-kit ledger is full at %d characters and no room could be '
            .. 'made, so nothing of %s\'s is being written down. Something is not collecting -- read '
            .. 'the lines above.', OWED_KIT_CHARACTERS, tostring(citizenid))
        return 0
    end

    local ox = inventory()

    -- READ AFTER THE ADMISSION, for the reason given in oweWeapon: making room
    -- evicts a character, and a list grabbed above that could be theirs.
    local rows = owedKit[citizenid] or {}
    local added, stacks, unchaseable = 0, 0, 0

    for _, byPlayer in pairs(issuedWeapons) do
        for _, item in ipairs(byPlayer[src] or {}) do
            -- WHOEVER THE ARENA ACTUALLY ARMED, not whoever this call was
            -- told to bill. Every row records the character it was issued to
            -- and reclaimWeapons already reads it; this did not, so a stale
            -- stash record under a recycled server id charged the DEPARTED
            -- character for the loadout of whoever inherited the id -- and
            -- forgot the real holder's, who then kept it. One line, two
            -- exploits: a free kit for the newcomer and a debt collected off
            -- somebody who was never in the round. DO NOT bill a row to
            -- anyone but the character named on it.
            -- ASKED BEFORE THE ROW IS TOUCHED. The test below already says
            -- this might not be a table, and reading `item.citizenid` above
            -- it made that promise unkeepable: a malformed row raised on the
            -- index and took the whole exit down before forgetWeapons, so a
            -- guard written to survive bad data was the thing that could not.
            -- DO NOT index a row above its own type check.
            local owner = type(item) == 'table' and Arena.IsKey(item.citizenid)
                and item.citizenid or citizenid

            if type(item) == 'table' and Arena.IsKey(item.name) and owner == citizenid then
                -- WITHOUT A SERIAL IT IS NOT A DEBT, IT IS A TRAP, and this
                -- is the line that keeps the promise the block above makes.
                --
                -- Collecting is only safe because a serial names the arena's
                -- exact copy. A row that never got one collects BY NAME --
                -- against a character who, by the time they are seen again,
                -- may own a perfectly ordinary weapon of that name. It would
                -- take theirs, and because it can never be written off
                -- either, it would sit in the ledger and try again on every
                -- sweep until it finally succeeded on something.
                --
                -- The arena would rather lose a weapon than take one it
                -- cannot prove is its own. DO NOT queue a row with no serial.
                if Arena.IsKey(item.serial) then
                    rows[#rows + 1] = { name = item.name, serial = item.serial }
                    saveOwedWeapon(citizenid, item)
                    added = added + 1
                else
                    unchaseable = unchaseable + 1
                end
            end
        end
    end

    -- AND THE CONSUMABLES, which walked off completely unrecorded and must
    -- NEVER do so again. The mismatch branch calls forgetWeapons a few lines
    -- after this, and that
    -- drops issuedAmmo and issuedSupplies outright -- so on the one path this
    -- ledger exists for, every round and every plate the arena handed out
    -- left free while the weapons were carefully written down.
    --
    -- CLAMPED HERE, WHERE THE FLOOR IS STILL KNOWN. `heldBefore` remembers
    -- what this fighter walked in carrying and goes when the match is
    -- cleared; reading their pockets when they next appear could never tell
    -- the arena's rounds from their own. Working the figure out now is the
    -- whole reason it is safe to collect later. DO NOT move this clamp to
    -- collection time.
    --
    -- THE SUM IS `min(issued, held now - their own floor)`, AND EVERY TERM
    -- MATTERS. It was `issued - floor`, which is a category error twice
    -- over: `issued` is the CUMULATIVE amount handed over this match and is
    -- never decremented as it is fired, and a player's own stock has nothing
    -- to do with how much the arena gave them.
    --
    -- Fire two hundred of the two hundred and fifty you were issued -- the
    -- ordinary thing to do in an arena -- and it wrote two hundred and fifty
    -- on the slate, so collecting it later came out of the player's OWN
    -- ammunition. It failed the other way too: walk in carrying five hundred
    -- with the door off, be issued two hundred and fifty, and `250 - 500`
    -- clamped to zero, so the whole consumable loadout was free.
    --
    -- AN UNREADABLE INVENTORY WRITES NOTHING. If the count cannot be read
    -- the arena does not know what is theirs, and a guess here is a guess
    -- with somebody else's property. It would rather lose the rounds -- the
    -- same rule the weapon side follows for a missing serial.
    --
    -- AND ONLY WHERE THE POCKETS BEING READ ARE THE POCKETS BEING BILLED.
    --
    -- The counts below come from `src`, and `src` is only this character
    -- while nobody else has taken the server id over. On the branch this
    -- function exists for they often HAVE -- so measuring the newcomer's
    -- stock and writing it down against the character who left is both a
    -- debt they never incurred and a free round of consumables for whoever
    -- inherited the id. The stamp says who the arena actually armed.
    local holder = ArenaGetPlayer(src)
    local liveId = holder and holder.PlayerData and holder.PlayerData.citizenid or nil

    local function oweStock(store)
        for matchId, byPlayer in pairs(store) do
            local given = byPlayer[src]
            local stamped = (issuedOwner[matchId] or {})[src]
            local billed = Arena.IsKey(stamped) and stamped or citizenid

            if given == nil then
                -- NOTHING WAS ISSUED HERE, so there is nothing to say about
                -- it. `store` is keyed by every live match on the server,
                -- not by the ones this player fought in, and the refusal
                -- below is a shouted console line. Testing ownership before
                -- testing whether this match ever armed them named every
                -- other match on the server, once per exit, per store. DO
                -- NOT put the ownership test first.
                goto nextMatch
            elseif billed ~= citizenid or (Arena.IsKey(liveId) and liveId ~= citizenid) then
                -- NOT THIS CHARACTER'S TO MEASURE. Either the rows belong to
                -- somebody else, or the pockets do. Either way the arena
                -- would rather lose the rounds than guess -- the same rule
                -- the weapon side follows for a missing serial. DO NOT bill
                -- a character whose pockets these are not.
                --
                -- SOMEBODY ELSE MUST ACTUALLY BE THERE. This read
                -- `citizenid ~= liveId`, which sounds like the same test and
                -- is not: it also refuses when NOBODY holds the server id.
                -- Both callers reach this function only after finding
                -- exactly that, and both pass the departed character as
                -- `citizenid` -- so the test was true by construction at
                -- every real call site and the loop below never ran once.
                -- Every round and every plate went free on the one path this
                -- ledger was written for.
                --
                -- An empty id is the /logout to character select, and
                -- ox_inventory still has that inventory loaded at the moment
                -- the door runs. The counts are the departing character's
                -- own, and billing them is right. If the inventory HAS gone
                -- the read comes back zero and the clamp below writes
                -- nothing, so the open case costs nothing either way. DO NOT
                -- fold the two conditions back together.
                ArenaLog('weapons: %s\'s consumables from match %s cannot be counted -- %s holds '
                    .. 'that server id now. The rounds are written off rather than charged to '
                    .. 'the wrong person.', tostring(citizenid), tostring(matchId), tostring(liveId))
                goto nextMatch
            end

            for item, issued in pairs(given) do
                -- MEASURED BEFORE THEIR OWN BELONGINGS CAME BACK, where a
                -- caller took the trouble to do that.
                --
                -- ReturnLeftovers empties the stash into the player and only
                -- then calls this. The floor for a stripped fighter is zero,
                -- because it was captured after the door cleared them -- so
                -- reading their pockets HERE counted the whole of their own
                -- returned stock as the arena's. Fire two hundred and forty
                -- of the two hundred and fifty you were issued, own a
                -- thousand of that calibre, and the slate said you owed the
                -- full two hundred and fifty; the chase then took it out of
                -- your own ammunition with the floor at zero.
                --
                -- An honest player charged for the rounds they shot, by the
                -- ledger written to stop people walking off with kit. DO NOT
                -- drop the snapshot and read live on that path.
                -- A MISSING ENTRY FALLS BACK TO THE LIVE READ rather than
                -- counting as zero. The snapshot is built from the catalogue
                -- of things this server is configured to issue, and an item
                -- that was issued and has since left that list would
                -- otherwise read as "they hold none" and quietly forgive the
                -- whole debt. Absent is NOT the same as none. DO NOT collapse
                -- these two branches into `counted[item] or 0`.
                local ok, answer
                if type(counted) == 'table' and counted[item] ~= nil then
                    ok, answer = true, counted[item]
                else
                    ok, answer = pcall(function() return ox:GetItemCount(src, item) end)
                end
                -- AND THE FLOOR HAS TO BE KNOWN TOO, not just the count. This
                -- asked only whether the pockets could be read; the floor was
                -- allowed to be an unread zero, which claims the player's
                -- whole stock of that item as the arena's and writes it on a
                -- slate that is collected later. Both halves of the sum have
                -- to have been measured or the sum means nothing. DO NOT test
                -- one and assume the other.
                local base = floorFor(matchId, src, item)

                if not ok or base == nil then
                    ArenaLog('weapons: could not read how much %s %s has, or what they walked in '
                        .. 'with, so the arena is not writing any down against %s. It would rather '
                        .. 'lose the rounds than take theirs later.',
                        item, tostring(src), tostring(citizenid))
                else
                    local held = math.max(0, Arena.ToInt(answer) or 0)
                    local mine = math.max(0, held - base)
                    local owing = math.min(math.max(0, Arena.ToInt(issued) or 0), mine)

                    if owing > 0 then
                        if oweItem(citizenid, item, owing) then
                            stacks = stacks + 1
                        else
                            -- SAID OUT LOUD, the way the other one is. The
                            -- identical refusal in reclaimStock logs; this
                            -- one dropped the rounds in silence, so the same
                            -- full ledger was loud on one path and invisible
                            -- on the other. DO NOT leave a refusal unlogged.
                            ArenaLog('weapons: %d %s could NOT be written down against %s -- the '
                                .. 'ledger is full. They are gone.', owing, item, tostring(citizenid))
                        end
                    end
                end
            end

            ::nextMatch::
        end
    end

    if ox then
        oweStock(issuedAmmo)
        oweStock(issuedSupplies)
    else
        ArenaLog('weapons: ox_inventory is not running, so none of %s\'s rounds or supplies can be '
            .. 'counted and none are written down.', tostring(citizenid))
    end

    if unchaseable > 0 then
        ArenaLog('weapons: %d weapon(s) of %s\'s were issued without a readable serial and CANNOT be '
            .. 'chased -- they are written off rather than risk taking a weapon of their own. '
            .. 'This means ox_inventory could not be read at the moment they were handed over.',
            unchaseable, tostring(citizenid))
    end

    if added == 0 then return 0 end

    -- BOUNDED IN BOTH DIRECTIONS, the way `owed` is: rows per character, and
    -- characters. A ledger nothing can empty is a memory leak with a moral,
    -- and this one has no expiry -- a character who never comes back is never
    -- collected from. The OLDEST rows go, because the newest debt is the one
    -- most likely still to be collectable.
    trimOwedKit(citizenid, rows)

    -- ONLY IF THERE IS A WEAPON IN IT. A character who owed nothing but
    -- rounds got an EMPTY list written here, and an empty list is worse than
    -- no list: chaseOwedKit gives up on `#rows == 0` before it ever reaches
    -- the stacks, so they were never collected from again -- and the empty
    -- key still counted towards the character cap, which nothing ever
    -- cleared. Two hundred of those and the whole ledger latched shut and
    -- refused every new debt on the server. DO NOT write an empty row.
    if #rows > 0 then
        owedKit[citizenid] = rows
        touchOwedKit(citizenid)
    end

    -- COUNTED SEPARATELY, because they are not the same thing. `added` is
    -- incremented by the weapon loop AND by the stock loop, and the line
    -- called the total "arena weapon(s)" -- so a fighter who walked off with
    -- nothing but a plate and some rounds was reported as leaving with two
    -- guns. An operator reading that goes looking for weapons that were
    -- never issued. DO NOT report one number as the other.
    if added > 0 or stacks > 0 then
        ArenaLog('weapons: %d arena weapon(s) and %d item stack(s) left with %s and are written '
            .. 'down against them. They will be taken back the next time that character is seen.',
            added, stacks, tostring(citizenid))
    end

    return added + stacks
end

--- Takes back whatever this character still owes, and forgets what they no
--- longer have.
--- Whether a FUNGIBLE debt can be collected right now, which is really the
--- question of whether settling it can be WRITTEN DOWN.
---
--- A CONSUMABLE DEBT IS A NUMBER WITH NOTHING ON IT. A weapon row carries a
--- serial, so a debt collected twice cannot take the wrong gun -- the second
--- attempt finds the arena's copy is not there and leaves the player alone.
--- Rounds and plates have no such lock: two armour is two armour, and the
--- only thing standing between a settled stack and it being collected AGAIN
--- is the DELETE that takes the row out of the table.
---
--- So when that DELETE cannot be sent, the collection does not happen either.
--- ArenaDb drops a write it cannot deliver -- there is no queue and no dirty
--- set -- so with oxmysql stopped the slate clears in memory while the row
--- survives, and the next start reads it back and takes the same two armour
--- and three bandages off the player a second time, out of stock they bought
--- themselves, with a toast telling them the arena has taken its kit back.
--- Reproduced end to end: eleven items in, one item left, on a debt of five.
---
--- The debt is NOT written off by waiting -- it stays on both the slate and
--- the table, which agree with each other throughout, and the first sweep or
--- door after the database answers collects it in full. DO NOT trade that
--- delay for a second collection: the arena would rather wait for its own
--- rounds than take a player's twice.
---
--- WITH NO DATABASE AT ALL there is no row to disagree with, the slate is
--- memory only, and clearing it is the whole of the settlement -- so the
--- collection goes ahead exactly as it always has. `kitWriteRefused` is the
--- third case: a user who can read the table and not write it, whose DELETE
--- is refused asynchronously on oxmysql's own console. Once one write has
--- come back refused, every further collection would be a repeat of the
--- first, so it stops there too.
local function stockIsCollectable()
    if Config.Database.enabled ~= true then return true end
    if kitWriteRefused then return false end

    -- AND ONE WRITE MUST ACTUALLY HAVE LANDED. `kitWriteRefused` is only ever
    -- set by a statement that has already been sent and refused, so on a
    -- SELECT-only database user it is still false for the FIRST collection of
    -- every run -- which goes ahead, takes the rounds, and learns a moment
    -- later that it could not be written down. Measured at 10 taken on a debt
    -- of 5, once per restart, out of stock the player bought. The refusal is
    -- one collection too late to be the whole gate. DO NOT drop this test.
    if not kitWriteLanded then return false end

    return ArenaDbReady('the outstanding-kit slate')
end

local function midMatch(src)
    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.IsPlayerInArena) == 'function' then
        return ArenaDispatch.IsPlayerInArena(src) == true
    end
    return true
end

local function chaseOwedKit(src, citizenid)
    if not Arena.IsKey(citizenid) then return 0 end

    -- BOTH SLATES, OR THE SECOND ONE IS NEVER COLLECTED.
    --
    -- This asked only about weapons and gave up on an empty list -- and the
    -- stack loop is further down the same function, so a character who owed
    -- nothing but rounds was never chased at all, at the door or on the
    -- sweep. The consumables ledger had a writer and no reader. DO NOT
    -- narrow this back to one table.
    local rows = owedKit[citizenid]
    if type(rows) ~= 'table' then rows = {} end

    local stock = owedItems[citizenid]
    if #rows == 0 and (type(stock) ~= 'table' or next(stock) == nil) then return 0 end

    local ox = inventory()
    if not ox then return 0 end

    -- TAKEN OFF THE BOOKS BEFORE THE LOOP, AND SURVIVORS PUT BACK AFTER.
    --
    -- The write-back used to REPLACE the whole slate with a list built only
    -- from the rows this pass happened to start with. Anything queueOwedKit
    -- appended while the loop was running -- it appends into the very same
    -- table -- was then thrown away by the assignment at the end. A debt
    -- silently vanishing is the exploit reopening, so the slate is claimed up
    -- front instead and merged back at the bottom. DO NOT go back to
    -- overwriting it.
    owedKit[citizenid] = nil

    -- ONE READ PER WEAPON NAME, not one per row. A stuck debt is chased
    -- again on every sweep and at every door, and a full ledger asking
    -- ox_inventory for the same inventory two hundred times over is the kind
    -- of cost that only ever lands on the servers already having a bad day.
    -- `false` is cached too: it records "could not be read", which must not
    -- be retried as though it were a different question.
    local reads = {}
    local function heldFor(name)
        if reads[name] == nil then reads[name] = serialsFor(ox, src, name) or false end
        if reads[name] == false then return nil end
        return reads[name]
    end

    local left, taken = {}, 0
    for _, row in ipairs(rows) do
        -- GONE IS AN ANSWER AND NOT A FAILURE, on purpose. A weapon can stop
        -- existing -- destroyed on death, dropped and despawned -- and a
        -- ledger that keeps chasing a serial nobody holds is one that never
        -- empties. Asking the inventory settles it.
        --
        -- A ROW WITH NO SERIAL IS DROPPED, NEVER CHASED. queueOwedKit refuses
        -- to write one down for the reason given there; this is the second
        -- lock on the same door, because the cost of being wrong is somebody
        -- else's weapon.
        -- A NAMELESS ROW IS DROPPED BEFORE IT IS TOUCHED. `heldFor` keys its
        -- cache on the name, and writing `reads[nil]` RAISES -- which would
        -- take the whole sweep down with it, for every player after this one,
        -- and leave the slate claimed but never merged back. One malformed
        -- row must NEVER cost a character their entire ledger.
        if type(row) ~= 'table' or not Arena.IsKey(row.name) then
            ArenaLog('weapons: a row owed by %s has no item name and cannot mean anything -- dropped.',
                tostring(citizenid))
            goto continue
        end

        if not Arena.IsKey(row.serial) then
            -- AND THE STORED ROW GOES WITH IT. Dropped from memory only, it
            -- is read back on every start for ever and can NEVER be acted on.
            dropLedgerRow(citizenid, weaponKey(row.serial))
            ArenaLog('weapons: a %s owed by %s has no serial and cannot be told from one of their own '
                .. '-- written off.', tostring(row.name), tostring(citizenid))
            goto continue
        end

        local held = heldFor(row.name)

        if held ~= nil and not held[row.serial] then
            -- NOT IN THEIR POCKETS IS NOT THE SAME AS GONE, and treating it
            -- as gone was a thirty-second window with a hole in it. This read
            -- only the player's OWN inventory and deleted the row on the
            -- first look that came back empty -- so putting the arena's rifle
            -- in a house stash, a glovebox or a friend's hands before the
            -- next sweep settled the debt for good, and it could be collected
            -- again afterwards. Outside an arena nothing refuses that move.
            --
            -- THE ROW STAYS. The arena cannot prove a weapon was destroyed
            -- and no longer pretends it can: the debt is simply not collected
            -- this time, and the cap is what eventually forgets it. DO NOT
            -- delete a row because it is not in front of you.
            left[#left + 1] = row
            ArenaDebug('weapons: %s is not carrying the arena\'s %s (%s) right now -- still owed.',
                tostring(citizenid), row.name, tostring(row.serial))
        elseif takeWeaponBack(ox, src, row) then
            dropOwedWeapon(citizenid, row.serial)
            taken = taken + 1
            ArenaLog('weapons: took the arena\'s %s (%s) back off %s.',
                row.name, tostring(row.serial or 'no serial'), tostring(citizenid))
        else
            left[#left + 1] = row
        end

        ::continue::
    end

    -- AND THE CONSUMABLES. Fungible, so this asks only for a NUMBER back and
    -- does not care which rounds it gets. What it must not do is take more
    -- than is owed, so a partial collection leaves the remainder on the
    -- slate rather than rounding it away.
    -- NOT WHILE THEY ARE IN A ROUND, and only this half.
    --
    -- A consumable debt is a NUMBER: the chase asks for that many back and
    -- does not care which ones it gets. Inside a match the rounds and plates
    -- in a fighter's pockets are the ones the arena just handed them -- so
    -- the sweep settled last week's debt out of this week's issue. Walk in
    -- owing two hundred and fifty, carry none of it, take the loadout, and
    -- thirty seconds later the debt is paid with the arena's own property at
    -- no cost to you at all. The exit then finds nothing left to reclaim and
    -- writes nothing down.
    --
    -- The weapon half above is safe and stays outside this: a row carries the
    -- serial it was issued with, so it can only ever match the arena's own
    -- copy from the round it came from, never the one in their hands now.
    --
    -- The debt is not written off, only left alone -- `owedItems` is not
    -- claimed below, so the slate is untouched and the next sweep after they
    -- leave collects it. DO NOT move this gate above the weapons.
    local settle = type(stock) == 'table' and not midMatch(src)

    if settle and not stockIsCollectable() then
        -- SAID EVERY TIME RATHER THAN ONCE, on purpose and for the same
        -- reason as the strict refusal in takeBack: each line is one
        -- collection that did not happen, to one named character.
        ArenaLog('weapons: %s owes the arena consumables and the outstanding-kit slate cannot be '
            .. 'written to right now, so NOTHING was taken. Settling a fungible debt the arena '
            .. 'cannot record as settled is how the same two armour and three bandages get taken '
            .. 'off somebody twice. The debt stands and is collected once the database answers.',
            tostring(citizenid))
        settle = false
    end

    if settle then
        -- CLAIMED AND MERGED, the same way the weapon slate above is. This
        -- assigned straight over the top, which is exactly what the comment
        -- there says must never come back -- anything written while the loop
        -- ran would be thrown away by the assignment. DO NOT let the two
        -- halves of this function disagree about that again.
        owedItems[citizenid] = nil

        local rest = nil
        for item, amount in pairs(stock) do
            local got = takeBack(ox, src, item, amount, 0, true)
            local still = math.max(0, amount - got)

            if got > 0 then
                taken = taken + 1
                ArenaLog('weapons: took back %d %s the arena issued %s.', got, item, tostring(citizenid))
            end

            if got > 0 then setOwedItem(citizenid, item, still) end

            if still > 0 then
                rest = rest or {}
                rest[item] = still
            end
        end
        for item, amount in pairs(owedItems[citizenid] or {}) do
            rest = rest or {}
            rest[item] = (rest[item] or 0) + amount
        end

        owedItems[citizenid] = rest
    end

    -- MERGED, NOT ASSIGNED, for the reason given above the loop.
    for _, row in ipairs(owedKit[citizenid] or {}) do left[#left + 1] = row end
    trimOwedKit(citizenid, left)
    owedKit[citizenid] = #left > 0 and left or nil

    -- AND THE STAMP GOES WHEN THE LAST DEBT DOES. It is only ever read to
    -- decide which character on the slate is the stalest, so a stamp for
    -- somebody who owes nothing is a row in a table that would otherwise grow
    -- with every debtor this server ever settles with.
    if owedKit[citizenid] == nil and owedItems[citizenid] == nil then
        owedKitSeen[citizenid] = nil
    end

    -- AND THE PLAYER IS TOLD, because this is the only place in the resource
    -- that removes something a player is holding while they are nowhere near
    -- the arena. It said nothing at all: a weapon and a pile of rounds left
    -- their inventory on a routine sweep tick, anywhere on the map, with the
    -- only explanation going to the server console. That is indistinguishable
    -- from ox_inventory eating their kit, and it is what they will report.
    --
    -- A TOAST, not a notification, and once for the whole collection rather
    -- than per row. They may have the arena panel open at the door -- the
    -- likeliest moment for this to fire -- and a closing panel swallows an
    -- ordinary notify. DO NOT quieten this.
    if taken > 0 then
        ArenaToastKey(src, 'notify.kit_reclaimed', 'info')
    end

    return taken
end

--- Puts one issued weapon on a character's slate.
local function oweWeapon(citizenid, row)
    if not (Arena.IsKey(citizenid) and Arena.IsKey(row.name) and Arena.IsKey(row.serial)) then
        return false
    end

    -- BOTH TABLES, for the reason spelled out in oweItem: the counter
    -- answers about the union, so a character already owing rounds must not
    -- be refused a weapon row they do not widen the ledger by adding.
    if not admitToLedger(citizenid) then return false end

    -- READ AFTER THE ADMISSION AND NOT BEFORE IT. Making room can evict a
    -- character, and a list grabbed above that could be the evicted one's --
    -- which would be re-filed here under the new name, putting the debt that
    -- was just written off back on the slate against somebody who never
    -- incurred it. DO NOT hoist this above admitToLedger.
    local rows = owedKit[citizenid] or {}

    rows[#rows + 1] = { name = row.name, serial = row.serial }
    trimOwedKit(citizenid, rows)
    owedKit[citizenid] = rows
    touchOwedKit(citizenid)
    saveOwedWeapon(citizenid, row)
    return true
end

--- @param fallbackOwner string? -- whose kit this is when nobody is on the
--- id. Without it a disconnect has nobody to bill and the debt is dropped, so
--- callers that know whose round it was must NOT omit it.
local function reclaimWeapons(ox, src, fallbackOwner)
    -- WHO IS ACTUALLY STANDING HERE, asked once and compared against every
    -- row below.
    --
    -- WHY THE ROW DECIDES AND NOT THE BRANCH ABOVE IT. Reclaim only reaches
    -- its citizen-id check when a STASH record exists, and there are two
    -- shipped ways to have no record at all: the door switched off, and a
    -- stash that failed. Those are precisely the configurations where a
    -- fighter's own weapons are loose in their pockets beside the arena's --
    -- so the one path that most needs to know whose gun it is had no idea,
    -- and a character switch there walked off with the loadout exactly as
    -- before. The record on each weapon carries its own owner, so this works
    -- the same whether a stash was ever made or not.
    local holder = ArenaGetPlayer(src)
    local liveId = holder and holder.PlayerData and holder.PlayerData.citizenid or nil

    -- WHO TO CHARGE WHEN NOBODY IS THERE. On a disconnect the player object
    -- is already gone, so there is no live citizen id to compare or to bill
    -- -- and without this the shortfall below had nowhere to go and was
    -- simply dropped. The caller knows whose round it was, and must not stop
    -- saying so.
    --
    -- AND IT NO LONGER ENDS AT WHOEVER IS STANDING THERE. This was
    -- `or liveId`, which answered by guessing the one question this function
    -- exists to answer by evidence. Both tests below compare an owner
    -- against the live holder, so an exit that could not read who it armed
    -- named the live holder as the owner and then found no mismatch -- the
    -- guess agreeing with itself -- and settled a departed fighter's round
    -- against a newcomer's pockets. `fallbackOwner` is a statement about who
    -- was ARMED; the live holder is a statement about who is HERE, and they
    -- are only the same person until somebody reconnects onto a freed slot.
    -- Left unset an unknown owner stays unknown, which is what the tests
    -- below are written to refuse to act on. DO NOT put `or liveId` back.
    local owner = Arena.IsKey(fallbackOwner) and fallbackOwner or nil

    for matchId, byPlayer in pairs(issuedWeapons) do
        local given = byPlayer[src]
        if given then
            -- WHO THE ARENA ARMED FOR THIS MATCH, read here for the same
            -- reason the stock loop below reads it: a weapon row carries its
            -- own citizen id, and that id is empty for exactly one reason --
            -- the framework could not say who was standing there at the
            -- instant the kit was handed over. The stamp is a SECOND read of
            -- the same question, taken again at every consumable handed over
            -- afterwards, so it is often there when the row's own id is not.
            --
            -- This loop was keyed `_, byPlayer` and so had no `matchId` to
            -- look the stamp up with, which is why it had nothing to fall
            -- back to and fell open instead. DO NOT drop the key again.
            local stamped = (issuedOwner[matchId] or {})[src]

            -- THE COPY THE ARENA ISSUED, IDENTIFIED BY ITS SERIAL, and this
            -- is a theft guard rather than a tidiness one. Removing by name
            -- alone took whichever slot ox_inventory found first, so a
            -- fighter carrying their own rifle beside the arena's could lose
            -- THEIRS -- serial, components and tint destroyed to leave the
            -- arena's stock copy behind. takeWeaponBack filters on the
            -- serial, which is the one field that survives being fired, and
            -- this must not go back to a bare name.
            --
            -- AND A REFUSAL IS NOW SAID OUT LOUD. This was a bare pcall
            -- whose result went in the bin, so ox_inventory declining to take
            -- the weapon back was indistinguishable from success.
            -- takeWeaponBack says so when it has something to say: the first
            -- attempt is deliberately quiet, because "the weapon is not there"
            -- and "this build cannot filter on a serial" both land on it and
            -- it works the difference out for itself.
            --
            -- THE RECORD IS STILL DROPPED EITHER WAY, on purpose. This is the
            -- player's own exit and they are standing right there; a weapon
            -- ox_inventory will not remove is not going to be removed by
            -- keeping a row about it, and a debt against somebody who never
            -- left is one nothing would ever collect. The ledger is for kit
            -- that walked off with a CHARACTER, which is a different case
            -- and has its own branch above.
            for _, item in ipairs(given) do
                -- WHOSE ROW THIS IS, and only the two answers that were
                -- written down WHILE THE PLAYER WAS BEING ARMED are allowed
                -- to say: the row's own stamp, then the match stamp.
                --
                -- `fallbackOwner` is deliberately not a third one. It names
                -- the character a STASH RECORD belongs to, and a record is
                -- kept on purpose when a restore could not finish -- so on
                -- this path it can be a leftover from an earlier round and
                -- an earlier character. It is honest enough to bill a
                -- shortfall to, which is all the stock loop below asks of
                -- it, and not honest enough to decide whether to take a
                -- weapon off the person standing here.
                --
                -- The live holder is not on the list either, for the
                -- stronger reason: it is the thing every test here compares
                -- against, so putting it in the answer makes the test agree
                -- with itself and take a stranger's weapon. DO NOT widen
                -- this to anything that is not a record of who was armed.
                local rowOwner = Arena.IsKey(item.citizenid) and item.citizenid
                    or (Arena.IsKey(stamped) and stamped)
                    or nil

                -- NOT THIS PLAYER'S TO GIVE BACK. The arena armed somebody
                -- else on this server id; taking a weapon off whoever
                -- inherited it would be taking one of their own. It goes on
                -- the absent character's slate instead.
                --
                -- AND A ROW WITH NO OWNER FAILS CLOSED. This opened with
                -- `Arena.IsKey(item.citizenid)`, so a row the arena could
                -- not put a name to skipped the ownership test altogether
                -- and fell through to the removal below -- which, for a row
                -- that has no serial either, takes the one copy of that name
                -- it can find. On a server id that has been handed to
                -- somebody else, that copy is the newcomer's own weapon, and
                -- they are told nothing.
                --
                -- "I cannot tell whose this is" is not permission to take it
                -- off whoever happens to be standing here; the arena would
                -- rather write its own weapon off, which is the same
                -- judgement the serial guard below already makes. DO NOT
                -- narrow this back to rows that name an owner.
                if Arena.IsKey(liveId) and rowOwner ~= liveId then
                    if oweWeapon(rowOwner, item) then
                        ArenaLog('weapons: the arena\'s %s (%s) went with %s, not with %s who holds '
                            .. 'their server id now. It is written down against them.',
                            item.name, tostring(item.serial or 'no serial'),
                            tostring(rowOwner), tostring(liveId))
                    elseif Arena.IsKey(rowOwner) then
                        ArenaLog('weapons: the arena\'s %s went with %s and CANNOT be chased -- it was '
                            .. 'issued without a readable serial, so it is written off rather than risk '
                            .. 'taking a weapon of somebody else\'s.',
                            item.name, tostring(rowOwner))
                    else
                        -- NAMED SEPARATELY BECAUSE IT IS A DIFFERENT ANSWER.
                        -- The line above says the arena knows whose weapon
                        -- walked off and cannot chase it; this one says it
                        -- does not know, which is an operator's cue that the
                        -- framework could not identify a player at the door.
                        -- Both end the same way -- written off, nothing
                        -- taken -- and a console that says the wrong one of
                        -- the two sends somebody looking for the wrong fault.
                        ArenaLog('weapons: the arena\'s %s is written off -- it was issued without a '
                            .. 'readable owner, and %s holds that server id now. NOTHING is being taken '
                            .. 'off them for a round they were never in.',
                            item.name, tostring(liveId))
                    end
                elseif not takeWeaponBack(ox, src, item) then
                    -- IT DID NOT COME BACK, SO IT GOES ON THE SLATE. This is
                    -- the branch every ordinary disconnect takes: nobody has
                    -- taken the server id over yet, so the row still looks
                    -- like this player's, and the removal simply fails
                    -- because ox_inventory saved the kit into a character who
                    -- is no longer connected. The record was then dropped a
                    -- line below and the weapons were gone for good -- which
                    -- is the same free loadout by a quieter route.
                    --
                    -- AND "NOT IN THESE POCKETS" IS ON THIS BRANCH TOO, which
                    -- is the owner's answer to the second half of the same
                    -- exploit and NOT an editing tidy-up. `absent` is dropped
                    -- on purpose here: the arena reads the pockets, finds its
                    -- serial gone, and had been calling that settled -- so an
                    -- arena weapon moved out of a fighter's pockets by any
                    -- route the swapItems hook cannot see (another resource's
                    -- server-side RemoveItem, a trunk, a friend's hands) left
                    -- the round free and unrecorded. ox raises no hook on
                    -- another resource's write, so no number of extra hooks
                    -- closes it; only billing the absence does. Measured: 0
                    -- debts and the gun kept, against 1 debt and the gun
                    -- collected the next time they carried it.
                    --
                    -- WHAT IT COSTS is a row for a weapon a corpse dropped,
                    -- which nothing will ever collect -- and this branch is
                    -- only reached with the door OFF or after a stash failed,
                    -- because a stripped exit destroys the pockets wholesale
                    -- and never comes through here. Those rows now age out of
                    -- the table; see OWED_KIT_MAX_DAYS, which was written for
                    -- exactly this. DO NOT narrow this back to a refusal
                    -- without taking the age-out out with it.
                    -- THE SAME `rowOwner` THE TEST ABOVE USED, rather than a
                    -- second one computed here that ended `or liveId`. That
                    -- fallback billed whoever held the server id whenever the
                    -- row could not name its own owner -- so a player who
                    -- reconnected onto a freed slot appeared on the
                    -- outstanding-kit screen owing a weapon they have never
                    -- held, while the character who actually walked off with
                    -- it owed nothing and was never chased. An owner the
                    -- arena cannot name is left unnamed and the row written
                    -- off. DO NOT bill the live holder for a row that does
                    -- not name them.
                    if Arena.IsKey(rowOwner) and Arena.IsKey(item.serial) then
                        -- SAY WHICH ACTUALLY HAPPENED. This logged "put on
                        -- their slate" whether or not it went on, so a full
                        -- ledger dropped the debt while the console said it
                        -- had been recorded. DO NOT log an outcome you did
                        -- not check.
                        if oweWeapon(rowOwner, item) then
                            ArenaDebug('weapons: %s (%s) did not come back off %s -- put on %s\'s slate.',
                                item.name, tostring(item.serial), tostring(src), tostring(rowOwner))
                        else
                            ArenaLog('weapons: %s (%s) did not come back off %s and could NOT be written '
                                .. 'down -- the ledger is full. It is gone.',
                                item.name, tostring(item.serial), tostring(src))
                        end
                    end
                end
            end
            byPlayer[src] = nil
        end
    end

    -- WHAT COULD NOT BE COLLECTED IS WRITTEN DOWN, not shrugged off. These
    -- two loops threw takeBack's answer away and dropped the row regardless,
    -- so every round and every plate the arena could not reach left free and
    -- unrecorded -- the same hole the weapons had, one level down, and the
    -- one that pays best because kill rewards keep topping it up. DO NOT
    -- throw takeBack's answer away again.
    local function reclaimStock(store)
        for matchId, byPlayer in pairs(store) do
            local given = byPlayer[src]
            if given then
                -- WHO THE ARENA ARMED FOR THIS MATCH, which the rows
                -- themselves cannot say. The stamp first, then the caller's
                -- answer, and nothing after those two: both are statements
                -- about who was ARMED, and the stamp is the one of them that
                -- CANNOT be wrong.
                --
                -- `owner` used to end at whoever holds the server id, and
                -- the stranger test one line below compares against whoever
                -- holds the server id -- so on an exit with no stamp and no
                -- caller's answer the two agreed, the test found no
                -- stranger, and this loop took the departed fighter's issued
                -- count of ammunition, plates and bandages out of a
                -- newcomer's pockets, measured against the departed
                -- fighter's floor, with no notification and no ledger row.
                -- An unknown owner must not become the live holder here.
                local stamped = (issuedOwner[matchId] or {})[src]
                local billed = Arena.IsKey(stamped) and stamped or owner

                -- AN EMPTY ID IS NOT A WRONG ONE. This was `billed ==
                -- liveId`, which refuses when NOBODY holds the server id as
                -- readily as when a stranger does -- and nobody holding it is
                -- the ordinary disconnect, the case with the most kit
                -- outstanding. DO NOT go back to demanding a live holder.
                local stranger = Arena.IsKey(liveId) and liveId ~= billed

                -- ASKED BEFORE ANYTHING IS REMOVED, not after. This sat one
                -- line below `takeBack` and gated only the ledger write, so
                -- when a stranger held the server id the arena still walked
                -- the departed character's rows against the NEWCOMER's
                -- pockets -- with the departed character's floor, which for
                -- a stripped fighter is zero -- took their ammunition, their
                -- plates and their bandages, and then politely declined to
                -- write any of it down.
                --
                -- Somebody who has never been in the arena, robbed by the
                -- exit of somebody who has. The weapon loop above gets this
                -- right and refuses before it removes; this is the same test
                -- in the same order. DO NOT put a removal above this check.
                if stranger then
                    -- AN OWNER THE ARENA COULD NOT READ IS SAID AS THAT,
                    -- not printed as `nil`. This branch now also catches the
                    -- rows it could not put a name to, and a console line
                    -- reading "nil's consumables" reads as a bug in the
                    -- logging rather than as the thing an operator needs to
                    -- know: the framework could not identify a player at the
                    -- door.
                    ArenaLog('weapons: %s\'s consumables from match %s are written off -- %s holds '
                        .. 'that server id now, and NOTHING is being taken off them for a round '
                        .. 'they were never in.',
                        Arena.IsKey(billed) and billed or 'an unidentified fighter',
                        tostring(matchId), tostring(liveId))
                    byPlayer[src] = nil
                    goto nextStock
                end

                for item, count in pairs(given) do
                    local _, short, measured = takeBack(ox, src, item, count, floorFor(matchId, src, item))

                    -- MEASURED, AND AGAINST THE RIGHT PERSON. A shortfall is
                    -- only a debt when the arena could actually see what they
                    -- were holding -- and it is only THEIR debt when the
                    -- pockets it measured are the pockets of the character
                    -- being billed. DO NOT drop either half of that test.
                    if short > 0 and measured and Arena.IsKey(billed) then
                        if oweItem(billed, item, short) then
                            ArenaDebug('weapons: %d %s did not come back off %s -- put on %s\'s slate.',
                                short, item, tostring(src), tostring(billed))
                        else
                            ArenaLog('weapons: %d %s did not come back off %s and could NOT be written '
                                .. 'down -- the ledger is full. They are gone.',
                                short, item, tostring(src))
                        end
                    end
                end
                byPlayer[src] = nil
            end

            ::nextStock::
        end
    end

    reclaimStock(issuedAmmo)

    reclaimStock(issuedSupplies)

    -- AND THE STAMP AND THE FLOOR GO WITH THE ROWS. `reclaimStock` nils
    -- `byPlayer[src]` as it settles each match, but the two tables that
    -- describe those rows are keyed the same way and were left standing --
    -- and both are written ONCE and never overwritten, so whatever survives
    -- here is what the next character on this server id inherits.
    --
    -- `forgetWeapons` clears them too, but it is not on this path: an
    -- ordinary disconnect reclaims and never calls it. Leaving it to that
    -- one function covered the exits that drop rows and missed every exit
    -- that collects them, which is most of them. DO NOT rely on
    -- forgetWeapons alone.
    for _, byPlayer in pairs(issuedOwner) do byPlayer[src] = nil end
    for _, byPlayer in pairs(heldBefore) do byPlayer[src] = nil end
end

local function forgetWeapons(src)
    for _, byPlayer in pairs(issuedWeapons) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedAmmo) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedSupplies) do byPlayer[src] = nil end

    -- AND THE STAMP GOES WITH THEM. `rememberHeld` writes the owner once and
    -- then NEVER overwrites a stamp that is already there, so a stamp left
    -- standing after its rows are gone is inherited by the next character to
    -- take this server id in the same match.
    --
    -- That is the exact failure the stamp was added to prevent, pointed the
    -- other way: the newcomer is armed, the arena still believes the
    -- departed character holds the kit, and at the newcomer's ORDINARY exit
    -- every ownership test refuses and their real shortfall is written off.
    -- A free loadout, from the machinery meant to close one. DO NOT drop
    -- rows here without dropping the stamp that describes them.
    for _, byPlayer in pairs(issuedOwner) do byPlayer[src] = nil end

    -- THE FLOOR IS PART OF THE SAME ANSWER, so it cannot be left behind
    -- either. `heldBefore` records what THIS character walked in carrying,
    -- and every debt is `min(issued, held now - that floor)`. Fixing the
    -- stamp so the newcomer is billed correctly, while still measuring them
    -- against the departed character's floor, bills the right person the
    -- wrong number -- and a floor higher than their own stock forgives the
    -- lot. The two are one answer about one character. DO NOT separate them.
    for _, byPlayer in pairs(heldBefore) do byPlayer[src] = nil end
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
    -- THE RECORD AND NOT A FLAG, on purpose. This held `true` and answered
    -- only "did the arena hand this name over"; the removal below needs to
    -- know WHICH copy, which is what the record's serial says.
    local held = (issuedWeapons[matchId] or {})[src] or {}

    local issuedHere = {}
    for _, record in ipairs(held) do
        if type(record) == 'table' and Arena.IsKey(record.name) then
            issuedHere[record.name] = true
        end
    end

    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) and (wanted[entry.key] or wanted[name]) and issuedHere[name] then
            -- THROUGH takeRungBack, which is the same three steps this used
            -- to spell out again: find the arena's row, take that exact copy,
            -- forget only that row. The copy was a second place to fix
            -- anything wrong with the original, and it had already drifted --
            -- it took the FIRST row and then deleted EVERY row of the name.
            -- DO NOT re-inline it.
            if takeRungBack(ox, src, held, name) then
                removed[#removed + 1] = name
            end
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
--- Matches whose rows could not be dropped yet, and the ones that have been
--- shouted about already.
---
--- DECLARED HERE RATHER THAN BESIDE ArenaAmmo.Clear, WHICH IS WHERE IT READS
--- BEST, because the door and the sweep both drive the retry and both are
--- above that function. A local used above its own definition is not a
--- forward reference in Lua, it is a GLOBAL -- silently nil at the call and
--- named in the resource's global scan. DO NOT move these down beside Clear.
local pendingClear = {}
local pendingClearSaid = {}

--- Drops one match's five per-match tables, or says who is stopping it.
--- @return boolean, number|nil, string|nil
local function dropMatchRows(matchId)
    -- THE REFUSAL COMES FIRST, AND `heldBefore` GOES WITH THE REST OR NOT AT
    -- ALL.
    --
    -- This dropped the floor before deciding whether to drop anything. When
    -- the refusal then fired -- somebody's kit still stashed against the
    -- match -- the issued rows survived, as intended, but the record of what
    -- each fighter WALKED IN WITH was already gone. `takeBack` reads that as
    -- a floor of zero, so the exit that followed reclaimed a player's own
    -- ammunition down to nothing.
    --
    -- It bites hardest exactly where the floor is the only protection there
    -- is: with the door off, or after a stash failed, a fighter's own rounds
    -- are loose in their pockets beside the arena's. DO NOT hoist this line
    -- back above the loop.
    for src, record in pairs(stashed) do
        if record.matchId == matchId then return false, src, record.stash end
    end

    heldBefore[matchId] = nil
    issuedOwner[matchId] = nil

    issuedAmmo[matchId] = nil
    issuedWeapons[matchId] = nil
    issuedSupplies[matchId] = nil
    return true
end

--- Asks again for every match whose teardown was refused.
---
--- A REFUSAL USED TO BE PERMANENT. All three callers of ArenaAmmo.Clear throw
--- its boolean away and none of them ever asks a second time, so the five
--- per-match tables for a match with a stranded stash stayed for the life of
--- the process -- long after the exit that stranded it had settled and taken
--- the reason away. They are not big: forgetWeapons drops the rows inside
--- them, so what is left is empty. What is left is also walked, twice, by
--- every exit that happens afterwards, because queueOwedKit and reclaimWeapons
--- both iterate every match this process has ever seen. Measured at four table
--- entries per refused match, for ever: five hundred of them cost one exit two
--- thousand steps through nothing. DO NOT let a refusal be the last word.
local function retryPendingClears()
    if next(pendingClear) == nil then return 0 end

    local cleared = 0
    -- LISTED FIRST, because the drop below takes its own key out of the table
    -- this walks. DO NOT drop from inside the pairs loop.
    local ids = {}
    for matchId in pairs(pendingClear) do ids[#ids + 1] = matchId end

    for _, matchId in ipairs(ids) do
        if dropMatchRows(matchId) then
            pendingClear[matchId] = nil
            pendingClearSaid[matchId] = nil
            cleared = cleared + 1
        end
    end
    return cleared
end

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

    -- ON PURPOSE AT THE DOOR, and not only on the sweep: somebody who walked
    -- off with an arena kit is most likely to be seen again exactly here,
    -- queueing for another round, and collecting the old debt before issuing
    -- a new loadout is what stops the trick paying twice while a timer
    -- catches up.
    --
    -- ABOVE THE DOOR RATHER THAN INSIDE IT, and that is not tidiness. Nested
    -- in the stash block it inherited that block's conditions, so with
    -- `stripOnEntry` off it never ran -- and if `returnRetrySeconds` is also
    -- zero the sweep thread never starts either. Between them the ledger had
    -- NO reader at all on that pair of settings: every debt written, none
    -- ever collected. A weapon debt has nothing to do with whether the door
    -- stashes anything. DO NOT move this back inside.
    -- AND THE SAME THREE THINGS THE SWEEP DOES, IN THE SAME ORDER, because on
    -- `returnRetrySeconds = 0` there IS no sweep. Config says that number
    -- switches off the stash retry, which is what an operator setting it
    -- means -- but the same thread is the only retry the slate read-back has,
    -- and the only thing that ever re-sends a settlement the database refused.
    -- On that one setting the slate was never read back at all if oxmysql came
    -- up second, and no settlement was ever replayed. The door is the other
    -- place a debtor is certain to be standing. DO NOT tie the ledger's own
    -- upkeep to a stash setting.
    replaySettled()
    ArenaAmmo.LoadOwedKit()
    retryPendingClears()

    if ox then
        local holder = ArenaGetPlayer(src)
        local holderId = holder and holder.PlayerData and holder.PlayerData.citizenid or nil
        if Arena.IsKey(holderId) then chaseOwedKit(src, holderId) end
    end

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

            local landed, why, granted = oxGave(function() return ox:AddItem(src, item, count) end)
            if landed then
                supplyRecord[item] = (supplyRecord[item] or 0) + count
                ArenaDebug('supplies: gave %s x%d to %s.', item, count, tostring(src))
            else
                ArenaLog('supplies: %s x%d did not reach %s -- %s. (%d is a lot to carry: check the '
                    .. 'item weight against your ox_inventory player limit.) Nothing is recorded as '
                    .. 'issued, so the exit will not take it out of their own stock.',
                    item, count, tostring(src), gaveWhy(why, granted), count)
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
            -- AND THE KIT IS WRITTEN DOWN RATHER THAN WAVED OFF. DO NOT
            -- drop this and leave forgetWeapons standing on its own.
            --
            -- forgetWeapons alone dropped the issued rows without taking
            -- anything back, which is the whole of a free-loadout exploit:
            -- join a round, /logout mid-match, and the exit finds a stranger
            -- on the server id and gives up. ox_inventory has already saved
            -- the arena's weapons into the character who walked away, and
            -- nothing remembered they were ever issued. Every round, for
            -- free.
            --
            -- Reclaiming from whoever holds the id now is NOT the answer --
            -- they never got a kit, and on any build that matches by name it
            -- would take their own guns. The debt follows the CHARACTER, and
            -- the serial on each row means collecting it can only ever take
            -- the arena's own copy.
            queueOwedKit(record.citizenid, src)

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
        if ox then reclaimWeapons(ox, src, record.citizenid) end
    end

    local ok, wiped = restore(src, record)

    if ok then
        stashed[src] = nil
        owed[record.citizenid] = nil

        if wiped then
            -- WRITTEN DOWN ONLY WHEN THE CLEAR CANNOT HAVE HAPPENED, and
            -- that distinction is the whole of this branch.
            --
            -- `wiped` is not proof. ox_inventory answers a clear against an
            -- inventory that is no longer loaded with nil, and nil reads as
            -- success -- which is exactly what a player sitting at the
            -- character-select screen produces. Their kit was never
            -- destroyed; it is saved into the character they stepped out of,
            -- and forgetting the rows there was a free loadout.
            --
            -- BUT WRITING IT DOWN UNCONDITIONALLY WAS WORSE. On an ordinary
            -- exit the clear really did run and there is nothing to owe --
            -- and because the chase now keeps a row it cannot see rather
            -- than writing it off, every clean round left a debt that could
            -- never clear. Persisted, that filled the table and the admin
            -- screen with players who owe nothing.
            --
            -- THE PLAYER STANDING THERE IS THE EVIDENCE. If this server id
            -- still answers to the character the kit was issued to, the
            -- clear reached a real inventory and settled it. If nobody is
            -- there, or somebody else is, it cannot have -- and that is
            -- exactly the case the ledger exists for.
            local holder = ArenaGetPlayer(src)
            local liveId = holder and holder.PlayerData and holder.PlayerData.citizenid or nil

            if liveId ~= record.citizenid then
                queueOwedKit(record.citizenid, src)
            end

            forgetWeapons(src)
        else
            local ox = inventory()
            if ox then reclaimWeapons(ox, src, record.citizenid) end
        end
    elseif Arena.IsKey(record.citizenid) then
        owed[record.citizenid] = record.stash

        ArenaNotifyKey(src, 'notify.kit_held', 'error')
    end

    ArenaDebug('door: %s left (%s), kit %s', tostring(src), tostring(reasonKey),
        ok and 'returned' or 'STILL STASHED')
    return ok and 1 or 0
end

function ArenaAmmo.Clear(matchId)
    if not Arena.IsKey(matchId) then return false end

    local dropped, src, stash = dropMatchRows(matchId)
    if dropped then
        pendingClear[matchId] = nil
        pendingClearSaid[matchId] = nil
        return true
    end

    -- SAID ONCE PER MATCH, NOT ONCE PER ASK. The refusal is now retried at
    -- every door and every sweep until it goes through, and a line repeating
    -- the same sentence every thirty seconds is the log an operator stops
    -- reading -- the rule this file already states over the empty-read
    -- warning. It is worth saying loudly the first time and worth nothing
    -- after that. DO NOT move this above the retry and make it per-pass.
    if not pendingClearSaid[matchId] then
        pendingClearSaid[matchId] = true
        ArenaLog('door: refusing to drop match %s -- %s\'s kit is still stashed at %s. The rows '
            .. 'are kept and it is asked again at every exit and every sweep. Said once.',
            tostring(matchId), tostring(src), tostring(stash))
    end

    pendingClear[matchId] = true
    return false
end

--- THE READER BELOW GOES THROUGH ownRecord, and that is not tidiness. `stashed` is keyed by server id, a record is deliberately KEPT
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
-- other half prints. DO NOT read `stashed` directly anywhere.
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

--- How many times a character's stash may read EMPTY before the sweep drops
--- them from the close look to the slow one.
---
--- IT WAS ONE, AND ONE WAS A WAY TO LOSE SOMEBODY'S BELONGINGS FOR EVER.
---
--- "A stash that read empty is not a stash that was empty" is the rule this
--- whole path is built on, and the guard below that enforces it needs
--- `stowedCount` -- which lives in `stashed`, which is MEMORY. After a
--- restart there is no record, so the count is zero, so the guard cannot
--- fire: one transient empty read fell straight through to the settled block,
--- the character was marked probed, and nothing ever looked at that stash
--- again for the life of the process. Their phone and their cash sat in it
--- for ever, with no line in the log saying so, because the warning is inside
--- the branch that was skipped.
---
--- A restart is exactly when a transient empty read happens: ox_inventory
--- loads a stash on demand, and the sweep can reach one before it is there.
--- So the answer is not one look, it is several, spread over minutes -- and
--- the moment anything at all comes back, the question is settled properly.
--- DO NOT make this one again.
---
--- AND IT IS NOT A COUNT OF LOOKS BEFORE GIVING UP. It was, and five was the
--- same defect as one on a longer fuse: a stash still loading four minutes
--- after a restart was dropped for the life of the process, exactly as the
--- single look dropped one that was slow by thirty seconds. Measured against
--- the sweep's own default cadence -- a stash blind for eight passes came
--- back, blind for nine never did, and twenty blind passes followed by forty
--- perfectly readable ones never did either. All this number decides now is
--- how long the CLOSE looks last; LOOK_AGAIN_SLOWLY_SECONDS says what happens
--- afterwards. DO NOT turn it back into a give-up.
local EMPTY_READS_BEFORE_SLOWING_DOWN = 5

--- And how far apart those looks are, which is the other half of the answer.
---
--- THE COST THE ONE-LOOK RULE WAS PROTECTING IS REAL AND IS NOT BEING SPENT.
--- The look is a stash read for somebody nothing says is owed anything, which
--- on a full server is a read per player -- and the sweep runs every
--- `returnRetrySeconds`, which is thirty by default. Five looks taken on five
--- consecutive passes is five times the cost in the same two and a half
--- minutes and no more likely to catch anything: what the retry is waiting for
--- is ox_inventory finishing a load, and asking it four more times in the same
--- breath tells you nothing new.
---
--- Spread out, it is one read per player per minute for four minutes, and one
--- per player per LOOK_AGAIN_SLOWLY_SECONDS after that. DO NOT tie the look to
--- the sweep's own cadence.
local LOOK_AGAIN_SECONDS = 60

--- How often the sweep looks once the close looks are used up, WHICH IS NOT
--- NEVER.
---
--- NEVER IS WHAT IT WAS, AND IT IS HOW A PHONE GOES MISSING FOR A WHOLE
--- SESSION. The close looks cover the case they were written for -- an
--- ox_inventory stash that is slow to load after a restart -- and they cover
--- it for four minutes of that player's presence. A stash slower than that
--- fell off the end and was never looked at again: their own phone and their
--- own cash stayed in a stash nothing would open, and NOT ONE LINE was
--- printed, because the warning that would have said so lives inside a branch
--- that needs a memory record which the restart had already erased. Measured
--- over thirty simulated minutes with a phone and forty-two thousand stranded:
--- zero log lines, and the stash still full at the end.
---
--- THE COST THE GIVE-UP WAS PROTECTING IS WORTH STATING IN FULL, because it is
--- what makes this affordable rather than merely kind: one stash read per
--- connected player per five minutes. On a forty-eight slot server that is
--- forty-eight reads per three hundred seconds, against the sixteen hundred
--- the same server would spend over the same five minutes if the close look
--- never slowed down. Roughly a thirtieth of the price the close look already
--- pays, for the one thing this whole file exists to promise.
---
--- DO NOT put a ceiling on the number of slow looks. A ceiling is the give-up
--- again under another name, and the entire defect is that a stash which
--- becomes readable AFTER the ceiling is one nobody ever goes back for.
local LOOK_AGAIN_SLOWLY_SECONDS = 300

local function worthTrying(src, citizenid)
    if owed[citizenid] then return true end

    -- HOW LONG SINCE THE LAST LOOK IS THE ONLY GATE HERE, and the count only
    -- chooses which of the two waits applies. There is no number of empty
    -- reads that shuts the door on a character for good: the close looks give
    -- way to the slow ones and the slow ones do not stop while the player is
    -- still connected. DO NOT put a `return false` back on the look count.
    local looks = probed[citizenid] or 0
    local waitFor = LOOK_AGAIN_SECONDS
    if looks >= EMPTY_READS_BEFORE_SLOWING_DOWN then waitFor = LOOK_AGAIN_SLOWLY_SECONDS end
    if looks > 0 and (os.time() - (probedAt[citizenid] or 0)) < waitFor then
        return false
    end

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
    local hasRecord = false
    for _, record in pairs(stashed) do
        if record.citizenid == citizenid then
            hasRecord = true
            stowedCount = math.max(stowedCount, Arena.ToInt(record.stowedCount) or 0)
        end
    end

    -- LOOKED AT BEFORE THE EXPENSIVE PART, because most passes over most
    -- players find nothing and the snapshot below asks ox_inventory for a
    -- count of every item this server is configured to issue -- ninety-odd
    -- calls, per player, per sweep. There is nothing to snapshot for a stash
    -- with nothing in it.
    --
    -- An unreadable stash is NOT an empty one and never falls through here:
    -- it leaves without answering, exactly as handBack does, so the sweep
    -- comes back rather than counting this character as settled.
    local peek = slotMap(ox, stash)
    if peek == nil then
        ArenaLog('door: could not read %s\'s stash (%s). THEIR KIT IS STILL IN IT -- it is a real '
            .. 'ox_inventory stash and can be opened.', tostring(src), stash)
        return false, 0, false
    end

    local holding = false
    for _ in pairs(peek) do holding = true break end

    -- READ BEFORE THE HAND-BACK, and used by queueOwedKit far below.
    --
    -- Everything past this line puts the player's own belongings into their
    -- pockets, so a count taken after it CANNOT tell their property from the
    -- arena's. The set is bounded -- only what this server is configured to
    -- issue -- and it is the last honest moment to ask. DO NOT move this
    -- below handBack.
    --
    -- ONLY COUNTS THAT WERE ACTUALLY COUNTED GO IN. `Arena.ToInt(answer) or 0`
    -- wrote a zero for the nil ox_inventory answers when it has not loaded an
    -- inventory, and the reader below treats a present entry as measured
    -- fact. Left out, it falls back to a live read instead, which is what the
    -- reader is written to do -- absent is not the same as none.
    local beforeHandBack = {}
    if holding or hasRecord then
        for item in pairs(Arena.AllIssuedItems() or {}) do
            local read, answer = pcall(function() return ox:GetItemCount(src, item) end)
            local counted = read and Arena.ToInt(answer) or nil
            if counted ~= nil then beforeHandBack[item] = math.max(0, counted) end
        end
    end

    local readable, failures, returned = true, 0, 0
    if holding then
        readable, failures, returned = handBack(ox, src, stash)
        if not readable then return false, 0, false end
    end

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

    -- WHOSE POCKETS THE SNAPSHOT DESCRIBES, AND WHY EVERY RECORD OF THEIRS
    -- GETS IT RATHER THAN ONLY THE ONE UNDER THIS SERVER ID.
    --
    -- The snapshot was handed to the record filed under `src` and nothing
    -- else. A player who combat-logs mid-round and reconnects gets a NEW
    -- server id -- the ordinary case, not the exotic one -- so their record
    -- is filed under the old id, missed the snapshot, and the ledger fell
    -- back to reading the pockets of a server id nobody is on. That answers
    -- zero, so nothing was owed: every round and every plate they logged out
    -- holding was forgiven, which is the exact exploit this ledger exists to
    -- close. Reconnecting on the SAME id was billed correctly, which is why
    -- it read as working.
    --
    -- The counts belong to this CHARACTER, and every record here is this
    -- character's. ONE record gets them, though: the snapshot is a single
    -- measurement of a single pair of pockets, and giving it to two records
    -- would bill the same rounds twice -- and this ledger is collected out of
    -- a player's own stock later. DO NOT hand it to more than one.
    local ids = {}
    for other, record in pairs(stashed) do
        if record.citizenid == citizenid then ids[#ids + 1] = other end
    end
    table.sort(ids, function(a, b)
        if a == src then return true end
        if b == src then return false end
        return tostring(a) < tostring(b)
    end)

    for index, other in ipairs(ids) do
        local record = stashed[other]
        if record ~= nil then
            local counted = index == 1 and beforeHandBack or nil
            -- AND THE WEAPONS ARE WRITTEN DOWN, NOT WRITTEN OFF. This loop
            -- settles a character's BELONGINGS -- their own kit is back, so
            -- the stash record goes. It also dropped every arena weapon still
            -- recorded against them, which is a different question and the
            -- wrong answer to it: an admin pressing "return their gear" to
            -- help somebody quietly forgave whatever they were still holding
            -- of the arena's. DO NOT drop this and leave forgetWeapons
            -- standing here on its own.
            queueOwedKit(citizenid, other, counted)
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
    -- THE SLATE IS READ BACK IF IT NEVER WAS, and this is the first thing
    -- the sweep does. Cheap once it has been -- one boolean -- and the only
    -- thing that rescues a server whose `ensure` order put this resource
    -- above oxmysql.
    --
    -- ABOVE THE INVENTORY CHECK AND OUTSIDE THE PLAYER LOOP, both on
    -- purpose. Reading a database has nothing to do with ox_inventory, so
    -- the same bad `ensure` order that this exists to survive must not also
    -- be able to skip it; and an empty server still needs the read, or the
    -- admin screen reports the slate unsaved until somebody happens to
    -- connect.
    --
    -- Inside the loop it fired ONCE PER CONNECTED PLAYER. FiveM Lua does not
    -- preempt, so no callback could land mid-loop to set the guard: thirty
    -- players meant thirty CREATE statements and thirty full-table reads
    -- dispatched together, at the exact moment a struggling database came
    -- up. Worse than the noise, the snapshots were taken at different
    -- instants, and a later-landing older one overwrote what a newer one had
    -- already merged. DO NOT move this back inside the loop.
    --
    -- AND THE SETTLEMENTS THE DATABASE NEVER TOOK GO FIRST, because the read
    -- below is a photograph of the table and a settlement still queued is an
    -- open debt in it. See replaySettled. DO NOT reorder these two.
    replaySettled()
    ArenaAmmo.LoadOwedKit()
    retryPendingClears()

    if not inventory() then return 0 end

    local handed = 0
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        local player = src and ArenaGetPlayer(src) or nil
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if Arena.IsKey(citizenid) then
            -- OUTSIDE `worthTrying`, DELIBERATELY. That gate exists to stop
            -- the stash sweep re-reading a database for a character it has
            -- already answered for, and it is never reopened for the rest of
            -- the session. A weapon debt is a table lookup, it can be
            -- incurred long after that gate shut, and it must not inherit a
            -- decision made about something else.
            chaseOwedKit(src, citizenid)

            if worthTrying(src, citizenid) then
                -- READ BEFORE THE LOOK, because the look is what changes it.
                -- A find made on a SLOW look is the one an operator has to be
                -- told about: it is proof that stashes on this server take
                -- longer to load than the close looks wait for, which is the
                -- condition under which somebody who disconnects before the
                -- slow look comes round is handed nothing at all. Below the
                -- call it reads the counter the call's own answer has already
                -- moved, and every find looks like a close one. DO NOT move
                -- it down.
                local slowLook = (probed[citizenid] or 0) >= EMPTY_READS_BEFORE_SLOWING_DOWN

                local _, returned, answered = ArenaAmmo.ReturnLeftovers(src)

                -- COUNTED, NOT LATCHED. This wrote `true` on the FIRST
                -- answer, and `answered` is true for a stash that read empty
                -- -- which is what an ox_inventory stash looks like in the
                -- moment before it has been loaded. One such read and that
                -- character was never looked at again for the life of the
                -- process. Nothing anywhere cleared this table.
                --
                -- Something actually coming back is proof the stash was read
                -- for real, and settles it -- meaning it goes straight to the
                -- slow cadence rather than counting its way up to it. Nothing
                -- coming back is only ever a vote. DO NOT go back to latching
                -- on one.
                if answered then
                    probedAt[citizenid] = os.time()
                    if returned > 0 then
                        probed[citizenid] = EMPTY_READS_BEFORE_SLOWING_DOWN
                    else
                        probed[citizenid] = (probed[citizenid] or 0) + 1
                    end
                end
                if returned > 0 then
                    handed = handed + 1
                    if slowLook then
                        ArenaLog('door: %s\'s belongings came back on a SLOW look, out of stash %s. '
                            .. 'Their stash read empty for the whole of the first %d minute(s) they '
                            .. 'were looked at, so the close looks had already given out. Nothing was '
                            .. 'lost -- but stashes on this server load slower than the door expects, '
                            .. 'and anybody who leaves before the slow look comes round is handed '
                            .. 'nothing.',
                            tostring(src), stashFor(citizenid),
                            math.floor(EMPTY_READS_BEFORE_SLOWING_DOWN * LOOK_AGAIN_SECONDS / 60))
                    end
                end
            end
        end
    end

    return handed
end

--- Reads the slate back off the database at start.
---
--- WITHOUT THIS THE TABLE IS A WRITE-ONLY LOG. Every debt was written down
--- faithfully and never read again, so a restart still forgot the lot -- the
--- rows just sat there proving it. This is the half that makes the column
--- worth having.
---
--- NOTHING IS CLOBBERED. It merges rather than assigns: `onResourceStart`
--- can land after a match has already begun on a busy server, and a debt
--- incurred in those first seconds must not be wiped by the read that
--- follows it.
function ArenaAmmo.LoadOwedKit()
    if kitLoaded or kitLoading or not ArenaDbReady('the outstanding-kit slate') then return false end

    kitLoading = true

    -- AND THE FLAG IS FREED IF NOTHING EVER ANSWERS. ArenaDb calls back on
    -- every path it controls, but a query oxmysql accepts and then never
    -- answers is not one of them -- and a flag stuck on would end the retry
    -- for the life of the process, turning a guard against reading twice
    -- into a guarantee of never reading at all. The late answer is handled
    -- above. DO NOT set the flag without this releasing it.
    SetTimeout(RETRY_TIMEOUT_MS, function() kitLoading = false end)

    ArenaDb('the outstanding-kit slate', KIT_SCHEMA_SQL, {}, function()
        -- THE AGE-OUT, AND IT GOES ABOVE THE READ ON PURPOSE. A row past the
        -- limit must not come back into memory only to be evicted again by
        -- the cap; deleting it first is what makes the limit mean anything.
        --
        -- ITS ANSWER IS ALSO THE ONE HONEST TEST OF WHETHER THIS DATABASE
        -- USER MAY DELETE, taken at start instead of out of a player's
        -- pockets. It is NOT routed through `wrote`: a statement that matches
        -- no rows is the ordinary case, and latching the loud "slate cannot be
        -- written" warning on it would shout at every healthy server on any
        -- build whose driver answers a nothing-to-do DELETE with nil. Proof
        -- one way only. DO NOT hand this callback to `wrote`.
        --
        -- WHICH ALSO MEANS THE TWO JOBS CANNOT BE SEPARATED. Take this
        -- statement away and nothing else proves a write on a process whose
        -- only ledger traffic is COLLECTIONS -- every one of them is held, on
        -- a perfectly healthy database, for ever. Measured at 0 taken of a
        -- debt of 5. DO NOT remove it without giving kitWriteLanded another
        -- source first.
        ArenaDb('the outstanding-kit slate', KIT_PURGE_SQL, {}, function(answer)
            if answer ~= nil then kitWriteLanded = true end
        end)

        ArenaDb('the outstanding-kit slate', KIT_READ_SQL, {}, function(rows)
            -- CLEARED ON EVERY EXIT FROM HERE, including the failure below.
            -- ArenaDb calls the callback with nil when it cannot send, so both
            -- ways out come through this function -- but leaving the flag
            -- set on the failure path would end the retry permanently, which
            -- is the very thing the retry exists to prevent.
            kitLoading = false

            if type(rows) ~= 'table' then return end

            -- AND A LATE ONE IS REFUSED OUTRIGHT. The timeout below can free
            -- the flag while a read is still out there, so the flag alone
            -- does not prove this is the only answer -- but a second answer
            -- is never wanted. Once one read has merged, the slate in memory
            -- is the live one and anything still on the wire is a photograph
            -- of the table BEFORE whatever has been collected since. Merging
            -- it re-inserts settled debts. DO NOT drop this check.
            if kitLoaded then return end

            local weapons, stacks, skipped = 0, 0, 0

            -- WALKED BACKWARDS, because the read is deliberately the other
            -- way round. The statement is `ORDER BY written_at DESC LIMIT`,
            -- so that a table far past the cap yields the NEWEST rows rather
            -- than the oldest -- and appending them in arrival order then
            -- built each character's slate newest-first.
            --
            -- Every other producer appends newest LAST, and trimOwedKit
            -- evicts index 1 as the oldest and DELETES its row. Fed a
            -- reversed list, it deleted the newest debt from the database
            -- every time a heavy character passed the cap, keeping the
            -- stalest two hundred and erasing everything worth collecting --
            -- the exact inverse of the rule the read order exists to serve.
            -- Reversing here, not in the SQL, keeps both. DO NOT change this
            -- to a forward walk without changing the ORDER BY with it.
            for i = #rows, 1, -1 do
                local row = rows[i]
                local citizenid = type(row) == 'table' and row.citizenid or nil

                -- A ROW ALREADY SETTLED IN MEMORY IS NOT AN OPEN DEBT, and
                -- this read cannot tell the difference on its own. The SELECT
                -- is a photograph of the table taken at one instant, and a
                -- collection that happened either before it (its DELETE not
                -- yet taken) or while it was on the wire is still in the
                -- picture. Merging it puts a settled stack back at its old
                -- total, to be charged again, or re-inserts a weapon the
                -- arena is already holding. settledKeys is the only record
                -- that those settlements happened. DO NOT drop this test.
                local pending = citizenid and settledKeys[citizenid] or nil
                if pending and type(row) == 'table' and pending[row.ledger_key] then
                    citizenid = nil
                end

                if Arena.IsKey(citizenid) then
                    -- THE CAPS APPLY TO WHAT COMES BACK IN, TOO. This read
                    -- was a straight bulk insert with no bound of any kind,
                    -- so a table that had been allowed to grow put every row
                    -- back into memory above the per-character limit and
                    -- above the character limit -- the one path in the whole
                    -- ledger with nothing holding it down.
                    local fresh = owedKit[citizenid] == nil and owedItems[citizenid] == nil
                    if fresh and owedKitCharacters() >= OWED_KIT_CHARACTERS then
                        skipped = skipped + 1
                    elseif row.kind == 'weapon' and Arena.IsKey(row.serial)
                        and Arena.IsKey(row.name)
                    then
                        local held = owedKit[citizenid] or {}
                        local already = false
                        for _, have in ipairs(held) do
                            if have.serial == row.serial then already = true break end
                        end
                        if not already then
                            held[#held + 1] = { name = row.name, serial = row.serial }
                            trimOwedKit(citizenid, held)
                            owedKit[citizenid] = held
                            weapons = weapons + 1
                        end
                    elseif row.kind == 'item' and Arena.IsKey(row.name) then
                        -- THE STORED TOTAL WINS, and it must. This kept
                        -- whatever memory already had and threw the row away
                        -- -- but a stack is a QUANTITY, not an identity, and
                        -- every write to memory is mirrored into that same
                        -- row before this runs. So a debt incurred in the
                        -- moment between the schema call and this read left
                        -- memory holding only the new part while the column
                        -- held the true total; the next collection then
                        -- settled the small number and DELETED the row,
                        -- forgiving everything from before the restart.
                        --
                        -- Skipping the name was the weapon rule applied to
                        -- the wrong kind of debt. DO NOT put it back.
                        local amount = math.max(0, Arena.ToInt(row.amount) or 0)
                        local held = owedItems[citizenid] or {}

                        -- AND THE NAME CAP, which the write side applies and
                        -- this did not. Every other bound is enforced here
                        -- now; leaving one off is how a table that grew once
                        -- grows for ever. DO NOT leave a bound off one side.
                        local names = 0
                        for _ in pairs(held) do names = names + 1 end

                        -- WHICHEVER TOTAL IS HIGHER, because neither side is
                        -- reliably the fresher one. This assigned the stored
                        -- total outright, on the premise that every write to
                        -- memory is mirrored into the row before this runs --
                        -- and the one situation that makes this read retry is
                        -- the situation that falsifies it. A debt incurred
                        -- while oxmysql was still down lives in memory ONLY,
                        -- because ArenaDb drops the write silently; assigning
                        -- the stored total then forgave every round taken
                        -- before the database came up.
                        --
                        -- Taking the larger keeps the original fix -- a
                        -- stored total still beats a memory holding only the
                        -- new part -- without throwing away the half the
                        -- column never saw. DO NOT put the bare assignment
                        -- back.
                        if amount > 0 and (held[row.name] ~= nil or names < OWED_ITEM_LIMIT) then
                            if held[row.name] == nil then stacks = stacks + 1 end
                            held[row.name] = math.max(amount, held[row.name] or 0)
                            owedItems[citizenid] = held
                        elseif amount > 0 then
                            skipped = skipped + 1
                        end
                    end
                end
            end

            kitLoaded = true
            kitSchemaConfirmed = true

            if weapons > 0 or stacks > 0 then
                ArenaLog('weapons: read back %d outstanding weapon(s) and %d item stack(s) that '
                    .. 'players still owe the arena. They are collected the next time each '
                    .. 'character is seen.', weapons, stacks)
            end

            if skipped > 0 then
                ArenaLog('weapons: %d stored row(s) were NOT read back -- the ledger is already at '
                    .. 'its %d-character limit. Those debts stay in the table and are picked up '
                    .. 'once it drains. A table this size means something is not collecting.',
                    skipped, OWED_KIT_CHARACTERS)
            end
        end)
    end)

    return true
end

function ArenaAmmo.Owed()
    local total = 0
    for _ in pairs(owed) do total = total + 1 end
    return total
end

--- Whether the slate is being written somewhere that survives a restart.
--- @return boolean
function ArenaAmmo.OwedKitIsSaved()
    -- THE SAME GATE THE WRITES GO THROUGH, not a second copy of it. This
    -- spelled the two conditions out inline, so the screen an operator reads
    -- to decide whether their slate is safe could disagree with the code
    -- that actually decides whether to send the write. DO NOT restate the
    -- gate; ask it.
    return kitSchemaConfirmed
        and not kitWriteRefused
        and ArenaDbReady('the outstanding-kit slate')
end

--- Every arena weapon that left with a character and has not come back.
---
--- ROWS AND NOT A COUNT, deliberately. `Owed` above answers with a number
--- because its only caller is a limit check, and a number is a thing an
--- operator cannot act on. This debt had no surface at all: nothing outside
--- this file could see who owed what, so a serial that could never be
--- collected, or a door path quietly failing to write one down, was
--- invisible until somebody counted guns by hand.
---
--- IT IS NOT THE SAME KIND OF DEBT AS A STASH, and the screen must not
--- imply it is. A stash is a real ox_inventory row that AllStashes can find
--- again after a restart. This has a table of its own only when the operator
--- turned one on -- ask OwedKitIsSaved, do not assume either way.
--- @return table[] -- { { citizenid, count, weapons = { { name, serial } },
---                       items = { { name, amount } } } }
function ArenaAmmo.OwedKit()
    local byCitizen = {}

    local function slate(citizenid)
        local row = byCitizen[citizenid]
        if not row then
            row = { citizenid = citizenid, count = 0, weapons = {}, items = {} }
            byCitizen[citizenid] = row
        end
        return row
    end

    for citizenid, weapons in pairs(owedKit) do
        local row = slate(citizenid)
        for _, weapon in ipairs(weapons) do
            row.weapons[#row.weapons + 1] = { name = weapon.name, serial = weapon.serial }
            row.count = row.count + 1
        end
    end

    -- ONE SLATE PER CHARACTER, not one per ledger. A player who owes a rifle
    -- and two hundred rounds is one debtor and reads as one line; two lists
    -- for the same person would have an operator counting them twice. DO NOT
    -- split this back into two lists.
    for citizenid, stock in pairs(owedItems) do
        local row = slate(citizenid)
        for name, amount in pairs(stock) do
            row.items[#row.items + 1] = { name = name, amount = amount }
        end
    end

    local rows = {}
    for _, row in pairs(byCitizen) do rows[#rows + 1] = row end

    -- SORTED, because `pairs` is not. The stash list beside this one is
    -- ordered, and an unordered one re-shuffles under the operator's cursor
    -- on every push -- including the push their own click causes.
    -- tostring BOTH SIDES. A row with no citizen id makes this comparison
    -- raise, and it is sorting a screen an admin opens mid-incident. DO NOT
    -- compare these raw.
    table.sort(rows, function(a, b) return tostring(a.citizenid) < tostring(b.citizenid) end)
    return rows
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
