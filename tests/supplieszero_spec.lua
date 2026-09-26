--[[
    crimson_arena/tests/supplieszero_spec.lua

    A SUPPLY THE PLAYER DELIBERATELY TOOK NONE OF.

    Arena.ResolveSupplies runs TWICE over the same choice: once when the pick
    is made, and again when the round starts, because server/match.lua
    re-resolves the loadout server/lobby.lua stored. That makes it a function
    whose output must be a legal input to itself -- and a dropped zero was not.

    The declined supply came back missing from the resolved list, the second
    pass found no key for it, and re-applied the OPERATOR'S DEFAULT. The plate
    a player had taken none of was in their hands at the start of every round,
    and under a `totalItems` ceiling it also pushed out something they had
    actually picked.

    Every count the player can pick is a fixed point. That is the property
    being asserted here, and zero was the only value that was not one.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')
print('supplieszero_spec')

local stock = Sandbox.newArenaEnv()
local Arena, Config = stock.Arena, stock.Config

--- The resolved supply list as { key = count }, so a missing key and a zero
--- can be told apart by the tests rather than by luck.
local function countsOf(list)
    local out = {}
    for _, entry in ipairs(list or {}) do out[entry.key] = entry.count end
    return out
end

local function pick(arena, chosen)
    local asked = {}
    for key, count in pairs(chosen) do asked[#asked + 1] = { key = key, count = count } end
    return arena.ResolveSupplies(asked)
end

--- THE WHOLE POINT: resolve, then resolve the RESULT, the way the server does.
local function roundTrip(arena, chosen)
    local once = pick(arena, chosen)
    return countsOf(once), countsOf(arena.ResolveSupplies(once))
end

local enabled = Arena.GetEnabledSupplies()
assert(#enabled >= 2, 'the shipped config needs two enabled supplies for this spec')
local A, B = enabled[1], enabled[2]
local aDefault = Arena.ClampInt(A.default, 0, Arena.SupplyMax(A)) or 0
assert(aDefault > 0, ('supply "%s" defaults to 0, so this spec cannot show a default being re-applied'):format(A.key))

t.test('CONTROL: the operator default is what somebody who picked nothing gets', function()
    local counts = countsOf(Arena.ResolveSupplies(nil))
    t.equals(counts[A.key], aDefault, 'a player who expressed no preference should get the default')
end)

t.test('CONTROL: a non-zero pick survives the round trip unchanged', function()
    local max = Arena.SupplyMax(A)
    local want = math.min(math.max(1, aDefault + 1), max)
    local first, second = roundTrip(Arena, { [A.key] = want })
    t.equals(first[A.key], want, 'the pick did not resolve to itself')
    t.equals(second[A.key], want, 'a non-zero pick drifted on the second pass -- the resolver is broken generally, not just for zero')
end)

t.test('DEFECT: a supply picked at zero came back as the operator default', function()
    local first, second = roundTrip(Arena, { [A.key] = 0 })
    t.equals(first[A.key], 0, 'the declined supply was dropped from the resolved list instead of recorded as 0')
    t.equals(second[A.key], 0, 'the round start handed back a supply the player had taken none of')
end)

t.test('DEFECT: and it is not one pass of luck -- it holds for a third', function()
    local once = pick(Arena, { [A.key] = 0 })
    local twice = Arena.ResolveSupplies(once)
    local thrice = countsOf(Arena.ResolveSupplies(twice))
    t.equals(thrice[A.key], 0, 'the declined supply crept back on a later pass')
end)

t.test('DEFECT: declining one supply does not displace another under a total ceiling', function()
    -- The shipped config ships totalItems = 0 (no ceiling), so this is the
    -- operator-configured case -- and it is the one that costs a player
    -- something they DID pick, rather than merely handing them something spare.
    local env = Sandbox.newArenaEnv()
    local ceiling = 10
    env.Config.Loadouts.supplies.totalItems = ceiling

    local bMax = math.min(ceiling, env.Arena.SupplyMax(B))
    local first, second = roundTrip(env.Arena, { [A.key] = 0, [B.key] = bMax })

    t.equals(first[B.key], bMax, 'the ceiling ate the pick on the FIRST pass -- wrong fixture, not the defect')
    t.equals(second[A.key], 0, 'the declined supply came back and took a slot under the ceiling')
    t.equals(second[B.key], bMax, 'the re-applied default displaced a supply the player actually picked')
end)

t.test('a zero row still issues nothing: it carries the item name and a count of 0', function()
    local list = pick(Arena, { [A.key] = 0 })
    local row
    for _, entry in ipairs(list) do if entry.key == A.key then row = entry end end
    t.isNotNil(row, 'the declined supply has no row at all, so the next pass cannot see the choice')
    t.equals(row.count, 0, 'a declined row must be a real zero')
    t.equals(row.item, A.item, 'the row must still name its item, so the list has one shape')
end)

os.exit(t.summary())
