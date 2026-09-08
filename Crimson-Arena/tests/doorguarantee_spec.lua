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
local function newServer(ids, mutate, extra)
    local wallets, inv, stashes = {}, {}, {}
    for _, src in ipairs(ids) do
        wallets[src] = {
            citizenid = 'CID' .. src,
            name = 'Player' .. src,
            money = { cash = 50000, bank = 0 },
        }
        inv[src] = {}
        for _, item in ipairs(OWN) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count }
        end
        for _, item in ipairs(extra or {}) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count }
        end
    end

    local qbx = Sandbox.newQbxCore(wallets)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}

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

    local ox = {
        RegisterStash = function() return true end,
        GetInventoryItems = function(_self, id)
            local out = {}
            if forgotten[id] then return out end
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata)
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
        -- Captured nowhere: this file drives events, not commands.
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name) return name == 'ox_inventory' and 'started' or 'missing' end,
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
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
        GetPlayerRoutingBucket = function() return 0 end,
        SetPlayerRoutingBucket = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
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

    --- Puts an item straight into a stash, the way an earlier run of this
    --- resource left one behind.
    function server.stashItem(stash, name, count)
        stashes[stash] = stashes[stash] or {}
        stashes[stash][#stashes[stash] + 1] = { name = name, count = count }
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
    t.isTrue(server.ammo.IsHolding(1), 'and the arena owes them their kit back')
end)

-- ========================================================================
-- Every way out
-- ========================================================================

t.test('a match that finishes normally hands everything back', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
    t.isFalse(server.ammo.IsHolding(1))
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

    t.equals(server.ammo.OnLoan(matchId), 0,
        'the finished match is still on the hook for rounds it handed out')
    t.isFalse(server.ammo.IsHolding(1), 'the arena still thinks it owes player 1 a kit')
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
    t.isTrue(server.ammo.IsHolding(1), 'nothing was stashed, so this proves nothing')

    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    t.equals(server.ammo.Owed(), 1, 'the exit did not record the debt it could not settle')

    -- The sweep, over and over, exactly as the retry thread runs it.
    for _ = 1, 5 do server.ammo.SweepReturns() end

    t.equals(server.ammo.Owed(), 1,
        'the retry declared the debt settled off a read that returned nothing')
    t.isTrue(server.ammo.IsHolding(1),
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
    t.isFalse(server.ammo.IsHolding(1), 'and the record was not dropped afterwards')
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
    t.isTrue(server.ammo.IsHolding(1), 'the record was not kept, so there is nothing stranded')

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

    t.isTrue(server.ammo.IsHolding(1), 'the record was not kept, so this proves nothing')
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

os.exit(t.summary())
