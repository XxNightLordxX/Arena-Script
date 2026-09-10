--[[
    crimson_arena/tests/unwitnessedclaim_spec.lua

    A DEATH REPORT THAT NAMES A NON-FIGHTER IS A DEATH THAT NAMES NOBODY.

    resolveKiller refuses a killer claim that is nil, non-positive, the
    victim, or not on the roster. The unwitnessed-death price asked a
    different question -- nil-or-self only -- so a claim of 0, -1, or a
    stranger's server id was refused as a kill AND excused from the price,
    with no UNATTRIBUTED line. The honest client never sends those (it sends
    no id when it has nobody to name); a modded one could, and got a free,
    silent death on every report. Fourteen deaths 5.5s apart sit inside the
    60s window, so the seventh onward are priced: eight of them.
]]
local t = dofile('testkit.lua')
print('unwitnessedclaim_spec')
local Sandbox = dofile('fixtures/sandbox.lua')

local function newServer()
    local centre = { x = 2344.4, y = 2565.1, z = 46.7 }
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host',  money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents, flags = {}, {}, {}
    local logs = {}
    local refreshes = {}
    local now = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) logs[#logs + 1] = tostring(line) end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return now end,
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = centre.x + ((tonumber(ped) or 0) % 16) * 3.0, y = centre.y, z = centre.z }
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
            Refresh = function(src) refreshes[#refreshes + 1] = src return true end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function(src, matchId) flags[src] = matchId end,
            Clear = function(src) flags[src] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return flags[src] ~= nil end,
            GetPlayerMatchId = function(src) return flags[src] end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.minPlayers = 2
    -- SHIPPED numbers left alone otherwise: lives default 3 is too few for 14
    -- deaths, so only the life count is raised. Everything the finding depends
    -- on -- respawnDelaySeconds 5, serverChecks, Debug -- is untouched.
    env.Config.Match.lives = { allowChoose = true, min = 1, max = 10, default = 3 }
    env.Config.Match.winCondition = { allowChoose = true, default = 'score_limit' }

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local s = { env = env, lobby = env.ArenaLobby, match = env.ArenaMatch, logs = logs, refreshes = refreshes, sent = sent }
    function s.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end
    function s.step(n) for _ = 1, (n or 1) do threads.step() end end
    function s.setNow(v) now = v end
    function s.getNow() return now end
    function s.standIn(arenaKey)
        local arena = env.Arena.GetArenaByKey(arenaKey)
        local b = arena and env.Arena.BoundaryOf(arena)
        local p = b and b.center
        assert(p, 'no boundary for ' .. tostring(arenaKey))
        centre = { x = p.x, y = p.y, z = p.z }
    end
    return s
end

local function liveRound()
    local s = newServer()
    local arenas = s.env.Arena.GetEnabledArenas()
    local arenaKey = arenas[1].key
    s.standIn(arenaKey)
    local matchId, err = s.lobby.Create(1, arenaKey, nil, 0, nil, nil, nil, nil, 'score_limit', nil, 25)
    assert(matchId, tostring(err))
    assert(s.lobby.Join(2, matchId, nil, nil))
    s.lobby.SetReady(1, true); s.lobby.SetReady(2, true)
    local ok, why = s.match.Start(matchId)
    assert(ok, tostring(why))
    s.step()
    local m = s.lobby.Get(matchId)
    assert(m.state == 'live', 'not live: ' .. tostring(m.state))
    return s, matchId, arenaKey
end

local function run(label, payloadFor, deaths)
    local s, matchId, arenaKey = liveRound()
    local match = s.lobby.Get(matchId)
    local base = #s.logs
    local refreshBase = #s.refreshes
    local notifyRespawnDelays = {}
    local sentBase = #s.sent

    for i = 1, deaths do
        s.setNow(s.getNow() + 5500)
        local entry = match.players[2]
        assert(entry.alive, ('death %d: victim was not alive, cannot report'):format(i))
        s.fire('reportDeath', 2, payloadFor())
        assert(entry.alive == false, ('death %d: report was refused'):format(i))
        -- run the respawn thread to completion
        s.step(4)
        assert(entry.alive, ('death %d: never respawned'):format(i))
    end

    local unattributedLog, unattributedDebug, pricedLog, unverified = 0, 0, 0, 0
    for i = base + 1, #s.logs do
        local line = s.logs[i]
        if line:find('UNATTRIBUTED', 1, true) then
            if line:find('%[debug%]') then unattributedDebug = unattributedDebug + 1
            else unattributedLog = unattributedLog + 1 end
        end
        if line:find('named nobody %-%- %d+ of them inside') then pricedLog = pricedLog + 1 end
        if line:find('unverified kill claim', 1, true) then unverified = unverified + 1 end
    end

    local toasts, respawnNotices = 0, {}
    for i = sentBase + 1, #s.sent do
        local msg = s.sent[i]
        if msg.event == 'crimson_arena:client:notify' and msg.target == 2 then
            local d = tostring((msg.payload or {}).description or '')
            if d:find('Nothing could be pinned on anybody', 1, true) then toasts = toasts + 1 end
            local secs = d:match('Back in the fight in (%d+)')
            if secs then respawnNotices[#respawnNotices + 1] = secs end
        end
    end

    if false then print(('%-28s arena=%-12s resupplies=%2d  pricedLOG=%2d  UNATTRIB(log)=%2d UNATTRIB(dbg)=%2d  toasts=%d  unverified=%2d  respawnWaits=%s')
        :format(label, arenaKey, #s.refreshes - refreshBase, pricedLog, unattributedLog, unattributedDebug,
            toasts, unverified, table.concat(respawnNotices, ','))) end
    return { resupplies = #s.refreshes - refreshBase, priced = pricedLog, unattrib = unattributedLog, toasts = toasts }
end


local DEATHS, PRICED = 14, 8

t.test('CONTROL: a report with no killer at all is priced by the rate', function()
    local r = run('nil', function() return {} end, DEATHS)
    t.equals(r.priced, PRICED, 'the honest no-id report is not priced, so this proves nothing')
end)

t.test('CONTROL: naming yourself is naming nobody', function()
    local r = run('self', function() return { killerServerId = 2 } end, DEATHS)
    t.equals(r.priced, PRICED, 'naming yourself escaped the price')
end)

t.test('DEFECT: a killer id of 0 was refused as a kill and excused from the price', function()
    local r = run('zero', function() return { killerServerId = 0 } end, DEATHS)
    t.equals(r.priced, PRICED, 'a claim of 0 bought a free, silent death every time')
end)

t.test('DEFECT: a negative killer id did the same', function()
    local r = run('neg', function() return { killerServerId = -1 } end, DEATHS)
    t.equals(r.priced, PRICED, 'a claim of -1 bought a free, silent death every time')
end)

t.test('DEFECT: a server id that is nobody in the round did the same', function()
    local r = run('stranger', function() return { killerServerId = 999 } end, DEATHS)
    t.equals(r.priced, PRICED, 'naming a stranger bought a free, silent death every time')
end)

os.exit(t.summary())
