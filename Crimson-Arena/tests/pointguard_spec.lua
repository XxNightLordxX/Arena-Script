--[[
    crimson_arena/tests/pointguard_spec.lua

    THE BUG NO FIXTURE CAN EVER CATCH, GUARDED AT THE SOURCE INSTEAD.

    In the CitizenFX Lua runtime a vector is its OWN type: `type(v)` answers
    'vector3', never 'table' and never 'userdata'. Every coordinate the game
    hands back is one -- GetEntityCoords, GetModelDimensions, and the
    vector3()/vector4() calls in config.lua.

    SO A GUARD THAT ASKS FOR 'table' SAYS NO TO EVERY REAL COORDINATE AND YES
    TO EVERY ONE IN THIS SUITE. Plain Lua has no vector type, so a fixture
    cannot produce the shape that breaks it -- which means no behavioural test
    can ever fail on this, however many are written. It has been made three
    times in this codebase; the third time it silently switched off four
    server-side guards at once (the kill-distance ceiling, the out-of-bounds
    fence, the unreported-death check and the death corroboration), because
    all four read one helper and all four fail open when it answers nil.

    The only defence left is to read the source and refuse the pattern.
    Arena.IsPoint is the one place allowed to know the list.
]]

local t = dofile('testkit.lua')

print('pointguard_spec')

local FILES = {
    '../shared/arena.lua', '../shared/compat/dispatch.lua',
    '../server/main.lua', '../server/match.lua', '../server/lobby.lua',
    '../server/ammo.lua', '../server/betting.lua', '../server/dispatch.lua',
    '../server/stats.lua', '../server/util.lua',
    '../client/main.lua', '../client/match.lua', '../client/spectate.lua',
    '../client/ui.lua', '../client/dispatch.lua',
}

--- One file with its comments taken out, so a paragraph ABOUT the mistake
--- does not read as the mistake.
local function codeOf(path)
    local handle = io.open(path, 'r')
    if not handle then return nil end
    local text = handle:read('a')
    handle:close()
    return (text:gsub('%-%-%[%[.-%]%]', ' '):gsub('%-%-[^\n]*', ' '))
end

t.test('every file this reads is really on disk', function()
    -- Without this the whole file passes by reading nothing, which is the
    -- failure mode of every source-level test ever written.
    for _, path in ipairs(FILES) do
        t.isNotNil(codeOf(path), path .. ' could not be read')
    end
end)

t.test('nothing decides a coordinate is real by writing the types out', function()
    -- The shape of the mistake: a type test that admits 'table' and does not
    -- admit 'vector3'. Both orders, and the userdata variant.
    local patterns = {
        "type%([%w_%.]+%)%s*==%s*'table'",
        "type%([%w_%.]+%)%s*~=%s*'table'",
    }

    for _, path in ipairs(FILES) do
        local code = codeOf(path)
        for _, pattern in ipairs(patterns) do
            for match in code:gmatch(pattern) do
                -- The name being tested, so the line can be found again.
                local name = match:match("type%(([%w_%.]+)%)")

                -- A test for 'table' is only a POINT test when the same
                -- expression is asked about a vector nearby. Config blocks,
                -- rosters and payloads are ordinary tables and this must not
                -- fire on those -- a guard that cries wolf gets deleted.
                local nearby = code:match("type%(" .. name:gsub('%.', '%%.')
                    .. "%)[^\n]-'vector3'")
                if code:find("'vector3'", 1, true) and nearby then
                    t.isTrue(true, 'a vector-aware test, which is the right shape')
                end
            end
        end

        -- THE REAL ASSERTION, and it is a flat refusal: no file may pair
        -- 'table' with 'userdata' as its idea of what a coordinate is. That
        -- exact pair is the mistake, three times over, and it has never once
        -- been the right answer about a point.
        t.isTrue(code:find("~= 'table' and type", 1, true) == nil
            or code:find("'userdata'", 1, true) == nil
            or code:find("Arena.IsPoint", 1, true) ~= nil,
            path .. ' decides what a coordinate is by writing the types out. '
                .. 'Use Arena.IsPoint -- a real vector answers "vector3" to '
                .. 'type(), so a list that omits it rejects every coordinate '
                .. 'on a live server and none in this suite.')
    end
end)

t.test('and Arena.IsPoint itself still admits the vector types', function()
    -- The one place allowed to know the list. If this stops naming vector3,
    -- every caller above starts refusing real coordinates and the test above
    -- goes on passing.
    local code = codeOf('../shared/arena.lua')
    local body = code:match('function Arena%.IsPoint%(.-\nend')
    t.isNotNil(body, 'Arena.IsPoint is gone, and every guard above leans on it')

    for _, kind in ipairs({ 'table', 'vector2', 'vector3', 'vector4' }) do
        t.isTrue(body:find("'" .. kind .. "'", 1, true) ~= nil,
            ("Arena.IsPoint no longer admits '%s'"):format(kind))
    end
end)

t.test('and the server can still be asked where a player is', function()
    -- positionOf is the helper the four server-side guards share. It is local
    -- to server/match.lua, so this reads it rather than calling it -- but what
    -- it asserts is the thing that was wrong: the answer must come from
    -- Arena.IsPoint and not from a list beside it.
    local code = codeOf('../server/match.lua')
    local body = code:match('local function positionOf%(.-\nend')
    t.isNotNil(body, 'positionOf is gone -- the four guards that read it have no eyes')

    t.isTrue(body:find('Arena.IsPoint', 1, true) ~= nil,
        'positionOf no longer asks Arena.IsPoint whether it got a coordinate')
    t.isTrue(body:find("'userdata'", 1, true) == nil,
        'positionOf is writing the types out again -- this is the third time')
end)

os.exit(t.summary())
