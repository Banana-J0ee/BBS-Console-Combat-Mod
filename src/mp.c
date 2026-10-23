/* MP pool in place of per-command reloads, and the MP bar on the HUD.

   Game objects used here (rva = offset from the exe image base):
     PlayerData            0x10f9eeb0   +0x31 level
     PL::CPlayerCommand*   [0x10f9ed40] +0x60/+0x64 flags, +0x1e0 deck plates[8], +0x220 count, +0xc8 D-Link prompt
     Gauge::CPlayerGauge*  [0x10f9ec60] +0x20 dt (60 Hz ticks), +0x8c HUD layout handle
     PL::CPlayerManager*   [0x10f9ee40] +0x118 player
     PL::CCommandPlate     +0x30 type (2 = deck), +0x31 state, +0x58 COMMAND*, +0x60 flags (0x2 unavailable,
                           0x800 item), +0x64 reload percent, +0x6c list position
   See docs/NOTES.md for how these were found. */
#include "core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "steals_gen.h"
#include "mod.h"

extern char g_dir[MAX_PATH], g_ini[MAX_PATH + 32];
extern int g_debug;
void dbg_frame(void);

#define PD      ((u8*)RVA(0x10f9eeb0))
#define CMD     G(u8*, 0x10f9ed40)
#define GAUGE   G(u8*, 0x10f9ec60)
#define MGR     G(u8*, 0x10f9ee40)
static u8 *player(void) { u8 *m = MGR; return m ? *(u8**)(m + 0x118) : NULL; }

/* command tables in the exe */
#define CMD_TYPE(id)   G(u8, 0x814900 + (u32)(id) * 0x18 + 0)
#define CMD_CAT(id)    G(u8, 0x814900 + (u32)(id) * 0x18 + 1)
#define CMD_SUB(id)    G(u8, 0x814900 + (u32)(id) * 0x18 + 3)
#define CMD_CLASS(id)  (G(u8, 0x814900 + (u32)(id) * 0x18 + 4) & 15)       /* 1..3: the command's rank */
#define CMD_RELOAD(id) G(u8, 0x811080 + (u32)(id) * 0x1e + 3)
#define CMD_MAX 0x23a

/* ---------------- settings (bbskh2.ini) ---------------- */
static float c_max_base = 60.0f;       /* baseline MP */
static float c_max_base_crit = 20.0f;  /* ... on Critical */
static float c_max_per_slot = 10.0f;   /* extra MP per command deck slot the character has (filled or not) */
static float c_max_per_level = 0.0f;   /* extra MP per level above 1 */
static float c_cost_scale = 1.0f;      /* MP cost = command's reload seconds x this */
static int   c_cure_all = 1;           /* Cure/Cura/Curaga use all remaining MP (KH2 rule) */
static float c_charge_seconds = 25.0f; /* MP charge: seconds to recharge from empty (KH2: 50) */
static float c_haste_bonus = 0.10f;    /* ... divided by 1 + this for every Magic Haste ("MP Haste") installed */
static int   c_haste_rename = 1;       /* it is shown as MP Haste, with a description of what it does here */
static char  c_haste_name[48], c_haste_help[256];
static int   c_haste_name_set, c_haste_help_set;   /* given in the ini: used whatever the game's language */
/* Attack Haste is this mod's MP Rage (KH2): damage taken gives MP back, outside the MP charge.
   KH2 FM (1403d5600): MP += (int)(damage / max HP x DamageAspir), DamageAspir being 75 a copy (03system pref sstm).
   Weaker here, on request: losing a full HP bar gives back this percent of the MP bar with every copy the ability
   can have installed (5), a share of it with fewer. */
static float c_rage = 25.0f;           /* percent of max MP for a full HP bar lost, at the full stack (0 = off) */
static int   c_rage_rename = 1;
static char  c_rage_name[48], c_rage_help[256];
static int   c_rage_name_set, c_rage_help_set;
static float c_berserk_pct = 5.0f;     /* Reload Boost ("Berserker"): percent more damage dealt during MP charge (0 = off) */
static int   c_berserk_rename = 1;
static char  c_berserk_name[48], c_berserk_help[256];
static int   c_berserk_name_set, c_berserk_help_set;
static int   c_cursor_advance = 0;     /* 1 = cursor moves to the next command after a use (vanilla) */
static int   c_ether = 1;              /* Ether-type items restore MP */
static int   c_tiered = 1;             /* magic costs spread out by tier (see base_cost) */
static int   c_link_refill = 1;        /* starting a D-Link fills the MP bar and ends an MP charge, as a Drive Form does in KH2 */
static float c_link_keep = 100.0f;     /* percent of a full D-Link gauge that can be left once a D-Link has ended (game: 100, KH2: 0) */
static int   c_link_in_burn = 1;       /* a D-Link can be started during MP charge (0 = not until the bar is back) */
static int   c_dlink_cost = 1;         /* the commands only D-Link decks have cost by their class, their two cures as Cure (see base_cost) */
static float c_save_seconds = 1.0f;    /* standing on a save point: seconds for a full bar / a full recharge (0 = off) */
/* MP bar: right end and top edge in the game's screen units (480 x 272), thickness, length of the bar itself at
   100 MP, and the share of any extra MP that lengthens it */
/* The bar hangs under the Focus bar, whose outline ends at about y 253.9: 0.7 below that, 4.5 high, and 57.6 long at
   100 MP (the plate adds 11.7: 69.5 in all, as long as the first bar, so its left end is where that one's was).  Before that it was 7.5 high and 50 long at y 255.5. */
static float c_bar_right = 425.0f, c_bar_top = 254.6f, c_bar_height = 4.5f;
static float c_bar_len = 57.6f, c_bar_grow = 0.4f;
static int   c_bar = 1, c_bar_art = 1, c_bar_round = 1, c_bar_exact = 1;
/* colours AABBGGRR; 80 = the art's own colour, ff = twice as bright */
static u32 c_col_fill = 0x80808080, c_col_label = 0x80ff9030, c_col_empty = 0x80381810, c_col_frame = 0x80808080;
static u32 c_col_burn_fill = 0x80b860ff, c_col_burn_label = 0x80c060ff, c_col_burn_empty = 0x80280c20;

static float ini_f(const char *sec, const char *key, float def) {
    char p[MAX_PATH + 32], b[64], d[64];
    snprintf(p, sizeof p, "%s", g_ini); snprintf(d, sizeof d, "%g", def);
    GetPrivateProfileStringA(sec, key, d, b, sizeof b, p);
    return (float)atof(b);
}
/* a text; "\n" in it is a line break.  Returns 0 when the key is absent or empty. */
static int ini_s(const char *sec, const char *key, char *out, size_t n) {
    char b[512]; b[0] = 0;
    GetPrivateProfileStringA(sec, key, "", b, sizeof b, g_ini);
    size_t o = 0;
    for (const char *p = b; *p && o + 1 < n; p++) {
        if (p[0] == '\\' && p[1] == 'n') { out[o++] = '\n'; p++; }
        else out[o++] = *p;
    }
    out[o] = 0;
    return o != 0;
}
static u32 ini_x(const char *sec, const char *key, u32 def) {
    char p[MAX_PATH + 32], b[64], d[64];
    snprintf(p, sizeof p, "%s", g_ini); snprintf(d, sizeof d, "%08x", def);
    GetPrivateProfileStringA(sec, key, d, b, sizeof b, p);
    return (u32)strtoul(b, NULL, 16);
}
/* EXP Zero's minimum damage (1400d2960, table Exp0/Exp0Param.edp, loaded with the system files in every mode):
   the game applies it only when the player has the ability 0x1c9.  That test (the call at d29a5) is answered
   "yes" on Critical as well, so there the minimum holds for every hit (c_floor 2: on every difficulty).  The
   other effects of the ability (no EXP, the cap on damage taken) are untouched. */
#define FLOOR_CALL 0xd29a5
#define HAS_ABILITY 0x221900
#define DIFFICULTY G(u8, 0x10fa0881)        /* 0 Beginner, 1 Standard, 2 Proud, 3 Critical */
static int c_floor = 1;
static int c_desc_cost = 1;        /* MP cost at the end of command descriptions */
static int MSABI floor_ability_hook(u8 *player, u16 id) {
    if (FN(u8, HAS_ABILITY, u8*, u16)(player, id)) return 1;
    return c_floor >= 2 || (c_floor == 1 && DIFFICULTY == 3);
}
/* Boss HP ([BossHP]).  A boss's max HP is the float at +0xc of its .epd, taken as is (names starting with 'b'
   have no level scaling and no difficulty scaling): 1402d0700 when the .epd is loaded (6th argument != 0) and
   1402d2ec0 when the HP is set again from it.  After either, a listed boss gets percent x that value, max and
   current HP alike.  Only the value the game itself just wrote is changed, so nothing is scaled twice.
   Default: a ramp over the stories (Final Mix superbosses, Mirage Arena and the minigames left out). */
#define EPD_LOAD 0x2d0700
#define EPD_LOAD_A 0x2d2dd0
#define EPD_LOAD_B 0x2d2e24
#define EPD_LOAD_C 0x2d528e
#define EPD_LOAD_D 0x2d52b4
#define EPD_LOAD_E 0x2d52d2
#define EPD_LOAD_F 0x2d52f2
#define EPD_RESET 0x2d2ec0
#define EPD_RESET_A 0x2b7dfe
#define FLOOR_FN 0xd2960
#define FLOOR_FN_CALL 0x2d2510       /* the enemy damage function 1402d24b0 asks for EXP Zero's minimum */
#define FLOOR_BOSS_MAX 1500          /* the table's boss row ends there */
typedef struct { char name[8]; s16 pct; } BossHp;
static const BossHp k_boss_hp[] = {
    /* early-mid: x1.10 */
    { "b03sb00", 110 }, { "b10ex00", 110 }, { "b10ex01", 110 }, { "b32ex00", 110 },
    { "b01rg00", 110 }, { "b04rg00", 110 }, { "b05rg00", 110 }, { "b06rg00", 110 }, { "b07rg00", 110 }, { "b08rg00", 110 },
    /* mid: x1.20 */
    { "b30he00", 120 }, { "b40he00", 120 }, { "b01he00", 120 }, { "b10he00", 120 },
    { "b20ls00", 120 }, { "b01ls00", 120 }, { "b02ls00", 120 }, { "b10ls00", 120 },
    /* late worlds and the story finales: x1.30 */
    { "b01pp00", 130 }, { "b20pp00", 130 }, { "b10ex02", 130 }, { "b11ex00", 130 }, { "b20ex00", 130 },
    { "b30ex00", 130 }, { "b40ex00", 130 }, { "b63ex00", 130 }, { "b50ex00", 130 },
    /* Final Episode: x1.25 */
    { "b51ex00", 125 }, { "b52ex00", 125 },
};
#define BOSS_HP_MAX 96
static BossHp g_boss_hp[BOSS_HP_MAX];
static int g_boss_hp_n, c_boss_hp = 1;
static void boss_hp_set(const char *name, int pct) {
    if (!name[0] || strlen(name) > 7) return;
    if (pct < 10) pct = 100; if (pct > 500) pct = 500;
    for (int i = 0; i < g_boss_hp_n; i++) if (!strcmp(g_boss_hp[i].name, name)) { g_boss_hp[i].pct = (s16)pct; return; }
    if (g_boss_hp_n < BOSS_HP_MAX) { snprintf(g_boss_hp[g_boss_hp_n].name, 8, "%s", name); g_boss_hp[g_boss_hp_n++].pct = (s16)pct; }
}
static void boss_hp_config(void) {
    g_boss_hp_n = 0;
    for (unsigned i = 0; i < sizeof k_boss_hp / sizeof *k_boss_hp; i++) boss_hp_set(k_boss_hp[i].name, k_boss_hp[i].pct);
    c_boss_hp = (int)ini_f("BossHP", "Enabled", 1.0f);
    static char sec[8192]; sec[0] = sec[1] = 0;
    GetPrivateProfileSectionA("BossHP", sec, sizeof sec, g_ini);
    for (char *e = sec; *e; e += strlen(e) + 1) {
        char k[32]; int v;
        if (sscanf(e, " %31[^= ] = %d", k, &v) != 2) continue;
        for (char *c = k; *c; c++) if (*c >= 'A' && *c <= 'Z') *c += 32;
        if (k[0] != 'b') continue;
        boss_hp_set(k, v);
    }
}
static int boss_hp_pct(const char *name) {
    for (int i = 0; i < g_boss_hp_n; i++) if (!strncmp(name, g_boss_hp[i].name, 8)) return g_boss_hp[i].pct;
    return 100;
}
/* after the game set ent's HP from epd: the listed boss gets its share */
static void boss_hp_apply(u8 *ent, const u8 *epd) {
    if (!c_boss_hp || !ent || !epd || ent[0xf0] != 'b' || memcmp(epd, "@EPD", 4)) return;
    int pct = boss_hp_pct((const char*)ent + 0xf0);
    if (pct == 100) return;
    int base = (int)*(const float*)(epd + 0xc);
    s16 *cur = (s16*)(ent + 0x238), *max = (s16*)(ent + 0x23a);
    if (base <= 0 || *max != (s16)base) return;                  /* not the value the game just wrote */
    int hp = (base * pct + 50) / 100; if (hp > 32767) hp = 32767; if (hp < 1) hp = 1;
    *max = (s16)hp;
    if (*cur == (s16)base) *cur = (s16)hp;
}
static u64 MSABI epd_load_hook(u8 *ent, u64 a2, u64 a3, u64 a4, int slot, int set_hp) {
    u64 r = FN(u64, EPD_LOAD, u8*, u64, u64, u64, int, int)(ent, a2, a3, a4, slot, set_hp);
    if ((u32)r && set_hp && slot >= 0 && slot < 4) boss_hp_apply(ent, *(u8**)(ent + (0x49 + slot) * 8));
    return r;
}
static void MSABI epd_reset_hook(u8 *ent) {
    FN(void, EPD_RESET, u8*)(ent);
    boss_hp_apply(ent, *(u8**)(ent + 0x250));
}
/* EXP Zero's minimum reads the boss row of its table (max HP 200..1500): a boss given more HP than 1500 is
   looked up as 1500, so it keeps its minimum. */
static u64 MSABI floor_hp_hook(int *dmg, u32 id, int maxhp, const char *name) {
    if (c_boss_hp && name && name[0] == 'b' && maxhp > FLOOR_BOSS_MAX) maxhp = FLOOR_BOSS_MAX;
    return FN(u64, FLOOR_FN, int*, u32, int, const char*)(dmg, id, maxhp, name);
}
void test_boss_hp_apply(u8 *ent, const u8 *epd) { boss_hp_apply(ent, epd); }
void test_boss_hp_reset(u8 *ent) { epd_reset_hook(ent); }
u64 test_floor_hp(int *dmg, u32 id, int maxhp, const char *name) { return floor_hp_hook(dmg, id, maxhp, name); }
int test_boss_hp_pct(const char *name) { return boss_hp_pct(name); }
static void load_ini(void) {
    c_max_base = ini_f("MP", "MaxAtLevel1", c_max_base);
    c_max_base = ini_f("MP", "Baseline", c_max_base);
    c_max_base_crit = ini_f("MP", "BaselineCritical", c_max_base_crit);
    c_max_per_slot = ini_f("MP", "MaxPerDeckSlot", c_max_per_slot);
    c_max_per_level = ini_f("MP", "MaxPerLevel", c_max_per_level);
    c_cost_scale = ini_f("MP", "CostScale", c_cost_scale);
    c_cure_all = (int)ini_f("MP", "CureUsesAllMP", (float)c_cure_all);
    c_charge_seconds = ini_f("MP", "ChargeSeconds", c_charge_seconds);
    c_haste_bonus = ini_f("MP", "MPHasteBonus", c_haste_bonus);
    c_haste_rename = (int)ini_f("MP", "MPHasteRename", (float)c_haste_rename);
    c_haste_name_set = ini_s("MP", "MPHasteName", c_haste_name, sizeof c_haste_name);
    c_haste_help_set = ini_s("MP", "MPHasteHelp", c_haste_help, sizeof c_haste_help);
    if (!c_haste_name_set) snprintf(c_haste_name, sizeof c_haste_name, "SP Haste");
    c_rage = ini_f("MP", "MPRage", c_rage);
    if (!(c_rage >= 0 && c_rage <= 400)) c_rage = 25.0f;
    c_rage_rename = (int)ini_f("MP", "MPRageRename", (float)c_rage_rename);
    c_rage_name_set = ini_s("MP", "MPRageName", c_rage_name, sizeof c_rage_name);
    c_rage_help_set = ini_s("MP", "MPRageHelp", c_rage_help, sizeof c_rage_help);
    if (!c_rage_name_set) snprintf(c_rage_name, sizeof c_rage_name, "SP Rage");
    if (!c_rage_help_set) snprintf(c_rage_help, sizeof c_rage_help,
        "Restores some SP whenever you take damage, except\nduring an SP charge. Multi-install the ability to\nrestore even more.");
    if (!c_haste_help_set) {
        char pc[16]; snprintf(pc, sizeof pc, "%g", c_haste_bonus * 100.0f);
        snprintf(c_haste_help, sizeof c_haste_help, "Makes SP recharge %s%% faster once you have run out.\n"
                 "Multi-install the ability for an even quicker recharge.", pc);
    }
    c_berserk_pct = ini_f("MP", "BerserkerDamage", c_berserk_pct);
    c_berserk_rename = (int)ini_f("MP", "BerserkerRename", (float)c_berserk_rename);
    c_berserk_name_set = ini_s("MP", "BerserkerName", c_berserk_name, sizeof c_berserk_name);
    c_berserk_help_set = ini_s("MP", "BerserkerHelp", c_berserk_help, sizeof c_berserk_help);
    if (!c_berserk_name_set) snprintf(c_berserk_name, sizeof c_berserk_name, "Berserker");
    if (!c_berserk_help_set) {
        char pc[16]; snprintf(pc, sizeof pc, "%g", c_berserk_pct);
        snprintf(c_berserk_help, sizeof c_berserk_help, "Increases the damage you deal by %s%% while SP is\nrecharging.", pc);
    }
    c_cursor_advance = (int)ini_f("MP", "CursorAdvance", (float)c_cursor_advance);
    c_ether = (int)ini_f("MP", "EtherRestoresMP", (float)c_ether);
    c_save_seconds = ini_f("MP", "SavePointSeconds", c_save_seconds);
    c_tiered = (int)ini_f("MP", "TieredMagic", (float)c_tiered);
    c_dlink_cost = (int)ini_f("MP", "DLinkCostByClass", (float)c_dlink_cost);
    c_link_in_burn = (int)ini_f("MP", "DLinkDuringCharge", (float)c_link_in_burn);
    c_link_refill = (int)ini_f("MP", "DLinkRefillsMP", (float)c_link_refill);
    c_link_keep = ini_f("MP", "DLinkGaugeAfter", c_link_keep);
    if (!(c_link_keep >= 0.0f && c_link_keep <= 100.0f)) c_link_keep = 0.0f;
    c_floor = (int)ini_f("Combat", "DamageFloor", (float)c_floor);
    boss_hp_config();
    c_desc_cost = (int)ini_f("Menu", "DescriptionCost", (float)c_desc_cost);
    for (int id = 0x5b; id < 0x1a0; id++) {             /* the deck commands */
        char key[8]; snprintf(key, sizeof key, "%x", id);
        float v = ini_f("Cost", key, 0);
        extern s16 *mp_cost_overrides(void);
        mp_cost_overrides()[id] = v > 0 ? (s16)(v + 0.5f) : 0;
    }
    c_bar = (int)ini_f("Bar", "Show", (float)c_bar);
    c_bar_art = (int)ini_f("Bar", "KH2Art", (float)c_bar_art);
    c_bar_round = (int)ini_f("Bar", "RoundEnd", (float)c_bar_round);
    c_bar_exact = (int)ini_f("Bar", "ExactSize", (float)c_bar_exact);
    c_bar_right = ini_f("Bar", "Right", c_bar_right);
    c_bar_top = ini_f("Bar", "Top", c_bar_top);
    c_bar_height = ini_f("Bar", "Height", c_bar_height);
    c_bar_len = ini_f("Bar", "BarLength", c_bar_len);
    c_bar_grow = ini_f("Bar", "Growth", c_bar_grow);
    c_col_fill = ini_x("Bar", "Fill", c_col_fill);
    c_col_label = ini_x("Bar", "Label", c_col_label);
    c_col_empty = ini_x("Bar", "Empty", c_col_empty);
    c_col_frame = ini_x("Bar", "Frame", c_col_frame);
    c_col_burn_fill = ini_x("Bar", "BurnFill", c_col_burn_fill);
    c_col_burn_label = ini_x("Bar", "BurnLabel", c_col_burn_label);
    c_col_burn_empty = ini_x("Bar", "BurnEmpty", c_col_burn_empty);
    if (c_bar_height < 2) c_bar_height = 2;
    tex_enable(c_bar_art);
    if (c_max_base < 1) c_max_base = 1;
    if (c_max_base_crit < 1) c_max_base_crit = 1;
    if (c_charge_seconds < 0.1f) c_charge_seconds = 0.1f;
}

/* ---------------- MP state ---------------- */
static float g_mp = 100.0f, g_mpmax = 100.0f;
static int   g_burn;            /* 1 while recharging after running out */
static float g_charge;          /* recharge progress, 0..100 */
static float g_time;            /* ticks, for the pulse */
static int   g_fresh = 1;       /* fill to max at the next tick (new game / load) */

/* PlayerData +0x31 level, +0x36 number of command deck slots the character has (3 at the start, up to 8; the deck
   menu's "Deck Max Slots").  The baseline is lower on Critical (difficulty byte 3). */
static float max_mp(void) {
    int lv = PD[0x31]; if (lv < 1) lv = 1;
    int slots = PD[0x36]; if (slots > 8) slots = 8;
    return (DIFFICULTY == 3 ? c_max_base_crit : c_max_base) + c_max_per_slot * (float)slots + c_max_per_level * (float)(lv - 1);
}
/* Base cost of a command = its original reload time in seconds.  Magic is spread out by tier (ini TieredMagic):
   the game gives a spell and its -ra version the same time, so the -ra spells go from 10 to 15, and what was 15 /
   20 (the -ga spells and the stronger ones) moves up to 20 / 25.  [Cost] <hex id>=<MP> in the ini overrides any
   single command.

   The fourteen commands that only D-Link decks have (e4..f1, category 8: Mickey's Holy, Cinderella's four, the
   seven dwarfs, Vanitas's two) all reload in 5 seconds in the game - their limit there is the D-Link's own gauge -
   which made them 5 MP: a heal as strong as Curaga for 5, attacks stronger than a 20 MP command for 5.  They are
   costed as the game costs every ordinary command, by class: class 1 reloads in 10, class 2 in 15, class 3 in 20
   (one-slot attack and magic commands, with a handful of exceptions).  The two that heal (e8 Cinderella's, e9 Doc;
   strength 100 / 125 / 150 by D-Link level where Curaga's is 100) are cures: 30 like Cure, and all remaining MP
   under CureUsesAllMP.  ini DLinkCostByClass = 0 puts the 5 back. */
static s16 g_cost_over[CMD_MAX];        /* 0 = none */
static int is_dlink_only(int id) { return id >= 0xe4 && id <= 0xf1; }
static int is_dlink_cure(int id) { return id == 0xe8 || id == 0xe9; }
static int base_cost(int id) {
    if (g_cost_over[id] > 0) return g_cost_over[id];
    int c = CMD_RELOAD(id);
    if (c_dlink_cost && is_dlink_only(id)) {
        if (is_dlink_cure(id)) return 30;
        int cls = CMD_CLASS(id);
        return cls >= 3 ? 20 : cls == 2 ? 15 : 10;
    }
    if (c_tiered && CMD_CAT(id) == 2) {
        switch (id) {
        case 0x84: case 0x8b: case 0x8f: case 0x9a: case 0x9d: case 0xa3: case 0xb9: return 15;   /* Fira, Blizzara, Thundara, Zero Gravira, Magnera, Aerora, Stopra */
        case 0xba: return 20;                                                                       /* Stopga */
        }
        if (c == 15) return 20;
        if (c == 20) return 25;
    }
    return c;
}
float mp_cost(int id) {
    if (id <= 0 || id >= CMD_MAX) return 0;
    float c = (float)base_cost(id) * c_cost_scale;
    return c < 1.0f ? 1.0f : c;
}
/* Cure, Cura, Curaga, and the D-Link decks' two heals: what CureUsesAllMP is about.  A command with a cost of its
   own in [Cost] is not one of them: that cost is what it costs, as the ini says. */
static int is_cure(int id) {
    if (id <= 0 || id >= CMD_MAX || g_cost_over[id] > 0) return 0;
    return (id >= 0x92 && id <= 0x94) || (c_dlink_cost && is_dlink_cure(id));
}

/* would using this command now end in MP burn?  (what the menu marks) */
s16 *mp_cost_overrides(void) { return g_cost_over; }
int *test_dlink_cost(void) { return &c_dlink_cost; }
int mp_would_burn(int id) {
    if (g_burn || id <= 0 || id >= CMD_MAX || mp_fx(id)) return 0;     /* Focus Exchange: no MP charge to warn of */
    if (c_cure_all && is_cure(id)) return 1;
    return g_mp - mp_cost(id) < 0.5f;
}
/* ---------------- MP cost in the command descriptions ----------------
   The camp menu's help line (deck, shop, meld ...) shows message 0x320000 + command id through SetNodeMsg
   (1401a8170), which looks the text up with 1401b3750 and hands it to the text object, which copies it.  That
   lookup call is hooked: for a command that costs MP the cost is added at the end, in the text engine's green
   (character code f951 = colour style 2, f941 = back to the text's own colour; the descriptions use f959, yellow,
   the same way for "(Uses two slots.)").  A last line that would get longer than the game's longest line gets
   the cost on a line of its own while the box (three lines) has room. */
#define DESC_CALL 0x1a81bf
#define MSG_FIND  0x1b3750
#define DESC_MSG  0x320000u
#define DESC_MAX_LINE 54                 /* longest line of the original descriptions */
static char g_desc[768];
static int costs_mp(int id) { return id >= 0x5b && id <= 0xe3 && CMD_CAT(id) != 3; }    /* deck commands, not items */
/* ---------------- Focus Exchange (2026-10-23; the ability is combomaster.c's) ----------------
   With the ability on, a physical deck command (category 1, Attack: the red keyblade icon) costs its SP cost in Focus
   instead (the gauge's own 0..100 at gauge+0x68, the shotlocks' gauge), and SP is not touched.  Unlike SP it needs the
   whole cost: below it the command is unavailable (its plate in the "not ready" look, its reload fill showing how
   far the Focus has got), and it never leads into anything like an MP charge.  It can be used during an MP charge.
   Where the game has the Focus gauge switched off (gauge flag 0x100000), the command costs SP as usual. */
static int fx_physical(int id) { return id > 0 && id < CMD_MAX && costs_mp(id) && CMD_CAT(id) == 1; }
int mp_fx(int id) {
    if (!focusx_on() || !fx_physical(id)) return 0;
    u8 *g = GAUGE;
    return g && !(*(u32*)(g + 0x84) & 0x100000);
}
static float fx_focus(void) { u8 *g = GAUGE; return g ? *(float*)(g + 0x68) : 0; }
static int fx_ready(int id) { return fx_focus() + 0.001f >= mp_cost(id); }
static float fx_progress(int id) {         /* the plate's fill: how far the Focus is towards the cost (100 = ready) */
    if (fx_ready(id)) return 100.0f;
    float c = mp_cost(id), p = c > 0 ? fx_focus() * 100.0f / c : 0;
    return p > 99.0f ? 99.0f : p < 0 ? 0 : p;
}
/* the Focus gauge's own setter (20ad00) for the new value; it starts the shotlock "consume" display when asked for 0
   and keeps the MAX look and drops the pending gain on its own, so those three are handled here */
static void fx_spend(int id) {
    u8 *g = GAUGE; if (!g) return;
    float before = fx_focus(), v = before - mp_cost(id), pend = *(float*)(g + 0x6c);
    if (v < 0) v = 0;
    int h = *(int*)(g + 0x8c);
    *(u32*)(g + 0x84) &= ~0x10000u;                                 /* no longer MAX */
    if (h > 0) FN(int, 0x1a7db0, int, u16, int)(h, 0xde, 0);         /* the fill's plain control, not the MAX glow */
    if (v > 0.01f) FN(void, 0x20ad00, u8*, float)(g, v);
    else { *(float*)(g + 0x68) = 0; if (h > 0) FN(int, 0x1a7d30, int, u16, float, int)(h, 0xde, 0.0f, 0); }
    *(float*)(g + 0x6c) = pend;
    if (g_debug) LOG("focus exchange: command %x costs %.1f FP -> %.1f", id, mp_cost(id), *(float*)(g + 0x68));
}
static int plate_id(u8 *P) { u16 *k = P ? *(u16**)(P + 0x58) : NULL; return k ? k[0] : 0; }
static int text_width(const u8 *p, const u8 *end) {        /* characters shown, roughly */
    int n = 0;
    while (p < end) {
        if (*p >= 0x81) { n += (*p == 0xf9 || *p == 0xf0) ? 0 : 2; p += p + 1 < end ? 2 : 1; }
        else { n++; p++; }
    }
    return n;
}
/* the description with its cost added; NULL when there is nothing to add */
static const char *desc_with_cost(int id, const char *text) {
    if (!c_desc_cost || !text || !costs_mp(id)) return NULL;
    char cost[32]; float c = mp_cost(id);
    const char *unit = focusx_on() && fx_physical(id) ? "FP" : "SP";     /* Focus Exchange on: what it costs is Focus */
    if (c_cure_all && is_cure(id)) snprintf(cost, sizeof cost, "SP All");
    else if (c == (float)(int)c) snprintf(cost, sizeof cost, "%s %d", unit, (int)c);
    else snprintf(cost, sizeof cost, "%s %.1f", unit, c);
    size_t n = strlen(text);
    if (n + strlen(cost) + 8 > sizeof g_desc) return NULL;
    while (n && (text[n - 1] == ' ' || text[n - 1] == '\n')) n--;
    int lines = 1; const char *last = text;
    for (size_t i = 0; i < n; i++) if (text[i] == '\n') { lines++; last = text + i + 1; }
    int wide = text_width((const u8*)last, (const u8*)text + n) + 1 + (int)strlen(cost) > DESC_MAX_LINE;
    memcpy(g_desc, text, n);
    snprintf(g_desc + n, sizeof g_desc - n, "%s\xf9\x51%s\xf9\x41", !n ? "" : wide && lines < 3 ? "\n" : " ", cost);
    return g_desc;
}
/* The items that restore MP as well as Focus (item_effect_hook) say so in their descriptions.  English game text
   only: the replacement is used when the game's text starts as expected, so another language keeps its own. */
static const struct { u16 id; const char *was, *now; } g_item_desc[] = {
    { 0xbf, "Can be used once to restore a large portion of",                        /* Ether: 50 % */
      "Can be used once to restore half of your SP and a\nlarge portion of the Focus Gauge." },
    { 0xc0, "Can be used once to completely restore the",                           /* Mega-Ether: 100 % */
      "Can be used once to completely restore your SP\nand the Focus Gauge." },
    { 0xc2, "Can be used once to completely restore your HP",                       /* Elixir: 100 % */
      "Can be used once to completely restore your HP, SP\nand the Focus Gauge. Also eliminates all negative\nstatus effects." },
    { 0xc3, "Can be used once to completely restore HP,",                           /* Megalixir: 100 % */
      "Can be used once to completely restore HP and SP,\nas well as the Focus and D-Link Gauges.\nAlso eliminates all negative status effects." },
};
static const char *item_desc(int id, const char *text) {
    if (!c_ether || !text) return NULL;
    for (unsigned i = 0; i < sizeof g_item_desc / sizeof *g_item_desc; i++)
        if (g_item_desc[i].id == id && !strncmp(text, g_item_desc[i].was, strlen(g_item_desc[i].was))) return g_item_desc[i].now;
    return NULL;
}
static int MSABI desc_hook(u32 msg, const char **text, void **layout, u16 *extra, char flag) {
    int r = FN(int, MSG_FIND, u32, const char**, void**, u16*, char)(msg, text, layout, extra, flag);
    if (r && text && *text && msg - DESC_MSG < CMD_MAX) {
        const char *t = item_desc((int)(msg - DESC_MSG), *text);
        if (!t) t = desc_with_cost((int)(msg - DESC_MSG), *text);
        if (t) *text = t;
    }
    return r;
}
const char *test_item_desc(int id, const char *text) { return item_desc(id, text); }
const char *test_desc(int id, const char *text) { return desc_with_cost(id, text); }
void *test_desc_hook(void) { return (void*)desc_hook; }

/* how much of the bar is filled: MP / max; during an MP charge the pink bar starts full and drains as the charge
   runs, as in KH2 (it used to fill up), then the bar is blue and full again */
static float bar_frac(void) {
    float f = g_burn ? 1.0f - g_charge / 100.0f : (g_mpmax > 0 ? g_mp / g_mpmax : 0);
    if (f < 0) f = 0; if (f > 1) f = 1;
    return f;
}
float test_bar_frac(void) { return bar_frac(); }
static void burn_start(void) { g_mp = 0; g_burn = 1; g_charge = 0; if (g_debug) LOG("mp: burn starts"); }
static void burn_end(void)   { g_burn = 0; g_charge = 0; g_mp = g_mpmax; if (g_debug) LOG("mp: burn ends, MP %.0f", g_mp); }

static void mp_spend(int id) {
    float c = mp_cost(id);
    if (c_cure_all && is_cure(id)) c = g_mp;
    g_mp -= c;
    if (g_debug) LOG("mp: command %x costs %.1f -> %.1f / %.0f", id, c, g_mp < 0 ? 0 : g_mp, g_mpmax);
    if (g_mp < 0.5f) burn_start();
}
static void mp_restore(float pct) {     /* pct of the maximum */
    if (g_burn) { g_charge += pct; if (g_charge >= 100.0f) burn_end(); }
    else { g_mp += g_mpmax * pct * 0.01f; if (g_mp > g_mpmax) g_mp = g_mpmax; }
    if (g_debug) LOG("mp: restored %.0f%% -> %.1f (burn %d, charge %.0f)", pct, g_mp, g_burn, g_charge);
}

void mp_restore_pct(float pct) { if (pct > 0) mp_restore(pct); }      /* SP orbs (sporb.c) */
/* ---------------- deck plates ---------------- */
static int plate_count(u8 *cmd) { int n = *(u16*)(cmd + 0x220); return n > 8 ? 8 : n; }
static u8 *plate_of(u8 *cmd, const void *command) {
    int n = plate_count(cmd);
    for (int i = 0; i < n; i++) {
        u8 *P = *(u8**)(cmd + 0x1e0 + i * 8);
        if (P && *(void**)(P + 0x58) == command) return P;
    }
    return NULL;
}
int mp_in_burn(void) { return g_burn; }
/* MP charge keeps a new D-Link from being started (only with DLinkDuringCharge = 0) */
int mp_blocks_link(void) { return g_burn && !c_link_in_burn; }
int *test_link_in_burn(void) { return &c_link_in_burn; }
void mp_get(float *cur, float *max) { *max = max_mp(); *cur = g_fresh ? *max : g_burn ? 0 : g_mp > *max ? *max : g_mp; }
static float burn_pct(void);
float mp_burn_pct(void) { return burn_pct(); }
static float burn_pct(void) { float c = g_charge; if (c > 99.0f) c = 99.0f; if (c < 0) c = 0; return c; }

/* 233d40: the deck button was pressed on plate P; vanilla calls 2063c0(P), which returns the COMMAND or 0 */
static u8 *MSABI use_hook(u8 *P) {
    int item = (*(u32*)(P + 0x60) & 0x800) != 0;
    int id = item ? 0 : plate_id(P);
    if (!item && mp_fx(id)) {                      /* Focus Exchange: Focus, the whole cost, MP charge or not */
        if (!fx_ready(id)) return NULL;
        u8 *c = FN(u8*, 0x2063c0, u8*)(P);
        if (c) { fx_spend(id); *(float*)(P + 0x64) = fx_progress(id); }
        return c;
    }
    if (!item && g_burn) return NULL;
    u8 *c = FN(u8*, 0x2063c0, u8*)(P);
    if (c && !item) {
        mp_spend(*(u16*)c);
        *(float*)(P + 0x64) = g_burn ? 0.0f : 100.0f;
    }
    return c;
}
u8 *mp_use(u8 *P) { return use_hook(P); }
/* 206a6e: percent a reloading plate gains this frame (vanilla 1ce550). No reloads: ready at once, or held at the
   recharge progress while in MP burn. */
static float MSABI reload_hook(const void *command, float factor, float dt) {
    (void)factor; (void)dt;
    int fid = command ? *(const u16*)command : 0;
    if (mp_fx(fid)) {                              /* Focus Exchange: ready once the Focus covers the cost */
        u8 *cmd = CMD; u8 *P = cmd ? plate_of(cmd, command) : NULL;
        return P ? fx_progress(fid) - *(float*)(P + 0x64) : 0.0f;
    }
    if (!g_burn) return 100.0f;
    u8 *cmd = CMD; u8 *P = cmd ? plate_of(cmd, command) : NULL;
    if (!P) return 0.0f;
    return burn_pct() - *(float*)(P + 0x64);
}
/* while in MP burn every command (not items) shows as unavailable */
static void plates_block(u8 *cmd) {
    int n = plate_count(cmd);
    for (int i = 0; i < n; i++) {
        u8 *P = *(u8**)(cmd + 0x1e0 + i * 8);
        if (!P || P[0x30] != 2) continue;
        u32 fl = *(u32*)(P + 0x60);
        if (fl & (0x800 | 0x80000000u | 0x2)) continue;     /* item / not built yet / already unavailable */
        if (P[0x31] >= 2) continue;                          /* sliding: wait until it is idle */
        if (mp_fx(plate_id(P))) continue;                    /* Focus Exchange: its own rule (fx_block) */
        *(float*)(P + 0x64) = burn_pct();
        *(u32*)(P + 0x60) = fl | 2;
        FN(void, 0x2060d0, u8*)(P);                           /* the game's own redraw of a plate */
    }
}
/* Focus Exchange: a ready physical command whose cost the Focus no longer covers is made unavailable, as plates_block
   does in an MP charge; reload_hook makes it ready again once the Focus has come up to the cost */
static void fx_block(u8 *cmd) {
    int n = plate_count(cmd);
    for (int i = 0; i < n; i++) {
        u8 *P = *(u8**)(cmd + 0x1e0 + i * 8);
        if (!P || P[0x30] != 2) continue;
        u32 fl = *(u32*)(P + 0x60);
        if (fl & (0x800 | 0x80000000u | 0x2)) continue;
        if (P[0x31] >= 2) continue;
        int id = plate_id(P);
        if (!mp_fx(id) || fx_ready(id)) continue;
        *(float*)(P + 0x64) = fx_progress(id);
        *(u32*)(P + 0x60) = fl | 2;
        FN(void, 0x2060d0, u8*)(P);
    }
}
/* any physical command in the deck that Focus Exchange lets through an MP charge (the menu's Skills entry and list) */
int mp_fx_any(u8 *cmd) {
    if (!cmd || !focusx_on()) return 0;
    int n = plate_count(cmd);
    for (int i = 0; i < n; i++) { u8 *P = *(u8**)(cmd + 0x1e0 + i * 8);
        if (P && P[0x30] == 2 && !(*(u32*)(P + 0x60) & 0x800) && mp_fx(plate_id(P))) return 1; }
    return 0;
}

/* 2388a0: open the D-Link list (returns 1 when opened).  A D-Link is not a command and costs no MP, so being out
   of MP does not stand in its way (its deck's commands wait for the charge like any others).  With
   DLinkDuringCharge = 0, the first rule: not while in MP charge, unless a link is active (so that it can still be
   ended). */
static int (MSABI *o_dlink_open)(u8 *cmd);
static int MSABI dlink_open_hook(u8 *cmd) {
    if (mp_blocks_link() && !(*(u32*)(cmd + 0x64) & 0x80)) {
        FN(int, 0x1a5b30, int, int)(*(int*)(cmd + 0xc8), 0);
        return 0;
    }
    return o_dlink_open(cmd);
}
/* 205ee0: confirm an entry of the D-Link list (returns its COMMAND*, 0 = refused: the entry is used up or is not a
   D-Link).  This is the player starting a D-Link, and the one place that is: a link carried into the next room
   does not come through here.  Starting one fills the MP bar and ends an MP charge, as a Drive Form does in KH2
   (ini DLinkRefillsMP) - since 2026-10-23 only with the Link Charge ability on (combomaster.c), whose price is a
   D-Link that drains twice as fast (link_drain); not when a link is already active, where the list is only there
   to end it. */
static u8 *(MSABI *o_dlink_pick)(u8 *P);
static u8 *MSABI dlink_pick_hook(u8 *P) {
    u8 *cmd = CMD;
    int linked = cmd && (*(u32*)(cmd + 0x64) & 0x80);
    if (mp_blocks_link() && cmd && !linked) return NULL;
    u8 *c = o_dlink_pick(P);
    if (c && cmd && !linked && c_link_refill && linkcharge_on()) {        /* only with the Link Charge ability */
        if (g_burn) burn_end(); else g_mp = g_mpmax;
        if (g_debug) LOG("mp: D-Link started, MP %.0f / %.0f", g_mp, g_mpmax);
    }
    return c;
}
u8 *test_dlink_pick(u8 *P) { return dlink_pick_hook(P); }

/* A D-Link ends.  The player's style change back to normal (28a950) ends the gauge's "linked" mode with 208390(gauge,
   now) at two places [28ac09: the revert, by the D-Link list's "end link", by the gauge running out, or a forced
   end; 28ae3d: a D-Link finisher].  In the game the time left stays on the gauge, so a link ended early is most of a
   full gauge again: a hit or two and the next D-Link (full HP, and here full MP) is ready.  KH2's Drive Forms spend
   their cost when they start (1403c2780: the bars are taken away, and the partial bar too when the gauge was full)
   and keep the form's time on a gauge of its own, which a revert simply throws away.  The same here: once a link
   has ended the gauge holds at most DLinkGaugeAfter percent (0).  Illusions (gauge flag 0x8000) are not D-Links. */
#define LINK_END_A 0x28ac09u
#define LINK_END_B 0x28ae3du
#define LINK_END   0x208390u
static void (MSABI *g_link_set)(u8 *g, float v);           /* 20ac70 = set the D-Link gauge (and its HUD state) */
static void MSABI link_end_hook(u8 *g, int now) {
    u32 fl = g ? *(u32*)(g + 0x84) : 0;
    int linked = (fl & 0x200) && !(fl & 0x8000);
    float v = linked ? *(float*)(g + 0x60) : 0.0f;
    FN(void, LINK_END, u8*, int)(g, now);
    if (linked && v > c_link_keep) {
        g_link_set(g, c_link_keep);
        if (g_debug) LOG("mp: D-Link over with %.0f left on the gauge: down to %.0f", v, c_link_keep);
    }
}
void test_link_end(u8 *g, int now) { link_end_hook(g, now); }
void test_link_set(void (MSABI *f)(u8*, float)) { g_link_set = f; }
float *test_link_keep(void) { return &c_link_keep; }
int *test_link_refill(void) { return &c_link_refill; }

/* 2624e0: an item takes effect. Items that restore Focus (Ether, Mega-Ether, Elixir, Megalixir) restore MP too. */
static void (MSABI *o_item_effect)(u8 *pl);
static void MSABI item_effect_hook(u8 *pl) {
    if (c_ether && pl == player()) {
        int id = *(s16*)(pl + 0x312); u8 *row = *(u8**)(pl + 0x3b0);
        if (id >= 0xbc && id <= 0xc4 && row) {
            int focus = *(s16*)(row + 0xc);
            if (focus > 0) {
                int boost = (FN(u8, 0x221900, u8*, int)(pl, 0x1ce) + 10) * 10;   /* Item Boost, as for the heal */
                mp_restore((float)focus * (float)boost / 100.0f);
            }
        }
    }
    o_item_effect(pl);
}

/* 285780: PlayerData is reset (new game / load) */
static void (MSABI *o_pd_init)(void);
static void MSABI pd_init_hook(void) { o_pd_init(); g_fresh = 1; g_burn = 0; g_charge = 0; }

/* ---------------- MP bar ----------------
   One instance of the Focus gauge's fill sequence (seq 0x12d of gauge_01), with private copies of two of its sprites:
   the mask is emptied and the fill sprite's quads are rewritten every frame.  The quads draw KH2's own MP bar art,
   which tex.c adds to an unused area of the gauge texture: a black frame, the blue gradient, and the "MP" plate at
   the right end; the left end is round, as KH2's (KH2Art's RoundEnd).  As in KH2 the bar is anchored at that plate:
   it empties from the left; during an MP charge the pink bar starts full and empties the same way, as in KH2.  Without the art (texture not recognised) a plain bar is drawn instead. */
#include "mpart_gen.h"
typedef struct { s16 x0, y0, x1, y1; u16 part, attr; } Grp;
typedef struct { s16 u0, v0, u1, v1; u32 col[4]; } Part;
typedef struct { Grp *g; Part *p; } Pair;
#define BAR_Q 4                 /* sprite units per pixel of the art */
static int g_bar;               /* L2D sequence instance, 0 = none */
static int g_bar_fail;

static int bar_alive(void) { l2d_live(&g_bar); return g_bar > 0 && FN(int, 0x1a60e0, int)(g_bar) != 8; }
static void bar_destroy(void) {
    if (g_bar > 0) FN(void, 0x1a57f0, int)(g_bar); g_bar = 0;
}
/* a new instance of the Focus fill sequence with its mask emptied and its fill sprite made private; 0 on failure */
static int bar_instance(int prio) {
    G(u8, 0x8f88028) = 0;       /* created hidden */
    G(u8, 0x8f8802a) = 0;       /* timer/draw group 0, like the rest of the HUD */
    int h = FN(int, 0x1a5350, const char*, u16, int, void*)("gauge_01:0", 0x12d, 0, NULL);
    if (h <= 0) return 0;
    FN(int, 0x1a7600, int, s16, int)(h, (s16)prio, 0);
    FN(int, 0x1a74c0, int, float, int)(h, 0.0f, 0);          /* hold the animation */
    FN(int, 0x1a7be0, int, int)(h, 2);                       /* private copies: mask quad, fill sprite */
    FN(int, 0x1a7be0, int, int)(h, 3);
    Pair *m = NULL;
    int n = FN(int, 0x1a6350, int, int, Pair**)(h, 2, &m);
    for (int i = 0; i < n && m; i++) { m[i].g->x0 = m[i].g->x1 = m[i].g->y0 = m[i].g->y1 = 0; }   /* no mask */
    return h;
}
static void bar_create(void) {
    int h = bar_instance(5);                                 /* same draw priority as the HP gauge */
    if (h <= 0) { if (!g_bar_fail++) LOG("mp bar: could not create (gauge_01 not loaded?)"); g_bar = 0; return; }
    g_bar = h; g_bar_fail = 0;
    if (g_debug) LOG("mp bar: instance %d created", h);
}
/* Scale without the pixel grid.
   The game draws a sequence in one of two ways [1401aaea0 -> CD2Obj::Draw 1401a87b0 -> 140526100]:
     - "unscaled": every quad's corners are moved to whole screen units of the 480 x 272 screen (14052c550:
       x = ceil(x - 0.5), the texture position corrected to match), as the PS2 drew its sprites;
     - "scaled": corners as they are (14052cbc0).
   A sequence counts as scaled when its root object's record has one scaleX and one scaleY key and the first two
   keys of the root's key table are at time 0 with a value other than 1 - which is what the command plates' "0.88"
   roots look like.  The scale set with 1401a7730 is not looked at, so with that alone a bar 7.5 units high with
   0.75 unit borders came out 8 high with borders of 1, and art drawn from the texture (the plate, the round end)
   did not line up with the plain rectangles next to it.
   So the instance's root gets a record of its own: the game's, plus the two scale keys, on a two-key table of its
   own.  Applied every frame; the scale itself then comes from the keys and 1401a7730 is left at 1. */
typedef struct { s32 maxf; s16 spr; u16 key; u8 keyn[11]; u8 kind, blend, flag, sciss, z; } RootAnim;      /* 0x18 bytes, as in the file */
typedef struct { float t, v; u32 interp; } RootKey;
typedef struct { RootAnim rec; RootKey key[2]; } RootScale;
static RootScale g_root_bar, g_root_timer;
static void root_scale(int h, RootScale *r, float se) {
    u8 *sc = c_bar_exact ? FN(u8*, 0x1a5fd0, int)(h) : NULL;        /* the instance's CD2SeqCtrl */
    u8 *o = sc && (s8)sc[0xb2] > 0 && *(u8***)(sc + 0xa8) ? **(u8***)(sc + 0xa8) : NULL;     /* its first object: the root */
    RootAnim *cur = o ? *(RootAnim**)(o + 0x30) : NULL;
    if (cur && cur != &r->rec) {
        int nk = 0;
        for (int i = 0; i < 11; i++) nk += cur->keyn[i];
        if (cur->kind != 0 || nk != 0) cur = NULL;                  /* not the plain root this was written for */
        else {
            r->rec = *cur; r->rec.maxf = 0; r->rec.key = 0; r->rec.keyn[8] = r->rec.keyn[9] = 1;
            r->key[0].t = r->key[1].t = 0; r->key[0].interp = r->key[1].interp = 0;
            r->key[0].v = r->key[1].v = se;
            *(RootKey**)(o + 0x38) = r->key;
            FN(void, 0x1aa7f0, u8*, RootAnim*)(o, &r->rec);
        }
    }
    if (!cur || se == 1.0f) { FN(int, 0x1a7730, int, float)(h, se); return; }     /* as before: on the pixel grid */
    r->key[0].v = r->key[1].v = se;
    FN(int, 0x1a7730, int, float)(h, 1.0f);
}
int own_add(char *out, int n, const char *name, int h) {
    if (h <= 0) return 0;
    size_t l = strlen(out);
    if ((int)l + 24 < n) snprintf(out + l, (size_t)n - l, " %s=%d", name, h);
    return 1;
}
void mod_own_handles(char *out, int n) {
    if (n > 0) out[0] = 0;
    own_add(out, n, "mpbar", g_bar);
    menu_own(out, n); style_own(out, n); status_own(out, n); sccamp_own(out, n);
}
static u32 lerp_col(u32 a, u32 b, float t) {
    u32 r = 0;
    for (int i = 0; i < 4; i++) {
        float x = (float)((a >> (i * 8)) & 0xff), y = (float)((b >> (i * 8)) & 0xff);
        r |= ((u32)(x + (y - x) * t + 0.5f) & 0xff) << (i * 8);
    }
    return r;
}
static void set_quad(Pair *q, int x0, int y0, int x1, int y1, int u0, int v0, int u1, int v1, u32 cl, u32 cr) {
    q->g->x0 = (s16)x0; q->g->x1 = (s16)x1; q->g->y0 = (s16)y0; q->g->y1 = (s16)y1;
    q->p->u0 = (s16)u0; q->p->u1 = (s16)u1; q->p->v0 = (s16)v0; q->p->v1 = (s16)v1;
    q->p->col[0] = cl; q->p->col[1] = cr; q->p->col[2] = cl; q->p->col[3] = cr;
}
static void no_quad(Pair *q) { set_quad(q, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0); }

static void bar_update(u8 *g) {
    if (!c_bar) { if (g_bar) bar_destroy(); return; }
    if (!bar_alive()) { bar_create(); if (!g_bar) return; }
    int h = g_bar;
    Pair *q = NULL;
    int n = FN(int, 0x1a6350, int, int, Pair**)(h, 3, &q);
    if (n < 5 || !q) { FN(int, 0x1a5b30, int, int)(h, 0); return; }

    float len = c_bar_len * (1.0f + c_bar_grow * (g_mpmax - 100.0f) / 100.0f);
    if (len < 8) len = 8; if (len > 160) len = 160;
    float frac = bar_frac();
    float pulse = g_burn ? 0.35f * (0.5f + 0.5f * sinf(g_time * 0.12f)) : 0;   /* the recharge bar pulses */
    float se, right_sx, top_sy;      /* scale; sprite coordinates that go to (Right, Top) */

    if (tex_art_ready()) {
        /* art pixels: frame 20 high, 2 of border, 16 of gradient; plate 52 x 22 with a soft rim of 1 */
        const int Q = BAR_Q;
        float s = c_bar_height / 20.0f;                         /* screen units per art pixel */
        int L = (int)(len / s * Q + 0.5f);                      /* bar, without the plate */
        int in0 = 2 * Q, in1 = L;                               /* inner (gradient) span */
        int F = (int)((float)(in1 - in0) * frac + 0.5f);
        u32 fill = g_burn ? lerp_col(c_col_burn_fill, 0x80ffffff, pulse) : c_col_fill;
        int fu = (g_burn ? MPART_GREY_U : MPART_BLUE_U) + MPART_BLUE_W / 2;
        int eu = MPART_GREY_U + MPART_GREY_W / 2, bu = MPART_BLACK_U + MPART_BLACK_W / 2, bv = MPART_BLACK_V + MPART_BLACK_H / 2;
        u32 empty = g_burn ? c_col_burn_empty : c_col_empty;
        u32 lab = g_burn ? c_col_burn_label : c_col_label;
        Pair *plate;
        if (c_bar_round && n >= 7) {
            /* the left end is round, as KH2's: the frame's first 8 pixels and the inside's first 6 are drawn from the
               round end pieces of the art, the rest from the plain columns as before.  A fill that reaches into the
               round part takes that much of the round piece (its edge there moves by whole art pixels, as texture
               positions are whole). */
            int fc = MPART_FCAP_W * Q, ic = in0 + MPART_BCAP_W * Q;
            int cu = g_burn ? MPART_GCAP_U : MPART_BCAP_U;
            int xf = in1 - F;
            set_quad(&q[0], 0, 1 * Q, fc, 21 * Q, MPART_FCAP_U, MPART_FCAP_V, MPART_FCAP_U + MPART_FCAP_W, MPART_FCAP_V + MPART_FCAP_H, c_col_frame, c_col_frame);
            set_quad(&q[1], fc, 1 * Q, L + 6 * Q, 21 * Q, bu, bv, bu, bv, c_col_frame, c_col_frame);                /* ... reaching under the plate's round end */
            set_quad(&q[2], in0, 3 * Q, ic, 19 * Q, MPART_GCAP_U, MPART_GCAP_V, MPART_GCAP_U + MPART_GCAP_W, MPART_GCAP_V + MPART_GCAP_H, empty, empty);
            set_quad(&q[3], ic, 3 * Q, in1, 19 * Q, eu, MPART_GREY_V, eu, MPART_GREY_V + MPART_GREY_H, empty, empty);
            if (xf < ic) {
                int px = (xf - in0 + Q / 2) / Q;                                                                    /* art pixels of the round part left empty */
                if (px >= MPART_BCAP_W) no_quad(&q[4]);
                else set_quad(&q[4], in0 + px * Q, 3 * Q, ic, 19 * Q, cu + px, MPART_BCAP_V, cu + MPART_BCAP_W, MPART_BCAP_V + MPART_BCAP_H, fill, fill);
                xf = ic;
            } else no_quad(&q[4]);
            set_quad(&q[5], xf, 3 * Q, in1, 19 * Q, fu, MPART_BLUE_V, fu, MPART_BLUE_V + MPART_BLUE_H, fill, fill);
            plate = &q[6];
            for (int i = 7; i < n; i++) no_quad(&q[i]);
        } else {
            set_quad(&q[0], 0, 1 * Q, L + 6 * Q, 21 * Q, bu, bv, bu, bv, c_col_frame, c_col_frame);                 /* frame, reaching under the plate's round end */
            set_quad(&q[1], in0, 3 * Q, in1, 19 * Q, eu, MPART_GREY_V, eu, MPART_GREY_V + MPART_GREY_H, empty, empty);   /* empty part */
            set_quad(&q[2], in1 - F, 3 * Q, in1, 19 * Q, fu, MPART_BLUE_V, fu, MPART_BLUE_V + MPART_BLUE_H, fill, fill); /* what is left / recharged */
            plate = &q[3];
            for (int i = 4; i < n; i++) no_quad(&q[i]);
        }
        set_quad(plate, L, 0, L + MPART_PILL_W * Q, MPART_PILL_H * Q, MPART_PILL_U, MPART_PILL_V,
                 MPART_PILL_U + MPART_PILL_W, MPART_PILL_V + MPART_PILL_H, lab, lab);                               /* "MP" plate */
        se = s / Q; right_sx = (float)(L + (MPART_PILL_W - 1) * Q); top_sy = (float)Q;
    } else {
        /* plain bar: the cross-section of the Focus bar art (u 138..140, v 70..112; its lower third is solid), tinted */
        const int K = 4;
        float so = c_bar_height / 6.8f * 0.9f;
        int L = (int)(len * K / so + 0.5f), cap = K, F = (int)((float)L * frac + 0.5f);
        u32 cl = g_burn ? lerp_col(0x80d880ff, 0x80ffffff, pulse) : 0x80ffb030, cr = g_burn ? lerp_col(0x80b030ff, 0x80ffffff, pulse) : 0x80ff6000;
        u32 bg = g_burn ? 0x80300828 : 0x80401008;
        no_quad(&q[0]);
        set_quad(&q[1], 0, 0, cap, 21 * K, 138, 70, 140, 112, bg, bg);
        set_quad(&q[2], cap, 0, cap + L, 21 * K, 140, 70, 140, 112, bg, bg);
        set_quad(&q[3], cap + L + cap, 0, cap + L, 21 * K, 138, 70, 140, 112, bg, bg);
        set_quad(&q[4], cap + L - F, 0, cap + L, 21 * K, 140, 70, 140, 112, lerp_col(cr, cl, frac), cr);
        for (int i = 5; i < n; i++) no_quad(&q[i]);
        se = so / K; right_sx = (float)(L + 2 * cap); top_sy = 14.0f * K;
    }
    root_scale(h, &g_root_bar, se);
    /* the sprite sits at (-77, +1) from the instance origin, in sprite units */
    FN(int, 0x1a7660, int, float, float)(h, c_bar_right - (right_sx - 77.0f) * se, c_bar_top - (top_sy + 1.0f) * se);
    int vis = FN(int, 0x1a6060, int)(*(int*)(g + 0x8c)) != 0;                         /* follow the HP gauge */
    FN(int, 0x1a5b30, int, int)(h, vis);
}

/* A small plain bar for other parts of the mod (the Command Style prompt's timer), made the same way: black frame,
   dark inside, tinted fill from the left.  *ph holds its instance (0 = none yet); frac < 0 removes it.
   left / top / w / hgt in screen units; the fill colour is a tint (AABBGGRR, 80 = as is, ff = doubled). */
void hud_timer_bar(int *ph, float left, float top, float w, float hgt, float frac, u32 fill, int prio, int show) {
    l2d_live(ph);
    int alive = *ph > 0 && FN(int, 0x1a60e0, int)(*ph) != 8;
    if (frac < 0) { if (alive) FN(void, 0x1a57f0, int)(*ph); *ph = 0; return; }
    if (!alive) { *ph = bar_instance(prio); if (*ph <= 0) { *ph = 0; return; } }
    int h = *ph;
    Pair *q = NULL;
    int n = FN(int, 0x1a6350, int, int, Pair**)(h, 3, &q);
    if (n < 3 || !q) { FN(int, 0x1a5b30, int, int)(h, 0); return; }
    if (frac > 1) frac = 1;
    const int K = 8;                                            /* sprite units per screen unit */
    int W = (int)(w * K + 0.5f), H = (int)(hgt * K + 0.5f), b = K / 2;      /* frame 0.5 thick */
    int F = (int)((float)(W - 2 * b) * frac + 0.5f);
    int art = tex_art_ready();
    /* with the KH2 art: its black and its grey gradient; without: one solid texel of the Focus bar art, tinted */
    int bu = art ? MPART_BLACK_U + MPART_BLACK_W / 2 : 140, bv = art ? MPART_BLACK_V + MPART_BLACK_H / 2 : 105;
    int gu = art ? MPART_GREY_U + MPART_GREY_W / 2 : 140, gv0 = art ? MPART_GREY_V : 105, gv1 = art ? MPART_GREY_V + MPART_GREY_H : 105;
    set_quad(&q[0], 0, 0, W, H, bu, bv, bu, bv, art ? 0x80808080 : 0x80000000, art ? 0x80808080 : 0x80000000);
    set_quad(&q[1], b, b, W - b, H - b, gu, gv0, gu, gv1, 0x80202020, 0x80202020);
    set_quad(&q[2], b, b, b + F, H - b, gu, gv0, gu, gv1, fill, fill);
    for (int i = 3; i < n; i++) no_quad(&q[i]);
    float se = 1.0f / K;
    root_scale(h, &g_root_timer, se);
    FN(int, 0x1a7660, int, float, float)(h, left + 77.0f * se, top - 1.0f * se);   /* the sprite sits at (-77, +1) from the origin */
    FN(int, 0x1a5b30, int, int)(h, show);
}

/* The context prompt (cmd+0x60 bit 0x40000, plate at cmd+0x298) is the save point's: command 0x12e "Save". */
static int at_save_point(u8 *cmd) {
    if (!cmd || !(*(u32*)(cmd + 0x60) & 0x40000)) return 0;
    u8 *P = *(u8**)(cmd + 0x298);
    u16 *k = P ? *(u16**)(P + 0x58) : NULL;
    return k && k[0] == 0x12e;
}
/* ---------------- MP Haste ----------------
   KH2: the MP charge takes 50 s / (1 + bonus), MP Haste being 0.25 of bonus.  Here it is 25 s / (1 + bonus) and the
   game's own Magic Haste (ability 0x1d0, which can be installed several times; 140221900 gives the number in
   effect) is that ability: 0.10 a copy.  Attack Haste (0x1cf), which has nothing of its own left to shorten
   either, is KH2's MP Rage (see rage()).

   Its texts.  A message file (CRsrcCTD) is: +0xe u16 number of messages, +0x10 offset of the message records
   (u32 id, u32 text offset, u32 layout), texts as plain bytes.  Once a file is in memory the game calls slot 1 of
   the object's vtable (140112ed0: +0x90 file, +0x98 records, +0xb0 first id), which for the command names (file
   0xfa0000) also fills the name pointers of the command table (140814908 + id * 0x18) - the only way a name is
   read.  An ability's description is message 0x32003d + id of file 0x320000 [14041d880].  That slot is hooked and
   the texts are rewritten in the file as loaded, so every reader gets them: the name there if it fits, else
   through the name pointer; the description cut to the room the game's has (125 / 126 bytes in English).  Only
   the English texts are replaced, unless the ini gives texts of its own.  An ability whose bonus is set to 0 keeps
   the game's texts.

   Berserker.  The game's Reload Boost (ability 0x1d9: all reloads faster under a quarter of HP) has nothing left
   to do either.  It is this mod's Berserker, after KH2's Berserk Charge, and does one thing: while the MP charge
   runs, what the player deals is BerserkerDamage percent higher.  Damage is worked out in one place, 1401f9180
   (attack record, hit record), called once [1f985a] when an attack registers on a target:
       crit [1f90e0] x clamp((attack+0x82 stat - hit+0xac defence) x attack+0x84 power / 100, hit+0xb0, hit+0xae)
       x hit's resistance to the attack's element / 100 x hit+0xc4 x attack+0x88
   (attack+0x7e & 0x7f: kind; 0x22 = stat + power, a cure [2d24b0 negates it], 0x2a = a percentage).  The result
   is a whole number (fractions dropped, at least 1); the bonus is added to it, rounded up.  Whose
   attack: attack+0x94 is the owner's entity id (it becomes hit+0x8c, which 1402d24b0 looks up with 1401d45c0
   and tests the same way: the entity or its parent, +0x10, of type +0x28 == 1, the player's). */
#define VT_CTD_READY 0x637910u          /* CRsrcCTD vtable slot 1 */
#define FN_CTD_READY 0x112ed0u
#define AB_ATTACK_HASTE 0x1cf
#define AB_MAGIC_HASTE  0x1d0
#define AB_RELOAD_BOOST 0x1d9
#define DMG_CALL 0x1f985au
#define DMG_FN   0x1f9180u
#define ENTITY_BY_ID 0x1d45c0u
/* percent this attack's damage is raised by; 0 = not at all */
static double berserk_pct(u8 *atk) {
    if (!(c_berserk_pct > 0) || !g_burn || !atk) return 0;
    u8 *pl = player(); if (!pl) return 0;
    int n = FN(u8, HAS_ABILITY, u8*, u16)(pl, AB_RELOAD_BOOST); if (!n) return 0;
    u32 kind = *(u16*)(atk + 0x7e) & 0x7f;
    if (kind == 0x22 || kind == 0x2a || *(s16*)(atk + 0x84) < 1) return 0;         /* cures, percentages, no damage */
    u8 *e = FN(u8*, ENTITY_BY_ID, u32)(*(u32*)(atk + 0x94)); if (!e) return 0;
    u8 *par = *(u8**)(e + 0x10);
    if (!(e == pl || *(int*)(e + 0x28) == 1 || (par && (par == pl || *(int*)(par + 0x28) == 1)))) return 0;
    return (double)c_berserk_pct * n;
}
/* The game works the damage out once (the critical hit is a dice roll in there) and drops the fraction.  The bonus
   is taken of that whole number and rounded UP, so it is never lost: 2 -> 3, 19 -> 20, 20 -> 21, 21 -> 23 at 5 %. */
static u32 MSABI damage_hook(u8 *atk, u8 *hit) {
    double pct = berserk_pct(atk);
    u32 r = FN(u32, DMG_FN, u8*, u8*)(atk, hit);
    if (!(pct > 0) || r == 0 || r >= 0x7fff) return r;
    double add = ceil((double)r * pct / 100.0 - 1e-6);
    if (add < 1) add = 1;
    r += (u32)add;
    return r > 0x7fff ? 0x7fff : r;         /* kept as a signed 16-bit number by the caller */
}
#define MSG_NAMES 0xfa0000u
#define MSG_ABILITY_HELP 0x32003du
static float charge_speed(u8 *pl) {
    float s = 1.0f;
    if (pl) s += c_haste_bonus * (float)FN(u8, HAS_ABILITY, u8*, u16)(pl, AB_MAGIC_HASTE);
    return s < 0.05f ? 0.05f : s;
}
static char *ctd_text(u8 *self, u32 id) {
    u8 *file = *(u8**)(self + 0x90); u32 *rec = *(u32**)(self + 0x98);
    if (!file || !rec) return NULL;
    for (int i = 0, n = *(u16*)(file + 0xe); i < n; i++, rec += 3) if (rec[0] == id) return (char*)file + rec[1];
    return NULL;
}
/* the loaded file is the game's heap memory; should it ever not be writable, leave it alone */
static int can_write(const char *p, size_t n) {
#ifdef _WIN32
    MEMORY_BASIC_INFORMATION mi;
    if (!VirtualQuery(p, &mi, sizeof mi) || mi.State != MEM_COMMIT) return 0;
    if (!(mi.Protect & (PAGE_READWRITE | PAGE_EXECUTE_READWRITE)) || (mi.Protect & PAGE_GUARD)) return 0;
    return (const u8*)p + n <= (const u8*)mi.BaseAddress + mi.RegionSize;
#else
    (void)p; (void)n; return 1;
#endif
}
static void haste_texts(u8 *self) {
    /* the game's English texts, and what they become */
    const struct { u32 id; const char *name, *help; int on, name_set, help_set; const char *new_name, *new_help; } ab[3] = {
        { AB_MAGIC_HASTE,  "Magic Haste",  "Shortens the reload time for all magic commands",
          c_haste_rename && c_haste_bonus > 0, c_haste_name_set, c_haste_help_set, c_haste_name, c_haste_help },
        { AB_ATTACK_HASTE, "Attack Haste", "Shortens the reload time for all attack commands",
          c_rage_rename && c_rage > 0, c_rage_name_set, c_rage_help_set, c_rage_name, c_rage_help },
        { AB_RELOAD_BOOST, "Reload Boost", "Shortens the reload time for all commands installed",
          c_berserk_rename && c_berserk_pct > 0, c_berserk_name_set, c_berserk_help_set, c_berserk_name, c_berserk_help } };
    u32 first = *(u32*)(self + 0xb0);
    if (first != MSG_NAMES && first != DESC_MSG) return;
    for (int i = 0; i < 3; i++) {
        if (!ab[i].on) continue;
        if (first == MSG_NAMES) {
            char *t = ctd_text(self, MSG_NAMES + ab[i].id);
            if (!t || !(ab[i].name_set || !strcmp(t, ab[i].name))) continue;
            if (strlen(ab[i].new_name) <= strlen(t) && can_write(t, strlen(t) + 1)) strcpy(t, ab[i].new_name);
            else G(const char*, 0x814908 + ab[i].id * 0x18) = ab[i].new_name;
            if (g_debug) LOG("mp: %s is named \"%s\"", ab[i].name, ab[i].new_name);
        } else {
            char *t = ctd_text(self, MSG_ABILITY_HELP + ab[i].id);
            if (!t || !(ab[i].help_set || !strncmp(t, ab[i].help, strlen(ab[i].help)))) continue;
            if (!can_write(t, strlen(t) + 1)) { LOG("mp: the description of %s cannot be written", ab[i].name); continue; }
            size_t room = strlen(t), n = strlen(ab[i].new_help);
            if (n > room) { n = room; LOG("mp: the description of %s is cut to %u bytes", ab[i].name, (unsigned)room); }
            memcpy(t, ab[i].new_help, n); t[n] = 0;
        }
    }
}
static u64 (MSABI *o_ctd_ready)(u8 *self, u64 a, u64 b, u64 c);
static u64 MSABI ctd_ready_hook(u8 *self, u64 a, u64 b, u64 c) {
    u64 r = o_ctd_ready(self, a, b, c);
    haste_texts(self);
    combomaster_texts(self);
    return r;
}
/* MP Rage (Attack Haste).  The player's HP: s16 at +0x4a0, the maximum at +0x4a2 (vtable slots 0x78 / 0x80,
   140219e80 / 140219e90, the getters behind Lua's Player.GetPlayerHP / GetPlayerHPMax).  HP lost since the last
   frame gives lost / max HP x max MP x MPRage% x copies / the most copies (140811083 + id * 0x1e: 5), never during
   the MP charge.  Kept with its fraction (the bar is a float), so small hits add up. */
#define AB_MAX_COPIES(id) G(u8, 0x811083 + (u32)(id) * 0x1e)
#define PL_HP    0x4a0
#define PL_HPMAX 0x4a2
static u8 *g_rage_pl; static int g_rage_hp = -1;
static void rage(u8 *pl) {
    if (!pl) { g_rage_pl = NULL; return; }
    int hp = *(s16*)(pl + PL_HP), max = *(s16*)(pl + PL_HPMAX);
    if (pl == g_rage_pl && g_rage_hp > hp && max > 0 && !g_burn && c_rage > 0 && g_mp < g_mpmax) {
        int n = FN(u8, HAS_ABILITY, u8*, u16)(pl, AB_ATTACK_HASTE), most = AB_MAX_COPIES(AB_ATTACK_HASTE);
        if (most < 1) most = 5;
        if (n > most) n = most;
        float gain = (float)(g_rage_hp - hp) / (float)max * g_mpmax * c_rage * 0.01f * (float)n / (float)most;
        if (gain > 0) {
            g_mp += gain; if (g_mp > g_mpmax) g_mp = g_mpmax;
            if (g_debug) LOG("mp: MP Rage +%.2f (HP %d -> %d of %d, %d of %d copies)", gain, g_rage_hp, hp, max, n, most);
        }
    }
    g_rage_pl = pl; g_rage_hp = hp;
}
/* ---------------- per frame (the player gauge's update, 209f20) ---------------- */
static void tick(u8 *g) {
    float dt = *(float*)(g + 0x20);
    if (!(dt >= 0) || dt > 6) dt = 1;
    g_time += dt;
    g_mpmax = max_mp();
    if (g_fresh) { g_fresh = 0; g_mp = g_mpmax; g_burn = 0; g_charge = 0; }
    if (g_mp > g_mpmax) g_mp = g_mpmax;
    u8 *cmd = CMD, *pl = player();
    rage(pl);
    if (g_burn) {
        g_charge += dt * 100.0f / (c_charge_seconds * 60.0f) * charge_speed(pl);
        if (g_charge >= 100.0f) burn_end();
    }
    /* on a save point (its "Save" prompt is up): MP comes back fast, and a recharge finishes fast */
    if (c_save_seconds > 0 && at_save_point(cmd)) {
        float pct = dt * 100.0f / (c_save_seconds * 60.0f);
        if (g_burn) { g_charge += pct; if (g_charge >= 100.0f) burn_end(); }
        else if (g_mp < g_mpmax) { g_mp += g_mpmax * pct * 0.01f; if (g_mp > g_mpmax) g_mp = g_mpmax; }
    }
    if (cmd) {
        if (!c_cursor_advance) *(u32*)(cmd + 0x60) |= 2;     /* stay on the command that was used */
        if (g_burn) plates_block(cmd);
        if (focusx_on()) fx_block(cmd);
    }
}
/* Link Charge: an active D-Link drains twice as fast.  The gauge's update (209f20) drains an active link (flag 0x200,
   not 0x1000 pinned full, 0x8800 disabled / illusion, 0x400 "skip this frame") by adding to the pending change
   +0x64 per frame dt x -0.2 once the link is 7200 ticks old (+0xac), before that the larger of dt x -0.01 and
   dt x -0.0005 x value (the constants at 6468a8..6468b4), then value += pending.  The same drain is added to the
   pending change here, just before that update, so the link loses twice as much each frame. */
static float link_drain(u8 *g) {
    u32 f = *(u32*)(g + 0x84);
    if (!(f & 0x200) || (f & (0x1000 | 0x8800 | 0x400))) return 0;
    float dt = *(float*)(g + 0x20), d = dt * G(float, 0x6468b4);
    float t = *(float*)(g + 0xac), lim = G(float, 0x6468a8);
    if (t < lim) { float a = dt * G(float, 0x6468ac) * *(float*)(g + 0x60), b = dt * G(float, 0x6468b0); d = a <= b ? a : b; }
    return d;
}
float test_link_drain(u8 *g) { return link_drain(g); }
static void (MSABI *o_gauge_update)(u8 *g);
static void MSABI gauge_update_hook(u8 *g) {
    tick(g);
    if (linkcharge_on()) *(float*)(g + 0x64) += link_drain(g);
    o_gauge_update(g);
    bar_update(g);
    menu_frame(g);
    dbg_frame();
}
static void *(MSABI *o_gauge_dtor)(u8 *g, u32 flags);
static void *MSABI gauge_dtor_hook(u8 *g, u32 flags) {
    bar_destroy();
    menu_shutdown();            /* nothing of the mod's HUD may outlive the gauge: its files can be unloaded next */
    return o_gauge_dtor(g, flags);
}

/* ---------------- install ---------------- */
static int site_ok(const Steal *s) { return memcmp(g_base + s->rva, s->bytes, s->len) == 0; }
static int call_ok(u32 rva, u32 target) {
    u8 *p = g_base + rva; s32 d; memcpy(&d, p + 1, 4);
    return p[0] == 0xE8 && (u32)(rva + 5 + d) == target;
}
int mod_install(void) {
    load_ini();
    /* check every site before changing anything, so that an unknown game build is left untouched */
    const Steal *all[] = { &S_gauge_update, &S_gauge_dtor, &S_dlink_open, &S_dlink_pick, &S_item_effect, &S_pd_init };
    int bad = 0;
    for (unsigned i = 0; i < sizeof all / sizeof *all; i++) if (!site_ok(all[i])) { LOG("site %x does not match", all[i]->rva); bad++; }
    if (!call_ok(0x233d40, 0x2063c0)) { LOG("call site 233d40 does not match"); bad++; }
    if (!call_ok(0x206a6e, 0x1ce550)) { LOG("call site 206a6e does not match"); bad++; }
    if ((c_desc_cost || c_ether) && !call_ok(DESC_CALL, MSG_FIND)) { LOG("description site does not match"); bad++; }
    if (c_floor && !call_ok(FLOOR_CALL, HAS_ABILITY)) { LOG("damage floor site does not match"); bad++; }
    if (c_boss_hp) {
        static const u32 l[] = { EPD_LOAD_A, EPD_LOAD_B, EPD_LOAD_C, EPD_LOAD_D, EPD_LOAD_E, EPD_LOAD_F };
        for (unsigned i = 0; i < 6; i++) if (!call_ok(l[i], EPD_LOAD)) { LOG("boss HP site %x does not match", l[i]); bad++; }
        if (!call_ok(EPD_RESET_A, EPD_RESET)) { LOG("boss HP site %x does not match", EPD_RESET_A); bad++; }
        if (!call_ok(FLOOR_FN_CALL, FLOOR_FN)) { LOG("boss HP floor site does not match"); bad++; }
    }
    if (G(u64, VT_CTD_READY) != (u64)(g_base + FN_CTD_READY)) { LOG("message file vtable does not match"); bad++; }
    if (c_berserk_pct > 0 && !call_ok(DMG_CALL, DMG_FN)) { LOG("damage site does not match"); bad++; }
    if (c_link_keep < 100.0f && (!call_ok(LINK_END_A, LINK_END) || !call_ok(LINK_END_B, LINK_END))) { LOG("D-Link end sites do not match"); bad++; }
    if (!bundle_check()) bad++;
    if (!menu_check()) bad++;
    if (!tex_check()) bad++;
    if (!style_check()) bad++;
    if (!speed_check()) bad++;
    if (!status_check()) bad++;
    if (!shortcut_check()) bad++;
    if (!sccamp_check()) bad++;
    if (!guard_check()) bad++;
    if (!combomaster_check()) bad++;
    if (!worldmap_check()) bad++;
    if (!sporb_check()) bad++;
    if (bad) { LOG("this is not the game build the mod was written for: nothing changed"); g_patch_errors += bad; return 0; }
    if (c_desc_cost || c_ether) hook_call(DESC_CALL, MSG_FIND, desc_hook, "descriptions (MP cost, MP items)");
    if (c_floor) {
        hook_call(FLOOR_CALL, HAS_ABILITY, floor_ability_hook, "damage floor");
        LOG("combat: EXP Zero's minimum damage applies without the ability %s", c_floor >= 2 ? "on every difficulty" : "on Critical");
    }
    if (c_berserk_pct > 0) hook_call(DMG_CALL, DMG_FN, damage_hook, "damage (Berserker)");
    if (c_boss_hp) {
        static const u32 l[] = { EPD_LOAD_A, EPD_LOAD_B, EPD_LOAD_C, EPD_LOAD_D, EPD_LOAD_E, EPD_LOAD_F };
        for (unsigned i = 0; i < 6; i++) hook_call(l[i], EPD_LOAD, epd_load_hook, "boss HP (load)");
        hook_call(EPD_RESET_A, EPD_RESET, epd_reset_hook, "boss HP (reset)");
        hook_call(FLOOR_FN_CALL, FLOOR_FN, floor_hp_hook, "boss HP (damage floor)");
        LOG("combat: boss HP for %d bosses", g_boss_hp_n);
    }
    g_link_set = (void (MSABI *)(u8*, float))(g_base + 0x20ac70);
    if (c_link_keep < 100.0f) {
        hook_call(LINK_END_A, LINK_END, link_end_hook, "D-Link end (revert)");
        hook_call(LINK_END_B, LINK_END, link_end_hook, "D-Link end (finisher)");
    }
    {   /* always: MP Haste / Berserker texts and the Combo Master name come through here */
        u64 old = (u64)(g_base + FN_CTD_READY), f = (u64)ctd_ready_hook;
        o_ctd_ready = (void*)old;
        patch_bytes(VT_CTD_READY, (u8*)&old, (u8*)&f, 8, "message file ready");
    }
    bundle_apply();
    menu_apply();
    tex_apply();
    style_apply();
    speed_apply();
    status_apply();
    shortcut_apply();
    sccamp_apply();
    guard_apply();
    combomaster_apply();
    worldmap_apply();
    sporb_apply();

    o_gauge_update = hook_fn(&S_gauge_update, gauge_update_hook, "gauge_update");
    o_gauge_dtor   = hook_fn(&S_gauge_dtor, gauge_dtor_hook, "gauge_dtor");
    o_dlink_open   = hook_fn(&S_dlink_open, dlink_open_hook, "dlink_open");
    o_dlink_pick   = hook_fn(&S_dlink_pick, dlink_pick_hook, "dlink_pick");
    o_item_effect  = hook_fn(&S_item_effect, item_effect_hook, "item_effect");
    o_pd_init      = hook_fn(&S_pd_init, pd_init_hook, "pd_init");
    hook_call(0x233d40, 0x2063c0, use_hook, "deck_use");
    hook_call(0x206a6e, 0x1ce550, reload_hook, "reload");
    return g_patch_errors == 0;
}

/* ---------------- debug commands ---------------- */
void dbg_custom(const char *cmd, char *args) {
    if (!strcmp(cmd, "mp")) {
        char sub[16] = {0}; float v = 0; sscanf(args, "%15s %f", sub, &v);
        if (!strcmp(sub, "set")) { g_mp = v; if (g_mp < 0.5f) burn_start(); else g_burn = 0; }
        else if (!strcmp(sub, "burn")) burn_start();
        else if (!strcmp(sub, "full")) { g_burn = 0; g_mp = g_mpmax; }
        LOG("  MP %.1f / %.1f  burn %d charge %.1f  bar handle %d alive %d", g_mp, g_mpmax, g_burn, g_charge, g_bar, bar_alive());
    } else if (!strcmp(cmd, "bar")) {
        sscanf(args, "%f %f %f %f %f", &c_bar_right, &c_bar_top, &c_bar_height, &c_bar_len, &c_bar_grow);
        LOG("  bar right %.1f top %.1f height %.2f length %.1f growth %.2f (handle %d, art %d)", c_bar_right, c_bar_top, c_bar_height, c_bar_len, c_bar_grow, g_bar, tex_art_ready());
    } else if (!strcmp(cmd, "barcol")) {
        sscanf(args, "%x %x %x %x %x %x %x", &c_col_fill, &c_col_label, &c_col_empty, &c_col_frame, &c_col_burn_fill, &c_col_burn_label, &c_col_burn_empty);
        LOG("  fill %08x label %08x empty %08x frame %08x  burn: fill %08x label %08x empty %08x", c_col_fill, c_col_label, c_col_empty, c_col_frame, c_col_burn_fill, c_col_burn_label, c_col_burn_empty);
    } else if (!strcmp(cmd, "ini")) {
        load_ini(); LOG("  settings reloaded");
    } else if (!strcmp(cmd, "plates")) {
        u8 *c = CMD; if (!c) { LOG("  no command object"); return; }
        LOG("  cmd %p flags %08x %08x count %d selected %d", c, *(u32*)(c + 0x60), *(u32*)(c + 0x64), *(u16*)(c + 0x220), *(u16*)(c + 0x224));
        for (int i = 0; i < plate_count(c); i++) {
            u8 *P = *(u8**)(c + 0x1e0 + i * 8); if (!P) continue;
            u16 *k = *(u16**)(P + 0x58);
            LOG("  plate %d %p type %d state %d flags %08x pct %.1f pos %d cmd %x (cost %.0f) uses %d l2d %d", i, P, P[0x30], P[0x31],
                *(u32*)(P + 0x60), *(float*)(P + 0x64), (s8)P[0x6c], k ? k[0] : 0, k ? mp_cost(k[0]) : 0, k ? ((u8*)k)[2] : 0, *(int*)(P + 0x4c));
        }
    } else if (!strcmp(cmd, "hud")) {
        u8 *g = GAUGE;
        LOG("  gauge %p state %d handle %d visible %d  G %08x  bar %d", g, g ? *(int*)(g + 0x88) : -1, g ? *(int*)(g + 0x8c) : 0,
            g ? FN(int, 0x1a6060, int)(*(int*)(g + 0x8c)) : 0, G(u32, 0x10f9ee48), g_bar);
        if (bar_alive()) {
            Pair *q = NULL; int n = FN(int, 0x1a6350, int, int, Pair**)(g_bar, 3, &q);
            for (int i = 0; i < n && q; i++)
                LOG("   quad %d xy (%d,%d)-(%d,%d) uv (%d,%d)-(%d,%d) col %08x %08x %08x %08x", i, q[i].g->x0, q[i].g->y0, q[i].g->x1, q[i].g->y1,
                    q[i].p->u0, q[i].p->v0, q[i].p->u1, q[i].p->v1, q[i].p->col[0], q[i].p->col[1], q[i].p->col[2], q[i].p->col[3]);
        }
    } else if (!strcmp(cmd, "menu")) {
        menu_dbg(cmd, args);
    } else LOG("  unknown command");
}

#ifndef _WIN32      /* offline test access */
float *test_mp(void) { return &g_mp; }
float *test_mpmax(void) { return &g_mpmax; }
int *test_fresh(void) { return &g_fresh; }
int *test_burn(void) { return &g_burn; }
float *test_charge(void) { return &g_charge; }
int *test_bar(void) { return &g_bar; }
void test_tick(u8 *g) { tick(g); }
float *test_charge_seconds(void) { return &c_charge_seconds; }
float *test_haste_bonus(void) { return &c_haste_bonus; }
const char *test_haste_help(int atk) { return atk ? c_rage_help : c_haste_help; }
float *test_rage(void) { return &c_rage; }
const char *test_berserk_help(void) { return c_berserk_help; }
float *test_berserk_pct(void) { return &c_berserk_pct; }
u32 test_damage(u8 *atk, u8 *hit) { return damage_hook(atk, hit); }
void test_gauge_update(u8 *g) { gauge_update_hook(g); }
u8 *test_use(u8 *P) { return use_hook(P); }
#endif
#ifndef _WIN32
void test_bar_update(u8 *g) { bar_update(g); }
int *test_bar_round(void) { return &c_bar_round; }
int *test_bar_exact(void) { return &c_bar_exact; }
void test_bar_geom(float *io, int set) {      /* right, top, height, length */
    if (set) { c_bar_right = io[0]; c_bar_top = io[1]; c_bar_height = io[2]; c_bar_len = io[3]; }
    else { io[0] = c_bar_right; io[1] = c_bar_top; io[2] = c_bar_height; io[3] = c_bar_len; }
}
#endif
