--[[
    crimson_arena/server/main.lua

    The wire. Everything a client can say to this resource arrives here,
    and almost nothing is decided here.

    A handler in this file does four things, in this order, and then stops:
    read `source` into a local, rate-limit it, check the SHAPE of what
    arrived, and hand the pieces to ArenaLobby / ArenaMatch / ArenaBetting.
    Any handler that starts weighing config, moving money or touching a
    match record belongs in one of those files instead.

    WHY SHAPE-CHECKING IS THE WHOLE JOB. Every argument below came off the
    network, which means it is whatever a modified client felt like sending:
    a table where a number belongs, a string a megabyte long, a list with
    ten thousand weapon entries, a table nested into itself. The rules in
    shared/arena.lua are strict about VALUES but they are not armour against
    a hostile SHAPE -- `Arena.ResolveLoadout` will happily walk a list as
    long as the sender cares to make it. So the argument readers at the top
    of this file rebuild every payload from scalars, bounded, and reject
    anything they cannot make sense of rather than coercing it into
    something plausible.

    The second authority check, if you are counting: the panel already
    refuses what config forbids, and every call below re-asks anyway,
    because the panel is the client's and the client is not trusted.
]]

-- ======================================================================
-- RATE LIMITS
--
-- Per source, per bucket, in milliseconds. These are anti-spam floors,
-- not gameplay pacing -- each one is well under the fastest a human can
-- meaningfully act, so a real player never notices a refusal and a script
-- hammering an event never gets a second call through.
-- ======================================================================
local RATE = {
    state = 500,
    create = 3000,
    join = 1000,
    leave = 1000,
    choice = 250,       -- team, loadout and ready share a tempo
    start = 2000,
    spectate = 1000,
    bet = 1500,
    -- Deliberately the loosest limit here. A throttled death report is a
    -- player who stays alive on the scoreboard after dying on screen, so
    -- this only has to catch a flood, not pace anything.
    death = 200,
}

-- ======================================================================
-- ARGUMENT READERS
--
-- The only code in this file that touches a raw payload. Each one returns
-- either a clean scalar or nil; none of them ever returns something the
-- caller has to look inside again.
-- ======================================================================

--- A key long enough to be a weapon is a key. Anything longer is either a
--- bug or an attempt to make a downstream string operation expensive, and
--- no legitimate config key comes close to this.
local MAX_KEY_LENGTH = 64

--- Weapon entries read out of a request before giving up. `weaponSlots`
--- decides how many are USED; this decides how many are LOOKED AT, which
--- is the number a sender controls.
local MAX_WEAPON_ENTRIES = 32

--- @param value any
--- @return table|nil
local function tableArg(value)
    if type(value) ~= 'table' then return nil end
    return value
end

--- @param value any
--- @return string|nil
local function keyArg(value)
    if not Arena.IsKey(value) or #value > MAX_KEY_LENGTH then return nil end
    return value
end

--- @param value any
--- @return integer|nil
local function intArg(value)
    -- Arena.ToInt is nil for tables, NaN and both infinities, which is
    -- every non-number a client can put in a numeric field.
    return Arena.ToInt(value)
end

--- Booleans are not coerced: `0`, `'false'` and `{}` are all rejected
--- rather than guessed at, because a ready flag guessed wrong starts a
--- match somebody did not agree to.
--- @param value any
--- @return boolean|nil
local function boolArg(value)
    if value == true or value == false then return value end
    return nil
end

--- A side-bet pick is a team key in a team mode and a fighter's server id
--- in a free-for-all. Both spellings are legal on the wire; betting.lua
--- canonicalises them, so this only has to prove it is one or the other.
--- @param value any
--- @return string|integer|nil
local function pickArg(value)
    local id = intArg(value)
    if id then return id end
    return keyArg(value)
end

--- Rebuilds a loadout request out of scalars.
---
--- Nothing the sender supplied is passed on by reference: what comes back
--- is a bounded list of { key = string, ammo = integer|nil } built here,
--- so a nested or self-referencing payload cannot reach Arena.ResolveLoadout
--- at all. The values themselves are still the sender's -- resolving them
--- against the catalogue is that function's job, not this one's.
--- @param data any
--- @return table|nil request
local function loadoutArg(data)
    local payload = tableArg(data)
    if not payload then return nil end

    local weapons = {}
    local wanted = tableArg(payload.weapons)
    if wanted then
        for index = 1, MAX_WEAPON_ENTRIES do
            local entry = tableArg(wanted[index])
            if not entry then break end

            local key = keyArg(entry.key)
            if key then
                weapons[#weapons + 1] = { key = key, ammo = intArg(entry.ammo) }
            end
        end
    end

    return { weapons = weapons, armor = intArg(payload.armor) }
end

-- ======================================================================
-- HANDLER PLUMBING
-- ======================================================================

--- @param src number
--- @param reasonKey string?
local function refuse(src, reasonKey)
    ArenaNotifyKey(src, Arena.IsKey(reasonKey) and reasonKey or 'error.invalid_request', 'error')
end

--- Registers one client -> server event with the boilerplate every one of
--- them needs: `source` captured before anything can yield, then the rate
--- limit, then the handler.
---
--- A throttled call is dropped silently. Telling a spamming client it was
--- throttled would hand it a notification to spam with instead.
--- @param event string
--- @param intervalMs integer
--- @param fn fun(src: number, data: any)
local function onClient(event, intervalMs, fn)
    RegisterNetEvent(event, function(data)
        local src = source
        if not ArenaRateLimit(src, event, intervalMs) then return end
        fn(src, data)
    end)
end

--- Takes a player out of whatever they are in, live match or lobby.
---
--- The two exits are genuinely different: ArenaMatch.RemovePlayer has to
--- decide whether a departure ends the round, while ArenaLobby.Leave only
--- has to hand a stake back. Leaving and disconnecting both come through
--- here so neither can grow a rule the other is missing.
--- @param src number
--- @param reasonKey string
local function detach(src, reasonKey)
    local match = ArenaLobby.GetByPlayer(src)
    if match and ArenaMatch.IsLive(match.id) then
        ArenaMatch.RemovePlayer(src, reasonKey)
        return
    end
    ArenaLobby.Leave(src, reasonKey)
end

-- ======================================================================
-- STATE
-- ======================================================================

--- The panel asks for the snapshot the moment it opens, so answering is
--- also how we learn a panel IS open and should be pushed to.
lib.callback.register('crimson_arena:server:getState', function(src)
    ArenaLobby.MarkPanelOpen(src)
    return ArenaLobby.BuildState(src)
end)

onClient('crimson_arena:server:requestState', RATE.state, function(src)
    ArenaLobby.MarkPanelOpen(src)
    TriggerClientEvent('crimson_arena:client:state', src, ArenaLobby.BuildState(src))
end)

-- ======================================================================
-- LOBBY
-- ======================================================================

onClient('crimson_arena:server:createMatch', RATE.create, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local arenaKey = keyArg(payload.arenaKey)
    if not arenaKey then return refuse(src, 'error.arena_unavailable') end

    -- A missing mode or fee is a panel that was never touched; the lobby
    -- falls back to the operator's defaults for both.
    local matchId, reason = ArenaLobby.Create(src, arenaKey, keyArg(payload.modeKey), intArg(payload.entryFee))
    if not matchId then return refuse(src, reason) end

    ArenaNotifyKey(src, 'notify.match_created', 'success')
end)

onClient('crimson_arena:server:joinMatch', RATE.join, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local matchId = keyArg(payload.matchId)
    if not matchId then return refuse(src, 'error.match_not_found') end

    local ok, reason = ArenaLobby.Join(src, matchId, keyArg(payload.teamKey))
    if not ok then return refuse(src, reason) end

    ArenaNotifyKey(src, 'notify.match_joined', 'success')
end)

onClient('crimson_arena:server:leaveMatch', RATE.leave, function(src)
    detach(src, 'notify.you_left')
end)

onClient('crimson_arena:server:setTeam', RATE.choice, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local teamKey = keyArg(payload.teamKey)
    if not teamKey then return refuse(src, 'error.pick_a_team') end

    local ok, reason = ArenaLobby.SetTeam(src, teamKey)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:setLoadout', RATE.choice, function(src, data)
    local request = loadoutArg(data)
    if not request then return refuse(src) end

    local ok, reason = ArenaLobby.SetLoadout(src, request)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:setReady', RATE.choice, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local ready = boolArg(payload.ready)
    if ready == nil then return refuse(src) end

    local ok, reason = ArenaLobby.SetReady(src, ready)
    if not ok then return refuse(src, reason) end
end)

-- ======================================================================
-- MATCH CONTROL
-- ======================================================================

--- Which match a start or cancel is aimed at is never taken from the
--- payload: it is the one the sender is standing in. A match id on the
--- wire would be an invitation to start somebody else's lobby.
onClient('crimson_arena:server:startMatch', RATE.start, function(src)
    local match = ArenaLobby.GetByPlayer(src)
    if not match then return refuse(src, 'error.not_in_match') end

    -- ArenaMatch.Begin weighs Config.Match.onlyHostCanStart against the
    -- requester; passing `src` is what gives it something to weigh.
    local ok, reason = ArenaMatch.Begin(match.id, src)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:cancelMatch', RATE.start, function(src)
    local match = ArenaLobby.GetByPlayer(src)
    if not match then return refuse(src, 'error.not_in_match') end
    if match.hostSource ~= src then return refuse(src, 'error.host_only') end

    -- Cancelling is a lobby control. Once the round is running the way out
    -- is leaving it, or an admin stop -- both of which already exist, and
    -- neither of which should be reachable by every host through a button
    -- labelled "cancel".
    if match.state ~= 'lobby' and match.state ~= 'countdown' then
        return refuse(src, 'error.match_in_progress')
    end

    ArenaLobby.Destroy(match.id, 'notify.match_cancelled')
end)

--- A death report is a hint from the victim's client, and it is treated as
--- one: ArenaMatch.OnDeath re-checks that the reporter is really in a live
--- match and really alive, and that the claimed killer is somebody who
--- could have killed them. All this end has to do is prove the killer id
--- is a number before it goes any further.
onClient('crimson_arena:server:reportDeath', RATE.death, function(src, data)
    local payload = tableArg(data)
    if not payload then return end

    -- A death with no killer is ordinary -- fall damage, the boundary, the
    -- player's own grenade -- so an absent id is passed through as nil
    -- rather than refused.
    ArenaMatch.OnDeath(src, intArg(payload.killerServerId))
end)

-- ======================================================================
-- SPECTATING AND SIDE-BETS
-- ======================================================================

onClient('crimson_arena:server:spectateMatch', RATE.spectate, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local matchId = keyArg(payload.matchId)
    if not matchId then return refuse(src, 'error.match_not_found') end

    local ok, reason = ArenaLobby.AddSpectator(src, matchId)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:stopSpectating', RATE.spectate, function(src)
    ArenaLobby.RemoveSpectator(src)
end)

onClient('crimson_arena:server:placeSpectatorBet', RATE.bet, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local matchId = keyArg(payload.matchId)
    if not matchId then return refuse(src, 'error.match_not_found') end

    local pick = pickArg(payload.pick)
    if not pick then return refuse(src, 'error.bet_invalid_pick') end

    -- The amount is handed over as it arrived: Arena.ResolveSpectatorBet
    -- owns the min/max band, and clamping it here would turn a bet outside
    -- the band into a smaller bet the player never agreed to.
    local ok, reason = ArenaBetting.PlaceSpectatorBet(src, matchId, pick, intArg(payload.amount))
    if not ok then return refuse(src, reason) end

    ArenaNotifyKey(src, 'notify.bet_placed', 'success')
end)

-- ======================================================================
-- DISCONNECTS
-- ======================================================================

AddEventHandler('playerDropped', function()
    local src = source

    detach(src, 'notify.player_disconnected')
    ArenaLobby.RemoveSpectator(src)
    ArenaLobby.MarkPanelClosed(src)

    -- Last, and always: the rate-limit history is keyed by source and
    -- nothing else drops it, so skipping this leaks a table per player who
    -- has ever connected.
    ArenaForgetPlayer(src)
end)

-- ======================================================================
-- RESOURCE LIFECYCLE
-- ======================================================================

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    Arena.ReportConfigProblems()
    ArenaStats.EnsureSchema()
    ArenaLog('%s ready', Config.ResourceLabel)
end)

--- THE HANDLER THAT STOPS A RESTART EATING A POT.
---
--- Every live match is holding real money in escrow. A stop with no
--- refund path leaves that money nowhere: the escrow tables go with the
--- Lua state and the players it came from have nothing to show for it.
--- So every match is aborted -- which refunds every stake in full -- and
--- only then are the queued stat rows flushed.
---
--- Everything here is synchronous on purpose. A stop handler that yields
--- may not be resumed, and a refund that never resumes is the exact bug
--- this exists to prevent.
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    local aborted = 0
    for _, match in ipairs(ArenaLobby.All()) do
        ArenaMatch.Abort(match.id, 'notify.resource_stopping')
        aborted = aborted + 1
    end
    if aborted > 0 then
        ArenaLog('stopping: aborted and refunded %d match(es)', aborted)
    end

    ArenaStats.Flush()
end)

-- ======================================================================
-- ADMIN COMMAND
--
-- Registered unrestricted and gated on ArenaIsAdmin inside, so the ACE
-- groups in Config.Permissions.adminGroups are the only thing that decides
-- who may use it -- and the server console (source 0) always may.
-- ======================================================================

--- Console gets `print`, a player gets a notification: the console has no
--- notification to receive and a player has no console to read.
--- @param src number
--- @param message string
local function tell(src, message)
    if src == 0 then
        ArenaLog('%s', message)
    else
        ArenaNotify(src, message, 'info')
    end
end

RegisterCommand('arenaadmin', function(src, args)
    if not ArenaIsAdmin(src) then
        return refuse(src, 'error.no_permission')
    end

    local action = keyArg(args[1]) or 'list'

    if action == 'list' then
        local all = ArenaLobby.All()
        if #all == 0 then
            return tell(src, locale('cmd.no_matches'))
        end
        for _, match in ipairs(all) do
            tell(src, locale('cmd.match_row',
                match.id,
                match.state,
                ArenaLobby.PlayerCount(match),
                ArenaBetting.GetPot(match.id)))
        end
        return
    end

    if action == 'stop' then
        local matchId = keyArg(args[2])
        if not matchId or not ArenaLobby.Get(matchId) then
            return tell(src, locale('cmd.match_not_found'))
        end

        -- Abort, not Destroy: the admin path refunds everybody whatever
        -- state the match is in, and a live round needs unwinding first.
        ArenaMatch.Abort(matchId, 'notify.match_stopped_by_admin')
        return tell(src, locale('cmd.match_stopped', matchId))
    end

    if action == 'wipe' then
        local wiped = 0
        for _, match in ipairs(ArenaLobby.All()) do
            ArenaMatch.Abort(match.id, 'notify.match_stopped_by_admin')
            wiped = wiped + 1
        end
        ArenaLog('%s wiped %d match(es)', ArenaPlayerName(src), wiped)
        return tell(src, locale('cmd.wiped', wiped))
    end

    tell(src, locale('cmd.usage'))
end, false)
