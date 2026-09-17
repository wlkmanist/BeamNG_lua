-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local calibrationOverrides = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/calibrationOverrides')
local compositorUtil = require('/lua/ge/extensions/gameplay/rally/compositors/helpers/compositorUtil')
local geoPacenotes = require('/lua/ge/extensions/gameplay/rally/snaproad/geoPacenotes')
local Structured = require('/lua/ge/extensions/gameplay/rally/notebook/structured')

local M = {}

local logTag = 'calibrationAnalysisExport'
local exportBasename = 'calibrationAnalysis.json'
local exportV2Basename = 'calibrationAnalysis.v2.json'

local skipKeys = {
  diameterChange = true,
}

local function exportFile(missionDir)
  if not missionDir then return nil end
  return missionDir .. '/rally/' .. exportBasename
end
M.exportFile = exportFile

local function exportV2File(missionDir)
  if not missionDir then return nil end
  return missionDir .. '/rally/' .. exportV2Basename
end
M.exportV2File = exportV2File

local function roundNumber(value, places)
  if type(value) ~= 'number' then return value end
  local scale = 10 ^ (places or 3)
  return math.floor(value * scale + 0.5) / scale
end

local function tryField(value, key)
  local ok, result = pcall(function() return value[key] end)
  if ok then return result end
  return nil
end

local function vecToArray(value)
  if not value then return nil end
  local x = tryField(value, 'x')
  local y = tryField(value, 'y')
  local z = tryField(value, 'z')
  if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
    return {roundNumber(x), roundNumber(y), roundNumber(z)}
  end
  return nil
end

local function jsonCopy(value, depth)
  depth = depth or 0
  if depth > 12 then return nil end

  local valueType = type(value)
  if valueType == 'number' then return roundNumber(value) end
  if valueType == 'string' or valueType == 'boolean' then return value end
  if valueType == 'userdata' then return vecToArray(value) end
  if valueType ~= 'table' then return nil end

  local vec = vecToArray(value)
  if vec then return vec end

  local out = {}
  for key, child in pairs(value) do
    if not skipKeys[key] then
      local copiedKey = key
      if type(key) == 'number' or type(key) == 'string' then
        local copiedValue = jsonCopy(child, depth + 1)
        if copiedValue ~= nil then
          out[copiedKey] = copiedValue
        end
      end
    end
  end
  return out
end

local function copyRange(value)
  if type(value) ~= 'table' then return nil end
  local min = tonumber(value.min)
  if not min then return nil end
  local out = { min = roundNumber(min) }
  if value.max ~= nil then
    local max = tonumber(value.max)
    if not max then return nil end
    out.max = roundNumber(max)
  end
  return out
end

local function serializeVisualText(entry)
  if not entry then return nil end
  if entry.visual and entry.visual.text then return entry.visual.text end
  return nil
end

local function serializeIntensityEntry(entry)
  if type(entry) ~= 'table' then return nil end
  return {
    id = entry.id,
    text = entry.text,
    afterDirection = entry.afterDirection,
    label = entry.label,
    visualText = serializeVisualText(entry),
    diameter = copyRange(entry.diameter),
    hp = entry.hp == true,
  }
end

local function serializeLengthsByIntensity(lengthsByIntensity)
  if type(lengthsByIntensity) ~= 'table' then return nil end
  return jsonCopy(lengthsByIntensity)
end

local function serializeDirection(direction)
  if type(direction) ~= 'table' then return nil end
  return {
    left = direction[-1],
    right = direction[1],
    values = {
      ['-1'] = direction[-1],
      ['1'] = direction[1],
    },
  }
end

local function serializeDescriptors(descriptors)
  if type(descriptors) ~= 'table' then return nil end
  local out = {}
  for key, entry in pairs(descriptors) do
    if type(key) == 'string' then
      if type(entry) == 'table' then
        out[key] = {
          text = entry.text,
          visualText = serializeVisualText(entry),
        }
      elseif type(entry) == 'string' then
        out[key] = {text = entry}
      end
    end
  end
  return out
end

local function serializeShapes(shapes)
  if type(shapes) ~= 'table' then return nil end
  local out = {}
  for key, entry in pairs(shapes) do
    if type(key) == 'string' then
      if type(entry) == 'table' then
        out[key] = {
          text = entry.text,
          visualText = serializeVisualText(entry),
        }
      elseif type(entry) == 'string' then
        out[key] = {text = entry}
      end
    end
  end
  return out
end

local function serializeCurrentCalibration(corner)
  if not corner then return nil end
  local numbering = corner.numbering or corner

  local intensity = {}
  for _, entry in ipairs(numbering.intensity or {}) do
    table.insert(intensity, serializeIntensityEntry(entry))
  end

  return {
    corner = {
      intensity = intensity,
      lengthsByIntensity = serializeLengthsByIntensity(numbering.lengthsByIntensity),
      direction = serializeDirection(corner.direction),
      descriptors = serializeDescriptors(corner.descriptors),
      shapes = serializeShapes(corner.shapes),
    },
  }
end

local function serializeOverrideData(missionDir, compositorName)
  local data = calibrationOverrides.load(missionDir)
  local style = data and data.styles and data.styles[compositorName] or nil
  return {
    file = calibrationOverrides.calibrationFile(missionDir),
    activeStyleOverrides = jsonCopy(style) or {},
  }
end

local function compactMeasurement(measurement)
  if type(measurement) ~= 'table' then return nil end

  return {
    radius = jsonCopy(measurement.radius),
    diameter = jsonCopy(measurement.diameter),
    arcDistance = jsonCopy(measurement.arcDistance),
    arcDegrees = jsonCopy(measurement.arcDegrees),
    arcMeters = jsonCopy(measurement.arcMeters),
    chordMeters = jsonCopy(measurement.chordMeters),
    straightLineDistance = jsonCopy(measurement.straightLineDistance),
    fitQuality = jsonCopy(measurement.fitQuality),
    pointsLength = jsonCopy(measurement.pointsLength),
    direction = jsonCopy(measurement.direction),
    intensity = serializeIntensityEntry(measurement.intensity),
    hairpinCandidate = jsonCopy(measurement.hairpinCandidate),
    center = vecToArray(measurement.center),
    p1 = vecToArray(measurement.p1),
    p2 = vecToArray(measurement.p2),
    p3 = vecToArray(measurement.p3),
  }
end

local function compactVariant(variant)
  if type(variant) ~= 'table' then return nil end

  local out = compactMeasurement(variant) or {}
  out.measurementType = jsonCopy(variant.measurementType)
  out.segmentCount = jsonCopy(variant.segmentCount)
  out.totalPointsLength = jsonCopy(variant.totalPointsLength)
  out.splitPoint = vecToArray(variant.splitPoint)
  out.splitPoints = {}
  for _, splitPoint in ipairs(variant.splitPoints or {}) do
    table.insert(out.splitPoints, vecToArray(splitPoint))
  end
  out.segments = {}
  for _, segment in ipairs(variant.segments or {}) do
    table.insert(out.segments, compactMeasurement(segment))
  end

  return out
end

local function compactVariants(variants)
  if type(variants) ~= 'table' then return nil end
  return {
    single = compactVariant(variants.single),
    split2 = compactVariant(variants.split2),
    split3 = compactVariant(variants.split3),
  }
end

local function serializeMeasurements(measurements)
  if type(measurements) ~= 'table' then return {} end
  return {
    selectedType = jsonCopy(measurements.selectedType),
    variants = compactVariants(measurements.variants),
    corner1 = compactMeasurement(measurements.corner1),
    corner2 = compactMeasurement(measurements.corner2),
    splitPoint = vecToArray(measurements.splitPoint),
    totalPointsLength = jsonCopy(measurements.totalPointsLength),
    hairpinCandidate = jsonCopy(measurements.hairpinCandidate),
    diagnostics = jsonCopy(measurements.diagnostics),
  }
end

local function metadataLabels(pn)
  local calibration = pn.metadata and pn.metadata.calibration or {}
  return {
    cornerIntensity = calibration.cornerIntensity,
    cornerDescriptor = calibration.cornerDescriptor,
    direction = calibration.direction,
    cornerLength = calibration.cornerLength,
    shape = calibration.shape,
  }
end

local function authoredAdjustments(pn)
  local corner = pn.corner and pn:corner() or nil
  local riskIntensity = tonumber(corner and corner.riskIntensity) or 0
  local lengthMode = corner and corner.lengthMode or nil
  return {
    riskIntensity = riskIntensity,
    riskIntensityLabel = riskIntensity > 0 and 'more risk' or (riskIntensity < 0 and 'less risk' or 'normal'),
    lengthMode = lengthMode,
    lengthModeLabel = lengthMode == 'longer' and 'feels longer' or (lengthMode == 'shorter' and 'feels shorter' or (lengthMode == 'skip' and 'skip length' or 'normal')),
  }
end

local function hasAnyMetadata(labels)
  for _, value in pairs(labels or {}) do
    if value ~= nil and value ~= '' then return true end
  end
  return false
end

local function structuredItems(pn)
  if not pn.structured then return {} end
  return jsonCopy(Structured.slotItems(pn.structured)) or {}
end

local function actualCornerLabels(pn, cornerCfg)
  local structured = pn.structuredForProjection and pn:structuredForProjection() or pn.structured
  local corner = Structured.slotItem(structured, 4)
  if corner and corner.type ~= 'corner' then corner = nil end
  if not (corner and cornerCfg) then return {} end

  local cornerCall = compositorUtil.getCornerCall(cornerCfg, corner)
  local lengthStr = compositorUtil.getCornerLengthForItem(cornerCfg, corner)
  local shapeStr = compositorUtil.getCornerShape(cornerCfg, corner.shape)
  return {
    cornerCall = cornerCall,
    cornerLength = lengthStr,
    cornerShape = shapeStr,
  }
end

local function compositedPreview(pn)
  if not (pn and pn.noteOutputPreview) then return nil end
  local ok, result = pcall(function() return pn:noteOutputPreview() end)
  if ok then return result end
  return nil
end

local function waypointContext(pn)
  local cs = pn.getCornerStartWaypoint and pn:getCornerStartWaypoint() or nil
  local ce = pn.getCornerEndWaypoint and pn:getCornerEndWaypoint() or nil
  local csPos = cs and cs.pos or nil
  local cePos = ce and ce.pos or nil
  local distance = nil
  if csPos and cePos then
    local ok, result = pcall(function() return vec3(csPos):distance(vec3(cePos)) end)
    if ok then distance = roundNumber(result) end
  end

  return {
    cornerStart = {
      id = cs and cs.id or nil,
      name = cs and cs.name or nil,
      pos = vecToArray(csPos),
    },
    cornerEnd = {
      id = ce and ce.id or nil,
      name = ce and ce.name or nil,
      pos = vecToArray(cePos),
    },
    straightLineDistance = distance,
  }
end

local function flags(pn)
  return {
    todo = pn.todo == true,
    ignoreDistanceCalls = pn.ignoreDistanceCalls == true,
    isolate = pn.isolate == true,
    hasCorner = pn.corner and pn:corner() ~= nil or false,
  }
end

local function measureForExport(pn, snaproad)
  if not (pn and snaproad and snaproad.setPartitionToPacenote) then
    return nil, 'snaproad unavailable'
  end

  local originalMeasurements = pn.measurements
  local originalHalfpoint = pn.halfpoint
  local originalHalfpointLocation = pn.halfpointLocation
  local originalHalfpointPos = pn.halfpointPos

  pn.measurements = {}

  local ok, err = pcall(function()
    snaproad:setPartitionToPacenote(pn)
    local focusPoints = snaproad.partition and snaproad.partition.focus_points or {}
    geoPacenotes.measurePartition(pn, focusPoints, true)
  end)

  local measurements = serializeMeasurements(pn.measurements)

  pn.measurements = originalMeasurements
  pn.halfpoint = originalHalfpoint
  pn.halfpointLocation = originalHalfpointLocation
  pn.halfpointPos = originalHalfpointPos

  if not ok then return measurements, tostring(err) end
  if not measurements.corner1 and not (measurements.variants and measurements.variants.single) then return measurements, 'not enough measurement data' end
  return measurements, nil
end

local function serializePacenote(pn, index, snaproad, cornerCfg)
  local labels = metadataLabels(pn)
  local measurements, measurementWarning = measureForExport(pn, snaproad)

  return {
    index = index,
    id = pn.id,
    pk = pn.pk,
    name = pn.name,
    hasHandLabels = hasAnyMetadata(labels),
    handLabels = labels,
    authoredAdjustments = authoredAdjustments(pn),
    structuredItems = structuredItems(pn),
    currentCornerLabels = actualCornerLabels(pn, cornerCfg),
    compositedTextPreview = compositedPreview(pn),
    measurements = measurements or {},
    measurementWarning = measurementWarning,
    waypoints = waypointContext(pn),
    flags = flags(pn),
  }
end

local function notebookIdentity(path, missionDir)
  return {
    name = path.name,
    id = path.id,
    file = path.fname,
    missionDir = missionDir,
    missionId = path.getMissionId and path:getMissionId() or nil,
    metadata = jsonCopy(path.metadata) or {},
  }
end

local function analysisInstructions()
  return {
    purpose = 'Analyze rally pacenote corner intensity and corner length calibration using hand-labelled reference labels, measured geometry, and the current effective compositor calibration.',
    requestedOutput = {
      'Suggest conservative changes to corner intensity diameter ranges and per-intensity corner length arc-meter ranges.',
      'Preserve adjacent numeric ranges: each finite range max should remain the next range min, and the final range should stay open-ended.',
      'Assign confidence levels to suggested threshold changes.',
      'Identify labelled examples that look like geometry, waypoint, or driveline outliers rather than calibration problems.',
      'Identify cases where more hand-labelled data, more routes, or additional measurements are needed before changing calibration.',
      'Call out special hairpin and descriptor cases separately from ordinary numeric threshold tuning.',
    },
    outOfScope = {
      'Do not make automatic shape changes. Opens/tightens are explicit corner.shape author data only.',
      'Do not decide whether saved notebook corner items should store measurement-derived values; that is a separate notebook format decision.',
    },
  }
end

local function schema()
  return {
    handLabels = 'Manual reference labels assigned in the Rally Editor. These are the target labels for calibration.',
    authoredAdjustments = 'Small authored interpretation shifts applied after measurement bucketization. riskIntensity changes the style-defined intensity call by one risk step; lengthMode controls corner length detail (shorter, normal, longer, or skip). Raw measurements remain unchanged.',
    structuredItems = 'Current canonical structured pacenote slot map from the notebook, keyed "1".."6" for caution, two pre modifiers, corner, and two post modifiers. Direction/intensity/arc values may be legacy projection cache data; prefer measurements for analysis.',
    currentCornerLabels = 'Current style-rendered labels for the existing corner item, including corner call, length, and confirmed shape when present.',
    compositedTextPreview = 'Current full text preview from the active style.',
    measurements = {
      selectedType = 'The corner measurementType selected for projection when the export was generated.',
      variants = 'Unified measurements for single, two-part, and three-part fits. Projection uses selectedType; analysis can compare all variants.',
      corner1 = 'Compatibility alias for the single CS-to-CE circle-fit measurement.',
      corner2 = 'Compatibility alias for older split measurements. New exports use variants.split2 and variants.split3.',
      radius = 'Circle radius in meters.',
      diameter = 'Circle diameter in meters. Current intensity calibration maps diameter ranges to labels.',
      arcDistance = 'Circle-derived arc length in meters.',
      arcDegrees = 'Estimated arc angle in degrees. Useful supporting context, but not the primary current length calibration input.',
      arcMeters = 'Measured driveline path length through the corner. Current length calibration maps arcMeters ranges per projected intensity.',
      chordMeters = 'Straight-line chord distance from corner start to corner end.',
      straightLineDistance = 'Straight-line distance between the measurement endpoints in meters.',
      fitQuality = 'Normalized circle-fit error. Lower generally means the points fit a simple circular corner better.',
      pointsLength = 'Length of the measured driveline segment in meters.',
      p1_p2_p3_center = 'Compact [x, y, z] coordinates for the fitted circle inputs and center.',
      diagnostics = 'Full, two-circle, and three-circle fit diagnostics for analysis. They are informational and do not imply automatic corner.shape changes.',
      hairpinCandidate = 'Informational hairpin detection features and score. This does not mutate descriptor or intensity.',
    },
    waypoints = 'Corner start and corner end waypoint context. Short CS-to-CE distances can cause misleading circle fits.',
    currentCalibration = 'Effective active style calibration after mission-local JSON overrides have been applied.',
    activeOverrides = 'Mission-local boundary overrides from rally/compositorCalibration.json, if any.',
  }
end

local function domainContext()
  return {
    'Measured values are derived from the current driveline and pacenote waypoint placement. A bad one-off example may be better fixed by adjusting the driveline or waypoints than by changing global calibration.',
    'Hairpins are special because they may require diameter, arcMeters, chordMeters, arcDegrees, and fit quality together. The export includes informational hairpinCandidate diagnostics only.',
    'Very mild corners can still produce noisy circle fits; treat unusual high-diameter examples as candidates for waypoint or measurement review before changing broad thresholds.',
    'Descriptor calls such as square, flat, and possible future hairpin descriptors can be considered separately from ordinary numeric intensity ranges.',
    'The labelled set may be too small or biased. Explicitly say when more hand-labelled examples, more routes, or more measurement features are needed before making confident threshold changes.',
  }
end

function M.build(path, pacenotesWindow)
  if not path then return nil, 'No notebook path is loaded.' end

  local missionDir = path:getMissionDir()
  local compositorName = path:getActiveCompositorName()
  local compositor = path:getTextCompositor()
  local config = compositor and compositor:getConfig() or nil
  local corner = config and config.componentTypes and config.componentTypes.corner or nil
  if not (missionDir and compositorName and corner) then
    return nil, 'No active corner calibration is available.'
  end

  local snaproad = pacenotesWindow and pacenotesWindow.snaproad or path:getSnaproad()
  if not snaproad then
    return nil, 'Snaproad is not loaded, so measurement data cannot be exported.'
  end

  local originalPartitionPacenote = snaproad.partition and snaproad.partition.pacenote or nil
  local pacenotes = {}
  local skippedTodoPacenoteCount = 0
  local sourcePacenoteCount = 0
  for index, pn in ipairs(path.pacenotes.sorted or {}) do
    if not pn.missing then
      sourcePacenoteCount = sourcePacenoteCount + 1
    end
    if not pn.missing and pn.todo == true then
      skippedTodoPacenoteCount = skippedTodoPacenoteCount + 1
    elseif not pn.missing then
      table.insert(pacenotes, serializePacenote(pn, index, snaproad, corner))
    end
  end

  if originalPartitionPacenote and snaproad.setPartitionToPacenote then
    snaproad:setPartitionToPacenote(originalPartitionPacenote)
  elseif snaproad.clearPartition then
    snaproad:clearPartition()
  end

  return {
    version = 1,
    generatedAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    notebook = notebookIdentity(path, missionDir),
    activeCompositorStyle = compositorName,
    currentCalibration = serializeCurrentCalibration(corner),
    activeOverrides = serializeOverrideData(missionDir, compositorName),
    analysisInstructions = analysisInstructions(),
    schema = schema(),
    domainContext = domainContext(),
    exportFilters = {
      todo = false,
      note = 'Only pacenotes with todo == false are included in pacenotes.',
    },
    pacenotes = pacenotes,
    summary = {
      sourcePacenoteCount = sourcePacenoteCount,
      pacenoteCount = #pacenotes,
      skippedTodoPacenoteCount = skippedTodoPacenoteCount,
      handLabelledPacenoteCount = (function()
        local count = 0
        for _, entry in ipairs(pacenotes) do
          if entry.hasHandLabels then count = count + 1 end
        end
        return count
      end)(),
    },
  }
end

function M.export(path, pacenotesWindow)
  local data, err = M.build(path, pacenotesWindow)
  if not data then return false, err end

  local missionDir = path:getMissionDir()
  local fname = exportFile(missionDir)
  if not fname then return false, 'No export path is available.' end

  local dir = fname:match('(.*/)')
  if dir then
    FS:directoryCreate(dir, true)
  end

  local ok = jsonWriteFile(fname, data, true)
  if not ok then
    log('E', logTag, 'Failed to write calibration analysis export: ' .. tostring(fname))
    return false, 'Failed to write export file.', fname
  end

  local parsed = jsonReadFile(fname)
  if type(parsed) ~= 'table' then
    log('E', logTag, 'Calibration analysis export parse check failed: ' .. tostring(fname))
    return false, 'Wrote export file, but JSON parse verification failed: ' .. tostring(fname), fname
  end

  log('I', logTag, 'Wrote calibration analysis export: ' .. tostring(fname))
  return true, fname, data
end

local function compactRange(range)
  return copyRange(range)
end

local function compactCalibrationRanges(data)
  local corner = data.currentCalibration and data.currentCalibration.corner or {}
  local intensity = {}
  for _, entry in ipairs(corner.intensity or {}) do
    table.insert(intensity, {
      id = entry.id,
      label = entry.label or entry.text or entry.visualText or entry.id,
      diameter = compactRange(entry.diameter),
    })
  end

  return {
    intensityDiameter = intensity,
    lengthsByIntensity = jsonCopy(corner.lengthsByIntensity) or {},
  }
end

local function normalizeText(value, directionWords)
  if value == nil then return nil end
  local text = tostring(value):lower():gsub("[^%w%s]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text == "" then return nil end

  text = " " .. text .. " "
  for _, word in ipairs(directionWords or {}) do
    local normalizedWord = tostring(word):lower():gsub("[^%w%s]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if normalizedWord and normalizedWord ~= "" then
      text = text:gsub(" " .. normalizedWord .. " ", " ")
    end
  end
  return text:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function addMatcherValue(matcher, value, id, directionWords)
  local normalized = normalizeText(value, directionWords)
  if normalized and normalized ~= "" then
    matcher[normalized] = id
  end
end

local function directionWords(corner)
  local out = { 'left', 'right' }
  local direction = corner and corner.direction
  if type(direction) == 'table' then
    if direction.left then table.insert(out, direction.left) end
    if direction.right then table.insert(out, direction.right) end
  end
  return out
end

local function buildIntensityMatcher(corner, dirWords)
  local matcher = {}
  local labelsById = {}
  for _, entry in ipairs(corner.intensity or {}) do
    local id = entry.id or entry.text or entry.label or entry.visualText
    if id then
      labelsById[id] = entry.label or entry.text or entry.visualText or id
      addMatcherValue(matcher, id, id, dirWords)
      addMatcherValue(matcher, entry.text, id, dirWords)
      addMatcherValue(matcher, entry.label, id, dirWords)
      addMatcherValue(matcher, entry.visualText, id, dirWords)
    end
  end
  return matcher, labelsById
end

local function buildDescriptorMatcher(corner, dirWords)
  local matcher = {}
  for key, entry in pairs(corner.descriptors or {}) do
    if type(key) == 'string' then
      addMatcherValue(matcher, key, key, dirWords)
      if type(entry) == 'table' then
        addMatcherValue(matcher, entry.text, key, dirWords)
        addMatcherValue(matcher, entry.visualText, key, dirWords)
      end
    end
  end
  return matcher
end

local function matchText(value, matcher, dirWords)
  local normalized = normalizeText(value, dirWords)
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

local function buildLengthMatcher(corner)
  local matcher = {}
  local namesById = {}
  for _, intEntry in ipairs(corner.intensity or {}) do
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(corner, intEntry.id) or {}) do
      local id = lengthEntry.id
      if id and not namesById[id] then
        local label = compositorUtil.cornerLengthEntryLabel(lengthEntry)
        namesById[id] = label
        addMatcherValue(matcher, id, id)
        addMatcherValue(matcher, label, id)
        addMatcherValue(matcher, lengthEntry.text, id)
      end
    end
  end
  return matcher, namesById
end

local function selectedMeasurement(entry)
  local measurements = entry and entry.measurements or {}
  local variants = measurements.variants or {}
  local selectedType = measurements.selectedType
  if selectedType and variants[selectedType] then return variants[selectedType] end
  return measurements.corner1 or variants.single
end

local function projectedIntensity(entry, measurement, matcher, dirWords)
  local intensity = measurement and measurement.intensity or nil
  if type(intensity) == 'table' then
    if intensity.id and intensity.id ~= "" then return intensity.id end
    for _, key in ipairs({ 'text', 'label', 'visualText' }) do
      local matched = matchText(intensity[key], matcher, dirWords)
      if matched then return matched end
    end
  end

  local labels = entry and entry.currentCornerLabels or {}
  return matchText(labels.cornerCall, matcher, dirWords)
end

local function rangeContains(range, value)
  value = tonumber(value)
  if type(range) ~= 'table' or not value then return false end

  local min = tonumber(range.min)
  if not min or value < min then return false end

  local max = tonumber(range.max)
  if max and value >= max then return false end
  return true
end

local function rangeDelta(range, value)
  value = tonumber(value)
  if type(range) ~= 'table' or not value then return nil, 'unknown' end

  local min = tonumber(range.min)
  local max = tonumber(range.max)
  if min and value < min then return roundNumber(min - value), 'below' end
  if max and value >= max then return roundNumber(value - max), 'above' end
  return 0, 'inside'
end

local function projectedLength(entry, measurement, projectedIntensityId, corner, matcher)
  local arcMeters = measurement and measurement.arcMeters
  if projectedIntensityId and arcMeters then
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(corner, projectedIntensityId) or {}) do
      if rangeContains(lengthEntry.arcMeters, arcMeters) then
        return lengthEntry.id
      end
    end
  end

  local labels = entry and entry.currentCornerLabels or {}
  return matchText(labels.cornerLength, matcher)
end

local function orderedIntensityKeys(corner, keySet)
  local out = {}
  local seen = {}
  for _, entry in ipairs(corner.intensity or {}) do
    local id = entry.id or entry.text or entry.label or entry.visualText
    if id and keySet[id] then
      table.insert(out, id)
      seen[id] = true
    end
  end

  local remaining = {}
  for key in pairs(keySet) do
    if not seen[key] then table.insert(remaining, key) end
  end
  table.sort(remaining)
  for _, key in ipairs(remaining) do table.insert(out, key) end
  return out
end

local function orderedLengthKeys(corner, keySet)
  local out = {}
  local seen = {}
  for _, intEntry in ipairs(corner.intensity or {}) do
    for _, lengthEntry in ipairs(compositorUtil.cornerLengthList(corner, intEntry.id) or {}) do
      local key = lengthEntry.id
      if key and keySet[key] and not seen[key] then
        table.insert(out, key)
        seen[key] = true
      end
    end
  end

  local remaining = {}
  for key in pairs(keySet) do
    if not seen[key] then table.insert(remaining, key) end
  end
  table.sort(remaining)
  for _, key in ipairs(remaining) do table.insert(out, key) end
  return out
end

local function newDistribution(labelsById)
  return {
    labels = labelsById,
    labelled = 0,
    compared = 0,
    skippedNoProjection = 0,
    rows = {},
    order = {},
  }
end

local function ensureRow(distribution, targetKeys, target)
  local row = distribution.rows[target]
  if not row then
    row = {
      target = target,
      targetLabel = distribution.labels[target] or target,
      total = 0,
      projected = {},
      projectedKeys = {},
      order = {},
    }
    distribution.rows[target] = row
    targetKeys[target] = true
  end
  return row
end

local function addComparison(distribution, targetKeys, target, projected, example)
  distribution.labelled = distribution.labelled + 1
  local row = ensureRow(distribution, targetKeys, target)

  if not projected or projected == "" then
    distribution.skippedNoProjection = distribution.skippedNoProjection + 1
    return
  end

  row.total = row.total + 1
  row.projectedKeys[projected] = true
  local bucket = row.projected[projected]
  if not bucket then
    bucket = {
      value = projected,
      label = distribution.labels[projected] or projected,
      count = 0,
      examples = {},
    }
    row.projected[projected] = bucket
  end
  bucket.count = bucket.count + 1
  table.insert(bucket.examples, example)
  distribution.compared = distribution.compared + 1
end

local function finalizeDistribution(distribution, orderedTargetsFn, orderedProjectedFn, targetKeys)
  distribution.order = orderedTargetsFn(targetKeys)
  for _, target in ipairs(distribution.order) do
    local row = distribution.rows[target]
    row.order = orderedProjectedFn(row.projectedKeys)
    for _, projected in ipairs(row.order) do
      local bucket = row.projected[projected]
      bucket.percent = row.total > 0 and roundNumber((bucket.count / row.total) * 100, 1) or 0
      bucket.matchesTarget = projected == target
    end
  end
end

local function hasDescriptorLabel(labels, descriptorMatcher, dirWords)
  if not labels then return false end
  if labels.cornerDescriptor and labels.cornerDescriptor ~= "" then return true end
  for _, value in pairs(labels) do
    if matchText(value, descriptorMatcher, dirWords) then return true end
  end
  return false
end

local function intensityRange(corner, intensityId)
  for _, entry in ipairs(corner.intensity or {}) do
    local id = entry.id or entry.text or entry.label or entry.visualText
    if id == intensityId then return entry.diameter end
  end
  return nil
end

local function lengthRange(corner, intensityId, lengthId)
  local entry = compositorUtil.cornerLengthEntryById(corner, intensityId, lengthId)
  return entry and entry.arcMeters or nil
end

local function exampleDetail(entry, value, targetRange, valueField, unit)
  local delta, direction = rangeDelta(targetRange, value)
  return {
    index = entry.index,
    id = entry.id,
    name = entry.name,
    valueField = valueField,
    value = roundNumber(value),
    unit = unit,
    targetRange = compactRange(targetRange),
    delta = delta,
    deltaDirection = direction,
  }
end

local function compactAnalysis(data)
  local corner = data.currentCalibration and data.currentCalibration.corner or {}
  local dirWords = directionWords(corner)
  local intensityMatcher, intensityLabels = buildIntensityMatcher(corner, dirWords)
  local descriptorMatcher = buildDescriptorMatcher(corner, dirWords)
  local lengthMatcher, lengthNames = buildLengthMatcher(corner)
  local intensity = newDistribution(intensityLabels)
  local length = newDistribution(lengthNames)
  local intensityTargetKeys = {}
  local lengthTargetKeys = {}
  local skippedDescriptor = 0

  for _, entry in ipairs(data.pacenotes or {}) do
    local labels = entry.handLabels or {}
    if hasDescriptorLabel(labels, descriptorMatcher, dirWords) then
      skippedDescriptor = skippedDescriptor + 1
    else
      local measurement = selectedMeasurement(entry)
      local projIntensity = projectedIntensity(entry, measurement, intensityMatcher, dirWords)

      local intensityTarget = labels.cornerIntensity
      local normalizedIntensityTarget = nil
      if intensityTarget and intensityTarget ~= "" then
        normalizedIntensityTarget = matchText(intensityTarget, intensityMatcher, dirWords) or intensityTarget
        addComparison(
          intensity,
          intensityTargetKeys,
          normalizedIntensityTarget,
          projIntensity,
          exampleDetail(entry, measurement and measurement.diameter, intensityRange(corner, normalizedIntensityTarget), 'diameter', 'm')
        )
      end

      local lengthTarget = labels.cornerLength
      if lengthTarget and lengthTarget ~= "" then
        lengthTarget = matchText(lengthTarget, lengthMatcher) or lengthTarget
        local projLength = projectedLength(entry, measurement, projIntensity, corner, lengthMatcher)
        local targetIntensity = normalizedIntensityTarget or projIntensity
        addComparison(
          length,
          lengthTargetKeys,
          lengthTarget,
          projLength,
          exampleDetail(entry, measurement and measurement.arcMeters, lengthRange(corner, targetIntensity, lengthTarget), 'arcMeters', 'm')
        )
      end
    end
  end

  finalizeDistribution(
    intensity,
    function(keys) return orderedIntensityKeys(corner, keys) end,
    function(keys) return orderedIntensityKeys(corner, keys) end,
    intensityTargetKeys
  )
  finalizeDistribution(
    length,
    function(keys) return orderedLengthKeys(corner, keys) end,
    function(keys) return orderedLengthKeys(corner, keys) end,
    lengthTargetKeys
  )

  return {
    skippedDescriptorPacenoteCount = skippedDescriptor,
    intensity = intensity,
    length = length,
  }
end

function M.buildV2(path, pacenotesWindow)
  local data, err = M.build(path, pacenotesWindow)
  if not data then return nil, err end

  return {
    version = 2,
    generatedAt = data.generatedAt,
    notebook = data.notebook,
    activeCompositorStyle = data.activeCompositorStyle,
    calibrationRanges = compactCalibrationRanges(data),
    activeOverrides = data.activeOverrides,
    analysis = compactAnalysis(data),
    analysisInstructions = {
      purpose = analysisInstructions().purpose,
      requestedOutput = analysisInstructions().requestedOutput,
      rangeRules = {
        'Intensity uses diameter meters.',
        'Length uses arcMeters and is scoped by the projected/target intensity where available.',
        'Rows compare manual target labels against current projected buckets.',
        'Examples include measured values, target ranges, and distance from target range.',
        'Descriptor-labelled pacenotes such as square and hairpin are excluded from numeric threshold analysis.',
      },
    },
    domainContext = domainContext(),
  }
end

function M.exportV2(path, pacenotesWindow)
  local data, err = M.buildV2(path, pacenotesWindow)
  if not data then return false, err end

  local missionDir = path:getMissionDir()
  local fname = exportV2File(missionDir)
  if not fname then return false, 'No export path is available.' end

  local dir = fname:match('(.*/)')
  if dir then
    FS:directoryCreate(dir, true)
  end

  local ok = jsonWriteFile(fname, data, true)
  if not ok then
    log('E', logTag, 'Failed to write calibration analysis v2 export: ' .. tostring(fname))
    return false, 'Failed to write export file.', fname
  end

  local parsed = jsonReadFile(fname)
  if type(parsed) ~= 'table' then
    log('E', logTag, 'Calibration analysis v2 export parse check failed: ' .. tostring(fname))
    return false, 'Wrote export file, but JSON parse verification failed: ' .. tostring(fname), fname
  end

  log('I', logTag, 'Wrote calibration analysis v2 export: ' .. tostring(fname))
  return true, fname, data
end

return M
