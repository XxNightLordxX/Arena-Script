package.path = './?.lua;' .. package.path
local t = dofile('testkit.lua')

-- ========================================================================
-- THE NATIVES THAT CANNOT BE PUT BACK
--
-- CitizenFX ships a setter and no getter for SetMaxWantedLevel,
-- SetCreateRandomCops and SetPlayerHealthRechargeMultiplier. All three are
-- WORLD-WIDE or session-wide for the player they are set on, so a match that
-- changes one can never restore it -- there is nothing to read the old value
-- from, and handing back the stock value is a guess that silently overwrites
-- whatever the operator configured.
--
-- client/dispatch.lua says exactly that in a comment above ENTER / EXIT, and
-- then something called one anyway: the revive ended with
-- SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0).
--
-- That was not a small slip. Revive runs on the way OUT of a match as well as
-- inside one, so a player who fought a single round left the arena with
-- health regeneration switched off for the rest of their session, everywhere
-- on the server, with nothing anywhere able to switch it back on.
--
-- A comment stating an invariant is not an invariant. This file is.
-- ========================================================================

local FORBIDDEN = {
    'SetPlayerHealthRechargeMultiplier',
    'SetCreateRandomCops',
    'SetMaxWantedLevel',
}

--- The file's text, with comment lines removed.
---
--- Every one of these names is DISCUSSED in the comments of the file that
--- must not call them -- that is the whole point of the note above ENTER /
--- EXIT -- so a plain search finds the explanation and reports it as the
--- offence. Only code counts.
local function codeOf(path)
    local handle = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local source = handle:read('a')
    handle:close()

    local kept = {}
    for line in (source .. '\n'):gmatch('(.-)\n') do
        -- Whole-line comments only. A trailing comment on a line of code
        -- leaves the code, which is the half being examined.
        if not line:match('^%s*%-%-') then kept[#kept + 1] = line end
    end
    return table.concat(kept, '\n')
end

for _, native in ipairs(FORBIDDEN) do
    t.test(('client/dispatch.lua never calls %s -- it cannot be put back'):format(native), function()
        local code = codeOf('../client/dispatch.lua')

        t.notContains(code, native .. '(',
            ('%s is called in client/dispatch.lua. It has a setter and no getter, so whatever it '):format(native)
            .. 'changes is changed for the rest of that player\'s session and this resource cannot undo it. '
            .. 'If it is genuinely wanted, it needs a config key carrying the value to restore TO -- see the '
            .. 'note above ENTER / EXIT in that file.')
    end)
end

t.test('and the file still explains why, so the next person does not re-add it', function()
    -- The rule above is only enforceable if the reasoning survives next to
    -- it. A test that fails with no explanation in the file it guards is a
    -- test somebody deletes.
    local handle = assert(io.open('../client/dispatch.lua', 'r'))
    local source = handle:read('a')
    handle:close()

    t.contains(source, 'none of them can be read',
        'the note explaining why these three are never called has gone -- without it the rule reads as arbitrary')
end)

t.test('and the client has no revive left to put it back in', function()
    -- WHERE THE BUG WENT IN, and where it can no longer go. The note used to
    -- live inside ArenaDispatch.Revive on the client, warning whoever
    -- touched it not to reach for the recharge multiplier. That whole
    -- function is gone -- the arena does not stand players up itself any
    -- more -- so the note has nowhere to be and the assertion becomes the
    -- stronger one: the function is not there to regress.
    local handle = assert(io.open('../client/dispatch.lua', 'r'))
    local source = handle:read('a')
    handle:close()

    t.isNil(source:match('function ArenaDispatch%.Revive%s*%('),
        'the client revive came back -- with it comes the setter that has no getter')
    t.isNil(source:match('function ArenaDispatch%.RevivePersistently'),
        'the persistent revive came back')
end)

print('unrestorable_spec')
os.exit(t.summary())
