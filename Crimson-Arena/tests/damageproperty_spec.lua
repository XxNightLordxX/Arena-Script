--[[
    crimson_arena/tests/damageproperty_spec.lua

    THE DAMAGE GUARD, AGAINST GENERATED WORLDS RATHER THAN CHOSEN ONES.

    Every other spec in this suite is example-based: a case is written down,
    the answer is written beside it, and the pair is checked. That method has
    one weakness which is not a matter of care -- the cases are chosen by
    whoever wrote them, so it cannot find the case nobody thought of. This
    guard has now been wrong twice in exactly that gap:

      FRIENDLY FIRE never refused a shot. Arena.CanDamage was correct and had
      a passing unit test; nothing called it from the damage path.

      AND THE FIX FOR IT made a spread that clipped a teammate cancel the
      whole packet, so standing next to a teammate made a player immune to
      every shotgun in the arena. The suite was green through both.

    So this file chooses nothing. It generates thousands of servers -- two
    concurrent matches, spectators, passers-by, both friendlyFire settings,
    packets naming one to four victims -- and asserts INVARIANTS that must
    hold in every one of them, in both directions:

      NOTHING GETS IN that is not in the attacker's own round.
      NOTHING LAWFUL IS LOST because something unlawful shared its packet.

    The second is the one an example-based test kept missing, because it is a
    property of the packet rather than of a pair of players.

    Seeded, so a failure is reproducible rather than a story about a run that
    happened once.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('damageproperty_spec')

--- A whole modelled server with the REAL server/dispatch.lua loaded into it.
--- @param friendlyFire boolean
local function newServer(friendlyFire)
    local handlers = {}
    local f = { cancelled = false, netIds = {} }

    local env = Sandbox.newEnv({
        GetPlayers = function()
            local out = {}
            for src in pairs(f.netIds) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        NetworkGetNetworkIdFromEntity = function(ped)
            return f.netIds[(tonumber(ped) or 0) - 1000] or 0
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

        Player = function() return { state = { set = function() end } } end,
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
        ArenaDebug = function() end,
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.enableAllArenas(env)
    -- And the doors, for the same reason the fixture does it: this spec
    -- is about routing buckets, not about what time it is.
    Sandbox.openTheDoors(env)
    env.Config.Teams.friendlyFire = friendlyFire
    Sandbox.loadInto('../shared/arena.lua', env)
    Sandbox.loadInto('../server/dispatch.lua', env)

    f.env, f.D, f.handlers = env, env.ArenaDispatch, handlers
    return f
end

--- One generated world, played out and judged.
--- @param seed integer
--- @return table report -- { cancelled, thrown, violations = { string } }
local function round(seed)
    math.randomseed(seed)

    local friendlyFire = math.random() < 0.5
    local s = newServer(friendlyFire)
    local mode = ({ 'tdm', 'ffa' })[math.random(2)]
    local report = { violations = {} }

    -- THREE KINDS OF PERSON, because the guard answers differently for each
    -- and the interesting cases are the ones where a packet mixes them.
    --   a FIGHTER  is flagged into a match AND on its roster
    --   a WATCHER  is flagged into a match and NOT on its roster -- which is
    --              exactly what syncMatchBuckets produces for a spectator
    --   a PASSER-BY is not flagged at all
    local matchOf, teamOf, roster = {}, {}, {}
    for src = 1, math.random(2, 9) do
        s.netIds[src] = 5000 + src
        local roll = math.random()
        if roll < 0.55 then
            local id = math.random() < 0.75 and 'm1' or 'm2'
            s.D.Set(src, id)
            matchOf[src] = id
            teamOf[src] = ({ 'crimson', 'ash' })[math.random(2)]
            if id == 'm1' then roster[src] = { team = teamOf[src] } end
        elseif roll < 0.7 then
            s.D.Set(src, 'm1')
            matchOf[src] = 'm1'
        end
    end

    s.env.ArenaLobby = {
        Get = function(id)
            if id ~= 'm1' then return nil end
            return { modeKey = mode, players = roster }
        end,
    }

    local attacker = math.random(1, 9)
    if not s.netIds[attacker] then return report end

    local victims, hits = {}, {}
    for _ = 1, math.random(1, 4) do
        local v = math.random(1, 9)
        if s.netIds[v] then
            victims[#victims + 1] = v
            hits[#hits + 1] = s.netIds[v]
        end
    end

    s.cancelled = false
    for _, fn in ipairs(s.handlers['weaponDamageEvent'] or {}) do
        local ok, err = pcall(fn, tostring(attacker), { hitGlobalIds = hits })
        if not ok then
            report.thrown = tostring(err)
            return report
        end
    end
    report.cancelled = s.cancelled

    local function violate(fmt, ...)
        report.violations[#report.violations + 1] =
            ('seed %d: %s'):format(seed, select('#', ...) > 0 and fmt:format(...) or fmt)
    end

    local attackerMatch = matchOf[attacker]

    -- INVARIANT 1 -- NOTHING FROM OUTSIDE THE ROUND GETS IN, and it does not
    -- bend for the rest of the packet. A passer-by, another match, or the
    -- spectator watching from inside the instance: any of them named in the
    -- packet takes the whole packet down.
    for _, v in ipairs(victims) do
        if v ~= attacker then
            local victimMatch = matchOf[v]
            local crossedTheLine = (attackerMatch ~= nil or victimMatch ~= nil)
                and (attackerMatch == nil or attackerMatch ~= victimMatch)
            local watching = attackerMatch ~= nil and attackerMatch == victimMatch
                and attackerMatch == 'm1'
                and (roster[attacker] == nil or roster[v] == nil)

            if (crossedTheLine or watching) and not report.cancelled then
                violate('%s may not damage %s and was allowed to', tostring(attacker), tostring(v))
            end
        end
    end

    -- INVARIANT 2 -- A LAWFUL HIT IS NEVER LOST to a refusal in the same
    -- packet. This is the shotgun-immunity regression, stated as a property:
    -- with an enemy the attacker is allowed to hit, and nobody from outside
    -- the round in the packet, the shot must land whatever else it touched.
    if attackerMatch ~= nil and roster[attacker] ~= nil then
        local anyOutsider, anyLawful = false, false
        for _, v in ipairs(victims) do
            if v ~= attacker then
                if matchOf[v] ~= attackerMatch or roster[v] == nil then
                    anyOutsider = true
                elseif s.env.Arena.CanDamage(mode, roster[attacker].team, roster[v].team) then
                    anyLawful = true
                end
            end
        end
        if anyLawful and not anyOutsider and report.cancelled then
            violate('a packet with a lawful enemy in it was cancelled -- '
                .. 'standing near a teammate makes you spread-proof')
        end

        -- INVARIANT 3 -- AIMING AT YOUR OWN SIDE IS REFUSED, which is the
        -- report this guard was extended for: "i am still able to shoot my
        -- teammates".
        --
        -- ADDED AFTER A MUTANT SURVIVED. The two invariants above are both
        -- about what must NOT be lost, and a guard that consults the teams
        -- not at all satisfies them both -- deleting the Arena.CanDamage call
        -- outright left this file green. An invariant that only ever says
        -- "let it through" cannot fail a guard that always lets things
        -- through.
        --
        -- Every victim on the attacker's own side, nobody else in the packet,
        -- friendlyFire off, a mode that has sides at all: that shot must not
        -- land, and the packet is the only thing the engine lets us refuse.
        if not friendlyFire and s.env.Arena.ModeUsesTeams(mode) then
            local hitSomeone, allTeammates = false, true
            for _, v in ipairs(victims) do
                if v ~= attacker then
                    hitSomeone = true
                    if roster[v] == nil or roster[v].team ~= roster[attacker].team then
                        allTeammates = false
                    end
                end
            end
            if hitSomeone and allTeammates and not report.cancelled then
                violate('a packet naming nothing but teammates was allowed with '
                    .. 'friendlyFire off')
            end
        end
    end

    return report
end

-- ======================================================================
-- THE SWEEP
-- ======================================================================

t.test('across 2000 generated worlds, no shot crosses the line and no lawful shot is lost', function()
    local cancelled, allowed, violations = 0, 0, {}

    for seed = 1, 2000 do
        local report = round(seed)
        t.isNil(report.thrown, ('the handler threw: %s'):format(tostring(report.thrown)))
        if report.cancelled then cancelled = cancelled + 1 else allowed = allowed + 1 end
        for _, v in ipairs(report.violations) do violations[#violations + 1] = v end
    end

    -- BOTH BRANCHES HAVE TO BE REACHED or the sweep proves nothing: a guard
    -- that cancels everything satisfies invariant 1, and one that cancels
    -- nothing satisfies invariant 2.
    t.isTrue(cancelled > 200, ('only %d of 2000 packets were refused -- the sweep is not '
        .. 'reaching the refusing branch'):format(cancelled))
    t.isTrue(allowed > 200, ('only %d of 2000 packets were allowed -- the sweep is not '
        .. 'reaching the allowing branch'):format(allowed))

    t.equals(#violations, 0, (#violations > 0 and violations[1] or 'no violations'))
end)

t.test('and nothing a hostile client can put in a packet makes it throw', function()
    -- The handler sits on the path of every shot fired on the server, so an
    -- error here is not a refused shot -- it is the rest of the handler chain
    -- not running. Generated payloads rather than a list somebody wrote.
    math.randomseed(99)
    local s = newServer(false)
    s.netIds[1] = 5001
    s.D.Set(1, 'm1')
    s.env.ArenaLobby = { Get = function() return { modeKey = 'tdm', players = { [1] = { team = 'crimson' } } } end }

    local pieces = { 0, -1, 1 / 0, -1 / 0, 0 / 0, '', 'x', true, false, {}, 5001, 2 ^ 60 }

    for round_ = 1, 500 do
        local hits = {}
        for _ = 1, math.random(0, 6) do hits[#hits + 1] = pieces[math.random(#pieces)] end

        local data
        local shape = math.random(4)
        if shape == 1 then data = { hitGlobalIds = hits }
        elseif shape == 2 then data = { hitGlobalIds = pieces[math.random(#pieces)] }
        elseif shape == 3 then data = pieces[math.random(#pieces)]
        else data = nil end

        local sender = ({ '1', '9', '', 'nope', '-1', nil })[math.random(6)]
        for _, fn in ipairs(s.handlers['weaponDamageEvent'] or {}) do
            local ok, err = pcall(fn, sender, data)
            t.isTrue(ok, ('payload %d took the handler down: %s'):format(round_, tostring(err)))
        end
    end
end)

os.exit(t.summary())
