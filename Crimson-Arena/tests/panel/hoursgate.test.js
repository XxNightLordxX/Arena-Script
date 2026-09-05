/*
    crimson_arena/tests/panel/hoursgate.test.js

    THREE CONTROLS AND ONE LINE, AGAINST A SHUT ARENA.

    server/lobby.lua's Join and server/match.lua's Begin both refuse while
    the doors are shut, and both refusals are correct. What this file is
    about is whether the screen says so BEFORE the click:

      CREATE MATCH      refused by ArenaLobby.Join, which Create funnels its
                        host through.
      JOIN              the same refusal, on somebody else's lobby.
      START MATCH NOW   refused by ArenaMatch.Begin. This chain is the one
                        that is easy to miss -- it is hand-written and never
                        calls Arena.CanStartMatch -- so a full, readied lobby
                        whose host clicks a lit button gets a toast.

    AND THE ONE THAT IS NOT A REFUSAL: the header line listing the whole
    schedule. A player who has just missed a window needs to know when the
    next one is without walking back to the NPC to find out.

    THE ABSENT-FIELD CASE IS THE LOAD-BEARING ONE. Every read is `=== false`,
    never `!== true`: a server running an older panel, or a snapshot
    assembled before `schedule` existed, must keep OFFERING all three and let
    the server be the one to refuse. A panel that refuses on an absent field
    takes the arena away from anybody running a mismatched pair.
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

const SHUT = { open: false, now: '03:14', opensAt: '05:00', line: '05:00-07:00, 12:00-14:00' };
const OPEN = { open: true, now: '05:30', closesAt: '07:00', line: '05:00-07:00, 12:00-14:00' };

/*
 * `schedule` is left UNSET by default, so the "an older server sends none"
 * case is the shape the defaults describe and every test that wants a
 * verdict has to ask for one.
 */
function snapshot(options) {
    const o = Object.assign({
        schedule: undefined,
        who: 'bystander',   // 'bystander' | 'host'
        state: 'lobby',
    }, options || {});

    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: 'ffa', modeLabel: 'Mode', state: o.state,
        teams: false, playerCount: 2, hostName: 'Host', pot: 0, entryFee: 0,
        teamCounts: {},
        players: [
            { id: SELF, name: 'Me', team: null, alive: true },
            { id: 11, name: 'Other', team: null, alive: true },
        ],
    };
    if (o.who === 'host') {
        match.hostId = SELF;
        match.hostName = 'Me';
    }

    const snap = {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'Mode', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, maxConcurrentMatches: 0, onlyHostCanStart: true },
            betting: {
                enabled: false, currencySymbol: '$', payout: 'winner_takes_all',
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false }, fighterBets: { enabled: false },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: {
            serverId: SELF,
            money: 100000,
            wallet: { cash: 100000, bank: 100000 },
            matchId: o.who === 'host' ? 'm1' : null,
            /* What renderLobby actually reads to decide who may start it. */
            isHost: o.who === 'host',
            spectating: false,
            team: false,
        },
        matches: [match],
        leaderboard: [],
    };
    if (o.schedule !== undefined) snap.schedule = o.schedule;
    return snap;
}

function opened(options) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(options);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

console.log('==> Create Match, against a shut arena');

test('THE BUG: Create Match was lit while the arena was shut', () => {
    const panel = opened({ schedule: SHUT });

    assert.strictEqual(panel.node('create-submit').disabled, true,
        'Create Match was offered while the arena was shut');
    assert.ok(/05:00/.test(panel.text('create-hint')),
        'the screen did not say when it opens: ' + panel.text('create-hint'));
});

test('and is offered again once it is open', () => {
    // The other direction, and the reason the first is worth something: a
    // panel that refused every match would pass that test and never let
    // anybody fight.
    const panel = opened({ schedule: OPEN });

    assert.notStrictEqual(panel.node('create-submit').disabled, true,
        'Create Match was refused on an open arena: ' + panel.text('create-hint'));
});

test('and a server that sends no schedule is given the benefit of the doubt', () => {
    const panel = opened({ schedule: undefined });

    assert.notStrictEqual(panel.node('create-submit').disabled, true,
        'an absent schedule block was read as a shut arena: ' + panel.text('create-hint'));
});

test('and a shut arena is never reported as a server with no arenas', () => {
    /* Placed after the two config-fault sentences on purpose. A player at
       03:00 told "This server has no arena switched on." files a bug the
       operator cannot reproduce at 13:00. */
    const panel = opened({ schedule: SHUT });
    assert.ok(!/no arena switched on/i.test(panel.text('create-hint')),
        'a shut arena was reported as a broken config: ' + panel.text('create-hint'));
});

console.log('');
console.log('==> Join, on somebody else\'s lobby');

/** The Join button the match card builds, found by the id it is given. */
function joinButton(panel) {
    return panel.nodes['match-join-m1'];
}

test('THE BUG: Join was lit on a lobby the server would refuse', () => {
    const panel = opened({ schedule: SHUT });

    const join = joinButton(panel);
    assert.ok(join, 'no Join button was drawn at all');
    assert.strictEqual(join.disabled, true, 'Join was offered while the arena was shut');
    assert.ok(/05:00/.test(join.title), 'the tooltip did not say when it opens: ' + join.title);
});

test('and offered again once it is open', () => {
    const panel = opened({ schedule: OPEN });

    const join = joinButton(panel);
    assert.ok(join, 'no Join button was drawn at all');
    assert.notStrictEqual(join.disabled, true, 'Join was refused on an open arena: ' + join.title);
});

test('and offered when the server sends no schedule at all', () => {
    const panel = opened({ schedule: undefined });

    const join = joinButton(panel);
    assert.notStrictEqual(join.disabled, true, 'an absent schedule block took Join away');
});

test('and a shut arena is named rather than the entry fee', () => {
    /* Placed before the full and the fee checks, so a shut arena is named
       rather than telling somebody they cannot afford a match they could
       afford perfectly well an hour from now. */
    const panel = opened({ schedule: SHUT });
    assert.ok(!/afford|cover/i.test(joinButton(panel).title),
        'a shut arena was reported as a money problem: ' + joinButton(panel).title);
});

console.log('');
console.log('==> Start Match Now, which no other chain covers');

test('THE HOLE: Start Match Now was lit while the arena was shut', () => {
    const panel = opened({ schedule: SHUT, who: 'host' });

    const start = panel.node('btn-start');
    assert.strictEqual(start.disabled, true,
        'the host of a full lobby was offered a start the server would refuse');
    assert.ok(/05:00/.test(start.title),
        'the tooltip did not say when it opens: ' + start.title);
});

test('and offered again once it is open', () => {
    const panel = opened({ schedule: OPEN, who: 'host' });

    assert.notStrictEqual(panel.node('btn-start').disabled, true,
        'the host was refused a start on an open arena: ' + panel.node('btn-start').title);
});

test('and offered when the server sends no schedule at all', () => {
    const panel = opened({ schedule: undefined, who: 'host' });

    assert.notStrictEqual(panel.node('btn-start').disabled, true,
        'an absent schedule block took Start Match Now away');
});

console.log('');
console.log('==> the header line, which is the only place the whole schedule is written');

test('the schedule is shown unprompted, with the next opening', () => {
    const panel = opened({ schedule: SHUT });
    const line = panel.text('arena-hours');

    // ON SCREEN, not merely written into a hidden node: `show()` toggles the
    // `hidden` class, and a test that only reads textContent passes against
    // a line nobody can see.
    assert.ok(!panel.node('arena-hours').classList.contains('hidden'),
        'the schedule was written into a hidden element');
    assert.ok(/05:00-07:00/.test(line), 'the window list is missing: ' + line);
    assert.ok(/12:00-14:00/.test(line), 'only one window was listed: ' + line);
    assert.ok(/05:00/.test(line), 'it does not say when it next opens: ' + line);
});

test('and says how long is left while it is open', () => {
    const panel = opened({ schedule: OPEN });
    const line = panel.text('arena-hours');

    assert.ok(!panel.node('arena-hours').classList.contains('hidden'),
        'the schedule was written into a hidden element');
    assert.ok(/07:00/.test(line), 'it does not say when it shuts: ' + line);
});

test('and a server keeping no hours advertises none', () => {
    /* `line` is sent only when the server is genuinely enforcing hours, so
       the panel can never advertise a schedule nobody is keeping. */
    const panel = opened({ schedule: { open: true, now: '03:14' } });

    assert.ok(panel.node('arena-hours').classList.contains('hidden'),
        'the hours line was left on screen with no schedule to show');
    assert.strictEqual(panel.text('arena-hours'), '',
        'the panel advertised a schedule the server is not keeping');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    console.log('Failures:');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
