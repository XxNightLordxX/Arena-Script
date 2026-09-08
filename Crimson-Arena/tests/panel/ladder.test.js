/*
    crimson_arena/tests/panel/ladder.test.js

    WHAT THE PANEL SAYS ABOUT A MODE THAT ISSUES ITS OWN LOADOUT.

    The server had been putting `tier` and `tiers` on every scoreboard row of
    a gun game for as long as the mode existed, and a grep for either across
    the whole panel returned nothing. The one number the mode is played for
    reached the player only as a toast that scrolled away, and a player who
    had just been knocked down a tier could not tell a rule from a bug.

    Three separate things key off `Arena.GetEnabledModes()` now, and none of
    them had a test in either language -- so both ends of that wire were
    unguarded at once:

      THE SCOREBOARD COLUMN, drawn only where the server sends a height.
      THE LOBBY CARD, which must stop quoting lives and a win condition that
      a ladder mode does not use.
      THE LOADOUT SCREEN, which must shut, and say what it hands out instead.

    These assert on RENDERED TEXT AND CLASSES, for the reason the sibling
    lobbycard suite gives: every one of these bugs was a value that was
    correct at every point a state assertion could have looked at it, and
    wrong by the time a player read it.
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

/* The two modes, as Arena.GetEnabledModes really sends them: a ladder mode
   carries `tiers` and `startingKit` and its own `roundTimeSeconds`, and an
   ordinary one carries neither of the first two. A fixture that gave both
   modes the same fields would hide every bug below. */
const LADDER_MODE = {
    key: 'gungame',
    label: 'Gun Game',
    enabled: true,
    teams: false,
    tiers: 7,
    roundTimeSeconds: 480,
    startingKit: [
        { label: 'Body Armour', count: 1 },
        { label: 'Bandage', count: 5 },
    ],
};

const PLAIN_MODE = { key: 'ffa', label: 'Free For All', enabled: true, teams: false, roundTimeSeconds: 600 };

function snapshot(modeKey, scoreboard) {
    const match = {
        id: 'm1',
        arenaKey: 'airfield',
        arenaLabel: 'Sandy Shores Airfield',
        modeKey: modeKey,
        modeLabel: modeKey === 'gungame' ? 'Gun Game' : 'Free For All',
        state: 'lobby',
        lives: 3,
        playerCount: 2,
        hostName: 'John Allday',
        players: [],
        teams: [],
    };

    return {
        config: {
            arenas: [{ key: 'airfield', label: 'Sandy Shores Airfield', enabled: true }],
            modes: [PLAIN_MODE, LADDER_MODE],
            match: {
                lives: 3,
                livesChoice: { min: 1, max: 10 },
                minPlayers: 2,
                maxPlayers: 0,
                roundTimeSeconds: 600,
                winCondition: 'last_standing',
                onlyHostCanStart: true,
            },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: {
                allowChoose: true,
                chooser: 'player',
                weapons: [],
                supplies: { enabled: true, allowChoose: true, totalItems: 0, items: [] },
            },
            teams: { list: [] },
            ui: {},
        },
        player: { matchId: 'm1', serverId: 1 },
        matches: [match],
        leaderboard: [],
        scoreboard: scoreboard,
    };
}

function panelFor(modeKey, scoreboard) {
    const panel = loadPanel(ROOT);
    panel.send('open', snapshot(modeKey, scoreboard));
    panel.send('state', snapshot(modeKey, scoreboard));
    return panel;
}

/* The same panel with the ladder mode's `startingKit` replaced -- `null`
   deletes the field the way a mode that names no kit really arrives.

   THE THREE ANSWERS ARE DIFFERENT ON PURPOSE, which is the whole of the two
   tests at the bottom of this file: a list is "here is the kit", an empty
   list is "nothing at all, deliberately", and no field is "this mode has no
   opinion -- hand out whatever this server hands out". */
function panelWithKit(kit) {
    const panel = loadPanel(ROOT);
    const snap = snapshot('gungame', []);
    const mode = snap.config.modes.find((m) => m.key === 'gungame');
    if (kit === null) delete mode.startingKit; else mode.startingKit = kit;
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

console.log('==> the tier column on the scoreboard');

/* Two fighters, the second of them ahead on the ladder and behind on kills
   -- which is the ordering the server sorts by and the panel must not
   re-sort. */
const ROWS = [
    { id: 1, name: 'Ada', kills: 6, deaths: 5, alive: true, remaining: true, tier: 2, tiers: 7 },
    { id: 2, name: 'Ben', kills: 2, deaths: 0, alive: true, remaining: true, tier: 5, tiers: 7 },
];

test('a ladder row draws the tier, and says how tall the ladder is', () => {
    const panel = panelFor('gungame', ROWS);
    panel.send('hud', { visible: true, hud: { alive: 2, total: 2, scoreboard: ROWS } });
    const text = panel.text('hud-scoreboard');

    assert.ok(/2\/7/.test(text), 'Ada\'s tier is missing from the board: ' + text);
    assert.ok(/5\/7/.test(text), 'Ben\'s tier is missing from the board: ' + text);
    assert.ok(/Ada/.test(text) && /Ben/.test(text), 'the names went with it: ' + text);
});

test('and an ordinary mode draws no tier column at all', () => {
    // THE MECHANISM, not a coincidence: the server sends tier and tiers as
    // null outside a ladder, and that absence is the whole of how the panel
    // knows. A row that carried a stale tier would print one here.
    const plain = [
        { id: 1, name: 'Ada', kills: 6, deaths: 5, alive: true, remaining: true },
        { id: 2, name: 'Ben', kills: 2, deaths: 0, alive: true, remaining: true },
    ];
    const panel = panelFor('ffa', plain);
    panel.send('hud', { visible: true, hud: { alive: 2, total: 2, scoreboard: plain } });
    const text = panel.text('hud-scoreboard');

    assert.ok(/Ada/.test(text), 'the board rendered at all: ' + text);
    assert.ok(!/\/7/.test(text), 'a free-for-all should carry no ladder height: ' + text);
    assert.ok(!/\d+\/\d+/.test(text), 'nor anything shaped like a tier: ' + text);
});

test('the row is widened for the extra column only where there is one', () => {
    // The grid is three columns wide by default and four with a tier in it.
    // Without the class the tier is drawn into the name column and the whole
    // board shears sideways -- which no text assertion above would catch.
    const laddered = panelFor('gungame', ROWS);
    laddered.send('hud', { visible: true, hud: { alive: 2, total: 2, scoreboard: ROWS } });
    const tiered = laddered.node('hud-scoreboard').children;
    assert.ok(tiered.length > 0, 'no rows were drawn');
    tiered.forEach((row) => {
        assert.ok(row.classList.contains('tiered'),
            'a ladder row is missing the tiered class, so the tier is drawn into the name column');
    });

    const plainRows = [{ id: 1, name: 'Ada', kills: 1, deaths: 0, alive: true, remaining: true }];
    const plain = panelFor('ffa', plainRows);
    plain.send('hud', { visible: true, hud: { alive: 1, total: 1, scoreboard: plainRows } });
    plain.node('hud-scoreboard').children.forEach((row) => {
        assert.ok(!row.classList.contains('tiered'),
            'a free-for-all row should not be widened');
    });
});

console.log('');
console.log('==> what the lobby card says about a ladder mode');

test('a ladder mode quotes its OWN clock, not the server default', () => {
    // The card read Config.Match.roundTimeSeconds and nothing else, so every
    // player in a gun-game lobby was told the wrong length of the round they
    // were about to play -- ten minutes against the mode's eight.
    const text = panelFor('gungame', []).text('lobby-meta');
    assert.ok(/8:00/.test(text), 'the mode\'s own 480 seconds is missing: ' + text);
    assert.ok(!/10:00/.test(text), 'the card is still quoting the shared 600: ' + text);

    const plain = panelFor('ffa', []).text('lobby-meta');
    assert.ok(/10:00/.test(plain), 'and an ordinary mode still reads the shared number: ' + plain);
});

test('and stops quoting lives and a win condition it does not use', () => {
    const text = panelFor('gungame', []).text('lobby-meta');
    assert.ok(!/lives each/.test(text), 'a ladder mode spends no lives: ' + text);
    assert.ok(!/One life/.test(text), 'nor eliminates on the first death: ' + text);
    assert.ok(/Respawn until the clock stops/.test(text), 'and should say so: ' + text);
    assert.ok(/topping the 7-tier ladder/.test(text), 'and name what winning is: ' + text);
    assert.ok(!/last one standing/.test(text), 'the win condition does not apply: ' + text);
});

test('an ordinary mode is untouched by any of it', () => {
    const text = panelFor('ffa', []).text('lobby-meta');
    assert.ok(/3 lives each/.test(text), 'a free-for-all still quotes lives: ' + text);
    assert.ok(!/Respawn until the clock stops/.test(text), 'and not the ladder line: ' + text);
    assert.ok(!/tier ladder/.test(text), 'nor a ladder it does not climb: ' + text);
});

console.log('');
console.log('==> the loadout screen a ladder mode shuts');

test('the weapon lists and the Save row go, and the reason takes their place', () => {
    const panel = panelFor('gungame', []);
    const note = panel.text('loadout-note');

    assert.ok(/Gun Game/.test(note), 'the note should name the mode: ' + note);
    assert.ok(/7-tier ladder/.test(note), 'and the ladder it hands out: ' + note);
    assert.ok(/drawn fresh every round/.test(note), 'and that it is not the same one twice: ' + note);

    // THE KIT, BY NAME AND NUMBER, off the wire -- an operator who renames
    // the item or changes the count gets a panel that says so.
    assert.ok(/1 Body Armour/.test(note), 'the kit\'s armour is missing: ' + note);
    assert.ok(/5 Bandages/.test(note), 'the kit\'s bandages are missing: ' + note);

    assert.ok(panel.node('loadout-save-row').classList.contains('hidden'),
        'the save row should be hidden where nothing can be saved');
});

test('the Supplies block states the kit the mode issues, not a saved draft', () => {
    // It used to draw the player's own draft chips under a caption reading
    // "Set by the server." -- which is a specific claim about the wrong
    // numbers: the screen said whatever they last saved on some other mode,
    // and the round handed out the mode's kit.
    const panel = panelFor('gungame', []);
    const text = panel.text('supplies-picker');

    assert.ok(/Body Armour/.test(text), 'the kit is missing from the block: ' + text);
    assert.ok(/Bandage/.test(text), 'and its bandages: ' + text);
    assert.ok(/\b1\b/.test(text) && /\b5\b/.test(text),
        'with the counts the mode really issues: ' + text);
    assert.ok(!/Set by the server/.test(text),
        'the old caption claimed the draft below it was what the server would hand out: ' + text);
    assert.ok(/Issued to everyone/.test(text), 'and should say where it comes from: ' + text);
});

test('and an ordinary mode still lets a player pick', () => {
    const panel = panelFor('ffa', []);
    const note = panel.text('loadout-note');
    assert.ok(!/hands out its own weapons/.test(note),
        'a free-for-all should not be locked: ' + note);
    assert.ok(/Click a weapon to carry it/.test(note),
        'and should still explain the picker: ' + note);
});

test('Into The Round stops previewing a loadout the round will throw away', () => {
    // The one lie this screen must never tell: a player picked a rifle,
    // saved it, read this heading showing exactly that, and was handed a
    // golf club.
    const slots = panelFor('gungame', []).text('loadout-slots');
    assert.ok(/tier 1 of 7/.test(slots), 'it should say where everybody opens: ' + slots);
    assert.ok(/1 Body Armour/.test(slots) && /5 Bandages/.test(slots),
        'and what they are issued with it: ' + slots);
});

test('the host is not offered Lives Each for a mode that spends none', () => {
    // It rode all the way through -- validated, stored on the match, echoed
    // back on the wire -- and changed nothing about the round, so a host who
    // set it to 1 and watched twelve deaths eliminate nobody had no way to
    // tell whether the setting or the mode was broken.
    const panel = panelFor('gungame', []);
    // The create form follows its own mode select, not the match the player
    // is in -- this is the box where the mode is chosen.
    panel.node('create-mode').value = 'gungame';
    panel.fire('create-mode', 'change');

    assert.ok(panel.node('create-lives-row').classList.contains('hidden'),
        'the lives row should be hidden for a ladder mode');

    const note = panel.text('create-lives-note');
    assert.ok(/no lives/.test(note), 'and should say why it went: ' + note);
});

test('a mode that names NO kit does not claim nobody is issued anything', () => {
    /* Deleting `startingKit` is a documented, distinct choice, and the
       server honours it: kitFor falls through and every fighter walks in
       carrying this server's own supply defaults -- a plate and a couple of
       bandages on the shipped config. The panel collapsed that into the
       empty-list case and printed "No supplies are issued in this mode."
       while the round handed out three items. */
    const slots = panelWithKit(null).text('loadout-slots');

    assert.ok(!/No supplies are issued in this mode/.test(slots),
        'the screen says nobody is issued anything, and the server issues the defaults: ' + slots);
    assert.ok(/by default/.test(slots),
        'and it should say where what they carry comes from: ' + slots);
});

test('and one that names an EMPTY kit still says exactly that', () => {
    /* The other half. An empty list really does mean nothing is carried,
       and a panel that softened it into "whatever the server hands out"
       would be wrong in the opposite direction. */
    const slots = panelWithKit([]).text('loadout-slots');

    assert.ok(/No supplies are issued in this mode/.test(slots),
        'a mode that deliberately issues nothing should say so: ' + slots);
    assert.ok(!/by default/.test(slots),
        'and must not promise a fallback the server will not apply: ' + slots);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
