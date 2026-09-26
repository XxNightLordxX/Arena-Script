--[[
    crimson_arena/tests/deathbroadcast_spec.lua

    A DEATH THE ROOM DOES NOT NEED TO HEAR ABOUT IS NOT BROADCAST.

    ArenaMatch.OnDeath ended with an unconditional ArenaLobby.Broadcast: the
    whole state snapshot -- config block, every lobby, a per-head player row
    -- rebuilt and sent to every fighter, every watcher, every open panel and
    every fenced player on the server, for EVERY death. A 20-player round
    with three onlookers paid about 50 KB for each one, and a most_kills or
    score_limit round is nothing but respawning deaths.

    MEASURED BEFORE IT WAS CHANGED, AND MEASURED HERE AGAIN: across every
    mode and win condition, a respawning death in a round that plays no
    ladder moves exactly two numbers in the snapshot -- the killer row's
    `kills` and the victim row's `deaths` -- and no consumer of the state
    event reads either of them off a match row. The panel draws kills and
    deaths only from the HUD, the results, the leaderboard and the admin
    payloads; client/spectate.lua reads a row's id and alive; client/main.lua
    reads the player block, the schedule and the fence; client/exports.lua
    reads no snapshot at all; client/ui.lua hands the state to the panel.

    SO THE BROADCAST STAYS WHERE A DEATH CHANGES SOMETHING SOMEBODY SEES:

      AN ELIMINATION (no lives left). The room learns the fighter is out:
      spectator target lists, the "Out of the round" bet row, the chips
      betPickOptions offers, the sent-home fighter's fence. The note in
      ArenaLobby.AddSpectator names this broadcast as the one the room
      depends on.

      A LADDER. Every gun game death moves a tier and the fighter's own
      loadout is in the snapshot (settleTier writes it).

      A DEATH THAT DECIDES THE ROUND. The snapshot's betsOpen reads
      ArenaMatch.IsDecided, so a score-limit kill shuts the watchers' book --
      and every open panel has to be told at once, not a second later when
      the sweep ends the round.

    What this file holds to: the three broadcasts above each reach every
    recipient; a death that is none of them pushes nothing; the next
    broadcast of any kind still carries the counts; and -- the differential
    -- over a seeded run of deaths the pushes that remain are exactly the old
    ones, and at every skipped one the snapshot each recipient WOULD have
    been sent differs from the last one they got only in fields no consumer
    reads.

    Deterministic throughout: os.time and GetGameTimer are the fixture's,
    and the random runs draw from a local generator with a fixed seed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('deathbroadcast_spec')

local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }
local START = 1700000000
local STATE = 'crimson_arena:client:state'

local FIGHTERS = { 1, 2, 3, 4, 5, 6 }
--- 11 watches, 12 has the panel open, 13 was fenced and closed the panel.
local ONLOOKERS = { 11, 12, 13 }

-- ======================================================================
-- THE SERVER
-- ======================================================================

--- The real util, betting, lobby, match and main, with a dispatch stub that
--- keeps the in-arena flag the keep-out fence and the bucket sweep read.
--- @param mutate fun(config: table)?
--- @return table server
local function newServer(mutate)
    local players = {}
    local everyone = {}
    for _, src in ipairs(FIGHTERS) do everyone[#everyone + 1] = src end
    for _, src in ipairs(ONLOOKERS) do everyone[#everyone + 1] = src end
    for _, src in ipairs(everyone) do
        players[src] = {
            citizenid = ('CID%03d'):format(src), name = ('Player %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent, inArena = {}, {}, {}, {}
    local clock, now = 1000, START
    local last = {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        os = setmetatable({ time = function() return now end }, { __index = os }),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
            if event == STATE then last[target] = payload end
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[tonumber(src)] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = CENTRE.x + ((tonumber(ped) or 0) % 16) * 2.0, y = CENTRE.y, z = CENTRE.z }
        end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
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
            GrantRounds = function() return true end,
            PayKillAmmo = function() return true end,
        },
        ArenaDispatch = {
            Set = function(src) inArena[tonumber(src)] = true end,
            Clear = function(src) inArena[tonumber(src)] = nil end,
            Revive = function() end,
            IsPlayerInArena = function(src) return inArena[tonumber(src)] ~= nil end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 3
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = true
    env.Config.Modes.gungame.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, console = console, sent = sent, last = last,
        match = env.ArenaMatch, lobby = env.ArenaLobby, Arena = env.Arena }
    local matchId

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        clock = clock + 60000
        env.source = src
        handler(data)
    end

    --- Opens and starts a round through the ready path. Stops the moment it
    --- is live, so goLive's scheduled bets-close broadcast is still pending.
    function server.play(count, modeKey, winCondition, scoreLimit)
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey or 'ffa', entryFee = 0, account = 'cash',
            winCondition = winCondition, scoreLimit = scoreLimit, lives = env.Config.Match.lives,
        })
        local all = server.lobby.All()
        matchId = all[#all].id
        for src = 2, count do server.fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        if server.Arena.ModeUsesTeams(modeKey or 'ffa') then
            for src = 1, count do
                server.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        for src = 1, count do server.fire('setReady', src, { ready = true }) end
        for _ = 1, 6 do
            if server.lobby.Get(matchId).state == 'live' then break end
            threads.step()
        end
        assert(server.lobby.Get(matchId).state == 'live', 'the fixture failed to start the round')
        return server.lobby.Get(matchId)
    end

    function server.live() return server.lobby.Get(matchId) end
    function server.matchId() return matchId end
    function server.step(times) for _ = 1, (times or 1) do threads.step() end end
    function server.at(seconds) now = START + seconds end

    --- The three kinds of onlooker, set up the way players become them.
    function server.onlookers()
        server.fire('spectateMatch', 11, { matchId = matchId })
        server.fire('requestState', 12, { panel = true })
        server.fire('requestState', 13, { panel = true })
        server.fire('panelClosed', 13)
    end

    --- Every state push since `mark`, as { [target] = count } and a total.
    function server.pushesSince(mark)
        local by, total = {}, 0
        for index = mark + 1, #sent do
            if sent[index].event == STATE then
                by[sent[index].target] = (by[sent[index].target] or 0) + 1
                total = total + 1
            end
        end
        return by, total
    end

    --- One death, and the state pushes it caused.
    function server.die(victim, killer)
        local mark = #sent
        local ok = server.match.OnDeath(victim, killer)
        local by, total = server.pushesSince(mark)
        return ok, by, total, mark
    end

    return server
end

--- Every leaf that differs between two snapshots, as dotted paths.
local function diff(a, b, path, out)
    out = out or {}
    path = path or ''
    if type(a) ~= 'table' or type(b) ~= 'table' then
        if a ~= b then out[#out + 1] = path end
        return out
    end
    for key, value in pairs(a) do diff(value, b[key], path .. '.' .. tostring(key), out) end
    for key, value in pairs(b) do
        if a[key] == nil then diff(nil, value, path .. '.' .. tostring(key), out) end
    end
    return out
end

--- The fields a respawning death may move without anybody being told:
--- a match row's kills and deaths, and nothing else.
local function unreadField(path)
    return path:match('^%.matches%.%d+%.players%.%d+%.kills$') ~= nil
        or path:match('^%.matches%.%d+%.players%.%d+%.deaths$') ~= nil
end

local function rowIndexOf(snapshot, matchId, src)
    for mi, match in ipairs(snapshot.matches or {}) do
        if match.id == matchId then
            for pi, row in ipairs(match.players or {}) do
                if row.id == src then return mi, pi, row end
            end
        end
    end
    return nil
end

local function rowOf(snapshot, matchId, src)
    local _, _, row = rowIndexOf(snapshot, matchId, src)
    return row
end

local function matchOf(snapshot, matchId)
    for _, match in ipairs(snapshot.matches or {}) do
        if match.id == matchId then return match end
    end
    return nil
end

local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return ((state // 65536) % n) + 1
    end
end

local SETUPS = {}
for _, mode in ipairs({ 'ffa', 'tdm', 'gungame' }) do
    for _, win in ipairs({ 'last_standing', 'most_kills', 'score_limit' }) do
        SETUPS[#SETUPS + 1] = { mode = mode, win = win }
    end
end

-- ======================================================================
-- WHAT A RESPAWNING DEATH CHANGES, FOR EVERY VIEWER
-- ======================================================================

t.test('PIN: EVERY VIEWER, EVERY MODE, EVERY WIN CONDITION: a respawning death moves kills and deaths and nothing else',
function()
    -- THE PREMISE THE WHOLE CHANGE RESTS ON, re-measured on this code. The
    -- viewers are every kind of recipient Broadcast has: fighters (one of
    -- them eliminated and watching in a round that eliminates), a watcher
    -- who never fought, a bystander with the panel open, and one the fence
    -- keeps a recipient after the panel closed. Three deaths each: a
    -- credited kill, a death that names nobody, and a claim the roster
    -- refuses.
    for _, setup in ipairs(SETUPS) do
        local s = newServer(function(config) config.Match.lives = 2 end)
        local match = s.play(6, setup.mode, setup.win, setup.win == 'score_limit' and 50 or nil)
        s.onlookers()
        s.step(2)
        if setup.win == 'last_standing' and setup.mode ~= 'gungame' then
            s.match.OnDeath(6, 1)
            s.step()
            s.match.OnDeath(6, 1)
            s.step()
            t.isTrue(s.Arena.IsEliminated(match.players[6]), setup.mode .. ': fighter 6 was not eliminated')
        end
        s.step(2)

        local viewers = { 1, 2, 3, 4, 5, 6, 11, 12, 13 }
        for _, death in ipairs({ { 3, 2 }, { 4, nil }, { 5, 3 } }) do
            local before = {}
            for _, src in ipairs(viewers) do before[src] = s.lobby.BuildState(src) end
            local killsWas = death[2] and match.players[death[2]].kills or nil

            local victimLives = s.Arena.ToInt(match.players[death[1]].lives) or 0
            t.isTrue(victimLives > 1 or setup.win ~= 'last_standing' or setup.mode == 'gungame',
                'the victim is on their last life, so this death is not a respawning one')
            s.match.OnDeath(death[1], death[2])
            local credited = death[2] ~= nil and match.players[death[2]].kills ~= killsWas

            for _, src in ipairs(viewers) do
                local after = s.lobby.BuildState(src)
                local paths = diff(before[src], after)
                local unexpected = {}
                for _, path in ipairs(paths) do
                    if not unreadField(path) then unexpected[#unexpected + 1] = path end
                end
                local label = ('%s/%s viewer %d, death %s by %s'):format(setup.mode, setup.win, src,
                    tostring(death[1]), tostring(death[2]))

                if setup.mode == 'gungame' then
                    -- THE LADDER IS WHY IT KEEPS ITS BROADCAST: a credited
                    -- kill promotes the killer, and the killer's own
                    -- snapshot carries the new loadout.
                    if credited and src == death[2] then
                        t.isTrue(#unexpected > 0, label .. ': a promotion changed nothing but the counts')
                    end
                else
                    t.equals(#unexpected, 0, label .. ' moved a field somebody reads: '
                        .. table.concat(unexpected, ', '))
                    -- And the two it does move are the victim's deaths and,
                    -- only when credited, the killer's kills.
                    local mi, pi = rowIndexOf(before[src], match.id, death[1])
                    local wanted = { [('.matches.%d.players.%d.deaths'):format(mi or 0, pi or 0)] = true }
                    if credited then
                        local ki, kj = rowIndexOf(before[src], match.id, death[2])
                        wanted[('.matches.%d.players.%d.kills'):format(ki or 0, kj or 0)] = true
                    end
                    local count = 0
                    for _, path in ipairs(paths) do
                        count = count + 1
                        t.isTrue(wanted[path], label .. ': an unexpected count moved: ' .. path)
                    end
                    local expected = 0
                    for _ in pairs(wanted) do expected = expected + 1 end
                    t.equals(count, expected, label .. ': the counts did not move as the death says')
                end
            end
            s.step()
        end
    end
end)

-- ======================================================================
-- AND NOTHING ON THE CLIENT READS THOSE TWO FIELDS
-- ======================================================================

--- Natives the client realm calls on these paths, whose answers decide
--- nothing here.
local CLIENT_SILENT = {
    'FreezeEntityPosition', 'SetEntityVisible', 'SetEntityCollision', 'SetLocalPlayerVisibleLocally',
    'SetEntityCoordsNoOffset', 'SetEntityHeading', 'RenderScriptCams', 'DestroyCam', 'SetCamActive',
    'SetCamCoord', 'SetCamRot', 'PointCamAtEntity', 'ClearFocus', 'SetFocusEntity', 'SetFocusPosAndVel',
    'DisableAllControlActions', 'EnableControlAction', 'DisableControlAction', 'RequestCollisionAtCoord',
    'SetBlipSprite', 'SetBlipColour', 'SetBlipDisplay', 'SetBlipAsShortRange', 'SetBlipScale',
    'BeginTextCommandSetBlipName', 'AddTextComponentSubstringPlayerName', 'EndTextCommandSetBlipName',
    'RemoveBlip', 'SetEntityDrawOutline', 'SetEntityDrawOutlineColor', 'SetEntityDrawOutlineShader',
    'SetNuiFocus', 'SetNuiFocusKeepInput', 'TriggerServerEvent', 'RegisterNUICallback',
    'RegisterCommand', 'RegisterKeyMapping', 'SetEntityInvincible', 'SetPlayerInvincible',
}

--- The whole client realm, loaded the way FXServer loads it -- the
--- manifest's own list and order -- behind a registry that keeps EVERY
--- handler an event has, so a state push reaches client/main.lua,
--- client/ui.lua and client/spectate.lua exactly as it does in the game.
local function newClient()
    local runner = Sandbox.newThreadRunner()
    local handlers, nui = {}, {}
    local function register(name, fn)
        handlers[name] = handlers[name] or {}
        handlers[name][#handlers[name] + 1] = fn
    end
    local overrides = {
        CreateThread = runner.CreateThread, Wait = runner.Wait,
        RegisterNetEvent = register, AddEventHandler = register,
        SendNUIMessage = function(message) nui[#nui + 1] = message end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function() return 'missing' end,
        print = function() end,
        joaat = function(value) return #tostring(value) end,
        PlayerPedId = function() return 1001 end, PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 11 end,
        GetPlayerFromServerId = function(id) return id end,
        GetPlayerPed = function(id) return 1000 + (tonumber(id) or 0) end,
        NetworkIsPlayerActive = function() return true end,
        DoesEntityExist = function() return true end,
        IsEntityDead = function() return false end,
        IsEntityVisible = function() return true end,
        GetEntityCollisionDisabled = function() return false end,
        GetEntityCoords = function() return { x = CENTRE.x, y = CENTRE.y, z = CENTRE.z } end,
        GetEntityHeading = function() return 0.0 end,
        GetEntityHealth = function() return 200 end,
        GetGameTimer = function() return 0 end,
        CreateCam = function() return 900 end,
        IsDisabledControlJustPressed = function() return false end,
        IsDisabledControlPressed = function() return false end,
        GetDisabledControlNormal = function() return 0.0 end,
        AddBlipForEntity = function() return 1 end, DoesBlipExist = function() return true end,
        GetBlipInfoIdEntityIndex = function() return 0 end,
        IsPauseMenuActive = function() return false end,
        IsDuplicityVersion = function() return false end,
        lib = { callback = { await = function() return nil end }, notify = function() end },
        exports = setmetatable({}, { __call = function() end }),
    }
    for _, name in ipairs(CLIENT_SILENT) do overrides[name] = function() end end
    local env = Sandbox.newEnv(overrides)
    local manifest = Sandbox.readDeclarations('../Crimson-Arena/fxmanifest.lua')
    local loaded = {}
    for _, name in ipairs(Sandbox.realmScripts(manifest, 'client')) do
        Sandbox.loadInto('../Crimson-Arena/' .. name, env)
        loaded[name] = true
    end
    return {
        env = env, nui = nui, loaded = loaded,
        count = function(name) return #(handlers[name] or {}) end,
        fire = function(name, ...)
            for _, handler in ipairs(handlers[name] or {}) do handler(...) end
        end,
    }
end

--- The same snapshot, with every match row replaced by a stand-in that
--- writes down each field anybody reads off it.
local function watched(snapshot, reads)
    local copy = {}
    for key, value in pairs(snapshot) do copy[key] = value end
    copy.matches = {}
    for mi, match in ipairs(snapshot.matches or {}) do
        local m = {}
        for key, value in pairs(match) do m[key] = value end
        m.players = {}
        for pi, row in ipairs(match.players or {}) do
            m.players[pi] = setmetatable({}, {
                __index = function(_, key) reads[key] = (reads[key] or 0) + 1; return row[key] end,
                __pairs = function() reads['(every field)'] = (reads['(every field)'] or 0) + 1; return next, row, nil end,
                __len = function() return #row end,
            })
        end
        copy.matches[mi] = m
    end
    return copy
end

t.test('PIN: no client file reads kills or deaths off a match row -- the whole realm, fed real snapshots', function()
    -- THE OTHER HALF OF THE PREMISE. Every client-realm file the manifest
    -- loads, every handler the state event has, fed the snapshots the
    -- server really builds for a fighter, a watcher, an eliminated fighter
    -- watching, and a bystander with the panel open. Every field read off a
    -- match row is written down; kills and deaths must never be among them.
    -- client/ui.lua hands the state on to the panel without reading it;
    -- tests/panel/deathstate.test.js holds the panel to the same.
    local s = newServer(function(config) config.Match.lives = 1 end)
    local match = s.play(4, 'tdm', 'last_standing')
    s.onlookers()
    s.step(2)
    s.match.OnDeath(4, 1)
    s.step()
    t.isTrue(s.Arena.IsEliminated(match.players[4]), 'premise: fighter 4 is out and watching')

    local client = newClient()
    t.isTrue(client.loaded['client/main.lua'] and client.loaded['client/ui.lua']
        and client.loaded['client/spectate.lua'] and client.loaded['client/exports.lua'],
        'the client realm did not load the files this is about')
    t.isTrue(client.count(STATE) >= 3, 'fewer state handlers than main, ui and spectate register')

    local reads = {}
    for _, viewer in ipairs({ 1, 4, 11, 12, 13 }) do
        local snapshot = s.lobby.BuildState(viewer)
        local ok, err = pcall(client.fire, STATE, watched(snapshot, reads))
        t.isTrue(ok, 'the client realm threw on viewer ' .. viewer .. '\'s snapshot: ' .. tostring(err))
    end

    t.isNil(reads.kills, 'a client file read `kills` off a match row')
    t.isNil(reads.deaths, 'a client file read `deaths` off a match row')
    t.isNil(reads['(every field)'], 'a client file walked every field of a match row')
    -- AND THE STAND-INS WERE REALLY READ, or the two lines above prove
    -- nothing: the spectate camera rebuilds its targets from id and alive.
    t.isTrue((reads.id or 0) > 0 and (reads.alive or 0) > 0,
        'nothing read a match row at all, so the stand-ins were never reached')
    local forwarded = 0
    for _, message in ipairs(client.nui) do
        if message.action == 'state' then forwarded = forwarded + 1 end
    end
    t.equals(forwarded, 5, 'client/ui.lua did not hand every state on to the panel')
end)

-- ======================================================================
-- THE DEFECT, AND ITS BUDGET
-- ======================================================================

t.test('DEFECT: a respawning death in a round with no ladder, which decides nothing, pushes no state at all', function()
    -- Every mode without a ladder, every win condition, betting on and off,
    -- and three kinds of death: a credited kill, a death naming nobody, and
    -- a claim naming somebody who is not in the round.
    for _, setup in ipairs(SETUPS) do
        for _, betting in ipairs({ true, false }) do
            if setup.mode ~= 'gungame' then
                local s = newServer(function(config) config.Betting.enabled = betting end)
                local match = s.play(6, setup.mode, setup.win, setup.win == 'score_limit' and 50 or nil)
                s.onlookers()
                s.step(2)
                for _, death in ipairs({ { 3, 2 }, { 4, nil }, { 5, 99 } }) do
                    local ok, _, total = s.die(death[1], death[2])
                    t.isTrue(ok == true, 'the death was refused, so this proves nothing')
                    t.isTrue(not s.Arena.IsEliminated(match.players[death[1]]), 'the death eliminated them')
                    t.equals(total, 0, ('%s/%s betting=%s: a respawning death by %s pushed %d state snapshot(s)')
                        :format(setup.mode, setup.win, tostring(betting), tostring(death[2]), total))
                    s.step()
                end
            end
        end
    end
end)

t.test('BUDGET: thirty respawning deaths cost nothing; the one elimination costs one push per recipient', function()
    local s = newServer(function(config) config.Match.lives = 50 end)
    local match = s.play(6, 'ffa', 'last_standing')
    s.onlookers()
    s.step(2)

    local mark = #s.sent
    local random = generator(7)
    for _ = 1, 30 do
        local victim = random(6)
        local killer = random(7)
        s.match.OnDeath(victim, killer <= 6 and killer ~= victim and killer or nil)
        s.step()
    end
    local _, total = s.pushesSince(mark)
    t.equals(total, 0, 'thirty respawning deaths pushed ' .. total .. ' state snapshot(s)')

    match.players[4].lives = 1
    match.players[4].alive = true
    local _, by, pushes = s.die(4, 1)
    for _, src in ipairs({ 1, 2, 3, 4, 5, 6, 11, 12, 13 }) do
        t.isTrue((by[src] or 0) >= 1, 'the elimination did not reach ' .. src)
    end
    -- The broadcast reaches nine; the eliminated fighter also gets their own
    -- push from AddSpectator. Nothing else.
    t.equals(pushes, 10, 'the elimination pushed more or fewer snapshots than one per recipient')
end)

-- ======================================================================
-- THE THREE BROADCASTS THAT STAY
-- ======================================================================

t.test('PIN: AN ELIMINATION STILL TELLS THE WHOLE ROOM, with the fighter out on every copy', function()
    for _, mode in ipairs({ 'ffa', 'tdm' }) do
        for _, watching in ipairs({ true, false }) do
            local s = newServer(function(config)
                config.Match.lives = 1
                config.Match.spectateOnElimination = watching
            end)
            local match = s.play(6, mode, 'last_standing')
            s.onlookers()
            s.step(2)

            local ok, by = s.die(3, 2)
            t.isTrue(ok == true, 'the death was refused')
            t.isTrue(s.Arena.IsEliminated(match.players[3]), 'premise: the death eliminated them')
            for _, src in ipairs({ 1, 2, 3, 4, 5, 6, 11, 12, 13 }) do
                t.isTrue((by[src] or 0) >= 1, ('%s watching=%s: the elimination never reached %d')
                    :format(mode, tostring(watching), src))
                local row = rowOf(s.last[src] or {}, match.id, 3)
                t.isTrue(row ~= nil and row.alive == false,
                    ('%s watching=%s: %d was not told fighter 3 is out'):format(mode, tostring(watching), src))
            end
        end
    end
end)

t.test('NEW RULE, THE BOUNDARY: the last life broadcasts, the one before it does not', function()
    local s = newServer(function(config) config.Match.lives = 2 end)
    local match = s.play(4, 'ffa', 'last_standing')
    s.onlookers()
    s.step(2)

    local _, _, first = s.die(3, 2)
    t.equals(match.players[3].lives, 1, 'premise: one life left')
    t.equals(first, 0, 'a death with a life left pushed the room')
    s.step()
    local _, _, second = s.die(3, 2)
    t.equals(match.players[3].lives, 0, 'premise: no lives left')
    t.isTrue(second > 0, 'the death that spent the last life told nobody')
end)

t.test('PIN: A GUN GAME KILL STILL PUSHES: every recipient, and the killer\'s copy carries the new weapon', function()
    for _, win in ipairs({ 'last_standing', 'most_kills' }) do
        local s = newServer()
        local match = s.play(4, 'gungame', win)
        s.onlookers()
        s.step(2)
        local ladder = match.ladder or {}
        t.isTrue(#ladder >= 2, 'premise: a ladder was drawn')

        local ok, by = s.die(3, 2)
        t.isTrue(ok == true, 'the death was refused')
        for _, src in ipairs({ 1, 2, 3, 4, 11, 12, 13 }) do
            t.isTrue((by[src] or 0) >= 1, win .. ': the ladder kill never reached ' .. src)
        end
        local loadout = ((s.last[2] or {}).player or {}).loadout or {}
        local first = (loadout.weapons or {})[1] or {}
        t.equals(first.key, (ladder[2] or {}).key, win .. ': the killer was not sent the promoted weapon')
    end
end)

t.test('PIN: a ladder death that moves no weapon at all still pushes -- the ladder clause is not "a tier moved"', function()
    -- A fall on the first rung: no killer, nothing to demote to. The death
    -- is still a ladder death and still broadcast, as it always was.
    local s = newServer()
    local match = s.play(4, 'gungame', 'last_standing')
    s.onlookers()
    s.step(2)
    t.equals(s.Arena.ToInt(match.players[3].tier) or 1, 1, 'premise: fighter 3 is on the first rung')
    local _, _, total = s.die(3, nil)
    t.isTrue(total > 0, 'a ladder death with no tier to move pushed nothing')
end)

t.test('PIN: A KILL THAT DECIDES THE ROUND CLOSES THE BOOK ON EVERY PANEL AT ONCE (score limit)', function()
    -- THE AMENDMENT. The watchers' book is open for thirty seconds after the
    -- round goes live; betsOpen reads ArenaMatch.IsDecided, so the kill that
    -- reaches the limit shuts it. That has to reach every open panel now,
    -- not a second later when the sweep ends the round -- a bet taken in
    -- that second is a bet on a known result.
    for _, mode in ipairs({ 'ffa', 'tdm' }) do
        local s = newServer()
        local match = s.play(4, mode, 'score_limit', 3)
        s.onlookers()
        s.step(2)
        t.isTrue(s.env.ArenaBetting.BetsAreOpen(match), mode .. ': premise: the watchers\' book is open')

        local killer, victims = 1, { 2, 4, 2 }
        for index, victim in ipairs(victims) do
            local _, by = s.die(victim, killer)
            if index < #victims then
                t.isTrue(not s.match.IsDecided(match), mode .. ': premise: decided too early')
            else
                t.isTrue(s.match.IsDecided(match), mode .. ': premise: the third kill did not decide it')
                for _, src in ipairs({ 1, 2, 3, 4, 11, 12, 13 }) do
                    t.isTrue((by[src] or 0) >= 1, mode .. ': the deciding kill never reached ' .. src)
                    local copy = matchOf(s.last[src] or {}, match.id) or {}
                    t.isTrue(copy.betsOpen == false, mode .. ': ' .. src .. ' still sees the book open')
                    local row = rowOf(s.last[src] or {}, match.id, killer) or {}
                    t.equals(row.kills, 3, mode .. ': ' .. src .. ' was not sent the deciding count')
                end
            end
            s.step()
        end
    end
end)

t.test('NEW RULE: the kills SHORT of the limit are quiet, and only the one that reaches it speaks', function()
    for _, mode in ipairs({ 'ffa', 'tdm' }) do
        local s = newServer()
        local match = s.play(4, mode, 'score_limit', 3)
        s.onlookers()
        s.step(2)
        local pushes = {}
        for _, victim in ipairs({ 2, 4, 2 }) do
            local _, _, total = s.die(victim, 1)
            pushes[#pushes + 1] = total
            s.step()
        end
        t.equals(pushes[1], 0, mode .. ': the first kill short of the limit pushed the room')
        t.equals(pushes[2], 0, mode .. ': the second kill short of the limit pushed the room')
        t.isTrue(pushes[3] > 0, mode .. ': the deciding kill pushed nothing')
        t.isTrue(match.state ~= 'live', mode .. ': the sweep did not end the decided round')
    end
end)

t.test('PIN: a death after the clock has run out, before the sweep ends it, pushes too (every win condition)', function()
    -- WHOEVER IT NAMES, WHATEVER THE WIN CONDITION. The clause is "the round
    -- is decided once the death has landed", not "a kill decided it": a
    -- fall, a claim the roster refuses and a credited kill all land in a
    -- round the clock has already settled, and each is told to the room.
    -- evaluate answers on the clock for last_standing and score_limit too,
    -- so a respawning death there is a deciding one and must shut the book
    -- on every panel -- a gate that asked IsDecided only for most_kills
    -- would leave last_standing panels taking bets on a finished round.
    for _, win in ipairs({ 'most_kills', 'last_standing', 'score_limit' }) do
        for _, killer in ipairs({ 2, false, 99 }) do
            local s = newServer()
            local match = s.play(4, 'ffa', win, win == 'score_limit' and 10 or nil)
            s.onlookers()
            s.step(2)
            t.isTrue(match.endsAt ~= nil, win .. ': premise: the round has a clock')
            t.isTrue(not s.match.IsDecided(match), win .. ': premise: decided before the clock ran out')

            s.at((match.endsAt - START) + 1)
            t.isTrue(s.match.IsDecided(match), win .. ': premise: the clock has decided it')
            local ok, by = s.die(3, killer ~= false and killer or nil)
            t.isTrue(ok == true, win .. ': the death was refused')
            t.isTrue(not s.Arena.IsEliminated(match.players[3]), win .. ': premise: the death was a respawn')
            for _, src in ipairs({ 1, 2, 3, 4, 11, 12, 13 }) do
                t.isTrue((by[src] or 0) >= 1, ('%s: a death by %s in a decided round never reached %d')
                    :format(win, tostring(killer), src))
                local copy = matchOf(s.last[src] or {}, match.id) or {}
                t.isTrue(copy.betsOpen == false, ('%s: %d still sees the book open'):format(win, src))
            end
        end
    end
end)

t.test('PIN: THE NEXT SCHEDULED BROADCAST CARRIES THE COUNTS the quiet deaths moved', function()
    -- goLive schedules one broadcast at the instant the watchers' book
    -- shuts. Three deaths land before it and push nothing; when it goes out
    -- it must carry all three.
    local s = newServer()
    local match = s.play(4, 'ffa', 'most_kills')
    s.onlookers()

    s.die(2, 1)
    s.die(3, 1)
    s.die(4, 2)
    local mark = #s.sent
    s.step()
    local by = s.pushesSince(mark)
    t.isTrue((by[12] or 0) >= 1, 'the scheduled broadcast never went out, so this proves nothing')
    for _, src in ipairs({ 1, 2, 3, 4, 11, 12, 13 }) do
        local copy = s.last[src] or {}
        t.equals((rowOf(copy, match.id, 1) or {}).kills, 2, src .. ' was sent a stale kill count')
        t.equals((rowOf(copy, match.id, 2) or {}).kills, 1, src .. ' was sent a stale kill count')
        t.equals((rowOf(copy, match.id, 4) or {}).deaths, 1, src .. ' was sent a stale death count')
    end
end)

t.test('PIN: and so does the next elimination\'s broadcast', function()
    local s = newServer(function(config) config.Match.lives = 3 end)
    local match = s.play(4, 'ffa', 'last_standing')
    s.onlookers()
    s.step(2)
    s.die(2, 1)
    s.step()
    s.die(2, 1)
    s.step()
    s.die(3, 4)
    s.step()
    local _, by = s.die(2, 1)
    t.isTrue(s.Arena.IsEliminated(match.players[2]), 'premise: the third death eliminated fighter 2')
    for _, src in ipairs({ 1, 3, 4, 11, 12, 13 }) do
        t.isTrue((by[src] or 0) >= 1, 'the elimination never reached ' .. src)
        local copy = s.last[src] or {}
        t.equals((rowOf(copy, match.id, 1) or {}).kills, 3, src .. ' was sent a stale kill count')
        t.equals((rowOf(copy, match.id, 3) or {}).deaths, 1, src .. ' was sent a stale death count')
    end
end)

-- ======================================================================
-- EDGES
-- ======================================================================

t.test('PIN, EDGE: a death OnDeath refuses pushes nothing, as it never did', function()
    local s = newServer()
    local match = s.play(4, 'ffa', 'last_standing')
    s.onlookers()
    s.step(2)
    for _, src in ipairs({ false, 'x', 0, -1, 99, 11 }) do
        local ok, _, total = s.die(src ~= false and src or nil, 2)
        t.isTrue(ok == false, 'a death for ' .. tostring(src) .. ' was accepted')
        t.equals(total, 0, 'a refused death for ' .. tostring(src) .. ' pushed the room')
    end
    match.players[3].alive = false
    local ok, _, total = s.die(3, 2)
    t.isTrue(ok == false, 'a second death for a body already down was accepted')
    t.equals(total, 0, 'a refused second death pushed the room')
end)

t.test('PIN, EDGE: with betting switched off an elimination still tells the room', function()
    local s = newServer(function(config)
        config.Betting.enabled = false
        config.Match.lives = 1
    end)
    local match = s.play(4, 'tdm', 'last_standing')
    s.onlookers()
    s.step(2)
    local _, by = s.die(3, 2)
    t.isTrue(s.Arena.IsEliminated(match.players[3]), 'premise: eliminated')
    for _, src in ipairs({ 1, 2, 3, 4, 11, 12, 13 }) do
        t.isTrue((by[src] or 0) >= 1, 'with betting off the elimination missed ' .. src)
    end
end)

t.test('PIN, EDGE: an empty room -- a round nobody else is watching -- still broadcasts an elimination to its fighters', function()
    local s = newServer(function(config) config.Match.lives = 1 end)
    s.play(3, 'ffa', 'last_standing')
    s.step(2)
    local _, by = s.die(3, 2)
    for _, src in ipairs({ 1, 2, 3 }) do t.isTrue((by[src] or 0) >= 1, 'the elimination missed ' .. src) end
end)

t.test('NEW RULE, EDGE: lives written as 0 in a round that spends none respawns, pushes nothing, and comes back alive', function()
    -- Unreachable from Start, which writes at least one life -- but it is the
    -- one state where the snapshot's `alive` would flicker across a
    -- respawning death, so it is pinned: nobody is told they are out, and
    -- once the respawn lands the snapshot says alive again, which is what
    -- everybody's last copy already said.
    local s = newServer()
    local match = s.play(4, 'ffa', 'most_kills')
    s.onlookers()
    s.step(2)
    match.players[3].lives = 0
    local _, _, total = s.die(3, 2)
    t.equals(total, 0, 'a respawning death pushed the room')
    s.step(2)
    t.isTrue(match.players[3].alive == true, 'the fighter did not respawn')
    local row = rowOf(s.lobby.BuildState(12), match.id, 3) or {}
    t.isTrue(row.alive == true, 'after the respawn the snapshot still reads them out')
end)

-- ======================================================================
-- THE DIFFERENTIAL: THE OLD RULE AGAINST THE REAL OnDeath
-- ======================================================================

t.test('DIFFERENTIAL: hundreds of seeded deaths -- every push the old code made is still made, byte for byte, but the silent ones',
function()
    -- THE OLD RULE WAS "ALWAYS". The new one broadcasts when the victim has
    -- no lives left, when the round plays a ladder, or when the round is
    -- decided once the death has landed. For every death below:
    --
    --   * the pushes happen exactly when that rule says;
    --   * a push that happens is the snapshot BuildState builds -- what the
    --     old broadcast sent;
    --   * at a push that does NOT happen, the snapshot each recipient would
    --     have been sent differs from the last one they actually got only in
    --     a match row's kills and deaths.
    local random = generator(20260925)
    local failures, deaths, silent, loud = {}, 0, 0, 0
    local reasons = { eliminated = 0, ladder = 0, decided = 0 }

    for index, setup in ipairs(SETUPS) do
        for round = 1, 2 do
            local s = newServer(function(config)
                config.Match.lives = 2 + (round % 2)
                config.Match.spectateOnElimination = (index + round) % 2 == 0
            end)
            local match = s.play(6, setup.mode, setup.win, setup.win == 'score_limit' and (8 + round) or nil)
            s.onlookers()
            s.step(2)
            -- EVERYBODY ALREADY BEING SENT STATE, so a silent first death is
            -- checked against every screen and not only the ones a later
            -- broadcast happens to reach.
            local recipients = {}
            for target in pairs(s.last) do recipients[target] = true end

            for _ = 1, 30 do
                if match.state ~= 'live' then break end
                local alive = {}
                for _, src in ipairs(FIGHTERS) do
                    local row = match.players[src]
                    if row and row.alive == true and not s.Arena.IsEliminated(row) then alive[#alive + 1] = src end
                end
                if #alive < 2 then break end
                local victim = alive[random(#alive)]
                local pick = random(8)
                local killer = pick <= #alive and alive[pick] or (pick == 8 and 99 or nil)
                if killer == victim then killer = nil end

                local mark = #s.sent
                deaths = deaths + 1
                s.match.OnDeath(victim, killer)

                local row = match.players[victim]
                local eliminated = row ~= nil and s.Arena.IsEliminated(row)
                local ladder = #(match.ladder or {}) > 0
                local decided = match.state == 'live' and s.match.IsDecided(match)
                local expectLoud = eliminated or ladder or decided
                if eliminated then reasons.eliminated = reasons.eliminated + 1 end
                if ladder then reasons.ladder = reasons.ladder + 1 end
                if decided then reasons.decided = reasons.decided + 1 end

                local by, total = s.pushesSince(mark)
                local label = ('%s/%s round %d: %d killed by %s'):format(setup.mode, setup.win, round,
                    victim, tostring(killer))

                if expectLoud then
                    loud = loud + 1
                    if total == 0 then failures[#failures + 1] = label .. ': the old broadcast was dropped' end
                    for target in pairs(by) do recipients[target] = true end
                    -- WHAT WENT OUT IS WHAT THE OLD BROADCAST SENT: the
                    -- snapshot as it stands.
                    for target in pairs(by) do
                        local now = s.lobby.BuildState(target)
                        local paths = diff(s.last[target], now)
                        if #paths > 0 then
                            failures[#failures + 1] = ('%s: %d was sent a snapshot that is not the current one: %s')
                                :format(label, target, table.concat(paths, ', '))
                        end
                    end
                else
                    silent = silent + 1
                    if total ~= 0 then
                        failures[#failures + 1] = ('%s: %d push(es) for a death that changed nothing anybody reads')
                            :format(label, total)
                    end
                    for target in pairs(recipients) do
                        local paths = diff(s.last[target] or {}, s.lobby.BuildState(target))
                        for _, path in ipairs(paths) do
                            if not unreadField(path) then
                                failures[#failures + 1] = ('%s: %d is now stale in %s, which is read')
                                    :format(label, target, path)
                            end
                        end
                    end
                end
                s.step()
            end
        end
    end

    t.isTrue(deaths >= 300, 'the run was shorter than it claims: ' .. deaths)
    t.isTrue(silent > 50, 'the run produced too few silent deaths to compare')
    t.isTrue(loud > 50, 'the run produced too few broadcast deaths to compare')
    t.isTrue(reasons.eliminated > 0 and reasons.ladder > 0 and reasons.decided > 0,
        ('the run never produced every kind of broadcast: %d eliminated, %d ladder, %d decided')
            :format(reasons.eliminated, reasons.ladder, reasons.decided))
    t.equals(#failures, 0, table.concat(failures, '\n'))
end)

os.exit(t.summary())
