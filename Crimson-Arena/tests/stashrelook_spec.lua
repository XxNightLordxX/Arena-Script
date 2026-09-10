--[[
    crimson_arena/tests/stashrelook_spec.lua

    HOW LONG THE DOOR GOES ON LOOKING FOR SOMEBODY'S BELONGINGS.

    THE REPORT: "my phone didn't come back after the restart." Their phone was
    never destroyed -- it was sitting in their Arena Belongings stash, which is
    a real ox_inventory stash an admin can open -- but nothing in this resource
    was ever going to go back for it, and nothing in the console said so.

    THE MECHANISM, in three parts:

        1. `stashed` is memory. A restart erases every record of who has
           belongings put away, so after one the ONLY way the door finds out
           is the return sweep looking at a stash nothing named.

        2. ox_inventory loads a stash on demand. A stash it has not loaded yet
           reads back as an EMPTY LIST -- identical to a stash with nothing in
           it. So the look that happens seconds after a restart is exactly the
           look most likely to lie.

        3. The sweep counted those empty reads and stopped looking. First at
           one, then -- once that was found -- at five spread a minute apart.
           Five is a longer fuse, not a different mechanism: a stash that was
           still loading four minutes in was dropped for the REST OF THE
           PROCESS, and the warning that would have named it lives inside a
           branch gated on the memory record the restart had already erased.

    So this file is about one number: how long is "still looking". It asserts
    that there is no count of empty reads that ends it, that the looking gets
    cheaper rather than stopping, and that a hand-back which needed the slow
    look leaves a line an operator can grep for.

    The clock is a stub this file drives by hand. Sweeps that all happen in the
    same wall-clock second cannot see any of this -- which is why it was missed
    -- so every test below says what time it is.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- What the player walked in with, sitting in the stash where the door put it.
--- The phone carries metadata on purpose: the promise is the EXACT item back,
--- serial and all, so a hand-back that loses it is a failure here.
local BELONGINGS = {
    { name = 'phone', count = 1, metadata = { number = '555-0100', serial = 'PH-77' } },
    { name = 'money', count = 42000 },
}

--- One player, one stash left over from before a restart, and a clock.
---
--- @param opts table? -- { blindFor = integer } -- how many of the first
---        sweeps read the stash as an EMPTY LIST whatever is really in it
--- @return table fixture
local function newServer(opts)
    opts = opts or {}

    local inv, stashes, console = { [1] = {} }, {}, {}
    local stashReads = 0
    local sweeps = 0

    -- THE CLOCK, AND WHY IT IS A STUB. Everything this file is about is
    -- measured in minutes of a player's presence, and a spec runs in
    -- milliseconds. Left on the real os.time every sweep below would land in
    -- the same second, the look timer would refuse all but the first, and
    -- every assertion here would pass or fail for a reason that has nothing
    -- to do with the code under test.
    local now = 1700000000
    local clock = setmetatable({
        time = function(spec)
            if spec ~= nil then return os.time(spec) end
            return now
        end,
    }, { __index = os })

    local function bucket(id)
        if type(id) == 'number' then
            inv[id] = inv[id] or {}
            return inv[id]
        end
        stashes[id] = stashes[id] or {}
        return stashes[id]
    end

    local ox = {
        RegisterStash = function() return true end,
        registerHook = function() return true end,
        GetInventoryItems = function(_self, id)
            local out = {}
            if type(id) == 'string' then
                stashReads = stashReads + 1
                -- A STASH ox_inventory HAS NOT LOADED YET. Not an error, not
                -- a nil -- an empty list, which is the whole ambiguity this
                -- file exists to test against.
                if sweeps <= (opts.blindFor or 0) then return out end
            end
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
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = metadata }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            local from, want = bucket(id), tonumber(count) or 0
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
            if type(id) == 'number' then inv[id] = {} else stashes[id] = {} end
            return true
        end,
    }

    local env = Sandbox.newArenaEnv({
        os = clock,
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        -- Nobody is mid-round here. Every test in this file is about the
        -- player standing in the lobby wondering where their phone went.
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            IsPlayerInArena = function() return false end,
        },
        GetResourceState = function(name)
            return name == 'ox_inventory' and 'started' or 'missing'
        end,
        Wait = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function() end,
        -- The shipped sweep is a `while true`, and this runner takes a body
        -- straight through. returnRetrySeconds is zeroed below so it never
        -- starts; this file drives the sweep by hand so it can say what time
        -- each pass happened at. DO NOT hand this one a looping thread.
        CreateThread = function(fn) fn() end,
        GetPlayers = function() return { '1' } end,
        TriggerClientEvent = function() end,
        print = function(line) console[#console + 1] = line end,
        lib = Sandbox.newOxLib(),
        ArenaGetPlayer = function(src)
            return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
        end,
    })

    env.Config.Loadouts.inventory.returnRetrySeconds = 0

    Sandbox.loadInto('../server/util.lua', env)
    -- util.lua defines its own ArenaGetPlayer over the stub above.
    env.ArenaGetPlayer = function(src)
        return { PlayerData = { citizenid = 'CID' .. tostring(src) } }
    end
    Sandbox.loadInto('../server/ammo.lua', env)

    local fixture = { env = env, ammo = env.ArenaAmmo }

    --- The stash a restart left behind, filled the way the door filled it.
    for _, item in ipairs(BELONGINGS) do
        stashes['crimson_arena_CID1'] = stashes['crimson_arena_CID1'] or {}
        local into = stashes['crimson_arena_CID1']
        into[#into + 1] = { name = item.name, count = item.count, metadata = item.metadata }
    end

    --- One pass of the return sweep, `seconds` after the last one.
    --- @param seconds integer? -- the shipped returnRetrySeconds default
    function fixture.sweep(seconds)
        sweeps = sweeps + 1
        env.ArenaAmmo.SweepReturns()
        now = now + (seconds or 30)
    end

    --- @param passes integer
    --- @param seconds integer?
    function fixture.sweepFor(passes, seconds)
        for _ = 1, passes do fixture.sweep(seconds) end
    end

    --- Everything the player is carrying, sorted and comparable.
    function fixture.carrying()
        local names = {}
        for _, item in ipairs(inv[1] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- What is still in the stash the restart left behind.
    function fixture.leftInStash()
        local names = {}
        for _, item in ipairs(stashes['crimson_arena_CID1'] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- The metadata on the phone in the player's pockets, or nil.
    function fixture.phoneSerial()
        for _, item in ipairs(inv[1] or {}) do
            if item.name == 'phone' then return (item.metadata or {}).serial end
        end
        return nil
    end

    --- How many times ox_inventory has been asked to read a stash. This is
    --- the price of looking, and half this file is about that price.
    function fixture.stashReads() return stashReads end

    function fixture.log() return table.concat(console, '\n') end

    return fixture
end

--- What BELONGINGS looks like once carrying() has formatted it.
local INTACT = 'moneyx42000,phonex1'

-- ======================================================================
-- THERE IS NO NUMBER OF EMPTY READS THAT ENDS IT
-- ======================================================================

t.test('DEFECT: a stash still loading when the close looks run out was dropped for good', function()
    -- THE EXACT SHAPE OF THE REPORT. The resource restarts with the player
    -- online. Their belongings are in the stash; nothing in memory says so.
    -- ox_inventory takes four and a half minutes to have that stash ready --
    -- longer than the five close looks wait -- and from then on it reads
    -- perfectly.
    --
    -- Measured against the shipped thirty-second sweep: blind for eight
    -- passes came back, blind for nine never did, and the ninth is not a
    -- boundary anybody chose. It is where a counter ran out.
    local s = newServer({ blindFor = 9 })

    s.sweepFor(60)   -- half an hour of sweeps, all but the first nine readable

    t.equals(s.carrying(), INTACT, 'their belongings never came back')
    t.equals(s.leftInStash(), '', 'and are still in the stash')
    t.equals(s.phoneSerial(), 'PH-77', 'the phone came back as a different phone')
end)

t.test('and an hour of empty reads does not end it either', function()
    -- THE POINT OF THE PREVIOUS TEST STATED AS A RULE, because a fix that
    -- simply raises the count passes that one and fails this. A stash whose
    -- load failed and was retried by ox_inventory much later is the same
    -- player with the same phone, and there is no honest count of empty reads
    -- after which their things stop being theirs.
    local s = newServer({ blindFor = 120 })   -- one full hour of empty reads

    s.sweepFor(240)                           -- two hours of sweeps

    t.equals(s.carrying(), INTACT, 'the door stopped looking, so their phone stayed in the stash')
    t.equals(s.leftInStash(), '', 'and their cash with it')
end)

t.test('and a hand-back that needed a slow look leaves something to grep for', function()
    -- WHAT THE OPERATOR HAD BEFORE THIS: nothing. Not one line, ever -- the
    -- one warning on this path is inside a branch gated on the memory record
    -- a restart erases, so the console was silent for exactly the players it
    -- was silent about. The player reported it before the log did.
    --
    -- A find on a SLOW look is worth saying out loud because of what it
    -- implies about everybody else: stashes on this server load slower than
    -- the close looks wait, so anybody who disconnected in between was handed
    -- nothing at all.
    local s = newServer({ blindFor = 9 })

    s.sweepFor(60)

    t.isTrue(s.log():find('SLOW look', 1, true) ~= nil,
        'nothing in the console says the close looks missed it: ' .. s.log())
    t.isTrue(s.log():find('crimson_arena_CID1', 1, true) ~= nil,
        'the line does not name the stash an admin would have to open: ' .. s.log())
end)

t.test('and the ordinary player, whose stash reads empty because it is empty, is not shouted about', function()
    -- THE OTHER SIDE OF IT. Almost every empty read in this resource's life
    -- is a player who simply has nothing put away, and a line about each of
    -- them every few minutes is the log an operator stops reading -- which
    -- would put the sentence above back where it started.
    local s = newServer()
    s.sweepFor(1)                             -- the first look empties the stash
    t.equals(s.carrying(), INTACT, 'the first look did not hand anything back, so this proves nothing')

    local before = s.log()
    s.sweepFor(120)                           -- an hour with nothing left to find

    t.equals(s.log(), before, 'the sweep talks about a player it has nothing to say about')
end)

-- ======================================================================
-- AND THE LOOKING STAYS AFFORDABLE
-- ======================================================================

t.test('the close look is one read per character per minute, not one per sweep', function()
    -- THE GUARD THAT MAKES ANY OF THIS AFFORDABLE, and the reason the fix is
    -- a slower cadence rather than no gate at all. A look is a stash read for
    -- somebody nothing says is owed anything; at the sweep's own cadence that
    -- is a read per player every thirty seconds for ever.
    local s = newServer({ blindFor = 99 })

    s.sweepFor(4, 1)   -- four passes inside four seconds

    t.equals(s.stashReads(), 1, 'the sweep re-read a stash it had just read')

    s.sweep(60)        -- and now a minute has gone by
    s.sweep(1)

    t.equals(s.stashReads(), 2, 'a minute passed and the second close look never happened')
end)

t.test('and the slow look is not a read per sweep either', function()
    -- THE CEILING ON THE FIX. "Never stop looking" written as "look every
    -- pass" would be the give-up traded for a permanent tax on every player
    -- on the server -- and the give-up existed for a reason.
    --
    -- The numbers below are deliberately loose: this asserts the SHAPE --
    -- much less than one read per sweep, and more than the handful the close
    -- looks alone would spend -- not the exact interval, which an operator
    -- may reasonably want to tune.
    local s = newServer({ blindFor = 999 })   -- never readable, so it never settles

    s.sweepFor(120)                           -- one hour at the shipped cadence

    t.isTrue(s.stashReads() > 6,
        'the door gave up: ' .. s.stashReads() .. ' reads in an hour is the close looks and nothing after')
    t.isTrue(s.stashReads() <= 30,
        'the slow look is not slow: ' .. s.stashReads() .. ' reads in an hour')
end)

t.test('and a player who was handed their things back is not re-read every pass', function()
    -- THE ORDINARY CASE, which is every match on every server: the exit
    -- worked, the stash is empty, and this resource owes them nothing. The
    -- slow look still comes round -- their next match will fill that stash
    -- again -- but it must stay slow.
    local s = newServer()

    s.sweepFor(2)
    t.equals(s.leftInStash(), '', 'the door did not hand their things back, so this proves nothing')

    local reads = s.stashReads()
    s.sweepFor(8)                             -- four more minutes

    t.isTrue(s.stashReads() - reads <= 4,
        'a settled player costs a stash read per sweep: ' .. (s.stashReads() - reads) .. ' in four minutes')
end)

os.exit(t.summary())
