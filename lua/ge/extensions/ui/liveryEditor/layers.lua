-- local M = {}

-- local api = extensions.editor_api_dynamicDecals
-- local utils = extensions.ui_liveryEditor_utils
-- local uiCameraApi = extensions.ui_liveryEditor_camera
-- local uiFillApi = extensions.ui_liveryEditor_layers_fill

-- -- Layer Cached Data
-- -- Id
-- -- Path - path from root
-- local layerMap = {}
-- local layers = {}

-- local transformLayerUiFormat = function(layer, coordinates)
--   local formattedLayer = {
--     uid = layer.uid,
--     id = layer.uid,
--     name = layer.name,
--     type = layer.type,
--     enabled = layer.enabled,
--     locked = layer.locked
--   }

--   if layer.type == api.layerTypes.decal then
--     formattedLayer.preview = layer.decalColorTexturePath
--     formattedLayer.rotation = utils.convertRadiansToDegrees(layer.decalRotation)
--     formattedLayer.mirrored = layer.mirrored
--     formattedLayer.mirrorFlipped = layer.flipMirroredDecal
--     formattedLayer.scale = {
--       x = layer.decalScale.x,
--       y = layer.decalScale.z
--     }
--     formattedLayer.skew = {
--       x = utils.roundAndTruncateDecimal(layer.decalSkew.x),
--       y = utils.roundAndTruncateDecimal(layer.decalSkew.y)
--     }
--     formattedLayer.position = utils.getXYCoordinates(layer.decalPos, uiCameraApi.getOrientationCoordinates())
--     formattedLayer.color = layer.color:toTable()
--     formattedLayer.metallicIntensity = layer.metallicIntensity
--     formattedLayer.normalIntensity = layer.normalIntensity
--     formattedLayer.roughnessIntensity = layer.roughnessIntensity
--   elseif layer.type == api.layerTypes.fill then
--     formattedLayer.colorPaletteMapId = layer.colorPaletteMapId

--     if layer.colorPaletteMapId == 0 then
--       formattedLayer.color = layer.color:toTable()
--     else
--       local colorPaletteData = uiFillApi.getColorPaletteDataById(layer.colorPaletteMapId)
--       formattedLayer.color = colorPaletteData.color
--     end
--   elseif layer.type == api.layerTypes.linkedSet then
--     dump("transformLayerUiFormat", layer)
--     for k, property in ipairs(layer.properties) do
--       dump("property key", k)
--       dump("property value", property)
--       if property.id == "color" then
--         formattedLayer.color = property.value:toTable()
--       end
--     end
--   end

--   return formattedLayer
-- end

-- local function parseLayersData(layersData, parentUid, parentPath, parentPathIndices)
--   local uiLayers = {}

--   for key in ipairs(layersData) do
--     local layer = layersData[key]
--     local uiLayer = transformLayerUiFormat(layer, uiCameraApi.getOrientationCoordinates())

--     uiLayer.order = key
--     uiLayer.parentUid = parentUid
--     uiLayer.path = parentPath
--     uiLayer.pathIndices = parentPathIndices
--     uiLayer.childrenCount = layer.children and #layer.children or 0

--     if layer.children and #layer.children > 0 then
--       local layerPath = parentPath and shallowcopy(parentPath) or {}
--       table.insert(layerPath, layer.uid)

--       local layerPathIndices = parentPathIndices and shallowcopy(parentPathIndices) or {}
--       table.insert(layerPathIndices, key)

--       uiLayer.children = parseLayersData(layer.children, layer.uid, layerPath, layerPathIndices)
--     end

--     table.insert(uiLayers, uiLayer)

--     layerMap[uiLayer.uid] = {
--       order = key,
--       parentUid = parentUid,
--       layer = shallowcopy(uiLayer)
--     }
--   end

--   return uiLayers
-- end

-- local function notifyUIListeners()
--   guihooks.trigger("LiveryEditorLayersUpdate", layers)
-- end

-- local function rebuildLayerData()
--   layerMap = {}
--   layers = parseLayersData(api.getLayerStack())
--   notifyUIListeners()
-- end

-- M.getLayers = function()
--   return layers
-- end

-- M.getLayerByUid = function(layerUid)
--   return layerMap[layerUid].layer
-- end

-- M.getLayerByOrder = function(order, parentUid)
--   dump("getLayerByUid", order .. " " .. (parentUid or "nil"))
--   for k, layer in ipairs(layerMap) do
--     if parentUid == layer.parentUid and layer.order == order then
--       return layer
--     end
--   end
-- end

-- M.getChildrenCount = function(layerUid)
--   if not layerUid then
--     return #layers
--   end

--   local count = 0
--   for k, layer in ipairs(layerMap) do
--     if layer.parentUid == layerUid then
--       count = count + 1
--     end
--   end

--   return count
-- end

-- -- External hooks. Do not call!
-- M.dynamicDecals_onLayerAdded = function(layerUid)
--   dump("dynamicDecals_onLayerAdded", layerUid)
--   rebuildLayerData()
-- end

-- M.dynamicDecals_onLayerDeleted = function(layerUid)
--   dump("dynamicDecals_onLayerDeleted", layerUid)
--   rebuildLayerData()
-- end

-- M.dynamicDecals_onLayerUpdated = function(layerUid)
--   dump("dynamicDecals_onLayerUpdated", layerUid)
--   rebuildLayerData()
--   extensions.hook("liveryEditor_onLayersUpdated", layerUid)
-- end

-- M.dynamicDecals_moveLayer = function(from, fromParentUid, to, toParentUid)
--   dump("dynamicDecals_moveLayer",
--     "from: " ..
--     from .. ", fromParent: " .. (fromParentUid or "nil") .. ", to: " .. to .. ", toParent: " .. (toParentUid or "nil"))
--   local movedLayer = M.getLayerByOrder(from, fromParentUid)
--   rebuildLayerData()

--   if movedLayer then
--     extensions.hook("liveryEditor_onLayersUpdated", movedLayer.uid)
--   end
-- end

-- return M
