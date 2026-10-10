/*
    crimson_arena/tests/panel/betscreen.test.js

    THE BETS TAB, AFTER IT WAS MADE READABLE.

    What the tab held before this: one paragraph of about a hundred words at
    the top of the form, two summary figures saying the same rule in
    different words, a bare number box, and a row of chips carrying nothing
    but names. The one thing a bettor needs -- how much money is already on
    each side -- was computed on the server, sent down the wire as
    `betPool`, and shown nowhere at all.

    THESE ARE THE FACTS THAT MUST KEEP REACHING THE SCREEN. Every one of them
    is a thing the panel can only get right by reading the snapshot: the
    money per side, which of those sides is the player's own, whose stake it
    is in a team match, and which of the two payout rules this server runs.
    A test that asserted the wording would pass on a panel that had stopped
    reading any of them, so these assert the NUMBERS and the POSTED PAYLOAD.
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

const SELF = 7;

/* One match with a book already open on it: 1,800 on Rico and 800 on Marla,
   which is 2,600 -- the same figure server/lobby.lua sends as `betPool`, so
   a panel that adds the breakdown up must land on the number beside it. */
function snapshot(over) {
    const teams = (over || {}).teams === true;
    const snap = {
        config: {
            arenas: [{ key: 'a', label: 'Warehouse', enabled: true }],
            modes: [{ key: 'm', label: 'Mode', enabled: true, teams: teams }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true,
                currencySymbol: '$',
                account: 'cash',
                accounts: ['cash', 'bank'],
                payout: 'winner_takes_all',
                entryFee: { enabled: true, min: 100, max: 5000, default: 500 },
                spectatorBets: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2, oneBetPerMatch: true },
                fighterBets: { enabled: true, min: 100, max: 50000, ownSideOnly: true, oneBetPerMatch: true },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: teams ? [{ key: 'crimson', label: 'Crimson' }, { key: 'ash', label: 'Ash' }] : [] },
            ui: {},
        },
        player: {
            serverId: SELF, money: 12000, wallet: { cash: 12000, bank: 48000 },
            matchId: null, spectating: null, team: false, backing: [], bet: null,
        },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Warehouse', label: 'Friday Night',
            modeKey: 'm', modeLabel: 'Mode', state: 'lobby', teams: teams,
            playerCount: 4, hostName: 'Dave', pot: 2000, entryFee: 500,
            betsOpen: true, fighterBetsOpen: true,
            bets: 2, betPool: 2600,
            /* NESTED BY SETTLEMENT POOL, as server/lobby.lua sends it.
               'all' is the shared pool, which is what betPayout.sharedPool
               ships. The split-pool cases are at the foot of this file. */
            betsByPick: { all: teams ? { crimson: 1800, ash: 800 } : { 11: 1800, 12: 800 } },
            teamCounts: teams ? { crimson: 2, ash: 2 } : {},
            players: [
                { id: 11, name: 'Rico', alive: true, team: teams ? 'crimson' : null },
                { id: 12, name: 'Marla', alive: true, team: teams ? 'ash' : null },
                { id: 13, name: 'Teejay', alive: true, team: teams ? 'crimson' : null },
                { id: 14, name: 'Bones', alive: false, team: teams ? 'ash' : null },
            ],
        }],
        leaderboard: [],
    };
    if (over && typeof over.edit === 'function') over.edit(snap);
    return snap;
}

/* Opens the panel AND points the Bets tab at the match, by clicking its card
   the way a player does. The tab follows whatever match is focused on the
   Matches list and focuses nothing on its own, so a test that skips this
   asserts against "No match picked" and proves only that. */
function opened(over) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(over);
    panel.send('open', snap);
    panel.send('state', snap);

    const card = panel.node('match-list').children[0];
    if (card) clickNode(card);
    return panel;
}

function clickNode(node) {
    (node.listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() {}, preventDefault() {} });
    });
}

/** Every string anywhere under a node, flattened -- the rendered text. */
function textOf(node) {
    let out = String(node.textContent || '');
    (node.children || []).forEach(function (kid) { out += ' ' + textOf(kid); });
    return out;
}

function chips(panel) {
    return panel.node('bet-pick').children.filter(function (c) {
        return (c.classList || { contains() { return false; } }).contains('bet-chip');
    });
}

console.log('==> betscreen.test.js');

// ------------------------------------------------------------------
// The book on screen
// ------------------------------------------------------------------

test('every chip carries the money already staked on that side', () => {
    const panel = opened();
    const text = chips(panel).map(textOf).join(' | ');
    assert.ok(/Rico[\s\S]*\$1,800/.test(text), 'Rico chip did not carry 1,800: ' + text);
    assert.ok(/Marla[\s\S]*\$800/.test(text), 'Marla chip did not carry 800: ' + text);
});

test('a side nobody has backed says so rather than showing nothing', () => {
    const panel = opened();
    const teejay = chips(panel).find(function (c) { return /Teejay/.test(textOf(c)); });
    assert.ok(teejay, 'no Teejay chip');
    assert.ok(/no bets yet/i.test(textOf(teejay)),
        'a side with nothing on it was silent about it: ' + textOf(teejay));
});

test('the split is drawn in proportion, and rounds to whole percents', () => {
    const panel = opened();
    const text = textOf(panel.node('bet-split'));
    // 1800/2600 = 69.23%, 800/2600 = 30.77%
    assert.ok(/69%/.test(text), 'no 69% in the key: ' + text);
    assert.ok(/31%/.test(text), 'no 31% in the key: ' + text);
});

test('DEFECT: a match with no bets on it says the first one wins nothing alone', () => {
    const panel = opened({ edit(s) { s.matches[0].bets = 0; s.matches[0].betPool = 0; s.matches[0].betsByPick = {}; } });
    const text = textOf(panel.node('bet-split'));
    assert.ok(/No side-bets/i.test(text), 'silent on an empty book: ' + text);
    assert.ok(/nobody/i.test(text),
        'it did not say a lone bet has nothing to win from: ' + text);
});

test('an older server that sends no breakdown is not a crash, and not a lie', () => {
    const panel = opened({ edit(s) { delete s.matches[0].betsByPick; } });
    const text = chips(panel).map(textOf).join(' | ');
    assert.ok(/Rico/.test(text), 'the chips did not survive a missing breakdown');
    assert.ok(!/\$1,800/.test(text), 'it invented a figure it was never sent: ' + text);
});

test('the summary quotes the SERVER pool, never the panel’s own sum', () => {
    /* betPool is what settlement divides. If a bet ever carries no pick the
       breakdown under-counts, and the figure on screen must still be the
       one the server will actually pay out of. */
    const panel = opened({ edit(s) { s.matches[0].betsByPick = { all: { 11: 100 } }; } });
    assert.ok(/\$2,600/.test(textOf(panel.node('bet-summary'))),
        'the panel quoted its own sum instead of betPool: ' + textOf(panel.node('bet-summary')));
});

// ------------------------------------------------------------------
// Whose money it is
// ------------------------------------------------------------------

test('DEFECT: a team’s stake is named as the team’s, not as each fighter’s', () => {
    /* Two fighters on a side carrying 1,800 between them both used to read
       "$1,800 bet on them", which totals 3,600 on a tab whose own summary
       says 2,600. */
    const panel = opened({ teams: true });
    const list = textOf(panel.node('bet-list'));
    assert.ok(/\$1,800 on Crimson/.test(list), 'the side was not named: ' + list);
    assert.ok(!/\$1,800 bet on them/.test(list),
        'a team stake was still credited to one fighter: ' + list);
});

test('and in a free-for-all it IS that fighter’s, so it still says so', () => {
    const panel = opened();
    assert.ok(/\$1,800 bet on them/.test(textOf(panel.node('bet-list'))),
        'a personal stake lost its wording: ' + textOf(panel.node('bet-list')));
});

test('a fighter who is out says so in words, not only in grey', () => {
    const panel = opened();
    const list = textOf(panel.node('bet-list'));
    assert.ok(/Bones[\s\S]*Out of the round/.test(list), 'no state on the row: ' + list);
    assert.ok(/Rico[\s\S]*Still in/.test(list), 'no state on a live row: ' + list);
});

test('the row you are backing is marked, and only that row', () => {
    const panel = opened({ edit(s) { s.player.bet = { pick: '11', amount: 400 }; } });
    const marked = panel.node('bet-list').children.filter(function (row) {
        return row.classList && row.classList.contains('backed');
    });
    assert.strictEqual(marked.length, 1, 'expected exactly one marked row, got ' + marked.length);
    assert.ok(/Rico/.test(textOf(marked[0])), 'the wrong row was marked: ' + textOf(marked[0]));
});

// ------------------------------------------------------------------
// The stake
// ------------------------------------------------------------------

test('the top quick stake is the SMALLER of the ceiling and the balance', () => {
    /* max is 1,000 and cash is 12,000, so 1,000 binds. */
    const panel = opened();
    const text = textOf(panel.node('bet-quick'));
    assert.ok(/\$1,000/.test(text), 'the operator ceiling was not offered: ' + text);
    assert.ok(!/\$12,000/.test(text), 'it offered more than the rules allow: ' + text);
});

test('and when the wallet is the smaller of the two, the wallet binds', () => {
    const panel = opened({ edit(s) { s.player.wallet = { cash: 300, bank: 5 }; s.player.money = 300; } });
    /* THE BUTTONS ONLY. The line beside them states the operator's allowed
       band and is right to name 1,000 there -- it is what the RULES permit,
       not what this account can pay. Reading the whole row would fail this
       test on a correct panel. */
    const buttons = panel.node('bet-quick').children
        .filter(function (c) { return c.classList && c.classList.contains('bet-quick-chip'); })
        .map(function (c) { return String(c.textContent); });
    assert.ok(buttons.indexOf('$300') !== -1, 'the balance was not the ceiling: ' + buttons.join(' '));
    assert.ok(buttons.indexOf('$1,000') === -1,
        'it offered a stake the account cannot cover: ' + buttons.join(' '));
});

test('too poor for the smallest bet gets a sentence, not a row of dead buttons', () => {
    const panel = opened({ edit(s) { s.player.wallet = { cash: 10, bank: 5 }; s.player.money = 10; } });
    const text = textOf(panel.node('bet-quick'));
    assert.ok(/smallest bet/i.test(text) && /\$50/.test(text) && /\$10/.test(text),
        'it did not say what was needed and what was held: ' + text);
});

test('a quick stake fills the box AND is what gets posted', () => {
    const panel = opened();
    const rico = chips(panel).find(function (c) { return /Rico/.test(textOf(c)); });
    clickNode(rico);

    const five = panel.node('bet-quick').children.find(function (c) {
        return String(c.textContent) === '$500';
    });
    assert.ok(five, 'no $500 quick stake was offered');
    clickNode(five);

    assert.strictEqual(panel.node('bet-amount').value, '500',
        'the box did not take the quick stake');

    panel.fire('bet-submit', 'click');
    const posts = panel.posted.filter(function (p) { return p.name === 'spectatorBet'; });
    assert.strictEqual(posts.length, 1, 'expected one bet, got ' + posts.length);
    assert.strictEqual(posts[0].body.amount, 500, 'wrong amount: ' + posts[0].body.amount);
    assert.strictEqual(String(posts[0].body.pick), '11', 'wrong pick: ' + posts[0].body.pick);
    assert.strictEqual(posts[0].body.account, 'cash', 'wrong account: ' + posts[0].body.account);
});

// ------------------------------------------------------------------
// Which payout rule is running
// ------------------------------------------------------------------

test('an odds server quotes the multiplier it actually pays', () => {
    const panel = opened({ edit(s) { s.config.betting.betPayout.spectators = 'odds'; } });
    const text = textOf(panel.node('bet-summary')) + ' ' + textOf(panel.node('bet-note'));
    assert.ok(/×2/.test(text), 'no multiplier anywhere: ' + text);
});

test('a pool server quotes NO figure, because none is knowable yet', () => {
    const panel = opened();
    const note = textOf(panel.node('bet-note'));
    assert.ok(/splits everything staked/i.test(note),
        'it did not say a win is a split of the stakes: ' + note);
    assert.ok(!/×2/.test(note), 'it quoted a multiplier nothing pays: ' + note);
});

test('DEFECT: the rules are hidden with the rest of the tab when betting is off', () => {
    /* `bet-note` used to live inside `bet-form` and was hidden by hiding its
       parent. It was moved out to the column beside the roster, and a box
       that hides itself is what an inherited rule stops being once it is no
       longer inherited. */
    const panel = opened({ edit(s) { s.config.betting.enabled = false; } });
    assert.ok(panel.node('bet-note').classList.contains('hidden'),
        'the rules of a game this server does not run were left on screen');
    assert.ok(panel.node('bet-match').classList.contains('hidden'),
        'the match heading was left on screen');
});

// ------------------------------------------------------------------
// Which match the tab is about
// ------------------------------------------------------------------

test('the tab names the match it is pointed at', () => {
    const panel = opened();
    const text = textOf(panel.node('bet-match'));
    assert.ok(/Friday Night/.test(text), 'the match was not named: ' + text);
    assert.ok(/Warehouse/.test(text), 'the arena was not named: ' + text);
});

test('and says so when you are in the round you are betting on', () => {
    const panel = opened({ edit(s) {
        s.player.matchId = 'm1';
        s.matches[0].players.push({ id: SELF, name: 'You', alive: true, team: null });
    } });
    assert.ok(/fighting in this one/i.test(textOf(panel.node('bet-match'))),
        'it did not say you are in this match: ' + textOf(panel.node('bet-match')));
});

test('with no match picked it says that, rather than showing an empty pot', () => {
    const panel = opened({ edit(s) { s.matches = []; } });
    assert.ok(/No match picked/i.test(textOf(panel.node('bet-match'))),
        'it did not say there is nothing selected: ' + textOf(panel.node('bet-match')));
});

// ------------------------------------------------------------------
// Two books, where the operator asked for two
// ------------------------------------------------------------------

/* betPayout.sharedPool off makes the server settle fighters and spectators
   in separate pools and pay each bet a share of its own. A panel reading the
   whole book then describes a contest that is not happening -- measured
   against the real settlement: a fighter staking 1,800 on themselves and a
   spectator staking 800 against them are EACH handed their stake back. */
function splitPools(over) {
    return opened({
        teams: (over || {}).teams,
        edit(s) {
            s.config.betting.betPayout.sharedPool = false;
            s.matches[0].betsByPick = { fighter: { 11: 1800 }, spectator: { 12: 800 } };
            s.matches[0].betPool = 2600;
            s.matches[0].bets = 2;
            if (over && over.edit) over.edit(s);
        },
    });
}

test('DEFECT: a spectator is shown the SPECTATOR pool, not the whole book', () => {
    const panel = splitPools();
    const chipText = chips(panel).map(textOf).join(' | ');
    assert.ok(/\$800/.test(chipText), 'the spectator pool did not reach the chips: ' + chipText);
    assert.ok(!/\$1,800/.test(chipText),
        'THE FIGHTERS\u2019 STAKES WERE SHOWN AS MONEY A SPECTATOR CAN WIN: ' + chipText);
});

test('and the summary quotes that pool, not the flat betPool beside it', () => {
    const panel = splitPools();
    const summary = textOf(panel.node('bet-summary'));
    assert.ok(/\$800/.test(summary), 'the spectator pool is not in the summary: ' + summary);
    assert.ok(!/\$2,600/.test(summary),
        'the flat total was quoted as the money this bettor is playing for: ' + summary);
    assert.ok(/In your pool/.test(summary), 'the figure was not named as one pool: ' + summary);
});

test('a fighter in the same match is shown the FIGHTER pool instead', () => {
    const panel = splitPools({ edit(s) {
        s.player.matchId = 'm1';
        s.matches[0].players.push({ id: SELF, name: 'You', alive: true, team: null });
        s.config.betting.fighterBets.ownSideOnly = false;
    } });
    const summary = textOf(panel.node('bet-summary'));
    assert.ok(/\$1,800/.test(summary), 'the fighter pool is not in the summary: ' + summary);
    assert.ok(!/\$800\b/.test(summary.replace(/\$1,800/g, '')),
        'a fighter was shown the spectators\u2019 money: ' + summary);
});

test('and the rules say out loud that there are two books', () => {
    const panel = splitPools();
    const note = textOf(panel.node('bet-note'));
    assert.ok(/settled separately/i.test(note),
        'nothing on screen said the two kinds do not contest each other: ' + note);
});

test('a shared-pool server says none of that, because it is not true there', () => {
    const panel = opened();
    assert.ok(!/settled separately/i.test(textOf(panel.node('bet-note'))),
        'a shared server was told its pools are split');
    assert.ok(/On side-bets/.test(textOf(panel.node('bet-summary'))),
        'a shared server had its figure renamed as one pool');
});

// ------------------------------------------------------------------
// The three figures that meant something other than their label
// ------------------------------------------------------------------

test('DEFECT: the pot header totals the rows under it, not the prize pool', () => {
    /* `match.pot` is GetPrizePool -- the entry pot PLUS the whole side-bet
       pool wherever includeEntryPot is on, which is the shipped default. It
       was printed as the header of a list that itemises ENTRY FEES: measured
       at 3,000 over two rows of 500. `entryPot` was already on the wire and
       nothing read it. */
    const panel = opened({ edit(s) {
        s.matches[0].pot = 3000;
        s.matches[0].entryPot = 2000;
        s.matches[0].entryFee = 500;
    } });

    const list = textOf(panel.node('bet-list'));
    assert.ok(/\$2,000/.test(list), 'the entry pot is not on the header: ' + list);
    assert.ok(!/\$3,000/.test(list),
        'THE PRIZE POOL WAS PRINTED OVER A LIST OF ENTRY FEES: ' + list);
});

test('and an older server that sends no entryPot still shows a figure', () => {
    const panel = opened({ edit(s) {
        s.matches[0].pot = 3000;
        delete s.matches[0].entryPot;
    } });
    assert.ok(/\$3,000/.test(textOf(panel.node('bet-list'))),
        'dropping entryPot blanked the header instead of falling back');
});

test('DEFECT: an odds server shows the bet COUNT, not an always-empty pool', () => {
    /* betting.lua keeps odds bets out of GetSideBetPool and out of the
       breakdown -- they are the operator's money, not the pool's -- while
       CountSideBets counts them. Side by side that read "$0 on side-bets /
       3 bets" on a match with a real book. */
    const panel = opened({ edit(s) {
        s.config.betting.betPayout.spectators = 'odds';
        s.matches[0].betPool = 0;
        s.matches[0].betsByPick = {};
        s.matches[0].bets = 3;
    } });

    const summary = textOf(panel.node('bet-summary'));
    assert.ok(/Bets placed/.test(summary), 'the count was not offered: ' + summary);
    assert.ok(!/On side-bets\s*\$0/.test(summary.replace(/\s+/g, ' ')),
        'AN EMPTY POOL WAS QUOTED ON A SERVER THAT HAS NO POOL: ' + summary);
});

test('and its chips quote the payout instead of "no bets yet"', () => {
    const panel = opened({ edit(s) {
        s.config.betting.betPayout.spectators = 'odds';
        s.matches[0].betPool = 0;
        s.matches[0].betsByPick = {};
        s.matches[0].bets = 3;
    } });
    const chipText = chips(panel).map(textOf).join(' | ');
    assert.ok(/\u00d72 if they win/.test(chipText),
        'the chips did not say what a win pays: ' + chipText);
    assert.ok(!/no bets yet/.test(chipText),
        'every chip still claimed an empty book: ' + chipText);
});

test('and the split says there is no pool to contest', () => {
    const panel = opened({ edit(s) {
        s.config.betting.betPayout.spectators = 'odds';
        s.matches[0].betPool = 0;
        s.matches[0].betsByPick = {};
        s.matches[0].bets = 3;
    } });
    assert.ok(/no pool to share/i.test(textOf(panel.node('bet-split'))),
        'the split drew an empty book rather than explaining there is none: '
        + textOf(panel.node('bet-split')));
});

test('DEFECT: money on an ELIMINATED fighter is still named, not a raw id', () => {
    /* Nothing returns a side-bet when its pick is eliminated -- only when the
       backer leaves -- so the stake stays on the book. The label map was
       built from the OFFER list, which drops the eliminated, so the money
       showed against a bare server id. */
    const panel = opened({ edit(s) {
        s.matches[0].players[0].alive = false;          // Rico is out
        s.matches[0].betsByPick = { all: { 11: 1800, 12: 800 } };
    } });

    const split = textOf(panel.node('bet-split'));
    assert.ok(/Rico/.test(split),
        'THE ELIMINATED FIGHTER\u2019S STAKE LOST ITS NAME: ' + split);
    assert.ok(!/\b11\b/.test(split), 'a raw server id reached the screen: ' + split);
});

test('DEFECT: a max of 0 is the server\u2019s "one stake only", not "no limit"', () => {
    /* shared/arena.lua: maximum = math.max(minimum, max or minimum). With
       min 50 and max 0 the server accepts 50 and refuses 51, 100 and 500 --
       measured. The panel had its own rule, "0 means unlimited", and offered
       everything up to the player's balance. */
    const panel = opened({ edit(s) {
        s.config.betting.spectatorBets.min = 50;
        s.config.betting.spectatorBets.max = 0;
    } });

    const buttons = panel.node('bet-quick').children
        .filter(function (c) { return c.classList && c.classList.contains('bet-quick-chip'); })
        .map(function (c) { return String(c.textContent); });
    assert.deepStrictEqual(buttons, ['$50'],
        'THE PANEL OFFERED STAKES THE SERVER REFUSES: ' + buttons.join(' '));

    assert.ok(/exactly/i.test(textOf(panel.node('bet-quick'))),
        'the band was not described as the single stake it is: '
        + textOf(panel.node('bet-quick')));
});

test('and it refuses anything above that stake, with the reason', () => {
    const panel = opened({ edit(s) {
        s.config.betting.spectatorBets.min = 50;
        s.config.betting.spectatorBets.max = 0;
    } });
    const rico = chips(panel).find(function (c) { return /Rico/.test(textOf(c)); });
    clickNode(rico);
    panel.type('bet-amount', '500');

    assert.strictEqual(panel.node('bet-submit').disabled, true,
        'a stake the server refuses was offered as placeable');
    assert.ok(/one stake only/i.test(panel.text('bet-hint')),
        'the refusal did not say what the server actually takes: ' + panel.text('bet-hint'));
});

test('a real ceiling still behaves like a ceiling', () => {
    const panel = opened();   // min 50, max 1000
    const buttons = panel.node('bet-quick').children
        .filter(function (c) { return c.classList && c.classList.contains('bet-quick-chip'); })
        .map(function (c) { return String(c.textContent); });
    assert.ok(buttons.length > 1, 'a real band collapsed to one stake: ' + buttons.join(' '));
    assert.ok(buttons.indexOf('$1,000') !== -1, 'the ceiling was not offered: ' + buttons.join(' '));
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) process.exit(1);
