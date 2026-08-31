/*
    crimson_arena/tests/panel/radar.test.js

    THE RADAR TOGGLE.

    Permanent blips on every fighter turn a round into a map to be read
    rather than a place to be searched, so they ship off. This is what
    replaced them: opt-in, per player, and a SWEEP rather than a live feed.

    The panel's job is small -- draw the control where the operator allows
    one, and put the player's decision on the wire. So that is what these
    assert: the payload, and whether the control exists at all.
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

function snapshot(radar) {
    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: 'ffa', modeLabel: 'FFA', state: 'lobby',
        playerCount: 1, hostName: 'John Allday', players: [], teams: [],
    };
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600, radar: radar },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: true, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: { matchId: 'm1' },
        matches: [match],
        leaderboard: [],
    };
}

function opened(radar) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(radar);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

console.log('==> the radar toggle');

test('no control at all where the operator has not allowed one', () => {
    // A dead control reads as a broken feature. Absent is honest.
    // Checked through the class this panel actually hides with, not the
    // `hidden` attribute: show() toggles a class and never touches the
    // attribute, so markup using the attribute would be hidden forever with
    // nothing able to reveal it. That was the first version of this row.
    const panel = opened(null);
    assert.ok(panel.node('lobby-radar-row').classList.contains('hidden'),
        'the radar row was shown on a server that allows no radar');
});

test('and a control where they have', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    assert.ok(!panel.node('lobby-radar-row').classList.contains('hidden'),
        'the radar row was hidden on a server that allows one');
});

test('it starts on the operator default, not on off', () => {
    const on = opened({ defaultOn: true, intervalSeconds: 30 });
    assert.strictEqual(on.node('btn-radar').textContent, 'Radar On',
        'a server defaulting the radar ON opened with it reading Off');

    const off = opened({ defaultOn: false, intervalSeconds: 30 });
    assert.strictEqual(off.node('btn-radar').textContent, 'Radar Off');
});

test('pressing it puts the decision on the wire', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    panel.node('btn-radar').onclick();

    const sent = panel.posted.filter((p) => p.name === 'setRadar');
    assert.strictEqual(sent.length, 1, 'nothing was posted');
    assert.strictEqual(sent[0].body.on, true, 'the toggle posted ' + JSON.stringify(sent[0].body));
});

test('and pressing it again turns it back off', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    panel.node('btn-radar').onclick();
    panel.node('btn-radar').onclick();

    const sent = panel.posted.filter((p) => p.name === 'setRadar');
    assert.strictEqual(sent.length, 2);
    assert.strictEqual(sent[1].body.on, false, 'the second press did not turn it off');
});

test('turning OFF a radar the operator defaulted ON is sent, not swallowed', () => {
    // The state key starts null so the operator's default applies. A player
    // who then switches it off must produce a real `false` -- not nothing,
    // which is what a naive falsy check on an untouched value would give.
    const panel = opened({ defaultOn: true, intervalSeconds: 30 });
    panel.node('btn-radar').onclick();

    const sent = panel.posted.filter((p) => p.name === 'setRadar');
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].body.on, false,
        'switching off a defaulted-on radar posted ' + JSON.stringify(sent[0].body));
});

test('the label says how often it sweeps, so the wait is expected', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    assert.ok(/30 seconds/.test(panel.node('btn-radar').title),
        'the control does not say how long the gap is: ' + panel.node('btn-radar').title);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
