--[[
    tests/arena_spec.lua

    Every rule in shared/arena.lua, run against the REAL config.lua. Both
    files are loaded unmodified through tests/fixtures/sandbox.lua, which is
    the whole payoff of a rules file that calls no native: the thing under
    test here is the thing that ships, not a copy of it.

    ADVERSARIAL BY DEFAULT. On the server every one of these arguments arrived
    over the network, so each is fed what a modified client can actually send
    -- a string, a table, nil, a float, a negative, a value just past a legal
    one -- and not only the shapes the panel produces.

    BROKEN CONFIGS ARE BUILT HERE, never in config.lua. `tweaked()` below
    mutates a private sandbox copy, so a test about a duplicate weapon key
    cannot leave a duplicate weapon key behind for the next test, and the
    shipped config stays the config the suite otherwise proves things about.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

-- The env every read-only test shares. It is this spec's own copy of the real
-- config, but it is still ONE copy: a test that wrote to it would quietly
-- change the answer for every test after it.
local stock = Sandbox.newArenaEnv()
local Arena = stock.Arena
local Config = stock.Config

--- A sandbox of its own, mutated into the server one test is about.
--- @param mutate fun(config: table)
--- @return table arena
--- @return table config
local function tweaked(mutate)
    local env = Sandbox.newArenaEnv()
    mutate(env.Config)
    return env.Arena, env.Config
end

--- The player array Arena.CountTeams reads, described as the split it is
--- meant to be: roster({ { team = 'crimson', count = 7 }, { team = 'ash', count = 1 } }).
--- `team = nil` is allowed on purpose -- that is somebody who never picked.
--- @param spec table[]
--- @return table[] players
local function roster(spec)
    local players = {}
    for _, entry in ipairs(spec) do
        for _ = 1, entry.count do
            players[#players + 1] = { id = #players + 1, team = entry.team }
        end
    end
    return players
end

-- The three shapes of ammo config that exist in the shipped weapon list.
local pistol = Arena.GetWeaponByKey('pistol')       -- options { 30, 60, 120 }, default 60, max 250
local sniper = Arena.GetWeaponByKey('sniper')       -- options { 10, 20, 40 }, default 20, max 60
local knife = Arena.GetWeaponByKey('knife')         -- options = nil, default 1, max 1

-- ======================================================================
-- THE SHIPPED CONFIG
-- ======================================================================

t.test('the shipped config validates clean', function()
    local problems = Arena.ValidateConfig()
    t.equals(#problems, 0, table.concat(problems, ' | '))
end)

t.test('the three weapons this spec leans on are the shape it assumes', function()
    t.equals(pistol.ammo.default, 60)
    t.equals(pistol.ammo.max, 250)
    t.equals(#Arena.GetAmmoOptions(pistol), 3)
    t.equals(sniper.ammo.default, 20)
    -- Melee has nothing to pick: an EMPTY option list, not "no ammo".
    t.equals(#Arena.GetAmmoOptions(knife), 0)
    t.isNil(knife.ammo.options)
end)

-- ======================================================================
-- ResolveAmmo
--
-- TWO MODES, AND EVERY TEST BELOW SAYS WHICH IT IS IN.
--
-- With `allowCustomAmmo` OFF the option list is the only legal set of values
-- and an off-list request falls back to the weapon's default -- never to the
-- nearest option, which is the move that would let a modified client walk a
-- value up past a preset by asking for one just above it.
--
-- With it ON the list becomes presets and an off-list request is clamped
-- into [0, max]. That is not the same relaxation: `max` is the ceiling in
-- both modes, so it widens what may be ASKED for and moves the limit not at
-- all.
--
-- The block below pins the refusing mode explicitly rather than leaning on
-- the shipped default, because the shipped default changed and these tests
-- are about the rule, not about today's config.
-- ======================================================================

--- The refusing mode, whatever the shipped config currently says.
local function strict()
    Config.Loadouts.allowCustomAmmo = false
end

--- The typing-allowed mode.
local function custom()
    Config.Loadouts.allowCustomAmmo = true
end

t.test('ResolveAmmo grants an on-list request exactly as asked', function()
    strict()
    t.equals(Arena.ResolveAmmo(pistol, 30), 30)
    t.equals(Arena.ResolveAmmo(pistol, 60), 60)
    t.equals(Arena.ResolveAmmo(pistol, 120), 120)
end)

t.test('ResolveAmmo falls back to the default for an off-list request, never to the nearest option', function()
    strict()
    -- 119 sits one under a legal 120. Rounding to "closest" is exactly the
    -- move that would let a client walk a value up past a preset.
    t.equals(Arena.ResolveAmmo(pistol, 119), 60)
    t.equals(Arena.ResolveAmmo(pistol, 121), 60)
    t.equals(Arena.ResolveAmmo(pistol, 31), 60)
    t.equals(Arena.ResolveAmmo(sniper, 39), 20)
end)

t.test('ResolveAmmo refuses a value above max rather than clamping to it', function()
    strict()
    -- 250 IS this weapon's max, and the request still does not get it: the
    -- clamp is only ever reachable through the option list.
    t.equals(Arena.ResolveAmmo(pistol, 9999), 60)
    t.equals(Arena.ResolveAmmo(pistol, 250), 60)
    t.equals(Arena.ResolveAmmo(sniper, 60), 20)
end)

t.test('ResolveAmmo gives the default for a negative request', function()
    strict()
    t.equals(Arena.ResolveAmmo(pistol, -1), 60)
    t.equals(Arena.ResolveAmmo(pistol, -9999), 60)
    t.equals(Arena.ResolveAmmo(knife, -1), 1)
end)

t.test('ResolveAmmo gives the default for a string, and still checks the list when the string is a number', function()
    strict()
    t.equals(Arena.ResolveAmmo(pistol, 'plenty'), 60)
    t.equals(Arena.ResolveAmmo(pistol, ''), 60)
    -- A numeric string is coerced, which is harmless precisely because the
    -- coerced value has to clear the same option list an integer does.
    t.equals(Arena.ResolveAmmo(pistol, '120'), 120)
    t.equals(Arena.ResolveAmmo(pistol, '119'), 60)
end)

t.test('ResolveAmmo gives the default for a table', function()
    strict()
    t.equals(Arena.ResolveAmmo(pistol, {}), 60)
    t.equals(Arena.ResolveAmmo(pistol, { 120 }), 60)
    t.equals(Arena.ResolveAmmo(pistol, { ammo = 120 }), 60)
end)

t.test('ResolveAmmo gives the default for nil, and for no argument at all', function()
    strict()
    t.equals(Arena.ResolveAmmo(pistol, nil), 60)
    t.equals(Arena.ResolveAmmo(pistol), 60)
end)

t.test('ResolveAmmo floors a float before the option list is consulted', function()
    strict()
    t.equals(Arena.ResolveAmmo(sniper, 40.9), 40)
    t.equals(Arena.ResolveAmmo(sniper, 40.0), 40)
    -- 39.9 floors to 39, which is not on the list, so it lands on the
    -- default rather than on the 40 it was nearly asking for.
    t.equals(Arena.ResolveAmmo(sniper, 39.9), 20)
    t.equals(Arena.ResolveAmmo(sniper, 20.5), 20)
end)

t.test('a typed amount is honoured when the operator allows one', function()
    custom()
    -- The whole point of the feature: a number that is on no preset list.
    t.equals(Arena.ResolveAmmo(pistol, 119), 119)
    t.equals(Arena.ResolveAmmo(pistol, 7), 7)
    t.equals(Arena.ResolveAmmo(sniper, 39), 39)
end)

t.test('and it is still held to the weapon max, which is the whole safety of it', function()
    custom()
    t.equals(Arena.ResolveAmmo(pistol, 9999), pistol.ammo.max)
    t.equals(Arena.ResolveAmmo(pistol, 251), pistol.ammo.max)
    t.equals(Arena.ResolveAmmo(sniper, 9999), sniper.ammo.max)
end)

t.test('a typed amount below zero is still a refusal, not a clamp to zero', function()
    -- Negative is not a small request, it is nonsense, and nonsense gets the
    -- default in both modes.
    custom()
    t.equals(Arena.ResolveAmmo(pistol, -1), pistol.ammo.default)
end)

t.test('one weapon can be pinned to its presets while the rest stay free', function()
    custom()
    local pinned = {}
    for key, value in pairs(pistol) do pinned[key] = value end
    pinned.allowCustomAmmo = false

    t.equals(Arena.ResolveAmmo(pinned, 119), pistol.ammo.default,
        'a weapon carrying allowCustomAmmo = false still accepted a typed amount')
    t.equals(Arena.ResolveAmmo(pistol, 119), 119,
        'pinning one weapon pinned the others with it')
end)

t.test('melee is unaffected either way -- there is nothing to type', function()
    custom()
    t.equals(Arena.ResolveAmmo(knife, 99), 1, 'a knife accepted a typed magazine')
end)

t.test('ResolveAmmo clamps instead of refusing when the weapon has no options list', function()
    strict()
    -- The melee entries are the only `options = nil` weapons that ship, and
    -- their ceiling is 1, so anything at all comes back as 1.
    t.equals(Arena.ResolveAmmo(knife, 500), 1)
    t.equals(Arena.ResolveAmmo(knife, 1), 1)
    t.equals(Arena.ResolveAmmo(knife, 0), 0)
    t.equals(Arena.ResolveAmmo(knife, 'plenty'), 1)

    -- A free-form weapon with real headroom -- shaped like one an operator
    -- could write, and needing no place in Config because ResolveAmmo takes
    -- the weapon table itself.
    local freeform = { key = 'freeform', weapon = 'WEAPON_PISTOL', ammo = { default = 25, max = 200 } }
    t.equals(Arena.ResolveAmmo(freeform, 5000), 200)
    t.equals(Arena.ResolveAmmo(freeform, 7), 7)
    t.equals(Arena.ResolveAmmo(freeform, 7.9), 7)
    t.equals(Arena.ResolveAmmo(freeform, -7), 25)
    t.equals(Arena.ResolveAmmo(freeform, {}), 25)
end)

t.test('ResolveAmmo hands out nothing for a weapon with no ammo block', function()
    t.equals(Arena.ResolveAmmo({ key = 'broken', weapon = 'WEAPON_PISTOL' }, 60), 0)
    t.equals(Arena.ResolveAmmo({ ammo = 'sixty' }, 60), 0)
    t.equals(Arena.ResolveAmmo(nil, 60), 0)
end)

t.test('ResolveAmmo ignores the request entirely when allowChoose is off', function()
    local arena = tweaked(function(config) config.Loadouts.allowChoose = false end)
    local fixedPistol = arena.GetWeaponByKey('pistol')
    -- Even a perfectly legal on-list request is not honoured: with choosing
    -- switched off there is no request, only the operator's default.
    t.equals(arena.ResolveAmmo(fixedPistol, 120), 60)
    t.equals(arena.ResolveAmmo(fixedPistol, 30), 60)
    t.equals(arena.ResolveAmmo(fixedPistol, nil), 60)
end)

-- ======================================================================
-- ResolveLoadout
--
-- alwaysGive SHIPS EMPTY, so these set up their own where they need one.
--
-- They used to lean on a house knife that was in the shipped config, and
-- counted it in every assertion -- so removing it failed six tests that were
-- not about it. A test that says what it needs survives a config decision it
-- has no opinion on.
-- ======================================================================

--- Hands everybody the house knife, for the tests that are about that.
local function houseKnife()
    Config.Loadouts.alwaysGive = { { key = 'knife' } }
end

--- Nothing on top of what the player picked -- the shipped arrangement.
local function noHouseWeapon()
    Config.Loadouts.alwaysGive = {}
end

t.test('ResolveLoadout drops an unknown weapon key and honours the rest', function()
    houseKnife()
    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = 'railgun', ammo = 300 }, { key = 'rifle', ammo = 300 } },
    })

    t.equals(#rejected, 1)
    t.equals(rejected[1], 'railgun')
    t.equals(#loadout.weapons, 2)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[1].ammo, 300)
    t.equals(loadout.weapons[2].weapon, 'WEAPON_KNIFE')
    t.isTrue(loadout.weapons[2].alwaysGive)
end)

t.test('ResolveLoadout refuses a disabled weapon by key exactly as it refuses an unknown one', function()
    houseKnife()
    -- `enabled = false` has to be indistinguishable from "no such weapon",
    -- or it is only a UI hint and a modified client walks straight past it.
    t.isNil(Arena.GetWeaponByKey('grenadelauncher'))

    local disabled, disabledRejected = Arena.ResolveLoadout({ weapons = { { key = 'grenadelauncher', ammo = 20 } } })
    local unknown, unknownRejected = Arena.ResolveLoadout({ weapons = { { key = 'nosuchweapon', ammo = 20 } } })

    t.equals(#disabledRejected, 1)
    t.equals(disabledRejected[1], 'grenadelauncher')
    t.equals(#unknownRejected, 1)
    t.equals(unknownRejected[1], 'nosuchweapon')
    -- Both end up carrying the house knife and nothing else.
    t.equals(#disabled.weapons, 1)
    t.equals(#unknown.weapons, #disabled.weapons)
    t.equals(disabled.weapons[1].weapon, 'WEAPON_KNIFE')
end)

t.test('ResolveLoadout burns one slot for the same weapon asked for twice, not two', function()
    houseKnife()
    local loadout, rejected = Arena.ResolveLoadout({
        weapons = {
            { key = 'rifle', ammo = 60 },
            { key = 'rifle', ammo = 300 },
            { key = 'pistol', ammo = 120 },
        },
    })

    t.equals(#rejected, 1)
    t.equals(rejected[1], 'rifle')
    -- The duplicate did not eat the second slot, so the pistol still got in.
    t.equals(#loadout.weapons, 3)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[1].ammo, 60)
    t.equals(loadout.weapons[2].weapon, 'WEAPON_PISTOL')
    t.equals(loadout.weapons[2].ammo, 120)
    t.equals(loadout.weapons[3].weapon, 'WEAPON_KNIFE')
end)

t.test('ResolveLoadout stops at weaponSlots, and names what did not fit', function()
    houseKnife()
    t.equals(Config.Loadouts.weaponSlots, 2)

    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = 'pistol' }, { key = 'rifle' }, { key = 'sniper' }, { key = 'shotgun' } },
    })

    -- Two picks plus the house knife.
    t.equals(#loadout.weapons, 3)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_PISTOL')
    t.equals(loadout.weapons[2].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[3].weapon, 'WEAPON_KNIFE')

    -- The overflow is REPORTED, not silently swallowed. This changed when
    -- melee got an allowance of its own: the loop can no longer stop at the
    -- first weapon that does not fit, because a blade further down the list is
    -- still takeable after the firearm slots are gone. Everything it skips is
    -- named instead, which is strictly more useful -- the panel can tell a
    -- player which weapon did not make it rather than quietly dropping one.
    t.equals(#rejected, 2)
    t.equals(rejected[1], 'sniper')
    t.equals(rejected[2], 'shotgun')
end)

t.test('melee has its own allowance and does not compete with firearms', function()
    -- The BEHAVIOUR, not the shipped number. This used to assert
    -- meleeSlots == 1 and then lean on it, so raising the operator's melee
    -- allowance broke a test that is not about the allowance at all.
    t.isTrue((Arena.ToInt(Config.Loadouts.meleeSlots) or 0) >= 1,
        'melee is switched off entirely, so there is no allowance to test')

    -- Two guns AND a blade, from a request that would have cost three shared
    -- slots. The whole point of the separate count.
    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = 'pistol' }, { key = 'rifle' }, { key = 'machete' } },
    })

    local names = {}
    for _, weapon in ipairs(loadout.weapons) do names[weapon.weapon] = true end

    t.isTrue(names['WEAPON_PISTOL'])
    t.isTrue(names['WEAPON_ASSAULTRIFLE'])
    t.isTrue(names['WEAPON_MACHETE'], 'the blade did not cost a gun slot')
    t.equals(#rejected, 0)
end)

t.test('a blade past the allowance is refused while a firearm slot is still free', function()
    -- Pinned to ONE melee slot here rather than read from the config: this is
    -- about what happens when the allowance runs out, so the allowance has to
    -- be a known number. The operator ships two.
    local restore = Config.Loadouts.meleeSlots
    Config.Loadouts.meleeSlots = 1

    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = 'machete' }, { key = 'bat' }, { key = 'pistol' } },
    })
    Config.Loadouts.meleeSlots = restore

    local names = {}
    for _, weapon in ipairs(loadout.weapons) do names[weapon.weapon] = true end

    t.isTrue(names['WEAPON_MACHETE'])
    t.isFalse(names['WEAPON_BAT'] == true, 'one melee slot means one blade')
    t.isTrue(names['WEAPON_PISTOL'], 'and a spent melee allowance does not block a gun behind it')
    t.equals(#rejected, 1)
    t.equals(rejected[1], 'bat')
end)

t.test('meleeSlots = 0 removes melee without touching the firearm allowance', function()
    local noMelee = tweaked(function(config) config.Loadouts.meleeSlots = 0 end)
    local loadout = noMelee.ResolveLoadout({
        weapons = { { key = 'machete' }, { key = 'pistol' }, { key = 'rifle' } },
    })

    local names = {}
    for _, weapon in ipairs(loadout.weapons) do names[weapon.weapon] = true end

    t.isFalse(names['WEAPON_MACHETE'] == true)
    t.isTrue(names['WEAPON_PISTOL'])
    t.isTrue(names['WEAPON_ASSAULTRIFLE'])
end)

t.test('a melee weapon is offered no ammo types, whatever the shared list says', function()
    -- A knife with an armour-piercing dropdown would be nonsense, and the
    -- shared default list applies to every OTHER weapon.
    for _, key in ipairs({ 'knife', 'bat', 'machete' }) do
        local weapon = Arena.GetWeaponByKey(key)
        t.isNotNil(weapon, key .. ' is missing from the catalogue')
        t.isTrue(Arena.IsMeleeWeapon(weapon), key .. ' should read as melee')
        t.equals(#Arena.GetAmmoTypes(weapon), 0, key .. ' should offer no ammo types')
        t.isNil(Arena.ResolveAmmoType(weapon, 'ap'), key .. ' should refuse a type outright')
    end
end)

t.test('ResolveLoadout honours a smaller weaponSlots, and zero slots', function()
    -- Set INSIDE the callback: tweaked() builds a fresh env from the shipped
    -- config, so mutating the outer one does not reach it.
    local oneSlot = tweaked(function(config)
        config.Loadouts.weaponSlots = 1
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local single = oneSlot.ResolveLoadout({ weapons = { { key = 'pistol' }, { key = 'rifle' } } })
    t.equals(#single.weapons, 2)
    t.equals(single.weapons[1].weapon, 'WEAPON_PISTOL')
    t.equals(single.weapons[2].weapon, 'WEAPON_KNIFE')

    -- Zero slots is a legal, if joyless, arena: nobody picks anything and
    -- everybody still walks in with what the operator hands out.
    local noSlots = tweaked(function(config)
        config.Loadouts.weaponSlots = 0
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local empty = noSlots.ResolveLoadout({ weapons = { { key = 'pistol' } } })
    t.equals(#empty.weapons, 1)
    t.equals(empty.weapons[1].weapon, 'WEAPON_KNIFE')

    -- A negative slot count is floored to zero rather than read as "all".
    local negative = tweaked(function(config)
        config.Loadouts.weaponSlots = -5
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local none = negative.ResolveLoadout({ weapons = { { key = 'pistol' } } })
    t.equals(#none.weapons, 1)
    t.equals(none.weapons[1].weapon, 'WEAPON_KNIFE')
end)

t.test('with alwaysGive empty a player carries exactly what they picked', function()
    -- THE SHIPPED ARRANGEMENT. The house knife made the melee allowance a
    -- lie: somebody who deliberately took no blade still had one, and
    -- somebody who picked a different blade carried two.
    noHouseWeapon()

    local loadout = Arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })

    t.equals(#loadout.weapons, 1, 'something was handed out that the player did not ask for')
    t.equals(loadout.weapons[1].weapon, 'WEAPON_PISTOL')
    t.isNil(loadout.weapons[1].alwaysGive)
end)

t.test('and the shipped config really is empty, so that is not just this test', function()
    local shipped = Sandbox.newArenaEnv()
    t.equals(#(shipped.Config.Loadouts.alwaysGive or {}), 0,
        'the shipped config hands out a weapon nobody picked')
end)

t.test('ResolveLoadout appends alwaysGive past the slot limit', function()
    houseKnife()
    local loadout = Arena.ResolveLoadout({ weapons = { { key = 'rifle' }, { key = 'shotgun' } } })

    -- Both slots are spent on the player's own picks and the operator's
    -- entry still lands: you cannot spend your way out of the house knife.
    t.equals(#loadout.weapons, 3)
    t.equals(loadout.weapons[3].weapon, 'WEAPON_KNIFE')
    t.equals(loadout.weapons[3].ammo, 1)
    t.isTrue(loadout.weapons[3].alwaysGive)
    t.isNil(loadout.weapons[1].alwaysGive)
end)

t.test('ResolveLoadout survives a request that is not a table at all', function()
    for _, request in ipairs({ 'rifle', 42, true }) do
        local loadout, rejected = Arena.ResolveLoadout(request)
        t.equals(#loadout.weapons, 1, tostring(request))
        t.equals(loadout.weapons[1].weapon, 'WEAPON_KNIFE', tostring(request))
        t.equals(#rejected, 0, tostring(request))
        t.equals(loadout.armor, 100, tostring(request))
        t.equals(loadout.health, 200, tostring(request))
    end

    local fromNil = Arena.ResolveLoadout(nil)
    t.equals(#fromNil.weapons, 1)
    local fromNothing = Arena.ResolveLoadout()
    t.equals(#fromNothing.weapons, 1)
end)

t.test('ResolveLoadout ignores a weapons field that is not a list', function()
    local loadout = Arena.ResolveLoadout({ weapons = 'rifle' })
    t.equals(#loadout.weapons, 1)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_KNIFE')
end)

t.test('ResolveLoadout reads a bare string entry as a weapon key, at default ammo', function()
    local loadout, rejected = Arena.ResolveLoadout({ weapons = { 'rifle' } })
    t.equals(#rejected, 0)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[1].ammo, 150)
end)

t.test('ResolveLoadout drops a table where a key should be, like any other bad key', function()
    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = {} }, { key = 12 }, { key = 'pistol' } },
    })

    t.equals(#rejected, 2)
    -- The rejects are only ever logged, so they are stringified rather than
    -- passed through as whatever arrived.
    t.equals(type(rejected[1]), 'string')
    t.equals(rejected[2], '12')
    t.equals(#loadout.weapons, 2)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_PISTOL')
end)

t.test('everybody starts a round on a full plate, whatever they ask for', function()
    -- Config.Loadouts.armor.allowChoose ships FALSE: a round starts even, and
    -- nobody can hand themselves a disadvantage by accident or hand an
    -- opponent one on purpose. Every request resolves to the default.
    t.isFalse(Config.Loadouts.armor.allowChoose)
    t.equals(Config.Loadouts.armor.default, Config.Loadouts.armor.max)

    for _, asked in ipairs({ 0, 50, 75, 500, -50 }) do
        t.equals(Arena.ResolveLoadout({ armor = asked }).armor, 100,
            ('asking for %s should still be a full plate'):format(tostring(asked)))
    end
    t.equals(Arena.ResolveLoadout({ armor = 'max' }).armor, 100)
    t.equals(Arena.ResolveLoadout({}).armor, 100, 'and asking for nothing is the same')
end)

t.test('and full health, whoever walked up to the arena half dead', function()
    t.equals(Arena.ResolveLoadout({}).health, Config.Loadouts.health)
    t.equals(Config.Loadouts.health, 200, 'a stock GTA full bar')
end)

t.test('turning the armour picker back on makes the options real again', function()
    -- The switch has to actually do something, or it is the sort of dead key
    -- this suite exists to catch.
    local choosable = tweaked(function(config) config.Loadouts.armor.allowChoose = true end)

    t.equals(choosable.ResolveLoadout({ armor = 50 }).armor, 50)
    t.equals(choosable.ResolveLoadout({ armor = 0 }).armor, 0)
    -- 75 is not one of the offered options, so it takes the default -- the
    -- same refusal ammo gets, for the same reason.
    t.equals(choosable.ResolveLoadout({ armor = 75 }).armor, 100)
    t.equals(choosable.ResolveLoadout({ armor = 500 }).armor, 100)
    t.equals(choosable.ResolveLoadout({ armor = 'max' }).armor, 100)
end)

t.test('ResolveLoadout swaps the request for the operator fixed list when allowChoose is off', function()
    local arena = tweaked(function(config)
        config.Loadouts.allowChoose = false
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local loadout, rejected = arena.ResolveLoadout({
        weapons = { { key = 'sniper', ammo = 40 } },
        armor = 50,
    })

    t.equals(#rejected, 0)
    t.equals(#loadout.weapons, 3)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[2].weapon, 'WEAPON_PISTOL')
    t.equals(loadout.weapons[3].weapon, 'WEAPON_KNIFE')
    -- Rule 3 in ResolveAmmo's own header: with choosing off EVERY weapon gets
    -- its default, so the ammo written next to each `fixed` entry (250 / 100)
    -- never reaches the player -- they get the weapon's own 150 / 60.
    t.equals(loadout.weapons[1].ammo, 150)
    t.equals(loadout.weapons[2].ammo, 60)
    t.equals(loadout.armor, 100)
end)

-- ======================================================================
-- TEAMS
-- ======================================================================

t.test('TeamsAreStartable accepts 7v1 while allowUnequal is on', function()
    t.isTrue(Config.Teams.allowUnequal)

    local ok, reason = Arena.TeamsAreStartable(roster({
        { team = 'crimson', count = 7 },
        { team = 'ash', count = 1 },
    }))
    t.isTrue(ok)
    t.isNil(reason)
end)

t.test('TeamsAreStartable rejects a split past maxTeamSizeDifference once allowUnequal is off', function()
    local arena, config = tweaked(function(c) c.Teams.allowUnequal = false end)
    t.equals(config.Teams.maxTeamSizeDifference, 1)

    local evenOk = arena.TeamsAreStartable(roster({ { team = 'crimson', count = 3 }, { team = 'ash', count = 3 } }))
    t.isTrue(evenOk)

    -- A difference OF the allowance is fine; one past it is not.
    local edgeOk = arena.TeamsAreStartable(roster({ { team = 'crimson', count = 2 }, { team = 'ash', count = 1 } }))
    t.isTrue(edgeOk)

    local ok, reason = arena.TeamsAreStartable(roster({ { team = 'crimson', count = 3 }, { team = 'ash', count = 1 } }))
    t.isFalse(ok)
    t.equals(reason, 'error.teams_unbalanced')

    local lopsidedOk, lopsidedReason = arena.TeamsAreStartable(roster({
        { team = 'crimson', count = 7 },
        { team = 'ash', count = 1 },
    }))
    t.isFalse(lopsidedOk)
    t.equals(lopsidedReason, 'error.teams_unbalanced')
end)

t.test('TeamsAreStartable refuses a team match with everybody on one side', function()
    local ok, reason = Arena.TeamsAreStartable(roster({ { team = 'crimson', count = 5 } }))
    t.isFalse(ok)
    t.equals(reason, 'error.need_two_teams')

    -- Nobody having picked a side counts as no side being occupied, not as
    -- one team with everyone on it.
    local unpicked, unpickedReason = Arena.TeamsAreStartable(roster({ { team = nil, count = 4 } }))
    t.isFalse(unpicked)
    t.equals(unpickedReason, 'error.need_two_teams')

    t.isFalse((Arena.TeamsAreStartable({})))
end)

t.test('TeamsAreStartable lets a one-sided match start when requireBothTeamsOccupied is off', function()
    local arena = tweaked(function(config) config.Teams.requireBothTeamsOccupied = false end)
    local ok, reason = arena.TeamsAreStartable(roster({ { team = 'crimson', count = 3 } }))
    t.isTrue(ok)
    t.isNil(reason)
end)

t.test('TeamsAreStartable enforces maxTeamSize, and treats zero as unlimited', function()
    local capped = tweaked(function(config) config.Teams.maxTeamSize = 3 end)

    local ok, reason = capped.TeamsAreStartable(roster({ { team = 'crimson', count = 4 }, { team = 'ash', count = 1 } }))
    t.isFalse(ok)
    t.equals(reason, 'error.team_over_capacity')

    t.isTrue((capped.TeamsAreStartable(roster({ { team = 'crimson', count = 3 }, { team = 'ash', count = 1 } }))))

    -- The shipped value. Forty against one is a legal arena.
    t.equals(Config.Teams.maxTeamSize, 0)
    t.isTrue((Arena.TeamsAreStartable(roster({ { team = 'crimson', count = 40 }, { team = 'ash', count = 1 } }))))
end)

t.test('TeamsAreStartable refuses before anything else when no team is enabled', function()
    local arena = tweaked(function(config)
        for _, team in pairs(config.Teams.list) do team.enabled = false end
    end)

    local ok, reason = arena.TeamsAreStartable(roster({ { team = 'crimson', count = 2 }, { team = 'ash', count = 2 } }))
    t.isFalse(ok)
    t.equals(reason, 'error.no_teams_enabled')
    t.isNil(arena.SuggestTeam({}))
end)

t.test('SuggestTeam is deterministic, and picks the smallest side', function()
    -- Config.Teams.list is a hash, so without the sort in GetEnabledTeams this
    -- would depend on pairs() ordering and differ between runs.
    for _ = 1, 25 do
        t.equals(Arena.SuggestTeam({}), 'crimson')
    end

    t.equals(Arena.SuggestTeam(roster({ { team = 'crimson', count = 1 } })), 'ash')
    t.equals(Arena.SuggestTeam(roster({ { team = 'crimson', count = 3 }, { team = 'ash', count = 1 } })), 'ash')
    -- A tie breaks on config order, every time.
    for _ = 1, 25 do
        t.equals(Arena.SuggestTeam(roster({ { team = 'crimson', count = 2 }, { team = 'ash', count = 2 } })), 'crimson')
    end
end)

t.test('CanDamage keeps teammates safe in a team mode while friendlyFire is off', function()
    t.isFalse(Config.Teams.friendlyFire)
    t.isFalse(Arena.CanDamage('tdm', 'crimson', 'crimson'))
    t.isFalse(Arena.CanDamage('tdm', 'ash', 'ash'))
    t.isTrue(Arena.CanDamage('tdm', 'crimson', 'ash'))
end)

t.test('CanDamage lets teammates hurt each other once friendlyFire is on', function()
    local arena = tweaked(function(config) config.Teams.friendlyFire = true end)
    t.isTrue(arena.CanDamage('tdm', 'crimson', 'crimson'))
    t.isTrue(arena.CanDamage('tdm', 'crimson', 'ash'))
end)

t.test('CanDamage is always true in a free-for-all', function()
    -- Same team key on both sides, friendly fire off, and it still passes:
    -- in FFA the team field is not a thing that protects anybody.
    t.isTrue(Arena.CanDamage('ffa', 'crimson', 'crimson'))
    t.isTrue(Arena.CanDamage('ffa', nil, nil))
    t.isTrue(Arena.CanDamage('ffa', 'crimson', 'ash'))
end)

t.test('CanDamage treats an unknown or disabled mode as a free-for-all', function()
    t.isTrue(Arena.CanDamage('nosuchmode', 'crimson', 'crimson'))
    t.isTrue(Arena.CanDamage(nil, 'crimson', 'crimson'))
    t.isTrue(Arena.CanDamage({}, 'crimson', 'crimson'))
    -- gungame ships disabled, so it resolves to no mode at all.
    t.isFalse(Arena.ModeUsesTeams('gungame'))
    t.isTrue(Arena.CanDamage('gungame', 'crimson', 'crimson'))
end)

t.test('CanDamage does not protect a player with no usable team', function()
    t.isTrue(Arena.CanDamage('tdm', nil, 'crimson'))
    t.isTrue(Arena.CanDamage('tdm', 'crimson', nil))
    t.isTrue(Arena.CanDamage('tdm', 5, 'crimson'))
    t.isTrue(Arena.CanDamage('tdm', '', ''))
end)

-- ======================================================================
-- SPAWNS
-- ======================================================================

t.test('PickSpawn hands out spawn points round-robin and wraps past the end', function()
    -- Counts are DERIVED, never written down here. An operator adding a spawn
    -- point to a shipped arena -- which this resource actively invites -- must
    -- not turn a spec red, and the round-robin is the behaviour under test,
    -- not how many points happen to be in the config today.
    local spawns = Config.Arenas.airfield.spawns
    local count = #spawns
    t.isTrue(count >= 2, 'the round-robin cannot be shown with fewer than two spawn points')

    for index = 1, count do
        t.equals(Arena.PickSpawn('airfield', nil, index), spawns[index], 'index ' .. index)
    end
    -- More players than spawn points: the list starts over rather than running out.
    t.equals(Arena.PickSpawn('airfield', nil, count + 1), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, count + 2), spawns[2])
    t.equals(Arena.PickSpawn('airfield', nil, (count * 2) + 1), spawns[1])
    -- A number no lobby will ever reach still lands somewhere real.
    t.equals(Arena.PickSpawn('airfield', nil, (count * 100)), spawns[count])
end)

t.test('PickSpawn uses a team own spawn list, and wraps that too', function()
    local crimson = Config.Arenas.airfield.teamSpawns.crimson
    local count = #crimson
    t.isTrue(count >= 2, 'a team needs at least two spawn points to show the wrap')

    for index = 1, count do
        t.equals(Arena.PickSpawn('airfield', 'crimson', index), crimson[index], 'index ' .. index)
    end
    t.equals(Arena.PickSpawn('airfield', 'crimson', count + 1), crimson[1], 'the team list wraps too')
end)

t.test('PickSpawn falls back from an empty or missing teamSpawns to the shared list', function()
    local spawns = Config.Arenas.airfield.spawns
    -- 'bone' ships disabled and has no spawns anywhere: this is what an
    -- operator enabling a third team gets before they edit any arena.
    t.equals(Arena.PickSpawn('airfield', 'bone', 1), spawns[1])
    t.equals(Arena.PickSpawn('airfield', 'bone', #spawns + 1), spawns[1])

    local arena, config = tweaked(function(c) c.Arenas.airfield.teamSpawns.crimson = {} end)
    t.equals(arena.PickSpawn('airfield', 'crimson', 1), config.Arenas.airfield.spawns[1])
    t.equals(arena.PickSpawn('airfield', 'crimson', 2), config.Arenas.airfield.spawns[2])

    -- A teamSpawns table that is not a table is worth no more than a missing one.
    local broken, brokenConfig = tweaked(function(c) c.Arenas.airfield.teamSpawns = 'nope' end)
    t.equals(broken.PickSpawn('airfield', 'crimson', 2), brokenConfig.Arenas.airfield.spawns[2])
end)

t.test('PickSpawn returns nil for an unknown arena', function()
    t.isNil(Arena.PickSpawn('nosucharena', nil, 1))
    t.isNil(Arena.PickSpawn('', nil, 1))
    t.isNil(Arena.PickSpawn(nil, nil, 1))
    t.isNil(Arena.PickSpawn(7, nil, 1))
    t.isNil(Arena.PickSpawn({}, nil, 1))

    -- A disabled arena is unknown as far as everything outside config is
    -- concerned, spawn points or not.
    local arena = tweaked(function(config) config.Arenas.airfield.enabled = false end)
    t.isNil(arena.PickSpawn('airfield', nil, 1))
end)

t.test('PickSpawn returns nil for an arena with nowhere to land', function()
    local emptied = tweaked(function(config)
        config.Arenas.airfield.spawns = {}
        config.Arenas.airfield.teamSpawns = nil
    end)
    t.isNil(emptied.PickSpawn('airfield', nil, 1))
    t.isNil(emptied.PickSpawn('airfield', 'crimson', 1))

    local removed = tweaked(function(config)
        config.Arenas.airfield.spawns = nil
        config.Arenas.airfield.teamSpawns = nil
    end)
    t.isNil(removed.PickSpawn('airfield', nil, 1))
end)

t.test('PickSpawn puts a junk index on the first spawn rather than nowhere', function()
    local spawns = Config.Arenas.airfield.spawns
    t.equals(Arena.PickSpawn('airfield', nil, 0), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, -3), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, nil), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, 'first'), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, {}), spawns[1])
    t.equals(Arena.PickSpawn('airfield', nil, '3'), spawns[3])
    t.equals(Arena.PickSpawn('airfield', nil, 2.9), spawns[2])
end)

-- ======================================================================
-- CAPACITY
-- ======================================================================

t.test('HasRoom treats maxPlayers = 0 as unlimited', function()
    t.equals(Config.Match.maxPlayers, 0)
    t.isTrue(Arena.HasRoom(0))
    t.isTrue(Arena.HasRoom(1))
    t.isTrue(Arena.HasRoom(1000000))
    t.isTrue(Arena.HasRoom(nil))
    t.isTrue(Arena.HasRoom('900'))
end)

t.test('HasRoom enforces a real ceiling', function()
    local arena = tweaked(function(config) config.Match.maxPlayers = 4 end)
    t.isTrue(arena.HasRoom(0))
    t.isTrue(arena.HasRoom(3))
    t.isFalse(arena.HasRoom(4))
    t.isFalse(arena.HasRoom(5))
    t.isFalse(arena.HasRoom('4'))
    -- An unreadable head count is read as none, which is the safe direction
    -- only because the caller counts the lobby itself.
    t.isTrue(arena.HasRoom(nil))
end)

t.test('HasRoom reads a negative ceiling as unlimited, not as full', function()
    local arena = tweaked(function(config) config.Match.maxPlayers = -5 end)
    t.isTrue(arena.HasRoom(9999))
end)

-- ======================================================================
-- ValidateConfig
-- ======================================================================

t.test("ValidateConfig accepts both logo styles and nothing else", function()
    -- The panel falls back to 'mark' for anything it does not recognise, so
    -- a typo here is otherwise SILENT: an operator who wrote 'Banner' sees
    -- their full lockup drawn as a fingernail-sized badge and concludes the
    -- setting does nothing rather than that they misspelled it.
    for _, style in ipairs({ 'mark', 'banner' }) do
        local arena = tweaked(function(config) config.UI.logoStyle = style end)
        t.equals(#arena.ValidateConfig(), 0, style .. ' should be accepted')
    end

    -- Absent is fine too: the key is optional and the panel has a default.
    local absent = tweaked(function(config) config.UI.logoStyle = nil end)
    t.equals(#absent.ValidateConfig(), 0, 'an unset logoStyle should not complain')

    local wrong = tweaked(function(config) config.UI.logoStyle = 'Banner' end)
    local problems = wrong.ValidateConfig()
    t.equals(#problems, 1, table.concat(problems, ' | '))
    t.contains(problems[1], 'Banner', 'the complaint should quote what was actually written')
    t.contains(problems[1], 'mark')
end)

t.test('ValidateConfig catches a duplicate weapon key', function()
    local arena = tweaked(function(config)
        local weapons = config.Loadouts.weapons
        weapons[#weapons + 1] = {
            key = 'pistol',
            weapon = 'WEAPON_COMBATPISTOL',
            label = 'Shadowed Pistol',
            category = 'sidearm',
            enabled = true,
            ammo = { default = 60, options = { 30, 60, 120 }, max = 250 },
        }
    end)

    local problems = arena.ValidateConfig()
    t.equals(#problems, 1, table.concat(problems, ' | '))
    t.contains(problems[1], 'pistol')
    t.contains(problems[1], 'two entries')
    -- And the complaint is true: the second entry is genuinely unreachable.
    t.equals(arena.GetWeaponByKey('pistol').label, 'Pistol')
end)

t.test('ValidateConfig catches an ammo option above the weapon max', function()
    local arena = tweaked(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.key == 'sniper' then weapon.ammo.options = { 10, 20, 40, 999 } end
        end
    end)

    local problems = arena.ValidateConfig()
    t.equals(#problems, 1, table.concat(problems, ' | '))
    t.contains(problems[1], 'sniper')
    t.contains(problems[1], '999')

    -- Why it matters: the option is on the list, so it passes the list check
    -- and is then clamped -- a player picking 999 silently gets that weapon's
    -- max instead, with nothing telling them.
    --
    -- Read off the weapon rather than written as a number here. The behaviour
    -- under test is the clamp, not the sniper's current allowance, and a test
    -- that hardcodes a config value fails the next time somebody retunes it --
    -- which teaches people to edit the test instead of reading it.
    local tweakedSniper = arena.GetWeaponByKey('sniper')
    t.equals(arena.ResolveAmmo(tweakedSniper, 999), tweakedSniper.ammo.max)
end)

t.test('ValidateConfig catches an arena with no spawns', function()
    local emptied = tweaked(function(config) config.Arenas.beach.spawns = {} end)
    local problems = emptied.ValidateConfig()
    t.equals(#problems, 1, table.concat(problems, ' | '))
    t.contains(problems[1], 'beach')
    t.contains(problems[1], 'no spawns')

    -- A spawns key that was deleted rather than emptied is the same fault.
    local removed = tweaked(function(config) config.Arenas.beach.spawns = nil end)
    local removedProblems = removed.ValidateConfig()
    t.equals(#removedProblems, 1, table.concat(removedProblems, ' | '))
    t.contains(removedProblems[1], 'beach')
end)

t.test('ValidateConfig reports rather than throws, and finds every fault at once', function()
    local arena = tweaked(function(config)
        config.Arenas.beach.spawns = {}
        config.Loadouts.weapons[1].key = nil
        config.Match.lives = 0
    end)

    local problems = arena.ValidateConfig()
    -- Three independent faults, three complaints, no error raised: a typo in
    -- config.lua must not take the resource down at start.
    t.equals(#problems, 3, table.concat(problems, ' | '))
end)
-- ======================================================================
-- HexToRgb -- one source for every place a team is coloured
--
-- The outline drawn round a teammate in the world is derived from the same
-- hex the panel is tinted with and the same team the map blip belongs to.
-- That is what makes "the outline matches the dot" true by construction
-- rather than by an operator keeping two fields in step.
-- ======================================================================

t.test('a full hex is read as three channels', function()
    local r, g, b = Arena.HexToRgb('#c81020')
    t.equals(r, 200) t.equals(g, 16) t.equals(b, 32)
end)

t.test('the hash is optional, because half the world writes it without one', function()
    local r, g, b = Arena.HexToRgb('4a4a52')
    t.equals(r, 74) t.equals(g, 74) t.equals(b, 82)
end)

t.test('a three-digit hex doubles each digit, which is the standard reading', function()
    -- '#c12' IS '#cc1122'. Not an approximation of it.
    local r, g, b = Arena.HexToRgb('#c12')
    t.equals(r, 204) t.equals(g, 17) t.equals(b, 34)
end)

t.test('anything else is nil, so the caller falls back rather than guessing', function()
    -- A wrong colour drawn confidently is worse than no outline: a white
    -- edge round half the lobby says nothing about sides.
    t.isNil(Arena.HexToRgb('nonsense'))
    t.isNil(Arena.HexToRgb('#12345'))
    t.isNil(Arena.HexToRgb('#gg0000'))
    t.isNil(Arena.HexToRgb(''))
    t.isNil(Arena.HexToRgb(nil))
    t.isNil(Arena.HexToRgb(0xc81020))
    t.isNil(Arena.HexToRgb({ 200, 16, 32 }))
end)

t.test('every shipped team has a colour the outline can actually use', function()
    -- The outline is drawn from this field. A team whose colour cannot be
    -- read gets no outline at all, silently, so it is worth failing here
    -- instead of in a round.
    for _, team in ipairs(Arena.GetEnabledTeams()) do
        local r = Arena.HexToRgb(team.color)
        t.isNotNil(r, ('team "%s" has colour %s, which cannot be read as RGB'):format(
            tostring(team.key), tostring(team.color)))
    end
end)

t.test('and the shipped config really draws them, or none of that matters', function()
    t.isTrue(Config.Teams.showTeamBlips == true, 'teammates are not on the map')
    t.isTrue(Config.Teams.showTeamOutline == true, 'teammates have no outline')
    t.isFalse(Config.Teams.showEnemyBlips == true,
        'enemies are permanently on the map, which is what the radar exists to replace')
end)

-- ======================================================================
-- WHAT COUNTS AS A COORDINATE
-- ======================================================================

t.test('a coordinate is a point whichever of the runtime\'s shapes it arrives in', function()
    -- THE GUARD THIS REPLACED WAS WRONG EVERYWHERE IT APPEARED, and it
    -- appeared four times. config.lua writes coordinates as vector3/vector4;
    -- GetEntityCoords and GetModelDimensions return vector3s. In the
    -- CitizenFX Lua runtime each of those is its OWN type -- `type(v)` is
    -- 'vector3' -- so a check for 'table' says no to every real coordinate
    -- and yes to every one built by hand in a test.
    local env = Sandbox.newArenaEnv()
    local rules = env.Arena

    t.isTrue(rules.IsPoint(env.vector3(1.0, 2.0, 3.0)), 'a vector3 is not being read as a coordinate')
    t.isTrue(rules.IsPoint(env.vector4(1.0, 2.0, 3.0, 4.0)), 'a vector4 is not being read as a coordinate')
    t.isTrue(rules.IsPoint(env.vector2(1.0, 2.0)), 'a vector2 is not being read as a coordinate')
    t.isTrue(rules.IsPoint({ x = 1.0, y = 2.0, z = 3.0 }), 'a plain table is not being read as a coordinate')
    t.isTrue(rules.IsPoint({ 1.0, 2.0, 3.0 }), 'an array of numbers is not being read as a coordinate')
end)

t.test('and the shapes that are not coordinates are still refused', function()
    -- The other direction, because a predicate that says yes to everything
    -- passes the test above and protects nothing.
    local rules = Sandbox.newArenaEnv().Arena
    t.isTrue(not rules.IsPoint(nil))
    t.isTrue(not rules.IsPoint(12.0))
    t.isTrue(not rules.IsPoint('1500,3000,1201'))
    t.isTrue(not rules.IsPoint(true))
    t.isTrue(not rules.IsPoint(function() end))
end)

t.test('every coordinate the shipped config writes is one', function()
    -- Against the real file, so this cannot drift from what an operator
    -- actually has in front of them.
    local env = Sandbox.newArenaEnv()
    Sandbox.enableAllArenas(env)
    local rules = env.Arena

    local checked = 0
    for key, arena in pairs(env.Config.Arenas) do
        for _, field in ipairs({ 'spawnArea', 'boundary' }) do
            local block = arena[field]
            if type(block) == 'table' and block.center ~= nil then
                t.isTrue(rules.IsPoint(block.center),
                    ('%s.%s.center is not readable as a coordinate'):format(tostring(key), field))
                checked = checked + 1
            end
        end
        for index, spawn in ipairs(arena.spawns or {}) do
            t.isTrue(rules.IsPoint(spawn),
                ('%s.spawns[%d] is not readable as a coordinate'):format(tostring(key), index))
            checked = checked + 1
        end
    end
    t.isTrue(checked >= 8, ('only %d coordinates were checked -- the config stopped having any'):format(checked))
end)

os.exit(t.summary())
