--[[
    crimson_arena/server/ammo.lua

    Handing out ammunition items, and getting every one of them back.

    On a server where ammo types are inventory items, an arena that gives them
    out is an ammo printer unless it also takes them back: join, take two
    hundred armour-piercing rounds, walk out, repeat. So this file is written
    with the same discipline as server/betting.lua's escrow, for the same
    reason -- it is handing a player something with real value, on loan.

    THE RULE: everything issued is recorded against the player and the match
    that issued it, and removed on every exit path there is -- finishing,
    leaving, being eliminated, disconnecting, an admin stop, a resource
    restart. A round the player already fired is gone and cannot be reclaimed;
    that is expected and is not an error. A round that is still in their
    pocket and cannot be removed IS an error, and it is named in the console
    rather than written off quietly.

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

--- [matchId] = { [src] = { { item, count, reclaimed } } }
--- @type table<string, table<number, table[]>>
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
-- ISSUING
-- ======================================================================

--- Gives a player the ammunition items their loadout calls for and records
--- every one against this match.
---
--- Returns the weapon keys whose ammo could NOT be handed over -- a full
--- inventory, an item name that does not exist. The caller decides what that
--- means: Config.Loadouts.ammoItems.allowWeaponWithoutAmmoItem says whether
--- a player fights with an empty gun or is refused the round.
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

    issued[matchId] = issued[matchId] or {}
    local ledger = issued[matchId][src] or {}
    issued[matchId][src] = ledger

    for _, entry in ipairs(loadout.weapons or {}) do
        local item = entry.ammoTypeItem
        local count = itemsFor(entry.ammo)

        if Arena.IsKey(item) and count > 0 then
            -- BOTH have to be true. pcall succeeding only means the call did
            -- not throw; ox_inventory returns false for a full inventory or an
            -- item name that does not exist, and recording one of those would
            -- have Reclaim later take an item this player was never given.
            local ok, granted = pcall(function() return ox:AddItem(src, item, count) end)
            if ok and granted ~= false then
                -- Recorded BEFORE anything else can go wrong. An item given
                -- and not recorded is an item nothing will ever take back.
                ledger[#ledger + 1] = { item = item, count = count, reclaimed = false }
                ArenaDebug('ammo: gave %s x%d to %s on match %s', item, count, tostring(src), tostring(matchId))
            else
                failed[#failed + 1] = entry.key or entry.weapon
                ArenaLog('ammo: could not give %s x%d to %s -- check that item exists on this server.',
                    item, count, tostring(src))
            end
        end
    end

    return failed
end

-- ======================================================================
-- RECLAIMING
-- ======================================================================

--- Takes back everything this resource issued to one player, across every
--- match. Safe to call for somebody who was never issued anything, and safe
--- to call twice -- each record is marked as it is returned, so a second call
--- takes nothing a second time.
---
--- A round the player has already FIRED cannot be removed and is not an
--- error: they were given it to shoot. What is worth knowing about is an item
--- still in their pocket that will not come out, so a partial removal is
--- logged and a total failure is logged louder.
--- @param src number
--- @param reasonKey string? -- audit reason, recorded in the console line
--- @return integer reclaimed -- items actually taken back
function ArenaAmmo.Reclaim(src, reasonKey)
    if type(src) ~= 'number' or src <= 0 then return 0 end
    if (Config.Loadouts.ammoItems or {}).reclaimOnExit == false then return 0 end

    local ox = inventory()
    local taken, owed = 0, 0

    for matchId, players in pairs(issued) do
        local ledger = players[src]
        if ledger then
            for _, record in ipairs(ledger) do
                if not record.reclaimed then
                    record.reclaimed = true
                    owed = owed + record.count

                    if ox then
                        -- Same reasoning as Issue, in the other direction: a
                        -- RemoveItem that returns false took nothing, and
                        -- counting it as reclaimed would report a clean
                        -- teardown over ammunition still in somebody's pocket.
                        local ok, removed = pcall(function() return ox:RemoveItem(src, record.item, record.count) end)
                        if ok and removed ~= false then
                            taken = taken + record.count
                        else
                            ArenaLog('ammo: %s x%d issued to %s on match %s could not be taken back (%s). They fired it, dropped it, or are already gone.',
                                record.item, record.count, tostring(src), tostring(matchId), tostring(reasonKey))
                        end
                    end
                end
            end
            players[src] = nil
        end
    end

    if owed > 0 then
        ArenaDebug('ammo: reclaimed %d of %d item(s) from %s', taken, owed, tostring(src))
    end
    return taken
end

--- Every player a match still holds ammunition for. Used on the paths that
--- end a whole match at once rather than one player at a time.
--- @param matchId string
--- @param reasonKey string?
--- @return integer players
function ArenaAmmo.ReclaimAll(matchId, reasonKey)
    if not Arena.IsKey(matchId) then return 0 end

    local players = issued[matchId]
    if not players then return 0 end

    local count = 0
    -- Collected first: Reclaim mutates this table as it goes, and walking a
    -- table while removing from it is how an entry gets skipped.
    local sources = {}
    for src in pairs(players) do sources[#sources + 1] = src end

    for _, src in ipairs(sources) do
        ArenaAmmo.Reclaim(src, reasonKey)
        count = count + 1
    end

    issued[matchId] = nil
    return count
end

--- Drops a match's record. REFUSES while anything is still on loan, the same
--- way ArenaBetting.Clear refuses while escrow is held -- a record dropped
--- with items outstanding is ammunition nothing will ever ask for back.
--- @param matchId string
--- @return boolean cleared
function ArenaAmmo.Clear(matchId)
    if not Arena.IsKey(matchId) then return false end

    local players = issued[matchId]
    if not players then return true end

    for src, ledger in pairs(players) do
        for _, record in ipairs(ledger) do
            if not record.reclaimed then
                ArenaLog('ammo: refusing to drop match %s -- %s still holds %s x%d. Reclaim before clearing.',
                    tostring(matchId), tostring(src), record.item, record.count)
                return false
            end
        end
    end

    issued[matchId] = nil
    return true
end

--- What one player is currently holding on loan, for diagnostics.
--- @param src number
--- @return integer
function ArenaAmmo.OnLoan(src)
    local total = 0
    for _, players in pairs(issued) do
        for holder, ledger in pairs(players) do
            if holder == src then
                for _, record in ipairs(ledger) do
                    if not record.reclaimed then total = total + record.count end
                end
            end
        end
    end
    return total
end

-- A restart with ammunition on loan would hand every player in every arena a
-- permanent supply. This is the last chance to take it back, so it runs
-- before anything else tears down.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for matchId in pairs(issued) do
        ArenaAmmo.ReclaimAll(matchId, 'resource stopping')
    end
end)
