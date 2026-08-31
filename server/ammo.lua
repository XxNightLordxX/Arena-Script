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
    local registered = pcall(function()
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
        local moved = pcall(function()
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
    local cleared = pcall(function() return ox:ClearInventory(src) end)
    if not cleared then
        ArenaLog('door: stashed %s\'s kit but could not clear their inventory -- putting it back.', tostring(src))
        for _, item in ipairs(items) do
            pcall(function() return ox:RemoveItem(stash, item.name, item.count, item.metadata) end)
        end
        return false
    end

    return true
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
    pcall(function() return ox:ClearInventory(src) end)

    local ok, items = pcall(function() return ox:GetInventoryItems(record.stash) end)
    if not ok or type(items) ~= 'table' then
        ArenaLog('door: could not read %s\'s stash (%s). THEIR KIT IS STILL IN IT -- it is a real ox_inventory stash and can be opened.',
            tostring(src), record.stash)
        return false
    end

    local failures = 0
    for _, item in ipairs(items) do
        local given = pcall(function()
            return ox:AddItem(src, item.name, item.count, item.metadata)
        end)
        if given then
            pcall(function() return ox:RemoveItem(record.stash, item.name, item.count, item.metadata) end)
        else
            failures = failures + 1
        end
    end

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
-- ISSUING
-- ======================================================================

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
    if ox and doorConfig().stripOnEntry ~= false and not stashed[src] then
        local player = ArenaGetPlayer(src)
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil

        if not Arena.IsKey(citizenid) then
            ArenaLog('door: no citizen id for %s -- they keep their own kit.', tostring(src))
        elseif stow(src, citizenid) then
            stashed[src] = { stash = stashFor(citizenid), matchId = matchId, citizenid = citizenid }
            ArenaDebug('door: stashed %s\'s kit for match %s', tostring(src), tostring(matchId))
        end
    end

    if not ArenaAmmo.IsEnabled() then return failed end
    if not ox then
        ArenaLog('ammo items are switched on but ox_inventory is not started -- nobody is being given any.')
        return failed
    end

    issued[matchId] = issued[matchId] or {}
    local given = issued[matchId][src] or 0

    for _, entry in ipairs(loadout.weapons or {}) do
        local item = entry.ammoTypeItem
        local count = itemsFor(entry.ammo)

        if Arena.IsKey(item) and count > 0 then
            -- BOTH have to be true. pcall succeeding only means the call did
            -- not throw; ox_inventory returns false for a full inventory or an
            -- item name that does not exist.
            local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
            if ok and granted ~= false then
                given = given + count
            else
                failed[#failed + 1] = entry.key or entry.weapon
                ArenaLog('ammo: could not give %s x%d to %s -- check that item exists on this server.',
                    item, count, tostring(src))
            end
        end
    end

    issued[matchId][src] = given
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
    if not record then return 0 end
    stashed[src] = nil

    local ok = restore(src, record)
    ArenaDebug('door: %s left (%s), kit %s', tostring(src), tostring(reasonKey),
        ok and 'returned' or 'STILL STASHED')
    return ok and 1 or 0
end

--- @param matchId string
--- @param reasonKey string?
--- @return integer players
function ArenaAmmo.ReclaimAll(matchId, reasonKey)
    if not Arena.IsKey(matchId) then return 0 end

    local sources = {}
    for src, record in pairs(stashed) do
        if record.matchId == matchId then sources[#sources + 1] = src end
    end
    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, reasonKey)
    end

    issued[matchId] = nil
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

    issued[matchId] = nil
    return true
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

--- @param matchId string
--- @param src number
--- @return integer
function ArenaAmmo.IssuedTo(matchId, src)
    local match = issued[matchId]
    return match and match[src] or 0
end

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

    local ox = inventory()
    if not ox then return end

    local ok = pcall(function()
        return ox:registerHook('swapItems', function(payload)
            -- Only a player who is actually mid-match, and only a move OUT of
            -- their own inventory to something that is not theirs. Moving
            -- things around inside their own pockets stays their business.
            local src = payload and payload.source
            if not src or not stashed[src] then return true end

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
