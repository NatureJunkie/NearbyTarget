-- NearbyTargets (Vanilla 1.12, Lua 5.0-safe)
-- Split top-bar list with filters + multi-[t:] silent targeter (independent).
--  • Name/Filters: words + [t:name1,name2|name3] + [below:N] [above:N] [lvl:<|>|=N]
--  • Scoping: list words apply to list; everything AFTER a [t:] applies to that t-scope.
--      - Example: "wolf [t:boar][below:40]"  -> list=wolf, targeter=boar<40%
--      - Example: "[t:apple] [below:50]"     -> below applies to LIST only (separate scope)
--  • Compare toggle: % vs raw HP (affects [below]/[above] meaning and list bar color)
--  • Clickthrough: hold BOTH mouse buttons ~holdBothDelay on a row's buttons -> world input until release.
--  • Chat: [say] [party] [raid] [rw] [whisper] [whisper:Name:Name2] (no names = whisper all visible players).

---------------------------------------------------
-- SavedVariables
---------------------------------------------------
if not NearbyTargetsTypeCache then NearbyTargetsTypeCache = {} end
if not NearbyTargetsFilters   then NearbyTargetsFilters   = {} end
if not NearbyTargetsSettings  then
  NearbyTargetsSettings = {
    comparePercent   = true,   -- % vs raw HP in numeric filters and bar color
    pinTargetFirst   = false,  -- Top row shows current target if available, else lowest
    holdBothDelay    = 0.10,   -- seconds to hold both buttons for clickthrough
  }
end
if NearbyTargetsSettings.pinTargetFirst == nil then NearbyTargetsSettings.pinTargetFirst = false end
if NearbyTargetsSettings.holdBothDelay  == nil then NearbyTargetsSettings.holdBothDelay  = 0.10 end

---------------------------------------------------
-- Geometry
---------------------------------------------------
local ROW_W, ROW_H = 520, 20
local BTN_W, BTN_H, BTN_SP = 14, 14, 6
local MAX_ROWS = 12
local UPDATE_INTERVAL = 0.6
local TARGET_INTERVAL = 0.30

---------------------------------------------------
-- Addon state
---------------------------------------------------
local ADDON = {}
ADDON.settings   = NearbyTargetsSettings
ADDON.typeCache  = NearbyTargetsTypeCache
ADDON.filters    = NearbyTargetsFilters

ADDON.rows       = {}
ADDON.topRow     = nil
local main, nameEdit, msgEdit = nil, nil, nil

-- global mouse state for clickthrough
ADDON._ldown, ADDON._rdown = false, false
ADDON._heldRow = nil

-- targeter lock
ADDON._t_lastTick   = 0
ADDON.t_locked      = false
ADDON.t_lockedName  = nil

-- dual-scope parsed results
ADDON.parsedList    = { terms={}, below=nil, above=nil, lvlOp=nil, lvlVal=nil }
ADDON.parsedTScopes = {}   -- array of { tokens={}, below, above, lvlOp, lvlVal }

-- visible players in list (for [whisper])
ADDON.visiblePlayers = {}

---------------------------------------------------
-- Utils
---------------------------------------------------
local function floor_div(n,d) return math.floor(n/d) end
local function mod_no_pct(n,d) return n - d * floor_div(n,d) end
local function Trim(s)
  if not s then return "" end
  s = string.gsub(s, "^[%s%z]+", "")
  s = string.gsub(s, "[%s%z]+$", "")
  return s
end
local function lc(s) return string.lower(s or "") end
-- Lua 5.0 safe string.match replacement
local function strmatch(text, pat)
  local a,b,c,d = string.find(text, pat)
  -- returns captures only
  if c and d then return c,d elseif c then return c end
  return nil
end


---------------------------------------------------
-- Clickthrough (hold both mouse buttons)
---------------------------------------------------
local function EnableRowMouse(row)
  if not row or not row.colorButtons then return end
  if row._mouseOff then
    local i=1
    while row.colorButtons[i] do row.colorButtons[i]:EnableMouse(true); i=i+1 end
    if row.nameBtn and row.nameBtn.EnableMouse then row.nameBtn:EnableMouse(true) end
    row._mouseOff = nil
  end
end
local function DisableRowMouse(row)
  if not row or not row.colorButtons then return end
  if not row._mouseOff then
    local i=1
    while row.colorButtons[i] do row.colorButtons[i]:EnableMouse(false); i=i+1 end
    if row.nameBtn and row.nameBtn.EnableMouse then row.nameBtn:EnableMouse(false) end
    row._mouseOff = true
  end
end
local function ReArmAllRows()
  if ADDON.topRow then EnableRowMouse(ADDON.topRow) end
  local i=1
  while ADDON.rows[i] do EnableRowMouse(ADDON.rows[i]); i=i+1 end
  ADDON._heldRow = nil
end

-- hook WorldFrame mouse to track both buttons
do
  local prevDown = WorldFrame:GetScript("OnMouseDown")
  WorldFrame:SetScript("OnMouseDown", function()
    if prevDown then prevDown() end
    if arg1 == "LeftButton"  then ADDON._ldown = true  end
    if arg1 == "RightButton" then ADDON._rdown = true  end
  end)
  local prevUp = WorldFrame:GetScript("OnMouseUp")
  WorldFrame:SetScript("OnMouseUp", function()
    if prevUp then prevUp() end
    if arg1 == "LeftButton"  then ADDON._ldown = false end
    if arg1 == "RightButton" then ADDON._rdown = false end
    if not ADDON._ldown and not ADDON._rdown then ReArmAllRows() end
  end)
end

---------------------------------------------------
-- Parsing (dual scope + chat)
---------------------------------------------------
local function _split_tokens(s)
  local out = {}
  if not s then return out end
  local i,n = 1,string.len(s)
  while i<=n do
    local c1 = string.find(s,",",i,true)
    local c2 = string.find(s,"|",i,true)
    local p = c1 and c2 and (c1<c2 and c1 or c2) or (c1 or c2)
    local piece = Trim(p and string.sub(s,i,p-1) or string.sub(s,i))
    if piece~="" then table.insert(out, lc(piece)) end
    if not p then break end
    i = p + 1
  end
  return out
end
local function _parse_lvl(v)
  v = Trim(v or ""); if v=="" then return nil,nil end
  local op = string.sub(v,1,1)
  if op=="<" or op==">" or op=="=" then
    local num = tonumber(Trim(string.sub(v,2)))
    if num then return op,num end
  else
    local num = tonumber(v); if num then return "=",num end
  end
  return nil,nil
end
-- put this near your other locals, above ParseNameBoxScopes
local CHAT_TAGS = {
  say=true, party=true, raid=true, rw=true, raidwarning=true, whisper=true
}
-- Dual-scope parser:
--  • plain words -> active scope (list until a [t:] starts; then that t-scope until next [t:] or end)
--  • [below]/[above]/[lvl] attach to the current active scope
local function ParseNameBoxScopes(txt)
  local listScope = { terms={}, below=nil, above=nil, lvlOp=nil, lvlVal=nil }
  local tScopes   = {}
  local activeT   = nil
  if not txt or txt=="" then return listScope, tScopes end

  local i,n = 1,string.len(txt)
  while i<=n do
    local lb = string.find(txt,"[",i,true)
    if not lb then
      local plain = Trim(string.sub(txt,i))
      if plain~="" then
        if activeT then table.insert(activeT.tokens, lc(plain))
        else table.insert(listScope.terms, lc(plain)) end
      end
      break
    end
    if lb>i then
      local plain = Trim(string.sub(txt,i,lb-1))
      if plain~="" then
        if activeT then table.insert(activeT.tokens, lc(plain))
        else table.insert(listScope.terms, lc(plain)) end
      end
    end
    local rb = string.find(txt,"]",lb+1,true); if not rb then break end
    local tag = Trim(string.sub(txt,lb+1,rb-1))
    local key,val = strmatch(tag,"([^:]+):?(.*)")
    key = lc(Trim(key or "")); val = Trim(val or "")

    if key=="t" then
      activeT = { tokens={}, below=nil, above=nil, lvlOp=nil, lvlVal=nil }
      if val~="" then
        local toks = _split_tokens(val)
        local k=1 while toks[k] do table.insert(activeT.tokens, toks[k]); k=k+1 end
      end
      table.insert(tScopes, activeT)
    elseif key=="below" or key=="above" or key=="lvl" or key=="level" then
      local tgt = activeT or listScope
      if key=="below" then
        local num = tonumber((string.gsub(val,"%%",""))); if num then tgt.below = num end
      elseif key=="above" then
        local num = tonumber((string.gsub(val,"%%",""))); if num then tgt.above = num end
      else
        local op,num = _parse_lvl(val); if op and num then tgt.lvlOp,tgt.lvlVal = op,num end
      end
    elseif CHAT_TAGS[key] then
      -- it's a chat directive; ignore here (chat is handled by ParseChatDirectives)
      -- do nothing so it doesn't affect list/target scopes
    else
      -- treat truly unknown bracket words as plain term in current scope
      if activeT then table.insert(activeT.tokens, key)
      else table.insert(listScope.terms, key) end

    end
    i = rb + 1
  end
  return listScope, tScopes
end

local function UpdateTargeterParse()
  local txt = (nameEdit and nameEdit:GetText()) or ""
  local ls, ts = ParseNameBoxScopes(txt)
  ADDON.parsedList    = ls
  ADDON.parsedTScopes = ts
end

-- Chat directives
local function ParseChatDirectives(txt)
  if not txt or txt=="" then return {} end
  local out = {}
  local i,n=1,string.len(txt)
  while i<=n do
    local lb=string.find(txt,"[",i,true); if not lb then break end
    local rb=string.find(txt,"]",lb+1,true); if not rb then break end
    local tag=Trim(string.sub(txt,lb+1,rb-1))
    local key,val= strmatch(tag,"([^:]+):?(.*)")
    key=lc(Trim(key or "")); val=Trim(val or "")
    if key=="say" then table.insert(out,{mode="SAY"})
    elseif key=="party" then table.insert(out,{mode="PARTY"})
    elseif key=="raid" then table.insert(out,{mode="RAID"})
    elseif key=="rw" or key=="raidwarning" then table.insert(out,{mode="RAID_WARNING"})
    elseif key=="whisper" then
      local targets=nil
      if val~="" then
        targets={}
        for w in string.gfind(val,"[^:]+") do table.insert(targets, Trim(w)) end
      end
      table.insert(out,{mode="WHISPER", targets=targets})
    end
    i = rb + 1
  end
  return out
end

local function SendChatByDirectives(msg)
  msg = Trim(msg or ""); if msg=="" then return end
  local dirs = ParseChatDirectives((nameEdit and nameEdit:GetText()) or "")
  if not dirs or table.getn(dirs)==0 then SendChatMessage(msg,"SAY"); return end

  local idx=1
  while dirs[idx] do
    local d = dirs[idx]
    if d.mode=="WHISPER" then
      if not d.targets then
        local sent = {}
        local j=1; while ADDON.visiblePlayers[j] do
        local nm = ADDON.visiblePlayers[j]
        if nm and not sent[nm] then sent[nm]=true; SendChatMessage(msg,"WHISPER",nil,nm) end
        j=j+1
      end
      else
        local k=1; while d.targets[k] do
        SendChatMessage(msg,"WHISPER",nil,d.targets[k]); k=k+1
      end
      end
    else
      SendChatMessage(msg, d.mode)
    end
    idx = idx + 1
  end
end

---------------------------------------------------
-- Filters / Comparators
---------------------------------------------------
local function NumericFiltersPass_HP(hp,mx,below,above,comparePercent)
  local val
  if comparePercent then
    local m = (mx and mx>0) and mx or 1
    val = (hp or 0) * 100 / m
  else
    val = hp or 0
  end
  if below and not (val < below) then return false end
  if above and not (val > above) then return false end
  return true
end

local function LevelFilterPass(level, op, val)
  if not op or not val then return true end
  local L = tonumber(level or 0) or 0
  if op=="<" then return L <  val end
  if op==">" then return L >  val end
  if op=="=" then return L == val end
  return true
end

local function NameHasAnyToken(nm, tokens)
  if not tokens or table.getn(tokens)==0 then return true end
  local h = lc(nm or "")
  local i=1
  while tokens[i] do
    if string.find(h, tokens[i], 1, true) then return true end
    i=i+1
  end
  return false
end

local function CompareValue(u)
  local hp = u.hp or 0
  local mx = (u.max and u.max>0) and u.max or 1
  if ADDON.settings.comparePercent then return hp/mx else return hp end
end

local function IsALowerThanB(a,b)
  local va,vb = CompareValue(a), CompareValue(b)
  if ADDON.settings.comparePercent then
    local diff = va - vb
    if diff < -0.0001 then return true end
    if diff >  0.0001 then return false end
  else
    if va < vb then return true end
    if va > vb then return false end
  end
  local an,bn = a.realName or "", b.realName or ""
  if an ~= bn then return an < bn end
  return false
end

---------------------------------------------------
-- Type cache (unit learning)
---------------------------------------------------
local function TypeFromUnitToken(u)
  if not UnitExists(u) then return nil end
  if UnitIsPlayer(u) then return "Player" end
  if UnitPlayerControlled(u) and not UnitIsPlayer(u) then return "Pet" end
  return UnitCreatureType(u) or "Unknown"
end
local function UpdateTypeCacheFromUnit(u)
  if not UnitExists(u) then return end
  local n = UnitName(u); if not n or n=="" then return end
  ADDON.typeCache[n] = TypeFromUnitToken(u) or "Unknown"
end

---------------------------------------------------
-- Nameplate scan (Vanilla)
---------------------------------------------------
local function IsCritterFrame(f)
  if not f or not f.GetChildren then return false end
  local _,c
  for _,c in ipairs({ f:GetChildren() }) do
    if c and c.GetObjectType and c:GetObjectType()=="StatusBar" then
      local _,m = c:GetMinMaxValues()
      if m and m<=10 then return true end
    end
  end
  return false
end
local function IsValidName(s)
  if not s or s=="" then return false end
  if string.find(s,"Corpse") then return false end
  if string.find(s,"^%s*[0-9]+$") then return false end
  if string.find(s,"^Level") then return false end
  return true
end

local function ScanNameplates()
  if not WorldFrame or not WorldFrame.GetChildren then return {} end
  local ok, frames = pcall(function() return { WorldFrame:GetChildren() } end)
  if not ok or not frames then return {} end

  local list, idx, seen = {}, 0, {}
  local _, f
  for _, f in ipairs(frames) do
    if f and f.IsShown and f:IsShown() and f.GetRegions and not IsCritterFrame(f) then
      local hpBar, nameFS
      local __, r
      for __, r in ipairs({ f:GetRegions() }) do
        if r and r.GetObjectType and r:GetObjectType()=="FontString" then
          local t = r:GetText()
          if IsValidName(t) then nameFS = r; break end
        end
      end
      local ___, c
      for ___, c in ipairs({ f:GetChildren() }) do
        if c and c.GetObjectType and c:GetObjectType()=="StatusBar" then hpBar = c; break end
      end
      if nameFS and hpBar and hpBar.GetValue then
        local n = nameFS:GetText()
        if n and n~="" and not seen[n] then
          seen[n] = true
          local hp  = hpBar:GetValue() or 0
          local _,mx = hpBar:GetMinMaxValues()
          local ut
          if mx and mx<=10 then ut="Critter" else ut=ADDON.typeCache[n] or "Unknown" end
          if ut~="Critter" then
            idx = idx + 1
            list[idx] = { realName=n, hp=hp, max=mx or 1, utype=ut, gray=false }
          end
        end
      end
    end
  end
  return list
end

---------------------------------------------------
-- UI (current look)
---------------------------------------------------
local function SafeSetBackdrop(f)
  if f and f.SetBackdrop then
    f:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    if f.SetBackdropColor then f:SetBackdropColor(0,0,0,0.85) end
  end
end

local COLORS = {
  {1,0.2,0.2},{1,0.7,0.2},{1,1,0.2},
  {0.3,1,0.3},{0.3,0.6,1},{0.7,0.3,1},{1,1,1}
}

local HOLD_BOTH_THRESHOLD = NearbyTargetsSettings.holdBothDelay or 0.10

local function TargetNearestSameName(n)
  if not n or n=="" then return false end
  if UnitExists("target") then
    local ct = UnitCreatureType("target")
    if UnitIsDead("target") or ct=="Critter" or ct=="Non-combat Pet" then
      ClearTarget()
    elseif UnitName("target")==n then
      return true
    end
  end
  ClearTarget()
  local i=1; while i<=15 do
    TargetNearestEnemy()
    if UnitExists("target") and not UnitIsDead("target") and UnitName("target")==n then
      return true
    end
    i=i+1
  end
  ClearTarget()
  return false
end

local function CreateRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetWidth(ROW_W); row:SetHeight(ROW_H)
  row.colorButtons = {}
  row._mouseOff, row._bothDownAt = nil, nil

  local j=1
  while j<=7 do
    local btn = CreateFrame("Button", nil, row)
    btn:SetWidth(BTN_W); btn:SetHeight(BTN_H)
    if j==1 then btn:SetPoint("LEFT", row, "LEFT", 0, 0)
    else btn:SetPoint("LEFT", row.colorButtons[j-1], "RIGHT", BTN_SP, 0) end

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    tex:SetVertexColor(COLORS[j][1], COLORS[j][2], COLORS[j][3], 1)
    btn.bg = tex

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    btn:RegisterForClicks("LeftButtonUp","RightButtonUp")
    btn.leftIsDown, btn.rightIsDown = false, false

    btn:SetScript("OnMouseDown", function()
      if arg1=="LeftButton"  then btn.leftIsDown=true;  ADDON._ldown=true  end
      if arg1=="RightButton" then btn.rightIsDown=true; ADDON._rdown=true  end
      if (ADDON._ldown or btn.leftIsDown) and (ADDON._rdown or btn.rightIsDown) then
        row._bothDownAt = GetTime()
      else
        row._bothDownAt = nil
      end
    end)
    btn:SetScript("OnUpdate", function()
      if row._mouseOff then return end
      local bothHeld = (ADDON._ldown or btn.leftIsDown) and (ADDON._rdown or btn.rightIsDown)
      if bothHeld then
        if not row._bothDownAt then row._bothDownAt = GetTime() end
        if GetTime() - row._bothDownAt > HOLD_BOTH_THRESHOLD then
          DisableRowMouse(row)
          ADDON._heldRow = row
        end
      else
        row._bothDownAt = nil
      end
    end)
    btn:SetScript("OnMouseUp", function()
      if arg1=="LeftButton"  then btn.leftIsDown=false;  ADDON._ldown=false end
      if arg1=="RightButton" then btn.rightIsDown=false; ADDON._rdown=false end
      if not ADDON._ldown and not ADDON._rdown then ReArmAllRows() end
    end)

    local idx = j
    btn:SetScript("OnClick", function(_, mb)
      if row._mouseOff then return end
      if not row.realName or row.realName=="" then return end
      local had = UnitExists("target"); local prev = had and UnitName("target") or nil
      if not TargetNearestSameName(row.realName) then return end

      if     idx==1 and type(Button1)=="function" then Button1()
      elseif idx==2 and type(Button2)=="function" then Button2()
      elseif idx==3 and type(Button3)=="function" then Button3()
      elseif idx==4 and type(Button4)=="function" then Button4()
      elseif idx==5 and type(Button5)=="function" then Button5()
      elseif idx==6 and type(Button6)=="function" then Button6()
      elseif idx==7 and type(Button7)=="function" then Button7() end

      if ((mb=="RightButton") or IsAltKeyDown()) and had and prev and prev~=row.realName then
        TargetLastTarget()
        if UnitName("target") ~= prev then TargetByName(prev, true) end
      end
    end)

    row.colorButtons[j] = btn
    j=j+1
  end

  row.bg = row:CreateTexture(nil, "BORDER")
  row.bg:SetPoint("LEFT", row.colorButtons[7], "RIGHT", 10, 0)
  row.bg:SetWidth(180); row.bg:SetHeight(18)
  row.bg:SetTexture(0.1,0.1,0.1,0.9)

  row.healthBar = row:CreateTexture(nil, "ARTWORK")
  row.healthBar:SetPoint("LEFT", row.bg, "LEFT", 0, 0)
  row.healthBar:SetHeight(18)
  row.healthBar:SetWidth(180)
  row.healthBar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
  row.healthBar:SetVertexColor(0, 0.8, 0)

  row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.nameText:SetPoint("LEFT", row.colorButtons[7], "RIGHT", 10, 0)
  row.nameText:SetWidth(145)

  row.typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.typeText:SetPoint("LEFT", row.nameText, "RIGHT", 10, 0)
  row.typeText:SetWidth(90)

  row.hpText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.hpText:SetPoint("LEFT", row.bg, "RIGHT", 12, 0)
  row.hpText:SetWidth(100)

  return row
end

-- main frame
main = CreateFrame("Frame", "NearbyTargetsFrame", UIParent)
main:SetWidth(520)
main:SetHeight(82 + MAX_ROWS*24)
main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
main:SetMovable(true)
main:EnableMouse(false)
SafeSetBackdrop(main)

-- drag bar
local drag = CreateFrame("Frame", nil, main)
drag:SetPoint("TOPLEFT", main, "TOPLEFT", 0, 0)
drag:SetPoint("TOPRIGHT", main, "TOPRIGHT", 0, 0)
drag:SetHeight(24)
drag:EnableMouse(true)
drag:RegisterForDrag("LeftButton")
drag:SetScript("OnDragStart", function() main:StartMoving() end)
drag:SetScript("OnDragStop",  function() main:StopMovingOrSizing() end)
SafeSetBackdrop(drag)

local title = drag:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", drag, "LEFT", 8, 0)
title:SetJustifyH("LEFT")
title:SetText("Nearby Targets")

-- header buttons
local filterBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
filterBtn:SetWidth(60); filterBtn:SetHeight(18)
filterBtn:SetPoint("LEFT", title, "RIGHT", 12, 0)
filterBtn:SetText("Filter")

local modeBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
modeBtn:SetWidth(110); modeBtn:SetHeight(18)
modeBtn:SetPoint("LEFT", filterBtn, "RIGHT", 10, 0)

local compareBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
compareBtn:SetWidth(90); compareBtn:SetHeight(18)
compareBtn:SetPoint("LEFT", modeBtn, "RIGHT", 10, 0)

local function ModeLabel() return ADDON.settings.pinTargetFirst and "Mode: Target→Top" or "Mode: Lowest→Top" end
local function CompareLabel() return ADDON.settings.comparePercent and "Compare [%]" or "Compare [HP]" end
local function ToggleMode()
  ADDON.settings.pinTargetFirst = not ADDON.settings.pinTargetFirst
  NearbyTargetsSettings.pinTargetFirst = ADDON.settings.pinTargetFirst
  modeBtn:SetText(ModeLabel())
end
local function ToggleCompare()
  ADDON.settings.comparePercent = not ADDON.settings.comparePercent
  NearbyTargetsSettings.comparePercent = ADDON.settings.comparePercent
  compareBtn:SetText(CompareLabel())
end
modeBtn:SetText(ModeLabel()); compareBtn:SetText(CompareLabel())
modeBtn:SetScript("OnClick", ToggleMode)
compareBtn:SetScript("OnClick", ToggleCompare)

-- filter panel (types)
local filterFrame = CreateFrame("Frame", "NearbyTargetsFilterFrame", main)
filterFrame:SetPoint("BOTTOMLEFT", drag, "TOPLEFT", 0, 4)
filterFrame:SetWidth(470); filterFrame:SetHeight(70)
filterFrame:SetScale(0.9)
filterFrame:SetFrameStrata("DIALOG")
filterFrame:SetFrameLevel(main:GetFrameLevel() + 10)
SafeSetBackdrop(filterFrame)
filterFrame:Hide()

local types = { "Beast","Elemental","Humanoid","Undead","Demon","Dragonkin","Mechanical","Player","Pet","Unknown" }
do
  local i=1 while types[i] do
  if ADDON.filters[types[i]] == nil then ADDON.filters[types[i]] = (types[i]~="Critter") end
  i=i+1
end
end
local cols, spacingX, spacingY = 5, 88, 26
local iT=1 while iT<=table.getn(types) do
  local t = types[iT]
  local cb = CreateFrame("CheckButton", nil, filterFrame, "UICheckButtonTemplate")
  local idx = iT-1
  local col = mod_no_pct(idx, cols)
  local row = floor_div(idx, cols)
  cb:SetScale(0.9)
  cb:SetPoint("TOPLEFT", filterFrame, "TOPLEFT", 16 + col*spacingX, -14 - row*spacingY)
  cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  cb.text:SetPoint("LEFT", cb, "RIGHT", -10, 0)
  cb.text:SetText(t)
  cb:SetChecked(ADDON.filters[t])
  cb:SetScript("OnClick", (function(typeName, ref)
    return function() ADDON.filters[typeName] = ref:GetChecked() and true or false end
  end)(t, cb))
  iT=iT+1
end
filterFrame:SetScript("OnShow", function()
  local c=1
  while c<=filterFrame:GetNumChildren() do
    local ch = select(c, filterFrame:GetChildren())
    if ch and ch.text and ch.text.GetText then
      local key = ch.text:GetText()
      if key and ADDON.filters[key] ~= nil then ch:SetChecked(ADDON.filters[key] and true or false) end
    end
    c=c+1
  end
end)
filterBtn:SetScript("OnClick", function()
  if filterFrame:IsShown() then filterFrame:Hide() else filterFrame:Show() end
end)

-- bottom bar
local bottom = CreateFrame("Frame", nil, main)
bottom:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", 0, 0)
bottom:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", 0, 0)
bottom:SetHeight(26)
SafeSetBackdrop(bottom)

local nameLblFS = bottom:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
nameLblFS:SetText("Filters:")
nameLblFS:SetPoint("LEFT", bottom, "LEFT", 8, 0)

nameEdit = CreateFrame("EditBox", "NearbyTargetsNameFilter", bottom, "InputBoxTemplate")
nameEdit:SetAutoFocus(false)
nameEdit:SetWidth(280); nameEdit:SetHeight(18); nameEdit:SetMaxLetters(255)
nameEdit:SetPoint("LEFT", nameLblFS, "RIGHT", 4, 0)
nameEdit:SetText("")
if nameEdit.SetAltArrowKeyMode then nameEdit:SetAltArrowKeyMode(true) end
-- proper enter handling for Vanilla 1.12
nameEdit:SetScript("OnTextChanged", function()
  UpdateTargeterParse()
end)
nameEdit:SetScript("OnEnterPressed", function()
  UpdateTargeterParse()
  this:ClearFocus()
  PlaySound("igMainMenuOptionCheckBoxOn") -- small feedback click
end)
nameEdit:SetScript("OnEscapePressed", function()
  this:ClearFocus()
end)
nameEdit:SetScript("OnTabPressed", function()
  this:ClearFocus()
end)

local msgLbl = bottom:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
msgLbl:SetText("Message:")
msgLbl:SetPoint("LEFT", nameEdit, "RIGHT", 10, 0)

msgEdit = CreateFrame("EditBox", "NearbyTargetsMsgBox", bottom, "InputBoxTemplate")
msgEdit:SetAutoFocus(false)
msgEdit:SetWidth(100); msgEdit:SetHeight(18); msgEdit:SetMaxLetters(255)
msgEdit:SetPoint("LEFT", msgLbl, "RIGHT", 4, 0)
msgEdit:SetText("")
if msgEdit.SetAltArrowKeyMode then msgEdit:SetAltArrowKeyMode(true) end

local sendBtn = CreateFrame("Button", nil, bottom, "UIPanelButtonTemplate")
sendBtn:SetWidth(44); sendBtn:SetHeight(18)
sendBtn:SetPoint("LEFT", msgEdit, "RIGHT", 0, 0)
sendBtn:SetText("Send")
sendBtn:SetScript("OnClick", function()
  local txt = (msgEdit and msgEdit:GetText()) or ""
  if txt~="" then SendChatByDirectives(txt) end
  if msgEdit then msgEdit:ClearFocus() end
end)
msgEdit:SetScript("OnEnterPressed", function()
  local txt = (msgEdit and msgEdit:GetText()) or ""
  if txt~="" then SendChatByDirectives(txt) end
  msgEdit:ClearFocus()
end)
msgEdit:SetScript("OnEscapePressed", function() this:ClearFocus() end)

-- rows
ADDON.topRow = CreateRow(main)
ADDON.topRow:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -30)
local ri=1
while ri<=MAX_ROWS do
  local row = CreateRow(main)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -58 - (ri-1)*24)
  ADDON.rows[ri] = row
  ri=ri+1
end

---------------------------------------------------
-- Draw helper
---------------------------------------------------
local function DrawRow(row, d)
  if not row then return end
  if d then
    local hp = d.hp or 0
    local mx = d.max or 1
    if mx<=0 then mx=1 end
    local pct = hp/mx
    if pct<0 then pct=0 elseif pct>1 then pct=1 end

    if d.gray then
      row.healthBar:SetVertexColor(0.4,0.4,0.4)
      row.nameText:SetTextColor(0.7,0.7,0.7)
      row.hpText:SetTextColor(0.7,0.7,0.7)
    else
      row.healthBar:SetVertexColor(1-pct, pct, 0)
      row.nameText:SetTextColor(1,1,1)
      row.hpText:SetTextColor(1,1,1)
    end
    row.healthBar:SetWidth(180 * pct)
    row.nameText:SetText(d.realName or "?")
    row.typeText:SetText("["..(d.utype or "?").."]")
    if ADDON.settings.comparePercent then
      local p = math.floor(pct*100 + 0.5)
      row.hpText:SetText(p.."%")
    else
      row.hpText:SetText((d.hp or 0).." / "..(d.max or 1))
    end

    row.realName = d.realName
    row:Show()
  else
    row.realName = nil
    row:Hide()
  end
end

---------------------------------------------------
-- Events (learn types)
---------------------------------------------------
local evt = CreateFrame("Frame")
evt:RegisterEvent("PLAYER_TARGET_CHANGED")
evt:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
evt:RegisterEvent("UNIT_TARGET")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:SetScript("OnEvent", function()
  if event=="PLAYER_TARGET_CHANGED" and UnitExists("target") then
    UpdateTypeCacheFromUnit("target")
  elseif event=="UPDATE_MOUSEOVER_UNIT" and UnitExists("mouseover") then
    UpdateTypeCacheFromUnit("mouseover")
  elseif event=="UNIT_TARGET" and arg1=="pet" and UnitExists("pettarget") then
    UpdateTypeCacheFromUnit("pettarget")
  elseif event=="PLAYER_ENTERING_WORLD" then
    if UnitExists("target") then UpdateTypeCacheFromUnit("target") end
    if UnitExists("pettarget") then UpdateTypeCacheFromUnit("pettarget") end
  end
end)

---------------------------------------------------
-- Main loop
---------------------------------------------------
main.lastUpdate = 0
main:SetScript("OnUpdate", function()
  local now = GetTime()

  -- Multi-[t:] targeter (scoped)
  if ADDON.parsedTScopes and table.getn(ADDON.parsedTScopes)>0 then
    if ADDON.t_locked then
      local alive = UnitExists("target") and not UnitIsDead("target")
      local same  = alive and (UnitName("target")==ADDON.t_lockedName)
      if not alive or not same then
        ADDON.t_locked, ADDON.t_lockedName = false, nil
        ClearTarget()
      end
    end
    if (not ADDON.t_locked) and (now - ADDON._t_lastTick > TARGET_INTERVAL) then
      ADDON._t_lastTick = now
      local s=1
      while ADDON.parsedTScopes[s] do
        local sc = ADDON.parsedTScopes[s]
        local j=1
        while sc.tokens[j] do
          local tok = sc.tokens[j]
          TargetByName(tok, false)
          if UnitExists("target") and not UnitIsDead("target") then
            local nm = UnitName("target") or ""
            if string.find(lc(nm), tok, 1, true) then
              local hp = UnitHealth("target") or 0
              local mx = UnitHealthMax("target") or 1
              local lvl= UnitLevel("target") or 0
              if NumericFiltersPass_HP(hp,mx, sc.below,sc.above, ADDON.settings.comparePercent)
                      and LevelFilterPass(lvl, sc.lvlOp, sc.lvlVal)
              then
                ADDON.t_locked=true; ADDON.t_lockedName=nm; break
              else
                ClearTarget()
              end
            else
              ClearTarget()
            end
          end
          j=j+1
        end
        if ADDON.t_locked then break end
        s=s+1
      end
    end
  end

  -- UI cadence
  if now - main.lastUpdate < UPDATE_INTERVAL then return end
  main.lastUpdate = now

  if not ADDON._ldown and not ADDON._rdown and ADDON._heldRow then ReArmAllRows() end

  -- Build list: listScope terms/filters only (t-scope is independent)
  local scanned = ScanNameplates()
  local list, L = {}, 0
  local cur = UnitName("target")
  local targetSeen = false

  local i=1
  while scanned[i] do
    local u = scanned[i]
    local type_ok = ADDON.filters[u.utype] or (u.utype=="Unknown" and ADDON.filters["Unknown"]) or (u.utype=="Pet" and ADDON.filters["Pet"])
    local hp_ok   = NumericFiltersPass_HP(u.hp, u.max, ADDON.parsedList.below, ADDON.parsedList.above, ADDON.settings.comparePercent)
    local lvl_ok  = LevelFilterPass(u.level, ADDON.parsedList.lvlOp, ADDON.parsedList.lvlVal)  -- u.level may be nil; LevelFilterPass handles it
    local name_ok = NameHasAnyToken(u.realName, ADDON.parsedList.terms)
    if type_ok and hp_ok and lvl_ok and name_ok then
      L=L+1; list[L]=u
      if cur and u.realName==cur then targetSeen=true end
    end
    i=i+1
  end

  -- visible players for [whisper]
  ADDON.visiblePlayers = {}
  local vp=1; local k=1
  while list[k] do
    if list[k].utype=="Player" then ADDON.visiblePlayers[vp]=list[k].realName; vp=vp+1 end
    k=k+1
  end

  local lowest = nil
  local li=1
  while list[li] do
    if (not lowest) or IsALowerThanB(list[li], lowest) then lowest = list[li] end
    li=li+1
  end

  local stickyEntry = nil
  if UnitExists("target") then
    stickyEntry = {
      realName = cur,
      hp   = UnitHealth("target") or 0,
      max  = UnitHealthMax("target") or 1,
      utype= (UnitIsPlayer("target") and "Player") or (UnitPlayerControlled("target") and not UnitIsPlayer("target") and "Pet") or (UnitCreatureType("target") or "Unknown"),
      gray = not targetSeen
    }
    if not targetSeen then
      table.insert(list, 1, stickyEntry); L=L+1
    end
  end

  local topData
  if ADDON.settings.pinTargetFirst then
    topData = stickyEntry or lowest
  else
    if lowest then
      if stickyEntry and lowest.realName==(stickyEntry.realName or "") then topData=stickyEntry else topData=lowest end
    else
      topData = stickyEntry
    end
  end

  DrawRow(ADDON.topRow, topData)
  local ri2=1
  while ri2<=MAX_ROWS do
    DrawRow(ADDON.rows[ri2], list[ri2])
    ri2=ri2+1
  end

  if UnitExists("mouseover") then UpdateTypeCacheFromUnit("mouseover") end
end)

---------------------------------------------------
-- Slash
---------------------------------------------------
SLASH_NEARBYTARGETS1 = "/nt"
SlashCmdList["NEARBYTARGETS"] = function()
  if NearbyTargetsFrame:IsShown() then NearbyTargetsFrame:Hide() else NearbyTargetsFrame:Show() end
end

SLASH_NEARBYTARGETSMODE1 = "/ntmode"
SlashCmdList["NEARBYTARGETSMODE"] = function()
  ADDON.settings.pinTargetFirst = not ADDON.settings.pinTargetFirst
  NearbyTargetsSettings.pinTargetFirst = ADDON.settings.pinTargetFirst
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Top row mode: "..(ADDON.settings.pinTargetFirst and "Target→Top" or "Lowest→Top")..".|r")
end

-- Init
UpdateTargeterParse()
NearbyTargetsFrame:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NearbyTargets loaded.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Filters: words + [t:name1,name2|name3] + [below:N] [above:N] [lvl:<|>|=N].|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Scoping: everything after a [t:] applies to that t: only. List words remain list-only.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Chat: [say] [party] [raid] [rw] [whisper] [whisper:Name:Name2]. Whisper (no names) -> all visible players.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Hold both mouse buttons ~"..(NearbyTargetsSettings.holdBothDelay or 0.10).."s on a row to click-through.|r")
