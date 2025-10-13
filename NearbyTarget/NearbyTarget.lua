-- NearbyTargets (Vanilla 1.12)
-- Split-top-bar: dedicated Top row (Target/Lowest) + independent list below
-- Filters + sticky targets + stable lowest tie-break (by UID)
-- Mode button toggles: Top = Target (if exists; fallback Lowest)  <->  Top = Lowest (current behavior)
-- Clickthrough-on-hold (camera/move) using BOTH buttons, row-scoped, 1.12-safe

---------------------------------------------------
-- SavedVariables
---------------------------------------------------
if not NearbyTargetsTypeCache then NearbyTargetsTypeCache = {} end
if not NearbyTargetsSlotOrder then NearbyTargetsSlotOrder = {} end
if not NearbyTargetsFilters   then NearbyTargetsFilters   = {} end
if not NearbyTargetsSettings  then
  NearbyTargetsSettings = {
    comparePercent   = true,
    stickyPetTarget  = true,
    pinTargetFirst   = false, -- NEW: Mode toggle (true = Top row shows current target when available)
  }
end
if NearbyTargetsSettings.pinTargetFirst == nil then NearbyTargetsSettings.pinTargetFirst = false end

---------------------------------------------------
-- Addon state
---------------------------------------------------
local ADDON = {}
ADDON.settings       = NearbyTargetsSettings
local UPDATE_INTERVAL = 0.6
local MAX_ROWS        = 12

ADDON.rows          = {}
ADDON.topRow        = nil
ADDON.typeCache     = NearbyTargetsTypeCache
ADDON.filters       = NearbyTargetsFilters

-- Global mouse-state (Vanilla-safe)
ADDON._ldown, ADDON._rdown = false, false
ADDON._heldRow = nil  -- the row currently in clickthrough mode (if any)

---------------------------------------------------
-- Helpers
---------------------------------------------------
local function IsValidName(t)
  if not t or t == "" then return false end
  if string.find(t, "Corpse") then return false end
  if string.find(t, "^%s*[0-9]+$") then return false end
  if string.find(t, "^Level") then return false end
  return true
end

local function IsCritterUnitFrame(f)
  if not f or not f.GetChildren then return false end
  for _, c in ipairs({ f:GetChildren() }) do
    if c and c.GetObjectType and c:GetObjectType() == "StatusBar" then
      local _, m = c:GetMinMaxValues()
      if m and m <= 10 then return true end
    end
  end
  return false
end

local function TypeFromUnitToken(u)
  if not UnitExists(u) then return nil end
  if UnitIsPlayer(u) then
    return "Player"
  elseif UnitPlayerControlled(u) and not UnitIsPlayer(u) then
    return "Pet"
  else
    return UnitCreatureType(u) or "Unknown"
  end
end

local function UpdateTypeCacheFromUnit(u)
  if not UnitExists(u) then return end
  local n = UnitName(u)
  if not n or n == "" then return end
  ADDON.typeCache[n] = TypeFromUnitToken(u) or "Unknown"
end

local function floor_div(n,d) return math.floor(n/d) end
local function mod_no_pct(n,d) return n - d * floor_div(n,d) end

-- Compare helpers for "lowest" selection (stable with uid tie-break)
local function CompareValue(u)
  local hp = u.hp or 0
  local mx = (u.max and u.max > 0) and u.max or 1
  if ADDON.settings.comparePercent then
    return hp / mx
  else
    return hp
  end
end

local function IsALowerThanB(a, b)
  local va, vb = CompareValue(a), CompareValue(b)
  if ADDON.settings.comparePercent then
    local diff = va - vb
    if diff < -0.0001 then return true end
    if diff >  0.0001 then return false end
  else
    if va < vb then return true end
    if va > vb then return false end
  end
  -- tie: prefer lower uid for stability (falls back to name if needed)
  if a.uid and b.uid then return a.uid < b.uid end
  local an, bn = a.realName or "", b.realName or ""
  if an ~= bn then return an < bn end
  return false
end

---------------------------------------------------
-- UID + scanning nameplates
---------------------------------------------------
local frameToUID = setmetatable({},{ __mode = "k" })
local nextUID = 1
local function GetUIDForFrame(f)
  if not f then return nil end
  if not frameToUID[f] then
    frameToUID[f] = nextUID
    nextUID = nextUID + 1
  end
  return frameToUID[f]
end

local function ScanNameplates()
  if not WorldFrame or not WorldFrame.GetChildren then return {} end
  local ok, frames = pcall(function() return { WorldFrame:GetChildren() } end)
  if not ok or not frames then return {} end
  local newUnits, idx, seen = {}, 0, {}
  for _, f in ipairs(frames) do
    if f and f.IsShown and f:IsShown() and f.GetRegions and not IsCritterUnitFrame(f) then
      local hpBar, nameFS
      for _, r in ipairs({ f:GetRegions() }) do
        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
          local txt = r:GetText()
          if IsValidName(txt) then nameFS = r; break end
        end
      end
      for _, c in ipairs({ f:GetChildren() }) do
        if c and c.GetObjectType and c:GetObjectType() == "StatusBar" then hpBar = c; break end
      end
      if nameFS and hpBar and hpBar.GetValue then
        local n = nameFS:GetText()
        if n and n ~= "" and not seen[n] then
          seen[n] = true
          local uid = GetUIDForFrame(f)
          local hp  = hpBar:GetValue() or 0
          local _, mx = hpBar:GetMinMaxValues()
          local ut
          if mx and mx <= 10 then
            ut = "Critter"
          else
            ut = ADDON.typeCache[n] or "Unknown"
          end
          if ut ~= "Critter" then
            idx = idx + 1
            newUnits[idx] = { uid = uid, realName = n, hp = hp, max = mx or 1, utype = ut, gray = false }
          end
        end
      end
    end
  end
  return newUnits
end

---------------------------------------------------
-- Target selection helper (supports pets; stay on current instance if already targeted)
---------------------------------------------------
local function TargetNearestSameName(n)
  if not n or n == "" then return false end

  -- pets first by exact name
  if UnitName("pet") == n then TargetUnit("pet"); return true end
  for i = 1, GetNumPartyMembers() do
    if UnitName("party"..i.."pet") == n then TargetUnit("party"..i.."pet"); return true end
  end

  if UnitExists("target") then
    local ct = UnitCreatureType("target")
    if UnitIsDead("target") or ct == "Critter" or ct == "Non-combat Pet" then
      ClearTarget()
    elseif UnitName("target") == n then
      -- already on that name: stay (avoid bouncing between same-name instances)
      return true
    end
  end

  ClearTarget()
  for i = 1, 15 do
    TargetNearestEnemy()
    if UnitExists("target") and not UnitIsDead("target") and UnitName("target") == n then
      return true
    end
  end
  ClearTarget()
  return false
end

---------------------------------------------------
-- Backdrop helper
---------------------------------------------------
local function SafeSetBackdrop(f)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    if f.SetBackdropColor then f:SetBackdropColor(0,0,0,0.85) end
  end
end

---------------------------------------------------
-- UI setup
---------------------------------------------------
local main = CreateFrame("Frame", "NearbyTargetsFrame", UIParent)
main:SetWidth(520)
-- +24 drag, +22 top row, + (rows * 24) + padding
main:SetHeight(82 + MAX_ROWS * 24)
main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
main:SetMovable(true)
main:EnableMouse(false) -- clickthrough by default
SafeSetBackdrop(main)

-- Drag bar (hosts title, buttons, and a close X)
local drag = CreateFrame("Frame", nil, main)
drag:SetPoint("TOPLEFT", main, "TOPLEFT", 0, 0)
drag:SetPoint("TOPRIGHT", main, "TOPRIGHT", 0, 0)
drag:SetHeight(24)
drag:EnableMouse(true)
drag:RegisterForDrag("LeftButton")
drag:SetScript("OnDragStart", function() main:StartMoving() end)
drag:SetScript("OnDragStop",  function() main:StopMovingOrSizing() end)
SafeSetBackdrop(drag)

-- Title on the far left
local title = drag:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", drag, "LEFT", 8, 0)
title:SetJustifyH("LEFT")
title:SetText("Nearby Targets")


-- Controls on the drag bar
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

-- Labels + handlers
local function ModeLabel()
  return ADDON.settings.pinTargetFirst and "Mode: Target→Top" or "Mode: Lowest→Top"
end
local function CompareLabel() return ADDON.settings.comparePercent and "Compare [%]" or "Compare [HP]" end
local function ModeChat()
  return ADDON.settings.pinTargetFirst and "Top row shows your current target (fallback to lowest)." or "Top row shows the overall lowest."
end

local function ToggleMode()
  ADDON.settings.pinTargetFirst = not ADDON.settings.pinTargetFirst
  NearbyTargetsSettings.pinTargetFirst = ADDON.settings.pinTargetFirst
  modeBtn:SetText(ModeLabel())
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NearbyTargets:|r "..ModeChat())
end

local function ToggleCompare()
  ADDON.settings.comparePercent = not ADDON.settings.comparePercent
  NearbyTargetsSettings.comparePercent = ADDON.settings.comparePercent
  compareBtn:SetText(CompareLabel())
  local msg = ADDON.settings.comparePercent and "Comparing by %HP" or "Comparing by raw HP"
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NearbyTargets:|r "..msg)
end

modeBtn:SetText(ModeLabel())
compareBtn:SetText(CompareLabel())
modeBtn:SetScript("OnClick", ToggleMode)
compareBtn:SetScript("OnClick", ToggleCompare)


-- Filter frame (anchors ABOVE the drag bar now)
local filterFrame = CreateFrame("Frame", "NearbyTargetsFilterFrame", main)
filterFrame:ClearAllPoints()
filterFrame:SetPoint("BOTTOMLEFT", drag, "TOPLEFT", 0, 4)
filterFrame:SetWidth(470)
filterFrame:SetHeight(70)
filterFrame:SetScale(0.9)
filterFrame:SetFrameStrata("DIALOG")
filterFrame:SetFrameLevel(main:GetFrameLevel() + 10)
SafeSetBackdrop(filterFrame)
filterFrame:Hide()

local types = { "Beast","Elemental","Humanoid","Undead","Demon","Dragonkin","Mechanical","Player","Pet","Unknown" }
local cols, spacingX, spacingY = 5, 88, 26

for _, t in ipairs(types) do if ADDON.filters[t] == nil then ADDON.filters[t] = (t ~= "Critter") end end
for i, t in ipairs(types) do
  local cb = CreateFrame("CheckButton", nil, filterFrame, "UICheckButtonTemplate")
  local idx = i - 1
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
end

filterFrame:SetScript("OnShow", function()
  for i = 1, filterFrame:GetNumChildren() do
    local c = select(i, filterFrame:GetChildren())
    if c and c.text and c.text.GetText then
      local key = c.text:GetText()
      if key and ADDON.filters[key] ~= nil then
        c:SetChecked(ADDON.filters[key] and true or false)
      end
    end
  end
end)

filterBtn:SetScript("OnClick", function()
  if filterFrame:IsShown() then filterFrame:Hide() else filterFrame:Show() end
end)

---------------------------------------------------
-- Row clickthrough helpers (row-scoped)
---------------------------------------------------
local function EnableRowMouse(row)
  if not row then return end
  if row._mouseOff then
    for i = 1, 7 do if row.colorButtons[i] then row.colorButtons[i]:EnableMouse(true) end end
    row._mouseOff = nil
  end
end

local function DisableRowMouse(row)
  if not row then return end
  if not row._mouseOff then
    for i = 1, 7 do if row.colorButtons[i] then row.colorButtons[i]:EnableMouse(false) end end
    row._mouseOff = true
  end
end

local function ReArmAllRows()
  if ADDON.topRow then EnableRowMouse(ADDON.topRow) end
  for i = 1, MAX_ROWS do
    local r = ADDON.rows[i]
    if r then EnableRowMouse(r) end
  end
  ADDON._heldRow = nil
end

---------------------------------------------------
-- Global mouse hooks (guaranteed cleanup)
---------------------------------------------------
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
    if not ADDON._ldown and not ADDON._rdown then
      ReArmAllRows()
    end
  end)
end

---------------------------------------------------
-- Row factory (used for Top row and list rows)
---------------------------------------------------
local COLORS = {
  {1,0.2,0.2},{1,0.7,0.2},{1,1,0.2},
  {0.3,1,0.3},{0.3,0.6,1},{0.7,0.3,1},{1,1,1}
}

local function CreateRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetWidth(500); row:SetHeight(20)
  row.colorButtons = {}
  row._mouseOff = nil
  row._bothDownAt = nil

  row.highlight = row:CreateTexture(nil, "BACKGROUND")
  row.highlight:SetAllPoints()
  row.highlight:SetTexture(0,0,0,0)
  row.highlight:Hide()

  -- 7 color buttons
  for j = 1, 7 do
    local btn = CreateFrame("Button", nil, row)
    btn:SetWidth(18); btn:SetHeight(18)
    if j == 1 then
      btn:SetPoint("LEFT", row, "LEFT", 0, 0)
    else
      btn:SetPoint("LEFT", row.colorButtons[j-1], "RIGHT", 10, 0)
    end

    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    tex:SetVertexColor(COLORS[j][1], COLORS[j][2], COLORS[j][3], 1)
    btn.bg = tex

    btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    btn:RegisterForClicks("LeftButtonUp","RightButtonUp")

    btn.leftIsDown, btn.rightIsDown = false, false

    btn:SetScript("OnMouseDown", function()
      if arg1 == "LeftButton"  then btn.leftIsDown  = true; ADDON._ldown = true  end
      if arg1 == "RightButton" then btn.rightIsDown = true; ADDON._rdown = true  end
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
        if GetTime() - row._bothDownAt > 0.1 then
          DisableRowMouse(row)
          ADDON._heldRow = row
        end
      else
        row._bothDownAt = nil
      end
    end)

    btn:SetScript("OnMouseUp", function()
      if arg1 == "LeftButton"  then btn.leftIsDown  = false; ADDON._ldown = false end
      if arg1 == "RightButton" then btn.rightIsDown = false; ADDON._rdown = false end
      if not ADDON._ldown and not ADDON._rdown then
        ReArmAllRows()
      end
    end)

    btn:SetScript("OnLeave", function()
      btn.leftIsDown, btn.rightIsDown = false, false
    end)

    local idx = j
    btn:SetScript("OnClick", function(_, mb)
      if not row.realName or row.realName == "" then return end
      local restore = (mb == "RightButton") or IsAltKeyDown()
      local had = UnitExists("target")
      local prev = had and UnitName("target") or nil
      local nm = row.realName

      if not TargetNearestSameName(nm) then return end

      if idx == 1 and type(Button1) == "function" then Button1()
      elseif idx == 2 and type(Button2) == "function" then Button2()
      elseif idx == 3 and type(Button3) == "function" then Button3()
      elseif idx == 4 and type(Button4) == "function" then Button4()
      elseif idx == 5 and type(Button5) == "function" then Button5()
      elseif idx == 6 and type(Button6) == "function" then Button6()
      elseif idx == 7 and type(Button7) == "function" then Button7()
      else
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[NearbyTargets]|r Button"..idx.." has no assigned Button function.")
      end

      if restore and had and prev and prev ~= nm then
        TargetLastTarget()
        if UnitName("target") ~= prev then TargetByName(prev, true) end
      end
    end)

    row.colorButtons[j] = btn
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

-- Top row
ADDON.topRow = CreateRow(main)
ADDON.topRow:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -30)

-- List rows (start below the top row)
for i = 1, MAX_ROWS do
  local row = CreateRow(main)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -58 - (i-1)*24)
  ADDON.rows[i] = row
end

---------------------------------------------------
-- Type learning events
---------------------------------------------------
local evt = CreateFrame("Frame")
evt:RegisterEvent("PLAYER_TARGET_CHANGED")
evt:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
evt:RegisterEvent("UNIT_TARGET")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:SetScript("OnEvent", function()
  if event == "PLAYER_TARGET_CHANGED" and UnitExists("target") then
    UpdateTypeCacheFromUnit("target")
  elseif event == "UPDATE_MOUSEOVER_UNIT" and UnitExists("mouseover") then
    UpdateTypeCacheFromUnit("mouseover")
  elseif event == "UNIT_TARGET" and arg1 == "pet" and UnitExists("pettarget") then
    UpdateTypeCacheFromUnit("pettarget")
  elseif event == "PLAYER_ENTERING_WORLD" then
    if UnitExists("target") then UpdateTypeCacheFromUnit("target") end
    if UnitExists("pettarget") then UpdateTypeCacheFromUnit("pettarget") end
  end
end)

---------------------------------------------------
-- Drawing helpers
---------------------------------------------------
local function DrawRow(row, d, isTop)
  if not row then return end
  if d then
    local hp = d.hp or 0
    local mx = d.max or 1
    if mx <= 0 then mx = 1 end
    local pct = (mx > 0) and (hp / mx) or 0
    if d.gray then
      row.healthBar:SetVertexColor(0.4, 0.4, 0.4)
      row.nameText:SetTextColor(0.7, 0.7, 0.7)
      row.hpText:SetTextColor(0.7, 0.7, 0.7)
    else
      row.healthBar:SetVertexColor(1 - pct, pct, 0)
      row.nameText:SetTextColor(1, 1, 1)
      row.hpText:SetTextColor(1, 1, 1)
    end
    row.healthBar:SetWidth(180 * pct)
    row.nameText:SetText(d.realName or "?")
    row.typeText:SetText("["..(d.utype or "?").."]")
    row.hpText:SetText(string.format("%d / %d", hp, mx))
    row.realName = d.realName
    row:Show()
  else
    row.realName = nil
    row:Hide()
  end
end

---------------------------------------------------
-- Main update loop
---------------------------------------------------
main.lastUpdate = 0
main:SetScript("OnUpdate", function()
  if GetTime() - main.lastUpdate < UPDATE_INTERVAL then return end
  main.lastUpdate = GetTime()

  -- Safety net: if for any reason both buttons aren't down anymore, re-arm rows
  if not ADDON._ldown and not ADDON._rdown and ADDON._heldRow then
    ReArmAllRows()
  end

  -- Scan visible units
  local scanned = ScanNameplates()

  -- Build list (independent from Top row)
  local list = {}
  local currentTarget = UnitName("target")
  local targetSeen = false
  for _, u in ipairs(scanned) do
    if ADDON.filters[u.utype] or (u.utype == "Unknown" and ADDON.filters["Unknown"]) or u.utype == "Pet" then
      table.insert(list, u)
      if currentTarget and u.realName == currentTarget then
        targetSeen = true
      end
    end
  end

  -- Compute overall lowest among visible (stable tie-break)
  local lowest = nil
  for _, u in ipairs(list) do
    if not lowest or IsALowerThanB(u, lowest) then lowest = u end
  end

  -- Sticky pet injection at top of list if enabled and unseen
  if ADDON.settings.stickyPetTarget and UnitExists("pettarget") then
    local pn = UnitName("pettarget")
    if pn and pn ~= "" then
      local seenPet = false
      for _, u in ipairs(list) do if u.realName == pn then seenPet = true; break end end
      if not seenPet then
        table.insert(list, 1, {
          uid = "stickypet", realName = pn,
          hp = UnitHealth("pettarget") or 0,
          max = UnitHealthMax("pettarget") or 1,
          utype = UnitCreatureType("pettarget") or "Unknown",
          gray = true
        })
      end
    end
  end

  -- Build sticky entry for player target (always prioritized when matching lowest name)
  local stickyName = nil
  local stickyEntry = nil
  if UnitExists("target") then
    stickyName = currentTarget
    stickyEntry = {
      uid   = "stickytarget",
      realName = stickyName,
      hp    = UnitHealth("target") or 0,
      max   = UnitHealthMax("target") or 1,
      utype = UnitCreatureType("target") or "Unknown",
      gray  = not targetSeen
    }
    -- If not seen in list, also inject a gray entry to the list (keeps list independent)
    if not targetSeen then
      table.insert(list, 1, stickyEntry)
    end
  end

  -- Decide Top row content based on Mode:
  -- Mode: pinTargetFirst = true  -> show target if exists; else fallback to lowest
  -- Mode: pinTargetFirst = false -> show lowest; BUT if lowest name == sticky name, show sticky entry instead (sticky prioritized among same-name instances)
  local topData = nil
  if ADDON.settings.pinTargetFirst then
    if stickyEntry then
      topData = stickyEntry
    else
      topData = lowest
    end
  else
    if lowest then
      if stickyEntry and lowest.realName == stickyEntry.realName then
        topData = stickyEntry
      else
        topData = lowest
      end
    else
      -- no visible lowest; if we at least have a target, show it
      topData = stickyEntry
    end
  end

  -- Draw Top row
  DrawRow(ADDON.topRow, topData, true)

  -- Draw list rows (independent list; do NOT remove the topData from it)
  for i = 1, MAX_ROWS do
    DrawRow(ADDON.rows[i], list[i], false)
  end

  if UnitExists("mouseover") then UpdateTypeCacheFromUnit("mouseover") end
end)

---------------------------------------------------
-- Slash commands
---------------------------------------------------
SLASH_NEARBYTARGETS1 = "/nt"
SlashCmdList["NEARBYTARGETS"] = function()
  if main:IsShown() then main:Hide() else main:Show() end
end

SLASH_NEARBYTARGETSMODE1 = "/ntmode"
SlashCmdList["NEARBYTARGETSMODE"] = function() ToggleMode() end

NearbyTargetsFrame:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NearbyTargets loaded.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Top row mode: "..(ADDON.settings.pinTargetFirst and "Target→Top" or "Lowest→Top")..". Toggle with /ntmode.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Use both mouse buttons for clickthrough (hold ~0.1s).|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Use buttons to toggle compare type.|r")
