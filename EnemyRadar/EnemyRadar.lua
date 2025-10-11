-- NearbyTargets (Vanilla 1.12 / pfUI): stable slot version + health bar

local ADDON = {}
local UPDATE_INTERVAL = 0.6
local MAX_ROWS = 12
ADDON.units, ADDON.rows = {}, {}
ADDON.order = {} -- keeps consistent slot order

---------------------------------------------------
-- Name validation
---------------------------------------------------
local function IsValidName(text)
  if not text or text == "" then return false end
  if string.find(text, "Corpse") then return false end
  if string.find(text, "^%s*[0-9]+$") then return false end
  if string.find(text, "^Level") then return false end
  return true
end

---------------------------------------------------
-- Detect 1HP critter frames
---------------------------------------------------
local function IsCritterUnitFrame(f)
  if not f or not f.GetChildren then return false end
  for _, child in ipairs({ f:GetChildren() }) do
    if child and child.GetObjectType and child:GetObjectType() == "StatusBar" then
      local _, max = child:GetMinMaxValues()
      if max and max <= 8 then return true end
    end
  end
  return false
end

---------------------------------------------------
-- Scan pfUI + WorldFrame nameplates
---------------------------------------------------
local function ScanNameplates()
  local seen, frames = {}, {}
  local pfFrame = _G["pfUICombatScreen"]

  if pfFrame and pfFrame.GetChildren then
    for _, c in ipairs({ pfFrame:GetChildren() }) do table.insert(frames, c) end
  end
  for _, c in ipairs({ WorldFrame:GetChildren() }) do table.insert(frames, c) end

  local newUnits = {}

  for _, f in ipairs(frames) do
    if type(f) == "table" and f.IsShown and f:IsShown() and f.GetRegions and not IsCritterUnitFrame(f) then
      local hpBar, nameFS
      for _, child in ipairs({ f:GetChildren() }) do
        if child and child.GetObjectType and child:GetObjectType() == "StatusBar" then hpBar = child end
      end
      for _, region in ipairs({ f:GetRegions() }) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
          local txt = region:GetText()
          if IsValidName(txt) then nameFS = region break end
        end
      end

      if hpBar and nameFS and hpBar.GetValue then
        local nm, hp, _, max = nameFS:GetText(), hpBar:GetValue(), hpBar:GetMinMaxValues()
        if nm and nm ~= "" and hp > 0 and max > 1 then
          newUnits[nm] = { realName = nm, hp = hp, max = max }

          -- preserve order
          if not ADDON.order[nm] then
            local maxIndex = 0
            for _, idx in pairs(ADDON.order) do
              if idx > maxIndex then maxIndex = idx end
            end
            ADDON.order[nm] = maxIndex + 1
          end
        end
      end
    end
  end

  -- remove missing names
  for nm in pairs(ADDON.order) do
    if not newUnits[nm] then ADDON.order[nm] = nil end
  end

  local sorted = {}
  for nm, idx in pairs(ADDON.order) do
    if newUnits[nm] then sorted[idx] = newUnits[nm] end
  end

  ADDON.units = sorted
end

---------------------------------------------------
-- Target nearest alive same-name enemy
---------------------------------------------------
local function TargetNearestSameName(name)
  if not name or name == "" then return false end

  if UnitExists("target") then
    local creatureType = UnitCreatureType("target")
    if UnitIsDead("target") or creatureType == "Critter" or creatureType == "Non-combat Pet" then
      ClearTarget()
    elseif UnitName("target") == name then
      return true
    end
  end

  ClearTarget()
  for _ = 1, 12 do
    TargetNearestEnemy()
    if UnitExists("target") and not UnitIsDead("target") then
      local tname = UnitName("target")
      local creatureType = UnitCreatureType("target")
      if tname == name and creatureType ~= "Critter" and creatureType ~= "Non-combat Pet" then
        return true
      end
    end
  end
  ClearTarget()
  return false
end

---------------------------------------------------
-- UI
---------------------------------------------------
local function CreateBackdrop(f)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  })
  f:SetBackdropColor(0, 0, 0, 0.85)
end

local main = CreateFrame("Frame", "NearbyTargetsFrame", UIParent)
main:SetWidth(420)
main:SetHeight(55 + MAX_ROWS * 24)
main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", function() this:StartMoving() end)
main:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
CreateBackdrop(main)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -8)
title:SetText("Nearby Targets")

local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -4, -4)

---------------------------------------------------
-- Buttons + Health Bar
---------------------------------------------------
local COLORS = {
  {1, 0.2, 0.2}, {1, 0.7, 0.2}, {1, 1, 0.2},
  {0.3, 1, 0.3}, {0.3, 0.6, 1}, {0.7, 0.3, 1}, {1, 1, 1},
}

for i = 1, MAX_ROWS do
  local row = CreateFrame("Frame", nil, main)
  row:SetWidth(400)
  row:SetHeight(20)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -32 - (i - 1) * 24)
  row.colorButtons = {}

  local buttonSize, spacing = 18, 3
  for j = 1, 7 do
    local btn = CreateFrame("Button", nil, row)
    local buttonIndex = j
    btn:SetWidth(buttonSize)
    btn:SetHeight(buttonSize)
    if buttonIndex == 1 then
      btn:SetPoint("LEFT", row, "LEFT", 0, 0)
    else
      btn:SetPoint("LEFT", row.colorButtons[buttonIndex - 1], "RIGHT", spacing, 0)
    end

    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture(COLORS[buttonIndex][1], COLORS[buttonIndex][2], COLORS[buttonIndex][3])
    btn.bg = tex

    btn:SetScript("OnClick", function()
      local realName = row.realName
      if not realName or not TargetNearestSameName(realName) then return end
      if buttonIndex == 1 then RunMacro("petagrro")
      elseif buttonIndex == 2 then CastSpellByName("Crusader Strike")
      elseif buttonIndex == 3 then CastSpellByName("Hammer of Wrath")
      elseif buttonIndex == 4 then CastSpellByName("Seal of Righteousness")
      elseif buttonIndex == 5 then CastSpellByName("Exorcism")
      elseif buttonIndex == 6 then cast_attack_heals()
      elseif buttonIndex == 7 then RunMacro("range_attack")
      end
    end)
    row.colorButtons[buttonIndex] = btn
  end

  -- Health bar background
  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("LEFT", row.colorButtons[7], "RIGHT", 10, 0)
  bg:SetWidth(160)
  bg:SetHeight(18)
  bg:SetTexture(0.1, 0.1, 0.1, 0.9)
  row.bg = bg

  -- Health bar (red→green)
  local bar = row:CreateTexture(nil, "ARTWORK")
  bar:SetPoint("LEFT", bg, "LEFT", 0, 0)
  bar:SetHeight(18)
  bar:SetWidth(160)
  bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetVertexColor(0, 0.8, 0)
  row.healthBar = bar

  -- Name overlay
  local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nameText:SetPoint("CENTER", bg, "CENTER", 0, 0)
  nameText:SetWidth(160)
  nameText:SetJustifyH("CENTER")
  row.nameText = nameText

  ADDON.rows[i] = row
end

---------------------------------------------------
-- Command
---------------------------------------------------
SLASH_NEARBYTARGETS1 = "/nt"
SlashCmdList["NEARBYTARGETS"] = function()
  if main:IsShown() then main:Hide() else main:Show() end
end

---------------------------------------------------
-- Update loop
---------------------------------------------------
main.lastUpdate = 0
main:SetScript("OnUpdate", function()
  if GetTime() - main.lastUpdate < UPDATE_INTERVAL then return end
  main.lastUpdate = GetTime()
  ScanNameplates()

  for i = 1, MAX_ROWS do
    local data, row = ADDON.units[i], ADDON.rows[i]
    if data then
      local hp, max = data.hp or 0, data.max or 1
      local pct = math.min(1, hp / max)
      local r, g = (1 - pct), pct
      row.healthBar:SetWidth(160 * pct)
      row.healthBar:SetVertexColor(r, g, 0)
      row.nameText:SetText(string.format("%s [%d/%d]", data.realName, hp, max))
      row.realName = data.realName
      row:Show()
    else
      row.realName = nil
      row:Hide()
    end
  end
end)

main:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00NearbyTargets loaded.|r Stable slots + health bars active.")
