-- -- Core file and Api interface to the UI
-- local M = {}

-- M.dependencies = { "editor_api_dynamicDecals", "ui_liveryEditor_layers", "ui_liveryEditor_layers_decals",
--   "ui_liveryEditor_camera", "ui_liveryEditor_controls", "ui_liveryEditor_resources", "ui_liveryEditor_selection",
--   "ui_liveryEditor_tools", "ui_liveryEditor_tools_transform" }

-- local api = extensions.editor_api_dynamicDecals
-- local texturesApi = extensions.editor_api_dynamicDecals_textures
-- local uiControlsApi = extensions.ui_liveryEditor_controls
-- local uiLayersApi = extensions.ui_liveryEditor_layers
-- local uiDecalApi = extensions.ui_liveryEditor_layers_decals
-- local uiResourcesApi = extensions.ui_liveryEditor_resources
-- local uiSelectionApi = extensions.ui_liveryEditor_selection
-- local uiToolsApi = extensions.ui_liveryEditor_tools
-- local uiUtilsApi = extensions.ui_liveryEditor_utils
-- local uiUserDataApi = extensions.ui_liveryEditor_userData

-- local SAVE_FILENAME_PATTERN = "^[a-zA-Z0-9_-]+$"

-- local setupComplete = false
-- local isRunning = false
-- local currentFile = nil
-- local hasLoadedFile = false

-- local loadFile = function()
--   api.loadLayerStackFromFile(currentFile)
--   api.onUpdate_()
-- end

-- local createNew = function()
--   local vehicleObj = getPlayerVehicle(0)

--   api.clearLayerStack()
--   api.setFillLayerColorPaletteMapId(1)
--   api.setFillLayerColor(vehicleObj.color)
--   api.addFillLayer()

--   local history = api.getHistory()
--   history:clear()

--   api.onUpdate_()
-- end

-- M.startEditor = function()
--   if not setupComplete then
--     log("I", "", "Starting initial setup. Skipping...")
--     api.setLayerNameBuildString("@type { - @colormap}")
--     api.setup()
--     uiResourcesApi.setup()

--     core_vehicle_partmgmt.setSkin("dynamicTextures")
--     extensions.editor_dynamicDecalsTool.doApiUpdate = false
--     setupComplete = true
--   end

--   uiControlsApi.useCursorProjection()

--   -- hide decal cursor
--   uiDecalApi.showCursor(false)

--   isRunning = true
-- end

-- M.startSession = function()
--   if not setupComplete then
--     log("W", "Editor has not been setup")
--     return
--   end

--   if hasLoadedFile and currentFile then
--     loadFile()
--     local filename = uiUserDataApi.getFilename(currentFile)
--     guihooks.trigger("LiveryEditorLoadedFile", { name = filename, location = currentFile })
--   else
--     createNew()
--   end
-- end

-- M.createNew = function()
--   currentFile = nil
--   hasLoadedFile = false
-- end

-- M.loadFile = function(file)
--   if not FS:fileExists(file) then
--     log("W", "", "File " .. file .. " not found")
--     return false
--   end

--   currentFile = file
--   hasLoadedFile = true

--   return true
-- end

-- M.save = function(filename)
--   if not hasLoadedFile and not filename then
--     log("W", "", "No loaded file saved or specified filename. Cannot save")
--     return
--   end

--   local playerVehicle = extensions.core_vehicles.getCurrentVehicleDetails()
--   api.exportSkin(playerVehicle.current.key, filename)

--   -- if not uiUserDataApi.saveFileExists(filename) then
--   local path = uiUserDataApi.createSaveFile(filename)
--   currentFile = path
--   hasLoadedFile = true
--   guihooks.trigger("LiveryEditorLoadedFile", { name = filename, location = path })
--   -- end
-- end

-- M.exitEditor = function()
--   core_vehicle_partmgmt.setSkin(nil)
--   uiControlsApi.disableAllActionMaps()
--   currentFile = nil
--   hasLoadedFile = false
--   isRunning = false
--   setupComplete = false
-- end

-- M.applyDecal = function()
--   uiDecalApi.showCursor(true)
--   uiDecalApi.createDecal()
--   uiDecalApi.showCursor(false)
-- end

-- M.onUpdate = function()
--   if isRunning then
--     api.onUpdate_()
--   end
-- end

-- -- External hooks. Do not call!
-- M.dynamicDecals_onLayerAdded = function(layerUid)
--   local layer = api.getLayerByUid(layerUid)

--   if #uiLayersApi.getLayers() <= 1 then
--     return
--   end

--   -- Ignore if a tool is in used because it will be an update to a selected layer that requires recreation of the layer
--   if layer.type == api.layerTypes.decal and not uiToolsApi.getCurrentTool() then
--     uiSelectionApi.setSelected(layerUid)
--     uiToolsApi.useTool(uiToolsApi.TOOLS.transform)
--   elseif layer.type == api.layerTypes.fill and layer.colorPaletteMapId == 0 then
--     uiSelectionApi.setSelected(layerUid)
--     uiToolsApi.useTool(uiToolsApi.TOOLS.material)
--   end
-- end

-- M.dynamicDecals_onLayerDeleted = function(layerUid)
--   local selectedLayers = uiSelectionApi.getSelectedLayers()
--   if #selectedLayers == 0 then
--     uiToolsApi.closeCurrentTool()
--   end
-- end

-- return M
