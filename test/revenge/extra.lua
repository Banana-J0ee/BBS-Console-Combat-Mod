package.path = (os.getenv("RV_TEST") or "test/revenge") .. "/?.lua;" .. package.path
local M = require("emu")
math.randomseed(7)
M.common()
BBS_REVENGE.vary = 0           -- deterministic limits for these checks (variance has its own check below)
BBS_REVENGE.opening = false    -- (the opening attack has its own check at the end)
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 io.write("  FAIL: ", msg, "\n") else io.write("  ok: ", msg, "\n") end end
local function hit(h, kind, cat)
  local c, r = EntityManager:CallFunctionArg5("OnDamageBefore", h, kind or ATK_KIND_DMG_SMALL, cat or COMMAND_CATEGORY_ATTACK, 0, 0)
  if r ~= nil and r ~= false and r ~= 0 then return "before" end
  c, r = EntityManager:CallFunctionArg5("OnDamage", h, kind or ATK_KIND_DMG_SMALL, cat or COMMAND_CATEGORY_ATTACK, 0, 0)
  if r ~= nil and r ~= false and r ~= 0 then return "damage" end
end
-- No Heart
M.script("b85vs00")
do
  local e, h = M.create("b85vs00")
  local st = BBS_REVENGE.ents.b85vs00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  for i = 1, 13 do hit(h) end
  check(st.rv == 13 and e.burstTimer > 90000 and e.burstStartFlag == 1, "No Heart: 13 hits, value 13, his own timer held off (" .. tostring(e.burstTimer) .. ")")
  for i = 1, 200 do e:OnUpdate() end
  check(e:GetState() == "Idling" and st.rv > 10.5 and st.rv < 10.7, "200 frames of update between hits: no burst, value drains at his slow rate (state " .. e:GetState() .. ", value " .. st.rv .. ")")
  local armed = false
  for i = 1, 20 do hit(h) if st.firing then armed = true break end end
  check(armed and e.burstTimer < 0, "more hits: burst armed at his limit")
  e:OnUpdate()
  check(e:GetState() == "BurstAttack", "next update: BurstAttack (" .. e:GetState() .. ")")
  check(st.rv == 0 and st.firing == false and st.count == 1, "value cleared after the burst (" .. st.rv .. ")")
  check(hit(h) == "before" and st.rv == 0, "hits during the burst are ignored by him and do not count")
  pcall(e.GotoState, e, "Idling")
  for i = 1, 5 do hit(h) end
  check(st.rv == 5, "new string: value 5")
  for i = 1, 320 do e:OnUpdate() end
  check(st.rv == 0 and e.burstStartFlag == 0, "10 s without a hit: value and his timer cleared (" .. st.rv .. ", flag " .. tostring(e.burstStartFlag) .. ")")
  check(e:GetState() == "Idling", "... and no burst came out of it")
end
-- Master Xehanort
M.script("b40ex00")
do
  local e, h = M.create("b40ex00")
  local st = BBS_REVENGE.ents.b40ex00
  pcall(e.GotoState, e, "Idling")
  local r
  for i = 1, 8 do r = hit(h) end
  check(r == nil and st.rv == 8 and e:GetState() == "Idling", "Xehanort: 8 hits land, he stays in the combo")
  r = hit(h)
  check(r == "before" and e:GetState() == "Warp" and st.rv == 9 and e.defenseTimer > 0, "9th hit: quick warp (state " .. e:GetState() .. "), hit negated, value kept (KH2)")
  local grace = BBS_REVENGE.grace
  check(st.idle >= grace, "... and it drains from now on, while he acts")
  check(hit(h) == nil and e:GetState() == "Warp", "while he is warping nothing more is triggered")
  st.owe = nil                                   -- (the attack owed after the warp: not this check)
  pcall(e.GotoState, e, "Idling"); st.rv = 0
  for i = 1, 2 do hit(h, ATK_KIND_DMG_SMALL, COMMAND_CATEGORY_FINISH) end
  check(st.rv == 6 and e:GetState() == "Idling", "finishers count 3 each (value " .. st.rv .. ")")
  check(hit(h, ATK_KIND_DMG_SMALL, COMMAND_CATEGORY_FINISH) == "before" and st.rv == 9, "... break-out at the third")
  -- KH2: the gauge is not cleared by a break-out; it drains while he acts, so going straight
  -- back in brings the next break-out sooner than the first
  pcall(e.GotoState, e, "Idling")
  for i = 1, 20 do e:OnUpdate() end              -- a third of a second of his own action
  check(st.rv > 6.9 and st.rv < 7.1, "a third of a second later: drained at KH2's pace, 9 -> " .. st.rv)
  local n = 0
  repeat n = n + 1 r = hit(h) until r == "before" or n > 12
  check(r == "before" and n <= 3, "straight back in: the next break-out after " .. n .. " hits, not 9")
  pcall(e.GotoState, e, "Idling")
  for i = 1, 200 do e:OnUpdate() end
  check(st.rv == 0, "left alone long enough it drains to nothing (" .. st.rv .. ")")
end
-- Master Xehanort with Vanitas: his idle voice lines scaled by how much shorter his refusal wait is (2 / 300)
do
  local e, h = M.create("b40ex00")
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  check(type(rawget(e, "PlayVoice")) == "function", "his voice lines go through the mod")
  local said = 0
  local old = M.num["Sound.PlayVoice"]
  M.num["Sound.PlayVoice"] = function() said = said + 1 end
  e.phase, e.DamageWarpParam = 100, 102
  local refusals = 0
  for k = 1, 3000 do
    pcall(e.GotoState, e, "Attack0")
    e.StateParam = 0
    pcall(e.GotoState, e, "Idling")               -- after his attack: the Beat
    e.StateParam = 101
    local before = said
    for j = 1, 9 do pcall(e.GotoState, e, "Idling") end   -- refused nine times: idle after idle, 2 of his 300
    refusals = refusals + (said - before)
  end
  e.phase, said = 0, 0
  for k = 1, 3000 do pcall(e.GotoState, e, "Attack0") e.StateParam = 0 pcall(e.GotoState, e, "Idling") end
  M.num["Sound.PlayVoice"] = old
  -- 27000 refusals at 20 % x 2/300: ~36 lines (unscaled ~5400)
  check(refusals >= 10 and refusals <= 80, "with Vanitas: " .. refusals .. " lines in 27000 refused idles (~36; unscaled ~5400)")
  check(said > 480 and said < 720, "alone: his lines as before (" .. said .. " in 3000 idles, ~600)")
end
-- Master Xehanort with Vanitas: his close-range warp after a refusal, scaled the same way (2 / 300)
do
  local e, h = M.create("b40ex00")
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  local st = BBS_REVENGE.ents.b40ex00
  local function tries(phase, param, n)
    e.phase, e.DamageWarpParam = phase, 102
    local warps = 0
    for k = 1, n do
      pcall(e.GotoState, e, "Attack0"); e.StateParam = 0
      pcall(e.GotoState, e, "Idling")
      e.StateParam = 101
      pcall(e.GotoState, e, "Idling")              -- refused: his wait made 2 frames
      e.StateParam = param                         -- his script: close by, param 101 -> Warp
      pcall(e.GotoState, e, "Warp")
      if e:GetState() == "Warp" then warps = warps + 1 end
    end
    return warps
  end
  local w = tries(100, 101, 3000)
  check(w >= 5 and w <= 45 and st.idleRatio ~= nil and st.idleRatio < 0.01, "with Vanitas: the close-range warp " .. w .. " times in 3000 (~20; it was every time)")
  check(e:GetState() == "Idling" or e:GetState() == "Warp", "held back: he stays in Idling (" .. e:GetState() .. ")")
  check(tries(100, 102, 200) == 200, "his warp with the team param (the break-out's) is never held back")
  check(tries(0, 101, 200) == 200, "alone: never held back")
end
-- Debug only: Vanitas's team watch - a wait over 4 s for Xehanort's end message is logged; nothing changed
do
  M.script("b10ex00")
  check(BBS_REVENGE.debug == false, "no debug file: the watch is not put on (" .. tostring(BBS_REVENGE.debug) .. ")")
  local v0 = M.create("b10ex00")
  check(rawget(v0, "SearchTarget") == nil and rawget(v0, "OnMessage") == nil, "... his functions are the script's own")
  local lines = {}
  local log0 = BBS_REVENGE.log
  BBS_REVENGE.debug = true
  BBS_REVENGE.log = function(...)
    local t = { ... } for i = 1, #t do t[i] = tostring(t[i]) end
    local l = table.concat(t, " ")
    if l:find("team watch", 1, true) then lines[#lines + 1] = l end
  end
  local x = M.create("b40ex00")
  rawset(x, "Update", function() end); rawset(x, "Debug", function() end)
  x.phase, x.DamageWarpParam = 100, 102
  pcall(x.GotoState, x, "Attack0"); x.StateParam = 3; pcall(x.GotoState, x, "Idling"); pcall(x.GotoState, x, "Move")
  M.num["Enemy.SearchEnemy"] = function(h, name) if name == "b40ex00" then return 777 end return NULL_HANDLE end
  local v, hv = M.create("b10ex00")
  rawset(v, "Update", function() end); rawset(v, "Debug", function() end)
  local st = rawget(v, "__rv")
  pcall(v.GotoState, v, "Idling")
  local perm0 = v.attackPermission
  st.t = st.t + 200; v:SearchTarget()
  local n200 = #lines
  st.t = st.t + 100; v:SearchTarget(); v:SearchTarget()
  check(perm0 == false and n200 == 0 and #lines == 1 and lines[1]:find("waiting 5.0 s", 1, true) and lines[1]:find("Xehanort: Move", 1, true)
        and lines[1]:find("Idling(3)", 1, true), "waiting over 4 s: one line, with what Xehanort is doing: " .. tostring(lines[1]))
  v:OnMessage(B40EX_MES_B40EX_ATTACK_END, 777)
  check(#lines == 2 and lines[2]:find("his turn back after 5.0 s", 1, true) and v.attackPermission == true, "the end message: logged, his turn back as the game does: " .. tostring(lines[2]))
  pcall(v.GotoState, v, "Idling"); st.t = st.t + 60; v:OnMessage(B40EX_MES_B40EX_ATTACK_END, 777)
  check(#lines == 2, "a short wait: nothing logged")
  BBS_REVENGE.debug, BBS_REVENGE.log = false, log0
  M.num["Enemy.SearchEnemy"] = nil
end
-- Master Xehanort with Vanitas: he breaks out at his limit too, with his team warp (param 102)
do
  local e, h = M.create("b40ex00")
  local st = BBS_REVENGE.ents.b40ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  e.phase, e.DamageWarpParam = 100, 102
  local r
  for i = 1, 8 do r = hit(h) end
  check(r == nil and st.rv == 8, "with Vanitas: 8 hits land")
  r = hit(h)
  check(r == "before" and e:GetState() == "Warp" and e.StateParam == 102 and e.DamageWarpParam == 102,
        "9th hit: his quick warp, landing in his team pattern (state " .. e:GetState() .. ", param " .. tostring(e.StateParam) .. ")")
  local e2, h2 = M.create("b40ex00")
  local st2 = BBS_REVENGE.ents.b40ex00
  rawset(e2, "Update", function() end); rawset(e2, "Debug", function() end)
  pcall(e2.GotoState, e2, "Idling"); pcall(e2.GotoState, e2, "Attack0")
  e2.phase, e2.DamageWarpParam = 100, 102
  M.num["Enemy.IsNoDamageReaction"] = function() return false end
  for i = 1, 8 do hit(h2) end
  r = hit(h2)
  check(r == "before" and e2:IsQuickWarping() and e2.DamageWarpParam == 102, "... also when hit out of his slash (he vanishes, as alone)")
  M.num["Enemy.IsNoDamageReaction"] = false
end
-- Zack
M.script("b40he00")
do
  local e, h = M.create("b60vs00")
  local st = BBS_REVENGE.ents.b60vs00
  for i = 1, 8 do hit(h) end
  check(st.rv == 8, "Zack: 8 hits")
  pcall(e.GotoState, e, "Bushinhazan")
  check(hit(h) == nil and st.firing == true, "limit reached during a move he cannot leave: no counter yet")
  pcall(e.GotoState, e, "Move")
  local r = hit(h)
  check(r == "before" and st.rv >= 8, "next hit: his counter, now per hit (" .. tostring(r) .. ", into " .. e:GetState() .. "), value kept (" .. st.rv .. ")")
  check(st.armor > 0, "the counter got its armour window")
  for i = 1, 60 do e:OnUpdate() end
  local held = st.armor > 0 or e:GetState() == "Move"
  st.owe = nil                                        -- (his answer attack, owed after the counter, is checked elsewhere)
  pcall(e.GotoState, e, "Move")
  e:OnUpdate(); e:OnUpdate()
  check(held and st.armor == 0, "... held through his counter, off once he walks again")
  st.rv = 0
  for i = 1, 4 do hit(h) end
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(st.rv == 4 and st.idle >= BBS_REVENGE.grace, "recovering from hit-stun does not clear the value, it starts the drain")
  e:OnUpdate()
  check(st.rv < 4 and st.rv > 3.8, "... at once (" .. st.rv .. ")")
  -- hit in his get-away jump, hit-stun after hit-stun (no update in between): it used to never end
  st.rv = 0; st.firing = false; st.armor = 0
  e.stack:clear(); e.stack:push("Move")
  pcall(e.GotoState, e, "BackJump_Short")
  e.step = 2
  local out
  for i = 1, 20 do out = hit(h) if out ~= nil then break end end
  check(out == "before" and e:GetState() == "BackJump_Short" and e.step == 0 and st.armor > 0,
        "hit through his back-jump: at the limit it starts again with the break-out's armour (" .. tostring(out) .. ", step " .. tostring(e.step) .. ")")
  check(e.stack:pop(1) == "Move", "... and what follows it is kept")
  -- hit in the end of his Hakougeki (open past its armour window), hit-stun after hit-stun
  st.rv = 0; st.firing = false; st.armor = 0
  rawset(e, "AddBushinCnt", function() end)                       -- (needs more of the engine than the stand-in has)
  pcall(e.GotoState, e, "Hakougeki")
  check(e:GetState() == "Hakougeki", "(in Hakougeki: " .. e:GetState() .. ")")
  st.mArmor = 0; st.winOff = true
  pcall(Enemy.EnableNoDamageReaction, h, 0)
  out = nil
  for i = 1, 20 do out = hit(h) if out ~= nil then break end end
  check(out == "before" and e:GetState():find("BackJump", 1, true) ~= nil and st.armor > 0,
        "hit through the end of his Hakougeki: he breaks out (" .. tostring(out) .. ", into " .. e:GetState() .. ")")
end
-- Zack, Climbhazard: armoured in the air (no answer), open on the landing (answer) - a fresh Zack (no cooldowns)
do
  local e, h = M.create("b30he00")
  local st = BBS_REVENGE.ents.b30he00
  rawset(e, "AddBushinCnt", function() end)
  e.stack:clear(); e.stack:push("Move")
  pcall(e.GotoState, e, "Climbhazard")
  check(e:GetState() == "Climbhazard", "(in Climbhazard: " .. e:GetState() .. ")")
  M.num["Enemy.IsNoDamageReaction"] = true                       -- (the stand-in engine keeps no lock)
  local armoured = BBS_REVENGE.cfg.b30he00.counter(e)
  M.num["Enemy.IsNoDamageReaction"] = false
  check(armoured == 0 and e:GetState() == "Climbhazard", "Climbhazard in the air (armoured): no answer")
  local out
  for i = 1, 20 do out = hit(h) if out ~= nil then break end end
  check(out == "before" and e:GetState():find("BackJump", 1, true) ~= nil,
        "hit through his Climbhazard landing: he breaks out (" .. tostring(out) .. ", into " .. e:GetState() .. ")")
end
-- Hades
M.script("b01he00")
do
  local e, h = M.create("b80vs00")
  local st = BBS_REVENGE.ents.b80vs00
  for i = 1, 5 do hit(h) end
  check(st.rv == 5, "Hades: 5 hits")
  M.num["Effect.IsAlive"] = true
  check(hit(h) == "before" and st.rv == 5, "burning red: the hit is ignored, the value stays (KH2)")
  M.num["Effect.IsAlive"] = false
  local r
  local n0 = st.count
  for i = 1, 9 do r = hit(h) end
  check((r == "damage" or r == "before") and st.count > n0, "9 hits: counter (" .. tostring(r) .. ", into " .. e:GetState() .. ")")
end
-- Peter Pan (added in v2: vanilla has no break-out at all)
M.script("b20pp00")
do
  local e, h = M.create("b20pp00")
  local st = BBS_REVENGE.ents.b20pp00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  local r
  for i = 1, 11 do r = hit(h) end
  check(r == nil and st.rv == 11, "Peter Pan: 11 hits land, no vanilla escape fires")
  r = hit(h)
  local s8 = e:GetState()
  check(r == "before" and st.rv == 12 and (s8 == "Attack1" or s8 == "Attack2" or s8 == "Attack3" or s8 == "Attack4"), "12th hit: one of his own attacks as the revenge (" .. tostring(s8) .. "), value kept")
  check(st.armor > 0, "the revenge has its armour window")
  for i = 1, 70 do e:OnUpdate() end
  check(st.armor > 0, "... held while his attack runs")
  pcall(e.GotoState, e, "Idling")
  e:OnUpdate()
  check(st.armor == 0, "... and off once he is idle again (punishable)")
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(e:GetState() == "BeforeAttackIdling", "after a combo he goes back on the offensive (" .. e:GetState() .. ")")
  do
    local tset
    local old = M.num["Entity.SetTimer"]
    M.num["Entity.SetTimer"] = function(h2, v) tset = v end
    pcall(e.GotoState, e, "Idling")
    EntityManager:CallFunctionNoArg("OnReturnDamage", h)
    M.num["Entity.SetTimer"] = old
    check(e:GetState() == "BeforeAttackIdling" and tset == 24, "... dazed 24 frames first, not 2 (" .. tostring(tset) .. ")")
  end
  -- a juggle the engine hides from the callbacks: the HP watch and the watchdog still break it
  local hp = 100
  M.num["Enemy.GetHp"] = function() return hp end
  pcall(e.GotoState, e, "Idling")
  st.rv, st.firing, st.hp = 0, false, nil
  local n0 = st.count
  for i = 1, 60 do hp = hp - 1 e:OnUpdate() if st.count > n0 then break end end
  check(st.count > n0, "hits invisible to the callbacks: the watchdog forced the revenge (value " .. st.rv .. ")")
  -- poison / burn: HP loss with no hit string behind it must not build revenge
  pcall(e.GotoState, e, "Idling")
  st.rv, st.firing, st.armor = 0, 0 == 1, 0
  st.seen, st.drop = -1e9, -1e9
  n0 = st.count
  for i = 1, 10 do
    hp = hp - 1
    for k = 1, 70 do e:OnUpdate() end        -- a tick a little over once a second
  end
  check(st.rv == 0 and st.count == n0, "damage over time (ticks over 1 s apart) builds no revenge (value " .. st.rv .. ")")
  M.num["Enemy.GetHp"] = 100
end
-- the limit varies after each revenge (KH2 FM re-rolls the cap)
M.script("b20pp00")
do
  local e, h = M.create("b20pp00")
  local st = BBS_REVENGE.ents.b20pp00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  BBS_REVENGE.vary = 1
  local lo, hi = 99, 0
  for i = 1, 12 do
    pcall(e.GotoState, e, "Idling")
    st.rv, st.firing, st.armor = st.limit - 0.5, false, 0
    hit(h)
    if st.limit < lo then lo = st.limit end
    if st.limit > hi then hi = st.limit end
  end
  BBS_REVENGE.vary = 0
  check(lo >= 11 and hi <= 13 and hi > lo, string.format("the limit re-rolls in 12 +- 1 after each revenge (%.2f .. %.2f)", lo, hi))
end
-- boss pace: idle waits shortened, walks capped, attacks / superbosses / allies left alone
do
  local log = {}
  M.num["Entity.SetTimer"] = function(h, v) log[h] = v end
  local RVs = BBS_REVENGE
  check(math.abs(RVs.aggr - 0.4) < 1e-6 and RVs.walkCap == 2 and RVs.idleFloor == 45, "pace defaults: idle x0.4 (floor 0.75 s), walks capped at 2 s")
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  check(log[h] >= 15 and log[h] <= 24, "Vanitas Idling: the beat of bbskh2_boss.ini, 15-24 frames (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "TargetMove")
  check(log[h] == 120, "Vanitas TargetMove: 300 -> 120 frames (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "KeyBladeRush")
  check(log[h] == 180, "Vanitas KeyBladeRush keeps its 180 (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "Warp1")
  check(log[h] == 30, "Vanitas Warp1 keeps its 30")
  -- a short idle stays as it is
  check(RVs.paceValue("idle", 40) == 40 and RVs.paceValue("idle", 60) == 45 and math.abs(RVs.paceValue("idle", 120) - 48) < 0.01 and RVs.paceValue("walk", 90) == 90,
        "waits under 0.75 s and walks under 2 s are not changed; 1 s idle -> 0.75 s")
  -- the same handle handed to another entity: no pace for it
  M.names[h] = "x"
  pcall(EntityFactory.Create, EntityFactory, "b01cd00", h)
  Entity.SetTimer(h, 300)
  check(log[h] == 300, "a handle given to another entity is not paced (" .. tostring(log[h]) .. ")")
  -- superboss
  M.script("b12ex00")
  local e2, h2 = M.create("b12ex00")
  rawset(e2, "Update", function() end); rawset(e2, "Debug", function() end)
  pcall(e2.GotoState, e2, "TargetMove")
  check(log[h2] == 120, "Vanitas Remnant (superboss, since 2026-10-19 paced like the others): walk capped at 120 (" .. tostring(log[h2]) .. ")")
  -- Braig: the beat of bbskh2_boss.ini in his WaitIdling counter (no boss-pace cut)
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  M.num["Script.RandomInRange"] = function(a, b) return 90 end
  pcall(e3.GotoState, e3, "WaitIdling")
  M.num["Script.RandomInRange"] = nil
  check(type(e3.timer) == "number" and e3.timer >= 15 and e3.timer <= 24, "Braig WaitIdling: the beat, 15-24 frames (" .. tostring(e3.timer) .. ")")
  -- keyblade wielder as an ally: untouched
  M.script("b60")
  local e4, h4 = M.create("b60ex00")
  rawset(e4, "Update", function() end); rawset(e4, "Debug", function() end)
  pcall(e4.GotoState, e4, "Move")
  check(log[h4] == 120, "wielder boss Move capped at 120 (" .. tostring(log[h4]) .. ")")
  e4.friendFlag = 1
  pcall(e4.GotoState, e4, "Move")
  check(log[h4] ~= 120 and log[h4] > 120, "the same script as an ally keeps its own pace (" .. tostring(log[h4]) .. ")")
  -- Hook: a walk that runs out of time short of his attack's range decides again
  M.script("b01pp00")
  local e5, h5 = M.create("b01pp00")
  rawset(e5, "Update", function() end); rawset(e5, "Debug", function() end)
  local function walk(dist, over)
    pcall(e5.GotoState, e5, "Idling")
    e5.stack:clear(); e5.stack:push("Idling"); e5.stack:push("DisturbStab"); e5.nearDist = 4
    pcall(e5.GotoState, e5, "TargetMove")
    M.num["Entity.CalcDistanceXZSq"] = dist; M.num["Entity.IsTimeOver"] = over
    pcall(e5.states.TargetMove.OnUpdate, e5)
    M.num["Entity.CalcDistanceXZSq"] = nil; M.num["Entity.IsTimeOver"] = false
    return e5:GetState()
  end
  local s1 = walk(100, true)
  check(s1 == "Idling" and log[h5] <= 24, "Hook: time out 10 m away -> no stab, decides again after the beat (" .. s1 .. ", timer " .. tostring(log[h5]) .. ")")
  local s2 = walk(3, false)
  check(s2 == "DisturbStab", "Hook: in range -> his planned stab (" .. s2 .. ")")
  local s3 = walk(100, false)
  check(s3 == "TargetMove", "Hook: still walking while the time lasts (" .. s3 .. ")")
  check(log[h5] == 120, "Hook TargetMove capped at 120 (" .. tostring(log[h5]) .. ")")
  M.num["Entity.SetTimer"] = nil
end
-- break-outs answer with an attack; the armour covers the answer and ends once the boss is idle again
do
  M.script("b60")
  local e, h = M.create("b50ex00")
  local st = BBS_REVENGE.ents.b50ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  M.num["Entity.IsGround"] = true
  local seen = {}
  for k = 1, 8 do
    st.chain = 0                                             -- (no reposition of bbskh2_boss.ini in this check)
    pcall(e.GotoState, e, "BattleIdling")
    st.rv, st.firing, st.armor = 0, false, 0
    local r
    for i = 1, 10 do r = hit(h) if r ~= nil then break end end
    seen[e:GetState()] = true
    check(r == "before" and st.rv >= 7 and st.rv <= 9, "Terra-Xehanort breaks out at his limit (8 +- 1): value " .. st.rv)
  end
  local atk = seen.Combo
  check(atk and not seen.EvasionAction, "... always with an attack of his own, never only the dodge roll")
  check(st.armor > 0, "the answer has its armour")
  for i = 1, 10 do e:OnUpdate() end
  check(st.armor > 0, "still armoured while attacking")
  st.chain = 0
  pcall(e.GotoState, e, "BattleIdling")
  e:OnUpdate()
  check(st.armor == 0, "back to idling: armour off, he can be punished")
  M.num["Entity.IsGround"] = nil
  -- an early wielder: attacks mostly, still dodges sometimes
  local e2, h2 = M.create("b70ex00")
  local st2 = BBS_REVENGE.ents.b70ex00
  rawset(e2, "Update", function() end); rawset(e2, "Debug", function() end)
  M.num["Entity.IsGround"] = true
  local na, nd = 0, 0
  for k = 1, 1000 do   -- (about 54 : 46 - enough tries that chance cannot tie it)
    pcall(e2.GotoState, e2, "BattleIdling")
    st2.rv, st2.firing, st2.armor = 0, false, 0
    local nh = 12
    for i = 1, 12 do if hit(h2) ~= nil then nh = i break end end
    if nh < 12 and (nh < 2 or nh > 4) then nd = -1000 - nh end   -- limit 3 +- 1: a break-out on hit 2-4 (12: their own dodge roll)
    local s2 = e2:GetState()
    if s2 == "EvasionAction" then nd = nd + 1 elseif s2 == "Combo" or s2 == "SpecialCommandAttack0" or s2 == "ShortDistAttackCommand" then na = na + 1 end
  end
  M.num["Entity.IsGround"] = nil
  check(na > nd and nd > 0, "Terra (practice, limit 3 +- 1): " .. na .. " attacks, " .. nd .. " dodges out of 1000 break-outs")
  -- bbskh2_boss.ini [Keyblade wielders]: the enemy wielders get the combo window and the gaps, the allies nothing
  local e6 = M.create("b82ex00")
  local st6 = BBS_REVENGE.ents.b82ex00
  rawset(e6, "Update", function() end); rawset(e6, "Debug", function() end)
  pcall(e6.GotoState, e6, "BattleIdling")
  pcall(e6.GotoState, e6, "Combo")
  check(st6.mArmor == 36, "Aqua (enemy): her combo armoured 36 frames (" .. tostring(st6.mArmor) .. ")")
  pcall(e6.GotoState, e6, "SpecialCommandAttack0")
  check(st6.mArmor == 1e9 and (st6.cdUntil.SpecialCommandAttack0 or 0) > st6.t, "... a special whole, on its 15 s cooldown")
  local e7 = M.create("b88ex00")
  local st7 = BBS_REVENGE.ents.b88ex00
  rawset(e7, "Update", function() end); rawset(e7, "Debug", function() end)
  e7.friendFlag = 1
  pcall(e7.GotoState, e7, "BattleIdling")
  pcall(e7.GotoState, e7, "Combo")
  check((st7 == nil or (st7.mArmor or 0) == 0) and BBS_REVENGE.bossProfile("b88ex00") == nil and BBS_REVENGE.bossProfile("b68ex00") == nil
        and BBS_REVENGE.bossProfile("b78ex00") == nil, "Aqua (ally): no section, no armour window")
  -- Braig: warps away and shoots from there
  local e3, h3 = M.create("b30ex00")
  local st3 = BBS_REVENGE.ents.b30ex00
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  local shots = 0
  for k = 1, 20 do
    pcall(e3.GotoState, e3, "Idling")
    st3.rv, st3.firing, st3.armor = 0, false, 0
    for i = 1, 10 do if hit(h3) ~= nil then break end end
    if e3:GetState() == "Escape" and e3.stack ~= nil then
      pcall(e3.GotoState, e3, e3.stack:pop(1))     -- the escape warp ends
      local s3 = e3:GetState()
      if s3 == "WarpShoot" or s3 == "DashShoot" or s3 == "ChargeShoot" or s3 == "RoundShoot" then shots = shots + 1 end
    end
  end
  check(shots == 20, "Braig: escape, then one of his shots, in " .. shots .. " of 20 break-outs")
  check(st3.limit >= 7 and st3.limit <= 9, "Braig in the Keyblade Graveyard: limit 8 +- 1 (" .. st3.limit .. ")")
  check(BBS_REVENGE.cfg.b32ex00.limit == 7 and BBS_REVENGE.cfg.b30ex00.limit == 8, "Braig: Radiant Garden (Terra) limit 7, Keyblade Graveyard 8")
  -- juggled in Inverted Shoot (air, steps 3-7): at the limit his own dodge-warp of that move comes out (the counter
  -- does not run there); below it, no dodge
  do
    local dodged, early = 0, 0
    for k = 1, 20 do
      pcall(e3.GotoState, e3, "InvertedShoot")
      e3.step = 3; e3.InvertedCount = 4
      st3.rv, st3.firing, st3.armor, st3.mArmor = 0, false, 0, 0
      local at
      for i = 1, 14 do
        local r = hit(h3)
        if e3.step == 7 then at = i break end
      end
      if at ~= nil and at >= st3.limit - 1.01 and e3.InvertedCount == 1 then dodged = dodged + 1 elseif at ~= nil then early = early + 1 end
    end
    check(dodged == 20 and early == 0, "Braig in Inverted Shoot: his dodge-warp at the limit, his last round, in " .. dodged .. " of 20 (" .. early .. " early)")
  end
  -- his escape warp goes far, his other warps keep their range
  local got
  rawset(e3, "__wt", nil)
  local mt = getmetatable(e3)
  local cls = mt and mt.__index
  local orig = type(cls) == "table" and rawget(cls, "WarpToTarget") or nil
  if orig ~= nil then
    rawset(cls, "WarpToTarget", function(self, a, b) got = { a, b } end)
    local e5 = M.create("b30ex00")
    rawset(e5, "Update", function() end); rawset(e5, "Debug", function() end)
    pcall(e5.GotoState, e5, "Escape")
    e5:WarpToTarget(4, 6)
    local far = got and got[1] == 8 and got[2] == 11
    pcall(e5.GotoState, e5, "Idling")
    e5:WarpToTarget(4, 6)
    check(far and got[1] == 4 and got[2] == 6, "Braig: escape warp 8-11 m, other warps unchanged")
    rawset(cls, "WarpToTarget", orig)
  else
    check(false, "Braig's WarpToTarget found")
  end
  -- superboss: no armour added
  M.script("b12ex00")
  local e4, h4 = M.create("b12ex00")
  local st4 = BBS_REVENGE.ents.b12ex00
  rawset(e4, "Update", function() end); rawset(e4, "Debug", function() end)
  pcall(e4.GotoState, e4, "Idling")
  for i = 1, 12 do if hit(h4) ~= nil then break end end
  check(st4.armor == 0, "Vanitas Remnant (superboss): no armour after his break-out")
end
-- KH2's uninterruptible class: listed specials / warps armoured while they run, normal attacks not
do
  local log = {}
  M.num["Enemy.EnableNoDamageReaction"] = function(h, v) log[h] = v end
  M.num["Enemy.IsNoDamageReaction"] = function(h) return log[h] == 1 end
  M.script("b40ex00")
  local e, h = M.create("b40ex00")
  local st = BBS_REVENGE.ents.b40ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  pcall(e.GotoState, e, "BladeTornado")
  check(log[h] == 1, "Master Xehanort's Blade Tornado: armoured")
  for i = 1, 100 do e:OnUpdate() end
  check(log[h] == 1, "... for as long as it runs")
  pcall(e.GotoState, e, "Idling")
  check(log[h] == 0 and st.mArmor == 0, "back to idling: armour off")
  pcall(e.GotoState, e, "Attack0")
  check(log[h] == 1, "his normal slash is armoured too (KH2: every attack)")
  pcall(e.GotoState, e, "Move")
  check(log[h] == 0, "... walking: flinchable")
  M.script("b63ex00")
  local e2, h2 = M.create("b63ex00")
  local st2 = BBS_REVENGE.ents.b63ex00
  rawset(e2, "Update", function() end); rawset(e2, "Debug", function() end)
  pcall(e2.GotoState, e2, "Idling")
  pcall(e2.GotoState, e2, "SuccessionAttack2")
  check(log[h2] == 1, "Aqua's Vanitas: his combo is armoured")
  for i = 1, 30 do pcall(e2.OnUpdate, e2) end
  check(log[h2] == 1, "... for the whole move")
  -- a move whose own update drops the armour part way is held (the script's off is undone)
  M.script("b11ex00")
  local e5, h5 = M.create("b11ex00")
  rawset(e5, "Update", function() end); rawset(e5, "Debug", function() end)
  pcall(e5.GotoState, e5, "Idling")
  pcall(e5.GotoState, e5, "DarkSplicer1GroundBattle")
  local held5, n5 = true, 0
  for i = 1, 120 do
    pcall(e5.OnUpdate, e5)
    if e5:GetState() ~= "DarkSplicer1GroundBattle" then break end
    n5 = n5 + 1
    if log[h5] ~= 1 then held5 = false end
  end
  check(held5 and n5 > 0, "Vanitas's Dark Splicer: armoured to its end (" .. n5 .. " frames)")
  -- Braig (bbskh2_boss.ini): Dash Shoot armoured for its first 56 frames (hits kept from his script, which would end
  -- the shot), then open: a hit cuts it.  Then the beat (15-24 frames) in his Idling before the next shot
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  local st3 = BBS_REVENGE.ents.b30ex00
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "DashShoot")
  st3.rv, st3.firing, st3.armor = 0, false, 0
  check(st3.mArmor == 56 and log[h3] == 1, "Braig: Dash Shoot armoured from its start, 56 frames (" .. tostring(st3.mArmor) .. ")")
  for i = 1, 3 do hit(h3) end
  for i = 1, 30 do pcall(e3.OnUpdate, e3) end
  check(e3:GetState() == "DashShoot" and log[h3] == 1, "... hits in the window do not cut it (" .. tostring(e3:GetState()) .. ")")
  for i = 1, 25 do pcall(e3.OnUpdate, e3) end
  check(log[h3] == 1, "... still armoured at frame 55")
  pcall(e3.OnUpdate, e3)
  check(log[h3] == 0 and st3.mArmor == 0 and st3.winOff, "... after 56 frames he can be staggered")
  hit(h3)
  check(e3:GetState() ~= "DashShoot", "... and a hit then cuts the shot (" .. tostring(e3:GetState()) .. ")")
  e3.EnableAttack, e3.EnemyType, e3.RoundShoot, e3.ChargeShoot, e3.WarpShoot, e3.InvertedShoot = true, false, true, false, false, false
  st3.chain, st3.chainN = 0, 9
  pcall(e3.GotoState, e3, "DashShoot")
  pcall(e3.GotoState, e3, "Idling")                        -- the shot ends
  check(log[h3] == 0 and st3.hold >= 15 and st3.hold <= 24, "... then the beat, 15-24 frames, unarmoured (" .. tostring(st3.hold) .. ")")
  for i = 1, 10 do pcall(e3.states.Idling.OnUpdate, e3) end   -- (his state update)
  check(e3:GetState() == "Idling", "... during it no new shot (" .. tostring(e3:GetState()) .. ")")
  local r0 = st3.hold
  pcall(e3.GotoState, e3, "Idling")                        -- a hit: his script puts him back in Idling
  check(st3.hold <= r0, "... a hit does not lengthen it")
  for i = 1, 30 do pcall(e3.states.Idling.OnUpdate, e3) end   -- (his state update)
  check(e3:GetState() ~= "Idling", "... after it his Idling picks the next shot (" .. tostring(e3:GetState()) .. ")")
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "InvertedShoot")
  check(st3.mArmor == 46, "... Inverted Shoot armoured for its first 46 frames (" .. tostring(st3.mArmor) .. ")")
  -- each round of it (step 3: after the jump, or after the warp that follows a volley / a combo) gets that again
  do
    local steps, i = { 1, 2, 3, 4, 5, 5, 6, 7, 7, 3, 4 }, 0
    rawset(e3, "Update", function(self) i = i + 1 self.step = steps[i] or 4 end)   -- (his state update: the rounds)
    rawset(e3, "CheckPlayerPos", function() end)                                     -- (needs real positions)
    st3.hitWin, st3.mArmor, st3.winOff = nil, 0, true
    local armed = {}
    for k = 1, #steps do
      pcall(e3.OnUpdate, e3)
      if st3.mArmor == 46 then armed[#armed + 1] = k end
      if k == 5 then st3.hitWin, st3.mArmor, st3.winOff = nil, 0, true end    -- (as if the window were over)
    end
    check(#armed == 2 and armed[1] == 3 and armed[2] == 10 and not st3.winOff,
          "Braig's Inverted Shoot: a new window for each round, at step 3 (rounds armed at updates " .. table.concat(armed, ",") .. ")")
    rawset(e3, "Update", function() end)
  end
  -- Charge Shoot: armoured whole, and no hit reaches his script (no damage break, no cut)
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "ChargeShoot")
  st3.rv, st3.firing, st3.armor = 0, false, 0
  local heldC = true
  for i = 1, 150 do
    pcall(e3.OnUpdate, e3)
    if i % 10 == 0 then hit(h3) end
    if e3:GetState() ~= "ChargeShoot" then break end
    if log[h3] ~= 1 then heldC = false end
  end
  check(heldC, "Braig's Charge Shoot: armoured throughout, hits do not end it (" .. tostring(e3:GetState()) .. ")")
  -- a revenge answer's armour is not cut by the end of a listed move
  pcall(e.GotoState, e, "Idling")
  st.armor, st.armorT0 = 50, st.t
  pcall(e.GotoState, e, "Warp")
  pcall(e.GotoState, e, "Attack1")
  check(log[h] == 1 or st.armor > 0, "leaving an armoured move keeps the revenge armour")
  st.armor = 0
  M.num["Enemy.EnableNoDamageReaction"] = nil
  M.num["Enemy.IsNoDamageReaction"] = nil
end
-- a forced break-out never cuts into a warp / dive (it would leave the boss hidden or misplaced)
do
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  local st = BBS_REVENGE.ents.b10ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  for _, s0 in ipairs{ "Warp1", "Warp2", "ShadowDiving", "RideMode" } do
    pcall(e.GotoState, e, s0)
    st.rv, st.firing, st.fireT, st.armor = st.limit + 1, true, 0, 0
    for i = 1, 30 do pcall(e.OnUpdate, e) end
    check(e:GetState() ~= "Cartwheel", "watchdog leaves Vanitas alone in " .. s0 .. " (" .. tostring(e:GetState()) .. ")")
  end
  pcall(e.GotoState, e, "Idling")
  st.rv, st.firing, st.fireT, st.armor = st.limit + 1, true, 0, 0
  for i = 1, 30 do pcall(e.OnUpdate, e) end
  check(e:GetState() == "Cartwheel", "... and breaks out as soon as he is back on his feet (" .. tostring(e:GetState()) .. ")")
end
-- Vanitas (Ventus's final), last phase: while the Vanitas D-Link runs the mod leaves him alone
do
  M.script("b11ex00")
  local e, h = M.create("b11ex00")
  local st = BBS_REVENGE.ents.b11ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  COMMAND_KIND_DLink17 = COMMAND_KIND_DLink17 or 9917
  local dl = false
  M.num["Player.GetCommandKind"] = function() if dl then return COMMAND_KIND_DLink17 end return 0 end
  e.airBattle = true
  pcall(e.GotoState, e, "Hovering")
  st.rv, st.firing, st.fireT, st.armor = 0, false, 0, 0
  local r
  for i = 1, 12 do r = hit(h) if r ~= nil then break end end
  check(r ~= nil and st.count >= 1, "air phase without the D-Link: revenge works as usual")
  pcall(e.GotoState, e, "Hovering")
  st.rv, st.firing, st.fireT, st.armor = st.limit + 1, true, 0, 30
  dl = true
  local n0 = st.count
  for i = 1, 12 do hit(h) end
  for i = 1, 30 do pcall(e.OnUpdate, e) end
  check(st.count == n0 and e:GetState() ~= "Cartwheel" and st.armor == 0 and st.firing == false,
        "Vanitas D-Link running: no gauge, no forced break-out, no armour of ours (" .. tostring(e:GetState()) .. ")")
  dl = false
  M.num["Player.GetCommandKind"] = nil
end
-- masked Vanitas's ride: no armour of ours; enough hits during the ride knock him off his own way
do
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  local st = BBS_REVENGE.ents.b10ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  local ended = 0
  rawset(e, "EndRideMode", function() ended = ended + 1 end)
  e.keybladeHandle = { 9001, 9002 }
  pcall(e.GotoState, e, "RideWaiting")
  e.keybladeHandle = { 9001, 9002 }
  check(e.__rideHits == 0, "summoning the keyblades starts a new ride count")
  pcall(e.GotoState, e, "RideMode")
  local need = st.limit
  for i = 1, math.floor(need) - 1 do st.t = st.t + 2 hit(h) pcall(e.GotoState, e, "RideMode") end
  pcall(e.states.RideMode.OnUpdate, e)
  check(e:GetState() == "RideMode" and ended == 0, "fewer hits than his limit: still riding (" .. tostring(e.__rideHits) .. " hits)")
  for i = 1, 2 do st.t = st.t + 2 hit(h) pcall(e.GotoState, e, "RideMode") end
  pcall(e.states.RideMode.OnUpdate, e)
  local top = e.stack:pop(1)
  check(ended == 1 and e:GetState() == "BackhandsSpringJump" and top == "StyleChange",
        "his limit's worth of hits: off the keyblades the way his script ends a ride (" .. tostring(e:GetState()) .. ", then " .. tostring(top) .. ")")
end
-- the revenge answer: after the get-away the boss attacks with a move picked from its list - by distance,
-- never the same as last time - under armour (KH2: a break-out is always an attack)
do
  local function set(list) local t = {} for i = 1, #list do t[list[i]] = true end return t end
  local rows = {
    { "b10ex00", "b10ex00", "Idling", { "SuccessionAttack1", "DarkFiraga", "DarkThundaga" }, { "Warp1", "DarkFiraga", "DarkThundaga" } },
    { "b11ex00", "b11ex00", "Idling", { "SuccessionAttack", "XDisCharge" }, { "DarkThundaga", "DarkAxisGroundBattle", "DarkSplicer1GroundBattle" } },
    { "b63ex00", "b63ex00", "Idling", { "SuccessionAttack2", "DarkThundaga" }, { "Warp2", "ShadowDiving", "DarkThundaga" } },
    { "b20ex00", "b20ex00", "Idling", { "SuccessionAttack", "RushAttack", "Kagerou" }, { "RushAttack", "Oboro", "Kasumi", "Itusen" } },
    { "b30ex00", "b30ex00", "Idling", { "RoundShoot", "DashShoot" }, { "WarpShoot", "DashShoot", "ChargeShoot" } },
    { "b40ex00", "b40ex00", "Idling", { "Attack0", "Attack1", "RisingGround", "Blizzaga", "Thundaga" }, { "RisingGround", "Blizzaga", "Thundaga" } },
    { "b40he00", "b30he00", "Move", { "ComboAttack", "Hakougeki", "Climbhazard" }, { "Climbhazard", "Hakougeki" } },
    { "b01pp00", "b01pp00", "Idling", { "JumpCutting", "RushStab", "DisturbStab" }, { "RushXCutting", "PresentBombSmall" } },
    { "b20ls00", "b20ls00", "AirMove", { "Electroshock", "Lightning" }, { "Lightning", "ElectricBall" } },
    { "b01sb00", "b01sb00", "IdlingA", { "StaffAttack", "Thundaga" }, { "StaffAttack", "Thundaga" } },
    { "b60", "b60ex00", "BattleIdling", { "Combo", "ShortDistAttackCommand" }, { "DistanceAttackCommand2", "DistanceAttackCommand3", "Combo" } },
  }
  M.num["Enemy.SearchEnemy"] = function() return NULL_HANDLE end   -- (no Xehanort beside Vanitas)
  for _, row in ipairs(rows) do
    local script, name, ret = row[1], row[2], row[3]
    M.script(script)
    local e, h = M.create(name)
    local st = BBS_REVENGE.ents[name]
    if e == nil or st == nil then
      check(false, name .. ": answer test could not create the boss")
    else
      rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
      for pass = 1, 2 do
        local d = pass == 1 and 4 or 900
        M.num["Entity.CalcDistanceSq"] = d
        local want = set(pass == 1 and row[4] or row[5])
        local okAll, rep, last, seen, n = true, false, nil, {}, 0
        for k = 1, 16 do
          st.owe = nil
          pcall(e.GotoState, e, ret)
          st.armor, st.mArmor = 0, 0
          st.owe = st.t                                -- a forced break-out: the attack is owed
          pcall(e.GotoState, e, ret)                   -- the get-away hands over
          local cur = e:GetState()
          local lab = st.lastAnswer
          -- (the picked move; some moves' own start cannot run in the stand-in engine)
          if not want[lab] or not (want[cur] or cur == ret or cur == "Landing") then okAll = false end
          cur = lab or "?"
          if lab == last then rep = true end
          if not seen[cur] then seen[cur] = true n = n + 1 end
          last = lab
          if k == 1 and not (st.armor > 0 and st.armorCap ~= nil) then okAll = false end
        end
        local multi = (pass == 1 and #row[4] or #row[5]) > 1
        if name == "b60ex00" and pass == 2 then multi = false end   -- (the stand-in has no command table)
        check(okAll and not (multi and rep) and (n >= 2 or not multi),
              name .. (pass == 1 and " close" or " far") .. ": after the get-away an attack from his list, armoured, " ..
              n .. " different, never twice in a row" .. (okAll and "" or " (got " .. tostring(e:GetState()) .. ")"))
      end
      M.num["Entity.CalcDistanceSq"] = 4
      -- an owed attack lapses when the boss attacks on its own first
      st.owe = nil
      pcall(e.GotoState, e, ret)
      st.owe = st.t
      pcall(e.GotoState, e, row[4][1])
      check(st.owe == nil, name .. ": attacking on its own pays the owed attack")
      st.owe = nil
    end
  end
  -- no get-away: Hades and Peter Pan answer at once, from their lists
  for _, row in ipairs({ { "b01he00", "b01he00", { "NoRiaFingernailofFire", "BladesCrossing", "MegaFire" } },
                         { "b20pp00", "b20pp00", { "Attack1", "Attack2", "Attack3" } } }) do
    M.script(row[1])
    local e, h = M.create(row[2])
    local st = BBS_REVENGE.ents[row[2]]
    rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
    local want, okAll, last, rep = set(row[3]), true, nil, false
    for k = 1, 12 do
      pcall(e.GotoState, e, "Idling")
      st.rv, st.firing, st.armor = st.limit + 1, true, 0
      local c0 = st.count
      for i = 1, 3 do if hit(h) ~= nil then break end end
      if st.count == c0 or not want[e:GetState()] then okAll = false end
      if st.lastAnswer == last then rep = true end
      last = st.lastAnswer
      if st.owe ~= nil then okAll = false end                 -- answered: nothing more owed
    end
    check(okAll and not rep, row[2] .. ": break-out = one of his attacks at once, never twice in a row")
  end
  -- the whole path: Vanitas breaks out with his cartwheel and attacks when it ends
  M.script("b63ex00")
  local e, h = M.create("b63ex00")
  local st = BBS_REVENGE.ents.b63ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  M.num["Entity.CalcDistanceSq"] = 900            -- at range he breaks out with his cartwheel
  pcall(e.GotoState, e, "Idling")
  st.rv, st.firing, st.armor, st.owe = st.limit - 0.5, false, 0, nil
  for i = 1, 3 do if hit(h) ~= nil then break end end
  local s1 = e:GetState()
  check(s1 == "Cartwheel" and st.owe ~= nil, "Aqua's Vanitas: break-out = his cartwheel, an attack owed (" .. tostring(s1) .. ")")
  pcall(e.GotoState, e, e.stack:pop(1))          -- his cartwheel ends (its own pop)
  local s2 = e:GetState()
  M.num["Entity.CalcDistanceSq"] = 4
  check((s2 == "Warp2" or s2 == "ShadowDiving" or s2 == "DarkThundaga") and st.armor > 0,
        "... and when it ends he attacks at once, armoured (" .. tostring(s2) .. ")")
end
-- a hit on armour leaves the boss's idle pause alone (Vanitas / Eraqus zero it on every hit)
do
  M.script("b63ex00")
  local e, h = M.create("b63ex00")
  local st = BBS_REVENGE.ents.b63ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  e.idlingTimer = 90
  M.num["Enemy.IsNoDamageReaction"] = true
  hit(h)
  M.num["Enemy.IsNoDamageReaction"] = false
  check(e.idlingTimer == 90, "Vanitas hit on armour: his next pause is kept (" .. tostring(e.idlingTimer) .. ")")
  st.rv, st.firing = 0, false
  hit(h)
  check(e.idlingTimer == 0, "... a hit that lands still cuts it, as in vanilla (" .. tostring(e.idlingTimer) .. ")")
end
-- the opening: the first idle after the entrance is an attack from the boss's list (no armour of ours),
-- then its own loop; bosses without a list (superbosses) as they were
do
  BBS_REVENGE.opening = true
  M.num["Enemy.SearchEnemy"] = function() return NULL_HANDLE end
  local rows = {
    { "b63ex00", "b63ex00", "Idling", { SuccessionAttack2 = true, DarkThundaga = true } },
    { "b20ex00", "b20ex00", "Idling", { SuccessionAttack = true, RushAttack = true, Kagerou = true } },
    { "b20pp00", "b20pp00", "BattleStartState", { Attack1 = true, Attack2 = true, Attack3 = true } },
    { "b01pp00", "b01pp00", "Idling", { JumpCutting = true, RushStab = true, DisturbStab = true } },
  }
  for _, row in ipairs(rows) do
    M.script(row[1])
    local e, h = M.create(row[2])
    local st = BBS_REVENGE.ents[row[2]]
    rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
    st.opening = true
    pcall(e.GotoState, e, row[3])
    local first = st.lastAnswer
    check(row[4][first] == true and st.opening == false and st.armor == 0,
          row[2] .. ": opens the fight with " .. tostring(first) .. " instead of " .. row[3] .. ", no armour of ours")
    st.lastAnswer = nil
    pcall(e.GotoState, e, row[3])
    check(st.lastAnswer == nil, row[2] .. ": ... once - the next " .. row[3] .. " is his own")
  end
  M.script("b12ex00")
  local e, h = M.create("b12ex00")
  local st = BBS_REVENGE.ents.b12ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  check(st.opening == false and e:GetState() == "Idling", "Vanitas Remnant (superboss): no opening attack")
  BBS_REVENGE.opening = false
end
-- bbskh2_boss.ini: armour windows, gaps between attacks, cooldowns (the shipped file, then the live one)
do
  local RVs = BBS_REVENGE
  local log = {}
  M.num["Enemy.EnableNoDamageReaction"] = function(h, v) log[h] = v end
  M.num["Enemy.IsNoDamageReaction"] = function(h) return log[h] == 1 end
  local tlog = {}
  M.num["Entity.SetTimer"] = function(h, v) tlog[h] = v end
  local pr = RVs.bossProfile("b10ex00")
  check(pr ~= nil and pr.name == "Vanitas" and pr.moves.SuccessionAttack1 == 36 and pr.moves.ShadowDiving == "vanilla"
        and pr.moves.Cartwheel == "vanilla" and pr.cd.DarkFiraga == 180 and pr.cd.ShadowDiving == nil
        and pr.beat[1] == 15 and pr.beat[2] == 24 and pr.chain[1] == 2 and pr.chain[2] == 4 and pr.pause[1] == 25
        and pr.repo.BackhandsSpringJump and pr.repoList[2] == "Cartwheel", "ini: Vanitas's section read")
  check(RVs.bossProfile("b30ex00").name == "Braig" and RVs.bossProfile("b30ex00").moves.DashShoot == 56
        and RVs.bossProfile("b32ex00").name == "Braig" and RVs.bossProfile("b32ex00").moves.DashShoot == 56 and RVs.bossProfile("b52ex00").moves.Attack3 == 166
        and RVs.bossProfile("b52ex00").cd.Attack3 == 720 and RVs.bossProfile("b85vs00") == nil and RVs.bossProfile("b12ex00").name == "Vanitas Remnant",
        "ini: Braig, Terra-Xehanort, Vanitas Remnant by their ids; no section = nil (No Heart)")
  -- the live file wins per key (the DLL's BBS_BossIni), re-read for every boss created
  BBS_BossIni = function(sec) if sec == "Vanitas" then return "SuccessionAttack1 = 20 ; shorter\nBeat=30-30\nDarkThundaga = all, cooldown 2\n" end end
  local p2 = RVs.bossProfile("b10ex00")
  check(p2.moves.SuccessionAttack1 == 20 and p2.beat[1] == 30 and p2.moves.DarkThundaga == true and p2.cd.DarkThundaga == 120
        and p2.moves.DarkFiraga == 48, "ini: the file in the game folder overrides key by key")
  BBS_BossIni = nil
  -- Vanitas: his combo armoured for its first 36 frames (counted while he is visible), then open
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  local st = RVs.ents.b10ex00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  pcall(e.GotoState, e, "SuccessionAttack1")
  check(log[h] == 1 and st.mArmor == 36, "Vanitas's combo: armoured from its start (36 frames)")
  M.num["Entity.GetAlpha"] = 0
  for i = 1, 40 do pcall(e.OnUpdate, e) end
  check(st.mArmor == 36 and log[h] == 1, "... not counted while he is hidden (a warp)")
  M.num["Entity.GetAlpha"] = 1
  for i = 1, 35 do pcall(e.OnUpdate, e) end
  check(log[h] == 1, "... still armoured at frame 35")
  for i = 1, 2 do pcall(e.OnUpdate, e) end
  check(log[h] == 0 and st.winOff, "... open from frame 36 on")
  -- the beat: his Idling timer
  st.chain, st.chainN = 0, 9
  pcall(e.GotoState, e, "Idling")
  check(tlog[h] >= 15 and tlog[h] <= 24 and log[h] == 0, "... then the beat, 15-24 frames (" .. tostring(tlog[h]) .. ")")
  -- after Chain attacks: a reposition instead of the idle, back through his stack
  st.chain, st.chainN = 3, 3
  pcall(e.GotoState, e, "DarkThundaga")
  pcall(e.GotoState, e, "Idling")
  local rs = e:GetState()
  check((rs == "BackhandsSpringJump" or rs == "Cartwheel") and e.stack:getn() >= 1 and st.chain == 0,
        "after his chain of attacks: " .. tostring(rs) .. " instead of Idling, Idling on his stack")
  -- after a reposition: sometimes a pause, broken when the player comes close
  local mr = M.rand
  M.rand = function() return 0 end
  pcall(e.GotoState, e, "Idling")
  M.rand = mr
  check(st.pauseOn and tlog[h] == 60, "after the reposition: a pause (" .. tostring(tlog[h]) .. " frames)")
  M.num["Entity.CalcDistanceSq"] = 4
  pcall(e.OnUpdate, e)
  check(not st.pauseOn and tlog[h] == 0, "... broken when the player is within 3 m: he attacks")
  M.num["Entity.CalcDistanceSq"] = nil
  -- an attack on cooldown is swapped for another of his (answer pick); the answer itself ignores cooldowns
  st.cdUntil.DarkFiraga = st.t + 1000
  st.chain, st.chainN, st.reroll = 0, 9, 0
  pcall(e.GotoState, e, "Idling")
  pcall(e.GotoState, e, "DarkFiraga")
  check(e:GetState() ~= "DarkFiraga" and e:GetState() ~= "Idling", "Dark Firaga on cooldown: another attack instead (" .. e:GetState() .. ")")
  -- everything on cooldown: the one closest to ready
  for _, n in ipairs{ "SuccessionAttack1", "DarkFiraga", "DarkThundaga", "Warp1" } do st.cdUntil[n] = st.t + 1000 end
  st.cdUntil.DarkThundaga = st.t + 10
  st.reroll = 0
  pcall(e.GotoState, e, "Idling")
  M.num["Entity.CalcDistanceSq"] = 100
  pcall(e.GotoState, e, "DarkFiraga")
  M.num["Entity.CalcDistanceSq"] = nil
  check(e:GetState() == "DarkThundaga", "all on cooldown: the one closest to ready, never a stand-still (" .. e:GetState() .. ")")
  -- no answer to swap with (riding): he decides again, twice; then he goes ahead
  e.rideMode = true
  st.reroll = 0
  pcall(e.GotoState, e, "Idling")
  pcall(e.GotoState, e, "DarkFiraga")
  local s1 = e:GetState()
  pcall(e.GotoState, e, "DarkFiraga")
  local s2 = e:GetState()
  pcall(e.GotoState, e, "DarkFiraga")
  check(s1 == "Idling" and s2 == "Idling" and e:GetState() == "DarkFiraga" and tlog[h] <= 2,
        "nothing to swap with: decides again (" .. s1 .. ", " .. s2 .. "), then goes ahead (" .. e:GetState() .. ")")
  e.rideMode = false
  -- Braig: Inverted Shoot is armoured by his own script; past its window it is held open
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  local st3 = RVs.ents.b30ex00
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "InvertedShoot")
  local open, n = false, 0
  for i = 1, 80 do
    pcall(e3.OnUpdate, e3)
    if e3:GetState() ~= "InvertedShoot" then break end
    n = n + 1
    if i > 47 and log[h3] == 0 then open = true end
    Enemy.EnableNoDamageReaction(h3, 1)                     -- (as if his script switched it on again)
    pcall(e3.OnUpdate, e3)
  end
  check(open, "Braig's Inverted Shoot: open after its 46 frames although his script armours it (" .. n .. ")")
  -- ... but his descent after the last round (steps 8-11) keeps his own armour: no stagger as he comes down
  do
    pcall(e3.GotoState, e3, "Idling")
    pcall(e3.GotoState, e3, "InvertedShoot")
    for i = 1, 60 do pcall(e3.OnUpdate, e3) end              -- past the window: held open
    local roundOpen = log[h3] == 0
    e3.step = 8; e3.timer = 1000
    Enemy.EnableNoDamageReaction(h3, 1)                     -- (his script, as the descent starts)
    local kept = true
    for i = 1, 10 do pcall(e3.OnUpdate, e3); if e3.step >= 8 and log[h3] ~= 1 then kept = false end end
    check(roundOpen and kept and e3:GetState() == "InvertedShoot", "Braig's Inverted Shoot: open in its rounds, his own armour kept on the way down")
  end
  M.num["Enemy.EnableNoDamageReaction"] = nil
  M.num["Enemy.IsNoDamageReaction"] = nil
  M.num["Entity.SetTimer"] = nil
  M.num["Entity.GetAlpha"] = nil
end
-- Masked Vanitas's late fight: hits during the ride never fill the gauge; a move ending into an empty stack goes idle
local okL, errL = xpcall(function()
  M.script("b10ex00")
  local e, h = M.create("b10ex02")
  local st = BBS_REVENGE.ents.b10ex02
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "RideMode")
  e.rideMode = false                                  -- (his knock-off test needs positions this stand-in lacks)
  M.num["Entity.CalcDistanceSq"] = 4
  st.rv, st.firing, st.armor = 0, false, 0
  local mr = M.rand
  M.rand = function() return 0.99 end               -- (his own dice: no escape)
  e.dmgCount = -100                                  -- (his own growing escape chance kept low for this check)
  for i = 1, 20 do hit(h) end
  M.rand = mr
  check(st.rv == 0 and not st.firing and e:GetState() ~= "WarpAttack2", "late Vanitas: hits on his ride build no revenge (" .. tostring(st.rv) .. ", " .. e:GetState() .. ")")
  pcall(e.GotoState, e, "WarpAttack2")
  e.stack:clear()
  pcall(e.GotoState, e, e.stack:pop(1))
  check(e:GetState() == "Idling", "a move that ends into an empty stack goes to his Idling (" .. e:GetState() .. ")")
end, debug.traceback)
check(okL, "late Vanitas checks ran (" .. tostring(errL) .. ")")
-- Armor of the Master: a break-out far away is his guard, then his dash cut in the style he is in
local okA, errA = xpcall(function()
  M.script("b81vs00")
  local e, h = M.create("b81vs00")
  local st = BBS_REVENGE.ents.b81vs00
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  M.num["Entity.CalcDistanceSq"] = 900; M.num["Entity.CalcDistanceXZSq"] = 900
  for _, row in ipairs({ { 4, "IdlingT", "GodspeedCuttingT" }, { 2, "IdlingZ", "GodspeedCuttingZ" }, { 5, "IdlingA", "GodspeedCuttingA" } }) do
    pcall(e.GotoState, e, row[2])
    e.style = row[1]
    if e.stack.clear then e.stack:clear() end
    st.rv, st.firing, st.armor, st.mArmor = 0, false, 0, 0
    local r
    for i = 1, 14 do r = hit(h) if r ~= nil then break end end
    local top = e.stack:pop(1)
    check(e:GetState() == "Guard" and top == row[3],
          "Armor of the Master (style " .. row[1] .. ", far): break-out guard, then " .. row[3] .. " (" .. tostring(e:GetState()) .. ", next " .. tostring(top) .. ")")
  end
  M.num["Entity.CalcDistanceSq"] = 4; M.num["Entity.CalcDistanceXZSq"] = 4
  for _, row in ipairs({ { 4, "IdlingT", "MikiriT" }, { 2, "IdlingZ", "Aurora" } }) do
    pcall(e.GotoState, e, row[2])
    e.style = row[1]
    if e.stack.clear then e.stack:clear() end
    st.rv, st.firing, st.armor, st.mArmor = 0, false, 0, 0
    for i = 1, 14 do if hit(h) ~= nil then break end end
    check(e:GetState() == row[3], "Armor of the Master (style " .. row[1] .. ", close): break-out " .. row[3] .. " as before (" .. tostring(e:GetState()) .. ")")
  end
  M.num["Entity.CalcDistanceSq"] = nil; M.num["Entity.CalcDistanceXZSq"] = nil
end, debug.traceback)
check(okA, "Armor of the Master checks ran (" .. tostring(errA) .. ")")
-- moves with rounds inside one state: each new round gets its window again (cfg.rearm)
local okR, errR = xpcall(function()
  local rows = {
    { "b30ex00", "b30ex00", "DashShoot", "step", { 0, 1, 2, 3, 4, 5, 0, 1, 2, 3 }, { 3, 9 } },
    { "b30ex00", "b30ex00", "WarpShoot", "step", { 1, 2, 3, 4, 5, 6 }, { 5 } },
    { "b20ex00", "b20ex00", "RushAttack", "count", { 0, 0, 1, 1, 2 }, { 3, 5 } },
    { "b01he00", "b01he00", "FingernailofFire", "cnboNum", { 5, 5, 4, 4, 3 }, { 3, 5 } },
    { "b01sb00", "b01sb00", "Thunder", "count", { 8, 8, 7, 7, 6 }, { 3, 5 } },
    { "b01sb00", "b01sb00", "StaffAttack", "count", { 3, 2, 2, 1 }, { 2, 4 } },
    { "b20ls00", "b20ls00", "Lightning", "step", { 0, 1, 1, 2, 3, 4, 2, 3 }, { 4, 7 } },
    { "b81vs00", "b81vs00", "GodspeedCuttingVFinish", "count", { 0, 0, 1, 1, 2 }, { 3, 5 } },
  }
  for _, row in ipairs(rows) do
    local script, name, move, field, seq, want = row[1], row[2], row[3], row[4], row[5], row[6]
    M.script(script)
    local e, h = M.create(name)
    local st = BBS_REVENGE.ents[name]
    rawset(e, "Debug", function() end); rawset(e, "CheckPlayerPos", function() end)
    rawset(e, "RestHpRate", function() return 1 end)                              -- (stand-in values the
    rawset(e, "AttackControl", function() end); rawset(e, "ChangeDisp", function() end)   -- emulator lacks)
    local i = 0
    rawset(e, "Update", function(self) i = i + 1 self[field] = seq[i] end)
    pcall(e.GotoState, e, move)
    st.rrS = nil
    local armed = {}
    for k = 1, #seq do
      st.hitWin, st.mArmor, st.winOff = nil, 0, true            -- (the last round's window is over)
      local ok, err = pcall(e.OnUpdate, e)
      if not ok then armed[#armed + 1] = "err:" .. tostring(err) break end
      if (st.mArmor or 0) > 0 then armed[#armed + 1] = k end
    end
    local got = table.concat(armed, ",")
    check(got == table.concat(want, ","), name .. " " .. move .. ": a new window at each new round (updates " .. got .. ")")
    rawset(e, "Update", function() end)
  end
end, debug.traceback)
check(okR, "round checks ran (" .. tostring(errR) .. ")")
-- [Mobs]: regular enemies wait less (Scrapper m02ex00: Idling 180, Wander 240..480, Stiffening 180 in its script)
do
  local okM, errM = pcall(function()
    local RVx = BBS_REVENGE
    check(RVx.mobOn == 1 and RVx.mobWait == 0.5 and RVx.mobFloor == 0.3 and RVx.mobWander == 0.5 and RVx.mobRecover == 1, "mob pace defaults (markers unpatched)")
    local set = {}
    M.num["Entity.SetTimer"] = function(h, v) set[#set + 1] = v end
    M.script("m02ex00")
    local e, h = M.create("m02ex00")
    check(e ~= nil and rawget(e, "__rvmob") ~= nil, "Scrapper gets the mob pace")
    rawset(e, "Update", function() end)
    set = {}; pcall(e.GotoState, e, "Idling")
    check(set[1] ~= nil and set[1] > 89 and set[1] < 91.5, "Idling: 180 (+0..1) -> " .. tostring(set[1]))
    set = {}; pcall(e.GotoState, e, "Wander")
    check(set[1] ~= nil and set[1] >= 120 and set[1] <= 240, "Wander: 240..480 -> " .. tostring(set[1]))
    set = {}; pcall(e.GotoState, e, "Stiffening")
    check(set[1] == 180, "Stiffening (the stagger) kept: " .. tostring(set[1]))
    local mv = RVx.mobValue
    check(mv("idle", 30) == 18 and mv("idle", 15) == 15 and mv("idle", 60) == 30 and mv("idle", 300) == 150, "floor 0.3 s: 30 -> 18, 15 stays, 60 -> 30, 300 -> 150 (" .. mv("idle", 30) .. ")")
    check(mv(nil, 300) == 300 and mv("recover", 300) == 300, "other states and the stagger: as the game has them")
    -- a boss is not paced as a mob, and a mob not listed (Prize Pod) is left alone
    check(RVx.mobs.m23ex00 == nil and RVx.mobs.b20pp00 == nil and RVx.mobs.m01sb00 and RVx.mobs.m57ex00 and RVx.mobs.m22ex00s and RVx.mobs.m02sb00b and RVx.mobs.m18vs00 == nil,
          "list: Prize Pod, Peter Pan and the arena copies out; goons, Final Mix Unversed and the story variants in")
    -- the Heartless: a lighter scale (HeartlessScale 0.75) for their waits, their stagger as the others
    check(RVx.mobHeartless == 0.75 and RVx.mobs.m40ex00 and RVx.mobs.m41ex00 and RVx.mobs.m42ex00, "Heartless listed, scale 0.75 (marker unpatched)")
    check(mv("wander", 300, "m40ex00") == 225 and mv("idle", 300, "m42ex00") == 225 and mv("recover", 480, "m41ex00") == 480
          and mv("idle", 20, "m42ex00") == 18 and mv("idle", 15, "m42ex00") == 15 and mv("idle", 300, "m01ex00") == 150, "Heartless: 300 -> 225 (Unversed 150), stagger kept, the 0.3 s floor")
    M.script("m42ex00")
    local d = M.create("m42ex00")
    check(d ~= nil and rawget(d, "__rvmob") ~= nil, "Darkball gets the pace")
    rawset(d, "Update", function() end)
    local rand0 = M.rand
    M.rand = function() return 0.999 end           -- its longest drift (Script.Random comes from M.rand)
    set = {}; pcall(d.GotoState, d, "Move")
    local want = nil
    M.rand = rand0
    check(set[1] ~= nil and set[1] > 30, "Darkball Move (its drift between attacks): " .. tostring(set[1]))
    set = {}; pcall(d.GotoState, d, "Bite")
    check(#set == 0 or set[1] == nil or set[1] >= 0, "Darkball Bite (an attack): its own timer")
    M.script("m40ex00")
    local sh = M.create("m40ex00")
    check(sh ~= nil and rawget(sh, "__rvmob") ~= nil and rawget(sh, "__rvmob").pace ~= nil, "Shadow gets the pace")
    local sst = rawget(sh, "__rvmob"); sst.state = "ShadowMove"
    check(sst.pace(rawget(sh, "myHandle"), 300) == 225, "Shadow crawl (ShadowMove) 300 -> " .. tostring(sst.pace(rawget(sh, "myHandle"), 300)))
    sst.state = "Piercing"
    check(sst.pace(rawget(sh, "myHandle"), 300) == 300, "Shadow attack (Piercing): its own timer")
    RVx.mobOn = 0
    local e2 = M.create("m02ex00")
    check(e2 ~= nil and rawget(e2, "__rvmob") == nil, "Enabled=0: no pace")
    RVx.mobOn = 1
    M.num["Entity.SetTimer"] = nil
  end)
  check(okM, "mob pace checks ran (" .. tostring(errM) .. ")")
end
-- Zack's jumps: armoured from start to landing (last: its state changes roll dice, which would shift the counts above)
M.script("b40he00")
do
  local e, h = M.create("b30he00")
  local lock
  M.num["Enemy.EnableNoDamageReaction"] = function(hh, on) if hh == h then lock = on end end
  for _, s in ipairs({ "BackJump", "BackJump_Short", "BackJump_Short_Cancel" }) do
    lock = nil
    e.stack:clear(); e.stack:push("Move")
    pcall(e.GotoState, e, s)
    check(e:GetState() == s and lock == 1, "Zack " .. s .. ": armoured (lock " .. tostring(lock) .. ", " .. e:GetState() .. ")")
  end
  pcall(e.GotoState, e, "Move")
  check(lock == 0, "... and open again once he walks (lock " .. tostring(lock) .. ")")
  M.num["Enemy.EnableNoDamageReaction"] = nil
end
-- helmet Zack (his story fight: layout parameter 0, the mode that reads the long parameter names)
do
  local real = { IdlingTime = 1.0, MoveTime = 1.0, ChaIdlingT = 2.0, ActionDist1 = 5, ComboDist = 2,
                 Action1Rate = 50, Action2Rate = 40, Action3Rate = 30, Action4Rate = 70, Action5Rate = 60, Action6Rate = 60 }
  M.num["Enemy.GetExtraParam"] = function(h, n) return real[n] or 8 end
  M.num["Entity.GetLayoutParam"] = 0
  M.num["Script.GetDebugTestParam"] = 0
  M.script("b40he00")
  local e, h = M.create("b30he00")
  rawset(e, "AddBushinCnt", function() end)
  -- strafe and idle as short as the helmetless Zack's
  check(e:GetIdlingTime() == 30 and e:GetMoveTime() == 30 and e:GetIdlingChangeTime() == 180,
        "helmet Zack: idle " .. tostring(e:GetIdlingTime()) .. ", strafe " .. tostring(e:GetMoveTime()) .. ", moving " .. tostring(e:GetIdlingChangeTime()) .. " frames (30 / 30 / 180)")
  check(BBS_REVENGE.cfg.b60vs00.setup == nil, "Mirage Arena Zack: no change")
  -- dice in order: the next values Script.Random gives
  local q = {}
  local mr = M.rand
  M.rand = function() if #q > 0 then return table.remove(q, 1) end return mr() end
  local function decide(rolls, dist)
    M.num["Entity.CalcDistanceSq"] = dist
    BBS_REVENGE.ents.b30he00.owe = nil
    pcall(e.GotoState, e, "Idling")
    e.stack:clear()
    q = rolls                                                 -- (after the idle's own dice)
    e:EnableActionSelect()
    return e:GetState()
  end
  -- close (3 m), not the combo (0.9 > 50 %), then our roll
  check(decide({ 0.9, 0.2 }, 9) == "Approache", "close, no combo picked, our roll 0.2: the combo instead (" .. e:GetState() .. ")")
  check(decide({ 0.9, 0.8 }, 9) == "BackJump", "... our roll 0.8: his own back-up and Hakougeki (" .. e:GetState() .. ")")
  check(decide({ 0.9, 0.2 }, 1) == "ComboAttack", "within combo range: straight into the combo (" .. e:GetState() .. ")")
  -- after a Hakougeki, player near: follow-up
  local function after(rolls, dist)
    pcall(e.GotoState, e, "Hakougeki")
    q = rolls
    M.num["Entity.CalcDistanceSq"] = dist
    pcall(e.GotoState, e, "Move")
    return e:GetState()
  end
  BBS_REVENGE.ents.b30he00.cdUntil = {}
  check(after({ 0.1, 0.2 }, 9) == "Climbhazard", "Hakougeki, player near, follow-up roll 0.1 / 0.2: Climbhazard (" .. e:GetState() .. ")")
  check(after({ 0.1, 0.7 }, 1) == "ComboAttack", "... 0.1 / 0.7, within combo range: the combo (" .. e:GetState() .. ")")
  BBS_REVENGE.ents.b30he00.cdUntil = { Climbhazard = 1e9 }
  check(after({ 0.1, 0.2 }, 1) == "ComboAttack", "... Climbhazard cooling down: the combo (" .. e:GetState() .. ")")
  BBS_REVENGE.ents.b30he00.cdUntil = {}
  check(after({ 0.6 }, 9) == "Move", "... roll 0.6: no follow-up (" .. e:GetState() .. ")")
  check(after({ 0.1, 0.2 }, 36) == "Move", "... player far: no follow-up (" .. e:GetState() .. ")")
  -- the helmetless Zack (his simple mode): the same up close; his own strafe / idle times untouched
  real = { IdlingTime = 0.5, MoveTime = 0.5, ChaIdlingT = 3.0, ActionDist1 = 5, ComboDist = 2,
           Action1Rate = 50, Action2Rate = 40, Action3Rate = 30, Action4Rate = 70, Action5Rate = 60, Action6Rate = 60 }
  M.script("b40he00")
  local es = M.create("b40he00")
  rawset(es, "AddBushinCnt", function() end)
  check(es:GetIdlingTime() == 30 and es:GetMoveTime() == 30 and es:GetIdlingChangeTime() == 180, "helmetless Zack: his own 30 / 30 / 180")
  local function decideS(rolls, dist)
    M.num["Entity.CalcDistanceSq"] = dist
    BBS_REVENGE.ents.b40he00.owe = nil
    pcall(es.GotoState, es, "Idling")
    es.stack:clear()
    q = rolls                                                 -- (after the idle's own dice)
    es:EnableActionSelect()
    return es:GetState()
  end
  check(decideS({ 0.9, 0.1, 0.2 }, 9) == "Approache", "helmetless, close, back-up and Hakougeki, our roll 0.2: the combo instead (" .. es:GetState() .. ")")
  check(decideS({ 0.9, 0.1, 0.8 }, 9) == "BackJump", "... our roll 0.8: his own back-up and Hakougeki (" .. es:GetState() .. ")")
  check(decideS({ 0.9, 0.9 }, 9) == "BackJump", "... his back-up and Climbhazard: as it was (" .. es:GetState() .. ")")
  pcall(es.GotoState, es, "Hakougeki")
  BBS_REVENGE.ents.b40he00.cdUntil = {}
  q = { 0.1, 0.7 }; M.num["Entity.CalcDistanceSq"] = 1
  pcall(es.GotoState, es, "Move")
  check(es:GetState() == "ComboAttack", "helmetless, after a Hakougeki, player near, 0.1 / 0.7: the combo (" .. es:GetState() .. ")")
  M.rand = mr
  M.num["Entity.CalcDistanceSq"] = 4
  -- his strongest mode on the same entry: none of this
  M.num["Entity.GetLayoutParam"] = 1
  real = { IdlingTim = 0.75, MoveTim = 0.5, ChaIdlinT = 3.0 }
  M.script("b40he00")
  local e3 = M.create("b30he00")
  check(e3:GetIdlingTime() == 45 and e3:GetMoveTime() == 30 and e3:GetIdlingChangeTime() == 180, "strongest mode: times as his data has them")
  pcall(e3.GotoState, e3, "Hakougeki"); M.num["Entity.CalcDistanceSq"] = 1
  pcall(e3.GotoState, e3, "Move")
  check(e3:GetState() == "Move", "strongest mode: no follow-up (" .. e3:GetState() .. ")")
  M.num["Entity.CalcDistanceSq"] = 4
  M.num["Entity.GetLayoutParam"] = nil
  M.num["Script.GetDebugTestParam"] = nil
  M.num["Enemy.GetExtraParam"] = 8
end
-- Experiment 221's Electric Ball: armoured until the ball is thrown (frame 40), then open
do
  M.script("b20ls00")
  local e, h = M.create("b20ls00")
  local st = BBS_REVENGE.ents.b20ls00
  local lock
  M.num["Enemy.EnableNoDamageReaction"] = function(hh, on) if hh == h then lock = on end end
  M.num["Entity.GetMotionNowFrame"] = 0
  pcall(e.GotoState, e, "ElectricBall")
  check(e:GetState() == "ElectricBall" and lock == 1 and (st.mArmor or 0) > 1e8, "221 Electric Ball: armoured from its start")
  M.num["Entity.GetMotionNowFrame"] = 12
  for i = 1, 3 do e:OnUpdate() end
  check(e.step == 1 and lock == 1 and st.mArmor > 1e8, "... the ball made (step " .. tostring(e.step) .. "): still armoured")
  M.num["Entity.GetMotionNowFrame"] = 41
  e:OnUpdate()
  check(e.step == 2 and st.mArmor == 0 and st.winOff == true and lock == 0, "... thrown: open (step " .. tostring(e.step) .. ", lock " .. tostring(lock) .. ")")
  e:OnUpdate()
  check(lock == 0, "... and stays open")
  M.num["Entity.GetMotionNowFrame"] = 0
  M.num["Enemy.EnableNoDamageReaction"] = nil
end
-- Peter Pan, experimental (2026-11-03): short multi-hit, faster flight, the charge as Attack4, the warning trail
do
  M.script("b20pp00")
  local e, h = M.create("b20pp00")
  local st = BBS_REVENGE.ents.b20pp00
  rawset(e, "Debug", function() end)
  check(st.limit >= 11 and st.limit <= 13, "Peter Pan: limit 12 (+- 1): " .. st.limit)
  -- Attack3: 2 swings, then the finisher
  pcall(e.GotoState, e, "Attack3")
  check(e:GetState() == "Attack3" and e.attackLoopCnt == 3, "Attack3 starts its swing count at 3 (" .. tostring(e.attackLoopCnt) .. ")")
  local swings, fin = 0, false
  M.num["Entity.SetMotion"] = function(hh, m) if m == "311" then fin = true end end
  e.step = 1
  M.num["Entity.IsMotionEnd"] = true
  for i = 1, 6 do if not fin then swings = swings + 1 end e:OnUpdate() end
  M.num["Entity.IsMotionEnd"] = false
  M.num["Entity.SetMotion"] = nil
  check(fin and swings == 2, "... the finisher after 2 swings (" .. swings .. ")")
  -- faster flight
  local got
  M.num["Entity.CalcVelocity"] = function(hh, v) got = v end
  e.Speed = 1
  e:MoveEx(0.16, 0.01)
  check(got ~= nil and math.abs(got - 0.24) < 1e-4, "his flight speeds x1.5 (0.16 -> " .. tostring(got) .. ")")
  M.num["Entity.CalcVelocity"] = nil
  -- flying around: the charge after 30 frames
  M.num["Entity.CalcDistance"] = 10
  pcall(e.GotoState, e, "Move")
  for i = 1, 20 do e:OnUpdate() end
  check(e:GetState() == "Move", "Move: still flying around after 20 frames (" .. e:GetState() .. ")")
  for i = 1, 15 do e:OnUpdate() end
  check(e:GetState() == "Attack4" and e.step == 0, "... then the charge (" .. e:GetState() .. ")")
  -- his own charge inside Move goes to the attack too
  pcall(e.GotoState, e, "Move")
  e:OnUpdate()
  e.step, e.Wait = 4, 300            -- as his script starts it (Move step 1, the 40% roll)
  e:OnUpdate()
  check(e:GetState() == "Attack4", "his own charge (Move step 4) becomes Attack4 (" .. e:GetState() .. ")")
  -- the charge: flies, stabs within 4 m, ends with the stab
  local mot
  local grp
  M.num["Entity.SetMotionWithSameCheck"] = function(hh, m, a3, a4) mot = m if m == "300" then grp = a4 end end
  pcall(e.GotoState, e, "Idling")
  e.attackCnt = 3
  pcall(e.GotoState, e, "Attack4")
  check((st.mArmor or 0) > 1e8 and st.hitWin ~= nil and st.hitWin.fallback == 180, "the charge: armoured until the stab's hits are over (hit 180)")
  do
    local asked, set = {}, {}
    for _, f in ipairs({ "Kind", "Attr", "Point", "PowerCorrection" }) do
      M.num["Enemy.GetAttack" .. f] = function(hh, n) asked[f] = n return 100 + #f end
    end
    for _, f in ipairs({ "AttackKind", "AttackAttr", "AttackPoint", "TechniquePowerCorrection" }) do
      M.num["Entity.Set" .. f .. "ForBodyColl"] = function(hh, v) set[f] = v end
    end
    pcall(e.GotoState, e, "Idling")
    e.attackCnt = 3
    pcall(e.GotoState, e, "Attack4")
    for _, f in ipairs({ "Kind", "Attr", "Point", "PowerCorrection" }) do M.num["Enemy.GetAttack" .. f] = nil end
    for _, f in ipairs({ "AttackKind", "AttackAttr", "AttackPoint", "TechniquePowerCorrection" }) do M.num["Entity.Set" .. f .. "ForBodyColl"] = nil end
    check(asked.Kind == 2 and asked.Attr == 2 and asked.Point == 2 and asked.PowerCorrection == 2
          and set.AttackKind == 104 and set.AttackAttr == 104 and set.AttackPoint == 105 and set.TechniquePowerCorrection == 115,
          "the charge: his body collision takes attack #2 (Attack2's stab): kind, attr, point, correction")
  end
  e:OnUpdate()
  check(e.step == 0 and (mot == "032" or mot == "033" or mot == "034"), "charging: flight motion (" .. tostring(mot) .. ")")
  do
    local deg
    M.num["Entity.TurnTargetDegree"] = function(hh, t, d) deg = d end
    e.Angle = 0
    e:OnUpdate()
    local first = deg
    for i = 1, 120 do e.Wait = 100 e:OnUpdate() end
    M.num["Entity.TurnTargetDegree"] = nil
    check(first ~= nil and math.abs(first - 0.15) < 1e-4 and math.abs(deg - 15) < 1e-4,
          string.format("charge homing x3: +0.15 deg/frame up to 15 (%s, %s)", tostring(first), tostring(deg)))
  end
  M.num["Entity.CalcDistance"] = 6
  M.num["Entity.CalcDistanceXZ"] = 6
  e:OnUpdate()
  check(e.step == 0, "6 m: still flying (step " .. tostring(e.step) .. ")")
  M.num["Entity.CalcDistance"] = 5
  M.num["Entity.CalcDistanceXZ"] = 3          -- height 4 over 3 on the ground: above you
  e:OnUpdate()
  check(e.step == 0, "within 5.5 m but above you (height 4, ground 3): keeps flying (step " .. tostring(e.step) .. ")")
  M.num["Entity.CalcDistanceXZ"] = 0          -- straight over your head
  e:OnUpdate()
  check(e.step == 0, "... straight overhead: keeps flying (step " .. tostring(e.step) .. ")")
  M.num["Entity.CalcDistanceXZ"] = 4.8        -- height ~1.4 over 4.8: shallow
  M.num["Entity.CalcDistance"] = 5.2          -- ... but further than last frame: flying away (past you)
  e:OnUpdate()
  check(e.step == 0, "level and in reach but not closing in (flying away): keeps flying (step " .. tostring(e.step) .. ")")
  M.num["Entity.CalcDistance"] = 5            -- closing in again
  e:OnUpdate()
  M.num["Entity.CalcDistanceXZ"] = 2          -- (the emulator's default)
  check(e.step == 1 and mot == "300", "within 5.5 m, coming in shallow: the stab (" .. tostring(mot) .. ")")
  check(grp == 0, "... with attack group 0 = his Attack2's stab, which a guard blocks (" .. tostring(grp) .. ")")
  M.num["Entity.IsMotionEnd"] = true
  e:OnUpdate()
  M.num["Entity.IsMotionEnd"] = false
  check(e:GetState() == "BeforeAttackIdling" and e.attackCnt == 2, "the stab done: next attack (" .. e:GetState() .. ")")
  -- a charge that cannot reach gives up
  M.num["Entity.CalcDistance"] = 30
  pcall(e.GotoState, e, "Attack4")
  for i = 1, 185 do e:OnUpdate() if e:GetState() ~= "Attack4" then break end end
  check(e:GetState() ~= "Attack4", "a charge that cannot reach gives up (" .. e:GetState() .. ")")
  M.num["Entity.SetMotionWithSameCheck"] = nil
  -- the warning: trail on near the limit, kept through his OnDamage, off once the gauge drains
  local made, ended = 0, 0
  M.num["Effect.IsAlive"] = false
  M.num["Entity.AttachEffect"] = function() made = made + 1 return 1 end
  M.num["Effect.LoopEnd"] = function() ended = ended + 1 end
  M.num["Entity.CalcDistance"] = 2
  pcall(e.GotoState, e, "Idling")
  st.rv, st.firing, st.armor = 0, false, 0
  e:OnUpdate()
  check(rawget(e, "__ppWarn") ~= true, "no warning on an empty gauge")
  st.rv = st.limit - 2.5
  e:OnUpdate()
  check(rawget(e, "__ppWarn") ~= true, "... nor 2.5 short of the limit")
  st.rv = st.limit - 1.5
  made = 0
  e:OnUpdate()
  check(rawget(e, "__ppWarn") == true and made > 0, "2 or less short of the limit: the trail lights up (" .. made .. ")")
  ended = 0
  pcall(e.DashEffectControler, e, 0)
  check(ended == 0, "... and his own 'trail off' (every OnDamage) leaves it on")
  st.rv = 0
  e:OnUpdate()
  check(rawget(e, "__ppWarn") == false and ended > 0, "the gauge drained: the trail goes out")
  M.num["Effect.IsAlive"] = nil; M.num["Entity.AttachEffect"] = nil; M.num["Effect.LoopEnd"] = nil
  M.num["Entity.CalcDistance"] = 2
end
-- Master Eraqus: his stand-still in Wander lasts 30-60 frames (his own 60-120); his hold-back after fleeing 30-60
do
  M.script("b20ex00")
  local e, h = M.create("b20ex00")
  rawset(e, "Debug", function() end)
  rawset(e, "RestHpRate", function() return 1 end)
  local st = BBS_REVENGE.ents.b20ex00
  check(st.pr ~= nil and st.pr.pause[1] == 25 and st.pr.pause[2] == 30 and st.pr.pause[3] == 60,
        "Eraqus: hold-back after fleeing 25%, 30-60 frames (" .. tostring(st.pr and st.pr.pause[2]) .. "-" .. tostring(st.pr and st.pr.pause[3]) .. ")")
  pcall(e.GotoState, e, "Wander")
  M.num["Entity.IsTimeOver"] = false
  M.num["Entity.IsWall"] = false
  M.num["Entity.CalcDistanceXZSq"] = 36
  local asked
  M.num["Script.RandomInRange"] = function(a, b) asked = (asked or "") .. a .. "-" .. b .. " " return b end
  local mr = M.rand
  M.rand = function() return 0.1 end          -- under 0.25: he stands still
  e.step, e.walkTimer, e.timer = 0, 0, 5
  e:OnUpdate()
  check(e.step == 1 and e.walkTimer == 60, "Wander: he stands still for 30-60 frames (" .. tostring(e.walkTimer) .. ", asked " .. tostring(asked) .. ")")
  M.rand = function() return 0.9 end          -- a walk step: his own 60-120
  e.step, e.walkTimer = 0, 0
  e:OnUpdate()
  check(e.step == 0 and e.walkTimer == 120, "Wander: his walk steps unchanged, 60-120 (" .. tostring(e.walkTimer) .. ")")
  M.rand = mr
  M.num["Script.RandomInRange"] = nil
  M.num["Entity.IsTimeOver"] = nil
  M.num["Entity.IsWall"] = nil
  M.num["Entity.CalcDistanceXZSq"] = nil
end
-- Master Eraqus: out of a flinch in an attack he does not restart it (his own OnReturnDamage did)
do
  M.script("b20ex00")
  local e, h = M.create("b20ex00")
  rawset(e, "Debug", function() end)
  rawset(e, "RestHpRate", function() return 1 end)
  for _, a in ipairs({ "RushAttack", "SuccessionAttack", "Oboro" }) do
    pcall(e.GotoState, e, a)
    e.reflect = false
    local p0 = e.stack.ptr
    EntityManager:CallFunctionNoArg("OnReturnDamage", h)
    -- (Oboro is "no damage reaction" in his script: a flinch out of it only happens in this test, and
    -- the mod's own handling adds an Idling there; that can also happen in SuccessionAttack, depending on
    -- the dice - about 1 run in 4.  Either way he does not restart it: Idling, then Wander)
    check(e:GetState() == "Idling" and (e.stack:get() == "Wander" or (e.stack:get() == "Idling" and e.stack:get(2) == "Wander")),
          "Eraqus: out of a flinch in " .. a .. ": Idling, Wander next - not " .. a .. " again (" .. e:GetState() .. ")")
    while e.stack.ptr > p0 do e.stack:pop() end
  end
  pcall(e.GotoState, e, "Wander")
  e.reflect = false
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(e:GetState() == "Wander", "Eraqus: out of a flinch in Wander: his own (back to Wander) (" .. e:GetState() .. ")")
  -- his next pick after a flinch out of RushAttack is not RushAttack (mid range: a die under 0.3 is RushAttack)
  M.num["Entity.CalcDistanceXZSq"] = 36
  local mr = M.rand
  pcall(e.GotoState, e, "RushAttack")
  e.reflect = false
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  local q = { 0.1 }
  M.rand = function() if #q > 0 then return table.remove(q, 1) end return 0.4 end
  local stk = e.stack
  local p0 = stk.ptr
  local ok = e:SelectAttack()
  local picked = {}
  for i = p0, stk.ptr - 1 do picked[#picked + 1] = tostring(stk._et[i]) end
  local rush = false
  for _, v in ipairs(picked) do if v == "RushAttack" then rush = true end end
  check(ok and not rush, "Eraqus: right after a flinch out of RushAttack his pick is not RushAttack (" .. table.concat(picked, ",") .. ")")
  while stk.ptr > p0 do stk:pop() end
  -- the pick after that: his own dice again (RushAttack allowed)
  q = { 0.1 }
  ok = e:SelectAttack()
  check(ok and stk:get() == "RushAttack", "... and only that pick: the next may be RushAttack (" .. tostring(stk:get()) .. ")")
  while stk.ptr > p0 do stk:pop() end
  M.rand = mr
  M.num["Entity.CalcDistanceXZSq"] = nil
end
-- Master Eraqus: an attack he did twice in a row is barred until he does another - his own picks, the
-- mod's answers, his guard counter
do
  M.script("b20ex00")
  local e, h = M.create("b20ex00")
  rawset(e, "Debug", function() end)
  rawset(e, "RestHpRate", function() return 1 end)
  M.num["Entity.CalcDistanceXZSq"] = 36       -- mid range: a die under 0.3 is RushAttack
  local mr = M.rand
  local stk = e.stack
  local function pick(dice)
    local q = dice
    M.rand = function() if #q > 0 then return table.remove(q, 1) end return 0.4 end
    local p0 = stk.ptr
    local ok = e:SelectAttack()
    local got = {}
    for i = p0, stk.ptr - 1 do got[#got + 1] = tostring(stk._et[i]) end
    while stk.ptr > p0 do stk:pop() end
    return table.concat(got, ",")
  end
  pcall(e.GotoState, e, "RushAttack")
  pcall(e.GotoState, e, "Idling")
  check(pick({ 0.1 }):find("RushAttack") ~= nil, "Eraqus: one RushAttack: the next pick may be RushAttack")
  pcall(e.GotoState, e, "RushAttack")
  pcall(e.GotoState, e, "Idling")
  local g = pick({ 0.1, 0.1, 0.1 })
  check(g:find("RushAttack") == nil, "Eraqus: RushAttack twice in a row: his pick is not RushAttack (" .. g .. ")")
  pcall(e.GotoState, e, "Oboro")
  pcall(e.GotoState, e, "Idling")
  check(pick({ 0.1 }):find("RushAttack") ~= nil, "Eraqus: another attack in between: RushAttack allowed again")
  -- a restart his own code does out of a flinch is not a new use
  pcall(e.GotoState, e, "RushAttack")
  e.reflect = false
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(rawget(e, "__exLast") == "RushAttack" and rawget(e, "__exRun") == 1, "Eraqus: his restart out of a flinch is not counted (" .. tostring(rawget(e, "__exRun")) .. ")")
  -- the mod's answers: his lists without the barred attack
  local cfg = BBS_REVENGE.cfg.b20ex00
  local seen
  local function choose(l) seen = table.concat(l, ",") return l[1] end
  rawset(e, "__exLast", "RushAttack") rawset(e, "__exRun", 2)
  local p0 = stk.ptr
  local n = cfg.answer(e, false, "Wander", choose)
  check(n == "Oboro" and seen == "Oboro,Kasumi,Itusen" and stk:get() == "Wander", "Eraqus: an answer (far) after RushAttack twice: not RushAttack (" .. tostring(seen) .. ")")
  while stk.ptr > p0 do stk:pop() end
  n = cfg.answer(e, true, nil, choose)
  check(seen == "SuccessionAttack,Kagerou", "Eraqus: an answer (close): not RushAttack (" .. tostring(seen) .. ")")
  rawset(e, "__exLast", "Oboro") rawset(e, "__exRun", 1)
  cfg.answer(e, false, nil, choose)
  check(seen == "RushAttack,Oboro,Kasumi,Itusen", "Eraqus: an answer with nothing barred: his full list (" .. tostring(seen) .. ")")
  -- his guard counter: not a third Kagerou in a row
  rawset(e, "__exLast", "Kagerou") rawset(e, "__exRun", 2)
  pcall(e.GotoState, e, "Idling")
  p0 = stk.ptr
  cfg.counter(e)
  local has = false
  for i = p0, stk.ptr - 1 do if stk._et[i] == "Kagerou" then has = true end end
  check(e:GetState() == "Guard" and not has, "Eraqus: guard after Kagerou twice: no third Kagerou queued")
  while stk.ptr > p0 do stk:pop() end
  M.rand = mr
  M.num["Entity.CalcDistanceXZSq"] = nil
end
io.write(fails == 0 and "ALL OK\n" or ("FAILED " .. fails .. "\n"))
os.exit(fails == 0 and 0 or 1)
