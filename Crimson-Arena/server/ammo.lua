--[[
    crimson_arena/server/ammo.lua

    Handing out ammunition items, and getting every one of them back.

    On a server where ammo types are inventory items, an arena that gives them
    out is an ammo printer unless it also takes them back: join, take two
    hundred armour-piercing rounds, walk out, repeat. So this file is written
    with the same discipline as server/betting.lua's escrow, for the same
    reason -- it is handing a player something with real value, on loan.

    THE RULE: nobody brings their own kit into the arena, and nothing leaves
    with them. A player's whole inventory goes into a private stash at the
    door; they are given only what the loadout screen issued; on the way out
    everything they are carrying is destroyed and their own inventory is handed
    back untouched.

    THAT IS STRONGER THAN RECONCILING COUNTS, and the difference is everything
    a match can produce. Reconciling knows what a player started with and can
    put them back to it. This makes the question not arise: there is nothing in
    their pockets at the end that was not issued, because there was nothing in
    them at the start. Looting a body, picking something off the floor and
    hoarding all come out in the wash.

    WHERE THE STUFF ACTUALLY GOES, because this is the part worth being sure
    about: an ox_inventory STASH, one per character, which ox_inventory
    persists itself. NOT a Lua table in this resource's memory -- a server that
    crashed mid-round would take that with it, and losing somebody's inventory
    is not a bug you get to apologise for.

    AND IF PUTTING IT AWAY FAILS, THE PLAYER IS NOT STRIPPED. They walk in
    carrying their own gear, which is a worse match and a fixable one. Every
    path here is written so that the failure mode is "the arena did not work
    properly" and never "your inventory is gone".

    WHY A FILE OF ITS OWN, rather than a few lines in match.lua: this is the
    only place in the resource that touches a player's inventory, which makes
    it the only place that can duplicate an item. That is worth being able to
    read in one sitting.

    SHIPS OFF. Config.Loadouts.ammoItems.enabled is false until an operator
    has put their own item names in Config.Loadouts.defaultAmmoTypes, because
    handing out an item name that does not exist is a silent nothing, and a
    player who picked armour-piercing and got no ammunition reports it as the
    arena being broken.
]]

ArenaAmmo = {}

--- Who is currently stashed, and where. Present means this resource is
--- holding that player's real inventory and owes it back.
--- @type table<number, { stash: string, matchId: string, citizenid: string }>
local stashed = {}

--- Characters whose exit could not finish, keyed by CITIZEN ID.
---
--- Declared up here because Lua needs it before the code that writes it, but
--- it belongs to THE RETRY at the bottom of this file -- read that comment
--- for what it is for. In one line: `stashed` above is keyed by server id,
--- and a server id does not survive the disconnect that caused half of these
--- failures. This key does.
--- @type table<string, string> -- citizenid -> stash name
local owed = {}

--- Citizen ids whose stash has been looked at at least once this session.
---
--- The restart case, and the only thing that covers it: after a restart
--- `owed` is empty and every stash left behind by the session before is
--- invisible to this resource. So each character gets ONE look on their way
--- past, and then never again -- a bounded cost that finds a stash nothing in
--- memory knows about.
--- @type table<string, boolean>
local probed = {}

--- What was issued, kept only so the console can say what a match handed out.
--- @type table<string, table<number, integer>>
local issued = {}

--- Whether ammunition ITEMS are being handed out. Note this is separate from
--- the door: Config.Loadouts.inventory.stripOnEntry decides whether a player's
--- own kit is taken, and that happens whether or not any ammo item is issued.
--- @return boolean
function ArenaAmmo.IsEnabled()
    local ammoItems = Config.Loadouts.ammoItems
    return type(ammoItems) == 'table' and ammoItems.enabled == true
end

--- @return integer -- rounds one item is worth, never below 1
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

--- How many items a player needs for `rounds` of ammunition, rounded UP.
--- Rounding down would hand somebody 59 rounds when they asked for 60 and one
--- item is worth 30.
--- @param rounds integer
--- @return integer
local function itemsFor(rounds)
    local per = roundsPerItem()
    return math.ceil(math.max(0, Arena.ToInt(rounds) or 0) / per)
end

-- ======================================================================
-- THE DOOR
-- ======================================================================

--- @return table
local function doorConfig()
    return (Config.Loadouts.inventory or {})
end

--- The stash that holds one character's real inventory. Keyed by citizen id
--- rather than server id, so a reconnect finds the same stash and a recycled
--- server id can never open somebody else's.
--- @param citizenid string
--- @return string
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

--- Moves everything a player is carrying into their stash.
---
--- RETURNS FALSE IF ANYTHING AT ALL GOES WRONG, and the caller must then leave
--- the player's inventory alone. Every branch here is written around that: it
--- reads first, writes the stash second, and only clears the player once every
--- item is provably somewhere else.
--- @param src number
--- @param citizenid string
--- @return boolean stowed
local function stow(src, citizenid)
    local ox = inventory()
    if not ox then return false end

    local stash = stashFor(citizenid)

    -- Registered every time rather than once: ox_inventory forgets stashes on
    -- its own restart, and a stash it does not know about accepts nothing.
    local registered = oxDid('registering stash ' .. stash, function()
        return ox:RegisterStash(stash, 'Arena Belongings', 100, 1000000, citizenid)
    end)
    if not registered then
        ArenaLog('door: could not register the stash for %s -- they keep their own kit.', tostring(src))
        return false
    end

    local ok, items = pcall(function() return ox:GetInventoryItems(src) end)
    if not ok or type(items) ~= 'table' then
        ArenaLog('door: could not read %s\'s inventory -- they keep their own kit.', tostring(src))
        return false
    end

    -- Nothing to put away is a success, not a failure: an empty-handed player
    -- is still stripped-and-restored correctly, they simply have nothing.
    for _, item in ipairs(items) do
        local moved = oxDid(('stashing %s x%s'):format(tostring(item.name), tostring(item.count)), function()
            return ox:AddItem(stash, item.name, item.count, item.metadata)
        end)
        if not moved then
            -- Stop at the first failure and put back whatever already moved,
            -- rather than leaving an inventory split across two places.
            ArenaLog('door: could not stash %s x%s for %s -- putting it all back and letting them keep their kit.',
                tostring(item.name), tostring(item.count), tostring(src))
            for _, done in ipairs(items) do
                pcall(function() return ox:RemoveItem(stash, done.name, done.count, done.metadata) end)
            end
            return false
        end
    end

    -- LAST. Everything is provably in the stash before anything is taken.
    local cleared = oxDid('clearing ' .. tostring(src) .. "'s inventory", function()
        return ox:ClearInventory(src)
    end)
    if not cleared then
        ArenaLog('door: stashed %s\'s kit but could not clear their inventory -- putting it back.', tostring(src))
        for _, item in ipairs(items) do
            pcall(function() return ox:RemoveItem(stash, item.name, item.count, item.metadata) end)
        end
        return false
    end

    return true
end

--- Hands one stash's contents back, taking each item OUT of the stash only
--- once it is provably in the player's pockets.
---
--- SPLIT OUT OF restore() SO THE RETRY AT THE BOTTOM OF THIS FILE CAN USE IT,
--- and the halves are not interchangeable. restore() is the exit: it destroys
--- the arena kit first and hands the stash back second. The retry must do
--- only the second half -- somebody being caught up on a return they never
--- got is not carrying an arena kit, and clearing their inventory to find
--- that out would destroy everything they have picked up since.
--- @param ox table -- ox_inventory exports
--- @param src number
--- @param stash string
--- @return boolean readable -- false when the stash itself could not be read
--- @return integer failures -- items that would not go back; still in the stash
--- @return integer returned -- items that did go back
local function handBack(ox, src, stash)
    local ok, items = pcall(function() return ox:GetInventoryItems(stash) end)
    if not ok or type(items) ~= 'table' then
        ArenaLog('door: could not read %s\'s stash (%s). THEIR KIT IS STILL IN IT -- it is a real ox_inventory stash and can be opened.',
            tostring(src), stash)
        return false, 0, 0
    end

    local failures, returned = 0, 0
    for _, item in ipairs(items) do
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

--- Destroys whatever a player is carrying and hands their own inventory back.
--- @param src number
--- @param record table -- the entry from `stashed`
--- @return boolean restored
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
    if not record.cleared then
        if not oxDid('clearing the arena kit from ' .. tostring(src), function()
            return ox:ClearInventory(src)
        end) then
            ArenaLog('door: %s LEFT THE ARENA STILL HOLDING THE KIT IT ISSUED -- their own is being returned on top of it.',
                tostring(src))
        end
        record.cleared = true
    end

    local readable, failures = handBack(ox, src, record.stash)
    if not readable then return false end

    if failures > 0 then
        -- Deliberately NOT cleared. Anything that would not go back is still
        -- sitting in a stash the player can be pointed at.
        ArenaLog('door: %d item(s) of %s\'s could not be returned and are still in stash %s.',
            failures, tostring(src), record.stash)
        return false
    end

    return true
end

-- ======================================================================
-- THE ARENA'S WEAPONS
--
-- WHY THE SERVER HANDS THESE OUT AND NOT THE CLIENT. Without an inventory
-- resource a weapon is a property of the ped, and GiveWeaponToPed on the
-- client is the whole story. With ox_inventory it is not: a weapon is an
-- ITEM, and ox_inventory continuously reconciles what the ped holds against
-- what the inventory contains. Give the ped a weapon it has no item for and
-- ox_inventory takes it straight back off them.
--
-- That is invisible until the door is switched on, and then it is total: the
-- door empties the player's inventory into a stash, so every arena weapon is
-- one ox_inventory has no item for, and every player spawns unarmed.
--
-- So on an ox_inventory server the weapon is added as an item here, with the
-- magazine in its metadata, and client/match.lua does not touch the ped.
-- ======================================================================

--- Weapon items handed out, per match, per player. Only consulted when the
--- door is OFF: with it on, the whole inventory is cleared on the way out and
--- these go with it, tracked or not.
--- @type table<string, table<number, table[]>>
local issuedWeapons = {}

--- Ammunition ITEMS handed out, per match, per player, by item name.
---
--- Kept apart from `issued` above, which is a running count for the console
--- line and cannot be reclaimed against: knowing sixty rounds were given says
--- nothing about which item to take back.
--- @type table<string, table<number, table<string, integer>>>
local issuedAmmo = {}

--- SUPPLIES handed out, per match, per player, by item name.
---
--- A FOURTH RECORD RATHER THAN A COLUMN IN THE THIRD, and the reason is what
--- the third one MEANS. `issuedAmmo` is rounds: ArenaAmmo.OnLoan sums it and
--- reports it as rounds in the console line an operator reads, and a future
--- ammunition-only change would silently reach into anything else stored
--- there. A plate is not a round.
---
--- It is also the thing standing between this feature and a shop. Supplies
--- are real items with real value on a Qbox server; issued and not recorded,
--- a player joins a match, walks out, and keeps them, once a minute, forever.
--- @type table<string, table<number, table<string, integer>>>
local issuedSupplies = {}

--- How the rounds a player picked are split between the magazine in the gun
--- and the loose items in their pocket.
---
--- THE PICK IS A TOTAL, and until now it was issued twice. `issueWeapons`
--- below put the whole amount in the weapon's metadata, and the ammo-item
--- loop in ArenaAmmo.Issue then handed over the whole amount AGAIN as items:
--- sixty rounds picked, sixty in the magazine, sixty in the pocket, a hundred
--- and twenty carried. Two loops, each correct on its own, neither aware the
--- other had already issued everything.
---
--- Nothing caught it because both halves were tested separately -- one spec
--- asserting the magazine, another asserting the item count -- and each one
--- passed. The total was the thing nobody asserted.
---
--- WHEN THERE IS NOTHING TO SPLIT INTO the whole amount stays in the
--- magazine, which is exactly what config.lua says switching ammo items off
--- does: "rounds then travel in the weapon's own metadata instead".
--- @param entry table -- one resolved loadout weapon
--- @return integer loaded -- rounds in the gun
--- @return integer spare -- rounds handed over as items
local function splitRounds(entry)
    local total = math.max(0, Arena.ToInt(entry.ammo) or 0)
    if total == 0 then return 0, 0 end

    if not ArenaAmmo.IsEnabled() or not Arena.IsKey(entry.ammoTypeItem) then
        return total, 0
    end

    -- THE CATALOGUE ENTRY, not the resolved one, because the magazine is
    -- read off the weapon's own `ammo.options` and a resolved entry has
    -- already collapsed that to a single number. A loadout entry with no
    -- catalogue behind it -- the operator's `alwaysGive` list, or a test
    -- double -- falls through to the configured default.
    local catalogue = Arena.IsKey(entry.key) and Arena.GetWeaponByKey(entry.key) or nil

    -- NOT RE-CLAMPED HERE. Arena.MagazineFor floors its input at zero and
    -- returns math.min(whatever it chose, that input) down every branch, so
    -- a second `if loaded > total` on this side is a guard nothing can ever
    -- break -- which is a guard nobody can trust, and one more line claiming
    -- to enforce something it does not.
    local loaded = Arena.MagazineFor(catalogue, total)
    return loaded, total - loaded
end

--- Gives one player the loadout's weapons as ox_inventory items.
--- @param ox table -- ox_inventory exports
--- @param src number
--- @param matchId string
--- @param loadout table
--- @return string[] failed -- weapon keys that could not be handed over
local function issueWeapons(ox, src, matchId, loadout)
    local failed = {}
    local given = {}

    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) then
            -- The magazine rides in metadata rather than being set on the ped
            -- afterwards: on an ox_inventory server SetPedAmmo is reconciled
            -- away exactly like the weapon itself. Melee carries no ammo and
            -- ResolveAmmo already returns 0 for it, which ox_inventory reads
            -- as "not an ammo weapon" rather than "an empty one".
            local metadata = {}
            -- ONE MAGAZINE, NOT THE WHOLE PICK. The rest is handed over as
            -- items by ArenaAmmo.Issue; see splitRounds above for why putting
            -- the full amount here as well was giving everybody double.
            local loaded = select(1, splitRounds(entry))
            if loaded > 0 then metadata.ammo = loaded end

            -- ATTACHMENTS AND TINT RIDE IN THE METADATA TOO, and they were
            -- being dropped here. client/match.lua applies both with natives
            -- on a server WITHOUT ox_inventory -- so a suppressor or a scope
            -- an operator configured arrived on one kind of server and not
            -- the other, from the same config, with nothing to say why.
            --
            -- Only when there is something to carry: ox_inventory reads an
            -- empty `components` list as a weapon with its attachments
            -- explicitly removed, which is not the same as one that was never
            -- given any.
            if type(entry.components) == 'table' and #entry.components > 0 then
                local parts = {}
                for _, component in ipairs(entry.components) do
                    if Arena.IsKey(component) then parts[#parts + 1] = component end
                end
                if #parts > 0 then metadata.components = parts end
            end

            local tint = Arena.ToInt(entry.tint) or 0
            if tint > 0 then metadata.tint = tint end

            -- BOTH have to be true, for the same reason the ammo items below
            -- check both: a pcall that did not throw is not ox_inventory
            -- saying yes. It returns false for an item it does not know, and
            -- a weapon missing from an operator's ox_inventory data is the
            -- single most likely thing to go wrong here.
            local ok, accepted = pcall(function() return ox:AddItem(src, name, 1, metadata) end)
            if ok and accepted ~= false then
                given[#given + 1] = { name = name, metadata = metadata }
                -- SUCCESS IS LOGGED TOO, and it has to be. "No weapon
                -- appeared" has two completely different causes -- the item
                -- was refused, or it was accepted and something took it back
                -- afterwards -- and only one of them used to leave a trace.
                -- Without this line those are the same silence.
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

--- Takes back weapon items when the door did not take everything anyway.
--- @param ox table
--- @param src number
local function reclaimWeapons(ox, src)
    for _, byPlayer in pairs(issuedWeapons) do
        local given = byPlayer[src]
        if given then
            for _, item in ipairs(given) do
                pcall(function() return ox:RemoveItem(src, item.name, 1, item.metadata) end)
            end
            byPlayer[src] = nil
        end
    end

    -- AND THE ROUNDS. Same path, same reason: with the door off nothing else
    -- takes them, and ammunition left behind is a slower version of the same
    -- weapon shop -- a player farming rounds a match at a time.
    for _, byPlayer in pairs(issuedAmmo) do
        local given = byPlayer[src]
        if given then
            for item, count in pairs(given) do
                pcall(function() return ox:RemoveItem(src, item, count) end)
            end
            byPlayer[src] = nil
        end
    end

    -- AND THE SUPPLIES, WHICH ARE THE ONES A PLAYER MEANS TO SPEND.
    --
    -- TAKEN BACK AGAINST WHAT THEY STILL HOLD, not against what they were
    -- given, and that is the difference between this loop and the two above.
    -- A plate and a bandage exist to be used: a fighter who was handed two
    -- bandages and used both holds none, and asking ox_inventory to remove
    -- two from a player holding none is refused OUTRIGHT on most builds --
    -- it does not remove one and shrug. So the arena would take back nothing
    -- at all from exactly the players who consumed the most, which is the
    -- farm this record exists to close, arriving through the one path nobody
    -- would think to test.
    for _, byPlayer in pairs(issuedSupplies) do
        local given = byPlayer[src]
        if given then
            for item, count in pairs(given) do
                local held = 0
                local ok, answer = pcall(function() return ox:GetItemCount(src, item) end)
                if ok then held = Arena.ToInt(answer) or 0 end

                -- A build with no counter at all is asked for the full
                -- amount: taking back what was issued is the right answer
                -- when nothing can tell us otherwise, and a refusal there
                -- costs the arena nothing it had.
                if not ok then held = count end

                local take = math.min(count, held)
                if take > 0 then
                    pcall(function() return ox:RemoveItem(src, item, take) end)
                end
            end
            byPlayer[src] = nil
        end
    end
end

--- Forgets a player's weapon record without removing anything -- for the
--- door path, where the inventory was cleared wholesale.
--- @param src number
local function forgetWeapons(src)
    for _, byPlayer in pairs(issuedWeapons) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedAmmo) do byPlayer[src] = nil end
    for _, byPlayer in pairs(issuedSupplies) do byPlayer[src] = nil end
end

-- ======================================================================
-- ISSUING
-- ======================================================================

--- Takes back the weapons named by `keys`, and forgets them from the issued
--- record so the exit does not try to remove them a second time.
---
--- Keys, not weapon names, because that is what Issue collects: the loadout
--- entry carries both and the failure list is built from `entry.key or
--- entry.weapon`, so it may hold either spelling. Both are matched.
--- @param ox table
--- @param src number
--- @param matchId string
--- @param keys string[]
--- @param loadout table
--- @return string[] removed -- weapon names actually taken back
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
    local takenBack = {}
    for _, entry in ipairs(loadout.weapons or {}) do
        local name = entry.weapon
        if Arena.IsKey(name) and (wanted[entry.key] or wanted[name]) then
            if oxDid('taking back ' .. name, function() return ox:RemoveItem(src, name, 1) end) then
                removed[#removed + 1] = name
                takenBack[name] = true
            end
        end
    end

    -- Forgotten from the issued record too. A weapon this took back is no
    -- longer on the player, and leaving it listed would have the exit try to
    -- remove it again -- which on a name that happens to collide with
    -- something of their own removes theirs.
    --
    -- Only the ones actually taken: a removal ox_inventory refused leaves
    -- the weapon on the player, and forgetting it there would walk it out
    -- of the arena.
    local held = (issuedWeapons[matchId] or {})[src]
    if type(held) == 'table' then
        for index = #held, 1, -1 do
            local record = held[index]
            if type(record) == 'table' and takenBack[record.name] then table.remove(held, index) end
        end
    end

    return removed
end

--- Puts the player's own kit away, then gives them what the loadout says.
---
--- Returns the weapon keys whose ammo item could not be handed over.
--- @param src number
--- @param matchId string
--- @param loadout table -- Arena.ResolveLoadout output
--- @return string[] failed
function ArenaAmmo.Issue(src, matchId, loadout)
    local failed = {}
    if type(src) ~= 'number' or src <= 0 or not Arena.IsKey(matchId) then return failed end
    if type(loadout) ~= 'table' then return failed end

    local ox = inventory()

    -- THE DOOR, before anything is issued.
    --
    -- ASKED PER MATCH, NOT PER PLAYER, and that is the other half of the
    -- data-loss fix above. This used to skip anybody who already had a
    -- record -- which is exactly the state a partly-failed return leaves
    -- behind. So a player whose phone had gone back but whose water had not
    -- walked into their NEXT round still carrying the phone, because the
    -- door decided it had already stowed them. The exit then cleared them
    -- out, and the phone was the arena's to destroy as far as any of this
    -- could tell.
    --
    -- Stowing again is safe and additive: the stash is named from the
    -- citizen id, so the phone joins the water in the same one, and the
    -- fresh record's clear is unspent again for the new round.
    local held = stashed[src]
    local alreadyStowedForThisMatch = held ~= nil and held.matchId == matchId

    if ox and doorConfig().stripOnEntry ~= false and not alreadyStowedForThisMatch then
        local player = ArenaGetPlayer(src)
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if not Arena.IsKey(citizenid) then
            ArenaLog('door: no citizen id for %s -- they keep their own kit.', tostring(src))
        elseif stow(src, citizenid) then
            stashed[src] = { stash = stashFor(citizenid), matchId = matchId, citizenid = citizenid }
            ArenaDebug('door: stashed %s\'s kit for match %s', tostring(src), tostring(matchId))
        end
    end

    -- THE WEAPONS, and note where this sits: BEFORE the ammo-items check
    -- below. Ammo items are an opt-in feature that ships off; the weapons
    -- are the arena. Putting this behind that toggle is what would leave an
    -- ox_inventory server issuing nobody anything at all.
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
            -- The same proof the rounds use: pcall succeeding only says the
            -- call did not throw, and ox_inventory answers `false` for a
            -- full inventory or an item name it does not know.
            local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
            if ok and granted ~= false then
                supplyRecord[item] = (supplyRecord[item] or 0) + count
            else
                ArenaLog('supplies: could not give %s x%d to %s -- check that item exists on this server.',
                    item, count, tostring(src))
            end
        end
    end

    if not ArenaAmmo.IsEnabled() then return failed end
    if not ox then
        ArenaLog('ammo items are switched on but ox_inventory is not started -- nobody is being given any.')
        return failed
    end

    issued[matchId] = issued[matchId] or {}
    local given = issued[matchId][src] or 0

    -- BY NAME AS WELL AS BY COUNT, and the count alone was a leak.
    --
    -- A running total says how much was handed over; it does not say WHAT, so
    -- there is nothing for the exit to remove. With the door on that never
    -- showed, because the door clears the whole inventory anyway. With the
    -- door off -- `stripOnEntry = false` -- the rounds simply stayed: join,
    -- collect sixty, leave, keep them, repeat. The weapons were already
    -- recorded by name for exactly this reason; the ammunition was not.
    issuedAmmo[matchId] = issuedAmmo[matchId] or {}
    local record = issuedAmmo[matchId][src] or {}
    issuedAmmo[matchId][src] = record

    for _, entry in ipairs(loadout.weapons or {}) do
        local item = entry.ammoTypeItem
        -- THE REMAINDER, not the whole pick. The magazine already carries the
        -- rest of it; issuing the full amount here as well is what doubled
        -- everybody's ammunition.
        local _, spare = splitRounds(entry)
        local count = itemsFor(spare)

        if Arena.IsKey(item) and count > 0 then
            -- BOTH have to be true. pcall succeeding only means the call did
            -- not throw; ox_inventory returns false for a full inventory or an
            -- item name that does not exist.
            local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
            if ok and granted ~= false then
                given = given + count
                record[item] = (record[item] or 0) + count
            else
                failed[#failed + 1] = entry.key or entry.weapon
                ArenaLog('ammo: could not give %s x%d to %s -- check that item exists on this server.',
                    item, count, tostring(src))
            end
        end
    end

    issued[matchId][src] = given

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

-- ======================================================================
-- THE WAY OUT
-- ======================================================================

--- Destroys the arena kit and hands the player's own inventory back.
---
--- Safe to call for somebody who was never stashed, and safe to call twice --
--- the record is dropped on the first call.
--- @param src number
--- @param reasonKey string?
--- @return integer restored -- 1 when a stash was handed back, 0 otherwise
function ArenaAmmo.Reclaim(src, reasonKey)
    if type(src) ~= 'number' or src <= 0 then return 0 end

    local record = stashed[src]

    -- NO STASH IS NOT NOTHING TO DO. With the door switched off a player
    -- keeps their own inventory and is simply handed the arena's weapons on
    -- top of it -- so there is no wholesale clear on the way out, and the
    -- arena's weapons are only removed if something removes them by name.
    -- Returning early here left every issued weapon in the player's pockets,
    -- permanently, on the one setting where nothing else would catch it.
    if not record then
        local ox = inventory()
        if ox then reclaimWeapons(ox, src) end
        return 0
    end

    -- A SECOND PASS OVER THE SAME RECORD does not get to clear the player
    -- out (restore refuses to, above) -- so the arena's own weapons have to
    -- come off some other way, or they walk out on top of the belongings
    -- this pass is about to hand back. By name is the only safe way left:
    -- it removes what this resource issued and nothing else.
    if record.cleared then
        local ox = inventory()
        if ox then reclaimWeapons(ox, src) end
    end

    local ok = restore(src, record)

    -- THE RECORD IS DROPPED ONLY IF THE KIT ACTUALLY CAME BACK.
    --
    -- It used to be cleared on the line above the restore, and the two
    -- failures restore() reports are precisely the ones where the player's
    -- belongings are STILL IN THE STASH -- ox_inventory gone, or the stash
    -- unreadable. Its own log says so in as many words, and offers the stash
    -- name because it is a real openable stash. Forgetting the record threw
    -- that name away: nothing could retry, ArenaAmmo.Clear stopped refusing
    -- over them, IsHolding and StashOf said there was nothing held, and the
    -- line below printed STILL STASHED about a record it had just deleted.
    --
    -- Keeping it costs a stale row on a server whose inventory is broken.
    -- Dropping it costs a player everything they walked in with, and leaves
    -- nobody able to say where it went.
    if ok then
        stashed[src] = nil
        owed[record.citizenid] = nil

        -- Forgotten rather than removed, and only here: restore() clears the
        -- whole inventory before putting their own kit back, so the arena's
        -- weapons are already gone and removing them again would be removing
        -- items that no longer exist -- or, worse, their own if a name
        -- happened to collide.
        --
        -- ON A FAILED RESTORE NONE OF THAT HAPPENED. With ox_inventory gone
        -- there was no clear at all, so the arena's weapons are still on the
        -- player -- and forgetting them here is what stops any later exit
        -- from taking them back.
        forgetWeapons(src)
    elseif Arena.IsKey(record.citizenid) then
        -- THE HANDLE EVERY RETRY WORKS FROM, and the line that turns "it was
        -- logged and somebody will read the console" into "the server keeps
        -- trying". restore() has just said their belongings are still in the
        -- stash; this remembers that in a form which outlives their server
        -- id. See THE RETRY at the bottom of this file.
        owed[record.citizenid] = record.stash
    end

    ArenaDebug('door: %s left (%s), kit %s', tostring(src), tostring(reasonKey),
        ok and 'returned' or 'STILL STASHED')
    return ok and 1 or 0
end

--- @param matchId string
--- @param reasonKey string?
--- @return integer players
function ArenaAmmo.ReclaimAll(matchId, reasonKey)
    if not Arena.IsKey(matchId) then return 0 end

    -- The UNION of both records, for the same reason Reclaim now handles
    -- both: with the door off nobody has a stash, so walking `stashed` alone
    -- would walk an empty table and reclaim nothing from a match where every
    -- player is carrying arena weapons.
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
    -- THE OTHER TWO RECORDS TOO. A player whose weapons all failed to issue
    -- but who was handed rounds or a plate is in neither of the tables this
    -- walk used to read, so nothing was ever taken back from them.
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

--- Drops a match's record. REFUSES while this resource still owes anybody
--- their inventory, the same way ArenaBetting.Clear refuses over escrow.
--- @param matchId string
--- @return boolean cleared
function ArenaAmmo.Clear(matchId)
    if not Arena.IsKey(matchId) then return false end

    for src, record in pairs(stashed) do
        if record.matchId == matchId then
            ArenaLog('door: refusing to drop match %s -- %s\'s kit is still stashed at %s.',
                tostring(matchId), tostring(src), record.stash)
            return false
        end
    end

    -- ALL THREE, not just the count. `issued` is a running total per player,
    -- `issuedAmmo` is what they were given BY NAME (which is what the exit
    -- removes) and `issuedWeapons` is the same for guns. Dropping only the
    -- first left the other two growing for the life of the server -- one
    -- entry per match, never freed, on a resource whose whole job is running
    -- matches back to back.
    issued[matchId] = nil
    issuedAmmo[matchId] = nil
    issuedWeapons[matchId] = nil
    issuedSupplies[matchId] = nil
    return true
end

--- How many rounds one match is still on the hook for.
---
--- The observable form of an invariant that had none: a finished match must
--- end up owing nothing. Nothing could see these tables from outside, so
--- nothing noticed when ArenaAmmo.Clear turned out to be called from
--- nowhere at all and every match a server ran left its records behind.
---
--- Several test doubles in this suite already stub an `OnLoan` -- written
--- against a function that did not exist.
--- @param matchId string
--- @return integer rounds
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
function ArenaAmmo.IsHolding(src)
    return stashed[src] ~= nil
end

--- The stash a player's kit is in, for an admin who needs to point them at it.
--- @param src number
--- @return string|nil
function ArenaAmmo.StashOf(src)
    local record = stashed[src]
    return record and record.stash or nil
end

-- ======================================================================
-- THE RETRY
--
-- WHAT THIS IS FOR, AND IT IS NOT AN EDGE CASE. The exit above hands a
-- player's own inventory back, and every branch of it that can fail leaves
-- their belongings in the stash rather than destroying them. That is the
-- half of the promise this resource already kept. The other half was
-- missing: NOTHING EVER TRIED AGAIN. It logged a line naming the stash and
-- then waited for an operator to read the console and hand somebody their
-- things back by hand -- which, on the one piece of code that holds a
-- player's entire inventory, is not a return policy.
--
-- Three ordinary things land there, none of them exotic:
--
--   A FULL INVENTORY, OR A WEIGHT LIMIT. ox_inventory refuses the item and
--   says so, plainly, and the door leaves it in the stash -- correctly. Two
--   minutes later the player has dropped something and it would go straight
--   in. Nobody asked it again.
--
--   A DISCONNECT. playerDropped reclaims, which means handing items to a
--   source that has already left; ox_inventory refuses what it cannot put
--   anywhere. So far so good -- except `stashed` is keyed by SERVER ID, and
--   the id they come back on is a different one. Nothing in memory pointed
--   at their stash any more.
--
--   A SERVER RESTART. `stashed` is in memory and goes with it. The stash
--   does NOT: it is a real ox_inventory stash, persisted by ox_inventory,
--   named from the character's citizen id and nothing else -- so it is still
--   there afterwards, and still findable, by anything that thinks to look.
--
-- So this keeps asking. `owed` is keyed by citizen id, which survives the
-- reconnect; the sweep walks the players actually on the server, so it costs
-- nothing on an empty one; and each character gets one look at their stash
-- on the way past even when nothing in memory says they are owed anything,
-- which is what finds what a restart forgot.
--
-- WHAT IT WILL NOT DO, and this is the guard that matters most: it never
-- hands anything to a player who is mid-match. The exit clears the whole
-- inventory BEFORE it reads the stash, so putting somebody's own kit into
-- their pockets during a round means the next exit destroys it. An
-- unanswerable "are they in a round?" is therefore answered as YES. Waiting
-- costs a few more minutes in a stash. Guessing wrong costs everything they
-- own.
-- ======================================================================

--- How often the sweep runs, when the config says nothing.
local RETRY_SECONDS = 30

--- Whether this player is in a live round right now.
---
--- ASKED BEFORE EVERY RETURN. ArenaDispatch is part of this resource, but it
--- loads after this file, so it is asked for rather than assumed -- and when
--- it cannot be asked the answer is YES, because "do nothing" is the only
--- safe way to be wrong here.
--- @param src number
--- @return boolean
local function midMatch(src)
    if type(ArenaDispatch) == 'table' and type(ArenaDispatch.IsPlayerInArena) == 'function' then
        return ArenaDispatch.IsPlayerInArena(src) == true
    end
    return true
end

--- Whether this player's stash is worth opening on this pass.
---
--- NOT WHETHER IT IS SAFE TO HAND ANYTHING OVER -- that is asked once, in
--- ReturnLeftovers below, which is the only thing that hands anything over
--- and is public besides. Repeating it here would be a guard nothing could
--- ever break a test by removing, which is a guard nobody can trust.
--- @param src number
--- @param citizenid string
--- @return boolean
local function worthTrying(src, citizenid)
    -- A KNOWN DEBT. The exit ran, could not finish, and said so.
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
    return stashed[src] == nil
end

--- Hands back anything of this player's still sitting in their arena stash.
---
--- SAFE TO CALL FOR ANYBODY, at any time. A player who is mid-match, who has
--- no stash, or whose stash is empty is left completely alone.
--- @param src number
--- @return boolean settled -- true when nothing of theirs is left in a stash
--- @return integer returned -- items handed over on this call
--- @return boolean answered -- true when the stash was actually read, whether
---         or not everything in it would go back
function ArenaAmmo.ReturnLeftovers(src)
    if type(src) ~= 'number' or src <= 0 then return false, 0, false end
    if midMatch(src) then return false, 0, false end

    local player = ArenaGetPlayer(src)
    local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil
    if not Arena.IsKey(citizenid) then return false, 0, false end

    local ox = inventory()
    if not ox then return false, 0, false end

    local stash = stashFor(citizenid)

    -- REGISTERED FIRST, and this is what makes the restart case work at all:
    -- ox_inventory forgets every stash it was told about when it restarts,
    -- and a stash it does not know about is not one it will read.
    if not oxDid('registering stash ' .. stash, function()
        return ox:RegisterStash(stash, 'Arena Belongings', 100, 1000000, citizenid)
    end) then
        return false, 0, false
    end

    local readable, failures, returned = handBack(ox, src, stash)
    if not readable then return false, 0, false end

    if returned > 0 then
        ArenaLog('door: handed %d item(s) back to %s out of stash %s -- a return that had not gone through.',
            returned, tostring(src), stash)
    end

    if failures > 0 then
        -- STILL THEIRS, STILL IN THE STASH, AND THIS IS WHAT COMES BACK FOR
        -- IT. The stash has now been read, so the sweep's one-look-per-
        -- character rule is satisfied and will not bring anybody here again;
        -- from this point on the debt list is the only thing that does.
        owed[citizenid] = stash
        return false, returned, true
    end

    -- SETTLED, so every record holding this player open is dropped -- the
    -- by-server-id one included, and that one matters beyond tidiness:
    -- ArenaAmmo.Clear refuses to drop a match while any record names it, so
    -- a restore that failed and later succeeded would otherwise pin that
    -- match's tables for the life of the server. The record may well be
    -- under a DIFFERENT server id than the one being handed the items --
    -- that is the reconnect this whole section exists for -- so it is found
    -- by citizen id, not by src.
    owed[citizenid] = nil
    for other, record in pairs(stashed) do
        if record.citizenid == citizenid then
            stashed[other] = nil
            forgetWeapons(other)
        end
    end

    return true, returned, true
end

--- One pass over everybody on the server.
--- @return integer handed -- players who got something back on this pass
function ArenaAmmo.SweepReturns()
    if not inventory() then return 0 end

    local handed = 0
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        local player = src and ArenaGetPlayer(src) or nil
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if Arena.IsKey(citizenid) and worthTrying(src, citizenid) then
            local _, returned, answered = ArenaAmmo.ReturnLeftovers(src)

            -- MARKED ON AN ANSWER, NOT ON A GOOD ONE, and the distinction
            -- is the whole value of the once-only look. `answered` means the
            -- stash was registered and read: whatever is in there, this
            -- character's one look has been spent usefully, and anything
            -- still outstanding was written to the debt list, which is what
            -- brings the sweep back to them.
            --
            -- NOT AN ANSWER: ox_inventory that has not started yet, a stash
            -- it would not register, a read that threw. Marking those would
            -- spend the one look on a failure and leave whatever is in that
            -- stash invisible until the player next reconnects -- which is
            -- the shape of the bug this whole section exists to kill, rebuilt
            -- inside the fix.
            if answered then probed[citizenid] = true end
            if returned > 0 then handed = handed + 1 end
        end
    end

    return handed
end

--- How many characters this resource still owes belongings to.
---
--- The observable form of a promise that had none, and the same reason
--- ArenaAmmo.OnLoan exists a few functions up: a resource that hands
--- inventories back has to be able to say, out loud, whether it currently
--- owes anybody anything. Nothing could see this list from outside, and a
--- debt nobody can count is a debt nobody notices going unpaid.
--- @return integer characters
function ArenaAmmo.Owed()
    local total = 0
    for _ in pairs(owed) do total = total + 1 end
    return total
end

CreateThread(function()
    local seconds = Arena.ToInt(doorConfig().returnRetrySeconds)
    if seconds == nil then seconds = RETRY_SECONDS end

    -- ZERO OR BELOW SWITCHES IT OFF, and config.lua says what that costs: an
    -- item that would not go back stays in the stash until somebody opens it
    -- by hand.
    if seconds <= 0 then return end

    while true do
        Wait(seconds * 1000)
        ArenaAmmo.SweepReturns()
    end
end)


-- ======================================================================
-- NO DROPPING
--
-- A dropped item becomes its own inventory in the world, and finding every one
-- of them again afterwards is guesswork. Not dropping in the first place is
-- not. ox_inventory's swapItems hook is the supported way to refuse a move, so
-- that is what this uses -- guarded, because a version without hooks must
-- degrade to "drops are allowed" rather than to "the resource fails to start".
-- ======================================================================
CreateThread(function()
    if doorConfig().blockDropsInArena == false then return end

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
        ArenaLog('door: ox_inventory never started, so dropping in an arena cannot be blocked. Anything dropped stays on the floor.')
        return
    end

    local ok = pcall(function()
        return ox:registerHook('swapItems', function(payload)
            -- Only a player who is actually mid-match, and only a move OUT of
            -- their own inventory to something that is not theirs. Moving
            -- things around inside their own pockets stays their business.
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
            -- every other guard in this file keeps one -- server/dispatch.lua
            -- loads after this file, so the function is asked for rather
            -- than assumed.
            local inArena = stashed[src] ~= nil
            if not inArena and type(ArenaDispatch) == 'table'
                and type(ArenaDispatch.IsPlayerInArena) == 'function'
            then
                inArena = ArenaDispatch.IsPlayerInArena(src) == true
            end
            if not inArena then return true end

            local target = payload.toInventory
            if target and target ~= src and tostring(target) ~= tostring(src) then
                ArenaNotifyKey(src, 'error.no_dropping_in_arena', 'error')
                return false
            end
            return true
        end, { print = false })
    end)

    if not ok then
        ArenaLog('door: ox_inventory would not take a swapItems hook, so dropping cannot be blocked. Anything dropped in an arena stays on the floor.')
    end
end)

-- A restart mid-match would otherwise leave every player in every arena
-- holding whatever the round gave them. This is the last chance to square
-- everyone up, so it runs before anything else tears down.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- The kit is in a real ox_inventory stash and survives regardless, but
    -- handing it straight back is far better than leaving somebody to work out
    -- where it went.
    local sources = {}
    for src in pairs(stashed) do sources[#sources + 1] = src end
    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, 'resource stopping')
    end
end)
