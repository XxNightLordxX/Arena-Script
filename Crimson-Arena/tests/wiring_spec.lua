--[[
    crimson_arena/tests/wiring_spec.lua

    THE FUNNEL, ARGUMENT BY ARGUMENT.

    wireguard_spec proves the rate limiter refuses and the shape guards do
    not throw. fuzzwire_spec proves the handler bodies survive junk. Neither
    asks the positive question: when a WELL-FORMED message arrives, does the
    real handler get entered, and does it hand DOWNSTREAM exactly what the
    funnel (tableArg / keyArg / intArg / boolArg / pickArg / loadoutArg)
    says it should -- coerced where it coerces, dropped where it drops,
    refused where it refuses?

    That is the wire's whole contract, and until this file no test held it
    per entry point. A funnel that quietly passed `entryFee` through raw
    would have failed nothing: every other spec calls ArenaLobby.Create
    directly with numbers already made.

    HOW: server/util.lua and server/main.lua are loaded for real -- the
    limiter live, the clock under this file's control -- and every module
    main.lua hands on to (ArenaLobby, ArenaMatch, ArenaBetting, ArenaAmmo,
    ArenaDispatch, ArenaStats) is a RECORDER: each call is written down with
    its arguments, and answers what the test says. Then each of the 22
    onClient entry points and the one lib.callback is fired through the
    real RegisterNetEvent handler with `source` set, and the recording is
    read back.

    22 net events + 1 callback = 23 -- the number STAGE 3 calls the attack
    surface. outlineReason is here too; it had no test anywhere.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('wiring_spec')

local LONG_KEY = string.rep('k', 65)     -- MAX_KEY_LENGTH is 64
local EDGE_KEY = string.rep('k', 64)

--- A recorder for one downstream module. Any function name works; each
--- call is written to `calls` and answered from `answers[module.fn]`.
local function recorder(module, calls, answers)
    return setmetatable({}, {
        __index = function(_, fn)
            return function(...)
                local args = table.pack(...)
                calls[#calls + 1] = { module = module, fn = fn, args = args }
                local answer = answers[module .. '.' .. fn]
                if type(answer) == 'function' then return answer(...) end
                return answer
            end
        end,
    })
end

local function newFunnel(opts)
    opts = opts or {}
    local players = {}
    for src = 1, 6 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    local qbx = Sandbox.newQbxCore(players)
    local oxlib = Sandbox.newOxLib()

    local calls, answers, netEvents, handlers, sent = {}, {}, {}, {}, {}
    local clock = { now = 0 }

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = oxlib,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return clock.now end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        IsPlayerAceAllowed = function() return opts.admin == true end,
        IsDuplicityVersion = function() return true end,
        PerformHttpRequest = function() end,
        GetResourceState = function() return 'missing' end,
        GetPlayers = function() return {} end,
    })

    -- The recorders go in AFTER the env is built so shared/arena.lua (real)
    -- is untouched and only the server modules main.lua hands on to are
    -- stood in for.
    for _, module in ipairs({ 'ArenaLobby', 'ArenaMatch', 'ArenaBetting',
                              'ArenaAmmo', 'ArenaDispatch', 'ArenaStats' }) do
        env[module] = recorder(module, calls, answers)
    end

    -- Sensible defaults so a handler runs to its end; a test overrides what
    -- it is about.
    answers['ArenaLobby.GetByPlayer'] = nil
    answers['ArenaLobby.BuildState'] = function(src) return { forSrc = src, built = true } end
    answers['ArenaLobby.All'] = function() return {} end
    answers['ArenaAmmo.AllStashes'] = function(cb) cb({}) end
    answers['ArenaAmmo.OwedKit'] = function() return {} end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = {
        env = env, calls = calls, answers = answers, netEvents = netEvents,
        handlers = handlers, sent = sent, clock = clock, qbx = qbx,
    }

    --- Fires one wire event as the network would: `source` set, the clock
    --- advanced a minute so the limiter is out of the picture unless a test
    --- wants it in.
    function server.fire(name, src, data, keepClock)
        if not keepClock then clock.now = clock.now + 60000 end
        env.source = src
        local handler = netEvents['crimson_arena:server:' .. name]
        assert(handler, 'no handler registered for ' .. name)
        handler(data)
    end

    --- The last recorded call to module.fn, or nil.
    function server.last(module, fn)
        for index = #calls, 1, -1 do
            local call = calls[index]
            if call.module == module and call.fn == fn then return call end
        end
        return nil
    end

    function server.count(module, fn)
        local n = 0
        for _, call in ipairs(calls) do
            if call.module == module and (fn == nil or call.fn == fn) then n = n + 1 end
        end
        return n
    end

    --- The last notice sent to `src`, as its description text.
    function server.lastNotice(src)
        for index = #sent, 1, -1 do
            local row = sent[index]
            if row.event == 'crimson_arena:client:notify' and row.target == src then
                return row.payload.description, row.payload.type
            end
        end
        return nil
    end

    function server.lastSent(event, src)
        for index = #sent, 1, -1 do
            local row = sent[index]
            if row.event == event and row.target == src then return row.payload end
        end
        return nil
    end

    return server
end

local function L(key, ...) return Sandbox.locale(key, ...) end

-- ----------------------------------------------------------------------
-- THE CALLBACK
-- ----------------------------------------------------------------------

t.test('getState: entered through the real callback; marks the panel open and answers BuildState', function()
    local s = newFunnel()
    local cb = s.env.lib.callbacks['crimson_arena:server:getState']
    t.isTrue(cb ~= nil, 'callback registered')
    s.clock.now = 60000
    local state = cb(3)
    t.equals(s.last('ArenaLobby', 'MarkPanelOpen').args[1], 3)
    t.equals(s.last('ArenaLobby', 'BuildState').args[1], 3)
    t.equals(state.forSrc, 3)
end)

t.test('getState: a second ask inside RATE.state is answered nil and never entered', function()
    local s = newFunnel()
    local cb = s.env.lib.callbacks['crimson_arena:server:getState']
    s.clock.now = 60000
    cb(3)
    s.clock.now = 60000 + 499
    local again = cb(3)
    t.equals(again, nil)
    t.equals(s.count('ArenaLobby', 'BuildState'), 1)
    s.clock.now = 60000 + 500
    t.equals(cb(3).forSrc, 3, 'at the interval it is answered again')
end)

-- ----------------------------------------------------------------------
-- PANEL PRESENCE AND DIAGNOSTICS
-- ----------------------------------------------------------------------

t.test('panelClosed: MarkPanelClosed(src), nothing else', function()
    local s = newFunnel()
    s.fire('panelClosed', 4, nil)
    t.equals(s.last('ArenaLobby', 'MarkPanelClosed').args[1], 4)
    t.equals(s.count('ArenaLobby'), 1)
end)

t.test('requestState: {panel=true} marks the panel open; the state goes to the asker only', function()
    local s = newFunnel()
    s.fire('requestState', 2, { panel = true })
    t.equals(s.last('ArenaLobby', 'MarkPanelOpen').args[1], 2)
    t.equals(s.lastSent('crimson_arena:client:state', 2).forSrc, 2)

    s.fire('requestState', 5, { panel = 'true' })
    t.equals(s.count('ArenaLobby', 'MarkPanelOpen'), 1, 'a string "true" is not a boolean true')
    t.equals(s.lastSent('crimson_arena:client:state', 5).forSrc, 5, 'the state is still answered')
end)

t.test('outlineReason: a string reason reaches the debug log, cut at 200 characters, only with Config.Debug', function()
    local lines = {}
    local s = newFunnel()
    s.env.print = function(line) lines[#lines + 1] = line end
    s.env.Config.Debug = true
    local long = string.rep('R', 500)
    s.fire('outlineReason', 2, { reason = long })
    t.equals(#lines, 1)
    t.isTrue(lines[1]:find(string.rep('R', 200), 1, true) ~= nil, 'the first 200 are logged')
    t.isTrue(lines[1]:find(string.rep('R', 201), 1, true) == nil, 'and not the 201st')

    s.fire('outlineReason', 2, 'bare string')
    t.equals(#lines, 2, 'a bare string is accepted too')
    s.fire('outlineReason', 2, { reason = 42 })
    s.fire('outlineReason', 2, 42)
    t.equals(#lines, 2, 'a number is not a reason')

    s.env.Config.Debug = false
    s.fire('outlineReason', 2, { reason = 'quiet' })
    t.equals(#lines, 2, 'with Debug off nothing is written')
end)

-- ----------------------------------------------------------------------
-- LOBBY
-- ----------------------------------------------------------------------

t.test('createMatch: every field funnelled -- numeric strings become integers, junk booleans become nil, keys bounded', function()
    local s = newFunnel()
    s.answers['ArenaLobby.Create'] = function() return 'm-1' end
    local plan = { { tier = 1 }, { tier = 2 } }
    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = '500', lives = '3',
        radar = 'yes', account = 'bank', roundTimeSeconds = '120.9',
        winCondition = 'kills', tierPlan = plan, scoreLimit = '10',
    })
    local call = s.last('ArenaLobby', 'Create')
    t.isTrue(call ~= nil, 'Create entered')
    local a = call.args
    t.equals(a[1], 1)
    t.equals(a[2], 'trailerpark')
    t.equals(a[3], 'ffa')
    t.equals(a[4], 500, 'entryFee "500" -> 500')
    t.equals(a[5], 3, 'lives "3" -> 3')
    t.equals(a[6], nil, 'radar "yes" -> nil, not true')
    t.equals(a[7], 'bank')
    t.equals(a[8], 120, 'roundTimeSeconds "120.9" -> 120')
    t.equals(a[9], 'kills')
    t.equals(a[10], plan, 'tierPlan passed as the table it was')
    t.equals(a[11], 10, 'scoreLimit "10" -> 10')
    t.equals(s.lastNotice(1), L('notify.match_created'))
end)

t.test('createMatch: a 65-character arena key never reaches Create; 64 does', function()
    local s = newFunnel()
    s.answers['ArenaLobby.Create'] = function() return 'm-1' end
    s.fire('createMatch', 1, { arenaKey = LONG_KEY })
    t.equals(s.count('ArenaLobby', 'Create'), 0)
    t.equals(s.lastNotice(1), L('error.arena_unavailable'))

    s.fire('createMatch', 1, { arenaKey = EDGE_KEY })
    t.equals(s.count('ArenaLobby', 'Create'), 1)
    t.equals(s.last('ArenaLobby', 'Create').args[2], EDGE_KEY)

    s.fire('createMatch', 1, 'not a table')
    t.equals(s.count('ArenaLobby', 'Create'), 1)
    t.equals(s.lastNotice(1), L('error.invalid_request'))
end)

t.test('createMatch: Create\'s refusal reason is the toast; NaN and infinity become nil, not numbers', function()
    local s = newFunnel()
    s.answers['ArenaLobby.Create'] = function() return nil, 'error.pot_limit_reached' end
    s.fire('createMatch', 2, { arenaKey = 'trailerpark', entryFee = 0 / 0, lives = math.huge })
    local a = s.last('ArenaLobby', 'Create').args
    t.equals(a[4], nil, 'NaN entry fee -> nil')
    t.equals(a[5], nil, 'infinite lives -> nil')
    t.equals(s.lastNotice(2), L('error.pot_limit_reached'))
end)

t.test('joinMatch: matchId, teamKey and account funnelled as keys; a numeric team is dropped', function()
    local s = newFunnel()
    s.answers['ArenaLobby.Join'] = function() return true end
    s.fire('joinMatch', 2, { matchId = 'm-1', teamKey = 123, account = 'cash' })
    local a = s.last('ArenaLobby', 'Join').args
    t.equals(a[1], 2); t.equals(a[2], 'm-1'); t.equals(a[3], nil, 'teamKey 123 -> nil'); t.equals(a[4], 'cash')
    t.equals(s.lastNotice(2), L('notify.match_joined'))

    s.fire('joinMatch', 2, { matchId = '' })
    t.equals(s.count('ArenaLobby', 'Join'), 1, 'an empty id is refused before Join')
    t.equals(s.lastNotice(2), L('error.match_not_found'))
end)

t.test('leaveMatch: ArenaMatch.RemovePlayer first; ArenaLobby.Leave only when the match did not handle it', function()
    local s = newFunnel()
    s.answers['ArenaMatch.RemovePlayer'] = function() return true end
    s.fire('leaveMatch', 3, nil)
    local a = s.last('ArenaMatch', 'RemovePlayer').args
    t.equals(a[1], 3); t.equals(a[2], 'notify.you_left'); t.equals(a[3], nil, 'not a disconnect')
    t.equals(s.count('ArenaLobby', 'Leave'), 0)

    s.answers['ArenaMatch.RemovePlayer'] = function() return false end
    s.answers['ArenaLobby.Leave'] = function() return false, 'error.not_in_match' end
    s.fire('leaveMatch', 3, nil)
    t.equals(s.last('ArenaLobby', 'Leave').args[2], 'notify.you_left')
    t.equals(s.lastNotice(3), L('error.not_in_match'))
end)

t.test('setTeam: the key funnelled; the THROTTLED second click names the side the player is on', function()
    local s = newFunnel()
    local team = s.env.Arena.GetEnabledTeams()[1]
    s.answers['ArenaLobby.SetTeam'] = function() return true end
    s.answers['ArenaLobby.GetByPlayer'] = function() return { players = { [4] = { team = team.key } } } end

    s.fire('setTeam', 4, { teamKey = team.key })
    t.equals(s.last('ArenaLobby', 'SetTeam').args[2], team.key)

    s.fire('setTeam', 4, { teamKey = 'other' }, true)     -- same instant: throttled
    t.equals(s.count('ArenaLobby', 'SetTeam'), 1, 'the second click never reached SetTeam')
    t.equals(s.lastNotice(4), L('notify.team_side', team.label or team.key), 'and the player is told which side they are on')

    s.fire('setTeam', 5, { teamKey = {} })
    t.equals(s.count('ArenaLobby', 'SetTeam'), 1)
    t.equals(s.lastNotice(5), L('error.pick_a_team'))
end)

t.test('setLoadout: the request is REBUILT -- 32 weapons at most, keys only, ammo coerced, armor never passed', function()
    local s = newFunnel()
    s.answers['ArenaLobby.SetLoadout'] = function() return true end
    local weapons = {}
    for index = 1, 40 do
        weapons[index] = { key = 'weapon_' .. index, ammo = tostring(index), ammoType = 'ammo_x', extra = 'junk' }
    end
    weapons[3] = { key = 123, ammo = 9 }        -- a non-key entry is dropped, the list goes on
    s.fire('setLoadout', 2, { weapons = weapons, supplies = { { key = 'bandage', count = '2' } }, armor = 100 })
    local request = s.last('ArenaLobby', 'SetLoadout').args[2]
    t.equals(#request.weapons, 31, '40 sent, 32 read, 1 dropped for a bad key')
    t.equals(request.weapons[1].key, 'weapon_1')
    t.equals(request.weapons[1].ammo, 1, 'ammo "1" -> 1')
    t.equals(request.weapons[1].ammoType, 'ammo_x')
    t.equals(request.weapons[1].extra, nil, 'unknown fields do not travel')
    t.equals(request.armor, nil, 'armor is not a loadout field')
    t.equals(request.supplies[1].key, 'bandage')
    t.equals(request.supplies[1].count, 2)
end)

t.test('setLoadout: a stranger\'s junk gets a refusal and NO state push; a drafter gets their draft back', function()
    local s = newFunnel()
    s.fire('setLoadout', 2, 'junk')
    t.equals(s.count('ArenaLobby', 'PushState'), 0, 'no lobby, no push')
    t.equals(s.lastNotice(2), L('error.invalid_request'))

    s.answers['ArenaLobby.GetByPlayer'] = function() return { id = 'm-1' } end
    s.answers['ArenaLobby.SetLoadout'] = function() return false, 'error.mode_picks_loadout' end
    s.fire('setLoadout', 2, { weapons = {} })
    t.equals(s.last('ArenaLobby', 'PushState').args[1], 2, 'the refused draft is pushed back to the drafter')
    t.equals(s.lastNotice(2), L('error.mode_picks_loadout'))
end)

t.test('setReady: only a real boolean is passed on', function()
    local s = newFunnel()
    s.answers['ArenaLobby.SetReady'] = function() return true end
    s.fire('setReady', 3, { ready = false })
    t.equals(s.last('ArenaLobby', 'SetReady').args[2], false)
    s.fire('setReady', 3, { ready = 'true' })
    s.fire('setReady', 3, { ready = 1 })
    t.equals(s.count('ArenaLobby', 'SetReady'), 1, '"true" and 1 are not booleans')
    t.equals(s.lastNotice(3), L('error.invalid_request'))
end)

t.test('startMatch: Begin(match.id, src) for the player\'s own lobby; refused with not_in_match otherwise', function()
    local s = newFunnel()
    s.fire('startMatch', 1, nil)
    t.equals(s.count('ArenaMatch', 'Begin'), 0)
    t.equals(s.lastNotice(1), L('error.not_in_match'))

    s.answers['ArenaLobby.GetByPlayer'] = function() return { id = 'm-9' } end
    s.answers['ArenaMatch.Begin'] = function() return false, 'error.start_held' end
    s.fire('startMatch', 1, { anything = true })
    local a = s.last('ArenaMatch', 'Begin').args
    t.equals(a[1], 'm-9'); t.equals(a[2], 1)
    t.equals(s.lastNotice(1), L('error.start_held'))
end)

t.test('holdCountdown and cancelMatch: src through, reason back', function()
    local s = newFunnel()
    s.answers['ArenaLobby.HoldCountdown'] = function() return false, 'error.not_host' end
    s.fire('holdCountdown', 2, nil)
    t.equals(s.last('ArenaLobby', 'HoldCountdown').args[1], 2)
    t.equals(s.lastNotice(2), L('error.not_host'))

    s.answers['ArenaLobby.Cancel'] = function() return true end
    s.fire('cancelMatch', 2, nil)
    t.equals(s.last('ArenaLobby', 'Cancel').args[1], 2)
end)

t.test('updateMatch: the eight rule fields funnelled into a fresh table; a refusal re-seeds the host\'s form', function()
    local s = newFunnel()
    s.answers['ArenaLobby.UpdateMatch'] = function() return true end
    local plan = { 'a' }
    local sent = {
        arenaKey = 'sky', modeKey = 7, lives = '2', radar = true, roundTimeSeconds = 'x',
        winCondition = 'score', scoreLimit = '15', tierPlan = plan, evil = 'field',
    }
    s.fire('updateMatch', 1, sent)
    local rules = s.last('ArenaLobby', 'UpdateMatch').args[2]
    t.isTrue(rules ~= sent, 'a NEW table, not the sender\'s')
    t.equals(rules.arenaKey, 'sky'); t.equals(rules.modeKey, nil, 'modeKey 7 -> nil')
    t.equals(rules.lives, 2); t.equals(rules.radar, true); t.equals(rules.roundTimeSeconds, nil)
    t.equals(rules.winCondition, 'score'); t.equals(rules.scoreLimit, 15); t.equals(rules.tierPlan, plan)
    t.equals(rules.evil, nil)

    s.fire('updateMatch', 1, 'junk')
    t.equals(s.count('ArenaLobby', 'UpdateMatch'), 1)
    t.equals(s.lastNotice(1), L('error.invalid_request'))

    s.answers['ArenaLobby.UpdateMatch'] = function() return false, 'error.rules_locked_by_stakes' end
    s.fire('updateMatch', 1, {})
    t.equals(s.count('ArenaLobby', 'PushState'), 0, 'nobody in a lobby: no push')
    s.answers['ArenaLobby.GetByPlayer'] = function() return { id = 'm-1' } end
    s.fire('updateMatch', 1, {})
    t.equals(s.last('ArenaLobby', 'NoteEditRefused').args[1], 1)
    t.equals(s.last('ArenaLobby', 'PushState').args[1], 1)
    t.equals(s.lastNotice(1), L('error.rules_locked_by_stakes'))
end)

-- ----------------------------------------------------------------------
-- THE ROUND
-- ----------------------------------------------------------------------

t.test('reportDeath: killer and why are integers or nothing; the middle argument is always nil', function()
    local s = newFunnel()
    s.fire('reportDeath', 5, { killerServerId = '7', why = '2' })
    local a = s.last('ArenaMatch', 'OnDeath').args
    t.equals(a[1], 5); t.equals(a[2], 7); t.equals(a[3], nil); t.equals(a[4], 2)
    t.equals(a.n, 4)

    s.fire('reportDeath', 5, { killerServerId = {}, why = 'console injection' })
    a = s.last('ArenaMatch', 'OnDeath').args
    t.equals(a[2], nil); t.equals(a[4], nil, 'a string why never travels')

    s.fire('reportDeath', 5, 'junk')
    t.equals(s.count('ArenaMatch', 'OnDeath'), 2, 'junk is dropped without a toast')
    t.equals(s.lastNotice(5), nil)
end)

t.test('spectateMatch / stopSpectating: AddSpectator(src, matchId) and RemoveSpectator(src)', function()
    local s = newFunnel()
    s.answers['ArenaLobby.AddSpectator'] = function() return false, 'error.match_not_found' end
    s.fire('spectateMatch', 6, { matchId = 'm-2' })
    local a = s.last('ArenaLobby', 'AddSpectator').args
    t.equals(a[1], 6); t.equals(a[2], 'm-2')
    t.equals(s.lastNotice(6), L('error.match_not_found'))

    s.fire('spectateMatch', 6, { matchId = LONG_KEY })
    t.equals(s.count('ArenaLobby', 'AddSpectator'), 1)

    s.fire('stopSpectating', 6, nil)
    t.equals(s.last('ArenaLobby', 'RemoveSpectator').args[1], 6)
end)

t.test('placeSpectatorBet: pick is an integer first and a key second; amount is an integer; a table pick is refused', function()
    local s = newFunnel()
    s.answers['ArenaBetting.PlaceSpectatorBet'] = function() return true end
    s.fire('placeSpectatorBet', 6, { matchId = 'm-1', pick = '2', amount = '750', account = 'cash' })
    local a = s.last('ArenaBetting', 'PlaceSpectatorBet').args
    t.equals(a[1], 6); t.equals(a[2], 'm-1'); t.equals(a[3], 2, 'pick "2" -> 2'); t.equals(a[4], 750); t.equals(a[5], 'cash')

    s.fire('placeSpectatorBet', 6, { matchId = 'm-1', pick = 'red', amount = 750.9 })
    a = s.last('ArenaBetting', 'PlaceSpectatorBet').args
    t.equals(a[3], 'red'); t.equals(a[4], 750, 'a fractional amount is floored')

    s.fire('placeSpectatorBet', 6, { matchId = 'm-1', pick = {}, amount = 750 })
    t.equals(s.count('ArenaBetting', 'PlaceSpectatorBet'), 2)
    t.equals(s.lastNotice(6), L('error.bet_invalid_pick'))
end)

-- ----------------------------------------------------------------------
-- THE ADMIN TABLET
-- ----------------------------------------------------------------------

local ADMIN_EVENTS = { 'adminState', 'adminStop', 'adminReturn', 'adminHours', 'adminRevive' }

t.test('every admin event: a non-admin is refused before any module is touched', function()
    local s = newFunnel({ admin = false })
    for _, name in ipairs(ADMIN_EVENTS) do
        s.fire(name, 2, { matchId = 'm-1', target = 3, citizenid = 'CID003', stash = 's', forced = 'open' })
        t.equals(s.lastNotice(2), L('error.no_permission'), name)
    end
    t.equals(#s.calls, 0, 'no downstream call at all')
end)

t.test('adminState: the tablet snapshot goes to the admin; matchId funnelled as a key', function()
    local s = newFunnel({ admin = true })
    s.answers['ArenaLobby.Get'] = function(id) return { id = id, players = {} } end
    s.answers['ArenaLobby.PlayerArray'] = function() return {} end
    s.answers['ArenaBetting.GetPot'] = function() return 0 end
    s.fire('adminState', 1, { matchId = 'm-3' })
    t.equals(s.last('ArenaLobby', 'Get').args[1], 'm-3')
    t.isTrue(s.lastSent('crimson_arena:client:adminState', 1) ~= nil, 'snapshot sent')

    s.fire('adminState', 1, { matchId = LONG_KEY })
    t.equals(s.count('ArenaLobby', 'Get'), 1, 'an over-long id is not looked up')
    t.isTrue(s.lastSent('crimson_arena:client:adminState', 1) ~= nil, 'but the tablet still gets its list')
end)

t.test('adminStop: Abort(matchId, notify.match_stopped_by_admin) only for a match that exists', function()
    local s = newFunnel({ admin = true })
    s.answers['ArenaLobby.Get'] = function(id) if id == 'm-1' then return { id = id, players = {} } end end
    s.answers['ArenaLobby.PlayerArray'] = function() return {} end
    s.answers['ArenaBetting.GetPot'] = function() return 0 end
    s.fire('adminStop', 1, { matchId = 'm-404' })
    t.equals(s.count('ArenaMatch', 'Abort'), 0)
    t.equals(s.lastNotice(1), L('error.match_not_found'))

    s.fire('adminStop', 1, { matchId = 'm-1' })
    local a = s.last('ArenaMatch', 'Abort').args
    t.equals(a[1], 'm-1'); t.equals(a[2], 'notify.match_stopped_by_admin')
end)

t.test('adminReturn: target as an integer goes to ReturnLeftovers; citizenid + stash go to QueueReturn', function()
    local s = newFunnel({ admin = true })
    s.answers['ArenaAmmo.ReturnLeftovers'] = function() return true, 2 end
    s.fire('adminReturn', 1, { target = '3' })
    t.equals(s.last('ArenaAmmo', 'ReturnLeftovers').args[1], 3, 'target "3" -> 3')
    t.equals(s.count('ArenaAmmo', 'QueueReturn'), 0)

    s.answers['ArenaAmmo.QueueReturn'] = function() return true end
    s.fire('adminReturn', 1, { citizenid = 'CID009', stash = 'arena_CID009' })
    local a = s.last('ArenaAmmo', 'QueueReturn').args
    t.equals(a[1], 'CID009'); t.equals(a[2], 'arena_CID009')
    t.equals(s.lastNotice(1), L('notify.return_queued', 'CID009'))

    s.fire('adminReturn', 1, { target = 0, citizenid = 5 })
    t.equals(s.count('ArenaAmmo', 'ReturnLeftovers'), 1)
    t.equals(s.count('ArenaAmmo', 'QueueReturn'), 1)
    t.equals(s.lastNotice(1), L('error.invalid_request'))
end)

t.test('adminHours: forced is funnelled to ArenaSetHoursOverride; a shut door closes waiting lobbies', function()
    local s = newFunnel({ admin = true })
    s.answers['ArenaMatch.CloseWaitingLobbies'] = function() return 1 end
    s.fire('adminHours', 1, { forced = 'shut' })
    t.equals(s.env.ArenaHoursOverride(), 'shut')
    t.equals(s.last('ArenaMatch', 'CloseWaitingLobbies').args[1], 'notify.hours_lobby_closed')
    t.equals(s.count('ArenaLobby', 'Broadcast'), 1)

    s.fire('adminHours', 1, { forced = 42 })
    t.equals(s.env.ArenaHoursOverride(), nil, 'a non-key clears the override')
    t.equals(s.count('ArenaMatch', 'CloseWaitingLobbies'), 1, 'open again: nothing closed')
end)

t.test('adminRevive: target as an integer; zero and junk refused; a stranger is not_in_match', function()
    local s = newFunnel({ admin = true })
    s.fire('adminRevive', 1, { target = 0 })
    s.fire('adminRevive', 1, { target = 'three' })
    s.fire('adminRevive', 1, 'junk')
    t.equals(s.count('ArenaLobby', 'GetByPlayer'), 0)
    t.equals(s.lastNotice(1), L('error.invalid_request'))

    s.fire('adminRevive', 1, { target = '3' })
    t.equals(s.last('ArenaLobby', 'GetByPlayer').args[1], 3)
    t.equals(s.lastNotice(1), L('error.not_in_match'))

    local row = { alive = false, lives = 2 }
    s.answers['ArenaLobby.GetByPlayer'] = function() return { id = 'm-1', state = 'countdown', players = { [3] = row } } end
    s.answers['ArenaLobby.Get'] = function() return { id = 'm-1', players = {} } end
    s.answers['ArenaLobby.PlayerArray'] = function() return {} end
    s.answers['ArenaBetting.GetPot'] = function() return 0 end
    s.fire('adminRevive', 1, { target = 3 })
    t.equals(s.last('ArenaDispatch', 'Revive').args[1], 3)
    t.equals(row.alive, true)
end)

-- ----------------------------------------------------------------------
-- THE WHOLE SURFACE, COUNTED
-- ----------------------------------------------------------------------

t.test('exactly the 22 wire events STAGE 3 counts are registered, plus the one callback', function()
    local s = newFunnel()
    local names = {}
    for name in pairs(s.netEvents) do
        if name:find('^crimson_arena:server:') then names[#names + 1] = name end
    end
    table.sort(names)
    t.equals(#names, 22, table.concat(names, ' '))
    t.isTrue(s.env.lib.callbacks['crimson_arena:server:getState'] ~= nil)
    for _, name in ipairs({ 'panelClosed', 'requestState', 'outlineReason', 'createMatch', 'joinMatch',
                            'leaveMatch', 'setTeam', 'setLoadout', 'setReady', 'startMatch', 'holdCountdown',
                            'cancelMatch', 'updateMatch', 'reportDeath', 'spectateMatch', 'stopSpectating',
                            'placeSpectatorBet', 'adminState', 'adminStop', 'adminReturn', 'adminHours',
                            'adminRevive' }) do
        t.isTrue(s.netEvents['crimson_arena:server:' .. name] ~= nil, name)
    end
end)

os.exit(t.summary())
