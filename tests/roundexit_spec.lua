-- Crimson Arena: what the server leaves behind when a round is over.

--[[
    tests/roundexit_spec.lua

    THE OWNER'S ASK: "after a match ends, every player must be back to
    normal -- nothing the arena changed may be left behind." The audit of
    every exit found these on the SERVER side, each exercised here against the
    real util, betting, lobby, match and main:

      A WATCH FROM THE FLOOR.  A player downed in the city could press Watch;
                  the down-state hold then kept their flags false all round
                  and the end of it revived them. AddSpectator now asks what
                  Join asks.

      A REVIVE NOBODY NEEDED.  Every pure onlooker was sent the medical
                  script's revive at End and Abort -- which, on a player who
                  is up, rewrites health and strips armour. Now only a
                  watcher who is down gets it.

      THE SWEEP THAT REACHED TOO FAR.  End's delayed revive sweep stood up a
                  fighter eliminated and sent home MINUTES earlier, wherever
                  they had gone down since. Now only the fighters End itself
                  sent home are swept.

      AN ABORT OF A LOBBY.  Stop, Wipe and a restart sent every lobby member
                  through the exit -- revive and all -- although nobody had
                  been placed anywhere. Now only a placed fighter is.

      A WATCHER NOBODY TOLD.  A fighter sent home who came back to watch
                  their own round was never sent an exit when it ended.

      A CHANNEL LOCKED TO NOBODY.  A team round's pma-voice channel checks
                  refused every player on the server after the round.

      THE CHANNEL THEY WERE ON.  The exit hands a player's own radio channel
                  back, and the server has to read it before the door's
                  stash takes their radio and the radio script drops it.

    Harness borrowed from hudsenthome_spec, with ArenaDispatch recording who
    it revives and who carries the arena flag, the framework's metadata, the
    medical state bag and the server's reading of a body's health all
    settable per player, and pma-voice's addChannelCheck kept so a channel
    can be asked who it lets in.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('roundexit_spec')

local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }
local NOW = 1700000000
local BAG = 'qbx_medical:deathState'

--- Server ids 1..8 are fighters; 11..13 are onlookers who never join.
local FIGHTERS = { 1, 2, 3, 4, 5, 6, 7, 8 }
local ONLOOKERS = { 11, 12, 13 }

--- @param opts table? -- { mutate = fn(config) }
local function newServer(opts)
    opts = opts or {}
    local players = {}
    for _, src in ipairs(FIGHTERS) do
        players[src] = { citizenid = ('CID%03d'):format(src), name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 } }
    end
    for _, src in ipairs(ONLOOKERS) do
        players[src] = { citizenid = ('CID%03d'):format(src), name = ('Onlooker %d'):format(src),
            money = { cash = 100000, bank = 100000 } }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, handlers, sent = {}, {}, {}
    local clock = 1000

    local metadata = {}   -- [src] = the framework's metadata for them
    local bags = {}       -- [src] = { [key] = value } -- Player(src).state
    local health = {}     -- [src] = what the server reads off their body; 200 if unset
    local checks = {}     -- [channel] = the check pma-voice holds now
    local dispatch = { revived = {}, flag = {} }

    local exportsTable = {
        qbx_core = {
            GetPlayer = function(self, id)
                local player = qbx.exports.qbx_core.GetPlayer(self, id)
                if player then player.PlayerData.metadata = metadata[id] or {} end
                return player
            end,
        },
        ['pma-voice'] = {
            addChannelCheck = function(_self, channel, fn) checks[channel] = fn end,
        },
    }

    local env = Sandbox.newArenaEnv({
        exports = exportsTable,
        lib = Sandbox.newOxLib(),
        os = setmetatable({ time = function() return NOW end }, { __index = os }),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name) return name == 'pma-voice' and 'started' or 'missing' end,
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[tonumber(src)] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = CENTRE.x + ((tonumber(ped) or 0) % 16) * 2.0, y = CENTRE.y, z = CENTRE.z }
        end,
        GetEntityHealth = function(ped) return health[ped] or 200 end,
        Player = function(src)
            bags[src] = bags[src] or {}
            return { state = bags[src] }
        end,
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
            PayKillAmmo = function() return true end,
        },
        -- THE FLAG IS MODELLED, NOT ANSWERED FALSE: who carries it is half of
        -- what Abort now asks about a roster.
        ArenaDispatch = {
            Set = function(src, matchId) dispatch.flag[src] = matchId end,
            Clear = function(src) dispatch.flag[src] = nil end,
            Revive = function(src) dispatch.revived[#dispatch.revived + 1] = src end,
            IsPlayerInArena = function(src) return dispatch.flag[tonumber(src)] ~= nil end,
            GetPlayerMatchId = function(src) return dispatch.flag[tonumber(src)] end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 1
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = false
    -- Everybody stands at the Trailer Park here, so the second arena's round
    -- in the radio test would read as fought from five kilometres away.
    if type(env.Config.Match.serverChecks) == 'table' then env.Config.Match.serverChecks.enabled = false end
    if opts.mutate then opts.mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local s = { env = env, config = env.Config, sent = sent, match = env.ArenaMatch, lobby = env.ArenaLobby,
        Arena = env.Arena, metadata = metadata, bags = bags, health = health, checks = checks,
        dispatch = dispatch }

    function s.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        clock = clock + 60000
        env.source = src
        handler(data)
    end

    function s.settle(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Opens a lobby and seats `ids` in it, on sides in a team mode.
    --- @return string matchId
    function s.open(ids, modeKey, arenaKey)
        modeKey = modeKey or 'ffa'
        s.fire('createMatch', ids[1], {
            arenaKey = arenaKey or 'trailerpark', modeKey = modeKey, entryFee = 0, account = 'cash',
            lives = env.Config.Match.lives,
        })
        local id = nil
        for _, match in ipairs(s.lobby.All()) do
            if match.players[ids[1]] then id = match.id end
        end
        assert(id, 'the fixture could not open a lobby')
        for index = 2, #ids do s.fire('joinMatch', ids[index], { matchId = id, account = 'cash' }) end
        if s.Arena.ModeUsesTeams(modeKey) then
            for index, src in ipairs(ids) do
                s.fire('setTeam', src, { teamKey = (index % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        return id
    end

    --- A live round with `ids` (default 1..count) placed in it.
    --- @return table match
    function s.play(count, modeKey, arenaKey, ids)
        if not ids then
            ids = {}
            for src = 1, count do ids[#ids + 1] = src end
        end
        local id = s.open(ids, modeKey, arenaKey)
        for _, src in ipairs(ids) do s.fire('setReady', src, { ready = true }) end
        for _ = 1, 6 do
            if s.lobby.Get(id).state == 'live' then break end
            threads.step()
        end
        assert(s.lobby.Get(id).state == 'live', 'the fixture failed to start the round')
        threads.step()
        return s.lobby.Get(id)
    end

    function s.revivesOf(src)
        local count = 0
        for _, who in ipairs(dispatch.revived) do if who == src then count = count + 1 end end
        return count
    end

    function s.eventsTo(src, name)
        local out = {}
        for _, message in ipairs(sent) do
            if message.target == src and message.event == 'crimson_arena:client:' .. name then
                out[#out + 1] = message.payload
            end
        end
        return out
    end

    function s.exitsTo(src) return #s.eventsTo(src, 'exitArena') end

    --- Whether pma-voice would let `src` onto `channel` right now: its own
    --- canJoinChannel, which lets anybody in when the channel has no check.
    function s.canJoin(channel, src)
        local check = checks[channel]
        if not check then return true end
        return check(src) == true
    end

    function s.stopResource()
        handlers['onResourceStop']('crimson_arena')
    end

    return s
end

-- ======================================================================
-- NOBODY WATCHES FROM THE FLOOR
-- ======================================================================

t.test('DEFECT: a player down in the city cannot start watching a round', function()
    for _, down in ipairs({ { inlaststand = true }, { isdead = true } }) do
        local s = newServer()
        local match = s.play(2)
        s.metadata[11] = down

        local ok, why = s.lobby.AddSpectator(11, match.id)
        t.isTrue(ok ~= true, 'a downed player was let in to watch -- held "alive" all round, revived at the end')
        t.equals(why, 'error.cannot_join_dead')

        s.fire('spectateMatch', 11, { matchId = match.id })
        t.isTrue(not (match.spectators or {})[11], 'the Watch button let a downed player in')
    end
end)

t.test('a watcher on their feet is let in as before', function()
    local s = newServer()
    local match = s.play(2)
    s.metadata[11] = { isdead = false, inlaststand = false }
    t.isTrue((s.lobby.AddSpectator(11, match.id)) == true, 'a standing watcher was refused')
end)

t.test('an ELIMINATED fighter, down by definition, is still put on the camera', function()
    -- ArenaMatch.OnDeath calls AddSpectator for somebody who has just died.
    local s = newServer()
    local match = s.play(3)
    s.metadata[3] = { isdead = true }
    s.match.OnDeath(3, 1)
    s.settle()
    t.isTrue(match.players[3].alive == false, 'premise: fighter 3 was eliminated')
    t.isTrue((match.spectators or {})[3] == true, 'an eliminated fighter was refused the camera for being dead')
end)

t.test('and with blockWhileDead switched off, nobody is refused', function()
    local s = newServer({ mutate = function(config) config.Match.blockWhileDead = false end })
    local match = s.play(2)
    s.metadata[11] = { isdead = true }
    t.isTrue((s.lobby.AddSpectator(11, match.id)) == true, 'the switch Join honours was not honoured')
end)

-- ======================================================================
-- THE ONLOOKER'S REVIVE
-- ======================================================================

t.test('DEFECT: a watcher who never went down is not sent the medical revive when the round ends', function()
    local s = newServer()
    local match = s.play(2)
    t.isTrue((s.lobby.AddSpectator(11, match.id)) == true, 'premise: the watcher got in')

    s.match.End(match.id, 'match.ended')
    s.settle(3)

    t.equals(s.exitsTo(11), 1, 'the watcher was not sent home')
    t.equals(s.revivesOf(11), 0, 'a watcher on their feet was handed the medical revive -- health rewritten, armour gone')
end)

t.test('DEFECT: nor when the round is aborted', function()
    local s = newServer()
    local match = s.play(2)
    s.lobby.AddSpectator(11, match.id)

    s.match.Abort(match.id, 'match.aborted')

    t.equals(s.exitsTo(11), 1, 'the watcher was not sent home')
    t.equals(s.revivesOf(11), 0, 'an abort handed a standing watcher the medical revive')
end)

t.test('a watcher the round DID put down is stood up: the medical state bag says so', function()
    local s = newServer()
    local match = s.play(2)
    s.lobby.AddSpectator(11, match.id)
    s.bags[11] = { [BAG] = 2 }              -- LAST_STAND

    s.match.End(match.id, 'match.ended')
    t.equals(s.revivesOf(11), 1, 'a watcher downed in the arena was sent home still down')
end)

t.test('and so is one whose body the server reads as dead', function()
    local s = newServer()
    local match = s.play(2)
    s.lobby.AddSpectator(11, match.id)
    s.health[11] = 0

    s.match.Abort(match.id, 'match.aborted')
    t.equals(s.revivesOf(11), 1, 'a watcher killed in the arena was sent home dead')
end)

t.test('a bag reading ALIVE is not a reason to revive', function()
    local s = newServer()
    local match = s.play(2)
    s.lobby.AddSpectator(11, match.id)
    s.bags[11] = { [BAG] = 1 }

    s.match.End(match.id, 'match.ended')
    t.equals(s.revivesOf(11), 0)
end)

t.test('every fighter is still stood up on the way out, as before', function()
    local s = newServer()
    local match = s.play(2)
    s.match.End(match.id, 'match.ended')
    for _, src in ipairs({ 1, 2 }) do
        t.isTrue(s.revivesOf(src) >= 1, 'fighter ' .. src .. ' left the round without the revive')
    end
end)

-- ======================================================================
-- END'S DELAYED SWEEP
-- ======================================================================

t.test('DEFECT: a fighter eliminated and sent home earlier is not swept again when the round ends', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(3)

    s.match.OnDeath(3, 1)
    s.settle()
    t.isTrue(match.players[3].leftArena == true, 'premise: fighter 3 was sent home')
    local before = s.revivesOf(3)

    s.match.End(match.id, 'match.ended')
    s.settle(4)                             -- the sweep's Wait, then its pass

    t.equals(s.revivesOf(3), before,
        'a fighter who went home long ago was revived by the sweep -- out in the city, for a fall the arena never caused')
end)

t.test('the fighters End itself sent home are still swept', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(3)
    s.match.OnDeath(3, 1)
    s.settle()

    s.match.End(match.id, 'match.ended')
    local atExit = s.revivesOf(1)
    s.settle(4)
    t.equals(s.revivesOf(1), atExit + 1, 'the sweep no longer reaches a fighter who was in the arena at the end')
    t.isTrue(s.revivesOf(2) >= 2, 'fighter 2 missed the exit revive or the sweep')
end)

-- ======================================================================
-- STOPPING A LOBBY NOBODY WAS PLACED IN
-- ======================================================================

t.test('DEFECT: stopping a lobby revives nobody and sends nobody an exit', function()
    local s = newServer()
    local id = s.open({ 1, 2 })
    t.equals(s.lobby.Get(id).state, 'lobby')

    t.isTrue(s.match.Abort(id, 'match.aborted'))

    t.isNil(s.lobby.Get(id), 'the lobby was not closed')
    t.isNil(s.lobby.GetByPlayer(1), 'the host is still attached to a closed lobby')
    for _, src in ipairs({ 1, 2 }) do
        t.equals(s.revivesOf(src), 0, 'lobby member ' .. src .. ' was handed the medical revive by an admin Stop')
        t.equals(s.exitsTo(src), 0, 'lobby member ' .. src .. ' was sent out of an arena they were never in')
    end
end)

t.test('DEFECT: nor a lobby COUNTDOWN, which is not a placed round either', function()
    local s = newServer({ mutate = function(config) config.Match.lobbyCountdownSeconds = 10 end })
    local id = s.open({ 1, 2 })
    for _, src in ipairs({ 1, 2 }) do s.fire('setReady', src, { ready = true }) end
    local match = s.lobby.Get(id)
    t.equals(match.state, 'countdown', 'premise: the lobby countdown is running')
    t.isTrue(match.placed ~= true, 'premise: nobody has been placed')

    s.match.Abort(id, 'match.aborted')
    t.equals(s.revivesOf(1) + s.revivesOf(2), 0, 'a lobby countdown called off revived its members')
end)

t.test('DEFECT: nor a resource restart with a lobby open', function()
    local s = newServer()
    s.open({ 1, 2 })
    s.stopResource()
    t.equals(s.revivesOf(1) + s.revivesOf(2), 0, 'a restart revived everybody waiting in a lobby')
end)

t.test('a live round that is stopped still sends every fighter home and stands them up', function()
    local s = newServer()
    local match = s.play(2)
    s.match.Abort(match.id, 'match.aborted')
    for _, src in ipairs({ 1, 2 }) do
        t.equals(s.exitsTo(src), 1, 'fighter ' .. src .. ' was left in an aborted round')
        t.equals(s.revivesOf(src), 2, 'fighter ' .. src .. ' was not revived on the way out (entry + exit)')
    end
end)

t.test('a roster half-placed by a start that threw: the one already placed goes home', function()
    -- Start's placement loop raising leaves `placed` unset with part of the
    -- roster in; countdownOverran aborts exactly that round.
    local s = newServer({ mutate = function(config) config.Match.lobbyCountdownSeconds = 10 end })
    local id = s.open({ 1, 2 })
    for _, src in ipairs({ 1, 2 }) do s.fire('setReady', src, { ready = true }) end
    s.dispatch.flag[1] = id                 -- sendEnterArena got as far as fighter 1

    s.match.Abort(id, 'match.aborted')
    t.equals(s.exitsTo(1), 1, 'a fighter already placed was left in the arena')
    t.equals(s.revivesOf(1), 1)
    t.equals(s.exitsTo(2), 0, 'a fighter never placed was sent an exit')
    t.equals(s.revivesOf(2), 0, 'a fighter never placed was revived')
end)

-- ======================================================================
-- THE FIGHTER SENT HOME WHO CAME BACK TO WATCH
-- ======================================================================

local function sentHomeThenWatching()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(3)
    s.match.OnDeath(3, 1)
    s.settle()
    t.isTrue(match.players[3].leftArena == true, 'premise: fighter 3 was sent home')
    s.fire('spectateMatch', 3, { matchId = match.id })
    t.isTrue((match.spectators or {})[3] == true, 'premise: fighter 3 is watching their own round again')
    return s, match
end

t.test('DEFECT: a fighter sent home who came back to watch is told when the round ends', function()
    local s, match = sentHomeThenWatching()
    local exits, revives = s.exitsTo(3), s.revivesOf(3)

    s.match.End(match.id, 'match.ended')
    s.settle(4)

    t.equals(s.exitsTo(3), exits + 1, 'the round ended and the watcher\'s camera was never told')
    t.equals(s.revivesOf(3), revives, 'they had their revive when they went home; this is a second one')
    local cards = s.eventsTo(3, 'results')
    t.equals((cards[#cards] or {}).deaths, 1, 'their own results card was replaced by a blank onlooker one')
end)

t.test('DEFECT: and when the round is aborted', function()
    local s, match = sentHomeThenWatching()
    local exits = s.exitsTo(3)
    s.match.Abort(match.id, 'match.aborted')
    t.equals(s.exitsTo(3), exits + 1, 'an aborted round never stopped the watcher\'s camera')
end)

t.test('a fighter sent home and NOT watching is sent nothing more', function()
    local s = newServer({ mutate = function(config) config.Match.spectateOnElimination = false end })
    local match = s.play(3)
    s.match.OnDeath(3, 1)
    s.settle()
    local exits = s.exitsTo(3)
    s.match.End(match.id, 'match.ended')
    t.equals(s.exitsTo(3), exits, 'a fighter already home was sent a second exit')
end)

-- ======================================================================
-- THE TEAM CHANNELS
-- ======================================================================

local function channelsOf(match)
    local out = {}
    for team, channel in pairs(match.radioChannels or {}) do out[team] = channel end
    return out
end

t.test('during the round each channel is its own side\'s, and nobody else\'s', function()
    local s = newServer()
    local match = s.play(4, 'tdm')
    local channels = channelsOf(match)
    t.isNotNil(channels.crimson, 'premise: the round was given team channels')
    t.isTrue(s.canJoin(channels.crimson, 1), 'a fighter was refused their own side\'s channel')
    t.isTrue(not s.canJoin(channels.crimson, 2), 'the other side was let onto the channel')
    t.isTrue(not s.canJoin(channels.crimson, 11), 'an outsider was let onto a live team\'s channel')
end)

t.test('DEFECT: once the round ends, its channels are open to everybody again', function()
    local s = newServer()
    local match = s.play(4, 'tdm')
    local channels = channelsOf(match)

    s.match.End(match.id, 'match.ended')

    for team, channel in pairs(channels) do
        t.isTrue(s.canJoin(channel, 11), ('channel %d (%s) still refuses everybody after the round'):format(channel, team))
        t.isTrue(s.canJoin(channel, 1), ('channel %d refuses a former fighter after the round'):format(channel))
    end
end)

t.test('DEFECT: and after an abort', function()
    local s = newServer()
    local match = s.play(4, 'tdm')
    local channels = channelsOf(match)
    s.match.Abort(match.id, 'match.aborted')
    for _, channel in pairs(channels) do
        t.isTrue(s.canJoin(channel, 11), ('channel %d still locked after an abort'):format(channel))
    end
end)

t.test('DEFECT: and when the last fighter walks out, which never passes End or Abort', function()
    local s = newServer()
    local match = s.play(2, 'tdm')
    local id = match.id
    local channels = channelsOf(match)
    s.match.RemovePlayer(1, 'match.left', true)
    s.match.RemovePlayer(2, 'match.left', true)
    t.isNil(s.lobby.Get(id), 'premise: the match is gone')
    for _, channel in pairs(channels) do
        t.isTrue(s.canJoin(channel, 11), ('channel %d still locked after everybody left'):format(channel))
    end
end)

t.test('a channel a NEWER round has been handed keeps that round\'s lock', function()
    -- Two channels in the range, two team rounds: the second wraps onto the
    -- first one's numbers. The first ending must not open the second's.
    local s = newServer({ mutate = function(config)
        config.Modes.tdm.teamRadio = { enabled = true, firstChannel = 400, lastChannel = 401 }
    end })
    local first = s.play(4, 'tdm', 'trailerpark', { 1, 2, 3, 4 })
    local second = s.play(4, 'tdm', 'skydome', { 5, 6, 7, 8 })
    local channel = second.radioChannels.crimson
    t.isTrue(channel == 400 or channel == 401, 'premise: the second round wrapped onto the first one\'s range')

    s.match.Abort(first.id, 'match.aborted')

    t.equals(s.lobby.Get(second.id).state, 'live', 'premise: the second round is still being fought')
    t.isTrue(not s.canJoin(channel, 11), 'ending the first round opened a live team\'s channel to anybody')
    t.isTrue(s.canJoin(channel, 5), 'the live team lost its own channel')
end)

-- ======================================================================
-- THE CHANNEL THEY WERE ON, READ BEFORE THE DOOR TAKES THEIR RADIO
--
-- client/match.lua hands a player's own radio channel back at the exit, and
-- the number it hands back is the one the server sends as
-- `priorRadioChannel`. The door's stash takes their radio item, and a radio
-- script that drops the channel when the item goes answers it -- so the
-- reading has to be taken BEFORE ArenaAmmo.Issue. The fixture's Issue drops
-- the channel at once, the worst case of that answer.
-- ======================================================================

t.test('DEFECT: the channel a fighter was on is read before the door, and sent in with them', function()
    local s = newServer()
    for _, src in ipairs({ 1, 2 }) do s.bags[src] = { radioChannel = 3 } end
    local issue = s.env.ArenaAmmo.Issue
    s.env.ArenaAmmo.Issue = function(src, ...)
        s.bags[src].radioChannel = 0        -- the radio script, on the stash
        return issue(src, ...)
    end

    s.play(2)

    for _, src in ipairs({ 1, 2 }) do
        local entered = s.eventsTo(src, 'enterArena')
        t.equals(#entered, 1, 'premise: fighter ' .. src .. ' was placed once')
        t.equals(entered[1].priorRadioChannel, 3,
            ('fighter %d went in on channel 3 and the exit was told %s'):format(src,
                tostring(entered[1].priorRadioChannel)))
    end
end)

t.test('and a channel the server cannot read is sent as nothing, so the client asks pma-voice itself', function()
    -- nil, never 0: a 0 would tell the client "they were on none" for
    -- certain, and stop it falling back to its own reading.
    local s = newServer()
    s.play(2)
    local entered = s.eventsTo(1, 'enterArena')
    t.equals(#entered, 1, 'premise: fighter 1 was placed once')
    t.isNil(entered[1].priorRadioChannel, 'an unreadable channel was sent as a number')
end)

os.exit(t.summary())
