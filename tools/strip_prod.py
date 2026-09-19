#!/usr/bin/env python3
"""
The production strip, at the agreed defaults.

WHAT COMES OUT: every comment in a code file.
WHAT STAYS:     any comment BLOCK that carries a warning, plus one new
                header line per file.

THE UNIT IS THE BLOCK, NOT THE LINE, and it has to be. A warning is a
sentence inside a paragraph -- "these two rules disagree ON PURPOSE, and
that is the thing to keep in mind before tidying either into the other" --
and keeping that line while deleting the six around it leaves a fragment
that is worse than either keeping or dropping the lot. So a run of
consecutive comment lines is kept or dropped whole, on whether anything in
it warns.

FINDING THE COMMENTS IS A SCANNER'S JOB, not a regular expression's. A `--`
inside a string is not a comment; nor is a `//` inside a template literal,
nor a `/` that begins a regex. This walks the file character by character
with the quoting rules in hand and records the LINE NUMBERS its comments
occupy, so the second pass can work in whole lines without ever having to
guess.

Nothing here is trusted on its own: tools/verify_lua_identical.sh and
tools/verify_web_identical.py are written separately and compare the
executable content afterwards.

    usage: strip_prod.py [--header "one line"] <file> [<file> ...]
"""
import sys, os, re

# A comment block survives if any line in it says "somebody thought about this
# and the answer is not the obvious one".
#
# TWO LISTS, AND THE SPLIT IS THE WHOLE ACCURACY OF THIS TOOL. The first
# version was one case-insensitive list that included `never `, `cannot ` and
# `used to `, and it kept 10,560 comment lines out of 18,654 -- 57%, against a
# stated intention of keeping only the warnings. Those three words are not
# warnings; they are how ordinary English explains anything ("a bucket cannot
# hide a client from itself", "this never reaches a player"). And `used to `
# is the marker of HISTORY, which is exactly the category being removed.
#
# What separates the two in this codebase is CASE. A warning aimed at the next
# editor is shouted -- DO NOT, NEVER, CANNOT, THE DEFECT -- because that is the
# house style for a sentence that must not be skimmed past. So `never` in a
# sentence is prose and `NEVER` is an instruction, and only the second is kept.
#
# The lower-case list is for phrases that are warnings whatever their case:
# nothing writes "deliberate" or "is not an oversight" except to tell you that
# what you are looking at was chosen.
WARNS_ANY_CASE = re.compile(
    r'(on purpose|deliberate|must not|do not |is not an oversight|disagree'
    r'|before .*tidy|none of them can be read)', re.I)

WARNS_SHOUTED = re.compile(
    r'(NEVER |CANNOT |DO NOT|THE DEFECT|THE BUG|THE REGRESSION|THE REPORT'
    r'|IN A PLAYER)')


# WARNINGS A REVIEW FOUND THAT THE RULE ABOVE MISSED.
#
# THIS IS A LIST OF EXCEPTIONS AND IT IS HONEST ABOUT BEING ONE. The obvious
# generalisation -- "a shouted clause is a warning" -- was tried and measured
# and does not work here, because the house style shouts everything: section
# headings, paragraph openers and emphasis all look exactly like a warning to
# any rule that counts capital letters. At three capitalised words in a row it
# keeps 74% of all commentary; at seven it starts dropping real warnings. There
# is no threshold that separates them, so there is no rule to write.
#
# What is left is judgement, and judgement does not compress into a regex. Each
# phrase below identifies one comment block that a reviewer read and decided the
# next editor cannot safely be without -- an invariant, a fixed ordering, a
# guard that looks redundant and is not. They are quoted from the block itself
# so that if the block is ever rewritten the phrase stops matching and the block
# is dropped, which is the right failure: a stale exception should lapse rather
# than protect text that no longer says what it said.
REVIEWED = (
    'WHY THIS IS NOT `ipairs`',              # ammo.lua: slot-keyed inventory reads
    'match.players` is keyed by SERVER ID',  # lobby.lua: the same trap
    'THE ORDER OF THESE FIVE IS FIXED',      # match.lua: End()'s settlement order
    'AFTER THE EXITS, WHICH IS THE WHOLE POINT',  # match.lua: ArenaAmmo.Clear's position
    'THE LIST OF TYPES IS THE WHOLE POINT',  # arena.lua: vectors are their own type
    'THE INVARIANT',                         # betting.lua: the escrow contract
    'THE ROSTER THE ROUND STARTED WITH',     # match.lua: the latched ladder divisor
    'TWO VICTIMS, ALWAYS',                   # match.lua: the max(2) that is the guard
    'WHY THIS DOES NOT JUST READ THE RETURN VALUE',  # betting.lua: nil means success
    'A STASH THAT READ EMPTY IS NOT A STASH THAT WAS EMPTY',  # ammo.lua, both sites
    'THIS IS THE ONE THAT WAS MISSING',      # ammo.lua: the swapItems IN direction
    'UNGUARDED IT WOULD BE FATAL',           # match.lua (client): the per-frame thread
    'SERVER IDS ARE RECYCLED',               # ammo.lua: ownRecord
    'A MISSING PLAYER IS NOT A MISMATCH',    # ammo.lua: the other branch of it
)


def warns(block):
    """Does this run of comment lines carry a warning?

    THE BLOCK IS FLATTENED FIRST, and that is not tidiness. Comment text wraps,
    so a phrase this is looking for can straddle a line break -- `ammo.lua`
    really did say "kept on\n--- purpose", and a rule reading raw lines saw
    neither "on purpose" nor anything else it knew. Stripping the comment
    markers and collapsing the whitespace makes the block one sentence again,
    which is what it is.
    """
    flat = re.sub(r'\s+', ' ', re.sub(r'(?m)^\s*(--+\[?=*\[?|//+|/\*+|\*+/?|#)', ' ', block))
    if WARNS_ANY_CASE.search(flat) or WARNS_SHOUTED.search(flat):
        return True
    return any(phrase in flat for phrase in REVIEWED)


def comment_lines_lua(src):
    """Two answers per file: which lines a comment touches, and how many
    characters of REAL CODE each line holds.

    The second is what makes the block rule safe. A long comment's interior
    lines do not begin with `--` -- they are ordinary prose -- so a rule that
    looked at the first characters of a line left them behind as bare text
    once the opening `--[[` was gone, and the file stopped parsing. Counting
    code instead asks the only question that matters: is there anything on
    this line the machine would run."""
    spans, code, i, n, line = [], {}, 0, len(src), 0

    def mark(ch):
        if not ch.isspace():
            code[line] = code.get(line, 0) + 1

    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
        elif c in '\'"':
            quote, i = c, i + 1
            mark(quote)
            while i < n and src[i] != quote:
                if src[i] == '\\':
                    i += 1
                elif src[i] == '\n':
                    line += 1
                mark(src[i])
                i += 1
            i += 1
        elif c == '[' and _long(src, i) is not None:
            level = _long(src, i)
            close = ']' + '=' * level + ']'
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            for k in range(line, line + src.count('\n', i, j) + 1):
                code[k] = code.get(k, 0) + 1
            line += src.count('\n', i, j)
            i = j
        elif src.startswith('--', i):
            level = _long(src, i + 2)
            if level is None:
                j = src.find('\n', i)
                j = n if j < 0 else j
            else:
                close = ']' + '=' * level + ']'
                j = src.find(close, i + 2)
                j = n if j < 0 else j + len(close)
            spans.append((line, line + src.count('\n', i, j)))
            line += src.count('\n', i, j)
            i = j
        else:
            mark(c)
            i += 1
    return spans, code


def _long(src, i):
    if i >= len(src) or src[i] != '[':
        return None
    j, level = i + 1, 0
    while j < len(src) and src[j] == '=':
        level += 1
        j += 1
    return level if j < len(src) and src[j] == '[' else None


def comment_lines_js(src):
    """The same two answers for the web files, by the same reasoning as
    comment_lines_lua: which lines a comment touches, and how much real code
    sits on each. A `/* ... */` spanning six lines has four interior lines of
    plain prose in the middle, and only the code count can tell those apart
    from a line of script."""
    spans, code, i, n, line, prev = [], {}, 0, len(src), 0, ''

    def mark(ch):
        if not ch.isspace():
            code[line] = code.get(line, 0) + 1

    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
        elif c in '\'"`':
            quote, i = c, i + 1
            mark(quote)
            while i < n and src[i] != quote:
                if src[i] == '\\':
                    i += 1
                elif src[i] == '\n':
                    line += 1
                mark(src[i])
                i += 1
            i += 1
            prev = 'str'
        elif src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j < 0 else j
            spans.append((line, line))
            i = j
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            spans.append((line, line + src.count('\n', i, j)))
            line += src.count('\n', i, j)
            i = j
        elif c == '/' and prev in ('(', ',', '=', ':', '[', '!', '&', '|',
                                   '?', '{', '}', ';', 'op', ''):
            i0 = i
            j, klass = i + 1, False
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == '[':
                    klass = True
                elif src[j] == ']':
                    klass = False
                elif src[j] == '/' and not klass:
                    j += 1
                    break
                elif src[j] == '\n':
                    break
                j += 1
            for k in range(line, line + src.count('\n', i0, j) + 1):
                code[k] = code.get(k, 0) + 1
            i = j
            prev = 'str'
        else:
            if not c.isspace():
                prev = 'op' if (c.isalnum() or c in '_$') else c
                mark(c)
            i += 1
    return spans, code


def comment_lines_html(src):
    """The markup files, on the same contract as the other two scanners.

    `<!-- ... -->` is the only comment form here -- UNLESS the page carries an
    inline <script> or <style>, where JavaScript and CSS comment rules take
    over inside the block. This page has neither, and rather than half-write a
    scanner for a case that does not exist, the function REFUSES a file that
    grows one. A tool that quietly does the wrong thing to a new file is worse
    than one that stops.
    """
    for tag in ('script', 'style'):
        for m in re.finditer(r'<\s*%s\b[^>]*>' % tag, src, re.I):
            close = re.search(r'<\s*/\s*%s\s*>' % tag, src[m.end():], re.I)
            body = src[m.end():m.end() + close.start()] if close else src[m.end():]
            if body.strip():
                raise SystemExit(
                    'inline <%s> with content -- this scanner understands '
                    'only <!-- --> and would corrupt it' % tag)
    spans, code, i, n, line = [], {}, 0, len(src), 0
    while i < n:
        if src[i] == '\n':
            line += 1
            i += 1
        elif src.startswith('<!--', i):
            j = src.find('-->', i + 4)
            j = n if j < 0 else j + 3
            spans.append((line, line + src.count('\n', i, j)))
            line += src.count('\n', i, j)
            i = j
        else:
            if not src[i].isspace():
                code[line] = code.get(line, 0) + 1
            i += 1
    return spans, code


def strip(path, header=None):
    with open(path, encoding='utf-8') as fh:
        src = fh.read()
    ext = os.path.splitext(path)[1]
    scan = {'.lua': comment_lines_lua,
            '.html': comment_lines_html}.get(ext, comment_lines_js)
    spans, code = scan(src)
    lines = src.split('\n')

    # THE UNIT OF REMOVAL IS ONE WHOLE COMMENT. A comment that opens after
    # code -- `local x = 1 --[[ note` and three lines of prose under it -- has
    # a first line that must stay and interior lines that look removable on
    # their own. Removing those leaves `local x = 1 --[[ note` with nothing to
    # close it, and the file no longer parses. So a comment is droppable only
    # when EVERY line it spans is free of code, and then all of it goes.
    marked = set()
    for start, end in spans:
        if all(code.get(k, 0) == 0 for k in range(start, end + 1)):
            marked.update(range(start, end + 1))

    # A line of code with a note after it keeps both: the comment's span
    # touches a line holding code, so the whole comment stayed above.
    #
    # Note that this is asked of the SCANNER, never of the text. Reading the
    # first characters of a line looks equivalent and is not: the middle lines
    # of a long comment are bare prose starting with no marker at all, and a
    # rule that went by appearance left them standing as code once the opening
    # delimiter was cut -- which is how server/match.lua stopped parsing on
    # the first dry run.
    def pure(idx):
        return idx in marked

    keep = [True] * len(lines)
    i = 0
    while i < len(lines):
        if not pure(i):
            i += 1
            continue
        j = i
        while j < len(lines) and pure(j):
            j += 1
        block = '\n'.join(lines[i:j])
        if not warns(block):
            for k in range(i, j):
                keep[k] = False
        i = j

    out = [l for idx, l in enumerate(lines) if keep[idx]]

    # One blank line at most, no trailing whitespace.
    tidy, blanks = [], 0
    for l in out:
        l = l.rstrip()
        if l == '':
            blanks += 1
            if blanks > 1:
                continue
        else:
            blanks = 0
        tidy.append(l)
    while tidy and tidy[0] == '':
        tidy.pop(0)
    while tidy and tidy[-1] == '':
        tidy.pop()

    # THE HEADER IS WRITTEN IN THE FILE'S OWN COMMENT SYNTAX, and it has to
    # be spelled out per language rather than assumed. `//` is a comment in
    # JavaScript and in neither CSS nor HTML: in a stylesheet the parser reads
    # it as the start of a selector and swallows the first real rule with it,
    # and in a page it renders as visible text above the document. Both were
    # produced by a first pass that treated "not Lua" as "JavaScript".
    if header:
        if ext == '.lua':
            note = ['-- %s' % header, '']
        elif ext == '.css':
            note = ['/* %s */' % header, '']
        elif ext == '.html':
            note = ['<!-- %s -->' % header, '']
        else:
            note = ['// %s' % header, '']

        # A page must open on its doctype, so the note goes under it.
        at = 0
        if ext == '.html':
            for idx, l in enumerate(tidy[:5]):
                if l.strip().lower().startswith('<!doctype'):
                    at = idx + 1
                    break
        tidy = tidy[:at] + note + tidy[at:]

    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(tidy) + '\n')
    return len(lines), len(tidy)


def main(argv):
    header = None
    args = []
    i = 1
    while i < len(argv):
        if argv[i] == '--header':
            header = argv[i + 1]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    for path in args:
        before, after = strip(path, header)
        print('%-32s %6d -> %6d lines' % (path, before, after))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
