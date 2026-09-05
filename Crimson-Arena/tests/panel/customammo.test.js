/*
    crimson_arena/tests/panel/customammo.test.js

    TYPING YOUR OWN AMMUNITION AMOUNT.

    The presets stay; this is the box beside them. What matters is that what
    a player types is what the server is asked for -- the whole recurring
    defect in this build is a value that is right in the form and wrong on
    the wire, so these assert the PAYLOAD rather than the input's value.
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

/** A snapshot shaped like server/lobby.lua's config block. */
function snapshot(allowCustom, weaponOverride) {
    const weapon = Object.assign({
        key: 'pistol',
        label: 'Pistol',
        category: 'sidearm',
        melee: false,
        allowCustomAmmo: allowCustom,
        ammo: { default: 60, options: [30, 60, 120], max: 250 },
        ammoTypes: [],
    }, weaponOverride || {});

    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, livesChoice: { min: 1, max: 10 }, minPlayers: 2, maxPlayers: 0 },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: {
                allowChoose: true,
                chooser: 'player',
                allowCustomAmmo: allowCustom,
                slots: 3,
                allowFirearms: true,
                allowMelee: true,
                weapons: [weapon],
                categories: [{ key: 'sidearm', label: 'Sidearms', order: 1 }],
                armor: { allowChoose: false, options: [], default: 100 },
            },
            teams: { list: [] },
            ui: {},
        },
        /* IN A LOBBY, which is the only place a save reaches the server:
           setLoadout is refused with error.not_in_match from a player who is
           in none, and with error.match_in_progress once it has started. The
           panel agrees with both now, so a fixture that saved from nowhere
           was testing a request that could never have been taken. */
        player: { serverId: 7, matchId: 'm1' },
        matches: [{
            id: 'm1', arenaKey: 'a', arenaLabel: 'Arena', modeKey: 'ffa', modeLabel: 'FFA',
            state: 'lobby', teams: false, playerCount: 1, hostName: 'You',
            pot: 0, entryFee: 0, teamCounts: {}, players: [],
        }],
        leaderboard: [],
    };
}

function opened(snap) {
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);
    const tab = panel.node('tab-btn-loadout');
    return panel;
}

console.log('==> typing a custom ammo amount');

test('the box is not offered when the operator has not allowed it', () => {
    const panel = opened(snapshot(false));
    assert.ok(!panel.built('weapon-ammo-custom-pistol'),
        'a typing box was built for a server that refuses typed amounts');
    // And the presets ARE still there, so this is not passing on a panel
    // that rendered nothing at all.
    assert.ok(panel.built('weapon-card-pistol'), 'the weapon card never rendered');
});

test('a typed amount is what gets posted, not the nearest preset', () => {
    // THE POINT. 119 is on no preset list; under the old rule the server
    // would have handed back the default instead.
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');          // pick it, as a player does
    panel.type('weapon-ammo-custom-pistol', '119');     // then type the amount
    panel.fire('loadout-save', 'click');

    const sent = panel.posted.find((p) => p.name === 'setLoadout');
    assert.ok(sent, 'nothing was posted at all');
    const entry = (sent.body.weapons || []).find((w) => w.key === 'pistol');
    assert.ok(entry, 'the pistol never reached the payload');
    assert.strictEqual(entry.ammo, 119,
        'typed 119, posted ' + entry.ammo + ' -- the value did not survive the form');
});

test('typing several digits builds ONE number, not one digit at a time', () => {
    /* THE BUG THIS GUARDS, reported from a live server: "when typing a
       number it doesn't back off after hitting 1 number ... when I hit 1 I
       have to click it again to hit 0".

       setWeaponAmmo ended in render(), and render() REBUILDS the weapon
       cards -- so the <input> being typed into was destroyed on every
       keystroke and rebuilt as a new element, taking the focus and the caret
       with it. One digit per click.

       The lives box never had this because it is a static element in
       index.html; only the controls the panel builds are torn down.

       Node identity is the probe, because it is exactly what the browser
       loses: the harness re-registers a built node under its id, so a rebuilt
       box is a DIFFERENT object under the same name. */
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');

    const box = panel.node('weapon-ammo-custom-pistol');
    assert.ok(panel.built('weapon-ammo-custom-pistol'), 'the box was never built');

    // 1, then 0, then 0 -- three keystrokes, one element.
    ['1', '10', '100'].forEach((sofar) => {
        box.value = sofar;
        panel.fire('weapon-ammo-custom-pistol', 'input', { target: { value: sofar } });

        assert.strictEqual(panel.node('weapon-ammo-custom-pistol'), box,
            'the box was rebuilt after typing "' + sofar + '" -- in a browser that is the '
            + 'caret gone and the player clicking back in for every digit');
    });

    panel.fire('loadout-save', 'click');
    const sent = panel.posted.find((p) => p.name === 'setLoadout');
    assert.ok(sent, 'nothing was posted at all');
    const entry = (sent.body.weapons || []).find((w) => w.key === 'pistol');
    assert.ok(entry, 'the pistol never reached the payload');
    assert.strictEqual(entry.ammo, 100,
        'typed 100 one digit at a time and posted ' + entry.ammo);
});

test('and the save button still notices, though nothing was re-rendered', () => {
    /* The quiet path skips render(), so the one thing render() would have
       done that still matters has to be done by hand: a player who types an
       amount and is left looking at a greyed-out Save button reads it as the
       panel having ignored them. */
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');
    panel.fire('loadout-save', 'click');
    assert.strictEqual(panel.node('loadout-save').disabled, true,
        'the button was not clean after a save, so this proves nothing');

    panel.type('weapon-ammo-custom-pistol', '77');
    assert.strictEqual(panel.node('loadout-save').disabled, false,
        'typing an amount left Save greyed out -- the panel looks like it ignored the change');
});

test('clicking away writes back a value the box could not keep', () => {
    /* The box is capped at the weapon's max for guidance, but nothing is
       re-rendered while typing -- so a number over the cap sits on screen
       looking accepted. Blur is the end of typing and where the panel
       catches up, so the clamp becomes visible rather than a surprise at
       save time. */
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');
    panel.type('weapon-ammo-custom-pistol', '9999');    // max is 250

    panel.fire('weapon-ammo-custom-pistol', 'blur');
    assert.strictEqual(panel.node('weapon-ammo-custom-pistol').value, '250',
        'the box still showed a number the server would never hand out');
});

test('and a preset still works, because the chips did not go away', () => {
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');
    panel.type('weapon-ammo-custom-pistol', '120');
    panel.fire('loadout-save', 'click');

    const sent = panel.posted.find((p) => p.name === 'setLoadout');
    const entry = (sent.body.weapons || []).find((w) => w.key === 'pistol');
    assert.strictEqual(entry.ammo, 120);
});

test('a weapon pinned by the operator gets no box even when the server allows typing', () => {
    const snap = snapshot(true, { allowCustomAmmo: false });
    const panel = opened(snap);
    assert.ok(!panel.built('weapon-ammo-custom-pistol'),
        'a weapon carrying allowCustomAmmo = false was still given a typing box');
});

test('the box appears only under a weapon that has been chosen', () => {
    // Asking how much ammunition somebody wants for a gun they are not
    // carrying is a question with no meaning.
    const panel = opened(snapshot(true));
    assert.ok(!panel.built('weapon-ammo-custom-pistol'),
        'a typing box was drawn under a weapon nobody has picked');

    panel.fire('weapon-card-pistol', 'click');
    assert.ok(panel.built('weapon-ammo-custom-pistol'),
        'picking the weapon did not bring up its ammo box');
});

test('Enter in the box saves the loadout, without hunting for the save button', () => {
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');
    panel.type('weapon-ammo-custom-pistol', '77');

    const before = panel.posted.filter((p) => p.name === 'setLoadout').length;
    panel.fire('weapon-ammo-custom-pistol', 'keydown', { key: 'Enter' });

    const after = panel.posted.filter((p) => p.name === 'setLoadout');
    assert.strictEqual(after.length, before + 1, 'Enter did not save the loadout');

    const entry = (after[after.length - 1].body.weapons || []).find((w) => w.key === 'pistol');
    assert.strictEqual(entry.ammo, 77, 'Enter saved a different amount than the one typed');
});

test('and any other key does not save, so typing is not a series of saves', () => {
    const panel = opened(snapshot(true));
    panel.fire('weapon-card-pistol', 'click');
    panel.type('weapon-ammo-custom-pistol', '7');

    const before = panel.posted.filter((p) => p.name === 'setLoadout').length;
    panel.fire('weapon-ammo-custom-pistol', 'keydown', { key: '7' });
    const after = panel.posted.filter((p) => p.name === 'setLoadout').length;

    assert.strictEqual(after, before, 'an ordinary keystroke posted the whole loadout');
});

test('a weapon with one round offers no ammo-type control at all', () => {
    // The correlation is already done -- the round comes from the weapon's
    // own ammoname -- so a picker here is a question with a single answer.
    const snap = snapshot(true);
    snap.config.loadouts.weapons[0].ammoTypes = [{ key: 'standard', label: '9mm', item: 'ammo-9' }];
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');

    const text = panel.text('weapon-grid');
    assert.ok(!/Ammo type/.test(text),
        'a weapon with exactly one round still drew an ammo-type picker: ' + text);
});

test('but a weapon the operator really gave two rounds still gets the picker', () => {
    const snap = snapshot(true);
    snap.config.loadouts.weapons[0].ammoTypes = [
        { key: 'standard', label: '9mm', item: 'ammo-9' },
        { key: 'ap', label: 'AP', item: 'ammo-9-ap' },
    ];
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(/Ammo type/.test(panel.text('weapon-grid')),
        'a genuine choice between two rounds was hidden');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
