/*
    crimson_arena/tests/panel/adminpayload.test.js

    THE TABLET READS ITS MESSAGE IN ONE PLACE.

    Two messages fill the admin tablet: `adminOpen`, when an operator opens
    it, and `adminState`, every refresh after that. They carry the same
    fourteen fields -- the matches, the two slates, the stash counts, the
    jam list's state, the database switch, the opening hours and the
    currency symbol -- and the panel used to read them in two copies of the
    same twenty-three lines, one per message.

    TWO COPIES IS HOW THEY DRIFTED ONCE ALREADY. server/main.lua records the
    time the two lists disagreed -- eight keys on one side, twelve on the
    other -- and the stash tab read "no database" on the very first draw, the
    one an operator opened the tablet to look at. Its note ends "DO NOT let
    the two lists drift apart again". The panel now reads both through
    readAdminPayload, so a field added there reaches both messages, and this
    file is what keeps it that way.

    WHAT IS PINNED HERE, and passed on the two copies before they were
    merged:

      Every field the same whichever message carried it.
      Every field ABSENT from a message read exactly as it always was --
      a default, never whatever the last message said -- except the
      currency symbol, which an absent one leaves alone.
      Garbage in every field coerced exactly as it always was.
      A refresh that lands after the tablet has closed changes nothing.
      adminOpen still resets what it reset, and adminState still keeps what
      it kept.

    AND WHAT WAS NOT TRUE OF THE TWO COPIES, and is now:

      Both messages go through the one function (read from the source, and
      proved by planting a field in the function and seeing both carry it).
      The function reads the message exactly as the two copies did: the old
      copy is kept below as REFERENCE, and a seeded run of hundreds of
      messages through the panel with each reader compares everything the
      tablet holds and draws, after every one.

    A FIELD ADDED ON PURPOSE goes into readAdminPayload, into server/main.lua's
    two payloads, and into REFERENCE below -- this file fails until all three
    agree, which is the point.
*/

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { loadPanel } = require('./harness');

const ROOT = path.resolve(__dirname, '..', '..', 'Crimson-Arena');
const APP = path.join(ROOT, 'html', 'app.js');

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

/*
 * THE OLD READER, KEPT WORD FOR WORD: the twenty-three lines both cases
 * carried before they were merged, jamsKnown comment included, without their
 * indentation. The differential below runs the panel with this in place of
 * the call, so it is the reference the new function is compared against.
 */
const REFERENCE = [
    'rememberCurrency(data.currencySymbol);',
    'admin.matches = arrayOf(data.matches);',
    'admin.owed = arrayOf(data.owed);',
    'admin.owedKit = arrayOf(data.owedKit);',
    'admin.owedKitSaved = data.owedKitSaved === true;',
    '/* AND WHETHER THE HELD-BACK MARKS BELOW MEAN ANYTHING',
    'YET. Until the jam list has been read back every stash',
    'looks unheld, and an unqualified screen would offer a',
    'hand-back on the one stash the door is certain to',
    'refuse. */',
    'admin.jamsKnown = data.jamsKnown === true;',
    'admin.databaseOn = data.databaseOn === true;',
    'admin.stashesFound = int(data.stashesFound, 0);',
    'admin.stashesRead = int(data.stashesRead, 0);',
    'admin.stashesReadable = data.stashesReadable !== false;',
    'admin.hoursOpen = data.hoursOpen !== false;',
    'admin.hoursForced = (data.hoursForced === \'open\' || data.hoursForced === \'shut\')',
    '? data.hoursForced',
    ': null;',
    'admin.hoursLine = typeof data.hoursLine === \'string\' ? data.hoursLine : null;',
    'admin.hoursOpensAt = typeof data.hoursOpensAt === \'string\'',
    '? data.hoursOpensAt',
    ': null;',
];

/* The fourteen message fields the reader takes, and the admin field each
   lands in (the symbol lands outside `admin`, in adminCurrency). */
const FIELDS = [
    'currencySymbol', 'matches', 'owed', 'owedKit', 'owedKitSaved', 'jamsKnown',
    'databaseOn', 'stashesFound', 'stashesRead', 'stashesReadable', 'hoursOpen',
    'hoursForced', 'hoursLine', 'hoursOpensAt',
];

/* What each admin field holds when its message field is ABSENT -- the old
   reader's answer, written out. */
const ABSENT = {
    matches: [], owed: [], owedKit: [], owedKitSaved: false, jamsKnown: false,
    databaseOn: false, stashesFound: 0, stashesRead: 0, stashesReadable: true,
    hoursOpen: true, hoursForced: null, hoursLine: null, hoursOpensAt: null,
};

// ======================================================================
// LOADING THE PANEL, WITH A WINDOW INTO IT
// ======================================================================

/*
 * loadPanel reads html/app.js itself, so a variant of the file is handed to
 * it by answering that one read with different text. Nothing else is read
 * differently, and fs is put back before loadPanel returns.
 */
function loadSource(source) {
    const real = fs.readFileSync;
    fs.readFileSync = function (file) {
        if (path.resolve(String(file)) === APP) return source;
        return real.apply(fs, arguments);
    };
    try {
        return loadPanel(ROOT);
    } finally {
        fs.readFileSync = real;
    }
}

function appSource() {
    return fs.readFileSync(APP, 'utf8');
}

/*
 * THE WINDOW. `admin` and `adminCurrency` are private to app.js's closure,
 * and the DOM only shows what the render chose to draw. So two lines are
 * planted directly after `var admin = {...};` that hang readers for both on
 * a node the test can reach. They read; they change nothing.
 */
function withProbe(source) {
    const start = source.indexOf('\n    var admin = {');
    assert.ok(start !== -1, 'app.js no longer declares `var admin = {` where this file looks for it');
    const close = source.indexOf('\n    };\n', start);
    assert.ok(close !== -1, 'the admin state object has no closing brace at the indent this file expects');
    const at = close + '\n    };\n'.length;
    return source.slice(0, at)
        + '    document.getElementById(\'test-admin-probe\').state = function () { return admin; };\n'
        + '    document.getElementById(\'test-admin-probe\').currency = function () { return adminCurrency; };\n'
        + source.slice(at);
}

/* The panel with the new reader, as shipped, plus the window. */
function current() {
    return loadSource(withProbe(appSource()));
}

/*
 * THE PANEL WITH THE OLD READER. Every call to readAdminPayload(data) is
 * replaced by the REFERENCE lines themselves -- which is exactly what both
 * cases were before the merge -- and nothing else in the file changes.
 */
function withOldReader(source) {
    const call = 'readAdminPayload(data);';
    const sites = source.split(call).length - 1;
    assert.strictEqual(sites, 2,
        'expected readAdminPayload(data) to be called from exactly the two cases, found ' + sites);
    return source.split(call).join(REFERENCE.join('\n'));
}

function adminOf(panel) { return panel.node('test-admin-probe').state(); }
function currencyOf(panel) { return panel.node('test-admin-probe').currency(); }

/* Stable JSON: keys sorted, so two objects built in a different order compare
   equal when they hold the same thing. */
function canon(value) {
    if (Array.isArray(value)) return '[' + value.map(canon).join(',') + ']';
    if (value && typeof value === 'object') {
        return '{' + Object.keys(value).sort().map(function (key) {
            return JSON.stringify(key) + ':' + canon(value[key]);
        }).join(',') + '}';
    }
    return value === undefined ? 'undefined' : JSON.stringify(value);
}

/* Everything the tablet has DRAWN: every node the panel knows by id, with
   what a person can see of it and everything beneath it. */
function drawn(panel) {
    const walk = function (node) {
        return {
            text: node.textContent || '',
            cls: node.className,
            disabled: node.disabled === true,
            value: node.value,
            kids: (node.children || []).map(walk),
        };
    };
    const out = {};
    Object.keys(panel.nodes).sort().forEach(function (id) {
        if (id === 'test-admin-probe') return;
        out[id] = walk(panel.nodes[id]);
    });
    return canon(out);
}

function copy(value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); }

const MATCH = {
    id: 'm1', label: 'Trailer Park', arenaKey: 'a', modeKey: 'ffa',
    state: 'live', hostName: 'John Allday', players: 2, pot: 1500,
};

const FOCUSED = {
    id: 'm1', label: 'Trailer Park', state: 'live', pot: 0, livesSpent: true,
    players: [
        { src: 1, name: 'Fighter One', alive: true, kills: 3, deaths: 1, lives: 3 },
        { src: 2, name: 'Fighter Two', alive: false, kills: 1, deaths: 3, lives: 3 },
    ],
};

/* Every field present, each set to something other than its absent answer. */
function fullPayload() {
    return {
        currencySymbol: '€',
        matches: [copy(MATCH)],
        owed: [{ citizenid: 'CID777', stash: 'crimson_arena_CID777', items: [{ name: 'phone', count: 1 }] }],
        owedKit: [{ citizenid: 'CID5', weapons: [{ name: 'WEAPON_PISTOL', serial: 'S1' }], items: [] }],
        owedKitSaved: true,
        jamsKnown: true,
        databaseOn: true,
        stashesFound: 7,
        stashesRead: 5,
        stashesReadable: false,
        hoursOpen: false,
        hoursForced: 'shut',
        hoursLine: '05:00-07:00',
        hoursOpensAt: '05:00',
    };
}

// ======================================================================
// THE PINS -- TRUE OF THE TWO COPIES, AND TRUE OF THE ONE FUNCTION
// ======================================================================

console.log('==> both messages read every field the same way');

test('every field, carried by adminOpen or by adminState, leaves the tablet holding and drawing the same', () => {
    /* THE SAME RENDER BEHIND BOTH. renderAdmin leaves alone what a branch
       it did not take never touched, so what is on screen depends on the
       draws before it as well as on the state -- both panels are therefore
       opened empty first, and differ only in which message brings the
       fields. */
    const viaOpen = current();
    viaOpen.send('adminOpen', {});
    viaOpen.send('adminOpen', fullPayload());

    const viaState = current();
    viaState.send('adminOpen', {});
    viaState.send('adminState', fullPayload());

    assert.strictEqual(canon(adminOf(viaState)), canon(adminOf(viaOpen)), 'the admin state differs');
    assert.strictEqual(currencyOf(viaState), currencyOf(viaOpen), 'the currency differs');
    assert.strictEqual(currencyOf(viaOpen), '€');
    assert.strictEqual(drawn(viaState), drawn(viaOpen), 'the tablet draws differently');

    const held = adminOf(viaOpen);
    const full = fullPayload();
    FIELDS.forEach(function (field) {
        if (field === 'currencySymbol') return;
        assert.strictEqual(canon(held[field]), canon(full[field]), field + ' was not taken from the message');
    });
});

test('a field ABSENT from either message reads exactly as it always did', () => {
    FIELDS.forEach(function (field) {
        const payload = fullPayload();
        delete payload[field];

        const viaOpen = current();
        viaOpen.send('adminOpen', payload);

        /* adminState ON TOP OF A FULL OPEN, so "absent" is tested against a
           tablet that was holding a value -- an absent field is a default,
           not "whatever the last message said". */
        const viaState = current();
        viaState.send('adminOpen', fullPayload());
        viaState.send('adminState', payload);

        if (field === 'currencySymbol') {
            /* THE ONE FIELD AN ABSENT VALUE LEAVES ALONE. rememberCurrency
               ignores a non-string, so the symbol from before stands. */
            assert.strictEqual(currencyOf(viaOpen), null, 'an absent symbol on open invented one');
            assert.strictEqual(currencyOf(viaState), '€', 'an absent symbol on refresh wiped the last one');
            return;
        }

        assert.strictEqual(canon(adminOf(viaOpen)[field]), canon(ABSENT[field]),
            field + ' absent from adminOpen');
        assert.strictEqual(canon(adminOf(viaState)[field]), canon(ABSENT[field]),
            field + ' absent from adminState');
        assert.strictEqual(canon(adminOf(viaState)), canon(adminOf(viaOpen)),
            field + ' absent: the two messages disagree about the rest');
    });
});

test('an empty message, and no message data at all, give the absent answer for every field in both', () => {
    [{}, null, 'junk', 5].forEach(function (data) {
        const viaOpen = current();
        viaOpen.send('adminOpen', data);
        const viaState = current();
        viaState.send('adminOpen', fullPayload());
        viaState.send('adminState', data);

        Object.keys(ABSENT).forEach(function (field) {
            assert.strictEqual(canon(adminOf(viaOpen)[field]), canon(ABSENT[field]),
                field + ' on adminOpen(' + JSON.stringify(data) + ')');
            assert.strictEqual(canon(adminOf(viaState)[field]), canon(ABSENT[field]),
                field + ' on adminState(' + JSON.stringify(data) + ')');
        });
    });
});

test('garbage in every field is coerced exactly as it always was, in both', () => {
    /* [value sent, what the tablet must hold]. The answers are the old
       reader's: === true, !== false, parseInt, and the two string checks. */
    const cases = {
        matches: [[{}, []], ['x', []], [7, []], [null, []]],
        owed: [[{}, []], [true, []]],
        owedKit: [['[]', []], [null, []]],
        owedKitSaved: [['true', false], [1, false], [null, false]],
        jamsKnown: [['true', false], [1, false]],
        databaseOn: [[1, false], ['yes', false]],
        stashesFound: [['12', 12], ['12abc', 12], ['abc', 0], [-3, -3], [2.7, 2], [null, 0], [true, 0]],
        stashesRead: [['9', 9], [[], 0], [{}, 0]],
        stashesReadable: [[null, true], [0, true], ['false', true], [false, false]],
        hoursOpen: [[0, true], [null, true], [false, false]],
        hoursForced: [['OPEN', null], ['', null], [1, null], ['open', 'open'], ['shut', 'shut']],
        hoursLine: [[5, null], [{}, null], ['', '']],
        hoursOpensAt: [[5, null], [null, null], ['', '']],
    };
    Object.keys(cases).forEach(function (field) {
        cases[field].forEach(function (pair) {
            const payload = fullPayload();
            payload[field] = pair[0];

            const viaOpen = current();
            viaOpen.send('adminOpen', copy(payload));
            const viaState = current();
            viaState.send('adminOpen', {});
            viaState.send('adminState', copy(payload));

            const label = field + ' = ' + JSON.stringify(pair[0]);
            assert.strictEqual(canon(adminOf(viaOpen)[field]), canon(pair[1]), label + ' on adminOpen');
            assert.strictEqual(canon(adminOf(viaState)[field]), canon(pair[1]), label + ' on adminState');
        });
    });
    /* And the symbol: a string of any kind is an answer, anything else is not. */
    [['', ''], ['$', '$'], [5, '€'], [null, '€'], [{}, '€']].forEach(function (pair) {
        const panel = current();
        panel.send('adminOpen', { currencySymbol: '€' });
        panel.send('adminState', { currencySymbol: pair[0] });
        assert.strictEqual(currencyOf(panel), pair[1], 'currencySymbol = ' + JSON.stringify(pair[0]));
    });
});

console.log('');
console.log('==> and what each message does besides, it still does');

test('a refresh that lands after the tablet has closed changes nothing, not even the symbol', () => {
    /* adminState's `if (!admin.open) break;` comes BEFORE the read. A read
       moved above it would take the symbol -- and every field -- off a
       message meant for a tablet that is no longer there. */
    const panel = current();
    panel.send('adminOpen', { currencySymbol: '£', matches: [copy(MATCH)] });
    panel.send('adminClose', {});
    const before = canon(adminOf(panel));

    panel.send('adminState', fullPayload());

    assert.strictEqual(canon(adminOf(panel)), before, 'a closed tablet took a refresh');
    assert.strictEqual(currencyOf(panel), '£', 'a closed tablet took the refresh\'s symbol');
    assert.strictEqual(adminOf(panel).open, false);
});

test('and one before it ever opened is ignored the same way', () => {
    const panel = current();
    panel.send('adminState', fullPayload());
    assert.strictEqual(adminOf(panel).open, false);
    assert.strictEqual(currencyOf(panel), null);
    assert.strictEqual(canon(adminOf(panel).matches), '[]');
});

test('adminOpen still resets the focus, the fighter, the tab, the stash and the Tools report', () => {
    const panel = current();
    panel.send('adminOpen', fullPayload());
    const admin = adminOf(panel);
    admin.focused = copy(FOCUSED);
    admin.player = 1;
    admin.tab = 'stashes';
    admin.stash = 'crimson_arena_CID777';
    admin.tool = 'doors';
    admin.toolTitle = 'Doors';
    admin.toolLines = ['a line'];
    admin.toolWaiting = true;

    panel.send('adminOpen', fullPayload());

    const after = adminOf(panel);
    assert.strictEqual(after.open, true);
    assert.strictEqual(after.focused, null);
    assert.strictEqual(after.player, null);
    assert.strictEqual(after.tab, null);
    assert.strictEqual(after.stash, null);
    assert.strictEqual(after.tool, null);
    assert.strictEqual(after.toolTitle, null);
    assert.strictEqual(canon(after.toolLines), '[]');
    assert.strictEqual(after.toolWaiting, false);
});

test('adminOpen ignores a focused match in its message; adminState takes one, and keeps the fighter with it', () => {
    const opened = current();
    const payload = fullPayload();
    payload.focused = copy(FOCUSED);
    opened.send('adminOpen', payload);
    assert.strictEqual(adminOf(opened).focused, null, 'adminOpen took a focus from its message');

    const refreshed = current();
    refreshed.send('adminOpen', fullPayload());
    adminOf(refreshed).player = 2;
    refreshed.send('adminState', payload);
    assert.strictEqual(canon(adminOf(refreshed).focused), canon(FOCUSED), 'adminState dropped the focus');
    assert.strictEqual(adminOf(refreshed).player, 2, 'a refresh with a focus forgot the fighter');
});

test('adminState with no focus, or garbage for one, drops both the focus and the fighter', () => {
    [undefined, null, 'm1', 7, false].forEach(function (focused) {
        const panel = current();
        panel.send('adminOpen', fullPayload());
        const payload = fullPayload();
        payload.focused = copy(FOCUSED);
        panel.send('adminState', payload);
        adminOf(panel).player = 1;

        const next = fullPayload();
        if (focused !== undefined) next.focused = focused;
        panel.send('adminState', next);
        assert.strictEqual(adminOf(panel).focused, null, 'focused = ' + JSON.stringify(focused));
        assert.strictEqual(adminOf(panel).player, null, 'the fighter outlived the focus: ' + JSON.stringify(focused));
    });
});

test('adminState keeps the tab, the stash, the Tools report and both confirmations', () => {
    const panel = current();
    panel.send('adminOpen', fullPayload());
    const admin = adminOf(panel);
    admin.tab = 'stashes';
    admin.stash = 'crimson_arena_CID777';
    admin.tool = 'doors';
    admin.toolTitle = 'Doors';
    admin.toolLines = ['a line'];
    admin.toolWaiting = true;
    admin.wipeConfirm = true;
    admin.holdConfirm = 'crimson_arena_CID777';

    panel.send('adminState', fullPayload());

    const after = adminOf(panel);
    assert.strictEqual(after.tab, 'stashes');
    assert.strictEqual(after.stash, 'crimson_arena_CID777');
    assert.strictEqual(after.tool, 'doors');
    assert.strictEqual(after.toolTitle, 'Doors');
    assert.strictEqual(canon(after.toolLines), canon(['a line']));
    assert.strictEqual(after.toolWaiting, true);
    assert.strictEqual(after.wipeConfirm, true, 'the reader touched the Stop-every-match arming');
    assert.strictEqual(after.holdConfirm, 'crimson_arena_CID777', 'the reader touched the hold confirmation');
});

test('adminOpen marks the tablet open BEFORE it reads the message', () => {
    /* The order the merge had to keep. A message whose reading fails half
       way -- here a field that throws, the only way to make the order
       visible from outside, since JSON cannot -- has still opened the
       tablet, so the refresh after it is taken rather than ignored. */
    const panel = current();
    const poisoned = fullPayload();
    Object.defineProperty(poisoned, 'owedKitSaved', {
        get() { throw new Error('unreadable'); },
        enumerable: true,
    });
    panel.send('adminOpen', poisoned);
    assert.strictEqual(adminOf(panel).open, true, 'the tablet was not open when the read began');

    panel.send('adminState', fullPayload());
    assert.strictEqual(adminOf(panel).stashesFound, 7, 'the refresh after it was ignored');
});

// ======================================================================
// ONE FUNCTION, TWO CALLERS -- NOT TRUE OF THE TWO COPIES
// ======================================================================

console.log('');
console.log('==> and both messages are read by the one function');

/* The body of one `case '<name>':` in the message switch, up to the next case. */
function caseBody(source, name) {
    const start = source.indexOf('\n                case \'' + name + '\':\n');
    assert.ok(start !== -1, 'no `case \'' + name + '\':` in the message switch');
    const next = source.indexOf('\n                case \'', start + 1);
    return source.slice(start, next === -1 ? undefined : next);
}

test('readAdminPayload is defined once, inside the panel\'s closure, after the admin state it fills', () => {
    const source = appSource();
    const definitions = source.split('\n    function readAdminPayload(data) {\n').length - 1;
    assert.strictEqual(definitions, 1, 'readAdminPayload(data) definitions at the closure\'s indent');

    /* INSIDE THE IIFE, AFTER `var admin`. Outside it, admin, int, arrayOf and
       rememberCurrency do not resolve -- and guarded() swallows the
       ReferenceError, so the tablet goes blank with nothing on the console. */
    const at = source.indexOf('\n    function readAdminPayload(data) {\n');
    const adminAt = source.indexOf('\n    var admin = {');
    const refreshAt = source.indexOf('\n    function adminRefresh() {');
    assert.ok(adminAt !== -1 && at > adminAt, 'readAdminPayload is above the admin state it writes to');
    assert.ok(refreshAt !== -1 && at < refreshAt, 'readAdminPayload has moved away from the admin helpers');
});

test('adminOpen and adminState each call it once, in the right place, and read no field themselves', () => {
    const source = appSource();
    const open = caseBody(source, 'adminOpen');
    const refresh = caseBody(source, 'adminState');

    [['adminOpen', open], ['adminState', refresh]].forEach(function (pair) {
        assert.strictEqual(pair[1].split('readAdminPayload(data);').length - 1, 1,
            pair[0] + ' must read its message through readAdminPayload exactly once');
        FIELDS.forEach(function (field) {
            assert.strictEqual(pair[1].indexOf('data.' + field), -1,
                pair[0] + ' reads data.' + field + ' itself -- that is the drift this file exists to stop');
        });
    });

    /* adminOpen: open first, then the read, then the resets. */
    assert.ok(open.indexOf('admin.open = true;') !== -1
        && open.indexOf('admin.open = true;') < open.indexOf('readAdminPayload(data);'),
        'adminOpen reads the message before it marks the tablet open');
    assert.ok(open.indexOf('readAdminPayload(data);') < open.indexOf('admin.focused = null;'),
        'adminOpen resets the focus before reading, not after');

    /* adminState: the closed-tablet guard first, then the read, then the focus. */
    assert.ok(refresh.indexOf('if (!admin.open) break;') !== -1
        && refresh.indexOf('if (!admin.open) break;') < refresh.indexOf('readAdminPayload(data);'),
        'adminState reads the message before it checks the tablet is open');
    assert.ok(refresh.indexOf('readAdminPayload(data);') < refresh.indexOf('admin.focused = (data.focused'),
        'adminState takes the focus before the read');
});

test('nothing outside readAdminPayload fills the tablet from a message', () => {
    /* WHAT A THIRD COPY LOOKS LIKE, and only that: one of the thirteen admin
       fields the reader fills, assigned from `data` anywhere but the reader.
       The two cases are held to that above; this holds the rest of the file.

       NARROWER THAN "NO data.<field> ANYWHERE", ON PURPOSE. Another message
       is free to carry a field of the same name for its own screen --
       `matches`, `owed`, a currency symbol -- and read it, and that is not
       this tablet's business; a test that failed on it would be switched
       off the first time it cried wolf. A write into the tablet's own
       state from a message is the drift, wherever it happens. */
    const source = appSource();
    const anchor = '\n    function readAdminPayload(data) {\n';
    const start = source.indexOf(anchor);
    assert.ok(start !== -1, 'there is no readAdminPayload');
    const end = source.indexOf('\n    }\n', start);
    assert.ok(end !== -1, 'readAdminPayload has no end at its own indent');
    const outside = source.slice(0, start) + source.slice(end);

    Object.keys(ABSENT).forEach(function (field) {
        const filled = new RegExp('\\badmin\\.' + field + '\\s*=(?!=)[^;]*\\bdata\\b');
        const hit = outside.match(filled);
        assert.strictEqual(hit, null,
            'admin.' + field + ' is filled from a message outside readAdminPayload: ' + (hit && hit[0]));
    });

    /* And the rule bites: the reader's own lines, put anywhere else, are
       found -- every one of them, in each of its spellings. */
    const reader = source.slice(start + anchor.length, end);
    let found = 0;
    Object.keys(ABSENT).forEach(function (field) {
        const filled = new RegExp('\\badmin\\.' + field + '\\s*=(?!=)[^;]*\\bdata\\b');
        if (filled.test(reader)) found += 1;
    });
    assert.strictEqual(found, Object.keys(ABSENT).length, 'admin fields the rule finds in the reader itself');
    assert.strictEqual(/\badmin\.matches\s*=(?!=)[^;]*\bdata\b/.test('admin.matches = [];\n var x = data.matches;'), false,
        'a reset followed by an unrelated read is not a fill');
    assert.strictEqual(/\badmin\.owed\s*=(?!=)[^;]*\bdata\b/.test('if (admin.owed === data.owed) {}'), false,
        'a comparison is not a fill');
});

test('the reader is REFERENCE word for word, the jamsKnown note included', () => {
    /* BOTH WAYS ROUND, so this also proves REFERENCE is a true copy of what
       the two cases carried: with no readAdminPayload in the file it looks
       for REFERENCE inside each case instead, which is what it found before
       the merge. With the function, its body must be REFERENCE exactly --
       every line, the comment and the order, indentation aside. */
    const source = appSource();
    const trimmed = function (text) {
        return text.split('\n').map(function (line) { return line.trim(); }).join('\n');
    };
    const anchor = '\n    function readAdminPayload(data) {\n';
    const start = source.indexOf(anchor);
    if (start === -1) {
        ['adminOpen', 'adminState'].forEach(function (name) {
            assert.ok(trimmed(caseBody(source, name)).indexOf(REFERENCE.join('\n')) !== -1,
                name + ' does not carry REFERENCE -- the copy in this file is not the old reader');
        });
        return;
    }
    const bodyStart = start + anchor.length;
    const end = source.indexOf('\n    }\n', bodyStart);
    assert.strictEqual(trimmed(source.slice(bodyStart, end)), REFERENCE.join('\n'));
});

test('a field planted in readAdminPayload reaches BOTH messages', () => {
    /* The drift, proved impossible rather than asserted absent: one new line
       in the function, and both messages must carry it. Two copies could
       not pass this -- a line added to one is missing from the other. */
    const source = appSource();
    const anchor = '\n    function readAdminPayload(data) {\n';
    assert.ok(source.indexOf(anchor) !== -1, 'there is no readAdminPayload to plant a field in');
    const planted = source.replace(anchor, anchor + '        admin.plantedForTest = data.plantedForTest;\n');

    const viaOpen = loadSource(withProbe(planted));
    viaOpen.send('adminOpen', { plantedForTest: 'open' });
    assert.strictEqual(adminOf(viaOpen).plantedForTest, 'open', 'adminOpen did not read through readAdminPayload');

    const viaState = loadSource(withProbe(planted));
    viaState.send('adminOpen', {});
    viaState.send('adminState', { plantedForTest: 'refresh' });
    assert.strictEqual(adminOf(viaState).plantedForTest, 'refresh', 'adminState did not read through readAdminPayload');
});

// ======================================================================
// THE DIFFERENTIAL -- THE OLD READER AGAINST THE NEW, MESSAGE BY MESSAGE
// ======================================================================

console.log('');
console.log('==> and it reads every message exactly as the two copies did');

/* mulberry32: a fixed seed, so a failing step names a sequence that fails
   the same way on every run. */
function prng(seed) {
    let a = seed >>> 0;
    return function (n) {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        const r = ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        return Math.floor(r * n);
    };
}

const ABSENT_MARK = {};

/* What each field may carry in the corpus: the real shapes, and the garbage
   a broken or older server could send. ABSENT_MARK leaves the key out. */
const POOL = {
    currencySymbol: [ABSENT_MARK, '€', '', '$', null, 5, {}],
    matches: [ABSENT_MARK, [], [MATCH], [MATCH, Object.assign({}, MATCH, { id: 'm2', state: 'waiting', pot: 0 })],
        {}, null, 'x', 3],
    owed: [ABSENT_MARK, [], [{ citizenid: 'CID777', stash: 'crimson_arena_CID777', items: [{ name: 'phone', count: 1 }] }],
        null, {}],
    owedKit: [ABSENT_MARK, [], [{ citizenid: 'CID5', weapons: [{ name: 'WEAPON_PISTOL', serial: 'S1' }], items: [] }],
        null, 'x'],
    owedKitSaved: [ABSENT_MARK, true, false, 'true', 1, null],
    jamsKnown: [ABSENT_MARK, true, false, 'true', 0],
    databaseOn: [ABSENT_MARK, true, false, 1, 'false'],
    stashesFound: [ABSENT_MARK, 0, 3, '12', '12abc', 'abc', -2, 2.5, null, true],
    stashesRead: [ABSENT_MARK, 0, 2, '4', 'x', null, {}],
    stashesReadable: [ABSENT_MARK, true, false, null, 0, 'false'],
    hoursOpen: [ABSENT_MARK, true, false, null, 0, 'no'],
    hoursForced: [ABSENT_MARK, 'open', 'shut', 'OPEN', '', null, 1],
    hoursLine: [ABSENT_MARK, '05:00-07:00', '', 5, null],
    hoursOpensAt: [ABSENT_MARK, '05:00', '', 7, null],
    focused: [ABSENT_MARK, FOCUSED, null, 'm1', 4, []],
};

function randomPayload(roll) {
    const out = {};
    Object.keys(POOL).forEach(function (field) {
        const pick = POOL[field][roll(POOL[field].length)];
        if (pick !== ABSENT_MARK) out[field] = copy(pick);
    });
    return out;
}

/* One step the operator or the server could take, applied to both panels. */
function randomStep(roll) {
    const kind = roll(12);
    if (kind <= 3) return { send: 'adminState', data: randomPayload(roll) };
    if (kind <= 5) return { send: 'adminOpen', data: randomPayload(roll) };
    if (kind === 6) return { send: 'adminClose', data: {} };
    if (kind === 7) return { send: 'adminTool', data: { tool: ['doors', null][roll(2)], title: 'T', lines: ['l'] } };
    if (kind === 8) return { click: ['admin-tab-stashes', 'admin-tab-matches', 'admin-tab-tools', 'admin-wipe'][roll(4)] };
    if (kind === 9) return { row: 'admin-matches' };
    if (kind === 10) return { poke: { wipeConfirm: roll(2) === 0, holdConfirm: ['crimson_arena_CID777', null][roll(2)] } };
    return { poke: { player: [1, 2, null][roll(3)], stash: ['crimson_arena_CID777', null][roll(2)] } };
}

function apply(panel, step) {
    if (step.send) {
        panel.send(step.send, copy(step.data));
    } else if (step.click) {
        panel.fire(step.click, 'click');
    } else if (step.row) {
        const rows = panel.node(step.row).children;
        if (rows.length > 0 && rows[0].listeners && rows[0].listeners.click) {
            rows[0].listeners.click.forEach(function (fn) {
                fn({ target: rows[0], stopPropagation() {}, preventDefault() {} });
            });
        }
    } else if (step.poke) {
        const admin = adminOf(panel);
        Object.keys(step.poke).forEach(function (key) { admin[key] = step.poke[key]; });
    }
}

const SEQUENCES = 12;
const STEPS = 45;

test(SEQUENCES + ' seeded sequences of ' + STEPS + ' steps: the old reader and readAdminPayload leave the tablet identical after every one', () => {
    const shipped = withProbe(appSource());
    const old = withOldReader(shipped);
    let compared = 0;
    let messages = 0;

    for (let sequence = 1; sequence <= SEQUENCES; sequence += 1) {
        const roll = prng(sequence * 2654435761);
        const before = loadSource(old);
        const after = loadSource(shipped);

        for (let index = 1; index <= STEPS; index += 1) {
            const step = randomStep(roll);
            apply(before, step);
            apply(after, step);
            if (step.send === 'adminOpen' || step.send === 'adminState') messages += 1;

            const where = 'sequence ' + sequence + ' step ' + index + ' (' + JSON.stringify(step).slice(0, 160) + ')';
            assert.strictEqual(canon(adminOf(after)), canon(adminOf(before)), 'admin state differs at ' + where);
            assert.strictEqual(currencyOf(after), currencyOf(before), 'currency differs at ' + where);
            assert.strictEqual(drawn(after), drawn(before), 'the drawn tablet differs at ' + where);
            assert.strictEqual(canon(after.posted), canon(before.posted), 'what was posted differs at ' + where);
            compared += 1;
        }
    }
    assert.strictEqual(compared, SEQUENCES * STEPS);
    assert.ok(messages >= 200, 'only ' + messages + ' adminOpen/adminState messages in the corpus');
});

console.log(passed + ' passed, ' + failures.length + ' failed');
process.exit(failures.length > 0 ? 1 : 0);
