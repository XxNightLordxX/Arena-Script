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
                -- ammoType is a KEY, not a value: it names an entry in that
                -- weapon's type list, and Arena.ResolveAmmoType refuses
                -- anything not on it. A field dropped here would leave the
                -- whole ammo-type feature inert on the wire while both ends
                -- looked correct.
                weapons[#weapons + 1] = {
                    key = key,
                    ammo = intArg(entry.ammo),
                    ammoType = keyArg(entry.ammoType),
                }
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
    -- ArenaMatch.RemovePlayer owns the "are they mid-match" question and
    -- already calls ArenaLobby.Leave itself; it returns false only when the
    -- player was in no match at all.
    --
    -- THIS USED TO ASK ArenaMatch.IsLive, WHICH WAS THE WRONG QUESTION.
    -- IsLive is `state == 'live'`, but Start() teleports everybody into the
    -- arena and leaves the state at 'countdown' -- only goLive() promotes it,
    -- several seconds later, after the frozen countdown. A player who left
    -- during that window was standing in the arena, holding a routing bucket
    -- and the dispatch flag, while this gate said they were not, so they went
    -- to ArenaLobby.Leave and no exit was ever sent: their police and medical
    -- alerts stayed suppressed for the rest of their session and they kept a
    -- bucket that made them invisible. RemovePlayer's own predicate has always
    -- been the correct one ('live' OR 'countdown'); this was a narrower copy
    -- of it that drifted. Asking the owner rather than re-deriving the answer
    -- is what stops it drifting again.
    if ArenaMatch.RemovePlayer(src, reasonKey) then return end

    ArenaLobby.Leave(src, reasonKey)
end

-- ======================================================================
-- STATE
-- ======================================================================

--- The panel asks for the snapshot the moment it opens, so answering is
--- also how we learn a panel IS open and should be pushed to.
--- RATE-LIMITED like every other client entry point, and it is the one that
--- most needs it: BuildState walks every match, every player in each and the
--- leaderboard, so it is the most expensive thing a client can ask for, and
--- being a callback rather than an event was the only reason it escaped the
--- limiter its `requestState` twin has always had.
---
--- A throttled call answers nil rather than a stale snapshot. client/ui.lua
--- refuses to open on a falsy state and tells the player so, which is the
--- right outcome for a second panel-open inside half a second -- that is a
--- stuck button or a script, not somebody reading the menu.
lib.callback.register('crimson_arena:server:getState', function(src)
    if not ArenaRateLimit(src, 'crimson_arena:server:getState', RATE.state) then return nil end

    ArenaLobby.MarkPanelOpen(src)
    return ArenaLobby.BuildState(src)
end)

-- The other half of MarkPanelOpen. Cheap, idempotent, and rate-limited on the
-- same tempo as the state request it undoes -- a client that spams it only
-- costs a table write it has already paid for.
onClient('crimson_arena:server:panelClosed', RATE.state, function(src)
    ArenaLobby.MarkPanelClosed(src)
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
    local matchId, reason = ArenaLobby.Create(src, arenaKey, keyArg(payload.modeKey),
        intArg(payload.entryFee), intArg(payload.lives), boolArg(payload.radar))
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

--- Nothing to shape-check: the only argument a cancel has is who sent it.
--- Whether they are the host, whether the match is still cancellable, and
--- what closing it does to the stakes are all ArenaLobby.Cancel's to answer
--- -- the last of those reads Config.Betting.refundOnCancel, which is
--- precisely the kind of decision this file does not make.
onClient('crimson_arena:server:cancelMatch', RATE.start, function(src)
    local ok, reason = ArenaLobby.Cancel(src)
    if not ok then return refuse(src, reason) end
end)

--- The host changing their mind about a lobby they have already opened.
---
--- Rate-limited as a CHOICE rather than as a start: it is somebody adjusting
--- a form, which they will do several times in a row, not an action that
--- opens or closes anything.
onClient('crimson_arena:server:updateMatch', RATE.choice, function(src, data)
    if type(data) ~= 'table' then return refuse(src, 'error.invalid_request') end

    local ok, reason = ArenaLobby.UpdateMatch(src, {
        arenaKey = keyArg(data.arenaKey),
        modeKey = keyArg(data.modeKey),
        lives = intArg(data.lives),
        -- boolArg, so anything that is not a real boolean arrives as nil and
        -- UpdateMatch leaves the setting alone -- rather than a stray string
        -- reading as `true` and switching a radar on nobody asked for.
        radar = boolArg(data.radar),
    })
    if not ok then return refuse(src, reason) end
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

    -- detach() routes a live-match disconnect through the normal exit, which
    -- clears the flag. This catches the rest: a player who dropped between
    -- being placed in the arena and the match registering it, and any future
    -- path that forgets. Clearing a flag that was never set costs nothing.
    ArenaDispatch.Clear(src)

    -- Same catch as the flag above, for the same reason: detach() reclaims on
    -- the normal exit, and this covers a drop between being issued ammunition
    -- and the match recording it. Reclaiming from somebody who holds nothing
    -- costs nothing.
    ArenaAmmo.Reclaim(src, 'disconnected')

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
