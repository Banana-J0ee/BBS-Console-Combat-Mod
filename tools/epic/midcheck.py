import re,subprocess,sys
sys.path.insert(0,'/home/claude/epic')
import resolve as R
MOD='/home/claude/bbs/mod'
files=subprocess.run(['git','-C',MOD,'ls-tree','-r','--name-only','1.8'],capture_output=True,text=True).stdout.split()
files=[f for f in files if (f.startswith('src/') and (f.endswith('.c') or f.endswith('.h')) and not f.endswith('_gen.h')) or f=='test/run.c']
EX={0x606060,0x200000,0x1000,0x10000,0xff00,0x2000,0xffff,0x18cc,0x7fff,0xfff0,0x7ffc,0xf000,0x1234,0x8200,0x32020d,0x32020c,0x32020b,0x320215,0x3200a2,0x3200bc,0x1e00a2,0x60000,0x400040,0x62f000,0x62f080,0x62e080,0x631290}
seen=set()
for f in files:
    src=subprocess.run(['git','-C',MOD,'show','1.8:'+f],capture_output=True,text=True).stdout
    for ln,line in enumerate(src.split('\n'),1):
        for mm in re.finditer(r'0x([0-9a-fA-F]{4,9})u?\b',line):
            v=int(mm.group(1),16)
            if v>=0x140000000: v-=0x140000000
            if 0x1000<=v<0x630000 and v not in R.S and v not in EX and (v,f) not in seen:
                seen.add((v,f)); print(f,ln,hex(v),'|',line.strip()[:110])
