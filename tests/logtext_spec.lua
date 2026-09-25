--[[
    crimson_arena/tests/logtext_spec.lua

    WHAT A PLAYER CAN PUT INTO THE CONSOLE, AND WHAT COMES OUT.

    Two functions in server/util.lua stand between a player-chosen string
    and the operator's console. ArenaLogText cleans a NAME for the lines
    that quote one: one line, bounded, no colour codes, no quote that closes
    the quotes it sits in. And the composer behind ArenaLog and ArenaDebug
    cleans every FINISHED line, whatever went into it, so a line that prints
    a name raw cannot start another line either.

    Before this file, one test covered ArenaLogText -- a '\n', an ESC, a '^'
    and a quote in one killer's name -- and nine separate changes to the
    function survived the whole suite: C1 left in, the line separators left
    in, DEL, TAB and NUL left in, no length cap, a cut on a byte, nil
    answered with nothing. One of the gaps was live: a '^' taken out LAST
    rebuilt the very sequences the passes before it had looked for.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('logtext_spec')

--- util.lua on its own, with the console captured.
local function newUtil(debug)
    local console = {}
    local env = Sandbox.newArenaEnv({ print = function(line) console[#console + 1] = line end })
    env.Config.Debug = debug == true
    Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
    return env, console
end

local function hex(text)
    return (tostring(text):gsub('.', function(c) return ('%02X '):format(c:byte()) end))
end

--- No byte or sequence in `text` that a console treats as anything but text.
local function dangerIn(text)
    if text:find('[%z\1-\31\127]') then return 'a C0 control or DEL' end
    if text:find('\194[\128-\159]') then return 'a C1 control' end
    if text:find('\226\128[\168-\174]') then return 'a line separator or a bidi override' end
    if text:find('\226\129[\166-\169]') then return 'a bidi isolate' end
    if not utf8.len(text) then return 'invalid UTF-8' end
    return nil
end

-- ======================================================================
-- ArenaLogText, ONE INPUT AT A TIME
-- ======================================================================

t.test('ArenaLogText: every control a name can carry becomes a space', function()
    local env = newUtil()
    local cases = {
        { 'a line feed', 'a\nb', 'a b' },
        { 'SOH, the bottom of C0', 'a\1b', 'a b' },
        { 'US, the top of C0', 'a\31b', 'a b' },
        { 'U+0080, the bottom of C1', 'a\194\128b', 'a b' },
        { 'U+009F, the top of C1', 'a\194\159b', 'a b' },
        { 'a carriage return', 'a\rb', 'a b' },
        { 'a tab', 'a\tb', 'a b' },
        { 'a NUL', 'a\0b', 'a b' },
        { 'a bell', 'a\7b', 'a b' },
        { 'an ESC', 'a\27b', 'a b' },
        { 'DEL', 'a\127b', 'a b' },
        { 'C1 NEL', 'a\194\133b', 'a b' },
        { 'C1 CSI', 'a\194\155b', 'a b' },
        { 'U+2028 line separator', 'a\226\128\168b', 'a b' },
        { 'U+2029 paragraph separator', 'a\226\128\169b', 'a b' },
        { 'U+202E right-to-left override', 'a\226\128\174b', 'a b' },
        { 'U+202A left-to-right embedding', 'a\226\128\170b', 'a b' },
        { 'U+2066 left-to-right isolate', 'a\226\129\166b', 'a b' },
        { 'U+2069 pop directional isolate', 'a\226\129\169b', 'a b' },
    }
    for _, case in ipairs(cases) do
        local label, input, want = case[1], case[2], case[3]
        local got = env.ArenaLogText(input)
        t.equals(got, want, ('%s came out as %s'):format(label, hex(got)))
    end
end)

t.test('ArenaLogText: colour codes go, and a quote cannot close the quotes it sits in', function()
    local env = newUtil()
    t.equals(env.ArenaLogText('^1Red^7Name'), '1Red7Name', 'a colour code survived')
    t.equals(env.ArenaLogText('say "hi"'), "say 'hi'", 'a double quote survived')
end)

t.test('THE SPLIT: a \'^\' inside a control sequence does not rebuild it when it is taken out', function()
    -- '^' is the one thing removed rather than replaced, so taking it out
    -- joins the bytes either side. Taken out LAST, it rebuilt what the
    -- earlier passes had looked for and not found.
    local env = newUtil()
    local cases = {
        { 'a split NEL', 'Evil\194^\133[crimson_arena] match m1 ended', 'Evil [crimson_arena] match m1 ended' },
        { 'a split CSI', 'X\194^\1552J', 'X 2J' },
        { 'a split line separator', 'E\226^\128^\168x', 'E x' },
        { 'a split override', 'E\226^\128^\174x', 'E x' },
    }
    for _, case in ipairs(cases) do
        local got = env.ArenaLogText(case[2])
        t.equals(got, case[3], ('THE DEFECT: %s came out as %s'):format(case[1], hex(got)))
    end
end)

t.test('ArenaLogText: bytes that are not UTF-8 do not reach the console', function()
    -- The console is UTF-8, and every line is kept valid UTF-8 so the C1,
    -- separator and bidi passes see characters rather than stray bytes they
    -- cannot match. (An 8-bit console is NOT defended: valid letters carry
    -- the same bytes -- see validUtf8 in server/util.lua.)
    local env = newUtil()
    t.equals(env.ArenaLogText('a\133b\155c'), 'a?b?c', 'lone high bytes survived')
    t.equals(env.ArenaLogText('\192\138'), '??', 'an overlong line feed survived')
    -- STRICT UTF-8: a surrogate encoded on its own is not a character, and a
    -- lax reading would pass it to the console.
    t.equals(env.ArenaLogText('a\237\160\128b'), 'a???b', 'an encoded surrogate survived')
    t.equals(env.ArenaLogText('Omega \226\137\136 sigma'), 'Omega \226\137\136 sigma', 'valid UTF-8 was mangled')
    t.equals(env.ArenaLogText('Jos\195\169'), 'Jos\195\169', 'an accented letter was mangled')
end)

t.test('ArenaLogText: bounded, and cut on a character, never through one', function()
    local env = newUtil()

    t.equals(env.ArenaLogText(string.rep('a', 100)), string.rep('a', 48) .. '...', 'the default cap is not 48 bytes')
    t.equals(env.ArenaLogText(string.rep('a', 48)), string.rep('a', 48), 'a name exactly at the cap was cut')

    -- A WHOLE CHARACTER ENDING EXACTLY AT THE CAP IS KEPT. The pattern this
    -- used to cut with dropped it along with any broken one.
    t.equals(env.ArenaLogText(string.rep('a', 46) .. '\195\169b'), string.rep('a', 46) .. '\195\169...',
        'a complete character at the edge of the cut was dropped')

    -- AND ONE THE CUT LANDS INSIDE GOES, rather than half of it.
    local through = env.ArenaLogText(string.rep('a', 47) .. '\195\169b')
    t.equals(through, string.rep('a', 47) .. '...', 'a cut through a character was not stepped back')
    t.isTrue(utf8.len(through) ~= nil, 'the cut left broken UTF-8 behind: ' .. hex(through))

    t.equals(env.ArenaLogText(string.rep('a', 40), 16), string.rep('a', 16) .. '...', 'a cap of 16 was ignored')

    -- MEASURED AFTER CLEANING: a colour code does not count against the cap.
    t.equals(env.ArenaLogText('^1' .. string.rep('a', 47)), '1' .. string.rep('a', 47),
        'the cap was measured before the colour code came out')
    t.equals(env.ArenaLogText('abcdef', '3'), 'abc...', 'a cap given as text was ignored')
    t.equals(env.ArenaLogText(string.rep('a', 60), 0), string.rep('a', 48) .. '...', 'a cap of 0 did not fall back to 48')
    t.equals(env.ArenaLogText(string.rep('a', 60), -1), string.rep('a', 48) .. '...', 'a negative cap did not fall back to 48')
end)

t.test('ArenaLogText: nil is a question mark, and anything else is its text', function()
    local env = newUtil()
    t.equals(env.ArenaLogText(nil), '?', 'nil did not come out as ?')
    t.equals(env.ArenaLogText(42), '42', 'a number was not printed')
    t.equals(env.ArenaLogText(true), 'true', 'a boolean was not printed')
end)

t.test('ArenaLogText: two thousand random names, and nothing dangerous comes out of any of them', function()
    -- Seeded, so a failure names its input and happens again. The alphabet
    -- is weighted towards the bytes every trick above is made of.
    local env = newUtil()
    local seed = 20260925
    local function nextNumber(limit)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % limit
    end
    local pieces = { '^', '"', '\n', '\27', '\194', '\133', '\155', '\226', '\128', '\168', '\174', '\129',
        '\166', '\169', '\195', '\169', '\240', '\159', '\152', 'a', 'Z', ' ', '%', '\0', '\127', '\255' }

    for round = 1, 2000 do
        local parts = {}
        for index = 1, nextNumber(40) do parts[index] = pieces[nextNumber(#pieces) + 1] end
        local input = table.concat(parts)
        local out = env.ArenaLogText(input, 1 + nextNumber(60))

        local danger = dangerIn(out)
        t.isNil(danger, ('round %d: %s came out of %s as %s'):format(round, tostring(danger), hex(input), hex(out)))
        t.isNil(out:find('^', 1, true), ('round %d: a colour code survived %s'):format(round, hex(input)))
        t.isNil(out:find('"', 1, true), ('round %d: a double quote survived %s'):format(round, hex(input)))
        if danger then break end
    end
end)

t.test('ArenaLogText: a thousand names built from whole characters, split by carets, and nothing dangerous comes out', function()
    -- The byte fuzz above is flattened to '?' almost every time -- random
    -- bytes are rarely valid UTF-8 -- so it hardly reaches the passes that
    -- look for C1, the separators and the bidi controls. These are built
    -- from whole characters, most of them dangerous, with carets pushed in
    -- between their bytes, so most survive the caret and reach every pass.
    local env = newUtil()
    local seed = 4242
    local function nextNumber(limit)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % limit
    end
    local characters = { '\194\133', '\194\155', '\194\128', '\194\159', '\226\128\168', '\226\128\169',
        '\226\128\174', '\226\128\170', '\226\129\166', '\226\129\169', '\195\169', '\240\159\152\128',
        '\n', '\27', '\0', '\127', '\t', '"', '%', 'a', 'Z', ' ' }

    local reachedPasses = 0
    for round = 1, 1000 do
        local bytes = {}
        for _ = 1, 1 + nextNumber(12) do
            local character = characters[nextNumber(#characters) + 1]
            for index = 1, #character do
                bytes[#bytes + 1] = character:sub(index, index)
                if nextNumber(3) == 0 then bytes[#bytes + 1] = string.rep('^', 1 + nextNumber(2)) end
            end
        end
        local input = table.concat(bytes)
        if utf8.len((input:gsub('%^', ''))) then reachedPasses = reachedPasses + 1 end

        local out = env.ArenaLogText(input, 1 + nextNumber(60))
        local danger = dangerIn(out)
        t.isNil(danger, ('round %d: %s came out of %s as %s'):format(round, tostring(danger), hex(input), hex(out)))
        t.isNil(out:find('^', 1, true), ('round %d: a colour code survived %s'):format(round, hex(input)))
        if danger then break end
    end
    t.isTrue(reachedPasses >= 900, ('only %d of 1000 names reached the control passes, so this tests little'):format(reachedPasses))
end)

-- ======================================================================
-- THE COMPOSER: EVERY LINE, WHATEVER WENT INTO IT
-- ======================================================================

t.test('THE COMPOSER: a name printed raw cannot forge a second line', function()
    -- Measured through the side-bet lines: a spectator named with a new line
    -- and a fake KILL record got that record printed as a line of its own.
    local env, console = newUtil()
    env.ArenaLog('SIDE-BET UNCONTESTED: nobody bet against %s', 'Watcher\n[crimson_arena] KILL: "Admin" (1 CID001)')

    t.equals(#console, 1, 'one call printed more than one line')
    t.isNil(console[1]:find('\n', 1, true), 'THE DEFECT: a raw name put a line break into the console')
    t.equals(console[1]:sub(1, 36), '[crimson_arena] SIDE-BET UNCONTESTED', 'the line does not start as the resource wrote it')
end)

t.test('and it strips the same controls ArenaLogText does, from any argument', function()
    local env, console = newUtil()
    local inputs = {
        'a\27[2Jb', 'a\194\133b', 'a\194\155b', 'a\226\128\168b', 'a\226\128\174b', 'a\226\129\166b',
        'a\133b', 'a\0b', 'a\127b', 'a\rb', 'a\tb',
    }
    for _, input in ipairs(inputs) do env.ArenaLog('value %s end', input) end
    t.equals(#console, #inputs, 'a line went missing')
    for index, line in ipairs(console) do
        t.isNil(dangerIn(line), ('%s came out as %s'):format(hex(inputs[index]), hex(line)))
    end
end)

t.test('and it keeps everything that is not dangerous, the resource\'s own text included', function()
    local env, console = newUtil()
    env.ArenaLog('caf\195\169 %s at %d%%', 'Jos\195\169 "quoted"', 50)
    t.equals(console[1], '[crimson_arena] caf\195\169 Jos\195\169 "quoted" at 50%',
        'the composer changed text that was never dangerous')

    -- A BAD BYTE IN ONE ARGUMENT COSTS ONLY THAT ARGUMENT: it is made valid
    -- before it goes into the line, so the resource's own characters stay.
    env.ArenaLog('caf\195\169 %s', 'x\133y')
    t.equals(console[2], '[crimson_arena] caf\195\169 x?y', 'a bad byte in an argument mangled the rest of the line')

    env.ArenaLog('%d kills', 'not a number')
    t.equals(console[3], '[crimson_arena] %d kills', 'a format that fails no longer falls back to its own text')

    env.ArenaLog('no arguments at all, 100%')
    t.equals(console[4], '[crimson_arena] no arguments at all, 100%', 'a line with no arguments was changed')

    -- A TRAILING nil IS STILL AN ARGUMENT: unpacked without the count it was
    -- dropped, the format failed, and the line lost everything in it.
    env.ArenaLog('a %s b %s', 'x', nil)
    t.equals(console[5], '[crimson_arena] a x b nil', 'a trailing nil argument cost the line its data')
end)

t.test('and a name cannot repaint the line: colour codes go from every argument, not the format', function()
    -- '^1' is FiveM's red: a name carrying '^1SCRIPT ERROR: ...' printed raw
    -- inside an arena line wore the server's own error styling.
    local env, console = newUtil()
    env.ArenaLog('%s revived %s from the admin tablet', 'Admin', '^1SCRIPT ERROR: @crimson_arena/server/betting.lua:1551^7')
    t.equals(console[1], '[crimson_arena] Admin revived 1SCRIPT ERROR: @crimson_arena/server/betting.lua:15517 from the admin tablet',
        'a colour code in an argument reached the console')

    -- A RUN OF CARETS goes with the digit, or taking one out leaves the next.
    env.ArenaLog('x %s', '^^1red^^^2green')
    t.equals(console[2], '[crimson_arena] x 1red2green', 'a doubled caret left a colour code behind')

    -- A caret that is not a colour code stays, and the resource's own format
    -- string is never touched.
    env.ArenaLog('^3own %s', 'a^b 2^')
    t.equals(console[3], '[crimson_arena] ^3own a^b 2^', 'the composer touched text that was not a colour code')
end)

t.test('and ArenaDebug goes through it too, and prints nothing with Debug off', function()
    local on, onConsole = newUtil(true)
    on.ArenaDebug('who %s', 'x\ny')
    t.equals(#onConsole, 1, 'the debug line was not printed')
    t.equals(onConsole[1], '[crimson_arena] [debug] who x y', 'the debug line was not cleaned')

    local off, offConsole = newUtil(false)
    off.ArenaDebug('who %s', 'x')
    t.equals(#offConsole, 0, 'a debug line printed with Debug off')
end)

os.exit(t.summary())
