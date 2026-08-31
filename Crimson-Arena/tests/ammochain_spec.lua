--[[
    crimson_arena/tests/ammochain_spec.lua

    A TYPED AMMUNITION AMOUNT, FOLLOWED THE WHOLE WAY.

    The number a player types has four chances to be quietly replaced by
    something else before it reaches their hands:

      the relay      client/ui.lua names every field by hand, and a name left
                     out is a nil -- indistinguishable from "did not choose",
                     so the server falls back to the default and reports
                     success. This has happened twice in this build.
      the wire shape server/main.lua rebuilds the payload field by field
      the resolver   Arena.ResolveAmmo decides whether an off-preset number is
                     a request or a refusal
      the start      the stored choice is re-resolved when the round begins,
                     and could resolve differently to how it was saved

    Every one of those is right on its own and tested on its own. This file
    exists because the defect that keeps happening is not in any of them --
    it is in the joins, where both ends are correct and the value between
    them is lost. So this asserts the number at the far end: what
    ArenaAmmo is handed, and what the client is told to load.

    THE ARENA'S OWN CONFIG IS USED, not a fixture, so this also proves the
    shipped weapon list can carry a typed amount at all.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('ammochain_spec')

local function newServer(mutate)
    local qbx = Sandbox.newQbxCore({
        [1] = { citizenid = 'AAA11111', name = 'Host', money = { cash = 50000, bank = 0 } },
        [2] = { citizenid = 'BBB22222', name = 'Rival', money = { cash = 50000, bank = 0 } },
    })
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents, handlers, issued = {}, {}, {}, {}
    local dispatch = { cleared = {}, set = {}, bucketIn = {}, bucketOut = {} }

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = (function() local c = 0 return function() c = c + 60000 return c end end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        ArenaAmmo = {
            -- RECORDING, not silent. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; what this file is about is what reaches it,
            -- so the loadout handed over is kept rather than dropped.
            IsEnabled = function() return false end,
            Issue = function(src, _matchId, loadout)
                issued[#issued + 1] = { src = src, loadout = loadout }
                return {}
            end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function(src) dispatch.set[#dispatch.set + 1] = src end,
            Clear = function(src) dispatch.cleared[#dispatch.cleared + 1] = src end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function(src) dispatch.revived = (dispatch.revived or {}); dispatch.revived[#dispatch.revived + 1] = src end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function(src) dispatch.bucketIn[#dispatch.bucketIn + 1] = src end,
            ExitBucket = function(src) dispatch.bucketOut[#dispatch.bucketOut + 1] = src end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
    })

    -- No lobby countdown, and a long freeze: that puts everybody in the arena
    -- immediately and holds the match at 'countdown' for the whole test,
    -- which IS the window under examination.
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 30
    env.Config.Match.minPlayers = 2
    -- Betting off: an entry fee would make every createMatch below a
    -- transaction, and this file is about one boolean.
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, dispatch = dispatch, config = env.Config,
        lobby = env.ArenaLobby, match = env.ArenaMatch }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    --- One pass of every live coroutine. Deliberately explicit: the freeze
    --- is a CreateThread + Wait, and the sandbox's Wait yields once, so a
    --- single extra step is the difference between a frozen countdown and a
    --- live round.
    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- The payload of the LAST event of one name sent to one player, which
    --- is what a fighter actually entered the arena under.
    function server.payloadTo(event, target)
        local found = nil
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:' .. event and message.target == target then
                found = message.payload
            end
        end
        return found
    end

    --- What the panel would draw from, for one player.
    function server.snapshot(src)
        return env.ArenaLobby.BuildState(src)
    end

    --- The loadout ArenaAmmo was asked to hand over to one player.
    function server.issuedTo(src)
        for _, entry in ipairs(issued) do
            if entry.src == src then return entry.loadout end
        end
        return nil
    end

    --- The stored choice, as the lobby holds it between save and start.
    function server.storedLoadout(matchId, src)
        local match = env.ArenaLobby.Get(matchId)
        local entry = match and match.players[src]
        return entry and entry.loadout or nil
    end

    return server
end



--- One lobby with both players in it, ready to start.
local function lobby(mutate)
    local server = newServer(mutate)
    server.fire('createMatch', 1, { arenaKey = 'airfield', modeKey = 'ffa' })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')
    server.fire('joinMatch', 2, { matchId = match.id })

    return server, match.id
end

--- The ammo one weapon was handed over with, out of a loadout.
local function ammoOf(loadout, weaponName)
    for _, entry in ipairs((loadout or {}).weapons or {}) do
        if entry.weapon == weaponName then return entry.ammo end
    end
    return nil
end

--- A shipped weapon that takes ammunition and allows a typed amount, so the
--- numbers below are the arena's own rather than a fixture's.
local function firstCustomWeapon(config)
    for _, weapon in ipairs(config.Loadouts.weapons or {}) do
        if weapon.enabled ~= false and type(weapon.ammo) == 'table'
            and (Sandbox.newArenaEnv().Arena.ToInt(weapon.ammo.max) or 0) > 0
        then
            return weapon
        end
    end
    return nil
end

-- ======================================================================
-- WHAT THE SHIPPED CONFIG ALLOWS
-- ======================================================================

t.test('the shipped config lets a player type an amount at all', function()
    local config = newServer().config
    t.isTrue(config.Loadouts.allowChoose ~= false, 'nobody can choose a loadout, so nothing below applies')
    t.isTrue(config.Loadouts.allowCustomAmmo == true,
        'typed amounts are switched off in the shipped config, so the box is decoration')

    local weapon = firstCustomWeapon(config)
    t.isNotNil(weapon, 'no shipped weapon takes ammunition')
end)

-- ======================================================================
-- THE NUMBER, ALL THE WAY THROUGH
-- ======================================================================

t.test('an off-preset amount reaches the arena exactly as typed', function()
    -- 137 is on no preset list in the shipped config. Under the old rule --
    -- off-list is refused, not rounded -- this came back as the default, and
    -- the box looked like it had been ignored.
    local server, matchId = lobby()
    local weapon = firstCustomWeapon(server.config)

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = 137 } }, armor = 0 })

    t.equals(ammoOf(server.storedLoadout(matchId, 1), weapon.weapon), 137,
        'the typed amount did not survive being saved')

    server.fire('startMatch', 1)
    server.step(4)

    -- `.loadout`, because payloadTo hands back the whole enterArena payload
    -- and the weapons live inside it.
    t.equals(ammoOf((server.payloadTo('enterArena', 1) or {}).loadout, weapon.weapon), 137,
        'the client was told to load a different number to the one that was saved')
    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), 137,
        'the inventory was handed a different number to the one the client was told')
end)

t.test('and an amount ON the preset list survives too', function()
    -- The other branch of ResolveAmmo, so a pass above is not a resolver that
    -- has simply stopped checking anything.
    local server = lobby()
    local weapon = firstCustomWeapon(server.config)
    local preset = (weapon.ammo.options or {})[1]
    t.isNotNil(preset, 'the weapon this test picked has no presets')

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = preset } }, armor = 0 })
    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), preset)
end)

t.test('an amount over the ceiling is cut to the ceiling, not to the default', function()
    -- The distinction matters to a player: cut to the maximum is the server
    -- saying "that is all you may have", and dropping to the default is the
    -- box appearing not to work.
    local server = lobby()
    local weapon = firstCustomWeapon(server.config)
    local maximum = weapon.ammo.max

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = maximum + 5000 } }, armor = 0 })
    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), maximum,
        'an over-ceiling request did not come back as the ceiling')
    t.isTrue(maximum ~= weapon.ammo.default,
        'this weapon\'s max equals its default, so the assertion above cannot tell them apart')
end)

t.test('a server that FORBIDS typed amounts still refuses one, off the same wire', function()
    local server = lobby(function(config) config.Loadouts.allowCustomAmmo = false end)
    local weapon = firstCustomWeapon(server.config)

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = 137 } }, armor = 0 })
    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), weapon.ammo.default,
        'a typed amount was accepted on a server that does not allow them')
end)

t.test('THE SHIPPED DEFAULT: the host picks, and everybody fights with it', function()
    -- Config.Loadouts.chooser is 'host' as shipped, which is a real decision
    -- and not an oversight: everyone carries the same weapons, so the only
    -- variable left in a round is the players.
    --
    -- Asserted because it is invisible from the panel of the person setting
    -- it up. The host sees a picker that works, types an amount, and every
    -- fighter in the match gets it -- including the ones whose own box was
    -- never drawn for them.
    local server = lobby()
    local weapon = firstCustomWeapon(server.config)
    t.equals(server.config.Loadouts.chooser, 'host',
        'the shipped chooser changed, and the rest of this test is about the old one')

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = 137 } }, armor = 0 })

    -- And a fighter who is not the host is REFUSED, rather than silently
    -- ignored -- the panel hides the picker from them, and the server does
    -- not rely on the panel having done so.
    local ok, reason = server.lobby.SetLoadout(2, { weapons = { { key = weapon.key, ammo = 42 } }, armor = 0 })
    t.isFalse(ok, 'a non-host set their own loadout on a host-picks server')
    t.equals(reason, 'error.host_picks_loadout')

    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), 137)
    t.equals(ammoOf(server.issuedTo(2), weapon.weapon), 137,
        'a fighter who is not the host did not inherit the host\'s loadout')
end)

t.test('and with chooser = player, one fighter\'s amount is not handed to the other', function()
    -- The other setting, and the one where a shared loadout table would show
    -- up: a bug that stored the choice on the match rather than on the player
    -- is invisible while everybody is meant to have the same one.
    local server = lobby(function(config) config.Loadouts.chooser = 'player' end)
    local weapon = firstCustomWeapon(server.config)

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key, ammo = 137 } }, armor = 0 })
    server.fire('setLoadout', 2, { weapons = { { key = weapon.key, ammo = 42 } }, armor = 0 })
    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), 137)
    t.equals(ammoOf(server.issuedTo(2), weapon.weapon), 42,
        'both fighters were armed from the same loadout')
end)

t.test('a weapon carrying no amount at all gets the operator default', function()
    -- What the panel sends for a weapon picked without touching the box.
    local server = lobby()
    local weapon = firstCustomWeapon(server.config)

    server.fire('setLoadout', 1, { weapons = { { key = weapon.key } }, armor = 0 })
    server.fire('startMatch', 1)
    server.step(4)

    t.equals(ammoOf(server.issuedTo(1), weapon.weapon), weapon.ammo.default,
        'a weapon picked without an amount did not get the default')
end)

-- ======================================================================
-- AND THE AMMUNITION IS THE RIGHT KIND
-- ======================================================================

t.test('every shipped weapon names an ammo item its own ammoTypes list has', function()
    -- The panel has no ammo-type picker any more: the type is correlated from
    -- the weapon. So a weapon whose list is empty or wrong is a weapon that
    -- hands out nothing, silently, on a server with ammo items switched on.
    local config = newServer().config
    local Arena = Sandbox.newArenaEnv().Arena

    local bad = {}
    for _, weapon in ipairs(config.Loadouts.weapons or {}) do
        -- The resource's OWN predicate, not a rule invented here. Melee
        -- ships as `max = 1`, not `max = 0` -- a bat swings once -- so a
        -- test that decided melee by "no ceiling" called every knife in the
        -- list a firearm with no ammunition.
        if weapon.enabled ~= false and not Arena.IsMeleeWeapon(weapon) then
            local types = weapon.ammoTypes
            if type(types) ~= 'table' or #types == 0 then
                bad[#bad + 1] = tostring(weapon.key) .. ' (no ammoTypes)'
            else
                for _, entry in ipairs(types) do
                    if not Arena.IsKey(entry.item) then
                        bad[#bad + 1] = tostring(weapon.key) .. ' (a type with no item)'
                    end
                end
            end
        end
    end

    t.equals(table.concat(bad, ', '), '',
        'these weapons take ammunition and cannot say which kind')
end)

os.exit(t.summary())
