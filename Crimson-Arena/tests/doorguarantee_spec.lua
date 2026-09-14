--[[
    crimson_arena/tests/doorguarantee_spec.lua

    ONE PROMISE, PROVED ON EVERY WAY OUT.

        Whatever a player owned before the match, they get back.
        Nothing the match produced leaves with them.

    Everything else in this resource is a feature. This is the promise, because
    it is the one whose failure a player cannot fix and would not forgive.

    WHY THIS FILE EXISTS SEPARATELY from tests/ammo_spec.lua: that file tests
    server/ammo.lua directly, and passed while the promise was broken. A player
    torn down through ArenaLobby.Destroy's fallback had their flag cleared and
    their routing bucket returned and was never reclaimed -- so they kept the
    arena kit and their real belongings stayed in a stash. The unit was correct
    and one caller did not call it.

    So this file does not test the door. It drives the whole server stack
    through every exit an arena has and asserts the promise came out the other
    side: finishing, leaving, being eliminated, disconnecting, a host closing
    the lobby, an admin stopping it, and the resource shutting down mid-round.

    A new way out of an arena that forgets to reclaim fails here by name.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- WHETHER THE ARENA IS STILL HOLDING THIS PLAYER'S OWN KIT.
---
--- ArenaAmmo.IsHolding answered this until 2fec9fe deleted it: nothing in the
--- shipped tree called it. HeldFor is the reader that survived, and the commit
--- that removed the other says so in as many words -- both went through the
--- same private ownRecord, which is what makes this an exact stand-in rather
--- than an approximation. The question the tests below ask is unchanged; only
--- the function that answers it is.
--- @param ammo table -- env.ArenaAmmo
--- @param src integer
--- @return boolean
local function isHolding(ammo, src)
    return ammo.HeldFor(src) ~= nil
end

--- What every player in these tests owns before they go near the arena.
local OWN = {
    { name = 'phone', count = 1 },
    { name = 'burger', count = 3 },
    { name = 'ammo-rifle-ap', count = 40 },   -- deliberately an ARENA item too
}

--- @param ids integer[]
--- @param mutate fun(config: table)?
--- @return table server
--- @param extra table[]? -- items every player also starts with
--- @param opts table|nil
---   tickMs  how far GetGameTimer jumps per call. The default of a whole
---           MINUTE is what most of this file wants -- it makes round timers
---           expire so a match cannot outlive the test looking at it. It also
---           makes it impossible to hold a second match live while asking
---           anything about the first, so the multi-match section passes a
---           small value instead. Default kept exactly as it was.
local function newServer(ids, mutate, extra, opts)
    opts = opts or {}
    local wallets, inv, stashes = {}, {}, {}
    for _, src in ipairs(ids) do
        wallets[src] = {
            citizenid = 'CID' .. src,
            name = 'Player' .. src,
            money = { cash = 50000, bank = 0 },
        }
        inv[src] = {}
        -- METADATA COMES WITH THE ITEM. It was dropped here, so nothing in
        -- this file could carry an item whose IDENTITY is its metadata -- a
        -- phone with a number, a licence with a name -- and the door's
        -- promise is about those more than about a count of burgers.
        for _, item in ipairs(OWN) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count, metadata = item.metadata }
        end
        for _, item in ipairs(extra or {}) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count, metadata = item.metadata }
        end
    end

    local qbx = Sandbox.newQbxCore(wallets)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}

    --- The console commands the resource registers.
    local commands = {}

    --- Which routing bucket each player is standing in.
    local buckets = {}

    --- Inventories that refuse everything offered to them.
    local refusingAdds = {}

    --- Every id this fixture knows to be a CONTAINER rather than a stash,
    --- so the reads above can tell the two apart.
    local containerKeys = {}

    local function bucket(id)
        if type(id) == 'number' then
            inv[id] = inv[id] or {}
            return inv[id]
        end
        stashes[id] = stashes[id] or {}
        return stashes[id]
    end

    --- Stash ids ox_inventory will answer an EMPTY LIST for, whatever is
    --- really in them.
    ---
    --- THIS IS NOT A FAILURE ox_inventory REPORTS. A stash it has forgotten
    --- -- because the resource restarted, or the row was re-registered under
    --- a different name -- reads exactly like a stash with nothing in it, and
    --- that ambiguity is the whole subject of the tests that use this.
    local forgotten = {}

    --- The swapItems hook the resource registers, so these can drive it. The
    --- stub used to throw it away, which made every question about who the
    --- guard applies to unanswerable from in here.
    local hook

    --- Which container inventories ox_inventory is currently holding. A
    --- container is NOT reachable by id until something wakes it -- see
    --- wakeContainer in server/ammo.lua -- so this models the one thing that
    --- makes the police-bag defect possible: `GetInventoryItems(containerId)`
    --- answers nothing for a container that has been dropped from memory, and
    --- only GetContainerFromSlot can bring one back.
    local livingContainers = {}

    --- Set by a test to model an ox_inventory build old enough not to have
    --- GetContainerFromSlot at all.
    local noContainerExport = false

    local ox = {
        RegisterStash = function() return true end,
        --- ox_inventory's own export, modelled on its real body: find the
        --- item in that slot, and if the inventory behind its container key
        --- is not in memory, CREATE it -- empty.
        GetContainerFromSlot = function(_self, id, slot)
            if noContainerExport then error('no such export GetContainerFromSlot', 2) end

            local holder = bucket(id)
            local item = holder[slot]
            if type(item) ~= 'table' then return nil end

            local key = type(item.metadata) == 'table' and item.metadata.container or nil
            if key == nil then return nil end

            if not livingContainers[key] then
                -- Woken from nothing, which is what a container reloaded out
                -- of a database that did not answer looks like.
                livingContainers[key] = true
                stashes[key] = stashes[key] or {}
            end
            return { id = key }
        end,
        GetInventoryItems = function(_self, id)
            local out = {}
            -- A CONTAINER NOBODY HAS WOKEN IS NOT READABLE, and that is not
            -- the same answer as an empty one. ox_inventory resolves an id
            -- that is not a registered stash to nothing at all.
            if containerKeys[id] and not livingContainers[id] then return nil end
            if forgotten[id] then return out end
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata)
            -- A PLAYER WHO CANNOT BE GIVEN ANYTHING MORE. ox_inventory refuses
            -- by returning false when an inventory is out of slots or over
            -- weight, and this fixture had no way to say so -- which left the
            -- single most ordinary refusal at the exit, a full inventory,
            -- untested.
            if refusingAdds[id] then return false end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = metadata }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            local from = bucket(id)
            for index = #from, 1, -1 do
                if from[index].name == name and from[index].count == count then
                    table.remove(from, index)
                    return true
                end
            end
            return false
        end,
        -- MODELS ox_inventory's REAL SIGNATURE: ClearInventory(inv, keep),
        -- where `keep` is a list of item names that survive the clear. The
        -- stub used to drop the second argument, so a resource that passed
        -- one and a resource that did not looked identical here -- which is
        -- exactly how money could be cleared out of a player's pockets with
        -- every test still green.
        ClearInventory = function(_self, id, keep)
            local safe = {}
            for _, name in ipairs(type(keep) == 'table' and keep or { keep }) do
                if type(name) == 'string' then safe[name] = true end
            end
            local from = type(id) == 'number' and (inv[id] or {}) or (stashes[id] or {})
            local left = {}
            for _, item in ipairs(from) do
                if safe[item.name] then left[#left + 1] = item end
            end
            if type(id) == 'number' then inv[id] = left else stashes[id] = left end
            return true
        end,
        registerHook = function(_self, name, fn)
            if name == 'swapItems' then hook = fn end
            return true
        end,
    }

    local env = Sandbox.newArenaEnv({
        exports = setmetatable({ ox_inventory = ox, qbx_core = qbx.exports.qbx_core },
            { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        -- CAPTURED, because one of them is now part of the door's promise:
        -- a jammed stash is a dead end until an admin can see it and clear
        -- it, and /arenaunjam is the only thing that can.
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        GetGameTimer = (function()
            local c = 0
            local step = tonumber(opts.tickMs) or 60000
            return function() c = c + step return c end
        end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        -- Everybody the door has ever seen. The return sweep walks this, and
        -- letting it run for real here is the point: these are the tests
        -- that say a match cannot cost anyone anything, so a background
        -- thread that hands inventories about had better be in them.
        GetPlayers = function()
            local out = {}
            for src in pairs(inv) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            -- INSIDE THE ARENA THESE FIGHTERS ARE SUPPOSED TO BE IN, which
            -- this used to be nowhere near: it answered a point 1,450m from
            -- the Trailer Park, so every fighter in every one of these specs
            -- was standing well outside the fence they were fighting inside.
            -- Nothing read it until Config.Match.serverChecks did, and then
            -- it read as the whole roster having walked out of the round.
            --
            -- Spread three metres apart, so they are also close enough for
            -- the kill-distance ceiling -- the other thing that reads this.
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        -- The real server/dispatch.lua writes the arena flag through a state
        -- bag; this file cares only that it does not throw.
        Player = function()
            return { state = { set = function() end } }
        end,
        -- REAL, NOT NO-OPS. These answered 0 and did nothing, which is
        -- precisely what FXServer does when routing buckets are unavailable
        -- -- so server/dispatch.lua caught the move not landing, latched
        -- `provenInert`, and switched isolation off for the whole fixture.
        -- Every bucket line in the file it loads was therefore dead here.
        --
        -- Modelled properly, this is the one fixture with the real inventory
        -- AND real instancing at the same time, which is what "does a second
        -- match cost the first one anything" needs.
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) buckets[tonumber(src)] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        GetAllVehicles = function() return {} end,
        GetAllObjects = function() return {} end,
        GetAllPeds = function() return {} end,
        GetEntityRoutingBucket = function() return 0 end,
        DeleteEntity = function() end,
        DoesEntityExist = function() return false end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
    })

    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.minPlayers = 2
    env.Config.Betting.enabled = false
    env.Config.Loadouts.ammoItems.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'ammo', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, lobby = env.ArenaLobby, match = env.ArenaMatch, ammo = env.ArenaAmmo }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    function server.stopResource() handlers['onResourceStop']('crimson_arena') end
    function server.step(n) for _ = 1, (n or 4) do threads.step() end end

    --- Everything a player is carrying, as a sorted comparable string.
    function server.carrying(src)
        local names = {}
        for _, item in ipairs(inv[src] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- The metadata on the first item of that name a player is holding, or
    --- nil. `carrying` above compares names and counts, which is the whole
    --- of what most items are and none of what a phone is.
    function server.metaOf(src, name)
        for _, item in ipairs(inv[src] or {}) do
            if item.name == name then return item.metadata end
        end
        return nil
    end

    --- What is sitting in one player's arena stash, as a sorted string.
    --- The door's promise is about this side as much as the player's side.
    function server.stashed(src)
        local names = {}
        for _, item in ipairs(stashes['crimson_arena_CID' .. src] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- Puts an item straight into a player's pockets, the way a payout does
    --- on a server where cash is an ox_inventory item.
    function server.give(src, name, count)
        inv[src] = inv[src] or {}
        inv[src][#inv[src] + 1] = { name = name, count = count }
    end

    function server.log() return table.concat(console, '\n') end

    --- Makes one player's arena stash read EMPTY without emptying it.
    --- @param src integer
    --- @param on boolean?  -- default true
    function server.forgetStash(src, on)
        forgotten['crimson_arena_CID' .. src] = (on ~= false) or nil
    end

    --- Makes one inventory refuse every item offered to it, the way a full
    --- one does. `false` lets it accept again.
    function server.refuseAdds(id, on)
        refusingAdds[id] = (on ~= false) or nil
    end

    --- The metadata on the first item of that name inside a bag.
    function server.bagMetaOf(key, name)
        for _, item in ipairs(stashes[key] or {}) do
            if item.name == name then return item.metadata end
        end
        return nil
    end

    --- What is in ANY stash, by its real name -- including the bag holding
    --- stashes, which `bagContents` cannot see because that reads the
    --- container itself.
    function server.contentsOf(stash)
        local names = {}
        for _, item in ipairs(stashes[stash] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- The routing bucket a player is in right now. 0 is the open world.
    function server.bucketOf(src) return buckets[tonumber(src)] or 0 end

    --- An admin emptying a stash by hand, which is what the jam message tells
    --- them to do before clearing it.
    function server.emptyStash(stash)
        stashes[stash] = {}
    end

    --- Runs a console command, the way an operator at the server would.
    --- Source 0 is the console, which ArenaIsAdmin always accepts.
    function server.command(name, src, ...)
        local fn = commands[name]
        if not fn then error('no command registered called ' .. tostring(name), 2) end
        fn(src or 0, { ... }, name)
    end

    --- EVERY ITEM THIS WHOLE SERVER IS HOLDING, wherever it is: pockets,
    --- belongings stashes, bag-holding stashes, the insides of bags. As
    --- name -> count, so two of these can be compared.
    ---
    --- The point is conservation. A match must not be able to make an item
    --- appear or disappear, and the only way to say that with confidence is
    --- to count everything rather than the one inventory a test is looking at.
    function server.ledger()
        local total = {}
        local function add(list)
            for _, item in ipairs(list or {}) do
                if type(item) == 'table' and type(item.name) == 'string' then
                    total[item.name] = (total[item.name] or 0) + (tonumber(item.count) or 0)
                end
            end
        end
        for _, list in pairs(inv) do add(list) end
        for _, list in pairs(stashes) do add(list) end
        return total
    end

    --- Gives a player a CONTAINER item -- a police bag -- with things
    --- already in it. ox_inventory keeps a bag's contents in a separate
    --- inventory keyed by `metadata.container`; the item itself holds only
    --- the key.
    function server.giveBag(src, name, key, contents)
        containerKeys[key] = true
        livingContainers[key] = true
        inv[src] = inv[src] or {}
        inv[src][#inv[src] + 1] = { name = name, count = 1, metadata = { container = key } }
        stashes[key] = {}
        for _, entry in ipairs(contents or {}) do
            -- METADATA COMES WITH IT. An item whose identity IS its metadata
            -- -- a phone with a number, a licence with a name -- is the case
            -- a count of names cannot see, and a bag is exactly where people
            -- keep those.
            stashes[key][#stashes[key] + 1] = { name = entry[1], count = entry[2], metadata = entry[3] }
        end
    end

    --- What is in one bag right now.
    function server.bagContents(key)
        local names = {}
        for _, item in ipairs(stashes[key] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- Whether a player is carrying the bag with that key at all.
    function server.hasBag(src, key)
        for _, item in ipairs(inv[src] or {}) do
            if type(item.metadata) == 'table' and item.metadata.container == key then return true end
        end
        return false
    end

    --- ox_inventory's idle purge taking a container out of memory, and the
    --- database not giving it back. THIS IS THE DEFECT: five minutes of a
    --- round with nobody holding the bag open is all it takes.
    function server.purgeContainer(key)
        livingContainers[key] = nil
        stashes[key] = {}
    end

    --- An ox_inventory old enough to have no GetContainerFromSlot.
    function server.oldOxBuild() noContainerExport = true end

    --- Puts an item straight into a stash, the way an earlier run of this
    --- resource left one behind.
    function server.stashItem(stash, name, count)
        stashes[stash] = stashes[stash] or {}
        stashes[stash][#stashes[stash] + 1] = { name = name, count = count }
    end

    --- Puts an item into a stash AT A GIVEN POSITION, pushing everything at
    --- or after it down a slot. That is what a stash reloaded from an older
    --- database row looks like: the rows that come back are not necessarily
    --- after the ones already there.
    function server.stashItemAt(stash, index, name, count)
        stashes[stash] = stashes[stash] or {}
        table.insert(stashes[stash], index, { name = name, count = count })
    end

    --- Hands a server id to a different character, the way FiveM does when a
    --- player disconnects and the next one to connect inherits their slot.
    --- @param src integer
    --- @param citizenid string
    function server.reseat(src, citizenid)
        qbx.players[src] = {
            citizenid = citizenid,
            name = 'Newcomer' .. tostring(src),
            money = { cash = 50000, bank = 0 },
        }
        inv[src] = {}
    end

    --- Asks the swapItems hook whether one move by `src` is allowed.
    ---
    --- `source` IS THE ACTOR, and the hook reads nothing else to find them --
    --- leave it out and the hook returns true before asking any question at
    --- all, which is a green test that has driven nothing.
    --- @return boolean
    function server.mayMove(src, from, to)
        if hook == nil then error('the resource registered no swapItems hook', 2) end
        return hook({ source = src, fromInventory = from, toInventory = to, count = 1 }) ~= false
    end

    return server
end

--- What OWN looks like once server.carrying has formatted it.
local INTACT = 'ammo-rifle-apx40,burgerx3,phonex1'

--- Opens a match with everyone in it and starts it, leaving the round live
--- with every fighter stripped and issued.
--- @param ids integer[]
--- @return table server
--- @return string matchId
local function liveMatch(ids, extra, mutate)
    local server = newServer(ids, mutate, extra)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
    end
    for _, src in ipairs(ids) do
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)

    return server, match.id
end

-- ========================================================================
-- The door is actually shut
-- ========================================================================

t.test('a lobby does not touch anybody: only entering the arena does', function()
    local server = newServer({ 1, 2 })
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })

    t.equals(server.carrying(1), INTACT, 'sitting in a menu is not being in a fight')
    t.equals(server.carrying(2), INTACT)
end)

t.test('walking into the arena empties their pockets', function()
    local server = liveMatch({ 1, 2 })
    t.isFalse(server.carrying(1) == INTACT, 'they are not still carrying their own things')
    t.isTrue(isHolding(server.ammo, 1), 'and the arena owes them their kit back')
end)

-- ========================================================================
-- Every way out
-- ========================================================================

t.test('a match that finishes normally hands everything back', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
    t.isFalse(isHolding(server.ammo, 1))
end)

t.test('and it hands back THEIR phone, not a phone', function()
    -- WHAT A COUNT CANNOT SEE. Every assertion above compares names and
    -- counts -- `phonex1` before, `phonex1` after -- and that is the whole of
    -- what a burger is. It is none of what a phone is: the number, the
    -- contacts and the messages live in the item's METADATA, and an item that
    -- comes back without it is a new phone belonging to nobody.
    --
    -- To the player those two outcomes are not similar, they are opposite,
    -- and they read identically in every other test in this file. The fixture
    -- dropped metadata when it seeded a player, so the case could not be
    -- built here at all.
    local phone = { number = '555-0134', contacts = 12 }
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'phone-2', count = 1, metadata = phone } })

    t.isNil(server.metaOf(1, 'phone-2'), 'they carried it INTO the arena -- the door did not take it')

    server.match.End(matchId, 'match.ended')

    local back = server.metaOf(1, 'phone-2')
    t.isNotNil(back, 'the phone did not come back at all')
    t.equals(back.number, phone.number,
        'A PHONE CAME BACK, BUT NOT THEIRS -- the number it is known by did not survive the round')
    t.equals(back.contacts, phone.contacts, 'and what was on it did not either')
end)

-- ========================================================================
-- MONEY GOES IN LIKE EVERYTHING ELSE, AND THE PAYOUT STILL SURVIVES
--
-- TWO QUESTIONS, AND FOR A WHILE ONE SETTING ANSWERED BOTH -- wrongly, in
-- opposite directions.
--
--   ON THE WAY IN. Cash was left in a player's pockets on the reasoning that
--   it "cannot be spent in an arena and cannot be looted off a body here".
--   The second half was never true: ox_inventory drops a dead player's
--   inventory on the floor whatever this resource thinks. So a fighter walked
--   into a live round carrying every note they own and dropped the lot the
--   first time somebody shot them. It goes in the stash now, with everything
--   else -- `neverStash` ships EMPTY.
--
--   ON THE WAY OUT. The exit clears whatever a player is carrying, on the
--   reasoning that at that moment everything in their pockets belongs to the
--   arena. That stops being true before the clear runs: server/match.lua
--   settles the pot and the side-bets and only THEN sends everybody home, so
--   a winner's payout is credited into the inventory the exit is about to
--   wipe. Bank was untouched throughout, because bank is player data rather
--   than an item -- which is what made it look like cash bets specifically do
--   not pay out. `neverDestroy` is the list that keeps it, and cash stays on
--   it.
-- ========================================================================

t.test('THE REPORT: cash goes into the stash with everything else', function()
    -- IN THE OPERATOR'S WORDS: "it is not taking money out of the inventory
    -- when you start the match, so in the match I still have all my cash I
    -- had before joining -- it takes the money out for the betting but not
    -- the rest of my cash".
    --
    -- Which was true, and was the setting doing exactly what it said. The
    -- reasoning behind it -- cash "cannot be looted off a body here" -- was
    -- never true: ox_inventory drops a dead player's inventory on the floor
    -- whatever this resource thinks, so a fighter was carrying their whole
    -- wallet into a live round and dropping it the first time they died.
    local server = liveMatch({ 1, 2 }, { { name = 'money', count = 5000 } })
    local carrying = server.carrying(1)

    -- PROOF THE DOOR ACTUALLY RAN, first. Without this the test passes on a
    -- build where the door never opened, which is the one state where the
    -- pockets being empty means nothing at all.
    t.isNil(carrying:find('phonex1', 1, true),
        'the door did not run, so this test proves nothing: ' .. carrying)

    t.isTrue(server.stashed(1):find('money', 1, true) ~= nil,
        'the door left cash in the arena rather than putting it away: ' .. server.stashed(1))
    t.isNil(carrying:find('money', 1, true),
        'and it left a copy in their pockets as well, which is worse: ' .. carrying)
end)

t.test('and it comes back out again at the exit', function()
    -- The other half, and the half that matters: putting it away is only
    -- safe if it comes back. INTACT is the whole inventory these fixtures
    -- walk in with.
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'money', count = 5000 } })
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx5000', 1, true) ~= nil,
        'THE ARENA KEPT THEIR CASH -- ' .. carrying)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'and their own belongings did not come back either: ' .. carrying)
end)

t.test('and a payout is protected even when config.lua has never heard of the key', function()
    -- THE UPGRADE CASE, and it is the normal one. `neverDestroy` is new, so
    -- an operator who keeps their own config.lua across the upgrade has the
    -- inventory block WITHOUT it -- and that is exactly the person who
    -- reported the payout vanishing in the first place.
    --
    -- The default therefore has to be the safe list, not an empty one:
    -- config.lua overrides it, it does not enable it.
    local server, matchId = liveMatch({ 1, 2 }, nil,
        function(config) config.Loadouts.inventory.neverDestroy = nil end)

    -- The payout, exactly where the real one lands: after the round is
    -- decided, before the player is sent home.
    server.give(1, 'money', 7500)
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx7500', 1, true) ~= nil,
        'with no neverDestroy key the exit clear destroyed the payout: ' .. carrying)
end)

t.test('and money credited DURING a round survives the way out', function()
    -- The payout, exactly where the real one lands: after the round is
    -- decided, before the player is sent home.
    local server, matchId = liveMatch({ 1, 2 })

    server.give(1, 'money', 7500)
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx7500', 1, true) ~= nil,
        'THE PAYOUT WAS DESTROYED BY THE EXIT CLEAR -- ' .. carrying)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'and their own belongings did not come back either: ' .. carrying)
end)

t.test('leaving mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.fire('leaveMatch', 2)
    t.equals(server.carrying(2), INTACT)
end)

t.test('disconnecting mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.drop(2)
    t.equals(server.carrying(2), INTACT)
end)

t.test('an admin stopping the match hands everything back', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.Abort(matchId, 'match.aborted')

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
end)

t.test('destroying the match outright hands everything back', function()
    -- THE PATH THAT WAS BROKEN. Destroy is the last teardown and the one
    -- nothing else covers: it cleared the dispatch flag and the routing bucket
    -- and never reclaimed, so a player torn down here kept the arena kit while
    -- their real belongings sat in a stash.
    local server, matchId = liveMatch({ 1, 2 })
    server.lobby.Destroy(matchId, 'notify.match_closed')

    t.equals(server.carrying(1), INTACT, 'Destroy owes them their kit like every other exit')
    t.equals(server.carrying(2), INTACT)
end)

t.test('the resource stopping mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.stopResource()

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
end)

-- ========================================================================
-- Nothing from the match comes with them
-- ========================================================================

-- ========================================================================
-- WITH THE DOOR OFF
--
-- stripOnEntry = false is the setting where a player keeps their own
-- inventory and is simply handed the arena's kit on top of it. Nothing is
-- stashed, so nothing is restored -- which means the ONLY way the arena's
-- weapons come back is being removed by name on the way out, from the
-- record of what was issued. Every guarantee above is carried by restore();
-- none of them reaches this path.
-- ========================================================================

--- Switches the door off.
local function doorOff(config)
    config.Loadouts.inventory.stripOnEntry = false
end

--- The first shipped weapon that takes ammunition, so the arena has
--- something real to hand out and something real to take back.
local function firstArmedWeapon(config)
    for _, weapon in ipairs(config.Loadouts.weapons or {}) do
        if weapon.enabled ~= false and type(weapon.ammo) == 'table' then return weapon end
    end
    return nil
end

--- A live round with the door OFF and everybody actually carrying a weapon
--- the arena issued. liveMatch above readies people straight away, which
--- leaves them on an empty loadout -- and an empty loadout would make every
--- assertion below pass for the wrong reason.
--- @param ids integer[]
--- @return table server
--- @return string matchId
local function armedDoorOffMatch(ids)
    local server = newServer(ids, doorOff)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    local weapon = firstArmedWeapon(server.env.Config)
    t.isNotNil(weapon, 'no shipped weapon takes ammunition, so this proves nothing')

    for index = 2, #ids do server.fire('joinMatch', ids[index], { matchId = match.id }) end
    for _, src in ipairs(ids) do
        server.fire('setLoadout', src, { weapons = { { key = weapon.key, ammo = 60 } }, armor = 0 })
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)

    return server, match.id
end

t.test('with the door off a fighter keeps their own things and gains the arena kit', function()
    -- The premise, asserted so the tests below cannot pass by the arena
    -- quietly having issued nothing.
    local server = armedDoorOffMatch({ 1, 2 })

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'the door was shut after all -- their own things were taken')
    t.isTrue(carrying ~= INTACT,
        ('the arena issued nothing, so there is nothing to take back: %s'):format(carrying))
end)

t.test('DEFECT: and a finished match takes the arena kit back off them', function()
    -- ArenaAmmo.Clear drops the match's rows from `issuedWeapons` and
    -- `issuedAmmo`, and those rows ARE the list of names the exit removes.
    -- End called it BEFORE sending anybody out, so by the time the exit ran
    -- there was nothing left to remove -- and every fighter walked away
    -- still holding the arena's weapon and its ammunition. A free gun per
    -- round, per player, on a resource whose stated promise is that a match
    -- cannot cost or pay anyone anything.
    --
    -- Abort has always had the two in the right order. End did not.
    local server, matchId = armedDoorOffMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(4)

    t.equals(server.carrying(1), INTACT,
        ('player 1 left a finished match carrying %s'):format(server.carrying(1)))
    t.equals(server.carrying(2), INTACT,
        ('player 2 left a finished match carrying %s'):format(server.carrying(2)))
end)

t.test('and two rounds in a row do not stack two kits on them', function()
    -- The observable form of the same defect, and the one a player would
    -- notice: it compounds.
    local server, first = armedDoorOffMatch({ 1, 2 })
    server.match.End(first, 'match.ended')
    server.step(4)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = second.id })
    local weapon = firstArmedWeapon(server.env.Config)
    for _, src in ipairs({ 1, 2 }) do
        server.fire('setLoadout', src, { weapons = { { key = weapon.key, ammo = 60 } }, armor = 0 })
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)
    server.match.End(second.id, 'match.ended')
    server.step(4)

    t.equals(server.carrying(1), INTACT,
        ('after two rounds player 1 is carrying %s'):format(server.carrying(1)))
end)

t.test('and the match stops being owed anything once everyone is out', function()
    -- The bookkeeping half. Clearing the records is right -- it just has to
    -- happen after the reclaims that read them, not before.
    local server, matchId = armedDoorOffMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(4)

    -- ASSERTED ON THE KIT RECORD AND NOTHING ELSE, because the other probe
    -- is gone. ArenaAmmo.OnLoan summed a second scalar ledger that was never
    -- decremented when the arena took anything back -- it reported
    -- cumulative-issued, not outstanding -- and 2fec9fe deleted the function
    -- and the ledger together.
    t.isFalse(isHolding(server.ammo, 1), 'the arena still thinks it owes player 1 a kit')
end)

t.test('nothing looted inside the arena leaves with them', function()
    local server, matchId = liveMatch({ 1, 2 })

    -- They kill somebody and take everything the body was carrying, including
    -- an item they own plenty of themselves.
    server.env.exports.ox_inventory:AddItem(2, 'ammo-rifle-ap', 500)
    server.env.exports.ox_inventory:AddItem(2, 'gold-bar', 9)

    server.match.End(matchId, 'match.ended')
    t.equals(server.carrying(2), INTACT, 'exactly what they walked in with, and only that')
end)

t.test('an item they own plenty of is returned at the number they had', function()
    -- ammo-rifle-ap is in OWN *and* is an arena round. Returning "what we
    -- issued, minus what came back" would get this one wrong in both
    -- directions; returning the stash gets it right by construction.
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')

    t.isTrue(server.carrying(1):find('ammo%-rifle%-apx40') ~= nil,
        'forty, not forty plus whatever the arena issued, and not zero')
end)

t.test('two rounds in a row leave them exactly as they started', function()
    local server = newServer({ 1, 2 })
    for _ = 1, 2 do
        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)
        server.match.End(match.id, 'match.ended')
    end

    t.equals(server.carrying(1), INTACT, 'nothing accumulates across matches')
    t.equals(server.carrying(2), INTACT)
end)

print('doorguarantee_spec')
-- ========================================================================
-- A STASH THAT READS EMPTY IS NOT A STASH THAT WAS EMPTY
--
-- ox_inventory answers the same empty list for both, and the second is what
-- a forgotten or re-registered stash looks like: a resource restart, a
-- database hiccup, a row that came back under a different name. So an exit
-- that trusted the answer reported a clean return of nothing, dropped the
-- record, cleared the debt and left the player with empty pockets while every
-- log in the file said the exit had gone perfectly.
--
-- The exit learned to tell them apart by counting what went IN. These are
-- about everything that happens AFTER it does.
-- ========================================================================

t.test('THE BUG: the retry undid the exit\'s guard about thirty seconds later', function()
    -- restore() refuses to call an empty read a clean return, keeps the
    -- record, writes the debt and tells the player their kit is safe and
    -- still being chased. ArenaAmmo.ReturnLeftovers is the only thing that
    -- chases it -- and it had no such check, so the very next pass of the
    -- sweep read the same nothing, called it settled, and deleted every
    -- record the retry works from. The promise lasted one sweep interval.
    local server, matchId = liveMatch({ 1, 2 })
    t.isTrue(isHolding(server.ammo, 1), 'nothing was stashed, so this proves nothing')

    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    t.equals(server.ammo.Owed(), 1, 'the exit did not record the debt it could not settle')

    -- The sweep, over and over, exactly as the retry thread runs it.
    for _ = 1, 5 do server.ammo.SweepReturns() end

    t.equals(server.ammo.Owed(), 1,
        'the retry declared the debt settled off a read that returned nothing')
    t.isTrue(isHolding(server.ammo, 1),
        'the retry dropped the record, so nothing is left pointing at the stash')
end)

t.test('and the moment the stash can be read again, everything comes back', function()
    -- The point of keeping the debt: the stash is a REAL one and its contents
    -- were never in doubt. Nothing is lost, it is only unreachable -- and the
    -- retry has to still be trying when it stops being.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    for _ = 1, 3 do server.ammo.SweepReturns() end

    server.forgetStash(1, false)
    server.ammo.SweepReturns()

    t.equals(server.carrying(1), INTACT, 'their own things did not come back')
    t.equals(server.ammo.Owed(), 0, 'the debt was not settled once it actually could be')
    t.isFalse(isHolding(server.ammo, 1), 'and the record was not dropped afterwards')
end)

t.test('and it is still THEIR phone when it comes back late', function()
    -- THE CLOSEST THING THIS SANDBOX HAS TO THE REPORTED SYMPTOM. A phone
    -- that returns immediately is one thing; the case worth checking is the
    -- one where the hand-back could not happen at the exit and the kit comes
    -- back on a later sweep instead. That is a player who finished a match,
    -- found nothing in their pockets, and got their things minutes later --
    -- and if the identity is lost on that path, what arrives is a stranger's
    -- phone with their name on the label.
    --
    -- It is the same handBack either way, so this ought to hold. Ought is not
    -- the same as does, and the test above only ever compared counts.
    local phone = { number = '555-0134', contacts = 12 }
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'phone-2', count = 1, metadata = phone } })

    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    for _ = 1, 3 do server.ammo.SweepReturns() end
    t.isNil(server.metaOf(1, 'phone-2'), 'it came back while the stash was unreadable, so this proves nothing')

    server.forgetStash(1, false)
    server.ammo.SweepReturns()

    local back = server.metaOf(1, 'phone-2')
    t.isNotNil(back, 'the phone never came back at all on the late path')
    t.equals(back.number, phone.number,
        'THE LATE RETURN HANDED BACK A PHONE THAT IS NOT THEIRS -- the number did not survive the wait')
    t.equals(back.contacts, phone.contacts, 'and what was on it did not either')
end)

t.test('and a stash that really IS empty still settles cleanly', function()
    -- The guard must not turn every ordinary exit into a permanent debt. A
    -- player who walked in owning nothing stashes nothing, so there is no
    -- count to disagree with the empty read and nothing to keep chasing.
    local server = newServer({ 1, 2 })
    server.env.Config.Loadouts.inventory.stripOnEntry = true
    -- Emptied before they ever go near the door.
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })

    for _ = 1, 4 do server.ammo.SweepReturns() end
    t.equals(server.ammo.Owed(), 0, 'somebody who owns nothing was recorded as owed something')
end)

t.test('THE BUG: re-entering with empty pockets erased the debt outright', function()
    -- The record's count is the one fact that can tell the two empties apart,
    -- and ArenaAmmo.Issue wrote the NEW entry's count straight over it. A
    -- player whose exit failed walks back in carrying nothing -- because the
    -- failed exit is exactly why they have nothing -- so the count went to
    -- zero, the guard was disarmed for the one player it was written for, and
    -- the next exit read empty, called it clean, and forgot the lot.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    t.equals(server.ammo.Owed(), 1, 'the first exit did not leave a debt to erase')

    -- STRAIGHT BACK IN, with the pockets the failed exit left them: empty.
    -- The stash can be read again by now, but it does not matter -- what is
    -- being asserted is that the second round cannot erase the first round's
    -- debt on its way past.
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second = server.lobby.All()[1]
    t.isNotNil(second, 'the second lobby never opened')
    server.fire('joinMatch', 2, { matchId = second.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(second.id, 'match.ended')

    t.equals(server.ammo.Owed(), 1,
        'a second round erased a debt from the first -- their belongings are in a '
        .. 'real stash with nothing in this resource left pointing at it')
end)

-- ========================================================================
-- A SERVER ID IS NOT A PERSON
--
-- `stashed` is keyed by server id, and a record is KEPT on purpose when an
-- exit could not finish -- so it outlives its owner's disconnect, and FiveM
-- hands that id to whoever connects next.
-- ========================================================================

t.test('THE BUG: a stranded record froze the NEXT player on that id out of every stash', function()
    -- The swapItems guard reads that table to decide who is "in the arena".
    -- Read raw, the newcomer was refused every inventory move they made
    -- anywhere on the map -- their own house stash, a glovebox, a shop, an
    -- item handed to a friend -- with the arena's own "you fight with what
    -- you were issued" line explaining it, and nothing able to clear it: the
    -- sweep that would have is gated on the same table.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    t.isTrue(isHolding(server.ammo, 1), 'the record was not kept, so there is nothing stranded')

    server.drop(1)
    server.reseat(1, 'CID_NEWCOMER')

    t.isTrue(server.mayMove(1, 1, 'house_stash_newcomer'),
        'the newcomer cannot put anything into their own stash')
    t.isTrue(server.mayMove(1, 'house_stash_newcomer', 1),
        'the newcomer cannot take anything out of their own stash')
end)

t.test('and the sweep will still look at that newcomer', function()
    -- worthTrying reads the same table for the same reason, so the one player
    -- who most needed a look -- the new arrival inheriting a stranded id --
    -- was the one player it would never take.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    server.drop(1)
    server.reseat(1, 'CID_NEWCOMER')

    -- Something of theirs really is in their own arena stash, from an earlier
    -- life this run knows nothing about.
    server.stashItem('crimson_arena_CID_NEWCOMER', 'phone', 1)
    server.ammo.SweepReturns()

    t.isTrue(server.carrying(1):find('phone', 1, true) ~= nil,
        'the sweep skipped the newcomer because somebody else\'s record sat on their id')
end)

t.test('THE LOCKOUT: a stranded record must not follow them round the map', function()
    -- The worst thing this session nearly shipped, and it was a regression
    -- inside a fix.
    --
    -- A record is KEPT when an exit cannot empty the stash, and the read-empty
    -- guard keeps the debt written -- so that record is never settled and
    -- never dropped. The swapItems guard read it as "this player is in the
    -- arena", so from that moment every inventory move they made ANYWHERE was
    -- refused: their own house stash, a glovebox, a shop, handing a friend an
    -- item. For the rest of the session, through a reconnect, standing
    -- nowhere near an arena, with the arena's own line explaining it.
    --
    -- Their belongings being stuck is the problem this player already has.
    -- Being unable to touch anything they own for the rest of the night is a
    -- second one nobody asked for.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    t.isTrue(isHolding(server.ammo, 1), 'the record was not kept, so this proves nothing')
    t.equals(server.ammo.Owed(), 1, 'and the debt was not written')

    t.isTrue(server.mayMove(1, 1, 'house_stash_theirs'),
        'a player whose arena stash could not be read cannot put anything in their own')
    t.isTrue(server.mayMove(1, 'house_stash_theirs', 1),
        'nor take anything out of it')
    t.isTrue(server.mayMove(1, 1, 'a_friend'),
        'nor hand a friend an item, anywhere on the map')
end)

t.test('and the sweep still comes back for them', function()
    -- The debt is what brings it back, and it must survive the narrowing
    -- above: freeing the player must not mean forgetting the stash.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    for _ = 1, 3 do server.ammo.SweepReturns() end
    t.equals(server.ammo.Owed(), 1, 'the debt was dropped along with the lockout')

    server.forgetStash(1, false)
    server.ammo.SweepReturns()
    t.equals(server.carrying(1), INTACT, 'and their things never came back')
end)

t.test('and a fighter who is genuinely mid-round is still refused', function()
    -- The narrowing must not switch the guard off. The record belongs to the
    -- person sitting on that id, so it still speaks for them.
    local server = liveMatch({ 1, 2 })
    t.isFalse(server.mayMove(1, 1, 'some_other_stash'),
        'a fighter can empty the arena kit into a stash mid-round')
    t.isFalse(server.mayMove(1, 'a_corpse', 1),
        'a fighter can loot into their own pockets mid-round')
end)

-- ======================================================================
-- NOT TAKING SOMETHING IS NOT PERMISSION TO DESTROY IT
-- ======================================================================
--
-- The door has two lists and they were independent:
--
--   neverStash    "leave this in their pockets on the way in"
--   neverDestroy  "the exit's clear must not wipe this"
--
-- Which left a hole exactly the size of the difference between them. An item
-- on the first list and not the second was carried, unprotected, through the
-- whole round -- and then met the wholesale clear at the exit, which keeps
-- only what the SECOND list names. The arena destroyed the one thing it had
-- promised not to touch.
--
-- The only warning was a clause in a config comment. An operator naming an
-- item they did not want the arena taking had to know to name it again, in a
-- different list, under a different heading, to stop the arena destroying it
-- instead.

t.test('THE REPORT: an item the door was told to leave alone was wiped at the exit',
    function()
        local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
            -- Named on one list and not the other, which is the whole of it.
            config.Loadouts.inventory.neverStash = { 'phone' }
            config.Loadouts.inventory.neverDestroy = { 'money' }
        end)

        -- It never went to the stash, which is what the operator asked for.
        t.isNil(server.stashed(1):find('phone', 1, true),
            'the door stashed an item it was told to leave in their pockets: '
                .. server.stashed(1))

        server.match.End(matchId, 'match.ended')

        local carrying = server.carrying(1)
        t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
            'THE ARENA DESTROYED IT. It was never stashed, so there was nothing to hand '
                .. 'back -- and the exit clear wiped it where it sat: ' .. carrying)
    end)

t.test('and the clear still ran, in the same round, over the same fighter', function()
    -- THE PAIR THE FIX HAS TO SATISFY AT ONCE, asserted in one fixture
    -- rather than two. Its first version checked only that an UNNAMED item
    -- survived a round -- which is what happens if the exit stops clearing
    -- anything at all, so the control passed on exactly the fix it was
    -- written to catch.
    --
    -- Named and unnamed, side by side: the phone is protected, and something
    -- the arena handed over in the same round is not.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'phone' }
    end)

    server.give(1, 'ammo-9', 120)

    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'the protected item did not survive: ' .. carrying)
    t.isNil(carrying:find('ammo-9', 1, true),
        'and the clear did not run at all, so the protection above means nothing: ' .. carrying)
end)

t.test('and the arena kit is still destroyed, which is what the clear is for', function()
    -- The other control. `neverStash` growing must not become a way to keep
    -- the weapons the arena issued -- those are the whole reason the exit
    -- clears anything.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'phone' }
    end)

    -- Something the ARENA gave them, arriving mid-round the way a kill
    -- payment does.
    server.give(1, 'ammo-9', 250)

    server.match.End(matchId, 'match.ended')

    t.isNil(server.carrying(1):find('ammo-9', 1, true),
        'the exit let a fighter walk out with the arena\'s own ammunition: '
            .. server.carrying(1))
end)

t.test('AND `neverStash` CANNOT BE USED TO WALK OUT WITH THE KIT', function()
    -- The hole the rule above opened, and the reason it is not a plain
    -- merge. `neverStash` protects a name from the exit's clear -- so
    -- naming something the ARENA issues would keep it: `armour`, `ammo-9`,
    -- a weapon. And the exit would still report a clean wipe, so the arena
    -- forgets it ever issued one. No debt, no sweep, no retry. Two hundred
    -- rounds a round, for ever, out of one line of config.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'armour', 'bandage' }
    end)

    -- Issued mid-round, the way a kill payment or a respawn refresh arrives.
    server.give(1, 'armour', 1)
    server.give(1, 'bandage', 2)

    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isNil(carrying:find('armour', 1, true),
        'a fighter walked out wearing the arena\'s own plate: ' .. carrying)
    t.isNil(carrying:find('bandage', 1, true),
        'and carrying its bandages: ' .. carrying)
end)

t.test('and the same names still reach the stash, so nobody loses their own', function()
    -- The kindest of the three things that could happen to an operator's
    -- mistake. Refusing only the exit half would leave a player's OWN plate
    -- in their pockets for the round and then destroy it at the door -- a
    -- worse outcome than the setting they were reaching for. The name is
    -- ignored on both halves instead, so the item takes the ordinary path.
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.neverStash = { 'armour' }
    end, { { name = 'armour', count = 3 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    for _, src in ipairs({ 1, 2 }) do server.fire('setReady', src, { ready = true }) end
    server.match.Start(match.id)
    server.step()

    t.isTrue(server.stashed(1):find('armour', 1, true) ~= nil,
        'the fighter\'s own plate was left in their pockets to be destroyed: '
            .. server.stashed(1))

    server.match.End(match.id, 'match.ended')

    t.isTrue(server.carrying(1):find('armourx3', 1, true) ~= nil,
        'and it did not come back: ' .. server.carrying(1))
end)

-- ========================================================================
-- MORE IN THE STASH THAN THE DOOR PUT IN IT
--
-- The exit handed over WHATEVER was in the belongings stash. Nothing asked
-- whether the stash was still holding what the door left there, and things
-- get into it: ox_inventory throws an idle inventory out of memory after
-- `inventory:cleartime` (five minutes by default) and reloads it from the
-- database on the next touch, so any round longer than that round-trips
-- these belongings through a row that may not have had the last write. It is
-- also a real stash with a predictable name that an admin tool or another
-- resource can write to.
--
-- Reported off a live server as a match "duplicating the items they had and
-- didn't have", and that is exactly what it produced here.
-- ========================================================================

t.test('DEFECT: rows that appear in the stash mid-round are NOT handed over', function()
    local server, matchId = liveMatch({ 1, 2 })

    -- An older snapshot of this same stash coming back, which is what a
    -- reload from a stale row looks like -- two of what they own and one
    -- thing they never did.
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.stashItem('crimson_arena_CID1', 'burger', 3)
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT,
        'THEY WALKED OUT WITH TWO OF EVERYTHING AND A LOCKPICK THEY NEVER OWNED')
    t.equals(server.stashed(1), 'burgerx3,lockpickx2,phonex1',
        'the surplus was not left where an admin can settle it')
    t.contains(server.log(), 'appeared while',
        'it handed back only what it took and said nothing about the rest')
end)

-- The assertion above is also what holds the CHOICE of refused rows: the
-- three stale rows land after the player's own, and a ceiling that simply
-- kept the first `allowed` in slot order refused the player's rifle ammo and
-- handed them a lockpick instead. Measured by inverting the ordering alone:
-- `burgerx3,lockpickx2,phonex1`.

t.test('and the sweep does not come back and hand the surplus over a tick later', function()
    -- ArenaAmmo.ReturnLeftovers is UNCAPPED on purpose -- after a restart
    -- nothing knows what went into a stash, and a ceiling of zero there
    -- would refuse a player their whole kit. So refusing the rows and
    -- leaving them lying there was not enough on its own: the sweep
    -- collected the exact rows the exit had just refused. The refusal shuts
    -- the stash, which is what makes it stick.
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')

    for _ = 1, 6 do server.step(8) end

    t.equals(server.carrying(1), INTACT, 'the sweep handed over what the exit refused')
    t.equals(server.stashed(1), 'phonex1', 'and the surplus is still there to be settled')
end)

t.test('CONTROL: the leftovers of an earlier exit that could not finish still come back', function()
    -- THE REGRESSION THIS CEILING COULD CAUSE, and it is the unforgivable
    -- one. A stash can already have things in it when the door shuts -- an
    -- exit that could not finish leaves them there on purpose, and they are
    -- the player's. stow() counts them, so they are INSIDE the ceiling.
    -- Without that this test fails and somebody loses their property.
    local server = newServer({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), 'ammo-rifle-apx40,burgerx3,lockpickx2,phonex1',
        'a player lost belongings that were legitimately waiting in their stash')
    t.equals(server.stashed(1), '', 'and the stash was not emptied')
end)

t.test('CONTROL: an ordinary round is untouched by any of this', function()
    -- Without this the three above pass on a build that simply refuses
    -- everything, which is worse than the defect.
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT)
    t.equals(server.stashed(1), '')
    t.isNil(server.log():find('appeared while', 1, true),
        'it refused something on a round where nothing appeared')
end)

t.test('CONTROL: a stash that reads EMPTY the instant after it is filled is not a ceiling of zero', function()
    -- THE TRAP THIS FILE IS BUILT AROUND, aimed at the new ceiling. A stash
    -- ox_inventory has not loaded answers an EMPTY list rather than an
    -- error, and reading the ceiling off the stash alone would therefore set
    -- it to zero for exactly that case -- and a ceiling of zero refuses the
    -- player their entire kit at the exit. The count is kept as the floor
    -- for this reason and no other.
    local server = newServer({ 1, 2 })
    server.forgetStash(1)          -- it fills, and every read of it says empty

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.forgetStash(1, false)   -- ox loads it again, and it was full all along

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT, 'A PLAYER WAS REFUSED THEIR OWN BELONGINGS')
    t.isNil(server.log():find('appeared while', 1, true),
        'it called their own kit a surplus and shut the stash on them')
end)

-- ========================================================================
-- THE POLICE BAG, WHICH CAME BACK EMPTY
--
-- A container item does not carry its contents in its metadata. ox_inventory
-- keeps them in a SEPARATE inventory keyed by metadata.container, and the bag
-- holds nothing but that key. So stashing the bag stashes a REFERENCE -- and
-- that inventory is never open and never a player, which puts it in the same
-- five-minute idle purge as everything else. Written out, dropped, and read
-- back from the database on the next touch; if that does not come back, the
-- bag returns with nothing in it.
--
-- The arena now holds the contents itself for the length of the round.
-- ========================================================================

local BAG = 'police_bag'
local KEY = 'bagkey123'

--- A round fought by somebody carrying a packed bag.
local function roundWithBag(contents)
    local server = newServer({ 1, 2 })
    server.giveBag(1, BAG, KEY, contents or { { 'radio', 1 }, { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    return server, match.id
end

t.test('DEFECT: a bag whose container is purged mid-round still comes back packed', function()
    local server, matchId = roundWithBag()

    -- Five minutes into the round, with nobody holding the bag open.
    server.purgeContainer(KEY)

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.isTrue(server.hasBag(1, KEY), 'they did not get their bag back at all')
    t.equals(server.bagContents(KEY), 'handcuffsx2,radiox1',
        'THE BAG CAME BACK EMPTY -- its contents were never in the arena\'s keeping')
end)

t.test('and the contents are in the BAG, not loose in their pockets', function()
    local server, matchId = roundWithBag()
    server.purgeContainer(KEY)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    -- INTACT is what they own outside the bag. Anything from inside it
    -- turning up here means the exit unpacked their bag for them.
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1',
        'the bag contents were tipped into their pockets instead of put back')
end)

t.test('CONTROL: an ordinary round with a bag changes nothing about it', function()
    -- Without this the tests above pass on a build that hands out contents
    -- from nowhere. Nothing is purged here: the bag must come back exactly
    -- as it went in, with no extra copies anywhere.
    local server, matchId = roundWithBag()
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.bagContents(KEY), 'handcuffsx2,radiox1', 'the bag came back wrong')
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1', 'they gained or lost something')
    t.equals(server.stashed(1), '', 'and the belongings stash was left holding something')
end)

t.test('CONTROL: an empty bag is left alone entirely', function()
    local server, matchId = roundWithBag({})
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.bagContents(KEY), '')
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1')
end)

t.test('CONTROL: with emptyContainers off the bag travels as it always did', function()
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.emptyContainers = false
    end)
    server.giveBag(1, BAG, KEY, { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    -- The arena never took them, so a purge still costs them -- which is the
    -- behaviour an operator is choosing when they turn this off.
    server.purgeContainer(KEY)
    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.isTrue(server.hasBag(1, KEY), 'they lost the bag itself, which is not what off means')
    t.equals(server.bagContents(KEY), '', 'the arena held contents it was told not to touch')
end)

t.test('CONTROL: an ox_inventory with no GetContainerFromSlot costs nothing', function()
    -- The export is not on every build. A server without it keeps the
    -- behaviour it has always had, and above all the door still works.
    local server = newServer({ 1, 2 })
    server.oldOxBuild()
    server.giveBag(1, BAG, KEY, { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1', 'the door stopped working on an older build')
    t.equals(server.bagContents(KEY), 'radiox1', 'it lost a bag it could not reach into')
end)

--- Anything the arena itself issues, which is legitimately created at the
--- door and destroyed at the exit. Conservation is asserted over everything
--- else -- the things players actually own.
local function ownedOnly(ledger, issued)
    local out = {}
    for name, count in pairs(ledger) do
        if not issued[name] then out[name] = count end
    end
    return out
end

local function ledgerDiff(before, after)
    local lines = {}
    local seen = {}
    for name in pairs(before) do seen[name] = true end
    for name in pairs(after) do seen[name] = true end
    local names = {}
    for name in pairs(seen) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local was, now = before[name] or 0, after[name] or 0
        if was ~= now then
            lines[#lines + 1] = ('%s %d -> %d'):format(name, was, now)
        end
    end
    return table.concat(lines, '; ')
end

t.test('A WHOLE MATCH CONSERVES WHAT PLAYERS OWN, on every way out of one', function()
    -- THE GENERAL FORM OF EVERY DUPLICATION DEFECT IN THIS FILE, asserted
    -- rather than reasoned about: count every item this server is holding --
    -- pockets, belongings stashes, bag-holding stashes, the insides of bags
    -- -- before a match and after it, and nothing players own may have
    -- appeared or gone. Anything the ARENA issues is excluded: that is
    -- created at the door and destroyed at the exit on purpose.
    --
    -- It is deliberately not about one inventory. The defects this file has
    -- had were all of the shape "it is in two places now", and only a total
    -- can see that.
    local shapes = {
        ['a match that ends normally'] = function(server, matchId)
            server.match.End(matchId, 'match.ended')
        end,
        ['a fighter leaving mid-round'] = function(server)
            server.fire('leaveMatch', 2)
        end,
        ['a fighter disconnecting'] = function(server)
            server.drop(2)
        end,
        ['the resource stopping mid-round'] = function(server)
            server.stopResource()
        end,
    }

    for label, finish in pairs(shapes) do
        local server = newServer({ 1, 2 })
        server.giveBag(1, 'police_bag', 'k_' .. #label, { { 'radio', 1 } })

        local issued = {}
        local before = server.ledger()

        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)

        -- Whatever the arena handed out during placement is its own and is
        -- meant to vanish at the exit; conservation is about the rest.
        for name in pairs(server.ledger()) do
            if before[name] == nil then issued[name] = true end
        end

        finish(server, match.id)
        server.step(10)

        local diff = ledgerDiff(ownedOnly(before, issued), ownedOnly(server.ledger(), issued))
        t.equals(diff, '', ('%s did not conserve what players own'):format(label))
    end
end)

-- ========================================================================
-- A JAM IS ONLY USEFUL IF SOMEBODY CAN CLEAR IT
--
-- Three failures in server/ammo.lua stop the door touching a stash: a
-- rollback that could not be undone, a hand-back whose removal was refused,
-- and a stash holding more than the door put in it. All three print "settle
-- it by hand" -- and there was nothing to run afterwards to say the settling
-- was done. The flag lived and died with the resource, so following the
-- instructions exactly still left the stash dead, and that player was never
-- stripped at the door again for the rest of the server's uptime.
-- ========================================================================

--- Plays a round that leaves player 1's belongings stash jammed, with a
--- surplus parked in it.
local function jammedBySurplus()
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)
    t.contains(server.log(), 'touching that stash no further', 'the fixture did not jam anything')
    return server
end

--- Runs one more round and answers whether the door stripped player 1.
--- Stripped means their own things are no longer in their pockets, which is
--- the only observable that tells a cleared jam from a standing one.
local function strippedNextRound(server)
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    return server.carrying(1):find('burgerx3', 1, true) == nil
end

t.test('a jammed stash is listed, with what is still in it', function()
    local server = jammedBySurplus()

    server.command('arenaunjam', 0)

    t.contains(server.log(), 'crimson_arena_CID1')
    t.contains(server.log(), 'STILL IN IT',
        'the listing did not say the stash has things in it, which is the whole decision')
end)

t.test('DEFECT: clearing a jam on a stash that still holds something is REFUSED', function()
    -- THE FOOT-GUN, found by attacking this command rather than by a report.
    -- A jam means the arena parked rows it could not account for. Clearing it
    -- without emptying the stash puts every one of them back inside the next
    -- ceiling, and the next exit hands them over -- the exact duplication the
    -- jam was protecting against. An operator running this to tidy a noisy
    -- console would have done that to every parked surplus at once.
    local server = jammedBySurplus()

    server.command('arenaunjam', 0, 'crimson_arena_CID1')

    t.isNil(server.log():find('no longer held back', 1, true), 'it cleared a stash that still had a surplus in it')
    t.contains(server.log(), 'duplication the jam was protecting against')
    t.isFalse(strippedNextRound(server), 'the jam cleared anyway, so the surplus is live again')
end)

t.test('and once it has been settled by hand, it clears and the door uses it again', function()
    local server = jammedBySurplus()

    server.emptyStash('crimson_arena_CID1')      -- the admin took the surplus out
    server.command('arenaunjam', 0, 'crimson_arena_CID1')

    t.contains(server.log(), 'no longer held back')
    t.isTrue(strippedNextRound(server), 'the door still refuses to strip them, so the jam never cleared')
end)

t.test('and `force` clears one that still holds something, for an operator who has checked', function()
    -- The escape hatch has to exist -- sometimes what is in there really is
    -- theirs -- but it has to be said out loud rather than be the default.
    local server = jammedBySurplus()

    server.command('arenaunjam', 0, 'crimson_arena_CID1', 'force')

    t.contains(server.log(), 'no longer held back')
    t.isTrue(strippedNextRound(server), 'even force did not clear it')
end)

t.test('and a jam that has not been cleared still holds', function()
    -- The control: listing must not clear anything by itself, and neither
    -- must a name that is not jammed.
    local server = jammedBySurplus()

    server.command('arenaunjam', 0)
    server.command('arenaunjam', 0, 'crimson_arena_CID9')

    t.isFalse(strippedNextRound(server), 'the jam cleared itself')
end)

t.test('and a player who is not an admin cannot clear one', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    -- 1 is a player, not the console, and holds no admin group here.
    server.command('arenaunjam', 1, 'crimson_arena_CID1')

    t.isNil(server.log():find('no longer held back', 1, true),
        'a player cleared a jam on their own stash')
end)

t.test('two players with their own bags never get each other\'s contents', function()
    -- The holding stash is named from the CONTAINER, not the player, and it
    -- is owned by the character -- both halves of that matter. Registered
    -- shared, or named from anything two players could collide on, this is
    -- where it would show.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })
    server.giveBag(2, 'police_bag', 'k2', { { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.purgeContainer('k1')
    server.purgeContainer('k2')
    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.bagContents('k1'), 'radiox1', 'one player\'s bag came back with the wrong things in it')
    t.equals(server.bagContents('k2'), 'handcuffsx2')
end)

t.test('and a bag survives two rounds back to back', function()
    -- The second round finds the bag EMPTY at the door, because the first
    -- round put its contents back a moment earlier. Nothing to hold means
    -- nothing to give back, and a refill that fired anyway on a stale list
    -- would duplicate.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'bagkey123', { { 'radio', 1 } })

    for _ = 1, 2 do
        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)
        server.purgeContainer('bagkey123')
        server.match.End(match.id, 'match.ended')
        server.step(8)
    end

    t.equals(server.bagContents('bagkey123'), 'radiox1', 'the bag did not survive two rounds')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1', 'something accumulated across the two rounds')
end)

-- ========================================================================
-- TWO MATCHES AT ONCE
--
-- Every test above this point runs ONE round. The door, the belongings
-- stash, the bag holding stashes and the routing buckets are all keyed
-- per-player or per-match, and "keyed per X" is a claim that only a second
-- X can test. This section runs two rounds at two arenas at the same time
-- and asks whether either one can cost the other anything.
-- ========================================================================

--- Opens a match at `arenaKey` with `ids`, readies everybody and steps until
--- the fighters are placed. Returns the match id.
local function roundAt(server, arenaKey, ids)
    server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })

    local match
    for _, candidate in ipairs(server.lobby.All()) do
        if candidate.arenaKey == arenaKey then match = candidate end
    end
    t.isNotNil(match, ('no lobby opened at %s'):format(arenaKey))

    for n = 2, #ids do server.fire('joinMatch', ids[n], { matchId = match.id }) end
    for _, src in ipairs(ids) do server.fire('setReady', src, { ready = true }) end
    server.step(6)
    return match.id
end

t.test('two matches at once get their own instances, and nobody is left in the world', function()
    local server = newServer({ 1, 2, 3, 4 })

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    local bucketA, bucketB = server.bucketOf(1), server.bucketOf(3)

    t.isTrue(bucketA > 0, 'the first match was fought in the open world')
    t.isTrue(bucketB > 0, 'the second match was fought in the open world')
    t.isFalse(bucketA == bucketB, 'BOTH MATCHES ARE IN THE SAME INSTANCE -- they can see and shoot each other')
    t.equals(server.bucketOf(2), bucketA, 'a fighter was left out of their own match\'s instance')
    t.equals(server.bucketOf(4), bucketB)

    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(10)

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        t.equals(server.bucketOf(src), 0, ('%d was left behind in an arena instance'):format(src))
    end
end)

t.test('and one match ending does not touch the other', function()
    -- A SLOW CLOCK, because this test needs match B to still be running when
    -- it looks. The fixture's default jumps GetGameTimer a whole minute per
    -- call, so B's round timer expires within a couple of steps and "B lost
    -- its instance" would really be "B finished".
    local server = newServer({ 1, 2, 3, 4 }, nil, nil, { tickMs = 10 })

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })
    local bucketB = server.bucketOf(3)

    server.match.End(a, 'match.ended')

    -- TWO STEPS, NOT EIGHT, AND THE NUMBER IS THE TEST'S OWN LIMIT RATHER
    -- THAN THE CODE'S. The round thread counts resumes, not milliseconds, so
    -- any match left running in this fixture finishes within about three
    -- steps whatever the clock says. That is a clean, correct end -- the
    -- fighters get everything back, which the checks below the section prove
    -- -- but it means "B is still live" is only askable in this window.
    server.step(2)

    t.equals(server.lobby.Get(b).state, 'live', 'the fixture ended B on its own before the test looked')

    -- The finished match's fighters are home with their own things...
    t.equals(server.carrying(1), INTACT, 'the finished match did not hand everything back')
    t.equals(server.bucketOf(1), 0)

    -- ...and the live one is untouched: still instanced, still stripped.
    t.equals(server.bucketOf(3), bucketB, 'the live match lost its instance when the other one ended')
    t.isNil(server.carrying(3):find('burgerx3', 1, true),
        'the live match\'s fighter got their own kit back mid-round')
    t.equals(server.stashed(3), 'ammo-rifle-apx40,burgerx3,phonex1',
        'the live match\'s belongings were emptied out of their stash by the other match ending')
end)

t.test('four players with four bags, two matches, every bag comes back its own', function()
    local server = newServer({ 1, 2, 3, 4 })
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        server.giveBag(src, 'police_bag', 'k' .. src, { { 'radio', src } })
    end

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    -- Five minutes pass in both instances and every container is dropped.
    for _, src in ipairs({ 1, 2, 3, 4 }) do server.purgeContainer('k' .. src) end

    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(12)

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        t.equals(server.bagContents('k' .. src), 'radiox' .. src,
            ('%d\'s bag came back with the wrong things in it'):format(src))
        t.equals(server.carrying(src), INTACT .. ',police_bagx1',
            ('%d did not come out with exactly their own things'):format(src))
    end
end)

t.test('a disconnect out of one match leaves the other match alone', function()
    local server = newServer({ 1, 2, 3, 4 }, nil, nil, { tickMs = 10 })
    server.giveBag(3, 'police_bag', 'k3', { { 'radio', 1 } })

    roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })
    local bucketB = server.bucketOf(3)

    server.drop(1)
    server.step(2)

    t.equals(server.lobby.Get(b).state, 'live', 'the fixture ended B on its own before the test looked')
    t.equals(server.bucketOf(1), 0, 'the disconnected player was left in an arena instance')
    t.equals(server.bucketOf(3), bucketB, 'the other match lost its instance')
    t.equals(server.bucketOf(4), bucketB)

    server.purgeContainer('k3')
    server.match.End(b, 'match.ended')
    server.step(10)

    t.equals(server.bagContents('k3'), 'radiox1', 'the other match\'s bag was collateral')
    t.equals(server.carrying(3), INTACT .. ',police_bagx1')
end)

t.test('AND TWO SIMULTANEOUS MATCHES CONSERVE WHAT PLAYERS OWN', function()
    -- The same total as the single-match check, across two rounds running at
    -- once, with bags in both and a disconnect out of one of them.
    local server = newServer({ 1, 2, 3, 4 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })
    server.giveBag(3, 'police_bag', 'k3', { { 'handcuffs', 2 } })

    local before = server.ledger()

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    local issued = {}
    for name in pairs(server.ledger()) do
        if before[name] == nil then issued[name] = true end
    end

    server.purgeContainer('k1')
    server.purgeContainer('k3')
    server.drop(4)
    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(12)

    local diff = ledgerDiff(ownedOnly(before, issued), ownedOnly(server.ledger(), issued))
    t.equals(diff, '', 'two matches at once did not conserve what players own')
end)

-- ========================================================================
-- WHEN THE DATABASE ROUND TRIP DOES NOT COME BACK
--
-- ox_inventory throws an idle inventory out of memory after
-- `inventory:cleartime` and reads it back from the database on the next
-- touch. With a healthy database that is lossless and invisible, and every
-- other test in this file is that case. These two are the other one.
--
-- Nothing in this resource can recover items ox_inventory has dropped and
-- the database did not give back -- they do not exist anywhere any more. So
-- the whole of the promise here is: never call it a clean exit, never make
-- it worse, and say exactly what is missing.
-- ========================================================================

t.test('a belongings stash that comes back empty is never reported as a clean exit', function()
    local server, matchId = liveMatch({ 1, 2 })

    server.forgetStash(1)      -- written out, read back, nothing came back

    server.match.End(matchId, 'match.ended')
    server.step(10)

    t.contains(server.log(), 'READ EMPTY',
        'it handed a player empty pockets and called the exit clean')
    t.isNotNil(server.ammo.HeldFor(1),
        'the record was dropped, so nothing will ever go back for their belongings')
end)

t.test('and a bag holding stash that comes back short says so, by count', function()
    -- THE SAME EXPOSURE ON THIS RESOURCE'S OWN STASH, and it was silent. The
    -- refill returned quietly on an empty read, so a holding stash that had
    -- been through the round trip looked exactly like a bag that went in
    -- empty: the bag came back hollow with nothing anywhere saying why. The
    -- count taken at the door is the only thing that can tell those apart.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 }, { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.emptyStash('crimson_arena_bag_k1')   -- the holding stash is what was lost

    server.match.End(match.id, 'match.ended')
    server.step(10)

    t.contains(server.log(), 'are NOT in stash',
        'a player\'s bag was emptied by the arena and nothing said so')
    -- And it still does not make anything up, or take anything else.
    t.equals(server.carrying(1), INTACT .. ',police_bagx1')
end)

-- ========================================================================
-- THE REFUSALS NOBODY HAD DRIVEN
--
-- A full inventory is the most ordinary refusal there is at an exit, and
-- nothing here could say it: the fixture had no way to make ox_inventory
-- turn an item down. Neither could it show what was sitting in a bag
-- holding stash. Both are levers now, and these are the three cases they
-- open up.
-- ========================================================================

t.test('an exit that cannot hand everything over keeps it, says so, and comes back for it', function()
    local server, matchId = liveMatch({ 1, 2 })

    server.refuseAdds(1)          -- their pockets are full
    server.match.End(matchId, 'match.ended')
    server.step(10)

    t.equals(server.carrying(1), '', 'items were handed to somebody who could not take them')
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1',
        'THEIR BELONGINGS WERE DESTROYED rather than left where they were safe')
    t.contains(server.log(), 'did not happen', 'nothing said their kit could not be returned')

    -- AND THE SWEEP GOES BACK FOR IT. A refusal that is never retried is the
    -- same as a loss with a nicer log line.
    server.refuseAdds(1, false)
    server.step(12)

    t.equals(server.carrying(1), INTACT, 'they never got their belongings once they had room')
    t.equals(server.stashed(1), '', 'and the stash was not emptied')
end)

t.test('a bag that will not take its contents back keeps them in the holding stash', function()
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.purgeContainer('k1')
    server.refuseAdds('k1')        -- the bag is full and will not take them
    server.match.End(match.id, 'match.ended')
    server.step(10)

    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1',
        'THE BAG CONTENTS WERE DESTROYED rather than left in a stash that can be opened')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1',
        'the rest of the exit stopped working because a bag was full')
end)

t.test('a different character on the same server id gets nothing of the last one\'s', function()
    -- FiveM reuses server ids. Everything the door remembers is keyed on the
    -- SERVER ID, and the only thing that says whether it still means the same
    -- person is the citizen id. This is that guard, over both halves at once:
    -- the belongings stash and the bag holding stash.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1', 'the door did not take the bag contents')

    -- They drop with everything still held, and their pockets stay shut so
    -- the exit cannot empty the stash on the way out.
    server.refuseAdds(1)
    server.drop(1)
    server.step(4)
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1,police_bagx1',
        'the fixture handed it all back before the newcomer arrived, so this proves nothing')

    -- Somebody else connects onto that id.
    server.refuseAdds(1, false)
    server.reseat(1, 'CID999')
    server.step(12)

    t.equals(server.carrying(1), '',
        'A NEWCOMER WAS HANDED THE PREVIOUS CHARACTER\'S BELONGINGS')
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1,police_bagx1',
        'the previous character\'s stash was emptied by somebody else taking their id')
    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1',
        'and their bag contents went with it')
end)

-- ========================================================================
-- A BAG IS NEVER EMPTIED, ON ANY WAY OUT OF A ROUND
--
-- The container fix is tested above on the ordinary exit. A bag does not
-- care how the round ended, and neither should its contents -- so this
-- section runs the same claim through every other way out there is, plus
-- the shapes a bag itself can take: two of them at once, ten items in one,
-- and an item whose identity is its metadata rather than its name.
-- ========================================================================

--- Opens and starts a round at the trailer park. Returns the match id.
local function bagRound(server, ids)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    for n = 2, #ids do server.fire('joinMatch', ids[n], { matchId = match.id }) end
    for _, src in ipairs(ids) do server.fire('setReady', src, { ready = true }) end
    server.step(6)
    return match.id
end

--- Every one of these purges the container mid-round, which is the failure
--- the whole mechanism exists for: without the arena holding the contents,
--- the bag comes back empty.
local WAYS_OUT = {
    { 'the round ends',        function(server, m) server.match.End(m, 'match.ended') end },
    { 'the round is aborted',  function(server, m) server.match.Abort(m, 'match.aborted') end },
    { 'the fighter leaves',    function(server) server.fire('leaveMatch', 1) end },
    { 'the fighter drops',     function(server) server.drop(1) end },
    { 'the resource stops',    function(server) server.stopResource() end },
}

for _, way in ipairs(WAYS_OUT) do
    local label, finish = way[1], way[2]

    t.test(('a bag comes back packed when %s'):format(label), function()
        local server = newServer({ 1, 2 })
        server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 }, { 'handcuffs', 2 } })

        local matchId = bagRound(server, { 1, 2 })
        t.equals(server.bagContents('k1'), '', 'the door did not empty the bag on the way in')

        server.purgeContainer('k1')
        finish(server, matchId)
        server.step(12)

        t.equals(server.bagContents('k1'), 'handcuffsx2,radiox1',
            ('THE BAG WAS EMPTIED when %s'):format(label))
        t.equals(server.contentsOf('crimson_arena_bag_k1'), '',
            'the contents were left behind in the holding stash')
    end)
end

t.test('two bags on one player never pour into each other', function()
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'ka', { { 'radio', 1 } })
    server.giveBag(1, 'police_bag', 'kb', { { 'handcuffs', 2 } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('ka')
    server.purgeContainer('kb')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('ka'), 'radiox1', 'the first bag came back with the wrong things')
    t.equals(server.bagContents('kb'), 'handcuffsx2', 'the second bag came back with the wrong things')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1,police_bagx1', 'they lost or gained a bag')
end)

t.test('and an item whose identity is its metadata keeps it inside a bag', function()
    -- A count of names cannot see this, and a bag is exactly where people
    -- keep the things it matters for.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'phone', 1, { number = '555-REAL' } } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local meta = server.bagMetaOf('k1', 'phone')
    t.isNotNil(meta, 'the phone did not come back to the bag at all')
    t.equals(meta.number, '555-REAL', 'THEY GOT SOMEBODY ELSE\'S PHONE BACK')
end)

t.test('and ten items in one bag all come back', function()
    local server = newServer({ 1, 2 })
    local stuff = {}
    for n = 1, 10 do stuff[n] = { 'item' .. n, n } end
    server.giveBag(1, 'police_bag', 'k1', stuff)

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local back = {}
    for _, entry in ipairs(stuff) do
        if not server.bagContents('k1'):find(entry[1] .. 'x' .. entry[2], 1, true) then
            back[#back + 1] = entry[1]
        end
    end
    t.equals(table.concat(back, ','), '', 'these did not come back to the bag')
end)

t.test('CONTROL: with the door switched off entirely, the bag is never touched', function()
    -- stripOnEntry off means no stow, so no hold and no refill. The bag must
    -- travel exactly as it is -- and nothing may be left in a holding stash
    -- for a round that never took anything.
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    local matchId = bagRound(server, { 1, 2 })
    t.equals(server.bagContents('k1'), 'radiox1', 'the door emptied a bag it was told not to touch')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'radiox1')
    t.equals(server.contentsOf('crimson_arena_bag_k1'), '', 'it held contents for a round that never stripped')
end)

os.exit(t.summary())
