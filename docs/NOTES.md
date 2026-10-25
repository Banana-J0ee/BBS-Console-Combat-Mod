# BBS KH2-style mod: working notes

Target: KINGDOM HEARTS Birth by Sleep FINAL MIX.exe, Steam (HD 1.5+2.5), sha256 375a8112... (unmodified) or
874bc1f2... (with the Combo Flow exe patch).  Image base 0x140000000; all addresses below are offsets from it.

Delivery: `dbghelp.dll` next to the exe (the exe imports dbghelp!MiniDumpWriteDump; every export of the system
DLL is forwarded lazily, see tools/genproxy.py).  The DLL does nothing in the other games of the collection.
Files: bbskh2.ini (settings), bbskh2_log.txt (log), bbskh2_off.txt (present = mod off),
bbskh2_debug.txt (present = debug channel: commands written to bbskh2_cmd.txt are answered in the log).

Reference notes (static analysis): l2d_api.md (2D layout runtime), player_gauge.md (HUD gauge object),
player_command.md (command deck, plates, input, styles, D-Link).

## Piece 1: MP instead of reloads (src/mp.c)
- 233d40 call 2063c0 (use the selected deck plate) -> use_hook: refuse while in MP burn, charge MP on success.
- 206a6e call 1ce550 (reload gain per frame) -> reload_hook: 100 (ready at once), or the recharge progress
  while in burn so every plate's own bar shows it.
- plates_block: while in burn, idle non-item plates get flag 0x2 + refresh 2060d0.
- cmd+0x60 |= 2 each frame: no cursor advance / auto-skip after a use (ini CursorAdvance).
- 2388a0 / 205ee0: no new D-Link while in burn.  2624e0: items that restore Focus restore MP.  285780: reset.
- Per-frame work runs from the player gauge's update (209f20), which also drives the bar.
- Max MP = baseline + 10 per deck slot the character has (PlayerData +0x36).  Baseline 60, or 20 on Critical
  (difficulty byte 150fa0881 == 3; ini Baseline / BaselineCritical): 90..140, on Critical 50..100.
- MP bar: one instance of sequence 0x12d of "gauge_01:0" (the Focus fill); its fill sprite (object 3) and
  mask (object 2) are cloned per instance (1a7be0) and rewritten every frame (1a6350): mask emptied, quads
  0..3 = black frame, empty part, fill (kept at the right end, as in KH2), "MP" plate.
- Place and size (`[Bar] Right`, `Top`, `Height`, `BarLength`): right end of the plate's solid part at x 425, top at
  y 254.6, 4.5 high, 57.6 long at 100 MP (the plate adds 2.6 x height = 11.7; 69.5 in all, the first bar's length,
  so the left end is at x 355.9 as before).  The Focus bar's outline ends at about
  y 253.9 (measured on a 1440p screenshot), so the bar hangs 0.7 under it.  The first size was top 255.5, height
  7.5, length 50; the tests' quad numbers are still for that size (test_bar_geom).
- **Pixel grid** (`[Bar] ExactSize`, default on).  CD2SeqCtrl::Draw (1401aaea0) hands every object's draw
  (CD2Obj vtable slot 1, 1401a87b0) a "scaled" flag, and 140526100 picks the quad builder by it: unscaled ->
  14052c550, which moves every corner to a whole unit of the 480 x 272 screen (`ceil(x - 0.5)`, texture position
  corrected, texel-centre rounding) as the PS2 drew sprites, filter mode 3; scaled -> 14052cbc0, corners and
  texture rectangle as given, mode 4.  A stand-alone sequence is "scaled" when its root record has keyn[8] ==
  keyn[9] == 1 and the first two keys of the root object's key table have t == 0 and a value != 1.0 (a layout
  node: the same test on the top parent, 1401aad80) - the "0.88" roots of the command plates.  The scale set
  with 1401a7730 does not count.  The bar's sequence (root record without keys) was therefore drawn on the grid:
  7.5 high with 0.75 borders became 8 with borders of 1, and textured pieces (plate, round end) sat up to half a
  unit away from the plain rectangles.  mp.c root_scale gives the instance's root object a record of its own
  (the game's + one scaleX and one scaleY key) on a two-key table of its own, every frame, and leaves 1401a7730
  at 1; the Command Style timer bar gets the same.  Test `t_draw` runs the game's draw code with the renderer
  stubbed and reads the vertices: on the grid without it, exact with it.
- Round left end (`[Bar] RoundEnd`, default on): all seven quads of that sprite are used - 0 frame's round end
  (8 art pixels), 1 frame's straight part, 2 / 3 the same for the empty inside (round end 6 pixels, from x 2), 4 the
  part of the fill that reaches into the round end, 5 the straight fill, 6 the plate.  The round pieces are drawn
  by tools/genmpart.py (a rounded rectangle's left end, radius 5 for the frame and 3 for the inside, in black,
  blue gradient and grey gradient, with 2 units of margin) into the second row of the art block, which is now
  192x108 pixels (texel units 104,184 + 96x54).  Texture positions are whole units = art pixels, so inside the
  round end the fill's edge moves by whole art pixels.
- The bar's art is KH2's own (the "MP" plate and gradients of field2d/us/zz0field.2dd, texture 1).  src/tex.c
  copies it into an unused area of the gauge sheet (texture 2 of p00common.arc, 1024x512; area 208,368 +
  192x108 = texel units 104,184 of the 512x256 sheet) when the game creates the texture: hook on the call
  4e1ee4 -> 4e1630 (pixels from libpng, BGRA).  The sheet is recognised by 24 check pixels; if it is not, the
  bar falls back to a plain one made from the Focus bar's cross-section (uv x 140, y 70..112).
  tools/genmpart.py builds src/mpart_gen.h from the two PNGs.  Before a public release: the header holds a
  small piece of KH2's texture; read it from the user's own KH2 files instead, or ask.
- The confirm-button icon on the plate under the cursor is a text node (node 0x5d of the deck plate layout,
  node 1 of the D-Link plate layout, default string "\xf5g"); the menu keeps it empty.
- Offline test: test/run.sh (plates on the real game code with the L2D calls stubbed; the bar on the real L2D
  runtime with BBS_GAUGE_L2D=<gauge_01.l2d extracted from arc/pc/p00common.arc>).

## Command Style offer (src/style.c)
- Hook on the compare at 2368f2 (cmd update, gauge full, level < 2): with a style candidate (+0x190 != 0x151) the game
  is held there (jump to 236b49 with +0x64 bit 0x100 left set) while a prompt with a timer is up; the old deck button
  (pad test 272c20) lets the game's own change run, timer out jumps to the finisher branch 236a82.
- Prompt = bc01_00 layout 7 with seq 0x197 on node 0x5a (control 0 steady, 4 flash), name on node 0, button icon =
  text of node 0x5a (f5 'g' = deck button, f5 'd' = confirm).  Timer bar: hud_timer_bar in mp.c.
  Draw priority 11 (both): under the Magic / Items / D-Link lists and their headers (12, row under the cursor 13),
  which reach up to it when long - reported drawn over them at 12, where the later-made offer won the bucket - and
  over the command menu (5 / 7).
- The menu no longer draws the game's style attack plates (type 4) and finisher plate (type 3); its Attack entry
  shows the active one's name.  236c92 (extra presses of multi-press commands) also accepts the confirm button.
- Finishers are offered the same way: 236d67 (call to 233f70) runs the timer, 234115 (its confirm test) is the old
  deck button, 236d98 (jne that skips Attack while a finisher is available) is removed and the Attack plates are
  un-covered (205890 / 205910).  Timer out = 233f70's own "finisher over" branch (flag 0x4000 set, 0x8000 clear).
- test/run.sh t_style drives the real hook with landing pads on its three exits, and 233f70 for the finisher.
- **An offer that runs out does not end the style you are in (`[Style] KeepStyle`).**  Reported: in a style, the
  next style / finisher comes up, you leave it alone, and you are back in the normal style.  Cause: the chain
  ends in 233f70's "finisher over" branch, and that branch has two ends.  With cmd+0x64 bit 0x20 (set for good in
  the constructor [22fe30]) and no D-Link / illusion (0x400080) it reverts: `2371d0(cmd, 0)`, next = 0x151,
  `237f20(cmd, 4)`.  Otherwise it keeps the level: `2371d0(cmd, level)`, which only clamps the gauge to
  level x 100 - the value a style begins with - and readies the style's plate.  Both then clear the affinity
  counters, the candidate and the "full" flag.  For a finisher that was only offered, at level 1 or 2, the mod
  takes bit 0x20 away for that one call and puts it back, so the game's own keep-the-level end runs.  A finisher
  that is used still ends the style, and in the normal style an offer that runs out still empties the gauge.
  Test in `t_style`, both ends on the game's function (KeepStyle = 0 reproduces the report).  Not seen in the game
  by me.

## Later pieces (not built yet)
- Attack / Magic / Items / D-Link menu (entry names: `[Menu] MagicText`, `ItemText`, `LinkText`); split deck editor (CCampDeck* classes); link list like KH2 summons.
- Style change as an optional prompt: patch point 2368f2 (see player_command.md section 8).

## Bundled earlier mods (src/bundle.c, generated src/bundle_gen.h, tools/genbundle.py)
- Combo Flow code: five byte ranges (2291bf, 26825f, 268286, routines at 62f080 and 631290) written in memory;
  skipped if the old exe patch is present.  Only used with `[Speed] Enabled=0`: speed.c has the walk-out now and
  hooks the same three places (an installed old exe patch is taken out of them in memory first).  Its PAtkData.bin bytes and the KH2 Camera files are set in place
  when the resource object is created: CRsrcData::vftable[1] at 637b10 (was a bare ret, 114bc0).
- Revenge Value: the call to luaL_loadbuffer at 2c5962 swaps the 638-byte original Factory.lub for our build
  (bundle_src/Factory_revenge.lub, made by tools/genrevenge.py from bundle_src/revenge/*.lua).  Since
  2026-10-04 the copy here goes beyond the old standalone mod: Zack, Hades, Master Xehanort and No Heart were
  added (the old mod's folder is untouched).  2026-10-09, version 2: the core rules are KH2's own, verified in
  the KH2 exe and data (its atkp table holds a per-attack "revenge damage" byte, x10 fixed point, normal hit
  10; the engine sums it into the victim at +0xd48, compares against a per-boss cap at +0xd4c - default 100 -
  every update when flag +0x6c8 bit 4 is set, fires the AI event named "revenge" at the cap, and drains the
  gauge 1.0 a frame at 60 fps while the enemy is not being hit [14040e337..6b, 1403db730, 1403db440]).
  Mapped to BBS Lua: weights 1 / finisher 3 / magic 1.5 capped at 4 per cast (45-frame window) / shotlock 0.3
  / +0.5 launch; drain 0.2 per 30 fps frame after a 15-frame grace; limit re-rolled +-1 after each revenge.
  - Why Zack / Peter Pan / Hades / Maleficent could be looped: the engine calls OnDamageBefore on (nearly)
    every hit [2d5e30: skipped when the reaction controller's type at +0x14 is 4 or >= 6] but OnDamage only
    when no damage reaction is running [2d60f0: +0xac's +0x10 == 0] - the first hit of a combo.  A break-out
    that lives only in OnDamage (Zack, Hades, Maleficent) can never fire mid-combo, and Peter Pan's script
    has no break-out at all (his OnDamage returns nothing and his recovery is GotoState("Idling")).
  - The guarantee, v2: every such boss has a `counter` built from its own states (Zack: Climbhazard /
    Hakougeki / BackJump as his script rolls them; Hades: BladesCrossing / NoRiaFingernailofFire; Maleficent:
    warp or StaffAttack; Peter Pan: Attack3; Hook: Guard / Evade into JumpCutting), fired from OnDamageBefore
    at the limit and, when hits land in a state where the engine mutes the callbacks, from a watchdog in
    OnUpdate (RV.watchdog = 6 frames at the limit).  An HP watch in OnUpdate counts hits the callbacks never
    saw (1.0 each).  A break-out can arm cfg.iframes frames of EnableNoDamageReaction (Peter Pan 24, Zack /
    Hades / Hook / Maleficent 18) so the revenge cannot be stuffed - KH2 revenge actions behave so.
  - Config keys: `counter`, `armored`, `fired`, `quiet = "real"`, and new in v2: `grace` / `drain` (per-boss
    gauge decay; No Heart 120 / 0.03 for his vanilla 10 s memory), `vary`, `iframes`, `recover` (run after
    OnReturnDamage: Peter Pan goes to BeforeAttackIdling - his approach-then-attack - instead of idling),
    `haste` (scales idle times read through entity methods such as GetIdlingChangeTime; timers baked into a
    script as constants are out of reach).  `decay` (v1 hard clear) was replaced by grace / drain.
  - v2.1 (2026-10-09, after the first in-game report: Aqua's final Vanitas could still be comboed forever).
    The v2 build read every time constant as 30ths of a second; Entity.GetFrameRate is the entity dt in
    60ths [1402b8570 -> entity+0x20], so the gauge waited only 0.25 s and drained 12 a second - more than a
    real combo (a hit every 0.3 .. 0.9 s, +1 each) could build.  No boss could ever reach its limit in play;
    the offline test missed it by hitting every 3 frames.  Recalibrated: grace 60, drain 0.1 (KH2's 6 a
    second), magic window 90, watchdog 12, armour 40-48, No Heart 120 / 0.03; the loop test now hits every
    35 frames.  The HP watch is gated to hit strings (a counted hit within 60 frames, or a second hidden
    drop within 30) so poison / burn ticks cannot build revenge.  And every remaining dice-driven boss got a
    `counter` built from its own moves, so the watchdog guarantee now covers all of them: Vanitas (all,
    Cartwheel), Remnant (DarkSplicer2 / WarpAttack2), Eraqus (Guard + Kagerou), Armor (Guard), Braig
    (Escape), Mysterious Figure (WarpMove_Counter), Experiment 221 (Flee string), the wielders and
    Terra-Xehanort (EvasionAction; his own-AI form has no such state and stays covered by pre()).
  - Build needs Lua 5.1 in the game's bytecode format: github.com/lua/lua tag v5.1.1 with LUA_NUMBER float
    (luaconf.h: number type, "%.7g" / "%f", strtof), the string length dumped and loaded as unsigned int
    (ldump.c DumpString, lundump.c LoadString, header byte 4), and lua_dump stripping when LUA_STRIP is set.
  - The engine calls callbacks through EntityManager:CallFunctionArgN (CommonLua EntityMgr.lub), a plain
    `entity[name]` lookup, and decides which callbacks exist with EntityManager:CheckFunctions after the
    factory's Create: functions the mod sets on the instance are found.  OnDamageBefore ~= 0: hit negated;
    OnDamage ~= 0: no flinch [2d5e30, 2d60f0].
  - No Heart (b85vs00) has no small-flinch animations (only 220-223, the launch set) and his OnDamage always
    returns 1: he cannot be made to stagger.  His own answer to a string of hits is a burst on a timer
    (132 + 0..180 frames after the first hit); the mod drives that timer from the revenge value instead.
  - test/revenge: the boss scripts run against a stand-in engine (which hit breaks the combo, with and
    without the mod).  v2 adds test/revenge/loop.sh: 80-hit unbroken combos (OnDamageBefore only, as the
    engine behaves mid-combo) against every configured boss, one script per process (the stand-in's globals
    are shared and scripts contaminate each other); every boss must break out repeatedly, with forced
    revenges, and never let more than 16 hits go unanswered.  b52ex00 cannot run in the stand-in (its script
    trips over uninitialised fields there); its own-AI break-out is pre()-saturated and its shared-AI form is
    covered through the wielder script.  Zack's arena / Ventus-dream modes read their CounterNum from enemy
    params at setup, which the stand-in cannot supply - another reason their own counters looked dead there.
- The old standalone mods were uninstalled from the game files on 2026-10-04 (their folders are untouched;
  their stale backup records were moved to _to_delete in the game folder).
- See resource_loading.md.

## Pace: ending lag, air weight, speed, cast times (src/speed.c)
Research notes: player_actions.md (state machine, end tests, air physics), player_speed.md (animation speed
field), cast_timing.md (KH2 vs BBS cast data; scripts in /home/claude/bbs/speed).
- An action (player states 0x10 attack, 0x11 magic, 0x12 item, 0x13 friend, 0x14 finisher) ends only when its
  animation has played out; the stick is not read.  Each state has one "animation finished?" test; hook_ctx on
  each (2291bf, 2246c0, 224476, 2253ff, 262056, 2599ab, 2562bc; magic 26825f and 26828a) returns the state's own
  "end" address when the stick is tilted and the action is done.
- "Done" is worked out at run time from the game's collision controllers (entity+0x88 of the player and of the
  weapon pl+0x378: +0x20 count, +0x28 entries of 0x90; entry +0x28 / +0x2a state 0 not yet / 1 on / 2 on to the
  end / 3 over, +0x48 description with s16 on / off at +0x24 / +0x26 and +0x30 / +0x32): all windows over, then
  max(last off + FollowThrough, frMoveEnd + 1, frMarkEnd + 1, triggers + 2).  No windows at all: frChangeEnable.
- While a press can still continue the action (normal combo hit that is not a finisher and frame < frComboEnable;
  commands 5c / 6f / 75 that are pressed again) the stick must have changed since the attack began.  Finisher
  records: list in speed.c, from the combo tables.
- Air: 21cb00 keeps an aerial action (pl+0x318 bit 23) from sinking before frMoveEnd and then uses 16 % gravity.
  The hook at 21cb55 clears the bit in the register copy once the end test of this frame said "done, nothing can
  follow" (g_fall, cleared every frame in the tick).  2633ff: the 6-frame vy hold at the start of the fall loop
  is skipped when the previous state was an action.  26407b: button lock after an aerial action 30 -> 6 ticks.
- Speed: pl+0x1a8 (and the weapons') set every frame from the call at 220b1d, only over 1.0 or our own value;
  never over the game's 0 / 0.5 / 1.2 / 2.0.  Lunge speed divisor (21cf52, was 60.0) = 60 / factor.
- Casts: wind-up factor = t1 / 30 / KH2 release time (never below 1); recovery lock per family = KH2's ticks from
  release to the combo window (Fire 38, Blizzard 20, Thunder 24; BBS has 40 for everything).  Only for the plain
  cast path (commands 83-87, 89, 8a-8c, 8e-91, 92-95).
- Not tested in the game by me; the debug channel logs every walk-out with the window count it saw.

## MP cost in the command descriptions (src/mp.c, `[Menu] DescriptionCost`)

* The camp menu's help line is node 0x65 of the camp layout (`camp+0xd0`, camp = [150fb51f0]):
  `140417710(camp, msgId, args)` -> `SetNodeMsg 1401a8170(h, 0x65, msgId, 0, mode 1, args)`,
  `140417770(camp, char*, args)` for plain strings.  A command's description is message
  `0x320000 + id` (`14041e030(COMMAND*)`; deck edit 400800 / 400040 / 3fd180, shop 4074c0).  The texts are in
  `message/<lang>/system/CT00100.ctd` (FileID 0x320000; plain bytes, `\n` between lines, 1 to 3 lines, longest
  line 54 characters).
* SetNodeMsg looks the text up with `1401b3750(id, char **text, layout **rec, u16*, char)` (call at 1a81bf) and
  the text object copies it (`140125650`).  The mod hooks that call and, for ids 0x5b..0xe3 that are not items,
  returns its own buffer: the text + " MP n" ("MP All" for Cure while CureUsesAllMP is on), on a new line when
  the last line would pass 54 characters and there are fewer than three lines.
* Text encoding (decoder `140549180` -> `140128360`): bytes below 0x81 are one character, otherwise two bytes
  form one 16-bit code, Shift-JIS style.  Codes handled by the layout pass `140125b70`: colour style per
  character, f950 = 1, f951 = 2, f959 = 3, f066 = 4, f941 / f958 = 0; f961 + three digits = x position; f5xx /
  f1ae.. / f9ad.. = icons.  Style colours (`140127800`, ABGR, 80 = full): 0 the text's own, 1 ff000080 red,
  2 ff008000 green, 3 ff008080 yellow, 4 ff006080 orange, each multiplied by the node colour (`140122750`).
* Test: `t_desc`.
* The four items that restore MP as well as Focus (`EtherRestoresMP`, item_effect_hook: Ether 0xbf 50 %, Mega-Ether
  0xc0, Elixir 0xc2, Megalixir 0xc3 100 %; Item Boost raises it as it does the heal) get descriptions that say so,
  through the same lookup hook: messages 0x3200bf / c0 / c2 / c3, replaced only when the game's text starts as the
  English one does.  Lines kept to 54 characters, at most three.  Test in `t_desc` against CT00100.ctd.

## MP row in the menu's character panel (src/status.c, tex.c; `[Menu] StatusMP`, `StatusMPColor`)

* The panel is `CCampTopStatus` (vtable 140677440, object at CCampTop+0xe0, 0xa8 bytes): layout id 0x67
  "chara_plate" of camp.l2d ("camp" data handle at +0x1c, instance handle at +0x20).  Base class CMenuWnd:
  slot 1 = update / state machine `14042ab80` (state byte +0x9b; state 1 calls slot 5 "open"), slot 5 =
  `140417f00` here (base `14042b340` creates the layout with control 1 or restarts control 1, then the texts are
  written), slot 9 / 12 start control 2 (close), slot 11 `14042b2c0` and the destructor `14042a790` destroy the
  layout (also `14042b010` / `14042b090`).
* Nodes (id: sequence, position under the plate): 0x1d plate "player_flame" (-85,-87 in the layout; root
  animation of controls 1 / 2 = slide by 80 and fade over 16 frames; object 5 = sprite 179 = the four lines,
  3 high at y 0 / 11 / 22 / 41 from (-2, 25), vertex colours yellow / green / orange / white), 0x1c LV (0,18),
  0x19 HP (0,30), 0x1a FP (0,41), 0x1b NEXT LEVEL (0,51): label sprites of two quads (shadow, glyph) tinted by
  a colour key; 0x1e name, 0x1f / 0x22 / 0x24 / 0x26 the value texts at (69, 17 / 28 / 39 / 58), sequence
  "font_02" (id 0xb0), text table entries 13..16 (colour, pitch 8, size index 4, alignment index 6, kind 1).
* Label art: grey (128) pixel glyphs in the menu sheet (remastered texture of camp.l2d block 0, 1024x1024,
  uv = texels, 2 texels per screen unit): LV (8,646), HP (34,646), FP (62,646), NEXT LEVEL (90,646).  Four
  copies of the sheet are loaded (US_camp_arc6 / 10 / 11 / 12.png), identical in that area.  tex.c recognises
  the sheet by a hash of the HP / FP alpha shapes and writes an "MP" cell at (300,676) 26x16: an M drawn in the
  same style (tools/genstatart.py) and the sheet's own P.  The area is transparent in every copy and outside
  every sprite rectangle of the file.
* status.c, every frame after the panel's update (the class's vtable slot 1 is replaced): FP / NEXT LEVEL
  nodes and the plate's last two lines move down 11 (SetNodePos 1a7ec0; CloneNodeSprite 1a83f0 +
  GetNodeSpriteData 1a6980 on node 0x1d object 5); two sequence instances of "camp:0" are attached to the
  plate node (AttachToNode 1a4e10): id 0x184 ("charge_tab_grd", one sprite of three quads without a colour
  key) rewritten into line + label shadow + label, and id 0xb0 with SetFontParam (1a7450; struct of 1aa820:
  +0 text, +8 colour, +0x14 flags 1 text / 2 colour / 4 pitch +0x17 / 8 alignment +0x18 / 0x40 size +0x19 /
  0x80 kind +0x1c) and SetText (1a7b20).  They copy the panel's priority, queue and timer group and follow its
  visible flag.  Vertex colour = wanted colour (texel 128 x 0x80 = 1.0); text colour = half of it (a text
  colour counts double: FP's table colour ff / 44 / 1a is shown as ff / 88 / 34, its label key is ff8434).
* Lifetime: an attached instance points into its parent, so `Destroy` (1401a57f0) is hooked: when the
  panel's layout goes, ours are detached (1a5a50) and destroyed first.
* Test: `t_status` (texture patch on the real sheet; layout part on the real 2D runtime with camp.l2d and
  stand-in font tables [0x8f86968 + i*8]: +0x100 glyph count, +0x10c glyphs per row, +0x10e / +0x110 metrics,
  +0x118 glyph table).

## Minimum damage (EXP Zero's damage floor without the ability, on Critical; src/mp.c, `[Combat] DamageFloor`)

* `1400d2960(int *dmg, attackId, enemyMaxHP, enemyName)`, called from the enemy damage function `1402d24b0`
  (attack id `hit+0x9c`, enemy max HP `enemy+0x23a`, name `enemy+0xf0`): only when the player has ability 0x1c9
  (EXP Zero; test `140221900`) and the table is loaded.  The floor is applied last, after the enemy's own
  reductions, and only when the computed damage is lower.
* Table `Exp0/Exp0Param.edp` ("@EDP", version 2), requested with the system files by `1401da420` in every mode
  and every difficulty, loader `1400d2af0`: a class nibble per attack id 1..0x12d (0 basic attacks, 1 most
  commands / magic / finishers, 2 the big commands 5d 5e 7c 80 86 a6-a9 ac ad af b0, 15 none), then rows of 13
  ints (two unused, max-HP range, and per class: divisor, addend, percent/10).
  Normal enemies (max HP 15..132): (HP/30 + 3) x 1 / 2 / 3.  Bosses (name starts with 'b', max HP 200..1500):
  HP/200 (at least 3), (HP/200 + 3) x 1.5, (HP/200 + 3) x 2.5.  Outside the ranges: no floor.
* The mod hooks the ability test's call (d29a5 -> `140221900`): the answer is also "yes" when the difficulty
  byte `150fa0881` is 3 (0 Beginner, 1 Standard, 2 Proud, 3 Critical; the same byte the menus use to offer EXP
  Zero), or on every difficulty with `DamageFloor=2`.  Untouched and still tied to the ability: the cap on
  damage taken (`1400d2c00`, from `14023e4e0`: non-boss hits at most (maxHP-1)/2), the EXP take-back
  (`140284800`), the "active" test `1400d2cc0`.
* Test: `t_floor` runs the game's function on a table with these values, without the ability.

## Context prompts on triangle (src/menu.c, style.c; `[Menu] ReactionButton`)

* A context prompt (Talk, Open, Save ...; `cmd+0x60` bit 0x40000, plate type 5 at `cmd+0x298`: layout 7 with
  node 0x5a on sequence 0x19d, whose first text is the button picture, f564 in the layout) is answered in the
  command update by the confirm test `140272860` at 236b97; while it is up only that test, the action commands
  (232df0) and the deck input (233a00) run - the Attack part is skipped.
* The call is replaced: for every prompt but the counter prompts (command category 6) the answer is the triangle
  test `140272c20`.  The plate's picture is set to f567 (f564 for counters) after each plate update.
* The attack button then: off Attack it is the menu's as usual (the "swallow" rule no longer stands back for such
  a prompt); on Attack, menu_input does what the skipped Attack part would [236d9e..236e8e]: the COMMAND of the
  attack plate of the current style level to `cmd+0x80` and `+0x1c8`, `pl+0x570 = dt`, under the same conditions
  (no 0x1000 / 0x4000 / 0x20000, `pl+0x318 & 0xc0`, not action 0x18e at level 0) but without the plate's
  "pressed" state (the game covers the attack plates while a prompt is up, 1402376b0).
* A Command Style offer does not take a triangle press while such a prompt is up (style_decide).
* Placement: the offer always sits right above the gauge window (prompt place - 3, its timer bar under it); a
  context prompt is at the prompt place, or 16 above the offer (`PromptAboveOffer`) while an offer's plate is on
  screen (style_prompt_shown: offer, finisher offer, or the "accepted" flash).

## Lists over the menu, with a header (src/menu.c list_y / hdr_frame, tex.c hd_patch; `[Menu] ListX`, `ListHeader*`, `ListDims*`)

* Place, as in KH1: x = `ListX` (14; the menu is at 4.5).  The first row of a list of n rows opened from entry e
  (1 Magic, 2 Items, 3 D-Link) is on row min(e, 3 - (n - 1)) of the menu's rows (0..3 at 198 / 213 / 228 / 243;
  negative rows lie above the menu, 15 apart): the list starts on its entry's row and runs down, and once it would
  pass the last row it ends there and grows upwards.  The D-Link list (the game's own plates, type 6) follows the
  same rule and gets the lists' draw priority (12 / 13: over the entries at 5 / 7 and the gauge window at 8).
* The four entries are darkened while a list is open (L2D SetColor on our instances, `ListDimLevel` percent).
* Header = an instance of bc01_00 layout 5 with node 0x46 (gauge) hidden; node 0x47 is the label: sequence 0x25a
  in battle (plate efaf03, letters ffff00), 0x25d in the field (005ff0 / 00ffff) - the game swaps them the same
  way for its window [2320e0], it does not use control 5 of 0x25a.  Object 1 = sprite 34 (plate, three quads:
  -2..5, stretch 5..76, 76..90), object 2 = sprite 35 (letters, one quad (0,-1)-(82,9) with uv 8,294..172,314 =
  a 20-unit strip at half size).  Private copies of both: the plate's stretch is made 24 longer (as long as a
  row), the letters' quad is pointed at one of our words.  Placed at the first row + (-1.6, -9.1).
* **Language files.**  The game loads `arc_<lang>/pc/p00common.arc` (en, fr, de, it, es in bbs_first; the plain
  `arc/pc/p00common.arc` is the Japanese one).  bc01_00.l2d differs between them only in sprite 35's quad (JP
  73 wide, uv to 154: "COMMAND"; the others 82, to 172: "COMMANDS" etc.), and the command sheet - the remastered
  texture of bc01_00, 1024 x 1024 - differs in the three words at px 17..367, 529..706 (and JP in a few icons).
  Everything in l2d/ and tex/ before this was the Japanese set; en/ has the English and French ones.
* The words MAGIC, ITEMS, D-LINK are our own drawings (tools/hdfont.py: rectangles on a 31 x 24 box, slant 0.4,
  heavy left stem 12.5, thin strokes 5.6, bars 5.3, black shadow at +3,+3, measured from the game's label; no
  pixels of the game are used).  tools/genhdart.py writes them to src/hdart_gen.h with 24 check pixels taken where
  the EN, JP and FR sheets agree; tex.c adds them at px 16,740 (236 x 132; units 8,370), an area all three leave
  empty, when the game creates the texture.  No recognised sheet: no header, the lists still work.
* Tests: `t_listhdr` (rows; the three sheets recognised and patched; header on the English bc01_00.l2d).

## D-pad right opens a list (src/menu.c menu_input; `[Menu] RightOpensList`)

* On the main menu, with the cursor on Magic, Items or D-Link, a new press of d-pad right (`140272cd0`) does what
  the confirm button does there: opens the Magic / Items list, or the game's D-Link list through `1402388a0`.
  Nothing on Attack or inside a list.  It does not depend on who owns the confirm button, so it also works while a
  counter prompt is up.  Test: in `t_menu`.

## Jump button closes an open list (src/menu.c; `[Menu] JumpClosesList`)

* The player's input gather `14021f9f0` asks the pad object "jump pressed" with `140272f10` (call at 21fb99; the
  button is the menus' cancel button, mask `1408221c4`, circle by default; the answer becomes flag 1 of
  `pl+0x31c`; `140272670` at 21fbb4 is "held", flag 0x400).  The call is replaced: with the Magic / Item list
  open the press closes the list and the answer is no; with the game's D-Link list open (`cmd+0x60` bit
  0x10000000) the answer is no and the game's own "close the list" pad test (`140272d30`, d-pad left, call at
  2337e9 inside 1402334f0) says yes once.  Test: in `t_menu`.

## Shortcuts (src/shortcut.c, sccamp.c, menu.c; `[Shortcuts]`, bindings in bbskh2_shortcuts.ini)

* A shortcut is "face button -> deck slot 1..8", per character (`150fa0880`, 0..2), default slots 1..4.  Rows in
  KH2's order: circle, triangle, square, cross.
* Pad: bit words in the PS2 layout (0x10 up, 0x20 right, 0x40 down, 0x80 left, 0x400 L1, 0x800 R1, 0x1000
  triangle, 0x2000 circle, 0x4000 cross, 0x8000 square; the left stick repeats the directions at << 16):
  `148f64930` held, `..34` newly pressed, `..38` changed, `..3c` with auto-repeat, `..9c` input off; history ring
  index `..54`, arrays `..58` / `..78`.  All written by `1400ed040` (called at e3716); keyboard and mouse
  bindings arrive in the same words.  Readers: `1400ecd90` new presses, `ecd40` repeat, `ecca0` held.
* shortcut.c, after that call: while L1 is held without R1, the command menu is on screen (menu.c tells), no
  D-Link list is open and the player's pad object (`mgr+0x58`: flags +0xa0 bit 0, lock timer +0x54) is live,
  the four face bits are removed from all of those words and a new press is kept for `BufferFrames`.  menu.c
  uses it through the same gate as a confirm in the list (can_use_now, mp_use, queue at cmd+0x80..).
* Vanilla L1 in control type 0: camera behind the character (pad test `1402729c0`, call at 22b5df) and next
  lock-on target (`140272b80`, call at 2650d4).  Both calls are replaced: true for one frame when L1 is let go
  within `TapFrames` and nothing was done with it.  Other control types keep the game's camera test.
* The L1 list (menu.c sc_frame): four more instances of the deck plate (bc01_00 layout 3), body node 0x5d always
  on sequence 0xb, layout control 0 = the game's look for the plate under its cursor: sprite 17, a plate 10
  longer whose left end is a solid tab (x 0..20 of 127), and a text object centred at (11, 8) in the tab that
  holds a button picture (text table entry 16: font index 3, pitch 8, alignment index 4 = centre / middle; the
  alignment value is low nibble 0 / 1 / 2 = left / centre / right, 0x10 / 0x20 = middle / bottom, `140123d80`).
  In control 0 the name node's text is at x 27 and the item count at 111.
  Grey: all plate colours are colour keys on grey texels and colours only multiply (key x local x parent), so
  the key has to change.  An object's animation record and key table are pointers of the object (`CD2Obj +0x30`
  record, `+0x38` key table; set by `1401abb80 -> 1401aa7f0` on every control change, read at draw time by
  `1401a87b0`), so the seven objects of that node get records of our own: record = 0x18 bytes {s32 maxf, s16
  sprite, u16 first key, u8 keys-per-kind[11] (status, baseX, baseY, offX, offY, rotX, rotY, rotZ, scaleX,
  scaleY, colour), kind (0 root, 1 sprite, 2 text; 0x80 = not drawn), blend, flag, scissor, z}, key = 0xc bytes
  {float frame, value (float or R G B A), interpolation}.  Put back every frame (a control change resets them).
  The inside is object 6 (sprite 2) with private quads: the game's gradient art (2,30..32,60).
  Button pictures in text: f564 confirm, f565 cancel, f566 square, f567 triangle, f568 L1, f569 R1, f56a L2,
  f56b R2, f57b circle, f57c cross (`140546c00` swaps in the current device's glyph).  A picture inside a line
  of text hangs below the letters; a text of pictures alone with "middle" alignment is centred.
* Menu (sccamp.c).  Command Decks = `CCampDeckTop` (vtable 140674c70; update 140402fa0 in slot 1; state +0x9b,
  2 = browsing; +0xea pane-pick mode; +0x11 pad lock of the screen's own confirm / cancel reading).  Children:
  +0xb8 the list `CCampDeckTopCmd` (vtable 140674d40, layout 0xcc: root node 0xb, entries nodes 1..5 at
  (-230, -75 + 17 i), sequence ids 4b / af / 113 / 177 / 242; cursor +0x8e; hand +0xe8 with offset (8, 10),
  light frame +0xf0 with offset (105, 0), both attached to node 0xb; positions +0xa8; input = vtable slot 8,
  140404490, which returns the "action taken" flag of 14042b450 and wraps the cursor 4 <-> 0 by itself),
  +0xc0 the Battle Commands pane `CCampDeckTopBtl` (vtable 140674e10, layout 0xc9: slot anchors nodes 1..8,
  18 apart; plate objects +0xc0 + 8 i with handle +8 and "locked" +0x40, layout 0x6f: node 3 name, 4 "LV",
  5 level; hand +0x100 attached to node 1, no offset).
* The entry: an instance of sequence 0x177 attached to node 0xb at (-230, 10), text through SetFontParam as
  text-table entry 24 (pitch 11 becomes 12 for font 0 on PC, `1401aa620`).  The text object of a sequence
  instance is the first object with one (`1401abb00`): object 1 here, the same as in the layout's own node.
* The list's input is wrapped: when the game's cursor wraps, ours takes over (mode ENTRY) and the game's entry
  is un-lit; from there up / down hand the cursor back to entry 4 / 0.  While in our modes the screen's pad lock
  is set so that its own confirm / cancel see nothing; cancel on the entry clears it and runs the game's input,
  so the screen closes as usual.  If the list's input stops being called while we hold the lock (the screen's
  update wrapper checks every frame), everything is let go.
* The screen's update (140402fa0) returns 1 when the screen is finished (state 4) and the menu then drops it;
  the wrapper has to return that value (a void wrapper closed the screen on its first frame).
* In the pane, a slot's buttons are shown by its level text node (5): anchor moved to (123, 5.3) (a button
  picture is drawn 2.2 below the middle of its text: measured in play, anchor 7.5 gave 5.1 .. 14.3), font
  parameters through `1401a7cb0` (node version of SetFontParam) = font index 3, pitch 8, alignment index 7
  (right / middle), no tint; put back to entry 65's (font index 4, alignment 0, the saved colour and text).
* The pane's plates come from `140402820`: per slot the 6-byte deck record of `14041dd30` (s16 inventory index,
  byte 3 = row inside a multi-slot command, byte 4 = slots the command takes); a plate object is made only where
  byte 3 is 0 (the first row's plate is made taller, `140410370`), so the second row of a two-slot command has
  no object at pane+0xc0 + 8 i.  The slot cursor skips slots without one.
* The fill `1404103c0(btn, COMMAND*, name 3, 2, level 5, 0, 0, LV 4, record, 0)` gives an item its count in the
  level node as "x3" with font parameters flags 0x29: alignment index 6 (right) and x offset 5 (text +0x2b4).
  The offset stays on the text object, so ours are set with offsets 0 (flag 0x20) and the old alignment, font
  and offsets are saved from the text object (+0x298, +0x2cc / +0x2cd, +0x2b4 / +0x2b5 / +0x2c8 / +0x2c9) and
  put back.
* Tests: `t_shortcut` (pad), `t_sclist` (L1 list on bc01_00.l2d), `t_sccamp` (menu on camp.l2d with the game's
  own list input).  Not covered offline: how any of it looks.

## Grey "COMMANDS" window while the shortcut list is shown (src/menu.c hd_frame; `[Menu] ShortcutHeader*`)

* The window is bc01_00 layout 5 (the game's instance at cmd+0x98): node 0x46 = sequence 0x258 in battle (7
  objects: root, sprite 15, 32 shadow, 37, 36 gauge fill, 37 gauge bar, 33 frame) or 0x259 in the field (6: no
  sprite 15); node 0x47 = sequence 0x25a (root, sprite 34 label plate, sprite 35 letters).  Colours are colour
  keys on grey texels: frame ffdc00 / 005ff0 (alpha ff, a0), plate efaf03 / 0056e6, letters ffff00 / 146efa.
* A Command Style's window and the D-Link's (dl_01) are other instances (cmd+0x9c) and are never touched.
* Grey = the object plays a twin of the record the game gave it: same record, key index into our table
  (g_sc_keys from entry 16, 40 per object), where the record's keys are copied and its colour keys (the last
  `keyn[10]` of them) set to grey with the game's alpha.  So appear / fade animations keep working in grey.
  Object +0x30 = record (set with 1401aa7f0), +0x38 = key table.
* Back to normal: the game's record (remembered per twin) and the node's key table (read from the root object,
  which is never changed) are put back.  A control change by the game (1401abb80) puts its own records back but
  not the key table; hd_node sees "game's record on our table" on its next pass and repairs it.  Until then such
  an object reads zeros or twin keys from our table: at worst one frame of a wrong colour, no bad read (the
  table has 0x10000 entries).
* The gauge (sprites 36 / 37) keeps its colours.  Test: `t_header`.

## D-Link list: cursor speed (src/menu.c link_scroll; `[Menu] LinkCursorTime`)

* The game's D-Link list is a wheel under a fixed cursor: a step calls 140205cf0(plate, direction) for every
  entry [233491] (new place plate+0x6e, state 2, time plate+0x68 = 10).  The plate's update steps the move with
  1402044c0 and, when it is over, makes the entry under the cursor (place == cmd+0x354, or the last) the selected
  one (flag 4, state 4, 140205a60 -> state 1), the others state 0 [204d5a].  140233200 takes no input until the
  entry under the cursor is ready (1402047f0), so a step costs 10 time units, a third of a second.
* The two calls of 205cf0 in 233200 (2332a1, 233491) go through link_scroll: time 0, the game's own step
  function ends the move at once, and what the plate's update would do next is done right there.  The list then
  moves at the pad's repeat rate, as the Magic and Items lists.  `LinkCursorTime` > 0 keeps the animation with
  that time (10 = the game's).  Test: in `t_menu`, on the game's own functions.

## D-Links during MP charge (`DLinkDuringCharge`)

* The first design refused a new D-Link while the bar recharged, in three places: the menu's D-Link entry
  (entry_usable), the game's "open the D-Link list" [2388a0] and "confirm an entry" [205ee0].  Reported as a bug: out
  of MP, no D-Link.  A D-Link costs no MP, so all three now go through `mp_blocks_link()`, which is only true with
  DLinkDuringCharge = 0.  The D-Link deck's commands still wait for the charge (use_hook), items do not.

* `DLinkRefillsMP` (asked for right after): starting a D-Link fills the bar and ends a running charge, as a Drive
  Form does in KH2.  Done in the hook on 205ee0, the game's confirm of a D-Link list entry (it takes the entry only
  if it is not used up and its command id is above 0x162): that is the player starting a link and nothing else - a
  link carried into another room does not come through it, so there is no refill per room.  Not when a link is
  already active.  Test in `t_use`, through the installed hook and the game's own function.

## Air combat: BBS against KH2, and air hops (src/speed.c hop_hit / hop_frame / h_gravity; `[Speed] AirHop*`, `AirLog`)
* BBS (player_actions.md 4.2, 4.3): g = -0.0049 per tick^2 (1/60 s), jump 0.135 per tick, height cap 1.75.  An
  aerial action starts with vy = 0, bit 0x800000 and 16 % gravity; 21cb00 forbids sinking before frMoveEnd and
  zeroes any rise from frMoveEnd on.  Every hit of an air combo starts from vy = 0 again, so a whole combo loses
  almost no height; an EXMOVE hit with the target 4 or more above starts at +44u, faster than a jump.  After the
  action: 6 frames of no gravity at the start of the fall, 30 ticks without buttons (the mod: AirWeight / AirLock).
* KH2 (its own files, read from the user's install): 03system.bin > pref > plyr, Sora's entry: AttackFirstV0 8,
  AttackComboV0 6, AttackFinishV0 12, AttackJV0 8 (forms differ, e.g. 12 / 9, 18 / 24); sstm FallMax 16; prty
  Sora JumpHeight 185 (Valor's high jump 235 / 310 in fmab).  obj/P_EX100.mset: the motions A330 / A331 (air
  combo hits, combo window from 22 / 20 of 60 a second) and A332 / A333 (finishers) have no "no gravity" range at
  all; the moves A341..A346 have one for part of the move (16-24 ... 16-100).  So KH2's air combo is a hop per
  hit with gravity on.  Its gravity is not in the data (a code constant).  Units: KH2 about cm per 1/60 s, BBS m
  per tick; a hop of 6 is about 3.6 m/s against BBS's jump of 8.1 m/s.  (Which motions are the air combo is
  read from their markers, not from a name table.)
* The mod (AirHop): for Attack-button hits in the air (state 0x10 part 5, record AERIAL without RISE / DOWN /
  FLOAT, local player only):
  - start of a hit (tick hook 220b1d, new record or the animation frame went back): vy = AirHopKeep x g x T / 2,
    T = frChangeEnable (0x0d, or cmb) x 2 / animation speed, clamped 8..80 ticks - the speed that is back at
    the start height when the next hit can start; x AirHopFirst on the first air hit since the attack state was
    entered; the finisher (is_finisher) gets AirHopFinisher x the jump speed (27.6 u) instead.  pl+0x508 = g.
    This replaces the +44u pull of 229fa0 for these hits.
  - every frame of such a hit (21cb55): xmm0 = g x AirHopGravity, on at 21cb7a (written to pl+0x508), bit 23
    cleared in the register copy (no no-sink clamp), xmm4 = 1e9 so 21cc00 never zeroes a rise.  pl+0x318 keeps
    bit 23, so the game still ends the attack into the fall state.
  - Ventus' first air hit (chg 15) at speed 1: vy 0.079, up 0.6, +0.1 when the next hit can start.
* `AirReach` (asked for, option 2 of four discussed): the lift is kept only as one rise to a target well above -
  KH2 has a separate rising attack for enemies about 0.5 .. 1.9 m above (its plyr U MinH / MaxH -50 / -190, Y
  up is negative there) within about 2.6 m.  At the start of a hop hit, if pl+0x600 > 0 and pl+0x618 (target
  height difference, positive = above; what 229fa0 itself uses: (dy x 10 + 4) x u) >= AirReachMin: vy = max(hop,
  sqrt(2 g min(dy, AirReachMax))), at most the jump speed.  No horizontal-distance test (no field for it found).
* Reported right after AirReach: on the ground, an enemy a little above, the player was pulled into the air.  The game
  plays air-combo records (AERIAL, which always sets bit 23) from the ground too; its own rise (229fa0) is only
  given when 264a10 says "in the air", so they stay down.  The hop and AirReach had no such test.  Now a hit hops
  only if it starts in the air - pl+0x318 bit 22, which the player update sets from 264a10 after the tick hook
  [220550 tail]; 264a10 itself is not called from the mod (it can call 292350, a landing effect) - and the
  gravity hook applies only to the record that started hopping (g_hop_live).  Test in `t_speed`.
* `JumpHang` (default 0, asked for): the 6-frame hold of the fall state (2633ff, the hook that already skipped it
  after actions) is skipped for every fall, so the top of a jump no longer hangs for 0.2 s.  JumpHang = 1 gives
  the game's hold back for jumps and ledges (still none after an action while AirWeight is on).
* AirLog = 1: a line per frame in the air (state, part, record, frame, vy, height summed from vy, gravity) and a
  summary on landing; "air: hop" lines say what each hop got.
* Test: in `t_speed`, on the game's integrator.  Not seen in the game by me: what the homing of [mks, mke]
  (21b670) does to the hop, and how it feels.  Next steps if it works: cap the pull towards targets above for
  other aerial moves, no hover at the top of a jump, finishers ending in a drop.

## Launch height (src/speed.c h_launch; `[Speed] LaunchHeight / LaunchMin / LaunchMax`)
* Asked for after comparing with KH2 (the user had first checked that the frequent launches happen in the unmodded
  game too).  BBS: the Attack button's record is chosen from the combo table (pl+0x5c0, PAO_<char>Cnn.bin, 20-byte
  entries: mode, count, PBA slot, then (type, value) conditions; type 1 = in the air, 4 = a bit of the mask below,
  6 = same as the entry above) by 2239b0, which builds the mask from the target [21b670]: pl+0x618 = target point
  height (a joint by default, 1d4920) - player height - PPM+0x1c (0.2 / 0.3 / 0.4), pl+0x614 horizontal distance,
  pl+0x620 angle.  Within 3.5: bit 1 (2) if dy > 0, bit 5 (0x20) if dy < -1.5; bit 3 (8) beyond 3.5; bit 2 (4)
  angle <= 45 deg, bit 4 (0x10) 45 .. 135 deg.  All three base tables: on the ground with bit 1 -> PBA slot 4,
  the rising attack (16 / 301 / 582); in the air bit 1 picks another air hit (19 / 304 / 584).
* KH2, first look (03system pref plyr, Sora: U MinH / MaxH -190 / -50, URange 260) gave 0.5 .. 1.9; the first build used
  that.  Asked to make Ventus match Sora exactly, KH2's code was searched (Ghidra, all 24789 functions): no code reads
  those plyr fields (the plyr entry is reached only through obj+0x150, and only +0x2c, +0x50..+0x70 are read).  The
  attack choice is 00battle.bin ptya (0x44-byte entries; Sora = pointer 1): 1404029f0 / 1404027f0 test, per entry,
  Near <= horizontal distance - target radius < Far, High < target y (player local, Y up negative) <= Low, angle.
  The target is the enemy's target collision (1403c9c00: bone + offset, radius +0x10, half height +0x12 = "span").
  Flag 2: High -= the jump height (prty, 185); flag 8 / 0x10 flip the span.  Sora's base rising attack (id 0, motion
  182, flags 0xa): -435 - span < y <= -110 - span, Far 260 -> the bottom of the target 110 .. 435 cm above Sora's feet
  within 260 cm of its edge.  Ordinary first hits (id 4 / 6, flags 0): -110 - span < y <= -20 + span -> the target
  reaches into 20 .. 110 cm.  Units: Sora's skeleton is 160 tall (cm), Ventus 1.59 (m); jump 185 / 1.86.
* The hook at 223b0d (ecx = mask, rbx = player, r13 = 1 in the air, pl+0x608 = target entity): on the ground,
  bit 1 = LaunchMin <= target phys+0x34 - player phys+0x34 <= LaunchMax and horizontal distance - target phys+0x190
  (radius, clamped 0 .. 1.5) <= LaunchReach (defaults 1.1 / 4.35 / 2.6).  BBS has no "bottom of the target volume";
  the entity's position (its feet / origin) stands in for it.  In the air nothing changes.  Command Style tables that
  test bit 1 on the ground follow the same rule.  Test in `t_speed` (the handler on a context with fake entities).

## D-Link entry icon (menu.c link_icon; `[Menu] DLinkIcon / DLinkIconX / DLinkIconY`)
* The entries' icons are sequences of bc01_00 on node 0x5a of the deck plate (layout 3): 0x20 keyblade, 0x21 hat,
  0x22 bottle (control 3 the still one), the D-Link entry had none.  The hearts are sequence 0x2e (the D-Link gauge's):
  control 0 the pink heart (sprite 61, texture 362,90..390,118, 14 x 14 at (0,0)), 1 / 3 the grey one (sprite 62),
  2 / 4 pink 10 to the left.  Its sprite sits at the node's origin where the other sequences put theirs around
  (104, 10), so the node is moved by (97, 2) (3 was too low, 1 too high) (1a7ec0 -> the node's +0x58 method), and node 0x5a is put back on
  control 0 every frame (the plate's set_control sets every node's control; 1 / 3 would be the grey heart).
  Asked for: the pink one always, also when the entry cannot be used (the other icons do not grey out either).

## Command Style in the air (style.c h_style_air; `[Style] AirChange`)
* State 0x19 (style change) starts in 28a950: for a style candidate (cmd+0x190) it asks 264a10 at 28ac1d; in the air it
  sets pl+0x318 bit 0x80000 and plays the fall loop (motion 10), and the update 286380 integrates gravity until
  landing, then plays motion 0x87 (0xd3 for categories 7 and 12) and goes on.  The hook at 28ac22 (rax = 264a10,
  rdi = player) makes the answer "on the ground" for category 6 (Command Styles) only: the change plays at once;
  1d3b90 right after zeroes the body's velocity and nothing in that state moves the player vertically, so it plays
  in the air.  The end (21a490(pl, -1)) asks 264a10 itself -> 264060, the fall state.  Not seen in the game by me.
  Test in `t_style` (the handler on a context).

## Speed per command (src/speed.c cmd_override; `[CommandSpeed]`)
* Asked for: Mega Flare a little slower, and a way to set every command by itself.  Mega Flare (0xac) was never in a
  cast-time family: it, and every spell but the four families, played at Actions (1.15) from start to end.
* `<id>=<speed>` in [CommandSpeed] (ids 1..0x23f, 0.25..4).  `wanted()` asks the list first: while the game says a
  command runs (`pl+0x5e0` != 0, the category the starters set) the speed of `pl+0x312`, the running command's
  id (21f9b0), if it is listed.  That covers every state a command runs in - 0x10 attack, 0x11 magic, 0x12 item,
  0x13 D-Link / friend, 0x14 finisher, 0x15 movement, 0x16 guard, 0x17 counter, 0x18 shotlock - through the same
  per-frame setter as the rest (so Haste / Slow / Stop still win and the lunge fix follows).  The list in the ini is
  generated from the command table (type / category) and the English names (CT00500.ctd).
* Not seen in the game by me: in particular that the Attack combo runs as id 1 (or the Command Style's own
  attack, 2..0x10 / 0x2e) in `pl+0x312`, and that movement, guard and shotlock animations look right at other
  speeds - parts of those are timed by the state's clock, not the animation.
* Test: in `t_speed`.

## MP Haste (mp.c charge_speed, haste_texts; `[MP] ChargeSeconds`, `MPHasteBonus`, `MPHasteRename`)

* KH2 (its 00battle.bin and the wiki): the MP charge takes 50 s / (1 + bonus); MP Haste 0.25, Hastera 0.5,
  Hastega 1.0 (0.75 in Final Mix).  Here: `ChargeSeconds` 25 (20 at first, 50 for one build, then 25 on request),
  and the game's own Magic Haste - ability
  0x1d0, which can be installed several times; `140221900(player, id)` gives the number in effect, the byte
  `player + 0x4a3 + slot`, slot = command table +7 (13) - adds `MPHasteBonus` 0.05 a copy (0.1 in that one build): 25 / 23.8 /
  22.7 / 21.7 / 20.8 / 20 s for 0..5 copies.  Attack Haste (0x1cf, slot 12) keeps the 0.05 a copy both abilities had before
  (`AttackHasteBonus`).  The two then do exactly the same, so on request Attack Haste is shown as MP Haste too:
  name message 0xfa01cf, description 0x32020c ("Shortens the reload time for all attack commands ...", 126
  bytes), same treatment as below.  An ability whose bonus is set to 0 keeps the game's texts.
* The name.  Command and ability names are file `message/<lang>/system/CT00500.ctd` (first id 0xfa0000, 498
  messages, message i = command i).  A message file: `@CTD`, +8 first id, +0xc u16 layouts, +0xe u16 messages,
  +0x10 offset of the message records (u32 id, u32 text offset, u32 layout), +0x14 / +0x18 the other tables; texts
  are plain bytes.  When a file is in memory the game calls slot 1 of CRsrcCTD's vtable (637910 -> 140112ed0):
  it sets +0x90 file, +0x98 records, +0xb0 / +0xb4 the id range, and for file 0xfa0000 copies every text's
  address into the command table (`140814908 + id * 0x18`).  Nothing else reads a name (no other use of
  0xfa0000 in the exe).
* The description.  An ability's is message `0x32003d + id` of CT00100.ctd (`14041d880`, through the plain
  lookup `1401b3d80`, which has 394 callers - not the SetNodeMsg lookup the MP-cost text hooks).  Magic Haste:
  0x32020d, "Shortens the reload time for all magic commands / installed in your deck. Multi-install the ability
  for even / quicker reloading." (125 bytes, lines up to 58).
* So the vtable slot is replaced: after the game's function, the two texts are rewritten in the loaded file
  itself, which every reader then sees.  The name goes there when it fits (MP Haste does; a longer one from the
  ini goes through the name pointer instead); the description is cut to the room the game's text has.  Only when
  the text found is the English one - other languages keep theirs - unless `MPHasteName` / `MPHasteHelp` are
  given.  The mod is loaded before the game reads any file, so the slot is in place for the first load, and a
  file loaded again is rewritten again.
* Test: `t_haste` (charge times on the game's own ability count; the texts through the patched slot on the real
  files, BBS_MSG_NAMES / BBS_MSG_HELP).  Not seen in the game by me.

## Berserker (mp.c berserk_factor, damage_hook; `[MP] BerserkerDamage`, `BerserkerRename`)

* Asked for: "command boost" renamed to Berserker, doing more damage during the MP charge and nothing else of
  KH2's Berserk Charge (there: Strength +1, +2 in Final Mix, per copy, and combos that never reach a finisher).
  The game has no Command Boost; the one Boost about commands is **Reload Boost** (0x1d9, slot 22, one copy:
  "Shortens the reload time for all commands installed in your deck whenever your HP falls below 25%"), which
  like the two Hastes has nothing left to do here (its only reader, the reload factor `140235140`, feeds a
  reload the mod replaces).  That one was taken.  The name is "Berserker" (the request spelt it "beserker").
* A percentage, not KH2's flat Strength: the test save is level 99 (Strength 53), where +2 would be about 4 %, and
  without the endless combo the damage is all the ability is.  20 % in the first build, 5 % on request.  The
  game truncates damage to a whole number, so 5 % as a multiplier added nothing to a hit below 20 - and basic
  hits are about 5 to 15 for most of the game ((Strength - Defence) x power: Strength 3-4 at level 1, 11-14 at
  20, 21-23 at 40, 49-53 at 99 from the level table 140649790; enemy Defence 3 to 15 by the wiki).  So, on
  request, the bonus is rounded UP: the game's own whole number + ceil(that x percent / 100), at least 1.
* Where damage is worked out: `1401f9180(attack, hit)`, called only from `1401f9790` [1f985a] when an attack
  registers on a target; the result is the hit record's +0xaa (s16), which the enemy's damage function
  `1402d24b0` then takes off its HP.
      crit (`1401f90e0`: attack+0x78 percent chance, +0x7a multiplier percent)
      x clamp((attack+0x82 stat - hit+0xac defence) x attack+0x84 power / 100; hit+0xb0 .. hit+0xae)
      x hit+0xb2.. resistance to element attack+0x80 (1..6) / 100 x hit+0xc4 x attack+0x88
  attack+0x7e & 0x7f is the kind: 0x22 gives stat + power (a cure: 2d24b0 negates it), 0x2a a percentage.
  attack+0x60 is the attacking object's entity id, +0x94 its owner's, +0x8c the command id.  The record is filled
  from the owner's callback in `1401f3d90` (stat, power, element, multiplier 1.0 by default).
* The hook on that call lets the game work the damage out (once: the critical hit is a dice roll in there), adds
  the rounded-up bonus to the result and holds it to 0x7fff; the attack record is not touched.  (The first two
  builds raised attack+0x88 for the length of the call instead.)  Conditions: the MP charge is
  running, the player has the ability (`140221900`), the kind is a damaging one, and the owner (`1401d45c0(id)`,
  the lookup 2d24b0 uses for the same question) is the player object, or its parent (+0x10) is - a spell in
  flight - or either is of type +0x28 == 1, the player class (2 = enemies [20cc70]).
* Texts: as MP Haste's, name message 0xfa01d9 (12 bytes of room) and description 0x320216 (97 bytes).
* Test: `t_berserk`, the game's formula through the hook with a stand-in entity table; texts in `t_haste`.  Not
  seen in the game by me: that the hit of a real attack carries the player as owner is read from the code, not
  observed.

## MP cost of the D-Link-only commands (mp.c base_cost; `DLinkCostByClass`)

* Reported by players: D-Link heals for 5 MP.  The fourteen commands only D-Link decks have (ids e4..f1, category
  8; decks: table at file offset 8161f8, 14 D-Links x 3 levels x 8 ids) all have reload 5 in the command table, so
  cost = reload made them 5 MP.  Two heal: e8 (Cinderella) and e9 (Doc), strength 100 / 125 / 150 by D-Link level
  against Curaga's 100; several attacks are stronger than 20 MP commands.
* The game's own rule for ordinary one-slot commands is by class (table byte +4, low nibble): class 1 reloads in
  10, class 2 in 15, class 3 in 20 (attack: 10/12 at 10, 7/11 at 15, 8/8 at 20; magic the same with the cures,
  status spells and Mega Flare as exceptions).  The D-Link commands now cost by that rule; the two heals are cures
  (`is_cure`): base 30, all MP under CureUsesAllMP.
  e4 Holy 15, e5 Wish Circle 10, e6 Enchanted Step 15, e7 Wish Shot 15, e8 heal, e9 Doc heal, ea Grumpy 15,
  eb Sneezy 15, ec Happy 10, ed Sleepy 15, ee Bashful 15, ef Dopey 20, f0 Dark Spiral 20, f1 Dark Splicer 20.
* A `[Cost]` entry now also wins over CureUsesAllMP (the ini always said it overrides everything; for the cures
  it did not).
* Test: in `t_ether`, against the real command tables.

## Two shortcut sets (shortcut.c, sccamp.c, menu.c sc_frame; `[Shortcuts] Sets`, `[Menu] ShortcutColor2`)
* Bindings are `g_bind[character][set][row]`; set 2 is saved beside set 1 in bbskh2_shortcuts.ini as Circle2,
  Triangle2, Square2, Cross2, deck slots 5..8 to begin with.  `sc_slot(row)` / `sc_assign(row, slot)` are the set
  shown in battle; `sc_slot_in` / `sc_assign_in` name the set.
* Battle: while the list is up the d-pad (0xf0 of the pad words: up 10, right 20, down 40, left 80) is taken from the
  game like the face buttons, by the same "counts where it went down" rule, and any new press flips the set (the
  menus' cursor sound, SE 1).  The set is remembered for the next time L1 is held.  A d-pad button still down
  when L1 is let go stays hidden from the game until it is let go.  The list's frame and tab (key 3 of the list's
  own key table) take ShortcutColor2 while set 2 is shown, and so does the "COMMANDS" window over it (hd_rgb: its
  frame, sprite 33, ShortcutColor2; its label plate, sprite 34, the same colour scaled by ShortcutHeaderPlate /
  ShortcutColor per channel, a87e38 by default; the twins' colour keys are rewritten on every grey pass).
* Menu (Command Decks > Shortcuts): while picking a slot, square (unless it is the confirm or cancel button)
  switches the set shown and edited; the plates show that set's buttons and the help line says which set it is.
  In "press a button" mode square is still a button to give.
* Tests: in `t_shortcut` and `t_sccamp`.

## Shortcuts: a face button counts where it went down (shortcut.c pad_frame)

* Reported: circle held, then L1 -> circle's shortcut was used.  The game's "pressed this frame" word is
  `~history[last frame] & held` [1400ed040], and the mod wipes the face buttons from that history entry while the
  list is shown (so nothing buffered sees them).  From the second frame of the list a held face button therefore
  read as pressed anew every frame: a button held before L1 fired at once, and a held one repeated.
* Presses are now counted by the mod itself from the raw held word, frame to frame (`g_face_prev`), list shown or
  not.  And the other direction, same cause: a face button still down when the list goes away stays hidden from the
  game until it is let go (`g_face_block`), or the game would take it for a fresh press and attack.
* Test: in `t_shortcut`.

## The lists' own colours (menu.c tint_node, row_colours, hdr_frame; `ListColors`)

* Asked for: Magic blue, Items green, D-Link "the D-Link blue", and none of them changing with battle.
* Where the game's colours are (bc01_00, dumped with tools/l2d.py): the deck plate's body is sequence 0xf in battle
  (frame sprite 0, key e1dc00) and 0xb in the field (sprite 0, 005ff0; reload glow sprite 2, 00c0ff additive); the
  label is 0x25a in battle (plate sprite 34 efaf03, letters sprite 35 ffff00) and 0x25d in the field (005ff0 /
  00ffff).  The D-Link plate (layout 0xa, node 1, sequence 0x2d) has no battle variant; its blue is in the corner
  colours of sprite 63's quads (0080ff; the right end 00def0), multiplied by a key 3c3c3c/a0 in controls 3 and 4 and
  by nothing under the cursor (control 0, with the gradient sprite 65 in 00b4c8).  The game's own D-LINK header
  (layout 0xb) is 0096fa.
* Rows of Magic and Items always get the field body (`row_body`: 14 objects = battle body -> ReplaceNodeSeq 0xb; the
  game re-skins only on entering / leaving battle [203ea0] and keeps its own note in plate flag 0x200, untouched),
  the header always sequence 0x25d.  Colours: `tint_node` gives an object a twin of the record the game would have
  it play, with other colour keys (alpha kept).  The game's record of object i is anims[control.first + i]
  [1abb80], so the pass is stateless: it sets what each object should play, twin or the game's own, every frame
  after the plate's update.  Magic's default 005ff0 is the field body's own colour: no twin at all.
* **A record's key index is signed 16-bit to the game** (`movsx esi, word [rec+6]` at 1a8871, then used unsigned):
  an index of 0x8000 or more reads far outside the table.  The twins' keys are at 0x4000.. in g_sc_keys (256 twins
  of up to 32 keys; the file has 3749 keys).  Found by t_colours drawing a tinted plate, before it reached the game.
* The row under the cursor.  The battle body's inside is three black quads of the frame sprite, which cursor_body()
  turns into the gradient.  The field body lays sprite 2 (object 6: black in control 3, the glow in 4) over that,
  so the gradient never showed in the field.  For a list row under the cursor `row_fill` gives that sprite's
  private quads the gradient's texels and the tint turns its black into the list's colour; back to black when the
  cursor leaves.  (The four main entries are as they were: gradient in battle, black inside in the field.)
* D-Link rows: the art's blue is kept; `DLinkRowsBright` replaces the 3c3c3c key by 808080 (rule with a `from`
  colour, so control 5's e1dc00 and the keyless control 0 are left alone).
* Test `t_colours`: records and key tables of every case, and the colour word the game's draw function sends
  (battle a100dfe5, Items a133cb00, Magic a1f46000: A B G R).  Mock-up: scratchpad col/run2.py.

## Crash log: which 2D instance (src/main.c l2d_crash_report)

* First crash seen in play (build 10574bd, 5.4 minutes into a session, in a fight): access violation at rva 4f0195
  (`cmp dword [rdx+0x10], 0x2f02eb5` in 1404f0180, the texture bind) with rdx = 74f111e420036048, called from
  14010ccb0 <- CD2SeqCtrl::Draw 1401aaea0 [1ab025] <- CD2LayCtrl::Draw 1401a2bb0 [1a311a] <- the draw list
  [0f5140].  So a node of some layout drew from a block (CD2SeqData) whose current texture (+0x90, a CRsrcTM2 the
  game can swap with 1a84e0 / 1a8530) had been freed.  The log could not say which layout: the registers were gone.
  The mod's own layouts only draw from bc01_00, whose texture every command plate of the game uses too, so it is
  probably a game instance; whether something the mod does lets it outlive its texture is open.
* Since then the exception filter searches the stack for controller objects (first word = vtable 6418b8 CD2LayCtrl or
  641dc0 CD2SeqCtrl) and logs each: handle, the mod's own handles for comparison (mod_own_handles), and per node the
  block name, current / original texture, substituted texture id.  The node whose texture's native pointer (+0x28)
  equals the faulting rdx is marked.
* Second time (same place, build with the report): the report itself died.  `IsBadReadPtr` works by faulting, the
  handler was entered again for that fault (it was reading past the end of the stack: only 0x5b0 bytes were left
  above rsp), six times over.  Now: reads are checked with VirtualQuery, the stack is read up to the thread's stack
  base only, and a fault during the report is not reported in turn.
* What the two crashes have in common: Terra, Castle of Dreams, the moment the first forced fight is won; the same
  call path; and the same "texture object" **74f111e420036048** although the game sat at another address each time.
  So it is not a freed pointer but data: the block's current texture (+0x90) pointed at memory that holds some
  other file's bytes by then (the resource arena is laid out the same way in the same situation).  It took the
  path at 10cd0d: image+0x40 non-zero and the float at +0x48 below 1.0, also not what a registered image has.
  No raw TIM2 header in the files at hand has that value at +0x28 (they look like 0000000224000000).
* Which block is still unknown.  Blocks that get a replacement texture (1401a84e0): the player gauge's face
  (gauge_01:1), the D-Link faces, the item / level-up window (itemget_02:1), the escort gauge (msn_00:1 / :2, layout
  1 of msn_00.l2d, CFriendGauge 14020ced0 - a child task of the gauge root that nothing deletes before the scene
  jump; it is hidden by the player gauge's update when the HUD goes off and shown again by 14020b5f0(0) when the HUD
  comes back).  The mod loads no files, swaps no textures and does not write the HUD-off flag.

## Texture guard (src/guard.c, `[Safety] TextureGuard`)

* **Off by default since the owner asked for it to be taken out** (the game felt slightly laggy; whether the guard
  is why is not measured - it is the only thing the crash fix added that runs for every 2D node every frame).  With
  it off the two draw vtable slots are not patched at all.  What stays is the fix itself (`menu_shutdown` from the
  gauge's destructor) and `l2d_live` in the modules' own "is it alive" tests.

* CD2SeqCtrl's draw (1401aaea0, vtable 641dc0 slot 3 - every node of every layout and every standalone sequence
  goes through this slot; a layout's draw 1401a2bb0 is vtable 6418b8 slot 2) is entered through `guard_seq`.
  Only when the game is about to bind (timer group drawn [8f88020 + group], drawing on [8f8802c], objects > 0): the
  block must be readable, and if its image has a size (+0x3d / +0x3e, the game's own test) the texture objects at
  +0x28 and +0x40 must be addresses that can be read (as far as 1404f0180 reads: the mark at +0x10 and, if it is
  02f02eb5, +0x70).  Readable = VirtualQuery, remembered per page in a small table that is emptied every 65536 draws.
* Not readable: if the block's own texture (+0x98) is sound it is put back in +0x90 (the replacement's resource id
  at +0xa0 stays, so the game's own restore still releases it) and the node is drawn; otherwise the node is not
  drawn that frame.  A draw the game could have done is never changed.
* The log then names: the layout (handle, file, node id) or the sequence, the mod's own handles, the block, the
  resource of the block's file and of the replacement texture (state, group, users, address, size), the 0x50 bytes
  now at the texture's address and which loaded file that address belongs to now (resource lists [8f7e328 + type *
  0x20], walked under the resource lock [8f7dc10]+0x58).  At most 24 reports, one per node and texture.
* Test `t_guard` (the decision on made-up blocks, with the value of the two crashes); `t_draw` runs the real draw
  through the patched slots.
* **Found** (third run, the guard's log): the nodes were the mod's own - the four menu entries (layouts of data
  handle 65 = bc01_00.l2d), a Command Style offer and its timer bar (sequence of gauge_01:0).  Their blocks were
  "not a data block any more", the files' resources (ids 2ff, 2fe) gone, and the textures' addresses belonged to
  a sound file (se1742.scd, group 6000) by then.  So at that moment the game destroys the player's gauge and
  command objects and frees their files (p00common's 2D files) **without** the "destroy every instance" that a
  scene jump does first, and without regard for the references instances hold on the file (the question left
  open in l2d_api.md section 6: a group free ignores them).  The gauge's destructor only removed the MP bar; the
  entries and the offer are looked after from the gauge's update (menu_frame), which no longer ran, so they stayed
  alive and visible over freed data.  The mod's bug, not the game's.
* Fix: the gauge's destructor hook calls `menu_shutdown` (menu.c: entries, shortcut rows, list header; style.c
  `style_shutdown`: offer plate and timer) while the files are still loaded.  Second line, guard.c: a layout or
  standalone sequence whose data handle (+0x1c) is no longer registered is not drawn (`data_gone`, one pool lookup
  a draw), and `l2d_live(&handle)` in every "is it alive" test of menu.c / style.c / mp.c destroys such an instance
  (the destroy path looks the data handle up before using it [1abcf0, 1a3cd0], so that is safe) and clears the
  handle, so the module makes a new one.  Test `t_gone`: the real runtime, file unregistered [1a5f20] under a live
  layout and sequence.
* Cost of the guard.  One launch of the fix build was "insanely laggy" from the first frame of play, the next
  launches were not, and the log showed no reports - so nothing was being destroyed and re-made, and the diff to
  the guard-only build is a few pool lookups.  Most likely (not measured on the PC) the readability test: it was
  VirtualQuery behind a 256-slot page table emptied every 65536 draws.  VirtualQuery also sizes the region around
  the address page by page, the images are in the game's resource arena (inside the exe image, one huge run of
  like pages), and whether two busy pages share a table slot - and so ask on every node - depends on where the
  heap is in that run.  Now: one byte read through ReadProcessMemory per unknown page (2048 slots, hashed, never
  emptied), and `g_seen` remembers per block the image and texture objects found sound, so an unchanged node costs
  three compares and no question at all.  `TextureGuard=0` takes the draw hooks out entirely; the fix above does
  not depend on them.
* Default history: on when written, off while the user tested the menu_shutdown fix alone (and a slight lag was
  being looked into), on again at the user's request as a safety net.
* Handles cannot be mistaken for one another: a freed slot's id grows by 0x400 (l2d_api.md), so a stale handle of
  ours never names a newer game instance.

## OpenKH Mod Manager package (modmanager/, tools/package.sh -> dist/BBS-KH2-Style.zip)
- The package is the same DLL under the name dll/bbskh2.dll plus dll/bbskh2.ini, two `copy` assets in mod.yml.
  The Mod Manager copies them to <CompiledModPath = .../mod/bbs>/dll/, and Panacea (the mod loader, dbghelp.dll
  in the game folder) loads every DLL in <mod_path>/<game>/dll/ at start-up [OpenKh.Research.Panacea
  Panacea.cpp LoadDLLs; the patcher's own special case is for "dlls/", which Panacea does not read].
- main.c already covers this: inert in the other games' exes, one copy only (BBSKH2_LOADED), settings from
  next to the game exe if there is a bbskh2.ini there, else from next to the DLL.
- Works only with the mod loader; a build that patches the pkg files would just store the DLL as a dead file.
- bundle.c also replaces the first Revenge Value build of Factory.lub (10208 bytes), so that the old mod left
  enabled in the Mod Manager does not hide the bosses added later.
- Not tested through the Mod Manager by me (no access to the user's OpenKH folder).

## Camera distance and tilt limits ([Camera])
- Player/boss camera files (PCam?000.bin, BCam????.bin, 112 bytes): header (FOV at 0x8), then two 0x30 chunks
  (Normal at 0x10, Extended at 0x40) with eye at +0x10 and aim at +0x20.  `Distance` moves the eye towards the aim
  point after the KH2 Camera bytes are applied (FOV and look-at unchanged); the result's crc is remembered so a
  reloaded resource is not scaled twice.  Default 0.9.
- BBS tilt clamp: FUN_14022d790 stores -30 deg (0xbf060a92) to camera+0x344 and +45 deg (0x3f490fdb) to +0x348
  (instructions at 22dae3 / 22daf0, immediates at 22dae9 / 22daf6); FUN_14022c0b0 clamps the stick tilt offset
  (+0x2b0) so base pitch + offset stays inside them.  Positive = camera above looking down.
- KH2 (verified in kh2.exe): the field camera reads the pad only for yaw (pad bits 0x14/0x15, +/-3 deg/frame in
  1403a9250 / 1403a70a0 -> 1403b7a80) and for movement direction (1403a8fa0).  The pitch component of its angle
  (+0x680) is only ever set by scripted/auto code, never from the stick.  The +/-45 deg found at gm::CAMERA+0xe2c is
  ACTION_NMGUN (a minigame camera's yaw limit, pitch +/-15 there).  So KH2 has no wider tilt range to copy;
  `PitchLow`/`PitchHigh` stay at the game's values unless changed.
- Tilting down on flat ground the camera's map ray (look point -> eye, FUN_1401ffa90 in FUN_14022b110) hits the
  floor at about -10 deg and the eye is pulled in to the hit point; past that, more tilt slides the camera along the
  floor towards the character.  The -30 limit stopped that ~1.2 m out, so PitchLow defaults to -60 (imm 0xbf860a92).

## Combo Master (src/combomaster.c; `[Combat] ComboMaster`, `ComboMasterName`, `ComboMasterHelp`)
- Asked for: KH's Combo Master as a new ability with a single entry like EXP Zero, unlocked by default.
- Abilities in the game: command ids 0x1c4..0x1e1, exactly 30 - the size of every table they live in: the save's
  u32 per ability at save+0x18cc (`14041d800`; read as save+0x11bc+id*4), the player's count per slot at pl+0x4a3
  (filled each frame by `1402218b0` from bits 0-2 through `14041d810`).  The u32: bits 0-2 in effect, 3-5 level,
  6-8 copies learned (`14041fb70`; max per id at `140811083 + id*0x1e`, EXP Zero 1), 9-13 copy on/off
  (`14041d2e0(id, copy, mode)`, mode <0 flips), 14-15 0 "???" / 1 new / 2 seen / 3 known (`419380` sets new,
  `41c5f0` turns seen into known on leaving the menu).  No free id inside the block, so a 31st cannot be stored there.
- The new one is id 0x1c3 (ABILITY_KIND_None: empty name and description in CT00500 / CT00100; the code that loads
  0x1c3 as an immediate uses it as a layout sequence number, not a command).  It exists only where an ability is
  seen and switched, the camp Abilities menu (CCampAbility):
  - list `3f1ce0` (callers 3f2979, 3f2f55, 3f39a6): entries of 0x10 at menu+0xa8, room for exactly 30: menu+0x288
    holds the 7 on-screen rows' positions (3f24d0 `lea rdx,[rbx+0x288]`), then the row objects at +0x2c0 / +0x2f8.
    The first build counted room for 41 and put a 31st entry there: the row positions overwrote it and moving the
    cursor onto it crashed (3f26ae, reading its u32).  EXP Zero is listed only on Critical (`140360150` = the
    difficulty byte 150fa0881 == 3), so the list has 29 entries elsewhere and 30 on Critical - no room there.
    The fix that followed makes room: the row positions (7 x 2 floats) are only ever reached through three
    `lea reg,[menu+0x288]` - 3f2f60 (setup loop, 1a6880 fills them), 3f2644 / 3f2657 (cursor, passed to 4283c0 /
    428800) - and nothing else in the menu (3f0000..3f4000), its base class (42a000..42c000) or those helpers touches
    +0x288..+0x2bf; the 0x1e constants there are the constructor's first count and 3f1ce0's loop over the 30 ids.
    hook_ctx at the three sites points them at a buffer of the mod's, so the list holds 31 (up to 33 would fit).
    The append only goes past 30 when all three hooks are in.
    count at +0x94; +0 u32*, +8 id, +0xa group (0 Prize 0x10, 1 Stats 0x0b, 2 Support 0x11),
    +0xb first of group, +0xc/+0xf level, +0xd learned, +0xe possible.  After each call the entry is appended to
    Support with its own u32 (0xc000 known | one copy learned | on bit), +0xd = +0xe = 1: one pip, like EXP Zero.
    Off until switched on, per save (below).
  - row name: `3f1b20` reads the command table's name pointer (140814908 + id*0x18) - set at install and again when
    the names file is loaded (mp.c's CRsrcCTD hook calls combomaster_texts after the game's).
  - description: `14041d880` answers only 0x1c4..0x1e1; its calls at 3f2711 / 3f3562 are hooked.
  - switching: the call of `14041d2e0` at 3f37f0 (cVar 3 in `3f32a0`, after the "learned" checks) is hooked: for
    0x1c3 it sets or clears the choice; the list is then rebuilt by the game (`3f2970` -> 3f1ce0 -> appended again).
  - where the choice is kept: in the save, bit 23 of EXP Zero's u32 (the save in memory is 150fa3d08 [1403600f0],
    so 150fa3d08 + 0x18cc + 5*4).  Every user of these u32s masks its own fields: bits 0-5 (422de0 recompute),
    6-8 / 18-20 (41fb70, 41e090), 9-13 (41d2e0), 14-17 (419380, 41c5f0; 41de10 returns only 14-17); the save
    conversions (1bdbc0 / 1c04a0) copy the whole u32.  So bit 23 is saved and loaded with the rest, is never cleared
    by the game, and a new game starts with it 0 (off).  The first builds kept one `ComboMasterOn` in the ini for all
    saves: switched on in one save, it showed on in every other (reported: a late Aqua save off, an early Terra save
    on when its menu was first opened).
  - detail page (confirm, 3f3659 `mov rax,[rbx+rax*8+0xa8]` before the `test [rax],0xc000`): `3f1550` and the
    300-byte table index by id-0x1c4, so for 0x1c3 the hook goes to the game's own buzzer path (3f3669).
- The effect: the normal combo's window.  The next hit can only be asked for in `14021c140`; for the Attack category
  that needs pl+0x320 bit 0x20 "connected" (cmd+0x60 & 0x1000 aside), set only by the weapon hit handler
  [293d9d / 293dee] or a fired bullet [229021].  Normal combo (sub-state 5): the window opens with 0x318 |= 0x40, valid
  until frComboEnable (+0xc); a queued command starts at frChangeEnable (+0xd).  The bit also ends the forward lunge
  (228f39 passes "not connected" to the movement call), so it is lent only for the window call at 22902e (rcx = pl,
  xmm1 = frame): ability on, category 1, sub-state 5, not connected, frame >= frMark End (+0x1d, where the swing
  lands; melee records have frTrigger 0) - set before the call, cleared after (21c140 writes 0x320 back from its own
  copy when it queues).  Other readers of the bit (magic states 2674d0 / 2687d0) never see it.
  Same as after a real hit: the open window also takes guard / dodge / other commands, so a whiffed normal-combo hit
  can be cancelled into them (vanilla: nothing until the animation ends).
- Test: `t_cm` (append on a list built like 3f1ce0 from the exe's tables, the switch / description / detail hooks,
  the name through the real names file, the window through the game's 21c140 at frames 3 / 8 / 26, real hit and deck
  attack untouched).  Not seen in the game by me: the menu itself (the list builder needs the save and deck).

## Cure and the big spells a little slower (speed.c; `[Speed] CureRelease`, `BigSpells`)
- Asked for: Cure and the bigger spells felt too quick; slow them a little, Cure still much snappier than vanilla.
- Cure family (Cure, Cura, Curaga, Esuna): CureRelease 0.30 (KH2) -> 0.40 s.  t1 20 / 18 / 22 frames (Ventus / Aqua /
  Terra) gave wind-up factors 2.22 / 2.00 / 2.44; now 1.67 / 1.50 / 1.83.  Vanilla release 0.67 / 0.60 / 0.73 s, so
  still 35-45 % sooner.  The lock after the release stays the game's 40 ticks.
- Big spells (no KH2 counterpart, played at Actions 1.15 before): 0xa6..0xb0 (Faith, Deep Freeze, Glacier, Ice
  Barrage, Firaga Burst, Raging Storm, Mega Flare, Quake, Tornado, Meteor, Transcendence) and 0x88 / 0x8d (Triple
  Firaga / Triple Blizzaga) play at BigSpells = 1.05 from start to end, about 9 % longer than before and still a
  little quicker than the game.  [CommandSpeed] for a single command still wins.  The ticks-based locks after the
  release (Mega Flare 120) are not animation and do not change.
- Test: t_speed (Cure factor and release time, every big spell 1.05, ordinary -aga / Aero / Stop spells not).

## Revenge Value v2.2: the gauge is not cleared (KH2), and armour windows hold
- Reported: Aqua's final Vanitas still easy to combo - he breaks out, but comes back right next to you and you are
  straight back in for another full string.  Asked to look at it for all bosses, not him alone.
- KH2 (kh2.exe): the gauge at +0xd48 is written only by the constructors (1403db840 / 1403db930: 0, cap +0xd4c
  100.0), the adds (1403db730 / 1403dbb90) and the drain (1403db440 / 1403dbbf0, clamped at 0).  The "revenge"
  event (14040e337: flag +0x6c8 bit 4, gauge >= cap -> 1403cac50 with "revenge") does not touch it.  So after a
  revenge the gauge stays at the cap and drains at 1.0 / frame (6 hits a second) while the boss is out of
  hit-stun - during its own revenge action.  Going straight back in, the next revenge comes after a few hits.
- v2.1 cleared the gauge after every break-out (done) and whenever the boss recovered from hit-stun
  (OnReturnDamage).  The second made every combo string start from 0: only one unbroken string of ~10 hits could
  ever bring a break-out, and after one the player always had a full gauge's worth of free hits.
- Now: done() keeps the value and sets idle to the grace (drain from the next frame); OnReturnDamage does the
  same.  Per boss `clear = true` keeps the old clearing - No Heart only, whose slow gauge (grace 120, drain 0.03)
  stands in for his own burst timer.
- The armour window after a forced revenge (iframes) is held every frame: the boss's own states switch "no damage
  reaction" off in their OnEndState (Vanitas' Cartwheel / WarpAttack2 ...), which cut it short before.
- Effect in the loop test (80 hits, one every 35 frames): 11 break-outs for every boss instead of 6 - 9.
- Vanitas (b63ex00) found in the investigation: his break-out at the limit is Warp2 - vanish, reappear 0.5 m behind
  the player (WarpToTargetBack scales the target's direction by -0.5), one slash (WarpAttack2), back to Idling.
  Unchanged for now; with the gauge kept he breaks out again after a few hits when you go straight back in.
- Grace back to 60 frames (1 s, KH2's pace) on request (2026-10-12); the bosses' long idles are to be handled on the
  boss side instead (see the KH2 AI comparison: KH2 bosses wait 0.25-0.75 s between decisions, BBS's 1.5-2 s).

## Boss pace (2026-10-12)
- KH2 boss AI (BDX in obj/B_*.mdlx, read from the PC install): the engine runs the act "idle_time" between decisions -
  random 15..45 frames in nearly every boss (Org XIII, Data versions, Barbossa, Shan Yu...; Xigbar 30..45, Hades
  60..120); walks (move_target) 60..120.  BBS humanoid bosses: Idling 90..120 (Wielders 180+), TargetMove 300..600.
- revenge.lua wraps Entity.SetTimer once (global __BBS_PACE, handle -> boss state) and each paced boss's
  GotoStateSub (to know the state being entered: the FSM sets current_state only after OnBeginState).  Idle states
  (name has Idling / Waiting, or Hovering): v * aggr, floor 45, values <= 45 untouched.  Walk states (Move$ / Walk$ /
  ^Wander / ^Approach): capped at walkCap s.  Allies (wielders with friendFlag 1) are skipped; a handle handed out
  again clears its entry in EntityFactory.Create.  Braig counts his WaitIdling in self.timer: cfg.paceFields.
- pace = false: b01ex00, b81vs00, b85vs00, b12ex00 (superbosses, on request) and Hades (b01he00 / b80vs00: his Move
  sets 20 s while AttackFlag is 0, tied to the IceTianHandle helper).  Terra-Xehanort's own AI (b52ex00) has no SetTimer idles.
- [Bosses] Aggression / WalkCap: the Lua carries markers 9001.5 / 9002.5 as float constants; bundle.c copies
  rv_factory into rv_buf and writes the ini values over them (each must be found exactly once).
- Hook (b01pp00) picks his attack first and walks to its range after (TargetMove pops the attack in range or on
  time-out).  cfg.setup gives his instance its own states table with a TargetMove whose time-out short of nearDist
  clears the stack and goes to Idling with idlingTimer 0: his Idling decides by range (close: SelectAttack, mid:
  Step, far: PresentBombLarge).  The other paced walks either come after the attack (Vanitas, Eraqus' Wander) or
  re-decide on time-out already (Zack's Approache -> Move, wielders' Move -> BattleIdling).

## MP Rage (2026-10-12; mp.c rage(), `[MP] MPRage`, `MPRageRename`) and MP Haste doubled
* Asked for: the second "MP Haste" (the game's Attack Haste, 0x1cf, slot 12) becomes KH2's MP Rage; the first (Magic
  Haste) doubled: `MPHasteBonus` 0.05 -> 0.10 a copy.  `AttackHasteBonus` is gone (Attack Haste no longer speeds
  the charge).
* KH2 FM, verified in its exe and data: abilities are summed into a stats block by 140401730 (MP Rage 0x19c adds
  sstm+0x150 to block+0x5c; sstm is 03system.bin pref/sstm, "Damage Aspir" = 75.0 at offset 336 in the PC
  files; MP Haste / Hastera / Hastega 0.25 / 0.5 / 0.75 at 288..296).  On damage, 1403d5600 / 1403d5e50:
  unless the MP charge runs (status+0x1c0 > 0, 1403c1d10), MP += (int)(damage / max HP (status+4) x that sum),
  through 1403d3cf0 (capped at max MP).  The "100 in the original KH2" is the Ultimania's figure (not checked).
* BBS: the player's HP is s16 player+0x4a0, max +0x4a2 (the vtable getters 140219e80 / 140219e90 behind
  Player.GetPlayerHP / GetPlayerHPMax, slots 0x78 / 0x80 of every CPlayer* vtable).  The mod watches it once a
  frame in tick(): HP lost since the last frame, with no MP charge, gives (int)(lost / max x MPRage x copies).
  Hits landing in the same frame count together (a fraction more generous than KH2's per hit).  Any HP loss
  counts, Poison ticks included (KH2's hook is its damage path, which may differ there).
* Test: `t_rage`, and the texts in `t_haste`.  Not seen in the game by me.
* Weakened on request ("a full stack gives a quarter of your MP back if you took 100% of damage"): `MPRage` is now
  the percent of max MP a full HP bar lost gives at the most copies the ability can have (140811083 + id*0x1e:
  5 for Attack Haste), 25 by default; n copies give n/5 of it.  Kept with its fraction (g_mp is a float), so small
  hits are not lost the way KH2's truncation loses them.

## Command cancel (2026-10-12; speed.c cc_*, `[CommandCancel]`)
* Asked for: deck commands only (attack / magic) can be cut short at the end of their animation into anything
  (another command, the same one, Attack, guard, dodge, jump, shotlock); nothing pressed = the animation plays out;
  finishers, base combo, items, team attacks and everything else untouched; repeated-press commands only once no
  press can continue them; a press shortly before is remembered; per-command delays in the ini (frames, >= 0).
* "Over" = the last hit window (body and weapon controllers, all windows' off frames, also the ones not closed yet;
  a window "on to the end" = only at the animation's end) + FollowThrough, and past frMoveEnd / frMarkEnd /
  triggers; spells without body windows: t1 + FollowThrough, at least frChangeEnable; a spell already in its idle
  pose (the 40 / 120-tick lock) is over.  Then + the command's delay.  BufferFrames (8) before that: presses held.
* Judged only on frames where the game itself waits for the command's last animation: the end-test hooks
  2246c0 / 224476 (deck attacks), 2253ff (dashes, surges, Aerial Slam), 26825f / 26828a (magic recovery, sub-state 4)
  call cc_seen.  Covered: 5b 5c 5f 60 6a-6d 6f 71-74 76-78 81 and the spells that end in the shared recovery
  (all but 9f-a1, a6-a8, aa, ab, ae-b0).  Not covered (own end code): 5d 5e 61-69 6e 70 75 79-80 82 and those spells.
* Mechanics: 220b1d (after the state function) sets pl+0x318 bit 0x40 on those frames, so the command object makes a
  request of any button (deck needs exactly 0x40 [233d0a]); 2206f8 (call 21f9f0, the input intake) is wrapped: right
  after it, a request on an "over" frame ends the action with 21c510(pl, -1, 0) - a request taken this frame
  (pl+0x31c bit 0x8000000) survives it [21c510 tail] - and the idle (219200) / fall (263030) state that runs next in
  the same update dispatches it through 2176b0.  Early presses: the request bits are taken out of pl+0x31c and held,
  0x8000000 kept set every frame (so a natural end keeps pl+0x34c), and put back once over (or once the action has
  ended by itself; dropped if the player is hit meanwhile).  Requests the action's own 21c140 window would take
  (its accept bits that frame: 0x40 all, 0x80 Attack / square) are left to the game; a vanilla-queued command
  (pl+0x320 & 0x80) wins.  Jump in the air is left alone.
* Test: `t_cancel` (fake player and controllers, the end call stubbed).  Not seen in the game by me.
* Cure, Cura and Curaga (92-94) taken out on request: they are never cut short.

## D-Link gauge after a link (2026-10-12; mp.c link_end_hook, `[MP] DLinkGaugeAfter`)
* Reported: D-Link for full HP / MP, revert, one hit, D-Link again.  The BBS gauge (gauge+0x60, 0..100) is both the
  "ready" meter (a link needs 100) and the link's time (it drains while linked); ending early leaves the time on it.
* KH2 (exe): status+0x1b1 drive bars (+0x1b0 the partial bar 0..100, +0x1b2 the maximum); entering a form
  (1403c17c0) refills HP and MP and puts the form's own time on +0x1b4 / +0x1b8 ((level + 3) x sstm Drive Time);
  the cost is taken from the bars by 1403c2780 (bars - cost; the partial bar is emptied too when the gauge was full
  or short).  A revert throws the form time away; the bars stay spent.
* Here: both calls of 208390 (end of the gauge's linked mode) in the style change back to normal 28a950
  [28ac09 revert / run out / forced, 28ae3d D-Link finisher] are wrapped: if a D-Link was active (flag 0x200, not an
  illusion 0x8000), after the game's own end the gauge is set with 20ac70 (SetDLink, also the HUD state) to at most
  DLinkGaugeAfter percent (0).  Test: `t_link_end`.  Not seen in the game by me.

## Special commands (team attacks) and the Attack lockout after them (2026-10-12; menu.c special_pad / special_icon / uncover_attack)
* Reported: Burst of Faith (with Mickey) "shows an X prompt"; after it, Attack does nothing until the cursor moves.
  Traced in the game (menu.c trace_prompt, debug only): the offer (1402790f0: pl+0x6f4, pl+0x318 bit 0x400, timer
  pl+0x704) is taken at 2738c9 by 140273030(pad, 3) = square (index 0 triangle, 1 cross, 2 circle, 3 square), its icon
  over the player (bc01_00 seq 0x771/0x772/0x76c via 140213e50) gets its button text from 140214040's table at
  646a5c (f567, f564, f565, f566 by kind; 3 = f566 square).  The press made state 0x1d; Burst of Faith (274f40)
  shows the prompt plate with 0x141 (cmd+0x60 0x40000, f564) for its mashing, which is the confirm button [27506c].
* With ReactionButton the offer is taken with triangle (n 3 -> 0 at 2738c9) and its icon shows triangle (kind 3 -> 0
  at its two offer paths, 27908f / 2794ee: 140213e50(icon, 2, handle, 3)).  The mashing stays on confirm.
* (2026-10-13) Was at both calls of 140214040 (213f55 / 214a40) at first: those are the game's general button-icon
  routines.  The random-button prompts inside commands (288a10..: pl+0x334 = random 0..2, pressed with 272c20
  triangle / 272860 confirm / 272760 square, icon kind 1 << n - 1 = 0, 1, 3 via 288b0b / 288b72) were repainted
  triangle when the game wanted square, and a triangle press failed them ("Absolute Zero / Sonic Shadow / Air Dive
  QTE sometimes drops").  Found from the log + code: no follow-up, offer or walk-out was involved.
* Lockout: the plate's close (140237090(cmd, 0)) uncovers the Attack plate (1402376b0 had put it in state 2) only
  when no finisher is available (cmd+0x60 bit 0x20000) - the game's finisher plate would take the Attack button.
  Here the finisher is style.c's own prompt, so the Attack plate stayed covered (type 1 is "stable" only in state
  < 2, 1402047f0) and the game's Attack part did nothing until the finisher offer ran out ("finisher: not taken";
  moving the cursor only happened to take that long).  After every command update with no prompt up, a covered
  level-0 Attack plate is uncovered with 140205890.  Test: `t_special`.

## Boss HP (src/mp.c, `[BossHP]`)

* A boss's max HP is the float at `.epd + 0xc`, taken as is for names starting with 'b' (normal enemies: x the
  level row's `+8` from `1402cef40`); no difficulty scaling.  Written to `enemy+0x23a` (max) / `+0x238` (current) by
  `1402d0700(ent, .., .., .., slot, setHp)` (.epd at `ent[0x49 + slot]`; called at 2d2dd0 2d2e24 2d528e 2d52b4
  2d52d2 2d52f2) and `1402d2ec0(ent)` (.epd at `ent+0x250`; called at 2b7dfe).  The calls are wrapped: after the
  game's own write, a listed boss gets percent x the value - only when `+0x23a` still holds the .epd value, so
  nothing is scaled twice.  No boss script sets a max HP of its own (they only read GetHpMax).
* Default ramp: opening bosses 100, early-mid 110, mid 120, late worlds and story finales 130, Final Episode 125.
  Not listed: superbosses (b01ex00 999, b12ex00 200 at x0.5/x0.25 taken, b81vs00 1000 at x0.5, b85vs00 1500),
  Dark Hide b02ex00 1650, Mirage Arena (b*vs00), Disney Town (b*dc00).
* EXP Zero's minimum (`1400d2960`, called at 2d2510) has its boss row at 200..1500 HP; the wrapped call looks a
  boss above 1500 up as 1500.
* Test: `t_bosshp`.

## Revenge v2.3: limits ramp, answers are attacks, armour until idle

* Limits (bosses.lua) ramp like KH2's Data fights (Data Roxas: karma limit 75 against story Roxas's 100 -
  B_EX390 `trap_enemy_set_karma_limit`, chosen by spawn argument 2, eh21 b_80 vs b_40): opening bosses unchanged,
  b10ex00/01 9, b32ex00 9, Zack / Hades (story copies) 8, E221 7, Hook / Peter Pan 8, b10ex02 8, finales 7-7.5
  (b11ex00, b63ex00, b40ex00, b30ex00 7), Eraqus 12 -> 9, Terra-Xehanort b50/b51/b52 8 -> 6.  Mirage Arena copies
  (b60vs00, b80vs00) and superbosses keep theirs.
* Answers: keyblade wielders (b60 script) at the limit no longer roll their own dodge (fire 0.999); the counter
  pushes their Combo (share `attack`, default 0.6; Terra-Xehanort 1) or EvasionAction.  Braig: Escape, then
  DashShoot (40 %) / RoundShoot (35 %).  Eraqus: Guard always into Kagerou.  E221: Electroshock 75 %.
* Armour after a forced break-out for every configured boss (RV.iframes 45 default; superbosses 0): held until the
  boss is in an idle / walk state again (after 6 frames), at most RV.armorMax 180 frames.  Not cut at a fixed time
  any more, so a boss state that holds "no damage reaction" itself (wielder Combo) is not cleared mid-attack.
* KH2 survey (motion triggers, range trigger 27 "hitbox off" / 19): Roxas and Data Roxas (same B_EX390) have none;
  a few bosses have whole-move "can't be hit" on warp / vanish / special moves; trigger 8 (no damage reaction) unused.

## Revenge v2.4: KH2's uninterruptible moves (`armorStates`)

* KH2 boss AI registers every move with `trap_act_table_add(table, name, flags, code, ...)`: low 16 bits 100
  (idle / movement), 200 (attacks), 300 (revenge, dead); bit 0x10000 on revenge answers, desperation attacks,
  warps and big specials (Roxas atk_*_revenge / atk_final_*, Axel *_revenge, Saïx dances, Xemnas warp_target_*,
  most of Lingering Will's sword moves); never on normal attacks.  Read as "cannot be interrupted once started"
  (inferred from the pattern; KH2's engine is not available here).  KH2 atkp also has an attack type "pierce armor".
* BBS states that switch EnableNoDamageReaction on: wielders (all commands), b52ex00 (all attacks), Eraqus's
  specials, Zack's specials, Braig's sniper / charge / Ultima / inverted shots, Vanitas's warps / Shadow Diving /
  Grand Cross / Ultimate Charge / Dark Splicer.  None: Master Xehanort, Peter Pan, Maleficent.
* `armorStates` (bosses.lua) adds the missing ones; the GotoStateSub wrapper sets no damage reaction after the
  state's OnBeginState and clears it before the next state starts (unless revenge armour runs); a number = only the
  first frames (OnUpdate counts down).  b63ex00 SuccessionAttack2 24 frames.  Test in extra.lua.
* Braig (instead of the reverted escape-roll change): his Escape warps with WarpToTarget(2, 3.5) - a random
  offset of 2-3.5 m on each axis from the player, i.e. right next to you (DashShoot the same, WarpShoot 4-6).
  setup() wraps WarpToTarget: during Escape at least 8-11 m (his own loop clamps to the arena's MaxDist).
  DashShoot added to his armorStates (his last flinchable attack).
* Bug (Vanitas vanished / misplaced in a fight): Warp1 / Warp2 set alpha 0 and switch off lock-on, damage and body
  collision; only WarpAttack1/2's OnEndState switch them on again.  The watchdog (or a counter after a failed fire)
  could GotoState("Cartwheel") out of a warp or ShadowDiving, leaving him invisible and unhittable (or under the
  floor).  The HP watch could arm the watchdog from damage taken during a warp.  Now: no forced counter while the
  boss is in a state whose name holds Warp / Escape / Diving / Disappear / Teleport / Ride / StyleChange / Appear /
  Dead / Standby / Hide / Sink / Fly / Goes_away / Fall / Breakdown (RV.unsafeState; the watchdog waits until he is
  back on his feet), and hidden HP loss does not count while the boss cannot flinch.  Test in extra.lua.
* Vanitas (Ventus's final, b11ex00), last phase: with Ventus's Vanitas D-Link (COMMAND_KIND_DLink17) running in
  the air battle, his OnDamageBefore returns 0 at once (no escape) so he stays in place for the finisher.  The
  revenge layer still counted those hits and forced vanitasCounter (Cartwheel), moving him away from the
  finisher.  His cfg `active` is now false while airBattle and DLink17: every hook passes through, and the
  watchdog / revenge armour / move armour still pending are cleared.  Boss only, that phase only.  Test in extra.lua.
* Masked Vanitas's keyblade ride (b10ex00/01/02): RideWaiting switches no damage reaction on and nothing clears it
  until he gets off (StyleChange / Cartwheel OnEndState) - vanilla, the whole ride is unflinchable, attached to the
  keyblade (RideKeyBlade AttachCoord).  armorStates RideKeyBlade / KeyBladeRush cleared it when they ended, so hits
  reacted and their knock-back pushed him off the keyblade while RideMode carried on ("floating").  Removed.  Instead
  (rideSetup / rideHit, his config only): hits taken in a ride state count (once a frame, `vanilla` hook); when they
  reach his revenge limit, his RideMode update ends the ride his own way (EndRideMode, StyleChange pushed,
  BackhandsSpringJump - what it does when the ride runs out).  RideWaiting resets the count.  Test in extra.lua.
* Finisher prompt name (style.c finisher_name): the game's plate rule prefers the stored name at PlayerData+0x1b0,
  which is the normal finisher's.  In a Command Style (cmd+0x1a8 > 0) the finisher is the style's own, so the prompt
  now shows that command's name (reported: Spellweaver's finisher showed "Gold Rush").  Test in t_style.
* MP bar during an MP charge (mp.c bar_frac): the pink bar now starts full and drains as the charge runs (1 - charge),
  as in KH2, instead of filling up; then the bar is blue and full.  Display only - the charge itself is unchanged.

## Negative command-cancel delays (2026-10-15; speed.c cc_after / cc_config)
* The recovery-speed experiment (f58f6f4) was reverted on request; instead `[CommandCancel]` delays may be negative
  (down to -120): "over" moves that many frames earlier, into the last hit window (asked for: a cut-off hit is
  fine).  Still judged only on the end-test frames of the last animation (so never before it starts; r clamped
  at 0), and for spells never before t1 + 1 (the spell goes off first).  Test: in `t_cancel`.  Not seen in the
  game by me.

## Release (2026-10-15): debug-only test aids removed, tuned cancel delays as defaults
* Removed: the F9 [CommandCancel] reload and the QTE investigation log (state_log, follow-up press log,
  style_offers_up).  [CommandCancel] defaults are the user's tuned values: Quick Blitz / Blitz / Fire Surge /
  Barrier Surge / Thunder Surge -5, Aerial Slam / Fire Strike / Confusion Strike / Binding Strike -2.
  Known: Blitz's value has no effect yet (repress gate waits for its follow-up window, ~frame 38; see the Blitz
  investigation - a fix would apply the delay to that gate too).

## D-Link row names, prompt under the lists (2026-10-15; menu.c plate_update_hook)
* Reported: D-Link rows' text sits further left than Magic / Items rows'; Magic and Items rows draw behind the Save
  prompt (D-Link rows draw over it).  From bc01_00.l2d: d_comand's name node (id 0) is at -1, l_comand's (id 2) at
  -3, the text at +17 in both controls 1 / 3 - so the D-Link name is moved by DLinkNameX (2) with 1a7ec0 every
  frame.  The prompt plate (type 5) keeps the game's priority (placement table row 4.., set in the plate update);
  while a list is open it is put at 11, under the list rows (12 / 13), over the entries (5 / 7).  Not seen in the
  game by me.

## Player outfits -> the separate "BBS Armor" mod (2026-10-15)
* The outfit research (model 1..15 = character + 3 x outfit p0x..p4x, setter 26c720, room entry 1ed3f2 / 1ed44d,
  save byte 150fa0887; outfit 1 armor, 2 / 3 Rumble Racing, 4 armor without helmet) and the Items > Armor entry
  were moved out of this mod on request: they live in the stand-alone BBS Armor mod (its own DLL, bbsarmor.dll /
  bbsarmor.ini; local source /home/claude/bbs/armormod).  It touches none of this mod's sites (the 10 calls of
  26c720, the 2 of 1ebc00, CCampItemTop's update and CCampItemCmd's input / destructor slots) and keeps its choice
  in bits 24-25 of EXP Zero's save u32, next to Combo Master's bit 23.

## 1.7: D-Link chosen plate, world map free flight (2026-10-15)
* D-Link list: on choosing a link the list closes and the chosen plate plays control 5 (the cursor plate's places:
  text offset 27 vs 17, hearts without the -10) - its name and hearts jumped 10 right.  menu.c link_row_places:
  every frame, open or closed, name node 2 at -3 + DLinkNameX (- 10 in controls 0 / 5) and hearts 3 / 4 at 116 /
  128 (- 10 in controls 0 / 1 / 5); control 5 also gets link_cursor_body.  Test: in t_cursor.
* World map: the rider's move 4b83b0 asks 4b74a0 (sphere +0x600 against the map collision; a hit on one of the
  route volumes listed at +0x200 sets +0x6a0 / +0x6a4 / +0x6a8) twice, at 4b8549 / 4b8647; a route found makes the
  move follow it (4b86d3..).  worldmap.c: both calls answer 0 ([WorldMap] FreeFlight).  Landing at a world is the
  landmarks' test, untouched.  Test: t_worldmap.  Not seen in the game by me.

## KH2 armour on every boss attack (2026-10-17; bosses.lua armorStates, revenge.lua OnUpdate)
* KH2 check (kh2.exe + the game's own KH2 files): a boss's flinch is not decided by damage.  Animation range trigger
  36 (14040d810 case 0x24) sets a status bit at enemy+0xd14 for a frame span (cleared every frame, 14040e5c0); the
  hit's reaction is remapped through 00battle.bin "patn" (1403ee9b0): bit 1 = no reaction at all, bit 3 = only the
  heavy reaction types, bit 7/8 = push only.  Humanoid bosses carry bit 1/3 from frame 0 over nearly every attack
  (Roxas B_EX390 atk_tate frames 0-240 against a hitbox at 32-39; Data Xemnas every attack); a flinch outside them
  sends Roxas straight into an armoured answer (mode_revenge_boss -> rvg_*).  Open: idle / walk / recovery.
* So every attack of the story humanoid bosses is armoured now (asked for: "keep everything armoured"), added to
  armorStates: Masked Vanitas (b10ex00/01/02) SuccessionAttack1/2, DarkFiraga, DarkThundaga (ride moves are the
  script's); Vanitas b11ex00 SuccessionAttack, DarkThundaga, DarkSplicer1/2 Ground/AirBattle (not DarkSplicerDuel,
  the D-Link duel); b63ex00 SuccessionAttack2 whole move (was 24 frames), WarpAttack2, DarkThundaga; Eraqus
  SuccessionAttack; Braig ChargeShoot, InvertedShoot; Master Xehanort Attack0/1, Thundaga, Blizzaga; Zack (story
  copies) ComboAttack, Hakougeki; Hades (story) FingernailofFire; Hook RushStab, DisturbStab, PresentBombSmall;
  Peter Pan Attack1-4; Maleficent Meteor; Experiment 221 Electroshock, Lightning, ElectricBall, BlasterMode.
  Superbosses and Mirage Arena copies: as they were.
* Moves whose own update switches the armour off part way (Braig ChargeShoot / InvertedShoot, Dark Splicer): the
  OnUpdate wrapper sets it again after the script's update, so no frame is left open.  Test in extra.lua.
* Braig's idle (2026-10-17, "lower his idle time"): his wait between moves is the WaitIdling field timer, rolled from
  .epd IdlLowTime..IdlHiTime (b30ex00 30..90, b32ex00 30..60 frames).  The boss pace cut it x0.4 but never below
  RV.idleFloor 45, so it was 30..45 frames.  New per-boss `idleFloor` (frames); Braig 15 (KH2's shortest wait):
  now 15..36.  The warp inside WaitIdling is unchanged.  Test in extra.lua.
* Boss pace raised (2026-10-17, "increase the aggression"): Aggression default 0.4 -> 0.25 and RV.idleFloor 45 -> 15
  frames, so idle waits land in KH2's 15..45 frame range (Vanitas Idling 120 -> 30, Braig 30..90 -> 15..22.5).
  Braig's own idleFloor is no longer needed (the key stays for per-boss use).  The user's ini: Aggression 0.4 -> 0.25.
* KH2 revenge (checked in the AI scripts): the "revenge" act always starts an attack - Axel atk_burst/assault_revenge,
  Larxene atk_aero/turn/brush/jump, Saix atk_behave/normal_swing, Roxas atk_spotbeam_revenge_air/land; the warping
  bosses warp and attack as one answer (Xigbar move_warp -> atk_shot/drop_shot, Xemnas warp_target_near ->
  atk_counter/combo).  Never a bare escape.

## Revenge answer: get-away, then an attack picked from a list (2026-10-17)
* KH2: a boss's "revenge" act always starts an attack (a warp being part of it).  BBS break-outs were often a bare
  get-away (all three Vanitas: Cartwheel then Idling).  Now, after a forced break-out the boss owes an attack
  (st.owe, done(true)); the first time its get-away hands over to an idle / walk state (cfg.answerAt overrides, e.g.
  Experiment 221's AirMove) the outermost GotoStateSub wrapper goes into an attack picked by cfg.answer instead -
  close or far list by distance (RV.answerNear 4 m; Hook 3.5 m), never the move of the last answer (st.lastAnswer;
  function answers are re-asked up to 4 times with the stack put back).  The return state is pushed for the attack's
  own pop (noRet for bosses whose attacks leave by a literal GotoState).  Armour from the answer's first frame,
  capped at RV.answerArmorMax 300 from its start (st.armorCap; the usual cap 180 otherwise).  An owed attack lapses
  after RV.oweMax 300 frames, outside `active`, and when the boss starts an attack of its own first (armorStates,
  answer lists, cfg.answerClear, names holding Attack / Combo / Shoot).
* Answers: Masked Vanitas (his mode: SA1 or SA2 close, Warp1 / Warp2 far, Dark Firaga / Thundaga, Shadow Diving in
  dark mode; none in the late fight's ride mode, none while Xehanort holds the turn); Ventus's Vanitas: his own
  SelectAttackGround/AirBattle without the wait; Aqua's Vanitas SA2 / Dark Thundaga close, Warp2 / Shadow Diving /
  Dark Thundaga far; Eraqus (Guard without Kagerou, then SA / Rush / Kagerou close, Rush / Oboro / Kasumi / Itsusen
  far); Braig (Escape, then Round / Dash close, Warp / Dash / Charge far); MX (quick warp lands in Idling - param
  101 - then his attack pattern 1 slashes or 2 magic); Zack story (BackJump_Short, then Combo / Hakougeki /
  Climbhazard); Hades story and Peter Pan at once (counter -> st.answer); Hook (Guard / Evade, then Jump Cutting /
  Rush Stab / Disturb Stab close, Rush X-Cutting / Present Bomb far); Maleficent (always the teleport, then Staff
  Attack or her phase's spell); Experiment 221 (flee, then Electroshock - landing first - or Lightning close,
  Lightning / Electric Ball far); wielders (attack share: answer at once, else dodge then answer; Combo /
  short-range command close, the distance commands the copy has far).  Superbosses and Arena copies: unchanged.
* NOTE: bundle_src/Factory_revenge.lub only reaches the DLL through src/bundle_gen.h - after genrevenge.py run
  `BBS_EXE=.../bbs.exe BBS_EXE_COMBO=.../bbs_patched.exe python3 tools/genbundle.py`.  The three revenge commits
  before this one (armour, Braig's idle floor, idle floor 15) had not been regenerated, so the game ran without
  them (only the Aggression value, which the DLL patches into the script, was live).  Regenerated here.
* Tests: extra.lua (each boss's close / far answers, no repeats, armour, lapses on its own attack; Hades / Peter Pan
  at once; Aqua's Vanitas cartwheel -> attack), loop.lua (the owed answer is played out between strings).
* Braig still comboed during his shots (reported after the answer build): his own OnDamageBefore sends every
  shot to Idling on any hit (30 % Escape otherwise) without asking IsNoDamageReaction, so the armour stopped the
  flinch but the script still cut the shot and stood him in Idling, unarmoured.  New cfg.armorHit: during an
  armoured move the hit is kept from the script (runQuiet returns 0).  Braig: Dash / Warp / Round Shoot, Warp
  Center, Charge Shoot's recovery (step >= 4).  Kept: Sniper / Charge Shot charging end after enough damage
  (AttackReleaseHP - a damage break by design), Inverted Shot's 30 % dodge.  The other configured scripts ask
  IsNoDamageReaction first (or only dodge by dice).
* Debug log for the revenge layer: with bbskh2_debug.txt in the game folder the DLL registers BBS_Log (the game's
  lua_pushcclosure 5b9d80 / lua_setfield 5ba4b0 at the Factory.lub load) and revenge.lua logs every configured
  boss's state changes, hits (state, no-reaction flag, gauge), flinch checks, recoveries, break-outs and answers
  ("rv ..." lines in bbskh2_log.txt).  Without the file nothing is registered or written.
* Opening attack (2026-10-17, "start with an attack, then the normal loop"): a boss with an answer list goes
  from its entrance straight into an attack from it (st.opening; the first idle / walk state after Appear, or
  cfg.openAt - Peter Pan's BattleStartState, a hover of up to 500 frames), with no revenge armour, once; then
  its own loop.  Cleared when it attacks on its own first (Braig's entrance Sniper: answerClear) or outside
  `active` (wielders as allies).  Masked Vanitas's late fight opens with his ride as before (no answer in ride
  mode).  Superbosses: unchanged.  RV.opening = false in the stand-in tests except the opening check.
* Pace undone (2026-10-17, "attacking just slightly too fast"): Aggression back to 0.4, RV.idleFloor back to 45
  (Braig's wait 30..45 again).  The per-boss idleFloor key stays (unused).
* Hits on armour no longer zero the idle pause: Vanitas (b10 / b11 / b63) and Eraqus set idlingTimer = 0 at the top
  of OnDamageBefore, before asking IsNoDamageReaction.  With every attack armoured, each hit during an attack
  zeroed it and the next attack came with no pause (log: Ventus's Vanitas Idling 1 frame between attacks).  The
  shielded branch of our OnDamageBefore restores the field.  Test in extra.lua.
* Braig: armour only for the first second of a shot (2026-10-17, his log: a Dash Shoot ran ~10 s, an Inverted
  Shoot ~22 s, all under armour - no opening, no gauge).  As KH2's Xigbar (single shots armoured, long shooting
  strings not): armorStates Dash / Round / Warp Shoot = 60 frames, Warp Center whole; Charge Shoot and Inverted
  Shoot back to the game's own armour (charge until it fires; the inverted phase's start and end).  armorHit now
  also covers a revenge answer's armour (st.armor), and applies only while armour lasts - after that a hit ends
  the shot as in vanilla.  The hold test moved to Ventus's Vanitas's Dark Splicer.
* Braig's Charge Shoot armoured whole again (asked for: never staggered out of it): armorStates true (held through
  the script's own switch-off) and armorHit, so hits never reach his script there - no damage break
  (AttackReleaseHP), no cut at step >= 4.  Test in extra.lua.
* Braig's shot armour per move (asked for, slightly longer): Round Shoot 75 frames (1.25 s), Dash Shoot 90 (1.5 s),
  Warp Shoot 120 (2 s: its warp and first volley).  Charge Shoot whole, Inverted Shoot the game's own.
* Braig, full armour + his own rest (asked for): every attack armoured whole (Dash / Round / Warp / Charge /
  Inverted Shoot, Warp Center; hits kept from his script during them - only the Sniper's damage break and the
  Inverted Shot dodge stay).  braigRest (setup, own states table): 60-90 frames (1.0-1.5 s, random) after every
  attack, unarmoured - his WaitIdling counter gets that length (no paceFields any more); his Idling, entered
  straight from a shot (Dash / Round Shoot used to pick the next one in 0-1 frame), first holds him in his idle
  pose (WaitIdling's own start) for that long, turning to the player.  A hit during the rest (his script:
  GotoState Idling) does not start it over.  Tests in extra.lua.

## bbskh2_boss.ini: KH3-style armour windows, gaps between attacks, cooldowns (2026-10-18; first: Vanitas, Braig, Terra-Xehanort)
* From the KH3 comparison (e_ex311 Vanitas, e_ex313 Terra-Xehanort, e_ex305 Xigbar: armour = ChangeBodyCollReaction
  notifies from the wind-up through the hit, recovery open; no idle waits - cooldowns, combo limits, repositions).
  Asked for: no attack fully open (every one keeps some armour), revenge values and break-outs unchanged.
* File: dist/bbskh2_boss.ini is the source of the built-in values (genrevenge.py puts its text into the Lua as
  RV.bossIniText).  In the game the DLL registers BBS_BossIni(section) (bundle.c; lua_pushlstring 5b9ee0): that
  section of bbskh2_boss.ini in the game folder, else next to bbskh2.ini, read on every call (GetPrivateProfileSectionA)
  - the revenge script asks once per boss created (attach), so edits apply at the next fight.  Keys of the file win.
* Moves: `State = frames | all | vanilla [, cooldown s]`.  frames = armoured from the state's start, counted only while
  the boss is visible (Entity.GetAlpha >= 0.5: a warp does not use it up), then open; where the boss's own script
  armours the whole move (Braig's Inverted Shoot, Terra-Xehanort's Guardian attacks, wielder commands) the armour is
  held off after the window (st.winOff, after the script's update).  Same mechanism as armorStates numbers.
* Gaps (cfg.tempo.idle: "timer" = the idle's Entity.SetTimer, "hold" = our hold skipping its update, {field} = a frame
  field of its own): the first idle after an attack gets Beat frames; after Chain attacks in a row (a move entered
  straight from another counts once) a Reposition move instead of the idle (pushing the idle first for moves in
  cfg.tempo.pop that return through the stack); after a reposition Pause% of the time a pause, broken when the player
  is within PauseNear m.  An idle entered from another idle gets 2 frames.
* Cooldowns: an attack entered while cooling down is swapped (stack back to its depth at the idle, then the revenge
  answer's pick with only ready moves, by distance; none ready = the one closest to ready); bosses with no answer
  for the moment decide again (their idle, 2 frames) up to twice, then go ahead.  Revenge answers and the opening
  ignore cooldowns.
* Values: from the script's own frame tests (GetMotionNowFrame thresholds, in 30 fps motion frames: x2) and the .aac
  hit windows (boss arcs arc/boss/<id>d.arc in bbs_third / bbs_first.pkg; reader /home/claude/bbs/bossdata/aac.py,
  motion use per state: bossdata/motions.py - its motion-index mapping is not settled, the frame tests are).
  Terra-Xehanort's final fight: his Attack0..6 drive his Guardian (b56ex00: ATK0 300 hit 16-20, ATK1 310 wave at 26,
  ATK3 330+331 souls 19/30/38, ATK4 340 hits 23-43, ATK6 360 blasts 19-38).  Wielder commands: first estimates.
* Braig's rest (braigRest, 1.0-1.5 s) is replaced by the beat.  Debug log: "armour window over", "chain .. repositions",
  "pause", "cooldown: .. swapped / decides again / goes ahead".  Tests: extra.lua (ini, window, beat, chain, pause,
  cooldown swap, all on cooldown, no answer, Inverted Shoot held open).
* (2026-10-18) **The game's Lua has no math library** (nor io / os / debug; string works): the log showed "attempt to
  index global 'math'" on every idle after an attack (gaps), and the answers' pick (math.floor) failed inside its
  pcall, so revenge answers / openings / cooldown swaps never came out in the game since they were added (b11ex00's
  own picker and the armour windows do not use math).  revenge.lua now has floor / max of its own; emu.lua runs the
  mod's script without math / io / os / debug, so the tests fail as the game would (the old build: 20+ failures).
  Also from that fight: hits during Masked Vanitas's keyblade ride build no revenge (rideHit -> vanilla), a state
  change to nothing goes to the boss's idle, and an error in our state-change handling falls back to the game's own
  (all logged with ERROR in debug).
* (2026-10-19) Debug: "long action" lines (speed.c long_action_log, from the tick hook, debug only): a player action
  (states 0x10..0x14) running over 2 s gets a line every 10 ticks (state / parts 0x310 0x314, command, PAtk record,
  animation frame and whether it moved, motion flags, pl+0x1a8 speed and ours, dt, 0x318 / 0x31c / 0x320, vy / g,
  air, buttons held) and one when it ends.  For "stuck in an attack, no buttons work" against No Heart (the long
  log gaps in that report were the game paused).
* (2026-10-19) Debug: "frame gap" lines (speed.c frame_gap_log): time between two updates of the local player over
  150 ms (with the player's state), runs of frames over 40 ms once a second, and our own per-frame work over 20 ms.
  The revenge script gets BBS_Ms() (debug only; lua_pushinteger 5b9ea0, ms since load) and logs "update gap" (a boss
  not updated for over 300 ms) and "SLOW update" (a boss callback over 30 ms).  For the No Heart stalls: the log
  showed his updates slowing to ~2 a second for 22 s (during Sonic Impact, twice), the player unable to move.

## Shortcuts kept in the save (2026-10-19; shortcut.c)
* Reported: shortcuts stayed changed without saving the game.  They were written to bbskh2_shortcuts.ini at once,
  per character.  Asked for: tied to the save, kept only when the game is saved.
* Now in the save in memory, as Combo Master's bit: the top byte of abilities 1..4's u32 (150fa3d08 + 0x18cc +
  (1..4) * 4 + 3), one nibble per button (set * 4 + row): 1..8 slot, 0xf none, 0 never set.  The game's users of
  those u32 keep their own fields (bits 0-20: 41d426/447/463, 419645 btr/bts, 422e12 `and -0x40`); 41f44f writes
  0x3e00 into every ability (a give-all, not seen in play) and would clear them back to "never set".  A change is
  in the save data at once and in the file when the game is saved; loading a save brings back that save's.
* Never set (saves made before): the binding of bbskh2_shortcuts.ini for that character, which is now only read,
  else the default slots 1..4 / 5..8.  Test in t_shortcut.

## Boss rollout to every remaining boss (2026-10-19)

bbskh2_boss.ini now has sections for Vanitas (Aqua's and Ventus's finals), Eraqus, Master Xehanort, Zack (story and
Mirage Arena), Hades (armour only, his pace untouched), Hook, Peter Pan, Maleficent, Experiment 221 and the superbosses
Mysterious Figure, Vanitas Remnant and Armor of the Master. Left alone: No Heart, the wielder fights, Masked Vanitas /
Braig / Terra-Xehanort (done earlier).

New armour mode `hit [N]`: armoured until the move's hit windows have opened and closed again or it has fired a
bullet, read live through `BBS_AtkState(handle)` (bundle.c: n + 64*open + 4096*shots over the entity, its children and
its bullets). N (default 60) is the fallback for a move that never opens a window; 600 frames is the hard cap. In the
emulator BBS_AtkState is missing, so "hit" falls back to N. Debug log: "armour of X ends at ...".

Tempo `repoAt` limits repositioning to the listed idle states (Ventus's-final Vanitas and Mysterious Figure have more
than one idle). Superbosses use Beat 10-18 and Pause 20, 45-90. Zack and Hades in the Mirage Arena are copies of the
story configs with revenge limit 9.

## Keyblade wielders as bosses (2026-10-19)

The shared wielder AI (b60 script) sets friendFlag 1 for b68/b69 (Ventus), b78/b79 (Terra) and b88/b89 (Aqua): those are
allies and keep the plain `wielder` config (the boss system is off for them).  The enemy copies b60/b62, b70/b72/b73,
b80/b82/b83 use `wielderBoss` (tempo: BattleIdling timer) and bbskh2_boss.ini [Keyblade wielders] (Terra-Xehanort's
keyblade numbers, plus LimitCommando whole with cooldown 30; KealCommand, EvasionAction, StateReflect vanilla).
Answers now reroll up to 8 times against repeating the last one (was 4; MX's own pattern picker could repeat).

## Armor of the Master: far break-out guard -> dash cut (2026-10-19)

His break-out (vanilla roll forced) is Aurora / MikiriV/T/A within NEAR_DIST (3 m), but only Guard beyond it
(his own style through our counter, the copied styles through their own script).  A guard alone could be punished
into the next one.  `armorGuardDash` (from the counter and from `post` when his own break-out fired) pushes
GodspeedCutting<style> on his stack while he is in Guard: the guard pops it when it ends, the cut pops the idle
that was under it.  Styles: 1/2 Z, 3 V, 4 T, 5 A.  Tests in extra.lua (far: guard then the cut; close: unchanged).

## Braig's Inverted Shoot rounds; final Braig limit 6 (2026-10-19)

Inverted Shoot (b30/b32 script) is 2-5 rounds in the air: step 3 wait for the motion, step 4 ISIdling1 (20 frames),
step 5 volley (arrows at motion frames 11-19 and 36-44), 6 reload, 7 warp, then step 3 again.  His OnReturnDamage
(out of hit-stun in steps 3-7) and his 30 % dodge on a hit jump to step 7: he warps and starts the next round.
Only the first round had a window, so after one combo every later round could be staggered as it started (log of
2026-10-19).  New: cfg.rearm(self, st) -> true re-applies the current state's bbskh2_boss.ini window (st.armMove,
the code the state start uses); Braig's fires on the step change into 3.  [Braig (final)] InvertedShoot = hit 60
(armoured until his first arrow of the round); [Braig] keeps 46 frames per round.  b30ex00 limit 7 -> 6.

## Per-round armour for repeating moves (2026-10-19)

Survey of every windowed move (number / hit) of the humanoid bosses: moves that start new rounds inside one state
only had a window for the first round.  `rounds(spec)` in bosses.lua builds a cfg.rearm: spec[state] =
{ step = n } (a round starts when self.step turns n) or { up/down = "field" } (a counter changes while he stays).
Fixed: Braig InvertedShoot step 3, DashShoot step 2 (dash after the warp, up to 5 rounds), WarpShoot step 5
(second volley); Eraqus RushAttack count up (3 rushes); Hades FingernailofFire cnboNum down (3-8 swings);
Maleficent Thunder / StaffAttack count down; Experiment 221 Lightning step 2 (8 dashes after a ~480-frame wind-up:
the window used to run out before the first dash); Armor of the Master GodspeedCuttingVFinish count up.
Left for playtesting (user's doc "BBS KH2-Style: Boss Moves to Playtest"): MF Random_Laser, Maleficent Thundaga,
MX Thundaga, Peter Attack3, Hook RushXCutting, Braig RoundShoot, b11ex00 XDisCharge, b52 Guardian repeats,
MF RashAttack, 221 ElectricBall.

## Final Braig's extra armour undone (2026-10-19)

The +12 frames for final Braig (own [Braig (final)] section) were an attempt at the "stagger on start-up" problem
that the per-round windows fixed; at the user's request both fights share [Braig] again (Dash 56, Round 60, Warp 48,
Inverted 46 per round).  Kept: final Braig's revenge limit 6 (bosses.lua braigLate).

## D-Link gauge after a link: back to the game's way (2026-10-22)

At the user's request `DLinkGaugeAfter` defaults to 100 (dist ini and the built-in default): ending a D-Link leaves
the gauge as the game does.  The hook stays; 0 brings the KH2 rule back.  t_link_end checks both.

## The Magic list is called Skills (2026-10-22)

At the user's request: the menu row (`[Menu] MagicText`, default and dist ini "Skills") and the list's header word
(tools/genhdart.py now draws SKILLS for the MAGIC slot; hdart_gen.h keeps the HDART_MAGIC_* names, 240 px wide,
patch 244 x 132 at 16,740, still in the empty area of all three sheets).

## MP is called SP in the game's text (2026-10-22)

At the user's request (the Magic list is Skills now): every in-game text of the mod says SP - command costs in
descriptions ("SP 10", "SP All"), SP Haste / SP Rage (names and help), Berserker's help, the Ether / Mega-Ether /
Elixir / Megalixir descriptions; README and modmanager/README.  Not yet: the HUD plate and the status panel label
(art; the user will supply assets), the ini (comments, [MP] section and key names kept), code names, logs.
* (art, same day) The bar's plate: tools/genmpart.py relabels KH2's "MP" plate "SP" - KH2's "p" kept (x 342..355),
  an "s" drawn on its pixel grid (12 rows, strokes 4 wide, bars 2 rows, corners trimmed by one), centred where "mp"
  was.  The menu panel's label: tools/genstatart.py draws an S in the sheet's square style (8 x 10, like its E / F)
  and puts the sheet's P 2 texels after it (as in "HP"); STAT_M_* names kept.  Test: t_stat (the S, the P).

## The Skills entry's icon: the gold emblem (2026-10-22; menu.c skills_icon, `[Menu] SkillsIcon`)
* Asked for: the Skills entry shows the gold emblem of the game's own menu sheet (camp.l2d's texture, x 58..84,
  y 755..794) instead of the magic hat, and nothing else changes.  tools/genhdart.py copies it (needs BBS_CAMP_PNG)
  with a clear 2-pixel rim, 32 x 44, to px 268,740 of the command sheet beside the header words (empty in EN / JP / FR);
  tex.c writes it in colour, in the byte order the check pixels show (BGRA from the game's decoder).
* The entry keeps sequence 0x21 (game id 33).  The hat drawn on the plate (control 3) is object 1: sprite 4, one quad
  (-6,-6)..(8,8), uv 26,98..54,126 (a grey hat, purple from its quad colour).  Object 3 (sprite 6, the large hat at
  338,2) has kind 0x81 in that control = not drawn; the first version changed that one, so the game kept showing the
  hat (found with the draw capture: the node's only draw was uv 26,98).  Each frame the plate's own copy of sprite 4
  (L2D_CloneNodeSprite) is pointed at the emblem: texels 0..16 x 3..21 of it (the art sits low in its block) on 12 x 14 units, x -5..7, y -7..7 (11 x 12 was centred but the user wanted it bigger),
  neutral colour.  Placed from the user's screenshots: the plate's black inside is node y -6.9..8.1; the whole block
  (y -7..9) and then the art on y -6..8 both showed the emblem low and nearly filling the inside.
  Other plates with the hat keep it.  Test: t_listhdr (the art in all three sheets and both byte orders; on the layout
  runtime the Skills plate's icon, what the node draws, and another plate's hat).

## D-Link rows solid (2026-10-23; menu.c plate_update_hook, `[Menu] DLinkRowsSolid`)
* Reported: the D-Link list is see-through, unlike the Magic / Items lists.  Cause (bc01_00, sequence 0x2d): the
  D-Link plate is one sprite, 63 - frame and its black inside in one piece of art (texture 120,48..176,86, inside
  opaque in the texture) - and controls 3 / 4 multiply it by the key 3c3c3c with alpha a0, so the whole plate,
  inside included, draws at about 63 %.  The Magic / Items body (sequence 0xb) has the same a0 on its frame sprite
  0, but lays sprite 2 (object 6, black, alpha ff) over the inside.  Under the cursor (control 0) the D-Link plate
  has no colour key and is opaque.
* Fix: the D-Link row rule of tint_node now also sets the key's alpha to ff (Tint `to` with a top byte = alpha;
  0 keeps the game's, as before for every other rule).  DLinkRowsSolid=1 default; with DLinkRowsBright=0 the
  rule keeps 3c3c3c and only changes the alpha.  Test t_colours: record alpha ff and the drawn colour word's alpha
  above the game's.  Not seen in the game by me.

## Focus Exchange (2026-10-23; combomaster.c, mp.c fx_*, `[Combat] FocusExchange`)
* Asked for: a new ability like Combo Master.  With it on, physical deck commands (category 1, Attack - the red
  keyblade icon) cost their SP cost in Focus instead; unlike SP they need the whole cost (greyed out below it), no
  yellow "would start a charge" warning, and they can be used during an SP charge.  Off by default.  Descriptions
  say FP.  Ethers and Elixirs untouched.
* The ability: combomaster.c now keeps a table of its abilities.  Focus Exchange is id 0x1c2 (ENCHANT_KIND_Random,
  category DEBUG: a command-board debug entry nothing shows; the Abilities row reads only the name pointer, 3f1b20,
  and its detail page is refused as for Combo Master).  Its choice: bit 26 of EXP Zero's save u32 (Combo Master 23,
  BBS Armor 24-25; the game's own fields are 0-20).  The list holds up to 33 now (with the rows' positions moved out,
  the entries may run to menu+0x2b8; the row objects start at +0x2c0): on Critical 30 + 2.
* The cost: Focus is the gauge's float at +0x68 (0..100, the shotlocks' gauge; pending gain at +0x6c).  use_hook
  takes a physical command only when Focus >= its cost, then spends it: the game's setter 20ad00 for the new value
  (it starts the shotlock "consume" display when asked for 0 and keeps the MAX flag 0x10000 / control 4 and drops the
  pending gain by itself, so fx_spend clears MAX, puts node 0xde in control 0, writes 0 by hand, and keeps the
  pending gain).  Availability: fx_block (every frame) makes a ready physical plate unavailable (flag 2) when the
  Focus no longer covers its cost, its reload fill = Focus / cost; reload_hook brings it to 100 once it does, so the
  game's own plate update readies it.  plates_block (SP charge) leaves physical plates to that rule.  Menu: the
  Skills entry and list stay open in a charge when the deck has such a command (mp_fx_any); the shortcut list's
  rows likewise; mp_would_burn is 0 for them.  Where the game switches the Focus gauge off (gauge flag 0x100000),
  they cost SP as usual.
* Test: t_fx (SP off / FP on, refused below the cost with the fill at Focus / cost, ready again when Focus comes up,
  from MAX, during a charge with Fire refused, gauge off, switched off again); t_cm (two entries, bit 26, help,
  detail, name through the names file).  Not seen in the game by me.

## Link Charge (2026-10-23; combomaster.c, mp.c dlink_pick_hook / link_drain, `[Combat] LinkCharge`)
* Asked for: starting a D-Link no longer refills SP by default; a new ability, Link Charge, brings the refill back,
  and with it on the D-Link gauge drains twice as fast.  Off by default, like the other two.
* The ability: the third of combomaster.c's table, id 0x1c1 (ENCHANT_KIND_Unknown: a status entry no command board
  places - its loc 28 is no board's panel; the 0x1c1 immediates at 40517f / 405af3 are layout sequence numbers), bit
  27 of EXP Zero's save u32.  The Abilities list is now 33 on Critical (30 + 3), the whole room there is.
* Refill: dlink_pick_hook refills only when DLinkRefillsMP and the ability are both on.
* Drain: the gauge update 209f20 drains an active link (flag 0x200; not 0x1000 pinned, 0x8800, 0x400 skip) by adding
  to the pending change +0x64 per frame dt x -0.2 once +0xac (time in the link) >= 7200, before that the larger of
  dt x -0.01 and dt x -0.0005 x value (constants 6468a8 / ac / b0 / b4), then value += pending.  link_drain computes
  the same amount and gauge_update_hook adds it to +0x64 just before the game's update: twice the drain, prizes
  picked up during a link (also through +0x64) not doubled.
* Test: t_linkdrain (the game's own gauge update through the hook: one frame early in a link 2x, late 0.4 a frame,
  no link / pinned / skip flag nothing added); t_use (no refill without the ability, refill with it); t_cm (33 on
  Critical, bit 27, help, name).  Not seen in the game by me.

## Regular enemies wait less ([Mobs], 2026-10-23; revenge.lua attachMob / mobValue, bundle.c mob_patch)
* Investigated first (no changes): BBS Unversed vs KH2 Heartless / Nobodies.  BBS: no group attack limit -
  Enemy.CanAttack (2b7670 -> 2d2ae0) is a perception check (target in the enemy's 10-slot sight table at +0x2b0:
  visible, awareness >= 100, seen within 60 ticks, first spotted over 15 ticks ago; sight range +0x29c 15.0; the
  table is refreshed in 2d1dc0); waits are per-script SetTimer values (Scrapper 3 s idle, Monotrucker 3 s, Red
  Hot Chili 2 s, Buckle Bruiser two idle loops + 0..1.3 s, wanders 4..12 s).  KH2 (its BDX AI: idle_time 15..45
  frames, counterattack on flinch, group shouts, no attack limit, no difficulty reads) - scratch tools in
  /home/claude/kh2mob (bdx.py disassembler) and /home/claude/mobs (decompiled mob scripts, upvalue dumps).
* Asked for: only shorter waits, for the Unversed and Maleficent's goons.  RV.mobs: m01..m22, m25, m50..m57 (31
  Unversed by OpenKH's model names) and m01sb00 / m02sb00 (goons), plus the other story versions the same scripts
  register (m08ex00b, m14ex00b, m19ex00b, m22ex00s, m02sb00b; added on request).  Out: Prize Pod m23 (only runs), Disney Town
  m03dc00 / m07dc00, Heartless m40..m42, the Mirage Arena "vs" copies, bosses, allies (Peter Pan included).
* How: attachMob wraps the factory record's Create of a listed name (not when it has a boss cfg), tracks the state
  through GotoStateSub and puts the entity in the SetTimer pace table the bosses use (P.by).  The state decides:
  MOB_KIND idle (Idling, Idling2, InIdling, InIdlingNeedle, Rock_Idling, FastIdling, UndergroundIdling, SearchIdling,
  Search, SeekTarget, SearchTargeting, AttackWaiting, BeforeAttackIdling, Waiting) x WaitScale 0.5; wander (Wander,
  Rotation, Goes_away, Shuffle, Uneasiness, SearchTargetingUneasiness) x WanderScale 0.5; recover (Stiff,
  Stiffening, Dizzy) x RecoveryScale 1.0; nothing below WaitFloor 0.3 s (18 frames; shorter waits stay).  Per enemy:
  Yellow Mustard m18 decides inside its Move (70 % attack, 30 % a wait set there): Move = idle.  The state list was
  read from every SetTimer in the 33 scripts.  Waits counted in a field of the script's own (Bruiser's Wait = a third
  of its idle, Belly Balloon / Floating Flora's behaviours) are not changed.
* Settings: [Mobs] Enabled / WaitScale / WaitFloor / WanderScale / RecoveryScale, float markers 9003.5 .. 9007.5 in
  the compiled script replaced by the DLL (pace_patch), as [Bosses].  Needs RevengeValue=1.
* Test: extra.lua (Scrapper Idling 180 -> 90, Wander halved, Stiffening kept, floor, list, Enabled=0), t_bundle
  (markers replaced, ini values written).  A smoke run of all 33 through the stand-in: every listed enemy is paced,
  the halved values come out (scratch mobsmoke.lua).  Not seen in the game by me.

* The Heartless too (2026-10-23, asked for: "attack slightly more", not bosses): m40ex00 Shadow, m41ex00 Neoshadow,
  m42ex00 Darkball (named by their moves) in RV.mobs, their waits x HeartlessScale 0.75 (marker 9008.5) instead of
  WaitScale / WanderScale; stagger (Stiff, 8 s) x RecoveryScale.  Shadow / Neoshadow have no idle wait: Idling
  decides at once (when Enemy.CanAttack), so their wait is the shadow crawl before the attack they picked
  (ShadowMove, SetTimer 300, ends early on arrival) and Neoshadow's SideMove (300): MOB_OWN "wander".  Darkball:
  Move (8 + 0..300 frames, between attacks) "idle"; its Idling (480 + 0..60, before its first attack) by MOB_KIND.
  Attack timers (ShadowOut, AirRush, Bite, Ranbu, DarkCnage, DarkMove) untouched.  Upvalues dumped with
  /home/claude/mobs/upv2.lua (the class from EntityFactory, the Heartless scripts keep it local).

## SP orbs (2026-10-23; sporb.c, `[SPOrbs]`)
* Asked for: KH2's MP orbs as SP orbs - dropped whenever an enemy drops D-Link prizes, only on defeat, not by
  bosses, weaker than KH2's; later the KH2 bubble look and the MP sound.
* Prizes: an enemy's drops are 2d5b30(enemy, pos, percent, a4, a5) - its epd prize table ([enemy+0x250]+0x9c id,
  +0x98 count; entries kind u32, count u16, chance u16; looked up by 53f640), each prize made by 1e83e0(pos, kind,
  0, 0, f, f) at 2d5cc7.  Prize types at 140817b30, 0x50 each (+0x20 / +0x28 model arc / name, +0x38 / +0x3c floats,
  +0x40 command): 0 / 1 HP 1e2 / 1e3 (SYS_PRZ_000), 2..4 munny 1e6..1e8 (SYS_PRZ_002), 5 / 6 D-Link 1e4 / 1e5
  (SYS_PRZ_001; pickup 273420 adds to the gauge's pending D-Link +0x64 through 208280; counts x ability 0x1c6
  "FpPrizeUp" = Link Prize Boost), 7 Vile Phial's drain, 8 1f0 (SYS_PRZ_003), 9.. Floating Flora / Gluttonous Goo
  balls.  HP counts x ability 0x1c5.  Defeat: 2d8e40 (call 2d8f16) and 2def30 (call 2defd8); hit drops 2cfaae (50 %)
  and the scripts' MakePrize are not defeats.  The entity name is at ent+0xf0 (m... regular, b... boss).
* The orb: made as kind 5 (the small D-Link prize: model, flight, pull of Prize Draw), then given a type record of its
  own (prize+0x250): kind 5's copy with command 0x1ef, a prize command (type 10) that 273420 does nothing for.  All
  pickup paths take the command from that record and go through 2733d0 -> the one call of 273420 at 273408, hooked:
  0x1ef from the local player = mp_restore_pct(SPPercent) (SP, or the recharge in an SP charge).
* Settings: Enabled 1, PerDLinkPrize 1 (a fraction = a chance), SPPercent 2.
* Test t_sporb: the game's own 2d5b30 over a made-up table (2 HP, 3 + 1 D-Link at 100 %) with 1e83e0 stubbed: a Flood
  gets 4 orbs, a boss none, a drop outside a defeat none, 0.5 about half; pickup +2 % / +2 % of the recharge, a
  friend's pickup nothing.  Not seen in the game by me.  Look and sound: next.

### SP orbs: the look (2026-10-23)

Prize looks are FEP particle effects in `arc/system/commonGame.arc` → `s_ex_prz_00.fep` (9 effects: SYS_PRZ_000_0/1 HP,
001_0/1 D-Link, 002_0/1/2 munny, 100_0, 003_0).  SYS_PRZ_100_0 is in the file but no prize type uses it.  The effect is
picked while the prize is made (1ea280, from the type's +0x20 file / +0x28 effect name), so the orb borrows kind 5's
entry for its one 1e83e0 call with the name swapped (`[SPOrbs] Look`).  Textures are not in the FEP: its five texture
resources are ids 0xf00000xx into `arc/system/common.arc` → `resident.frr` (29 shared textures; the remastered DDS
of frr texture N is common.arc's remastered entry N+4).  The prizes use 0x12 (orbs / D-Link star sheet), 0x0a, 0x13
(munny crystal), 0x04, 0x1b (chrome sphere) - and 0x1b alone is shared by ~100 other effects (magic, bosses), so its
pixels can't be swapped for KH2's bubble (obj/PRIZE.mdlx remastered -1.dds) without changing those too.
HD DDS textures go through 4e19b0 → the call to 4e1630 at 4e1e47 (the PNG path is 4e1ee4).
Pickup sound: record +0x44 (bank, -1 = system) / +0x46 (SE id) → 1b2e40 (system bank "se0000",
sound/win/se/common/se0000.win32.scd) or 1b2c70 (bank*0x400+id).  HP 11, D-Link 12, munny 13.  Bounce sounds come
from 1e8d30 / 1e93c0 by command (0x3c / 0x3d / 0x3e) - the orb (0x1ef) has none.

### SP orbs: KH2's pickup sound (2026-10-23)

KH2 (PC exe): prize kinds table at 0x5c7390, {u8 kind, f32 height, i32 bounce SE, i32 pickup SE}; the pickup plays
it at 413730 through 1de150 (SE id = file * 1000 + sound, file 0 = se/se000.win32.scd).  HP orbs 16, munny 15, MP
orbs 17 (kinds 5 / 6, which add MP through 3d3cf0 - the same function spells take their cost with).  Sound 17 = one
track (16: KeyOn, wait 462 ms, KeyOff) of audio entry 167 (MS-ADPCM, mono, 47978 Hz).  tools/genorbse.py copies
the track and the entry to src/orbse_gen.h.
BBS: the common bank's resource handler 553160 registers "se0000" with the sound engine at 553472 (4c3fb0(0, scd,
size, 0, 0); a transfer thread copies the buffer, 4c4f20; the bank number is the SCD's u16 at 0x36).  The hook
hands the engine an extended copy (sporb.c se_extend): BBS's SCD is version 3 (KH2's 4: longer sound entries, same
track and audio formats); the four offset tables (sounds at 0x50, tracks [0x38], audio [0x3c], per-sound 0x80
blocks [0x40] -> [0x48]) each get one more slot, everything after them moves on by the same 16-aligned amount, and
the new sound (a copy of the D-Link pickup's 0x14 entry and block, number = old count = 164, volume 1.0), the
track and the audio entry go at the end.  The header's u32 at 0x10 moves on by the added size.  The orb's prize
type then has +0x44 -1 / +0x46 164.  The engine plays MS-ADPCM (AdpcmStreamDataTransferEx) as well as its own
Vorbis; BBS's own pickups are full-scale samples at volume 0.2-0.4, KH2's is quieter at 1.0 - about as loud.

### SP orbs: KH2's bubble (2026-10-23)

Not by editing shared data.  Prize effects (s_ex_prz_00.fep) hold no textures: their five texture resources are
references (ids 0xf00000xx, resolved at FEP registration by 161880 -> texture manager +0x28 with owner 0), and the
units draw sprites of shared ANM resources in resident.frr (program 0x98 FecAnm_plus: unit parameter +0xc indexes
the FEP's animation resources [0x38]; header +0x10 = the slot in the ANM manager).  The small D-Link prize (ed 1)
draws ANM 0xf00000a4: texrefs {0xf0000012, 0xf000000a}; parts 0x1c bytes {texref, colour (0x80 = 1.0), vertex
count, vertex offset (from the ANM), blend, ...}; vertices 10 bytes {u16 u, u16 v, s16 x, y, z}, uv 0x4000 = 1.0.
It samples texture 0x12 at u 0-.25 / v .5-1 (the star, normal blending) and u .25-.5 / v .5-1 (white star, additive
glow), and 0x0a at u .13-.25 / v 0-.12 (sparkles).
Textures: texture manager G(0x8f869d0), 192 slots of {object, id, owner, refs} at +0x28; register = vtable +0x18
(4bbd00 -> 158b70(mgr, owner, tex): first free slot, id from tex+4), release +0x30 (158cb0).  FRR textures are made
by 1a1770(frr, 0) at 11d818 (inside the mutex, after 131460 registered them), freed at 11d4a4.  A TEX record: "TEX",
+4 id, +0xc made, +0x10 format, +0x14 levels, +0x18 palette offset (from +0x10; 0 = 32-bit, format forced to 3),
+0x1c / +0x20 size, +0x24 pixel offset (then the renderer's handle).  4bc160 -> 522790: the HD picture is found by
where the pixels lie in a loaded asset (532da0: offset in the arc -> its remastered entry); pixels the mod owns have
none, so they are used as they are: 32-bit RGBA (alpha 0xff opaque), PSP-swizzled in 16-byte x 8-row blocks.
The swap: FecAnm_plus vtable 63de18 slot 3 (1779c0(self, ctx, params, float, work); the float is xmm3) wrapped;
ctx+0x78 = the effect leaf (15b0d0: tag 'e', +0x198 FEP, +0x158/+0x160 end callback 12a890 and the effect object),
ctx+0xa8 the ANM manager (+slot*0x20+0x30 -> object, +8 the ANM).  The effect object (12a600): +0x30 handle, +0x48
leaf, +0x50 flags (0x8000 ended); the prize keeps the handle at +0x244, 130c00(handle) -> the object.  An orb's
(object, handle, leaf) is noted when it is made; for those draws ANM 0xa4's texref slots point at the orb texture.
tools/genorbtex.py: the bubble from KH2 obj/PRIZE.mdlx remastered texture 1 (left 128x128), tinted, 60x60 in the
star's cell, a soft glow in the white star's, the rest clear (no sparkles).
Later (asked for): the glow cell is clear as well - the D-Link prize's pulsing additive glow parts showed as a shine
inside the bubble.

### SP orbs: half the drops (2026-10-23)
* Measured in game (debug log, Terra early, max SP 70): every pickup exactly +1.4 SP (2 %), one log line per orb, no
  double counts; kills drop 2-3 orbs at once, so six pickups took 50 -> 58.4 SP in 7 s against a 10 SP command.
  Asked for: half the drop rate, 2 % kept - PerDLinkPrize 1 -> 0.5 (default and ini).

## Rebalanced SP costs (2026-10-24; mp.c k_rebalance, ini [MP] Rebalanced)
* Asked for: re-evaluate the costs of the strong commands (up to 50 or the whole bar).  First an investigation of
  the command data (no changes): the per-command parameters at 140811080 + id*0x1e, +0xa: ten s16 "pw" values read
  at the command's start indexed by level - attack commands (1402232a0) pw[lv-1], magic and the D-Link-only commands
  (140265920) pw[lv] (pw[0] a level-0 value), D-Link-only by D-Link level pw[0..2]; the power is a percent of the
  stat (Strength for attack commands, Magic for magic, 140219fe0) per hit; other slots are counts (mines, Faith's
  columns, Quake's waves, written to pl+0x338), durations (x2 = 60 Hz ticks), chances, heal percent.  Cure family:
  Magic + pw[lv]; Faith 300..325 per hit and 50..100 % of max HP; Salvation 40..90 %.  Hit counts from code / bullet
  data where they could be read (keyblade swing hit data was not in the extracted files - one hit per swing assumed).
* Costs set (by strength per use, Fire 200 / 10 and Mega Flare 1350 / 50 as the yardsticks; the user's own picks
  for Seeker Mine 45 and the three chains 50, Deep Freeze kept at 25): see k_rebalance.  Faith is a cure for
  CureUsesAllMP (all remaining SP; 50 without).  [Cost] overrides still win.  Test: t_ether's cost block (with
  Rebalanced=0 the old values), t_fx runs with Rebalanced=0 (its Sonic Blade is the 20-SP command).

## Final Braig's revenge limit back up (2026-10-24)
* Asked for: Braig in the Keyblade Graveyard (Aqua's final episode, b30ex00 = braigLate) 6 -> 8 (re-rolled +-1 after
  each break-out as every boss).  His other fight (b32ex00) stays 9.

## Terra-Xehanort's revenge limit up (2026-10-24)
* Asked for: Terra-Xehanort 6 -> 8 in all three fights (b50ex00 / b51ex00 = xehanort, b52ex00 the final episode),
  re-rolled +-1 after each break-out as every boss.  Test: extra.lua's b50ex00 break-out (8 +- 1).

## Ventus / Terra / Aqua revenge limit down (2026-10-24)
* Asked for: every Ventus / Terra / Aqua fight (the shared wielder entry: b60/b62, b70/b72/b73, b80/b82/b83, the
  practice fights included) 9 -> 3, re-rolled +-1 after each break-out.  The allies (b68/b69, b78/b79, b88/b89) are
  inactive as before.  Test: extra.lua's practice Terra break-outs land at 2-4.
