--[[
    crimson_arena/server/exports.lua

    THE PUBLIC SURFACE. Everything another resource on this server is allowed
    to ask the arena, in one file, so it can be read in one sitting.

    WHY IT IS A FILE AND NOT A LINE HERE AND THERE. This resource already
    learned that lesson once: `/arenadispatch` was registered the whole time
    and an operator reported it did not exist, because nothing told anybody
    the name. An export has the same failure mode with a worse ending -- a
    server owner greps this resource, finds nothing useful, and writes their
    own version of a question the arena could have answered. One file, listed
    last in the manifest, is a thing somebody can find.

    EVERY ONE OF THESE IS A READING. Nothing here stops a match, pays anybody,
    issues kit or clears a hold, and that is a deliberate line rather than a
    gap to fill in later. An export is callable by ANY resource on the box
    with no ACE check in front of it -- the admin tablet's gates do not apply
    and cannot be made to -- so an action export would be an unauthenticated
    way into the arena's money and its rounds. Readings cost nothing if a
    badly-written resource calls them in a loop. DO NOT add an action here
    without deciding, out loud, who is allowed to call it and how you know.

    THREE RULES, and all three exist because of something this resource does
    elsewhere:

      1. NOTHING INTERNAL IS HANDED OUT. ArenaLobby.All() returns the LIVE
         match tables -- a fresh array, but the same tables the round is being
         fought in. Returning one of those would let any resource on the
         server rename a match, empty its roster or zero its pot by writing to
         a field. Every table below is built here, from scalars, per call.

      2. NOTHING THROWS INTO THE CALLER. Each body runs inside pcall and
         answers with something usable if the arena is mid-restart, a module
         has not loaded yet, or one of these functions changes shape. A
         resource calling an export must not be able to die because the arena
         is having a bad minute.

      3. EVERY ANSWER IS THE SAME SHAPE EVERY TIME. Once sc-dispatch or a
         phone app reads `pot` off one of these, changing what it holds breaks
         their server silently -- no error, just a wrong number on somebody's
         screen. Add a field freely; do not rename or repurpose one.

    LOADED LAST, after every module it asks. See fxmanifest.lua.

    THE OTHER TWO WAYS IN are not here and are not going anywhere: the
    `crimson_arena:dispatch:enter` / `:exit` server events, and the replicated
    `crimsonArena` state bag. config.lua documents both under
    Config.Dispatch.custom, with the reasons to prefer each.
]]

--- Runs `fn` and answers `fallback` if anything at all goes wrong.
---
--- THE FALLBACK IS ALWAYS THE QUIET ANSWER -- an empty list, a zero, the
--- arena being shut -- so a caller that never checks still behaves as though
--- the arena has nothing going on, rather than as though it has something it
--- cannot describe.
local function answer(fallback, fn)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

--- Whether the doors are open right now, schedule and admin override both.
exports('IsArenaOpen', function()
    return answer(false, function()
        if type(ArenaHoursOpen) ~= 'function' then return false end
        return ArenaHoursOpen() ~= false
    end)
end)

--- Every match the arena knows about, as flat rows.
---
--- BUILT FIELD BY FIELD, never `out[#out + 1] = match`. See rule 1 above.
--- `players` is a COUNT rather than a roster: who is in a round is answerable
--- through GetArenaPlayers and IsPlayerInArena, and a roster here would mean
--- copying every fighter's table on every call for the one caller in ten that
--- wants it.
exports('GetMatches', function()
    return answer({}, function()
        if type(ArenaLobby) ~= 'table' or type(ArenaLobby.All) ~= 'function' then return {} end

        local rows = {}
        for _, match in ipairs(ArenaLobby.All()) do
            if type(match) == 'table' then
                rows[#rows + 1] = {
                    id = match.id,
                    label = match.label,
                    arenaKey = match.arenaKey,
                    modeKey = match.modeKey,
                    state = match.state,
                    players = type(ArenaLobby.PlayerCount) == 'function'
                        and ArenaLobby.PlayerCount(match) or 0,
                    pot = (type(ArenaBetting) == 'table'
                        and type(ArenaBetting.GetPot) == 'function')
                        and ArenaBetting.GetPot(match.id) or 0,
                }
            end
        end
        return rows
    end)
end)

--- What is staked on one match right now, entry fees and side bets together.
exports('GetPot', function(matchId)
    return answer(0, function()
        if type(ArenaBetting) ~= 'table' or type(ArenaBetting.GetPot) ~= 'function' then
            return 0
        end
        return ArenaBetting.GetPot(matchId) or 0
    end)
end)

--- What the arena is still owed, by character.
---
--- Answers the whole slate, or one character's row when given a citizen id.
--- An id nobody owes anything for comes back as nil, which is the honest
--- answer and the one a caller can test.
exports('GetOwedKit', function(citizenid)
    return answer(nil, function()
        if type(ArenaAmmo) ~= 'table' or type(ArenaAmmo.OwedKit) ~= 'function' then
            -- WRITTEN AS AN `if`, NOT `citizenid ~= nil and nil or {}`. That
            -- form can never yield nil: `true and nil` is nil, and `nil or {}`
            -- is {}, so asking about one character on a build with no door
            -- would answer "they owe nothing" instead of "I cannot tell you".
            -- This exact trap has cost this resource two defects already.
            if citizenid ~= nil then return nil end
            return {}
        end

        local rows = {}
        for _, row in ipairs(ArenaAmmo.OwedKit()) do
            local weapons, items = {}, {}
            for _, weapon in ipairs(row.weapons or {}) do
                weapons[#weapons + 1] = { name = weapon.name, serial = weapon.serial }
            end
            for _, item in ipairs(row.items or {}) do
                items[#items + 1] = { name = item.name, amount = item.amount }
            end

            local copy = {
                citizenid = row.citizenid,
                count = row.count or 0,
                weapons = weapons,
                items = items,
            }
            if citizenid ~= nil and row.citizenid == citizenid then return copy end
            rows[#rows + 1] = copy
        end

        -- ASKED ABOUT ONE CHARACTER AND NOT FOUND is nil, not an empty row.
        -- An empty row reads as "they owe nothing and the arena knows it",
        -- which is a different claim from "nobody by that name is on the
        -- slate", and only one of them is true here.
        if citizenid ~= nil then return nil end
        return rows
    end)
end)

--- What the arena still owes PLAYERS, the other way round: the total, as one
--- number.
---
--- A NUMBER AND NOT THE LEDGER. Who is owed what is money, and a list of it
--- is a thing to put behind an admin screen rather than hand to whatever
--- asks. The tablet's Money owed report is that screen.
---
--- ONE RETURN VALUE, because everything here goes through `answer` and pcall
--- carries one. Outstanding() answers with a count AND a total; the total is
--- the one a caller outside this resource can do anything with.
exports('GetOwedMoney', function()
    return answer(0, function()
        if type(ArenaBetting) ~= 'table' or type(ArenaBetting.Outstanding) ~= 'function' then
            return 0
        end
        local _, total = ArenaBetting.Outstanding()
        return total or 0
    end)
end)
