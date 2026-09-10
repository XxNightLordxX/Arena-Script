--[[
    crimson_arena/tests/teamswitch_spec.lua

    A TEAM SWITCH IN THE LOBBY, DRIVEN ALL THE WAY THROUGH TO A BULLET.

    Reported from the live server, twice, in the owner's words:

        "in the menu on team deathmatch i clicked a team, had another member
         join my team, they switched teams, and in the match they could not
         kill each other"

    No spec in this suite covered it, and the gap is exact:

      * crossfire_spec STUBS ArenaLobby and installs hand-built roster rows,
        so it never exercises how a team gets from the panel into
        match.players at all.
      * lobbyrules_spec loads lobby.lua and match.lua but NOT dispatch.lua,
        so it never fires a shot.

    So this file loads BOTH halves into one sandbox -- the real config.lua,
    shared/arena.lua, server/util.lua, server/dispatch.lua, server/betting.lua,
    server/lobby.lua, server/match.lua and server/main.lua -- and plays the
    sequence a player plays: join, pick a side, switch sides, start, shoot.

    NOTHING GOES IN THROUGH A FUNCTION CALL WHERE A PLAYER WOULD USE THE
    WIRE, the same rule lobbyrules_spec states: every choice below is fired
    as the net event server/main.lua registers, with `source` set the way
    FiveM sets it. A rule wired into the lobby but unreachable from the
    panel fails here.

    AND THE SHOT IS THE ENGINE'S OWN PACKET. weaponDamageEvent, with
    hitGlobalIds naming the victim's network id, exactly as crossfire_spec
    fires it -- because that handler is the only place in this resource a
    bullet can be stopped.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teamswitch_spec')

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

local function roster(wallets)
    local players = {}
    for id, cash in pairs(wallets) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = cash, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    return players
end

--- One whole arena server, with the REAL server/dispatch.lua in it.
---
--- lobbyrules_spec stubs ArenaDispatch because its questions are about money
--- and permission. Here the dispatch file IS half the subject: `active`, the
--- routing buckets and weaponDamageEvent all live in it, and a stub would
--- put the very thing under test out of reach.
--- @param wallets table<integer, integer>
--- @param mutate fun(config: table)?
--- @return table server
local function newArena(wallets, mutate)
    local qbx = Sandbox.newQbxCore(roster(wallets))
    local oxlib = Sandbox.newOxLib()
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents, handlers, commands = {}, {}, {}, {}, {}
    local clock = 0

    -- WHO IS ON THE SERVER, and their network ids. dispatch.lua resolves a
    -- damage packet's hitGlobalIds back to a server id by walking every
    -- player and asking the engine for the net id of their ped, so both
    -- natives have to agree with each other or no victim is ever found and
    -- every shot is allowed by default -- which would make this whole file
    -- pass while proving nothing.
    local present = {}
    for id in pairs(wallets) do present[id] = true end

    local buckets = {}

    -- CALLABLE AS WELL AS INDEXABLE. lobbyrules_spec only ever INDEXES this
    -- (`exports.qbx_core:GetPlayer`), but server/dispatch.lua also PUBLISHES
    -- three of its own -- `exports('IsPlayerInArena', ...)` -- at load time,
    -- which is a call on the same global.
    local exportsTable = setmetatable(qbx.exports, {
        __call = function(_, _name, _fn) end,
    })

    local env = Sandbox.newArenaEnv({
        exports = exportsTable,
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
        -- A LIST PER NAME, not one function. Two server files register
        -- 'playerDropped', and weaponDamageEvent is fired by name below --
        -- a single-slot table would silently drop one of them.
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,

        -- Well past every RATE bucket in main.lua on every call. THE ONE
        -- EXCEPTION IS DELIBERATE AND LIVES IN ITS OWN TEST BELOW: a switch
        -- that arrives inside 250ms of the pick before it is a different
        -- question, and it is asked there rather than accidentally here.
        GetGameTimer = function() clock = clock + 60000; return clock end,

        GetPlayerName = function(src)
            local record = qbx.players[src]
            if not record or not present[src] then return '' end
            return record.name
        end,
        GetPlayers = function()
            local out = {}
            for src in pairs(present) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        NetworkGetNetworkIdFromEntity = function(ped)
            local src = (tonumber(ped) or 0) - 1000
            return present[src] and (5000 + src) or 0
        end,
        GetEntityCoords = function(ped)
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,

        -- Routing buckets that really hold a value, because dispatch.lua
        -- reads its own write back and declares isolation dead if the two
        -- disagree. A stub that always answered 0 would print the
        -- ISOLATION IS NOT IN FORCE banner on the first fighter placed.
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) buckets[tonumber(src)] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        Player = function() return { state = { set = function() end } } end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
            Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Refresh = function() return true end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
    })

    -- CancelEvent has to write into a place this fixture can read, and a
    -- closure inside the overrides table above cannot see a local declared
    -- after it, so it is bound here instead of leaning on a global.
    local cancelled = false
    env.CancelEvent = function() cancelled = true end

    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env,
        qbx = qbx,
        config = env.Config,
        lobby = env.ArenaLobby,
        match = env.ArenaMatch,
        dispatch = env.ArenaDispatch,
    }

    --- One client -> server event, as the panel sends it.
    function server.fire(event, src, data)
        local name = 'crimson_arena:server:' .. event
        local handler = netEvents[name]
        if not handler then error('no handler registered for ' .. name, 2) end
        env.source = src
        handler(data)
    end

    --- A player losing their connection, through every handler that wants it.
    function server.drop(src)
        env.source = src
        for _, fn in ipairs(handlers['playerDropped'] or {}) do fn() end
        present[src] = nil
    end

    function server.step()
        threads.step()
        threads.step()
    end

    --- Fires the engine's damage packet from `attacker` at `victims`.
    --- @return boolean cancelled -- true when the server refused the shot
    function server.shoot(attacker, victims)
        cancelled = false
        local hits = {}
        for _, victim in ipairs(victims) do
            hits[#hits + 1] = 5000 + victim
        end
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do
            fn(tostring(attacker), { hitGlobalIds = hits })
        end
        return cancelled
    end

    --- What one player was told, in order -- toasts only.
    function server.told(id)
        local said = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == id then
                said[#said + 1] = message.payload.description
            end
        end
        return table.concat(said, '\n')
    end

    --- The teamKey the SERVER told this client to fight under, from the
    --- enterArena payload -- which is the value client/match.lua caches and
    --- hands to SetPlayerTeam.
    function server.toldTeam(id)
        local team = nil
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:enterArena' and message.target == id then
                team = message.payload.teamKey
            end
        end
        return team
    end

    --- What the panel last showed this player as their own side.
    function server.panelTeam(id)
        return server.lobby.BuildState(id).player.team
    end

    --- What the panel last showed everybody about one player's side.
    function server.rosterTeam(matchId, id)
        for _, match in ipairs(server.lobby.BuildState(id).matches) do
            if match.id == matchId then
                for _, row in ipairs(match.players) do
                    if row.id == id then return row.team end
                end
            end
        end
        return nil
    end

    function server.log() return table.concat(console, '\n') end

    return server
end

--- Opens a team-deathmatch lobby at the trailer park with `ids[1]` hosting,
--- everybody after that joining. Nobody has picked a side yet.
--- @return string matchId
local function openTdm(server, ids)
    server.fire('createMatch', ids[1], {
        arenaKey = 'trailerpark', modeKey = 'tdm', entryFee = 0,
    })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a team deathmatch lobby')

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
        t.isNotNil(match.players[ids[index]], ('player %d could not join'):format(ids[index]))
    end

    return match.id
end

--- Starts the match and runs the countdown out, so the fighters are placed
--- and `active` is raised on all of them.
local function startAndPlace(server, matchId, host)
    local ok, reason = server.match.Begin(matchId, host)
    t.isTrue(ok, ('the match would not start: %s'):format(tostring(reason)))
    for _ = 1, 40 do server.step() end
end

-- ======================================================================
-- WHAT THESE TESTS ASSUME
-- ======================================================================

t.test('the shipped config is the one the numbers below assume', function()
    local config = newArena({}).config
    t.equals(config.Modes.tdm.teams, true, 'tdm is the team mode this file drives')
    t.equals(config.Teams.friendlyFire, false, 'friendly fire ships OFF, which is what makes a stale side fatal')
    t.equals(config.Teams.allowChoose, true, 'players pick their own side out of the box')
    t.equals(config.Teams.autoAssignIfUnchosen, true)
    t.equals(config.Teams.maxTeamSize, 0, 'no cap ships, so a switch is refused for no reason by default')
    t.equals(config.Match.crossfireGuard.enabled, true, 'the damage guard ships on')
end)

-- ======================================================================
-- THE OWNER'S SEQUENCE, EXACTLY
-- ======================================================================

t.test('B switches sides in the lobby and the two can then shoot each other', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    -- 1 picks crimson. 2 joins them on crimson. 2 then thinks better of it
    -- and moves to ash, with the match still sitting in the lobby.
    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'ash' })

    local match = server.lobby.Get(matchId)
    t.equals(match.players[1].team, 'crimson', 'the host stayed where they were')
    t.equals(match.players[2].team, 'ash', 'the switch never reached the roster')

    startAndPlace(server, matchId, 1)
    t.equals(server.lobby.Get(matchId).state, 'live', 'the round never went live')

    t.equals(server.toldTeam(1), 'crimson', 'client 1 was told the wrong side')
    t.equals(server.toldTeam(2), 'ash', 'client 2 was told the side it left, not the one it chose')

    t.isFalse(server.shoot(1, { 2 }), 'the server refused a shot across the line')
    t.isFalse(server.shoot(2, { 1 }), 'the server refused the shot back')
end)

t.test('both of them switch, ending on opposite sides', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setTeam', 1, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    startAndPlace(server, matchId, 1)

    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('B switches twice and ends where they started -- the shot is still refused', function()
    -- THREE, because a team round cannot start with everybody on one side:
    -- Arena.TeamsAreStartable refuses it as error.need_two_teams, so a
    -- two-player version of this test would never reach a bullet at all.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setTeam', 3, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    local match = server.lobby.Get(matchId)
    t.equals(match.players[2].team, 'crimson')

    startAndPlace(server, matchId, 1)

    -- Same side, friendly fire off: BOTH shots must die. This is the
    -- control -- if it passed, the guard would be doing nothing at all.
    t.isTrue(server.shoot(1, { 2 }), 'two players on one side must not be able to shoot each other')
    t.isTrue(server.shoot(2, { 1 }))
    t.isFalse(server.shoot(2, { 3 }), 'and the line they did NOT cross is still open')
end)

t.test('B switches after picking a loadout', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setLoadout', 2, { weapons = { { key = 'pistol' } } })
    server.fire('setTeam', 2, { teamKey = 'ash' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'ash')

    startAndPlace(server, matchId, 1)

    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('B switches, leaves and rejoins', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.fire('leaveMatch', 2)
    server.fire('joinMatch', 2, { matchId = matchId })
    server.fire('setTeam', 2, { teamKey = 'ash' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'ash', 'the rejoin lost the side they picked')

    startAndPlace(server, matchId, 1)

    t.isFalse(server.shoot(1, { 2 }))
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('three players, two ending on one side -- the shape of the reported round', function()
    -- His server log for the round reads:
    --   teams: match mfa9f6 starts ash 1 v crimson 2 (0 assigned, 3 chose their own)
    -- so: everybody picked, nobody was auto-assigned, and it began 1 v 2.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    server.fire('setTeam', 3, { teamKey = 'crimson' })
    server.fire('setTeam', 3, { teamKey = 'ash' })

    startAndPlace(server, matchId, 1)

    t.contains(server.log(), 'ash 1 v crimson 2', 'the round did not start in the shape his log records')

    -- 1 and 2 are the pair on one side: neither may shoot the other.
    t.isTrue(server.shoot(1, { 2 }))
    t.isTrue(server.shoot(2, { 1 }))

    -- 3 is alone on the other side, and everything across the line must fire.
    t.isFalse(server.shoot(3, { 1 }))
    t.isFalse(server.shoot(1, { 3 }))
    t.isFalse(server.shoot(3, { 2 }))
    t.isFalse(server.shoot(2, { 3 }))
end)

-- ======================================================================
-- THE SWITCH THE SERVER NEVER TOOK
-- ======================================================================

t.test('a switch refused while the countdown runs leaves the panel showing the truth', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    local began, why = server.match.Begin(matchId, 1)
    t.isTrue(began, ('the countdown would not start: %s'):format(tostring(why)))
    t.equals(server.lobby.Get(matchId).state, 'countdown')

    server.fire('setTeam', 2, { teamKey = 'ash' })

    -- The lobby is closed to team changes once the countdown starts, and
    -- that is a decision this file does not argue with. What it insists on
    -- is that the player is TOLD, and that the panel goes on showing the
    -- side the server will actually fight them under.
    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson',
        'a countdown switch must not half-apply')
    t.isTrue(#server.told(2) > 0,
        'the player was moved nowhere and told nothing')
    t.equals(server.panelTeam(2), 'crimson',
        'the panel disagrees with the roster the bullet is judged against')
end)

t.test('the countdown is held, the switch is taken, and the round starts on the new sides', function()
    local server = newArena({ [1] = 5000, [2] = 5000 })
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    t.isTrue((server.match.Begin(matchId, 1)))

    server.fire('holdCountdown', 1)
    t.equals(server.lobby.Get(matchId).state, 'lobby', 'the host could not stop the countdown')

    -- 2 moves onto 1's side, then thinks better of it and goes back.
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.fire('setTeam', 2, { teamKey = 'crimson' })
    t.equals(server.lobby.Get(matchId).players[2].team, 'crimson')

    startAndPlace(server, matchId, 1)
    t.isFalse(server.shoot(1, { 2 }), 'the shot across the line was refused after a held countdown')
    t.isFalse(server.shoot(2, { 1 }))
end)

t.test('a player who leaves and whose server id is reused does not inherit the old side', function()
    -- The recycled-id case: 2 walks out on ash, and the next person to
    -- connect is handed server id 2. Nothing about the departed player's
    -- side may follow the id.
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'ash' })
    server.fire('setTeam', 3, { teamKey = 'ash' })

    server.fire('leaveMatch', 2)
    t.isNil(server.lobby.Get(matchId).players[2], 'the row outlived the player')

    server.fire('joinMatch', 2, { matchId = matchId })
    t.equals(server.lobby.Get(matchId).players[2].team, nil,
        'the recycled id walked back in already on a side')

    server.fire('setTeam', 2, { teamKey = 'crimson' })

    startAndPlace(server, matchId, 1)
    t.isTrue(server.shoot(1, { 2 }), '1 and 2 are both crimson now')
    t.isFalse(server.shoot(1, { 3 }))
    t.isFalse(server.shoot(2, { 3 }))
end)

t.test('a switch refused for capacity is refused OUT LOUD, and the panel still agrees with the server', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Teams.maxTeamSize = 1
    end)
    local matchId = openTdm(server, { 1, 2 })

    server.fire('setTeam', 1, { teamKey = 'crimson' })
    server.fire('setTeam', 2, { teamKey = 'ash' })

    -- 2 tries to join 1 on crimson. There is no room.
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    t.equals(server.lobby.Get(matchId).players[2].team, 'ash', 'the cap was not enforced')
    t.equals(server.panelTeam(2), 'ash', 'the panel and the server disagree about 2\'s side')
    t.equals(server.rosterTeam(matchId, 2), 'ash')
    t.isTrue(#server.told(2) > 0, 'a refused switch said nothing at all')

    startAndPlace(server, matchId, 1)
    t.isFalse(server.shoot(1, { 2 }), 'they are on opposite sides and the shot must land')
end)

t.test('a switch refused because choosing is off says so, and does not move anybody', function()
    local server = newArena({ [1] = 5000, [2] = 5000 }, function(config)
        config.Teams.allowChoose = false
    end)
    local matchId = openTdm(server, { 1, 2 })

    -- With allowChoose off, resolveTeam assigns at JOIN. Both are already on
    -- a side they did not pick.
    local match = server.lobby.Get(matchId)
    t.isNotNil(match.players[1].team)
    t.isNotNil(match.players[2].team)

    local before = match.players[2].team
    server.fire('setTeam', 2, { teamKey = 'crimson' })

    t.equals(match.players[2].team, before, 'a refused switch moved somebody anyway')
    t.isTrue(#server.told(2) > 0, 'the player was refused in silence')
end)

-- ======================================================================
-- WHAT THE PANEL SHOWS
-- ======================================================================

t.test('the panel and the roster never disagree about a player\'s own side', function()
    local server = newArena({ [1] = 5000, [2] = 5000, [3] = 5000 })
    local matchId = openTdm(server, { 1, 2, 3 })

    local picks = {
        { 1, 'crimson' }, { 2, 'crimson' }, { 3, 'ash' },
        { 2, 'ash' }, { 1, 'ash' }, { 3, 'crimson' }, { 2, 'crimson' },
    }
    for _, pick in ipairs(picks) do
        server.fire('setTeam', pick[1], { teamKey = pick[2] })
        local live = server.lobby.Get(matchId).players[pick[1]].team
        t.equals(server.panelTeam(pick[1]), live,
            ('the panel showed %s a different side from the one the server holds'):format(pick[1]))
        t.equals(server.rosterTeam(matchId, pick[1]), live,
            'the lobby list disagreed with the roster')
    end
end)

os.exit(t.summary())
