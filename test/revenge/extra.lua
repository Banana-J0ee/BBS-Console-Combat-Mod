package.path = (os.getenv("RV_TEST") or "test/revenge") .. "/?.lua;" .. package.path
local M = require("emu")
math.randomseed(7)
M.common()
BBS_REVENGE.vary = 0           -- deterministic limits for these checks (variance has its own check below)
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
  for i = 1, 6 do r = hit(h) end
  check(r == nil and st.rv == 6 and e:GetState() == "Idling", "Xehanort: 6 hits land, he stays in the combo")
  r = hit(h)
  check(r == "before" and e:GetState() == "Warp" and st.rv == 7 and e.defenseTimer > 0, "7th hit: quick warp (state " .. e:GetState() .. "), hit negated, value kept (KH2)")
  local grace = BBS_REVENGE.grace
  check(st.idle >= grace, "... and it drains from now on, while he acts")
  check(hit(h) == nil and e:GetState() == "Warp", "while he is warping nothing more is triggered")
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
  check(r == "before" and n <= 3, "straight back in: the next break-out after " .. n .. " hits, not 7")
  pcall(e.GotoState, e, "Idling")
  for i = 1, 200 do e:OnUpdate() end
  check(st.rv == 0, "left alone long enough it drains to nothing (" .. st.rv .. ")")
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
  pcall(e.GotoState, e, "Move")
  e:OnUpdate(); e:OnUpdate()
  check(held and st.armor == 0, "... held through his counter, off once he walks again")
  st.rv = 0
  for i = 1, 4 do hit(h) end
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(st.rv == 4 and st.idle >= BBS_REVENGE.grace, "recovering from hit-stun does not clear the value, it starts the drain")
  e:OnUpdate()
  check(st.rv < 4 and st.rv > 3.8, "... at once (" .. st.rv .. ")")
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
  for i = 1, 7 do r = hit(h) end
  check(r == nil and st.rv == 7, "Peter Pan: 7 hits land, no vanilla escape fires")
  r = hit(h)
  check(r == "before" and st.rv == 8 and e:GetState() == "Attack3", "8th hit: his own attack as the revenge (" .. tostring(e:GetState()) .. "), value kept")
  check(st.armor > 0, "the revenge has its armour window")
  for i = 1, 70 do e:OnUpdate() end
  check(st.armor > 0, "... held while his attack runs")
  pcall(e.GotoState, e, "Idling")
  e:OnUpdate()
  check(st.armor == 0, "... and off once he is idle again (punishable)")
  EntityManager:CallFunctionNoArg("OnReturnDamage", h)
  check(e:GetState() == "BeforeAttackIdling", "after a combo he goes back on the offensive (" .. e:GetState() .. ")")
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
  check(lo >= 7 and hi <= 9 and hi > lo, string.format("the limit re-rolls in 8 +- 1 after each revenge (%.2f .. %.2f)", lo, hi))
end
-- boss pace: idle waits shortened, walks capped, attacks / superbosses / allies left alone
do
  local log = {}
  M.num["Entity.SetTimer"] = function(h, v) log[h] = v end
  local RVs = BBS_REVENGE
  check(RVs.aggr == 0.4 and RVs.walkCap == 2 and RVs.idleFloor == 45, "pace defaults: idle x0.4 (floor 0.75 s), walks capped at 2 s")
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  check(log[h] == 48, "Vanitas Idling: 120 -> 48 frames (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "TargetMove")
  check(log[h] == 120, "Vanitas TargetMove: 300 -> 120 frames (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "KeyBladeRush")
  check(log[h] == 180, "Vanitas KeyBladeRush keeps its 180 (" .. tostring(log[h]) .. ")")
  pcall(e.GotoState, e, "Warp1")
  check(log[h] == 30, "Vanitas Warp1 keeps its 30")
  -- a short idle stays as it is
  check(RVs.paceValue("idle", 40) == 40 and RVs.paceValue("idle", 60) == 45 and RVs.paceValue("walk", 90) == 90,
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
  check(log[h2] == 600, "Vanitas Remnant (superboss) keeps his 600 (" .. tostring(log[h2]) .. ")")
  -- Braig: his wait is a field
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  M.num["Script.RandomInRange"] = function(a, b) return 90 end
  pcall(e3.GotoState, e3, "WaitIdling")
  M.num["Script.RandomInRange"] = nil
  check(e3.timer == 45, "Braig WaitIdling: 90 -> 45 frames (" .. tostring(e3.timer) .. ")")
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
  check(s1 == "Idling" and log[h5] == 0, "Hook: time out 10 m away -> no stab, decides again at once (" .. s1 .. ", timer " .. tostring(log[h5]) .. ")")
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
    pcall(e.GotoState, e, "BattleIdling")
    st.rv, st.firing, st.armor = 0, false, 0
    local r
    for i = 1, 10 do r = hit(h) if r ~= nil then break end end
    seen[e:GetState()] = true
    check(r == "before" and st.rv >= 5 and st.rv <= 7, "Terra-Xehanort breaks out at his limit (6 +- 1): value " .. st.rv)
  end
  local atk = seen.Combo
  check(atk and not seen.EvasionAction, "... always with an attack of his own, never only the dodge roll")
  check(st.armor > 0, "the answer has its armour")
  for i = 1, 10 do e:OnUpdate() end
  check(st.armor > 0, "still armoured while attacking")
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
  for k = 1, 80 do
    pcall(e2.GotoState, e2, "BattleIdling")
    st2.rv, st2.firing, st2.armor = 0, false, 0
    for i = 1, 12 do if hit(h2) ~= nil then break end end
    local s2 = e2:GetState()
    if s2 == "EvasionAction" then nd = nd + 1 elseif s2 == "Combo" or s2 == "SpecialCommandAttack0" or s2 == "ShortDistAttackCommand" then na = na + 1 end
  end
  M.num["Entity.IsGround"] = nil
  check(na > nd and nd > 0, "Terra (practice): " .. na .. " attacks, " .. nd .. " dodges out of 80 break-outs")
  -- Braig: warps away and shoots from there
  local e3, h3 = M.create("b30ex00")
  local st3 = BBS_REVENGE.ents.b30ex00
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  local shots = 0
  for k = 1, 20 do
    pcall(e3.GotoState, e3, "Idling")
    st3.rv, st3.firing, st3.armor = 0, false, 0
    for i = 1, 10 do if hit(h3) ~= nil then break end end
    local top = e3.stack ~= nil and e3.stack:pop(1) or nil
    if e3:GetState() == "Escape" and (top == "DashShoot" or top == "RoundShoot") then shots = shots + 1 end
  end
  check(shots >= 10, "Braig: escape then his own shots in " .. shots .. " of 20 break-outs")
  check(st3.limit >= 6 and st3.limit <= 8, "Braig in the Keyblade Graveyard: limit 7 +- 1 (" .. st3.limit .. ")")
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
  check(log[h] ~= 1, "his normal slash stays flinchable")
  M.script("b63ex00")
  local e2, h2 = M.create("b63ex00")
  local st2 = BBS_REVENGE.ents.b63ex00
  rawset(e2, "Update", function() end); rawset(e2, "Debug", function() end)
  pcall(e2.GotoState, e2, "Idling")
  pcall(e2.GotoState, e2, "SuccessionAttack2")
  check(log[h2] == 1, "Ventus-Vanitas: his combo's opening is armoured")
  for i = 1, 30 do pcall(e2.OnUpdate, e2) end
  check(log[h2] == 0, "... and flinchable again after 24 frames")
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
io.write(fails == 0 and "ALL OK\n" or ("FAILED " .. fails .. "\n"))
os.exit(fails == 0 and 0 or 1)
