-- Crimson Arena: keeping the police and the medics out of the arena.

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

    WHAT IS PUBLISHED, and it is deliberately the same fact twice because
    different scripts want it different ways:
      * a replicated state bag on the player, keyed by
        Config.Dispatch.custom.stateBagKey, holding
        { active = true, matchId = ... }
      * an export, `exports.crimson_arena:IsInArena()`

    THE STATE BAG IS WRITTEN BY THE SERVER, NOT HERE -- see server/dispatch.lua.
    That is a security decision, not a structural one. A replicated bag set
    from the client can be set by ANY client, so a player who never went near
    the arena could pin the flag on themselves and have your dispatch script
    politely ignore them robbing a bank. The server sets it because the
    server is the only party that knows whether someone is really in a match.
    This file reads its own local record for its own exports and never writes
    the bag at all.

    EVERYTHING HERE IS PER-MATCH AND REVERSIBLE. This file is not allowed to
    leak a single setting into the rest of someone's session, which is why
    every Enter() has a matching Exit(), why Exit() is safe to call when
    nothing is active, and why a setting this file cannot read back is one it
    does not set at all -- see ENTER / EXIT below.
]]

ArenaDispatch = {}

local restore = nil

--- What the ped's own properties were before ClearDeadState overwrote them,
--- or nil when no casualty is being held.
---
--- THE RECORD IS THE PERMISSION. ReleaseDeadState may only write a property
--- this table says was taken, so an exit from a round nobody died in writes
--- nothing at all -- which is the whole of the god-mode fix. DO NOT let a
--- release write a property that is not in here. See the header on
--- ReleaseDeadState.
local deadStateHold = nil

--- The three of the four hold properties a client can actually be asked
--- about, read through pcall'd existence checks because an older artifact
--- may not have all of them.
---
--- A MISSING GETTER FALLS BACK TO THE VALUE THE HOLD IS ABOUT TO REPLACE,
--- NEVER to nothing: the release must put a held player back on their feet on
--- every build there is, and "visible, solid, unfrozen" is exactly what this
--- function shipped as before it could ask. So a build with the getters
--- restores what the player had, and one without is no worse than it was.
--- The fallbacks must not be changed to anything else.
--- @param ped integer
--- @return table
local function readPedState(ped)
    local function ask(native, fallback)
        if type(native) ~= 'function' then return fallback end
        local ok, value = pcall(native, ped)
        if not ok then return fallback end
        return value
    end

    return {
        visible = ask(IsEntityVisible, true) ~= false,
        collision = ask(GetEntityCollisionDisabled, false) ~= true,
        frozen = ask(IsEntityPositionFrozen, false) == true,
    }
end

function ArenaDispatch.IsInArena()
    return restore ~= nil
end

function ArenaDispatch.MatchId()
    return restore and restore.matchId or nil
end

exports('IsInArena', ArenaDispatch.IsInArena)
exports('GetArenaMatchId', ArenaDispatch.MatchId)

--- Calls each Config.Dispatch.custom.disableExports entry with `enabled`.
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
-- NO GAME SETTING IS TOUCHED ON THE WAY IN, which is why there is nothing to
-- hand back on the way out. All this pair does is the operator's own
-- disableExports list, and that is symmetric by construction: the same
-- entries called with true on entry and false on exit.
--
-- THE RULE THAT KEEPS IT THAT WAY, and the one to apply to anything added
-- later: A SETTING THIS RESOURCE CANNOT READ BACK IS ONE IT DOES NOT SET.
-- SetMaxWantedLevel, SetCreateRandomCops and
-- SetPlayerHealthRechargeMultiplier can all be set and none of them can be read
-- -- CitizenFX ships no getter for any of the three. A match that
-- changed one could only put it back by assuming the stock value, and an
-- assumption is not a restore: on a server that caps wanted levels, keeps
-- NPC patrols off its streets, or turns passive health regeneration off
-- through its medical script, handing back 5 / true / 1.0 on the way out
-- would silently undo that operator's setting for the rest of that player's
-- session, off the back of one arena round.
-- ======================================================================

function ArenaDispatch.Enter(matchId)
    if restore then return end

    restore = { matchId = matchId }

    callDisableExports(true)
end

function ArenaDispatch.Exit()
    if not restore then return end

    restore = nil

    callDisableExports(false)
end

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
    if config.clearDeadStateImmediately == false then return false end
    if not restore then return false end

    local x, y, z = table.unpack(GetEntityCoords(ped))
    local heading = GetEntityHeading(ped)

    -- READ BEFORE ANYTHING IS WRITTEN, and off the ped as the player had it
    -- rather than off the one the resurrect hands back. What is being
    -- recorded is how this player wanted to be -- invisible on purpose, or
    -- frozen by another resource -- and the resurrect is this file's own
    -- first change to them.
    -- NOT RE-READ WHILE A HOLD IS ALREADY STANDING. A second capture would
    -- record the hold's own settings -- invisible, no collision, frozen -- as
    -- "what the player had", and hand those back as the restore. The first
    -- reading is the only one taken off a ped this file has not touched.
    deadStateHold = deadStateHold or readPedState(ped)

    NetworkResurrectLocalPlayer(x, y, z, heading, true, false)

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
---
--- IT PUTS BACK WHAT WAS THERE, AND IT TOUCHES NOTHING IT DID NOT TAKE.
---
--- IN THE OWNER'S WORDS: "It should not be disabling my god mode ... after
--- the match is over ... It should be reverting me back to what it was
--- before". This wrote four constants -- not invincible, visible, solid,
--- unfrozen -- every single time it ran, and leaveArena runs it on EVERY way
--- out of a round, including the overwhelmingly common one where nobody
--- died and this file had therefore never touched the ped at all. So an
--- admin who walked in with god mode on walked out mortal, somebody who was
--- deliberately invisible was put on show, and a player another resource had
--- frozen was unfrozen -- off the back of an arena round, by a function
--- undoing a hold that was never taken.
---
--- A hold that was never taken is now nothing to undo, and one that WAS
--- taken is undone to the reading captured before it was applied. That is
--- the difference between "back to normal" and "back to what it was", and
--- only the second is what was asked for.
---
--- INVINCIBILITY IS THE ONE THIS CANNOT READ, and it is handled by the rule
--- at the head of ENTER / EXIT rather than by guessing: CitizenFX ships no
--- getter for an entity's invincibility, so the only honest statement this
--- can make is "I set it, therefore I unset it". It must not write `false`
--- into a flag it never wrote `true` into -- that is the god-mode defect --
--- and it must not leave `true` behind either, because this file is what put
--- it there and a fighter who kept it would be untouchable for the rest of
--- their session.
--- @param ped integer
function ArenaDispatch.ReleaseDeadState(ped)
    local hold = deadStateHold
    if not hold then return end
    deadStateHold = nil

    -- Ours, so ours to take back. There is no reading to restore it to.
    SetEntityInvincible(ped, false)

    SetEntityVisible(ped, hold.visible, false)
    SetEntityCollision(ped, hold.collision, true)
    FreezeEntityPosition(ped, hold.frozen)
end

--- Whether this file is currently holding a casualty in the pattern above.
---
--- client/spectate.lua asks it. That file used to ask IsInArena() instead --
--- "am I in a round" as a stand-in for "does somebody else own this ped" --
--- and the two are not the same question. leaveArena stops the spectator
--- camera while the round is still notionally on, so the stand-in answered
--- yes and the camera's own hide was left in place for ReleaseDeadState to
--- undo. That worked only while ReleaseDeadState undid a hold it had never
--- taken, which is the defect above. This is the real question.
--- @return boolean
function ArenaDispatch.IsHoldingDeadState()
    return deadStateHold ~= nil
end

-- A restart mid-match must not leave the operator's dispatch script muted
-- for every fighter for the rest of their session. This is the one teardown
-- that has to happen even when nothing else gets the chance to run.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    ArenaDispatch.Exit()
end)
