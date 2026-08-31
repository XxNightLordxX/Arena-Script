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
local function newServer(ids, mutate)
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

    local ox = {
        RegisterStash = function() return true end,
        GetInventoryItems = function(_self, id)
            local out = {}
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
        ClearInventory = function(_self, id)
            if type(id) == 'number' then inv[id] = {} else stashes[id] = {} end
            return true
        end,
        registerHook = function() return true end,
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
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
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

    function server.log() return table.concat(console, '\n') end

    return server
end

--- What OWN looks like once server.carrying has formatted it.
local INTACT = 'ammo-rifle-apx40,burgerx3,phonex1'

--- Opens a match with everyone in it and starts it, leaving the round live
--- with every fighter stripped and issued.
--- @param ids integer[]
--- @return table server
--- @return string matchId
local function liveMatch(ids, mutate)
    local server = newServer(ids, mutate)
    server.fire('createMatch', ids[1], { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })

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
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
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
        server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
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
os.exit(t.summary())
