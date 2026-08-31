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
                weaponSlots: 2,
                meleeSlots: 2,
                weapons: WEAPONS,
                categories: [
                    { key: 'sidearm', label: 'Sidearms', order: 1 },
                    { key: 'primary', label: 'Primaries', order: 2 },
                ],
                armor: { allowChoose: true, options: [0, 50, 100], default: 100 },
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
                armor: 50,
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

test('the armour line names what the HOST set, not the server default', () => {
    /* Reading the config default told a player they were starting with 100
       while the host had set them to 50. */
    const panel = opened('guest');
    const armor = panel.text('armor-picker');
    assert.ok(/50/.test(armor), 'the armour shown is not the host\'s choice: ' + armor);
    assert.ok(!/100/.test(armor), 'the server default was shown instead: ' + armor);
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
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
