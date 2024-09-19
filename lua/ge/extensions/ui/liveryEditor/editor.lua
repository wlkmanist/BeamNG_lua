-- Core file and Api interface to the UI
local M = {}

M.dependencies = {"editor_api_dynamicDecals", "ui_liveryEditor_layers", "ui_liveryEditor_layers_decals",
                  "ui_liveryEditor_layers_cursor", "ui_liveryEditor_camera", "ui_liveryEditor_controls",
                  "ui_liveryEditor_resources", "ui_liveryEditor_selection", "ui_liveryEditor_tools",
                  "ui_liveryEditor_tools_transform", "ui_liveryEditor_editMode"}

local api = extensions.editor_api_dynamicDecals
local texturesApi = extensions.editor_api_dynamicDecals_textures
local uiControlsApi = extensions.ui_liveryEditor_controls
local uiLayersApi = extensions.ui_liveryEditor_layers
local uiDecalApi = extensions.ui_liveryEditor_layers_decals
local uiResourcesApi = extensions.ui_liveryEditor_resources
local uiSelectionApi = extensions.ui_liveryEditor_selection
local uiToolsApi = extensions.ui_liveryEditor_tools
local uiUtilsApi = extensions.ui_liveryEditor_utils
local uiUserDataApi = extensions.ui_liveryEditor_userData
local uiEditMode = extensions.ui_liveryEditor_editMode

local SAVE_FILENAME_PATTERN = "^[a-zA-Z0-9_-]+$"

local setupComplete = false
local isRunning = false
local currentFile = nil
local hasLoadedFile = false
local applyOnExit = false

local function toggleVehicleControls(enable)
  local commonActionMap = scenetree.findObject("VehicleCommonActionMap")
  if commonActionMap then
    commonActionMap:setEnabled(enable)
  end

  local specificActionMap = scenetree.findObject("VehicleSpecificActionMap")
  if specificActionMap then
    specificActionMap:setEnabled(enable)
  end
end

local loadFile = function()
  api.loadLayerStackFromFile(currentFile)
  api.onUpdate_()
end

local createNew = function()
  local vehicleObj = getPlayerVehicle(0)

  api.clearLayerStack()
  api.setFillLayerColorPaletteMapId(1)
  api.setFillLayerColor(vehicleObj.color)
  api.addFillLayer()

  local history = api.getHistory()
  history:clear()

  api.onUpdate_()
end

M.startEditor = function()
  -- if not setupComplete then
  log("I", "", "Starting initial setup. Skipping...")
  api.setLayerNameBuildString("@type { - @colormap}")
  api.setup()

  core_vehicle_partmgmt.setSkin("dynamicTextures")
  extensions.editor_dynamicDecalsTool.doApiUpdate = false
  uiResourcesApi.setup()
  uiEditMode.setup()
  setupComplete = true

  -- disable vehicle controls
  toggleVehicleControls(false)

  isRunning = true

  uiControlsApi.disableAllActionMaps()
  api.setEnabled(false)
end

M.startSession = function()
  if not setupComplete then
    log("W", "Editor has not been setup")
    return
  end

  if hasLoadedFile and currentFile then
    loadFile()
    local filename = uiUserDataApi.getFilename(currentFile)
    guihooks.trigger("LiveryEditor_onSaveFileLoaded", {
      name = filename,
      location = currentFile
    })
    uiLayersApi.requestInitialData()
  else
    guihooks.trigger("LiveryEditor_onSaveFileLoaded", nil)
    createNew()
  end

  uiSelectionApi.setup()
end

M.createNew = function()
  currentFile = nil
  hasLoadedFile = false
end

M.loadFile = function(file)
  if not FS:fileExists(file) then
    log("W", "", "File " .. file .. " not found")
    return false
  end

  currentFile = file
  hasLoadedFile = true

  return true
end

M.save = function(filename)
  if not hasLoadedFile and not filename then
    log("W", "", "No loaded file saved or specified filename. Cannot save")
    return
  end

  local playerVehicle = extensions.core_vehicles.getCurrentVehicleDetails()
  api.exportSkin(playerVehicle.current.key, filename)

  local path = uiUserDataApi.createSaveFile(filename)
  currentFile = path
  hasLoadedFile = true
  guihooks.trigger("LiveryEditor_onSaveFileLoaded", {
    name = filename,
    location = path
  })
end

M.applySkin = function()
  if hasLoadedFile and currentFile then
    core_vehicle_partmgmt.setSkin(currentFile)
    applyOnExit = true
  else
    log("W", "", "No loaded file saved or specified filename. Cannot apply skin")
  end
end

M.exitEditor = function()
  if not applyOnExit then
    core_vehicle_partmgmt.setSkin(nil)
  end

  uiControlsApi.disableAllActionMaps()
  currentFile = nil
  hasLoadedFile = false
  applyOnExit = false
  isRunning = false
  setupComplete = false

  toggleVehicleControls(true)
end

M.onUpdate = function()
  if isRunning then
    api.onUpdate_()
  end
end

return M
