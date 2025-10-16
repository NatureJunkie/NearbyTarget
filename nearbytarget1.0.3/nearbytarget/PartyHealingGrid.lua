-- NearbyTargets Square Grid (Vanilla 1.12, Lua 5.0-safe)
-- Party: square list UI with orbit buttons around each main square (/ntparty)
-- Raid : 8x5 clusters, each is a square + 16 uniform-color orbit buttons (/ntraid)
-- Filters: words + [and]/[or], [below:N], [above:N] (N is % if comparePercent=true, else raw HP)
-- Targeting directive (group-scoped only): [targeting:<name>[:<hpRule>]]
-- Chat directives in Name box: [whisper[:Name]] | [say] | [yell] | [party] | [raid]
-- All WoW frame calls avoid ":" sugar (no self). No "%" operator (Lua 5.0-safe).

---------------------------------------------------
-- SavedVariables (shared)
---------------------------------------------------
if not NearbyTargetsSettings then
    NearbyTargetsSettings = {
        comparePercent = true,
        showPercent    = true,
        raidScale      = 1.0,
        partyScale     = 1.0,
        partySquare    = 80,
        raidSquare     = 90,
        orbitSize      = 12,
        orbitCount     = 16,
    }
end

if not NearbyTargetsFilters then
    NearbyTargetsFilters = {
        Beast=true, Elemental=true, Humanoid=true, Undead=true, Demon=true, Dragonkin=true,
        Mechanical=true, Player=true, Pet=true, Unknown=true
    }
end
local HOLD_BOTH_THRESHOLD = 0.1
---------------------------------------------------
-- Small utils (Lua 5.0 safe)
---------------------------------------------------
local function Trim(s)
    if not s then return "" end
    s = string.gsub(s, "^[%s%z]+", "")
    s = string.gsub(s, "[%s%z]+$", "")
    return s
end

local function tappend(t, v)
    local n = table.getn(t)
    t[n+1] = v
end

local function mod_no_pct(n, d)  -- n % d without using '%'
    return n - d * math.floor(n / d)
end

-- Nil-safe backdrop setter (no ":" sugar)
local function SafeSetBackdrop(frame, alpha)
    if not frame or type(frame) ~= "table" then return end
    local setBD = frame.SetBackdrop
    if setBD then
        setBD(frame, {
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        local setCol = frame.SetBackdropColor
        if setCol then setCol(frame, 0, 0, 0, alpha or 0.85) end
    end
end

---------------------------------------------------
-- Clickthrough system (hold both buttons >= 0.10s)
---------------------------------------------------
local _LDOWN, _RDOWN = false, false
local _HELD_ROW = nil

-- global click-through state
local _NT_CLICKTHRU = { on=false, root=nil, row=nil }

-- Toggle mouse on our addon tree (frames/buttons/edits etc.)
local function ToggleMouseTree(root, enable)
    if not root then return end
    if root.EnableMouse then root.EnableMouse(root, enable) end
    if root.EnableMouseWheel then root.EnableMouseWheel(root, enable) end

    local list, i

    list = root._nt_rows
    if list then
        i = 1
        while list[i] do
            local r = list[i]
            if r and r.unit and r.unit.EnableMouse then r.unit.EnableMouse(r.unit, enable) end
            if r and r.orbit then
                local j = 1
                while r.orbit[j] do
                    local b = r.orbit[j]
                    if b and b.EnableMouse then b.EnableMouse(b, enable) end
                    j = j + 1
                end
            end
            i = i + 1
        end
    end

    list = root._nt_clusters
    if list then
        i = 1
        while list[i] do
            local cl = list[i]
            if cl and cl.unit and cl.unit.EnableMouse then cl.unit.EnableMouse(cl.unit, enable) end
            if cl and cl.orbit then
                local j = 1
                while cl.orbit[j] do
                    local b = cl.orbit[j]
                    if b and b.EnableMouse then b.EnableMouse(b, enable) end
                    j = j + 1
                end
            end
            i = i + 1
        end
    end

    if root._nt_drag and root._nt_drag.EnableMouse then root._nt_drag.EnableMouse(root._nt_drag, enable) end
    if root._nt_bottom and root._nt_bottom.EnableMouse then root._nt_bottom.EnableMouse(root._nt_bottom, enable) end
end

local function NT_EngageClickthrough(row)
    if not row then return end
    local root = row._root
    if root and (not _NT_CLICKTHRU.on) then
        ToggleMouseTree(root, false)
        root._mutedByNT = true
        _NT_CLICKTHRU.on = true
        _NT_CLICKTHRU.root = root
        _NT_CLICKTHRU.row  = row
    end
end

local function NT_DisengageClickthrough()
    if _NT_CLICKTHRU.on and _NT_CLICKTHRU.root then
        ToggleMouseTree(_NT_CLICKTHRU.root, true)
        _NT_CLICKTHRU.root._mutedByNT = nil
    end
    _NT_CLICKTHRU.on = false
    _NT_CLICKTHRU.root = nil
    _NT_CLICKTHRU.row  = nil
end

local function EnableRowMouse(row)
    if not row then return end
    if row._mouseOff then
        if row.unit and row.unit.EnableMouse then row.unit.EnableMouse(row.unit, true) end
        if row.orbit then
            local i = 1
            while row.orbit[i] do
                if row.orbit[i].EnableMouse then row.orbit[i].EnableMouse(row.orbit[i], true) end
                i = i + 1
            end
        end
        row._mouseOff = nil
    end
end

local function DisableRowMouse(row)
    if not row then return end
    if not row._mouseOff then
        if row.unit and row.unit.EnableMouse then row.unit.EnableMouse(row.unit, false) end
        if row.orbit then
            local i = 1
            while row.orbit[i] do
                if row.orbit[i].EnableMouse then row.orbit[i].EnableMouse(row.orbit[i], false) end
                i = i + 1
            end
        end
        row._mouseOff = true
    end
end

local function ReArmAllRows(rowsA, rowsB)
    if rowsA then
        local i = 1
        while rowsA[i] do EnableRowMouse(rowsA[i]); i = i + 1 end
    end
    if rowsB then
        local j = 1
        while rowsB[j] do EnableRowMouse(rowsB[j]); j = j + 1 end
    end
    _HELD_ROW = nil
end

do
    local prevDown = nil
    if WorldFrame.GetScript then
        prevDown = WorldFrame.GetScript(WorldFrame, "OnMouseDown")
    end
    if WorldFrame.SetScript then
        WorldFrame.SetScript(WorldFrame, "OnMouseDown", function()
            if prevDown then prevDown() end
            if arg1 == "LeftButton"  then _LDOWN = true  end
            if arg1 == "RightButton" then _RDOWN = true  end
        end)
    end

    local prevUp = nil
    if WorldFrame.GetScript then
        prevUp = WorldFrame.GetScript(WorldFrame, "OnMouseUp")
    end
    if WorldFrame.SetScript then
        WorldFrame.SetScript(WorldFrame, "OnMouseUp", function()
            if prevUp then prevUp() end
            if arg1 == "LeftButton"  then _LDOWN = false end
            if arg1 == "RightButton" then _RDOWN = false end
            NT_DisengageClickthrough()
            -- each UI re-arms on its own OnUpdate by calling ReArmAllRows(...)
        end)
    end
end

-- Attach click-through logic to a row (main square and its orbits)
local function AttachRowClickthrough(row, mainButton)
    if mainButton and mainButton.SetScript then
        mainButton.SetScript(mainButton, "OnMouseDown", function()
            if arg1 == "LeftButton"  then _LDOWN = true  end
            if arg1 == "RightButton" then _RDOWN = true  end
            if _LDOWN and _RDOWN then
                row._bothDownAt = GetTime()
            else
                row._bothDownAt = nil
            end
        end)
        mainButton.SetScript(mainButton, "OnUpdate", function()
            if row._mouseOff then return end
            local bothHeld = _LDOWN and _RDOWN
            if bothHeld then
                if not row._bothDownAt then row._bothDownAt = GetTime() end
                if GetTime() - row._bothDownAt > HOLD_BOTH_THRESHOLD  then
                    DisableRowMouse(row)
                    _HELD_ROW = row
                    NT_EngageClickthrough(row)
                end
            else
                row._bothDownAt = nil
            end
        end)
        mainButton.SetScript(mainButton, "OnMouseUp", function()
            if arg1 == "LeftButton"  then _LDOWN = false end
            if arg1 == "RightButton" then _RDOWN = false end
            if (not _LDOWN) or (not _RDOWN) then
                NT_DisengageClickthrough()
            end
        end)
    end

    if row.orbit then
        local i = 1
        while row.orbit[i] do
            local b = row.orbit[i]
            if b and b.SetScript then
                b.leftIsDown, b.rightIsDown = false, false
                b.SetScript(b, "OnMouseDown", function()
                    if arg1 == "LeftButton"  then b.leftIsDown  = true; _LDOWN = true  end
                    if arg1 == "RightButton" then b.rightIsDown = true; _RDOWN = true  end
                    if (_LDOWN or b.leftIsDown) and (_RDOWN or b.rightIsDown) then
                        row._bothDownAt = GetTime()
                    else
                        row._bothDownAt = nil
                    end
                end)
                b.SetScript(b, "OnUpdate", function()
                    if row._mouseOff then return end
                    local bothHeld = (_LDOWN or b.leftIsDown) and (_RDOWN or b.rightIsDown)
                    if bothHeld then
                        if not row._bothDownAt then row._bothDownAt = GetTime() end
                        if GetTime() - row._bothDownAt > HOLD_BOTH_THRESHOLD  then
                            DisableRowMouse(row)
                            _HELD_ROW = row
                            NT_EngageClickthrough(row)
                        end
                    else
                        row._bothDownAt = nil
                    end
                end)
                b.SetScript(b, "OnMouseUp", function()
                    if arg1 == "LeftButton"  then b.leftIsDown  = false; _LDOWN = false end
                    if arg1 == "RightButton" then b.rightIsDown = false; _RDOWN = false end
                    if (not _LDOWN) or (not _RDOWN) then
                        NT_DisengageClickthrough()
                    end
                end)
            end
            i = i + 1
        end
    end
end

---------------------------------------------------
-- Query parsing (words + [and]/[or], [below:N], [above:N])
---------------------------------------------------
local function ParseQueryText(txt)
    local res = { terms = {}, op = "OR", below = nil, above = nil }
    if not txt or txt == "" then return res end

    local s = string.lower(txt)
    local i, n = 1, string.len(s)
    local plainPieces = {}

    while i <= n do
        local lb = string.find(s, "[", i, true)
        if not lb then
            tappend(plainPieces, string.sub(s, i, n))
            break
        end
        if lb > i then tappend(plainPieces, string.sub(s, i, lb - 1)) end
        local rb = string.find(s, "]", lb + 1, true)
        if not rb then
            tappend(plainPieces, string.sub(s, lb, n))
            break
        end

        local tag = Trim(string.sub(s, lb + 1, rb - 1))
        if tag == "and" then
            res.op = "AND"
        elseif tag == "or" then
            res.op = "OR"
        else
            local cpos = string.find(tag, ":", 1, true)
            if cpos then
                local key = Trim(string.sub(tag, 1, cpos - 1))
                local val = Trim(string.sub(tag, cpos + 1))
                local cleaned = string.gsub(val, "%%", "")
                local num = tonumber(cleaned)
                if key == "below" and num then res.below = num
                elseif key == "above" and num then res.above = num
                end
            end
        end
        i = rb + 1
    end

    local plain = Trim(table.concat(plainPieces, " "))
    local wstart, plen = 1, string.len(plain)
    while wstart <= plen do
        while wstart <= plen do
            local ch = string.sub(plain, wstart, wstart)
            if ch ~= " " and ch ~= "\t" then break end
            wstart = wstart + 1
        end
        if wstart > plen then break end
        local wend = string.find(plain, " ", wstart, true)
        if not wend then wend = plen + 1 end
        local word = Trim(string.sub(plain, wstart, wend - 1))
        if word ~= "" then tappend(res.terms, word) end
        wstart = wend + 1
    end

    return res
end

local function NameTermsPass(name, terms, op)
    if not terms or table.getn(terms) == 0 then return true end
    if not name or name == "" then return false end
    local lc = string.lower(name)
    local i = 1
    if op == "AND" then
        while i <= table.getn(terms) do
            if not string.find(lc, terms[i], 1, true) then return false end
            i = i + 1
        end
        return true
    else
        while i <= table.getn(terms) do
            if string.find(lc, terms[i], 1, true) then return true end
            i = i + 1
        end
        return false
    end
end

local function NumericFiltersPass(u, below, above, comparePercent)
    local hpval
    if comparePercent then
        local mx = (u.max and u.max > 0) and u.max or 1
        local pct = (u.hp or 0) / mx
        hpval = pct * 100
    else
        hpval = u.hp or 0
    end
    if below and not (hpval < below) then return false end
    if above and not (hpval > above) then return false end
    return true
end

local function PassesAllFilters(u, parsed, comparePercent)
    if u.utype ~= "Player" and u.utype ~= "Pet" then return false end
    if not NearbyTargetsFilters[u.utype] then return false end
    if not NameTermsPass(u.realName, parsed.terms, parsed.op) then return false end
    if not NumericFiltersPass(u, parsed.below, parsed.above, comparePercent) then return false end
    return true
end

---------------------------------------------------
-- Targeting directive [targeting:<name>[:<hpRule>]]
---------------------------------------------------
local function parse_hp_rule(tok)
    if not tok or tok == "" then return nil end
    local first = string.sub(tok, 1, 1)
    if first ~= "<" and first ~= ">" and first ~= "=" then return nil end
    local rest = Trim(string.sub(tok, 2))
    local isPct = false
    if string.sub(rest, -1) == "%" then
        isPct = true
        rest = string.sub(rest, 1, string.len(rest)-1)
    end
    local num = tonumber(rest)
    if not num then return nil end
    return { op = first, val = num, pct = isPct }
end

local function hp_matches_rule(hp, hpmax, rule)
    if not rule then return true end
    if not hp or not hpmax or hpmax <= 0 then return false end
    local actual = rule.pct and ((hp / hpmax) * 100) or hp
    if rule.op == "<" then return actual <  rule.val end
    if rule.op == ">" then return actual >  rule.val end
    if rule.op == "=" then
        if rule.pct then
            return (actual > (rule.val - 0.25)) and (actual < (rule.val + 0.25))
        else
            return actual == rule.val
        end
    end
    return true
end

local function parse_targeting_from_text(txt)
    if not txt or txt == "" then return nil end
    local s = string.lower(txt)
    local i, n = 1, string.len(s)
    while i <= n do
        local lb = string.find(s, "[", i, true)
        if not lb then break end
        local rb = string.find(s, "]", lb + 1, true)
        if not rb then break end
        local tag = string.sub(s, lb + 1, rb - 1)
        if string.sub(tag, 1, 10) == "targeting:" then
            local inner = string.sub(tag, 11)
            local nameTok, hpTok
            local c1 = string.find(inner, ":", 1, true)
            if c1 then
                nameTok = Trim(string.sub(inner, 1, c1 - 1))
                hpTok   = Trim(string.sub(inner, c1 + 1))
            else
                nameTok = Trim(inner)
            end
            if nameTok ~= "" then
                return { nameLC = string.lower(nameTok), hp = parse_hp_rule(hpTok) }
            end
        end
        i = rb + 1
    end
    return nil
end

---------------------------------------------------
-- Chat directive in Name box
---------------------------------------------------
local function parse_chat_directive(txt)
    if not txt or txt == "" then return nil end
    local s = string.lower(txt)
    local i, n = 1, string.len(s)
    while i <= n do
        local lb = string.find(s, "[", i, true)
        if not lb then break end
        local rb = string.find(s, "]", lb + 1, true)
        if not rb then break end
        local tag = Trim(string.sub(s, lb + 1, rb - 1))
        if tag == "say"   then return { mode = "SAY" } end
        if tag == "yell"  then return { mode = "YELL" } end
        if tag == "party" then return { mode = "PARTY" } end
        if tag == "raid"  then return { mode = "RAID" } end
        if string.sub(tag,1,7) == "whisper" then
            local target = nil
            if string.len(tag) > 7 and string.sub(tag,8,8) == ":" then
                target = Trim(string.sub(tag,9))
                if target == "" then target = nil end
            end
            return { mode = "WHISPER", target = target }
        end
        i = rb + 1
    end
    return nil
end

---------------------------------------------------
-- Group scanning (party/raid), friendly only (players + pets)
---------------------------------------------------
local function BuildGroupList(mode) -- "party" | "raid"
    local units, idx = {}, 0
    local function addUnit(token, isPet)
        if not UnitExists(token) then return end
        local name = UnitName(token)
        if not name or name == "" then return end
        if isPet and not NearbyTargetsFilters.Pet then return end
        if (not isPet) and not NearbyTargetsFilters.Player then return end
        local hp  = UnitHealth(token) or 0
        local mx  = UnitHealthMax(token) or 1
        local utype = isPet and "Pet" or "Player"
        idx = idx + 1
        units[idx] = { uid = token, realName = name, hp = hp, max = mx, utype = utype, token = token }
    end

    if mode == "party" then
        addUnit("player", false)
        addUnit("pet",    true)
        local count, i = (GetNumPartyMembers() or 0), 1
        while i <= count do
            addUnit("party"..i, false)
            addUnit("party"..i.."pet", true)
            i = i + 1
        end
    else
        local rcount, i = (GetNumRaidMembers() or 0), 1
        while i <= rcount do
            addUnit("raid"..i, false)
            addUnit("raid"..i.."pet", true)
            i = i + 1
        end
    end
    return units
end

---------------------------------------------------
-- Compare helpers
---------------------------------------------------
local function CompareValuePercent(u)
    local mx = (u.max and u.max > 0) and u.max or 1
    return (u.hp or 0) / mx
end

local function IsALowerThanB(a, b, comparePercent)
    local va, vb
    if comparePercent then
        va, vb = CompareValuePercent(a), CompareValuePercent(b)
        local diff = va - vb
        if diff < -0.0001 then return true end
        if diff >  0.0001 then return false end
    else
        va, vb = (a.hp or 0), (b.hp or 0)
        if va < vb then return true end
        if va > vb then return false end
    end
    return (a.realName or "") < (b.realName or "")
end

---------------------------------------------------
-- Common UI helpers (backdrop, resizer, hp text)
---------------------------------------------------
local function ClampToScreen(frame)
    local uiW, uiH = UIParent.GetWidth(UIParent), UIParent.GetHeight(UIParent)
    local fw, fh = frame.GetWidth(frame) * frame.GetScale(frame), frame.GetHeight(frame) * frame.GetScale(frame)
    local left, right, top, bottom = frame.GetLeft(frame), frame.GetRight(frame), frame.GetTop(frame), frame.GetBottom(frame)
    if not (left and right and top and bottom) then return end

    local offX, offY = 0, 0
    if left < 0 then offX = -left
    elseif right > uiW then offX = uiW - right end

    if bottom < 0 then offY = -bottom
    elseif top > uiH then offY = uiH - top end

    frame.ClearAllPoints(frame)
    frame.SetPoint(frame, "CENTER", UIParent, "BOTTOMLEFT", (left + offX) + fw / 2, (bottom + offY) + fh / 2)
end

local function MakeScaleGrip(parent, applyScale, getScale)
    local grip = CreateFrame("Frame", nil, parent)
    grip.SetWidth(grip, 16); grip.SetHeight(grip, 16)
    grip.SetPoint(grip, "BOTTOMRIGHT", parent, "BOTTOMRIGHT", -3, 3)
    local tex = grip.CreateTexture(grip, nil, "ARTWORK")
    tex.SetAllPoints(tex)
    tex.SetTexture(tex, "Interface\\ChatFrame\\ChatFrameBackground")
    tex.SetVertexColor(tex, 0.8,0.8,0.8, 0.9)
    grip.EnableMouse(grip, true)
    grip.RegisterForDrag(grip, "LeftButton")
    local startX, startY, startS
    grip.SetScript(grip, "OnDragStart", function()
        startS = getScale()
        startX, startY = GetCursorPosition()
        grip.StartMoving(grip)
    end)
    grip.SetScript(grip, "OnDragStop", function()
        grip.StopMovingOrSizing(grip)
    end)
    grip.SetScript(grip, "OnUpdate", function()
        if not startX then return end
        local x, y = GetCursorPosition()
        local dx = x - startX
        local dy = y - startY
        local delta = (math.abs(dx) > math.abs(dy)) and dx or dy
        local s = startS + (delta / 600.0)
        if s < 0.6 then s = 0.6 end
        if s > 2.0 then s = 2.0 end
        applyScale(s)
    end)
    return grip
end

local function FormatHPText(u, showPercent)
    local hp, mx = (u.hp or 0), (u.max or 1); if mx <= 0 then mx = 1 end
    if showPercent then
        local pct = math.floor((hp * 100) / mx + 0.5)
        return tostring(pct) .. "%"
    else
        return tostring(hp) .. "/" .. tostring(mx)
    end
end

---------------------------------------------------
-- Orbit buttons
---------------------------------------------------
local ORBIT_COLORS = {
    {1.0, 0.2, 0.2},
    {1.0, 0.6, 0.2},
    {1.0, 1.0, 0.2},
    {0.4, 1.0, 0.3},
    {0.1, 0.8, 0.5},
    {0.3, 0.6, 1.0},
    {0.7, 0.3, 1.0},
    {1.0, 0.3, 0.6},
    {0.9, 0.9, 0.9},
    {0.3, 1.0, 1.0},
    {1.0, 0.8, 0.4},
    {0.4, 0.4, 1.0},
    {0.4, 1.0, 0.8},
    {1.0, 0.5, 0.8},
    {0.8, 0.3, 0.3},
    {0.6, 0.6, 0.6},
}

local function CreateOrbitButtons(parent, unit, count, size, callFunc)
    local btns = {}
    local numColors = table.getn(ORBIT_COLORS)

    -- the holder itself should not swallow clicks
    if parent.EnableMouse then parent.EnableMouse(parent, false) end
    if parent.SetBackdrop then parent.SetBackdrop(parent, nil) end

    if parent.SetFrameStrata then parent.SetFrameStrata(parent, "HIGH") end
    if unit.GetFrameLevel and parent.SetFrameLevel then
        local lvl = unit.GetFrameLevel(unit) or 0
        parent.SetFrameLevel(parent, lvl + 1)
    end

    local i = 1
    while i <= count do
        local b = CreateFrame("Button", nil, parent)
        b.SetWidth(b, size); b.SetHeight(b, size)
        b.EnableMouse(b, true)
        b.RegisterForClicks(b, "LeftButtonUp", "RightButtonUp")
        b.leftIsDown, b.rightIsDown = false, false

        local tex = b.CreateTexture(b, nil, "ARTWORK")
        tex.SetAllPoints(tex)
        tex.SetTexture(tex, "Interface\\ChatFrame\\ChatFrameBackground")
        local colorIndex = ((i - 1) - numColors * math.floor((i - 1) / numColors)) + 1
        local c = ORBIT_COLORS[colorIndex]
        tex.SetVertexColor(tex, c[1], c[2], c[3], 1)

        if b.SetHitRectInsets then b.SetHitRectInsets(b, 0, 0, 0, 0) end

        local idxForCall = i
        b.SetScript(b, "OnClick", function(_, _btn)
            local owner = parent._ownerRow or parent
            if owner and owner._mouseOff then return end

            -- NEW: provide context + auto-target this unit
            if owner and owner.unit and owner.unit.token then
                NearbyTargets_LastUnitToken = owner.unit.token
                NearbyTargets_LastUnitName  = owner.realName
                TargetUnit(owner.unit.token)         -- <-- this is the key line
            end

            if type(callFunc) == "function" then callFunc(idxForCall) end
        end)


        btns[i] = b
        i = i + 1
    end

    local function layout()
        local N = count; if N < 8 then N = 8 end
        local perSide = math.floor(N / 4); if perSide < 2 then perSide = 2 end
        local extra = N - (perSide * 4)

        local uW = unit.GetWidth(unit) or 80
        local uH = unit.GetHeight(unit) or 80
        local pad = 3
        local gapX = (uW - size) / (perSide - 1)
        local gapY = (uH - size) / (perSide - 1)

        local sides = { perSide, perSide, perSide, perSide }
        local r = extra; local si = 1
        while r > 0 do
            sides[si] = sides[si] + 1
            r = r - 1; si = si + 1; if si > 4 then si = 1 end
        end

        local idx = 1
        local k

        -- TOP
        k = 1
        while k <= sides[1] do
            local b = btns[idx]; if not b then break end
            b.ClearAllPoints(b)
            b.SetPoint(b, "BOTTOMLEFT", unit, "TOPLEFT", (k - 1) * gapX, pad)
            idx = idx + 1; k = k + 1
        end
        -- RIGHT
        k = 1
        while k <= sides[2] do
            local b = btns[idx]; if not b then break end
            b.ClearAllPoints(b)
            b.SetPoint(b, "TOPLEFT", unit, "TOPRIGHT", pad, -((k - 1) * gapY))
            idx = idx + 1; k = k + 1
        end
        -- BOTTOM
        k = 1
        while k <= sides[3] do
            local b = btns[idx]; if not b then break end
            b.ClearAllPoints(b)
            b.SetPoint(b, "TOPRIGHT", unit, "BOTTOMRIGHT", -((k - 1) * gapX), -pad)
            idx = idx + 1; k = k + 1
        end
        -- LEFT
        k = 1
        while k <= sides[4] do
            local b = btns[idx]; if not b then break end
            b.ClearAllPoints(b)
            b.SetPoint(b, "BOTTOMRIGHT", unit, "BOTTOMLEFT", -pad, (k - 1) * gapY)
            idx = idx + 1; k = k + 1
        end
    end

    parent.SetScript(parent, "OnShow", layout)
    parent.SetScript(parent, "OnSizeChanged", layout)
    unit.SetScript(unit, "OnSizeChanged", layout)

    return btns
end

---------------------------------------------------
-- PARTY UI (square rows + orbit)
---------------------------------------------------
local function CreatePartyUI(addonName, windowTitle)
    local STATE = {}
    STATE.settings     = NearbyTargetsSettings
    STATE.parsedQuery  = { terms = {}, op = "OR", below = nil, above = nil }
    STATE.targeting    = nil
    STATE.chatDir      = nil
    STATE.rows         = {}
    STATE._currentList = {}
    STATE.scale        = NearbyTargetsSettings.partyScale or 1.0

    local UPDATE_INTERVAL = 0.5
    local MAX_ROWS = 8
    local SQ       = NearbyTargetsSettings.partySquare or 80
    local ORB      = NearbyTargetsSettings.orbitSize or 12
    local ORBCNT   = NearbyTargetsSettings.orbitCount or 16
    if ORBCNT < 8 then ORBCNT = 8 end

    local main = CreateFrame("Frame", addonName.."Frame", UIParent)
    main.SetWidth(main, 620)
    main.SetHeight(main, 82 + MAX_ROWS * (SQ + 10) + 40)
    main.SetPoint(main, "CENTER", UIParent, "CENTER", 0, 160)
    main.SetMovable(main, true)
    -- Root should not swallow clicks (content area is click-through);
    -- drag/title bar remains interactive.
    main.EnableMouse(main, false)
    if main.EnableMouseWheel then main.EnableMouseWheel(main, true) end

    SafeSetBackdrop(main, 0.88)
    main.SetScale(main, STATE.scale)

    local function AutoFit()
        local sw, sh = UIParent.GetWidth(UIParent), UIParent.GetHeight(UIParent)
        local mw, mh = main.GetWidth(main) * STATE.scale, main.GetHeight(main) * STATE.scale
        local margin = 40
        local sx = (sw - margin) / mw
        local sy = (sh - margin) / mh
        local s = sx; if sy < s then s = sy end
        if s < 1.0 then
            STATE.scale = s
            NearbyTargetsSettings.partyScale = s
            main.SetScale(main, s)
            ClampToScreen(main)
        end
    end

    local drag = CreateFrame("Frame", nil, main)
    drag.SetPoint(drag, "TOPLEFT", main, "TOPLEFT", 0, 0)
    drag.SetPoint(drag, "TOPRIGHT", main, "TOPRIGHT", 0, 0)
    drag.SetHeight(drag, 24)
    drag.EnableMouse(drag, true)
    drag.RegisterForDrag(drag, "LeftButton")
    drag.SetScript(drag, "OnDragStart", function() main.StartMoving(main) end)
    drag.SetScript(drag, "OnDragStop",  function() main.StopMovingOrSizing(main) end)
    SafeSetBackdrop(drag, 0.85)

    local title = drag.CreateFontString(drag, nil, "OVERLAY", "GameFontNormal")
    title.SetPoint(title, "LEFT", drag, "LEFT", 8, 0)
    title.SetJustifyH(title, "LEFT")
    title.SetText(title, windowTitle)

    local compareBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    compareBtn.SetWidth(compareBtn, 110); compareBtn.SetHeight(compareBtn, 18)
    compareBtn.SetPoint(compareBtn, "LEFT", title, "RIGHT", 8, 0)
    local function CompareLabel() return STATE.settings.comparePercent and "Compare: %HP" or "Compare: Raw HP" end
    compareBtn.SetText(compareBtn, CompareLabel())
    compareBtn.SetScript(compareBtn, "OnClick", function()
        STATE.settings.comparePercent = not STATE.settings.comparePercent
        compareBtn.SetText(compareBtn, CompareLabel())
    end)

    local hpModeBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    hpModeBtn.SetWidth(hpModeBtn, 90); hpModeBtn.SetHeight(hpModeBtn, 18)
    hpModeBtn.SetPoint(hpModeBtn, "LEFT", compareBtn, "RIGHT", 8, 0)
    local function HPLabel() return STATE.settings.showPercent and "HP Mode: %" or "HP Mode: Raw" end
    hpModeBtn.SetText(hpModeBtn, HPLabel())
    hpModeBtn.SetScript(hpModeBtn, "OnClick", function()
        STATE.settings.showPercent = not STATE.settings.showPercent
        hpModeBtn.SetText(hpModeBtn, HPLabel())
    end)

    local resetBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    resetBtn.SetWidth(resetBtn, 50); resetBtn.SetHeight(resetBtn, 18)
    resetBtn.SetPoint(resetBtn, "LEFT", hpModeBtn, "RIGHT", 8, 0)
    resetBtn.SetText(resetBtn, "Reset")

    local function ApplyScaleParty(s)
        if s < 0.6 then s = 0.6 end
        if s > 2.0 then s = 2.0 end
        STATE.scale = s
        NearbyTargetsSettings.partyScale = s
        main.SetScale(main, s)
        ClampToScreen(main)
    end
    resetBtn.SetScript(resetBtn, "OnClick", function()
        ApplyScaleParty(1.0)
        ClampToScreen(main)
        main.SetWidth(main, 620)
        main.SetHeight(main, 82 + MAX_ROWS * (SQ + 10) + 40)
        AutoFit()
    end)

    local scaleMinus = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    scaleMinus.SetWidth(scaleMinus, 20); scaleMinus.SetHeight(scaleMinus, 18)
    scaleMinus.SetPoint(scaleMinus, "RIGHT", drag, "RIGHT", -60, 0)
    scaleMinus.SetText(scaleMinus, "-")

    local scalePlus = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    scalePlus.SetWidth(scalePlus, 20); scalePlus.SetHeight(scalePlus, 18)
    scalePlus.SetPoint(scalePlus, "RIGHT", drag, "RIGHT", -35, 0)
    scalePlus.SetText(scalePlus, "+")

    scaleMinus.SetScript(scaleMinus, "OnClick", function() ApplyScaleParty(STATE.scale - 0.1) end)
    scalePlus.SetScript(scalePlus, "OnClick",  function() ApplyScaleParty(STATE.scale + 0.1) end)

    -- black content area (always click-through)
    local contentBG = CreateFrame("Frame", nil, main)
    contentBG.SetPoint(contentBG, "TOPLEFT", main, "TOPLEFT", 8, -32)
    contentBG.SetPoint(contentBG, "BOTTOMRIGHT", main, "BOTTOMRIGHT", -8, 32)
    SafeSetBackdrop(contentBG, 0.40)
    contentBG.EnableMouse(contentBG, false)

    local bottom = CreateFrame("Frame", nil, main)
    bottom.SetPoint(bottom, "BOTTOMLEFT", main, "BOTTOMLEFT", 0, 0)
    bottom.SetPoint(bottom, "BOTTOMRIGHT", main, "BOTTOMRIGHT", 0, 0)
    bottom.SetHeight(bottom, 26)
    SafeSetBackdrop(bottom, 0.85)
    bottom.EnableMouse(bottom, true)

    local nameLbl = bottom.CreateFontString(bottom, nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl.SetText(nameLbl, "Filters:")
    nameLbl.SetPoint(nameLbl, "LEFT", bottom, "LEFT", 8, 0)

    local nameEdit = CreateFrame("EditBox", addonName.."NameFilter", bottom, "InputBoxTemplate")
    nameEdit.SetAutoFocus(nameEdit, false)
    nameEdit.SetWidth(nameEdit, 210)
    nameEdit.SetHeight(nameEdit, 18)
    nameEdit.SetMaxLetters(nameEdit, 120)
    nameEdit.SetPoint(nameEdit, "LEFT", nameLbl, "RIGHT", 4, 0)
    nameEdit.SetText(nameEdit, "")
    if nameEdit.SetAltArrowKeyMode then nameEdit.SetAltArrowKeyMode(nameEdit, true) end

    local msgLbl = bottom.CreateFontString(bottom, nil, "OVERLAY", "GameFontNormalSmall")
    msgLbl.SetText(msgLbl, "Message:")
    msgLbl.SetPoint(msgLbl, "LEFT", nameEdit, "RIGHT", 10, 0)

    local msgEdit = CreateFrame("EditBox", addonName.."MsgBox", bottom, "InputBoxTemplate")
    msgEdit.SetAutoFocus(msgEdit, false)
    msgEdit.SetWidth(msgEdit, 260)
    msgEdit.SetHeight(msgEdit, 18)
    msgEdit.SetMaxLetters(msgEdit, 255)
    msgEdit.SetPoint(msgEdit, "LEFT", msgLbl, "RIGHT", 4, 0)
    msgEdit.SetText(msgEdit, "")
    if msgEdit.SetAltArrowKeyMode then msgEdit.SetAltArrowKeyMode(msgEdit, true) end

    local sendBtn = CreateFrame("Button", nil, bottom, "UIPanelButtonTemplate")
    sendBtn.SetWidth(sendBtn, 44); sendBtn.SetHeight(sendBtn, 18)
    sendBtn.SetPoint(sendBtn, "LEFT", msgEdit, "RIGHT", 6, 0)
    sendBtn.SetText(sendBtn, "Send")

    local function CreateSquareRow(parent)
        local row = CreateFrame("Frame", nil, parent)
        row.SetWidth(row, SQ + 2*(ORB+6)); row.SetHeight(row, SQ + 2*(ORB+6))
        row._mouseOff = nil
        row._bothDownAt = nil

        local unit = CreateFrame("Button", nil, row)
        unit.SetWidth(unit, SQ); unit.SetHeight(unit, SQ)
        unit.SetPoint(unit, "CENTER", row, "CENTER", 0, 0)
        unit.SetBackdrop(unit, {
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        unit.SetBackdropColor(unit, 0,0,0,0.8)

        unit.hpBG = unit.CreateTexture(unit, nil, "BORDER")
        unit.hpBG.SetPoint(unit.hpBG, "TOPLEFT", unit, "TOPLEFT", 3, -3)
        unit.hpBG.SetPoint(unit.hpBG, "BOTTOMRIGHT", unit, "BOTTOMRIGHT", -3, 3)
        unit.hpBG.SetTexture(unit.hpBG, 0.1,0.1,0.1,0.9)

        unit.hpFill = unit.CreateTexture(unit, nil, "ARTWORK")
        unit.hpFill.SetPoint(unit.hpFill, "TOPLEFT", unit.hpBG, "TOPLEFT", 0, 0)
        unit.hpFill.SetPoint(unit.hpFill, "BOTTOMLEFT", unit.hpBG, "BOTTOMLEFT", 0, 0)
        unit.hpFill.SetWidth(unit.hpFill, (SQ - 6))
        unit.hpFill.SetTexture(unit.hpFill, "Interface\\TargetingFrame\\UI-StatusBar")
        unit.hpFill.SetVertexColor(unit.hpFill, 0, 0.85, 0)

        unit.nameText = unit.CreateFontString(unit, nil, "OVERLAY", "GameFontHighlightSmall")
        unit.nameText.SetPoint(unit.nameText, "CENTER", unit, "CENTER", 0, 0)
        unit.nameText.SetWidth(unit.nameText, SQ - 10)
        unit.nameText.SetJustifyH(unit.nameText, "CENTER")
        unit.nameText.SetText(unit.nameText, "")

        unit.hpText = unit.CreateFontString(unit, nil, "OVERLAY", "GameFontNormalSmall")
        unit.hpText.SetPoint(unit.hpText, "BOTTOMRIGHT", unit, "BOTTOMRIGHT", -4, 2)
        unit.hpText.SetWidth(unit.hpText, SQ - 8)
        unit.hpText.SetJustifyH(unit.hpText, "RIGHT")
        unit.hpText.SetText(unit.hpText, "")

        unit.EnableMouse(unit, true)
        unit.RegisterForClicks(unit, "LeftButtonUp", "RightButtonUp")

        -- Double-click support on the main square
        unit.SetScript(unit, "OnClick", function(_, btn)
            if not unit.token or not UnitExists(unit.token) then return end

            local now = GetTime()
            local dbl = unit._lastClickTime and (now - unit._lastClickTime < 0.30) and (unit._lastClickBtn == btn)
            unit._lastClickTime = now
            unit._lastClickBtn  = btn

            if dbl then
                if type(PartyUnitDoubleClick) == "function" then
                    PartyUnitDoubleClick(unit.token, btn)
                else
                    TargetUnit(unit.token)
                end
                return
            end

            -- single click behavior (target with optional restore)
            local restore = (btn == "RightButton") or IsAltKeyDown()
            local had = UnitExists("target")
            local prev = had and UnitName("target") or nil
            TargetUnit(unit.token)
            if restore and had and prev and UnitName("target") ~= prev then
                TargetLastTarget()
                if UnitName("target") ~= prev then TargetByName(prev, true) end
            end
        end)

        local function CallPartyButton(idx)
            if     idx == 1  and type(PartyButton1 ) == "function" then PartyButton1 ()
            elseif idx == 2  and type(PartyButton2 ) == "function" then PartyButton2 ()
            elseif idx == 3  and type(PartyButton3 ) == "function" then PartyButton3 ()
            elseif idx == 4  and type(PartyButton4 ) == "function" then PartyButton4 ()
            elseif idx == 5  and type(PartyButton5 ) == "function" then PartyButton5 ()
            elseif idx == 6  and type(PartyButton6 ) == "function" then PartyButton6 ()
            elseif idx == 7  and type(PartyButton7 ) == "function" then PartyButton7 ()
            elseif idx == 8  and type(PartyButton8 ) == "function" then PartyButton8 ()
            elseif idx == 9  and type(PartyButton9 ) == "function" then PartyButton9 ()
            elseif idx == 10 and type(PartyButton10) == "function" then PartyButton10()
            elseif idx == 11 and type(PartyButton11) == "function" then PartyButton11()
            elseif idx == 12 and type(PartyButton12) == "function" then PartyButton12()
            elseif idx == 13 and type(PartyButton13) == "function" then PartyButton13()
            elseif idx == 14 and type(PartyButton14) == "function" then PartyButton14()
            elseif idx == 15 and type(PartyButton15) == "function" then PartyButton15()
            elseif idx == 16 and type(PartyButton16) == "function" then PartyButton16()
            end
        end

        local orbitHolder = CreateFrame("Frame", nil, row)
        orbitHolder.SetAllPoints(orbitHolder, row)
        orbitHolder.EnableMouse(orbitHolder, false)
        row.orbit = CreateOrbitButtons(orbitHolder, unit, ORBCNT, ORB, CallPartyButton)
        orbitHolder._ownerRow = row

        -- attach clickthrough to this row (main square + orbit buttons)
        row.unit = unit
        row._root = parent._root -- inherit
        AttachRowClickthrough(row, unit)

        return row
    end

    local lowLabel = drag.CreateFontString(drag, nil, "OVERLAY", "GameFontHighlightSmall")
    lowLabel.SetPoint(lowLabel, "LEFT", hpModeBtn, "RIGHT", 10, 0)
    lowLabel.SetText(lowLabel, "Lowest: -")

    local topAnchorY = -32
    local i = 1
    while i <= MAX_ROWS do
        local r = CreateSquareRow(main)
        r.SetPoint(r, "TOPLEFT", main, "TOPLEFT", 12, topAnchorY - (i-1)*(SQ + ORB + 34))
        STATE.rows[i] = r
        i = i + 1
    end

    local function UpdateQueryAndDirectives()
        local t = nameEdit.GetText(nameEdit) or ""
        STATE.parsedQuery = ParseQueryText(t)
        STATE.targeting   = parse_targeting_from_text(t)
        STATE.chatDir     = parse_chat_directive(t)
    end
    nameEdit.SetScript(nameEdit, "OnTextChanged", function() UpdateQueryAndDirectives() end)
    nameEdit.SetScript(nameEdit, "OnEnterPressed", function() nameEdit.ClearFocus(nameEdit) end)
    nameEdit.SetScript(nameEdit, "OnEscapePressed", function() nameEdit.ClearFocus(nameEdit) end)

    local function DrawRow(row, d)
        if not d then row.realName=nil; row.token=nil; row.Hide(row); return end
        local hp, mx = d.hp or 0, d.max or 1
        if mx <= 0 then mx = 1 end
        local pct = hp / mx
        row.unit.hpFill.SetWidth(row.unit.hpFill, (SQ - 6) * pct)
        row.unit.hpFill.SetVertexColor(row.unit.hpFill, 1 - pct, pct, 0)
        row.unit.nameText.SetText(row.unit.nameText, d.realName or "")
        row.unit.hpText.SetText(row.unit.hpText, FormatHPText(d, STATE.settings.showPercent))
        row.realName = d.realName
        row.token    = d.token
        row.unit.token = d.token
        row.Show(row)
    end

    local function SendMessage(msg)
        msg = Trim(msg or ""); if msg == "" then return end
        STATE.chatDir = parse_chat_directive(nameEdit.GetText(nameEdit) or "")
        local dir = STATE.chatDir
        if not dir then SendChatMessage(msg, "SAY"); return end
        if     dir.mode == "SAY"   then SendChatMessage(msg, "SAY")
        elseif dir.mode == "YELL"  then SendChatMessage(msg, "YELL")
        elseif dir.mode == "PARTY" then SendChatMessage(msg, "PARTY")
        elseif dir.mode == "RAID"  then SendChatMessage(msg, "RAID")
        elseif dir.mode == "WHISPER" then
            if dir.target and dir.target ~= "" then
                SendChatMessage(msg, "WHISPER", nil, dir.target)
            end
        end
    end
    local function doSend()
        local txt = msgEdit.GetText(msgEdit) or ""
        if txt ~= "" then SendMessage(txt) end
        msgEdit.ClearFocus(msgEdit)
    end
    msgEdit.SetScript(msgEdit, "OnEnterPressed", function() doSend() end)
    msgEdit.SetScript(msgEdit, "OnEscapePressed", function() msgEdit.ClearFocus(msgEdit) end)
    sendBtn.SetScript(sendBtn, "OnClick", function() doSend() end)

    local function RefreshAndDraw()
        local scanned = BuildGroupList("party")
        local list, L = {}, 0
        local i2 = 1
        while i2 <= table.getn(scanned) do
            local u = scanned[i2]
            if PassesAllFilters(u, STATE.parsedQuery, STATE.settings.comparePercent) then
                L = L + 1; list[L] = u; if L >= MAX_ROWS then break end
            end
            i2 = i2 + 1
        end

        local lowest = nil
        local j = 1
        while j <= L do
            local u = list[j]
            if not lowest or IsALowerThanB(u, lowest, STATE.settings.comparePercent) then lowest = u end
            j = j + 1
        end
        if lowest then
            if STATE.settings.comparePercent then
                local pct = math.floor(((lowest.hp or 0) * 100) / ((lowest.max and lowest.max > 0) and lowest.max or 1) + 0.5)
                lowLabel.SetText(lowLabel, "Lowest: "..(lowest.realName or "?").." ("..pct.."%)")
            else
                lowLabel.SetText(lowLabel, "Lowest: "..(lowest.realName or "?").." ("..(lowest.hp or 0)..")")
            end
        else
            lowLabel.SetText(lowLabel, "Lowest: -")
        end

        local k = 1
        while k <= MAX_ROWS do
            DrawRow(STATE.rows[k], list[k])
            k = k + 1
        end

        if STATE.targeting then
            local foundToken = nil
            local t = 1
            while t <= L do
                local u = list[t]
                local lc = string.lower(u.realName or "")
                if string.find(lc, STATE.targeting.nameLC, 1, true) then
                    if hp_matches_rule(u.hp, u.max, STATE.targeting.hp) then
                        foundToken = u.token; break
                    end
                end
                t = t + 1
            end
            if foundToken then TargetUnit(foundToken) end
        end
    end

    main.lastUpdate = 0
    main.SetScript(main, "OnUpdate", function()
        if GetTime() - main.lastUpdate < UPDATE_INTERVAL then
            if (not _LDOWN) and (not _RDOWN) and _HELD_ROW then ReArmAllRows(STATE.rows) end
            return
        end
        main.lastUpdate = GetTime()
        RefreshAndDraw()
        if (not _LDOWN) and (not _RDOWN) and _HELD_ROW then ReArmAllRows(STATE.rows) end
    end)

    main.SetScript(main, "OnShow", function() AutoFit() end)
    main.Hide(main)

    -- expose for toggler
    main._root       = main
    main._nt_drag    = drag
    main._nt_bottom  = bottom
    main._nt_rows    = STATE.rows

    return {
        frame = main,
        toggle = function() if main.IsShown(main) then main.Hide(main) else main.Show(main) end end
    }
end

---------------------------------------------------
-- RAID UI: 8x5 clusters (square + 16 orbit), resizable
---------------------------------------------------
local function CreateRaidUI(addonName, windowTitle)
    local STATE = {}
    STATE.settings     = NearbyTargetsSettings
    STATE.parsedQuery  = { terms = {}, op = "OR", below = nil, above = nil }
    STATE.targeting    = nil
    STATE.chatDir      = nil
    STATE._units       = {}
    STATE.scale        = NearbyTargetsSettings.raidScale or 1.0

    local UPDATE_INTERVAL = 0.5
    local COLS, ROWS = 8, 5
    local SQ       = NearbyTargetsSettings.raidSquare or 90
    local ORB      = NearbyTargetsSettings.orbitSize or 12
    local ORBCNT   = NearbyTargetsSettings.orbitCount or 16
    if ORBCNT < 8 then ORBCNT = 8 end
    local CLW, CLH = SQ + 2*(ORB+6), SQ + 2*(ORB+6)
    local GAP_X, GAP_Y = 12, 12

    local function GridSize()
        local w = COLS*CLW + (COLS-1)*GAP_X + 16
        local h = ROWS*CLH + (ROWS-1)*GAP_Y + 16
        return w, h
    end

    local main = CreateFrame("Frame", addonName.."Frame", UIParent)
    local baseW, baseH = GridSize()
    main.SetWidth(main, baseW + 24)
    main.SetHeight(main, baseH + 80)
    main.SetPoint(main, "CENTER", UIParent, "CENTER", 0, -40)
    main.SetMovable(main, true)
    -- Root shouldn't swallow clicks; drag bar handles moving
    main.EnableMouse(main, false)
    if main.EnableMouseWheel then main.EnableMouseWheel(main, true) end

    SafeSetBackdrop(main, 0.90)
    main.SetScale(main, STATE.scale)

    local function AutoFit()
        local sw, sh = UIParent.GetWidth(UIParent), UIParent.GetHeight(UIParent)
        local mw, mh = main.GetWidth(main) * STATE.scale, main.GetHeight(main) * STATE.scale
        local margin = 40
        local sx = (sw - margin) / mw
        local sy = (sh - margin) / mh
        local s = sx; if sy < s then s = sy end
        if s < 1.0 then
            STATE.scale = s
            NearbyTargetsSettings.raidScale = s
            main.SetScale(main, s)
            ClampToScreen(main)
        end
    end

    local drag = CreateFrame("Frame", nil, main)
    drag.SetPoint(drag, "TOPLEFT", main, "TOPLEFT", 0, 0)
    drag.SetPoint(drag, "TOPRIGHT", main, "TOPRIGHT", 0, 0)
    drag.SetHeight(drag, 24)
    drag.EnableMouse(drag, true)
    drag.RegisterForDrag(drag, "LeftButton")
    drag.SetScript(drag, "OnDragStart", function() main.StartMoving(main) end)
    drag.SetScript(drag, "OnDragStop",  function() main.StopMovingOrSizing(main) end)
    SafeSetBackdrop(drag, 0.85)

    local title = drag.CreateFontString(drag, nil, "OVERLAY", "GameFontNormal")
    title.SetPoint(title, "LEFT", drag, "LEFT", 8, 0)
    title.SetText(title, windowTitle.." (Per-unit square clusters)")

    local compareBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    compareBtn.SetWidth(compareBtn, 120); compareBtn.SetHeight(compareBtn, 18)
    compareBtn.SetPoint(compareBtn, "LEFT", title, "RIGHT", 12, 0)
    local function CompareLabel() return STATE.settings.comparePercent and "Compare: %HP" or "Compare: Raw HP" end
    compareBtn.SetText(compareBtn, CompareLabel())
    compareBtn.SetScript(compareBtn, "OnClick", function()
        STATE.settings.comparePercent = not STATE.settings.comparePercent
        compareBtn.SetText(compareBtn, CompareLabel())
    end)

    local hpModeBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    hpModeBtn.SetWidth(hpModeBtn, 90); hpModeBtn.SetHeight(hpModeBtn, 18)
    hpModeBtn.SetPoint(hpModeBtn, "LEFT", compareBtn, "RIGHT", 8, 0)
    local function HPLabel() return STATE.settings.showPercent and "HP Mode: %" or "HP Mode: Raw" end
    hpModeBtn.SetText(hpModeBtn, HPLabel())
    hpModeBtn.SetScript(hpModeBtn, "OnClick", function()
        STATE.settings.showPercent = not STATE.settings.showPercent
        hpModeBtn.SetText(hpModeBtn, HPLabel())
    end)

    local resetBtn = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    resetBtn.SetWidth(resetBtn, 50); resetBtn.SetHeight(resetBtn, 18)
    resetBtn.SetPoint(resetBtn, "LEFT", hpModeBtn, "RIGHT", 8, 0)
    resetBtn.SetText(resetBtn, "Reset")
    resetBtn.SetScript(resetBtn, "OnClick", function()
        STATE.scale = 1.0
        NearbyTargetsSettings.raidScale = 1.0
        main.SetScale(main, 1.0)
        local bw, bh = GridSize()
        main.SetWidth(main, bw + 24)
        main.SetHeight(main, bh + 80)
        AutoFit()
    end)

    local scaleMinus = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    scaleMinus.SetWidth(scaleMinus, 20); scaleMinus.SetHeight(scaleMinus, 18)
    scaleMinus.SetPoint(scaleMinus, "RIGHT", drag, "RIGHT", -48, 0)
    scaleMinus.SetText(scaleMinus, "-")

    local scalePlus = CreateFrame("Button", nil, drag, "UIPanelButtonTemplate")
    scalePlus.SetWidth(scalePlus, 20); scalePlus.SetHeight(scalePlus, 18)
    scalePlus.SetPoint(scalePlus, "RIGHT", drag, "RIGHT", -24, 0)
    scalePlus.SetText(scalePlus, "+")

    local function ApplyScale(s)
        if s < 0.6 then s = 0.6 end
        if s > 2.0 then s = 2.0 end
        STATE.scale = s
        NearbyTargetsSettings.raidScale = s
        main.SetScale(main, s)
    end
    scalePlus.SetScript(scalePlus, "OnClick", function()
        ApplyScale(STATE.scale + 0.1)
        ClampToScreen(main)
    end)
    scaleMinus.SetScript(scaleMinus, "OnClick", function()
        ApplyScale(STATE.scale - 0.1)
        ClampToScreen(main)
    end)

    main.SetScript(main, "OnMouseWheel", function()
        if IsControlKeyDown() then
            if arg1 > 0 then ApplyScale(STATE.scale + 0.05) else ApplyScale(STATE.scale - 0.05) end
        end
    end)

    MakeScaleGrip(main, ApplyScale, function() return STATE.scale end)

    local bottom = CreateFrame("Frame", nil, main)
    bottom.SetPoint(bottom, "BOTTOMLEFT", main, "BOTTOMLEFT", 0, 0)
    bottom.SetPoint(bottom, "BOTTOMRIGHT", main, "BOTTOMRIGHT", 0, 0)
    bottom.SetHeight(bottom, 26)
    SafeSetBackdrop(bottom, 0.85)
    bottom.EnableMouse(bottom, true)

    local nameLbl = bottom.CreateFontString(bottom, nil, "OVERLAY", "GameFontNormalSmall")
    nameLbl.SetText(nameLbl, "Filters:")
    nameLbl.SetPoint(nameLbl, "LEFT", bottom, "LEFT", 8, 0)

    local nameEdit = CreateFrame("EditBox", addonName.."NameFilter", bottom, "InputBoxTemplate")
    nameEdit.SetAutoFocus(nameEdit, false)
    nameEdit.SetWidth(nameEdit, 240)
    nameEdit.SetHeight(nameEdit, 18)
    nameEdit.SetMaxLetters(nameEdit, 120)
    nameEdit.SetPoint(nameEdit, "LEFT", nameLbl, "RIGHT", 4, 0)
    nameEdit.SetText(nameEdit, "")
    if nameEdit.SetAltArrowKeyMode then nameEdit.SetAltArrowKeyMode(nameEdit, true) end

    local msgLbl = bottom.CreateFontString(bottom, nil, "OVERLAY", "GameFontNormalSmall")
    msgLbl.SetText(msgLbl, "Msg:")
    msgLbl.SetPoint(msgLbl, "LEFT", nameEdit, "RIGHT", 10, 0)

    local msgEdit = CreateFrame("EditBox", addonName.."MsgBox", bottom, "InputBoxTemplate")
    msgEdit.SetAutoFocus(msgEdit, false)
    msgEdit.SetWidth(msgEdit, 260)
    msgEdit.SetHeight(msgEdit, 18)
    msgEdit.SetMaxLetters(msgEdit, 255)
    msgEdit.SetPoint(msgEdit, "LEFT", msgLbl, "RIGHT", 4, 0)
    msgEdit.SetText(msgEdit, "")
    if msgEdit.SetAltArrowKeyMode then msgEdit.SetAltArrowKeyMode(msgEdit, true) end

    local sendBtn = CreateFrame("Button", nil, bottom, "UIPanelButtonTemplate")
    sendBtn.SetWidth(sendBtn, 44); sendBtn.SetHeight(sendBtn, 18)
    sendBtn.SetPoint(sendBtn, "LEFT", msgEdit, "RIGHT", 6, 0)
    sendBtn.SetText(sendBtn, "Send")

    local function SendMessage(msg)
        msg = Trim(msg or ""); if msg == "" then return end
        STATE.chatDir = parse_chat_directive(nameEdit.GetText(nameEdit) or "")
        local dir = STATE.chatDir
        if not dir then SendChatMessage(msg, "SAY"); return end
        if     dir.mode == "SAY"   then SendChatMessage(msg, "SAY")
        elseif dir.mode == "YELL"  then SendChatMessage(msg, "YELL")
        elseif dir.mode == "PARTY" then SendChatMessage(msg, "PARTY")
        elseif dir.mode == "RAID"  then SendChatMessage(msg, "RAID")
        elseif dir.mode == "WHISPER" then
            if dir.target and dir.target ~= "" then
                SendChatMessage(msg, "WHISPER", nil, dir.target)
            else
                local seen, me = {}, UnitName("player")
                local i2 = 1
                while i2 <= table.getn(STATE._units) do
                    local u = STATE._units[i2]
                    if u and u.utype == "Player" then
                        local nm = u.realName
                        if nm and nm ~= "" and nm ~= me and not seen[nm] then
                            seen[nm] = true
                            SendChatMessage(msg, "WHISPER", nil, nm)
                        end
                    end
                    i2 = i2 + 1
                end
            end
        end
    end
    local function doSend()
        local txt = msgEdit.GetText(msgEdit) or ""
        if txt ~= "" then SendMessage(txt) end
        msgEdit.ClearFocus(msgEdit)
    end
    msgEdit.SetScript(msgEdit, "OnEnterPressed", function() doSend() end)
    msgEdit.SetScript(msgEdit, "OnEscapePressed", function() msgEdit.ClearFocus(msgEdit) end)
    sendBtn.SetScript(sendBtn, "OnClick", function() doSend() end)

    local function CallRaidButton(idx)
        if     idx == 1  and type(RaidButton1 ) == "function" then RaidButton1 ()
        elseif idx == 2  and type(RaidButton2 ) == "function" then RaidButton2 ()
        elseif idx == 3  and type(RaidButton3 ) == "function" then RaidButton3 ()
        elseif idx == 4  and type(RaidButton4 ) == "function" then RaidButton4 ()
        elseif idx == 5  and type(RaidButton5 ) == "function" then RaidButton5 ()
        elseif idx == 6  and type(RaidButton6 ) == "function" then RaidButton6 ()
        elseif idx == 7  and type(RaidButton7 ) == "function" then RaidButton7 ()
        elseif idx == 8  and type(RaidButton8 ) == "function" then RaidButton8 ()
        elseif idx == 9  and type(RaidButton9 ) == "function" then RaidButton9 ()
        elseif idx == 10 and type(RaidButton10) == "function" then RaidButton10()
        elseif idx == 11 and type(RaidButton11) == "function" then RaidButton11()
        elseif idx == 12 and type(RaidButton12) == "function" then RaidButton12()
        elseif idx == 13 and type(RaidButton13) == "function" then RaidButton13()
        elseif idx == 14 and type(RaidButton14) == "function" then RaidButton14()
        elseif idx == 15 and type(RaidButton15) == "function" then RaidButton15()
        elseif idx == 16 and type(RaidButton16) == "function" then RaidButton16()
        end
    end

    local function CreateCluster(parent)
        local f = CreateFrame("Frame", nil, parent)
        f.Hide(f)  -- start hidden; only shown by SetUnitData(d) when d exists

        f.SetWidth(f, CLW); f.SetHeight(f, CLH)
        f._mouseOff = nil
        f._bothDownAt = nil

        local unit = CreateFrame("Button", nil, f)
        unit.SetWidth(unit, SQ); unit.SetHeight(unit, SQ)
        unit.SetPoint(unit, "CENTER", f, "CENTER", 0, 0)
        unit.SetBackdrop(unit, {
            bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        unit.SetBackdropColor(unit, 0,0,0,0.8)

        unit.hpBG = unit.CreateTexture(unit, nil, "BORDER")
        unit.hpBG.SetPoint(unit.hpBG, "TOPLEFT", unit, "TOPLEFT", 3, -3)
        unit.hpBG.SetPoint(unit.hpBG, "BOTTOMRIGHT", unit, "BOTTOMRIGHT", -3, 3)
        unit.hpBG.SetTexture(unit.hpBG, 0.1,0.1,0.1,0.9)

        unit.hpFill = unit.CreateTexture(unit, nil, "ARTWORK")
        unit.hpFill.SetPoint(unit.hpFill, "TOPLEFT", unit.hpBG, "TOPLEFT", 0, 0)
        unit.hpFill.SetPoint(unit.hpFill, "BOTTOMLEFT", unit.hpBG, "BOTTOMLEFT", 0, 0)
        unit.hpFill.SetWidth(unit.hpFill, (SQ - 6))
        unit.hpFill.SetTexture(unit.hpFill, "Interface\\TargetingFrame\\UI-StatusBar")
        unit.hpFill.SetVertexColor(unit.hpFill, 0, 0.85, 0)

        unit.nameText = unit.CreateFontString(unit, nil, "OVERLAY", "GameFontHighlightSmall")
        unit.nameText.SetPoint(unit.nameText, "CENTER", unit, "CENTER", 0, 0)
        unit.nameText.SetWidth(unit.nameText, SQ - 10)
        unit.nameText.SetJustifyH(unit.nameText, "CENTER")
        unit.nameText.SetText(unit.nameText, "")

        unit.hpText = unit.CreateFontString(unit, nil, "OVERLAY", "GameFontNormalSmall")
        unit.hpText.SetPoint(unit.hpText, "BOTTOMRIGHT", unit, "BOTTOMRIGHT", -4, 2)
        unit.hpText.SetWidth(unit.hpText, SQ - 8)
        unit.hpText.SetJustifyH(unit.hpText, "RIGHT")
        unit.hpText.SetText(unit.hpText, "")

        unit.EnableMouse(unit, true)
        unit.RegisterForClicks(unit, "LeftButtonUp", "RightButtonUp")

        -- Double-click support
        unit.SetScript(unit, "OnClick", function(_, btn)
            if not unit.token or not UnitExists(unit.token) then return end

            local now = GetTime()
            local dbl = unit._lastClickTime and (now - unit._lastClickTime < 0.30) and (unit._lastClickBtn == btn)
            unit._lastClickTime = now
            unit._lastClickBtn  = btn

            if dbl then
                if type(RaidUnitDoubleClick) == "function" then
                    RaidUnitDoubleClick(unit.token, btn)
                else
                    TargetUnit(unit.token)
                end
                return
            end

            local restore = (btn == "RightButton") or IsAltKeyDown()
            local had = UnitExists("target")
            local prev = had and UnitName("target") or nil
            TargetUnit(unit.token)
            if restore and had and prev and UnitName("target") ~= prev then
                TargetLastTarget()
                if UnitName("target") ~= prev then TargetByName(prev, true) end
            end
        end)

        f.unit = unit

        local orbits = CreateOrbitButtons(f, unit, ORBCNT, ORB, CallRaidButton)
        f.btn = orbits
        f.orbit = orbits
        f.EnableMouse(f, false)
        f._ownerRow = f

        f.SetUnitData = function(d)
            if not d then
                f.Hide(f)
                f.unit.token = nil
                return
            end
            local hp, mx = d.hp or 0, d.max or 1
            if mx <= 0 then mx = 1 end
            local pct = hp / mx
            f.unit.hpFill.SetWidth(f.unit.hpFill, (SQ - 6) * pct)
            f.unit.hpFill.SetVertexColor(f.unit.hpFill, 1 - pct, pct, 0)
            f.unit.nameText.SetText(f.unit.nameText, d.realName or "")
            f.unit.hpText.SetText(f.unit.hpText, FormatHPText(d, NearbyTargetsSettings.showPercent))
            f.unit.token = d.token
            f.Show(f)
        end

        -- attach clickthrough (cluster row: main square + orbit buttons)
        f._root = parent._root
        AttachRowClickthrough(f, unit)

        return f
    end

    local grid = CreateFrame("Frame", nil, main)
    grid.SetPoint(grid, "TOPLEFT", main, "TOPLEFT", 12, -32)
    grid.SetWidth(grid, baseW)
    grid.SetHeight(grid, baseH)
    SafeSetBackdrop(grid, 0.40)
    grid.EnableMouse(grid, false)   -- black grid area: always click-through
    grid._root = main

    local clusters = {}

    local r = 1
    while r <= ROWS do
        local c = 1
        while c <= COLS do
            local cl = CreateCluster(grid)
            local x = (c-1)*(CLW + GAP_X) + 8
            local y = - (r-1)*(CLH + GAP_Y) - 8
            cl.SetPoint(cl, "TOPLEFT", grid, "TOPLEFT", x, y)
            tappend(clusters, cl)
            c = c + 1
        end
        r = r + 1
    end
    local function HideAllClusters()
        local i = 1
        while clusters[i] do
            clusters[i].Hide(clusters[i])
            i = i + 1
        end
    end

    -- hide them on boot
    HideAllClusters()

    local lowLabel = drag.CreateFontString(drag, nil, "OVERLAY", "GameFontHighlightSmall")
    lowLabel.SetPoint(lowLabel, "LEFT", hpModeBtn, "RIGHT", 10, 0)
    lowLabel.SetText(lowLabel, "Lowest: -")

    local function UpdateQueryAndDirectives()
        local t = nameEdit.GetText(nameEdit) or ""
        STATE.parsedQuery = ParseQueryText(t)
        STATE.targeting   = parse_targeting_from_text(t)
        STATE.chatDir     = parse_chat_directive(t)
    end
    nameEdit.SetScript(nameEdit, "OnTextChanged", function() UpdateQueryAndDirectives() end)
    nameEdit.SetScript(nameEdit, "OnEnterPressed", function() nameEdit.ClearFocus(nameEdit) end)
    nameEdit.SetScript(nameEdit, "OnEscapePressed", function() nameEdit.ClearFocus(nameEdit) end)

    local function RefreshGrid()
        local scanned = BuildGroupList("raid")
        local list, L = {}, 0
        local i2 = 1
        while i2 <= table.getn(scanned) do
            local u = scanned[i2]
            if PassesAllFilters(u, STATE.parsedQuery, STATE.settings.comparePercent) then
                L = L + 1; list[L] = u; if L >= 40 then break end
            end
            i2 = i2 + 1
        end
        STATE._units = list
        if table.getn(list) == 0 then
            HideAllClusters()
            lowLabel.SetText(lowLabel, "Lowest: -")
            return
        end

        local lowest = nil
        local j = 1
        while j <= L do
            local u = list[j]
            if not lowest or IsALowerThanB(u, lowest, STATE.settings.comparePercent) then lowest = u end
            j = j + 1
        end
        if lowest then
            if STATE.settings.comparePercent then
                local mx = (lowest.max and lowest.max > 0) and lowest.max or 1
                local pct = math.floor( ((lowest.hp or 0) * 100) / mx + 0.5 )
                lowLabel.SetText(lowLabel, "Lowest: "..(lowest.realName or "?").." ("..pct.."%)")
            else
                lowLabel.SetText(lowLabel, "Lowest: "..(lowest.realName or "?").." ("..(lowest.hp or 0)..")")
            end
        else
            lowLabel.SetText(lowLabel, "Lowest: -")
        end

        local nC = table.getn(clusters)
        local k = 1
        while k <= nC do
            -- correct
            clusters[k].SetUnitData(list[k])

            k = k + 1
        end

        if STATE.targeting then
            local foundToken = nil
            local t = 1
            while t <= L do
                local u = list[t]
                local lc = string.lower(u.realName or "")
                if string.find(lc, STATE.targeting.nameLC, 1, true) then
                    if hp_matches_rule(u.hp, u.max, STATE.targeting.hp) then
                        foundToken = u.token; break
                    end
                end
                t = t + 1
            end
            if foundToken then TargetUnit(foundToken) end
        end
    end

    main.lastUpdate = 0
    main.SetScript(main, "OnUpdate", function()
        if GetTime() - main.lastUpdate < UPDATE_INTERVAL then
            if (not _LDOWN) and (not _RDOWN) and _HELD_ROW then ReArmAllRows(clusters) end
            return
        end
        main.lastUpdate = GetTime()
        RefreshGrid()
        if (not _LDOWN) and (not _RDOWN) and _HELD_ROW then ReArmAllRows(clusters) end
    end)

    main.SetScript(main, "OnShow", function() AutoFit() end)
    main.Hide(main)

    -- expose for toggler
    main._root        = main
    main._nt_drag     = drag
    main._nt_bottom   = bottom
    main._nt_clusters = clusters

    return {
        frame = main,
        toggle = function() if main.IsShown(main) then main.Hide(main) else main.Show(main) end end
    }
end

---------------------------------------------------
-- Create instances
---------------------------------------------------
local NT_PARTY = CreatePartyUI("NearbyTargetsParty", "Nearby Targets (Party)")
local NT_RAID  = CreateRaidUI ("NearbyTargetsRaid",  "Nearby Targets (Raid)")

---------------------------------------------------
-- Slash commands
---------------------------------------------------
SLASH_NEARBYTARGETSPARTY1 = "/ntparty"
SlashCmdList["NEARBYTARGETSPARTY"] = function() NT_PARTY.toggle() end

SLASH_NEARBYTARGETSRAID1 = "/ntraid"
SlashCmdList["NEARBYTARGETSRAID"] = function() NT_RAID.toggle() end

DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99NearbyTargets Square Grid loaded.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Black area is click-through; drag bar moves window.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Hold both mouse buttons ≥0.10s on a square/orbit to click-through temporarily.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00/ntparty — party squares; /ntraid — raid squares (8x5).|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Orbit buttons: same color, 16 per unit. Define PartyButton1..16 / RaidButton1..16 in macros.|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Double-click a unit square to trigger PartyUnitDoubleClick/RaidUnitDoubleClick (optional hooks).|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Compare toggle affects filters; HP Mode affects text (raw/%).|r")
DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Resize: bottom-right grip or Ctrl+MouseWheel (raid). Window auto-fits first time.|r")
