#!/usr/bin/env python3
"""Steam -> Epic RVA resolution with verification (instruction windows for code)."""
import pickle, sys, bisect
sys.path.insert(0, '/home/claude/epic')
from mapper import Map, load_asm
m = Map(pickle.load(open('/home/claude/epic/map.pkl', 'rb')))
S = load_asm('/home/claude/epic/steam.asm'); E = load_asm('/home/claude/epic/epic.asm')
SA = sorted(S); EA = sorted(E)
D = dict(m.dt)

def window(ins, addrs, a, n=8):
    i = bisect.bisect_left(addrs, a)
    if i >= len(addrs) or addrs[i] != a: return None
    return [ins[x][0] for x in addrs[i:i + n]]

def score(s, e, n=8):
    ws, we = window(S, SA, s, n), window(E, EA, e, n)
    if ws is None or we is None: return 0
    return sum(1 for x, y in zip(ws, we) if x == y)

def nearest_delta(v):
    i = bisect.bisect_right(m.starts, v) - 1
    return m.code[i][2] if i >= 0 else 0

def resolve_code(v, need=6):
    cands = []
    c = m.code_rva(v)
    if c is not None: cands.append(c)
    if v in D: cands.append(v + D[v])
    for c in cands:
        if score(v, c) >= need: return c, 'ok'
    # search around the nearest known delta
    base = v + nearest_delta(v)
    best = (0, None)
    for off in sorted(range(-0x2000, 0x2000), key=abs):
        e = base + off
        if e not in E: continue
        sc = score(v, e, 12)
        if sc > best[0]: best = (sc, e)
        if sc == 12: break
    if best[0] >= 9: return best[1], 'search%d' % best[0]
    return None, 'fail'

def resolve_data(v):
    if v in D: return v + D[v], 'exact'
    e, how = m.any_rva(v)
    return e, how

if __name__ == '__main__':
    for a in sys.argv[1:]:
        v = int(a, 16); print(hex(v), resolve_code(v) if v < 0x630000 else resolve_data(v))
