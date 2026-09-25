--[[
    crimson_arena/tests/killwitness_spec.lua

    THE KILL THE DYING CLIENT DID NOT SEE.

    THE REPORT, from the owner of the server, in his words: "as its not
    giving points for a kill".

    THE MEASUREMENT, out of his own console, in the first gun game round
    anybody played on it:

      18:19:37  UNATTRIBUTED: 2 died in match mbd091 with nobody named --
                inside the arena, where something should have been able to
                kill them. The client says nothing it could name hit them.
      18:19:55  the same line again.

    Not a fall and not the boundary: the bodies were INSIDE the fence, and
    the other fighter was standing in front of them shooting a revolver he
    had been handed thirty seconds earlier. The ladder demoted the victim
    and did not promote the shooter, no kill ammo was paid, and the score
    did not move.

    WHY THE CLIENT MISSES A BLOW IT DIED TO. client/match.lua asks four
    readings in turn, and every one of them is a question about ENTITIES
    that client is currently holding: the damage event's attacker, the fatal
    blow it remembers, GET_PED_SOURCE_OF_DEATH, and the last thing that hurt
    it. All four answer nothing when no CEventNetworkEntityDamage reached
    that client for the killing shot and the engine had not finished filling
    the death in -- which is what a single lethal hit looks like. The
    client's own reason code for "all four were empty" is 1, and 1 is what
    both of those lines carried.

    Nothing the client can be taught fixes it. The client is the thing that
    did not see it.

    THE SERVER SAW IT. weaponDamageEvent arrives on the server for every
    shot that lands, carrying the shooter as the event's own sender -- an
    identity no client chooses -- and server/dispatch.lua was already
    resolving every victim in the packet to a server id, once per bullet,
    to enforce friendly fire. Then it returned without writing any of it
    down.

    So it is written down now, and ArenaMatch.OnDeath asks for it when the
    dying client named nobody. This file is about the two halves of that
    being true at once:

      IT CREDITS THE KILL THE CLIENT MISSED, in every mode, including the
      promotion on a ladder that the report is actually about.

      AND IT CANNOT BE USED TO INVENT ONE. What the memory names goes
      through resolveKiller exactly as a client's claim does -- the roster,
      the teams, elimination, the fence, the distance ceiling -- it is spent
      by the death it explains, it expires, and it is never consulted at all
      for a client that DID name somebody.

    THE WIRE from the damage packet to this memory is pinned in
    crossfire_spec, against the real server/dispatch.lua. This file drives
    ArenaMatch.RememberDamage directly, which is the seam between them.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('killwitness_spec')

-- The Trailer Park's own spawn centre, out of config.lua. A test that
-- invented its own coordinates would pass against an arena this resource
-- does not ship.
local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }

local function eastOf(metres)
    return { x = CENTRE.x + metres, y = CENTRE.y, z = CENTRE.z }
end

--- A server whose fighters can be shot at, killed, and moved.
---
--- THE CLOCK IS HELD STILL AND MOVED BY HAND, which is the one thing this
--- fixture cannot borrow from serverchecks_spec: that one advances sixty
--- seconds on every single read of GetGameTimer, and the memory this file
--- tests is five seconds wide. Every entry would have expired before it was
--- ever read, every test here would have passed for the wrong reason, and
--- the expiry test would have been the only honest one in the file.
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
    local netEvents, console, sent = {}, {}, {}
    local clock = 1000

    local at = {}
    for src = 1, 4 do at[src] = eastOf(src * 2.0) end

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
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            local point = at[tonumber(ped) or -1]
            if not point then return { x = 0.0, y = 0.0, z = 0.0 } end
            return { x = point.x, y = point.y, z = point.z }
        end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            -- THE LADDER'S OWN HAND-OVER. Without it the gun game test below
            -- throws in settleTier rather than asserting anything.
            SwapWeapon = function() return true end,
            GrantSupply = function() return true end,
            PayKillAmmo = function() return true end,
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
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, console = console,
        match = env.ArenaMatch, lobby = env.ArenaLobby, sent = sent }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end
    server.fire = fire

    function server.place(src, point) at[src] = point end

    --- Move the clock forward. Nothing else in this fixture moves it.
    function server.wait(ms) clock = clock + ms end

    function server.play(count, modeKey, teams)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey or 'ffa',
            entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src, team in pairs(teams or {}) do
            fire('setTeam', src, { teamKey = team })
        end
        for src = 1, count do fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    function server.matchId() return matchId end
    function server.settle(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    function server.rowOf(src)
        local live = server.lobby.Get(matchId)
        return live and live.players[src]
    end

    --- The dying client's report, with NOBODY NAMED and the reason code the
    --- owner's own log carried.
    function server.diesNamingNobody(src)
        fire('reportDeath', src, { why = 1 })
    end

    --- The dying client's report, naming its killer, which is the control.
    function server.diesNaming(src, killer)
        fire('reportDeath', src, { killerServerId = killer })
    end

    --- Does the console hold a line with this in it?
    function server.said(fragment)
        for _, line in ipairs(console) do
            if line:find(fragment, 1, true) then return true end
        end
        return false
    end

    return server
end

local function killsOf(server, src)
    local row = server.rowOf(src)
    return row and (row.kills or 0) or -1
end

-- ======================================================================
-- THE DEFECT, AND THE FIX, ON THE SAME DEATH
-- ======================================================================

t.test('CONTROL: the death the owner reported -- nobody named, nobody credited', function()
    -- This is the bug as it shipped, and it still reads exactly this way
    -- for a death the server never saw a blow for: a fall, a drowning, the
    -- boundary. Nothing below changes that, and this is the test that keeps
    -- it from changing.
    local server = newServer()
    server.play(2)

    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 0, 'somebody was credited for a death nothing was seen to cause')
    t.equals(server.rowOf(2).deaths, 1, 'the death itself was not booked')
    t.isTrue(server.said('UNATTRIBUTED'),
        'the operator was not told a death inside his arena went unattributed')
end)

t.test('THE FIX: the server watched the hit land, so the kill is credited', function()
    -- THE SAME REPORT AS THE TEST ABOVE -- the client names nobody and
    -- gives reason code 1 -- and the ONLY thing that differs is that the
    -- server saw the bullet arrive. That is the whole change.
    local server = newServer()
    server.play(2)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 1, 'THE DEFECT: the shooter the server watched hit them got nothing')
    t.equals(server.rowOf(2).deaths, 1, 'the death was booked twice, or not at all')
    t.isTrue(not server.said('UNATTRIBUTED'),
        'a death the server DID account for was still reported as unattributed')
    t.isTrue(server.said('kill credited from the server'),
        'nothing in the log says where this credit came from')
end)

t.test('and the gun game promotion the report was actually about', function()
    -- THE OWNER'S ROUND WAS A LADDER, and a ladder is where an uncredited
    -- kill costs the most: the victim drops a tier and the shooter does not
    -- climb one, so the scoreboard and both loadouts are wrong afterwards.
    local server = newServer(function(config)
        config.Modes.gungame.enabled = true
    end)
    server.play(2, 'gungame')

    local before = server.rowOf(1).tier
    t.isTrue(before ~= nil, 'the fixture did not draw a ladder, so this tests nothing')

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)

    t.isTrue(server.rowOf(1).tier > before,
        'THE DEFECT: the shooter stayed on the rung he killed from')
end)

-- ======================================================================
-- IT IS A SECOND OPINION, NEVER AN OVERRIDE
-- ======================================================================

t.test('a client that DID name somebody is not second-guessed', function()
    -- The memory must not be able to move a credit off the fighter the
    -- client named, in either direction: this is the path every ordinary
    -- death in every round takes, and it has to answer exactly what it
    -- always answered.
    local server = newServer()
    server.play(3)

    -- The server watched 3 hit them; the client says 1 killed them.
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNaming(2, 1)

    t.equals(killsOf(server, 1), 1, 'the client\'s own claim was overridden')
    t.equals(killsOf(server, 3), 0, 'the memory took a kill off the fighter the client named')
end)

t.test('a claim naming somebody who is NOT IN THIS ROUND still falls through to the memory', function()
    -- A CLAIM THAT NAMED SOMEBODY AND WAS REFUSED IS NOT A CLAIM THAT NAMED
    -- NOBODY, and this is the distinction the fallback is gated on. A client
    -- naming a fighter who has left is refused by rosterKiller -- and if
    -- that refusal fell through to the memory, a modded client could pick
    -- WHICH of the two answers it got by naming a dead id on purpose.
    local server = newServer()
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')

    -- 99 is nobody on this server. rosterKiller refuses it, and that
    -- refusal answers namedAFighter = false -- so the memory IS consulted,
    -- which is correct: a claim naming nobody real is a claim naming
    -- nobody. What must not happen is the claim choosing the outcome.
    server.diesNaming(2, 99)
    t.equals(killsOf(server, 3), 1,
        'a claim naming a stranger threw away the witness the server had')
end)

t.test('THE AUDIT: a claim naming a TEAM-MATE keeps its refusal, and the TEAMKILL line still prints', function()
    -- "REFUSAL INCLUDED". The first version of the fallback asked only
    -- whether the claim had been ACCEPTED, so a claim naming a team-mate --
    -- refused under friendly fire -- read as "nobody named" and fell
    -- through: an enemy who had landed any hit in the last five seconds was
    -- paid for the team-kill, and the TEAMKILL line was never printed.
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    t.isTrue(server.match.IsLive(server.matchId()), 'the round never went live, so nothing below tests anything')

    -- The enemy tagged them; their own team-mate finished them.
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNaming(2, 1)

    t.equals(killsOf(server, 3), 0, 'THE DEFECT: the enemy was paid for a team-kill through the memory')
    t.equals(killsOf(server, 1), 0, 'a team-kill was credited with friendly fire off')
    t.isTrue(server.said('TEAMKILL'), 'THE DEFECT: the TEAMKILL line was swallowed by the fallback')
end)

t.test('THE AUDIT: shots into a corpse do not pay for that fighter\'s next death', function()
    -- The rest of a burst lands on the body. Those hits used to be written
    -- down after the death had spent the entry, and the last of them could
    -- outlive the respawn -- so a fighter who then stepped off an edge was
    -- paid out to whoever had been shooting their corpse.
    local server = newServer()
    local id = server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)
    t.equals(killsOf(server, 1), 1, 'the real kill was not credited, so this tests nothing')

    t.isTrue(server.rowOf(2).alive ~= true, 'the fixture did not leave them dead')
    t.isTrue(not server.match.RememberDamage(2, 1), 'THE DEFECT: a hit on a corpse was written down')

    server.settle(1)
    t.isTrue(server.match.IsLive(id), 'the round ended between the two deaths')
    t.isTrue(server.rowOf(2).alive == true, 'the fighter never respawned, so they cannot die again')
    server.wait(250)
    server.diesNamingNobody(2)

    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 1, 'THE DEFECT: shots into a corpse paid for the next life\'s death')
end)

-- ======================================================================
-- AND IT CANNOT BE USED TO INVENT A KILL
-- ======================================================================

t.test('the memory is SPENT by the death it explains', function()
    -- Left behind, one landed hit would pay for every death inside its
    -- window -- so a fighter who traded a shot and then fell off the
    -- skydome would hand out two kills for one bullet.
    --
    -- THREE FIGHTERS, AND MUTATION TESTING IS WHY. Written with two, this
    -- test passed with the spend DELETED: a free-for-all whose only other
    -- fighter is dead is a round that has been won, so the sweep ended it
    -- between the two deaths, the second report was refused on OnDeath's
    -- third line and the assertion below held for a reason that had nothing
    -- to do with the memory. The third fighter keeps the round alive, and
    -- the two assertions in the middle are here so it can never go quiet
    -- that way again.
    local server = newServer()
    local id = server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)
    t.equals(killsOf(server, 1), 1, 'the first death was not credited at all')

    server.settle(1)
    t.isTrue(server.match.IsLive(id), 'the round ended between the two deaths')
    t.isTrue(server.rowOf(2).alive == true, 'the fighter never respawned, so they cannot die again')

    -- PAST THE DEATH-REPORT RATE LIMIT AND NOWHERE NEAR THE MEMORY'S
    -- WINDOW, which is the gap this test needs and is only available
    -- because the two numbers are twenty-five times apart: server/main.lua
    -- throttles reportDeath at 200ms, and the memory is good for 5000. This
    -- was the third reason the test passed with the spend deleted -- the
    -- second report was being dropped by the limiter, not refused by the
    -- rule. Every assertion in the middle of this test is a scar.
    server.wait(250)
    server.diesNamingNobody(2)
    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 1,
        'one landed hit was paid for twice, which is a kill nobody fired')
end)

t.test('and it expires, so an old hit does not explain a later death', function()
    local server = newServer()
    server.play(2)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(5001)
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 0,
        'a hit from before the window still paid, so the window does nothing')

    -- THE CONTROL, and it is the one that makes the test above mean
    -- anything: inside the window the same hit DOES pay.
    local inside = newServer()
    inside.play(2)
    t.isTrue(inside.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    inside.wait(4999)
    inside.diesNamingNobody(2)
    t.equals(killsOf(inside, 1), 1, 'a hit inside the window did not pay')
end)

t.test('a team-mate is refused, because the memory goes through the same rules', function()
    -- friendlyFire ships OFF. A hit that lands on a team-mate anyway -- a
    -- spread that caught them, which server/dispatch.lua allows through on
    -- purpose -- must not be able to buy a kill through this door that the
    -- front door refuses.
    --
    -- THREE FIGHTERS AND NOT TWO, and the reason is a vacuous test this
    -- replaced: a team deathmatch with both players on one side does not
    -- START, so the round was never live, OnDeath returned on its first
    -- line, and "nobody was credited" passed without the rule under test
    -- ever being reached. The third fighter gives the other side somebody
    -- to be, so the round is real and 1 shooting 2 is a genuine team hit.
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })

    t.isTrue(server.match.IsLive(server.matchId()),
        'the round never went live, so nothing below tests anything')
    t.equals(server.rowOf(1).team, 'ash', 'the fixture did not put them on one side')
    t.equals(server.rowOf(2).team, 'ash', 'the fixture did not put them on one side')

    server.match.RememberDamage(2, 1)
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 0, 'the memory paid a kill friendly fire forbids')
    t.isTrue(server.said('UNATTRIBUTED'), 'and the death was not reported as unattributed either')
end)

t.test('and an enemy on the other side IS credited, which is the control', function()
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })

    t.isTrue(server.match.IsLive(server.matchId()),
        'the round never went live, so nothing below tests anything')

    server.match.RememberDamage(2, 3)
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 3), 1, 'a lawful kill the server watched land was refused')
end)

t.test('a body well outside the fence is not explained by a hit inside it', function()
    -- THE SKYDOME'S LETHAL EDGE IS ITS BOUNDARY: step off the floor and you
    -- are hundreds of metres out on the way down. resolveKiller already
    -- refuses to CREDIT a kill out there while still booking the death, and
    -- the memory must not walk round that -- otherwise a fighter who winged
    -- somebody that then fell to their death is paid for the fall.
    local server = newServer()
    server.play(2)

    server.match.RememberDamage(2, 1)
    server.place(2, eastOf(3000.0))
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 0, 'a fall outside the arena was paid to whoever last hit them')
end)

t.test('and a shooter who is out of the round is refused', function()
    local server = newServer()
    server.play(2)

    local shooter = server.rowOf(1)
    shooter.lives = 0
    shooter.alive = false

    server.match.RememberDamage(2, 1)
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 0, 'a fighter with no lives left was paid a kill')
end)

-- ======================================================================
-- WHAT THE MEMORY ITSELF WILL AND WILL NOT WRITE DOWN
-- ======================================================================

t.test('RememberDamage refuses everything that is not two fighters in one live round', function()
    local server = newServer()
    server.play(2)

    t.isTrue(not server.match.RememberDamage(2, 2), 'a player was remembered as hitting themselves')
    t.isTrue(not server.match.RememberDamage(2, 0), 'server id 0 was remembered as a shooter')
    t.isTrue(not server.match.RememberDamage(2, -1), 'a negative server id was remembered')
    t.isTrue(not server.match.RememberDamage(2, nil), 'nil was remembered as a shooter')
    t.isTrue(not server.match.RememberDamage(nil, 1), 'nil was remembered as a victim')
    t.isTrue(not server.match.RememberDamage(2, 'one'), 'a string was remembered as a shooter')
    t.isTrue(not server.match.RememberDamage(2, 4),
        'somebody who is not in this round was remembered as hitting a fighter in it')
    t.isTrue(not server.match.RememberDamage(4, 1),
        'a fighter was remembered as hitting somebody outside the round')

    -- AND THE ONE IT MUST ACCEPT, so none of the above passes by accident.
    t.isTrue(server.match.RememberDamage(2, 1), 'two fighters in one live round were refused')
end)

t.test('nothing it remembers survives the round it was remembered in', function()
    -- THE LEAK, and it is the reason this hangs off the match table rather
    -- than a module-level store: the server recycles server ids, so a store
    -- that outlived a round would let whoever is handed id 2 next inherit
    -- a witness about somebody else entirely.
    local server = newServer()
    local id = server.play(2)

    server.match.RememberDamage(2, 1)
    local live = server.lobby.Get(id)
    t.isTrue(type(live.recentDamage) == 'table', 'the memory was not written where it is read from')

    server.match.End(id, 'match.ended_time_up')
    server.settle(2)

    t.isTrue(server.lobby.Get(id) == nil, 'the match outlived its own end')

    -- And the only thing holding the memory went with it, which is the
    -- whole of the guarantee: there is no other reference to reach.
    t.isTrue(not server.match.RememberDamage(2, 1),
        'a hit was remembered against a round that has finished')
end)

t.test('a hit in a waiting lobby is not remembered, because nobody can be killed in one', function()
    local server = newServer(function(config)
        config.Match.lobbyCountdownSeconds = 30
    end)
    server.fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
    })
    local id = server.lobby.All()[1].id
    server.fire('joinMatch', 2, { matchId = id, account = 'cash' })

    t.isTrue(not server.match.RememberDamage(2, 1),
        'the server remembered a hit in a round that has not started')
end)

-- ======================================================================
-- THE WHOLE CHAIN, WITH NOTHING STUBBED IN THE MIDDLE
--
-- Everything above drives ArenaMatch.RememberDamage by hand, and
-- crossfire_spec drives the damage packet against a stand-in for it. Both
-- halves can be green while the seam between them is wrong -- a renamed
-- function, an argument the wrong way round, a load order that means the
-- module is not there when the bullet arrives. Nothing either of them
-- asserts would notice.
--
-- So this builds a server with the REAL server/dispatch.lua and the REAL
-- server/match.lua in it, fires the engine's own weaponDamageEvent packet
-- at it, and then has the victim report their death naming nobody -- which
-- is the exact sequence the owner's log recorded twice.
-- ======================================================================

--- A server running the real damage handler as well as the real round.
local function newWiredServer()
    local players = {}
    for src = 1, 3 do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, handlers, console = {}, {}, {}
    local clock = 1000
    local buckets, cancelled = {}, false

    local at = {}
    for src = 1, 3 do at[src] = eastOf(src * 2.0) end

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return 1000 + (tonumber(src) or 0) end,
        GetPlayers = function()
            local out = {}
            for src in pairs(players) do out[#out + 1] = tostring(src) end
            table.sort(out)
            return out
        end,
        GetEntityCoords = function(ped)
            local point = at[(tonumber(ped) or 0) - 1000]
            if not point then return { x = 0.0, y = 0.0, z = 0.0 } end
            return { x = point.x, y = point.y, z = point.z }
        end,
        -- Each ped's network id, which is what the damage packet names.
        NetworkGetNetworkIdFromEntity = function(ped)
            local src = (tonumber(ped) or 0) - 1000
            return players[src] and (5000 + src) or 0
        end,
        CancelEvent = function() cancelled = true end,
        GetEntityHealth = function() return 200 end,
        GetVehiclePedIsIn = function() return 0 end,
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(name, fallback)
            if name == 'onesync' then return 'on' end
            return fallback
        end,
        Player = function() return { state = { set = function() end } } end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end,
            Flush = function() end, Record = function() return true end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            Refresh = function() return true end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            SwapWeapon = function() return true end,
            GrantSupply = function() return true end,
            PayKillAmmo = function() return true end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Match.lives = 3
    env.Config.Match.respawnDelaySeconds = 0
    env.Config.Betting.enabled = false

    -- EVERY SERVER FILE THE CHAIN RUNS THROUGH, in the manifest's own order.
    for _, file in ipairs({ 'util', 'dispatch', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, match = env.ArenaMatch, lobby = env.ArenaLobby, console = console }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.play(count)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = 'ffa', entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, count do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        for src = 1, count do fire('setReady', src, { ready = true }) end
        server.match.Start(matchId)
        threads.step()
        return matchId
    end

    --- The engine's own damage packet, exactly as FXServer delivers it.
    --- @return boolean cancelled
    function server.shoot(attacker, victim)
        cancelled = false
        local data = { hitGlobalIds = { 5000 + victim } }
        for _, fn in ipairs(handlers['weaponDamageEvent'] or {}) do
            fn(tostring(attacker), data)
        end
        return cancelled
    end

    function server.diesNamingNobody(src) fire('reportDeath', src, { why = 1 }) end
    function server.rowOf(src)
        local live = server.lobby.Get(matchId)
        return live and live.players[src]
    end

    return server
end

t.test('END TO END: the packet the engine sends pays the kill the client missed', function()
    local server = newWiredServer()
    server.play(2)

    t.isTrue(server.rowOf(1) ~= nil and server.rowOf(2) ~= nil,
        'the round did not start, so nothing below tests anything')

    t.isFalse(server.shoot(1, 2), 'a lawful shot between two fighters was cancelled')
    server.diesNamingNobody(2)

    t.equals(server.rowOf(1).kills, 1,
        'THE DEFECT, END TO END: the server watched the bullet land and credited nobody')
    t.equals(server.rowOf(2).deaths, 1, 'the death was not booked')
end)

t.test('and with no shot fired at all, nobody is credited -- the control', function()
    -- THE CONTROL THE TEST ABOVE IS WORTHLESS WITHOUT. If the credit came
    -- from anywhere other than the packet, this would pay too.
    local server = newWiredServer()
    server.play(2)

    server.diesNamingNobody(2)

    t.equals(server.rowOf(1).kills, 0, 'a kill was credited for a bullet nobody fired')
end)

os.exit(t.summary())
