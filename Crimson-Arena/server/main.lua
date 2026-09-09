-- Crimson Arena: the front door. Every message the panel sends.

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
    diag = 1000,
    -- THE ADMIN TABLET. Loose, because an operator watching a live round
    -- refreshes it deliberately and every handler behind it re-checks
    -- ArenaIsAdmin -- the rate limit is a flood guard, not the gate.
    admin = 500,
}

local adminScan = {}

local adminTicket = 0

local MAX_KEY_LENGTH = 64

local MAX_WEAPON_ENTRIES = 32

local MAX_SUPPLY_ENTRIES = 16

local function tableArg(value)
    if type(value) ~= 'table' then return nil end
    return value
end

local function keyArg(value)
    if not Arena.IsKey(value) or #value > MAX_KEY_LENGTH then return nil end
    return value
end

local function intArg(value)
    return Arena.ToInt(value)
end

local function boolArg(value)
    if value == true or value == false then return value end
    return nil
end

local function pickArg(value)
    local id = intArg(value)
    if id then return id end
    return keyArg(value)
end

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

local function refuse(src, reasonKey)
    ArenaNotifyKey(src, Arena.IsKey(reasonKey) and reasonKey or 'error.invalid_request', 'error')
end

--- @param event string
--- @param intervalMs integer
--- @param fn fun(src: integer, data: any)
--- @param throttled fun(src: integer)? -- run INSTEAD of fn when the rate
---        limiter drops this one. Opt-in per event; see setTeam below for
---        the only one that takes it, and why.
local function onClient(event, intervalMs, fn, throttled)
    RegisterNetEvent(event, function(data)
        local src = source
        if not ArenaRateLimit(src, event, intervalMs) then
            -- A DROPPED EVENT ANSWERS ONLY WHERE AN EVENT WAS ASKED TO
            -- ANSWER, and that is deliberate rather than timidity.
            --
            -- Most of what this file throttles is a flood -- a panel
            -- refreshing, a client reporting a death twice, an operator
            -- hammering the tablet -- and answering a flood is how a rate
            -- limiter becomes an amplifier pointed at the person who
            -- triggered it. `death` in particular is loose ON PURPOSE and
            -- says so above; a toast per dropped death report would be
            -- noise over the one thing a fighter must not miss.
            --
            -- So a handler that wants its refusals audible asks for it.
            if throttled then throttled(src) end
            return
        end
        fn(src, data)
    end)
end

local function detach(src, reasonKey, dropped)
    local handled, refusal = ArenaMatch.RemovePlayer(src, reasonKey, dropped)
    if handled then return refusal == nil, refusal end

    return ArenaLobby.Leave(src, reasonKey, dropped)
end

lib.callback.register('crimson_arena:server:getState', function(src)
    if not ArenaRateLimit(src, 'crimson_arena:server:getState', RATE.state) then return nil end

    ArenaLobby.MarkPanelOpen(src)
    return ArenaLobby.BuildState(src)
end)

onClient('crimson_arena:server:panelClosed', RATE.state, function(src)
    ArenaLobby.MarkPanelClosed(src)
end)

onClient('crimson_arena:server:requestState', RATE.state, function(src, data)
    if type(data) == 'table' and data.panel == true then
        ArenaLobby.MarkPanelOpen(src)
    end
    TriggerClientEvent('crimson_arena:client:state', src, ArenaLobby.BuildState(src))
end)

onClient('crimson_arena:server:outlineReason', RATE.diag, function(src, data)
    if not Config.Debug then return end

    local reason = type(data) == 'table' and data.reason or data
    if type(reason) ~= 'string' then return end

    ArenaDebug('outline: %s reports -- %s', tostring(src), reason:sub(1, 200))
end)

onClient('crimson_arena:server:createMatch', RATE.create, function(src, data)
    local payload = tableArg(data)
    if not payload then return refuse(src) end

    local arenaKey = keyArg(payload.arenaKey)
    if not arenaKey then return refuse(src, 'error.arena_unavailable') end

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
end,
-- THE ONE THROTTLED EVENT THAT ANSWERS, AND THE DEFECT THAT BOUGHT IT.
--
-- IN A PLAYER'S WORDS, from the live server, three times: "i clicked a
-- team, had another member join my team, they switched teams, and in the
-- match they could not kill each other" -- "it bugged them where they
-- couldnt shoot each other". The server's own log for that round says
-- `ash 1 v crimson 2 (0 assigned, 3 chose their own)` and then `crossfire:
-- 4 may not damage 3 -- they are on the same team and friendly fire is
-- off`. So the pair really were on one side, the guard really did refuse
-- the shot, and the friendly-fire rule was never broken. The SWITCH never
-- happened.
--
-- It never happened because this handler ate it. Two clicks inside
-- RATE.choice -- a fifth of a second, which is exactly how long a person
-- takes to correct a misclick on a tile that has not lit up yet -- and the
-- second one fell down the bare `return` above: no refusal, no toast, no
-- state push, nothing in any log. Every other way a switch can be turned
-- down says so; this one alone was silent, and it is the one that put a
-- man in a round believing he was on the other side.
--
-- SO IT NAMES THE SIDE HE IS ACTUALLY ON, which is the answer to the
-- question the click asked. Not "slow down": a fighter does not need to
-- know about a rate limiter, he needs to know he did not move.
--
-- CHEAP, AND POINTED AT NOBODY BUT THE CLICKER. One table lookup and one
-- event, to the source and only the source -- no snapshot, no broadcast,
-- no leaderboard. A client spamming this event pays for one line to
-- itself per message it sent, which is the same order as the message.
-- Somebody who is in no match is told nothing at all, because there is no
-- side to name.
function(src)
    -- `match.players` is keyed by SERVER ID, a number, and every other
    -- reader in this file goes through tonumber before indexing it.
    local target = tonumber(src)
    local match = target and ArenaLobby.GetByPlayer(target)
    local row = match and match.players[target]
    local side = row and Arena.GetTeamByKey(row.team)
    if not side then return end

    ArenaNotifyKey(target, 'notify.team_side', 'warning', side.label or row.team)
end)

onClient('crimson_arena:server:setLoadout', RATE.choice, function(src, data)
    -- ONLY FOR SOMEBODY WHO HAS A PICKER OPEN, and this is the same guard
    -- `updateMatch` states at length two handlers down. The push exists to
    -- put a REFUSED DRAFT back on the screen of somebody who is in a lobby;
    -- a player with no match has no draft to put back and no picker to put
    -- it in. Without it, `setLoadout` from a client that has never joined
    -- anything bought the most expensive thing this file builds -- every
    -- lobby, every player's own row, the leaderboard -- four times a second,
    -- before SetLoadout's own membership check ever ran. Measured at ten
    -- pushes to updateMatch's nought. DO NOT push to a stranger.
    local drafting = ArenaLobby.GetByPlayer(src) ~= nil

    local request = loadoutArg(data)
    if not request then
        if drafting then ArenaLobby.PushState(src) end
        return refuse(src)
    end

    local ok, reason = ArenaLobby.SetLoadout(src, request)
    if not ok then
        if drafting then ArenaLobby.PushState(src) end
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

onClient('crimson_arena:server:startMatch', RATE.start, function(src)
    local match = ArenaLobby.GetByPlayer(src)
    if not match then return refuse(src, 'error.not_in_match') end

    local ok, reason = ArenaMatch.Begin(match.id, src)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:holdCountdown', RATE.start, function(src)
    local ok, reason = ArenaLobby.HoldCountdown(src)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:cancelMatch', RATE.start, function(src)
    local ok, reason = ArenaLobby.Cancel(src)
    if not ok then return refuse(src, reason) end
end)

onClient('crimson_arena:server:updateMatch', RATE.choice, function(src, data)
    if type(data) ~= 'table' then return refuse(src, 'error.invalid_request') end

    local ok, reason = ArenaLobby.UpdateMatch(src, {
        arenaKey = keyArg(data.arenaKey),
        modeKey = keyArg(data.modeKey),
        lives = intArg(data.lives),
        radar = boolArg(data.radar),
        roundTimeSeconds = intArg(data.roundTimeSeconds),
        winCondition = keyArg(data.winCondition),
        scoreLimit = intArg(data.scoreLimit),
        tierPlan = tableArg(data.tierPlan),
    })
    if not ok then
        -- AND THE SCREEN GOES BACK, exactly as the loadout picker's does one
        -- handler down and for the same reason. The create/edit form is the
        -- other control on this panel holding a DRAFT, so a refusal that was
        -- only a red toast left it showing the rule the server had just
        -- turned down -- with the lobby card beside it showing the rule the
        -- round is actually fought under, and nothing saying which was real.
        --
        -- The count is what makes the push land: the form seeds once per
        -- lobby id on purpose, so that a broadcast in the middle of somebody
        -- typing does not overwrite them. A refusal is the one moment it
        -- must seed again.
        -- ONLY FOR SOMEBODY WHO HAS A FORM OPEN. A full snapshot is the
        -- most expensive thing this file builds -- every lobby, every
        -- player's own row, the leaderboard -- and without this guard an
        -- empty `updateMatch` from a client that has never opened a lobby
        -- bought one, four times a second, before any membership check ran.
        -- The push exists to put a HOST'S form back; a player with no lobby
        -- has no form to put back.
        if ArenaLobby.GetByPlayer(src) ~= nil then
            ArenaLobby.NoteEditRefused(src)
            ArenaLobby.PushState(src)
        end
        return refuse(src, reason)
    end
end)

onClient('crimson_arena:server:reportDeath', RATE.death, function(src, data)
    local payload = tableArg(data)
    if not payload then return end

    -- `why` IS FOR THE LOG AND FOR NOTHING ELSE. It is a small integer the
    -- dying client picks; ArenaMatch.OnDeath turns it into one of four fixed
    -- sentences and never lets it decide anything. DO NOT widen it to a
    -- string -- that is a client writing its own lines into the operator's
    -- console.
    ArenaMatch.OnDeath(src, intArg(payload.killerServerId), nil, intArg(payload.why))
end)

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

    local ok, reason = ArenaBetting.PlaceSpectatorBet(src, matchId, pick, intArg(payload.amount),
        keyArg(payload.account))
    if not ok then return refuse(src, reason) end

end)

AddEventHandler('playerDropped', function()
    local src = source

    detach(src, 'notify.player_disconnected', true)
    ArenaLobby.RemoveSpectator(src)
    ArenaLobby.MarkPanelClosed(src)

    ArenaDispatch.Clear(src)

    ArenaAmmo.Reclaim(src, 'disconnected')

    adminScan[src] = nil

    ArenaLobby.ForgetEditRefusals(src)

    ArenaForgetPlayer(src)
end)

AddEventHandler('onResourceStart', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    Arena.ReportConfigProblems()
    ArenaStats.EnsureSchema()

    -- AND WHAT PLAYERS STILL OWE THE ARENA, read back before anybody can
    -- queue. Without this the table was a write-only log: every debt
    -- faithfully recorded and never looked at again, so a restart still
    -- forgot the lot and the rows just sat there proving it. DO NOT drop
    -- this call.
    ArenaAmmo.LoadOwedKit()

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

local function tell(src, message)
    if src == 0 then
        ArenaLog('%s', message)
    else
        ArenaNotify(src, message, 'info')
    end
end

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

    if hours.forced then
        tell(src, ('  OVERRIDDEN:        an admin has the doors %s. /arenaadmin puts them back.')
            :format(hours.forced == 'open' and 'HELD OPEN past the schedule'
                or 'CLOSED inside the schedule'))
    end

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
        tell(src, '  if "this machine says" is not your local time, put the difference in '
            .. 'Config.Schedule.offsetHours.')
    end
end, false)

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

--- Whether a stash could be OPENED on this look, as against how many were
--- NAMED.
---
--- ArenaAmmo.AllStashes COUNTS NAMES. With ox_inventory stopped it reads
--- nothing, drops every row, and still reports found = read = N -- and the
--- screen took that as proof it had looked, so an operator whose inventory
--- resource was down was told THE ARENA IS HOLDING NOTHING FOR ANYBODY
--- while it was holding everything. That is the one sentence this screen
--- must never say when it could not look.
---
--- THE SAME MISTAKE THE OWED-KIT LINE MADE, and the same cure: send the
--- state of the MECHANISM, never a count of what it returned. DO NOT go back
--- to inferring this from stashesRead.
---
--- Asked per push and never cached, exactly as ammo.lua asks it: an operator
--- restarting their inventory resource must not leave this answering for the
--- rest of the session.
---
--- AND IT ANSWERS "READABLE" WHEN IT CANNOT ASK. This drives a warning on the
--- operator's screen, and a warning raised because a lookup was unavailable
--- is a warning they learn to scroll past. Only a definite "ox_inventory is
--- not running" is worth putting in front of them.
local function stashesReadable()
    local asked, state = pcall(GetResourceState, 'ox_inventory')
    return not asked or state == 'started'
end

--- Whether server id `target` is still the character the tablet drew.
---
--- NO NAME MEANS DO NOT ASK. The tablet always sends one, but /arenaadmin's
--- own callers and an older panel do not, and a row that names nobody is a
--- row there is nothing to disagree with -- refusing it would take away the
--- hand-back rather than aim it.
--- @param target integer
--- @param citizenid string|nil
--- @return boolean
local function holderIs(target, citizenid)
    if not Arena.IsKey(citizenid) then return true end

    local player = ArenaGetPlayer(target)
    local holder = player and player.PlayerData and player.PlayerData.citizenid or nil
    return holder == citizenid
end

local function pushAdmin(src, matchId)
    local matches = adminMatches()
    local focused = Arena.IsKey(matchId) and adminMatch(matchId) or nil

    adminTicket = adminTicket + 1
    local ticket = adminTicket
    adminScan[src] = ticket

    local total, read = 0, 0
    ArenaAmmo.AllStashes(function(rows)
        if adminScan[src] ~= ticket then return end

        TriggerClientEvent('crimson_arena:client:adminState', src, {
            matches = matches,
            focused = focused,
            hoursOpen = ArenaHoursOpen(),
            hoursForced = ArenaHoursOverride(),
            hoursLine = Arena.ScheduleLine(),
            hoursOpensAt = ArenaHoursSnapshot().opensAt,
            owed = withHolders(rows),
            -- WHAT LEFT WITH SOMEBODY, beside what the arena is holding FOR
            -- somebody. The list above is the arena's debt to a player; this
            -- is the player's debt to the arena, and an operator who cannot
            -- see it cannot tell a quiet server from one being farmed.
            owedKit = withHolders(ArenaAmmo.OwedKit()),
            owedKitSaved = ArenaAmmo.OwedKitIsSaved(),
            databaseOn = Config.Database.enabled == true,
            stashesFound = total,
            stashesRead = read,
            stashesReadable = stashesReadable(),
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
        -- AND THE SCREEN GOES BACK, which is the rule the create/edit form
        -- and the loadout picker already state at length. This screen holds
        -- a DRAW rather than a draft, and it is drawn only when the admin
        -- asks: nothing tells an open tablet that the round it is showing
        -- has ended. So a match that finished while they were reading it
        -- left them on a detail page for something that no longer exists,
        -- with a live-looking roster and a Stop button, and pressing it
        -- produced a red toast and no change at all. The refusal is the one
        -- moment this screen knows it is out of date. DO NOT read this push
        -- as a redundant scan and tidy it away: it is the only thing that
        -- clears the ghost.
        pushAdmin(src, nil)
        return refuse(src, 'error.match_not_found')
    end

    ArenaMatch.Abort(matchId, 'notify.match_stopped_by_admin')
    ArenaLog('%s stopped match %s from the admin tablet', ArenaPlayerName(src), matchId)

    pushAdmin(src, nil)
end)

onClient('crimson_arena:server:adminReturn', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    if not payload then return refuse(src, 'error.invalid_request') end

    local target = intArg(payload.target)
    local citizenid = keyArg(payload.citizenid)
    local stash = keyArg(payload.stash)

    -- ONLINE: HAND IT OVER NOW.
    --
    -- The same call the sweep makes, and deliberately not a shortcut around
    -- it. ReturnLeftovers refuses somebody who is mid-match, works out their
    -- citizen id itself, and hands back only what is actually in their stash
    -- -- so an admin pressing this cannot conjure items, cannot reach into
    -- somebody else's stash, and cannot empty one into a player who is
    -- standing in a live round.
    --
    -- AND ONLY WHILE THAT SERVER ID IS STILL THE PERSON THE ROW NAMES. A
    -- server id is whoever holds it NOW: the tablet drew this row when the
    -- last push went out, and between that draw and the click the owner can
    -- have disconnected and somebody else arrived on their number.
    -- ReturnLeftovers works the citizen id out from the LIVE player, so the
    -- click ran a leftovers return for the newcomer, left the row's real
    -- stash untouched, queued nothing, and said nothing. Nobody's property
    -- went anywhere it should not -- and nobody's came back either.
    if target and target > 0 and holderIs(target, citizenid) then
        local ok, returned = ArenaAmmo.ReturnLeftovers(target)
        ArenaLog('%s handed %s %d item(s) back from the admin tablet (%s)',
            ArenaPlayerName(src), ArenaPlayerName(target), returned or 0,
            ok and 'complete' or 'still outstanding')

        if ok then return pushAdmin(src, keyArg(payload.matchId)) end
    end

    -- AND EVERY OTHER WAY THAT CAN GO, INCLUDING THE HAND-BACK THAT DID NOT
    -- GO THROUGH, ENDS UP ON THE LIST.
    --
    -- ReturnLeftovers answers false for a fighter who is mid-round, for a
    -- stopped ox_inventory, for a stash it could not open -- none of which
    -- are the admin's mistake and none of which used to leave a trace. The
    -- button reported nothing, queued nothing, and the sweep only ever
    -- retries the people already on its list, so a stash found by name after
    -- a restart stayed on nobody's. Queuing is what puts it back on one.
    --
    -- A HAND-BACK THAT DID NOT GO THROUGH MUST NOT END UP ON NOBODY'S LIST.
    -- DO NOT tidy this fall-through back into an early return.
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

    ArenaLobby.Broadcast()

    pushAdmin(src, keyArg(payload.matchId))
end)

onClient('crimson_arena:server:adminRevive', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    local target = payload and intArg(payload.target)
    if not target or target <= 0 then return refuse(src, 'error.invalid_request') end

    local match = ArenaLobby.GetByPlayer(target)
    if not match then
        -- THE SAME REDRAW THE STOP BUTTON TAKES, and for the same reason: a
        -- fighter who left, was eliminated out of the roster, or whose match
        -- ended is one this screen is still showing as revivable, under a
        -- button that cannot do anything. A refusal here must not only say
        -- no, it must put the screen right.
        pushAdmin(src, nil)
        return refuse(src, 'error.not_in_match')
    end

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

    if action == 'tablet' then
        if src == 0 then return tell(src, locale('cmd.usage')) end
        -- EVERY FIELD THE SCREEN READS, not the eight this used to send.
        -- The panel's two reducers are the same reducer: `adminOpen` reads
        -- twelve keys and this sent eight, so the three the stash tab needs
        -- -- databaseOn, owedKit, owedKitSaved -- arrived absent and were
        -- read as "no database, nothing out". An absent field is not an
        -- empty one, and the first draw is the one an operator opened the
        -- tablet to look at. DO NOT let the two lists drift apart again.
        TriggerClientEvent('crimson_arena:client:openAdmin', src, {
            matches = adminMatches(),
            owed = {},
            owedKit = withHolders(ArenaAmmo.OwedKit()),
            owedKitSaved = ArenaAmmo.OwedKitIsSaved(),
            databaseOn = Config.Database.enabled == true,
            stashesFound = 0,
            stashesRead = 0,
            stashesReadable = stashesReadable(),
            hoursOpen = ArenaHoursOpen(),
            hoursForced = ArenaHoursOverride(),
            hoursLine = Arena.ScheduleLine(),
            hoursOpensAt = ArenaHoursSnapshot().opensAt,
        })

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
