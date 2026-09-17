-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
--
-- Bracket racing: one ImGui popup to set the local player's dial.
-- SP: at strip POI (bracket); MP: when host starts heat and local dial is 0.
-- On confirm: SP = apply to racer data and run callback; MP = send to host (host applies and syncs to all).

local M = {}
M.dependencies = { "gameplay_drag_core", "gameplay_drag_saveSystem", "ui_imgui" }

local im = ui_imgui
local WINDOW_NAME = "Drag - Set Dial##DragDialSingle"
local DIAL_MIN = 0
local DIAL_MAX = 999
local DIAL_DEFAULT = 10
local DIAL_INPUT_LEN = 32

-- Single popup state: only one instance ever
local open = false
local vehicleId = nil
local onConfirm = nil
local inputBuf = nil
local drawing = false -- re-entrancy guard: only one draw per frame

local function getImportantTimerLabel(data)
  if not data then return "Dial" end
  local importantId = data.importantTimerId or "time_1_4"
  local timerConfig = data.timers or {}
  for _, t in ipairs(timerConfig) do
    local id = t.id or ("timer_" .. 0)
    if id == importantId then
      return (t.label and t.label ~= "") and t.label or id
    end
  end
  return importantId
end

local function getDefaultDialValue()
  local general = gameplay_drag_core
  if not general or not general.getData then return DIAL_DEFAULT end
  local data = general.getData()
  if not data then return DIAL_DEFAULT end
  local vehId = vehicleId
  if not vehId or vehId == -1 then return DIAL_DEFAULT end
  local save = gameplay_drag_saveSystem
  if save and save.getDialTimes and save.generateHashFromFile then
    local times = save.getDialTimes()
    local key = save.generateHashFromFile(vehId)
    local importantId = data.importantTimerId or "time_1_4"
    if key and times and times[key] then
      return times[key][importantId] or times[key].time_1_4 or DIAL_DEFAULT
    end
  end
  return DIAL_DEFAULT
end


function M.requestDial(vehId, callback)
  if open then return end
  if not vehId or vehId == -1 then return end
  open = true
  vehicleId = vehId
  onConfirm = callback
  local defaultStr = string.format("%.2f", getDefaultDialValue())
  inputBuf = im.ArrayChar(DIAL_INPUT_LEN, defaultStr)
end

local function close()
  open = false
  vehicleId = nil
  onConfirm = nil
  inputBuf = nil
end

local function parseInputValue()
  if not inputBuf then return nil end
  local str
  local ffi = rawget(_G, "ffi")
  if ffi and ffi.string then
    str = ffi.string(inputBuf)
  else
    str = ""
    for i = 0, DIAL_INPUT_LEN - 2 do
      local c = inputBuf[i]
      if c == nil or c == 0 or (type(c) == "string" and c == "\0") then break end
      str = str .. (type(c) == "number" and string.char(c) or tostring(c))
    end
  end
  str = str and str:match("^%s*(.-)%s*$") or ""
  return tonumber(str)
end

local function applyAndClose(val)
  local vehId = vehicleId
  local cb = onConfirm
  close()

  local general = gameplay_drag_core
  if not general then
    if type(cb) == "function" then cb(val) end
    return
  end

  local drag = general.getDragGamemode and general.getDragGamemode()
  local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()

  if isMP then
    local raceState = general.getRaceState and general.getRaceState()
    if raceState and raceState.id and drag.updateTimerValue then
      drag.updateTimerValue(raceState.id, vehId, "dial", val)
    end
  end
  -- SP: callback starts activity (racer created) then sets dial. MP: host applies from our update.

  if type(cb) == "function" then cb(val) end
end

local function draw()
  if not open or not inputBuf then return end
  if drawing then return end
  drawing = true
  local general = gameplay_drag_core
  if not general or not general.getData then
    drawing = false
    close()
    return
  end
  local data = general.getData()
  if not data or data.dragType ~= "bracketRace" then
    drawing = false
    close()
    return
  end

  local label = getImportantTimerLabel(data)
  local io = im.GetIO()
  local displayW = io.DisplaySize and io.DisplaySize.x or 1280
  local displayH = io.DisplaySize and io.DisplaySize.y or 720
  im.SetNextWindowPos(im.ImVec2(displayW * 0.5 - 140, displayH * 0.5 - 50), im.Cond_FirstUseEver)
  im.SetNextWindowSize(im.ImVec2(280, 140), im.Cond_FirstUseEver)
  local openPtr = im.BoolPtr(true)
  if not im.Begin(WINDOW_NAME, openPtr, im.WindowFlags_NoCollapse) then
    im.End()
    drawing = false
    return
  end

  im.Text("Your dial (" .. label .. "):")
  im.Spacing()
  im.SetNextItemWidth(-1)
  local changed = im.InputText("##dial", inputBuf, DIAL_INPUT_LEN, im.InputTextFlags_CharsDecimal)
  im.Spacing()

  if im.Button("Confirm", im.ImVec2(-1, 0)) or (changed and im.IsKeyPressed(im.Key_Enter)) then
    local val = parseInputValue()
    if not val or val < DIAL_MIN or val > DIAL_MAX then
      val = DIAL_DEFAULT
    end
    val = math.max(DIAL_MIN, math.min(DIAL_MAX, val))
    applyAndClose(val)
  end
  if im.Button("Close", im.ImVec2(-1, 0)) then
    close()
  end

  im.End()
  if openPtr and openPtr[0] == false then close() end
  drawing = false
end

-- Called only from core.lua (not from extension hook) so we draw once per frame.
function M.tick(dtReal, dtSim, dtRaw)
  if open then draw() end
end

return M
