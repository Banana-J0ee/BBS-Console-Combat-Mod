-- ---------------------------------------------------------------------
-- Boss table.  key = entity name used by the game.
--   limit    revenge value at which the boss breaks out
--   quiet    dice value fed to the boss script below the limit  (default 0.999;
--            "real" = leave the dice alone)
--   fire     dice value fed to the boss script at the limit     (default 0;
--            "real" = leave the dice alone, pre() forces the break-out)
--   fireSeq  first dice values at the limit ("coin" = low or high at random)
--            quiet / fire / fireSeq may also be function(self)
--   pre      function(self, firing) run before the boss's own callback
--   post     function(self, fired) run after it when the limit was reached
--   vanilla  function(self, kind, cat) -> true: this hit keeps vanilla dice
--   active   function(self) -> false to leave this instance alone
--   counter  function(self, kind, cat) -> 1 when it made the boss break out: used at the
--            limit when the boss script itself has no break-out on a hit
--   armored  true: the boss never flinches, so its OnDamage result is not a break-out
--   fired    function(self) -> true once a break-out that starts from the boss's own
--            update (not from a hit) is under way
--   grace    frames (60/s) after the last hit before the gauge starts to drain (default RV.grace)
--   drain    gauge drained per frame once draining (default RV.drain; KH2's pace)
--   vary     the limit is re-rolled +- this after each revenge (default RV.vary)
--   iframes  armour frames (60/s) after a forced break-out, so it cannot be stuffed (default none)
--   recover  function(self) run after the boss recovers from hit-stun: KH2 bosses come
--            back at you, several BBS scripts just stand up into idling
--   clear    true: the gauge is cleared after a break-out and when the boss recovers (default:
--            KH2's rule - it is kept and drains while the boss acts)
--   pace     false: the boss keeps its own pace (superbosses, Hades).  Otherwise [Bosses] in the ini
--            shortens its idle waits and caps its walks (revenge.lua, "Boss pace")
--   paceFields { State = "field" }: an idle the script counts down in a field of its own
--            (frames) instead of Entity.SetTimer, shortened when the state starts
--   idleFloor  shortest paced idle wait in frames for this boss (default RV.idleFloor 15)
--   opening  false: no opening attack (default: a boss with an answer opens with one; openAt: states where)
--   armorHit function(self) -> true: during an armoured move, hits are kept from the script's OnDamageBefore
--   answer   the revenge answer (revenge.lua, RV.oweMax): after the get-away the boss goes into an attack
--            picked from { close = {...}, far = {...} } (by distance, never the last one again), or chosen
--            by function(self, near, ret, choose).  answerAt / answerNear / answerClear: see revenge.lua
--   setup    function(ent) run once when the boss is created (changes to its own states)
--   armorStates { State = true | frames }: moves of KH2's "cannot be interrupted" class (specials,
--            warps) the script leaves flinchable: armoured for the whole move, or its first frames
--   haste    < 1 shortens the idle times the script reads through entity methods
--            (hasteFns, default GetIdlingChangeTime); timers baked in as constants stay
-- Large bosses are deliberately absent: they keep their vanilla behaviour.
-- ---------------------------------------------------------------------
local cfg = RV.cfg

-- Many scripts roll "Random() < dmgCount * k".  Keep their own hit counter
-- at zero below the limit and saturate it when the limit is reached.
local function dmgCountPre(self, firing)
  if type(self.dmgCount) == "number" then
    if firing then self.dmgCount = 99 else self.dmgCount = 0 end
  end
end

-- The revenge answer (KH2: a break-out is always an attack).  answers(self): this boss's config has one,
-- so its counter only does the get-away and the attack is picked when that ends; answerNow: at once.
local function answers(self)
  local st = rawget(self, "__rv")
  return st ~= nil and st.cfg ~= nil and st.cfg.answer ~= nil and st.answer ~= nil
end
local function answerNow(self, ret)
  local st = rawget(self, "__rv")
  return st ~= nil and st.answer ~= nil and st.answer(self, ret) == true
end

-- Break-outs for the bosses whose own escapes live in dice or in OnDamage:
-- each is the boss's own move set, usable per hit and from the watchdog.
local function vanitasCounter(self)
  if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
  local s = self:GetState()
  if s == "Dead" or s == "Appear" or s == "Cartwheel" then return 0 end
  self.stack:push("Idling")
  self:GotoState("Cartwheel")
  if type(self.dmgCount) == "number" then self.dmgCount = 0 end
  return 1
end
local function wielderCounter(self)
  if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
  if type(self.GetGrandEvasionRate) ~= "function" then return 0 end     -- not the shared wielder script
  local s = self:GetState()
  if s == "EvasionAction" or s == "Dead" or s == "Appear" then return 0 end
  self.stack:push("BattleIdling")
  -- answer with an attack of their own (their combo, as their action select picks up close);
  -- otherwise the dodge roll.  attack: share of attacks (per boss, default 0.6)
  local st = rawget(self, "__rv")
  local share = (st and st.cfg and st.cfg.attack) or 0.6
  if answers(self) then
    -- an attack picked at once, or the dodge roll and the attack after it (owed)
    if Script.Random() < share and answerNow(self, "BattleIdling") then
      if type(self.DamageCnt) == "number" then self.DamageCnt = 0 end
      return 1
    end
    self.stack:push("EvasionAction")
  elseif Script.Random() < share then
    self.targetHandle = Enemy.SearchAttackEntity(self.myHandle, SEARCH_TYPE_NEAR)
    self.stack:push("Combo")     -- every wielder's action select has its combo (not every one a special 0)
  else
    self.stack:push("EvasionAction")
  end
  self:GotoState(self.stack:pop(1))
  if type(self.DamageCnt) == "number" then self.DamageCnt = 0 end
  return 1
end
-- wielders: close their combo or short-range command, far the distance commands that copy has
local function wielderAnswer(self, near, ret, choose)
  if type(self.GetGrandEvasionRate) ~= "function" then return nil end     -- not the shared wielder script
  local function has(cmd)
    if cmd == nil then return false end
    local ok, r = pcall(self.GetRate, self, cmd)
    return ok and type(r) == "number" and r > 0
  end
  local list = {}
  if near then
    list[1] = "Combo"
    if has(PLBBASE_COMMAND_ATTACKCOM1) then list[#list + 1] = "ShortDistAttackCommand" end
  else
    if has(PLBBASE_COMMAND_ATTACKCOM2) then list[#list + 1] = "DistanceAttackCommand2" end
    if has(PLBBASE_COMMAND_ATTACKCOM3) then list[#list + 1] = "DistanceAttackCommand3" end
    if #list == 0 then list[1] = "Combo" end
  end
  local n = choose(list)
  if n ~= nil and self.stack ~= nil and ret ~= nil then self.stack:push(ret) end
  return n
end
-- Masked Vanitas: his own close / far attacks for the mode he is in (the late fight's normal mode is
-- the keyblade ride - no answer there; neither while he waits for Xehanort's go-ahead)
local function maskedAnswer(self, near, ret, choose)
  if self.rideMode == true then return nil end
  -- with Xehanort in the fight they take turns (his go-ahead: attackPermission, as SearchTarget asks)
  if self.attackPermission == false and Enemy.SearchEnemy(self.myHandle, "b40ex00", SEARCH_TYPE_NEAR) ~= NULL_HANDLE then
    return nil
  end
  local dark = self.darkMode == true
  if self.type == 3 and not dark then return nil end
  local list
  if near then
    list = { dark and "SuccessionAttack2" or "SuccessionAttack1", "DarkFiraga", "DarkThundaga" }
  else
    list = { dark and "Warp2" or "Warp1", "DarkFiraga", "DarkThundaga" }
    if dark then list[#list + 1] = "ShadowDiving" end
  end
  local n = choose(list)
  if n ~= nil and self.stack ~= nil then self.stack:push(dark and "CheckDarkModeAttackCount" or ret or "Idling") end
  return n
end

-- Vanitas (story fights)
-- vanilla: 15% cartwheel on every hit + growing chance of a warp counter.
-- Revenge limits ramp with the story (as KH2's Data fights: Data Roxas breaks out at 75 of story Roxas's 100):
-- opening bosses as they were, early-mid / mid x0.9, late worlds x0.8, story finales and Final Episode x0.75.
-- Masked Vanitas's keyblade ride: his script switches flinching off when he summons the keyblades and
-- keeps it off for the whole ride (jump-on, riding, keyblade rush, Dark Blizzaga), attached to the
-- keyblade.  So the ride is left as it is - no armour of ours, which used to switch flinching back on
-- and let hits push him off his keyblade while he kept "riding".  Hits still knock him off: after his
-- revenge limit's worth of hits taken during the ride, he gets off the way his own script does when
-- the ride ends (EndRideMode, back-handspring, style change), as soon as he is riding (not mid-attack).
local RIDING = { RideMode = true, KeyBladeRush = true, KeyBladeDarkBlizzaga = true, RideKeyBlade = true }
local function rideHit(self, kind, cat)
  if kind ~= ATK_KIND_RECOVER and type(self.GetState) == "function" and RIDING[self:GetState()] then
    local st = rawget(self, "__rv")
    local t = st and st.t or 0
    if self.__rideHitT ~= t then                      -- asked from both damage callbacks: once a frame
      self.__rideHitT = t
      self.__rideHits = (self.__rideHits or 0) + 1
    end
  end
  return false                  -- the hit itself goes the usual way
end
local function rideSetup(ent)
  local states = ent.states
  if type(states) ~= "table" or type(states.RideMode) ~= "table" or type(states.RideWaiting) ~= "table" then return end
  local own = {}
  for k, v in pairs(states) do own[k] = v end
  local rm, rmUpdate = {}, states.RideMode.OnUpdate
  for k, v in pairs(states.RideMode) do rm[k] = v end
  local rw, rwBegin = {}, states.RideWaiting.OnBeginState
  for k, v in pairs(states.RideWaiting) do rw[k] = v end
  if type(rmUpdate) ~= "function" or type(rwBegin) ~= "function" then return end
  rw.OnBeginState = function(self, a, b)
    self.__rideHits = 0
    return rwBegin(self, a, b)
  end
  rm.OnUpdate = function(self, a, b)
    local st = rawget(self, "__rv")
    local need = (st and st.limit) or 9
    if (self.__rideHits or 0) >= need and type(self.EndRideMode) == "function" and self.stack ~= nil then
      self.__rideHits = 0
      self:EndRideMode()
      self.stack:push("StyleChange")
      self:GotoState("BackhandsSpringJump")
      return
    end
    return rmUpdate(self, a, b)
  end
  own.RideMode = rm
  own.RideWaiting = rw
  rawset(ent, "states", own)
end
-- KH2 armour (2026-10-17): every attack of his is armoured; the ride moves already are (RideWaiting)
local vanitasArmor = { SuccessionAttack1 = true, SuccessionAttack2 = true, DarkFiraga = true, DarkThundaga = true }
local vanitas = { limit = 9, fire = 0.5, armorStates = vanitasArmor, answer = maskedAnswer, pre = dmgCountPre, counter = vanitasCounter, vanilla = rideHit, setup = rideSetup }
cfg.b10ex00 = vanitas
cfg.b10ex01 = vanitas
cfg.b10ex02 = { limit = 8, fire = 0.5, armorStates = vanitasArmor, answer = maskedAnswer, pre = dmgCountPre, counter = vanitasCounter, vanilla = rideHit, setup = rideSetup }   -- the late one
-- Aqua's final fight: at range the script can only cartwheel, so let it.
cfg.b63ex00 = {
  limit = 7.5,
  -- his specials are armoured in BBS already; his combo's opening is too here (it comes out,
  -- its end can be punished)
  armorStates = { SuccessionAttack2 = true, WarpAttack2 = true, DarkThundaga = true },
  answer = { close = { "SuccessionAttack2", "DarkThundaga" }, far = { "Warp2", "ShadowDiving", "DarkThundaga" } },
  pre = dmgCountPre,
  counter = vanitasCounter,
  fire = function(self)
    local d = Entity.CalcDistanceSq(self.myHandle, self.targetHandle)
    if type(d) == "number" and d > 25 then return 0 end
    return 0.5
  end,
}

-- Vanitas (Ventus's final fight): growing chance of Dark Splicer per hit.
cfg.b11ex00 = { limit = 7.5, pre = dmgCountPre, counter = vanitasCounter,
  -- the answer: his own attack pick for the phase (ground / air), without its wait
  answer = function(self, near, ret, choose)
    if self.stack == nil then return nil end
    local f = self.airBattle and self.SelectAttackAirBattle or self.SelectAttackGroundBattle
    if type(f) ~= "function" then return nil end
    self.stack:push(ret or (self.airBattle and "Hovering" or "Idling"))
    f(self)
    return self.stack:pop(1)
  end,
  armorStates = { XDisCharge = true, DarkBreaker = true, DarkCannon = true, DarkAxisAirBattle = true,
                  SuccessionAttack = true, DarkThundaga = true,
                  -- the script drops its own armour part way through these: held to the end
                  DarkSplicer1GroundBattle = true, DarkSplicer2GroundBattle = true,
                  DarkSplicer1AirBattle = true, DarkSplicer2AirBattle = true },
  -- the last phase: while Ventus's Vanitas D-Link (DLink17) runs, his script takes every hit without an escape
  -- so he stays in place for the finisher (OnDamageBefore).  The mod leaves him alone then as well: no
  -- gauge, no forced break-out, no armour of ours - a forced cartwheel moved him away from the finisher.
  active = function(self)
    if not (self.airBattle and type(Player) == "table" and type(Player.GetCommandKind) == "function"
            and COMMAND_KIND_DLink17 ~= nil and Player.GetCommandKind(Player.GetHandle()) == COMMAND_KIND_DLink17) then
      return true
    end
    local st = rawget(self, "__rv")
    if st ~= nil then
      local held = (st.armor or 0) > 0 or (st.mArmor or 0) > 0
      st.firing, st.fireT, st.armor, st.mArmor = false, 0, 0, 0
      if held and type(Enemy.EnableNoDamageReaction) == "function" then Enemy.EnableNoDamageReaction(self.myHandle, 0) end
    end
    return false
  end }

-- Vanitas Remnant: growing chance of Dark Splicer / warp attack per hit.
-- (his answer to shotlocks is unconditional and keeps its own dice)
cfg.b12ex00 = {
  limit = 8,
  iframes = 0,                  -- Final Mix superboss: as he was
  pace = false,                 -- Final Mix superboss: already hard enough
  fireSeq = { 0, "coin" },
  pre = dmgCountPre,
  vanilla = function(self, kind, cat) return cat == COMMAND_CATEGORY_SHOOTLOCK end,
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "DarkSplicer2" or s == "WarpAttack2" then return 0 end
    self.stack:push("Idling")
    if Script.Random() > 0.66 then
      self.stack:push("DarkSplicer2")
    else
      self.stack:push("WarpAttack2")
    end
    if type(self.dmgCount) == "number" then self.dmgCount = 0 end
    self:GotoState(self.stack:pop(1))
    return 1
  end,
}

-- Master Eraqus: guard (+ counter) chance on every hit.
cfg.b20ex00 = {
  limit = 9,
  armorStates = { RushAttack = true, SuccessionAttack = true },
  answer = { close = { "SuccessionAttack", "RushAttack", "Kagerou" }, far = { "RushAttack", "Oboro", "Kasumi", "Itusen" } },
  pre = dmgCountPre,
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Guard" or s == "Kagerou" then return 0 end
    self.stack:push("Wander")
    self.stack:push("Idling")
    if not answers(self) then
      self.stack:push("Kagerou")  -- the guard is always followed by his counter
    end                           -- (with an answer: the guard, then the attack it picks)
    self:GotoState("Guard")
    if type(self.dmgCount) == "number" then self.dmgCount = 0 end
    return 1
  end,
}

-- Armor of the Master: 30% counter per hit in his own style, and only a
-- 30% chance to flinch at all while he copies Ventus / Terra / Aqua.
local armor = {
  limit = 9,
  iframes = 0,                  -- Final Mix superboss: as he was
  pace = false,                 -- Final Mix superboss
  quiet = function(self) if self.style == 2 then return 0.999 end return 0 end,
  fire  = function(self) if self.style == 2 then return 0 end return 0.5 end,
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Guard" then return 0 end
    if s ~= nil then self.stack:push(s) end
    self:GotoState("Guard")
    return 1
  end,
}
cfg.b81vs00 = armor

-- Braig: 30% escape on every hit.
local braig = {
  limit = 9,                    -- b30ex00 (Keyblade Graveyard) gets his own copy below
  armorStates = { WarpShoot = true, WarpCenter = true, RoundShoot = true, DashShoot = true,
                  ChargeShoot = true, InvertedShoot = true },   -- these two: the script drops it part way
  answer = { close = { "RoundShoot", "DashShoot" }, far = { "WarpShoot", "DashShoot", "ChargeShoot" }, noRet = true },
  -- his OnDamageBefore sends every shot to Idling on any hit (30 % escape otherwise), armour or not, so an
  -- armoured shot was still cut short.  Kept from the script during his armoured shots; his designed breaks
  -- stay: Sniper / Charge Shot charging end after enough damage (AttackReleaseHP), Inverted Shot's dodge
  answerClear = { Sniper = true, ArutemaShoot = true },   -- (his entrance may go straight into the Sniper)
  armorHit = function(self)
    local s = self:GetState()
    if s == "DashShoot" or s == "WarpShoot" or s == "RoundShoot" or s == "WarpCenter" then return true end
    return s == "ChargeShoot" and type(self.step) == "number" and self.step >= 4
  end,
  -- his escape warp lands 8-11 m out on each axis (vanilla 2-6): out of reach, the arena edge caps it
  setup = function(ent)
    local wt = ent.WarpToTarget
    if type(wt) ~= "function" then return end
    rawset(ent, "WarpToTarget", function(self, a, b)
      if type(self.GetState) == "function" and self:GetState() == "Escape" and type(a) == "number" and type(b) == "number" then
        if a < 8 then a = 8 end
        if b < 11 then b = 11 end
      end
      return wt(self, a, b)
    end)
  end,
  fire = 0.999,                 -- his own plain escape does not come out at the limit: the counter answers
  paceFields = { WaitIdling = "timer" },   -- his wait between shots is a frame counter
  -- his wait (.epd IdlLowTime..IdlHiTime: 30..90 frames, 30..60 in the first fight) x the boss pace: 15..36 frames
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Escape" or s == "InvertedShoot" or s == "Sniper"
       or s == "ChargeShoot" or s == "ArutemaShoot" then return 0 end
    self.stack:clear()
    self.stack:push("Idling")
    -- he warps away and answers from there (his own dash / circling shots) - 1 in 4 he only escapes
    if not answers(self) then     -- (with an answer: the attack is picked when the warp ends)
      local r = Script.Random()
      if r < 0.4 then self.stack:push("DashShoot") elseif r < 0.75 then self.stack:push("RoundShoot") end
    end
    self.targetHandle = Enemy.SearchAttackEntity(self.myHandle, SEARCH_TYPE_NEAR)
    self:GotoState("Escape")
    return 1
  end,
}
cfg.b32ex00 = braig
local braigLate = {}
for k, v in pairs(braig) do braigLate[k] = v end
braigLate.limit = 7
cfg.b30ex00 = braigLate

-- Mysterious Figure: guard / warp counter / time-slip rolls on every hit.
cfg.b01ex00 = {
  limit = 9,
  iframes = 0,                  -- Final Mix superboss: as he was
  pace = false,                 -- Final Mix superboss
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "DeadCopy" or s == "Appear" or s == "WarpMove_Counter" or s == "Guard" then return 0 end
    self.stack:push("BattleIdling")
    self.stack:push("WarpMove_Counter")
    if type(self.DamageCnt) == "number" then self.DamageCnt = 0 end
    self:GotoState(self.stack:pop(1))
    return 1
  end,
  -- one roll picks the move: < GuardRate guard, < GuardRate + WarpRate warp counter
  fire = function(self) if RV.coin() == 0 then return 0 end return 0.45 end,
  pre = function(self, firing)
    if firing and type(self.DamageCnt) == "number" then
      self.__rvCnt = self.DamageCnt
      self.DamageCnt = 99
    end
  end,
  post = function(self, fired)
    if type(self.__rvCnt) == "number" then
      if not fired and self.DamageCnt == 99 then self.DamageCnt = self.__rvCnt end
      self.__rvCnt = nil
    end
  end,
}

-- Captain Hook: guard / evade roll on every hit (his own recovery already
-- counter-attacks, so no recover is needed).  The counter is his own escape -
-- guard or evade, then his jump-cut counter - for hits his rolls do not cover.
-- He picks his attack first and walks to its range after (TargetMove), and the attack
-- comes out when the walk ends - in range or not.  With the walk capped (boss pace) he
-- would swing from afar, so a walk that runs out of time short of the range drops the
-- planned attack and decides again at once (his Idling: close -> melee, mid -> step in,
-- far -> big bomb), as Zack and the keyblade wielders do.
local function hookSetup(ent)
  local states = ent.states
  if type(states) ~= "table" or type(states.TargetMove) ~= "table" then return end
  local own = {}
  for k, v in pairs(states) do own[k] = v end
  local tm, tmUpdate = {}, states.TargetMove.OnUpdate
  for k, v in pairs(states.TargetMove) do tm[k] = v end
  if type(tmUpdate) ~= "function" then return end
  tm.OnUpdate = function(self)
    if Entity.IsTimeOver(self.myHandle) and type(self.nearDist) == "number" and self.stack ~= nil
       and Entity.CalcDistanceXZSq(self.myHandle, self.targetHandle) > self.nearDist then
      self.stack:clear()
      self.idlingTimer = 0
      self:GotoState("Idling")
      return
    end
    return tmUpdate(self)
  end
  own.TargetMove = tm
  rawset(ent, "states", own)
end
cfg.b01pp00 = {
  limit = 8,
  armorStates = { RushXCutting = true, PresentBombLarge = true, RushStab = true, DisturbStab = true,
                  PresentBombSmall = true },
  iframes = 40,
  setup = hookSetup,
  answer = { close = { "JumpCutting", "RushStab", "DisturbStab" }, far = { "RushXCutting", "PresentBombSmall" } },
  answerNear = 12.25,           -- his own close range (3.5 m)
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Guard" or s == "Evade" or s == "JumpCutting"
       or s == "SinkSea" or s == "FlyUp" or s == "Blow" or s == "FireDamage" then return 0 end
    if self.stack == nil then return 0 end
    self.stack:push("Idling")
    if not answers(self) then self.stack:push("JumpCutting") end   -- with an answer: picked after the guard / evade
    if Script.Random() < 0.5 then
      self.stack:push("Guard")
    else
      self.stack:push("Evade")
    end
    self:GotoState(self.stack:pop(1))
    pcall(function() Entity.SetMovementCollKind(self.myHandle, COLL_KIND_ENEMY) end)
    return 1
  end,
}

-- Peter Pan.  vanilla: no break-out of any kind - he can be comboed forever - and
-- he recovers from hit-stun into idling.  At the limit he answers with one of his
-- own attacks; after any combo he goes straight back on the offensive.
cfg.b20pp00 = {
  limit = 8,
  armorStates = { Attack1 = true, Attack2 = true, Attack3 = true, Attack4 = true },
  iframes = 48,
  -- his three attacks are all picked at the same range in his script (BeforeAttackIdling); Attack4 is
  -- never used by it, so it stays out
  answer = { close = { "Attack1", "Attack2", "Attack3" }, far = { "Attack1", "Attack2", "Attack3" }, noRet = true },
  openAt = { BattleStartState = true },   -- his opening hover (up to 500 frames) is where his fight starts
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "BattleStartState" then return 0 end
    self.targetHandle = Enemy.SearchAttackEntity(self.myHandle, SEARCH_TYPE_NEAR)
    if self.stack ~= nil then
      pcall(function() self.stack:clear() self.stack:push("Idling") end)
    end
    pcall(self.ReSetRot, self)
    if answers(self) and answerNow(self) then return 1 end
    self:GotoState("Attack3")
    return 1
  end,
  recover = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" then return end
    self.targetHandle = Enemy.SearchAttackEntity(self.myHandle, SEARCH_TYPE_NEAR)
    self:GotoState("BeforeAttackIdling")
  end,
}

-- Experiment 221: growing chance to flee per hit.
cfg.b20ls00 = {
  limit = 7,
  armorStates = { Electroshock = true, Lightning = true, ElectricBall = true, BlasterMode = true },
  -- his answer once he has fled: close his shock (he lands for it, as his script does), far his air shots
  answerAt = { AirMove = true, AirIdling = true, Idling = true, Wander = true },
  answer = function(self, near, ret, choose)
    if self.stack == nil then return nil end
    local n = choose(near and { "Electroshock", "Lightning" } or { "Lightning", "ElectricBall" })
    if n == nil then return nil end
    self.stack:push(ret or "AirMove")
    if n == "Electroshock" then
      self.stack:push("Electroshock")
      return "Landing"
    end
    self.stack:push("AirIdling")
    if n == "ElectricBall" then
      if Script.Random() < 0.5 then self.stack:push("ElectricBall") end
      return "ElectricBall"
    end
    return "Lightning"
  end,
  fireSeq = { 0, "coin" },
  pre = dmgCountPre,
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" or self.stack == nil then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Flee" or s == "StartAirMove" or s == "Electroshock" or s == "AirMove" then return 0 end
    self.stack:clear()
    self.stack:push("AirMove")
    self.stack:push("Flee")
    self.stack:push("StartAirMove")
    if not answers(self) and Script.Random() < 0.75 then -- usually he answers with his shock first
      self.stack:push("Electroshock")
      Enemy.EnableNoDamageReaction(self.myHandle, 1)      -- as his own escape does
    end
    if type(self.dmgCount) == "number" then self.dmgCount = 0 end
    self:GotoState(self.stack:pop(1))
    return 1
  end,
}

-- Maleficent: vanilla teleports / staff-attacks after only 3 hits - but only
-- from OnDamage, which the engine asks on the first hit of a combo alone, so
-- an unbroken combo could loop her.  The counter below is her own pair of
-- moves, fired per hit / from the watchdog.
cfg.b01sb00 = {
  limit = 9,
  armorStates = { Teleport = true, StaffAttack = true, Meteor = true },
  fire = "real",
  iframes = 40,
  -- her answer: the staff or the spell of the phase she is in (IdlingA: Thundaga, IdlingB / C: Thunder)
  answer = function(self, near, ret, choose)
    local n = choose({ "StaffAttack", ret == "IdlingA" and "Thundaga" or "Thunder" })
    if n ~= nil and self.stack ~= nil and ret ~= nil then self.stack:push(ret) end
    return n
  end,
  answerClear = { Thunder = true, Thundaga = true, Meteor = true, CharmFlash = true, SoldierSummons = true,
                  Sleep = true, StaffAttack = true },
  counter = function(self)
    if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return 0 end
    local s = self:GetState()
    if s == "Dead" or s == "Appear" or s == "Teleport" or s == "StaffAttack" or s == "BeginBarrier"
       or s == "BuildingBarrier" or s == "CheckBarrierComplete" then return 0 end
    if self.stack ~= nil and type(self.stack.getn) == "function" and self.stack:getn() <= 0 then
      if s ~= nil then self.stack:push(s) else self.stack:push("IdlingA") end
    end
    if type(self.ChangeWarpState) == "function" and (answers(self) or Script.Random() < 0.5) then
      self:ChangeWarpState()      -- with an answer: always the teleport, then the attack it picks
    else
      self:GotoState("StaffAttack")
    end
    if type(self.dmgCount) == "number" then self.dmgCount = 0 end
    pcall(function() Enemy.SetFaceAnim(self.myHandle, 3, 2) end)
    return 1
  end,
  pre = function(self, firing)
    if type(self.dmgCount) == "number" then
      if firing then self.dmgCount = 99 else self.dmgCount = 0 end
    end
  end,
}

-- Keyblade wielders (shared AI): Ventus / Terra / Aqua bosses and
-- Terra-Xehanort.  vanilla: dodge-roll roll on every hit; Terra-Xehanort
-- warps into a special attack after ~5 hits.  Allies are left alone.
local function wielderActive(self) return self.friendFlag ~= 1 end
local function wielderPre(self, firing)
  if type(self.DamageCnt) ~= "number" then return end
  if firing then
    self.__rvCnt = self.DamageCnt
    self.DamageCnt = 99
    if type(self.saveDamage) == "number" then self.saveDamage = 2 end
  elseif type(self.saveDamage) == "number" then
    self.saveDamage = 0
  end
end
local function wielderPost(self, fired)
  if type(self.__rvCnt) == "number" then
    if not fired and self.DamageCnt == 99 then self.DamageCnt = self.__rvCnt end
    self.__rvCnt = nil
  end
end
-- (a wielder whose script has no dodge chance, e.g. in mid-air, still has none)
-- fire 0.999: their own dodge roll does not come out by itself at the limit, the counter picks (mostly an attack)
local wielder = { limit = 9, fire = 0.999, active = wielderActive, pre = wielderPre, post = wielderPost, counter = wielderCounter,
                  answer = wielderAnswer }
local wielders = { "b60ex00", "b62ex00", "b68ex00", "b69ex00", "b70ex00", "b72ex00", "b73ex00",
                   "b78ex00", "b79ex00", "b80ex00", "b82ex00", "b83ex00", "b88ex00", "b89ex00" }
for i = 1, #wielders do
  cfg[wielders[i]] = wielder
end
local xehanort = { limit = 6, attack = 1, fire = 0.999, active = wielderActive, pre = wielderPre, post = wielderPost, fireSeq = { 0.999, "coin" }, counter = wielderCounter,
                   answer = wielderAnswer }
cfg.b50ex00 = xehanort
cfg.b51ex00 = xehanort

-- Terra-Xehanort (final episode; own AI when it has SetDmgCount, shared
-- wielder AI otherwise).  vanilla: counter-attacks after 2-5 hits.
local function ownAI(self) return self.SetDmgCount ~= nil end
cfg.b52ex00 = {
  limit = 6,
  attack = 1,
  active = wielderActive,
  counter = wielderCounter,     -- the shared-AI form only; his own AI has no EvasionAction and is covered by pre()
  answer = wielderAnswer,       -- (nil for his own AI)
  fire = function(self) if ownAI(self) then return "real" end return 0 end,
  fireSeq = function(self) if ownAI(self) then return nil end return xehanort.fireSeq end,
  pre = function(self, firing)
    if ownAI(self) then
      if type(self.nDmgCount) == "number" then
        if firing then
          self.nDmgCount = 0
          self.nDmgHamariCount = 1
        else
          self.nDmgCount = 100
        end
      end
    else
      wielderPre(self, firing)
    end
  end,
  post = function(self, fired)
    if not ownAI(self) then wielderPost(self, fired) end
  end,
}

-- Zack (all three versions share one script).  vanilla: one hit counter for the
-- whole fight, counter move at 8-10 hits - but it lives in OnDamage, which the
-- engine only asks on the first hit of a combo, so an unbroken combo could loop
-- him forever.  The counter below is his own move set, fired per hit / from the
-- watchdog with roughly his own odds.
local function zackCounter(self)
  if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return 0 end
  local s = self:GetState()
  if s == "Bushinhazan" or s == "Climbhazard" or s == "BackJump_Short" or s == "Hakougeki"
     or s == "BackJump_Short_Cancel" or s == "Dead" or s == "Appear" then return 0 end
  if self.stack == nil then return 0 end
  self.stack:clear()
  self.stack:push("Move")
  local r = Script.Random()
  if answers(self) then         -- the back-jump, then the attack picked when it ends
    self.stack:push("BackJump_Short")
  elseif r < 0.4 then
    self.stack:push("Climbhazard")
    self.stack:push("BackJump_Short")
  elseif r < 0.7 then
    self.stack:push("Hakougeki")
    self.stack:push("BackJump_Short_Cancel")
  else
    self.stack:push("BackJump_Short")
  end
  self:GotoState(self.stack:pop(1))
  if type(self.damageCnt) == "number" then self.damageCnt = 0 end
  return 1
end
local zack = {
  limit = 9,
  fire = "real",
  iframes = 40,
  counter = zackCounter,
  pre = function(self, firing)
    if type(self.damageCnt) == "number" then
      if firing then self.damageCnt = 99 else self.damageCnt = 0 end
    end
  end,
}
cfg.b60vs00 = zack                                   -- Mirage Arena: as it was
local zackStory = {}
for k, v in pairs(zack) do zackStory[k] = v end
zackStory.limit = 8
zackStory.armorStates = { ComboAttack = true, Hakougeki = true }   -- story copies only (Arena: as it was)
zackStory.answer = { close = { "ComboAttack", "Hakougeki", "Climbhazard" }, far = { "Climbhazard", "Hakougeki" } }
cfg.b30he00 = zackStory
cfg.b40he00 = zackStory

-- Hades (story and Mirage Arena).  vanilla: counters at the 7th hit in a row on the
-- same spot.  (While he burns red he ignores hits; that stays.)
local function hadesCounter(self)
  if type(self.GotoState) ~= "function" or type(self.GetState) ~= "function" then return 0 end
  local s = self:GetState()
  if s == "Watching" or s == "Dead" or s == "Freeze" or s == "Appear" or s == "BladesCrossing"
     or s == "MegaFire" or s == "FingernailofFire" or s == "NoRiaFingernailofFire" then return 0 end
  if answers(self) then         -- no get-away: one of his attacks at once
    if answerNow(self) then
      if type(self.sameDamageCont) == "number" then self.sameDamageCont = 0 end
      return 1
    end
  end
  if Script.Random() < 0.5 then
    self:GotoState("BladesCrossing")
  else
    self:GotoState("NoRiaFingernailofFire")
  end
  if type(self.sameDamageCont) == "number" then self.sameDamageCont = 0 end
  return 1
end
local hades = {
  limit = 9,
  pace = false,                 -- his slow pace is the fight: he walks while he burns, as KH2's Hades
  fire = "real",
  iframes = 40,
  counter = hadesCounter,
  pre = function(self, firing)
    if type(self.sameDamageCont) ~= "number" then return end
    if firing then
      self.sameDamageCont = 99
      self.oldDamagePoint = Entity.GetDamagePoint(self.myHandle)
    else
      self.sameDamageCont = 0
    end
  end,
}
cfg.b80vs00 = hades                                  -- Mirage Arena: as it was
local hadesStory = {}
for k, v in pairs(hades) do hadesStory[k] = v end
hadesStory.limit = 8
hadesStory.armorStates = { MegaFire = true, BladesCrossing = true, FingernailofFire = true }
hadesStory.answer = { close = { "NoRiaFingernailofFire", "BladesCrossing" }, far = { "MegaFire", "BladesCrossing" }, noRet = true }
cfg.b01he00 = hadesStory

-- Master Xehanort.  vanilla: never leaves a ground combo - his script's escape (a quick
-- warp, from idle into a warp attack) is still there but switched off at the first line
-- of OnDamageBefore.  At the limit he uses it.
cfg.b40ex00 = {
  limit = 7,
  armorStates = { Warp = true, UltimateFreeze = true, BladeTornado = true, RisingGround = true,
                  Attack0 = true, Attack1 = true, Thundaga = true, Blizzaga = true },
  -- his answer: his own attack patterns - close mostly his slashes (pattern 1: Attack0 / Attack1), else
  -- his magic (pattern 2: Rising Ground / Blizzaga / Thundaga); never his specials
  answer = function(self, near, ret, choose)
    if type(self.StartAttackPattern) ~= "function" or self.phase == 100 then return nil end
    local melee = near and Script.Random() < 0.65
    if melee then self:StartAttackPattern(1, 0) else self:StartAttackPattern(2, 0) end
    return true
  end,
  counter = function(self)
    if type(self.QuickWarpStart) ~= "function" or type(self.GetState) ~= "function" then return 0 end
    local s = self:GetState()
    if s == "Warp" or s == "UltimateFreeze" or s == "Dead" or s == "Appear" or self.phase == 100 then return 0 end
    -- with an answer the quick warp lands in Idling (his param 101) and the answer picks the attack
    if answers(self) and type(self.DamageWarpParam) == "number" then self.DamageWarpParam = 101 end
    self:QuickWarpStart()
    self.damageCombo = 0
    return 1
  end,
}

-- No Heart (standing form).  He never flinches (he has no flinch animations), so there is
-- no combo to break out of.  vanilla: 4.4-10.4 s after the first hit of a string of hits
-- he answers with his burst.  Here the burst comes when the revenge value is reached.
cfg.b85vs00 = {
  limit = 14,
  iframes = 0,                  -- Final Mix superboss: as he was
  pace = false,                 -- Final Mix superboss
  grace = 120, drain = 0.03,    -- vanilla forgets a string of hits over ~10 s
  clear = true,                 -- his gauge stands in for that timer: a burst starts it over
  armored = true,
  quiet = "real",
  fire = "real",
  pre = function(self, firing)
    if type(self.burstTimer) ~= "number" then return end
    self.burstStartFlag = 1                       -- timer "running": the script does not roll a new one
    if firing then self.burstTimer = -1 else self.burstTimer = 100000 end
  end,
  fired = function(self) return self:GetState() == "BurstAttack" end,
}
