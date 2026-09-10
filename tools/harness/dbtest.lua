-- Loads server/ammo.lua for real, with Config.Database.enabled = false,
-- and exercises every path that would touch a database.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

local log = {}
local queries = {}

-- ---- FiveM surface -------------------------------------------------
local threads = {}
function CreateThread(fn) threads[#threads + 1] = fn end
function SetTimeout(_, fn) threads[#threads + 1] = fn end
function Wait(_) error('a harness thread yielded', 0) end
function AddEventHandler() end
function GetCurrentResourceName() return 'crimson_arena' end
function GetPlayers() return { '1' } end

-- oxmysql is RUNNING. That is the sharp case: the switch, not the
-- resource's absence, must be what stops every query.
function GetResourceState(name)
    if name == 'oxmysql' then return 'started' end
    if name == 'ox_inventory' then return 'started' end
    return 'missing'
end

exports = setmetatable({}, { __index = function(_, resource)
    if resource == 'oxmysql' then
        return { query = function(_, sql, params, cb)
            queries[#queries + 1] = sql
            if cb then cb({}) end
        end }
    end
    if resource == 'ox_inventory' then
        return {
            GetInventoryItems = function() return {} end,
            GetItemCount = function() return 0 end,
            AddItem = function() return true end,
            RemoveItem = function() return true end,
            ClearInventory = function() return true end,
            RegisterStash = function() return true end,
            registerHook = function() return 1 end,
        }
    end
    return {}
end })

-- ---- resource surface ----------------------------------------------
function ArenaLog(fmt, ...) log[#log + 1] = tostring(fmt) end
function ArenaDebug() end
function ArenaNotifyKey() end
function ArenaToastKey() end
function ArenaPlayerName(s) return 'Player ' .. tostring(s) end
function ArenaGetPlayer(src)
    if src ~= 1 then return nil end
    return { PlayerData = { citizenid = 'CID_ONE' } }
end
ArenaDispatch = {}
ArenaLobby = {}

Arena = {
    IsKey = function(v) return type(v) == 'string' and v ~= '' end,
    ToInt = function(v) return math.tointeger(tonumber(v) or 0) or 0 end,
    IsPoint = function(v) return v ~= nil end,
    IsMeleeWeapon = function() return false end,
    AllIssuedItems = function() return {} end,
    BuildLoadout = function() return { weapons = {}, supplies = {} } end,
    KillAmmoFor = function() return 0 end,
}

Config = {
    Database = { enabled = false, flushIntervalMs = 60000, leaderboardSize = 25 },
    Loadouts = {
        inventory = { stripOnEntry = true, blockDropsInArena = true,
                      returnRetrySeconds = 30, stashPrefix = 'crimson_arena_' },
        ammoItems = { enabled = true, roundsPerItem = 1 },
        slots = 4,
    },
    Modes = {},
}

-- ---- load the real module ------------------------------------------
-- the real database gate now lives in util.lua, so load it rather than stub
-- it: the whole point is to prove the SHIPPED gate stays shut
local keep = {}
for _, n in ipairs({ 'ArenaLog', 'ArenaDebug', 'ArenaGetPlayer', 'ArenaPlayerName',
                     'ArenaNotifyKey', 'ArenaToastKey' }) do keep[n] = _ENV[n] end
assert(loadfile(ROOT .. 'server/util.lua'))()
for n, fn in pairs(keep) do _ENV[n] = fn end

local chunk = assert(loadfile(ROOT .. 'server/ammo.lua'))
chunk()

print('loaded server/ammo.lua with Config.Database.enabled = false')

-- Run every thread body the module registered, once, catching the
-- deliberate yield so we see how far each got.
for _, fn in ipairs(threads) do pcall(fn) end

-- ---- exercise every database-touching entry point -------------------
local checks = {
    { 'LoadOwedKit',       function() return ArenaAmmo.LoadOwedKit() end },
    { 'OwedKitIsSaved',    function() return ArenaAmmo.OwedKitIsSaved() end },
    { 'OwedKit',           function() return #ArenaAmmo.OwedKit() end },
    { 'Owed',              function() return ArenaAmmo.Owed() end },
    { 'SweepReturns',      function() return ArenaAmmo.SweepReturns() end },
    { 'Reclaim',           function() return ArenaAmmo.Reclaim(1, 'test') end },
    { 'Clear',             function() return ArenaAmmo.Clear('m1') end },
    { 'Issue',             function() return #ArenaAmmo.Issue(1, 'm1', { weapons = {}, supplies = {} }) end },
}

local failures = 0
for _, c in ipairs(checks) do
    local ok, err = pcall(c[2])
    if ok then
        print(('  ok    %-16s -> %s'):format(c[1], tostring(err)))
    else
        failures = failures + 1
        print(('  THREW %-16s -> %s'):format(c[1], tostring(err)))
    end
end

print()
print('SQL statements sent with the database off: ' .. #queries)
for _, q in ipairs(queries) do print('  ' .. q:gsub('%s+', ' '):sub(1, 90)) end

print()
print(failures == 0 and 'NOTHING THREW' or (failures .. ' ENTRY POINT(S) THREW'))
print(#queries == 0 and 'NO QUERY WAS SENT' or 'A QUERY WAS SENT WITH THE SWITCH OFF')
