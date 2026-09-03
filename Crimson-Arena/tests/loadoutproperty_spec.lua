--[[
    crimson_arena/tests/loadoutproperty_spec.lua

    THE LOADOUT RESOLVER AND THE TEAM DRAW, AGAINST GENERATED INPUT.

    Arena.ResolveLoadout is the one function the server calls before giving
    anybody a gun, and Arena.SuggestTeam decides which side a player who did
    not pick one lands on. Both were rewritten recently -- two separate weapon
    allowances became one shared pool, and a tie between equally-small sides
    stopped always going to crimson -- and both are covered by example-based
    tests in arena_spec.

    This file covers what those cannot: it chooses no examples. It generates
    thousands of configs and requests, junk mixed in with real keys, and
    asserts what must be true of EVERY answer rather than what one answer
    should be.

    THE ACCOUNTING INVARIANT is the one worth having. A resolver may refuse a
    weapon -- that is its job -- but it may not drop one silently, because
    ArenaLobby.SetLoadout raises its notify.loadout_rejected toast from that
    list and a weapon missing from both the loadout and the list is a weapon
    the player is never told about. That is exactly the defect the shared pool
    fixed, and this is the shape that keeps it fixed.

    Seeded, so a failure is reproducible.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('loadoutproperty_spec')

--- Values an operator might really write, plus the ones they might fat-finger.
local SLOTS = { 0, 1, 2, 3, 4, 7, 40, nil, -1, -99, 'four', {}, true, 0 / 0, 1 / 0 }
local SWITCH = { true, false, nil }

--- Junk the resolver has to survive alongside real catalogue keys. A GTA
--- weapon NAME is in here on purpose: it is not a catalogue key, and the
--- resolver's own output used to be assumed to contain them.
local JUNK = { 'nope', '', 'WEAPON_PISTOL', 0, -1, 1 / 0, 0 / 0, true, {} }

local base = Sandbox.newArenaEnv()
local KEYS = {}
for _, weapon in ipairs(base.Arena.GetEnabledWeapons()) do KEYS[#KEYS + 1] = weapon.key end

-- ======================================================================
-- THE POOL
-- ======================================================================

t.test('across 2000 generated configs and requests, every answer is legal', function()
    t.isTrue(#KEYS > 20, 'not enough weapons enabled to generate anything interesting')

    local failures = {}
    local function check(cond, seed, fmt, ...)
        if cond then return end
        failures[#failures + 1] = ('seed %d: %s'):format(seed,
            select('#', ...) > 0 and fmt:format(...) or fmt)
    end

    local issuedSomething, refusedSomething = 0, 0

    for seed = 1, 2000 do
        math.randomseed(seed)

        local env = Sandbox.newArenaEnv()
        local A = env.Arena
        local slots = SLOTS[math.random(#SLOTS)]
        local guns = SWITCH[math.random(#SWITCH)]
        local melee = SWITCH[math.random(#SWITCH)]
        env.Config.Loadouts.slots = slots
        env.Config.Loadouts.allowFirearms = guns
        env.Config.Loadouts.allowMelee = melee

        local request = {}
        for _ = 1, math.random(0, 40) do
            if math.random() < 0.75 then
                request[#request + 1] = { key = KEYS[math.random(#KEYS)], ammo = math.random(-5, 500) }
            else
                request[#request + 1] = { key = JUNK[math.random(#JUNK)] }
            end
        end

        local ok, loadout, rejected = pcall(A.ResolveLoadout, { weapons = request })
        check(ok, seed, 'ResolveLoadout threw: %s', tostring(loadout))
        if ok then
            local cap = A.SlotsPerPlayer()
            if #loadout.weapons > 0 then issuedSomething = issuedSomething + 1 end
            if #rejected > 0 then refusedSomething = refusedSomething + 1 end

            -- NEVER OVER THE POOL. Zero means no limit, so it is not a cap.
            if cap > 0 then
                check(#loadout.weapons <= cap, seed,
                    '%d weapons issued against a pool of %d', #loadout.weapons, cap)
            end

            local carried = {}
            for _, entry in ipairs(loadout.weapons) do
                local catalogue = A.GetWeaponByKey(entry.key)

                -- NEVER SOMETHING OUTSIDE THE CATALOGUE.
                check(catalogue ~= nil, seed, 'issued "%s", which is not a catalogue entry',
                    tostring(entry.key))

                -- NEVER A KIND THE OPERATOR SWITCHED OFF.
                if catalogue then
                    local isMelee = A.IsMeleeWeapon(catalogue)
                    check(not (isMelee and melee == false), seed,
                        'issued melee "%s" with allowMelee = false', tostring(entry.key))
                    check(not ((not isMelee) and guns == false), seed,
                        'issued firearm "%s" with allowFirearms = false', tostring(entry.key))
                end

                -- NEVER THE SAME WEAPON TWICE. Asking twice would otherwise
                -- burn two slots on one gun.
                check(not carried[entry.key], seed, '"%s" issued twice', tostring(entry.key))
                carried[entry.key] = true

                -- ALWAYS A SANE WHOLE NUMBER OF ROUNDS.
                check(type(entry.ammo) == 'number' and entry.ammo >= 0
                    and entry.ammo == math.floor(entry.ammo), seed,
                    '"%s" carries ammo %s', tostring(entry.key), tostring(entry.ammo))
            end

            -- THE ACCOUNTING INVARIANT. Every resolvable key that was asked
            -- for is either carried or named in `rejected`. Nothing may
            -- vanish between the two, because that list is the only thing the
            -- player is ever told.
            local named = {}
            for _, key in ipairs(rejected) do named[key] = true end
            for _, entry in ipairs(request) do
                local catalogue = type(entry.key) == 'string' and A.GetWeaponByKey(entry.key) or nil
                if catalogue then
                    check(carried[catalogue.key] or named[catalogue.key], seed,
                        '"%s" was asked for, is not carried, and was never named',
                        catalogue.key)
                end
            end
        end
    end

    -- The sweep has to reach both outcomes, or it is asserting about nothing.
    t.isTrue(issuedSomething > 500,
        ('only %d of 2000 requests produced a weapon'):format(issuedSomething))
    t.isTrue(refusedSomething > 200,
        ('only %d of 2000 requests refused anything'):format(refusedSomething))

    t.equals(#failures, 0, (#failures > 0 and failures[1] or 'no violations'))
end)

-- ======================================================================
-- THE TEAM DRAW
-- ======================================================================

t.test('and the team draw never names a side that is larger, or full, or unreal', function()
    local failures = {}
    local function check(cond, seed, fmt, ...)
        if cond then return end
        failures[#failures + 1] = ('seed %d: %s'):format(seed,
            select('#', ...) > 0 and fmt:format(...) or fmt)
    end

    for seed = 1, 1500 do
        math.randomseed(seed)

        local env = Sandbox.newArenaEnv()
        local A = env.Arena
        local cap = ({ 0, 0, 0, 1, 2, 3, 5 })[math.random(7)]
        env.Config.Teams.maxTeamSize = cap

        local enabled = {}
        for _, team in ipairs(A.GetEnabledTeams()) do enabled[#enabled + 1] = team.key end

        local players = {}
        for id = 1, math.random(0, 24) do
            players[id] = { id = id }
            -- Some arrive having already picked, which SuggestTeam does not
            -- control and must not be judged on.
            if math.random() < 0.3 then players[id].team = enabled[math.random(#enabled)] end
        end

        for _, player in ipairs(players) do
            if not A.GetTeamByKey(player.team) then
                local before = A.CountTeams(players)
                local pick = A.SuggestTeam(players)

                if pick ~= nil then
                    check(A.GetTeamByKey(pick) ~= nil, seed,
                        'suggested "%s", which is not an enabled team', tostring(pick))

                    if cap > 0 then
                        check((before[pick] or 0) < cap, seed,
                            'suggested %s at %d of a cap of %d', pick, before[pick] or 0, cap)
                    end

                    -- THE RULE THAT NEVER BENDS: chance decides between sides
                    -- that are already equal, never between unequal ones.
                    for _, other in ipairs(enabled) do
                        local count = before[other] or 0
                        local hasRoom = cap <= 0 or count < cap
                        if hasRoom then
                            check((before[pick] or 0) <= count, seed,
                                'suggested %s (%d) over %s (%d), which had room',
                                pick, before[pick] or 0, other, count)
                        end
                    end
                end
                player.team = pick
            end
        end
    end

    t.equals(#failures, 0, (#failures > 0 and failures[1] or 'no violations'))
end)

t.test('and a lobby it fills on its own always comes out level', function()
    -- THE HALF A RANDOM TIE-BREAK COULD HAVE BROKEN. Only rosters SuggestTeam
    -- placed entirely on its own are judged -- a player who picked a side
    -- themselves can unbalance a roster and that is not the draw's doing.
    local worst = 0

    for seed = 1, 400 do
        math.randomseed(seed)

        local env = Sandbox.newArenaEnv()
        local A = env.Arena
        env.Config.Teams.maxTeamSize = 0

        local players = {}
        for id = 1, math.random(1, 24) do players[id] = { id = id } end
        for _, player in ipairs(players) do player.team = A.SuggestTeam(players) end

        local counts = A.CountTeams(players)
        local low, high
        for _, team in ipairs(A.GetEnabledTeams()) do
            local count = counts[team.key] or 0
            low = (low == nil or count < low) and count or low
            high = (high == nil or count > high) and count or high
        end

        local spread = (high or 0) - (low or 0)
        if spread > worst then worst = spread end
        t.isTrue(spread <= 1,
            ('seed %d: %d players it placed alone came out %d/%d'):format(seed, #players, low, high))
    end

    -- An odd roster cannot split evenly, so 1 is the floor for the worst case
    -- and 0 would mean the sweep never generated an odd one.
    t.equals(worst, 1, 'the sweep never generated an odd roster, so this proves less than it looks')
end)

os.exit(t.summary())
