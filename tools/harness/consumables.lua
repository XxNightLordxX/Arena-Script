-- Proves the consumables half of the ledger records a debt when the player
-- logs out mid-round, which the old `citizenid ~= liveId` guard refused.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

local function run(logsOutAtExit, stranger, doorOff)
    local loggedOut = false
    local counts, weapons, serialSeq = {}, {}, 0
    local liveCitizen = 'CID_ONE'
    local threads, lines = {}, {}

    _ENV.CreateThread = function(fn) threads[#threads + 1] = fn end
    _ENV.SetTimeout = function(_, fn) end
    _ENV.Wait = function() error('yield', 0) end
    _ENV.AddEventHandler = function() end
    _ENV.GetCurrentResourceName = function() return 'crimson_arena' end
    _ENV.GetPlayers = function() return {} end
    _ENV.GetResourceState = function(n) return n == 'ox_inventory' and 'started' or 'missing' end

    local stash = {}
    _ENV.exports = setmetatable({}, { __index = function()
        return {
            GetInventoryItems = function(_, who)
                if who == 1 then
                    local out = {}
                    for _, w in ipairs(weapons) do out[#out + 1] = w end
                    for n, c in pairs(counts) do out[#out + 1] = { name = n, count = c, slot = 90 } end
                    return out
                end
                return stash
            end,
            GetItemCount = function(_, _, name) return counts[name] or 0 end,
            AddItem = function(_, who, name, count, meta)
                if who ~= 1 then stash[#stash + 1] = { name = name, count = count } return true end
                if name:find('^WEAPON_') then
                    serialSeq = serialSeq + 1
                    weapons[#weapons + 1] = { name = name, slot = #weapons + 1, count = 1,
                                              metadata = { serial = 'SER' .. serialSeq } }
                else
                    counts[name] = (counts[name] or 0) + (count or 1)
                end
                return true
            end,
            RemoveItem = function(_, _, name, count)
                if counts[name] then counts[name] = math.max(0, counts[name] - (count or 1)) end
                return true
            end,
            -- the character-select case: the inventory is gone, so the clear
            -- answers nil, which the resource must NOT read as success
            ClearInventory = function() if loggedOut then return nil end
                counts, weapons = {}, {} return true end,
            RegisterStash = function() return true end,
            registerHook = function() return 1 end,
        }
    end })

    _ENV.ArenaLog = function(f, ...) lines[#lines + 1] = (select('#', ...) > 0)
        and tostring(f):format(...) or tostring(f) end
    _ENV.ArenaDebug = function() end
    _ENV.ArenaNotifyKey, _ENV.ArenaToastKey = function() end, function() end
    _ENV.ArenaPlayerName = function(s) return 'P' .. tostring(s) end
    _ENV.ArenaGetPlayer = function(src)
        if loggedOut or src ~= 1 then return nil end
        return { PlayerData = { citizenid = liveCitizen } }
    end
    _ENV.ArenaDispatch, _ENV.ArenaLobby = {}, {}
    _ENV.Arena = {
        IsKey = function(v) return type(v) == 'string' and v ~= '' end,
        ToInt = function(v) return math.tointeger(tonumber(v) or 0) or 0 end,
        IsPoint = function(v) return v ~= nil end,
        IsMeleeWeapon = function() return false end,
        AllIssuedItems = function() return {} end,
        GetWeaponByKey = function() return nil end,
        MagazineFor = function(_, t) return t end,
        ResolveWeaponEntry = function(e) return e end,
        KillAmmoFor = function() return nil, 0 end,
    }
    _ENV.Config = {
        Database = { enabled = false },
        Loadouts = {
            inventory = { stripOnEntry = not doorOff, blockDropsInArena = true,
                          returnRetrySeconds = 30, stashPrefix = 'crimson_arena_' },
            ammoItems = { enabled = true, roundsPerItem = 1 }, slots = 4,
        },
        Modes = {},
    }
    _ENV.ArenaAmmo = nil
    -- the real database gate now lives in util.lua, so load it rather than
    -- stub it: the whole point is to prove the SHIPPED gate stays shut
    local keep = {}
    for _, n in ipairs({ 'ArenaLog', 'ArenaDebug', 'ArenaGetPlayer', 'ArenaPlayerName',
                         'ArenaNotifyKey', 'ArenaToastKey' }) do keep[n] = _ENV[n] end
    assert(loadfile(ROOT .. 'server/util.lua'))()
    for n, fn in pairs(keep) do _ENV[n] = fn end
    assert(loadfile(ROOT .. 'server/ammo.lua'))()
    for _, fn in ipairs(threads) do pcall(fn) end

    ArenaAmmo.Issue(1, 'm1', { weapons = {}, supplies = { { item = 'armour', count = 2 }, { item = 'bandage', count = 3 } } })
    local issued = (counts.armour or 0) .. '+' .. (counts.bandage or 0)

    -- they walk out. Either normally, or straight to character select --
    -- which is the case the ledger exists for: nobody answers to the server
    -- id, but ox_inventory still has the departing character's stock loaded.
    loggedOut = logsOutAtExit

    if stranger then
        -- somebody else takes the server id, carrying their OWN supplies
        liveCitizen = 'CID_TWO'
        counts.armour, counts.bandage = 9, 9
    end

    ArenaAmmo.Reclaim(1, 'left')

    local owing = 0
    for _, row in ipairs(ArenaAmmo.OwedKit()) do
        for _, st in ipairs(row.items or {}) do owing = owing + st.amount end
    end
    return issued, owing, lines, (counts.armour or 0) .. '+' .. (counts.bandage or 0)
end

local cases = {
    { 'ordinary exit                 ', false, false },
    { 'logs out to character select  ', true,  false },
    { 'server id inherited by another', false, true  },
    { 'inherited, door OFF (no stash)', false, true, true },
}
for _, c in ipairs(cases) do
    local issued, owing, lines, left = run(c[2], c[3], c[4])
    print(('%s  issued %s  ledger records %d  pockets left holding %s')
        :format(c[1], issued, owing, left))
end
