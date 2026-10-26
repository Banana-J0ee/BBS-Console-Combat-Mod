/* Pace of the player's actions: less ending lag, weight in the air, a little more speed, KH2's cast times.

   The player (PL::CPlayer, update 220550) is a state machine; an action is one of the states
       0x10 attacks (normal combo = sub-state 5, deck attack commands = sub-state 3 / 4)
       0x11 magic   0x12 items   0x13 friend / D-Link commands   0x14 finishers
   and every one of them ends only when its animation has played out (magic: when a fixed 40-tick lock after the
   release has run out).  The stick is not read at all in between.  docs/NOTES.md has the map; in short:

   1. Walk-out.  Each state has one place where it asks "has the animation finished?" and either ends the action
      (21c510) or carries on.  A hook on each of those tests ends the action early when the stick is tilted and the
      action is "done": every hit window of the body and the weapon has closed (read from the game's own collision
      controllers), the attack's own movement and its triggers are over, plus a few frames of follow-through.
      While the next hit of a combo can still be asked for, only a *change* of the stick counts (neutral <-> tilted
      or a turn of 1 rad), so that holding the stick towards the enemy never cuts a combo short.
          2291bf  normal attacks        end 2291cd      2246c0 / 224476  deck attacks   end 2264d3
          2253ff  dash-type commands    end 22540d      262056  items                    end 262064
          2599ab  friend commands       end 2599b9      2562bc  generic finishers        end 2562c6
          26825f / 26828a  magic recovery               end 26829a
   2. Air.  An action started in the air sets pl+0x318 bit 23: the integrator 21cb00 then forbids sinking until
      frMoveEnd and uses 16 % gravity for the rest of the action.  The hook at 21cb55 clears that bit (in the
      register copy the function tests) once the action is done and nothing can follow, so the character falls
      through the recovery.  After the action the fall state holds vy for the first 6 frames of the fall loop
      [2633ff]; that is skipped when the fall follows an action.  The button lock after an action that ended in
      the air (30 ticks, 26407b) is shortened.
   3. Speed.  entity+0x1a8 is the game's own animation speed factor (Haste 2.0, Slow 0.5, Stop 0; hit windows,
      triggers and the weapon follow it).  It is set once per frame from the call at 220b1d, only while it holds
      exactly 1.0 or our own value, and put back when the action is over.  Attack lunges are speed * time, so their
      speed is raised by the same factor [21cf52] to keep their reach.
   4. Cast times.  KH2 (Sora, ground): Fire goes off at 0.37 s and the next action can start at 1.00 s; Blizzard
      0.27 / 0.60; Thunder 0.30 / 0.70; Cure goes off at 0.30.  BBS: Fire 0.33-0.43, Blizzard 0.33-0.43, Thunder
      0.33-0.50, Cure 0.60-0.73, and every spell is locked for 40 ticks (0.67 s) after it goes off.  The wind-up
      is played faster so that the release frame (PAtk t1) comes at KH2's time, never slower than the original,
      and the lock after the release gets KH2's length per family.  Cure goes off at 0.40 s here, not KH2's 0.30
      (asked for: 0.30 made its wind-up 2-2.4 times the game's speed and felt too quick).  The big spells (Mega
      Flare, Meteor, Raging Storm ..., [Speed] BigSpells) play at 1.05 instead of Actions.
   6. Air hops (KH2's air combo, [Speed] AirHop).  BBS holds the player up in an air combo by taking gravity away:
      every aerial hit starts with vy = 0, no sinking at all before frMoveEnd, 16 % gravity after it, and the next
      hit starts again from vy = 0.  KH2 gives each air hit an upward speed instead (Sora: first hit 8, then 6, the
      finisher 12 - per 1/60 s, in units of about a centimetre) and leaves gravity on.  Here, for the hits of the
      Attack button in the air (state 0x10 part 5, records with AERIAL and none of RISE / DOWN / FLOAT):
        - when a hit starts, vy = the speed that brings the player back to the height he started the hit at by the
          time the next hit can start (frChangeEnable, at the speed the animation plays): g * T / 2, times
          AirHopKeep (below 1 = a little lower after every hit), times AirHopFirst for the first hit in the air;
          the finisher (the last hit of the combo) gets AirHopFinisher x the character's jump speed instead;
        - during the hit full gravity (x AirHopGravity), no no-sink clamp and no "rise stops at frMoveEnd": the hook
          at 21cb55 in the integrator 21cb00 goes on at 21cb7a with its own gravity in xmm0, bit 23 cleared in the
          register copy and xmm4 (frMoveEnd) out of reach.
      The game's own pull towards a target above (229fa0: +44u) is replaced by the hop for these hits.  In its place
      (AirReach, after KH2's rising attack for enemies 0.5 .. 1.9 m above): when the target is at least AirReachMin
      above (pl+0x618, the height difference the game keeps for its homing; pl+0x600 > 0 = a target), the hit
      gets the speed that just reaches that height, sqrt(2 g dy) with dy capped at AirReachMax and the speed at
      the character's jump - if that is more than the hop.  Once level with the target, the next hits are hops.  Everything
      else in the air (commands, styles, spells, FLOAT moves, Terra's plunge) is the game's.
   7. Air log ([Speed] AirLog = 1): every frame in the air, one line in bbskh2_log.txt - state, part, record,
      animation frame, vy, height since take-off (summed from vy), gravity - and a summary on landing.
   5. Per command ([CommandSpeed] in the ini, "<command id in hex>=<speed>").  A command listed there is played at
      that speed from start to end - whatever state the player is in for it (attack, magic, item, D-Link,
      finisher, shotlock, movement, guard, counter, reaction), as long as the game says a command is running
      (pl+0x5e0 != 0, its id in pl+0x312).  It stands in for every rule above for that command; anything not
      listed keeps them.  The ticks-based lock after a spell's release (FireFree ...) is not an animation and
      stays.  Haste / Slow / Stop still win, as they do over Actions. */
#include "core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include "steals_gen.h"
#include "mod.h"

extern char g_ini[MAX_PATH + 32];
extern int g_debug;

static int   c_on = 1, c_walk = 1, c_air = 1, c_lunge = 1;
static float c_actions = 1.15f;         /* animation speed of attacks, commands, items, spell recovery */
static float c_margin = 3.0f;           /* frames of follow-through after the last hit window */
static float c_airlock = 6.0f;          /* ticks without buttons after an action that ended in the air (game: 30) */
/* KH2's release times in seconds (0 = leave the spell alone) and ticks from release to "free" (game: 40) */
static float c_rel_fire = 0.37f, c_rel_blizzard = 0.27f, c_rel_thunder = 0.30f, c_rel_cure = 0.40f;
/* the big spells, which have no KH2 counterpart and play at Actions otherwise: a little slower than that */
static float c_big = 1.05f;
static int big_spell(u16 id) {
    return (id >= 0xa6 && id <= 0xb0)               /* Faith, Deep Freeze, Glacier, Ice Barrage, Firaga Burst, Raging Storm,
                                                       Mega Flare, Quake, Tornado, Meteor, Transcendence */
        || id == 0x88 || id == 0x8d;                /* Triple Firaga, Triple Blizzaga */
}
static float c_free_fire = 38.0f, c_free_blizzard = 20.0f, c_free_thunder = 24.0f;
static float c_cast_max = 2.5f;
static int   c_hop = 1, c_airlog = 0;
static int   c_jump_hang = 0;           /* 1 = the game's 6-frame hang at the top of a jump (and any fall) */
static float c_hop_keep = 0.9f, c_hop_first = 1.2f, c_hop_fin = 0.6f, c_hop_grav = 1.0f;
static int   c_reach = 1;
static float c_reach_min = 0.5f, c_reach_max = 1.9f;
static int   c_launch = 1;              /* KH2's height band for the rising attack (the launcher) */
static float c_launch_min = 1.1f, c_launch_max = 4.35f, c_launch_reach = 2.6f;
#define P_AERIAL 0x0002
#define P_RISE   0x0010
#define P_DOWN   0x0020
#define P_FLOAT  0x2000
static u8 *local_player(void) { u8 *m = G(u8*, 0x10f9f540); return m ? *(u8**)(m + 0x118) : NULL; }
static const u8 *g_hop_live;            /* the record of the hit that is hopping now (started in the air) */
/* an Attack-button hit in the air that hops, KH2-style */
static int hop_hit(u8 *pl) {
    if (!c_hop || !pl || pl != local_player()) return 0;
    if (*(u16*)(pl + 0x304) != 0x10 || *(s16*)(pl + 0x310) != 5 || !(*(u32*)(pl + 0x318) & 0x800000)) return 0;
    const u8 *rec = *(u8**)(pl + 0x5b8);
    if (!rec) return 0;
    u16 fl = *(u16*)(rec + 4);
    return (fl & P_AERIAL) && !(fl & (P_RISE | P_DOWN | P_FLOAT));
}
#define CMD_IDS 0x240
static float g_cmd_speed[CMD_IDS];      /* [CommandSpeed]: speed of one command, 0 = not listed */
static float cmd_override(u8 *pl) {
    if (!*(u32*)(pl + 0x5e0)) return 0.0f;                      /* no command running */
    u16 id = *(u16*)(pl + 0x312);
    return id < CMD_IDS ? g_cmd_speed[id] : 0.0f;
}

#define STICK_MOVE 0.45f                /* the game's own "moving" threshold (0x6470e8) */
enum { K_NORMAL, K_DECK, K_ITEM, K_FRIEND, K_FINISH, K_MAGIC };

/* combo finishers of the Attack button: the PAtkData records the combo tables (PBA_*.bin, PAO_*.bin) use as their
   last hit (record type 2) */
static const u16 fin_idx[] = { 15, 20, 27, 32, 38, 44, 48, 53, 59, 65, 71, 77, 81, 86, 299, 306, 307, 312, 318, 323, 329,
    333, 339, 344, 348, 352, 363, 367, 372, 580, 581, 586, 591, 597, 602, 608, 613, 619, 624, 629, 633, 637, 644, 650,
    654, 660, 664, 864, 871, 878 };
static int is_finisher(const u8 *rec) {
    u8 *mgr = G(u8*, 0x10f9f540); if (!mgr) return 0;
    u8 *base = *(u8**)(mgr + 0x128); if (!base || rec < base) return 0;
    size_t i = (size_t)(rec - base) / 0x28;
    for (unsigned k = 0; k < sizeof fin_idx / sizeof *fin_idx; k++) if (fin_idx[k] == i) return 1;
    return 0;
}

static long patk_index(const u8 *rec) {    /* the record's number in PAtkData (for the log) */
    u8 *mgr = G(u8*, 0x10f9f540); u8 *base = mgr ? *(u8**)(mgr + 0x128) : NULL;
    return base && rec >= base ? (long)((rec - base) / 0x28) : -1;
}
static float frame_of(u8 *pl) { u8 *mot = *(u8**)(pl + 0x78); return mot ? *(float*)(mot + 0x3c) : 0.0f; }
static int   finished(u8 *pl) { u8 *mot = *(u8**)(pl + 0x78); return !mot || (mot[8] & 1); }

/* Hit windows of one entity for the current animation.  Controller = *(entity+0x88): +0x20 count, +0x28 entries
   (0x90 each): +0x28 / +0x2a state of the first / second shape (0 not yet, 1 on, 2 on until the animation ends,
   3 over), +0x48 description: s16 +0x24 on, +0x26 off, +0x30 on of the second shape (-1 = none), +0x32 off. */
static void windows(u8 *ent, int *n, int *open, float *last) {
    if (!ent) return;
    u8 *ctl = *(u8**)(ent + 0x88); if (!ctl) return;
    int cnt = *(s32*)(ctl + 0x20); u8 *e = *(u8**)(ctl + 0x28);
    if (!e || cnt <= 0 || cnt > 64) return;
    for (int i = 0; i < cnt; i++, e += 0x90) {
        u8 *d = *(u8**)(e + 0x48); if (!d) continue;
        for (int k = 0; k < 2; k++) {
            if (k && *(s16*)(d + 0x30) < 0) break;
            s16 st = *(s16*)(e + 0x28 + 2 * k), off = *(s16*)(d + (k ? 0x32 : 0x26));
            (*n)++;
            if (st != 3) (*open)++;
            else if ((float)off > *last) *last = (float)off;
        }
    }
}
/* the frame from which the action is "done", or -1 while that cannot be said */
static int g_dbg_n; static float g_dbg_last;
static float done_frame(u8 *pl, const u8 *rec, int kind) {
    int n = 0, open = 0; float last = 0.0f;
    windows(pl, &n, &open, &last);
    windows(*(u8**)(pl + 0x378), &n, &open, &last);
    g_dbg_n = n; g_dbg_last = last;
    if (open) return -1.0f;
    float busy = last;
    if (rec[0x1f] > busy) busy = rec[0x1f];                      /* frMoveEnd */
    if (rec[0x1d] > busy) busy = rec[0x1d];                      /* frMarkEnd */
    for (int i = 0x14; i <= 0x17; i++) if (rec[i] && rec[i] + 1.0f > busy) busy = rec[i] + 1.0f;   /* triggers */
    float d;
    if (kind == K_ITEM) d = rec[0x14] + c_margin;                /* the item takes effect at t1 */
    else if (n) d = last + c_margin;
    else if (rec[0x0d]) d = rec[0x0d];                           /* nothing to hit with: frChangeEnable */
    else return -1.0f;
    return d > busy + 1.0f ? d : busy + 1.0f;
}

/* has the stick changed since this attack began? */
static struct { const u8 *rec; float last, yaw; u8 tilted, changed; } g_trk;
static void track(const u8 *rec, float fr, int tilted, float yaw) {
    if (rec != g_trk.rec || fr < 1.0f || fr < g_trk.last) {
        g_trk.rec = rec; g_trk.yaw = yaw; g_trk.tilted = (u8)tilted; g_trk.changed = 0;
    } else if (tilted != g_trk.tilted) g_trk.changed = 1;
    else if (tilted) {
        float d = yaw - g_trk.yaw;
        if (d > 3.14159265f) d -= 6.2831853f;
        if (d < -3.14159265f) d += 6.2831853f;
        if (d * d >= 1.0f) g_trk.changed = 1;
    }
    g_trk.last = fr;
}
/* can another press still continue this action (the next hit of a combo, or of a command that is pressed again)? */
static int can_follow(u8 *pl, const u8 *rec, int kind, float fr) {
    u8 cmb = rec[0x0c];
    if (kind == K_NORMAL) return !is_finisher(rec) && cmb && fr < cmb;
    if (kind == K_DECK) {
        u16 id = *(u16*)(pl + 0x312);
        if (id == 0x5c || id == 0x6f || id == 0x75) return !cmb || fr < cmb;
    }
    return 0;
}

/* Set by the hooks below when the action whose end test they sit on is done and nothing can follow; read by the
   gravity hook, which the same state function calls later in the frame; cleared once per frame (tick_hook). */
static u8 *g_fall;

/* the common part of the end tests: 1 = end the action now */
static int leave(u8 *pl, int kind) {
    const u8 *rec = *(u8**)(pl + 0x5b8);
    if (!rec || !*(u8**)(pl + 0x78)) return 0;
    float fr = frame_of(pl);
    int tilted = *(float*)(pl + 0x44c) >= STICK_MOVE;
    track(rec, fr, tilted, *(float*)(pl + 0x454));
    if (finished(pl)) return 0;
    if (*(u32*)(pl + 0x320) & 0x80) return 0;                    /* a command is queued */
    if (kind == K_FINISH && (*(u16*)(rec + 4) & 0x1000) && *(u16*)(pl + 0x422) == rec[8]) return 0;   /* a second animation follows */
    float d = done_frame(pl, rec, kind);
    if (d < 0.0f || fr < d) return 0;
    int follow = can_follow(pl, rec, kind, fr);
    if (!follow && !(*(u16*)(rec + 4) & 0x2000)) g_fall = pl;    /* (FLOAT attacks hover on purpose) */
    if (!c_walk || !tilted) return 0;
    if (*(u32*)(pl + 0x31c) & 0x2000) return 0;                  /* the game is ignoring the stick */
    if (follow && !g_trk.changed) return 0;
    if (g_debug) LOG("speed: walk-out, command %x record %d frame %.1f (done at %.0f; %d hit windows, last closes at %.0f; kind %d, %s)", *(u16*)(pl + 0x312),
                     (int)((rec - *(u8**)(G(u8*, 0x10f9f540) + 0x128)) / 0x28), fr, d, g_dbg_n, g_dbg_last, kind, (*(u32*)(pl + 0x318) & 0xc00000) ? "air" : "ground");
    return 1;
}

/* ---- command cancel ([CommandCancel]) ----
   A deck command (attack or magic, ids 5b..bb) can be cut short once it is over: its last hit window has closed
   (+ FollowThrough), plus a per-command delay from the ini (negative = earlier: the last hit can be cut off; never
   before the last animation starts, nor before a spell goes off).  Whatever is pressed then - another command, Attack,
   guard, dodge, jump, shotlock ... - starts at once; nothing pressed, and the animation plays to its end.
   "Over" is only judged where the game itself waits for the command's last animation to finish (the end tests
   hooked above: deck attacks 2246c0 / 224476, dashes and surges 2253ff, magic recovery 26825f / 26828a), so a
   multi-part command is never cut between its parts; commands that run their own end code are not covered yet.
   Commands that are pressed again (Blitz, Ars Arcanum ...) are left alone while another press could continue them.
   How: on such a frame the player's accept bit 0x40 (pl+0x318) is set after the state function (220b1d), so the
   command panel takes any button as a request [233d0a, 236e53, 232df0]; the next update, right after the request
   reached pl+0x31c (21f9f0, called at 2206f8), the action is ended with the game's own 21c510 - which keeps a
   request taken that frame (pl+0x31c bit 0x8000000) - and the idle / fall state that follows starts it through
   2176b0, the dispatcher those states call every frame.  A press up to BufferFrames before the moment is held
   and released then.  Requests the action's own window already takes (21c140) are left to the game. */
static int   c_cc = 1;
static float c_cc_buf = 8.0f;                   /* frames (1/30 s) a press may come early */
static float g_cc_off[CMD_IDS];                 /* frames later (or, negative, earlier) than "over", per command */
static const struct { u16 id; const char *name; } cc_names[] = {
    { 0x5b, "Quick Blitz" },
    { 0x5c, "Blitz" },
    { 0x5d, "Magic Hour" },
    { 0x5e, "Meteor Crash" },
    { 0x5f, "Sliding Dash" },
    { 0x60, "Fire Dash" },
    { 0x61, "Dark Haze" },
    { 0x62, "Sonic Blade" },
    { 0x63, "Chaos Blade" },
    { 0x64, "Zantetsuken" },
    { 0x65, "Strike Raid" },
    { 0x66, "Freeze Raid" },
    { 0x67, "Treasure Raid" },
    { 0x68, "Spark Raid" },
    { 0x69, "Wind Raid" },
    { 0x6a, "Fire Surge" },
    { 0x6b, "Barrier Surge" },
    { 0x6c, "Thunder Surge" },
    { 0x6d, "Aerial Slam" },
    { 0x6e, "Ars Solum" },
    { 0x6f, "Ars Arcanum" },
    { 0x70, "Time Splicer" },
    { 0x71, "Poison Edge" },
    { 0x72, "Wishing Edge" },
    { 0x73, "Blizzard Edge" },
    { 0x74, "Stun Edge" },
    { 0x75, "Slot Edge" },
    { 0x76, "Fire Strike" },
    { 0x77, "Confusion Strike" },
    { 0x78, "Binding Strike" },
    { 0x79, "Tornado Strike" },
    { 0x7a, "Brutal Blast" },
    { 0x7b, "Magnet Spiral" },
    { 0x7c, "Salvation" },
    { 0x7d, "Windcutter" },
    { 0x7e, "Limit Storm" },
    { 0x7f, "Collision Magnet" },
    { 0x80, "Geo Impact" },
    { 0x81, "Sacrifice" },
    { 0x82, "Break Time" },
    { 0x83, "Fire" },
    { 0x84, "Fira" },
    { 0x85, "Firaga" },
    { 0x86, "Dark Firaga" },
    { 0x87, "Fission Firaga" },
    { 0x88, "Triple Firaga" },
    { 0x89, "Crawling Fire" },
    { 0x8a, "Blizzard" },
    { 0x8b, "Blizzara" },
    { 0x8c, "Blizzaga" },
    { 0x8d, "Triple Blizzaga" },
    { 0x8e, "Thunder" },
    { 0x8f, "Thundara" },
    { 0x90, "Thundaga" },
    { 0x91, "Thundaga Shot" },
    { 0x92, "Cure" },
    { 0x93, "Cura" },
    { 0x94, "Curaga" },
    { 0x95, "Esuna" },
    { 0x96, "Mine Shield" },
    { 0x97, "Mine Square" },
    { 0x98, "Seeker Mine" },
    { 0x99, "Zero Gravity" },
    { 0x9a, "Zero Gravira" },
    { 0x9b, "Zero Graviga" },
    { 0x9c, "Magnet" },
    { 0x9d, "Magnera" },
    { 0x9e, "Magnega" },
    { 0x9f, "Munny Magnet" },
    { 0xa0, "Energy Magnet" },
    { 0xa1, "D-Link Magnet" },
    { 0xa2, "Aero" },
    { 0xa3, "Aerora" },
    { 0xa4, "Aeroga" },
    { 0xa5, "Warp" },
    { 0xa6, "Faith" },
    { 0xa7, "Deep Freeze" },
    { 0xa8, "Glacier" },
    { 0xa9, "Ice Barrage" },
    { 0xaa, "Firaga Burst" },
    { 0xab, "Raging Storm" },
    { 0xac, "Mega Flare" },
    { 0xad, "Quake" },
    { 0xae, "Tornado" },
    { 0xaf, "Meteor" },
    { 0xb0, "Transcendence" },
    { 0xb1, "Mini" },
    { 0xb2, "Blackout" },
    { 0xb3, "Ignite" },
    { 0xb4, "Confuse" },
    { 0xb5, "Bind" },
    { 0xb6, "Poison" },
    { 0xb7, "Slow" },
    { 0xb8, "Stop" },
    { 0xb9, "Stopra" },
    { 0xba, "Stopga" },
    { 0xbb, "Sleep" },
};
/* commands that end through their own code (multi-part or own handlers): not covered */
static int cc_covered(u16 id) {
    if (id >= 0x92 && id <= 0x94) return 0;                     /* Cure, Cura, Curaga: never (asked for) */
    if (id >= 0x83 && id <= 0xbb)                               /* magic: those that end in the shared recovery */
        return !((id >= 0x9f && id <= 0xa1) || id == 0xa6 || id == 0xa7 || id == 0xa8 || id == 0xaa || id == 0xab || (id >= 0xae && id <= 0xb0));
    switch (id) {
    case 0x5b: case 0x5c: case 0x5f: case 0x60: case 0x6a: case 0x6b: case 0x6c: case 0x6d: case 0x6f:
    case 0x71: case 0x72: case 0x73: case 0x74: case 0x76: case 0x77: case 0x78: case 0x81: return 1;
    }
    return 0;
}
static int cc_repress(u16 id) { return id == 0x5c || id == 0x62 || id == 0x63 || id == 0x6d || id == 0x6e || id == 0x6f || id == 0x75; }
#define CC_REQ (0x1u | 0x4u | 0x8u | 0x10u | 0x20u | 0x40u | 0x100u | 0x200u | 0x200000u | 0x800000u)
enum { CCS_NONE, CCS_ZONE, CCS_READY };
static struct {
    unsigned seen;                  /* tick in which an end test of the command was reached */
    int kind, state, logged;
    const u8 *rec; u16 id; u8 vacc; /* the action's own accept bits on that frame */
    u32 stash;                      /* requests held for the moment */
} g_cc;
static unsigned g_tick;
static void (MSABI *g_cc_end)(u8 *pl, int air, int moving);     /* 21c510 (the tests put their own here) */

static void cc_seen(u8 *pl, int kind) {
    if (!c_cc || pl != local_player()) return;
    g_cc.seen = g_tick; g_cc.kind = kind;
}
/* the deck command this action is, or 0 */
static u16 cc_command(u8 *pl) {
    u32 st = *(u32*)(pl + 0x304); u16 id = *(u16*)(pl + 0x312); s16 part = *(s16*)(pl + 0x310);
    if (id < 0x5b || id > 0xbb || !cc_covered(id)) return 0;
    if (G(u8, 0x815900 + (u32)id * 0x18) != 2) return 0;                         /* a deck command */
    u8 cat = G(u8, 0x815901 + (u32)id * 0x18);
    if (st == 0x10) return cat == 1 && (part == 3 || part == 4) ? id : 0;
    if (st == 0x11) return cat == 2 && part == 4 ? id : 0;
    return 0;
}
/* the frame the command is over from: its last hit window closes (+ FollowThrough), its own movement and triggers
   are past; -1 = only when the animation ends (a window that stays on to the end) */
static float cc_over(u8 *pl, const u8 *rec, int magic) {
    float last = -1.0f; int n = 0, to_end = 0;
    u8 *ents[2] = { pl, *(u8**)(pl + 0x378) };
    for (int k = 0; k < 2; k++) {
        u8 *ctl = ents[k] ? *(u8**)(ents[k] + 0x88) : NULL; if (!ctl) continue;
        int cnt = *(s32*)(ctl + 0x20); u8 *e = *(u8**)(ctl + 0x28);
        if (!e || cnt <= 0 || cnt > 64) continue;
        for (int i = 0; i < cnt; i++, e += 0x90) {
            u8 *d = *(u8**)(e + 0x48); if (!d) continue;
            for (int j = 0; j < 2; j++) {
                if (j && *(s16*)(d + 0x30) < 0) break;
                n++;
                if (*(s16*)(e + 0x28 + 2 * j) == 2) to_end = 1;
                float off = *(s16*)(d + (j ? 0x32 : 0x26));
                if (off > last) last = off;
            }
        }
    }
    if (to_end) return -1.0f;
    float busy = 0.0f;
    if (rec[0x1f] > busy) busy = rec[0x1f];
    if (rec[0x1d] > busy) busy = rec[0x1d];
    for (int i = 0x14; i <= 0x17; i++) if (rec[i] && rec[i] + 1.0f > busy) busy = rec[i] + 1.0f;
    float d;
    if (n) d = last + c_margin;
    else if (magic) d = rec[0x14] + c_margin;                    /* the spell went off at t1 */
    else if (rec[0x0d]) d = rec[0x0d];
    else return -1.0f;
    if (magic && rec[0x0d] > d) d = rec[0x0d];
    return d > busy + 1.0f ? d : busy + 1.0f;
}
/* after this frame's state function (220b1d): is the command over, or nearly? then any button makes a request */
static void cc_after(u8 *pl) {
    g_cc.state = CCS_NONE;
    if (!c_cc || pl != local_player() || g_cc.seen != g_tick) return;
    u16 id = cc_command(pl); const u8 *rec = *(u8**)(pl + 0x5b8);
    if (!id || !rec || !*(u8**)(pl + 0x78)) return;
    if (*(u32*)(pl + 0x320) & 0x80) return;                      /* the game has queued the next command */
    if (*(u32*)(pl + 0x31c) & 0x2000) return;                    /* controls locked */
    float fr = frame_of(pl);
    if (cc_repress(id)) {
        u8 *cmd = *(u8**)(pl + 0x390);
        if (cmd && (*(u32*)(cmd + 0x60) & 0x1000)) return;      /* another press can still continue it */
        if (can_follow(pl, rec, K_DECK, fr)) return;
    }
    int magic = *(u32*)(pl + 0x304) == 0x11;
    u16 mo = *(u16*)(pl + 0x422);
    int anim_over = finished(pl) || (magic && (mo == 10 || mo == *(u16*)(pl + 0x428)));   /* spell: idle pose while its lock runs */
    float r = -1.0f;
    if (!anim_over) {
        r = cc_over(pl, rec, magic);
        if (r >= 0.0f) {
            r += g_cc_off[id];                                   /* a negative delay: earlier, into the last hit */
            if (magic && rec[0x14] && r < rec[0x14] + 1.0f) r = rec[0x14] + 1.0f;   /* a spell always goes off first */
            if (r < 0.0f) r = 0.0f;                              /* (only the last animation is judged at all) */
        }
    }
    int st = anim_over || (r >= 0.0f && fr >= r) ? CCS_READY : (r >= 0.0f && fr >= r - c_cc_buf ? CCS_ZONE : CCS_NONE);
    if (st == CCS_NONE) return;
    g_cc.state = st; g_cc.rec = rec; g_cc.id = id;
    g_cc.vacc = (u8)(*(u32*)(pl + 0x318) & 0xc0);
    *(u32*)(pl + 0x318) |= 0x40;
    if (g_debug && g_cc.logged != st) LOG("cancel: command %x %s at frame %.1f (over from %.1f)", id, st == CCS_READY ? "can be cancelled" : "takes early presses", fr, r);
    g_cc.logged = st;
}
/* right after the input reached the player (2206f8, before the state function) */
static void cc_before(u8 *pl) {
    if (!c_cc || pl != local_player()) return;
    u32 *rq = (u32*)(pl + 0x31c), req = *rq & CC_REQ;
    u32 st = *(u32*)(pl + 0x304);
    int same = (st == 0x10 || st == 0x11) && *(const u8**)(pl + 0x5b8) == g_cc.rec && *(u16*)(pl + 0x312) == g_cc.id;
    if (g_cc.stash) {
        if (req) g_cc.stash = req;                               /* a later press replaces it */
        if (same && g_cc.state != CCS_READY) { *rq &= ~req; *rq |= 0x8000000; return; }   /* (keeps the taken command through an end) */
        if (same && g_cc.state == CCS_READY) {
            *rq |= g_cc.stash | 0x8000000;
            if (g_debug) LOG("cancel: command %x cut short for a held press (%x)", g_cc.id, g_cc.stash);
            g_cc.stash = 0; g_cc.logged = 0;
            g_cc_end(pl, -1, 0);
            return;
        }
        if (st >= 1 && st <= 5) { *rq |= g_cc.stash | 0x8000000; if (g_debug) LOG("cancel: held press (%x) after the command's own end", g_cc.stash); }
        else if (g_debug) LOG("cancel: held press (%x) dropped (state %x)", g_cc.stash, st);
        g_cc.stash = 0;
        return;
    }
    if (!req || !same || g_cc.state == CCS_NONE) return;
    if (g_cc.vacc & 0x40) return;                                /* the action's own window takes everything */
    if ((g_cc.vacc & 0x80) && !(req & ~(0x4u | 0x8u | 0x100u | 0x200u))) return;      /* ... or this */
    if (req == 0x1 && (*(u32*)(pl + 0x318) & 0x400000)) return; /* jump in the air: nothing to do */
    if (g_cc.state == CCS_ZONE) { g_cc.stash = req; *rq &= ~req; *rq |= 0x8000000; return; }
    if (g_debug) LOG("cancel: command %x cut short (%x)", g_cc.id, req);
    g_cc.logged = 0;
    g_cc_end(pl, -1, 0);
}
static void cc_config(void) {
    char b[64];
    GetPrivateProfileStringA("CommandCancel", "Enabled", "1", b, sizeof b, g_ini); c_cc = atoi(b);
    char def[32]; snprintf(def, sizeof def, "%g", c_cc_buf);
    GetPrivateProfileStringA("CommandCancel", "BufferFrames", def, b, sizeof b, g_ini); c_cc_buf = (float)atof(b);
    if (!(c_cc_buf >= 0.0f && c_cc_buf <= 30.0f)) c_cc_buf = 8.0f;
    int n = 0;
    for (unsigned i = 0; i < sizeof cc_names / sizeof *cc_names; i++) {
        u16 id = cc_names[i].id; char hex[8]; b[0] = 0;
        GetPrivateProfileStringA("CommandCancel", cc_names[i].name, "", b, sizeof b, g_ini);
        if (!b[0]) { snprintf(hex, sizeof hex, "%x", id); GetPrivateProfileStringA("CommandCancel", hex, "", b, sizeof b, g_ini); }
        float v = b[0] ? (float)atof(b) : 0.0f;
        if (!(v >= -120.0f)) v = b[0] && v < 0.0f ? -120.0f : 0.0f;    /* negative = before "over", into the last hit */
        if (v > 120.0f) v = 120.0f;
        g_cc_off[id] = v;
        if (v != 0.0f) n++;
    }
    if (n) LOG("cancel: %d commands with a delay of their own", n);
}
static void MSABI input_hook(u8 *pl) {
    FN(void, 0x21f710, u8*)(pl);
    if (c_on) cc_before(pl);
}

static u64 MSABI h_attack(Ctx *c) { return leave((u8*)c->rbx, K_NORMAL) ? (u64)(g_base + 0x228eed) : 0; }
static u64 MSABI h_deck(Ctx *c)   { cc_seen((u8*)c->rdi, K_DECK); return leave((u8*)c->rdi, K_DECK) ? (u64)(g_base + 0x2261f3) : 0; }
static u64 MSABI h_dash(Ctx *c)   { cc_seen((u8*)c->rdi, K_DECK); return leave((u8*)c->rdi, K_DECK) ? (u64)(g_base + 0x22512d) : 0; }
static u64 MSABI h_item(Ctx *c)   { return leave((u8*)c->rbx, K_ITEM) ? (u64)(g_base + 0x261d84) : 0; }
static u64 MSABI h_friend(Ctx *c) { return leave((u8*)c->rbx, K_FRIEND) ? (u64)(g_base + 0x2596d9) : 0; }
static u64 MSABI h_finish(Ctx *c) { return leave((u8*)c->rbx, K_FINISH) ? (u64)(g_base + 0x255fe6) : 0; }

/* ---- magic ---- */
enum { F_NONE, F_FIRE, F_BLIZZARD, F_THUNDER, F_CURE };
static int family(u16 id) {
    if ((id >= 0x83 && id <= 0x87) || id == 0x89) return F_FIRE;
    if (id >= 0x8a && id <= 0x8c) return F_BLIZZARD;
    if (id >= 0x8e && id <= 0x91) return F_THUNDER;
    if (id >= 0x92 && id <= 0x95) return F_CURE;
    return F_NONE;
}
static int plain_spell(u8 *pl) {            /* an ordinary cast: magic command, not the Magnet family (its end resets the camera) */
    u16 m = *(u16*)(pl + 0x34c);
    return *(u32*)(pl + 0x5e0) == 2 && !(m >= 0x9c && m <= 0x9e);
}
/* 26825f: the cast animation has just finished, the lock is still running: the game would stand in the idle pose
   (or hang in the fall loop) until it is out */
static u64 MSABI h_mag_anim(Ctx *c) {
    u8 *pl = (u8*)c->rbx;
    cc_seen(pl, K_MAGIC);
    if (!c_walk || !plain_spell(pl) || *(float*)(pl + 0x1a0) > 40.0f) return 0;
    return (u64)(g_base + 0x267fba);
}
/* 26828a: every frame of the recovery in which nothing is queued, just before "lock <= 0 ?" */
static u64 MSABI h_mag_lock(Ctx *c) {
    u8 *pl = (u8*)c->rbx; const u8 *rec = *(u8**)(pl + 0x5b8);
    cc_seen(pl, K_MAGIC);
    float t = *(float*)(pl + 0x1a0);
    if (!rec || !plain_spell(pl) || t > 40.0f || t <= 0.0f) return 0;
    float fr = frame_of(pl);
    int late = rec[0x0d] && fr >= rec[0x0d];                     /* past frChangeEnable */
    if (*(u16*)(pl + 0x422) == 10 || (late && !(*(u32*)(pl + 0x320) & 0x80) && !(*(u16*)(rec + 4) & 0x2000))) g_fall = pl;
    if (c_on) {                                                  /* KH2's time from release to the next action */
        int f = family(*(u16*)(pl + 0x312));
        float fre = f == F_FIRE ? c_free_fire : f == F_BLIZZARD ? c_free_blizzard : f == F_THUNDER ? c_free_thunder : 40.0f;
        if (fre < 40.0f && 40.0f - t >= fre && !(*(u32*)(pl + 0x320) & 0x80)) return (u64)(g_base + 0x267fba);
    }
    if (!c_walk || finished(pl)) return 0;
    if (*(u32*)(pl + 0x320) & 0x80) return 0;
    if (*(u32*)(pl + 0x31c) & 0x2000) return 0;
    if (*(u16*)(pl + 0x422) == *(u16*)(pl + 0x428)) return 0;    /* already waiting in the idle pose */
    if (*(u16*)(rec + 4) & 0x2000) return 0;                     /* FLOAT */
    if (*(float*)(pl + 0x44c) < STICK_MOVE || !late) return 0;
    float d = done_frame(pl, rec, K_MAGIC);
    if (d < 0.0f || fr < d) return 0;
    if (g_debug) LOG("speed: walk-out of spell %x at frame %.1f", *(u16*)(pl + 0x312), fr);
    return (u64)(g_base + 0x267fba);
}

/* ---- air ---- */
/* 21cb55 in the vertical integrator 21cb00: rcx = player, eax = copy of pl+0x318 (bit 23 = aerial action: no sinking
   before frMoveEnd, 16 % gravity), r9d = mode (0 = plain gravity, 0x2000 = FLOAT record) */
static u64 MSABI h_gravity(Ctx *c) {
    u32 mode = (u32)c->r9;
    if (mode && !(mode & 0x2000) && hop_hit((u8*)c->rcx) && g_hop_live && *(const u8**)((u8*)c->rcx + 0x5b8) == g_hop_live) {           /* a hop: plain gravity, nothing holds it up */
        u8 *pl = (u8*)c->rcx;
        float g = *(float*)(pl + 0x32c) * c_hop_grav, never = 1.0e9f;
        memcpy(c->xmm[0], &g, 4);                                       /* written to pl+0x508 at 21cb7d */
        memcpy(c->xmm[4], &never, 4);                                     /* frMoveEnd: never reached, the rise is not cut */
        c->rax &= ~(u64)0x800000;                                       /* no no-sink clamp */
        return (u64)(g_base + 0x21c89a);
    }
    if (c_air && mode && !(mode & 0x2000) && (c->rax & 0x800000) && g_fall == (u8*)c->rcx) {
        static u8 *last_rec;                                     /* (debug: one line per action) */
        u8 *pl = (u8*)c->rcx;
        if (g_debug && *(u8**)(pl + 0x5b8) != last_rec) { last_rec = *(u8**)(pl + 0x5b8); LOG("speed: falling out of command %x at frame %.1f", *(u16*)(pl + 0x312), frame_of(pl)); }
        c->rax &= ~(u64)0x800000;
    }
    return (u64)(g_base + (mode ? 0x21c87a : 0x21c892));
}
/* 2633ff in the fall state: "fall loop frame >= 6 ?" (rdi = player); before that vy is held.  The same hold makes
   the top of every jump hang for 6 animation frames (0.2 s): gone unless JumpHang = 1 (KH2's jumps do not hang). */
static u64 MSABI h_hover(Ctx *c) {
    u16 prev = *(u16*)((u8*)c->rdi + 0x308);
    if (!c_jump_hang) return (u64)(g_base + 0x26329c);
    return c_air && prev >= 0x10 && prev <= 0x14 ? (u64)(g_base + 0x26329c) : 0;
}

/* ---- launcher ---- */
/* 223b0d in 2239b0, where the conditions of the combo tables are built (ecx = bits so far, rbx = player, r13 = 1 in the
   air, pl+0x608 = the target entity): bit 1 (2) = "target above" - the game sets it for a target joint above the
   player's feet + 0.2 / 0.3 / 0.4 (pl+0x618 > 0) within 3.5; on the ground it picks the rising attack.
   KH2 (00battle ptya, Sora's set, entry "id 0": motion 182, flags 0xa; checked in 1404027f0): the rising attack needs
   the bottom of the target's volume 110 .. 250 + jump height (185) cm above Sora's feet and at most 260 cm from Sora
   to the target's surface; ordinary ground hits take targets whose volume reaches into 20 .. 110 cm.  Here, on the
   ground: bit 1 = LaunchMin <= (target's position - player's position, both feet / origin, phys+0x34) <= LaunchMax
   and (horizontal distance - target radius phys+0x190) <= LaunchReach.  In the air the game's bit is kept. */
static u64 MSABI h_launch(Ctx *c) {
    u8 *pl = (u8*)c->rbx;
    if (!c_launch || (u32)c->r13) return 0;
    u8 *tg = *(u8**)(pl + 0x608), *tp = tg ? *(u8**)(tg + 0x80) : NULL, *pp = *(u8**)(pl + 0x80);
    int was = (c->rcx & 2) != 0, now = 0;
    float h = 0.0f, d = 0.0f;
    if (tp && pp && *(int*)(pl + 0x600) > 0) {
        h = *(float*)(tp + 0x34) - *(float*)(pp + 0x34);
        float dx = *(float*)(tp + 0x30) - *(float*)(pp + 0x30), dz = *(float*)(tp + 0x38) - *(float*)(pp + 0x38);
        float r = *(float*)(tp + 0x190);
        if (!(r > 0.0f)) r = 0.0f;
        if (r > 1.5f) r = 1.5f;
        d = sqrtf(dx * dx + dz * dz) - r;
        now = h >= c_launch_min && h <= c_launch_max && d <= c_launch_reach;
    }
    if (now) c->rcx |= 2; else c->rcx &= ~(u64)2;
    if ((g_debug || c_airlog) && (was != now || now)) LOG("launch: target %.2f above, %.2f from its edge: %s%s", h, d, now ? "rising attack" : "ground combo",
                                                          was == now ? "" : was ? " (the game would rise)" : " (the game would not)");
    return 0;
}

/* ---- speed ---- */
static float g_mine;                    /* the factor this module has put into pl+0x1a8 (0 = none) */
static float *g_lunge_div;              /* divisor of the lunge speed, 60 / factor */
static float wanted(u8 *pl) {
    float o = cmd_override(pl);
    if (o > 0.0f) return o;
    if (c_big > 0.0f && *(u32*)(pl + 0x5e0) && big_spell(*(u16*)(pl + 0x312))) return c_big;
    switch (*(u16*)(pl + 0x304)) {
    case 0x10: case 0x12: case 0x13: return c_actions;
    case 0x14: return *(u32*)(pl + 0x5e0) == 7 ? c_actions : 1.0f;
    case 0x11: {
        if (*(s16*)(pl + 0x310) == 4) return c_actions;          /* recovery */
        const u8 *rec = *(u8**)(pl + 0x5b8);
        int f = family(*(u16*)(pl + 0x312));
        float rel = f == F_FIRE ? c_rel_fire : f == F_BLIZZARD ? c_rel_blizzard : f == F_THUNDER ? c_rel_thunder : f == F_CURE ? c_rel_cure : -1.0f;
        if (rel < 0.0f || !rec) return c_actions;                /* no KH2 counterpart */
        if (rel == 0.0f || !rec[0x14]) return 1.0f;
        float k = rec[0x14] / 30.0f / rel;                       /* t1 is in frames of 1/30 s */
        return k < 1.0f ? 1.0f : k > c_cast_max ? c_cast_max : k;
    }
    }
    return 1.0f;
}
static void put(u8 *pl, float f) {       /* what the game's setter 21de30 does */
    *(float*)(pl + 0x1a8) = f;
    u8 *w = *(u8**)(pl + 0x378); if (w) *(float*)(w + 0x1a8) = f;
    w = *(u8**)(pl + 0x380);     if (w) *(float*)(w + 0x1a8) = f;
}
static float distinct(float f) { return f == 0.5f || f == 1.2f || f == 2.0f ? f + 0.002f : f; }   /* the game's own values */
static void speed_frame(u8 *pl) {
    float cur = *(float*)(pl + 0x1a8);
    if (g_mine != 0.0f && cur != g_mine) g_mine = 0.0f;          /* the game has set its own value meanwhile */
    float f = distinct(wanted(pl));
    if (f != 1.0f && (cur == 1.0f || g_mine != 0.0f)) {
        if (g_debug && f != g_mine) LOG("speed: x%.2f (state %x, command %x, part %d)", f, *(u16*)(pl + 0x304), *(u16*)(pl + 0x312), *(s16*)(pl + 0x310));
        put(pl, f); g_mine = f;
    }
    else if (f == 1.0f && g_mine != 0.0f) { put(pl, 1.0f); g_mine = 0.0f; }
    if (g_lunge_div) *g_lunge_div = 60.0f / (g_mine != 0.0f ? g_mine : 1.0f);
}
/* 220b1d: call 23b3a0 (status effects) in the player update, after this frame's state function and before the
   animation step */
/* ---- air hops: the start of each hop ---- */
static const u8 *g_hop_rec; static float g_hop_fr; static int g_hop_n;
static void hop_frame(u8 *pl) {
    if (pl != local_player()) return;
    if (!hop_hit(pl)) {
        if (*(u16*)(pl + 0x304) != 0x10) g_hop_n = 0;                   /* out of the attack: the next air hit is a first */
        g_hop_rec = NULL; g_hop_live = NULL; return;
    }
    const u8 *rec = *(u8**)(pl + 0x5b8);
    float fr = frame_of(pl);
    int fresh = rec != g_hop_rec || fr + 0.5f < g_hop_fr;
    /* The game also plays air-combo records from the ground (an enemy a little above): they must not lift the player.
       The game itself gives them no rise there (229fa0 asks 264a10, "in the air", first); only hits that start in
       the air hop.  "In the air" here: pl+0x318 bit 22, set by the player's update when it ended airborne
       [220550 tail] - 264a10 itself is not called, it can play a landing effect (292350). */
    if (fresh && !(*(u32*)(pl + 0x318) & 0x400000)) { g_hop_live = NULL; g_hop_rec = rec; g_hop_fr = fr; return; }
    if (fresh) {                                                        /* a hit has started in the air */
        g_hop_live = rec;
        float g = -*(float*)(pl + 0x32c) * c_hop_grav, sp = *(float*)(pl + 0x1a8);
        if (!(sp > 0.05f)) sp = 1.0f;
        float v;
        if (is_finisher(rec)) v = c_hop_fin * *(float*)(pl + 0x330) * 27.6f;    /* x the jump speed (PPM+0x0c x u) */
        else {
            int next = rec[0x0d] ? rec[0x0d] : rec[0x0c];               /* frChangeEnable: the next hit can start */
            float t = (float)next * 2.0f / sp;                          /* in ticks */
            if (t < 8.0f) t = 8.0f;
            if (t > 80.0f) t = 80.0f;
            v = c_hop_keep * g * t * 0.5f * (g_hop_n == 0 ? c_hop_first : 1.0f);
        }
        float dy = *(int*)(pl + 0x600) > 0 ? *(float*)(pl + 0x618) : 0.0f;
        if (c_reach && dy >= c_reach_min) {                             /* the target is well above: rise to it */
            if (dy > c_reach_max) dy = c_reach_max;
            float vr = sqrtf(2.0f * g * dy), jump = *(float*)(pl + 0x330) * 27.6f;
            if (vr > jump) vr = jump;
            if (vr > v) { v = vr; if (g_debug || c_airlog) LOG("air: rising to a target %.2f above", dy); }
        }
        if (v < 0.0f) v = 0.0f;
        *(float*)(pl + 0x50c) = v; *(float*)(pl + 0x510) = v;
        *(float*)(pl + 0x508) = *(float*)(pl + 0x32c) * c_hop_grav;
        if (g_debug || c_airlog) LOG("air: hop %d, record %d, vy %.4f", g_hop_n, (int)patk_index(rec), v);
        g_hop_n++;
    }
    g_hop_rec = rec; g_hop_fr = fr;
}
/* ---- air log ---- */
static int g_air_on; static float g_air_t, g_air_y, g_air_top;
static void air_log(u8 *pl) {
    if (!c_airlog || pl != local_player()) return;
    int up = (*(u32*)(pl + 0x318) & 0x400000) != 0;
    float dt = *(float*)(pl + 0x20); if (!(dt > 0.0f) || dt > 6.0f) dt = 1.0f;
    if (!up) {
        if (g_air_on) LOG("air: landed after %.2f s, top %.2f above the take-off, end %.2f", g_air_t / 60.0f, g_air_top, g_air_y);
        g_air_on = 0; return;
    }
    if (!g_air_on) { g_air_on = 1; g_air_t = 0; g_air_y = 0; g_air_top = 0; LOG("air: take-off, state %x", *(u16*)(pl + 0x304)); }
    float vy = *(float*)(pl + 0x50c);
    g_air_t += dt; g_air_y += vy * dt; if (g_air_y > g_air_top) g_air_top = g_air_y;
    const u8 *rec = *(u8**)(pl + 0x5b8);
    LOG("air: t %5.1f  state %2x part %d  rec %4d  frame %5.1f  vy %+.4f  y %+.3f  g %.5f%s", g_air_t, *(u16*)(pl + 0x304), *(s16*)(pl + 0x310),
        rec ? (int)patk_index(rec) : -1, frame_of(pl), vy, g_air_y, *(float*)(pl + 0x508), (*(u32*)(pl + 0x318) & 0x800000) ? " aerial" : "");
}
/* ---- long-action log (debug only): an action of the player's (states 0x10..0x14) that runs over 2 s gets a line
   every 10 ticks - what it is, where its animation is, its speed and flags - and one when it ends.  For the report
   "stuck in an attack, no buttons work" (No Heart, 2026-10-19). */
static float g_act_t, g_act_next, g_act_lastfr; static u32 g_act_st; static u16 g_act_cmd; static const u8 *g_act_rec;
static int g_act_logged, g_act_still;
static void long_action_log(u8 *pl) {
    if (!g_debug || pl != local_player()) return;
    u32 st = *(u16*)(pl + 0x304);
    float dt = *(float*)(pl + 0x20); if (!(dt >= 0.0f) || dt > 6.0f) dt = 1.0f;
    if (st < 0x10 || st > 0x14) {
        if (g_act_logged) LOG("long action: over after %.1f s (state now %x)", g_act_t / 60.0f, st);
        g_act_t = 0; g_act_logged = 0; g_act_st = 0; return;
    }
    u16 cmd = *(u16*)(pl + 0x312);
    if (st != g_act_st || cmd != g_act_cmd) {
        if (g_act_logged) LOG("long action: state %x command %x over after %.1f s, now state %x command %x", g_act_st, g_act_cmd, g_act_t / 60.0f, st, cmd);
        g_act_st = st; g_act_cmd = cmd; g_act_t = 0; g_act_next = 120; g_act_logged = 0; g_act_still = 0; g_act_rec = NULL;
    }
    g_act_t += dt;
    float fr = frame_of(pl);
    const u8 *rec = *(u8**)(pl + 0x5b8);
    if (g_act_t < g_act_next) return;
    g_act_next = g_act_t + 10;
    g_act_still = (fr == g_act_lastfr && rec == g_act_rec) ? g_act_still + 1 : 0;
    g_act_lastfr = fr; g_act_rec = rec;
    u8 *mot = *(u8**)(pl + 0x78);
    LOG("long action: %.1f s  state %x part %d/%d command %x rec %d  frame %.1f%s  mot flags %x  speed %.2f (ours %.2f)  dt %.2f  "
        "318 %x 31c %x 320 %x  vy %+.4f g %.5f  air %d  buttons %x",
        g_act_t / 60.0f, st, *(s16*)(pl + 0x310), *(s16*)(pl + 0x314), cmd, rec ? (int)patk_index(rec) : -1, fr,
        g_act_still ? " (not moving)" : "", mot ? *(u32*)(mot + 8) : 0, *(float*)(pl + 0x1a8), g_mine, dt,
        *(u32*)(pl + 0x318), *(u32*)(pl + 0x31c), *(u32*)(pl + 0x320), *(float*)(pl + 0x50c), *(float*)(pl + 0x508),
        (*(u32*)(pl + 0x318) & 0x400000) != 0, G(u32, 0x8f65030) & 0xf0ff);
    g_act_logged = 1;
}
/* ---- frame-gap log (debug only): the time between two updates of the local player, from the clock.  A gap over
   150 ms is logged with the player's state (a pause shows as one big gap; a slowed game as many); a run of slow
   frames once a second with their count.  Also our own per-frame work here, when it takes over 20 ms. */
static DWORD g_fg_last, g_fg_slow_since, g_fg_slow_n;
static void frame_gap_log(u8 *pl, DWORD t0) {
    if (!g_debug || pl != local_player()) return;
    DWORD gap = g_fg_last ? t0 - g_fg_last : 0;
    g_fg_last = t0;
    if (gap > 150) {
        u8 *mot = *(u8**)(pl + 0x78);
        LOG("frame gap: %lu ms  state %x part %d/%d command %x  frame %.1f speed %.2f dt %.2f  318 %x  mot flags %x  buttons %x",
            (unsigned long)gap, *(u16*)(pl + 0x304), *(s16*)(pl + 0x310), *(s16*)(pl + 0x314), *(u16*)(pl + 0x312),
            frame_of(pl), *(float*)(pl + 0x1a8), *(float*)(pl + 0x20), *(u32*)(pl + 0x318), mot ? *(u32*)(mot + 8) : 0,
            G(u32, 0x8f65030) & 0xf0ff);
    }
    if (gap > 40) {
        if (!g_fg_slow_since) g_fg_slow_since = t0;
        g_fg_slow_n++;
        if (t0 - g_fg_slow_since >= 1000) {
            LOG("slow frames: %lu over 40 ms in the last %lu ms (state %x command %x)", (unsigned long)g_fg_slow_n,
                (unsigned long)(t0 - g_fg_slow_since), *(u16*)(pl + 0x304), *(u16*)(pl + 0x312));
            g_fg_slow_since = t0; g_fg_slow_n = 0;
        }
    } else if (g_fg_slow_since && t0 - g_fg_slow_since > 2000) { g_fg_slow_since = 0; g_fg_slow_n = 0; }
}
/* ---- Terra's Air Slide: a cooldown before the next one (2026-10-26, asked for) ----
   With its end frame cut to 12 (patches.json) Terra could chain Air Slides back to back.  Every MOVE command starts
   in 2430c0 (rcx = player, the command already queued in pl+0x34c), whichever of its callers took the press: the
   air state [218e09], the input dispatcher 2176b0 [21782d], an action's command window 21c140 [21c219], a slide
   chaining [242c9d].  Entering it for Air Slide (0xff) less than AirSlideCooldown seconds after Terra's last Air
   Slide ended does not start it: the press does nothing and the player stays as he is.  Terra's is told by its
   record (PAtk 667: flag AERIAL only, animations 50 then 9 - Ventus' and Aqua's have NEXT and 50 then 51), so
   the others are not affected.  The time runs on the player's own dt (60 Hz ticks). */
static float c_as_cool = 0.25f;                 /* seconds; 0 = off */
static double g_as_clock, g_as_end = -1e9;
static int g_as_on;
static u64 (MSABI *o_move_start)(u8 *pl, u64 a);
static int terra_air_slide(const u8 *pl) {
    if (*(const u16*)(pl + 0x304) != 0x15 || *(const u16*)(pl + 0x312) != 0xff) return 0;
    const u8 *rec = *(u8* const*)(pl + 0x5b8);
    return rec && *(const u16*)(rec + 4) == 0x0002 && rec[8] == 50 && rec[9] == 9;
}
static void air_slide_frame(u8 *pl) {
    float dt = *(float*)(pl + 0x20); if (!(dt >= 0.0f) || dt > 6.0f) dt = 1.0f;
    g_as_clock += dt;
    int now = terra_air_slide(pl);
    if (g_as_on && !now) g_as_end = g_as_clock;
    g_as_on = now;
}
static int air_slide_blocked(u8 *pl) {
    return c_as_cool > 0.0f && pl && pl == local_player() && *(u16*)(pl + 0x34c) == 0xff && !g_as_on
           && g_as_clock - g_as_end < c_as_cool * 60.0f;
}
static u64 MSABI move_start_hook(u8 *pl, u64 a) {
    if (air_slide_blocked(pl)) {
        if (g_debug) LOG("speed: Air Slide %.0f ticks after the last one: not yet", g_as_clock - g_as_end);
        return 0;
    }
    return o_move_start(pl, a);
}

static void MSABI tick_hook(u8 *pl) {
    DWORD t0 = g_debug ? GetTickCount() : 0;
    frame_gap_log(pl, t0);
    long_action_log(pl);
    if (c_on) cc_after(pl);
    if (pl == local_player()) { g_tick++; air_slide_frame(pl); }
    if (c_on) speed_frame(pl);
    if (c_on) { hop_frame(pl); air_log(pl); }
    g_fall = NULL;
    if (g_debug && pl == local_player()) {
        DWORD own = GetTickCount() - t0;
        if (own > 20) LOG("frame gap: our per-frame work took %lu ms", (unsigned long)own);
    }
    FN(void, 0x23b0c0, u8*)(pl);
}

/* ---- install ---- */
static float ini_f(const char *key, float def) {
    char b[64], d[64];
    snprintf(d, sizeof d, "%g", def);
    GetPrivateProfileStringA("Speed", key, d, b, sizeof b, g_ini);
    return (float)atof(b);
}
int speed_enabled(void) { return c_on; }
static const Steal *const sites[] = { &S_atk_end, &S_mag_anim, &S_mag_lock, &S_deck_a, &S_deck_b, &S_deck_c, &S_item_end,
                                      &S_friend_end, &S_fin_end, &S_fall_hover, &S_gravity, &S_launch };
int speed_check(void) {
    c_on = (int)ini_f("Enabled", 1);
    cc_config();
    c_walk = (int)ini_f("WalkOut", 1); c_air = (int)ini_f("AirWeight", 1); c_lunge = (int)ini_f("LungeFix", 1);
    c_actions = ini_f("Actions", c_actions); c_margin = ini_f("FollowThrough", c_margin); c_airlock = ini_f("AirLock", c_airlock);
    c_rel_fire = ini_f("FireRelease", c_rel_fire); c_rel_blizzard = ini_f("BlizzardRelease", c_rel_blizzard);
    c_rel_thunder = ini_f("ThunderRelease", c_rel_thunder); c_rel_cure = ini_f("CureRelease", c_rel_cure);
    c_free_fire = ini_f("FireFree", c_free_fire); c_free_blizzard = ini_f("BlizzardFree", c_free_blizzard);
    c_free_thunder = ini_f("ThunderFree", c_free_thunder);
    c_big = ini_f("BigSpells", c_big);
    if (c_big != 0.0f && c_big < 0.5f) c_big = 0.5f;
    if (c_big > 2.0f) c_big = 2.0f;
    c_jump_hang = (int)ini_f("JumpHang", (float)c_jump_hang);
    c_hop = (int)ini_f("AirHop", (float)c_hop);
    c_reach = (int)ini_f("AirReach", (float)c_reach);
    c_launch = (int)ini_f("LaunchHeight", (float)c_launch);
    c_launch_min = ini_f("LaunchMin", c_launch_min); c_launch_max = ini_f("LaunchMax", c_launch_max);
    c_launch_reach = ini_f("LaunchReach", c_launch_reach);
    c_reach_min = ini_f("AirReachMin", c_reach_min); c_reach_max = ini_f("AirReachMax", c_reach_max); c_airlog = (int)ini_f("AirLog", (float)c_airlog);
    c_as_cool = ini_f("AirSlideCooldown", c_as_cool); if (c_as_cool < 0.0f) c_as_cool = 0.0f; if (c_as_cool > 5.0f) c_as_cool = 5.0f;
    c_hop_keep = ini_f("AirHopKeep", c_hop_keep); c_hop_first = ini_f("AirHopFirst", c_hop_first);
    c_hop_fin = ini_f("AirHopFinisher", c_hop_fin); c_hop_grav = ini_f("AirHopGravity", c_hop_grav);
    if (c_hop_grav < 0.1f) c_hop_grav = 0.1f;
    if (c_hop_grav > 3.0f) c_hop_grav = 3.0f;
    int listed = 0;
    for (int id = 1; id < CMD_IDS; id++) {
        char key[8], b[32]; snprintf(key, sizeof key, "%x", id); b[0] = 0;
        GetPrivateProfileStringA("CommandSpeed", key, "", b, sizeof b, g_ini);
        float v = b[0] ? (float)atof(b) : 0.0f;
        if (v > 0.0f && v < 0.25f) v = 0.25f;
        if (v > 4.0f) v = 4.0f;
        g_cmd_speed[id] = v > 0.0f ? v : 0.0f;
        if (g_cmd_speed[id] > 0.0f) listed++;
    }
    if (listed) LOG("speed: %d commands with a speed of their own", listed);
    if (c_actions < 0.5f) c_actions = 0.5f;
    if (c_actions > 2.0f) c_actions = 2.0f;
    if (c_airlock < 0.0f) c_airlock = 0.0f;
    if (!c_on) return 1;
    int bad = 0;
    for (unsigned i = 0; i < sizeof sites / sizeof *sites; i++) {
        const Steal *s = sites[i];
        if (memcmp(g_base + s->rva, s->bytes, s->nfix ? s->fix[0] : s->len) == 0) continue;
        if (bundle_combo_in_exe() && (s == &S_atk_end || s == &S_mag_anim || s == &S_mag_lock)) continue;   /* put back in speed_apply */
        LOG("speed: site %x does not match", s->rva); bad++;
    }
    u8 *p = g_base + 0x22083d; s32 d; memcpy(&d, p + 1, 4);
    if (p[0] != 0xE8 || (u32)(0x22083d + 5 + d) != 0x23b0c0) { LOG("speed: call site 220b1d does not match"); bad++; }
    if (G(u32, 0x263d9b) != 0x41f00000) { LOG("speed: 26407b does not match"); bad++; }
    p = g_base + 0x220418; memcpy(&d, p + 1, 4);
    if (c_cc && (p[0] != 0xE8 || (u32)(0x220418 + 5 + d) != 0x21f710)) { LOG("speed: call site 2206f8 does not match"); bad++; }
    if (c_as_cool > 0.0f && memcmp(g_base + S_move_start.rva, S_move_start.bytes, S_move_start.len)) { LOG("speed: site %x does not match", S_move_start.rva); bad++; }
    static const u8 lunge[] = { 0x41, 0x0f, 0x28, 0xf2, 0xf3, 0x0f, 0x5e, 0x35 };
    if (memcmp(g_base + 0x21cc6e, lunge, sizeof lunge)) { LOG("speed: 21cf4e does not match"); bad++; }
    return bad == 0;
}
void speed_apply(void) {
    if (!c_on) { LOG("speed: off"); return; }
    bundle_restore_sites();                                      /* the old Combo Flow exe patch sits on three of the sites */
    hook_ctx(&S_atk_end, h_attack, "attack end");
    hook_ctx(&S_deck_a, h_deck, "deck attack end");
    hook_ctx(&S_deck_b, h_deck, "deck attack end 2");
    hook_ctx(&S_deck_c, h_dash, "dash attack end");
    hook_ctx(&S_item_end, h_item, "item end");
    hook_ctx(&S_friend_end, h_friend, "friend command end");
    hook_ctx(&S_fin_end, h_finish, "finisher end");
    hook_ctx(&S_mag_anim, h_mag_anim, "magic animation end");
    hook_ctx(&S_mag_lock, h_mag_lock, "magic lock");
    hook_ctx(&S_gravity, h_gravity, "air gravity");
    hook_ctx(&S_fall_hover, h_hover, "fall hover");
    if (c_launch) hook_ctx(&S_launch, h_launch, "launch height");
    hook_call(0x22083d, 0x23b0c0, tick_hook, "player tick");
    if (c_as_cool > 0.0f) o_move_start = hook_fn(&S_move_start, move_start_hook, "move command start (Air Slide cooldown)");
    g_cc_end = (void (MSABI *)(u8*, int, int))(g_base + 0x21c230);
    if (c_cc) hook_call(0x220418, 0x21f710, input_hook, "player input (command cancel)");
    if (c_air && c_airlock != 30.0f) { u32 v; memcpy(&v, &c_airlock, 4); patch_u32(0x263d9b, 0x41f00000, v, "air lock"); }
    if (c_lunge) {
        g_lunge_div = near_alloc(4);
        if (g_lunge_div) { *g_lunge_div = 60.0f; patch_riprel(0x21cc76, 0, 0x6ec4a4, g_lunge_div, "lunge speed"); }
    }
    LOG("speed: actions x%.2f, walk-out %d, air %d (lock %.0f), release fire %.2f blizzard %.2f thunder %.2f cure %.2f, big spells x%.2f, command cancel %d (buffer %.0f)",
        c_actions, c_walk, c_air, c_airlock, c_rel_fire, c_rel_blizzard, c_rel_thunder, c_rel_cure, c_big, c_cc, c_cc_buf);
}

#ifndef _WIN32      /* offline test access */
float test_speed_wanted(u8 *pl) { return wanted(pl); }
void  test_cc_after(u8 *pl) { cc_after(pl); }
void  test_cc_before(u8 *pl) { cc_before(pl); }
void  test_cc_seen(u8 *pl, int magic) { cc_seen(pl, magic ? K_MAGIC : K_DECK); }
void  test_cc_tick(void) { g_tick++; }
void  test_as_frame(u8 *pl) { air_slide_frame(pl); }
u64   test_move_start(u8 *pl, u64 (MSABI *orig)(u8*, u64)) { o_move_start = orig; return move_start_hook(pl, 0); }
float *test_as_cool(void) { return &c_as_cool; }
void  test_as_reset(void) { g_as_clock = 0; g_as_end = -1e9; g_as_on = 0; }
int   test_cc_state(void) { return g_cc.state; }
u32   test_cc_stash(void) { return g_cc.stash; }
void  test_cc_reset(void) { memset(&g_cc, 0, sizeof g_cc); g_cc.seen = (unsigned)-1; }
float *test_cc_off(void) { return g_cc_off; }
int   *test_cc_on(void) { return &c_cc; }
void  test_cc_end(void (MSABI *f)(u8*, int, int)) { g_cc_end = f; }
void  test_cc_config(void) { cc_config(); }
float *test_cmd_speed(void) { return g_cmd_speed; }
void  test_hop_frame(u8 *pl) { hop_frame(pl); }
int   test_hop_hit(u8 *pl) { return hop_hit(pl); }
int   *test_hop_on(void) { return &c_hop; }
int   *test_jump_hang(void) { return &c_jump_hang; }
float *test_hop_keep(void) { return &c_hop_keep; }
int   *test_reach_on(void) { return &c_reach; }
int   *test_launch_on(void) { return &c_launch; }
u64   test_h_launch(Ctx *c) { return h_launch(c); }
const u8 **test_hop_live(void) { return &g_hop_live; }
void  test_speed_frame(u8 *pl) { speed_frame(pl); }
float test_done_frame(u8 *pl, const u8 *rec, int kind) { return done_frame(pl, rec, kind); }
int   test_leave(u8 *pl, int kind) { return leave(pl, kind); }
u8   *test_fall(void) { return g_fall; }
void  test_fall_clear(void) { g_fall = NULL; }
u64   test_h_gravity(Ctx *c) { return h_gravity(c); }
u64   test_h_mag_lock(Ctx *c) { return h_mag_lock(c); }
u64   test_h_mag_anim(Ctx *c) { return h_mag_anim(c); }
u64   test_h_hover(Ctx *c) { return h_hover(c); }
float test_lunge_div(void) { return g_lunge_div ? *g_lunge_div : 0.0f; }
#endif
