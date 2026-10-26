/* Diagnostics for "install FAILED" reports (2026-10-26, asked for: a build that finds out by itself why the mod
   refused a player's game - no hash commands for the player).

   When the mod refuses to install (or always with [Debug] Diagnose=1 in bbskh2.ini), bbskh2_log.txt gets:
     1. the game exe on disk: size and CRC-32, named when it is a known build (Epic 1.0.0.10_WW, Steam);
     2. the files next to it that load into the game (Panacea's DBGHELP.dll / version.dll, LuaBackend.dll,
        dinput8.dll) and the DLLs in this mod's own folder;
     3. every module loaded in the game process (other mods, overlays, trainers);
     4. memory against disk: the exe's code (.text, .nep) and read-only tables (.rdata, minus the import table the
        loader fills) as loaded, compared with the exe file relocated to the same base.  Each differing range is
        logged with its bytes and, when the new bytes jump / call / point somewhere, the module that is - so a hook
        names its owner.  The writable .data is compared too but counted apart (the game itself writes there).
   It runs before the mod changes anything (on a refusal the mod has changed nothing at all), so every difference
   is someone else's.  Nothing here writes to the game. */
#include "core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---- portable part (tested in test/run.c) ---- */
typedef struct DiffRange { u32 rva, len; } DiffRange;
/* ranges where a and b differ (gaps of up to `join` equal bytes are merged); returns the number found (all of
   them, even past `max`, which only limits how many are stored) */
int diag_ranges(const u8 *a, const u8 *b, u32 n, u32 rva0, u32 join, DiffRange *out, int max) {
    int cnt = 0; u32 i = 0;
    while (i < n) {
        if (a[i] == b[i]) { i++; continue; }
        u32 s = i, e = i + 1, eq = 0;
        for (u32 k = e; k < n; k++) {
            if (a[k] != b[k]) { e = k + 1; eq = 0; }
            else if (++eq > join) break;
        }
        if (cnt < max) { out[cnt].rva = rva0 + s; out[cnt].len = e - s; }
        cnt++; i = e;
    }
    return cnt;
}
/* the absolute addresses a run of bytes leads to: a rel32 jmp / call (E8 / E9 at its start or within its first
   bytes), an indirect jmp [rip+x] (FF 25), or an 8-byte pointer; `mem_va` = the address of p[0] in memory */
int diag_targets(const u8 *p, u32 n, u64 mem_va, u64 *out, int max) {
    int c = 0;
    for (u32 k = 0; k + 5 <= n && c < max; k++) {
        if (p[k] == 0xE8 || p[k] == 0xE9) {
            s32 d; memcpy(&d, p + k + 1, 4);
            out[c++] = mem_va + k + 5 + (s64)d;
            k += 4;
        } else if (p[k] == 0xFF && k + 6 <= n && p[k + 1] == 0x25) {
            s32 d; memcpy(&d, p + k + 2, 4);
            u64 slot = mem_va + k + 6 + (s64)d;
            out[c++] = slot | 1ull << 63;           /* the slot; the caller reads it if it can */
            k += 5;
        }
    }
    if (c == 0 && n >= 8 && n <= 16) {               /* a vtable slot / table entry: the new pointer(s) */
        for (u32 k = 0; k + 8 <= n && c < max; k += 8) { u64 v; memcpy(&v, p + k, 8); out[c++] = v; }
    }
    return c;
}
u32 diag_crc32(const u8 *p, size_t n) {
    static u32 t[256]; static int ready;
    if (!ready) { for (u32 i = 0; i < 256; i++) { u32 c = i; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0 - (c & 1))); t[i] = c; } ready = 1; }
    u32 c = 0xffffffffu;
    while (n--) c = t[(c ^ *p++) & 0xff] ^ (c >> 8);
    return ~c;
}
static const struct { u32 crc, size; const char *name; } k_known[] = {
    { 0x74e356ffu, 9345296, "Epic 1.0.0.10_WW (the one the Epic build is made for)" },
    { 0x79a373dbu, 9346320, "Steam (the one the Steam build is made for)" },
};
const char *diag_known(u32 crc, u32 size) {
    for (unsigned i = 0; i < sizeof k_known / sizeof *k_known; i++) if (k_known[i].crc == crc && k_known[i].size == size) return k_known[i].name;
    return NULL;
}

#ifdef _WIN32
#include <tlhelp32.h>
extern char g_dir[MAX_PATH], g_ini[MAX_PATH + 32];

typedef struct { u64 base, end; char name[64]; } Mod;
static Mod g_mods[256]; static int g_nmods;
static void list_modules(int log) {
    g_nmods = 0;
    HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (s == INVALID_HANDLE_VALUE) { if (log) LOG("diag: module list not available"); return; }
    MODULEENTRY32 me; me.dwSize = sizeof me;
    for (BOOL ok = Module32First(s, &me); ok; ok = Module32Next(s, &me)) {
        if (g_nmods < 256) {
            Mod *m = &g_mods[g_nmods++];
            m->base = (u64)me.modBaseAddr; m->end = m->base + me.modBaseSize;
            snprintf(m->name, sizeof m->name, "%s", me.szModule);
        }
        if (log) LOG("diag: module %-28s %p  %7lu KB  %s", me.szModule, me.modBaseAddr, (unsigned long)(me.modBaseSize / 1024), me.szExePath);
    }
    CloseHandle(s);
}
static const char *owner(u64 a, u64 *off) {
    for (int i = 0; i < g_nmods; i++) if (a >= g_mods[i].base && a < g_mods[i].end) { *off = a - g_mods[i].base; return g_mods[i].name; }
    MEMORY_BASIC_INFORMATION mi;
    if (VirtualQuery((void*)a, &mi, sizeof mi) && mi.State == MEM_COMMIT) { *off = a - (u64)mi.AllocationBase; return "(memory outside any module)"; }
    *off = 0; return NULL;
}
static u8 *slurp(const char *path, DWORD *n) {
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return NULL;
    DWORD sz = GetFileSize(f, NULL), got = 0; u8 *b = sz != INVALID_FILE_SIZE ? malloc(sz ? sz : 1) : NULL;
    if (b && (!ReadFile(f, b, sz, &got, NULL) || got != sz)) { free(b); b = NULL; }
    CloseHandle(f); if (b) *n = sz; return b;
}
static void file_note(const char *dir, const char *name) {
    char p[MAX_PATH + 64]; snprintf(p, sizeof p, "%s%s", dir, name);
    DWORD n; u8 *b = slurp(p, &n);
    if (!b) return;
    LOG("diag: file %s: %lu bytes, crc %08x", p, (unsigned long)n, diag_crc32(b, n));
    free(b);
}
static void hexs(char *o, size_t on, const u8 *p, u32 n) {
    size_t k = 0; o[0] = 0;
    for (u32 i = 0; i < n && i < 16 && k + 3 < on; i++) k += snprintf(o + k, on - k, "%02x", p[i]);
    if (n > 16 && k + 4 < on) snprintf(o + k, on - k, "..");
}

void diag_run(const char *why) {
    static int done; if (done) return; done = 1;
    LOG("diag: ---- diagnostics (%s) ----", why);
    /* 1. the exe on disk */
    char exe[MAX_PATH]; GetModuleFileNameA(NULL, exe, MAX_PATH);
    DWORD n = 0; u8 *f = slurp(exe, &n);
    if (!f) { LOG("diag: cannot read %s", exe); }
    u32 crc = f ? diag_crc32(f, n) : 0; const char *k = f ? diag_known(crc, n) : NULL;
    if (f) LOG("diag: game exe %s: %lu bytes, crc %08x = %s", exe, (unsigned long)n, crc, k ? k : "UNKNOWN BUILD");
    /* 2. files that load into the game */
    static const char *const near_files[] = { "DBGHELP.dll", "version.dll", "LuaBackend.dll", "dinput8.dll", "LuaBackend.toml", "panacea_settings.txt" };
    for (unsigned i = 0; i < sizeof near_files / sizeof *near_files; i++) file_note(g_dir, near_files[i]);
    {
        HMODULE me = NULL; char d[MAX_PATH];
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)diag_run, &me);
        GetModuleFileNameA(me, d, MAX_PATH); LOG("diag: this mod: %s", d);
        char *e = strrchr(d, '\\'); if (e) e[1] = 0;
        char pat[MAX_PATH + 8]; snprintf(pat, sizeof pat, "%s*.dll", d);
        WIN32_FIND_DATAA fd; HANDLE h = FindFirstFileA(pat, &fd);
        if (h != INVALID_HANDLE_VALUE) { do LOG("diag: dll in the mod's folder: %s (%lu bytes)", fd.cFileName, (unsigned long)fd.nFileSizeLow); while (FindNextFileA(h, &fd)); FindClose(h); }
    }
    /* 3. modules */
    list_modules(1);
    /* 4. memory against disk */
    if (f && n > 0x400) {
        IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64*)(f + ((IMAGE_DOS_HEADER*)f)->e_lfanew);
        IMAGE_NT_HEADERS64 *mnt = (IMAGE_NT_HEADERS64*)(g_base + ((IMAGE_DOS_HEADER*)g_base)->e_lfanew);
        if (nt->FileHeader.NumberOfSections != mnt->FileHeader.NumberOfSections || nt->OptionalHeader.SizeOfImage != mnt->OptionalHeader.SizeOfImage)
            LOG("diag: the exe on disk is not the one running (sections %d / %d, image %lx / %lx)", nt->FileHeader.NumberOfSections,
                mnt->FileHeader.NumberOfSections, (unsigned long)nt->OptionalHeader.SizeOfImage, (unsigned long)mnt->OptionalHeader.SizeOfImage);
        else {
            u64 delta = (u64)g_base - nt->OptionalHeader.ImageBase;
            IMAGE_SECTION_HEADER *sh = IMAGE_FIRST_SECTION(nt);
            int ns = nt->FileHeader.NumberOfSections;
            /* a relocated copy of each section (raw size), from the file */
            u8 *img[32] = {0};
            for (int i = 0; i < ns && i < 32; i++) {
                u32 rs = sh[i].SizeOfRawData < sh[i].Misc.VirtualSize ? sh[i].SizeOfRawData : sh[i].Misc.VirtualSize;
                if (sh[i].PointerToRawData + rs > n) rs = 0;
                img[i] = malloc(rs ? rs : 1); if (rs) memcpy(img[i], f + sh[i].PointerToRawData, rs);
            }
            IMAGE_DATA_DIRECTORY *rd = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
            u32 ro = 0;
            for (int i = 0; i < ns; i++) if (rd->VirtualAddress >= sh[i].VirtualAddress && rd->VirtualAddress < sh[i].VirtualAddress + sh[i].SizeOfRawData)
                ro = sh[i].PointerToRawData + rd->VirtualAddress - sh[i].VirtualAddress;
            for (u32 p = 0; ro && p + 8 <= rd->Size; ) {
                IMAGE_BASE_RELOCATION *br = (IMAGE_BASE_RELOCATION*)(f + ro + p);
                if (br->SizeOfBlock < 8 || ro + p + br->SizeOfBlock > n) break;
                u16 *e = (u16*)(br + 1);
                for (u32 j = 0; j < (br->SizeOfBlock - 8) / 2; j++) {
                    if ((e[j] >> 12) != IMAGE_REL_BASED_DIR64) continue;
                    u32 r = br->VirtualAddress + (e[j] & 0xfff);
                    for (int i = 0; i < ns; i++) {
                        u32 rs = sh[i].SizeOfRawData < sh[i].Misc.VirtualSize ? sh[i].SizeOfRawData : sh[i].Misc.VirtualSize;
                        if (r >= sh[i].VirtualAddress && r + 8 <= sh[i].VirtualAddress + rs) { u64 v; memcpy(&v, img[i] + r - sh[i].VirtualAddress, 8); v += delta; memcpy(img[i] + r - sh[i].VirtualAddress, &v, 8); }
                    }
                }
                p += br->SizeOfBlock;
            }
            IMAGE_DATA_DIRECTORY *iat = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IAT];
            int shown = 0, total_code = 0, total_data = 0;
            for (int i = 0; i < ns; i++) {
                char nm[9] = {0}; memcpy(nm, sh[i].Name, 8);
                int code = !strcmp(nm, ".text") || !strcmp(nm, ".nep"), ro_ = !strcmp(nm, ".rdata"), dat = !strcmp(nm, ".data");
                if (!code && !ro_ && !dat) continue;
                u32 rs = sh[i].SizeOfRawData < sh[i].Misc.VirtualSize ? sh[i].SizeOfRawData : sh[i].Misc.VirtualSize;
                u8 *mem = g_base + sh[i].VirtualAddress;
                if (ro_ && iat->Size && iat->VirtualAddress >= sh[i].VirtualAddress && iat->VirtualAddress < sh[i].VirtualAddress + rs)
                    memcpy(img[i] + iat->VirtualAddress - sh[i].VirtualAddress, mem + iat->VirtualAddress - sh[i].VirtualAddress, iat->Size);
                static DiffRange r[400];
                int c = diag_ranges(mem, img[i], rs, sh[i].VirtualAddress, 8, r, 400);
                LOG("diag: %s: %d range%s differ from the exe file", nm, c, c == 1 ? "" : "s");
                if (dat) { total_data += c; continue; }       /* the game writes there itself: counted only */
                total_code += c;
                for (int j = 0; j < c && j < 400 && shown < 150; j++, shown++) {
                    u32 o = r[j].rva - sh[i].VirtualAddress, len = r[j].len;
                    char hm[40], hd[40]; hexs(hm, sizeof hm, mem + o, len); hexs(hd, sizeof hd, img[i] + o, len);
                    u64 t[4]; int nt_ = diag_targets(mem + o, len < 32 ? len : 32, (u64)(mem + o), t, 4);
                    char to[256]; size_t tk = 0; to[0] = 0;
                    for (int q = 0; q < nt_ && tk + 80 < sizeof to; q++) {
                        u64 a = t[q];
                        if (a >> 63) { a &= ~(1ull << 63); MEMORY_BASIC_INFORMATION mi; if (VirtualQuery((void*)a, &mi, sizeof mi) && mi.State == MEM_COMMIT) a = *(u64*)a; else continue; }
                        u64 off; const char *w = owner(a, &off);
                        if (w) tk += snprintf(to + tk, sizeof to - tk, " -> %s+%llx", w, (unsigned long long)off);
                    }
                    LOG("diag:   %s %x (+%u): now %s, file %s%s", nm, r[j].rva, len, hm, hd, to);
                }
            }
            LOG("diag: memory against the exe file: %d code / table ranges changed, %d .data ranges (the game writes .data itself)", total_code, total_data);
            for (int i = 0; i < ns && i < 32; i++) free(img[i]);
        }
    }
    free(f);
    LOG("diag: ---- end of diagnostics ----");
}
#endif
