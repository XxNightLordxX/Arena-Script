/*
    crimson_arena/tests/panel/lobbycard.test.js

    WHAT THE LOBBY CARD SAYS, as opposed to what the match is.

    The bug: renderLobbyMeta read `cfg().match.lives` -- the operator's
    DEFAULT, which the server sends as Arena.ResolveLives(nil) -- instead of
    `match.lives`, the number this match is actually played with. So the card
    read "3 lives each" under every match ever created, including one the host
    had correctly set to 1, and it disagreed with the host's own edit form on
    the same screen.

    Nothing was wrong with the value. `match.lives` is in the snapshot
    (server/lobby.lua) and always was. The card asked the wrong object.

    That is why these assert on RENDERED TEXT rather than on state: the value
    was right at every point a state assertion could have looked.
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

/**
 * A player standing in a lobby of a match with `lives` lives.
 *
 * `config.match.lives` is deliberately left at 3 throughout -- that is the
 * operator default the server really sends, and it is the value the card used
 * to display. A fixture that set it to match would hide the bug.
 */
function inLobby(lives) {
    const match = {
        id: 'm1',
        arenaKey: 'airfield',
        arenaLabel: 'Sandy Shores Airfield',
        modeKey: 'ffa',
        modeLabel: 'Free For All',
        state: 'waiting',
        playerCount: 1,
        hostName: 'John Allday',
        players: [],
        teams: [],
    };
    if (lives !== undefined) match.lives = lives;

    return {
        config: {
            arenas: [{ key: 'airfield', label: 'Sandy Shores Airfield', enabled: true }],
            modes: [{ key: 'ffa', label: 'Free For All', enabled: true }],
            match: {
                lives: 3,
                livesChoice: { min: 1, max: 10 },
                minPlayers: 2,
                maxPlayers: 0,
                roundTimeSeconds: 600,
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
        },
        player: { matchId: 'm1' },
        matches: [match],
        leaderboard: [],
    };
}

function lobbyText(lives) {
    const panel = loadPanel(ROOT);
    panel.send('open', inLobby(lives));
    panel.send('state', inLobby(lives));
    return panel.text('lobby-meta');
}

console.log('==> what the lobby card says about lives');

test('a one-life match does not advertise three', () => {
    // THE REPORTED SYMPTOM, in one assertion. The host set 1 and the card
    // said "3 lives each".
    const text = lobbyText(1);
    assert.ok(!/3 lives each/.test(text),
        'the card still reads "3 lives each" for a match with 1 life -- it is showing the operator default: ' + text);
});

test('and says so in the singular, which is a different sentence entirely', () => {
    const text = lobbyText(1);
    assert.ok(/One life/.test(text),
        'a one-life match should say "One life -- first death is elimination", got: ' + text);
});

test('a five-life match says five', () => {
    const text = lobbyText(5);
    assert.ok(/5 lives each/.test(text),
        'the card does not report the match\'s own number, got: ' + text);
});

test('every number the host may pick reaches the card unchanged', () => {
    // Not one example: the bug rendered a CONSTANT, so a single case could
    // pass by coincidence if it happened to equal the default.
    for (let lives = 2; lives <= 10; lives += 1) {
        const text = lobbyText(lives);
        assert.ok(text.indexOf(lives + ' lives each') !== -1,
            'a match with ' + lives + ' lives rendered: ' + text);
    }
});

test('a match with no lives field falls back to the operator default', () => {
    // Older matches, and any snapshot written before the field existed. The
    // fallback is what makes reading match.lives safe rather than a new way
    // to render "undefined lives each".
    const text = lobbyText(undefined);
    assert.ok(/3 lives each/.test(text),
        'a match carrying no lives field should fall back to the config default of 3, got: ' + text);
});

test('the rest of the card still renders, so this is not passing on an empty node', () => {
    // The failure mode that would make every test above vacuous: lobby-meta
    // never rendered at all, so no string is ever found and every negative
    // assertion passes.
    const text = lobbyText(1);
    assert.ok(/Free For All/.test(text), 'the mode is missing from the card: ' + text);
    assert.ok(/Sandy Shores Airfield/.test(text), 'the arena is missing from the card: ' + text);
    assert.ok(/John Allday/.test(text), 'the host is missing from the card: ' + text);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
