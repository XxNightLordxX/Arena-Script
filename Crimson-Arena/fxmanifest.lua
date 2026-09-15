-- Crimson Arena: what FiveM loads, and in what order.

fx_version 'cerulean'
game 'gta5'

name 'crimson_arena'
author 'John Allday'
description 'Configurable PvP arena for Qbox: ped-started matches, player-chosen weapons and ammo, player-chosen teams that may be uneven, and an optional betting pot.'
version '1.0.0'

lua54 'yes'

-- Reads locales/<ox:locale>.json, defaulting to en.
ox_lib 'locale'

-- Only what the arena cannot run at all without. FXServer refuses to start
-- the resource until everything named here is running, so ox_target,
-- ox_inventory and oxmysql are DELIBERATELY absent: they are checked as they
-- are used, and a missing one costs you one feature and a console line
-- instead of the whole arena.
dependencies {
    'qbx_core',
    'ox_lib',
}

-- Loaded into both the client and the server.
--
-- THE ORDER IS LOAD-BEARING and this is the one place it is easy to break:
-- config.lua builds the Config table, config.weapons.lua writes into it, and
-- everything after reads it. Adding a file? Put it at the end.
shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
    'config.weapons.lua',
    'shared/arena.lua',
    'shared/compat/dispatch.lua',
}

-- The order is load-bearing here too: each file uses what the ones above it
-- define. Adding a file? Put it at the end.
client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/ui.lua',
    'client/dispatch.lua',
    'client/main.lua',
    'client/match.lua',
    'client/spectate.lua',
}

-- Same rule: each file uses what the ones above it define, and main.lua is
-- last because it wires up everything else. Adding a file? Put it at the end.
--
-- '@oxmysql/lib/MySQL.lua' is NOT listed on purpose -- a manifest include is
-- not optional, and listing it would make a database mandatory for every
-- install, including the default one that has it switched off.
server_scripts {
    'server/util.lua',
    'server/dispatch.lua',
    'server/ammo.lua',
    'server/stats.lua',
    'server/betting.lua',
    'server/lobby.lua',
    'server/match.lua',
    'server/main.lua',
}

-- The arena panel.
ui_page 'html/index.html'

-- NO stream/ FOLDER, on purpose: FiveM registers every file in one as a
-- streaming asset, so a stray .md or .txt in there prints an error in every
-- player's console on every connect. Make the folder only when you have a
-- real model to put in it. See STREAMING.md.

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    -- The logo in the panel header. Replace the FILE, not this line -- an
    -- image the manifest does not list is never sent to players, and shows
    -- as nothing with no error saying why.
    'html/images/logo.png',
    'locales/en.json',
}
