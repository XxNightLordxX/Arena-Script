/*
    crimson_arena/tests/panel/teamwin.test.js

    THE WIN CONDITIONS, SAID IN TEAM WORDS.

    "team deathmatch should be last team standing, first team to kill limit,
    team with most kills."

    NOTHING ABOUT THE ROUND CHANGES HERE, and that is worth being clear about
    before reading the assertions. server/match.lua has always scored a team
    mode by SIDE: `reachedScoreLimit` sums each side's kills, `decideOnKills`
    compares sides and crowns the whole winning one, and the last-standing
    branch counts how many SIDES still have anybody on their feet. All three
    of the shipped win conditions were already team rules in a team mode.

    WHAT CHANGES IS WHETHER A HOST CAN TELL. The dropdown said "last one
    standing" in a 4v4, which is not what happens and reads as though it is:
    it sounds like a rule about the last PLAYER alive, when in fact a side is
    out when its last member is and the other side takes it with three of them
    still standing. A host reading that picks a rule they did not mean.

    THE SAME THREE KEYS EITHER WAY. Only the words differ -- which is exactly
    why the dropdown has to be rebuilt when the MODE changes and not only when
    the key list does.
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

const ALL = ['last_standing', 'most_kills', 'score_limit'];

function snapshot(modeKey) {
    const teamed = modeKey === 'tdm';
    const match = {
        id: 'm1', arenaKey: 'a', arenaLabel: 'Arena',
        modeKey: modeKey, modeLabel: 'Mode', state: 'lobby',
        teams: teamed,
        winCondition: 'last_standing',
        playerCount: 1, hostName: 'John Allday', players: [], teams_: [],
    };
    return {
        config: {
            arenas: [{ key: 'a', label: 'Arena', enabled: true }],
            modes: [
                { key: 'ffa', label: 'FFA', enabled: true, teams: false },
                { key: 'tdm', label: 'Team Deathmatch', enabled: true, teams: true },
            ],
            match: {
                lives: 3, minPlayers: 2, maxPlayers: 0, roundTimeSeconds: 600,
                livesChoice: { min: 1, max: 10 },
                winCondition: 'last_standing',
                winConditionChoice: ALL,
                scoreLimit: 25,
                scoreLimitChoice: { min: 1, max: 200 },
            },
            betting: {
                enabled: false,
                entryFee: { enabled: false, min: 0, max: 0, default: 0 },
                spectatorBets: { enabled: false, min: 0, max: 0 },
            },
            loadouts: {
                allowChoose: true, chooser: 'player', weapons: [],
                armor: { allowChoose: false, options: [], default: 100 },
            },
            teams: { list: [] },
            ui: {},
        },
        player: { matchId: 'm1', isHost: true },
        matches: [match],
        leaderboard: [],
    };
}

function opened(modeKey) {
    const panel = loadPanel(ROOT);
    const snap = snapshot(modeKey);
    panel.send('open', snap);
    panel.send('state', snap);
    return panel;
}

function labels(panel) {
    return panel.node('create-win').children.map(function (option) {
        return option.textContent;
    });
}

function labelFor(panel, key) {
    const options = panel.node('create-win').children;
    for (let index = 0; index < options.length; index += 1) {
        if (options[index].value === key) return options[index].textContent;
    }
    throw new Error('the dropdown does not offer ' + key + ' at all');
}

console.log('==> a team mode is won by TEAMS, and now says so');

test('THE REQUEST: last team standing', () => {
    const panel = opened('tdm');
    assert.ok(/team/i.test(labelFor(panel, 'last_standing')),
        'team deathmatch offers "' + labelFor(panel, 'last_standing')
        + '", which reads as a rule about the last PLAYER alive');
});

test('and team with the most kills', () => {
    const panel = opened('tdm');
    assert.ok(/team/i.test(labelFor(panel, 'most_kills')),
        'the clock-out rule does not mention teams: ' + labelFor(panel, 'most_kills'));
});

test('and first team to the kill limit', () => {
    const panel = opened('tdm');
    assert.ok(/team/i.test(labelFor(panel, 'score_limit')),
        'the kill limit does not mention teams: ' + labelFor(panel, 'score_limit'));
});

test('and all three are still the server\'s own three keys, not a fourth rule', () => {
    /* The keys are the contract with server/match.lua, which has an
       evaluator for exactly these three. Re-wording must not invent one. */
    const panel = opened('tdm');
    const values = panel.node('create-win').children.map(function (option) {
        return option.value;
    });
    assert.deepStrictEqual(values, ALL,
        'the team wording changed the keys on the wire: ' + values.join(', '));
});

test('a free-for-all is NOT told about teams it does not have', () => {
    const panel = opened('ffa');
    labels(panel).forEach(function (label) {
        assert.ok(!/team/i.test(label),
            'a free-for-all was offered a team rule: ' + label);
    });
});

test('and no option is printed as a raw config key either way', () => {
    [opened('ffa'), opened('tdm')].forEach(function (panel) {
        labels(panel).forEach(function (label) {
            assert.ok(label.length > 0, 'an option has no text at all');
            assert.ok(!/_/.test(label), 'an option is printed as a raw key: ' + label);
        });
    });
});

console.log('');
console.log('==> and the wording follows the mode select, not just the key list');

test('THE BUG THIS WOULD HAVE HAD: switching mode leaves the old words up', () => {
    /* The dropdown is rebuilt only when its signature changes, so it is not
       torn out from under an open list on every server push. The three keys
       are IDENTICAL in both modes -- so a signature built from the keys alone
       never changes when the host switches free-for-all to team deathmatch,
       and the solo wording stays on screen describing a team round. */
    const panel = opened('ffa');
    assert.ok(!/team/i.test(labelFor(panel, 'last_standing')),
        'the free-for-all wording was already the team one, so this proves nothing');

    panel.node('create-mode').value = 'tdm';
    panel.fire('create-mode', 'change');

    assert.ok(/team/i.test(labelFor(panel, 'last_standing')),
        'the dropdown still says "' + labelFor(panel, 'last_standing')
        + '" after the host switched to team deathmatch');
});

test('and back again', () => {
    const panel = opened('tdm');
    panel.node('create-mode').value = 'ffa';
    panel.fire('create-mode', 'change');

    assert.ok(!/team/i.test(labelFor(panel, 'last_standing')),
        'the team wording survived a switch back to a solo mode: '
        + labelFor(panel, 'last_standing'));
});

console.log('');
console.log('==> and the line under it explains the TEAM rule');

test('last team standing says the whole side wins it', () => {
    const panel = opened('tdm');
    const hint = panel.node('create-win-hint').textContent;
    assert.ok(/side/i.test(hint) || /team/i.test(hint),
        'the hint under a team round talks only about one player: ' + hint);
});

test('and the kill limit says which side reaches it', () => {
    const panel = opened('tdm');
    panel.node('create-win').value = 'score_limit';
    panel.fire('create-win', 'change');

    const hint = panel.node('create-win-hint').textContent;
    assert.ok(/side/i.test(hint) || /team/i.test(hint),
        'the kill-limit hint does not say it is a side that reaches it: ' + hint);
    assert.ok(/lives are not spent/i.test(hint),
        'the hint dropped the part that matters most -- that lives stop being spent: ' + hint);
});

test('and a free-for-all keeps its own wording', () => {
    const panel = opened('ffa');
    const hint = panel.node('create-win-hint').textContent;
    assert.ok(!/side/i.test(hint) && !/team/i.test(hint),
        'a free-for-all host was told about sides: ' + hint);
});

console.log('');
if (failures.length > 0) {
    failures.forEach(function (row) {
        console.log('FAILED: ' + row.name);
        console.log(row.error.stack);
    });
}
console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length > 0 ? 1 : 0);
