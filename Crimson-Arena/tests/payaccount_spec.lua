--[[
    crimson_arena/tests/payaccount_spec.lua

    WHICH POCKET PAYS, AND WHO DECIDES.

    Money used to come out of Config.Betting.accounts in order for the whole
    amount, so a player was never asked: the entry fee and every bet left
    whichever account the operator had listed first, and there was no way to
    know before it happened.

    The player picks now, and A CHOSEN ACCOUNT IS THE ONLY ONE TRIED. Falling
    back to the other would be spending money out of a pocket they
    deliberately left alone -- somebody picks `bank` precisely because they
    want the cash kept -- which is the same class of mistake as quietly
    clamping a number they typed. Refused with a reason is the honest answer.

    Two properties this file exists to hold, both of which are easy to lose:

      THE CHOICE IS OBEYED     no silent fallback, in either direction.
      THE REFUND FOLLOWS THE   the escrow record must name the account the
      MONEY                    money actually LEFT, never the one that was
                               asked for -- otherwise a refund invents money
                               in a place the player never spent it from.

    Everything goes in over the wire, because the wire is where this build's
    defects have lived.
]]

local t = dofile('testkit.lua')
local Sandbox = dofile('fixtures/sandbox.lua')

print('payaccount_spec')

--- @param wallets table<integer, table> -- [src] = { cash = n, bank = n }
local function newServer(wallets, mutate)
    local players = {}
    for src, money in pairs(wallets) do
        players[src] = {
            citizenid = ('CID%03d'):format(src),
            name = ('Fighter %d'):format(src),
            money = { cash = money.cash or 0, bank = money.bank or 0 },
            job = { name = 'unemployed', grade = { level = 0 } },
        }
    end

    local qbx = Sandbox.newQbxCore(players)
    local threads = Sandbox.newThreadRunner()
    local netEvents, console = {}, {}
    local clock = 0

    local env = Sandbox.newArenaEnv({
        exports = qbx.exports,
        lib = Sandbox.newOxLib(),
        CreateThread = threads.CreateThread,
        Wait = threads.Wait,
        SetTimeout = threads.SetTimeout,
        print = function(line) console[#console + 1] = line end,
        TriggerClientEvent = function() end,
        TriggerEvent = function() end,
        RegisterNetEvent = function(name, fn) netEvents[name] = fn end,
        -- Nothing here drives a disconnect, so the handlers are taken and
        -- dropped rather than kept: an unused table that looks like a
        -- fixture is a fixture somebody will wonder why nothing uses.
        AddEventHandler = function() end,
        RegisterCommand = function() end,
        GetCurrentResourceName = function() return 'crimson_arena' end,
        GetGameTimer = function() clock = clock + 60000 return clock end,
        GetPlayerName = function(src) return (players[src] or {}).name or '' end,
        GetPlayerPed = function(src) return src end,
        GetEntityCoords = function(ped)
            return { x = 1000.0 + (tonumber(ped) or 0) * 25.0, y = 2000.0, z = 30.0 }
        end,
        GetVehiclePedIsIn = function() return 0 end,
        IsPlayerAceAllowed = function() return false end,
        PerformHttpRequest = function() end,
        ArenaStats = {
            GetLeaderboard = function(cb) cb({}) end,
            EnsureSchema = function() end, RecordMatch = function() end, Flush = function() end,
        },
        ArenaAmmo = {
            IsEnabled = function() return false end,
            Issue = function() return {} end, Reclaim = function() return 0 end,
            ReclaimAll = function() return 0 end, Clear = function() return true end,
            OnLoan = function() return 0 end,
        },
        ArenaDispatch = {
            Set = function() end, Clear = function() end, Revive = function() end,
            IsPlayerInArena = function() return false end,
            EnterBucket = function() end, ExitBucket = function() end,
            GetBucket = function() end, ReleaseBucket = function() end,
        },
    })

    env.Config.Match.minPlayers = 2
    env.Config.Match.lobbyCountdownSeconds = 0
    if mutate then mutate(env.Config) end

    for _, file in ipairs({ 'util', 'betting', 'lobby', 'match', 'main' }) do
        Sandbox.loadInto('../server/' .. file .. '.lua', env)
    end

    local server = { env = env, qbx = qbx, config = env.Config,
        betting = env.ArenaBetting, lobby = env.ArenaLobby }

    function server.fire(event, src, data)
        local handler = netEvents['crimson_arena:server:' .. event]
        if not handler then error('no handler for ' .. event, 2) end
        env.source = src
        handler(data)
    end

    function server.cash(src) return qbx.players[src].money.cash end
    function server.bank(src) return qbx.players[src].money.bank end
    function server.log() return table.concat(console, '\n') end

    return server
end

--- Opens a lobby at `fee`, with the host paying from `account`.
local function openLobby(server, fee, account)
    server.fire('createMatch', 1, {
        arenaKey = 'airfield', modeKey = 'ffa', entryFee = fee, account = account,
    })
    local match = server.lobby.All()[1]
    return match and match.id or nil
end

-- ======================================================================
-- WHAT SHIPS
-- ======================================================================

t.test('the shipped config offers both accounts, in order', function()
    local server = newServer({ [1] = { cash = 1000, bank = 1000 } })
    local accounts = server.betting.Accounts()
    t.equals(#accounts, 2, 'the choice is not on offer at all')
    t.equals(accounts[1], 'cash')
    t.equals(accounts[2], 'bank')
end)

t.test('and reports what a player holds in each, for the panel to draw', function()
    local server = newServer({ [1] = { cash = 250, bank = 9000 } })
    local wallet = server.betting.Wallet(1)
    t.equals(wallet.cash, 250)
    t.equals(wallet.bank, 9000)
end)

-- ======================================================================
-- THE ENTRY FEE
-- ======================================================================

t.test('an entry fee paid from the BANK leaves the cash alone', function()
    -- The whole point. Cash could cover it and is listed first, so with the
    -- choice ignored this money comes out of the wrong pocket.
    local server = newServer({ [1] = { cash = 5000, bank = 5000 } })
    openLobby(server, 1000, 'bank')

    t.equals(server.cash(1), 5000, 'the fee came out of cash despite the player picking bank')
    t.equals(server.bank(1), 4000)
end)

t.test('and from CASH leaves the bank alone', function()
    local server = newServer({ [1] = { cash = 5000, bank = 5000 } })
    openLobby(server, 1000, 'cash')

    t.equals(server.cash(1), 4000)
    t.equals(server.bank(1), 5000)
end)

t.test('a chosen account that cannot cover it is REFUSED, not quietly swapped', function()
    -- Falling through to cash would take money from a pocket the player
    -- deliberately did not pick.
    local server = newServer({ [1] = { cash = 5000, bank = 10 } })
    local matchId = openLobby(server, 1000, 'bank')

    t.isNil(matchId, 'the match opened on money the player did not offer')
    t.equals(server.cash(1), 5000, 'CASH WAS SPENT AFTER THE PLAYER CHOSE BANK')
    t.equals(server.bank(1), 10)
end)

t.test('with no choice made, the operator order still applies', function()
    -- Every server that has not switched the choice on, and every panel that
    -- has not been touched.
    local server = newServer({ [1] = { cash = 5000, bank = 5000 } })
    openLobby(server, 1000, nil)

    t.equals(server.cash(1), 4000, 'the fee did not fall to the first listed account')
    t.equals(server.bank(1), 5000)
end)

t.test('and an account name this server does not have is no preference', function()
    -- A stale panel or a crafted payload, not a reason to refuse a player who
    -- can plainly pay.
    local server = newServer({ [1] = { cash = 5000, bank = 5000 } })
    t.isNotNil(openLobby(server, 1000, 'crypto'), 'a junk account name refused a payable fee')
    t.equals(server.cash(1), 4000)
end)

t.test('a joiner picks their own account, independently of the host', function()
    local server = newServer({
        [1] = { cash = 5000, bank = 5000 },
        [2] = { cash = 5000, bank = 5000 },
    })
    local matchId = openLobby(server, 1000, 'cash')
    server.fire('joinMatch', 2, { matchId = matchId, account = 'bank' })

    t.equals(server.cash(1), 4000, 'the host did not pay from cash')
    t.equals(server.cash(2), 5000, 'the joiner paid from cash after choosing bank')
    t.equals(server.bank(2), 4000)
end)

-- ======================================================================
-- THE REFUND FOLLOWS THE MONEY
-- ======================================================================

t.test('a refund goes back to the account the money LEFT, not the one asked for', function()
    -- The trap in threading a preference through: the escrow record is what a
    -- refund reads, and recording the REQUEST rather than the result would
    -- put the money back somewhere it never came from -- inventing it in one
    -- pocket while it is still missing from the other.
    local server = newServer({ [1] = { cash = 5000, bank = 5000 } })
    openLobby(server, 1000, 'bank')
    t.equals(server.bank(1), 4000, 'the fee did not come out of the bank, so this proves nothing')

    server.fire('cancelMatch', 1)

    t.equals(server.bank(1), 5000, 'the bank was not made whole')
    t.equals(server.cash(1), 5000, 'THE REFUND WAS PAID INTO CASH, WHICH NEVER PAID ANYTHING')
end)

t.test('and with no preference it still goes back where it came from', function()
    local server = newServer({ [1] = { cash = 0, bank = 5000 } })
    -- Cash is listed first and holds nothing, so the fee falls to the bank.
    local matchId = openLobby(server, 1000, nil)
    t.isNotNil(matchId)
    t.equals(server.bank(1), 4000, 'the fee did not fall through to the bank')

    server.fire('cancelMatch', 1)

    t.equals(server.bank(1), 5000, 'the refund did not return to the account that paid')
    t.equals(server.cash(1), 0, 'the refund conjured cash the player never had')
end)

-- ======================================================================
-- SIDE-BETS TAKE THE SAME ROUTE
-- ======================================================================

t.test('a side-bet is paid from the account the bettor picked', function()
    local server = newServer({
        [1] = { cash = 5000, bank = 5000 },
        [2] = { cash = 5000, bank = 5000 },
        [3] = { cash = 5000, bank = 5000 },
    })
    local matchId = openLobby(server, 0, nil)
    server.fire('joinMatch', 2, { matchId = matchId })

    server.fire('placeSpectatorBet', 3, {
        matchId = matchId, pick = '1', amount = 500, account = 'bank',
    })

    t.equals(server.cash(3), 5000, 'the bet came out of cash despite the bettor picking bank')
    t.equals(server.bank(3), 4500)
end)

t.test('and a bet the chosen account cannot cover is refused', function()
    local server = newServer({
        [1] = { cash = 5000, bank = 5000 },
        [2] = { cash = 5000, bank = 5000 },
        [3] = { cash = 5000, bank = 10 },
    })
    local matchId = openLobby(server, 0, nil)
    server.fire('joinMatch', 2, { matchId = matchId })

    server.fire('placeSpectatorBet', 3, {
        matchId = matchId, pick = '1', amount = 500, account = 'bank',
    })

    t.equals(server.cash(3), 5000, 'CASH WAS SPENT ON A BET THE PLAYER ASKED TO PAY FROM THE BANK')
    t.equals(server.bank(3), 10)
end)

os.exit(t.summary())
