/*
    crimson_arena/tests/panel/betfocus.test.js

    A PICK THAT OUTLIVED THE MATCH IT WAS MADE ON.

    The Bets tab draws whatever match is focused, and the focus moves on its
    own: clicking another card in the Matches list, being placed in a match,
    starting to watch one. `state.betPick` moved with none of them.

    So backing a fighter on one match and then looking at another left the
    chips with nothing highlighted -- their fighter is not in this match --
    and Place Bet lit anyway, because the gate asked only whether a pick
    existed, not whether it belonged here. The click posted a pick the match
    had never heard of. server/betting.lua refuses that (`pickExists`), so no
    money moved; what the player got was a red toast with nothing on screen
    to explain it.

    A TEAM MODE DID NOT EVEN LOOK WRONG. The pick is a team key there, and
    the same key exists in both matches, so the carried pick simply became
    the highlighted selection for a match nobody had chosen it for -- and
    that bet WAS accepted.

    Both directions are asserted, on the wire and on the disabled state: the
    stale pick must not post, and a pick made on the match in front of you
    must still work.
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

/* Two matches with DIFFERENT fighters in them, so a pick from one cannot be
   mistaken for a valid pick in the other. The player is in neither and is
   watching neither -- which is what makes the Matches list the only thing
   deciding what the Bets tab shows. */
function snapshot(teams) {
    function match(id, label, ids) {
        return {
            id: id, arenaKey: 'a', arenaLabel: 'Arena', label: label,
            modeKey: teams ? 'tdm' : 'ffa', modeLabel: 'Mode', state: 'lobby',
            teams: teams === true, playerCount: ids.length, hostName: 'Host',
            pot: 0, entryFee: 0, betsOpen: true,
            teamCounts: teams ? { crimson: 1, ash: 1 } : {},
            players: ids.map(function (id, at) {
                return {
                    id: id, name: 'Fighter ' + id, alive: true,
                    team: teams ? (at % 2 === 0 ? 'crimson' : 'ash') : null,
                };
            }),
        };
    }

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: teams ? 'tdm' : 'ffa', label: 'Mode', enabled: true, teams: teams === true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true,
                currencySymbol: '$',
                payout: 'winner_takes_all',
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2, oneBetPerMatch: true },
                fighterBets: { enabled: true, min: 100, max: 50000, ownSideOnly: true, oneBetPerMatch: true },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: teams ? [{ key: 'crimson', label: 'Crimson' }, { key: 'ash', label: 'Ash' }] : [] },
            ui: {},
        },
        player: {
            serverId: SELF, money: 100000, wallet: { cash: 100000, bank: 100000 },
            matchId: null, spectating: null, team: false,
        },
        matches: [match('m1', 'First', [11, 12]), match('m2', 'Second', [21, 22])],
        leaderboard: [],
    };
}

function opened(teams) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(teams);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function clickNode(node) {
    (node.listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() {}, preventDefault() {} });
    });
}

/** Points the Bets tab at a match by clicking its card, the way a player does. */
function focusMatch(panel, label) {
    const card = panel.node('match-list').children.find(function (c) {
        return (c.children || []).some(function (kid) { return kid.textContent === label; });
    });
    assert.ok(card, 'no card titled ' + label + ' in the match list');
    clickNode(card);
}

/** Clicks the chip with this label, and asserts it was offered at all. */
function pick(panel, label) {
    const chip = panel.node('bet-pick').children.find(function (c) { return c.textContent === label; });
    assert.ok(chip, 'no chip labelled ' + label + '; there were: '
        + panel.node('bet-pick').children.map(function (c) { return c.textContent; }).join(', '));
    clickNode(chip);
}

function placeBet(panel) {
    panel.type('bet-amount', '500');
    panel.fire('bet-submit', 'click');
    return panel.posted.filter(function (p) { return p.name === 'spectatorBet'; });
}

function activeChips(panel) {
    return panel.node('bet-pick').children.filter(function (c) {
        return c.classList && c.classList.contains('active');
    }).map(function (c) { return c.textContent; });
}

console.log('==> a free-for-all pick does not follow you to another match');

test('THE BUG: the pick from one match left Place Bet lit on another', () => {
    const panel = opened(false);

    focusMatch(panel, 'First');
    pick(panel, 'Fighter 11');
    assert.deepStrictEqual(activeChips(panel), ['Fighter 11'],
        'the pick did not take on the match it was made on');

    focusMatch(panel, 'Second');

    assert.deepStrictEqual(activeChips(panel), [],
        'a fighter from the other match was shown as the selection here');
    assert.strictEqual(panel.node('bet-submit').disabled, true,
        'Place Bet was lit with nothing selected on this match');
    assert.ok(/choose who/i.test(panel.text('bet-hint')),
        'the screen did not ask for a pick: ' + panel.text('bet-hint'));
    assert.strictEqual(placeBet(panel).length, 0,
        'the panel posted a pick belonging to a different match');
});

test('and picking again on the new match works normally', () => {
    // The other direction, and the reason the first is worth something: a
    // fix that simply refused every bet would pass it.
    const panel = opened(false);

    focusMatch(panel, 'First');
    pick(panel, 'Fighter 11');
    focusMatch(panel, 'Second');
    pick(panel, 'Fighter 21');

    assert.deepStrictEqual(activeChips(panel), ['Fighter 21']);

    const sent = placeBet(panel);
    assert.strictEqual(sent.length, 1, 'a pick made on this match was refused: ' + panel.text('bet-hint'));
    assert.strictEqual(sent[0].body.matchId, 'm2');
    assert.strictEqual(String(sent[0].body.pick), '21', 'the wrong fighter was backed');
});

test('and the pick is bound to its match, not thrown away by looking elsewhere', () => {
    /* The distinction this fix turns on. The pick is not cleared on every
       focus change -- it is TIED to the match it was made on -- so glancing
       at another match and coming back finds the choice the player actually
       made still standing, while the match they glanced at never sees it.
       Clearing on any change would pass the two tests above and cost the
       player their pick for looking. */
    const panel = opened(false);

    focusMatch(panel, 'First');
    pick(panel, 'Fighter 11');
    focusMatch(panel, 'Second');
    focusMatch(panel, 'First');

    assert.deepStrictEqual(activeChips(panel), ['Fighter 11'],
        'the pick made on this match was lost by looking at another one');

    const sent = placeBet(panel);
    assert.strictEqual(sent.length, 1, 'the bet was refused on the match it was picked for');
    assert.strictEqual(sent[0].body.matchId, 'm1');
    assert.strictEqual(String(sent[0].body.pick), '11');
});

console.log('');
console.log('==> and a TEAM pick, which is the one that did not look wrong');

test('THE BUG: a team key exists in both matches, so the pick carried silently', () => {
    /* The FFA case at least showed an empty selection. Here the same key is
       on both matches, so the carried pick was drawn as the active chip and
       the bet was ACCEPTED -- on a match the player had never picked a side
       for. */
    const panel = opened(true);

    focusMatch(panel, 'First');
    pick(panel, 'Crimson');
    focusMatch(panel, 'Second');

    assert.deepStrictEqual(activeChips(panel), [],
        'the side picked on the other match was shown as chosen here');
    assert.strictEqual(placeBet(panel).length, 0,
        'a side-bet went out on a match the player never picked a side for');
});

test('and a side picked on THIS match still goes through', () => {
    const panel = opened(true);

    focusMatch(panel, 'Second');
    pick(panel, 'Crimson');

    const sent = placeBet(panel);
    assert.strictEqual(sent.length, 1, 'a side picked here was refused: ' + panel.text('bet-hint'));
    assert.strictEqual(sent[0].body.matchId, 'm2');
    assert.strictEqual(sent[0].body.pick, 'crimson');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length) {
    failures.forEach(function (f) { console.log('  - ' + f.name + ': ' + f.error.message); });
    process.exit(1);
}
