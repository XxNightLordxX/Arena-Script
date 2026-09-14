/*
    crimson_arena/tests/panel/attachmentpick.test.js

    THE WIRE BETWEEN THE CHIP AND THE GUN.

    attachments_spec.lua proves the RULES -- that a kind resolves to the
    right component, that a client cannot name a component itself, that an
    empty list really means bare. Every one of those tests calls Arena
    directly, and all of them stayed green when the panel stopped sending
    the choice at all.

    That is the gap this file is for. A mutation sweep removed the one line
    in saveLoadout that puts `attachments` on the wire and nothing anywhere
    noticed: the rules were still right about a choice that was no longer
    being made. The seams between the pieces need their own tests, and this
    is the seam the player actually touches.
*/

const assert = require('assert');
const path = require('path');
const { loadPanel } = require('./harness');

const ROOT = path.resolve(__dirname, '..', '..', 'Crimson-Arena');

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

test('an unpicked weapon shows no controls, only what it would come with', () => {
    /* THE DECLUTTER. Ninety-six cards each drawing two rows of chips made
       the three a player had actually picked impossible to find. An unpicked
       card is a name and one quiet line now. */
    const panel = opened(snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    }));

    assert.ok(!panel.built('attachment-pistol-scope'),
        'an unpicked weapon drew its attachment controls anyway');
    assert.ok(/Scope/.test(panel.text('weapon-card-pistol')),
        'the card does not say what it would come with: ' + panel.text('weapon-card-pistol'));
});

test('picking it brings the controls out, every attachment already ticked', () => {
    /* Zero clicks past the pick has to be a working loadout, so the chips
       start on and the server fits exactly that when nothing is sent. */
    const panel = opened(snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    }));
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(panel.built('attachment-pistol-scope'), 'no scope chip was drawn at all');
    assert.ok(panel.node('attachment-pistol-scope').classList.contains('active'),
        'the scope chip did not start ticked');
    assert.ok(panel.node('attachment-pistol-grip').classList.contains('active'),
        'the grip chip did not start ticked');
});

test('a weapon that takes none draws no attachment row at all', () => {
    const panel = opened(snapshot(false, { attachments: [] }));
    panel.fire('weapon-card-pistol', 'click');
    assert.ok(!/Attachments/i.test(panel.text('weapon-card-pistol')),
        'an empty attachment heading was drawn on a weapon that takes none');
});

test('THE WIRE: the ticked attachments reach the server', () => {
    const panel = opened(snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    }));

    panel.fire('weapon-card-pistol', 'click');
    panel.fire('loadout-save', 'click');

    const posts = panel.posted.filter((p) => p.name === 'setLoadout');
    assert.strictEqual(posts.length, 1, 'the loadout was not sent at all');

    const pick = posts[0].body.weapons[0];
    assert.ok(pick.attachments === undefined,
        'an untouched pick sent a list instead of leaving it to the server: '
        + JSON.stringify(pick.attachments));
});

test('and unticking one takes it off what is sent', () => {
    const panel = opened(snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    }));

    panel.fire('weapon-card-pistol', 'click');

    panel.fire('attachment-pistol-scope', 'click');

    panel.fire('loadout-save', 'click');

    const posts = panel.posted.filter((p) => p.name === 'setLoadout');
    assert.strictEqual(posts.length, 1, 'the loadout was not sent');

    const sent = posts[0].body.weapons[0].attachments;
    assert.ok(Array.isArray(sent), 'nothing was sent for a choice the player made');
    assert.ok(sent.indexOf('scope') < 0, 'the unticked scope was sent anyway: ' + sent.join(','));
    assert.ok(sent.indexOf('grip') >= 0, 'unticking the scope took the grip with it: ' + sent.join(','));
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
