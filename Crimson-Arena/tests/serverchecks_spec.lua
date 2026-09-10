--[[
    crimson_arena/tests/serverchecks_spec.lua

    THE TWO FACTS THE SERVER USED TO TAKE ON TRUST.

    Everything else about a round is decided on the server. These two came
    from the player's own game and nowhere else, and both were measured
    winning rounds with money on them:

      WHERE A FIGHTER IS STANDING.  The fence is drawn and enforced by the
                                    player's own client, so a client that
                                    does not run it cannot be pushed back.
                                    A fighter parked 140km away took the
                                    round and the pot while the others
                                    killed each other.

      WHETHER THEY DIED.            A death is reported by the dying
                                    player's own game, and that report is
                                    the only thing that spends a life -- so
                                    a client that never sends one cannot be
                                    eliminated at all.

    Config.Match.serverChecks answers both, once a second, and this file is
    about the thing that makes it safe to: IT ACTS ONLY ON WHAT IT HAS SEEN
    SEVERAL TIMES RUNNING, AND NEVER ON WHAT IT CANNOT SEE. A player whose
    world is still streaming reads for a moment exactly like a cheat, and
    throwing an honest player out of a paid round is worse than the thing
    this exists to stop.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('serverchecks_spec')

-- The Trailer Park's own spawn centre and fence, out of config.lua. A test
-- that invented its own numbers would pass against an arena this resource
-- does not ship.
local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }
local FENCE = 100.0

--- A point `metres` east of the middle of the arena.
local function eastOf(metres)
    return { x = CENTRE.x + metres, y = CENTRE.y, z = CENTRE.z }
end

--- A server whose fighters can be MOVED and KILLED from the outside.
--- @param mutate function?
local function newServer(mutate)
    local players = {}
    for src = 1, 4 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console, sent, recorded = {}, {}, {}, {}
    local clock = 0

    -- WHERE EACH BODY IS, AND WHAT ITS HEALTH READS. Both steerable, and
    -- both able to answer NOTHING -- `nil` here is a player the server
    -- cannot see, which is the case every guard in this file has to fail
    -- open on. Everybody starts a step from the middle of the arena.
    local at, health = {}, {}
    for src = 1, 4 do
        at[src] = eastOf(src * 2.0)
        health[src] = 200
    end

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        -- Nothing here drives a disconnect, so the handlers are taken and
        -- dropped: an unused table that looks like a fixture is a fixture
        -- somebody will wonder why nothing uses.
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            local point = at[tonumber(ped) or -1]
            -- THE ORIGIN IS HOW THE REAL NATIVE SAYS "I CANNOT SEE THEM",
            -- and server/match.lua's positionOf reads it as exactly that.
            -- Answering nil instead would be a shape the production code
            -- never meets.
            if not point then return { x = 0.0, y = 0.0, z = 0.0 } end
            return { x = point.x, y = point.y, z = point.z }
        end,
        GetEntityHealth = function(ped) return health[tonumber(ped) or -1] end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end,
            -- RECORDED, because whether a fence removal costs somebody a
            -- defeat is a rule, and a stub that swallowed it would let the
            -- rule be deleted without a test noticing.
            Record = function(entry) recorded[#recorded + 1] = entry return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 3
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config,
        match = env.ArenaMatch, lobby = env.ArenaLobby, console = console,
        recorded = recorded }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end
    server.fire = fire

    --- Move one fighter. nil puts them where the server cannot see them.
    function server.place(src, point) at[src] = point end

    --- Set what one fighter's body reads as. 0 is a corpse.
    function server.setHealth(src, value) health[src] = value end

    function server.play(count)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'ffa',
            entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src = 1, count do fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    --- `times` passes of the once-a-second sweep.
    function server.settle(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    function server.rowOf(src)
        local live = server.lobby.Get(matchId)
        return live and live.players[src]
    end

    --- Is this player still on the roster at all?
    function server.onRoster(src)
        return server.rowOf(src) ~= nil
    end

    return server
end

-- ======================================================================
-- THE FENCE
-- ======================================================================

t.test('a fighter parked outside the arena is removed from the round', function()
    -- THE EXPLOIT, EXACTLY AS MEASURED. A client that never runs the
    -- boundary thread cannot be bled and cannot be pushed back, so its
    -- owner sits somewhere nothing can reach and waits for the round to
    -- decide itself.
    local server = newServer(function(config)
        config.Match.serverChecks.outsideTicks = 3
    end)
    server.play(3)

    server.place(2, eastOf(FENCE + 500.0))
    t.isTrue(server.onRoster(2), 'the fixture removed them before the sweep ever ran')

    server.settle(1)
    t.isTrue(server.onRoster(2), 'one sighting was enough, which is the false-positive bug')
    server.settle(1)
    t.isTrue(server.onRoster(2), 'two sightings were enough')

    server.settle(1)
    t.isTrue(not server.onRoster(2), 'three sightings in a row still left them in the round')

    -- AND NOBODY ELSE. The two standing in the middle are untouched.
    t.isTrue(server.onRoster(1), 'a fighter inside the arena was removed as well')
    t.isTrue(server.onRoster(3), 'a fighter inside the arena was removed as well')
end)

t.test('and the count has to be CONSECUTIVE, not merely reached', function()
    -- A HITCH IS NOT A CHEAT. A player whose world stalls for a second, or
    -- who is between a death and a respawn, must not be able to accumulate
    -- strikes across a whole round and be thrown out for it.
    local server = newServer(function(config)
        config.Match.serverChecks.outsideTicks = 3
    end)
    server.play(3)

    for _ = 1, 5 do
        server.place(2, eastOf(FENCE + 500.0))
        server.settle(2)
        server.place(2, eastOf(5.0))
        server.settle(1)
    end

    t.isTrue(server.onRoster(2),
        'strikes accumulated across the round instead of resetting on a good sighting')
end)

t.test('a body the server cannot see is never a strike', function()
    -- FAILS OPEN, AND THIS IS THE TEST THAT SAYS SO. The native answers the
    -- origin for a ped that has not streamed in, and no arena is at 0,0,0
    -- -- so "unknown" must not read as "1,500 metres away".
    local server = newServer(function(config)
        config.Match.serverChecks.outsideTicks = 2
    end)
    server.play(3)

    server.place(2, nil)
    server.settle(6)

    t.isTrue(server.onRoster(2),
        'a player the server could not see was removed from a round they had paid to be in')
end)

t.test('and a fighter a step past the fence is left alone', function()
    -- THE FENCE ITSELF ALREADY BLEEDS THEM. This is not a second boundary,
    -- and a guard that removed somebody for being one metre out would take
    -- the round off every fighter who backed up too far.
    local server = newServer(function(config)
        config.Match.serverChecks.outsideTicks = 2
        config.Match.serverChecks.outsideMetres = 60.0
    end)
    server.play(3)

    server.place(2, eastOf(FENCE + 30.0))
    server.settle(6)

    t.isTrue(server.onRoster(2), 'a fighter 30m past the fence was thrown out of the round')
end)

t.test('switching the whole block off puts the trust back', function()
    local server = newServer(function(config)
        config.Match.serverChecks.enabled = false
    end)
    server.play(3)

    server.place(2, eastOf(FENCE + 5000.0))
    server.settle(12)

    t.isTrue(server.onRoster(2), 'the round policed itself with the setting switched off')
end)

-- ======================================================================
-- THE DEATH NOBODY REPORTED
-- ======================================================================

t.test('a fighter whose client never reports a death still loses the life', function()
    -- THE OTHER HALF OF THE SAME TRUST. The death report is the only thing
    -- that spends a life, so a client that simply never sends one is
    -- immortal to the round's bookkeeping -- measured winning a
    -- last-man-standing round having killed nobody.
    local server = newServer(function(config)
        config.Match.serverChecks.deadTicks = 2
    end)
    server.play(3)

    local before = server.rowOf(2).deaths or 0
    server.setHealth(2, 0)
    server.settle(1)
    t.equals(server.rowOf(2).deaths or 0, before,
        'one reading of a corpse was enough, which is the replication-lag bug')

    server.settle(1)
    t.equals(server.rowOf(2).deaths or 0, before + 1,
        'the server never booked the death its own eyes could see')
end)

t.test('and books it to NOBODY, because the server did not see a kill', function()
    -- A DEATH THE SERVER NOTICED IS NOT A KILL THE SERVER WITNESSED.
    -- Guessing at a killer here would be a bigger hole than the one this
    -- closes: it would hand the nearest player a free kill for every
    -- fighter who fell off the map.
    local server = newServer(function(config)
        config.Match.serverChecks.deadTicks = 1
    end)
    server.play(3)

    server.setHealth(2, 0)
    server.settle(2)

    t.equals(server.rowOf(1).kills or 0, 0, 'somebody was credited with a kill nobody made')
    t.equals(server.rowOf(3).kills or 0, 0, 'somebody was credited with a kill nobody made')
end)

t.test('a living fighter is never booked dead', function()
    local server = newServer(function(config)
        config.Match.serverChecks.deadTicks = 1
    end)
    server.play(3)

    server.settle(8)

    t.equals(server.rowOf(2).deaths or 0, 0, 'a fighter on full health was killed by the sweep')
    t.isTrue(server.rowOf(2).alive == true, 'a fighter on full health was knocked out by the sweep')
end)

t.test('and a body the server cannot see is not a corpse either', function()
    -- ZERO HEALTH IS ALSO WHAT THE NATIVE ANSWERS ABOUT AN ENTITY THAT DOES
    -- NOT EXIST, so an unreadable position has to disqualify the health
    -- beside it -- otherwise every player mid-stream reads as dead.
    local server = newServer(function(config)
        config.Match.serverChecks.deadTicks = 1
    end)
    server.play(3)

    server.place(2, nil)
    server.setHealth(2, 0)
    server.settle(6)

    t.equals(server.rowOf(2).deaths or 0, 0,
        'a player the server could not see was booked dead on a health reading it could not trust')
end)

t.test('deadTicks = 0 leaves the fence and drops this half', function()
    local server = newServer(function(config)
        config.Match.serverChecks.deadTicks = 0
        config.Match.serverChecks.outsideTicks = 2
    end)
    server.play(3)

    server.setHealth(2, 0)
    server.settle(6)
    t.equals(server.rowOf(2).deaths or 0, 0, 'the half that was switched off still ran')

    server.place(3, eastOf(FENCE + 500.0))
    server.settle(3)
    t.isTrue(not server.onRoster(3), 'switching one half off took the other with it')
end)

-- ======================================================================
-- THE DEATH REPORT ITSELF
-- ======================================================================

t.test('a death reported from outside the arena costs the CREDIT, not the death', function()
    -- THE FAKE-DEATH FARM. A death report costs the reporter nothing and
    -- hands whoever they name a kill, so a client sat out of the fight could
    -- feed an accomplice one every respawn delay.
    --
    -- THE DEATH ITSELF STILL STANDS, and that is not a concession -- it is
    -- the fix for a worse bug. Refusing the death was tried, and the
    -- skydome's lethal edge IS its boundary: step off the floor and you are
    -- hundreds of metres outside it on the way down. Every fall then produced
    -- a death the server would not book, a player who could not report again
    -- and was never respawned, and a fence removal eight seconds later. One
    -- life became the whole match, on a shipped arena, for playing normally.
    --
    -- A death out there is real. A KILL out there is the claim to refuse.
    local server = newServer()
    server.play(3)

    server.place(2, eastOf(FENCE + 500.0))
    server.match.OnDeath(2, 1)

    t.equals(server.rowOf(1).kills or 0, 0, 'a kill was credited for a death outside the arena')
    t.equals(server.rowOf(2).deaths or 0, 1,
        'the death itself was refused -- which is what strands a fighter who fell off the skydome')
    t.isTrue(server.rowOf(2).alive == false, 'the reporter was left standing after dying')
end)

t.test('and an honest death inside it still counts', function()
    -- THE HALF THAT MATTERS. A guard that refused real deaths would be far
    -- worse than the farm it stops: every round would stall on the first
    -- honest kill.
    local server = newServer()
    server.play(3)

    server.match.OnDeath(2, 1)

    t.equals(server.rowOf(2).deaths or 0, 1, 'an honest death inside the arena was refused')
    t.equals(server.rowOf(1).kills or 0, 1, 'an honest kill inside the arena was not credited')
end)

t.test('and a death the server cannot place is passed through', function()
    local server = newServer()
    server.play(3)

    server.place(2, nil)
    server.match.OnDeath(2, 1)

    t.equals(server.rowOf(2).deaths or 0, 1,
        'a death was refused because the server could not see where the body was')
end)

t.test('and being thrown out is a defeat on the record, unlike a crash', function()
    -- THE TWO EXITS LOOK IDENTICAL FROM INSIDE ArenaLobby.Leave and must not
    -- be treated identically. A crash spares the record because nobody chose
    -- it. Standing outside the arena for eight seconds running is the one
    -- exit that is entirely the player's doing -- and it is aimed squarely at
    -- somebody parked out of the fight waiting to be the last one left, so
    -- letting it clear their loss would pay for the exploit it exists to stop.
    local server = newServer(function(config)
        config.Match.serverChecks.outsideTicks = 2
    end)
    server.play(3)

    server.place(2, eastOf(FENCE + 500.0))
    server.settle(2)
    t.isTrue(not server.onRoster(2), 'the fence never removed them, so this proves nothing')

    local mine
    for _, entry in ipairs(server.recorded) do
        if entry.citizenid == 'CID002' then mine = entry end
    end
    t.isNotNil(mine, 'a fighter removed by the fence walked away with no defeat recorded')
    t.isTrue(mine.won == false, 'the fence recorded it as something other than a loss')
end)

os.exit(t.summary())
