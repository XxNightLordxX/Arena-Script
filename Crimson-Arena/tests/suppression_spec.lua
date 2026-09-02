--[[
    crimson_arena/tests/suppression_spec.lua

    WHAT THE ARENA TURNS OFF, AND PUTTING ALL OF IT BACK.

    client/dispatch.lua is the client half of "the police and the ambulance
    do not come to the arena". Entering a match tells GTA's own police to
    ignore this player, stops dispatch sending cops after them, stashes and
    zeroes their wanted level, and calls whatever ignore exports an
    operator named on their dispatch script. Leaving undoes exactly those
    and nothing else.

    THE FAILURE THIS FILE IS ABOUT IS THE ONE NOBODY REPORTS. A suppression
    that does not come back off is invisible: the player walks out of the
    arena permanently ignored by the police, with their wanted level pinned
    at zero, and everything looks fine. DEPLOYMENT.md calls the check for
    it "the test people skip", and it was the check no spec made either --
    a mutation sample found thirty-two survivors in this file, and the
    largest cluster is the three `restore.touched*` flags that decide
    whether anything is undone at all.

    The second cluster is the HOLD. A player who dies mid-round is
    resurrected immediately, so the medical script is told they are alive
    and files nothing -- but they are held invisible, frozen, without
    collision and invincible until the server says whether that was a
    respawn or an elimination. Every one of those four is a boolean, and
    getting any of them wrong hands a dead player back into a live round.

    Every assertion below was checked by breaking the code it covers and
    watching it fail.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local PLAYER = 0

--- One fresh load of the REAL client/dispatch.lua with every native it
--- touches recorded WITH ITS ARGUMENTS.
--- @param opts table? -- { mutate, running, exportRaises }
--- @return table fixture
local function newDispatch(opts)
    opts = opts or {}
    local running = opts.running or {}

    local f = {
        ped = 100,
        coords = { 10.0, 20.0, 30.0 },
        heading = 90.0,
        wantedLevel = 0,
        -- Every suppression native, last value wins, plus a call count so
        -- "never touched" is distinguishable from "set back to the same".
        police = {}, dispatchCops = {}, wanted = {}, wantedNow = {},
        exportCalls = {},
        entity = {},
        resurrects = {},
        commands = {},
        console = {},
    }

    local handlers = {}
    local function record(list, value)
        list[#list + 1] = value
        return value
    end

    local env = Sandbox.newArenaEnv({
        PlayerId = function() return PLAYER end,
        PlayerPedId = function() return f.ped end,
        GetEntityCoords = function() return f.coords end,
        GetEntityHeading = function() return f.heading end,
        GetEntityMaxHealth = function() return 200 end,
        SetEntityHealth = function(_ped, hp) f.entity.health = hp end,

        GetPlayerWantedLevel = function() return f.wantedLevel end,
        SetPoliceIgnorePlayer = function(_p, on) record(f.police, on) end,
        SetDispatchCopsForPlayer = function(_p, on) record(f.dispatchCops, on) end,
        SetPlayerWantedLevel = function(_p, level) record(f.wanted, level) end,
        SetPlayerWantedLevelNow = function(_p, flag) record(f.wantedNow, flag) end,

        NetworkResurrectLocalPlayer = function(x, y, z, heading, keepGear, resetHealth)
            f.resurrects[#f.resurrects + 1] = {
                x = x, y = y, z = z, heading = heading,
                keepGear = keepGear, resetHealth = resetHealth,
            }
        end,
        SetEntityInvincible = function(_ped, on) f.entity.invincible = on end,
        IsEntityDead = function() return f.dead == true end,
        IsPedInWrithe = function() return f.writhing == true end,
        IsPedRagdoll = function() return f.ragdolling == true end,
        GetEntityHealth = function() return f.health or 200 end,
        ClearPedTasksImmediately = function() f.entity.tasksCleared = true end,
        SetPedCanRagdoll = function(_ped, on) f.entity.canRagdoll = on end,
        ClearPedBloodDamage = function() end,
        ClearPedLastWeaponDamage = function() end,
        ResetPedVisibleDamage = function() end,
        AnimpostfxStopAll = function() f.entity.effectsStopped = true end,
        SetPedArmour = function() end,
        ExecuteCommand = function(line) f.commands[#f.commands + 1] = line end,
        SetEntityVisible = function(_ped, on, alsoNetwork)
            f.entity.visible = on
            f.entity.visibleNetwork = alsoNetwork
        end,
        SetEntityCollision = function(_ped, on, keepPhysics)
            f.entity.collision = on
            f.entity.keepPhysics = keepPhysics
        end,
        FreezeEntityPosition = function(_ped, on) f.entity.frozen = on end,

        GetResourceState = function(name) return running[name] and 'started' or 'missing' end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        RegisterNetEvent = function(name, fn) handlers[name] = fn end,
        TriggerServerEvent = function() end,
        CreateThread = function() end,
        Wait = function() end,
        print = function(line) f.console[#f.console + 1] = tostring(line) end,
        exports = setmetatable({}, {
            __call = function() end,
            __index = function(_t, resource)
                return setmetatable({}, {
                    __index = function(_t2, export)
                        return function(_self, enabled)
                            if opts.exportRaises then error('that export does not exist') end
                            f.exportCalls[#f.exportCalls + 1] =
                                { resource = resource, export = export, enabled = enabled }
                        end
                    end,
                })
            end,
        }),
    })

    if opts.mutate then opts.mutate(env.Config) end
    Sandbox.loadInto('../client/dispatch.lua', env)

    f.env = env
    f.D = env.ArenaDispatch
    f.fire = function(name, ...)
        local handler = handlers[name]
        if not handler then return false end
        handler(...)
        return true
    end
    f.log = function() return table.concat(f.console, '\n') end
    return f
end

--- The one export list every teardown test below shares, named once so a
--- change to it cannot make two of those tests disagree about what "the
--- operator's mute" is.
local function withIgnoreExport(config)
    config.Dispatch.custom.disableExports = {
        { resource = 'ps_dispatch', export = 'setIgnore' },
    }
end

--- A fixture with that export wired and its resource running.
local function newMuted(extra)
    local opts = { running = { ps_dispatch = true }, mutate = withIgnoreExport }
    for key, value in pairs(extra or {}) do opts[key] = value end
    return newDispatch(opts)
end

-- ========================================================================
-- NOTHING IS TAKEN, SO THERE IS NOTHING TO PUT BACK
--
-- This file used to open with a dozen tests about GTA's own wanted system:
-- a `vanillaPolice` block that shipped OFF, three sub-switches under it, and
-- a stash-and-restore for the player's stars. All of it is gone. The server
-- this resource runs on has a custom dispatch script, which disabled the
-- vanilla wanted system years ago, and a block that has never executed is
-- not coverage.
--
-- What replaced those tests is a stronger claim and a shorter one: ENTERING
-- OR LEAVING A MATCH TOUCHES NO GAME SETTING AT ALL. It is asserted as a
-- count of natives rather than a list of names, so a native added later
-- fails here whatever it is called.
-- ========================================================================

t.test('entering a match touches no game setting', function()
    local f = newDispatch()

    f.D.Enter('match-1')

    t.equals(#f.police, 0, 'entering reached for the vanilla police natives')
    t.equals(#f.dispatchCops, 0, 'entering told the game to stop dispatching cops')
    t.equals(#f.wanted, 0, 'entering zeroed the player\'s wanted level')
end)

t.test('and leaving one touches none either', function()
    -- The half that matters more. A native called only on the way OUT would
    -- leak a setting into the rest of that player's session with nothing
    -- captured on the way in to undo it.
    local f = newDispatch()

    f.D.Enter('match-1')
    f.D.Exit()

    t.equals(#f.police, 0, 'leaving handed back a police setting the arena never took')
    t.equals(#f.dispatchCops, 0)
    t.equals(#f.wanted, 0, 'leaving set a wanted level the arena never captured')
end)

t.test('even for an operator who switched the removed block back on', function()
    -- THE REGRESSION GUARD. These keys do not exist any more, so the only
    -- way this fixture reaches a native is if the code that reads them came
    -- back. Naming them here is what makes that visible.
    local f = newDispatch({ mutate = function(config)
        config.Dispatch.vanillaPolice = {
            enabled = true, ignorePlayer = true,
            stopDispatch = true, stashWantedLevel = true,
        }
    end })
    f.wantedLevel = 3

    f.D.Enter('match-1')
    f.D.Exit()

    t.equals(#f.police + #f.dispatchCops + #f.wanted, 0,
        'a removed config block is being read again -- the vanilla police branch is back')
end)

-- ========================================================================
-- AND PUTTING THE ONE THING THAT IS TAKEN BACK
--
-- The operator's own mute export is now the whole of what Enter/Exit do, so
-- the symmetry tests that used to ride on the wanted level ride on that.
-- ========================================================================

t.test('an Exit with no Enter behind it does nothing at all', function()
    -- Safe at any time, which is what lets client/match.lua call it on
    -- every exit path without working out whether it needs to.
    local f = newMuted()

    f.D.Exit()

    t.equals(#f.exportCalls, 0, 'an exit with nothing to undo called the mute export anyway')
end)

t.test('and a second Exit does not undo the restore twice', function()
    local f = newMuted()
    f.D.Enter('match-1')
    f.D.Exit()
    local calls = #f.exportCalls

    f.D.Exit()

    t.equals(#f.exportCalls, calls, 'a second exit called the operator\'s export again')
end)

t.test('a second Enter does not mute twice', function()
    -- The guard in Enter. Two mutes and one unmute leaves the operator's
    -- dispatch script silenced for the rest of that player's session, and
    -- nothing on their screen says so.
    local f = newMuted()
    f.D.Enter('match-1')

    f.D.Enter('match-2')

    t.equals(#f.exportCalls, 1, 'a re-entry muted a second time, so one exit cannot undo it')
end)

t.test('a restart mid-match puts it back', function()
    -- The one teardown that has to happen when nothing else gets the
    -- chance to run. Without it a `restart crimson_arena` during a round
    -- leaves every fighter's dispatch script muted for good.
    local f = newMuted()
    f.D.Enter('match-1')

    t.isTrue(f.fire('onResourceStop', 'crimson_arena'))

    t.equals(#f.exportCalls, 2, 'a restart left the operator\'s dispatch script muted forever')
    t.equals(f.exportCalls[2].enabled, false)
end)

t.test('but SOME OTHER resource stopping leaves the mute alone', function()
    -- onResourceStop fires for every resource. Undoing on somebody else's
    -- stop un-mutes a dispatch script in the middle of a round.
    local f = newMuted()
    f.D.Enter('match-1')

    t.isTrue(f.fire('onResourceStop', 'some_other_script'))

    t.equals(#f.exportCalls, 1, 'an unrelated resource stopping un-muted a live fighter\'s dispatch')
end)

-- ========================================================================
-- THE OPERATOR'S OWN IGNORE EXPORTS
-- ========================================================================

t.test('an ignore export is called ON at entry and OFF at exit', function()
    local f = newDispatch({
        running = { ps_dispatch = true },
        mutate = function(config)
            config.Dispatch.custom.disableExports = {
                { resource = 'ps_dispatch', export = 'setIgnore' },
            }
        end,
    })

    f.D.Enter('match-1')
    t.equals(#f.exportCalls, 1, 'the operator\'s ignore export was never called')
    t.equals(f.exportCalls[1].resource, 'ps_dispatch')
    t.equals(f.exportCalls[1].export, 'setIgnore')
    t.equals(f.exportCalls[1].enabled, true, 'the export was called to switch suppression OFF at entry')

    f.D.Exit()
    t.equals(#f.exportCalls, 2, 'the ignore export was never switched back off')
    t.equals(f.exportCalls[2].enabled, false, 'the player was left ignored by their dispatch script')
end)

t.test('an export on a resource this box does not run is not called', function()
    local f = newDispatch({
        running = {},
        mutate = function(config)
            config.Dispatch.custom.disableExports = {
                { resource = 'ps_dispatch', export = 'setIgnore' },
            }
        end,
    })

    f.D.Enter('match-1')

    t.equals(#f.exportCalls, 0, 'an export was called on a resource that is not running')
end)

t.test('a malformed export entry is skipped and the rest still run', function()
    -- Hand-written config. A typo in one entry must not cost the others.
    local f = newDispatch({
        running = { ps_dispatch = true, other_dispatch = true },
        mutate = function(config)
            config.Dispatch.custom.disableExports = {
                'not a table',
                { resource = 'ps_dispatch' },                       -- no export
                { export = 'setIgnore' },                           -- no resource
                { resource = 42, export = 'setIgnore' },
                { resource = 'other_dispatch', export = 'setIgnore' },
            }
        end,
    })

    f.D.Enter('match-1')

    t.equals(#f.exportCalls, 1, 'a malformed entry was called, or took a valid one down with it')
    t.equals(f.exportCalls[1].resource, 'other_dispatch')
end)

t.test('an export that RAISES does not stop the match starting', function()
    local f = newDispatch({
        running = { ps_dispatch = true },
        exportRaises = true,
        mutate = function(config)
            config.Dispatch.custom.disableExports = {
                { resource = 'ps_dispatch', export = 'setIgnore' },
            }
        end,
    })

    f.D.Enter('match-1')

    t.contains(f.log(), 'disableExports', 'a broken export failed silently')
    t.contains(f.log(), 'ps_dispatch:setIgnore', 'the console does not name which export is broken')
end)

t.test('and an empty list reaches for nothing', function()
    local f = newDispatch({ running = { ps_dispatch = true } })

    f.D.Enter('match-1')

    t.equals(#f.exportCalls, 0, 'a shipped config with no exports named called something anyway')
end)

-- ========================================================================
-- THE HOLD ON A PLAYER WHO JUST DIED
-- ========================================================================

--- A player mid-match, dead, with the dead state cleared.
local function heldAfterDeath(mutate)
    local f = newDispatch({ mutate = mutate })
    f.D.Enter('match-1')
    f.handled = f.D.ClearDeadState(f.ped)
    return f
end

t.test('a death is resurrected immediately, in place', function()
    -- The whole ambulance answer: the medical script's handler asks
    -- IsEntityDead in the frame the ped died, and this makes the answer
    -- NO. Resurrecting somewhere else would teleport the fighter.
    local f = heldAfterDeath()

    t.isTrue(f.handled, 'the death was not cleared at all')
    t.equals(#f.resurrects, 1, 'the player was never resurrected')
    local at = f.resurrects[1]
    t.equals(at.x, 10.0, 'the player was resurrected somewhere other than where they fell')
    t.equals(at.y, 20.0)
    t.equals(at.z, 30.0)
    t.equals(at.heading, 90.0, 'the player was spun round on resurrection')
end)

t.test('and they are HELD, not handed back into the round', function()
    -- Alive, but not back in the fight: the server has not said yet
    -- whether this was a respawn or an elimination, and a player who could
    -- shoot during that gap would be shooting from beyond the grave.
    local f = heldAfterDeath()

    t.equals(f.entity.invincible, true, 'a player mid-death could be killed again')
    t.equals(f.entity.visible, false, 'a dead player was visible during the hold')
    t.equals(f.entity.collision, false, 'a dead player could be walked into during the hold')
    t.equals(f.entity.frozen, true, 'a dead player could walk around during the hold')
    t.equals(f.entity.health, 200, 'the player was resurrected on the health they died with')
end)

t.test('releasing the hold gives all four back', function()
    -- Called from leaveArena and the respawn handler, both of which put
    -- the ped somewhere themselves -- so this restores properties and
    -- deliberately does not touch position.
    local f = heldAfterDeath()

    f.D.ReleaseDeadState(f.ped)

    t.equals(f.entity.invincible, false, 'the player was left invincible')
    t.equals(f.entity.visible, true, 'the player was left invisible')
    t.equals(f.entity.collision, true, 'the player was left walking through walls')
    t.equals(f.entity.frozen, false, 'the player was left frozen where they died')
    t.equals(#f.resurrects, 1, 'releasing the hold resurrected them a second time')
end)

t.test('a player who is not in a match is not resurrected at all', function()
    -- The guard is `restore`, which only exists between Enter and Exit.
    -- Without it this file would resurrect anybody who died anywhere on
    -- the map.
    local f = newDispatch()

    t.isFalse(f.D.ClearDeadState(f.ped), 'a death outside the arena was reported as handled')
    t.equals(#f.resurrects, 0, 'somebody who died in town was resurrected by the arena')
end)

t.test('an operator who turned the immediate clear off gets none of it', function()
    -- Returns false so the caller can tell "suppressed" from "left dead on
    -- purpose".
    local f = heldAfterDeath(function(config)
        config.Dispatch.clearDeadStateImmediately = false
    end)

    t.isFalse(f.handled, 'the clear ran on a server that switched it off')
    t.equals(#f.resurrects, 0)
end)

-- ========================================================================
-- THE ARGUMENTS PAST THE FIRST
--
-- Every native here takes a flag after the on/off. They are the arguments
-- a stub drops, and each of them decides HOW the thing is done.
-- ========================================================================

t.test('the resurrect keeps the player\'s gear and does not reset their health', function()
    -- A mid-round death resurrects in place. Drop the gear flag and the
    -- fighter stands back up empty-handed, holding a loadout they paid an
    -- entry fee for.
    local f = heldAfterDeath()

    local at = f.resurrects[1]
    t.equals(at.keepGear, true, 'the fighter lost their loadout to the resurrect')
    t.equals(at.resetHealth, false, 'the resurrect reset health itself instead of leaving it to the caller')
end)

t.test('the hold is local to this client, and keeps no physics', function()
    local f = heldAfterDeath()

    t.equals(f.entity.visibleNetwork, false, 'the hold was replicated to every other player')
    t.equals(f.entity.keepPhysics, false)
end)

-- ========================================================================
-- THE REVIVE, AND THE HOLD IT MUST NOT BREAK
-- ========================================================================

-- ========================================================================
-- THE COMMAND LINE THE SERVER SENDS
-- ========================================================================

os.exit(t.summary())
