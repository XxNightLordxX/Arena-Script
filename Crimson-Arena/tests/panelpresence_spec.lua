--[[
    crimson_arena/tests/panelpresence_spec.lua

    WHO THE SERVER KEEPS SENDING SNAPSHOTS TO.

    Every lobby change broadcasts a fresh snapshot, and the recipient list is
    built from three things: who is in a match, who is spectating one, and
    who has the PANEL OPEN. The third is a flag the server keeps per player,
    raised when they open the panel and lowered when they close it.

    Asking for a snapshot was treated as opening the panel, and those are not
    the same act. client/spectate.lua asks for one when the camera starts --
    the roster it needs to name the living only exists in a snapshot -- with
    the panel shut. That raised the flag, and nothing ever lowered it: the
    player kept receiving every state broadcast on the server for the rest of
    their session, long after they had stopped watching anything.

    Nothing in this suite covered panel presence at all, which is why a flag
    that is only ever raised went unnoticed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('panelpresence_spec')

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
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent = {}, {}, {}
    -- Held rather than built inline: the panel opens through an ox_lib
    -- CALLBACK rather than a net event, so the tests need to reach it.
    local oxlib = Sandbox.newOxLib()
    -- Who has actually been teleported into the arena, which is a different
    -- question to what the match calls its own state.
    local inArena = {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = oxlib,
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
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
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
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
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        -- RECORDING, because playersArePlaced is exactly what decides whether
        -- a start may still be held, and it asks this double. A stub that
        -- always says "nobody is in the arena" would let the guard pass every
        -- test while never being exercised once.
        ArenaDispatch = {
            Set = function(src) inArena[src] = true end,
            Clear = function(src) inArena[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return inArena[src] == true end,
            EnterBucket = function(src) inArena[src] = true end,
            ExitBucket = function(src) inArena[src] = nil end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, lobby = env.ArenaLobby }

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

    --- How many state snapshots one player has been sent.
    function server.snapshotsTo(src)
        local hits = 0
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:state' and message.target == src then
                hits = hits + 1
            end
        end
        return hits
    end

    --- Forgets what has been sent so far, so a count means "since this line".
    function server.forgetSent()
        for index = #sent, 1, -1 do sent[index] = nil end
    end

    --- The ox_lib callback the panel opens with, called the way ox_lib calls it.
    function server.callback(name, src)
        local fn = oxlib.callbacks['crimson_arena:server:' .. name]
        if not fn then error('no callback registered for ' .. name, 2) end
        return fn(src)
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    return server
end



--- One player, no match, nothing open.
local function idle()
    return newServer({ [1] = { cash = 1000, bank = 1000 }, [2] = { cash = 1000, bank = 1000 } })
end

--- Something that makes the lobby broadcast, without involving the player
--- whose presence is under test.
local function stirTheLobby(server)
    server.fire('createMatch', 2, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
end

-- ======================================================================
-- OPENING THE PANEL
-- ======================================================================

t.test('opening the panel puts a player on the broadcast list', function()
    local server = idle()
    server.callback('getState', 1)
    server.forgetSent()

    stirTheLobby(server)
    t.isTrue(server.snapshotsTo(1) > 0,
        'somebody with the panel open was not told the lobby changed')
end)

t.test('and closing it takes them off again', function()
    local server = idle()
    server.callback('getState', 1)
    server.fire('panelClosed', 1)
    server.forgetSent()

    stirTheLobby(server)
    t.equals(server.snapshotsTo(1), 0,
        'a closed panel is still being sent every change on the server')
end)

t.test('the panel refreshing itself still counts as open', function()
    local server = idle()
    server.fire('requestState', 1, { panel = true })
    server.forgetSent()

    stirTheLobby(server)
    t.isTrue(server.snapshotsTo(1) > 0,
        'the panel refreshed and was dropped from the broadcast list')
end)

-- ======================================================================
-- ASKING FOR ONE WITHOUT THE PANEL
-- ======================================================================

t.test('DEFECT: asking for a snapshot is not opening the panel', function()
    -- What client/spectate.lua does when the camera starts. It is answered --
    -- the snapshot is the only place the living-player list exists -- but it
    -- must not enrol the asker in every broadcast for the rest of the
    -- session, because nothing they do afterwards will ever unenrol them.
    local server = idle()
    server.fire('requestState', 1, nil)

    t.isTrue(server.snapshotsTo(1) > 0, 'the request was not answered at all')
    server.forgetSent()

    stirTheLobby(server)
    t.equals(server.snapshotsTo(1), 0,
        'ASKING FOR A SNAPSHOT ENROLLED THEM PERMANENTLY -- and nothing ever removes them')
end)

t.test('and an empty payload is not a claim either', function()
    local server = idle()
    server.fire('requestState', 1, {})
    server.forgetSent()

    stirTheLobby(server)
    t.equals(server.snapshotsTo(1), 0)
end)

t.test('but somebody actually IN a match is told regardless', function()
    -- The flag is not the only route onto the list, and a fix that made it
    -- the only route would silence the people who need it most.
    local server = idle()
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa', entryFee = 0 })
    server.fire('panelClosed', 1)
    server.forgetSent()

    server.fire('joinMatch', 2, { matchId = server.lobby.All()[1].id })
    t.isTrue(server.snapshotsTo(1) > 0,
        'a player in a lobby stopped being told who was joining it')
end)

os.exit(t.summary())
