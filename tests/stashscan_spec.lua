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
--- The rows a MySQL `LIKE` pattern would really return.
---
--- `%` is any run of characters, `_` is exactly one, and a backslash escapes
--- either -- which is the whole of what the resource's escaping is for, so a
--- fixture that ignores the pattern cannot be asked whether the escaping
--- works.
--- @param pattern any
--- @param rows table[]
--- @return table[]
local function matching(pattern, rows)
    if type(pattern) ~= 'string' then return {} end

    local out, lua = {}, '^'
    local index = 1
    while index <= #pattern do
        local char = pattern:sub(index, index)
        if char == '\\' then
            -- Escaped: the next character is a literal, whatever it is.
            index = index + 1
            lua = lua .. pattern:sub(index, index):gsub('%W', '%%%0')
        elseif char == '%' then
            lua = lua .. '.*'
        elseif char == '_' then
            lua = lua .. '.'
        else
            lua = lua .. char:gsub('%W', '%%%0')
        end
        index = index + 1
    end
    lua = lua .. '$'

    for _, row in ipairs(rows) do
        if type(row.name) == 'string' and row.name:find(lua) then out[#out + 1] = row end
    end
    return out
end

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
            -- A READ THAT FAILS, WHICH IS NOT A READ THAT SAYS "NOTHING".
            -- ox_inventory gives nil for an inventory it has not loaded, and
            -- every place this resource treats those two as the same answer
            -- has cost somebody their belongings.
            if control.unreadable then return nil end
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

        -- THE DOOR'S HOLD LIST, WHICH IS A DATABASE TABLE OF ITS OWN and not
        -- the ox_inventory one this file otherwise models. Inert unless a
        -- test asks for it: ArenaDbReady answering false is exactly the
        -- shipped default -- Config.Database.enabled is off -- so every test
        -- above runs the way it always has.
        ArenaDbReady = function() return control.dbReady == true end,
        ArenaDb = function(_subject, sql, _params, cb)
            if type(cb) ~= 'function' then return end
            if not control.dbReady then return cb(nil) end
            if type(sql) == 'string' and sql:find('SELECT stash') then
                return cb(control.jamRows or {})
            end
            cb({})
        end,
        ArenaNotifyKey = function() end,
        ArenaGetPlayer = function() return nil end,
        exports = setmetatable({
            ox_inventory = inventory,
            oxmysql = {
                query = function(_self, sql, params, cb)
                    queries[#queries + 1] = { sql = sql, params = params }
                    if type(cb) ~= 'function' then return end
                    if control.fail then return cb(false) end

                    -- THE PATTERN IS APPLIED, NOT JUST RECORDED.
                    --
                    -- This double used to answer `control.rows` whatever was
                    -- asked, which made the file's own "and the query still
                    -- matches this arena's own stashes" test -- written and
                    -- labelled as the control for the escaping test above it
                    -- -- incapable of failing. Escaping the prefix into
                    -- something that matches literally nothing left the suite
                    -- green while the real screen would list none.
                    local rows = matching(params and params[1], control.rows or {})
                    cb(rows)
                    -- A DATABASE THAT ANSWERS TWICE. oxmysql should not, and
                    -- the resource must survive one that does -- which is
                    -- what the `answered` latch is for. Without this the
                    -- fixture had exactly one path to the callback, so the
                    -- test named for that latch could not fail.
                    if control.answerTwice then cb(rows) end
                end,
            },
        }, { __call = function() end }),
    })

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)

    -- `dbReady` HAS TO CARRY THE SWITCH THAT MAKES IT POSSIBLE.
    --
    -- This fixture stubbed ArenaDbReady and left Config.Database.enabled at
    -- the shipped false, which is a state no server can be in: the real gate
    -- is `Config.Database.enabled == true AND oxmysql started`, so a true
    -- answer implies the switch is on. Nothing noticed while every reader
    -- went through the stub -- and then the jam list's own "is this answer
    -- worth anything" test had to tell "nothing was ever persisted" from
    -- "persisted and unreachable", which is exactly that switch, and the
    -- fixture was asserting on a world where the two disagreed.
    -- `== true`, MATCHING THE STUB. The ArenaDbReady stub above tests
    -- `control.dbReady == true`; a truthiness test here would split them on
    -- any truthy non-true value, turning one control field into an accidental
    -- tri-state where the switch reads on and the gate still answers false.
    --
    -- No `or {}` fallback: config.lua is loaded two lines up and defines
    -- Config.Database with three keys, so the fallback could never fire --
    -- and if it ever did it would replace the table with one holding only
    -- `enabled`, dropping the other two.
    if control.dbReady == true then
        env.Config.Database.enabled = true
    end

    if mutate then mutate(env.Config) end

    -- AND THE INVARIANT IS ENFORCED AFTER mutate, NOT BEFORE IT.
    --
    -- The write above lands before the mutate callback, so a test whose
    -- mutate sets Database.enabled = false while control.dbReady is true put
    -- the resource straight back into the state the comment calls impossible
    -- -- silently, with the test still green and the assertion the fixture
    -- change was made for quietly flipped. Nothing asserted the invariant it
    -- documented. Now a test that does that fails here and says why.
    if control.dbReady == true then
        assert(env.Config.Database.enabled == true,
            'this fixture models ArenaDbReady as true while Config.Database.enabled is not -- '
            .. 'a state no server can be in, because the real gate is `enabled == true AND '
            .. 'oxmysql started`. Either drop control.dbReady or stop setting enabled false.')
    end
    Sandbox.loadInto('../Crimson-Arena/server/ammo.lua', env)

    local fixture = { env = env, ammo = env.ArenaAmmo, queries = queries, registered = registered }

    --- Runs one scan and hands back its rows plus the two counters.
    function fixture.scan()
        local answer, found, read
        fixture.ammo.AllStashes(function(rows) answer = rows end,
            function(total, opened) found, read = total, opened end)
        return answer, found, read
    end

    --- Reads the hold list back, the way startup does.
    function fixture.loadJams() return fixture.ammo.LoadJams() end

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

t.test('BUT A HELD-BACK ONE IS, EVEN EMPTY -- otherwise the hold can never be cleared', function()
    -- THE DEAD END THIS REMOVES, and it is a dead end with a player's
    -- belongings on the far side of it.
    --
    -- JamReport tells the operator to open each held-back stash on the
    -- Stashes tab and press Clear the hold, and says so in as many words:
    -- clearing "is a button and only a button" -- /arenaunjam was deleted on
    -- purpose. It then prints "empty, safe to clear" for a stash the operator
    -- has just finished emptying BY HAND, which is precisely what the door's
    -- own log told them to do.
    --
    -- With the old `#items > 0` test that stash had no row here, so no row on
    -- the tab, so no detail screen, so no button -- and no command left to
    -- fall back on. The hold was permanent, it is written to
    -- crimson_arena_jammed_stash, and it came back after every restart
    -- telling them stashes were still held back "from before the restart".
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
        rows = { row('crimson_arena_CID777', 'CID777') },
        contents = { crimson_arena_CID777 = {} },
    })

    t.isTrue(f.loadJams(), 'the hold list was not read back at all')

    local rows = f.scan()
    t.equals(#rows, 1,
        'an emptied stash that is still HELD BACK was dropped, so there is no row to press '
        .. 'Clear the hold on and the hold can never be lifted')
    t.equals(rows[1].stash, 'crimson_arena_CID777')
    t.isTrue(rows[1].jammed, 'the row is there but is not marked as held back')
    t.equals(#rows[1].items, 0, 'the row invented contents it does not have')
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

t.test('and a database that answers TWICE is only listened to once', function()
    -- The latch exists because four paths can reach `finish` -- the query's
    -- callback, the two fallbacks either side of it, and the watchdog -- and
    -- a second answer would open every stash a second time and redraw a
    -- screen the admin may have moved on inside.
    local f = newAmmo({
        rows = { row('crimson_arena_CID001', 'CID001') },
        contents = { crimson_arena_CID001 = { { name = 'phone', count = 1 } } },
        answerTwice = true,
    })

    local answered = 0
    f.ammo.AllStashes(function() answered = answered + 1 end)

    t.equals(answered, 1, ('the caller was answered %d times'):format(answered))
end)


-- ========================================================================
-- THE SCAN SAYS WHICH ROWS THE DOOR IS HOLDING BACK
--
-- A held-back stash is a real stash with real contents, so it lists like any
-- other -- and it is the ONLY kind the hand-back button cannot move. Without
-- this flag the admin screen had no way to tell them apart, drew the same
-- button on both, and the operator was told belongings were queued that the
-- exit refuses every time.
-- ========================================================================

t.test('a held-back stash is listed, and listed AS held back', function()
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
        rows = {
            row('crimson_arena_CID777', 'CID777'),
            row('crimson_arena_CID888', 'CID888'),
        },
        contents = {
            crimson_arena_CID777 = { { name = 'phone', count = 1 } },
            crimson_arena_CID888 = { { name = 'water', count = 2 } },
        },
    })

    t.isTrue(f.loadJams(), 'the hold list was not read back at all')

    local rows = f.scan()
    t.equals(#rows, 2, 'a held-back stash was dropped from the list -- its contents are real')

    local marks = {}
    for _, entry in ipairs(rows) do marks[entry.stash] = entry.jammed end

    t.isTrue(marks.crimson_arena_CID777, 'the held-back stash was not marked')
    -- THE CONTROL. A flag that is true for everything says nothing.
    t.isFalse(marks.crimson_arena_CID888, 'an ordinary stash was marked as held back')
end)

t.test('and IsJammed answers for one stash, saying whether it has been asked yet', function()
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
    })

    -- BEFORE THE READ LANDS: not held back, and NOT KNOWN. Those two returns
    -- are the whole of this -- an unread list answers "not held" for every
    -- stash on earth, and a screen that took that as fact would offer a
    -- hand-back on the one stash the door is certain to refuse.
    local jammed, known = f.ammo.IsJammed('crimson_arena_CID777')
    t.isFalse(jammed, 'a hold list nobody has read yet named a held stash')
    t.isFalse(known, 'an unread hold list was reported as read')

    f.loadJams()

    jammed, known = f.ammo.IsJammed('crimson_arena_CID777')
    t.isTrue(jammed, 'the stash on the hold list did not answer as held')
    t.isTrue(known, 'a hold list that HAS been read was reported as unread')

    t.isFalse((f.ammo.IsJammed('crimson_arena_CID888')),
        'a stash that was never held back answered as held')
end)

-- ========================================================================
-- CLEARING A HOLD IS ONE GATE, AND BOTH WAYS IN ASK IT
--
-- The judgement -- a stash that still holds rows is not cleared by somebody
-- who has not said they looked -- was written out inside the /arenaunjam
-- command and nowhere else, so the tablet's button reached past every word of
-- it. What is left in a held-back stash goes back inside the next ceiling and
-- the next exit hands it to the owner: a second copy of everything they are
-- already carrying, from the screen built to settle it.
-- ========================================================================

t.test('THE BUG: a hold over a stash that still holds things clears on one word', function()
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
        contents = { crimson_arena_CID777 = { { name = 'phone', count = 1 } } },
    })
    f.loadJams()

    local cleared, reason, rows = f.ammo.ClearHold('crimson_arena_CID777')

    t.isFalse(cleared, 'a hold over a stash with things in it was cleared unasked')
    t.equals(reason, 'not_empty', 'and no reason came back to put on a screen')
    t.equals(rows, 1, 'nor how much is still in it')
    t.isTrue((f.ammo.IsJammed('crimson_arena_CID777')), 'and the hold is gone anyway')
end)

t.test('and it DOES clear once the operator says they have looked', function()
    -- The refusal is a question, not a wall. `force` is the only answer to it
    -- and has to work, or an operator with a genuinely settled stash is stuck.
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
        contents = { crimson_arena_CID777 = { { name = 'phone', count = 1 } } },
    })
    f.loadJams()

    t.isTrue((f.ammo.ClearHold('crimson_arena_CID777', true)),
        'an operator who has read the contents still could not clear it')
    t.isFalse((f.ammo.IsJammed('crimson_arena_CID777')), 'and the hold stayed on')
end)

t.test('and an EMPTY held-back stash needs no such word', function()
    -- Nothing in it is nothing to hand over twice, which is the whole of what
    -- the question is about.
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
    })
    f.loadJams()

    t.isTrue((f.ammo.ClearHold('crimson_arena_CID777')),
        'an empty held-back stash was made to ask for a confirmation')
end)

t.test('and a stash that was never held back is refused, forced or not', function()
    local f = newAmmo({ dbReady = true })
    f.loadJams()

    local cleared, reason = f.ammo.ClearHold('crimson_arena_CID888', true)
    t.isFalse(cleared, 'a stash nobody was holding back was cleared')
    t.equals(reason, 'not_held')
end)

t.test('and a stash that CANNOT be read is refused with the rest', function()
    -- An unreadable stash is not an empty one -- an empty read is exactly
    -- what ox_inventory gives for an inventory it has not loaded, which is
    -- the state a hold is most likely to coincide with.
    local f = newAmmo({
        dbReady = true,
        jamRows = { { stash = 'crimson_arena_CID777' } },
        unreadable = true,
    })
    f.loadJams()

    local cleared, reason, rows = f.ammo.ClearHold('crimson_arena_CID777')
    t.isFalse(cleared, 'a stash nobody could read was treated as an empty one')
    t.equals(reason, 'not_empty')
    t.isNil(rows, 'it invented a count for a stash it could not read')
end)

os.exit(t.summary())
