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

os.exit(t.summary())
