--[[
    crimson_arena/tests/blastreach_spec.lua

    THE EXPLOSION GUARD READS A POSITION ONLY WHEN IT COULD MATTER.

    server/dispatch.lua refuses a blast that would catch a team-mate and no
    lawful victim. It used to find that out by reading EVERY other fighter's
    position -- a pcall'd GetPlayerPed and a pcall'd GetEntityCoords each,
    sixty-two natives for one grenade in a thirty-two fighter round -- and
    only then asking whose side each one was on. In a free-for-all nobody is
    anybody's team-mate, so that walk could never refuse anything, and it
    paid in full on every blast. All thirteen heavy weapons ship enabled.

    It asks the team question first now, and reads a position only for a row
    the team question cannot settle alone. This file holds that in three
    ways:

      THE RULE, pinned case by case: a blast that catches only a team-mate is
      refused; one that also catches an enemy goes through whole (the bend);
      the distance is a sphere, with the flat reading when either point has
      no z; the eliminated, the departed, the unplaceable and the watching
      count for nothing; the edge of the blast is inside it.

      THE COST, counted on the stubs: nobody's position is read in a
      free-for-all, a gun game or a team round with friendly fire on, and a
      team round reads what the answer needs and never more than the old
      walk did. A later edit that puts the distance test back in front of
      the team test fails here, not on a live server under a launcher.

      THE OLD GUARD, KEPT BELOW VERBATIM and run against the same worlds as
      the real one: seeded, deterministic, hundreds of rounds of modes,
      teams, friendly fire, heights, the eliminated, the departed and the
      watching. Every decision and every log line must match.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('blastreach_spec')

--- Whole-number blast points, so a fighter six and eight metres off is
--- EXACTLY ten away and the edge of the blast can be tested on both sides
--- without float noise deciding it. Inside the trailer park's arena.
local BX, BY, BZ = 2344.0, 2565.0, 46.0

--- A server/dispatch.lua with one live match, every native the explosion
--- path touches counted.
local function newFixture()
    local handlers = {}
    local buckets = {}
    local f = {
        cancelled = false,
        debugs = {},
        --- src -> nil for an ordinary ped, or 'throw' | 'nil' | 'zero'.
        pedMode = {},
        --- src -> what GetEntityCoords answers for that player's ped: a
        --- point, or 'throw' | 'nil'. Unset is the map origin, far away.
        at = {},
        pedCalls = 0,
        coordCalls = 0,
        pedCallsBySrc = {},
    }

    local env = Sandbox.newEnv({
        GetPlayers = function() return {} end,
        GetPlayerPed = function(src)
            local n = tonumber(src) or 0
            f.pedCalls = f.pedCalls + 1
            f.pedCallsBySrc[n] = (f.pedCallsBySrc[n] or 0) + 1
            local mode = f.pedMode[n]
            if mode == 'throw' then error('no such player') end
            if mode == 'nil' then return nil end
            if mode == 'zero' then return 0 end
            return 1000 + n
        end,
        GetEntityCoords = function(ped)
            f.coordCalls = f.coordCalls + 1
            local at = f.at[(tonumber(ped) or 0) - 1000]
            if at == 'throw' then error('entity is gone') end
            if at == 'nil' then return nil end
            if at == nil then return { x = 0.0, y = 0.0, z = 0.0 } end
            return at
        end,
        NetworkGetNetworkIdFromEntity = function() return 0 end,
        CancelEvent = function() f.cancelled = true end,

        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
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
        ArenaDebug = function(fmt, ...)
            f.debugs[#f.debugs + 1] = select('#', ...) > 0 and fmt:format(...) or fmt
        end,
    })

    Sandbox.loadInto('../Crimson-Arena/config.lua', env)
    Sandbox.enableAllArenas(env)
    Sandbox.openTheDoors(env)
    Sandbox.loadInto('../Crimson-Arena/shared/arena.lua', env)
    Sandbox.loadInto('../Crimson-Arena/server/dispatch.lua', env)

    f.env = env
    f.D = env.ArenaDispatch

    --- src -> the match id it was flagged into, so a world can be torn down.
    f.flagged = {}

    function f.flag(src, matchId)
        f.D.Set(src, matchId, true)
        f.flagged[src] = matchId
    end

    function f.unflagAll()
        for src in pairs(f.flagged) do f.D.Clear(src) end
        f.flagged = {}
    end

    --- The rounds the lobby answers for, by match id.
    f.matches = {}
    env.ArenaLobby = {
        Get = function(id) return f.matches[id] end,
    }

    --- One team round the way server/lobby.lua holds it, every fighter
    --- flagged. `teams` is [src] = teamKey.
    function f.round(modeKey, teams, matchId)
        matchId = matchId or 'm1'
        local players = {}
        for src, team in pairs(teams) do
            players[src] = { src = src, team = team, alive = true, lives = 3 }
            f.flag(src, matchId)
        end
        f.matches[matchId] = { modeKey = modeKey, players = players, arenaKey = 'trailerpark' }
        return players
    end

    function f.stand(src, x, y, z)
        f.at[src] = { x = x, y = y, z = z }
    end

    function f.resetCounts()
        f.pedCalls, f.coordCalls, f.pedCallsBySrc = 0, 0, {}
    end

    --- Fires the engine's explosion packet, counting from zero.
    --- @return boolean cancelled
    function f.explode(sender, x, y, z)
        f.cancelled = false
        f.debugs = {}
        f.resetCounts()
        local data = { posX = x, posY = y, posZ = z }
        for _, fn in ipairs(handlers['explosionEvent'] or {}) do
            fn(sender ~= nil and tostring(sender) or nil, data)
        end
        return f.cancelled
    end

    return f
end

--- The line the handler writes when it refuses a blast from its own round.
local function refusedLine(sender, reason)
    return ('crossfire: refused an explosion from %s -- %s.'):format(tostring(sender), reason)
end

local TEAM_REASON = 'it would land on their own team and friendly fire is off'

-- ======================================================================
-- 1. THE RULE
-- ======================================================================

t.test('a blast that catches only a team-mate is refused, and says why', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(1, BX - 20, BY, BZ)
    f.stand(2, BX + 3, BY, BZ)
    f.stand(3, BX + 40, BY, BZ)

    t.isTrue(f.explode(1, BX, BY, BZ), 'a grenade on nobody but a team-mate went through')
    t.equals(f.debugs[#f.debugs], refusedLine(1, TEAM_REASON), 'the refusal stopped saying why')
end)

t.test('and one that also catches an enemy goes through whole: the bend', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX + 3, BY, BZ)
    f.stand(3, BX - 3, BY, BZ)

    t.isFalse(f.explode(1, BX, BY, BZ), 'standing next to a team-mate made an enemy launcher-proof')
    for _, line in ipairs(f.debugs) do
        t.isTrue(line:find('refused', 1, true) == nil, 'a blast that went through was logged as refused')
    end
end)

t.test('and a blast that catches only enemies goes through', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash', [4] = 'ash' })
    f.stand(2, BX + 40, BY, BZ)
    f.stand(3, BX + 1, BY, BZ)
    f.stand(4, BX, BY + 1, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a grenade on the other side only was refused')
end)

t.test('and a blast that catches nobody at all goes through', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX + 50, BY, BZ)
    f.stand(3, BX - 50, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a grenade on empty ground was refused')
end)

t.test('THE EDGE: a team-mate exactly ten metres off is caught, a hair further is not', function()
    -- Both sides of the one boundary this guard draws. `<=` and not `<`.
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })

    f.stand(2, BX + 6, BY + 8, BZ)          -- 6-8-10, flat
    t.isTrue(f.explode(1, BX, BY, BZ), 'a team-mate on the edge of the blast was not caught')

    f.stand(2, BX + 6, BY, BZ + 8)          -- 6-8-10, half of it height
    t.isTrue(f.explode(1, BX, BY, BZ), 'a team-mate on the edge of the sphere was not caught')

    f.stand(2, BX + 10.001, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a team-mate outside the blast was counted as caught')

    f.stand(2, BX + 6, BY, BZ + 8.001)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a team-mate just above the sphere was counted as caught')

    -- The smallest step past the edge there is. At z = 56 one unit in the
    -- last place is 2^-47, so a team-mate standing on the very next number
    -- above the top of the sphere is 100 plus ONE ulp of 100 away, squared.
    -- A reach widened by any amount that can be represented at all -- a
    -- billionth, a trillionth -- swallows them.
    t.isTrue(BZ + 10 + 2 ^ -47 > BZ + 10 and BZ + 10 + 2 ^ -48 == BZ + 10, 'not one ulp')
    f.stand(2, BX, BY, BZ + 10 + 2 ^ -47)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a team-mate a hair of a hair outside the blast was caught')
end)

t.test('and an enemy exactly ten metres off makes it lawful, a hair further does not', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX, BY, BZ)

    f.stand(3, BX, BY + 10, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'an enemy on the edge of the blast did not count')

    f.stand(3, BX, BY + 6, BZ - 8)
    t.isFalse(f.explode(1, BX, BY, BZ), 'an enemy on the edge of the sphere, below, did not count')

    f.stand(3, BX, BY + 10.001, BZ)
    t.isTrue(f.explode(1, BX, BY, BZ), 'an enemy outside the blast made it lawful')
end)

t.test('THE SPHERE, both ways, and the flat reading when the packet has no z', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })

    -- Team-mate in it, enemy thirty metres straight up: refused.
    f.stand(2, BX + 2, BY, BZ)
    f.stand(3, BX + 2, BY, BZ + 30)
    t.isTrue(f.explode(1, BX, BY, BZ), 'an enemy on a roof made a street-level blast lawful')

    -- And flat, the same two ARE both in it, so it goes through.
    t.isFalse(f.explode(1, BX, BY, nil), 'the flat reading stopped counting the enemy above')

    -- Team-mate thirty metres straight up, alone: not caught.
    f.stand(2, BX + 2, BY, BZ + 30)
    f.stand(3, BX + 50, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a team-mate on a roof had a street-level blast refused')

    -- And flat, they are: refused.
    t.isTrue(f.explode(1, BX, BY, nil), 'the flat reading stopped protecting a team-mate')
end)

t.test('BELOW THE SEA: heights at and under zero are measured like any other', function()
    -- A tunnel, a basement, the sea floor. The height term must not depend
    -- on the sign of either z, the fighter's or the blast's.
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })

    -- Team-mate thirty-five metres straight below a blast at z=5: not caught.
    f.stand(2, BX, BY, -30)
    f.stand(3, BX + 50, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, 5), 'a team-mate in a tunnel below had the blast refused')

    -- Six metres under sea level against a blast five metres above it is
    -- eleven metres of height, not one: a sign dropped anywhere shows here.
    f.stand(2, BX, BY, -6)
    t.isFalse(f.explode(1, BX, BY, 5), 'heights either side of zero were measured as one metre')

    -- And one exactly at z=0, nine metres under: caught.
    f.stand(2, BX, BY, 0)
    t.isTrue(f.explode(1, BX, BY, 9), 'a team-mate at sea level under the blast was not caught')

    -- A blast down in the tunnel, the team-mate on the street above: not caught.
    f.stand(2, BX, BY, 5)
    t.isFalse(f.explode(1, BX, BY, -30), 'a blast in a tunnel refused over a team-mate above it')

    -- Both under zero and close: caught; both under and far apart: not.
    f.stand(2, BX + 1, BY, -32)
    t.isTrue(f.explode(1, BX, BY, -30), 'a team-mate beside an underwater blast was not caught')
    f.stand(2, BX, BY, -60)
    t.isFalse(f.explode(1, BX, BY, -30), 'a team-mate thirty metres further down was caught')
end)

t.test('and west of the map origin, where x and y are negative, too', function()
    -- Five metres either side of x = 0 is ten metres, not none. No shipped
    -- arena sits there, so this round's boundary is moved onto the origin;
    -- the guard itself must not care which quarter of the map it is in.
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.env.Arena.BoundaryOf = function()
        return { center = { x = 0.0, y = -200.0, z = 10.0 }, radius = 500.0 }
    end
    f.stand(2, 5, -300, 10)
    t.isFalse(f.explode(1, -5.5, -300, 10), 'a team-mate across x = 0 was measured as beside the blast')
    t.isTrue(f.explode(1, -5, -300, 10), 'a team-mate exactly ten metres across x = 0 was not caught')
    f.stand(2, -400, 4.5, 10)
    t.isFalse(f.explode(1, -400, -6, 10), 'a team-mate across y = 0 was measured as beside the blast')
end)

t.test('and an enemy far below does not make a blast on a team-mate lawful', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX + 1, BY, 5)
    f.stand(3, BX, BY, -30)
    t.isTrue(f.explode(1, BX, BY, 5), 'an enemy in a tunnel below made the blast lawful')
    f.stand(3, BX, BY, -2)
    t.isFalse(f.explode(1, BX, BY, 5), 'an enemy seven metres below, under zero, did not count')
    f.stand(2, BX + 1, BY, -31)
    f.stand(3, BX, BY, 5)
    t.isTrue(f.explode(1, BX, BY, -30), 'an enemy on the street made a tunnel blast lawful')
end)

t.test('and a coordinate with no z of its own is measured flat too', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.at[2] = { x = BX + 3, y = BY }
    -- Twenty metres above them: out of the sphere, had there been a z.
    t.isTrue(f.explode(1, BX, BY, BZ + 20), 'a position with no z stopped being measured at all')
end)

t.test('and a real vector from the game is read like any other point', function()
    -- GetEntityCoords answers a vector3, which is its own type in this
    -- runtime and never 'table'. pointXY asks Arena.IsPoint for exactly this.
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.at[2] = Sandbox.asVector({ x = BX + 1, y = BY, z = BZ }, 'vector3')
    f.stand(3, BX + 50, BY, BZ)
    t.isTrue(f.explode(1, BX, BY, BZ), 'a team-mate reported as a vector3 was not placed')

    f.at[3] = Sandbox.asVector({ x = BX - 1, y = BY, z = BZ }, 'vector3')
    t.isFalse(f.explode(1, BX, BY, BZ), 'an enemy reported as a vector3 was not placed')
end)

t.test('a free-for-all and a gun game have no sides, whatever colours the rows carry', function()
    for _, mode in ipairs({ 'ffa', 'gungame' }) do
        local f = newFixture()
        f.round(mode, { [1] = 'crimson', [2] = 'crimson' })
        f.stand(2, BX + 1, BY, BZ)
        t.isFalse(f.explode(1, BX, BY, BZ), mode .. ' refused a blast on a same-coloured fighter')
    end
end)

t.test('and friendly fire ON lets the blast through, and so does a mode switched off or unknown', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.stand(2, BX + 1, BY, BZ)

    f.env.Config.Teams.friendlyFire = true
    t.isFalse(f.explode(1, BX, BY, BZ), 'friendlyFire on and a team-mate blast was still refused')

    -- `== true`, not truthiness: anything else is off.
    f.env.Config.Teams.friendlyFire = 'yes'
    t.isTrue(f.explode(1, BX, BY, BZ), 'a non-boolean friendlyFire switched the refusal off')
    f.env.Config.Teams.friendlyFire = false

    f.env.Config.Modes.tdm.enabled = false
    t.isFalse(f.explode(1, BX, BY, BZ), 'a switched-off mode was still read as having teams')
    f.env.Config.Modes.tdm.enabled = true

    f.matches.m1.modeKey = 'no-such-mode'
    t.isFalse(f.explode(1, BX, BY, BZ), 'an unknown mode was read as having teams')
    f.matches.m1.modeKey = nil
    t.isFalse(f.explode(1, BX, BY, BZ), 'a round with no mode was read as having teams')
end)

t.test('a row with no team, or a thrower with none, is nobody\'s team-mate', function()
    -- Arena.CanDamage answers yes for a missing or empty key. So such a row
    -- is a LAWFUL victim, and it bends the rule exactly as an enemy does.
    local f = newFixture()
    local players = f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX + 1, BY, BZ)
    f.stand(3, BX + 50, BY, BZ)
    t.isTrue(f.explode(1, BX, BY, BZ), 'control: the team-mate alone was not refused')

    for _, team in ipairs({ '', 7 }) do
        players[3].team = team
        f.stand(3, BX - 1, BY, BZ)
        t.isFalse(f.explode(1, BX, BY, BZ),
            ('a row with team %q in the blast did not count as lawful'):format(tostring(team)))
    end
    players[3].team = nil
    t.isFalse(f.explode(1, BX, BY, BZ), 'a row with no team in the blast did not count as lawful')

    players[3].team = 'ash'
    f.stand(3, BX + 50, BY, BZ)
    players[1].team = nil
    t.isFalse(f.explode(1, BX, BY, BZ), 'a thrower with no team was given team-mates')
end)

t.test('the eliminated count for nothing, on either side of the rule', function()
    local f = newFixture()
    local players = f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
    f.stand(2, BX + 1, BY, BZ)
    f.stand(3, BX - 1, BY, BZ)

    players[3].alive, players[3].lives = false, 0
    t.isTrue(f.explode(1, BX, BY, BZ), 'an ELIMINATED enemy in the blast made it lawful')

    players[3].alive, players[3].lives = true, 3
    players[2].alive, players[2].lives = false, 0
    f.stand(3, BX + 50, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'an eliminated team-mate was protected from a blast')

    -- BETWEEN LIVES IS NOT OUT: dead for the moment, lives in hand.
    players[2].alive, players[2].lives = false, 2
    t.isTrue(f.explode(1, BX, BY, BZ), 'a team-mate between lives stopped being protected')
end)

t.test('and the thrower is never their own team-mate, wherever they stand', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'ash' })
    f.stand(1, BX, BY, BZ)
    f.stand(2, BX + 50, BY, BZ)
    t.isFalse(f.explode(1, BX, BY, BZ), 'a fighter was refused their own grenade at their own feet')
    t.equals(f.pedCallsBySrc[1], nil, 'the thrower\'s own position was read')
end)

t.test('a fighter who cannot be placed is in no blast, on either side', function()
    -- Departed mid-round, a ped of 0, a native that throws, coordinates that
    -- are not a point: all of them read as "not here", which is what
    -- positionOf and pointXY have always answered, and none takes the
    -- handler down.
    local unplaceable = {
        { ped = 'zero' }, { ped = 'nil' }, { ped = 'throw' },
        { at = 'throw' }, { at = 'nil' }, { at = { x = 'abc', y = BY, z = BZ } }, { at = 7 },
    }
    for index, how in ipairs(unplaceable) do
        local f = newFixture()
        f.round('tdm', { [1] = 'crimson', [2] = 'crimson', [3] = 'ash' })
        f.pedMode[2] = how.ped
        f.at[2] = how.at or { x = BX + 1, y = BY, z = BZ }
        f.stand(3, BX + 50, BY, BZ)
        local ok, cancelled = pcall(f.explode, 1, BX, BY, BZ)
        t.isTrue(ok, ('unplaceable team-mate %d took the handler down'):format(index))
        t.isFalse(cancelled, ('unplaceable team-mate %d was counted as caught'):format(index))

        -- And an unplaceable ENEMY does not make a team-mate's blast lawful.
        f.pedMode[2], f.at[2] = nil, { x = BX + 1, y = BY, z = BZ }
        f.pedMode[3] = how.ped
        f.at[3] = how.at or { x = BX - 1, y = BY, z = BZ }
        ok, cancelled = pcall(f.explode, 1, BX, BY, BZ)
        t.isTrue(ok, ('unplaceable enemy %d took the handler down'):format(index))
        t.isTrue(cancelled, ('unplaceable enemy %d made the blast lawful'):format(index))
    end
end)

t.test('a coordinate whose numbers arrive as text is still measured', function()
    -- pointXY runs tonumber over x, y and z, so a string that IS a number is
    -- a position. Pinned because it is what both versions of the walk do.
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.at[2] = { x = tostring(BX + 2), y = tostring(BY), z = tostring(BZ) }
    t.isTrue(f.explode(1, BX, BY, BZ), 'a team-mate whose coordinates came as text was not caught')
end)

t.test('somebody watching the round is not on its roster, and does not bend it', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.flag(7, 'm1')                          -- flagged, in the instance, not fighting
    f.stand(2, BX + 1, BY, BZ)
    f.stand(7, BX - 1, BY, BZ)
    t.isTrue(f.explode(1, BX, BY, BZ), 'a spectator in the blast made a team-mate blast lawful')
    t.equals(f.pedCallsBySrc[7], nil, 'a spectator\'s position was read by the roster walk')
end)

t.test('and a fighter from ANOTHER round does not bend it either', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.round('tdm', { [8] = 'ash' }, 'm2')
    f.stand(2, BX + 1, BY, BZ)
    f.stand(8, BX - 1, BY, BZ)
    t.isTrue(f.explode(1, BX, BY, BZ), 'a fighter in the round next door made the blast lawful')
end)

t.test('the watching and the eliminated may not throw at all, and are told apart', function()
    local f = newFixture()
    local players = f.round('tdm', { [1] = 'crimson', [2] = 'ash' })
    f.flag(7, 'm1')

    t.isTrue(f.explode(7, BX, BY, BZ), 'a spectator set off an explosion in the round')
    t.equals(f.debugs[#f.debugs], refusedLine(7, 'they are watching rather than fighting'))

    players[1].alive, players[1].lives = false, 0
    t.isTrue(f.explode(1, BX, BY, BZ), 'an eliminated fighter set off an explosion in the round')
    t.equals(f.debugs[#f.debugs], refusedLine(1, 'the thrower is out of the round'))
end)

t.test('a lobby that has not answered with a roster fails open', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.stand(2, BX + 1, BY, BZ)
    f.matches.m1.players = nil
    t.isFalse(f.explode(1, BX, BY, BZ), 'a missing roster refused a blast')
    f.matches.m1.players = 'not a roster'
    t.isFalse(f.explode(1, BX, BY, BZ), 'a garbage roster refused a blast')
    t.equals(f.pedCalls, 0, 'a position was read with no roster to read it for')
end)

t.test('switching the guard off refuses nothing and reads nothing', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.stand(2, BX + 1, BY, BZ)
    f.env.Config.Match.crossfireGuard = { enabled = false }
    t.isFalse(f.explode(1, BX, BY, BZ), 'the guard refused a blast with its setting off')
    t.equals(f.pedCalls, 0, 'the guard read positions with its setting off')
end)

t.test('SERVER IDS ARE NOT A SEQUENCE: a team-mate at id 17 is found', function()
    -- `match.players` is keyed by server id, so the walk is pairs. ipairs
    -- over { [3], [17], [40] } walks nobody at all, and every id-1-2-3 test
    -- above would still pass.
    local f = newFixture()
    f.round('tdm', { [3] = 'crimson', [17] = 'crimson', [40] = 'ash' })
    f.stand(17, BX + 1, BY, BZ)
    f.stand(40, BX + 50, BY, BZ)
    t.isTrue(f.explode(3, BX, BY, BZ), 'a team-mate at a server id above the first was never looked at')

    f.stand(40, BX - 1, BY, BZ)
    t.isFalse(f.explode(3, BX, BY, BZ), 'an enemy at a server id above the first was never looked at')
end)

t.test('a malformed or hostile explosion packet cannot take the handler down', function()
    local f = newFixture()
    f.round('tdm', { [1] = 'crimson', [2] = 'crimson' })
    f.stand(2, BX + 1, BY, BZ)
    for _, args in ipairs({ { nil, nil, nil }, { 'x', 'y', 'z' }, { 0 / 0, 0 / 0, 0 / 0 },
        { BX, BY, 'high' }, { math.huge, BY, BZ }, { BX, -math.huge, BZ } }) do
        t.isTrue(pcall(f.explode, 1, args[1], args[2], args[3]), 'a malformed explosion took the handler down')
    end
    for _, sender in ipairs({ 'nope', '', '-1', '0', '99999999' }) do
        t.isTrue(pcall(f.explode, sender, BX, BY, BZ), ('sender %q took the handler down'):format(sender))
    end
end)

-- ======================================================================
-- 2. THE COST, COUNTED
--
-- Every position is a pcall'd GetPlayerPed and a pcall'd GetEntityCoords.
-- These are the numbers the change was made for, and a later edit that
-- puts the distance test back in front of the team test lands here.
-- ======================================================================

--- A 32-fighter round, everybody standing in the blast. `teamOf(src)`
--- decides the sides; the thrower is server id 1.
local function crowd(mode, teamOf)
    local f = newFixture()
    local teams = {}
    for src = 1, 32 do teams[src] = teamOf(src) end
    f.round(mode, teams)
    for src = 1, 32 do f.stand(src, BX + (src % 5), BY - (src % 3), BZ) end
    return f
end

local function halves(src) return src % 2 == 1 and 'crimson' or 'ash' end

t.test('COST: a 32-fighter free-for-all blast reads nobody\'s position', function()
    local f = crowd('ffa', function() return 'crimson' end)
    t.isFalse(f.explode(1, BX, BY, BZ))
    t.equals(f.pedCalls, 0, 'GetPlayerPed calls on one free-for-all blast (the old walk made 31)')
    t.equals(f.coordCalls, 0, 'GetEntityCoords calls on one free-for-all blast (the old walk made 31)')
end)

t.test('COST: nor does a gun game, nor a team round with friendly fire on', function()
    local g = crowd('gungame', halves)
    t.isFalse(g.explode(1, BX, BY, BZ))
    t.equals(g.pedCalls, 0, 'GetPlayerPed calls on one gun game blast')

    local f = crowd('tdm', halves)
    f.env.Config.Teams.friendlyFire = true
    t.isFalse(f.explode(1, BX, BY, BZ))
    t.equals(f.pedCalls, 0, 'GetPlayerPed calls on one friendly-fire-on blast')
end)

t.test('COST: a 16-a-side blast that catches both sides reads two positions, 62 natives down to 4', function()
    local f = crowd('tdm', halves)
    t.isFalse(f.explode(1, BX, BY, BZ), 'the bend stopped working in a crowd')
    t.equals(f.pedCalls + f.coordCalls, 4, 'natives on one mixed blast (the old walk made 62)')
end)

t.test('COST: a team blast with no team-mate near reads the team-mates and nobody else', function()
    local f = crowd('tdm', halves)
    for src = 3, 31, 2 do f.stand(src, BX + 60, BY, BZ) end   -- every team-mate away
    t.isFalse(f.explode(1, BX, BY, BZ))
    t.equals(f.pedCalls, 15, 'positions read: only the 15 team-mates can decide it (the old walk read 31)')
    for src = 2, 32, 2 do
        t.equals(f.pedCallsBySrc[src], nil, ('an enemy\'s position (%d) was read for nothing'):format(src))
    end
end)

t.test('COST, THE WORST CASE: team-mates caught and no enemy near is still no worse than the old walk', function()
    local f = crowd('tdm', halves)
    for src = 2, 32, 2 do f.stand(src, BX + 60, BY, BZ) end   -- every enemy away
    t.isTrue(f.explode(1, BX, BY, BZ), 'a crowd of team-mates alone was not protected')
    -- One team-mate to find the first, then every enemy to rule the bend out.
    t.equals(f.pedCalls, 17, 'positions read on the worst-case blast')
    t.isTrue(f.pedCalls <= 31, 'the worst case read more than the old walk did')
end)

t.test('and no fighter\'s position is read twice on one blast', function()
    for _, spread in ipairs({ 0, 60 }) do
        local f = crowd('tdm', halves)
        for src = 2, 32, 2 do f.stand(src, BX + spread, BY, BZ) end
        f.explode(1, BX, BY, BZ)
        for src, calls in pairs(f.pedCallsBySrc) do
            t.isTrue(calls <= 1, ('fighter %d was placed %d times on one blast'):format(src, calls))
        end
    end
end)

-- ======================================================================
-- 3. THE OLD GUARD, VERBATIM, AGAINST THE NEW ONE
--
-- The walk exactly as it shipped before the team question moved in front
-- of the position read, loaded into the SAME sandbox as the real file so it
-- calls the same stubbed natives and the same Arena helpers. pointXY and
-- positionOf are copied with it so the reference owes nothing to the file
-- under test.
-- ======================================================================

local OLD_GUARD = [==[
local BLAST_METRES = 10.0

local function pointXY(point)
    if not Arena.IsPoint(point) then return nil end
    local px, py = tonumber(point.x), tonumber(point.y)
    if not px or not py then return nil end
    return px, py, tonumber(point.z)
end

local function positionOf(src)
    local ok, ped = pcall(GetPlayerPed, src)
    if not ok or not ped or ped == 0 then return nil end

    local gotIt, coords = pcall(GetEntityCoords, ped)
    if not gotIt then return nil end
    return coords
end

local function explosionRefusal(exploder, matchId, px, py, pz)
    local match = ArenaLobby and ArenaLobby.Get and ArenaLobby.Get(matchId)
    if type(match) ~= 'table' or type(match.players) ~= 'table' then return nil end

    local thrower = match.players[exploder]
    if thrower == nil then return 'they are watching rather than fighting' end
    if Arena.IsEliminated(thrower) then return 'the thrower is out of the round' end

    local reach = BLAST_METRES * BLAST_METRES
    local caught, lawful = false, false

    for src, row in pairs(match.players) do
        if src ~= exploder and not Arena.IsEliminated(row) then
            local at = positionOf(src)
            if at then
                local x, y, z = pointXY(at)
                if x then
                    local dx, dy = x - px, y - py
                    local squared = dx * dx + dy * dy
                    if z and pz then
                        local dz = z - pz
                        squared = squared + dz * dz
                    end
                    if squared <= reach then
                        if Arena.CanDamage(match.modeKey, thrower.team, row.team) then
                            lawful = true
                        else
                            caught = true
                        end
                    end
                end
            end
        end
    end

    if caught and not lawful then
        return 'it would land on their own team and friendly fire is off'
    end
    return nil
end

return explosionRefusal
]==]

--- A small seeded generator, so every run draws the same worlds. Not
--- math.random: its sequence is the interpreter's business, this one is
--- written down.
local function newRng(seed)
    local state = seed
    local rng = {}
    function rng.int(lo, hi)
        state = (state * 1103515245 + 12345) % 2147483648
        return lo + (state // 65536) % (hi - lo + 1)
    end
    function rng.chance(percent) return rng.int(1, 100) <= percent end
    function rng.pick(list) return list[rng.int(1, #list)] end
    return rng
end

local NONE = {}
local function orNil(value) if value == NONE then return nil end return value end

local MODES = { 'tdm', 'tdm', 'tdm', 'tdm', 'tdm', 'tdm', 'ffa', 'gungame', 'no-such-mode', NONE }
local TEAMS = { 'crimson', 'crimson', 'crimson', 'ash', 'ash', 'ash', 'jade', NONE, '', 7 }
--- A round of two ordinary sides, one heavier than the other.
local TWO_SIDES = { 'crimson', 'crimson', 'ash' }
local STATES = {
    { alive = true, lives = 3 }, { alive = true, lives = 3 }, { alive = true, lives = 3 },
    { alive = true, lives = 3 }, { alive = true, lives = 1 },
    { alive = false, lives = 0 },            -- eliminated
    { alive = false, lives = 2 },            -- between lives, still in it
    { alive = true, lives = 0 },             -- last life, standing
    { alive = NONE, lives = NONE },          -- a row with neither: reads as out
    { alive = false, lives = '1' },          -- a count that arrived as text
}
local OFFSETS_XY = { 0, 0, 1, 3, 6, 8, 10, -6, -8, 9, 11, 25 }
local OFFSETS_Z = { 0, 0, 0, 0, 2, -2, 8, -8, 6, 10, 30, -40 }

--- Where one fighter stands, in every shape the game or a broken read can
--- hand back.
local function placeSomebody(rng, f, src, px, py, pz, farPercent)
    if rng.chance(farPercent) then
        f.at[src] = { x = px + 60 + rng.int(0, 40), y = py - rng.int(0, 40), z = BZ }
        f.pedMode[src] = nil
        return
    end
    local x = px + rng.pick(OFFSETS_XY)
    local y = py + rng.pick(OFFSETS_XY)
    local z = (pz or BZ) + rng.pick(OFFSETS_Z)
    local form = rng.int(1, 100)
    if form <= 55 then
        f.at[src] = { x = x, y = y, z = z }
    elseif form <= 70 then
        f.at[src] = Sandbox.asVector({ x = x, y = y, z = z }, 'vector3')
    elseif form <= 78 then
        f.at[src] = { x = x, y = y }
    elseif form <= 83 then
        f.at[src] = { x = tostring(x), y = tostring(y), z = tostring(z) }
    elseif form <= 86 then
        f.at[src] = { x = 'abc', y = y, z = z }
    elseif form <= 89 then
        f.at[src] = 'throw'
    elseif form <= 92 then
        f.at[src] = 'nil'
    elseif form <= 95 then
        f.at[src] = nil                      -- the map origin, far away
    else
        f.at[src] = { x = x + 0.25, y = y - 0.5, z = z + 0.125 }
    end

    local ped = rng.int(1, 100)
    f.pedMode[src] = (ped <= 4 and 'zero') or (ped <= 8 and 'nil') or (ped <= 12 and 'throw') or nil
end

--- Runs the seeded worlds once, the old guard and the real handler side by
--- side on each blast, and hands back what each of them did. The two tests
--- below judge it: one on the decisions, which must be identical on the
--- file before this change as well as after it -- that is what proves the
--- reference above really is the old guard -- and one on the cost.
local function runWorlds()
    local f = newFixture()
    local oldRefusal = assert(load(OLD_GUARD, '=old explosion guard', 't', f.env))()
    local rng = newRng(20260925)

    local cases = {}
    local tally = { team = 0, bend = 0, clear = 0, watching = 0, out = 0, guardOff = 0, heights = 0 }

    for world = 1, 1000 do
        f.unflagAll()
        f.matches, f.at, f.pedMode = {}, {}, {}
        f.env.Config.Teams.friendlyFire = orNil(rng.pick({ false, false, false, true, NONE, 'yes' }))
        f.env.Config.Modes.tdm.enabled = not rng.chance(5)
        local guardOn = not rng.chance(3)
        f.env.Config.Match.crossfireGuard = { enabled = guardOn }

        -- SERVER IDS SCATTERED over 1..128, never a sequence.
        local size = rng.int(1, 32)
        local ids, taken = {}, {}
        while #ids < size do
            local src = rng.int(1, 128)
            if not taken[src] then taken[src] = true; ids[#ids + 1] = src end
        end

        local palette = rng.chance(50) and TWO_SIDES or TEAMS
        local players = {}
        for _, src in ipairs(ids) do
            local state = rng.pick(STATES)
            players[src] = { src = src, team = orNil(rng.pick(palette)),
                alive = orNil(state.alive), lives = orNil(state.lives) }
            f.flag(src, 'm1')
        end
        local match = { modeKey = orNil(rng.pick(MODES)), players = players, arenaKey = 'trailerpark' }
        local shape = rng.int(1, 100)
        if shape <= 3 then match.players = nil
        elseif shape <= 5 then match.players = 'unanswered' end
        f.matches.m1 = match

        -- Watching: flagged into this round, on no roster.
        local watchers = {}
        for _ = 1, rng.int(0, 3) do
            local src = 200 + #watchers + 1
            watchers[#watchers + 1] = src
            f.flag(src, 'm1')
        end
        -- And a second round on the same ground.
        local other = {}
        for index = 1, rng.int(0, 3) do
            local src = 300 + index
            other[src] = { src = src, team = orNil(rng.pick(TEAMS)), alive = true, lives = 3 }
            f.flag(src, 'm2')
        end
        f.matches.m2 = { modeKey = 'tdm', players = other, arenaKey = 'trailerpark' }

        for _ = 1, 3 do
            local px, py = BX + rng.int(-3, 3), BY + rng.int(-3, 3)
            local pz = (not rng.chance(20)) and (BZ + rng.int(-2, 2)) or nil
            -- HOW CROWDED THE BLAST IS: a packed one nearly always holds an
            -- enemy, so most refusals come from the sparse ones.
            local farPercent = rng.pick({ 0, 30, 60, 80, 90, 95 })
            for _, src in ipairs(ids) do placeSomebody(rng, f, src, px, py, pz, farPercent) end
            for _, src in ipairs(watchers) do placeSomebody(rng, f, src, px, py, pz, farPercent) end
            for src in pairs(other) do placeSomebody(rng, f, src, px, py, pz, farPercent) end

            local sender = (#watchers > 0 and rng.chance(8)) and rng.pick(watchers) or rng.pick(ids)
            -- Mostly somebody still fighting: an eliminated thrower is
            -- refused before the walk, so too many of them test nothing new.
            if type(match.players) == 'table' and match.players[sender]
                and f.env.Arena.IsEliminated(match.players[sender]) and rng.chance(75) then
                sender = rng.pick(ids)
            end

            f.resetCounts()
            local expected = oldRefusal(sender, 'm1', px, py, pz)
            local case = {
                label = ('world %d, sender %d, mode %s'):format(world, sender, tostring(match.modeKey)),
                sender = sender, expected = expected, guardOn = guardOn,
                oldPeds = f.pedCalls, oldCoords = f.coordCalls,
            }

            local ok, err = pcall(f.explode, sender, px, py, pz)
            case.ok, case.err = ok, err
            case.cancelled = f.cancelled
            case.refusedLines = {}
            for _, line in ipairs(f.debugs) do
                if line:find('refused an explosion', 1, true) then
                    case.refusedLines[#case.refusedLines + 1] = line
                end
            end
            case.peds, case.coords = f.pedCalls, f.coordCalls
            case.twice = nil
            for src, calls in pairs(f.pedCallsBySrc) do
                if calls > 1 then case.twice = src end
            end

            -- Whether anybody on the roster COULD be a team-mate: the only
            -- rows whose position can change the answer.
            local thrower = type(match.players) == 'table' and match.players[sender] or nil
            case.anyTeamMate = false
            if thrower ~= nil and not f.env.Arena.IsEliminated(thrower) then
                for src, row in pairs(match.players) do
                    if src ~= sender and not f.env.Arena.IsEliminated(row)
                        and not f.env.Arena.CanDamage(match.modeKey, thrower.team, row.team) then
                        case.anyTeamMate = true
                    end
                end
            end
            cases[#cases + 1] = case

            if not guardOn then tally.guardOff = tally.guardOff + 1 end
            if pz ~= nil then tally.heights = tally.heights + 1 end
            if expected == TEAM_REASON then tally.team = tally.team + 1
            elseif expected == 'they are watching rather than fighting' then tally.watching = tally.watching + 1
            elseif expected == 'the thrower is out of the round' then tally.out = tally.out + 1
            elseif case.anyTeamMate then tally.bend = tally.bend + 1
            else tally.clear = tally.clear + 1 end
        end
    end

    return cases, tally
end

local CASES, TALLY = runWorlds()

--- Fails the test with the first few disagreements, not the first one only.
local function noneOf(problems, what)
    local shown = {}
    for index = 1, math.min(5, #problems) do shown[index] = problems[index] end
    t.equals(#problems, 0, ('%s:\n    %s'):format(what, table.concat(shown, '\n    ')))
end

t.test('DIFFERENTIAL: the new guard decides exactly what the old one did, over 3000 seeded blasts', function()
    t.equals(#CASES, 3000)
    local problems = {}
    for _, case in ipairs(CASES) do
        local wantCancel = case.guardOn and case.expected ~= nil
        if not case.ok then
            problems[#problems + 1] = case.label .. ': the handler threw: ' .. tostring(case.err)
        elseif case.cancelled ~= wantCancel then
            problems[#problems + 1] = ('%s: old said %s, new cancelled=%s')
                :format(case.label, tostring(case.expected), tostring(case.cancelled))
        elseif wantCancel and (#case.refusedLines ~= 1
            or case.refusedLines[1] ~= refusedLine(case.sender, case.expected)) then
            problems[#problems + 1] = ('%s: the refusal line changed: %s')
                :format(case.label, tostring(case.refusedLines[1]))
        elseif not wantCancel and #case.refusedLines ~= 0 then
            problems[#problems + 1] = case.label .. ': a blast that went through was logged as refused'
        end
    end
    noneOf(problems, 'old and new disagree')

    -- NOT VACUOUS: every branch of the rule was decided, many times over.
    t.isTrue(TALLY.team >= 100, ('only %d team-mate refusals were drawn'):format(TALLY.team))
    t.isTrue(TALLY.bend >= 100, ('only %d blasts with a possible team-mate and no refusal'):format(TALLY.bend))
    t.isTrue(TALLY.clear >= 100, ('only %d blasts with no possible team-mate were drawn'):format(TALLY.clear))
    t.isTrue(TALLY.watching >= 20, ('only %d spectator throws were drawn'):format(TALLY.watching))
    t.isTrue(TALLY.out >= 50, ('only %d eliminated throws were drawn'):format(TALLY.out))
    t.isTrue(TALLY.guardOff >= 20, ('only %d blasts with the guard off were drawn'):format(TALLY.guardOff))
    t.isTrue(TALLY.heights >= 1500, ('only %d blasts carried a z'):format(TALLY.heights))
end)

t.test('DIFFERENTIAL COST: never a position more than the old walk, nobody twice, none where no team-mate can be', function()
    local problems, saved = {}, 0
    for _, case in ipairs(CASES) do
        if case.peds > case.oldPeds or case.coords > case.oldCoords then
            problems[#problems + 1] = ('%s: %d/%d natives, the old walk made %d/%d')
                :format(case.label, case.peds, case.coords, case.oldPeds, case.oldCoords)
        elseif case.twice then
            problems[#problems + 1] = ('%s: fighter %d was placed twice'):format(case.label, case.twice)
        elseif not case.anyTeamMate and case.peds ~= 0 then
            problems[#problems + 1] = ('%s: %d positions read where nobody could be a team-mate')
                :format(case.label, case.peds)
        end
        if case.peds < case.oldPeds then saved = saved + 1 end
    end
    noneOf(problems, 'the cost went the wrong way')
    t.isTrue(saved >= 1000, ('only %d of 3000 blasts read fewer positions than the old walk'):format(saved))
end)

os.exit(t.summary())
