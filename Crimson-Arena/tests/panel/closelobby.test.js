/*
    crimson_arena/tests/panel/closelobby.test.js

    CLOSING THE LOBBY YOU OPENED, which nothing could reach.

    ArenaLobby.Cancel has always existed, is tested on the server side, and
    has a shipped setting of its own -- Config.Betting.refundOnCancel,
    documented in config.lua as "a host closing their own lobby". No player
    could get to any of it.

    The panel's only cancel was the "Stop The Countdown" button, which posted
    cancelMatch while its tooltip promised the lobby survived and nobody lost
    their place. Repointing that at holdCountdown fixed the lie and left the
    capability with no way in: the NUI callback in client/ui.lua and the
    server handler in server/main.lua were both still registered, and nothing
    in html/app.js posted the name. A host who opened a lobby by mistake
    could only walk out of it or wait out idleLobbyTimeoutSeconds.

    WHAT THE BUTTON MAY AND MAY NOT OFFER is the other half. Cancel is host
    only, and it refuses once the room has been teleported into the arena --
    which the panel cannot detect, because the lobby countdown and the frozen
    start countdown are both called 'countdown'. So the button is offered
    only in 'lobby': strictly narrower than the server allows, and never a
    guess.
*/

const assert = require('assert');
const path = require('path');
const { loadPanel } = require('./harness');

const ROOT = path.resolve(__dirname, '..', '..');

let passed = 0;
const failures = [];

function test(name, fn) {
    try {
        fn();
        passed += 1;
        console.log('  [PASS] ' + name);
    } catch (error) {
        failures.push({ name, error });
        console.log('  [FAIL] ' + name + ' -- ' + error.message);
    }
}

const SELF = 7;

function snapshot(options) {
    const o = Object.assign({
        state: 'lobby',
        isHost: true,
        inMatch: true,
        entryFee: 0,
        refundOnCancel: true,
    }, options || {});

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: o.entryFee > 0,
                currencySymbol: '$',
                refundOnCancel: o.refundOnCancel,
                entryFee: { enabled: o.entryFee > 0, min: 0, max: 100000, default: o.entryFee },
                spectatorBets: { enabled: false, min: 0, max: 0 },
                fighterBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: {
            serverId: SELF,
            money: 100000,
            matchId: o.inMatch ? 'm1' : null,
            spectating: o.inMatch ? false : 'm1',
            isHost: o.isHost,
            ready: false,
            team: false,
        },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
            modeKey: 'ffa', modeLabel: 'FFA', state: o.state,
            teams: false, playerCount: 2, hostName: 'You',
            pot: 0, entryFee: o.entryFee,
            teamCounts: {},
            players: [],
        }],
        leaderboard: [],
    };
}

function opened(options) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(options);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function closed(panel) {
    panel.fire('btn-close', 'click');
    return panel.posted.filter((p) => p.name === 'cancelMatch');
}

/* show() toggles a `hidden` CLASS -- the panel's own convention throughout --
   not the property of the same name, which stays false on a hidden control. */
function isHidden(panel, id) {
    return panel.node(id).classList.contains('hidden');
}

console.log('==> the host can close a lobby they opened');

test('THE BUG: nothing in the panel could reach cancelMatch at all', () => {
    const panel = opened();

    assert.ok(panel.built('btn-close'), 'there is no Close Lobby control');
    assert.strictEqual(isHidden(panel, 'btn-close'), false,
        'the host of a lobby was not offered a way to close it');
    assert.strictEqual(closed(panel).length, 1,
        'pressing Close Lobby posted nothing');
});

test('and it is the host who is offered it, nobody else', () => {
    const panel = opened({ isHost: false });

    assert.strictEqual(isHidden(panel, 'btn-close'), true,
        'a player who is not the host was offered the button that closes the room');
    assert.strictEqual(closed(panel).length, 0, 'a non-host posted a cancel');
});

test('and somebody WATCHING the lobby is not offered it either', () => {
    /* The server asks both -- GetByPlayer finds the match they are IN, and
       then hostSource has to match -- and the panel's own isHost is already
       `inMatch && player().isHost`, so a watcher fails it on the first half
       even with isHost true on the wire, which is how this fixture sends it. */
    const panel = opened({ inMatch: false });

    assert.strictEqual(isHidden(panel, 'btn-close'), true,
        'a spectator was offered a control over somebody else\'s lobby');
    assert.strictEqual(closed(panel).length, 0, 'a spectator posted a cancel');
});

console.log('');
console.log('==> and never once the round is under way');

test('a countdown hides it, because the panel cannot tell WHICH countdown', () => {
    /* ArenaLobby.Cancel accepts a lobby countdown and refuses the frozen
       start countdown, and both states are called 'countdown'. Offering it
       here would be a guess that is wrong half the time -- and wrong in the
       direction of a red toast on the button that closes the room. Stop The
       Countdown puts the match back to 'lobby', where this appears. */
    const panel = opened({ state: 'countdown' });

    assert.strictEqual(isHidden(panel, 'btn-close'), true,
        'Close Lobby was offered during a countdown the panel cannot identify');
    assert.strictEqual(closed(panel).length, 0, 'a cancel went out during a countdown');
});

test('and a live round hides it, which the server refuses outright', () => {
    const panel = opened({ state: 'live' });

    assert.strictEqual(isHidden(panel, 'btn-close'), true,
        'Close Lobby was offered on a round being fought');
    assert.strictEqual(closed(panel).length, 0, 'a cancel went out on a live round');
});

console.log('');
console.log('==> and it says what closing costs the room');

test('a free lobby says there was nothing staked', () => {
    const panel = opened({ entryFee: 0 });
    assert.ok(/nothing was staked/i.test(String(panel.node('btn-close').title)),
        'the button did not say the lobby was free: ' + panel.node('btn-close').title);
});

test('and a paid one says the fees come back, when they do', () => {
    const panel = opened({ entryFee: 5000, refundOnCancel: true });
    assert.ok(/handed back/i.test(String(panel.node('btn-close').title)),
        'the button did not say the fees are returned: ' + panel.node('btn-close').title);
});

test('THE ONE THAT COSTS MONEY: and says so when they do NOT', () => {
    /* refundOnCancel is the only setting under which a host closing their
       own lobby burns the room's entry fees, and it is the one thing they
       cannot find out by looking. Every other close -- idle timeout, admin
       stop, the last player leaving, a restart -- refunds in full. */
    const panel = opened({ entryFee: 5000, refundOnCancel: false });
    const title = String(panel.node('btn-close').title);

    assert.ok(/not handed back/i.test(title),
        'a host was not told that closing this lobby burns every entry fee: ' + title);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
