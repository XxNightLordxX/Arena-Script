/*
    crimson_arena/tests/panel/tierpicker.test.js

    THE GUN-GAME LADDER, COMPOSED BY THE HOST.

    The ladder used to be thirty hand-written pools in config.lua, and a flat
    list cannot be composed: "give me four shotgun rungs" is not a thing you
    can ask of it without knowing which of the thirty entries happened to be
    shotguns. It is also how the ladder got five melee rungs deep without
    anybody noticing that a sixth of every round was being fought with clubs.

    So it is weapon CLASSES now -- melee, sidearms, and up -- each with a rung
    count, and the host sets the counts in the match-creation menu: one row per
    class, a dropdown of how many rungs of it the climb has.

    WHAT THESE ASSERT. That the rows are drawn from the server's own class
    list rather than a list the panel carries; that a class may be set to 0 and
    left out, because pistols-and-rifles-and-nothing-else is a ladder somebody
    will want; that a class can never be offered more rungs than it has
    weapons, since two rungs drawing from one weapon is a promotion that hands
    you the gun you are already holding; and that the whole plan rides out with
    the match rather than being a control that looks like it did something.
*/

const assert = require('assert');
const fs = require('fs');
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

const CLASSES = [
    { key: 'melee', label: 'Melee', tiers: 1, maxTiers: 18 },
    { key: 'sidearm', label: 'Sidearms', tiers: 9, maxTiers: 18 },
    { key: 'shotgun', label: 'Shotguns', tiers: 4, maxTiers: 9 },
];

/* `seat` decides whether the form is a CREATE form or that lobby's settings:
   hosting an open lobby makes the same submit an edit. */
function snapshot(classes, modeKey, seat) {
    const mode = modeKey || 'gungame';
    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: mode, modeLabel: 'Mode', state: 'lobby',
        playerCount: 1, hostName: 'John Allday', players: [], teams: [],
    };
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [
                { key: 'ffa', label: 'FFA', enabled: true },
                {
                    key: 'gungame', label: 'Gun Game', enabled: true,
                    tiers: 14, tierClasses: classes,
                },
            ],
            match: {
                lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600,
                livesChoice: { min: 1, max: 10 },
                winCondition: 'last_standing',
                scoreLimit: 25,
                /* THE MODE THE FORM OPENS ON. A player outside every match
                   has no lobby to seed the form from, so this is what decides
                   whether the ladder rows are drawn at all -- and without it
                   the form opened on whichever mode came first. */
                defaultMode: 'gungame',
            },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: true, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: seat === 'outside' ? { matchId: null } : { matchId: 'm1', isHost: true },
        matches: [match],
        leaderboard: [],
    };
}

function opened(classes, modeKey, seat) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(classes, modeKey, seat);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function hidden(panel, id) {
    return panel.node(id).classList.contains('hidden');
}

/* The select the panel built for one class, by the id the panel gives it.
   The rows are built rather than written into index.html, and the harness
   registers a built element under whatever id the panel assigns -- which is
   what a real document does, and what makes a control the panel created
   addressable at all. */
function idFor(key) { return 'create-tier-' + key; }

function rowFor(panel, key) {
    return panel.built(idFor(key)) ? panel.node(idFor(key)) : null;
}

console.log('==> the gun-game ladder, composed by the host');

test('the rows live in the MATCHES tab, with the other match rules', () => {
    const html = fs.readFileSync(path.join(ROOT, 'html', 'index.html'), 'utf8');

    const matches = html.indexOf('id="tab-matches"');
    const lobby = html.indexOf('id="tab-lobby"');
    const tiers = html.indexOf('id="create-tiers-row"');

    assert.ok(matches >= 0 && lobby > matches, 'the panel no longer has the two tabs this asserts about');
    assert.ok(tiers >= 0, 'there is no weapon-tier row in the markup at all');
    assert.ok(tiers > matches && tiers < lobby,
        'the weapon-tier rows sit outside the matches tab');
});

test('one row per weapon class, drawn from the server\'s own list', () => {
    const panel = opened(CLASSES);
    assert.ok(!hidden(panel, 'create-tiers-row'),
        'a gun game was offered no way to shape its ladder');

    CLASSES.forEach(function (row) {
        const select = rowFor(panel, row.key);
        assert.ok(select, 'no row was drawn for ' + row.key);
    });

    const text = panel.text('create-tiers');
    CLASSES.forEach(function (row) {
        assert.ok(text.indexOf(row.label) >= 0,
            'the class is not named on screen: ' + row.label + ' -- got ' + text);
    });
});

test('and each opens on the count the server sent', () => {
    const panel = opened(CLASSES);
    CLASSES.forEach(function (row) {
        assert.strictEqual(rowFor(panel, row.key).value, String(row.tiers),
            row.key + ' opened on the wrong number of rungs');
    });
});

test('a class may be set to nothing, and 0 is on the list', () => {
    /* Pistols and rifles and nothing else is a ladder somebody will want, so
       leaving a class out has to be sayable rather than only typeable. */
    const panel = opened(CLASSES);
    const values = rowFor(panel, 'shotgun').children.map(function (o) { return o.value; });
    assert.strictEqual(values[0], '0', 'a class cannot be left out of the ladder');
});

test('and never more rungs than the class has weapons', () => {
    /* Two rungs drawing from one weapon is a promotion that hands you the gun
       you are already holding, so the ceiling is the class's own size. */
    const panel = opened(CLASSES);
    CLASSES.forEach(function (row) {
        const options = rowFor(panel, row.key).children;
        const last = options[options.length - 1].value;
        assert.strictEqual(last, String(row.maxTiers),
            row.key + ' offered up to ' + last + ' rungs out of ' + row.maxTiers + ' weapons');
    });
});

test('the hint counts the whole ladder, and warns below the floor', () => {
    /* A one-rung ladder is topped by the first kill of the round, so the
       server refuses it -- and a host who has just dialled every row to zero
       should read that here rather than meet it as a refusal on the button. */
    const panel = opened(CLASSES);
    assert.ok(/14 tiers/.test(panel.node('create-tiers-hint').textContent),
        'the hint does not total the ladder: ' + panel.node('create-tiers-hint').textContent);

    CLASSES.forEach(function (row) {
        rowFor(panel, row.key).value = '0';
        panel.fire(idFor(row.key), 'change');
    });

    assert.ok(/at least two/.test(panel.node('create-tiers-hint').textContent),
        'a ladder of nothing was not called out: ' + panel.node('create-tiers-hint').textContent);
});

test('no rows on a mode that climbs no ladder', () => {
    const panel = opened(CLASSES, 'ffa');
    assert.ok(hidden(panel, 'create-tiers-row'),
        'a free-for-all was offered a weapon ladder to shape');
});

test('and none where the mode declares no classes', () => {
    /* An operator who writes the flat gunGameTiers list by hand gets a ladder
       the panel cannot reshape -- which is honest, and better than a row of
       dropdowns that change nothing. */
    const panel = opened(undefined);
    assert.ok(hidden(panel, 'create-tiers-row'),
        'a mode with no classes was still offered rows');
});

test('the plan rides out with the match', () => {
    const panel = opened(CLASSES, 'gungame', 'outside');
    rowFor(panel, 'shotgun').value = '2';
    panel.fire(idFor('shotgun'), 'change');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'createMatch'; });
    assert.strictEqual(posted.length, 1,
        'the create did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.tierPlan.shotgun, 2,
        'the host\'s ladder was dropped on the way out: '
            + JSON.stringify(posted[0].body.tierPlan));
});

test('and on updateMatch, so a host can reshape an open lobby', () => {
    const panel = opened(CLASSES);
    rowFor(panel, 'melee').value = '3';
    panel.fire(idFor('melee'), 'change');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'updateMatch'; });
    assert.strictEqual(posted.length, 1,
        'the edit did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.tierPlan.melee, 3,
        'the edit dropped the ladder: ' + JSON.stringify(posted[0].body.tierPlan));
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
