/*
    crimson_arena/tests/panel/tabvisibility.test.js

    A TAB THAT CANNOT DO ANYTHING IS STILL A QUESTION.

    Five tabs were drawn at all times. Bets sat there on a server with
    betting switched off, and Lobby sat there when the player was not in one
    -- and the panel already knew both, because joining a match moves you to
    Lobby and leaving moves you off it. Clicking either landed on a screen
    whose only content was a sentence explaining why it was empty.

    THE RISK IN TAKING THEM AWAY is taking away one that was needed, which
    is a worse fault than the clutter it fixes. So this file pins both
    directions: gone when the feature is off, and BACK the moment it is on.
*/

const assert = require('assert');
const fs = require('fs');
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

/** Whether the tab BUTTON is on the bar -- which is what was changed. */
function tabOnBar(panel, name) {
    /* inMarkup, NOT node(). node() conjures a handle for ANY id -- it has to,
       because the panel builds most of what it shows -- so `assert.ok(button)`
       was true whatever index.html said, and deleting this button from the
       markup left the whole suite and verify_contracts green. Nothing else
       reads these buttons out of the markup: verify_contracts only checks ids
       app.js looks up by LITERAL name, and these are reached as
       `byId('tab-btn-' + name)`, built at run time. */
    assert.ok(panel.inMarkup('tab-btn-' + name),
        'there is no ' + name + ' tab button in html/index.html at all');

    /* AND THE PANEL THE BUTTON OPENS. The line right after the button lookup
       is `show(byId('tab-' + name), ...)`, built the same way and just as
       invisible -- so guarding only the button left half the control
       unguarded, and a tab whose CONTENT had gone would still read as
       present. */
    assert.ok(panel.inMarkup('tab-' + name),
        'there is no ' + name + ' tab PANEL in html/index.html at all');

    const button = panel.node('tab-btn-' + name);
    return !button.classList.contains('hidden');
}

/**
 * The tab names the panel really iterates, read out of app.js rather than
 * typed here -- so a tab added to TABS and forgotten in the markup fails this
 * file instead of shipping a button that opens nothing.
 */
function tabNames() {
    const source = fs.readFileSync(path.join(ROOT, 'html', 'app.js'), 'utf8');
    const line = source.match(/var TABS = \[([^\]]+)\]/);
    assert.ok(line, 'app.js no longer declares TABS the way this test reads it');

    const names = line[1].split(',')
        .map(function (part) { return part.trim().replace(/^['"]|['"]$/g, ''); })
        .filter(function (part) { return part.length > 0; });

    assert.ok(names.length > 0, 'no tab names were read out of app.js at all');
    return names;
}

test('EVERY tab the panel iterates ships BOTH a button and a panel', () => {
    /* NEITHER IS CHECKED ANYWHERE ELSE. verify_contracts only validates ids
       app.js looks up by LITERAL name, and both of these are reached as
       `byId('tab-btn-' + name)` and `byId('tab-' + name)` -- built at run
       time. The harness invents a node for any id asked of it, so every
       assertion through node() was true whatever the markup said.

       READ FROM app.js, not typed here, so adding a tab and forgetting the
       markup fails this rather than shipping a dead button. */
    const panel = loadPanel(ROOT);

    tabNames().forEach(function (name) {
        assert.ok(panel.inMarkup('tab-btn-' + name),
            'app.js iterates the "' + name + '" tab but html/index.html has no '
            + 'tab-btn-' + name + ' button');
        assert.ok(panel.inMarkup('tab-' + name),
            'app.js iterates the "' + name + '" tab but html/index.html has no '
            + 'tab-' + name + ' panel for it to open');
    });
});

test('Bets is gone when the server has betting switched off', () => {
    const snap = snapshot(false);
    snap.config.betting.enabled = false;
    const panel = opened(snap);

    assert.ok(!tabOnBar(panel, 'bets'),
        'the Bets tab was left on the bar with betting switched off');
});

test('and it comes BACK when betting is on', () => {
    const snap = snapshot(false);
    snap.config.betting.enabled = true;
    const panel = opened(snap);

    assert.ok(tabOnBar(panel, 'bets'),
        'betting is on and the Bets tab is still missing from the bar');
});

test('Lobby is gone when the player is in no match', () => {
    const snap = snapshot(false);
    /* The shared fixture puts the player IN a match, which is right for the
       loadout tests it was written for. Take them out of it. */
    snap.player = { serverId: 7 };
    snap.matches = [];
    const panel = opened(snap);

    assert.ok(!tabOnBar(panel, 'lobby'),
        'the Lobby tab was left on the bar for a player in no match');
});

test('NOTHING ELSE WENT WITH THEM: Matches, Loadout and Leaderboard survive', () => {
    /* The fault worth guarding against is over-reach -- hiding a tab that
       was doing its job. Loadout stays even where the host picks the guns,
       because a player still wants to see what they are handed, and an empty
       Leaderboard is a real answer to "who is winning". */
    const snap = snapshot(false);
    snap.config.betting.enabled = false;
    snap.player = { serverId: 7 };
    snap.matches = [];
    const panel = opened(snap);

    for (const name of ['matches', 'loadout', 'board']) {
        assert.ok(tabOnBar(panel, name),
            'the ' + name + ' tab was taken off the bar along with the other two');
    }
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length === 0 ? 0 : 1);
