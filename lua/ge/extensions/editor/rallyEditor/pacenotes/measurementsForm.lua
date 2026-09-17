-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local geoPacenotes = require('/lua/ge/extensions/gameplay/rally/snaproad/geoPacenotes')

local M = {}
local showSection = false
local showDetailWindow = false

local function formatDistance(meters)
  if not meters then return "N/A" end
  return string.format("%.0fm", meters)
end

local function formatNumber(value, places)
  if type(value) ~= 'number' then return tostring(value) end
  return string.format("%." .. tostring(places or 3) .. "f", value)
end

local function tryField(value, key)
  local ok, result = pcall(function() return value[key] end)
  if ok then return result end
  return nil
end

local function vecText(value)
  if not value then return nil end
  local x = tryField(value, 'x')
  local y = tryField(value, 'y')
  local z = tryField(value, 'z')
  if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
    return string.format("[%.3f, %.3f, %.3f]", x, y, z)
  end
  return nil
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do table.insert(keys, key) end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function drawValue(label, value, depth)
  depth = depth or 0
  if depth > 8 then
    im.Text(tostring(label) .. ": <max depth>")
    return
  end

  local vec = vecText(value)
  if vec then
    im.Text(tostring(label) .. ": " .. vec)
    return
  end

  if type(value) ~= 'table' then
    im.Text(tostring(label) .. ": " .. formatNumber(value))
    return
  end

  if im.TreeNode1(tostring(label) .. "##measurementDetail" .. tostring(depth) .. tostring(value)) then
    for _, key in ipairs(sortedKeys(value)) do
      drawValue(key, value[key], depth + 1)
    end
    im.TreePop()
  end
end

local function intensityName(measurement)
  local intensity = measurement and measurement.intensity
  if not intensity then return nil end
  return intensity.label or intensity.text or intensity.id
end

local function measurementTypeForPacenote(pacenote)
  local corner = pacenote and pacenote.corner and pacenote:corner() or nil
  return geoPacenotes.normalizeMeasurementType(corner and corner.measurementType or nil)
end

local function measurementTypeLabel(measurementType)
  local def = geoPacenotes.measurementTypes[geoPacenotes.normalizeMeasurementType(measurementType)]
  return def and def.label or tostring(measurementType)
end

local function selectedMeasurement(pacenote)
  if pacenote and pacenote.selectedMeasurementVariant then
    return pacenote:selectedMeasurementVariant()
  end

  local measurements = pacenote and pacenote.measurements or {}
  local measurementType = measurementTypeForPacenote(pacenote)
  local variants = measurements.variants or {}
  return variants[measurementType] or variants[geoPacenotes.defaultMeasurementType] or measurements.corner1
end

local function adjustmentSummary(pacenote)
  local corner = pacenote and pacenote.corner and pacenote:corner() or nil
  if not corner then return nil end

  local parts = {}
  local riskIntensity = tonumber(corner.riskIntensity) or 0
  if riskIntensity > 0 then
    table.insert(parts, "more intensity risk")
  elseif riskIntensity < 0 then
    table.insert(parts, "less intensity risk")
  end

  local lengthMode = corner.lengthMode
  if lengthMode == 'longer' then
    table.insert(parts, "feels longer")
  elseif lengthMode == 'shorter' then
    table.insert(parts, "feels shorter")
  elseif lengthMode == 'skip' then
    table.insert(parts, "skip length")
  end

  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

local function refreshAfterMeasurementTypeChange(pacenote, pacenoteToolsWindow)
  local didMeasure = false
  if pacenoteToolsWindow and pacenoteToolsWindow.measureSelectedPacenote and pacenoteToolsWindow.pacenoteToolsState and pacenoteToolsWindow.pacenoteToolsState.snaproad then
    pacenoteToolsWindow:measureSelectedPacenote(true)
    didMeasure = true
  end

  if not didMeasure then
    if pacenote.applyMeasurements then
      pacenote:applyMeasurements()
    else
      pacenote:refreshStructured()
    end
  end
end

local function drawMeasurementTypeDropdown(pacenote, pacenoteToolsWindow)
  local corner = pacenote and pacenote.corner and pacenote:corner() or nil
  if not corner then return end

  local current = measurementTypeForPacenote(pacenote)
  im.SetNextItemWidth(180)
  if im.BeginCombo("Measurement Type##measurementType", measurementTypeLabel(current)) then
    for _, opt in ipairs(geoPacenotes.measurementTypeOptions()) do
      if im.Selectable1(opt.label, opt.id == current) then
        if opt.id == geoPacenotes.defaultMeasurementType then
          corner.measurementType = nil
        else
          corner.measurementType = opt.id
        end
        refreshAfterMeasurementTypeChange(pacenote, pacenoteToolsWindow)
        if pacenoteToolsWindow and pacenoteToolsWindow.markValidationDirty then
          pacenoteToolsWindow:markValidationDirty()
        end
      end
    end
    im.EndCombo()
  end
  im.tooltip("Controls which measured fit is used for projected corner text and visualization. Single fit is the default and is not stored in the notebook.")
end

local function drawSummary(pacenote)
  local measurement = selectedMeasurement(pacenote)
  if not measurement then
    im.TextColored(im.ImVec4(1, 0.5, 0, 1), "No measurement data available")
    im.Text("Measurements will appear after the pacenote is refreshed or selected.")
    return
  end

  im.Text("Showing: " .. measurementTypeLabel(measurement.measurementType or measurementTypeForPacenote(pacenote)))
  local adjustment = adjustmentSummary(pacenote)
  if adjustment then
    im.Text("Adjustment: " .. adjustment)
  end

  local titleParts = {}
  if intensityName(measurement) then table.insert(titleParts, intensityName(measurement)) end
  if measurement.direction then table.insert(titleParts, measurement.direction) end
  if #titleParts > 0 then
    im.PushFont3("cairo_semibold_large")
    im.Text(table.concat(titleParts, " "))
    im.PopFont()
  end

  im.Text(string.format(
    "Diameter %s | Arc %s | Chord %s",
    formatDistance(measurement.diameter),
    formatDistance(measurement.arcMeters or measurement.pointsLength or measurement.arcDistance),
    formatDistance(measurement.chordMeters or measurement.straightLineDistance)
  ))
  im.Text(string.format(
    "Angle %s | Fit %.3f",
    measurement.arcDegrees and string.format("%.0f°", measurement.arcDegrees) or "N/A",
    measurement.fitQuality or 0
  ))

  local hairpin = measurement.hairpinCandidate
  if hairpin then
    local color = hairpin.isCandidate and im.ImVec4(0.4, 1.0, 0.4, 1.0) or im.ImVec4(0.8, 0.8, 0.8, 1.0)
    im.TextColored(color, string.format("hairpin candidate: %s (%s/%s)", tostring(hairpin.isCandidate), tostring(hairpin.score), tostring(hairpin.maxScore)))
  end
end

local function drawDetailWindow(pacenote)
  if not showDetailWindow then return end

  local openPtr = im.BoolPtr(showDetailWindow)
  im.SetNextWindowSize(im.ImVec2(520, 640), im.Cond_FirstUseEver)
  local flags = im.WindowFlags_NoDocking
  if im.Begin("Measurement Details###pacenoteMeasurementDetails", openPtr, flags) then
    im.Text("Pacenote: " .. tostring(pacenote.name))
    im.Separator()
    drawValue("measurements", pacenote.measurements or {})
  end
  im.End()
  showDetailWindow = openPtr[0]
end

M.draw = function(pacenote, pacenoteToolsState, pacenoteToolsWindow)
  im.HeaderText("Measurements")
  if im.IsItemClicked() then
    showSection = not showSection
  end
  if not showSection then
    if pacenoteToolsState then pacenoteToolsState.showMeasurements = false end
    im.SameLine()
    im.HeaderText("(...)")
    drawDetailWindow(pacenote)
    return
  end
  if pacenoteToolsState then pacenoteToolsState.showMeasurements = true end

  if im.Button(showDetailWindow and "Hide Details" or "Details") then
    showDetailWindow = not showDetailWindow
  end
  local rallyEditor = pacenoteToolsWindow and pacenoteToolsWindow.rallyEditor or nil
  if rallyEditor and rallyEditor.toggleCalibrationWindow then
    im.SameLine()
    local calibrationOpen = rallyEditor.isCalibrationWindowOpen and rallyEditor.isCalibrationWindowOpen()
    if im.Button(calibrationOpen and "Hide Calibration" or "Calibration") then
      rallyEditor.toggleCalibrationWindow()
    end
  end
  im.Spacing()

  drawMeasurementTypeDropdown(pacenote, pacenoteToolsWindow)
  im.Spacing()

  drawSummary(pacenote)
  drawDetailWindow(pacenote)
end

M.clear = function()
end

return M