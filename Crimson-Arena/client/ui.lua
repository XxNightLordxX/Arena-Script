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

    local token = closeToken
    local state = lib.callback.await('crimson_arena:server:getState', false)

    isOpening = false
    if token ~= closeToken then return end
    if not state then
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

RegisterNetEvent('crimson_arena:client:matchHud', function(data)
    ArenaUI.UpdateHud(data)
end)

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
