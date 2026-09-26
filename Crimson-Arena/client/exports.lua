--[[
    crimson_arena/client/exports.lua

    THE PUBLIC SURFACE ON THE CLIENT, and the counterpart to
    server/exports.lua rather than a second copy of it.

    TWO FILES BECAUSE THERE ARE TWO REALMS, not because the surface is split.
    An export registered in a server script is callable only from a server
    script, and one registered here only from a client -- so the server file
    cannot hold these, however much one file would be tidier. Each realm has
    all of its own surface in one place, which is the property that matters:
    somebody looking for what the arena can tell a client finds it here and
    nowhere else.

    THE SAME THREE RULES APPLY, and they are stated in full in
    server/exports.lua: nothing internal is handed out, nothing throws into a
    caller, and the shape is a promise. The bodies here are one line each and
    return a boolean or a string, so the first rule has nothing to do -- there
    is no table to copy.

    READINGS ONLY, exactly as on the server. Nothing here changes anything.

    PREFER THE STATE BAG FOR THIS QUESTION IF YOU HAVE A CHOICE.
    `LocalPlayer.state.crimsonArena` answers the same thing with no call and
    no dependency on this resource being started, and it is what config.lua
    recommends under Config.Dispatch.custom. These exist for a script that
    would rather call something than read a bag.

    LOADED LAST of the client scripts, after everything it asks. See
    fxmanifest.lua.
]]

--- Runs `fn` and answers `fallback` if anything at all goes wrong.
---
--- The client half of the same guard the server file uses, and for the same
--- reason: a resource asking the arena a question must not be able to die
--- because the arena is mid-restart or a file failed to load.
local function answer(fallback, fn)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

--- Whether the player at this client is in a match right now.
---
--- WRAPPED IN A CLOSURE, NOT PASSED BY REFERENCE. This was
--- `exports('IsInArena', ArenaDispatch.IsInArena)`, which binds whatever that
--- field held at load time -- so a later reassignment would leave the export
--- calling the old function with nobody able to tell. The wrapper looks the
--- field up per call, which is what the three server exports have always
--- done.
exports('IsInArena', function()
    return answer(false, function()
        if type(ArenaDispatch) ~= 'table' or type(ArenaDispatch.IsInArena) ~= 'function' then
            return false
        end
        return ArenaDispatch.IsInArena() == true
    end)
end)

--- The id of the match this client is in, or nil.
exports('GetArenaMatchId', function()
    return answer(nil, function()
        if type(ArenaDispatch) ~= 'table' or type(ArenaDispatch.MatchId) ~= 'function' then
            return nil
        end
        return ArenaDispatch.MatchId()
    end)
end)
