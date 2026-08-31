/*
    crimson_arena/tests/panel/account.test.js

    CHOOSING WHICH POCKET PAYS.

    Betting used to try Config.Betting.accounts in order for the whole
    amount, so a player with money in both was never asked -- the entry fee
    and every bet came out of whichever one the operator had listed first,
    and there was no way to tell before it happened.

    The server tries ONLY the chosen account now. Falling back to the other
    would be spending money out of a pocket the player deliberately left
    alone, which is the same class of mistake as clamping a number somebody
    typed. That makes the panel's job specific: offer the choice, refuse
    against the SAME balance the server will check, and put the pick on the
    wire for the fee as well as the bet.
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

const SELF = 5;
const RIVAL = 9;

function snapshot(options) {
    const o = Object.assign({
        accounts: ['cash', 'bank'],
        wallet: { cash: 100, bank: 90000 },
        inMatch: false,
    }, options || {});

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true,
                currencySymbol: '$',
                account: 'cash',
                accounts: o.accounts,
                payout: 'winner_takes_all',
                entryFee: { enabled: true, min: 0, max: 50000, default: 0, presets: [] },
                spectatorBets: { enabled: true, min: 50, max: 50000, oddsMultiplier: 2 },
                fighterBets: { enabled: true, min: 50, max: 50000, ownSideOnly: true },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: {
            serverId: SELF,
            money: o.wallet.cash,
            wallet: o.wallet,
            matchId: o.inMatch ? 'm1' : null,
            spectating: o.inMatch ? false : 'm1',
        },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Arena', modeKey: 'ffa', modeLabel: 'FFA',
            state: 'lobby', playerCount: 2, hostName: 'Host', pot: 0, entryFee: 500, teams: false,
            players: [
                { id: SELF, name: 'You', alive: true },
                { id: RIVAL, name: 'Rival', alive: true },
            ],
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

/** Clicks the chip whose label starts with this account name. */
function pick(panel, hostId, account) {
    const chip = panel.node(hostId).children.find(
        (c) => (c.textContent || '').toLowerCase().indexOf(account) === 0);
    assert.ok(chip, 'no chip for "' + account + '"; there were: '
        + panel.node(hostId).children.map((c) => c.textContent).join(' | '));
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
}

console.log('==> choosing cash or bank');

test('both accounts are offered, with what is in each', () => {
    const panel = opened();
    const labels = panel.node('bet-account').children.map((c) => c.textContent);
    assert.strictEqual(labels.length, 2, 'the picker did not offer both: ' + labels.join(' | '));
    assert.ok(/Cash/.test(labels[0]) && /\$100/.test(labels[0]), 'cash chip: ' + labels[0]);
    assert.ok(/Bank/.test(labels[1]) && /\$90,?000/.test(labels[1]), 'bank chip: ' + labels[1]);
});

test('a server with one account offers no choice at all', () => {
    // A picker with a single option is a control that answers nothing.
    const panel = opened({ accounts: ['cash'], wallet: { cash: 100 } });
    assert.strictEqual(panel.node('bet-account').children.length, 0,
        'a one-account server drew a picker');
    assert.ok(panel.node('bet-account-row').classList.contains('hidden'),
        'and left the row on screen');
});

test('a bet is refused against the CHOSEN account, not the richest one', () => {
    /* The server tries only what was picked, so a panel checking the wrong
       balance offers a bet that comes back rejected. Cash holds 100; the
       stake is 5000, which the bank could cover and cash cannot. */
    const panel = opened();
    pick(panel, 'bet-account', 'cash');
    panel.type('bet-amount', '5000');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    assert.ok(/do not have .* in Cash/.test(panel.text('bet-hint')),
        'the panel did not refuse against the chosen account: ' + panel.text('bet-hint'));

    panel.fire('bet-submit', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'spectatorBet').length, 0,
        'a bet the chosen account cannot cover was posted anyway');
});

test('and allowed once the account that can cover it is picked', () => {
    const panel = opened();
    panel.type('bet-amount', '5000');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
    pick(panel, 'bet-account', 'bank');
    panel.fire('bet-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'spectatorBet');
    assert.strictEqual(sent.length, 1, 'nothing was posted: ' + JSON.stringify(panel.posted));
    assert.strictEqual(sent[0].body.account, 'bank',
        'the bet was paid from ' + sent[0].body.account);
    assert.strictEqual(sent[0].body.amount, 5000);
});

test('the entry fee carries the choice too, on create', () => {
    const panel = opened();
    pick(panel, 'create-account', 'bank');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'createMatch');
    assert.strictEqual(sent.length, 1, 'nothing was posted: ' + JSON.stringify(panel.posted));
    assert.strictEqual(sent[0].body.account, 'bank',
        'the entry fee was paid from ' + sent[0].body.account);
});

test('and on joining somebody else\'s match', () => {
    const panel = opened();
    pick(panel, 'create-account', 'bank');
    const join = panel.node('match-join-m1');
    assert.ok(panel.built('match-join-m1'), 'the join button was never built');
    (join.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    const sent = panel.posted.filter((p) => p.name === 'joinMatch');
    assert.strictEqual(sent.length, 1, 'nothing was posted: ' + JSON.stringify(panel.posted));
    assert.strictEqual(sent[0].body.account, 'bank',
        'the entry fee was paid from ' + sent[0].body.account);
});

test('the summary names the account being paid from, and its balance', () => {
    // It used to name the operator's settlement account and show its balance
    // whatever the player picked, so somebody paying from the bank read their
    // cash.
    const panel = opened();
    pick(panel, 'bet-account', 'bank');
    const summary = panel.text('bet-summary');
    assert.ok(/Your Bank/.test(summary), 'the summary still names the wrong account: ' + summary);
    assert.ok(/\$90,?000/.test(summary), 'and shows the wrong balance: ' + summary);
});

test('an untouched picker still sends a real account, not nothing', () => {
    /* null on the wire means "no preference", which the server answers with
       its own order -- and that is fine, but only if it matches what the
       panel showed. The first chip is lit from the start, so that is what
       has to be sent. */
    const panel = opened();
    panel.type('bet-amount', '50');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
    panel.fire('bet-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'spectatorBet');
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].body.account, 'cash',
        'an untouched picker posted ' + JSON.stringify(sent[0].body.account));
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
