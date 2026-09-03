/*
    crimson_arena/tests/panel/betgate.test.js

    TWO BUTTONS THAT STAYED LIT OVER RULES THE SERVER HAD ALREADY DECIDED.

    Both refusals were correct on the server and invisible to the panel, so
    both arrived as a red toast after a click on a control that looked
    willing:

      PLACE BET, ON A ROUND WHOSE BOOK HAS SHUT. server/betting.lua stops
      taking side-bets `closeAfterStartSeconds` after the fighting starts --
      thirty seconds on the shipped config. Nothing carried that to the
      panel, so for the remaining minutes of every live round the button
      offered a bet and answered "Book is closed on this one."

      JOIN, ON A MATCH THE PLAYER HAS MONEY ON. Backing a match and then
      taking a seat in it is refused -- a bet whose holder can cancel it by
      joining and walking straight out again is a bet with no risk in it --
      and the panel could not see the bet at all. `player.bet` reports the
      bet on the match they are IN or WATCHING, and a side-bet is placed
      from the Bets tab on a match they are doing neither with.

    Both are asserted on the DISABLED STATE and on the wire: a button that
    looks refused and posts anyway is the same defect wearing a different
    coat.
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
const RIVAL = 9;

/*
 * `betsOpen` and `backing` are the two fields under test; both are left
 * UNSET by default so the tests below have to switch them on, and so the
 * "an older server sends neither" case is the shape the defaults describe.
 */
function snapshot(options) {
    const o = Object.assign({
        state: 'lobby',
        betsOpen: undefined,
        backing: undefined,
        who: 'spectator',
    }, options || {});

    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: 'ffa', modeLabel: 'Mode', state: o.state,
        teams: false, playerCount: 2, hostName: 'Host', pot: 0, entryFee: 0,
        teamCounts: {},
        players: [
            { id: RIVAL, name: 'Rival', team: null, alive: true },
            { id: 11, name: 'Other', team: null, alive: true },
        ],
    };
    if (o.betsOpen !== undefined) match.betsOpen = o.betsOpen;

    const player = {
        serverId: SELF,
        money: 100000,
        wallet: { cash: 100000, bank: 100000 },
        matchId: o.who === 'fighter' ? 'm1' : null,
        // A spectator is looking at a match -- that is what makes them one
        // rather than somebody with the panel open -- and it is also what
        // points the Bets tab at a match to draw chips for.
        spectating: o.who === 'fighter' ? false : 'm1',
        team: false,
    };
    if (o.backing !== undefined) player.backing = o.backing;

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'Mode', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true,
                currencySymbol: '$',
                payout: 'winner_takes_all',
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2 },
                fighterBets: { enabled: true, min: 100, max: 50000, ownSideOnly: true },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: player,
        matches: [match],
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

/** Picks a fighter to back and presses Place Bet. */
function tryToBet(panel) {
    panel.type('bet-amount', '500');
    const chip = panel.node('bet-pick').children.find((c) => (c.textContent || '') === 'Rival');
    assert.ok(chip, 'no chip to back; there were: '
        + panel.node('bet-pick').children.map((c) => c.textContent).join(', '));
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
    panel.fire('bet-submit', 'click');
    return panel.posted.filter((p) => p.name === 'spectatorBet');
}

console.log('==> the book shuts part-way into a live round');

test('THE BUG: a live round with the book shut still offered the bet', () => {
    const panel = opened({ state: 'live', betsOpen: false });

    assert.strictEqual(tryToBet(panel).length, 0,
        'the panel posted a bet the server had already closed the book on');
    assert.strictEqual(panel.node('bet-submit').disabled, true,
        'Place Bet was still lit on a round whose book has shut');
    assert.ok(/book closed/i.test(panel.text('bet-hint')),
        'the screen did not say why: ' + panel.text('bet-hint'));
});

test('and the same round takes bets while the window is still open', () => {
    // The other direction, and the reason the first is worth something: a
    // panel that refused every live round would pass that test and take
    // nobody's bet in the thirty seconds it is supposed to.
    const panel = opened({ state: 'live', betsOpen: true });

    const sent = tryToBet(panel);
    assert.strictEqual(sent.length, 1,
        'a bet inside the open window was refused by the panel: ' + panel.text('bet-hint'));
    assert.strictEqual(sent[0].body.matchId, 'm1');
});

test('a lobby is never refused for this', () => {
    const panel = opened({ state: 'lobby', betsOpen: true });
    assert.strictEqual(tryToBet(panel).length, 1,
        'a bet on a lobby was refused: ' + panel.text('bet-hint'));
});

test('and a server that sends no answer is given the benefit of the doubt', () => {
    /* Read as `=== false` rather than `!== true`. A snapshot assembled
       before this field existed must keep offering the bet and let the
       server refuse it -- a panel that refuses on an absent field takes the
       feature away from anybody running a mismatched pair. */
    const panel = opened({ state: 'live', betsOpen: undefined });
    assert.strictEqual(tryToBet(panel).length, 1,
        'an absent betsOpen was read as a closed book: ' + panel.text('bet-hint'));
});

console.log('');
console.log('==> and a match you have money on is not one you can join');

test('THE BUG: Join was lit on a match this player had backed', () => {
    const panel = opened({ state: 'lobby', backing: ['m1'] });

    assert.ok(panel.built('match-join-m1'), 'the join button was never built');
    const join = panel.node('match-join-m1');
    assert.strictEqual(join.disabled, true,
        'Join was offered on a match the server refuses this player a seat in');
    assert.ok(/money on this match/i.test(String(join.title)),
        'the button did not say why: ' + join.title);

    panel.fire('match-join-m1', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'joinMatch').length, 0,
        'the panel posted a join the server had already decided to refuse');
});

test('and a match they have NOT backed is joinable', () => {
    const panel = opened({ state: 'lobby', backing: ['someOtherMatch'] });

    const join = panel.node('match-join-m1');
    assert.notStrictEqual(join.disabled, true,
        'a match this player has no money on was refused: ' + join.title);

    panel.fire('match-join-m1', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'joinMatch').length, 1,
        'the join never reached the wire');
});

test('and an empty list refuses nothing', () => {
    const panel = opened({ state: 'lobby', backing: [] });
    panel.fire('match-join-m1', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'joinMatch').length, 1,
        'an empty backing list was read as backing everything');
});

test('and a server that sends no list at all refuses nothing either', () => {
    const panel = opened({ state: 'lobby', backing: undefined });
    panel.fire('match-join-m1', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'joinMatch').length, 1,
        'an absent backing list was read as backing everything');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    console.log('Failures:');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
