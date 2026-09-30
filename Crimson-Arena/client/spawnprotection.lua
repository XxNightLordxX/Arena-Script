-- Crimson Arena: invulnerability after a revive (Config.Match.spawnProtection).

--[[
    ADDING YOUR ANTICHEAT

    If your anticheat flags a player who cannot be hurt, tell it about this
    window in the two functions directly below -- that is the only place
    you need to edit. The arena calls OnStart the moment protection goes on
    and OnEnd the moment it comes off (timer up, the fighter fired, a newer
    revive, or they left the round). The server side has the same pair in
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

local POLL_MS = 100
local token = 0

local function hook(fn, ...)
    local ok, why = pcall(fn, ...)
    if not ok then print(('[crimson_arena] spawn protection hook raised: %s'):format(tostring(why))) end
end

--- Starts a window. `stillWanted` answers whether the round that asked for
--- it is still the one being played; when it stops answering true the
--- window closes early.
---
--- "I SET IT, THEREFORE I UNSET IT" -- the same rule as
--- ArenaDispatch.ReleaseDeadState: there is no getter for invincibility, so
--- this writes `false` only over the `true` it wrote itself, and a newer
--- revive takes the flag over rather than having it cut short.
--- @param stillWanted fun(): boolean
function ArenaSpawnProtection.Start(stillWanted)
    local cfg = (Config.Match or {}).spawnProtection
    local seconds = math.max(0, math.min(30, tonumber(type(cfg) == 'table' and cfg.seconds or 0) or 0))
    if seconds <= 0 then return end

    token = token + 1
    local mine = token
    local ped = PlayerPedId()
    SetEntityInvincible(ped, true)
    hook(ArenaSpawnProtection.OnStart, ped, seconds)

    CreateThread(function()
        local ends = GetGameTimer() + seconds * 1000
        while GetGameTimer() < ends do
            if token ~= mine or not stillWanted() then break end
            -- PROTECTION IS FOR ARRIVING, NOT ATTACKING.
            if IsPedShooting(PlayerPedId()) then break end
            Wait(POLL_MS)
        end
        -- A newer revive owns the flag now; it clears it itself.
        if token == mine then
            SetEntityInvincible(ped, false)
            hook(ArenaSpawnProtection.OnEnd, ped)
        end
    end)
end
