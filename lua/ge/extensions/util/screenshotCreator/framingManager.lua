-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local defaultModeId = "procedural"
local selectedModeId = defaultModeId

local function collectModes()
  local collected = {}
  extensions.hook("onScreenshotCreatorCollectFramingModes", collected)

  local modes = {}
  local seenIds = {}
  for _, mode in ipairs(collected) do
    if type(mode) == "table"
      and type(mode.id) == "string"
      and mode.id ~= ""
      and type(mode.resolve) == "function"
      and not seenIds[mode.id]
    then
      seenIds[mode.id] = true
      modes[#modes + 1] = mode
    end
  end

  table.sort(modes, function(a, b)
    local aOrder = tonumber(a.order) or math.huge
    local bOrder = tonumber(b.order) or math.huge
    if aOrder == bOrder then return a.id < b.id end
    return aOrder < bOrder
  end)
  return modes
end

local function findMode(modeId)
  for _, mode in ipairs(collectModes()) do
    if mode.id == modeId then return mode end
  end
end

local function normalizeSelectedMode()
  if not findMode(selectedModeId) then
    selectedModeId = defaultModeId
  end
  return selectedModeId
end

local function list()
  return collectModes()
end

local function getSelected()
  return normalizeSelectedMode()
end

local function setSelected(modeId)
  if type(modeId) ~= "string" or not findMode(modeId) then
    return false, "Unknown framing mode: " .. tostring(modeId)
  end
  selectedModeId = modeId
  return true
end

local function resolve(modeId, context)
  if type(modeId) == "table" and context == nil then
    context = modeId
    modeId = nil
  end

  modeId = modeId or getSelected()
  local mode = findMode(modeId)
  if not mode then
    return nil, "Unknown framing mode: " .. tostring(modeId)
  end
  if type(context) ~= "table" then
    return nil, "Framing context must be a table"
  end

  return mode.resolve(context)
end

local function serialize()
  return {selectedModeId = getSelected()}
end

local function deserialize(data)
  if type(data) ~= "table" then
    selectedModeId = defaultModeId
    return
  end

  local modeId = data.selectedModeId or data.framingModeId
  if modeId == nil and data.skipCustomCameras ~= nil then
    modeId = data.skipCustomCameras == false and "configured" or "procedural"
  end

  if type(modeId) == "string" and findMode(modeId) then
    selectedModeId = modeId
  else
    selectedModeId = defaultModeId
  end
end

M.list = list
M.get = getSelected
M.set = setSelected
M.getSelected = getSelected
M.setSelected = setSelected
M.resolve = resolve
M.serialize = serialize
M.deserialize = deserialize
M.migrateLegacyState = deserialize

M.listModes = list
M.getSelectedModeId = getSelected
M.setSelectedModeId = setSelected

M.onSerialize = serialize
M.onDeserialized = deserialize

return M
