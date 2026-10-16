/* TESTING ONLY (debug, bbskh2_debug.txt) - remove before a release.  Finding out what the player's outfits are.

   The player's model is one number, 1..15 = character (1 Ventus, 2 Aqua, 3 Terra) + 3 x outfit (0..4; files p0x..p4x),
   held at 150f9ee4c (getter 26b7d0, setter 26c720) and in the save at 150fa0887.  1401ebc00(model) changes it (and the
   save byte); the next room load builds the player from it (26ad90(0, ..) from 1ebb11).  On every room entry 1ed3f2
   asks the room's event data (3115f0: entries of type 6) for an outfit: 0x10 / 0x20 / 0x30 / 0x40 / 0x50 = outfit
   0..4 of the current character (1 / 2 / 3 = that character, normal clothes), anything else = keep; then 1ed44d calls
   1ebc00.
   Here: every room entry is logged (what the room asks for, the model before and after); F7 picks the next outfit
   (it shows from the next room load on - go through a door), and that outfit also replaces whatever a room asks for
   from then on; F6 lets the rooms decide again. */
#include "core.h"
#include <string.h>
#include "mod.h"

extern int g_debug;
#define CUR_MODEL   G(u32, 0x10f9ee4c)
#define ROOM_ASK    0x3115f0u
#define ROOM_CALL   0x1ed3f2u
#define SET_MODEL   0x1ebc00u
#define SET_CALL    0x1ed44du

static int call_ok(u32 rva, u32 target) {
    u8 *p = g_base + rva; s32 d; memcpy(&d, p + 1, 4);
    return p[0] == 0xE8 && (u32)(rva + 5 + d) == target;
}
static int g_on, g_force = -1;       /* outfit forced by F7 (0..4), -1 = the rooms decide */
static const char *const k_char[4] = { "?", "Ventus", "Aqua", "Terra" };

static int ch_of(int m) { return m >= 1 ? (m - 1) % 3 + 1 : 0; }
static int of_of(int m) { return m >= 1 ? (m - 1) / 3 : -1; }

static int MSABI room_ask_hook(void *room) {
    int v = FN(int, ROOM_ASK, void*)(room);
    int m = (int)CUR_MODEL;
    LOG("outfit: room entry - the room asks for %#x (%s), current model %d = %s outfit %d (p%d%d)%s", v,
        v == 0 ? "nothing: keep" : v >= 1 && v <= 3 ? "that character, normal" : (v & 15) == 0 && v >= 0x10 && v <= 0x50 ? "an outfit" : "?",
        m, k_char[ch_of(m)], of_of(m) + 1, of_of(m), ch_of(m), g_force >= 0 ? " [F7 outfit forced]" : "");
    return v;
}
static void MSABI set_model_hook(int m) {
    int want = m;
    if (g_force >= 0 && m >= 1 && m <= 15) want = ch_of(m) + 3 * g_force;
    LOG("outfit: room sets model %d (%s outfit %d)%s", m, k_char[ch_of(m)], of_of(m) + 1,
        want != m ? " - replaced by the F7 outfit" : "");
    if (want != m) LOG("outfit: -> model %d (%s outfit %d, p%d%d)", want, k_char[ch_of(want)], of_of(want) + 1, of_of(want), ch_of(want));
    FN(void, SET_MODEL, int)(want);
}

/* every frame (speed.c's player tick, local player) */
void outfit_test_frame(void) {
    static int was7, was6;
    if (!g_on) return;
    int d7 = (GetAsyncKeyState(VK_F7) & 0x8000) != 0, d6 = (GetAsyncKeyState(VK_F6) & 0x8000) != 0;
    if (d7 && !was7) {
        int m = (int)CUR_MODEL, c = ch_of(m);
        if (c) {
            int o = g_force >= 0 ? (g_force + 1) % 5 : (of_of(m) + 1) % 5;
            g_force = o;
            FN(void, SET_MODEL, int)(c + 3 * o);
            LOG("outfit: F7 - %s outfit %d (model %d, files p%d%d) from the next room load on; rooms can no longer change it (F6 = let them)",
                k_char[c], o + 1, c + 3 * o, o, c);
            MessageBeep(MB_OK);
        }
    }
    if (d6 && !was6) {
        g_force = -1;
        LOG("outfit: F6 - the rooms decide the outfit again (current model %d)", (int)CUR_MODEL);
        MessageBeep(MB_ICONASTERISK);
    }
    was7 = d7; was6 = d6;
}
int outfit_test_check(void) {
    if (!g_debug) return 1;
    if (!call_ok(ROOM_CALL, ROOM_ASK) || !call_ok(SET_CALL, SET_MODEL)) { LOG("outfit test: sites do not match"); return 0; }
    return 1;
}
void outfit_test_apply(void) {
    if (!g_debug) return;
    hook_call(ROOM_CALL, ROOM_ASK, room_ask_hook, "outfit test: room asks");
    hook_call(SET_CALL, SET_MODEL, set_model_hook, "outfit test: room sets");
    g_on = 1;
    LOG("outfit test: on (F7 next outfit, F6 rooms decide); current model %d", (int)CUR_MODEL);
}
