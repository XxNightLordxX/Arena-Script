/*
    crimson_arena/tests/panel/payload.test.js

    What the panel actually PUTS ON THE WIRE.

    The bug these were written for: Config.Match.lives let a host pick, the
    input appeared, typing in it did something -- and every match was still
    created with one life, because the state key behind the box was never
    declared and the guard that seeds it from config compared `undefined`
    against `null`. Nothing about the source read wrong. Only the payload did.
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

/** A snapshot shaped exactly like server/lobby.lua's config block. */
function snapshot(overrides) {
    const config = {
        arenas: [{ key: 'airfield', label: 'Airfield', enabled: true }],
        modes: [{ key: 'ffa', label: 'Free For All', enabled: true }],
        match: {
            lives: 3,
            livesChoice: { min: 1, max: 10 },
            minPlayers: 2,
            maxPlayers: 0,
            onlyHostCanStart: true,
        },
        betting: {
            enabled: false,
            entryFee: { enabled: false, min: 0, max: 0, default: 0 },
            spectatorBets: { enabled: false, min: 0, max: 0 },
        },
        loadouts: { allowChoose: true, chooser: 'host', weapons: [] },
        teams: { list: [] },
        ui: {},
    };
    Object.assign(config.match, (overrides || {}).match || {});
    return { config, player: {}, matches: [], leaderboard: [] };
}

/**
 * A panel in the state a player actually sees it in.
 *
 * The `open` matters: the create form is only rendered once the panel is
 * open, so a test that sends a snapshot and nothing else is testing a screen
 * nobody is looking at.
 */
function opened(snap) {
    const panel = loadPanel(ROOT);
    panel.send('open', snap || snapshot());
    panel.send('state', snap || snapshot());
    return panel;
}

console.log('==> what the create form posts');

test('the lives box starts on the operator default, not on a fallback', () => {
    const panel = opened();
    assert.strictEqual(panel.node('create-lives').value, '3',
        'the box shows ' + JSON.stringify(panel.node('create-lives').value)
        + ' -- the state key behind it was never seeded from config');
});

test('typing a number is what gets created', () => {
    const panel = opened();
    panel.type('create-lives', '7');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.ok(sent, 'nothing was posted at all');
    assert.strictEqual(sent.body.lives, 7,
        'typed 7, posted ' + sent.body.lives + ' -- this is the bug in one line');
});

test('and the value survives a server broadcast landing mid-edit', () => {
    // Every push re-renders. A render that writes state back into the input
    // is correct; one that re-seeds state from config is not, and would
    // silently undo what the host typed a moment earlier.
    const panel = opened();
    panel.type('create-lives', '9');
    panel.send('state', snapshot());
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.lives, 9, 'a broadcast reset the host\'s choice');
});

test('the arena and mode reach the wire too, not just the lives', () => {
    const panel = opened();
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.arenaKey, 'airfield');
    assert.strictEqual(sent.body.modeKey, 'ffa');
});

test('a fixed-lives server offers no box and still posts a usable number', () => {
    const snap = snapshot();
    delete snap.config.match.livesChoice;      // the operator fixed it
    snap.config.match.lives = 2;

    const panel = opened(snap);
    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.lives, 2,
        'a server that fixed the count had it overridden by the panel');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
