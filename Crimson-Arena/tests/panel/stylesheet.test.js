/*
    crimson_arena/tests/panel/stylesheet.test.js

    EVERY ELEMENT THE ADMIN TABLET DRAWS IS DRESSED.

    THE BUG THIS EXISTS FOR. The admin tablet shipped with structure in
    index.html, behaviour in app.js, and not one line of it in style.css. Both
    halves that HAVE tests passed: the markup was there, app.js drew into it,
    the Lua sent the right payload. What reached a seat was a column of grey
    operating-system buttons in the top-left corner of the screen, over the
    running game, with no box around them -- so "/arenaadmin does not pull up
    a tablet" was a true report about a feature every existing test called
    working.

    THE PAGE IS COMPOSITED OVER A RUNNING GAME, which is why the usual
    forgiveness does not apply here. On an ordinary web page an unstyled
    section is a plain but legible one. On a transparent NUI page it is
    unreadable text on whatever the player happens to be looking at, and a
    box that never appears at all.

    WHAT IT CHECKS, and deliberately not more: every element in the tablet's
    markup either names an id the stylesheet has a rule for, or carries a
    class it has a rule for -- and every class app.js invents while drawing
    the screen has one too. It does not check that the rules are any GOOD.
    That is a matter of taste and belongs to a person; this is the mechanical
    half nobody notices until it is missing.
*/

const assert = require('assert');
const fs = require('fs');
const path = require('path');

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

const html = fs.readFileSync(path.join(ROOT, 'html', 'index.html'), 'utf8');
const cssRaw = fs.readFileSync(path.join(ROOT, 'html', 'style.css'), 'utf8');

/* THE STYLESHEET WITHOUT ITS @media BLOCKS.
   A class whose ONLY rule sits inside `@media (max-width: 56rem)` is a class
   with no styling at all on the screen almost everybody plays on -- so
   counting those as "has a rule" would let exactly the bug this file exists
   for back in, narrowed to widescreens. */
const css = (function () {
    let out = '';
    let index = 0;
    while (index < cssRaw.length) {
        const at = cssRaw.indexOf('@media', index);
        if (at < 0) { out += cssRaw.slice(index); break; }
        out += cssRaw.slice(index, at);

        /* Walk the braces so a nested rule inside the block is skipped with
           it rather than ending it early. */
        let depth = 0;
        let cursor = cssRaw.indexOf('{', at);
        if (cursor < 0) break;
        while (cursor < cssRaw.length) {
            if (cssRaw[cursor] === '{') depth += 1;
            else if (cssRaw[cursor] === '}') {
                depth -= 1;
                if (depth === 0) { cursor += 1; break; }
            }
            cursor += 1;
        }
        index = cursor;
    }
    return out;
})();
const js = fs.readFileSync(path.join(ROOT, 'html', 'app.js'), 'utf8');

/* The tablet's own markup: from its opening tag to the end of the file, which
   is where it sits -- it is the last screen on the page. */
function adminMarkup() {
    const start = html.indexOf('<div id="arena-admin"');
    assert.ok(start >= 0, 'there is no admin tablet in the markup at all');
    return html.slice(start);
}

/* A selector is "present" when the stylesheet mentions it followed by
   something that ends a selector -- a brace, a comma, whitespace, or a
   combinator. Matching the bare string would let `#admin-list` be satisfied
   by a rule for `#admin-lists`. */
function styled(selector) {
    const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return new RegExp(escaped + '(?=[\\s,{:>+~])').test(css);
}

/* Every element in the tablet, as { id, classes }. */
function elements() {
    const markup = adminMarkup();
    const out = [];
    const tag = /<(\w+)([^>]*)>/g;
    let match = tag.exec(markup);
    while (match !== null) {
        const attrs = match[2];
        const id = /id="([^"]+)"/.exec(attrs);
        const cls = /class="([^"]+)"/.exec(attrs);
        out.push({
            tag: match[1],
            id: id ? id[1] : null,
            classes: cls ? cls[1].split(/\s+/).filter(Boolean) : [],
        });
        match = tag.exec(markup);
    }
    return out;
}

console.log('==> the admin tablet is dressed, not just built');

test('THE BUG: the tablet had no stylesheet rules of its own AT ALL', () => {
    /* The coarsest possible version of this check, kept as its own test
       because it is the one that would have caught what shipped. */
    assert.ok(styled('#arena-admin'),
        'style.css has no rule for #arena-admin -- the whole screen falls back '
        + 'to browser defaults over a transparent page');
});

test('and the box is positioned, not left in the top-left corner', () => {
    const block = css.slice(css.indexOf('#arena-admin {'));
    const rule = block.slice(0, block.indexOf('}'));
    assert.ok(/position:\s*fixed/.test(rule),
        'the tablet is not positioned, so it draws wherever the page flow puts it');
    assert.ok(/background:\s*var\(--bg\)/.test(rule),
        'the tablet has no ground of its own -- the game shows through its text');
});

test('every element in it names an id or a class the stylesheet knows', () => {
    const orphans = [];
    elements().forEach(function (element) {
        const byId = element.id !== null && styled('#' + element.id);
        const byClass = element.classes.some(function (name) {
            return styled('.' + name);
        });
        /* An element with neither an id nor a class is reached by a
           descendant rule or by nothing, and this test cannot tell those
           apart -- so it does not claim to. */
        if (element.id === null && element.classes.length === 0) return;
        if (!byId && !byClass) {
            orphans.push('<' + element.tag + ' id="' + element.id + '" class="'
                + element.classes.join(' ') + '">');
        }
    });
    assert.deepStrictEqual(orphans, [],
        'these elements have no rule anywhere in style.css:\n  ' + orphans.join('\n  '));
});

test('and every button on it wears the panel\'s own button class', () => {
    /* A bare <button> is an operating-system button: grey, rounded, in the
       system font, and nothing at all like the rest of this resource. */
    const bare = [];
    elements().forEach(function (element) {
        if (element.tag !== 'button') return;
        if (element.classes.indexOf('btn') < 0) {
            bare.push(element.id || '(unnamed)');
        }
    });
    assert.deepStrictEqual(bare, [],
        'these buttons are undressed: ' + bare.join(', '));
});

console.log('');
console.log('==> including the rows app.js invents while drawing it');

test('every admin- class the panel creates has a rule', () => {
    /* app.js builds the list rows, so they are in no markup file at all --
       which is exactly how they go unstyled without anybody noticing. */
    const created = new Set();
    const call = /makeEl\(\s*'(\w+)'\s*,\s*'([^']+)'/g;
    let match = call.exec(js);
    while (match !== null) {
        match[2].split(/\s+/).forEach(function (name) {
            if (name.indexOf('admin-') === 0) created.add(name);
        });
        match = call.exec(js);
    }

    assert.ok(created.size > 0,
        'no admin rows are created by app.js at all -- this test is asserting nothing');

    const orphans = [];
    created.forEach(function (name) {
        if (!styled('.' + name)) orphans.push('.' + name);
    });
    assert.deepStrictEqual(orphans, [],
        'these classes are drawn and never styled: ' + orphans.join(', '));
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
