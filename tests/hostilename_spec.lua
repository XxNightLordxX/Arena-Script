--[[
    crimson_arena/tests/hostilename_spec.lua

    A PLAYER'S NAME IS ATTACKER-CONTROLLED, AND IT GOES EVERYWHERE.

    It is the one string in this resource that somebody hostile chooses and
    the server then puts through a formatter, a JSON encoder, a Discord post
    and a snapshot sent to every other client. Nothing else a player controls
    travels that far.

    Every one of those is a classic injection sink, and the code is careful
    about all of them today -- ArenaLog's format string is always a literal,
    the webhook body is built by json.encode rather than concatenation, and
    the panel writes text with textContent. This file is what stops a later
    edit quietly undoing any of that.

    WHAT IT CANNOT CHECK. The real escaping is FiveM's own json.encode; this
    runs against the sandbox's model of it. So "the name did not break out of
    its string" is a statement about the SHAPE of what we hand over -- a table
    with the name as a value -- rather than proof about the C encoder. The
    thing worth guarding is that we never go around it, and that is what an
    assertion on the encoded payload actually pins.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('hostilename_spec')

--- Names a player can really set, each aimed at a different sink.
local NAMES = {
    ['a format string']        = '%s%s%s%s',
    ['a lone percent']         = '%',
    ['a %q verb']              = '%q',
    ['an HTML tag']            = '"><img src=x onerror=alert(1)>',
    ['a script tag']           = '</script><script>alert(1)</script>',
    ['a SQL fragment']         = "'; DROP TABLE crimson_arena_stats; --",
    ['a Discord mention']      = '@everyone',
    ['embedded JSON']          = '{"injected":true}',
    ['a quote and a brace']    = '"}{"',
    ['500 characters']         = string.rep('A', 500),
    ['control characters']     = '\0\1\2',
    ['multi-byte UTF-8']       = 'Omega \226\137\136 sigma',
    -- THE ONE THAT CUT IN HALF. Nine ASCII characters then thirty emoji: at
    -- 128 BYTES the cut lands three bytes into a four-byte character, and
    -- MySQL refuses a row carrying invalid UTF-8 exactly as it refuses an
    -- emoji into latin1. 39 characters is the smallest name that does it.
    ['a name that cuts mid-character'] = 'Big Mike ' .. string.rep('\240\159\152\128', 30),
    ['129 plain characters']   = string.rep('A', 129),
}

--- A whole server whose only player is called `name`.
local function serverNamed(name)
    local players = { [1] = {
        citizenid = 'CID001', name = name,
        money = { cash = 50000, bank = 50000 },
        job = { name = 'unemployed', grade = { level = 0 } },
    } }
    local qbx = Sandbox.newQbxCore(players)
    local netEvents, captured, clock = {}, {}, 0

    -- REAL, NOT NO-OPS. These answered 0 and did nothing, which is exactly
    -- what FXServer does when routing buckets are unavailable -- so
    -- server/dispatch.lua caught the move not landing, latched provenInert
    -- and switched isolation off for this whole fixture. Every bucket line
    -- in the file it loads was dead here, and anything in this spec's own
    -- subject that touches instancing was being asked of a server that had
    -- none.
    local buckets = {}

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = function() end, Wait = function() end, SetTimeout = function() end,
        print = function() end,
        TriggerClientEvent = function() end,
        RegisterNetEvent = function(n, fn) netEvents[n] = fn end,
        AddEventHandler = function() end, RegisterCommand = function() end,
        GetGameTimer = function() clock = clock + 60000; return clock end,
        GetPlayerName = function() return name end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function() return { x = 0.0, y = 0.0, z = 0.0 } end,
        GetVehiclePedIsIn = function() return 0 end,
        GetPlayers = function() return {} end,
        Player = function() return { state = { set = function() end } } end,
        IsPlayerAceAllowed = function() return false end,
        GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end,
        SetPlayerRoutingBucket = function(src, b) buckets[tonumber(src)] = b end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(n, fb) if n == 'onesync' then return 'on' end return fb end,
        CancelEvent = function() end,
        NetworkGetNetworkIdFromEntity = function() return 0 end,
        PerformHttpRequest = function(_, _, _, payload) captured.webhook = payload end,
        ArenaStats = { GetLeaderboard = function(cb) cb({}) end, EnsureSchema = function() end,
                       RecordMatch = function() end, Flush = function() end },
        -- Refresh is in here because a stub missing it does not fail a test,
        -- it THROWS inside the respawn thread.
        ArenaAmmo = { IsEnabled = function() return false end, Issue = function() return {} end,
                      Refresh = function() return true end,
                      Reclaim = function() return 0 end, ReclaimAll = function() return 0 end,
                      Clear = function() return true end, OnLoan = function() return 0 end },
        ArenaDispatch = { Set = function() end, Clear = function() end, Revive = function() end,
                          IsPlayerInArena = function() return false end,
                          ClearDownState = function() return 0 end,
                          EnterBucket = function() end, ExitBucket = function() end,
                          GetBucket = function() end, ReleaseBucket = function() end },
    })
    env.Config.Webhook = { enabled = true, url = 'https://discord.example/hook', color = 0 }

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../Crimson-Arena/server/' .. file .. '.lua', env)
    end
    return env, netEvents, captured
end

t.test('a hostile name survives the whole server pipeline without throwing', function()
    -- THE FORMATTER IS THE LIKELIEST BREAK. ArenaLog takes a format string
    -- first; the day somebody writes ArenaLog(name) instead of
    -- ArenaLog('%s', name), a player called '%s%s%s%s' takes the round down.
    for label, name in pairs(NAMES) do
        local ok, err = pcall(function()
            local env, netEvents = serverNamed(name)

            local resolved = env.ArenaPlayerName(1)
            t.equals(type(resolved), 'string', label .. ': the name did not resolve to a string')

            env.ArenaLog('a player called %s did something', resolved)
            env.ArenaWebhook('Match over', resolved, { { name = 'Winner', value = resolved } })

            env.source = 1
            netEvents['crimson_arena:server:createMatch']({
                arenaKey = 'trailerpark', modeKey = 'ffa', lives = 3,
            })

            local snapshot = env.ArenaLobby.BuildState(1)
            t.equals(type(snapshot), 'table', label .. ': the snapshot was not built')
        end)
        t.isTrue(ok, ('%s took the server down: %s'):format(label, tostring(err)))
    end
end)

t.test('and reaches the webhook as DATA, never as syntax', function()
    -- The body is built by json.encode from a table. A rewrite that
    -- concatenated the name into a JSON string instead would let a name
    -- containing a quote and a brace close the value and open a new key --
    -- which is what this name is shaped to do.
    local env, _, captured = serverNamed('"}{"')
    env.ArenaWebhook('Match over', env.ArenaPlayerName(1), nil)

    local payload = captured.webhook
    t.isNotNil(payload, 'nothing was posted, so this asserts nothing')
    t.isTrue(payload:find('\\"', 1, true) ~= nil,
        'the quote in the name was not escaped: ' .. tostring(payload))
    t.isTrue(payload:find('"}{"', 1, true) == nil,
        'the name went in RAW and closed its own JSON string: ' .. tostring(payload))
end)

t.test('and the panel is given no way to execute it', function()
    -- The other end of the same string. A name is rendered by html/app.js,
    -- and the only thing standing between a player called
    -- '<img src=x onerror=...>' and script execution in everybody else's
    -- panel is that the panel never assigns markup.
    local source = assert(io.open('../Crimson-Arena/html/app.js', 'r'), 'html/app.js is missing')
    local js = source:read('a')
    source:close()

    -- Comments are stripped: the file DESCRIBES this rule in its own header,
    -- and a search that counted that sentence would pass forever.
    local code = js:gsub('/%*.-%*/', ' '):gsub('\n%s*//[^\n]*', '\n')

    for _, sink in ipairs({ 'innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document%.write' }) do
        t.isTrue(code:find(sink) == nil,
            ('html/app.js uses %s -- a player NAME is rendered through this panel')
                :format((sink:gsub('%%', ''))))
    end
    for _, sink in ipairs({ 'eval%(', 'new Function%(' }) do
        t.isTrue(code:find(sink) == nil,
            ('html/app.js uses %s'):format((sink:gsub('%%', ''))))
    end
end)

-- ========================================================================
-- A NAME THAT CUTS IN HALF IS A ROW MYSQL WILL NOT TAKE
-- ========================================================================
--
-- string.sub counts BYTES; the columns count CHARACTERS. A cut landing in
-- the middle of a multi-byte character produces a byte sequence that is not
-- valid UTF-8, and MySQL refuses the WHOLE ROW for it.
--
-- sql/install.sql has described this for a long time and called it unfixable
-- from SQL -- "The column cannot fix that; the cut has to be done in
-- characters. Nothing in this file can do it." It was right, and the cut was
-- being done in bytes at two sinks: the leaderboard name, and the name on a
-- row recording money the arena owes somebody.
--
-- IT TAKES A MIXTURE, which is what let it sit unnoticed. A pure-ASCII name
-- and a pure-emoji name both happen to land on the boundary and survive.

local env = Sandbox.newArenaEnv()
Sandbox.loadInto('../Crimson-Arena/server/util.lua', env)
local cut = env.ArenaCutText

t.test('CONTROL: a name that fits is returned untouched', function()
    t.equals(cut('John Allday', 128), 'John Allday', 'an ordinary name was altered')
    t.equals(cut('Omega \226\137\136 sigma', 128), 'Omega \226\137\136 sigma',
        'a short multi-byte name was altered')
end)

t.test('CONTROL: a long ASCII name is cut to the column width', function()
    local long = string.rep('A', 129)
    t.equals(#cut(long, 128), 128, 'a 129-character name was not brought within the column')
end)

t.test('THE DEFECT: a name that cuts mid-character comes back as valid UTF-8', function()
    local name = 'Big Mike ' .. string.rep('\240\159\152\128', 30)

    -- The premise: the OLD cut really does produce invalid UTF-8.
    t.isNil(utf8.len(name:sub(1, 128)),
        'a byte cut of this name is valid UTF-8, so this name cannot show the defect')

    local safe = cut(name, 128)
    t.isNotNil(utf8.len(safe),
        'THE CUT STILL SPLITS A CHARACTER -- MySQL refuses the whole row and the write is lost')
    t.isTrue(#safe <= 128, 'the cut no longer fits the column')
end)

t.test('and it gives back as much of the name as will fit', function()
    -- A fix that returned the empty string would pass the test above and be
    -- useless, so this is the other half.
    local name = 'Big Mike ' .. string.rep('\240\159\152\128', 30)
    local safe = cut(name, 128)
    t.isTrue(#safe > 120, ('only %d bytes survived, so the cut is throwing the name away'):format(#safe))
    t.equals(safe:sub(1, 9), 'Big Mike ', 'the readable part of the name was lost')
end)

t.test('and every hostile name in this file survives it as valid UTF-8', function()
    -- The whole corpus at the top, through the cut, because a name is a name.
    for label, name in pairs(NAMES) do
        local safe = cut(name, 128)
        t.isNotNil(utf8.len(safe) or (utf8.len(name) == nil and 0),
            ('%s came back as invalid UTF-8'):format(label))
        t.isTrue(#safe <= 128, ('%s came back too long for the column'):format(label))
    end
end)

os.exit(t.summary())
