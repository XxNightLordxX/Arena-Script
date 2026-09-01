--[[
    crimson_arena/tests/moneyconservation_spec.lua

    NOTHING IS CREATED AND NOTHING IS DESTROYED.

    Every other money spec in this suite picks a scenario and asserts on the
    BALANCES it expects afterwards. That is a real check and it catches real
    bugs, but it has one blind spot it cannot see out of: two mistakes that
    cancel. Pay a winner twice and forget to take a loser's stake and the
    hand-picked figure still comes out right.

    So this file never asserts on anybody's balance. It asserts on the DELTA
    across the whole server:

      CONSERVATION. Add up cash plus bank for every player before the match
      and after it. The two numbers must be equal. The only differences this
      resource is entitled to are ones it takes on purpose and says so:
      Config.Betting.houseCutPercent off the top of a settled pot, and a pot
      forfeited by ArenaBetting.ForfeitAll when a host closes their own lobby
      with refundOnCancel switched off. Both are pinned by name below, with
      the exact figure they are allowed to remove. Anything else appearing or
      disappearing is a defect whichever direction it goes in.

      THE LEDGER. tests/fixtures/sandbox.lua records every RemoveMoney and
      AddMoney the production code makes, with the account each one touched.
      A balance cannot tell a refund that happened twice from one that never
      happened at all when a payout also went wrong; a ledger can. So the
      movements are counted as well as summed, and every one of them is
      checked against the account that player's money is supposed to live in.
      Money must not go out of a bank and come back as cash, in any direction
      and on any path.

    And it does not pick the scenarios. A few hundred seeded, deterministic
    matches are generated and run end to end through the real server files,
    varying everything that decides where money goes: roster size, free-for-
    all and team modes, entry fees paid from either pocket or from no stated
    preference at all, side-bets from fighters and from spectators on winners
    and on losers, betPayout.includeEntryPot, betPayout.sharedPool,
    fighterBets.enabled, fighterBets.ownSideOnly, both refund-on-leaving
    switches, matches that end and matches that abort, hosts who change the
    mode under an open lobby, players who walk out and players who sit back
    down, and the bet-then-join hole. The seed is fixed, so a failure names
    one number that reproduces it.

    A FUZZ THAT NEVER REACHED ANYTHING IS WORSE THAN A RED ONE, so the paths
    the run actually walked are counted and asserted on at the end. A green
    tick here means the settlement code was exercised, not that it was
    skipped.

    WHAT THIS ROUTE CANNOT SEE, said out loud so nobody retires the other
    specs on the strength of it. A conservation check is blind to any mistake
    that moves the right total to the wrong person, and blind by construction
    to one that moves nothing at all. The uncontested-pool defect
    tests/selfbet_spec.lua exists for is exactly that shape: a lone backer was
    told they had won and handed back their own stake, so the economy balanced
    to the dollar while the player was being lied to. Deleting the fix for it
    leaves every assertion in this file green. The two files are different
    instruments and both are needed.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('moneyconservation_spec')

--- Big enough that no fuzzed fee or bet is ever refused for want of funds,
--- so a refusal in the run below is always a RULE refusing and never a
--- wallet. Small enough to stay well inside integer money.
local WALLET = 5000000

--- The two sides Config.Teams ships enabled.
local TEAMS = { 'crimson', 'ash' }

-- ======================================================================
-- A SERVER, BUILT FROM THE REAL FILES
-- ======================================================================

--- Loads config.lua, shared/arena.lua and the five server files into one
--- sandbox, wired to a fake qbx_core whose ledger is the thing this file
--- reads.
--- @param wallets table<integer, table> -- [src] = { cash = n, bank = n }
--- @param mutate function? -- last word on Config, before the server loads
--- @return table server
local function newServer(wallets, mutate)
    local players = {}
    for src, wallet in pairs(wallets) do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('P%d'):format(src),
            money = { cash = wallet.cash, bank = wallet.bank },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local console = {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    -- Started by hand below, so the lobby must not run off and start itself
    -- the moment the last player readies up.
    env.Config.Match.autoStartWhenAllReady = false
    env.Config.Match.lives = 1
    env.Config.Betting.enabled = true
    -- The rake is the one legitimate leak, so it is OFF for every generated
    -- match and switched on only by the two tests that pin its exact size.
    env.Config.Betting.houseCutPercent = 0
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = {
        env = env, qbx = qbx, console = console,
        betting = env.ArenaBetting, match = env.ArenaMatch, lobby = env.ArenaLobby,
    }

    function server.step(times)
        for _ = 1, (times or 1) do threads.step() end
    end

    --- Cash plus bank across everybody. THE number this file is about.
    function server.economy()
        local total = 0
        for _, record in pairs(qbx.players) do
            total = total + record.money.cash + record.money.bank
        end
        return total
    end

    function server.log() return table.concat(console, '\n') end

    return server
end

--- What the players started the round holding, from the same table the
--- server was built out of.
local function openingBalance(wallets)
    local total = 0
    for _, wallet in pairs(wallets) do total = total + wallet.cash + wallet.bank end
    return total
end

-- ======================================================================
-- A SEEDED GENERATOR
--
-- Its own, rather than math.random: Lua's generator is free to change
-- between releases and is seeded per process, and a fuzz whose failing seed
-- does not reproduce tomorrow is a fuzz nobody can act on. This is the
-- MINSTD multiplier on a 31-bit modulus, which is short, exactly specified,
-- and reproducible anywhere lua5.4 runs.
-- ======================================================================

--- @param seed integer
--- @return fun(n: integer?): integer -- 1..n, or the raw state with no n
local function newRng(seed)
    local state = seed % 2147483647
    if state <= 0 then state = state + 2147483646 end
    return function(n)
        state = (state * 48271) % 2147483647
        if not n then return state end
        return (state % n) + 1
    end
end

-- ======================================================================
-- ONE GENERATED MATCH
-- ======================================================================

--- Everything about one round that decides where money goes. Nothing here
--- reads the clock or the environment, so a seed describes the same match on
--- every machine.
--- @param rng function
--- @return table plan
local function makePlan(rng)
    local size = math.max(2, 1 + rng(7))            -- 2..8 fighters
    local plan = {
        size = size,
        teams = rng(2) == 1,
        fee = ({ 0, 0, 500, 1000, 5000 })[rng(5)],
        includeEntryPot = rng(2) == 1,
        sharedPool = rng(2) == 1,
        -- How the POT is split when it is not folded into the bet pool.
        -- Three different splitters in shared/arena.lua, and every one of
        -- them hands its rounding remainder somewhere rather than dropping
        -- it -- which is a promise about conservation, so it is fuzzed.
        potSplit = ({ 'winner_takes_all', 'top_three', 'per_kill' })[rng(3)],
        -- Real deaths before the round is called, so `per_kill` has kills to
        -- divide by and the sweep sometimes ends the match on its own.
        deaths = rng(4) - 1,
        fighterBets = rng(2) == 1,
        ownSideOnly = rng(2) == 1,
        oneBetPerMatch = rng(2) == 1,
        refundBeforeStart = rng(2) == 1,
        refundDuringMatch = rng(3) == 1,
        abort = rng(5) == 1,
        liveLeaver = rng(3) == 1,
        lobbyLeaver = rng(4) == 1,
        rejoin = rng(3) == 1,
        betThenJoin = rng(3) == 1,
        updateMode = rng(4) == 1,
        emptyOut = rng(12) == 1,
        wallets = {},
        accounts = {},
        bets = {},
    }

    -- Two spectators sit outside the roster so there is always somebody who
    -- can back a fighter without being one.
    for src = 1, size + 2 do
        -- AN EMPTY POCKET IS THE INTERESTING WALLET. It is the only thing
        -- that separates "the account they asked for" from "the account that
        -- actually paid", which is the distinction every refund in
        -- server/betting.lua turns on.
        local shape = rng(4)
        plan.wallets[src] = (shape == 1 and { cash = 0, bank = WALLET })
            or (shape == 2 and { cash = WALLET, bank = 0 })
            or { cash = WALLET, bank = WALLET }

        -- Three answers, matching accountsFor: a named account, the other
        -- named account, or no preference at all.
        local pick = rng(3)
        plan.accounts[src] = (pick == 1 and 'cash') or (pick == 2 and 'bank') or nil
    end

    for _ = 1, rng(5) - 1 do                          -- 0..4 side-bets
        plan.bets[#plan.bets + 1] = {
            src = rng(size + 2),                     -- fighters and spectators alike
            amount = 100 + rng(24900),               -- inside both configured bands
            pick = plan.teams and TEAMS[rng(2)] or rng(size),
        }
    end

    return plan
end

--- The account one player's money has to move through for the whole round:
--- the one they chose, or -- with no preference stated -- the first on the
--- operator's list they can actually pay out of. Never the other one, and
--- never one direction only.
--- @return string
local function expectedAccount(plan, src)
    if plan.accounts[src] then return plan.accounts[src] end
    return plan.wallets[src].cash > 0 and 'cash' or 'bank'
end

--- Runs one plan against a real server, start to finish.
---
--- EVERY PLAN IS AUDITED, including the ones the rules refuse. A host who
--- picked an account they have nothing in cannot open the lobby at all, and a
--- roster the mode will not start is torn down instead -- both are money
--- questions ("did the refusal cost anybody anything?", "did the teardown
--- hand every stake back?") and neither is a reason to drop the seed.
--- @return table out
local function run(plan)
    local server = newServer(plan.wallets, function(config)
        config.Betting.betPayout.includeEntryPot = plan.includeEntryPot
        config.Betting.betPayout.sharedPool = plan.sharedPool
        config.Betting.fighterBets.enabled = plan.fighterBets
        config.Betting.fighterBets.ownSideOnly = plan.ownSideOnly
        config.Betting.fighterBets.oneBetPerMatch = plan.oneBetPerMatch
        config.Betting.spectatorBets.oneBetPerMatch = plan.oneBetPerMatch
        config.Betting.refundOnDisconnectBeforeStart = plan.refundBeforeStart
        config.Betting.refundOnDisconnectDuringMatch = plan.refundDuringMatch
        config.Betting.payout = plan.potSplit
    end)

    --- Which optional paths this run really walked, so the coverage check at
    --- the bottom is reading facts rather than intentions.
    local took = {}

    local id = server.lobby.Create(1, 'airfield', plan.teams and 'tdm' or 'ffa',
        plan.fee, nil, nil, plan.accounts[1])
    if not id then
        -- The host could not pay the fee out of the pocket they named. Create
        -- unwinds its own match, so there is nothing to tear down -- but the
        -- refusal still has to have cost them nothing, which the audit says.
        took['the host could not pay'] = true
        return { server = server, id = nil, placed = {}, took = took }
    end
    if plan.teams then server.lobby.SetTeam(1, TEAMS[1]) end

    for src = 2, plan.size do
        server.lobby.Join(src, id, plan.teams and TEAMS[((src - 1) % 2) + 1] or nil,
            plan.accounts[src])
    end

    local placed = {}
    for _, bet in ipairs(plan.bets) do
        local ok = server.betting.PlaceSpectatorBet(bet.src, id, bet.pick, bet.amount,
            plan.accounts[bet.src])
        placed[#placed + 1] = { src = bet.src, ok = ok == true }
        took[ok == true and 'a bet was accepted' or 'a bet was refused'] = true
    end

    -- THE BET-THEN-JOIN HOLE, walked on purpose: back a side, then take a
    -- seat on the match you just backed. It is the only route that reaches
    -- `voided`, and it is only open on a free match -- TakeStake refuses a
    -- paid seat to somebody already holding a bet on it.
    if plan.betThenJoin then
        for _, entry in ipairs(placed) do
            if entry.ok and entry.src > plan.size then
                took['a bettor took a seat afterwards'] =
                    server.lobby.Join(entry.src, id, plan.teams and TEAMS[1] or nil,
                        plan.accounts[entry.src]) == true
                break
            end
        end
    end

    -- The host changes the mode of an open lobby, which hands every
    -- outstanding side-bet back unjudged and clears everybody's team.
    if plan.updateMode then
        took['the host changed the mode'] =
            server.lobby.UpdateMatch(1, { modeKey = plan.teams and 'ffa' or 'tdm' }) == true
        for src in pairs(server.lobby.Get(id).players) do
            server.lobby.SetTeam(src, TEAMS[((src - 1) % 2) + 1])
        end
    end

    -- Somebody walks out of the LOBBY, before a shot is fired. Kept above
    -- minPlayers so the round still has one to run.
    local walkedOut
    if plan.lobbyLeaver then
        local sitting = {}
        for src in pairs(server.lobby.Get(id).players) do sitting[#sitting + 1] = src end
        table.sort(sitting)
        if #sitting > 2 then
            walkedOut = sitting[#sitting]
            took['somebody left the lobby'] = server.lobby.Leave(walkedOut, 'match.left') == true
        end
    end

    -- ...and sits back down. On a server that does not refund a lobby exit
    -- their forfeited stake is still in this pot, so this must take nothing a
    -- second time.
    if plan.rejoin and walkedOut and server.lobby.Get(id) then
        took['and sat back down'] = server.lobby.Join(walkedOut, id,
            plan.teams and TEAMS[((walkedOut - 1) % 2) + 1] or nil,
            plan.accounts[walkedOut]) == true
    end

    -- The whole room walks out before a shot is fired, which destroys the
    -- match through ArenaLobby.Destroy rather than through either settlement.
    if plan.emptyOut then
        local sitting = {}
        for src in pairs(server.lobby.Get(id).players) do sitting[#sitting + 1] = src end
        table.sort(sitting)
        for _, src in ipairs(sitting) do server.lobby.Leave(src, 'match.left') end
        took['the lobby emptied out'] = true
        server.step(6)
        return { server = server, id = id, placed = placed, took = took }
    end

    for src in pairs(server.lobby.Get(id).players) do server.lobby.SetReady(src, true) end

    -- A ROSTER THE MODE WILL NOT START -- everybody on one side of a team
    -- match, most often, after somebody walked out of it. The lobby is torn
    -- down rather than abandoned, because a lobby left open is a pot left
    -- held, and that is the harness leaking rather than the resource.
    if not server.match.Start(id) then
        took['the lobby would not start'] = server.match.Abort(id, 'match.aborted') == true
        server.step(6)
        return { server = server, id = id, placed = placed, took = took }
    end
    server.step(1)

    local match = server.lobby.Get(id)
    if not match or match.state ~= 'live' then
        took['the round never went live'] = true
        server.step(6)
        return { server = server, id = id, placed = placed, took = took }
    end

    -- A bettor walks out of a LIVE round, before it is decided.
    if plan.liveLeaver then
        for _, entry in ipairs(placed) do
            if entry.ok and entry.src <= plan.size then
                took['a bettor left mid-round'] =
                    server.match.RemovePlayer(entry.src, 'match.left') == true
                break
            end
        end
    end

    -- PEOPLE ACTUALLY DIE. One life apiece, so each of these eliminates
    -- somebody and puts a kill on the board -- which is what `per_kill` needs
    -- to divide by, and what lets the sweep decide the round on its own
    -- instead of always being told the answer below.
    for _ = 1, plan.deaths do
        local live = server.lobby.Get(id)
        if not live or live.state ~= 'live' then break end
        local standing = {}
        for src, row in pairs(live.players) do
            if row.alive then standing[#standing + 1] = src end
        end
        table.sort(standing)
        if #standing < 2 then break end
        took['somebody was killed'] =
            server.match.OnDeath(standing[#standing], standing[1]) == true
        -- Twice: the sweep is a Wait-first loop, so one resume only reaches
        -- its Wait. Two is one full pass, which is where it notices that a
        -- round has run out of people to fight it.
        server.step(2)
    end

    match = server.lobby.Get(id)
    -- The sweep ends a round that has run out of people to fight it, and End
    -- destroys the record on its way out -- so a match that has GONE by here
    -- is one the resource called itself rather than one this file called.
    if took['somebody was killed'] and (not match or match.state == 'ended') then
        took['the sweep called it'] = true
    end

    if match and match.state ~= 'ended' then
        if plan.abort then
            took['the match aborted'] = server.match.Abort(id, 'match.aborted') == true
        else
            -- The winners are read off the match rather than off the plan: a
            -- mid-lobby mode change means the round is not always fought in
            -- the mode it opened in.
            local standing = {}
            for src in pairs(match.players) do standing[#standing + 1] = src end
            table.sort(standing)

            local winners = {}
            if #standing > 0 then
                if server.env.Arena.ModeUsesTeams(match.modeKey) then
                    local team = match.players[standing[1]].team
                    for _, src in ipairs(standing) do
                        if match.players[src].team == team then winners[#winners + 1] = src end
                    end
                else
                    winners[1] = standing[1]
                end
            end
            took['the match was decided'] =
                server.match.End(id, 'match.ended', winners) == true
        end
    end
    server.step(6)

    return { server = server, id = id, placed = placed, took = took }
end

-- ======================================================================
-- WHAT IS CHECKED AFTER EVERY ONE OF THEM
-- ======================================================================

--- Console lines server/betting.lua prints when money it is responsible for
--- could not be delivered or could not be dropped. None of them may appear
--- in a run where every player is present the whole time, and any one of
--- them means money is sitting somewhere nobody can reach.
local STRANDED = {
    'CLEAR REFUSED', 'REFUND FAILED', 'REFUND INCOMPLETE', 'PAYOUT UNDELIVERED',
    'SIDE-BET REFUND FAILED', 'SIDE-BET PAYOUT UNDELIVERED', 'SETTLE REFUSED',
}

--- Audits one finished run. Returns a list of complaints per category, so a
--- failure in one property does not hide the others.
--- @return table<string, string[]>
local function audit(plan, out)
    local server, id = out.server, out.id
    local found = { conservation = {}, accounts = {}, movements = {}, books = {} }

    local expected = openingBalance(plan.wallets)
    local actual = server.economy()
    if actual ~= expected then
        found.conservation[#found.conservation + 1] =
            ('the economy moved by %+d (%d, expected %d)'):format(actual - expected, actual, expected)
    end

    -- The ledger's own sum, worked out from the movements rather than from
    -- the balances. The two disagreeing would mean the fixture and the
    -- server are describing different events, which is worth knowing.
    local net = 0
    for _, entry in ipairs(server.qbx.ledger) do net = net + entry.delta end
    if net ~= 0 then
        found.conservation[#found.conservation + 1] = ('the ledger sums to %+d, not 0'):format(net)
    end

    for src in pairs(plan.wallets) do
        local wanted = expectedAccount(plan, src)
        local debits, credits = 0, 0

        for _, entry in ipairs(server.qbx.ledger) do
            if entry.id == src then
                if entry.account ~= wanted then
                    found.accounts[#found.accounts + 1] =
                        ('player %d pays from %s but a %+d movement touched %s')
                            :format(src, wanted, entry.delta, entry.account)
                end
                if entry.delta < 0 then debits = debits + 1 else credits = credits + 1 end
            end
        end

        -- A DOUBLE REFUND NETS OUT TO NOTHING against a payout that never
        -- happened, and both leave the balance where it started. The count is
        -- what tells them apart: every movement into a player is the
        -- settlement of one movement out of them, so there can never be more
        -- of the first than of the second.
        if credits > debits then
            found.movements[#found.movements + 1] =
                ('player %d was credited %d time(s) against %d debit(s)'):format(src, credits, debits)
        end

        if server.betting.HasSpectatorBet(id, src) then
            found.books[#found.books + 1] =
                ('player %d still has a side-bet on the books after Clear'):format(src)
        end
    end

    local held = server.betting.GetPot(id)
    if held ~= 0 then
        found.books[#found.books + 1] = ('escrow still holds %d'):format(held)
    end

    local log = server.log()
    for _, needle in ipairs(STRANDED) do
        if log:find(needle, 1, true) then
            found.books[#found.books + 1] = ('the console says %s'):format(needle)
        end
    end

    return found
end

-- ======================================================================
-- THE RUN
-- ======================================================================

--- How many matches are generated. Every one of them loads the real config
--- and the real server files, so this is the whole cost of the file.
local SEEDS = 400

local complaints = { conservation = {}, accounts = {}, movements = {}, books = {} }
local walked = {}

for seed = 1, SEEDS do
    local plan = makePlan(newRng(seed))
    local out = run(plan)
    for name, taken in pairs(out.took) do
        if taken then walked[name] = (walked[name] or 0) + 1 end
    end
    for category, problems in pairs(audit(plan, out)) do
        for _, problem in ipairs(problems) do
            complaints[category][#complaints[category] + 1] = ('seed %d: %s'):format(seed, problem)
        end
    end
end

--- The first few failures, named by seed so one number reproduces it.
local function report(category)
    local problems = complaints[category]
    local shown = {}
    for index = 1, math.min(3, #problems) do shown[index] = problems[index] end
    if #problems > 3 then shown[#shown + 1] = ('...and %d more'):format(#problems - 3) end
    return table.concat(shown, '; ')
end

t.test(('%d generated matches created and destroyed no money'):format(SEEDS), function()
    t.equals(#complaints.conservation, 0, report('conservation'))
end)

t.test('no money crossed between a player\'s two accounts', function()
    t.equals(#complaints.accounts, 0, report('accounts'))
end)

t.test('nobody was paid more times than they were charged', function()
    t.equals(#complaints.movements, 0, report('movements'))
end)

t.test('every match left its books empty and nothing owed', function()
    t.equals(#complaints.books, 0, report('books'))
end)

t.test('and it reached every settlement path this file exists to cover', function()
    -- A GREEN TICK FROM A SUITE THAT NEVER RAN is the one failure mode a
    -- property test cannot report on itself, so the paths are counted as they
    -- are walked and every one of them has to have been.
    for _, path in ipairs({
        'a bet was accepted', 'a bet was refused', 'the match was decided',
        'the match aborted', 'a bettor left mid-round', 'somebody left the lobby',
        'and sat back down', 'a bettor took a seat afterwards',
        'the host changed the mode', 'the lobby emptied out',
        'the host could not pay', 'the lobby would not start',
        'somebody was killed', 'the sweep called it',
    }) do
        t.isTrue((walked[path] or 0) > 0, ('no generated match ever reached "%s"'):format(path))
    end
end)

-- ======================================================================
-- THE TWO LEAKS THIS RESOURCE IS ENTITLED TO
--
-- Both are deliberate, both are documented in config.lua, and both are
-- pinned to an exact figure here. A test that only proved money never
-- vanishes would pass just as happily if the rake stopped working.
-- ======================================================================

--- A three-handed round at a fixed fee, run to `finish`, with the economy
--- measured against what the room walked in with.
--- @param mutate function? -- Config, before the server loads
--- @param finish function -- what ends the match: (server, matchId)
--- @return integer delta -- what the economy moved by, signed
--- @return table server
local function pinned(fee, mutate, finish)
    local wallets = {
        [1] = { cash = WALLET, bank = WALLET },
        [2] = { cash = WALLET, bank = WALLET },
        [3] = { cash = WALLET, bank = WALLET },
    }
    local server = newServer(wallets, mutate)
    local id = server.lobby.Create(1, 'airfield', 'ffa', fee, nil, nil, 'cash')
    server.lobby.Join(2, id, nil, 'cash')
    server.lobby.Join(3, id, nil, 'cash')
    finish(server, id)
    server.step(6)
    return server.economy() - openingBalance(wallets), server
end

--- Starts the round and hands it to player 1.
local function fightAndWin(server, id)
    for src = 1, 3 do server.lobby.SetReady(src, true) end
    server.match.Start(id)
    server.step(1)
    server.match.End(id, 'match.ended', { 1 })
end

t.test('a host cancelling a no-refund lobby burns the pot and not a dollar more', function()
    -- refundOnCancel = false is the one path that ends with nobody credited.
    -- config.lua says the money "goes nowhere at all" on purpose; this is
    -- the number that has to be, and stay, exactly the pot.
    local delta = pinned(5000, function(config)
        config.Betting.refundOnCancel = false
    end, function(server, id)
        server.lobby.Cancel(1)
    end)
    t.equals(delta, -15000, 'three 5,000 stakes were forfeited, so 15,000 leaves')
end)

t.test('and cancelling with the refund left on burns nothing', function()
    local delta = pinned(5000, nil, function(server, id)
        server.lobby.Cancel(1)
    end)
    t.equals(delta, 0, 'a refunded cancel moved money nowhere')
end)

t.test('the house cut off a settled pot is exactly houseCutPercent', function()
    local delta = pinned(4000, function(config)
        config.Betting.houseCutPercent = 25
        -- The pot only settles on its OWN when it is not folded into the bet
        -- pool, and Arena.ApplyHouseCut is only reached down that path.
        config.Betting.betPayout.includeEntryPot = false
    end, fightAndWin)
    t.equals(delta, -3000, '25% of a 12,000 pot')
end)

t.test('a rake asked for under includeEntryPot is not taken, and is not taken quietly', function()
    -- THE ONE PLACE THE ECONOMY IS ALLOWED TO SHRINK AND DOES NOT.
    --
    -- betPayout.includeEntryPot ships ON, and on that path ArenaBetting
    -- .Settle hands the stakes to the bet pool and returns before
    -- Arena.ComputePayouts -- the only thing that applies the cut -- is ever
    -- reached. A pool is the bettors' money, so nothing is raked off it and
    -- the round is conserved to the dollar.
    --
    -- That is a deliberate decision rather than a leak, and the thing that
    -- makes it defensible is that Arena.ValidateConfig says so out loud at
    -- startup. Both halves are asserted here: the money that does not move,
    -- AND the sentence the operator gets instead of a mystery. Losing either
    -- one turns this back into a setting that does nothing and says nothing.
    local delta, server = pinned(4000, function(config)
        config.Betting.houseCutPercent = 25
        config.Betting.betPayout.includeEntryPot = true
    end, fightAndWin)
    t.equals(delta, 0, 'the pool was raked after all')
    t.notContains(server.log(), 'house kept', 'the pot never settles on its own down this path')

    local complaint = table.concat(server.env.Arena.ValidateConfig(), '\n')
    t.contains(complaint, 'NO CUT IS TAKEN', 'the validator went quiet about an uncollected rake')
end)

-- ======================================================================
-- TWO MATCHES AT ONCE
-- ======================================================================

t.test('two matches settling side by side do not pay each other', function()
    -- Escrow and the side-bet table are both keyed by match id, and one
    -- spectator holding a bet on each is the case that would notice if
    -- either were not. Run to two different endings on purpose: one decided,
    -- one aborted, so a leak in either direction has somewhere to go.
    local wallets = {}
    for src = 1, 5 do wallets[src] = { cash = WALLET, bank = WALLET } end
    local server = newServer(wallets)

    local first = server.lobby.Create(1, 'airfield', 'ffa', 2500, nil, nil, 'cash')
    server.lobby.Join(2, first, nil, 'bank')
    local second = server.lobby.Create(3, 'airfield', 'ffa', 1000, nil, nil, 'bank')
    server.lobby.Join(4, second, nil, 'cash')

    t.isTrue(server.betting.PlaceSpectatorBet(5, first, 1, 3000, 'cash'), 'bet on the first match')
    t.isTrue(server.betting.PlaceSpectatorBet(5, second, 3, 7000, 'bank'), 'bet on the second match')

    for _, src in ipairs({ 1, 2 }) do server.lobby.SetReady(src, true) end
    server.match.Start(first)
    for _, src in ipairs({ 3, 4 }) do server.lobby.SetReady(src, true) end
    server.match.Start(second)
    server.step(1)

    server.match.End(first, 'match.ended', { 1 })
    server.match.Abort(second, 'match.aborted')
    server.step(6)

    t.equals(server.economy(), openingBalance(wallets), 'money moved between the two matches')
    -- The aborted one returned everything, so the bettor is whole on that
    -- side and the only movement left on their bank is the round trip.
    t.equals(server.qbx.net(5, 'bank'), 0, 'the aborted match kept the bet it could not judge')
    t.equals(server.qbx.movements(5), 4, 'two bets placed, two settled, and nothing else')
end)

-- ======================================================================
-- AND A REFUSAL COSTS NOTHING
-- ======================================================================

t.test('a bet refused for want of funds moves nothing at all', function()
    local wallets = {
        [1] = { cash = WALLET, bank = WALLET },
        [2] = { cash = WALLET, bank = WALLET },
        [3] = { cash = 0, bank = WALLET },
    }
    local server = newServer(wallets)
    local id = server.lobby.Create(1, 'airfield', 'ffa', 0, nil, nil, 'cash')
    server.lobby.Join(2, id, nil, 'cash')

    -- An empty pocket, and cash is the account they picked. accountsFor
    -- refuses rather than quietly spending the bank they left alone.
    local ok = server.betting.PlaceSpectatorBet(3, id, 1, 5000, 'cash')
    t.isFalse(ok, 'a bet was taken out of an empty pocket')
    t.equals(#server.qbx.ledger, 0, 'a refused bet left a movement behind')
    t.equals(server.economy(), openingBalance(wallets), 'a refused bet moved money')
end)

os.exit(t.summary())
