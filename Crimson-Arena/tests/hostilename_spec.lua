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
        GetPlayerRoutingBucket = function() return 0 end,
        SetPlayerRoutingBucket = function() end,
        SetRoutingBucketPopulationEnabled = function() end,
        SetRoutingBucketEntityLockdownMode = function() end,
        GetConvar = function(n, fb) if n == 'onesync' then return 'on' end return fb end,
        CancelEvent = function() end,
        NetworkGetNetworkIdFromEntity = function() return 0 end,
        PerformHttpRequest = function(_, _, _, payload) captured.webhook = payload end,
        ArenaStats = { GetLeaderboard = function(cb) cb({}) end, EnsureSchema = function() end,
                       RecordMatch = function() end, Flush = function() end },
        ArenaAmmo = { IsEnabled = function() return false end, Issue = function() return {} end,
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
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
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
    local source = assert(io.open('../html/app.js', 'r'), 'html/app.js is missing')
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

os.exit(t.summary())
