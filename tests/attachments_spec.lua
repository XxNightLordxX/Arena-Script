--[[
    crimson_arena/tests/attachments_spec.lua

    A COMPONENT FITTED TO THE WRONG WEAPON FAILS SILENTLY.

    That is the whole reason this file exists. GTA does not complain when a
    weapon is handed a component it does not accept -- the component simply
    never appears. There is no error, no log line and nothing in the
    inventory to look at: the player just has a gun without the scope they
    were told it came with, and the only way anybody finds out is by
    noticing. A typo here is therefore invisible in exactly the way a typo
    in a config normally is not.

    So the table is checked rather than trusted: every name is shaped like a
    component, no weapon names the same one twice, and -- the part that
    matters -- every weapon it names is a weapon this resource actually
    hands out.

    AND THE THREE FAMILIES THAT MUST STAY OUT. Mk2 ammo clips change what a
    bullet does, thermal and night scopes change what a fight is, and camo
    is cosmetic ownership the arena has no business granting. Each is
    checked for by name, because the way they come back is somebody adding
    "just one" later.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('attachments_spec')

local env = Sandbox.newArenaEnv()
local Arena, Config = env.Arena, env.Config

local function catalogue()
    return Config.Loadouts.weapons or {}
end

local function attachmentTable()
    return Config.Loadouts.weaponAttachments or {}
end

-- ======================================================================
-- THE DATA
-- ======================================================================

t.test('every weapon the attachment table names is one the arena hands out', function()
    -- A row for a weapon that is not in the catalogue is dead weight at
    -- best, and at worst it is a misspelling of one that IS -- in which
    -- case the real weapon is silently issued bare.
    local known = {}
    for _, w in ipairs(catalogue()) do known[w.weapon] = true end

    local checked = 0
    for weapon in pairs(attachmentTable()) do
        checked = checked + 1
        t.isTrue(known[weapon] == true,
            ('the attachment table names %s, which is not in Config.Loadouts.weapons'):format(weapon))
    end
    t.isTrue(checked > 0, 'the attachment table is empty, so this test checks nothing')
end)

t.test('and every name in it is an ox_inventory component item, not a GTA one', function()
    -- THE SHAPE IS THE BUG. ox_inventory equips an attachment with
    -- `Items[name].client.component`, unguarded: a name it does not know is
    -- nil, the index throws, and the throw lands between GiveWeaponToPed and
    -- SetCurrentPedWeapon -- so the fighter holds a weapon the game will not
    -- draw. This table shipped full of GTA's own COMPONENT_ names, which
    -- ox_inventory has never accepted, so every weapon in it was affected on
    -- every server with attachments on.
    --
    -- ox_inventory's own names are lower case and start `at_`. Asserting the
    -- shape is not the same as asserting the name exists -- only the running
    -- server's item list can say that, and server/ammo.lua asks it before it
    -- writes anything onto a weapon -- but a COMPONENT_ name is wrong here on
    -- sight, and that is the mistake that got made.
    local checked = 0
    for weapon, row in pairs(attachmentTable()) do
        t.equals(type(row), 'table', ('%s has a %s, not a table'):format(weapon, type(row)))
        for kind, component in pairs(row) do
            checked = checked + 1
            t.isTrue(type(component) == 'string' and component:match('^at_%l') ~= nil,
                ('%s.%s is "%s", which is not an ox_inventory component item -- those are '
                    .. 'named at_scope_medium, at_grip, at_suppressor_heavy and so on. A GTA '
                    .. 'COMPONENT_ name here stops the weapon being drawn at all.')
                    :format(weapon, kind, tostring(component)))
        end
    end
    t.isTrue(checked > 20, ('only %d component(s) checked'):format(checked))
end)


-- ======================================================================
-- AND THAT EVERY NAME IS ONE ox_inventory REALLY SHIPS
--
-- THE CHECK ABOVE IS A SHAPE CHECK, and a shape check is what let the
-- original fault ship. Every value in that table matched `^COMPONENT_%u`
-- perfectly; all 180 of them were wrong, because ox_inventory does not take
-- GTA's names. Swapping the pattern for `^at_%l` fixed the values but not
-- the weakness: `at_scope_enormous` matches it too, and would reach a
-- weapon and stop it being drawn exactly as the old names did.
--
-- So the names are checked against a list of what ox_inventory actually
-- ships, read out of its own data/weapons.lua `Components` block rather
-- than remembered. Thirty-two items, skins excluded -- those are cosmetic
-- and the table above bans them by name anyway.
--
-- WHAT THIS CANNOT DO, said plainly so nobody trusts it further than it
-- goes: it cannot know what the OPERATOR'S ox_inventory has. A server with
-- a customised Components block, or one older than a name used here, will
-- differ -- which is why server/ammo.lua asks the running inventory at
-- start-up and drops what it does not have. This is the cheaper half: it
-- catches a name that is wrong EVERYWHERE, at the moment it is typed,
-- instead of on somebody's server.
-- ======================================================================

--- Every component item in ox_inventory's shipped data/weapons.lua, skins
--- excluded. Present in every release checked, v2.30.0 through current.
local OX_COMPONENTS = {
    'at_barrel', 'at_clip_drum_rifle', 'at_clip_drum_shotgun',
    'at_clip_drum_smg', 'at_clip_extended_mg', 'at_clip_extended_pistol',
    'at_clip_extended_rifle', 'at_clip_extended_shotgun',
    'at_clip_extended_smg', 'at_clip_extended_sniper', 'at_compensator',
    'at_flashlight', 'at_grip', 'at_muzzle_bell', 'at_muzzle_fat',
    'at_muzzle_flat', 'at_muzzle_heavy', 'at_muzzle_precision',
    'at_muzzle_slanted', 'at_muzzle_split', 'at_muzzle_squared',
    'at_muzzle_tactical', 'at_scope_advanced', 'at_scope_holo',
    'at_scope_large', 'at_scope_macro', 'at_scope_medium', 'at_scope_nv',
    'at_scope_small', 'at_scope_thermal', 'at_suppressor_heavy',
    'at_suppressor_light',
}

t.test('every configured attachment is an item ox_inventory really ships', function()
    local known = {}
    for _, name in ipairs(OX_COMPONENTS) do known[name] = true end

    local checked, unknown = 0, {}
    for weapon, row in pairs(attachmentTable()) do
        for kind, component in pairs(row) do
            checked = checked + 1
            if not known[component] then
                unknown[#unknown + 1] = ('%s.%s = %s'):format(weapon, kind, tostring(component))
            end
        end
    end
    table.sort(unknown)

    t.isTrue(checked > 20, ('only %d name(s) checked'):format(checked))
    t.equals(#unknown, 0, ('these are not ox_inventory component items, so ox_inventory would '
        .. 'throw on them and the weapon would not come out: %s'):format(table.concat(unknown, ', ')))
end)

t.test('and the ammunition components are real items too', function()
    -- A `component` on an ammoTypes line goes into the same metadata.components
    -- list and breaks a weapon in exactly the same way. Nothing in the shipped
    -- catalogue carries one, which is the state this asserts -- add one and it
    -- has to be a real item like everything else.
    local known = {}
    for _, name in ipairs(OX_COMPONENTS) do known[name] = true end

    local bad = {}
    for _, entry in ipairs(catalogue()) do
        for _, ammoType in ipairs(entry.ammoTypes or {}) do
            local name = type(ammoType) == 'table' and ammoType.component or nil
            if name ~= nil and not known[name] then
                bad[#bad + 1] = ('%s/%s = %s'):format(tostring(entry.weapon),
                    tostring(ammoType.key), tostring(name))
            end
        end
    end
    table.sort(bad)

    t.equals(#bad, 0, ('an ammunition type names a component ox_inventory does not ship: %s')
        :format(table.concat(bad, ', ')))
end)

t.test('and every weapon catalogue entry\'s own components list too', function()
    local known = {}
    for _, name in ipairs(OX_COMPONENTS) do known[name] = true end

    local bad = {}
    for _, entry in ipairs(catalogue()) do
        for _, name in ipairs(entry.components or {}) do
            if not known[name] then
                bad[#bad + 1] = ('%s = %s'):format(tostring(entry.weapon), tostring(name))
            end
        end
    end
    table.sort(bad)

    t.equals(#bad, 0, ('a weapon\'s own components list names something ox_inventory does not '
        .. 'ship: %s'):format(table.concat(bad, ', ')))
end)

t.test('and no weapon is fitted with the same component twice', function()
    for weapon, row in pairs(attachmentTable()) do
        local seen = {}
        for kind, component in pairs(row) do
            t.isNil(seen[component],
                ('%s lists %s as both %s and %s'):format(weapon, component, tostring(seen[component]), kind))
            seen[component] = kind
        end
    end
end)

t.test('THE THREE THAT MUST STAY OUT: no ammo clips, no thermal, no camo', function()
    -- Each of these is a change to how a round is FOUGHT rather than a
    -- change to a gun, which is not what "fitted automatically" may mean.
    -- PLAIN SUBSTRINGS, ONE PER ROW, AND NOT A PATTERN BETWEEN THEM.
    --
    -- This list was written as 'SCOPE_THERMAL|SCOPE_NV' first, which reads
    -- like an alternation and is not one: Lua patterns have no `|`, so the
    -- whole string was searched for literally, matched nothing ever, and
    -- the check passed on data it was not looking at. A mutation that put a
    -- thermal scope straight into the table did not fail a thing. Every
    -- entry below is matched with `find(..., 1, true)` -- plain text, no
    -- pattern -- so there is nothing left to be clever and wrong about.
    local banned = {
        { 'CLIP_FMJ',           'an FMJ clip' },
        { 'CLIP_HOLLOWPOINT',   'a hollow-point clip' },
        { 'CLIP_INCENDIARY',    'an incendiary clip' },
        { 'CLIP_TRACER',        'a tracer clip' },
        { 'CLIP_DRUM',          'a drum magazine' },
        { 'SCOPE_THERMAL',      'a thermal scope' },
        { 'SCOPE_NV',           'a night scope' },
        { 'AT_SKIN_',           'a weapon skin' },
        { 'CAMO',               'camo' },
        { 'LIVERY',             'a livery' },
        { 'VARMOD',             'a varmod skin' },
        { 'GUNRUN_MK2_UPGRADE', 'the Mk2 conversion kit' },
    }

    local checked = 0
    for weapon, row in pairs(attachmentTable()) do
        for kind, component in pairs(row) do
            local upper = component:upper()
            for _, entry in ipairs(banned) do
                checked = checked + 1
                t.isNil(upper:find(entry[1], 1, true),
                    ('%s.%s is %s -- that is %s, which is fitted on purpose by nobody')
                        :format(weapon, kind, component, entry[2]))
            end
        end
    end
    t.isTrue(checked > 100, ('only %d check(s) ran'):format(checked))
end)

-- ======================================================================
-- THE WIRING
-- ======================================================================

t.test('a weapon that can take them is issued with them fitted', function()
    local weapon
    for _, w in ipairs(catalogue()) do
        if w.weapon == 'WEAPON_CARBINERIFLE' then weapon = w end
    end
    t.isNotNil(weapon, 'the carbine is not in the catalogue, so this proves nothing')

    local entry = Arena.ResolveWeaponEntry(weapon, nil, nil)
    t.isTrue(#entry.components > 0,
        'the carbine was issued with nothing fitted at all')

    local joined = table.concat(entry.components, ',')
    t.contains(joined, 'at_scope',
        ('the carbine came without its scope: %s'):format(joined))
end)

t.test('and a weapon that can take none is still issued, just bare', function()
    -- The bat. A weapon with no row must not be a refusal, an error or an
    -- empty loadout slot -- it is simply handed over as it always was.
    local weapon
    for _, w in ipairs(catalogue()) do
        if w.weapon == 'WEAPON_BAT' then weapon = w end
    end
    t.isNotNil(weapon, 'the bat is not in the catalogue, so this proves nothing')

    local entry = Arena.ResolveWeaponEntry(weapon, nil, nil)
    t.equals(#entry.components, 0, 'something was fitted to a baseball bat')
    t.equals(entry.weapon, 'WEAPON_BAT', 'the bat stopped being issued at all')
end)

t.test('the switch really switches: off means nothing is fitted', function()
    local was = Config.Loadouts.attachments
    Config.Loadouts.attachments = { enabled = false, fit = { 'scope' } }

    local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE')
    Config.Loadouts.attachments = was

    t.equals(#fitted, 0, 'attachments were fitted with the whole feature switched off')
end)

t.test('and a kind left out of the list is never fitted', function()
    -- The suppressor ships OUT of the list on purpose: a suppressed shot
    -- does not put the shooter on the minimap, which changes how a round is
    -- fought. If it ever starts arriving by default, that is this test's
    -- business.
    local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE')
    for _, component in ipairs(fitted) do
        t.isNil(component:upper():find('SUPP'),
            ('a suppressor (%s) was fitted, and it is not in the shipped list'):format(component))
    end
end)

t.test('asking for one kind fits exactly that kind', function()
    local was = Config.Loadouts.attachments
    Config.Loadouts.attachments = { enabled = true, fit = { 'extendedclip' } }

    local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE')
    Config.Loadouts.attachments = was

    t.equals(#fitted, 1, ('asked for one kind and got %d'):format(#fitted))
    t.contains(fitted[1], 'clip', ('%s is not a magazine'):format(fitted[1]))
end)

t.test('a component named by two kinds is fitted once, not twice', function()
    -- ox_inventory is handed this list verbatim. A weapon whose data names
    -- the same component under two kinds -- a rail that is both the
    -- flashlight mount and the sight on some weapons -- would otherwise be
    -- sent it twice. Nothing in the shipped table does this today, which is
    -- exactly why it is worth pinning: the guard is invisible until some
    -- future row needs it.
    local was = Config.Loadouts
    Config.Loadouts = {
        attachments = { enabled = true, fit = { 'scope', 'flashlight', 'grip' } },
        weaponAttachments = {
            ['WEAPON_TESTGUN'] = {
                scope = 'COMPONENT_SHARED_RAIL',
                flashlight = 'COMPONENT_SHARED_RAIL',
                grip = 'COMPONENT_REAL_GRIP',
            },
        },
    }

    local fitted = Arena.AttachmentsFor('WEAPON_TESTGUN')
    Config.Loadouts = was

    t.equals(#fitted, 2, ('the same component was fitted %d time(s)'):format(#fitted))
    t.equals(fitted[1], 'COMPONENT_SHARED_RAIL', 'the first kind asked for did not win')
    t.equals(fitted[2], 'COMPONENT_REAL_GRIP')
end)

t.test('a weapon nobody listed is not an error', function()
    t.equals(#Arena.AttachmentsFor('WEAPON_NOT_A_REAL_GUN'), 0)
    t.equals(#Arena.AttachmentsFor(nil), 0)
    t.equals(#Arena.AttachmentsFor(42), 0)
    t.equals(#Arena.AttachmentsFor(''), 0)
end)

t.test('a hand-written components list still arrives, with the fitted ones after it', function()
    -- The per-weapon `components` field predates this and an operator may
    -- have written one. Fitting must ADD to it, never take it over.
    local entry = Arena.ResolveWeaponEntry({
        key = 'test', weapon = 'WEAPON_CARBINERIFLE', label = 'Test',
        components = { 'COMPONENT_HAND_WRITTEN' },
        ammo = { default = 30, max = 30 },
    }, nil, nil)

    t.equals(entry.components[1], 'COMPONENT_HAND_WRITTEN',
        'the operator\'s own component was dropped or reordered')
    t.isTrue(#entry.components > 1, 'nothing was fitted alongside it')
end)

-- ======================================================================
-- CHOOSING THEM, PER WEAPON, PER MATCH
-- ======================================================================

t.test('the picker is only offered what that weapon can really take', function()
    -- Same rule the ammo types follow: the options come from the table the
    -- server fits from, so a chip can never offer something the server would
    -- then refuse.
    local carbine = Arena.AttachmentOptionsFor('WEAPON_CARBINERIFLE')
    t.isTrue(#carbine > 0, 'the carbine offers no attachments at all')

    local map = attachmentTable()['WEAPON_CARBINERIFLE']
    for _, option in ipairs(carbine) do
        t.isTrue(Arena.IsKey(map[option.key]),
            ('the picker offers %s, which the carbine has no component for'):format(option.key))
        t.isTrue(Arena.IsKey(option.label), ('%s has no label to draw'):format(option.key))
    end
end)

t.test('and a weapon that takes none offers none, rather than an empty row', function()
    t.equals(#Arena.AttachmentOptionsFor('WEAPON_BAT'), 0)
    t.equals(#Arena.AttachmentOptionsFor('WEAPON_NOT_REAL'), 0)
end)

t.test('ticking one fits exactly that one', function()
    local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE', { 'scope' })
    t.equals(#fitted, 1, ('asked for a scope and got %d thing(s)'):format(#fitted))
    t.contains(fitted[1], 'scope', ('%s is not a scope'):format(fitted[1]))
end)

t.test('and taking everything off really fits nothing', function()
    -- AN EMPTY LIST IS AN ANSWER, not an absence. If this fell back to the
    -- default a player could never take an attachment off -- which is the
    -- whole point of a picker.
    t.equals(#Arena.AttachmentsFor('WEAPON_CARBINERIFLE', {}), 0,
        'a player who unticked everything was fitted with things anyway')
end)

t.test('while asking for nothing at all still means the default', function()
    -- nil is not {} here: a pick nobody touched, and every loadout saved
    -- before this existed, must still arrive fitted.
    t.isTrue(#Arena.AttachmentsFor('WEAPON_CARBINERIFLE', nil) > 0,
        'an untouched pick arrived bare')
end)

t.test('THE SECURITY: a client cannot ask for a component, only a kind', function()
    -- The list that crosses the wire is kind keys. If a raw component name
    -- could be passed through, a client could fit itself anything at all --
    -- a thermal scope, an incendiary clip, a component from another weapon.
    local hostile = {
        'COMPONENT_AT_SCOPE_THERMAL',
        'COMPONENT_PISTOL_MK2_CLIP_INCENDIARY',
        'COMPONENT_AT_AR_SUPP',
        'scope; DROP TABLE',
        '../../etc/passwd',
    }

    local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE', hostile)
    t.equals(#fitted, 0,
        ('a client got %s fitted by naming it directly'):format(table.concat(fitted, ',')))
end)

t.test('and a kind that weapon does not have is ignored, not invented', function()
    -- The pistol has no grip. Asking for one must not reach for another
    -- weapon's grip, and must not raise.
    local fitted = Arena.AttachmentsFor('WEAPON_PISTOL', { 'grip', 'barrel' })
    t.equals(#fitted, 0, ('the pistol was fitted with %s'):format(table.concat(fitted, ',')))
end)

t.test('a loadout request carries the choice through to the weapon', function()
    -- End to end through the function the server really calls.
    local resolved = Arena.ResolveLoadout({
        weapons = { { key = 'carbine', ammo = 30, attachments = { 'scope' } } },
    })

    t.equals(#resolved.weapons, 1, 'the carbine did not make it into the loadout')
    local entry = resolved.weapons[1]
    t.equals(#entry.components, 1,
        ('one attachment was asked for and %d arrived'):format(#entry.components))
    t.contains(entry.components[1], 'scope')
end)

t.test('and two weapons in one loadout are fitted separately', function()
    local resolved = Arena.ResolveLoadout({
        weapons = {
            { key = 'carbine', ammo = 30, attachments = { 'scope' } },
            { key = 'pistol', ammo = 12, attachments = {} },
        },
    })

    t.equals(#resolved.weapons, 2)
    t.equals(#resolved.weapons[1].components, 1, 'the carbine lost its scope')
    t.equals(#resolved.weapons[2].components, 0, 'the stripped pistol was fitted anyway')
end)

-- ======================================================================
-- ...OR THE OPERATOR FITS THEM AND NOBODY PICKS
--
-- Config.Loadouts.attachments.allowChoose. It ships TRUE -- the picker above
-- is what a player gets -- and an operator turning it off wants one arena
-- where everybody is issued the same gun.
--
-- NOT THE SAME SWITCH AS `enabled`. That one takes attachments away
-- altogether; this one is about who decides.
--
-- THE CHOICE IS DROPPED, NOT CHECKED. A greyed-out button stops nobody, so
-- the gate lives inside Arena.AttachmentsFor -- the single door every
-- attachment goes through -- rather than at the call sites, where a caller
-- added later could forget it.
-- ======================================================================

--- Arena, with attachments fitted by the server rather than picked.
--- @return table Arena
local function operatorFits()
    local env = Sandbox.newArenaEnv({})
    env.Config.Loadouts.attachments.allowChoose = false
    return env.Arena
end

t.test('the picker ships ON, so nothing changes for a server that never set it', function()
    t.isTrue(Arena.AttachmentsAreChosen(),
        'the shipped config no longer lets a player pick their own attachments')
end)

t.test('and an operator who turns it off gets the full fitted set', function()
    local A = operatorFits()
    t.isFalse(A.AttachmentsAreChosen())

    local fitted = A.AttachmentsFor('WEAPON_CARBINERIFLE', nil)
    t.isTrue(#fitted > 0, 'the carbine was issued bare on an auto-fitting server')
end)

t.test('THE POINT: a picked list is IGNORED, not honoured', function()
    local A = operatorFits()
    local full = A.AttachmentsFor('WEAPON_CARBINERIFLE', nil)

    local asked = A.AttachmentsFor('WEAPON_CARBINERIFLE', { 'scope' })
    t.equals(table.concat(asked, ','), table.concat(full, ','),
        'a player picked one kind and got one kind on a server that fits them all')
end)

t.test('WITH THE PICKER ON, a client naming components rather than kinds fits nothing', function()
    -- The other half of the same guarantee, on the SHIPPED setting.
    --
    -- What reaches the player's weapon is written into ox_inventory's
    -- `metadata.components`, and ox_inventory equips that with
    -- `Items[name].client.component`, unguarded -- a name it does not know
    -- throws, and the throw leaves the weapon undrawable. So the question is
    -- not only "can a client fit itself something it should not", it is "can
    -- a client put an arbitrary STRING in front of that lookup".
    --
    -- It cannot, and the reason is structural rather than a filter: what a
    -- client sends is only ever used to ask `ticked[kind]`, and the string
    -- that goes on the gun is always read out of the config row. Every
    -- payload below is a kind that does not exist, so it ticks nothing.
    for _, payload in ipairs({
        { 'COMPONENT_AT_SCOPE_MEDIUM' },   -- a GTA component name
        { 'at_scope_medium' },             -- the real item name, sent as a kind
        { 'at_scope_thermal' },            -- a component the arena excludes
        { 'water' },                       -- a real ox_inventory item
        { 'WEAPON_RPG' },                  -- a weapon
        { 42, {}, false, '' },             -- not strings at all
    }) do
        local fitted = Arena.AttachmentsFor('WEAPON_CARBINERIFLE', payload)
        t.equals(#fitted, 0,
            ('a client sent %s and got %s onto the weapon')
                :format(tostring(payload[1]), table.concat(fitted, ',')))
    end
end)

t.test('and the same payloads through ResolveWeaponEntry, which is what builds the loadout', function()
    local weapon
    for _, w in ipairs(catalogue()) do
        if w.weapon == 'WEAPON_CARBINERIFLE' then weapon = w end
    end
    t.isNotNil(weapon, 'the carbine is not in the catalogue, so this proves nothing')

    for _, payload in ipairs({
        { 'COMPONENT_AT_SCOPE_MEDIUM' },
        { 'at_scope_medium' },
        { 'os.exit()' },
    }) do
        local entry = Arena.ResolveWeaponEntry(weapon, nil, nil, payload)
        t.equals(#entry.components, 0,
            ('%s reached the weapon through the loadout path'):format(tostring(payload[1])))
    end
end)

t.test('and an EMPTY list cannot strip a gun either', function()
    -- The half that matters more. With the picker on, {} means "I took
    -- everything off" -- so if it survived here, anybody could still issue
    -- themselves a bare weapon on an arena meant to standardise kit.
    local A = operatorFits()
    local full = A.AttachmentsFor('WEAPON_CARBINERIFLE', nil)

    t.equals(table.concat(A.AttachmentsFor('WEAPON_CARBINERIFLE', {}), ','),
        table.concat(full, ','),
        'A PLAYER UNTICKED EVERYTHING AND WAS ISSUED A BARE GUN')
end)

t.test('and neither can a hostile client naming components directly', function()
    local A = operatorFits()
    local full = A.AttachmentsFor('WEAPON_CARBINERIFLE', nil)

    t.equals(table.concat(A.AttachmentsFor('WEAPON_CARBINERIFLE', {
        'COMPONENT_AT_SCOPE_THERMAL', 'scope', 42, '', false,
    }), ','), table.concat(full, ','),
        'junk from a client changed what went on the gun')
end)

t.test('the whole loadout goes through the same gate, not just the helper', function()
    -- ResolveWeaponEntry is what actually builds what a player carries. A
    -- gate the helper honours and the entry path does not is no gate at all.
    local A = operatorFits()

    local carbine
    for _, row in ipairs(A.GetWeaponCatalogue and A.GetWeaponCatalogue() or {}) do
        if row.weapon == 'WEAPON_CARBINERIFLE' then carbine = row break end
    end
    if carbine == nil then
        local env = Sandbox.newArenaEnv({})
        for _, row in ipairs(env.Config.Loadouts.weapons or {}) do
            if row.weapon == 'WEAPON_CARBINERIFLE' then carbine = row break end
        end
    end
    t.isNotNil(carbine, 'the carbine is no longer in the catalogue')

    local bare = A.ResolveWeaponEntry(carbine, nil, 0, {})
    local full = A.ResolveWeaponEntry(carbine, nil, 0, nil)
    t.equals(table.concat(bare.attachments or {}, ','),
        table.concat(full.attachments or {}, ','),
        'the entry path honoured a choice the helper drops')
end)

t.test('A CONFIG THAT NEVER HEARD OF THE SETTING KEEPS ITS PICKER', function()
    -- READ AS `~= false`, NOT `== true`, and this is the only test that can
    -- tell the two apart -- the shipped config now carries the key, so every
    -- other test here passes either way.
    --
    -- An operator upgrading from a config written before this existed has no
    -- `allowChoose` at all. Reading it as `== true` would silently take the
    -- picker away from them, which is a feature vanishing on an upgrade
    -- nobody asked for.
    local env = Sandbox.newArenaEnv({})
    env.Config.Loadouts.attachments.allowChoose = nil

    t.isTrue(env.Arena.AttachmentsAreChosen(),
        'a config from before this setting existed lost its attachment picker')
    t.equals(#env.Arena.AttachmentsFor('WEAPON_CARBINERIFLE', { 'scope' }), 1,
        'and stopped honouring a choice it used to honour')
end)

t.test('and `enabled = false` still beats it: no attachments at all', function()
    -- The two switches are not alternatives. Off means off, whoever chooses.
    --
    -- allowChoose LEFT ON, deliberately. Setting both to false lets the
    -- second one carry the test on its own, and the `enabled` guard could
    -- then be deleted with everything still green -- measured.
    local env = Sandbox.newArenaEnv({})
    env.Config.Loadouts.attachments.enabled = false
    env.Config.Loadouts.attachments.allowChoose = true

    t.isFalse(env.Arena.AttachmentsAreChosen(),
        'a server with attachments switched off still claims a player picks them')
    t.equals(#env.Arena.AttachmentsFor('WEAPON_CARBINERIFLE', nil), 0,
        'attachments were fitted on a server that has them switched off')
end)

t.test('the panel is told which of the two it is', function()
    -- The chips are drawn read-only off this, so it has to be on the wire.
    local env = Sandbox.newArenaEnv({})
    t.isTrue(env.Arena.AttachmentsAreChosen(), 'the shipped default moved')

    env.Config.Loadouts.attachments.allowChoose = false
    t.isFalse(env.Arena.AttachmentsAreChosen())
end)

os.exit(t.summary())
