-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {
  "editor_api_dynamicDecals",
  "ui_liveries",
  "ui_liveries_camera",
  "ui_liveries_paint",
  "ui_liveries_textures",
}

local LAYERS_UPDATED_EVENT = "liveries_decal_layersUpdated"
local SELECTION_CHANGED_EVENT = "liveries_decal_selectionChanged"
local TRANSFORM_UPDATED_EVENT = "liveries_decal_transformUpdated"

local layers = {}
local selectedLayerUid = nil
local isActive = false
local api = extensions.editor_api_dynamicDecals

local existingTransformSession = nil

local pendingAddTargetUid = nil

local cursorForcedMousePosOff = false

local TRANSFORM_ACTION_MAP = "LiveriesDecalTransform"
local SCALE_SPEED = 0.5 -- scale units per second, at full stick deflection
local MIN_DECAL_SCALE = 0.01
local SKEW_SPEED = 2 -- skew units per second, at full stick deflection
local ROTATION_SPEED = math.pi -- radians per second, at full trigger pressure
local TWO_PI = math.pi * 2

local SMALL_INCREMENT_MULTIPLIER = 0.1

local DEFAULT_DECAL_SCALE = { x = 0.5, y = 1.0, z = 0.5 }
local DEFAULT_DECAL_SKEW = { x = 0, y = 0 }
local DEFAULT_DECAL_ROTATION = 0

local DEFAULT_MIRRORED = false
local DEFAULT_FLIP_MIRRORED_DECAL = false
local DEFAULT_MIRROR_OFFSET = 0
local MIRROR_OFFSET_LIMIT = 1

local CENTER_UV = 0.5
local CENTERED_UV_EPSILON = 0.01

local TRANSFORM_PAINT_UID = "transform-preview"

local PROJECTION_SURFACE_LABEL = "ui.liveries.edit.transform.projection.surface"
local PROJECTION_CAMERA_LABEL = "ui.liveries.edit.transform.projection.camera"

local transformActionMapActive = false
local scaleInputHorizontal = 0
local scaleInputVertical = 0
local skewInputHorizontal = 0
local skewInputVertical = 0
local rotateLeftValue = 0
local rotateRightValue = 0
local smallIncrements = false
local lockRatio = false

local function getHighlightedLayerUid()
  if not api then return nil end
  local highlighted = api.getHighlightedLayer()
  return highlighted and highlighted.uid or nil
end

local function wrapRotation(value)
  value = math.fmod(value, TWO_PI)
  if value < 0 then value = value + TWO_PI end
  return value
end

local function buildTransformSnapshot()
  local scale = api.getDecalScale()
  local skew = api.getDecalSkew()
  local rotationDeg = math.deg(api.getDecalRotation())

  return {
    scale = {
      x = string.format("%.2f", scale.x),
      y = string.format("%.2f", scale.z),
    },
    skew = {
      x = string.format("%.2f", skew.x),
      y = string.format("%.2f", skew.y),
    },
    rotation = string.format("%.1f", rotationDeg),
    projection = api.getUseSurfaceNormal() and PROJECTION_SURFACE_LABEL or PROJECTION_CAMERA_LABEL,
    smallIncrements = smallIncrements,
    lockRatio = lockRatio,
  }
end

local function notifyTransform()
  if not api then return end
  guihooks.trigger(TRANSFORM_UPDATED_EVENT, buildTransformSnapshot())
end

local function resetTransform()
  api.setDecalScale(vec3(DEFAULT_DECAL_SCALE.x, DEFAULT_DECAL_SCALE.y, DEFAULT_DECAL_SCALE.z))
  api.setDecalSkew(Point2F(DEFAULT_DECAL_SKEW.x, DEFAULT_DECAL_SKEW.y))
  api.setDecalRotation(DEFAULT_DECAL_ROTATION)
end

local function buildMirrorSnapshot()
  return {
    mirrored = api.getMirrored() == true,
    flipMirroredDecal = api.getFlipMirroredDecal() == true,
    mirrorOffset = api.getMirrorOffset() or DEFAULT_MIRROR_OFFSET,
  }
end

local function resetMirror()
  api.setMirrored(DEFAULT_MIRRORED)
  api.setFlipMirroredDecal(DEFAULT_FLIP_MIRRORED_DECAL)
  api.setMirrorOffset(DEFAULT_MIRROR_OFFSET)
end

local function getLayerColor(layer)
  if layer.color then
    return layer.color:toTable()
  end

  if layer.properties then
    for _, property in ipairs(layer.properties) do
      if property.id == "color" and property.value then
        return property.value:toTable()
      end
    end
  end
end

local function clearHighlight()
  api.disableDecalHighlighting()
end

local function highlightLayer(layerUid)
  local layer = api.getLayerByUid(layerUid)
  if not layer then
    log("W", "liveries", string.format("can't highlight layer, no layer with uid '%s'", tostring(layerUid)))
    return false
  end

  clearHighlight()
  api.highlightLayerByUid(layerUid)
  return true
end

local function buildLayerNodes(layerStack, highlightedUid)
  local nodes = {}

  for _, layer in ipairs(layerStack) do
    local kind
    if layer.type == api.layerTypes.decal then
      kind = "decal"
    elseif layer.type == api.layerTypes.linkedSet or layer.type == api.layerTypes.group then
      kind = "group"
    end

    if kind then
      local node = {
        uid = layer.uid,
        name = layer.name,
        kind = kind,
        preview = layer.decalColorTexturePath,
        color = getLayerColor(layer),
        enabled = layer.enabled ~= false,
        highlighted = layer.uid == highlightedUid,
      }

      if layer.children and #layer.children > 0 then
        node.children = buildLayerNodes(layer.children, highlightedUid)
      end

      -- newest layer sits on top of the stack, so it goes first in the tree
      table.insert(nodes, 1, node)
    end
  end

  return nodes
end

local function containsLayer(nodes, layerUid)
  for _, node in ipairs(nodes) do
    if node.uid == layerUid then
      return true
    end
    if node.children and containsLayer(node.children, layerUid) then
      return true
    end
  end
  return false
end

local function findLayerNode(nodes, layerUid)
  for _, node in ipairs(nodes) do
    if node.uid == layerUid then
      return node
    end
    if node.children then
      local found = findLayerNode(node.children, layerUid)
      if found then return found end
    end
  end
end

local function findFirstNewLayerUid(oldNodes, newNodes)
  for _, node in ipairs(newNodes) do
    if not containsLayer(oldNodes, node.uid) then
      return node.uid
    end
    if node.children then
      local childUid = findFirstNewLayerUid(oldNodes, node.children)
      if childUid then return childUid end
    end
  end
end

local function notifyLayers()
  guihooks.trigger(LAYERS_UPDATED_EVENT, layers)
end

local function notifySelection()
  guihooks.trigger(SELECTION_CHANGED_EVENT, selectedLayerUid)
end

local function rebuildLayers(markNewFocus)
  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return
  end

  local previousLayers = layers
  local highlightedUid = getHighlightedLayerUid()
  layers = buildLayerNodes(api.getLayerStack(), highlightedUid)

  if markNewFocus then
    local focusUid = findFirstNewLayerUid(previousLayers, layers)
    local focusNode = focusUid and findLayerNode(layers, focusUid)
    if focusNode then
      focusNode.focus = true
    end
  end

  if highlightedUid and not containsLayer(layers, highlightedUid) then
    clearHighlight()
  end

  if selectedLayerUid and not containsLayer(layers, selectedLayerUid) then
    selectedLayerUid = nil
    notifySelection()
  end
end

M.setup = function()
  isActive = true
  selectedLayerUid = nil
  pendingAddTargetUid = nil

  if api then
    clearHighlight()
  end

  rebuildLayers()
end

M.teardown = function()
  M.endExistingTransform()
  M.hideSelectedCursor()

  isActive = false
  selectedLayerUid = nil
  pendingAddTargetUid = nil
  ui_liveries_textures.clearSelectedItem()
  layers = {}

  if api then
    clearHighlight()
  end
end

M.notifyUi = function()
  notifyLayers()
  notifySelection()
end

M.select = function(layerUid)
  if not api then return false end

  if selectedLayerUid == layerUid then return true end

  if layerUid then
    if not highlightLayer(layerUid) then return false end
  else
    clearHighlight()
  end

  selectedLayerUid = layerUid
  notifySelection()
  return true
end

local function findLayerLocation(layerUid, siblings, parentUid)
  for index, layer in ipairs(siblings) do
    if layer.uid == layerUid then
      return index, parentUid
    end

    if layer.children and #layer.children > 0 then
      local childIndex, childParentUid = findLayerLocation(layerUid, layer.children, layer.uid)
      if childIndex then return childIndex, childParentUid end
    end
  end
end

local function locateLayer(layerUid, action)
  local index, parentUid = findLayerLocation(layerUid, api.getLayerStack())
  if not index then
    log("W", "liveries", string.format("can't %s layer, no layer with uid '%s'", action, tostring(layerUid)))
  end
  return index, parentUid
end

local function refreshLayers()
  rebuildLayers()
  notifyLayers()
end

M.toggleLayerVisibility = function(layerUid)
  if not api or not layerUid then return end

  local layer = api.getLayerByUid(layerUid)
  if not layer then
    log("W", "liveries", string.format("can't toggle layer visibility, no layer with uid '%s'", tostring(layerUid)))
    return
  end

  local updatedLayer = deepcopy(layer)
  updatedLayer.enabled = layer.enabled == false
  api.setLayer(updatedLayer, true)
  refreshLayers()
end

M.toggleLayerHighlight = function(layerUid)
  if not api or not layerUid then return end

  if getHighlightedLayerUid() == layerUid then
    clearHighlight()
  else
    local layer = api.getLayerByUid(layerUid)
    if not layer or layer.enabled == false then return end
    if not highlightLayer(layerUid) then return end
  end

  refreshLayers()
end

M.duplicateLayer = function(layerUid)
  if not api or not layerUid then return end

  local index, parentUid = locateLayer(layerUid, "duplicate")
  if not index then return end

  api.duplicateLayer(index, parentUid)
end

M.deleteLayer = function(layerUid)
  if not api or not layerUid then return end

  local index, parentUid = locateLayer(layerUid, "delete")
  if not index then return end

  api.removeLayer(index, parentUid)
end

local function sameOrder(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

local function withoutUid(uids, layerUid)
  local result = {}
  for _, uid in ipairs(uids) do
    if uid ~= layerUid then table.insert(result, uid) end
  end
  return result
end

local function findMovedUid(currentOrder, nextOrder)
  if #currentOrder ~= #nextOrder then return nil end

  for i = 1, #nextOrder do
    if currentOrder[i] ~= nextOrder[i] then
      for _, candidate in ipairs({ nextOrder[i], currentOrder[i] }) do
        if sameOrder(withoutUid(currentOrder, candidate), withoutUid(nextOrder, candidate)) then
          return candidate
        end
      end
      return nil
    end
  end
end

-- first layer is the fill layer so decals can't be moved below it
local FIRST_MOVABLE_ROOT_INDEX = 2

M.reorderLayers = function(orderedUids)
  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return false
  end

  if type(orderedUids) ~= "table" or #orderedUids == 0 then
    log("W", "liveries", "can't reorder layers, no layer order given")
    return false
  end

  local currentOrder = {}
  for _, node in ipairs(layers) do
    table.insert(currentOrder, node.uid)
  end

  if sameOrder(currentOrder, orderedUids) then
    notifyLayers()
    return true
  end

  local movedUid = findMovedUid(currentOrder, orderedUids)
  if not movedUid then
    log("W", "liveries", "can't reorder layers, the given order isn't a single layer move")
    return false
  end

  local fromIndex, fromParentUid = locateLayer(movedUid, "reorder")
  if not fromIndex then return false end
  if fromParentUid then
    log("W", "liveries", string.format("can't reorder layer '%s', only root layers can be reordered", tostring(movedUid)))
    return false
  end

  local movedLayer = api.getLayerByUid(movedUid)
  if not movedLayer or movedLayer.type ~= api.layerTypes.decal then
    log("W", "liveries", string.format("can't reorder layer '%s', only decals can be reordered", tostring(movedUid)))
    return false
  end

  -- the row displayed right below the moved one sits directly beneath it in the stack. when the
  -- decal lands on the last row there is none, so it gets anchored below the row above it instead.
  local toPos = arrayFindValueIndex(orderedUids, movedUid)
  local belowUid = orderedUids[toPos + 1]
  local anchorUid = belowUid or orderedUids[toPos - 1]

  local anchorIndex, anchorParentUid = locateLayer(anchorUid, "reorder")
  if not anchorIndex or anchorParentUid then
    log("W", "liveries", string.format("can't reorder layer '%s', no root sibling to anchor it to", tostring(movedUid)))
    return false
  end

  local toIndex = belowUid and (anchorIndex + 1) or anchorIndex
  -- moveLayer removes the layer before re-inserting it, so anything above it shifts down by one
  if fromIndex < toIndex then toIndex = toIndex - 1 end
  toIndex = math.max(toIndex, FIRST_MOVABLE_ROOT_INDEX)

  if fromIndex == toIndex then return true end

  -- the stack refresh comes back through the dynamicDecals_moveLayer hook
  api.moveLayer(fromIndex, nil, toIndex, nil)
  return true
end

M.getPaint = function(layerUid)
  if not isActive then
    log("W", "liveries", "can't read decal paint, decal editor isn't active")
    return nil
  end

  return ui_liveries_paint.getLayerPaint(layerUid)
end

M.setPaint = function(layerUid, paint)
  if not isActive then
    log("W", "liveries", "can't update decal paint, decal editor isn't active")
    return false
  end

  return ui_liveries_paint.setLayerPaint(layerUid, paint)
end

local function findMirrorLayer(layerUid, action)
  if not api then return nil end

  if type(layerUid) ~= "string" then
    log("W", "liveries", string.format("can't %s layer mirror, invalid layerUid '%s'", action, tostring(layerUid)))
    return nil
  end

  local layer = api.getLayerByUid(layerUid)
  if not layer then
    log("W", "liveries", string.format("can't %s layer mirror, no layer with uid '%s'", action, tostring(layerUid)))
    return nil
  end

  return layer
end

-- per-layer mirror flags for a committed decal; the mirror plane offset is editor-global
M.getLayerMirror = function(layerUid)
  if not isActive then
    log("W", "liveries", "can't read decal mirror, decal editor isn't active")
    return nil
  end

  local layer = findMirrorLayer(layerUid, "read")
  if not layer then return nil end

  return {
    layerUid = layer.uid,
    mirrored = layer.mirrored == true,
    flipMirroredDecal = layer.flipMirroredDecal == true,
    mirrorOffset = api.getMirrorOffset() or DEFAULT_MIRROR_OFFSET,
  }
end

-- the new values are applied to a copy of the layer, so the api's history don't get affected
M.setLayerMirror = function(layerUid, mirror)
  if not isActive then
    log("W", "liveries", "can't update decal mirror, decal editor isn't active")
    return false
  end

  local layer = findMirrorLayer(layerUid, "update")
  if not layer then return false end

  if type(mirror) ~= "table" then
    log("W", "liveries", "can't update layer mirror, no mirror data given")
    return false
  end

  local updatedLayer = deepcopy(layer)
  updatedLayer.mirrored = mirror.mirrored == true
  updatedLayer.flipMirroredDecal = mirror.flipMirroredDecal == true
  api.setLayer(updatedLayer, true)
  return true
end

M.getTransformPaint = function()
  if not api then return nil end

  return {
    layerUid = existingTransformSession and existingTransformSession.layerUid or TRANSFORM_PAINT_UID,
    color = api.getDecalColor():toTable(),
    metallic = api.getMetallicIntensity(),
    roughness = api.getRoughnessIntensity(),
    presets = ui_liveries_paint.getVehiclePaintPresets(),
  }
end

M.setTransformPaint = function(paint)
  if not api then return false end

  if type(paint) ~= "table" then
    log("W", "liveries", "can't update transform paint, no paint data given")
    return false
  end

  local readNormalized = ui_liveries_paint.readNormalized
  local color = type(paint.color) == "table" and paint.color or {}
  local currentColor = api.getDecalColor():toTable()

  -- the color's alpha doubles as the decal's opacity
  api.setDecalColor(Point4F(
    readNormalized(color[1], currentColor[1]),
    readNormalized(color[2], currentColor[2]),
    readNormalized(color[3], currentColor[3]),
    readNormalized(color[4], currentColor[4])
  ))

  if paint.metallic ~= nil then
    api.setMetallicIntensity(readNormalized(paint.metallic, api.getMetallicIntensity()))
  end

  if paint.roughness ~= nil then
    api.setRoughnessIntensity(readNormalized(paint.roughness, api.getRoughnessIntensity()))
  end

  api.onUpdate_()
  return true
end

local function isControllerUsed()
  local devices = core_input_bindings.getRecentDevices()
  if not devices or #devices == 0 then return false end
  local first = devices[1]
  return first ~= "keyboard0" and first ~= "mouse0"
end

local function centerCursor()
  -- mouse placement owns the cursor position, so only center it when the setting is off
  cursorForcedMousePosOff = false
  if api.isUseMousePos() then return end
  api.setCursorPosition(Point2F(0.5, 0.5))
end

local function restoreCursorMousePos()
  if not cursorForcedMousePosOff then return end
  api.toggleSetting(api.settingsFlags.UseMousePos.value)
  cursorForcedMousePosOff = false
end

M.showSelectedCursor = function()
  local selectedCatalogItem = ui_liveries_textures.getSelectedItem()
  if not selectedCatalogItem or not selectedCatalogItem.preview then
    log("W", "liveries", "no selected decal texture to show the cursor for")
    return
  end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return
  end

  if isControllerUsed() then
    M.setUseMousePos(false)
  end

  centerCursor()
  api.setDecalTexturePath("color", selectedCatalogItem.preview)

  local color = api.getDecalColor():toTable()
  color[4] = 1
  api.setDecalColor(Point4F.fromTable(color))

  api.setProjectDynamicDecalsState(true)

  resetTransform()
  resetMirror()
  smallIncrements = false
  lockRatio = false
  notifyTransform()

  scaleInputHorizontal = 0
  scaleInputVertical = 0
  skewInputHorizontal = 0
  skewInputVertical = 0
  rotateLeftValue = 0
  rotateRightValue = 0
  if not transformActionMapActive then
    pushActionMap(TRANSFORM_ACTION_MAP)
    transformActionMapActive = true
  end
  ui_liveries_camera.startTransform()
end

M.hideSelectedCursor = function()
  if transformActionMapActive then
    popActionMap(TRANSFORM_ACTION_MAP)
    transformActionMapActive = false
  end
  scaleInputHorizontal = 0
  scaleInputVertical = 0
  skewInputHorizontal = 0
  skewInputVertical = 0
  rotateLeftValue = 0
  rotateRightValue = 0
  ui_liveries_camera.stopTransform()

  if not api or not ui_liveries.isRunning() then return end

  local color = api.getDecalColor():toTable()
  color[4] = 0
  api.setDecalColor(Point4F.fromTable(color))
  api.onUpdate_()
  api.setProjectDynamicDecalsState(false)
  restoreCursorMousePos()
end

M.suspendTransformActionMap = function()
  if transformActionMapActive then
    popActionMap(TRANSFORM_ACTION_MAP)
    transformActionMapActive = false
  end
  scaleInputHorizontal = 0
  scaleInputVertical = 0
  skewInputHorizontal = 0
  skewInputVertical = 0
  rotateLeftValue = 0
  rotateRightValue = 0
end

M.resumeTransformActionMap = function()
  if not transformActionMapActive then
    pushActionMap(TRANSFORM_ACTION_MAP)
    transformActionMapActive = true
  end
end

local function isLayerCentered(layer)
  local uv = layer.cursorPosScreenUv
  if not uv then return false end
  return math.abs(uv.x - CENTER_UV) <= CENTERED_UV_EPSILON and math.abs(uv.y - CENTER_UV) <= CENTERED_UV_EPSILON
end

M.beginExistingTransform = function(layerUid)
  -- entering fresh always supersedes a leftover session; treat the old one as a cancel
  if existingTransformSession then
    M.endExistingTransform()
  end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return false
  end

  if type(layerUid) ~= "string" then
    log("W", "liveries", "beginExistingTransform: invalid layerUid")
    return false
  end

  local layer = api.getLayerByUid(layerUid)
  if not layer then
    log("W", "liveries", string.format("beginExistingTransform: no layer with uid '%s'", tostring(layerUid)))
    return false
  end

  if layer.type ~= api.layerTypes.decal then
    log("W", "liveries", string.format("beginExistingTransform: layer '%s' is not a decal", tostring(layerUid)))
    return false
  end

  if not isLayerCentered(layer) then
    log("W", "liveries", string.format("beginExistingTransform: layer '%s' isn't centered, refusing to edit", tostring(layerUid)))
    return false
  end

  existingTransformSession = {
    layerUid = layerUid,
    originalLayer = deepcopy(layer),
    wasHighlighted = getHighlightedLayerUid() == layerUid,
    applied = false,
  }
  return true
end

M.showExistingCursor = function()
  local session = existingTransformSession
  if not session then
    log("W", "liveries", "no existing transform session to show the cursor for")
    return
  end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return
  end

  local original = session.originalLayer

  clearHighlight()
  api.setLayerVisibility(session.layerUid, false)

  if isControllerUsed() then
    M.setUseMousePos(false)
  end

  centerCursor()

  if original.decalColorTexturePath then
    api.setDecalTexturePath("color", original.decalColorTexturePath)
  end
  local color = original.color and original.color:toTable() or api.getDecalColor():toTable()
  color[4] = 1
  api.setDecalColor(Point4F.fromTable(color))
  api.setDecalScale(vec3(original.decalScale.x, original.decalScale.y, original.decalScale.z))
  api.setDecalSkew(Point2F(original.decalSkew.x, original.decalSkew.y))
  api.setDecalRotation(original.decalRotation or 0)
  api.setUseSurfaceNormal(original.useSurfaceNormal == true)
  api.setMirrored(original.mirrored == true)
  api.setFlipMirroredDecal(original.flipMirroredDecal == true)

  api.setProjectDynamicDecalsState(true)

  smallIncrements = false
  lockRatio = false
  notifyTransform()

  scaleInputHorizontal = 0
  scaleInputVertical = 0
  skewInputHorizontal = 0
  skewInputVertical = 0
  rotateLeftValue = 0
  rotateRightValue = 0
  if not transformActionMapActive then
    pushActionMap(TRANSFORM_ACTION_MAP)
    transformActionMapActive = true
  end
  ui_liveries_camera.startTransformAtLayer(session.layerUid)
end

M.endExistingTransform = function()
  local session = existingTransformSession
  if not session then return end
  existingTransformSession = nil -- clear first so re-entrancy (teardown, refresh) is safe

  M.hideSelectedCursor()

  if not session.applied and api then
    api.setLayerVisibility(session.layerUid, session.originalLayer.enabled ~= false)
    if session.wasHighlighted then
      highlightLayer(session.layerUid)
    end
  end

  refreshLayers()
end

M.startAddDecal = function(targetLayerUid)
  local targetLayer = type(targetLayerUid) == "string" and api and api.getLayerByUid(targetLayerUid) or nil
  pendingAddTargetUid = targetLayer and targetLayer.type == api.layerTypes.decal and targetLayerUid or nil
  extensions.ui_router.navigate("liveries.edit.decals.camera")
end

M.placeSelectedDecal = function()
  local selectedCatalogItem = ui_liveries_textures.getSelectedItem()
  if not selectedCatalogItem or not selectedCatalogItem.preview then
    log("W", "liveries", "no selected decal texture to place")
    return nil
  end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return nil
  end

  M.select(nil)

  local targetIndex, targetParentUid
  if pendingAddTargetUid then
    targetIndex, targetParentUid = locateLayer(pendingAddTargetUid, "insert above")
  end
  pendingAddTargetUid = nil

  local layer = api.addDecal()
  ui_liveries_textures.clearSelectedItem()

  if layer and layer.uid then
    if targetIndex then
      local rootIndex = #api.getLayerStack()
      local destinationIndex = targetIndex + 1

      if targetParentUid or rootIndex ~= destinationIndex then
        api.moveLayer(rootIndex, nil, destinationIndex, targetParentUid)

        local focusNode = findLayerNode(layers, layer.uid)
        if focusNode then
          focusNode.focus = true
          notifyLayers()
        end
      end
    end

    extensions.ui_router.navigate("liveries.edit.decals")
  end

  return layer and layer.uid
end

M.commitTransform = function()
  local session = existingTransformSession
  if not session then
    return M.placeSelectedDecal()
  end

  if not api then
    log("E", "liveries", "dynamic decals api not available")
    return false
  end

  if not api.replaceDecalTransformFromCurrentProjection(session.layerUid, session.originalLayer) then
    log("W", "liveries", string.format("commitTransform: failed to re-transform layer '%s'", tostring(session.layerUid)))
    return false
  end

  session.applied = true
  extensions.ui_router.navigate("liveries.edit.decals")
  return true
end

M.setScaleHorizontal = function(value)
  scaleInputHorizontal = value or 0
end

M.setScaleVertical = function(value)
  scaleInputVertical = value or 0
end

M.setSkewHorizontal = function(value)
  skewInputHorizontal = value or 0
end

M.setSkewVertical = function(value)
  skewInputVertical = value or 0
end

M.setRotateLeft = function(value)
  rotateLeftValue = value or 0
end

M.setRotateRight = function(value)
  rotateRightValue = value or 0
end

M.setUseSurfaceNormal = function(value)
  if type(value) ~= "boolean" then
    log("W", "liveries", "setUseSurfaceNormal: value must be a boolean, got " .. dumps(value))
    return false
  end

  if not api then return false end

  if api.getUseSurfaceNormal() ~= value then
    api.setUseSurfaceNormal(value)
    notifyTransform()
  end

  return true
end

M.toggleProjectionMode = function()
  if not transformActionMapActive then return end
  if not api then return end

  M.setUseSurfaceNormal(not api.getUseSurfaceNormal())
end

M.getTransformSnapshot = function()
  if not api then return nil end
  return buildTransformSnapshot()
end

M.getMirrorSnapshot = function()
  if not api then return nil end
  return buildMirrorSnapshot()
end

M.getSmallIncrements = function()
  return smallIncrements
end

M.setSmallIncrements = function(value)
  if type(value) ~= "boolean" then
    log("W", "liveries", "setSmallIncrements: value must be a boolean, got " .. dumps(value))
    return false
  end

  if smallIncrements ~= value then
    smallIncrements = value
    notifyTransform()
  end

  return true
end

M.getLockRatio = function()
  return lockRatio
end

M.setLockRatio = function(value)
  if type(value) ~= "boolean" then
    log("W", "liveries", "setLockRatio: value must be a boolean, got " .. dumps(value))
    return false
  end

  if lockRatio ~= value then
    lockRatio = value
    notifyTransform()
  end

  return true
end

M.isUseMousePos = function()
  if not api then return false end
  return api.isUseMousePos()
end

M.setUseMousePos = function(value)
  if not api then return false end

  if type(value) ~= "boolean" then
    log("W", "liveries", "setUseMousePos: value must be a boolean, got " .. dumps(value))
    return false
  end

  cursorForcedMousePosOff = false

  if api.isUseMousePos() ~= value then
    api.toggleSetting(api.settingsFlags.UseMousePos.value)
  end

  -- mouse placement expects orbit-style camera control
  if value and transformActionMapActive then
    ui_liveries_camera.ensureTransformOrbitMode()
  end

  return true
end

M.setMirrored = function(value)
  if not api then return false end

  if type(value) ~= "boolean" then
    log("W", "liveries", "setMirrored: value must be a boolean, got " .. dumps(value))
    return false
  end

  api.setMirrored(value)
  return true
end

M.setFlipMirroredDecal = function(value)
  if not api then return false end

  if type(value) ~= "boolean" then
    log("W", "liveries", "setFlipMirroredDecal: value must be a boolean, got " .. dumps(value))
    return false
  end

  api.setFlipMirroredDecal(value)
  return true
end

M.setMirrorOffset = function(value)
  if not api then return false end

  if type(value) ~= "number" then
    log("W", "liveries", "setMirrorOffset: value must be a number, got " .. dumps(value))
    return false
  end

  api.setMirrorOffset(clamp(value, -MIRROR_OFFSET_LIMIT, MIRROR_OFFSET_LIMIT))
  return true
end

M.onUpdate = function(dtReal)
  if not transformActionMapActive then return end

  if not api then return end

  local transformChanged = false
  local rateScale = smallIncrements and SMALL_INCREMENT_MULTIPLIER or 1

  if scaleInputHorizontal ~= 0 or scaleInputVertical ~= 0 then
    local scale = api.getDecalScale()
    local deltaH = scaleInputHorizontal * SCALE_SPEED * rateScale * dtReal
    local deltaV = scaleInputVertical * SCALE_SPEED * rateScale * dtReal
    local deltaX, deltaZ
    if lockRatio then
      local delta = deltaH + deltaV
      deltaX = delta
      deltaZ = delta
    else
      deltaX = deltaH
      deltaZ = deltaV
    end
    local x = math.max(MIN_DECAL_SCALE, scale.x + deltaX)
    local z = math.max(MIN_DECAL_SCALE, scale.z + deltaZ)
    api.setDecalScale(vec3(x, scale.y, z))
    transformChanged = true
  end

  if skewInputHorizontal ~= 0 or skewInputVertical ~= 0 then
    local skew = api.getDecalSkew()
    local deltaH = skewInputHorizontal * SKEW_SPEED * rateScale * dtReal
    local deltaV = skewInputVertical * SKEW_SPEED * rateScale * dtReal
    local deltaX, deltaY
    if lockRatio then
      local delta = deltaH + deltaV
      deltaX = delta
      deltaY = delta
    else
      deltaX = deltaH
      deltaY = deltaV
    end
    local x = clamp(skew.x + deltaX, -2, 2)
    local y = clamp(skew.y + deltaY, -2, 2)
    api.setDecalSkew(Point2F(x, y))
    transformChanged = true
  end

  local rotateAmount = rotateRightValue - rotateLeftValue
  if rotateAmount ~= 0 then
    api.setDecalRotation(wrapRotation(api.getDecalRotation() + rotateAmount * ROTATION_SPEED * rateScale * dtReal))
    transformChanged = true
  end

  if transformChanged then
    notifyTransform()
  end
end

-- External hooks. Do not call!
local function onLayerStackChanged()
  if not isActive then return end
  rebuildLayers(true)
  notifyLayers()
end

M.dynamicDecals_onLayerAdded = onLayerStackChanged
M.dynamicDecals_onLayerDeleted = onLayerStackChanged
M.dynamicDecals_onLayerUpdated = onLayerStackChanged
M.dynamicDecals_moveLayer = onLayerStackChanged

return M
