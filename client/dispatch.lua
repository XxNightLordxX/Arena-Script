--[[
    crimson_arena/client/dispatch.lua

    Keeping the emergency services out of the arena.

    Three separate problems wear the same coat here, and it is worth being
    clear about which of them this file actually solves:

    1. THE GAME'S OWN POLICE. GTA dispatches NPC cops at gunfire on its own,
       with no script involved. This file switches that off for the length
       of a match and puts it back afterwards. Solved outright.

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
    session, which is why every Enter() has a matching Exit() and Exit() is
    safe to call when nothing is active.
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
    local list = Config.Dispatch and Config.Dispatch.disableExports
    if type(list) ~= 'table' then return end

    for _, entry in ipairs(list) do
        if type(entry) == 'table' and type(entry.resource) == 'string' and type(entry.export) == 'string' then
            if GetResourceState(entry.resource) == 'started' then
                local ok, err = pcall(function()
                    exports[entry.resource][entry.export](nil, enabled)
                end)
                if not ok then
                    print(('[crimson_arena] Config.Dispatch.disableExports: %s:%s failed (%s). Check that export name against that resource\'s own documentation.')
                        :format(entry.resource, entry.export, tostring(err)))
                end
            else
                print(('[crimson_arena] Config.Dispatch.disableExports names "%s", which is not started. Skipping it.')
                    :format(entry.resource))
            end
        end
    end
end

-- ======================================================================
-- ENTER / EXIT
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
        touchedWanted = false,
    }

    if config.suppressPoliceShotsFired ~= false and config.suppressVanillaPolice ~= false then
        restore.touchedPolice = true
        SetPoliceIgnorePlayer(player, true)
        SetDispatchCopsForPlayer(player, false)
        SetCreateRandomCops(false)
    end

    if config.stashWantedLevel ~= false then
        restore.touchedWanted = true
        restore.wantedLevel = GetPlayerWantedLevel(player)
        -- Clearing without also locking the maximum lets the stars come
        -- straight back the first time somebody fires at a passing NPC.
        SetPlayerWantedLevel(player, 0, false)
        SetPlayerWantedLevelNow(player, false)
        SetMaxWantedLevel(0)
    end

    if config.disableHealthRecharge == true then
        SetPlayerHealthRechargeMultiplier(player, 0.0)
    end

    callDisableExports(true)
end

--- Undoes Enter(), exactly. Safe to call when nothing is active, which is
--- what lets client/match.lua call it on every exit path -- normal finish,
--- disconnect, resource stop -- without first working out whether it needs
--- to.
function ArenaDispatch.Exit()
    if not restore then return end

    local config = Config.Dispatch or {}
    local player = PlayerId()
    local previous = restore

    -- Cleared before the calls below, so a re-entry racing this exit sees
    -- an inactive state rather than being refused by the guard in Enter.
    restore = nil

    if previous.touchedPolice then
        SetPoliceIgnorePlayer(player, false)
        SetDispatchCopsForPlayer(player, true)
        SetCreateRandomCops(true)
    end

    if previous.touchedWanted then
        SetMaxWantedLevel(5)
        -- Handed back rather than cleared: walking into an arena is not an
        -- amnesty, and a player who used it as one would be a bug worth
        -- reporting.
        if previous.wantedLevel > 0 then
            SetPlayerWantedLevel(player, previous.wantedLevel, false)
            SetPlayerWantedLevelNow(player, false)
        end
    end

    if config.disableHealthRecharge == true then
        SetPlayerHealthRechargeMultiplier(player, 1.0)
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

--- Undoes ClearDeadState's holding pattern. client/match.lua calls this
--- from its respawn and elimination handlers, both of which place the ped
--- themselves afterwards -- so this restores the ped's properties and
--- deliberately does not touch its position.
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
