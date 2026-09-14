/*
    crimson_arena/tests/panel/payload.test.js

    What the panel actually PUTS ON THE WIRE.

    The bug these were written for: Config.Match.lives let a host pick, the
    input appeared, typing in it did something -- and every match was still
    created with one life, because the state key behind the box was never
    declared and the guard that seeds it from config compared `undefined`
    against `null`. Nothing about the source read wrong. Only the payload did.
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

/** A snapshot shaped exactly like server/lobby.lua's config block. */
function snapshot(overrides) {
    const config = {
        arenas: [{ key: 'airfield', label: 'Airfield', enabled: true }],
        modes: [{ key: 'ffa', label: 'Free For All', enabled: true }],
        match: {
            lives: 3,
            livesChoice: { min: 1, max: 10 },
            roundTimeSeconds: 600,
            roundTimeChoice: { min: 60, max: 3600 },
            minPlayers: 2,
            maxPlayers: 0,
            onlyHostCanStart: true,
        },
        betting: {
            enabled: false,
            entryFee: { enabled: false, min: 0, max: 0, default: 0 },
            spectatorBets: { enabled: false, min: 0, max: 0 },
        },
        loadouts: { allowChoose: true, chooser: 'host', weapons: [] },
        teams: { list: [] },
        ui: {},
    };
    Object.assign(config.match, (overrides || {}).match || {});
    return { config, player: {}, matches: [], leaderboard: [] };
}

/**
 * A panel in the state a player actually sees it in.
 *
 * The `open` matters: the create form is only rendered once the panel is
 * open, so a test that sends a snapshot and nothing else is testing a screen
 * nobody is looking at.
 */
function opened(snap) {
    const panel = loadPanel(ROOT);
    panel.send('open', snap || snapshot());
    panel.send('state', snap || snapshot());
    return panel;
}

console.log('==> what the create form posts');

test('the lives box starts on the operator default, not on a fallback', () => {
    const panel = opened();
    assert.strictEqual(panel.node('create-lives').value, '3',
        'the box shows ' + JSON.stringify(panel.node('create-lives').value)
        + ' -- the state key behind it was never seeded from config');
});

test('typing a number is what gets created', () => {
    const panel = opened();
    panel.type('create-lives', '7');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.ok(sent, 'nothing was posted at all');
    assert.strictEqual(sent.body.lives, 7,
        'typed 7, posted ' + sent.body.lives + ' -- this is the bug in one line');
});

test('and the value survives a server broadcast landing mid-edit', () => {
    // Every push re-renders. A render that writes state back into the input
    // is correct; one that re-seeds state from config is not, and would
    // silently undo what the host typed a moment earlier.
    const panel = opened();
    panel.type('create-lives', '9');
    panel.send('state', snapshot());
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.lives, 9, 'a broadcast reset the host\'s choice');
});

test('the arena and mode reach the wire too, not just the lives', () => {
    const panel = opened();
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.arenaKey, 'airfield');
    assert.strictEqual(sent.body.modeKey, 'ffa');
});

test('a fixed-lives server offers no box and still posts a usable number', () => {
    const snap = snapshot();
    delete snap.config.match.livesChoice;      // the operator fixed it
    snap.config.match.lives = 2;

    const panel = opened(snap);
    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.lives, 2,
        'a server that fixed the count had it overridden by the panel');
});

test('a snapshot carrying the operator\'s THEME still renders the page', () => {
    /* server/lobby.lua puts Config.UI on the wire verbatim, and config.lua's
       `ui.theme` is a table of CSS variables -- so applyTheme writes to
       document.documentElement.style on the first `state` push of any
       genuine ArenaLobby.BuildState payload.

       The harness had no documentElement, so that threw -- and the throw was
       swallowed by the panel's own guarded() wrapper. The page rendered
       NOTHING: empty picker, empty roster, empty title, buttons at their
       defaults. Every suite here drove hand-written payloads with no theme
       on them and never noticed; one driven by a real payload would have
       measured a blank screen and reported a finding about whatever it was
       looking at. */
    const panel = loadPanel(ROOT);
    const snap = snapshot();
    snap.config.ui = {
        title: 'CRIMSON',
        subtitle: 'ROLEPLAY ARENA',
        theme: { accent: '#c81020', accentBright: '#ff2038', surface: '#12100f' },
    };
    panel.send('open', snap);
    panel.send('state', snap);

    assert.ok(/Airfield/.test(panel.text('create-arena') + panel.text('matches')),
        'the page rendered nothing at all with a theme on the wire: '
            + JSON.stringify(panel.text('matches')));
});

test('Round Length opens on the number the server says it will run', () => {
    /* IN MINUTES. The server sends 600 and the box shows 10, because a host
       setting a round length thinks "give it ten" and nothing on the screen
       ever said which unit the box wanted. The one that matters is still
       seconds and still goes out as seconds -- see the post below. */
    const panel = opened();
    assert.ok(!panel.node('create-round-row').classList.contains('hidden'),
        'the row is hidden on a server that offers the choice');
    assert.strictEqual(panel.node('create-round').value, '10',
        'the box shows ' + JSON.stringify(panel.node('create-round').value)
        + ' -- 600 seconds is ten minutes');
    assert.ok(/minute/i.test(panel.text('create-round-hint')),
        'the hint has to name the unit, or the number means nothing: '
        + panel.text('create-round-hint'));
    assert.ok(/10:00/.test(panel.text('create-round-hint')),
        'and quote the clock it works out to: ' + panel.text('create-round-hint'));
    assert.ok(!/in seconds/i.test(panel.text('create-round-hint')),
        'the hint still says seconds over a box counting minutes: '
        + panel.text('create-round-hint'));
});

test('and the length typed is the length created', () => {
    /* THE WHOLE POINT OF THE CONTROL. Gun game is decided by its clock, so
       until this existed the one rule the mode is built around was the one
       rule a host could not set without editing config.lua and restarting.

       FIFTEEN IN THE BOX, NINE HUNDRED ON THE WIRE. The conversion is the
       thing under test: a host typing 15 who got a fifteen SECOND round
       would be the same defect the unit change was made to fix. */
    const panel = opened();
    panel.type('create-round', '15');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.ok(sent, 'nothing was posted at all');
    assert.strictEqual(sent.body.roundTimeSeconds, 900,
        'typed 15 minutes, posted ' + sent.body.roundTimeSeconds + ' seconds');
});

test('and the hint follows the box as it is typed into', () => {
    const panel = opened();
    panel.type('create-round', '5');
    assert.ok(/5:00/.test(panel.text('create-round-hint')),
        'the clock beside the box still reads the old value: '
        + panel.text('create-round-hint'));
});

test('the box counts in ones, not in the thirties it counted seconds in', () => {
    /* step="30" was right for a box holding seconds and is nonsense for one
       holding minutes: the arrows would jump half an hour, and a typed 11
       fails the browser's own step check against a min of 1. */
    const panel = opened();
    assert.strictEqual(panel.node('create-round').step, '1',
        'the step is ' + JSON.stringify(panel.node('create-round').step));
    assert.strictEqual(panel.node('create-round').min, '1',
        'the floor is ' + JSON.stringify(panel.node('create-round').min)
        + ' -- 60 seconds is one minute');
    assert.strictEqual(panel.node('create-round').max, '60',
        'the ceiling is ' + JSON.stringify(panel.node('create-round').max)
        + ' -- 3600 seconds is sixty minutes');
});

test('a band is rounded INWARDS, so every minute offered is one the server takes', () => {
    /* 90 to 200 seconds is 1.5 to 3.33 minutes. Offering 1 would be offering
       90 seconds' worth of a round the server refuses at 60, and offering 4
       would be offering 240 against a ceiling of 200. Two and three are the
       only honest answers. */
    const snap = snapshot();
    snap.config.match.roundTimeChoice = { min: 90, max: 200 };
    snap.config.match.roundTimeSeconds = 120;
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('create-round').min, '2',
        'the floor is ' + JSON.stringify(panel.node('create-round').min));
    assert.strictEqual(panel.node('create-round').max, '3',
        'the ceiling is ' + JSON.stringify(panel.node('create-round').max));
});

test('and a band with no whole minute in it stays in seconds and says so', () => {
    /* An operator is allowed to write 30 to 50. There is no whole minute in
       that, and an empty minutes box would be worse than an honest one in
       the smaller unit. */
    const snap = snapshot();
    snap.config.match.roundTimeChoice = { min: 30, max: 50 };
    snap.config.match.roundTimeSeconds = 45;
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('create-round').value, '45',
        'the box shows ' + JSON.stringify(panel.node('create-round').value));
    assert.ok(/in seconds/i.test(panel.text('create-round-hint')),
        'and the hint has to say which unit that 45 is: '
        + panel.text('create-round-hint'));

    panel.type('create-round', '50');
    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.roundTimeSeconds, 50,
        'typed 50 seconds, posted ' + sent.body.roundTimeSeconds);
});

test('a default that is not a whole minute is snapped, so the box never lies', () => {
    /* 450 seconds is seven and a half minutes and the box can only show 7 or
       8. Left alone, a host reading 8 would create a 450-second round. The
       state is moved to the box's answer instead, once, on the way in. */
    const snap = snapshot();
    snap.config.match.roundTimeSeconds = 450;
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);

    assert.strictEqual(panel.node('create-round').value, '8',
        'the box shows ' + JSON.stringify(panel.node('create-round').value));

    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.roundTimeSeconds, 480,
        'the box said 8 minutes and the wire said ' + sent.body.roundTimeSeconds
        + ' seconds -- they have to agree without the host touching anything');
});

test('and typing past the ceiling is held at the ceiling, in minutes', () => {
    const panel = opened();
    panel.type('create-round', '9999');
    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.roundTimeSeconds, 3600,
        'typed 9999 minutes against a 3600 second ceiling, posted '
        + sent.body.roundTimeSeconds);
});

test('and a server that fixes the length offers no control at all', () => {
    /* A control that cannot change anything is worse than no control,
       because it invites a host to try. The server sends no range when the
       operator has written a plain number. */
    const snap = snapshot();
    delete snap.config.match.roundTimeChoice;
    const panel = loadPanel(ROOT);
    panel.send('open', snap);
    panel.send('state', snap);

    assert.ok(panel.node('create-round-row').classList.contains('hidden'),
        'a fixed round length still drew a box the host can type into');
    assert.strictEqual(panel.text('create-round-hint'), '',
        'and left a hint under it: ' + panel.text('create-round-hint'));
});

/*
    THE MODE'S OWN CLOCK.

    THE DEFECT. The round-length box was seeded once, from
    Config.Match.roundTimeSeconds -- the GLOBAL default -- and never looked
    again. The panel posts that number on every create, and the server reads
    any in-range value as a deliberate choice by the host, so it SHADOWED the
    mode's own clock. Gun game ships a designed 480-second ladder and every
    gun game ever created from this panel ran 600; an operator who shortened
    it to 120 still got 600. Config.Modes.gungame.roundTimeSeconds was
    unreachable through the only path a player can create a match by.

    The mode carries its own resolved number on the wire already -- server
    side Arena.RoundSecondsFor does the resolution -- so the fix is for the
    box to follow the mode until the host takes it over.
*/

/** A snapshot whose second mode runs a shorter clock of its own. */
function withGunGame(matchOverrides) {
    const snap = snapshot(matchOverrides ? { match: matchOverrides } : undefined);
    snap.config.modes = [
        { key: 'ffa', label: 'Free For All', enabled: true, roundTimeSeconds: 600 },
        { key: 'gungame', label: 'Gun Game', enabled: true, roundTimeSeconds: 480 },
    ];
    return snap;
}

test('THE DEFECT: picking a mode with its own clock moves the box to it', () => {
    const panel = opened(withGunGame());
    assert.strictEqual(panel.node('create-round').value, '10',
        'free-for-all should open on the global 600 seconds');

    panel.pick('create-mode', 'gungame');
    assert.strictEqual(panel.node('create-round').value, '8',
        'the box shows ' + JSON.stringify(panel.node('create-round').value)
        + ' minutes -- gun game runs 480 seconds and the box still says 600');
});

test('and the mode\'s clock is what reaches the wire, not the global default', () => {
    const panel = opened(withGunGame());
    panel.pick('create-mode', 'gungame');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.ok(sent, 'nothing was posted at all');
    assert.strictEqual(sent.body.roundTimeSeconds, 480,
        'posted ' + sent.body.roundTimeSeconds + ' -- the mode\'s own 480 was overridden');
});

test('and an operator who SHORTENS a mode gets the short mode', () => {
    /* The sharper version of the same defect: a setting the operator changed
       on purpose was unreachable, five times over. */
    const snap = withGunGame();
    snap.config.modes[1].roundTimeSeconds = 120;
    const panel = opened(snap);
    panel.pick('create-mode', 'gungame');
    panel.fire('create-submit', 'click');

    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.roundTimeSeconds, 120,
        'posted ' + sent.body.roundTimeSeconds + ' against an operator setting of 120');
});

test('but a length the host TYPED survives a mode change', () => {
    /* The other half. Following the mode must not throw away a number the
       host set on purpose -- that would be a box that will not hold a value. */
    const panel = opened(withGunGame());
    panel.type('create-round', '3');
    panel.pick('create-mode', 'gungame');

    assert.strictEqual(panel.node('create-round').value, '3',
        'the box shows ' + JSON.stringify(panel.node('create-round').value)
        + ' -- a mode change overwrote a length the host typed');

    panel.fire('create-submit', 'click');
    const sent = panel.posted.find((p) => p.name === 'createMatch');
    assert.strictEqual(sent.body.roundTimeSeconds, 180,
        'posted ' + sent.body.roundTimeSeconds + ' rather than the typed three minutes');
});

test('and a mode with no clock of its own falls back to the global one', () => {
    const snap = withGunGame();
    delete snap.config.modes[1].roundTimeSeconds;
    const panel = opened(snap);
    panel.pick('create-mode', 'gungame');

    assert.strictEqual(panel.node('create-round').value, '10',
        'a mode with no clock of its own should sit on the global default');
});

test('a mode clock outside the operator band is held inside it', () => {
    /* A mode may carry a number the host is not allowed to choose. The box
       must not offer one the create call then refuses. */
    const snap = withGunGame({ roundTimeChoice: { min: 60, max: 300 } });
    const panel = opened(snap);
    panel.pick('create-mode', 'gungame');

    assert.strictEqual(panel.node('create-round').value, '5',
        'the box shows ' + JSON.stringify(panel.node('create-round').value)
        + ' against a ceiling of 300 seconds');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + f.error.message));
    process.exit(1);
}
