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

test('and opens on the matches, not on the stashes', () => {
    /* Two subjects, one screen at a time. /arenaadmin is most often typed
       because something is happening NOW. */
    const panel = opened();
    assert.ok(!hidden(panel, 'admin-list'), 'the tablet did not open on the match list');
    assert.ok(hidden(panel, 'admin-stashes'), 'it opened on the stashes instead');
    assert.ok(panel.node('admin-tab-matches').classList.contains('active'),
        'the Matches tab is not lit');
});

console.log('');
console.log('==> and the stashes are a tab at the top');

/* One stash for somebody who is here, one for somebody who is not. */
function withStashes() {
    const panel = opened();
    panel.send('adminState', {
        matches: [],
        focused: null,
        owed: [
            {
                citizenid: 'CID001', stash: 'crimson_arena_CID001', src: 2,
                remembered: true,
                items: [{ name: 'phone', count: 1 }],
            },
            {
                citizenid: 'CID777', stash: 'crimson_arena_CID777',
                remembered: false,
                items: [{ name: 'phone', count: 1 }, { name: 'burger', count: 3 }],
            },
        ],
        stashesFound: 2,
        stashesRead: 2,
    });
    return panel;
}

/* Every stash row on the list, as { open, give }. */
function stashRows(panel) {
    return panel.node('admin-stash-list').children.map(function (row) {
        let open = null;
        let give = null;
        row.children.forEach(function (child) {
            if (child.classList.contains('admin-stash-open')) open = child;
            if (child.classList.contains('admin-owed-give')) give = child;
        });
        return { row, open, give };
    });
}

function press(node) {
    (node.listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() {} });
    });
    if (typeof node.onclick === 'function') node.onclick({ stopPropagation() {} });
}

test('THE REQUEST: a Stashes tab at the top, and it shows the stashes', () => {
    const panel = withStashes();

    panel.fire('admin-tab-stashes', 'click');

    assert.ok(!hidden(panel, 'admin-stashes'), 'the Stashes tab did not open');
    assert.ok(hidden(panel, 'admin-list'), 'the match list is still on screen underneath it');
    assert.ok(panel.node('admin-tab-stashes').classList.contains('active'),
        'the Stashes tab is not lit');
    assert.ok(!panel.node('admin-tab-matches').classList.contains('active'),
        'both tabs are lit at once');

    assert.strictEqual(stashRows(panel).length, 2,
        'the tab drew ' + stashRows(panel).length + ' stashes, not 2');
});

test('and every row says who the stash is for', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    const text = panel.text('admin-stash-list');
    assert.ok(/CID001/.test(text) && /CID777/.test(text),
        'the rows do not name whose belongings they are: ' + text);
});

test('THE REQUEST: a stash whose owner is OFFLINE is listed, and says so', () => {
    /* The one case nothing else in this resource can do anything about. The
       retry sweep only ever tries people who are on the server, so a
       character who has not been seen since a restart is invisible to it --
       and this tab is the only place their belongings can be found. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    const text = panel.text('admin-stash-list');
    assert.ok(/CID777/.test(text), 'the offline character\'s stash was not listed at all');
    assert.ok(/offline/i.test(text),
        'nothing on the row says their owner is not on the server: ' + text);
});

test('THE REQUEST: every row carries a Return button', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    const rows = stashRows(panel);
    rows.forEach(function (entry) {
        assert.ok(entry.give !== null, 'a stash row has no button to send it back');
        assert.ok(!entry.give.disabled, 'a stash with things in it was not offered a button');
    });

    /* And the offline one says what it will actually do, which is not the
       same thing: there is no live inventory to put items into, so the
       server queues the return instead. */
    assert.ok(/queue/i.test(rows[1].give.textContent),
        'the offline row promises to hand it over now: ' + rows[1].give.textContent);
    assert.ok(/hand it back/i.test(rows[0].give.textContent),
        'the online row does not offer to hand it over: ' + rows[0].give.textContent);
});

test('and pressing it asks the server about that stash', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    press(stashRows(panel)[1].give);

    const posts = postsNamed(panel, 'adminReturn');
    assert.strictEqual(posts.length, 1, 'pressing the button asked the server for nothing');
    assert.strictEqual(posts[0].body.citizenid, 'CID777', 'it asked about the wrong character');
    assert.strictEqual(posts[0].body.stash, 'crimson_arena_CID777');
});

test('and pressing it does NOT also walk the admin into the stash', () => {
    /* The button sits INSIDE the row, and the row opens the stash. Without a
       stopPropagation, sending somebody their things also changed screen for
       no reason.

       ASSERTED ON THE CALL rather than on the screen, deliberately. The DOM
       shim these tests run against dispatches to one node and does not bubble
       at all -- so a test that pressed the button and then checked which
       screen is up would pass whether the handler stops the event or not, and
       would be a test of the harness rather than of the panel. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    let stopped = false;
    const give = stashRows(panel)[0].give;
    (give.listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() { stopped = true; } });
    });

    assert.ok(stopped,
        'the Return button lets its click through to the row, which opens the stash');
    assert.ok(!hidden(panel, 'admin-stashes'), 'and the list was left');
});

console.log('');
console.log('==> and clicking a stash shows what is in it');

test('THE REQUEST: clicking a stash opens it', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    press(stashRows(panel)[1].open);

    assert.ok(!hidden(panel, 'admin-stash-detail'), 'the stash did not open');
    assert.ok(hidden(panel, 'admin-stashes'), 'the list is still on screen underneath it');
    assert.ok(/CID777/.test(panel.text('admin-stash-title')),
        'the opened stash does not say whose it is: ' + panel.text('admin-stash-title'));
});

test('and names everything in it, item by item', () => {
    /* The list says how much; the opened stash says what. A manifest of every
       item in forty stashes is a wall rather than a list, which is why it is
       one level down rather than on the row. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[1].open);

    const items = panel.text('admin-stash-items');
    assert.ok(/phone/.test(items), 'the phone is not listed: ' + items);
    assert.ok(/burger/.test(items), 'the burger is not listed: ' + items);
    assert.ok(/3/.test(items), 'the counts are not shown: ' + items);
});

test('and the opened stash carries the same Return button', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[1].open);

    const give = panel.node('admin-stash-return');
    assert.ok(!give.disabled, 'the button is dead on a stash with things in it');
    assert.ok(/queue/i.test(give.textContent),
        'it promises to hand an offline character their things now: ' + give.textContent);

    panel.fire('admin-stash-return', 'click');
    const posts = postsNamed(panel, 'adminReturn');
    assert.strictEqual(posts.length, 1, 'the button asked the server for nothing');
    assert.strictEqual(posts[0].body.citizenid, 'CID777');
});

test('and Back returns to the list', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[0].open);
    panel.fire('admin-stash-back', 'click');

    assert.ok(!hidden(panel, 'admin-stashes'), 'the list did not come back');
    assert.ok(hidden(panel, 'admin-stash-detail'), 'the stash stayed open');
});

test('and a stash handed back while it was open falls out to the list', () => {
    /* The screen is drawn from the CURRENT snapshot, so a stash that is no
       longer held is not one an admin is left staring at a manifest of. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[1].open);
    assert.ok(!hidden(panel, 'admin-stash-detail'), 'it never opened');

    panel.send('adminState', {
        matches: [], focused: null, owed: [], stashesFound: 0, stashesRead: 0,
    });

    assert.ok(hidden(panel, 'admin-stash-detail'),
        'the admin is still looking at a stash the arena no longer holds');
    assert.ok(!hidden(panel, 'admin-stashes'), 'and was not put back on the list');
});

test('and how many of them nobody can be handed is said out loud', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');

    const line = panel.text('admin-stash-line');
    assert.ok(/not on the server/i.test(line),
        'the caption does not say how many are for somebody who is away: ' + line);
});

test('an empty tab says so rather than drawing a blank screen', () => {
    const panel = opened();
    panel.fire('admin-tab-stashes', 'click');

    assert.ok(!hidden(panel, 'admin-stashes'), 'the tab did not open');
    assert.ok(!hidden(panel, 'admin-stash-empty'),
        'an empty tab is a blank screen, which reads as one that failed to load');
});

test('and arriving on the tab asks the server for a fresh read', () => {
    /* The stash list is a database read the server does not repeat on its
       own, so a tablet left open while a return finally went through would
       show a stash that is no longer held. */
    const panel = opened();
    const before = postsNamed(panel, 'adminState').length;

    panel.fire('admin-tab-stashes', 'click');

    assert.strictEqual(postsNamed(panel, 'adminState').length, before + 1,
        'arriving on the Stashes tab did not ask for a fresh look');
});

test('and going back to Matches returns to the match list', () => {
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[0].open);
    panel.fire('admin-tab-matches', 'click');

    assert.ok(!hidden(panel, 'admin-list'), 'the match list did not come back');
    assert.ok(hidden(panel, 'admin-stashes'), 'the stash list stayed on screen');
    assert.ok(hidden(panel, 'admin-stash-detail'), 'and the opened stash stayed with it');
});

test('and coming BACK to Stashes arrives on the list, not inside a stash', () => {
    /* Arriving on a tab means arriving at the top of it. Anything else drops
       an admin back inside whichever stash they last looked in -- which may
       not even be held any more. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[0].open);
    assert.ok(!hidden(panel, 'admin-stash-detail'), 'the stash never opened');

    /* PRESSED WITHOUT LEAVING FIRST, which is the gesture this is really
       about -- "take me back to the top" -- and the only one that isolates
       the Stashes tab's own handler. Going out to Matches and back would
       pass on the Matches handler clearing it instead. */
    panel.fire('admin-tab-stashes', 'click');

    assert.ok(!hidden(panel, 'admin-stashes'), 'the list did not come back');
    assert.ok(hidden(panel, 'admin-stash-detail'),
        'the tab left the admin inside the stash they were last looking in');
});

test('and leaving for the matches and coming back does the same', () => {
    /* The other route to the same guarantee: whichever way an admin arrives
       on the Stashes tab, they arrive at the top of it. */
    const panel = withStashes();
    panel.fire('admin-tab-stashes', 'click');
    press(stashRows(panel)[0].open);

    panel.fire('admin-tab-matches', 'click');
    assert.ok(!hidden(panel, 'admin-list'), 'the matches did not come up');

    panel.fire('admin-tab-stashes', 'click');
    assert.ok(hidden(panel, 'admin-stash-detail'),
        'leaving for the matches and coming back reopened the stash');
});

console.log('');
console.log('==> and the doors are the admin\'s to decide, either way');

function withDoors(open, forced) {
    const panel = opened();
    panel.send('adminState', {
        matches: [], focused: null, owed: [],
        stashesFound: 0, stashesRead: 0,
        hoursOpen: open, hoursForced: forced,
    });
    return panel;
}

test('THE REQUEST: a shut arena can be opened from the tablet', () => {
    /* Config.Schedule can have the arena shut at four in the morning, and an
       operator running an event at four in the morning needs a way in that is
       not editing config and restarting the resource. */
    const panel = withDoors(false, null);

    assert.ok(/shut/i.test(panel.text('admin-doors-state')),
        'the tablet does not say the arena is shut: ' + panel.text('admin-doors-state'));

    panel.fire('admin-doors-open', 'click');

    const posts = postsNamed(panel, 'adminHours');
    assert.strictEqual(posts.length, 1, 'the button asked the server for nothing');
    assert.strictEqual(posts[0].body.forced, 'open',
        'it did not ask for the doors to be held open');
});

test('THE REQUEST: and an open one can be closed', () => {
    const panel = withDoors(true, null);

    panel.fire('admin-doors-shut', 'click');

    const posts = postsNamed(panel, 'adminHours');
    assert.strictEqual(posts.length, 1, 'the button asked the server for nothing');
    assert.strictEqual(posts[0].body.forced, 'shut', 'it did not ask for the arena to close');
});

test('and the schedule can be given its say back', () => {
    const panel = withDoors(true, 'open');

    panel.fire('admin-doors-schedule', 'click');

    const posts = postsNamed(panel, 'adminHours');
    assert.strictEqual(posts[0].body.forced, null,
        'handing it back asked for a state rather than for no state');
});

test('and the line says WHICH of the two kinds of open or shut it is', () => {
    /* "Open" is two different facts -- the schedule says so, or somebody did
       -- and an operator who cannot tell them apart cannot tell what pressing
       anything here will do. */
    const scheduled = withDoors(true, null);
    assert.ok(/schedule/i.test(scheduled.text('admin-doors-state')),
        'an arena open on its own hours does not say so: '
        + scheduled.text('admin-doors-state'));

    const held = withDoors(true, 'open');
    assert.ok(/held open/i.test(held.text('admin-doors-state')),
        'an arena being held open does not say so: ' + held.text('admin-doors-state'));

    const closed = withDoors(false, 'shut');
    assert.ok(/closed by an admin/i.test(closed.text('admin-doors-state')),
        'an arena an admin closed does not say who closed it: '
        + closed.text('admin-doors-state'));

    const offHours = withDoors(false, null);
    assert.ok(/on the schedule/i.test(offHours.text('admin-doors-state')),
        'an arena shut on its own hours does not say so: '
        + offHours.text('admin-doors-state'));
});

test('and closing it says the fights already happening will finish', () => {
    /* Shutting the arena stops people coming IN. An operator who thinks the
       button ends live rounds will not press it when they should. */
    const panel = withDoors(false, 'shut');
    assert.ok(/finishing/i.test(panel.text('admin-doors-state')),
        'nothing says what happens to a round being fought: '
        + panel.text('admin-doors-state'));
});

test('and the state in force is lit and cannot be pressed again', () => {
    /* A button that re-asks for the state the arena is already in is a button
       whose only possible effect is a wasted round trip. */
    const panel = withDoors(true, 'open');

    assert.ok(panel.node('admin-doors-open').classList.contains('active'),
        'the state in force is not lit');
    assert.ok(panel.node('admin-doors-open').disabled,
        'the state in force can be asked for again');
    assert.ok(!panel.node('admin-doors-shut').disabled, 'closing was refused');
    assert.ok(!panel.node('admin-doors-schedule').disabled,
        'handing it back to the schedule was refused');
});

test('and on the schedule it is the schedule button that is lit', () => {
    const panel = withDoors(true, null);
    assert.ok(panel.node('admin-doors-schedule').classList.contains('active'),
        'no state is shown as being in force');
    assert.ok(panel.node('admin-doors-schedule').disabled);
});

test('and the screen redraws from the SERVER\'s answer, not from hope', () => {
    /* A control that shows itself flipped when the server refused is worse
       than a control that does nothing. */
    const panel = withDoors(false, null);
    panel.fire('admin-doors-open', 'click');

    assert.ok(/shut/i.test(panel.text('admin-doors-state')),
        'the tablet flipped itself before the server had answered: '
        + panel.text('admin-doors-state'));

    panel.send('adminState', {
        matches: [], focused: null, owed: [],
        stashesFound: 0, stashesRead: 0,
        hoursOpen: true, hoursForced: 'open',
    });
    assert.ok(/held open/i.test(panel.text('admin-doors-state')),
        'the server said the doors are held open and the tablet did not follow');
});

test('and a state the server has never heard of reads as the schedule', () => {
    const panel = withDoors(true, 'ajar');
    assert.ok(panel.node('admin-doors-schedule').classList.contains('active'),
        'a word nobody knows was drawn as a door state');
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
