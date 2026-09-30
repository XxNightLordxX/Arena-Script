--[[
    crimson_arena/tests/teamkillrule_spec.lua

    THE TEAMKILL LINE AND THE FRIENDLY-FIRE RULE ARE ONE RULE.

    server/match.lua prints an always-on TEAMKILL line when a dying client
    names a team-mate whose claim was refused. Whether "team-mate, with
    friendly fire off" is true was written out by hand at that line --
    ModeUsesTeams, IsKey, the same side, `friendlyFire ~= true` -- while
    every other reader of the rule asks Arena.CanDamage: kill attribution
    (rosterKiller), the weapon-damage refusal and the explosion refusal.
    Two copies of one condition is how this file's rosterKiller bypass
    drifted, and a copy is what a per-mode friendly-fire switch would have
    had to find and edit a second time.

    So the line now asks Arena.CanDamage too, and this file is about that
    being SAFE as much as about it being done:

      THE OLD RULE IS KEPT HERE, VERBATIM, as a reference, and the real
      OnDeath is driven against it: every mode plus an unknown one, six
      team values on each side, four friendly-fire values -- 576 deaths --
      and then a seeded sweep over the clauses that did NOT move (the
      self-guard, the roster, leftArena, elimination), with the neighbouring
      KILL NOT CREDITED line checked alongside, because the TEAMKILL decision
      is also what silences that one.

      THE RULE HAS ONE READER. Config.Teams.friendlyFire is read in exactly
      one place in the resource's Lua -- inside Arena.CanDamage -- and a
      source scan below keeps it that way.

      AND THE LINE FOLLOWS THE RULE. With Arena.CanDamage answering for a
      mode that lets team-mates hurt each other, a refused team-mate claim
      is no longer announced as a hole in a friendly-fire setting that does
      not exist.

    WHAT DID NOT MOVE AND MUST NOT: the accused is looked up off the roster
    and never the victim themselves, and a team-mate who has left the arena
    or is eliminated is not announced -- rosterKiller refuses that claim on
    the TEAM ground first (it asks CanDamage before it asks whether they are
    out), which is exactly why this line may not be derived from rosterKiller's
    refusal reason.

    Deterministic throughout: the clock is held still, os.time is the
    fixture's, and the sweep's randomness is a local generator with a fixed
    seed rather than the global stream.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('teamkillrule_spec')

-- The Trailer Park's own spawn centre, out of config.lua -- the arena every
-- round in this file is fought in.
local CENTRE = { x = 2344.4294, y = 2565.0552, z = 46.6677 }

--- Nowhere near anybody: nine kilometres off, which is over every kill
--- ceiling this resource can compute and therefore a claim resolveKiller
--- refuses on DISTANCE after the roster has accepted it.
local FAR = { x = CENTRE.x + 9000.0, y = CENTRE.y + 9000.0, z = CENTRE.z }

local NOW = 1700000000

--- A tdm round with four fighters, crimson 1 and 3 against ash 2 and 4.
--- @param mutate fun(config: table)?
--- @return table server
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
    local netEvents, console = {}, {}
    local clock = 1000

    local at = {}
    for src = 1, 4 do at[src] = { x = CENTRE.x + src * 2.0, y = CENTRE.y, z = CENTRE.z } end

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        os = setmetatable({ time = function() return NOW end }, { __index = os }),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
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
    env.Config.Match.maxKillDistance = 100.0
    env.Config.Betting.enabled = false
    env.Config.Teams.friendlyFire = false
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end

    local server = { env = env, config = env.Config, console = console,
        match = env.ArenaMatch, lobby = env.ArenaLobby, Arena = env.Arena }
    local matchId

    local function fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.place(src, point) at[src] = point end

    --- Opens and starts a round through the ready path, the only thing that
    --- starts one in production.
    function server.play(modeKey)
        fire('createMatch', 1, {
            arenaKey = 'trailerpark', modeKey = modeKey or 'tdm', entryFee = 0, account = 'cash',
        })
        matchId = server.lobby.All()[1].id
        for src = 2, 4 do fire('joinMatch', src, { matchId = matchId, account = 'cash' }) end
        if server.Arena.ModeUsesTeams(modeKey or 'tdm') then
            for src = 1, 4 do
                fire('setTeam', src, { teamKey = (src % 2 == 1) and 'crimson' or 'ash' })
            end
        end
        for src = 1, 4 do fire('setReady', src, { ready = true }) end
        for _ = 1, 4 do
            if server.lobby.Get(matchId).state == 'live' then break end
            threads.step()
        end
        assert(server.lobby.Get(matchId).state == 'live', 'the fixture failed to start the round')
        return server.lobby.Get(matchId)
    end

    function server.live() return server.lobby.Get(matchId) end

    --- Everything printed since `from` (an index into the console).
    function server.since(from)
        local out = {}
        for index = from + 1, #console do out[#out + 1] = console[index] end
        return table.concat(out, '\n')
    end

    return server
end

--- How many lines of `text` carry `fragment`.
local function countOf(text, fragment)
    local total = 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        if line:find(fragment, 1, true) then total = total + 1 end
    end
    return total
end

-- ======================================================================
-- THE REFERENCE: THE OLD CONDITION, WORD FOR WORD
-- ======================================================================

--- The TEAMKILL condition as server/match.lua wrote it before this change,
--- copied rather than paraphrased. Evaluated on the state the death is
--- about to be read against.
local function oldTeamKill(Arena, Config, match, id, killerSrc, player)
    local accused = killerSrc ~= id and match.players[killerSrc] or nil
    return accused ~= nil and Arena.ModeUsesTeams(match.modeKey)
        and Arena.IsKey(accused.team) and accused.team == player.team
        and Config.Teams.friendlyFire ~= true
        and accused.leftArena ~= true and not Arena.IsEliminated(accused)
end

--- Why rosterKiller turns this claim down, or nil when it accepts it --
--- copied from server/match.lua, which this change does not touch. The KILL
--- NOT CREDITED line prints for three of these, and only when the TEAMKILL
--- line has not already spoken.
local function rosterRefusal(Arena, match, victim, killerSrc)
    local killerId = Arena.ToInt(killerSrc)
    if not killerId or killerId <= 0 then return 'nobody' end
    if killerId == victim.src then return 'self' end
    local killer = match.players[killerId]
    if not killer then return 'not_on_roster' end
    if not Arena.CanDamage(match.modeKey, killer.team, victim.team) then return 'team' end
    if killer.leftArena == true or Arena.IsEliminated(killer) then return 'out_of_round' end
    return nil
end

local LOGGED_REFUSAL = { not_on_roster = true, team = true, out_of_round = true }

--- A small deterministic generator, so the sweep neither reads nor moves
--- the global math.random stream the server itself draws from. The HIGH
--- bits are used: the low bit of this recurrence simply alternates, which
--- would pair every coin toss with the one before it.
local function generator(seed)
    local state = seed
    return function(n)
        state = (state * 1103515245 + 12345) % 2147483648
        return ((state // 65536) % n) + 1
    end
end

local MODES = { 'ffa', 'tdm', 'gungame', 'nosuchmode' }
local TEAMS = { { v = nil }, { v = '' }, { v = 'crimson' }, { v = 'ash' }, { v = 5 }, { v = false } }
local FRIENDLY = { true, false, 'yes', 1 }

--- Puts both rows into the state one case describes and reads the death.
--- @return table outcome
local function runCase(s, case)
    local match = s.live()
    local victim = match.players[case.victim]

    match.modeKey = case.mode
    s.config.Teams.friendlyFire = case.friendlyFire

    -- Every fighter back on their feet with lives to spare, so no case can
    -- eliminate anybody or be refused for a body that is already down.
    for src, row in pairs(match.players) do
        row.alive = true
        row.lives = 50
        row.leftArena = nil
        s.place(src, { x = CENTRE.x + src * 2.0, y = CENTRE.y, z = CENTRE.z })
    end
    victim.team = case.victimTeam

    local accused = type(case.killer) == 'number' and match.players[case.killer] or nil
    if accused and accused ~= victim then
        accused.team = case.accusedTeam
        if case.accusedLeft ~= nil then accused.leftArena = case.accusedLeft end
        if case.accusedOut then
            accused.alive = false
            accused.lives = 0
        elseif case.accusedDown then
            accused.alive = false
        end
        if case.far ~= false then s.place(case.killer, FAR) end
    end

    local expectTeamKill = case.killer ~= nil
        and oldTeamKill(s.Arena, s.config, match, case.victim, case.killer, victim)
    local refusal = rosterRefusal(s.Arena, match, victim, case.killer)
    local killsBefore = accused and (accused.kills or 0) or 0

    local from = #s.console
    local ok = s.match.OnDeath(case.victim, case.killer, nil, nil, 987654321)
    local said = s.since(from)

    return {
        ok = ok,
        expectTeamKill = expectTeamKill,
        refusal = refusal,
        credited = accused ~= nil and (accused.kills or 0) > killsBefore,
        teamKill = countOf(said, 'TEAMKILL:'),
        notCredited = countOf(said, 'KILL NOT CREDITED:'),
        said = said,
    }
end

local function describe(case)
    return ('mode=%s victim=%s(%s) killer=%s(%s) ff=%s left=%s out=%s down=%s far=%s'):format(
        tostring(case.mode), tostring(case.victim), tostring(case.victimTeam),
        tostring(case.killer), tostring(case.accusedTeam), tostring(case.friendlyFire),
        tostring(case.accusedLeft), tostring(case.accusedOut), tostring(case.accusedDown),
        tostring(case.far))
end

--- Checks one outcome against the reference and returns a failure line, or nil.
local function judge(case, outcome)
    if outcome.ok ~= true then return 'OnDeath refused the death: ' .. describe(case) end
    local wantTeamKill = (outcome.expectTeamKill and not outcome.credited) and 1 or 0
    if outcome.teamKill ~= wantTeamKill then
        return ('TEAMKILL %d, the old rule says %d: %s'):format(outcome.teamKill, wantTeamKill, describe(case))
    end
    local wantNotCredited = (LOGGED_REFUSAL[outcome.refusal] and wantTeamKill == 0) and 1 or 0
    if outcome.notCredited ~= wantNotCredited then
        return ('KILL NOT CREDITED %d, expected %d (refusal %s): %s'):format(
            outcome.notCredited, wantNotCredited, tostring(outcome.refusal), describe(case))
    end
    if outcome.credited and outcome.teamKill > 0 then
        return 'a credited kill was also announced as a team-kill: ' .. describe(case)
    end
    return nil
end

-- ======================================================================
-- THE DIFFERENTIAL: THE OLD RULE AGAINST THE REAL OnDeath
-- ======================================================================

t.test('576 deaths: every mode and an unknown one, six team values a side, four friendly-fire values', function()
    -- THE COMBINATIONS THE CHANGE HAS TO SURVIVE, all of them, through the
    -- real death path. Gun game is switched on and given sides, so all three
    -- shipped modes have something to say: ffa has no teams, tdm has them,
    -- gun game has them here, and 'nosuchmode' has no mode at all.
    --
    -- THE ACCUSED STANDS NINE KILOMETRES OFF, so every claim the roster
    -- accepts is still refused -- by the distance ceiling -- and every one
    -- of the 576 reaches the refused-claim branch the TEAMKILL line lives
    -- in. The accused's kill count is the proof: it must never move.
    local s = newServer(function(config)
        config.Modes.gungame.enabled = true
        config.Modes.gungame.teams = true
    end)
    s.play('tdm')

    local failures, cases, announced, credited = {}, 0, 0, 0
    for _, mode in ipairs(MODES) do
        for _, accusedTeam in ipairs(TEAMS) do
            for _, victimTeam in ipairs(TEAMS) do
                for _, friendlyFire in ipairs(FRIENDLY) do
                    local case = {
                        mode = mode, victim = 1, killer = 3,
                        accusedTeam = accusedTeam.v, victimTeam = victimTeam.v,
                        friendlyFire = friendlyFire,
                    }
                    local outcome = runCase(s, case)
                    cases = cases + 1
                    if outcome.teamKill > 0 then announced = announced + 1 end
                    if outcome.credited then credited = credited + 1 end
                    local failure = judge(case, outcome)
                    if failure then failures[#failures + 1] = failure end
                end
            end
        end
    end

    t.equals(cases, 576, 'the sweep did not cover the combinations it names')
    t.equals(credited, 0, 'a claim was CREDITED, so it never reached the branch under test')
    -- Both answers really occur, or the sweep compared two constants.
    -- Two same-side keys, two team modes, three friendly-fire values that
    -- are not `true`: 2 x 2 x 3 = 12.
    t.equals(announced, 12, 'the sweep did not produce the announcements the old rule makes')
    t.equals(#failures, 0, table.concat(failures, '\n'))
end)

t.test('and a seeded sweep over the clauses that did not move: who is named, left, eliminated, near or far', function()
    -- THE SELF-GUARD, THE ROSTER LOOKUP, leftArena AND ELIMINATION ARE KEPT
    -- EXACTLY, and this is what says so. Every value a killer id can take on
    -- the wire -- nil, nought, negative, the victim, a stranger, anybody on
    -- the roster -- crossed with the accused's state and the mode switches,
    -- 2,000 deaths from one fixed seed.
    local s = newServer(function(config)
        config.Modes.gungame.enabled = true
        config.Modes.gungame.teams = true
    end)
    s.play('tdm')

    local random = generator(20260925)
    -- WRAPPED, because a nil inside a table constructor leaves `#` free to
    -- answer either side of it, and the sweep would stop drawing it.
    local KILLERS = { { v = nil }, { v = 0 }, { v = -1 }, { v = 1 }, { v = 2 }, { v = 3 }, { v = 4 }, { v = 99 } }
    local FRIENDLY_WIDE = { { v = true }, { v = false }, { v = 'yes' }, { v = 1 }, { v = 0 }, { v = 'true' }, { v = nil } }
    local LEFT = { { v = nil }, { v = true }, { v = false }, { v = 'yes' } }
    local modes = s.config.Modes

    local failures, seen = {}, { teamKill = 0, notCredited = 0, credited = 0, quiet = 0 }
    for _ = 1, 2000 do
        local victim = random(4)
        -- HALF THE TIME ON A REAL SIDE, AND HALF THE TIME THE ACCUSED ON THE
        -- VICTIM'S OWN, whatever it is -- drawn independently the two would
        -- match one time in eighteen and the sweep would hardly ever reach
        -- the line it is about.
        local victimTeam = random(2) == 1 and TEAMS[2 + random(2)].v or TEAMS[random(#TEAMS)].v
        local accusedTeam = random(2) == 1 and victimTeam or TEAMS[random(#TEAMS)].v
        local case = {
            mode = MODES[random(#MODES)],
            victim = victim,
            killer = KILLERS[random(#KILLERS)].v,
            accusedTeam = accusedTeam,
            victimTeam = victimTeam,
            friendlyFire = FRIENDLY_WIDE[random(#FRIENDLY_WIDE)].v,
            accusedLeft = LEFT[random(#LEFT)].v,
            accusedOut = random(4) == 1,
            accusedDown = random(3) == 1,
            far = random(3) ~= 1,
        }

        -- THE MODE SWITCHES AS WELL, because both forms ask the mode
        -- through Arena.ModeUsesTeams -> GetModeByKey, which answers nil for
        -- a mode that is switched off.
        local tdmEnabled, tdmTeams = random(5) ~= 1, random(5) ~= 1
        local ggEnabled, ggTeams = random(2) == 1, random(2) == 1
        modes.tdm.enabled, modes.tdm.teams = tdmEnabled, tdmTeams
        modes.gungame.enabled, modes.gungame.teams = ggEnabled, ggTeams

        local outcome = runCase(s, case)
        local failure = judge(case, outcome)
        if failure then
            failures[#failures + 1] = failure .. (' tdm=%s/%s gungame=%s/%s'):format(
                tostring(tdmEnabled), tostring(tdmTeams), tostring(ggEnabled), tostring(ggTeams))
        end
        if outcome.teamKill > 0 then seen.teamKill = seen.teamKill + 1 end
        if outcome.notCredited > 0 then seen.notCredited = seen.notCredited + 1 end
        if outcome.credited then seen.credited = seen.credited + 1 end
        if outcome.teamKill == 0 and outcome.notCredited == 0 then seen.quiet = seen.quiet + 1 end
    end
    modes.tdm.enabled, modes.tdm.teams = true, true

    -- EVERY OUTCOME OCCURS, so the sweep is not quietly one-sided.
    t.isTrue(seen.teamKill > 0, 'the sweep never produced a TEAMKILL line')
    t.isTrue(seen.notCredited > 0, 'the sweep never produced a KILL NOT CREDITED line')
    t.isTrue(seen.credited > 0, 'the sweep never credited a kill')
    t.isTrue(seen.quiet > 0, 'the sweep never produced a death with neither line')
    t.equals(#failures, 0, table.concat(failures, '\n'))
end)

t.test('THE PREDICATES THEMSELVES: the old condition and not Arena.CanDamage agree everywhere', function()
    -- Wider than the death path can reach: every mode switched off, on,
    -- with and without sides, a nil and a false mode key, and garbage for
    -- every team and for the setting. The old form had no IsKey on the
    -- victim's side; `accused.team == player.team` with IsKey on the
    -- accused's makes it implied, and this is the check that it is.
    local env = Sandbox.newArenaEnv()
    local Arena, Config = env.Arena, env.Config
    local modeKeys = { 'ffa', 'tdm', 'gungame', 'nosuchmode', '', 'CRIMSON' }
    local teams = { { v = nil }, { v = '' }, { v = 'crimson' }, { v = 'ash' }, { v = 'CRIMSON' },
        { v = 5 }, { v = false }, { v = true }, { v = {} } }
    local friendly = { { v = nil }, { v = true }, { v = false }, { v = 'yes' }, { v = 1 }, { v = 0 }, { v = 'true' } }
    local switches = { { true, true }, { true, false }, { false, true }, { false, false }, { nil, nil } }

    local compared, differ, both = 0, {}, { [true] = 0, [false] = 0 }
    for _, switch in ipairs(switches) do
        for _, key in ipairs({ 'ffa', 'tdm', 'gungame' }) do
            Config.Modes[key].enabled, Config.Modes[key].teams = switch[1], switch[2]
        end
        for mi = 0, #modeKeys do
            local modeKey = modeKeys[mi]   -- index 0 is nil: no mode key at all
            for ai = 1, #teams do
                for vi = 1, #teams do
                    for fi = 1, #friendly do
                        local accusedTeam, victimTeam = teams[ai].v, teams[vi].v
                        Config.Teams.friendlyFire = friendly[fi].v
                        local old = Arena.ModeUsesTeams(modeKey) and Arena.IsKey(accusedTeam)
                            and accusedTeam == victimTeam and Config.Teams.friendlyFire ~= true
                        local new = not Arena.CanDamage(modeKey, accusedTeam, victimTeam)
                        compared = compared + 1
                        both[old and true or false] = both[old and true or false] + 1
                        if (old and true or false) ~= new then
                            differ[#differ + 1] = ('mode=%s a=%s v=%s ff=%s'):format(tostring(modeKey),
                                tostring(accusedTeam), tostring(victimTeam), tostring(Config.Teams.friendlyFire))
                        end
                    end
                end
            end
        end
    end

    t.isTrue(compared > 10000, 'the sweep was smaller than it claims')
    t.isTrue(both[true] > 0 and both[false] > 0, 'one answer never came up, so nothing was compared')
    t.equals(#differ, 0, 'the two forms disagree:\n' .. table.concat(differ, '\n'))
end)

-- ======================================================================
-- ONE RULE, ONE READER
-- ======================================================================

--- Blanks every string literal and every `--` comment out of one line of
--- code (long comments are already gone), so a name mentioned in a message
--- or a note is not read as a read of it.
local function codeOf(line)
    local out, i, quote = {}, 1, nil
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == '\\' then i = i + 1
            elseif c == quote then quote = nil end
            out[#out + 1] = ' '
        elseif c == '"' or c == "'" then
            quote = c
            out[#out + 1] = ' '
        elseif line:sub(i, i + 1) == '--' then
            break
        else
            out[#out + 1] = c
        end
        i = i + 1
    end
    return table.concat(out)
end

t.test('Config.Teams.friendlyFire is read in ONE place: inside Arena.CanDamage', function()
    -- THE GUARD THAT KEEPS THE ANSWER SINGLE, modelled on configeffect_spec's
    -- scan for boundary.enabled. The TEAMKILL line carried the last private
    -- copy of this rule; a new reader written by hand is how the next copy
    -- starts drifting, so every Lua file the manifest loads is read.
    local manifest = Sandbox.readDeclarations('../Crimson-Arena/fxmanifest.lua')
    local files, seenFile = {}, {}
    for _, realm in ipairs({ 'server', 'client' }) do
        for _, path in ipairs(Sandbox.realmScripts(manifest, realm)) do
            if path:find('%.lua$') and not seenFile[path] then
                seenFile[path] = true
                files[#files + 1] = path
            end
        end
    end
    t.isTrue(seenFile['server/match.lua'] and seenFile['shared/arena.lua'] and seenFile['config.lua'],
        'the manifest did not list the files this scan is about')

    local offenders, legal = {}, 0
    for _, path in ipairs(files) do
        local handle = assert(io.open('../Crimson-Arena/' .. path, 'r'), path .. ' is missing')
        local text = Sandbox.blankLongComments(handle:read('a'))
        handle:close()

        local inCanDamage, number = false, 0
        for line in (text .. '\n'):gmatch('([^\n]*)\n') do
            number = number + 1
            if line:find('^function Arena%.CanDamage%(') then inCanDamage = true end
            local code = codeOf(line)
            if code:find('friendlyFire', 1, true) then
                local definition = path == 'config.lua' and code:find('^%s*friendlyFire%s*=')
                if inCanDamage and path == 'shared/arena.lua' then
                    legal = legal + 1
                elseif not definition then
                    offenders[#offenders + 1] = ('%s:%d  %s'):format(path, number, (line:gsub('^%s+', '')))
                end
            end
            if inCanDamage and line:find('^end') then inCanDamage = false end
        end
    end

    t.equals(legal, 1, 'Arena.CanDamage no longer reads the setting, so this scan proves nothing')
    t.equals(#offenders, 0, 'Config.Teams.friendlyFire is read outside Arena.CanDamage:\n  '
        .. table.concat(offenders, '\n  '))
end)

t.test('THE LINE FOLLOWS THE RULE: a mode whose rule lets team-mates hurt each other is not accused', function()
    -- THE GAIN, AS A BEHAVIOUR. The day friendly fire becomes a per-mode
    -- choice it is Arena.CanDamage that changes, and every reader follows
    -- it. Here that day is simulated: CanDamage answers "allowed" for tdm.
    -- rosterKiller accepts the team-mate; the distance ceiling refuses the
    -- claim; and the TEAMKILL line -- "Friendly fire is off, so the kill
    -- was credited to nobody" -- must not print, because friendly fire is
    -- not off in this mode. The hand-written copy printed it.
    local s = newServer()
    local match = s.play('tdm')
    t.equals(match.players[1].team, match.players[3].team, '1 and 3 are not on one side')

    local real = s.Arena.CanDamage
    s.Arena.CanDamage = function(modeKey, attackerTeam, victimTeam)
        if modeKey == 'tdm' then return true end
        return real(modeKey, attackerTeam, victimTeam)
    end

    s.place(3, FAR)
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    local said = s.since(from)
    s.Arena.CanDamage = real

    t.equals(match.players[3].kills or 0, 0, 'the distance ceiling did not refuse the claim, so this proves nothing')
    t.isNil(said:find('TEAMKILL', 1, true),
        'the TEAMKILL line kept its own copy of the rule and accused a team-mate the rule allows')
end)

t.test('and CONTROL: the same death with the rule refusing IS announced, through the same override', function()
    -- The override is not what silences the line: route the same death
    -- through the real rule and it speaks.
    local s = newServer()
    local match = s.play('tdm')
    local calls = 0
    local real = s.Arena.CanDamage
    s.Arena.CanDamage = function(...)
        calls = calls + 1
        return real(...)
    end

    s.place(3, FAR)
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    local said = s.since(from)
    s.Arena.CanDamage = real

    t.isTrue(calls > 0, 'the override was never consulted, so this proves nothing')
    t.contains(said, 'TEAMKILL:', 'a team-mate kill with friendly fire off was not announced')
    t.equals(match.players[3].kills or 0, 0, 'the team-mate kill was credited')
end)

t.test('every question put to Arena.CanDamage on a death names the ACCUSED first and the VICTIM second', function()
    -- CanDamage reads (attacker, victim), and today it is symmetric -- so a
    -- call with the two sides swapped gives the same answer and nothing
    -- else in this file would notice. A rule that stops being symmetric
    -- would. Two different sides make the order visible.
    --
    -- AN ENEMY, far away: the roster accepts them, the distance ceiling
    -- refuses the claim, and the death reaches the TEAMKILL branch with the
    -- accused on ash and the victim on crimson.
    local s = newServer()
    local match = s.play('tdm')
    t.equals(match.players[2].team, 'ash', 'the accused is not on ash')
    t.equals(match.players[1].team, 'crimson', 'the victim is not on crimson')

    local calls = {}
    local real = s.Arena.CanDamage
    s.Arena.CanDamage = function(modeKey, attackerTeam, victimTeam)
        calls[#calls + 1] = ('%s:%s>%s'):format(tostring(modeKey), tostring(attackerTeam), tostring(victimTeam))
        return real(modeKey, attackerTeam, victimTeam)
    end
    s.place(2, FAR)
    s.match.OnDeath(1, 2, nil, nil, 987654321)
    s.Arena.CanDamage = real

    t.equals(match.players[2].kills or 0, 0, 'the claim was credited, so it never reached the branch')
    t.isTrue(#calls >= 1, 'the rule was never asked about this death')
    for _, call in ipairs(calls) do
        t.equals(call, 'tdm:ash>crimson', 'the rule was asked the question the wrong way round')
    end
end)

-- ======================================================================
-- THE PINS: WHAT THE LINE MUST STILL DO, ONE CASE APIECE
-- ======================================================================

t.test('PIN: in TEAM DEATHMATCH a team-mate\'s refused claim is announced, naming the cause', function()
    -- gungame_spec pins this on a ladder with sides switched on; tdm is the
    -- mode that ships with sides, and is where a server actually meets it.
    local s = newServer()
    local match = s.play('tdm')
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 424242)
    local said = s.since(from)

    t.equals(countOf(said, 'TEAMKILL:'), 1, 'the team-mate kill was not announced exactly once')
    t.contains(said, 'cause hash 424242', 'the cause was not named')
    t.isNil(said:find('KILL NOT CREDITED', 1, true), 'the TEAMKILL line was contradicted by a second line')
    t.equals(match.players[3].kills or 0, 0, 'the team-mate kill was credited')
end)

t.test('PIN: a team-mate who was SENT HOME is not announced -- the claim is logged as refused instead', function()
    -- gungame_spec pins the eliminated team-mate. leftArena is the other
    -- half of "out of the round", and rosterKiller refuses this claim on
    -- the TEAM ground before it ever asks about leftArena -- which is why
    -- the line cannot be read off rosterKiller's reason.
    local s = newServer()
    local match = s.play('tdm')
    match.players[3].leftArena = true
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    local said = s.since(from)

    t.isNil(said:find('TEAMKILL', 1, true), 'a team-mate who had gone home was announced as a team-killer')
    t.equals(countOf(said, 'KILL NOT CREDITED:'), 1, 'the refused claim went unreported')
end)

t.test('PIN: an ELIMINATED team-mate is not announced either -- both fields, as IsEliminated reads them', function()
    local s = newServer()
    local match = s.play('tdm')
    match.players[3].alive = false
    match.players[3].lives = 0
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    local said = s.since(from)

    t.isNil(said:find('TEAMKILL', 1, true), 'an eliminated team-mate was announced as a team-killer')
    t.equals(countOf(said, 'KILL NOT CREDITED:'), 1, 'the refused claim went unreported')
end)

t.test('PIN: a team-mate who is DOWN but not out IS announced', function()
    -- Dead-but-respawning is still in the round: two team-mates can trade in
    -- one tick. Only elimination silences the line.
    local s = newServer()
    local match = s.play('tdm')
    match.players[3].alive = false
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    t.contains(s.since(from), 'TEAMKILL:', 'a team-mate waiting out a respawn was not announced')
end)

t.test('PIN: friendly fire written as a truthy NON-true value is OFF, and the team-kill is announced', function()
    -- `friendlyFire = 'yes'` or `= 1` is not `true`, so the shot is refused
    -- (crossfire) and the kill is refused (rosterKiller) -- and the line has
    -- always said so. Both forms read the setting with `== true`.
    for _, value in ipairs({ 'yes', 1 }) do
        local s = newServer(function(config) config.Teams.friendlyFire = value end)
        s.play('tdm')
        local from = #s.console
        s.match.OnDeath(1, 3, nil, nil, 987654321)
        t.contains(s.since(from), 'TEAMKILL:', 'friendlyFire = ' .. tostring(value) .. ' read as ON')
    end
end)

t.test('PIN: a mode switched OFF mid-round has no sides to betray', function()
    -- GetModeByKey answers nil for a disabled mode, so ModeUsesTeams says no
    -- and so does CanDamage: the claim is refused for distance only, and
    -- nothing is announced.
    local s = newServer()
    local match = s.play('tdm')
    s.config.Modes.tdm.enabled = false
    s.place(3, FAR)
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    local said = s.since(from)
    s.config.Modes.tdm.enabled = true

    t.equals(match.players[3].kills or 0, 0, 'the claim was credited, so this proves nothing')
    t.isNil(said:find('TEAMKILL', 1, true), 'a mode with no sides produced a team-kill')
end)

t.test('PIN: FREE-FOR-ALL announces nothing, whatever the rows say about sides', function()
    local s = newServer()
    local match = s.play('ffa')
    match.players[1].team = 'crimson'
    match.players[3].team = 'crimson'
    s.place(3, FAR)
    local from = #s.console
    s.match.OnDeath(1, 3, nil, nil, 987654321)
    t.isNil(s.since(from):find('TEAMKILL', 1, true), 'a free-for-all claim was announced as a team-kill')
end)

t.test('PIN: nobody, nought, a stranger and the victim themselves are never the accused', function()
    local s = newServer()
    local match = s.play('tdm')
    for _, killer in ipairs({ false, 0, -1, 99, 1 }) do
        match.players[1].alive, match.players[1].lives = true, 3
        local from = #s.console
        s.match.OnDeath(1, killer ~= false and killer or nil, nil, nil, 987654321)
        t.isNil(s.since(from):find('TEAMKILL', 1, true),
            'a claim naming ' .. tostring(killer) .. ' was announced as a team-kill')
    end
end)

os.exit(t.summary())
