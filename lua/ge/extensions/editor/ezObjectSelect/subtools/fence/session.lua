-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local anchors = require("editor/ezObjectSelect/subtools/fence/anchors")
local objectBoxAnchors = require("editor/ezObjectSelect/objectBoxAnchors")
local populationEngine = require("editor/meshSpline/populationEngine")
local rdp = require("editor/toolUtilities/rdp")
local rSpline = require("editor/toolUtilities/render/spline")
local splineInput = require("editor/toolUtilities/splineInput")
local util = require("editor/toolUtilities/util")

local minimumSplineDivisions = 100
local maximumPreviewPieces = 512
local rdpTolerance = 0.5
local defaultSplineWidth = 10
local globalUp = vec3(0, 0, 1)
local unitScale = vec3(1, 1, 1)
local quat90Z = quat(0, 0, 0.70710678, 0.70710678)
local nodeColor = ColorF(0.2, 1, 0.7, 0.95)
local escapeKey = im.GetKeyIndex(im.Key_Escape)

local active = false
local initialCreation = false
local initialDrag = false
local capped = false
local noOverlap = true
local spline = nil
local splineList = {}
local splineState = {spline = 1, node = 1, isGizmoActive = false, isLockShape = false}
local assetPath = nil
local assetPaths = {}
local panelLength = nil
local isLongX = false
local localAnchorCenter = nil
local sessionScale = vec3(1, 1, 1)
local sourceSnapshots = {}
local sourceObjects = {}
local extraObjects = {}
local placements = {}
local sampledPositions, sampledTangents, sampledNormals = {}, {}, {}
local discoveryResult = nil
local selectedPieceCount = 0
local statusMessage = nil
local originalSelection = {}

local framePosition, frameTangent, frameUp = vec3(), vec3(), vec3()
local previousAcross = vec3()
local baseRotation, finalRotation = quat(), quat()

local function refreshScene()
  if editor.refreshSceneTreeWindow then editor.refreshSceneTreeWindow() end
  if be and be.reloadCollision then be:reloadCollision() end
  editor.setDirty()
end

local function copyVecArray(values)
  local result = {}
  for index, value in ipairs(values or {}) do result[index] = vec3(value) end
  return result
end

local function copySpline(value)
  if not value then return nil end
  return {
    id = value.id,
    nodes = copyVecArray(value.nodes),
    widths = deepcopy(value.widths),
    nmls = copyVecArray(value.nmls),
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    isEnabled = value.isEnabled,
    isLink = false,
    isLoop = value.isLoop,
    isConformToTerrain = value.isConformToTerrain,
    terrainOnly = value.terrainOnly,
    rayPostFloat = value.rayPostFloat,
    isDirty = true,
    normalMode = value.normalMode
  }
end

local function copySplineState()
  return spline and {copySpline(spline)} or {}
end

local function noop()
end

local function suppressHistoryCommit()
  return true
end

local function syncSplineArrays()
  if not spline then return end
  for index = #spline.widths, #spline.nodes + 1, -1 do spline.widths[index] = nil end
  for index = #spline.nmls, #spline.nodes + 1, -1 do spline.nmls[index] = nil end
  for index = 1, #spline.nodes do
    spline.widths[index] = spline.widths[index] or defaultSplineWidth
    spline.nmls[index] = spline.nmls[index] or vec3(globalUp)
  end
end

local function newSpline(nodes, isLoop)
  spline = {
    id = Engine.generateUUID(),
    nodes = copyVecArray(nodes),
    widths = {},
    nmls = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    isEnabled = true,
    isLink = false,
    isLoop = isLoop == true,
    isConformToTerrain = true,
    terrainOnly = true,
    rayPostFloat = 0,
    isDirty = true,
    normalMode = 0
  }
  syncSplineArrays()
  splineList[1] = spline
  splineState.spline = 1
  splineState.node = math.max(1, #spline.nodes)
  splineState.isGizmoActive = false
end

local function deleteObjectIds(ids)
  local deleted = {}
  for _, objectId in ipairs(ids or {}) do
    if not deleted[objectId] and scenetree.findObjectById(objectId) then
      editor.deleteObject(objectId)
      deleted[objectId] = true
    end
  end
end

local function nextSiblingInfo(obj, excludedIds)
  local parent = obj:getGroup()
  if not parent then return nil, nil end
  local foundObject = false
  for index = 0, parent:size() - 1 do
    local child = parent:at(index)
    local childId = child and child:getID() or nil
    if foundObject and childId and not excludedIds[childId] then
      return childId, index
    end
    if childId == obj:getID() then foundObject = true end
  end
  return nil, parent:size()
end

local function collisionEnabledState(obj)
  if obj.isCollisionEnabled then
    local ok, enabled = pcall(obj.isCollisionEnabled, obj)
    if ok and type(enabled) == "boolean" then return enabled end
  end
  local ok, enabled = pcall(function() return obj.collisionEnabled end)
  if ok and type(enabled) == "boolean" then return enabled end
  if obj.getField then
    local fieldOk, fieldValue = pcall(obj.getField, obj, "collisionEnabled", 0)
    if fieldOk and fieldValue ~= nil and fieldValue ~= "" then
      fieldValue = string.lower(tostring(fieldValue))
      if fieldValue == "true" or fieldValue == "1" then return true end
      if fieldValue == "false" or fieldValue == "0" then return false end
    end
    local typeOk, collisionType = pcall(obj.getField, obj, "collisionType", 0)
    if typeOk and collisionType ~= nil and collisionType ~= "" then
      return string.lower(tostring(collisionType)) ~= "none"
    end
  end
  return nil
end

local function snapshotObject(obj, excludedIds)
  if not obj then return nil end
  local serialized = obj:serialize(true, -1)
  if not serialized or serialized == "" then return nil end
  local parent = obj:getGroup()
  local nextSiblingId, siblingIndex = nextSiblingInfo(obj, excludedIds or {})
  return {
    id = obj:getID(),
    serialized = "[" .. serialized .. "]",
    parentId = parent and parent:getID() or nil,
    nextSiblingId = nextSiblingId,
    siblingIndex = siblingIndex,
    cansave = obj.cansave,
    collisionEnabled = collisionEnabledState(obj)
  }
end

local function snapshotObjects(objects, excludedIds)
  local result = {}
  for _, obj in ipairs(objects or {}) do
    local snapshot = snapshotObject(obj, excludedIds)
    if not snapshot then return nil end
    result[#result + 1] = snapshot
  end
  return result
end

local function stateIds(state)
  local ids = {}
  for _, snapshot in ipairs(state or {}) do ids[#ids + 1] = snapshot.id end
  return ids
end

local function restoreObjectState(state, currentIds)
  deleteObjectIds(currentIds)
  local restoredObjects = {}
  local restoredIds = {}
  local restoredList = {}
  for _, snapshot in ipairs(state or {}) do
    SimObject.setForcedId(snapshot.id)
    Sim.deserializeObjectsFromText(snapshot.serialized, true, true)
    local obj = scenetree.findObjectById(snapshot.id)
    if obj then
      restoredObjects[snapshot.id] = obj
      restoredIds[#restoredIds + 1] = snapshot.id
      restoredList[#restoredList + 1] = obj
      local parent = snapshot.parentId and (
        scenetree.findObjectById(snapshot.parentId) or scenetree.MissionGroup) or nil
      if parent then parent:addObject(obj.obj) end
      if snapshot.cansave ~= nil then obj.cansave = snapshot.cansave end
      if snapshot.collisionEnabled == false and obj.disableCollision then
        obj:disableCollision()
      elseif snapshot.collisionEnabled == true and obj.enableCollision then
        obj:enableCollision()
      end
    end
  end

  local orderedState = {}
  for _, snapshot in ipairs(state or {}) do orderedState[#orderedState + 1] = snapshot end
  table.sort(orderedState, function(first, second)
    if first.parentId == second.parentId then
      return (first.siblingIndex or 0) < (second.siblingIndex or 0)
    end
    return tostring(first.parentId) < tostring(second.parentId)
  end)
  for _, snapshot in ipairs(orderedState) do
    local obj = restoredObjects[snapshot.id]
    local nextSibling = snapshot.nextSiblingId and scenetree.findObjectById(snapshot.nextSiblingId) or nil
    local parent = obj and obj:getGroup() or nil
    local nextParent = nextSibling and nextSibling:getGroup() or nil
    if parent and nextParent and nextParent:getID() == parent:getID() then
      parent:reorderChild(obj, nextSibling)
    end
  end

  for _, objectId in ipairs(restoredIds) do
    extensions.hook("onEditorObjectAdded", objectId)
  end
  refreshScene()
  return restoredIds, restoredList
end

local function applyHistoryState(data, state)
  data.currentIds = restoreObjectState(state, data.currentIds)
end

local function fenceUndo(data)
  applyHistoryState(data, data.before)
end

local function fenceRedo(data)
  applyHistoryState(data, data.after)
end

local function currentPreviewIds()
  local ids = stateIds(sourceSnapshots)
  for _, obj in ipairs(extraObjects) do
    if obj and simObjectExists(obj) then ids[#ids + 1] = obj:getID() end
  end
  return ids
end

local function restoreSources()
  local _, restoredObjects = restoreObjectState(sourceSnapshots, currentPreviewIds())
  sourceObjects = restoredObjects
  table.clear(extraObjects)
end

local function previewObject(index)
  if sourceObjects[index] then return sourceObjects[index] end
  local extraIndex = index - #sourceObjects
  local obj = extraObjects[extraIndex]
  if not obj or not simObjectExists(obj) then
    obj = createObject("TSStatic")
    obj.cansave = false
    obj:setField("shapeName", 0, assetPath)
    obj:registerObject()
    extraObjects[extraIndex] = obj
  end
  return obj
end

local function resizePreviewPool(count)
  for index = 1, #sourceObjects do
    local obj = sourceObjects[index]
    if obj and simObjectExists(obj) then
      local hidden = index > count
      if obj.setHidden then obj:setHidden(hidden) end
      if obj.setRenderEnabled then obj:setRenderEnabled(not hidden) end
    end
  end
  local requiredExtras = math.max(0, count - #sourceObjects)
  for index = #extraObjects, requiredExtras + 1, -1 do
    local obj = extraObjects[index]
    if obj and simObjectExists(obj) then obj:delete() end
    extraObjects[index] = nil
  end
end

local function polylineLength(points)
  local length = 0
  for index = 2, #points do length = length + points[index]:distance(points[index - 1]) end
  return length
end

local function fitSamplingStride(points)
  if noOverlap then return panelLength end
  local length = polylineLength(points)
  if length <= 0.001 then return panelLength end
  local count = math.max(1, math.ceil(length / math.max(panelLength, 0.1)))
  return length / count * (1 - 1e-9)
end

local function rebuildPreview()
  if not spline then return end
  syncSplineArrays()
  if not populationEngine.updateGeometry(spline, minimumSplineDivisions) then
    table.clear(placements)
    resizePreviewPool(0)
    spline.isDirty = false
    return
  end

  populationEngine.sample(
    spline,
    fitSamplingStride(spline.divPoints),
    sampledPositions,
    sampledTangents,
    sampledNormals)
  local sectionCount = math.max(0, #sampledPositions - 1)
  capped = sectionCount > maximumPreviewPieces
  sectionCount = math.min(sectionCount, maximumPreviewPieces)
  table.clear(placements)
  previousAcross:set(0, 0, 0)

  for index = 1, sectionCount do
    if populationEngine.intervalFrame(
      sampledPositions,
      sampledTangents,
      sampledNormals,
      index,
      framePosition,
      frameTangent,
      frameUp,
      previousAcross) then
      baseRotation:setFromDir(frameTangent, frameUp)
      if isLongX then
        finalRotation:setMul2(quat90Z, baseRotation)
      else
        finalRotation:set(baseRotation)
      end
      local centerOffset = localAnchorCenter:rotated(finalRotation)
      placements[#placements + 1] = {
        position = vec3(framePosition - centerOffset),
        rotation = quat(finalRotation.x, finalRotation.y, finalRotation.z, finalRotation.w)
      }
    end
  end

  resizePreviewPool(#placements)
  for index, placement in ipairs(placements) do
    local obj = previewObject(index)
    obj.cansave = false
    if obj.setHidden then obj:setHidden(false) end
    if obj.setRenderEnabled then obj:setRenderEnabled(true) end
    obj:setField("shapeName", 0, assetPath)
    obj.scale = vec3(sessionScale)
    if obj.disableCollision then obj:disableCollision() end
    local position, rotation = placement.position, placement.rotation
    obj:setPosRot(
      position.x,
      position.y,
      position.z,
      rotation.x,
      rotation.y,
      rotation.z,
      rotation.w)
  end
  spline.isDirty = false
end

local function configureAsset(path, scale)
  local box = util.getMeshBox(path)
  if not box or not box.extents then return false, "Unable to read fence mesh bounds" end
  sessionScale = scale and vec3(scale) or vec3(unitScale)
  local boxDescription = objectBoxAnchors.describeMeshBox(box, sessionScale)
  if not boxDescription then return false, "Unable to derive fence mesh anchors" end
  isLongX = boxDescription.isLongX
  panelLength = isLongX and boxDescription.scaledX or boxDescription.scaledY
  if panelLength <= 0.001 then return false, "Fence mesh has no usable horizontal length" end
  assetPath = path
  localAnchorCenter = (
    boxDescription.shortEdgeOrigin.firstLocal
    + boxDescription.shortEdgeOrigin.secondLocal) * 0.5
  return true
end

local function clearSessionState()
  active = false
  initialCreation = false
  initialDrag = false
  capped = false
  noOverlap = true
  spline = nil
  splineList[1] = nil
  assetPath = nil
  panelLength = nil
  localAnchorCenter = nil
  discoveryResult = nil
  selectedPieceCount = 0
  statusMessage = nil
  splineState.spline = 1
  splineState.node = 1
  splineState.isGizmoActive = false
  worldEditorCppApi.setAxisGizmoSelectedElement(-1)
  table.clear(assetPaths)
  table.clear(sourceSnapshots)
  table.clear(sourceObjects)
  table.clear(extraObjects)
  table.clear(placements)
  table.clear(sampledPositions)
  table.clear(sampledTangents)
  table.clear(sampledNormals)
  table.clear(originalSelection)
end

local function beginFromSelection(seedObjectId, options)
  local result, errorMessage = anchors.discover(seedObjectId, {
    assetPaths = options.assetPaths,
    distance = options.anchorDistance,
    maximumPieces = options.maximumPieces
  })
  if not result then return false, errorMessage end
  if #result.ids < 1 or #result.joints < 2 then return false, "No connected fence run found" end

  local discoveredObjects = {}
  for _, objectId in ipairs(result.ids) do
    local obj = scenetree.findObjectById(objectId)
    if not obj
      or not editor.canManipulateObject(obj)
      or not editor.isObjectSelectable(obj) then
      return false, "Fence contains locked or non-manipulable objects"
    end
    discoveredObjects[#discoveredObjects + 1] = obj
  end
  local snapshots = snapshotObjects(discoveredObjects)
  if not snapshots then return false, "Unable to serialize every fence source object" end

  local seedDescriptor = result.descriptors[seedObjectId]
  local seedObject = seedDescriptor and seedDescriptor.obj
  local seedScale = seedObject and seedObject:getScale() or unitScale
  local configured, configureError = configureAsset(seedDescriptor.shapePath, seedScale)
  if not configured then return false, configureError end

  local nodes = copyVecArray(result.joints)
  if not result.isLoop and #nodes > 2 then rdp.simplifyNodes(nodes, rdpTolerance) end
  newSpline(nodes, result.isLoop)
  discoveryResult = result
  selectedPieceCount = #result.ids
  sourceObjects = discoveredObjects
  sourceSnapshots = snapshots
  for _, obj in ipairs(sourceObjects) do
    obj.cansave = false
    if obj.disableCollision then obj:disableCollision() end
  end
  active = true
  editor.clearObjectSelection()
  rebuildPreview()
  return true
end

local function beginCreation(options)
  local path = options.assetPaths and options.assetPaths[1]
  if not path then return false, "No fence asset selected" end
  local configured, configureError = configureAsset(path, unitScale)
  if not configured then return false, configureError end
  newSpline({}, false)
  initialCreation = true
  active = true
  return true
end

local function registerSplineInput()
  local prefix = editor.editMode and editor.editMode.displayName or "Easy Select"
  splineInput.registerSplineTool(
    prefix,
    function() return splineList end,
    function() return "ezObjectSelect" end,
    copySpline,
    copySplineState,
    "editor_ezObjectSelect")
end

function M.begin(options)
  if active then return false, "Fence session is already active" end
  options = options or {}
  statusMessage = nil
  splineInput.cancelDrag()
  table.clear(assetPaths)
  table.clear(sourceSnapshots)
  table.clear(sourceObjects)
  table.clear(extraObjects)
  originalSelection = deepcopy(editor.selection.object or {})
  noOverlap = options.noOverlap ~= false
  for _, path in ipairs(options.assetPaths or {}) do assetPaths[#assetPaths + 1] = path end
  registerSplineInput()
  local selectedIds = editor.selection.object
  if selectedIds and #selectedIds > 0 then
    return beginFromSelection(selectedIds[#selectedIds], options)
  end
  return beginCreation(options)
end

local function mouseTerrainPoint()
  local hit = cameraMouseRayCast(false, SOTTerrain)
  if not hit then return nil end
  if hit.pos then return vec3(hit.pos) end
  if hit.pt then return vec3(hit.pt) end
end

local function updateInitialCreation(canAcceptInput)
  if not initialDrag and canAcceptInput and im.IsMouseClicked(0) then
    local point = mouseTerrainPoint()
    if point then
      spline.nodes = {point, vec3(point)}
      syncSplineArrays()
      splineState.node = 2
      spline.isDirty = false
      initialDrag = true
    end
  end
  if initialDrag and im.IsMouseDown(0) and canAcceptInput then
    local point = mouseTerrainPoint()
    if point then
      spline.nodes[2]:set(point)
      spline.isDirty = true
    end
  elseif initialDrag and not im.IsMouseDown(0) then
    if spline.nodes[1]:squaredDistance(spline.nodes[2]) <= 0.0001 then
      spline.nodes = {}
      spline.widths = {}
      spline.nmls = {}
      initialDrag = false
      initialCreation = true
    else
      initialDrag = false
      initialCreation = false
    end
  end
end

local function updateSplineInput()
  splineInput.handleSplineEvents(
    splineList,
    splineState,
    true,
    spline.isConformToTerrain,
    false,
    false,
    false,
    false,
    true,
    false,
    defaultSplineWidth,
    copySpline,
    copySplineState,
    nil,
    nil,
    function() if spline then spline.isDirty = true end end,
    nil,
    noop,
    noop,
    noop,
    noop,
    nil,
    nil,
    nil,
    {commitHistoryOverride = suppressHistoryCommit})
end

local function drawSpline()
  anchors.draw(discoveryResult)
  if not spline then return end
  if #spline.divPoints > 1 then rSpline.renderSplinePolylines(splineList, 1) end
  for _, node in ipairs(spline.nodes) do
    debugDrawer:drawSphere(node, 0.16, nodeColor, false)
  end
end

function M.update(canAcceptInput)
  if not active then return false end
  if im.IsKeyPressed(escapeKey) then
    M.cancel()
    return true
  end

  if initialCreation or initialDrag then
    updateInitialCreation(canAcceptInput)
  elseif canAcceptInput then
    updateSplineInput()
  end
  if spline and spline.isDirty then rebuildPreview() end
  drawSpline()
  return true
end

local function finalObjectState()
  local parent = editor.resolveAddGroup(scenetree.MissionGroup)
  local objects = {}
  local includedIds = {}
  for index = 1, #placements do
    local obj = previewObject(index)
    local sourceSnapshot = sourceSnapshots[index]
    if sourceSnapshot then
      obj.cansave = sourceSnapshot.cansave
    else
      obj.cansave = true
    end
    if obj.setHidden then obj:setHidden(false) end
    if obj.setRenderEnabled then obj:setRenderEnabled(true) end
    if sourceSnapshot and sourceSnapshot.collisionEnabled == false and obj.disableCollision then
      obj:disableCollision()
    elseif obj.enableCollision then
      obj:enableCollision()
    end
    if index > #sourceObjects and parent then parent:addObject(obj.obj) end
    objects[#objects + 1] = obj
    includedIds[obj:getID()] = true
  end

  local excludedIds = {}
  for _, snapshot in ipairs(sourceSnapshots) do
    if not includedIds[snapshot.id] then excludedIds[snapshot.id] = true end
  end
  return snapshotObjects(objects, excludedIds)
end

function M.exitAndCommit()
  if not active then return 0 end
  if M.isCapped() then
    statusMessage = "Cannot commit: fence discovery or preview reached the safety limit"
    return 0
  end
  splineInput.cancelDrag()
  local after = finalObjectState()
  if not after then
    statusMessage = "Cannot commit: unable to serialize every preview object"
    return 0
  end
  local before = deepcopy(sourceSnapshots)
  local currentIds = currentPreviewIds()
  local count = #after
  if count == 0 then
    restoreSources()
    clearSessionState()
    return 0
  end
  clearSessionState()
  editor.history:commitAction(
    "Edit Fence",
    {
      actionId = Engine.generateUUID(),
      before = before,
      after = after,
      currentIds = currentIds
    },
    fenceUndo,
    fenceRedo)
  return count
end

function M.deleteAndCommit()
  if not active or #sourceSnapshots == 0 then return 0 end
  if M.isCapped() then
    statusMessage = "Cannot delete: fence discovery or preview reached the safety limit"
    return 0
  end
  splineInput.cancelDrag()
  local before = deepcopy(sourceSnapshots)
  local currentIds = currentPreviewIds()
  local count = #before
  clearSessionState()
  editor.history:commitAction(
    "Delete Fence",
    {
      actionId = Engine.generateUUID(),
      before = before,
      after = {},
      currentIds = currentIds
    },
    fenceUndo,
    fenceRedo)
  return count
end

function M.cancel()
  if not active then return end
  splineInput.cancelDrag()
  local selection = deepcopy(originalSelection)
  restoreSources()
  clearSessionState()
  if #selection > 0 then
    editor.selectObjects(selection)
  else
    editor.clearObjectSelection()
  end
end

function M.isActive()
  return active
end

function M.isDragging()
  return initialDrag or splineInput.isDragging()
end

function M.getPieceCount()
  return #placements
end

function M.getSelectedPieceCount()
  return selectedPieceCount
end

function M.getNodeCount()
  return spline and #spline.nodes or 0
end

function M.isLoop()
  return spline and spline.isLoop or false
end

function M.isCapped()
  return capped or discoveryResult and discoveryResult.capped or false
end

function M.setNoOverlap(enabled)
  enabled = enabled == true
  if noOverlap == enabled then return end
  noOverlap = enabled
  if spline then spline.isDirty = true end
end

function M.getStatusMessage()
  return statusMessage
end

return M
