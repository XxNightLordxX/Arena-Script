--[[
    crimson_arena/tests/outagereplay_spec.lua

    THE SLATE AFTER AN oxmysql OUTAGE.

    ArenaDb throws away a statement it cannot send -- there is no queue behind
    it -- so every write the outstanding-kit slate makes while oxmysql is down
    evaporates. Both directions cost something, and only one of them was ever
    put back:

      A SETTLEMENT LOST      the chase takes the arena's rifle back, the DELETE
                             never lands, and the next start reads the row back
                             as an open debt for a weapon the arena is holding.

      A DEBT LOST            an exit that cannot get the rifle back writes the
                             debt into memory while its INSERT evaporates, so
                             the table never hears about it and the next start
                             has written off the arena's own kit.

    The replay is the answer to both, and it is only correct because it asks
    MEMORY what the row should say rather than remembering which statement was
    dropped: memory is the live answer for the whole of a run. That is also
    what makes it safe to repeat -- a stack is re-sent as its current total and
    never as another addition to one.

    Nothing else in this suite runs an outage at all.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('outagereplay_spec')

--- The real server/ammo.lua with oxmysql modelled as a TABLE rather than
--- stubbed, so "the row is in the database" is a fact this file can check.
---
---   control.down       -- oxmysql is not started: ArenaDb never reaches it
---   control.connected  -- who GetPlayers answers with (default: player 1)
---   control.refuse     -- RemoveItem refuses to take anything off a player,
---                         which is what leaves a debt behind at the exit
---   control.failWrites -- oxmysql takes the statement and answers nil, the
---                         way a user without INSERT or DELETE does
---   control.defer      -- the callback is HELD rather than called, so a test
---                         can run a sweep in the window a real oxmysql leaves
---                         open between dispatch and answer
local function newArena(control)
    control = control or {}

    -- The rows, keyed exactly as the table's primary key is.
    local stored = {}
    local queries = {}
    local held = {}
    local inv = {}
    local serials = 0

    local function bucket(id)
        inv[id] = inv[id] or {}
        return inv[id]
    end

    local ox = {
        RegisterStash = function() return true end,
        registerHook = function() return 1 end,
        GetInventoryItems = function(_self, id)
            local out = {}
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        GetItemCount = function(_self, id, name)
            local total = 0
            for _, item in ipairs(bucket(id)) do
                if item.name == name then total = total + (tonumber(item.count) or 0) end
            end
            return total
        end,
        AddItem = function(_self, id, name, count, metadata)
            -- ox_inventory stamps a serial onto a weapon that arrives without
            -- one, and the serial is the whole of what makes a weapon debt
            -- collectable -- a row without one is refused by the ledger.
            local meta = metadata
            if type(name) == 'string' and name:find('^WEAPON_')
                and (meta == nil or meta.serial == nil) then
                serials = serials + 1
                meta = meta or {}
                meta.serial = 'ARENA-' .. serials
            end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = meta }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            if control.refuse then return false end

            local from = bucket(id)
            local want = tonumber(count) or 0
            local total = 0
            for _, item in ipairs(from) do
                if item.name == name then total = total + (tonumber(item.count) or 0) end
            end
            if total < want then return false end

            for index = #from, 1, -1 do
                if want <= 0 then break end
                if from[index].name == name then
                    local have = tonumber(from[index].count) or 0
                    if have <= want then
                        want = want - have
                        table.remove(from, index)
                    else
                        from[index].count = have - want
                        want = 0
                    end
                end
            end
            return true
        end,
        ClearInventory = function(_self, id)
            inv[id] = {}
            return true
        end,
    }

    --- oxmysql, answering the four statements the slate sends.
    local function query(_self, sql, params, cb)
        queries[#queries + 1] = { sql = sql, params = params }
        local flat = sql:gsub('%s+', ' ')

        -- HELD, and the statement is NOT applied. A query oxmysql has taken
        -- and not answered has not changed anything yet, which is the whole
        -- window this models.
        if control.defer and not flat:find('CREATE TABLE') then
            if cb then held[#held + 1] = cb end
            return
        end

        if flat:find('CREATE TABLE') then
            if cb then cb({}) end
            return
        end

        if flat:find('^SELECT') then
            local rows = {}
            for key, row in pairs(stored) do
                rows[#rows + 1] = {
                    citizenid = key:match('^(.-)|'), ledger_key = row.key, kind = row.kind,
                    name = row.name, serial = row.serial, amount = row.amount,
                }
            end
            if cb then cb(rows) end
            return
        end

        if control.failWrites then
            if cb then cb(nil) end
            return
        end

        if flat:find('^DELETE') then
            -- The age-out carries no parameters; the settlement carries two.
            if params and params[2] then stored[params[1] .. '|' .. params[2]] = nil end
            if cb then cb({ affectedRows = 1 }) end
            return
        end

        local key = params[1] .. '|' .. params[2]
        if flat:find("'weapon'") then
            stored[key] = { key = params[2], kind = 'weapon', name = params[3],
                serial = params[4], amount = 1 }
        elseif flat:find('amount %+ VALUES') then
            local have = stored[key]
            stored[key] = { key = params[2], kind = 'item', name = params[3],
                amount = (have and have.amount or 0) + params[4] }
        else
            stored[key] = { key = params[2], kind = 'item', name = params[3], amount = params[4] }
        end
        if cb then cb({ affectedRows = 1 }) end
    end

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox, oxmysql = { query = query } },
            { __call = function() end }),
        GetResourceState = function(name)
            if name == 'ox_inventory' then return 'started' end
            if name == 'oxmysql' then return control.down and 'missing' or 'started' end
            return 'missing'
        end,
        GetPlayers = function()
            local out = {}
            for _, src in ipairs(control.connected or { 1 }) do out[#out + 1] = tostring(src) end
            return out
        end,
        Wait = function() end,
        CreateThread = function(fn) fn() end,
        SetTimeout = function() end,
        AddEventHandler = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        TriggerClientEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        lib = Sandbox.newOxLib(),
        print = function() end,
        ArenaGetPlayer = function(src)
            return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
        end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        ArenaNotifyKey = function() end,
        ArenaToastKey = function() end,
        ArenaPlayerName = function(src) return 'P' .. tostring(src) end,
        ArenaDispatch = { Set = function() end, Clear = function() end,
            IsPlayerInArena = function() return false end },
    })

    -- The sweep is a `while true`, and CreateThread above runs a body to
    -- completion. Every pass in this file is driven by hand.
    env.Config.Loadouts.inventory.returnRetrySeconds = 0
    env.Config.Loadouts.inventory.stripOnEntry = false
    env.Config.Database = { enabled = true }

    Sandbox.loadInto('../server/util.lua', env)
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    env.ArenaLog = function() end
    env.ArenaDebug = function() end
    Sandbox.loadInto('../server/ammo.lua', env)

    local fixture = { env = env, ammo = env.ArenaAmmo, queries = queries, control = control }

    --- The slate as the DATABASE holds it, sorted, as a comparable string.
    function fixture.table()
        local out = {}
        for key, row in pairs(stored) do
            out[#out + 1] = ('%s=%s'):format(key, tostring(row.amount))
        end
        table.sort(out)
        return #out == 0 and '(none)' or table.concat(out, ',')
    end

    --- The slate as MEMORY holds it, in the same shape, so the two can be
    --- compared against each other rather than against a hand-written string.
    function fixture.memory()
        local out = {}
        for _, row in ipairs(fixture.ammo.OwedKit() or {}) do
            for _, weapon in ipairs(row.weapons or {}) do
                out[#out + 1] = ('%s|w:%s=1'):format(row.citizenid, weapon.serial)
            end
            for _, item in ipairs(row.items or {}) do
                out[#out + 1] = ('%s|i:%s=%s'):format(row.citizenid, item.name, tostring(item.amount))
            end
        end
        table.sort(out)
        return #out == 0 and '(none)' or table.concat(out, ',')
    end

    --- Hands player `src` a rifle and thirty bandages, then puts them through
    --- an exit that cannot get either back -- which is the one thing that
    --- writes a debt down.
    function fixture.leaveOwing(src)
        control.refuse = false
        fixture.ammo.Issue(src, 'm1', {
            weapons = { { key = 'w1', weapon = 'WEAPON_TEST', ammo = 0, components = {} } },
            supplies = { { item = 'bandage', count = 30 } },
            armor = 0, health = 200,
        })
        control.refuse = true
        fixture.ammo.Reclaim(src, 'match ended')
        control.refuse = false
    end

    function fixture.sweep(times)
        for _ = 1, (times or 1) do fixture.ammo.SweepReturns() end
    end

    --- Answers every held callback with `result`, the way oxmysql eventually
    --- would. nil is a statement that did not land.
    function fixture.settle(result)
        local batch = held
        held = {}
        for _, cb in ipairs(batch) do cb(result) end
        return #batch
    end

    --- How many statements that CHANGE the slate have been sent.
    function fixture.writes()
        local total = 0
        for _, sent in ipairs(queries) do
            if not sent.sql:find('SELECT') and not sent.sql:find('CREATE TABLE') then
                total = total + 1
            end
        end
        return total
    end

    return fixture
end

-- ======================================================================
-- THE HEADLINE: A DEBT INCURRED WHILE THE DATABASE IS DOWN
-- ======================================================================

t.test('a debt taken on while oxmysql is down is written down once it answers again', function()
    local s = newArena({ down = false })
    s.sweep()                              -- a healthy start, so the slate is read
    s.control.down = true

    s.leaveOwing(1)
    t.equals(s.table(), '(none)', 'the outage did not stop the write reaching the database')
    t.isTrue(s.memory() ~= '(none)', 'nothing was written down in memory, so there is no debt to test')

    -- The debtor logs off, so nothing in this process can settle the debt and
    -- the only thing that can put it in the table is the replay.
    s.control.connected = {}
    s.control.down = false
    s.sweep(3)

    t.equals(s.table(), s.memory(),
        'the debts taken on during the outage were never re-sent -- the database still does not '
            .. 'know about the arena\'s own rifle and thirty bandages, and the next restart '
            .. 'writes them off')
end)

t.test('and the stack is re-sent as the total it stands at, never as another addition', function()
    local s = newArena({ down = false })
    s.sweep()
    s.control.down = true
    s.leaveOwing(1)
    s.control.connected = {}
    s.control.down = false

    -- Ten passes. An adding statement replayed is a different debt every time
    -- it lands; the total must not move after the first one.
    s.sweep(10)
    t.equals(s.table(), s.memory(), 'the replay has moved the stored total away from the slate')
    t.isTrue(s.table():find('|i:bandage=30', 1, true) ~= nil,
        'the stack was replayed as an addition: ' .. s.table())
end)

-- ======================================================================
-- THE HALF THAT WAS ALREADY PUT BACK, GUARDED
-- ======================================================================

t.test('a settlement the database never took is still re-sent, and the row goes', function()
    local s = newArena({ down = false })
    s.sweep()
    s.leaveOwing(1)
    t.isTrue(s.table() ~= '(none)', 'the debt was never written down with the database up')

    -- The outage, and a sweep that collects the debt: the player is holding
    -- what they owe, so the chase takes it and the DELETE evaporates.
    s.control.down = true
    s.sweep()
    s.control.down = false
    s.sweep(2)

    t.equals(s.table(), '(none)',
        'a settled debt is still in the table, so the next start reads it back as open')
end)

-- ======================================================================
-- ONE REFUSAL IS NOT A DATABASE THAT CANNOT WRITE
-- ======================================================================

t.test('one refused write does not switch the replay off for the rest of the run', function()
    local s = newArena({ down = false })
    s.sweep()                              -- the age-out answers: a write HAS landed here

    -- One statement taken and answered nil, which is all it takes to latch the
    -- "this slate cannot be written to" flag for the life of the process.
    s.control.failWrites = true
    s.leaveOwing(1)
    t.equals(s.table(), '(none)', 'the refusal did not refuse')

    s.control.failWrites = false
    s.control.connected = {}
    s.sweep(3)

    t.equals(s.table(), s.memory(),
        'the replay stayed switched off after a single refusal, which is exactly when '
            .. 'settlements are being lost')
end)

t.test('a statement still on the wire is not sent a second time underneath itself', function()
    -- THE ORDERING HAZARD THE REPLAY HAS TO RESPECT. An absolute total sent
    -- while the addition it was meant to follow is still in flight can land
    -- first, and then the row is wrong until something else rewrites it. A key
    -- becomes replayable only when its own answer is in.
    local s = newArena({ down = false, connected = {} })
    s.sweep()

    s.control.defer = true
    s.leaveOwing(1)

    local sentSoFar = s.writes()
    s.sweep(3)
    t.equals(s.writes(), sentSoFar,
        'the replay re-sent a write whose answer had not come back yet')

    -- The answers arrive, and say the statements never landed. NOW they are
    -- the replay's business.
    s.control.defer = false
    t.isTrue(s.settle(nil) > 0, 'nothing was held, so this test proved nothing')
    s.sweep(2)

    t.equals(s.table(), s.memory(), 'the writes were never re-sent after they came back refused')
end)

os.exit(t.summary())
