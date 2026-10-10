-- A fighter walks in carrying a STOLEN pistol -- somebody else's serial, and
-- a flag saying so. It must come back out of the arena unchanged, and the
-- arena must never confiscate it to settle a record of its own.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

local STOLEN = { serial = 'VICTIM-9931', stolen = true, owner = 'CID_VICTIM',
                 registered = 'Los Santos PD', components = { 'clip_ext' }, tint = 3 }

local function run(arenaRecordHasSerial)
    local pockets, stash, threads, lines = {}, {}, {}, {}
    local seq = 0

    _ENV.CreateThread = function(fn) threads[#threads + 1] = fn end
    _ENV.SetTimeout = function() end
    _ENV.Wait = function() error('yield', 0) end
    _ENV.AddEventHandler = function() end
    _ENV.GetCurrentResourceName = function() return 'crimson_arena' end
    _ENV.GetPlayers = function() return { '1' } end
    _ENV.GetResourceState = function(n) return n == 'ox_inventory' and 'started' or 'missing' end

    local function slotsOf(t)
        local out = {}
        for i, it in ipairs(t) do out[#out + 1] = { name = it.name, count = it.count or 1,
                                                    slot = i, metadata = it.metadata } end
        return out
    end

    _ENV.exports = setmetatable({}, { __index = function()
        return {
            GetInventoryItems = function(_, who)
                -- the inventory is unreadable at the instant of issue, so the
                -- arena cannot read back the serial of the gun it just gave
                return slotsOf(who == 1 and pockets or stash)
            end,
            GetItemCount = function(_, who, name)
                local n = 0
                for _, it in ipairs(who == 1 and pockets or stash) do
                    if it.name == name then n = n + (it.count or 1) end
                end
                return n
            end,
            AddItem = function(_, who, name, count, meta)
                local into = (who == 1) and pockets or stash
                if name:find('^WEAPON_') and meta == nil and not _ENV.__noSerials then
                    seq = seq + 1
                    meta = { serial = 'ARENA-' .. seq }
                end
                into[#into + 1] = { name = name, count = count or 1, metadata = meta }
                return true
            end,
            RemoveItem = function(_, who, name, count, meta, slot)
                local from = (who == 1) and pockets or stash
                for i, it in ipairs(from) do
                    if it.name == name and (slot == nil or i == slot) then
                        table.remove(from, i) return true
                    end
                end
                return false
            end,
            ClearInventory = function(_, who) if who == 1 then pockets = {} end return true end,
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
        return { PlayerData = { citizenid = 'CID_FIGHTER' } }
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
            inventory = { stripOnEntry = arenaRecordHasSerial, blockDropsInArena = true,
                          returnRetrySeconds = 30, stashPrefix = 'crimson_arena_' },
            ammoItems = { enabled = false }, slots = 4,
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

    -- they turn up carrying the stolen gun
    pockets[#pockets + 1] = { name = 'WEAPON_PISTOL', count = 1, metadata = STOLEN }

    _ENV.__noSerials = not arenaRecordHasSerial
    ArenaAmmo.Issue(1, 'm1', { weapons = { { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 12 } },
                               supplies = {} })
    _ENV.__noSerials = false

    if not arenaRecordHasSerial then
        -- the arena's own copy is destroyed on death, so the only pistol left
        -- in those pockets is the stolen one
        for i = #pockets, 1, -1 do
            local m = pockets[i].metadata
            if pockets[i].name == 'WEAPON_PISTOL' and not (m and m.stolen) then
                table.remove(pockets, i)
            end
        end
    end

    ArenaAmmo.Reclaim(1, 'left')

    -- what did they walk out with?
    local held, meta = 0, nil
    for _, it in ipairs(pockets) do
        if it.name == 'WEAPON_PISTOL' then held = held + 1; meta = meta or it.metadata end
    end
    for _, it in ipairs(stash) do
        if it.name == 'WEAPON_PISTOL' then held = held + 1; meta = meta or it.metadata end
    end
    return held, meta, lines
end

for _, c in ipairs({ { 'the arena knows its own serial   ', true },
                     { 'arena record has NO serial, its  ', false } }) do
local held, meta, lines = run(c[2])
print(('\n== %s =='):format(c[1]))
print(('pistols the fighter ends up with: %d'):format(held))
print(('serial   : %s'):format(tostring(meta and meta.serial)))
print(('stolen   : %s'):format(tostring(meta and meta.stolen)))
print(('owner    : %s'):format(tostring(meta and meta.owner)))
print(('registered: %s'):format(tostring(meta and meta.registered)))
print(('components: %s'):format(tostring(meta and meta.components and meta.components[1])))
print(('tint      : %s'):format(tostring(meta and meta.tint)))
for _, l in ipairs(lines) do if l:find('serial') then print('  | ' .. l) end end
end
