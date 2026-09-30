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

local function config()
    local cfg = (Config.Match or {}).spawnProtection
    return type(cfg) == 'table' and cfg or {}
end

local function windowSeconds()
    return math.max(0, math.min(30, tonumber(config().seconds) or 0))
end

--- [src] = GetGameTimer() at which the window, plus grace, closes. Opened
--- only here, by the server's own revive -- a client cannot open one.
local protectedUntil = {}

--- Called by server/match.lua at every revive it sends.
--- @param src integer
function ArenaSpawnProtection.Revived(src)
    local seconds = windowSeconds()
    if seconds <= 0 then protectedUntil[src] = nil return end

    local grace = math.max(0, math.min(10, tonumber(config().finiGraceSeconds) or 0))
    protectedUntil[src] = GetGameTimer() + (seconds + grace) * 1000

    local ok, why = pcall(ArenaSpawnProtection.OnStart, src, seconds)
    if not ok then ArenaLog('spawn protection: the OnStart hook raised -- %s', tostring(why)) end
end

--- Whether `src` is inside a revive window the server opened.
--- @param src integer
--- @return boolean
function ArenaSpawnProtection.IsProtected(src)
    local untilAt = protectedUntil[src]
    if not untilAt then return false end
    if GetGameTimer() >= untilAt then
        protectedUntil[src] = nil
        return false
    end
    return true
end

-- ----------------------------------------------------------------------
-- FiniAC (Config.Match.spawnProtection.finiHook)
-- ----------------------------------------------------------------------

--- FiniAC's hook contract (docs.fini.ac/resource-api): return false to
--- cancel, the detection (or nil) to let it through. Cancels ONLY a listed
--- god-mode-type detection on a player inside a server-opened window.
function ArenaSpawnProtection.FiniDetectionHook(player, detection)
    if type(player) ~= 'table' or type(detection) ~= 'table' then return detection end
    local src = tonumber(player.source)
    if not src or not ArenaSpawnProtection.IsProtected(src) then return detection end

    local kind = tostring(detection.type or ''):lower()
    local list = config().finiDetections
    for _, fragment in ipairs(type(list) == 'table' and list or {}) do
        if type(fragment) == 'string' and fragment ~= '' and kind:find(fragment:lower(), 1, true) then
            ArenaLog('spawn protection: cancelled FiniAC %s on %s inside their revive window.',
                tostring(detection.type), tostring(src))
            return false
        end
    end
    return detection
end

local finiHooked = false

local function hookFini()
    if finiHooked or config().finiHook == false or windowSeconds() <= 0 then return end
    if GetResourceState('FiniAC') ~= 'started' then return end
    local ok, why = pcall(function() exports.FiniAC:AddDetectionHook(ArenaSpawnProtection.FiniDetectionHook) end)
    if ok then
        finiHooked = true
        ArenaLog('spawn protection: FiniAC detection hook registered.')
    else
        ArenaLog('spawn protection: FiniAC is running but the hook could not be registered -- %s', tostring(why))
    end
end

-- FiniAC fires this every time it finishes starting; a restart of FiniAC
-- drops the hooks it had, so it is registered again.
AddEventHandler('FiniAC:Started', function()
    finiHooked = false
    hookFini()
end)

CreateThread(hookFini)

AddEventHandler('playerDropped', function()
    protectedUntil[source] = nil
end)
