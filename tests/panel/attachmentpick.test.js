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
function snapshot(allowCustom, weaponOverride, configOverride) {
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
            loadouts: Object.assign({
                allowChoose: true,
                chooser: 'player',
                allowCustomAmmo: allowCustom,
                slots: 3,
                allowFirearms: true,
                allowMelee: true,
                weapons: [weapon],
                categories: [{ key: 'sidearm', label: 'Sidearms', order: 1 }],
                armor: { allowChoose: false, options: [], default: 100 },
            }, (configOverride || {}).loadouts || {}),
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

// ------------------------------------------------------------------
// AND THE CHOICE SURVIVES THE SERVER CONFIRMING IT
// ------------------------------------------------------------------

/* THE ROUND TRIP LOST THE PICK EVERY TIME, and the screen agreed it never
   happened. seedDraft rebuilt each draft weapon as {key, ammo, ammoType}
   only, so the moment the server confirmed a save and pushed state back,
   `pick.attachments` was undefined again; attachmentsOn() fell back to "every
   kind this weapon takes" and re-lit every chip. The player was looking at a
   scope they had deliberately taken off, being told it was fitted.

   It got worse on the next save: saveLoadout only sends the key when it is
   an array, so the field was omitted, and server/main.lua reads absent as
   "fit what this server fits by default" -- which put the scope back on the
   gun for real. Two saves and the choice was gone from both ends.

   Nothing in the snapshot could have restored it either: the resolved entry
   carried component NAMES and not the KINDS that were ticked.
   Arena.ResolveWeaponEntry records `attachments` for exactly this. */

/** The entry the server sends back after fitting `kinds`. */
function confirmed(snap, kinds) {
    const next = JSON.parse(JSON.stringify(snap));
    next.player.loadout = {
        weapons: [{
            key: 'pistol', weapon: 'WEAPON_PISTOL', label: 'Pistol', ammo: 60,
            attachments: kinds,
            components: kinds.map(function (k) { return 'COMPONENT_' + k.toUpperCase(); }),
        }],
        armor: 100, health: 200, supplies: [],
    };
    return next;
}

test('DEFECT: a chip says whether IT is fitted, not whether the weapon is picked', () => {
    /* The title read `picked ? 'Fitted...' : 'Pick this weapon...'`, and the
       whole block only runs when `picked` is true -- so the second branch was
       dead and every chip claimed to be fitted, including the ones just
       switched off. It is the one control whose entire job is to say whether
       a component is going on the gun. */
    const panel = opened(snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    }));
    panel.fire('weapon-card-pistol', 'click');
    panel.fire('attachment-pistol-scope', 'click');   // take the scope off

    const off = panel.node('attachment-pistol-scope').title;
    const on = panel.node('attachment-pistol-grip').title;

    assert.ok(/not fitted/i.test(off),
        'AN UNTICKED CHIP STILL CLAIMED TO BE FITTED: ' + off);
    assert.ok(/^fitted/i.test(on),
        'the chip that IS fitted stopped saying so: ' + on);
    assert.notStrictEqual(off, on,
        'both chips carry the same tooltip, so it says nothing about either');
});

test('DEFECT: an unticked attachment stays unticked once the server confirms', () => {
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');
    panel.fire('attachment-pistol-scope', 'click');
    panel.fire('loadout-save', 'click');

    // The server fits grip alone and pushes the state back.
    panel.send('state', confirmed(snap, ['grip']));

    assert.ok(!panel.node('attachment-pistol-scope').classList.contains('active'),
        'THE SCOPE RE-LIT: the panel claims a component the server did not fit');
    assert.ok(panel.node('attachment-pistol-grip').classList.contains('active'),
        'the grip the server DID fit was shown as off');
});

test('DEFECT: and the next save still carries the choice, rather than dropping it', () => {
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');
    panel.fire('attachment-pistol-scope', 'click');
    panel.fire('loadout-save', 'click');
    panel.send('state', confirmed(snap, ['grip']));

    /* Change something unrelated -- drop the grip and take it back is the
       cheapest way to make the draft dirty again without touching the scope.
       Then save, and the scope must still be absent from the wire. */
    panel.fire('attachment-pistol-grip', 'click');
    panel.fire('attachment-pistol-grip', 'click');
    panel.fire('loadout-save', 'click');

    const saves = panel.posted.filter(function (p) { return p.name === 'setLoadout'; });
    assert.strictEqual(saves.length, 2, 'the second save never reached the wire');

    const sent = (saves[1].body.weapons[0] || {}).attachments;
    assert.ok(Array.isArray(sent),
        'THE SECOND SAVE OMITTED THE ATTACHMENTS KEY -- the server refits everything');
    assert.ok(sent.indexOf('scope') < 0,
        'the scope came back on the second save: ' + sent.join(','));
});

test('a server that sends no kinds back leaves the default set alone', () => {
    /* An older server, or a loadout saved before attachments existed. Absent
       must still mean "fit what this server fits by default". */
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);
    const next = JSON.parse(JSON.stringify(snap));
    next.player.loadout = {
        weapons: [{ key: 'pistol', weapon: 'WEAPON_PISTOL', label: 'Pistol', ammo: 60 }],
        armor: 100, health: 200, supplies: [],
    };
    panel.send('state', next);
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(panel.node('attachment-pistol-scope').classList.contains('active'),
        'a server that said nothing had its silence read as "fit nothing"');
});

test('and an EMPTY list from the server means exactly that: none of them', () => {
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);
    panel.send('state', confirmed(snap, []));

    assert.ok(!panel.node('attachment-pistol-scope').classList.contains('active'),
        'a player who took everything off was handed the scope back');
    assert.ok(!panel.node('attachment-pistol-grip').classList.contains('active'),
        'a player who took everything off was handed the grip back');
});

// ------------------------------------------------------------------
// A DRAFT YOU CAN NO LONGER SAVE IS NOT A DRAFT
// ------------------------------------------------------------------

test('DEFECT: an unsaved pick is dropped once the loadout locks', () => {
    /* seedDraft holds the reseed off while the draft is dirty, so a
       broadcast cannot wipe out what somebody is choosing. Right in a lobby;
       wrong the moment the round leaves one. The save row is hidden when the
       loadout locks and that row holds the ONLY "Unsaved" warning -- so the
       warning vanished at the countdown while the unsaved pick stayed on
       screen under "what you are carrying is locked in". The server had
       never been sent it, and the player walked in a weapon short. */
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);

    // pick it and do NOT save
    panel.fire('weapon-card-pistol', 'click');
    assert.ok(/Pistol/.test(panel.text('loadout-slots')),
        'the pick never reached the draft at all');

    // the round leaves the lobby, and the server still holds nothing
    const started = JSON.parse(JSON.stringify(snap));
    started.matches[0].state = 'countdown';
    started.player.loadout = { weapons: [], armor: 100, health: 200, supplies: [] };
    panel.send('state', started);

    assert.ok(!/Pistol/.test(panel.text('loadout-slots')),
        'A LOCKED LOADOUT STILL SHOWED A WEAPON THE SERVER WAS NEVER SENT: '
        + panel.text('loadout-slots'));
});

test('and inside a lobby an unsaved pick is still protected from a broadcast', () => {
    /* The other half, and the reason the guard exists. */
    const snap = snapshot(false, {
        attachments: [{ key: 'scope', label: 'Scope' }, { key: 'grip', label: 'Grip' }],
    });
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');

    panel.send('state', JSON.parse(JSON.stringify(snap)));   // still a lobby

    assert.ok(/Pistol/.test(panel.text('loadout-slots')),
        'a broadcast wiped out a pick the player was still making');
});

/*
    WHEN THE OPERATOR FITS THEM INSTEAD.

    Config.Loadouts.attachments.allowChoose ships true -- everything above is
    what a player gets. Turned off, the server fits every kind it allows and
    the panel must draw the switches READ-ONLY rather than hiding them: a
    player still wants to see what is on the gun, they just do not get to
    change it.

    The server is what enforces the rule (Arena.AttachmentsFor drops the
    choice). These are about not offering a control that would do nothing.
*/

const FITTED = { loadouts: { chooseAttachments: false } };

/** A weapon that takes a scope and a grip. */
const ARMED = { attachments: [{ key: 'scope', label: 'Scope' },
                              { key: 'grip', label: 'Grip' }] };

test('operator-fitted: the chips are still drawn, so you can see the gun', () => {
    const panel = opened(snapshot(false, ARMED, FITTED));
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(panel.built('attachment-pistol-scope'),
        'the attachments row vanished, so nobody can see what is on the gun');
    assert.ok(panel.node('attachment-pistol-scope').classList.contains('active'),
        'the scope the server fits was drawn as if it were off');
});

test('...but they cannot be pressed', () => {
    const panel = opened(snapshot(false, ARMED, FITTED));
    panel.fire('weapon-card-pistol', 'click');

    assert.strictEqual(panel.node('attachment-pistol-scope').disabled, true,
        'a player was offered a switch that the server would ignore');
    assert.strictEqual(panel.node('attachment-pistol-grip').disabled, true);
});

test('and the screen says why, rather than leaving dead buttons', () => {
    const panel = opened(snapshot(false, ARMED, FITTED));
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(/come with the gun/i.test(panel.text('weapon-card-pistol')),
        'nothing on screen explains why the switches will not move: '
        + panel.text('weapon-card-pistol').slice(0, 200));
});

test('CONTROL: with the switch ON they are live, as before', () => {
    const panel = opened(snapshot(false, ARMED));
    panel.fire('weapon-card-pistol', 'click');

    assert.strictEqual(panel.node('attachment-pistol-scope').disabled, false,
        'the picker is dead even with the setting on');
    assert.ok(!/come with the gun/i.test(panel.text('weapon-card-pistol')),
        'a picking server was told its attachments are fitted for it');
});

test('and a saved half-fitted pick is redrawn as the FULL fitted set', () => {
    /* THE ONE THAT ONLY BITES ON A CHANGE OF MIND. A player picks a scope and
       nothing else while the picker is on; the operator then turns it off.
       The server now fits the lot -- and without this the screen would keep
       showing yesterday's single tick over a gun carrying everything, which
       is the one thing this row exists to report.

       Caught by mutation: the guard could be deleted with every other test
       here still green, because they all start from a fresh pick. */
    const saved = confirmed(snapshot(false, ARMED), ['scope']);
    saved.config.loadouts.chooseAttachments = false;

    const panel = opened(saved);
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(panel.node('attachment-pistol-scope').classList.contains('active'),
        'the scope the server fits was drawn as off');
    assert.ok(panel.node('attachment-pistol-grip').classList.contains('active'),
        'A SAVED TICK WAS SHOWN OVER A GUN THE SERVER NOW FITS IN FULL');
});

test('CONTROL: with the picker ON, a saved half-fitted pick is redrawn as saved', () => {
    /* The other direction, and the reason the guard is conditional. A player
       who took the grip off must find it still off when they come back. */
    const saved = confirmed(snapshot(false, ARMED), ['scope']);

    const panel = opened(saved);
    panel.fire('weapon-card-pistol', 'click');

    assert.ok(panel.node('attachment-pistol-scope').classList.contains('active'),
        'the scope they kept came back off');
    assert.ok(!panel.node('attachment-pistol-grip').classList.contains('active'),
        'the grip they took off came back fitted');
});

test('and a server that sends no flag at all keeps its picker', () => {
    /* Read as `=== false`, like every other flag on this wire: a snapshot
       assembled before this setting existed must not lose the feature. */
    const snap = snapshot(false, ARMED);
    delete snap.config.loadouts.chooseAttachments;
    const panel = opened(snap);
    panel.fire('weapon-card-pistol', 'click');

    assert.strictEqual(panel.node('attachment-pistol-scope').disabled, false,
        'an older server lost its attachment picker');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
