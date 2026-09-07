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

    FIFTEEN TESTS, on deliberately different parts of it:

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
---        is drawn, so a test can name the ladder it wants
local function newServer(mutate, seed)
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
            if name == 'ox_inventory' then return 'started' end
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
    -- The door off, so the fake pockets below hold what the arena issued and
    -- nothing else -- with it on, `restore` clears the inventory wholesale
    -- and every weapon assertion in this file would read an empty bag.
    env.Config.Loadouts.stripOnEntry = false
    if mutate then mutate(env.Config) end

    -- ammo.lua FIRST, because match.lua calls into it.
    for _, file in ipairs({ 'util', 'ammo', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
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
    function server.play(count)
        server.fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'gungame', entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do server.fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src = 1, count do server.fire('setReady', src, { ready = true }) end
        -- SEEDED HERE, immediately before Start draws the ladder, so a test
        -- that names a seed gets the ladder that seed produces.
        if seed then math.randomseed(seed) end
        server.match.Start(matchId)
        threads.step()
        return matchId
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

    local tiers = s.config.Modes.gungame.gunGameTiers
    local drawn = s.ladder()

    t.equals(#drawn, #tiers,
        ('the ladder should have one weapon per tier, got %d for %d tier(s)')
            :format(#drawn, #tiers))

    -- EACH ONE OUT OF ITS OWN POOL, which is what makes the ladder
    -- "structured" rather than merely random: tier 3 is drawn from tier 3.
    for index, key in ipairs(drawn) do
        local inPool = false
        for _, candidate in ipairs(tiers[index]) do
            if candidate == key then inPool = true end
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
    for attempt = 1, 40 do
        local s = newServer(nil, attempt)
        s.play(2)
        local ladder = s.match_().ladder
        t.isTrue(s.arena.IsMeleeWeapon(ladder[1]) == true,
            ('draw %d opened on %s, which is not melee'):format(attempt, tostring(ladder[1].key)))
        t.isTrue(s.arena.IsMeleeWeapon(ladder[#ladder]) ~= true,
            ('draw %d finished on %s, which is melee'):format(attempt, tostring(ladder[#ladder].key)))
    end
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
    local s = newServer(function(config)
        -- Tier 4's whole pool, switched off in the catalogue.
        for _, weapon in ipairs(config.Loadouts.weapons) do
            for _, key in ipairs(config.Modes.gungame.gunGameTiers[4]) do
                if weapon.key == key then weapon.enabled = false end
            end
        end
    end)
    s.play(2)

    local full = #s.config.Modes.gungame.gunGameTiers
    t.equals(s.tierCount(), full - 1,
        'a tier with nothing playable in it should be dropped from the ladder')
    t.equals(#s.ladder(), full - 1, 'and the drawn ladder should be that much shorter')

    -- AND BELOW TWO IT IS NOT A LADDER AT ALL. A one-tier ladder would be
    -- topped by the first kill of the round, which is a worse outcome than
    -- the mode quietly running as ordinary rules -- and Arena.ValidateConfig
    -- is what makes sure an operator hears about it.
    local bare = newServer(function(config)
        config.Modes.gungame.gunGameTiers = { { 'knife' } }
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
    local s = newServer()
    s.play(6)
    local top = s.tierCount()

    -- Up to the top tier: top-1 credited kills, each on a different victim
    -- so the per-victim cap never bites.
    local victims = { 2, 3, 4, 5, 6, 2, 3 }
    for step = 1, top - 1 do s.trade(victims[step], 1) end

    t.equals(s.row(1).tier, top, ('%d kills should stand on the top tier'):format(top - 1))
    t.isTrue(s.row(1).ladderFinished ~= true,
        'reaching the top tier is not topping the ladder -- the kill made FROM it is')

    -- THE ROOM IS TOLD, once, and not the player themselves.
    t.isTrue(s.told(2):find('top tier', 1, true) ~= nil,
        'the room should be told when somebody reaches the top tier')

    -- NO FREE RE-ISSUE. A kill from the top tier moves nobody, and the early
    -- return in settleTier is the only thing stopping it handing the weapon
    -- over again with a full magazine every time. Counted through the real
    -- inventory: a second copy of the top weapon is the symptom.
    local before = s.ox.count(1, weaponAt(s, top))
    s.trade(4, 1)

    t.equals(s.row(1).ladderFinished, true, 'the kill made from the top tier tops the ladder')
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
    local s = newServer()
    s.play(3)
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
    local s = newServer(function(config)
        config.Modes.gungame.maxTiersPerVictim = 1
        config.Modes.gungame.killReward = {
            { key = 'bandage', count = 3 },
            { key = 'armour', count = 1, chance = 100 },
        }
    end)
    s.play(2)

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

os.exit(t.summary())
