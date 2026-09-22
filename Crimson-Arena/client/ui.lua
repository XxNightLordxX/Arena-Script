-- Crimson Arena: the wire between the panel and the server.

ArenaUI = {}

local isOpen = false

local isOpening = false

local closeToken = 0

function ArenaUI.Send(action, data)
    SendNUIMessage({ action = action, data = data or {} })
end

function ArenaUI.IsOpen()
    return isOpen
end

function ArenaUI.SendState(state)
    if not state then return end
    ArenaUI.Send('state', state)
end

--- Player-visible message. It goes to the panel when the panel is up, and
--- to ox_lib otherwise -- a notification about a match the player is
--- fighting in must not be swallowed just because they closed the menu.
--- @param description string
--- @param notifyType string? 'info'|'success'|'warning'|'error'
--- @param toast boolean? force ox_lib even while the panel is open
function ArenaUI.Notify(description, notifyType, toast)
    if type(description) ~= 'string' or description == '' then return end
    -- FORCED PAST THE PANEL when the caller asks. A message sent in the same
    -- tick the panel is closed CANNOT be delivered into the panel -- see
    -- ArenaToast in server/util.lua for the case this exists for.
    if isOpen and not toast then
        ArenaUI.Send('notify', { message = description, type = notifyType or 'info' })
    else
        local level = notifyType or 'info'
        lib.notify({
            title = Config.NotifyTitle,
            description = description,
            type = level == 'info' and 'inform' or level,
        })
    end
end

local adminOpen = false

local closeAdmin

function ArenaUI.Open()
    if isOpen or isOpening then return end

    isOpening = true

    -- pcall BECAUSE A RAISE HERE USED TO COST THE PANEL FOR THE WHOLE SESSION.
    --
    -- `isOpening` is the guard that stops two opens racing, and it was cleared
    -- on the line AFTER the await. lib.callback.await reaches ox_lib and the
    -- server: it raises if the callback is not registered, if the server
    -- handler errors, and on the timeout paths of some ox_lib builds. Any of
    -- those unwound this function with the flag still TRUE -- and every later
    -- Open() then hit `if isOpen or isOpening then return end` and returned
    -- immediately. No error, no notify, nothing on any screen: the arena menu
    -- was simply dead until the player reconnected.
    --
    -- MEASURED: one raise, then a perfectly healthy await, and the panel never
    -- opens again. So the flag is cleared on every path out, and a raise is
    -- reported to the player as what it is -- the state could not be fetched
    -- -- rather than swallowed.
    local token = closeToken
    local fetched, state = pcall(lib.callback.await, 'crimson_arena:server:getState', false)

    isOpening = false
    if token ~= closeToken then return end
    if not fetched or not state then
        ArenaUI.Notify(locale('error.state_unavailable'), 'error')
        return
    end

    closeAdmin()

    isOpen = true
    ArenaUI.Send('open', state)
    SetNuiFocus(true, true)
end

closeAdmin = function()
    if not adminOpen then return end
    adminOpen = false
    ArenaUI.Send('adminClose')
end

local function openAdmin(payload)
    ArenaUI.Close()

    adminOpen = true
    ArenaUI.Send('adminOpen', payload)
    SetNuiFocus(true, true)
end

RegisterNetEvent('crimson_arena:client:openAdmin', function(payload)
    openAdmin(type(payload) == 'table' and payload or { matches = {} })
end)

RegisterNetEvent('crimson_arena:client:adminState', function(payload)
    if not adminOpen then return end
    ArenaUI.Send('adminState', type(payload) == 'table' and payload or {})
end)

--- One admin report, on its way to the Tools tab.
---
--- GUARDED ON adminOpen like the state push above, and for the same reason:
--- a report arriving after the operator shut the tablet has no screen to
--- draw on, and sending it anyway asks the panel to render into nothing.
RegisterNetEvent('crimson_arena:client:adminTool', function(payload)
    if not adminOpen then return end
    ArenaUI.Send('adminTool', type(payload) == 'table' and payload or {})
end)

--- Safe to call when already closed; the release is unconditional because
--- releasing focus we do not hold costs nothing and failing to release
--- focus we do hold costs the player their character.
function ArenaUI.Close()
    closeAdmin()

    local wasOpen = isOpen

    isOpen = false
    closeToken = closeToken + 1
    ArenaUI.Send('close')
    SetNuiFocus(false, false)

    if wasOpen then
        TriggerServerEvent('crimson_arena:server:panelClosed')
    end
end

function ArenaUI.UpdateHud(data)
    if not Config.UI.showMatchHud then return end

    -- `visible = true` IS THE DEFAULT ON PURPOSE, and it is this function's
    -- asserted contract: "a hud update is a visible hud", pinned by two tests
    -- in tests/nuicallback_spec.lua. It was briefly removed here on the
    -- reasoning that all three callers pass `visible` explicitly and the
    -- default was therefore dead -- which was wrong twice over. It is not
    -- dead, it is the contract; and those two tests caught the removal.
    --
    -- What the default does NOT excuse is going unchecked. A caller's own
    -- value has to survive it, or restoring the unconditional bolt-on that
    -- the note at the bottom of this file is about would go unnoticed.
    -- tests/hudscope_spec.lua drives the exit path, which asks for the HUD to
    -- be HIDDEN, and fails if it comes back visible.
    local payload = { visible = true }
    for key, value in pairs(data or {}) do
        payload[key] = value
    end
    ArenaUI.Send('hud', payload)
end

function ArenaUI.Countdown(seconds, label)
    ArenaUI.Send('countdown', { seconds = seconds, label = label })
end

function ArenaUI.Results(results)
    if type(results) ~= 'table' then return end
    ArenaUI.Send('results', { results = results })
end

local function register(name, handler)
    RegisterNUICallback(name, function(data, cb)
        if type(data) ~= 'table' then data = {} end

        local ok, err = pcall(handler, data)
        if not ok then
            print(('[crimson_arena] NUI callback "%s" errored: %s'):format(name, err))
        end

        cb('ok')
    end)
end

register('close', function()
    ArenaUI.Close()
end)

register('refresh', function()
    -- `panel = true`: this ask really is the panel, so being counted as
    -- watching is correct. client/spectate.lua asks for the same snapshot
    -- with the panel shut and deliberately does not say this.
    TriggerServerEvent('crimson_arena:server:requestState', { panel = true })
end)

register('createMatch', function(data)
    TriggerServerEvent('crimson_arena:server:createMatch', {
        arenaKey = data.arenaKey,
        modeKey = data.modeKey,
        entryFee = data.entryFee,
        lives = data.lives,
        roundTimeSeconds = data.roundTimeSeconds,
        winCondition = data.winCondition,
        scoreLimit = data.scoreLimit,
        tierPlan = data.tierPlan,
        radar = data.radar,
        account = data.account,
    })
end)

--- The host editing a lobby they have already opened.
---
--- THIS WAS MISSING ENTIRELY. The panel posts `updateMatch`, the server
--- listens for `crimson_arena:server:updateMatch`, and nothing on the client
--- joined them up -- so "Apply changes" reached a callback that did not
--- exist. A fetch to an unregistered NUI callback does not throw and does not
--- warn; `register` answers every call it receives, but it never received
--- this one, so the panel got its answer from the runtime and carried on as
--- though the edit had been applied.
---
--- No entryFee: the fee is frozen once a lobby is open, and the panel
--- deliberately does not send one rather than sending a value the server
--- would refuse.
register('updateMatch', function(data)
    TriggerServerEvent('crimson_arena:server:updateMatch', {
        arenaKey = data.arenaKey,
        modeKey = data.modeKey,
        lives = data.lives,
        roundTimeSeconds = data.roundTimeSeconds,
        winCondition = data.winCondition,
        scoreLimit = data.scoreLimit,
        tierPlan = data.tierPlan,
        radar = data.radar,
    })
end)

register('joinMatch', function(data)
    TriggerServerEvent('crimson_arena:server:joinMatch', {
        matchId = data.matchId,
        teamKey = data.teamKey,
        account = data.account,
    })
end)

register('leaveMatch', function()
    TriggerServerEvent('crimson_arena:server:leaveMatch')
end)

register('setTeam', function(data)
    TriggerServerEvent('crimson_arena:server:setTeam', { teamKey = data.teamKey })
end)

register('setLoadout', function(data)
    TriggerServerEvent('crimson_arena:server:setLoadout', {
        weapons = data.weapons,
        supplies = data.supplies,
    })
end)

register('setReady', function(data)
    TriggerServerEvent('crimson_arena:server:setReady', { ready = data.ready and true or false })
end)

register('startMatch', function()
    TriggerServerEvent('crimson_arena:server:startMatch')
end)

register('cancelMatch', function()
    TriggerServerEvent('crimson_arena:server:cancelMatch')
end)

register('holdCountdown', function()
    TriggerServerEvent('crimson_arena:server:holdCountdown')
end)

--- THE RADAR IS NOT RELAYED FROM HERE ANY MORE, on purpose.
---
--- There was a `setRadar` callback in this spot: the panel's own toggle,
--- answered on this side and never put on the wire, because a display
--- setting on one player's map is nothing the server has an opinion about.
---
--- The setting is the host's now, so it travels the way every other match
--- rule travels -- `createMatch` and `updateMatch` above carry it up, and
--- `enterArena` carries it back down to ArenaMatch.SetRadar. A player with
--- no match has no radar to set, which is why nothing here answers for one.

register('spectate', function(data)
    TriggerServerEvent('crimson_arena:server:spectateMatch', { matchId = data.matchId })
end)

register('stopSpectate', function()
    TriggerServerEvent('crimson_arena:server:stopSpectating')
end)

register('spectatorBet', function(data)
    TriggerServerEvent('crimson_arena:server:placeSpectatorBet', {
        matchId = data.matchId,
        pick = data.pick,
        amount = data.amount,
        account = data.account,
    })
end)

register('adminClose', function()
    -- THROUGH closeAdmin, so the screen is shut in one place. The release is
    -- unconditional and outside it: letting go of focus we do not hold costs
    -- nothing, and failing to let go of focus we DO hold costs the player
    -- their character.
    closeAdmin()
    SetNuiFocus(false, false)
end)

register('adminState', function(data)
    TriggerServerEvent('crimson_arena:server:adminState', { matchId = data.matchId })
end)

register('adminTool', function(data)
    TriggerServerEvent('crimson_arena:server:adminTool', {
        tool = data.tool,
        -- ONLY THE MEDICAL TEST READS THIS, and the server decides that, not
        -- the page: a target sent alongside a report that does not want one
        -- is handed to nothing. Passed through as it arrives so the two ends
        -- cannot disagree about what an empty box means -- the server reads a
        -- missing or unusable id as "the person who pressed it".
        target = data.target,
    })
end)

register('adminStop', function(data)
    TriggerServerEvent('crimson_arena:server:adminStop', { matchId = data.matchId })
end)

register('adminRevive', function(data)
    TriggerServerEvent('crimson_arena:server:adminRevive', { target = data.target })
end)

register('adminHours', function(data)
    TriggerServerEvent('crimson_arena:server:adminHours', {
        -- Passed through as it arrives rather than narrowed here: the
        -- server reads exactly two words and treats everything else as
        -- "follow the schedule", so narrowing it twice would only give the
        -- two ends a chance to disagree about what a third value means.
        forced = data.forced,
        matchId = data.matchId,
    })
end)

register('adminWipe', function(data)
    TriggerServerEvent('crimson_arena:server:adminWipe', {
        -- COERCED HERE, as adminUnjam's is: the page sends this only on the
        -- press that follows the warning, and a nil arriving as anything but
        -- false would be a confirmation nobody gave.
        confirm = data.confirm == true,
    })
end)

register('adminUnjam', function(data)
    TriggerServerEvent('crimson_arena:server:adminUnjam', {
        stash = data.stash,
        -- COERCED HERE, as setReady's is. The page sends this only on a
        -- deliberate second press, and a `nil` arriving as anything but false
        -- would be an operator's confirmation nobody gave.
        force = data.force == true,
        matchId = data.matchId,
    })
end)

register('adminReturn', function(data)
    TriggerServerEvent('crimson_arena:server:adminReturn', {
        target = data.target,
        citizenid = data.citizenid,
        stash = data.stash,
        matchId = data.matchId,
    })
end)

RegisterNetEvent('crimson_arena:client:state', function(state)
    ArenaUI.SendState(state)
end)

RegisterNetEvent('crimson_arena:client:notify', function(data)
    if type(data) ~= 'table' then return end
    ArenaUI.Notify(data.description, data.type, data.toast == true)
end)

RegisterNetEvent('crimson_arena:client:closePanel', function()
    ArenaUI.Close()
end)

-- THERE IS NO matchHud HANDLER HERE, AND THAT IS THE POINT.
--
-- There was one, and it read `ArenaUI.UpdateHud(data)` -- three words that
-- quietly undid a guard in another file for as long as both existed.
--
-- client/match.lua registers its OWN handler for this event and refuses a
-- board belonging to somebody else's round. FiveM runs every handler
-- registered for an event, in registration order, and fxmanifest.lua loads
-- this file BEFORE client/match.lua -- so the handler here ran first, sent
-- the foreign board straight to the panel with `visible = true` bolted on by
-- UpdateHud, and then match.lua's guard returned early and sent nothing.
-- Returning early cannot take back a message already posted. The refusal
-- looked right in the file, was covered by a passing test, and did nothing:
-- a fighter in one match saw another match's scoreboard, and the panel was
-- forced open to show it.
--
-- ArenaUI.UpdateHud is still the only way the board reaches the panel.
-- client/match.lua calls it directly, AFTER the guard and after
-- refreshTeamMarks, with the visibility it actually worked out rather than
-- the unconditional `true` this handler supplied.
--
-- DO NOT REGISTER A HANDLER FOR crimson_arena:client:matchHud IN THIS FILE.
-- tests/hudscope_spec.lua loads this file and client/match.lua together --
-- which is the only way to see the pair of them -- and fails if a second
-- handler comes back.

RegisterNetEvent('crimson_arena:client:countdown', function(data)
    if type(data) ~= 'table' then return end
    ArenaUI.Countdown(data.seconds, data.label)
end)

RegisterNetEvent('crimson_arena:client:results', function(data)
    if type(data) ~= 'table' then return end
    ArenaUI.Results(type(data.results) == 'table' and data.results or data)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
