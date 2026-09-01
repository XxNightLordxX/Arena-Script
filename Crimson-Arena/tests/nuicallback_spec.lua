--[[
    crimson_arena/tests/nuicallback_spec.lua

    THE HANDLERS ON THE OTHER SIDE OF THE PANEL'S fetch().

    Everything a player does in the menu arrives here. `html/app.js` posts
    a JSON body to a callback name; `client/ui.lua` registers a handler for
    that name, reads the fields out, and forwards them to the server.

    NOTHING HAS EVER RUN ONE. panel_spec loads the same file and stubs
    RegisterNUICallback to an empty function, because its subject is the
    panel's open/close lifecycle and the callbacks are not part of it.
    nuicontract_spec reads both files as TEXT -- it proves every field the
    page posts is NAMED in the relay, which is the defect that kept
    happening (a name left out is a nil, indistinguishable from "the host
    did not choose"), but it never executes a line of either.

    So the handlers themselves were unexecuted, and a mutation sample found
    eighteen survivors. The worst of them is one line:

        TriggerServerEvent('...:setReady', { ready = data.ready and true or false })

    That `and true or false` coerces whatever the page sent into a real
    boolean. Turn the `and` into an `or` and it is ALWAYS TRUE -- every
    player in every lobby is permanently ready and rounds start the moment
    they are created. Turn the `true` into `false` and it is always false:
    nobody can ready up and no match ever starts. Both are the whole
    feature, in one operator-invisible token, with no test between them and
    a server.

    What this file holds:

      THE WRAPPER              a body that is not a table, a handler that
                               raises, and the callback that must still
                               answer either way -- a fetch() with no reply
                               hangs the page.

      THE READY TOGGLE         both directions, and the coercion.

      WHAT ELSE REACHES THE    the refresh ask, which deliberately says it
      SERVER                   is the panel, and the close, which is the
                               only way the server learns a panel shut.

      THE NOTIFICATION SPLIT   panel rail while open, ox_lib while closed,
                               and the one word that is spelled
                               differently between them.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- One fresh load of the REAL client/ui.lua with its NUI callbacks KEPT.
---
--- That is the whole difference from panel_spec's fixture: there
--- RegisterNUICallback is an empty function, so every handler below is
--- registered into nothing and none of them has ever run.
--- @param opts table? -- { snapshot }
--- @return table fixture
local function newPanel(opts)
    opts = opts or {}
    local f = {
        sent = {},           -- every SendNUIMessage
        focus = {},          -- every SetNuiFocus, both arguments
        server = {},         -- every TriggerServerEvent, with its payload
        notifications = {},  -- everything that fell through to ox_lib
        replies = {},        -- every cb(...) a callback answered with
        console = {},
    }
    local callbacks, handlers = {}, {}
    -- NOT `opts.snapshot ~= nil and opts.snapshot or default`. That idiom
    -- collapses to the default whenever the value is FALSE -- which is
    -- precisely the failed-fetch case a test wants to describe, so the
    -- fixture would hand back a working snapshot and the test would pass
    -- against a panel that opens on nothing.
    if opts.snapshot == nil then
        f.snapshot = { config = {}, player = {} }
    else
        f.snapshot = opts.snapshot
    end

    local env = Sandbox.newEnv({
        SendNUIMessage = function(message) f.sent[#f.sent + 1] = message end,
        SetNuiFocus = function(hasFocus, hasCursor)
            f.focus[#f.focus + 1] = { hasFocus = hasFocus, hasCursor = hasCursor }
        end,
        RegisterNUICallback = function(name, fn) callbacks[name] = fn end,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function(name, payload)
            f.server[#f.server + 1] = { name = name, payload = payload }
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        print = function(line) f.console[#f.console + 1] = tostring(line) end,
        lib = {
            callback = {
                await = function(name, delay)
                    f.awaited = { name = name, delay = delay }
                    if f.duringAwait then f.duringAwait() end
                    return f.snapshot
                end,
            },
            notify = function(data) f.notifications[#f.notifications + 1] = data end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../client/ui.lua', env)

    f.env = env
    f.UI = env.ArenaUI

    --- Posts a body to a NUI callback the way the page's fetch() does, and
    --- records what the callback answered with. Returns false when this
    --- resource registered no callback of that name at all.
    function f.post(name, body)
        local fn = callbacks[name]
        if not fn then return false end
        fn(body, function(reply) f.replies[#f.replies + 1] = { name = name, reply = reply } end)
        return true
    end

    function f.fire(name, ...)
        local handler = handlers[name]
        if not handler then return false end
        handler(...)
        return true
    end

    --- The last server event of this name, or nil.
    function f.lastServer(name)
        for index = #f.server, 1, -1 do
            if f.server[index].name == name then return f.server[index] end
        end
        return nil
    end

    function f.lastFocus() return f.focus[#f.focus] end
    function f.log() return table.concat(f.console, '\n') end

    return f
end

local READY = 'crimson_arena:server:setReady'
local STATE = 'crimson_arena:server:requestState'

-- ========================================================================
-- THE WRAPPER EVERY HANDLER SITS INSIDE
-- ========================================================================

t.test('every callback ANSWERS, because a fetch with no reply hangs the page', function()
    -- The page awaits the response. A callback that returns without
    -- calling cb leaves that promise pending forever, and the button the
    -- player pressed never comes back.
    local f = newPanel()

    t.isTrue(f.post('setReady', { ready = true }), 'no callback is registered for setReady')

    t.equals(#f.replies, 1, 'the page was left waiting on a reply that never came')
    t.equals(f.replies[1].reply, 'ok')
end)

t.test('and answers even when the handler RAISES', function()
    -- A handler that throws must not take the reply with it, or one bad
    -- payload freezes the menu until the player relogs.
    local f = newPanel()
    -- setLoadout indexes its data; a body with a hostile shape is the
    -- realistic way in.
    f.env.TriggerServerEvent = function() error('the server event blew up') end

    t.isTrue(f.post('setReady', { ready = true }))

    t.equals(#f.replies, 1, 'a raising handler left the page waiting forever')
    t.contains(f.log(), 'errored', 'a handler raised and nothing was said about it')
end)

t.test('a body that is not a table is replaced, not indexed into', function()
    -- fetch() with no body arrives as nil, and a hostile page can send a
    -- bare number. Handlers index `data` unconditionally, so the wrapper
    -- has to make that safe.
    local f = newPanel()

    for _, bad in ipairs({ 42, 'ready', true }) do
        t.isTrue(f.post('setReady', bad), ('setReady raised on %s'):format(tostring(bad)))
    end
    f.post('setReady', nil)

    t.equals(#f.replies, 4, 'a junk body left the page waiting')
    t.notContains(f.log(), 'errored', 'a junk body raised inside the handler')
end)

-- ========================================================================
-- THE READY TOGGLE
-- ========================================================================

t.test('readying up sends TRUE, and un-readying sends FALSE', function()
    -- BOTH DIRECTIONS, because either one alone passes against a relay
    -- that hardcodes its answer -- and hardcoding it is the whole
    -- feature: always true starts every round the instant it is made,
    -- always false means no round ever starts.
    local f = newPanel()

    f.post('setReady', { ready = true })
    t.equals(f.lastServer(READY).payload.ready, true, 'readying up did not reach the server as ready')

    f.post('setReady', { ready = false })
    t.equals(f.lastServer(READY).payload.ready, false, 'un-readying did not reach the server as not ready')
end)

t.test('and whatever the page sent is coerced to a real BOOLEAN', function()
    -- The page is JavaScript and the wire is JSON. A checkbox that posts
    -- the string "false", or a 0, is truthy in Lua -- so the coercion is
    -- what stands between the panel and a server that reads `ready` as a
    -- string.
    local f = newPanel()

    for _, truthy in ipairs({ 1, 0, 'yes', 'false', {} }) do
        f.post('setReady', { ready = truthy })
        local sent = f.lastServer(READY).payload.ready
        t.equals(type(sent), 'boolean',
            ('%s reached the server as a %s'):format(tostring(truthy), type(sent)))
        t.equals(sent, true, ('%s should be truthy'):format(tostring(truthy)))
    end
end)

t.test('and a MISSING ready field is not ready, rather than a nil', function()
    -- A nil here is indistinguishable from "the field was never sent",
    -- which is the defect class this whole relay exists to prevent.
    local f = newPanel()

    f.post('setReady', {})

    local sent = f.lastServer(READY).payload.ready
    t.equals(type(sent), 'boolean', 'a missing ready field reached the server as a nil')
    t.equals(sent, false)
end)

-- ========================================================================
-- WHAT ELSE REACHES THE SERVER
-- ========================================================================

t.test('the refresh ask says it IS the panel', function()
    -- The server reads a state request as "a panel just opened" and adds
    -- the asker to the set every broadcast is serialised for. This ask
    -- really is the panel, so being counted is correct -- and
    -- client/spectate.lua asks for the same snapshot with the menu shut
    -- and deliberately does not say it.
    local f = newPanel()

    t.isTrue(f.post('refresh', {}))

    local ask = f.lastServer(STATE)
    t.isNotNil(ask, 'the refresh button asked the server for nothing')
    t.equals(ask.payload.panel, true, 'the panel asked for a snapshot without saying it was the panel')
end)

t.test('closing the panel TELLS the server, so the pushes stop', function()
    -- The server pushes a fresh snapshot to everyone it believes has the
    -- panel up, on every ready toggle, join and team switch in any lobby.
    -- It learns a panel opened from the state request; without this it had
    -- no way to learn one closed, and a player who opened the menu once
    -- kept receiving those pushes for the rest of their session.
    local f = newPanel()
    f.UI.Open()
    local before = #f.server

    t.isTrue(f.post('close', {}))

    t.isTrue(#f.server > before, 'closing the panel told the server nothing')
    t.isFalse(f.UI.IsOpen(), 'the panel stayed open after the page asked to close it')
    t.equals(f.lastFocus().hasFocus, false, 'the player was left holding NUI focus')
end)

t.test('and a close on a panel that was never open says nothing', function()
    -- Every ESC press outside the arena, and every defensive Close() on a
    -- path that may not have opened anything, would otherwise send the
    -- server a message.
    local f = newPanel()

    f.post('close', {})

    t.equals(#f.server, 0, 'closing a panel that was never open messaged the server')
end)

-- ========================================================================
-- FOCUS, BOTH FLAGS
-- ========================================================================

t.test('opening takes the mouse AND the keyboard', function()
    -- Two flags, and the second is the cursor. Taken without it the
    -- player has a menu they cannot click.
    local f = newPanel()

    f.UI.Open()

    local focus = f.lastFocus()
    t.isNotNil(focus, 'the panel never took focus')
    t.equals(focus.hasFocus, true, 'the panel opened without keyboard focus')
    t.equals(focus.hasCursor, true, 'the panel opened without a mouse cursor')
end)

t.test('and closing releases both', function()
    local f = newPanel()
    f.UI.Open()
    f.UI.Close()

    local focus = f.lastFocus()
    t.equals(focus.hasFocus, false, 'the player was left with the keyboard captured')
    t.equals(focus.hasCursor, false, 'the player was left with the mouse captured')
end)

t.test('a panel that is already open is not opened twice', function()
    -- Re-entrancy costs a second snapshot fetch and a second focus grab
    -- for one menu.
    local f = newPanel()
    f.UI.Open()
    local focusCalls = #f.focus

    f.UI.Open()

    t.equals(#f.focus, focusCalls, 'an already-open panel took focus a second time')
end)

t.test('and a failed snapshot leaves the player their controls', function()
    -- A panel that opened before it had anything to render shows an empty
    -- frame with the mouse already captured, and a failed fetch would
    -- make that frame permanent.
    local f = newPanel({ snapshot = false })

    f.UI.Open()

    t.equals(#f.focus, 0, 'focus was taken for a panel that had nothing to draw')
    t.isFalse(f.UI.IsOpen())
    t.equals(#f.notifications, 1, 'a failed fetch said nothing to the player')
end)

-- ========================================================================
-- WHERE A NOTIFICATION GOES
-- ========================================================================

t.test('an empty notification is not sent anywhere', function()
    local f = newPanel()

    for _, bad in ipairs({ '', 42, {}, true }) do
        f.UI.Notify(bad, 'info')
    end
    f.UI.Notify(nil, 'info')

    t.equals(#f.notifications, 0, 'an empty notification was shown to the player')
end)

t.test('ox_lib is told "inform" where the rest of the resource says "info"', function()
    -- One word, spelled differently on each side of a boundary. Send
    -- 'info' and ox_lib renders its default style rather than the neutral
    -- one, which is the sort of difference nobody reports and everybody
    -- sees.
    local f = newPanel()

    f.UI.Notify('Weapon refused.', 'info')

    t.equals(#f.notifications, 1)
    t.equals(f.notifications[1].type, 'inform', 'ox_lib was handed a level it does not use')
    t.equals(f.notifications[1].description, 'Weapon refused.')
    t.equals(f.notifications[1].title, f.env.Config.NotifyTitle)
end)

t.test('and every OTHER level is passed through untranslated', function()
    -- The control. Without it, a translation that rewrote everything to
    -- 'inform' passes the assertion above.
    local f = newPanel()

    for _, level in ipairs({ 'success', 'warning', 'error' }) do
        f.UI.Notify('Something happened.', level)
        t.equals(f.notifications[#f.notifications].type, level,
            ('the %s level was rewritten on its way to ox_lib'):format(level))
    end
end)

t.test('a notification with no level at all defaults to the neutral one', function()
    local f = newPanel()

    f.UI.Notify('Something happened.')

    t.equals(f.notifications[1].type, 'inform', 'a notification with no level was sent at some other level')
end)

t.test('with the panel OPEN it goes to the rail instead, and only there', function()
    local f = newPanel()
    f.UI.Open()

    f.UI.Notify('Weapon refused.', 'warning')

    t.equals(#f.notifications, 0, 'the notification went to ox_lib as well as the panel')
    local last = f.sent[#f.sent]
    t.equals(last.action, 'notify', 'the notification never reached the panel')
    t.equals(last.data.message, 'Weapon refused.')
    t.equals(last.data.type, 'warning')
end)

-- ========================================================================
-- THE MATCH HUD
-- ========================================================================

t.test('the hud payload is marked visible and carries the data with it', function()
    local f = newPanel()

    f.UI.UpdateHud({ alive = 3, lives = 2 })

    local last = f.sent[#f.sent]
    t.equals(last.action, 'hud')
    t.equals(last.data.visible, true, 'a hud update was sent without being marked visible')
    t.equals(last.data.alive, 3, 'the hud payload lost its fields on the way to the page')
    t.equals(last.data.lives, 2)
end)

t.test('and a hud update with no data at all is still a visible hud', function()
    local f = newPanel()

    f.UI.UpdateHud(nil)

    local last = f.sent[#f.sent]
    t.equals(last.action, 'hud')
    t.equals(last.data.visible, true)
end)

t.test('an operator who turned the hud off gets nothing', function()
    local f = newPanel({ mutate = function(config) config.UI.showMatchHud = false end })

    f.UI.UpdateHud({ alive = 3 })

    t.equals(#f.sent, 0, 'a hud was drawn for an operator who switched it off')
end)


-- ========================================================================
-- OPENING TWICE AT ONCE
--
-- The snapshot fetch YIELDS. Everything between pressing the key and the
-- server answering is a window another press lands in, and `isOpen` is not
-- set until the answer arrives -- so the flag that has to stop the second
-- one is `isOpening`, and only a re-entrant open can reach it.
-- ========================================================================

t.test('a second open landing DURING the first fetch is refused', function()
    local f = newPanel()
    local reentered = 0
    f.duringAwait = function()
        reentered = reentered + 1
        if reentered == 1 then f.UI.Open() end
    end

    f.UI.Open()

    t.equals(reentered, 1, 'the second open started a second snapshot fetch of its own')
    t.equals(#f.focus, 1, 'the panel took focus twice for one menu')
    t.equals(#f.sent, 1, 'the panel was drawn twice')
end)

t.test('and the panel still opens normally afterwards', function()
    -- The guard has to clear. Left set, the menu never opens again for the
    -- rest of the session.
    local f = newPanel()
    f.duringAwait = function() f.UI.Open() end
    f.UI.Open()

    f.duringAwait = nil
    f.UI.Close()
    f.UI.Open()

    t.isTrue(f.UI.IsOpen(), 'the panel could not be reopened after a re-entrant open')
end)

t.test('the snapshot is awaited with no payload of its own', function()
    -- ox_lib reads the second argument as the callback's own delay, not as
    -- data. The panel has nothing to send with the ask.
    local f = newPanel()
    f.UI.Open()

    t.isNotNil(f.awaited, 'the panel never asked the server for a snapshot')
    t.equals(f.awaited.name, 'crimson_arena:server:getState')
    t.equals(f.awaited.delay, false, 'the snapshot ask carries a delay the panel did not intend')
end)

-- ========================================================================
-- THE RESTART
-- ========================================================================

t.test('a restart with the menu open releases BOTH focus flags', function()
    -- The page dies with the resource; the focus it took does not. Both
    -- flags matter: released as keyboard-only, the player keeps a captured
    -- mouse and no page to release it.
    local f = newPanel()
    f.UI.Open()

    t.isTrue(f.fire('onResourceStop', 'crimson_arena'))

    local focus = f.lastFocus()
    t.equals(focus.hasFocus, false, 'the player was left with the keyboard captured after a restart')
    t.equals(focus.hasCursor, false, 'the player was left with the mouse captured after a restart')
end)

-- ========================================================================
-- SERVER PUSHES WITH THE WRONG SHAPE
-- ========================================================================

t.test('a countdown push that is not a table is ignored, not indexed', function()
    -- Every one of these is a network payload. Indexing one without
    -- checking is a client-side raise for anybody a malformed push
    -- reaches.
    local f = newPanel()
    f.UI.Open()
    local before = #f.sent

    for _, bad in ipairs({ 'countdown', 42, true }) do
        t.isTrue(f.fire('crimson_arena:client:countdown', bad),
            ('the countdown handler raised on %s'):format(tostring(bad)))
    end

    t.equals(#f.sent, before, 'a malformed countdown push was drawn on the page anyway')
end)

t.test('while a real one reaches the page', function()
    -- The control: without it, a handler that ignores EVERY countdown
    -- passes the assertion above.
    local f = newPanel()
    f.UI.Open()

    t.isTrue(f.fire('crimson_arena:client:countdown', { seconds = 3, label = 'GET READY' }))

    local last = f.sent[#f.sent]
    t.equals(last.action, 'countdown', 'a real countdown never reached the page')
    t.equals(last.data.seconds, 3)
    t.equals(last.data.label, 'GET READY')
end)

os.exit(t.summary())
