/* "Armor": a choice of outfit for the player, set in the menu (Items, under Stock), used wherever the game itself
   would show the character in normal clothes.

   The player's model.  One number, 1..15 = character (1 Ventus, 2 Aqua, 3 Terra) + 3 x outfit 0..4 (the files
   p0x..p4x): 0 normal clothes, 1 armor with helmet (also the Mirage Arena look), 2 and 3 Rumble Racing, 4 armor
   without helmet (it moves with the normal clothes' motions - the table at 818e58 points p4x at p0x's).  The game
   keeps it at 150f9ee4c (getter 26b7d0; the only writes are the setter 26c720 and 26ad90(model != 0)) and in the
   save at 150fa0887.  The story sets it: on entering a room 1ed3f2 asks the room's event data for an outfit and
   1ed44d hands it to 1ebc00 (which sets both, and does nothing when the model is already that one); loading a save
   (1ec760, 1ed100), a new game and the character switches call 26c720 with the save's value or the character.
   The room load builds the player, and loads its files, from 150f9ee4c.

   Here the save keeps what the GAME wants (the mod never writes 150fa0887) and only 150f9ee4c gets the choice:
     - every call of the setter 26c720 is hooked: a model in normal clothes (outfit 0) becomes the chosen outfit,
       any other model (story armor, Rumble Racing) is passed on as it is.  Not in the Mirage Arena (game mode 0xf).
     - the two calls of 1ebc00 first put the game's own model back into 150f9ee4c, so that its "already that one"
       test compares what the game wants with what it wanted before - not with the choice.
     - choosing in the menu sets 150f9ee4c at once; the player is rebuilt with it at the next room load.
   With the choice "No Armor" (or the mod off) nothing differs from the game.  The choice is kept in the save, in
   bits 24-25 of EXP Zero's u32 (save + 0x18cc + 5*4), next to Combo Master's bit 23: no user of those u32s reads
   bits 21-31, the save copies the whole u32, a new game writes 0x3e00 (= No Armor).

   The menu entry is a third plate under the Items screen's two (CCampItemTop, vtable 140675f90, update 14040c480,
   state +0x9b: 2 = browsing; its list CCampItemCmd at +0x2b0, vtable 140676060, input slot 8 14040d170: layout
   0x18a of camp.l2d, entries "Deck Items" / "Stock" at -230,-76 / -59 under node 0xb (ids 1, 2), cursor +0x8e,
   hand +0xb8, light frame +0xc0, positions +0xa8, help messages 0x34370200 + index).  Done as sccamp.c does the
   Shortcuts entry: past either end of the list the cursor lands on the new plate; there the screen's own
   buttons are held (+0x11) and confirm steps through the outfits. */
#include "mod.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern char g_ini[MAX_PATH + 32];
extern int g_debug;

#define CAMP            G(u8*, 0x10fb51f0)
#define CUR_MODEL       G(u32, 0x10f9ee4c)
#define SAVE_MODEL      G(u8, 0x10fa0887)
#define SAVE_U32        G(u32, 0x10fa3d08 + 0x18cc + 5 * 4)
#define CHOICE_SHIFT    24
#define CHOICE_MASK     (3u << CHOICE_SHIFT)
#define FN_SET          0x26c720u
#define FN_CHANGE       0x1ebc00u
#define FN_MODE         0x1ec250u           /* the game mode record; byte 0 = 0xf in the Mirage Arena */
static const u32 SET_CALLS[] = { 0x1da5f3, 0x1db229, 0x1db2b3, 0x1db465, 0x1db524, 0x1db605, 0x1db81a, 0x1ebc3e, 0x1ec760, 0x1ed100 };
static const u32 CHANGE_CALLS[] = { 0x1ec880, 0x1ed44d };

#define VT_TOP_UPDATE   (0x675f90 + 0x08)
#define FN_TOP_UPDATE   0x40c480
#define VT_LIST_INPUT   (0x676060 + 0x40)
#define FN_LIST_INPUT   0x40d170
#define SEQ_PLATE       0x1fb               /* "menu_plate_item", the Stock entry's plate */
#define N_ROOT          0xb
#define N_LAST          1                   /* the game's last entry (Stock) */
#define ITEM_X          (-230.0f)
#define ITEM_Y          (-42.0f)            /* the game's two are at -76 and -59 */

#define L2D_Alive(h)            ((h) > 0 && FN(int, 0x1a60e0, int)(h) != 8)
#define L2D_Show(h, on)         FN(int, 0x1a5b30, int, int)(h, on)
#define L2D_IsVisible(h)        FN(int, 0x1a6060, int)(h)
#define L2D_GetControl(h)       FN(int, 0x1a60e0, int)(h)
#define L2D_SetControl(h, c)    FN(int, 0x1a7520, int, int)(h, c)
#define L2D_SetPos(h, x, y)     FN(int, 0x1a7660, int, float, float)(h, x, y)
#define L2D_GetNodeControl(h, n) FN(int, 0x1a6790, int, u16)(h, n)
#define L2D_SetNodeControl(h, n, c) FN(int, 0x1a7db0, int, u16, int)(h, n, c)
#define SE(id)                  FN(u64, 0x1b2e40, int, float, u64, u32, u32)(id, G(float, 0x6420b8), 0, 4, 0)
#define HELP_TEXT(s)            FN(void, 0x417770, u8*, const char*, void*)(CAMP, s, NULL)
#define HELP_MSG(id)            FN(void, 0x417710, u8*, int, void*)(CAMP, id, NULL)

static int  c_on = 1;
static char c_title[32] = "Armor";
static char c_name[3][32] = { "No Armor", "Armor", "Armor (No Helmet)" };
static const int k_outfit[3] = { 0, 1, 4 };          /* choice -> outfit */

/* ---------------- the outfit ---------------- */
static int choice(void) { int c = (int)((SAVE_U32 & CHOICE_MASK) >> CHOICE_SHIFT); return c > 2 ? 0 : c; }
static int in_arena(void) { u8 *m = FN(u8*, FN_MODE, void)(); return m && m[0] == 0x0f; }
/* the model to show for the model the game wants */
static int shown(int m) {
    if (!c_on || m < 1 || m > 3 || in_arena()) return m;             /* only normal clothes (1..3) are replaced */
    return m + 3 * k_outfit[choice()];
}
static void MSABI set_hook(int m) {
    int s = shown(m);
    if (g_debug && s != m) LOG("armor: model %d -> %d (%s)", m, s, c_name[choice()]);
    FN(void, FN_SET, int)(s);
}
static void MSABI change_hook(int m) {
    u8 want = SAVE_MODEL;
    if (want >= 1 && want <= 15) CUR_MODEL = want;                   /* the game's own model, for its "already" test */
    FN(void, FN_CHANGE, int)(m);
    if ((int)CUR_MODEL == m) FN(void, FN_SET, int)(shown(m));       /* unchanged (already that one): our choice again */
}
static void choice_set(int c) {
    SAVE_U32 = (SAVE_U32 & ~CHOICE_MASK) | ((u32)c << CHOICE_SHIFT);
    u8 want = SAVE_MODEL;
    if (want >= 1 && want <= 15) { int s = shown(want); FN(void, FN_SET, int)(s); }
    if (g_debug) LOG("armor: %s (model now %d, the game's %d)", c_name[c], (int)CUR_MODEL, (int)want);
}

/* ---------------- the menu entry ---------------- */
enum { M_OFF, M_ENTRY };
static int g_mode;
static int g_list_h, g_item;
static u8 *g_top;
static int g_seen;
static int (MSABI *o_list_input)(u8 *self);

static void item_drop(void) {
    if (L2D_Alive(g_item)) { FN(int, 0x1a5a50, int, int)(g_list_h, g_item); l2d_destroy(g_item); }
    g_item = 0; g_list_h = 0; g_mode = M_OFF;
}
void armor_on_destroy(int h) { if (h == g_list_h && h > 0) item_drop(); }

static void help(void) {
    char t[240];
    snprintf(t, sizeof t, "Outfit: %s. Press %c%c to change it.\nWorn where the story has no outfit of its own;\nit shows from the next area you enter.",
             c_name[choice()], 0xf5, 0x64);
    HELP_TEXT(t);
}
static void list_cursor(u8 *self, int idx) {
    static float mine[2] = { ITEM_X, ITEM_Y };
    float *pos = idx < 0 ? mine : (float*)(self + 0xa8 + idx * 8);
    if (*(u8**)(self + 0xb8)) FN(void, 0x4283c0, u8*, float*)(*(u8**)(self + 0xb8), pos);
    if (*(u8**)(self + 0xc0)) FN(void, 0x428800, u8*, float*, char)(*(u8**)(self + 0xc0), pos, 0);
}
static void enter_entry(u8 *self) {            /* the game has just wrapped its cursor to the entry in +0x8e */
    L2D_SetNodeControl(*(int*)(self + 0x20), (u16)(*(s16*)(self + 0x8e) + 1), 0);
    g_mode = M_ENTRY;
    list_cursor(self, -1);
    help();
}
static void leave_entry(u8 *self, int idx) {
    g_mode = M_OFF;
    *(s16*)(self + 0x90) = *(s16*)(self + 0x8e); *(s16*)(self + 0x8e) = (s16)idx;
    L2D_SetNodeControl(*(int*)(self + 0x20), (u16)(idx + 1), 4);
    list_cursor(self, idx);
    HELP_MSG(0x34370200 + idx);
    if (g_top) g_top[0x11] = 0;
}
/* vtable slot 8 of the list: its input, once a frame while the list has the focus */
static int MSABI list_input_hook(u8 *self) {
    u8 *top = g_top;
    g_seen = 1;
    int browsing = c_on && top && top[0x9b] == 2 && *(u8**)(top + 0x2b0) == self
                   && *(int*)(self + 0x20) == g_list_h && L2D_Alive(g_item);
    if (!browsing) {
        if (g_mode != M_OFF && top) leave_entry(self, N_LAST);
        return o_list_input(self);
    }
    if (g_mode == M_OFF) {
        s16 before = *(s16*)(self + 0x8e);
        int r = o_list_input(self);
        s16 after = *(s16*)(self + 0x8e), dir = *(s16*)(self + 0x8c);
        if (dir && ((before == N_LAST && after == 0 && dir > 0) || (before == 0 && after == N_LAST && dir < 0))) { enter_entry(self); top[0x11] = 1; }
        return r;
    }
    /* ours: the screen sees no buttons; read the pad as the game's menus do (newly pressed; up / down with repeat) */
    top[0x11] = 1;
    *(s16*)(self + 0x8c) = 0; self[0x9e] = 0;
    u32 press = (self[0x11] || G(u8, 0x10fb5364)) ? 0 : FN(u32, 0xecd90, u32)(0xffffffffu);
    u32 up = *(u32*)(self + 0x44), down = *(u32*)(self + 0x48);
    u32 move = FN(u32, 0x429960, u8*, u32)(self, up | down);
    u32 ok = G(u16, 0x8221c0), cancel = G(u16, 0x8221c4);
    if (move & up) { leave_entry(self, N_LAST); self[0x10] = 1; *(u32*)(self + 0xc) = up; SE(1); }
    else if (move & down) { leave_entry(self, 0); self[0x10] = 1; *(u32*)(self + 0xc) = down; SE(1); }
    else if (press & ok) { choice_set((choice() + 1) % 3); help(); SE(2); }
    else if (press & cancel) { leave_entry(self, N_LAST); return o_list_input(self); }   /* the screen closes as usual */
    return 0;
}
/* our plate, once a frame after the screen's update */
static void item_frame(u8 *top) {
    u8 *list = *(u8**)(top + 0x2b0);
    int lh = list ? *(int*)(list + 0x20) : 0;
    if (!L2D_Alive(lh)) { if (g_list_h) item_drop(); return; }
    if (lh != g_list_h) { item_drop(); g_list_h = lh; }
    if (!L2D_Alive(g_item)) {
        u8 *pc = FN(u8*, 0x1a65c0, int)(lh);
        g_item = pc ? l2d_attach_seq(lh, pc, N_ROOT, SEQ_PLATE) : 0;
        if (!g_item) return;
        FontParam fp; memset(&fp, 0, sizeof fp);
        fp.text = c_title; fp.colour = 0xff808080; fp.pitch = 0x0c; fp.align = 0; fp.size = 0; fp.kind = 1;
        fp.flags = 0x01 | 0x02 | 0x04 | 0x08 | 0x40 | 0x80;
        FN(int, 0x1a7450, int, FontParam*, int)(g_item, &fp, 0);
        L2D_SetPos(g_item, ITEM_X, ITEM_Y);
    }
    int idle = L2D_GetNodeControl(lh, (u16)(*(s16*)(list + 0x8e) == 0 ? 2 : 1));
    if (idle < 0 || idle > 7 || idle == 4) idle = 0;
    int want = g_mode != M_OFF ? 4 : idle;
    if (L2D_GetControl(g_item) != want) L2D_SetControl(g_item, want);
    L2D_Show(g_item, L2D_IsVisible(lh) != 0);
}
static u64 MSABI top_update_hook(u8 *self) {
    g_top = self; g_seen = 0;
    u64 r = FN(u64, FN_TOP_UPDATE, u8*)(self);
    if (g_mode != M_OFF && !g_seen) { g_mode = M_OFF; self[0x11] = 0; }
    item_frame(self);
    g_top = NULL;
    return r;
}

/* ---------------- install ---------------- */
static int call_ok(u32 rva, u32 target) {
    u8 *p = g_base + rva; s32 d; memcpy(&d, p + 1, 4);
    return p[0] == 0xE8 && (u32)(rva + 5 + d) == target;
}
static void ini_text(const char *key, char *out, size_t n) {
    char b[64];
    GetPrivateProfileStringA("Armor", key, "", b, sizeof b, g_ini);
    if (b[0]) snprintf(out, n, "%s", b);
}
int armor_check(void) {
    char b[32];
    GetPrivateProfileStringA("Armor", "Enabled", "1", b, sizeof b, g_ini); c_on = atoi(b);
    ini_text("MenuText", c_title, sizeof c_title);
    ini_text("NoArmor", c_name[0], sizeof c_name[0]);
    ini_text("Armor", c_name[1], sizeof c_name[1]);
    ini_text("NoHelmet", c_name[2], sizeof c_name[2]);
    if (!c_on) return 1;
    int bad = 0;
    for (unsigned i = 0; i < sizeof SET_CALLS / sizeof *SET_CALLS; i++) if (!call_ok(SET_CALLS[i], FN_SET)) { LOG("armor: model site %x does not match", SET_CALLS[i]); bad++; }
    for (unsigned i = 0; i < sizeof CHANGE_CALLS / sizeof *CHANGE_CALLS; i++) if (!call_ok(CHANGE_CALLS[i], FN_CHANGE)) { LOG("armor: model site %x does not match", CHANGE_CALLS[i]); bad++; }
    if (G(u64, VT_TOP_UPDATE) != (u64)(g_base + FN_TOP_UPDATE) || G(u64, VT_LIST_INPUT) != (u64)(g_base + FN_LIST_INPUT)) { LOG("armor: items screen vtable slots do not match"); bad++; }
    if (!l2d_destroy_site_ok()) { LOG("armor: Destroy does not match"); bad++; }
    return bad == 0;
}
void armor_apply(void) {
    if (!c_on || !l2d_destroy_hook()) return;
    for (unsigned i = 0; i < sizeof SET_CALLS / sizeof *SET_CALLS; i++) hook_call(SET_CALLS[i], FN_SET, set_hook, "armor: model set");
    for (unsigned i = 0; i < sizeof CHANGE_CALLS / sizeof *CHANGE_CALLS; i++) hook_call(CHANGE_CALLS[i], FN_CHANGE, change_hook, "armor: model change");
    o_list_input = (void*)(g_base + FN_LIST_INPUT);
    void *f; u64 old;
    f = (void*)top_update_hook;  old = (u64)(g_base + FN_TOP_UPDATE); patch_bytes(VT_TOP_UPDATE, (u8*)&old, (u8*)&f, 8, "items screen update");
    f = (void*)list_input_hook;  old = (u64)(g_base + FN_LIST_INPUT); patch_bytes(VT_LIST_INPUT, (u8*)&old, (u8*)&f, 8, "items list input");
    LOG("armor: \"%s\" entry in the Items menu", c_title);
}
void armor_own(char *out, int n) { own_add(out, n, "armorplate", g_item); }

#ifndef _WIN32      /* offline test access */
int  test_armor_choice(void) { return choice(); }
void test_armor_set(int c) { choice_set(c); }
int  test_armor_shown(int m) { return shown(m); }
void *test_armor_set_hook(void) { return (void*)set_hook; }
void *test_armor_change_hook(void) { return (void*)change_hook; }
int  test_armor_input(u8 *self) { return list_input_hook(self); }
void test_armor_top(u8 *top) { g_top = top; }
void test_armor_frame(u8 *top) { item_frame(top); }
int *test_armor_state(void) { static int s[3]; s[0] = g_mode; s[1] = g_item; s[2] = g_list_h; return s; }
#endif
