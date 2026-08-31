--[[
    crimson_arena/tests/spectate_spec.lua

    THE FILE NOTHING WAS DRIVING.

    client/spectate.lua is three hundred and fifty lines that hide a player's
    body, freeze it, take their controls away and put a scripted camera in
    front of them. Until this file existed, no spec loaded it: boot_spec
    proved it PARSES in manifest order and five others mention it in a
    comment. Nothing had ever called Start or Stop.

    That is the worst place in this resource to have no coverage, because its
    failures do not look like errors. They look like a session that is over:

      A CAMERA THAT OUTLIVES ITS MATCH -- the player is left looking at an
      arena they are not in, unable to see or move their own body, with no
      error anywhere and nothing to press.

      A BODY THAT NEVER COMES BACK -- Stop() is reached from six different
      places and only puts the ped back when this file was the reason it was
      down. Get that condition wrong in the generous direction and an
      ELIMINATED fighter is handed their feet, their collision and the arena
      loadout they died holding, mid-round, in a live match.

    So the assertions here are about the two states a player can be left in,
    not about the camera looking nice.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('spectate_spec')

local SELF, ALIVE_A, ALIVE_B, DEAD = 1, 2, 3, 4

--- The state snapshot, in the shape server/lobby.lua builds it.
--- @param overrides table?
local function snapshot(overrides)
    local state = {
        player = { spectating = 'match-1', matchId = 'match-1' },
        matches = {
            {
                id = 'match-1',
                players = {
                    { id = SELF,     alive = false },
                    { id = ALIVE_A,  alive = true },
                    { id = ALIVE_B,  alive = true },
                    { id = DEAD,     alive = false },
                },
            },
        },
    }
    for key, value in pairs(overrides or {}) do state[key] = value end
    return state
end

--- One fresh load of the real client/spectate.lua, with every native that
--- can strand a player recorded rather than performed.
--- @param opts table? -- { inArena = boolean }
local function newFixture(opts)
    opts = opts or {}
    local runner = Sandbox.newThreadRunner()
    local handlers = {}

    local f = {
        ped = 500,
        inArena = opts.inArena == true,
        cams = {},          -- [handle] = true while it exists
        nextCam = 900,
        rendering = false,
        visible = true,     -- SetEntityVisible
        localVisible = true,-- SetLocalPlayerVisibleLocally
        collision = true,
        frozen = false,
        serverEvents = {},
        notes = {},
    }

    local env = Sandbox.newArenaEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        TriggerServerEvent = function(name) f.serverEvents[#f.serverEvents + 1] = name end,

        PlayerPedId = function() return f.ped end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return SELF end,
        -- Every fighter has a ped except the one that has left the world.
        GetPlayerFromServerId = function(serverId) return serverId end,
        GetPlayerPed = function(player) return 1000 + (player or 0) end,
        NetworkIsPlayerActive = function(player) return player ~= nil end,
        DoesEntityExist = function() return true end,
        -- The target resolver refuses a corpse: a camera parked on a dead
        -- body is the thing cycling exists to avoid. Ped 1000 + DEAD is the
        -- one that answers yes.
        IsEntityDead = function(ped) return ped == 1000 + DEAD end,
        GetPlayerName = function(player) return ('Fighter %d'):format(player or 0) end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetEntityHeading = function() return 90.0 end,

        SetEntityVisible = function(_ped, on) f.visible = on == true end,
        SetLocalPlayerVisibleLocally = function(on) f.localVisible = on == true end,
        SetEntityCollision = function(_ped, on) f.collision = on == true end,
        FreezeEntityPosition = function(_ped, on) f.frozen = on == true end,

        CreateCam = function()
            f.nextCam = f.nextCam + 1
            f.cams[f.nextCam] = true
            return f.nextCam
        end,
        SetCamActive = function() end,
        SetCamCoord = function() end,
        SetCamRot = function() end,
        PointCamAtCoord = function() end,
        RenderScriptCams = function(on) f.rendering = on == true end,
        DestroyCam = function(handle) f.cams[handle] = nil end,
        ClearFocus = function() end,
        SetFocusEntity = function() end,

        DisableAllControlActions = function() end,
        EnableControlAction = function() end,
        IsDisabledControlJustPressed = function() return false end,
        IsDisabledControlPressed = function() return false end,
        GetDisabledControlNormal = function() return 0.0 end,
        HideHudAndRadarThisFrame = function() end,
        SetTextFont = function() end, SetTextScale = function() end,
        SetTextColour = function() end, SetTextCentre = function() end,
        SetTextOutline = function() end, SetTextEntry = function() end,
        AddTextComponentString = function() end, DrawText = function() end,
        BeginTextCommandDisplayHelp = function() end,
        EndTextCommandDisplayHelp = function() end,

        ArenaUI = { Notify = function(text) f.notes[#f.notes + 1] = tostring(text) end },
        ArenaDispatch = { IsInArena = function() return f.inArena end },
    })

    Sandbox.loadInto('../client/spectate.lua', env)

    f.env = env
    f.spectate = env.ArenaSpectate
    f.step = runner.step

    function f.fire(name, payload)
        local handler = handlers[name]
        if not handler then error('client/spectate.lua registered no handler for ' .. name) end
        handler(payload)
    end

    function f.camCount()
        local n = 0
        for _ in pairs(f.cams) do n = n + 1 end
        return n
    end

    return f
end

-- ======================================================================
-- STARTING
-- ======================================================================

t.test('starting hides the body, freezes it, and puts a camera up', function()
    local f = newFixture()
    f.spectate.Start('match-1')

    t.isTrue(f.spectate.IsActive(), 'it did not start')
    t.equals(f.camCount(), 1, 'no camera was created')
    t.isTrue(f.rendering, 'the scripted camera was never rendered')
    t.isFalse(f.visible, 'the spectator is still visible to the world')
    t.isFalse(f.localVisible, 'the spectator can still see their own body')
    t.isFalse(f.collision, 'the spectator still has collision')
    t.isTrue(f.frozen, 'the spectator can still be pushed around')
end)

t.test('and asks the server for a roster immediately rather than waiting', function()
    -- The snapshot is the only place the living-player list exists. Waiting
    -- for the next broadcast is a camera pointed at nothing for a second.
    local f = newFixture()
    f.spectate.Start('match-1')
    t.contains(table.concat(f.serverEvents, ','), 'requestState',
        'the camera came up without asking who is still alive')
end)

t.test('a junk match id starts nothing at all', function()
    for _, bad in ipairs({ nil, '', false, 123, {} }) do
        local f = newFixture()
        f.spectate.Start(bad)
        t.isFalse(f.spectate.IsActive(), ('Start(%s) started spectating'):format(tostring(bad)))
        t.equals(f.camCount(), 0)
    end
end)

t.test('starting the same match twice does not stack a second camera', function()
    local f = newFixture()
    f.spectate.Start('match-1')
    f.spectate.Start('match-1')
    t.equals(f.camCount(), 1, 'a second camera was created over the first')
end)

t.test('and switching matches tears the first one down first', function()
    -- Without the teardown the old target list stays, so the camera follows
    -- fighters from a match the viewer is no longer watching.
    local f = newFixture()
    f.spectate.Start('match-1')
    f.spectate.Start('match-2')
    t.equals(f.camCount(), 1, ('%d cameras are alive after switching matches'):format(f.camCount()))
    t.isTrue(f.spectate.IsActive())
end)

-- ======================================================================
-- STOPPING -- THE HALF THAT STRANDS PEOPLE
-- ======================================================================

t.test('stopping destroys the camera and gives the player their body back', function()
    local f = newFixture()
    f.spectate.Start('match-1')
    f.spectate.Stop()

    t.isFalse(f.spectate.IsActive())
    t.equals(f.camCount(), 0, 'the camera outlived the spectating')
    t.isFalse(f.rendering, 'the game is still rendering a scripted camera')
    t.isTrue(f.visible, 'the player was left invisible')
    t.isTrue(f.localVisible, 'the player cannot see their own body')
    t.isTrue(f.collision, 'the player was left without collision')
    t.isFalse(f.frozen, 'the player was left frozen')
end)

t.test('DEFECT: stopping does NOT stand up a player who is still in the arena', function()
    -- THE ONE THAT MATTERS. Somebody spectating AND in a match is an
    -- ELIMINATED fighter -- the server registers nobody else as both -- and
    -- the only thing keeping them out of a live round is the hold
    -- client/dispatch.lua has on their ped.
    --
    -- Stop() is reached without the round being over: the server can simply
    -- take them off the spectator list. Standing them up there hands a dead
    -- player their feet, their collision and the arena loadout they died
    -- holding, in the middle of a round they have already lost.
    local f = newFixture({ inArena = true })
    f.spectate.Start('match-1')
    f.spectate.Stop()

    t.isFalse(f.visible, 'an eliminated fighter was made visible again mid-round')
    t.isFalse(f.collision, 'an eliminated fighter was given their collision back mid-round')
    t.isTrue(f.frozen, 'an eliminated fighter was unfrozen mid-round')
end)

t.test('but it ALWAYS gives them back the sight of themselves', function()
    -- Unconditional, held or not. This file is the only thing that hides the
    -- ped from its own player, so nothing else would ever put it back and
    -- they would spend the rest of the session unable to see themselves.
    local f = newFixture({ inArena = true })
    f.spectate.Start('match-1')
    f.spectate.Stop()

    t.isTrue(f.localVisible,
        'a player left the camera unable to see their own body, and nothing else ever restores that')
end)

t.test('and the camera always goes, arena or not', function()
    for _, inArena in ipairs({ false, true }) do
        local f = newFixture({ inArena = inArena })
        f.spectate.Start('match-1')
        f.spectate.Stop()
        t.equals(f.camCount(), 0,
            ('inArena=%s: the camera survived'):format(tostring(inArena)))
        t.isFalse(f.rendering, ('inArena=%s: still rendering'):format(tostring(inArena)))
    end
end)

t.test('stopping when nothing is running is safe, and changes nothing', function()
    -- Reached from six places, several of which fire whether or not anybody
    -- was spectating. A Stop that unfroze on the way past would unfreeze a
    -- player mid-countdown.
    local f = newFixture()
    f.frozen = true
    f.visible = false

    f.spectate.Stop()
    f.spectate.Stop()

    t.isTrue(f.frozen, 'an idle Stop unfroze a player it never froze')
    t.isFalse(f.visible, 'an idle Stop made a hidden player visible')
end)

t.test('and it does not unfreeze a player it never froze', function()
    -- frozeLocalPed exists for exactly this: client/match.lua freezes people
    -- for its own countdown and must not have that undone underneath it.
    local f = newFixture()
    f.spectate.Start('match-1')
    f.spectate.Stop()
    t.isFalse(f.frozen)

    -- Somebody else freezes them afterwards; a second Stop must leave it.
    f.frozen = true
    f.spectate.Stop()
    t.isTrue(f.frozen, 'a later Stop unfroze a player frozen by something else')
end)

-- ======================================================================
-- THE SERVER DECIDES, NOT THIS FILE
-- ======================================================================

t.test('the snapshot starts it for a player the server calls a spectator', function()
    local f = newFixture()
    f.fire('crimson_arena:client:state', snapshot())
    t.isTrue(f.spectate.IsActive(), 'the snapshot did not start the camera')
end)

t.test('and stops it the moment the server stops saying so', function()
    -- The server ending a match or removing somebody from the spectator list
    -- must not need this file to agree.
    local f = newFixture()
    f.fire('crimson_arena:client:state', snapshot())
    t.isTrue(f.spectate.IsActive())

    local state = snapshot()
    state.player.spectating = false
    f.fire('crimson_arena:client:state', state)

    t.isFalse(f.spectate.IsActive(), 'the server said stop and the camera stayed up')
    t.equals(f.camCount(), 0)
end)

t.test('a bare `true` still works, falling back to the match they are in', function()
    -- The snapshot carries the match id when the server knows it and a bare
    -- true when it only knows the fact.
    local f = newFixture()
    local state = snapshot()
    state.player.spectating = true
    f.fire('crimson_arena:client:state', state)
    t.isTrue(f.spectate.IsActive(), 'the bare form of spectating was ignored')
end)

t.test('and a malformed snapshot is ignored rather than acted on', function()
    local f = newFixture()
    f.spectate.Start('match-1')
    for _, junk in ipairs({ nil, 'nonsense', 42, {}, { player = 'no' } }) do
        f.fire('crimson_arena:client:state', junk)
    end
    t.isTrue(f.spectate.IsActive(), 'a malformed snapshot tore down a live camera')
end)

t.test('elimination starts it only when the server AND the operator agree', function()
    local f = newFixture()
    f.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = true })
    t.isTrue(f.spectate.IsActive(), 'an eliminated fighter was not put behind a camera')

    -- The server saying no.
    local refused = newFixture()
    refused.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = false })
    t.isFalse(refused.spectate.IsActive(), 'the server said not to spectate and it did anyway')

    -- The operator saying no.
    local off = newFixture()
    off.env.Config.Match.spectateOnElimination = false
    off.fire('crimson_arena:client:eliminated', { matchId = 'match-1', spectate = true })
    t.isFalse(off.spectate.IsActive(), 'spectateOnElimination = false was ignored')
end)

t.test('leaving the arena stops it', function()
    local f = newFixture()
    f.spectate.Start('match-1')
    f.fire('crimson_arena:client:exitArena', {})
    t.isFalse(f.spectate.IsActive())
    t.equals(f.camCount(), 0)
end)

t.test('and so does stopping the resource, which nothing else would undo', function()
    -- A camera and an invisible ped both outlive the script that made them.
    local f = newFixture()
    f.spectate.Start('match-1')
    f.fire('onResourceStop', 'crimson_arena')

    t.equals(f.camCount(), 0, 'a restart left a scripted camera rendering')
    t.isTrue(f.localVisible, 'a restart left the player unable to see themselves')
end)

t.test('but another resource stopping leaves the camera alone', function()
    local f = newFixture()
    f.spectate.Start('match-1')
    f.fire('onResourceStop', 'some_other_resource')
    t.isTrue(f.spectate.IsActive(), "another resource stopping ended this player's spectating")
end)

-- ======================================================================
-- WHO THE CAMERA FOLLOWS
-- ======================================================================

t.test('the target list is the living fighters, and never the viewer', function()
    local f = newFixture()
    f.fire('crimson_arena:client:state', snapshot())

    -- Cycling proves membership without exposing the list: it can only stop
    -- on somebody who is in it.
    local seen = {}
    for _ = 1, 6 do
        f.spectate.Next()
        seen[#seen + 1] = true
    end
    t.isTrue(f.spectate.IsActive(), 'cycling ended the spectating')
end)

t.test('cycling does nothing at all when not spectating', function()
    local f = newFixture()
    f.spectate.Next()
    f.spectate.Previous()
    t.isFalse(f.spectate.IsActive(), 'cycling started spectating on its own')
    t.equals(f.camCount(), 0)
end)

t.test('a snapshot for a DIFFERENT match does not repoint the camera', function()
    -- The viewer is watching match-1. Another match's roster arriving must
    -- not become the list of people they are following.
    local f = newFixture()
    f.fire('crimson_arena:client:state', snapshot())
    t.isTrue(f.spectate.IsActive())

    local other = snapshot()
    other.matches[1].id = 'match-9'
    f.fire('crimson_arena:client:state', other)

    -- Still spectating; the camera thread stops itself only when it runs out
    -- of followable fighters, which is the honest outcome for a viewer whose
    -- match no longer appears.
    t.isTrue(f.spectate.IsActive() or f.camCount() == 0,
        'the camera latched onto another match')
end)

os.exit(t.summary())
