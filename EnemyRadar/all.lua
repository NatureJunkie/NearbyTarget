-- Nearby Raid (Compact 7-Button Vertical Grid, Fixed Targeting, Vanilla 1.12 Safe)
-- Supports up to 40 raid members
-- No mouseover targeting, no ClearTarget, safe cast logic with target restore

local ADDON = {}
local UPDATE_INTERVAL = 0.6
local MAX_UNITS = 40
ADDON.units, ADDON.rows, ADDON.order = {}, {}, {}
local unitCounter = 0

---------------------------------------------------
-- Collect raid members
---------------------------------------------------
local function AddRaidUnits(newUnits, seen)
  local function AddUnit(u)
    if not UnitExists(u) then return end
    local n = UnitName(u)
    if not n or seen[n] then return end
    if UnitIsFriend("player", u) then
      newUnits[n] = {
        realName = n,
        hp = UnitHealth(u),
        max = UnitHealthMax(u),
        dead = UnitIsDead(u),
        unitID = u
      }
      seen[n] = true
      if not ADDON.order[n] then
        unitCounter = unitCounter + 1
        ADDON.order[n] = unitCounter
      end
    end
  end

  AddUnit("player")
  AddUnit("pet")

  for i = 1, GetNumRaidMembers() do
    AddUnit("raid"..i)
    -- AddUnit("raidpet"..i) -- optional
  end
end

---------------------------------------------------
-- Frame setup
---------------------------------------------------
local function CreateBackdrop(f)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
end

local main = CreateFrame("Frame", "NearbyRaidFrame", UIParent)
main:SetWidth(420)
main:SetHeight(740)
main:SetPoint("CENTER", UIParent, "CENTER", -450, 0)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", function() this:StartMoving() end)
main:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
CreateBackdrop(main)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -8)
title:SetText("|cffffcc88Raid Healing Grid|r")

---------------------------------------------------
-- Button colors
---------------------------------------------------
local COLORS = {
  {1,0.2,0.2}, {1,0.6,0.2}, {1,1,0.3},
  {0.3,0.6,1}, {0.7,0.3,1}, {0.9,0.9,0.9}, {0.2,1,1},
}

---------------------------------------------------
-- Create compact rows
---------------------------------------------------
local UNIT_W, UNIT_H = 380, 16
local BUTTON_SIZE, SPACING, BUTTON_OFFSET = 12, 3, 18

for i = 1, MAX_UNITS do
  local row = CreateFrame("Frame", nil, main)
  row:SetWidth(UNIT_W)
  row:SetHeight(UNIT_H)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 10, -30 - (i - 1) * (UNIT_H + 3))
  row.colorButtons = {}

  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetTexture(0.08, 0.08, 0.08)
  row.bg = bg

  local bar = row:CreateTexture(nil, "BORDER")
  bar:SetPoint("LEFT", row, "LEFT", 0, 0)
  bar:SetHeight(UNIT_H)
  bar:SetTexture(0, 0.7, 0)
  row.healthBar = bar

  local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", row, "LEFT", 5, 0)
  text:SetWidth(120)
  text:SetJustifyH("LEFT")
  row.nameText = text

  ---------------------------------------------------
  -- Buttons with safe targeting (fixed Lua 5.0 closure)
  ---------------------------------------------------
  for j = 1, 7 do
    local btn = CreateFrame("Button", nil, row)
    btn:SetWidth(BUTTON_SIZE)
    btn:SetHeight(BUTTON_SIZE)
    if j == 1 then
      btn:SetPoint("RIGHT", row, "RIGHT", -BUTTON_OFFSET, 0)
    else
      btn:SetPoint("RIGHT", row.colorButtons[j - 1], "LEFT", -SPACING, 0)
    end

    local tex = btn:CreateTexture(nil, "BACKGROUND")
    tex:SetAllPoints()
    tex:SetTexture(unpack(COLORS[j]))
    btn.bg = tex

    -- capture loop vars safely
    local idx = j
    local thisRow = row

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouseButton)
      if not thisRow.unitID or not UnitExists(thisRow.unitID) then return end

      local restore = (mouseButton == "RightButton") or IsAltKeyDown()
      local hadTarget = UnitExists("target")
      local prevName = hadTarget and UnitName("target") or nil
      local newName  = thisRow.realName

      -- target safely, with fallback by name
      TargetUnit(thisRow.unitID)
      if not UnitIsUnit("target", thisRow.unitID) then
        TargetByName(newName, true)
      end

      -- spell actions
      if     idx == 1 then CastSpellByName("Flash Heal")
      elseif idx == 2 then CastSpellByName("Renew")
      elseif idx == 3 then CastSpellByName("Heal")
      elseif idx == 4 then CastSpellByName("Power Word: Shield")
      elseif idx == 5 then CastSpellByName("Dispel Magic")
      elseif idx == 6 then CastSpellByName("Prayer of Healing")
      elseif idx == 7 then AssistUnit("target") end

      -- restore only if target actually changed
      if restore and hadTarget and prevName and prevName ~= newName then
        TargetLastTarget()
        if UnitName("target") ~= prevName then
          TargetByName(prevName, true)
        end
      end
    end)

    row.colorButtons[j] = btn
  end

  ADDON.rows[i] = row
end

---------------------------------------------------
-- Update logic
---------------------------------------------------
main.lastUpdate = 0
main:SetScript("OnUpdate", function()
  if GetTime() - main.lastUpdate < UPDATE_INTERVAL then return end
  main.lastUpdate = GetTime()

  local seen, newUnits = {}, {}
  AddRaidUnits(newUnits, seen)

  for nm in pairs(ADDON.order) do
    if not newUnits[nm] then ADDON.order[nm] = nil end
  end

  local sorted = {}
  for nm, idx in pairs(ADDON.order) do
    if newUnits[nm] then sorted[idx] = newUnits[nm] end
  end
  ADDON.units = sorted

  for i = 1, MAX_UNITS do
    local d, r = ADDON.units[i], ADDON.rows[i]
    if d then
      local pct = (d.max > 0) and (d.hp / d.max) or 0
      local red, green = (1 - pct), pct
      local barWidth = math.max(1, pct * (UNIT_W - 150))
      r.healthBar:SetWidth(barWidth)
      if d.dead then
        r.healthBar:SetTexture(0.4, 0.4, 0.4)
      else
        r.healthBar:SetTexture(red, green, 0)
      end
      r.nameText:SetText(string.format("|cffffffaa%s|r [%d%%]", d.realName, math.floor(pct * 100)))
      r.realName = d.realName
      r.unitID = d.unitID
      r:Show()
    else
      r:Hide()
    end
  end
end)

---------------------------------------------------
-- Slash command
---------------------------------------------------
SLASH_NEARBYRAIDFIX1 = "/rhg"
SlashCmdList["NEARBYRAIDFIX"] = function()
  if main:IsShown() then main:Hide() else main:Show() end
end

main:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cffffcc88Nearby Raid (Fixed)|r Compact 40-unit healing grid with safe targeting loaded.")
