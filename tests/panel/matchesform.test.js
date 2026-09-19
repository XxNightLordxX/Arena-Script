/*
    crimson_arena/tests/panel/matchesform.test.js

    THE MATCHES TAB'S TWO LIES.

    Both were found by auditing the tab against the server that acts on it,
    and both are the same shape: the panel stating something the rest of the
    system does not agree with.

    ONE. A match card said "the Bets tab is showing this match" whenever you
    had clicked it. The Bets tab does not follow clicks alone -- focusedMatch()
    prefers the match you are FIGHTING in, then the one you are WATCHING, and
    only then the one you clicked. Being in a match hides the problem, because
    applySnapshot forces the selection back to your own. Watching one does not:
    a spectator who clicked another card was told the tab had followed them
    while it sat on the match they were watching, and the bet they then placed
    carried the watched match's id.

    TWO. The Kill Limit box was gated on the win-condition DROPDOWN being on
    screen rather than on the win condition that is actually running. Fix the
    condition to 'score_limit' the documented plain-string way and the dropdown
    goes away -- taking the limit box with it, on the one server that had
    committed to using a limit. Every match was then created on the default and
    the operator's own min/max band was unreachable.
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

function clickNode(node) {
    (node.listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() {}, preventDefault() {} });
    });
}

function textOf(node) {
    let out = String(node.textContent || '');
    (node.children || []).forEach(function (kid) { out += ' ' + textOf(kid); });
    return out;
}

function baseSnapshot() {
    function match(id, label, ids) {
        return {
            id: id, arenaKey: 'a', arenaLabel: 'Warehouse', label: label,
            modeKey: 'ffa', modeLabel: 'Free For All', state: 'lobby', teams: false,
            playerCount: ids.length, hostName: 'Host', pot: 0, entryFee: 0,
            betsOpen: true, fighterBetsOpen: true, bets: 0, betPool: 0,
            betsByPick: {}, teamCounts: {},
            players: ids.map(function (id) {
                return { id: id, name: 'Fighter ' + id, alive: true, team: null };
            }),
        };
    }
    return {
        config: {
            arenas: [{ key: 'a', label: 'Warehouse', enabled: true }],
            modes: [{ key: 'ffa', label: 'Free For All', enabled: true, teams: false }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: true, currencySymbol: '$', account: 'cash', accounts: ['cash'],
                payout: 'winner_takes_all',
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2, oneBetPerMatch: true },
                fighterBets: { enabled: false },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: {
            serverId: SELF, money: 100000, wallet: { cash: 100000 },
            matchId: null, spectating: null, team: false, backing: [], bet: null,
        },
        matches: [match('m1', 'First', [11, 12]), match('m2', 'Second', [21, 22])],
        leaderboard: [],
    };
}

function opened(edit) {
    const panel = loadPanel(ROOT);
    const snap = baseSnapshot();
    if (edit) edit(snap);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function cardTitled(panel, label) {
    return panel.node('match-list').children.find(function (c) {
        return (c.children || []).some(function (kid) { return kid.textContent === label; });
    });
}

console.log('==> matchesform.test.js');

// ------------------------------------------------------------------
// ONE: the card only claims the focus it actually has
// ------------------------------------------------------------------

test('a clicked card says the Bets tab is showing it, and it is', () => {
    const panel = opened();
    const first = cardTitled(panel, 'First');
    assert.ok(first, 'no card titled First');
    clickNode(first);

    assert.ok(/Bets tab is showing this match/.test(textOf(cardTitled(panel, 'First'))),
        'the card did not claim the focus it really has');
    assert.ok(/First/.test(textOf(panel.node('bet-match'))),
        'the Bets tab did not actually follow the click: ' + textOf(panel.node('bet-match')));
});

test('DEFECT: while WATCHING one match, clicking another does not claim it', () => {
    /* focusedMatch() prefers the watched match, so the click changes nothing
       the Bets tab will honour. The card used to say it had. */
    const panel = opened(function (s) { s.player.spectating = 'm2'; });

    const first = cardTitled(panel, 'First');
    assert.ok(first, 'no card titled First');
    clickNode(first);

    const claim = textOf(cardTitled(panel, 'First'));
    assert.ok(!/Bets tab is showing this match/.test(claim),
        'A CARD CLAIMED A FOCUS THE BETS TAB NEVER GAVE IT: ' + claim);
});

test('and the Bets tab really is still on the watched match, not the clicked one', () => {
    const panel = opened(function (s) { s.player.spectating = 'm2'; });
    clickNode(cardTitled(panel, 'First'));

    const heading = textOf(panel.node('bet-match'));
    assert.ok(/Second/.test(heading),
        'the tab moved off the watched match: ' + heading);
    /* Which is the whole point: a bet placed here carries m2. The card must
       not have said otherwise. */
});

test('the watched match IS the one marked, so the claim is not simply gone', () => {
    const panel = opened(function (s) { s.player.spectating = 'm2'; });
    assert.ok(/Bets tab is showing this match/.test(textOf(cardTitled(panel, 'Second'))),
        'the card for the match the tab is really on says nothing at all');
});

// ------------------------------------------------------------------
// TWO: the Kill Limit box follows the rule, not the dropdown
// ------------------------------------------------------------------

/* The operator's two shapes for Config.Match.winCondition:
     a plain string  -> fixed for every match, WinConditionChoice returns nil
     a table         -> a choice, and the dropdown appears
   Only the second used to reach the Kill Limit box. */
function creating(edit) {
    return opened(function (s) {
        s.config.match.scoreLimitChoice = { min: 1, max: 200, default: 25 };
        s.config.match.scoreLimit = 25;
        s.player.canCreate = true;
        if (edit) edit(s);
    });
}

test('DEFECT: a FIXED score-limit server still offers the limit', () => {
    /* winConditionChoice absent is exactly what the server sends when the
       operator writes Config.Match.winCondition = 'score_limit'. */
    const panel = creating(function (s) {
        s.config.match.winCondition = 'score_limit';
        delete s.config.match.winConditionChoice;
    });

    assert.ok(!panel.node('create-limit-row').classList.contains('hidden'),
        'THE KILL LIMIT BOX WAS HIDDEN ON A SERVER THAT RUNS A KILL LIMIT');
    assert.ok(/\d/.test(panel.text('create-limit-hint')),
        'the limit hint was blank, so the band was never stated: '
        + panel.text('create-limit-hint'));
});

test('and the Win Condition dropdown stays hidden, because it IS fixed', () => {
    const panel = creating(function (s) {
        s.config.match.winCondition = 'score_limit';
        delete s.config.match.winConditionChoice;
    });
    assert.ok(panel.node('create-win-row').classList.contains('hidden'),
        'a fixed win condition was offered as a choice');
});

test('a fixed LAST-STANDING server still does not offer a kill limit', () => {
    const panel = creating(function (s) {
        s.config.match.winCondition = 'last_standing';
        delete s.config.match.winConditionChoice;
    });
    assert.ok(panel.node('create-limit-row').classList.contains('hidden'),
        'a kill limit was offered on a match that has no kill limit');
});

test('and where the host CHOOSES, the box still follows the choice', () => {
    const panel = creating(function (s) {
        s.config.match.winConditionChoice = ['last_standing', 'score_limit'];
        s.config.match.winCondition = 'last_standing';
    });
    assert.ok(panel.node('create-limit-row').classList.contains('hidden'),
        'the limit showed for last_standing');

    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change', { target: { value: 'score_limit' } });

    assert.ok(!panel.node('create-limit-row').classList.contains('hidden'),
        'picking score_limit did not bring the limit box back');
});

test('DEFECT: in a team mode the hint names the TEAM rule the server runs', () => {
    /* reachedScoreLimit in server/match.lua sums teamKills in a team mode.
       "The first fighter to this many kills" was the individual rule, stated
       on the modes where it does not apply. */
    const panel = creating(function (s) {
        s.config.modes = [{ key: 'tdm', label: 'Team Deathmatch', enabled: true, teams: true }];
        s.config.teams.list = [{ key: 'crimson', label: 'Crimson' }, { key: 'ash', label: 'Ash' }];
        s.config.match.winCondition = 'score_limit';
        delete s.config.match.winConditionChoice;
    });

    const hint = panel.text('create-limit-hint');
    assert.ok(/side to this many kills between them/i.test(hint),
        'the hint stated the individual rule in a team mode: ' + hint);
});

test('and in a free-for-all it still names the individual rule', () => {
    const panel = creating(function (s) {
        s.config.match.winCondition = 'score_limit';
        delete s.config.match.winConditionChoice;
    });
    assert.ok(/first fighter to this many kills/i.test(panel.text('create-limit-hint')),
        'the individual rule was lost: ' + panel.text('create-limit-hint'));
});

// ------------------------------------------------------------------
// THREE: joining moves you to Lobby. Reading a card does not.
// ------------------------------------------------------------------

test('DEFECT: clicking another card in a lobby does not throw you off Matches', () => {
    /* The move to Lobby fired whenever the SELECTION differed from the match
       you are in -- and every card click writes the selection. So a player
       sitting in a lobby who clicked another match to read it was dragged
       onto the Lobby tab by the next broadcast, having asked for nothing. */
    const panel = loadPanel(ROOT);
    const snap = baseSnapshot();
    panel.send('open', snap);
    panel.send('state', snap);

    // join m1: the next snapshot carries the membership
    const joined = baseSnapshot();
    joined.player.matchId = 'm1';
    panel.send('state', joined);

    // the player walks back to Matches themselves and clicks the other card
    panel.fire('tab-btn-matches', 'click');
    clickNode(cardTitled(panel, 'Second'));

    // and another broadcast lands, with nothing changed about their membership
    panel.send('state', joined);

    assert.ok(!panel.node('tab-matches').classList.contains('hidden'),
        'A BROADCAST DRAGGED THE PLAYER OFF THE MATCHES TAB FOR CLICKING A CARD');
});

test('and joining one still does move you there, which is what the rule is for', () => {
    const panel = loadPanel(ROOT);
    const snap = baseSnapshot();
    panel.send('open', snap);
    panel.send('state', snap);
    panel.fire('tab-btn-matches', 'click');

    const joined = baseSnapshot();
    joined.player.matchId = 'm1';
    panel.send('state', joined);

    assert.ok(!panel.node('tab-lobby').classList.contains('hidden'),
        'joining a match no longer takes the player to the lobby');
    assert.ok(panel.node('tab-matches').classList.contains('hidden'),
        'the Matches tab was left showing after a join');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
