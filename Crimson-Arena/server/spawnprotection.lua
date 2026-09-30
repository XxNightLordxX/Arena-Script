-- Crimson Arena: the server's side of the revive invulnerability window.

--[[
    ADDING YOUR ANTICHEAT (server side)

    The arena calls OnStart for a player the moment it revives them with
    protection on (Config.Match.spawnProtection.seconds). If your anticheat
    is told from the server how long to leave a player alone, put that call
    here. The client-side pair is in client/spawnprotection.lua.

    The protection can end early on the client (the fighter fires), so use
    `seconds` as the longest it can last, not the exact time.
]]

ArenaSpawnProtection = {}

--- Called when a player is revived with protection on.
--- @param src integer
--- @param seconds number
function ArenaSpawnProtection.OnStart(src, seconds)
    -- your anticheat call goes here
end

-- ======================================================================
-- Nothing below needs editing.
-- ======================================================================

--- Called by server/match.lua at every revive it sends.
--- @param src integer
function ArenaSpawnProtection.Revived(src)
    local cfg = (Config.Match or {}).spawnProtection
    local seconds = math.max(0, math.min(30, tonumber(type(cfg) == 'table' and cfg.seconds or 0) or 0))
    if seconds <= 0 then return end
    local ok, why = pcall(ArenaSpawnProtection.OnStart, src, seconds)
    if not ok then ArenaLog('spawn protection: the OnStart hook raised -- %s', tostring(why)) end
end
