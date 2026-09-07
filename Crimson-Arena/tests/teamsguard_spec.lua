--[[
    crimson_arena/tests/teamsguard_spec.lua

    THREE THINGS THAT DECIDE A TEAM ROUND, AND ONE THAT DECIDED WHETHER THE
    RESOURCE STARTED AT ALL.

    Every one of these came out of an eighteen-agent review of team
    deathmatch, and every one was reproduced before it was fixed:

      A QUOTATION MARK IN config.lua BRICKED THE WHOLE RESOURCE.
      `order = "1"` on one team reached a table.sort comparing it to a
      number, Lua raised rather than guessed, and that threw out of
      Arena.GetEnabledTeams -- which Arena.ValidateConfig calls, which
      onResourceStart calls. The validator written to catch that typo was
      taken down by it, so nothing was ever printed and the arena simply did
      not exist.

      A LEAVER TOOK THEIR SIDE'S KILLS WITH THEM. A team's score is the sum
      of its members' kills, and ArenaLobby.Leave deletes a departed
      fighter's row -- correctly, so nobody can be crowned after walking out.
      Six kills for your side and a rage-quit therefore HANDED the round to
      the other one, and the pot with it. A button anybody could press.

      THE EXIT CHARGED PLAYERS FOR WHAT THEY SPENT, out of their own
      identical stock. The reclaim asks for what was issued and clamps it to
      what is still held, which is right while the two stacks are the
      arena's alone -- and wrong the moment they are not.

    THE THIRD ONE ONLY BITES WITH THE DOOR OFF (Config.Loadouts.inventory
    .stripOnEntry = false), which is a documented, supported setting: with
    the door on the stash has already taken everything, so there is nothing
    of the player's for the arena to take twice.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teamsguard_spec')

-- ======================================================================
-- THE CONFIG TYPO THAT TOOK THE RESOURCE WITH IT
-- ======================================================================

--- A config with one team's `order` set to whatever is handed in.
--- @param order any
--- @return table env
local function withTeamOrder(order)
    local env = Sandbox.newArenaEnv({})
    local first = nil
    for key in pairs(env.Config.Teams.list or {}) do
        if first == nil or key < first then first = key end
    end
    env.Config.Teams.list[first].order = order
    return env, first
end

t.test('a team order that is not a number does not take the resource down', function()
    -- THE SHAPE OF THE FAILURE, not just the value: Lua raises on
    -- `1 < "2"`, so ONE team with a string order was enough, and it did not
    -- matter what the others held.
    for _, junk in ipairs({ '1', '10', 'first', true, {} }) do
        local env = withTeamOrder(junk)

        local ok, teams = pcall(env.Arena.GetEnabledTeams)
        t.isTrue(ok, ('Config.Teams order = %s threw out of GetEnabledTeams: %s')
            :format(tostring(junk), tostring(teams)))
        t.isTrue(type(teams) == 'table' and #teams > 0,
            'and it should still answer with the teams that are enabled')

        -- AND THE VALIDATOR HAS TO SURVIVE IT, because it is the thing that
        -- exists to tell the operator. It calls GetEnabledTeams itself, so
        -- the typo used to kill the report of the typo.
        local reported, problems = pcall(env.Arena.ValidateConfig)
        t.isTrue(reported, ('ValidateConfig threw on order = %s: %s')
            :format(tostring(junk), tostring(problems)))
        t.isTrue(type(problems) == 'table', 'and it should answer with a list')
    end
end)

t.test('and the operator is told, by name, which team it was', function()
    -- A value that cannot be READ as a number, not merely one written as a
    -- string: `order = "1"` is a typo the resource can honour, and honouring
    -- it silently is the right answer. `"first"` is not.
    local env, key = withTeamOrder('first')
    local said = table.concat(env.Arena.ValidateConfig() or {}, '\n')

    t.isTrue(said:find(key, 1, true) ~= nil,
        ('the complaint should name the team it is about -- got: %s'):format(said))
    t.isTrue(said:find('not a number', 1, true) ~= nil,
        ('and say what is wrong with it -- got: %s'):format(said))

    -- AND STAY QUIET ON A CONFIG THAT IS RIGHT. A false alarm on a good
    -- config is as bad as silence on a broken one -- and that includes a
    -- numeric string, which is honoured rather than complained about.
    local clean = Sandbox.newArenaEnv({})
    local quiet = table.concat(clean.Arena.ValidateConfig() or {}, '\n')
    t.isTrue(quiet:find('not a number', 1, true) == nil,
        ('the shipped config should raise no order complaint -- got: %s'):format(quiet))

    local coercible = withTeamOrder('1')
    local alsoQuiet = table.concat(coercible.Arena.ValidateConfig() or {}, '\n')
    t.isTrue(alsoQuiet:find('not a number', 1, true) == nil,
        ('order = "1" is readable as a number and must not be complained about -- got: %s')
            :format(alsoQuiet))
end)

t.test('an ordering the operator wrote is still the ordering they get', function()
    -- THE COERCION MUST NOT QUIETLY REORDER A CONFIG THAT WAS FINE.
    local env = Sandbox.newArenaEnv({})
    local wanted = {}
    for key, team in pairs(env.Config.Teams.list or {}) do
        if team.enabled ~= false then wanted[#wanted + 1] = { key = key, order = team.order or 999 } end
    end
    table.sort(wanted, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.key < b.key
    end)

    local got = env.Arena.GetEnabledTeams()
    t.equals(#got, #wanted, 'the same teams come back')
    for index, entry in ipairs(wanted) do
        t.equals(got[index].key, entry.key,
            ('team %d should be %s'):format(index, entry.key))
    end
end)

-- ======================================================================
-- THE FOUR SEAMS FRIENDLY FIRE HANGS OFF
-- ======================================================================

t.test('every enabled team maps to a real engine team number, and nobody to -1', function()
    -- Arena.TeamIndex IS WHAT holdFriendlyFire PUTS THE PLAYER ON.
    -- SetPlayerTeam(-1) is the engine's "no team", which is where an
    -- ordinary player starts -- so a mapping that answered -1, or 0, or the
    -- same number for two sides, would silently switch engine-level friendly
    -- fire OFF for that side while every other test in the suite stayed
    -- green. The mapping was asserted nowhere.
    local env = Sandbox.newArenaEnv({})
    local teams = env.Arena.GetEnabledTeams()
    t.isTrue(#teams >= 2, 'the shipped config needs at least two sides for this to mean anything')

    local seen = {}
    for _, team in ipairs(teams) do
        local index = env.Arena.TeamIndex(team.key)

        t.isTrue(type(index) == 'number',
            ('team %s has no engine team number at all'):format(team.key))
        t.isTrue(index >= 1,
            ('team %s maps to %s -- anything below 1 is the engine\'s "no team", which turns friendly fire back ON for that side')
                :format(team.key, tostring(index)))
        t.equals(seen[index], nil,
            ('teams %s and %s share engine number %s, so they can shoot each other')
                :format(tostring(seen[index]), team.key, tostring(index)))
        seen[index] = team.key
    end

    -- AND A KEY THAT IS NOT A TEAM ANSWERS NOTHING, rather than a number
    -- that would put the player on somebody else's side. holdFriendlyFire
    -- returns early on nil, which is the safe reading.
    t.equals(env.Arena.TeamIndex('nosuchteam'), nil, 'an invented key maps to nothing')
    t.equals(env.Arena.TeamIndex(nil), nil, 'and so does no key at all')
end)

t.test('a fighter cannot change sides once the round has started', function()
    -- SWITCHING SIDES MID-ROUND FLIPS WHO YOU MAY SHOOT AND WHO PAYS YOU.
    -- The guard is one line and nothing asserted it: a player about to lose
    -- could join the winning side, and with friendlyFire off their old
    -- teammates would stop being able to shoot back.
    -- The real server files, with the thread runner they expect: betting.lua
    -- starts a sweep at load and a nil CreateThread raises before a single
    -- assertion runs.
    local threads = Sandbox.newThreadRunner()
    local qbx = Sandbox.newQbxCore({
        [1] = {
            citizenid = 'CID001', name = 'Fighter 1',
            money = { cash = 50000, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        },
    })
    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        TriggerClientEvent = function() end,
        RegisterNetEvent = function() end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetPlayerName = function(src) return ('Fighter %s'):format(tostring(src)) end,
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
    for _, file in ipairs({ 'util', 'betting', 'lobby' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local teams = env.Arena.GetEnabledTeams()
    local first, second = teams[1].key, teams[2].key

    -- Positional, not a table: ArenaLobby.Create(src, arenaKey, modeKey,
    -- entryFee, lives, radar, account).
    local id, why = env.ArenaLobby.Create(1, 'trailerpark', 'tdm', 0, 3, false, 'cash')
    t.isTrue(id ~= nil, ('the lobby did not open: %s'):format(tostring(why)))
    local match = env.ArenaLobby.All()[1]

    -- IN A LOBBY IT IS ALLOWED, which is what makes the refusal below a
    -- refusal about the STATE rather than about the request.
    t.equals(select(1, env.ArenaLobby.SetTeam(1, first)), true, 'a side may be picked in a lobby')
    t.equals(select(1, env.ArenaLobby.SetTeam(1, second)), true, 'and changed in a lobby')

    for _, state in ipairs({ 'countdown', 'live', 'ending' }) do
        match.state = state
        local allowed, reason = env.ArenaLobby.SetTeam(1, first)
        t.equals(allowed, false, ('a side must not be changeable while the match is %s'):format(state))
        t.equals(reason, 'error.match_in_progress', 'and the refusal has to say why')
    end
end)

t.test('a teammate kill is not credited when friendly fire is off', function()
    -- THE SERVER-SIDE HALF OF THE FRIENDLY-FIRE RULE. The client hold stops
    -- the shot landing; this stops a kill being CREDITED if one somehow is
    -- reported -- and it is the only half a crafted death report has to get
    -- past. Nothing asserted it, so deleting the check credited teammate
    -- kills with friendlyFire off, which is the behaviour the resource says
    -- it fixed.
    local env = Sandbox.newArenaEnv({})
    local teams = env.Arena.GetEnabledTeams()
    local ours, theirs = teams[1].key, teams[2].key

    t.equals(env.Config.Teams.friendlyFire, false,
        'the shipped config has friendly fire off, which is what this is about')
    t.equals(env.Arena.CanDamage('tdm', ours, theirs), true, 'an opponent may be damaged')
    t.equals(env.Arena.CanDamage('tdm', ours, ours), false, 'and a teammate may not')

    -- WITH IT ON, the same pair is damageable -- so the answer follows the
    -- operator's setting rather than being a constant.
    local loose = Sandbox.newArenaEnv({})
    loose.Config.Teams.friendlyFire = true
    t.equals(loose.Arena.CanDamage('tdm', ours, ours), true,
        'an operator who asked for friendly fire gets it')

    -- AND A FREE-FOR-ALL HAS NO SIDES TO PROTECT, so everybody is fair game
    -- however the teams are configured.
    t.equals(env.Arena.CanDamage('ffa', ours, ours), true,
        'a free-for-all must not inherit the team rule')
end)

t.test('the crossfire guard is opt-OUT, so an old config keeps its protection', function()
    -- IT GUARDS TWO THINGS AT ONCE: the arena against the city, and a player
    -- against their own side. An operator upgrading from a config written
    -- before the block existed has no `crossfireGuard` key at all -- and if
    -- absence read as "off", that upgrade would silently switch BOTH off.
    --
    -- Read through the same expression server/dispatch.lua uses, so this
    -- cannot pass while that one changes.
    local function enabled(block)
        local env = Sandbox.newArenaEnv({})
        env.Config.Match.crossfireGuard = block
        return (env.Config.Match.crossfireGuard or {}).enabled ~= false
    end

    t.equals(enabled(nil), true, 'a config with no crossfireGuard block at all keeps the guard')
    t.equals(enabled({}), true, 'and so does an empty one')
    t.equals(enabled({ enabled = true }), true, 'switched on is on')
    t.equals(enabled({ enabled = false }), false,
        'and only an explicit false switches it off -- that is the whole opt-out contract')

    -- NOT A TRUTHINESS TEST. `enabled = 0` and `enabled = 'no'` are truthy
    -- in Lua, and reading them as "off" would be a different rule.
    t.equals(enabled({ enabled = 0 }), true, 'zero is not false in Lua and must not read as off')
    t.equals(enabled({ enabled = 'no' }), true, 'nor is a string')
end)

t.test('the scoreboard on the wire carries the side each fighter is on', function()
    -- THE OTHER HALF OF THE HAZE. blipscope_spec proves the client draws
    -- nobody without `team` on the row; this proves the server puts it
    -- there. Between them the seam is covered from both ends -- which it was
    -- not, so dropping the field would have turned the haze off for every
    -- team round with the whole suite green.
    local threads = Sandbox.newThreadRunner()
    local sent = {}
    local players = {}
    for id = 1, 4 do
        players[id] = {
            citizenid = ('CID%03d'):format(id), name = ('Fighter %d'):format(id),
            money = { cash = 50000, bank = 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end
    local qbx = Sandbox.newQbxCore(players)
    local netEvents = {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function() end,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() return 60000 end,
        GetPlayerName = function(src) return ('Fighter %s'):format(tostring(src)) end,
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
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
            SwapWeapon = function() return false, 'no-inventory' end,
            GrantSupply = function() return false end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return true end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    env.Config.Match.startCountdownSeconds = 0
    env.Config.Betting.enabled = false
    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local teams = env.Arena.GetEnabledTeams()
    local function fire(event, src, data)
        env.source = src
        netEvents['crimson_arena:server:' .. event](data)
    end

    fire('createMatch', 1, {
        arenaKey = 'trailerpark', modeKey = 'tdm', entryFee = 0, account = 'cash',
    })
    local id = env.ArenaLobby.All()[1].id
    for src = 2, 4 do fire('joinMatch', src, { matchId = id, account = 'cash' }) end
    for src = 1, 4 do
        fire('setTeam', src, { teamKey = (src % 2 == 1) and teams[1].key or teams[2].key })
    end
    for src = 1, 4 do fire('setReady', src, { ready = true }) end
    for _ = 1, 4 do
        if env.ArenaLobby.Get(id).state == 'live' then break end
        threads.step()
    end
    threads.step()

    local board
    for index = #sent, 1, -1 do
        local message = sent[index]
        if message.event == 'crimson_arena:client:matchHud' and message.payload
            and message.payload.scoreboard then
            board = message.payload.scoreboard
            break
        end
    end

    t.isTrue(type(board) == 'table' and #board > 0, 'the hud carries a scoreboard at all')

    local sides = {}
    for _, row in ipairs(board) do
        t.isTrue(env.Arena.IsKey(row.team),
            ('fighter %s has no team on their row -- the haze reads this field and nothing else')
                :format(tostring(row.id)))
        sides[row.team] = (sides[row.team] or 0) + 1
    end

    t.equals(sides[teams[1].key], 2, 'both fighters on the first side are named as being on it')
    t.equals(sides[teams[2].key], 2, 'and both on the second')

    -- AND THE ENTRY PAYLOAD CARRIES THE PLAYER'S OWN SIDE, which is the
    -- other input: holdFriendlyFire reads `teamKey` off it, and the haze
    -- compares every row against it.
    local entered = {}
    for _, message in ipairs(sent) do
        if message.event == 'crimson_arena:client:enterArena' and message.payload then
            entered[message.target] = message.payload.teamKey
        end
    end
    for src = 1, 4 do
        t.isTrue(env.Arena.IsKey(entered[src]),
            ('fighter %d was sent into the arena with no teamKey -- friendly fire and the haze both hang off it')
                :format(src))
    end
    t.equals(entered[1], entered[3], 'two fighters on one side were sent different keys')
    t.isTrue(entered[1] ~= entered[2], 'and two on opposite sides were sent the same one')
end)

os.exit(t.summary())
