--[[
    tests/rulesdefects_spec.lua

    Three rules in shared/arena.lua that did not hold, each pinned here
    against the REAL file loaded through tests/fixtures/sandbox.lua:

      * a payout threshold judged on the survivors, so quitting a 1v1 you
        were losing turned your forfeited stake back into a refund;
      * an alwaysGive de-duplication written in one namespace and checked in
        the other, so the house knife was handed out twice to anybody who
        picked a knife;
      * a team suggestion that ignored the cap the start check enforces, so
        auto-assign built rosters that could only ever be refused.

    Every case below fails against the file as it was and passes against the
    file as it is -- that is the only reason any of them is here.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

local stock = Sandbox.newArenaEnv()
local Arena = stock.Arena

--- A sandbox of its own, mutated into the server one test is about. The
--- shipped config is never written to: a test that changed it would change
--- the answer for every test after it.
--- @param mutate fun(config: table)
--- @return table arena
--- @return table config
local function tweaked(mutate)
    local env = Sandbox.newArenaEnv()
    mutate(env.Config)
    return env.Arena, env.Config
end

--- The payout row for one player id, or nil.
--- @param payouts table[]
--- @param id any
--- @return table|nil
local function rowFor(payouts, id)
    for _, payout in ipairs(payouts) do
        if payout.id == id then return payout end
    end
    return nil
end

--- Every GTA weapon name in a resolved loadout, in the order the client
--- would be handed them.
--- @param loadout table
--- @return string[]
local function weaponsOf(loadout)
    local names = {}
    for _, entry in ipairs(loadout.weapons or {}) do names[#names + 1] = entry.weapon end
    return names
end

--- How many times one weapon appears in a resolved loadout. The client gives
--- what it is sent, entry for entry, so two is two GiveWeaponToPed calls.
--- @param loadout table
--- @param weapon string
--- @return integer
local function countOf(loadout, weapon)
    local total = 0
    for _, entry in ipairs(loadout.weapons or {}) do
        if entry.weapon == weapon then total = total + 1 end
    end
    return total
end

--- What server/match.lua does to a stored loadout at match start: feeds the
--- resolved thing back through the same function against the live catalogue.
--- @param arena table
--- @param loadout table
--- @return table loadout
--- @return string[] rejected
local function reresolve(arena, loadout)
    return arena.ResolveLoadout(loadout)
end

--- server/match.lua's assignMissingTeams, in miniature: every player without
--- a side takes the one Arena.SuggestTeam names, counted in place so the next
--- unchosen player sees the one before them.
--- @param arena table
--- @param count integer
--- @return table[] players
local function autoAssign(arena, count)
    local players = {}
    for index = 1, count do players[index] = { id = index } end
    for _, player in ipairs(players) do
        player.team = arena.SuggestTeam(players)
    end
    return players
end

-- ======================================================================
-- ComputePayouts -- WHO THE ROUND WAS FOUGHT WITH
--
-- `players` is who is still here to be paid. `contestants` is how many the
-- round started with. Config.Betting.minPlayersToPayOut is a rule about the
-- second, and reading it off the first is what made walking out profitable.
-- ======================================================================

t.test('a mid-round quitter cannot turn a decided round into a refund', function()
    -- The shipped 1v1: two players at 1000 each, minPlayersToPayOut = 2, and
    -- refundOnDisconnectDuringMatch off, so the quitter's stake stays in the
    -- pot. One walks out, the survivor wins the round, and the payout sees a
    -- roster of one -- which used to mean "too few players, give it all back"
    -- and handed the quitter their forfeited stake.
    local Config = stock.Config
    t.equals(Config.Betting.minPlayersToPayOut, 2)
    t.isFalse(Config.Betting.refundOnDisconnectDuringMatch)

    local payouts, cut = Arena.ComputePayouts({
        pot = 2000,
        contestants = 2,
        players = { { id = 1, team = nil, kills = 1, stake = 1000, placement = 1 } },
        winners = { 1 },
        teams = false,
    })

    t.equals(#payouts, 1)
    t.equals(rowFor(payouts, 1).amount, 2000, 'the winner was paid his own stake back, not the pot')
    t.equals(rowFor(payouts, 1).reason, 'winner')
    t.equals(cut, 0)
end)

t.test('a round genuinely fought below minPlayersToPayOut still refunds', function()
    -- The rule itself is not weakened: one player who staked and fought
    -- nobody is exactly what it exists to refuse.
    local payouts = Arena.ComputePayouts({
        pot = 1000,
        contestants = 1,
        players = { { id = 1, stake = 1000 } },
        winners = { 1 },
        teams = false,
    })

    t.equals(#payouts, 1)
    t.equals(rowFor(payouts, 1).amount, 1000)
    t.equals(rowFor(payouts, 1).reason, 'refund_too_few')
end)

t.test('a caller that names no contestant count is judged on the roster it handed in', function()
    -- A round that never went live has no separate figure to give, and the
    -- two numbers are the same one there. Every existing caller shape keeps
    -- the behaviour it had.
    local short = Arena.ComputePayouts({
        pot = 1000,
        players = { { id = 1, stake = 1000 } },
        winners = { 1 },
        teams = false,
    })
    t.equals(rowFor(short, 1).reason, 'refund_too_few')

    local full = Arena.ComputePayouts({
        pot = 2000,
        players = { { id = 1, stake = 1000 }, { id = 2, stake = 1000 } },
        winners = { 1 },
        teams = false,
    })
    t.equals(rowFor(full, 1).amount, 2000)
    t.equals(rowFor(full, 1).reason, 'winner')
end)

t.test('a contestant count under the roster it was handed cannot deny that roster a payout', function()
    -- The count only ever grows the head count the threshold is judged on.
    -- A caller that passes a stale, zero or nonsense figure falls back to the
    -- players in front of it rather than refunding a full match.
    for _, contestants in ipairs({ 0, 1, -5, 'two' }) do
        local payouts = Arena.ComputePayouts({
            pot = 2000,
            contestants = contestants,
            players = { { id = 1, stake = 1000 }, { id = 2, stake = 1000 } },
            winners = { 1 },
            teams = false,
        })
        t.equals(rowFor(payouts, 1).reason, 'winner', tostring(contestants))
        t.equals(rowFor(payouts, 1).amount, 2000, tostring(contestants))
    end
end)

t.test('contestants does not reach any decision other than the threshold', function()
    -- It is a head count, not a pot: no winner is still a refund, and an
    -- empty pot still pays nobody, whatever was fought.
    local noWinner = Arena.ComputePayouts({
        pot = 1500,
        contestants = 8,
        players = { { id = 1, stake = 500 }, { id = 2, stake = 1000 } },
        winners = {},
        teams = false,
    })
    t.equals(#noWinner, 2)
    t.equals(rowFor(noWinner, 1).reason, 'refund_no_winner')
    t.equals(rowFor(noWinner, 1).amount, 500)
    t.equals(rowFor(noWinner, 2).amount, 1000)

    local emptyPot = Arena.ComputePayouts({
        pot = 0,
        contestants = 8,
        players = { { id = 1, stake = 0 } },
        winners = { 1 },
        teams = false,
    })
    t.equals(#emptyPot, 0)
end)

-- ======================================================================
-- ResolveLoadout -- THE HOUSE WEAPON AND THE PICKED ONE
--
-- The picked loop records catalogue keys ('knife'); the alwaysGive loop
-- checks GTA weapon names ('WEAPON_KNIFE'). Until both spellings were
-- recorded the guard could never fire on a weapon a player had picked.
-- ======================================================================

t.test('picking the weapon the operator already hands out does not hand it out twice', function()
    -- THE FIXTURE, asserted through the resolver rather than off the raw
    -- config field. alwaysGive accepts either spelling -- a catalogue `key`,
    -- which inherits the real entry, or a bare `weapon` name taken verbatim
    -- -- and this test is about the guard between the two loops, not about
    -- which form the shipped config happens to use today. Reading the field
    -- directly made it fail the moment that choice changed, which is a test
    -- failing for a reason it does not care about.
    -- alwaysGive ships EMPTY -- a player carries what they picked. This test
    -- is about the guard between the picked loop and the alwaysGive loop, so
    -- it puts a house weapon there itself rather than depending on one.
    local Config = stock.Config
    Config.Loadouts.alwaysGive = { { key = 'knife' } }
    local house = Config.Loadouts.alwaysGive[1]
    local houseWeapon = house.weapon or Arena.GetWeaponByKey(house.key).weapon
    t.equals(houseWeapon, 'WEAPON_KNIFE')
    t.equals(Arena.GetWeaponByKey('knife').weapon, 'WEAPON_KNIFE')

    local loadout, rejected = Arena.ResolveLoadout({
        weapons = { { key = 'knife' }, { key = 'pistol', ammo = 120 } },
    })

    t.equals(countOf(loadout, 'WEAPON_KNIFE'), 1, 'the house knife was handed out on top of the picked one')
    t.equals(#loadout.weapons, 2)
    t.equals(weaponsOf(loadout)[1], 'WEAPON_KNIFE')
    t.equals(weaponsOf(loadout)[2], 'WEAPON_PISTOL')
    t.equals(#rejected, 0)
end)

t.test('an alwaysGive entry does not overwrite the ammo the player chose for the same weapon', function()
    -- The client gives what it is sent in order, so a second entry for one
    -- weapon lands its SetPedAmmo last -- an operator whose house weapon is
    -- also on the picker would silently cut every chosen count down to theirs.
    local arena = tweaked(function(config)
        config.Loadouts.alwaysGive = { { weapon = 'WEAPON_PISTOL', ammo = 12 } }
    end)

    local loadout = arena.ResolveLoadout({ weapons = { { key = 'pistol', ammo = 120 } } })

    t.equals(countOf(loadout, 'WEAPON_PISTOL'), 1)
    t.equals(loadout.weapons[1].ammo, 120)
end)

t.test('a stored loadout re-resolved at match start rejects nothing it handed out itself', function()
    -- server/match.lua re-runs the stored loadout through ResolveLoadout on
    -- entry and logs whatever comes back rejected. Anything the lobby itself
    -- put in that table has to survive the second pass, or every player of
    -- every match produces a false "dropped 1 loadout entr(ies)" line --
    -- burying the one diagnostic an operator has for a real one.
    local first, firstRejected = Arena.ResolveLoadout({ weapons = { { key = 'pistol', ammo = 120 } } })
    t.equals(#firstRejected, 0)
    t.equals(#first.weapons, 1)

    local second, secondRejected = reresolve(Arena, first)
    t.equals(#secondRejected, 0, 'match start rejected the entry the lobby itself put there')
    t.equals(#second.weapons, 1)
    t.equals(weaponsOf(second)[1], 'WEAPON_PISTOL')
    t.equals(second.weapons[1].ammo, 120)

    -- And it is stable: a third pass is the same loadout again, not a
    -- shorter one.
    local third, thirdRejected = reresolve(Arena, second)
    t.equals(#thirdRejected, 0)
    t.equals(#third.weapons, 1)
end)

t.test('a re-resolved loadout still loses a weapon the operator has since switched off', function()
    -- The re-resolve is a check, not a pass-through.
    local arena = tweaked(function(config)
        for _, weapon in ipairs(config.Loadouts.weapons) do
            if weapon.key == 'sniper' then weapon.enabled = false end
        end
    end)

    local stored = { weapons = { { key = 'sniper', ammo = 20 }, { key = 'pistol', ammo = 60 } } }
    local loadout, rejected = arena.ResolveLoadout(stored)

    t.equals(#rejected, 1)
    t.equals(rejected[1], 'sniper')
    t.equals(#loadout.weapons, 1)
    t.equals(loadout.weapons[1].weapon, 'WEAPON_PISTOL')
end)

-- ======================================================================
-- SuggestTeam -- THE CAP THE START CHECK ALREADY ENFORCES
-- ======================================================================

t.test('SuggestTeam does not name a team that is already at maxTeamSize', function()
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 2 end)

    -- Crimson is full and Ash has one seat left, so the smallest team is not
    -- the answer -- the smallest team with room is.
    local players = {
        { id = 1, team = 'crimson' }, { id = 2, team = 'crimson' }, { id = 3, team = 'ash' },
    }
    t.equals(arena.SuggestTeam(players), 'ash')
end)

t.test('SuggestTeam has no side to suggest once every enabled team is full', function()
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 1 end)

    t.equals(arena.SuggestTeam({ { id = 1, team = 'crimson' } }), 'ash')
    t.isNil(arena.SuggestTeam({ { id = 1, team = 'crimson' }, { id = 2, team = 'ash' } }))
end)

t.test('SuggestTeam still fills evenly while the caps have room, and zero is unlimited', function()
    local capped = tweaked(function(config) config.Teams.maxTeamSize = 3 end)
    local players = autoAssign(capped, 6)

    local counts = capped.CountTeams(players)
    t.equals(counts.crimson, 3)
    t.equals(counts.ash, 3)
    t.isTrue((capped.TeamsAreStartable(players)))

    -- The shipped cap is 0, which has always meant unlimited and still does.
    t.equals(stock.Config.Teams.maxTeamSize, 0)
    local uncapped = autoAssign(Arena, 40)
    t.equals(Arena.CountTeams(uncapped).crimson, 20)
    t.isTrue((Arena.TeamsAreStartable(uncapped)))
end)

t.test('auto-assign never writes a roster the start check will refuse for capacity', function()
    -- Six players, two teams, a cap of two. Auto-assign used to hand out
    -- 3v3 -- a split TeamsAreStartable refuses, that nobody could switch out
    -- of, because both sides were over the cap the switch is checked against.
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 2 end)
    local players = autoAssign(arena, 6)

    local counts = arena.CountTeams(players)
    t.equals(counts.crimson, 2)
    t.equals(counts.ash, 2)
    t.isNil(players[5].team, 'a fifth player was written onto a full team')
    t.isNil(players[6].team)

    -- The lobby is still refused -- six into four does not go -- but it is
    -- refused for the reason that is true, with nobody wedged over the cap.
    local ok, reason = arena.TeamsAreStartable(players)
    t.isFalse(ok)
    t.equals(reason, 'error.team_over_capacity')
end)

t.test('the lobby recovers the moment the overflow leaves', function()
    -- The point of not writing the over-capacity roster: what is left when
    -- the two who did not fit walk out is a legal 2v2 that starts.
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 2 end)
    local players = autoAssign(arena, 6)

    local remaining = {}
    for index = 1, 4 do remaining[index] = players[index] end

    local ok, reason = arena.TeamsAreStartable(remaining)
    t.isTrue(ok, tostring(reason))
    t.isNil(reason)
end)

t.test('a team match will not start with a fighter no side has room for', function()
    -- TeamsAreStartable is the last gate before the teleport, and a player
    -- carried into a team round with no side is on nobody's team for the win
    -- condition and hurt by everybody under friendly fire.
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 2 end)

    local ok, reason = arena.TeamsAreStartable({
        { id = 1, team = 'crimson' }, { id = 2, team = 'crimson' },
        { id = 3, team = 'ash' }, { id = 4, team = 'ash' },
        { id = 5, team = nil },
    })
    t.isFalse(ok)
    t.equals(reason, 'error.team_over_capacity')
end)

t.test('an unchosen player a team still has room for does not block the start', function()
    -- Config.Teams.autoAssignIfUnchosen is on by default and the assignment
    -- happens at start, so "has not picked yet" is a legal lobby the panel
    -- must keep offering a start button for.
    local arena = tweaked(function(config) config.Teams.maxTeamSize = 3 end)

    local ok, reason = arena.TeamsAreStartable({
        { id = 1, team = 'crimson' }, { id = 2, team = 'ash' }, { id = 3, team = nil },
    })
    t.isTrue(ok, tostring(reason))

    -- And with no cap at all there is nothing for the check to measure
    -- against, so any number of unchosen players is fine.
    local uncapped = Arena.TeamsAreStartable({
        { id = 1, team = 'crimson' }, { id = 2, team = 'ash' },
        { id = 3, team = nil }, { id = 4, team = nil }, { id = 5, team = nil },
    })
    t.isTrue(uncapped)
end)

-- ======================================================================
-- THE SHIPPED CONFIG AND WHAT IT PROMISES
--
-- Two comments in config.lua described behaviour this file does not have.
-- The comments were corrected rather than the code; these pin the shape the
-- corrected comments now describe, so the next edit to either notices.
-- ======================================================================

t.test('a weapon asked for with no ammo count is handed its catalogue default', function()
    -- ResolveAmmo rule 3: anything non-numeric gets the default. The panel
    -- sends no ammo for a weapon whose picker is off, so this is the path a
    -- real request takes far more often than the one that names a number.
    local loadout = Arena.ResolveLoadout({ weapons = { { key = 'rifle' }, { key = 'pistol' } } })

    t.equals(loadout.weapons[1].weapon, 'WEAPON_ASSAULTRIFLE')
    t.equals(loadout.weapons[1].ammo, Arena.GetWeaponByKey('rifle').ammo.default)
    t.equals(loadout.weapons[2].ammo, Arena.GetWeaponByKey('pistol').ammo.default)
end)

t.test('every shipped weapon with no ammo picker is pinned by max, not by trust', function()
    -- ResolveAmmo rule 2: no `options` list means free-form, clamped into
    -- [0, max]. The panel shows no ammo row for those, so an honest client
    -- asks for nothing and gets `default` -- but `max` is what a modified one
    -- is held to, which is why every no-picker weapon that ships sets the two
    -- to the same number.
    for _, weapon in ipairs(stock.Arena.GetEnabledWeapons()) do
        if #Arena.GetAmmoOptions(weapon) == 0 then
            t.equals(weapon.ammo.max, weapon.ammo.default,
                weapon.key .. ' has no picker but leaves headroom above its default')
            t.equals(Arena.ResolveAmmo(weapon, 99999), weapon.ammo.default, weapon.key)
        end
    end
end)

os.exit(t.summary())
