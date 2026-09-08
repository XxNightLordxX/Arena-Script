/*
    crimson_arena/tests/panel/adminscreen.test.js

    THE TABLET IS A SCREEN YOU CAN GET OUT OF.

    ONE FOCUS, NO STACK. SetNuiFocus is global state, so the tablet and the
    panel take turns rather than layering -- and the tablet is a fixed opaque
    modal covering most of the viewport. A tablet that stays drawn after focus
    has been released is not a screen with a bug in it; it is a blindfold. The
    admin is standing in a live round, behind it, with no mouse.

    THAT IS NOT HYPOTHETICAL. An admin can be queued for the round they are
    watching, and server/match.lua sends every fighter a closePanel the moment
    it starts -- which releases focus unconditionally. The tablet had no part
    in that, and ESC did not reach it either: the page's key handler returned
    early on the PANEL's open flag.
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

function opened() {
    const panel = loadPanel(ROOT);
    panel.send('adminOpen', {
        matches: [{
            id: 'm1', label: 'Trailer Park', arenaKey: 'a', modeKey: 'ffa',
            state: 'live', hostName: 'John Allday', players: 2, pot: 0,
        }],
        owed: [],
        stashesFound: 0,
        stashesRead: 0,
    });
    return panel;
}

function hidden(panel, id) {
    return panel.node(id).classList.contains('hidden');
}

function postsNamed(panel, name) {
    return panel.posted.filter(function (row) { return row.name === name; });
}

console.log('==> the tablet draws, and can be got out of');

test('an adminOpen message puts the screen on the page', () => {
    const panel = opened();
    assert.ok(!hidden(panel, 'arena-admin'), 'the tablet did not appear');
    assert.ok(!hidden(panel, 'admin-list'), 'it opened on no screen at all');
});

test('and it opens on the live matches, not an empty list', () => {
    const panel = opened();
    assert.ok(!hidden(panel, 'arena-admin'));
    assert.ok(hidden(panel, 'admin-empty'),
        'a tablet opened with a live match on it says there are none');
});

test('and says nothing about outstanding stashes before it has looked', () => {
    /* The command opens the screen on what memory answers instantly and lets
       the database sweep follow. An empty list draws no section at all --
       which is honest -- rather than an empty one captioned as good news. */
    const panel = opened();
    assert.ok(hidden(panel, 'admin-owed-row'),
        'the first draw claimed to know that nobody is short');
});

test('THE BUG: ESC did not reach the tablet at all', () => {
    /* The handler returned early on `state.open`, which is the PANEL's flag.
       So while the tablet was up -- the one screen whose Close button can
       become unreachable -- ESC did nothing whatever. */
    const panel = opened();

    const prevented = panel.key('Escape');

    assert.ok(prevented, 'ESC was not handled at all while the tablet was open');
    assert.strictEqual(postsNamed(panel, 'adminClose').length, 1,
        'ESC did not ask Lua to close the tablet');
});

test('and it asks LUA to close it rather than hiding it here', () => {
    /* Lua owns the focus release. A screen that hides itself and leaves NUI
       focus held costs the player their character -- which is the same
       failure this whole file is about, arrived at from the other side. */
    const panel = opened();
    panel.key('Escape');

    assert.ok(!hidden(panel, 'arena-admin'),
        'the page hid the tablet itself instead of letting Lua do it');
});

test('and the adminClose Lua sends back is what actually takes it away', () => {
    const panel = opened();
    panel.send('adminClose', {});
    assert.ok(hidden(panel, 'arena-admin'), 'the tablet stayed drawn after Lua closed it');
});

test('ESC with no tablet up still closes the panel, as it always did', () => {
    const panel = loadPanel(ROOT);
    panel.send('open', {
        config: {
            arenas: [], modes: [], match: {}, betting: { enabled: false },
            loadouts: { weapons: [] }, teams: { list: [] }, ui: {},
        },
        player: {}, matches: [], leaderboard: [],
    });

    const prevented = panel.key('Escape');
    assert.ok(prevented, 'ESC stopped working on the panel');
    assert.strictEqual(postsNamed(panel, 'close').length, 1,
        'ESC did not close the panel');
});

console.log('');
if (failures.length > 0) {
    failures.forEach(function (row) {
        console.log('FAILED: ' + row.name);
        console.log(row.error.stack);
    });
}
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length > 0 ? 1 : 0);
