-- Crimson Arena: the weapons the arena may hand out.

Config.Loadouts.weapons = {
    -- GENERATED FROM THIS SERVER'S OWN ox_inventory weapons.lua.
    --
    -- Every entry below is a weapon that really exists in this server's
    -- inventory, and every `item` in an `ammoTypes` line is the ammo item
    -- that weapon's own `ammoname` field names. Neither was guessed: a
    -- weapon the inventory does not define cannot be handed out, and an
    -- ammo item it does not define cannot be given, so both are read from
    -- the source rather than from a list of what GTA usually calls things.
    --
    -- `ammoTypes` is per weapon here rather than one shared list, because
    -- on this server the round differs by weapon -- a 9mm and a 12 gauge
    -- are separate items. That is exactly the per-weapon override
    -- config.lua's Config.Loadouts.defaultAmmoTypes note describes.
    --
    -- `components` ON AN ENTRY IS A HAND-WRITTEN ATTACHMENT LIST, separate
    -- from Config.Loadouts.weaponAttachments further down and appended to
    -- whatever that fits. Every name in it -- and every `component` on an
    -- ammoTypes line -- is an ox_inventory component ITEM name, the same as
    -- that table: `at_scope_medium`, not `COMPONENT_AT_SCOPE_MEDIUM`. A GTA
    -- name here is not a component that fails to appear, it is a weapon the
    -- game will not draw; the note above that table says why at length.
    -- server/ammo.lua drops any name this server's ox_inventory does not
    -- have and says so in the console, so a mistake costs an attachment
    -- rather than the weapon -- but it is still a mistake.
    --
    -- NINETY-THREE OF THE 96 ENTRIES BELOW ARE `enabled = true`, INCLUDING ALL
    -- THIRTEEN HEAVY WEAPONS -- the RPG, the homing, grenade, EMP, compact
    -- and firework launchers, the minigun, both railguns, the Unholy
    -- Hellbringer, the Widowmaker and the flamethrower. The MUSKET, the
    -- DOUBLE-BARREL SHOTGUN and the MARKSMAN RIFLE are the three exceptions
    -- and are switched off at the owner's instruction. Everything else being
    -- on is deliberate: the arena was asked to offer
    -- everything this server owns.
    --
    -- WHY THOSE THREE AND NOT OTHERS, because it matters to anyone running
    -- this somewhere else: it is an ANTI-CHEAT on the owner's server and NOT
    -- anything in this file. That anti-cheat stops those three firing no
    -- matter how much ammunition the arena hands out. The arena's own side of
    -- it -- the weapon, the round, the item name, the count -- was measured
    -- and is correct for all three, so there is no arena bug here and nothing
    -- to fix; switching them off is the fix. DO NOT go hunting for a broken
    -- ammo mapping on the strength of these three being off, and DO NOT
    -- "correct" one: they are right. On a server without that anti-cheat all
    -- three work, and one word each turns them back on.
    --
    -- IT IS A DECISION AND NOT A DEFAULT, so it is written down. Explosive
    -- damage is not refused between teammates whatever
    -- Config.Teams.friendlyFire says -- the crossfire guard allows or
    -- refuses an explosion whole -- so on a team mode a launcher kills the
    -- side that fired it. config.lua says the same beside friendlyFire.
    --
    -- TO TAKE ONE OUT OF THE ARENA, set `enabled = false` on its entry
    -- here. That is the whole job: the server re-checks every loadout
    -- request against this list before a round is handed out, so a switched
    -- off weapon is genuinely gone rather than merely hidden from the panel,
    -- and an edited client cannot ask for it. Delete the block instead and
    -- it is gone too -- but `enabled = false` keeps the ammo item names for
    -- when you change your mind.

    {
        key = 'acidspray',
        weapon = 'WEAPON_ACIDSPRAY',
        label = '200ML Acid Spray',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '1Ml acid ammo', item = 'ammo-acidspray' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pepperspray',
        weapon = 'WEAPON_PEPPERSPRAY',
        label = '200ML Pepper Spray',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '1Ml pepper ammo', item = 'ammo-pepperspray' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pinkpepperspray',
        weapon = 'WEAPON_PINKPEPPERSPRAY',
        label = '200ML Pepper Spray',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '1Ml pepper ammo', item = 'ammo-pepperspray' } },
        components = {},
        tint = 0,
    },
    {
        key = 'spraypaint',
        weapon = 'WEAPON_SPRAYPAINT',
        label = '200ML Spray Paint',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '1Ml Spray Paint', item = 'ammo-spraypaint' } },
        components = {},
        tint = 0,
    },
    {
        key = 'appistol',
        weapon = 'WEAPON_APPISTOL',
        label = 'AP Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'ceramicpistol',
        weapon = 'WEAPON_CERAMICPISTOL',
        label = 'Ceramic Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'combatpistol',
        weapon = 'WEAPON_COMBATPISTOL',
        label = 'Combat Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'doubleaction',
        weapon = 'WEAPON_DOUBLEACTION',
        label = 'Double Action Revolver',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.38 LC', item = 'ammo-38' } },
        components = {},
        tint = 0,
    },
    {
        key = 'flaregun',
        weapon = 'WEAPON_FLAREGUN',
        label = 'Flare Gun',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Flare round', item = 'ammo-flare' } },
        components = {},
        tint = 0,
    },
    {
        key = 'heavypistol',
        weapon = 'WEAPON_HEAVYPISTOL',
        label = 'Heavy Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'machinepistol',
        weapon = 'WEAPON_MACHINEPISTOL',
        label = 'Machine Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'nailgun',
        weapon = 'WEAPON_NAILGUN',
        label = 'Nail Gun',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Nail Ammo', item = 'ammo-nail' } },
        components = {},
        tint = 0,
    },
    {
        key = 'navyrevolver',
        weapon = 'WEAPON_NAVYREVOLVER',
        label = 'Navy Revolver',
        category = 'sidearm',
        -- SWITCHED OFF BY THE OWNER. It is also taken out of the gun game
        -- sidearm pool in config.lua, because a pool naming a weapon that is
        -- switched off fills fewer tiers than it asks for -- which the boot
        -- check now says out loud rather than leaving the ladder short.
        enabled = false,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
        components = {},
        tint = 0,
    },
    {
        key = 'gadgetpistol',
        weapon = 'WEAPON_GADGETPISTOL',
        label = 'Perico Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pistol',
        weapon = 'WEAPON_PISTOL',
        label = 'Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        -- NOT A BASE-GAME WEAPON. Every other row in this file is one GTA
        -- ships; this one is an addon the owner runs, added at their request.
        -- It follows that the usual safety net does not apply to it: a base
        -- weapon is present on every client, and this one is present only
        -- where the addon is installed.
        --
        -- IF IT IS MISSING, THE ARENA SAYS SO AT BOOT rather than at the
        -- counter. ArenaAmmo.WeaponItemReport reads every name in this file
        -- against ox_inventory's items when the resource starts, so an addon
        -- whose item is not in ox_inventory/data/weapons.lua is named there
        -- instead of leaving a fighter standing in the arena unarmed.
        --
        -- .45 ACP, ON THE OWNER'S WORD. The arena hands a weapon the rounds
        -- this row names, so a pistol that actually feeds on something else
        -- would be issued ammunition it cannot fire -- it would go out with a
        -- full magazine of the wrong thing. `ammo-45` is the item three other
        -- sidearms in this file already use, so nothing new has to exist in
        -- ox_inventory for it.
        key = 'blackice',
        weapon = 'WEAPON_BLACKICE',
        label = 'Black Ice',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pistol50',
        weapon = 'WEAPON_PISTOL50',
        label = 'Pistol .50',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.50 AE', item = 'ammo-50' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pistolmk2',
        weapon = 'WEAPON_PISTOL_MK2',
        label = 'Pistol MK2',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'revolver',
        weapon = 'WEAPON_REVOLVER',
        label = 'Revolver',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
        components = {},
        tint = 0,
    },
    {
        key = 'revolvermk2',
        weapon = 'WEAPON_REVOLVER_MK2',
        label = 'Revolver MK2',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.44 Magnum', item = 'ammo-44' } },
        components = {},
        tint = 0,
    },
    {
        key = 'snspistol',
        weapon = 'WEAPON_SNSPISTOL',
        label = 'SNS Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'snspistolmk2',
        weapon = 'WEAPON_SNSPISTOL_MK2',
        label = 'SNS Pistol MK2',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'tecpistol',
        weapon = 'WEAPON_TECPISTOL',
        label = 'Tactical SMG',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'vintagepistol',
        weapon = 'WEAPON_VINTAGEPISTOL',
        label = 'Vintage Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pistolxm3',
        weapon = 'WEAPON_PISTOLXM3',
        label = 'WM 29 Pistol',
        category = 'sidearm',
        enabled = true,
        ammo = { default = 60, options = { 30, 60, 120, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },

    {
        key = 'advancedrifle',
        weapon = 'WEAPON_ADVANCEDRIFLE',
        label = 'Advanced Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'rifle',
        weapon = 'WEAPON_ASSAULTRIFLE',
        label = 'Assault Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'riflemk2',
        weapon = 'WEAPON_ASSAULTRIFLE_MK2',
        label = 'Assault Rifle MK2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'assaultsmg',
        weapon = 'WEAPON_ASSAULTSMG',
        label = 'Assault SMG',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'battlerifle',
        weapon = 'WEAPON_BATTLERIFLE',
        label = 'Battle Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'bullpuprifle',
        weapon = 'WEAPON_BULLPUPRIFLE',
        label = 'Bullpup Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'bullpupriflemk2',
        weapon = 'WEAPON_BULLPUPRIFLE_MK2',
        label = 'Bullpup Rifle MK2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'carbine',
        weapon = 'WEAPON_CARBINERIFLE',
        label = 'Carbine Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'carbineriflemk2',
        weapon = 'WEAPON_CARBINERIFLE_MK2',
        label = 'Carbine Rifle MK2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'combatmg',
        weapon = 'WEAPON_COMBATMG',
        label = 'Combat MG',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'combatmgmk2',
        weapon = 'WEAPON_COMBATMG_MK2',
        label = 'Combat MG MK2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'combatpdw',
        weapon = 'WEAPON_COMBATPDW',
        label = 'Combat PDW',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'compactrifle',
        weapon = 'WEAPON_COMPACTRIFLE',
        label = 'Compact Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'gusenberg',
        weapon = 'WEAPON_GUSENBERG',
        label = 'Gusenberg',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'heavyrifle',
        weapon = 'WEAPON_HEAVYRIFLE',
        label = 'Heavy Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'mg',
        weapon = 'WEAPON_MG',
        label = 'Machine Gun',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'microsmg',
        weapon = 'WEAPON_MICROSMG',
        label = 'Micro SMG',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.45 ACP', item = 'ammo-45' } },
        components = {},
        tint = 0,
    },
    {
        key = 'militaryrifle',
        weapon = 'WEAPON_MILITARYRIFLE',
        label = 'Military Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'minismg',
        weapon = 'WEAPON_MINISMG',
        label = 'Mini SMG',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'smg',
        weapon = 'WEAPON_SMG',
        label = 'SMG',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'smgmk2',
        weapon = 'WEAPON_SMG_MK2',
        label = 'SMG Mk2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '9mm', item = 'ammo-9' } },
        components = {},
        tint = 0,
    },
    {
        key = 'specialcarbine',
        weapon = 'WEAPON_SPECIALCARBINE',
        label = 'Special Carbine',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'specialcarbinemk2',
        weapon = 'WEAPON_SPECIALCARBINE_MK2',
        label = 'Special Carbine MK2',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },
    {
        key = 'tacticalrifle',
        weapon = 'WEAPON_TACTICALRIFLE',
        label = 'Tactical Rifle',
        category = 'automatic',
        enabled = true,
        ammo = { default = 150, options = { 60, 150, 300, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '5.56x45', item = 'ammo-rifle' } },
        components = {},
        tint = 0,
    },

    {
        key = 'assaultshotgun',
        weapon = 'WEAPON_ASSAULTSHOTGUN',
        label = 'Assault Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'bullpupshotgun',
        weapon = 'WEAPON_BULLPUPSHOTGUN',
        label = 'Bullpup Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'combatshotgun',
        weapon = 'WEAPON_COMBATSHOTGUN',
        label = 'Combat Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'heavyshotgun',
        weapon = 'WEAPON_HEAVYSHOTGUN',
        label = 'Heavy Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'shotgun',
        weapon = 'WEAPON_PUMPSHOTGUN',
        label = 'Pump Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'pumpshotgunmk2',
        weapon = 'WEAPON_PUMPSHOTGUN_MK2',
        label = 'Pump Shotgun MK2',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'sawnoffshotgun',
        weapon = 'WEAPON_SAWNOFFSHOTGUN',
        label = 'Sawn Off Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'autoshotgun',
        weapon = 'WEAPON_AUTOSHOTGUN',
        label = 'Sweeper Shotgun',
        category = 'shotgun',
        enabled = true,
        ammo = { default = 40, options = { 20, 40, 80, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '12 Gauge', item = 'ammo-shotgun' } },
        components = {},
        tint = 0,
    },

    {
        key = 'heavysniper',
        weapon = 'WEAPON_HEAVYSNIPER',
        label = 'Heavy Sniper',
        category = 'precision',
        enabled = true,
        ammo = { default = 20, options = { 10, 20, 40, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.50 BMG', item = 'ammo-heavysniper' } },
        components = {},
        tint = 0,
    },
    {
        key = 'snipermk2',
        weapon = 'WEAPON_HEAVYSNIPER_MK2',
        label = 'Heavy Sniper MK2',
        category = 'precision',
        enabled = true,
        ammo = { default = 20, options = { 10, 20, 40, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '.50 BMG', item = 'ammo-heavysniper' } },
        components = {},
        tint = 0,
    },
    {
        key = 'precisionrifle',
        weapon = 'WEAPON_PRECISIONRIFLE',
        label = 'Precision Rifle',
        category = 'precision',
        enabled = true,
        ammo = { default = 20, options = { 10, 20, 40, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
        components = {},
        tint = 0,
    },
    {
        key = 'sniper',
        weapon = 'WEAPON_SNIPERRIFLE',
        label = 'Sniper Rifle',
        category = 'precision',
        enabled = true,
        ammo = { default = 20, options = { 10, 20, 40, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x51', item = 'ammo-sniper' } },
        components = {},
        tint = 0,
    },

    {
        key = 'emplauncher',
        weapon = 'WEAPON_EMPLAUNCHER',
        label = 'Compact EMP Launcher',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'EMP round', item = 'ammo-emp' } },
        components = {},
        tint = 0,
    },
    {
        key = 'compactlauncher',
        weapon = 'WEAPON_COMPACTLAUNCHER',
        label = 'Compact Grenade Launcher',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '40mm Explosive', item = 'ammo-grenade' } },
        components = {},
        tint = 0,
    },
    {
        key = 'firework',
        weapon = 'WEAPON_FIREWORK',
        label = 'Firework Launcher',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Firework', item = 'ammo-firework' } },
        components = {},
        tint = 0,
    },
    {
        key = 'fireworksingle',
        weapon = 'WEAPON_FIREWORKSINGLE',
        label = 'Firework Spray',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Firework', item = 'ammo-firework' } },
        components = {},
        tint = 0,
    },
    {
        key = 'flamethrower',
        weapon = 'WEAPON_FLAMETHROWER',
        label = 'Flamethrower',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Fuel', item = 'ammo-flamethrower' } },
        components = {},
        tint = 0,
    },
    {
        key = 'grenadelauncher',
        weapon = 'WEAPON_GRENADELAUNCHER',
        label = 'Grenade Launcher',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '40mm Explosive', item = 'ammo-grenade' } },
        components = {},
        tint = 0,
    },
    {
        key = 'hominglauncher',
        weapon = 'WEAPON_HOMINGLAUNCHER',
        label = 'Homing Launcher',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Rocket', item = 'ammo-rocket' } },
        components = {},
        tint = 0,
    },
    {
        key = 'minigun',
        weapon = 'WEAPON_MINIGUN',
        label = 'Minigun',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = '7.62x39', item = 'ammo-rifle2' } },
        components = {},
        tint = 0,
    },
    {
        key = 'rpg',
        weapon = 'WEAPON_RPG',
        label = 'RPG',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Rocket', item = 'ammo-rocket' } },
        components = {},
        tint = 0,
    },
    {
        key = 'railgun',
        weapon = 'WEAPON_RAILGUN',
        label = 'Railgun',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Railgun charge', item = 'ammo-railgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'railgunxm3',
        weapon = 'WEAPON_RAILGUNXM3',
        label = 'Railgun XM3',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Railgun charge', item = 'ammo-railgun' } },
        components = {},
        tint = 0,
    },
    {
        key = 'raycarbine',
        weapon = 'WEAPON_RAYCARBINE',
        label = 'Unholy Hellbringer',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Laser charge', item = 'ammo-laser' } },
        components = {},
        tint = 0,
    },
    {
        key = 'rayminigun',
        weapon = 'WEAPON_RAYMINIGUN',
        label = 'Widowmaker',
        category = 'heavy',
        enabled = true,
        ammo = { default = 8, options = { 4, 8, 16, 500 }, max = 500 },
        ammoTypes = { { key = 'standard', label = 'Laser charge', item = 'ammo-laser' } },
        components = {},
        tint = 0,
    },

    {
        key = 'bat',
        weapon = 'WEAPON_BAT',
        label = 'Bat',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'bottle',
        weapon = 'WEAPON_BOTTLE',
        label = 'Bottle',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'crowbar',
        weapon = 'WEAPON_CROWBAR',
        label = 'Crowbar',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'dagger',
        weapon = 'WEAPON_DAGGER',
        label = 'Dagger',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'golfclub',
        weapon = 'WEAPON_GOLFCLUB',
        label = 'Golf Club',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'hammer',
        weapon = 'WEAPON_HAMMER',
        label = 'Hammer',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'hatchet',
        weapon = 'WEAPON_HATCHET',
        label = 'Hatchet',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'knife',
        weapon = 'WEAPON_KNIFE',
        label = 'Knife',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'knuckles',
        weapon = 'WEAPON_KNUCKLE',
        label = 'Knuckle Dusters',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'machete',
        weapon = 'WEAPON_MACHETE',
        label = 'Machete',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'nightstick',
        weapon = 'WEAPON_NIGHTSTICK',
        label = 'Nightstick',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'poolcue',
        weapon = 'WEAPON_POOLCUE',
        label = 'Pool Cue',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'switchblade',
        weapon = 'WEAPON_SWITCHBLADE',
        label = 'Switchblade',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'wrench',
        weapon = 'WEAPON_WRENCH',
        label = 'Wrench',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'battleaxe',
        weapon = 'WEAPON_BATTLEAXE',
        label = 'Battle Axe',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'stonehatchet',
        weapon = 'WEAPON_STONE_HATCHET',
        label = 'Stone Hatchet',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'candycane',
        weapon = 'WEAPON_CANDYCANE',
        label = 'Candy Cane',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
    {
        key = 'flashlight',
        weapon = 'WEAPON_FLASHLIGHT',
        label = 'Flashlight',
        category = 'melee',
        enabled = true,
        ammo = { default = 1, options = nil, max = 1 },
        ammoTypes = false,
        components = {},
        tint = 0,
    },
}

-- ======================================================================
-- WHAT EACH WEAPON COMES FITTED WITH
--
-- FITTED AUTOMATICALLY, NOT PICKED PER WEAPON. Nobody sets an attachment on
-- a gun -- the arena looks the weapon up here, takes the kinds
-- Config.Loadouts.attachments asks for, and fits the ones this weapon can
-- actually take. A weapon that is not listed, or that has no entry for a
-- kind, is simply issued without it.
--
-- EVERY NAME BELOW IS AN ox_inventory COMPONENT ITEM -- `at_scope_medium`,
-- `at_grip`, `at_suppressor_heavy` -- and NOT one of GTA's own
-- `COMPONENT_...` names. That distinction is the whole reason this block
-- was rewritten, and getting it wrong does not fail quietly:
--
--   ox_inventory's equip path does `Items[name].client.component`. A name
--   it does not know is nil, indexing nil throws, and the throw happens
--   AFTER GiveWeaponToPed but BEFORE SetCurrentPedWeapon -- so the player
--   holds a weapon the game will not draw. On a live server that read as
--   "the gun does nothing", and turning every attachment off in the picker
--   was the only way to fire it.
--
--   This table shipped full of GTA names, so every single weapon in it was
--   affected. It is fixed by naming the ox_inventory item instead.
--
-- ox_inventory MAPS THE ITEM TO THE RIGHT GTA COMPONENT ITSELF. Each of its
-- component items carries a list of the game components it covers, and it
-- fits whichever of them `DoesWeaponTakeWeaponComponent` accepts for the
-- weapon in hand. So `at_clip_extended_rifle` is the right answer for
-- fourteen different rifles, and naming a component the weapon cannot take
-- fits nothing rather than breaking anything.
--
-- WHICH NAMES EXIST is decided by YOUR ox_inventory, in its
-- `data/weapons.lua` under `Components`. The shipped set is:
--
--   sights      at_scope_macro, at_scope_small, at_scope_medium,
--               at_scope_large, at_scope_advanced, at_scope_holo,
--               at_scope_nv, at_scope_thermal
--   magazines   at_clip_extended_pistol / _smg / _shotgun / _rifle / _mg /
--               _sniper, at_clip_drum_smg / _shotgun / _rifle
--   muzzles     at_suppressor_light, at_suppressor_heavy, at_compensator,
--               at_muzzle_flat / _tactical / _fat / _precision / _heavy /
--               _slanted / _split / _squared / _bell
--   grip        at_grip
--   barrel      at_barrel
--   flashlight  at_flashlight
--
-- A NAME THIS SERVER'S ox_inventory WILL NOT TAKE IS DROPPED, not fitted:
-- server/ammo.lua checks each one against the live item list before it
-- writes any of them onto a weapon -- that it exists AND that it is a
-- component rather than an ordinary item, because an item that is not a
-- component throws in the same place -- and says in the console exactly
-- which name it threw away and for which weapon. `/arenaattachments` prints
-- the same reading on demand.
--
-- TWO CASES IT CANNOT CHECK, and it is honest about both rather than
-- pretending. If ox_inventory will not answer Items() at all, names are
-- used as configured and the console says they were NOT checked. And on an
-- ox_inventory too old to tag its items -- no item anywhere carrying
-- `component`, `weapon`, `ammo` or `tint` -- a real item that is not a
-- component cannot be told from a component, so it is let through rather
-- than stripping every attachment off every weapon to guard against a typo.
-- On any current build neither applies, and a typo here costs you an
-- attachment rather than a weapon that will not come out.
--
-- WHERE A WEAPON OFFERS SEVERAL OF A KIND the plainest is taken: the first
-- scope rather than the biggest, the first clip rather than the drum. An
-- arena is not the place to hand everybody the largest of everything.
--
-- THREE FAMILIES ARE DELIBERATELY ABSENT and should stay absent:
--
--   DRUM MAGAZINES AND Mk2 AMMO CLIPS -- incendiary, hollow point, FMJ,
--   tracer. Those change what a bullet DOES. Fitting them automatically
--   would quietly rewrite the damage every fight is balanced around.
--
--   THERMAL AND NIGHT SCOPES (`at_scope_thermal`, `at_scope_nv`). Seeing a
--   heat signature through the dark is not a scope, it is a different game.
--
--   CAMO, LIVERIES AND VARMOD SKINS (`at_skin_...`). Cosmetic, and several
--   are tied to ownership the arena has no business granting.
--
-- WEAPON_HEAVYSNIPER HAS NO ROW, unlike its Mk2. The only scope that fits
-- it is COMPONENT_AT_SCOPE_LARGE, and stock ox_inventory ships no component
-- item covering that one -- `at_scope_large` is the Mk2 scope. Add an item
-- for it in your own data/weapons.lua and a row here will work.
--
-- ADDING ONE: find the weapon, add `kind = 'at_...'`. The suite checks every
-- name here is an ox_inventory component item spelled the way ox_inventory
-- spells one, and that no weapon names the same component twice.
-- ======================================================================

Config.Loadouts.weaponAttachments = {
    ['WEAPON_APPISTOL'] = { extendedclip = 'at_clip_extended_pistol', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_CERAMICPISTOL'] = { extendedclip = 'at_clip_extended_pistol', suppressor = 'at_suppressor_light' },
    ['WEAPON_COMBATPISTOL'] = { extendedclip = 'at_clip_extended_pistol', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_HEAVYPISTOL'] = { extendedclip = 'at_clip_extended_pistol', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_MACHINEPISTOL'] = { extendedclip = 'at_clip_extended_smg', suppressor = 'at_suppressor_light' },
    ['WEAPON_PISTOL'] = { extendedclip = 'at_clip_extended_pistol', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_PISTOL50'] = { extendedclip = 'at_clip_extended_pistol', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_PISTOL_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_pistol', muzzle = 'at_compensator', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_REVOLVER_MK2'] = { scope = 'at_scope_holo', muzzle = 'at_compensator', flashlight = 'at_flashlight' },
    ['WEAPON_SNSPISTOL'] = { extendedclip = 'at_clip_extended_pistol' },
    ['WEAPON_SNSPISTOL_MK2'] = { extendedclip = 'at_clip_extended_pistol', muzzle = 'at_compensator', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_TECPISTOL'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_pistol', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_VINTAGEPISTOL'] = { extendedclip = 'at_clip_extended_pistol', suppressor = 'at_suppressor_light' },
    ['WEAPON_PISTOLXM3'] = { suppressor = 'at_suppressor_light' },
    ['WEAPON_ADVANCEDRIFLE'] = { scope = 'at_scope_small', extendedclip = 'at_clip_extended_rifle', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_ASSAULTRIFLE'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_ASSAULTRIFLE_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', muzzle = 'at_muzzle_flat', barrel = 'at_barrel', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_ASSAULTSMG'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_smg', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_BATTLERIFLE'] = { extendedclip = 'at_clip_extended_rifle', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_BULLPUPRIFLE'] = { scope = 'at_scope_small', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_BULLPUPRIFLE_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', muzzle = 'at_muzzle_flat', barrel = 'at_barrel', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_CARBINERIFLE'] = { scope = 'at_scope_medium', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_CARBINERIFLE_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', muzzle = 'at_muzzle_flat', barrel = 'at_barrel', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_COMBATMG'] = { scope = 'at_scope_medium', extendedclip = 'at_clip_extended_mg', grip = 'at_grip' },
    ['WEAPON_COMBATMG_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_mg', grip = 'at_grip', muzzle = 'at_muzzle_flat', barrel = 'at_barrel' },
    ['WEAPON_COMBATPDW'] = { scope = 'at_scope_small', extendedclip = 'at_clip_extended_smg', grip = 'at_grip', flashlight = 'at_flashlight' },
    ['WEAPON_COMPACTRIFLE'] = { extendedclip = 'at_clip_extended_rifle' },
    ['WEAPON_GUSENBERG'] = { extendedclip = 'at_clip_extended_mg' },
    ['WEAPON_HEAVYRIFLE'] = { scope = 'at_scope_medium', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_MG'] = { scope = 'at_scope_small', extendedclip = 'at_clip_extended_mg' },
    ['WEAPON_MICROSMG'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_smg', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_MILITARYRIFLE'] = { scope = 'at_scope_small', extendedclip = 'at_clip_extended_rifle', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_MINISMG'] = { extendedclip = 'at_clip_extended_smg' },
    ['WEAPON_SMG'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_smg', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_SMG_MK2'] = { scope = 'at_scope_macro', extendedclip = 'at_clip_extended_smg', muzzle = 'at_muzzle_flat', barrel = 'at_barrel', flashlight = 'at_flashlight', suppressor = 'at_suppressor_light' },
    ['WEAPON_SPECIALCARBINE'] = { scope = 'at_scope_medium', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_SPECIALCARBINE_MK2'] = { scope = 'at_scope_holo', extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', muzzle = 'at_muzzle_flat', barrel = 'at_barrel', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_TACTICALRIFLE'] = { extendedclip = 'at_clip_extended_rifle', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_ASSAULTSHOTGUN'] = { extendedclip = 'at_clip_extended_shotgun', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_BULLPUPSHOTGUN'] = { grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_COMBATSHOTGUN'] = { flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_HEAVYSHOTGUN'] = { extendedclip = 'at_clip_extended_shotgun', grip = 'at_grip', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_PUMPSHOTGUN'] = { flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_PUMPSHOTGUN_MK2'] = { scope = 'at_scope_holo', muzzle = 'at_muzzle_squared', flashlight = 'at_flashlight', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_HEAVYSNIPER_MK2'] = { scope = 'at_scope_large', extendedclip = 'at_clip_extended_sniper', muzzle = 'at_muzzle_squared', barrel = 'at_barrel', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_SNIPERRIFLE'] = { scope = 'at_scope_advanced', suppressor = 'at_suppressor_heavy' },
    ['WEAPON_GRENADELAUNCHER'] = { scope = 'at_scope_small', grip = 'at_grip', flashlight = 'at_flashlight' },
}
