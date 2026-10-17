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
  for i = 1, 6 do r = hit(h) end
  check(r == nil and st.rv == 6 and e:GetState() == "Idling", "Xehanort: 6 hits land, he stays in the combo")
  r = hit(h)
  check(r == "before" and e:GetState() == "Warp" and st.rv == 7 and e.defenseTimer > 0, "7th hit: quick warp (state " .. e:GetState() .. "), hit negated, value kept (KH2)")
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
  local s8 = e:GetState()
  check(r == "before" and st.rv == 8 and (s8 == "Attack1" or s8 == "Attack2" or s8 == "Attack3"), "8th hit: one of his own attacks as the revenge (" .. tostring(s8) .. "), value kept")
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
  check(math.abs(RVs.aggr - 0.4) < 1e-6 and RVs.walkCap == 2 and RVs.idleFloor == 45, "pace defaults: idle x0.4 (floor 0.75 s), walks capped at 2 s")
  M.script("b10ex00")
  local e, h = M.create("b10ex00")
  rawset(e, "Update", function() end); rawset(e, "Debug", function() end)
  pcall(e.GotoState, e, "Idling")
  check(math.abs(log[h] - 48) < 0.01, "Vanitas Idling: 120 -> 48 frames (" .. tostring(log[h]) .. ")")
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
  check(log[h2] == 600, "Vanitas Remnant (superboss) keeps his 600 (" .. tostring(log[h2]) .. ")")
  -- Braig: his wait is a field
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  M.num["Script.RandomInRange"] = function(a, b) return 90 end
  pcall(e3.GotoState, e3, "WaitIdling")
  M.num["Script.RandomInRange"] = nil
  check(math.abs(e3.timer - 45) < 0.01, "Braig WaitIdling: 90 -> 45 frames (" .. tostring(e3.timer) .. ")")
  pcall(e3.GotoState, e3, "Idling")
  M.num["Script.RandomInRange"] = function(a, b) return 30 end
  pcall(e3.GotoState, e3, "WaitIdling")
  M.num["Script.RandomInRange"] = nil
  check(e3.timer == 30, "... 30 stays 30 (under the floor) (" .. tostring(e3.timer) .. ")")
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
    if e3:GetState() == "Escape" and e3.stack ~= nil then
      pcall(e3.GotoState, e3, e3.stack:pop(1))     -- the escape warp ends
      local s3 = e3:GetState()
      if s3 == "WarpShoot" or s3 == "DashShoot" or s3 == "ChargeShoot" or s3 == "RoundShoot" then shots = shots + 1 end
    end
  end
  check(shots == 20, "Braig: escape, then one of his shots, in " .. shots .. " of 20 break-outs")
  check(st3.limit >= 6 and st3.limit <= 8, "Braig in the Keyblade Graveyard: limit 7 +- 1 (" .. st3.limit .. ")")
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
  -- Braig: the first second of a shot is armoured and hits do not reach his script (it would end the shot);
  -- after that hits stagger him and end it, as in vanilla (his shots are long shooting phases)
  M.script("b30ex00")
  local e3, h3 = M.create("b30ex00")
  rawset(e3, "Update", function() end); rawset(e3, "Debug", function() end)
  local st3 = BBS_REVENGE.ents.b30ex00
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "DashShoot")
  st3.rv, st3.firing, st3.armor = 0, false, 0
  for i = 1, 3 do hit(h3) end
  check(e3:GetState() == "DashShoot" and log[h3] == 1, "Braig: hits early in his Dash Shoot do not cut it short (" .. tostring(e3:GetState()) .. ")")
  for i = 1, 80 do pcall(e3.OnUpdate, e3) end
  check(log[h3] == 1, "... still armoured at 1.33 s (Dash Shoot: 1.5 s)")
  for i = 1, 15 do pcall(e3.OnUpdate, e3) end
  local s3 = e3:GetState()
  check(log[h3] == 0, "... after 1.5 s his armour is off (" .. tostring(s3) .. ")")
  if s3 == "DashShoot" then
    hit(h3)
    check(e3:GetState() ~= "DashShoot", "... and a hit ends the shot (" .. tostring(e3:GetState()) .. ")")
  end
  pcall(e3.GotoState, e3, "Idling")
  pcall(e3.GotoState, e3, "InvertedShoot")
  check(st3.mArmor == 0, "... Inverted Shoot keeps the game's own armour only")
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
io.write(fails == 0 and "ALL OK\n" or ("FAILED " .. fails .. "\n"))
os.exit(fails == 0 and 0 or 1)
