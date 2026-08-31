--[[
    crimson_arena/server/ammo.lua

    Handing out ammunition items, and getting every one of them back.

    On a server where ammo types are inventory items, an arena that gives them
    out is an ammo printer unless it also takes them back: join, take two
    hundred armour-piercing rounds, walk out, repeat. So this file is written
    with the same discipline as server/betting.lua's escrow, for the same
    reason -- it is handing a player something with real value, on loan.

    THE RULE: a player leaves the arena with exactly the ammunition they
    walked in with. Not "what we gave them, minus what we took back" -- the
    actual count they held before the match, restored.

    THAT IS DELIBERATELY STRONGER THAN A LEDGER, and the difference is looting.
    A ledger knows what this resource ISSUED, so it can take that back. It
    knows nothing about a player who killed somebody and emptied their pockets,
    and on a server where ammunition is an inventory item that is the obvious
    way to carry a match's worth of rounds out of the arena. So the baseline is
    the player's own inventory, snapshotted on the way in and restored on the
    way out: anything gained inside -- issued, looted, or found -- goes, and
    anything they owned beforehand survives untouched.

    Their own rounds are given back even if they FIRED them. Arena ammunition
    is issued first and spent first, and reconciling to the snapshot is what
    makes the arena cost nothing; a player who walks out lighter than they
    walked in would rightly call that a bug.

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

--- What each player held BEFORE the arena touched anything, for every item
--- any ammo type can hand out. This is the thing restored on the way out.
--- @type table<number, table<string, integer>>
local baseline = {}

--- Which match each snapshot belongs to, so a whole match can be torn down.
--- @type table<number, string>
local snapshotMatch = {}

--- What was actually issued, kept only so the console can say what a match
--- handed out. Nothing reconciles against it -- see the header.
--- @type table<string, table<number, integer>>
local issued = {}

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
--- Looked up per call rather than cached at load: an operator restarting
--- their inventory resource must not leave this file holding a dead handle
--- for the rest of the session.
--- @return table|nil
local function inventory()
    if GetResourceState('ox_inventory') ~= 'started' then return nil end
    return exports.ox_inventory
end

--- How many items a player needs for `rounds` of ammunition, rounded UP.
--- Rounding down would hand somebody 59 rounds when they asked for 60 and
--- one item is worth 30.
--- @param rounds integer
--- @return integer
local function itemsFor(rounds)
    local per = roundsPerItem()
    return math.ceil(math.max(0, Arena.ToInt(rounds) or 0) / per)
end

-- ======================================================================
-- THE SNAPSHOT
-- ======================================================================

--- Reads how many of `item` a player is holding. Returns nil when the count
--- cannot be read at all, which is different from zero and is treated as
--- "do not touch this item" everywhere below -- guessing zero would have the
--- restore hand somebody a pile of ammunition they never owned.
--- @param ox table
--- @param src number
--- @param item string
--- @return integer|nil
local function countOf(ox, src, item)
    local ok, count = pcall(function() return ox:Search(src, 'count', item) end)
    if not ok then return nil end

    local number = Arena.ToInt(count)
    if not number or number < 0 then return nil end
    return number
end

--- Records what a player is carrying before the arena gives them anything.
---
--- Taken across EVERY item any ammo type can hand out, not just the ones this
--- loadout uses: the whole point is to catch rounds picked up during the
--- match, and those can be of a type the player never chose.
--- @param src number
--- @param matchId string
local function snapshot(src, matchId)
    local ox = inventory()
    if not ox then return end

    local held = {}
    for item in pairs(Arena.AllAmmoItems()) do
        local count = countOf(ox, src, item)
        -- An unreadable count is left out entirely. Restore skips whatever is
        -- absent here, which is the safe direction: no change beats a wrong one.
        if count then held[item] = count end
    end

    baseline[src] = held
    snapshotMatch[src] = matchId
end

-- ======================================================================
-- ISSUING
-- ======================================================================

--- Snapshots the player, then gives them the ammunition their loadout calls
--- for.
---
--- Returns the weapon keys whose ammo could NOT be handed over -- a full
--- inventory, an item name that does not exist. The caller decides what that
--- means: Config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem says whether a
--- player fights with an empty gun or is refused the round.
--- @param src number
--- @param matchId string
--- @param loadout table -- Arena.ResolveLoadout output
--- @return string[] failed -- weapon keys whose ammo item did not land
function ArenaAmmo.Issue(src, matchId, loadout)
    local failed = {}
    if not ArenaAmmo.IsEnabled() then return failed end
    if type(src) ~= 'number' or src <= 0 or not Arena.IsKey(matchId) then return failed end
    if type(loadout) ~= 'table' then return failed end

    local ox = inventory()
    if not ox then
        ArenaLog('ammo items are switched on but ox_inventory is not started -- nobody is being given any.')
        return failed
    end

    -- BEFORE a single item is handed over. A snapshot taken afterwards would
    -- bake the arena's own ammunition into what the player "arrived with".
    snapshot(src, matchId)

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
                ArenaDebug('ammo: gave %s x%d to %s on match %s', item, count, tostring(src), tostring(matchId))
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
-- RESTORING
-- ======================================================================

--- Puts a player's ammunition back exactly as it was before the arena.
---
--- Walks every item in their snapshot and moves it to the recorded number:
--- what they gained inside -- issued, looted off a body, picked up -- is
--- taken, and what they spent of their own is handed back. A player who never
--- entered, or whose snapshot could not be read, is left alone entirely.
---
--- Safe to call twice: the snapshot is dropped on the first call, so a second
--- finds nothing to reconcile and touches nothing.
--- @param src number
--- @param reasonKey string? -- audit reason, recorded in any console line
--- @return integer moved -- items added or removed to get back to the baseline
function ArenaAmmo.Reclaim(src, reasonKey)
    if type(src) ~= 'number' or src <= 0 then return 0 end

    local held = baseline[src]
    baseline[src] = nil
    snapshotMatch[src] = nil
    if not held then return 0 end

    if (Config.Loadouts.ammoItems or {}).reclaimOnExit == false then return 0 end

    local ox = inventory()
    if not ox then
        ArenaLog('ammo: ox_inventory is gone, so %s keeps whatever the arena gave them (%s).',
            tostring(src), tostring(reasonKey))
        return 0
    end

    local moved = 0
    for item, want in pairs(held) do
        local now = countOf(ox, src, item)

        if now and now > want then
            local surplus = now - want
            -- Everything above the line: what we issued, plus anything taken
            -- off a body. Neither is theirs to keep.
            local ok, removed = pcall(function() return ox:RemoveItem(src, item, surplus) end)
            if ok and removed ~= false then
                moved = moved + surplus
            else
                ArenaLog('ammo: %s left the arena with %d more %s than they arrived with, and it could not be taken back (%s).',
                    tostring(src), surplus, item, tostring(reasonKey))
            end
        elseif now and now < want then
            -- They spent their own. The arena is not allowed to cost them
            -- anything, so it goes back.
            local shortfall = want - now
            local ok, added = pcall(function() return ox:AddItem(src, item, shortfall) end)
            if ok and added ~= false then
                moved = moved + shortfall
            else
                ArenaLog('ammo: %s is owed %d %s they had before the match and it could not be returned (%s).',
                    tostring(src), shortfall, item, tostring(reasonKey))
            end
        end
    end

    if moved > 0 then
        ArenaDebug('ammo: reconciled %d item(s) for %s (%s)', moved, tostring(src), tostring(reasonKey))
    end
    return moved
end

--- Every player a match still holds a snapshot for. Used on the paths that end
--- a whole match at once rather than one player at a time.
--- @param matchId string
--- @param reasonKey string?
--- @return integer players
function ArenaAmmo.ReclaimAll(matchId, reasonKey)
    if not Arena.IsKey(matchId) then return 0 end

    -- Collected first: Reclaim mutates these tables as it goes, and walking one
    -- while removing from it is how an entry gets skipped.
    local sources = {}
    for src, id in pairs(snapshotMatch) do
        if id == matchId then sources[#sources + 1] = src end
    end

    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, reasonKey)
    end

    issued[matchId] = nil
    return #sources
end

--- Drops a match's record. REFUSES while any player of that match still has an
--- unreconciled snapshot, the same way ArenaBetting.Clear refuses while escrow
--- is held: a record dropped early is ammunition nobody will ever square up.
--- @param matchId string
--- @return boolean cleared
function ArenaAmmo.Clear(matchId)
    if not Arena.IsKey(matchId) then return false end

    for src, id in pairs(snapshotMatch) do
        if id == matchId then
            ArenaLog('ammo: refusing to drop match %s -- %s has not been squared up yet. Reclaim before clearing.',
                tostring(matchId), tostring(src))
            return false
        end
    end

    issued[matchId] = nil
    return true
end

--- Whether this player still has an arena snapshot waiting to be reconciled.
--- @param src number
--- @return boolean
function ArenaAmmo.IsHolding(src)
    return baseline[src] ~= nil
end

--- How many items a match has handed out, for the console.
--- @param matchId string
--- @return integer
function ArenaAmmo.IssuedTo(matchId, src)
    local match = issued[matchId]
    return match and match[src] or 0
end

-- A restart mid-match would otherwise leave every player in every arena
-- holding whatever the round gave them. This is the last chance to square
-- everyone up, so it runs before anything else tears down.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    -- Driven off the snapshots rather than the issued log: a player who was
    -- snapshotted but given nothing still has an inventory to put back.
    local sources = {}
    for src in pairs(baseline) do sources[#sources + 1] = src end
    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, 'resource stopping')
    end
end)
