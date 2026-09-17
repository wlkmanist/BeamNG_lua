-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local ffi = require("ffi")
local objectHistoryActions = require("editor/api/objectHistoryActions")()

local toolWindowName = "groundCoverEditor"
local editModeName = "Ground Cover Editor"
local logTag = "editor_groundCoverEditor"
local maxTypes = 8
local maxBillboardsPerCell = 10922

local objectFields = {
  {field = "reflectScale", label = "Reflection scale", kind = "float", step = 0.05, stepFast = 0.25, format = "%.2f"},
  {field = "maxBillboardTiltAngle", label = "Max billboard tilt", kind = "float", step = 1, stepFast = 10, format = "%.2f"},
  {field = "shapesCastShadows", label = "Shapes cast shadows", kind = "bool"},
}

local windFields = {
  {field = "windDirection", label = "Wind direction", kind = "text"},
  {field = "windGustLength", label = "Gust length", kind = "float", step = 0.5, stepFast = 5, format = "%.2f"},
  {field = "windGustFrequency", label = "Gust frequency", kind = "float", step = 0.05, stepFast = 0.5, format = "%.2f"},
  {field = "windGustStrength", label = "Gust strength", kind = "float", step = 0.05, stepFast = 0.5, format = "%.2f"},
  {field = "windTurbulenceFrequency", label = "Turbulence frequency", kind = "float", step = 0.05, stepFast = 0.5, format = "%.2f"},
  {field = "windTurbulenceStrength", label = "Turbulence strength", kind = "float", step = 0.025, stepFast = 0.25, format = "%.3f"},
}

local debugFields = {
  {field = "renderCells", label = "Render cells", kind = "bool"},
  {field = "lockFrustum", label = "Lock frustum", kind = "bool"},
  {field = "noBillboards", label = "No billboards", kind = "bool"},
  {field = "noShapes", label = "No shapes", kind = "bool"},
}

local typeFields = {
  "billboardUVs",
  "useWorldRandomYaw",
  "shapeFilename",
  "layer",
  "invertLayer",
  "probability",
  "sizeMin",
  "sizeMax",
  "sizeExponent",
  "windScale",
  "maxSlope",
  "minElevation",
  "maxElevation",
  "minClumpCount",
  "maxClumpCount",
  "clumpExponent",
  "clumpRadius",
}

local objectSetupFields = {
  "material", "radius", "dissolveRadius", "reflectScale", "gridSize", "zOffset", "seed",
  "maxElements", "maxBillboardTiltAngle", "shapeCullRadius", "shapesCastShadows",
  "windDirection", "windGustLength", "windGustFrequency", "windGustStrength",
  "windTurbulenceFrequency", "windTurbulenceStrength",
}

local transformFields = {"position", "rotationMatrix", "scale"}
local invertLayerField = {field = "invertLayer", label = "Invert layer", kind = "bool"}
local typeSizeFields = {
  {field = "sizeExponent", label = "Size exponent", kind = "sliderFloat", min = 0.05, max = 5, format = "%.3f"},
  {field = "windScale", label = "Wind scale", kind = "sliderFloat", min = 0, max = 2, format = "%.3f"},
  {field = "useWorldRandomYaw", label = "World random yaw", kind = "bool"},
}
local typePlacementFields = {
  {field = "maxSlope", label = "Max slope", kind = "sliderFloat", min = 0, max = 90, format = "%.1f"},
}

local defaultObjectFields = {
  {"material", "BNGGrass_3"}, {"radius", "80"}, {"dissolveRadius", "50"}, {"gridSize", "6"},
  {"zOffset", "0"}, {"seed", "1"}, {"maxElements", "100000"}, {"shapeCullRadius", "60"}, {"shapesCastShadows", "false"},
}

local defaultTypeFields = {
  {"probability", "1"}, {"billboardUVs", "0 0 1 1"}, {"sizeMin", "0.2"},
  {"sizeMax", "0.5"}, {"sizeExponent", "1"}, {"windScale", "0.05"}, {"useWorldRandomYaw", "true"},
}

local typePresets = {
  grass = {
    {"probability", "1"}, {"billboardUVs", "0 0 1 1"}, {"shapeFilename", ""},
    {"sizeMin", "0.15"}, {"sizeMax", "0.45"}, {"sizeExponent", "1"},
    {"windScale", "0.05"}, {"useWorldRandomYaw", "true"},
  },
  shape = {
    {"probability", "1"}, {"billboardUVs", ""}, {"sizeMin", "0.8"},
    {"sizeMax", "1.2"}, {"sizeExponent", "1"}, {"windScale", "0"},
    {"useWorldRandomYaw", "true"},
  },
}

local rangeProfiles = {
  {label = "Close", radius = 50, dissolveRadius = 30, shapeCullRadius = 45},
  {label = "Medium", radius = 120, dissolveRadius = 80, shapeCullRadius = 90},
  {label = "Distant", radius = 300, dissolveRadius = 250, shapeCullRadius = 280},
}

local densityProfiles = {
  {label = "Sparse", perCell = 1200},
  {label = "Normal", perCell = 4500},
  {label = "Dense", perCell = 8500},
}

local coverageProfiles = {
  {label = "Close detail grass", radius = 45, dissolveRadius = 25, shapeCullRadius = 45, gridSize = 6, perCell = 9000},
  {label = "Medium grass", radius = 100, dissolveRadius = 70, shapeCullRadius = 100, gridSize = 8, perCell = 3500},
  {label = "Distant grass", radius = 300, dissolveRadius = 250, shapeCullRadius = 290, gridSize = 10, perCell = 8500},
  {label = "Sparse shapes/rocks", radius = 100, dissolveRadius = 80, shapeCullRadius = 100, gridSize = 5, perCell = 250, material = "Empty", shapesCastShadows = "false"},
}

for _, profile in ipairs(rangeProfiles) do
  profile.rangeButtonLabel = string.format("%s %.0fm##gcRange%s", profile.label, profile.radius, profile.label)
  profile.rangeTooltip = string.format("Sets visible distance to %.0f m, fade start to %.0f m, and shape cull to %.0f m.", profile.radius, profile.dissolveRadius, profile.shapeCullRadius)
end

for _, profile in ipairs(densityProfiles) do
  profile.buttonLabel = string.format("%s##gcDensity%s", profile.label, profile.label)
  profile.tooltip = string.format("Keeps each object's current grid resolution and sets a shared budget of %.0f elements per cell across all active types.", profile.perCell)
end

for _, profile in ipairs(coverageProfiles) do
  profile.buttonLabel = string.format("%s##gcCoverage%s", profile.label, profile.label)
  profile.tooltip = string.format("Sets %.0f m radius, %.0f m fade start, grid %d, and a shared budget of %.0f elements per cell.", profile.radius, profile.dissolveRadius, profile.gridSize, profile.perCell)
end

local fieldTooltips = {
  material = "Shared billboard material atlas used by every type slot. Use Empty for shape-only cover.",
  radius = "Outer visible/generation distance around the camera. Larger values cover more area but cost more.",
  dissolveRadius = "Distance where billboards start fading out. Keep this lower than Visible until.",
  shapeCullRadius = "Hard cull distance for 3D shape instances in type slots.",
  reflectScale = "Scales ground cover distance in reflection passes. Use 0 to skip reflections.",
  gridSize = "Number of cells per axis. Higher values create smaller cells and distribute maxElements across more cells.",
  zOffset = "Vertical placement offset applied to generated cover.",
  seed = "Saved random seed used to generate stable cover placement.",
  maxElements = "Total placement budget across all active grid cells before global grass density scaling.",
  maxBillboardTiltAngle = "Maximum angle billboards may tilt to match the camera.",
  shapesCastShadows = "Whether 3D shape instances cast shadows. This can be expensive for dense cover.",
  windDirection = "World-space wind direction as X Y.",
  windGustLength = "Distance between wind gust peaks.",
  windGustFrequency = "How often gust peaks occur.",
  windGustStrength = "Maximum displacement from gust wind.",
  windTurbulenceFrequency = "How quickly turbulence varies.",
  windTurbulenceStrength = "Maximum displacement from turbulence.",
  renderCells = "Draw debug cell bounds for this GroundCover object.",
  lockFrustum = "Freeze the generation frustum for debugging.",
  noBillboards = "Temporarily disable billboard rendering for this object.",
  noShapes = "Temporarily disable 3D shape rendering for this object.",
  layer = "Terrain material layer this type may spawn on. Empty means all terrain layers.",
  invertLayer = "Invert the layer mask so this type spawns everywhere except the selected layer.",
  probability = "Relative spawn weight for this type. Weights are normalized against active type slots.",
  billboardUVs = "UV rectangle inside the shared material atlas: U, V, width, height.",
  shapeFilename = "Optional DAE shape for this type. Leave empty for billboard-only cover.",
  sizeMin = "Minimum random size for this type.",
  sizeMax = "Maximum random size for this type.",
  sizeExponent = "Bias between min and max size. Higher values favor smaller sizes.",
  windScale = "Per-type wind multiplier. Use 0 for rocks or rigid shapes.",
  useWorldRandomYaw = "Keep billboards upright with random yaw instead of camera-facing.",
  maxSlope = "Maximum terrain slope in degrees where this type can spawn.",
  minElevation = "Minimum world Z elevation where this type can spawn.",
  maxElevation = "Maximum world Z elevation where this type can spawn.",
  minClumpCount = "Minimum number of elements per clump.",
  maxClumpCount = "Maximum number of elements per clump.",
  clumpExponent = "Bias between minimum and maximum clump count.",
  clumpRadius = "Maximum radius used when spreading elements inside a clump.",
}

local selectedGroundCoverId = nil
local selectedParentGroupId = nil
local copySourceGroundCoverId = nil
local objectNameFilter = im.ArrayChar(128, "")
local materialFilter = im.ArrayChar(128, "")
local tempBool = im.BoolPtr(false)
local editEnded = im.BoolPtr(false)
local autoFlushPreview = im.BoolPtr(true)
local groundCoverObjectsCache = nil
local parentGroupsCache = nil
local terrainLayersCache = nil
local terrainLayerLookupCache = nil
local validationCache = {objectId = nil, warnings = nil, dirty = true}

local function invalidateObjectCaches()
  groundCoverObjectsCache = nil
  parentGroupsCache = nil
end

local function invalidateTerrainLayerCache()
  terrainLayersCache = nil
  terrainLayerLookupCache = nil
end

local function invalidateValidationCache()
  validationCache.dirty = true
end

local function getObjectId(obj)
  if not obj then return nil end
  if obj.getID then return obj:getID() end
  if obj.getId then return obj:getId() end
end

local function getObjectName(obj)
  if not obj then return "" end
  local name = obj:getName()
  if not name or name == "" then
    name = "#" .. tostring(getObjectId(obj))
  end
  return name
end

local function getField(obj, field, arrayIndex)
  if not obj then return "" end
  local value = obj:getField(field, arrayIndex or 0)
  if value == nil then return "" end
  return tostring(value)
end

local function toBool(value)
  return value == true or value == "true" or value == "1" or value == "True"
end

local function formatFloat(value)
  return string.format("%.6g", tonumber(value) or 0)
end

local function clampNumber(value, minValue, maxValue)
  value = tonumber(value) or 0
  if minValue and value < minValue then value = minValue end
  if maxValue and value > maxValue then value = maxValue end
  return value
end

local function getDensityScale()
  if VariableRegistry and VariableRegistry.get then
    return tonumber(VariableRegistry.get("$pref::GroundCover::densityScale")) or 1
  end
  return 1
end

local function getPlacementMetrics(obj)
  local radius = math.max(0, tonumber(getField(obj, "radius", 0)) or 0)
  local dissolveRadius = math.max(0, tonumber(getField(obj, "dissolveRadius", 0)) or 0)
  local gridSize = math.max(2, math.floor((tonumber(getField(obj, "gridSize", 0)) or 2) + 0.5))
  local maxElements = math.max(0, math.floor((tonumber(getField(obj, "maxElements", 0)) or 0) + 0.5))
  local densityScale = getDensityScale()
  local cells = gridSize * gridSize
  local perCell = cells > 0 and maxElements / cells or 0
  local qualityPerCell = perCell * densityScale
  local cellSize = gridSize > 1 and (radius * 2) / (gridSize - 1) or radius * 2
  return {
    radius = radius,
    dissolveRadius = dissolveRadius,
    fadeLength = math.max(0, radius - dissolveRadius),
    gridSize = gridSize,
    maxElements = maxElements,
    densityScale = densityScale,
    cells = cells,
    perCell = perCell,
    qualityPerCell = qualityPerCell,
    cellSize = cellSize,
  }
end

local function getMaterialNames()
  local names = scenetree.findClassObjects("Material") or {}
  local filtered = {}
  local seen = {}
  local filter = ffi.string(materialFilter):lower()
  for _, name in ipairs(names) do
    if name and name ~= "" and not seen[name] and (filter == "" or tostring(name):lower():find(filter, 1, true)) then
      table.insert(filtered, name)
      seen[name] = true
    end
  end
  table.sort(filtered, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
  return filtered
end

local function drawHelpText(text)
  im.PushTextWrapPos(im.GetContentRegionAvailWidth())
  im.PushStyleColor2(im.Col_Text, im.ImVec4(0.55, 0.82, 1, 1))
  im.TextWrapped(text)
  im.PopStyleColor()
  im.PopTextWrapPos()
end

local wrappedButtonLineWidth = 0

local function beginWrappedButtons()
  wrappedButtonLineWidth = 0
end

local function drawWrappedButton(label, tooltip)
  local style = im.GetStyle()
  local availWidth = im.GetContentRegionAvailWidth()
  local buttonWidth = im.CalcTextSize(label).x + style.FramePadding.x * 2
  if wrappedButtonLineWidth > 0 and wrappedButtonLineWidth + style.ItemSpacing.x + buttonWidth <= availWidth then
    im.SameLine()
    wrappedButtonLineWidth = wrappedButtonLineWidth + style.ItemSpacing.x + buttonWidth
  else
    wrappedButtonLineWidth = buttonWidth
  end
  local clicked = im.Button(label)
  if tooltip then
    im.tooltip(tooltip)
  end
  return clicked
end

local function refreshGroundCoverPreview()
  if flushGroundCoverGrids then
    flushGroundCoverGrids()
  end
end

local function postApplyObject(obj)
  if obj and obj.postApply then
    obj:postApply()
  end
end

local function postApplyObjects(ids)
  for _, id in ipairs(ids or {}) do
    postApplyObject(scenetree.findObjectById(id))
  end
  invalidateValidationCache()
  if autoFlushPreview[0] then
    refreshGroundCoverPreview()
  end
end

local function setFieldWithUndo(ids, field, value, arrayIndex, transactionName)
  if not ids or #ids == 0 then return end
  editor.history:beginTransaction(transactionName or "ChangeGroundCoverField")
  objectHistoryActions.changeObjectFieldWithUndo(ids, field, tostring(value), arrayIndex or 0)
  editor.history:endTransaction()
  editor.setDirty()
  postApplyObjects(ids)
end

local function setFieldsWithUndo(ids, entries, transactionName)
  if not ids or #ids == 0 or not entries or #entries == 0 then return end
  editor.history:beginTransaction(transactionName or "ChangeGroundCoverFields")
  for _, entry in ipairs(entries) do
    objectHistoryActions.changeObjectFieldWithUndo(ids, entry.field, tostring(entry.value or ""), entry.arrayIndex or 0)
  end
  editor.history:endTransaction()
  editor.setDirty()
  postApplyObjects(ids)
end

local function setFieldMultipleValuesWithUndo(ids, field, values, arrayIndex, transactionName)
  if not ids or #ids == 0 or not values or #values == 0 then return end
  editor.history:beginTransaction(transactionName or "ChangeGroundCoverFieldValues")
  objectHistoryActions.changeObjectFieldMultipleValuesWithUndo(ids, field, values, arrayIndex or 0)
  editor.history:endTransaction()
  editor.setDirty()
  postApplyObjects(ids)
end

local function setFieldLive(ids, field, value, arrayIndex)
  for _, id in ipairs(ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:setField(field, arrayIndex or 0, tostring(value))
    end
  end
  invalidateValidationCache()
end

local function setFieldMultipleValuesLive(ids, field, values, arrayIndex)
  for index, id in ipairs(ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:setField(field, arrayIndex or 0, tostring(values[index] or ""))
    end
  end
  invalidateValidationCache()
end

local function setMultipleFieldValuesLive(ids, entries)
  for _, entry in ipairs(entries or {}) do
    setFieldMultipleValuesLive(ids, entry.field, entry.values, entry.arrayIndex or 0)
  end
end

local function finishLiveSliderEdit(ids)
  editor.setDirty()
  postApplyObjects(ids)
end

local function finishLiveSliderEditIfNeeded(ids)
  if editEnded[0] then
    finishLiveSliderEdit(ids)
  end
end

local function setMultipleFieldValuesWithUndo(ids, entries, transactionName)
  if not ids or #ids == 0 or not entries or #entries == 0 then return end
  editor.history:beginTransaction(transactionName or "ChangeGroundCoverFieldValues")
  for _, entry in ipairs(entries) do
    objectHistoryActions.changeObjectFieldMultipleValuesWithUndo(ids, entry.field, entry.values, entry.arrayIndex or 0)
  end
  editor.history:endTransaction()
  editor.setDirty()
  postApplyObjects(ids)
end

local function applyFieldValues(ids, field, values, arrayIndex, transactionName, live)
  if live then
    setFieldMultipleValuesLive(ids, field, values, arrayIndex)
  else
    setFieldMultipleValuesWithUndo(ids, field, values, arrayIndex, transactionName)
  end
end

local function applyMultiFieldValues(ids, entries, transactionName, live)
  if live then
    setMultipleFieldValuesLive(ids, entries)
  else
    setMultipleFieldValuesWithUndo(ids, entries, transactionName)
  end
end

local function makeEntries(fieldValues, arrayIndex)
  local entries = {}
  for _, fieldValue in ipairs(fieldValues) do
    table.insert(entries, {field = fieldValue[1], value = fieldValue[2], arrayIndex = arrayIndex})
  end
  return entries
end

local function maxElementsForProfile(obj, profile)
  local gridSize = profile.gridSize or (obj and getPlacementMetrics(obj).gridSize) or 2
  local perCell = math.min(profile.perCell or 0, maxBillboardsPerCell)
  return tostring(math.floor(gridSize * gridSize * perCell + 0.5))
end

local function applyRangeProfile(ids, profile)
  setFieldsWithUndo(ids, {
    {field = "radius", value = tostring(profile.radius)},
    {field = "dissolveRadius", value = tostring(profile.dissolveRadius)},
    {field = "shapeCullRadius", value = tostring(profile.shapeCullRadius)},
  }, "ApplyGroundCoverRangeProfile")
end

local function applyDensityProfile(ids, activeObj, profile)
  local values = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    table.insert(values, maxElementsForProfile(obj or activeObj, profile))
  end
  setFieldMultipleValuesWithUndo(ids, "maxElements", values, 0, "ApplyGroundCoverDensityProfile")
end

local function applyCoverageProfile(ids, profile)
  local entries = {
    {field = "radius", value = tostring(profile.radius)},
    {field = "dissolveRadius", value = tostring(profile.dissolveRadius)},
    {field = "shapeCullRadius", value = tostring(profile.shapeCullRadius)},
    {field = "gridSize", value = tostring(profile.gridSize)},
    {field = "maxElements", value = maxElementsForProfile(nil, profile)},
  }
  if profile.material then
    table.insert(entries, {field = "material", value = profile.material})
  end
  if profile.shapesCastShadows then
    table.insert(entries, {field = "shapesCastShadows", value = profile.shapesCastShadows})
  end
  setFieldsWithUndo(ids, entries, "ApplyGroundCoverCoverageProfile")
end

local function getAutoBalanceForRadius(radius)
  if radius <= 70 then
    return 6, 8500
  elseif radius <= 160 then
    return 8, 3500
  elseif radius <= 320 then
    return 10, 6500
  end
  return 12, 4500
end

local function applyAutoBalance(ids)
  local gridValues = {}
  local maxElementValues = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    local metrics = obj and getPlacementMetrics(obj) or {radius = 100}
    local gridSize, perCell = getAutoBalanceForRadius(metrics.radius)
    table.insert(gridValues, tostring(gridSize))
    table.insert(maxElementValues, tostring(gridSize * gridSize * perCell))
  end

  setMultipleFieldValuesWithUndo(ids, {
    {field = "gridSize", values = gridValues},
    {field = "maxElements", values = maxElementValues},
  }, "AutoBalanceGroundCoverDensity")
end

local function applyAutoDistanceFromRadius(ids)
  local dissolveValues = {}
  local shapeCullValues = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    local metrics = obj and getPlacementMetrics(obj) or {radius = 100}
    table.insert(dissolveValues, formatFloat(metrics.radius * 0.8))
    table.insert(shapeCullValues, formatFloat(math.min(metrics.radius, 300)))
  end

  setMultipleFieldValuesWithUndo(ids, {
    {field = "dissolveRadius", values = dissolveValues},
    {field = "shapeCullRadius", values = shapeCullValues},
  }, "AutoGroundCoverFadeAndCull")
end

local function setDistanceValue(ids, field, value, live)
  if not ids or #ids == 0 then return end
  value = clampNumber(value, field == "radius" and 10 or 0, 500)

  if field == "radius" then
    local radiusValues = {}
    local dissolveValues = {}
    local shapeCullValues = {}
    for _, id in ipairs(ids) do
      local obj = scenetree.findObjectById(id)
      table.insert(radiusValues, formatFloat(value))
      table.insert(dissolveValues, formatFloat(math.min(tonumber(getField(obj, "dissolveRadius", 0)) or 0, value)))
      table.insert(shapeCullValues, formatFloat(math.min(tonumber(getField(obj, "shapeCullRadius", 0)) or 0, value)))
    end
    local entries = {
      {field = "radius", values = radiusValues},
      {field = "dissolveRadius", values = dissolveValues},
      {field = "shapeCullRadius", values = shapeCullValues},
    }
    applyMultiFieldValues(ids, entries, "ChangeGroundCoverDistance", live)
    return
  end

  local values = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    local radius = math.max(10, tonumber(getField(obj, "radius", 0)) or 10)
    table.insert(values, formatFloat(math.min(value, radius)))
  end
  applyFieldValues(ids, field, values, 0, "ChangeGroundCoverDistance", live)
end

local function maxElementsForGrid(gridSize)
  return math.floor(gridSize * gridSize * maxBillboardsPerCell)
end

local function setGridSizeValue(ids, value, live)
  if not ids or #ids == 0 then return end
  local gridSize = math.floor(clampNumber(value, 2, 16) + 0.5)
  local gridValues = {}
  local maxElementValues = {}
  local maxElements = maxElementsForGrid(gridSize)
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    table.insert(gridValues, tostring(gridSize))
    table.insert(maxElementValues, tostring(math.min(tonumber(getField(obj, "maxElements", 0)) or 0, maxElements)))
  end
  local entries = {
    {field = "gridSize", values = gridValues},
    {field = "maxElements", values = maxElementValues},
  }
  applyMultiFieldValues(ids, entries, "ChangeGroundCoverGridSize", live)
end

local function setMaxElementsClamped(ids, value, live)
  if not ids or #ids == 0 then return end
  local values = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    local gridSize = math.max(2, math.floor((tonumber(getField(obj, "gridSize", 0)) or 2) + 0.5))
    table.insert(values, tostring(math.floor(clampNumber(value, 0, maxElementsForGrid(gridSize)) + 0.5)))
  end
  applyFieldValues(ids, "maxElements", values, 0, "ChangeGroundCoverMaxElements", live)
end

local function setDependentMinMaxValue(ids, typeIndex, minField, maxField, field, value, isInt, transactionName, live)
  if not ids or #ids == 0 then return end
  value = isInt and math.floor(value + 0.5) or value

  if field == minField then
    local minValues = {}
    local maxValues = {}
    for _, id in ipairs(ids) do
      local obj = scenetree.findObjectById(id)
      table.insert(minValues, tostring(value))
      table.insert(maxValues, tostring(math.max(tonumber(getField(obj, maxField, typeIndex)) or value, value)))
    end
    local entries = {
      {field = minField, values = minValues, arrayIndex = typeIndex},
      {field = maxField, values = maxValues, arrayIndex = typeIndex},
    }
    applyMultiFieldValues(ids, entries, transactionName, live)
    return
  end

  local maxValues = {}
  for _, id in ipairs(ids) do
    local obj = scenetree.findObjectById(id)
    table.insert(maxValues, tostring(math.max(value, tonumber(getField(obj, minField, typeIndex)) or value)))
  end
  applyFieldValues(ids, maxField, maxValues, typeIndex, transactionName, live)
end

local function getGroundCoverObjects()
  if groundCoverObjectsCache then
    return groundCoverObjectsCache
  end
  local result = {}
  local names = scenetree.findClassObjects("GroundCover") or {}
  table.sort(names, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
  for _, name in ipairs(names) do
    local obj = scenetree.findObject(name)
    if obj then
      table.insert(result, obj)
    end
  end
  groundCoverObjectsCache = result
  return result
end

local function getSelectedGroundCoverIds()
  local result = {}
  local selection = editor.selection and editor.selection.object or {}
  for _, id in ipairs(selection) do
    local obj = scenetree.findObjectById(id)
    if obj and obj:getClassName() == "GroundCover" then
      table.insert(result, id)
    end
  end
  return result
end

local function getSelectedObject()
  if selectedGroundCoverId then
    local obj = scenetree.findObjectById(selectedGroundCoverId)
    if obj and obj:getClassName() == "GroundCover" then
      return obj
    end
  end

  local selectedIds = getSelectedGroundCoverIds()
  if selectedIds[1] then
    selectedGroundCoverId = selectedIds[1]
    return scenetree.findObjectById(selectedGroundCoverId)
  end
end

local function selectGroundCover(obj)
  if not obj then return end
  selectedGroundCoverId = getObjectId(obj)
  invalidateValidationCache()
  editor.selectObjects({selectedGroundCoverId}, editor.SelectMode_New)
end

local function findVegetationGroup()
  for _, name in ipairs({"vegetation", "Vegetation"}) do
    local obj = scenetree.findObject(name)
    if obj and (obj:getClassName() == "SimGroup" or obj:getClassName() == "SimSet") then
      return obj
    end
  end
end

local function getParentGroupObjects()
  if parentGroupsCache then
    return parentGroupsCache
  end
  local groups = {}
  local seen = {}

  local function addGroup(obj)
    local id = getObjectId(obj)
    if obj and id and not seen[id] and (obj:getClassName() == "SimGroup" or obj:getClassName() == "SimSet") then
      table.insert(groups, obj)
      seen[id] = true
    end
  end

  addGroup(scenetree.MissionGroup)
  for _, name in ipairs(scenetree.findClassObjects("SimGroup") or {}) do
    addGroup(scenetree.findObject(name))
  end

  table.sort(groups, function(a, b) return getObjectName(a):lower() < getObjectName(b):lower() end)
  parentGroupsCache = groups
  return groups
end

local function getSelectedParentGroup()
  if selectedParentGroupId then
    local obj = scenetree.findObjectById(selectedParentGroupId)
    if obj and (obj:getClassName() == "SimGroup" or obj:getClassName() == "SimSet") then
      return obj
    end
    selectedParentGroupId = nil
  end
end

local function getCreateParent()
  local selectedParent = getSelectedParentGroup()
  if selectedParent then
    return selectedParent
  end

  local selection = editor.selection and editor.selection.object or {}
  if #selection == 1 then
    local selected = scenetree.findObjectById(selection[1])
    if selected and (selected:getClassName() == "SimGroup" or selected:getClassName() == "SimSet") then
      return selected
    end
  end
  return findVegetationGroup() or scenetree.MissionGroup
end

local function getCameraPositionString()
  if core_camera and core_camera.getPosition then
    local pos = core_camera.getPosition()
    if pos then
      return string.format("%g %g %g", pos.x, pos.y, pos.z)
    end
  end
  return "0 0 0"
end

local function getTerrainLayers()
  if terrainLayersCache and terrainLayerLookupCache then
    return terrainLayersCache, terrainLayerLookupCache
  end
  local layers = {}
  local seen = {}

  if editor_terrainEditor and editor_terrainEditor.updatePaintMaterialProxies then
    editor_terrainEditor.updatePaintMaterialProxies()
  end

  local proxies = editor_terrainEditor and editor_terrainEditor.getPaintMaterialProxies and editor_terrainEditor.getPaintMaterialProxies() or nil
  if proxies then
    for _, proxy in ipairs(proxies) do
      if proxy.internalName and proxy.internalName ~= "" and not seen[proxy.internalName] then
        table.insert(layers, proxy.internalName)
        seen[proxy.internalName] = true
      end
    end
  end

  if #layers == 0 and editor_terrainEditor and editor_terrainEditor.getTerrainBlock then
    local terrainBlock = editor_terrainEditor.getTerrainBlock()
    if terrainBlock and terrainBlock.getMaterials then
      for _, mtl in ipairs(terrainBlock:getMaterials() or {}) do
        local name = mtl and mtl.getInternalName and mtl:getInternalName() or nil
        if name and name ~= "" and not seen[name] then
          table.insert(layers, name)
          seen[name] = true
        end
      end
    end
  end

  table.sort(layers, function(a, b) return a:lower() < b:lower() end)
  terrainLayersCache = layers
  terrainLayerLookupCache = seen
  return layers, seen
end

local function drawLayerCombo(label, obj, arrayIndex, targetIds)
  local current = getField(obj, "layer", arrayIndex)
  local layers = getTerrainLayers()
  local changed = false

  if im.BeginCombo(label, current ~= "" and current or "<all terrain layers>") then
    if im.Selectable1("<all terrain layers>", current == "") then
      setFieldWithUndo(targetIds, "layer", "", arrayIndex, "ChangeGroundCoverLayer")
      changed = true
    end
    for _, layer in ipairs(layers) do
      if im.Selectable1(layer, current == layer) then
        setFieldWithUndo(targetIds, "layer", layer, arrayIndex, "ChangeGroundCoverLayer")
        changed = true
      end
    end
    im.EndCombo()
  end
  return changed
end

local drawFieldLabel
local drawFloatField
local drawIntField
local drawSliderFloatField
local drawSliderIntField

local function drawDistanceSlider(obj, ids, field, label, minValue, maxValue, format)
  drawFieldLabel(label, fieldTooltips[field])
  local current = clampNumber(getField(obj, field, 0), minValue, maxValue)
  local valuePtr = editor.getTempFloat_NumberNumber(current)
  editEnded[0] = false
  local changed = editor.uiSliderFloat("##" .. field .. "Distance", valuePtr, minValue, maxValue, format or "%.0f m", nil, editEnded)
  im.PopItemWidth()
  if changed then
    setDistanceValue(ids, field, valuePtr[0], true)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawGridSizeSlider(obj, ids)
  drawFieldLabel("Grid resolution", fieldTooltips.gridSize)
  local valuePtr = editor.getTempInt_NumberNumber(math.floor(clampNumber(getField(obj, "gridSize", 0), 2, 16) + 0.5))
  editEnded[0] = false
  local changed = editor.uiSliderInt("##gridSize0", valuePtr, 2, 16, nil, editEnded)
  im.PopItemWidth()
  if changed then
    setGridSizeValue(ids, valuePtr[0], true)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawMaxElementsSlider(obj, ids)
  local metrics = getPlacementMetrics(obj)
  drawFieldLabel("Total budget", fieldTooltips.maxElements)
  local valuePtr = editor.getTempInt_NumberNumber(math.floor(clampNumber(getField(obj, "maxElements", 0), 0, maxElementsForGrid(metrics.gridSize)) + 0.5))
  editEnded[0] = false
  local changed = editor.uiSliderInt("##maxElements0", valuePtr, 0, maxElementsForGrid(metrics.gridSize), nil, editEnded)
  im.PopItemWidth()
  if changed then
    setMaxElementsClamped(ids, valuePtr[0], true)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawMaterialSelector(obj, ids)
  local current = getField(obj, "material", 0)
  im.TextUnformatted("Material")
  im.tooltip(fieldTooltips.material)

  local comboLabel = current ~= "" and current or "<no material>"
  local fullWidth = im.GetContentRegionAvailWidth()
  im.PushItemWidth(fullWidth * 0.6)
  if im.BeginCombo("Choose material##groundCoverMaterialCombo", comboLabel) then
    if im.Selectable1("Empty", current == "Empty") then
      setFieldWithUndo(ids, "material", "Empty", 0, "ChangeGroundCoverMaterial")
    end
    for _, name in ipairs(getMaterialNames()) do
      if im.Selectable1(name, current == name) then
        setFieldWithUndo(ids, "material", name, 0, "ChangeGroundCoverMaterial")
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()
  im.tooltip("Pick from currently loaded Material objects.")

  im.SameLine()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
  editor.uiInputText("Filter##groundCoverMaterialFilter", materialFilter, im.ArraySize(materialFilter), nil, nil, nil, nil)
  im.PopItemWidth()
  im.tooltip("Filter the material dropdown by name.")

  if editor_materialEditor then
    if im.Button("Open in Material Editor") then
      editor_materialEditor.showMaterialEditor()
      if current ~= "" then
        editor_materialEditor.selectMaterialByName(current, true)
      end
    end
    im.tooltip("Open the Material Editor and select the current material.")
  end
end

local function drawDistanceControls(obj, ids)
  local metrics = getPlacementMetrics(obj)
  if im.BeginTable("groundCoverDistanceFields", 2, im.TableFlags_SizingStretchProp) then
    drawDistanceSlider(obj, ids, "radius", "Visible until", 10, 500, "%.0f m")
    drawDistanceSlider(obj, ids, "dissolveRadius", "Start fading at", 0, metrics.radius, "%.0f m")
    drawDistanceSlider(obj, ids, "shapeCullRadius", "3D shape cull", 0, metrics.radius, "%.0f m")
    im.EndTable()
  end
  drawHelpText(string.format("Fade length: %.1f m. Billboards fade between start fading and visible until.", metrics.fadeLength))

  beginWrappedButtons()
  if drawWrappedButton("Auto fade/cull from radius", "Keeps visible distance, sets fade start to 80% of it, and caps shape cull at 300 m.") then
    applyAutoDistanceFromRadius(ids)
  end
  for _, profile in ipairs(rangeProfiles) do
    if drawWrappedButton(profile.rangeButtonLabel, profile.rangeTooltip) then
      applyRangeProfile(ids, profile)
    end
  end
end

local function drawDensityControls(obj, ids)
  local metrics = getPlacementMetrics(obj)
  if im.BeginTable("groundCoverDensityFields", 2, im.TableFlags_SizingStretchProp) then
    drawGridSizeSlider(obj, ids)

    im.TableNextColumn()
    im.TextUnformatted("Cell element budget")
    im.tooltip("Convenience editor for maxElements. The value here is multiplied by gridSize squared.")
    im.TableNextColumn()
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    local perCellPtr = editor.getTempInt_NumberNumber(math.floor(metrics.perCell + 0.5))
    editEnded[0] = false
    local changed = editor.uiSliderInt("##groundCoverTargetPerCell", perCellPtr, 0, maxBillboardsPerCell, nil, editEnded)
    im.PopItemWidth()
    if changed then
      local target = math.max(0, perCellPtr[0])
      if #ids > 1 then
        local values = {}
        for _, id in ipairs(ids) do
          local targetObj = scenetree.findObjectById(id)
          local targetMetrics = targetObj and getPlacementMetrics(targetObj) or metrics
          table.insert(values, tostring(target * targetMetrics.cells))
        end
        setFieldMultipleValuesLive(ids, "maxElements", values, 0)
      else
        setFieldLive(ids, "maxElements", tostring(target * metrics.cells), 0)
      end
    end
    finishLiveSliderEditIfNeeded(ids)

    drawMaxElementsSlider(obj, ids)
    im.EndTable()
  end

  metrics = getPlacementMetrics(obj)
  drawHelpText(string.format("%d cells, %.1f m cell, %.0f elements/cell.", metrics.cells, metrics.cellSize, metrics.perCell))
  if metrics.perCell > maxBillboardsPerCell then
    im.TextColored(im.ImVec4(1, 0.55, 0.25, 1), "Elements per cell is above the engine billboard index limit; it will be clamped.")
  end

  beginWrappedButtons()
  if drawWrappedButton("Auto balance grid+density", "Sets gridSize and a shared maxElements budget from each object's current radius.") then
    applyAutoBalance(ids)
  end
  for _, profile in ipairs(densityProfiles) do
    if drawWrappedButton(profile.buttonLabel, profile.tooltip) then
      applyDensityProfile(ids, obj, profile)
    end
  end
end

drawFieldLabel = function(label, tooltip)
  im.TableNextColumn()
  im.TextUnformatted(label)
  if tooltip then
    im.tooltip(tooltip)
  end
  im.TableNextColumn()
  im.PushItemWidth(im.GetContentRegionAvailWidth())
end

local function drawTextField(obj, ids, field, label, arrayIndex)
  drawFieldLabel(label, fieldTooltips[field])
  editEnded[0] = false
  local changed = editor.uiInputText("##" .. field .. tostring(arrayIndex or 0), editor.getTempCharPtr(getField(obj, field, arrayIndex)), nil, nil, nil, nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setFieldWithUndo(ids, field, editor.getTempCharPtr(), arrayIndex, "ChangeGroundCoverField")
  end
end

drawFloatField = function(obj, ids, field, label, arrayIndex, step, stepFast, format)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempFloat_NumberNumber(tonumber(getField(obj, field, arrayIndex)) or 0)
  editEnded[0] = false
  local changed = editor.uiInputFloat("##" .. field .. tostring(arrayIndex or 0), valuePtr, step or 0.1, stepFast or 1, format or "%.3f", nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setFieldWithUndo(ids, field, formatFloat(valuePtr[0]), arrayIndex, "ChangeGroundCoverField")
  end
end

drawIntField = function(obj, ids, field, label, arrayIndex, step, stepFast)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempInt_NumberNumber(tonumber(getField(obj, field, arrayIndex)) or 0)
  editEnded[0] = false
  local changed = editor.uiInputInt("##" .. field .. tostring(arrayIndex or 0), valuePtr, step or 1, stepFast or 10, nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setFieldWithUndo(ids, field, tostring(valuePtr[0]), arrayIndex, "ChangeGroundCoverField")
  end
end

drawSliderFloatField = function(obj, ids, field, label, arrayIndex, minValue, maxValue, format)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempFloat_NumberNumber(clampNumber(getField(obj, field, arrayIndex), minValue, maxValue))
  editEnded[0] = false
  local changed = editor.uiSliderFloat("##" .. field .. tostring(arrayIndex or 0), valuePtr, minValue, maxValue, format or "%.2f", nil, editEnded)
  im.PopItemWidth()
  if changed then
    setFieldLive(ids, field, formatFloat(clampNumber(valuePtr[0], minValue, maxValue)), arrayIndex)
  end
  finishLiveSliderEditIfNeeded(ids)
end

drawSliderIntField = function(obj, ids, field, label, arrayIndex, minValue, maxValue, format)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempInt_NumberNumber(math.floor(clampNumber(getField(obj, field, arrayIndex), minValue, maxValue) + 0.5))
  editEnded[0] = false
  local changed = editor.uiSliderInt("##" .. field .. tostring(arrayIndex or 0), valuePtr, minValue, maxValue, format, editEnded)
  im.PopItemWidth()
  if changed then
    setFieldLive(ids, field, tostring(math.floor(clampNumber(valuePtr[0], minValue, maxValue) + 0.5)), arrayIndex)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawBoolField(obj, ids, field, label, arrayIndex)
  drawFieldLabel(label, fieldTooltips[field])
  tempBool[0] = toBool(getField(obj, field, arrayIndex))
  if im.Checkbox("##" .. field .. tostring(arrayIndex or 0), tempBool) then
    setFieldWithUndo(ids, field, tempBool[0] and "true" or "false", arrayIndex, "ChangeGroundCoverField")
  end
  im.PopItemWidth()
end

local function drawUvField(obj, ids, arrayIndex)
  drawFieldLabel("Billboard UVs", fieldTooltips.billboardUVs)
  if not editor.groundCoverBillboardUVFieldEditor and extensions and extensions.load then
    extensions.load("editor_inspector")
  end

  local result = editor.groundCoverBillboardUVFieldEditor and editor.groundCoverBillboardUVFieldEditor(ids, getField(obj, "billboardUVs", arrayIndex), arrayIndex, getObjectId(obj))
  if result and result.editEnded then
    setFieldWithUndo(ids, "billboardUVs", result.fieldValue, arrayIndex, "ChangeGroundCoverUVs")
  end
  im.PopItemWidth()
end

local function drawShapeFileField(obj, ids, arrayIndex)
  drawFieldLabel("Shape file", fieldTooltips.shapeFilename)
  if editor.uiIconImageButton and editor.icons and editor.icons.folder then
    if editor.uiIconImageButton(editor.icons.folder, im.ImVec2(22, 22)) then
      local current = getField(obj, "shapeFilename", arrayIndex)
      local dir = current ~= "" and path.splitWithoutExt(current) or "/levels/" .. tostring(getCurrentLevelIdentifier()) .. "/art/shapes/"
      editor_fileDialog.openFile(function(data)
        if data and data.filepath then
          setFieldWithUndo(ids, "shapeFilename", data.filepath, arrayIndex, "ChangeGroundCoverShape")
        end
      end, {{"DAE Mesh", ".dae"}, {"Any files", "*"}}, false, dir, true)
    end
    im.tooltip("Choose shape file")
    im.SameLine()
  end
  editEnded[0] = false
  local changed = editor.uiInputText("##shapeFilename" .. tostring(arrayIndex), editor.getTempCharPtr(getField(obj, "shapeFilename", arrayIndex)), nil, nil, nil, nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setFieldWithUndo(ids, "shapeFilename", editor.getTempCharPtr(), arrayIndex, "ChangeGroundCoverShape")
  end
end

local function drawFieldByKind(obj, ids, entry, arrayIndex)
  if entry.kind == "text" then
    drawTextField(obj, ids, entry.field, entry.label, arrayIndex)
  elseif entry.kind == "float" then
    drawFloatField(obj, ids, entry.field, entry.label, arrayIndex, entry.step, entry.stepFast, entry.format)
  elseif entry.kind == "int" then
    drawIntField(obj, ids, entry.field, entry.label, arrayIndex, entry.step, entry.stepFast)
  elseif entry.kind == "sliderFloat" then
    drawSliderFloatField(obj, ids, entry.field, entry.label, arrayIndex, entry.min, entry.max, entry.format)
  elseif entry.kind == "sliderInt" then
    drawSliderIntField(obj, ids, entry.field, entry.label, arrayIndex, entry.min, entry.max, entry.format)
  elseif entry.kind == "bool" then
    drawBoolField(obj, ids, entry.field, entry.label, arrayIndex)
  end
end

local function drawFieldTable(tableId, obj, ids, fields, arrayIndex)
  if im.BeginTable(tableId, 2, im.TableFlags_SizingStretchProp) then
    for _, entry in ipairs(fields) do
      drawFieldByKind(obj, ids, entry, arrayIndex or 0)
    end
    im.EndTable()
  end
end

local function isTypeEnabled(obj, index)
  local probability = tonumber(getField(obj, "probability", index)) or 0
  return probability > 0
end

local function isTypeConfigured(obj, index)
  return getField(obj, "billboardUVs", index) ~= "" or getField(obj, "shapeFilename", index) ~= ""
end

local function getTotalProbability(obj)
  local total = 0
  for typeIndex = 0, maxTypes - 1 do
    total = total + math.max(0, tonumber(getField(obj, "probability", typeIndex)) or 0)
  end
  return total
end

local function drawProbabilityField(obj, ids, typeIndex)
  local probability = math.max(0, tonumber(getField(obj, "probability", typeIndex)) or 0)
  local total = getTotalProbability(obj)
  local share = total > 0 and (probability / total * 100) or 0

  drawFieldLabel(string.format("Weight (%.0f%% share)", share), fieldTooltips.probability)
  local valuePtr = editor.getTempFloat_NumberNumber(probability)
  editEnded[0] = false
  local changed = editor.uiSliderFloat("##probability" .. tostring(typeIndex), valuePtr, 0, 5, "%.2f", nil, editEnded)
  if changed then
    setFieldLive(ids, "probability", formatFloat(math.max(0, valuePtr[0])), typeIndex)
  end
  finishLiveSliderEditIfNeeded(ids)
  im.PopItemWidth()

  im.TableNextColumn()
  im.TextUnformatted("Quick weight")
  im.TableNextColumn()
  if im.SmallButton("Off##probOff" .. tostring(typeIndex)) then
    setFieldWithUndo(ids, "probability", "0", typeIndex, "ChangeGroundCoverProbability")
  end
  im.tooltip("Set this type weight to 0 so it will not be selected.")
  im.SameLine()
  if im.SmallButton("Low##probLow" .. tostring(typeIndex)) then
    setFieldWithUndo(ids, "probability", "0.25", typeIndex, "ChangeGroundCoverProbability")
  end
  im.tooltip("Set a low relative weight for rare variants.")
  im.SameLine()
  if im.SmallButton("Normal##probNormal" .. tostring(typeIndex)) then
    setFieldWithUndo(ids, "probability", "1", typeIndex, "ChangeGroundCoverProbability")
  end
  im.tooltip("Set normal relative weight.")
  im.SameLine()
  if im.SmallButton("High##probHigh" .. tostring(typeIndex)) then
    setFieldWithUndo(ids, "probability", "2", typeIndex, "ChangeGroundCoverProbability")
  end
  im.tooltip("Set high relative weight for common variants.")
end

local function setTypeEnabled(obj, ids, index, enabled)
  if enabled then
    local entries = {{field = "probability", value = "1", arrayIndex = index}}
    if not isTypeConfigured(obj, index) then
      entries = makeEntries(defaultTypeFields, index)
      local layer = getField(obj, "layer", index)
      if layer == "" then
        local layers = getTerrainLayers()
        layer = layers[1] or ""
      end
      table.insert(entries, {field = "layer", value = layer, arrayIndex = index})
    end
    setFieldsWithUndo(ids, entries, "EnableGroundCoverType")
  else
    setFieldWithUndo(ids, "probability", "0", index, "DisableGroundCoverType")
  end
end

local function copyFieldsFromObject(source, fields, arrayIndex)
  local entries = {}
  for _, field in ipairs(fields) do
    table.insert(entries, {field = field, value = getField(source, field, arrayIndex), arrayIndex = arrayIndex or 0})
  end
  return entries
end

local function copySetupFromObject(source, targetIds)
  if not source or not targetIds or #targetIds == 0 then return end
  local entries = copyFieldsFromObject(source, objectSetupFields, 0)
  for typeIndex = 0, maxTypes - 1 do
    for _, field in ipairs(typeFields) do
      table.insert(entries, {field = field, value = getField(source, field, typeIndex), arrayIndex = typeIndex})
    end
  end
  setFieldsWithUndo(targetIds, entries, "CopyGroundCoverSetup")
end

local function randomSeed()
  return tostring(math.random(1, 2147483647))
end

local function randomizeSeeds(ids)
  if not ids or #ids == 0 then return end
  local values = {}
  for _ = 1, #ids do
    table.insert(values, randomSeed())
  end
  setFieldMultipleValuesWithUndo(ids, "seed", values, 0, "RandomizeGroundCoverSeed")
end

local function applyTypePreset(ids, index, presetName)
  local entries = makeEntries(typePresets[presetName] or {}, index)
  if presetName == "empty" then
    for _, field in ipairs(typeFields) do
      table.insert(entries, {field = field, value = "", arrayIndex = index})
    end
  end
  setFieldsWithUndo(ids, entries, "ApplyGroundCoverTypePreset")
end

local function createGroundCover(defaultLayer)
  local parent = getCreateParent()
  if not parent then
    editor.logWarn(logTag .. ": no MissionGroup found.")
    return
  end

  local obj = createObject("GroundCover")
  obj:registerObject(Sim.getUniqueName("GroundCover"))
  parent:addObject(obj.obj or obj)
  obj:setField("position", 0, getCameraPositionString())
  for _, fieldValue in ipairs(defaultObjectFields) do
    obj:setField(fieldValue[1], 0, fieldValue[2])
  end
  obj:setField("layer", 0, defaultLayer or "")
  for _, fieldValue in ipairs(defaultTypeFields) do
    obj:setField(fieldValue[1], 0, fieldValue[2])
  end
  postApplyObject(obj)

  local id = getObjectId(obj)
  editor.history:commitAction("CreateGroundCover", {objectId = id}, objectHistoryActions.deleteObjectRedo, objectHistoryActions.deleteObjectUndo, true)
  editor.setDirty()
  invalidateObjectCaches()
  invalidateValidationCache()
  selectGroundCover(obj)
  refreshGroundCoverPreview()
end

local function duplicateGroundCover(source)
  if not source then return end
  local parent = source.getGroup and source:getGroup() or getCreateParent()
  local obj = createObject("GroundCover")
  obj:registerObject(Sim.getUniqueName(getObjectName(source) .. "_copy"))
  parent:addObject(obj.obj or obj)

  for _, field in ipairs(transformFields) do
    local value = getField(source, field, 0)
    if value ~= "" then
      obj:setField(field, 0, value)
    end
  end

  for _, field in ipairs(objectSetupFields) do
    local value = getField(source, field, 0)
    if value ~= "" then
      obj:setField(field, 0, value)
    end
  end

  for typeIndex = 0, maxTypes - 1 do
    for _, field in ipairs(typeFields) do
      obj:setField(field, typeIndex, getField(source, field, typeIndex))
    end
  end

  postApplyObject(obj)
  local id = getObjectId(obj)
  editor.history:commitAction("DuplicateGroundCover", {objectId = id}, objectHistoryActions.deleteObjectRedo, objectHistoryActions.deleteObjectUndo, true)
  editor.setDirty()
  invalidateObjectCaches()
  invalidateValidationCache()
  selectGroundCover(obj)
  refreshGroundCoverPreview()
end

local function deleteSelectedGroundCovers()
  local ids = getSelectedGroundCoverIds()
  if #ids == 0 and selectedGroundCoverId then
    ids = {selectedGroundCoverId}
  end
  if #ids == 0 then return end

  editor.history:beginTransaction("DeleteGroundCover")
  for _, id in ipairs(ids) do
    editor.history:commitAction("DeleteGroundCover", {objectId = id}, objectHistoryActions.deleteObjectUndo, objectHistoryActions.deleteObjectRedo)
  end
  editor.history:endTransaction()
  editor.clearObjectSelection()
  selectedGroundCoverId = nil
  editor.setDirty()
  invalidateObjectCaches()
  invalidateValidationCache()
  refreshGroundCoverPreview()
end

local function drawObjectList()
  local objects = getGroundCoverObjects()
  local filter = ffi.string(objectNameFilter):lower()
  local createParent = getCreateParent()

  im.TextUnformatted("Objects")
  im.SameLine()
  if im.Button("Refresh") then
    invalidateObjectCaches()
    invalidateTerrainLayerCache()
    invalidateValidationCache()
    objects = getGroundCoverObjects()
  end
  im.tooltip("Refresh the list of loaded GroundCover scene objects.")

  im.PushItemWidth(im.GetContentRegionAvailWidth())
  editor.uiInputText("##groundCoverFilter", objectNameFilter, im.ArraySize(objectNameFilter), nil, nil, nil, nil)
  im.PopItemWidth()
  im.tooltip("Filter objects by name")

  local parentGroups = getParentGroupObjects()
  local parentLabel = createParent and getObjectName(createParent) or "MissionGroup"
  if im.BeginCombo("Add parent##groundCoverAddParent", parentLabel) then
    for _, group in ipairs(parentGroups) do
      local groupId = getObjectId(group)
      local selected = createParent and getObjectId(createParent) == groupId
      if im.Selectable1(getObjectName(group) .. "##parent" .. tostring(groupId), selected) then
        selectedParentGroupId = groupId
      end
    end
    im.EndCombo()
  end
  im.tooltip("New GroundCover objects are added under this SimGroup. If not set, the tool falls back to selected group, vegetation, then MissionGroup.")

  local listHeight = math.max(140, im.GetContentRegionAvail().y - 80)
  if im.BeginChild1("groundCoverObjectList", im.ImVec2(0, listHeight), im.WindowFlags_ChildWindow) then
    for _, obj in ipairs(objects) do
      local name = getObjectName(obj)
      if filter == "" or name:lower():find(filter, 1, true) then
        local id = getObjectId(obj)
        if im.Selectable1(name .. "##gcObj" .. tostring(id), selectedGroundCoverId == id) then
          selectGroundCover(obj)
        end
      end
    end
  end
  im.EndChild()

  local layers = getTerrainLayers()
  local defaultLayer = layers[1] or ""
  local parentSource = getSelectedParentGroup() and "selected" or "auto"
  im.TextUnformatted("Parent (" .. parentSource .. "): " .. (createParent and getObjectName(createParent) or "MissionGroup"))
  if im.Button("Add") then
    createGroundCover(defaultLayer)
  end
  im.tooltip("Create a new GroundCover object under the shown parent group.")
  im.SameLine()
  local selected = getSelectedObject()
  if not selected then im.BeginDisabled() end
  beginWrappedButtons()
  if drawWrappedButton("Duplicate", "Duplicate the active GroundCover object and all 8 type slots.") then
    duplicateGroundCover(selected)
  end
  if drawWrappedButton("Remove", "Delete selected GroundCover objects with undo support.") then
    deleteSelectedGroundCovers()
  end
  if not selected then im.EndDisabled() end
end

local function drawNameField(obj, ids)
  if im.BeginTable("groundCoverNameField", 2, im.TableFlags_SizingStretchProp) then
    im.TableNextColumn()
    im.TextUnformatted("Name")
    im.TableNextColumn()
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    editEnded[0] = false
    local changed = editor.uiInputText("##groundCoverName", editor.getTempCharPtr(getObjectName(obj)), nil, nil, nil, nil, editEnded)
    im.PopItemWidth()
    if changed and editEnded[0] then
      local name = editor.getTempCharPtr()
      if name ~= "" then
        setFieldWithUndo(ids, "name", name, 0, "RenameGroundCover")
      end
    end
    im.EndTable()
  end
end

local function drawSeedField(obj, ids)
  drawFieldLabel("Seed", fieldTooltips.seed)
  local valuePtr = editor.getTempInt_NumberNumber(tonumber(getField(obj, "seed", 0)) or 0)
  editEnded[0] = false
  local width = im.GetContentRegionAvailWidth()
  im.PushItemWidth(math.max(80, width - 120 * im.uiscale[0]))
  local changed = editor.uiInputInt("##seed0", valuePtr, 1, 100, nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setFieldWithUndo(ids, "seed", tostring(valuePtr[0]), 0, "ChangeGroundCoverSeed")
  end
  im.SameLine()
  if im.Button("Random##groundCoverSeed") then
    randomizeSeeds(ids)
  end
  im.tooltip("Generate a new random seed. When editing multiple objects, each gets a different seed.")
  im.PopItemWidth()
end

local function drawCopySetupControls(obj, ids)
  local objects = getGroundCoverObjects()
  local currentId = getObjectId(obj)
  local source = copySourceGroundCoverId and scenetree.findObjectById(copySourceGroundCoverId) or nil
  if not source or getObjectId(source) == currentId then
    source = nil
    copySourceGroundCoverId = nil
    for _, candidate in ipairs(objects) do
      if getObjectId(candidate) ~= currentId then
        source = candidate
        copySourceGroundCoverId = getObjectId(candidate)
        break
      end
    end
  end

  im.TextUnformatted("Copy setup from")
  im.tooltip("Copies material, distance, density, seed, wind, and all type slot settings. It does not copy name, transform, or parent.")
  im.SameLine()
  im.PushItemWidth(math.max(160, im.GetContentRegionAvailWidth() - 150 * im.uiscale[0]))
  if im.BeginCombo("##groundCoverCopySetupSource", source and getObjectName(source) or "<no other GroundCover>") then
    for _, candidate in ipairs(objects) do
      local candidateId = getObjectId(candidate)
      if candidateId ~= currentId then
        if im.Selectable1(getObjectName(candidate) .. "##copySetup" .. tostring(candidateId), copySourceGroundCoverId == candidateId) then
          copySourceGroundCoverId = candidateId
        end
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()
  im.SameLine()
  if not source then im.BeginDisabled() end
  if im.Button("Apply##groundCoverCopySetup") then
    copySetupFromObject(source, ids)
  end
  im.tooltip("Apply the selected object's setup to the active/selected GroundCover objects.")
  if not source then im.EndDisabled() end
end

local function drawObjectFields(obj, ids)
  if im.CollapsingHeader1("Setup", im.TreeNodeFlags_DefaultOpen) then
    drawMaterialSelector(obj, ids)
    if im.BeginTable("groundCoverSeedFields", 2, im.TableFlags_SizingStretchProp) then
      drawSeedField(obj, ids)
      im.EndTable()
    end
  end

  if im.CollapsingHeader1("Render Distance", im.TreeNodeFlags_DefaultOpen) then
    drawDistanceControls(obj, ids)
  end

  if im.CollapsingHeader1("Density and Grid", im.TreeNodeFlags_DefaultOpen) then
    drawDensityControls(obj, ids)
  end

  if im.CollapsingHeader1("Quick Presets", 0) then
    drawHelpText("Presets are simple LOD layers: combine close detail with distant coverage.")
    beginWrappedButtons()
    for _, profile in ipairs(coverageProfiles) do
      if drawWrappedButton(profile.buttonLabel, profile.tooltip) then
        applyCoverageProfile(ids, profile)
      end
    end
  end

  if im.CollapsingHeader1("More setup", 0) then
    if im.BeginTable("groundCoverSetupFields", 2, im.TableFlags_SizingStretchProp) then
      drawSliderFloatField(obj, ids, "zOffset", "Z offset", 0, -2, 2, "%.3f m")
      im.EndTable()
    end
    drawCopySetupControls(obj, ids)
  end
end

local function drawAdvancedFields(obj, ids)
  if im.CollapsingHeader1("Advanced Render Options", 0) then
    drawFieldTable("groundCoverObjectFields", obj, ids, objectFields, 0)
  end

  if im.CollapsingHeader1("Wind", 0) then
    drawFieldTable("groundCoverWindFields", obj, ids, windFields, 0)
  end

  if im.CollapsingHeader1("Preview and Debug", 0) then
    im.Checkbox("Auto flush preview after edits", autoFlushPreview)
    im.tooltip("Flush generated GroundCover cells after edits so changes show sooner in the viewport.")
    im.SameLine()
    if im.Button("Flush preview now") then
      refreshGroundCoverPreview()
    end
    im.tooltip("Manually clear GroundCover cells so the engine regenerates them.")

    drawFieldTable("groundCoverDebugFields", obj, ids, debugFields, 0)
  end
end

local function drawDependentSliderFloat(obj, ids, typeIndex, field, label, minField, maxField, minValue, maxValue, format)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempFloat_NumberNumber(clampNumber(getField(obj, field, typeIndex), minValue, maxValue))
  editEnded[0] = false
  local changed = editor.uiSliderFloat("##" .. field .. tostring(typeIndex), valuePtr, minValue, maxValue, format or "%.3f", nil, editEnded)
  im.PopItemWidth()
  if changed then
    setDependentMinMaxValue(ids, typeIndex, minField, maxField, field, valuePtr[0], false, "ChangeGroundCoverTypeRange", true)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawDependentSliderInt(obj, ids, typeIndex, field, label, minField, maxField, minValue, maxValue)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempInt_NumberNumber(math.floor(clampNumber(getField(obj, field, typeIndex), minValue, maxValue) + 0.5))
  editEnded[0] = false
  local changed = editor.uiSliderInt("##" .. field .. tostring(typeIndex), valuePtr, minValue, maxValue, nil, editEnded)
  im.PopItemWidth()
  if changed then
    setDependentMinMaxValue(ids, typeIndex, minField, maxField, field, valuePtr[0], true, "ChangeGroundCoverTypeRange", true)
  end
  finishLiveSliderEditIfNeeded(ids)
end

local function drawDependentFloatField(obj, ids, typeIndex, field, label, minField, maxField)
  drawFieldLabel(label, fieldTooltips[field])
  local valuePtr = editor.getTempFloat_NumberNumber(tonumber(getField(obj, field, typeIndex)) or 0)
  editEnded[0] = false
  local changed = editor.uiInputFloat("##" .. field .. tostring(typeIndex), valuePtr, 1, 10, "%.2f", nil, editEnded)
  im.PopItemWidth()
  if changed and editEnded[0] then
    setDependentMinMaxValue(ids, typeIndex, minField, maxField, field, valuePtr[0], false, "ChangeGroundCoverTypeRange")
  end
end

local function drawTypeSizeFields(obj, ids, typeIndex)
  local sizeMin = clampNumber(getField(obj, "sizeMin", typeIndex), 0, 10)
  local sizeMax = math.max(sizeMin, clampNumber(getField(obj, "sizeMax", typeIndex), 0, 10))
  drawDependentSliderFloat(obj, ids, typeIndex, "sizeMin", "Size min", "sizeMin", "sizeMax", 0, math.max(0.01, sizeMax), "%.3f")
  drawDependentSliderFloat(obj, ids, typeIndex, "sizeMax", "Size max", "sizeMin", "sizeMax", sizeMin, math.max(10, sizeMin), "%.3f")
  for _, entry in ipairs(typeSizeFields) do
    drawFieldByKind(obj, ids, entry, typeIndex)
  end
end

local function drawTypePlacementFields(obj, ids, typeIndex)
  for _, entry in ipairs(typePlacementFields) do
    drawFieldByKind(obj, ids, entry, typeIndex)
  end
  drawDependentFloatField(obj, ids, typeIndex, "minElevation", "Min elevation", "minElevation", "maxElevation")
  drawDependentFloatField(obj, ids, typeIndex, "maxElevation", "Max elevation", "minElevation", "maxElevation")
end

local function drawTypeClumpFields(obj, ids, typeIndex)
  local minClumpCount = math.max(1, math.floor((tonumber(getField(obj, "minClumpCount", typeIndex)) or 1) + 0.5))
  local maxClumpCount = math.max(minClumpCount, math.floor((tonumber(getField(obj, "maxClumpCount", typeIndex)) or minClumpCount) + 0.5))
  drawDependentSliderInt(obj, ids, typeIndex, "minClumpCount", "Min clump count", "minClumpCount", "maxClumpCount", 1, math.max(1, maxClumpCount))
  drawDependentSliderInt(obj, ids, typeIndex, "maxClumpCount", "Max clump count", "minClumpCount", "maxClumpCount", minClumpCount, math.max(40, minClumpCount))
  drawSliderFloatField(obj, ids, "clumpExponent", "Clump exponent", typeIndex, -0.95, 5, "%.3f")
  drawSliderFloatField(obj, ids, "clumpRadius", "Clump radius", typeIndex, 0, 20, "%.3f")
end

local function drawTypeSlot(obj, ids, typeIndex)
  local enabled = isTypeEnabled(obj, typeIndex)
  tempBool[0] = enabled
  if im.Checkbox("Enabled##typeEnabled" .. tostring(typeIndex), tempBool) then
    setTypeEnabled(obj, ids, typeIndex, tempBool[0])
  end
  im.tooltip("Enable or disable this type slot by setting its core fields.")
  im.SameLine()
  im.TextUnformatted("Type " .. tostring(typeIndex + 1))

  beginWrappedButtons()
  if drawWrappedButton("Grass slot preset##" .. tostring(typeIndex), "Configure this slot as a billboard grass variant.") then
    applyTypePreset(ids, typeIndex, "grass")
  end
  if drawWrappedButton("Shape slot preset##" .. tostring(typeIndex), "Configure this slot for sparse 3D shapes; choose the shape file below.") then
    applyTypePreset(ids, typeIndex, "shape")
  end
  if drawWrappedButton("Clear slot##" .. tostring(typeIndex), "Clear all fields for this type slot.") then
    applyTypePreset(ids, typeIndex, "empty")
  end

  if im.BeginTable("groundCoverTypeFields" .. tostring(typeIndex), 2, im.TableFlags_SizingStretchProp) then
    im.TableNextColumn()
    im.TextUnformatted("Layer")
    im.tooltip(fieldTooltips.layer)
    im.TableNextColumn()
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    drawLayerCombo("##layer" .. tostring(typeIndex), obj, typeIndex, ids)
    im.PopItemWidth()

    drawFieldByKind(obj, ids, invertLayerField, typeIndex)
    drawProbabilityField(obj, ids, typeIndex)
    drawUvField(obj, ids, typeIndex)
    drawShapeFileField(obj, ids, typeIndex)
    drawTypeSizeFields(obj, ids, typeIndex)
    im.EndTable()
  end

  if im.CollapsingHeader1("Placement filters##type" .. tostring(typeIndex), 0) then
    if im.BeginTable("groundCoverTypePlacementFields" .. tostring(typeIndex), 2, im.TableFlags_SizingStretchProp) then
      drawTypePlacementFields(obj, ids, typeIndex)
      im.EndTable()
    end
  end

  if im.CollapsingHeader1("Clumping##type" .. tostring(typeIndex), 0) then
    if im.BeginTable("groundCoverTypeClumpFields" .. tostring(typeIndex), 2, im.TableFlags_SizingStretchProp) then
      drawTypeClumpFields(obj, ids, typeIndex)
      im.EndTable()
    end
  end
end

local function drawTypeEditor(obj, ids)
  if im.BeginTabBar("groundCoverTypeTabs") then
    for typeIndex = 0, maxTypes - 1 do
      local label = tostring(typeIndex + 1)
      if isTypeEnabled(obj, typeIndex) then
        label = label .. " *"
      end
      if im.BeginTabItem(label .. "##gcType" .. tostring(typeIndex)) then
        drawTypeSlot(obj, ids, typeIndex)
        im.EndTabItem()
      end
    end
    im.EndTabBar()
  end
end

local function getHealthWarnings(obj)
  local warnings = {}
  local _, layerLookup = getTerrainLayers()
  local activeTypes = 0
  local metrics = getPlacementMetrics(obj)

  local function warn(message)
    table.insert(warnings, message)
  end

  local function typeWarn(typeIndex, message)
    warn("Type " .. tostring(typeIndex + 1) .. " " .. message)
  end

  local function numberField(field, arrayIndex)
    return tonumber(getField(obj, field, arrayIndex or 0)) or 0
  end

  local radius = numberField("radius")
  local dissolveRadius = numberField("dissolveRadius")
  local shapeCullRadius = numberField("shapeCullRadius")
  local reflectScale = numberField("reflectScale")
  local maxElements = numberField("maxElements")
  local maxBillboardTiltAngle = numberField("maxBillboardTiltAngle")
  local windGustLength = numberField("windGustLength")
  local windGustFrequency = numberField("windGustFrequency")
  local windGustStrength = numberField("windGustStrength")
  local windTurbulenceFrequency = numberField("windTurbulenceFrequency")
  local windTurbulenceStrength = numberField("windTurbulenceStrength")
  local windDirection = stringToTable(getField(obj, "windDirection", 0)) or {}
  local windDirectionLength = math.sqrt((tonumber(windDirection[1]) or 0) ^ 2 + (tonumber(windDirection[2]) or 0) ^ 2)
  local useNewPlacementGpu = toBool(getField(obj, "useNewPlacement", 0)) and toBool(getField(obj, "useNewPlacementGpu", 0))
  local hasActiveBillboards = false
  local hasActiveShapes = false
  local maxActiveWindScale = 0

  if radius <= 0 then
    warn("radius must be above 0 for grid generation.")
  end
  if dissolveRadius < 0 then
    warn("dissolveRadius should not be negative.")
  end
  if radius > 0 and dissolveRadius > radius then
    warn("dissolveRadius is larger than radius.")
  end
  if shapeCullRadius < 0 then
    warn("shapeCullRadius should not be negative.")
  end
  if reflectScale < 0 then
    warn("reflectScale should not be negative.")
  end
  if maxElements <= 0 then
    warn("maxElements must be above 0 or no cells will generate cover.")
  end
  if maxBillboardTiltAngle < 0 or maxBillboardTiltAngle > 90 then
    warn("maxBillboardTiltAngle should stay between 0 and 90 degrees.")
  end
  if windGustLength <= 0 then
    warn("windGustLength must be above 0; the foliage shader divides by it.")
  end
  if windGustFrequency < 0 or windTurbulenceFrequency < 0 then
    warn("Wind frequencies should not be negative.")
  end
  if windGustStrength < 0 or windTurbulenceStrength < 0 then
    warn("Wind strengths should not be negative.")
  end
  if windDirectionLength > 1.5 then
    warn("windDirection length is above 1 and will amplify wind displacement.")
  end
  if numberField("gridSize") < 2 then
    warn("gridSize below 2 will be forced to 2 at runtime.")
  end
  if radius > 120 and metrics.gridSize < 5 then
    warn("Large radius with low gridSize can create coarse cell updates and visible generation steps.")
  end
  if metrics.cellSize > 100 then
    warn("Grid cells are very large; increase gridSize or reduce radius to avoid coarse generation/pop-in while moving.")
  elseif metrics.cellSize < 4 and radius > 0 then
    warn("Grid cells are very small; reduce gridSize or radius to avoid excessive cell churn.")
  end
  if metrics.perCell > maxBillboardsPerCell then
    warn("maxElements / gridSize^2 exceeds the per-cell billboard limit and will be clamped.")
  end
  if maxElements > 0 and metrics.qualityPerCell < 1 then
    warn("Current grass density scale makes effective elements per cell below 1, so cover may not generate.")
  end

  local material = getField(obj, "material", 0)
  if material ~= "" and material ~= "Empty" and not scenetree.findObject(material) then
    warn("Material '" .. material .. "' is not loaded.")
  end

  for typeIndex = 0, maxTypes - 1 do
    local enabled = isTypeEnabled(obj, typeIndex)
    local billboardUVs = getField(obj, "billboardUVs", typeIndex)
    local shapeFilename = getField(obj, "shapeFilename", typeIndex)
    local hasShape = shapeFilename ~= ""
    local uvValues = billboardUVs ~= "" and stringToTable(billboardUVs) or nil
    local billboardWidth = uvValues and tonumber(uvValues[3]) or 0
    local billboardHeight = uvValues and tonumber(uvValues[4]) or 0
    local hasBillboard = billboardUVs ~= "" and billboardWidth > 0 and billboardHeight > 0
    if enabled then
      activeTypes = activeTypes + 1
      hasActiveBillboards = hasActiveBillboards or hasBillboard
      hasActiveShapes = hasActiveShapes or hasShape
      maxActiveWindScale = math.max(maxActiveWindScale, math.abs(numberField("windScale", typeIndex)))
    end
    local layer = getField(obj, "layer", typeIndex)
    if layer ~= "" and not layerLookup[layer] then
      typeWarn(typeIndex, "references missing terrain layer '" .. layer .. "'.")
    end
    if enabled and hasBillboard and layer == "" and useNewPlacementGpu then
      typeWarn(typeIndex, "has no terrain layer; GPU placement requires an explicit layer for billboard generation.")
    end
    local probability = numberField("probability", typeIndex)
    if probability < 0 then
      typeWarn(typeIndex, "has negative probability.")
    end
    if enabled and not hasShape and not hasBillboard then
      typeWarn(typeIndex, "has no valid billboard UVs or shape file, so it will not render.")
    end
    if billboardUVs ~= "" and not hasBillboard then
      typeWarn(typeIndex, "billboard UV width/height must be above 0.")
    end
    if hasBillboard and uvValues then
      local u = tonumber(uvValues[1]) or 0
      local v = tonumber(uvValues[2]) or 0
      if u < 0 or v < 0 or u + billboardWidth > 1 or v + billboardHeight > 1 then
        typeWarn(typeIndex, "billboard UV rectangle is outside the 0..1 material atlas range.")
      end
    end
    if hasBillboard and (material == "" or material == "Empty") then
      typeWarn(typeIndex, "uses billboard UVs but the object material is Empty.")
    end

    local sizeMin = numberField("sizeMin", typeIndex)
    local sizeMax = numberField("sizeMax", typeIndex)
    local sizeExponent = numberField("sizeExponent", typeIndex)
    if enabled and (sizeMin < 0 or sizeMax < 0) then
      typeWarn(typeIndex, "sizeMin/sizeMax should not be negative.")
    end
    if enabled and sizeMax < sizeMin then
      typeWarn(typeIndex, "sizeMax is smaller than sizeMin.")
    end
    if enabled and sizeExponent <= 0 then
      typeWarn(typeIndex, "sizeExponent should be above 0.")
    end

    local minElevation = tonumber(getField(obj, "minElevation", typeIndex))
    local maxElevation = tonumber(getField(obj, "maxElevation", typeIndex))
    if minElevation and maxElevation and maxElevation < minElevation then
      typeWarn(typeIndex, "maxElevation is smaller than minElevation.")
    end

    local maxSlope = numberField("maxSlope", typeIndex)
    if maxSlope < 0 then
      typeWarn(typeIndex, "maxSlope below 0 rejects all terrain.")
    elseif maxSlope > 90 then
      typeWarn(typeIndex, "maxSlope above 90 degrees is unusual for terrain placement.")
    end

    local minClumpCount = tonumber(getField(obj, "minClumpCount", typeIndex))
    local maxClumpCount = tonumber(getField(obj, "maxClumpCount", typeIndex))
    local clumpExponent = numberField("clumpExponent", typeIndex)
    local clumpRadius = numberField("clumpRadius", typeIndex)
    if enabled and clumpExponent <= -1 then
      typeWarn(typeIndex, "clumpExponent must be above -1; GPU placement divides by clumpExponent + 1.")
    end
    if enabled and clumpRadius < 0 then
      typeWarn(typeIndex, "clumpRadius should not be negative.")
    end
    if minClumpCount and minClumpCount < 1 then
      typeWarn(typeIndex, "minClumpCount below 1 will be treated as 1.")
    end
    if maxClumpCount and maxClumpCount < 1 then
      typeWarn(typeIndex, "maxClumpCount below 1 will be treated as 1.")
    end
    if minClumpCount and maxClumpCount and maxClumpCount < minClumpCount then
      typeWarn(typeIndex, "maxClumpCount is smaller than minClumpCount.")
    end
  end

  if activeTypes == 0 then
    warn("No active type slots.")
  end
  if hasActiveBillboards and radius > 0 then
    local fadeLength = radius - dissolveRadius
    local minFadeLength = math.max(5, radius * 0.1)
    if fadeLength <= 0 then
      warn("Billboard fade range is zero or negative; the foliage shader needs dissolveRadius below radius.")
    elseif dissolveRadius <= 0 then
      warn("Billboards fade from the camera outward; set dissolveRadius above 0 for more predictable distance fading.")
    elseif fadeLength < minFadeLength then
      warn("Billboard fade range is very short and may cause visible pop-in; lower dissolveRadius or increase radius.")
    end
  end
  if hasActiveBillboards and maxActiveWindScale > 0 and (windGustStrength + windTurbulenceStrength) * maxActiveWindScale > 5 then
    warn("Combined wind strength and per-type windScale are high; billboards may visibly jump or shimmer.")
  end
  if hasActiveBillboards and metrics.qualityPerCell < 50 then
    warn("Effective billboard density per cell is very low; distant grass may look sparse or appear/disappear in chunks.")
  end
  if hasActiveShapes and shapeCullRadius > 0 and shapeCullRadius < math.min(radius, dissolveRadius) then
    warn("shapeCullRadius is inside the billboard fade range, so 3D shapes may pop before the cover fades out.")
  end

  return warnings
end

local function getCachedHealthWarnings(obj)
  local objectId = getObjectId(obj)
  if validationCache.objectId == objectId and not validationCache.dirty and validationCache.warnings then
    return validationCache.warnings
  end

  validationCache.objectId = objectId
  validationCache.warnings = getHealthWarnings(obj)
  validationCache.dirty = false
  return validationCache.warnings
end

local function drawHealthPanel(warnings)
  if #warnings == 0 then
    im.TextColored(im.ImVec4(0.5, 1, 0.5, 1), "Settings Validation: OK")
    return
  end

  im.TextColored(im.ImVec4(1, 0.75, 0.25, 1), string.format("Settings Validation: %d warning(s)", #warnings))
  if im.BeginChild1("##GroundCoverValidationScroll", im.ImVec2(0, 110 * im.uiscale[0]), true) then
    for _, warning in ipairs(warnings) do
      im.BulletText(warning)
    end
  end
  im.EndChild()
end

local function drawDetails()
  local obj = getSelectedObject()
  if not obj then
    drawHelpText("Select or add a GroundCover object.")
    return
  end

  local selectedIds = getSelectedGroundCoverIds()
  if #selectedIds == 0 then
    selectedIds = {getObjectId(obj)}
  end

  im.Separator()
  im.TextUnformatted("Active: " .. getObjectName(obj))
  drawNameField(obj, selectedIds)

  local warnings = getCachedHealthWarnings(obj)
  local validationHeight = im.GetTextLineHeightWithSpacing()
  if #warnings > 0 then
    validationHeight = validationHeight + 110 * im.uiscale[0] + im.GetStyle().ItemSpacing.y
  end
  local tabsHeight = math.max(120 * im.uiscale[0], im.GetContentRegionAvail().y - validationHeight - im.GetStyle().ItemSpacing.y)

  if im.BeginChild1("##GroundCoverTabsArea", im.ImVec2(0, tabsHeight), im.WindowFlags_ChildWindow) then
    if im.BeginTabBar("groundCoverEditorTabs") then
      if im.BeginTabItem("General", nil, im.TabItemFlags_None) then
        drawObjectFields(obj, selectedIds)
        im.EndTabItem()
      end

      if im.BeginTabItem("Types", nil, im.TabItemFlags_None) then
        drawTypeEditor(obj, selectedIds)
        im.EndTabItem()
      end

      if im.BeginTabItem("Advanced", nil, im.TabItemFlags_None) then
        drawAdvancedFields(obj, selectedIds)
        im.EndTabItem()
      end

      im.EndTabBar()
    end
  end
  im.EndChild()

  im.Separator()
  drawHealthPanel(warnings)
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Ground Cover Editor") then
    local tableFlags = im.TableFlags_SizingStretchProp + im.TableFlags_Resizable
    if im.BeginTable("groundCoverMainLayout", 2, tableFlags) then
      im.TableSetupColumn("Objects", im.TableColumnFlags_WidthFixed, 260 * im.uiscale[0])
      im.TableSetupColumn("Editor", im.TableColumnFlags_WidthStretch)
      im.TableNextRow()

      im.TableSetColumnIndex(0)
      if im.BeginChild1("groundCoverObjectsPane", im.ImVec2(0, 0), im.WindowFlags_ChildWindow) then
        drawObjectList()
      end
      im.EndChild()

      im.TableSetColumnIndex(1)
      if im.BeginChild1("groundCoverDetailsPane", im.ImVec2(0, 0), im.WindowFlags_ChildWindow) then
        drawDetails()
      end
      im.EndChild()

      im.EndTable()
    else
      drawObjectList()
      drawDetails()
    end
  end
  editor.endWindow()
end

local function show()
  editor.showWindow(toolWindowName)
  editor.selectEditMode(editor.editModes.groundCoverEditMode)
end

local function onActivate()
  editor.showWindow(toolWindowName)
end

local function onEditorObjectSelectionChanged()
  local selectedIds = getSelectedGroundCoverIds()
  if selectedIds[1] then
    selectedGroundCoverId = selectedIds[1]
  end
  invalidateValidationCache()
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(920, 720))
  editor.editModes.groundCoverEditMode = {
    displayName = editModeName,
    onActivate = onActivate,
    auxShortcuts = {},
    hideObjectIcons = false,
  }
  editor.editModes.groundCoverEditMode.auxShortcuts[editor.AuxControl_LMB] = "Select"
  editor.addWindowMenuItem("Ground Cover Editor", show)
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.onEditorObjectSelectionChanged = onEditorObjectSelectionChanged
M.show = show

return M
