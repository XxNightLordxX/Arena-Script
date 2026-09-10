#!/usr/bin/env python3
"""
Removes comments from the shipping source files.

It is a SCANNER, not a set of regular expressions, because the hard part of
this job is knowing when a `--` or a `//` is not a comment at all:

    Lua   long comments --[[ ]] and --[==[ ]==], long strings [[ ]], and a
          `--` sitting inside an ordinary quoted string.
    JS    // and /* */, but also template literals, and REGEX literals -- a
          `/` that begins a pattern rather than a comment. Told apart by what
          came before it, which is the only way it can be told apart.
    CSS   /* */ only.
    HTML  <!-- -->, but never inside a <script> or <style> block.

Nothing here is trusted on its own. Every file it writes is checked
afterwards by tools/verify_lua_identical.sh (bytecode) or
tools/verify_web_identical.py (tokens), which are written independently and
would fail loudly if this scanner ever ate a line of real code.

    usage: strip_comments.py <file> [<file> ...]     rewrites in place
           strip_comments.py --keep-header <file>    keeps the first block
"""
import sys, os

def strip_lua(src, keep_header=False):
    out, i, n = [], 0, len(src)
    header_done = not keep_header
    while i < n:
        c = src[i]
        if c in '\'"':
            quote, j = c, i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == quote:
                    j += 1
                    break
                if src[j] == '\n':
                    break
                j += 1
            out.append(src[i:j]); i = j
        elif src.startswith('[', i) and _long_open(src, i):
            level = _long_open(src, i)
            close = ']' + '=' * level + ']'
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(src[i:j]); i = j
        elif src.startswith('--', i):
            level = _long_open(src, i + 2)
            if level is not None:
                close = ']' + '=' * level + ']'
                j = src.find(close, i + 2)
                j = n if j < 0 else j + len(close)
                if not header_done:
                    out.append(src[i:j]); header_done = True
                i = j
            else:
                j = src.find('\n', i)
                j = n if j < 0 else j
                i = j
                # a line that was only a comment loses its newline too
                if out and out[-1].endswith('\n') and _blank_tail(out):
                    _drop_blank_tail(out)
                    if i < n:
                        i += 1
        else:
            out.append(c); i += 1
    return ''.join(out)

def _long_open(src, i):
    """Level of a Lua long bracket starting at i, or None."""
    if i >= len(src) or src[i] != '[':
        return None
    j = i + 1
    level = 0
    while j < len(src) and src[j] == '=':
        level += 1
        j += 1
    return level if j < len(src) and src[j] == '[' else None

def _blank_tail(out):
    tail = ''.join(out[-40:])
    line = tail.rsplit('\n', 1)[-1]
    return line.strip() == ''

def _drop_blank_tail(out):
    """Remove the run of spaces/tabs that preceded a whole-line comment."""
    while out and out[-1] and out[-1][-1] in ' \t':
        if len(out[-1]) == 1:
            out.pop()
        else:
            out[-1] = out[-1][:-1]

def strip_js(src, keep_header=False):
    out, i, n = [], 0, len(src)
    header_done = not keep_header
    prev = ''
    while i < n:
        c = src[i]
        if c in '\'"`':
            quote, j = c, i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(src[i:j]); prev = 'str'; i = j
        elif src.startswith('//', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            if out and _blank_tail(out):
                _drop_blank_tail(out)
                if i < n:
                    i += 1
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            j = n if j < 0 else j + 2
            if not header_done:
                out.append(src[i:j]); header_done = True
            elif out and _blank_tail(out) and src[j:j + 1] == '\n':
                _drop_blank_tail(out)
                j += 1
            i = j
        elif c == '/' and prev in ('(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', 'return', 'op', ''):
            # a regex literal, not a comment: told apart by what precedes it
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
                    while j < n and src[j].isalpha():
                        j += 1
                    break
                elif src[j] == '\n':
                    break
                j += 1
            out.append(src[i:j]); prev = 'str'; i = j
        else:
            out.append(c)
            if not c.isspace():
                prev = c if not (c.isalnum() or c in '_$') else 'op'
            i += 1
    return ''.join(out)

def strip_css(src):
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            if out and _blank_tail(out) and src[i:i + 1] == '\n':
                _drop_blank_tail(out)
                i += 1
        else:
            out.append(src[i]); i += 1
    return ''.join(out)

def strip_html(src):
    out, i, n = [], 0, len(src)
    while i < n:
        if src.startswith('<!--', i):
            j = src.find('-->', i + 4)
            i = n if j < 0 else j + 3
            if out and _blank_tail(out) and src[i:i + 1] == '\n':
                _drop_blank_tail(out)
                i += 1
        else:
            out.append(src[i]); i += 1
    return ''.join(out)

def tidy(text):
    """At most one blank line in a row, and no trailing whitespace."""
    lines = [l.rstrip() for l in text.split('\n')]
    out, blanks = [], 0
    for l in lines:
        if l == '':
            blanks += 1
            if blanks > 1:
                continue
        else:
            blanks = 0
        out.append(l)
    while out and out[-1] == '':
        out.pop()
    return '\n'.join(out) + '\n'

STRIPPERS = {'.lua': strip_lua, '.js': strip_js}

def main(argv):
    keep_header = '--keep-header' in argv
    paths = [a for a in argv[1:] if not a.startswith('--')]
    for path in paths:
        ext = os.path.splitext(path)[1]
        with open(path, encoding='utf-8') as fh:
            src = fh.read()
        if ext in ('.lua', '.js'):
            done = STRIPPERS[ext](src, keep_header)
        elif ext == '.css':
            done = strip_css(src)
        elif ext == '.html':
            done = strip_html(src)
        else:
            print('skipped (no stripper): %s' % path)
            continue
        done = tidy(done)
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(done)
        print('%-32s %6d -> %6d lines' % (path, src.count('\n') + 1, done.count('\n')))
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
