local M = {}

local api = extensions.editor_api_dynamicDecals

-- save files
local saveDir = 'settings/dynamicDecals/'
local saveFilenamePattern = "^[a-zA-Z0-9_-]+$"
local dynDecalsExtension = '.dynDecals.json'

-- textures
local texturesDirectoryPath = "/art/dynamicDecals/textures"
local categories = { "digit", "gradient", "layer", "letter", "logo", "noise", "pattern", "shape", "team", "various" }
local othersCategory = "others"

local decalDefaultSettings = {
  scale = vec3(0.5, 1, 0.5),
  rotation = 0,
  color = Point4F(1, 1, 1, 1),
  skew = Point2F(0, 0),
  texture = '/art/dynamicDecals/textures/shape_circle.png'
}

local currentSaveFile = nil
local cachedUiLayerAncestorsMap = nil
local cachedUiLayerStack = nil
local selectedLayer = nil
local applyMultipleDecal = true
local resetDecalSettingsOnApply = false
local isApplyingDecal = false
local isRunning = false
local exportSkinName = nil

local function getFilename(file)
  local _, fn, e = path.split(file)
  return fn:sub(1, #fn - #dynDecalsExtension)
end

local function getCategorizedTextures()
  local textureFiles = FS:findFiles(texturesDirectoryPath, '*.png', -1, false, false)
  local groupedTextures = {}

  for k, file in ipairs(textureFiles) do
    local _, filename, _ = path.split(file)
    local category = nil

    for _, catvalue in ipairs(categories) do
      category = filename:sub(1, #catvalue) == catvalue and catvalue or nil

      if category then break end
    end

    category = category and category or othersCategory

    if not groupedTextures or not groupedTextures[category] then
      table.insert(groupedTextures, category)
      groupedTextures[category] = { category = category, textures = {} }
    end

    local texture = { name = filename, location = file }
    table.insert(groupedTextures[category].textures, texture)
  end

  return groupedTextures
end

local function truncateNumber(num, decimalPlaces)
  return tonumber(string.format("%." .. (decimalPlaces or 0) .. "f", num))
end

local function getAvailableSaveFiles()
  local saveFiles = {}
  local files = FS:findFiles(saveDir, '*' .. dynDecalsExtension, -1, false, false)
  for i, file in ipairs(files) do
    saveFiles[i] = { name = getFilename(file), location = file }
  end
  return saveFiles
end

local function convertUiRotationToGeRotation(rotation)
  if not rotation or rotation == 0 then return 0 end
  return rotation / 180 * math.pi
end

local function convertGeRotationToUiRotation(rotation)
  if not rotation or rotation == 0 then return 0 end

  return truncateNumber(rotation * 180 / math.pi, 1)
end

local function convertGeScaleToUiScale(scale) return { x = truncateNumber(scale.x, 1), y = truncateNumber(scale.z, 1) } end

local function convertUiScaleToGeScale(scale) return vec3(scale.x, 1, scale.y) end

local function convertGeSkewToUiSkew(skew) return { x = truncateNumber(skew.x, 1), y = truncateNumber(skew.y, 1) } end

local function convertUiSkewToGeSkew(skew) return Point2F(skew.x, skew.y) end

local function getDecalSettings()
  local settings = {}

  local rotation = api.getDecalRotation()
  settings.rotation = convertGeRotationToUiRotation(rotation)
  settings.texture = api.getDecalTexturePath("color")

  settings.color = api.getDecalColor():toTable()
  settings.color[4] = 1

  local scale = api.getDecalScale()
  settings.scale = convertGeScaleToUiScale(scale)

  local skew = api.getDecalSkew()
  settings.skew = convertGeSkewToUiSkew(skew)

  settings.applyMultiple = applyMultipleDecal
  settings.resetOnApply = resetDecalSettingsOnApply

  return settings
end

local function getFillSettings()
  local colorPaletteMap = api.propertiesMap["fill_colorPaletteMapId"]
  local vehicleObj = getPlayerVehicle(0)

  local values = {}
  local colorPaletteMapColor = api.getFillLayerColor()

  for i = colorPaletteMap.min, colorPaletteMap.max do
    if i == 1 then
      colorPaletteMapColor = vehicleObj.color
    elseif i == 2 then
      colorPaletteMapColor = vehicleObj.colorPalette0
    elseif i == 3 then
      colorPaletteMapColor = vehicleObj.colorPalette1
    end

    values[i + 1] = {
      value = i,
      label = colorPaletteMap.options[i + 1],
      color = colorPaletteMapColor
          :toTable(),
      canEdit = i == 0
    }
  end

  local settings = {}

  -- local color = api.getFillLayerColor()
  -- settings.color = color:toTable()
  settings.colorPaletteMapId = colorPaletteMap.value
  settings.colorPaletteMapValues = values

  return settings
end

local function getEditorResources()
  local resources = {}
  resources.decalSettings = getDecalSettings()
  resources.decalTextures = getCategorizedTextures()
  resources.fillSettings = getFillSettings()
  return resources
end

local function resetDecalSettings(notifyUi)
  if not api then return end

  api.setDecalScale(decalDefaultSettings.scale)
  -- api.setDecalColor(decalDefaultSettings.color)
  api.setDecalRotation(decalDefaultSettings.rotation)
  api.setDecalSkew(decalDefaultSettings.skew)
  -- api.setDecalTexturePath("color", decalDefaultSettings.texture)

  if notifyUi then
    local resources = getEditorResources()
    guihooks.trigger("DynamicDecalsResourcesUpdated", resources)
  end
end

local function convertLayerToUiData(layer)
  local uiLayer = {}

  uiLayer.uid = layer.uid
  uiLayer.name = layer.name
  uiLayer.enabled = layer.enabled
  uiLayer.type = layer.type

  if layer.type == api.layerTypes.decal then
    uiLayer.color = layer.color and layer.color:toTable() or nil
    uiLayer.decalScale = layer.decalScale and convertGeScaleToUiScale(layer.decalScale) or nil
    uiLayer.decalColorTexturePath = layer.decalColorTexturePath or nil
    uiLayer.decalSkew = layer.decalSkew and convertGeSkewToUiSkew(layer.decalSkew) or nil
  elseif layer.type == api.layerTypes.fill then
    uiLayer.colorPaletteMapId = layer.colorPaletteMapId or nil

    if layer.colorPaletteMapId == 0 then
      uiLayer.color = layer.color:toTable()
    else
      local vehicleObj = getPlayerVehicle(0)

      if layer.colorPaletteMapId == 1 then
        uiLayer.color = vehicleObj.color:toTable()
      elseif layer.colorPaletteMapId == 2 then
        uiLayer.color = vehicleObj.colorPalette0:toTable()
      elseif layer.colorPaletteMapId == 3 then
        uiLayer.color = vehicleObj.colorPalette1:toTable()
      end
    end
  end

  local rotation = nil
  if layer.decalRotation and type(layer.decalRotation) == "number" then
    rotation = layer.decalRotation
  elseif layer.decalRotation and layer.decalRotation:toTable() then
    rotation = layer.decalRotation:toTable()[1]
  end
  uiLayer.decalRotation = rotation and convertGeRotationToUiRotation(rotation)

  return uiLayer
end

local function convertLayerStackToUiData(layerStack, parentUid, layerPath)
  local uiLayerStack = {}

  for key, layer in pairs(layerStack) do
    local uiLayerData = convertLayerToUiData(layer)

    uiLayerData.order = #uiLayerStack + 1
    uiLayerData.parentUid = parentUid

    uiLayerData.path = layerPath and shallowcopy(layerPath) or {}
    table.insert(uiLayerData.path, uiLayerData.uid)

    uiLayerStack[key] = uiLayerData
    cachedUiLayerAncestorsMap[uiLayerData.uid] = uiLayerData

    if layer.children and #layer.children > 0 then
      uiLayerData.children = convertLayerStackToUiData(layer.children, uiLayerData.uid, uiLayerData.path)
    end
  end

  return uiLayerStack
end

local function onLayerUpdated(payload)
  cachedUiLayerAncestorsMap = {}

  local apiLayerStack = api.getLayerStack()
  cachedUiLayerStack = convertLayerStackToUiData(apiLayerStack)

  local history = api.getHistory()

  guihooks.trigger("DynamicDecalsDataUpdated", { operation = payload, layers = cachedUiLayerStack, history = history })

  if payload and payload.type == "layer_added" then
    local currentLayer = payload.layerUid

    if isApplyingDecal and applyMultipleDecal then
      currentLayer = selectedLayer and selectedLayer.uid or nil
    end

    M.selectLayer(currentLayer)
  elseif payload and payload.type == "layer_updated" then
    M.selectLayer(payload.layerUid)
  end
end

local function reset()
  currentSaveFile = nil
  selectedLayer = nil
  cachedUiLayerAncestorsMap = nil
  cachedUiLayerStack = nil
  applyMultipleDecal = true
  resetDecalSettingsOnApply = false
  isApplyingDecal = false
  guihooks.trigger("DynamicDecalsSaveFileLoaded", nil)
  guihooks.trigger("DynamicDecalsDataUpdated", nil)
end

local function toggleVehicleControls(enable)
  local commonActionMap = scenetree.findObject("VehicleCommonActionMap")
  if commonActionMap then commonActionMap:setEnabled(enable) end

  local specificActionMap = scenetree.findObject("VehicleSpecificActionMap")
  if specificActionMap then specificActionMap:setEnabled(enable) end
end

M.toggleActionMap = function(enable)
  local o = scenetree.findObject("DynamicDecalsUIActionMap")
  if o then o:setEnabled(enable) end
end

M.toggleStampActionMap = function(enable)
  if enable then
    pushActionMap("DynamicDecalsStampUI")
  else
    popActionMap("DynamicDecalsStampUI")
  end
end

M.initialize = function()
  cachedUiLayerAncestorsMap = nil
  cachedUiLayerStack = nil
  selectedLayer = nil

  toggleVehicleControls(false)

  popActionMap("dynamicDecals")
  pushActionMap("DynamicDecalsUI")

  -- if currentSaveFile then
  --   M.loadSaveFile(currentSaveFile)
  -- else
  -- M.setupEditor()
  -- isRunning = true

  local saveFiles = getAvailableSaveFiles()
  guihooks.trigger("DynamicDecalSaveFilesUpdated", saveFiles)
  -- end
end

M.setupEditor = function()
  api.setLayerNameBuildString("@type{ - @colormap}")
  api.setup()

  core_vehicle_partmgmt.setSkin("dynamicTextures")
  extensions.editor_dynamicDecalsTool.doApiUpdate = false

  isRunning = true

  resetDecalSettings()
  -- exclude decal color from resetting
  api.setDecalColor(decalDefaultSettings.color)
  M.toggleDecalVisibility(false)
end

M.loadSaveFile = function(path_string)
  currentSaveFile = path_string

  -- M.setupEditor()

  local res = api.loadLayerStackFromFile(path_string)
  local filename = getFilename(currentSaveFile)
  guihooks.trigger("DynamicDecalsSaveFileLoaded",
    { success = res.status.code == 0, file = path_string, filename = filename })
  guihooks.trigger('ChangeState', { state = 'decals-editor' })
end

M.createSaveFile = function()
  -- if not string.match(filename, saveFilenamePattern) then
  --   log("W", "", "Cannot create invalid filename: " .. filename)
  --   return
  -- end

  -- local path = saveDir .. filename .. dynDecalsExtension

  -- M.setupEditor()

  -- local thePlayer = scenetree.findObject("thePlayer")
  local vehicleObj = getPlayerVehicle(0)

  api.clearLayerStack()
  api.setFillLayerColorPaletteMapId(1)
  api.setFillLayerColor(vehicleObj.color)
  api.addFillLayer()
  -- api.saveLayerStackToFile(path)

  local history = api.getHistory()
  history:clear()

  -- currentSaveFile = path
  currentSaveFile = nil
  selectedLayer = nil

  -- guihooks.trigger("DynamicDecalsSaveFileLoaded", { success = true, file = path })
  -- guihooks.trigger("DynamicDecalSaveFilesUpdated", getAvailableSaveFiles())
  guihooks.trigger('ChangeState', { state = 'decals-editor' })
end

M.toggleApplyingDecal = function(enable)
  isApplyingDecal = enable
  M.toggleDecalVisibility(enable)
  M.toggleActionMap(enable)
end

M.toggleDecalVisibility = function(visible)
  local alpha = visible and 1 or 0
  local color = api.getDecalColor()

  api.setDecalColor(Point4F(color.x, color.y, color.z, alpha))
  -- local resources = getEditorResources()
  -- guihooks.trigger("DynamicDecalsResourcesUpdated", resources)
end

M.requestUpdatedData = function()
  onLayerUpdated()

  local resources = getEditorResources()
  guihooks.trigger("DynamicDecalsResourcesUpdated", resources)
end

M.saveChanges = function(filename)
  if not string.match(filename, saveFilenamePattern) then
    log("W", "", "Cannot create invalid filename: " .. filename)
    return
  end

  local path = saveDir .. filename .. dynDecalsExtension
  api.saveLayerStackToFile(path)
  reset()
  guihooks.trigger('ChangeState', { state = 'garagemode' })
end

M.cancelChanges = function()
  local history = api.getHistory()

  if history.undoStack and #history.undoStack > 0 then
    for i = 1, #history.undoStack do
      api.undo()
    end
    api.reprojectLayers()
  end

  reset()

  guihooks.trigger('ChangeState', { state = 'garagemode' })
end

M.createLayer = function(layerData)
  dump(layerData)
  if not layerData then
    log("W", "", "Attempting to create a layer with empty data")
    return
  end

  layerData.parentUid = selectedLayer and selectedLayer.uid

  if layerData.type == api.layerTypes.fill then
    M.createFillLayer(layerData)
  elseif layerData.type == api.layerTypes.group then
    M.createGroupLayer(layerData)
  end
end

M.createFillLayer = function(layerData)
  dump(layerData)

  api.setFillLayerColorPaletteMapId(layerData.colorPaletteMapId)

  if layerData.color then
    local color = Point4F.fromTable(layerData.color)
    api.setFillLayerColor(color)
  end
  api.addFillLayer(layerData)

  local resources = getEditorResources()
  guihooks.trigger("DynamicDecalsResourcesUpdated", resources)
end

M.createGroupLayer = function(layerData)
  dump(layerData)
  api.addGroup(layerData)
end

local function isMouseOverlapVehicle()
  local thePlayer = scenetree.findObject("thePlayer")
  local mouseRay = getCameraMouseRay()
  local bb = thePlayer:getSpawnWorldOOBB()

  local intersects = intersectsRay_OBB(mouseRay.pos, mouseRay.dir, bb:getCenter(), bb:getAxis(0) * bb:getHalfExtents().x,
    bb:getAxis(1) * bb:getHalfExtents().y, bb:getAxis(2) * bb:getHalfExtents().z)

  return not isinf(intersects)
end

M.createDecal = function()
  local isOverlap = isMouseOverlapVehicle()

  if not isOverlap then
    log("D", "", "Cannot apply decal outside of car")
    return
  end
  local params = { name = "decal", parentUid = selectedLayer and selectedLayer.uid }

  api.addDecal(params)

  if resetDecalSettingsOnApply then
    resetDecalSettings(true)
  end

  if not applyMultipleDecal then
    resetDecalSettings(true)
    M.toggleDecalVisibility(false)
    M.toggleActionMap(false)
  end
end

local function updateFillLayer(layerData, layerUpdates)
  if layerUpdates.colorPaletteMapId then
    layerData.colorPaletteMapId = layerUpdates.colorPaletteMapId
  end

  if layerUpdates.color then
    layerData.color = Point4F.fromTable(layerUpdates.color)
  end
end

local function updateDecalLayer(layer, layerUpdates)
  if layerUpdates.color then
    layer.color = Point4F.fromTable(layerUpdates.color)
  end

  if layerUpdates.decalColorTexturePath then
    layer.decalColorTexturePath = layerUpdates.decalColorTexturePath
  end

  if layerUpdates.decalScale then
    layer.decalScale = vec3(layerUpdates.decalScale.x, 1.0, layerUpdates.decalScale.y)
  end

  if layerUpdates.decalRotation then
    layer.decalRotation = convertUiRotationToGeRotation(layerUpdates.decalRotation)
  end

  if layerUpdates.decalSkew then
    layer.decalSkew = convertUiSkewToGeSkew(layerUpdates.decalSkew)
  end
end

M.updateLayer = function(layerData)
  if not layerData or not layerData.uid then
    log("W", "", "Attempting to updated selectedLayer with empty data")
    return
  end

  if not selectedLayer or not selectedLayer.uid then
    log("W", "", "Attempting to update selectedLayer with a nil value")
    return
  end

  if selectedLayer.uid ~= layerData.uid then
    log("W", "", "Attempting to update selectedLayer but the uid is not the same")
    return
  end

  local layer = api.getLayerByUid(layerData.uid)

  layer.name = layerData.name or layer.name

  if layerData.type == api.layerTypes.fill then
    updateFillLayer(layer, layerData)
  elseif layerData.type == api.layerTypes.decal then
    updateDecalLayer(layer, layerData)
  end

  api.setLayer(layer, true)
end

M.deleteSelectedLayer = function()
  if selectedLayer then
    api.removeLayer(selectedLayer.order, selectedLayer.parentUid)
    M.deselectLayer()
  else
    log("W", "", "Attempting to call deleteSelectedLayer on selectedLayer with nil value")
  end
end

M.moveSelectedLayer = function(newOrder)
  if not selectedLayer then
    log("W", "", "Attempting to move selectedLayer with nil value")
    return
  end

  local parentUid = selectedLayer and selectedLayer.parentUid
  local parentLayer = parentUid and api.getLayerByUid(parentUid)
  local childrenCount = parentLayer and #parentLayer.children or #api.getLayerStack()

  if newOrder < 1 or newOrder > childrenCount then
    log("W", "", "Attempting to move selectedLayer with index " .. newOrder .. " in range 1 - " .. childrenCount)
    return
  end

  api.moveLayer(selectedLayer.order, parentUid, newOrder, parentUid)
  M.selectLayer(selectedLayer.uid)
end

M.selectLayer = function(layerUid)
  selectedLayer = nil
  if layerUid and cachedUiLayerAncestorsMap and cachedUiLayerAncestorsMap[layerUid] then
    selectedLayer = shallowcopy(cachedUiLayerAncestorsMap[layerUid])
  end
  guihooks.trigger("DynamicDecalsLayerSelected", selectedLayer)
end

M.deselectLayer = function()
  selectedLayer = nil
  guihooks.trigger("DynamicDecalsLayerSelected", selectedLayer)
end

M.toggleLayerHighlight = function(uid)
  local highlightedLayer = api.getHighlightedLayer()
  local highlighted = false

  if highlightedLayer == nil or not highlightedLayer.uid == uid then
    api.highlightLayerByUid(uid)
    highlighted = true
  else
    api.disableDecalHighlighting()
  end

  highlightedLayer = api.getHighlightedLayer()
  guihooks.trigger("DynamicDecalsHighlightedLayerChanged", { uid = uid, highlighted })
end

M.toggleLayerVisibility = function(uid)
  local res = api.toggleLayerVisibility(uid)
  local layer = cachedUiLayerAncestorsMap and cachedUiLayerAncestorsMap[uid] and cachedUiLayerAncestorsMap[uid] or {}
  layer.enabled = res
  guihooks.trigger("DynamicDecalsLayerUpdated", layer)
end

M.setDecalTexture = function(file_path)
  api.setDecalTexturePath("color", file_path)
end

M.setDecalColor = function(color)
  api.setDecalColor(Point4F.fromTable(color))
end

M.setDecalScale = function(scale)
  dump(scale)
  api.setDecalScale(convertUiScaleToGeScale(scale))
end

M.increaseDecalScale = function(step)
  step = step and step or 0.1
  local scale = api.getDecalScale()

  local newScale = scale - step
end

M.setDecalRotation = function(rotation)
  api.setDecalRotation(convertUiRotationToGeRotation(rotation))
end

M.setDecalSkew = function(skew)
  api.setDecalSkew(convertUiSkewToGeSkew(skew))
end

M.setDecalApplyMultiple = function(applyMultiple)
  applyMultipleDecal = applyMultiple
end

M.setDecalResetOnApply = function(resetOnApply)
  resetDecalSettingsOnApply = resetOnApply
end

M.redo = function()
  api.redo()
  onLayerUpdated()
  M.selectLayer(nil)
end

M.undo = function()
  api.undo()
  onLayerUpdated()
  M.selectLayer(nil)
end

M.exportSkin = function(skinName)
  local playerVehicle = extensions.core_vehicles.getCurrentVehicleDetails()
  api.exportSkin(playerVehicle.current.key, skinName)
  exportSkinName = skinName
end

M.exit = function()
  popActionMap("DynamicDecalsUI")
  toggleVehicleControls(true)

  core_vehicle_partmgmt.setSkin(exportSkinName)
  exportSkinName = nil

  isRunning = false
end

M.onUpdate = function(dtReal, dtSim, dtRaw)
  if isRunning then
    api.onUpdate_()
  end
end


-- API hooks
M.dynamicDecals_onLayerAdded = function(layerUid)
  onLayerUpdated({ type = "layer_added", layerUid = layerUid })
end
M.dynamicDecals_onLayerDeleted = function(layerUid)
  onLayerUpdated({ type = "layer_deleted", layerUid = layerUid })
end
M.dynamicDecals_onLayerUpdated = function(layerUid)
  onLayerUpdated({ type = "layer_updated", layerUid = layerUid })
end
M.dynamicDecals_moveLayer = function(from, fromParentUid, to, toParentUid)
  onLayerUpdated({ type = "layer_moved", layerUid = from })
end

return M
