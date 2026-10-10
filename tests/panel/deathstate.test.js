/*
    crimson_arena/tests/panel/deathstate.test.js

    THE PANEL NEVER READS kills OR deaths OFF A MATCH ROW.

    ArenaMatch.OnDeath no longer broadcasts a death that leaves the fighter
    a life in a round with no ladder that it does not decide. Such a death
    moves exactly two fields of the state snapshot -- a match row's `kills`
    and `deaths` -- so between broadcasts those two can trail the real count.
    That is only safe while nothing on the screen is drawn from them: the
    panel's kills and deaths come from the HUD payload, the results card, the
    leaderboard rows and the admin screens, never from `matches[].players[]`.

    THIS IS WHAT HOLDS IT TO THAT, TWO WAYS:

      EVERY FIELD READ OFF A MATCH ROW IS WRITTEN DOWN. Each row is handed to
      the panel behind a Proxy, and the panel is walked through every tab as
      a fighter, a fighter who is out and watching, an onlooker watching and
      a bystander who picked the match from the list -- team and free-for-all,
      live and in the lobby, a ladder and none.

      AND THE SCREEN DOES NOT MOVE. The same views are drawn twice from one
      snapshot and then from a copy whose counts are different; every node
      the panel built must come out identical.

    tests/deathbroadcast_spec.lua holds the Lua half: the server side of the
    change and every client file that receives the state event.
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

const TABS = ['matches', 'lobby', 'loadout', 'bets', 'board'];

/* A snapshot in the shape server/lobby.lua's BuildState sends. `counts`
   shifts every row's kills and deaths, which is the only thing a quiet
   death changes. */
function snapshot(view, counts) {
    const teams = view.teams === true;
    const ladder = view.ladder === true;
    const shift = counts || 0;
    const rows = [1, 2, 3, 4].map((id) => ({
        id,
        name: 'Fighter ' + id,
        team: teams ? (id % 2 === 1 ? 'crimson' : 'ash') : null,
        ready: true,
        kills: id + shift,
        deaths: (id % 3) + shift * 2,
        alive: !(view.outRow === id),
        isHost: id === 1,
    }));
    const match = {
        id: 'm1', label: 'Friday Night', arenaKey: 'trailerpark', arenaLabel: 'Trailer Park',
        betsOpen: view.betsOpen !== false, fighterBetsOpen: false, sizeFactor: 1,
        modeKey: ladder ? 'gungame' : (teams ? 'tdm' : 'ffa'),
        modeLabel: ladder ? 'Gun Game' : (teams ? 'Team Deathmatch' : 'Free For All'),
        teams, hostId: 1, hostName: 'Fighter 1', state: view.state || 'live',
        entryFee: 500, lives: 3, radar: false, roundTimeSeconds: 600,
        winCondition: view.win || 'last_standing', livesSpent: (view.win || 'last_standing') === 'last_standing',
        scoreLimit: 25, tierPlan: null, tiers: ladder ? 6 : null,
        pot: 2000, entryPot: 2000, betPool: 600, bets: 2,
        betsByPick: { all: teams ? { crimson: 400, ash: 200 } : { 1: 400, 2: 200 } },
        playerCount: 4, teamCounts: teams ? { crimson: 2, ash: 2 } : {},
        startsAt: 1700000000, players: rows,
    };
    return {
        config: {
            arenas: [{ key: 'trailerpark', label: 'Trailer Park', enabled: true }],
            modes: [
                { key: 'ffa', label: 'Free For All', enabled: true, teams: false },
                { key: 'tdm', label: 'Team Deathmatch', enabled: true, teams: true },
                { key: 'gungame', label: 'Gun Game', enabled: true, teams: false, tiers: 6 },
            ],
            match: { lives: 3, livesChoice: { min: 1, max: 10 }, minPlayers: 2, maxPlayers: 0,
                roundTimeSeconds: 600, winCondition: 'last_standing' },
            betting: {
                enabled: true, currencySymbol: '$', account: 'cash', accounts: ['cash', 'bank'],
                payout: 'winner_takes_all',
                entryFee: { enabled: true, min: 100, max: 5000, default: 500 },
                spectatorBets: { enabled: true, min: 50, max: 1000, oddsMultiplier: 2, oneBetPerMatch: true },
                fighterBets: { enabled: true, min: 100, max: 50000, ownSideOnly: true, oneBetPerMatch: true },
                betPayout: { fighters: 'pool', spectators: 'pool', sharedPool: true, includeEntryPot: true },
            },
            loadouts: { allowChoose: false, chooser: 'player', weapons: [],
                armor: { allowChoose: false, options: [], default: 100 } },
            teams: { list: [{ key: 'crimson', label: 'Crimson' }, { key: 'ash', label: 'Ash' }] },
            ui: {},
        },
        player: {
            serverId: view.self, name: 'Viewer', money: 12000, wallet: { cash: 12000, bank: 48000 },
            matchId: view.inMatch ? 'm1' : false,
            team: view.inMatch && teams ? (view.self % 2 === 1 ? 'crimson' : 'ash') : false,
            ready: view.inMatch === true, loadout: { weapons: [] },
            spectating: view.watching ? 'm1' : false,
            bet: false, backing: [], walkedOut: [], isHost: view.self === 1, editRefused: 0,
        },
        matches: [match],
        leaderboard: [{ name: 'Fighter 1', wins: 3, kills: 40, deaths: 12, earnings: 9000 }],
        keepOut: [],
        schedule: { open: true },
    };
}

/* Every row behind a Proxy that writes down what is read off it. */
function watched(snap, reads) {
    snap.matches.forEach((match) => {
        match.players = match.players.map((row) => new Proxy(row, {
            get(target, key) {
                if (typeof key === 'string') reads[key] = (reads[key] || 0) + 1;
                return target[key];
            },
            ownKeys(target) {
                reads['(every field)'] = (reads['(every field)'] || 0) + 1;
                return Reflect.ownKeys(target);
            },
        }));
    });
    return snap;
}

/* Everything the panel has built, as one string. */
function screen(panel) {
    const seen = new Set();
    const walk = (node) => {
        if (!node || seen.has(node)) return '';
        seen.add(node);
        const own = [
            node.tag, node.id, node.textContent, node.className, node.hidden, node.disabled,
            node.value, node.title, JSON.stringify(node.style || {}),
        ].map(String).join('|');
        return '<' + own + '>' + (node.children || []).map(walk).join('') + '</>';
    };
    return Object.keys(panel.nodes).sort().map((id) => id + '=' + walk(panel.nodes[id])).join('\n');
}

/* The match card in the list, which a bystander clicks to pick it. */
function cardFor(panel, matchId) {
    const button = panel.nodes['match-join-' + matchId];
    const find = (node) => {
        if (!node) return null;
        if ((node.listeners.click || []).length > 0 && contains(node, button)) return node;
        for (const kid of node.children || []) {
            const hit = find(kid);
            if (hit) return hit;
        }
        return null;
    };
    const contains = (node, wanted) => node === wanted
        || (node.children || []).some((kid) => contains(kid, wanted));
    return find(panel.node('match-list'));
}

const VIEWS = [
    { name: 'a fighter in a live team round', self: 1, inMatch: true, teams: true },
    { name: 'a fighter who is out and watching', self: 3, inMatch: true, watching: true, teams: true, outRow: 3 },
    { name: 'an onlooker watching a free-for-all', self: 11, watching: true },
    { name: 'a bystander who picked the match from the list', self: 12, pick: true, teams: true },
    { name: 'a fighter in a gun game', self: 2, inMatch: true, ladder: true },
    { name: 'a fighter in a most-kills round', self: 2, inMatch: true, win: 'most_kills' },
    { name: 'a watcher once the book has shut', self: 11, watching: true, betsOpen: false, win: 'score_limit' },
    { name: 'a bystander looking at a lobby', self: 12, pick: true, state: 'lobby' },
];

/* Draws one view on every tab, and returns the screen per tab. */
function drawAll(panel, view, snap) {
    panel.send('state', snap);
    if (view.pick) {
        const card = cardFor(panel, 'm1');
        assert.ok(card, 'the match card was not found, so the bystander never picked the match');
        card.listeners.click.forEach((fn) => fn({ target: card, stopPropagation() {}, preventDefault() {} }));
    }
    const out = {};
    TABS.forEach((tab) => {
        panel.fire('tab-btn-' + tab, 'click');
        out[tab] = screen(panel);
    });
    return out;
}

console.log('==> nothing on the panel is drawn from a match row\'s kills or deaths');

VIEWS.forEach((view) => {
    test('no read of kills or deaths off a match row: ' + view.name, () => {
        const reads = {};
        const panel = loadPanel(ROOT);
        panel.send('open', snapshot(view));
        drawAll(panel, view, watched(snapshot(view), reads));
        drawAll(panel, view, watched(snapshot(view, 5), reads));

        assert.strictEqual(reads.kills, undefined, 'the panel read `kills` off a match row');
        assert.strictEqual(reads.deaths, undefined, 'the panel read `deaths` off a match row');
        assert.strictEqual(reads['(every field)'], undefined, 'the panel walked every field of a match row');
        /* THE PROXIES WERE REALLY IN THE PATH, or the lines above prove
           nothing: the roster and the bet rows name the fighters off these
           rows, so a name has to have been read. */
        assert.ok((reads.name || 0) > 0,
            'nothing read a match row at all: ' + JSON.stringify(reads));
    });

    test('and the screen is identical whatever the counts say: ' + view.name, () => {
        const panel = loadPanel(ROOT);
        panel.send('open', snapshot(view));
        const first = drawAll(panel, view, snapshot(view));
        const again = drawAll(panel, view, snapshot(view));
        const moved = drawAll(panel, view, snapshot(view, 7));

        TABS.forEach((tab) => {
            assert.strictEqual(again[tab], first[tab],
                'the ' + tab + ' tab is not stable across two identical snapshots, so this compares nothing');
            assert.strictEqual(moved[tab], again[tab],
                'the ' + tab + ' tab changed when only the counts on the match rows did');
        });
    });
});

test('CONTROL: a field the panel DOES draw from a row -- alive -- does move the screen', () => {
    /* The comparison above is only worth something if it can see a change. */
    const view = { self: 12, pick: true, teams: false };
    const panel = loadPanel(ROOT);
    panel.send('open', snapshot(view));
    drawAll(panel, view, snapshot(view));
    const before = drawAll(panel, view, snapshot(view));
    const out = snapshot(view);
    out.matches[0].players[1].alive = false;
    const after = drawAll(panel, view, out);
    assert.ok(TABS.some((tab) => before[tab] !== after[tab]),
        'a fighter going out changed nothing on any tab, so the screen comparison is blind');
});

console.log('');
console.log(passed + ' passed, ' + failures.length + ' failed');
if (failures.length > 0) {
    console.log('');
    console.log('Failures:');
    failures.forEach((f) => console.log('  - ' + f.name + ': ' + (f.error && f.error.stack || f.error)));
}
process.exit(failures.length === 0 ? 0 : 1);
