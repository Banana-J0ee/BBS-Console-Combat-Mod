#!/usr/bin/env python3
"""Map Steam BBS exe RVAs to the Epic exe.

Both builds come from the same source, a few hours apart: the functions are the same, in the same order, with
small insertions.  Functions (.pdata chunks) are matched by their normalized instruction stream (addresses
masked); within a matched chunk code RVAs map by the chunk's offset.  Data RVAs map by the pairs of targets that
matched instructions reference (rip-relative operands, call / jump targets), as piecewise offsets.
"""
import re, struct, bisect, hashlib, pickle, os, sys, difflib, collections

BASE = 0x140000000

def pdata(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]; opt = pe + 24
    ns = struct.unpack_from('<H', d, pe + 6)[0]; osz = struct.unpack_from('<H', d, pe + 20)[0]
    secs = []
    for i in range(ns):
        o = opt + osz + i * 40
        vs, va, rs, ro = struct.unpack_from('<IIII', d, o + 8)
        secs.append((d[o:o + 8].rstrip(b'\0').decode(), va, vs, ro, rs))
    ex, exs = struct.unpack_from('<II', d, opt + 112 + 3 * 8)
    def off(r):
        for n, va, vs, ro, rs in secs:
            if va <= r < va + max(vs, rs): return ro + r - va
    o = off(ex)
    ents = sorted({struct.unpack_from('<II', d, o + i) for i in range(0, exs, 12)})
    return d, secs, off, ents

ADDR = re.compile(r'0x1[45][0-9a-f]{7}')
def load_asm(path):
    """rva -> (normalized text, [abs targets])"""
    ins = {}
    for line in open(path):
        if not line.startswith('   14') and not line.startswith('  14'): continue
        a, _, rest = line.partition(':')
        try: rva = int(a.strip(), 16) - BASE
        except ValueError: continue
        rest = rest.strip()
        targets = [int(x, 16) - BASE for x in ADDR.findall(rest)]
        norm = re.sub(r'#.*$', '', rest)
        norm = ADDR.sub('A', norm)
        norm = re.sub(r'rip\+0x[0-9a-f]+', 'rip+D', norm)
        norm = re.sub(r'<[^>]*>', '', norm).strip()
        ins[rva] = (norm, targets)
    return ins

def build(steam_exe, epic_exe, steam_asm, epic_asm, cache):
    if os.path.exists(cache): return pickle.load(open(cache, 'rb'))
    S = {'exe': pdata(steam_exe), 'ins': load_asm(steam_asm)}
    E = {'exe': pdata(epic_exe), 'ins': load_asm(epic_asm)}
    for X in (S, E):
        X['addrs'] = sorted(X['ins'])
        chunks = []
        for b, e in X['exe'][3]:
            lo = bisect.bisect_left(X['addrs'], b); hi = bisect.bisect_left(X['addrs'], e)
            seq = [X['ins'][a][0] for a in X['addrs'][lo:hi]]
            h = hashlib.md5('\n'.join(seq).encode()).hexdigest()
            chunks.append((b, e, h))
        X['chunks'] = chunks
    sm = difflib.SequenceMatcher(None, [c[2] for c in S['chunks']], [c[2] for c in E['chunks']], autojunk=False)
    pairs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            for k in range(i2 - i1): pairs.append((S['chunks'][i1 + k], E['chunks'][j1 + k]))
    # second pass: chunks in 'replace' blocks - pair them in order when the counts agree, else by a nested match
    # of instruction counts; then align their instructions one by one
    fine = {}
    def align(sc, ec):
        lo = bisect.bisect_left(S['addrs'], sc[0]); hi = bisect.bisect_left(S['addrs'], sc[1])
        sa = S['addrs'][lo:hi]
        lo = bisect.bisect_left(E['addrs'], ec[0]); hi = bisect.bisect_left(E['addrs'], ec[1])
        ea = E['addrs'][lo:hi]
        m2 = difflib.SequenceMatcher(None, [S['ins'][a][0] for a in sa], [E['ins'][a][0] for a in ea], autojunk=False)
        if m2.ratio() < 0.6: return 0
        for t, a1, a2, b1, b2 in m2.get_opcodes():
            if t == 'equal':
                for k in range(a2 - a1): fine[sa[a1 + k]] = ea[b1 + k]
        return 1
    extra = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != 'replace': continue
        sl, el = S['chunks'][i1:i2], E['chunks'][j1:j2]
        if len(sl) == len(el):
            for a, b in zip(sl, el):
                if align(a, b): extra.append((a, b))
        else:
            for a in sl:      # best partner by length among the block's chunks
                b = min(el, key=lambda c: abs((c[1] - c[0]) - (a[1] - a[0])))
                if align(a, b): extra.append((a, b))
    # code map: chunk start -> (end, delta)
    code = sorted((s[0], s[1], e[0] - s[0]) for s, e in pairs)
    pairs_all = pairs + extra
    # data pairs from operands of matched chunks
    dp = collections.Counter()
    for s, e in pairs_all:
        d = e[0] - s[0]
        lo = bisect.bisect_left(S['addrs'], s[0]); hi = bisect.bisect_left(S['addrs'], s[1])
        for a in S['addrs'][lo:hi]:
            ea = (a + d) if (s, e) in pairs else fine.get(a)
            if ea is None: continue
            if S['ins'][a][0] != E['ins'].get(ea, ('', []))[0]: continue
            ts = S['ins'][a][1]; te = E['ins'].get(ea, (None, []))[1]
            if len(ts) == len(te):
                for x, y in zip(ts, te): dp[(x, y)] += 1
    got = {p[0] for p in pairs_all}
    unmatched_s = [c for c in S['chunks'] if c not in got]
    res = {'code': code, 'fine': fine, 'n_extra': len(extra), 'dpairs': dp, 'n_s': len(S['chunks']), 'n_e': len(E['chunks']), 'n_pairs': len(pairs),
           'unmatched': [(c[0], c[1]) for c in unmatched_s]}
    pickle.dump(res, open(cache, 'wb'))
    return res

class Map:
    def __init__(s, res):
        s.code = res['code']; s.starts = [c[0] for c in s.code]
        # data: one delta per steam target (majority), then piecewise
        best = {}
        for (x, y), n in res['dpairs'].items():
            if x not in best or n > best[x][1]: best[x] = (y - x, n)
        s.dt = sorted((x, d) for x, (d, n) in best.items())
        s.dkeys = [x for x, d in s.dt]
        s.unmatched = res['unmatched']; s.fine = res['fine']
    def code_rva(s, r):
        i = bisect.bisect_right(s.starts, r) - 1
        if i >= 0 and s.code[i][0] <= r < s.code[i][1]: return r + s.code[i][2]
        return s.fine.get(r)
    def any_rva(s, r):
        c = s.code_rva(r)
        if c is not None: return c, 'code'
        if r in dict(s.dt): return r + dict(s.dt)[r], 'exact'
        i = bisect.bisect_right(s.dkeys, r) - 1
        if i < 0 or i + 1 >= len(s.dkeys): return None, 'none'
        a, b = s.dt[i], s.dt[i + 1]
        if a[1] == b[1]: return r + a[1], 'between'
        return r + a[1], 'near:%x/%x' % (a[1], b[1])

if __name__ == '__main__':
    res = build('/home/claude/bbs/bbs.exe', '/home/claude/epic/bbs_epic.exe', '/home/claude/epic/steam.asm', '/home/claude/epic/epic.asm', '/home/claude/epic/map.pkl')
    print('chunks', res['n_s'], res['n_e'], 'matched', res['n_pairs'], '+', res['n_extra'], 'unmatched steam', len(res['unmatched']))
    m = Map(res)
    for r in map(lambda x: int(x, 16), sys.argv[1:]): print(hex(r), [hex(x) if isinstance(x, int) else x for x in m.any_rva(r)])
