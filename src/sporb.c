/* SP orbs (2026-10-23): KH2's MP orbs, for SP.  A regular enemy (name m...: the Unversed and the like; not a boss,
   b...) that drops D-Link prizes when it is defeated also drops SP orbs; one picked up gives back a little SP, or
   during an SP charge moves the recharge on by as much (mp_restore_pct).

   Where prizes come from.  An enemy's drops are 1402d5b30(enemy, pos, percent, a4, a5): its prize table (epd, at
   [enemy+0x250]+0x9c / +0x98: entries of kind u32, count u16, chance u16), each prize made by 1401e83e0(pos, kind,
   0, 0, f, f) [the call at 2d5cc7].  Kinds index the prize types at 140817b30 (0x50 each): 0 / 1 HP (command 1e2 /
   1e3), 2..4 munny (1e6..1e8), 5 / 6 D-Link (1e4 / 1e5: 273420 adds to the gauge's pending D-Link, 208280; the count
   is scaled by the "FpPrizeUp" ability 0x1c6, Link Prize Boost).  Defeat: the calls at 2d8f16 (the usual death,
   2d8e40) and 2defd8 (2def30).  Other calls - hits that shake prizes out (2cfaae, 50 %), the scripts' MakePrize -
   are not defeats and get no orbs.
   The orb.  It is made as a small D-Link prize (kind 5: its model, its flight) and then given a type record of its
   own: a copy of kind 5's with the command 0x1ef - a prize command (type 10) with no effect of its own in the pickup
   (273420 returns for it).  Every pickup path reads the command from the record ([prize+0x250]+0x40, through
   2733d0); the one call to 273420 (at 273408) is hooked, and 0x1ef from there is the orb.
   The sound.  A prize type's pickup sound is its +0x44 (bank, -1 = the common one) / +0x46 (sound) - 1e8ea0 / 1e9320
   play it, through 1b2e40 into the common SE bank "se0000" (sound/win/se/common/se0000.win32.scd: the D-Link prize's
   is 12).  KH2's MP orb sound (its se000 sound 17, orbse_gen.h) is added to that bank as it is loaded: the call
   at 553472 registers it with the sound engine (4c3fb0, which copies it), and gets an extended copy instead - one
   more sound, track, audio entry and per-sound block, the old data moved along unchanged. */
#include "mod.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define ORBSE_DATA
#include "orbse_gen.h"

extern char g_ini[MAX_PATH + 32];
extern int g_debug;

#define DROP_FN     0x2d5b30u
static const u32 DEATH_CALLS[2] = { 0x2d8f16, 0x2defd8 };
#define MAKE_FN     0x1e83e0u
#define MAKE_CALL   0x2d5cc7u
#define PICK_FN     0x273420u
#define PICK_CALL   0x273408u
#define PRIZE_TYPES 0x817b30u
#define ORB_CMD     0x1efu
#define MGR         G(u8*, 0x10f9ee40)
#define BANK_FN     0x4c3fb0u
#define BANK_CALL   0x553472u      /* the "se0000" bank */
#define DLINK_SE    12             /* the D-Link prize's pickup sound (the copy's template) */

static int   c_on = 1;              /* [SPOrbs] Enabled */
static float c_per = 1.0f;          /* orbs per D-Link prize (a fraction = that chance of one) */
static float c_pct = 2.0f;          /* percent of max SP per orb (also the recharge it adds in an SP charge) */
static int   c_look = 1;            /* the effect it is drawn with: 0 the small D-Link prize's, 1 SYS_PRZ_100_0 (in the
                                       prize effects s_ex_prz_00.fep but used by no prize type), 2 SYS_PRZ_003_0 */
static const char *const k_look[3] = { "SYS_PRZ_001_0", "SYS_PRZ_100_0", "SYS_PRZ_003_0" };
static u8    g_rec[0x50];           /* the orb's prize type: kind 5's, command 0x1ef */
static u8   *g_drop;                /* the defeated regular enemy whose drops are being made */
static int   c_sound = 1;             /* 1 KH2's MP orb sound, 0 the D-Link prize's */
static float c_vol = 1.0f;          /* its volume in the bank (KH2's own; BBS's pickups are 0.2-0.4 of louder samples) */
static int   g_se = -1;             /* the sound's number in the bank once added */
static u32   g_seed = 0x2545f491u;
static int   g_made, g_got;         /* (log / tests) */

static float rnd(void) { g_seed = g_seed * 1103515245u + 12345u; return (float)((g_seed >> 8) & 0xffff) / 65536.0f; }
static int regular(u8 *ent) { return ent && ent[0xf0] == 'm'; }

typedef u8 *(MSABI *MakeFn)(void *pos, int kind, u64 a3, int a4, float a5, float a6);
static u8 *MSABI make_hook(void *pos, int kind, u64 a3, int a4, float a5, float a6) {
    u8 *p = ((MakeFn)(g_base + MAKE_FN))(pos, kind, a3, a4, a5, a6);
    if (c_on && g_drop && (kind == 5 || kind == 6)) {
        float n = c_per;
        while (n > 0) {
            if (n < 1 && rnd() >= n) break;
            /* the effect is chosen while the prize is made (1ea280: from its type's +0x20 / +0x28): kind 5's entry
               lends the orb's name for this one call */
            u8 *k5 = g_base + PRIZE_TYPES + 5 * 0x50;
            const char *was = *(const char**)(k5 + 0x28);
            *(const char**)(k5 + 0x28) = *(const char**)(g_rec + 0x28);
            u8 *o = ((MakeFn)(g_base + MAKE_FN))(pos, 5, 0, 0, a5, a6);
            *(const char**)(k5 + 0x28) = was;
            if (o) { *(u8**)(o + 0x250) = g_rec; g_made++; }
            n -= 1;
        }
    }
    return p;
}
typedef void (MSABI *DropFn)(u8 *ent, void *pos, int pct, int a4, int a5);
static void MSABI drop_hook(u8 *ent, void *pos, int pct, int a4, int a5) {
    u8 *was = g_drop;
    g_drop = regular(ent) ? ent : NULL;
    ((DropFn)(g_base + DROP_FN))(ent, pos, pct, a4, a5);
    g_drop = was;
}
typedef void (MSABI *PickFn)(u8 *pl, u64 command, int a3, int a4);
static void MSABI pick_hook(u8 *pl, u64 command, int a3, int a4) {
    if (c_on && (u16)command == ORB_CMD) {
        u8 *m = MGR, *me = m ? *(u8**)(m + 0x118) : NULL;
        if (pl && pl == me) {
            mp_restore_pct(c_pct);
            g_got++;
            if (g_debug) LOG("sp orb: picked up, +%.1f%%", c_pct);
        }
        return;
    }
    ((PickFn)(g_base + PICK_FN))(pl, command, a3, a4);
}

/* An SCD bank (version 3, as BBS's): header 0x30, then at 0x50 the sound table; the track, audio and per-sound block
   tables at [0x38] / [0x3c] / [0x40], each 16-aligned after the one before; the blocks themselves from [0x48]; then
   the sounds, tracks and audio entries.  A sound (0x14): u8 track count, ..., f32 volume at +8, u32 number at +0xc,
   then {u16 track, u16 audio} pairs.  Returns a new bank with one more sound (number = the old count), or NULL. */
#define AL16(n) (((n) + 15u) & ~15u)
static u8 *se_extend(const u8 *b, u32 size, u32 *out_size, int *out_se) {
    if (size < 0x60 || memcmp(b, "SEDBSSCF", 8) || *(const u32*)(b + 8) != 3 || *(const u16*)(b + 0xe) != 0x30) return NULL;
    u32 ns = *(const u16*)(b + 0x30), nt = *(const u16*)(b + 0x32), na = *(const u16*)(b + 0x34);
    u32 to = *(const u32*)(b + 0x38), ao = *(const u32*)(b + 0x3c), lo = *(const u32*)(b + 0x40), lb = *(const u32*)(b + 0x48);
    if (*(const u32*)(b + 0x44) || ns <= DLINK_SE || ns >= 0xfff0 || nt >= 0xfff0 || na >= 0xfff0) return NULL;
    if (to != AL16(0x50 + 4 * ns) || ao != AL16(to + 4 * nt) || lo != AL16(ao + 4 * na) || lb != AL16(lo + 4 * ns) || lb > size) return NULL;
    const u32 *S = (const u32*)(b + 0x50), *T = (const u32*)(b + to), *A = (const u32*)(b + ao), *L = (const u32*)(b + lo);
    u32 sd = S[DLINK_SE], ld = L[DLINK_SE];
    if (sd < lb || sd + 0x14 > size || b[sd] != 1 || !ld || ld < lb || ld + 0x80 > size) return NULL;
    u32 nto = AL16(0x50 + 4 * (ns + 1)), nao = AL16(nto + 4 * (nt + 1)), nlo = AL16(nao + 4 * (na + 1)), nlb = AL16(nlo + 4 * (ns + 1));
    u32 D = nlb - lb, end = AL16(size + D);
    u32 pl = end, ps = pl + 0x80, pt = AL16(ps + 0x14), pa = AL16(pt + sizeof orbse_track), n = AL16(pa + sizeof orbse_audio);
    u8 *o = (u8*)calloc(1, n);
    if (!o) return NULL;
    memcpy(o, b, 0x50);
    memcpy(o + nlb, b + lb, size - lb);
    u32 *nS = (u32*)(o + 0x50), *nT = (u32*)(o + nto), *nA = (u32*)(o + nao), *nL = (u32*)(o + nlo);
    for (u32 i = 0; i < ns; i++) { nS[i] = S[i] ? S[i] + D : 0; nL[i] = L[i] ? L[i] + D : 0; }
    for (u32 i = 0; i < nt; i++) nT[i] = T[i] ? T[i] + D : 0;
    for (u32 i = 0; i < na; i++) nA[i] = A[i] ? A[i] + D : 0;
    nS[ns] = ps; nT[nt] = pt; nA[na] = pa; nL[ns] = pl;
    memcpy(o + pl, b + ld, 0x80);                                   /* the D-Link prize sound's block */
    memcpy(o + ps, b + sd, 0x14);                                   /* and its entry: one track */
    *(float*)(o + ps + 8) = c_vol; *(u32*)(o + ps + 0xc) = ns;
    *(u16*)(o + ps + 0x10) = (u16)nt; *(u16*)(o + ps + 0x12) = (u16)na;
    memcpy(o + pt, orbse_track, sizeof orbse_track);
    memcpy(o + pa, orbse_audio, sizeof orbse_audio);
    *(u16*)(o + 0x30) = (u16)(ns + 1); *(u16*)(o + 0x32) = (u16)(nt + 1); *(u16*)(o + 0x34) = (u16)(na + 1);
    *(u32*)(o + 0x38) = nto; *(u32*)(o + 0x3c) = nao; *(u32*)(o + 0x40) = nlo; *(u32*)(o + 0x48) = nlb;
    *(u32*)(o + 0x10) += n - size;
    *out_size = n; *out_se = (int)ns;
    return o;
}
typedef u32 (MSABI *BankFn)(u32 id, const u8 *scd, u32 size, u32 a4, int a5);
static u32 MSABI bank_hook(u32 id, const u8 *scd, u32 size, u32 a4, int a5) {
    static u8 *made; static u32 made_size; static const u8 *from; static u32 from_size;
    if (c_on && c_sound && scd && *(const u16*)(scd + 0x36) == 0) {       /* bank 0, the common SE */
        if (!(made && from == scd && from_size == size)) {
            u32 n; int se;
            u8 *x = se_extend(scd, size, &n, &se);
            if (x) { made = x; made_size = n; from = scd; from_size = size;
                     if (g_se < 0) LOG("sp orbs: KH2's MP orb sound added to the common SE bank as sound %d", se);
                     g_se = se; *(s16*)(g_rec + 0x44) = -1; *(s16*)(g_rec + 0x46) = (s16)se; }
            else LOG("sp orbs: the common SE bank is not as expected, the orbs keep the D-Link prize's sound");
        }
        if (made && from == scd) return ((BankFn)(g_base + BANK_FN))(id, made, made_size, a4, a5);
    }
    return ((BankFn)(g_base + BANK_FN))(id, scd, size, a4, a5);
}

static int call_ok(u32 rva, u32 target) {
    u8 *p = g_base + rva; s32 d; memcpy(&d, p + 1, 4);
    return p[0] == 0xE8 && (u32)(rva + 5 + d) == target;
}
static float ini_f(const char *key, float def) {
    char b[32], d[32]; snprintf(d, sizeof d, "%g", def);
    GetPrivateProfileStringA("SPOrbs", key, d, b, sizeof b, g_ini);
    return (float)atof(b);
}
int sporb_check(void) {
    c_on = (int)ini_f("Enabled", (float)c_on);
    c_per = ini_f("PerDLinkPrize", c_per); if (!(c_per >= 0 && c_per <= 5)) c_per = 1.0f;
    c_pct = ini_f("SPPercent", c_pct); if (!(c_pct >= 0 && c_pct <= 100)) c_pct = 2.0f;
    c_look = (int)ini_f("Look", (float)c_look); if (c_look < 0 || c_look > 2) c_look = 1;
    c_sound = (int)ini_f("Sound", (float)c_sound);
    c_vol = ini_f("SoundVolume", c_vol); if (!(c_vol > 0 && c_vol <= 2)) c_vol = 1.0f;
    if (!c_on) return 1;
    int bad = 0;
    for (int i = 0; i < 2; i++) if (!call_ok(DEATH_CALLS[i], DROP_FN)) { LOG("sp orbs: defeat drop call %x does not match", DEATH_CALLS[i]); bad++; }
    if (!call_ok(MAKE_CALL, MAKE_FN)) { LOG("sp orbs: prize call does not match"); bad++; }
    if (!call_ok(PICK_CALL, PICK_FN)) { LOG("sp orbs: pickup call does not match"); bad++; }
    if (c_sound && !call_ok(BANK_CALL, BANK_FN)) { LOG("sp orbs: SE bank call does not match, the orbs keep the D-Link prize's sound"); c_sound = 0; }
    const u8 *k5 = g_base + PRIZE_TYPES + 5 * 0x50;
    if (*(const u32*)(k5 + 0x40) != 0x1e4) { LOG("sp orbs: prize type 5 is not the D-Link prize"); bad++; }
    else { const char *nm = *(const char* const*)(k5 + 0x28); if (!nm || strcmp(nm, "SYS_PRZ_001_0")) { LOG("sp orbs: prize type 5 has another effect"); bad++; } }
    if (G(u8, 0x814900 + ORB_CMD * 0x18) != 10) { LOG("sp orbs: command %x is not a prize", ORB_CMD); bad++; }
    return bad == 0;
}
void sporb_apply(void) {
    if (!c_on) { LOG("sp orbs: off"); return; }
    memcpy(g_rec, g_base + PRIZE_TYPES + 5 * 0x50, sizeof g_rec);
    *(u32*)(g_rec + 0x40) = ORB_CMD;
    *(const char**)(g_rec + 0x28) = k_look[c_look];                 /* the effect's name in the prize effects */
    for (int i = 0; i < 2; i++) hook_call(DEATH_CALLS[i], DROP_FN, drop_hook, "defeat drops (SP orbs)");
    hook_call(MAKE_CALL, MAKE_FN, make_hook, "prize (SP orbs)");
    hook_call(PICK_CALL, PICK_FN, pick_hook, "prize pickup (SP orbs)");
    if (c_sound) hook_call(BANK_CALL, BANK_FN, bank_hook, "common SE bank (SP orb sound)");
    LOG("sp orbs: %.2f per D-Link prize from a defeated regular enemy, %.1f%% SP each", c_per, c_pct);
}

#ifndef _WIN32
int *test_sporb_counts(void) { static int c[2]; c[0] = g_made; c[1] = g_got; return c; }
void test_sporb_reset(void) { g_made = g_got = 0; }
u8 *test_sporb_rec(void) { return g_rec; }
float *test_sporb_cfg(void) { return &c_per; }
float *test_sporb_pct(void) { return &c_pct; }
u8 *test_sporb_se_extend(const u8 *b, u32 size, u32 *n, int *se) { return se_extend(b, size, n, se); }
u32 test_sporb_bank(u32 id, const u8 *scd, u32 size) { return bank_hook(id, scd, size, 0, 0); }
int test_sporb_se(void) { return g_se; }
#endif
