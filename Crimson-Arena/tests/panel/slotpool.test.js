/*
    crimson_arena/tests/panel/slotpool.test.js

    THE MIX IS THE PLAYER'S, PROVEN BY DRIVING THE REAL PANEL.

    Asked for from the game, in these words: "Let it choose if they only want
    to guns or only melee."

    Guns and blades used to be two separate allowances. A player who wanted to
    fight with a bat and nothing else was made to carry two guns as well, and
    a player who wanted four rifles could not have them -- two of their four
    slots were reserved for knives they did not want.

    Now there is ONE count, Config.Loadouts.slots, and whatever mix fills it is
    the player's business. This file is the half of that claim the Lua specs
    cannot make: those drive Arena.ResolveLoadout, which is the server's
    answer. THIS drives html/app.js, which is what the player is looking at
    when they decide -- and a panel that disagrees with the server is a panel
    that tells somebody they are full while the server would have handed over
    another weapon, or the reverse.

    The Lua specs and these have to agree. That is the point of both.
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

function gun(key, label) {
    return {
        key: key, label: label, category: 'sidearm', melee: false,
        allowCustomAmmo: false, ammo: { default: 60, options: [60], max: 250 }, ammoTypes: [],
    };
}

function blade(key, label) {
    return {
        key: key, label: label, category: 'melee', melee: true,
        allowCustomAmmo: false, ammo: { default: 1, options: [], max: 1 }, ammoTypes: [],
    };
}

const WEAPONS = [
    gun('pistol', 'Pistol'), gun('rifle', 'Rifle'),
    gun('sniper', 'Sniper'), gun('shotgun', 'Shotgun'), gun('smg', 'SMG'),
    blade('bat', 'Bat'), blade('knife', 'Knife'),
    blade('machete', 'Machete'), blade('crowbar', 'Crowbar'), blade('hammer', 'Hammer'),
];

/* @param loadouts partial Config.Loadouts overrides for the snapshot */
function snapshot(loadouts) {
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
            loadouts: Object.assign({
                allowChoose: true,
                chooser: 'player',
                allowCustomAmmo: false,
                slots: 4,
                allowFirearms: true,
                allowMelee: true,
                weapons: WEAPONS,
                categories: [{ key: 'sidearm', label: 'Sidearms', order: 1 }],
            }, loadouts || {}),
            teams: { list: [] },
            ui: {},
        },
        player: {},
        matches: [],
        leaderboard: [],
    };
}

function opened(loadouts) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(loadouts);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

/** What the panel would send to the server, as weapon keys in order. */
function drafted(panel) {
    panel.fire('loadout-save', 'click');
    const sent = panel.posted.filter((entry) => entry.name === 'setLoadout');
    assert.ok(sent.length > 0, 'the panel posted no loadout at all');
    const body = sent[sent.length - 1].body || {};
    return (body.weapons || []).map((entry) => entry.key);
}

console.log('slotpool.test.js');

test('THE REQUEST: a player can spend every slot on blades', () => {
    const panel = opened();
    ['bat', 'knife', 'machete', 'crowbar'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });

    const keys = drafted(panel);
    assert.deepStrictEqual(keys, ['bat', 'knife', 'machete', 'crowbar'],
        'a melee-only loadout was cut short by the panel: ' + JSON.stringify(keys));
});

test('and every slot on guns', () => {
    const panel = opened();
    ['pistol', 'rifle', 'sniper', 'shotgun'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });

    const keys = drafted(panel);
    assert.deepStrictEqual(keys, ['pistol', 'rifle', 'sniper', 'shotgun'],
        'a firearms-only loadout was cut short by the panel: ' + JSON.stringify(keys));
});

test('and any mix, because a blade costs exactly what a gun costs', () => {
    const panel = opened();
    ['pistol', 'bat', 'rifle', 'knife'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });
    assert.strictEqual(drafted(panel).length, 4);
});

test('THE COUNT IS SHARED: a fifth weapon is refused whatever kind it is', () => {
    /* The old panel would have taken this: four guns filled the firearm
       allowance and the bat went into the melee one, which the server --
       counting the same way -- also allowed. Now both refuse it. */
    const panel = opened();
    ['pistol', 'rifle', 'sniper', 'shotgun', 'bat'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });

    const keys = drafted(panel);
    assert.strictEqual(keys.length, 4, 'the panel let a fifth weapon into a pool of four');
    assert.ok(keys.indexOf('bat') === -1, 'the blade was taken as though it were free');
});

test('and the counter says the total, not one kind of it', () => {
    const panel = opened();
    panel.fire('weapon-card-pistol', 'click');
    panel.fire('weapon-card-bat', 'click');

    /* Both sections carry the same counter on purpose: a player looking at
       the melee list still needs to know how full they are. */
    ['firearms-count', 'melee-count'].forEach((id) => {
        const text = panel.text(id);
        assert.ok(/2 of 4/.test(text),
            id + ' did not show the shared total: "' + text + '"');
    });
});

test('and clicking a carried weapon again gives the slot back', () => {
    const panel = opened();
    ['pistol', 'rifle', 'sniper', 'shotgun'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });
    panel.fire('weapon-card-rifle', 'click');      // drop it
    panel.fire('weapon-card-bat', 'click');        // and spend the freed slot on a blade

    const keys = drafted(panel);
    assert.ok(keys.indexOf('bat') !== -1, 'a freed slot could not be refilled');
    assert.ok(keys.indexOf('rifle') === -1, 'the dropped weapon was still carried');
    assert.strictEqual(keys.length, 4);
});

console.log('');
console.log('==> and the operator still decides which KINDS exist');

test('allowMelee = false takes the melee section away entirely', () => {
    /* Not greyed out: the operator meant it, and an empty section reads as a
       fault rather than as a decision. */
    const panel = opened({ allowMelee: false });
    assert.ok(panel.node('loadout-melee').classList.contains('hidden'),
        'the melee section survived allowMelee = false');
    assert.ok(!panel.node('loadout-firearms').classList.contains('hidden'),
        'switching melee off took the firearms with it');
});

test('and allowFirearms = false makes a melee-only arena', () => {
    const panel = opened({ allowFirearms: false });
    assert.ok(panel.node('loadout-firearms').classList.contains('hidden'),
        'the firearms section survived allowFirearms = false');
    assert.ok(!panel.node('loadout-melee').classList.contains('hidden'),
        'a melee-only arena hid its melee');

    /* And the pool is still four -- switching a kind off does not shrink it. */
    ['bat', 'knife', 'machete', 'crowbar'].forEach((key) => {
        panel.fire('weapon-card-' + key, 'click');
    });
    assert.strictEqual(drafted(panel).length, 4, 'a melee-only arena shrank the pool');
});

test('and both off says so rather than showing an empty picker', () => {
    const panel = opened({ allowFirearms: false, allowMelee: false });
    assert.ok(panel.node('loadout-lists').classList.contains('hidden'),
        'an arena that issues nothing still drew the lists');
    assert.ok(!panel.node('loadout-empty').classList.contains('hidden'),
        'an arena that issues nothing said nothing about it');
});

console.log('');
console.log('==> and zero means UNLIMITED, the way it does everywhere else in the file');

test('slots = 0 lets a player take the whole catalogue', () => {
    /* THE REVERSAL. Under the two keys this replaces, 0 meant "none of this
       kind". Under one pool it means "no limit" -- which is what 0 means for
       ammoTypeSlots and for supplies.totalItems, and what config.lua's own
       header says it means for every count in the file. */
    const panel = opened({ slots: 0 });
    WEAPONS.forEach((weapon) => panel.fire('weapon-card-' + weapon.key, 'click'));
    assert.strictEqual(drafted(panel).length, WEAPONS.length,
        'slots = 0 was read as a cap rather than as no cap');
});

test('and the counter drops the "of N" it has nothing to count against', () => {
    const panel = opened({ slots: 0 });
    panel.fire('weapon-card-pistol', 'click');
    const text = panel.text('firearms-count');
    assert.ok(!/ of /.test(text), 'an unlimited pool still advertised a limit: "' + text + '"');
    assert.ok(/1 weapon/.test(text), 'an unlimited pool did not say what is carried: "' + text + '"');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
