#!/usr/bin/env python3
"""Relocate the Combo Flow code runs (Steam: hook-site jumps + two code caves) to the Epic exe.
Writes /home/claude/epic/combo_runs.json: [{rva, old (hex), new (hex)}] for genbundle (BBS_COMBO_RUNS)."""
import json, struct, subprocess, sys, pickle, re
sys.path.insert(0, '/home/claude/epic'); sys.path.insert(0, '/home/claude/bbs/mod/tools')
from mapper import Map
from bbsexe import PE
m = Map(pickle.load(open('/home/claude/epic/map.pkl', 'rb')))
a = PE('/home/claude/bbs/bbs.exe'); b = PE('/home/claude/bbs/bbs_patched.exe'); e = PE('/home/claude/epic/bbs_epic.exe')
da, db = bytes(a.d), bytes(b.d)
def rva(p, off):
    for n, va, vs, ro, rs in p.secs:
        if ro <= off < ro + rs: return va + off - ro
def offof(p, r):
    for n, va, vs, ro, rs in p.secs:
        if va <= r < va + rs: return ro + r - va
diff = [i for i in range(len(da)) if da[i] != db[i] and rva(a, i) is not None]
runs = []; s = p = diff[0]
for i in diff[1:]:
    if i - p > 8: runs.append((s, p + 1)); s = i
    p = i
runs.append((s, p + 1))
CAVE = {0x62f080: 0x631340, 0x631290: 0x631290}          # Steam cave -> Epic cave (.nep page tail, zero in memory)
SCRATCH = {0x1110d800: 0x1110dd00}                         # cave's state block: Steam's .data page tail -> Epic's
caves = [(rva(a, i), j - i) for i, j in runs if rva(a, i) in CAVE]
def cave_of(r):
    for c, n in caves:
        if c <= r < c + n: return CAVE[c] + (r - c)
def mp(r):
    c = cave_of(r)
    if c is not None: return c
    if r in SCRATCH: return SCRATCH[r]
    x, how = m.any_rva(r)
    if x is None or how.startswith('near') or how == 'none': raise SystemExit('cannot map %x (%s)' % (r, how))
    return x
out = []
for i, j in runs:
    sr = rva(a, i); new = bytearray(db[i:j]); er = cave_of(sr) if sr in CAVE else mp(sr)
    def mem(p, r, n):     # bytes as mapped: file data within the section's raw size, zeros past it
        out = bytearray(n)
        for k in range(n):
            o = offof(p, r + k)
            sec = [s for s in p.secs if s[1] <= r + k < s[1] + s[4]]
            if o is not None and sec and sec[0][1] <= r < sec[0][1] + sec[0][4]: out[k] = p.d[o]
        return bytes(out)
    old = mem(e, er, j - i)
    if sr not in CAVE and old != da[i:j]: raise SystemExit('site %x -> %x: original bytes differ' % (sr, er))
    if sr in CAVE and any(old): raise SystemExit('cave %x not free' % er)
    # re-encode every rel32 / rip-relative operand for the new place
    open('/tmp/run.bin', 'wb').write(new)
    dis = subprocess.run(['objdump', '--insn-width=15', '-D', '-b', 'binary', '-m', 'i386:x86-64', '--adjust-vma=0x%x' % (0x140000000 + sr), '/tmp/run.bin'], capture_output=True, text=True).stdout
    for line in dis.splitlines():
        mm = re.match(r'\s*(14[0-9a-f]+):\s+((?:[0-9a-f]{2} )+)\s*(.*)$', line)
        if not mm: continue
        ia = int(mm.group(1), 16) - 0x140000000; ib = bytes.fromhex(mm.group(2).replace(' ', '')); txt = mm.group(3)
        k = ia - sr; L = len(ib)
        tgt = None
        t = re.search(r'#\s*0x(1[45][0-9a-f]+)', txt)
        if t: tgt = int(t.group(1), 16) - 0x140000000; dpos = None
        elif re.match(r'(jmp|call|j[a-z]+)\s+0x', txt) and L >= 5:
            tgt = int(re.search(r'0x([0-9a-f]+)', txt).group(1), 16) - 0x140000000
        if tgt is None: continue
        if sr <= tgt < sr + (j - i) and L < 5: continue      # short internal jump
        # the disp32: rip-relative operands put it before any immediate; find it by value
        disp = tgt - (ia + L)
        enc = struct.pack('<i', disp); pos = ib.find(enc)
        if pos < 0: raise SystemExit('no disp in %x %s' % (ia, txt))
        nt = mp(tgt) if not (sr <= tgt < sr + (j - i)) else (er + (tgt - sr))
        nd = nt - (er + k + L)
        new[k + pos:k + pos + 4] = struct.pack('<i', nd)
        print('%x -> %x  %-40s target %x -> %x' % (ia, er + k, txt[:40], tgt, nt))
    out.append({'rva': er, 'old': old.hex(), 'new': bytes(new).hex()})
json.dump(out, open('/home/claude/epic/combo_runs.json', 'w'), indent=1)
print([(hex(o['rva']), len(o['new']) // 2) for o in out])
