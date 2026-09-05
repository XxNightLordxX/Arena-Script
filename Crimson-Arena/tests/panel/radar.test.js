/*
    crimson_arena/tests/panel/radar.test.js

    THE RADAR -- A MATCH SETTING THE HOST PICKS.

    Permanent blips on every fighter turn a round into a map to be read
    rather than a place to be searched, so they ship off. The radar is what
    replaced them: a SWEEP rather than a live feed.

    It used to be per player, toggled down in the lobby and never sent
    anywhere. That made a round only as dark as its least patient fighter --
    anyone who wanted enemies on their map switched them on for themselves,
    and the sweep interval the whole setting exists for was a formality.

    So it is the host's now, and it lives in the box that creates and edits
    a match. These assert the three things that move: it is drawn in the
    MATCHES tab and not the lobby, it is dead for anyone who is not hosting
    an open lobby, and the decision rides out on createMatch/updateMatch
    rather than on a post of its own.
*/

const assert = require('assert');
const fs = require('fs');
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

/* `host` is who the panel's own player is against this match: 'host' makes
   them its host and so the one person who may edit it, 'guest' puts them in
   it as an ordinary fighter, 'none' leaves them outside every match. */
function snapshot(radar, host) {
    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: 'ffa', modeLabel: 'FFA', state: 'lobby',
        playerCount: 1, hostName: 'John Allday', players: [], teams: [],
        radar: false,
    };
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [{ key: 'ffa', label: 'FFA', enabled: true }],
            match: { lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600, radar: radar },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: true, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        player: host === 'none'
            ? { matchId: null }
            : { matchId: 'm1', isHost: host === 'host' },
        matches: [match],
        leaderboard: [],
    };
}

function opened(radar, host) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(radar, host || 'host');
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

console.log('==> the radar, a host-set match rule');

test('the control lives in the MATCHES tab, not the lobby', () => {
    /* The point of the whole change. Asserted against the markup rather
       than the panel state because this is a question about where the
       element SITS, and app.js cannot answer it -- byId finds a node
       wherever it is. */
    const html = fs.readFileSync(path.join(ROOT, 'html', 'index.html'), 'utf8');

    const matches = html.indexOf('id="tab-matches"');
    const lobby = html.indexOf('id="tab-lobby"');
    const radar = html.indexOf('id="create-radar-row"');

    assert.ok(matches >= 0 && lobby > matches, 'the panel no longer has the two tabs this asserts about');
    assert.ok(radar >= 0, 'there is no radar row in the markup at all');
    assert.ok(radar > matches && radar < lobby,
        'the radar row is outside the matches tab -- it must sit with the other match rules');

    assert.strictEqual(html.indexOf('lobby-radar-row'), -1,
        'the old per-player lobby row is still in the markup');
});

test('no control at all where the operator has not allowed one', () => {
    // A dead control reads as a broken feature. Absent is honest.
    // Checked through the class this panel actually hides with, not the
    // `hidden` attribute: show() toggles a class and never touches the
    // attribute, so markup using the attribute would be hidden forever with
    // nothing able to reveal it. That was the first version of this row.
    const panel = opened(null);
    assert.ok(panel.node('create-radar-row').classList.contains('hidden'),
        'the radar row was shown on a server that allows no radar');
});

test('and a control where they have', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    assert.ok(!panel.node('create-radar-row').classList.contains('hidden'),
        'the radar row was hidden on a server that allows one');
});

test('a fresh form starts on the operator default, not on off', () => {
    const on = opened({ defaultOn: true, intervalSeconds: 30 }, 'none');
    assert.strictEqual(on.node('btn-radar').textContent, 'Radar On',
        'a server defaulting the radar ON opened with it reading Off');

    const off = opened({ defaultOn: false, intervalSeconds: 30 }, 'none');
    assert.strictEqual(off.node('btn-radar').textContent, 'Radar Off');
});

test('but a lobby already open shows ITS setting, not the default', () => {
    /* The form is that match's settings once you are hosting one, so it has
       to open showing what the match actually is. A host who set the radar
       off, walked away and came back to a control reading On -- because the
       server defaults it on -- would turn it on by pressing Apply. */
    const panel = loadPanel(ROOT);
    const snap = snapshot({ defaultOn: true, intervalSeconds: 30 }, 'host');
    snap.matches[0].radar = false;
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('btn-radar').textContent, 'Radar Off',
        'the form showed the server default over the match\'s own setting');

    // And the other way, so this is reading the match rather than hard-off.
    const other = loadPanel(ROOT);
    const lit = snapshot({ defaultOn: false, intervalSeconds: 30 }, 'host');
    lit.matches[0].radar = true;
    other.send('open', lit);
    other.send('state', lit);

    assert.strictEqual(other.node('btn-radar').textContent, 'Radar On',
        'a match with the radar on opened reading Off');
});

test('HOST ONLY -- a fighter who is not the host cannot touch it', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 }, 'guest');
    const button = panel.node('btn-radar');

    assert.strictEqual(button.disabled, true,
        'a non-host was offered a live radar toggle for somebody else\'s match');

    // And pressing it anyway changes nothing, so the guard is the handler's
    // and not merely the attribute's -- a disabled attribute is a hint to a
    // browser, not a permission check.
    button.onclick();
    assert.strictEqual(panel.node('btn-radar').textContent, 'Radar Off',
        'a non-host pressing the disabled toggle still flipped it');
});

test('pressing it posts NOTHING -- it is applied by Create/Apply', () => {
    /* Deliberate: the arena, the mode and the lives all wait for the button
       at the bottom of the form, and a radar that committed itself on click
       would be the one setting that behaved differently. */
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    panel.node('btn-radar').onclick();

    assert.strictEqual(panel.posted.length, 0,
        'the toggle posted on click: ' + JSON.stringify(panel.posted));
    assert.strictEqual(panel.node('btn-radar').textContent, 'Radar On',
        'the press did not flip the control');
});

test('Apply Changes carries the radar to the server', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    panel.node('btn-radar').onclick();
    panel.fire('create-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'updateMatch');
    assert.strictEqual(sent.length, 1, 'nothing was posted: ' + JSON.stringify(panel.posted));
    assert.strictEqual(sent[0].body.radar, true,
        'Apply Changes posted ' + JSON.stringify(sent[0].body));
});

test('Create Match carries it too, on a host who is in no match yet', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 }, 'none');
    panel.node('btn-radar').onclick();
    panel.fire('create-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'createMatch');
    assert.strictEqual(sent.length, 1, 'nothing was posted: ' + JSON.stringify(panel.posted));
    assert.strictEqual(sent[0].body.radar, true,
        'Create Match posted ' + JSON.stringify(sent[0].body));
});

test('an untouched toggle still sends what the button says', () => {
    /* The state key starts null so the operator's default applies. Sending
       that null straight out would mean a host who read "Radar On" and
       pressed Apply got a match with no radar in it -- the server reads a
       missing value as "leave it alone". */
    const panel = opened({ defaultOn: true, intervalSeconds: 30 }, 'none');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'createMatch');
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].body.radar, true,
        'an untouched default-on toggle posted ' + JSON.stringify(sent[0].body));
});

test('turning OFF a radar the operator defaulted ON is sent, not swallowed', () => {
    // The mirror of the above: a real `false`, not nothing, which is what a
    // naive falsy check on an untouched value would give.
    const panel = opened({ defaultOn: true, intervalSeconds: 30 }, 'none');
    panel.node('btn-radar').onclick();
    panel.fire('create-submit', 'click');

    const sent = panel.posted.filter((p) => p.name === 'createMatch');
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].body.radar, false,
        'switching off a defaulted-on radar posted ' + JSON.stringify(sent[0].body));
});

test('DEFECT: somebody else joining a lobby does not undo your radar choice', () => {
    /* The reset that forgets a match you have stopped editing ran on EVERY
       render, not on the transition -- and a render happens on every server
       broadcast, which is every join, ready, bet, match start and match end
       anywhere on the server.

       So a player sitting in the browser who pressed the toggle had their
       choice quietly put back to the operator default the moment anybody
       else did anything, and Create Match then posted the default they had
       just changed. Nothing on screen said so; the button simply went back. */
    const panel = opened({ defaultOn: false, intervalSeconds: 30 }, 'none');
    panel.node('btn-radar').onclick();

    const chosen = panel.node('btn-radar').textContent;
    assert.ok(/on/i.test(chosen), 'pressing the toggle did not turn it on: ' + chosen);

    /* Anybody else, anywhere on the server, doing anything at all. */
    panel.send('state', snapshot({ defaultOn: false, intervalSeconds: 30 }, 'none'));

    assert.strictEqual(panel.node('btn-radar').textContent, chosen,
        'a broadcast put the toggle back to ' + panel.node('btn-radar').textContent);

    panel.fire('create-submit', 'click');
    const sent = panel.posted.filter((p) => p.name === 'createMatch');
    assert.strictEqual(sent.length, 1);
    assert.strictEqual(sent[0].body.radar, true,
        'the match was created with the radar the player had turned off again: '
            + JSON.stringify(sent[0].body));
});

test('but leaving a match you were hosting DOES clear the form', () => {
    /* The other direction, and what that branch is actually for: the form
       must not carry one lobby's settings into a different match. */
    const panel = loadPanel(ROOT);
    const hosting = snapshot({ defaultOn: false, intervalSeconds: 30 }, 'host');
    hosting.matches[0].radar = true;
    panel.send('open', hosting);
    panel.send('state', hosting);

    assert.ok(/on/i.test(panel.node('btn-radar').textContent),
        'the form did not take the hosted match\'s radar setting');

    /* They leave it. */
    panel.send('state', snapshot({ defaultOn: false, intervalSeconds: 30 }, 'none'));

    assert.ok(/off/i.test(panel.node('btn-radar').textContent),
        'the form kept the old match\'s radar after leaving it: '
            + panel.node('btn-radar').textContent);
});

test('the hint says how often it sweeps, so the wait is expected', () => {
    const panel = opened({ defaultOn: false, intervalSeconds: 30 });
    assert.ok(/30 seconds/.test(panel.node('create-radar-hint').textContent),
        'the control does not say how long the gap is: ' + panel.node('create-radar-hint').textContent);
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
