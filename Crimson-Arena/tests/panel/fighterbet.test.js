/*
    crimson_arena/tests/panel/fighterbet.test.js

    A FIGHTER BACKING THEMSELVES.

    server/betting.lua has taken these bets since fighterBets shipped: it
    holds a fighter to their own side, re-checks that at settlement against
    who actually fought, and pays the winner a share of the pool rather than
    printing money for them.

    The panel refused every one of them before it reached the wire:

        if (playerMatchId() === match.id)
            return 'You are fighting in this match. You cannot bet on yourself.'

    -- a line that was true when it was written and stopped being true when
    the feature landed. The server never saw a single fighter bet, so nothing
    on that side could report a fault. The config block did not even carry
    fighterBets to the panel, so the panel could not have known.

    These assert the PAYLOAD, because a screen that looks willing and posts
    nothing is the failure being guarded against.
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
 * `who` is what this player is to the match: 'fighter' puts them in it,
 * 'spectator' leaves them outside it.
 * `teams` switches between a team mode and a free-for-all, which is what
 * decides whether "your own side" is a team key or your own server id.
 */
function snapshot(options) {
    const o = Object.assign({
        who: 'fighter',
        teams: false,
        betPayout: null,
        fighter: { enabled: true, min: 100, max: 50000, ownSideOnly: true },
        spectator: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2 },
    }, options || {});

    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: o.teams ? 'tdm' : 'ffa', modeLabel: 'Mode', state: 'lobby',
        teams: o.teams, playerCount: 2, hostName: 'Host', pot: 0, entryFee: 0,
        // The team chips are drawn from these, not from the roster: a team
        // with nobody in it is not somebody to back.
        teamCounts: o.teams ? { crimson: 1, ash: 1 } : {},
        players: [
            { id: SELF, name: 'You', team: o.teams ? 'crimson' : null, alive: true },
            { id: RIVAL, name: 'Rival', team: o.teams ? 'ash' : null, alive: true },
        ],
    };

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: match.modeKey, label: 'Mode', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true,
                currencySymbol: '$',
                payout: 'winner_takes_all',
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: o.spectator,
                fighterBets: o.fighter,
                betPayout: o.betPayout || { fighters: 'pool', spectators: 'pool', sharedPool: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: {
                list: [
                    { key: 'crimson', label: 'Crimson', color: '#c81020', enabled: true },
                    { key: 'ash', label: 'Ash', color: '#8a8a8a', enabled: true },
                ],
            },
            ui: {},
        },
        player: {
            serverId: SELF,
            money: 100000,
            matchId: o.who === 'fighter' ? 'm1' : null,
            // A spectator is looking at a match too -- that is what makes
            // them a spectator rather than somebody with the panel open.
            spectating: o.who === 'fighter' ? false : 'm1',
            team: o.teams && o.who === 'fighter' ? 'crimson' : false,
        },
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

/** Selects a pick and an amount, then presses the button. */
function bet(panel, pick, amount) {
    panel.type('bet-amount', String(amount));
    // The pick chips are built, so this reaches into state the way a click
    // on one does -- via the panel's own handler, not by writing state.
    const chips = panel.node('bet-pick').children;
    const chip = chips.find((c) => (c.textContent || '') === pick);
    assert.ok(chip, 'no chip labelled "' + pick + '"; there were: '
        + chips.map((c) => c.textContent).join(', '));
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
    panel.fire('bet-submit', 'click');
    return panel.posted.filter((p) => p.name === 'spectatorBet');
}

console.log('==> a fighter backing themselves');

test('THE BUG: a fighter is not refused before the wire', () => {
    const panel = opened({ who: 'fighter', teams: false });
    const sent = bet(panel, 'You', 5000);

    assert.strictEqual(sent.length, 1,
        'the panel posted nothing -- a fighter still cannot bet on themselves');
    assert.strictEqual(sent[0].body.pick, String(SELF),
        'the bet backed ' + sent[0].body.pick + ' rather than the player themselves');
    assert.strictEqual(sent[0].body.amount, 5000, 'the amount did not survive the form');
    assert.strictEqual(sent[0].body.matchId, 'm1');
});

test('in a team mode they back their team, which is what the server expects', () => {
    const panel = opened({ who: 'fighter', teams: true });
    const sent = bet(panel, 'Crimson', 2000);

    assert.strictEqual(sent.length, 1, 'the panel posted nothing');
    assert.strictEqual(sent[0].body.pick, 'crimson',
        'the bet was placed on ' + sent[0].body.pick + ' -- the server reads a team key here');
});

test('and is offered NOTHING but their own side while held to it', () => {
    // Not disabled -- absent. A row of names you may not click, on a screen
    // about money, reads as a broken panel.
    const ffa = opened({ who: 'fighter', teams: false });
    const labels = ffa.node('bet-pick').children.map((c) => c.textContent).filter(Boolean);
    assert.ok(labels.indexOf('You') >= 0, 'the player could not back themselves: ' + labels.join(', '));
    assert.strictEqual(labels.indexOf('Rival'), -1,
        'a fighter was offered the other side, which is being paid to lose on purpose: ' + labels.join(', '));

    const tdm = opened({ who: 'fighter', teams: true });
    const teams = tdm.node('bet-pick').children.map((c) => c.textContent).filter(Boolean);
    assert.strictEqual(teams.indexOf('Ash'), -1, 'a fighter was offered the enemy team');
});

test('but a server that allows it offers both sides', () => {
    const panel = opened({
        who: 'fighter',
        teams: false,
        fighter: { enabled: true, min: 100, max: 50000, ownSideOnly: false },
    });
    const labels = panel.node('bet-pick').children.map((c) => c.textContent).filter(Boolean);
    assert.ok(labels.indexOf('Rival') >= 0,
        'ownSideOnly:false still hid the other side: ' + labels.join(', '));

    const sent = bet(panel, 'Rival', 1000);
    assert.strictEqual(sent.length, 1, 'the bet was refused on a server that allows it');
    assert.strictEqual(sent[0].body.pick, String(RIVAL));
});

test('a server with fighter bets off says so, and posts nothing', () => {
    const panel = opened({
        who: 'fighter',
        fighter: { enabled: false, min: 0, max: 0, ownSideOnly: true },
    });
    panel.fire('bet-submit', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'spectatorBet').length, 0,
        'a bet was posted on a server that does not take fighter bets');
    assert.ok(/[Ff]ighters cannot bet/.test(panel.text('bet-hint') + panel.text('bet-pick')),
        'the screen did not say why: ' + panel.text('bet-hint'));
});

test('the fighter band is the fighter band, not the spectators\'', () => {
    /* Reading spectatorBets for a fighter is how a fighter came to be told
       the biggest bet was 1000 when the operator had set theirs to 50000 --
       and, worse, how a legal bet could be refused by the panel alone. */
    const panel = opened({
        who: 'fighter',
        fighter: { enabled: true, min: 100, max: 50000, ownSideOnly: true },
        spectator: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2 },
    });

    const sent = bet(panel, 'You', 20000);   // over the spectator max, inside the fighter's
    assert.strictEqual(sent.length, 1,
        'a bet inside the fighter band was refused against the spectator band');
    assert.strictEqual(sent[0].body.amount, 20000,
        'the amount was clamped to the spectator ceiling: got ' + (sent[0] && sent[0].body.amount));
});

test('a spectator is still a spectator, on their own band', () => {
    // The other half of the same branch: this must not have widened.
    const panel = opened({ who: 'spectator', teams: false });
    const labels = panel.node('bet-pick').children.map((c) => c.textContent).filter(Boolean);
    assert.ok(labels.indexOf('Rival') >= 0 && labels.indexOf('You') >= 0,
        'a spectator was restricted to one side: ' + labels.join(', '));

    /* Over their ceiling is CLAMPED, not refused -- the amount box holds the
       band, the same way the entry-fee box does, so the bet still goes but
       never for more than the operator allows. What matters here is that the
       ceiling applied is the spectators' own: the fighter band is 50x wider,
       and reading it for a spectator would let one stake 20000 in a 1000
       arena. */
    const sent = bet(panel, 'Rival', 5000);   // over the spectator max of 1000
    assert.strictEqual(sent.length, 1, 'nothing was posted at all');
    assert.strictEqual(sent[0].body.amount, 1000,
        'a spectator staked ' + sent[0].body.amount + ' against a ceiling of 1000');
});

test('a server that only lets FIGHTERS bet still draws the form', () => {
    /* The form was gated on spectatorBets.enabled alone, so this server drew
       no controls at all for the one group it was switched on for. */
    const panel = opened({
        who: 'fighter',
        spectator: { enabled: false, min: 0, max: 0, oddsMultiplier: 2 },
        fighter: { enabled: true, min: 100, max: 50000, ownSideOnly: true },
    });
    assert.ok(!panel.node('bet-amount-row').classList.contains('hidden'),
        'the amount box was hidden from the only people allowed to bet');

    const sent = bet(panel, 'You', 3000);
    assert.strictEqual(sent.length, 1, 'nothing was posted');
    assert.strictEqual(sent[0].body.amount, 3000);
});

test('and the note tells them the money comes from the pool, not the server', () => {
    // The old wording said the house pays it, which is what the pool rework
    // stopped being true -- and it is the part people get wrong.
    const panel = opened({ who: 'fighter' });
    const note = panel.text('bet-note');
    assert.ok(/back yourself/.test(note), 'the note never mentions backing yourself: ' + note);
    assert.ok(/never from the server/.test(note),
        'the note does not say where the money comes from: ' + note);
    assert.ok(!/the house pays it/.test(note), 'the note still claims the house pays: ' + note);
});

console.log('');
console.log('==> what a bet is said to pay');

test('under the POOL rule the panel promises a share, not a multiplier', () => {
    /* The defect: the hint quoted spectatorBets.oddsMultiplier whatever the
       payout rule was, so on a pool server every spectator was told they
       would be paid exactly twice their stake -- by a rule that was not
       running. A pool share is not knowable while bets are open; it depends
       on who else backs what. */
    const panel = opened({ who: 'spectator', teams: false });
    panel.type('bet-amount', '500');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    const hint = panel.text('bet-hint');
    assert.ok(/share of the whole betting pool/.test(hint),
        'the hint does not say the payout is a pool share: ' + hint);
    assert.ok(!/you are paid \$1,?000/.test(hint),
        'the hint still quotes a fixed x2 payout under the pool rule: ' + hint);
});

test('DEFECT: and it does not promise a loss the settlement does not take', () => {
    /* "If you lose, the stake is gone" is true of FIXED ODDS, where the
       server is the counterparty and keeps the bet. A pool has no
       counterparty: a losing stake is paid to whoever backed the winner, and
       where nobody did -- nobody bet against you, or nobody backed the side
       that won -- there is nobody to pay it to and the server hands it back.

       The panel said it was gone anyway. A player told their money was gone
       and then handed it back reads that as the arena being broken, which is
       the same complaint that started this from the other end. */
    const panel = opened({ who: 'spectator', teams: false });
    panel.type('bet-amount', '500');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    const hint = panel.text('bet-hint');
    assert.ok(!/stake is gone/.test(hint),
        'the pool hint still says the stake is gone: ' + hint);
    assert.ok(/handed back/.test(hint),
        'the pool hint does not say an unbacked pool comes back: ' + hint);
});

test('and it says the same to a fighter backing themselves', () => {
    // The case that was actually reported: one fighter, their own money, and
    // nobody on the other side of it.
    const panel = opened({ who: 'fighter', teams: false });
    panel.type('bet-amount', '500');
    const own = panel.node('bet-pick').children.find((c) => c.textContent === 'You');
    (own.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    const hint = panel.text('bet-hint');
    assert.ok(!/stake is gone/.test(hint),
        'the fighter hint still says the stake is gone: ' + hint);
    assert.ok(/nobody bet against you/.test(hint),
        'the fighter hint does not say what happens with nobody on the other side: ' + hint);
});

test('but fixed odds STILL says the stake is gone, because there it is', () => {
    // The rule this is honest about is real. Losing that distinction would
    // make the panel wrong in the other direction.
    const panel = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'odds', sharedPool: true },
    });
    panel.type('bet-amount', '500');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    assert.ok(/stake is gone/.test(panel.text('bet-hint')),
        'a fixed-odds loss is genuinely gone and the panel no longer says so: ' + panel.text('bet-hint'));
});

test('and the summary strip says the same thing', () => {
    const panel = opened({ who: 'spectator' });
    const summary = panel.text('bet-summary');
    assert.ok(/Share of pool/.test(summary),
        'the summary still advertises a multiplier: ' + summary);
    assert.ok(!/x2/.test(summary), 'the summary quotes odds under the pool rule: ' + summary);
});

test('but a server really running fixed odds still quotes them', () => {
    // The escape hatch stays honest: this rule IS server-funded and the
    // figure IS knowable, so it should be on screen.
    const panel = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'odds', sharedPool: true },
    });
    panel.type('bet-amount', '500');
    const chip = panel.node('bet-pick').children.find((c) => c.textContent === 'Rival');
    (chip.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));

    assert.ok(/x2/.test(panel.text('bet-summary')),
        'a fixed-odds server did not say what it pays: ' + panel.text('bet-summary'));
    assert.ok(/you are paid/.test(panel.text('bet-hint')),
        'a fixed-odds server did not quote the figure: ' + panel.text('bet-hint'));
});

test('a fighter and a spectator can be paid by DIFFERENT rules', () => {
    // fighters and spectators are separate keys, so the panel has to read
    // the one that applies to whoever is looking.
    const asFighter = opened({
        who: 'fighter',
        betPayout: { fighters: 'pool', spectators: 'odds', sharedPool: true },
    });
    assert.ok(/Share of pool/.test(asFighter.text('bet-summary')),
        'a fighter was quoted the spectators\' rule: ' + asFighter.text('bet-summary'));

    const asSpectator = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'odds', sharedPool: true },
    });
    assert.ok(/x2/.test(asSpectator.text('bet-summary')),
        'a spectator was quoted the fighters\' rule: ' + asSpectator.text('bet-summary'));
});

console.log('');
console.log('==> and what the tab says the money does');

test('THE BUG: with one shared pool it still said a side-bet never touches the pot', () => {
    /* betPayout.sharedPool makes fighters and spectators settle together and
       includeEntryPot folds every entry fee in with them -- both shipped on
       -- so a bystander's stake really is paid to the winner. The panel
       could not know: includeEntryPot was the one field of the block that
       never went on the wire. */
    const panel = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
    });

    const note = panel.text('bet-note');
    assert.ok(!/never changes what the winners take/i.test(note),
        'the tab still promises a side-bet cannot reach the winner: ' + note);
    assert.ok(/same pot|share of it/i.test(note),
        'the tab does not say where the stake actually goes: ' + note);
});

test('and a server with SEPARATE pools still says so', () => {
    // The control. Turning includeEntryPot off is a real configuration, and
    // there the original sentence is the true one.
    const panel = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: false },
    });

    assert.ok(/never changes what the winners take/i.test(panel.text('bet-note')),
        'a server whose pools really are separate was told they are shared: ' + panel.text('bet-note'));
});

test('and the payout phrase stops quoting a rule that never runs', () => {
    /* Config.Betting.payout is read only inside Arena.ComputePayouts, and
       Settle returns before it whenever the entry pot joins the pool. So
       "the winner takes the lot" described a settlement that does not
       happen. */
    const panel = opened({
        who: 'spectator',
        betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
    });

    const note = panel.text('bet-note');
    assert.ok(/proportion to what they staked/i.test(note),
        'the tab still quotes the unreachable payout rule: ' + note);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
