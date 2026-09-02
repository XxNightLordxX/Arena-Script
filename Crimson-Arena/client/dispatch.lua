--[[
    crimson_arena/client/dispatch.lua

    Keeping the emergency services out of the arena.

    Two separate problems wear the same coat here, and it is worth being
    clear about which of them this file actually solves:

    1. A DEAD PLAYER BEING SPOTTED BY A MEDICAL SCRIPT. Almost every one of
       them finds casualties by polling "is this player dead" a couple of
       times a second. This file puts an arena death back on its feet inside
       the same frame it happened, so that poll never catches one. Solved in
       practice, and the limit is stated below rather than glossed over.

    2. AN ALERT SENT BY SOMEBODY ELSE'S RESOURCE. sc-dispatch deciding to
       broadcast a shots-fired call, or sc-ambulance raising a distress
       signal, is that resource's decision inside its own event handlers.
       No FiveM resource can reach into another one and cancel that. NOT
       solved here, and it cannot be -- what this file does instead is
       publish, in two forms anyone can read, the fact that a player is
       mid-match, so one line in that resource can decline to send.

    GTA'S OWN NPC POLICE ARE NOT A THIRD PROBLEM, and this file no longer
    pretends they are. It used to carry a Config.Dispatch.vanillaPolice
    block that shipped OFF and stayed off: a server running a custom
    dispatch script has disabled the vanilla wanted system already, and the
    ones that drive their own logic off the native wanted level would have
    been fought for it by an arena zeroing it mid-match. Three sub-switches
    and a stash-and-restore for a system this server does not run is not
    coverage, it is a block an operator has to read and dismiss. Gone.

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

--- Nil when not in a match, and the match id while one is running. It is
--- the in-a-match latch Enter/Exit pair on, nothing more -- there is no
--- longer any game setting to stash and hand back.
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
-- NO GAME SETTING IS TOUCHED ON THE WAY IN ANY MORE, which is why there is
-- nothing to hand back on the way out. Everything this pair does now is the
-- operator's own disableExports list, and that is symmetric by construction:
-- the same entries called with true on entry and false on exit.
--
-- THE RULE THAT EMPTIED IT, kept here because it is the one worth applying
-- to anything added later: A SETTING THIS RESOURCE CANNOT READ BACK IS ONE
-- IT DOES NOT SET. SetMaxWantedLevel, SetCreateRandomCops and
-- SetPlayerHealthRechargeMultiplier can all be set and none of them can be read
-- -- CitizenFX ships no getter for any of the three. A match that
-- changed one could only put it back by assuming the stock value, and an
-- assumption is not a restore: on a server that caps wanted levels, keeps
-- NPC patrols off its streets, or turns passive health regeneration off
-- through its medical script, handing back 5 / true / 1.0 on the way out
-- would silently undo that operator's setting for the rest of that player's
-- session, off the back of one arena round.
-- ======================================================================

--- Silences everything this resource is able to silence, and records that
--- a match is running so Exit() knows there is something to undo.
---
--- Safe to call twice: a second call while already active is ignored, so a
--- re-entry cannot fire the operator's mute exports a second time and leave
--- the unmute one call short.
--- @param matchId string
function ArenaDispatch.Enter(matchId)
    if restore then return end

    restore = { matchId = matchId }

    callDisableExports(true)
end

--- Undoes Enter(), exactly. Safe to call when nothing is active, which is
--- what lets client/match.lua call it on every exit path -- normal finish,
--- disconnect, resource stop -- without first working out whether it needs
--- to.
function ArenaDispatch.Exit()
    if not restore then return end

    -- Cleared before the call below, so a re-entry racing this exit sees
    -- an inactive state rather than being refused by the guard in Enter.
    restore = nil

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
    -- ONE SWITCH, NOT TWO. `suppressAmbulanceDown` sat on the line above
    -- this one and gated exactly the same function -- two keys an operator
    -- had to set the same way, in two parts of config, to change one
    -- behaviour, and either of them alone silently doing nothing. It is
    -- gone; clearDeadStateImmediately is the switch.
    local config = Config.Dispatch or {}
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
