--[[
    crimson_arena/tests/crossfire_spec.lua

    NOBODY SHOOTS ACROSS THE LINE, IN EITHER DIRECTION.

    Asked for from the game, about the trailer park: someone who is not in
    the match must not be able to hurt anyone in it, and the fighters must
    not be able to hurt anyone outside.

    The routing bucket already covers the ordinary case -- a player outside
    the match is in another network instance and cannot see or hit anyone in
    it. Three cases fall outside that, and they are the reason this layer
    exists rather than the bucket being called good enough:

      A SPECTATOR IS PUT IN THE MATCH'S OWN INSTANCE, deliberately, because
      watching requires seeing. Their body is hidden and frozen while the
      camera runs -- and the camera stops itself when it runs out of
      fighters to follow, which hands the body back inside a live round.

      ISOLATION MAY NOT BE IN FORCE. Buckets need OneSync, and an operator
      can switch them off. Every line of the instancing still runs.

      AND A SAFETY PROPERTY SHOULD NOT BE A SIDE EFFECT of a networking
      setting that four other things also depend on.

    So the rule is decided on the server from the damage packet itself. What
    follows tests it eight ways: what it must allow, what it must refuse,
    what a hostile client can put in the packet, what happens at the edges,
    what it costs when nothing is running, that an idle server is untouched,
    that it composes with spectating and with two matches on one arena, and
    that switching it off really does restore the old behaviour.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('crossfire_spec')

--- A server/dispatch.lua running against a modelled server.
--- @param opts table? -- { guard = boolean }
local function newFixture(opts)
    opts = opts or {}
    local handlers = {}
    local f = {
        cancelled = false,
        --- src -> the network id of that player's ped.
        netIds = {},
        --- How many times the guard walked every player on the server.
        walks = 0,
        debugs = {},
    }

    local env = Sandbox.newEnv({
        GetPlayers = function()
            f.walks = f.walks + 1
            local out = {}
            for src in pairs(f.netIds) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        NetworkGetNetworkIdFromEntity = function(ped)
            local src = (tonumber(ped) or 0) - 1000
            return f.netIds[src] or 0
        end,
        CancelEvent = function() f.cancelled = true end,

        GetPlayerRoutingBucket = function() return 0 end,
        SetPlayerRoutingBucket = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,

        Player = function()
            return { state = { set = function() end } }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        RegisterCommand = function() end,
        CreateThread = function() end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        exports = setmetatable({}, { __call = function() end }),
        ArenaLog = function() end,
        ArenaDebug = function(fmt, ...)
            f.debugs[#f.debugs + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
        end,
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.enableAllArenas(env)
    if opts.guard ~= nil then
        env.Config.Match.crossfireGuard = { enabled = opts.guard }
    end
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)

    f.env = env
    f.D = env.ArenaDispatch

    --- Puts a player on the server with a ped somebody can shoot at.
    function f.spawn(src, netId)
        f.netIds[src] = netId or (5000 + src)
        return f.netIds[src]
    end

    --- Puts a player IN a match, which is what `active` records.
    function f.enter(src, matchId)
        f.spawn(src)
        f.D.Set(src, matchId)
    end

    --- Fires the engine's damage packet the way the server does.
    --- @return boolean cancelled
    function f.shoot(attacker, victims, override)
        f.cancelled = false
        local hits = {}
        for _, victim in ipairs(victims or {}) do
            hits[#hits + 1] = f.netIds[victim] or victim
        end
        local data = override or { hitGlobalIds = hits }
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do fn(tostring(attacker), data) end
        return f.cancelled
    end

    --- Fires the engine's explosion packet.
    function f.explode(sender, x, y, z)
        f.cancelled = false
        local data = { posX = x, posY = y, posZ = z }
        for _, fn in ipairs(handlers['explosionEvent'] or {}) do
            fn(sender and tostring(sender) or nil, data)
        end
        return f.cancelled
    end

    --- Fires a raw payload, for the packets a hostile client can build.
    function f.raw(sender, data)
        f.cancelled = false
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do fn(sender, data) end
        return f.cancelled
    end

    f.handlers = handlers
    return f
end

local SKY = { x = 1500.0, y = 3000.0, z = 1201.0 }
local PARK = { x = 2344.4294, y = 2565.0552, z = 46.6677 }

-- ======================================================================
-- 1. WHAT IT MUST ALLOW
-- ======================================================================

t.test('two fighters in the same match can fight', function()
    -- The one thing this must never break.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')
    t.isFalse(f.shoot(1, { 2 }), 'a fighter could not shoot their opponent')
    t.isFalse(f.shoot(2, { 1 }), 'the opponent could not shoot back')
end)

t.test('and two people with nothing to do with the arena are left alone', function()
    -- An arena is running elsewhere, so the guard is awake -- and it still
    -- must not touch a fight in the city.
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(8)
    f.spawn(9)
    t.isFalse(f.shoot(8, { 9 }), 'the guard cancelled a fight it has no business in')
end)

t.test('and a player can always hurt themselves', function()
    -- A fall, or your own grenade. Refusing it would make a fighter immortal
    -- to the one thing the arena does not control, and it is not crossfire.
    local f = newFixture()
    f.enter(1, 'm1')
    t.isFalse(f.shoot(1, { 1 }), 'a fighter was made immune to their own damage')
end)

-- ======================================================================
-- 2. WHAT IT MUST REFUSE
-- ======================================================================

t.test('THE REPORT: somebody outside the match cannot shoot into it', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(9)
    t.isTrue(f.shoot(9, { 1 }), 'a passer-by shot a fighter in a live round')
end)

t.test('AND THE OTHER HALF: a fighter cannot shoot out of it', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(9)
    t.isTrue(f.shoot(1, { 9 }), 'a fighter shot somebody who is not in the arena')
end)

t.test('two matches on one arena cannot shoot each other', function()
    -- What makes one arena safe to run two rounds in, and it is the same
    -- rule rather than a second one: a fighter in another match is exactly
    -- as much an outsider as a passer-by.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')
    f.enter(3, 'm2')
    f.enter(4, 'm2')

    t.isTrue(f.shoot(1, { 3 }), 'a fighter hit somebody in the other match')
    t.isTrue(f.shoot(3, { 1 }), 'the other match hit back')
    t.isFalse(f.shoot(1, { 2 }), 'the first match can no longer fight itself')
    t.isFalse(f.shoot(3, { 4 }), 'the second match can no longer fight itself')
end)

t.test('a spectator cannot shoot the fighters they are watching', function()
    -- THE CASE THE BUCKET CANNOT COVER, because a spectator is deliberately
    -- put in the match's own instance so they can see it -- and the camera
    -- hands their body back the moment it runs out of fighters to follow.
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(7)   -- watching, so in the instance, but not in `active`
    t.isTrue(f.shoot(7, { 1 }), 'a spectator shot a fighter')
    t.isTrue(f.shoot(1, { 7 }), 'a fighter shot the spectator watching them')
end)

t.test('and one hit among many is enough to refuse the whole packet', function()
    -- A shotgun names several entities. Letting the packet through because
    -- most of it was legitimate applies the illegitimate part too.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')
    f.spawn(9)
    t.isTrue(f.shoot(1, { 2, 9 }), 'a spread that clipped an outsider was allowed')
end)

-- ======================================================================
-- 3. EXPLOIT: WHAT A HOSTILE CLIENT CAN PUT IN THE PACKET
-- ======================================================================

t.test('EXPLOIT: nothing in the packet can make the guard throw', function()
    -- This handler sits on the path of every shot fired on the server. An
    -- error here is not a refused shot, it is the rest of the handler chain
    -- not running.
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(9)

    local cyclic = { hitGlobalIds = {} }
    cyclic.hitGlobalIds[1] = cyclic

    local hostile = {
        nil, false, 0, -1, '', 'nonsense', {}, { hitGlobalIds = nil },
        { hitGlobalIds = 5 }, { hitGlobalIds = 'x' }, { hitGlobalIds = {} },
        { hitGlobalIds = { nil } }, { hitGlobalIds = { 'x', {}, true } },
        { hitGlobalIds = { 0 / 0 } }, { hitGlobalIds = { math.huge } },
        { hitGlobalIds = { -1, -99999 } },
        { hitGlobalIds = { 2 ^ 60 } },
        cyclic,
        setmetatable({}, { __index = function() error('hostile metatable') end }),
    }

    for index, data in ipairs(hostile) do
        local ok, err = pcall(f.raw, '9', data)
        t.isTrue(ok, ('payload %d took the handler down: %s'):format(index, tostring(err)))
    end

    for _, sender in ipairs({ 'not-a-number', '', '-1', '0', '999999999' }) do
        local ok = pcall(f.raw, sender, { hitGlobalIds = { f.netIds[1] } })
        t.isTrue(ok, ('sender %q took the handler down'):format(sender))
    end
end)

t.test('EXPLOIT: a packet naming thousands of entities is refused, not scanned', function()
    -- The scan is what a payload like this is trying to buy. A shotgun hits
    -- a handful; nothing legitimate hits thirty-two.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')

    local flood = {}
    for index = 1, 5000 do flood[index] = f.netIds[2] end

    local walksBefore = f.walks
    t.isTrue(f.raw('1', { hitGlobalIds = flood }), 'a 5000-entity damage packet was allowed')
    t.equals(f.walks, walksBefore, 'the guard walked the server for a packet it should have refused outright')
end)

t.test('EXPLOIT: a network id nobody owns cannot be used to reach a fighter', function()
    -- Neither direction is a hole: an id that resolves to nobody is not a
    -- player, so there is nothing to protect and nothing to refuse.
    local f = newFixture()
    f.enter(1, 'm1')
    t.isFalse(f.raw('1', { hitGlobalIds = { 987654 } }),
        'a fighter was refused for hitting an entity that is not a player')

    f.spawn(9)
    t.isFalse(f.raw('9', { hitGlobalIds = { 987654 } }),
        'an outsider was refused for hitting an entity that is not a player')
end)

t.test('EXPLOIT: claiming to be another player does not launder the shot', function()
    -- `sender` is the server's own answer for who sent the packet, but the
    -- rule must hold whichever id arrives: the decision is made from the
    -- attacker AND the victim, not from a claim about either alone.
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(9)

    -- 9 pretending to be the fighter, shooting the fighter: still refused,
    -- because the pair is what is judged.
    t.isFalse(f.raw('1', { hitGlobalIds = { f.netIds[1] } }), 'self-damage stopped being allowed')
    t.isTrue(f.raw('9', { hitGlobalIds = { f.netIds[1] } }), 'an outsider reached a fighter')
end)

-- ======================================================================
-- 4. EDGES
-- ======================================================================

t.test('a player who leaves the match stops being shootable by it', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')
    t.isFalse(f.shoot(1, { 2 }))

    f.D.Clear(2)
    t.isTrue(f.shoot(1, { 2 }), 'a fighter could still shoot somebody who has left the round')
end)

t.test('and a respawned ped is followed rather than cached', function()
    -- A ped's network id changes when the player respawns. A cache alone
    -- goes stale in exactly the situation this guard runs in, and it does
    -- not fail safe in one direction: the wrong answer either lets an
    -- outsider through or cancels damage inside a legitimate round.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')
    t.isFalse(f.shoot(1, { 2 }), 'the round could not fight before the respawn')

    -- Player 2 dies and comes back with a new ped.
    f.netIds[2] = 91234
    t.isFalse(f.shoot(1, { 2 }), 'the round could not fight after a respawn')

end)

t.test('and a network id that changes hands does not carry the old owner\'s rights', function()
    -- THE CASE THE VERIFICATION EXISTS FOR, and the reason a plain cache is
    -- not good enough.
    --
    -- Ped network ids are recycled. Once a fighter's id has been looked up
    -- and remembered, that same id being handed to somebody who walked in
    -- off the street means a cached answer says "in the match" about a
    -- passer-by -- and the guard waves the shot through. So the cached
    -- answer is confirmed against the world before it is used.
    local f = newFixture()
    f.enter(1, 'm1')
    f.enter(2, 'm1')

    local recycled = f.netIds[2]
    t.isFalse(f.shoot(1, { 2 }), 'the round could not fight, so nothing was cached')

    -- Player 2 respawns onto a new ped, and an outsider inherits the id 2
    -- used to hold.
    f.netIds[2] = 91234
    f.netIds[9] = recycled

    t.isTrue(f.raw('1', { hitGlobalIds = { recycled } }),
        'a fighter shot an outsider who had inherited a teammate\'s network id')
    t.isFalse(f.shoot(1, { 2 }), 'the fighter could no longer reach their actual opponent')
end)

t.test('an empty hit list refuses nothing', function()
    local f = newFixture()
    f.enter(1, 'm1')
    t.isFalse(f.raw('9', { hitGlobalIds = {} }))
end)

-- ======================================================================
-- 5. COST WHEN NOTHING IS RUNNING
-- ======================================================================

t.test('with no match anywhere the guard does no work at all', function()
    -- It is on the path of every shot fired on the server, and a server
    -- spends almost all of its time with no round running.
    local f = newFixture()
    f.spawn(8)
    f.spawn(9)

    local before = f.walks
    for _ = 1, 200 do f.shoot(8, { 9 }) end

    t.equals(f.walks, before, 'the guard walked the player list with nobody in an arena')
    t.isFalse(f.cancelled)
end)

-- ======================================================================
-- 6. EXPLOSIONS
-- ======================================================================

t.test('an explosion from outside cannot land in a live arena', function()
    -- The one weapon whose reach does not care whether you can see what you
    -- are hitting.
    local f = newFixture()
    f.enter(1, 'm1')
    f.env.ArenaLobby = { Get = function() return { arenaKey = 'trailerpark' } end }
    t.isTrue(f.explode(9, PARK.x, PARK.y, PARK.z), 'an explosion landed in a live round from outside')
end)

t.test('and one from a fighter inside it is theirs to throw', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.env.ArenaLobby = { Get = function() return { arenaKey = 'trailerpark' } end }
    t.isFalse(f.explode(1, PARK.x, PARK.y, PARK.z), 'a fighter could not use a grenade in their own round')
end)

t.test('and an explosion nowhere near an arena is nobody\'s business', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.env.ArenaLobby = { Get = function() return { arenaKey = 'trailerpark' } end }
    t.isFalse(f.explode(9, PARK.x + 5000.0, PARK.y + 5000.0, PARK.z),
        'an explosion on the far side of the map was cancelled')
end)

t.test('and the arena in the sky is guarded the same way', function()
    -- Worth stating separately: its boundary is a sphere a kilometre up, and
    -- the check is on x/y only. A grenade thrown at the trailer park's
    -- coordinates must not be refused for being inside the skydome, and one
    -- thrown at the skydome's must be.
    local f = newFixture()
    f.enter(1, 'm1')
    f.env.ArenaLobby = { Get = function() return { arenaKey = 'skydome' } end }

    t.isTrue(f.explode(9, SKY.x, SKY.y, SKY.z), 'an explosion landed in the sky arena from outside')
    t.isFalse(f.explode(9, PARK.x, PARK.y, PARK.z),
        'an explosion at the trailer park was refused by the sky arena a kilometre away')
end)

t.test('and a malformed explosion packet cannot take the handler down', function()
    local f = newFixture()
    f.enter(1, 'm1')
    f.env.ArenaLobby = { Get = function() return { arenaKey = 'trailerpark' } end }
    for _, args in ipairs({ { nil, nil, nil }, { 'x', 'y', 'z' }, { 0 / 0, 0 / 0, 0 / 0 } }) do
        t.isTrue(pcall(f.explode, 9, args[1], args[2], args[3]), 'a malformed explosion took the handler down')
    end
end)

-- ======================================================================
-- 7. THE SWITCH
-- ======================================================================

t.test('switching the guard off restores the old behaviour exactly', function()
    -- An operator who does not want it gets the bucket alone, which is what
    -- shipped before this existed.
    local f = newFixture({ guard = false })
    f.enter(1, 'm1')
    f.spawn(9)
    t.isFalse(f.shoot(9, { 1 }), 'the guard ran with its setting off')
    t.isFalse(f.shoot(1, { 9 }), 'the guard ran with its setting off')
end)

t.test('and it ships ON, because the setting is opt-out', function()
    local env = Sandbox.newArenaEnv()
    local guard = env.Config.Match.crossfireGuard
    t.isNotNil(guard, 'the setting is gone from config.lua')
    t.isTrue(guard.enabled ~= false, 'the crossfire guard does not ship on')
end)

-- ======================================================================
-- 8. IT SAYS WHAT IT DID
-- ======================================================================

t.test('a refusal is written down, so an operator can see it happening', function()
    -- A guard that silently eats damage is indistinguishable from a bug in
    -- somebody's weapon script.
    local f = newFixture()
    f.enter(1, 'm1')
    f.spawn(9)
    f.shoot(9, { 1 })

    t.isTrue(table.concat(f.debugs, '\n'):find('crossfire', 1, true) ~= nil,
        'a shot was refused and nothing was written down')
end)

os.exit(t.summary())
