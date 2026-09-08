/*
    crimson_arena/tests/panel/arenashut.test.js

    A SHUT ARENA IS ONE SCREEN.

    Matches, Loadout and Bets are all things a player cannot do while the
    doors are closed. Offering all five tabs anyway is offering five ways to
    find that out one at a time -- click Matches and the list is empty, click
    Create and the button is dead, click Loadout and save a kit for a round
    that cannot start. What is wanted instead is the answer, in letters big
    enough to read from where they are standing, and when to come back.

    A FIGHTER MID-ROUND IS THE EXCEPTION, and it is not a nicety. Closing the
    arena stops people coming IN and leaves the round already being fought to
    finish -- so for somebody still in one, every tab is still true. Taking
    them away would strand a live fighter behind a wall with no Leave Match
    button, which is the exact "stuck" this screen exists to prevent.
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

/* @param schedule the block server/util.lua's ArenaHoursSnapshot builds
   @param matchId  the match this player is in, or null */
function snapshot(schedule, matchId) {
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600 },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: {
                allowChoose: true, chooser: 'player', weapons: [],
                armor: { allowChoose: false, options: [], default: 100 },
            },
            teams: { list: [] },
            ui: {},
        },
        player: { matchId: matchId || null },
        matches: matchId
            ? [{
                id: matchId, arenaKey: 'a', arenaLabel: 'Arena', modeKey: 'ffa',
                modeLabel: 'FFA', state: 'live', playerCount: 2, hostName: 'John Allday',
                players: [], teams: [],
            }]
            : [],
        leaderboard: [],
        schedule: schedule,
    };
}

function opened(schedule, matchId) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(schedule, matchId);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function hidden(panel, id) {
    return panel.node(id).classList.contains('hidden');
}

const SHUT_ON_HOURS = {
    open: false, now: '03:00',
    line: '05:00-07:00, 12:00-14:00', opensAt: '05:00',
};
const SHUT_BY_ADMIN = {
    open: false, now: '13:00', forced: 'shut',
    line: '05:00-07:00, 12:00-14:00',
};
const OPEN = { open: true, now: '13:00', line: '05:00-07:00', closesAt: '14:00' };

console.log('==> a shut arena is one screen, not five dead tabs');

test('THE REQUEST: the tabs and the whole body go away', () => {
    const panel = opened(SHUT_ON_HOURS, null);

    assert.ok(!hidden(panel, 'arena-shut'), 'the closed screen was not drawn');
    assert.ok(hidden(panel, 'arena-nav'), 'the tabs are still offered');
    assert.ok(hidden(panel, 'arena-body'),
        'Matches, Loadout and Bets are all still on screen');
});

test('and it says WHY, in its own words for each of the two reasons', () => {
    const byHours = opened(SHUT_ON_HOURS, null);
    assert.ok(/hours/i.test(byHours.text('arena-shut-why')),
        'a closure on the schedule does not say so: ' + byHours.text('arena-shut-why'));
    assert.ok(!/admin/i.test(byHours.text('arena-shut-why')),
        'and blames an admin for it: ' + byHours.text('arena-shut-why'));

    const byAdmin = opened(SHUT_BY_ADMIN, null);
    assert.ok(/admin/i.test(byAdmin.text('arena-shut-why')),
        'a closure an admin made does not say so: ' + byAdmin.text('arena-shut-why'));
});

test('and when to come back', () => {
    const panel = opened(SHUT_ON_HOURS, null);
    const hours = panel.text('arena-shut-hours');

    assert.ok(/05:00-07:00/.test(hours), 'the hours are not on the screen: ' + hours);
    assert.ok(/12:00-14:00/.test(hours), 'and not all of them: ' + hours);
    assert.ok(/05:00/.test(hours), 'nor when it next opens: ' + hours);
});

test('and a server with no hours says the truth about that instead', () => {
    /* No schedule means the closure can only be an admin's, and no clock is
       going to undo it. Quoting hours that do not exist would be the wrong
       kind of reassuring. */
    const panel = opened({ open: false, now: '13:00', forced: 'shut' }, null);
    const hours = panel.text('arena-shut-hours');
    assert.ok(/no opening hours/i.test(hours),
        'a server that keeps no hours was given some: ' + hours);
    assert.ok(/admin says so/i.test(hours),
        'and the player was not told what actually reopens it: ' + hours);
});

test('an OPEN arena is the ordinary panel, untouched', () => {
    const panel = opened(OPEN, null);
    assert.ok(hidden(panel, 'arena-shut'), 'the closed screen was drawn over an open arena');
    assert.ok(!hidden(panel, 'arena-nav'), 'the tabs were taken away');
    assert.ok(!hidden(panel, 'arena-body'), 'and so was everything else');
});

test('and a server keeping no hours at all is not treated as shut', () => {
    /* Config.Schedule off sends `open: true`, and the whole feature fails
       OPEN by design. A panel that read a missing block as closed would take
       the arena away from every server that never asked for hours. */
    const panel = opened({}, null);
    assert.ok(hidden(panel, 'arena-shut'),
        'a server with no schedule at all was told its arena is closed');
});

console.log('');
console.log('==> and a fighter mid-round is never walled in');

test('THE STUCK CASE: somebody still in a match keeps their whole panel', () => {
    /* Closing the arena leaves the round already being fought to finish. A
       fighter in one needs the Lobby tab, the scoreboard and Leave Match --
       taking them away is the stuck this screen exists to prevent. */
    const panel = opened(SHUT_BY_ADMIN, 'm1');

    assert.ok(hidden(panel, 'arena-shut'),
        'a fighter mid-round was shown the closed screen');
    assert.ok(!hidden(panel, 'arena-nav'), 'and had their tabs taken away');
    assert.ok(!hidden(panel, 'arena-body'), 'and the rest of the panel with them');
});

test('and gets the closed screen only once their round is over', () => {
    /* The transition: the round ends, the server stops naming them a match,
       and the next push is the closed arena they are standing outside of. */
    const panel = opened(SHUT_BY_ADMIN, 'm1');
    assert.ok(hidden(panel, 'arena-shut'), 'they were walled in from the start');

    panel.send('state', snapshot(SHUT_BY_ADMIN, null));

    assert.ok(!hidden(panel, 'arena-shut'),
        'their round ended and the panel still offered a shut arena five ways');
    assert.ok(hidden(panel, 'arena-nav'), 'and kept the tabs');
});

test('THE STUCK CASE: a lobby destroyed under an open panel is not a dead screen', () => {
    /* Closing the arena destroys every lobby still waiting to start and hands
       the stakes back. The player who was sitting in one has their panel open
       on the Lobby tab at that moment, looking at a match that no longer
       exists. */
    const panel = opened(OPEN, 'm1');
    assert.ok(!hidden(panel, 'arena-body'), 'the panel never opened');

    panel.send('state', snapshot(SHUT_BY_ADMIN, null));

    assert.ok(!hidden(panel, 'arena-shut'),
        'the lobby vanished and the player was left looking at where it had been');
    assert.ok(hidden(panel, 'arena-nav'), 'with the tabs still offered');
});

test('and the panel can still be closed from that screen', () => {
    /* The header is deliberately NOT part of what goes away. A screen with no
       way out is the worst version of this. */
    const panel = opened(SHUT_ON_HOURS, null);
    assert.ok(!hidden(panel, 'arena-header'), 'the header went away with everything else');

    panel.fire('arena-close', 'click');
    const closes = panel.posted.filter(function (row) { return row.name === 'close'; });
    assert.strictEqual(closes.length, 1, 'the panel could not be closed from the shut screen');
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
