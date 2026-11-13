-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function normalizeColor(color)
  if type(color) ~= "string" or color == "" then
    return nil
  end
  if string.byte(color, 1) ~= 35 then -- '#'
    return "#" .. color
  end
  return color
end

local function setButton(id, uiName, icon, color, ringValue, onClickCallback, remove, active)
  local players = {}
  for playerIndex in pairs(playerInfo.seatedPlayers or {}) do
    players[#players + 1] = playerIndex
  end
  table.sort(players)

  --print(string.format("id: %q, uiName: %q, icon: %q, ringvalue: %q, click: %q, remove: %q", id, uiName, icon, color, ringValue, onClickCallback, remove))
  guihooks.trigger(
    "ChangePowerTrainButtons",
    {
      id = id,
      players = players,
      tooltip = uiName,
      icon = icon,
      color = normalizeColor(color),
      ringValue = ringValue,
      onClick = onClickCallback,
      remove = remove,
      active = active,
    }
  )
end

local function updateButtons()
  powertrain.updateSimpleControlButtons()
  controller.updateSimpleControlButtons()
end

local function onReset()
end

local function onInit()
end

M.onInit = onInit
M.onReset = onReset

M.setButton = setButton
M.updateButtons = updateButtons

return M
