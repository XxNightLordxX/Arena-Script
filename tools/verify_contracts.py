#!/usr/bin/env python3
"""Crimson Arena: the promises this resource makes to itself.

Every check here is a name crossing a boundary. A typo in one is silent at load
time and only shows up when a player walks into it -- the panel asks for an
element that is not there, the code asks for a locale key that was deleted, a
setting the operator can write is read by nothing.

    python3 tools/verify_contracts.py [path-to-resource]

Exit 0 when every contract holds. Each failure names the file and the name.

EVERY CHECK BELOW REPORTS HOW MANY THINGS IT LOOKED AT. A gate that passes by
finding nothing is worse than no gate, and the count is how you tell the two
apart at a glance. Several checks here read as informational rather than fatal,
because the resource legitimately builds some names at run time and a hard
failure on those would be a false alarm every time.
"""
import json
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else 'Crimson-Arena'
fail, note = [], []


def read(rel):
    with open(os.path.join(ROOT, rel), encoding='utf-8') as handle:
        return handle.read()


lua = {}
for sub in ('server', 'client', 'shared'):
    for dirpath, _, names in os.walk(os.path.join(ROOT, sub)):
        for name in names:
            if name.endswith('.lua'):
                path = os.path.join(dirpath, name)
                lua[os.path.relpath(path, ROOT)] = open(path, encoding='utf-8').read()

cfg_src = read('config.lua') + read('config.weapons.lua')
app, index, css = read('html/app.js'), read('html/index.html'), read('html/style.css')
manifest = read('fxmanifest.lua')
locales = json.loads(read('locales/en.json'))
alllua = ''.join(lua.values())


def args_of(src, paren):
    """Top-level argument strings of the call whose '(' is at index `paren`.

    Counting commas does not work: a call spanning four lines with a nested
    call in it reads as the wrong arity, which is how the first version of this
    file reported a healthy call site as broken.
    """
    depth, out, cur, i = 0, [], '', paren
    while i < len(src):
        ch = src[i]
        if ch in '([{':
            depth += 1
            if depth == 1:
                i += 1
                continue
        elif ch in ')]}':
            depth -= 1
            if depth == 0:
                out.append(cur)
                return [a for a in out if a.strip()]
        elif ch == ',' and depth == 1:
            out.append(cur)
            cur = ''
            i += 1
            continue
        elif ch in '"\'':
            quote = ch
            cur += ch
            i += 1
            while i < len(src) and src[i] != quote:
                if src[i] == '\\':
                    cur += src[i]
                    i += 1
                cur += src[i]
                i += 1
        if depth >= 1:
            cur += src[i]
        i += 1
    return []


# ----------------------------------------------------------------- locale keys
flat = {}


def flatten(node, prefix=''):
    for key, value in node.items():
        full = prefix + key
        if isinstance(value, dict):
            flatten(value, full + '.')
        else:
            flat[full] = value


flatten(locales)

ACCESSORS = ('locale', 'ArenaNotifyKey', 'ArenaToastKey')
# ArenaNotifyKey(src, key, style, ...) -- the style argument is not a placeholder.
HAS_STYLE_ARG = {'ArenaNotifyKey'}
KEYLIKE = re.compile(r'^\s*[\'"][a-z]')

used, arity_bad, calls = set(), [], 0
for filename, src in lua.items():
    for accessor in ACCESSORS:
        for match in re.finditer(r'\b' + accessor + r'\s*\(', src):
            args = args_of(src, match.end() - 1)
            if not args:
                continue
            keyarg = next((a for a in args if KEYLIKE.match(a)), None)
            if keyarg is None:
                continue
            key = keyarg.strip().strip('\'"')
            # EVERY REAL KEY IS DOTTED, and requiring that is not cosmetic: in
            # a call whose key is a variable, the first string literal is the
            # STYLE argument, and without this test 'error' and 'success' get
            # reported as missing locale keys. They are not keys at all.
            if not re.fullmatch(r'[a-zA-Z0-9_.]+', key) or '.' not in key:
                continue
            used.add(key)
            calls += 1
            text = flat.get(key)
            if isinstance(text, str):
                want = len(re.findall(r'%[sdfqx]', text))
                given = len(args) - args.index(keyarg) - 1
                if accessor in HAS_STYLE_ARG:
                    given -= 1
                if 0 <= given < want:
                    arity_bad.append('%s: %s wants %d, given %d' % (filename, key, want, given))

missing = sorted(k for k in used if k not in flat)
if missing:
    fail.append('locale keys used in code but absent from en.json: ' + ', '.join(missing))
else:
    note.append('%d locale keys defined, %d literal call sites, 0 missing' % (len(flat), calls))

if arity_bad:
    fail.append('locale placeholder mismatch: ' + '; '.join(sorted(set(arity_bad))[:8]))
else:
    note.append('placeholder counts match the string at all %d literal call sites' % calls)

note.append('%d keys have no literal call site (many are built by name at run time)'
            % len(set(flat) - used))

# ----------------------------------------------------------------- config keys
defined = set(re.findall(r'^Config\.([A-Za-z][A-Za-z0-9_]*)\s*=', cfg_src, re.M))
defined |= set(re.findall(r'^\s{4}([A-Za-z][A-Za-z0-9_]*)\s*=', cfg_src, re.M))
readp = set()
for filename, src in lua.items():
    readp.update(re.findall(r'\bConfig\.([A-Za-z][A-Za-z0-9_]*)', src))
unknown = sorted(p for p in readp if p not in defined)
if unknown:
    fail.append('Config keys read but never defined: ' + ', '.join(unknown))
else:
    note.append('%d Config keys read across the resource, all of %d defined ones resolve'
                % (len(readp), len(defined)))

# ------------------------------------------------------------------- NUI names
sent = set(re.findall(r'ArenaUI\.Send\s*\(\s*[\'"]([a-zA-Z0-9_]+)[\'"]', alllua))
sent |= set(re.findall(r'SendNUIMessage\s*\(\s*\{\s*action\s*=\s*[\'"]([a-zA-Z0-9_]+)[\'"]', alllua))
handled = set(re.findall(r'case\s*[\'"]([a-zA-Z0-9_]+)[\'"]', app))
handled |= set(re.findall(r'\.action\s*===?\s*[\'"]([a-zA-Z0-9_]+)[\'"]', app))
handled |= set(re.findall(r'^\s*([a-zA-Z0-9_]+)\s*:\s*function', app, re.M))
if sent:
    orphan = sorted(s for s in sent if s not in handled)
    if orphan:
        note.append('NUI actions with no literal handler (may be dispatched by table): '
                    + ', '.join(orphan))
    else:
        note.append('%d NUI actions sent, every one handled' % len(sent))
else:
    note.append('NUI actions are pushed through a helper by variable, so they are not '
                'checkable by name here -- nuicontract_spec covers them')

posted = set(re.findall(r'\bpost\s*\(\s*[\'"]([a-zA-Z0-9_]+)[\'"]', app))
registered = set(re.findall(r'RegisterNUICallback\s*\(\s*[\'"]([a-zA-Z0-9_]+)[\'"]', alllua))
# Every callback here goes through a local `register` wrapper that adds the
# pcall and the reply, so the bare native appears exactly once.
registered |= set(re.findall(r'^\s*register\s*\(\s*[\'"]([a-zA-Z0-9_]+)[\'"]', alllua, re.M))
missing_cb = sorted(p for p in posted if p not in registered)
if missing_cb:
    fail.append('the panel posts to callbacks the client never registers: ' + ', '.join(missing_cb))
else:
    note.append('%d NUI callbacks posted by the panel, all of %d registered ones resolve'
                % (len(posted), len(registered)))
dead_cb = sorted(r for r in registered if r not in posted)
if dead_cb:
    note.append('registered NUI callbacks the panel never posts to: ' + ', '.join(dead_cb))

# --------------------------------------------------------------------- HTML ids
ids = set(re.findall(r'id="([a-zA-Z0-9_-]+)"', index))
# A literal name only. `byId('tab-' + name)` is built at run time and cannot be
# checked from here; treating it as a missing id is a false alarm.
looked = set(re.findall(r'\b(?:byId|getElementById)\s*\(\s*[\'"]([a-zA-Z0-9_-]+)[\'"]\s*\)', app))
absent = sorted(i for i in looked if i not in ids)
if absent:
    fail.append('app.js looks up ids index.html does not contain: ' + ', '.join(absent))
else:
    note.append('%d element ids defined, %d looked up by literal name, all present'
                % (len(ids), len(looked)))

# ------------------------------------------------------------------------- CSS
classes = set(re.findall(r'\.([a-zA-Z][a-zA-Z0-9_-]*)\s*[,{:]', css))
used_cls = set()
for chunk in re.findall(r'class="([^"]+)"', index):
    used_cls.update(chunk.split())
used_cls |= set(re.findall(r'classList\.(?:add|remove|toggle)\s*\(\s*[\'"]([a-zA-Z0-9_-]+)[\'"]', app))
unstyled = sorted(c for c in used_cls if c and c not in classes)
if unstyled:
    note.append('classes used with no rule in style.css: ' + ', '.join(unstyled[:12]))
else:
    note.append('%d CSS classes defined; every class used in markup has a rule' % len(classes))

# ------------------------------------------------------------------ fxmanifest
listed = set(re.findall(r'[\'"]([A-Za-z0-9_./-]+\.(?:lua|js|css|html|png|json))[\'"]', manifest))
gone = sorted(r for r in listed if not os.path.exists(os.path.join(ROOT, r)))
if gone:
    fail.append('fxmanifest.lua lists files that do not exist: ' + ', '.join(gone))
else:
    note.append('%d manifest entries, every one present on disk' % len(listed))

on_disk = set()
for dirpath, _, names in os.walk(os.path.join(ROOT, 'html')):
    for name in names:
        on_disk.add(os.path.relpath(os.path.join(dirpath, name), ROOT))
unlisted = sorted(f for f in on_disk if f not in listed)
if unlisted:
    fail.append('files in html/ the manifest does not ship: ' + ', '.join(unlisted))
else:
    note.append('%d files in html/, all shipped by the manifest' % len(on_disk))

# -------------------------------------------------------- config.lua line map
# The map at the top of config.lua sends a non-coder to a line number. A stale
# one sends them to the wrong setting, which is worse than having no map.
cfg_lines = read('config.lua').split('\n')
bad_map, mapped = [], 0
for line in cfg_lines[:50]:
    match = re.match(r'^\s+(\d+)\s+([A-Z][A-Za-z]*)\s{2,}', line)
    if not match:
        continue
    want, key = int(match.group(1)), match.group(2)
    mapped += 1
    for lineno, text in enumerate(cfg_lines, 1):
        if re.match(r'^Config\.' + re.escape(key) + r'\s*=', text):
            if lineno != want:
                bad_map.append('%s mapped to %d, really on %d' % (key, want, lineno))
            break
if bad_map:
    fail.append('config.lua line map is stale: ' + '; '.join(bad_map))
elif mapped:
    note.append('config.lua line map checked, all %d entries point at the right line' % mapped)
else:
    fail.append('config.lua line map: found no entries to check -- the format has changed')

for line in note:
    print('  ok   ' + line)
for line in fail:
    print('  FAIL ' + line)
print()
print('ALL CONTRACTS HOLD' if not fail else ('%d CONTRACT(S) BROKEN' % len(fail)))
sys.exit(1 if fail else 0)
