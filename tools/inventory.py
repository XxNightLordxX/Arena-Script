#!/usr/bin/env python3
"""
SAFETY CHECK 3 OF 4 -- NOTHING THE SERVER DEPENDS ON WENT MISSING

Bytecode and tokens prove the code is the same. This proves the SURFACE is
the same, in the terms a server operator would recognise:

    functions      every top-level function each file defines
    exports        every exports('name', ...) other resources call
    net events     every client -> server event the server listens for
    client events  every server -> client event the server sends
    commands       every /command registered
    locale keys    every line of text a player can be shown
    config keys    every setting an operator can write
    panel ids      every element the browser panel looks up by id
    hooks          every ox_inventory hook registered

Written out as a plain list and compared line by line, so the failure reads
"this locale key is gone" rather than "a hash changed".

    usage: inventory.py <dir>                  print the inventory
           inventory.py <before> <after>       compare two trees

HOW THE CONFIG KEYS ARE FOUND, AND WHY IT IS NOT A GREP. The first version of
this file matched `^\\s{0,12}(name) =` in config.lua alone. That answered with
a bare list of leaf names and it under-reported four ways at once: it never
opened config.weapons.lua, so no weapon was in the inventory at all; it could
not see a top-level `Config.Arenas = {` because that line's key is written
`Config.Arenas` and not `Arenas`; it could not see a bracketed key, which is
how every arena and every mode is written (`['trailerpark'] = {`); and it
stopped at twelve spaces of indent, which is shallower than most of the file.
Deleting a whole arena, a whole mode or a whole weapon produced NO lost line.
A check that cannot see a deletion does not prove a deletion did not happen,
and this one is quoted as a proof.

So the config files are PARSED instead. Every `config*.lua` in the tree is
read as the pure data it is -- these files contain assignments and table
constructors and nothing else -- and every key is written out as the full
path an operator would type:

    config-key Config.Arenas.trailerpark.boundary.radius

A LIST ENTRY IS ADDRESSED BY ITS OWN `key`, NOT BY ITS POSITION. The weapons
are a list, so numbering them would make deleting the first weapon read as 95
changes rather than one, and the one line that matters -- the weapon that is
gone -- would be buried:

    config-key Config.Loadouts.weapons[key=appistol].ammo.max

List entries with no `key` (a list of numbers, say) are numbered, so that
shortening one is still a lost line.

VALUES ARE DELIBERATELY NOT IN THE INVENTORY. This is a check for things that
went MISSING, and the owner tunes numbers on purpose; a changed ammo count is
not a lost dependency and must not read as one. The one exception is a list
entry's `key`, which is not a setting but the entry's name.
"""
import sys, os, re, json

def read(p):
    with open(p, encoding='utf-8', errors='ignore') as fh:
        return fh.read()

def walk(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ('tests', '.git')]
        for f in sorted(files):
            if os.path.splitext(f)[1] in exts:
                yield os.path.relpath(os.path.join(base, f), root), read(os.path.join(base, f))

def flatten(d, prefix=''):
    out = []
    for k, v in d.items():
        key = prefix + k
        out.extend(flatten(v, key + '.') if isinstance(v, dict) else [key])
    return out

# ---------------------------------------------------------------------------
# The config files, read as data.
# ---------------------------------------------------------------------------

LONG_BRACKET = re.compile(r'\[(=*)\[')
PUNCT3 = ('...',)
PUNCT2 = ('..', '==', '~=', '<=', '>=', '::', '//', '<<', '>>')

def lua_tokens(src):
    """Lua source -> [(kind, text)], comments and whitespace dropped.

    Long comments and long strings both use the [==[ ... ]==] form and the
    tokeniser has to count the equals signs to find the right close: `]]`
    inside a `[==[` string does not end it.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
            continue
        if src.startswith('--', i):
            m = LONG_BRACKET.match(src, i + 2)
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, m.end())
                i = n if j < 0 else j + len(close)
            else:
                j = src.find('\n', i)
                i = n if j < 0 else j + 1
            continue
        m = LONG_BRACKET.match(src, i)
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, m.end())
            out.append(('str', src[m.end():n if j < 0 else j]))
            i = n if j < 0 else j + len(close)
            continue
        if c in '"\'':
            j, buf = i + 1, []
            while j < n:
                if src[j] == '\\':
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if src[j] == c:
                    j += 1
                    break
                buf.append(src[j])
                j += 1
            out.append(('str', ''.join(buf)))
            i = j
            continue
        if c.isalpha() or c == '_':
            j = i
            while j < n and (src[j].isalnum() or src[j] == '_'):
                j += 1
            out.append(('name', src[i:j]))
            i = j
            continue
        if c.isdigit() or (c == '.' and i + 1 < n and src[i + 1].isdigit()):
            j = i
            while j < n and (src[j].isalnum() or src[j] == '.'
                             or (src[j] in '+-' and src[j - 1] in 'eE')):
                j += 1
            out.append(('num', src[i:j]))
            i = j
            continue
        if src[i:i + 3] in PUNCT3:
            out.append(('punct', src[i:i + 3]))
            i += 3
            continue
        if src[i:i + 2] in PUNCT2:
            out.append(('punct', src[i:i + 2]))
            i += 2
            continue
        out.append(('punct', c))
        i += 1
    return out

class Cursor:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.t[j] if 0 <= j < len(self.t) else (None, None)

    def take(self, n=1):
        self.i += n

def assignment_ahead(cur):
    """`Config.Loadouts.weapons =` -> ('Config.Loadouts.weapons', tokens).

    Answers None when the cursor is not on a statement of that shape, which
    is how the reader steps over anything these files are not supposed to
    contain rather than guessing at it.
    """
    if cur.peek()[0] != 'name':
        return None
    parts, k = [cur.peek()[1]], 1
    while True:
        if cur.peek(k) == ('punct', '.') and cur.peek(k + 1)[0] == 'name':
            parts.append(cur.peek(k + 1)[1])
            k += 2
        elif cur.peek(k) == ('punct', '[') and cur.peek(k + 1)[0] == 'str' \
                and cur.peek(k + 2) == ('punct', ']'):
            parts.append(cur.peek(k + 1)[1])
            k += 3
        else:
            break
    if cur.peek(k) == ('punct', '='):
        return '.'.join(parts), k + 1
    return None

def parse_value(cur, toplevel=False):
    """A table -> ('table', [(key or None, value), ...]); anything else ->
    ('scalar', the string literal if that is all it was, else None)."""
    if cur.peek() == ('punct', '{'):
        return parse_table(cur)
    depth, seen, literal = 0, 0, None
    while True:
        kind, text = cur.peek()
        if kind is None:
            break
        if depth == 0:
            if kind == 'punct' and text in (',', ';', '}'):
                break
            if toplevel and assignment_ahead(cur):
                break
        if kind == 'punct':
            if text in '([{':
                depth += 1
            elif text in ')]}':
                if depth == 0:
                    break
                depth -= 1
        seen += 1
        literal = text if (kind == 'str' and seen == 1) else None
        cur.take()
    return ('scalar', literal)

def parse_table(cur):
    cur.take()
    entries = []
    while True:
        kind, text = cur.peek()
        if kind is None:
            break
        if kind == 'punct' and text == '}':
            cur.take()
            break
        if kind == 'punct' and text in (',', ';'):
            cur.take()
            continue
        key = None
        if kind == 'name' and cur.peek(1) == ('punct', '='):
            key = text
            cur.take(2)
        elif kind == 'punct' and text == '[' and cur.peek(2) == ('punct', ']') \
                and cur.peek(3) == ('punct', '='):
            kind2, text2 = cur.peek(1)
            key = text2 if kind2 == 'str' else '[%s]' % text2
            cur.take(4)
        entries.append((key, parse_value(cur)))
    return ('table', entries)

def parse_config(src):
    cur, out = Cursor(lua_tokens(src)), []
    while cur.peek()[0] is not None:
        found = assignment_ahead(cur)
        if not found:
            cur.take()
            continue
        path, skip = found
        cur.take(skip)
        out.append((path, parse_value(cur, toplevel=True)))
    return out

def entry_label(value, index):
    if value[0] == 'table':
        for wanted in ('key', 'name'):
            for k, v in value[1]:
                if k == wanted and v[0] == 'scalar' and v[1]:
                    return '[%s=%s]' % (wanted, v[1])
    return '[%d]' % index

def emit_keys(path, value, out):
    out.append(path)
    if value[0] != 'table':
        return
    index = 0
    for k, v in value[1]:
        if k is None:
            index += 1
            child = path + entry_label(v, index)
        else:
            child = path + '.' + k
        emit_keys(child, v, out)

def config_keys(root):
    """Every key in every config*.lua in the tree, as a full dotted path."""
    out = []
    for rel, src in walk(root, {'.lua'}):
        if not os.path.basename(rel).startswith('config.'):
            continue
        for path, value in parse_config(src):
            emit_keys(path, value, out)
    return out

def inventory(root):
    lines = []
    for rel, src in walk(root, {'.lua'}):
        for name in re.findall(r'^function\s+([A-Za-z_][\w.]*)\s*\(', src, re.M):
            lines.append('function   %s  %s' % (rel, name))
        for name in re.findall(r"exports\(\s*'([^']+)'", src):
            lines.append('export     %s  %s' % (rel, name))
        for name in re.findall(r"onClient\(\s*'([^']+)'", src):
            lines.append('net-in     %s  %s' % (rel, name))
        for name in re.findall(r"RegisterNetEvent\(\s*'([^']+)'", src):
            lines.append('net-reg    %s  %s' % (rel, name))
        for name in re.findall(r"TriggerClientEvent\(\s*'([^']+)'", src):
            lines.append('net-out    %s  %s' % (rel, name))
        for name in re.findall(r"RegisterCommand\(\s*'([^']+)'", src):
            lines.append('command    %s  %s' % (rel, name))
        for name in re.findall(r"registerHook\(\s*'([^']+)'", src):
            lines.append('hook       %s  %s' % (rel, name))
        for name in re.findall(r"locale\(\s*'([^']+)'", src):
            lines.append('locale-use %s' % name)
    for rel, src in walk(root, {'.js'}):
        for name in re.findall(r"post\(\s*'([^']+)'", src):
            lines.append('nui-post   %s  %s' % (rel, name))
        for name in re.findall(r"byId\(\s*'([^']+)'", src):
            lines.append('panel-id   %s' % name)
        for name in re.findall(r"bind\(\s*'([^']+)'", src):
            lines.append('panel-bind %s' % name)
    for rel, src in walk(root, {'.html'}):
        for name in re.findall(r'id="([^"]+)"', src):
            lines.append('html-id    %s' % name)
    loc = os.path.join(root, 'locales', 'en.json')
    if os.path.isfile(loc):
        for key in flatten(json.loads(read(loc))):
            lines.append('locale-key %s' % key)
    for key in config_keys(root):
        lines.append('config-key %s' % key)
    return sorted(set(lines))

def main(argv):
    if len(argv) == 2:
        print('\n'.join(inventory(argv[1])))
        return 0
    before, after = inventory(argv[1]), inventory(argv[2])
    gone = [l for l in before if l not in set(after)]
    new = [l for l in after if l not in set(before)]
    for l in gone:
        print('LOST  %s' % l)
    for l in new:
        print('NEW   %s' % l)
    print('-' * 63)
    print('%d entries before, %d after: %d lost, %d new' % (len(before), len(after), len(gone), len(new)))
    print('PASS -- the whole surface survived' if not gone else 'FAIL -- something a server depends on is gone')
    return 1 if gone else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
