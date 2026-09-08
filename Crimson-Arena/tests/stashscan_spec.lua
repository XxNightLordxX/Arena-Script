--[[
    crimson_arena/tests/stashscan_spec.lua

    FINDING EVERY STASH THIS ARENA HAS EVER MADE.

    `owed` and `stashed` are in MEMORY. They survive a reconnect, the retry
    sweep works from them, and they are gone the moment the resource restarts.
    The stashes are not -- they are real ox_inventory rows -- so somebody whose
    belongings were outstanding when the server went down was a person nothing
    in this resource could name afterwards. ArenaAmmo.AllStashes goes to the
    database and finds them by name; ArenaAmmo.QueueReturn puts one back on the
    list the sweep works from.

    WHY THIS FILE EXISTS SEPARATELY from tests/admintablet_spec.lua: that file
    stubs ArenaAmmo wholesale to test the SCREEN, which is right for what it
    asks and leaves both of these functions with no coverage at all. Three
    defects lived in that gap, and every one of them cost exactly the person
    the feature was written for.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('stashscan_spec')

--- The real server/ammo.lua with oxmysql and ox_inventory modelled rather
--- than stubbed, so what the query actually ASKS FOR is a fact this file can
--- check.
---
---   control.rows    -- what the name query answers with
---   control.fail    -- the query answers a non-table, as a broken read does
---   control.contents -- what each stash holds, by stash name
--- @param mutate fun(config: table)?
local function newAmmo(control, mutate)
    control = control or {}
    control.contents = control.contents or {}

    local queries, registered = {}, {}

    local inventory = {
        RegisterStash = function(_self, name, label, slots, weight, owner)
            registered[#registered + 1] = {
                name = name, label = label, slots = slots, weight = weight, owner = owner,
            }
            return true
        end,
        GetInventoryItems = function(_self, id)
            return control.contents[id] or {}
        end,
        AddItem = function() return true end,
        RemoveItem = function() return true end,
        ClearInventory = function() return true end,
        registerHook = function() return true end,
    }

    local env = Sandbox.newEnv({
        CreateThread = function() end,
        Wait = function() end,
        SetTimeout = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'started' end,
        GetPlayers = function() return {} end,
        ArenaLog = function() end,
        ArenaDebug = function() end,
        ArenaNotifyKey = function() end,
        ArenaGetPlayer = function() return nil end,
        exports = setmetatable({
            ox_inventory = inventory,
            oxmysql = {
                query = function(_self, sql, params, cb)
                    queries[#queries + 1] = { sql = sql, params = params }
                    if type(cb) ~= 'function' then return end
                    if control.fail then return cb(false) end
                    cb(control.rows or {})
                end,
            },
        }, { __call = function() end }),
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/ammo.lua', env)

    local fixture = { env = env, ammo = env.ArenaAmmo, queries = queries, registered = registered }

    --- Runs one scan and hands back its rows plus the two counters.
    function fixture.scan()
        local answer, found, read
        fixture.ammo.AllStashes(function(rows) answer = rows end,
            function(total, opened) found, read = total, opened end)
        return answer, found, read
    end

    --- Every stash name the scan answered with.
    function fixture.namesFrom(rows)
        local out = {}
        for _, row in ipairs(rows or {}) do out[#out + 1] = row.stash end
        table.sort(out)
        return out
    end

    return fixture
end

--- A database row, as oxmysql answers one.
local function row(name, owner)
    return { name = name, owner = owner }
end

-- ========================================================================
-- THE ONE PERSON WHO IS SHORT IS THE ONE IT MUST NOT HIDE
-- ========================================================================

t.test('a stash from an earlier run is found by name', function()
    -- The whole point of going to the database rather than to memory.
    local f = newAmmo({
        rows = { row('crimson_arena_CID777', 'CID777') },
        contents = { crimson_arena_CID777 = { { name = 'phone', count = 1 } } },
    })

    local rows = f.scan()
    t.equals(#rows, 1, 'a stash this run has never heard of was not listed')
    t.equals(rows[1].citizenid, 'CID777')
    t.isFalse(rows[1].remembered, 'a stash found by name was reported as remembered')
end)

t.test('and an empty one is not listed, because nothing is being held', function()
    -- Every character who has ever fought here has a row, and almost all of
    -- them were emptied back into their owner long ago. Listing those would
    -- bury the handful that matter.
    local f = newAmmo({ rows = { row('crimson_arena_CID001', 'CID001') } })
    t.equals(#f.scan(), 0, 'an emptied stash was listed as something being held')
end)

t.test('THE BUG: a stash past the read limit was dropped from the answer entirely', function()
    -- The names are all fetched and the contents of the newest handful are
    -- read -- that part is deliberate, and the counters say so. But the row
    -- was struck off the memory list BEFORE the limit was checked, so a row
    -- past the limit was taken off `known` AND left off the answer, and the
    -- backstop that exists to catch exactly that could no longer put it back.
    --
    -- Which cost the one person this screen was written for: somebody whose
    -- kit is stuck in escrow, on a server with sixty more recently-touched
    -- stashes, was not listed at all -- and the counters did not hint at it
    -- either, because from here it looked like everything picked had been
    -- opened.
    local rows, contents = {}, {}
    for index = 1, 70 do
        local name = ('crimson_arena_CID%03d'):format(index)
        rows[#rows + 1] = row(name, ('CID%03d'):format(index))
        contents[name] = { { name = 'phone', count = 1 } }
    end

    local f = newAmmo({ rows = rows, contents = contents })
    -- The stash this run KNOWS is owed, sitting at the far end of the list.
    f.ammo.QueueReturn('CID070', 'crimson_arena_CID070')

    local answered = f.scan()

    local found = false
    for _, entry in ipairs(answered) do
        if entry.citizenid == 'CID070' then found = true end
    end
    t.isTrue(found,
        'the one stash this run knows is outstanding was dropped off the end of the list')
end)

t.test('and the counters still say how many were not opened', function()
    local rows = {}
    for index = 1, 70 do
        rows[#rows + 1] = row(('crimson_arena_CID%03d'):format(index), ('CID%03d'):format(index))
    end

    local f = newAmmo({ rows = rows })
    local _, found, read = f.scan()
    t.equals(found, 70, 'the screen was not told how many stashes exist')
    t.isTrue(read <= 70, 'more stashes were reported opened than exist')
end)

-- ========================================================================
-- THE PREFIX IS A PATTERN, NOT A NAME
-- ========================================================================

t.test('THE BUG: the underscores in the prefix were LIKE wildcards', function()
    -- The shipped prefix is `crimson_arena_`, and in a LIKE each `_` matches
    -- any single character. So the query also matched names like
    -- `crimsonXarenaY...` -- and any such row was then treated as an arena
    -- stash: re-registered under an owner sliced out of its name, and its
    -- contents printed on the tablet.
    local f = newAmmo({})
    f.scan()

    t.equals(#f.queries, 1, 'the scan did not go to the database at all')
    local pattern = f.queries[1].params[1]
    t.isTrue(pattern:find('\\_', 1, true) ~= nil,
        ('the LIKE pattern leaves its underscores as wildcards: %s'):format(pattern))
end)

t.test('and the query still matches this arena\'s own stashes', function()
    -- The control. Escaping the pattern into something that matches nothing
    -- would pass the test above and quietly empty the screen.
    local f = newAmmo({
        rows = { row('crimson_arena_CID001', 'CID001') },
        contents = { crimson_arena_CID001 = { { name = 'phone', count = 1 } } },
    })
    t.equals(#f.scan(), 1, 'the arena can no longer find its own stashes')
end)

-- ========================================================================
-- AND A QUEUED RETURN NAMES A STASH THIS ARENA WOULD HAVE MADE
-- ========================================================================

t.test('queueing a return for a real arena stash works', function()
    local f = newAmmo({})
    t.isTrue(f.ammo.QueueReturn('CID001', 'crimson_arena_CID001'),
        'an ordinary queued return was refused')
    t.equals(f.ammo.Owed(), 1, 'it was accepted and then not written down')
end)

t.test('THE BUG: it took ANY inventory id, and the next refresh opened it', function()
    -- The stash name is derived from the citizen id, so the caller's copy of
    -- it is not information -- it is only a chance to be wrong. Unchecked, an
    -- admin payload naming any inventory in the database put that inventory
    -- on the sweep's list, and the tablet's next refresh re-registered it as
    -- an 'Arena Belongings' stash under a caller-chosen owner and printed
    -- what was in it. On every refresh, from then on.
    local f = newAmmo({ contents = { gang_ballas = { { name = 'weapon_pistol', count = 4 } } } })

    t.isFalse(f.ammo.QueueReturn('anything', 'gang_ballas'),
        'a foreign inventory was accepted as somebody\'s arena belongings')
    t.equals(f.ammo.Owed(), 0, 'and written onto the debt list')

    f.scan()
    for _, entry in ipairs(f.registered) do
        t.isTrue(entry.name ~= 'gang_ballas',
            'the arena re-registered a foreign stash as its own')
    end
end)

t.test('and an empty citizen id or stash is refused, as it always was', function()
    local f = newAmmo({})
    t.isFalse(f.ammo.QueueReturn(nil, 'crimson_arena_CID001'))
    t.isFalse(f.ammo.QueueReturn('CID001', nil))
    t.equals(f.ammo.Owed(), 0)
end)

-- ========================================================================
-- AND IT ANSWERS EXACTLY ONCE, WHATEVER THE DATABASE DOES
-- ========================================================================

t.test('a query that answers a non-table still answers the caller', function()
    local f = newAmmo({ fail = true })
    local answered = 0
    f.ammo.AllStashes(function() answered = answered + 1 end)
    t.equals(answered, 1, 'a failed read left the caller waiting for ever')
end)

t.test('and a scan answers once and once only', function()
    local f = newAmmo({ rows = { row('crimson_arena_CID001', 'CID001') } })
    local answered = 0
    f.ammo.AllStashes(function() answered = answered + 1 end)
    t.equals(answered, 1, ('the callback ran %d times'):format(answered))
end)

os.exit(t.summary())
