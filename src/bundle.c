/* The changes of the three earlier mods, applied in memory instead of to the game files:
     Combo Flow     code at five places in the exe + 89 bytes of PAtkData.bin
     KH2 Camera     the camera parameter files PCam?000.bin / BCam????.bin
     Revenge Value  Factory.lub (enemy AI factory script) in CommonLua.arc
   Data files are plain "CRsrcData" resources whose bytes are read straight from the loaded archive image, so
   they are patched in place when the resource is created (vtable slot 1 of CRsrcData, a bare `ret` in the
   game).  Factory.lub has another length, so the buffer is swapped at the one call that loads Lua chunks. */
#include "core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "bundle_gen.h"
#include "mod.h"

extern char g_dir[MAX_PATH], g_ini[MAX_PATH + 32];
extern int g_debug;
static int c_combo = 1, c_camera = 1, c_revenge = 1;

/* [Camera]: on top of the KH2 Camera files.  Distance scales how far the camera sits (eye pulled towards the
   aim point, so the viewing angle and FOV stay); the pitch limits are the player camera's hard clamp on how
   far the right stick can tilt it: Low (camera below, looking up) and High (camera above, looking down).
   BBS clamps to [-30, +45] degrees (set in FUN_14022d790).  Tilting down, the camera reaches the floor at about
   -10 deg (its map ray pulls it in to the hit point, FUN_14022b110), so the low limit decides how far it can keep
   sliding in along the ground towards the character: -60 by default here.  KH2's field camera has no manual tilt at all: it only
   reads the pad for yaw (3 deg/frame, 1403a9250) and the height follows automatically. */
static float c_cam_dist = 0.9f, c_pitch_min = -60.0f, c_pitch_max = 45.0f;
static u32 cam_scaled_crc[64];
#define DEG2RAD 0.01745329252f              /* the same constant KH2 uses (0x3c8efa35) */
#define PITCH_MIN_IMM 0x22dae9              /* FUN_14022d790: mov [rdi+344h], 0bf060a92h (-30 deg), imm at +6 */
#define PITCH_MAX_IMM 0x22daf6              /*                mov [rdi+348h], 3f490fdbh  (+45 deg), imm at +6 */
#define PITCH_MIN_OLD 0xbf060a92u
#define PITCH_MAX_OLD 0x3f490fdbu

#define FACTORY_OLD_SIZE 638
#define FACTORY_OLD_CRC  0x951b6dfdu
/* the first Revenge Value build (the standalone mod, still installed through the Mod Manager or its own installer):
   replaced as well, so that the bosses added since are there */
#define FACTORY_RV1_SIZE 10208
#define FACTORY_RV1_CRC  0x9fcc7bc9u
static u32 crc32_(const u8 *p, size_t n);
static int is_factory(const char *buf, size_t n) {
    if (!buf) return 0;
    if (n == FACTORY_OLD_SIZE) return crc32_((const u8*)buf, n) == FACTORY_OLD_CRC;
    if (n == FACTORY_RV1_SIZE) return crc32_((const u8*)buf, n) == FACTORY_RV1_CRC;
    return 0;
}
#define VT_SLOT   0x637b10      /* CRsrcData::vftable[1] */
#define VT_STUB   0x114bc0      /* what it points to: ret */
#define LUA_CALL  0x2c5962      /* call luaL_loadbuffer */
#define LUA_LOAD  0x5bb9f0

static u32 crc32_(const u8 *p, size_t n) {
    static u32 t[256]; static int ready;
    if (!ready) { for (u32 i = 0; i < 256; i++) { u32 c = i; for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xedb88320u & (0 - (c & 1))); t[i] = c; } ready = 1; }
    u32 c = 0xffffffffu;
    while (n--) c = t[(c ^ *p++) & 0xff] ^ (c >> 8);
    return ~c;
}

/* PCAM / BCAM: two 0x30 chunks at 0x10 (Normal, Extended), eye at +0x10, aim at +0x20 */
static void cam_scale(u8 *data) {
    if (c_cam_dist == 1.0f) return;
    for (int c = 0; c < 2; c++) {
        float *eye = (float*)(data + 0x20 + c * 0x30), *aim = (float*)(data + 0x30 + c * 0x30);
        for (int k = 0; k < 3; k++) eye[k] = aim[k] + (eye[k] - aim[k]) * c_cam_dist;
    }
}

/* CRsrcData: +0x10 type (2 = .bin), +0x38 name, +0x70 data, +0x80 size.  Runs on the game's loader threads. */
static u64 MSABI rsrc_loaded(u8 *r) {
    if (r[0x10] != 2) return 0;
    const char *name = (const char*)(r + 0x38);
    u8 *data = *(u8**)(r + 0x70); u64 size = *(u64*)(r + 0x80);
    if (!data) data = *(u8**)(r + 0x68);        /* revived from the cache: only the planned address is set yet */
    if (!data) return 0;
    for (unsigned i = 0; i < sizeof df_files / sizeof *df_files; i++) {
        if (size != df_files[i].size || strncmp(name, df_files[i].name, 16) != 0) continue;
        if (df_files[i].group == 0 ? !c_combo : !c_camera) return 0;
        int cam = df_files[i].group != 0 && i < 64;
        u32 c = crc32_(data, size);
        if (cam && cam_scaled_crc[i] && c == cam_scaled_crc[i]) return 0;     /* this mod's own result */
        if (c == df_files[i].crc_new) {
            if (g_debug) LOG("bundle: %s already changed", name);
        } else if (c != df_files[i].crc_old) {
            LOG("bundle: %s is not the expected original (crc %08x): left alone", name, c); return 0;
        } else {
            for (unsigned k = 0; k < df_files[i].n; k++) data[df_files[i].set[2 * k]] = (u8)df_files[i].set[2 * k + 1];
            if (g_debug) LOG("bundle: %s patched (%d bytes)", name, df_files[i].n);
        }
        if (cam && c_cam_dist != 1.0f) { cam_scale(data); cam_scaled_crc[i] = crc32_(data, size); }
        return 0;
    }
    return 0;
}

/* [Bosses]: boss pace, carried by the Revenge Value script.  Its two settings are float constants in the
   compiled Lua (type byte 3 + the float) with marker values that are replaced by the ini's here. */
static float c_aggr = 0.4f, c_walkcap = 2.0f;
static u8 rv_buf[sizeof rv_factory];
static int pace_patch(float marker, float value, const char *what) {
    u8 pat[5] = {3}; memcpy(pat + 1, &marker, 4);
    int n = 0; size_t at = 0;
    for (size_t i = 0; i + 5 <= sizeof rv_buf; i++) if (!memcmp(rv_buf + i, pat, 5)) { n++; at = i; }
    if (n != 1) { LOG("bundle: boss pace %s marker found %d times: default kept", what, n); return 0; }
    memcpy(rv_buf + at + 1, &value, 4);
    return 1;
}
static void pace_config(void) {
    char b[32], d[32];
    snprintf(d, sizeof d, "%g", c_aggr);
    GetPrivateProfileStringA("Bosses", "Aggression", d, b, sizeof b, g_ini); c_aggr = (float)atof(b);
    snprintf(d, sizeof d, "%g", c_walkcap);
    GetPrivateProfileStringA("Bosses", "WalkCap", d, b, sizeof b, g_ini); c_walkcap = (float)atof(b);
    if (!(c_aggr >= 0.1f && c_aggr <= 1.0f)) c_aggr = 0.4f;
    if (!(c_walkcap >= 0.0f && c_walkcap <= 30.0f)) c_walkcap = 2.0f;
    memcpy(rv_buf, rv_factory, sizeof rv_buf);
    pace_patch(9001.5f, c_aggr, "Aggression");
    pace_patch(9002.5f, c_walkcap, "WalkCap");
}

/* Debug only: BBS_Log(...) for the revenge script, its arguments written to the log as one line.
   The game's own Lua 5.1 API (from luaI_openlib 5bbd40 and luaB_print 5bca60): lua_gettop 5b9900,
   lua_tolstring 5ba7f0, lua_pushcclosure 5b9d80, lua_setfield 5ba4b0. */
#define LUA_GETTOP   0x5b9900
#define LUA_TOLSTR   0x5ba7f0
#define LUA_PUSHCCL  0x5b9d80
#define LUA_SETFIELD 0x5ba4b0
static int MSABI rv_log(void *L) {
    int n = FN(int, LUA_GETTOP, void*)(L);
    char line[600]; int p = 0; line[0] = 0;
    for (int i = 1; i <= n && p < (int)sizeof line - 80; i++) {
        size_t len = 0;
        const char *s = FN(const char*, LUA_TOLSTR, void*, int, size_t*)(L, i, &len);
        int w = snprintf(line + p, sizeof line - p, "%s%.*s", i > 1 ? " " : "", s ? (int)(len < 200 ? len : 200) : 1, s ? s : "?");
        if (w > 0) p += w;
    }
    LOG("rv %s", line);
    return 0;
}
static int lua_api_ok(void) {
    static const u8 top[] = { 0x48, 0x8b, 0x41, 0x10, 0x48, 0x2b, 0x41, 0x18 };
    return !memcmp(g_base + LUA_GETTOP, top, sizeof top);
}

/* BBS_BossIni(section): that section of bbskh2_boss.ini as "key=value" lines, or nothing when the file or the section
   is missing.  Read from the file on every call (the revenge script asks once per boss it creates), so edits take
   effect at the next boss without restarting.  The file is looked for in the game folder, then next to bbskh2.ini.
   lua_pushlstring 5b9ee0 (luaC_checkGC 5c4910, luaS_newlstr 5c57c0, type 4). */
#define LUA_PUSHLSTR 0x5b9ee0
static int pushlstr_ok(void) {
    static const u8 head[] = { 0x48, 0x89, 0x5c, 0x24, 0x08, 0x48, 0x89, 0x6c, 0x24, 0x10 };
    return !memcmp(g_base + LUA_PUSHLSTR, head, sizeof head);
}
static void boss_ini_path(char *out, size_t n) {
    snprintf(out, n, "%sbbskh2_boss.ini", g_dir);
    if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES) return;
    snprintf(out, n, "%s", g_ini);
    char *e = strrchr(out, '\\');
    if (e) snprintf(e + 1, n - (size_t)(e + 1 - out), "bbskh2_boss.ini");
}
/* Debug only: BBS_Ms() - milliseconds since the DLL loaded, for the revenge script's timing of boss callbacks.
   lua_pushinteger 5b9ea0 (the number type is float: kept small by counting from the start). */
#define LUA_PUSHINT 0x5b9ea0
static DWORD g_ms0;
static int pushint_ok(void) {
    static const u8 head[] = { 0x48, 0x8b, 0x41, 0x10, 0x0f, 0x57, 0xc0, 0xf3, 0x48, 0x0f, 0x2a, 0xc2 };
    return !memcmp(g_base + LUA_PUSHINT, head, sizeof head);
}
static int MSABI rv_ms(void *L) {
    FN(void, LUA_PUSHINT, void*, long long)(L, (long long)(GetTickCount() - g_ms0));
    return 1;
}
/* BBS_AtkState(handle): what the boss's attack is doing, for the armour windows of bbskh2_boss.ini ("hit").
   The handle (light userdata, lua_touserdata 5ba960) gives the entity through 1401d45c0 - as Entity.IsAttacking
   does [2bc400 -> 1d5900].  Its hit windows are its collision controller's (entity+0x88: +0x20 count, +0x28
   entries of 0x90: +0x28 / +0x2a state of the two shapes, 0 not yet / 1 on / 2 on to the end / 3 over; +0x48
   description, +0x30 second shape's on, -1 = none - as speed.c reads the player's), and its children's (entity+0x40
   list: node +8 entity, +0x10 next; characters only, vtable+0x28 bit 0x10).  Its shots: the objects of list 0xb
   (1401128b0) of kind 0x10005 whose owner (+0x204) is its id (vtable+0x38).
   Returns windows + 64 x windows not over + 4096 x shots (0 when the entity is not found). */
#define LUA_TOUDATA 0x5ba960
#define ENT_OF      0x1d45c0
#define OBJ_LIST    0x1128b0
static int atk_ok(void) {
    static const u8 a[] = { 0x48, 0x83, 0xec, 0x28, 0xe8 }, b[] = { 0x40, 0x53, 0x48, 0x83, 0xec, 0x20, 0x8b, 0xd9 },
                    c[] = { 0x83, 0xf9, 0x1b, 0x77, 0x0f };
    return !memcmp(g_base + LUA_TOUDATA, a, sizeof a) && !memcmp(g_base + ENT_OF, b, sizeof b) && !memcmp(g_base + OBJ_LIST, c, sizeof c);
}
#define VCALL_U32(obj, off) (((u32 (MSABI *)(u8*))*(void**)(*(u8**)(obj) + (off)))(obj))   /* a virtual of the object */
static void atk_windows(u8 *ent, int *n, int *open, int depth) {
    if (!ent || depth > 3) return;
    u8 *ctl = *(u8**)(ent + 0x88);
    if (ctl) {
        int cnt = *(s32*)(ctl + 0x20); u8 *e = *(u8**)(ctl + 0x28);
        if (e && cnt > 0 && cnt <= 64)
            for (int i = 0; i < cnt; i++, e += 0x90) {
                u8 *d = *(u8**)(e + 0x48); if (!d) continue;
                for (int k = 0; k < 2; k++) {
                    if (k && *(s16*)(d + 0x30) < 0) break;
                    (*n)++;
                    if (*(s16*)(e + 0x28 + 2 * k) != 3) (*open)++;
                }
            }
    }
    for (u8 *node = *(u8**)(ent + 0x40); node; node = *(u8**)(node + 0x10)) {
        u8 *ch = *(u8**)(node + 8);
        if (!ch) continue;
        u32 kind = VCALL_U32(ch, 0x28);
        if (kind & 0x10000) atk_windows(ch, n, open, depth + 1);
    }
}
static int MSABI rv_atk(void *L) {
    void *h = FN(void*, LUA_TOUDATA, void*, int)(L, 1);
    u8 *ent = h ? FN(u8*, ENT_OF, u32)((u32)(uintptr_t)h) : NULL;
    long long r = 0;
    if (ent) {
        int n = 0, open = 0, shots = 0;
        atk_windows(ent, &n, &open, 0);
        u32 id = VCALL_U32(ent, 0x38);
        u8 *list = FN(u8*, OBJ_LIST, int)(0xb);
        int guard = 0;
        for (u8 *node = list ? *(u8**)(list + 0x10) : NULL; node && guard < 512; node = *(u8**)(node + 0x10), guard++) {
            u8 *o = *(u8**)(node + 8);
            if (!o) continue;
            if (VCALL_U32(o, 0x28) == 0x10005 && *(u32*)(o + 0x204) == id) shots++;
        }
        if (n > 63) n = 63;
        if (open > 63) open = 63;
        if (shots > 255) shots = 255;
        r = n + 64 * open + 4096LL * shots;
    }
    FN(void, LUA_PUSHINT, void*, long long)(L, r);
    return 1;
}
static char boss_buf[32768];
static int MSABI rv_boss_ini(void *L) {
    if (FN(int, LUA_GETTOP, void*)(L) < 1) return 0;
    size_t len = 0;
    const char *sec = FN(const char*, LUA_TOLSTR, void*, int, size_t*)(L, 1, &len);
    if (!sec || !len || len > 64) return 0;
    char path[MAX_PATH + 32];
    boss_ini_path(path, sizeof path);
    if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) return 0;
    DWORD n = GetPrivateProfileSectionA(sec, boss_buf, sizeof boss_buf, path);
    if (n == 0) return 0;
    for (DWORD i = 0; i < n; i++) if (boss_buf[i] == 0) boss_buf[i] = '\n';
    FN(void, LUA_PUSHLSTR, void*, const char*, size_t)(L, boss_buf, n);
    return 1;
}

/* luaL_loadbuffer(L, buf, size, name) at the game's script loader */
static int MSABI lua_load_hook(void *L, const char *buf, size_t n, const char *name) {
    if (c_revenge && is_factory(buf, n)) {
        if (g_debug) LOG("bundle: Factory.lub replaced (%d bytes)", (int)sizeof rv_buf);
        if (g_debug && lua_api_ok()) {             /* the revenge script's log (BBS_Log), debug builds of the run only */
            FN(void, LUA_PUSHCCL, void*, void*, int)(L, (void*)rv_log, 0);
            FN(void, LUA_SETFIELD, void*, int, const char*)(L, -10002, "BBS_Log");
            if (pushint_ok()) {
                if (!g_ms0) g_ms0 = GetTickCount();
                FN(void, LUA_PUSHCCL, void*, void*, int)(L, (void*)rv_ms, 0);
                FN(void, LUA_SETFIELD, void*, int, const char*)(L, -10002, "BBS_Ms");
            }
        }
        if (lua_api_ok() && pushlstr_ok()) {        /* bbskh2_boss.ini for the revenge script (BBS_BossIni) */
            FN(void, LUA_PUSHCCL, void*, void*, int)(L, (void*)rv_boss_ini, 0);
            FN(void, LUA_SETFIELD, void*, int, const char*)(L, -10002, "BBS_BossIni");
            if (pushint_ok() && atk_ok()) {           /* a boss's hit windows and shots (BBS_AtkState) */
                FN(void, LUA_PUSHCCL, void*, void*, int)(L, (void*)rv_atk, 0);
                FN(void, LUA_SETFIELD, void*, int, const char*)(L, -10002, "BBS_AtkState");
            }
        } else if (g_debug) LOG("bundle: Lua API does not match: bbskh2_boss.ini not read (built-in values)");
        buf = (const char*)rv_buf; n = sizeof rv_buf;
    }
    return FN(int, LUA_LOAD, void*, const char*, size_t, const char*)(L, buf, n, name);
}

static int ini_i(const char *key, int def) {
    char p[MAX_PATH + 32], b[32], d[32];
    snprintf(p, sizeof p, "%s", g_ini); snprintf(d, sizeof d, "%d", def);
    GetPrivateProfileStringA("Bundle", key, d, b, sizeof b, p);
    return atoi(b);
}
static float ini_cam(const char *key, float def) {
    char b[32], d[32];
    snprintf(d, sizeof d, "%g", def);
    GetPrivateProfileStringA("Camera", key, d, b, sizeof b, g_ini);
    return (float)atof(b);
}
static void cam_config(void) {
    c_cam_dist = ini_cam("Distance", c_cam_dist);
    if (!(c_cam_dist >= 0.5f && c_cam_dist <= 1.5f)) c_cam_dist = 1.0f;
    c_pitch_min = ini_cam("PitchLow", c_pitch_min); c_pitch_max = ini_cam("PitchHigh", c_pitch_max);
    if (!(c_pitch_min >= -80.0f && c_pitch_min <= 0.0f)) c_pitch_min = -30.0f;
    if (!(c_pitch_max >= 0.0f && c_pitch_max <= 80.0f)) c_pitch_max = 45.0f;
}
static void cam_pitch_apply(void) {
    float lo = c_pitch_min * DEG2RAD, hi = c_pitch_max * DEG2RAD;
    u32 nlo, nhi; memcpy(&nlo, &lo, 4); memcpy(&nhi, &hi, 4);
    if (nlo != PITCH_MIN_OLD) patch_u32(PITCH_MIN_IMM, PITCH_MIN_OLD, nlo, "camera pitch low");
    if (nhi != PITCH_MAX_OLD) patch_u32(PITCH_MAX_IMM, PITCH_MAX_OLD, nhi, "camera pitch high");
}

/* state of the Combo Flow code: 0 = original, 1 = already present (the old exe patch is installed), -1 = neither */
static int combo_state(void) {
    int old = 0, neu = 0, n = sizeof cf_code / sizeof *cf_code;
    for (int i = 0; i < n; i++) {
        if (!memcmp(g_base + cf_code[i].rva, cf_code[i].old, cf_code[i].len)) old++;
        else if (!memcmp(g_base + cf_code[i].rva, cf_code[i].neu, cf_code[i].len)) neu++;
    }
    return old == n ? 0 : neu == n ? 1 : -1;
}
/* speed.c takes over the walk-out logic and hooks the same three places of the game code */
int bundle_combo_in_exe(void) { return combo_state() == 1; }
void bundle_restore_sites(void) {
    if (combo_state() != 1) return;
    for (unsigned i = 0; i < sizeof cf_code / sizeof *cf_code; i++)
        if (cf_code[i].rva < 0x62f000) patch_bytes(cf_code[i].rva, cf_code[i].neu, cf_code[i].old, cf_code[i].len, "combo flow (undo)");
    LOG("bundle: the old Combo Flow exe patch is installed; its three hooks are replaced by the speed module");
}
int bundle_check(void) {
    c_combo = ini_i("ComboFlow", 1); c_camera = ini_i("Camera", 1); c_revenge = ini_i("RevengeValue", 1);
    cam_config();
    pace_config();
    int bad = 0;
    crc32_((const u8*)"", 0);                    /* build the table now: the hooks run on several threads */
    if (G(u64, VT_SLOT) != (u64)(g_base + VT_STUB)) { LOG("bundle: resource vtable slot does not match"); bad++; }
    u8 *p = g_base + LUA_CALL; s32 d; memcpy(&d, p + 1, 4);
    if (p[0] != 0xE8 || (u32)(LUA_CALL + 5 + d) != LUA_LOAD) { LOG("bundle: Lua call site does not match"); bad++; }
    if (c_combo && combo_state() < 0) { LOG("bundle: Combo Flow code sites do not match"); bad++; }
    return bad == 0;
}
void bundle_apply(void) {
    if (c_combo && speed_enabled()) LOG("bundle: Combo Flow walk-out is handled by the speed module");
    else if (c_combo) {
        if (combo_state() == 1) LOG("bundle: Combo Flow code is already in the exe (old mod still installed)");
        else {
            for (unsigned i = 0; i < sizeof cf_code / sizeof *cf_code; i++)
                patch_bytes(cf_code[i].rva, cf_code[i].old, cf_code[i].neu, cf_code[i].len, "combo flow");
            LOG("bundle: Combo Flow code applied");
        }
    }
    if (c_combo || c_camera) {
        void *f = (void*)rsrc_loaded; u64 old = (u64)(g_base + VT_STUB);
        patch_bytes(VT_SLOT, (u8*)&old, (u8*)&f, 8, "rsrc vtable");
    }
    if (c_revenge) hook_call(LUA_CALL, LUA_LOAD, lua_load_hook, "lua load");
    if (c_camera) cam_pitch_apply();
    LOG("bundle: combo flow %d, camera %d (distance %.2f, pitch %.0f..%.0f), revenge value %d (boss pace: idle x%.2f, walks %.1f s)",
        c_combo, c_camera, c_camera ? c_cam_dist : 1.0f, c_pitch_min, c_pitch_max, c_revenge, c_aggr, c_walkcap);
}

#ifndef _WIN32
u64 test_rsrc_loaded(u8 *r) { return rsrc_loaded(r); }
int test_lua_swap(const char **buf, size_t *n) {      /* the decision of lua_load_hook, without calling Lua */
    if (c_revenge && is_factory(*buf, *n)) { *buf = (const char*)rv_buf; *n = sizeof rv_buf; return 1; }
    return 0;
}
void test_pace(float aggr, float walk) { c_aggr = aggr; c_walkcap = walk; memcpy(rv_buf, rv_factory, sizeof rv_buf);
    pace_patch(9001.5f, c_aggr, "Aggression"); pace_patch(9002.5f, c_walkcap, "WalkCap"); }
u32 test_crc(const u8 *p, size_t n) { return crc32_(p, n); }
void test_cam_dist(float d) { c_cam_dist = d; memset(cam_scaled_crc, 0, sizeof cam_scaled_crc); }
#endif
