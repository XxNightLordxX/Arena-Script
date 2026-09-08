#!/usr/bin/env python3
"""
SAFETY CHECK 2 OF 4 -- THE PANEL'S CODE IS PROVABLY UNCHANGED

There is no compiler for the browser files the way there is for Lua, so this
does the next best thing: it reads app.js, style.css and index.html as a
stream of TOKENS -- names, numbers, strings, punctuation -- and compares the
two streams.

Why that is worth something: the tokeniser here is written independently of
whatever removes the comments. It does not trust a stripper's idea of where a
comment ends; it re-derives it from the file, character by character, tracking
quotes and escapes so that a `//` inside a string is not mistaken for a
comment. If the stripper ever ate a line of real code, the token streams
diverge and this says exactly where.

Whitespace and comments produce no tokens at all, so reformatting is
invisible here -- which is the point. Everything that is not a comment is
visible.

    usage: verify_web_identical.py <before-dir> <after-dir>
"""
import sys, os, re

def tokens_js(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
        elif src.startswith('//', i):
            i = src.find('\n', i)
            if i < 0: break
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
        elif c in '\'"`':
            quote, j = c, i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(('str', src[i:j]))
            i = j
        elif c.isalpha() or c in '_$':
            j = i
            while j < n and (src[j].isalnum() or src[j] in '_$'):
                j += 1
            out.append(('name', src[i:j]))
            i = j
        elif c.isdigit():
            j = i
            while j < n and (src[j].isalnum() or src[j] == '.'):
                j += 1
            out.append(('num', src[i:j]))
            i = j
        else:
            out.append(('punct', c))
            i += 1
    return out

def tokens_css(src):
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    return [('t', t) for t in re.findall(r'[A-Za-z_#.\-][\w#.\-]*|[{}:;,()>+~*\[\]="\']|\S', src)]

def tokens_html(src):
    src = re.sub(r'<!--.*?-->', ' ', src, flags=re.S)
    return [('t', t) for t in re.findall(r'<[^>]+>|[^<\s][^<]*', src)]

READERS = {'.js': tokens_js, '.css': tokens_css, '.html': tokens_html}

def read(path):
    with open(path, encoding='utf-8', errors='ignore') as fh:
        return fh.read()

def main(before, after):
    fail = checked = missing = 0
    for root, dirs, files in os.walk(before):
        dirs[:] = [d for d in dirs if d not in ('tests', '.git')]
        for f in sorted(files):
            ext = os.path.splitext(f)[1]
            if ext not in READERS:
                continue
            rel = os.path.relpath(os.path.join(root, f), before)
            b = os.path.join(after, rel)
            if not os.path.isfile(b):
                print('MISSING   %s  -- the file is gone from the stripped tree' % rel)
                missing += 1
                continue
            ta = READERS[ext](read(os.path.join(root, f)))
            tb = READERS[ext](read(b))
            checked += 1
            if ta != tb:
                fail += 1
                print('CHANGED   %s  (%d tokens before, %d after)' % (rel, len(ta), len(tb)))
                for k in range(min(len(ta), len(tb))):
                    if ta[k] != tb[k]:
                        print('          first difference at token %d: %r -> %r' % (k, ta[k], tb[k]))
                        print('          context before: %r' % (ta[max(0, k - 6):k + 6],))
                        break
                else:
                    side = 'before' if len(ta) > len(tb) else 'after'
                    longer = ta if len(ta) > len(tb) else tb
                    print('          %s has %d extra token(s): %r'
                          % (side, abs(len(ta) - len(tb)), longer[min(len(ta), len(tb)):][:8]))
    print('-' * 63)
    print('compared %d web file(s): %d changed, %d missing' % (checked, fail, missing))
    print('PASS -- every shipping panel file has the same tokens' if not (fail or missing) else 'FAIL')
    return 1 if (fail or missing) else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
