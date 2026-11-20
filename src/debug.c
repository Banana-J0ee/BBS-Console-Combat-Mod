/* Debug channel: polls bbskh2_cmd.txt in the game folder, executes commands, appends output to the log.
   Only active when bbskh2_debug.txt exists next to the DLL. */
#include "core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
extern char g_dir[MAX_PATH];
void dbg_custom(const char *cmd, char *args);   /* mp.c */

/* main-thread call queue */
typedef struct { volatile LONG pending; u32 rva; u64 a[4]; u64 ret; } MainCall;
static MainCall g_mc;
static int readable(const void *p, size_t n);
/* Camera trace (debug only, for research): one line whenever the active camera, the player camera's mode or
   settings, or the player's attack changes.  [148f6d450] = the active camera (Lua GetActiveCameraHandle,
   14010fb80); player camera = player+0x368 (mode +0x1e0, previous +0x1e4, flags +0x20c, settings pointer +0xb0,
   attack camera data +0x1f0 [22ed00]); attack record = player+0x5b8 (PAtkData, 0x28 each). */
extern int g_debug;
static void cam_trace(void) {
    static u64 last[12]; static unsigned frame;
    frame++;
    u8 *mgr = G(u8*, 0x10f9ee40), *pl = mgr ? *(u8**)(mgr + 0x118) : NULL;
    u8 *act = G(u8*, 0x8f6d450), *pc = pl ? *(u8**)(pl + 0x368) : NULL;
    u8 *base = mgr ? *(u8**)(mgr + 0x128) : NULL, *rec = pl ? *(u8**)(pl + 0x5b8) : NULL;
    if (act && !readable(act, 8)) act = NULL;
    if (pc && !readable(pc + 0x1e0, 0x50)) pc = NULL;
    u64 v[12] = {
        (u64)act, act ? *(u64*)act - (u64)g_base : 0,
        pc ? *(u32*)(pc + 0x1e0) : 0xff, pc ? *(u32*)(pc + 0x1e4) : 0xff, pc ? *(u32*)(pc + 0x20c) : 0,
        pc && *(u8**)(pc + 0xb0) ? (u64)(*(u8**)(pc + 0xb0) - pc) : 0, pc ? (u64)*(u8**)(pc + 0x1f0) : 0,
        base && rec >= base ? (u64)((rec - base) / 0x28) : 0xffff, pl ? *(u16*)(pl + 0x312) : 0,
        pl ? *(u16*)(pl + 0x304) : 0, pl ? (u16)*(s16*)(pl + 0x310) : 0, (u64)pc };
    if (!memcmp(v, last, sizeof v)) return;
    memcpy(last, v, sizeof v);
    LOG("cam f%u: active %p (vt %llx%s) | pcam mode %llu prev %llu flags %08llx set +%llx acam %p | rec %lld motion %x cmd %llx state %llx/%llx",
        frame, act, v[1], act && act == pc ? " = player cam" : "", v[2], v[3], v[4], v[5], (void*)v[6],
        v[7] == 0xffff ? -1LL : (long long)v[7], rec && v[7] != 0xffff ? rec[8] : 0, v[8], v[9], v[10]);
}
/* Who makes and starts the Exusia (scripted) cameras: debug only.  CExusiaCameraEx ctor 14029b3d0 (10 call sites),
   start 14029c720 (19 call sites).  Each call is logged with its site and the player's attack record. */
static long cam_rec(void) {
    u8 *mgr = G(u8*, 0x10f9ee40), *pl = mgr ? *(u8**)(mgr + 0x118) : NULL;
    u8 *base = mgr ? *(u8**)(mgr + 0x128) : NULL, *rec = pl ? *(u8**)(pl + 0x5b8) : NULL;
    return base && rec >= base ? (long)((rec - base) / 0x28) : -1;
}
static u64 MSABI xcam_ctor_hook(u64 a, u64 b, u64 c, u64 d, u64 e) {
    u32 site = (u32)((u8*)__builtin_return_address(0) - g_base) - 5;
    u64 r = FN(u64, 0x29b3d0, u64, u64, u64, u64, u64)(a, b, c, d, e);
    LOG("xcam: CExusiaCameraEx made at %x -> %p (rec %ld)", site, (void*)r, cam_rec());
    return r;
}
static u64 MSABI xcam_start_hook(u64 a, u64 b, u64 c, u64 d) {
    u32 site = (u32)((u8*)__builtin_return_address(0) - g_base) - 5;
    u64 r = FN(u64, 0x29c720, u64, u64, u64, u64)(a, b, c, d);
    LOG("xcam: camera %p started at %x (rec %ld)", (void*)a, site, cam_rec());
    return r;
}
static void cam_trace_install(void) {
    static const u32 ctor[] = { 0x22de59, 0x26ceb5, 0x26d040, 0x26d3ec, 0x2b4720, 0x304305, 0x314afd, 0x31ddae, 0x33cf8a, 0x33d0ec };
    static const u32 start[] = { 0x22df1d, 0x26ced4, 0x26d0a6, 0x26d40b, 0x2b479e, 0x304324, 0x314b1c, 0x31ddda, 0x33cfaf, 0x33d111,
                                 0x38803c, 0x3ab2a3, 0x3cfaf8, 0x3de689, 0x3df9d8, 0x3dfae2, 0x3dfb85, 0x48a03f, 0x48a3ca };
    int n = 0;
    for (unsigned i = 0; i < sizeof ctor / sizeof *ctor; i++) n += hook_call(ctor[i], 0x29b3d0, xcam_ctor_hook, "xcam ctor (debug)");
    for (unsigned i = 0; i < sizeof start / sizeof *start; i++) n += hook_call(start[i], 0x29c720, xcam_start_hook, "xcam start (debug)");
    LOG("debug: camera trace, %d call sites", n);
}
void dbg_frame(void) {       /* called from a main-thread hook */
    if (g_debug) cam_trace();
    if (g_mc.pending == 1) {
        g_mc.ret = FN(u64, g_mc.rva, u64, u64, u64, u64)(g_mc.a[0], g_mc.a[1], g_mc.a[2], g_mc.a[3]);
        LOG("call %x(%llx,%llx,%llx,%llx) = %llx", g_mc.rva, g_mc.a[0], g_mc.a[1], g_mc.a[2], g_mc.a[3], g_mc.ret);
        g_mc.pending = 0;
    }
}
static int readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION mbi;
    const u8 *a = p, *end = a + n;
    while (a < end) {
        if (!VirtualQuery(a, &mbi, sizeof mbi)) return 0;
        if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) || !(mbi.Protect & 0xEE)) return 0;
        a = (u8*)mbi.BaseAddress + mbi.RegionSize;
    }
    return 1;
}
int dbg_readable(const void *p, size_t n) { return readable(p, n); }
static void hexdump(u8 *p, size_t n) {
    char line[160];
    if (!readable(p, n)) { LOG("  %p not readable", p); return; }
    for (size_t i = 0; i < n; i += 16) {
        int k = snprintf(line, sizeof line, "  %p:", p + i);
        for (size_t j = i; j < i + 16 && j < n; j++) k += snprintf(line + k, sizeof line - k, " %02x", p[j]);
        LOG("%s", line);
    }
}
static u8 *addr_of(const char *s) {     /* "x123" = absolute, otherwise rva; "*"prefix = deref pointer at rva, "+off" suffix */
    int deref = 0; u8 *a;
    while (*s == '*') { deref++; s++; }
    char *end;
    if (*s == 'x') a = (u8*)strtoull(s + 1, &end, 16); else a = g_base + strtoull(s, &end, 16);
    while (deref--) { if (!readable(a, 8)) return NULL; a = *(u8**)a; }
    if (*end == '+') a += strtoull(end + 1, NULL, 16);
    return a;
}
static void exec_line(char *l) {
    char cmd[32] = {0}; int n = 0;
    while (*l == ' ') l++;
    if (!*l || *l == '#') return;
    sscanf(l, "%31s%n", cmd, &n); char *args = l + n; while (*args == ' ') args++;
    LOG("> %s %s", cmd, args);
    if (!strcmp(cmd, "r")) {
        char a[64]; unsigned len = 64; sscanf(args, "%63s %x", a, &len);
        u8 *p = addr_of(a); if (p) hexdump(p, len); else LOG("  bad addr");
    } else if (!strcmp(cmd, "w")) {
        char a[64]; int k = 0; sscanf(args, "%63s%n", a, &k); u8 *p = addr_of(a); char *h = args + k;
        if (!p) { LOG("  bad addr"); return; }
        while (*h) {
            while (*h == ' ') h++;
            if (!h[0] || !h[1]) break;
            char b[3] = { h[0], h[1], 0 }; u8 v = (u8)strtoul(b, NULL, 16);
            DWORD old; if (VirtualProtect(p, 1, PAGE_EXECUTE_READWRITE, &old)) { *p = v; VirtualProtect(p, 1, old, &old); }
            p++; h += 2;
        }
    } else if (!strcmp(cmd, "call")) {
        unsigned rva = 0; unsigned long long a0 = 0, a1 = 0, a2 = 0, a3 = 0;
        sscanf(args, "%x %llx %llx %llx %llx", &rva, &a0, &a1, &a2, &a3);
        g_mc.rva = rva; g_mc.a[0] = a0; g_mc.a[1] = a1; g_mc.a[2] = a2; g_mc.a[3] = a3; g_mc.pending = 1;
        for (int i = 0; i < 300 && g_mc.pending; i++) Sleep(10);
        if (g_mc.pending) { g_mc.pending = 0; LOG("  call not serviced (no main-thread hook running)"); }
    } else if (!strcmp(cmd, "sleep")) {
        Sleep(atoi(args));
    } else dbg_custom(cmd, args);
}
static DWORD WINAPI dbg_thread(LPVOID p) {
    (void)p;
    char path[MAX_PATH + 32], tmp[MAX_PATH + 32];
    snprintf(path, sizeof path, "%sbbskh2_cmd.txt", g_dir);
    snprintf(tmp, sizeof tmp, "%sbbskh2_cmd.run", g_dir);
    for (;;) {
        Sleep(200);
        if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) continue;
        DeleteFileA(tmp);
        if (!MoveFileA(path, tmp)) continue;
        HANDLE f = CreateFileA(tmp, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        if (f == INVALID_HANDLE_VALUE) continue;
        static char buf[65536]; DWORD got = 0;
        ReadFile(f, buf, sizeof buf - 1, &got, NULL); CloseHandle(f); DeleteFileA(tmp);
        buf[got] = 0;
        char *save = NULL;
        for (char *l = strtok_s(buf, "\r\n", &save); l; l = strtok_s(NULL, "\r\n", &save)) exec_line(l);
        LOG("> done");
    }
    return 0;
}
int g_debug;
void dbg_start(void) {
    char p[MAX_PATH + 32]; snprintf(p, sizeof p, "%sbbskh2_debug.txt", g_dir);
    if (GetFileAttributesA(p) == INVALID_FILE_ATTRIBUTES) return;
    g_debug = 1;
    LOG("debug channel enabled");
    cam_trace_install();
    CreateThread(NULL, 0, dbg_thread, NULL, 0, NULL);
}
