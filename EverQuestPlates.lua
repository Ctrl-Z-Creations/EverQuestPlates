-- EverQuestPlates: a gold "!" and "x/y" at the left end of quest mobs' nameplates.
-- Which mobs: read from the unit's tooltip data (quest objective lines).
-- Counts: read live from the quest log, matched to the tooltip objective by text.

local ADDON = "EverQuestPlates"
local DEFAULTS = { enabled = true, pos = "left", x = 0, y = 0, scale = 1.0, showCount = true }
local POS_ALIASES = { left = "left", right = "right", middle = "middle", top = "middle", center = "middle" }

local db
local myName
local issecret = _G.issecretvalue

local function IsSecret(v)
  if not issecret then return false end
  local ok, sec = pcall(issecret, v)
  return ok and sec and true or false
end

---------------------------------------------------------------------------
-- Quest log: live objective counts
---------------------------------------------------------------------------
local liveObjectives = {}

-- "Ragged Timber Wolf slain: 3/8" / " - Ragged Timber Wolf slain: 0/8" / "0/5 Wolf Pelt"
-- -> "ragged timber wolf slain" / "wolf pelt"
local function StripObjective(text)
  if type(text) ~= "string" or IsSecret(text) then return nil end
  local s = text:lower():gsub("%d+%s*/%s*%d+", ""):gsub("^[%s%-]+", ""):gsub("[%s:]+$", "")
  s = s:gsub("^%s+", ""):gsub("%s+", " ")
  return s ~= "" and s or nil
end

local function BuildLiveObjectives()
  wipe(liveObjectives)
  local n = C_QuestLog.GetNumQuestLogEntries() or 0
  for i = 1, n do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then
      for _, o in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
        local key = StripObjective(o.text)
        if key then
          liveObjectives[key] = { cur = tonumber(o.numFulfilled), max = tonumber(o.numRequired),
                                  finished = o.finished and true or false }
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Tooltip data: is this mob needed, and for which objective?
---------------------------------------------------------------------------
local LT = (Enum and Enum.TooltipDataLineType) or {}
local LT_OBJ    = LT.QuestObjective or 8
local LT_TITLE  = LT.QuestTitle or 17
local LT_PLAYER = LT.QuestPlayer or 18

-- Returns cur, max of the first unfinished objective of ours, or nil.
local function GetNeededObjective(unit)
  local ok, data = pcall(C_TooltipInfo.GetUnit, unit)
  if not ok or not data or IsSecret(data) or type(data.lines) ~= "table" then return nil end

  local mine = true
  for _, line in ipairs(data.lines) do
    local t, text = line.type, line.leftText
    if not IsSecret(t) and not IsSecret(text) then
      if t == LT_TITLE then
        mine = true
      elseif t == LT_PLAYER then
        mine = (text == myName)          -- party member's progress follows
      elseif t == LT_OBJ and mine and type(text) == "string" then
        local live = liveObjectives[StripObjective(text) or ""]
        if live then
          if not live.finished then return live.cur, live.max end
        else
          -- No quest-log match: fall back to the tooltip's own numbers.
          local cur, max = text:match("(%d+)%s*/%s*(%d+)")
          cur, max = tonumber(cur), tonumber(max)
          if not (line.completed == true or (cur and max and cur >= max)) then return cur, max end
        end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Markers
---------------------------------------------------------------------------
local markers = {}      -- nameplate frame -> marker
local activeUnits = {}  -- visible nameplate unit tokens

-- Positions (x/y offsets are added on top of each):
--   left   = "! 0/8 [=====]"   right = "[=====] ! 0/8"   middle = centered above the name
local RIGHT_GAP = 22   -- clears the level badge on the right end of the bar

local function Anchor(m, plate)
  local uf = plate.UnitFrame
  local bar, name
  pcall(function()
    bar = uf and (uf.healthBar or uf.HealthBarsContainer)
    name = uf and uf.name
  end)
  local x, y = db.x, db.y
  m:ClearAllPoints()
  local ok
  if db.pos == "right" and bar then
    ok = pcall(m.SetPoint, m, "LEFT", bar, "RIGHT", RIGHT_GAP + x, y)
  elseif db.pos == "middle" and (name or bar) then
    ok = pcall(m.SetPoint, m, "BOTTOM", name or bar, "TOP", x, (name and 1 or 14) + y)
  elseif bar or name then
    ok = pcall(m.SetPoint, m, "RIGHT", bar or name, "LEFT", -3 + x, y)
  end
  if not ok then
    local fx = (db.pos == "right" and 70) or (db.pos == "middle" and 0) or -70
    local fy = (db.pos == "middle" and 20) or 0
    m:SetPoint("CENTER", plate, "CENTER", fx + x, fy + y)
  end
  m:SetScale(db.scale)
end

-- Size the marker to its text so every anchor hugs the "! 0/8" group exactly.
local function FitWidth(m)
  local w = m.bang:GetStringWidth() or 8
  local c = m.count:GetText()
  if c and c ~= "" then w = w + 2 + (m.count:GetStringWidth() or 0) end
  m:SetWidth(math.max(w, 1))
end

local function GetMarker(plate)
  local m = markers[plate]
  if not m then
    m = CreateFrame("Frame", nil, plate)
    m:SetSize(40, 24)
    m:SetFrameStrata("HIGH")
    m.bang = m:CreateFontString(nil, "OVERLAY")
    m.bang:SetFont(STANDARD_TEXT_FONT, 22, "OUTLINE")
    m.bang:SetPoint("LEFT", m, "LEFT", 0, 0)
    m.count = m:CreateFontString(nil, "OVERLAY")
    m.count:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    m.count:SetPoint("LEFT", m.bang, "RIGHT", 2, 0)
    m.count:SetTextColor(1, 1, 1)
    m.bang:SetTextColor(1, 0.82, 0)
    m.bang:SetText("!")
    m:Hide()
    markers[plate] = m
  end
  Anchor(m, plate)
  return m
end

local function UpdateUnit(unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local m = GetMarker(plate)

  local isPlayer = false
  pcall(function() isPlayer = UnitIsPlayer(unit) and true or false end)
  if not db.enabled or isPlayer then m:Hide(); return end

  local cur, max = GetNeededObjective(unit)
  if cur or max then
    m.count:SetText((db.showCount and cur and max) and (cur .. "/" .. max) or "")
    FitWidth(m)
    m:Show()
  else
    m:Hide()
  end
end

local function UpdateAll()
  for unit in pairs(activeUnits) do pcall(UpdateUnit, unit) end
end

local pending = false
local function QueueRefresh()
  if pending then return end
  pending = true
  C_Timer.After(0.15, function()
    pending = false
    BuildLiveObjectives()
    UpdateAll()
  end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
f:RegisterEvent("UI_INFO_MESSAGE")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON then return end
    EverQuestPlatesDB = EverQuestPlatesDB or {}
    db = EverQuestPlatesDB
    for k, v in pairs(DEFAULTS) do if db[k] == nil then db[k] = v end end
  elseif event == "PLAYER_LOGIN" then
    myName = UnitName("player")
    BuildLiveObjectives()
    C_Timer.NewTicker(1, function() pcall(function() BuildLiveObjectives(); UpdateAll() end) end)
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    if a1 and not IsSecret(a1) then activeUnits[a1] = true end
    pcall(UpdateUnit, a1)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    if a1 and not IsSecret(a1) then activeUnits[a1] = nil end
    local plate = C_NamePlate.GetNamePlateForUnit(a1)
    if plate and markers[plate] then markers[plate]:Hide() end
  elseif event == "UNIT_QUEST_LOG_CHANGED" then
    if a1 == "player" then QueueRefresh() end
  elseif event == "UI_INFO_MESSAGE" then
    if type(a2) == "string" and not IsSecret(a2) and a2:find("%d+/%d+") then QueueRefresh() end
  else -- QUEST_LOG_UPDATE, PLAYER_REGEN_ENABLED
    QueueRefresh()
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Print(msg) print("|cffffd100EverQuestPlates|r " .. msg) end

SLASH_EVERQUESTPLATES1 = "/eqp"
SlashCmdList.EVERQUESTPLATES = function(msg)
  local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(.-)$")
  local n = tonumber(arg)
  if POS_ALIASES[cmd] then arg, cmd = cmd, "pos" end   -- /eqp left|right|middle shortcuts
  if cmd == "pos" and POS_ALIASES[arg] then
    db.pos = POS_ALIASES[arg]; Print("position " .. db.pos)
  elseif cmd == "toggle" then
    db.enabled = not db.enabled; Print(db.enabled and "enabled" or "disabled")
  elseif cmd == "count" then
    db.showCount = not db.showCount; Print("count " .. (db.showCount and "shown" or "hidden"))
  elseif cmd == "x" and n then
    db.x = n; Print("X offset " .. n)
  elseif cmd == "y" and n then
    db.y = n; Print("Y offset " .. n)
  elseif cmd == "scale" and n and n >= 0.5 and n <= 3 then
    db.scale = n; Print("scale " .. n)
  elseif cmd == "reset" then
    for k, v in pairs(DEFAULTS) do db[k] = v end; Print("settings reset")
  else
    Print("commands:")
    print("  /eqp toggle  - turn markers on/off (now " .. (db.enabled and "on" or "off") .. ")")
    print("  /eqp left | right | middle - marker position (now " .. db.pos .. ")")
    print("  /eqp count   - show/hide the 0/8 count")
    print("  /eqp x <n>   - horizontal offset (now " .. db.x .. ", negative = further left)")
    print("  /eqp y <n>   - vertical offset (now " .. db.y .. ", negative = lower)")
    print("  /eqp scale <0.5-3> - marker size (now " .. db.scale .. ")")
    print("  /eqp reset   - restore defaults")
    return
  end
  QueueRefresh()
end
