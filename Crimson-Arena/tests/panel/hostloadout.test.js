/*
    crimson_arena/tests/panel/hostloadout.test.js

    WHAT A PLAYER WHO CANNOT PICK THEIR LOADOUT SEES.

    Config.Loadouts.chooser ships as 'host': the host picks once and every
    fighter in the match carries it. The server enforces that -- a non-host's
    own setLoadout is refused, not merely hidden -- so the only question left
    is what the panel puts in front of them.

    It used to be the whole picker, drawn and disabled, on the reasoning that
    seeing the lists is worth something even when they cannot be touched. It
    is not. A player who joined a match was handed ninety-odd greyed-out
    weapon cards to scroll past, and the one thing they wanted -- what they
    will be carrying -- was underneath all of it.

    So: no picker, and the summary of what was chosen. These assert both
    halves, because hiding the lists without showing the choice would be
    worse than what it replaced.
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

const WEAPONS = [
    {
        key: 'pistol', label: 'Pistol', category: 'sidearm', melee: false,
        allowCustomAmmo: true, ammo: { default: 60, options: [30, 60], max: 250 }, ammoTypes: [],
    },
    {
        key: 'rifle', label: 'Rifle', category: 'primary', melee: false,
        allowCustomAmmo: true, ammo: { default: 90, options: [90], max: 250 }, ammoTypes: [],
    },
    {
        key: 'knife', label: 'Knife', category: 'melee', melee: true,
        allowCustomAmmo: false, ammo: { default: 1, options: [], max: 1 }, ammoTypes: [],
    },
];

/* `who` is 'host' or 'guest'; `chooser` is the operator's setting. */
function snapshot(who, chooser) {
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: {
                allowChoose: true,
                chooser: chooser || 'host',
                allowCustomAmmo: true,
                slots: 4,
                allowFirearms: true,
                allowMelee: true,
                weapons: WEAPONS,
                categories: [
                    { key: 'sidearm', label: 'Sidearms', order: 1 },
                    { key: 'primary', label: 'Primaries', order: 2 },
                ],
                supplies: {
                    enabled: true,
                    allowChoose: true,
                    totalItems: 8,
                    items: [
                        { key: 'armour', label: 'Body Armour', max: 4, default: 4, options: [0, 1, 2, 4] },
                        { key: 'bandage', label: 'Bandage', max: 6, default: 6, options: [0, 2, 4, 6] },
                    ],
                },
            },
            teams: { list: [] },
            ui: {},
        },
        player: {
            serverId: 5,
            matchId: 'm1',
            isHost: who === 'host',
            /* What the host settled on, which is what this player will be
               handed whether or not they chose it. */
            loadout: {
                weapons: [
                    { key: 'rifle', weapon: 'WEAPON_RIFLE', ammo: 137 },
                    { key: 'knife', weapon: 'WEAPON_KNIFE', ammo: 1 },
                ],
                supplies: [{ key: 'armour', count: 2 }, { key: 'bandage', count: 0 }],
            },
        },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Arena', modeKey: 'ffa', modeLabel: 'FFA',
            state: 'lobby', playerCount: 2, hostName: 'Host', players: [], teams: false,
        }],
        leaderboard: [],
    };
}

function opened(who, chooser) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(who, chooser);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

console.log('==> the loadout tab for somebody who cannot pick');

test('a non-host is shown no weapon picker at all', () => {
    const panel = opened('guest');
    assert.ok(panel.node('loadout-lists').classList.contains('hidden'),
        'the whole weapon picker was drawn for a player who may not use it');
});

test('and no weapon cards are built behind the hidden panel either', () => {
    /* Not merely hidden: not built. A hidden container full of controls is
       still a screenful of work on every render, and a card that exists can
       be clicked by anything that finds it. */
    const panel = opened('guest');
    assert.ok(!panel.built('weapon-card-pistol'),
        'the weapon cards were built for a player who cannot choose them');
});

test('but they ARE shown what they will be carrying', () => {
    // The half that matters. Hiding the lists without this would be worse
    // than the greyed-out picker it replaces.
    const panel = opened('guest');
    const slots = panel.text('loadout-slots');
    assert.ok(/Rifle/.test(slots), 'the chosen rifle is not shown: ' + slots);
    assert.ok(/Knife/.test(slots), 'the chosen knife is not shown: ' + slots);
    assert.ok(/137/.test(slots), 'the amount the host chose is not shown: ' + slots);
});

test('and told why the lists are not there', () => {
    const panel = opened('guest');
    const note = panel.text('loadout-note');
    assert.ok(/host picks one loadout/.test(note), 'no explanation was given: ' + note);
    assert.ok(/Into The Round/.test(note),
        'the note does not point at where the answer actually is: ' + note);
});

test('the supplies line names what the HOST set, not the server default', () => {
    /* Reading the config default told a player they were carrying four
       plates while the host had set them two. Same defect, same place, one
       feature along -- so the same assertion follows it. */
    const panel = opened('guest');
    const supplies = panel.text('supplies-picker');
    assert.ok(/2/.test(supplies), 'the supplies shown are not the host\'s choice: ' + supplies);
    assert.ok(!/4/.test(supplies), 'the server default was shown instead: ' + supplies);
});

test('and a supply the host took none of shows as none, not as the default', () => {
    /* The other half, and the one a fallback gets wrong: an entry the host
       deliberately zeroed must not re-seed from the operator's default the
       moment the panel reopens. */
    const panel = opened('guest');
    const supplies = panel.text('supplies-picker');
    assert.ok(/Bandage/.test(supplies), 'the bandage row was not drawn: ' + supplies);
    assert.ok(!/6/.test(supplies), 'a supply the host set to none showed the default: ' + supplies);
});

test('and there is no Save button for a choice they cannot make', () => {
    const panel = opened('guest');
    assert.ok(panel.node('loadout-save-row').classList.contains('hidden'),
        'a player who cannot choose was offered a Save button');
});

console.log('');
console.log('==> and for the host, who can');

test('the host still gets the whole picker', () => {
    const panel = opened('host');
    assert.ok(!panel.node('loadout-lists').classList.contains('hidden'),
        'the host cannot see the picker they own');
    assert.ok(panel.built('weapon-card-pistol'), 'the weapon cards were not built for the host');
    assert.ok(!panel.node('loadout-save-row').classList.contains('hidden'),
        'the host has no way to save what they picked');
});

test('and on a chooser = player server, everybody does', () => {
    const panel = opened('guest', 'player');
    assert.ok(!panel.node('loadout-lists').classList.contains('hidden'),
        'a player-picks server hid the picker from a player');
    assert.ok(panel.built('weapon-card-pistol'));
});

console.log('');
console.log('==> and what the save row claims about a save');

/* Presses one weapon card, so the draft is dirty and Save is live. */
function edit(panel) {
    panel.fire('weapon-card-pistol', 'click');
}

test('a fresh screen says the picker is showing what the server holds', () => {
    const panel = opened('host');
    assert.strictEqual(panel.text('loadout-save-status'),
        'Saved. This is what you are handed when a round starts.',
        'an untouched picker did not say it was saved');
});

test('an edit says so, and offers the button', () => {
    const panel = opened('host');
    edit(panel);

    assert.ok(/^Unsaved/.test(panel.text('loadout-save-status')),
        'an edited picker did not say it was unsaved: ' + panel.text('loadout-save-status'));
    assert.strictEqual(panel.node('loadout-save').disabled, false,
        'Save Loadout was greyed out over unsaved changes');
});

test('THE BUG: pressing Save no longer claims the server agreed', () => {
    /* It used to print "Saved." the instant the button was pressed --
       before anything had left the machine. A save the server refused (the
       host picks the loadout here, a weapon switched off since the panel
       opened, a malformed request) put a red toast on screen while the
       picker underneath went on showing the rejected weapons and calling
       them saved. */
    const panel = opened('host');
    edit(panel);
    panel.fire('loadout-save', 'click');

    assert.strictEqual(panel.posted.filter((p) => p.name === 'setLoadout').length, 1,
        'the loadout never reached the wire');
    assert.strictEqual(panel.text('loadout-save-status'), 'Saving — waiting for the server.',
        'the panel claimed a save the server had not answered: ' + panel.text('loadout-save-status'));
});

test('and says it IS saved once the server answers', () => {
    const panel = opened('host');
    edit(panel);
    panel.fire('loadout-save', 'click');

    /* The server's answer is a snapshot -- server/main.lua pushes one when
       it refuses a loadout as well as when it takes one -- and the picker
       re-seeds from the loadout inside it. So this sentence is only ever
       printed about a picker showing the server's own answer. */
    panel.send('state', snapshot('host'));

    assert.strictEqual(panel.text('loadout-save-status'),
        'Saved. This is what you are handed when a round starts.',
        'the panel never acknowledged the server\'s answer: ' + panel.text('loadout-save-status'));
});

test('and an edit made while waiting still offers the button', () => {
    /* Greying Save out while an answer is in flight would be tidier and is
       a trap: an answer that never arrives -- a dropped event, a resource
       restart -- would leave the player unable to save at all with edits in
       front of them they can see are not sent. */
    const panel = opened('host');
    edit(panel);
    panel.fire('loadout-save', 'click');
    panel.fire('weapon-card-rifle', 'click');

    assert.strictEqual(panel.node('loadout-save').disabled, false,
        'an edit made while a save was in flight could not be saved');
    assert.ok(/^Unsaved/.test(panel.text('loadout-save-status')),
        'unsaved changes were reported as a save in progress: ' + panel.text('loadout-save-status'));
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
