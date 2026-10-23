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
   2733d0); the one call to 273420 (at 273408) is hooked, and 0x1ef from there is the orb. */
#include "mod.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

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

static int   c_on = 1;              /* [SPOrbs] Enabled */
static float c_per = 1.0f;          /* orbs per D-Link prize (a fraction = that chance of one) */
static float c_pct = 2.0f;          /* percent of max SP per orb (also the recharge it adds in an SP charge) */
static int   c_look = 1;            /* the effect it is drawn with: 0 the small D-Link prize's, 1 SYS_PRZ_100_0 (in the
                                       prize effects s_ex_prz_00.fep but used by no prize type), 2 SYS_PRZ_003_0 */
static const char *const k_look[3] = { "SYS_PRZ_001_0", "SYS_PRZ_100_0", "SYS_PRZ_003_0" };
static u8    g_rec[0x50];           /* the orb's prize type: kind 5's, command 0x1ef */
static u8   *g_drop;                /* the defeated regular enemy whose drops are being made */
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
    if (!c_on) return 1;
    int bad = 0;
    for (int i = 0; i < 2; i++) if (!call_ok(DEATH_CALLS[i], DROP_FN)) { LOG("sp orbs: defeat drop call %x does not match", DEATH_CALLS[i]); bad++; }
    if (!call_ok(MAKE_CALL, MAKE_FN)) { LOG("sp orbs: prize call does not match"); bad++; }
    if (!call_ok(PICK_CALL, PICK_FN)) { LOG("sp orbs: pickup call does not match"); bad++; }
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
    LOG("sp orbs: %.2f per D-Link prize from a defeated regular enemy, %.1f%% SP each", c_per, c_pct);
}

#ifndef _WIN32
int *test_sporb_counts(void) { static int c[2]; c[0] = g_made; c[1] = g_got; return c; }
void test_sporb_reset(void) { g_made = g_got = 0; }
u8 *test_sporb_rec(void) { return g_rec; }
float *test_sporb_cfg(void) { return &c_per; }
float *test_sporb_pct(void) { return &c_pct; }
#endif
