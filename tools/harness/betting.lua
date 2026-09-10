-- Drives the pot through Settle: once, twice, and with the winner's server
-- id taken over by a different character before the round ends.
local ROOT = os.getenv('ARENA_ROOT') or '../../Crimson-Arena/'

local function run(scenario)
    local threads, lines = {}, {}
    local paid = {}                       -- citizenid -> money actually credited
    local owedTo = {}                     -- citizenid -> money filed as unpaid
    -- src 1 is the winner; who answers to that id is the scenario's business
    local liveCitizen = { [1] = 'CID_WIN', [2] = 'CID_LOSE' }

    _ENV.CreateThread = function(fn) threads[#threads + 1] = fn end
    _ENV.SetTimeout = function() end
    _ENV.Wait = function() error('yield', 0) end
    _ENV.AddEventHandler, _ENV.RegisterNetEvent = function() end, function() end
    _ENV.GetCurrentResourceName = function() return 'crimson_arena' end
    _ENV.GetPlayers = function() return { '1', '2' } end
    _ENV.GetResourceState = function() return 'missing' end
    _ENV.PerformHttpRequest = function() end
    _ENV.exports = setmetatable({}, { __index = function() return {} end })

    _ENV.ArenaLog = function(f, ...) lines[#lines + 1] = (select('#', ...) > 0)
        and tostring(f):format(...) or tostring(f) end
    _ENV.ArenaDebug, _ENV.ArenaNotifyKey, _ENV.ArenaToastKey = function() end, function() end, function() end
    _ENV.ArenaWebhook = function() end
    -- a raise OUTSIDE credit's pcall, which is what stops the payout loop
    -- part-way: credit catches everything the framework throws, but the
    -- logging around it is not wrapped
    local armed, blowUps = false, 0
    _ENV.ArenaPlayerName = function(s)
        if armed and s == 2 and blowUps == 0 then
            blowUps = 1
            error('a resource hooked into the money event blew up', 0)
        end
        return 'P' .. tostring(s)
    end
    _ENV.ArenaGetPlayer = function(src)
        local cid = liveCitizen[src]
        if not cid then return nil end
        return {
            PlayerData = { citizenid = cid, money = { cash = 100000, bank = 100000 } },
            Functions = {
                RemoveMoney = function() return true end,
                AddMoney = function(_, amount)
                    paid[cid] = (paid[cid] or 0) + amount
                    return true
                end,
            },
        }
    end
    _ENV.ArenaMatch, _ENV.ArenaLobby, _ENV.ArenaStats = {}, {}, {}
    _ENV.Arena = {
        IsKey = function(v) return type(v) == 'string' and v ~= '' end,
        ToInt = function(v) return math.tointeger(tonumber(v) or 0) or 0 end,
        IsEliminated = function() return false end,
        ModeUsesTeams = function() return false end,
        GetTeamByKey = function() return nil end,
        SplitByStake = function() return {} end,
        -- these are called with differing arities across the file, so take
        -- the first argument that looks like an amount
        ResolveEntryFee = function(...)
            for _, v in ipairs({ ... }) do
                local n = math.tointeger(tonumber(v) or 0)
                if n and n > 0 then return n end
            end
            return 0
        end,
        ComputeSpectatorPayout = function(a) return a end,

        -- the whole pot to the single winner, server id 1
        ComputePayouts = function(o)
            if scenario == 'partial' then
                return { { id = 1, amount = o.pot // 2, reason = 'won' },
                         { id = 2, amount = o.pot // 2, reason = 'won' } }, 0
            end
            return { { id = 1, amount = o.pot, reason = 'won' } }, 0
        end,
    }
    _ENV.Arena.ResolveFighterBet = _ENV.Arena.ResolveEntryFee
    _ENV.Arena.ResolveSpectatorBet = _ENV.Arena.ResolveEntryFee
    _ENV.Config = {
        Debug = false,
        Betting = {
            enabled = true, account = 'cash', accounts = { 'cash', 'bank' },
            entryPotJoinsPool = false, minPlayersToPayOut = 1,
            refundOnDisconnectDuringMatch = false, refundRetrySeconds = 0,
            spectator = {}, fighter = {},
        },
        Webhook = { enabled = false },
        NotifyTitle = 'Arena',
    }
    _ENV.ArenaBetting = nil

    local keep = {}
    for _, n in ipairs({ 'ArenaLog', 'ArenaDebug', 'ArenaGetPlayer', 'ArenaPlayerName',
                         'ArenaNotifyKey', 'ArenaToastKey', 'ArenaWebhook' }) do keep[n] = _ENV[n] end
    assert(loadfile(ROOT .. 'server/util.lua'))()
    for n, fn in pairs(keep) do _ENV[n] = fn end
    assert(loadfile(ROOT .. 'server/betting.lua'))()
    for _, fn in ipairs(threads) do pcall(fn) end

    -- both fighters put 500 in
    ArenaBetting.TakeStake(1, 'm1', 500, 'cash')
    ArenaBetting.TakeStake(2, 'm1', 500, 'cash')
    local pot = ArenaBetting.GetPot('m1')
    paid = {}                              -- forget the debits; we watch credits

    if scenario == 'switch' then
        -- the winner switches character before the round is settled
        liveCitizen[1] = 'CID_OTHER'
    end

    armed = (scenario == 'partial')

    pcall(function()
        ArenaBetting.Settle('m1', { players = { 1, 2 }, winners = { 1 }, contestants = 2 })
    end)
    local first = paid['CID_WIN'] or 0
    local wrongHands = paid['CID_OTHER'] or 0

    if scenario == 'twice' or scenario == 'partial' then
        pcall(function()
            ArenaBetting.Settle('m1', { players = { 1, 2 }, winners = { 1 }, contestants = 2 })
        end)
    end

    return pot, first, (paid['CID_WIN'] or 0), wrongHands, lines
end

for _, c in ipairs({ { 'settled once', 'once' },
                     { 'settled twice', 'twice' },
                     { 'winner switched character first', 'switch' },
                     { 'first settle died mid-loop, retried', 'partial' } }) do
    local pot, first, total, wrong, lines = run(c[2])
    print(('%-32s pot %d | paid to the winning character %d | to whoever holds their id %d')
        :format(c[1], pot, total, wrong))
    for _, l in ipairs(lines) do print('   | ' .. l) end
end
