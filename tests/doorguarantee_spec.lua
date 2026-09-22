--[[
    crimson_arena/tests/doorguarantee_spec.lua

    ONE PROMISE, PROVED ON EVERY WAY OUT.

        Whatever a player owned before the match, they get back.
        Nothing the match produced leaves with them.

    Everything else in this resource is a feature. This is the promise, because
    it is the one whose failure a player cannot fix and would not forgive.

    WHY THIS FILE EXISTS SEPARATELY from tests/ammo_spec.lua: that file tests
    server/ammo.lua directly, and passed while the promise was broken. A player
    torn down through ArenaLobby.Destroy's fallback had their flag cleared and
    their routing bucket returned and was never reclaimed -- so they kept the
    arena kit and their real belongings stayed in a stash. The unit was correct
    and one caller did not call it.

    So this file does not test the door. It drives the whole server stack
    through every exit an arena has and asserts the promise came out the other
    side: finishing, leaving, being eliminated, disconnecting, a host closing
    the lobby, an admin stopping it, and the resource shutting down mid-round.

    A new way out of an arena that forgets to reclaim fails here by name.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

--- WHETHER THE ARENA IS STILL HOLDING THIS PLAYER'S OWN KIT.
---
--- ArenaAmmo.IsHolding answered this until 2fec9fe deleted it: nothing in the
--- shipped tree called it. HeldFor is the reader that survived, and the commit
--- that removed the other says so in as many words -- both went through the
--- same private ownRecord, which is what makes this an exact stand-in rather
--- than an approximation. The question the tests below ask is unchanged; only
--- the function that answers it is.
--- @param ammo table -- env.ArenaAmmo
--- @param src integer
--- @return boolean
local function isHolding(ammo, src)
    return ammo.HeldFor(src) ~= nil
end

--- What every player in these tests owns before they go near the arena.
local OWN = {
    { name = 'phone', count = 1 },
    { name = 'burger', count = 3 },
    { name = 'ammo-rifle-ap', count = 40 },   -- deliberately an ARENA item too
}

--- @param ids integer[]
--- @param mutate fun(config: table)?
--- @return table server
--- @param extra table[]? -- items every player also starts with
--- @param opts table|nil
---   tickMs  how far GetGameTimer jumps per call. The default of a whole
---           MINUTE is what most of this file wants -- it makes round timers
---           expire so a match cannot outlive the test looking at it. It also
---           makes it impossible to hold a second match live while asking
---           anything about the first, so the multi-match section passes a
---           small value instead. Default kept exactly as it was.
local function newServer(ids, mutate, extra, opts)
    opts = opts or {}
    local wallets, inv, stashes = {}, {}, {}
    for _, src in ipairs(ids) do
        wallets[src] = {
            citizenid = 'CID' .. src,
            name = 'Player' .. src,
            money = { cash = 50000, bank = 0 },
        }
        inv[src] = {}
        -- METADATA COMES WITH THE ITEM. It was dropped here, so nothing in
        -- this file could carry an item whose IDENTITY is its metadata -- a
        -- phone with a number, a licence with a name -- and the door's
        -- promise is about those more than about a count of burgers.
        for _, item in ipairs(OWN) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count, metadata = item.metadata }
        end
        for _, item in ipairs(extra or {}) do
            inv[src][#inv[src] + 1] = { name = item.name, count = item.count, metadata = item.metadata }
        end
    end

    local qbx = Sandbox.newQbxCore(wallets)
    local threads = Sandbox.newThreadRunner()
    local console, netEvents, handlers = {}, {}, {}

    --- The console commands the resource registers.
    local commands = {}

    --- Which routing bucket each player is standing in.
    local buckets = {}

    --- Inventories that refuse everything offered to them.
    local refusingAdds = {}

    --- Inventories that ACCEPT everything and answer nothing.
    local lyingAdds = {}

    --- Server convars, as this box has them.
    local convars = { ['inventory:cleartime'] = tonumber(opts.cleartime) or 5 }

    --- Every id this fixture knows to be a CONTAINER rather than a stash,
    --- so the reads above can tell the two apart.
    local containerKeys = {}

    --- Every AddItem this run, in order: which inventory, what, and WHICH
    --- SLOT the caller asked for.
    local addCalls = {}

    --- Per inventory, the slot numbers the last ClearInventory told the
    --- client about. An empty list here means the player's screen still
    --- shows everything that was just taken off them.
    local clientTold = {}

    --- CitizenFX's `table.type`, which is not Lua's and is not ox_lib's.
    ---
    --- It answers 'empty', 'array', 'hash' or 'mixed', and the case that
    --- matters is the first one: an EMPTY table is 'empty', NOT 'array'.
    --- ox_inventory's Clear tests for 'array' exactly, so `{}` misses it --
    --- which is the entire defect this fixture now reproduces. Written out
    --- here rather than stubbed to a constant because getting this one
    --- answer wrong is what made the bug invisible.
    local function cfxTableType(tbl)
        if next(tbl) == nil then return 'empty' end

        local count = 0
        for _ in pairs(tbl) do count = count + 1 end

        local sequence = 0
        for _ in ipairs(tbl) do sequence = sequence + 1 end

        if sequence == count then return 'array' end
        if sequence == 0 then return 'hash' end
        return 'mixed'
    end

    --- Set by server.watchClientEvents, called for every TriggerClientEvent.
    --- Declared HERE rather than on the fixture table because the env closure
    --- below is built before that table exists.
    local clientEventHook = nil

    local function bucket(id)
        if type(id) == 'number' then
            inv[id] = inv[id] or {}
            return inv[id]
        end
        stashes[id] = stashes[id] or {}
        return stashes[id]
    end

    --- Stash ids ox_inventory will answer an EMPTY LIST for, whatever is
    --- really in them.
    ---
    --- THIS IS NOT A FAILURE ox_inventory REPORTS. A stash it has forgotten
    --- -- because the resource restarted, or the row was re-registered under
    --- a different name -- reads exactly like a stash with nothing in it, and
    --- that ambiguity is the whole subject of the tests that use this.
    local forgotten = {}

    --- The swapItems hook the resource registers, so these can drive it. The
    --- stub used to throw it away, which made every question about who the
    --- guard applies to unanswerable from in here.
    local hook

    --- Which container inventories ox_inventory is currently holding. A
    --- container is NOT reachable by id until something wakes it -- see
    --- wakeContainer in server/ammo.lua -- so this models the one thing that
    --- makes the police-bag defect possible: `GetInventoryItems(containerId)`
    --- answers nothing for a container that has been dropped from memory, and
    --- only GetContainerFromSlot can bring one back.
    local livingContainers = {}

    --- Set by a test to model an ox_inventory build old enough not to have
    --- GetContainerFromSlot at all.
    local noContainerExport = false

    --- Every statement the resource sends, in order, so a test can say which
    --- tables it touched -- and refuse anything that is not its own.
    local queries = {}

    --- oxmysql, when a test asks for one. `opts.dbFails` models the case an
    --- operator actually hits: the database is connected and every statement
    --- is refused -- a read-only user, a missing table, a full disk.
    local oxmysql = {
        query = function(_self, sql, params, cb)
            queries[#queries + 1] = sql

            -- THE JAM LIST AS IT STOOD BEFORE THE RESTART. `opts.jamRows` is
            -- how a test says "this table already had rows in it when the
            -- process started", which is the only way to drive the read-back
            -- path -- everything else here answers an empty table.
            -- TAKEN AND NEVER ANSWERED, which is the window the door's own
            -- guard is about: oxmysql has the read, `jammedStash` is still
            -- empty, and empty reads exactly like "nothing is jammed".
            if opts.holdJamRead
                and sql:find('crimson_arena_jammed_stash', 1, true)
                and sql:find('SELECT', 1, true)
            then
                return
            end

            if opts.jamRows and not opts.dbFails
                and sql:find('crimson_arena_jammed_stash', 1, true)
                and sql:find('SELECT', 1, true)
            then
                local rows = {}
                for _, stash in ipairs(opts.jamRows) do rows[#rows + 1] = { stash = stash } end
                if cb then cb(rows) end
                return rows
            end

            -- `opts.dbFails and nil or {}` COULD NEVER BE nil, which made
            -- this knob inert for as long as it existed: `true and nil` is
            -- nil, and `nil or {}` is {}. So every test that asked for a
            -- failing database got a HEALTHY one answering an empty table,
            -- and passed for the wrong reason. It is the same Lua trap that
            -- bit unpaidreplay_spec's database switch; `x and nil or y` is
            -- never safe when x is meant to select nil.
            -- AND THE CASE BETWEEN THE TWO, which is the one operators
            -- actually hit: a user with SELECT and no INSERT. Reads land,
            -- writes come back empty. `dbFails` models the whole database
            -- being unreachable; this models it being half granted.
            local answer = nil
            if not opts.dbFails then
                local writing = not sql:find('SELECT', 1, true)
                    and not sql:find('CREATE TABLE', 1, true)
                if not (opts.failWrites and writing) then answer = {} end
            end
            if cb then cb(answer) end
            return answer
        end,
    }
    oxmysql.execute = oxmysql.query
    oxmysql.scalar = oxmysql.query
    oxmysql.insert = oxmysql.query
    oxmysql.update = oxmysql.query

    local ox = {
        RegisterStash = function() return true end,
        --- ox_inventory's own export, modelled on its real body: find the
        --- item in that slot, and if the inventory behind its container key
        --- is not in memory, CREATE it -- empty.
        GetContainerFromSlot = function(_self, id, slot)
            if noContainerExport then error('no such export GetContainerFromSlot', 2) end

            local holder = bucket(id)
            local item = holder[slot]
            if type(item) ~= 'table' then return nil end

            local key = type(item.metadata) == 'table' and item.metadata.container or nil
            if key == nil then return nil end

            if not livingContainers[key] then
                -- Woken from nothing, which is what a container reloaded out
                -- of a database that did not answer looks like.
                livingContainers[key] = true
                stashes[key] = stashes[key] or {}
            end
            return { id = key }
        end,
        GetInventoryItems = function(_self, id)
            local out = {}
            -- A CONTAINER NOBODY HAS WOKEN IS NOT READABLE, and that is not
            -- the same answer as an empty one. ox_inventory resolves an id
            -- that is not a registered stash to nothing at all.
            if containerKeys[id] and not livingContainers[id] then return nil end
            if forgotten[id] then return out end
            for _, item in ipairs(bucket(id)) do
                out[#out + 1] = { name = item.name, count = item.count, metadata = item.metadata }
            end
            return out
        end,
        AddItem = function(_self, id, name, count, metadata, slot)
            -- THE SLOT THE DOOR ASKED FOR, recorded whether or not this
            -- fixture can honour it.
            --
            -- ox_inventory's AddItem takes a slot as its fifth argument and
            -- USES it when that slot is free -- `if not slotData then toSlot
            -- = slot end` -- falling back to the first slot it fits in
            -- otherwise. This fixture stores an inventory as a plain array,
            -- so it cannot model a hole in one; what it CAN say, exactly, is
            -- which slot each call named. That is the whole of what the door
            -- controls, and the half that was being thrown away: every add
            -- in this file went out with no slot at all, so a player's items
            -- came back renumbered and the fixture had no way to notice.
            addCalls[#addCalls + 1] = { id = id, name = name, slot = slot }
            -- A PLAYER WHO CANNOT BE GIVEN ANYTHING MORE. ox_inventory refuses
            -- by returning false when an inventory is out of slots or over
            -- weight, and this fixture had no way to say so -- which left the
            -- single most ordinary refusal at the exit, a full inventory,
            -- untested.
            if refusingAdds[id] then return false end
            -- TAKES IT AND ANSWERS NOTHING. ox_inventory has code paths that
            -- return nil where a true belongs, and oxGave deliberately reads
            -- nil as "no" -- the right rule when "no" means leave the item
            -- alone, and a DUPLICATION HAZARD anywhere "no" means try
            -- somewhere else. The fixture could refuse and it could accept;
            -- it had no way to accept quietly, which is the one shape that
            -- matters for the bag refill's second chance.
            if lyingAdds[id] then
                local silently = bucket(id)
                silently[#silently + 1] = { name = name, count = count, metadata = metadata }
                return nil
            end
            local into = bucket(id)
            into[#into + 1] = { name = name, count = count, metadata = metadata }
            return true
        end,
        RemoveItem = function(_self, id, name, count)
            local from = bucket(id)
            for index = #from, 1, -1 do
                if from[index].name == name and from[index].count == count then
                    table.remove(from, index)
                    return true
                end
            end
            return false
        end,
        -- MODELS ox_inventory's REAL SIGNATURE: ClearInventory(inv, keep),
        -- where `keep` is a list of item names that survive the clear. The
        -- stub used to drop the second argument, so a resource that passed
        -- one and a resource that did not looked identical here -- which is
        -- exactly how money could be cleared out of a player's pockets with
        -- every test still green.
        --- MODELS ox_inventory's Inventory.Clear LINE FOR LINE, INCLUDING
        --- THE BRANCH THAT DOES NOT RUN.
        ---
        --- The old stub built a lookup out of `keep` and filtered by it,
        --- which is what the function MEANS -- and it is not what the
        --- function DOES. ox_inventory's real body is:
        ---
        ---     if keep then
        ---         if type(keep) == 'string' then           ... fills updateSlots ...
        ---         elseif type(keep) == 'table'
        ---             and table.type(keep) == 'array' then ... fills updateSlots ...
        ---         end
        ---         table.wipe(inv.items); inv.items = keptItems
        ---     else                                         ... fills updateSlots ...
        ---         table.wipe(inv.items)
        ---     end
        ---     inv:syncSlotsWithClients(updateSlots, true)
        ---
        --- `table.type` is CitizenFX's and answers 'empty' for `{}`, so an
        --- EMPTY keep list matches NEITHER branch. The wipe on the next line
        --- still happens; `updateSlots` never gets filled; and the sync that
        --- follows tells the client to update nothing at all. Server empty,
        --- screen full.
        ---
        --- A stub that filters by intent cannot express that, and did not:
        --- the door shipped handing this call an empty table, every test in
        --- this file passed, and on a live server the fighters walked into
        --- the arena looking at every item they owned. WHAT THE CLIENT WAS
        --- TOLD IS NOW RECORDED, because it is the only half that was wrong.
        ClearInventory = function(_self, id, keep)
            local from = type(id) == 'number' and (inv[id] or {}) or (stashes[id] or {})

            -- `if not inv or not next(inv.items) then return end`
            if #from == 0 then return end

            local told, left = {}, {}

            if keep ~= nil then
                local keepType = type(keep)
                if keepType == 'string' then
                    for slot, item in ipairs(from) do
                        if item.name == keep then left[#left + 1] = item
                        else told[#told + 1] = slot end
                    end
                elseif keepType == 'table' and cfxTableType(keep) == 'array' then
                    for slot, item in ipairs(from) do
                        local kept = false
                        for index = 1, #keep do
                            if item.name == keep[index] then kept = true break end
                        end
                        if kept then left[#left + 1] = item
                        else told[#told + 1] = slot end
                    end
                end
                -- AND NO `else`. An empty list, or a hash, falls straight
                -- through to the wipe below with `told` still empty. This
                -- gap is the defect, reproduced rather than described.
            else
                for slot in ipairs(from) do told[#told + 1] = slot end
            end

            if type(id) == 'number' then inv[id] = left else stashes[id] = left end
            clientTold[id] = told
            -- ox_inventory's Clear returns nothing at all. oxDid reads that
            -- as success, which is the right rule for a clear; returning
            -- `true` here made this fixture kinder than the real thing.
        end,
        registerHook = function(_self, name, fn)
            if name == 'swapItems' then hook = fn end
            return true
        end,
    }

    -- A CLOCK A TEST CAN MOVE. Only `time` is replaced; everything else on
    -- `os` is the real one, so nothing that merely formats a date changes
    -- behaviour. Used by the jam-list grace, which is measured in seconds of
    -- wall time and cannot be driven any other way.
    local clockSkew = 0
    local fakeOs = setmetatable({ time = function(...) return os.time(...) + clockSkew end },
        { __index = os })

    local env = Sandbox.newArenaEnv({
        os = fakeOs,
        exports = setmetatable({ ox_inventory = ox, oxmysql = oxmysql, qbx_core = qbx.exports.qbx_core },
            { __call = function() end }),
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        -- INTERCEPTABLE, so a test can ask what the SERVER's own state was at
        -- the instant a particular message went out. Some defects are purely
        -- about ordering -- a flag cleared a moment too late is still cleared
        -- by the time anything asks afterwards -- and the only way to catch
        -- those is to look while the message is being sent.
        TriggerClientEvent = function(name, target, payload)
            if clientEventHook then clientEventHook(name, target, payload) end
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn) handlers[name] = fn end,
        -- CAPTURED, because one of them is now part of the door's promise:
        -- a jammed stash is a dead end until an admin can see it and clear
        -- it, and /arenaadmin unjam is the only thing that can.
        RegisterCommand = function(name, fn) commands[name] = fn end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- WHETHER ox_inventory IS ALREADY UP, which decides whether a convar
        -- set now can still reach it. Started unless a test says otherwise,
        -- because that is the ordinary case for everything else in here.
        GetResourceState = function(name)
            if name == 'oxmysql' then
                -- A DATABASE ONLY EXISTS WHEN A TEST ASKS FOR ONE. The whole
                -- suite runs on the SHIPPED config, which has the database
                -- off -- so the on-path was barely driven anywhere.
                return opts.database and 'started' or 'missing'
            end
            if name ~= 'ox_inventory' then return 'missing' end
            return opts.oxStarted == false and 'starting' or 'started'
        end,
        GetConvarInt = function(name, fallback)
            local value = tonumber(convars[name])
            return value or fallback
        end,
        SetConvar = function(name, value) convars[name] = tonumber(value) or value end,
        GetGameTimer = (function()
            local c = 0
            local step = tonumber(opts.tickMs) or 60000
            return function() c = c + step return c end
        end)(),
        GetPlayerName = function(src) return 'Player' .. tostring(src) end,
        -- Everybody the door has ever seen. The return sweep walks this, and
        -- letting it run for real here is the point: these are the tests
        -- that say a match cannot cost anyone anything, so a background
        -- thread that hands inventories about had better be in them.
        GetPlayers = function()
            local out = {}
            for src in pairs(inv) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            -- INSIDE THE ARENA THESE FIGHTERS ARE SUPPOSED TO BE IN, which
            -- this used to be nowhere near: it answered a point 1,450m from
            -- the Trailer Park, so every fighter in every one of these specs
            -- was standing well outside the fence they were fighting inside.
            -- Nothing read it until Config.Match.serverChecks did, and then
            -- it read as the whole roster having walked out of the round.
            --
            -- Spread three metres apart, so they are also close enough for
            -- the kill-distance ceiling -- the other thing that reads this.
            return {
                x = 2344.4 + ((tonumber(ped) or 0) % 16) * 3.0,
                y = 2565.1,
                z = 46.7,
            }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        -- The real server/dispatch.lua writes the arena flag through a state
        -- bag; this file cares only that it does not throw.
        Player = function()
            return { state = { set = function() end } }
        end,
        -- REAL, NOT NO-OPS. These answered 0 and did nothing, which is
        -- precisely what FXServer does when routing buckets are unavailable
        -- -- so server/dispatch.lua caught the move not landing, latched
        -- `provenInert`, and switched isolation off for the whole fixture.
        -- Every bucket line in the file it loads was therefore dead here.
        --
        -- Modelled properly, this is the one fixture with the real inventory
        -- AND real instancing at the same time, which is what "does a second
        -- match cost the first one anything" needs.
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, bucket) buckets[tonumber(src)] = bucket end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        GetAllVehicles = function() return {} end,
        GetAllObjects = function() return {} end,
        GetAllPeds = function() return {} end,
        GetEntityRoutingBucket = function() return 0 end,
        DeleteEntity = function() end,
        DoesEntityExist = function() return false end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
    })

    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.minPlayers = 2
    env.Config.Betting.enabled = false
    env.Config.Loadouts.ammoItems.enabled = true
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'ammo', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, lobby = env.ArenaLobby, match = env.ArenaMatch, ammo = env.ArenaAmmo }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.drop(src)
        env.source = src
        handlers['playerDropped']()
    end

    function server.stopResource() handlers['onResourceStop']('crimson_arena') end
    --- The resource STARTING, which is where the ledgers are read back.
    function server.startResource() handlers['onResourceStart']('crimson_arena') end
    function server.step(n) for _ = 1, (n or 4) do threads.step() end end

    --- Everything a player is carrying, as a sorted comparable string.
    function server.carrying(src)
        local names = {}
        for _, item in ipairs(inv[src] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- The metadata on the first item of that name a player is holding, or
    --- nil. `carrying` above compares names and counts, which is the whole
    --- of what most items are and none of what a phone is.
    function server.metaOf(src, name)
        for _, item in ipairs(inv[src] or {}) do
            if item.name == name then return item.metadata end
        end
        return nil
    end

    --- What is sitting in one player's arena stash, as a sorted string.
    --- The door's promise is about this side as much as the player's side.
    function server.stashed(src)
        local names = {}
        for _, item in ipairs(stashes['crimson_arena_CID' .. src] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- Puts an item straight into a player's pockets, the way a payout does
    --- on a server where cash is an ox_inventory item.
    function server.give(src, name, count, metadata)
        inv[src] = inv[src] or {}
        inv[src][#inv[src] + 1] = { name = name, count = count, metadata = metadata }
    end

    function server.log() return table.concat(console, '\n') end
    --- The console as separate lines, for assertions about ONE line's length.
    server.lines = console

    --- Makes one player's arena stash read EMPTY without emptying it.
    --- @param src integer
    --- @param on boolean?  -- default true
    function server.forgetStash(src, on)
        forgotten['crimson_arena_CID' .. src] = (on ~= false) or nil
    end

    --- Every statement sent to the database, as one string.
    function server.queries() return table.concat(queries, '\n') end
    --- Moves the server's clock forward, in seconds.
    function server.advanceClock(seconds) clockSkew = clockSkew + seconds end

    --- Every table named in a statement that is NOT this resource's own.
    function server.foreignTables()
        local out = {}
        for _, sql in ipairs(queries) do
            for verb, name in sql:gmatch('(%a+)%s+([%w_]+)') do
                local v = verb:upper()
                if (v == 'FROM' or v == 'INTO' or v == 'UPDATE')
                    and not name:match('^crimson_arena')
                    and name ~= 'EXISTS' and name ~= 'NOT'
                then
                    out[#out + 1] = v .. ' ' .. name
                end
            end
        end
        table.sort(out)
        return table.concat(out, ',')
    end

    --- What a convar says right now.
    function server.convar(name) return convars[name] end

    --- Makes one inventory refuse every item offered to it, the way a full
    --- one does. `false` lets it accept again.
    function server.refuseAdds(id, on)
        refusingAdds[id] = (on ~= false) or nil
    end

    --- The metadata on the first item of that name inside a bag.
    function server.bagMetaOf(key, name)
        for _, item in ipairs(stashes[key] or {}) do
            if item.name == name then return item.metadata end
        end
        return nil
    end

    --- Makes one inventory take everything offered and answer nothing, the
    --- way some ox_inventory code paths do.
    function server.lieOnAdds(id, on)
        lyingAdds[id] = (on ~= false) or nil
    end

    --- What is in ANY stash, by its real name -- including the bag holding
    --- stashes, which `bagContents` cannot see because that reads the
    --- container itself.
    function server.contentsOf(stash)
        local names = {}
        for _, item in ipairs(stashes[stash] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- HOW MANY SLOTS THE CLIENT WAS TOLD ABOUT by the last clear of one
    --- inventory, or nil if it was never cleared at all.
    ---
    --- Zero is the answer that matters, and it is not the same as nil: it
    --- means ox_inventory emptied the inventory on the server and sent the
    --- player's screen an empty update list, so their inventory UI goes on
    --- showing every item they no longer have.
    function server.clientToldAbout(id)
        local told = clientTold[id]
        return told and #told or nil
    end

    --- The slot each AddItem asked for, for one inventory and one item name,
    --- in call order, as a comma-separated string.
    ---
    --- A CALL THAT NAMED NO SLOT READS AS '-', deliberately, rather than
    --- being left out or left as a boolean. That is the whole failure mode
    --- being measured -- "the door did not say where this goes" -- so it has
    --- to be visible in the assertion message. A nil would make a slotless
    --- call and an absent call look the same; a boolean makes the failure a
    --- crash inside table.concat, which says nothing to whoever broke it.
    function server.slotsAskedFor(id, name)
        local out = {}
        for _, call in ipairs(addCalls) do
            if call.id == id and call.name == name then
                out[#out + 1] = call.slot and tostring(call.slot) or '-'
            end
        end
        return table.concat(out, ',')
    end

    --- The routing bucket a player is in right now. 0 is the open world.
    function server.bucketOf(src) return buckets[tonumber(src)] or 0 end

    --- Empties a player's pockets WITHOUT going through ox_inventory, so a
    --- test can set up an empty-handed fighter without that setup itself
    --- counting as the clear the test is about.
    function server.wipe(src)
        inv[src] = {}
    end

    --- An admin emptying a stash by hand, which is what the jam message tells
    --- them to do before clearing it.
    function server.emptyStash(stash)
        stashes[stash] = {}
    end

    --- Watches every message the server sends a client, so a test can ask what
    --- the SERVER's own state was at the instant a particular one went out.
    --- Some defects are purely about ORDER -- a flag cleared a moment too late
    --- is still cleared by the time anything asks afterwards -- and looking
    --- while the message is in flight is the only way to catch those.
    --- @param fn fun(name: string, target: any, payload: any)|nil
    function server.watchClientEvents(fn)
        clientEventHook = fn
    end

    --- Runs a console command, the way an operator at the server would.
    --- Source 0 is the console, which ArenaIsAdmin always accepts.
    function server.command(name, src, ...)
        local fn = commands[name]
        if not fn then error('no command registered called ' .. tostring(name), 2) end
        fn(src or 0, { ... }, name)
    end

    --- EVERY ITEM THIS WHOLE SERVER IS HOLDING, wherever it is: pockets,
    --- belongings stashes, bag-holding stashes, the insides of bags. As
    --- name -> count, so two of these can be compared.
    ---
    --- The point is conservation. A match must not be able to make an item
    --- appear or disappear, and the only way to say that with confidence is
    --- to count everything rather than the one inventory a test is looking at.
    function server.ledger()
        local total = {}
        local function add(list)
            for _, item in ipairs(list or {}) do
                if type(item) == 'table' and type(item.name) == 'string' then
                    total[item.name] = (total[item.name] or 0) + (tonumber(item.count) or 0)
                end
            end
        end
        for _, list in pairs(inv) do add(list) end
        for _, list in pairs(stashes) do add(list) end
        return total
    end

    --- Gives a player a CONTAINER item -- a police bag -- with things
    --- already in it. ox_inventory keeps a bag's contents in a separate
    --- inventory keyed by `metadata.container`; the item itself holds only
    --- the key.
    function server.giveBag(src, name, key, contents)
        containerKeys[key] = true
        livingContainers[key] = true
        inv[src] = inv[src] or {}
        inv[src][#inv[src] + 1] = { name = name, count = 1, metadata = { container = key } }
        stashes[key] = {}
        for _, entry in ipairs(contents or {}) do
            -- METADATA COMES WITH IT. An item whose identity IS its metadata
            -- -- a phone with a number, a licence with a name -- is the case
            -- a count of names cannot see, and a bag is exactly where people
            -- keep those.
            stashes[key][#stashes[key] + 1] = { name = entry[1], count = entry[2], metadata = entry[3] }
        end
    end

    --- What is in one bag right now.
    function server.bagContents(key)
        local names = {}
        for _, item in ipairs(stashes[key] or {}) do
            names[#names + 1] = item.name .. 'x' .. tostring(item.count)
        end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- Whether a player is carrying the bag with that key at all.
    function server.hasBag(src, key)
        for _, item in ipairs(inv[src] or {}) do
            if type(item.metadata) == 'table' and item.metadata.container == key then return true end
        end
        return false
    end

    --- ox_inventory's idle purge taking a container out of memory, and the
    --- database not giving it back. THIS IS THE DEFECT: five minutes of a
    --- round with nobody holding the bag open is all it takes.
    function server.purgeContainer(key)
        livingContainers[key] = nil
        stashes[key] = {}
    end

    --- An ox_inventory old enough to have no GetContainerFromSlot.
    function server.oldOxBuild() noContainerExport = true end

    --- Puts an item straight into a stash, the way an earlier run of this
    --- resource left one behind.
    function server.stashItem(stash, name, count)
        stashes[stash] = stashes[stash] or {}
        stashes[stash][#stashes[stash] + 1] = { name = name, count = count }
    end

    --- Puts an item into a stash AT A GIVEN POSITION, pushing everything at
    --- or after it down a slot. That is what a stash reloaded from an older
    --- database row looks like: the rows that come back are not necessarily
    --- after the ones already there.
    function server.stashItemAt(stash, index, name, count)
        stashes[stash] = stashes[stash] or {}
        table.insert(stashes[stash], index, { name = name, count = count })
    end

    --- Changes one metadata key on an item sitting in a stash, the way a
    --- third-party script re-minting a bag's id does.
    ---
    --- THE CASE THIS EXISTS FOR, straight off the operator's server: two
    --- different characters' bags came back carrying the SAME creation
    --- second in their ids, which means something on that box re-mints them.
    --- A re-minted id points the bag at a new and empty stash while
    --- everything that was in it stays filed under the old name.
    function server.remint(stash, name, key, value)
        for _, item in ipairs(stashes[stash] or {}) do
            if item.name == name then
                item.metadata = item.metadata or {}
                item.metadata[key] = value
                return true
            end
        end
        error('no ' .. tostring(name) .. ' in stash ' .. tostring(stash), 2)
    end

    --- Hands a server id to a different character, the way FiveM does when a
    --- player disconnects and the next one to connect inherits their slot.
    --- @param src integer
    --- @param citizenid string
    function server.reseat(src, citizenid)
        qbx.players[src] = {
            citizenid = citizenid,
            name = 'Newcomer' .. tostring(src),
            money = { cash = 50000, bank = 0 },
        }
        inv[src] = {}
    end

    --- Asks the swapItems hook whether one move by `src` is allowed.
    ---
    --- `source` IS THE ACTOR, and the hook reads nothing else to find them --
    --- leave it out and the hook returns true before asking any question at
    --- all, which is a green test that has driven nothing.
    --- @return boolean
    function server.mayMove(src, from, to)
        if hook == nil then error('the resource registered no swapItems hook', 2) end
        return hook({ source = src, fromInventory = from, toInventory = to, count = 1 }) ~= false
    end

    return server
end

--- What OWN looks like once server.carrying has formatted it.
local INTACT = 'ammo-rifle-apx40,burgerx3,phonex1'

--- Opens a match with everyone in it and starts it, leaving the round live
--- with every fighter stripped and issued.
--- @param ids integer[]
--- @return table server
--- @return string matchId
local function liveMatch(ids, extra, mutate, opts)
    local server = newServer(ids, mutate, extra, opts)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    for index = 2, #ids do
        server.fire('joinMatch', ids[index], { matchId = match.id })
    end
    for _, src in ipairs(ids) do
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)

    return server, match.id
end

-- ========================================================================
-- The door is actually shut
-- ========================================================================

t.test('a lobby does not touch anybody: only entering the arena does', function()
    local server = newServer({ 1, 2 })
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })

    t.equals(server.carrying(1), INTACT, 'sitting in a menu is not being in a fight')
    t.equals(server.carrying(2), INTACT)
end)

t.test('walking into the arena empties their pockets', function()
    local server = liveMatch({ 1, 2 })
    t.isFalse(server.carrying(1) == INTACT, 'they are not still carrying their own things')
    t.isTrue(isHolding(server.ammo, 1), 'and the arena owes them their kit back')
end)

-- ========================================================================
-- Every way out
-- ========================================================================

t.test('a match that finishes normally hands everything back', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
    t.isFalse(isHolding(server.ammo, 1))
end)

t.test('and it hands back THEIR phone, not a phone', function()
    -- WHAT A COUNT CANNOT SEE. Every assertion above compares names and
    -- counts -- `phonex1` before, `phonex1` after -- and that is the whole of
    -- what a burger is. It is none of what a phone is: the number, the
    -- contacts and the messages live in the item's METADATA, and an item that
    -- comes back without it is a new phone belonging to nobody.
    --
    -- To the player those two outcomes are not similar, they are opposite,
    -- and they read identically in every other test in this file. The fixture
    -- dropped metadata when it seeded a player, so the case could not be
    -- built here at all.
    local phone = { number = '555-0134', contacts = 12 }
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'phone-2', count = 1, metadata = phone } })

    t.isNil(server.metaOf(1, 'phone-2'), 'they carried it INTO the arena -- the door did not take it')

    server.match.End(matchId, 'match.ended')

    local back = server.metaOf(1, 'phone-2')
    t.isNotNil(back, 'the phone did not come back at all')
    t.equals(back.number, phone.number,
        'A PHONE CAME BACK, BUT NOT THEIRS -- the number it is known by did not survive the round')
    t.equals(back.contacts, phone.contacts, 'and what was on it did not either')
end)

-- ========================================================================
-- MONEY GOES IN LIKE EVERYTHING ELSE, AND THE PAYOUT STILL SURVIVES
--
-- TWO QUESTIONS, AND FOR A WHILE ONE SETTING ANSWERED BOTH -- wrongly, in
-- opposite directions.
--
--   ON THE WAY IN. Cash was left in a player's pockets on the reasoning that
--   it "cannot be spent in an arena and cannot be looted off a body here".
--   The second half was never true: ox_inventory drops a dead player's
--   inventory on the floor whatever this resource thinks. So a fighter walked
--   into a live round carrying every note they own and dropped the lot the
--   first time somebody shot them. It goes in the stash now, with everything
--   else -- `neverStash` ships EMPTY.
--
--   ON THE WAY OUT. The exit clears whatever a player is carrying, on the
--   reasoning that at that moment everything in their pockets belongs to the
--   arena. That stops being true before the clear runs: server/match.lua
--   settles the pot and the side-bets and only THEN sends everybody home, so
--   a winner's payout is credited into the inventory the exit is about to
--   wipe. Bank was untouched throughout, because bank is player data rather
--   than an item -- which is what made it look like cash bets specifically do
--   not pay out. `neverDestroy` is the list that keeps it, and cash stays on
--   it.
-- ========================================================================

t.test('THE REPORT: cash goes into the stash with everything else', function()
    -- IN THE OPERATOR'S WORDS: "it is not taking money out of the inventory
    -- when you start the match, so in the match I still have all my cash I
    -- had before joining -- it takes the money out for the betting but not
    -- the rest of my cash".
    --
    -- Which was true, and was the setting doing exactly what it said. The
    -- reasoning behind it -- cash "cannot be looted off a body here" -- was
    -- never true: ox_inventory drops a dead player's inventory on the floor
    -- whatever this resource thinks, so a fighter was carrying their whole
    -- wallet into a live round and dropping it the first time they died.
    local server = liveMatch({ 1, 2 }, { { name = 'money', count = 5000 } })
    local carrying = server.carrying(1)

    -- PROOF THE DOOR ACTUALLY RAN, first. Without this the test passes on a
    -- build where the door never opened, which is the one state where the
    -- pockets being empty means nothing at all.
    t.isNil(carrying:find('phonex1', 1, true),
        'the door did not run, so this test proves nothing: ' .. carrying)

    t.isTrue(server.stashed(1):find('money', 1, true) ~= nil,
        'the door left cash in the arena rather than putting it away: ' .. server.stashed(1))
    t.isNil(carrying:find('money', 1, true),
        'and it left a copy in their pockets as well, which is worse: ' .. carrying)
end)

t.test('and it comes back out again at the exit', function()
    -- The other half, and the half that matters: putting it away is only
    -- safe if it comes back. INTACT is the whole inventory these fixtures
    -- walk in with.
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'money', count = 5000 } })
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx5000', 1, true) ~= nil,
        'THE ARENA KEPT THEIR CASH -- ' .. carrying)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'and their own belongings did not come back either: ' .. carrying)
end)

t.test('and a payout is protected even when config.lua has never heard of the key', function()
    -- THE UPGRADE CASE, and it is the normal one. `neverDestroy` is new, so
    -- an operator who keeps their own config.lua across the upgrade has the
    -- inventory block WITHOUT it -- and that is exactly the person who
    -- reported the payout vanishing in the first place.
    --
    -- The default therefore has to be the safe list, not an empty one:
    -- config.lua overrides it, it does not enable it.
    local server, matchId = liveMatch({ 1, 2 }, nil,
        function(config) config.Loadouts.inventory.neverDestroy = nil end)

    -- The payout, exactly where the real one lands: after the round is
    -- decided, before the player is sent home.
    server.give(1, 'money', 7500)
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx7500', 1, true) ~= nil,
        'with no neverDestroy key the exit clear destroyed the payout: ' .. carrying)
end)

t.test('and money credited DURING a round survives the way out', function()
    -- The payout, exactly where the real one lands: after the round is
    -- decided, before the player is sent home.
    local server, matchId = liveMatch({ 1, 2 })

    server.give(1, 'money', 7500)
    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('moneyx7500', 1, true) ~= nil,
        'THE PAYOUT WAS DESTROYED BY THE EXIT CLEAR -- ' .. carrying)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'and their own belongings did not come back either: ' .. carrying)
end)

t.test('leaving mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.fire('leaveMatch', 2)
    t.equals(server.carrying(2), INTACT)
end)

t.test('disconnecting mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.drop(2)
    t.equals(server.carrying(2), INTACT)
end)

t.test('an admin stopping the match hands everything back', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.Abort(matchId, 'match.aborted')

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
end)

t.test('destroying the match outright hands everything back', function()
    -- THE PATH THAT WAS BROKEN. Destroy is the last teardown and the one
    -- nothing else covers: it cleared the dispatch flag and the routing bucket
    -- and never reclaimed, so a player torn down here kept the arena kit while
    -- their real belongings sat in a stash.
    local server, matchId = liveMatch({ 1, 2 })
    server.lobby.Destroy(matchId, 'notify.match_closed')

    t.equals(server.carrying(1), INTACT, 'Destroy owes them their kit like every other exit')
    t.equals(server.carrying(2), INTACT)
end)

t.test('the resource stopping mid-round hands everything back', function()
    local server = liveMatch({ 1, 2 })
    server.stopResource()

    t.equals(server.carrying(1), INTACT)
    t.equals(server.carrying(2), INTACT)
end)

-- ========================================================================
-- Nothing from the match comes with them
-- ========================================================================

-- ========================================================================
-- WITH THE DOOR OFF
--
-- stripOnEntry = false is the setting where a player keeps their own
-- inventory and is simply handed the arena's kit on top of it. Nothing is
-- stashed, so nothing is restored -- which means the ONLY way the arena's
-- weapons come back is being removed by name on the way out, from the
-- record of what was issued. Every guarantee above is carried by restore();
-- none of them reaches this path.
-- ========================================================================

--- Switches the door off.
local function doorOff(config)
    config.Loadouts.inventory.stripOnEntry = false
end

--- The first shipped weapon that takes ammunition, so the arena has
--- something real to hand out and something real to take back.
local function firstArmedWeapon(config)
    for _, weapon in ipairs(config.Loadouts.weapons or {}) do
        if weapon.enabled ~= false and type(weapon.ammo) == 'table' then return weapon end
    end
    return nil
end

--- A live round with the door OFF and everybody actually carrying a weapon
--- the arena issued. liveMatch above readies people straight away, which
--- leaves them on an empty loadout -- and an empty loadout would make every
--- assertion below pass for the wrong reason.
--- @param ids integer[]
--- @return table server
--- @return string matchId
local function armedDoorOffMatch(ids)
    local server = newServer(ids, doorOff)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })

    local match = server.lobby.All()[1]
    t.isNotNil(match, 'the host could not open a lobby')

    local weapon = firstArmedWeapon(server.env.Config)
    t.isNotNil(weapon, 'no shipped weapon takes ammunition, so this proves nothing')

    for index = 2, #ids do server.fire('joinMatch', ids[index], { matchId = match.id }) end
    for _, src in ipairs(ids) do
        server.fire('setLoadout', src, { weapons = { { key = weapon.key, ammo = 60 } }, armor = 0 })
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)

    return server, match.id
end

t.test('with the door off a fighter keeps their own things and gains the arena kit', function()
    -- The premise, asserted so the tests below cannot pass by the arena
    -- quietly having issued nothing.
    local server = armedDoorOffMatch({ 1, 2 })

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'the door was shut after all -- their own things were taken')
    t.isTrue(carrying ~= INTACT,
        ('the arena issued nothing, so there is nothing to take back: %s'):format(carrying))
end)

t.test('DEFECT: and a finished match takes the arena kit back off them', function()
    -- ArenaAmmo.Clear drops the match's rows from `issuedWeapons` and
    -- `issuedAmmo`, and those rows ARE the list of names the exit removes.
    -- End called it BEFORE sending anybody out, so by the time the exit ran
    -- there was nothing left to remove -- and every fighter walked away
    -- still holding the arena's weapon and its ammunition. A free gun per
    -- round, per player, on a resource whose stated promise is that a match
    -- cannot cost or pay anyone anything.
    --
    -- Abort has always had the two in the right order. End did not.
    local server, matchId = armedDoorOffMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(4)

    t.equals(server.carrying(1), INTACT,
        ('player 1 left a finished match carrying %s'):format(server.carrying(1)))
    t.equals(server.carrying(2), INTACT,
        ('player 2 left a finished match carrying %s'):format(server.carrying(2)))
end)

t.test('and two rounds in a row do not stack two kits on them', function()
    -- The observable form of the same defect, and the one a player would
    -- notice: it compounds.
    local server, first = armedDoorOffMatch({ 1, 2 })
    server.match.End(first, 'match.ended')
    server.step(4)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = second.id })
    local weapon = firstArmedWeapon(server.env.Config)
    for _, src in ipairs({ 1, 2 }) do
        server.fire('setLoadout', src, { weapons = { { key = weapon.key, ammo = 60 } }, armor = 0 })
        server.fire('setReady', src, { ready = true })
    end
    server.step(6)
    server.match.End(second.id, 'match.ended')
    server.step(4)

    t.equals(server.carrying(1), INTACT,
        ('after two rounds player 1 is carrying %s'):format(server.carrying(1)))
end)

t.test('and the match stops being owed anything once everyone is out', function()
    -- The bookkeeping half. Clearing the records is right -- it just has to
    -- happen after the reclaims that read them, not before.
    local server, matchId = armedDoorOffMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(4)

    -- ASSERTED ON THE KIT RECORD AND NOTHING ELSE, because the other probe
    -- is gone. ArenaAmmo.OnLoan summed a second scalar ledger that was never
    -- decremented when the arena took anything back -- it reported
    -- cumulative-issued, not outstanding -- and 2fec9fe deleted the function
    -- and the ledger together.
    t.isFalse(isHolding(server.ammo, 1), 'the arena still thinks it owes player 1 a kit')
end)

t.test('nothing looted inside the arena leaves with them', function()
    local server, matchId = liveMatch({ 1, 2 })

    -- They kill somebody and take everything the body was carrying, including
    -- an item they own plenty of themselves.
    server.env.exports.ox_inventory:AddItem(2, 'ammo-rifle-ap', 500)
    server.env.exports.ox_inventory:AddItem(2, 'gold-bar', 9)

    server.match.End(matchId, 'match.ended')
    t.equals(server.carrying(2), INTACT, 'exactly what they walked in with, and only that')
end)

t.test('an item they own plenty of is returned at the number they had', function()
    -- ammo-rifle-ap is in OWN *and* is an arena round. Returning "what we
    -- issued, minus what came back" would get this one wrong in both
    -- directions; returning the stash gets it right by construction.
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')

    t.isTrue(server.carrying(1):find('ammo%-rifle%-apx40') ~= nil,
        'forty, not forty plus whatever the arena issued, and not zero')
end)

t.test('two rounds in a row leave them exactly as they started', function()
    local server = newServer({ 1, 2 })
    for _ = 1, 2 do
        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)
        server.match.End(match.id, 'match.ended')
    end

    t.equals(server.carrying(1), INTACT, 'nothing accumulates across matches')
    t.equals(server.carrying(2), INTACT)
end)

print('doorguarantee_spec')
-- ========================================================================
-- A STASH THAT READS EMPTY IS NOT A STASH THAT WAS EMPTY
--
-- ox_inventory answers the same empty list for both, and the second is what
-- a forgotten or re-registered stash looks like: a resource restart, a
-- database hiccup, a row that came back under a different name. So an exit
-- that trusted the answer reported a clean return of nothing, dropped the
-- record, cleared the debt and left the player with empty pockets while every
-- log in the file said the exit had gone perfectly.
--
-- The exit learned to tell them apart by counting what went IN. These are
-- about everything that happens AFTER it does.
-- ========================================================================

t.test('THE BUG: the retry undid the exit\'s guard about thirty seconds later', function()
    -- restore() refuses to call an empty read a clean return, keeps the
    -- record, writes the debt and tells the player their kit is safe and
    -- still being chased. ArenaAmmo.ReturnLeftovers is the only thing that
    -- chases it -- and it had no such check, so the very next pass of the
    -- sweep read the same nothing, called it settled, and deleted every
    -- record the retry works from. The promise lasted one sweep interval.
    local server, matchId = liveMatch({ 1, 2 })
    t.isTrue(isHolding(server.ammo, 1), 'nothing was stashed, so this proves nothing')

    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    t.equals(server.ammo.Owed(), 1, 'the exit did not record the debt it could not settle')

    -- The sweep, over and over, exactly as the retry thread runs it.
    for _ = 1, 5 do server.ammo.SweepReturns() end

    t.equals(server.ammo.Owed(), 1,
        'the retry declared the debt settled off a read that returned nothing')
    t.isTrue(isHolding(server.ammo, 1),
        'the retry dropped the record, so nothing is left pointing at the stash')
end)

t.test('and the moment the stash can be read again, everything comes back', function()
    -- The point of keeping the debt: the stash is a REAL one and its contents
    -- were never in doubt. Nothing is lost, it is only unreachable -- and the
    -- retry has to still be trying when it stops being.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    for _ = 1, 3 do server.ammo.SweepReturns() end

    server.forgetStash(1, false)
    server.ammo.SweepReturns()

    t.equals(server.carrying(1), INTACT, 'their own things did not come back')
    t.equals(server.ammo.Owed(), 0, 'the debt was not settled once it actually could be')
    t.isFalse(isHolding(server.ammo, 1), 'and the record was not dropped afterwards')
end)

t.test('and it is still THEIR phone when it comes back late', function()
    -- THE CLOSEST THING THIS SANDBOX HAS TO THE REPORTED SYMPTOM. A phone
    -- that returns immediately is one thing; the case worth checking is the
    -- one where the hand-back could not happen at the exit and the kit comes
    -- back on a later sweep instead. That is a player who finished a match,
    -- found nothing in their pockets, and got their things minutes later --
    -- and if the identity is lost on that path, what arrives is a stranger's
    -- phone with their name on the label.
    --
    -- It is the same handBack either way, so this ought to hold. Ought is not
    -- the same as does, and the test above only ever compared counts.
    local phone = { number = '555-0134', contacts = 12 }
    local server, matchId = liveMatch({ 1, 2 }, { { name = 'phone-2', count = 1, metadata = phone } })

    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    for _ = 1, 3 do server.ammo.SweepReturns() end
    t.isNil(server.metaOf(1, 'phone-2'), 'it came back while the stash was unreadable, so this proves nothing')

    server.forgetStash(1, false)
    server.ammo.SweepReturns()

    local back = server.metaOf(1, 'phone-2')
    t.isNotNil(back, 'the phone never came back at all on the late path')
    t.equals(back.number, phone.number,
        'THE LATE RETURN HANDED BACK A PHONE THAT IS NOT THEIRS -- the number did not survive the wait')
    t.equals(back.contacts, phone.contacts, 'and what was on it did not either')
end)

t.test('and a stash that really IS empty still settles cleanly', function()
    -- The guard must not turn every ordinary exit into a permanent debt. A
    -- player who walked in owning nothing stashes nothing, so there is no
    -- count to disagree with the empty read and nothing to keep chasing.
    local server = newServer({ 1, 2 })
    server.env.Config.Loadouts.inventory.stripOnEntry = true
    -- Emptied before they ever go near the door.
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })

    for _ = 1, 4 do server.ammo.SweepReturns() end
    t.equals(server.ammo.Owed(), 0, 'somebody who owns nothing was recorded as owed something')
end)

t.test('THE BUG: re-entering with empty pockets erased the debt outright', function()
    -- The record's count is the one fact that can tell the two empties apart,
    -- and ArenaAmmo.Issue wrote the NEW entry's count straight over it. A
    -- player whose exit failed walks back in carrying nothing -- because the
    -- failed exit is exactly why they have nothing -- so the count went to
    -- zero, the guard was disarmed for the one player it was written for, and
    -- the next exit read empty, called it clean, and forgot the lot.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    t.equals(server.ammo.Owed(), 1, 'the first exit did not leave a debt to erase')

    -- STRAIGHT BACK IN, with the pockets the failed exit left them: empty.
    -- The stash can be read again by now, but it does not matter -- what is
    -- being asserted is that the second round cannot erase the first round's
    -- debt on its way past.
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second = server.lobby.All()[1]
    t.isNotNil(second, 'the second lobby never opened')
    server.fire('joinMatch', 2, { matchId = second.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(second.id, 'match.ended')

    t.equals(server.ammo.Owed(), 1,
        'a second round erased a debt from the first -- their belongings are in a '
        .. 'real stash with nothing in this resource left pointing at it')
end)

-- ========================================================================
-- A SERVER ID IS NOT A PERSON
--
-- `stashed` is keyed by server id, and a record is KEPT on purpose when an
-- exit could not finish -- so it outlives its owner's disconnect, and FiveM
-- hands that id to whoever connects next.
-- ========================================================================

t.test('THE BUG: a stranded record froze the NEXT player on that id out of every stash', function()
    -- The swapItems guard reads that table to decide who is "in the arena".
    -- Read raw, the newcomer was refused every inventory move they made
    -- anywhere on the map -- their own house stash, a glovebox, a shop, an
    -- item handed to a friend -- with the arena's own "you fight with what
    -- you were issued" line explaining it, and nothing able to clear it: the
    -- sweep that would have is gated on the same table.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    t.isTrue(isHolding(server.ammo, 1), 'the record was not kept, so there is nothing stranded')

    server.drop(1)
    server.reseat(1, 'CID_NEWCOMER')

    t.isTrue(server.mayMove(1, 1, 'house_stash_newcomer'),
        'the newcomer cannot put anything into their own stash')
    t.isTrue(server.mayMove(1, 'house_stash_newcomer', 1),
        'the newcomer cannot take anything out of their own stash')
end)

t.test('and the sweep will still look at that newcomer', function()
    -- worthTrying reads the same table for the same reason, so the one player
    -- who most needed a look -- the new arrival inheriting a stranded id --
    -- was the one player it would never take.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')
    server.drop(1)
    server.reseat(1, 'CID_NEWCOMER')

    -- Something of theirs really is in their own arena stash, from an earlier
    -- life this run knows nothing about.
    server.stashItem('crimson_arena_CID_NEWCOMER', 'phone', 1)
    server.ammo.SweepReturns()

    t.isTrue(server.carrying(1):find('phone', 1, true) ~= nil,
        'the sweep skipped the newcomer because somebody else\'s record sat on their id')
end)

t.test('THE LOCKOUT: a stranded record must not follow them round the map', function()
    -- The worst thing this session nearly shipped, and it was a regression
    -- inside a fix.
    --
    -- A record is KEPT when an exit cannot empty the stash, and the read-empty
    -- guard keeps the debt written -- so that record is never settled and
    -- never dropped. The swapItems guard read it as "this player is in the
    -- arena", so from that moment every inventory move they made ANYWHERE was
    -- refused: their own house stash, a glovebox, a shop, handing a friend an
    -- item. For the rest of the session, through a reconnect, standing
    -- nowhere near an arena, with the arena's own line explaining it.
    --
    -- Their belongings being stuck is the problem this player already has.
    -- Being unable to touch anything they own for the rest of the night is a
    -- second one nobody asked for.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    t.isTrue(isHolding(server.ammo, 1), 'the record was not kept, so this proves nothing')
    t.equals(server.ammo.Owed(), 1, 'and the debt was not written')

    t.isTrue(server.mayMove(1, 1, 'house_stash_theirs'),
        'a player whose arena stash could not be read cannot put anything in their own')
    t.isTrue(server.mayMove(1, 'house_stash_theirs', 1),
        'nor take anything out of it')
    t.isTrue(server.mayMove(1, 1, 'a_friend'),
        'nor hand a friend an item, anywhere on the map')
end)

t.test('and the sweep still comes back for them', function()
    -- The debt is what brings it back, and it must survive the narrowing
    -- above: freeing the player must not mean forgetting the stash.
    local server, matchId = liveMatch({ 1, 2 })
    server.forgetStash(1)
    server.match.End(matchId, 'match.ended')

    for _ = 1, 3 do server.ammo.SweepReturns() end
    t.equals(server.ammo.Owed(), 1, 'the debt was dropped along with the lockout')

    server.forgetStash(1, false)
    server.ammo.SweepReturns()
    t.equals(server.carrying(1), INTACT, 'and their things never came back')
end)

t.test('and a fighter who is genuinely mid-round is still refused', function()
    -- The narrowing must not switch the guard off. The record belongs to the
    -- person sitting on that id, so it still speaks for them.
    local server = liveMatch({ 1, 2 })
    t.isFalse(server.mayMove(1, 1, 'some_other_stash'),
        'a fighter can empty the arena kit into a stash mid-round')
    t.isFalse(server.mayMove(1, 'a_corpse', 1),
        'a fighter can loot into their own pockets mid-round')
end)

-- ======================================================================
-- NOT TAKING SOMETHING IS NOT PERMISSION TO DESTROY IT
-- ======================================================================
--
-- The door has two lists and they were independent:
--
--   neverStash    "leave this in their pockets on the way in"
--   neverDestroy  "the exit's clear must not wipe this"
--
-- Which left a hole exactly the size of the difference between them. An item
-- on the first list and not the second was carried, unprotected, through the
-- whole round -- and then met the wholesale clear at the exit, which keeps
-- only what the SECOND list names. The arena destroyed the one thing it had
-- promised not to touch.
--
-- The only warning was a clause in a config comment. An operator naming an
-- item they did not want the arena taking had to know to name it again, in a
-- different list, under a different heading, to stop the arena destroying it
-- instead.

t.test('THE REPORT: an item the door was told to leave alone was wiped at the exit',
    function()
        local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
            -- Named on one list and not the other, which is the whole of it.
            config.Loadouts.inventory.neverStash = { 'phone' }
            config.Loadouts.inventory.neverDestroy = { 'money' }
        end)

        -- It never went to the stash, which is what the operator asked for.
        t.isNil(server.stashed(1):find('phone', 1, true),
            'the door stashed an item it was told to leave in their pockets: '
                .. server.stashed(1))

        server.match.End(matchId, 'match.ended')

        local carrying = server.carrying(1)
        t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
            'THE ARENA DESTROYED IT. It was never stashed, so there was nothing to hand '
                .. 'back -- and the exit clear wiped it where it sat: ' .. carrying)
    end)

t.test('and the clear still ran, in the same round, over the same fighter', function()
    -- THE PAIR THE FIX HAS TO SATISFY AT ONCE, asserted in one fixture
    -- rather than two. Its first version checked only that an UNNAMED item
    -- survived a round -- which is what happens if the exit stops clearing
    -- anything at all, so the control passed on exactly the fix it was
    -- written to catch.
    --
    -- Named and unnamed, side by side: the phone is protected, and something
    -- the arena handed over in the same round is not.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'phone' }
    end)

    server.give(1, 'ammo-9', 120)

    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isTrue(carrying:find('phonex1', 1, true) ~= nil,
        'the protected item did not survive: ' .. carrying)
    t.isNil(carrying:find('ammo-9', 1, true),
        'and the clear did not run at all, so the protection above means nothing: ' .. carrying)
end)

t.test('and the arena kit is still destroyed, which is what the clear is for', function()
    -- The other control. `neverStash` growing must not become a way to keep
    -- the weapons the arena issued -- those are the whole reason the exit
    -- clears anything.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'phone' }
    end)

    -- Something the ARENA gave them, arriving mid-round the way a kill
    -- payment does.
    server.give(1, 'ammo-9', 250)

    server.match.End(matchId, 'match.ended')

    t.isNil(server.carrying(1):find('ammo-9', 1, true),
        'the exit let a fighter walk out with the arena\'s own ammunition: '
            .. server.carrying(1))
end)

t.test('AND `neverStash` CANNOT BE USED TO WALK OUT WITH THE KIT', function()
    -- The hole the rule above opened, and the reason it is not a plain
    -- merge. `neverStash` protects a name from the exit's clear -- so
    -- naming something the ARENA issues would keep it: `armour`, `ammo-9`,
    -- a weapon. And the exit would still report a clean wipe, so the arena
    -- forgets it ever issued one. No debt, no sweep, no retry. Two hundred
    -- rounds a round, for ever, out of one line of config.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'armour', 'bandage' }
    end)

    -- Issued mid-round, the way a kill payment or a respawn refresh arrives.
    server.give(1, 'armour', 1)
    server.give(1, 'bandage', 2)

    server.match.End(matchId, 'match.ended')

    local carrying = server.carrying(1)
    t.isNil(carrying:find('armour', 1, true),
        'a fighter walked out wearing the arena\'s own plate: ' .. carrying)
    t.isNil(carrying:find('bandage', 1, true),
        'and carrying its bandages: ' .. carrying)
end)

t.test('and the same names still reach the stash, so nobody loses their own', function()
    -- The kindest of the three things that could happen to an operator's
    -- mistake. Refusing only the exit half would leave a player's OWN plate
    -- in their pockets for the round and then destroy it at the door -- a
    -- worse outcome than the setting they were reaching for. The name is
    -- ignored on both halves instead, so the item takes the ordinary path.
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.neverStash = { 'armour' }
    end, { { name = 'armour', count = 3 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    for _, src in ipairs({ 1, 2 }) do server.fire('setReady', src, { ready = true }) end
    server.match.Start(match.id)
    server.step()

    t.isTrue(server.stashed(1):find('armour', 1, true) ~= nil,
        'the fighter\'s own plate was left in their pockets to be destroyed: '
            .. server.stashed(1))

    server.match.End(match.id, 'match.ended')

    t.isTrue(server.carrying(1):find('armourx3', 1, true) ~= nil,
        'and it did not come back: ' .. server.carrying(1))
end)

-- ========================================================================
-- MORE IN THE STASH THAN THE DOOR PUT IN IT
--
-- The exit handed over WHATEVER was in the belongings stash. Nothing asked
-- whether the stash was still holding what the door left there, and things
-- get into it: ox_inventory throws an idle inventory out of memory after
-- `inventory:cleartime` (five minutes by default) and reloads it from the
-- database on the next touch, so any round longer than that round-trips
-- these belongings through a row that may not have had the last write. It is
-- also a real stash with a predictable name that an admin tool or another
-- resource can write to.
--
-- Reported off a live server as a match "duplicating the items they had and
-- didn't have", and that is exactly what it produced here.
-- ========================================================================

t.test('DEFECT: rows that appear in the stash mid-round are NOT handed over', function()
    local server, matchId = liveMatch({ 1, 2 })

    -- An older snapshot of this same stash coming back, which is what a
    -- reload from a stale row looks like -- two of what they own and one
    -- thing they never did.
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.stashItem('crimson_arena_CID1', 'burger', 3)
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT,
        'THEY WALKED OUT WITH TWO OF EVERYTHING AND A LOCKPICK THEY NEVER OWNED')
    t.equals(server.stashed(1), 'burgerx3,lockpickx2,phonex1',
        'the surplus was not left where an admin can settle it')
    t.contains(server.log(), 'appeared while',
        'it handed back only what it took and said nothing about the rest')
end)

-- The assertion above is also what holds the CHOICE of refused rows: the
-- three stale rows land after the player's own, and a ceiling that simply
-- kept the first `allowed` in slot order refused the player's rifle ammo and
-- handed them a lockpick instead. Measured by inverting the ordering alone:
-- `burgerx3,lockpickx2,phonex1`.

t.test('and the sweep does not come back and hand the surplus over a tick later', function()
    -- ArenaAmmo.ReturnLeftovers is UNCAPPED on purpose -- after a restart
    -- nothing knows what went into a stash, and a ceiling of zero there
    -- would refuse a player their whole kit. So refusing the rows and
    -- leaving them lying there was not enough on its own: the sweep
    -- collected the exact rows the exit had just refused. The refusal shuts
    -- the stash, which is what makes it stick.
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')

    for _ = 1, 6 do server.step(8) end

    t.equals(server.carrying(1), INTACT, 'the sweep handed over what the exit refused')
    t.equals(server.stashed(1), 'phonex1', 'and the surplus is still there to be settled')
end)

t.test('CONTROL: the leftovers of an earlier exit that could not finish still come back', function()
    -- THE REGRESSION THIS CEILING COULD CAUSE, and it is the unforgivable
    -- one. A stash can already have things in it when the door shuts -- an
    -- exit that could not finish leaves them there on purpose, and they are
    -- the player's. stow() counts them, so they are INSIDE the ceiling.
    -- Without that this test fails and somebody loses their property.
    local server = newServer({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), 'ammo-rifle-apx40,burgerx3,lockpickx2,phonex1',
        'a player lost belongings that were legitimately waiting in their stash')
    t.equals(server.stashed(1), '', 'and the stash was not emptied')
end)

t.test('CONTROL: an ordinary round is untouched by any of this', function()
    -- Without this the three above pass on a build that simply refuses
    -- everything, which is worse than the defect.
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT)
    t.equals(server.stashed(1), '')
    t.isNil(server.log():find('appeared while', 1, true),
        'it refused something on a round where nothing appeared')
end)

t.test('CONTROL: a stash that reads EMPTY the instant after it is filled is not a ceiling of zero', function()
    -- THE TRAP THIS FILE IS BUILT AROUND, aimed at the new ceiling. A stash
    -- ox_inventory has not loaded answers an EMPTY list rather than an
    -- error, and reading the ceiling off the stash alone would therefore set
    -- it to zero for exactly that case -- and a ceiling of zero refuses the
    -- player their entire kit at the exit. The count is kept as the floor
    -- for this reason and no other.
    local server = newServer({ 1, 2 })
    server.forgetStash(1)          -- it fills, and every read of it says empty

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.forgetStash(1, false)   -- ox loads it again, and it was full all along

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT, 'A PLAYER WAS REFUSED THEIR OWN BELONGINGS')
    t.isNil(server.log():find('appeared while', 1, true),
        'it called their own kit a surplus and shut the stash on them')
end)

-- ========================================================================
-- THE POLICE BAG, WHICH CAME BACK EMPTY
--
-- A container item does not carry its contents in its metadata. ox_inventory
-- keeps them in a SEPARATE inventory keyed by metadata.container, and the bag
-- holds nothing but that key. So stashing the bag stashes a REFERENCE -- and
-- that inventory is never open and never a player, which puts it in the same
-- five-minute idle purge as everything else. Written out, dropped, and read
-- back from the database on the next touch; if that does not come back, the
-- bag returns with nothing in it.
--
-- The arena now holds the contents itself for the length of the round.
-- ========================================================================

local BAG = 'police_bag'
local KEY = 'bagkey123'

--- A round fought by somebody carrying a packed bag.
local function roundWithBag(contents)
    local server = newServer({ 1, 2 })
    server.giveBag(1, BAG, KEY, contents or { { 'radio', 1 }, { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    return server, match.id
end

t.test('DEFECT: a bag whose container is purged mid-round still comes back packed', function()
    local server, matchId = roundWithBag()

    -- Five minutes into the round, with nobody holding the bag open.
    server.purgeContainer(KEY)

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.isTrue(server.hasBag(1, KEY), 'they did not get their bag back at all')
    t.equals(server.bagContents(KEY), 'handcuffsx2,radiox1',
        'THE BAG CAME BACK EMPTY -- its contents were never in the arena\'s keeping')
end)

t.test('and the contents are in the BAG, not loose in their pockets', function()
    local server, matchId = roundWithBag()
    server.purgeContainer(KEY)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    -- INTACT is what they own outside the bag. Anything from inside it
    -- turning up here means the exit unpacked their bag for them.
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1',
        'the bag contents were tipped into their pockets instead of put back')
end)

t.test('CONTROL: an ordinary round with a bag changes nothing about it', function()
    -- Without this the tests above pass on a build that hands out contents
    -- from nowhere. Nothing is purged here: the bag must come back exactly
    -- as it went in, with no extra copies anywhere.
    local server, matchId = roundWithBag()
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.bagContents(KEY), 'handcuffsx2,radiox1', 'the bag came back wrong')
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1', 'they gained or lost something')
    t.equals(server.stashed(1), '', 'and the belongings stash was left holding something')
end)

t.test('CONTROL: an empty bag is left alone entirely', function()
    local server, matchId = roundWithBag({})
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.bagContents(KEY), '')
    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1')
end)

t.test('CONTROL: with emptyContainers off the bag travels as it always did', function()
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.emptyContainers = false
    end)
    server.giveBag(1, BAG, KEY, { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    -- The arena never took them, so a purge still costs them -- which is the
    -- behaviour an operator is choosing when they turn this off.
    server.purgeContainer(KEY)
    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.isTrue(server.hasBag(1, KEY), 'they lost the bag itself, which is not what off means')
    t.equals(server.bagContents(KEY), '', 'the arena held contents it was told not to touch')
end)

t.test('CONTROL: an ox_inventory with no GetContainerFromSlot costs nothing', function()
    -- The export is not on every build. A server without it keeps the
    -- behaviour it has always had, and above all the door still works.
    local server = newServer({ 1, 2 })
    server.oldOxBuild()
    server.giveBag(1, BAG, KEY, { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT .. ',' .. BAG .. 'x1', 'the door stopped working on an older build')
    t.equals(server.bagContents(KEY), 'radiox1', 'it lost a bag it could not reach into')
end)

--- Anything the arena itself issues, which is legitimately created at the
--- door and destroyed at the exit. Conservation is asserted over everything
--- else -- the things players actually own.
local function ownedOnly(ledger, issued)
    local out = {}
    for name, count in pairs(ledger) do
        if not issued[name] then out[name] = count end
    end
    return out
end

local function ledgerDiff(before, after)
    local lines = {}
    local seen = {}
    for name in pairs(before) do seen[name] = true end
    for name in pairs(after) do seen[name] = true end
    local names = {}
    for name in pairs(seen) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local was, now = before[name] or 0, after[name] or 0
        if was ~= now then
            lines[#lines + 1] = ('%s %d -> %d'):format(name, was, now)
        end
    end
    return table.concat(lines, '; ')
end

t.test('A WHOLE MATCH CONSERVES WHAT PLAYERS OWN, on every way out of one', function()
    -- THE GENERAL FORM OF EVERY DUPLICATION DEFECT IN THIS FILE, asserted
    -- rather than reasoned about: count every item this server is holding --
    -- pockets, belongings stashes, bag-holding stashes, the insides of bags
    -- -- before a match and after it, and nothing players own may have
    -- appeared or gone. Anything the ARENA issues is excluded: that is
    -- created at the door and destroyed at the exit on purpose.
    --
    -- It is deliberately not about one inventory. The defects this file has
    -- had were all of the shape "it is in two places now", and only a total
    -- can see that.
    local shapes = {
        ['a match that ends normally'] = function(server, matchId)
            server.match.End(matchId, 'match.ended')
        end,
        ['a fighter leaving mid-round'] = function(server)
            server.fire('leaveMatch', 2)
        end,
        ['a fighter disconnecting'] = function(server)
            server.drop(2)
        end,
        ['the resource stopping mid-round'] = function(server)
            server.stopResource()
        end,
    }

    for label, finish in pairs(shapes) do
        local server = newServer({ 1, 2 })
        server.giveBag(1, 'police_bag', 'k_' .. #label, { { 'radio', 1 } })

        local issued = {}
        local before = server.ledger()

        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)

        -- Whatever the arena handed out during placement is its own and is
        -- meant to vanish at the exit; conservation is about the rest.
        for name in pairs(server.ledger()) do
            if before[name] == nil then issued[name] = true end
        end

        finish(server, match.id)
        server.step(10)

        local diff = ledgerDiff(ownedOnly(before, issued), ownedOnly(server.ledger(), issued))
        t.equals(diff, '', ('%s did not conserve what players own'):format(label))
    end
end)

-- ========================================================================
-- A JAM IS ONLY USEFUL IF SOMEBODY CAN CLEAR IT
--
-- Three failures in server/ammo.lua stop the door touching a stash: a
-- rollback that could not be undone, a hand-back whose removal was refused,
-- and a stash holding more than the door put in it. All three print "settle
-- it by hand" -- and there was nothing to run afterwards to say the settling
-- was done. The flag lived and died with the resource, so following the
-- instructions exactly still left the stash dead, and that player was never
-- stripped at the door again for the rest of the server's uptime.
-- ========================================================================

--- Plays a round that leaves player 1's belongings stash jammed, with a
--- surplus parked in it.
local function jammedBySurplus()
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)
    t.contains(server.log(), 'touching that stash no further', 'the fixture did not jam anything')
    return server
end

--- Whether any stash is still being held back. ASKED DIRECTLY, because the
--- observable this used to use -- "was the player stripped next round" -- is
--- no longer the same question: a jam deliberately does not stop the door
--- working any more, it just moves that round into the next stash along.
local function jamsStanding(server)
    return #server.ammo.JammedStashes()
end

--- Runs one more round and answers whether the door stripped player 1.
local function strippedNextRound(server)
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    return server.carrying(1):find('burgerx3', 1, true) == nil
end

--- Presses Clear the hold on the tablet, as an admin standing in the game.
---
--- NOT FROM THE CONSOLE, and the reason is worth keeping: ArenaRateLimit
--- refuses src 0 outright, because a net event comes from a client and the
--- server console is not one. Firing these as src 0 looked like it worked --
--- no error, nothing in the log -- and asserted nothing at all.
---
--- The admin check is stubbed rather than ace-granted because this fixture's
--- IsPlayerAceAllowed answers false for everybody; who may press the button is
--- tests/admintablet_spec.lua's subject, not this file's.
local function unjam(server, stash, forced)
    local was = server.env.ArenaIsAdmin
    server.env.ArenaIsAdmin = function() return true end
    server.fire('adminUnjam', 1, { stash = stash, force = forced == true })
    server.env.ArenaIsAdmin = was
end

t.test('THE PROPERTY-LOSS DEFECT: the sweep empties the stash that HOLDS their things',
function()
    -- ReturnLeftovers used to re-derive the stash with stashFor(citizenid),
    -- and stashFor answers the BASE name whenever the base is not jammed.
    -- That is right for deciding where to PUT things and wrong for deciding
    -- where to GET them, and the two come apart on exactly the path the
    -- tablet tells an operator to walk:
    --
    --   the base jams, so the round's belongings go to the NEXT stash along
    --     and the arena records that as what it owes them;
    --   the exit cannot hand them over -- a full inventory here, which is the
    --     ordinary reason a debt is left standing at all;
    --   the operator opens the base, reads it, presses Clear the hold;
    --   the base is unjammed now, so stashFor goes back to answering the
    --     BASE -- and the sweep empties the BASE, calls it settled, and drops
    --     the debt.
    --
    -- The player is handed whatever was in the base and their real belongings
    -- are stranded with nothing recording that they are owed anything.
    local server = jammedBySurplus()

    -- A SECOND ROUND, DRIVEN BY THE ARENA ITSELF. That is what makes the alt
    -- stash real: the base is jammed, so the door stows this round's
    -- belongings into the next stash along and records THAT as the debt.
    -- Planting items by hand would test a state the arena never produces.
    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local second = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = second.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    t.isTrue(server.contentsOf('crimson_arena_CID1_2') ~= '',
        'premise: the jam did not move this round into the next stash along')

    -- The exit cannot hand them back, so the debt stands.
    server.refuseAdds(1, true)
    server.match.End(second.id, 'match.ended')
    server.step(8)
    server.refuseAdds(1, false)

    t.isTrue(server.contentsOf('crimson_arena_CID1_2') ~= '',
        'premise: the refused exit did not leave the belongings outstanding')

    -- Something else is in the base, and the operator settles it and clears
    -- the hold exactly as the tablet tells them to.
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)
    unjam(server, 'crimson_arena_CID1', true)

    server.env.ArenaAmmo.ReturnLeftovers(1)

    t.equals(server.contentsOf('crimson_arena_CID1_2'), '',
        'the stash that actually held their belongings was never emptied -- their things are '
        .. 'stranded and the debt has been dropped')
    t.isTrue(server.carrying(1):find('lockpick', 1, true) == nil,
        'the sweep emptied the BASE stash instead of the one holding their things')
end)

t.test('a jammed stash is listed, with what is still in it', function()
    -- THE LISTING IS A TABLET REPORT NOW -- Tools -> Held-back stashes --
    -- rather than a console command, so this asserts the lines that report
    -- hands back rather than what a command printed. Same function, same
    -- words, and it is the one an operator actually reads.
    local server = jammedBySurplus()

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.contains(report, 'crimson_arena_CID1')
    t.contains(report, 'STILL IN IT',
        'the listing did not say the stash has things in it, which is the whole decision')
end)

t.test('DEFECT: clearing a jam on a stash that still holds something is REFUSED', function()
    -- THE FOOT-GUN, found by attacking this command rather than by a report.
    -- A jam means the arena parked rows it could not account for. Clearing it
    -- without emptying the stash puts every one of them back inside the next
    -- ceiling, and the next exit hands them over -- the exact duplication the
    -- jam was protecting against. An operator running this to tidy a noisy
    -- console would have done that to every parked surplus at once.
    local server = jammedBySurplus()

    unjam(server, 'crimson_arena_CID1')

    t.isNil(server.log():find('no longer held back', 1, true), 'it cleared a stash that still had a surplus in it')
    t.contains(server.log(), 'would put those back inside the next ceiling')
    t.equals(jamsStanding(server), 1, 'the jam cleared anyway, so the surplus is live again')
end)

t.test('and once it has been settled by hand, it clears and the door uses it again', function()
    local server = jammedBySurplus()

    server.emptyStash('crimson_arena_CID1')      -- the admin took the surplus out
    unjam(server, 'crimson_arena_CID1')

    t.contains(server.log(), 'no longer held back')
    t.equals(jamsStanding(server), 0, 'the jam never cleared')
end)

t.test('and `force` clears one that still holds something, for an operator who has checked', function()
    -- The escape hatch has to exist -- sometimes what is in there really is
    -- theirs -- but it has to be said out loud rather than be the default.
    local server = jammedBySurplus()

    unjam(server, 'crimson_arena_CID1', true)

    t.contains(server.log(), 'no longer held back')
    t.equals(jamsStanding(server), 0, 'even force did not clear it')
end)

t.test('and a jam that has not been cleared still holds', function()
    -- The control: listing must not clear anything by itself, and neither
    -- must a name that is not jammed.
    local server = jammedBySurplus()

    server.ammo.JamReport()
    unjam(server, 'crimson_arena_CID9')

    t.equals(jamsStanding(server), 1, 'the jam cleared itself')
end)

t.test('and a player who is not an admin cannot clear one', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    -- SRC 3, WHO HAS FIRED NOTHING YET, and that is the whole of what makes
    -- this test able to fail.
    --
    -- It used to fire as src 1 -- a fighter who had just been through a whole
    -- round. This fixture's clock does not move, so ArenaRateLimit had
    -- already seen src 1 on this bucket and dropped the event before the
    -- admin check was ever reached: the test passed with the permission gate
    -- deleted. Measured, not suspected. A src the limiter has never seen
    -- reaches the gate, and the gate is what refuses them.
    -- WITH `force`, so the only thing left that can refuse them is the
    -- permission gate. Without it the stash's own contents refuse the clear
    -- first -- it still holds the phone -- and the test passed with the gate
    -- deleted, which is a test of the wrong line.
    server.fire('adminUnjam', 3, { stash = 'crimson_arena_CID1', force = true })

    t.isNil(server.log():find('no longer held back', 1, true),
        'a player cleared a jam on somebody else\'s stash')
end)

t.test('two players with their own bags never get each other\'s contents', function()
    -- The holding stash is named from the CONTAINER, not the player, and it
    -- is owned by the character -- both halves of that matter. Registered
    -- shared, or named from anything two players could collide on, this is
    -- where it would show.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })
    server.giveBag(2, 'police_bag', 'k2', { { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.purgeContainer('k1')
    server.purgeContainer('k2')
    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.bagContents('k1'), 'radiox1', 'one player\'s bag came back with the wrong things in it')
    t.equals(server.bagContents('k2'), 'handcuffsx2')
end)

t.test('and a bag survives two rounds back to back', function()
    -- The second round finds the bag EMPTY at the door, because the first
    -- round put its contents back a moment earlier. Nothing to hold means
    -- nothing to give back, and a refill that fired anyway on a stale list
    -- would duplicate.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'bagkey123', { { 'radio', 1 } })

    for _ = 1, 2 do
        server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
        local match = server.lobby.All()[1]
        server.fire('joinMatch', 2, { matchId = match.id })
        server.fire('setReady', 1, { ready = true })
        server.fire('setReady', 2, { ready = true })
        server.step(6)
        server.purgeContainer('bagkey123')
        server.match.End(match.id, 'match.ended')
        server.step(8)
    end

    t.equals(server.bagContents('bagkey123'), 'radiox1', 'the bag did not survive two rounds')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1', 'something accumulated across the two rounds')
end)

-- ========================================================================
-- TWO MATCHES AT ONCE
--
-- Every test above this point runs ONE round. The door, the belongings
-- stash, the bag holding stashes and the routing buckets are all keyed
-- per-player or per-match, and "keyed per X" is a claim that only a second
-- X can test. This section runs two rounds at two arenas at the same time
-- and asks whether either one can cost the other anything.
-- ========================================================================

--- Opens a match at `arenaKey` with `ids`, readies everybody and steps until
--- the fighters are placed. Returns the match id.
local function roundAt(server, arenaKey, ids)
    server.fire('createMatch', ids[1], { arenaKey = arenaKey, modeKey = 'ffa', entryFee = 0 })

    local match
    for _, candidate in ipairs(server.lobby.All()) do
        if candidate.arenaKey == arenaKey then match = candidate end
    end
    t.isNotNil(match, ('no lobby opened at %s'):format(arenaKey))

    for n = 2, #ids do server.fire('joinMatch', ids[n], { matchId = match.id }) end
    for _, src in ipairs(ids) do server.fire('setReady', src, { ready = true }) end
    server.step(6)
    return match.id
end

t.test('two matches at once get their own instances, and nobody is left in the world', function()
    local server = newServer({ 1, 2, 3, 4 })

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    local bucketA, bucketB = server.bucketOf(1), server.bucketOf(3)

    t.isTrue(bucketA > 0, 'the first match was fought in the open world')
    t.isTrue(bucketB > 0, 'the second match was fought in the open world')
    t.isFalse(bucketA == bucketB, 'BOTH MATCHES ARE IN THE SAME INSTANCE -- they can see and shoot each other')
    t.equals(server.bucketOf(2), bucketA, 'a fighter was left out of their own match\'s instance')
    t.equals(server.bucketOf(4), bucketB)

    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(10)

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        t.equals(server.bucketOf(src), 0, ('%d was left behind in an arena instance'):format(src))
    end
end)

t.test('and one match ending does not touch the other', function()
    -- A SLOW CLOCK, because this test needs match B to still be running when
    -- it looks. The fixture's default jumps GetGameTimer a whole minute per
    -- call, so B's round timer expires within a couple of steps and "B lost
    -- its instance" would really be "B finished".
    local server = newServer({ 1, 2, 3, 4 }, nil, nil, { tickMs = 10 })

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })
    local bucketB = server.bucketOf(3)

    server.match.End(a, 'match.ended')

    -- TWO STEPS, NOT EIGHT, AND THE NUMBER IS THE TEST'S OWN LIMIT RATHER
    -- THAN THE CODE'S. The round thread counts resumes, not milliseconds, so
    -- any match left running in this fixture finishes within about three
    -- steps whatever the clock says. That is a clean, correct end -- the
    -- fighters get everything back, which the checks below the section prove
    -- -- but it means "B is still live" is only askable in this window.
    server.step(2)

    t.equals(server.lobby.Get(b).state, 'live', 'the fixture ended B on its own before the test looked')

    -- The finished match's fighters are home with their own things...
    t.equals(server.carrying(1), INTACT, 'the finished match did not hand everything back')
    t.equals(server.bucketOf(1), 0)

    -- ...and the live one is untouched: still instanced, still stripped.
    t.equals(server.bucketOf(3), bucketB, 'the live match lost its instance when the other one ended')
    t.isNil(server.carrying(3):find('burgerx3', 1, true),
        'the live match\'s fighter got their own kit back mid-round')
    t.equals(server.stashed(3), 'ammo-rifle-apx40,burgerx3,phonex1',
        'the live match\'s belongings were emptied out of their stash by the other match ending')
end)

t.test('four players with four bags, two matches, every bag comes back its own', function()
    local server = newServer({ 1, 2, 3, 4 })
    for _, src in ipairs({ 1, 2, 3, 4 }) do
        server.giveBag(src, 'police_bag', 'k' .. src, { { 'radio', src } })
    end

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    -- Five minutes pass in both instances and every container is dropped.
    for _, src in ipairs({ 1, 2, 3, 4 }) do server.purgeContainer('k' .. src) end

    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(12)

    for _, src in ipairs({ 1, 2, 3, 4 }) do
        t.equals(server.bagContents('k' .. src), 'radiox' .. src,
            ('%d\'s bag came back with the wrong things in it'):format(src))
        t.equals(server.carrying(src), INTACT .. ',police_bagx1',
            ('%d did not come out with exactly their own things'):format(src))
    end
end)

t.test('a disconnect out of one match leaves the other match alone', function()
    local server = newServer({ 1, 2, 3, 4 }, nil, nil, { tickMs = 10 })
    server.giveBag(3, 'police_bag', 'k3', { { 'radio', 1 } })

    roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })
    local bucketB = server.bucketOf(3)

    server.drop(1)
    server.step(2)

    t.equals(server.lobby.Get(b).state, 'live', 'the fixture ended B on its own before the test looked')
    t.equals(server.bucketOf(1), 0, 'the disconnected player was left in an arena instance')
    t.equals(server.bucketOf(3), bucketB, 'the other match lost its instance')
    t.equals(server.bucketOf(4), bucketB)

    server.purgeContainer('k3')
    server.match.End(b, 'match.ended')
    server.step(10)

    t.equals(server.bagContents('k3'), 'radiox1', 'the other match\'s bag was collateral')
    t.equals(server.carrying(3), INTACT .. ',police_bagx1')
end)

t.test('AND TWO SIMULTANEOUS MATCHES CONSERVE WHAT PLAYERS OWN', function()
    -- The same total as the single-match check, across two rounds running at
    -- once, with bags in both and a disconnect out of one of them.
    local server = newServer({ 1, 2, 3, 4 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })
    server.giveBag(3, 'police_bag', 'k3', { { 'handcuffs', 2 } })

    local before = server.ledger()

    local a = roundAt(server, 'trailerpark', { 1, 2 })
    local b = roundAt(server, 'skydome', { 3, 4 })

    local issued = {}
    for name in pairs(server.ledger()) do
        if before[name] == nil then issued[name] = true end
    end

    server.purgeContainer('k1')
    server.purgeContainer('k3')
    server.drop(4)
    server.match.End(a, 'match.ended')
    server.match.End(b, 'match.ended')
    server.step(12)

    local diff = ledgerDiff(ownedOnly(before, issued), ownedOnly(server.ledger(), issued))
    t.equals(diff, '', 'two matches at once did not conserve what players own')
end)

-- ========================================================================
-- WHEN THE DATABASE ROUND TRIP DOES NOT COME BACK
--
-- ox_inventory throws an idle inventory out of memory after
-- `inventory:cleartime` and reads it back from the database on the next
-- touch. With a healthy database that is lossless and invisible, and every
-- other test in this file is that case. These two are the other one.
--
-- Nothing in this resource can recover items ox_inventory has dropped and
-- the database did not give back -- they do not exist anywhere any more. So
-- the whole of the promise here is: never call it a clean exit, never make
-- it worse, and say exactly what is missing.
-- ========================================================================

t.test('a belongings stash that comes back empty is never reported as a clean exit', function()
    local server, matchId = liveMatch({ 1, 2 })

    server.forgetStash(1)      -- written out, read back, nothing came back

    server.match.End(matchId, 'match.ended')
    server.step(10)

    t.contains(server.log(), 'READ EMPTY',
        'it handed a player empty pockets and called the exit clean')
    t.isNotNil(server.ammo.HeldFor(1),
        'the record was dropped, so nothing will ever go back for their belongings')
end)

t.test('and a bag holding stash that comes back short says so, by count', function()
    -- THE SAME EXPOSURE ON THIS RESOURCE'S OWN STASH, and it was silent. The
    -- refill returned quietly on an empty read, so a holding stash that had
    -- been through the round trip looked exactly like a bag that went in
    -- empty: the bag came back hollow with nothing anywhere saying why. The
    -- count taken at the door is the only thing that can tell those apart.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 }, { 'handcuffs', 2 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.emptyStash('crimson_arena_bag_k1')   -- the holding stash is what was lost

    server.match.End(match.id, 'match.ended')
    server.step(10)

    t.contains(server.log(), 'are NOT in stash',
        'a player\'s bag was emptied by the arena and nothing said so')
    -- And it still does not make anything up, or take anything else.
    t.equals(server.carrying(1), INTACT .. ',police_bagx1')
end)

-- ========================================================================
-- THE REFUSALS NOBODY HAD DRIVEN
--
-- A full inventory is the most ordinary refusal there is at an exit, and
-- nothing here could say it: the fixture had no way to make ox_inventory
-- turn an item down. Neither could it show what was sitting in a bag
-- holding stash. Both are levers now, and these are the three cases they
-- open up.
-- ========================================================================

t.test('an exit that cannot hand everything over keeps it, says so, and comes back for it', function()
    local server, matchId = liveMatch({ 1, 2 })

    server.refuseAdds(1)          -- their pockets are full
    server.match.End(matchId, 'match.ended')
    server.step(10)

    t.equals(server.carrying(1), '', 'items were handed to somebody who could not take them')
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1',
        'THEIR BELONGINGS WERE DESTROYED rather than left where they were safe')
    t.contains(server.log(), 'did not happen', 'nothing said their kit could not be returned')

    -- AND THE SWEEP GOES BACK FOR IT. A refusal that is never retried is the
    -- same as a loss with a nicer log line.
    server.refuseAdds(1, false)
    server.step(12)

    t.equals(server.carrying(1), INTACT, 'they never got their belongings once they had room')
    t.equals(server.stashed(1), '', 'and the stash was not emptied')
end)

t.test('a bag that will not take its contents back hands them over loose instead', function()
    -- EVERYTHING COMES BACK, AND IT IS NOT CONDITIONAL ON THE BAG. A
    -- container has its own size and weight and can be too full for what came
    -- out of it. Leaving the items in a holding stash was safe but it was not
    -- BACK -- and the owner cannot reach a stash the arena named in a console
    -- they never see. Loose in their hands is a nuisance; still in a stash is
    -- something they have to ask an admin about.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    local matchId = match.id

    server.purgeContainer('k1')
    server.refuseAdds('k1')        -- the bag is full and will not take them

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.contentsOf('crimson_arena_bag_k1'), '',
        'the contents were left in a stash the player cannot reach')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1,radiox1',
        'THEY DID NOT GET IT BACK AT ALL')
    t.contains(server.log(), 'went into their pockets instead')
end)

t.test('and only when THEY cannot take it either does it stay in the stash', function()
    -- The last resort, and it must still never destroy anything.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)
    local matchId = match.id

    server.purgeContainer('k1')
    server.refuseAdds('k1')
    server.refuseAdds(1)           -- and their pockets are full too

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1',
        'it was destroyed rather than left where it is safe')
end)

t.test('a different character on the same server id gets nothing of the last one\'s', function()
    -- FiveM reuses server ids. Everything the door remembers is keyed on the
    -- SERVER ID, and the only thing that says whether it still means the same
    -- person is the citizen id. This is that guard, over both halves at once:
    -- the belongings stash and the bag holding stash.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1', 'the door did not take the bag contents')

    -- They drop with everything still held, and their pockets stay shut so
    -- the exit cannot empty the stash on the way out.
    server.refuseAdds(1)
    server.drop(1)
    server.step(4)
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1,police_bagx1',
        'the fixture handed it all back before the newcomer arrived, so this proves nothing')

    -- Somebody else connects onto that id.
    server.refuseAdds(1, false)
    server.reseat(1, 'CID999')
    server.step(12)

    t.equals(server.carrying(1), '',
        'A NEWCOMER WAS HANDED THE PREVIOUS CHARACTER\'S BELONGINGS')
    t.equals(server.stashed(1), 'ammo-rifle-apx40,burgerx3,phonex1,police_bagx1',
        'the previous character\'s stash was emptied by somebody else taking their id')
    t.equals(server.contentsOf('crimson_arena_bag_k1'), 'radiox1',
        'and their bag contents went with it')
end)

-- ========================================================================
-- A BAG IS NEVER EMPTIED, ON ANY WAY OUT OF A ROUND
--
-- The container fix is tested above on the ordinary exit. A bag does not
-- care how the round ended, and neither should its contents -- so this
-- section runs the same claim through every other way out there is, plus
-- the shapes a bag itself can take: two of them at once, ten items in one,
-- and an item whose identity is its metadata rather than its name.
-- ========================================================================

--- Opens and starts a round at the trailer park. Returns the match id.
local function bagRound(server, ids)
    server.fire('createMatch', ids[1], { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    for n = 2, #ids do server.fire('joinMatch', ids[n], { matchId = match.id }) end
    for _, src in ipairs(ids) do server.fire('setReady', src, { ready = true }) end
    server.step(6)
    return match.id
end

--- Every one of these purges the container mid-round, which is the failure
--- the whole mechanism exists for: without the arena holding the contents,
--- the bag comes back empty.
local WAYS_OUT = {
    { 'the round ends',        function(server, m) server.match.End(m, 'match.ended') end },
    { 'the round is aborted',  function(server, m) server.match.Abort(m, 'match.aborted') end },
    { 'the fighter leaves',    function(server) server.fire('leaveMatch', 1) end },
    { 'the fighter drops',     function(server) server.drop(1) end },
    { 'the resource stops',    function(server) server.stopResource() end },
}

for _, way in ipairs(WAYS_OUT) do
    local label, finish = way[1], way[2]

    t.test(('a bag comes back packed when %s'):format(label), function()
        local server = newServer({ 1, 2 })
        server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 }, { 'handcuffs', 2 } })

        local matchId = bagRound(server, { 1, 2 })
        t.equals(server.bagContents('k1'), '', 'the door did not empty the bag on the way in')

        server.purgeContainer('k1')
        finish(server, matchId)
        server.step(12)

        t.equals(server.bagContents('k1'), 'handcuffsx2,radiox1',
            ('THE BAG WAS EMPTIED when %s'):format(label))
        t.equals(server.contentsOf('crimson_arena_bag_k1'), '',
            'the contents were left behind in the holding stash')
    end)
end

t.test('two bags on one player never pour into each other', function()
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'ka', { { 'radio', 1 } })
    server.giveBag(1, 'police_bag', 'kb', { { 'handcuffs', 2 } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('ka')
    server.purgeContainer('kb')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('ka'), 'radiox1', 'the first bag came back with the wrong things')
    t.equals(server.bagContents('kb'), 'handcuffsx2', 'the second bag came back with the wrong things')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1,police_bagx1', 'they lost or gained a bag')
end)

t.test('and an item whose identity is its metadata keeps it inside a bag', function()
    -- A count of names cannot see this, and a bag is exactly where people
    -- keep the things it matters for.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'phone', 1, { number = '555-REAL' } } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local meta = server.bagMetaOf('k1', 'phone')
    t.isNotNil(meta, 'the phone did not come back to the bag at all')
    t.equals(meta.number, '555-REAL', 'THEY GOT SOMEBODY ELSE\'S PHONE BACK')
end)

t.test('and ten items in one bag all come back', function()
    local server = newServer({ 1, 2 })
    local stuff = {}
    for n = 1, 10 do stuff[n] = { 'item' .. n, n } end
    server.giveBag(1, 'police_bag', 'k1', stuff)

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local back = {}
    for _, entry in ipairs(stuff) do
        if not server.bagContents('k1'):find(entry[1] .. 'x' .. entry[2], 1, true) then
            back[#back + 1] = entry[1]
        end
    end
    t.equals(table.concat(back, ','), '', 'these did not come back to the bag')
end)

t.test('CONTROL: with the door switched off entirely, the bag is never touched', function()
    -- stripOnEntry off means no stow, so no hold and no refill. The bag must
    -- travel exactly as it is -- and nothing may be left in a holding stash
    -- for a round that never took anything.
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.stripOnEntry = false
    end)
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    local matchId = bagRound(server, { 1, 2 })
    t.equals(server.bagContents('k1'), 'radiox1', 'the door emptied a bag it was told not to touch')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'radiox1')
    t.equals(server.contentsOf('crimson_arena_bag_k1'), '', 'it held contents for a round that never stripped')
end)

-- ========================================================================
-- KEEPING A STASH ALIVE LONG ENOUGH TO OUTLIVE A ROUND
--
-- ox_inventory drops any inventory nobody has open after
-- `inventory:cleartime` -- five minutes by default -- and reads it back from
-- the database on the next touch. Nobody ever opens the arena's belongings
-- stash, so on the shipped setting every round longer than five minutes
-- sends somebody's belongings through the database mid-match.
--
-- The door catches what that costs. This stops it happening.
-- ========================================================================

t.test('the shipped setting is raised to outlive a round', function()
    local server = newServer({ 1, 2 }, nil, nil, { oxStarted = false })

    t.equals(server.convar('inventory:cleartime'), 45,
        'a round can still outlive ox_inventory\'s memory of the stash it is held in')
    t.contains(server.log(), 'raised from 5 minute(s) to 45')
end)

t.test('and a longer one an operator already chose is left alone', function()
    -- A floor, not an opinion. Somebody who set 90 in server.cfg has said
    -- what they want.
    local server = newServer({ 1, 2 }, nil, nil, { oxStarted = false, cleartime = 90 })

    t.equals(server.convar('inventory:cleartime'), 90, 'it overrode an operator\'s own setting')
    t.isNil(server.log():find('raised from', 1, true))
end)

t.test('and 0 means do not touch ox_inventory\'s setting at all', function()
    local server = newServer({ 1, 2 }, function(config)
        config.Loadouts.inventory.keepStashesAliveMinutes = 0
    end, nil, { oxStarted = false })

    t.equals(server.convar('inventory:cleartime'), 5, 'it changed a setting it was told to leave')
end)

t.test('DEFECT: if ox_inventory is already up it says so, rather than doing nothing quietly', function()
    -- ox_inventory reads that convar ONCE, when IT starts. Setting it
    -- afterwards changes nothing until something restarts -- and a fix that
    -- silently does not apply is worse than no fix, because the operator
    -- believes it did.
    local server = newServer({ 1, 2 }, nil, nil, { oxStarted = true })

    t.contains(server.log(), 'will not take effect until the next restart')
    t.contains(server.log(), 'set inventory:cleartime 45',
        'it did not print the line an operator needs for server.cfg')
end)

t.test('a holding stash that refuses the contents leaves them in the bag', function()
    -- THE FAIL-SAFE DIRECTION. If the arena cannot take a bag's contents into
    -- its own keeping, the right answer is to leave them exactly where they
    -- are -- which is the behaviour this resource had before any of this
    -- existed, and costs nothing.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })
    server.refuseAdds('crimson_arena_bag_k1')

    local matchId = bagRound(server, { 1, 2 })
    t.equals(server.bagContents('k1'), 'radiox1', 'it took them out of the bag with nowhere to put them')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'radiox1', 'THE CONTENTS WERE LOST between the bag and nowhere')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1', 'the rest of the exit stopped working')
end)

t.test('a player\'s OWN copy of an arena item, inside their bag, comes back and is not billed', function()
    -- ammo-rifle-ap is something this arena issues, and the exit takes the
    -- arena's own rounds back by name. Their own copy is in their bag. Both
    -- halves have to be true: it comes back, AND the reclaim does not treat
    -- it as the arena's just because the name matches.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'ammo-rifle-ap', 25 } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'ammo-rifle-apx25',
        'THE ARENA TOOK A PLAYER\'S OWN AMMUNITION OUT OF THEIR BAG')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1',
        'and what they were carrying changed too')
end)

t.test('a bag still comes back packed when the belongings stash jams at the exit', function()
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)   -- surplus, so the stash jams

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'radiox1',
        'a jam on the belongings stash cost them their bag contents as well')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1')
    t.equals(server.stashed(1), 'lockpickx2', 'the surplus was not left parked')
end)

t.test('DEFECT: a jam must not stop the door stripping the NEXT round, or protecting a bag', function()
    -- THE CLIFF, reported off a live server as the arena "not clearing the
    -- inventory" and "still clearing the leo bag" -- one cause, both
    -- symptoms. A jam stopped the door putting anything into that stash, and
    -- the stash name was the character's and nothing else, so that player was
    -- never stripped again. holdContainers sits BELOW the jam check, so their
    -- bags stopped being protected at the same moment.
    --
    -- On a server where the thing that causes a jam happens routinely, that
    -- is every player, one long round each.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    local first = bagRound(server, { 1, 2 })
    server.stashItem('crimson_arena_CID1', 'lockpick', 2)     -- surplus -> jam
    server.match.End(first, 'match.ended')
    server.step(12)

    t.equals(jamsStanding(server), 1, 'the fixture did not jam anything, so this proves nothing')

    -- The next round must work completely normally.
    local second = bagRound(server, { 1, 2 })

    t.isNil(server.carrying(1):find('burgerx3', 1, true),
        'THE DOOR STOPPED STRIPPING THEM because an earlier stash was jammed')
    t.equals(server.bagContents('k1'), '',
        'AND IT STOPPED PROTECTING THEIR BAG for the same reason')

    server.purgeContainer('k1')
    server.match.End(second, 'match.ended')
    server.step(12)

    t.equals(server.carrying(1), INTACT .. ',police_bagx1', 'they did not get everything back')
    t.equals(server.bagContents('k1'), 'radiox1', 'the bag came back empty')

    -- And the jammed stash is untouched, still waiting for an admin.
    t.equals(jamsStanding(server), 1, 'the jam was quietly dropped instead of left to be settled')
end)

-- ========================================================================
-- IT IS THE SAME ONE BACK, NOT ONE LIKE IT
--
-- On a server where a weapon carries a serial and a phone carries a number,
-- "they got a pistol back" is not the promise -- "they got THEIR pistol
-- back" is. A count of names cannot tell those apart, and every test above
-- that compares `carrying` is a count of names.
--
-- ox_inventory keeps that identity in the item's metadata, so the whole
-- question is whether metadata survives the round trip into the stash and
-- out again -- and, separately, into a bag's holding stash and back into
-- the bag.
-- ========================================================================

-- NOT A SECOND PHONE. OWN already carries one, and metaOf answers on the
-- first item of that name -- so adding another here reads the metadata of
-- the wrong one and the test fails for a reason that is not the code's. A
-- licence is an item nothing else in this file uses.
local OWNED_GUN = {
    { name = 'WEAPON_PISTOL', count = 1,
      metadata = { serial = 'MINE-0001', ammo = 12, components = { 'flashlight' } } },
    { name = 'licence', count = 1, metadata = { holder = 'John Allday' } },
}

t.test('a player\'s own weapon comes back with its own serial, ammo and components', function()
    local server = newServer({ 1, 2 }, nil, OWNED_GUN)

    local matchId = bagRound(server, { 1, 2 })
    t.isNil(server.metaOf(1, 'WEAPON_PISTOL'), 'the door did not take their own weapon off them')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    local gun = server.metaOf(1, 'WEAPON_PISTOL')
    t.isNotNil(gun, 'they did not get their own weapon back at all')
    t.equals(gun.serial, 'MINE-0001', 'THEY GOT SOMEBODY ELSE\'S WEAPON BACK')
    t.equals(gun.ammo, 12, 'the rounds in it were not the rounds they left with')
    t.equals(gun.components and gun.components[1], 'flashlight', 'its attachments were lost')
end)

t.test('and an item whose identity is a name on it comes back as theirs', function()
    local server = newServer({ 1, 2 }, nil, OWNED_GUN)

    local matchId = bagRound(server, { 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local licence = server.metaOf(1, 'licence')
    t.isNotNil(licence, 'it did not come back')
    t.equals(licence.holder, 'John Allday', 'THEY GOT SOMEBODY ELSE\'S PAPERS BACK')
end)

t.test('and a weapon kept INSIDE a bag keeps its serial too', function()
    -- The bag's contents take a different route entirely -- out of the
    -- container, into a holding stash, back into the container -- so the
    -- identity question has to be asked of that route separately.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', {
        { 'WEAPON_PISTOL', 1, { serial = 'INBAG-0002', ammo = 7 } },
    })

    local matchId = bagRound(server, { 1, 2 })
    server.purgeContainer('k1')
    server.match.End(matchId, 'match.ended')
    server.step(12)

    local gun = server.bagMetaOf('k1', 'WEAPON_PISTOL')
    t.isNotNil(gun, 'the weapon did not come back to the bag')
    t.equals(gun.serial, 'INBAG-0002', 'THE WEAPON IN THEIR BAG CAME BACK AS A DIFFERENT ONE')
    t.equals(gun.ammo, 7, 'its rounds were not what they left in it')
end)

t.test('and two players\' identical weapons do not swap owners', function()
    -- Same item name, different serials, one round. A hand-back that matched
    -- on name alone would be invisible to every other test in this file.
    local server = newServer({ 1, 2 })
    server.give(1, 'WEAPON_PISTOL', 1, { serial = 'P1-GUN' })
    server.give(2, 'WEAPON_PISTOL', 1, { serial = 'P2-GUN' })

    local matchId = bagRound(server, { 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.metaOf(1, 'WEAPON_PISTOL').serial, 'P1-GUN',
        'a player was handed the other fighter\'s weapon')
    t.equals(server.metaOf(2, 'WEAPON_PISTOL').serial, 'P2-GUN',
        'and the other one got the first player\'s')
end)

t.test('DEFECT: a bag that takes the item and answers nothing must not produce a second one', function()
    -- THE DUPLICATION HAZARD IN THE FALLBACK ITSELF. oxGave demands proof and
    -- reads a nil answer as "no" -- correct everywhere else in this file,
    -- because everywhere else "no" means leave the item where it is. In the
    -- refill "no" means try their pockets instead, so a bag that took the
    -- item and merely answered nil would get them a second copy. That is the
    -- exact defect this whole file exists to stop, reintroduced by a
    -- convenience, so the refusal is verified before it is believed.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'k1', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.purgeContainer('k1')
    server.lieOnAdds('k1')         -- it takes them, and says nothing

    server.match.End(match.id, 'match.ended')
    server.step(12)

    t.equals(server.bagContents('k1'), 'radiox1', 'the bag did not end up with it')
    t.equals(server.carrying(1), INTACT .. ',police_bagx1',
        'THEY WERE HANDED A SECOND COPY because the bag did not say it took the first')
end)

-- ========================================================================
-- A STASH-BACKED BAG, WHICH IS NOT A CONTAINER AT ALL
--
-- fm-firstresponderbag's LEO and EMS bags are NOT ox_inventory containers.
-- They are ordinary items carrying `metadata.bagId`, and their contents live
-- in a SEPARATE STASH named `leo_bag_<bagId>` that the bag resource
-- registers and opens on demand.
--
-- So the container custody above does nothing for them, correctly: there is
-- no `metadata.container` to hold. The arena never touches that stash, and
-- must not.
--
-- WHAT THE ARENA CAN STILL COST THEM is the LINK. The bag is just an item to
-- this resource -- it goes into the belongings stash and comes back -- and
-- if `bagId` did not survive that trip, the bag would open a DIFFERENT,
-- EMPTY stash on the other side. To its owner that is indistinguishable
-- from the arena having emptied it, and the real contents would still be
-- sitting in a stash nothing now points at.
-- ========================================================================

t.test('a stash-backed bag keeps the id its contents hang off', function()
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7', label = 'LEO Bag' } },
    })

    local matchId = bagRound(server, { 1, 2 })
    t.isNil(server.metaOf(1, 'leo_bag'), 'the door did not take the bag off them')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    local bag = server.metaOf(1, 'leo_bag')
    t.isNotNil(bag, 'the bag itself did not come back')
    t.equals(bag.bagId, 'CID1-LEO-7',
        'THE BAG CAME BACK POINTING AT A DIFFERENT STASH -- to its owner that reads as emptied')
    t.equals(bag.label, 'LEO Bag', 'the rest of its metadata was lost with it')
end)

t.test('THE DEFECT: a stash-backed bag is EMPTY for the round, so nothing can empty it', function()
    -- THIS TEST USED TO ASSERT THE OPPOSITE, and it was right at the time:
    -- the arena's own sweep works on its own prefix and had no business in
    -- somebody else's stash. What changed is that leaving it alone turned
    -- out to be the reason police bags came back empty round after round --
    -- something ELSE on that server empties it, and there is nothing in this
    -- repository to fix because there is nothing in this repository that
    -- touches it.
    --
    -- So the arena takes the contents for the length of the round, exactly
    -- as it does an ox_inventory container's, and whatever empties that
    -- stash mid-round now empties one that is already empty. See
    -- stashBagRules in server/ammo.lua.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7' } },
    })
    server.stashItem('leo_bag_CID1-LEO-7', 'handcuffs', 2)
    server.stashItem('leo_bag_CID1-LEO-7', 'radio', 1)

    local matchId = bagRound(server, { 1, 2 })
    t.equals(server.contentsOf('leo_bag_CID1-LEO-7'), '',
        'the bag\'s own stash still held its contents through the round, where anything '
        .. 'on the server could empty it and the arena would never know')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.contentsOf('leo_bag_CID1-LEO-7'), 'handcuffsx2,radiox1',
        'THE ARENA DID NOT PUT THE BAG CONTENTS BACK')
    t.equals(server.carrying(1), 'ammo-rifle-apx40,burgerx3,leo_bagx1,phonex1',
        'and the player did not come out with exactly their own things')
end)

t.test('and something emptying that stash mid-round costs the player NOTHING', function()
    -- The whole point, stated as the thing that was actually happening.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7' } },
    })
    server.stashItem('leo_bag_CID1-LEO-7', 'handcuffs', 2)
    server.stashItem('leo_bag_CID1-LEO-7', 'radio', 1)

    local matchId = bagRound(server, { 1, 2 })

    -- Whatever it is. It finds an empty stash now.
    server.emptyStash('leo_bag_CID1-LEO-7')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.contentsOf('leo_bag_CID1-LEO-7'), 'handcuffsx2,radiox1',
        'the bag came back empty, which is the entire defect')
end)

t.test('and a bag whose id is RE-MINTED mid-round follows the bag, not the old name', function()
    -- THE MECHANISM, off the operator's own log: two different characters'
    -- bags carried an identical creation second, so something re-mints those
    -- ids. A re-minted id points the bag at a new and empty stash.
    --
    -- The contents are put back into whatever the bag names WHEN IT COMES
    -- BACK, never the name taken at the door -- so they follow it across the
    -- change instead of being filed for ever under a name nothing opens.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7' } },
    })
    server.stashItem('leo_bag_CID1-LEO-7', 'handcuffs', 2)
    server.stashItem('leo_bag_CID1-LEO-7', 'radio', 1)

    local matchId = bagRound(server, { 1, 2 })

    -- Something re-mints it while its owner is fighting.
    server.remint('crimson_arena_CID1', 'leo_bag', 'bagId', 'CID1-LEO-9')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    local bag = server.metaOf(1, 'leo_bag')
    t.isNotNil(bag, 'the bag itself did not come back')
    t.equals(bag.bagId, 'CID1-LEO-9', 'premise: the bag came back carrying the new id')

    t.equals(server.contentsOf('leo_bag_CID1-LEO-9'), 'handcuffsx2,radiox1',
        'the contents were filed under the id the bag had at the DOOR, which is a name '
        .. 'nothing will ever open again -- to its owner that reads as emptied')
end)

t.test('a server that went down mid-round does not strand a bag\'s contents for ever', function()
    -- THE GAP THE CUSTODY ITSELF OPENED, and it would have been a worse
    -- version of the defect it was written to fix. The record of what was
    -- taken lives in memory, so a restart mid-round takes it with it -- and
    -- without this the contents sit in a holding stash nothing ever comes
    -- back for, while the bag their owner is carrying opens an empty one.
    --
    -- It needs no record. The holding stash is named from the bag's own id,
    -- so the whole list rebuilds off whatever bags the player is carrying.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7' } },
    })

    -- Exactly what a restart leaves behind: the player holding their bag,
    -- their things in the arena's holding stash, and no record anywhere.
    server.stashItem('crimson_arena_bag_leo_bag_CID1-LEO-7', 'handcuffs', 2)
    server.stashItem('crimson_arena_bag_leo_bag_CID1-LEO-7', 'radio', 1)

    t.isTrue((server.env.ArenaAmmo.ReturnLeftovers(1)), 'the sweep could not settle this character')

    t.equals(server.contentsOf('leo_bag_CID1-LEO-7'), 'handcuffsx2,radiox1',
        'the contents were left in a holding stash nothing will ever come back for')
    t.equals(server.contentsOf('crimson_arena_bag_leo_bag_CID1-LEO-7'), '',
        'and the holding stash was not emptied, so the next sweep hands them over again')
end)

t.test('CONTROL: a bag the operator has NOT listed is still left entirely alone', function()
    -- The rule this replaced is still the rule for anything not named in
    -- Config.Loadouts.inventory.stashBags. The arena does not go looking for
    -- stashes to take custody of; it is told which, with the numbers to open
    -- them by, and it touches nothing else.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'duffel_bag', count = 1, metadata = { bagId = 'CID1-DUF-1' } },
    })
    server.stashItem('duffel_bag_CID1-DUF-1', 'handcuffs', 2)

    local matchId = bagRound(server, { 1, 2 })
    t.equals(server.contentsOf('duffel_bag_CID1-DUF-1'), 'handcuffsx2',
        'the arena reached into a stash nobody told it about')

    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.equals(server.contentsOf('duffel_bag_CID1-DUF-1'), 'handcuffsx2',
        'the arena emptied a stash nobody told it about')
end)


-- ========================================================================
-- THE SCREEN AND THE SERVER SAID DIFFERENT THINGS
--
-- IN THE OWNER'S OWN WORDS, off a live server, four ways in one night:
--
--   "It still brings in the items i had before a match start so thats a
--    big issue"
--   "It was in my inventory but stated it was unable to find this item or
--    something to that effect when trying to use it"
--   [the LEO bag answering] "Could not find this bag"
--   "the invetory stuff should be a top priorty it should make sure they
--    do not bring anything that was with them before a match into a match"
--
-- And the server log, the same night, for the same round:
--
--   door: put 14 item(s) of 2's away for match mb4972.
--
-- Both true. stow() reads the pockets, proves every item into the stash,
-- clears the inventory, and then READS THE POCKETS BACK to prove they are
-- empty -- and they were. The server was right. The PLAYER'S SCREEN was
-- never told, so it went on showing all fourteen items in the slots they
-- had been in, and every one of them was a ghost: use it and the server
-- has nothing there; open the LEO bag and fm-firstresponderbag's
-- `GetSlot(src, slot)` answers nil for the slot the client sent.
--
-- One argument, in ox_inventory's Inventory.Clear. See keepArg in
-- server/ammo.lua and the ClearInventory stub above, which now reproduces
-- the branch rather than the intent.
-- ========================================================================

t.test('THE DEFECT: the player\'s screen is told about every item the door took', function()
    -- The shipped config names nothing in `neverStash`, so the keep list is
    -- empty -- and an empty list is the one shape ox_inventory's Clear
    -- silently skips the sync for. This is the exact configuration every
    -- operator runs.
    local server = liveMatch({ 1, 2 })

    -- Their OWN three items are gone from the server; what they are holding
    -- now is the kit the arena issued after the clear.
    t.isNil(server.carrying(1):find('phone', 1, true), 'the server did not empty their pockets')
    t.equals(server.clientToldAbout(1), 3,
        'the server emptied their pockets and told the client about NOTHING -- '
        .. 'the player is standing in the arena looking at every item they walked in with')
end)

t.test('and the same is true of the second fighter, so it is not one unlucky source', function()
    local server = liveMatch({ 1, 2 })

    t.isNil(server.carrying(2):find('phone', 1, true))
    t.equals(server.clientToldAbout(2), 3, 'the other fighter was left looking at a ghost inventory')
end)

t.test('and an operator who DOES name something in neverStash still gets a synced screen', function()
    -- The other half of the fix, and the half a naive `if #keep == 0 then
    -- pass nil` could get wrong: a non-empty list must still go through as
    -- a list, because it is what keeps the named item in their pockets.
    local server = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverStash = { 'phone' }
    end)

    local holding = server.carrying(1)
    t.isNotNil(holding:find('phonex1', 1, true), 'the item the operator protected was taken anyway')
    t.isNil(holding:find('burger', 1, true), 'an item NOT on the list was left in their pockets')
    t.equals(server.clientToldAbout(1), 2,
        'the two items that WERE taken were not synced to the screen')
end)

t.test('and the exit clear syncs too, even when nothing is protected from it', function()
    -- Config.Loadouts.inventory.neverDestroy defaults to money, so this path
    -- has always had a non-empty list and has always synced -- which is
    -- exactly why the way OUT of a round worked while the way in did not.
    -- An operator can empty that list, and if they do this must not quietly
    -- become the same bug on the other side of the round.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Loadouts.inventory.neverDestroy = {}
    end)

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT, 'their own belongings did not come back')
    t.isNotNil(server.clientToldAbout(1), 'the exit never cleared anything at all')
end)

t.test('CONTROL: a player carrying nothing needs no sync, and is not a failure', function()
    -- ox_inventory returns immediately for an inventory with nothing in it,
    -- so there is no clear and nothing to tell the client. An empty-handed
    -- player is still stripped-and-restored correctly; they simply have
    -- nothing. Without this the assertion above could be satisfied by a
    -- door that reports a sync it never performed.
    local server = newServer({ 1, 2 })
    server.wipe(1)

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    -- What they are holding is the kit the arena issued them; none of it is
    -- theirs, and none of it existed before the door ran.
    t.isNil(server.carrying(1):find('phone', 1, true),
        'an empty-handed player ended up holding something of their own')
    t.isNil(server.clientToldAbout(1), 'an inventory with nothing in it was cleared anyway')
end)


-- ========================================================================
-- AN ITEM'S SLOT IS AN ADDRESS OTHER RESOURCES HOLD
--
-- fm-firstresponderbag opens the LEO bag like this, and it is not unusual:
--
--     local item = ox_inventory:GetSlot(src, slot)
--     if not item then ... 'Could not find this bag.' ... end
--
-- The slot comes from the client, off what it is showing. Renumber a
-- player's inventory underneath that -- which plain AddItem calls do, since
-- ox_inventory drops an item in the first slot it fits -- and every hotbar
-- binding, usable item and context menu on the server is aimed at the wrong
-- row. See addAt in server/ammo.lua.
-- ========================================================================

t.test('THE DEFECT: the door puts each item into the stash at the slot it came from', function()
    local server = liveMatch({ 1, 2 })

    -- OWN is phone, burger, ammo-rifle-ap -- slots 1, 2 and 3 in that order.
    -- INTACT reads them back alphabetically, which is not the same thing.
    t.equals(server.slotsAskedFor('crimson_arena_CID1', 'phone'), '1',
        'the phone went into the stash at whatever slot happened to be free, '
        .. 'so the number it had in the player\'s pockets is gone for good')
    t.equals(server.slotsAskedFor('crimson_arena_CID1', 'ammo-rifle-ap'), '3')
end)

t.test('and hands it back to the player at that same slot', function()
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT, 'the round trip lost something')
    t.equals(server.slotsAskedFor(1, 'phone'), '1',
        'their phone came back in a different slot than it went in, so anything '
        .. 'on this server that opens an item BY SLOT is now aimed at the wrong one')
end)

t.test('and a bag carried through a round comes back in the slot it was carried in', function()
    -- THE ONE THE OWNER HIT. A LEO bag in slot 4 that comes back in slot 1
    -- is a bag the client asks for at slot 4 and the server cannot find.
    local server = newServer({ 1, 2 })
    server.giveBag(1, 'police_bag', 'bagkey', { { 'radio', 1 } })

    server.fire('createMatch', 1, { arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0 })
    local match = server.lobby.All()[1]
    server.fire('joinMatch', 2, { matchId = match.id })
    server.fire('setReady', 1, { ready = true })
    server.fire('setReady', 2, { ready = true })
    server.step(6)

    server.match.End(match.id, 'match.ended')
    server.step(8)

    t.equals(server.slotsAskedFor(1, 'police_bag'), '4',
        'the bag was handed back without a slot, so it landed wherever it fitted')
end)

-- ========================================================================
-- A REFUSAL THAT LOOKS LIKE A LOSS
--
-- From the operator's console, while a round was live:
--
--   John Allday handed John Allday 0 item(s) back from the admin tablet
--                                               (still outstanding)
--   door: Q71NQ64O's stash (crimson_arena_Q71NQ64O) is queued
--
-- Nothing is wrong there. The player was standing in a live round with
-- fourteen items in that stash, and emptying it into them would have handed
-- them their own kit to fight with -- so the door refused, and the tablet
-- put the stash on the queue instead. Both halves are correct.
--
-- But "handed 0 item(s) back (still outstanding)" with no reason attached is
-- indistinguishable from a stash that has lost its contents, and it was read
-- that way: an afternoon went into looking for a defect that was not there.
-- One of those outcomes is the door working and the other is somebody's
-- property missing, and the log has to tell them apart.
-- ========================================================================

t.test('a fighter mid-round is refused their belongings, and the refusal SAYS WHY', function()
    local server = liveMatch({ 1, 2 })

    local ok, returned, _, why = server.env.ArenaAmmo.ReturnLeftovers(1)

    t.isFalse(ok, 'the door emptied a live fighter\'s own belongings into them mid-round')
    t.equals(returned, 0, 'it handed something over anyway')
    t.isNotNil(why, 'it refused and said nothing at all about why -- which reads as a loss')
    t.contains(why, 'live match',
        'the reason does not name the one thing an operator needs to hear: that this is '
        .. 'the door working, not their stash going missing')
end)

t.test('and their belongings are still every bit there once the round is over', function()
    -- The half that makes the refusal safe rather than merely loud. Without
    -- this the test above passes on a build that refuses and then loses it.
    local server, matchId = liveMatch({ 1, 2 })

    t.isFalse((server.env.ArenaAmmo.ReturnLeftovers(1)), 'premise: refused mid-round')

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.equals(server.carrying(1), INTACT, 'a refusal mid-round cost them their belongings')
    t.equals(server.stashed(1), '', 'and the stash was not emptied')
end)

t.test('CONTROL: a player standing in the lobby is not refused, and no reason is given', function()
    -- Without this the assertions above are satisfied by a build that
    -- refuses everybody for ever.
    local server = newServer({ 1, 2 })

    local ok, _, _, why = server.env.ArenaAmmo.ReturnLeftovers(1)

    t.isTrue(ok, 'somebody who is nowhere near a round could not be settled')
    t.isNil(why, 'a clean settle came back carrying a refusal reason')
end)

-- ========================================================================
-- SENT HOME MEANS SENT HOME, INCLUDING FROM THE CAMERA
--
-- An eliminated fighter is made a SPECTATOR of the round that just put them
-- out: AddSpectator sets the flag and their client starts a camera, which
-- hides their ped. Correct while the round runs.
--
-- What was missing is the other half. Being sent home did not stop them
-- being a watcher, so `spectating` was still set in the very next state
-- broadcast -- and client/spectate.lua starts watching whatever that field
-- names. The client was told to start spectating a match it had just been
-- sent home from, and hid the player's ped again AFTER leaveArena had
-- finished putting them right. From the player's own console, one frame
-- apart:
--
--   you left the arena invisible and this resource has just put you back
--   arena scenery: 87 of 87 piece(s) built
--
-- The second line is the spectator camera building the arena to look at.
--
-- THE CLOSE ALREADY CLEARED IT, WHICH IS WHY THIS IS ABOUT ORDER. Ending a
-- match walks its spectators and clears every one -- so by the time anything
-- asks afterwards the flag is gone, and a test that only looks at the end
-- sees nothing wrong. The window that matters is between the exit being sent
-- and the match closing, because that is where a state broadcast lands.
-- ========================================================================

t.test('THE DEFECT: they are no longer watching AT THE MOMENT the exit is sent', function()
    local server, matchId = liveMatch({ 1, 2 })

    -- Eliminated, and therefore made a watcher of the round that put them out
    -- -- which is what server/match.lua does on every elimination when
    -- Config.Match.spectateOnElimination is on.
    local live = server.lobby.Get(matchId)
    t.isNotNil(live, 'premise: the match can be reached')
    t.isNotNil(live.players[2], 'premise: player 2 is in it')
    live.players[2].alive = false
    live.players[2].lives = 0

    t.isTrue(server.lobby.AddSpectator(2, matchId) == true,
        'premise: an eliminated fighter can be made a watcher')

    -- What the server believed about them at the instant it told them to go.
    local watchingWhenSentHome = nil
    server.watchClientEvents(function(name, target)
        if name == 'crimson_arena:client:exitArena' and target == 2 then
            watchingWhenSentHome = server.lobby.RemoveSpectator(2) == true
        end
    end)

    server.match.End(matchId, 'match.ended')
    server.step(8)
    server.watchClientEvents(nil)

    t.isNotNil(watchingWhenSentHome, 'the exit was never sent to that player at all')
    t.isFalse(watchingWhenSentHome,
        'they were sent home STILL FLAGGED as watching the round -- so the next state '
        .. 'broadcast tells their client to start a spectator camera, which hides their ped '
        .. 'again after everything else has finished putting them right')
end)

-- ========================================================================
-- JamReport -- WHAT THE ADMIN TABLET SHOWS, which nothing was holding
--
-- The same reading /arenaunjam prints, as lines the tablet can draw. It is
-- READ-ONLY on purpose and the tablet offers no button: clearing a jam on a
-- stash that still holds rows puts every one of them back inside the next
-- ceiling and the next exit hands them to the owner -- the exact duplication
-- the jam exists to stop. So the report has to tell a human which stashes are
-- safe to clear and which are not, and be right about it.
-- ========================================================================

t.test('with nothing held back it says so, in one line', function()
    local server = liveMatch({ 1, 2 })
    local lines = server.ammo.JamReport()

    t.equals(type(lines), 'table', 'the report was not a list of lines')
    t.equals(#lines, 1, 'a clean server produced more than the one line it needs')
    t.contains(lines[1], 'no stash is being held back',
        'a clean server did not say so: ' .. tostring(lines[1]))
end)

t.test('a held-back stash is listed, and named', function()
    local server = jammedBySurplus()
    local stashes = server.ammo.JammedStashes()
    t.isTrue(#stashes > 0, 'the fixture did not jam anything')

    local lines = server.ammo.JamReport()
    local text = table.concat(lines, '\n')

    t.isTrue(#lines > 1, 'a jammed server reported nothing beyond the header')
    for _, stash in ipairs(stashes) do
        t.contains(text, stash, 'the report did not name the stash it is about')
    end
end)

t.test('and it says which are safe to clear and which are not', function()
    -- THE WHOLE POINT. jammedBySurplus leaves rows in the stash, so the
    -- report must warn rather than invite. A human reading "empty, safe to
    -- clear" over a stash with a phone in it hands that phone out twice.
    local server = jammedBySurplus()
    local text = table.concat(server.ammo.JamReport(), '\n')

    t.contains(text, 'STILL IN IT',
        'a stash that still holds rows was not flagged: ' .. text)
    t.isTrue(text:find('empty, safe to clear', 1, true) == nil,
        'a stash with rows in it was called safe to clear: ' .. text)
end)

t.test('and it names the button, because a reading nobody can act on is half a report',
function()
    -- IT USED TO NAME `/arenaunjam`, and that command does not exist any
    -- more: clearing a hold is Clear the hold on the Stashes tab, and only
    -- that. A report still telling an operator to type a dead command is
    -- worse than one that says nothing -- they type it, nothing happens, and
    -- now they doubt the reading as well.
    --
    -- AND IT MUST NOT NAME THE DEAD ONE AGAIN, which is the half a
    -- `contains` cannot hold on its own.
    local server = jammedBySurplus()
    local text = table.concat(server.ammo.JamReport(), '\n')

    t.contains(text, 'Clear the hold',
        'the report did not say how to act on it: ' .. text)
    t.isTrue(text:find('/arenaunjam', 1, true) == nil,
        'the report sends an operator to a command that no longer exists: ' .. text)
end)

t.test('every line reaches the tablet as a string', function()
    -- The panel prints these straight out. A number or a table getting
    -- through is a screen that says "table: 0x..." to an operator already
    -- looking at a server they believe is broken.
    local server = jammedBySurplus()
    for index, line in ipairs(server.ammo.JamReport()) do
        t.equals(type(line), 'string',
            ('line %d reached the tablet as a %s'):format(index, type(line)))
    end
end)

t.test('and once the jam is cleared the report goes quiet again', function()
    local server = jammedBySurplus()
    for _, stash in ipairs(server.ammo.JammedStashes()) do
        t.isTrue(server.ammo.Unjam(stash), 'the jam would not clear')
    end

    local lines = server.ammo.JamReport()
    t.equals(#lines, 1, 'a cleared server still listed stashes')
    t.contains(lines[1], 'no stash is being held back',
        'a cleared server did not go back to saying so: ' .. tostring(lines[1]))
end)

t.test('Unjam refuses a stash it has never held back', function()
    local server = jammedBySurplus()
    for _, junk in ipairs({ 'nope', '', 'crimson_arena_CID999' }) do
        t.isFalse(server.ammo.Unjam(junk),
            'a stash that was never jammed was reported cleared: ' .. tostring(junk))
    end
    t.isTrue(#server.ammo.JammedStashes() > 0,
        'refusing an unknown stash cleared the real one')
end)

t.test('and refuses junk rather than throwing', function()
    local server = jammedBySurplus()
    for _, junk in ipairs({ 5, true, {} }) do
        local ok, cleared = pcall(server.ammo.Unjam, junk)
        t.isTrue(ok, 'Unjam threw on junk: ' .. tostring(cleared))
        t.isFalse(cleared, 'Unjam accepted junk: ' .. tostring(junk))
    end
    local ok = pcall(server.ammo.Unjam, nil)
    t.isTrue(ok, 'Unjam threw on nil')
end)

-- ========================================================================
-- AND THE JAM HAS TO OUTLIVE THE PROCESS
-- ========================================================================
--
-- A jam is a statement about a stash that STILL HAS THINGS IN IT. The
-- process forgetting it does not empty the stash: on the next start the
-- thirty-second sweep walks it again -- uncapped, because nothing after a
-- restart knows what the door put there -- and hands the parked copy to a
-- player who is already carrying the original. That is the duplication the
-- jam exists to stop, on a timer, and "wait for the nightly restart" was a
-- way to collect it.
--
-- Same reasoning, same machinery and the same OFF-BY-DEFAULT as the
-- outstanding-kit slate: with Config.Database.enabled false a jam still
-- works for one uptime and nothing is written.

local function jammedWithDatabase()
    -- BOTH HALVES, because ArenaDbReady wants the switch AND oxmysql up.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true })
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)
    t.contains(server.log(), 'touching that stash no further', 'the fixture did not jam anything')
    return server
end

t.test('THE DEFECT: a jam is written to the database, not only to memory', function()
    local server = jammedWithDatabase()

    t.contains(server.queries(), 'crimson_arena_jammed_stash',
        'the jam never reached the database, so a restart forgets it and hands out the duplicate')
    t.contains(server.queries(), 'INSERT IGNORE INTO crimson_arena_jammed_stash',
        'the jam table was touched, but not written to')
end)

t.test('and clearing it by hand takes the row with it', function()
    -- Or the next start holds the stash off again and the operator runs
    -- /arenaunjam after every restart wondering why it never takes.
    local server = jammedWithDatabase()
    local before = server.queries()
    t.isNil(before:find('DELETE FROM crimson_arena_jammed_stash', 1, true),
        'something deleted the jam row before the operator asked')

    t.isTrue(server.ammo.Unjam('crimson_arena_CID1'), 'the jam did not clear')

    t.contains(server.queries(), 'DELETE FROM crimson_arena_jammed_stash',
        'the jam cleared in memory only, so the next start puts it back')
end)

t.test('CONTROL: with the database off nothing is written, and the jam still holds', function()
    -- The shipped default. Nothing to import, nothing required -- and the
    -- jam must still stop the door for the length of this uptime.
    local server = jammedBySurplus()

    t.isNil(server.queries():find('crimson_arena_jammed_stash', 1, true),
        'the database is off and the jam was written to it anyway')
    t.equals(jamsStanding(server), 1, 'the jam did not hold with the database off')
end)

t.test('THE DEFECT: a jam from before the restart is read back, and the door stays off that stash',
function()
    -- THE WHOLE POINT. A fresh process, a table that already names this
    -- stash, and the door must not touch it -- the copy parked in there is
    -- one the player is already carrying.
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = true, jamRows = { 'crimson_arena_CID1' } })

    t.equals(jamsStanding(server), 0, 'the jam was in memory before anything read it')

    server.ammo.LoadJams()
    server.step(2)

    t.equals(jamsStanding(server), 1,
        'A JAM FROM BEFORE THE RESTART WAS FORGOTTEN -- the sweep will hand out the parked copy')
    t.contains(server.log(), 'still held back from before the restart',
        'the operator was never told there is a stash needing settling by hand')
end)

t.test('and the door refuses to hand anything back until that list has been read', function()
    -- THE RACE, and it is a real one: the sweep runs every thirty seconds
    -- and does not wait for anybody. Before the read lands `jammedStash` is
    -- empty, which reads exactly like "nothing is jammed" -- so without this
    -- the first sweep after a start could hand out the very duplicate the
    -- jam was parked to stop, a second before the list arrived to say so.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, holdJamRead = true })

    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.contains(server.log(), 'until the jam list has been read back',
        'the door handed belongings back before it knew which stashes were held')
end)

t.test('CONTROL: with the database off the door does not wait for a list that will never come',
function()
    -- The shipped default. Nothing was ever persisted, so there is nothing
    -- to wait for -- and waiting would shut the door on every server that
    -- never turned the database on.
    local server, matchId = liveMatch({ 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.isNil(server.log():find('until the jam list has been read back', 1, true),
        'the door held itself off on a server with no database at all')
    t.isTrue(server.carrying(1):find('phone', 1, true) ~= nil,
        'the player never got their belongings back')
end)

t.test('and the wait for that list is BOUNDED -- the door reopens rather than shutting for ever',
function()
    -- THE FAILURE THIS MUST NOT HAVE. The guard above refuses hand-backs
    -- until the jam list is read. A database user with CREATE but no SELECT
    -- never answers that read -- so an unbounded wait would shut the door on
    -- every player for the whole uptime, and this file's own rule is that
    -- "the arena did not work properly" is acceptable and leaving somebody
    -- unable to get their things back is not.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, holdJamRead = true })

    server.match.End(matchId, 'match.ended')
    server.step(8)
    t.contains(server.log(), 'until the jam list has been read back',
        'the door did not hold at all, so there is no wait to bound')
    t.isNil(server.carrying(1):find('phone', 1, true),
        'the hand-back went through while the list was unread')

    -- Past the grace, with the read still out there and never coming.
    server.advanceClock(61)
    for _ = 1, 6 do server.ammo.SweepReturns() end
    server.step(8)

    t.contains(server.log(), 'going ahead without it',
        'the door never gave up on a list that is never coming')
    t.isTrue(server.carrying(1):find('phone', 1, true) ~= nil,
        'THE DOOR STAYED SHUT FOR EVER -- the player cannot get their own belongings back')
end)

t.test('AND THE TABLET STOPS PROMISING A HOLD THE DOOR HAS ABANDONED', function()
    -- THE REPORT WAS STILL SAYING "the door is holding hand-backs until it
    -- lands" LONG AFTER IT HAD STOPPED.
    --
    -- That sentence is true only for the grace above. Past it the door sets
    -- jamWaitGaveUp, logs "going ahead without it", and resumes handing
    -- belongings back with NO list at all -- and on a database whose SELECT
    -- is refused, `known` stays false for the entire uptime, so the sentence
    -- never changed.
    --
    -- WHAT AN ADMIN DOES WITH IT. They read that nobody's belongings are
    -- moving and nothing can be handed out twice, and let the database wait
    -- until morning. The test above proves that by then the stash HAS been
    -- handed out -- so the tablet is telling them the opposite of what the
    -- door is doing, on the one screen they would use to decide.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, holdJamRead = true })

    -- WHILE IT REALLY IS HOLDING, which is the control: without it this
    -- passes against a report that never mentions holding at all.
    server.match.End(matchId, 'match.ended')
    server.step(8)
    local waiting = table.concat(server.ammo.JamReport(), '\n')
    t.contains(waiting, 'NOT been read back',
        'the report did not say the list was unread while it was unread')
    t.notContains(waiting, 'STOPPED WAITING',
        'the report said the door had given up while it was still holding')
    t.notContains(waiting, 'A SECOND TIME',
        'the report warned about double hand-backs while the door was still holding')

    -- Past the grace, with the read still never coming.
    server.advanceClock(61)
    for _ = 1, 6 do server.ammo.SweepReturns() end
    server.step(8)

    local gaveUp = table.concat(server.ammo.JamReport(), '\n')
    t.contains(gaveUp, 'STOPPED WAITING',
        'the tablet still promised a hold the door had abandoned minutes earlier')
    t.contains(gaveUp, 'A SECOND TIME',
        'the tablet did not warn that a stash from before the restart can be handed out twice')
end)

t.test('AND A LIST THAT IS NOT THE WHOLE LIST SAYS SO, rather than reading as complete', function()
    -- THE EMPTY BRANCH SAYS ALL THIS AT LENGTH AND THE NON-EMPTY ONE SAID
    -- NOTHING. `known` is false whenever the jam list was never read back --
    -- but the moment ONE hold exists this run, the report printed a tidy
    -- list of it with no caveat at all.
    --
    -- A list of one stash then reads as the complete set of things to
    -- settle. The holds made BEFORE the restart -- the ones with a player's
    -- kit parked in them -- are missing from it, are not being held back by
    -- this run either, and are being walked by the sweep. The admin settles
    -- the one they can see and stops looking.
    --
    -- IT IS WORSE THAN THE EMPTY CASE, not better: an empty report at least
    -- invites suspicion. A report with a real stash on it has just proved it
    -- works.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, holdJamRead = true })

    -- THE ORDER HERE IS THE TEST. stow() records how many rows the door
    -- itself left in the stash, and anything already sitting there when it
    -- looks is counted INSIDE that ceiling on purpose. So the surplus has to
    -- appear AFTER the door has shut the stash, which is exactly when it
    -- really appears -- ox_inventory reloading an idle stash from a row that
    -- never got its last write.
    server.match.End(matchId, 'match.ended')
    server.step(8)
    t.contains(server.log(), 'until the jam list has been read back',
        'the door did not hold at all, so there is no unread list to be incomplete about')

    server.stashItem('crimson_arena_CID1', 'phone', 9)

    -- Past the grace, with the read still never coming: the door gives up,
    -- looks at the stash, finds more in it than it put there, and jams it.
    -- That is the only state where the list is non-empty AND unread at once.
    -- THROUGH Reclaim, NOT SweepReturns. The sweep's hand-back is UNCAPPED
    -- on purpose -- after a restart nothing knows what went into a stash, and
    -- a ceiling of zero there would refuse a player their whole kit -- so it
    -- would hand the surplus straight over and jam nothing. The ceiling lives
    -- on the exit path, which keeps the record of what the door put in.
    server.advanceClock(61)
    server.ammo.Reclaim(1, 'match.ended')
    server.step(8)

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.contains(report, 'are being held back',
        'no hold was made this run, so this proves nothing about a non-empty list')
    t.contains(report, 'ONLY THE HOLDS THIS RUN MADE',
        'a jam list that is missing every hold from before the restart was printed as though '
        .. 'it were the complete set of things to settle')
end)

t.test('DEFECT: with the database ON and oxmysql DOWN, an empty list is not reported as fact', function()
    -- THE CASE THE `known` FLAG WAS INVENTED FOR, ANSWERED "known".
    --
    -- `known` read `jamsLoaded or not ArenaDbReady('the jam list')`, and
    -- ArenaDbReady answers false for two completely different facts:
    -- Config.Database.enabled being off (nothing was EVER persisted, so an
    -- empty list is a complete answer) and the switch being ON while oxmysql
    -- is not started (the table exists, may hold holds from before this
    -- restart, and this run has read none of it). The second was being
    -- reported as the first.
    --
    -- And the door does not hold on that path either: handBack's grace is
    -- gated on the same ArenaDbReady, so with oxmysql down it goes straight
    -- through without the list. So the sweep walks those stashes and can hand
    -- a player a second copy of something they already carry, while the
    -- tablet says, as fact, that no stash is being held back. That is the
    -- exact pairing the flag exists to prevent, reached through a different
    -- door.
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = false, jamRows = { 'crimson_arena_CIDOLD' } })

    server.startResource()
    server.step(2)

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.notContains(report, 'no stash is being held back',
        'the database is switched ON and oxmysql is not running, so this run has read nothing '
        .. 'of the hold list -- and the tablet reported an empty list as fact')
    t.contains(report, 'NOT been read back',
        'the report did not say the list is unread, so an admin is told there is nothing to '
        .. 'settle while the sweep is walking holds from before the restart')

    -- AND IT MUST NOT PROMISE A HOLD THE DOOR NEVER MAKES. handBack's grace
    -- is gated on ArenaDbReady, so with oxmysql not started it skips the wait
    -- and hands back from the first sweep. The unread branch used to say "The
    -- door is holding hand-backs for up to 60 seconds" in exactly this state.
    t.notContains(report, 'door is holding hand-backs',
        'the report promised a 60-second hold on the one path where the door never waits at '
        .. 'all -- the admin believes nothing is moving while the sweep hands stashes out')
    t.contains(report, 'is NOT waiting for it',
        'the report did not say the door is going ahead without the list')
end)

t.test('and a hold made THIS RUN is still marked on the tablet with the list unread', function()
    -- THE CONSEQUENCE OF THAT FLAG NOBODY TRACED. IsJammed's and
    -- JammedStashes' second return feeds jamsKnown(), and the tablet ANDed it
    -- into every per-row hold mark: `entry.jammed === true &&
    -- admin.jamsKnown === true`. That was harmless while the flag was only
    -- false for the first seconds after a start, because jammedStash is empty
    -- then and entry.jammed was false anyway.
    --
    -- Making the flag answer false for a LONG-LIVED state -- the database
    -- switched on with oxmysql not running -- broke that: holds this run made
    -- are in memory, the door is refusing them, and every one of their marks
    -- was un-drawn while the hand-back button came back for a stash the
    -- server will refuse. An unread list can only make us MISS a hold, never
    -- invent one, so the FIRST return is authoritative on its own.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = false })

    server.startResource()
    server.step(2)
    server.stashItem('crimson_arena_CID1', 'phone', 9)
    server.match.End(matchId, 'match.ended')
    server.step(8)
    server.advanceClock(61)
    server.ammo.Reclaim(1, 'match.ended')
    server.step(8)

    local jammed, known = server.ammo.IsJammed('crimson_arena_CID1')
    t.isTrue(jammed,
        'no hold was made this run, so this proves nothing about drawing one')
    t.isFalse(known,
        'the list was reported as complete while oxmysql is down, which is the other defect')

    -- The tablet must be able to draw this. It reads the FIRST return through
    -- stashHeldBack; the AND on the second return is what the app.js note now
    -- forbids.
    local app = assert(io.open('../Crimson-Arena/html/app.js', 'r'))
    local text = app:read('a')
    app:close()
    t.isNil(text:find('entry.jammed === true && admin.jamsKnown === true', 1, true),
        'the tablet still ANDs a live hold mark against the list-complete flag, so a stash the '
        .. 'door is refusing right now is drawn as free and its hand-back button is offered')
end)

t.test('CONTROL: and with no database at all an empty list IS reported as fact', function()
    -- The other side, and the reason the fix cannot simply hedge whenever
    -- ArenaDbReady is false. On the SHIPPED default nothing was ever
    -- persisted, so an empty list is a complete answer -- hedging it would
    -- put a permanent "not read back yet" on the majority of installs, which
    -- is a new false alarm in place of a correct answer.
    local server = newServer({ 1, 2 })

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.contains(report, 'no stash is being held back',
        'a server that never persisted anything was told its hold list is unknown')
    t.notContains(report, 'NOT been read back',
        'a server with no database was told to go and read a table it does not have')
end)

t.test('and that empty answer says WHY, because "none" only ever held for this run', function()
    -- THE HALF THE `known` FLAG SETTLES IN CODE AND NEVER SHOWS ANYBODY.
    --
    -- jamListIsKnown answers `known` on the switched-off path because an
    -- empty list really is the complete answer FOR THIS RUN. That is right,
    -- and the control above is why: hedging it would put a permanent "not
    -- read back yet" on the majority of installs. But the operator reading
    -- the screen got a flat "no stash is being held back" out of it.
    --
    -- Nothing deletes crimson_arena_jammed_stash when the switch goes off --
    -- the only DROP TABLE in the tree is in sql/uninstall.sql, which somebody
    -- runs deliberately. So a server that ran with the database ON, held a
    -- stash back, and then switched it off reads that flat sentence over a
    -- stored list nobody will ever look at, while the door hands those
    -- stashes out again: the same cost the oxmysql branch spells out at
    -- length, on a path that said nothing at all.
    --
    -- NOT A HEDGE, which is the distinction that makes this safe to add. It
    -- does not say "we cannot tell" -- with the switch off this run genuinely
    -- holds nothing back, and the sentence still says so first. What follows
    -- is what the switch MEANS, true on every such install, fresh or not.
    local server = newServer({ 1, 2 })

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.contains(report, 'no stash is being held back in this run',
        'the report did not answer the question before qualifying it')
    t.contains(report, 'Config.Database.enabled is off',
        'the report never named the setting that makes the answer good for one uptime only')
    t.contains(report, 'CAN BE HANDED OUT A SECOND TIME',
        'the report named the setting without saying what it costs, which is the half an '
        .. 'operator acts on')
    t.notContains(report, 'NOT been read back',
        'the switched-off path was given the unread-list hedge the control above forbids')

    -- AND THE MIRROR, so this cannot be satisfied by a caveat on every list.
    -- A database that is on and HAS been read back says none of it.
    local healthy = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = true, jamRows = {} })

    healthy.startResource()
    healthy.step(4)
    local said = table.concat(healthy.ammo.JamReport(), '\n')

    t.contains(said, 'no stash is being held back',
        'a healthy database with an empty list did not report it as empty')
    t.notContains(said, 'Config.Database.enabled is off',
        'a server that IS persisting was told it is not')
    t.notContains(said, 'CAN BE HANDED OUT A SECOND TIME',
        'a list that was really read back carried the switched-off warning, which teaches an '
        .. 'operator to read past the one line that matters')
end)

t.test('CONTROL: and a list read back from a healthy database carries no such caveat', function()
    -- A caveat on every list would teach the admin to ignore it.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, jamRows = {} })

    server.startResource()
    server.step(2)
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.contains(report, 'are being held back', 'no hold was made, so this proves nothing')
    t.notContains(report, 'ONLY THE HOLDS THIS RUN MADE',
        'a list that WAS read back was reported as incomplete')
end)

-- ========================================================================
-- AND THE DIAGNOSTIC MUST NOT BURY THE LOG IT IS PRINTED IN
-- ========================================================================
--
-- The line above is a diagnostic: it prints the foreign metadata an item
-- carried on the way in, so an operator can compare it with the way out and
-- see whether a key CHANGED. `bagId` is what it was written for.
--
-- But a foreign key can be enormous. `id_card` carries `mugShot`, a base64
-- PNG data URI of about four kilobytes, and this printed all of it -- twice
-- per item, for every player, every round. Seen on the owner's own server:
-- one 1v1 put roughly sixteen kilobytes of base64 through the console and
-- made the rest of the round unreadable.
--
-- Cutting it is not enough on its own, and that is the trap: two DIFFERENT
-- four-kilobyte mugshots share their first 48 characters, so a bare
-- truncation would have left the line looking identical whether the value
-- changed or not -- a diagnostic that always says "unchanged" is worse than
-- none. So a long value keeps its head, its length and a hash of the whole
-- string.

--- A long value whose first 48 characters are IDENTICAL whatever `tail` is.
---
--- The difference has to sit past the cut or the test is not testing the cut:
--- two mugshots that differ in their first few bytes survive a bare
--- truncation and the assertion below passes without the hash doing anything.
--- Real base64 PNGs of the same size share a long header exactly like this.
local function longMeta(tail)
    return 'data:image/png;base64,' .. string.rep('iVBORw0KGgoA', 400) .. (tail or '')
end

t.test('THE DEFECT: a four-kilobyte mugshot does not go through the console whole', function()
    local server = newServer({ 1, 2 }, nil, {
        { name = 'id_card', count = 1, metadata = { citizenid = 'CID1', mugShot = longMeta('AAAA') } },
    })

    local matchId = bagRound(server, { 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(12)

    for _, line in ipairs(server.lines) do
        t.isTrue(#line < 800,
            ('a %d-character line reached the console log -- the metadata dump is unbounded'):format(#line))
    end
end)

t.test('and the short keys it was written for are still printed whole', function()
    -- `bagId` is the entire reason this line exists. Summarising THAT would
    -- answer the question it was added to answer with a hash nobody can act on.
    local server = newServer({ 1, 2 }, nil, {
        { name = 'leo_bag', count = 1, metadata = { bagId = 'CID1-LEO-7' } },
    })

    local matchId = bagRound(server, { 1, 2 })
    server.match.End(matchId, 'match.ended')
    server.step(12)

    t.contains(server.log(), 'bagId=CID1-LEO-7',
        'the id the whole diagnostic exists to show was cut or summarised')
end)

t.test('and two DIFFERENT long values still read differently', function()
    -- The property a bare truncation would have destroyed. Same length, same
    -- first 48 characters, different content -- the line has to tell them
    -- apart or it cannot answer "did this key change".
    local a = newServer({ 1, 2 }, nil, {
        { name = 'id_card', count = 1, metadata = { mugShot = longMeta('AAAA') } },
    })
    local b = newServer({ 1, 2 }, nil, {
        { name = 'id_card', count = 1, metadata = { mugShot = longMeta('BBBB') } },
    })

    for _, server in ipairs({ a, b }) do
        local matchId = bagRound(server, { 1, 2 })
        server.match.End(matchId, 'match.ended')
        server.step(12)
    end

    local function shotLine(server)
        for _, line in ipairs(server.lines) do
            local found = line:match('mugShot=(%S+)')
            if found then return found end
        end
        return nil
    end

    local first, second = shotLine(a), shotLine(b)
    t.isNotNil(first, 'no mugShot line was printed at all, so this proves nothing')
    t.isNotNil(second, 'no mugShot line was printed for the second value')
    t.isTrue(first ~= second,
        'TWO DIFFERENT MUGSHOTS PRINTED IDENTICALLY -- the line can no longer show that a key changed')
end)

t.test('THE DEFECT: the jam list is read back at START-UP, not only from the sweep', function()
    -- It was reachable only from ArenaAmmo.SweepReturns -- the thirty-second
    -- retry. So the read began up to thirty seconds late, and on a server
    -- with returnRetrySeconds = 0 the sweep never runs at all and nothing
    -- ever dispatched it. Meanwhile the door holds every hand-back waiting
    -- for that read and then gives up after a minute blaming a missing
    -- SELECT grant -- which on those servers was a lie: nobody had asked the
    -- database anything.
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
        config.Loadouts.inventory.returnRetrySeconds = 0
    end, nil, { database = true, jamRows = { 'crimson_arena_CID1' } })

    t.equals(jamsStanding(server), 0, 'the jam was already in memory before anything read it')

    server.startResource()
    server.step(2)

    t.equals(jamsStanding(server), 1,
        'START-UP DID NOT READ THE JAM LIST -- with the sweep off, nothing ever does')
end)

t.test('and an empty jam list nobody has read is not reported as "none"', function()
    -- Two completely different causes print the same sentence otherwise:
    -- nothing is jammed, or the read that would say so never landed. On a
    -- database whose SELECT is refused, the operator was told there was
    -- nothing to settle for the whole uptime, while the door refused every
    -- hand-back waiting for the same read.
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = true, holdJamRead = true })

    local report = table.concat(server.ammo.JamReport(), '\n')

    t.notContains(report, 'no stash is being held back',
        'an unread list was reported as an empty one')
    t.contains(report, 'NOT been read back',
        'the report did not say that it cannot answer yet')
end)

t.test('CONTROL: and once it HAS been read, an empty list is reported as none', function()
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = true, jamRows = {} })

    server.startResource()
    server.step(2)

    local report = table.concat(server.ammo.JamReport(), '\n')
    t.contains(report, 'no stash is being held back',
        'a list that was read and really is empty was reported as unknown')
end)

t.test('CONTROL: with no database at all the report still says none, not unknown', function()
    -- The shipped default. Nothing was ever persisted, so an empty list is a
    -- real answer and must not be hedged.
    local server = newServer({ 1, 2 })
    local report = table.concat(server.ammo.JamReport(), '\n')
    t.contains(report, 'no stash is being held back',
        'a server with no database was told its jam list is unknown')
end)

t.test('THE INERT KNOB: a database that refuses every statement is a real case now', function()
    -- `opts.dbFails` has been in this fixture, documented, since before the
    -- jam list existed -- and nothing ever set it, because it could not
    -- work: `opts.dbFails and nil or {}` always answered {}. So the option
    -- that models "the database is connected and every statement is refused"
    -- has never once been exercised. This is the test that turns it.
    local server = newServer({ 1, 2 }, function(config)
        config.Database.enabled = true
    end, nil, { database = true, dbFails = true })

    server.startResource()
    server.step(2)

    -- The read is refused, so the list is unread -- and the report must say
    -- that rather than claiming there is nothing to settle.
    local report = table.concat(server.ammo.JamReport(), '\n')
    t.contains(report, 'NOT been read back',
        'a database refusing every statement was reported as an empty jam list')
end)

t.test('and a jam made on a SELECT-only user warns that a restart forgets it', function()
    -- READS LAND, WRITES DO NOT, which is the setup an operator really has
    -- when they grant SELECT and forget the rest. `dbFails` cannot show this:
    -- with the read refused too, the door holds every hand-back waiting for
    -- the jam list and no jam is ever reached -- correct behaviour, and the
    -- reason this needed its own knob.
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, jamRows = {}, failWrites = true })

    server.startResource()
    server.step(2)

    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.contains(server.log(), 'touching that stash no further', 'the fixture did not jam anything')
    t.contains(server.log(), 'could NOT be written to the database',
        'the jam held for this run but the operator was never told a restart forgets it')
end)

t.test('CONTROL: and with the database healthy neither line appears', function()
    local server, matchId = liveMatch({ 1, 2 }, nil, function(config)
        config.Database.enabled = true
    end, { database = true, jamRows = {} })

    server.startResource()
    server.stashItem('crimson_arena_CID1', 'phone', 1)
    server.match.End(matchId, 'match.ended')
    server.step(8)

    t.isNil(server.log():find('could NOT be written to the database', 1, true),
        'a healthy database was reported as unwritable')
    local report = table.concat(server.ammo.JamReport(), '\n')
    t.isNil(report:find('NOT been read back', 1, true),
        'a list that was read back was reported as unread')
end)

os.exit(t.summary())
