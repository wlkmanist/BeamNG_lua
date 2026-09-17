-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')

local M = {}

local fieldWidth = 220

local function displayLabel(entry, fallback)
  if not entry then return fallback end
  if entry.label and entry.label ~= "" then return entry.label end
  if entry.text and entry.text ~= "" then return entry.text end
  if entry.id and entry.id ~= "" then return entry.id end
  return fallback
end

local function ensureCalibrationMetadata(pacenote)
  pacenote.metadata = pacenote.metadata or {}
  pacenote.metadata.calibration = pacenote.metadata.calibration or {}
  return pacenote.metadata.calibration
end

local function setCalibrationValue(pacenote, key, value)
  if value == nil and not (pacenote.metadata and pacenote.metadata.calibration) then return end

  local calibration = ensureCalibrationMetadata(pacenote)
  calibration[key] = value

  if next(calibration) == nil then
    pacenote.metadata.calibration = nil
  end
end

local function drawDropdown(pacenote, key, label, options)
  if not options or #options == 0 then return end

  local calibration = pacenote.metadata and pacenote.metadata.calibration or {}
  local current = calibration[key]
  local currentLabel = "-"
  for _, option in ipairs(options) do
    if option.value == current then
      currentLabel = option.label
      break
    end
  end
  if currentLabel == "-" and current then currentLabel = current end

  im.SetNextItemWidth(fieldWidth)
  if im.BeginCombo("##calibrationMetadata" .. key, currentLabel) then
    if im.Selectable1("-", current == nil) then
      setCalibrationValue(pacenote, key, nil)
    end
    for _, option in ipairs(options) do
      local value = option.value
      if im.Selectable1(option.label, current == value) then
        setCalibrationValue(pacenote, key, value)
      end
    end
    im.EndCombo()
  end
  im.SameLine()
  im.Text(label)
end

local function buildIntensityOptions(cornerCfg)
  local out = {}
  for _, entry in ipairs(compositorUtil.cornerIntensityList(cornerCfg) or {}) do
    local value = compositorUtil.intensityEntryId(entry)
    if value and value ~= "" then
      table.insert(out, { label = displayLabel(entry, value), value = value })
    end
  end
  return out
end

local function buildDirectionOptions(cornerCfg)
  local out = {}
  local direction = cornerCfg and cornerCfg.direction
  if direction then
    if direction[-1] then table.insert(out, { label = direction[-1], value = direction[-1] }) end
    if direction[1] then table.insert(out, { label = direction[1], value = direction[1] }) end
  end
  return out
end

local function buildLengthOptions(cornerCfg)
  local out = {}
  local seen = {}
  for _, intEntry in ipairs(compositorUtil.cornerIntensityList(cornerCfg) or {}) do
    local intensityId = compositorUtil.intensityEntryId(intEntry)
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(cornerCfg, intensityId) or {}) do
      local id = lengthEntry.id
      if id and not seen[id] then
        seen[id] = true
        local label = compositorUtil.cornerLengthEntryLabel(lengthEntry)
        table.insert(out, { label = label, value = label })
      end
    end
  end
  return out
end

local function buildShapeOptions(cornerCfg)
  local out = {}
  local shapes = cornerCfg and cornerCfg.shapes
  if shapes then
    local keys = {}
    for k in pairs(shapes) do table.insert(keys, k) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local label = displayLabel(shapes[key], key)
      if label and label ~= "" then
        table.insert(out, { label = label, value = label })
      end
    end
  end
  return out
end

local function buildDescriptorOptions(cornerCfg)
  local out = {}
  local descriptors = cornerCfg and cornerCfg.descriptors
  if descriptors then
    local keys = {}
    for key in pairs(descriptors) do table.insert(keys, key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local label = displayLabel(descriptors[key], key)
      if label and label ~= "" then
        table.insert(out, { label = label, value = label })
      end
    end
  end
  return out
end

function M.draw(pacenote, pacenoteToolsWindow)
  if not (pacenote and pacenote.notebook) then return end
  if not (pacenote.notebook.metadata and pacenote.notebook.metadata.calibrationFields) then return end

  local compositor = pacenote.notebook:getTextCompositor()
  local config = compositor and compositor:getConfig()
  local cornerCfg = config and config.componentTypes and config.componentTypes.corner
  if not cornerCfg then return end

  im.Separator()
  im.HeaderText("Calibration Metadata")

  drawDropdown(pacenote, "cornerIntensity", "corner intensity", buildIntensityOptions(cornerCfg))
  drawDropdown(pacenote, "cornerDescriptor", "corner descriptor", buildDescriptorOptions(cornerCfg))
  drawDropdown(pacenote, "direction", "direction", buildDirectionOptions(cornerCfg))
  drawDropdown(pacenote, "cornerLength", "corner length", buildLengthOptions(cornerCfg))
  drawDropdown(pacenote, "shape", "shape", buildShapeOptions(cornerCfg))
end

return M
