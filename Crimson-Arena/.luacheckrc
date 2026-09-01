-- crimson_arena/.luacheckrc
--
-- luacheck runs this resource OUTSIDE FiveM, where none of the runtime it is
-- written against exists. Every name below is something a real VM provides at
-- run time and a bare `luacheck` cannot know about: a CitizenFX native, an
-- ox_lib or qbx_core global, or one of this resource's own documented exports.
--
-- THE LIST IS DELIBERATELY EXACT, NOT A BLANKET ALLOW. Allowing every native
-- CFX has ever shipped would make this file quiet and useless -- a typo'd
-- native name is exactly the bug luacheck is here to catch, and it can only
-- catch it while the allow-list is the natives this resource actually calls.
-- Adding a native call therefore means adding a line here, on purpose.
--
-- REALMS ARE SEPARATE. A client file that calls a server-only native, or the
-- reverse, is a crash in production and a warning here, which is the whole
-- point of splitting the sections rather than pooling them.

std = 'lua54'

-- FiveM hands every handler a fixed set of arguments and ox_lib's NUI
-- callbacks a fixed (data, cb) pair. A handler that legitimately ignores one
-- of them still reads better naming it than taking `_`, so an unused argument
-- is not a finding here.
unused_args = false

-- config.lua's tables, the log and locale format strings, and native calls
-- that take a dozen coordinates in a row are all clearer on one line than
-- wrapped. Line length is a style rule this codebase does not keep.
max_line_length = false

-- Nothing is allowed globally: `read_globals` stays empty at the top level so
-- tests/ (plain lua5.4, no FiveM) cannot silently start calling a native.
read_globals = {}

files = {}

-- ----------------------------------------------------------------------
-- SHARED -- loaded into BOTH Lua VMs from fxmanifest.lua's shared_scripts.
--
-- config.lua and shared/arena.lua may use nothing realm-specific.
-- shared/arena.lua calls no native at all, which is what lets tests/ load it
-- under plain lua5.4.
--
-- shared/compat/dispatch.lua is the one shared file that does call natives,
-- and every one of them is SHARED-realm: it works out which VM it is in from
-- IsDuplicityVersion() and keeps the report, the adapter mutes and its
-- command behind that check. A client-only or server-only native turning up
-- in its list below is a bug rather than a new entry.
-- ----------------------------------------------------------------------

files['config.lua'] = {
    globals = { 'Config' },
    -- CitizenFX Lua RUNTIME TYPES, not natives -- config.lua calls them while
    -- the file is still loading.
    read_globals = { 'vector3', 'vector4' },
}

files['shared/arena.lua'] = {
    globals = { 'Arena' },
    read_globals = { 'Config' },
}

files['shared/compat/dispatch.lua'] = {
    -- The adapter registry, the detection walk and the startup report.
    globals = { 'ArenaCompat' },

    read_globals = {
        -- SERVER-ONLY, and read from the report -- which runs on the server,
        -- after server/dispatch.lua has loaded. It answers whether OneSync
        -- is actually on, which is what decides whether isolation is real
        -- rather than merely configured.
        'ArenaDispatch',
        -- Shared realm, read-only: the catalogue reads the operator's hook
        -- names out of Config and validates every registration with
        -- Arena.IsKey.
        'Arena',
        'Config',

        -- Which VM this copy is running in. Shared, and the reason none of
        -- the server-only names below are ever reached on a client.
        'IsDuplicityVersion',

        -- Detection itself: the whole catalogue is a name and this answer.
        'GetResourceState',

        -- Scheduling, events, resource identity and the /arenadispatch
        -- command. Every one of them is registered on the server side of
        -- the realm check.
        'AddEventHandler',
        'CreateThread',
        'GetCurrentResourceName',
        'RegisterCommand',
        'Wait',

        -- server/util.lua's helpers, called only from the server branch and
        -- only at run time -- server_scripts load after this file, so none
        -- of these exists while it is still loading.
        'ArenaIsAdmin',
        'ArenaNotify',
        'ArenaNotifyKey',
    },
}

-- ----------------------------------------------------------------------
-- MANIFEST -- fxmanifest.lua is a Lua chunk run against FXServer's own
-- manifest DSL, so every directive in it is a global function call.
-- ----------------------------------------------------------------------

files['fxmanifest.lua'] = {
    read_globals = {
        'author',
        'client_scripts',
        'dependencies',
        'description',
        'files',
        'fx_version',
        'game',
        'lua54',
        'name',
        'ox_lib',
        'server_scripts',
        'shared_scripts',
        'ui_page',
        'version',
    },
}

-- ----------------------------------------------------------------------
-- CLIENT
-- ----------------------------------------------------------------------

files['client/'] = {
    -- This realm's own exports, in the order fxmanifest.lua loads them.
    globals = { 'ArenaUI', 'ArenaDispatch', 'ArenaState', 'ArenaSpectate', 'ArenaMatch' },

    read_globals = {
        -- Shared realm, read-only from here: the client never writes a rule.
        'ExecuteCommand', 'Arena',
        'Config',

        -- Dispatch suppression (client/dispatch.lua). The wanted-level and
        -- police natives are only ever called between entering and leaving a
        -- match, and every one of them is undone on the way out.
        'GetEntityMaxHealth',
        'GetPlayerWantedLevel',
        'GetResourceState',
        'SetDispatchCopsForPlayer',
        'SetPlayerWantedLevel',
        'SetPlayerWantedLevelNow',
        'SetPoliceIgnorePlayer',

        -- ox_lib (@ox_lib/init.lua) and its locale loader.
        'lib',
        'locale',
        -- `cache` and `QBX` are the rest of the ox_lib / qbx_core client
        -- surface. Nothing here reads them yet; they are allowed ahead of use
        -- because they are framework globals rather than natives, so their
        -- names cannot be typo'd into something that only fails in production.
        'cache',
        'QBX',

        -- Resource exports: ox_target for the lobby ped, qbx_core elsewhere.
        'exports',

        -- CitizenFX runtime types.
        'vector3',

        -- Scheduling, events and resource identity.
        'AddEventHandler',
        'CreateThread',
        'GetCurrentResourceName',
        'GetGameTimer', 'GetGroundZFor_3dCoord',
        'RegisterCommand',
        'RegisterNetEvent',
        'TriggerEvent',
        'TriggerServerEvent',
        'Wait',

        -- NUI.
        'RegisterNUICallback',
        'SendNUIMessage',
        'SetNuiFocus',

        -- Models.
        'HasModelLoaded',
        'IsModelInCdimage',
        'IsModelValid',
        'RequestModel',
        'SetModelAsNoLongerNeeded',
        'joaat',

        -- Entities: the lobby ped, and the player's own.
        'ApplyDamageToPed',
        'ClearPedBloodDamage', 'ResetPedVisibleDamage', 'ClearPedLastWeaponDamage', 'ClearPedTasksImmediately', 'SetPedCanRagdoll', 'AnimpostfxStopAll', 'IsPedRagdoll', 'IsPedInWrithe',
        'SetEntityDrawOutline', 'SetEntityDrawOutlineColor',
        'CreatePed',
        'DeleteEntity',
        'DoesEntityExist',
        'FreezeEntityPosition',
        'GetEntityCoords',
        'GetEntityHeading',
        'GetEntityHealth',
        'GetPedSourceOfDeath',
        'HasCollisionLoadedAroundEntity',
        'IsEntityAPed',
        'IsEntityDead',
        'RequestCollisionAtCoord',
        'SetBlockingOfNonTemporaryEvents',
        'SetEntityAsMissionEntity',
        'SetEntityCollision',
        'SetEntityCoordsNoOffset',
        'SetEntityHeading',
        'SetEntityHealth',
        'SetEntityInvincible',
        'SetEntityVisible',
        -- The arena's own scenery: a floor for an arena in the sky, and
        -- cover to fight over. Built client-side and local to each fighter,
        -- so these are the object natives rather than the networked ones.
        'CreateObject',
        -- Asked what a prop actually IS, rather than trusting a size typed
        -- into config: the floor is tiled on the model's real footprint and
        -- the walkable surface is its real top.
        'GetModelDimensions',
        'DeleteObject',
        'IsModelInCdimage',
        'IsModelValid',
        -- A script-created prop starts on the engine's short default draw
        -- distance, so a floor tiled out of them flickers and changes shape
        -- as you walk it while staying solid underfoot.
        'SetEntityLodDist',
        -- FINDING SCENERY NOBODY IS TRACKING. The handle list only covers
        -- pieces this client remembers creating; a build aborted halfway or a
        -- resource restarted with a round live leaves props behind that no
        -- list knows about, and the next round builds its floor inside them.
        'GetGamePool',
        'GetEntityModel',
        'SetLocalPlayerVisibleLocally',
        'TaskStartScenarioInPlace',

        -- Players, local and remote.
        'GetPlayerFromServerId',
        'GetPlayerName',
        'GetPlayerPed',
        'GetPlayerServerId',
        'IsPedAPlayer',
        'NetworkGetPlayerIndexFromPed',
        'NetworkIsPlayerActive',
        'NetworkResurrectLocalPlayer',
        'PlayerId',
        'PlayerPedId',

        -- Weapons and armour -- the loadout, and giving the player theirs back.
        'GetAmmoInPedWeapon',
        'GetPedArmour',
        'GetSelectedPedWeapon',
        'GiveWeaponComponentToPed',
        'GiveWeaponToPed',
        'HasPedGotWeapon',
        'RemoveAllPedWeapons',
        'RemoveWeaponFromPed',
        'SetCurrentPedWeapon',
        'SetPedAmmo',
        'SetPedArmour',
        'SetPedWeaponTintIndex',

        -- Blips: the one on the lobby, and one on each living fighter for
        -- the length of a round (Config.Teams.showTeamBlips/showEnemyBlips).
        'AddBlipForCoord',
        'AddBlipForEntity',
        'AddTextComponentSubstringPlayerName',
        'BeginTextCommandSetBlipName',
        'DoesBlipExist',
        'EndTextCommandSetBlipName',
        'RemoveBlip',
        'SetBlipAsShortRange',
        'SetBlipColour',
        'SetBlipDisplay',
        'SetBlipScale',
        'SetBlipSprite',

        -- The lobby marker and its help text.
        'BeginTextCommandDisplayHelp',
        'DrawMarker',
        'EndTextCommandDisplayHelp',

        -- Controls: locked down during a round and while spectating.
        'DisableAllControlActions',
        'DisableControlAction',
        'EnableControlAction',
        'GetDisabledControlNormal',
        'IsControlJustReleased',
        'IsDisabledControlJustPressed',
        'IsDisabledControlPressed',
        'IsPauseMenuActive',
        'SetFrontendActive',

        -- The spectator camera.
        'ClearFocus',
        'CreateCam',
        'DestroyCam',
        'RenderScriptCams',
        'SetCamActive',
        'SetCamCoord',
        'SetCamRot',
        'SetFocusEntity',
        'SetFocusPosAndVel',
        'DisablePlayerFiring',
        'SetEntityDrawOutlineShader',

        -- Per-arena weather and time overrides.
        'ClearOverrideWeather',
        'NetworkClearClockTimeOverride',
        'NetworkOverrideClockTime',
        'SetWeatherTypeNowPersist',
    },
}

-- ----------------------------------------------------------------------
-- SERVER
-- ----------------------------------------------------------------------

files['server/'] = {
    -- The whole cross-file API, in the order fxmanifest.lua loads it:
    -- util.lua's helpers, then the four namespaces.
    globals = {
        -- Defined in shared/compat/dispatch.lua, which the server manifest
        -- loads first. Read here to find the revive event of whichever
        -- medical script this box actually runs.
        'ArenaCompat',
        'ArenaCanCreate',
        'ArenaCanJoin',
        'ArenaDebug',
        'ArenaForgetPlayer',
        'ArenaGetPlayer',
        'ArenaIsAdmin',
        'ArenaLog',
        'ArenaNewId',
        'ArenaNotify',
        'ArenaNotifyKey',
        'ArenaPlayerName',
        'ArenaRateLimit',
        'ArenaWebhook',
        'ArenaAmmo',
        'ArenaDispatch',
        'ArenaStats',
        'ArenaBetting',
        'ArenaLobby',
        'ArenaMatch',
    },

    read_globals = {
        -- server/ammo.lua checks ox_inventory is actually running
        -- before it tries to hand anybody anything.
        'GetResourceState',

        -- server/dispatch.lua defers withdrawing an arena alert until after
        -- the sending resource's own handler has created it. Clearing a call
        -- that does not exist yet clears nothing, so the delay is the whole
        -- mechanism rather than a tidy-up.
        'SetTimeout',

        -- Shared realm. The server is the authority ON these rules, not over
        -- them: it reads the same functions the client does and never edits.
        'Arena',
        'Config',

        -- Server-side state bags. server/dispatch.lua writes the arena flag
        -- through Player(src).state so a third-party dispatch script can
        -- trust it -- a bag written from the client can be written by any
        -- client.
        'Player',

        -- server/dispatch.lua announces arena entry and exit on an
        -- operator-named SERVER event, so a custom dispatch script can keep
        -- its own ignore list.
        'TriggerEvent',

        -- Best-effort event cancelling (server/dispatch.lua). Raises the
        -- cancel flag on an operator-named alert event. WasEventCanceled is
        -- deliberately NOT here: this resource only ever sets that flag and
        -- never reads it -- whether anything acts on it belongs to the
        -- resource that raised the event.
        'CancelEvent',

        -- ox_lib and its locale loader. `cache` and `QBX` complete the
        -- ox_lib / qbx_core surface and are allowed ahead of use for the same
        -- reason they are on the client side.
        'lib',
        'locale',
        'cache',
        'QBX',

        -- exports.qbx_core:GetPlayer is the only export this realm calls.
        'exports',

        -- oxmysql (@oxmysql/lib/MySQL.lua). Present whatever
        -- Config.Database.enabled says, because it is a hard fxmanifest
        -- dependency -- server/stats.lua just never queries through it.
        'MySQL',

        -- The server id of whoever raised the event being handled. Read into
        -- a local before anything yields; never assigned.
        'source',

        -- Scheduling, events and resource identity.
        'AddEventHandler',
        'CreateThread',
        'GetCurrentResourceName',
        'GetGameTimer',
        'RegisterCommand',
        'RegisterNetEvent',
        'TriggerClientEvent',
        'Wait',

        -- Server-side player queries, for the join gates and for logging.
        'GetPlayerName',
        'GetPlayerPed',
        'GetVehiclePedIsIn',
        'IsPlayerAceAllowed',
        -- Where a live fighter currently is, read by the respawn picker so a
        -- player who lost a life is not put back next to whoever took it.
        -- Server-side reads of a client-owned entity can legitimately fail,
        -- so the caller treats an unreadable position as one to skip.
        'GetEntityCoords',

        -- Routing buckets (server/dispatch.lua). A match is fought in its
        -- own network instance, which is set server-side and never on a
        -- client's say-so -- these have no client-realm counterpart on
        -- purpose.
        'GetPlayerRoutingBucket',
        -- THE CROSSFIRE GUARD. weaponDamageEvent and explosionEvent name the
        -- entities a shot hit by NETWORK id, and only the server can say
        -- which player owns one -- so the guard walks the players and asks.
        'GetPlayers',
        'NetworkGetNetworkIdFromEntity',
        -- Routing buckets need OneSync; without it every bucket native is
        -- inert and silent. This is how the resource finds out.
        'GetConvar',
        'SetPlayerRoutingBucket',
        'SetRoutingBucketEntityLockdownMode',
        'SetRoutingBucketPopulationEnabled',

        -- The Discord webhook.
        'ExecuteCommand', 'IsPrincipalAceAllowed', 'PerformHttpRequest',
        'json',
    },
}

-- ----------------------------------------------------------------------
-- TESTS
--
-- Deliberately given nothing. Specs run under plain lua5.4 through
-- tests/run.sh, load production files into a sandbox environment table, and
-- reach the harness with dofile() -- so a native or a bare global appearing
-- in one is a spec that will not run, and should be reported as such.
-- ----------------------------------------------------------------------

files['tests/'] = {
    std = 'lua54',
}
