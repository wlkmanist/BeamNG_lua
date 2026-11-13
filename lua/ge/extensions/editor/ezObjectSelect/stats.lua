-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local selectionGeometry = require("editor/ezObjectSelect/selectionGeometry")

local values = {
  selections = 0,
  distance = 0,
  transforms = 0,
  rotates = 0,
  scales = 0,
  rRotates = 0,
  wheelRotates = 0,
  worldOperations = 0,
  localOperations = 0
}
local localSpace = false
local volumeDirty = true
local volumeSelection = {}
local volumeSelectionExists = {}
local cachedSelectedVolume = 0

local function percentages(first, second)
  local total = first + second
  if total <= 0 then return 0, 0 end
  return first / total * 100, second / total * 100
end

local function selectedVolume(selectedIds)
  selectedIds = selectedIds or {}
  local selectionMatches = not volumeDirty and #selectedIds == #volumeSelection
  if selectionMatches then
    for index, id in ipairs(selectedIds) do
      local obj = scenetree.findObjectById(id)
      if volumeSelection[index] ~= id
        or volumeSelectionExists[index] ~= (obj ~= nil)
        or obj and obj.isSubClassOf and obj:isSubClassOf("BeamNGVehicle") then
        selectionMatches = false
        break
      end
    end
  end
  if selectionMatches then return cachedSelectedVolume end

  table.clear(volumeSelection)
  table.clear(volumeSelectionExists)
  cachedSelectedVolume = 0
  for _, id in ipairs(selectedIds or {}) do
    local obj = scenetree.findObjectById(id)
    local objectVolume = selectionGeometry.getObjectVolume(obj)
    volumeSelection[#volumeSelection + 1] = id
    volumeSelectionExists[#volumeSelectionExists + 1] = obj ~= nil
    if objectVolume then cachedSelectedVolume = cachedSelectedVolume + objectVolume end
  end
  volumeDirty = false
  return cachedSelectedVolume
end

function M.activate(isLocal)
  localSpace = isLocal == true
  volumeDirty = true
end

function M.setCoordinateMode(isLocal)
  localSpace = isLocal == true
end

function M.recordSelection()
  values.selections = values.selections + 1
  volumeDirty = true
end

function M.recordOperation(operation, source, distance)
  volumeDirty = true
  if localSpace then
    values.localOperations = values.localOperations + 1
  else
    values.worldOperations = values.worldOperations + 1
  end
  if operation == "transform" then
    values.transforms = values.transforms + 1
    values.distance = values.distance + math.max(distance or 0, 0)
  elseif operation == "rotate" then
    values.rotates = values.rotates + 1
    if source == "r" then
      values.rRotates = values.rRotates + 1
    elseif source == "wheel" then
      values.wheelRotates = values.wheelRotates + 1
    end
  elseif operation == "scale" then
    values.scales = values.scales + 1
  end
end

function M.invalidateVolume()
  volumeDirty = true
end

local function reset()
  for name in pairs(values) do values[name] = 0 end
  volumeDirty = true
end

function M.draw(selectedIds)
  local worldPercent, localPercent = percentages(values.worldOperations, values.localOperations)
  local rPercent, wheelPercent = percentages(values.rRotates, values.wheelRotates)
  local hasSelection = selectedIds and #selectedIds > 0
  local volumeText = hasSelection and string.format("%.1f m^3", selectedVolume(selectedIds)) or ""

  im.Separator()
  im.HeaderText("Stats")
  im.TextUnformatted(string.format("Selected volume: %s", volumeText))
  im.TextUnformatted(string.format("Selections: %d", values.selections))
  im.TextUnformatted(string.format("Distance transformed: %.1f m", values.distance))
  im.TextUnformatted(string.format(
    "Transforms / rotates / scales: %d / %d / %d",
    values.transforms,
    values.rotates,
    values.scales))

  local coordTotal = values.worldOperations + values.localOperations
  local coordFraction = coordTotal > 0 and (values.worldOperations / coordTotal) or 0
  im.TextUnformatted("Coordinate operations:")
  im.ProgressBar(
    coordFraction,
    im.ImVec2(im.GetContentRegionAvailWidth(), 0),
    string.format("World %.1f%% / Local %.1f%%", worldPercent, localPercent))

  local rotateTotal = values.rRotates + values.wheelRotates
  local rotateFraction = rotateTotal > 0 and (values.rRotates / rotateTotal) or 0
  im.TextUnformatted("Rotation sessions:")
  im.ProgressBar(
    rotateFraction,
    im.ImVec2(im.GetContentRegionAvailWidth(), 0),
    string.format("R %.1f%% / Wheel %.1f%%", rPercent, wheelPercent))

  if im.Button("Reset Stats##resetStats") then reset() end
end

return M
