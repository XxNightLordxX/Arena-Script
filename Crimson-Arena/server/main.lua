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
    -- CLIENT DEBUG LINES. Tight, because this event exists for a switch
    -- that is off on a finished server and the handler prints to the one
    -- console every admin reads. A client that floods it gets one line a
    -- second and nothing else.
    clientDebug = 1000,
}

--- The longest client debug line the server will print.
--- Not a formatting choice: this string arrives from a client, and a
--- megabyte of it would be a megabyte in the console log on disk.
local MAX_DEBUG_LINE = 300

--- A client-supplied string, cut to length and made safe to put in the
--- server console.
---
--- ONE COPY, BECAUSE THERE WERE TWO HANDLERS AND ONLY ONE OF THEM DID IT.
--- `clientDebug` stripped every control character and explained at length
--- why; `outlineReason`, in the same file, cut its string to 200 characters
--- and passed it to ArenaDebug untouched. Both take an arbitrary string from
--- any connected client. So the rule lived in a comment next to one of its
--- two call sites, which is how it came to be missing from the other.
---
--- WHAT THE MISSING HALF ALLOWED. A client-supplied '\n' lets anybody write
--- a line into the console log that does not carry the attribution prefix --
--- a forged '[crimson_arena] ...' line sitting among the real ones, which is
--- an operator reading something a player wrote and believing the server
--- said it. An ESC is worse: a console that reads ANSI takes '\27[2J' as
--- "clear the screen" and '\27]0;' as "rename the window", so one diagnostic
--- line could wipe the output an operator was working through. Neither
--- belongs in a diagnostic message, so the whole 0x00-0x1F range and DEL go.
---
--- CUT FIRST, THEN STRIP, so the cap still bounds the work the gsub does.
--- @param text any
--- @param cap integer|nil -- defaults to MAX_DEBUG_LINE
--- @return string
local function scrubbedForLog(text, cap)
    if type(text) ~= 'string' then return '' end

    local limit = Arena.ToInt(cap) or MAX_DEBUG_LINE
    if limit < 1 then limit = MAX_DEBUG_LINE end

    local out = text
    if #out > limit then out = out:sub(1, limit) .. ' [cut]' end

    return (out:gsub('[%z\1-\31\127]', ' '))
end

local adminScan = {}

local adminTicket = 0

local MAX_KEY_LENGTH = 64

local MAX_WEAPON_ENTRIES = 32

--- The most attachment kinds one weapon may be asked for.
---
--- There are seven kinds in total, so this is already generous. It exists
--- because the list arrives from a client and every list that does needs an
--- end: without it, one weapon entry could carry a million strings and this
--- function would dutifully copy all of them.
local MAX_ATTACHMENT_ENTRIES = 8

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
                -- ATTACHMENTS, REBUILT KEY BY KEY LIKE EVERYTHING ELSE HERE.
                --
                -- ABSENT AND EMPTY ARE DIFFERENT ANSWERS and both have to
                -- survive: nil means "fit what this server fits by default",
                -- which is what an untouched pick and every loadout saved
                -- before attachments existed should get; an empty list means
                -- a player deliberately took everything off. Rebuilding into
                -- a fresh table only when one was actually sent is what keeps
                -- those two apart.
                --
                -- WHAT ARRIVES IS KIND KEYS -- 'scope', 'grip' -- never
                -- component names, and Arena.AttachmentsFor will only ever
                -- look them up in the operator's own table. A key that names
                -- nothing resolves to nothing rather than being handed on.
                local fitted = nil
                local asked = tableArg(entry.attachments)
                if asked then
                    fitted = {}
                    for slot = 1, MAX_ATTACHMENT_ENTRIES do
                        local kind = keyArg(asked[slot])
                        if kind == nil then break end
                        fitted[#fitted + 1] = kind
                    end
                end

                weapons[#weapons + 1] = {
                    key = key,
                    ammo = intArg(entry.ammo),
                    ammoType = keyArg(entry.ammoType),
                    attachments = fitted,
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

    ArenaDebug('outline: %s reports -- %s', tostring(src), scrubbedForLog(reason, 200))
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

    -- AND THE JAM LIST, AT THE SAME MOMENT AND FOR THE SAME REASON.
    --
    -- It was reachable only from ArenaAmmo.SweepReturns, which is the thirty-
    -- second retry and not a start-up call at all -- so the read began up to
    -- thirty seconds late, and on a server with returnRetrySeconds = 0 the
    -- sweep never runs, so nothing ever dispatched it. The door holds every
    -- hand-back until this lands and then gives up after a minute blaming a
    -- missing SELECT grant, which on those servers was a lie: nobody had
    -- asked the database anything.
    ArenaAmmo.LoadJams()

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

--- Everything /arenahours reports, as a list of ready-to-show lines.
---
--- SPLIT OUT OF THE COMMAND so the admin tablet can show the same reading.
--- The command below builds nothing of its own any more, which is the only
--- way the console and the screen are guaranteed to agree.
--- @return string[]
local function hoursReport()
    local lines = {}
    local function say(fmt, ...)
        local ok, text = pcall(string.format, fmt, ...)
        lines[#lines + 1] = ok and text or fmt
    end

    local hours = ArenaHoursState()
    say('arena hours: %s', hours.enabled and 'ON' or 'OFF')
    say('  this machine says: %s', hours.serverClock)
    say('  offsetHours:       %+d', hours.offsetHours)
    say('  arena is going by: %s', hours.arenaClock)
    say('  windows:           %s', hours.line or '(none -- open at every hour)')

    if hours.forced then
        say('  OVERRIDDEN:        an admin has the doors %s.',
            hours.forced == 'open' and 'HELD OPEN past the schedule'
                or 'CLOSED inside the schedule')
    end

    -- NAMED ONLY WHEN THERE IS ONE. `closesAt` is set only while the
    -- SCHEDULE says open and `opensAt` only while it says shut, so an
    -- override that disagrees with the clock leaves the matching one absent
    -- -- and this line used to print the word `nil` at an operator trying to
    -- work out what was wrong.
    local when = hours.open and hours.snapshot.closesAt or hours.snapshot.opensAt
    say('  right now:         %s%s',
        hours.open and 'OPEN' or 'SHUT',
        type(when) == 'string' and (hours.open and (', until ' .. when)
            or (', opens at ' .. when)) or '')

    if hours.line then
        say('  if "this machine says" is not your local time, put the difference in '
            .. 'Config.Schedule.offsetHours.')
    end

    return lines
end

-- `/arenahours` USED TO BE REGISTERED HERE and is not a command any more.
-- The reading is hoursReport above, which the admin tablet draws under Tools
-- and `/arenaconsole` prints at a console -- the same lines from the same
-- function, through the one command this resource still registers.

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
--- Whether the jam list has been read back, so the marks on the stash rows
--- can be believed.
---
--- GUARDED, because ArenaAmmo is a table other things mock. The harnesses and
--- the spec fixtures build the smallest ammo surface their test needs, and a
--- bare call here took the WHOLE admin screen down on any of them -- the
--- payload is built in one expression, so one missing function is a blank
--- tablet rather than a missing line. Absent reads as "not read yet", which
--- is the cautious end: the screen then declines to promise a hand-back
--- rather than promising one it cannot keep.
local function jamsKnown()
    if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.JammedStashes) ~= 'function' then
        return false
    end
    local asked, _, known = pcall(ArenaAmmo.JammedStashes)
    return asked and known == true
end

--- Whether ONE stash is being held back. Guarded for the same reason
--- jamsKnown is, and falls the same way: a surface that cannot answer is
--- treated as "not held back", so an older harness keeps the behaviour it
--- had rather than losing the hand-back button altogether.
local function stashHeldBack(stash)
    if not stash then return false end
    if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.IsJammed) ~= 'function' then
        return false
    end
    local asked, jammed = pcall(ArenaAmmo.IsJammed, stash)
    return asked and jammed == true
end

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
            -- THE MONEY SLATE'S ANSWER IS NOT SENT HERE, AND THAT IS
            -- DELIBERATE. It was, and nothing on the panel ever read it: the
            -- durability of the unpaid slate is already spelled out, in
            -- OwedReport's own words, on the Money owed report this same
            -- tablet opens. A second copy on another screen would be a second
            -- place for that answer to be worded -- and to go stale -- for no
            -- reading an operator cannot already get. ArenaBetting.UnpaidIsSaved
            -- is the gate; the report asks it. DO NOT add it back here without
            -- a screen that actually draws it.
            databaseOn = Config.Database.enabled == true,
            stashesFound = total,
            stashesRead = read,
            stashesReadable = stashesReadable(),
            -- WHETHER THE HELD-BACK MARKS ON THOSE ROWS MEAN ANYTHING YET.
            --
            -- Until the jam list is read back from the database every stash
            -- answers "not held back", so an unqualified screen would draw a
            -- hand-back button on the one stash the door is certain to
            -- refuse. Sent as the state of the READ, never inferred from an
            -- empty list -- the same rule the stash counts and the owed-kit
            -- line already follow.
            jamsKnown = jamsKnown(),
        })
    end, function(found, opened) total, read = found, opened end)
end

--- A debug line from a client, printed in the SERVER console.
---
--- WHY THE CLIENT DOES NOT JUST PRINT IT. The operator's words: the arena's
--- debug output belongs "into the live console instead of the f8". An F8
--- console is one player's, is cleared by a relog, and cannot be read by the
--- person actually diagnosing the server -- so a debug switch that writes
--- there tells the one person who cannot act on it.
---
--- EVERY LINE IS ATTRIBUTED AND EVERY LINE IS UNTRUSTED. The text comes from
--- a client, so it is cut to MAX_DEBUG_LINE, stripped of everything that is
--- not printable, and written under the sender's name and id. It decides
--- nothing and is stored nowhere.
---
--- THE SWITCH IS ENFORCED BY ArenaDebug, which is the only thing here that
--- prints -- so a client with the file edited cannot turn on output a server
--- has switched off, whatever it sends. The early return below is not that
--- guard and is not load-bearing: it only saves the name lookup and the
--- string work on a server that is not going to print the result anyway.
onClient('crimson_arena:server:clientDebug', RATE.clientDebug, function(src, data)
    if Config.Debug ~= true then return end

    local payload = tableArg(data)
    local line = payload and payload.line
    if type(line) ~= 'string' or line == '' then return end

    -- CUT AND STRIPPED IN ONE PLACE. This handler is where the rule was
    -- written down; see scrubbedForLog for why it is no longer written down
    -- HERE, and what its absence from the other handler allowed.
    line = scrubbedForLog(line, MAX_DEBUG_LINE)

    ArenaDebug('client %s (%s): %s', tostring(src), ArenaPlayerName(src), line)
end)

--- The admin tools the tablet can run, and what each one answers with.
---
--- THE ASK THIS ANSWERS, in the operator's words: put the admin commands
--- "in there instead of typing stuff out". Each entry is the SAME report the
--- console command prints, built by the same function -- not a second copy
--- that can drift from it.
---
--- READ-ONLY, EVERY ONE. Nothing here changes anything: the tablet already
--- has buttons for the actions that change something (stop a match, revive,
--- hand a stash back, hold the doors), each with the guard that action
--- needs. /arenaunjam in particular is NOT offered as a button and
--- ArenaAmmo.JamReport says why at length.
local ADMIN_TOOLS = {
    isolation = {
        title = 'Instancing',
        run = function()
            if type(ArenaDispatch) ~= 'table' or type(ArenaDispatch.IsolationReport) ~= 'function' then
                return { 'this build has no isolation report.' }
            end
            return ArenaDispatch.IsolationReport()
        end,
    },
    hours = {
        title = 'Opening hours',
        run = function() return hoursReport() end,
    },
    dispatch = {
        title = 'Police & EMS',
        run = function()
            if type(ArenaDispatch) ~= 'table' or type(ArenaDispatch.CompatReport) ~= 'function' then
                return { 'this build has no dispatch compat report.' }
            end
            return ArenaDispatch.CompatReport()
        end,
    },
    owed = {
        title = 'Money owed',
        run = function()
            if type(ArenaBetting) ~= 'table' or type(ArenaBetting.OwedReport) ~= 'function' then
                return { 'this build has no owed-money report.' }
            end
            return ArenaBetting.OwedReport()
        end,
    },
    attachments = {
        title = 'Attachments',
        run = function()
            if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.AttachmentReport) ~= 'function' then
                return { 'this build has no attachment report.' }
            end
            return ArenaAmmo.AttachmentReport()
        end,
    },
    jams = {
        title = 'Held-back stashes',
        run = function()
            if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.JamReport) ~= 'function' then
                return { 'this build has no jam report.' }
            end
            return ArenaAmmo.JamReport()
        end,
    },
    -- THE ONE TOOL THAT ACTS RATHER THAN READS, and the one that needs to be
    -- told WHO. Every report above is a look at the server; this runs the
    -- end-of-match revive against a named player so an operator can watch
    -- their medical script answer it, which is the whole reason it exists and
    -- cannot be done by describing it.
    --
    -- DELIBERATELY REACHES SOMEBODY WHO IS NOT IN A MATCH. The tablet's own
    -- revive button refuses anyone outside the round being looked at, and
    -- that refusal is right for what THAT button is for. This is the other
    -- job -- wiring up a medical script without first putting somebody
    -- through a round -- and the two do not stand in for each other.
    medical = {
        title = 'Medical test',
        wants = 'target',
        run = function(target)
            if type(ArenaDispatch) ~= 'table' or type(ArenaDispatch.ReviveReport) ~= 'function' then
                return { 'this build has no medical test.' }
            end
            return ArenaDispatch.ReviveReport(target)
        end,
    },
}

onClient('crimson_arena:server:adminTool', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    local name = payload and keyArg(payload.tool)
    local tool = name and ADMIN_TOOLS[name]
    if not tool then return refuse(src, 'error.invalid_request') end

    -- THE TARGET IS READ ONLY WHERE THE TOOL ASKS FOR ONE, and defaults to
    -- the person pressing.
    --
    -- DEFENSIVE, NOT LOAD-BEARING, and worth saying so rather than letting a
    -- future reader assume a test holds it. Every other report takes no
    -- argument and would ignore one, so deleting this check changes nothing
    -- observable today -- it is here for the next tool that takes a target,
    -- which must not be handed a stale id left in the box by this one.
    local target = nil
    if tool.wants == 'target' then
        target = intArg(payload.target)
        if not target or target <= 0 then target = src end
    end

    -- THROUGH pcall. These reports read live server state -- routing
    -- buckets, the clock, ox_inventory -- and one of them throwing must not
    -- take the tablet down with it. An operator looking at a broken server
    -- is exactly who is pressing this.
    local ok, lines = pcall(tool.run, target)
    if not ok or type(lines) ~= 'table' then
        lines = { 'that report could not be taken: ' .. tostring(lines) }
    end

    local out = {}
    for _, line in ipairs(lines) do out[#out + 1] = tostring(line) end

    TriggerClientEvent('crimson_arena:client:adminTool', src, {
        tool = name,
        title = tool.title,
        lines = out,
    })

    ArenaLog('%s ran the %s report from the admin tablet', ArenaPlayerName(src), name)
end)

onClient('crimson_arena:server:adminState', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end
    local payload = tableArg(data) or {}
    pushAdmin(src, keyArg(payload.matchId))
end)

--- Stops every match there is, and says how many that was.
---
--- ONE BODY FOR BOTH DOORS. The tablet's Stop every match button and its
--- own button are the same action, and written twice they would be two
--- places to keep a refund rule in step. See the tablet handler below for why
--- the CONFIRMATION is not in here: this function does the thing, and asking
--- belongs to whichever door is being knocked on.
--- @return integer wiped
local function wipeEveryMatch()
    local wiped = 0
    for _, match in ipairs(ArenaLobby.All()) do
        ArenaMatch.Abort(match.id, 'notify.match_stopped_by_admin')
        wiped = wiped + 1
    end
    return wiped
end

--- Wipes every match from the tablet.
---
--- THE MOST DESTRUCTIVE THING ON THIS SCREEN, and the only one that acts on
--- rounds the operator is not looking at. Stop takes the match they opened;
--- this takes every match on the server, including ones that started thirty
--- seconds ago with a full pot, and everybody in them is thrown out. Nobody
--- loses money -- Abort refunds every stake and entry fee, which is the whole
--- reason this is safe to offer at all -- but they lose the round they were
--- fighting, and there is no undo.
---
--- SO IT ASKS TWICE, AND THE SERVER IS WHERE THE SECOND ONE IS ENFORCED. The
--- panel arms the button and sends `confirm` only on the press that follows
--- the warning, exactly as Clear the hold does; refusing an unconfirmed one
--- HERE rather than trusting the page means a mis-click cannot be turned into
--- a wipe by a crafted request either. That is the whole of the difference
--- between this and a button that fires on one press.
onClient('crimson_arena:server:adminWipe', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data) or {}
    if payload.confirm ~= true then return refuse(src, 'error.confirm_wipe') end

    local wiped = wipeEveryMatch()
    ArenaLog('%s wiped %d match(es) from the admin tablet', ArenaPlayerName(src), wiped)

    -- AND THE SCREEN IS REDRAWN ON AN EMPTY WIPE TOO. Zero matches is a real
    -- answer -- the last one can have ended while the tablet was open -- and
    -- an operator who pressed a destructive button and saw nothing change
    -- presses it again.
    pushAdmin(src, nil)
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

    -- A STASH THE DOOR IS HOLDING BACK IS NOT HANDED BACK BY THIS BUTTON,
    -- AND THE ADMIN IS TOLD WHY RATHER THAN TOLD NOTHING.
    --
    -- Both ways out of this handler were wrong on a jammed stash. Offline,
    -- QueueReturn took it happily and the screen said the belongings were
    -- queued and would go back the next time that character was seen -- a
    -- promise the exit refuses every single time, for as long as the jam
    -- stands, which is for ever without a human. Online was worse and
    -- quieter: ReturnLeftovers works the stash name out for ITSELF, and
    -- stashFor skips a jammed name, so the hand-back emptied the NEXT stash
    -- along and reported "complete" while the row the operator actually
    -- pressed sat untouched.
    --
    -- The hold is cleared on the stash screen, by somebody who has read the
    -- contents -- see adminUnjam below. This refusal is what sends them
    -- there.
    if stashHeldBack(stash) then
        ArenaLog('%s pressed hand-back on %s, which is HELD BACK. Nothing was moved. The hold '
            .. 'has to be cleared on the stash screen first, by somebody who has compared what '
            .. 'is in it against what that character is carrying.',
            ArenaPlayerName(src), stash)
        return refuse(src, 'error.stash_held_back')
    end

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
        -- AND WHY, WHEN IT IS NOT COMPLETE.
        --
        -- This said "handed 0 item(s) back (still outstanding)" and stopped
        -- there, which reads exactly like a stash that has lost its contents.
        -- The commonest reason by far is the least alarming one -- the player
        -- is standing in a live round, and emptying their belongings into
        -- them there would hand them their own kit to fight with -- and an
        -- operator could not tell that from a real failure. One of them is
        -- the door working; the other is somebody's property missing.
        local ok, returned, _, why = ArenaAmmo.ReturnLeftovers(target)
        ArenaLog('%s handed %s %d item(s) back from the admin tablet (%s)',
            ArenaPlayerName(src), ArenaPlayerName(target), returned or 0,
            ok and 'complete'
                or ('still outstanding -- ' .. (why or 'reason not given')
                    .. '. It has been queued and goes back the next time they are seen.'))

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

--- Clears the door's hold on one stash, from the tablet.
---
--- WHY THIS IS A BUTTON NOW AND WAS A CONSOLE COMMAND BEFORE. Clearing a
--- hold is not automatic and must never become automatic: whatever is left
--- in a held-back stash goes back inside the next ceiling and the next exit
--- hands it to the owner, so a hold cleared over a stash still holding
--- somebody else's rows is the exact duplication the hold exists to stop.
--- The rule was, and stays, THAT A HUMAN LOOKED AT THE CONTENTS.
---
--- The contents are on the screen this button sits on. An operator opening a
--- stash on the tablet has just read every row in it, item by item -- which
--- is more than `/arenaunjam <name>` in a console ever made anybody do. So
--- the rule is kept and the typing is not. `/arenaunjam` is gone: clearing a
--- hold is this button and only this button, because the rule it enforces --
--- that somebody has LOOKED at the contents first -- is a property of the
--- screen rather than of the command.
---
--- IT IS ITS OWN BUTTON, NOT A HAND-BACK THAT CLEARS THE HOLD ON THE WAY
--- PAST. Two different decisions -- "this stash is settled" and "give these
--- things to this character" -- and rolling them into one press would make
--- the dangerous one a side effect of the ordinary one.
onClient('crimson_arena:server:adminUnjam', RATE.admin, function(src, data)
    if not ArenaIsAdmin(src) then return refuse(src, 'error.no_permission') end

    local payload = tableArg(data)
    if not payload then return refuse(src, 'error.invalid_request') end

    local stash = keyArg(payload.stash)
    if not stash then return refuse(src, 'error.invalid_request') end

    -- THROUGH ArenaAmmo.ClearHold, WHICH IS THE SAME GATE /arenaunjam ASKS,
    -- and deliberately not through Unjam.
    --
    -- Unjam is the mechanism: it clears and asks nothing. Every word of the
    -- judgement -- a stash that still holds rows must not be cleared by
    -- somebody who has not said they looked -- lived inside the console
    -- command, so a button wired to Unjam reached straight past it. One press
    -- on a stash holding forty rows, and the next exit hands the owner a
    -- second copy of everything they are already carrying: the exact
    -- duplication the hold exists to prevent, done by the screen built to
    -- settle it.
    --
    -- NAMED BY THE CLIENT, SO CHECKED HERE. ClearHold answers 'not_held' for
    -- anything that is not on the list, so a stash this arena never held back
    -- cannot be cleared by this button whatever name is sent.
    if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.ClearHold) ~= 'function' then
        return refuse(src, 'error.invalid_request')
    end

    -- THE SECOND PRESS, AND ONLY A SECOND PRESS. `force` is the operator
    -- saying they have read the item list on that screen and the contents are
    -- the owner's -- the tablet's equivalent of typing `force` at a console.
    -- The panel sends it on a deliberate second press and never on the first.
    local cleared, reason, rows = ArenaAmmo.ClearHold(stash, payload.force == true)

    if not cleared then
        -- A REFUSAL, NOT A QUIET SUCCESS, and the push redraws the screen so
        -- the operator sees which of the two it was rather than pressing
        -- again. The commonest by far is the harmless one: somebody else
        -- cleared it a moment ago.
        ArenaLog('%s could not clear the hold on %s -- %s', ArenaPlayerName(src), stash,
            reason == 'not_empty'
                and ('it still ' .. (rows == nil
                    and 'cannot be read, so what is in it is unknown'
                    or ('holds ' .. rows .. ' item(s)'))
                    .. '. Clearing it now would put those back inside the next ceiling and '
                    .. 'the next exit would hand them to the owner.')
                or 'it is not being held back.')

        pushAdmin(src, keyArg(payload.matchId))
        return refuse(src, reason == 'not_empty'
            and 'error.stash_not_empty' or 'error.stash_not_held_back')
    end

    ArenaLog('%s cleared the hold on stash %s from the admin tablet. The door will put '
        .. 'belongings in it and hand them out of it again.', ArenaPlayerName(src), stash)
    ArenaNotifyKey(src, 'notify.stash_unjammed', 'success', stash)

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

    -- A FIGHTER WAITING TO RESPAWN IS NOT DEAD FOR LONG, AND FLIPPING THE
    -- FLAG CANCELLED THE RESPAWN. A death in a live round with lives left
    -- schedules one, and the thread that sends it bails the moment it sees
    -- the row alive -- so a Revive pressed inside that five-second wait
    -- marked the fighter alive with NO respawn ever sent. They stayed on the
    -- floor, held: invincible, at full health, which the dead sweep reads as
    -- a healthy ped, and counted as standing by every winner-selection path.
    -- The round could not end by last man standing while they lay there,
    -- and once the real fighters had knocked each other out the held body
    -- was the last one standing: crowned, and paid. The tablet offers this
    -- press on exactly that fighter, because it marks them Down during the
    -- wait. So the round standing is left alone while a respawn is pending;
    -- the medical revive below still happens, and the respawn arrives on
    -- its own. The flip is kept for the countdown, where nothing is
    -- scheduled and somebody who arrived down is the person an admin is
    -- reaching for -- that is the case the comment above was written for.
    -- DO NOT set alive on a live-round fighter who has lives left.
    local respawning = row ~= nil and not eliminated and match.state == 'live' and row.alive ~= true
    if row and not eliminated and fighting and not respawning then
        row.alive = true
    end

    ArenaDispatch.Revive(target)
    ArenaLog('%s revived %s from the admin tablet%s', ArenaPlayerName(src), ArenaPlayerName(target),
        eliminated and ' -- they are out of the round and stay out' or '')

    if eliminated then
        ArenaNotifyKey(src, 'notify.revived_but_out', 'inform', ArenaPlayerName(target))
    elseif respawning then
        ArenaNotifyKey(src, 'notify.revived_respawning', 'inform', ArenaPlayerName(target))
    end

    pushAdmin(src, match.id)
end)

--- Every debug reading the arena can take, printed to the SERVER CONSOLE.
---
--- THE SECOND AND LAST COMMAND THIS RESOURCE REGISTERS, and the counterpart
--- to /arenaadmin rather than a way back to typing. /arenaadmin puts the
--- screen up and everything on it is a button; this one exists for the place
--- a screen cannot go -- a server console, a log an operator pastes into a
--- support thread, a box nobody can spawn into.
---
--- IT TAKES NO ARGUMENTS EITHER. It prints ALL of them, in one pass, so
--- there is nothing to remember and nothing to spell. The same readings are
--- on the tablet under Tools, one button each, and they are built by the same
--- ADMIN_TOOLS entries -- so a tool added to that screen appears here on the
--- same commit, and one renamed cannot leave this printing a heading with
--- nothing under it.
---
--- THE MEDICAL TEST IS NOT IN IT, and that is deliberate rather than an
--- oversight. Every other entry READS the server; that one REVIVES A PLAYER,
--- and it needs to be told which. A command that dumps everything cannot ask,
--- and quietly reviving whoever typed it -- or nobody, at a console, where
--- there is no such player -- is not a diagnostic. It stays a button, where
--- there is a box to put the server id in.
---
--- ALWAYS TO THE CONSOLE, even when a player runs it. An in-game admin gets
--- one short line saying where it went and that the same readings are on
--- their tablet. The whole report in a corner notification is what this
--- resource already tried once: twenty-odd lines and a pasteable snippet, for
--- a few seconds, which nobody has ever read a resource name out of.
RegisterCommand('arenaconsole', function(src)
    if not ArenaIsAdmin(src) then
        return refuse(src, 'error.no_permission')
    end

    -- IN A FIXED ORDER, not pairs(). ADMIN_TOOLS is a hash, so walking it
    -- directly prints these in a different order every run and makes two logs
    -- from the same server impossible to diff.
    local order = { 'hours', 'dispatch', 'isolation', 'attachments', 'owed', 'jams' }

    local printed = 0
    for _, name in ipairs(order) do
        local tool = ADMIN_TOOLS[name]
        if tool then
            ArenaLog('arenaconsole: ---- %s ----', tool.title or name)

            -- THROUGH pcall, one report at a time. These read live server
            -- state -- routing buckets, the clock, ox_inventory, the database
            -- -- and the operator running this is very often looking at a
            -- server where one of them is broken. One throwing must not take
            -- the other five with it.
            local ok, lines = pcall(tool.run)
            if not ok or type(lines) ~= 'table' then
                ArenaLog('arenaconsole:   that report could not be taken: %s', tostring(lines))
            else
                for _, line in ipairs(lines) do
                    ArenaLog('arenaconsole:   %s', tostring(line))
                end
            end
            printed = printed + 1
        end
    end

    ArenaLog('arenaconsole: %d report(s) above, taken by %s.', printed, ArenaPlayerName(src))

    if src ~= 0 then
        ArenaNotify(src, ('%d report(s) printed to the server console. The same readings are on '
            .. 'your tablet under Tools, where you can scroll them.'):format(printed), 'info')
    end
end, false)

RegisterCommand('arenaadmin', function(src)
    if not ArenaIsAdmin(src) then
        return refuse(src, 'error.no_permission')
    end

    -- IT TAKES NO ARGUMENTS AT ALL, AND THAT IS THE WHOLE DESIGN.
    --
    -- This is the only command this resource registers, and the only thing it
    -- does is put the screen up. Everything an admin can do is a button on
    -- that screen: the reports under Tools, stop and Stop every match on
    -- Matches, hand-backs and Clear the hold on Stashes, the doors, the
    -- revive, the medical test. Nothing is typed, because typing was the part
    -- the owner did not want.
    --
    -- SO THERE ARE NO SUBCOMMANDS, and this is not a list that has been
    -- trimmed and might grow back. A word after the command is IGNORED rather
    -- than refused: there is nothing it could name, so telling somebody their
    -- word was wrong would imply a right one exists. DO NOT add an action
    -- argument here -- the button on the screen is the interface, and a
    -- second way in is a second set of argument handling to keep in step with
    -- it.
    --
    -- THE CONSOLE CANNOT BE SHOWN A TABLET, so it gets the one reading that
    -- needs no client -- what is running right now. Source 0 has no NUI and
    -- never will; this is deliberately the whole of what a console can do,
    -- and an operator who needs more opens the screen in the game.
    if src == 0 then
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
        -- THE MONEY SLATE'S ANSWER IS NOT SENT HERE, AND THAT IS
        -- DELIBERATE. It was, and nothing on the panel ever read it: the
        -- durability of the unpaid slate is already spelled out, in
        -- OwedReport's own words, on the Money owed report this same
        -- tablet opens. A second copy on another screen would be a second
        -- place for that answer to be worded -- and to go stale -- for no
        -- reading an operator cannot already get. ArenaBetting.UnpaidIsSaved
        -- is the gate; the report asks it. DO NOT add it back here without
        -- a screen that actually draws it.
        databaseOn = Config.Database.enabled == true,
        stashesFound = 0,
        stashesRead = 0,
        stashesReadable = stashesReadable(),
        jamsKnown = jamsKnown(),
        hoursOpen = ArenaHoursOpen(),
        hoursForced = ArenaHoursOverride(),
        hoursLine = Arena.ScheduleLine(),
        hoursOpensAt = ArenaHoursSnapshot().opensAt,
    })

    pushAdmin(src, nil)

    ArenaLog('%s opened the admin tablet', ArenaPlayerName(src))
end, false)
