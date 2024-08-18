-- local M = {}

-- local API = extensions.editor_api_dynamicDecals
-- local utils = extensions.ui_liveryEditor_utils
-- local uiCameraApi = extensions.ui_liveryEditor_camera
-- local uiLayersApi = extensions.ui_liveryEditor_layers

-- local LOCKED_LAYER_ACTIONS = {"rename", "visibility", "lock", "delete"}
-- local MULTI_TYPES_LAYER_ACTIONS = {"group", "visibility", "lock", "delete"}
-- local MULTI_DECAL_LAYER_ACTIONS = {"group", "material", "duplicate", "mirror", "visibility", "lock", "delete"}
-- local MULTI_FILL_LAYER_ACTIONS = {"duplicate", "visibility", "lock", "delete"}

-- local selectedLayers = {}

-- local getUiFormattedSelectedLayers = function()
--   local uiFormattedLayers = {}

--   for key, layerUid in ipairs(selectedLayers) do
--     local layer = uiLayersApi.getLayerByUid(layerUid)
--     table.insert(uiFormattedLayers, layer)
--   end

--   return uiFormattedLayers
-- end

-- local addToSelection = function(layerUid)
--   table.insert(selectedLayers, layerUid)
-- end

-- local removeFromSelection = function(layerUid)
--   for i, selectedLayerUid in ipairs(selectedLayers) do
--     if selectedLayerUid == layerUid then
--       table.remove(selectedLayers, i)
--       return true
--     end
--   end

--   return false
-- end

-- local getFirstSelectedLayer = function()
--   for _, value in ipairs(selectedLayers) do
--     return value
--   end
-- end

-- local getAvailableActions = function()
--   if not selectedLayers then
--     return nil
--   end

--   if #selectedLayers == 1 then
--     local selectedLayer = uiLayersApi.getLayerByUid(getFirstSelectedLayer())
--     local selectedLayerType = selectedLayer.type

--     if selectedLayerType == API.layerTypes.decal then
--       return extensions.ui_liveryEditor_layers_decals.getLayerActions()
--     elseif selectedLayerType == API.layerTypes.fill then
--       return extensions.ui_liveryEditor_layers_fill.getLayerActions(selectedLayer)
--     elseif selectedLayerType == API.layerTypes.linkedSet then
--       return extensions.ui_liveryEditor_layers_group.getLayerActions()
--     else
--       log("D", "", "Layer actions not implemented for " .. selectedLayerType)
--     end
--   else
--     -- do filtering here
--     local layerTypes = {}

--     for _, v in ipairs(selectedLayers) do
--       local layer = uiLayersApi.getLayerByUid(v)

--       if not layerTypes[layer.type] then
--         layerTypes[layer.type] = true
--       end
--     end

--     local layerType
--     local layerTypeCount = 0
--     for k, _ in pairs(layerTypes) do
--       layerType = k
--       layerTypeCount = layerTypeCount + 1
--     end

--     if layerTypeCount > 1 then
--       return MULTI_TYPES_LAYER_ACTIONS
--     elseif layerType == API.layerTypes.decal then
--       return MULTI_DECAL_LAYER_ACTIONS
--     elseif layerType == API.layerTypes.fill then
--       return MULTI_FILL_LAYER_ACTIONS
--     end
--   end
-- end

-- local notifyUiListeners = function()
--   guihooks.trigger("LiveryEditor_SelectedLayersChanged", selectedLayers)
--   guihooks.trigger("LiverEditorLayerActionsUpdated", getAvailableActions())
--   guihooks.trigger("LiveryEditor_SelectedLayersDataUpdated", getUiFormattedSelectedLayers())
-- end

-- local clearSelection = function()
--   selectedLayers = {}
--   notifyUiListeners()
-- end

-- local getSelectedLayers = function()
--   return selectedLayers
-- end

-- local isLayerSelected = function(layerUid)
--   for _, value in ipairs(selectedLayers) do
--     if layerUid == value then
--       return true
--     end
--   end

--   return false
-- end

-- local setSelected = function(layerUid, moveCamera)
--   selectedLayers = {layerUid}

--   local layer = API.getLayerByUid(layerUid)

--   if layer.type == API.layerTypes.decal then
--     uiCameraApi.setCameraViewByPosition(layer.camPosition)
--   else
--     uiCameraApi.setCameraView(uiCameraApi.CAMERA_VIEWS.RIGHT)
--   end

--   notifyUiListeners()
-- end

-- local setMultipleSelected = function(layerUids)
--   dump("[selection] setMultipleSelected", layerUids)
--   selectedLayers = layerUids

--   notifyUiListeners()
-- end

-- M.setSelected = setSelected
-- M.setMultipleSelected = setMultipleSelected
-- M.clearSelection = clearSelection
-- M.getSelectedLayers = getSelectedLayers
-- M.getFirstSelectedLayer = getFirstSelectedLayer
-- M.addToSelection = addToSelection
-- M.removeFromSelection = removeFromSelection
-- M.getSelectedLayersData = getUiFormattedSelectedLayers

-- -- External hooks. Do not call!
-- M.dynamicDecals_onLayerDeleted = function(layerUid)
--   local success = M.removeFromSelection(layerUid)
--   if success then
--     notifyUiListeners()
--   end
-- end

-- M.liveryEditor_onLayersUpdated = function(layerUid)
--   if isLayerSelected(layerUid) then
--     guihooks.trigger("LiveryEditor_SelectedLayersDataUpdated", getUiFormattedSelectedLayers())
--   end
-- end

-- return M
