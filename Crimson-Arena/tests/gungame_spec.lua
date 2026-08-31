--[[
    crimson_arena/tests/gungame_spec.lua

    Config.Modes.gungame.gunGameLadder, played -- the REAL server/match.lua
    loaded into a sandbox over the REAL config.lua and shared/arena.lua, with
    the mode switched on the way an operator would switch it on.

    THE MODE SHIPS DISABLED and this file does not change that: every test
    that needs a ladder enables gungame in its OWN sandbox copy of the
    config, so the shipped file stays the file the rest of the suite proves
    things about. The first test below is the one that checks it is still
    off.

    WHAT IS STUBBED, and no more: the lobby that owns the match record, the
    escrow, the leaderboard, the dispatch flag, and CreateThread/Wait. The
    rules come from the real shared/arena.lua and the notifications from the
    real server/util.lua -- so a promotion whose locale key does not exist
    fails here, in the sandbox's locale(), rather than on somebody's screen.

    THE LADDER IS A LOADOUT DECISION, so almost every assertion below reads
    the loadout that went ON THE WIRE rather than a field on the record: what
    the client is sent is what the player ends up holding, and that is the
    thing an operator changing the ladder is trying to change.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('gungame_spec')

-- The ladder config.lua ships, and what each rung is really made of.
local SHIPPED_LADDER = { 'pistol', 'smg', 'shotgun', 'rifle', 'sniper', 'knife' }
local RUNG_WEAPONS = {
    'WEAPON_PISTOL', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN',
    'WEAPON_ASSAULTRIFLE', 'WEAPON_SNIPERRIFLE', 'WEAPON_KNIFE',
}

-- ======================================================================
-- THE SERVER UNDER TEST
-- ======================================================================

--- The one thing server/match.lua cannot run without: the lobby that owns
--- the match record. Only the functions match.lua actually calls are here,
--- so a file that starts calling a seventh one fails as a nil call naming it
--- rather than passing against a fixture that agreed with it in advance.
--- @return table lobby
local function newLobby()
    local matches = {}
    local lobby = { destroyed = {}, spectators = {} }

    function lobby.Get(matchId) return matches[matchId] end

    function lobby.GetByPlayer(src)
        for _, match in pairs(matches) do
            if match.players[src] then return match end
        end
        return nil
    end

    function lobby.All()
        local out = {}
        for _, match in pairs(matches) do out[#out + 1] = match end
        return out
    end

    -- Join order, exactly like the real one: the winners list -- and so the
    -- payout order -- must not depend on pairs().
    function lobby.PlayerArray(match)
        local out = {}
        if type(match) ~= 'table' then return out end
        for _, src in ipairs(match.order or {}) do
            local player = match.players[src]
            if player then out[#out + 1] = player end
        end
        return out
    end

    function lobby.PlayerCount(match) return #lobby.PlayerArray(match) end
    function lobby.Broadcast() end
    function lobby.AddSpectator(src) lobby.spectators[#lobby.spectators + 1] = src end
    function lobby.RemoveSpectator() end
    function lobby.Leave() end

    function lobby.Destroy(matchId, reasonKey)
        lobby.destroyed[#lobby.destroyed + 1] = { id = matchId, reason = reasonKey }
        matches[matchId] = nil
    end

    --- Test-side: puts a record where Get and GetByPlayer will find it.
    function lobby.put(match) matches[match.id] = match end

    return lobby
end

--- One arena server: real config, real rules, real util.lua, real
--- match.lua, and stand-ins for everything match.lua leans on but does not
--- own. Fresh per test -- a ladder enabled in one test must not decide the
--- answer in the next.
--- @param mutate fun(config: table)? -- applied before match.lua is loaded
--- @return table fixture
local function newFixture(mutate)
    local sent, console = {}, {}
    local runner = Sandbox.newThreadRunner()
    local lobby = newLobby()
    local recorded, settled = {}, {}

    local env = Sandbox.newEnv({
        CreateThread = runner.CreateThread,
        Wait = runner.Wait,
        TriggerClientEvent = function(event, target, payload)
            sent[#sent + 1] = { event = event, target = target, payload = payload }
        end,
        -- Captured rather than silenced: a dropped ladder rung is announced
        -- through ArenaDebug, and a test asserts on it.
        print = function(line) console[#console + 1] = line end,
        GetPlayerName = function(src) return ('Fighter %d'):format(src) end,
        -- The respawn picker asks where the live opponents are, so it can put
        -- a returning player somewhere none of them is.
        GetPlayerPed = function(src) return src end,
        -- Where a live opponent is, which the respawn picker reads so a
        -- player who lost a life does not come back next to whoever took it.
        -- Spread apart by server id so "furthest from the nearest threat" has
        -- a real answer rather than a tie between identical points.
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        exports = { qbx_core = { GetPlayer = function() return nil end } },

        ArenaLobby = lobby,
        ArenaStats = { RecordMatch = function(match) recorded[#recorded + 1] = match end },
        -- The flag, and the routing bucket a round is fought in. Both are
        -- entered and left on the same two choke points in match.lua, which
        -- is why they are stubbed together: a file that starts calling a
        -- fifth one fails as a nil call naming it.
        ArenaAmmo = {
            -- No-op double. server/ammo.lua is exercised directly by
            -- tests/ammo_spec.lua; here it only has to exist, because
            -- server/match.lua calls it at both arena choke points.
            IsEnabled = function() return false end,
            Issue = function() return {} end,
            -- The ladder swaps the weapon as an ITEM on an ox_inventory server:

            -- a ped handed a gun it has no item for is disarmed again within

            -- moments, so the promotion cannot be left to the client.

            SwapWeapon = function() return false end,
            Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end,
            Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end,
            Clear = function() end,
            -- Recorded like the rest: the exit path now tells whatever handles
            -- death that the player is alive again, and a stub missing it is a
            -- nil call rather than a silent no-op.
            Revive = function() end,
            EnterBucket = function() end,
            ExitBucket = function() end,
            GetBucket = function() end,
            ReleaseBucket = function() end,
        },
        ArenaBetting = {
            -- Refunds are not earnings, and server/match.lua asks this to
            -- tell them apart. A double missing it is a nil call naming it.
            IsRefundReason = function(reason)
                return type(reason) == 'string' and reason:sub(1, 6) == 'refund'
            end,
            GetPot = function() return 0 end,
            GetStake = function() return 0 end,
            Settle = function(matchId) settled[#settled + 1] = matchId return {} end,
            SettleSpectatorBets = function() end,
            RefundAll = function() end,
            Clear = function() end,
        },
    })

    Sandbox.loadInto('../config.lua', env)
    Sandbox.loadInto('../shared/arena.lua', env)
    if mutate then mutate(env.Config) end
    Sandbox.loadInto('../server/util.lua', env)
    Sandbox.loadInto('../server/match.lua', env)

    local fixture = {
        env = env,
        M = env.ArenaMatch,
        Arena = env.Arena,
        Config = env.Config,
        lobby = lobby,
        sent = sent,
        recorded = recorded,
        settled = settled,
    }

    --- One pass of every live thread: the sweep, and any respawn or
    --- countdown thread outstanding. The FIRST call only primes the sweep,
    --- which waits before it works.
    function fixture.step() runner.step() end

    --- Everything one player was sent under `event`, in order.
    --- @return table[] payloads
    function fixture.payloads(event, target)
        local out = {}
        for _, message in ipairs(sent) do
            if message.event == event and (target == nil or message.target == target) then
                out[#out + 1] = message.payload
            end
        end
        return out
    end

    --- The last payload of `event` sent to `target`, or nil.
    function fixture.lastPayload(event, target)
        local all = fixture.payloads(event, target)
        return all[#all]
    end

    function fixture.log() return table.concat(console, '\n') end

    return fixture
end

--- A lobby record in the shape server/lobby.lua builds one, with each
--- player's own panel choice already resolved into it -- which is what the
--- ladder has to be seen overruling.
--- @param fixture table
--- @param modeKey string
--- @param picks table[] -- one Arena.ResolveLoadout request per player
--- @return table match
local function newMatch(fixture, modeKey, picks)
    local match = {
        id = 'm1',
        label = 'test match',
        arenaKey = 'airfield',
        modeKey = modeKey,
        hostSource = 1,
        state = 'lobby',
        -- LIVES LIVE ON THE MATCH NOW, not in config: the host picks the
        -- number when they open the lobby, and every player seeded into that
        -- match takes it from here. A fixture that builds a match by hand has
        -- to say what the host chose -- left nil, every player is seeded with
        -- one life and a round ends on the first death.
        --
        -- Resolved through the real function against this fixture's own
        -- config, so a spec that sets Config.Match.lives still gets what it
        -- asked for rather than a literal written here.
        lives = fixture.Arena.ResolveLives(nil),
        entryFee = 0,
        createdAt = os.time(),
        startsAt = 0,
        endsAt = 0,
        players = {},
        order = {},
        spectators = {},
    }

    for index, pick in ipairs(picks) do
        match.players[index] = {
            src = index,
            citizenid = ('CID%03d'):format(index),
            name = ('Fighter %d'):format(index),
            team = nil,
            ready = true,
            loadout = (fixture.Arena.ResolveLoadout(pick)),
            kills = 0,
            deaths = 0,
            alive = true,
            lives = math.max(1, fixture.Arena.ToInt(fixture.Config.Match.lives) or 1),
            stake = 0,
            joinedAt = os.time(),
            placement = 0,
        }
        match.order[#match.order + 1] = index
    end

    fixture.lobby.put(match)
    return match
end

--- Turns the gun game on the way an operator would, and hands the round
--- rules a shape these tests can drive: no freeze, no respawn delay, and
--- enough lives that a victim can be killed again.
--- @param ladder string[]? -- defaults to the shipped one
--- @return fun(config: table)
local function gunGameConfig(ladder)
    return function(config)
        config.Modes.gungame.enabled = true
        if ladder then config.Modes.gungame.gunGameLadder = ladder end
        config.Match.startCountdownSeconds = 0
        config.Match.respawnDelaySeconds = 0
        config.Match.lives = 10
    end
end

--- Start a match and let the freeze thread run, so the round is live and
--- deaths count.
--- @param fixture table
--- @param match table
local function goLive(fixture, match)
    local ok, reason = fixture.M.Start(match.id)
    t.isTrue(ok, ('Start refused: %s'):format(tostring(reason)))
    fixture.step()
    t.equals(match.state, 'live', 'match never went live')
end

--- One credited kill, followed by the pass that respawns the victim so they
--- can be killed again.
--- @param fixture table
--- @param killer integer
--- @param victim integer
local function kill(fixture, killer, victim)
    t.isTrue(fixture.M.OnDeath(victim, killer), ('kill %d -> %d was not counted'):format(killer, victim))
    fixture.step()
end

--- The weapon names in a loadout, in the order the client will be handed
--- them.
--- @param loadout table
--- @return string[]
local function weaponsOf(loadout)
    local names = {}
    for _, entry in ipairs(loadout.weapons or {}) do names[#names + 1] = entry.weapon end
    return names
end

-- ======================================================================
-- WHAT SHIPS
-- ======================================================================

t.test('gun game ships OFF, and the ladder behind it is still sound', function()
    -- THE CONTRACT HAS CHANGED TWICE, both times on the operator's
    -- instruction, and neither time because anything was wrong with the mode.
    -- It shipped off while it was unfinished, went on once the promotion
    -- event had a client handler at last, and is off again now because this
    -- server does not want to run it.
    --
    -- So what is asserted is BOTH halves: that it is off, and that it is
    -- nonetheless ready -- the ladder intact, every rung a real weapon --
    -- because the whole of turning it back on is flipping `enabled`, and a
    -- mode that comes back on with a broken ladder promotes nobody.
    local f = newFixture()
    t.isFalse(f.Config.Modes.gungame.enabled,
        'gun game is live again -- the operator asked for it off')

    -- Read with the mode forced on, since GetLadder answers with nothing for
    -- a mode that is switched off. That IS the behaviour asserted below; here
    -- it would only hide whether the ladder itself survived.
    local ready = newFixture(function(config) config.Modes.gungame.enabled = true end)
    t.isTrue(#ready.M.GetLadder('gungame') > 0,
        'the ladder is empty, so switching gun game back on would promote nobody')
end)

t.test('and a mode switched OFF still plays no ladder', function()
    -- The half of the old test that is still about behaviour rather than
    -- about a default: disabling the mode has to actually disable it.
    local f = newFixture(function(config) config.Modes.gungame.enabled = false end)
    t.equals(#f.M.GetLadder('gungame'), 0)
end)

t.test('the shipped ladder is six rungs of real, enabled weapons', function()
    local f = newFixture(gunGameConfig())
    local rungs = f.M.GetLadder('gungame')

    t.equals(#rungs, #SHIPPED_LADDER)
    for index, key in ipairs(SHIPPED_LADDER) do
        t.equals(rungs[index].key, key)
        -- Resolved through the catalogue, not copied off the ladder: the
        -- rung carries the real GTA weapon name.
        t.equals(rungs[index].weapon, RUNG_WEAPONS[index])
    end
end)

t.test('every other mode has no ladder at all', function()
    local f = newFixture(gunGameConfig())
    t.equals(#f.M.GetLadder('ffa'), 0)
    t.equals(#f.M.GetLadder('tdm'), 0)
    t.equals(#f.M.GetLadder('nonsense'), 0)
    t.equals(#f.M.GetLadder(nil), 0)
    t.equals(#f.M.GetLadder(42), 0)
end)

-- ======================================================================
-- RungForKills -- the whole of the mode's arithmetic
-- ======================================================================

t.test('RungForKills starts everybody on rung one', function()
    local f = newFixture()
    local rung, finished = f.M.RungForKills(0, 6)
    t.equals(rung, 1)
    t.isFalse(finished)
end)

t.test('RungForKills moves one rung per kill', function()
    local f = newFixture()
    for kills = 0, 4 do
        local rung, finished = f.M.RungForKills(kills, 6)
        t.equals(rung, kills + 1)
        t.isFalse(finished)
    end
end)

t.test('RungForKills finishes the ladder on the kill made from the last rung', function()
    local f = newFixture()
    -- Five kills puts a six-rung climber ON the last rung; the sixth is the
    -- one made with it, and that is the one that wins.
    local fifth, notYet = f.M.RungForKills(5, 6)
    t.equals(fifth, 6)
    t.isFalse(notYet)

    local sixth, won = f.M.RungForKills(6, 6)
    t.equals(sixth, 6)
    t.isTrue(won)
end)

t.test('RungForKills never walks off the end of the ladder', function()
    local f = newFixture()
    local rung, finished = f.M.RungForKills(99, 6)
    t.equals(rung, 6)
    t.isTrue(finished)
end)

t.test('RungForKills answers rung one for a ladder with nothing in it', function()
    local f = newFixture()
    -- Nothing to climb is not a win: a mode with no playable ladder is
    -- ordinary play, and ordinary play is decided by Config.Match.
    local rung, finished = f.M.RungForKills(10, 0)
    t.equals(rung, 1)
    t.isFalse(finished)
end)

t.test('RungForKills refuses to be moved by rubbish', function()
    local f = newFixture()
    for _, junk in ipairs({ 'three', '', -4, 0 / 0 }) do
        local rung, finished = f.M.RungForKills(junk, 6)
        t.equals(rung, 1, ('%s should not have earned a rung'):format(tostring(junk)))
        t.isFalse(finished)
    end
    -- A fractional kill count is floored rather than rounded up: two and a
    -- half kills is two kills.
    t.equals((f.M.RungForKills(2.7, 6)), 3)
end)

-- ======================================================================
-- THE LADDER AGAINST THE CATALOGUE
-- ======================================================================

t.test('a rung naming a disabled weapon is dropped and the ladder is shorter', function()
    -- grenadelauncher ships enabled = false. A ladder that names it must not
    -- hand out nothing, and must not take the mode down.
    local f = newFixture(gunGameConfig({ 'pistol', 'grenadelauncher', 'knife' }))
    local rungs = f.M.GetLadder('gungame')

    t.equals(#rungs, 2)
    t.equals(rungs[1].key, 'pistol')
    t.equals(rungs[2].key, 'knife')
end)

t.test('a rung naming a weapon that does not exist is dropped, and says so in debug', function()
    local f = newFixture(function(config)
        gunGameConfig({ 'pistol', 'raygun', 'knife' })(config)
        config.Debug = true
    end)

    t.equals(#f.M.GetLadder('gungame'), 2)
    t.contains(f.log(), 'raygun')
end)

t.test('a ladder rung that is not a key at all is dropped rather than raising', function()
    local f = newFixture(gunGameConfig({ 'pistol', 42, { key = 'smg' }, '', 'knife' }))
    local rungs = f.M.GetLadder('gungame')

    t.equals(#rungs, 2)
    t.equals(rungs[1].key, 'pistol')
    t.equals(rungs[2].key, 'knife')
end)

t.test('a ladder with no usable rung left is no ladder', function()
    local f = newFixture(gunGameConfig({ 'raygun', 'grenadelauncher' }))
    t.equals(#f.M.GetLadder('gungame'), 0)
end)

t.test('a missing or malformed gunGameLadder is no ladder', function()
    for _, ladder in ipairs({ {}, 'pistol', 7 }) do
        local f = newFixture(function(config)
            gunGameConfig()(config)
            config.Modes.gungame.gunGameLadder = ladder
        end)
        t.equals(#f.M.GetLadder('gungame'), 0, ('%s should be no ladder'):format(type(ladder)))
    end

    local missing = newFixture(function(config)
        gunGameConfig()(config)
        config.Modes.gungame.gunGameLadder = nil
    end)
    t.equals(#missing.M.GetLadder('gungame'), 0)
end)

-- ======================================================================
-- WALKING IN
-- ======================================================================

t.test('the ladder replaces the weapon a player picked in the panel', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', {
        { weapons = { { key = 'sniper', ammo = 40 } }, armor = 50 },
        { weapons = { { key = 'rifle', ammo = 300 } }, armor = 100 },
    })
    goLive(f, match)

    local first = f.lastPayload('crimson_arena:client:enterArena', 1)
    -- Not the sniper they asked for: rung one, at the pistol's own default.
    t.equals(first.loadout.weapons[1].weapon, 'WEAPON_PISTOL')
    t.equals(first.loadout.weapons[1].ammo, 60)

    local second = f.lastPayload('crimson_arena:client:enterArena', 2)
    t.equals(second.loadout.weapons[1].weapon, 'WEAPON_PISTOL')
end)

t.test('walking in leaves everything that is not a weapon choice alone', function()
    local f = newFixture(function(config)
        (gunGameConfig())(config)
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local match = newMatch(f, 'gungame', {
        { weapons = { { key = 'sniper' } }, armor = 50 },
        { weapons = { { key = 'rifle' } }, armor = 100 },
    })
    goLive(f, match)

    local payload = f.lastPayload('crimson_arena:client:enterArena', 1)
    -- A full plate, whatever the request asked for: armour is not choosable
    -- (Config.Loadouts.armor.allowChoose is false, so every round starts even)
    -- and the ladder does not touch it either way.
    t.equals(payload.loadout.armor, f.Config.Loadouts.armor.default)
    t.equals(payload.loadout.health, f.Config.Loadouts.health)
    -- The operator's alwaysGive list is the house's, not the player's, and
    -- it survives the ladder the same way it survives the slot limit.
    t.equals(payload.loadout.weapons[2].weapon, 'WEAPON_KNIFE')
    t.isTrue(payload.loadout.weapons[2].alwaysGive)
end)

t.test('the ladder outranks Config.Loadouts.fixed when choosing is switched off', function()
    -- allowChoose = false normally means "everybody gets `fixed`". In gun
    -- game the ladder is the operator's list, and it is the one that wins.
    local f = newFixture(function(config)
        gunGameConfig()(config)
        config.Loadouts.allowChoose = false
        -- Set here rather than inherited: alwaysGive ships empty, and this
        -- test is about the ladder outranking `fixed`, not about what the
        -- house hands out.
        config.Loadouts.alwaysGive = { { key = 'knife' } }
    end)
    local match = newMatch(f, 'gungame', { {}, {} })
    goLive(f, match)

    -- The bottom rung and the house knife, and nothing from `fixed`: its
    -- rifle would be the first entry if that list had reached the player.
    local names = weaponsOf(f.lastPayload('crimson_arena:client:enterArena', 1).loadout)
    t.equals(#names, 2)
    t.equals(names[1], 'WEAPON_PISTOL')
    t.equals(names[2], 'WEAPON_KNIFE')
end)

t.test('everybody starts on the bottom rung with the ladder ahead of them', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {} })
    goLive(f, match)

    t.equals(match.players[1].rung, 1)
    t.isFalse(match.players[1].ladderFinished)
    t.equals(match.players[2].rung, 1)
end)

t.test('a mode with no ladder still hands a player exactly what they picked', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'ffa', {
        { weapons = { { key = 'sniper', ammo = 40 } } },
        { weapons = { { key = 'rifle' } } },
    })
    goLive(f, match)

    local payload = f.lastPayload('crimson_arena:client:enterArena', 1)
    t.equals(payload.loadout.weapons[1].weapon, 'WEAPON_SNIPERRIFLE')
    t.equals(payload.loadout.weapons[1].ammo, 40)
end)

t.test('a gun game whose ladder is all rubbish falls back to ordinary play', function()
    local f = newFixture(gunGameConfig({ 'raygun' }))
    local match = newMatch(f, 'gungame', {
        { weapons = { { key = 'sniper' } } },
        { weapons = { { key = 'rifle' } } },
    })
    goLive(f, match)

    -- No ladder to climb, so the player keeps their own choice rather than
    -- walking in empty-handed.
    t.equals(f.lastPayload('crimson_arena:client:enterArena', 1).loadout.weapons[1].weapon, 'WEAPON_SNIPERRIFLE')

    kill(f, 1, 2)
    t.equals(#f.payloads('crimson_arena:client:gunGameRung'), 0)
    t.isFalse(match.players[1].ladderFinished)
end)

-- ======================================================================
-- CLIMBING
-- ======================================================================

t.test('a credited kill moves the killer one rung up', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)

    t.equals(match.players[1].rung, 2)
    local promotion = f.lastPayload('crimson_arena:client:gunGameRung', 1)
    t.equals(promotion.rung, 2)
    t.equals(promotion.rungs, 6)
    t.equals(promotion.weapon, 'WEAPON_SMG')
    -- The rung below is taken back, and only that.
    t.equals(promotion.remove, 'WEAPON_PISTOL')
end)

t.test('a promotion carries the new weapon at its own configured default ammo', function()
    -- The player asked for 300 SMG rounds in the lobby. The ladder hands out
    -- the weapon's default, and neither their ask nor its max.
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { { weapons = { { key = 'smg', ammo = 300 } } }, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)
    t.equals(f.lastPayload('crimson_arena:client:gunGameRung', 1).ammo, 150)
end)

t.test('nobody is told about a rung they did not climb', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)
    t.equals(#f.payloads('crimson_arena:client:gunGameRung', 2), 0)
    t.equals(match.players[2].rung, 1)
    t.equals(match.players[3].rung, 1)
end)

t.test('an unverified kill claim climbs nobody', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    -- 99 is not in this match, and a player cannot kill themselves up the
    -- ladder either.
    t.isTrue(f.M.OnDeath(2, 99))
    t.isTrue(f.M.OnDeath(3, 3))
    f.step()

    t.equals(#f.payloads('crimson_arena:client:gunGameRung'), 0)
    t.equals(match.players[1].rung, 1)
    t.equals(match.players[3].rung, 1)
end)

t.test('the rung a player is already on is never granted twice', function()
    local f = newFixture(gunGameConfig({ 'pistol', 'smg' }))
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)                                   -- rung 1 -> 2
    t.equals(#f.payloads('crimson_arena:client:gunGameRung', 1), 1)

    -- A second kill from the top rung finishes the ladder; it does not
    -- re-issue the weapon already in the player's hands, which would refill
    -- its ammo for free.
    t.isTrue(f.M.OnDeath(3, 1))
    t.equals(#f.payloads('crimson_arena:client:gunGameRung', 1), 1)
    t.equals(match.players[1].rung, 2)
    t.isTrue(match.players[1].ladderFinished)
end)

t.test('a six-rung climb issues one promotion per rung and no more', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    for round = 1, 6 do
        kill(f, 1, (round % 2 == 0) and 3 or 2)
    end

    -- Six kills, five promotions: rung one is where they started, and the
    -- sixth kill was made FROM the top rung rather than onto a seventh.
    local promotions = f.payloads('crimson_arena:client:gunGameRung', 1)
    t.equals(#promotions, 5)
    for index, promotion in ipairs(promotions) do
        t.equals(promotion.rung, index + 1)
        t.equals(promotion.weapon, RUNG_WEAPONS[index + 1])
        t.equals(promotion.remove, RUNG_WEAPONS[index])
    end
end)

t.test('the top rung of the shipped ladder is not handed out twice over', function()
    -- The last rung is the knife, and so is Config.Loadouts.alwaysGive. The
    -- client gives what it is sent, entry for entry, so the duplicate has to
    -- be gone before it leaves here.
    local f = newFixture(gunGameConfig({ 'pistol', 'knife' }))
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)

    local names = weaponsOf(match.players[1].loadout)
    t.equals(#names, 1)
    t.equals(names[1], 'WEAPON_KNIFE')
    -- And the pistol it replaced is not stripped by a remove that would take
    -- the knife with it.
    t.equals(f.lastPayload('crimson_arena:client:gunGameRung', 1).remove, 'WEAPON_PISTOL')
end)

t.test('a respawn hands back the rung the player is on, not their lobby pick', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { { weapons = { { key = 'sniper' } } }, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)                                   -- player 1 is on the SMG
    kill(f, 2, 1)                                   -- and is killed by player 2

    local respawn = f.lastPayload('crimson_arena:client:respawn', 1)
    t.isNotNil(respawn, 'player 1 never came back')
    t.equals(respawn.loadout.weapons[1].weapon, 'WEAPON_SMG')
    t.equals(respawn.loadout.weapons[1].ammo, 150)
end)

t.test('a ladder shortened mid-round puts a player on the top rung, not off the end', function()
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)
    kill(f, 1, 3)                                   -- player 1 is on rung 3

    -- An operator reloading a shorter ladder mid-round leaves somebody
    -- standing on a rung that no longer exists.
    f.Config.Modes.gungame.gunGameLadder = { 'pistol', 'smg' }
    kill(f, 2, 1)

    local respawn = f.lastPayload('crimson_arena:client:respawn', 1)
    t.equals(respawn.loadout.weapons[1].weapon, 'WEAPON_SMG')
    t.equals(match.players[1].rung, 2)
end)

-- ======================================================================
-- WINNING
-- ======================================================================

t.test('finishing the ladder wins the match whatever the win condition says', function()
    local f = newFixture(function(config)
        gunGameConfig({ 'pistol', 'smg' })(config)
        -- Two other players are alive and nobody is near the score limit, so
        -- neither of these would have ended this round.
        config.Match.winCondition = 'last_standing'
        config.Match.scoreLimit = 25
    end)
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)                                   -- rung 2, the last one
    t.equals(match.state, 'live')

    t.isTrue(f.M.OnDeath(3, 1))                     -- the kill that finishes it
    t.equals(match.state, 'live', 'the death report decided the match itself')

    f.step()                                        -- the sweep decides, as always
    t.equals(match.state, 'ended')
    t.equals(#match.winners, 1)
    t.equals(match.winners[1], 1)

    local results = f.lastPayload('crimson_arena:client:exitArena', 1).results
    t.isTrue(results.won)
    t.equals(results.reason, 'match.ended_ladder')
    t.equals(f.lobby.destroyed[1].reason, 'match.ended_ladder')
    t.equals(#f.recorded, 1)
end)

t.test('a shorter ladder is won sooner, which is the whole of what the key does', function()
    -- Same round, one rung fewer, and the match ends a kill earlier. This is
    -- the assertion an operator is really making when they edit the ladder.
    local f = newFixture(gunGameConfig({ 'pistol', 'smg', 'rifle' }))
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    kill(f, 1, 2)
    kill(f, 1, 3)
    t.equals(match.state, 'live')
    t.isFalse(match.players[1].ladderFinished)

    kill(f, 1, 2)
    t.equals(match.state, 'ended')
    t.equals(match.winners[1], 1)
end)

t.test('two climbers who finish in the same sweep both take it', function()
    local f = newFixture(gunGameConfig({ 'pistol' }))
    local match = newMatch(f, 'gungame', { {}, {}, {} })
    goLive(f, match)

    -- A one-rung ladder: the first kill each finishes it. Both land before
    -- the sweep runs, and the server cannot honestly order two kills
    -- reported in the same second.
    t.isTrue(f.M.OnDeath(3, 1))
    t.isTrue(f.M.OnDeath(2, 3))
    f.step()

    t.equals(match.state, 'ended')
    t.equals(#match.winners, 2)
    -- Join order, so the payout order is not left to pairs().
    t.equals(match.winners[1], 1)
    t.equals(match.winners[2], 3)
end)

t.test('nobody wins a gun game by outliving it', function()
    -- Last standing still ends a round -- there is nobody left to climb
    -- against -- but it is not a ladder win and it does not need one.
    local f = newFixture(gunGameConfig())
    local match = newMatch(f, 'gungame', { {}, {} })
    goLive(f, match)

    f.Config.Match.lives = 1
    match.players[2].lives = 1
    t.isTrue(f.M.OnDeath(2, 1))
    f.step()

    t.equals(match.state, 'ended')
    t.equals(f.lobby.destroyed[1].reason, 'match.ended_last_standing')
    t.isFalse(match.players[1].ladderFinished)
end)

os.exit(t.summary())
