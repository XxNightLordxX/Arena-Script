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

--- How long the client's respawn may hold the fighter while the world
--- streams in before it places them -- placeAt's deadline in
--- client/match.lua. Protection starts only after that.
local PLACE_WAIT_SECONDS = 5

--- [src] = GetGameTimer() at which the window, plus grace, closes. Opened
--- only here, by the server's own revive -- a client cannot open one.
local protectedUntil = {}

--- Called by server/match.lua at every revive it sends.
--- @param src integer
function ArenaSpawnProtection.Revived(src)
    local seconds = windowSeconds()
    if seconds <= 0 then protectedUntil[src] = nil return end

    -- THE CLIENT'S WINDOW STARTS LATER THAN THIS ONE: the respawn waits up
    -- to PLACE_WAIT_SECONDS for the ground to stream in before it makes the
    -- fighter invulnerable, on top of the trip across the network. The
    -- server window covers that whole wait, so it can never close while an
    -- honest client is still protected.
    local grace = math.max(0, math.min(10, tonumber(config().finiGraceSeconds) or 0))
    protectedUntil[src] = GetGameTimer() + (seconds + PLACE_WAIT_SECONDS + grace) * 1000

    local ok, why = pcall(ArenaSpawnProtection.OnStart, src, seconds)
    if not ok then ArenaLog('spawn protection: the OnStart hook raised -- %s', tostring(why)) end
end

--- A player left the round or was eliminated: their window shrinks to the
--- network grace. NOT deleted outright -- the client stays invulnerable until
--- the exit reaches it, so a detection sampled or in flight during that trip
--- must still be cancelled. Never lengthens a window.
--- @param src integer
function ArenaSpawnProtection.Clear(src)
    local untilAt = protectedUntil[src]
    if not untilAt then return end
    local grace = math.max(0, math.min(10, tonumber(config().finiGraceSeconds) or 0))
    local capped = GetGameTimer() + grace * 1000
    if capped < untilAt then protectedUntil[src] = capped end
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

--- FiniAC's hook contract (docs.fini.ac/resource-api): called with
--- player { source, name, identifiers } and detection { type, data };
--- return false to cancel, the detection (or nil) to let it through. It
--- runs synchronously and must not yield -- nothing here does. Cancels ONLY
--- a listed god-mode-type detection on a player inside a server-opened
--- window. FiniAC's documented god-mode names are GodModePed, GodModeV2 and
--- GodModeV3 (docs.fini.ac/admin-whitelist-detections); 'godmode' covers
--- all three.
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

--- Registers the hook. Called on FiniAC's own `FiniAC:Started` event, and
--- at this resource's start only if FiniAC's `FiniAC:Started` convar is 1 --
--- both exactly as its Resource API page says: the resource being
--- 'started' is NOT enough, its export is not ready for a moment after.
local function hookFini()
    if finiHooked or config().finiHook == false or windowSeconds() <= 0 then return end
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

-- FiniAC was already running when this resource started.
if GetConvarInt('FiniAC:Started', 0) == 1 then hookFini() end

AddEventHandler('playerDropped', function()
    protectedUntil[source] = nil
end)
