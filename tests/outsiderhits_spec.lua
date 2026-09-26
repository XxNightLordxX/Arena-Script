--[[
    crimson_arena/tests/outsiderhits_spec.lua

    A SHOT FIRED BY SOMEBODY IN NO ROUND IS WEIGHED AGAINST THE PEOPLE IN
    ONE, AND NOBODY ELSE.

    weaponDamageEvent reaches server/dispatch.lua for every shot fired
    anywhere on the server once any round is live -- the city's gunfire as
    well as the arena's. A packet naming something that is not a player (an
    NPC, a car) misses the cache of who owns which network id, and a miss
    rebuilt that cache over EVERY player on the server: GetPlayers and two
    natives each, 129 natives for one bullet at 64 players. For an attacker
    who is in no round that walk cannot change a thing, because such an
    attacker can only ever be refused over a victim who IS in a round
    (mayDamage), and every other victim they resolve to is "allowed" with
    nothing to show for it. So their packets are resolved against the
    flagged players now: 16 natives with 8 of them.

    What this file holds:

      THE GUARD, both halves, with the flagged set moving under it between
      packets: respawns onto new ids, ids recycled from NPCs and from other
      players, rounds entered and left, the eliminated, the watching, the
      departed, a guard switched off, and hostile packets.

      THE COST, counted on the stubs: 129 down to 16 on an outsider's NPC
      hit, the same for a 32-NPC shotgun, rebuilt for every packet and never
      kept, 2 as before on a player the cache knows, fighters still walking
      the whole server -- and the one price that went up, written down: an
      outsider's hit on a city player the cache has not seen.

      THE OLD HANDLER, KEPT BELOW VERBATIM, run beside the real one over
      four hundred seeded worlds and over four thousand packets: the same cancels,
      the same log lines, and the same hits written down for the kill
      witness -- apart from outsider-on-outsider hits, which the witness
      never records anyway, and which this file proves it never records.

      AND THE WITNESS END TO END, on the real round, because that is the
      one thing the shortcut leans on: every fighter still standing in a
      live round is flagged.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('outsiderhits_spec')

--- A server/dispatch.lua against a modelled server, every native the damage
--- path touches counted.
local function newFixture()
    local handlers = {}
    local buckets = {}
    local f = {
        cancelled = false,
        debugs = {},
        --- src -> true for a player the server lists. GetPlayers answers
        --- these; a player who is not listed has no ped, as on FXServer.
        connected = {},
        --- src -> the network id of that player's ped.
        netIds = {},
        --- src -> 'zero' | 'throw' for a ped read that goes wrong.
        pedMode = {},
        --- src -> 'zero' | 'throw' for a network id read that goes wrong.
        netMode = {},
        calls = { players = 0, ped = 0, net = 0 },
        remembered = {},
        matches = {},
    }

    local env = Sandbox.newEnv({
        GetPlayers = function()
            f.calls.players = f.calls.players + 1
            local out = {}
            for src in pairs(f.connected) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src)
            f.calls.ped = f.calls.ped + 1
            local n = tonumber(src) or 0
            if f.pedMode[n] == 'throw' then error('no such player') end
            if f.pedMode[n] == 'zero' or not f.connected[n] then return 0 end
            return 1000 + n
        end,
        NetworkGetNetworkIdFromEntity = function(ped)
            f.calls.net = f.calls.net + 1
            local src = (tonumber(ped) or 0) - 1000
            if f.netMode[src] == 'throw' then error('entity is gone') end
            if f.netMode[src] == 'zero' then return 0 end
            return f.netIds[src] or 0
        end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        CancelEvent = function() f.cancelled = true end,

        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,

        Player = function() return { state = { set = function() end } } end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        exports = setmetatable({}, { __call = function() end }),
        ArenaLog = function() end,
        ArenaDebug = function(fmt, ...)
            f.debugs[#f.debugs + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
        end,
    })

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.enableAllArenas(env)
    Sandbox.openTheDoors(env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/dispatch.lua', env)

    env.ArenaLobby = { Get = function(id) return f.matches[id] end }
    env.ArenaMatch = {
        RememberDamage = function(victim, attacker)
            f.remembered[#f.remembered + 1] = { victim = victim, attacker = attacker }
            return false
        end,
    }

    f.env = env
    f.D = env.ArenaDispatch
    f.handlers = handlers

    --- Puts a player on the server with a ped.
    function f.join(src, netId)
        f.connected[src] = true
        f.netIds[src] = netId or (5000 + src)
        return f.netIds[src]
    end

    --- A round the way server/lobby.lua holds it, every fighter flagged.
    --- `teams` is [src] = teamKey (or true for no team).
    function f.round(matchId, modeKey, teams)
        local players = {}
        for src, team in pairs(teams) do
            if not f.connected[src] then f.join(src) end
            players[src] = { src = src, team = team ~= true and team or nil, alive = true, lives = 3 }
            f.D.Set(src, matchId, true)
        end
        f.matches[matchId] = { id = matchId, modeKey = modeKey, players = players, state = 'live' }
        return players
    end

    --- Somebody watching a round: in its instance and flagged, on no roster.
    function f.watch(src, matchId)
        if not f.connected[src] then f.join(src) end
        f.D.Set(src, matchId)
    end

    function f.natives() return f.calls.players + f.calls.ped + f.calls.net end

    --- Fires the engine's damage packet, counting from zero.
    --- @return boolean cancelled
    function f.packet(attacker, ids)
        f.cancelled = false
        f.debugs = {}
        f.remembered = {}
        f.calls = { players = 0, ped = 0, net = 0 }
        local data = { hitGlobalIds = ids }
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do
            fn(attacker ~= nil and tostring(attacker) or nil, data)
        end
        return f.cancelled
    end

    return f
end

local NPC = 777777

--- 64 players on the server, 1..8 fighting in one round, the rest in town.
local function busyServer()
    local f = newFixture()
    for src = 1, 64 do f.join(src) end
    local teams = {}
    for src = 1, 8 do teams[src] = src % 2 == 1 and 'crimson' or 'ash' end
    f.round('m1', 'tdm', teams)
    return f
end

--- The line the handler writes when it refuses a packet.
local function refusal(attacker, victim, reason)
    return ('crossfire: %s may not damage %s -- %s.'):format(tostring(attacker), tostring(victim), reason)
end
local NOT_SAME_ROUND = 'they are not in the same round'

-- ======================================================================
-- 1. THE GUARD, FROM OUTSIDE THE LINE
-- ======================================================================

t.test('an outsider shooting an NPC while a round is live is left alone', function()
    local f = busyServer()
    t.isFalse(f.packet(60, { NPC }), 'city gunfire at an NPC was cancelled')
    t.equals(#f.debugs, 0, 'city gunfire at an NPC was written to the log')
end)

t.test('THE REPORT: an outsider cannot shoot a fighter, wherever the fighter sits in the packet', function()
    for _, ids in ipairs({ { 5003 }, { NPC, 5003 }, { 5003, NPC }, { NPC, NPC + 1, 5003, NPC + 2 },
        { 5061, 5003 }, { 5003, 5061 } }) do
        local f = busyServer()
        t.isTrue(f.packet(60, ids), ('an outsider reached fighter 3 in packet %s'):format(table.concat(ids, ',')))
        t.equals(f.debugs[#f.debugs], refusal(60, 3, NOT_SAME_ROUND), 'the refusal names the wrong victim')
        for _, hit in ipairs(f.remembered) do
            t.isTrue(hit.victim ~= 3, 'a refused outsider hit was written down against the fighter')
        end
    end
end)

t.test('and names the FIRST fighter it would have hit, as it always has', function()
    local f = busyServer()
    t.isTrue(f.packet(60, { NPC, 5005, 5002 }))
    t.equals(f.debugs[#f.debugs], refusal(60, 5, NOT_SAME_ROUND))
end)

t.test('an outsider cannot shoot somebody WATCHING a round either', function()
    local f = busyServer()
    f.watch(40, 'm1')
    t.isTrue(f.packet(60, { 5040 }), 'an outsider shot a spectator of a live round')
    t.isTrue(f.packet(60, { NPC, 5040 }), 'an outsider shot a spectator from inside a spread')
end)

t.test('nor a fighter who is out of the round but still flagged', function()
    local f = busyServer()
    local players = f.matches.m1.players
    players[4].alive, players[4].lives = false, 0
    t.isTrue(f.packet(60, { 5004 }), 'an outsider shot an eliminated fighter still in the instance')
end)

t.test('and a fighter the round has sent home is back in town, and fair game again', function()
    local f = busyServer()
    local players = f.matches.m1.players
    players[4].alive, players[4].lives = false, 0
    f.D.Clear(4)
    t.isFalse(f.packet(60, { 5004 }), 'a fighter sent home was still protected by the arena')
end)

t.test('a city player, cached or not, is nobody the arena protects', function()
    local f = busyServer()
    t.isFalse(f.packet(60, { 5061 }), 'an outsider could not shoot a city player (cold cache)')
    f.packet(1, { NPC })                         -- a fighter's miss rebuilds the cache
    t.isFalse(f.packet(60, { 5061 }), 'an outsider could not shoot a city player (warm cache)')
end)

t.test('an outsider may always hurt themselves', function()
    local f = busyServer()
    t.isFalse(f.packet(60, { 5060 }), 'an outsider was made immune to their own damage')
    for _, hit in ipairs(f.remembered) do
        t.isTrue(hit.victim ~= hit.attacker, 'a self-hit was written down')
    end
end)

t.test('THE STALE MAP: a fighter who respawned between two outsider packets is still found', function()
    local f = busyServer()
    t.isFalse(f.packet(60, { NPC }))
    f.netIds[3] = 91234
    t.isTrue(f.packet(60, { 91234 }), 'the second packet was answered from the first one\'s map')
    t.isFalse(f.packet(60, { 5003 }), 'the fighter\'s OLD id still reads as theirs')
end)

t.test('and one whose new ped took an id the outsider had already hit as an NPC', function()
    -- The negative-cache trap in its purest form: "777777 is nobody" was
    -- true one packet ago.
    local f = busyServer()
    t.isFalse(f.packet(60, { NPC }))
    f.netIds[3] = NPC
    t.isTrue(f.packet(60, { NPC }), 'an id that WAS an NPC shielded the fighter who now owns it')
end)

t.test('a fighter\'s old id handed to a city player carries none of the fighter\'s protection', function()
    local f = busyServer()
    f.packet(1, { NPC })                         -- cache: 5003 -> fighter 3
    f.netIds[3] = 91234
    f.netIds[61] = 5003
    t.isFalse(f.packet(60, { 5003 }), 'the cached owner of a recycled id was believed')
    t.isTrue(f.packet(60, { 91234 }), 'the fighter\'s new id was not found')
end)

t.test('and a city player\'s old id handed to a fighter carries the fighter\'s', function()
    local f = busyServer()
    f.packet(1, { NPC })                         -- cache: 5061 -> city player 61
    f.netIds[61] = 91235
    f.netIds[3] = 5061
    t.isTrue(f.packet(60, { 5061 }), 'a cached city owner hid the fighter who now holds the id')
end)

t.test('somebody who walks into a round between two packets is protected on the second', function()
    local f = busyServer()
    t.isFalse(f.packet(60, { 5040 }), 'a city player was protected before entering a round')
    f.matches.m1.players[40] = { src = 40, team = 'ash', alive = true, lives = 3 }
    f.D.Set(40, 'm1', true)
    t.isTrue(f.packet(60, { 5040 }), 'a fighter who had just entered the round was not found')
end)

t.test('and somebody who walks out between two packets is not', function()
    local f = busyServer()
    t.isTrue(f.packet(60, { 5002 }))
    f.D.Clear(2)
    t.isFalse(f.packet(60, { 5002 }), 'a player who had left the round was still protected')
end)

t.test('a flagged player who has left the server, or whose reads fail, names nobody and breaks nothing', function()
    local f = busyServer()
    f.connected[2] = nil                         -- gone, flag not yet down
    f.pedMode[3] = 'throw'
    f.netMode[4] = 'throw'
    f.pedMode[5] = 'zero'
    f.netMode[6] = 'zero'
    for _, id in ipairs({ 5002, 5003, 5004, 5005, 5006 }) do
        local ok, cancelled = pcall(f.packet, 60, { NPC, id })
        t.isTrue(ok, ('a failed read on %d took the handler down'):format(id))
        t.isFalse(cancelled, ('an unreadable player (%d) was resolved from somewhere'):format(id))
    end
    t.isTrue(f.packet(60, { 5007 }), 'the readable fighters stopped being protected')
end)

t.test('a packet that names the same fighter twice is refused once', function()
    local f = busyServer()
    t.isTrue(f.packet(60, { 5003, 5003, NPC, 5003 }))
    t.equals(#f.debugs, 1, 'one refusal, one line')
end)

t.test('switching the guard off lets an outsider\'s packet through untouched', function()
    local f = busyServer()
    f.env.Config.Match.crossfireGuard = { enabled = false }
    t.isFalse(f.packet(60, { 5003 }), 'the guard refused a shot with its setting off')
    t.isFalse(f.packet(60, { NPC }), 'the guard refused an NPC hit with its setting off')
    t.equals(#f.debugs, 0, 'the guard wrote to the log with its setting off')
    for _, hit in ipairs(f.remembered) do
        t.isTrue(hit.victim ~= 3, 'an outsider\'s hit on a fighter was written down')
    end
end)

t.test('EXPLOIT: nothing an outsider puts in the packet takes the handler down', function()
    local f = busyServer()
    local cyclic = { hitGlobalIds = {} }
    cyclic.hitGlobalIds[1] = cyclic
    local hostile = {
        nil, false, 0, '', 'nonsense', {}, { hitGlobalIds = 5 }, { hitGlobalIds = 'x' },
        { hitGlobalIds = { nil } }, { hitGlobalIds = { 'x', {}, true } },
        { hitGlobalIds = { 0 / 0 } }, { hitGlobalIds = { math.huge, -math.huge } },
        { hitGlobalIds = { -1, 0, 2 ^ 60 } }, { hitGlobalIds = { '5003' } }, { hitGlobalIds = { 5003.0 } },
        cyclic,
    }
    for index, data in ipairs(hostile) do
        local ok, err = pcall(function()
            for _, fn in ipairs(f.handlers['weaponDamageEvent']) do fn('60', data) end
        end)
        t.isTrue(ok, ('payload %d took the handler down: %s'):format(index, tostring(err)))
    end
    -- A fighter's id as TEXT or as a float is still that fighter's.
    t.isTrue(f.packet(60, { '5003' }), 'a fighter\'s id sent as text was not resolved')
    t.isTrue(f.packet(60, { 5003.0 }), 'a fighter\'s id sent as a float was not resolved')
    for _, sender in ipairs({ 'abc', '', '-1', '0', '1.5', '99999999' }) do
        t.isTrue(pcall(f.packet, sender, { 5003, NPC }), ('sender %q took the handler down'):format(sender))
    end
end)

t.test('EXPLOIT: entries that are not ids cost nothing, from either side of the line', function()
    local f = busyServer()
    for _, attacker in ipairs({ 60, 1 }) do
        t.isFalse(f.packet(attacker, { 'x', true, {}, 'nonsense' }), 'a packet naming nothing was refused')
        t.equals(f.natives(), 0, ('natives read for a packet naming nothing, attacker %d'):format(attacker))
    end
end)

t.test('EXPLOIT: an outsider\'s flood is refused before anything is read', function()
    local f = busyServer()
    local flood = {}
    for index = 1, 33 do flood[index] = NPC + index end
    t.isTrue(f.packet(60, flood), 'a 33-entity packet from an outsider was allowed')
    t.equals(f.natives(), 0, 'natives read for a packet that is refused on its length')
end)

-- ======================================================================
-- 2. THE OTHER HALF IS UNTOUCHED: A FIGHTER STILL RESOLVES EVERYBODY
-- ======================================================================

t.test('AND THE OTHER HALF: a fighter cannot shoot a city player the cache has never seen', function()
    local f = busyServer()
    t.isTrue(f.packet(1, { 5061 }), 'a fighter shot somebody in town')
end)

t.test('nor after an outsider\'s packets have left the cache cold', function()
    local f = busyServer()
    f.packet(60, { NPC })
    f.packet(61, { 5062 })
    f.netIds[62] = 91236                         -- and a city player respawned
    t.isTrue(f.packet(1, { 91236 }), 'a fighter shot a respawned city player')
    t.isTrue(f.packet(1, { NPC, 5063 }), 'a fighter\'s spread reached into town')
end)

t.test('and the round still fights itself, teams and all', function()
    local f = busyServer()
    f.packet(60, { NPC })
    t.isFalse(f.packet(1, { 5002 }), 'a fighter could not shoot an enemy')
    t.equals(#f.remembered, 1, 'the landed hit was not written down')
    t.equals(f.remembered[1].victim, 2)
    t.equals(f.remembered[1].attacker, 1)
    t.isTrue(f.packet(1, { 5003 }), 'a fighter shot a team-mate with friendly fire off')
    t.equals(#f.remembered, 0, 'a refused team hit was written down')
    t.isFalse(f.packet(1, { 5003, 5002 }), 'the bend stopped letting a spread through')
    t.equals(#f.remembered, 1, 'the bend wrote down more than the enemy it hit')
end)

-- ======================================================================
-- 3. THE COST, COUNTED
-- ======================================================================

t.test('COST: an outsider\'s NPC hit reads the 8 fighters, not the 64 players (129 natives down to 16)', function()
    local f = busyServer()
    f.packet(60, { NPC })
    t.equals(f.calls.players, 0, 'GetPlayers was called for an outsider\'s NPC hit')
    t.equals(f.natives(), 16, 'natives on one outsider NPC hit')
end)

t.test('COST: and a shotgun naming 32 NPCs costs the same, not one map each', function()
    local f = busyServer()
    local spread = {}
    for index = 1, 32 do spread[index] = NPC + index end
    f.packet(60, spread)
    t.equals(f.natives(), 16, 'natives on one outsider 32-NPC spread')
end)

t.test('COST: the map is made for every packet and kept for none', function()
    local f = busyServer()
    f.packet(60, { NPC })
    t.equals(f.natives(), 16, 'first packet')
    f.packet(60, { NPC })
    t.equals(f.natives(), 16, 'second packet: the map was kept from the first, or not built')
end)

t.test('COST: an outsider\'s packet leaves the cache exactly as it found it', function()
    -- NOTHING A LATER PACKET READS IS CHANGED BY AN OUTSIDER'S. That is what
    -- keeps the argument for this path to one packet at a time: the map is
    -- thrown away, and the cache is only ever filled by a fighter's full
    -- walk. So the second hit on the same fighter pays for the map again,
    -- where a path that slipped what it learned into the cache would pay 2.
    local f = busyServer()
    t.isTrue(f.packet(60, { 5003 }))
    t.equals(f.natives(), 16, 'first outsider hit on a fighter, cold cache')
    t.isTrue(f.packet(60, { 5003 }))
    t.equals(f.natives(), 16, 'second outsider hit on the same fighter: the first one wrote the cache')
    t.isFalse(f.packet(1, { 5002 }))
    t.equals(f.calls.players, 1, 'a fighter\'s packet found the cache filled by an outsider\'s')
end)

t.test('COST: an outsider\'s hit on a player the cache knows costs 2, as it always did', function()
    local f = busyServer()
    f.packet(1, { NPC })                         -- a fighter's miss: the full walk
    t.equals(f.natives(), 129, 'a fighter\'s NPC hit stopped walking the whole server')
    f.packet(60, { 5061 })
    t.equals(f.natives(), 2, 'an outsider\'s hit on a cached city player')
    f.packet(60, { 5003 })
    t.equals(f.natives(), 2, 'an outsider\'s hit on a cached fighter')
end)

t.test('COST: nothing at all is read while no round is live', function()
    local f = newFixture()
    for src = 1, 64 do f.join(src) end
    f.packet(60, { NPC })
    f.packet(60, { 5061 })
    t.equals(f.natives(), 0, 'natives read with nobody in an arena')
end)

t.test('COST, THE PRICE THAT WENT UP: a city player the cache has not seen costs 2 per fighter, every time', function()
    -- WRITTEN DOWN BECAUSE IT IS REAL. The old walk refreshed the cache for
    -- everybody on an outsider's miss, so city fighting against a cold cache
    -- paid 129 once and 2 a packet after that. An outsider's packet no longer
    -- touches the cache, so it pays 2 per flagged player on every packet until
    -- a fighter's own miss rebuilds it. With 8 fighters that is 16.
    local f = busyServer()
    f.packet(60, { 5061 })
    t.equals(f.natives(), 16, 'first city hit on a cold cache')
    f.packet(60, { 5061 })
    t.equals(f.natives(), 16, 'second city hit on the still-cold cache')
    f.packet(1, { NPC })
    f.packet(60, { 5061 })
    t.equals(f.natives(), 2, 'a city hit once a fighter\'s miss has rebuilt the cache')
end)

-- ======================================================================
-- 4. THE OLD HANDLER, VERBATIM, AGAINST THE REAL ONE
--
-- Everything the damage path is made of, exactly as it shipped before
-- outsiders were resolved against the flagged players: netIdOf, the cache,
-- ownerOfNetId, mayDamage and the handler. Loaded into the SAME sandbox as
-- the real file so it calls the same counted natives, the same lobby and
-- the same witness. It keeps its OWN cache, because it is a second server
-- watching the same shots, and it reads who is flagged through the file's
-- public GetArenaPlayers, which copies `active`.
-- ======================================================================

local OLD_HANDLER = [==[
local active = {}
local netIdOwners = {}

local function netIdOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotId, netId = pcall(NetworkGetNetworkIdFromEntity, ped)
    if not gotId then return nil end

    netId = tonumber(netId)
    if not netId or netId == 0 then return nil end
    return netId
end

local function crossfireConfig()
    return (Config.Match or {}).crossfireGuard or {}
end

local function crossfireEnabled()
    return crossfireConfig().enabled ~= false
end

local MAX_HITS = 32

local function ownerOfNetId(netId, packet)
    local cached = netIdOwners[netId]
    if cached and netIdOf(cached) == netId then return cached end

    if packet then
        if packet.rebuilt then return netIdOwners[netId] end
        packet.rebuilt = true
    end

    netIdOwners = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local src = tonumber(id)
        if src then
            local owned = netIdOf(src)
            if owned then netIdOwners[owned] = src end
        end
    end

    return netIdOwners[netId]
end

local function mayDamage(attacker, victim)
    if attacker == victim then return true end

    local attackerMatch, victimMatch = active[attacker], active[victim]
    if attackerMatch == nil and victimMatch == nil then return true end
    if attackerMatch == nil or attackerMatch ~= victimMatch then
        return false, 'they are not in the same round', 'crossfire'
    end

    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(attackerMatch)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return true end

    local shooter, target = match.players[attacker], match.players[victim]
    if shooter == nil or target == nil then
        return false, 'one of them is watching rather than fighting', 'crossfire'
    end

    if Arena.IsEliminated(shooter) then
        return false, 'the shooter is out of the round', 'crossfire'
    end

    if Arena.CanDamage(match.modeKey, shooter.team, target.team) then
        return true
    end
    return false, 'they are on the same team and friendly fire is off', 'team'
end

return function(sender, data)
    active = ArenaDispatch.GetArenaPlayers()

    local guard = crossfireEnabled()

    if next(active) == nil then return end

    local attacker = tonumber(sender)
    if not attacker then return end

    local hits = type(data) == 'table' and data.hitGlobalIds or nil
    if type(hits) ~= 'table' then return end

    if #hits > MAX_HITS then
        if not guard then return end
        ArenaDebug('crossfire: refused a damage packet from %s naming %d entities.', tostring(attacker), #hits)
        CancelEvent()
        return
    end

    local allowed, refusal, crossfire = 0, nil, false

    local packet = {}

    local lawful = {}

    for _, entry in ipairs(hits) do
        local netId = tonumber(entry)
        local victim = netId and ownerOfNetId(netId, packet) or nil
        if victim then
            local ok, reason, kind = mayDamage(attacker, victim)
            if ok then
                if victim ~= attacker then
                    allowed = allowed + 1
                    lawful[#lawful + 1] = victim
                end
            else
                refusal = refusal or { victim = victim, reason = reason }
                if kind ~= 'team' then crossfire = true end
            end
        end
    end

    local cancelled = guard and refusal ~= nil and (crossfire or allowed == 0)
    if not cancelled
        and type(ArenaMatch) == 'table'
        and type(ArenaMatch.RememberDamage) == 'function'
    then
        for _, victim in ipairs(lawful) do
            ArenaMatch.RememberDamage(victim, attacker)
        end
    end

    if not guard then return end

    if refusal == nil then return end

    if cancelled then
        ArenaDebug('crossfire: %s may not damage %s -- %s.',
            tostring(attacker), tostring(refusal.victim), refusal.reason or 'refused')
        CancelEvent()
        return
    end

    ArenaDebug('crossfire: %s hit %s -- SAME TEAM, and it is ALLOWED because this packet also '
        .. 'named %d enemy target(s). A spread that catches a team-mate is let through whole on '
        .. 'purpose; cancelling it would make standing next to a team-mate shotgun-proof. '
        .. 'Nothing is broken -- this is the documented bend.',
        tostring(attacker), tostring(refusal.victim), allowed)
end
]==]

--- A small seeded generator, so every run draws the same worlds.
local function newRng(seed)
    local state = seed
    local rng = {}
    function rng.int(lo, hi)
        state = (state * 1103515245 + 12345) % 2147483648
        return lo + (state // 65536) % (hi - lo + 1)
    end
    function rng.chance(percent) return rng.int(1, 100) <= percent end
    function rng.pick(list) return list[rng.int(1, #list)] end
    return rng
end

--- What the real ArenaMatch.RememberDamage keeps, written out from
--- server/match.lua: a live round holding the victim, both of them on its
--- roster, and the victim standing. Section 5 runs the real one.
local function witnessKeeps(matches, victim, attacker)
    victim, attacker = math.tointeger(tonumber(victim)), math.tointeger(tonumber(attacker))
    if not victim or not attacker or victim <= 0 or attacker <= 0 or victim == attacker then return false end
    for _, match in pairs(matches) do
        if match.players[victim] ~= nil then
            return match.state == 'live' and match.players[attacker] ~= nil
                and match.players[victim].alive == true
        end
    end
    return false
end

--- One world after another, the old handler and the real one fed the same
--- packets. Returns every packet's record for the tests below to judge.
local function runWorlds()
    local f = newFixture()
    local oldHandler
    local rng = newRng(20260926)
    local records = {}
    local nextId = 60000

    local function freshId()
        nextId = nextId + 1
        return nextId
    end

    for world = 1, 400 do
        -- A NEW OLD SERVER FOR EVERY WORLD, and a new real one: neither may
        -- carry a cache from a world whose players are gone.
        f = newFixture()
        oldHandler = assert(load(OLD_HANDLER, '=old damage handler', 't', f.env))()
        f.env.Config.Teams.friendlyFire = rng.chance(20)

        local population = rng.int(2, 80)
        local srcs, taken = {}, {}
        while #srcs < population do
            local src = rng.int(1, 160)
            if not taken[src] then taken[src] = true; srcs[#srcs + 1] = src end
        end
        table.sort(srcs)
        for _, src in ipairs(srcs) do f.join(src, freshId()) end

        -- THE NPCS AND CARS in town, and every id ever handed out, so a
        -- respawn can recycle one.
        local npcs, used = {}, {}
        for index = 1, 12 do npcs[index] = 700000 + world * 100 + index end
        for _, src in ipairs(srcs) do used[#used + 1] = f.netIds[src] end

        -- UP TO THREE ROUNDS, each with fighters, the eliminated (some
        -- watching, some sent home) and spectators; and sometimes a round
        -- still in its lobby, whose roster is not flagged.
        local pool = {}
        for _, src in ipairs(srcs) do pool[#pool + 1] = src end
        local function draw()
            if #pool == 0 then return nil end
            return table.remove(pool, rng.int(1, #pool))
        end
        -- ONE WORLD IN THREE IS A TEAM BRAWL: two sides, friendly fire off,
        -- the fighters mostly shooting each other. That is where the team
        -- rule and the bend are decided, and a uniform draw hardly reaches it.
        local brawl = rng.chance(35)
        if brawl then f.env.Config.Teams.friendlyFire = false end
        for index = 1, brawl and 1 or rng.int(0, 3) do
            local id = 'm' .. index
            local lobbyStage = not brawl and rng.chance(15)
            local players = {}
            for _ = 1, rng.int(1, 8) do
                local src = draw()
                if src then
                    local row = { src = src, alive = true, lives = 3,
                        team = rng.pick(brawl and { 'crimson', 'ash' } or { 'crimson', 'ash', 'jade', false }) or nil }
                    players[src] = row
                    if not lobbyStage then
                        if rng.chance(15) then
                            row.alive, row.lives = false, 0
                            if rng.chance(50) then f.D.Set(src, id, true) end
                        else
                            f.D.Set(src, id, true)
                        end
                    end
                end
            end
            f.matches[id] = { id = id, modeKey = brawl and 'tdm' or rng.pick({ 'tdm', 'tdm', 'ffa', 'gungame' }),
                players = players, state = lobbyStage and 'lobby' or 'live' }
            if not lobbyStage then
                for _ = 1, rng.int(0, 2) do
                    local src = draw()
                    if src then f.D.Set(src, id) end
                end
            end
        end

        for step = 1, 14 do
            local roll = rng.int(1, 100)
            if roll <= 12 then
                -- A RESPAWN: a new ped, sometimes on an id somebody or
                -- something else held a moment ago.
                local src = rng.pick(srcs)
                local choice = rng.int(1, 3)
                local id = (choice == 1 and freshId()) or (choice == 2 and rng.pick(npcs)) or rng.pick(used)
                local holder = nil
                for other, held in pairs(f.netIds) do
                    if held == id and other ~= src then holder = other end
                end
                -- NETWORK IDS ARE UNIQUE on a real server: whoever held it
                -- has moved on to a fresh one.
                if holder then f.netIds[holder] = freshId() end
                f.netIds[src] = id
                used[#used + 1] = id
            elseif roll <= 16 then
                -- A round picks somebody up, or lets somebody go.
                local src = rng.pick(srcs)
                if f.D.GetPlayerMatchId(src) then f.D.Clear(src) else f.D.Set(src, 'm1', rng.chance(50)) end
            elseif roll <= 19 then
                -- Somebody leaves the server; mostly the flag comes down.
                local src = rng.pick(srcs)
                f.connected[src] = nil
                if rng.chance(70) then f.D.Clear(src) end
            elseif roll <= 21 then
                -- Somebody arrives, maybe on a recycled id.
                local src = rng.pick(srcs)
                if not f.connected[src] then f.join(src, freshId()) end
            elseif roll <= 23 then
                local src = rng.pick(srcs)
                f.pedMode[src] = rng.pick({ 'zero', 'throw', false }) or nil
                f.netMode[src] = rng.pick({ 'zero', 'throw', false, false }) or nil
            elseif roll <= 24 then
                f.env.Config.Match.crossfireGuard = { enabled = not rng.chance(50) }
            else
                -- A PACKET.
                local flaggedList, outsiders = {}, {}
                for _, src in ipairs(srcs) do
                    if f.D.GetPlayerMatchId(src) then flaggedList[#flaggedList + 1] = src
                    elseif f.connected[src] then outsiders[#outsiders + 1] = src end
                end
                local attacker
                local who = rng.int(1, 100)
                if who <= 55 and #outsiders > 0 then attacker = rng.pick(outsiders)
                elseif who <= 95 and #flaggedList > 0 then attacker = rng.pick(flaggedList)
                else attacker = rng.pick({ rng.pick(srcs), 0, -1, 'x', 999 }) end

                -- A FIGHTER MOSTLY SHOOTS AT THEIR OWN ROUND, which is where
                -- the team rule and the bend live.
                local roundmates = {}
                local own = type(attacker) == 'number' and f.D.GetPlayerMatchId(attacker) or nil
                if own and f.matches[own] then
                    for src in pairs(f.matches[own].players) do roundmates[#roundmates + 1] = src end
                    table.sort(roundmates)
                end

                local ids = {}
                local size = rng.chance(4) and 33 or rng.int(0, 7)
                for index = 1, size do
                    local kind = rng.int(1, 100)
                    local target = (#roundmates > 0 and rng.chance(brawl and 90 or 60)) and rng.pick(roundmates)
                        or rng.pick(srcs)
                    if kind <= 35 then ids[index] = rng.pick(npcs)
                    elseif kind <= 75 then ids[index] = f.netIds[target]
                    elseif kind <= 85 then ids[index] = rng.pick(used)
                    elseif kind <= 90 then ids[index] = tostring(f.netIds[target])
                    elseif kind <= 93 then ids[index] = f.netIds[target] + 0.0
                    else ids[index] = rng.pick({ 'x', true, 0, -1, 0 / 0 }) end
                end

                local outsider = type(attacker) == 'number' and f.D.GetPlayerMatchId(attacker) == nil
                local record = { label = ('world %d step %d attacker %s'):format(world, step, tostring(attacker)),
                    outsider = outsider, ids = ids, flagged = f.D.GetArenaPlayers(), matches = f.matches,
                    namesPlayer = false, flaggedCount = 0 }
                for _ in pairs(record.flagged) do record.flaggedCount = record.flaggedCount + 1 end
                for _, id in ipairs(ids) do
                    for src, held in pairs(f.netIds) do
                        if held == tonumber(id) and f.connected[src] then record.namesPlayer = true end
                    end
                end

                -- The old server first, then the real one, on the same world.
                f.cancelled, f.debugs, f.remembered = false, {}, {}
                f.calls = { players = 0, ped = 0, net = 0 }
                local okOld, errOld = pcall(oldHandler, attacker ~= nil and tostring(attacker) or nil,
                    { hitGlobalIds = ids })
                record.old = { ok = okOld, err = errOld, cancelled = f.cancelled, debugs = f.debugs,
                    remembered = f.remembered, natives = f.natives(), players = f.calls.players }

                local okNew, errNew = pcall(f.packet, attacker, ids)
                record.new = { ok = okNew, err = errNew, cancelled = f.cancelled, debugs = f.debugs,
                    remembered = f.remembered, natives = f.natives(), players = f.calls.players,
                    peds = f.calls.ped }
                records[#records + 1] = record
            end
        end
    end
    return records
end

local RECORDS = runWorlds()

local function noneOf(problems, what)
    local shown = {}
    for index = 1, math.min(5, #problems) do shown[index] = problems[index] end
    t.equals(#problems, 0, ('%s:\n    %s'):format(what, table.concat(shown, '\n    ')))
end

local function sameList(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do if a[index] ~= b[index] then return false end end
    return true
end

local function hitKey(hit) return tostring(hit.victim) .. '<' .. tostring(hit.attacker) end

t.test('DIFFERENTIAL: the same cancels and the same log lines as the old handler, packet for packet', function()
    local problems, tally = {}, { packets = 0, outsider = 0, outsiderCancel = 0, fighterCancel = 0, bend = 0 }
    for _, r in ipairs(RECORDS) do
        tally.packets = tally.packets + 1
        if not r.old.ok then
            problems[#problems + 1] = r.label .. ': the OLD handler threw: ' .. tostring(r.old.err)
        elseif not r.new.ok then
            problems[#problems + 1] = r.label .. ': the handler threw: ' .. tostring(r.new.err)
        elseif r.old.cancelled ~= r.new.cancelled then
            problems[#problems + 1] = ('%s: old cancelled=%s, new cancelled=%s')
                :format(r.label, tostring(r.old.cancelled), tostring(r.new.cancelled))
        elseif not sameList(r.old.debugs, r.new.debugs) then
            problems[#problems + 1] = ('%s: the log changed: %s / %s')
                :format(r.label, tostring(r.old.debugs[1]), tostring(r.new.debugs[1]))
        end
        if r.outsider then
            tally.outsider = tally.outsider + 1
            if r.new.cancelled then tally.outsiderCancel = tally.outsiderCancel + 1 end
        elseif r.new.cancelled then
            tally.fighterCancel = tally.fighterCancel + 1
        end
        for _, line in ipairs(r.new.debugs) do
            if line:find('documented bend', 1, true) then tally.bend = tally.bend + 1 end
        end
    end
    noneOf(problems, 'old and new disagree')

    -- NOT VACUOUS.
    t.isTrue(tally.packets >= 4000, ('only %d packets were fired'):format(tally.packets))
    t.isTrue(tally.outsider >= 2400, ('only %d outsider packets'):format(tally.outsider))
    t.isTrue(tally.outsiderCancel >= 500, ('only %d outsider packets were refused'):format(tally.outsiderCancel))
    t.isTrue(tally.fighterCancel >= 600, ('only %d fighter packets were refused'):format(tally.fighterCancel))
    t.isTrue(tally.bend >= 20, ('only %d bends were drawn'):format(tally.bend))
end)

t.test('DIFFERENTIAL: the witness is told the same thing, save the outsider-on-outsider hits it never keeps', function()
    local problems, dropped, kept, effective = {}, 0, 0, 0
    for _, r in ipairs(RECORDS) do
        if r.old.ok and r.new.ok then
            -- EVERY hit the new handler writes down, the old one wrote down
            -- too, in the same order.
            local cursor = 1
            for _, hit in ipairs(r.new.remembered) do
                while cursor <= #r.old.remembered and hitKey(r.old.remembered[cursor]) ~= hitKey(hit) do
                    local skipped = r.old.remembered[cursor]
                    -- AND THE ONLY ONES IT DROPS: an attacker in no round,
                    -- a victim in no round.
                    if not r.outsider or r.flagged[skipped.victim] ~= nil then
                        problems[#problems + 1] = ('%s: the witness lost %s'):format(r.label, hitKey(skipped))
                    end
                    dropped = dropped + 1
                    cursor = cursor + 1
                end
                if cursor > #r.old.remembered then
                    problems[#problems + 1] = ('%s: the witness was told %s, which the old handler never said')
                        :format(r.label, hitKey(hit))
                    break
                end
                cursor = cursor + 1
                kept = kept + 1
            end
            for index = cursor, #r.old.remembered do
                local skipped = r.old.remembered[index]
                if not r.outsider or r.flagged[skipped.victim] ~= nil then
                    problems[#problems + 1] = ('%s: the witness lost %s'):format(r.label, hitKey(skipped))
                end
                dropped = dropped + 1
            end

            -- AND WHAT THE WITNESS ACTUALLY KEEPS is identical.
            local function kept_(list)
                local out = {}
                for _, hit in ipairs(list) do
                    if witnessKeeps(r.matches, hit.victim, hit.attacker) then out[#out + 1] = hitKey(hit) end
                end
                return out
            end
            local before, after = kept_(r.old.remembered), kept_(r.new.remembered)
            if not sameList(before, after) then
                problems[#problems + 1] = r.label .. ': what the witness keeps changed'
            end
            effective = effective + #after
        end
    end
    noneOf(problems, 'the witness was told something different')
    t.isTrue(kept >= 1500, ('only %d hits reached the witness'):format(kept))
    t.isTrue(effective >= 200, ('only %d hits were ones the witness keeps'):format(effective))
end)

t.test('DIFFERENTIAL COST: no outsider packet walks the server, and none reads more than the flagged set', function()
    local problems, oldTotal, newTotal, npcOnly = {}, 0, 0, 0
    for _, r in ipairs(RECORDS) do
        if r.old.ok and r.new.ok and r.outsider then
            if r.new.players ~= 0 then
                problems[#problems + 1] = r.label .. ': an outsider packet called GetPlayers'
            end
            -- One map of the flagged, at most, plus one cached answer checked
            -- per entry.
            local ceiling = 2 * r.flaggedCount + 2 * #r.ids
            if r.new.natives > ceiling then
                problems[#problems + 1] = ('%s: %d natives, more than %d'):format(r.label, r.new.natives, ceiling)
            end
            if not r.namesPlayer then
                npcOnly = npcOnly + 1
                oldTotal, newTotal = oldTotal + r.old.natives, newTotal + r.new.natives
            end
        end
    end
    noneOf(problems, 'an outsider packet cost too much')
    t.isTrue(npcOnly >= 300, ('only %d outsider packets named no player'):format(npcOnly))
    t.isTrue(newTotal * 2 < oldTotal,
        ('outsider packets naming no player cost %d natives in all, the old walk %d'):format(newTotal, oldTotal))
end)

t.test('DIFFERENTIAL COST: a fighter\'s packet still walks the server at most once', function()
    local problems = {}
    for _, r in ipairs(RECORDS) do
        if r.new.ok and not r.outsider and r.new.players > 1 then
            problems[#problems + 1] = ('%s: %d walks'):format(r.label, r.new.players)
        end
    end
    noneOf(problems, 'a packet walked the server more than once')
end)

-- ======================================================================
-- 5. THE WITNESS, END TO END, ON THE REAL ROUND
--
-- The shortcut is exact only while every fighter still standing in a live
-- round is flagged: the witness keeps a hit only on a standing fighter in a
-- live round, and an outsider's packet now resolves nobody who is not
-- flagged. These run the real lobby, the real round and the real witness.
-- ======================================================================

local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }

--- The real server files, three players on the server, and a way to fire
--- the engine's damage packet at any network id.
local function newWiredServer(mutate)
    local players = {}
    for src = 1, 3 do
        players[src] = {
            citizenid = ('CID%03d'):format(src), name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, handlers = {}, {}
    local clock = 1000
    local buckets, cancelled = {}, false
    local netIds = { [1] = 5001, [2] = 5002, [3] = 5003 }

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        GetPlayers = function()
            local out = {}
            for src in pairs(players) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetEntityCoords = function(ped)
            local src = (tonumber(ped) or 0) - 1000
            return { x = CENTRE.x + src * 2.0, y = CENTRE.y, z = CENTRE.z }
        end,
        NetworkGetNetworkIdFromEntity = function(ped)
            return netIds[(tonumber(ped) or 0) - 1000] or 0
        end,
        CancelEvent = function() cancelled = true end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        Player = function() return { state = { set = function() end } } end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            SwapWeapon = function() return true end,
            GrantSupply = function() return true end,
            PayKillAmmo = function() return true end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 1
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, match = env.ArenaMatch, lobby = env.ArenaLobby, netIds = netIds }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- Players 1 and 2 fight; 3 stays in town.
    function server.play()
        fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash' })
        matchId = server.lobby.All()[1].id
        fire('joinMatch', 2, { matchId = matchId, account = 'cash' })
        for src = 1, 2 do fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    --- The engine's own damage packet, naming network ids.
    function server.shoot(attacker, ids)
        cancelled = false
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do
            fn(tostring(attacker), { hitGlobalIds = ids })
        end
        return cancelled
    end

    function server.diesNamingNobody(src) fire('reportDeath', src, { why = 1 }) end
    function server.rowOf(src)
        local live = server.lobby.Get(matchId)
        return live and live.players[src]
    end
    function server.live() return (server.lobby.Get(matchId) or {}).state == 'live' end
    function server.flagged(src) return env.ArenaDispatch.GetPlayerMatchId(src) ~= nil end

    return server
end

t.test('THE INVARIANT: every fighter standing in a live round is flagged, and nobody standing is not', function()
    local server = newWiredServer()
    server.play()
    t.isTrue(server.live(), 'the round did not go live, so nothing below tests anything')
    for src = 1, 2 do
        t.isTrue(server.rowOf(src).alive == true, ('fighter %d is not standing'):format(src))
        t.isTrue(server.flagged(src), ('fighter %d is standing in a live round and not flagged'):format(src))
    end
    t.isFalse(server.flagged(3), 'the player in town was flagged')
end)

t.test('and a fighter sent home is out of the round BEFORE the flag comes down', function()
    -- spectateOnElimination off: the eliminated fighter goes home, so the
    -- flag comes down -- and by then the row reads not standing, so the
    -- witness would refuse a hit on them whoever fired it.
    local server = newWiredServer(function(config) config.Match.spectateOnElimination = false end)
    server.play()
    server.diesNamingNobody(2)
    t.isFalse(server.flagged(2), 'the fighter sent home is still flagged')
    t.isTrue(server.rowOf(2) == nil or server.rowOf(2).alive ~= true,
        'a fighter the round sent home still reads as standing in it')
    t.isFalse(server.match.RememberDamage(2, 1), 'the witness kept a hit on somebody sent home')
end)

t.test('END TO END: an outsider\'s NPC hit in between does not stop a fighter\'s kill being credited', function()
    local server = newWiredServer()
    server.play()
    t.isFalse(server.shoot(1, { 5002 }), 'a lawful shot between two fighters was cancelled')
    t.isFalse(server.shoot(3, { NPC }), 'an outsider\'s NPC hit was cancelled')
    server.diesNamingNobody(2)
    t.equals(server.rowOf(1).kills, 1, 'the server watched the kill land and credited nobody')
end)

t.test('and a fighter who respawned onto a new id is still found after an outsider\'s packet', function()
    -- The cache is left cold by an outsider's packet now, so the fighter's
    -- own miss is what finds the new id.
    local server = newWiredServer()
    server.play()
    t.isFalse(server.shoot(1, { 5002 }))
    server.netIds[2] = 91234
    t.isFalse(server.shoot(3, { NPC }))
    t.isTrue(server.shoot(3, { 91234 }), 'an outsider reached the respawned fighter')
    t.isFalse(server.shoot(1, { 91234 }), 'the fighter could not reach the respawned opponent')
    server.diesNamingNobody(2)
    t.equals(server.rowOf(1).kills, 1, 'the hit on the new id was not written down')
end)

t.test('and an outsider\'s own shot is never the kill the witness credits', function()
    local server = newWiredServer()
    server.play()
    t.isTrue(server.shoot(3, { 5002 }), 'an outsider shot a fighter')
    server.diesNamingNobody(2)
    t.equals(server.rowOf(1).kills, 0, 'a kill was credited for a shot the guard threw away')
    t.isTrue(server.rowOf(3) == nil, 'the outsider is on the roster, so this tests nothing')
end)

os.exit(t.summary())
