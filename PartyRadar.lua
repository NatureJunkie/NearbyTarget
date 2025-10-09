-- NearbyAllies (Vanilla 1.12 / pfUI): Party & Raid Members Tracker

local ADDON = {}
local UPDATE_INTERVAL = 0.6
local MAX_ROWS = 40
ADDON.units, ADDON.rows, ADDON.order = {}, {}, {}

---------------------------------------------------
-- Build party/raid member list
---------------------------------------------------
local function ScanGroupMembers()
  local newUnits = {}
  local num = GetNumRaidMembers() or 0
  if num > 0 then
    for i = 1, num do
      local name = UnitName("raid"..i)
      if name and UnitExists("raid"..i) and not UnitIsDead("raid"..i) then
        local hp, maxhp = UnitHealth("raid"..i), UnitHealthMax("raid"..i)
        newUnits[name] = { realName = name, hp = hp, max = maxhp }
        if not ADDON.order[name] then
          local maxIndex = 0
          for _, idx in pairs(ADDON.order) do if idx > maxIndex then maxIndex = idx end end
          ADDON.order[name] = maxIndex + 1
        end
      end
    end
  else
    for i = 1, GetNumPartyMembers() do
      local name = UnitName("party"..i)
      if name and UnitExists("party"..i) and not UnitIsDead("party"..i) then
        local hp, maxhp = UnitHealth("party"..i), UnitHealthMax("party"..i)
        newUnits[name] = { realName = name, hp = hp, max = maxhp }
        if not ADDON.order[name] then
          local maxIndex = 0
          for _, idx in pairs(ADDON.order) do if idx > maxIndex then maxIndex = idx end end
          ADDON.order[name] = maxIndex + 1
        end
      end
    end
  end

  for nm, _ in pairs(ADDON.order) do
    if not newUnits[nm] then ADDON.order[nm] = nil end
  end

  local sorted = {}
  for nm, idx in pairs(ADDON.order) do
    if newUnits[nm] then sorted[idx] = newUnits[nm] end
  end
  ADDON.units = sorted
end

---------------------------------------------------
-- UI helpers
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

---------------------------------------------------
-- Main Frame
---------------------------------------------------
local main = CreateFrame("Frame", "NearbyAlliesFrame", UIParent)
main:SetWidth(400)
main:SetHeight(55 + MAX_ROWS * 20)
main:SetPoint("CENTER", UIParent, "CENTER", 450, 0)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", function() this:StartMoving() end)
main:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
CreateBackdrop(main)

local title = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -8)
title:SetText("Party & Raid Members")

---------------------------------------------------
-- Rows
---------------------------------------------------
for i = 1, MAX_ROWS do
  local row = CreateFrame("Frame", nil, main)
  row:SetWidth(380)
  row:SetHeight(18)
  row:SetPoint("TOPLEFT", main, "TOPLEFT", 10, -30 - (i - 1) * 18)

  local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nameText:SetPoint("LEFT", row, "LEFT", 5, 0)
  row.nameText = nameText

  ADDON.rows[i] = row
end

---------------------------------------------------
-- Slash command
---------------------------------------------------
SLASH_NEARBYALLIES1 = "/na"
SlashCmdList["NEARBYALLIES"] = function()
  if main:IsShown() then main:Hide() else main:Show() end
end

---------------------------------------------------
-- Update loop
---------------------------------------------------
main.lastUpdate = 0
main:SetScript("OnUpdate", function()
  if GetTime() - main.lastUpdate < UPDATE_INTERVAL then return end
  main.lastUpdate = GetTime()
  ScanGroupMembers()

  for i = 1, MAX_ROWS do
    local data, row = ADDON.units[i], ADDON.rows[i]
    if data then
      row.nameText:SetText(string.format("|cff00ccff%s|r [%d/%d]", data.realName, data.hp or 0, data.max or 0))
      row:Show()
    else
      row.nameText:SetText("")
      row:Hide()
    end
  end
end)

main:Show()
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00NearbyAllies loaded.|r Party/Raid up to 40 members.")
