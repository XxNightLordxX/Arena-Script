--[[
    crimson_arena/client/ui.lua

    The NUI bridge, and the ONLY file in this resource that touches NUI
    focus. Everything else asks through ArenaUI.

    WHY ONE FILE OWNS FOCUS: SetNuiFocus is global state with no stack. Two
    files taking and releasing it independently produces a player who cannot
    move because somebody else's release ran first. Keeping every call in
    one place makes that class of bug unwritable.

    WHAT THIS FILE DOES NOT DO: it does not decide anything. NUI callbacks
    forward to the server and nothing else -- a client-side "can I?" check
    here would be a suggestion, not a rule, and the server re-validates
    every one of these payloads anyway.
]]

ArenaUI = {}

--- True between a completed `open` message and the matching `close`.
local isOpen = false

--- Open() yields on a server callback. Without this the player pressing the
--- interaction twice gets two panels open and one stale focus grab.
local isOpening = false

--- Bumped by every Close(). Open() reads it before it yields and abandons
--- the open if it has moved since -- a close that lands while the snapshot
--- is still in flight would otherwise be undone by the open it could not
--- know about, which on the enterArena path leaves the player holding NUI
--- focus in a live round: the exact failure closing on entry exists to stop.
local closeToken = 0

--- Sends the raw `{ action, data }` envelope the panel listens for. Every
--- other Send* helper funnels through here so the shape is defined once.
--- @param action string
--- @param data table?
function ArenaUI.Send(action, data)
    SendNUIMessage({ action = action, data = data or {} })
end

--- @return boolean
function ArenaUI.IsOpen()
    return isOpen
end

--- Pushes a fresh state snapshot into an already-open panel.
--- @param state table
function ArenaUI.SendState(state)
    if not state then return end
    ArenaUI.Send('state', state)
end

--- Player-visible message. It goes to the panel when the panel is up, and
--- to ox_lib otherwise -- a notification about a match the player is
--- fighting in must not be swallowed just because they closed the menu.
--- @param description string
--- @param notifyType string? 'info'|'success'|'warning'|'error'
function ArenaUI.Notify(description, notifyType)
    if type(description) ~= 'string' or description == '' then return end
    if isOpen then
        ArenaUI.Send('notify', { message = description, type = notifyType or 'info' })
    else
        -- ox_lib spells the neutral level 'inform'; the rest of the resource
        -- says 'info'. Translated here rather than at every call site.
        local level = notifyType or 'info'
        lib.notify({
            title = Config.NotifyTitle,
            description = description,
            type = level == 'info' and 'inform' or level,
        })
    end
end

--- Whether the admin tablet is on screen. Declared here rather than beside
--- its own section below because both ArenaUI.Open and ArenaUI.Close have to
--- be able to shut it, and both are defined above that section.
local adminOpen = false

--- Shuts the tablet, if it is up. Assigned further down, next to the rest of
--- the tablet; forward-declared so the two functions below can call it.
local closeAdmin

--- Fetches the snapshot first and only then takes focus: a panel that opens
--- before it has anything to render shows an empty frame with the mouse
--- already captured, and a failed fetch would leave that frame permanent.
function ArenaUI.Open()
    if isOpen or isOpening then return end

    isOpening = true

    local token = closeToken
    local state = lib.callback.await('crimson_arena:server:getState', false)

    isOpening = false
    if token ~= closeToken then return end
    if not state then
        -- NOTHING IS TOUCHED ON THE WAY OUT, and that is the fix rather than
        -- an omission.
        --
        -- `state` is nil whenever the snapshot callback is THROTTLED -- a
        -- 500ms bucket, so an ordinary thing rather than an error: press E
        -- twice quickly and the second press lands here. closeAdmin() used to
        -- run BEFORE the snapshot was asked for, so this ordinary refusal shut
        -- a working tablet, opened no panel in its place, and returned holding
        -- the focus the tablet had taken. Mouse captured, nothing drawn, and
        -- ESC could reach neither screen because the page reads its two open
        -- flags and both were now false. Reconnecting was the only way out.
        --
        -- Leaving both alone costs the press and nothing else: an admin keeps
        -- the tablet they had, and a player who had nothing open still has
        -- nothing open and their controls.
        ArenaUI.Notify(locale('error.state_unavailable'), 'error')
        return
    end

    -- ONE SCREEN AT A TIME, and the tablet gives way here for the same reason
    -- the panel gives way to it: SetNuiFocus is global state with no stack.
    -- Without this, pressing E at the lobby ped with the tablet up drew the
    -- panel underneath an opaque full-screen modal.
    --
    -- AFTER THE SNAPSHOT, NOT BEFORE IT. Taking the tablet away first meant
    -- every refused open -- a throttled callback, a server that answered
    -- nothing -- shut a working screen and put nothing in its place.
    closeAdmin()

    isOpen = true
    ArenaUI.Send('open', state)
    SetNuiFocus(true, true)
end

--- THE ADMIN TABLET, opened by /arenaadmin.
---
--- ITS OWN SCREEN, NOT A TAB. The panel is what a PLAYER uses -- matches to
--- join, a loadout to pick, bets to place -- and the tablet is what somebody
--- watching the server uses. Bolting it on as a tab would put an admin
--- control in every player's panel and rely on the panel to hide it, which is
--- exactly the shape of gate this resource does not use: the server refuses
--- what the panel merely does not draw.
---
--- ONE FOCUS, SHARED. SetNuiFocus is global state with no stack, so the
--- tablet closes the panel rather than layering on top of it -- see the note
--- at the top of this file.
---
--- SHUT BY ANYTHING THAT SHUTS THE PANEL, and that is not tidiness.
--- ArenaUI.Close releases NUI focus unconditionally and the round start calls
--- it on every fighter -- so an admin who was queued for a match with the
--- tablet up was dropped into a live round behind an opaque full-screen
--- modal, with no mouse to press its Close button and no key that reached it.
--- The only way out was to run /arenaadmin again.
--- ASSIGNED, NOT DECLARED, because it is a LOCAL forward-declared above --
--- `function closeAdmin()` here would read as a new top-level function, and
--- REFERENCE.md's function tables (and the spec that checks them) count those.
closeAdmin = function()
    if not adminOpen then return end
    adminOpen = false
    ArenaUI.Send('adminClose')
end

--- @param payload table -- the first snapshot, so the screen has something
---        to draw before its own refresh comes back
local function openAdmin(payload)
    -- The panel and the tablet cannot both hold focus, and the panel is the
    -- one that has to give way: an admin typed a command to get here.
    ArenaUI.Close()

    adminOpen = true
    ArenaUI.Send('adminOpen', payload)
    SetNuiFocus(true, true)
end

RegisterNetEvent('crimson_arena:client:openAdmin', function(payload)
    openAdmin(type(payload) == 'table' and payload or { matches = {} })
end)

--- The server's answer to a refresh, a stop or a revive. Dropped when the
--- tablet is not open: a push that arrives after the screen was closed would
--- otherwise draw over whatever the player is looking at now.
RegisterNetEvent('crimson_arena:client:adminState', function(payload)
    if not adminOpen then return end
    ArenaUI.Send('adminState', type(payload) == 'table' and payload or {})
end)

--- Safe to call when already closed; the release is unconditional because
--- releasing focus we do not hold costs nothing and failing to release
--- focus we do hold costs the player their character.
function ArenaUI.Close()
    -- THE TABLET GOES WITH IT. The focus release below is unconditional, so a
    -- tablet left drawn here is one nothing can click.
    closeAdmin()

    -- Nothing to say if it was not open. Without this guard every ESC press
    -- outside the arena, and every defensive Close() on a path that may or
    -- may not have opened anything, would send the server a message.
    local wasOpen = isOpen

    isOpen = false
    closeToken = closeToken + 1
    ArenaUI.Send('close')
    SetNuiFocus(false, false)

    -- The server pushes a fresh snapshot to everyone it believes has the
    -- panel up, on every ready toggle, join and team switch in any lobby. It
    -- learns a panel OPENED from the state request; until this line it had no
    -- way to learn one closed, so a player who opened the menu once kept
    -- receiving those pushes for the rest of their session.
    if wasOpen then
        TriggerServerEvent('crimson_arena:server:panelClosed')
    end
end

-- ======================================================================
-- HUD OVERLAY
--
-- A separate NUI root with no pointer events, so it never takes focus and
-- is not affected by the panel being open or closed.
-- ======================================================================

--- @param data table? matchHud payload
function ArenaUI.UpdateHud(data)
    if not Config.UI.showMatchHud then return end
    local payload = { visible = true }
    for key, value in pairs(data or {}) do
        payload[key] = value
    end
    ArenaUI.Send('hud', payload)
end

--- The big centred number before a round goes live.
--- @param seconds integer
--- @param label string?
function ArenaUI.Countdown(seconds, label)
    ArenaUI.Send('countdown', { seconds = seconds, label = label })
end

--- End-of-match scoreboard. Drawn over gameplay rather than inside the
--- panel: it arrives as the player is teleported home with the panel already
--- closed, and taking NUI focus back to show it would take their controls
--- away at the moment they get them back.
--- @param results table
function ArenaUI.Results(results)
    if type(results) ~= 'table' then return end
    ArenaUI.Send('results', { results = results })
end

-- ======================================================================
-- NUI CALLBACKS
--
-- The panel talks to Lua with fetch(), and a fetch that is never answered
-- never rejects -- the promise simply hangs, the panel's button stays
-- disabled forever, and the player is left with a locked mouse.
--
-- So no handler below is allowed to answer for itself. `register` answers
-- exactly once, after the handler returns, on every path INCLUDING a Lua
-- error inside the handler (hence the pcall). Handlers cannot forget to
-- call cb because they are never given cb.
-- ======================================================================

--- @param name string
--- @param handler fun(data: table)
local function register(name, handler)
    RegisterNUICallback(name, function(data, cb)
        -- fetch() with no body arrives as nil, and a hostile page could send
        -- a bare number. Handlers may index `data` unconditionally.
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

-- EVERY FIELD THE PANEL SENDS IS NAMED HERE, and that is the whole job of
-- these handlers -- which is exactly why a missing name is so quiet.
--
-- `lives` was absent from this list. The panel computed it correctly, the
-- server read it correctly, and this relay in the middle dropped it on the
-- floor: every match was created on the operator's default no matter what
-- the host typed, with nothing anywhere reporting a problem. Both ends
-- looked right because both ends WERE right.
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
        -- Which account pays the entry fee. Dropped here it would arrive nil,
        -- which betting reads as "no preference" -- so the fee would come out
        -- of whichever account the operator listed first, whatever the player
        -- picked, and they would have no way to tell.
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
    -- Forwarded as it arrives. Arena.ResolveLoadout on the server is what
    -- decides which of these weapons exist and how much ammo they get.
    TriggerServerEvent('crimson_arena:server:setLoadout', {
        weapons = data.weapons,
        -- NAMED HERE OR IT DOES NOT EXIST. A field the panel posts and this
        -- relay does not forward is not an error at either end: the server
        -- reads nil, falls back to the operator's default and reports
        -- success. That is the defect this file keeps producing, and
        -- nuicontract_spec is what stops it.
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

--- Holding a countdown, which is NOT cancelling the match. The panel's
--- button says "everybody stays in the lobby and nobody loses their place",
--- and until this existed it posted the cancel above, which does neither.
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
        -- ALL THREE. `target` is a live source and is what hands items over
        -- now; the other two are how the same button queues a return for
        -- somebody who is not on the server, where there is no source to give
        -- anything to.
        target = data.target,
        citizenid = data.citizenid,
        stash = data.stash,
        matchId = data.matchId,
    })
end)

-- ======================================================================
-- SERVER -> PANEL RELAYS
-- ======================================================================

RegisterNetEvent('crimson_arena:client:state', function(state)
    ArenaUI.SendState(state)
end)

RegisterNetEvent('crimson_arena:client:notify', function(data)
    if type(data) ~= 'table' then return end
    ArenaUI.Notify(data.description, data.type)
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
    -- The board itself, or an envelope carrying it under `results`. Both are
    -- read because this is the one payload built on the server and drawn on
    -- the page with no shared code between the two ends to keep them agreed.
    ArenaUI.Results(type(data.results) == 'table' and data.results or data)
end)

-- The panel dies with the resource, but focus does not: a restart with the
-- menu open otherwise leaves the player with a captured mouse and no page
-- to release it. This handler is the reason a restart is survivable.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
