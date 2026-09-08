--[[
    crimson_arena/tests/gungame_spec.lua

    GUN GAME: THE LADDER, PLAYED.

    THE MODE IN ONE PARAGRAPH. Nobody is eliminated: a death costs a TIER and
    nothing else, and the round ends when the mode's own clock runs out or
    when somebody tops the ladder. Every kill carries you one tier up and
    hands you that tier's weapon; every death carries you one back down and
    takes it away. The ladder itself is DRAWN -- config gives ordered pools,
    melee first, and one weapon comes out of each when the round starts -- so
    the shape is learnable and the guns are not.

    THE MODE SHIPS OFF, so almost none of this runs on a default server --
    which is exactly why it needs its own file. A mode nobody tests is a mode
    that breaks the first time an operator turns it on, and "setting this to
    true is the whole of turning it on" is a promise config.lua makes.

    THE REAL server/ammo.lua RUNS IN THIS FILE, against a fake ox_inventory
    that keeps real pockets. The previous version of this spec stubbed
    ArenaAmmo out and asserted against the stub -- so overwriting ammo.lua
    with garbage still passed fifteen out of fifteen, and the one test that
    claimed to prove "the weapon really swaps" proved only that the spec's
    own table had been appended to. The item IS the weapon on an ox server:
    a promotion that does not reach a real inventory is a promotion that
    changed nothing a player can hold.

    FORTY-FOUR TESTS, on deliberately different parts of it:

      THE DRAW         one weapon per tier, melee first, stable all round,
                       different between rounds, and short pools survived.
      CLIMBING         score to tier derived rather than counted, the top
                       tier, and no free re-issue for standing still.
      FALLING          every death costs a tier whoever caused it, the floor
                       at tier 1, and that kills are never edited.
      THE CAP          one victim cannot be farmed for a whole ladder.
      THE REWARD       bandages every kill, armour on a roll, and neither
                       paid for an uncredited one.
      THE ROUND        the mode's own clock, no eliminations, the tier on
                       the wire, and who the clock crowns.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('gungame_spec')

local IDS = { 1, 2, 3, 4, 5, 6 }

--- The seed the next server that does not name one will use.
---
--- EVERY SERVER IS SEEDED, AND THAT IS THE POINT. `math.randomseed` is
--- global: two tests here name a seed of their own, and every test that ran
--- AFTER one of them was quietly climbing whatever stream that seed had left
--- behind. Seventy ladders were drawn in a run of this file and exactly one
--- of them -- the first -- varied between processes; the other sixty-nine
--- were hard-wired, for ever, by a number written in a different test.
---
--- The file was green because of it rather than in spite of it. Changing one
--- loop bound in a test that shares no state with any other -- 12 rounds to
--- 11, or to 13 -- turned the file red, because it moved the stream every
--- later test was standing in.
---
--- So the coupling is removed rather than tuned around: a test that names a
--- seed gets that seed, and a test that does not gets its own from this
--- counter. No test's ladder can depend on which tests ran before it, and
--- every failure is still reproducible by re-running the file.
local nextSeed = 90000

--- Sweeps many ladders rather than trusting one draw, for the properties
--- that have to hold for EVERY ladder the config can produce.
--- @param count integer
--- @param body fun(seed: integer)
local function overManyLadders(count, body)
    for index = 1, count do body(70000 + index * 13) end
end

--- A fake ox_inventory with real pockets.
---
--- IT REFUSES THE WAY THE REAL ONE DOES, which is the only reason it is
--- worth having: ox_inventory answers `false` rather than throwing, and it
--- refuses a removal it cannot satisfy IN FULL rather than taking what is
--- there. Both of those are load-bearing in server/ammo.lua and neither is
--- observable against a double that always says yes.
local function newInventory()
    local ox = { pockets = {}, refuseAdd = {} }

    local function bag(src)
        ox.pockets[src] = ox.pockets[src] or {}
        return ox.pockets[src]
    end

    function ox:AddItem(src, item, count, metadata)
        if ox.refuseAdd[item] then return false end
        local held = bag(src)
        held[#held + 1] = { name = item, count = count or 1, metadata = metadata }
        return true
    end

    function ox:RemoveItem(src, item, count)
        local held = bag(src)
        local want = count or 1
        local have = 0
        for _, row in ipairs(held) do
            if row.name == item then have = have + (row.count or 1) end
        end
        -- IN FULL OR NOT AT ALL.
        if have < want then return false end
        for index = #held, 1, -1 do
            if want <= 0 then break end
            if held[index].name == item then
                want = want - (held[index].count or 1)
                table.remove(held, index)
            end
        end
        return true
    end

    function ox:GetItemCount(src, item)
        local total = 0
        for _, row in ipairs(bag(src)) do
            if row.name == item then total = total + (row.count or 1) end
        end
        return total
    end

    function ox:GetInventoryItems(src) return bag(src) end
    function ox:ClearInventory(src) ox.pockets[src] = {} end
    function ox:RegisterStash() return true end
    function ox:registerHook() return true end

    --- Every item name one player is holding, sorted, as one string.
    function ox.holding(src)
        local names = {}
        for _, row in ipairs(ox.pockets[src] or {}) do names[#names + 1] = row.name end
        table.sort(names)
        return table.concat(names, ',')
    end

    --- How many of one item a player holds.
    function ox.count(src, item)
        local total = 0
        for _, row in ipairs(ox.pockets[src] or {}) do
            if row.name == item then total = total + (row.count or 1) end
        end
        return total
    end

    --- The metadata of the newest copy of one item, or nil.
    function ox.metaOf(src, item)
        for index = #(ox.pockets[src] or {}), 1, -1 do
            local row = ox.pockets[src][index]
            if row.name == item then return row.metadata end
        end
        return nil
    end

    return ox
end

--- A server with gun game switched ON, which no shipped config does.
--- @param mutate fun(config: table)?
--- @param seed integer? -- what math.randomseed is set to before the ladder
---        is drawn, so a test can name the ladder it wants. LEAVING IT OUT
---        DOES NOT MEAN "unseeded": see `nextSeed` below.
--- @param opts table? -- { noInventory = true } to run the whole server as
---        one WITHOUT ox_inventory started, which is the `no-inventory`
---        answer ArenaAmmo.SwapWeapon gives and a path nothing had reached;
---        { positions = t } to place bodies, so a test can put two players
---        far enough apart that the kill claim between them is refused
--- A seven-tier ladder, pinned.
---
--- THE SHIPPED LADDER IS THIRTY TIERS, and a great many tests below are not
--- about its height at all: they are about what happens at the TOP of a
--- ladder, or about the arithmetic of the per-victim cap, and both need one
--- short enough for a six-player lobby to climb. They used to get that by
--- accident -- the shipped ladder happened to be seven -- so raising it to
--- thirty broke six tests that had nothing to do with the change.
---
--- Pinned here instead, so an operator's tier list (and it IS an operator's
--- call; it has been changed once already) cannot silently rewrite what
--- these tests measure. The tests that ARE about the shipped ladder read
--- `tierCount()` and say so.
local SEVEN_TIERS = {
    { 'knife' }, { 'pistol' }, { 'combatpistol' }, { 'heavypistol' },
    { 'pistol50' }, { 'revolver' }, { 'appistol' },
}

--- Pins a gun game to one exact ladder, written out pool by pool.
---
--- CLEARS THE CLASSES AS WELL, and that is the whole reason this is a
--- function rather than one assignment. The shipped ladder is composed from
--- weapon CLASSES now -- melee, sidearms, and up, each with a rung count the
--- host can shape in the creation menu -- and Arena.LadderTiersFor reads the
--- classes first, falling back to a flat `gunGameTiers` only when there are
--- none. So setting `gunGameTiers` alone changes nothing at all: the mode
--- still has its classes, still builds the thirty-rung ladder from them, and
--- a test asserting on a three-tier ladder measures the shipped one instead.
---
--- Every test below that wants a ladder of its own goes through here, so
--- there is one place that knows both halves of that.
--- @param config table
--- @param pools table -- a list of tiers, each a list of weapon keys
local function pinLadder(config, pools)
    config.Modes.gungame.gunGameClasses = nil
    config.Modes.gungame.gunGameTiers = pools
end

local function sevenTiers(config)
    pinLadder(config, SEVEN_TIERS)
    -- AND THE CAP IS PINNED TOO, for the same reason the ladder is.
    --
    -- The shipped value is an operator's choice and this server ships it OFF
    -- -- a gun game there is meant to be winnable head to head. Every test
    -- below is about the RULE rather than about that choice, so it names the
    -- number it is reasoning with instead of reading whatever config happens
    -- to say. Read from config, all of them turned into assertions about a
    -- setting nobody had changed.
    config.Modes.gungame.maxTiersPerVictim = 2
end

local function newServer(mutate, seed, opts)
    opts = opts or {}
    local players = {}
    for _, id in ipairs(IDS) do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = 50000, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console, sent, netEvents = {}, {}, {}
    local clock = 0
    local ox = newInventory()

    -- THE REAL ammo.lua REACHES ox_inventory THROUGH THESE TWO, so this is
    -- where the double is plugged in rather than over ArenaAmmo itself.
    local exportTable = setmetatable({ ox_inventory = ox }, {
        __index = function(_, key) return qbx.exports[key] end,
    })

    local env = Sandbox.newArenaEnv({
        exports = exportTable,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        GetResourceState = function(name)
            if name == 'ox_inventory' and not opts.noInventory then return 'started' end
            return 'missing'
        end,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayers = function() return { '1', '2', '3', '4', '5', '6' } end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            -- A TEST MAY PLACE THE BODIES. `opts.positions[src] = nil` is a
            -- ped the server cannot see, which resolveKiller is documented
            -- to fail OPEN on -- so the absence has to be reachable too.
            if opts.positions then return opts.positions[tonumber(ped) or -1] end
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return true end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    -- THE SWITCH THIS WHOLE FILE IS ABOUT.
    env.Config.Modes.gungame.enabled = true
    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Match.lives = 3
    env.Config.Betting.enabled = false
    -- THE DOOR OFF, so the fake pockets below hold what the arena issued and
    -- nothing else -- with it on, `restore` clears the inventory wholesale
    -- and every weapon assertion in this file would read an empty bag.
    --
    -- THE PATH IS `Loadouts.inventory.stripOnEntry`. This file used to write
    -- `Loadouts.stripOnEntry`, which nothing reads: the door was ON for
    -- every test here and the comment above it was false. It passed only
    -- because these fighters walk in with empty pockets, so the door had
    -- nothing to take -- which is precisely a fixture agreeing with itself.
    env.Config.Loadouts.inventory = env.Config.Loadouts.inventory or {}
    env.Config.Loadouts.inventory.stripOnEntry = false
    if mutate then mutate(env.Config) end

    -- ammo.lua FIRST, because match.lua calls into it.
    for _, file in ipairs({ 'util', 'ammo', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    -- HOW MANY TIMES THE ROUND WAS STARTED, counted rather than assumed --
    -- see server.play. A double start is invisible in every assertion below
    -- except this one, because it doubles what it issues instead of
    -- changing it.
    local started = 0
    local realStart = env.ArenaMatch.Start
    env.ArenaMatch.Start = function(...)
        started = started + 1
        return realStart(...)
    end

    local server = { env = env, config = env.Config, ox = ox, console = console,
        lobby = env.ArenaLobby, match = env.ArenaMatch, arena = env.Arena,
        ammo = env.ArenaAmmo }
    local matchId

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    --- Opens and starts a gun game with `count` fighters.
    --- @param count integer -- how many fighters take a seat
    --- @param modeKey string? -- 'gungame' unless a test says otherwise. The
    ---        ladder machinery is what this file is about, but a few tests
    ---        below are about what a NON-ladder mode does differently, and
    ---        they need the same real ox_inventory behind them.
    --- @param before fun()? -- run with everybody seated and the lobby still
    ---        open, which is the only moment a loadout may be picked:
    ---        ArenaLobby.SetLoadout refuses one on a live match, so a test
    ---        that picks after `play` returns is silently picking nothing.
    function server.play(count, modeKey, before)
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey or 'gungame', entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do server.fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        -- SEEDED BEFORE THE ROUND STARTS, ALWAYS. A test that names a seed
        -- gets that ladder; one that does not gets its own rather than
        -- inheriting whatever an earlier test left in the global stream.
        nextSeed = nextSeed + 7
        math.randomseed(seed or nextSeed)

        -- READYING UP IS WHAT STARTS IT, and that is the only thing that
        -- does. `autoStartWhenAllReady` ships on, so the last setReady
        -- queues Begin's countdown thread and that thread calls Start.
        --
        -- THIS FILE USED TO CALL Start ITSELF AS WELL. ArenaMatch.Start
        -- accepts a second call while the state is still 'countdown', so
        -- every match in this file started TWICE: two ladders drawn, two
        -- loadouts issued, two sets of supplies, and the first draw's weapon
        -- orphaned in the bag with the arena's books overwritten. Production
        -- has one call site and it is Begin's guarded thread. Every
        -- inventory count below was being read against a doubled kit, which
        -- would have hidden a weapon the swap failed to take back.
        if before then before() end

        for src = 1, count do server.fire('setReady', src, { ready = true }) end
        for _ = 1, 4 do
            if server.lobby.Get(matchId).state == 'live' then break end
            threads.step()
        end

        assert(server.lobby.Get(matchId).state == 'live',
            'the fixture failed to start the match through the ready path')
        assert(started == 1, ('the match started %d times, not once'):format(started))
        return matchId
    end

    --- Runs the pending CreateThread bodies -- the respawn thread, chiefly.
    function server.step(times)
        for _ = 1, (times or 4) do threads.step() end
    end

    function server.row(src) return server.lobby.Get(matchId).players[src] end
    function server.match_() return server.lobby.Get(matchId) end

    --- The drawn ladder, as weapon keys.
    function server.ladder()
        local out = {}
        for _, weapon in ipairs(server.lobby.Get(matchId).ladder or {}) do
            out[#out + 1] = weapon.key
        end
        return out
    end

    function server.kill(victim, killer) server.match.OnDeath(victim, killer) end

    --- Puts a fighter back on their feet, the way the scheduled respawn
    --- does. OnDeath refuses a victim who is not alive -- correctly -- so a
    --- test that kills the same player twice without this delivers only the
    --- first blow and quietly proves nothing about the second.
    function server.revive(src) server.row(src).alive = true end

    --- Kills somebody and lets the REAL respawn thread put them back up,
    --- rather than standing them up by hand.
    ---
    --- `server.revive` sets `alive = true` directly, and scheduleRespawn's
    --- body begins `if not entry or entry.alive then return end` -- so every
    --- test that used revive left the respawn path unexecuted. It was called
    --- a hundred and sixteen times in one run of this file and its body ran
    --- zero times, which is why deleting the line that puts a respawning
    --- climber back on their own tier changed nothing here.
    function server.dieAndRespawn(victim, killer)
        server.kill(victim, killer)
        for _ = 1, 4 do
            if server.row(victim).alive then break end
            threads.step()
        end
    end

    --- One kill, with the victim back up afterwards. The pair is what a real
    --- round does and writing it out every time is where mistakes live.
    function server.trade(victim, killer)
        server.kill(victim, killer)
        server.revive(victim)
    end

    function server.settle(times) for _ = 1, (times or 1) do threads.step() end end
    function server.matchId() return matchId end

    --- How tall the ladder this config plays is, read the way the SERVER
    --- reads it -- through Arena.LadderTiersFor and the enabled catalogue --
    --- rather than recounted from the config list in the fixture. Counting
    --- it here again is how a test comes to assert its own arithmetic
    --- instead of the resource's.
    function server.tierCount()
        return #server.arena.LadderTiersFor('gungame')
    end

    function server.told(target)
        local said = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:notify' and message.target == target then
                said[#said + 1] = tostring((message.payload or {}).description or '')
            end
        end
        return table.concat(said, '\n')
    end

    function server.endedWith()
        for _, line in ipairs(console) do
            local reason = tostring(line):match('match %S+ ended: (%S+)')
            if reason then return reason end
        end
        return nil
    end

    function server.winners()
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == 'crimson_arena:client:results'
                and message.payload and message.payload.won == true then
                out[#out + 1] = message.target
            end
        end
        table.sort(out)
        return out
    end

    --- The end-of-round card one player was sent, or nil.
    ---
    --- READ FROM THE WIRE, because by the time a round has ended the match
    --- record is gone -- ArenaMatch.End finishes with ArenaLobby.Destroy --
    --- so `server.row` cannot answer anything about placement or earnings.
    --- The card is what the player actually sees, which is the better thing
    --- to assert against anyway.
    function server.resultFor(target)
        for index = #sent, 1, -1 do
            local message = sent[index]
            if message.event == 'crimson_arena:client:results' and message.target == target then
                return message.payload
            end
        end
        return nil
    end

    function server.board()
        for index = #sent, 1, -1 do
            local message = sent[index]
            if message.event == 'crimson_arena:client:matchHud' and message.payload then
                return message.payload.scoreboard
            end
        end
        return nil
    end

    return server
end

--- The GTA weapon name of one tier of a drawn ladder.
local function weaponAt(server, tier)
    return server.match_().ladder[tier].weapon
end

-- ======================================================================
-- 1-5. THE DRAW
-- ======================================================================

t.test('the ladder is one weapon per configured tier, in config order', function()
    local s = newServer()
    s.play(2)

    -- THE RESOLVED POOLS, NOT THE RAW CONFIG. The shipped ladder is composed
    -- from weapon CLASSES now -- so many rungs of melee, so many of
    -- sidearms, and up -- and the flat `gunGameTiers` the test used to read
    -- is not what the draw draws from any more. Arena.LadderTiersFor is: it
    -- is the one function that turns either config shape into the ordered
    -- pools the ladder is built out of, and reading it is what keeps this
    -- test about the DRAW rather than about a config field.
    local tiers = s.arena.LadderTiersFor('gungame')
    local drawn = s.ladder()

    t.equals(#drawn, #tiers,
        ('the ladder should have one weapon per tier, got %d for %d tier(s)')
            :format(#drawn, #tiers))

    -- EACH ONE OUT OF ITS OWN POOL, which is what makes the ladder
    -- "structured" rather than merely random: tier 3 is drawn from tier 3.
    for index, key in ipairs(drawn) do
        local inPool = false
        for _, candidate in ipairs(tiers[index]) do
            if candidate.key == key then inPool = true end
        end
        t.isTrue(inPool, ('tier %d drew "%s", which is not in tier %d\'s pool')
            :format(index, tostring(key), index))
    end
end)

t.test('the first tier is melee and the last one is not', function()
    -- THE SHAPE THE OPERATOR ASKED FOR: start on a blade, finish on the best
    -- gun on the ladder. Asserted against Arena.IsMeleeWeapon rather than
    -- against a list of knife names, because that is the resource's one
    -- answer to the question and a second spelling of it here is a second
    -- thing to keep in step.
    --
    -- RUN OVER MANY DRAWS. One draw proves one draw; the pools have up to
    -- seven entries and a rule that holds for the first weapon out of each
    -- has to hold for all of them.
    overManyLadders(40, function(attempt)
        local s = newServer(nil, attempt)
        s.play(2)
        local ladder = s.match_().ladder
        t.isTrue(s.arena.IsMeleeWeapon(ladder[1]) == true,
            ('draw %d opened on %s, which is not melee'):format(attempt, tostring(ladder[1].key)))
        t.isTrue(s.arena.IsMeleeWeapon(ladder[#ladder]) ~= true,
            ('draw %d finished on %s, which is melee'):format(attempt, tostring(ladder[#ladder].key)))

        -- AND EVERY TIER IN BETWEEN CAME OUT OF ITS OWN POOL. Test 1 checks
        -- that on one draw; over forty draws it is the claim that the ladder
        -- is structured rather than merely ordered, and tiers 2 to 6 were
        -- drawn forty times and asserted on never.
        for index, weapon in ipairs(ladder) do
            local inPool = false
            for _, candidate in ipairs(s.arena.LadderTiersFor('gungame')[index] or {}) do
                if candidate.key == weapon.key then inPool = true end
            end
            t.isTrue(inPool, ('draw %d put %s on tier %d, which is not in that pool')
                :format(attempt, tostring(weapon.key), index))
        end
    end)
end)

t.test('the drawn ladder does not change under the players mid-round', function()
    local s = newServer()
    s.play(3)

    local opening = table.concat(s.ladder(), ',')

    -- Everything that reads the ladder, made to read it: a climb, a fall, a
    -- scoreboard push and a respawn. Fighter 3 climbs and stays up; 1 and 2
    -- trade, so both of them end where they started.
    s.trade(2, 3)
    s.trade(1, 2)
    s.trade(2, 1)
    s.settle(2)

    t.equals(table.concat(s.ladder(), ','), opening,
        'the ladder a round is climbing must be the same one it started on')

    -- AND THE WEAPON A PLAYER IS HOLDING CAME OFF IT. A ladder that stayed
    -- put while the loadout was drawn from somewhere else would pass the
    -- line above and still be broken.
    t.equals(s.row(3).tier, 2, 'the climber is a tier up')
    t.equals(s.row(3).loadout.weapons[1].weapon, weaponAt(s, 2),
        'and holding tier 2 of the drawn ladder')
    -- Fighter 2 killed once and died once, in that order, so the death had
    -- a tier to take: back where they started. (Fighter 1 died FIRST, on
    -- tier 1, where there was nothing to charge -- which is the floor rule,
    -- tested on its own below.)
    t.equals(s.row(2).tier, 1, 'and a fighter who traded one for one is back where they started')
end)

t.test('two rounds of the same match do not climb the same guns', function()
    -- WHY THIS IS A TEST AND NOT A COIN FLIP. Seven tiers with pools of
    -- 7/5/5/5/5/5/3 have 7*5^5*3 = 65,625 possible ladders, so two
    -- consecutive draws matching is a 1-in-65,625 event -- but the failure
    -- this guards is not "unlucky", it is `match.ladder` never being cleared
    -- between rounds, which repeats 100% of the time. Twelve fresh servers
    -- makes a false failure a 1-in-10^54 event and a real one certain.
    local repeats = 0
    for attempt = 1, 12 do
        local s = newServer(nil, attempt * 977)
        s.play(2)
        local first = table.concat(s.ladder(), ',')

        -- Round two of the same match: Start is what clears the draw.
        local id = s.matchId()
        s.lobby.Get(id).state = 'lobby'
        for _, src in ipairs({ 1, 2 }) do s.row(src).ready = true end
        s.match.Start(id)
        s.settle(1)

        if table.concat(s.ladder(), ',') == first then repeats = repeats + 1 end
    end

    t.equals(repeats, 0,
        ('%d of 12 second rounds climbed the identical ladder -- the draw is not being cleared')
            :format(repeats))
end)

t.test('a tier whose whole pool is switched off is dropped, and two tiers is the floor', function()
    -- THE READING IS THE SERVER'S, NOT THE FIXTURE'S. Arena.LadderTiersFor
    -- is what decides how tall the ladder is; a test that recounts the pools
    -- itself asserts its own arithmetic and passes even when that function
    -- has stopped dropping anything.
    -- PINNED, so "tier 4" names a pool this test wrote rather than whichever
    -- rung the shipped class list happens to put there. Switching a whole
    -- CLASS off in the catalogue would drop several rungs at once and the
    -- arithmetic below counts one.
    local FOUR = { { 'knife' }, { 'pistol' }, { 'combatpistol' }, { 'heavypistol' }, { 'pistol50' } }
    local s = newServer(function(config)
        pinLadder(config, FOUR)
        -- Tier 4's whole pool, switched off in the catalogue.
        for _, weapon in ipairs(config.Loadouts.weapons) do
            for _, key in ipairs(FOUR[4]) do
                if weapon.key == key then weapon.enabled = false end
            end
        end
    end)
    s.play(2)

    local full = #FOUR
    t.equals(s.tierCount(), full - 1,
        'a tier with nothing playable in it should be dropped from the ladder')
    t.equals(#s.ladder(), full - 1, 'and the drawn ladder should be that much shorter')

    -- AND BELOW TWO IT IS NOT A LADDER AT ALL. A one-tier ladder would be
    -- topped by the first kill of the round, which is a worse outcome than
    -- the mode quietly running as ordinary rules -- and Arena.ValidateConfig
    -- is what makes sure an operator hears about it.
    local bare = newServer(function(config)
        pinLadder(config, { { 'knife' } })
    end)
    bare.play(2)
    t.equals(#bare.ladder(), 0, 'a single tier is not a ladder and should be played as ordinary rules')

    local complaints = table.concat(bare.arena.ValidateConfig() or {}, '\n')
    t.isTrue(complaints:find('gungame', 1, true) ~= nil,
        'the validator should complain about a gun game with fewer than two playable tiers')
end)

-- ======================================================================
-- 6-8. CLIMBING
-- ======================================================================

t.test('a kill carries the killer one tier up and hands them that weapon', function()
    local s = newServer()
    s.play(3)

    t.equals(s.row(1).tier, 1, 'everybody opens on tier 1')
    t.equals(s.row(1).loadout.weapons[1].weapon, weaponAt(s, 1),
        'and holding tier 1 of the drawn ladder')

    -- THE REAL INVENTORY, not the loadout record. On an ox server the item
    -- IS the weapon, so this is the assertion that a promotion happened to
    -- something a player can hold.
    t.equals(s.ox.count(1, weaponAt(s, 1)), 1, 'tier 1 should be in their pockets')

    s.trade(2, 1)

    t.equals(s.row(1).tier, 2, 'one kill is one tier')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 1, 'and tier 2 is now in their pockets')
    t.equals(s.ox.count(1, weaponAt(s, 1)), 0, 'and tier 1 has been taken off them')

    s.trade(3, 1)
    t.equals(s.row(1).tier, 3, 'two kills is two tiers')
    t.equals(s.ox.count(1, weaponAt(s, 3)), 1, 'holding tier 3')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 0, 'and no longer tier 2')
end)

t.test('the tier is derived from the score, so two kills in one tick move two tiers', function()
    -- COUNTED UP RATHER THAN DERIVED IS THE BUG THIS GUARDS. `settleTier`
    -- reads the score and works out where that puts the player, so a second
    -- kill landing before anything has swept moves them the right distance
    -- and a kill the server refused to credit cannot leave anybody standing
    -- a tier above what they earned.
    local s = newServer()
    s.play(4)

    -- Two victims, neither revived, nothing stepped in between.
    s.kill(2, 1)
    s.kill(3, 1)

    t.equals(s.row(1).tier, 3, 'two kills with no sweep between them is still two tiers')
    t.equals(s.row(1).ladderKills, 2, 'and both counted for the ladder')
    t.equals(s.ox.count(1, weaponAt(s, 3)), 1, 'and they are holding tier 3')

    -- AND THE TIERS THEY PASSED THROUGH ARE NOT IN THEIR POCKETS. Every
    -- swap has to take the old one away or a climber walks out of the arena
    -- with the whole ladder.
    t.equals(s.ox.count(1, weaponAt(s, 1)), 0, 'tier 1 gone')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 0, 'tier 2 gone')
end)

t.test('a kill made ON the top tier tops the ladder, and re-issues nothing on the way', function()
    -- SEVEN TIERS, PINNED. The `victims` list below is as long as the climb,
    -- and the shipped thirty-tier ladder would walk off the end of it.
    local s = newServer(sevenTiers)
    s.play(6)
    local top = s.tierCount()

    -- Up to the top tier: top-1 credited kills, each on a different victim
    -- so the per-victim cap never bites.
    local victims = { 2, 3, 4, 5, 6, 2, 3 }
    for step = 1, top - 1 do s.trade(victims[step], 1) end

    t.equals(s.row(1).tier, top, ('%d kills should stand on the top tier'):format(top - 1))

    -- REACHING THE TOP TIER IS NOT TOPPING THE LADDER -- the kill made FROM
    -- it is. Asserted through the round rather than through a flag: the
    -- server keeps no "finished" field any more, because a second copy of
    -- something the score already answers is a second copy that can drift.
    s.settle(2)
    t.equals(s.endedWith(), nil, 'standing on the top tier does not end the round')

    -- THE ROOM IS TOLD, once, and not the player themselves.
    t.isTrue(s.told(2):find('top tier', 1, true) ~= nil,
        'the room should be told when somebody reaches the top tier')

    -- NO FREE RE-ISSUE. A kill from the top tier moves nobody, and the early
    -- return in settleTier is the only thing stopping it handing the weapon
    -- over again with a full magazine every time. Counted through the real
    -- inventory: a second copy of the top weapon is the symptom.
    local before = s.ox.count(1, weaponAt(s, top))
    s.trade(4, 1)

    t.equals(s.ox.count(1, weaponAt(s, top)), before,
        'a kill from the top tier must not re-issue the weapon they are already holding')

    s.settle(2)
    t.equals(s.endedWith(), 'match.ended_ladder', 'and topping the ladder ends the round')
    t.equals(table.concat(s.winners(), ','), '1', 'won outright by the climber')
end)

-- ======================================================================
-- 9-11. FALLING
-- ======================================================================

t.test('every death costs a tier and takes the weapon, whoever caused it', function()
    local s = newServer()
    s.play(4)

    for step, victim in ipairs({ 2, 3, 4 }) do
        s.trade(victim, 1)
        t.equals(s.row(1).tier, step + 1, 'climbing')
    end
    t.equals(s.row(1).tier, 4, 'three kills stands on tier 4')

    -- KILLED BY SOMEBODY.
    s.trade(1, 2)
    t.equals(s.row(1).tier, 3, 'a death costs a tier')
    t.equals(s.ox.count(1, weaponAt(s, 4)), 0, 'and takes the tier-4 weapon away')
    t.equals(s.ox.count(1, weaponAt(s, 3)), 1, 'handing back tier 3')

    -- AND KILLED BY NOBODY. A demotion only on kills the server could verify
    -- would leave one free way down the ladder and back up it -- step off a
    -- roof, respawn, climb again with a full magazine each time.
    s.kill(1, nil)
    s.revive(1)
    t.equals(s.row(1).tier, 2, 'a death with no killer costs a tier just the same')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 1, 'and hands back tier 2')

    -- Nor does dying to yourself dodge it.
    s.kill(1, 1)
    s.revive(1)
    t.equals(s.row(1).tier, 1, 'and naming yourself as your own killer changes nothing')
end)

t.test('nobody falls below tier 1, however many times they die', function()
    local s = newServer()
    s.play(2)

    for _ = 1, 6 do
        s.kill(1, 2)
        s.revive(1)
    end

    t.equals(s.row(1).tier, 1, 'tier 1 is the floor')
    t.equals(s.row(1).tiersLost or 0, 0,
        'and a player with no tier to lose is never charged one -- a debt they can never climb out of')

    -- ONE KILL IS ONE TIER, still. If the six deaths had been counted the
    -- player would need seven kills to see tier 2.
    s.trade(2, 1)
    t.equals(s.row(1).tier, 2, 'one kill off the floor is tier 2, not tier 2 minus six deaths')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 1, 'and they are holding it')
end)

t.test('a demotion never edits a kill that really happened', function()
    -- THE SCOREBOARD, THE LEADERBOARD AND THE PAYOUT ALL READ `kills`.
    -- Moving somebody down the ladder by deleting one would quietly rewrite
    -- what happened in the round, which is why the ladder keeps its own two
    -- numbers next to it.
    local s = newServer()
    s.play(4)

    s.trade(2, 1)
    s.trade(3, 1)
    s.trade(4, 1)
    t.equals(s.row(1).kills, 3, 'three kills')

    s.trade(1, 2)
    s.trade(1, 3)

    t.equals(s.row(1).kills, 3, 'still three kills after two deaths')
    t.equals(s.row(1).deaths, 2, 'and two deaths')
    t.equals(s.row(1).ladderKills, 3, 'the ladder counts them all')
    t.equals(s.row(1).tiersLost, 2, 'and charges the deaths on its own number')
    t.equals(s.row(1).tier, 2, 'which is where they are standing: 3 up, 2 down, tier 2')
end)

-- ======================================================================
-- 12. THE CAP
-- ======================================================================

t.test('one victim cannot be farmed for a whole ladder', function()
    -- THE SERVER CANNOT SEE A KILL HAPPEN. It is told who died and who they
    -- say killed them, so an accomplice reporting their own death on a loop
    -- is indistinguishable from a fight -- and with no lives to spend and a
    -- topped ladder ending the round outright, that bought the entire pot in
    -- under a minute. The cap is on the PAIR, which is the shape a farm has
    -- and an honest round does not.
    -- FIVE PLAYERS AND SEVEN TIERS, and both numbers are load-bearing. The
    -- cap can never be tighter than the ladder needs -- see the floor test
    -- below -- so with seven tiers and four opponents the configured 2 is
    -- exactly what binds (ceil(7/4) = 2). In a smaller lobby, or against a
    -- taller ladder, the floor would loosen it and this test would be
    -- measuring the floor instead, which is a different rule. The shipped
    -- ladder is thirty tiers, so it has to be pinned rather than assumed.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim

    for _ = 1, cap + 4 do s.trade(2, 1) end

    t.equals(s.row(1).tier, cap + 1,
        ('%d kills on one victim should buy %d tier(s) and no more'):format(cap + 4, cap))
    t.equals(s.row(1).ladderKills, cap, 'and only the credited ones count for the ladder')

    -- THE KILLS THEMSELVES ARE UNTOUCHED. The cap withholds the climb, not
    -- the scoreboard: a player who really did kill somebody six times did.
    t.equals(s.row(1).kills, cap + 4, 'every kill still counts as a kill')
    t.isTrue(s.told(1):find('No tier for that one', 1, true) ~= nil,
        'and the killer is told why the climb stopped')

    -- A DIFFERENT VICTIM STILL PAYS, which is what keeps an honest round
    -- untouched by this.
    s.trade(3, 1)
    t.equals(s.row(1).tier, cap + 2, 'a fresh opponent moves them again')

    -- AND `0` REMOVES THE CAP, which is the operator's call on a closed
    -- server.
    local uncapped = newServer(function(config)
        config.Modes.gungame.maxTiersPerVictim = 0
    end)
    uncapped.play(2)
    for _ = 1, 4 do uncapped.trade(2, 1) end
    t.equals(uncapped.row(1).tier, 5, 'with the cap off, every kill climbs')

    -- AND A TYPO DOES NOT. Every unreadable value used to resolve to 0 --
    -- which is to say, the one setting that stops an accomplice buying the
    -- whole pot switched itself off silently. It falls back to the shipped
    -- default now, and Arena.ValidateConfig says so at start-up.
    for _, junk in ipairs({ 'two', true, -3 }) do
        local typo = newServer(function(config)
            config.Modes.gungame.maxTiersPerVictim = junk
            -- Three tiers against four opponents so the floor is 1 and the
            -- fallback of 2 is what binds.
            pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' } })
        end)
        typo.play(5)
        for _ = 1, 5 do typo.trade(2, 1) end
        -- ASSERTED ON ladderKills, NOT ON tier. The tier CLAMPS to the top of
        -- the ladder, so on a three-tier ladder a cap of 2 and no cap at all
        -- both read as tier 3 -- and removing the cap entirely passed this
        -- test until it was written this way.
        t.equals(typo.row(1).ladderKills, 2,
            ('maxTiersPerVictim = %s should fall back to the default, not remove the cap')
                :format(tostring(junk)))
    end
end)

t.test('the cap never makes the ladder unreachable in a small lobby', function()
    -- THE CAP IS "SPREAD YOUR KILLS ACROSS THE FIELD", AND A SMALL FIELD HAS
    -- NOWHERE TO SPREAD. Seven tiers at a cap of 2 needs four different
    -- victims to top, so the mode's own win condition was unreachable below
    -- five players while Config.Match.minPlayers ships at 2 -- a four-man
    -- lobby watched somebody collect "No tier for that one" forever and
    -- every round went to the clock.
    --
    -- It only ever loosens where a farm could not have paid anyway: the
    -- accomplice in a two-man match is the only other stake in the pot.
    local s = newServer(sevenTiers)
    s.play(2)
    local top = s.tierCount()

    for _ = 1, top do s.trade(2, 1) end

    -- ONE OPPONENT IS NOT ENOUGH, and that is deliberate. The floor divides
    -- by at least two however few opponents there really are, so the ladder
    -- can never be topped off a single person -- which is exactly the run
    -- two colluding accounts were using to take the pot in a 1v1.
    t.equals(s.row(1).ladderKills, math.ceil(top / 2),
        'a 1v1 gets half the ladder off its one opponent, and no more')

    s.settle(2)
    t.equals(s.endedWith(), nil, 'so a 1v1 is decided by the clock, not by topping the ladder')

    -- THREE PLAYERS IS WHERE IT BECOMES REACHABLE, which is the lobby the
    -- raise exists for: two opponents, seven tiers, four apiece.
    local small = newServer(sevenTiers)
    small.play(3)
    for round = 1, small.tierCount() do small.trade(2 + (round % 2), 1) end
    t.equals(small.row(1).ladderKills, small.tierCount(),
        'spread over two opponents, a three-man lobby can top the ladder')
    small.settle(2)
    t.equals(small.endedWith(), 'match.ended_ladder', 'and the round ends on it')

    -- AND THE FLOOR IS THE LADDER'S NEED, not a blanket exemption: with five
    -- opponents against seven tiers it works out at the shipped cap of 2, so
    -- a full lobby is untouched by it.
    local wide = newServer(sevenTiers)
    wide.play(6)
    for _ = 1, 6 do wide.trade(2, 1) end
    t.equals(wide.row(1).ladderKills, 2,
        'with five opponents the configured cap is what binds')
end)

t.test('and on the SHIPPED ladder it is the floor that binds, not the cap', function()
    -- THE COMPLAINT THIS ANSWERS, in a player's own words: "it is not going
    -- up tiers for better weapons, it says it took all you can off my name".
    --
    -- The shipped cap is 2, and against the seven-tier ladder it used to be
    -- the thing that bound in any lobby of five or more: two credits per
    -- victim, four different victims to top a seven-tier climb. In an
    -- ordinary three- or four-man round that meant a climber hit "No tier for
    -- that one" within a couple of minutes and then stopped moving for the
    -- rest of it, whoever they killed.
    --
    -- Thirty tiers changes the arithmetic rather than the rule: the floor is
    -- what a lone climber would need against everybody else in the room --
    -- ceil(30/5) = 6 with a full lobby -- so the cap only starts binding
    -- again in a room big enough for spreading kills to be possible. The rule
    -- is untouched; there is simply somewhere to spread to now.
    -- THE CAP IS NAMED HERE, not read from config: this server ships it OFF
    -- and the arithmetic below is about the rule, which still exists for
    -- anybody who turns it back on.
    local s = newServer(function(config)
        config.Modes.gungame.maxTiersPerVictim = 2
    end)
    s.play(6)
    t.equals(s.tierCount(), 30, 'the shipped ladder is thirty tiers')

    for _ = 1, 8 do s.trade(2, 1) end
    t.equals(s.row(1).ladderKills, 6,
        'ceil(30 tiers / 5 opponents) is what one victim is worth, not the cap of 2')
    t.isTrue(s.row(1).ladderKills > 2,
        'and that is looser than the configured cap, which is the whole point')
end)

-- ======================================================================
-- 13. THE REWARD
-- ======================================================================

t.test('a credited kill pays bandages every time and armour on a roll', function()
    local s = newServer(function(config)
        -- BOTH CHANCES PINNED, so this test is about the plumbing and not
        -- about luck. The roll itself is proved below.
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 1, chance = 100 },
        }
    end)
    s.play(4)

    local openingBandages = s.ox.count(1, 'bandage')
    local openingArmour = s.ox.count(1, 'armour')

    s.trade(2, 1)
    t.equals(s.ox.count(1, 'bandage'), openingBandages + 3, 'three bandages a kill')
    t.equals(s.ox.count(1, 'armour'), openingArmour + 1, 'and the plate, at 100%')

    s.trade(3, 1)
    t.equals(s.ox.count(1, 'bandage'), openingBandages + 6, 'and again on the next kill')

    -- CHANCE 0 IS NEVER, which is the other end of the same field and the
    -- reading that separates "no chance named" from "a chance of none".
    local never = newServer(function(config)
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 1, chance = 0 },
        }
    end)
    never.play(3)
    local before = never.ox.count(1, 'armour')
    for _ = 1, 2 do never.trade(2, 1) end
    t.equals(never.ox.count(1, 'armour'), before, 'a chance of 0 is never')
    t.equals(never.ox.count(1, 'bandage') > 0, true, 'while the bandages still land')

    -- THE ROLL IS A ROLL. Over many kills a 25% chance must land sometimes
    -- and not always -- the two ways a "chance" stops being one.
    local rolled = newServer(nil, 4242)
    rolled.play(6)
    local paid, kills = 0, 0
    for round = 1, 20 do
        local victim = 2 + (round % 5)
        local had = rolled.ox.count(1, 'armour')
        rolled.trade(victim, 1)
        kills = kills + 1
        if rolled.ox.count(1, 'armour') > had then paid = paid + 1 end
        -- Kept off the cap and off the top of the ladder so every one of
        -- these is a credited kill: knock the climber back down.
        rolled.kill(1, victim)
        rolled.revive(1)
        rolled.row(1).ladderVictims = {}
    end
    t.isTrue(paid > 0, ('the 25%% plate never landed in %d kills'):format(kills))
    t.isTrue(paid < kills, ('the 25%% plate landed on every one of %d kills'):format(kills))
end)

t.test('an uncredited kill pays nothing at all', function()
    -- HUNG OFF THE SAME GATE AS THE TIER, deliberately. A cap that stops the
    -- climb but keeps paying bandages leaves the accomplice farm intact for
    -- everything except the ladder -- three bandages a report, for ever,
    -- with no lives to spend.
    -- THREE TIERS AND FIVE PLAYERS so the floor is ceil(3/4) = 1 and the
    -- configured cap of 1 is what actually binds. On the shipped seven-tier
    -- ladder in a two-man lobby the floor would raise the cap to 7 and every
    -- one of these kills would be credited.
    local s = newServer(function(config)
        config.Modes.gungame.maxTiersPerVictim = 1
        pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' } })
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 1, chance = 100 },
        }
    end)
    s.play(5)

    s.trade(2, 1)
    local bandages = s.ox.count(1, 'bandage')
    local armour = s.ox.count(1, 'armour')
    t.isTrue(bandages > 0, 'the first, credited kill paid')

    for _ = 1, 5 do s.trade(2, 1) end

    t.equals(s.ox.count(1, 'bandage'), bandages, 'and five uncredited kills paid no bandages')
    t.equals(s.ox.count(1, 'armour'), armour, 'nor any armour')
end)

-- ======================================================================
-- 14-15. THE ROUND
-- ======================================================================

t.test('the mode runs on its own clock and eliminates nobody', function()
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = 600
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    s.play(3)

    -- THE MODE'S NUMBER, NOT Config.Match's. Every other mode treats the
    -- clock as a backstop; here it is the ordinary ending, so it is the one
    -- setting an operator most wants to reach for this mode alone.
    t.equals(s.arena.RoundSecondsFor('gungame'), 120, 'the mode carries its own round length')
    t.equals(s.arena.RoundSecondsFor('ffa'), 600, 'and every other mode still reads the shared one')
    t.equals(s.match_().endsAt - s.match_().startsAt, 120,
        'and the running match ends on the mode clock')

    -- NOBODY IS ELIMINATED, however many times they die. `lives` is 3 in
    -- this fixture, so on any other mode the fourth death ends this player's
    -- round -- and with it, in a three-way, the round itself.
    -- KILLED BY NOBODY, on purpose: eight credited kills would top the
    -- ladder and end the round, which would prove the wrong thing. What is
    -- under test here is that the DEATHS cost no lives.
    for _ = 1, 8 do
        s.kill(2, nil)
        s.revive(2)
    end

    t.equals(s.row(2).deaths, 8, 'eight deaths')
    t.equals(s.row(2).lives, 3, 'and not one life spent')
    t.equals(s.arena.IsEliminated(s.row(2)), false, 'so they are still in the round')

    s.settle(2)
    t.equals(s.endedWith(), nil, 'and the round is still running')
end)

t.test('the clock crowns the highest tier, and the board is ordered by it', function()
    local s = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    s.play(4)

    -- THE SHAPE THIS TEST NEEDS: one player ahead on TIERS and another ahead
    -- on KILLS, so the two possible answers point at different people.
    --
    -- Fighter 3 takes four kills and never dies -- four up, tier 5.
    -- Fighter 2 takes six kills and then dies five times -- MORE KILLS than
    -- fighter 3, and six up less five down leaves them on tier 2.
    --
    -- FIGHTER 2'S DEATHS HAVE NO KILLER, on purpose. A death charged to
    -- somebody would climb THEM, and the third climber would be the one at
    -- the top of the board -- which is how the first draft of this test came
    -- to assert against a leader it had created by accident.
    for _, victim in ipairs({ 1, 4, 1, 4 }) do
        s.trade(victim, 3)
    end
    for round = 1, 6 do
        local victim = (round % 2 == 0) and 1 or 4
        s.trade(victim, 2)
        s.row(2).ladderVictims = {}
    end
    for _ = 1, 5 do
        s.kill(2, nil)
        s.revive(2)
    end

    t.isTrue(s.row(2).kills > s.row(3).kills,
        ('the setup needs fighter 2 ahead on kills: %d vs %d')
            :format(s.row(2).kills, s.row(3).kills))
    t.isTrue(s.row(3).tier > s.row(2).tier,
        ('and fighter 3 ahead on tiers: %d vs %d'):format(s.row(3).tier, s.row(2).tier))

    -- THE SCOREBOARD, before the clock: the panel had better be showing the
    -- race the server is about to decide, not a different one. The tier and
    -- the ladder height both ride on it -- for a long time the server sent
    -- them and the panel drew neither.
    s.settle(1)
    local board = s.board()
    t.isTrue(type(board) == 'table' and #board > 0, 'the hud carries a scoreboard')
    t.equals(board[1].id, 3, 'the highest tier is top of the board, not the most kills')
    t.equals(board[1].tier, s.row(3).tier, 'and the row carries the tier')
    t.equals(board[1].tiers, s.tierCount(), 'and how tall the ladder is')

    -- THE CLOCK.
    s.match_().endsAt = os.time() - 1
    s.settle(2)

    t.equals(s.endedWith(), 'match.ended_time_up', 'the clock ends a gun game')
    t.equals(table.concat(s.winners(), ','), '3',
        'and crowns the player standing highest, not the one with the most kills')
end)

-- ======================================================================
-- 18-23. THE LOADOUT THE LADDER REPLACES
-- ======================================================================

t.test('nobody picks a loadout in this mode, and the server says so', function()
    -- THE LADDER IS THE LOADOUT, so there is nothing for a pick to change.
    -- The panel greys the whole screen out; this is the rule underneath it,
    -- because the panel is a suggestion and a crafted request is not.
    local s = newServer()
    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'gungame', entryFee = 0, account = 'cash',
    })
    local id = s.lobby.All()[1].id
    s.fire('joinMatch', 2, { matchId = id, account = 'cash' })

    local ok, reason = s.lobby.SetLoadout(1, { weapons = { { key = 'rifle' } } })
    t.equals(ok, false, 'a pick in a ladder mode is refused')
    t.equals(reason, 'error.mode_picks_loadout', 'and named as the mode\'s doing')

    -- THE HOST TOO, and that is the point of putting it above the
    -- host-picks rule rather than beside it: in this mode NOBODY picks.
    local host = s.lobby.Get(id).hostSource
    t.equals(select(1, s.lobby.SetLoadout(host, { weapons = { { key = 'rifle' } } })), false,
        'not even the host, on a server where the host normally would')

    -- AND AN ORDINARY MODE IS UNTOUCHED.
    local ffa = newServer()
    ffa.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    t.equals(select(1, ffa.lobby.SetLoadout(1, { weapons = { { key = 'rifle' } } })), true,
        'a free-for-all still lets its host pick')
end)

t.test('everybody is issued the mode\'s kit, and their own pick is ignored', function()
    local s = newServer()
    s.play(3)

    -- 1 body armour and 5 bandages, to everybody, as config names them.
    for _, src in ipairs({ 1, 2, 3 }) do
        t.equals(s.ox.count(src, 'armour'), 1, ('fighter %d carries one plate'):format(src))
        t.equals(s.ox.count(src, 'bandage'), 5, ('fighter %d carries five bandages'):format(src))
    end

    -- ON THE RECORD TOO, which is what the exit reclaims against -- and it
    -- survives a tier change, because a hand-built loadout that forgets the
    -- field silently takes the kit away.
    local carried = {}
    for _, entry in ipairs(s.row(1).loadout.supplies or {}) do carried[entry.key] = entry.count end
    t.equals(carried.armour, 1, 'the record says one plate')
    t.equals(carried.bandage, 5, 'and five bandages')

    s.trade(2, 1)
    local after = {}
    for _, entry in ipairs(s.row(1).loadout.supplies or {}) do after[entry.key] = entry.count end
    t.equals(after.bandage, 5, 'and a promotion does not wipe the kit off the record')

    -- A DIFFERENT KIT IS A DIFFERENT KIT, so this is reading config rather
    -- than a number written twice.
    local rich = newServer(function(config)
        config.Modes.gungame.startingKit = { { key = 'bandage', count = 9 } }
    end)
    rich.play(2)
    t.equals(rich.ox.count(1, 'bandage'), 9, 'the kit is whatever config says it is')
    t.equals(rich.ox.count(1, 'armour'), 0, 'and nothing it does not name')

    -- CLAMPED TO THE SUPPLY\'S OWN CEILING, exactly as a player\'s pick is.
    local greedy = newServer(function(config)
        config.Modes.gungame.startingKit = { { key = 'bandage', count = 99999 } }
    end)
    greedy.play(2)
    local max = 0
    for _, supply in ipairs(greedy.arena.GetEnabledSupplies()) do
        if supply.key == 'bandage' then max = greedy.arena.SupplyMax(supply) end
    end
    t.isTrue(max > 0, 'the catalogue has a ceiling to clamp against')
    t.equals(greedy.ox.count(1, 'bandage'), max, 'and the kit is held to it')
end)

t.test('a tier weapon arrives with the rounds that do not fit in it', function()
    -- HALF A WEAPON IS NOT A WEAPON. The swap loaded one magazine and threw
    -- the rest of the pick away, so a climber held 30 of a 60-round pistol
    -- and owned no ammo ITEM to reload from -- and since tier 1 is melee,
    -- entry hands them no rounds either. Switching ammo items ON halved what
    -- the mode carried, which is the opposite of what that setting promises.
    -- PINNED, because tier 2 has to be a FIREARM for there to be loose
    -- rounds to argue about. The shipped ladder opens on five melee pools,
    -- and a blade is issued no ammo item at all -- deliberately, since
    -- ox_inventory reads a present ammo key as "this is an ammo weapon".
    local s = newServer(sevenTiers)
    s.play(3)
    s.trade(2, 1)

    local entry = s.row(1).loadout.weapons[1]
    t.isTrue(s.arena.IsKey(entry.ammoTypeItem),
        'the tier entry names an ammo item at all -- it used to name none')

    local magazine = s.arena.MagazineFor(s.arena.GetWeaponByKey(entry.key), entry.ammo)
    local spare = entry.ammo - magazine
    t.isTrue(spare > 0, ('tier 2 should owe loose rounds: %d of %d'):format(spare, entry.ammo))

    t.equals(s.ox.metaOf(1, entry.weapon).ammo, magazine, 'one magazine in the gun')
    t.isTrue(s.ox.count(1, entry.ammoTypeItem) > 0,
        'and the rest as items they can actually reload from')

    -- AND THE ARENA KNOWS IT LENT THEM. Without the ledger write the exit
    -- reclaims nothing and, with the door off, the rounds simply stay.
    t.isTrue(s.ammo.OnLoan(s.matchId()) > 0, 'the rounds are on the arena\'s books')
end)

t.test('two tiers holding the same weapon never hand out two of it', function()
    -- NOTHING WAS REMOVED AND ONE WAS STILL ADDED, so every crossing of a
    -- boundary where two tiers name the same gun handed out another -- and
    -- deaths are free in this mode, so a player could sit on that boundary
    -- and pump it.
    local s = newServer(function(config)
        pinLadder(config, {
            { 'knife' }, { 'pistol' }, { 'pistol' }, { 'rifle' },
        })
    end)
    s.play(3)

    local pistol = s.match_().ladder[2].weapon
    s.trade(2, 1)
    t.equals(s.ox.count(1, pistol), 1, 'tier 2 hands over one')
    s.trade(3, 1)
    t.equals(s.row(1).tier, 3, 'and the climb carries on')
    t.equals(s.ox.count(1, pistol), 1, 'tier 3 is the same gun, and still only one of it')

    -- Back down and up again, which is the pump.
    s.kill(1, 2); s.revive(1)
    t.equals(s.ox.count(1, pistol), 1, 'a demotion onto the same gun leaves one')
    s.trade(2, 1)
    t.equals(s.ox.count(1, pistol), 1, 'and climbing back onto it leaves one')

    -- THE VALIDATOR SEES THE CONFIG THAT ALLOWS IT.
    local complaints = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(complaints:find('both tier 2 and tier 3', 1, true) ~= nil,
        'and an operator is told their ladder has a step that is not a step')
end)

t.test('an inventory that refuses a weapon does not lock the ladder for the round', function()
    -- THE WORST BUG IN THIS FILE\'S HISTORY. A refused add stripped the
    -- weapon from the pocket AND from the arena\'s record, the put-back was
    -- refused too, and every later swap then asked ox_inventory for a
    -- weapon nobody had -- was refused -- and returned early. The player
    -- stood disarmed on tier 1 for the rest of the round, their tier frozen,
    -- long after the inventory had room again.
    local s = newServer()
    s.play(3)

    local tier2 = weaponAt(s, 2)
    s.ox.refuseAdd[tier2] = true
    s.trade(2, 1)

    t.equals(s.ox.count(1, tier2), 0, 'the refused weapon was not handed over')
    t.equals(s.row(1).tier, 1, 'and the tier did not move without it')

    -- THE INVENTORY FREES UP.
    s.ox.refuseAdd[tier2] = nil
    s.trade(3, 1)

    t.isTrue(s.row(1).tier > 1,
        ('the ladder has to move again once the inventory frees up -- it is on tier %d')
            :format(s.row(1).tier))
    t.equals(s.ox.count(1, weaponAt(s, s.row(1).tier)), 1,
        'and they are holding the tier they are standing on')
end)

t.test('the board and the winner read the same number', function()
    -- ONE NUMBER, TWO READERS, AND THEY USED TO BE DIFFERENT NUMBERS. The
    -- board sorted on the tier a player was HOLDING and decideOnLadder
    -- crowned the tier their SCORE had earned -- identical in an ordinary
    -- round, and permanently apart after any refused swap, so the race was
    -- ranked backwards and the winner came off the bottom of the board.
    local s = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    s.play(4)

    -- Fighter 3 climbs, then their next weapon is refused: score says one
    -- thing, pockets say another.
    s.trade(1, 3)
    s.trade(4, 3)
    -- The weapon of the tier they are about to climb ONTO, not the one they
    -- are standing on -- refusing what they already hold refuses nothing.
    s.ox.refuseAdd[weaponAt(s, 4)] = true
    s.trade(1, 3)

    t.isTrue(s.row(3).tier < 4, 'the held tier is behind the score')
    s.settle(1)

    local board = s.board()
    t.equals(board[1].id, 3, 'the climber is top of the board')
    t.equals(board[1].tier, 4, 'and the board shows the tier their score earned')

    s.match_().endsAt = os.time() - 1
    s.settle(2)
    t.equals(table.concat(s.winners(), ','), '3',
        'and the clock crowns the player the board had at the top')
end)

-- ======================================================================
-- 24-29. THE PATHS NOTHING REACHED
-- ======================================================================

t.test('the mode ships ON, and its ladder is a real one', function()
    -- IT USED TO SHIP OFF, and this test used to be the guard on that: every
    -- test in this file switches gun game on, which was only defensible
    -- while the shipped config really did ship it off, so the assertion here
    -- was `enabled == false`.
    --
    -- The operator has turned it on. That makes the guard's original job
    -- disappear -- the config every test in this file runs is now the config
    -- operators actually have, which is strictly better -- and leaves the
    -- second half, which matters more than it did: a mode that is ON and
    -- broken is broken for everybody, immediately, rather than the first
    -- time somebody opts in.
    local shipped = Sandbox.shippedConfig()
    t.equals(shipped.Modes.gungame.enabled, true,
        'gun game was switched back off -- if that is deliberate, this test is the place to say so')

    -- AND WHAT SHIPS IS PLAYABLE, which is now the whole of this test's job.
    --
    -- READ THROUGH THE CLASSES. The shipped ladder is composed from weapon
    -- classes rather than written out pool by pool, so `gunGameTiers` is
    -- absent from the shipped config and asserting on it asserted on nil.
    t.isTrue(type(shipped.Modes.gungame.gunGameClasses) == 'table'
        and #shipped.Modes.gungame.gunGameClasses > 1,
        'the shipped ladder needs more than one weapon class')
    t.isTrue(type(shipped.Modes.gungame.startingKit) == 'table',
        'and a starting kit')

    -- EVERY CLASS OF THE SHIPPED LADDER RESOLVES. A class whose keys are all
    -- switched off is dropped silently, so "it ships with seven classes" and
    -- "it ships with seven PLAYABLE classes" are different claims and this is
    -- the second one.
    for index, class in ipairs(shipped.Modes.gungame.gunGameClasses) do
        local playable = 0
        for _, key in ipairs(class.weapons or {}) do
            for _, weapon in ipairs(shipped.Loadouts.weapons) do
                if weapon.key == key and weapon.enabled ~= false then playable = playable + 1 end
            end
        end
        t.isTrue(playable > 0,
            ('shipped class %d (%s) has nothing playable in it')
                :format(index, tostring(class.key)))

        -- AND NEVER MORE RUNGS THAN IT HAS WEAPONS, which is the one shape
        -- of ladder that hands the same gun out on two tiers in a row.
        t.isTrue((class.tiers or 0) <= playable,
            ('shipped class %s asks for %d rungs out of %d playable weapons')
                :format(tostring(class.key), class.tiers or 0, playable))
    end

    -- ONE MELEE RUNG. The whole shape of the mode: everybody opens on a
    -- blade, and the climb is out of melee from the very next tier.
    t.equals(shipped.Modes.gungame.gunGameClasses[1].tiers, 1,
        'the shipped ladder opens on more than one melee rung')

    -- AND THE KIT NAMES SUPPLIES THAT EXIST.
    for _, entry in ipairs(shipped.Modes.gungame.startingKit) do
        local found = false
        for _, supply in ipairs(shipped.Loadouts.supplies.items) do
            if supply.key == entry.key and supply.enabled ~= false then found = true end
        end
        t.isTrue(found, ('the shipped kit names "%s", which is not an enabled supply')
            :format(tostring(entry.key)))
    end
end)

t.test('a server with no ox_inventory still climbs the ladder', function()
    -- THE `no-inventory` ANSWER, which nothing had ever executed. It is not
    -- a refusal: there are no items to move, this side's record is the whole
    -- truth, and the tier has to move anyway or the mode does not run at all
    -- on a server without ox_inventory started.
    local s = newServer(nil, nil, { noInventory = true })
    s.play(3)

    t.equals(s.row(1).tier, 1, 'everybody still opens on tier 1')
    s.trade(2, 1)
    t.equals(s.row(1).tier, 2, 'and a kill still climbs')
    t.equals(s.row(1).loadout.weapons[1].weapon, weaponAt(s, 2),
        'with the record naming the right weapon')

    -- The swap itself says which answer it gave, so this is reading the
    -- branch rather than inferring it from the outcome.
    local ok, why = s.ammo.SwapWeapon(1, s.matchId(), nil,
        { weapon = 'WEAPON_PISTOL', key = 'pistol', ammo = 10 })
    t.equals(ok, false, 'the swap reports it did nothing')
    t.equals(why, 'no-inventory', 'and says why, so the caller does not roll back')
end)

t.test('two players topping the ladder in one sweep is a draw, and pays nobody', function()
    -- THE TIE THIS MODE IS THE ONLY NON-TEAM ONE THAT CAN PRODUCE, and
    -- nothing had ever reached it. `winningPick` collapses a free-for-all
    -- result to winners[1], so two finishers meant the second was told they
    -- had won, recorded as a winner, and paid nothing -- while their own
    -- stake was judged a loser against the first.
    local s = newServer(function(config)
        pinLadder(config, { { 'knife' }, { 'pistol' } })
    end)
    s.play(4)

    -- Two tiers, so two credited kills tops it. Both climbers finish inside
    -- the same sweep because nothing steps in between.
    s.trade(3, 1)
    s.trade(4, 1)
    s.trade(3, 2)
    s.trade(4, 2)

    t.equals(s.row(1).ladderKills, 2, 'fighter 1 topped a two-tier ladder')
    t.equals(s.row(2).ladderKills, 2, 'and so did fighter 2, in the same sweep')

    s.settle(2)
    t.equals(s.endedWith(), 'match.ended_draw',
        'two finishers at once is a draw, not a win for whichever reported first')
    t.equals(table.concat(s.winners(), ','), '', 'and nobody is told they won')
end)

t.test('the clock draws when nobody climbed, and when two are level', function()
    -- decideOnLadder's OTHER TWO ANSWERS. Only its single-winner branch had
    -- ever run, so "a tie is a draw" and "nobody climbed is a draw" were
    -- claims rather than behaviour.
    local quiet = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    quiet.play(3)
    quiet.match_().endsAt = os.time() - 1
    quiet.settle(2)
    t.equals(quiet.endedWith(), 'match.ended_draw', 'a round nobody climbed is a draw')

    local level = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    level.play(4)
    -- Two climbers, one kill each, on different victims: level on tier AND
    -- level on the kills that break a tier tie.
    level.trade(3, 1)
    level.trade(4, 2)
    t.equals(level.row(1).kills, level.row(2).kills, 'the setup needs them level on kills')

    level.match_().endsAt = os.time() - 1
    level.settle(2)
    t.equals(level.endedWith(), 'match.ended_draw', 'level on both is a draw')
    t.equals(table.concat(level.winners(), ','), '', 'and pays nobody')

    -- AND KILLS REALLY DO BREAK A TIER TIE, which is the third branch.
    local broken = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    broken.play(5)
    broken.trade(3, 1)
    broken.trade(4, 2)
    -- Fighter 2 takes a second kill and a death: same tier, more kills.
    broken.trade(5, 2)
    broken.kill(2, nil)
    broken.revive(2)

    t.equals(broken.row(1).tier, broken.row(2).tier, 'level on tiers')
    t.isTrue(broken.row(2).kills > broken.row(1).kills, 'and fighter 2 fought more to get there')

    broken.match_().endsAt = os.time() - 1
    broken.settle(2)
    t.equals(table.concat(broken.winners(), ','), '2', 'so the kills break the tie')
end)

t.test('the room can be told nothing, and the climber is never told about themselves', function()
    -- announceFinalTier = false was never once set by a test, so the switch
    -- decided nothing that anybody had checked.
    local quiet = newServer(function(config)
        sevenTiers(config)
        config.Modes.gungame.announceFinalTier = false
    end)
    quiet.play(6)
    local top = quiet.tierCount()
    local victims = { 2, 3, 4, 5, 6, 2, 3 }
    for step = 1, top - 1 do quiet.trade(victims[step], 1) end

    t.equals(quiet.row(1).tier, top, 'somebody is on the top tier')
    t.isTrue(quiet.told(2):find('top tier', 1, true) == nil,
        'and with the announcement off, the room is not told')

    -- ON, the room is told ONCE EACH and the climber is not told at all --
    -- both halves of the prose, neither of which was asserted.
    local loud = newServer(sevenTiers)
    loud.play(6)
    for step = 1, top - 1 do loud.trade(victims[step], 1) end

    t.isTrue(loud.told(1):find('top tier', 1, true) == nil,
        'the climber is not told about themselves')
    for _, other in ipairs({ 2, 3, 4, 5, 6 }) do
        local said = loud.told(other)
        local first, count = said:find('top tier', 1, true), 0
        while first do
            count = count + 1
            first = said:find('top tier', first + 1, true)
        end
        t.equals(count, 1, ('fighter %d should be told exactly once'):format(other))
    end
end)

t.test('a promotion and a demotion each say the tier, the height and the weapon', function()
    -- THE TWO NOTIFICATIONS THE MODE ACTUALLY SENDS, and nothing checked
    -- either was delivered or carried the right numbers. locale_spec checks
    -- their placeholder arity statically; that is a different question from
    -- whether the right values reach the player.
    local s = newServer()
    s.play(3)
    local height = s.tierCount()

    s.trade(2, 1)
    local up = s.told(1)
    t.isTrue(up:find('Tier 2 of ' .. height, 1, true) ~= nil,
        ('the promotion should name tier 2 of %d -- got: %s'):format(height, up))
    t.isTrue(up:find(s.match_().ladder[2].label, 1, true) ~= nil,
        'and the weapon they are now holding')

    s.trade(1, 2)
    local down = s.told(1)
    t.isTrue(down:find('Down to tier 1 of ' .. height, 1, true) ~= nil,
        ('the demotion should name tier 1 of %d -- got: %s'):format(height, down))
    t.isTrue(down:find(s.match_().ladder[1].label, 1, true) ~= nil,
        'and the weapon it put back in their hands')
end)

t.test('an ordinary mode carries no tier on the wire at all', function()
    -- THE OTHER HALF OF scoreboardOf's CONTRACT. Everything here asserts the
    -- tier is PRESENT in a gun game; nothing asserted it is ABSENT
    -- everywhere else, which is the whole mechanism by which the panel knows
    -- not to draw a column.
    local s = newServer()
    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    local id = s.lobby.All()[1].id
    s.fire('joinMatch', 2, { matchId = id, account = 'cash' })
    for src = 1, 2 do s.fire('setReady', src, { ready = true }) end
    for _ = 1, 4 do
        if s.lobby.Get(id).state == 'live' then break end
        s.settle(1)
    end
    s.settle(1)

    local board = s.board()
    t.isTrue(type(board) == 'table' and #board > 0, 'a free-for-all has a scoreboard')
    for _, row in ipairs(board) do
        t.equals(row.tier, nil, 'and no row carries a tier')
        t.equals(row.tiers, nil, 'nor a ladder height')
    end

    -- AND THE MODE LIST SAYS SO TOO, which is what the panel reads to decide
    -- whether the loadout screen is shut.
    local modes = {}
    for _, mode in ipairs(s.arena.GetEnabledModes()) do modes[mode.key] = mode end
    t.equals(modes.ffa.tiers, nil, 'a free-for-all advertises no ladder')
    t.isTrue((modes.gungame.tiers or 0) > 1, 'and a gun game advertises its height')
end)

-- ======================================================================
-- 31-37. WHAT THE MUTANTS WALKED THROUGH
-- ======================================================================

t.test('the real respawn thread puts a climber back on their own tier', function()
    -- THE PATH THAT WAS NEVER EXECUTED. Deleting the line in scheduleRespawn
    -- that re-resolves a respawning player's loadout left this file green,
    -- because `server.revive` stood everybody up before the thread could
    -- run. The header claims the ladder replaces the loadout "on every
    -- respawn"; nothing had ever watched one.
    local s = newServer()
    s.play(3)

    for _, victim in ipairs({ 2, 3 }) do s.trade(victim, 1) end
    t.equals(s.row(1).tier, 3, 'two kills up')

    s.dieAndRespawn(1, 2)

    t.equals(s.row(1).alive, true, 'the scheduled respawn really ran')
    t.equals(s.row(1).tier, 2, 'the death cost a tier')
    t.equals(s.row(1).loadout.weapons[1].weapon, weaponAt(s, 2),
        'and they come back holding the tier they are standing on, not the one they lost')

    -- AND THE RESPAWN IS WHAT RE-RESOLVES IT, provably.
    --
    -- The assertions above pass whether or not scheduleRespawn re-resolves,
    -- because settleTier already rewrote the loadout at the DEATH. So this
    -- corrupts the record on tier 1 -- where a death costs nothing and
    -- settleTier returns without touching anything -- and the respawn is
    -- then the only thing left that can put it right. Deleting that line
    -- makes exactly this assertion fail, which is the check a test earns its
    -- place with.
    while s.row(1).tier > 1 do
        s.kill(1, 2)
        s.revive(1)
    end
    s.row(1).loadout = { weapons = {}, armor = 0, health = 100, supplies = {} }

    s.dieAndRespawn(1, 2)

    t.equals(s.row(1).tier, 1, 'a death on tier 1 costs nothing')
    t.isTrue(s.row(1).loadout.weapons[1] ~= nil,
        'and the respawn re-resolves the loadout rather than handing back the record it found')
    t.equals(s.row(1).loadout.weapons[1].weapon, weaponAt(s, 1),
        'putting the tier they are standing on back in their hands')

    -- THE CLAMP, on the same path: a ladder redrawn shorter under a player
    -- leaves them standing on a tier that is not there.
    s.row(1).tier = 99
    s.row(1).loadout = { weapons = {}, armor = 0, health = 100, supplies = {} }
    s.dieAndRespawn(1, 2)
    t.isTrue(s.row(1).tier <= s.tierCount(),
        ('a tier past the top of the ladder should be clamped, got %s'):format(tostring(s.row(1).tier)))
    t.isTrue(s.row(1).loadout.weapons[1] ~= nil, 'and they are armed rather than indexed past the end')
end)

t.test('the ladder weapon carries its magazine, its attachments and its tint', function()
    -- weaponMetadata WAS ENTIRELY UNBOUND. It could be reduced to returning
    -- an empty table and this file passed -- and the three faults the
    -- builder was unified to fix are exactly these three fields.
    local s = newServer(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.key == 'pistol' then
                weapon.components = { 'at_pi_flsh' }
                weapon.tint = 3
            end
        end
        pinLadder(config, { { 'knife' }, { 'pistol' } })
    end)
    s.play(3)

    -- MELEE CARRIES NO AMMO KEY AT ALL. ox_inventory reads a present one as
    -- "this is an ammo weapon", which a blade is not -- and the catalogue
    -- gives every melee entry a default of 1 precisely so the ammo machinery
    -- has a number to agree on, which was reaching the item.
    local blade = s.ox.metaOf(1, weaponAt(s, 1))
    t.isTrue(blade ~= nil, 'the melee tier was issued as an item')
    t.equals(blade.ammo, nil, 'and a blade must carry no ammo key')

    s.trade(2, 1)
    local gun = s.ox.metaOf(1, weaponAt(s, 2))
    t.isTrue(gun ~= nil, 'the promotion issued the next tier')

    local entry = s.row(1).loadout.weapons[1]
    local magazine = s.arena.MagazineFor(s.arena.GetWeaponByKey(entry.key), entry.ammo)
    t.equals(gun.ammo, magazine,
        'ONE magazine rides in the gun, not the whole pick')
    t.isTrue(type(gun.components) == 'table' and gun.components[1] == 'at_pi_flsh',
        'the attachment an operator configured has to reach the player through the metadata or not at all')
    t.equals(gun.tint, 3, 'and so does the tint')
end)

t.test('a refused promotion puts back the weapon it took', function()
    -- THE ROLLBACK. The removal has already happened by the time the add is
    -- refused, so without it the player stands in the arena holding nothing
    -- -- and the log used to tell them they kept the tier they had.
    local s = newServer()
    s.play(3)

    local held = weaponAt(s, 1)
    t.equals(s.ox.count(1, held), 1, 'they open holding tier 1')

    s.ox.refuseAdd[weaponAt(s, 2)] = true
    s.trade(2, 1)

    t.equals(s.row(1).tier, 1, 'the tier did not move')
    t.equals(s.ox.count(1, held), 1, 'and tier 1 is back in their hands, not gone')
    t.equals(s.ox.count(1, weaponAt(s, 2)), 0, 'with none of the tier that was refused')

    -- AND A PLAYER THE ARENA NO LONGER KITS IS REFUSED OUTRIGHT. A promotion
    -- landing after the exit used to push a real weapon into the inventory
    -- the arena had already handed back, which neither Reclaim nor
    -- ReclaimAll takes away again.
    s.ammo.Reclaim(3, 'test')
    local ok, why = s.ammo.SwapWeapon(3, s.matchId(), nil, s.row(3).loadout.weapons[1])
    t.equals(ok, false, 'a swap for somebody the arena is not arming is refused')
    t.equals(why, 'refused', 'and named as a refusal, so the caller rolls back')
end)

t.test('every kill reward is on the arena\'s books, and a refused one is not', function()
    -- "ON THE BOOKS IS THE POINT" says the doc comment, and deleting the
    -- line that writes the ledger changed nothing anywhere in the suite. The
    -- record is what the exit reclaims against: a plate handed over and not
    -- recorded is a plate the player keeps.
    local s = newServer(function(config)
        config.Modes.gungame.killReward = { { key = 'bandage', count = 3 } }
    end)
    s.play(4)

    local carriedIn = s.ox.count(1, 'bandage')
    s.trade(2, 1)
    s.trade(3, 1)
    t.equals(s.ox.count(1, 'bandage'), carriedIn + 6, 'two kills paid six bandages')

    s.ammo.Reclaim(1, 'test')
    t.equals(s.ox.count(1, 'bandage'), 0,
        'and the exit takes back what the arena issued -- kit and reward alike')

    -- A REFUSED GRANT IS NOT RECORDED, or the exit reclaims something the
    -- player never got.
    local other = newServer(function(config)
        config.Modes.gungame.killReward = { { key = 'bandage', count = 3 } }
    end)
    other.play(3)
    other.ox.refuseAdd['bandage'] = true
    local before = other.ox.count(1, 'bandage')
    other.trade(2, 1)
    t.equals(other.ox.count(1, 'bandage'), before, 'a refused reward is not paid')
    other.ammo.Reclaim(1, 'test')
    t.equals(other.ox.count(1, 'bandage') >= 0, true,
        'and the exit does not go looking for what was never handed over')
end)

t.test('a second round clears every number the ladder keeps', function()
    -- Test 4 proves the LADDER is redrawn and nothing more. All five
    -- per-player reset lines could be deleted one at a time and this file
    -- stayed green -- including the victims list, which would carry last
    -- round's farming into this one's cap.
    local s = newServer()
    s.play(3)

    s.trade(2, 1)
    s.trade(3, 1)
    s.kill(1, 2)
    s.revive(1)

    t.isTrue((s.row(1).ladderKills or 0) > 0, 'the setup left something to clear')
    t.isTrue((s.row(1).tiersLost or 0) > 0, 'and a tier lost')
    t.isTrue(next(s.row(1).ladderVictims or {}) ~= nil, 'and a victims list')

    local id = s.matchId()
    s.lobby.Get(id).state = 'lobby'
    for _, src in ipairs({ 1, 2, 3 }) do s.row(src).ready = true end
    s.match.Start(id)
    s.settle(1)

    t.equals(s.row(1).tier, 1, 'everybody opens the new round on tier 1')
    t.equals(s.row(1).ladderKills, nil, 'with no ladder kills carried over')
    t.equals(s.row(1).tiersLost, nil, 'nor tiers lost')
    t.equals(s.row(1).ladderVictims, nil,
        'nor last round\'s victims, which would count against this round\'s cap')
end)

t.test('the ladder beats the clock, the score limit and the last one standing', function()
    -- THE OVERRIDE, and each half of it separately. The score-limit rule
    -- would settle a ladder on raw kills, which is not the race anybody is
    -- running; the last-standing rule cannot fire in a mode that eliminates
    -- nobody; and a ladder topped on the last second of the round was still
    -- topped.
    local s = newServer(function(config)
        config.Match.winCondition = 'score_limit'
        config.Match.scoreLimit = 2
        pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' } })
        config.Modes.gungame.roundTimeSeconds = 600
        -- PINNED, and only so the scenario below survives: with the cap off,
        -- the three deaths player 1 takes hand player 2 three credits, and on
        -- a three-tier ladder that tops it and ends the round before the
        -- thing this test is about can be asked.
        config.Modes.gungame.maxTiersPerVictim = 2
    end)
    s.play(4)

    -- Three kills and three deaths: well past the score limit, standing on
    -- tier 1. An ordinary mode would have ended on the second kill.
    for _, victim in ipairs({ 2, 3, 4 }) do s.trade(victim, 1) end
    for _ = 1, 3 do
        s.kill(1, 2)
        s.revive(1)
    end
    s.settle(2)

    t.isTrue(s.row(1).kills >= 2, 'the setup is past the score limit')
    t.equals(s.row(1).tier, 1, 'and standing on tier 1 for it')
    t.equals(s.endedWith(), nil, 'a ladder does not end on a score limit')

    -- AND THE LADDER IS READ BEFORE THE CLOCK. Both conditions true at once,
    -- and the ladder is the one that decides.
    local racing = newServer(function(config)
        pinLadder(config, { { 'knife' }, { 'pistol' } })
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    racing.play(4)
    racing.trade(2, 1)
    racing.trade(3, 1)
    t.equals(racing.row(1).ladderKills, 2, 'the two-tier ladder is topped')

    racing.match_().endsAt = os.time() - 1
    racing.settle(2)
    t.equals(racing.endedWith(), 'match.ended_ladder',
        'a ladder topped on the last second of the round was still topped')
end)

t.test('the validator names the thing that is wrong, and stays quiet when nothing is', function()
    -- A SUBSTRING MATCH ON "gungame" PROVES NOTHING. There are several
    -- complaints that contain it, so a validator that fired the wrong one
    -- passed -- and a false alarm on a good config is as bad as silence on a
    -- broken one.
    local shipped = newServer()
    local quiet = {}
    for _, line in ipairs(shipped.arena.ValidateConfig() or {}) do
        if tostring(line):find('gungame', 1, true) then quiet[#quiet + 1] = line end
    end
    t.equals(#quiet, 0,
        ('a working gun game should produce no complaints, got: %s'):format(table.concat(quiet, ' | ')))

    --- Every complaint mentioning gun game, as one string.
    local function complaintsOf(mutate)
        local server = newServer(mutate)
        local said = {}
        for _, line in ipairs(server.arena.ValidateConfig() or {}) do
            if tostring(line):find('gungame', 1, true) then said[#said + 1] = tostring(line) end
        end
        return table.concat(said, '\n')
    end

    -- THE WORDING MOVED WITH THE SHAPE. The complaint now has to cover two
    -- ways of declaring a ladder -- a list of weapon CLASSES, or the flat
    -- list of tiers -- so it names both rather than only the one an operator
    -- happened to get wrong.
    t.isTrue(complaintsOf(function(config)
        pinLadder(config, 'knife')
    end):find('declares a ladder that is not a table', 1, true) ~= nil,
        'a ladder of the wrong type is named as one')

    -- AND A CLASS LIST OF THE WRONG TYPE IS NAMED THE SAME WAY.
    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.gunGameTiers = nil
        config.Modes.gungame.gunGameClasses = 'pistols'
    end):find('declares a ladder that is not a table', 1, true) ~= nil,
        'a class list of the wrong type is not named at all')

    -- AND SETTING BOTH IS ITSELF THE COMPLAINT, because one of them is doing
    -- nothing and it is silently the one an operator is likelier to have
    -- just edited.
    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.gunGameTiers = { { 'knife' }, { 'pistol' } }
    end):find('BOTH gunGameClasses and gunGameTiers', 1, true) ~= nil,
        'a config setting both shapes was not told that one of them is ignored')

    t.isTrue(complaintsOf(function(config)
        pinLadder(config, { { 'knife' } })
    end):find('a ladder needs at least two', 1, true) ~= nil, 'a one-tier ladder is named as one')

    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.roundTimeSeconds = 0
        config.Match.roundTimeSeconds = 0
    end):find('no round clock', 1, true) ~= nil, 'a clockless ladder is named as one')

    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.killReward = { { key = 'nosuchthing', count = 1 } }
    end):find('nosuchthing', 1, true) ~= nil, 'a reward naming nothing is named by key')

    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.teams = true
    end):find('climbed and won by one player', 1, true) ~= nil, 'sides on a ladder are named as pointless')

    t.isTrue(complaintsOf(function(config)
        config.Modes.gungame.maxTiersPerVictim = 'two'
    end):find('not a number', 1, true) ~= nil, 'a cap that will not parse is named')
end)

t.test('a tier may be written as a bare key, and the catalogue is never edited', function()
    -- BOTH DOCUMENTED AT LENGTH AND NEITHER EXERCISED. An operator writing
    -- one gun per step should not have to type the braces.
    local s = newServer(function(config)
        pinLadder(config, { 'knife', { 'pistol' }, 'rifle' })
    end)
    s.play(2)

    t.equals(s.tierCount(), 3, 'a bare key reads as a one-weapon tier')
    t.equals(s.ladder()[1], 'knife', 'and is the tier it was written as')
    t.equals(s.ladder()[3], 'rifle', 'in the order it was written in')

    -- THE COMPONENTS LIST IS COPIED, NEVER HELD. It is the operator's own
    -- table on the live config, and an entry that aliased it would leak one
    -- player's ammo-type component into every later loadout for everybody.
    local catalogue = s.arena.GetWeaponByKey('rifle')
    local before = #(catalogue.components or {})
    local entry = s.arena.ResolveWeaponEntry(catalogue, s.arena.ResolveAmmoType(catalogue, nil), nil)
    entry.components[#entry.components + 1] = 'at_scope_max'
    t.equals(#(catalogue.components or {}), before,
        'appending to a resolved entry edited the operator\'s live config')
end)

-- ======================================================================
-- 39-42. WHAT THE EIGHTEEN AGENTS FOUND
-- ======================================================================

t.test('a mode with one playable tier arms its players and spends their lives', function()
    -- THREE PLACES ASKED THE SAME QUESTION AND TWO ANSWERED IT DIFFERENTLY.
    -- ladderOf refuses to play a ladder of fewer than two tiers; the loadout
    -- refusal and the panel's lock asked only whether the mode had ANY
    -- playable tier. So a gun game with exactly one -- six of seven pools
    -- mistyped, or a catalogue with most weapons switched off -- had its
    -- loadout screen shut by one rule and no ladder handed out by the other,
    -- and the whole lobby walked into the arena EMPTY-HANDED.
    local s = newServer(function(config)
        pinLadder(config, { { 'knife' } })
    end)

    t.equals(s.arena.PlaysLadder('gungame'), false, 'one tier is not a ladder')

    -- SO THE PICKER IS OPEN, because there is nothing to replace it.
    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'gungame', entryFee = 0, account = 'cash',
    })
    local id = s.lobby.All()[1].id
    s.fire('joinMatch', 2, { matchId = id, account = 'cash' })
    t.equals(select(1, s.lobby.SetLoadout(1, { weapons = { { key = 'rifle' } } })), true,
        'a mode that hands out no ladder must let its players pick')

    -- AND THE MODE ADVERTISES NO LADDER, which is what the panel locks on.
    local modes = {}
    for _, mode in ipairs(s.arena.GetEnabledModes()) do modes[mode.key] = mode end
    t.equals(modes.gungame.tiers, nil, 'and says so on the wire')

    for src = 1, 2 do s.fire('setReady', src, { ready = true }) end
    for _ = 1, 4 do
        if s.lobby.Get(id).state == 'live' then break end
        s.settle(1)
    end

    -- Read off this match's own record: server.row follows the id server.play
    -- opened, and this test opened its own.
    local function row(src) return s.lobby.Get(id).players[src] end

    t.isTrue(row(1).loadout.weapons[1] ~= nil,
        'and nobody walks into the arena empty-handed')
    t.equals(row(1).loadout.weapons[1].key, 'rifle', 'they carry what they picked')

    -- AND LIVES ARE SPENT, because this is an ordinary round now.
    local before = row(1).lives
    s.kill(1, 2)
    t.equals(row(1).lives, before - 1, 'a death costs a life in a mode with no ladder')
end)

t.test('a kill claimed from across the map is not credited', function()
    -- THE SERVER CANNOT SEE A KILL. A dying client names its own killer, and
    -- until this the only questions asked of that name were "is it a real
    -- player in this match" and "were they allowed to damage me" -- so one
    -- accomplice handed another every kill in the round from anywhere on the
    -- map, without either firing a shot. That decides a team deathmatch, a
    -- last-man-standing round, and the pot.
    local places = {}
    local s = newServer(function(config)
        config.Match.maxKillDistance = 100.0
    end, nil, { positions = places })
    s.play(3)

    -- NOT THE ORIGIN for either of them: positionOf treats 0,0 as "this ped
    -- has not streamed in" and answers nil, which fails open -- so a test
    -- that parked a body there would be measuring the fail-open path while
    -- believing it was measuring the ceiling.
    places[1] = { x = 1000.0, y = 2000.0, z = 30.0 }
    places[2] = { x = 1040.0, y = 2000.0, z = 30.0 }
    s.trade(2, 1)
    t.equals(s.row(1).kills, 1, 'a kill from 40m is an ordinary kill')

    places[2] = { x = 5000.0, y = 2000.0, z = 30.0 }
    s.trade(2, 1)
    t.equals(s.row(1).kills, 1, 'a kill claimed from 4km away is not credited')
    t.equals(s.row(2).deaths, 2, 'though the death still counted -- only the credit is refused')

    -- HEIGHT COUNTS. The sky arena is a platform above the world, so a flat
    -- measurement would read a player who has fallen off it as next door.
    places[2] = { x = 1000.0, y = 2000.0, z = 4030.0 }
    s.trade(2, 1)
    t.equals(s.row(1).kills, 1, 'nor one from 4km straight down')

    -- IT FAILS OPEN. A ped the server cannot see has no position, and
    -- refusing a real kill because one body had not streamed in would take a
    -- fought kill off an honest player.
    places[2] = nil
    s.trade(2, 1)
    t.equals(s.row(1).kills, 2, 'a position the server cannot read credits the kill')

    -- AND `0` SWITCHES IT OFF.
    local off = newServer(function(config)
        config.Match.maxKillDistance = 0
    end, nil, { positions = places })
    off.play(2)
    places[1] = { x = 1000.0, y = 2000.0, z = 30.0 }
    places[2] = { x = 9000.0, y = 9000.0, z = 30.0 }
    off.trade(2, 1)
    t.equals(off.row(1).kills, 1, 'with the ceiling off, distance decides nothing')
end)

t.test('parking your weapon is not immunity from dying', function()
    -- THE TWO PATHS WERE ASYMMETRIC IN THE ATTACKER'S FAVOUR. A refused swap
    -- refunded the DEMOTION and never the promotion -- and ox_inventory
    -- refuses the removal for a tier weapon sitting in a trunk, and the add
    -- for a full inventory, both of which the player chooses. A climber who
    -- arranged either was immune to the only cost this mode has while their
    -- kills went on counting.
    local s = newServer()
    s.play(4)

    for _, victim in ipairs({ 2, 3, 4 }) do s.trade(victim, 1) end
    t.equals(s.row(1).tier, 4, 'three kills up')

    -- Their pockets refuse everything from here: the demotion cannot move.
    for tier = 1, s.tierCount() do s.ox.refuseAdd[weaponAt(s, tier)] = true end
    s.ox.pockets[1] = {}

    local lost = s.row(1).tiersLost or 0
    s.kill(1, 2)
    s.revive(1)

    t.equals((s.row(1).tiersLost or 0), lost + 1,
        'a death costs a tier whether or not the weapon would move')
    t.equals(s.row(1).kills, 3, 'and the kills they earned are untouched')

    -- THE SCORE IS WHAT THEY EARNED, so the board and the winner follow it
    -- even while their hands do not.
    s.settle(1)
    local board = s.board()
    local mine
    for _, row in ipairs(board) do if row.id == 1 then mine = row end end
    t.isTrue(mine ~= nil, 'the climber is on the board')
    t.equals(mine.tier, 3, 'showing the tier their score earned, not the one they hold')
end)

t.test('the results board ranks a gun game on the ladder, not on raw kills', function()
    -- THE MODE HANDED ITS WINNER A LOSING PLACEMENT. The board sorts on the
    -- earned tier and decideOnLadder crowns it; assignFinalPlacements ranked
    -- on raw kills -- so the results card read "You Won" and "Placed #2" at
    -- the same time, because a player who traded three kills for three
    -- deaths outranked one who took two for nothing six tiers above them.
    local s = newServer(function(config)
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    s.play(5)

    -- Fighter 1: two kills, no deaths.
    s.trade(3, 1)
    s.trade(4, 1)
    -- Fighter 2: three kills and three deaths -- ahead on kills, on tier 1.
    s.trade(3, 2)
    s.trade(4, 2)
    s.trade(5, 2)
    -- FIGHTER 2'S DEATHS HAVE NO KILLER, so nobody else climbs on them --
    -- charging them to fighter 5 made FIVE the ladder leader, and the first
    -- draft of this test asserted against a winner it had created itself.
    for _ = 1, 3 do
        s.kill(2, nil)
        s.revive(2)
    end

    t.isTrue(s.row(2).kills > s.row(1).kills, 'fighter 2 is ahead on kills')
    t.isTrue(s.row(1).tier > s.row(2).tier, 'and fighter 1 is ahead on the ladder')

    s.match_().endsAt = os.time() - 1
    s.settle(2)

    t.equals(table.concat(s.winners(), ','), '1', 'the ladder leader wins')

    local won, lost = s.resultFor(1), s.resultFor(2)
    t.isTrue(won ~= nil and lost ~= nil, 'both fighters were sent a results card')
    t.equals(won.won, true, 'the ladder leader is told they won')
    t.equals(won.placement, 1,
        ('and placed first -- the card used to read "You Won" and "Placed #%s" at once')
            :format(tostring(won.placement)))
    t.isTrue(won.placement < lost.placement,
        ('the winner outranks the kill leader -- got #%s against #%s')
            :format(tostring(won.placement), tostring(lost.placement)))
end)

t.test('a fighter who is out of the round cannot be credited with a kill', function()
    -- ELIMINATED, RANKED LAST, STANDING AT THE LOBBY NPC -- and winning on
    -- most kills anyway, because resolveKiller asked only whether the named
    -- killer was a real player who was allowed to damage the victim.
    --
    -- Run on an ORDINARY mode, because that is where lives are spent and
    -- where the hole actually bit. A gun game eliminates nobody.
    local s = newServer()
    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    local id = s.lobby.All()[1].id
    for src = 2, 3 do s.fire('joinMatch', src, { matchId = id, account = 'cash' }) end
    for src = 1, 3 do s.fire('setReady', src, { ready = true }) end
    for _ = 1, 4 do
        if s.lobby.Get(id).state == 'live' then break end
        s.settle(1)
    end
    local function row(src) return s.lobby.Get(id).players[src] end

    -- A DEAD KILLER IS STILL CREDITED, and must stay that way: two fighters
    -- who kill each other in the same tick are both corpses when the reports
    -- arrive, and refusing those would delete half of every trade.
    row(1).alive = false
    s.match.OnDeath(2, 1)
    t.equals(row(1).kills, 1, 'a killer who is merely dead still scored')
    row(1).alive = true
    row(2).alive = true

    -- ELIMINATED IS A DIFFERENT FACT: no lives left, the round has finished
    -- with them.
    row(1).lives = 0
    row(1).alive = false
    t.equals(s.arena.IsEliminated(row(1)), true, 'the setup really eliminated them')

    s.match.OnDeath(3, 1)
    t.equals(row(1).kills, 1, 'and an eliminated fighter is credited with nothing')
    t.equals(row(3).deaths, 1, 'though the death still counted')

    -- NOR ONE WHO HAS ALREADY BEEN SENT HOME.
    row(1).lives = 3
    row(1).alive = true
    row(1).leftArena = true
    row(2).alive = true
    s.match.OnDeath(2, 1)
    t.equals(row(1).kills, 1, 'nor a fighter already standing back at the lobby')
end)

t.test('a tier tie is broken on the capped number, not the uncapped one', function()
    -- `kills` IS THE ONE NUMBER THE CAP DELIBERATELY LEAVES ALONE -- a kill
    -- past maxTiersPerVictim still counts as a kill, it just stops buying
    -- tiers -- so breaking a tier tie on it handed the decider straight back
    -- to the farm the cap exists to stop.
    local s = newServer(function(config)
        pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' } })
        config.Modes.gungame.maxTiersPerVictim = 1
        config.Modes.gungame.roundTimeSeconds = 120
    end)
    s.play(5)

    -- Fighter 1 climbs honestly: two different victims, two credited kills.
    s.trade(3, 1)
    s.trade(4, 1)

    -- Fighter 2 reaches the SAME two credited kills -- one off each of two
    -- victims -- and then farms one of them seven more times. Those seven
    -- count as kills and buy nothing, which is the whole point of the cap.
    s.trade(3, 2)
    s.trade(5, 2)
    for _ = 1, 7 do s.trade(5, 2) end

    t.isTrue(s.row(2).kills > s.row(1).kills,
        ('the farmer is ahead on raw kills: %d against %d')
            :format(s.row(2).kills, s.row(1).kills))
    t.equals(s.row(1).ladderKills, 2, 'the honest climber has two credited kills')
    t.equals(s.row(2).ladderKills, 2, 'and the farmer has exactly the same two')
    t.equals(s.row(1).tier, s.row(2).tier, 'so they are level on tiers')

    s.match_().endsAt = os.time() - 1
    s.settle(2)
    t.equals(s.endedWith(), 'match.ended_draw',
        'level on tiers AND on credited kills is a draw -- raw kills must not break it')
end)

-- ======================================================================
-- 44-49. WHAT THE RE-VERIFICATION FOUND
-- ======================================================================

t.test('accomplices walking out does not raise the per-victim cap', function()
    -- THE EXPLOIT, END TO END. The cap floor divides the ladder by the
    -- number of OPPONENTS, and that was counted live off `match.players` --
    -- a table ArenaLobby.Leave deletes a departed fighter's row from. So the
    -- divisor shrank as people left and the cap rose with it, and because
    -- the spent count persists the raise RETROACTIVELY reopened a victim the
    -- cap had already closed. The attacker chooses when it happens, which
    -- makes it a button rather than an accident.
    --
    -- Six fighters, a seven-tier ladder: five opponents gives ceil(7/5) = 2,
    -- the shipped cap. Farm three accomplices flat out -> 6 credits, one
    -- short of the top. Two accomplices leave: four on the roster, three
    -- opponents, ceil(7/3) = 3, and one more kill on an already-farmed
    -- victim tops the ladder.
    local s = newServer(sevenTiers)
    s.play(6)
    local top = s.tierCount()
    t.equals(top, 7, 'the pinned ladder is seven tiers, which is what this arithmetic assumes')

    for _, victim in ipairs({ 2, 3, 4 }) do
        for _ = 1, 5 do s.trade(victim, 1) end
    end
    t.equals(s.row(1).ladderKills, 6,
        'three victims at the shipped cap of 2 is six credits, one short of the top')

    -- THE BUTTON.
    s.fire('leaveMatch', 5)
    s.fire('leaveMatch', 6)
    t.isNil(s.match_().players[5], 'the fixture did not really remove the leavers')

    for _ = 1, 5 do s.trade(2, 1) end
    t.equals(s.row(1).ladderKills, 6,
        'a victim the cap had closed must not reopen because somebody else left')

    s.settle(2)
    t.equals(s.endedWith(), nil, 'and the ladder must not be topped by it')
end)

t.test('and the latched roster still lets a small lobby reach the top', function()
    -- THE OTHER DIRECTION, because latching the roster at the start is only
    -- right if it is the roster the FLOOR was written for. A three-man lobby
    -- has two opponents against seven tiers, so the floor really is four
    -- apiece -- and it has to stay four for the whole round rather than
    -- being recomputed away.
    local s = newServer()
    s.play(3)
    t.equals(s.match_().ladderSpread, 3, 'the roster is latched when the round starts')

    for round = 1, s.tierCount() do s.trade(2 + (round % 2), 1) end
    t.equals(s.row(1).ladderKills, s.tierCount(), 'a three-man lobby can still top the ladder')
    s.settle(2)
    t.equals(s.endedWith(), 'match.ended_ladder', 'and the round ends on it')
end)

t.test('a supply named twice in one kill reward shares one ceiling', function()
    -- EACH ENTRY WAS CLAMPED ON ITS OWN, so N lines naming the same supply
    -- each drew the full `max`: two lines paid 60 bandages against a ceiling
    -- of 30, ten lines paid 300. The validator promised "it is clamped to
    -- the max" for a single over-large line while saying nothing at all
    -- about the duplicate that breaks the same promise.
    --
    -- The sibling field startingKit has always deduplicated -- it reads the
    -- kit in catalogue order rather than in written order -- so the two
    -- halves of the same config disagreed about what a repeated key means.
    local s = newServer(function(config)
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 99999 },
            { key = 'bandage', count = 99999 },
            { key = 'bandage', count = 99999 },
        }
    end)
    s.play(3)

    local supply
    for _, entry in ipairs(s.config.Loadouts.supplies.items) do
        if entry.key == 'bandage' then supply = entry end
    end
    assert(supply, 'the fixture cannot find the bandage supply')
    local ceiling = s.arena.SupplyMax(supply)
    t.isTrue(ceiling > 0, 'the bandage supply has no max, so this test measures nothing')

    local before = s.ox.count(1, supply.item)
    s.trade(2, 1)
    local paid = s.ox.count(1, supply.item) - before

    t.equals(paid, ceiling,
        ('three lines naming one supply paid %d against a ceiling of %d'):format(paid, ceiling))
end)

t.test('and the operator is told about the duplicate rather than left to find it', function()
    local s = newServer(function(config)
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 5 },
            { key = 'bandage', count = 5 },
        }
    end)

    local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('more than once', 1, true) ~= nil,
        ('the complaint should say the key is repeated -- got: %s'):format(said))
    t.isTrue(said:find('killReward', 1, true) ~= nil,
        ('and name the field it is in -- got: %s'):format(said))

    -- QUIET ON THE SHIPPED REWARD, which names each supply once.
    local clean = newServer()
    local quiet = table.concat(clean.arena.ValidateConfig() or {}, '\n')
    t.isTrue(quiet:find('more than once', 1, true) == nil,
        ('the shipped gun game raised a duplicate complaint: %s'):format(quiet))
end)

t.test('the total-supplies ceiling binds the mode kit and the kill reward too', function()
    -- `supplies.totalItems` is documented as "a ceiling across ALL supplies
    -- together, not per entry", and the loadout picker has always honoured
    -- it. The mode kit and the kill reward did not: with a ceiling of 3, a
    -- kit naming two supplies at their own maxima walked in holding 55 items
    -- and one credited kill handed over 55 more -- while the picker on the
    -- same screen was refusing anything past 3.
    local s = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        config.Modes.gungame.startingKit = {
            { key = 'armour', count = 25 },
            { key = 'bandage', count = 30 },
        }
        config.Modes.gungame.killReward = {
            { key = 'armour', count = 25 },
            { key = 'bandage', count = 30 },
        }
    end)
    s.play(3)

    --- Every supply item one fighter is holding, added up.
    local function carried(src)
        local total = 0
        for _, entry in ipairs(s.config.Loadouts.supplies.items) do
            total = total + s.ox.count(src, entry.item)
        end
        return total
    end

    t.equals(carried(1), 3, 'the mode kit walked past the ceiling of 3')

    local before = carried(1)
    s.trade(2, 1)
    t.equals(carried(1) - before, 3, 'and one kill paid past it')
end)

t.test('and the operator is told when a mode names more than the ceiling allows', function()
    local s = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        config.Modes.gungame.startingKit = {
            { key = 'armour', count = 2 },
            { key = 'bandage', count = 5 },
        }
    end)

    local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('totalItems', 1, true) ~= nil,
        ('the complaint should name the ceiling -- got: %s'):format(said))
    t.isTrue(said:find('startingKit', 1, true) ~= nil,
        ('and the field that is over it -- got: %s'):format(said))

    -- QUIET WHEN THERE IS NO CEILING, which is what ships: 0 means no limit,
    -- and complaining about a kit that is "over" it would fire on every
    -- default server.
    local clean = newServer(function(config)
        config.Loadouts.supplies.totalItems = 0
    end)
    local quiet = table.concat(clean.arena.ValidateConfig() or {}, '\n')
    t.isTrue(quiet:find('totalItems', 1, true) == nil,
        ('a ceiling of 0 raised a complaint: %s'):format(quiet))
end)

t.test('the kit ceiling is not spent on a supply the server cannot hand over', function()
    -- A CATALOGUE ENTRY WITH NO `item` NAME is dropped by ArenaAmmo before
    -- ox_inventory is asked for anything -- both siblings guard for it, and
    -- Arena.StartingKitFor did not. So the ceiling was debited for a phantom
    -- and the mode's real kit got what was left, which was nothing.
    local s = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        for _, entry in ipairs(config.Loadouts.supplies.items) do
            if entry.key == 'armour' then entry.item = nil end
        end
        config.Modes.gungame.startingKit = {
            { key = 'armour', count = 3 },
            { key = 'bandage', count = 3 },
        }
    end)
    s.play(3)

    local bandage
    for _, entry in ipairs(s.config.Loadouts.supplies.items) do
        if entry.key == 'bandage' then bandage = entry.item end
    end
    assert(bandage, 'the fixture cannot find the bandage item')

    t.equals(s.ox.count(1, bandage), 3,
        'the whole ceiling was spent on a supply that is never handed over')
end)

t.test('a duplicated kit key is reported as last-wins, not as a shared ceiling', function()
    -- THE TWO FIELDS DO NOT AGREE ABOUT WHAT A REPEAT COSTS, and one
    -- sentence for both was wrong for one of them: payKillReward shares one
    -- ceiling between the lines, while Arena.StartingKitFor keys the kit
    -- first and walks the catalogue second, so the LAST line simply wins.
    local kit = newServer(function(config)
        config.Modes.gungame.startingKit = {
            { key = 'bandage', count = 5 },
            { key = 'bandage', count = 5 },
        }
    end)
    local said = table.concat(kit.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('Only the last line counts', 1, true) ~= nil,
        ('the kit complaint should say the earlier line is thrown away -- got: %s'):format(said))
    t.isTrue(said:find('share that supply', 1, true) == nil,
        ('and must not describe an addition the kit never does -- got: %s'):format(said))

    -- AND THE REWARD KEEPS ITS OWN, TRUE, SENTENCE.
    local reward = newServer(function(config)
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 5 },
            { key = 'bandage', count = 5 },
        }
    end)
    local paid = table.concat(reward.arena.ValidateConfig() or {}, '\n')
    t.isTrue(paid:find('share that supply', 1, true) ~= nil,
        ('the reward complaint should say the lines share one ceiling -- got: %s'):format(paid))
end)

t.test('and the ceiling total counts a repeated key the way its own reader does', function()
    -- Summing every line reported a kit of two 20-bandage entries as 40
    -- against a ceiling of 30 while the server issues 20 -- a boot complaint
    -- about a config that fits, which is the same cost as silence on one
    -- that does not.
    local s = newServer(function(config)
        config.Loadouts.supplies.totalItems = 30
        config.Modes.gungame.startingKit = {
            { key = 'bandage', count = 20 },
            { key = 'bandage', count = 20 },
        }
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 20 },
            { key = 'bandage', count = 20 },
        }
    end)
    local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('adds up to', 1, true) == nil,
        ('neither list is over the ceiling and both were reported: %s'):format(said))

    -- A LIST THAT REALLY IS OVER IT STILL FIRES, so the check above is not
    -- measuring a validator that has stopped looking.
    local over = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        config.Modes.gungame.startingKit = {
            { key = 'armour', count = 2 },
            { key = 'bandage', count = 5 },
        }
    end)
    local loud = table.concat(over.arena.ValidateConfig() or {}, '\n')
    t.isTrue(loud:find('adds up to 7 items', 1, true) ~= nil,
        ('a genuinely over-ceiling kit was not reported: %s'):format(loud))
    t.isTrue(loud:find('in catalogue order', 1, true) ~= nil,
        ('and the kit is read in catalogue order, which the message should say: %s'):format(loud))
end)

t.test('and a kill reward that can never pay costs nothing against the ceiling', function()
    -- `chance = 0` is the documented way to switch one reward line off, and
    -- payKillReward's own roll refuses it -- so counting it at full value
    -- complained about items nobody is ever handed.
    local s = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        -- THE KIT OUT OF THE WAY. The shipped one is six items and would
        -- raise its own, correct, complaint against a ceiling of three --
        -- which is a different sentence about a different field, and a test
        -- that matched it would pass whatever the reward did.
        config.Modes.gungame.startingKit = {}
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 25, chance = 0 },
        }
    end)
    local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('killReward adds up to', 1, true) == nil,
        ('a line at chance = 0 was counted against the ceiling: %s'):format(said))

    -- AND A LINE THAT CAN PAY IS STILL COUNTED, so the guard above is not
    -- simply switching the check off for the whole field.
    local live = newServer(function(config)
        config.Loadouts.supplies.totalItems = 3
        config.Modes.gungame.startingKit = {}
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 25, chance = 50 },
        }
    end)
    local loud = table.concat(live.arena.ValidateConfig() or {}, '\n')
    t.isTrue(loud:find('killReward adds up to', 1, true) ~= nil,
        ('a reward that really is over the ceiling was not reported: %s'):format(loud))
    t.isTrue(loud:find('in the order the entries are written', 1, true) ~= nil,
        ('and the reward is read in written order, which the message should say: %s'):format(loud))
end)

t.test('and the operator is told about a ceiling that is not one', function()
    -- MATCHED ON THE SENTENCE'S OWN OPENING ("totalItems is"), because the
    -- per-mode complaint one screen above says "over ... totalItems of" and
    -- a looser match would pass on either.
    for _, junk in ipairs({ -1, 'lots', true }) do
        local s = newServer(function(config)
            config.Loadouts.supplies.totalItems = junk
        end)
        local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
        t.isTrue(said:find('supplies.totalItems is', 1, true) ~= nil,
            ('totalItems = %s raised no complaint: %s'):format(tostring(junk), said))
        t.isTrue(said:find('NO ceiling', 1, true) ~= nil,
            ('and did not say what it is really read as: %s'):format(said))
    end

    -- 0 IS A DELIBERATE CHOICE, not a typo, and nil is the shipped default.
    for _, fine in ipairs({ 0, 50 }) do
        local clean = newServer(function(config)
            config.Loadouts.supplies.totalItems = fine
        end)
        local quiet = table.concat(clean.arena.ValidateConfig() or {}, '\n')
        t.isTrue(quiet:find('supplies.totalItems is', 1, true) == nil,
            ('totalItems = %d raised a complaint: %s'):format(fine, quiet))
    end
end)

t.test('and about a supply nobody can ever be handed', function()
    local s = newServer(function(config)
        for _, entry in ipairs(config.Loadouts.supplies.items) do
            if entry.key == 'armour' then entry.max = 0 end
        end
    end)
    local said = table.concat(s.arena.ValidateConfig() or {}, '\n')
    t.isTrue(said:find('max of 0', 1, true) ~= nil,
        ('a supply with a max of 0 raised no complaint: %s'):format(said))
    t.isTrue(said:find('enabled = false', 1, true) ~= nil,
        ('and was not told how to switch it off properly: %s'):format(said))

    local clean = newServer()
    local quiet = table.concat(clean.arena.ValidateConfig() or {}, '\n')
    t.isTrue(quiet:find('max of 0', 1, true) == nil,
        ('the shipped catalogue raised the complaint: %s'):format(quiet))
end)

t.test('a ladder round crowns a climber, not a side, so no side is named', function()
    -- `winningPick` answers "which side is this round settled against" --
    -- the question the spectator side-bets ask, and the right answer for
    -- them. The results card asks a different one, and a team mode running a
    -- ladder settles on ONE climber: naming their side on the card told
    -- their team-mates their side had taken it, on the same card that tells
    -- them they had not.
    local s = newServer(function(config)
        -- A LADDER MODE WITH SIDES, which is the shape the two answers come
        -- apart in and which nothing else in this file builds.
        config.Modes.gungame.teams = true
    end)
    s.play(4)
    for src = 1, 4 do
        s.fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
    end

    -- ONE CLIMBER, ENDED ON THE CLOCK. decideOnLadder crowns the highest
    -- tier when the round stops, which is one player -- fighter 3 is on
    -- crimson with them and has climbed nothing.
    s.trade(2, 1)
    s.trade(4, 1)
    s.match_().endsAt = os.time() - 1
    s.settle(3)

    local card = s.resultFor(1)
    t.isTrue(card ~= nil, 'the climber was sent no results card at all')
    t.isTrue(card.won == true, 'the highest climber should have taken the round')
    t.isTrue(s.resultFor(3) ~= nil and s.resultFor(3).won ~= true,
        'their team-mate climbed nothing and must not be a winner -- otherwise this proves nothing')

    t.isNil(card.winningTeam,
        'a ladder round crowned one climber and told their whole side they had won it')
    t.isNil(s.resultFor(3).winningTeam,
        'and told the team-mate who lost that their side had taken it')
end)

-- ======================================================================
-- THE ADJUSTABLE CLOCK
-- ======================================================================

t.test('a host can set how long the round runs, and it is what runs', function()
    -- THE MODE IS DECIDED BY ITS CLOCK, so the clock was the one rule of it
    -- a host could not set. Arena.RoundSecondsFor read the mode's config
    -- value and then the server's, and nothing else -- so "adjustable timer"
    -- meant editing config.lua and restarting.
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = { allowChoose = true, min = 60, max = 3600, default = 600 }
    end)

    local designed = s.arena.RoundSecondsFor('gungame')
    t.equals(designed, 480, 'the shipped gun game no longer runs its own 480 seconds')

    -- THE HOST'S NUMBER WINS OVER THE MODE'S OWN.
    t.equals(s.arena.RoundSecondsFor('gungame', 900), 900,
        'a host who set 900 seconds is not getting 900 seconds')

    -- AND LEAVING IT ALONE STILL RUNS THE MODE'S DESIGNED CLOCK. 0 is what
    -- the match stores for "the host did not choose", and reading it as a
    -- real answer would give every untouched gun game no clock at all.
    t.equals(s.arena.RoundSecondsFor('gungame', 0), 480,
        'a host who chose nothing lost the mode\'s own clock')
    t.equals(s.arena.RoundSecondsFor('gungame', nil), 480,
        'and nil is the same as not choosing')
end)

t.test('and the clock the round really counts down from is the one they set', function()
    -- END TO END, through the real createMatch handler and the real Start,
    -- because the number agreeing in Arena and disagreeing on the match is
    -- exactly the shape of the defect this fixes.
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = { allowChoose = true, min = 60, max = 3600, default = 600 }
    end)

    s.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'gungame', entryFee = 0, account = 'cash',
        roundTimeSeconds = 900,
    })
    local match = s.lobby.All()[1]
    t.equals(match.roundTimeSeconds, 900, 'the host\'s choice never reached the match')

    for src = 2, 3 do s.fire('joinMatch', src, { matchId = match.id, account = 'cash' }) end
    for src = 1, 3 do s.fire('setReady', src, { ready = true }) end
    for _ = 1, 4 do if s.lobby.Get(match.id).state == 'live' then break end s.settle(1) end

    local live = s.lobby.Get(match.id)
    t.equals(live.state, 'live', 'the round did not start')
    t.equals(live.endsAt - live.startsAt, 900,
        ('the round was scheduled for %d seconds, not the 900 the host set')
            :format((live.endsAt or 0) - (live.startsAt or 0)))
end)

t.test('and a length this server does not allow is refused, not quietly clamped', function()
    -- The same rule Arena.ResolveLives follows: a host who typed 9999 and
    -- silently got 3600 would believe they were running a different match.
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = { allowChoose = true, min = 60, max = 3600, default = 600 }
    end)

    local id, why = s.lobby.Create(1, 'trailerpark', 'gungame', 0, nil, false, 'cash', 9999)
    t.isNil(id, 'a round length over the maximum was accepted')
    t.equals(why, 'error.round_time_out_of_range', 'and the refusal has to say which rule')

    local low, lowWhy = s.lobby.Create(1, 'trailerpark', 'gungame', 0, nil, false, 'cash', 10)
    t.isNil(low, 'a round length under the minimum was accepted')
    t.equals(lowWhy, 'error.round_time_out_of_range', 'and likewise')

    -- AND ONE INSIDE THE RANGE IS TAKEN.
    local ok = s.lobby.Create(1, 'trailerpark', 'gungame', 0, nil, false, 'cash', 1200)
    t.isTrue(ok ~= nil, 'a legal round length was refused')
end)

t.test('and an operator who fixes the number takes the control away', function()
    -- The plain-number shape. Every reader has to keep working, and the
    -- panel must be sent no range at all -- a control that cannot change
    -- anything invites a host to try.
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = 600
    end)

    t.equals(s.arena.RoundTimeDefault(), 600, 'a plain number stopped being read')
    t.isNil(s.arena.RoundTimeChoice(), 'a fixed length still offered the host a range')

    -- AND A HOST WHO ASKS ANYWAY IS IGNORED RATHER THAN REFUSED: a stale
    -- panel is not a tampered payload, and the round runs the mode's clock.
    local seconds, why = s.arena.ResolveRoundTime(900)
    t.equals(seconds, 0, 'a request on a server that does not offer the choice was honoured')
    t.isNil(why, 'and it must not be reported as an error')
end)

t.test('and the mode\'s clock still beats the server default', function()
    local s = newServer(function(config)
        config.Match.roundTimeSeconds = { allowChoose = true, min = 60, max = 3600, default = 600 }
    end)
    t.equals(s.arena.RoundSecondsFor('gungame'), 480, 'the mode lost its own clock')
    t.equals(s.arena.RoundSecondsFor('ffa'), 600, 'and an ordinary mode lost the server default')
end)

-- ======================================================================
-- 50+. WHAT A TIER CHANGE TAKES AWAY, AND WHAT IT HANDS OVER
-- ======================================================================

t.test('a swap leaves the climber holding this tier\'s weapon and no other rung\'s', function()
    -- THE GUARANTEE, ASSERTED AT THE API RATHER THAN THROUGH A CONTRIVED
    -- ROUND. The swap used to take back exactly ONE weapon: the tier the
    -- player was standing on. That is right for a single step and wrong for
    -- every other way a rung can end up in somebody's pockets -- a removal
    -- ox_inventory refused while the score moved on, a second issue, an
    -- operator's pools drawing a gun twice. Each of those left a climber
    -- carrying a weapon from a tier they are not on, and a climber who has
    -- collected the best gun on the ladder is a climber for whom the ladder
    -- has stopped mattering.
    --
    -- Driven through ArenaAmmo directly because the ladder's own paths cannot
    -- currently produce that state -- which is the point: this is the check
    -- that says so, so that the day some path can, it is caught here rather
    -- than in a round.
    local s = newServer(sevenTiers)
    s.play(3)
    local matchId = s.matchId()

    local two = s.arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })
    local three = s.arena.ResolveLoadout({ weapons = { { key = 'combatpistol' } } })
    local four = s.arena.ResolveLoadout({ weapons = { { key = 'heavypistol' } } })

    -- ON THE ARENA'S OWN BOOKS, which is the only thing the sweep will touch:
    -- a weapon the record does not list is not one this match issued, and
    -- reaching past the books into a player's own property is the bug the
    -- record exists to prevent.
    s.ammo.Issue(1, matchId, {
        weapons = { two.weapons[1], three.weapons[1] },
        supplies = {},
    })
    t.equals(s.ox.count(1, two.weapons[1].weapon), 1, 'the fixture issued nothing')
    t.equals(s.ox.count(1, three.weapons[1].weapon), 1, 'the fixture issued only one of the two')

    local ladder = { two.weapons[1].weapon, three.weapons[1].weapon, four.weapons[1].weapon }
    local swapped = s.ammo.SwapWeapon(1, matchId, ladder[1], four.weapons[1], ladder)
    t.isTrue(swapped, 'the swap was refused outright')

    t.equals(s.ox.count(1, ladder[3]), 1, 'they should hold the tier they moved onto')
    t.equals(s.ox.count(1, ladder[1]), 0, 'the rung below was left in their pockets')
    t.equals(s.ox.count(1, ladder[2]), 0,
        'a rung that was NOT the one below was left in their pockets -- the whole defect')
end)

t.test('and a rung it cannot take back does not halt the ladder', function()
    -- THE ANTI-PARKING RULE IS ON THE RUNG BELOW, AND ONLY THERE. Refusing
    -- the whole swap because a gun from four tiers ago will not come off
    -- would freeze a player on a tier for the rest of a round over something
    -- they did minutes earlier -- and ox_inventory refuses a removal it
    -- cannot satisfy for reasons a player does not always choose.
    local s = newServer(sevenTiers)
    s.play(3)
    local matchId = s.matchId()

    local two = s.arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })
    local three = s.arena.ResolveLoadout({ weapons = { { key = 'combatpistol' } } })
    local four = s.arena.ResolveLoadout({ weapons = { { key = 'heavypistol' } } })

    s.ammo.Issue(1, matchId, {
        weapons = { two.weapons[1], three.weapons[1] },
        supplies = {},
    })

    -- PARKED. The record still lists it; the player no longer holds it, so
    -- ox_inventory refuses the removal -- exactly a weapon in a trunk.
    s.ox:RemoveItem(1, three.weapons[1].weapon, 1)

    local ladder = { two.weapons[1].weapon, three.weapons[1].weapon, four.weapons[1].weapon }
    local swapped, why = s.ammo.SwapWeapon(1, matchId, ladder[1], four.weapons[1], ladder)
    t.isTrue(swapped, ('an unreachable older rung refused the whole climb: %s'):format(tostring(why)))
    t.equals(s.ox.count(1, ladder[3]), 1, 'and they are holding the tier they earned')

    -- AND THE RUNG BELOW STILL REFUSES IT, which is the rule that stops a
    -- player parking the tier weapon between the kill and the promotion and
    -- ending up armed with both.
    local parked = newServer(sevenTiers)
    parked.play(3)
    local other = parked.matchId()
    local low = parked.arena.ResolveLoadout({ weapons = { { key = 'pistol' } } })
    local high = parked.arena.ResolveLoadout({ weapons = { { key = 'heavypistol' } } })

    parked.ammo.Issue(1, other, { weapons = { low.weapons[1] }, supplies = {} })
    parked.ox:RemoveItem(1, low.weapons[1].weapon, 1)

    local moved, reason = parked.ammo.SwapWeapon(1, other, low.weapons[1].weapon, high.weapons[1],
        { low.weapons[1].weapon, high.weapons[1].weapon })
    t.isFalse(moved, 'parking the tier weapon bought a free promotion')
    t.equals(reason, 'refused', 'and the caller must be told why, so the tier does not move')
    t.equals(parked.ox.count(1, high.weapons[1].weapon), 0, 'and nothing was handed over')
end)

t.test('and the rounds those rungs were issued go back with them', function()
    -- ONE-WAY AMMUNITION DISPENSER. Nothing took loose rounds back on a tier
    -- change, so every rung a climber had ever stood on left its ammunition
    -- in their pockets for the rest of the round -- ten tiers in, a player was
    -- carrying ten calibres and could reload a gun they no longer had. And
    -- because deaths cost no lives in this mode, walking a tier boundary was
    -- a free batch each way.
    local s = newServer(function(config)
        -- TWO CALIBRES, deliberately: the tier being left behind fires
        -- something the tier being climbed onto does not, so "took the wrong
        -- one back" and "took none back" are different results.
        pinLadder(config, {
            { 'knife' }, { 'pistol' }, { 'pistol50' },
        })
    end)
    s.play(3)

    s.trade(2, 1)
    local second = s.row(1).loadout.weapons[1]
    t.isTrue(s.arena.IsKey(second.ammoTypeItem), 'tier 2 names no ammo item, so this proves nothing')
    t.isTrue(s.ox.count(1, second.ammoTypeItem) > 0, 'tier 2 was issued no loose rounds at all')

    s.trade(3, 1)
    local third = s.row(1).loadout.weapons[1]
    t.isTrue(third.ammoTypeItem ~= second.ammoTypeItem,
        'the two tiers share a calibre, so this test cannot tell the cases apart')

    t.equals(s.ox.count(1, second.ammoTypeItem), 0,
        'the rounds for the tier they left are still in their pockets')
    t.isTrue(s.ox.count(1, third.ammoTypeItem) > 0,
        'and the tier they climbed onto was issued none')
end)

t.test('a demotion takes back what the tier above handed out', function()
    -- THE OTHER DIRECTION, and it is the one that made the ladder a pump:
    -- climb, step off a roof, climb again, and collect another batch each
    -- way. In the player's words: "when going down tiers it removes all that
    -- stuff it gave you".
    local s = newServer(function(config)
        pinLadder(config, {
            { 'knife' }, { 'pistol' }, { 'pistol50' },
        })
    end)
    s.play(3)

    s.trade(2, 1)
    s.trade(3, 1)
    local third = s.row(1).loadout.weapons[1]
    local thirdWeapon = third.weapon

    s.kill(1, 2)
    s.revive(1)

    t.equals(s.row(1).tier, 2, 'the death did not cost a tier')
    t.equals(s.ox.count(1, thirdWeapon), 0, 'the demotion left the higher tier\'s weapon on them')
    t.equals(s.ox.count(1, third.ammoTypeItem), 0,
        'and it left the higher tier\'s ammunition on them, which is the pump')
end)

t.test('a tier weapon carries the mode\'s tier ammunition, not the weapon\'s own default', function()
    -- "when going up tiers it should give 200 ammo for the weapons".
    --
    -- A promotion sweeps the previous rung's rounds away with its gun, so
    -- whatever lands here is the WHOLE supply for that tier -- and the
    -- per-weapon default is 60 for a sidearm, which is a magazine and a half
    -- to fight a rung with.
    local s = newServer(sevenTiers)
    s.play(3)
    s.trade(2, 1)

    local entry = s.row(1).loadout.weapons[1]
    t.equals(entry.ammo, 200, 'the tier weapon did not carry the mode\'s tier ammunition')

    -- AND ALL OF IT REACHES THEM: one magazine in the gun, the rest as items.
    local magazine = s.arena.MagazineFor(s.arena.GetWeaponByKey(entry.key), entry.ammo)
    t.equals(s.ox.metaOf(1, entry.weapon).ammo, magazine, 'one magazine in the gun')
    t.equals(s.ox.count(1, entry.ammoTypeItem), entry.ammo - magazine,
        'and the remainder as loose rounds')
end)

t.test('and a mode that names none falls back to the weapon\'s own default', function()
    -- DELETING THE LINE HAS TO STILL WORK, which is what config.lua promises
    -- of it -- otherwise the setting is not optional, it is load-bearing.
    local s = newServer(function(config)
        sevenTiers(config)
        config.Modes.gungame.tierAmmo = nil
    end)
    s.play(3)
    s.trade(2, 1)

    local entry = s.row(1).loadout.weapons[1]
    local catalogue = s.arena.GetWeaponByKey(entry.key)
    t.equals(entry.ammo, catalogue.ammo.default,
        'a mode with no tier ammunition should hand out the weapon\'s own default')
    t.isTrue(entry.ammo > 0, 'and that default is not zero, so this test is not vacuous')
end)

-- ======================================================================
-- 56+. WHAT A RESPAWN HANDS BACK, IN THE MODES THAT HAVE ONE
-- ======================================================================

t.test('a respawn puts a free-for-all fighter back on a full loadout', function()
    -- IN THE PLAYER'S WORDS: "upon a death it should refresh your inventory
    -- to be full just like at a start of a match with standard shit -- for
    -- team deathmatch and free for all".
    --
    -- WHY IT DID NOT. ox_inventory carries weapons through a death and the
    -- magazine rides in the item's metadata, so a fighter stood back up
    -- holding the same gun with the same empty magazine, the rounds they had
    -- fired gone, and the plate they had taken gone with it. Each life
    -- started worse than the one before it, which means the fighter who is
    -- losing is the one least able to come back. Nothing said so; the round
    -- simply got quieter.
    local s = newServer()
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, {
            weapons = { { key = 'pistol', ammo = 120 } },
            supplies = { { key = 'bandage', count = 3 } },
        })
    end)

    local loadout = s.row(1).loadout
    local gun = loadout.weapons[1]
    t.isTrue(s.arena.IsKey(gun.ammoTypeItem), 'the picked weapon names no ammo item')

    -- A LIFE SPENT. Fired most of the loose rounds, used the bandages, and
    -- the magazine in the gun is not full any more.
    local rounds = s.ox.count(1, gun.ammoTypeItem)
    t.isTrue(rounds > 0, 'the fixture issued no loose rounds, so there is nothing to spend')
    s.ox:RemoveItem(1, gun.ammoTypeItem, rounds)
    s.ox:RemoveItem(1, 'bandage', s.ox.count(1, 'bandage'))
    t.equals(s.ox.count(1, gun.ammoTypeItem), 0, 'the fixture did not really spend the rounds')

    s.kill(1, 2)
    s.step(6)

    t.isTrue(s.row(1).alive, 'the respawn thread did not run')
    t.equals(s.ox.count(1, gun.weapon), 1, 'they should stand up holding one of their weapon')

    local magazine = s.arena.MagazineFor(s.arena.GetWeaponByKey(gun.key), gun.ammo)
    t.equals(s.ox.metaOf(1, gun.weapon).ammo, magazine, 'and with a full magazine in it')
    t.equals(s.ox.count(1, gun.ammoTypeItem), gun.ammo - magazine,
        'and the loose rounds back at what they paid for')
    t.equals(s.ox.count(1, 'bandage'), 3, 'and the supplies they picked back at their count')
end)

t.test('and it is a top-up, not a second issue', function()
    -- A REFRESH THAT DOUBLED THE KIT WOULD BE WORSE THAN NONE: dying would be
    -- the way to get rich, and in a mode with respawns that is the whole
    -- round. Somebody who spent nothing must be handed nothing.
    local s = newServer()
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, {
            weapons = { { key = 'pistol', ammo = 120 } },
            supplies = { { key = 'bandage', count = 3 } },
        })
    end)

    local gun = s.row(1).loadout.weapons[1]
    local roundsBefore = s.ox.count(1, gun.ammoTypeItem)
    local bandagesBefore = s.ox.count(1, 'bandage')

    s.kill(1, 2)
    s.step(6)

    t.equals(s.ox.count(1, gun.weapon), 1, 'a second copy of the weapon was handed over')
    t.equals(s.ox.count(1, gun.ammoTypeItem), roundsBefore,
        'a fighter who fired nothing was given another batch of rounds')
    t.equals(s.ox.count(1, 'bandage'), bandagesBefore,
        'a fighter who used no bandages was given more')
end)

t.test('and a gun game respawn is left to the ladder', function()
    -- A LADDER DEATH COSTS A TIER, and settleTier owns what that player is
    -- holding. Refreshing on top of it would hand back the weapon the
    -- demotion had just taken away, which is the mode's only cost undone.
    local s = newServer(sevenTiers)
    s.play(3)

    s.trade(2, 1)
    local second = weaponAt(s, 2)
    t.equals(s.ox.count(1, second), 1, 'the climb did not reach tier 2')

    s.kill(1, 2)
    s.step(6)

    t.equals(s.row(1).tier, 1, 'the death did not cost a tier')
    t.equals(s.ox.count(1, second), 0,
        'the respawn handed back the weapon the demotion had just taken away')
end)

-- ======================================================================
-- WHAT A KILL PAYS IN AN ORDINARY MODE
-- ======================================================================

t.test('a verified kill in a free-for-all pays rounds for each weapon carried', function()
    -- THE HONEST VERSION OF SOMETHING PLAYERS WERE ALREADY DOING.
    -- ox_inventory drops a dead fighter's inventory on the floor as its own
    -- container, and walking over the body used to hand the killer the whole
    -- arena kit its owner had just been issued -- per kill, for as long as
    -- bodies kept falling. Looting is refused now, so the resupply a round
    -- with respawns actually needs is paid openly, in a fixed amount, to the
    -- fighter who earned it.
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = 100
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, { weapons = { { key = 'pistol', ammo = 120 } }, supplies = {} })
    end)

    local gun = s.row(1).loadout.weapons[1]
    local before = s.ox.count(1, gun.ammoTypeItem)

    s.kill(2, 1)
    t.equals(s.ox.count(1, gun.ammoTypeItem), before + 100,
        'the kill paid no rounds at all')

    s.revive(2)
    s.kill(2, 1)
    t.equals(s.ox.count(1, gun.ammoTypeItem), before + 200,
        'and a second kill paid nothing on top of the first')
end)

t.test('and it is per WEAPON, so two guns taking the same round are two payments', function()
    -- Collapsing them by calibre would quietly make a two-pistol loadout
    -- worth half what a pistol-and-rifle loadout is, which is not the rule
    -- config states.
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = 100
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, {
            weapons = { { key = 'pistol', ammo = 60 }, { key = 'combatpistol', ammo = 60 } },
            supplies = {},
        })
    end)

    local weapons = s.row(1).loadout.weapons
    t.equals(#weapons, 2, 'the fixture did not issue two weapons')
    t.equals(weapons[1].ammoTypeItem, weapons[2].ammoTypeItem,
        'the two weapons do not share a calibre, so this tests the wrong thing')

    local item = weapons[1].ammoTypeItem
    local before = s.ox.count(1, item)

    s.kill(2, 1)
    t.equals(s.ox.count(1, item), before + 200, 'two weapons should be two payments')
end)

t.test('and melee is paid nothing, because a blade names no ammunition', function()
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = 100
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, { weapons = { { key = 'knife' } }, supplies = {} })
    end)

    local gun = s.row(1).loadout.weapons[1]
    t.isTrue(gun ~= nil and not s.arena.IsKey(gun.ammoTypeItem),
        'the fixture gave the blade an ammo item, so this proves nothing')

    local held = 0
    for _, row in ipairs(s.ox.pockets[1] or {}) do
        if tostring(row.name):find('^ammo') then held = held + (row.count or 1) end
    end

    s.kill(2, 1)

    local after = 0
    for _, row in ipairs(s.ox.pockets[1] or {}) do
        if tostring(row.name):find('^ammo') then after = after + (row.count or 1) end
    end
    t.equals(after, held, 'a knife was paid ammunition')
end)

t.test('and a claim the server did not verify pays nothing', function()
    -- The same gate the scoreboard uses. resolveKiller refuses a teammate, a
    -- fighter who is out of the round, and anyone too far away to have done
    -- it -- and an unverified claim must not be a way to print ammunition.
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = 100
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, { weapons = { { key = 'pistol', ammo = 120 } }, supplies = {} })
    end)

    local gun = s.row(1).loadout.weapons[1]
    local before = s.ox.count(1, gun.ammoTypeItem)

    -- Nobody with server id 99 is in this match.
    s.kill(2, 99)
    t.equals(s.ox.count(1, gun.ammoTypeItem), before, 'an unverified claim paid the reward')

    -- And naming yourself is refused too.
    s.revive(2)
    s.kill(2, 2)
    t.equals(s.ox.count(1, gun.ammoTypeItem), before, 'a self-report paid the reward')
end)

t.test('and a gun game pays no rounds this way -- the ladder pays its own', function()
    -- A promotion already re-arms the climber with the tier's full
    -- ammunition and killReward pays the bandages. Paying this on top would
    -- be a second resupply for one kill.
    local s = newServer(function(config)
        sevenTiers(config)
        config.Modes.gungame.killAmmo = 100
    end)
    s.play(3)

    s.trade(2, 1)
    local entry = s.row(1).loadout.weapons[1]
    local magazine = s.arena.MagazineFor(s.arena.GetWeaponByKey(entry.key), entry.ammo)

    t.equals(s.ox.count(1, entry.ammoTypeItem), entry.ammo - magazine,
        'the ladder paid the kill-ammo reward on top of the tier it had just issued')
end)

t.test('and the rounds it pays are on the arena\'s books', function()
    -- A reward handed over and not recorded is a reward the player keeps: on
    -- a server with the door off it is the whole of an ammunition shop, one
    -- match at a time.
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = 100
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, { weapons = { { key = 'pistol', ammo = 120 } }, supplies = {} })
    end)

    local before = s.ammo.OnLoan(s.matchId())
    s.kill(2, 1)
    t.equals(s.ammo.OnLoan(s.matchId()), before + 100,
        'the reward was handed over without being written down')
end)

t.test('and a mode that names no killAmmo pays none', function()
    -- Deleting the line has to still work, which is what config.lua promises
    -- of it.
    local s = newServer(function(config)
        config.Modes.ffa.killAmmo = nil
    end)
    s.play(3, 'ffa', function()
        s.fire('setLoadout', 1, { weapons = { { key = 'pistol', ammo = 120 } }, supplies = {} })
    end)

    local gun = s.row(1).loadout.weapons[1]
    local before = s.ox.count(1, gun.ammoTypeItem)
    s.kill(2, 1)
    t.equals(s.ox.count(1, gun.ammoTypeItem), before, 'a mode with no killAmmo paid rounds anyway')
end)

-- ======================================================================
-- A TIER YOU LOST IS NOT A TIER THAT OPPONENT BOUGHT YOU
-- ======================================================================

t.test('THE REPORT: climb, die it all back, and the same opponent pays again', function()
    -- IN A PLAYER'S WORDS: "when you hit your max tier then die a lot then
    -- you kill that same person you wont go back up."
    --
    -- creditsTier counted kills PER VICTIM and the count only ever went up,
    -- while a player's position is `ladderKills - tiersLost` and goes both
    -- ways. So a climber who went up off one opponent and then died it all
    -- back was on tier 1 with that opponent recorded as having bought them
    -- everything -- and worth nothing for the rest of the round. They could
    -- stand next to the only other player in the arena, kill them over and
    -- over, and never move.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim
    t.isTrue(cap > 0, 'the cap is off, so this proves nothing')

    -- All the way up, off one opponent, to exactly where the cap stops them.
    for _ = 1, cap do s.trade(2, 1) end
    t.equals(s.row(1).tier, cap + 1, 'the climb did not happen')

    -- And all the way back down.
    for _ = 1, cap do s.trade(1, 2) end
    t.equals(s.row(1).tier, 1, 'the deaths did not cost the tiers')

    -- The same opponent, again. This is the kill the player reported.
    s.trade(2, 1)

    t.equals(s.row(1).tier, 2,
        'a tier that was climbed and then lost was still held against that opponent, so '
        .. 'killing them paid nothing and the player was stuck where they stood')
end)

t.test('and the cap still binds somebody who never dies', function()
    -- The control, and the thing that must not be given away. The refund can
    -- only ever pay back a tier that was actually LOST, so a climber who
    -- takes no deaths is capped exactly as before -- which is the run the cap
    -- was written to refuse.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim

    for _ = 1, cap + 4 do s.trade(2, 1) end

    t.equals(s.row(1).tier, cap + 1,
        'the refund handed a farm the tiers the cap exists to withhold')
    t.equals(s.row(1).ladderKills, cap, 'and credited kills it should not have')
end)

t.test('and a farm cannot be laundered through deaths on somebody else', function()
    -- The shape a cheat would try: climb off the accomplice to the cap, then
    -- die deliberately to a THIRD player to buy the credit back, then climb
    -- off the accomplice again.
    --
    -- It buys nothing, and the arithmetic is why: every death costs a tier
    -- before it refunds a credit, so the ladder position after any number of
    -- rounds of that is exactly what it would have been anyway. Dying to move
    -- up is not a strategy.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim

    for _ = 1, cap do s.trade(2, 1) end
    local peak = s.row(1).tier

    for _ = 1, 3 do
        s.trade(1, 3)      -- die to a third player
        s.trade(2, 1)      -- and climb off the accomplice again
    end

    t.equals(s.row(1).tier, peak,
        'dying on purpose bought ladder position it should not have')
end)

t.test('and one death gives back exactly one credit, not the whole opponent', function()
    -- The size of the refund matters as much as its existence. Handing back
    -- the victim's WHOLE count on a single death would let a climber buy the
    -- cap over again for the price of one death -- cheaper than the climb it
    -- pays for, which is a farm with an extra step.
    --
    -- Cap of two: climb twice off one opponent, die once, and exactly one
    -- more kill on them should pay.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim
    t.equals(cap, 2, 'this test is written around a cap of two')

    for _ = 1, cap do s.trade(2, 1) end
    t.equals(s.row(1).tier, cap + 1, 'the climb did not happen')

    s.trade(1, 2)                       -- one death: tier cap, one credit back
    t.equals(s.row(1).tier, cap, 'the death did not cost a tier')

    s.trade(2, 1)                       -- spends the refunded credit
    s.trade(2, 1)                       -- and this one must not pay

    t.equals(s.row(1).tier, cap + 1,
        'one death handed back more than one tier\'s worth of credit against that opponent')
end)

t.test('and the refund never runs a victim into negative credit', function()
    -- A player can lose tiers they did not buy from anybody in particular --
    -- the first death of the round, before any kill. The refund must not
    -- write a negative count that a later kill could spend.
    local s = newServer(sevenTiers)
    s.play(5)
    local cap = s.config.Modes.gungame.maxTiersPerVictim

    for _ = 1, 6 do s.trade(1, 2) end   -- die repeatedly having climbed nothing
    t.equals(s.row(1).tier, 1, 'nobody drops below tier 1')

    for _ = 1, cap + 3 do s.trade(2, 1) end
    t.equals(s.row(1).tier, cap + 1,
        'deaths taken before any climb were banked as credit against the cap')
end)

-- ======================================================================
-- THE FARM CAP IS OFF ON THIS SERVER, AND THE 1v1 IS WHY
-- ======================================================================

t.test('THE REQUEST: a 1v1 can be won on the ladder, on the shipped config', function()
    -- "take off the farm cap as what if i do a 1v1 etc".
    --
    -- The cap means "spread your kills across the field", and a field of one
    -- has nowhere to spread. The server does raise the cap for small lobbies,
    -- but that floor is deliberately divided by at least two -- so a straight
    -- 1v1 could not top the ladder however well anybody played, and the code
    -- said so in its own comment: "in a 1v1 the ladder cannot be topped".
    --
    -- SHIPPED CONFIG, not a mutated one. That is the whole assertion: this
    -- server's own settings, two players, and a ladder that can be finished.
    local s = newServer(function(config)
        pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' } })
    end)
    t.equals(s.config.Modes.gungame.maxTiersPerVictim, 0,
        'the shipped cap is not off, so this is not testing the shipped config')

    s.play(2)
    local height = #s.ladder()
    t.isTrue(height >= 2, 'the pinned ladder is too short to climb')

    for _ = 1, height do s.trade(2, 1) end
    s.settle(2)

    t.isNil(s.lobby.Get(s.matchId()),
        'a 1v1 climbed the whole ladder off its one opponent and the round never ended')
end)

t.test('and nothing else about the mode changed with it', function()
    -- The cap being off is a subtraction, not a rewrite: kills still climb,
    -- deaths still drop, and the ladder still ends the round. A change that
    -- quietly altered any of those would pass the test above.
    local s = newServer(function(config)
        pinLadder(config, { { 'knife' }, { 'pistol' }, { 'rifle' }, { 'smg' }, { 'carbine' } })
    end)
    s.play(3)

    s.trade(2, 1)
    t.equals(s.row(1).tier, 2, 'a kill no longer climbs')

    s.trade(1, 2)
    t.equals(s.row(1).tier, 1, 'a death no longer drops')

    -- And the killer who has been climbing is where their kills put them.
    t.equals(s.row(2).tier, 2, 'the other climber was not moved by their own kill')
end)

t.test('and an operator who wants it back gets it back', function()
    -- `0` is the off switch this server has chosen, not a removal. Writing a
    -- number puts the rule back exactly as it was, which is what makes the
    -- choice reversible rather than a decision taken for every server that
    -- ever runs this.
    local s = newServer(function(config)
        pinLadder(config, SEVEN_TIERS)
        config.Modes.gungame.maxTiersPerVictim = 2
    end)
    s.play(5)

    for _ = 1, 6 do s.trade(2, 1) end

    t.equals(s.row(1).ladderKills, 2, 'the cap did not come back when it was asked for')
    t.isTrue(s.told(1):find('No tier for that one', 1, true) ~= nil,
        'and the climber was not told why they stopped')
end)

os.exit(t.summary())
