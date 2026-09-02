--[[
    crimson_arena/client/dispatch.lua

    Keeping the emergency services out of the arena.

    Three separate problems wear the same coat here, and it is worth being
    clear about which of them this file actually solves:

    1. THE GAME'S OWN POLICE. GTA dispatches NPC cops at gunfire on its own,
       with no script involved. This file can switch that off for the length
       of a match and put it back afterwards -- but it ships OFF, under
       Config.Dispatch.vanillaPolice. A server running a custom dispatch
       script has almost certainly disabled the vanilla wanted system
       already, and some custom systems drive their own logic off the native
       wanted level, where pinning it to zero would fight them for it.

    2. A DEAD PLAYER BEING SPOTTED BY A MEDICAL SCRIPT. Almost every one of
       them finds casualties by polling "is this player dead" a couple of
       times a second. This file puts an arena death back on its feet inside
       the same frame it happened, so that poll never catches one. Solved in
       practice, and the limit is stated below rather than glossed over.

    3. AN ALERT SENT BY SOMEBODY ELSE'S RESOURCE. ps-dispatch deciding to
       broadcast a shots-fired call, or qbx_ambulancejob raising a distress
       signal, is that resource's decision inside its own event handlers.
       No FiveM resource can reach into another one and cancel that. NOT
       solved here, and it cannot be -- what this file does instead is
       publish, in two forms anyone can read, the fact that a player is
       mid-match, so one line in that resource can decline to send.

    WHAT IS PUBLISHED, and it is deliberately the same fact twice because
    different scripts want it different ways:
      * a replicated state bag on the player, keyed by
        Config.Dispatch.stateBagKey, holding { active = true, matchId = ... }
      * an export, `exports.crimson_arena:IsInArena()`

    THE STATE BAG IS WRITTEN BY THE SERVER, NOT HERE -- see server/dispatch.lua.
    That is a security decision, not a structural one. A replicated bag set
    from the client can be set by ANY client, so a player who never went near
    the arena could pin the flag on themselves and have your dispatch script
    politely ignore them robbing a bank. The server sets it because the
    server is the only party that knows whether someone is really in a match.
    This file reads its own local record for its own exports and never writes
    the bag at all.

    EVERYTHING HERE IS PER-MATCH AND REVERSIBLE. A player who walks into the
    arena with two wanted stars walks back out with two wanted stars. This
    file is not allowed to leak a single setting into the rest of someone's
    session, which is why every Enter() has a matching Exit(), why Exit() is
    safe to call when nothing is active, and why a setting this file cannot
    read back is one it does not set at all -- see ENTER / EXIT below.
]]

ArenaDispatch = {}

--- Nil when not in a match. Holds what has to be undone on the way out --
--- never a copy of what is currently set, always a record of what was set
--- BEFORE we touched it.
local restore = nil

-- ======================================================================
-- THE PUBLISHED FACT
-- ======================================================================

--- Whether this player is currently in an arena match.
---
--- Reads the local record rather than the state bag, because a state bag
--- read immediately after a write can still return the old value -- and a
--- dispatch script asking "should I suppress this shot" is asking at
--- exactly that moment.
--- @return boolean
function ArenaDispatch.IsInArena()
    return restore ~= nil
end

--- @return string|nil
function ArenaDispatch.MatchId()
    return restore and restore.matchId or nil
end

exports('IsInArena', ArenaDispatch.IsInArena)
exports('GetArenaMatchId', ArenaDispatch.MatchId)

-- ======================================================================
-- THIRD-PARTY MUTE EXPORTS
-- ======================================================================

--- Calls each Config.Dispatch.disableExports entry with `enabled`.
---
--- Wrapped in pcall per entry, and one warning per failure rather than per
--- call: an operator who names an export that does not exist should find
--- out, but a match must not fail to start over it, and a per-frame warning
--- would be worse than the original problem.
--- @param enabled boolean
local function callDisableExports(enabled)
    local custom = Config.Dispatch and Config.Dispatch.custom or nil
    local list = custom and custom.disableExports
    if type(list) ~= 'table' then return end

    for _, entry in ipairs(list) do
        if type(entry) == 'table' and type(entry.resource) == 'string' and type(entry.export) == 'string' then
            if GetResourceState(entry.resource) == 'started' then
                local ok, err = pcall(function()
                    exports[entry.resource][entry.export](nil, enabled)
                end)
                if not ok then
                    print(('[crimson_arena] Config.Dispatch.custom.disableExports: %s:%s failed (%s). Check that export name against that resource\'s own documentation.')
                        :format(entry.resource, entry.export, tostring(err)))
                end
            else
                print(('[crimson_arena] Config.Dispatch.custom.disableExports names "%s", which is not started. Skipping it.')
                    :format(entry.resource))
            end
        end
    end
end

-- ======================================================================
-- ENTER / EXIT
--
-- THREE NATIVES ARE DELIBERATELY NOT CALLED HERE, and naming them is worth
-- more than the suppression they would have bought: SetMaxWantedLevel,
-- SetCreateRandomCops and SetPlayerHealthRechargeMultiplier can all be set
-- and none of them can be read -- CitizenFX ships no getter for any of the
-- three. A match that changed one could only put it back by assuming the
-- stock value, and an assumption is not a restore: on a server that caps
-- wanted levels, keeps NPC patrols off its streets, or turns passive health
-- regeneration off through its medical script, handing back 5 / true / 1.0
-- on the way out would silently undo that operator's setting for the rest of
-- that player's session, off the back of one arena round. So the ceiling, the
-- ambient patrols and the recharge multiplier are left exactly as they were
-- found.
--
-- Config.Dispatch.disableHealthRecharge was removed rather than left sitting
-- in the config doing nothing. Putting it back honestly needs a second key
-- carrying the value to restore TO, since the multiplier cannot be read; if
-- that is ever wanted, add both keys together or not at all.
--
-- The two suppressions that remain -- SetPoliceIgnorePlayer and
-- SetDispatchCopsForPlayer -- have no getter either, but they are per-player
-- rather than world-wide, so putting them back reaches no further than the
-- player who was just in the match. The wanted level is the one value here
-- that CAN be read, so it is the one that is captured on the way in and
-- handed back exactly as captured.
-- ======================================================================

--- Silences everything this resource is able to silence, and records what
--- has to be put back.
---
--- Safe to call twice: a second call while already active is ignored rather
--- than overwriting the restore record with the values WE set, which would
--- make the player permanently unwanted and permanently ignored by police.
--- That is the failure this guard exists for.
--- @param matchId string
function ArenaDispatch.Enter(matchId)
    if restore then return end

    local config = Config.Dispatch or {}
    local player = PlayerId()

    restore = {
        matchId = matchId,
        wantedLevel = 0,
        touchedPolice = false,
        touchedDispatch = false,
        touchedWanted = false,
    }

    -- OFF unless an operator asks for it. A server running a custom dispatch
    -- script has almost certainly disabled the vanilla wanted system already,
    -- and plenty of custom systems drive their own logic off the native
    -- wanted level -- zeroing it mid-match would fight them for it.
    --
    -- `vanillaPolice.enabled` and the three sub-switches below it are the
    -- WHOLE gate, deliberately. This used to be AND-ed with a top-level
    -- Config.Dispatch.suppressPoliceShotsFired, which read as the headline
    -- police switch in the config and could only ever be consulted from in
    -- here -- inside a block that ships disabled. An operator toggling it on
    -- a stock config changed nothing, which made it the worst kind of key:
    -- the first one reached for when the police still turn up, and the one
    -- that cannot be the reason. It is gone from config.lua rather than
    -- silently kept, so this block's scope is the block you can see.
    local vanilla = config.vanillaPolice or {}
    if vanilla.enabled == true then
        if vanilla.ignorePlayer ~= false then
            restore.touchedPolice = true
            SetPoliceIgnorePlayer(player, true)
        end
        if vanilla.stopDispatch ~= false then
            restore.touchedDispatch = true
            SetDispatchCopsForPlayer(player, false)
        end
        if vanilla.stashWantedLevel ~= false then
            restore.touchedWanted = true
            restore.wantedLevel = GetPlayerWantedLevel(player)
            SetPlayerWantedLevel(player, 0, false)
            SetPlayerWantedLevelNow(player, false)
        end
    end

    callDisableExports(true)
end

--- Undoes Enter(), exactly. Safe to call when nothing is active, which is
--- what lets client/match.lua call it on every exit path -- normal finish,
--- disconnect, resource stop -- without first working out whether it needs
--- to.
function ArenaDispatch.Exit()
    if not restore then return end

    local player = PlayerId()
    local previous = restore

    -- Cleared before the calls below, so a re-entry racing this exit sees
    -- an inactive state rather than being refused by the guard in Enter.
    restore = nil

    -- Each undone only if it was done. Restoring a native this resource never
    -- touched would stamp on whatever the server's own scripts had set.
    if previous.touchedPolice then
        SetPoliceIgnorePlayer(player, false)
    end

    if previous.touchedDispatch then
        SetDispatchCopsForPlayer(player, true)
    end

    if previous.touchedWanted then
        -- Set to the captured number rather than only when that number is
        -- above zero: walking into an arena is not an amnesty, and walking
        -- out of one is not a conviction either -- stars earned inside the
        -- round belong to the round.
        SetPlayerWantedLevel(player, previous.wantedLevel, false)
        SetPlayerWantedLevelNow(player, false)
    end

    callDisableExports(false)
end

-- ======================================================================
-- THE DEAD STATE
-- ======================================================================

--- Puts an arena casualty back on their feet in the same instant they went
--- down, held frozen, invisible and untouchable until the server says what
--- happens next.
---
--- WHY: a medical script finds its patients by polling "is this player
--- dead", typically twice a second. A body that is never dead across a
--- poll boundary is never found, and no ambulance is ever paged. The player
--- sees no difference -- they are held in place either way, waiting on the
--- server's respawn or elimination message.
---
--- THE LIMIT, stated plainly: a resource that hooks the death EVENT rather
--- than polling the death STATE still fires, because the player really did
--- die. Nothing inside one resource can prevent that. Config.Dispatch's
--- state bag is the answer for those, not this function.
---
--- Returns false when it did nothing, so the caller can tell "suppressed"
--- from "left dead on purpose".
--- @param ped integer
--- @return boolean handled
function ArenaDispatch.ClearDeadState(ped)
    local config = Config.Dispatch or {}
    if config.suppressAmbulanceDown == false then return false end
    if config.clearDeadStateImmediately == false then return false end
    if not restore then return false end

    local x, y, z = table.unpack(GetEntityCoords(ped))
    local heading = GetEntityHeading(ped)

    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

    -- Alive, but not back in the fight: the server has not said yet whether
    -- this is a respawn or an elimination, and a player who could shoot
    -- during that gap would be shooting from beyond the grave.
    local resurrected = PlayerPedId()
    SetEntityInvincible(resurrected, true)
    SetEntityVisible(resurrected, false, false)
    SetEntityCollision(resurrected, false, false)
    FreezeEntityPosition(resurrected, true)
    SetEntityHealth(resurrected, GetEntityMaxHealth(resurrected))

    return true
end

--- Undoes ClearDeadState's holding pattern. client/match.lua calls it from
--- exactly two places -- leaveArena and the respawn handler -- and both put
--- the ped somewhere themselves, so this restores its properties and
--- deliberately does not touch its position.
---
--- NOT the elimination handler, which this used to claim. That one keeps the
--- hold on purpose and says so where it decides: releasing there stood an
--- eliminated player back up, armed, in a live round the moment the
--- spectator camera stopped.
--- @param ped integer
function ArenaDispatch.ReleaseDeadState(ped)
    SetEntityInvincible(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    FreezeEntityPosition(ped, false)
end

-- A restart mid-match must not leave a player permanently ignored by the
-- police with their wanted level pinned at zero. This is the one teardown
-- that has to happen even when nothing else gets the chance to run.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ArenaDispatch.Exit()
end)


--- The arena's OWN revive: everything a revive command would do, done here.
---
--- WHY THIS EXISTS. Every route to somebody else's revive was refused. The
--- command answered "Access denied" because a resource may not run an admin
--- command; granting the permission answered "Access denied" too, because a
--- resource may not grant itself permissions either -- which is correct, and
--- is the whole reason that door is shut.
---
--- So the arena stops knocking on it. A revive is not a privileged act when
--- the thing being revived is a player this resource put in an arena and is
--- now taking out again: it is standing up a body we knocked down.
---
--- WHAT IT DOES NOT DO, and cannot: it does not reach inside a medical
--- script's own bookkeeping. If yours records deaths in metadata of its own,
--- it still holds that record, and Config.Dispatch.revive's events and
--- exports are how to reach it -- with a name from that script's
--- documentation rather than a guess. What this guarantees is the half the
--- arena owns: the player is alive, whole, unfrozen, visible and able to
--- move, wherever they are standing.
