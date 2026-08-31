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

-- ----------------------------------------------------------------------
-- DEPENDENCIES. Deliberately short.
--
-- FXServer refuses to start this resource until everything on this list is
-- running, and it checks the list before config.lua is ever read -- so
-- anything named here is required on EVERY install, whatever the operator
-- switched off. That is why only the two things this resource genuinely
-- cannot run without are named:
--
--   qbx_core -- players, jobs, money. There is no arena without it.
--   ox_lib   -- notifications, callbacks and the locale loader below.
--
-- Everything else is checked at run time instead, so a missing one degrades
-- one feature with a line in the console rather than refusing to boot:
--
--   ox_target    -- the lobby NPC. Without it the ground marker is put up in
--                   its place at the same spot (client/main.lua).
--   ox_inventory -- ammunition items, and the stash a player's own kit is
--                   held in. Only reached when Config.Loadouts.ammoItems or
--                   the strip-on-entry rule is switched on (server/ammo.lua).
--   oxmysql      -- the all-time leaderboard. Only reached when
--                   Config.Database.enabled is true, which it is not by
--                   default; off, the leaderboard covers the current server
--                   run and no database is involved at all (server/stats.lua).
--
-- All three ship with Qbox and will almost always be present. Naming them
-- here anyway would only mean that a server which had legitimately removed
-- one -- or was still starting it -- could not run the arena either.
-- ----------------------------------------------------------------------
dependencies {
    'qbx_core',
    'ox_lib',
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
    -- No '@oxmysql/lib/MySQL.lua' here on purpose. A manifest include is not
    -- optional -- listing it would make oxmysql mandatory for every install,
    -- including the default one that has the database switched off and needs
    -- no database at all. server/stats.lua goes through the oxmysql export
    -- instead, which is a run-time question with a run-time answer.
    'server/util.lua',
    -- Straight after util.lua, whose ArenaDebug it calls, and before every
    -- file that flags a player as being in the arena.
    'server/dispatch.lua',
    -- Hands out ammunition items and takes every one of them back. After
    -- util (whose logging it uses) and before match.lua, which drives it.
    'server/ammo.lua',
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
