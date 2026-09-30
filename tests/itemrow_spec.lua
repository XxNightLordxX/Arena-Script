-- Crimson Arena: the item pop-ups moved off the crosshair during a round.

--[[
    tests/itemrow_spec.lua

    THE ASK: "when it gives like ammo items ... it stacks up where it covers
    the red dot". In a round, ox_inventory's own cards are switched off
    through its suppressItemNotifications export and the arena shows its own
    row, bottom-left. Outside a round nothing changes. Harness shaped like
    nuicallback_spec's.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('itemrow_spec')

local function newUI(opts)
    opts = opts or {}
    local f = { sent = {}, suppress = {} }
    local handlers, stops = {}, {}
    local ox = {
        suppressItemNotifications = function(_self, value)
            if opts.noExport then error('No such export suppressItemNotifications in resource ox_inventory', 0) end
            f.suppress[#f.suppress + 1] = value
        end,
    }
    local env = Sandbox.newEnv({
        SendNUIMessage = function(message) f.sent[#f.sent + 1] = message end,
        SetNuiFocus = function() end,
        RegisterNUICallback = function() end,
        RegisterNetEvent = function(name, fn) if fn then handlers[name] = fn end end,
        AddEventHandler = function(name, fn)
            if name == 'onResourceStop' then stops[#stops + 1] = fn else handlers[name] = fn end
        end,
        TriggerServerEvent = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetResourceState = function(name) return name == 'ox_inventory' and (opts.ox or 'started') or 'missing' end,
        GetConvar = function(name, default) if name == 'inventory:itemnotify' and opts.oxNotify then return opts.oxNotify end return default end,
        exports = setmetatable({ ox_inventory = ox }, { __call = function() end }),
        print = function() end,
        lib = { notify = function() end, callback = { await = function() return nil end } },
    })
    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../Crimson-Arena/client/ui.lua', env)
    f.UI = env.ArenaUI

    function f.notify(item, text, count) handlers['ox_inventory:itemNotify']({ item, text, count }) end
    function f.fireNet(name, ...) handlers[name](...) end
    function f.stop(name) for _, fn in ipairs(stops) do fn(name or 'crimson_arena') end end
    function f.rows()
        local out = {}
        for _, m in ipairs(f.sent) do if m.action == 'itemRow' and not m.data.clear then out[#out + 1] = m.data end end
        return out
    end
    function f.cleared()
        for _, m in ipairs(f.sent) do if m.action == 'itemRow' and m.data.clear then return true end end
        return false
    end
    return f
end

local AMMO = { name = 'ammo-rifle', label = 'Rifle Ammo', metadata = {} }

t.test('THE ASK: in a round ox\'s cards go off and the arena row shows the item', function()
    local f = newUI()
    f.UI.ItemRow(true)
    t.equals(f.suppress[1], true, 'ox was not told to stop its own cards')
    f.notify(AMMO, 'ui_added', 30)
    local rows = f.rows()
    t.equals(#rows, 1)
    t.equals(rows[1].label, 'Rifle Ammo')
    t.equals(rows[1].sign, '+')
    t.equals(rows[1].count, 30)
    t.equals(rows[1].image, 'nui://ox_inventory/web/images/ammo-rifle.png')
end)

t.test('leaving the round gives ox its cards back and clears the row', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.UI.ItemRow(false)
    t.equals(f.suppress[2], false, 'ox\'s cards were left switched off after the round')
    t.isTrue(f.cleared())
    f.notify(AMMO, 'ui_added', 30)
    t.equals(#f.rows(), 0, 'the arena row still drew outside a round')
end)

t.test('outside a round the arena draws nothing and never touches ox', function()
    local f = newUI()
    f.notify(AMMO, 'ui_added', 30)
    f.UI.ItemRow(false)
    t.equals(#f.rows(), 0)
    t.equals(#f.suppress, 0, 'ox was told something with no round in play')
end)

t.test('an ox without the export keeps its own cards and nothing is shown twice', function()
    local f = newUI({ noExport = true })
    f.UI.ItemRow(true)
    f.notify(AMMO, 'ui_added', 30)
    t.equals(#f.rows(), 0, 'the row drew alongside ox\'s own cards')
end)

t.test('switched off in config, ox is left alone in rounds too', function()
    local f = newUI({ mutate = function(Config) Config.UI.itemRow = false end })
    f.UI.ItemRow(true)
    t.equals(#f.suppress, 0)
    f.notify(AMMO, 'ui_added', 30)
    t.equals(#f.rows(), 0)
end)

t.test('stopping the resource mid-round gives ox its cards back', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.stop('some_other_resource')
    t.equals(#f.suppress, 1, 'another resource stopping touched ox')
    f.stop()
    t.equals(f.suppress[2], false)
end)

t.test('removals show as removals; unknown kinds and junk are dropped', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.notify(AMMO, 'ui_removed', 5)
    f.notify(AMMO, 'ui_something', 5)
    f.notify('junk', 'ui_added', 1)
    f.notify({ label = 'no name' }, 'ui_added', 1)
    local rows = f.rows()
    t.equals(#rows, 1)
    t.equals(rows[1].sign, '-')
end)

t.test('an image name that is not a plain name builds no image path', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.notify({ name = 'x', label = 'X', metadata = { image = '../../evil" onerror="x' } }, 'ui_added', 1)
    local rows = f.rows()
    t.equals(#rows, 1)
    t.isNil(rows[1].image)
end)

t.test('a long label is cut, and the metadata label wins', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.notify({ name = 'bandage', label = 'Bandage', metadata = { label = string.rep('A', 100) } }, 'ui_added', 1)
    t.equals(#f.rows()[1].label, 40)
end)

t.test('the page renders by text, never markup, and only nui/https images', function()
    local js = io.open('../Crimson-Arena/html/app.js'):read('a')
    local from = js:find('function showItemChip', 1, true)
    t.isNotNil(from)
    local body = js:sub(from, js:find('function renderCountdown', from, true))
    t.isNil(body:find('innerHTML', 1, true), 'the item row writes markup')
    t.contains(body, 'textContent')
    t.contains(body, '^(nui|https)')
    local html = io.open('../Crimson-Arena/html/index.html'):read('a')
    t.contains(html, 'id="arena-item-row"')
end)

t.test('FINAL CHECK: ox item notifications off server-wide -- the arena neither suppresses nor draws', function()
    for _, v in ipairs({ 'false', '0' }) do
        local f = newUI({ oxNotify = v })
        f.UI.ItemRow(true)
        t.equals(#f.suppress, 0)
        f.notify(AMMO, 'ui_added', 30)
        t.equals(#f.rows(), 0)
    end
end)

t.test('FINAL CHECK: the server turns the row on before the kit and off before the hand-back', function()
    local f = newUI()
    f.fireNet('crimson_arena:client:itemRow', true)
    t.equals(f.suppress[1], true)
    f.fireNet('crimson_arena:client:itemRow', false)
    t.equals(f.suppress[2], false)
    local text = io.open('../Crimson-Arena/server/match.lua'):read('a')
    local on = text:find("TriggerClientEvent('crimson_arena:client:itemRow', player.src, true)", 1, true)
    local issue = text:find('ArenaAmmo.Issue(player.src', 1, true)
    t.isTrue(on and issue and on < issue, 'the row is not switched on before the entry kit')
    local off = text:find("TriggerClientEvent('crimson_arena:client:itemRow', src, false)", 1, true)
    local reclaim = text:find("ArenaAmmo.Reclaim(src, 'left the arena')", 1, true)
    t.isTrue(off and reclaim and off < reclaim, 'the row is not switched off before the hand-back')
end)

t.test('FINAL CHECK: a long multi-byte label is cut on a character, not mid-byte', function()
    local f = newUI()
    f.UI.ItemRow(true)
    f.notify({ name = 'x', label = string.rep('é', 60), metadata = {} }, 'ui_added', 1)
    local label = f.rows()[1].label
    t.equals(utf8.len(label), 40)
end)

os.exit(t.summary())
