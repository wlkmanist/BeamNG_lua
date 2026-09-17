-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local calibrationOverrides = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/calibrationOverrides')
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local calibrationAnalysisExport = require('/lua/ge/extensions/editor/rallyEditor/pacenotes/calibrationAnalysisExport')

local M = {}

local plotHeight = 74
local plotPaddingX = 12
local segmentHeight = 16
local exportStatus = nil
local exportStatusOk = false
local exportV2Status = nil
local exportV2StatusOk = false
local analysisSummary = nil
local analysisStatus = nil
local analysisStatusOk = false
local editingLengthIntensityName = nil

local function rgba(color)
  return im.GetColorU322(color)
end

local function rainbowU32(count, index, alpha)
  local color = rainbowColor(count, index, 1)
  return rgba(im.ImVec4(color[1], color[2], color[3], alpha or 1))
end

local function textWidth(text)
  return im.CalcTextSize(text).x
end

local function styleLabel(entry, fallback)
  if not entry then return fallback end
  if entry.label and entry.label ~= "" then return entry.label end
  if entry.visual and entry.visual.text and entry.visual.text ~= "" then return entry.visual.text end
  if entry.text and entry.text ~= "" then return entry.text end
  if entry.id and entry.id ~= "" then return entry.id end
  return fallback
end

local function styleNameLabel(entry, fallback)
  if not entry then return fallback end
  if entry.label and entry.label ~= "" then return entry.label end
  if entry.text and entry.text ~= "" then return entry.text end
  if entry.id and entry.id ~= "" then return entry.id end
  if entry.visual and entry.visual.text and entry.visual.text ~= "" then return entry.visual.text end
  return fallback
end

local function refreshPath(path)
  if not path then return end
  path.textCompositor = nil
  path.visualCompositor = nil
  path._offlineTextCompositor = nil
  path.pacenoteMetadataOfflineStructured = nil
  if path.refreshAllStructuredNotes then
    path:refreshAllStructuredNotes()
  end
  if path.cacheCompiledPacenotes then
    path:cacheCompiledPacenotes()
  end
end

local function saveBoundaries(missionDir, compositorName, groupName, key, list, boundaries, path)
  if not calibrationOverrides.validateBoundaries(boundaries, #list) then return false end
  if not calibrationOverrides.applyBoundariesToList(list, key, boundaries) then return false end
  if not calibrationOverrides.setBoundaries(missionDir, compositorName, groupName, key, boundaries) then return false end
  refreshPath(path)
  return true
end

local function displayMaxForBoundaries(boundaries)
  if not boundaries or #boundaries == 0 then return nil end
  local last = boundaries[#boundaries]
  local previous = boundaries[#boundaries - 1] or 0
  local span = math.max(1, last - previous)
  return math.max(last + span, last * 1.5, 1)
end

local function drawNumberLine(id, list, key, boundaries, terminalLabel)
  if not (list and boundaries and #boundaries >= 2) then return end

  local maxValue = displayMaxForBoundaries(boundaries)
  if maxValue <= 0 then return end

  local width = math.max(260, im.GetContentRegionAvailWidth())
  local cursor = im.GetCursorScreenPos()
  im.InvisibleButton("##" .. id .. "NumberLine", im.ImVec2(width, plotHeight))
  local drawList = im.GetWindowDrawList()

  local originX = cursor.x + plotPaddingX
  local originY = cursor.y + 28
  local plotWidth = width - (plotPaddingX * 2)
  local textColor = rgba(im.ImVec4(1, 1, 1, 1))
  local axisColor = rgba(im.ImVec4(0.85, 0.88, 0.95, 0.9))

  for i, entry in ipairs(list) do
    local x1 = originX + plotWidth * (boundaries[i] / maxValue)
    local x2 = originX + plotWidth * ((boundaries[i + 1] or maxValue) / maxValue)
    local color = rainbowU32(#list, i - 1, 0.90)
    im.ImDrawList_AddRectFilled(drawList, im.ImVec2(x1, originY), im.ImVec2(x2, originY + segmentHeight), color, 2)
    drawList:AddRect(im.ImVec2(x1, originY), im.ImVec2(x2, originY + segmentHeight), axisColor, 2, 0, 1)

    local label = styleLabel(entry, tostring(i))
    im.ImDrawList_AddText1(drawList, im.ImVec2(x1 + 4, originY - 22), textColor, label, nil)
  end

  local tickTop = originY + segmentHeight + 3
  local tickBottom = tickTop + 8
  for i, value in ipairs(boundaries) do
    local x = originX + plotWidth * (value / maxValue)
    drawList:AddLine(im.ImVec2(x, tickTop), im.ImVec2(x, tickBottom), axisColor, 1)
    local txt = tostring(math.floor(value + 0.5))
    local txtX = math.min(x - 8, originX + plotWidth - textWidth(txt))
    im.ImDrawList_AddText1(drawList, im.ImVec2(txtX, tickBottom + 2), textColor, txt, nil)
  end

  terminalLabel = terminalLabel or "shown max"
  im.ImDrawList_AddText1(drawList, im.ImVec2(originX + plotWidth - textWidth(terminalLabel), originY - 22), textColor, terminalLabel, nil)
end

local function drawBoundaryInputs(id, list, key, boundaries, missionDir, compositorName, groupName, path)
  local changed = false
  for i = 2, #list do
    local valuePtr = im.IntPtr(math.floor(boundaries[i] + 0.5))
    local fromLabel = styleNameLabel(list[i - 1], tostring(i - 1))
    local toLabel = styleNameLabel(list[i], tostring(i))
    local label = fromLabel .. " <> " .. toLabel .. " boundary"
    im.SetNextItemWidth(112)
    if im.InputInt(label .. "##" .. id .. tostring(i), valuePtr, 1, 5) then
      local newValue = math.floor(valuePtr[0] + 0.5)
      local minValue = boundaries[i - 1] + 1
      local maxValue = boundaries[i + 1] and (boundaries[i + 1] - 1) or nil
      if maxValue then
        newValue = math.min(maxValue, newValue)
      end
      newValue = math.max(minValue, newValue)
      boundaries[i] = newValue
      changed = true
    end
  end

  if changed then
    saveBoundaries(missionDir, compositorName, groupName, key, list, boundaries, path)
  end
end

local function drawCalibrationGroup(title, id, list, key, missionDir, compositorName, groupName, path)
  if not (list and #list > 0) then return end

  local boundaries = calibrationOverrides.boundariesFromList(list, key)
  if not boundaries then return end

  im.HeaderText(title)
  drawNumberLine(id, list, key, boundaries)
  im.Spacing()
  drawBoundaryInputs(id, list, key, boundaries, missionDir, compositorName, groupName, path)
  im.Spacing()
end

local function drawLengthInputs(intensityName, intensityLabel, list, boundaries, missionDir, compositorName, path)
  local displayName = intensityLabel or intensityName
  local changed = false
  for i = 2, #list do
    local valuePtr = im.IntPtr(math.floor(boundaries[i] + 0.5))
    local fromLabel = styleNameLabel(list[i - 1], tostring(i - 1))
    local toLabel = styleNameLabel(list[i], tostring(i))
    local label = tostring(displayName) .. " " .. fromLabel .. " <> " .. toLabel .. " boundary"
    im.SetNextItemWidth(112)
    if im.InputInt(label .. "##lengthsByIntensity" .. tostring(intensityName) .. tostring(i), valuePtr, 1, 5) then
      local newValue = math.floor(valuePtr[0] + 0.5)
      local minValue = boundaries[i - 1] + 1
      local maxValue = boundaries[i + 1] and (boundaries[i + 1] - 1) or nil
      if maxValue then
        newValue = math.min(maxValue, newValue)
      end
      newValue = math.max(minValue, newValue)
      boundaries[i] = newValue
      changed = true
    end
  end

  if changed and calibrationOverrides.applyBoundariesToList(list, 'arcMeters', boundaries) then
    calibrationOverrides.setLengthBoundaries(missionDir, compositorName, intensityName, boundaries)
    refreshPath(path)
  end

  im.Spacing()
end

local function orderedLengthIntensityNames(numbering, byIntensity)
  local names = {}
  local seen = {}
  for _, entry in ipairs(numbering.intensity or {}) do
    local name = entry.id
    if name and byIntensity[name] then
      table.insert(names, name)
      seen[name] = true
    end
  end

  local remaining = {}
  for name in pairs(byIntensity) do
    if not seen[name] then
      table.insert(remaining, name)
    end
  end
  table.sort(remaining)
  for _, name in ipairs(remaining) do
    table.insert(names, name)
  end

  return names
end

local function drawLengthByIntensity(numbering, missionDir, compositorName, path)
  local byIntensity = numbering and numbering.lengthsByIntensity
  if type(byIntensity) ~= 'table' then return end

  local labelsById = {}
  for _, entry in ipairs(numbering.intensity or {}) do
    if entry.id then
      labelsById[entry.id] = styleNameLabel(entry, entry.id)
    end
  end

  local names = orderedLengthIntensityNames(numbering, byIntensity)
  if #names == 0 then return end

  im.HeaderText("Corner length arc meters")

  if editingLengthIntensityName and not byIntensity[editingLengthIntensityName] then
    editingLengthIntensityName = nil
  end

  for _, name in ipairs(names) do
    local list = compositorUtil.cornerLengthList(numbering, name) or {}
    local boundaries = #list > 0 and calibrationOverrides.boundariesFromList(list, 'arcMeters') or nil
    if boundaries then
      local displayName = labelsById[name] or name
      im.Text(tostring(displayName))
      im.SameLine()
      if im.Button("Edit##lengthsByIntensityEdit" .. tostring(name)) then
        if editingLengthIntensityName == name then
          editingLengthIntensityName = nil
        else
          editingLengthIntensityName = name
        end
      end
      drawNumberLine("lengthsByIntensity" .. tostring(name), list, 'arcMeters', boundaries)
      if editingLengthIntensityName == name then
        drawLengthInputs(name, displayName, list, boundaries, missionDir, compositorName, path)
      else
        im.Spacing()
      end
    end
  end
end

local function drawExportTab(pacenotesWindow, path, missionDir, compositorName)
  im.Text("Style: " .. tostring(compositorName))
  im.Text("JSON: " .. tostring(calibrationAnalysisExport.exportFile(missionDir)))
  im.Text("JSON v2: " .. tostring(calibrationAnalysisExport.exportV2File(missionDir)))
  im.Spacing()
  if im.Button("Export Analysis JSON") then
    local ok, result = calibrationAnalysisExport.export(path, pacenotesWindow)
    exportStatusOk = ok == true
    if ok then
      exportStatus = "Exported: " .. tostring(result)
    else
      exportStatus = "Export failed: " .. tostring(result)
    end
  end

  if exportStatus then
    local statusColor = exportStatusOk and im.ImVec4(0.45, 1.0, 0.45, 1.0) or im.ImVec4(1.0, 0.45, 0.45, 1.0)
    im.TextColored(statusColor, exportStatus)
  end

  im.Spacing()
  if im.Button("Export Analysis JSON v2") then
    local ok, result = calibrationAnalysisExport.exportV2(path, pacenotesWindow)
    exportV2StatusOk = ok == true
    if ok then
      exportV2Status = "Exported: " .. tostring(result)
    else
      exportV2Status = "Export failed: " .. tostring(result)
    end
  end

  if exportV2Status then
    local statusColor = exportV2StatusOk and im.ImVec4(0.45, 1.0, 0.45, 1.0) or im.ImVec4(1.0, 0.45, 0.45, 1.0)
    im.TextColored(statusColor, exportV2Status)
  end
end

local function intensityEntryId(entry)
  if not entry then return nil end
  if entry.id and entry.id ~= "" then return entry.id end
  if entry.text and entry.text ~= "" then return entry.text end
  if entry.label and entry.label ~= "" then return entry.label end
  if entry.visual and entry.visual.text and entry.visual.text ~= "" then return entry.visual.text end
  return nil
end

local function analysisDirectionWords(corner)
  local words = { 'left', 'right' }
  local direction = corner and corner.direction or nil
  if direction then
    if direction[-1] then table.insert(words, direction[-1]) end
    if direction[1] then table.insert(words, direction[1]) end
  end
  return words
end

local function trim(value)
  if not value then return nil end
  return tostring(value):match("^%s*(.-)%s*$")
end

local function normalizeAnalysisText(value, directionWords)
  local text = trim(value)
  if not text or text == "" then return nil end

  text = text:lower():gsub("[^%w%s]", " "):gsub("%s+", " ")
  text = " " .. trim(text) .. " "
  for _, word in ipairs(directionWords or {}) do
    local normalizedWord = trim(tostring(word):lower():gsub("[^%w%s]", " "):gsub("%s+", " "))
    if normalizedWord and normalizedWord ~= "" then
      text = text:gsub(" " .. normalizedWord .. " ", " ")
    end
  end
  return trim(text:gsub("%s+", " "))
end

local function addIntensityCandidate(matcher, value, id, directionWords)
  local normalized = normalizeAnalysisText(value, directionWords)
  if normalized and normalized ~= "" then
    matcher[normalized] = id
  end
end

local function buildIntensityMatcher(numbering, corner)
  local matcher = {}
  local labelsById = {}
  local directionWords = analysisDirectionWords(corner)
  for _, entry in ipairs(numbering.intensity or {}) do
    local id = intensityEntryId(entry)
    if id then
      labelsById[id] = styleNameLabel(entry, id)
      addIntensityCandidate(matcher, id, id, directionWords)
      addIntensityCandidate(matcher, entry.text, id, directionWords)
      addIntensityCandidate(matcher, entry.label, id, directionWords)
      addIntensityCandidate(matcher, entry.visual and entry.visual.text, id, directionWords)
    end
  end
  return matcher, labelsById, directionWords
end

local function buildDescriptorMatcher(corner, directionWords)
  local matcher = {}
  local descriptors = corner and corner.descriptors or nil
  if not descriptors then return matcher end

  for key, entry in pairs(descriptors) do
    if type(key) == 'string' then
      addIntensityCandidate(matcher, key, key, directionWords)
      if type(entry) == 'table' then
        addIntensityCandidate(matcher, entry.text, key, directionWords)
        addIntensityCandidate(matcher, entry.label, key, directionWords)
        addIntensityCandidate(matcher, entry.visual and entry.visual.text, key, directionWords)
      elseif type(entry) == 'string' then
        addIntensityCandidate(matcher, entry, key, directionWords)
      end
    end
  end

  return matcher
end

local function matchIntensityText(value, matcher, directionWords)
  local normalized = normalizeAnalysisText(value, directionWords)
  if not normalized or normalized == "" then return nil end
  if matcher[normalized] then return matcher[normalized] end

  local padded = " " .. normalized .. " "
  for candidate, id in pairs(matcher) do
    if padded:find(" " .. candidate .. " ", 1, true) then
      return id
    end
  end
  return nil
end

local function selectedAnalysisMeasurement(entry)
  local measurements = entry and entry.measurements or {}
  local variants = measurements.variants or {}
  local selectedType = measurements.selectedType
  if selectedType and variants[selectedType] then return variants[selectedType] end
  return measurements.corner1 or variants.single
end

local function projectedIntensityId(entry, measurement, matcher, directionWords)
  local intensity = measurement and measurement.intensity or nil
  if type(intensity) == 'table' then
    if intensity.id and intensity.id ~= "" then return intensity.id end
    for _, key in ipairs({ 'text', 'label', 'visualText' }) do
      local matched = matchIntensityText(intensity[key], matcher, directionWords)
      if matched then return matched end
    end
  end

  local currentCornerLabels = entry and entry.currentCornerLabels or {}
  return matchIntensityText(currentCornerLabels.cornerCall, matcher, directionWords)
end

local function buildLengthMatcher(numbering)
  local matcher = {}
  local labelsById = {}
  for _, intEntry in ipairs(numbering.intensity or {}) do
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(numbering, intEntry.id) or {}) do
      local id = lengthEntry.id
      if id and not labelsById[id] then
        local label = compositorUtil.cornerLengthEntryLabel(lengthEntry)
        labelsById[id] = label
        local normalizedKey = normalizeAnalysisText(id)
        local normalizedLabel = normalizeAnalysisText(label)
        local normalizedText = normalizeAnalysisText(lengthEntry.text)
        if normalizedKey then matcher[normalizedKey] = id end
        if normalizedLabel then matcher[normalizedLabel] = id end
        if normalizedText then matcher[normalizedText] = id end
      end
    end
  end
  return matcher, labelsById
end

local function matchLengthText(value, matcher)
  local normalized = normalizeAnalysisText(value)
  if not normalized or normalized == "" then return nil end
  return matcher[normalized]
end

local function rangeContainsValue(range, value)
  value = tonumber(value)
  if type(range) ~= 'table' or not value then return false end

  local min = tonumber(range.min)
  if not min or value < min then return false end

  local max = tonumber(range.max)
  if max and value >= max then return false end

  return true
end

local function rangeDistance(range, value)
  value = tonumber(value)
  if type(range) ~= 'table' or not value then return nil end

  local min = tonumber(range.min)
  local max = tonumber(range.max)
  if min and value < min then return min - value, 'below' end
  if max and value >= max then return value - max, 'above' end
  return 0, 'inside'
end

local function rangeText(range)
  if type(range) ~= 'table' then return "unknown" end

  local min = tonumber(range.min)
  local max = tonumber(range.max)
  if min and max then return string.format("%.1f-%.1f", min, max) end
  if min then return string.format("%.1f+", min) end
  return "unknown"
end

local function formatNumber(value)
  value = tonumber(value)
  if not value then return "-" end
  return string.format("%.1f", value)
end

local function projectedLengthId(entry, measurement, projectedIntensity, numbering, matcher)
  local arcMeters = measurement and measurement.arcMeters
  if projectedIntensity and arcMeters then
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(numbering, projectedIntensity) or {}) do
      if rangeContainsValue(lengthEntry.arcMeters, arcMeters) then
        return lengthEntry.id
      end
    end
  end

  local currentCornerLabels = entry and entry.currentCornerLabels or {}
  return matchLengthText(currentCornerLabels.cornerLength, matcher)
end

local function orderedIntensityKeys(numbering, keySet)
  local out = {}
  local seen = {}
  for _, entry in ipairs(numbering.intensity or {}) do
    local id = intensityEntryId(entry)
    if id and keySet[id] then
      table.insert(out, id)
      seen[id] = true
    end
  end

  local remaining = {}
  for key in pairs(keySet) do
    if not seen[key] then
      table.insert(remaining, key)
    end
  end
  table.sort(remaining)
  for _, key in ipairs(remaining) do
    table.insert(out, key)
  end
  return out
end

local function orderedLengthKeys(numbering, keySet)
  local out = {}
  local seen = {}
  for _, intEntry in ipairs(numbering.intensity or {}) do
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(numbering, intEntry.id) or {}) do
      local key = lengthEntry.id
      if key and keySet[key] and not seen[key] then
        table.insert(out, key)
        seen[key] = true
      end
    end
  end

  local remaining = {}
  for key in pairs(keySet) do
    if not seen[key] then
      table.insert(remaining, key)
    end
  end
  table.sort(remaining)
  for _, key in ipairs(remaining) do
    table.insert(out, key)
  end
  return out
end

local function rangeForIntensity(numbering, intensityName)
  for _, entry in ipairs(numbering.intensity or {}) do
    if intensityEntryId(entry) == intensityName then
      return entry.diameter
    end
  end
  return nil
end

local function rangeForLength(numbering, intensityName, lengthName)
  local entry = compositorUtil.cornerLengthEntryById(numbering, intensityName, lengthName)
  return entry and entry.arcMeters or nil
end

local function newAnalysisDistribution(labelsById)
  return {
    rows = {},
    orderedTargets = {},
    labelsById = labelsById,
    labelled = 0,
    compared = 0,
    skippedNoProjection = 0,
  }
end

local function addAnalysisComparison(distribution, targetKeys, target, projected, detail)
  distribution.labelled = distribution.labelled + 1

  local row = distribution.rows[target]
  if not row then
    row = { target = target, total = 0, counts = {}, projectedKeys = {}, orderedProjected = {}, details = {} }
    distribution.rows[target] = row
    targetKeys[target] = true
  end

  if projected and projected ~= "" then
    row.total = row.total + 1
    row.counts[projected] = (row.counts[projected] or 0) + 1
    row.projectedKeys[projected] = true
    row.details[projected] = row.details[projected] or {}
    table.insert(row.details[projected], detail)
    distribution.compared = distribution.compared + 1
  else
    distribution.skippedNoProjection = distribution.skippedNoProjection + 1
  end
end

local function hasDescriptorLabel(labels, descriptorMatcher, directionWords)
  if not labels then return false end
  if labels.cornerDescriptor and labels.cornerDescriptor ~= "" then return true end

  for _, value in pairs(labels) do
    if matchIntensityText(value, descriptorMatcher, directionWords) then
      return true
    end
  end
  return false
end

local function analysisDetail(entry, value, targetRange, valueLabel, unit)
  local distance, direction = rangeDistance(targetRange, value)
  return {
    name = entry.name or entry.id or entry.pk or "?",
    value = value,
    valueLabel = valueLabel,
    unit = unit,
    targetRange = targetRange,
    distance = distance,
    direction = direction,
  }
end

local function buildAnalysisSummary(data, corner)
  local numbering = corner and (corner.numbering or corner) or {}
  local matcher, labelsById, directionWords = buildIntensityMatcher(numbering, corner)
  local descriptorMatcher = buildDescriptorMatcher(corner, directionWords)
  local lengthMatcher, lengthNamesById = buildLengthMatcher(numbering)
  local summary = {
    intensity = newAnalysisDistribution(labelsById),
    length = newAnalysisDistribution(lengthNamesById),
    skippedDescriptor = 0,
  }
  local intensityTargetKeys = {}
  local lengthTargetKeys = {}

  for _, entry in ipairs(data.pacenotes or {}) do
    local labels = entry.handLabels or {}
    if hasDescriptorLabel(labels, descriptorMatcher, directionWords) then
      summary.skippedDescriptor = summary.skippedDescriptor + 1
    else
      local measurement = selectedAnalysisMeasurement(entry)
      local projected = projectedIntensityId(entry, measurement, matcher, directionWords)

      local intensityTarget = labels.cornerIntensity
      if intensityTarget and intensityTarget ~= "" then
        intensityTarget = matchIntensityText(intensityTarget, matcher, directionWords) or intensityTarget
        addAnalysisComparison(
          summary.intensity,
          intensityTargetKeys,
          intensityTarget,
          projected,
          analysisDetail(entry, measurement and measurement.diameter, rangeForIntensity(numbering, intensityTarget), "diameter", "m")
        )
      end

      local lengthTarget = labels.cornerLength
      if lengthTarget and lengthTarget ~= "" then
        lengthTarget = matchLengthText(lengthTarget, lengthMatcher) or lengthTarget
        local projectedLength = projectedLengthId(entry, measurement, projected, numbering, lengthMatcher)
        local lengthIntensity = intensityTarget or projected
        addAnalysisComparison(
          summary.length,
          lengthTargetKeys,
          lengthTarget,
          projectedLength,
          analysisDetail(entry, measurement and measurement.arcMeters, rangeForLength(numbering, lengthIntensity, lengthTarget), "arc meters", "m")
        )
      end
    end
  end

  summary.intensity.orderedTargets = orderedIntensityKeys(numbering, intensityTargetKeys)
  for _, target in ipairs(summary.intensity.orderedTargets) do
    local row = summary.intensity.rows[target]
    row.orderedProjected = orderedIntensityKeys(numbering, row.projectedKeys)
  end

  summary.length.orderedTargets = orderedLengthKeys(numbering, lengthTargetKeys)
  for _, target in ipairs(summary.length.orderedTargets) do
    local row = summary.length.rows[target]
    row.orderedProjected = orderedLengthKeys(numbering, row.projectedKeys)
  end

  return summary
end

local function refreshAnalysis(path, pacenotesWindow, corner)
  local data, err = calibrationAnalysisExport.build(path, pacenotesWindow)
  if not data then
    analysisSummary = nil
    analysisStatusOk = false
    analysisStatus = "Analysis failed: " .. tostring(err)
    return
  end

  analysisSummary = buildAnalysisSummary(data, corner)
  analysisStatusOk = true
  analysisStatus = "Analysis refreshed."
end

local function drawAnalysisResultFragment(text, matchesTarget)
  local color = matchesTarget and im.ImVec4(0.45, 1.0, 0.45, 1.0) or im.ImVec4(1.0, 0.45, 0.45, 1.0)
  im.TextColored(color, text)
end

local function drawAnalysisDetailTooltip(details)
  if not im.IsItemHovered() then return end

  im.BeginTooltip()
  im.Text("Examples")
  for index, detail in ipairs(details or {}) do
    if index > 20 then
      im.Text(string.format("... %d more", #details - 20))
      break
    end

    local deltaText = "in range"
    if detail.distance and detail.distance > 0 then
      deltaText = string.format("%s by %s%s", detail.direction, formatNumber(detail.distance), detail.unit or "")
    elseif not detail.distance then
      deltaText = "target range unknown"
    end

    im.Text(string.format(
      "%s: %s %s%s, target %s, %s",
      tostring(detail.name),
      tostring(detail.valueLabel or "value"),
      formatNumber(detail.value),
      tostring(detail.unit or ""),
      rangeText(detail.targetRange),
      deltaText
    ))
  end
  im.EndTooltip()
end

local function drawAnalysisDistribution(title, distribution, emptyText, missingText)
  im.HeaderText(title)
  im.Text(string.format("Labelled corners: %d, compared: %d", distribution.labelled, distribution.compared))
  if distribution.skippedNoProjection > 0 then
    im.TextColored(im.ImVec4(1.0, 0.85, 0.35, 1.0), string.format("%s: %d", missingText, distribution.skippedNoProjection))
  end
  im.Spacing()

  if #distribution.orderedTargets == 0 then
    im.Text(emptyText)
    return
  end

  for _, target in ipairs(distribution.orderedTargets) do
    local row = distribution.rows[target]
    local targetLabel = distribution.labelsById[target] or target
    im.Text(string.format("%s (target, n=%d) -", tostring(targetLabel), row.total))
    im.SameLine()

    if row.total == 0 then
      im.Text("no projected data")
    else
      for index, projected in ipairs(row.orderedProjected) do
        if index > 1 then
          im.SameLine()
          im.Text(",")
          im.SameLine()
        end

        local count = row.counts[projected] or 0
        local percent = math.floor((count / row.total) * 100 + 0.5)
        local projectedLabel = distribution.labelsById[projected] or projected
        drawAnalysisResultFragment(string.format("%s (%d%%, n=%d)", tostring(projectedLabel), percent, count), projected == target)
        drawAnalysisDetailTooltip(row.details[projected])
      end
    end
  end
end

local function drawAnalysisSummary()
  if not analysisSummary then
    im.TextWrapped("Click Refresh Analysis to compare hand-labelled targets with projected buckets.")
    return
  end

  if analysisSummary.skippedDescriptor > 0 then
    im.TextColored(im.ImVec4(1.0, 0.85, 0.35, 1.0), string.format("Skipped descriptive pacenotes: %d", analysisSummary.skippedDescriptor))
  end

  drawAnalysisDistribution("Corner intensity", analysisSummary.intensity, "No corner intensity metadata found.", "Skipped without projected intensity")
  im.Separator()
  drawAnalysisDistribution("Corner length", analysisSummary.length, "No corner length metadata found.", "Skipped without projected length")
end

local function drawAnalysisTab(pacenotesWindow, path)
  local compositor = path:getTextCompositor()
  local config = compositor and compositor:getConfig() or nil
  local corner = config and config.componentTypes and config.componentTypes.corner or nil
  if not corner then
    im.Text("No active corner calibration is available.")
    return
  end

  if im.Button("Refresh Analysis") then
    refreshAnalysis(path, pacenotesWindow, corner)
  end
  if analysisStatus then
    local statusColor = analysisStatusOk and im.ImVec4(0.45, 1.0, 0.45, 1.0) or im.ImVec4(1.0, 0.45, 0.45, 1.0)
    im.TextColored(statusColor, analysisStatus)
  end
  im.Separator()
  drawAnalysisSummary()
end

local function drawCalibrationTab(path, missionDir, compositorName)
  im.Text("Style: " .. tostring(compositorName))
  im.Text("JSON: " .. tostring(calibrationOverrides.calibrationFile(missionDir)))
  im.Spacing()

  local compositor = path:getTextCompositor()
  local config = compositor and compositor:getConfig() or nil
  local corner = config and config.componentTypes and config.componentTypes.corner or nil
  local numbering = corner and corner.numbering or nil
  if corner and numbering then
    im.Separator()
    drawCalibrationGroup("Corner intensity diameter", "intensity", numbering.intensity, "diameter", missionDir, compositorName, "intensity", path)
    im.Separator()
    drawLengthByIntensity(numbering, missionDir, compositorName, path)
  else
    im.Text("No corner calibration available for this style.")
  end
end

function M.draw(rallyEditor, openPtr)
  if not (openPtr and openPtr[0]) then return end

  local pacenotesWindow = rallyEditor.getPacenotesWindow and rallyEditor.getPacenotesWindow()
  local path = pacenotesWindow and pacenotesWindow.path or nil
  if not path then return end

  local missionDir = path:getMissionDir()
  local compositorName = path:getActiveCompositorName()
  if not (missionDir and compositorName) then return end

  im.SetNextWindowSize(im.ImVec2(620, 720), im.Cond_FirstUseEver)
  local flags = im.WindowFlags_NoDocking
  if im.Begin("Pacenote Calibration###pacenoteCalibrationWindow", openPtr, flags) then
    if im.BeginTabBar("##pacenoteCalibrationTabs") then
      if im.BeginTabItem("Calibration") then
        drawCalibrationTab(path, missionDir, compositorName)
        im.EndTabItem()
      end
      if im.BeginTabItem("Analysis") then
        drawAnalysisTab(pacenotesWindow, path)
        im.EndTabItem()
      end
      if im.BeginTabItem("Export") then
        drawExportTab(pacenotesWindow, path, missionDir, compositorName)
        im.EndTabItem()
      end
      im.EndTabBar()
    end
  end
  im.End()
end

return M
