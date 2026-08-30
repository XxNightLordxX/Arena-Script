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

    THREE FORMS OF THE SAME FACT, because dispatch scripts are written
    differently and none of these is more correct than the others:

      EVENTS -- this resource tells you, so you can keep your own ignore
      list without polling anything:
          AddEventHandler('crimson_arena:dispatch:enter', function(src, matchId) ... end)
          AddEventHandler('crimson_arena:dispatch:exit',  function(src, matchId) ... end)
      Names are Config.Dispatch.custom.enterEvent / exitEvent, and either can
      be set to nil to fire nothing. Both are SERVER events and are never
      sent to a client.


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

--- @return table
local function customConfig()
    return (Config.Dispatch and Config.Dispatch.custom) or {}
end

--- @return string
local function stateKey()
    local key = customConfig().stateBagKey
    return type(key) == 'string' and key ~= '' and key or 'crimsonArena'
end

--- Fires one of the two announcement events, if the operator has named it.
---
--- SERVER events, never sent to a client: "who may be ignored by dispatch"
--- is not a decision a client gets a say in, and an event carrying that fact
--- to every player would be handing them the answer.
--- @param eventName any -- whatever the operator put in config; validated here
--- @param src number
--- @param matchId string
local function announce(eventName, src, matchId)
    if type(eventName) ~= 'string' or eventName == '' then return end

    -- pcall because this crosses into somebody else's handler: a dispatch
    -- script that throws must not take a match start or a match end down
    -- with it.
    local ok, err = pcall(TriggerEvent, eventName, src, matchId)
    if not ok then
        ArenaLog('a handler for "%s" errored: %s', eventName, tostring(err))
    end
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
    announce(customConfig().enterEvent, src, matchId)
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

    local matchId = active[src]
    active[src] = nil

    -- Announced even when nothing was set, so a dispatch script that missed
    -- the enter -- it restarted, it was not running yet -- still gets told to
    -- drop this player rather than keeping them ignored forever. A clear for
    -- somebody who was never flagged is a harmless no-op on its side.
    announce(customConfig().exitEvent, src, matchId)

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

-- A dispatch script that restarts mid-round comes back with an empty ignore
-- list and starts alerting on a fight already in progress. Operators name
-- those resources in Config.Dispatch.custom.resyncResources and every player
-- currently in an arena is re-announced the moment one comes back up.
AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then return end

    local watched = customConfig().resyncResources
    if type(watched) ~= 'table' then return end

    local wanted = false
    for _, name in ipairs(watched) do
        if name == resource then wanted = true break end
    end
    if not wanted then return end

    local count = 0
    for src, matchId in pairs(active) do
        announce(customConfig().enterEvent, src, matchId)
        count = count + 1
    end

    if count > 0 then
        ArenaLog('%s restarted -- re-announced %d player(s) still in an arena.', resource, count)
    end
end)

-- Nothing is left flagged when this resource goes away. A dispatch script
-- that outlives a restart would otherwise keep reading a stale bag and keep
-- suppressing alerts for players who are standing in the middle of town.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for src in pairs(active) do
        ArenaDispatch.Clear(src)
    end
end)
