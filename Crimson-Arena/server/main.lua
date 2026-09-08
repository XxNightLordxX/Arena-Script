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
    -- A line in the console and nothing else, sent only when what it says
    -- changes. Tight, because nothing is waiting on it.
    diag = 1000,
    -- THE ADMIN TABLET. Loose, because an operator watching a live round
    -- refreshes it deliberately and every handler behind it re-checks
    -- ArenaIsAdmin -- the rate limit is a flood guard, not the gate.
    admin = 500,
}

--- The refresh each admin is currently waiting on, by server id.
---
--- THE STASH SWEEP IS ASYNCHRONOUS AND CAN TAKE SECONDS. Nothing sequenced
--- two of them, and the tablet applies every payload it is sent -- so an
--- admin who refreshed against a slow database and then clicked into a match
--- had the first scan answer afterwards and throw them back out to the match
--- list, drawn from rows several seconds old. A match aborted in between
--- still showed as live, and still offered a Stop button for it.
---
--- UP HERE rather than beside pushAdmin, because the disconnect handler --
--- which is the only thing that drops an entry -- sits between the two.
--- @type table<number, number>
local adminScan = {}

--- The number the next scan takes. Only ever goes up.
--- @type number
local adminTicket = 0

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

--- Weapon entries read out of a request before giving up.
--- `Config.Loadouts.slots` decides how many are USED; this decides how many
--- are LOOKED AT, which is the number a sender controls.
local MAX_WEAPON_ENTRIES = 32

--- The same bound for the supplies list. A request naming every supply on
--- the server twice over is not a player picking a loadout, and the list is
--- walked before anything in it is validated.
local MAX_SUPPLY_ENTRIES = 16

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

    -- SUPPLIES, REBUILT THE SAME WAY AND FOR THE SAME REASON. A key and a
    -- count, both scalars, both bounded here before Arena.ResolveSupplies
    -- decides which key names a real item and how many of it a player may
    -- carry. Nothing the sender supplied is passed on by reference.
    --
    -- `armor` is deliberately NOT rebuilt any more. Starting armour is a
    -- rule of the arena rather than a loadout field, so a client sending one
    -- is a client trying to choose how hard it is to kill them -- and the
    -- honest way to refuse that is to stop reading the field at all rather
    -- than to read it and clamp it somewhere further in.
    local supplies = {}
    local askedSupplies = tableArg(payload.supplies)
    if askedSupplies then
        for index = 1, MAX_SUPPLY_ENTRIES do
            local entry = tableArg(askedSupplies[index])
            if not entry then break end

            local key = keyArg(entry.key)
            if key then
                supplies[#supplies + 1] = { key = key, count = intArg(entry.count) }
            end
        end
    end

    return { weapons = weapons, supplies = supplies }
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
--- `dropped` says the player's CONNECTION went away rather than them
--- choosing to leave. Passed explicitly rather than sniffed out of
--- reasonKey: the leaderboard rule downstream turns on it, and a rule that
--- read a string would break silently the day somebody reworded a notice.
--- @param src any
--- @param reasonKey string?
--- @param dropped boolean? -- true only from playerDropped
--- @return boolean ok -- false when the exit was REFUSED
--- @return string|nil refusal -- the locale key to put on their screen
local function detach(src, reasonKey, dropped)
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
    --
    -- AND IT OWNS THE REFUSAL WITH IT. ArenaLobby.Leave turns away a
    -- voluntary exit from a lobby the player has a side-bet on -- a bet its
    -- holder can cancel by standing up is a bet with no risk in it -- and
    -- RemovePlayer carries that answer up rather than swallowing it. Passed
    -- straight through: this function decides nothing about it, it only
    -- refuses to lose it, which is the whole reason both exits come through
    -- one door.
    local handled, refusal = ArenaMatch.RemovePlayer(src, reasonKey, dropped)
    if handled then return refusal == nil, refusal end

    return ArenaLobby.Leave(src, reasonKey, dropped)
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

--- A snapshot on demand.
---
--- ASKING FOR ONE IS NOT THE SAME AS HAVING THE PANEL OPEN, and this used to
--- treat them as the same thing. client/spectate.lua asks for a snapshot when
--- the camera starts -- the roster it needs to name the living only exists
--- there -- with the panel shut. That marked them present, and nothing ever
--- unmarked them: they kept receiving every state broadcast on the server for
--- the rest of their session, long after they had stopped watching anything.
---
--- The panel says `panel = true` when it is the one asking. Anything else --
--- including an older client that sends no payload at all -- gets the
--- snapshot without being counted as watching.
onClient('crimson_arena:server:requestState', RATE.state, function(src, data)
    if type(data) == 'table' and data.panel == true then
        ArenaLobby.MarkPanelOpen(src)
    end
    TriggerClientEvent('crimson_arena:client:state', src, ArenaLobby.BuildState(src))
end)

--- WHY THE TEAM OUTLINE IS OR IS NOT DRAWN, ON THE SERVER'S CONSOLE.
---
--- client/match.lua has always worked this out and printed it -- in F8, on
--- the player's own machine. That is the right place for a player wondering
--- about their own screen and the wrong one for the person debugging the
--- server, who is reading a server console and cannot see it. Two rounds of
--- "the haze is not working" were spent with the answer already computed and
--- sitting somewhere nobody was looking.
---
--- So the client sends it here, and only here: this handler prints and does
--- nothing else. It changes no state, so a client that lies about it can
--- only put a wrong line in a debug log.
---
--- Sent only when the reason CHANGES, and only with Config.Debug on. A
--- healthy round says one line at the start and then nothing.
onClient('crimson_arena:server:outlineReason', RATE.diag, function(src, data)
    if not Config.Debug then return end

    local reason = type(data) == 'table' and data.reason or data
    if type(reason) ~= 'string' then return end

    -- Truncated rather than trusted: it is going into a log, and a client
    -- can send any string it likes.
    ArenaDebug('outline: %s reports -- %s', tostring(src), reason:sub(1, 200))
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
        intArg(payload.entryFee), intArg(payload.lives), boolArg(payload.radar),
        keyArg(payload.account), intArg(payload.roundTimeSeconds),
        keyArg(payload.winCondition), tableArg(payload.tierPlan),
        intArg(payload.scoreLimit))
    if not matchId then return refuse(src, reason) end

    ArenaNotifyKey(src, 'notify.match_created', 'success')
end)

onClient('crimson_arena:server:joinMatch', RATE.join, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local matchId = keyArg(payload.matchId)
    if not matchId then return refuse(src, 'error.match_not_found') end

    local ok, reason = ArenaLobby.Join(src, matchId, keyArg(payload.teamKey), keyArg(payload.account))
    if not ok then return refuse(src, reason) end

    ArenaNotifyKey(src, 'notify.match_joined', 'success')
end)

--- LEAVING CAN BE REFUSED, WHICH IS NEW, and this is where the player hears
--- about it. A lobby the player has a side-bet on will not let them walk out
--- of it; every other exit answers as it always did, and a `false` with no
--- key -- nothing to leave -- still says nothing, exactly as before.
onClient('crimson_arena:server:leaveMatch', RATE.leave, function(src)
    local ok, reason = detach(src, 'notify.you_left')
    if not ok and reason then return refuse(src, reason) end
end)

onClient('crimson_arena:server:setTeam', RATE.choice, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local teamKey = keyArg(payload.teamKey)
    if not teamKey then return refuse(src, 'error.pick_a_team') end

    local ok, reason = ArenaLobby.SetTeam(src, teamKey)
    if not ok then return refuse(src, reason) end
end)

--- THE ONE REFUSAL THAT HAS TO PUT THE SCREEN BACK, and the reason it is
--- the only one: every other control on the panel renders straight off the
--- snapshot, so a refused request leaves it showing what the server already
--- holds. The loadout picker is different -- it holds a DRAFT that exists
--- only in the browser until the server agrees -- so a refusal that was
--- only a red toast left the picker showing the rejected weapons, under the
--- word "Saved."
---
--- ArenaLobby.SetLoadout pushes its own snapshot when it succeeds; this is
--- the other half of that.
onClient('crimson_arena:server:setLoadout', RATE.choice, function(src, data)
    local request = loadoutArg(data)
    if not request then
        ArenaLobby.PushState(src)
        return refuse(src)
    end

    local ok, reason = ArenaLobby.SetLoadout(src, request)
    if not ok then
        ArenaLobby.PushState(src)
        return refuse(src, reason)
    end
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

--- The host holding a start they have already called.
---
--- SEPARATE FROM cancelMatch, and it has to be: the panel's "Stop The
--- Countdown" posted the cancel, which destroys the lobby and evicts
--- everybody -- the opposite of what the button says.
onClient('crimson_arena:server:holdCountdown', RATE.start, function(src)
    local ok, reason = ArenaLobby.HoldCountdown(src)
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
        roundTimeSeconds = intArg(data.roundTimeSeconds),
        -- THESE THREE WERE MISSING, and the shape of that is the one this
        -- resource keeps rediscovering: the panel posts them, client/ui.lua
        -- names them in its relay, ArenaLobby.UpdateMatch reads and
        -- validates all three -- and this handler in the middle built a
        -- table without them. So "Apply changes" moved the arena, the mode,
        -- the lives, the radar and the clock, and silently refused to move
        -- the win condition, the kill limit or the gun-game ladder. Nothing
        -- errored at either end, because nothing at either end was wrong.
        --
        -- Sanitised exactly as the create door sanitises them.
        winCondition = keyArg(data.winCondition),
        scoreLimit = intArg(data.scoreLimit),
        tierPlan = tableArg(data.tierPlan),
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
    local ok, reason = ArenaBetting.PlaceSpectatorBet(src, matchId, pick, intArg(payload.amount),
        keyArg(payload.account))
    if not ok then return refuse(src, reason) end

    -- NEITHER THE BROADCAST NOR THE TOAST IS HERE ANY MORE, and both used
    -- to be. ArenaBetting.PlaceSpectatorBet does both itself, a few lines
    -- after it takes the money: it broadcasts so the bettor's wallet and the
    -- pot stop reading from before the bet, and it says
    -- 'notify.spectator_bet_placed', which names the amount.
    --
    -- Two fixes wrote the same repair in two places without meeting. The
    -- cost was one player-visible bug and one invisible one: two toasts for
    -- one bet -- "$500 on your pick. No takebacks." and then "Bet is down."
    -- -- and two full snapshot rebuilds, each of which refreshes the
    -- leaderboard, the config block and the match list and then pushes a
    -- per-head payload to everybody on the server.
    --
    -- The copy that survives is the one beside the money, because it is the
    -- only one every path into that function reaches.
end)

-- ======================================================================
-- DISCONNECTS
-- ======================================================================

AddEventHandler('playerDropped', function()
    local src = source

    -- THE ONE CALLER THAT PASSES `dropped`. Everything else in this file is
    -- somebody choosing to go.
    detach(src, 'notify.player_disconnected', true)
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

    -- The tablet's refresh ticket is keyed by source too, and only an admin
    -- who has opened the screen ever has one. Dropping it also means a scan
    -- still in flight for them is discarded on arrival rather than sent to
    -- whoever holds that id next.
    adminScan[src] = nil

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

    -- ONE LINE, UNCONDITIONAL, not gated on Config.Debug -- the same reading
    -- the client's own `lobby:` line gets. An operator who has just set
    -- opening hours wants to know, at start, that the server agrees with
    -- them about what time it is; and an operator who has NOT set any wants
    -- to know that too, because "the arena is shut" is otherwise the first
    -- thing they hear about it, from a player.
    local hours = ArenaHoursState()
    if hours.line then
        ArenaLog('hours: %s (server clock %s, offset %+dh -> %s) -- %s',
            hours.line, hours.serverClock, hours.offsetHours, hours.arenaClock,
            hours.open and 'OPEN now' or ('SHUT now, opens at ' .. tostring(hours.snapshot.opensAt)))
    else
        ArenaLog('hours: not enforced -- the arena is open at every hour.')
    end

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

--- WHAT THE SERVER THINKS THE TIME IS, and every number that went into it
--- kept APART.
---
--- The same reading ArenaDispatch.IsolationState is written for: an operator
--- told "shut" cannot act on it without knowing whether the machine's clock
--- is wrong or the offset is. Printed as four separate facts rather than one
--- sentence, so the wrong one is obvious.
RegisterCommand('arenahours', function(src)
    if not ArenaIsAdmin(src) then
        return refuse(src, 'error.no_permission')
    end

    local hours = ArenaHoursState()
    tell(src, ('arena hours: %s'):format(hours.enabled and 'ON' or 'OFF'))
    tell(src, ('  this machine says: %s'):format(hours.serverClock))
    tell(src, ('  offsetHours:       %+d'):format(hours.offsetHours))
    tell(src, ('  arena is going by: %s'):format(hours.arenaClock))
    tell(src, ('  windows:           %s'):format(hours.line or '(none -- open at every hour)'))

    -- AN ADMIN'S DECISION, SAID FIRST AND ALWAYS.
    --
    -- This is the one command an operator runs to answer "why is the arena
    -- shut", and it could not answer it. ArenaHoursState grew a `forced`
    -- field for exactly this -- its own comment says an operator reading
    -- "open" at four in the morning needs to know whether that is the
    -- schedule or somebody's decision -- and nothing read it. On a server
    -- keeping no hours, an arena an admin had closed printed "open at every
    -- hour" and stopped.
    if hours.forced then
        tell(src, ('  OVERRIDDEN:        an admin has the doors %s. /arenaadmin puts them back.')
            :format(hours.forced == 'open' and 'HELD OPEN past the schedule'
                or 'CLOSED inside the schedule'))
    end

    -- OUTSIDE `if hours.line`, because whether the arena is open right now is
    -- worth saying on every server -- and on one with no windows at all it is
    -- the ONLY thing worth saying, since an override is then the only thing
    -- that can have shut it.
    local when = hours.open and hours.snapshot.closesAt or hours.snapshot.opensAt
    tell(src, ('  right now:         %s%s'):format(
        hours.open and 'OPEN' or 'SHUT',
        -- NAMED ONLY WHEN THERE IS ONE. `closesAt` is set only while the
        -- SCHEDULE says open and `opensAt` only while it says shut, so an
        -- override that disagrees with the clock leaves the matching one
        -- absent -- and this line used to print the word `nil` at an
        -- operator trying to work out what was wrong.
        type(when) == 'string' and (hours.open and (', until ' .. when)
            or (', opens at ' .. when)) or ''))

    if hours.line then
        -- THE ACTIONABLE LINE. An operator whose box is in the wrong
        -- timezone needs the number to type, not a diagnosis.
        tell(src, '  if "this machine says" is not your local time, put the difference in '
            .. 'Config.Schedule.offsetHours.')
    end
end, false)

-- ======================================================================
-- THE ADMIN TABLET
--
-- /arenaadmin with no arguments opens a small screen listing the live
-- matches: click a match to see who is in it and stop it, click a fighter to
-- see what the arena is holding for them and put them back on their feet.
--
-- EVERY HANDLER RE-CHECKS ArenaIsAdmin, and that is not belt and braces. The
-- command is what OPENS the screen; it is not authorisation for anything the
-- screen does. A client can fire these events without ever having run the
-- command -- that is what a client is -- so the gate has to be on the action.
--
-- READ-ONLY EXCEPT FOR TWO THINGS, both of which already existed as admin
-- powers: stopping a match (ArenaMatch.Abort, which refunds everybody) and
-- reviving a fighter (the same call the respawn path makes). The escrow view
-- moves nothing at all.
-- ======================================================================

--- One row per live match, with what an admin needs to pick between them.
--- @return table[]
local function adminMatches()
    local rows = {}
    for _, match in ipairs(ArenaLobby.All()) do
        rows[#rows + 1] = {
            id = match.id,
            label = match.label,
            arenaKey = match.arenaKey,
            modeKey = match.modeKey,
            state = match.state,
            hostName = match.hostName,
            players = ArenaLobby.PlayerCount(match),
            pot = ArenaBetting.GetPot(match.id),
        }
    end
    return rows
end

--- Who is in one match, and what the arena is holding for each of them.
---
--- THE ESCROW IS THE POINT OF THIS SCREEN. "Their kit is safe" and "their
--- stake is held" are claims this resource makes constantly and could not be
--- asked to demonstrate: both lived in local tables with no reader, so the
--- only way to see either was to end the round and watch what came back.
--- @param matchId string
--- @return table|nil
local function adminMatch(matchId)
    local match = ArenaLobby.Get(matchId)
    if not match then return nil end

    local rows = {}
    for _, player in ipairs(ArenaLobby.PlayerArray(match)) do
        local held = ArenaAmmo.HeldFor(player.src)
        local staked, account = ArenaBetting.StakeOf(match.id, player.src)

        rows[#rows + 1] = {
            src = player.src,
            name = player.name,
            team = player.team,
            alive = player.alive == true,
            kills = Arena.ToInt(player.kills) or 0,
            deaths = Arena.ToInt(player.deaths) or 0,
            lives = Arena.ToInt(player.lives) or 0,
            -- WHAT IS ACTUALLY IN THE STASH, beside what the arena BELIEVES
            -- it put there. Those two disagreeing is the whole of the bug
            -- that lost people their belongings, and an admin staring at an
            -- empty list needs to know whether that is normal.
            escrow = held and held.items or {},
            escrowStash = held and held.stash or nil,
            escrowExpected = held and held.expected or 0,
            staked = staked,
            stakedFrom = account,
        }
    end

    return {
        id = match.id,
        label = match.label,
        state = match.state,
        pot = ArenaBetting.GetPot(match.id),
        -- WHETHER THE `lives` ON EACH ROW ABOVE MEANS ANYTHING. Under a kill
        -- limit or most kills nobody is eliminated, so that number never
        -- moves -- and an admin reading it to decide who is nearly out is
        -- reading a constant. Sent rather than worked out on the panel, for
        -- the same reason the lobby card's copy is: the rule is the match's,
        -- and the panel has no business re-deriving it.
        livesSpent = not Arena.PlaysLadder(match.modeKey)
            and Arena.WinConditionSpendsLives(match.winCondition),
        players = rows,
    }
end

--- Stamps each outstanding stash with the SERVER ID of whoever it belongs
--- to, when they are on the server.
---
--- ArenaAmmo keys `owed` by citizen id, deliberately: a server id is whoever
--- holds it now, and the whole reason that table survives a reconnect is that
--- it does not use one. But the hand-back needs a live source to give items
--- to, so the two are matched up here rather than inside ammo.lua -- and the
--- absence of one is a real answer the screen shows ("not on the server")
--- rather than a row it hides.
--- @param rows table[]
--- @return table[]
local function withHolders(rows)
    local byCitizen = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local target = Arena.ToInt(id)
        local player = target and ArenaGetPlayer(target) or nil
        local citizenid = player and player.PlayerData and player.PlayerData.citizenid or nil
        if Arena.IsKey(citizenid) then byCitizen[citizenid] = target end
    end

    for _, row in ipairs(rows) do
        row.src = byCitizen[row.citizenid]
    end
    return rows
end

--- @param src number
--- @param matchId string|nil -- the match the tablet has open, if any
local function pushAdmin(src, matchId)
    -- ASYNCHRONOUS, because the stash list is a database read. Everything
    -- else on this screen is in memory and instant; the one thing that is not
    -- is also the one thing that has to outlive a restart, so the push waits
    -- for it rather than sending a screen with a hole in it and filling the
    -- hole later.
    local matches = adminMatches()
    local focused = Arena.IsKey(matchId) and adminMatch(matchId) or nil

    -- STAMPED BEFORE THE READ, CHECKED AFTER IT. Only the newest ask for
    -- this admin is allowed to draw; an older one that answers late is
    -- dropped where it stands rather than painting a stale screen over a
    -- fresh one.
    -- MONOTONIC ACROSS THE WHOLE SERVER, not per source.
    --
    -- Per source, `playerDropped` clears the entry and the next scan for that
    -- id restarts at 1 -- the same number a scan issued before the disconnect
    -- may still be holding. A reconnecting admin could then have their tablet
    -- painted with rows read before they left. One counter that only ever goes
    -- up cannot collide with itself.
    adminTicket = adminTicket + 1
    local ticket = adminTicket
    adminScan[src] = ticket

    local total, read = 0, 0
    ArenaAmmo.AllStashes(function(rows)
        if adminScan[src] ~= ticket then return end

        TriggerClientEvent('crimson_arena:client:adminState', src, {
            matches = matches,
            focused = focused,
            -- THE DOORS, on every push. The tablet has a switch for them and
            -- a switch that does not show its own state is a switch nobody
            -- can trust -- especially this one, where the wrong answer is an
            -- arena that quietly never shuts again.
            hoursOpen = ArenaHoursOpen(),
            hoursForced = ArenaHoursOverride(),
            -- THE HOURS THEMSELVES, so a closed arena can say what it is
            -- closed UNTIL rather than only that it is closed. Both are nil
            -- on a server that keeps no schedule, which is the honest answer
            -- there: nothing is being enforced, so there is no window to
            -- quote and no next opening to name.
            hoursLine = Arena.ScheduleLine(),
            hoursOpensAt = ArenaHoursSnapshot().opensAt,
            owed = withHolders(rows),
            -- HOW MANY ROWS EXIST AND HOW MANY WERE OPENED. An admin looking
            -- at four stashes needs to know whether that is all of them or
            -- the first four of nine hundred.
            stashesFound = total,
            stashesRead = read,
        })
    end, function(found, opened) total, read = found, opened end)
end


onClient('crimson_arena:server:adminState', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end
    local payload = tableArg(data) or {}
    pushAdmin(src, keyArg(payload.matchId))
end)

onClient('crimson_arena:server:adminStop', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    local matchId = payload and keyArg(payload.matchId)
    if not matchId or not ArenaLobby.Get(matchId) then
        return refuse(src, 'error.match_not_found')
    end

    -- Abort, not Destroy: the admin path refunds everybody whatever state the
    -- match is in, and a live round needs unwinding first. The same call the
    -- text command makes.
    ArenaMatch.Abort(matchId, 'notify.match_stopped_by_admin')
    ArenaLog('%s stopped match %s from the admin tablet', ArenaPlayerName(src), matchId)

    -- The match this admin was looking at no longer exists, so the tablet is
    -- sent back to the list rather than to a detail screen for a dead id.
    pushAdmin(src, nil)
end)

onClient('crimson_arena:server:adminReturn', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    if not payload then return refuse(src, 'error.invalid_request') end

    local target = intArg(payload.target)

    -- ONLINE: HAND IT OVER NOW.
    --
    -- The same call the sweep makes, and deliberately not a shortcut around
    -- it. ReturnLeftovers refuses somebody who is mid-match, works out their
    -- citizen id itself, and hands back only what is actually in their stash
    -- -- so an admin pressing this cannot conjure items, cannot reach into
    -- somebody else's stash, and cannot empty one into a player who is
    -- standing in a live round.
    if target and target > 0 then
        local ok, returned = ArenaAmmo.ReturnLeftovers(target)
        ArenaLog('%s handed %s %d item(s) back from the admin tablet (%s)',
            ArenaPlayerName(src), ArenaPlayerName(target), returned or 0,
            ok and 'complete' or 'still outstanding')

        return pushAdmin(src, keyArg(payload.matchId))
    end

    -- OFFLINE: QUEUE IT, so the server hands it over the moment they are next
    -- seen.
    --
    -- There is no live inventory to put items into for somebody who is not
    -- here, so this is the only safe thing an admin can do for them -- and it
    -- is not a consolation prize, it closes a real gap. `owed` is in MEMORY:
    -- a restart empties it and the sweep only ever tries the people on it, so
    -- a stash left outstanding when the server went down was invisible to the
    -- retry for ever after. The items were safe in a real stash and nothing
    -- was ever going to hand them over. This puts it back on the list.
    local citizenid = keyArg(payload.citizenid)
    local stash = keyArg(payload.stash)
    if not (citizenid and stash) then return refuse(src, 'error.invalid_request') end

    if not ArenaAmmo.QueueReturn(citizenid, stash) then
        return refuse(src, 'error.invalid_request')
    end

    ArenaLog('%s queued %s\'s stash (%s) from the admin tablet -- it goes back the next time they are seen.',
        ArenaPlayerName(src), citizenid, stash)
    ArenaNotifyKey(src, 'notify.return_queued', 'success', citizenid)

    pushAdmin(src, keyArg(payload.matchId))
end)

onClient('crimson_arena:server:adminHours', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data) or {}

    -- THREE STATES: held open past the schedule, closed inside it, or handed
    -- back to the clock. ArenaSetHoursOverride treats anything that is not
    -- one of the two words as "follow the schedule", so a malformed payload
    -- gives the arena back its own hours rather than inventing a state.
    --
    -- CLOSING DOES NOT END A ROUND ALREADY BEING FOUGHT. The sweep in
    -- server/match.lua tears down waiting LOBBIES when the doors shut and
    -- leaves live rounds alone -- shutting the arena is about who may come
    -- in, not about who is already inside.
    local mode = ArenaSetHoursOverride(keyArg(payload.forced))

    ArenaLog('%s set the arena doors to %s', ArenaPlayerName(src),
        mode == 'open' and 'HELD OPEN past the schedule'
            or (mode == 'shut' and 'CLOSED inside the schedule' or 'follow the schedule'))

    -- AND THE LOBBIES GO WITH THEM, HERE, RATHER THAN ON THE NEXT SWEEP.
    --
    -- The sweep in server/match.lua closes the waiting lobbies when it
    -- NOTICES the doors change, which is the right thing for a schedule
    -- window quietly closing at the top of the hour. It is not enough for a
    -- person pressing a button: an admin who shuts the arena and watches a
    -- lobby go on queueing for a round that cannot start -- with its host
    -- still out of pocket for the entry fee -- has no way to tell that from a
    -- button that did nothing.
    --
    -- ASKED THROUGH ArenaHoursOpen RATHER THAN OFF `mode`, so this cannot
    -- disagree with the gate: what closes the lobbies is the doors being
    -- shut, which is a different question from what an admin just clicked.
    -- Handing the arena back to a schedule that is mid-window closes nothing;
    -- handing it back to one that is not closes them, and should.
    if not ArenaHoursOpen() then
        local closed = ArenaMatch.CloseWaitingLobbies('notify.hours_lobby_closed')
        if closed > 0 then
            ArenaLog('door: %d lobby(s) closed and every stake handed back.', closed)
        end
    end

    -- EVERYBODY, NOT JUST THIS ADMIN. The doors decide what the lobby NPC
    -- says, whether the ground marker is drawn and what line the panel puts
    -- under Create Match -- so a change nobody else is told about is an arena
    -- that lets people in through a door every other screen still calls shut.
    ArenaLobby.Broadcast()

    pushAdmin(src, keyArg(payload.matchId))
end)

onClient('crimson_arena:server:adminRevive', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    local target = payload and intArg(payload.target)
    if not target or target <= 0 then return refuse(src, 'error.invalid_request') end

    -- IN A MATCH, AND THIS ADMIN'S OWN VIEW OF IT. Reviving somebody who is
    -- not in a round is not this screen's business -- there is a /arenarevive
    -- for that -- and taking the id straight off the wire would make this a
    -- revive-anybody button dressed as an arena tool.
    local match = ArenaLobby.GetByPlayer(target)
    if not match then return refuse(src, 'error.not_in_match') end

    local row = match.players[target]

    -- A REVIVE IS NOT A RESURRECTION INTO THE ROUND, and `alive` used to be
    -- flipped with no look at either.
    --
    -- Arena.IsEliminated is exactly `alive ~= true and lives <= 0`, so
    -- setting the flag put a fighter the round had already finished with back
    -- into every winner-selection path in server/match.lua. Two things
    -- followed, both silent. The round could no longer END by last-man-
    -- standing, because somebody who is not in the arena and cannot be shot
    -- was being counted as standing -- and with roundTimeSeconds = 0 there is
    -- no clock to break the deadlock either, so the match simply ran for
    -- ever. Then, once the real fighters had eliminated each other, that
    -- spectator was the last one standing: crowned, recorded as the winner,
    -- and paid the pot out of everybody else's stakes.
    --
    -- SO THE TWO HALVES ARE SPLIT. The medical revive happens for anybody --
    -- that is what the button says, and picking somebody up off the floor is
    -- never the wrong thing to do. The ROUND standing is restored only for a
    -- fighter the round has lives left for, and only while it is still being
    -- fought.
    -- A ROUND BEING FOUGHT OR ABOUT TO BE.
    --
    -- `live` alone was too tight, and it showed up in the report that a
    -- player killed before the match started could not be revived from here:
    -- the start countdown is `countdown`, everybody is standing in the arena
    -- frozen, and somebody who arrived down is exactly the person an admin is
    -- reaching for. Refusing there left the medical revive happening while
    -- the roster went on calling them dead.
    --
    -- `lobby` is still refused, and deliberately: nobody is in an arena then,
    -- so there is no round standing to restore.
    local fighting = match.state == 'live' or match.state == 'countdown'
    local eliminated = Arena.IsEliminated(row)
    if row and not eliminated and fighting then
        row.alive = true
    end

    ArenaDispatch.Revive(target)
    ArenaLog('%s revived %s from the admin tablet%s', ArenaPlayerName(src), ArenaPlayerName(target),
        eliminated and ' -- they are out of the round and stay out' or '')

    -- SAID TO THE ADMIN, because a button that does half of what its label
    -- says and reports nothing is a button nobody can trust. They pressed
    -- Revive on somebody the round is done with; they are entitled to know
    -- that is what happened.
    if eliminated then
        ArenaNotifyKey(src, 'notify.revived_but_out', 'inform', ArenaPlayerName(target))
    end

    pushAdmin(src, match.id)
end)

RegisterCommand('arenaadmin', function(src, args)
    if not ArenaIsAdmin(src) then
        return refuse(src, 'error.no_permission')
    end

    local action = keyArg(args[1]) or (src == 0 and 'list' or 'tablet')

    -- NO ARGUMENTS, FROM A PLAYER, OPENS THE SCREEN. The console has no NUI
    -- to open one in, so it keeps the list it always had -- which is also why
    -- `tablet` is only the default for a real player rather than for
    -- everybody.
    if action == 'tablet' then
        if src == 0 then return tell(src, locale('cmd.usage')) end
        -- THE SCREEN GOES UP FIRST, on what memory can answer this instant.
        --
        -- It used to be opened from INSIDE the stash sweep's callback, on the
        -- reasoning that a first draw without the stash list would tell an
        -- operator "nothing outstanding" when the whole reason they opened it
        -- is that somebody is short. That reasoning was right about the lie
        -- and wrong about the cure: the sweep is a database read, and a
        -- database that answers slowly opened the screen late while one that
        -- never answered at all meant /arenaadmin did nothing whatsoever --
        -- no screen, no error, nothing in the console to read.
        --
        -- The screen does not lie in the meantime either: an empty `owed`
        -- list draws no "not handed back yet" section at all, rather than an
        -- empty one captioned as good news.
        TriggerClientEvent('crimson_arena:client:openAdmin', src, {
            matches = adminMatches(),
            owed = {},
            stashesFound = 0,
            stashesRead = 0,
            hoursOpen = ArenaHoursOpen(),
            hoursForced = ArenaHoursOverride(),
            -- THE HOURS THEMSELVES, so a closed arena can say what it is
            -- closed UNTIL rather than only that it is closed. Both are nil
            -- on a server that keeps no schedule, which is the honest answer
            -- there: nothing is being enforced, so there is no window to
            -- quote and no next opening to name.
            hoursLine = Arena.ScheduleLine(),
            hoursOpensAt = ArenaHoursSnapshot().opensAt,
        })

        -- AND THEN THE SWEEP, exactly as the screen's own refresh button asks
        -- for it. It lands behind the open in this client's own event queue,
        -- and the client drops it outright if the tablet has been closed by
        -- the time it arrives.
        pushAdmin(src, nil)

        ArenaLog('%s opened the admin tablet', ArenaPlayerName(src))
        return
    end

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
