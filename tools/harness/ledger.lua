-- Drives the owed-kit ledger end to end through the public surface,
-- once with the database off and once with it on.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

-- rows the fake database keeps between runs, so a "restart" can read back
-- what the last process left behind
local persisted = {}

--- One whole process: start, arm a fighter, then either die or shut down.
--- @param dbEnabled boolean
--- @param readOnlyUser boolean -- the table reads, nothing writes
--- @param crash boolean        -- kill the process mid-round, no exit
--- @param startFrom table?     -- rows a previous process left behind
--- @param sameCharacter boolean? -- do NOT switch character before the exit
local function run(dbEnabled, readOnlyUser, crash, startFrom, sameCharacter, hideWeapon)
    -- SEEDED, WHICH IT WAS NOT. `startFrom` was accepted and then never
    -- read, so the "next start" case began on an EMPTY table and the debt it
    -- reported was one it had just written itself. It passed, and it was
    -- proving nothing about a row surviving a crash -- the single thing this
    -- harness exists to demonstrate.
    persisted = {}
    for k, v in pairs(startFrom or {}) do persisted[k] = v end
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

    -- A TABLE THAT ACTUALLY KEEPS THINGS, which is the whole reason this
    -- harness exists and the half that was missing.
    --
    -- The old fake answered every statement with an empty result and stored
    -- nothing, so `persisted` was read and never written -- and the crash
    -- case it was built to demonstrate could not happen: no row was ever
    -- left behind for the next start to find. It reported success on a
    -- question it was not asking.
    --
    -- Not a SQL engine. It understands exactly the four shapes the ledger
    -- sends -- insert-or-update, delete, read-all, create -- keyed the way
    -- the real table is keyed, on (citizenid, ledger_key). That is enough to
    -- tell a row that survived a process from one that did not, and nothing
    -- here should grow past it.
    local function runSql(sql, params, cb)
        queries[#queries + 1] = sql:gsub('%s+', ' '):sub(1, 60)

        local isRead = (sql:find('SELECT') or sql:find('CREATE')) ~= nil

        -- A least-privilege user: the table reads, nothing writes. nil is
        -- how oxmysql reports a refusal, and `x and nil or y` ALWAYS yields
        -- y in Lua, so this is spelled out.
        if readOnlyUser and not isRead then
            if cb then cb(nil) end
            return
        end

        params = params or {}

        if sql:find('CREATE TABLE') then
            if cb then cb({}) end
            return
        end

        if sql:find('^%s*SELECT') then
            local rows = {}
            for _, row in pairs(persisted) do
                rows[#rows + 1] = {
                    citizenid = row.citizenid, ledger_key = row.ledger_key,
                    kind = row.kind, name = row.name,
                    serial = row.serial, amount = row.amount,
                }
            end
            if cb then cb(rows) end
            return
        end

        if sql:find('^%s*DELETE') then
            persisted[tostring(params[1]) .. '|' .. tostring(params[2])] = nil
            if cb then cb({ affectedRows = 1 }) end
            return
        end

        if sql:find('INSERT INTO crimson_arena_owed_kit') then
            -- Which kind this statement writes is a literal in the text, the
            -- way the real ones are. Read from there rather than guessed at,
            -- so a new statement with a new kind does not land as 'item'.
            local kind = sql:match("VALUES %([^)]-'(%a+)'") or 'item'
            local key = tostring(params[1]) .. '|' .. tostring(params[2])
            local existing = persisted[key]

            local row = {
                citizenid = params[1], ledger_key = params[2], kind = kind,
                name = params[3],
            }

            if kind == 'item' then
                row.serial = nil
                local amount = tonumber(params[4]) or 1
                -- The two item statements differ only in their ON DUPLICATE
                -- clause, and that difference is the point of having both.
                if existing and sql:find('amount %+ VALUES%(amount%)') then
                    amount = (tonumber(existing.amount) or 0) + amount
                end
                row.amount = amount
            else
                row.serial = params[4]
                row.amount = 1
            end

            persisted[key] = row
            if cb then cb({ affectedRows = 1 }) end
            return
        end

        if cb then cb({}) end
    end

    _ENV.exports = setmetatable({}, { __index = function(_, r)
        if r == 'oxmysql' then
            return { query = function(_, sql, params, cb) runSql(sql, params, cb) end }
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

    -- THE FIGHTER PUT IT SOMEWHERE THE ARENA CANNOT REACH. A house stash, a
    -- glovebox, a friend's hands -- from the door's seat the weapon is
    -- simply not in the pockets it is asking, and RemoveItem refuses.
    --
    -- That refusal is the entire reason the row is struck off on the RESULT
    -- and not on the attempt: this is the weapon the ledger exists for, and
    -- forgiving it here would forgive the only case that matters.
    if hideWeapon then inv[1] = {} end

    -- They switch character mid-round -- same server id, different person --
    -- unless the caller asked for a clean round, which is the case that
    -- answers "does a normal exit leave anything behind".
    if not sameCharacter then liveCitizen = 'CID_TWO' end
    ArenaAmmo.Reclaim(1, 'left')

    local slate = ArenaAmmo.OwedKit()
    local owed, who = 0, nil
    for _, row in ipairs(slate) do
        owed = owed + #row.weapons
        who = row.citizenid
    end

    local left, rows = {}, 0
    for k, v in pairs(persisted) do left[k] = v; rows = rows + 1 end

    return {
        armed = armed, owed = owed, who = who, loaded = loaded, afterLoad = afterLoad,
        saved = ArenaAmmo.OwedKitIsSaved(), queries = #queries, sent = queries,
        left = left, rowsLeft = rows,
    }
end

-- ======================================================================
-- WHAT THIS PROVES, and it is the half that was missing.
--
-- The crash-persistence change writes a row the moment a weapon is handed
-- over, so a process that dies mid-round leaves evidence. Three things have
-- to hold at once for that to be worth having, and only the first was ever
-- obvious:
--
--   1. A crash LEAVES a row.
--   2. The next start reads that row back as a real debt.
--   3. A CLEAN round leaves NOTHING -- otherwise an idle server slowly
--      fills the table with rows for weapons that came back, which is the
--      failure mode that matters most and the open question this was
--      parked on.
--
-- And all three have to behave with the database switched OFF, where the
-- whole feature must be silent rather than merely harmless.
-- ======================================================================

local failures = 0
local function check(ok, label, detail)
    if not ok then failures = failures + 1 end
    print(('  [%s] %s%s'):format(ok and 'PASS' or 'FAIL', label,
        detail and ('  -- ' .. detail) or ''))
end

print('THE CRASH, WITH THE DATABASE ON')
local dead = run(true, false, true)
local rows = 0
for _ in pairs(dead.left) do rows = rows + 1 end
check(rows == 1, 'a crash mid-round leaves exactly one row',
    ('%d row(s) survived'):format(rows))
local outRow
for _, r in pairs(dead.left) do outRow = r end
check(outRow ~= nil and outRow.kind == 'out',
    "the row says 'out', not 'weapon'",
    outRow and ('kind=' .. tostring(outRow.kind)) or 'no row at all')
check(outRow ~= nil and outRow.serial ~= nil,
    'it names the exact copy, by serial',
    outRow and tostring(outRow.serial) or '-')

print()
print('THE NEXT START, READING WHAT THE CRASH LEFT')
local after = run(true, false, false, dead.left, true)
check(after.owed >= 1, 'the surviving row comes back as a debt',
    ('%d weapon(s) owed, billed to %s'):format(after.owed, tostring(after.who)))
check(after.who == 'CID_ONE', 'billed to the character who was holding it',
    tostring(after.who))

print()
print('THE CLEAN ROUND -- THE ONE THAT WOULD FILL THE TABLE')
local clean = run(true, false, false, nil, true)
check(clean.rowsLeft == 0,
    'a weapon that came back leaves no row behind',
    ('%d row(s) left on the slate'):format(clean.rowsLeft))
check(clean.owed == 0, 'and nobody owes anything',
    ('%d owed'):format(clean.owed))

print()
print('THE SAME THREE, WITH THE DATABASE OFF')
local offCrash = run(false, false, true)
local offRows = 0
for _ in pairs(offCrash.left) do offRows = offRows + 1 end
check(offRows == 0, 'a crash writes nothing when there is no database',
    ('%d row(s)'):format(offRows))
check(offCrash.queries == 0, 'and not one statement went out',
    ('%d quer(ies)'):format(offCrash.queries))

local offClean = run(false, false, false, nil, true)
check(offClean.queries == 0, 'a clean round sends nothing either',
    ('%d quer(ies)'):format(offClean.queries))
check(offClean.armed > 0, 'and the fighter was still armed, which is the point',
    ('%d item(s) issued'):format(offClean.armed))
check(offClean.loaded == false, 'LoadOwedKit reports it did not run',
    tostring(offClean.loaded))

print()
print('THE WEAPON THAT DID NOT COME BACK')
-- The fighter stepped out of the character mid-round AND the weapon is no
-- longer in the pockets the door is asking, so the removal is refused. This
-- is the copy the whole ledger exists for: it must be written down as a
-- debt and it must keep a row naming the exact serial.
--
-- NOTE ON THE SAME-CHARACTER CASE, which is NOT tested here on purpose.
-- server/ammo.lua states its contract in as many words: if the character
-- the kit was issued to is standing there when the exit runs, the clear
-- reached a real inventory and settled it. Nothing is owed, by design, and
-- that was as true before this change as after -- there simply were no rows
-- at all then. A check demanding a row there would be this harness
-- inventing a promise the resource does not make.
local kept = run(true, false, false, nil, false, true)
check(kept.owed >= 1,
    'a weapon the door could not take back is written down as a debt',
    ('%d owed, billed to %s'):format(kept.owed, tostring(kept.who)))
check(kept.rowsLeft >= 1,
    'and it keeps a row on the slate',
    ('%d row(s)'):format(kept.rowsLeft))

local keptRow
for _, r in pairs(kept.left) do keptRow = r end
check(keptRow ~= nil and keptRow.serial ~= nil,
    'named by serial, so it can be chased off that exact copy',
    keptRow and tostring(keptRow.serial) or '-')
check(keptRow ~= nil and keptRow.kind == 'weapon',
    "and promoted from 'out' to 'weapon' -- a debt, not an issue",
    keptRow and tostring(keptRow.kind) or '-')

print()
print('AND A DATABASE THAT REFUSES TO WRITE')
-- A least-privilege user is not a broken server: the round must go on, and
-- the arena must not claim the slate is saved when nothing was written.
local ro = run(true, true, false, nil, true)
check(ro.armed > 0, 'the fighter is armed anyway', ('%d item(s)'):format(ro.armed))
check(ro.saved == false, 'and the arena does not claim the slate was saved',
    tostring(ro.saved))

print()
print('THE THREE SHIPPED CONFIGURATIONS, END TO END')
for _, c in ipairs({ { 'database off              ', false, false },
                     { 'database on, full grants  ', true,  false },
                     { 'database on, SELECT only  ', true,  true  } }) do
    local r = run(c[2], c[3], false, nil, false)
    print(('  %s  LoadOwedKit=%-5s  debt recorded %d, billed to %s  OwedKitIsSaved=%-5s  queries=%d')
        :format(c[1], tostring(r.loaded), r.owed, tostring(r.who), tostring(r.saved), r.queries))
end

print()
if failures > 0 then
    print(('LEDGER HARNESS FAILED: %d check(s)'):format(failures))
    os.exit(1)
end
print('ledger harness: every check passed')
