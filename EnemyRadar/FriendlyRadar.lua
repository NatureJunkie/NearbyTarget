-- Nearby Party (Vertical 7-Button Grid, Fixed Targeting, Vanilla 1.12 Safe)
-- Player + Pet + Party + Party Pets
-- Left-click: cast and keep target
-- Right-click or Alt+click: cast and restore previous target
-- No mouseover, no ClearTarget

local ADDON, UPDATE_INTERVAL, MAX_UNITS = {}, 0.6, 10
ADDON.units, ADDON.rows, ADDON.order = {}, {}, {}
local unitCounter = 0

---------------------------------------------------
-- Collect party members + pets
---------------------------------------------------
local function AddFriendlyUnits(newUnits, seen)
  local function AddUnit(u)
    if not UnitExists(u) then return end
    local n = UnitName(u)
    if not n or seen[n] or not UnitIsFriend("player", u) then return end
    local hp, max = UnitHealth(u), UnitHealthMax(u)
    newUnits[n] = {
      realName = n,
      hp = hp,
      max = max,
      dead = UnitIsDead(u),
      unitID = u
    }
    seen[n] = true
    if not ADDON.order[n] then
      unitCounter = unitCounter + 1
      ADDON.order[n] = unitCounter
    end
  end

  AddUnit("player")
  AddUnit("pet")
  for i = 1, GetNumPartyMembers() do
    AddUnit("party"..i)
    AddUnit("partypet"..i)
  end
end

---------------------------------------------------
-- Frame setup
---------------------------------------------------
local function CreateBackdrop(f)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  f:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
end

local main = CreateFrame("Frame", "NearbyPartyFrame", UIParent)
main:SetWidth(420)
main:SetHeight(450)
main:SetPoint("CENTER", UIParent, "CENTER", -450, 0)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", function() this:StartMoving() end)
main:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
CreateBackdrop(main)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -8)
title:SetText("|cff88ccffParty Healing Grid|r")

---------------------------------------------------
-- Button colors
---------------------------------------------------
local COLORS = {
  {1,0.2,0.2}, {1,0.6,0.2}, {1,1,0.3},
  {0.3,0.6,1}, {0.7,0.3,1}, {0.9,0.9,0.9}, {0.2,1,1},
}

---------------------------------------------------
-- Create rows (vertical layout)
---------------------------------------------------
local UNIT_W, UNIT_H = 390, 24
local BUTTON_SIZE, SPACING, BUTTON_OFFSET = 16, 4, 20

for i = 1, MAX_UNITS do
  local row = CreateFrame("Frame", nil, main)
  row:SetWidth(UNIT_W)
  row:SetHeight(UNIT_H)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 10, -32 - (i - 1) * (UNIT_H + 6))
  row.colorButtons = {}

  -- Health bar background
  local bg = row:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetTexture(0.1, 0.1, 0.1)
  row.bg = bg

  -- Health bar
  local bar = row:CreateTexture(nil, "BORDER")
  bar:SetPoint("LEFT", row, "LEFT", 0, 0)
  bar:SetHeight(UNIT_H)
  row.healthBar = bar

  -- Name text
  local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("LEFT", row, "LEFT", 6, 0)
  text:SetWidth(150)
  text:SetJustifyH("LEFT")
  row.nameText = text

  -- Create 7 buttons
  -- Create 7 buttons spaced nicely on the right side
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
    tex:SetTexture(COLORS[j][1], COLORS[j][2], COLORS[j][3])
    btn.bg = tex

    -- FIX: capture per-button/per-row references (Lua 5.0 upvalue gotcha)
    local idx = j
    local thisRow = row

    -- FIX: 1.12-safe targeting/restore (no UnitGUID in Vanilla)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(_, mouseButton)
      if not thisRow.unitID or not UnitExists(thisRow.unitID) then return end

      local restore = (mouseButton == "RightButton") or IsAltKeyDown()
      local hadTarget = UnitExists("target")
      local prevName = hadTarget and UnitName("target") or nil
      local newName  = thisRow.realName

      -- Set target, with Vanilla fallback by name
      TargetUnit(thisRow.unitID)
      if not UnitIsUnit("target", thisRow.unitID) then
        TargetByName(newName, true)
      end

      -- Cast per-button
      if     idx == 1 then CastSpellByName("Flash Heal")
      elseif idx == 2 then CastSpellByName("Renew")
      elseif idx == 3 then CastSpellByName("Heal")
      elseif idx == 4 then CastSpellByName("Power Word: Shield")
      elseif idx == 5 then CastSpellByName("Dispel Magic")
      elseif idx == 6 then CastSpellByName("Prayer of Healing")
      elseif idx == 7 then AssistUnit("target") end

      -- Restore previous target only when requested
      if restore and hadTarget and prevName and prevName ~= newName then
        TargetLastTarget()
        -- Fallback if TLS fails
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
  AddFriendlyUnits(newUnits, seen)

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
      local barWidth = math.max(1, pct * (UNIT_W - 170))
      r.healthBar:SetWidth(barWidth)
      r.healthBar:SetTexture(d.dead and 0.4 or red, d.dead and 0.4 or green, 0)
      r.nameText:SetText(string.format("|cff88ccff%s|r [%d%%]", d.realName, math.floor(pct * 100)))
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
SLASH_NEARBYPARTYFIX1 = "/phg"
SlashCmdList["NEARBYPARTYFIX"] = function()
  if main:IsShown() then main:Hide() else main:Show() end
end

main:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cff88ccffNearby Party (Fixed)|r Compact 7-button healing grid with safe targeting loaded.")

