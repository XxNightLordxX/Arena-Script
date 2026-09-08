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
        allowUnequal: true,
        maxTeamSizeDifference: 1,
        requireBothTeamsOccupied: true,
        /* HOW MANY BODIES ARE IN THE LOBBY WITHOUT A SIDE. The roster rows
           below are BUILT from the side counts plus this, so `teamCounts`
           and `players` cannot disagree the way they would if each test
           wrote both by hand -- and a lobby with unpicked players in it is
           the case the Start gate was wrong about, so it has to be as easy
           to write as any other. */
        sideless: 0,
        /* Pass a roster explicitly only to say something the counts cannot. */
        players: null,
    }, options || {});

    if (o.players === null) {
        o.players = [];
        [['crimson', o.crimson], ['ash', o.ash], ['ember', o.thirdTeam ? (o.ember || 0) : 0]]
            .forEach(function (pair) {
                for (var i = 0; i < pair[1]; i += 1) {
                    o.players.push({ id: o.players.length + 1, team: pair[0] });
                }
            });
        for (var j = 0; j < o.sideless; j += 1) {
            o.players.push({ id: o.players.length + 1, team: false });
        }
    }
    if (o.playerCount === undefined) o.playerCount = o.players.length;

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'tdm', label: 'Team Deathmatch', enabled: true, teams: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, onlyHostCanStart: false, autoStartWhenAllReady: true },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: {
                allowChoose: true,
                allowUnequal: o.allowUnequal,
                maxTeamSizeDifference: o.maxTeamSizeDifference,
                maxTeamSize: o.maxTeamSize,
                autoAssignIfUnchosen: o.autoAssignIfUnchosen,
                requireBothTeamsOccupied: o.requireBothTeamsOccupied,
                list: o.thirdTeam
                    ? [
                        { key: 'crimson', label: 'Crimson', color: '#c81020', enabled: true },
                        { key: 'ash', label: 'Ash', color: '#8a8a8a', enabled: true },
                        { key: 'ember', label: 'Ember', color: '#d07010', enabled: true },
                    ]
                    : [
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
            /* THE ROSTER SIZE, which is not always the two side counts added
               up: a lobby where nobody has picked has bodies in it and zero
               on each side, and the minPlayers term reads this. */
            teams: true,
            playerCount: o.playerCount,
            hostName: 'You',
            pot: 0, entryFee: 0,
            teamCounts: o.thirdTeam
                ? { crimson: o.crimson, ash: o.ash, ember: o.ember || 0 }
                : { crimson: o.crimson, ash: o.ash },
            players: o.players,
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

test('and the tooltip says what readying up does on THIS server', () => {
    /* It said "This does not start the round." with no config read at all,
       while the hint one line below reads autoStartWhenAllReady and says the
       opposite. The shipped setting makes the tooltip the wrong one. */
    const on = opened({});
    on.node('btn-ready').title = on.node('btn-ready').title;   // read as rendered
    assert.ok(/starts on its own/i.test(String(on.node('btn-ready').title)),
        'a server that auto-starts still told the player readying up does nothing: '
        + on.node('btn-ready').title);

    const snap = snapshot({});
    snap.config.match.autoStartWhenAllReady = false;
    const off = loadPanel(ROOT);
    off.send('open', snap);
    off.send('state', snap);
    assert.ok(/does not start the round/i.test(String(off.node('btn-ready').title)),
        'a server that does NOT auto-start promised it would: ' + off.node('btn-ready').title);
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

console.log('==> a lobby the server would refuse is not offered a green button');

/** The Start button, after the panel has drawn `options`. */
function startButton(options) {
    return opened(options).node('btn-start');
}

test('a legal lobby still lights Start', () => {
    const start = startButton({ crimson: 1, ash: 1 });
    assert.strictEqual(start.disabled, false,
        'a startable lobby was refused: ' + start.title);
    assert.ok(/send everyone into the arena/i.test(String(start.title)),
        'the tooltip changed on a lobby nothing is wrong with: ' + start.title);
});

test('THE BUG: one side empty was offered a full-strength Start', () => {
    /* Arena.TeamsAreStartable refuses `occupied < 2` with
       'error.need_two_teams', and the host clicked a green button whose
       tooltip promised the round would start. */
    const start = startButton({ crimson: 2, ash: 0 });
    assert.strictEqual(start.disabled, true, 'Start was lit on a lobby with one side empty');
    assert.ok(/both sides/i.test(String(start.title)),
        'and it did not say why: ' + start.title);
});

test('and sides further apart than the server allows', () => {
    const start = startButton({ allowUnequal: false, maxTeamSizeDifference: 1, crimson: 3, ash: 1 });
    assert.strictEqual(start.disabled, true, 'Start was lit on a 3v1 the server refuses');
    assert.ok(/3 against 1|1 against 3/.test(String(start.title)),
        'and it did not say what the sides are: ' + start.title);
});

test('and a side over its cap, which had no text anywhere on the screen', () => {
    const start = startButton({ maxTeamSize: 2, crimson: 3, ash: 1 });
    assert.strictEqual(start.disabled, true, 'Start was lit on a side over its cap');
    assert.ok(/limit/i.test(String(start.title)), 'and it did not say why: ' + start.title);
});

test('and a player with no side on a server that will not pick for them', () => {
    /* The sharpest miss: the panel already reads autoAssignIfUnchosen and
       greys out READY UP for this exact rule, and Start was left out of the
       same pass. */
    const start = startButton({ autoAssignIfUnchosen: false, crimson: 1, ash: 1, sideless: 1 });
    assert.strictEqual(start.disabled, true, 'Start was lit with somebody still without a side');
    assert.ok(/without a side/i.test(String(start.title)),
        'and it did not say why: ' + start.title);
});

test('and the picker says the same thing the button does', () => {
    /* Two hand-written warnings used to live in the picker and the button
       consulted neither, so the screen and the control could disagree. They
       read one answer now. */
    const panel = opened({ maxTeamSize: 2, crimson: 3, ash: 1 });
    assert.ok(/limit/i.test(panel.text('team-picker')),
        'the picker said nothing about a side over its cap: ' + panel.text('team-picker'));
});

test('and an all-unpicked lobby the server WOULD split is not warned about', () => {
    /* The opposite sign, and it was there too: with autoAssign ON and
       nobody having picked, assignMissingTeams splits the roster and Begin
       starts it -- while the picker printed "Both sides need at least one
       player before the round can start." */
    const panel = opened({ autoAssignIfUnchosen: true, crimson: 0, ash: 0, sideless: 2 });
    assert.strictEqual(panel.node('btn-start').disabled, false,
        'Start was refused on a lobby the server would have split and started: '
            + panel.node('btn-start').title);
    assert.ok(!/both sides/i.test(panel.text('team-picker')),
        'the picker warned about sides the server does not care about: ' + panel.text('team-picker'));
});

test('an EMPTY third side is not counted into how far apart the sides are', () => {
    /* Arena.TeamsAreStartable measures the spread across OCCUPIED sides.
       Counting an empty third team as a 0 would report every two-sided lobby
       on a three-team server as wildly uneven -- 2v2 read as "0 against 2"
       -- and refuse a round the server starts happily. */
    const start = startButton({
        thirdTeam: true,
        allowUnequal: false,
        maxTeamSizeDifference: 0,
        crimson: 2, ash: 2, ember: 0,
    });
    assert.strictEqual(start.disabled, false,
        'a level 2v2 was refused because a third side was empty: ' + start.title);
});

test('and a server that does not require both sides occupied is not told to level them', () => {
    const start = startButton({ requireBothTeamsOccupied: false, crimson: 2, ash: 0 });
    assert.strictEqual(start.disabled, false,
        'Start was refused for a rule this server has switched off: ' + start.title);
});

test('THE REGRESSION: a lobby where nobody has picked is one the server SPLITS and starts', () => {
    /* ArenaMatch.Begin runs assignMissingTeams BEFORE Arena.CanStartMatch, so
       everybody who never touched the picker is dropped onto the smallest
       side with room and the round starts. The first version of this gate
       measured the roster as it STOOD, so on the shipped defaults it greyed
       out Start on any team lobby holding one un-picked player — which is
       precisely the lobby autoAssignIfUnchosen exists to allow.

       This ran green for a while because the test below it switched
       requireBothTeamsOccupied OFF in its own fixture, disabling the very
       term that fires. Twelfth fixture lie in this project, and mine. */
    const start = startButton({ crimson: 0, ash: 0, sideless: 2 });
    assert.strictEqual(start.disabled, false,
        'Start was dead on a lobby the server splits and starts: ' + start.title);
});

test('and one where a single player has not picked, on the shipped defaults', () => {
    /* crimson 2, ash 0, one unpicked: the split puts them on ash, both sides
       are occupied, and Begin returns ok. Measured pre-split it reads as one
       empty side. */
    const start = startButton({ crimson: 2, ash: 0, sideless: 1 });
    assert.strictEqual(start.disabled, false,
        'Start was dead on a 2v0 the split levels: ' + start.title);
});

test('and the spread is measured AFTER the split, not before it', () => {
    /* 3v1 with one unpicked and an allowance of 1. Pre-split that is 1
       against 3 and refused; the split puts the fifth on ash, making it 3v2,
       which is within the allowance and which Begin starts. */
    const start = startButton({
        allowUnequal: false, maxTeamSizeDifference: 1,
        crimson: 3, ash: 1, sideless: 1,
    });
    assert.strictEqual(start.disabled, false,
        'Start was dead on a 3v1+1 the split turns into a legal 3v2: ' + start.title);
});

test('and a roster that only becomes uneven after the split is NOT offered', () => {
    /* The other direction, which the same omission got wrong: 2v2 plus one
       unpicked at an allowance of 0 is level right up until the split lands
       the fifth player, and then it is 3v2 and Arena.TeamsAreStartable
       refuses it. The old gate lit Start and the host got a toast. */
    const start = startButton({
        allowUnequal: false, maxTeamSizeDifference: 0,
        crimson: 2, ash: 2, sideless: 1,
    });
    assert.strictEqual(start.disabled, true,
        'Start was lit on a roster the split makes uneven');
    assert.ok(/2 against 3|3 against 2/.test(String(start.title)),
        'and it did not say what the sides become: ' + start.title);
});

test('and a one-team server is not refused a rule the server does not have', () => {
    /* Arena.TeamsAreStartable refuses only `#teams == 0`. A server down to
       one enabled side with requireBothTeamsOccupied off starts happily; the
       gate was inventing "fewer than two sides" as a refusal of its own. */
    const panel = loadPanel(ROOT);
    const snap = snapshot({ requireBothTeamsOccupied: false, crimson: 2, ash: 0 });
    snap.config.teams.list = [snap.config.teams.list[0]];
    snap.matches[0].teamCounts = { crimson: 2 };
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('btn-start').disabled, false,
        'a one-team server was refused a start the server allows: '
            + panel.node('btn-start').title);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    console.log('Failures:');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
