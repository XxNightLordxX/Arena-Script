/*
    crimson_arena/tests/panel/wincondition.test.js

    HOW THE ROUND IS WON -- A HOST-SET MATCH RULE.

    Config.Match.winCondition takes two shapes, the same way `lives` and
    `roundTimeSeconds` already do: a plain string fixes it for the whole
    server, and a { allowChoose, default } block hands the decision to the
    host as a dropdown in the match-creation menu.

    THE ROW IS DRAWN FROM THE SNAPSHOT, NOT FROM CONFIG. `winConditionChoice`
    is absent on a server that fixes the rule, and absent is what hides the
    row -- a control that cannot change anything invites a host to try, and
    then to wonder why nothing happened. So "the operator did not turn this
    on" and "the panel is broken" look identical from a seat, and these are
    what tell them apart.

    AND A SCORE LIMIT SPENDS NO LIVES. That is not cosmetic: the round is
    meant to end when somebody reaches the number, and a roster that can be
    eliminated runs out of players first on any limit worth setting. The
    server stops spending lives under it, so the panel must stop offering the
    Lives Each box -- and say why, or a row vanishing reads as a bug.
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

/* `choice` is what the server sends as winConditionChoice: the list on a
   server that lets the host pick, absent on one that does not. */
function snapshot(choice, modeKey, seat) {
    const mode = modeKey || 'ffa';
    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: mode, modeLabel: 'Mode', state: 'lobby',
        playerCount: 1, hostName: 'John Allday', players: [], teams: [],
        /* THE RULE THE SERVER RESOLVED ONTO THIS MATCH. It is always on the
           wire (server/lobby.lua sends Arena.WinConditionFor), and the form
           seeds itself from it -- so a fixture without it made every seeding
           test fall back to whatever was already in `state`, which is the
           thing those tests are supposed to be measuring. */
        winCondition: 'last_standing',
        livesSpent: true,
    };
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [
                { key: 'ffa', label: 'FFA', enabled: true },
                /* A ladder mode, which is won by the ladder whatever this
                   says -- so the row must not be offered on it. */
                { key: 'gungame', label: 'Gun Game', enabled: true, tiers: 30 },
            ],
            match: {
                lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600,
                livesChoice: { min: 1, max: 10 },
                winCondition: 'last_standing',
                winConditionChoice: choice,
                scoreLimit: 25,
                scoreLimitChoice: { min: 1, max: 200 },
            },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: { allowChoose: true, chooser: 'player', weapons: [], armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [] },
            ui: {},
        },
        /* HOSTING AN OPEN LOBBY MAKES THE FORM AN EDIT, and the submit
           posts updateMatch rather than createMatch. Both doors carry the
           choice and both are worth asserting, so which seat the panel's own
           player is in is a parameter rather than a fixed fact. */
        player: seat === 'outside' ? { matchId: null } : { matchId: 'm1', isHost: true },
        matches: [match],
        leaderboard: [],
    };
}

const ALL = ['last_standing', 'most_kills', 'score_limit'];

function opened(choice, modeKey, seat) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(choice, modeKey, seat);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function hidden(panel, id) {
    return panel.node(id).classList.contains('hidden');
}

console.log('==> the win condition, a host-set match rule');

test('the row lives in the MATCHES tab, with the other match rules', () => {
    /* Asserted against the markup, because this is a question about where
       the element SITS and app.js cannot answer it -- byId finds a node
       wherever it is. */
    const html = fs.readFileSync(path.join(ROOT, 'html', 'index.html'), 'utf8');

    const matches = html.indexOf('id="tab-matches"');
    const lobby = html.indexOf('id="tab-lobby"');
    const win = html.indexOf('id="create-win-row"');

    assert.ok(matches >= 0 && lobby > matches, 'the panel no longer has the two tabs this asserts about');
    assert.ok(win >= 0, 'there is no win-condition row in the markup at all');
    assert.ok(win > matches && win < lobby,
        'the win-condition row is outside the matches tab -- it must sit with the other match rules');

    /* ABOVE LIVES EACH, because the answer here decides whether Lives Each
       is read at all. */
    assert.ok(win < html.indexOf('id="create-lives-row"'),
        'the win condition sits below Lives Each -- it decides whether that row applies');
});

test('THE REPORT: the dropdown is drawn when the server offers the choice', () => {
    /* "win condition did not have a dropdown menu". */
    const panel = opened(ALL);

    assert.ok(!hidden(panel, 'create-win-row'),
        'the win-condition row is hidden on a server that offers the choice');

    const select = panel.node('create-win');
    assert.strictEqual(select.children.length, ALL.length,
        'the dropdown was drawn with ' + select.children.length + ' options, not ' + ALL.length);

    const values = select.children.map(function (option) { return option.value; });
    assert.deepStrictEqual(values, ALL,
        'the dropdown does not offer the server\'s own list: ' + values.join(', '));
});

test('and every option is readable rather than a config key', () => {
    const panel = opened(ALL);
    const labels = panel.node('create-win').children.map(function (option) {
        return option.textContent;
    });
    labels.forEach(function (label) {
        assert.ok(!/_/.test(label), 'an option is printed as a raw key: ' + label);
        assert.ok(label.length > 0, 'an option has no text at all');
    });
});

test('no row at all where the operator has fixed the rule', () => {
    /* A dead control reads as a broken feature. Absent is honest. Checked
       through the class this panel actually hides with, not the `hidden`
       attribute: show() toggles a class and never touches the attribute. */
    const panel = opened(undefined);
    assert.ok(hidden(panel, 'create-win-row'),
        'a server that fixes the win condition was still offered a dropdown');
});

test('and none on a ladder mode, which is won by the ladder', () => {
    const panel = opened(ALL, 'gungame');
    assert.ok(hidden(panel, 'create-win-row'),
        'a gun game was offered a win condition it does not read');
});

test('picking a kill limit takes the Lives Each row away, and says why', () => {
    const panel = opened(ALL);
    assert.ok(!hidden(panel, 'create-lives-row'),
        'Lives Each was already hidden, so this proves nothing');

    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    assert.ok(hidden(panel, 'create-lives-row'),
        'a kill limit spends no lives, and the Lives Each box was still offered');

    /* SAID, NOT JUST HIDDEN. A row that disappears looks like a bug unless
       the reason goes in its place. */
    const note = panel.node('create-lives-note');
    assert.ok(!hidden(panel, 'create-lives-note'),
        'the row vanished with nothing in its place');
    assert.ok(/no lives|respawn/i.test(note.textContent),
        'the note does not explain where Lives Each went: ' + note.textContent);
});

test('and the hint names the limit rather than "the number on the server"', () => {
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    assert.ok(/25/.test(panel.node('create-win-hint').textContent),
        'the hint does not say what the kill limit actually is: '
            + panel.node('create-win-hint').textContent);
});

test('and choosing it back restores the lives box', () => {
    /* The other direction, which is where a one-way render breaks: the row
       is hidden on a change and never shown again. */
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');
    assert.ok(hidden(panel, 'create-lives-row'), 'the fixture did not hide it');

    panel.node('create-win').value = 'last_standing';
    panel.fire('create-win', 'change');

    assert.ok(!hidden(panel, 'create-lives-row'),
        'Lives Each never came back after the host changed their mind');
});

test('the choice rides out on createMatch', () => {
    /* OUTSIDE EVERY MATCH, which is the seat the form is a CREATE form in.
       Hosting an open lobby makes the same submit an edit. */
    const panel = opened(ALL, 'ffa', 'outside');
    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'createMatch'; });
    assert.strictEqual(posted.length, 1,
        'the create did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.winCondition, 'most_kills',
        'the host\'s win condition was dropped on the way out: '
            + JSON.stringify(posted[0].body.winCondition));
});

test('and on updateMatch, so a host can change it while the lobby is open', () => {
    /* THE OTHER DOOR. The fee is frozen once a lobby is open and deliberately
       not sent; the win condition is not, because nobody has staked anything
       on it and the host is the only person who can change it. */
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'updateMatch'; });
    assert.strictEqual(posted.length, 1,
        'the edit did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.winCondition, 'score_limit',
        'the edit dropped the win condition: ' + JSON.stringify(posted[0].body.winCondition));
});

test('THE KILL LIMIT IS THE HOST\'S TOO, and only where they play to one', () => {
    /* "on the win condition kill limit, ability to name the kill limit".
       Under every other condition the number is not read, so a box for it
       would be a control that changes nothing. */
    const panel = opened(ALL);
    assert.ok(hidden(panel, 'create-limit-row'),
        'the kill limit was offered under a condition that never reads it');

    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    assert.ok(!hidden(panel, 'create-limit-row'),
        'the host chose a kill limit and was given no way to name it');
    assert.strictEqual(panel.node('create-limit').value, '25',
        'the box did not open on the number the server sent');
});

test('and the band it may be named within comes from the server', () => {
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    assert.strictEqual(panel.node('create-limit').min, '1');
    assert.strictEqual(panel.node('create-limit').max, '200');
    assert.ok(/1 to 200/.test(panel.node('create-limit-hint').textContent),
        'the hint does not say what a host may type: '
            + panel.node('create-limit-hint').textContent);
});

test('and the sentence above it quotes the number the host typed', () => {
    /* Not the server default. A hint that keeps saying 25 while the box
       reads 60 is the panel contradicting itself on one screen. */
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    panel.node('create-limit').value = '60';
    panel.fire('create-limit', 'input');

    assert.ok(/First to 60/.test(panel.node('create-win-hint').textContent),
        'the win-condition hint still quotes the server default: '
            + panel.node('create-win-hint').textContent);
});

test('and it rides out with the match', () => {
    const panel = opened(ALL, 'ffa', 'outside');
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');
    panel.node('create-limit').value = '40';
    panel.fire('create-limit', 'input');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'createMatch'; });
    assert.strictEqual(posted.length, 1,
        'the create did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.scoreLimit, 40,
        'the kill limit the host named was dropped on the way out: '
            + JSON.stringify(posted[0].body.scoreLimit));
});

test('and it rides out on updateMatch too, so a host can move the line', () => {
    /* THE OTHER DOOR. A host who opens a lobby and then decides 40 is too
       many has to be able to say so, and the edit is the only place left to
       say it -- the create form has become that lobby's settings. */
    const panel = opened(ALL);
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');
    panel.node('create-limit').value = '15';
    panel.fire('create-limit', 'input');

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) { return row.name === 'updateMatch'; });
    assert.strictEqual(posted.length, 1,
        'the edit did not post at all: ' + JSON.stringify(panel.posted));
    assert.strictEqual(posted[0].body.scoreLimit, 15,
        'the edit dropped the kill limit: ' + JSON.stringify(posted[0].body.scoreLimit));
});

test('and no box at all where the operator has fixed the number', () => {
    const panel = loadPanel(ROOT);
    const snap = snapshot(ALL);
    delete snap.config.match.scoreLimitChoice;
    panel.send('open', snap);
    panel.send('state', snap);

    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    assert.ok(hidden(panel, 'create-limit-row'),
        'a server that fixes the kill limit still offered a box for it');
});

test('THE REPORT: most kills takes the Lives Each row away too', () => {
    /* "on win condition it should not have a lives for most kills till the
       clock runs out". The rule is decided when the clock stops, so
       eliminating people ends the round before the count is ever read --
       the server spends no lives under it, and the panel must not offer a
       box for the ones it does not spend. */
    const panel = opened(ALL);
    assert.ok(!hidden(panel, 'create-lives-row'),
        'Lives Each was already hidden, so this proves nothing');

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    assert.ok(hidden(panel, 'create-lives-row'),
        'most kills spends no lives, and the Lives Each box was still offered');
});

test('and says the clock is what ends it, not a kill limit', () => {
    /* The note where the row was. A host told "everyone respawns until
       somebody reaches it" would go looking for a finish line this round
       does not have. */
    const panel = opened(ALL);

    /* BRACKETED, because `hidden()` alone cannot see this. The harness
       creates nodes on demand and never parses index.html, so a note the
       panel has not touched reports "not hidden" -- and deleting the
       show() that reveals it left this test passing. Asserting it is
       hidden on the last-standing baseline FIRST is what makes the reveal
       observable. */
    assert.ok(hidden(panel, 'create-lives-note'),
        'the note is on screen under a rule that spends lives, so its reveal proves nothing');

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    const note = panel.node('create-lives-note');
    assert.ok(!hidden(panel, 'create-lives-note'),
        'the row vanished with nothing in its place');
    assert.ok(/clock/i.test(note.textContent),
        'the note does not say the clock ends it: ' + note.textContent);
    assert.ok(!/reaches it/i.test(note.textContent),
        'the note describes a kill limit under a condition with none: ' + note.textContent);
});

test('and the hint says lives are not spent, before the choice is made', () => {
    const panel = opened(ALL);
    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    assert.ok(/lives are not spent/i.test(panel.node('create-win-hint').textContent),
        'the hint does not warn that lives go with this choice: '
            + panel.node('create-win-hint').textContent);
});

test('and it does NOT bring the kill-limit box with it', () => {
    /* The two questions were one while a score limit was the only condition
       without lives. Reading "spends no lives" to mean "plays to a limit"
       would put a finish line on a round that ends on a clock. */
    const panel = opened(ALL);
    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    assert.ok(hidden(panel, 'create-limit-row'),
        'a round decided by the clock was offered a kill limit to play to');
});

test('and Lives Each comes back when the host changes their mind', () => {
    const panel = opened(ALL);
    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');
    assert.ok(hidden(panel, 'create-lives-row'), 'the fixture did not hide it');

    panel.node('create-win').value = 'last_standing';
    panel.fire('create-win', 'change');

    assert.ok(!hidden(panel, 'create-lives-row'),
        'Lives Each never came back after the host changed their mind');
    assert.ok(hidden(panel, 'create-lives-note'),
        'the note explaining a missing row outlived the row going missing');
});

test('and it is not offered at all where no round clock exists to run out', () => {
    /* THE PANEL MUST NOT OFFER WHAT THE SERVER REFUSES. With the round
       length fixed at 0 the server turns a most-kills match down at
       creation -- and the refusal says "set a round length", pointing at a
       box the panel is not drawing, because there is no round length to
       set. */
    const panel = loadPanel(ROOT);
    const snap = snapshot(ALL);
    snap.config.match.roundTimeSeconds = 0;
    delete snap.config.match.roundTimeChoice;
    panel.send('open', snap);
    panel.send('state', snap);

    const values = panel.node('create-win').children.map(function (option) {
        return option.value;
    });
    assert.ok(values.indexOf('most_kills') === -1,
        'a round that can only end on a clock was offered on a server with none: '
            + values.join(', '));
    /* The other two are unaffected -- one ends on eliminations, the other on
       a count somebody eventually reaches. */
    assert.deepStrictEqual(values, ['last_standing', 'score_limit'],
        'dropping most kills took something else with it: ' + values.join(', '));
});

test('and the host is not left holding it after the option goes', () => {
    /* They can pick it while a clock exists and then lose the clock. Left
       alone, the form would go on posting a condition the dropdown no longer
       shows and the server always refuses. */
    const panel = loadPanel(ROOT);
    const withClock = snapshot(ALL);
    panel.send('open', withClock);
    panel.send('state', withClock);

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    const noClock = snapshot(ALL);
    noClock.config.match.roundTimeSeconds = 0;
    delete noClock.config.match.roundTimeChoice;
    panel.send('state', noClock);

    panel.fire('create-submit', 'click');

    const posted = panel.posted.filter(function (row) {
        return row.name === 'createMatch' || row.name === 'updateMatch';
    });
    assert.strictEqual(posted.length, 1, 'the submit did not post at all');
    assert.notStrictEqual(posted[0].body.winCondition, 'most_kills',
        'the form still posted a condition the server would refuse');
});

test('and a server WITH a clock still offers all three, which is the control', () => {
    const panel = opened(ALL);
    const values = panel.node('create-win').children.map(function (option) {
        return option.value;
    });
    assert.deepStrictEqual(values, ALL,
        'most kills was dropped on a server that has a clock: ' + values.join(', '));
});

test('THE DRAFT THAT OUTLIVED ITS REFUSAL: a turned-down edit puts the form back', () => {
    /* The create/edit form is the second control on this panel holding a
       DRAFT -- values that live in the browser until the server agrees. It
       seeds once per lobby id, deliberately, so a broadcast in the middle of
       somebody typing does not overwrite them. A REFUSAL is the one moment
       that has to seed again: without it the form goes on saying "most
       kills" over a lobby still fought as "last standing", with the card
       beside it disagreeing and nothing saying which is real. */
    const panel = opened(ALL);

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');
    assert.strictEqual(panel.node('create-win').value, 'most_kills',
        'the host could not choose it at all, so this proves nothing');

    /* The server turns it down and pushes the state back. Same lobby, only
       the refusal count has moved.

       THE LOBBY IS FOUGHT AS `score_limit`, deliberately a THIRD value. The
       fixture's default and the dropdown's first option are both
       `last_standing`, so a form that simply reset to its default would look
       identical to one that re-seeded from the match -- and the test would
       pass on a panel that had stopped reading `editable.winCondition` at
       all. Only the match's own rule can produce this answer. */
    const refused = snapshot(ALL);
    refused.matches[0].winCondition = 'score_limit';
    refused.player.editRefused = 1;
    panel.send('state', refused);

    assert.strictEqual(panel.node('create-win').value, 'score_limit',
        'the form did not seed from the rule the lobby is actually fought under');
});

test('and again on the SECOND refusal, which a flag would not manage', () => {
    /* A count rather than a flag, and this is the difference. A boolean that
       is already true says nothing when it is set again -- so the host's
       second rejected edit would sit on screen for the life of the lobby. */
    const panel = opened(ALL);

    const first = snapshot(ALL);
    first.matches[0].winCondition = 'score_limit';
    first.player.editRefused = 1;
    panel.send('state', first);
    assert.strictEqual(panel.node('create-win').value, 'score_limit',
        'the first refusal did not re-seed, so this proves nothing');

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    const second = snapshot(ALL);
    second.matches[0].winCondition = 'score_limit';
    second.player.editRefused = 2;
    panel.send('state', second);

    assert.strictEqual(panel.node('create-win').value, 'score_limit',
        'the second refusal left the form holding the rule the server turned down');
});

test('and an ordinary broadcast still does NOT overwrite the host mid-edit', () => {
    /* The control, and the reason the seeding is keyed at all: a render
       happens on every join, ready, bet and match start anywhere on the
       server. A form that re-seeded on those would reset the host's typing
       whenever anybody else did anything. */
    const panel = opened(ALL);

    panel.node('create-win').value = 'most_kills';
    panel.fire('create-win', 'change');

    panel.send('state', snapshot(ALL));

    assert.strictEqual(panel.node('create-win').value, 'most_kills',
        'an unrelated broadcast reset the host\'s choice');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
