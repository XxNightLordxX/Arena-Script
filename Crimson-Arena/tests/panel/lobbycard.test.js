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
function inLobby(lives, rules) {
    const extra = rules || {};
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
    /* THE MATCH'S OWN RULE AND WHETHER IT SPENDS LIVES, both of which the
       server resolves onto the match and sends. Set only when a test is
       about them, so every existing case still describes a snapshot that
       carries neither. */
    if (extra.winCondition !== undefined) match.winCondition = extra.winCondition;
    if (extra.livesSpent !== undefined) match.livesSpent = extra.livesSpent;

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
                /* THE OPERATOR DEFAULT, deliberately different from what the
                   tests below put on the match -- the card used to read this
                   one, exactly as it used to read `lives` from here. */
                winCondition: 'last_standing',
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

function lobbyText(lives, rules) {
    const panel = loadPanel(ROOT);
    panel.send('open', inLobby(lives, rules));
    panel.send('state', inLobby(lives, rules));
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
console.log('==> and what it says about how the round is won');

test('THE SAME BUG ON THE WIN CONDITION: the card read the server default', () => {
    /* `matchCfg.winCondition` is the operator's default, sent in the config
       block; `match.winCondition` is the rule the server resolved for THIS
       match and has been sending all along. A host who picked "most kills
       when the clock runs out" had their card announce last one standing to
       everybody looking at it. */
    const text = lobbyText(3, { winCondition: 'most_kills', livesSpent: false });
    assert.ok(/most kills when the clock runs out/i.test(text),
        'the card does not name the rule this match is played by: ' + text);
    assert.ok(!/last one standing/i.test(text),
        'the card is still announcing the operator default: ' + text);
});

test('and a round that spends no lives does not advertise any', () => {
    /* IN A PLAYER'S WORDS: "it should not have a lives for most kills till
       the clock runs out". A card reading "3 lives each" over a round nobody
       can be eliminated from is the panel telling a plain untruth. */
    const text = lobbyText(3, { winCondition: 'most_kills', livesSpent: false });
    assert.ok(!/lives each/i.test(text),
        'the card quotes lives on a round that spends none: ' + text);
    assert.ok(/No lives/i.test(text), 'the card says nothing about lives at all: ' + text);
});

test('and says the CLOCK is what ends it, not a kill limit', () => {
    const text = lobbyText(3, { winCondition: 'most_kills', livesSpent: false });
    assert.ok(/until the clock stops/i.test(text),
        'the card does not say what ends a most-kills round: ' + text);
});

test('and a kill limit says the limit instead', () => {
    /* The other livesless condition, and it ends on a different thing. One
       sentence for both would be wrong for one of them. */
    const text = lobbyText(3, { winCondition: 'score_limit', livesSpent: false });
    assert.ok(/reaches the limit/i.test(text),
        'the card says a kill-limit round ends on the clock: ' + text);
});

test('and last one standing still quotes the lives, which is the control', () => {
    const text = lobbyText(3, { winCondition: 'last_standing', livesSpent: true });
    assert.ok(/3 lives each/.test(text),
        'the card stopped quoting lives on the one rule that spends them: ' + text);
    assert.ok(/last one standing/i.test(text),
        'the card does not name the rule: ' + text);
});

test('and a snapshot with no livesSpent field reads the condition instead', () => {
    /* Older matches, and any snapshot written before the field existed --
       the same fallback `lives` above has, and the reason reading the field
       is safe rather than a new way to render "undefined". */
    const text = lobbyText(3, { winCondition: 'most_kills' });
    assert.ok(!/lives each/i.test(text),
        'a snapshot with no livesSpent field fell back to quoting lives: ' + text);
    /* AND THE POSITIVE. The line above is satisfied by an empty string, so
       a card that rendered nothing at all would pass it -- which is exactly
       what happened when renderLobbyMeta was made to clear and return. */
    assert.ok(/No lives — respawn until the clock stops/i.test(text),
        'the card says nothing in place of the lives it dropped: ' + text);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
