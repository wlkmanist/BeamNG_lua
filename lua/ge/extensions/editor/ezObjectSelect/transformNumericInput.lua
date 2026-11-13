-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local digitKeys = {
  {im.GetKeyIndex(im.Key_0), im.GetKeyIndex(im.Key_Keypad0), "0"},
  {im.GetKeyIndex(im.Key_1), im.GetKeyIndex(im.Key_Keypad1), "1"},
  {im.GetKeyIndex(im.Key_2), im.GetKeyIndex(im.Key_Keypad2), "2"},
  {im.GetKeyIndex(im.Key_3), im.GetKeyIndex(im.Key_Keypad3), "3"},
  {im.GetKeyIndex(im.Key_4), im.GetKeyIndex(im.Key_Keypad4), "4"},
  {im.GetKeyIndex(im.Key_5), im.GetKeyIndex(im.Key_Keypad5), "5"},
  {im.GetKeyIndex(im.Key_6), im.GetKeyIndex(im.Key_Keypad6), "6"},
  {im.GetKeyIndex(im.Key_7), im.GetKeyIndex(im.Key_Keypad7), "7"},
  {im.GetKeyIndex(im.Key_8), im.GetKeyIndex(im.Key_Keypad8), "8"},
  {im.GetKeyIndex(im.Key_9), im.GetKeyIndex(im.Key_Keypad9), "9"}
}
local periodKey = im.GetKeyIndex(im.Key_Period)
local keypadPeriodKey = im.GetKeyIndex(im.Key_KeypadDecimal)
local minusKey = im.GetKeyIndex(im.Key_Minus)
local keypadMinusKey = im.GetKeyIndex(im.Key_KeypadSubtract)
local backspaceKey = im.GetKeyIndex(im.Key_Backspace)

function M.newState()
  return {text = "", active = false}
end

function M.clear(state)
  state.text = ""
  state.active = false
end

local function append(state, value)
  state.text = state.text .. value
  state.active = true
end

function M.update(state, ignoreTopRowFour)
  local changed = false
  for _, entry in ipairs(digitKeys) do
    local topRowPressed = not (ignoreTopRowFour and entry[3] == "4")
      and im.IsKeyPressed(entry[1])
    if topRowPressed or im.IsKeyPressed(entry[2]) then
      append(state, entry[3])
      changed = true
    end
  end

  if im.IsKeyPressed(periodKey) or im.IsKeyPressed(keypadPeriodKey) then
    if not string.find(state.text, ".", 1, true) then
      if state.text == "" or state.text == "-" then append(state, "0") end
      append(state, ".")
      changed = true
    end
  end

  if im.IsKeyPressed(minusKey) or im.IsKeyPressed(keypadMinusKey) then
    if string.sub(state.text, 1, 1) == "-" then
      state.text = string.sub(state.text, 2)
    else
      state.text = "-" .. state.text
    end
    state.active = true
    changed = true
  end

  if im.IsKeyPressed(backspaceKey) and state.text ~= "" then
    state.text = string.sub(state.text, 1, -2)
    state.active = state.text ~= ""
    changed = true
  end
  return changed
end

function M.value(state)
  if not state.active or state.text == "" or state.text == "-" or state.text == "." then
    return nil
  end
  return tonumber(state.text)
end

return M
