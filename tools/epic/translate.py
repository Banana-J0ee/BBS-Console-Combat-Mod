#!/usr/bin/env python3
import os, sys
if os.path.exists("/home/claude/epic/TRANSLATED"): sys.exit("already translated")
"""Rewrite the Steam RVAs in the mod's sources to the Epic build (run on the epic branch)."""
import re, sys, glob, os
sys.path.insert(0, '/home/claude/epic')
import resolve as R
MOD = '/home/claude/bbs/mod'
targets = set()
for r, (n, t) in R.S.items(): targets.update(t)
# code-range values that are not addresses (flags, sizes, message ids, test tokens)
EX = {0x606060, 0x200000, 0x1000, 0x10000, 0xff00, 0x2000, 0xffff, 0x18cc, 0x7fff, 0xfff0, 0x7ffc, 0xf000, 0x1234,
      0x8200, 0x32020d, 0x32020c, 0x32020b, 0x320215, 0x3200a2, 0x3200bc, 0x1e00a2, 0x60000, 0x400040,
      0x62f000, 0x62f080, 0x62e080, 0x631290}
DATA_EXTRA = {0x637910, 0x637b10, 0x63de30, 0x6418c8, 0x641dd8, 0x646018, 0x647b88, 0x818308, 0x818310, 0x818318,
              0x81e160, 0x10fa3d08, 0x674c78, 0x674d80}
DATA_SKIP = {0x632000}
files = [f for f in glob.glob(MOD + '/src/*.c') + glob.glob(MOD + '/src/*.h') if not f.endswith('_gen.h')]
files += [MOD + '/test/run.c', MOD + '/tools/gensteal.py']
LIT = re.compile(r'0x([0-9a-fA-F]{4,9})(u?)\b')
cache = {}; fails = []; changes = 0; log = []
def conv(v):
    if v in cache: return cache[v]
    r = None
    if v in EX: r = None
    elif 0x1000 <= v < 0x630000 and v in R.S:
        e, how = R.resolve_code(v)
        if e is None: fails.append(v)
        r = e
    elif 0x632000 <= v < 0x111b0000 and v not in DATA_SKIP and (v in targets or v in DATA_EXTRA):
        e, how = R.resolve_data(v)
        if e is None or how not in ('exact', 'between', 'code'): fails.append(v); e = None
        r = e
    cache[v] = r
    return r
for f in files:
    src = open(f).read()
    def sub(mm):
        global changes
        txt = mm.group(1); v = int(txt, 16); absol = v >= 0x140000000
        if absol: v -= 0x140000000
        e = conv(v)
        if e is None or e == v: return mm.group(0)
        changes += 1
        if absol: e += 0x140000000
        new = '0x%x' % e
        if txt.isupper(): new = '0x%X' % e
        if len(txt) > len(new) - 2 and txt.startswith('0'): new = '0x' + ('%0' + str(len(txt)) + 'x') % e
        log.append('%s: %s -> %s' % (os.path.relpath(f, MOD), mm.group(0), new + mm.group(2)))
        return new + mm.group(2)
    out = LIT.sub(sub, src)
    if out != src: open(f, 'w').write(out)
open('/home/claude/epic/translate.log', 'w').write('\n'.join(log))
print('changes', changes, 'unique', len([k for k, v in cache.items() if v is not None and v != k]))
print('FAILS', [hex(x) for x in sorted(set(fails))])
