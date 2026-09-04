--[[
    crimson_arena/tests/configeffect_spec.lua

    EVERY SETTING AN OPERATOR EDITS ACTUALLY CHANGES SOMETHING.

    config.lua is the whole interface this resource has. An operator's entire
    experience of it is: change a value, restart, see the difference. So the
    worst defect it can have is not a crash -- it is a setting that reads as
    supported, is documented in as many words, and does nothing.

    THIS HAS ALREADY HAPPENED HERE, more than once:

        `grantSelfPermission` had a page of config explaining when to switch
        it on, a stated default that disagreed with its own value, and not
        one line of code reading it. Anyone who followed that page got
        exactly the silence the setting existed to cure.

        `scatterRadius` was computed by the server, sent on the respawn
        payload, and thrown away on arrival -- the client read config
        instead. Changing the sent value did nothing at all.

    Neither was found by reading. A dead setting looks exactly like a live
    one from the outside, which is the entire problem, so this file asks the
    only question that separates them: CHANGE IT, AND SEE IF ANYTHING MOVES.

    HOW IT ASKS. Differential, not expectation-based. Each case runs the same
    scenario twice -- once on the shipped config, once with one value changed
    -- and requires the observable output to differ. It deliberately does not
    assert WHAT the output should be: that would be a second copy of the
    implementation, written by the same hand, agreeing with it for the same
    wrong reasons. "Something downstream noticed" is the weaker claim and the
    honest one, and it is exactly the claim a dead setting fails.

    WHERE IT LOOKS. Two places, because between them they are nearly
    everything an operator touches:

        THE SNAPSHOT -- ArenaLobby.BuildState, the single payload the whole
        panel is drawn from. Weapons, teams, modes, arenas, betting bands,
        slot limits, colours, the radar rule.

        THE WIRE -- what a client is actually sent when a round starts:
        spawn, boundary, size factor, lives, freeze.

    A setting whose effect is somewhere else entirely gets its own case at
    the bottom rather than being left out.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('configeffect_spec')

-- ======================================================================
-- ONE SERVER, BUILT TWICE
-- ======================================================================

--- A real server over the real config, with one value changed.
--- @param mutate fun(config: table)? -- applied BEFORE the files that read config at load
--- @return table server
local function newArena(mutate)
    local players = {}
    for id = 1, 4 do
        players[id] = {
            citizenid = ('CID%03d'):format(id),
            name = ('Fighter %d'):format(id),
            money = { cash = 100000, bank = 100000 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local sent, netEvents = {}, {}
    local clock = 0

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
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        -- Past every rate bucket on every call: a throttled event is
        -- indistinguishable from a refused one, and this file reads refusals.
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src)
            local record = qbx.players[src]
            return record and record.name or ''
        end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,

        ArenaStats = {
            GetLeaderboard = function(callback) callback({}) end,
            EnsureSchema = function() end,
            RecordMatch = function() end,
            Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            ClearDownState = function() return 0 end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() return 1 end, ReleaseBucket = function() end,
        },
    })

    -- BEFORE the loads: server/lobby.lua reads some of config once, at load.
    if mutate then mutate(env.Config) end

    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/betting.lua', env)
    Sandbox.loadInto('../server/lobby.lua', env)
    Sandbox.loadInto('../server/match.lua', env)
    Sandbox.loadInto('../server/main.lua', env)

    local server = { env = env, config = env.Config, Arena = env.Arena }

    function server.snapshot(src) return env.ArenaLobby.BuildState(src or 1) end

    --- One client -> server event, exactly as a client sends it.
    function server.fire(event, src, payload)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no server handler for ' .. event) end
        env.source = src
        local previous = rawget(env, 'source')
        env.source = src
        handler(payload)
        env.source = previous
    end

    --- Everything one client was sent, in order.
    function server.sentTo(target, event)
        local out = {}
        for _, message in ipairs(sent) do
            if message.target == target and (event == nil or message.event == event) then
                out[#out + 1] = message.payload
            end
        end
        return out
    end

    server.step = threads.step
    return server
end

-- ======================================================================
-- COMPARING TWO RUNS
-- ======================================================================

--- A stable, total rendering of any value, so two runs can be compared.
--- Sorted by key, so `pairs` order cannot make two identical snapshots look
--- different and fake a pass.
--- @param value any
--- @return string
local function render(value)
    if type(value) ~= 'table' then
        if type(value) == 'number' then return ('%.6f'):format(value) end
        return type(value) .. '(' .. tostring(value) .. ')'
    end

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        return tostring(a) .. type(a) < tostring(b) .. type(b)
    end)

    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key) .. '=' .. render(value[key])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

--- The core assertion. Runs `observe` against the shipped config and against
--- a config with one thing changed, and requires the two to differ.
--- @param label string -- the setting, as an operator would write it
--- @param mutate fun(config: table)
--- @param observe fun(server: table): any
local function changing(label, mutate, observe)
    -- THE MUTATION HAS TO BITE FIRST. A differential test whose "change"
    -- quietly changes nothing reports a dead setting for every setting, and
    -- the failure reads identically -- so the config itself is compared
    -- before anything downstream is. Disabling a weapon that was already
    -- disabled is exactly the shape of mistake this catches, and it is the
    -- first one this file made.
    local plain = newArena()
    local changed = newArena(mutate)
    t.isTrue(render(plain.config) ~= render(changed.config),
        ('the test for %s does not actually change the config'):format(label))

    t.isTrue(render(observe(plain)) ~= render(observe(changed)),
        ('%s changes NOTHING an operator can see -- it is a dead setting'):format(label))
end

-- ======================================================================
-- THE PANEL IS DRAWN FROM THE SNAPSHOT
-- ======================================================================

t.test('the settings the panel is built from all reach it', function()
    local cases = {
        {
            'Config.UI.title',
            function(c) c.UI.title = 'A Different Name Entirely' end,
        },
        {
            'Config.UI.logoStyle',
            function(c) c.UI.logoStyle = (c.UI.logoStyle == 'banner') and 'badge' or 'banner' end,
        },
        {
            'Config.Loadouts.slots',
            function(c) c.Loadouts.slots = 5 end,
        },
        {
            'Config.Loadouts.allowFirearms',
            function(c) c.Loadouts.allowFirearms = false end,
        },
        {
            'Config.Loadouts.allowMelee',
            function(c) c.Loadouts.allowMelee = false end,
        },
        {
            'Config.Loadouts.ammoTypeSlots',
            function(c) c.Loadouts.ammoTypeSlots = 6 end,
        },
        {
            'disabling a weapon',
            function(c)
                for _, weapon in pairs(c.Loadouts.weapons) do
                    if weapon.enabled ~= false then
                        weapon.enabled = false
                        break
                    end
                end
            end,
        },
        {
            'Config.Betting.enabled',
            function(c) c.Betting.enabled = not c.Betting.enabled end,
        },
        {
            'Config.Match.lives.default',
            function(c) c.Match.lives.default = (c.Match.lives.default or 1) + 4 end,
        },
        {
            'Config.Match.lives.allowChoose',
            function(c) c.Match.lives.allowChoose = not c.Match.lives.allowChoose end,
        },
        {
            'Config.Match.lives.max',
            function(c) c.Match.lives.max = (c.Match.lives.max or 10) + 5 end,
        },
        {
            'Config.Match.maxPlayers',
            function(c) c.Match.maxPlayers = 3 end,
        },
        {
            'disabling an arena',
            function(c)
                for _, arena in pairs(c.Arenas) do
                    if arena.enabled ~= false then
                        arena.enabled = false
                        break
                    end
                end
            end,
        },
        {
            'disabling a mode',
            function(c)
                for _, mode in pairs(c.Modes) do
                    if mode.enabled ~= false then
                        mode.enabled = false
                        break
                    end
                end
            end,
        },
        {
            'disabling a team',
            function(c)
                for _, team in pairs(c.Teams.list) do
                    if team.enabled ~= false then
                        team.enabled = false
                        break
                    end
                end
            end,
        },
        {
            'Config.Teams.allowUnequal',
            function(c) c.Teams.allowUnequal = not c.Teams.allowUnequal end,
        },
        {
            'Config.DefaultMode',
            function(c)
                for key, mode in pairs(c.Modes) do
                    if mode.enabled ~= false and key ~= c.DefaultMode then
                        c.DefaultMode = key
                        break
                    end
                end
            end,
        },
    }

    for _, case in ipairs(cases) do
        changing(case[1], case[2], function(server) return server.snapshot(1) end)
    end
end)

-- ======================================================================
-- WHAT A CLIENT IS ACTUALLY SENT WHEN A ROUND STARTS
--
-- The snapshot is what the panel draws. This is what the game is told: the
-- spawn, the boundary, how big the arena is for this roster, how long the
-- opening freeze lasts. A setting that reaches the panel and not the wire is
-- a setting that looks right in the menu and does nothing in the round.
-- ======================================================================

--- Opens a two-player match on `arenaKey`, starts it, and hands back what
--- the host's client was told.
--- @param server table
--- @param arenaKey string?
--- @return table payload
local function entryPayload(server, arenaKey)
    local matchId = assert(server.env.ArenaLobby.Create(1, arenaKey or 'skydome', 'ffa', 0, nil, false, nil),
        'the match could not be created at all')
    assert(server.env.ArenaLobby.Join(2, matchId, nil, nil))
    assert(server.env.ArenaMatch.Start(matchId))
    server.step()

    local sent = server.sentTo(1, 'crimson_arena:client:enterArena')
    return assert(sent[#sent], 'the host was never told to enter the arena')
end

t.test('the settings that decide a round reach the client that plays it', function()
    local cases = {
        {
            "an arena's spawn area",
            -- The sandbox's vector3, not a global: the mutator runs in this
            -- file, which is not inside the sandboxed env.
            function(c) c.Arenas.skydome.spawnArea.center = Sandbox.vector3(2500.0, 4000.0, 1201.0) end,
        },
        {
            "an arena's boundary radius",
            function(c) c.Arenas.skydome.boundary.radius = 123.0 end,
        },
        {
            "an arena's boundary damage",
            function(c) c.Arenas.skydome.boundary.damagePerTick = 77 end,
        },
        {
            "an arena's boundary warning",
            function(c) c.Arenas.skydome.boundary.warningSeconds = 17 end,
        },
        {
            'Config.Arenas.skydome.scale.perPlayer',
            function(c) c.Arenas.skydome.scale.perPlayer = 12.0 end,
        },
        {
            'Config.Arenas.skydome.scale.enabled',
            function(c) c.Arenas.skydome.scale.enabled = false end,
        },
        {
            "an arena's weather override",
            function(c) c.Arenas.skydome.weatherOverride = 'THUNDER' end,
        },
        {
            "an arena's time override",
            function(c) c.Arenas.skydome.timeOverride = { hour = 3, minute = 30 } end,
        },
        {
            'Config.Match.startCountdownSeconds',
            function(c) c.Match.startCountdownSeconds = (c.Match.startCountdownSeconds or 0) + 9 end,
        },
        {
            'Config.Match.lives.default',
            function(c) c.Match.lives.default = (c.Match.lives.default or 1) + 4 end,
        },
    }

    for _, case in ipairs(cases) do
        changing(case[1], case[2], function(server) return entryPayload(server) end)
    end
end)

t.test('and the scatter radius reaches an arena that uses its point list', function()
    -- SEPARATE, because on an arena with a spawn AREA the server deliberately
    -- sends no scatter -- the plan already spread the roster and scattering
    -- again undoes it. The setting is not dead there, it is overridden, and
    -- the arena it still governs is the one with an exact spawn list.
    local function pointListArena(config)
        config.Arenas.skydome.spawnArea.enabled = false
    end

    local before = render(entryPayload(newArena(pointListArena)))
    local after = render(entryPayload(newArena(function(config)
        pointListArena(config)
        config.Match.spawnScatterRadius = 25.0
    end)))

    t.isTrue(before ~= after,
        'Config.Match.spawnScatterRadius changes nothing even on an arena that uses its point list')
end)

-- ======================================================================
-- SETTINGS WHOSE EFFECT IS SOMEWHERE ELSE ENTIRELY
--
-- A handful do not show up in either payload, and each gets its own case
-- rather than being quietly left out -- "not covered" and "does nothing" look
-- identical in a list of passes.
-- ======================================================================

t.test('a player limit really refuses the player past it', function()
    -- maxPlayers is not a number in a snapshot, it is a door. The only proof
    -- is somebody being turned away.
    local server = newArena(function(config) config.Match.maxPlayers = 2 end)

    local matchId = assert(server.env.ArenaLobby.Create(1, 'skydome', 'ffa', 0, nil, false, nil))
    t.isTrue(server.env.ArenaLobby.Join(2, matchId, nil, nil) ~= false,
        'the second player could not join a two-player match')

    local ok, reason = server.env.ArenaLobby.Join(3, matchId, nil, nil)
    t.isFalse(ok, 'a third player joined a match limited to two')
    t.isTrue(reason ~= nil, 'the refusal came back without a reason to show the player')
end)

t.test('and raising it lets them in', function()
    -- The other half. A limit that refuses everybody is not a working limit
    -- either.
    local server = newArena(function(config) config.Match.maxPlayers = 4 end)

    local matchId = assert(server.env.ArenaLobby.Create(1, 'skydome', 'ffa', 0, nil, false, nil))
    for src = 2, 4 do
        local ok = server.env.ArenaLobby.Join(src, matchId, nil, nil)
        t.isTrue(ok ~= false, ('player %d was refused by a limit of four'):format(src))
    end
end)

t.test('an entry fee really leaves the account', function()
    -- Money is the one thing no snapshot can prove: the number in the panel
    -- is what will be charged, not what was.
    local server = newArena(function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.default = 2500
        config.Betting.entryFee.min = 0
        config.Betting.entryFee.max = 10000
    end)

    local before = server.env.exports.qbx_core:GetPlayer(1).PlayerData.money.cash
    assert(server.env.ArenaLobby.Create(1, 'skydome', 'ffa', 2500, nil, false, 'cash'))
    local after = server.env.exports.qbx_core:GetPlayer(1).PlayerData.money.cash

    t.equals(before - after, 2500,
        'the entry fee in config is not the amount that left the account')
end)

t.test('and a fee outside the operator band is refused rather than clamped', function()
    -- Clamping would charge somebody a number they never agreed to. The band
    -- is a rule, not a suggestion, and that is only observable by being told
    -- no.
    local server = newArena(function(config)
        config.Betting.enabled = true
        config.Betting.entryFee.min = 100
        config.Betting.entryFee.max = 500
    end)

    local matchId, reason = server.env.ArenaLobby.Create(1, 'skydome', 'ffa', 50000, nil, false, 'cash')
    t.isNil(matchId, 'a fee far outside the operator band was accepted')
    t.isTrue(reason ~= nil, 'it was refused without a reason')
end)

-- ======================================================================
-- THE ONE MISTAKE CONFIG MAKES EASY, NAMED AT START
--
-- An arena that carries its own floor states its height several times over:
-- the platform, the spawn area, the spawn list, each team list and the
-- boundary. Moving it means changing all of them, and missing one is not a
-- near miss -- a spawn below the floor is a fighter placed under the arena
-- and a spawn far above it is a fall when the countdown ends. Neither says
-- anything at the time.
-- ======================================================================

--- @param mutate fun(config: table)?
--- @return string -- every config warning, joined
local function validate(mutate)
    local env = Sandbox.newArenaEnv()
    if mutate then mutate(env.Config) end

    -- ValidateConfig RETURNS the problems; a separate reporter is what puts
    -- them on the console. Reading the return value tests the check itself
    -- rather than the printing around it.
    local problems = env.Arena.ValidateConfig()
    return table.concat(problems or {}, '\n')
end

-- ======================================================================
-- THE CATALOGUE LIVES IN ANOTHER FILE NOW
--
-- Splitting the weapon list out of config.lua introduced a failure nobody
-- had before: a server updated by copying only the files it already had
-- gets a config.lua that builds Config.Loadouts and NOTHING that ever
-- writes the catalogue into it. Arena.GetEnabledWeapons reads
-- `Config.Loadouts.weapons or {}`, so that is silent -- the only symptom
-- is the panel saying no weapons are enabled.
--
-- The console line has to name config.weapons.lua, because the operator's
-- next move is to open a file and the wrong name sends them to the one
-- where the list is no longer supposed to be.
-- ======================================================================

t.test('a MISSING catalogue names config.weapons.lua, not config.lua', function()
    local output = validate(function(config) config.Loadouts.weapons = nil end)

    t.contains(output, 'config.weapons.lua',
        'the operator is not told which file the catalogue is in')
    t.contains(output, 'shared_scripts',
        'the operator is not told the file has to be in the manifest')
end)

t.test('and so does a catalogue that is present but EMPTY', function()
    local output = validate(function(config) config.Loadouts.weapons = {} end)

    t.contains(output, 'config.weapons.lua',
        'an empty catalogue is the same fault as a missing one and needs the same answer')
end)

t.test('but a catalogue that is THERE with everything switched off is a different message', function()
    -- A different decision, in a different place, and the operator does not
    -- need to be told to go and find the file -- they are already in it.
    local output = validate(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do weapon.enabled = false end
    end)

    t.contains(output, 'not one of them is enabled',
        'switching every weapon off is reported as a missing file')
    t.isNil(output:find('is empty or missing', 1, true),
        'a populated catalogue was reported as missing')
end)

t.test('and the shipped config trips neither', function()
    local output = validate()

    t.isNil(output:find('config.weapons.lua', 1, true),
        ('the shipped catalogue does not load:\n%s'):format(output))
    t.isNil(output:find('not one of them is enabled', 1, true),
        'the shipped catalogue has nothing enabled in it')
end)

t.test('the shipped config passes its own validation without this warning', function()
    -- The shipped sky arena states 1201 in five places and they agree. If
    -- this ever fails, the arena itself is misconfigured -- which is the
    -- whole point of the check.
    local output = validate()
    t.isNil(output:find('platform surface', 1, true),
        ('the shipped config disagrees with itself about the arena height:\n%s'):format(output))
end)

t.test('a spawn BELOW the platform surface is named, with both numbers', function()
    local output = validate(function(config)
        config.Arenas.skydome.spawns[1] = { x = 1500.0, y = 3000.0, z = 1100.0, w = 0.0 }
    end)

    t.contains(output, 'spawns[1].z', 'the offending spawn was not named')
    t.contains(output, 'under the arena', 'the consequence was not spelled out')
    t.contains(output, '1100.00', 'the wrong value was not quoted back')
    t.contains(output, '1201.00', 'the surface it should match was not quoted')
end)

t.test('and so is a spawn far ABOVE it, because that is a fall', function()
    local output = validate(function(config)
        config.Arenas.skydome.spawns[2] = { x = 1500.0, y = 3000.0, z = 1900.0, w = 0.0 }
    end)

    t.contains(output, 'spawns[2].z')
    t.contains(output, 'fall when the countdown ends')
end)

t.test('and a team list, and the spawn area, and the boundary', function()
    -- All five places, because the one an operator forgets is the one no
    -- test covers.
    local team = validate(function(config)
        config.Arenas.skydome.teamSpawns.crimson[1] = { x = 1500.0, y = 3000.0, z = 900.0, w = 0.0 }
    end)
    t.contains(team, 'teamSpawns.crimson[1].z')

    local area = validate(function(config)
        config.Arenas.skydome.spawnArea.center = Sandbox.vector3(1500.0, 3000.0, 800.0)
    end)
    t.contains(area, 'spawnArea.center.z')

    local boundary = validate(function(config)
        config.Arenas.skydome.boundary.center = Sandbox.vector3(1500.0, 3000.0, 700.0)
    end)
    t.contains(boundary, 'boundary.center.z')
end)

t.test('and moving the platform alone is enough to flag every one of them', function()
    -- The realistic mistake, and the reason this is worth a check rather
    -- than a comment: an operator changes the ONE number they were looking
    -- at and the other five are silently left behind.
    local output = validate(function(config)
        config.Arenas.skydome.platform.z = 400.0
    end)

    for _, expected in ipairs({ 'spawnArea.center.z', 'spawns[1].z', 'teamSpawns', 'boundary.center.z' }) do
        t.contains(output, expected,
            ('moving the platform did not flag %s'):format(expected))
    end
end)

t.test('and an arena on the ground is never asked about a surface it does not have', function()
    -- The trailer park has no platform. Complaining that its spawns are not
    -- at a height it never claimed would be noise, and noise in a startup
    -- report is how the real lines stop being read.
    local output = validate()
    t.isNil(output:find('trailerpark', 1, true),
        ('an arena with no platform was warned about its heights:\n%s'):format(output))
end)

-- ======================================================================
-- AND A TYPO MUST NOT TAKE THE SERVER DOWN
--
-- The other half of "editing the config works". A setting that does nothing
-- is the quiet failure; a setting that throws is the loud one, and it is
-- worse -- an operator who mistypes a number should get a warning and a
-- running arena, not a resource that fails to start and a server with a hole
-- in it.
--
-- config.lua is edited by hand, in a text editor, by somebody who is not a
-- programmer. Every value in it will eventually be a string, a nil, a
-- negative, or a table where a number belongs.
-- ======================================================================

--- The settings an operator actually edits, as setters.
local SETTERS = {
    { 'Match.lives.default', function(c, v) c.Match.lives.default = v end },
    { 'Match.lives.min', function(c, v) c.Match.lives.min = v end },
    { 'Match.lives.max', function(c, v) c.Match.lives.max = v end },
    { 'Match.maxPlayers', function(c, v) c.Match.maxPlayers = v end },
    { 'Match.minPlayers', function(c, v) c.Match.minPlayers = v end },
    { 'Match.spawnScatterRadius', function(c, v) c.Match.spawnScatterRadius = v end },
    { 'Match.spawnHeightOffset', function(c, v) c.Match.spawnHeightOffset = v end },
    { 'Match.startCountdownSeconds', function(c, v) c.Match.startCountdownSeconds = v end },
    { 'Match.respawnDelaySeconds', function(c, v) c.Match.respawnDelaySeconds = v end },
    { 'Loadouts.slots', function(c, v) c.Loadouts.slots = v end },
    { 'Loadouts.allowFirearms', function(c, v) c.Loadouts.allowFirearms = v end },
    { 'Loadouts.allowMelee', function(c, v) c.Loadouts.allowMelee = v end },
    { 'Loadouts.ammoTypeSlots', function(c, v) c.Loadouts.ammoTypeSlots = v end },
    { 'Betting.entryFee.min', function(c, v) c.Betting.entryFee.min = v end },
    { 'Betting.entryFee.max', function(c, v) c.Betting.entryFee.max = v end },
    { 'Betting.entryFee.default', function(c, v) c.Betting.entryFee.default = v end },
    { 'Betting.enabled', function(c, v) c.Betting.enabled = v end },
    { 'Teams.allowUnequal', function(c, v) c.Teams.allowUnequal = v end },
    { 'Teams.maxTeamSizeDifference', function(c, v) c.Teams.maxTeamSizeDifference = v end },
    { 'DefaultMode', function(c, v) c.DefaultMode = v end },
    { 'skydome.platform.z', function(c, v) c.Arenas.skydome.platform.z = v end },
    { 'skydome.platform.radius', function(c, v) c.Arenas.skydome.platform.radius = v end },
    { 'skydome.platform.tileSize', function(c, v) c.Arenas.skydome.platform.tileSize = v end },
    { 'skydome.platform.maxTiles', function(c, v) c.Arenas.skydome.platform.maxTiles = v end },
    { 'skydome.spawnArea.radius', function(c, v) c.Arenas.skydome.spawnArea.radius = v end },
    { 'skydome.spawnArea.minSeparation', function(c, v) c.Arenas.skydome.spawnArea.minSeparation = v end },
    { 'skydome.spawnArea.teamRadius', function(c, v) c.Arenas.skydome.spawnArea.teamRadius = v end },
    { 'skydome.boundary.radius', function(c, v) c.Arenas.skydome.boundary.radius = v end },
    { 'skydome.scale.baseline', function(c, v) c.Arenas.skydome.scale.baseline = v end },
    { 'skydome.scale.perPlayer', function(c, v) c.Arenas.skydome.scale.perPlayer = v end },
    { 'skydome.scale.maxGrowth', function(c, v) c.Arenas.skydome.scale.maxGrowth = v end },
    { 'skydome.cover.clearance', function(c, v) c.Arenas.skydome.cover.clearance = v end },
    { 'UI.title', function(c, v) c.UI.title = v end },
    { 'Lobby.interaction', function(c, v) c.Lobby.interaction = v end },
}

--- Everything a hand-edited file eventually contains.
local JUNK = {
    nil, false, true, 0, -1, -99999, 0.5, 1e15, 0/0, 1/0, -1/0,
    '', ' ', 'yes', '10', 'NaN', {}, { 1, 2 }, { x = 1 },
}

t.test('FUZZ: no junk value in any operator setting throws', function()
    -- Not "is handled correctly" -- that is what the differential half above
    -- is for. Just that the resource still starts, still builds a panel, and
    -- still answers a request. A warning and a running arena beats a stack
    -- trace and a dead resource every time.
    local broke = nil

    for _, setter in ipairs(SETTERS) do
        local name, apply = setter[1], setter[2]
        -- `#JUNK` stops at the nil, so walk the whole range explicitly.
        for index = 1, 19 do
            local value = JUNK[index]

            local ok, err = pcall(function()
                local server = newArena(function(config) apply(config, value) end)

                -- Three things every start does, in order.
                server.Arena.ValidateConfig()
                server.snapshot(1)

                -- And the one thing a player does first. Refusing is fine;
                -- throwing is not.
                server.env.ArenaLobby.Create(1, 'skydome', 'ffa', 0, nil, false, nil)
            end)

            if not ok and not broke then
                broke = ('%s = %s (%s) threw: %s')
                    :format(name, tostring(value), type(value), tostring(err))
            end
        end
    end

    t.isNil(broke, broke or '')
end)

t.test('DEFECT: a floor smaller than its spawn ring is named at start', function()
    -- FOUND BY FUZZING JUNK INTO THE RADIUS, and it is the one geometry
    -- mistake that builds SUCCESSFULLY and is still fatal. Set
    -- platform.radius to 0.5 and the arena comes up: pieces really were
    -- created, so the client's "is there a floor" check passes -- and
    -- everybody who does not draw the middle spawn is placed over open air.
    --
    -- The realistic version is a dropped digit, not 0.5.
    local missed = nil

    for _, radius in ipairs({ 0.5, 1.0, 4.0, 20.0, 34.9, 35.0 }) do
        local output = validate(function(config)
            config.Arenas.skydome.platform.radius = radius
        end)
        if not output:find('over open air', 1, true) and not missed then
            missed = ('platform.radius = %.1f under a 35m spawn ring was not flagged'):format(radius)
        end
    end

    t.isNil(missed, missed or '')
end)

t.test('and a floor wider than its spawn ring is not', function()
    -- The shipped arena, and every sane one. A check that fires on correct
    -- config is a check an operator learns to ignore.
    local output = validate()
    t.isNil(output:find('over open air', 1, true),
        ('the shipped arenas were flagged for a floor that is fine:\n%s'):format(output))

    local wider = validate(function(config)
        config.Arenas.skydome.platform.radius = 200.0
    end)
    t.isNil(wider:find('over open air', 1, true), 'a generously large floor was flagged')
end)

t.test('FUZZ: and junk geometry never throws, whatever it is', function()
    -- The radius reaches arithmetic in several places. Whatever an operator
    -- types, the resource has to keep running and say something.
    local broke = nil

    for index = 1, 19 do
        local value = JUNK[index]
        local ok, err = pcall(function()
            local env = Sandbox.newArenaEnv()
            env.Config.Arenas.skydome.platform.radius = value
            env.Arena.ValidateConfig()
            env.Arena.GetPlatform('skydome')
            env.Arena.GetSpawnArea('skydome')
            env.Arena.PlanSpawns('skydome', { { src = 1 }, { src = 2 } })
        end)

        if not ok and not broke then
            broke = ('platform.radius = %s (%s): %s'):format(tostring(value), type(value), tostring(err))
        end
    end

    t.isNil(broke, broke or '')
end)

-- ======================================================================
-- A SUPPLY AMOUNT THE PICKER CANNOT OFFER
--
-- The supplies picker draws chips and nothing else -- there is no field to
-- type a number into -- so `options` is the entire set of amounts a player
-- can choose, not a row of shortcuts past a free entry box. A `default`
-- outside that set is therefore not a cosmetic mismatch: the row opens with
-- nothing lit while the player really is carrying that amount, and the
-- first chip they touch takes it away for good.
--
-- It shipped that way. Bandages defaulted to 2 with a ladder of
-- 0/5/10/20/30, so every player started with two bandages, no chip lit, and
-- no way back to two.
-- ======================================================================

t.test('the shipped supplies ladders all contain their own defaults', function()
    local output = validate()

    t.isNil(output:find('not one of its own options', 1, true),
        ('a shipped supply defaults to an amount its picker cannot offer:\n%s'):format(output))
end)

t.test('a default missing from its ladder is named, with the amount', function()
    local output = validate(function(config)
        config.Loadouts.supplies.items[2].default = 2
        config.Loadouts.supplies.items[2].options = { 0, 5, 10, 20, 30 }
    end)

    t.contains(output, 'bandage', 'the offending supply was not named')
    t.contains(output, 'defaults to 2', 'the unreachable amount was not quoted back')
    t.contains(output, 'chips', 'the operator is not told why the ladder is the whole set')
end)

t.test('and so is one with NO ladder at all, because the picker still only draws two chips',
function()
    -- With `options` missing the panel falls back to None and the maximum.
    -- A default between them is exactly as unreachable as one left out of a
    -- written ladder, and reads to an operator as the more innocent mistake.
    local output = validate(function(config)
        config.Loadouts.supplies.items[1].default = 3
        config.Loadouts.supplies.items[1].options = nil
    end)

    t.contains(output, 'armour', 'a supply with no ladder at all was not checked')
    t.contains(output, 'defaults to 3')
end)

t.test('a default at the top of an empty ladder is fine, because max IS a chip', function()
    local output = validate(function(config)
        config.Loadouts.supplies.items[1].default = config.Loadouts.supplies.items[1].max
        config.Loadouts.supplies.items[1].options = nil
    end)

    t.isNil(output:find('not one of its own options', 1, true),
        'the maximum was reported unreachable when the picker draws it as a chip')
end)

t.test('a default ABOVE max is compared as the amount really handed over', function()
    -- ResolveSupplies clamps the default to `max` before issuing it, so the
    -- amount the player ends up with is the maximum -- which the ladder
    -- offers. Comparing the number that was TYPED would warn about a row
    -- that lights up correctly.
    local output = validate(function(config)
        local supply = config.Loadouts.supplies.items[1]
        supply.default = supply.max + 50
        supply.options = { 0, supply.max }
    end)

    t.isNil(output:find('not one of its own options', 1, true),
        'a default clamped onto an existing chip was reported unreachable')
end)

t.test('and an OPTION above max is too, because the picker draws it clamped', function()
    -- The other half of the same rule, and the half that is easy to get
    -- wrong: renderSuppliesPicker clamps each chip down to `max` before
    -- drawing it, so an option written above the ceiling really is a chip
    -- for the ceiling. Reading the typed number here would flag a default
    -- of `max` as unreachable on a row whose last chip grants exactly that.
    local output = validate(function(config)
        local supply = config.Loadouts.supplies.items[1]
        supply.default = supply.max
        supply.options = { 0, supply.max + 10 }
    end)

    t.isNil(output:find('not one of its own options', 1, true),
        'a chip the picker clamps onto the default was read as a different amount')
end)

t.test('a supply switched OFF is not warned about', function()
    -- Nobody can be handed it and no row is drawn for it, so an amount
    -- nobody can pick is not a fault -- and warning about a disabled entry
    -- teaches an operator to ignore this whole list.
    local output = validate(function(config)
        config.Loadouts.supplies.items[2].enabled = false
        config.Loadouts.supplies.items[2].default = 2
        config.Loadouts.supplies.items[2].options = { 0, 5, 10 }
    end)

    t.isNil(output:find('not one of its own options', 1, true),
        'a supply nobody can be issued was still warned about')
end)

os.exit(t.summary())
