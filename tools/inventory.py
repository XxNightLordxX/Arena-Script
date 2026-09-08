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
    cfg = os.path.join(root, 'config.lua')
    if os.path.isfile(cfg):
        for name in re.findall(r'^\s{0,12}([A-Za-z_]\w*)\s*=', read(cfg), re.M):
            lines.append('config-key %s' % name)
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
