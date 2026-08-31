fx_version 'cerulean'
game 'gta5'

name 'crimson_arena'
author 'John Allday'
description 'Configurable PvP arena for Qbox: ped-started matches, player-chosen weapons and ammo, player-chosen teams that may be uneven, and an optional betting pot.'
version '1.0.0'

lua54 'yes'

-- ox_lib's locale loader. Reads locales/<Config.Locale>.json and exposes
-- `locale(key, ...)` in both realms -- the same convention every qbx_*
-- resource uses.
ox_lib 'locale'

dependencies {
    'qbx_core',
    'ox_lib',
    'ox_target',
    -- HARD dependency even with Config.Database.enabled = false. FXServer
    -- checks this list before config.lua is ever read, so no setting can
    -- route around it. Turning the database off means this resource sends
    -- oxmysql no queries and needs none of its own tables -- it does NOT
    -- mean you can uninstall oxmysql.
    'oxmysql',
}

-- ----------------------------------------------------------------------
-- SHARED. Loaded into BOTH Lua VMs from the same source.
--
-- ORDER IS LOAD-BEARING: config.lua defines the `Config` global that
-- shared/arena.lua reads on every call, so config must come first. Both
-- must come before any client or server file, since every one of them
-- calls Arena.* at some point.
--
-- shared/compat/dispatch.lua comes last of the three because it reads both:
-- Config for the operator's hook names, and Arena.IsKey to validate every
-- adapter it registers -- and it registers them while the file is still
-- loading. It is shared rather than server-only because the catalogue and
-- the detection walk are the same question in either realm; the file works
-- out which realm it is in and keeps the report, the mutes and the
-- /arenadispatch command on the server.
-- ----------------------------------------------------------------------
shared_scripts {
    '@ox_lib/init.lua',
    '@qbx_core/modules/lib.lua',
    'config.lua',
    'shared/arena.lua',
    'shared/compat/dispatch.lua',
}

-- ----------------------------------------------------------------------
-- CLIENT.
--
-- playerdata.lua gives us the live `QBX.PlayerData` cache (job, citizenid)
-- without this resource re-inventing one.
--
-- ORDER: ui.lua defines the NUI bridge that main.lua's ped interaction and
-- match.lua's HUD both push through, so it loads first. dispatch.lua next,
-- because match.lua calls into it on every entry, death and exit. main.lua
-- owns the lobby and the cached server state that match.lua and
-- spectate.lua read.
-- ----------------------------------------------------------------------
client_scripts {
    '@qbx_core/modules/playerdata.lua',
    'client/ui.lua',
    'client/dispatch.lua',
    'client/main.lua',
    'client/match.lua',
    'client/spectate.lua',
}

-- ----------------------------------------------------------------------
-- SERVER.
--
-- ORDER, strictly: shared primitives (util, dispatch, stats) -> betting ->
-- lobby -> match -> main. Each file calls only into globals defined by a file above
-- it at LOAD time. The one upward call -- lobby.lua auto-starting a match
-- through ArenaMatch.Begin -- happens at RUN time, inside an event handler,
-- long after every file has finished loading, so it needs no existence
-- guard. main.lua is last because it registers the net events and callbacks
-- that reach into all of them.
-- ----------------------------------------------------------------------
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/util.lua',
    -- Straight after util.lua, whose ArenaDebug it calls, and before every
    -- file that flags a player as being in the arena.
    'server/dispatch.lua',
    'server/stats.lua',
    'server/betting.lua',
    'server/lobby.lua',
    'server/match.lua',
    'server/main.lua',
}

-- The arena panel. One page, opened and closed like a modal (unlike a
-- passive HUD) -- client/ui.lua takes and releases NUI focus around it.
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    -- The server logo in the panel header. Replace the FILE, not this line.
    -- An image the manifest does not list is silently not sent to clients:
    -- it renders as nothing, with no error saying why.
    'html/images/logo.png',
    'locales/en.json',
}
