--[[
    crimson_arena/server/dispatch.lua

    The authoritative answer to "is this player in the arena right now",
    published for any other resource to read.

    WHY THIS LIVES ON THE SERVER. A dispatch script asking that question is
    deciding whether to suppress an alert, which makes the answer worth
    lying about: a replicated state bag written from the client can be
    written by ANY client, so a player who has never been near the arena
    could pin the flag on themselves and have your dispatch script quietly
    ignore them shooting up a bank. Only the server knows who is genuinely
    in a match, so only the server writes it.

    TWO FORMS OF THE SAME FACT, because different scripts want it different
    ways and neither is more correct:

      STATE BAG -- replicated, readable from both realms with no call:
          -- server
          if Player(src).state.crimsonArena then return end
          -- client, about yourself
          if LocalPlayer.state.crimsonArena then return end

      EXPORTS -- for scripts that would rather ask:
          exports.crimson_arena:IsPlayerInArena(src)
          exports.crimson_arena:GetPlayerMatchId(src)
          exports.crimson_arena:GetArenaPlayers()

    The key is Config.Dispatch.stateBagKey, renameable for a server that
    already uses `crimsonArena` for something else.

    WHAT THIS FILE DOES NOT DO: suppress anything. It reports. The actual
    silencing of the game's own police, and the trick that stops a medical
    script's polling loop ever seeing a dead player, are both client-side --
    see client/dispatch.lua. This file exists so that the alerts THIS
    resource cannot reach can be declined at their source, by the resource
    that owns them, on the strength of a fact it can trust.
]]

ArenaDispatch = {}

--- Mirrors what has been written to each player's bag, so Clear() can be
--- called unconditionally without a bag read, and so GetArenaPlayers() does
--- not have to walk every connected player asking.
--- @type table<number, string>
local active = {}

--- @return string
local function stateKey()
    local key = Config.Dispatch and Config.Dispatch.stateBagKey
    return type(key) == 'string' and key ~= '' and key or 'crimsonArena'
end

-- ======================================================================
-- WRITING THE FACT
-- ======================================================================

--- Marks a player as being in `matchId`. Called when they are placed in the
--- arena, not when they join the lobby -- somebody sitting in a menu
--- choosing a rifle is not in a fight, and suppressing their alerts would
--- be a hole rather than a feature.
--- @param src number
--- @param matchId string
function ArenaDispatch.Set(src, matchId)
    if type(src) ~= 'number' or src <= 0 then return end
    if not Arena.IsKey(matchId) then return end

    active[src] = matchId
    Player(src).state:set(stateKey(), { active = true, matchId = matchId }, true)
end

--- Clears the flag. Deliberately unconditional and idempotent: it is called
--- from every exit path there is -- match end, elimination, leaving, an
--- admin stopping a match, a disconnect, the resource shutting down -- and
--- several of those can happen to the same player in quick succession.
--- A flag that outlives the match it belonged to would suppress that
--- player's alerts for the rest of their session.
--- @param src number
function ArenaDispatch.Clear(src)
    if type(src) ~= 'number' or src <= 0 then return end

    active[src] = nil

    -- Guarded because a player who has already dropped has no state bag to
    -- write to, and the disconnect path reaches here after they are gone.
    local ok = pcall(function()
        Player(src).state:set(stateKey(), nil, true)
    end)
    if not ok then
        ArenaDebug('dispatch: could not clear the arena flag for %s -- they are most likely already gone.', tostring(src))
    end
end

-- ======================================================================
-- READING THE FACT
-- ======================================================================

--- @param src number
--- @return boolean
function ArenaDispatch.IsPlayerInArena(src)
    return active[src] ~= nil
end

--- @param src number
--- @return string|nil
function ArenaDispatch.GetPlayerMatchId(src)
    return active[src]
end

--- Every player currently in a match, as a server-id -> match-id map. A
--- copy, so a caller cannot edit this file's own record.
--- @return table<number, string>
function ArenaDispatch.GetArenaPlayers()
    local out = {}
    for src, matchId in pairs(active) do out[src] = matchId end
    return out
end

exports('IsPlayerInArena', function(src) return ArenaDispatch.IsPlayerInArena(src) end)
exports('GetPlayerMatchId', function(src) return ArenaDispatch.GetPlayerMatchId(src) end)
exports('GetArenaPlayers', function() return ArenaDispatch.GetArenaPlayers() end)

-- Nothing is left flagged when this resource goes away. A dispatch script
-- that outlives a restart would otherwise keep reading a stale bag and keep
-- suppressing alerts for players who are standing in the middle of town.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src in pairs(active) do
        ArenaDispatch.Clear(src)
    end
end)
