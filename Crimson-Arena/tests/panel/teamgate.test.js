/*
    crimson_arena/tests/panel/teamgate.test.js

    THE TEAM RULES THE PANEL COULD NOT SEE.

    server/lobby.lua turns down four things on the lobby screen, and the
    panel knew about one of them. The other three were a lit control and a
    red toast after the click:

      A SIDE, ONCE THE MATCH HAS KICKED OFF. SetTeam refuses anything but
      'lobby', and the lobby countdown leaves the panel open for the whole
      of it -- so the tiles went on saying "Fight on this side" while every
      click on them was refused.

      A SIDE THAT IS FULL. Config.Teams.maxTeamSize ships as 0 (unlimited),
      so on the shipped config this never fires -- which is exactly why it
      went unnoticed on the servers that set it.

      READY UP WITHOUT PICKING. With Config.Teams.autoAssignIfUnchosen off,
      SetReady refuses a player who has not chosen a side. The picker is
      sitting directly above the button that would not say so.

    Every one of them is a rule the SERVER owns. The panel does not enforce
    anything here -- it explains, before the click, what the server is
    going to do.
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

function snapshot(options) {
    const o = Object.assign({
        state: 'lobby',
        maxTeamSize: 0,
        autoAssignIfUnchosen: true,
        myTeam: 'crimson',
        crimson: 1,
        ash: 1,
        inMatch: true,
    }, options || {});

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'tdm', label: 'Team Deathmatch', enabled: true, teams: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, onlyHostCanStart: false },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: {
                allowChoose: true,
                allowUnequal: true,
                maxTeamSizeDifference: 1,
                maxTeamSize: o.maxTeamSize,
                autoAssignIfUnchosen: o.autoAssignIfUnchosen,
                list: [
                    { key: 'crimson', label: 'Crimson', color: '#c81020', enabled: true },
                    { key: 'ash', label: 'Ash', color: '#8a8a8a', enabled: true },
                ],
            },
            ui: {},
        },
        player: {
            serverId: SELF,
            money: 1000,
            matchId: o.inMatch ? 'm1' : null,
            /* A watcher still sees this lobby -- that is what makes them a
               watcher rather than somebody with the panel open -- and the
               team picker is drawn for them. */
            spectating: o.inMatch ? false : 'm1',
            isHost: true,
            ready: false,
            team: o.myTeam === null ? false : o.myTeam,
        },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
            modeKey: 'tdm', modeLabel: 'Team Deathmatch', state: o.state,
            teams: true, playerCount: o.crimson + o.ash, hostName: 'You',
            pot: 0, entryFee: 0,
            teamCounts: { crimson: o.crimson, ash: o.ash },
            players: [],
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

/** Clicks the tile labelled `label` and returns every setTeam posted. */
function pickSide(panel, label) {
    const tile = panel.node('team-picker').children.find(
        (c) => (c.children || []).some((k) => (k.textContent || '') === label));
    assert.ok(tile, 'no tile for "' + label + '"');
    (tile.listeners.click || []).forEach((fn) => fn({ stopPropagation() {}, preventDefault() {} }));
    return { tile, posted: panel.posted.filter((p) => p.name === 'setTeam') };
}

console.log('==> sides you may not move to');

test('an ordinary lobby lets you cross the floor', () => {
    const panel = opened({});
    const { tile, posted } = pickSide(panel, 'Ash');

    assert.ok(!tile.classList.contains('locked'), 'a side this player may take was drawn as locked');
    assert.strictEqual(posted.length, 1, 'the switch never reached the wire');
    assert.strictEqual(posted[0].body.teamKey, 'ash');
});

test('THE BUG: a match that has kicked off still offered its sides', () => {
    /* The lobby countdown keeps the panel open for the whole of it, and
       SetTeam refuses anything but 'lobby'. */
    const panel = opened({ state: 'countdown' });
    const { tile, posted } = pickSide(panel, 'Ash');

    assert.ok(tile.classList.contains('locked'),
        'a side was offered on a match that has already kicked off');
    assert.ok(/already kicked off/i.test(String(tile.title)),
        'the tile did not say why: ' + tile.title);
    assert.strictEqual(posted.length, 0,
        'the panel posted a team switch the server had already decided to refuse');
});

test('and a live one likewise', () => {
    const panel = opened({ state: 'live' });
    assert.strictEqual(pickSide(panel, 'Ash').posted.length, 0,
        'a team switch was posted mid-round');
});

test('a FULL side is locked, and the one you are on is not', () => {
    // Config.Teams.maxTeamSize ships as 0, so this fires only where an
    // operator set it -- which is why nobody noticed it was unenforced here.
    // BOTH sides at the cap, deliberately: the player's own side has to be
    // full for "you are never full to yourself" to be testing anything.
    const panel = opened({ maxTeamSize: 2, crimson: 2, ash: 2, myTeam: 'crimson' });

    const ash = pickSide(panel, 'Ash');
    assert.ok(ash.tile.classList.contains('locked'), 'a full side was still offered');
    assert.ok(/full/i.test(String(ash.tile.title)), 'the tile did not say why: ' + ash.tile.title);
    assert.strictEqual(ash.posted.length, 0, 'the panel posted a switch onto a full side');

    /* THE SIDE YOU ARE ALREADY ON IS NEVER FULL TO YOU. resolveTeam does not
       count a player against a cap they are already inside, and a panel that
       did would lock somebody out of their own team. */
    const own = pickSide(panel, 'Crimson');
    assert.ok(!own.tile.classList.contains('locked'),
        'the player was locked out of the side they are standing on');
});

test('and zero means unlimited, the way it does everywhere else', () => {
    const panel = opened({ maxTeamSize: 0, crimson: 1, ash: 40 });
    assert.strictEqual(pickSide(panel, 'Ash').posted.length, 1,
        'maxTeamSize 0 was read as "no room for anybody"');
});

test('somebody WATCHING the lobby is offered nothing, and told so', () => {
    const panel = opened({ inMatch: false });
    const { tile, posted } = pickSide(panel, 'Ash');
    assert.ok(tile.classList.contains('locked'), 'a side was offered to somebody not in the match');
    assert.strictEqual(posted.length, 0, 'a watcher posted a team switch');
});

console.log('');
console.log('==> and readying up without a side');

test('THE BUG: Ready Up was lit where the server demands a side first', () => {
    const panel = opened({ autoAssignIfUnchosen: false, myTeam: null });

    const ready = panel.node('btn-ready');
    assert.strictEqual(ready.disabled, true,
        'Ready Up was offered to a player the server will refuse for having no side');
    assert.ok(/[Pp]ick a side/.test(String(ready.title)),
        'the button did not say why: ' + ready.title);
});

test('and is offered the moment they pick one', () => {
    const panel = opened({ autoAssignIfUnchosen: false, myTeam: 'ash' });
    assert.strictEqual(panel.node('btn-ready').disabled, false,
        'Ready Up stayed greyed out for a player who has picked a side');
});

test('and a server that assigns for them never asks', () => {
    // The shipped default. Nobody is stopped from readying up here.
    const panel = opened({ autoAssignIfUnchosen: true, myTeam: null });
    assert.strictEqual(panel.node('btn-ready').disabled, false,
        'a server that assigns sides still demanded one be picked');
});

test('and taking a ready BACK is never refused for it', () => {
    /* SetReady only checks the side when `ready` is true. A panel that
       greyed the button out both ways would strand a player marked ready
       with no side on a server that had just been reconfigured. */
    const snap = snapshot({ autoAssignIfUnchosen: false, myTeam: null });
    snap.player.ready = true;
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('btn-ready').disabled, false,
        'a player already marked ready could not take it back');
    panel.fire('btn-ready', 'click');
    const sent = panel.posted.filter((p) => p.name === 'setReady');
    assert.strictEqual(sent.length, 1, 'the un-ready never reached the wire');
    assert.strictEqual(sent[0].body.ready, false);
});

console.log('');
console.log('==> and creating one more round than the server runs');

/* Snapshot with `n` matches on the board and a ceiling of `ceiling`, seen
   by somebody who is in none of them. */
function board(n, ceiling) {
    const snap = snapshot({ inMatch: false });
    snap.player.matchId = null;
    snap.player.spectating = false;
    snap.config.match.maxConcurrentMatches = ceiling;
    snap.matches = [];
    for (let i = 0; i < n; i += 1) {
        snap.matches.push({
            id: 'm' + i, arenaKey: 'a', arenaLabel: 'Arena',
            modeKey: 'tdm', modeLabel: 'Team Deathmatch', state: 'lobby',
            teams: true, playerCount: 1, hostName: 'Someone', pot: 0, entryFee: 0,
            teamCounts: {}, players: [],
        });
    }
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

test('THE BUG: Create Match was lit at a ceiling the server enforces', () => {
    const panel = board(2, 2);

    assert.strictEqual(panel.node('create-submit').disabled, true,
        'Create Match was offered on a server already running its limit');
    assert.ok(/at a time/i.test(panel.text('create-hint')),
        'the form did not say why: ' + panel.text('create-hint'));

    panel.fire('create-submit', 'click');
    assert.strictEqual(panel.posted.filter((p) => p.name === 'createMatch').length, 0,
        'the panel posted a create the server had already decided to refuse');
});

test('and is offered with room left', () => {
    const panel = board(1, 2);
    assert.strictEqual(panel.node('create-submit').disabled, false,
        'Create Match was refused with room to spare: ' + panel.text('create-hint'));
});

test('and zero means unlimited, the way it does everywhere else', () => {
    const panel = board(9, 0);
    assert.strictEqual(panel.node('create-submit').disabled, false,
        'maxConcurrentMatches 0 was read as "no matches allowed"');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    console.log('Failures:');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
