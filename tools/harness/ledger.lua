-- Drives the owed-kit ledger end to end through the public surface,
-- once with the database off and once with it on.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

-- rows the fake database keeps between runs, so a "restart" can read back
-- what the last process left behind
local persisted = {}

local function run(dbEnabled, readOnlyUser, crash, startFrom)
    local queries, log = {}, {}
    local inv, serialSeq = {}, 0          -- src -> { {name=, slot=, metadata={serial=}} }
    local liveCitizen = 'CID_ONE'
    local threads = {}

    _ENV.CreateThread = function(fn) threads[#threads + 1] = fn end
    _ENV.SetTimeout = function(_, fn) threads[#threads + 1] = fn end
    _ENV.Wait = function() error('yield', 0) end
    _ENV.AddEventHandler = function() end
    _ENV.GetCurrentResourceName = function() return 'crimson_arena' end
    _ENV.GetPlayers = function() return { '1' } end
    _ENV.GetResourceState = function(n)
        if n == 'oxmysql' or n == 'ox_inventory' then return 'started' end
        return 'missing'
    end

    _ENV.exports = setmetatable({}, { __index = function(_, r)
        if r == 'oxmysql' then
            return { query = function(_, sql, _, cb)
                queries[#queries + 1] = sql:gsub('%s+', ' '):sub(1, 60)
                -- a least-privilege user: the table reads, nothing writes
                -- `x and nil or y` ALWAYS yields y in Lua; spell it out
                local isRead = (sql:find('SELECT') or sql:find('CREATE')) ~= nil
                if not cb then return end
                if readOnlyUser and not isRead then cb(nil) else cb({}) end
            end }
        end
        return {
            GetInventoryItems = function(_, src) return inv[src] or {} end,
            GetItemCount = function() return 0 end,
            AddItem = function(_, src, name)
                serialSeq = serialSeq + 1
                inv[src] = inv[src] or {}
                table.insert(inv[src], { name = name, slot = #inv[src] + 1,
                                         metadata = { serial = 'SER' .. serialSeq } })
                return true
            end,
            RemoveItem = function(_, src, name)
                for i, it in ipairs(inv[src] or {}) do
                    if it.name == name then table.remove(inv[src], i) return true end
                end
                return false
            end,
            ClearInventory = function(_, src) inv[src] = {} return true end,
            RegisterStash = function() return true end,
            registerHook = function() return 1 end,
        }
    end })

    _ENV.ArenaLog = function(f) log[#log + 1] = tostring(f) end
    _ENV.ArenaDebug = function() end
    _ENV.ArenaNotifyKey = function() end
    _ENV.ArenaToastKey = function() end
    _ENV.ArenaPlayerName = function(s) return 'P' .. tostring(s) end
    _ENV.ArenaGetPlayer = function(src)
        if src ~= 1 then return nil end
        return { PlayerData = { citizenid = liveCitizen } }
    end
    _ENV.ArenaDispatch, _ENV.ArenaLobby = {}, {}
    _ENV.Arena = {
        IsKey = function(v) return type(v) == 'string' and v ~= '' end,
        ToInt = function(v) return math.tointeger(tonumber(v) or 0) or 0 end,
        IsPoint = function(v) return v ~= nil end,
        IsMeleeWeapon = function() return false end,
        AllIssuedItems = function() return {} end,
        GetWeaponByKey = function(key)
            if key ~= 'pistol' then return nil end
            return { key = 'pistol', weapon = 'WEAPON_PISTOL', magazine = 12 }
        end,
        MagazineFor = function(catalogue, total)
            local mag = catalogue and catalogue.magazine or total
            return math.min(total, mag)
        end,
        ResolveWeaponEntry = function(entry) return entry end,
        KillAmmoFor = function() return nil, 0 end,
    }
    _ENV.Config = {
        Database = { enabled = dbEnabled, flushIntervalMs = 60000 },
        Loadouts = {
            inventory = { stripOnEntry = true, blockDropsInArena = true,
                          returnRetrySeconds = 30, stashPrefix = 'crimson_arena_' },
            ammoItems = { enabled = true, roundsPerItem = 1 },
            slots = 4,
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

    -- what main.lua does at resource start
    local loaded = ArenaAmmo.LoadOwedKit()
    local afterLoad = #queries

    -- one fighter is armed
    ArenaAmmo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 12 } },
                               supplies = {} })
    local armed = #(inv[1] or {})

    if crash then
        -- the process dies here. No exit runs, nothing is reclaimed.
        local snapshot = {}
        for k, v in pairs(persisted) do snapshot[k] = v end
        return { armed = armed, owed = 0, who = nil, loaded = loaded,
                 afterLoad = afterLoad, saved = false, queries = #queries,
                 sent = queries, left = snapshot }
    end

    -- they switch character mid-round: same server id, different person
    liveCitizen = 'CID_TWO'
    ArenaAmmo.Reclaim(1, 'left')

    local slate = ArenaAmmo.OwedKit()
    local owed, who = 0, nil
    for _, row in ipairs(slate) do
        owed = owed + #row.weapons
        who = row.citizenid
    end

    return {
        armed = armed, owed = owed, who = who, loaded = loaded, afterLoad = afterLoad,
        saved = ArenaAmmo.OwedKitIsSaved(), queries = #queries, sent = queries,
    }
end

-- the crash case: arm a fighter, kill the process, then start again
persisted = {}
local dead = run(true, false, true)
local rows = 0
for _ in pairs(dead.left) do rows = rows + 1 end
print(('crash mid-round: %d row(s) survived the process'):format(rows))
for _, q in ipairs(dead.sent) do print('   sent> ' .. q) end
for _, r in pairs(dead.left) do
    print(('   %s  kind=%s  %s  %s'):format(r.ledger_key, r.kind, r.name, tostring(r.serial)))
end

persisted = {}
local after = run(true, false, false, dead.left)
print(('next start: the arena reads back a debt of %d weapon(s), billed to %s')
    :format(after.owed, tostring(after.who)))
print()

for _, c in ipairs({ { 'database off              ', false, false },
                     { 'database on, full grants  ', true,  false },
                     { 'database on, SELECT only  ', true,  true  } }) do
    local r = run(c[2], c[3])
    print(('%s  LoadOwedKit=%-5s  debt recorded %d, billed to %s  OwedKitIsSaved=%-5s  queries=%d')
        :format(c[1], tostring(r.loaded), r.owed, tostring(r.who), tostring(r.saved), r.queries))
    for _, q in ipairs(r.sent or {}) do print('      > ' .. q) end
end
