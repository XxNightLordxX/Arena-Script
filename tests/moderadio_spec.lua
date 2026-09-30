-- Crimson Arena: the team radio every team deathmatch fighter carries.

--[[
    tests/moderadio_spec.lua

    THE ASK: "on team deathmatch put a radio on every member" -- just the
    item, no channel. A mode's `extraItems` ride along with the supplies on
    a COPY of the loadout, so the exit's supply reclaim takes them back and a
    player's saved pick never grows a radio. The door's never-stash guard
    must know the name too, or one line of config would hand radios out for
    good. Harness borrowed from concurrent_spec.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('moderadio_spec')

local PLACES = {
    trailerpark = { x = 2344.4, y = 2565.1, z = 46.7 },
    skydome = { x = 1500.0, y = 3000.0, z = 1201.0 },
    atlantis = { x = 2344.4, y = 2565.1, z = 46.7 },
}

--- @param wallets table<integer, table> -- [src] = { cash = n, bank = n }
local function newServer(wallets, mutate)
    local players = {}
    for src, money in pairs(wallets) do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = money.cash or 0, bank = money.bank or 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local issued, refreshed = {}, {}
    local threads = Sandbox.newThreadRunner()
    local netEvents, console = {}, {}
    -- Who has actually been teleported into the arena, which is a different
    -- question to what the match calls its own state.
    local bucketOf = {}
    -- And WHERE, which is a third question again. GetEntityCoords below
    -- answers from this.
    local at = {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        -- CALLABLE, because server/dispatch.lua registers this resource's own
        -- exports with `exports('name', fn)` at load. A plain table raises
        -- there and takes the whole module down with it.
        exports = setmetatable(qbx.exports, { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        -- Nothing here drives a disconnect, so the handlers are taken and
        -- dropped rather than kept: an unused table that looks like a
        -- fixture is a fixture somebody will wonder why nothing uses.
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        -- IN WHICHEVER ARENA THIS FIGHTER WAS PUT, and this file is the one
        -- that needs the distinction: it is the only spec that runs matches
        -- at BOTH shipped arenas, and they are a kilometre apart vertically.
        -- A fixture answering one fixed point puts every skydome fighter
        -- 1,150m outside the fence they are standing inside, which
        -- Config.Match.serverChecks reads -- correctly -- as having walked
        -- out of the round. `runMatch` records where it sent people.
        GetEntityCoords = function(ped)
            local point = at[tonumber(ped) or -1] or PLACES.trailerpark
            return {
                x = point.x + ((tonumber(ped) or 0) % 16) * 3.0,
                y = point.y,
                z = point.z,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function(src, matchId, loadout) issued[#issued + 1] = { src = src, loadout = loadout }; return {} end, Reclaim = function() return 0 end,
            -- THE RESPAWN REFRESH. A stub missing it does not fail a test, it
            -- THROWS inside the respawn thread -- so leaving it out here
            -- breaks every spec that lets a fighter come back to life.
            Refresh = function(src, matchId, loadout) refreshed[#refreshed + 1] = { src = src, loadout = loadout }; return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        -- RECORDING, because playersArePlaced is exactly what decides whether
        -- a start may still be held, and it asks this double. A stub that
        -- always says "nobody is in the arena" would let the guard pass every
        -- test while never being exercised once.
        -- THE REAL ROUTING NATIVES, recorded. The whole question this file
        -- asks is which instance of the world each fighter is standing in,
        -- so the one module that answers it is the real one.
        -- The state bag server/dispatch.lua raises the arena flag on. Not
        -- what this file is about, but a nil call here takes the module down.
        Player = function() return { state = { set = function() end } } end,
        GetPlayerRoutingBucket = function(src) return bucketOf[src] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) bucketOf[src] = bucket end,
        SetRoutingBucketEntityLockdownMode = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    -- dispatch BEFORE the rest: lobby and match call ArenaDispatch at load
    -- time to decide what they can do.
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { issued = issued, refreshed = refreshed, env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, lobby = env.ArenaLobby,
        match = env.ArenaMatch, dispatch = env.ArenaDispatch }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- One pass of every captured coroutine, which is how the countdown
    --- thread gets to notice it has been stood down.
    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Stands these players in the middle of a named arena, so the server's
    --- own position reads agree with the round they are in.
    function server.placeIn(arenaKey, ids)
        local point = PLACES[arenaKey]
        if not point then error('no fixture coordinates for arena ' .. tostring(arenaKey), 2) end
        for _, src in ipairs(ids) do at[src] = point end
    end

    --- Which instance of the world one player is standing in.
    function server.bucket(src) return bucketOf[src] or 0 end

    --- Every player currently in some arena instance.
    function server.instanced()
        local out = {}
        for src, bucket in pairs(bucketOf) do
            if bucket ~= 0 then out[src] = bucket end
        end
        return out
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    return server
end



--- Opens a match on `arenaKey` with `ids` in it and starts it.
--- @return string matchId
local function runMatch(server, arenaKey, ids, modeKey)
    server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = modeKey or 'ffa', entryFee = 0 })

    -- The newest match, since earlier ones are still open.
    local match
    for _, entry in ipairs(server.lobby.All()) do
        if entry.hostSource == ids[1] then match = entry end
    end
    t.isNotNil(match, ('player %d could not open a lobby'):format(ids[1]))

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
        t.isNotNil(match.players[ids[index]], ('player %d could not join'):format(ids[index]))
    end

    -- WHERE THE SERVER WILL SEE THEIR BODIES, recorded before the round
    -- goes live rather than after: the fence reads a position on the very
    -- first sweep, and a fighter still standing at the last arena's
    -- coordinates is a fighter who has left this one.
    server.placeIn(arenaKey, ids)

    server.fire('startMatch', ids[1])
    server.step(6)
    return match.id
end


local function twoPlayers(mutate)
    return newServer({ [1] = { cash = 50000, bank = 50000 }, [2] = { cash = 50000, bank = 50000 } },
        function(config)
            config.Match.minPlayers = 2
            config.Match.lobbyCountdownSeconds = 0
            if mutate then mutate(config) end
        end)
end

local function radiosFor(server, src)
    local n, seen = 0, 0
    for _, call in ipairs(server.issued) do
        if call.src == src then
            seen = seen + 1
            for _, entry in ipairs((call.loadout or {}).supplies or {}) do
                if entry.item == 'radio' then n = n + (entry.count or 0) end
            end
        end
    end
    return n, seen
end

t.test('THE ASK: every team deathmatch fighter is issued one radio', function()
    local server = twoPlayers()
    runMatch(server, 'trailerpark', { 1, 2 }, 'tdm')
    for _, src in ipairs({ 1, 2 }) do
        local n, seen = radiosFor(server, src)
        t.isTrue(seen > 0, ('fighter %d was never issued anything'):format(src))
        t.equals(n, 1, ('fighter %d radios'):format(src))
    end
end)

t.test('free-for-all hands out no radio', function()
    local server = twoPlayers()
    runMatch(server, 'trailerpark', { 1, 2 }, 'ffa')
    local n, seen = radiosFor(server, 1)
    t.isTrue(seen > 0)
    t.equals(n, 0)
end)

t.test('the player\'s saved pick is not changed by the radio', function()
    local server = twoPlayers()
    runMatch(server, 'trailerpark', { 1, 2 }, 'tdm')
    for _, match in ipairs(server.lobby.All()) do
        for _, player in pairs(match.players or {}) do
            for _, entry in ipairs(((player.loadout or {}).supplies) or {}) do
                t.isTrue(entry.item ~= 'radio', 'the radio was written into the saved loadout')
            end
        end
    end
end)

t.test('ModeExtraItems: clamps, and drops junk and disabled modes', function()
    local server = twoPlayers(function(config)
        config.Modes.tdm.extraItems = {
            { item = 'radio', count = 50 }, { item = '', count = 1 }, { item = 'x', count = 0 }, 'junk',
        }
        config.Modes.ffa.extraItems = { { item = 'radio', count = 1 } }
        config.Modes.ffa.enabled = false
    end)
    local out = server.env.Arena.ModeExtraItems('tdm')
    t.equals(#out, 1)
    t.equals(out[1].item, 'radio')
    t.equals(out[1].count, 10)
    t.equals(#server.env.Arena.ModeExtraItems('ffa'), 0)
    t.equals(#server.env.Arena.ModeExtraItems(nil), 0)
end)

t.test('the radio is an arena item, so never-stash cannot hand it out for good', function()
    local server = twoPlayers()
    t.isTrue(server.env.Arena.AllIssuedItems().radio == true)
end)

t.test('removing extraItems from the mode removes the radio', function()
    local server = twoPlayers(function(config) config.Modes.tdm.extraItems = nil end)
    runMatch(server, 'trailerpark', { 1, 2 }, 'tdm')
    t.equals((radiosFor(server, 1)), 0)
end)

t.test('THE REVIEW: a death drops the radio, and the respawn top-up hands it back', function()
    local server = twoPlayers(function(config)
        config.Modes.tdm.lives = 3
        config.Match.lives = 3
    end)
    runMatch(server, 'trailerpark', { 1, 2 }, 'tdm')
    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.step(10)
    local tops, radio = 0, 0
    for _, call in ipairs(server.refreshed) do
        if call.src == 2 then
            tops = tops + 1
            for _, entry in ipairs((call.loadout or {}).supplies or {}) do
                if entry.item == 'radio' then radio = radio + 1 end
            end
        end
    end
    t.isTrue(tops > 0, 'no respawn top-up ran, so this proves nothing')
    t.isTrue(radio > 0, 'the respawn top-up left the radio out: lost for the round, owed at the exit')
end)

t.test('THE REVIEW: a server with no radio item hands none out and says so ONCE', function()
    local server = twoPlayers(function(config) config.Match.lives = 3; config.Modes.tdm.lives = 3 end)
    server.env.ArenaAmmo.HasItem = function(name) return name ~= 'radio' end
    runMatch(server, 'trailerpark', { 1, 2 }, 'tdm')
    server.fire('reportDeath', 2, { killerServerId = 1 })
    server.step(10)
    t.equals((radiosFor(server, 1)), 0, 'a radio was issued that ox does not have')
    local _, lines = server.log():gsub('no item called "radio"', '')
    t.equals(lines, 1, 'the missing item was named ' .. lines .. ' times, not once')
end)

os.exit(t.summary())
