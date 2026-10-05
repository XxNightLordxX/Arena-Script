-- Crimson Arena: invulnerability after a revive (Config.Match.spawnProtection).

--[[
    ADDING YOUR ANTICHEAT

    If your anticheat flags a player who cannot be hurt, tell it about this
    window in the two functions directly below -- that is the only place
    you need to edit. The arena calls OnStart the moment protection goes on
    and OnEnd the moment it comes off (timer up, the fighter attacked, or
    they left the round). A newer revive while a window is still open takes
    it over: OnStart is called again with no OnEnd in between. The server side has an OnStart only, in
    server/spawnprotection.lua, called at the same revive, if your anticheat
    is told from the server instead.

    Look in your anticheat's own documentation for how it exempts a player
    for a short time, and put that call here. The arena itself never reads,
    changes or cancels anything an anticheat does.
]]

ArenaSpawnProtection = {}

--- Called when protection goes ON for this player.
--- @param ped integer
--- @param seconds number
function ArenaSpawnProtection.OnStart(ped, seconds)
    -- your anticheat call goes here
end

--- Called when protection comes OFF for this player.
--- @param ped integer
function ArenaSpawnProtection.OnEnd(ped)
    -- your anticheat call goes here
end

-- ======================================================================
-- Nothing below needs editing.
-- ======================================================================

-- THE FIRE KEYS ONLY: attack, attack 2, melee alternate (LMB / RT). The
-- light and heavy melee inputs (140 R/B, 141 Q/A) share their keys with
-- reload, cover and pad sprint, so pressing them would end protection on a
-- non-attack; a real swing is caught by IsPedPerformingMeleeAction instead.
local ATTACK_CONTROLS = { 24, 257, 142 }
local token = 0

--- The ped the open window made invincible, or nil when none is open.
local activePed = nil

local function hook(fn, ...)
    local ok, why = pcall(fn, ...)
    if not ok then print(('[crimson_arena] spawn protection hook raised: %s'):format(tostring(why))) end
end

--- Whether the fighter is attacking this frame: firing, swinging, or
--- pressing an attack key (which also covers a swing that has not landed).
---
--- THEIR OWN ATTACK ONLY. IsPedPerformingMeleeAction is the fighter's own
--- swing; IsPedInMeleeCombat was also true while an ENEMY meleed them, so a
--- rusher could switch a fresh spawn's protection off by punching it. And
--- only ENABLED controls count: a press on a control the game has disabled
--- (a menu, the phone) is not an attack.
local function attacking()
    local ped = PlayerPedId()
    if IsPedShooting(ped) or IsPedPerformingMeleeAction(ped) then return true end
    for _, control in ipairs(ATTACK_CONTROLS) do
        if IsControlJustPressed(0, control) then return true end
    end
    return false
end

--- Closes the open window now, if there is one. Idempotent.
---
--- "I SET IT, THEREFORE I UNSET IT" -- the same rule as
--- ArenaDispatch.ReleaseDeadState: there is no getter for invincibility, so
--- this writes `false` only while a window it opened is still open. Both the
--- ped it was put on and the current ped are cleared, in case the ped was
--- rebuilt mid-window.
function ArenaSpawnProtection.Stop()
    if not activePed then return end
    local ped = activePed
    activePed = nil
    token = token + 1
    SetEntityInvincible(ped, false)
    SetPlayerInvincible(PlayerId(), false)
    local now = PlayerPedId()
    if now ~= ped then SetEntityInvincible(now, false) end
    hook(ArenaSpawnProtection.OnEnd, ped)
end

--- Starts a window. `stillWanted` answers whether the round that asked for
--- it is still the one being played; when it stops answering true the
--- window closes early. A newer revive takes over the open window rather
--- than being cut short by it.
--- @param stillWanted fun(): boolean
function ArenaSpawnProtection.Start(stillWanted)
    local cfg = (Config.Match or {}).spawnProtection
    local seconds = math.max(0, math.min(30, tonumber(type(cfg) == 'table' and cfg.seconds or 0) or 0))
    if seconds <= 0 then return end

    -- ADMIN GOD MODE IS LEFT ALONE. A player who is already invincible and
    -- not through a window of ours (an admin menu turned it on) needs no
    -- protection, and nothing here may switch theirs off -- so no window is
    -- opened at all and neither Start nor Stop writes a flag.
    if not activePed and GetPlayerInvincible(PlayerId()) then return end

    token = token + 1
    local mine = token
    activePed = PlayerPedId()
    SetEntityInvincible(activePed, true)
    SetPlayerInvincible(PlayerId(), true)
    hook(ArenaSpawnProtection.OnStart, activePed, seconds)

    CreateThread(function()
        local ends = GetGameTimer() + seconds * 1000
        local ped = activePed
        local health = GetEntityHealth(ped)
        while GetGameTimer() < ends do
            if token ~= mine or not stillWanted() then break end
            -- HELD EVERY FRAME, NOT SET ONCE. In live testing a single
            -- SetEntityInvincible did not stop revived fighters dying: other
            -- resources (medical, the ped being rebuilt) clear it, and the
            -- entity flag alone does not cover every damage path for a
            -- player. So both flags are re-applied each frame on the current
            -- ped, and any health lost anyway is put straight back.
            local now = PlayerPedId()
            if now ~= ped then ped = now; activePed = now; health = GetEntityHealth(now) end
            SetEntityInvincible(ped, true)
            SetPlayerInvincible(PlayerId(), true)
            local h = GetEntityHealth(ped)
            if h < health and h > 0 then SetEntityHealth(ped, health) elseif h > health then health = h end
            -- PROTECTION IS FOR ARRIVING, NOT ATTACKING -- any attack, gun
            -- or melee, ends it. EVERY FRAME, because a shot is one frame
            -- long: polled every 100 ms, five single shots in six went by
            -- unseen.
            if attacking() then break end
            Wait(0)
        end
        if token == mine then ArenaSpawnProtection.Stop() end
    end)
end

-- A STOPPED OR RESTARTED RESOURCE KILLS THE THREAD ABOVE, and with it the
-- only thing that would have cleared the flag. Without this a restart
-- inside the window left the player invincible until their ped was rebuilt.
AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then ArenaSpawnProtection.Stop() end
end)
