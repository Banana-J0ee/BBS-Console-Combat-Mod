-- =====================================================================
--  BBS Revenge Value  (KH2-style revenge system for Birth by Sleep FM)
--
--  Loaded as a prologue of arc/system/CommonLua.arc -> Factory.lub.
--  The original Factory.lub code runs first (unchanged, embedded), then
--  this file layers a revenge counter on top of selected bosses.
--
--  How BBS works (vanilla): every boss AI has OnDamageBefore/OnDamage
--  callbacks.  OnDamageBefore runs on (nearly) every hit and can negate
--  it; OnDamage runs only when no damage reaction is under way - the
--  first hit of a combo - and can refuse the flinch.  Humanoid bosses
--  roll dice in them on every hit, so a combo can be broken by its
--  first hit; bosses whose only break-out lives in OnDamage (Zack,
--  Hades) or nowhere (Peter Pan) can instead be comboed forever.
--
--  Version 2 copies the system KH2 itself uses (verified in its code
--  and data): every hit adds a weight to a gauge, the gauge drains
--  while the boss is not being hit, and at a per-boss limit the boss
--  performs its revenge action - guaranteed, even mid-combo:
--    - below the limit the dice are taken away: no random escapes;
--    - at the limit the boss breaks out through its own script, or
--      through a `counter` the config brings; a watchdog in the boss's
--      update forces it even when the engine mutes the hit callbacks
--      (some juggle reactions do), and an HP watch keeps counting the
--      hits the callbacks never see;
--    - the limit is re-rolled a little after each revenge (KH2 FM
--      varies the cap), and the break-out can get a short armour
--      window so it cannot be stuffed (KH2 revenge actions have one).
--  Hits that land while the boss has super armour are not counted.
--  Bosses that are not listed (all the large ones) are untouched.
-- =====================================================================
__FACTORY_ORIGINAL__()

-- Everything below is additive.  It runs inside pcall so that, whatever
-- happens, the original factory above is already in place and working.
pcall(function()
local RV = { version = "2.0", cfg = {}, ents = {} }
BBS_REVENGE = RV
-- The game's Lua has no math library (only the engine's Math): these stand in for it.
local function floor(x) local r = x % 1 return x - r end
local function max(a, b) if a > b then return a end return b end
local function rnd() return 0.5 end              -- (only when the engine's Script.Random is missing)
RV.floor, RV.max = floor, max
-- the DLL's BBS_AtkState(handle): hit windows + 64 x windows not over + 4096 x shots of that entity (moves "hit")
local ATKF = rawget(_G, "BBS_AtkState")
if type(ATKF) ~= "function" then ATKF = nil end

-- Debug log: the DLL registers BBS_Log only when bbskh2_debug.txt is in the game folder (one line per
-- call, in bbskh2_log.txt).  Otherwise nothing below writes anything.
local LOGF = rawget(_G, "BBS_Log")
if type(LOGF) ~= "function" then LOGF = nil end
local function rlog(...)
  if LOGF == nil then return end
  local n = select("#", ...)
  local t = { ... }
  pcall(function()
    for i = 1, n do
      local v = t[i]
      if type(v) == "number" then t[i] = string.format("%.1f", v) else t[i] = tostring(v) end
    end
    LOGF(unpack(t, 1, n))
  end)
end
RV.log = rlog
-- debug: milliseconds (BBS_Ms, debug builds only) - a boss callback that takes long is logged
local MSF = rawget(_G, "BBS_Ms")
if type(MSF) ~= "function" or LOGF == nil then MSF = nil end
local function slowCheck(name, what, t0, self)
  if MSF == nil or t0 == nil then return end
  local ok, t1 = pcall(MSF)
  if ok and type(t1) == "number" and t1 - t0 > 30 then
    local s = "?"
    pcall(function() s = tostring(self:GetState()) end)
    rlog(name, "SLOW", what, "took", t1 - t0, "ms in", s)
  end
end
local function msNow() if MSF == nil then return nil end local ok, t = pcall(MSF) if ok then return t end return nil end

-- Revenge value added per hit.  Scaled to KH2's own attack data
-- (00battle.bin atkp, "revenge damage", read from the game: a normal
-- hit is 1.0, finishers ~3, multi-hit spells small amounts per tick).
-- All times below are in the engine's own frames: Entity.GetFrameRate
-- advances 60 a second (verified in the game's code - the entity dt it
-- returns is in 60ths).  The first v2 build read them as 30ths, so the
-- gauge drained twice as fast as KH2 with half the intended grace and
-- could never fill at a real combo's pace.
RV.weight = {
  default   = 1.0,   -- normal combo hits, attack commands
  magic     = 1.5,
  magicCast = 4.0,   -- one cast adds at most this (KH2's heaviest magic)
  magicWin  = 90,    -- 1.5 s: magic hits this close count as one cast
  finish    = 3.0,   -- combo finishers / finish commands
  shootlock = 0.3,   -- per shotlock hit
  launch    = 0.5,   -- extra for hits that launch / knock away
}
RV.grace    = 60     -- 1 s after the last hit before the gauge drains: a combo's
                     -- own gaps (0.3 .. 0.9 s) never drain it, as in KH2, where
                     -- hit-stun blocks the drain outright
RV.drain    = 0.1    -- per frame once draining = KH2's 6 hit-units a second
RV.vary     = 1.0    -- next limit = boss's limit +- up to this, re-rolled per revenge
RV.watchdog = 12     -- 0.2 s at the limit without a break-out before `counter` is forced from the update
RV.iframes  = 45     -- armour after a forced break-out, so the answer cannot be stuffed (per boss: cfg.iframes;
                       -- 0 = none).  It lasts until the boss is back in an idle or a walk - then the end of its
                       -- answer can be punished - and at most RV.armorMax frames.
RV.armorMax = 180
-- The revenge answer (KH2: a boss that breaks out of a combo always attacks - its "revenge" act starts an
-- attack, a warp being part of it).  After a forced break-out the boss owes an attack: the first time its
-- get-away hands over to an idle / walk state (or a state in cfg.answerAt), it goes into an attack picked
-- by cfg.answer instead, under armour.  An owed attack lapses after RV.oweMax frames, and when the boss
-- starts an attack of its own first.
RV.oweMax = 300
RV.answerArmorMax = 300   -- armour cap for an answer, from the attack's start
RV.answerNear = 16        -- squared distance (4 m) under which the close list is used
-- The opening: a boss with an answer list opens the fight with an attack from it instead of its first
-- idle after the entrance (its first idle / walk state, or a state in cfg.openAt), then its own loop.
RV.opening = true

-- Boss pace ([Bosses] in bbskh2.ini).  KH2 bosses wait 0.25 .. 0.75 s between decisions and
-- walk at most 1 .. 2 s before attacking (their AI files: idle_time 15..45 frames, move_target
-- 60..120); BBS's humanoid bosses idle 1.5 .. 2 s and walk up to 5 .. 12 s.  The two numbers
-- below are markers the DLL overwrites with the ini values; left as they are, the defaults apply.
RV.aggr      = 9001.5  -- idle waits x this (1 = vanilla); never cut below RV.idleFloor
RV.walkCap   = 9002.5  -- walk / approach / wander timers capped at this many seconds (0 = no cap)
if RV.aggr > 100 or RV.aggr <= 0 then RV.aggr = 0.4 end
if RV.walkCap > 100 or RV.walkCap < 0 then RV.walkCap = 2.0 end
RV.idleFloor = 45      -- 0.75 s, KH2's longest wait between decisions: shorter waits stay as they are

-- ---------------------------------------------------------------------
-- bbskh2_boss.ini: per boss and move, how long the move is armoured (KH3: from the wind-up through the hit, the
-- recovery open), the gaps between attacks (a short beat instead of the idle wait, a reposition after a few
-- attacks in a row, sometimes a pause) and cooldowns.  The text below is the shipped file (genrevenge.py puts it
-- in); the DLL's BBS_BossIni(section) reads the file in the game / mod folder each time a boss is created, and
-- its keys win.  Bosses without a section keep the behaviour of their config alone.
-- ---------------------------------------------------------------------
RV.bossIniText = __BOSS_INI__
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function iniParse(text, into)
  local out, cur = into or {}, nil
  for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    line = line:gsub("[;#].*$", "")
    local sec = line:match("^%s*%[(.-)%]")
    if sec ~= nil then
      cur = trim(sec)
      out[cur] = out[cur] or {}
    elseif cur ~= nil then
      local k, v = line:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
      if k ~= nil and k ~= "" then out[cur][k] = v end
    end
  end
  return out
end
RV.iniParse = iniParse
local INI = {}
pcall(iniParse, RV.bossIniText, INI)
RV.ini = INI
local INI_IDS = {}
for sname, sec in pairs(INI) do
  for id in (sec.Ids or ""):gmatch("[%w_]+") do INI_IDS[id] = sname end
end
local function numRange(v, d1, d2)
  if type(v) ~= "string" then return d1, d2 end
  local a, b = v:match("^%s*([%d%.]+)%s*%-%s*([%d%.]+)")
  if a ~= nil then
    a, b = tonumber(a), tonumber(b)
    if a > b then a, b = b, a end
    return a, b
  end
  a = tonumber((v:match("^%s*([%d%.]+)")))
  if a ~= nil then return a, a end
  return d1, d2
end
-- the profile of a boss: { name, moves = { State = true | frames | "vanilla" }, cd = { State = frames },
--   repo = { State = true }, repoList, beat = {a, b}, chain = {a, b}, pause = {pct, a, b}, near (m) }
local function bossProfile(id)
  local sname = INI_IDS[id]
  if sname == nil then return nil end
  local sec = {}
  for k, v in pairs(INI[sname]) do sec[k] = v end
  local live = rawget(_G, "BBS_BossIni")
  if type(live) == "function" then
    local ok, txt = pcall(live, sname)
    if ok and type(txt) == "string" then
      local p = iniParse("[" .. sname .. "]\n" .. txt)
      for k, v in pairs(p[sname] or {}) do sec[k] = v end
    end
  end
  local pr = { name = sname, moves = {}, cd = {}, repo = {}, repoList = {}, near = 3 }
  pr.beat = { numRange(sec.Beat, 15, 24) }
  pr.chain = { numRange(sec.Chain, 2, 4) }
  local pct, rest = (sec.Pause or "0"):match("^%s*([%d%.]+)%s*,?%s*(.*)$")
  pr.pause = { tonumber(pct) or 0, numRange(rest, 60, 120) }
  pr.near = tonumber(sec.PauseNear or "") or 3
  for n in (sec.Reposition or ""):gmatch("[%w_]+") do pr.repo[n] = true; pr.repoList[#pr.repoList + 1] = n end
  for k, v in pairs(sec) do
    if k ~= "Ids" and k ~= "Beat" and k ~= "Chain" and k ~= "Pause" and k ~= "PauseNear" and k ~= "Reposition" then
      local a, rest2 = v:match("^%s*([^,]+)%s*,?(.*)$")
      if a ~= nil then
        a = trim(a):lower()
        local m
        if a == "all" then m = true elseif a == "vanilla" then m = "vanilla"
        elseif a:match("^hit") then m = { hit = true, fallback = tonumber(a:match("^hit%s*([%d%.]+)")) or 60 }
        else m = tonumber(a) end
        if m ~= nil then pr.moves[k] = m end
        local cd = (rest2 or ""):lower():match("cooldown%s*([%d%.]+)")
        if cd ~= nil then pr.cd[k] = tonumber(cd) * 60 end
      end
    end
  end
  return pr
end
RV.bossProfile = bossProfile

-- ---------------------------------------------------------------------
-- Controlled dice.  While one of our wrapped callbacks runs, the boss
-- script sees the values we choose instead of real random numbers.
-- ---------------------------------------------------------------------
-- The dice state lives in one global table so that it survives the game
-- re-running the common scripts (every generation shares it).
local S = __BBS_REVENGE_DICE
if type(S) ~= "table" then
  S = { real = nil, def = nil, seq = nil, idx = 0 }
  __BBS_REVENGE_DICE = S
end

local HIGH = 0.999   -- "never happens" roll (stays inside the engine's 0..1 range)

local function coin()
  if S.real ~= nil and S.real() < 0.5 then return 0 end
  return HIGH
end
RV.coin = coin

local function controlledRandom()
  if S.def == nil then
    return S.real()
  end
  local v = nil
  if S.seq ~= nil then
    S.idx = S.idx + 1
    v = S.seq[S.idx]
  end
  if v == nil then v = S.def end
  if v == "coin" then v = coin() end
  return v
end

local function installRandom()
  if Script == nil or type(Script.Random) ~= "function" then return false end
  if S.real == nil then
    S.real = Script.Random          -- the engine's own function, captured once
    S.hook = controlledRandom
    Script.Random = controlledRandom
  end
  -- If something else wrapped Script.Random later we leave it alone: it
  -- still ends up in our hook, and S.real must never point at a wrapper.
  return true
end

-- State changes made by the boss script run with the real dice again, so
-- the move the boss breaks out into still plays out with its normal variety.
local function unforced(f, self, a, b, c)
  local pd, ps, pi = S.def, S.seq, S.idx
  S.def, S.seq = nil, nil
  local ok, r = pcall(f, self, a, b, c)
  S.def, S.seq, S.idx = pd, ps, pi
  if not ok then error(r, 0) end
  return r
end

local function forced(def, seq, f, self, a, b, c, d)
  if f == nil then return 0 end
  local pd, ps, pi = S.def, S.seq, S.idx
  local go = self.GotoState
  local own = rawget(self, "GotoState")
  if type(go) == "function" then
    rawset(self, "GotoState", function(s, x, y, z) return unforced(go, s, x, y, z) end)
  end
  S.def, S.seq, S.idx = def, seq, 0
  local ok, r = pcall(f, self, a, b, c, d)
  S.def, S.seq, S.idx = pd, ps, pi
  if type(go) == "function" then rawset(self, "GotoState", own) end
  if not ok then error(r, 0) end
  return r
end

local function truthy(r)
  return r ~= nil and r ~= false and r ~= 0
end

-- KH2's weights, from its attack data.  Magic is capped per cast: hits
-- within magicWin frames of each other count as one cast of at most
-- magicCast, the way KH2 gives multi-hit spells small per-tick values.
local function hitValue(st, kind, cat)
  local w = RV.weight
  if cat == COMMAND_CATEGORY_FINISH then return w.finish end
  if cat == COMMAND_CATEGORY_SHOOTLOCK then return w.shootlock end
  if cat == COMMAND_CATEGORY_MACIG then
    if st.t - st.magT > w.magicWin then st.magSum = 0 end
    st.magT = st.t
    local v = w.magic
    if st.magSum + v > w.magicCast then v = w.magicCast - st.magSum end
    if v < 0 then v = 0 end
    st.magSum = st.magSum + v
    return v
  end
  local v = w.default
  if kind == ATK_KIND_DMG_BLOW or kind == ATK_KIND_DMG_TOSS or kind == ATK_KIND_DMG_BEAT or kind == ATK_KIND_DMG_FLICK then
    v = v + w.launch
  end
  return v
end

-- Everything that hits the boss builds revenge; healing "hits" do not.
local function countsAsHit(kind)
  return kind ~= ATK_KIND_RECOVER
end

-- States a forced break-out must never cut into: warps / vanishing moves hide the boss (alpha 0, no
-- damage or lock-on collision) until the move's own end shows it again, so leaving them any other way
-- leaves it invisible and unhittable.  Also entrances, deaths and mode changes.
local UNSAFE = { "Warp", "Escape", "Diving", "Disappear", "Teleport", "Ride", "StyleChange", "Appear",
                 "Dead", "Standby", "Hide", "Sink", "Fly", "Goes_away", "Fall", "Breakdown" }
local function unsafeState(self)
  if type(self) ~= "table" or type(self.GetState) ~= "function" then return true end
  local ok, s = pcall(self.GetState, self)
  if not ok or type(s) ~= "string" then return true end
  for i = 1, #UNSAFE do if s:find(UNSAFE[i], 1, true) then return true end end
  return false
end
RV.unsafeState = unsafeState

local function shielded(h)
  if Enemy.IsNoDamageReaction(h) then return true end
  local inv = Enemy.IsInvincible
  if inv ~= nil and inv(h) == true then return true end
  return false
end

-- ---------------------------------------------------------------------
-- Boss pace.  The boss scripts start their waits with Entity.SetTimer(h, frames) when they
-- enter a state (Idling 120, TargetMove 300, ...) and leave the state once IsTimeOver says so.
-- The engine function is wrapped once; for a paced boss the value is changed by the state the
-- boss is entering or in: idle states shortened, walk states capped.  Attacks, wind-ups and
-- reactions use their timers in other states and keep them.
-- ---------------------------------------------------------------------
local P = __BBS_PACE
if type(P) ~= "table" then
  P = { real = nil, hook = nil, by = {} }
  __BBS_PACE = P
end

local function paceKind(s)
  if type(s) ~= "string" then return nil end
  if s:find("Idling") or s:find("Waiting") or s == "Hovering" then return "idle" end
  if s:find("Move$") or s:find("Walk$") or s:find("^Wander") or s:find("^Approach") then return "walk" end
  return nil
end
RV.paceKind = paceKind

-- floor: a boss's own shortest wait (cfg.idleFloor, frames) instead of RV.idleFloor
local function paceIdle(v, floor)
  floor = floor or RV.idleFloor
  if RV.aggr >= 1 or v <= floor then return v end
  local n = v * RV.aggr
  if n < floor then n = floor end
  return n
end

local function paceValue(kind, v, floor)
  if kind == "idle" then return paceIdle(v, floor) end
  if kind == "walk" then
    local cap = RV.walkCap * 60
    if cap > 0 and v > cap then return cap end
  end
  return v
end
RV.paceValue = paceValue

local function pacedTimer(h, v, a, b)
  local st = P.by[h]
  if st ~= nil and type(v) == "number" then
    local ok, nv = pcall(st.pace, h, v)
    if ok and type(nv) == "number" then v = nv end
  end
  return P.real(h, v, a, b)
end

local function installPace()
  if Entity == nil or type(Entity.SetTimer) ~= "function" then return false end
  if Entity.SetTimer ~= P.hook then
    P.real = Entity.SetTimer          -- the engine's own (or whatever wraps it now)
    P.hook = pacedTimer
    Entity.SetTimer = pacedTimer
  end
  return true
end

local function attach(ent, name, handle)
  local c = RV.cfg[name]
  if c == nil or type(ent) ~= "table" then return end
  local odb, od, ord, upd = ent.OnDamageBefore, ent.OnDamage, ent.OnReturnDamage, ent.OnUpdate
  local gssOrig = ent.GotoStateSub                -- the game's own state change, before any wrapper of ours
  if odb == nil and od == nil then return end     -- nothing to steer (helper object, clone, ...)
  if not installRandom() then return end

  local st = rawget(ent, "__rv")
  if st ~= nil then                         -- same object re-used: just clear
    st.rv, st.idle, st.firing, st.fireT, st.armor = 0, 0, false, 0, 0
    st.mArmor = 0
    st.owe = nil
    st.opening = RV.opening and c.answer ~= nil and c.opening ~= false
    st.limit = c.limit
    st.pr = bossProfile(name)
    st.chain, st.chainN, st.cdUntil, st.hold, st.pauseOn, st.winOff = 0, nil, {}, 0, false, false
    if st.pace ~= nil and handle ~= nil then P.by[handle] = st end
    return
  end
  st = { rv = 0, idle = 0, firing = false, fireT = 0, armor = 0, count = 0, fcount = 0,
         t = 0, magT = -1e9, magSum = 0, hp = nil, sawHit = false, seen = -1e9, drop = -1e9,
         limit = c.limit, name = name, cfg = c }
  st.pr = bossProfile(name)
  st.chain, st.cdUntil, st.hold, st.pauseOn, st.winOff, st.reroll = 0, {}, 0, false, false, 0
  st.opening = RV.opening and c.answer ~= nil and c.opening ~= false
  rawset(ent, "__rv", st)
  RV.ents[name] = st

  -- dice value(s) for this boss; a config entry may be a function(self)
  local function pick(v, self, default)
    if type(v) == "function" then v = v(self) end
    if v == nil then return default end
    return v
  end
  local function runQuiet(f, self, kind, cat, attr, x)
    -- an armoured move whose script would still cut it short on any hit (Braig: every hit sends his shots
    -- to Idling, armour or not): the hit does not reach the script
    if c.armorHit ~= nil and ((st.mArmor or 0) > 0 or st.armor > 0) and c.armorHit(self) == true then
      rlog(name, st.t, "hit kept from the script: armoured move goes on")
      return 0
    end
    if c.pre ~= nil then c.pre(self, false) end
    local dice = pick(c.quiet, self, HIGH)
    if dice == "real" then           -- nothing to take away: pre() keeps the break-out off
      if f == nil then return 0 end
      return f(self, kind, cat, attr, x)
    end
    return forced(dice, nil, f, self, kind, cat, attr, x)
  end
  local function runFire(f, self, kind, cat, attr, x)
    if c.pre ~= nil then c.pre(self, true) end
    local dice = pick(c.fire, self, 0)
    local r
    if dice == "real" then           -- pre() already guarantees the break-out
      if f == nil then r = 0 else r = f(self, kind, cat, attr, x) end
    else
      r = forced(dice, pick(c.fireSeq, self, nil), f, self, kind, cat, attr, x)
    end
    if c.post ~= nil then c.post(self, truthy(r)) end
    return r
  end
  -- hits the boss script answers unconditionally keep their vanilla dice
  local function vanilla(self, kind, cat)
    return c.vanilla ~= nil and c.vanilla(self, kind, cat) == true
  end

  local function active(self)
    return c.active == nil or c.active(self)
  end

  local h0 = handle
  local function myh(self) return self.myHandle or h0 end

  -- the next limit: the boss's number, re-rolled a little (KH2 FM varies the cap)
  local function rollLimit(self)
    local vary = c.vary
    if vary == nil then vary = RV.vary end
    local r = 0.5
    if S.real ~= nil then r = S.real() end
    local l = c.limit + (r * 2 - 1) * vary
    if l < 2 then l = 2 end
    st.limit = l
  end

  -- a break-out happened.  fired = it was our forced revenge: arm the
  -- armour window (KH2 revenge actions cannot be stuffed), if configured.
  -- KH2 never clears the gauge (only the boss's constructor and the drain
  -- bottoming out write 0 to +0xd48): it stays where it is and drains while
  -- the boss acts on its own, out of hit-stun.  So the drain starts at once,
  -- and a player who goes straight back in finds a boss that breaks out
  -- again after a few hits instead of a fresh full gauge.
  local function done(fired)
    local grace = c.grace
    if grace == nil then grace = RV.grace end
    st.idle, st.firing, st.fireT = grace, false, 0
    if c.clear then st.rv, st.idle = 0, 0 end     -- per boss: its own timer, not KH2's gauge
    st.count = st.count + 1
    if fired then st.fcount = st.fcount + 1 end
    rollLimit()
    rlog(name, st.t, fired and "BREAK-OUT (forced)" or "break-out (its own)", "count", st.count, "next limit", st.limit)
    st.armorCap = nil
    if fired and c.answer ~= nil then
      -- answered at once by the counter (st.answer), or owed until the get-away ends
      if st.answeredT == st.t then st.armorCap = RV.answerArmorMax else st.owe = st.t end
    end
    if fired then
      local n = c.iframes or RV.iframes
      if n ~= nil and n ~= false and n > 0 and type(Enemy.EnableNoDamageReaction) == "function" then
        Enemy.EnableNoDamageReaction(myh(ent), 1)
        st.armor = n
        st.armorT0 = st.t
      end
    end
  end

  -- the forced revenge of a hit (or of the watchdog): the boss's own
  -- callback first, the config's counter when the script has none that
  -- fires on a hit.  Returns the value for the engine.
  local function fire(f, self, kind, cat, attr, x)
    local r = runFire(f, self, kind, cat, attr, x)
    if not truthy(r) and c.counter ~= nil and not unsafeState(self) then
      local ok, r2 = pcall(c.counter, self, kind, cat, attr, x)
      if ok then r = r2 end
    end
    if truthy(r) then done(true) end
    return r
  end

  -- KH2 bosses press; a config with haste < 1 shortens the idle times a
  -- script asks its parameters for (only where the script reads them
  -- through a method on the entity - timers baked into a script as
  -- constants cannot be reached).
  if type(c.haste) == "number" and c.haste ~= 1 then
    local fns = c.hasteFns or { "GetIdlingChangeTime" }
    for i = 1, #fns do
      local fname = fns[i]
      local fn = ent[fname]
      if type(fn) == "function" then
        rawset(ent, fname, function(self, a, b)
          local v = fn(self, a, b)
          if type(v) == "number" then return v * c.haste end
          return v
        end)
      end
    end
  end

  -- boss pace: the state being entered / run decides what a SetTimer means
  if c.pace ~= false and installPace() then
    local pf = c.paceFields
    st.pace = function(h, v)
      local mh = rawget(ent, "myHandle")
      if mh ~= nil and mh ~= h then return v end        -- a stale entry: another object owns h now
      if not active(ent) then return v end
      if st.tempoSet ~= nil then return st.tempoSet end  -- the gap of bbskh2_boss.ini (an idle being entered)
      return paceValue(paceKind(st.state), v, c.idleFloor)
    end
    if h0 ~= nil then P.by[h0] = st end
    local gss = ent.GotoStateSub
    if type(gss) == "function" then
      rawset(ent, "GotoStateSub", function(self, s, a, b)
        local prev = st.state
        st.state = s
        local r = gss(self, s, a, b)
        -- the FSM sets current_state after OnBeginState, so a state change made from inside
        -- OnBeginState ends with this state current: mirror that
        if type(self.states) == "table" and self.states[s] ~= nil then st.state = s else st.state = prev end
        local mh = rawget(self, "myHandle")
        if mh ~= nil then P.by[mh] = st end
        -- scripts that count an idle down in a field of their own (frames) instead of SetTimer
        if pf ~= nil and pf[s] ~= nil and active(self) then
          local f = pf[s]
          if type(self[f]) == "number" then self[f] = paceIdle(self[f], c.idleFloor) end
        end
        return r
      end)
    end
  end

  -- KH2 registers each boss move with a flag: specials, warps and revenge answers cannot be
  -- interrupted once started (0x10000 in its act table), normal attacks can.  armorStates lists
  -- the BBS moves of that class that the scripts leave flinchable: true = the whole move,
  -- a number = its first frames only.  Off again when the move ends, so its end is punishable.
  -- bbskh2_boss.ini (st.pr) overrides it per move: a number there is the KH3 window - armoured for that many
  -- frames from the start of the move (counted while the boss is visible), then open, also where the game's
  -- own script armours the whole move (st.winOff: held off until the move ends); "vanilla" = the script alone.
  local as = c.armorStates
  local function moveArmor(s)
    local pr = st.pr
    if pr ~= nil and pr.moves[s] ~= nil then
      local v = pr.moves[s]
      if v == "vanilla" then return nil end
      return v
    end
    if as ~= nil then return as[s] end
    return nil
  end
  if as ~= nil or st.pr ~= nil then
    local function setNDR(h, on)
      if type(Enemy.EnableNoDamageReaction) == "function" then Enemy.EnableNoDamageReaction(h, on and 1 or 0) end
    end
    local gss2 = ent.GotoStateSub
    if type(gss2) == "function" then
      rawset(ent, "GotoStateSub", function(self, s, a, b)
        local h = myh(self)
        st.winOff, st.winState = false, nil
        if st.mArmor ~= nil and st.mArmor > 0 then         -- leaving an armoured move
          st.mArmor = 0
          if not (st.armor > 0) and active(self) then setNDR(h, false) end
        end
        local r = gss2(self, s, a, b)
        local v = moveArmor(s)
        st.hitWin = nil
        if v ~= nil and v ~= false and active(self) and type(self.GetState) == "function" and self:GetState() == s then
          if v == true then st.mArmor = 1e9
          elseif type(v) == "table" then
            -- "hit": armoured until the move's hit windows have all closed (or it has shot something), checked
            -- every frame through the DLL; with neither, its fallback frames
            st.mArmor = 1e9
            st.hitWin = { state = s, fallback = v.fallback, t = 0, seen = false, shots0 = nil }
          else st.mArmor = v st.winState = s end
          if st.mArmor > 0 then setNDR(h, true) else st.winOff = true end
        end
        return r
      end)
    end
  end

  -- ---------------------------------------------------------------------------------------------------------
  -- Gaps between attacks (bbskh2_boss.ini; KH3: no idle waits - recoveries, repositions, cooldowns).  cfg.tempo:
  --   idle = { State = "timer" | "hold" | { field = "name" } }: the boss's idle states and how each one waits:
  --     its Entity.SetTimer, a hold of ours (its update is skipped while it lasts), or a frame field of its own
  --   pop = { State = true }: Reposition moves that return through the boss's stack (the idle is pushed first)
  -- On the first idle after an attack: the Beat (a pause instead, now and then, after a reposition).  After Chain
  -- attacks in a row: a Reposition move instead of the idle.  An attack on cooldown is swapped for another (the
  -- revenge answer's pick, by distance) or the boss decides again; with nothing else to pick it goes ahead.
  -- ---------------------------------------------------------------------------------------------------------
  local tempo = c.tempo
  local function roll(lo, hi)
    local r = (S.real ~= nil and S.real()) or rnd()
    return lo + (hi - lo) * r
  end
  if tempo ~= nil and st.pr ~= nil then
    local idles = tempo.idle or {}
    local function isAttack(s)
      local pr = st.pr
      if pr == nil or pr.repo[s] then return false end
      return pr.moves[s] ~= nil
    end
    local gssT = ent.GotoStateSub
    if type(gssT) == "function" then
      rawset(ent, "GotoStateSub", function(self, s, a, b)
        local pr = st.pr
        if pr == nil or type(s) ~= "string" or not active(self) then return gssT(self, s, a, b) end
        local prev = st.tstate
        local mode = idles[s]
        local f = nil
        if isAttack(s) then
          local cdu = st.cdUntil[s]
          if cdu ~= nil and cdu > st.t and not st.answering and not st.subbing then
            if st.reroll < 2 then
              -- on cooldown: another attack (the answer's pick) or a new decision
              st.reroll = st.reroll + 1
              local stk = self.stack
              if stk ~= nil and type(stk.getn) == "function" and st.idleBase ~= nil then
                while stk:getn() > st.idleBase do stk:pop(1) end
              end
              st.subbing = true
              local ok, done = pcall(function()
                if st.enterSub ~= nil and st.enterSub(self, st.idleName or prev) then return true end
                return false
              end)
              st.subbing = false
              if ok and done then rlog(name, st.t, "cooldown:", s, "swapped") return nil end
              if st.idleName ~= nil and self.states ~= nil and self.states[st.idleName] ~= nil then
                rlog(name, st.t, "cooldown:", s, "decides again")
                st.rerollIdle = true
                local r = self:GotoStateSub(st.idleName)
                st.rerollIdle = false
                return r
              end
            end
            rlog(name, st.t, "cooldown:", s, "nothing else to pick - goes ahead")
          end
          st.reroll = 0
          if pr.cd[s] ~= nil then st.cdUntil[s] = st.t + pr.cd[s] end
          if not isAttack(prev) then st.chain = st.chain + 1 end    -- (a move that follows on from another counts once)
          st.needBeat, st.pauseOn = true, false
        elseif pr.repo[s] then
          st.chain, st.chainN, st.afterRepo, st.needBeat, st.pauseOn = 0, nil, true, true, false
        elseif mode ~= nil then
          if st.rerollIdle then
            f = 2
          elseif st.needBeat then
            st.needBeat = false
            st.chainN = st.chainN or floor(roll(pr.chain[1], pr.chain[2] + 0.999))
            if st.chain >= st.chainN and not st.answering and (tempo.repoAt == nil or tempo.repoAt[s]) then
              -- a reposition instead of the idle
              local list = {}
              for i = 1, #pr.repoList do
                if type(self.states) == "table" and self.states[pr.repoList[i]] ~= nil then list[#list + 1] = pr.repoList[i] end
              end
              if #list > 0 then
                local n = list[floor(roll(1, #list + 0.999))]
                local stk = self.stack
                if tempo.pop ~= nil and tempo.pop[n] and stk ~= nil then stk:push(s) end
                rlog(name, st.t, "chain", st.chain, "- repositions:", n)
                st.tstate = n
                return self:GotoStateSub(n)
              end
            end
            f = roll(pr.beat[1], pr.beat[2])
            if st.afterRepo and roll(0, 100) < pr.pause[1] then
              f = roll(pr.pause[2], pr.pause[3])
              st.pauseOn = true
              rlog(name, st.t, "pause", f)
            end
            st.afterRepo = false
          elseif idles[prev] ~= nil then
            f = 2                       -- idle after idle: the beat was had already
          else
            f = roll(pr.beat[1], pr.beat[2])
          end
        end
        st.tstate = s
        if f ~= nil and mode == "timer" then st.tempoSet = f end
        local ok, r = pcall(gssT, self, s, a, b)
        st.tempoSet = nil
        if not ok then error(r, 0) end
        if f ~= nil and type(self.GetState) == "function" and self:GetState() == s then
          st.idleName = s
          local stk = self.stack
          st.idleBase = (stk ~= nil and type(stk.getn) == "function") and stk:getn() or nil
          if mode == "hold" then st.hold = f
          elseif type(mode) == "table" and mode.field ~= nil and type(self[mode.field]) == "number" then self[mode.field] = f end
        end
        return r
      end)
    end
    -- holds: the idle's own update waits while it lasts (turning to the target)
    local own = nil
    for sname, mode in pairs(idles) do
      if mode == "hold" and type(ent.states) == "table" and type(ent.states[sname]) == "table" then
        if own == nil then
          own = {}
          for k, v in pairs(ent.states) do own[k] = v end
        end
        local orig = ent.states[sname]
        local copy = {}
        for k, v in pairs(orig) do copy[k] = v end
        local up = orig.OnUpdate
        copy.OnUpdate = function(self, x, y)
          if st.hold > 0 and active(self) then
            local dt = Entity.GetFrameRate(myh(self))
            if type(dt) ~= "number" or dt <= 0 or dt > 6 then dt = 1 end
            st.hold = st.hold - dt
            pcall(Entity.TurnTargetYDegree, myh(self), self.targetHandle, 5)
            return
          end
          if up ~= nil then return up(self, x, y) end
        end
        own[sname] = copy
      end
    end
    if own ~= nil then rawset(ent, "states", own) end
  end

  -- the revenge answer (see RV.oweMax): the get-away hands over to an attack
  local ans = c.answer
  if ans ~= nil then
    local gss3 = ent.GotoStateSub
    local function attackLike(n)
      if type(n) ~= "string" then return false end
      if (c.armorStates ~= nil and c.armorStates[n]) or (c.answerClear ~= nil and c.answerClear[n]) then return true end
      if type(ans) == "table" then
        for _, l in ipairs({ ans.close or {}, ans.far or {} }) do
          for i = 1, #l do if l[i] == n then return true end end
        end
      end
      return n:find("Attack") ~= nil or n:find("Combo") ~= nil or n:find("Shoot") ~= nil
    end
    local function real() if S.real ~= nil then return S.real() end return rnd() end
    local function choose(list)
      local pool = {}
      for i = 1, #list do
        if list[i] ~= st.lastAnswer then pool[#pool + 1] = list[i] end
      end
      if #pool == 0 then pool = list end
      if st.subbing then
        -- swapping an attack on cooldown: only moves that are ready; none ready = the one closest to ready
        local ready, best, bestT = {}, nil, nil
        for i = 1, #list do
          local u = st.cdUntil[list[i]] or -1e9
          if u <= st.t then ready[#ready + 1] = list[i] end
          if bestT == nil or u < bestT then best, bestT = list[i], u end
        end
        if #ready > 0 then pool = ready else pool = { best } end
      end
      if #pool == 0 then return nil end
      local k = floor(real() * #pool) + 1
      if k > #pool then k = #pool end
      st.pickLabel = pool[k]
      return pool[k]
    end
    -- go into the answer instead of `ret` (the state the get-away hands over to; nil from a counter).
    -- cfg.answer: { close = {...}, far = {...}, noRet = true } (ret is pushed on the boss's stack for the
    -- attack's own pop, unless noRet), or function(self, near, ret, choose) -> a state name (it arranges the
    -- stack itself), or true when it went into the attack itself.  Returns true when the boss attacks.
    -- armour for the whole answer (KH2's revenge attacks cannot be stuffed), from its first frame
    local function armorUp(self)
      local fr = c.iframes or RV.iframes
      if fr ~= nil and fr ~= false and fr > 0 then
        st.armor = max(st.armor, fr)
        st.armorT0 = st.t
        st.armorCap = RV.answerArmorMax
        if type(Enemy.EnableNoDamageReaction) == "function" then Enemy.EnableNoDamageReaction(myh(self), 1) end
      end
    end
    local function enterAnswer(self, ret, a, b, opening)
      local h = myh(self)
      local tgt = Enemy.SearchAttackEntity(h, SEARCH_TYPE_NEAR)
      if tgt ~= nil and type(tgt) ~= "table" then self.targetHandle = tgt end
      local d = Entity.CalcDistanceSq(h, self.targetHandle)
      local near = type(d) == "number" and d < (c.answerNear or RV.answerNear)
      local stk = self.stack
      local base = (stk ~= nil and type(stk.getn) == "function") and stk:getn() or nil
      local pd, ps = S.def, S.seq
      S.def, S.seq = nil, nil                           -- the boss's own choices use real dice
      st.answering = true
      local ok, res = pcall(function()
        for try = 1, 4 do
          st.pickLabel = nil
          local n
          if type(ans) == "function" then
            n = ans(self, near, ret, choose)
          else
            n = choose((near and ans.close or ans.far) or {})
            if n ~= nil and stk ~= nil and ret ~= nil and not ans.noRet then stk:push(ret) end
          end
          if n == true then
            local cur = self:GetState()
            rlog(name, st.t, type(opening) == "string" and opening or (opening and "OPENING" or "ANSWER"), cur, near and "(close)" or "(far)", "instead of", ret)
            if cur ~= st.lastAnswer or try == 4 or st.subbing then st.lastAnswer = cur return true end
          elseif type(n) == "string" and type(self.states) == "table" and self.states[n] ~= nil then
            local label = st.pickLabel or n
            if label ~= st.lastAnswer or try == 4 or base == nil or st.subbing then
              rlog(name, st.t, type(opening) == "string" and opening or (opening and "OPENING" or "ANSWER"), label, near and "(close)" or "(far)", "instead of", ret)
              st.lastAnswer = label
              return n                                -- entered below, outside this pcall
            end
            while stk:getn() > base do stk:pop(1) end      -- the same as last time: once more
          else
            if base ~= nil then while stk:getn() > base do stk:pop(1) end end
            return false
          end
        end
        return false
      end)
      S.def, S.seq = pd, ps
      if not ok or res == false or res == nil then st.answering = false return false end
      if type(res) == "string" then
        -- the attack itself: the boss's own state code, outside the pcall (its errors are its own)
        if not opening then armorUp(self) end
        local ok2, err = pcall(gss3, self, res, a, b)
        st.answering = false
        if not ok2 then error(err, 0) end
        return true
      end
      st.answering = false
      if not opening then armorUp(self) end
      return true
    end
    -- an attack on cooldown swapped for one of these (tempo, above): no armour of the answer's
    st.enterSub = function(self, ret) return enterAnswer(self, ret, nil, nil, "SWAP") end
    st.answer = function(self, ret)               -- for counters: answer at once (no get-away)
      st.owe = nil
      if enterAnswer(self, ret) then st.answeredT = st.t return true end
      return false
    end
    if type(gss3) == "function" then
      rawset(ent, "GotoStateSub", function(self, s, a, b)
        if (st.owe ~= nil or st.opening) and not st.answering and type(s) == "string" then
          if st.owe ~= nil and (st.t - st.owe > RV.oweMax or not active(self)) then st.owe = nil end
          if st.opening and not active(self) then st.opening = false end
          if st.owe ~= nil or st.opening then
            local at = (c.answerAt ~= nil and c.answerAt[s]) or (c.answerAt == nil and paceKind(s) ~= nil)
            if st.opening and c.openAt ~= nil and c.openAt[s] then at = true end
            if at then
              local opening = st.owe == nil
              st.owe, st.opening = nil, false
              if enterAnswer(self, s, a, b, opening) then return nil end
            elseif attackLike(s) then
              st.owe, st.opening = nil, false     -- it attacks on its own: nothing owed
            end
          end
        end
        return gss3(self, s, a, b)
      end)
    end
  end

  -- a state change to nothing (a stack popped empty: "state not found [nil]" leaves the boss frozen in the move
  -- that ended) goes to the boss's idle instead: its first tempo idle, or Idling / BattleIdling
  local gssN = ent.GotoStateSub
  if type(gssN) == "function" then
    rawset(ent, "GotoStateSub", function(self, s, a, b)
      if (s == nil or (type(self.states) == "table" and self.states[s] == nil)) and active(self) and type(self.states) == "table" then
        local home = nil
        if c.tempo ~= nil and c.tempo.idle ~= nil then
          for n, m in pairs(c.tempo.idle) do if m == "timer" or m == "hold" then home = n end end
        end
        if home == nil or self.states[home] == nil then home = self.states.Idling and "Idling" or (self.states.BattleIdling and "BattleIdling") end
        if home ~= nil then
          rlog(name, st.t, "state", tostring(s), "does not exist: goes to", home)
          return gssN(self, home, a, b)
        end
      end
      return gssN(self, s, a, b)
    end)
  end

  -- per-boss changes to the script's own states (the instance gets its own states table)
  if c.setup ~= nil then pcall(c.setup, ent) end

  rawset(ent, "OnDamageBefore", function(self, kind, cat, attr, x)
    if not active(self) then
      if odb == nil then return 0 end
      return odb(self, kind, cat, attr, x)
    end
    st.sawHit = true
    if vanilla(self, kind, cat) then
      local r = 0
      if odb ~= nil then r = odb(self, kind, cat, attr, x) end
      if truthy(r) then done(false) end
      return r
    end
    if shielded(myh(self)) then
      -- a hit on armour.  Vanitas (all three) and Eraqus zero their idle timer on every hit before they
      -- ask about armour (vanilla: after a combo they come straight back).  With every attack armoured,
      -- each hit during an attack zeroed it and the next attack followed with no pause at all - no
      -- opening.  A hit the armour takes leaves their pause alone.
      local keep = rawget(self, "idlingTimer")
      local r = runQuiet(odb, self, kind, cat, attr, x)
      if type(keep) == "number" and type(rawget(self, "idlingTimer")) == "number" then rawset(self, "idlingTimer", keep) end
      return r
    end
    if not countsAsHit(kind) then
      return runQuiet(odb, self, kind, cat, attr, x)
    end
    local v = hitValue(st, kind, cat)
    if st.rv + v >= st.limit then
      st.rv = st.rv + v
      st.idle = 0
      st.seen = st.t
      st.firing = true
      return fire(odb, self, kind, cat, attr, x)
    end
    local r = runQuiet(odb, self, kind, cat, attr, x)
    if truthy(r) then
      done(false)                  -- the boss acted on its own: start over
    else
      st.rv = st.rv + v            -- the hit lands: build revenge
      st.idle = 0
      st.seen = st.t
    end
    return r
  end)

  if od ~= nil then
    rawset(ent, "OnDamage", function(self, kind, cat, attr, x)
      if not active(self) then return od(self, kind, cat, attr, x) end
      local r
      if vanilla(self, kind, cat) then
        r = od(self, kind, cat, attr, x)
        if truthy(r) and not c.armored then done(false) end
        return r
      end
      st.sawHit = true
      if st.firing and not shielded(myh(self)) then
        r = runFire(od, self, kind, cat, attr, x)
        if truthy(r) and not c.armored then done(true) end
        return r
      end
      r = runQuiet(od, self, kind, cat, attr, x)
      -- reaction cancelled: the boss broke out (a boss that never flinches cancels every reaction)
      if truthy(r) and not c.armored then done(false) end
      return r
    end)
  end

  if ord ~= nil or c.recover ~= nil then
    rawset(ent, "OnReturnDamage", function(self, a, b, c2, d)
      -- out of hit-stun: KH2 starts draining here, it does not clear the gauge
      -- (clearing it made every combo string start from nothing, so only one
      -- unbroken string of ~10 hits could ever bring a break-out)
      local grace = c.grace
      if grace == nil then grace = RV.grace end
      if c.clear then st.rv, st.idle, st.firing, st.fireT = 0, 0, false, 0
      elseif st.idle < grace then st.idle = grace end
      local r
      if ord ~= nil then r = ord(self, a, b, c2, d) end
      -- KH2 bosses come back at you after a combo; the config's recover
      -- overrides a script that just stands up into idling.
      if c.recover ~= nil then pcall(c.recover, self) end
      return r
    end)
  end

  rawset(ent, "OnUpdate", function(self, a, b, c2, d)
    local tms = msNow()
    if tms ~= nil then
      if st.lastMs ~= nil and tms - st.lastMs > 300 then rlog(name, "update gap", tms - st.lastMs, "ms") end
      st.lastMs = tms
    end
    local dt = Entity.GetFrameRate(myh(self))
    if type(dt) ~= "number" or dt <= 0 or dt > 6 then dt = 1 end
    st.t = st.t + dt
    -- an armoured move (armorStates): held while it runs; a timed one lets go after its frames
    local hw = st.hitWin
    if hw ~= nil then
      local vis = true
      if type(Entity.GetAlpha) == "function" then
        local ok, al = pcall(Entity.GetAlpha, myh(self))
        if ok and type(al) == "number" and al < 0.5 then vis = false end
      end
      if vis then hw.t = hw.t + dt end
      local over, why = false, nil
      if ATKF ~= nil then
        local ok, code = pcall(ATKF, myh(self))
        if ok and type(code) == "number" then
          local n = code % 64
          local open = floor(code / 64) % 64
          local shots = floor(code / 4096)
          if hw.shots0 == nil then hw.shots0 = shots end
          if open > 0 then hw.seen = true end            -- (windows already over at the start are the last move's)
          if hw.seen and open == 0 then over, why = true, "its hits are over" end
          if shots > hw.shots0 then over, why = true, "it has shot" end
        end
      end
      if not over and not hw.seen and hw.t >= hw.fallback then over, why = true, "no hit windows: fallback frames" end
      if not over and hw.t >= 600 then over, why = true, "10 s cap" end
      if over then
        st.hitWin = nil
        st.mArmor, st.winState = 4, hw.state                -- a few frames more, then the window ends as a timed one
        rlog(name, st.t, "armour of", hw.state, "ends at", hw.t, "frames:", why)
      end
    end
    if st.mArmor ~= nil and st.mArmor > 0 and type(Enemy.EnableNoDamageReaction) == "function" then
      -- (a window of bbskh2_boss.ini counts while the boss can be seen: not while a warp hides him)
      local vis = true
      if st.winState ~= nil and type(Entity.GetAlpha) == "function" then
        local ok, al = pcall(Entity.GetAlpha, myh(self))
        if ok and type(al) == "number" and al < 0.5 then vis = false end
      end
      if vis then st.mArmor = st.mArmor - dt end
      if st.mArmor > 0 then Enemy.EnableNoDamageReaction(myh(self), 1)
      else
        st.mArmor = 0
        if not (st.armor > 0) then Enemy.EnableNoDamageReaction(myh(self), 0) end
        if st.winState ~= nil then
          st.winOff = true
          rlog(name, st.t, "armour window over:", st.winState)
        end
      end
    end
    -- a pause (bbskh2_boss.ini) ends when the player comes close: he attacks
    if st.pauseOn and st.pr ~= nil then
      local cur = type(self.GetState) == "function" and self:GetState() or nil
      local mode = c.tempo and c.tempo.idle and c.tempo.idle[cur]
      if mode == nil then st.pauseOn = false
      else
        local d = Entity.CalcDistanceSq(myh(self), self.targetHandle)
        if type(d) == "number" and d < st.pr.near * st.pr.near then
          st.pauseOn = false
          rlog(name, st.t, "pause broken: player close")
          if mode == "timer" then pcall(Entity.SetTimer, myh(self), 0)
          elseif mode == "hold" then st.hold = 0
          elseif type(mode) == "table" and mode.field ~= nil and type(self[mode.field]) == "number" then self[mode.field] = 0 end
        end
      end
    end
    -- armour window after a forced revenge.  Held every frame: the boss's own
    -- states switch "no damage reaction" off when they end (a counter's
    -- OnEndState), which used to cut the window short.
    if st.armor > 0 then
      -- The answer to a combo cannot be stuffed: armour from the break-out until the boss is back
      -- in an idle or a walk (then it can be punished), at most RV.armorMax frames.  A boss whose
      -- own attack state holds "no damage reaction" (and clears it when it ends) is not cut short.
      st.armor = st.armor - dt
      local age = st.t - (st.armorT0 or 0)
      local idle = type(self.GetState) == "function" and paceKind(self:GetState()) ~= nil
      local off = (idle and age > 6) or age > (st.armorCap or RV.armorMax)
      if not off and st.armor <= 0 then st.armor = 1 end      -- the answer is still running
      if off then st.armor = 0 end
      if type(Enemy.EnableNoDamageReaction) == "function" then
        Enemy.EnableNoDamageReaction(myh(self), st.armor > 0 and 1 or 0)
      end
    end
    -- hits the engine hides from the callbacks (some juggle reactions)
    -- still cost HP: count them so those combos cannot run forever.  Only
    -- HP loss inside a hit string counts - within 1 s of a counted hit, or
    -- a second hidden drop within 0.5 s of the first - so poison and burn
    -- ticks (spaced wider, with no hits landing) cannot build revenge.
    local hp = Enemy.GetHp(myh(self))
    if type(hp) == "number" then
      -- (not while it cannot flinch anyway: a warp, an armoured move - nothing to break out of)
      if type(st.hp) == "number" and hp < st.hp and not st.sawHit and active(self) and not shielded(myh(self)) then
        if st.t - st.seen <= 60 or st.t - st.drop <= 30 then
          st.rv = st.rv + RV.weight.default
          st.idle = 0
          st.seen = st.t
          if st.rv >= st.limit then st.firing = true end
        end
        st.drop = st.t
      end
      st.hp = hp
    end
    st.sawHit = false
    -- the gauge drains while the boss is left alone (KH2: out of hit-stun)
    if st.rv > 0 then
      local grace = c.grace
      if grace == nil then grace = RV.grace end
      st.idle = st.idle + dt
      if st.idle > grace then
        local dr = c.drain
        if dr == nil then dr = RV.drain end
        st.rv = st.rv - dr * dt
        if st.rv <= 0 then st.rv, st.firing, st.fireT = 0, false, 0 end
      end
    end
    -- the watchdog: at the limit, a break-out that no hit has managed to
    -- fire (muted callbacks, a script with no own break-out) is forced
    if st.firing then
      st.fireT = st.fireT + dt
      if st.fireT >= RV.watchdog and c.counter ~= nil and active(self) and not unsafeState(self) then
        local ok, r = pcall(c.counter, self)
        if ok and truthy(r) then done(true) else st.fireT = 0 end
      end
    end
    local r
    local uok, uerr = true, nil
    if upd ~= nil then uok, uerr = pcall(upd, self, a, b, c2, d) if uok then r = uerr end end
    -- an armoured move whose own update switched "no damage reaction" off part way (Braig's
    -- ChargeShoot, Vanitas's Dark Splicer): on again before the hits of this frame land
    if st.mArmor ~= nil and st.mArmor > 0 and active(self) and type(Enemy.EnableNoDamageReaction) == "function" then
      Enemy.EnableNoDamageReaction(myh(self), 1)
    end
    -- past its window a move stays open, also where the boss's own script armours the whole move
    if st.winOff and not (st.armor > 0) and active(self) and type(Enemy.EnableNoDamageReaction) == "function" then
      Enemy.EnableNoDamageReaction(myh(self), 0)
    end
    -- break-outs that start from the boss's own update instead of from a hit
    if st.firing and c.fired ~= nil and c.fired(self) == true then done(false) end
    slowCheck(name, "update", tms, self)
    if not uok then
      rlog(name, st.t, "ERROR in the update of", type(self.GetState) == "function" and tostring(self:GetState()) or "?", ":", tostring(uerr))
      error(uerr, 0)                                -- the script's own error, as it would have been
    end
    return r
  end)

  -- safety net: if anything of ours fails during a state change, the game's own state change is done instead
  -- (an error here used to leave the boss in the move that was ending - repeating its end, frozen)
  local gTop = ent.GotoStateSub
  if type(gTop) == "function" and type(gssOrig) == "function" and gTop ~= gssOrig then
    rawset(ent, "GotoStateSub", function(self, s, a, b)
      local before = self.current_state
      local ok, r = pcall(gTop, self, s, a, b)
      if ok then return r end
      rlog(name, st.t, "ERROR in a state change to", tostring(s), ":", tostring(r))
      st.answering, st.subbing, st.tempoSet, st.rerollIdle = false, false, nil, false
      if self.current_state == before and s ~= nil and type(self.states) == "table" and self.states[s] ~= nil then
        local ok2, r2 = pcall(gssOrig, self, s, a, b)
        if not ok2 then rlog(name, st.t, "ERROR in the game's own state change to", tostring(s), ":", tostring(r2)) error(r2, 0) end
        return r2
      end
      return nil
    end)
  end

  -- debug log: state changes and hits of this boss (only with BBS_Log)
  if LOGF ~= nil then
    local function gs(self) local ok, v = pcall(self.GetState, self) if ok then return v end return "?" end
    local function ndr(self) local ok, v = pcall(Enemy.IsNoDamageReaction, myh(self)) return ok and v == true end
    rlog(name, "attached: limit", st.limit, "armour moves", c.armorStates ~= nil, "answer", c.answer ~= nil)
    local gl = ent.GotoStateSub
    if type(gl) == "function" then
      rawset(ent, "GotoStateSub", function(self, s, a, b)
        local from = gs(self)
        local r = gl(self, s, a, b)
        rlog(name, st.t, "state", from, "->", s, "now", gs(self), "noReaction", ndr(self), "armour", st.armor,
             "move", st.mArmor or 0, "gauge", st.rv, "/", st.limit)
        return r
      end)
    end
    local function wrapHit(key, label)
      local f = rawget(ent, key)
      if type(f) ~= "function" then return end
      rawset(ent, key, function(self, kind, cat, attr, x)
        local s0, n0, rv0 = gs(self), ndr(self), st.rv
        local r = f(self, kind, cat, attr, x)
        rlog(name, st.t, label, "kind", kind, "cat", cat, "in", s0, "noReaction", n0, "->", r, "gauge", rv0, "->", st.rv,
             "/", st.limit, "now", gs(self))
        return r
      end)
    end
    wrapHit("OnDamageBefore", "HIT")
    wrapHit("OnDamage", "FLINCH? (0 = flinches)")
    local fr = rawget(ent, "OnReturnDamage")
    if type(fr) == "function" then
      rawset(ent, "OnReturnDamage", function(self, a, b, c2, d)
        rlog(name, st.t, "recovered from hit-stun in", gs(self))
        return fr(self, a, b, c2, d)
      end)
    end
  end
end
RV.attach = attach

-- Hook entity construction: wrap the per-entity constructor the first
-- time a configured boss is created.
local factoryCreate = EntityFactory.Create
EntityFactory.Create = function(self, name, handle)
  if handle ~= nil then P.by[handle] = nil end    -- a handle handed out again: no stale pace entry
  local rec = self[name]
  if type(rec) == "table" and RV.cfg[name] ~= nil and not rec.__rv then
    local make = rec.Create
    rec.__rv = true
    rec.Create = function(h)
      local ent = make(h)
      if ent ~= nil then
        local ok = pcall(attach, ent, name, h)
      end
      return ent
    end
  end
  return factoryCreate(self, name, handle)
end

__BOSS_CONFIG__
end)
