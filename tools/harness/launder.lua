-- A debtor walks in owing 10 bandages, carrying none, and is issued 10.
-- The sweep must NOT settle the old debt out of the arena's fresh issue.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

local function run(inMatch)
    local counts, threads, lines = {}, {}, {}
    local stash = {}

    _ENV.CreateThread = function(fn) threads[#threads + 1] = fn end
    _ENV.SetTimeout = function() end
    _ENV.Wait = function() error('yield', 0) end
    _ENV.AddEventHandler = function() end
    _ENV.GetCurrentResourceName = function() return 'crimson_arena' end
    _ENV.GetPlayers = function() return { '1' } end
    _ENV.GetResourceState = function(n) return n == 'ox_inventory' and 'started' or 'missing' end

    _ENV.exports = setmetatable({}, { __index = function()
        return {
            GetInventoryItems = function(_, who)
                if who ~= 1 then return stash end
                local out = {}
                for n, c in pairs(counts) do out[#out + 1] = { name = n, count = c, slot = 90 } end
                return out
            end,
            GetItemCount = function(_, _, name) return counts[name] or 0 end,
            AddItem = function(_, who, name, count)
                if who ~= 1 then stash[#stash + 1] = { name = name, count = count } return true end
                counts[name] = (counts[name] or 0) + (count or 1)
                return true
            end,
            RemoveItem = function(_, who, name, count)
                if who == 1 and counts[name] then
                    counts[name] = math.max(0, counts[name] - (count or 1))
                end
                return true
            end,
            -- at character select the inventory is not loaded, so the clear
            -- answers nil and the arena's supplies stay with the character
            ClearInventory = function()
                if _ENV.__goneToCharacterSelect then return nil end
                counts = {} return true
            end,
            RegisterStash = function() return true end,
            registerHook = function() return 1 end,
        }
    end })

    _ENV.ArenaLog = function(f, ...) lines[#lines + 1] = (select('#', ...) > 0)
        and tostring(f):format(...) or tostring(f) end
    _ENV.ArenaDebug, _ENV.ArenaNotifyKey, _ENV.ArenaToastKey = function() end, function() end, function() end
    _ENV.ArenaPlayerName = function(s) return 'P' .. tostring(s) end
    _ENV.ArenaGetPlayer = function(src)
        if src ~= 1 then return nil end
        return { PlayerData = { citizenid = 'CID_DEBTOR' } }
    end
    -- whether the arena says this player is currently in a round
    _ENV.ArenaDispatch = { IsPlayerInArena = function() return inMatch end }
    _ENV.ArenaLobby = {}
    _ENV.Arena = {
        IsKey = function(v) return type(v) == 'string' and v ~= '' end,
        ToInt = function(v) return math.tointeger(tonumber(v) or 0) or 0 end,
        IsPoint = function(v) return v ~= nil end,
        IsMeleeWeapon = function() return false end,
        AllIssuedItems = function() return { bandage = true } end,
        GetWeaponByKey = function() return nil end,
        MagazineFor = function(_, t) return t end,
        ResolveWeaponEntry = function(e) return e end,
        KillAmmoFor = function() return nil, 0 end,
    }
    _ENV.Config = {
        Database = { enabled = false },
        Loadouts = {
            inventory = { stripOnEntry = true, blockDropsInArena = true,
                          returnRetrySeconds = 30, stashPrefix = 'crimson_arena_' },
            ammoItems = { enabled = true, roundsPerItem = 1 }, slots = 4,
        },
        Modes = {},
    }
    _ENV.ArenaAmmo = nil

    local keep = {}
    for _, n in ipairs({ 'ArenaLog', 'ArenaDebug', 'ArenaGetPlayer', 'ArenaPlayerName',
                         'ArenaNotifyKey', 'ArenaToastKey' }) do keep[n] = _ENV[n] end
    assert(loadfile(ROOT .. 'server/util.lua'))()
    for n, fn in pairs(keep) do _ENV[n] = fn end
    assert(loadfile(ROOT .. 'server/ammo.lua'))()
    for _, fn in ipairs(threads) do pcall(fn) end

    -- LAST WEEK: they were issued 10 bandages and walked out with the lot
    ArenaAmmo.Issue(1, 'old', { weapons = {}, supplies = { { item = 'bandage', count = 10 } } })
    _ENV.__goneToCharacterSelect = true
    _ENV.ArenaGetPlayer = function() return nil end        -- they log out
    ArenaAmmo.Reclaim(1, 'left')
    _ENV.__goneToCharacterSelect = false
    _ENV.ArenaGetPlayer = function(src)
        if src ~= 1 then return nil end
        return { PlayerData = { citizenid = 'CID_DEBTOR' } }
    end

    local owedBefore = 0
    for _, r in ipairs(ArenaAmmo.OwedKit()) do
        for _, st in ipairs(r.items or {}) do owedBefore = owedBefore + st.amount end
    end

    -- TODAY: they turn up carrying none of it and take a fresh loadout
    counts = {}
    ArenaAmmo.Issue(1, 'new', { weapons = {}, supplies = { { item = 'bandage', count = 10 } } })
    local afterIssue = counts.bandage or 0

    -- and the sweep runs while they are in the round
    ArenaAmmo.SweepReturns()

    local owedAfter = 0
    for _, r in ipairs(ArenaAmmo.OwedKit()) do
        for _, st in ipairs(r.items or {}) do owedAfter = owedAfter + st.amount end
    end

    return owedBefore, afterIssue, counts.bandage or 0, owedAfter
end

for _, c in ipairs({ { 'sweep runs while they are IN the round', true },
                     { 'sweep runs after they have left     ', false } }) do
    local before, issued, left, after = run(c[2])
    print(('%s  owed %d -> issued %d -> holding %d, still owed %d')
        :format(c[1], before, issued, left, after))
end
