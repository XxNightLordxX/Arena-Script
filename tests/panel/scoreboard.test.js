/*
    crimson_arena/tests/panel/scoreboard.test.js

    THE TWO THINGS DRAWN OVER GAMEPLAY: the live HUD and the end-of-match
    board.

    Neither had a test. Seven panel test files cover the menu -- the create
    form, the lobby card, the loadout, the bets, the account picker, the
    radar -- and every one of them is about a screen the player opens. The
    HUD is the screen they never open and stare at for the whole round, and
    the results board is where the money they just won is shown to them.

    WHAT MAKES THESE WORTH ASSERTING RATHER THAN READING. Both are built by
    appending elements, so what a player actually READS is spread across a
    tree of nodes and no single textContent holds it. Both also make
    decisions the source does not make obvious:

      BLANK IS NOT ZERO. The overlay can be switched on before any numbers
      exist -- the sweep that fills it runs once a second. An empty field
      says "not yet"; a zero claims an empty arena.

      NO CLOCK IS NOT 0:00. A round with no time limit has nothing to count
      down, and a frozen 0:00 burnt over live gameplay reads as a round
      that has already ended.

      EARNINGS ARE READ OFF THE NUMBER, not off the betting switch --
      because the switch lives in a snapshot this client may never have
      fetched, and the number only exists when there was a pot.
*/

const assert = require('assert');
const path = require('path');
const { loadPanel } = require('./harness');

const ROOT = path.resolve(__dirname, '..', '..', 'Crimson-Arena');

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

/** A snapshot with betting either on or off, and this player as server id 7. */
function snapshot(bettingEnabled) {
    return {
        config: {
            arenas: [{ key: 'airfield', label: 'Airfield', enabled: true }],
            modes: [{ key: 'ffa', label: 'Free For All', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600 },
            betting: {
                enabled: bettingEnabled === true,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: true, chooser: 'player', weapons: [] },
            teams: { list: [{ key: 'red', label: 'Red', color: '#ff0000' }] },
            ui: {},
        },
        player: { serverId: 7, matchId: 'm1' },
        matches: [],
        leaderboard: [],
    };
}

/**
 * Whether the panel is SHOWING a node.
 *
 * app.js's show() toggles a `hidden` CLASS -- it never touches the DOM
 * `hidden` property, which is what index.html's stylesheet is written
 * against. Asserting on `.hidden` reads a property nothing sets: it is
 * false on every node forever, so "the overlay is up" passes before the
 * panel has drawn anything at all.
 */
function shown(panel, id) {
    return !panel.node(id).classList.contains('hidden');
}

/** A panel that has taken a snapshot, ready to be sent hud/results pushes. */
function panelWith(bettingEnabled) {
    const panel = loadPanel(ROOT);
    panel.send('open', snapshot(bettingEnabled));
    return panel;
}

console.log('==> the live HUD and the end-of-match board');

// ======================================================================
// THE LIVE HUD
// ======================================================================

test('the HUD stays hidden until the client says otherwise', () => {
    // A `state` push is what runs renderHud without asking for the
    // overlay -- exactly what a player standing in the lobby receives.
    const panel = panelWith(false);
    panel.send('state', snapshot(false));

    assert.strictEqual(shown(panel, 'arena-hud'), false,
        'the match overlay is drawn over a player who is not in a match');
});

test('switched on with no numbers yet, the fields are BLANK rather than zero', () => {
    // The sweep that fills them runs once a second, so there is a real
    // window with the overlay up and nothing in it. "Remaining 0 / 0" in that
    // window claims an empty arena to a player standing in a full one.
    const panel = panelWith(false);

    panel.send('hud', { visible: true });

    assert.strictEqual(shown(panel, 'arena-hud'), true, 'the overlay never came up');
    assert.strictEqual(panel.node('hud-alive').textContent, '',
        'the overlay claimed a player count before it had one');
    assert.strictEqual(panel.node('hud-kills').textContent, '',
        'the overlay claimed a kill count before it had one');
    assert.strictEqual(panel.node('hud-timer').textContent, '',
        'the overlay showed a clock before it had one');
});

test('the numbers appear once they arrive', () => {
    const panel = panelWith(false);

    panel.send('hud', { visible: true, hud: { remaining: 3, total: 8, kills: 2, deaths: 1, timeLeft: 125 } });

    assert.strictEqual(panel.node('hud-alive').textContent, 'Remaining 3 / 8',
        'the remaining count is not what the server sent');
    assert.strictEqual(panel.node('hud-kills').textContent, 'Kills 2  Deaths 1',
        'the kill and death counts are not what the server sent');
});

test('the clock is minutes and seconds, zero-padded', () => {
    const panel = panelWith(false);

    panel.send('hud', { visible: true, hud: { timeLeft: 125 } });
    assert.strictEqual(panel.node('hud-timer').textContent, '2:05',
        'two minutes five seconds should read 2:05');

    panel.send('hud', { visible: true, hud: { timeLeft: 59 } });
    assert.strictEqual(panel.node('hud-timer').textContent, '0:59');

    panel.send('hud', { visible: true, hud: { timeLeft: 600 } });
    assert.strictEqual(panel.node('hud-timer').textContent, '10:00');
});

test('and a round with NO time limit shows no clock at all', () => {
    // Not 0:00. A frozen zero burnt over live gameplay reads as a round
    // that has already ended, and the player cannot clear it.
    const panel = panelWith(false);

    panel.send('hud', { visible: true, hud: { remaining: 2, total: 2, timeLeft: null } });

    assert.strictEqual(panel.node('hud-timer').textContent, '',
        'an untimed round shows a clock it has no business showing');
    assert.strictEqual(panel.node('hud-alive').textContent, 'Remaining 2 / 2',
        'the rest of the overlay went blank along with the clock');
});

test('the pot is shown only where there IS one', () => {
    const panel = panelWith(true);

    panel.send('hud', { visible: true, hud: { pot: 2500, alive: 2, total: 2 } });
    assert.strictEqual(shown(panel, 'hud-pot'), true, 'a real pot was hidden');
    assert.strictEqual(panel.node('hud-pot').textContent, 'Pot $2,500',
        'the pot is not formatted as money');

    panel.send('hud', { visible: true, hud: { pot: 0, alive: 2, total: 2 } });
    assert.strictEqual(shown(panel, 'hud-pot'), false,
        'an empty pot was advertised to the arena');
});

test('and never on a server with betting switched off', () => {
    const panel = panelWith(false);

    panel.send('hud', { visible: true, hud: { pot: 2500, alive: 2, total: 2 } });

    assert.strictEqual(shown(panel, 'hud-pot'), false,
        'a pot was shown on a server that does not take bets');
});

test('the scoreboard names the fighters, and marks which one is you', () => {
    const panel = panelWith(false);

    panel.send('hud', {
        visible: true,
        hud: {
            alive: 1,
            total: 2,
            scoreboard: [
                { id: 7, name: 'Ada', kills: 2, alive: true },
                { id: 9, name: 'Ben', kills: 1, alive: false },
            ],
        },
    });

    const text = panel.text('hud-scoreboard');
    assert.ok(/Ada/.test(text), 'the scoreboard does not name the players: ' + text);
    assert.ok(/Ben/.test(text), 'the scoreboard is missing a fighter: ' + text);

    const rows = panel.node('hud-scoreboard').children;
    assert.strictEqual(rows.length, 2, 'the scoreboard drew ' + rows.length + ' rows for two fighters');
    assert.ok(rows[0].classList.contains('self'),
        'the player cannot tell which row is theirs');
    assert.ok(!rows[1].classList.contains('self'),
        'another fighter was marked as the player');
    assert.ok(rows[1].classList.contains('dead'),
        'an eliminated fighter is not marked as out');
    assert.ok(!rows[0].classList.contains('dead'),
        'a living fighter is marked as out');
});

test('a fighter with no name is still a row, not a blank', () => {
    const panel = panelWith(false);

    panel.send('hud', { visible: true, hud: { alive: 1, total: 1, scoreboard: [{ id: 42, kills: 0, alive: true }] } });

    assert.ok(/42/.test(panel.text('hud-scoreboard')),
        'a fighter whose name has not arrived yet renders as nothing at all');
});

test('the scoreboard is capped, so a big lobby does not fill the screen', () => {
    const panel = panelWith(false);
    const many = [];
    for (let i = 1; i <= 25; i += 1) many.push({ id: i, name: 'P' + i, kills: 0, alive: true });

    panel.send('hud', { visible: true, hud: { alive: 25, total: 25, scoreboard: many } });

    assert.strictEqual(panel.node('hud-scoreboard').children.length, 10,
        'the scoreboard drew every fighter in a twenty-five player lobby');
});

test('and it is REDRAWN each push, not appended to', () => {
    // The container is cleared first. Without that every sweep stacks
    // another copy of the board on the last one, once a second, for the
    // whole round.
    const panel = panelWith(false);
    const rows = [{ id: 7, name: 'Ada', kills: 0, alive: true }];

    const push = { visible: true, hud: { alive: 1, total: 1, scoreboard: rows } };
    panel.send('hud', push);
    panel.send('hud', push);
    panel.send('hud', push);

    assert.strictEqual(panel.node('hud-scoreboard').children.length, 1,
        'the scoreboard is stacking a fresh copy on every sweep');
});

test('hiding the HUD takes it down', () => {
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: { alive: 2, total: 2 } });

    panel.send('hud', { visible: false });

    assert.strictEqual(shown(panel, 'arena-hud'), false,
        'the overlay stayed up after the round ended');
});

// ======================================================================
// THE END-OF-MATCH BOARD
// ======================================================================

test('winning says so, in those words', () => {
    const panel = panelWith(false);

    panel.send('results', { results: { won: true, placement: 1, kills: 4, deaths: 1 } });

    assert.ok(panel.built('arena-results'), 'no results board was drawn at all');
    assert.ok(/You Won/i.test(panel.text('arena-results')),
        'a winner was not told they won: ' + panel.text('arena-results'));
});

test('and losing does not', () => {
    const panel = panelWith(false);

    panel.send('results', { results: { won: false, placement: 4, kills: 0, deaths: 1 } });

    const text = panel.text('arena-results');
    assert.ok(!/You Won/i.test(text), 'a player who lost was congratulated: ' + text);
    assert.ok(/Match Over/i.test(text), 'the board says nothing at all: ' + text);
});

test('and it says HOW the round ended, in words', () => {
    /* The field used to carry a locale key, which this page has no locale
       file to render -- so it was dead on the wire for as long as it
       existed. The server renders the sentence now. */
    const panel = panelWith(false);

    panel.send('results', { results: { won: false, reason: 'Match over. Clock ran out.', kills: 0, deaths: 1 } });

    assert.ok(/Clock ran out/.test(panel.text('arena-results')),
        'the board never says how the round ended: ' + panel.text('arena-results'));
});

test('and an older server that sends no sentence still gets a board', () => {
    // Absent, not empty: the board looks exactly as it did before.
    const panel = panelWith(false);

    panel.send('results', { results: { won: true, kills: 1, deaths: 0 } });

    assert.ok(panel.built('arena-results'), 'the board vanished when the sentence was missing');
    assert.ok(/You Won/i.test(panel.text('arena-results')),
        'the board lost its title along with the sentence: ' + panel.text('arena-results'));
});

test('the summary line carries placement, kills and deaths', () => {
    const panel = panelWith(false);

    panel.send('results', { results: { won: false, placement: 3, kills: 2, deaths: 1 } });

    const text = panel.text('arena-results');
    assert.ok(/#3/.test(text), 'the board does not say where they placed: ' + text);
    assert.ok(/2 kills/.test(text), 'the board does not say what they scored: ' + text);
    assert.ok(/1 death/.test(text), 'the board does not say how often they died: ' + text);
});

test('and says one kill in the singular', () => {
    const panel = panelWith(false);

    panel.send('results', { results: { won: true, kills: 1, deaths: 1 } });

    const text = panel.text('arena-results');
    assert.ok(/1 kill\b/.test(text) && !/1 kills/.test(text),
        'the board reads "1 kills": ' + text);
});

test('EARNINGS are shown when there were any', () => {
    const panel = panelWith(true);

    panel.send('results', { results: { won: true, kills: 3, deaths: 0, earnings: 4500 } });

    assert.ok(/Won \$4,500/.test(panel.text('arena-results')),
        'a player was not told what they won: ' + panel.text('arena-results'));
});

test('and on a server whose betting switch this client never fetched', () => {
    // Read off the NUMBER rather than off the switch: earnings only exist
    // when there was a pot, and the switch lives in a snapshot a client
    // that joined mid-round may never have had.
    const panel = loadPanel(ROOT);

    panel.send('results', { results: { won: true, earnings: 900 } });

    assert.ok(/Won \$900/.test(panel.text('arena-results')),
        'a winner was not shown their money because the config had not arrived: '
        + panel.text('arena-results'));
});

test('but nothing is claimed where there were none', () => {
    const panel = panelWith(true);

    panel.send('results', { results: { won: true, kills: 1, deaths: 0, earnings: 0 } });

    assert.ok(!/Won \$/.test(panel.text('arena-results')),
        'a round with no pot told the player they won money: ' + panel.text('arena-results'));
});

test('the board lists the final scoreboard too', () => {
    const panel = panelWith(false);

    panel.send('results', {
        results: {
            won: false,
            scoreboard: [
                { id: 9, name: 'Ada', kills: 5, alive: true },
                { id: 7, name: 'Ben', kills: 1, alive: false },
            ],
        },
    });

    const text = panel.text('arena-results');
    assert.ok(/Ada/.test(text) && /Ben/.test(text),
        'the final board does not name the fighters: ' + text);
});

test('a results push takes the live overlay down with it', () => {
    // The round is over: the overlay and the countdown come down and the
    // board goes up in their place. An overlay left running counts down a
    // round that has ended.
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: { alive: 2, total: 2, timeLeft: 30 } });
    assert.strictEqual(shown(panel, 'arena-hud'), true, 'the overlay was never up');

    panel.send('results', { results: { won: true } });

    assert.strictEqual(shown(panel, 'arena-hud'), false,
        'the live overlay was left running over the results board');
});

test('and a second one REPLACES the first rather than stacking', () => {
    const panel = panelWith(false);

    panel.send('results', { results: { won: true, kills: 9 } });
    panel.send('results', { results: { won: false, kills: 1 } });

    const text = panel.text('arena-results');
    assert.ok(/Match Over/i.test(text), 'the second board never replaced the first: ' + text);
    assert.ok(!/You Won/i.test(text), 'both boards are on screen at once: ' + text);
});

test('a results payload that is not an object draws no board', () => {
    // It arrives off the wire. Indexing it unconditionally is a page-wide
    // raise for anybody a malformed push reaches.
    [null, undefined, 42, 'results'].forEach((bad) => {
        const panel = panelWith(false);
        panel.send('results', { results: bad });
        assert.ok(!panel.built('arena-results'),
            'a board was drawn from a payload of ' + String(bad));
    });
});

test('the board is inert, so it cannot swallow a click meant for the game', () => {
    // A scoreboard that took NUI focus would take the controls of a player
    // who has just been dropped back at the lobby ped.
    const panel = panelWith(false);

    panel.send('results', { results: { won: true } });

    assert.strictEqual(panel.node('arena-results').style.pointerEvents, 'none',
        'the results board swallows clicks meant for the game underneath it');
});

test('a team round names the side that took it, on everybody\'s card', () => {
    /* THE ONE FACT THE CARD DID NOT CARRY. "You Won" is about the reader,
       the placement is about the reader, and the rows are individuals -- so
       nothing on the board said which side had won, and a spectator, who is
       sent this board and nothing else at the end of a round, was never told
       how the fight they had just watched finished. */
    const panel = panelWith(false);
    panel.send('results', {
        results: { won: false, winningTeam: 'red', reason: 'Match over.', kills: 0, deaths: 2 },
    });

    const text = panel.text('arena-results');
    assert.ok(/Red/.test(text), 'the winning side is missing from the board: ' + text);
    assert.ok(/takes it/i.test(text), 'and it should read as a result: ' + text);
});

test('and a free-for-all card carries no side at all', () => {
    /* The server sends the field only for team modes; a panel that drew
       something for a free-for-all would be inventing a side. */
    const panel = panelWith(false);
    panel.send('results', { results: { won: true, placement: 1, kills: 4, deaths: 1 } });

    const text = panel.text('arena-results');
    assert.ok(!/takes it/i.test(text), 'a free-for-all card named a winning side: ' + text);
});

test('and a side this server does not have is not drawn as one', () => {
    /* teamByKey answers null for a key the snapshot does not carry, and the
       line is skipped rather than drawn with a raw key in it. */
    const panel = panelWith(false);
    panel.send('results', { results: { won: true, winningTeam: 'nosuchteam', kills: 1, deaths: 0 } });

    const text = panel.text('arena-results');
    assert.ok(!/nosuchteam/.test(text), 'the raw key was printed on the card: ' + text);
    assert.ok(/You Won/i.test(text), 'and the rest of the card should still be there: ' + text);
});

console.log('');
test('THE UNTRUTH: a round nobody can be eliminated from counted down anyway', () => {
    /* Under a ladder, a kill limit or most kills nobody is ever out, so
       `remaining` equals `total` from the first second to the last. A header
       shaped like a countdown then says people are being knocked out when
       none can be, and a fighter watching it wonders why it never moves. */
    const panel = loadPanel(ROOT);
    panel.send('hud', {
        visible: true,
        hud: { remaining: 6, total: 6, kills: 2, deaths: 1, timeLeft: 300, livesSpent: false },
    });

    const text = panel.node('hud-alive').textContent;
    assert.ok(!/Remaining/.test(text),
        'the header still counts down in a round with no eliminations: ' + text);
    assert.ok(/6 fighters/.test(text),
        'the header does not say how many are in the round: ' + text);
});

test('and a round that DOES eliminate still counts down, which is the control', () => {
    const panel = loadPanel(ROOT);
    panel.send('hud', {
        visible: true,
        hud: { remaining: 3, total: 8, kills: 2, deaths: 1, timeLeft: 300, livesSpent: true },
    });

    assert.strictEqual(panel.node('hud-alive').textContent, 'Remaining 3 / 8',
        'the countdown was taken off a round that has one');
});

test('and a payload with no livesSpent field counts as it always did', () => {
    /* Older servers, and any snapshot written before the field existed. */
    const panel = loadPanel(ROOT);
    panel.send('hud', {
        visible: true,
        hud: { remaining: 3, total: 8, kills: 2, deaths: 1, timeLeft: 300 },
    });

    assert.strictEqual(panel.node('hud-alive').textContent, 'Remaining 3 / 8',
        'a snapshot with no livesSpent field lost its header');
});

console.log('==> what the overlay tells a fighter the round is won on');

/* A panel whose team list has BOTH sides in it, because the goal line puts
   the reader's own side first by label and a fixture with one team cannot
   tell that apart from a fixture with none. */
function teamPanel() {
    const panel = loadPanel(ROOT);
    const snap = snapshot(false);
    snap.config.teams.list = [
        { key: 'crimson', label: 'Crimson', color: '#c81020' },
        { key: 'ash', label: 'Ash', color: '#888888' },
    ];
    panel.send('open', snap);
    return panel;
}

test('a score_limit round names the limit and both sides, own side first', () => {
    /* THE DEFECT, MEASURED against a real four-man round: the round ends the
       instant a side reaches the limit, and the overlay named neither the
       limit nor anybody's total. A team racing to 25 was adding its own
       scoreboard rows up in its head, under fire. */
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 2, deaths: 1,
        winCondition: 'score_limit', scoreLimit: 5,
        // CRIMSON ON PURPOSE. 'ash' sorts before 'crimson' alphabetically,
        // so a reader on ash comes out first whether the rule is applied or
        // not -- the fixture that proves nothing. This one is the other way
        // round, so only the rule can put it first.
        team: 'crimson', teamScores: { crimson: 2, ash: 3 },
    } });

    const said = panel.node('hud-goal').textContent;
    assert.ok(/First to 5/.test(said), 'the limit is not on the overlay: ' + said);
    assert.ok(/Crimson 2/.test(said) && /Ash 3/.test(said),
        'the side totals are missing: ' + said);
    assert.ok(said.indexOf('Crimson 2') < said.indexOf('Ash 3'),
        'the reader\'s own side is not first: ' + said);
    assert.strictEqual(shown(panel, 'hud-goal'), true, 'the goal line stayed hidden');
});

test('and a score_limit round with no teams counts the reader themselves', () => {
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 3, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 7,
    } });

    const said = panel.node('hud-goal').textContent;
    assert.ok(/First to 7/.test(said), 'the limit is not on the overlay: ' + said);
    assert.ok(/You 3/.test(said), 'a free-for-all fighter is not told their own count: ' + said);
});

test('a most_kills round says the clock decides it on kills', () => {
    /* Nothing anywhere said this. A fighter under most_kills read the same
       overlay as one under last_standing and had no way to tell that staying
       alive was not what the round pays for. */
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 1, deaths: 0, winCondition: 'most_kills',
    } });

    assert.ok(/Most kills when the clock stops/.test(panel.node('hud-goal').textContent),
        'the rule is still unstated: ' + panel.node('hud-goal').textContent);
});

test('CONTROL: last_standing and a ladder draw no goal line at all', () => {
    /* last_standing is already expressed by "Remaining 3 / 8" above it, and
       the server sends nothing for a ladder because neither counting rule
       can fire in one. A line invented for either would be a target that
       ends nothing. THIS IS last_standing WITH NO CLOCK AND NO SIDES: a
       team round with a clock is decided on the side totals when it runs
       out, and the test after this one draws those. */
    const standing = panelWith(false);
    standing.send('hud', { visible: true, hud: {
        remaining: 3, total: 8, kills: 0, deaths: 0, winCondition: 'last_standing',
    } });
    assert.strictEqual(standing.node('hud-goal').textContent, '',
        'last_standing invented a goal line: ' + standing.node('hud-goal').textContent);
    assert.strictEqual(shown(standing, 'hud-goal'), false, 'and left it on screen');

    const ladder = panelWith(false);
    ladder.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 0, deaths: 0, scoreboard: [],
    } });
    assert.strictEqual(ladder.node('hud-goal').textContent, '',
        'a ladder round invented a goal line: ' + ladder.node('hud-goal').textContent);
});

test('THE KILL TRACKER: a team last_standing round with a clock shows what the clock decides on', () => {
    /* The shipped default is last_standing with a 600-second clock, and
       when it runs out with both sides still in, the round goes to the side
       with more kills -- a leaver's banked kills included. The server sent
       those totals all round and this line drew none of them, so the round
       was decided on a number nobody saw. */
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 3, total: 3, kills: 1, deaths: 2, timeLeft: 300,
        winCondition: 'last_standing',
        team: 'ash', teamScores: { crimson: 3, ash: 2 }, departedScores: { crimson: 3 },
    } });

    const said = panel.node('hud-goal').textContent;
    assert.ok(/clock runs out/.test(said), 'the line does not say it is the clock that decides: ' + said);
    assert.ok(/Ash 2/.test(said) && /Crimson 3/.test(said), 'the side totals are missing: ' + said);
    assert.ok(/incl\. 3 from fighters who left/.test(said), 'the banked kills are unexplained: ' + said);
    assert.strictEqual(shown(panel, 'hud-goal'), true, 'the line stayed hidden');

    // THE CONTROL: the same round with no clock has nothing to decide it on
    // but who is left standing, and draws nothing.
    const noClock = teamPanel();
    noClock.send('hud', { visible: true, hud: {
        remaining: 3, total: 3, kills: 1, deaths: 2, winCondition: 'last_standing',
        team: 'ash', teamScores: { crimson: 3, ash: 2 },
    } });
    assert.strictEqual(noClock.node('hud-goal').textContent, '',
        'a round with no clock was told the clock decides it: ' + noClock.node('hud-goal').textContent);
});

test('THE KILL TRACKER: the results card carries the side totals, the winner first', () => {
    /* MEASURED: the clock gave crimson the round 3-2 on a leaver's banked
       kills, and the card read "Crimson takes it" over rows where crimson
       had none. The card now says what the round was decided on, the way
       the overlay said it. Crimson wins HERE ON PURPOSE: 'ash' sorts first
       alphabetically, so only the rule can put the winner first. */
    const panel = teamPanel();
    panel.send('results', { results: {
        won: false, winningTeam: 'crimson', reason: 'Match over. Clock ran out.', kills: 1, deaths: 2,
        teamScores: { ash: 2, crimson: 3 }, departedScores: { crimson: 3 },
    } });

    const text = panel.text('arena-results');
    assert.ok(/Crimson 3\s+Ash 2/.test(text), 'the side totals are missing, or the winner is not first: ' + text);
    assert.ok(/incl\. 3 from fighters who left/.test(text), 'the banked kills are unexplained: ' + text);

    // THE CONTROL: a card with no totals -- a free-for-all, or a side left
    // standing alone -- draws no tally and no clause.
    const plain = teamPanel();
    plain.send('results', { results: { won: true, winningTeam: 'crimson', kills: 2, deaths: 0 } });
    assert.ok(!/fighters who left/.test(plain.text('arena-results')) && !/Ash \d/.test(plain.text('arena-results')),
        'a card with no totals invented some: ' + plain.text('arena-results'));
});

test('the goal line does not outlive the round it belongs to', () => {
    /* Every other line on this overlay is blanked when the hud is cleared.
       One that was not would sit a finished round's "First to 25" over the
       next one. */
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 2, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 9,
    } });
    assert.ok(/First to 9/.test(panel.node('hud-goal').textContent), 'the fixture never drew one');

    /* THE REAL CLEARING PATH, which is the only one there is: a `visible:
       false` push is what drops state.hud, and the overlay coming back up
       with nothing in it is what runs the blanking branch. A push that
       merely omits `hud` leaves the last one standing -- true of the timer
       and the kill tally too, and not this line's to change. */
    panel.send('hud', { visible: false });
    panel.send('hud', { visible: true });

    assert.strictEqual(panel.node('hud-goal').textContent, '',
        'the finished round\'s goal line is still on screen: ' + panel.node('hud-goal').textContent);
    assert.strictEqual(shown(panel, 'hud-goal'), false,
        'and it was left visible over the next round');

    // THE CONTROL: the lines beside it blank on exactly the same push, so
    // this is the overlay's own rule and not something invented here.
    assert.strictEqual(panel.node('hud-kills').textContent, '',
        'the fixture is not really on the blanking path');
});

test('and a limit of zero is not advertised as a target of nought', () => {
    const panel = panelWith(false);
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 0, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 0,
    } });

    assert.strictEqual(panel.node('hud-goal').textContent, '',
        'the overlay offered a race to nought: ' + panel.node('hud-goal').textContent);
});

test('the goal line explains kills the board cannot account for', () => {
    /* A side KEEPS the kills of a fighter who walks out -- the server banks
       them and they still end the round -- while the board beside the total
       lists who is here. Measured: rows adding to 0 under a line saying 2.
       Both right, neither reconcilable by looking. */
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 3, total: 3, kills: 0, deaths: 1,
        winCondition: 'score_limit', scoreLimit: 9,
        team: 'crimson', teamScores: { crimson: 2, ash: 1 },
        departedScores: { crimson: 2 },
    } });

    const said = panel.node('hud-goal').textContent;
    assert.ok(/incl\. 2 from fighters who left/.test(said),
        'the unaccounted kills are still unexplained: ' + said);
    assert.ok(/Crimson 2/.test(said), 'and the total itself was lost: ' + said);
});

test('CONTROL: an ordinary round carries no such clause', () => {
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 2, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 9,
        team: 'crimson', teamScores: { crimson: 2, ash: 1 },
    } });

    assert.ok(!/fighters who left/.test(panel.node('hud-goal').textContent),
        'a round nobody left was given the clause: ' + panel.node('hud-goal').textContent);
});

test('and a banked total of zero is not announced as nothing', () => {
    /* The server only sends the field once there is something to explain,
       but a zero arriving any other way must not print "(incl. 0 ...)". */
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 4, total: 4, kills: 2, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 9,
        team: 'crimson', teamScores: { crimson: 2, ash: 1 },
        departedScores: { crimson: 0 },
    } });

    assert.ok(!/incl\./.test(panel.node('hud-goal').textContent),
        'a nought was announced: ' + panel.node('hud-goal').textContent);
});

test('the clause counts every side, not just the reader\'s own', () => {
    /* Both sides can lose a scorer. A note that only added up the reader's
       own would under-explain the gap on the row opposite theirs. */
    const panel = teamPanel();
    panel.send('hud', { visible: true, hud: {
        remaining: 2, total: 2, kills: 0, deaths: 0,
        winCondition: 'score_limit', scoreLimit: 9,
        team: 'crimson', teamScores: { crimson: 3, ash: 4 },
        departedScores: { crimson: 3, ash: 1 },
    } });

    assert.ok(/incl\. 4 from fighters who left/.test(panel.node('hud-goal').textContent),
        'the two sides were not added together: ' + panel.node('hud-goal').textContent);
});

console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
