package.path = './?.lua;' .. package.path
local t = dofile('testkit.lua')

-- ========================================================================
-- THE PANEL AND THE CLIENT RELAY, CHECKED AGAINST EACH OTHER
--
-- This is the seam that has broken more often than any other in this build,
-- and it breaks silently every time, because BOTH ENDS ARE RIGHT.
--
-- html/app.js computes a value and posts it. server/main.lua reads it and
-- uses it. Between them sits one relay in client/ui.lua that has to name
-- every field by hand, and a name left out of that list is not an error --
-- it is a nil, and a nil is indistinguishable from "the host did not choose",
-- so the server falls back to the operator's default and reports success.
--
-- Two real defects, both found only from a live server:
--
--   1. `lives` was missing from the createMatch relay. Every match was
--      created with the default number of lives whatever the host typed.
--      A panel test proved the panel posted the right number. It did. The
--      relay threw it away.
--
--   2. `updateMatch` was not registered AT ALL. The panel posted it, the
--      server listened for it, and nothing on the client joined them up, so
--      the host's "Apply changes" button did nothing at all -- silently,
--      because a fetch to an unregistered NUI callback still gets answered
--      by the runtime.
--
-- Neither could be caught by testing either end. Only by comparing them.
-- ========================================================================

--- @param path string
--- @return string
local function read(path)
    local handle = assert(io.open(path, 'r'), 'cannot open ' .. path)
    local source = handle:read('a')
    handle:close()
    return source
end

local PANEL = read('../html/app.js')
local RELAY = read('../client/ui.lua')

--- Every name the panel posts to, in source order.
local function panelPosts()
    local names, seen = {}, {}
    for name in PANEL:gmatch("post%(%s*'([%a_][%w_]*)'") do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    return names
end

--- Every name client/ui.lua registers a handler for.
local function relayRegisters()
    local set = {}
    for name in RELAY:gmatch("register%(%s*'([%a_][%w_]*)'") do set[name] = true end
    return set
end

--- The body of one register('name', ...) block, up to the matching `end)`.
local function relayBody(name)
    return RELAY:match("register%('" .. name .. "'.-\nend%)")
end

--- The object literal the panel passes to post('name', { ... }).
local function panelPayload(name)
    return PANEL:match("post%('" .. name .. "',%s*(%b{})")
end

--- Field names in an object literal, ignoring nested ones.
local function fieldsOf(literal)
    local names = {}
    if not literal then return names end
    for field in literal:gmatch("[{,]%s*([%a_][%w_]*)%s*:") do names[#names + 1] = field end
    return names
end

-- ------------------------------------------------------------------
-- Nothing the panel calls may be missing from the relay
-- ------------------------------------------------------------------

t.test('every callback the panel posts to is registered on the client', function()
    local registered = relayRegisters()
    local posts = panelPosts()

    t.isTrue(#posts > 5, 'no post() calls were found at all, so this test proved nothing')

    local missing = {}
    for _, name in ipairs(posts) do
        if not registered[name] then missing[#missing + 1] = name end
    end

    t.equals(table.concat(missing, ', '), '',
        'the panel posts to a callback client/ui.lua never registers. The button does nothing and says nothing -- '
        .. 'an unregistered NUI callback is answered by the runtime, so the panel cannot tell')
end)

-- ------------------------------------------------------------------
-- And nothing the panel sends may be dropped in the relay
-- ------------------------------------------------------------------

--- The payloads worth checking field-by-field: the ones carrying a host's
--- choice, where a dropped field silently becomes the operator's default.
local CHECKED = { 'createMatch', 'updateMatch', 'joinMatch' }

for _, name in ipairs(CHECKED) do
    t.test(('every field the panel sends to %s is forwarded by the relay'):format(name), function()
        local payload = panelPayload(name)
        t.isNotNil(payload, ('the panel no longer posts a %s payload this test can read'):format(name))

        local body = relayBody(name)
        t.isNotNil(body, ('client/ui.lua does not register %s'):format(name))

        local dropped = {}
        for _, field in ipairs(fieldsOf(payload)) do
            -- The relay names each field on the right of an assignment:
            --   lives = data.lives,
            if not body:find('data%.' .. field) then dropped[#dropped + 1] = field end
        end

        t.equals(table.concat(dropped, ', '), '',
            ('the panel sends these to %s and the relay never reads them. They arrive at the server as nil, which is '):format(name)
            .. 'indistinguishable from "the host did not choose" -- so the server falls back to the default and reports success')
    end)
end

-- ------------------------------------------------------------------
-- The two specific regressions, named, so a failure says which
-- ------------------------------------------------------------------

t.test('createMatch forwards the number of lives the host typed', function()
    local body = relayBody('createMatch')
    t.isNotNil(body)
    t.contains(body, 'data.lives',
        'the lives box is back to being decoration -- the host types a number and every match is created on the default')
end)

t.test('updateMatch exists, so Apply changes reaches the server', function()
    t.isTrue(relayRegisters()['updateMatch'] == true,
        'the host edit form posts to a callback that does not exist, so Apply changes does nothing at all')

    local body = relayBody('updateMatch')
    t.isNotNil(body)
    t.contains(body, 'crimson_arena:server:updateMatch',
        'updateMatch is registered but does not trigger the server event the server is listening for')
    t.contains(body, 'data.lives', 'the host can edit a lobby but not the thing they most want to edit')
end)

t.test('and updateMatch does NOT send an entry fee, which the server refuses', function()
    -- Not pedantry: the fee is frozen once money has been taken, so sending
    -- one would be the panel asking for something it has just told the player
    -- it cannot have.
    local body = relayBody('updateMatch')
    t.isNotNil(body)
    t.notContains(body, 'entryFee',
        'the edit relay sends an entry fee the server will refuse')
end)

print('nuicontract_spec')
os.exit(t.summary())
