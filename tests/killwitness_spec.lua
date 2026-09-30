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

    -- WHAT EACH BODY READS AS, for the dead sweep. Full health unless a test
    -- says otherwise, so every test that never touches it reads as before;
    -- `false` is a body the server cannot read at all.
    local health = {}

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
        GetEntityHealth = function(ped)
            local value = health[tonumber(ped) or -1]
            if value == false then return nil end
            return value or 200
        end,
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

    --- Set what one fighter's body reads as: 0 is a corpse, `false` a body
    --- the server cannot read.
    function server.setHealth(src, value) health[src] = value end

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

    --- The whole console line holding this, or nil.
    function server.line(fragment)
        for _, line in ipairs(console) do
            if line:find(fragment, 1, true) then return line end
        end
        return nil
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

t.test('and the TEAMKILL line cleans the names it prints, like the KILL line', function()
    -- A name is written by the player wearing it; printed raw, a line break
    -- in one starts a forged console line of its own.
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    server.rowOf(1).name = 'Mate\n[crimson_arena] match m1 ended ^1'
    server.diesNaming(2, 1)

    local found
    for _, line in ipairs(server.console) do
        if line:find('TEAMKILL:', 1, true) then found = line end
    end
    t.isNotNil(found, 'the TEAMKILL line did not print, so this tests nothing')
    t.isNil(found:find('\n', 1, true), 'a team-mate\'s name put a line break into the console')
    t.isNil(found:find('^', 1, true), 'a team-mate\'s name put a colour code into the console')
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
-- A CLAIM THAT NAMED SOMEBODY IS NOT A DEATH NOBODY WAS NAMED FOR
--
-- THE REPORTS: a last-life trade, a killer who walked out a moment before
-- the victim's report landed, and a team-mate's blade. In each the dying
-- client named its killer, the roster refused the claim on purpose -- and
-- the operator's only always-on line said UNATTRIBUTED, "nobody named",
-- "an older client", "this resource to blame", while the victim was told
-- nothing could be pinned on anybody and to go and tell the server owner.
--
-- EVERY TEST HERE BUT ONE RUNS WITH Config.Debug OFF. The debug lines
-- already said "kill refused"; the defect was that the line an operator
-- cannot switch off said the opposite. The one exception is about a debug
-- line, and leaves the shipped setting on so it can read it.
-- ======================================================================

--- How many times this fighter was told nothing could be pinned on anybody.
local function unattributedNotices(server, src)
    local count = 0
    for _, message in ipairs(server.sent) do
        if message.event == 'crimson_arena:client:notify' and message.target == src then
            local text = tostring((message.payload or {}).description or '')
            if text:find('Nothing could be pinned on anybody', 1, true) then count = count + 1 end
        end
    end
    return count
end

--- The first console line carrying this fragment, or nil.
local function lineSaying(server, fragment)
    for _, line in ipairs(server.console) do
        if line:find(fragment, 1, true) then return line end
    end
    return nil
end

t.test('THE LAST-LIFE TRADE: the second report named its killer, and is not logged as naming nobody', function()
    -- THREE FIGHTERS, so the round is still live when the second report
    -- lands -- which is what a real trade looks like: both reports arrive
    -- milliseconds apart, inside one sweep.
    local server = newServer(function(config)
        config.Match.lives = 1
        config.Debug = false
    end)
    local id = server.play(3)

    server.diesNaming(1, 2)
    t.equals(server.rowOf(1).lives, 0, 'the first death did not spend their last life, so this is no trade')
    server.wait(250)
    server.diesNaming(2, 1)

    t.isTrue(server.match.IsLive(id), 'the round ended between the two reports')
    t.equals(server.rowOf(2).deaths, 1, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 0, 'a fighter who was already out was credited a kill')
    t.equals(killsOf(server, 2), 1, 'the first kill of the trade was lost')

    local line = lineSaying(server, 'KILL NOT CREDITED')
    t.isNotNil(line, 'THE DEFECT: no always-on line says the claim was named and refused')
    t.contains(line, '2 died in match', 'the line does not say who died')
    t.contains(line, 'naming 1 as their killer', 'the line does not say whom they named')
    t.contains(line, 'already out of the round', 'the line does not say why the claim was refused')
    t.contains(line, 'By name: "Fighter 2" and "Fighter 1"', 'the line does not name the two fighters')
    t.isTrue(not server.said('UNATTRIBUTED'),
        'THE DEFECT: a death whose client named its killer was logged as nobody named')
    t.isTrue(not server.said('older client'), 'THE DEFECT: an up-to-date client was blamed for its age')
    t.equals(unattributedNotices(server, 2), 0,
        'THE DEFECT: the victim was told nothing could be pinned on anybody')
end)

t.test('A KILLER WHO WALKED OUT: the log says the victim named them, and says nothing it cannot know', function()
    -- GUN GAME, because it is the one mode where an honest client reaches
    -- this: nobody is eliminated there, so a leaver is the only named
    -- fighter the roster refuses. And the server watched the hit land too,
    -- which must not rescue a kill for somebody no longer in the round.
    local server = newServer(function(config)
        config.Modes.gungame.enabled = true
        config.Debug = false
    end)
    local id = server.play(3, 'gungame')

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.fire('leaveMatch', 1, {})
    t.isNil(server.rowOf(1), 'the leaver is still on the roster, so this tests nothing')
    t.isTrue(server.match.IsLive(id), 'the round ended when they left')

    -- THE OWNER'S RULING STILL HOLDS: a death with no killer costs a tier.
    -- Stood on rung 2 so the charge can be seen at all.
    server.rowOf(2).tier = 2
    server.wait(250)
    server.diesNaming(2, 1)

    t.equals(server.rowOf(2).deaths, 1, 'the death was not booked, so nothing was tested')
    t.equals(server.rowOf(2).tier, 1, 'the refused claim spared the victim a tier the ruling charges')
    t.equals(killsOf(server, 3), 0, 'somebody the victim did not name was credited')

    local line = lineSaying(server, 'KILL NOT CREDITED')
    t.isNotNil(line, 'THE DEFECT: no always-on line says the victim named a killer who had left')
    t.contains(line, '2 died in match', 'the line does not say who died')
    t.contains(line, 'naming 1 as their killer', 'the line does not say whom they named')
    -- NOT "has left": the row is gone, and a server id that never was in the
    -- round reads exactly the same from here.
    t.contains(line, 'or were never in it', 'the line asserts a departure the server cannot know')
    -- AND IT IS NOT LOOKED UP BY NAME: off the roster, the id may be anybody's.
    t.contains(line, 'By name: "Fighter 2" and nobody on the roster (id 1 is not looked up',
        'the line looked an id off the roster up by name')
    t.isTrue(not server.said('UNATTRIBUTED'), 'THE DEFECT: the named leaver was logged as nobody named')
    t.isTrue(not server.said('older client'), 'THE DEFECT: an up-to-date client was blamed for its age')
    t.equals(unattributedNotices(server, 2), 0,
        'THE DEFECT: the victim was told nothing could be pinned on anybody')
end)

t.test('AN HONEST TEAM-KILL: the TEAMKILL line speaks for it, alone', function()
    -- It printed TEAMKILL, and then UNATTRIBUTED "nobody named" about the
    -- same death, and told the victim to report a bug.
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
        config.Debug = false
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    t.isTrue(server.match.IsLive(server.matchId()), 'the round never went live, so nothing below tests anything')

    server.diesNaming(2, 1)

    t.isTrue(server.said('TEAMKILL'), 'the TEAMKILL line was lost')
    t.isTrue(not server.said('UNATTRIBUTED'),
        'THE DEFECT: TEAMKILL was contradicted by UNATTRIBUTED for the same death')
    t.isTrue(not server.said('KILL NOT CREDITED'), 'the refusal was said twice for one team-kill')
    t.equals(unattributedNotices(server, 2), 0,
        'THE DEFECT: the victim was told nothing could be pinned on anybody')
end)

t.test('and a team-mate who is already out still gets a line, because TEAMKILL stays quiet for them', function()
    -- TEAMKILL deliberately says nothing about an eliminated team-mate, so
    -- without a line of its own this death would be logged nowhere.
    local server = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
        config.Debug = false
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    t.isTrue(server.match.IsLive(server.matchId()), 'the round never went live, so nothing below tests anything')

    local out = server.rowOf(1)
    out.lives = 0
    out.alive = false
    server.diesNaming(2, 1)

    t.equals(server.rowOf(2).deaths, 1, 'the death was not booked, so nothing was tested')
    t.isTrue(not server.said('TEAMKILL'), 'TEAMKILL spoke for a team-mate who was out, so this tests nothing')
    local line = lineSaying(server, 'KILL NOT CREDITED')
    t.isNotNil(line, 'THE DEFECT: no always-on line says the named team-mate claim was refused')
    t.contains(line, 'naming 1 as their killer', 'the line does not say whom they named')
    -- THE SIDE IS ASKED FIRST, and that is the reason given: they are out
    -- as well, but a team-mate could not have been credited either way.
    t.contains(line, 'is on their own side, and friendly fire is off', 'the line gives the wrong reason')
    t.contains(line, 'By name: "Fighter 2" and "Fighter 1"', 'a named fighter still on the roster lost their name')
    t.isTrue(not server.said('UNATTRIBUTED'), 'THE DEFECT: the named team-mate was logged as nobody named')
    t.equals(unattributedNotices(server, 2), 0,
        'THE DEFECT: the victim was told nothing could be pinned on anybody')
end)

t.test('a server id that is nobody in the round is still logged, always on', function()
    -- The one a modded client reaches. It named nobody REAL, but it did put
    -- an id on the wire, and the always-on line must not go quiet for it.
    local server = newServer(function(config) config.Debug = false end)
    server.play(3)

    server.diesNaming(2, 99)

    t.equals(server.rowOf(2).deaths, 1, 'the death was not booked, so nothing was tested')
    local line = lineSaying(server, 'KILL NOT CREDITED')
    t.isNotNil(line, 'THE DEFECT: a claim naming a stranger had no always-on line of its own')
    t.contains(line, 'naming 99 as their killer', 'the line does not say whom they named')
    t.contains(line, 'or were never in it', 'the line asserts a departure the server cannot know')
    t.contains(line, 'id 99 is not looked up', 'the line does not say why the id has no name')
    t.isTrue(not server.said('UNATTRIBUTED'), 'the stranger claim was logged twice')
end)

t.test('and an id that belongs to somebody on the server, but not in the round, does not print their name', function()
    -- THE BYSTANDER. Player 3 is online, nowhere near the arena. A client
    -- naming 3 had the framework asked who 3 is, and an innocent player's
    -- name went into the always-on record as the accused.
    local server = newServer(function(config) config.Debug = false end)
    server.play(2)

    server.diesNaming(2, 3)

    local line = lineSaying(server, 'KILL NOT CREDITED')
    t.isNotNil(line, 'no always-on line for the refused claim, so nothing was tested')
    t.contains(line, 'naming 3 as their killer', 'the line does not say whom they named')
    t.isNil((line or ''):find('Fighter 3', 1, true),
        'THE DEFECT: a player who was never in the round was named as the accused')
end)

t.test('and a stranger claim the memory DID explain is reported as neither', function()
    -- The witness credited somebody, so this death is not unattributed and
    -- its claim is not the story: no refused-claim line, and the debug line
    -- that says where the credit came from must not blame an older client
    -- for a report that did carry an id.
    local server = newServer()
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNaming(2, 99)

    t.equals(killsOf(server, 3), 1, 'the witness was not asked, so this tests nothing')
    t.isTrue(not server.said('KILL NOT CREDITED'), 'a death the server DID account for was reported as refused')
    t.isTrue(not server.said('UNATTRIBUTED'), 'a death the server DID account for was reported as unattributed')
    t.isTrue(server.said('kill credited from the server'), 'the debug line naming the witness is gone')
    t.isTrue(not server.said('older client'),
        'THE DEFECT: the witness line blamed an older client for a report that named an id')

    -- THE KILL LINE SAYS THE CLIENT NAMED SOMEBODY, and whom: "the client
    -- named nobody" was the misstatement the UNATTRIBUTED line was cured of.
    local line = server.line('KILL: "Fighter 3"') or ''
    t.contains(line, "credited from the server's own record of the last hit (the client named 99, who is not on "
        .. "this round's roster", 'THE DEFECT: the KILL line says the client named nobody')
    t.isNil(line:find('the client named nobody', 1, true), 'the KILL line says the client named nobody')
end)

t.test('CONTROL: a report naming nobody -- no id, its own id, nought, negative -- is still UNATTRIBUTED', function()
    for label, payload in pairs({
        none = { why = 1 },
        self = { killerServerId = 2 },
        zero = { killerServerId = 0 },
        negative = { killerServerId = -1 },
    }) do
        local server = newServer(function(config) config.Debug = false end)
        server.play(3)

        server.fire('reportDeath', 2, payload)

        t.equals(server.rowOf(2).deaths, 1, label .. ': the death was not booked, so nothing was tested')
        t.isTrue(server.said('UNATTRIBUTED'), label .. ': a death that named nobody lost its always-on line')
        t.isTrue(not server.said('KILL NOT CREDITED'), label .. ': a report naming nobody was read as naming somebody')
        t.equals(unattributedNotices(server, 2), 1, label .. ': the victim was not told')
    end
end)

t.test('a refused claim does not spend the notice a real unattributed death is owed', function()
    -- The notice goes out once a round. Spent on a death whose client DID
    -- name its killer, it was gone when a genuine one came.
    local server = newServer(function(config) config.Debug = false end)
    local id = server.play(3)

    server.fire('leaveMatch', 1, {})
    server.wait(250)
    server.diesNaming(2, 1)
    t.equals(unattributedNotices(server, 2), 0,
        'THE DEFECT: the victim was told nothing could be pinned on anybody')

    server.settle(1)
    t.isTrue(server.match.IsLive(id), 'the round ended between the two deaths')
    t.isTrue(server.rowOf(2).alive == true, 'the fighter never respawned, so they cannot die again')
    server.wait(250)
    server.diesNamingNobody(2)

    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(unattributedNotices(server, 2), 1, 'the genuine unattributed death was never told')
end)

-- ======================================================================
-- THE DEATH NOBODY REPORTED
--
-- A victim whose client never reports is booked by the server's own dead
-- sweep, once a second, after Config.Match.serverChecks.deadTicks readings
-- of a corpse in a row -- three to four seconds at the shipped four. The
-- memory above is five seconds wide, and it used to be measured to that
-- BOOKING: a fighter who took the last hit two seconds before they dropped
-- had aged out of it by then, and the shooter lost a kill the very same
-- death paid when the client did report it. The window has always said it
-- runs to the body hitting the floor, so that is where it is measured now:
-- the sweep keeps a copy of what the memory held when the body FIRST read
-- dead, and a death it books reads that copy and nothing else.
-- ======================================================================

--- The dead sweep, one pass a second, until it books one more death for
--- `src` than they had.
--- @return boolean booked
local function sweepUntilBooked(server, src)
    local before = server.rowOf(src).deaths or 0
    for _ = 1, 12 do
        server.settle(1)
        if (server.rowOf(src).deaths or 0) > before then return true end
        server.wait(1000)
    end
    return false
end

--- A round whose fighters' own clients never say a word about their deaths.
local function silentServer(deadTicks, mutate)
    return newServer(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = deadTicks
        if mutate then mutate(config) end
    end)
end

t.test('THE SILENT VICTIM: a bleed-out the sweep books still pays the shooter it saw', function()
    -- The last hit lands, the body drops two and a half seconds later, and
    -- nothing is ever reported. The sweep books it on its fourth reading --
    -- five and a half seconds after the hit: past the window as it used to
    -- be measured, well inside it as it is defined.
    --
    -- Config.Debug OFF: the KILL line is the always-on record that this kill
    -- was paid on the server's own record, with no report behind it.
    local server = silentServer(4, function(config) config.Debug = false end)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(2500)
    server.setHealth(2, 0)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(server.rowOf(2).deaths, 1, 'the death was booked twice, or not at all')
    t.equals(killsOf(server, 1), 1,
        'THE DEFECT: the shooter lost a kill because the sweep took its time booking it')
    t.equals(killsOf(server, 3), 0, 'somebody who never touched them was credited')

    local line = server.line('KILL: "Fighter 1"')
    t.isNotNil(line, 'with Config.Debug off, nothing says who was credited')
    t.contains(line or '', '(dead sweep, no report)', 'the line does not say the sweep supplied the killer')
end)

t.test('and it pays at every count an operator may set, with a two-second bleed', function()
    -- deadTicks is the owner's own false-positive tolerance, and the fix
    -- must not depend on which number he picked. At six the booking is five
    -- seconds after the first corpse reading, so the old measure lost even
    -- an instant kill.
    for _, ticks in ipairs({ 4, 5, 6 }) do
        local server = silentServer(ticks)
        server.play(3)

        t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
        server.wait(2000)
        server.setHealth(2, 0)
        server.wait(1)

        t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
        t.equals(killsOf(server, 1), 1,
            ('THE DEFECT: at deadTicks %d the kill aged out while the sweep was counting'):format(ticks))
    end
end)

t.test('the five seconds run from the last hit to the FIRST dead reading, and no further', function()
    -- EXACTLY FIVE SECONDS still pays, the same edge damagerOf has for a
    -- death the client reported ...
    local edge = silentServer(4)
    edge.play(3)
    t.isTrue(edge.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    edge.wait(5000)
    edge.setHealth(2, 0)
    t.isTrue(sweepUntilBooked(edge, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(edge, 1), 1, 'THE DEFECT: a hit five seconds before the fall was measured to the booking')

    -- ... AND ONE MILLISECOND MORE DOES NOT, however the sweep is timed. A
    -- hit that long before the body went down is not why it went down.
    local outside = silentServer(4)
    outside.play(3)
    t.isTrue(outside.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    outside.wait(5001)
    outside.setHealth(2, 0)
    t.isTrue(sweepUntilBooked(outside, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(outside, 1), 0, 'a hit from before the window paid, so the window does nothing')
end)

t.test('a shot into the body while the sweep is still counting does not take the kill', function()
    -- The body reads alive to RememberDamage until the booking, so a third
    -- fighter emptying a magazine into the corpse in those seconds used to be
    -- the last hit on record -- and was paid for a kill somebody else made.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    t.equals(server.rowOf(2).deaths or 0, 0, 'one reading was enough to book it, so there was no window')

    server.wait(500)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(500)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 3), 0, 'THE DEFECT: a shot into the corpse took the kill')
    t.equals(killsOf(server, 1), 1, 'the fighter who made the kill was not paid for it')
end)

t.test('and nor does it when the sweep saw NO hit before the fall, or only a stale one', function()
    -- THE FALLBACK THE FIRST VERSION OF THIS FIX KEPT. It read the live
    -- memory whenever its copy named nobody -- and for a fall, a drowning or
    -- a grenade of their own, the only thing in the live memory by the
    -- booking is whoever shot the corpse. The empty copy is the answer.
    local fell = silentServer(4)
    fell.play(3)
    fell.setHealth(2, 0)
    fell.settle(1)
    fell.wait(500)
    t.isTrue(fell.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    fell.wait(500)
    t.isTrue(sweepUntilBooked(fell, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(fell, 3), 0, 'THE DEFECT: a shot into somebody who fell took the kill')

    -- A HIT SIX SECONDS BEFORE THE FALL is no witness, and it does not
    -- become the corpse-shooter's either.
    local stale = silentServer(4)
    stale.play(3)
    t.isTrue(stale.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    stale.wait(6000)
    stale.setHealth(2, 0)
    stale.settle(1)
    stale.wait(1500)
    t.isTrue(stale.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    stale.wait(500)
    t.isTrue(sweepUntilBooked(stale, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(stale, 3), 0, 'THE DEFECT: a shot into the corpse took a kill the window had dropped')
    t.equals(killsOf(stale, 1), 0, 'a hit from before the window paid')
end)

t.test('and another death read in the meantime does not wipe what the sweep saw', function()
    -- damagerOf sweeps the WHOLE memory against its own clock whenever any
    -- death reads it. Fighter 3 dies just over five seconds after 2 was hit,
    -- while 2 is still being counted, and takes 2's entry with it -- which
    -- is why the sweep keeps a copy of the row and not a note to look.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(2000)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(1000)
    server.settle(1)
    server.wait(1000)
    server.settle(1)
    server.wait(1100)

    server.diesNamingNobody(3)
    t.equals(server.rowOf(3).deaths, 1, 'the other death was not booked, so nothing was swept')
    t.equals(server.rowOf(2).deaths or 0, 0, 'the sweep booked it early, so there was no window')

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 1), 1, 'THE DEFECT: another fighter\'s death erased the witness')
end)

t.test('a hitch that read dead once leaves nothing for a later death to be paid from', function()
    -- One corpse reading, then the body reads alive again: a hitch, not a
    -- death. The copy that reading took must go with it, even when the
    -- memory it came from has since been swept away, or a death many
    -- seconds later is paid to whoever hit them before the hitch.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    server.setHealth(2, 200)
    server.wait(1000)
    server.settle(1)

    -- Somebody else's death, well past the window, sweeps 2's entry away.
    server.wait(6000)
    server.diesNamingNobody(3)
    t.equals(server.rowOf(3).deaths, 1, 'the other death was not booked, so nothing was swept')

    server.wait(1000)
    server.setHealth(2, 0)
    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 1), 0, 'a hit from before a hitch paid for a death eight seconds later')
end)

t.test('a body the server briefly cannot see keeps the moment it first read dead', function()
    -- AN UNREADABLE READING RESETS THE COUNT -- that is the fence's rule and
    -- serverchecks_spec pins it -- but it is no evidence the fighter got up.
    -- Taking a fresh copy when the count restarted moved the end of the
    -- window later: hit, fall three seconds on, one blind reading, and the
    -- restarted count's copy was taken five and a half seconds after the
    -- hit, so the shooter was dropped.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(3000)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(1000)
    server.setHealth(2, false)
    server.settle(1)
    server.wait(1500)
    server.setHealth(2, 0)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(server.rowOf(2).deaths, 1, 'the death was booked twice, or not at all')
    t.equals(killsOf(server, 1), 1, 'THE DEFECT: one blind reading moved the window past the shooter')
end)

t.test('THE LONG BLINDNESS: a copy from before a minute unread does not pay for a death after it', function()
    -- The copy is kept through a reading that cannot see the body. Kept
    -- through SIXTY of them, it was still there when the body next read dead
    -- and paid the fighter who hit them a minute ago -- while the fighter the
    -- server had just watched land a hit was robbed.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    server.setHealth(2, false)
    for _ = 1, 60 do
        server.wait(1000)
        server.settle(1)
    end
    t.equals(server.rowOf(2).deaths or 0, 0, 'a body nobody could see was booked, so this tests nothing')

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(500)
    server.setHealth(2, 0)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 1), 0, 'THE DEFECT: a hit a minute old took the kill')
    t.equals(killsOf(server, 3), 1, 'the fighter the server actually watched was robbed')
end)

t.test('and the copy lives through two unreadable checks, not a third', function()
    -- ONE is the hitch above. The limit is what the test before this one
    -- needs; the boundary is pinned here so neither side of it can move
    -- without a failure saying so.
    local function run(blind)
        local server = silentServer(4)
        server.play(3)

        t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
        server.wait(3000)
        server.setHealth(2, 0)
        server.settle(1)
        server.setHealth(2, false)
        for _ = 1, blind do
            server.wait(1000)
            server.settle(1)
        end
        server.wait(1000)
        server.setHealth(2, 0)

        t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
        return killsOf(server, 1)
    end

    t.equals(run(2), 1, 'two blind checks dropped a copy the shooter had earned')
    t.equals(run(3), 0, 'a copy survived three blind checks, so the limit does nothing')
end)

t.test('and blind checks that a dead one comes between do not add up', function()
    -- The limit counts unreadable checks IN A ROW. A body that flickers --
    -- blind, dead, blind, dead -- is still a body the server keeps seeing
    -- dead, and the copy of what hit it stays.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(2000)
    server.setHealth(2, 0)
    server.settle(1)
    for _ = 1, 3 do
        for _, reading in ipairs({ false, false, 0 }) do
            server.setHealth(2, reading)
            server.wait(1000)
            server.settle(1)
        end
    end
    t.equals(server.rowOf(2).deaths or 0, 0, 'the flickering body was booked early, so this tests nothing')

    server.setHealth(2, 0)
    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 1), 1, 'blind checks with dead ones between them were counted as one long blindness')
end)

t.test('THE LATE REPORT: once the sweep has read the body dead, a report is judged on its copy', function()
    -- The report is still on its way when the body already lies on the
    -- floor, and a third fighter empties a magazine into it. Read against
    -- the live memory, the report named nobody and paid the corpse shooter;
    -- the sweep's copy names the fighter who dropped them.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    t.equals(server.rowOf(2).deaths or 0, 0, 'one reading was enough to book it, so there was no window')

    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(300)
    server.diesNamingNobody(2)

    t.equals(server.rowOf(2).deaths, 1, 'the report was not booked, so nothing was tested')
    t.equals(killsOf(server, 3), 0, 'THE DEFECT: a shot into the corpse took a kill the late report left open')
    t.equals(killsOf(server, 1), 1, 'the fighter who dropped them was not paid')
end)

t.test('THE STALE CORPSE: the old body read just after a respawn leaves no copy behind', function()
    -- The client stands the body up only when the respawn event reaches it,
    -- and until then the server reads the corpse it left. A copy taken off
    -- that corpse was empty and outlived it: killed again before the next
    -- reading, the fighter was paid to nobody.
    local server = silentServer(4)
    server.play(3)

    server.diesNamingNobody(2)
    t.equals(server.rowOf(2).deaths, 1, 'the first death was not booked, so nothing was tested')
    server.setHealth(2, 0)
    server.settle(1)
    t.isTrue(server.rowOf(2).alive == true, 'the fighter never respawned, so there is no stale corpse')

    -- The sweep reads the corpse the respawn has not reached yet ...
    server.settle(1)
    -- ... and the new body is killed before the next reading.
    server.wait(200)
    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(800)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the second death, so nothing was tested')
    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 1, 'THE DEFECT: a copy of the old corpse paid the spawn kill to nobody')
end)

t.test('a report that lands mid-count still names its own killer', function()
    -- The copy is a second opinion for a death NOBODY reported. A client
    -- that reports while the sweep is counting, naming a fighter on the
    -- roster, gets the answer it always got -- and the sweep then leaves
    -- the body alone.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(1000)
    server.diesNaming(2, 3)
    server.setHealth(2, 200)
    server.settle(3)
    server.wait(4000)
    server.settle(3)

    t.equals(server.rowOf(2).deaths, 1, 'the death was booked twice, or not at all')
    t.equals(killsOf(server, 3), 1, 'the killer the client named was not credited')
    t.equals(killsOf(server, 1), 0, 'the sweep\'s copy overrode a named claim')
end)

t.test('and the copy is spent by the death it belongs to, even when the respawn beats the sweep', function()
    -- The client reports mid-count, and the fighter is stood back up before
    -- the sweep's next pass -- respawnDelaySeconds 0, or a slow pass -- while
    -- the server still reads the old corpse. The copy taken for the FIRST
    -- death must not be read for the second: 1 was paid nothing for either.
    local server = silentServer(4)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(1000)
    server.diesNaming(2, 3)
    t.equals(killsOf(server, 3), 1, 'the killer the client named was not credited')
    server.rowOf(2).alive = true

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the second death, so nothing was tested')
    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 0, 'a copy from the last death paid its shooter for this one')
end)

t.test('and the debug line does not blame an older client for a report nobody sent', function()
    -- The sweep's booking has no client reason at all. The line used to
    -- fall through to "an older client than this resource", which sent an
    -- operator hunting a version mismatch that was not there.
    local server = silentServer(1)
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')

    local line = server.line('kill credited from the server')
    t.isNotNil(line, 'nothing in the debug log says where this credit came from')
    t.isNil((line or ''):find('older client', 1, true),
        'THE DEFECT: a death the sweep booked was blamed on an older client that sent nothing')
    t.contains(line or '', 'dead sweep booked it', 'the line does not say the sweep booked it')
end)

t.test('and on a ladder the silent bleed-out still promotes the shooter', function()
    local server = silentServer(4, function(config)
        config.Modes.gungame.enabled = true
    end)
    server.play(3, 'gungame')

    local before = server.rowOf(1).tier
    t.isTrue(before ~= nil, 'the fixture did not draw a ladder, so this tests nothing')

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(2500)
    server.setHealth(2, 0)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.isTrue(server.rowOf(1).tier > before,
        'THE DEFECT: the shooter stayed on the rung he killed from')
end)

t.test('THE SLOW STAND-UP: a corpse still read a second after the respawn leaves no copy either', function()
    -- A fixed one-second grace was the first answer to the stale corpse, and
    -- a stand-up slower than one check beat it: the corpse read at +1 s gave
    -- an empty copy, the body stood up unread, and a spawn kill named
    -- nobody. No copy is taken now until the new body has been SEEN standing.
    for _, silent in ipairs({ false, true }) do
        local label = silent and 'silent' or 'reported'
        local server = silentServer(4)
        server.play(3)

        server.diesNamingNobody(2)
        server.setHealth(2, 0)
        server.settle(1)
        t.isTrue(server.rowOf(2).alive == true, label .. ': the fighter never respawned, so there is no stale corpse')

        server.wait(1000)
        server.settle(1)
        server.wait(200)
        server.setHealth(2, 200)
        server.wait(300)
        t.isTrue(server.match.RememberDamage(2, 1), label .. ': the server refused to remember a landed hit')
        server.wait(100)

        if silent then
            server.setHealth(2, 0)
            t.isTrue(sweepUntilBooked(server, 2), 'silent: the sweep never booked the second death, so nothing was tested')
        else
            server.diesNamingNobody(2)
        end
        t.equals(server.rowOf(2).deaths, 2, label .. ': the second death was not booked, so nothing was tested')
        t.equals(killsOf(server, 1), 1, label .. ': THE DEFECT: a copy of the stale corpse paid the spawn kill to nobody')
    end
end)

t.test('and once the new body HAS been seen standing, copies are taken again', function()
    -- The mark comes off on the first living reading: after that the late
    -- report is judged on the copy exactly as before any respawn.
    local server = silentServer(4)
    server.play(3)

    server.diesNamingNobody(2)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(500)
    server.setHealth(2, 200)
    server.settle(1)

    server.wait(1000)
    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(300)
    server.diesNamingNobody(2)

    t.equals(server.rowOf(2).deaths, 2, 'the second death was not booked, so nothing was tested')
    t.equals(killsOf(server, 3), 0, 'a shot into the corpse took the kill after the body had been seen standing')
    t.equals(killsOf(server, 1), 1, 'the fighter who dropped them was not paid')
end)

t.test('KNOWN LIMIT: a body never seen standing after its respawn is judged on the live memory', function()
    -- Killed again before the server ever read the new body alive, a death
    -- cannot be told from the corpse the respawn left, so no copy is taken
    -- and the death is read as it was before the copy existed -- a shot
    -- into the body before the booking can take it. Pinned so that trading
    -- this back is a decision, not an accident.
    local server = silentServer(4)
    server.play(3)

    server.diesNamingNobody(2)
    server.setHealth(2, 0)
    server.settle(1)

    server.wait(200)
    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(800)
    server.settle(1)
    server.wait(500)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(500)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the second death, so nothing was tested')
    t.equals(killsOf(server, 3), 1, 'the live memory no longer decides a death never seen standing -- update this pin')
    t.equals(killsOf(server, 1), 0, 'the live memory no longer decides a death never seen standing -- update this pin')
end)

t.test('KNOWN LIMIT: one false dead reading, then a real death reported inside the second, is judged on that reading', function()
    -- The server sees the same readings for this as for a late report after
    -- a real fall, so it cannot tell them apart; the late report is the case
    -- worth getting right. Pinned so that trading it back is a decision.
    local server = silentServer(4)
    server.play(3)

    server.setHealth(2, 0)
    server.settle(1)
    server.setHealth(2, 200)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(100)
    server.diesNamingNobody(2)

    t.equals(server.rowOf(2).deaths, 1, 'the death was not booked, so nothing was tested')
    t.equals(killsOf(server, 1), 0, 'a report after a single false reading is no longer judged on it -- update this pin')
end)

-- ======================================================================
-- THE CAP AND THE SPARING: ONLY A SHOT THE SERVER SAW
--
-- In a gun game a death is spared when the killer stood on a gun rung,
-- because the tier then moves to them. A kill past maxTiersPerVictim moves
-- no tier to anybody, so it spares the victim only when the server itself
-- watched THAT killer land a hit in the last five seconds -- not merely
-- when they were the LAST to, which an honest victim cannot control once
-- anybody else's round lands in the body. The victim's own report cannot
-- supply it.
--
-- HERE AND NOT IN gungame_spec, because that fixture's clock moves a
-- minute on every read and every entry below would have expired before it
-- was asked about.
-- ======================================================================

--- The LAST console line carrying this fragment, or nil -- the fixtures
--- below kill the same fighter several times before the death under test.
local function lastLineWith(server, fragment)
    for index = #server.console, 1, -1 do
        local line = server.console[index]
        if line:find(fragment, 1, true) then return line end
    end
    return nil
end

--- A gun game on a pinned seven-rung ladder with the per-victim cap ON,
--- where player 3 stands on a gun rung and has taken all they may off
--- player 2, and player 2 has two tiers to lose.
---
--- FOUR FIGHTERS AND A CAP OF 2, WHICH THE SMALL-LOBBY FLOOR RAISES TO 3:
--- seven rungs over three opponents. Deaths go straight to OnDeath so the
--- setup never meets the report rate limit; only the death under test goes
--- over the wire.
local function cappedLadder(mutate)
    local server = newServer(function(config)
        config.Modes.gungame.enabled = true
        config.Modes.gungame.gunGameClasses = nil
        config.Modes.gungame.gunGameTiers = {
            { 'knife' }, { 'pistol' }, { 'combatpistol' }, { 'heavypistol' },
            { 'pistol50' }, { 'revolver' }, { 'appistol' },
        }
        config.Modes.gungame.maxTiersPerVictim = 2
        if mutate then mutate(config) end
    end)
    server.play(4, 'gungame')

    local function kill(victim, killer)
        server.match.OnDeath(victim, killer)
        server.rowOf(victim).alive = true
    end
    for _ = 1, 3 do kill(2, 3) end
    kill(4, 2)
    kill(4, 2)

    t.equals(server.rowOf(3).ladderKills, 3, 'player 3 did not climb three tiers off player 2')
    t.equals(server.rowOf(2).tier, 3, 'player 2 has no tiers to lose')
    local ladder = server.lobby.Get(server.matchId()).ladder
    t.isTrue(server.env.Arena.IsMeleeWeapon(ladder[server.rowOf(3).tier]) ~= true,
        'player 3 is not on a gun rung, so nothing here would be spared anyway')
    return server
end

t.test('THE CAP: a capped killer the server SAW land the shot still spares the victim', function()
    -- The honest victim. They were shot, by a gun, and the server watched
    -- it land -- that is the rule's own sentence, and the cap is no reason
    -- to charge them.
    local server = cappedLadder()

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNaming(2, 3)

    t.equals(killsOf(server, 3), 4, 'the kill was not credited, so this proves nothing')
    t.equals(server.rowOf(3).ladderKills, 3, 'the capped kill moved the killer')
    t.equals(server.rowOf(2).tier, 3, 'a shot the server watched land cost the victim a tier')
    t.equals(server.rowOf(2).tiersLost, nil, 'and was charged')

    local line = lastLineWith(server, 'killed "Fighter 2"') or ''
    t.contains(line, 'the killer stays on tier 4/7 -- this victim has already paid out their tiers',
        'the KILL line does not say the capped kill moved nobody')
    t.contains(line, 'the victim keeps tier 3/7, spared by a gun kill', 'the KILL line does not say the victim was spared')
end)

t.test('and so does one whose shot was followed by somebody else\'s round into the body', function()
    -- THE REGRESSION THE FIRST VERSION OF THIS FIX HAD. It asked who hit the
    -- victim LAST, and the memory keeps one attacker, overwritten on every
    -- hit -- so the rest of a crowded fight landing in the body a moment
    -- after the killing shot charged an honest victim a tier.
    local server = cappedLadder()

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(50)
    t.isTrue(server.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    server.wait(50)
    server.diesNaming(2, 3)

    t.equals(killsOf(server, 3), 4, 'the kill was not credited, so this proves nothing')
    t.equals(server.rowOf(2).tier, 3, 'a later round into the body cost the victim of a capped gun a tier')
end)

t.test('and so does a capped killer the server saw when the client named nobody', function()
    local server = cappedLadder()

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 3), 4, 'the memory did not credit the shooter')
    t.equals(server.rowOf(2).tier, 3, 'a shot the server watched land cost the victim a tier')
end)

t.test('but a capped killer the server saw NOTHING from spares nothing', function()
    -- THE EXPLOIT. A fall, a suicide or a knife from somebody else,
    -- reported as the capped opponent's kill: it moved no tier to anybody,
    -- so it is charged -- one tier, and one of the victim's own credits
    -- handed back as any lost tier does.
    local server = cappedLadder()

    server.diesNaming(2, 3)

    t.equals(killsOf(server, 3), 4, 'the claim was not credited, so this proves nothing')
    t.equals(server.rowOf(3).ladderKills, 3, 'the capped kill moved the killer')
    t.equals(server.rowOf(3).tier, 4, 'the capped killer changed rung')
    t.equals(server.rowOf(2).tier, 2, 'THE DEFECT: naming the capped opponent kept the tier')
    t.equals(server.rowOf(2).tiersLost, 1, 'and nothing was charged')
    t.equals((server.rowOf(2).ladderVictims or {})[4], 1, 'the lost tier did not hand back a credit')

    local line = lastLineWith(server, 'killed "Fighter 2"') or ''
    t.contains(line, 'the killer stays on tier 4/7 -- this victim has already paid out their tiers',
        'the KILL line does not say the capped kill moved nobody')
    t.contains(line, 'the victim goes from tier 3 to 2/7', 'the KILL line does not say the victim was charged')
end)

t.test('and neither does a hit that has expired, or one by somebody else', function()
    local stale = cappedLadder()
    t.isTrue(stale.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    stale.wait(5001)
    stale.diesNaming(2, 3)
    t.equals(stale.rowOf(2).tier, 2, 'a hit from outside the window spared a capped kill')

    local other = cappedLadder()
    t.isTrue(other.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    other.diesNaming(2, 3)
    t.equals(other.rowOf(2).tier, 2, 'a hit by somebody else spared a capped kill by 3')
end)

t.test('and a silent bleed-out the sweep books on a capped killer\'s shot is spared', function()
    -- The dead sweep's copy names the capped shooter, so the server did
    -- see that shot land: the same answer an honest report gets.
    local server = cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(2500)
    server.setHealth(2, 0)

    t.isTrue(sweepUntilBooked(server, 2), 'the sweep never booked the death, so nothing was tested')
    t.equals(killsOf(server, 3), 4, 'THE DEFECT: the sweep did not credit the shooter it saw')
    t.equals(server.rowOf(2).tier, 3, 'a shot the server watched land cost the victim a tier')
end)

t.test('and exactly five seconds still spares, the same edge the credit has', function()
    local server = cappedLadder()
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(5000)
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 3, 'a hit exactly five seconds old was treated as expired')
end)

t.test('and a capped killer who hit twice is judged on the LATER hit', function()
    -- Each attacker keeps the time of their last hit, not their first: a
    -- fighter who landed one six seconds ago and another a second ago DID
    -- land one in the window.
    local server = cappedLadder()
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(5000)
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(1000)
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 3, 'the killer\'s second hit was forgotten and the victim charged')
end)

t.test('and on their OWN hit, not the last one anybody landed', function()
    -- 3's shot is six seconds old; 4 hit a second ago. The window is 3's to
    -- be inside, and they are not.
    local server = cappedLadder()
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(5000)
    t.isTrue(server.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    server.wait(1000)
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 2, 'somebody else\'s recent hit spared a capped kill by 3')
end)

t.test('and a report that arrives after the body first read dead is measured to that reading', function()
    -- The same death, reported late, used to be charged -- the clock ran on
    -- to the report -- while left to the sweep it was spared. Both are now
    -- measured to the moment the body was first seen down.
    local server = cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)
    local before = server.rowOf(2).deaths or 0

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(3000)
    server.setHealth(2, 0)
    server.settle(1)
    t.equals(server.rowOf(2).deaths or 0, before, 'one reading booked it, so there was no window')
    server.wait(2500)
    server.diesNaming(2, 3)

    t.equals(server.rowOf(2).deaths, before + 1, 'the report was not booked, so nothing was tested')
    t.equals(server.rowOf(2).tier, 3,
        'THE DEFECT: a capped kill the server saw land was charged because the report came late')
end)

t.test('and the copy holds a late report to the same five seconds', function()
    -- Measured to the first dead reading, a hit six seconds before it is as
    -- stale as a hit six seconds before a report -- the copy does not keep
    -- an old shot alive for longer.
    local server = cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)
    local before = server.rowOf(2).deaths or 0

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(6000)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    server.diesNaming(2, 3)

    t.equals(server.rowOf(2).deaths, before + 1, 'the report was not booked, so nothing was tested')
    t.equals(server.rowOf(2).tier, 2, 'a hit six seconds before the fall spared a capped kill')
end)

t.test('and a capped opponent firing into a body that fell on its own spares nothing', function()
    -- THE ONE THAT NEEDS NO ACCOMPLICE. The victim falls with nothing having
    -- hit them, waits for a capped opponent on a gun rung to fire into the
    -- body, then names them. Read against the live memory, that shot was
    -- "seen" and the fall was spared.
    local server = cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)
    local before = server.rowOf(2).deaths or 0

    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(300)
    server.diesNaming(2, 3)

    t.equals(server.rowOf(2).deaths, before + 1, 'the report was not booked, so nothing was tested')
    t.equals(server.rowOf(2).tier, 2, 'THE DEFECT: a shot into a body that fell turned the fall into a spared kill')
end)

t.test('and a corpse still read a second after a respawn does not charge a capped victim the server saw shot', function()
    local server = cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)

    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 3, 'the first capped kill the server saw was charged, so nothing below means anything')
    server.setHealth(2, 0)
    server.settle(1)
    t.isTrue(server.rowOf(2).alive == true, 'the fighter never respawned, so there is no stale corpse')

    server.wait(1000)
    server.settle(1)
    server.wait(200)
    server.setHealth(2, 200)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(100)
    server.diesNaming(2, 3)

    t.equals(server.rowOf(2).tier, 3, 'THE DEFECT: an empty copy of the stale corpse charged a victim the server saw shot')
end)

--- The capped ladder with the dead sweep on, for the tests that judge a
--- late report on the sweep's copy rather than on the live memory.
local function cappedSweep()
    return cappedLadder(function(config)
        config.Match.serverChecks.enabled = true
        config.Match.serverChecks.deadTicks = 4
    end)
end

--- The body reads dead, the sweep takes its copy, and the report arrives
--- 300 ms later naming the capped opponent 3.
local function fallsThenNames3(server)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    server.diesNaming(2, 3)
end

t.test('ON THE COPY: a late report naming a capped killer is judged on THAT killer\'s hit, not on anybody\'s', function()
    -- Only 4 hit them. With the copy answering "somebody hit them", any
    -- capped opponent the victim chose to name would spare the fall -- the
    -- free sparing the cap rule closed, reopened for late reports.
    local server = cappedSweep()
    t.isTrue(server.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    server.wait(500)
    fallsThenNames3(server)
    t.equals(server.rowOf(2).tier, 2, 'somebody else\'s hit spared a capped kill by 3 on the copy')
end)

t.test('ON THE COPY: and every attacker who hit before the fall is on it, not just the last', function()
    local server = cappedSweep()
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(1000)
    t.isTrue(server.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    server.wait(500)
    fallsThenNames3(server)
    t.equals(server.rowOf(2).tier, 3, 'the copy kept only the last hitter, and charged a victim 3 had shot')
end)

t.test('ON THE COPY: and a capped opponent\'s shot into the body after the reading does not count', function()
    local server = cappedSweep()
    t.isTrue(server.match.RememberDamage(2, 4), 'the server refused to remember a landed hit')
    server.wait(500)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(300)
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 2, 'a shot into the corpse reached the copy and spared the fall')
end)

t.test('ON THE COPY: and a killer who also fires into the body keeps the hit that dropped them', function()
    -- The copy is its own table. Shared with the live memory, 3's later shot
    -- into the corpse overwrote the time of the shot that dropped them, and
    -- the victim of a capped killer the server HAD seen was charged.
    local server = cappedSweep()
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.wait(1000)
    server.setHealth(2, 0)
    server.settle(1)
    server.wait(300)
    t.isTrue(server.match.RememberDamage(2, 3), 'the corpse hit was refused, so this tests nothing')
    server.wait(300)
    server.diesNaming(2, 3)
    t.equals(server.rowOf(2).tier, 3, 'a shot into the corpse overwrote the hit that dropped them')
end)

t.test('ON THE COPY: exactly five seconds before the fall still spares, and one millisecond more does not', function()
    local edge = cappedSweep()
    t.isTrue(edge.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    edge.wait(5000)
    fallsThenNames3(edge)
    t.equals(edge.rowOf(2).tier, 3, 'a hit exactly five seconds before the fall was treated as expired on the copy')

    local outside = cappedSweep()
    t.isTrue(outside.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    outside.wait(5001)
    fallsThenNames3(outside)
    t.equals(outside.rowOf(2).tier, 2, 'a hit more than five seconds before the fall spared a capped kill on the copy')
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

t.test('a later hit by somebody else becomes the one credited', function()
    -- The row is updated in place now, beside the per-attacker times, so the
    -- line that moves "who hit last" onto the newest hit is the only thing
    -- keeping the credit on the right fighter.
    local server = newServer()
    server.play(3)

    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.wait(1000)
    t.isTrue(server.match.RememberDamage(2, 3), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 3), 1, 'the last fighter to land a hit was not credited')
    t.equals(killsOf(server, 1), 0, 'an earlier hit took the credit from a later one')
end)

t.test('and every hit starts the five seconds again', function()
    -- One fighter hitting once a second for seven seconds, and the body
    -- going down a second after the last: that is a kill. A row that kept
    -- the time of its FIRST hit had expired it.
    local server = newServer()
    server.play(3)

    for _ = 1, 7 do
        t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
        server.wait(1000)
    end
    server.diesNamingNobody(2)

    t.equals(killsOf(server, 1), 1, 'a fighter still hitting them was dropped by a window measured from the first hit')
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
--- @param mutate function?
local function newWiredServer(mutate)
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
    if mutate then mutate(env.Config) end

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

    function server.play(count, modeKey)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey or 'ffa', entryFee = 0, account = 'cash',
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
    function server.diesNaming(src, killer) fire('reportDeath', src, { killerServerId = killer }) end
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

t.test('END TO END: the packet is what lets a capped gun kill spare the victim', function()
    -- The gun game's per-victim cap, through the real damage handler. Three
    -- fighters and a cap of 2, which the small-lobby floor raises to 4:
    -- player 3 takes four tiers off player 2 and stands on a gun, and
    -- player 2 climbs two tiers off player 1 so there is a tier to lose.
    local function capped()
        local server = newWiredServer(function(config)
            config.Modes.gungame.enabled = true
            config.Modes.gungame.gunGameClasses = nil
            config.Modes.gungame.gunGameTiers = {
                { 'knife' }, { 'pistol' }, { 'combatpistol' }, { 'heavypistol' },
                { 'pistol50' }, { 'revolver' }, { 'appistol' },
            }
            config.Modes.gungame.maxTiersPerVictim = 2
        end)
        server.play(3, 'gungame')
        local function kill(victim, killer)
            server.match.OnDeath(victim, killer)
            server.rowOf(victim).alive = true
        end
        for _ = 1, 4 do kill(2, 3) end
        kill(1, 2)
        kill(1, 2)
        t.equals(server.rowOf(3).ladderKills, 4, 'player 3 did not climb four tiers off player 2')
        t.equals(server.rowOf(2).tier, 3, 'player 2 has no tiers to lose')
        return server
    end

    local shot = capped()
    t.isFalse(shot.shoot(3, 2), 'a lawful shot between two fighters was cancelled')
    shot.diesNaming(2, 3)
    t.equals(shot.rowOf(3).kills, 5, 'the kill was not credited, so this proves nothing')
    t.equals(shot.rowOf(2).tier, 3, 'a capped gun kill the server saw land cost the victim a tier')

    local claimed = capped()
    claimed.diesNaming(2, 3)
    t.equals(claimed.rowOf(3).kills, 5, 'the claim was not credited, so this proves nothing')
    t.equals(claimed.rowOf(2).tier, 2, 'THE DEFECT, END TO END: a claim with no shot behind it kept the tier')
end)

-- ======================================================================
-- THE KILL LOG: WHO KILLED WHOM, WRITTEN DOWN
--
-- THE OWNER'S ASK: "so when someone kills etc that it actually logs who
-- killed them". Before this nothing did. A credited kill added one to a
-- count, and every record downstream -- the board, the results, the
-- leaderboard, the webhook -- kept counts and nothing else.
-- ======================================================================

--- Every KILL line on the console. Anchored on the prefix, because
--- "TEAMKILL:" contains "KILL:" and is a different line.
local function killLines(server)
    local out = {}
    for _, line in ipairs(server.console) do
        if line:sub(1, #'[crimson_arena] KILL: ') == '[crimson_arena] KILL: ' then out[#out + 1] = line end
    end
    return out
end

t.test('THE KILL LOG: a kill the victim names is written down with both names, Debug off', function()
    -- ALWAYS ON: it is a record, and turning Debug off to quieten a busy
    -- console must not take the answer to "who killed me" with it.
    local server = newServer(function(config) config.Debug = false end)
    server.play(2)
    server.diesNaming(2, 1)

    local lines = killLines(server)
    t.equals(#lines, 1, 'the kill was not written down exactly once')
    t.contains(lines[1], '"Fighter 1" (1 CID001) killed "Fighter 2" (2 CID002)',
        'the line does not name both people')
    t.contains(lines[1], "named by the victim's own client", 'the line does not say how the kill was credited')
    t.contains(lines[1], 'the victim has 2 lives left', 'the line does not say what the death cost')

    server.settle(3)
    t.isTrue(server.rowOf(2).alive == true, 'the victim did not come back after the line was written')
end)

t.test('and one credited from the server\'s own record says so', function()
    local server = newServer()
    server.play(2)
    t.isTrue(server.match.RememberDamage(2, 1), 'the server refused to remember a landed hit')
    server.diesNamingNobody(2)

    local lines = killLines(server)
    t.equals(#lines, 1, 'the witnessed kill was not written down')
    t.contains(lines[1], "credited from the server's own record of the last hit (the client named nobody)",
        'the line does not say the server supplied the killer')
end)

t.test('CONTROL: a claim that is refused writes no KILL line', function()
    -- The line reads only the killer that was CREDITED. A claim naming
    -- yourself, or somebody who is not in the round, credits nobody.
    local server = newServer()
    server.play(2)
    server.diesNaming(2, 2)
    server.settle(3)
    server.wait(1000)
    server.diesNaming(1, 99)
    t.equals(#killLines(server), 0, 'a refused claim was written down as a kill')
end)

t.test('and a name chosen to forge a console line stays one quoted line', function()
    local server = newServer()
    server.play(2)
    server.rowOf(1).name = 'Evil\n[crimson_arena] match m1 ended ^1"x"\27[2J'
    server.diesNaming(2, 1)

    local lines = killLines(server)
    t.equals(#lines, 1, 'the kill was not written down exactly once')
    t.isNil(lines[1]:find('\n', 1, true), 'a name put a line break into the console')
    t.isNil(lines[1]:find('\27', 1, true), 'a name put an escape sequence into the console')
    t.isNil(lines[1]:find('^', 1, true), 'a name put a colour code into the console')
    t.isNil(lines[1]:find('"x"', 1, true), 'a name closed the quotes it is printed inside')
end)

t.test('and the last life says the victim is out', function()
    local server = newServer(function(config) config.Match.lives = 1 end)
    server.play(3)
    server.diesNaming(2, 1)
    local lines = killLines(server)
    t.equals(#lines, 1, 'the kill was not written down')
    t.contains(lines[1], 'the victim is eliminated', 'the line does not say the victim is out')
end)

t.test('and a gun game kill says what it did to both tiers', function()
    local server = newServer(function(config) config.Modes.gungame.enabled = true end)
    server.play(2, 'gungame')
    server.diesNaming(2, 1)

    local lines = killLines(server)
    t.equals(#lines, 1, 'the ladder kill was not written down')
    t.contains(lines[1], 'the killer goes from tier 1 to 2/', 'the line does not say the killer climbed')
    t.contains(lines[1], 'The killer was holding "', 'the line does not name the weapon the kill was made with')
end)

t.test('a line that cannot be built never costs the victim their respawn', function()
    -- It runs before the respawn is scheduled, and nothing above OnDeath
    -- catches a throw: without its pcall, one bad log line would leave the
    -- victim dead for the rest of the round.
    local server = newServer()
    server.play(2)
    server.env.ArenaLogText = function() error('the scrubber fell over') end
    server.diesNaming(2, 1)

    t.isTrue(server.said('KILL line for match'), 'the failure was not reported')
    t.equals(server.rowOf(1).kills, 1, 'the kill itself was lost with the line')
    server.settle(3)
    t.isTrue(server.rowOf(2).alive == true, 'THE VICTIM WAS LEFT DEAD because a log line failed')
end)

-- ======================================================================
-- EVERY BRANCH OF THE LINE, ASSERTED
--
-- The suite drove all of these and asserted almost none: the wording of the
-- outcome could be broken branch by branch with every spec still green. The
-- line is a record an operator settles arguments with, so each thing it
-- can say is pinned to the kill that makes it say it.
-- ======================================================================

t.test('a victim on their last-but-one life has 1 life left, not 1 lives', function()
    local server = newServer(function(config) config.Match.lives = 2 end)
    server.play(3)
    server.diesNaming(2, 1)
    local lines = killLines(server)
    t.equals(#lines, 1, 'the kill was not written down')
    t.contains(lines[1], 'the victim has 1 life left.', 'the line miscounts the lives left')
end)

t.test('and a round that spends no lives says the victim respawns', function()
    local server = newServer(function(config) config.Match.winCondition.default = 'most_kills' end)
    server.play(3)
    server.diesNaming(2, 1)
    local lines = killLines(server)
    t.equals(#lines, 1, 'the kill was not written down')
    t.contains(lines[1], 'The killer is on 1 kill(s); the victim respawns.', 'the line does not say the victim respawns')
end)

t.test('and a kill between team-mates with friendly fire ON says so', function()
    local server = newServer(function(config)
        config.Teams.friendlyFire = true
        config.Modes.tdm.enabled = true
    end)
    server.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    t.isTrue(server.match.IsLive(server.matchId()), 'the round never went live, so nothing below tests anything')
    server.diesNaming(2, 1)
    local lines = killLines(server)
    t.equals(#lines, 1, 'the team-mate kill was not written down')
    t.contains(lines[1], 'They are team-mates: friendly fire is on.', 'the line does not say they share a side')

    server.wait(250)
    server.diesNaming(1, 3)
    lines = killLines(server)
    t.isNil(lines[#lines]:find('team-mates', 1, true), 'a kill across sides was called a team-mate kill')
end)

t.test('and it names what the victim reported: a catalogue gun, fists, a hash it does not know, or nothing', function()
    -- A hasher the test controls: the sandbox's own joaat is the identity,
    -- which resolves nothing.
    local codes, nextCode = {}, 5000
    local function hasher(name)
        if codes[name] == nil then
            nextCode = nextCode + 1
            codes[name] = nextCode
        end
        return codes[name]
    end

    local cases = {
        { label = 'a catalogue gun', cause = function(env) return hasher(env.Arena.GetWeaponByKey('pistol').weapon) end,
          says = function(env) return 'The victim reports "' .. env.Arena.GetWeaponByKey('pistol').label .. '"' end },
        { label = 'fists', cause = function() return 2725352035 end, says = function() return 'The victim reports fists.' end },
        { label = 'an unknown hash', cause = function() return 12345 end,
          says = function() return 'The victim reports cause hash 12345, not a weapon this arena lists.' end },
        { label = 'nothing', cause = function() return nil end, says = function() return 'The victim reports nothing.' end },
    }
    for _, case in ipairs(cases) do
        local server = newServer()
        server.env.GetHashKey = hasher
        server.play(2)
        server.fire('reportDeath', 2, { killerServerId = 1, cause = case.cause(server.env) })
        local lines = killLines(server)
        t.equals(#lines, 1, case.label .. ': the kill was not written down')
        t.contains(lines[1] or '', case.says(server.env), case.label .. ': the line misreports the cause')
    end
end)

--- A gun game on a pinned seven-rung ladder, knife then six pistols, no cap.
--- Kills go straight to OnDeath and stand the victim back up, so the rungs
--- can be walked without the report rate limit or a respawn in between.
local function pinnedLadder()
    local server = newServer(function(config)
        config.Modes.gungame.enabled = true
        config.Modes.gungame.gunGameClasses = nil
        config.Modes.gungame.gunGameTiers = {
            { 'knife' }, { 'pistol' }, { 'combatpistol' }, { 'heavypistol' },
            { 'pistol50' }, { 'revolver' }, { 'appistol' },
        }
        config.Modes.gungame.maxTiersPerVictim = 0
    end)
    server.play(4, 'gungame')

    function server.kill(victim, killer)
        server.match.OnDeath(victim, killer)
        server.rowOf(victim).alive = true
        local lines = killLines(server)
        return lines[#lines] or ''
    end
    function server.labelOf(key)
        local weapon = server.env.Arena.GetWeaponByKey(key)
        return weapon and (weapon.label or weapon.key) or key
    end
    return server
end

t.test('ON A LADDER: a melee kill of a rung-1 victim leaves them at the bottom', function()
    local server = pinnedLadder()
    local line = server.kill(2, 3)
    t.contains(line, 'The killer was holding "' .. server.labelOf('knife') .. '"', 'the line names the wrong weapon')
    t.contains(line, 'the killer goes from tier 1 to 2/7', 'the line does not say the killer climbed')
    t.contains(line, 'the victim stays on tier 1/7, the bottom of the ladder', 'the line misreports the victim')
end)

t.test('and a gun kill spares the victim', function()
    local server = pinnedLadder()
    server.kill(4, 1)
    local line = server.kill(2, 1)
    t.contains(line, 'The killer was holding "' .. server.labelOf('pistol') .. '"', 'the line names the wrong weapon')
    t.contains(line, 'the victim keeps tier 1/7, spared by a gun kill', 'the line does not say the victim was spared')
end)

t.test('and a melee kill of a rung-3 victim moves them down one', function()
    local server = pinnedLadder()
    server.kill(2, 1)
    server.kill(4, 1)
    t.equals(server.rowOf(1).tier, 3, 'player 1 is not on rung 3, so this tests nothing')
    local line = server.kill(1, 3)
    t.contains(line, 'the victim goes from tier 3 to 2/7', 'the line misreports the demotion')
end)

t.test('and the kill that tops the ladder says so, and so does the topped fighter\'s death', function()
    local server = pinnedLadder()
    local line
    for index = 1, 7 do line = server.kill(({ 2, 3, 4 })[(index - 1) % 3 + 1], 1) end
    t.contains(line, 'the killer goes from tier 7 to 7/7, LADDER TOPPED', 'the topping kill is not called out')

    -- THE ROUND ENDS AT THE NEXT SWEEP, and a death before it takes a point
    -- off a score past the top rung -- which leaves the rung where it is.
    -- The line called that "the bottom of the ladder".
    line = server.kill(1, 2)
    t.contains(line, 'the victim stays on tier 7/7 -- they had topped the ladder',
        'THE DEFECT: the topped fighter\'s death was misreported')
    t.isNil(line:find('bottom of the ladder', 1, true), 'THE DEFECT: the top of the ladder was called the bottom')
end)

--- Every character that could break a console line out of its quotes, one of
--- each, including the two a '^' can hide by splitting them.
local HOSTILE = 'Evil\n[crimson_arena] match m1 ended ^1"x"\27[2J\194^\133[crimson_arena] y\226^\128^\168z'

local function assertClean(line, where)
    t.isNil(line:find('\n', 1, true), where .. ': a name put a line break into the console')
    t.isNil(line:find('\27', 1, true), where .. ': a name put an escape into the console')
    t.isNil(line:find('^', 1, true), where .. ': a name put a colour code into the console')
    t.isNil(line:find('"x"', 1, true), where .. ': a name closed the quotes it is printed inside')
    t.isNil(line:find('\194\133', 1, true), where .. ': a name rebuilt a C1 new line out of a split')
    t.isNil(line:find('\226\128\168', 1, true), where .. ': a name rebuilt a line separator out of a split')
end

t.test('A VICTIM\'S NAME is cleaned in every line it is printed in, and so is the accused\'s', function()
    -- Only the killer's name was ever tested. The victim's is printed in
    -- the KILL, TEAMKILL and KILL NOT CREDITED lines, and the accused's in
    -- the last -- each could be printed raw with the suite still green.
    local kill = newServer()
    kill.play(2)
    kill.rowOf(2).name = HOSTILE
    kill.diesNaming(2, 1)
    t.equals(#killLines(kill), 1, 'the kill was not written down')
    assertClean(killLines(kill)[1], 'KILL')

    local teamkill = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    teamkill.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    teamkill.rowOf(2).name = HOSTILE
    teamkill.diesNaming(2, 1)
    local line = teamkill.line('TEAMKILL:')
    t.isNotNil(line, 'no TEAMKILL line, so nothing was tested')
    assertClean(line or '', 'TEAMKILL')

    local refused = newServer(function(config)
        config.Teams.friendlyFire = false
        config.Modes.tdm.enabled = true
    end)
    refused.play(3, 'tdm', { [1] = 'ash', [2] = 'ash', [3] = 'crimson' })
    refused.rowOf(1).lives, refused.rowOf(1).alive = 0, false
    refused.rowOf(1).name = HOSTILE
    refused.rowOf(2).name = HOSTILE
    refused.diesNaming(2, 1)
    line = refused.line('KILL NOT CREDITED')
    t.isNotNil(line, 'no KILL NOT CREDITED line, so nothing was tested')
    assertClean(line or '', 'KILL NOT CREDITED')

    -- AND NOTHING ELSE ON THE CONSOLE EITHER: every line goes through the
    -- one composer, whichever line it is.
    for _, server in ipairs({ kill, teamkill, refused }) do
        for _, printed in ipairs(server.console) do assertClean(printed, 'console') end
    end
end)

os.exit(t.summary())
